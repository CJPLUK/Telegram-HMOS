package ohos_app_cangjie_entry.services

/**
 * NotificationClickRouter — 通知点击 → payload 解析 → 导航路由 (P2-259)
 *
 * iOS 对应（逐行 gap 分析）：
 *   AppDelegate.swift:2840 userNotificationCenter(_:didReceive:withCompletionHandler:)
 *     - actionIdentifier == UNNotificationDefaultActionIdentifier:
 *       - 若 userInfo["url"] 存在 → openUrlWhenReady(url, external: true)
 *       - 否则 → peerIdFromNotification → openChatWhenReady(peerId, messageId, storyId)
 *     - actionIdentifier == "reply" → enqueueMessages（内联回复）
 *
 * HarmonyOS 等价链路：
 *   1. 通知 wantAgent 被触发 → 系统拉起 MainAbility
 *   2. 已在前台 → MainAbility.onNewWant(want)
 *      冷启动 → MainAbility.onCreate(want)
 *   3. MainAbility 调用 getNotificationClickRouter().handleClickWant(want)
 *   4. handleClickWant 解析 want.parameters 中的 peer_id / msg_id / peer_type / url 字段
 *   5. 结果存入模块级 pending click（_pendingClickRecord）
 *   6. MainTabPage.aboutToAppear / 轮询线程检测 pending click → setSelectedChat → pushPathByName
 *
 * 平台 Gap / Defer:
 *   - 内联回复（iOS: "reply" actionIdentifier）：defer，HarmonyOS notificationManager 的
 *     actionButton/回复框接入复杂，与本 feature 解耦，不实现。
 *   - wantAgent 注入到 NotificationRequest：属于发布侧（LocalNotificationDisplayService/P2-258）
 *     不在本 feature 的 target_files 内；已 emit integration_contract ic_notif_wantagent_inject
 *     供 P2-258 worker 接线。本 feature 实现消费侧（parseWant/navigate）。
 *   - Story 导航（storyId）：ChatRoomPage 当前无 story UI，解析字段保留但导航降级到 peer 聊天页。
 */

import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.{Want, WantValueType}
import kit.ArkUI.NavPathStack
import ohos.business_exception.BusinessException
import std.convert.*

// ==================== NotificationClickRecord ====================

/**
 * 通知点击解析结果
 *
 * 对应 iOS AppDelegate openChatWhenReady 调用参数：
 *   peerId     ← peerIdFromNotification(response.notification)
 *   threadId   ← peerIdFromNotification 的 threadId 字段（forum/超级群组话题）
 *   messageId  ← messageIdFromNotification(peerId, notification)
 *   storyId    ← storyIdFromNotification(peerId, notification)（暂保留字段，导航降级）
 *   url        ← userInfo["url"]（外部 URL 跳转）
 *   peerType   ← "user" / "chat" / "channel"（鸿蒙侧额外字段，iOS 靠 namespace 区分）
 */
public class NotificationClickRecord {
    public var peerId: Int64 = 0
    public var threadId: Int64 = 0
    public var messageId: Int32 = 0
    public var storyId: Int32 = 0
    public var url: String = ""
    public var peerName: String = ""
    public var peerType: String = "user"
    public var isValid: Bool = false
}

// ==================== Module-level pending navigation ====================

private var _pendingClickRecord: Option<NotificationClickRecord> = None

/**
 * 设置待处理的通知点击记录（供 MainAbility.onNewWant / onCreate 调用）
 */
public func setPendingNotificationClick(record: NotificationClickRecord) {
    _pendingClickRecord = Some(record)
    Hilog.info(0, "CjTelegram", "[NotifClickRouter] pending click set: peerId=${record.peerId} msgId=${record.messageId} url=${record.url}")
}

/**
 * 读取待处理的通知点击记录
 * 返回 Some(record) 若有待处理点击，None 若无
 */
public func getPendingNotificationClick(): Option<NotificationClickRecord> {
    return _pendingClickRecord
}

/**
 * 清除待处理的通知点击记录（导航完成后调用）
 */
public func clearPendingNotificationClick() {
    _pendingClickRecord = None
    Hilog.info(0, "CjTelegram", "[NotifClickRouter] pending click cleared")
}

// ==================== NotificationClickRouter ====================

private var _notifClickRouterInstance: Option<NotificationClickRouter> = None

public func getNotificationClickRouter(): NotificationClickRouter {
    match (_notifClickRouterInstance) {
        case Some(r) => return r
        case None =>
            let r = NotificationClickRouter()
            _notifClickRouterInstance = Some(r)
            return r
    }
}

/**
 * NotificationClickRouter — 通知点击处理服务
 *
 * 主入口：handleClickWant(want) — 解析 Want 参数并缓存 pending click 记录
 * 副入口：setDirectClick(peerId, messageId, peerType) — 测试/调试用直接设置
 */
public class NotificationClickRouter {

    public init() {}

    /**
     * 解析通知点击 Want 参数，缓存 pending click 记录
     *
     * Want.parameters 中的键（与发布侧 ic_notif_wantagent_inject 约定）：
     *   "notif_peer_id"   → Int64Value(peerId)
     *   "notif_msg_id"    → Int64Value(messageId)
     *   "notif_thread_id" → Int64Value(threadId)
     *   "notif_peer_type" → StringValue("user" / "chat" / "channel")
     *   "notif_peer_name" → StringValue(peerName)
     *   "notif_url"       → StringValue(url)（外部 URL 打开场景）
     *
     * @param want  MainAbility.onNewWant / onCreate 接收到的 Want
     * @return true 若解析到有效通知点击参数
     */
    public func handleClickWant(want: Want): Bool {
        let params = want.parameters
        Hilog.info(0, "CjTelegram", "[NotifClickRouter] handleClickWant: params size=${params.size}")

        let record = NotificationClickRecord()

        // 解析 peer_id
        match (params.get("notif_peer_id")) {
            case Some(WantValueType.Int64Value(pid)) =>
                record.peerId = pid
            case Some(WantValueType.StringValue(s)) =>
                try {
                    record.peerId = Int64.parse(s)
                } catch (_: Exception) {
                    Hilog.info(0, "CjTelegram", "[NotifClickRouter] peer_id parse failed: ${s}")
                }
            case _ => ()
        }

        // 解析 msg_id
        match (params.get("notif_msg_id")) {
            case Some(WantValueType.Int64Value(mid)) =>
                record.messageId = Int32(mid)
            case Some(WantValueType.StringValue(s)) =>
                try {
                    record.messageId = Int32(Int64.parse(s))
                } catch (_: Exception) {}
            case _ => ()
        }

        // 解析 thread_id
        match (params.get("notif_thread_id")) {
            case Some(WantValueType.Int64Value(tid)) =>
                record.threadId = tid
            case _ => ()
        }

        // 解析 peer_type
        match (params.get("notif_peer_type")) {
            case Some(WantValueType.StringValue(pt)) =>
                record.peerType = pt
            case _ => ()
        }

        // 解析 peer_name
        match (params.get("notif_peer_name")) {
            case Some(WantValueType.StringValue(pn)) =>
                record.peerName = pn
            case _ => ()
        }

        // 解析 url（外部打开场景）
        match (params.get("notif_url")) {
            case Some(WantValueType.StringValue(u)) =>
                record.url = u
            case _ => ()
        }

        // 检查 Want.uri 也可能携带 URL（fallback）
        if (record.url.size == 0 && want.uri.size > 0) {
            record.url = want.uri
        }

        // 有效性判断：peerId > 0（chat/message 点击）或 url 非空（外部 URL）
        record.isValid = record.peerId > 0 || record.url.size > 0

        if (record.isValid) {
            setPendingNotificationClick(record)
            Hilog.info(0, "CjTelegram", "[NotifClickRouter] handleClickWant: valid click → peerId=${record.peerId} msgId=${record.messageId} peerType=${record.peerType} url=${record.url}")
        } else {
            Hilog.info(0, "CjTelegram", "[NotifClickRouter] handleClickWant: no valid notification params in Want, skipping")
        }

        return record.isValid
    }

    /**
     * 直接设置 pending click（测试 / 开发场景用）
     *
     * @param peerId    目标 peer ID
     * @param messageId 目标消息 ID（0 = 跳转聊天列表头部）
     * @param peerType  "user" / "chat" / "channel"
     * @param peerName  显示名称（用于 setSelectedChat）
     */
    public func setDirectClick(
        peerId: Int64,
        messageId: Int32,
        peerType: String,
        peerName: String
    ) {
        let record = NotificationClickRecord()
        record.peerId = peerId
        record.messageId = messageId
        record.peerType = peerType
        record.peerName = peerName
        record.isValid = peerId > 0
        if (record.isValid) {
            setPendingNotificationClick(record)
        }
    }

    /**
     * 执行导航：将 pending click 记录映射到 pageStack pushPathByName
     *
     * 调用方：MainTabPage.aboutToAppear / 后台轮询
     *
     * 导航规则（对应 iOS openChatWhenReady）：
     *   - url 非空 → emit ic_open_external_url 由 BrowserService 处理（鸿蒙侧 Want.viewData）
     *   - peerId > 0 → setSelectedChat + pageStack.pushPathByName("ChatRoomPage", chatName)
     *     其中 chatName = peerName（若有），否则 fallback 到 peerId.toString()
     *     messageId 存入 selectedChatMessageId（新字段）供 ChatRoomPage 滚动定位
     *
     * @param pageStack  MainTabPage.@Provide pageStack（NavPathStack）
     * @return true 若触发了导航
     */
    public func navigatePendingClick(pageStack: NavPathStack): Bool {
        match (getPendingNotificationClick()) {
            case None =>
                return false
            case Some(record) =>
                clearPendingNotificationClick()

                if (record.url.size > 0 && record.peerId == 0) {
                    Hilog.info(0, "CjTelegram", "[NotifClickRouter] navigatePendingClick: URL open → ${record.url}")
                    handleUrlNavigation(record.url)
                    return true
                }

                if (record.peerId > 0) {
                    let chatName = if (record.peerName.size > 0) { record.peerName } else { record.peerId.toString() }
                    Hilog.info(0, "CjTelegram", "[NotifClickRouter] navigatePendingClick: chat → peerId=${record.peerId} chatName=${chatName} msgId=${record.messageId} peerType=${record.peerType}")

                    setSelectedChat(record.peerId, chatName, record.peerType)
                    setSelectedChatDraft("")
                    setSelectedChatUsername("")
                    if (record.messageId > 0) {
                        setNotificationClickMessageId(record.messageId)
                    }
                    pageStack.pushPathByName("ChatRoomPage", chatName)
                    return true
                }

                Hilog.info(0, "CjTelegram", "[NotifClickRouter] navigatePendingClick: record isValid but no action, skip")
                return false
        }
    }
}

// ==================== Message-scroll-to state ====================

/**
 * 通知点击时目标消息 ID（供 ChatRoomPage 初始化时滚动定位）
 *
 * 对应 iOS openChatWhenReady(messageId: MessageId?) 参数
 * ChatRoomPage.aboutToAppear 取此值后 clearNotificationClickMessageId()
 */
private var _notifClickMessageId: Int32 = 0

public func setNotificationClickMessageId(msgId: Int32) {
    _notifClickMessageId = msgId
    Hilog.info(0, "CjTelegram", "[NotifClickRouter] setNotificationClickMessageId: ${msgId}")
}

public func getNotificationClickMessageId(): Int32 { return _notifClickMessageId }

public func clearNotificationClickMessageId() {
    _notifClickMessageId = 0
}

// ==================== URL navigation helper ====================

/**
 * 处理外部 URL 打开
 *
 * 对应 iOS AppDelegate openUrlWhenReady(url, external: true) →
 *   UIApplication.shared.open(url)
 * 鸿蒙侧通过 context.startAbility(Want(action: "ohos.want.action.viewData", uri: url))
 */
private func handleUrlNavigation(url: String) {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            Hilog.info(0, "CjTelegram", "[NotifClickRouter] handleUrlNavigation: opening ${url}")
            try {
                let want = kit_AbilityKit_Want_builder(url)
                ctx.startAbility(want)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[NotifClickRouter] handleUrlNavigation failed: ${e}")
            }
        case None =>
            Hilog.info(0, "CjTelegram", "[NotifClickRouter] handleUrlNavigation: no context, skip")
    }
}

/**
 * 构建用于外部 URL 打开的 Want
 *
 * import kit.AbilityKit.Want 在本包已有 (main_ability.cj) 但 services 包需单独 import
 * → 内联构造，避免跨包引用复杂度
 */
private func kit_AbilityKit_Want_builder(url: String): Want {
    return Want(
        action: "ohos.want.action.viewData",
        uri: url
    )
}
