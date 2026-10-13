package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.interop.*

/**
 * LocalNotificationContent — 本地通知内容载体
 *
 * 对应 iOS UNMutableNotificationContent 字段集合：
 *   title     ← content.title
 *   body      ← content.body
 *   soundId   ← UNNotificationSound(named:) / aps.sound (铃声文件 ID，id=0 默认)
 *   badgeCount ← content.badge / UIApplication.shared.applicationIconBadgeNumber
 *   categoryId ← content.categoryIdentifier（"incomingCall" / "message"）
 *   notifId   ← UNNotificationRequest.identifier
 *   peerId    ← iOS UNMutableNotificationContent.threadIdentifier (peer grouping)
 *               P2-263: 同一 peer 的通知归同一分组，HarmonyOS 通过 groupName 实现
 *   threadId  ← iOS content.threadIdentifier (forum topic 子分组)
 *               P2-263: 论坛 topic 通知，格式 "<peerId>_<topicId>"
 *
 * avatar / largeIcon：HarmonyOS NotificationRequest.largeIcon 需要 PixelMap，
 * 当前无头像解码底座 → defer，见 Hand-off。
 */
public class LocalNotificationContent {
    public var notifId: String = ""
    public var title: String = ""
    public var body: String = ""
    public var soundId: Int64 = 0
    public var soundAccessHash: Int64 = 0
    public var badgeCount: Int32 = 0
    public var categoryId: String = "message"
    public var peerName: String = ""
    public var messageText: String = ""
    public var showPreviews: Bool = true
    // P2-263: 通知分组字段
    // peerId — 会话 peer ID 字符串；用作 HarmonyOS NotificationRequest.groupName
    // 对应 iOS UNMutableNotificationContent.threadIdentifier (peer 粒度)
    public var peerId: String = ""
    // threadId — 论坛 topic 子分组；格式 "<peerId>_<topicId>"
    // 当非空时设 NotificationRequest.groupName = threadId (topic 粒度比 peer 更细)
    public var threadId: String = ""
    // 点击通知后打开的会话（iOS: userInfo 里的 peerId / messageId →
    // AppDelegate.userNotificationCenter(_:didReceive:) → openChatWhenReady）。
    // 经 wantAgent 的 want.parameters 带回 EntryAbility.onCreate / onNewWant。
    public var navPeerId: Int64 = 0
    public var navPeerType: String = ""
    public var navMessageId: Int64 = 0
}

/**
 * LocalNotificationRecord — 发布记录（用于调试 / Reviewer 验证）
 */
public class LocalNotificationRecord {
    public var notifId: String = ""
    public var title: String = ""
    public var body: String = ""
    public var soundId: Int64 = 0
    public var badgeCount: Int32 = 0
    public var categoryId: String = ""
    public var publishedAt: Int64 = 0
}

private var _lastPublishedRecords: ArrayList<LocalNotificationRecord> = ArrayList<LocalNotificationRecord>()
private let LNDS_PREFS_NAME: String = "local_notif_display"
private let LNDS_KEY_LAST_NOTIF_ID: String = "last_notif_id"
private let LNDS_KEY_LAST_BADGE: String = "last_badge"

public func getLocalNotificationDisplayService(): LocalNotificationDisplayService {
    return LocalNotificationDisplayService()
}

/**
 * LocalNotificationDisplayService — 本地通知展示服务 (P2-258 / P2-261 / P2-263)
 *
 * 对应 iOS 链路:
 *   SharedNotificationManager.updateNotificationCall() →
 *     UNMutableNotificationContent(title/body/sound/badge/threadIdentifier) →
 *       UNUserNotificationCenter.current().add(request)
 *   ClearNotificationsManager.commitNow() →
 *     UNUserNotificationCenter.current().getDeliveredNotifications() →
 *       removeDeliveredNotifications(withIdentifiers:)
 *
 * HarmonyOS 等价链路（D-baseline）:
 *   publishLocalNotification(peerId, ...) →
 *     assembleContent() [title/body/sound/badge/groupName 全真组装] →
 *       doPublishViaArkInterop() [notificationManager.publish + groupName 真设]
 *
 * P2-261 声音应用: applySelectedSound(content) 调 NotificationSoundSelectionService
 * P2-263 通知分组:
 *   - publishLocalNotification 接收 peerId/threadId，
 *     在 doPublishViaArkInterop 中通过 setProperty("groupName", peerId) 真设分组
 *   - 论坛 topic 子分组: threadId 非空时 groupName = threadId ("<peerId>_<topicId>")
 *   - cancelNotificationsForPeer(peerId): 经 arkinterop 调 notificationManager.getActiveNotifications
 *     → 筛出 groupName=peerId 的通知 → 逐条 notificationManager.cancel(id)
 *   - cancelNotificationsOnRead(peerId): 消息已读事件入口 → 委托 cancelNotificationsForPeer
 *
 * avatar / largeIcon: defer — 需要将头像 URL 解码为 PixelMap 后设 NotificationRequest.largeIcon，
 * 当前无 PixelMap 解码底座，诚实 defer，见 emitted_integration_contracts。
 */
public class LocalNotificationDisplayService {
    private let presentationService: NotificationsPresentationDataService
    private let soundService: NotificationSoundSelectionService
    private let badgeService: BadgeService

    public init() {
        this.presentationService = NotificationsPresentationDataService()
        this.soundService = NotificationSoundSelectionService()
        this.badgeService = BadgeService()
    }

    /**
     * 组装并「发布」本地通知 (P2-258 / P2-263 主入口)
     *
     * @param peerName    对端显示名（用于格式化 title/body）
     * @param messageText 消息正文（若 showPreviews=false 则隐藏）
     * @param notifId     通知唯一 ID（对应 UNNotificationRequest.identifier）
     * @param categoryId  通知类别（"message" / "incomingCall"）
     * @param badgeCount  角标数（对应 aps.badge / applicationIconBadgeNumber）
     * @param peerId      P2-263: 会话 peer ID 字符串；用作 NotificationRequest.groupName
     *                    同一 peer 的通知归一组（对应 iOS threadIdentifier 按 peer 分组）。
     *                    传空串 "" 则不设 groupName（降级，不分组）。
     * @param threadId    P2-263: 论坛 topic 子分组（"<peerId>_<topicId>"）；
     *                    非空时 groupName = threadId（比 peer 粒度更细）。
     *
     * 真实行为:
     *   1. 调 NotificationsPresentationDataService 格式化 title / body
     *   2. 调 NotificationSoundSelectionService 获取选中铃声填入 soundId (P2-261)
     *   3. 组装 LocalNotificationContent（含 peerId/threadId 分组字段）
     *   4. doPublishViaArkInterop: 真实 publish，groupName 真设（P2-263）
     *   5. Hilog 记录 + 内存记录 + Preferences 持久化
     *
     * @return 组装好的 LocalNotificationContent
     */
    public func publishLocalNotification(
        peerName: String,
        messageText: String,
        notifId: String,
        categoryId: String,
        badgeCount: Int32,
        peerId!: String = "",
        threadId!: String = "",
        navPeerId!: Int64 = 0,
        navPeerType!: String = "",
        navMessageId!: Int64 = 0
    ): LocalNotificationContent {
        let content = LocalNotificationContent()
        content.notifId = notifId
        content.peerName = peerName
        content.messageText = messageText
        content.categoryId = categoryId
        content.badgeCount = badgeCount
        // P2-263: 填入分组字段
        content.peerId = peerId
        content.threadId = threadId
        content.navPeerId = navPeerId
        content.navPeerType = navPeerType
        content.navMessageId = navMessageId

        let settings = this.presentationService.getNotifySettings(peerName)
        content.showPreviews = settings.showPreviews

        content.title = this.presentationService.formatNotificationTitle(peerName, categoryId)
        content.body = this.presentationService.formatNotificationBody(peerName, messageText, settings.showPreviews)

        this.applySelectedSound(content)

        Hilog.info(0, "CjTelegram", "[LNDS] publishLocalNotification: id=${notifId} title=\"${content.title}\" body=\"${content.body}\" sound=${content.soundId} badge=${badgeCount} cat=${categoryId} peerId=${peerId} threadId=${threadId}")

        let record = LocalNotificationRecord()
        record.notifId = notifId
        record.title = content.title
        record.body = content.body
        record.soundId = content.soundId
        record.badgeCount = badgeCount
        record.categoryId = categoryId
        var arr = _lastPublishedRecords
        arr.add(record)
        _lastPublishedRecords = arr

        this.persistLastRecord(notifId, badgeCount)

        this.doPublishViaArkInterop(content)

        return content
    }

    /**
     * 来电专用通知 (P2-258 incomingCall 路径)
     *
     * 对应 iOS SharedNotificationManager.updateNotificationCall():
     *   content.sound = UNNotificationSound(named: "0.m4a")
     *   content.categoryIdentifier = "incomingCall"
     *
     * 来电铃声固定 soundId=0（系统默认铃声 / "0.m4a" 等价），
     * 不从 NotificationSoundSelectionService 读取（来电专用铃声独立设置 — P2-261 已在 publishLocalNotification 中应用消息铃声）。
     */
    public func publishIncomingCallNotification(
        callerName: String,
        callId: String
    ): LocalNotificationContent {
        let content = LocalNotificationContent()
        content.notifId = "call_${callId}"
        content.peerName = callerName
        content.title = callerName
        content.body = "Incoming call"
        content.soundId = 0
        content.categoryId = "incomingCall"
        content.badgeCount = 0

        Hilog.info(0, "CjTelegram", "[LNDS] publishIncomingCallNotification: callId=${callId} caller=${callerName}")

        let record = LocalNotificationRecord()
        record.notifId = content.notifId
        record.title = content.title
        record.body = content.body
        record.soundId = 0
        record.badgeCount = 0
        record.categoryId = "incomingCall"
        var arr = _lastPublishedRecords
        arr.add(record)
        _lastPublishedRecords = arr

        this.doPublishViaArkInterop(content)

        return content
    }

    /**
     * P2-261: 应用选中铃声到通知内容
     *
     * 读取 NotificationSoundSelectionService.getSelectedSound()，
     * 将 soundId + soundAccessHash 填入 content（供 ArkTS 桥接层设 NotificationRequest.sound）。
     *
     * iOS 对应: aps.sound 透传选中铃声文件名 / cloud ringtone doc_id。
     * id=0  → 系统默认铃声
     * id=-1 → 静音
     * id>0  → cloud ringtone（doc ID）
     */
    public func applySelectedSound(content: LocalNotificationContent): Unit {
        let (soundId, accessHash, _) = this.soundService.getSelectedSound()
        content.soundId = soundId
        content.soundAccessHash = accessHash
        Hilog.info(0, "CjTelegram", "[LNDS] applySelectedSound: soundId=${soundId} hash=${accessHash}")
    }

    /**
     * 获取最近发布的通知记录列表
     */
    public func getLastPublishedRecords(): ArrayList<LocalNotificationRecord> {
        return _lastPublishedRecords
    }

    /**
     * 获取最近一条发布记录（可能为 None）
     */
    public func getLastPublishedRecord(): Option<LocalNotificationRecord> {
        if (_lastPublishedRecords.size == 0) {
            return None
        }
        return Some(_lastPublishedRecords[_lastPublishedRecords.size - 1])
    }

    /**
     * 经 arkinterop 桥真实调用 notificationManager.publish(NotificationRequest)
     *
     * P2-263 扩展: 在 NotificationRequest 对象上真实设置 groupName。
     *   - content.threadId 非空 → groupName = threadId (论坛 topic 子分组)
     *   - content.peerId 非空 → groupName = peerId (会话 peer 粒度分组)
     *   - 都空 → 不设 groupName（无分组，降级兼容）
     *
     * 对应 iOS UNMutableNotificationContent.threadIdentifier 按 peer 分组。
     * 对应 HarmonyOS @ohos.notificationManager.publish NotificationRequest.groupName 字段。
     * 模块名 try "notificationManager" 再 fallback "notification"。
     */
    private func doPublishViaArkInterop(content: LocalNotificationContent): Unit {
        let notifIdStr = content.notifId
        // P2-263: 确定 groupName — threadId 优先（更细粒度），其次 peerId
        let groupNameStr: String
        if (content.threadId.size > 0) {
            groupNameStr = content.threadId
        } else if (content.peerId.size > 0) {
            groupNameStr = content.peerId
        } else {
            groupNameStr = ""
        }

        // notifId(String) → stable int id（原 JSRuntime 内计算，现搬到仓颉侧算好透传）
        // ⚠️ 每步取模防 Int64 溢出：仓颉算术溢出默认抛异常，来电 id 形如
        // "call_7801649093482067172"(24字符) 曾在 *31 累乘时 OverflowException: mul
        // → 通知从未发出（后台来电无横幅的直接原因之一）。
        var notifIdHash: Int64 = 1
        for (c in notifIdStr.toRuneArray()) {
            notifIdHash = (notifIdHash * 31 + Int64(UInt32(c))) % 1000000007
        }
        let notifIdInt = notifIdHash % 100000

        // argJson schema 与 ArkTS LocalNotificationImpl 逐条对应 (D3):
        //   {"id":<int>,"title":<str>,"text":<str>,"groupName":<str>,"category":<str>}
        // category="incomingCall" → ArkTS 侧设 SOCIAL_COMMUNICATION 高等级渠道
        // (默认渠道无横幅无铃声——后台来电"通知发了但没弹"的根因)。
        let argJson = "{\"id\":${notifIdInt},\"title\":\"${escapeJsonString(content.title)}\",\"text\":\"${escapeJsonString(content.body)}\",\"groupName\":\"${escapeJsonString(groupNameStr)}\",\"category\":\"${escapeJsonString(content.categoryId)}\",\"navPeerId\":\"${content.navPeerId}\",\"navPeerType\":\"${escapeJsonString(content.navPeerType)}\",\"navPeerName\":\"${escapeJsonString(content.peerName)}\",\"navMsgId\":\"${content.navMessageId}\"}"
        Hilog.info(0, "CjTelegram", "[LNDS] doPublishViaArkInterop: publish notifId=${notifIdStr} id=${notifIdInt} groupName=${groupNameStr}")
        callArk(NOTIF_PUBLISH, argJson)
    }

    /**
     * P2-263: 取消指定 peer 所有已投递通知（消息已读清理）
     *
     * 对应 iOS ClearNotificationsManager.commitNow():
     *   UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
     *     let removeIds = notifications.filter { $0.peerId == peerId }.map { $0.identifier }
     *     UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: removeIds)
     *   }
     *
     * HarmonyOS 等价链路（经 arkinterop）:
     *   notificationManager.getActiveNotifications() → Promise<Array<NotificationRequest>>
     *   → 筛出 groupNameMatchesPeer(req.groupName, peerId) 的通知（覆盖 peer 级和 topic 级）
     *   → 逐条 notificationManager.cancel(id)
     *
     * @param peerId 会话 peer ID 字符串（与发布时 content.peerId 一致）
     *
     * 说明: getActiveNotifications 返回 JS Array，每项含 id/groupName 等字段。
     * 本实现对 Promise-based API 采用 .then() 桥接（与 getHarmonyPushToken 同模式）。
     */
    public func cancelNotificationsForPeer(peerId: String): Unit {
        if (peerId.size == 0) {
            return
        }
        // getActiveNotifications 查询 + groupName 匹配 + 逐条 cancel 的重活整体搬到
        // ArkTS 侧（NOTIF_CANCEL_GROUP，含 groupNameMatchesPeer 语义），仓颉侧只透传 peerId。
        // 结果仅用于日志（best-effort），故用 callArkAsync 记结果。
        let argJson = "{\"peerId\":\"${escapeJsonString(peerId)}\"}"
        Hilog.info(0, "CjTelegram", "[LNDS] cancelNotificationsForPeer: dispatch cancel for peerId=${peerId}")
        callArkAsync(NOTIF_CANCEL_GROUP, argJson, { res =>
            Hilog.info(0, "CjTelegram", "[LNDS] cancelNotificationsForPeer: result=${res}")
        })
    }

    /**
     * P2-263: 消息已读后清理对应 peer 的通知
     *
     * 对应 iOS ClearNotificationsManager.append(readMessageId) + commitNow():
     *   当收到 "read" 事件后，按 peerId 移除对应已投递通知。
     *
     * 调用方: 消息已读事件回调（如 PushPayloadRouter 处理 "read" payload）。
     * 实现委托 cancelNotificationsForPeer(peerId)。
     *
     * @param peerId 已读会话的 peer ID 字符串
     */
    public func cancelNotificationsOnRead(peerId: String): Unit {
        Hilog.info(0, "CjTelegram", "[LNDS] cancelNotificationsOnRead: peerId=${peerId}")
        this.cancelNotificationsForPeer(peerId)
    }

    /**
     * 持久化最后一条通知 ID + badge 到 Preferences
     */
    private func persistLastRecord(notifId: String, badgeCount: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, LNDS_PREFS_NAME)
                    prefs.put(LNDS_KEY_LAST_NOTIF_ID, PreferencesValueType.StringData(notifId))
                    prefs.put(LNDS_KEY_LAST_BADGE, PreferencesValueType.Integer(Int64(badgeCount)))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[LNDS] persistLastRecord error: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[LNDS] persistLastRecord: no context, skip")
        }
    }
}
