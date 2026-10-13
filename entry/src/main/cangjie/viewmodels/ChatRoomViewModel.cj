package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.collection.*
import std.sync.*
import std.time.DateTime
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.utils.{parseMarkdown, textFormatSelfCheck, copyText, isSingleEmoji}
import kit.CoreFileKit.*

/** PresentationStrings formats peer counters with locale grouping in iOS. */
func formatChatPeerCount(count: Int32): String {
    let digits = "${count}"
    var result = ""
    var index: Int64 = 0
    while (index < digits.size) {
        let remaining = digits.size - index
        if (index > 0 && remaining % 3 == 0) { result = result + "," }
        result = result + digits[index..index + 1]
        index += 1
    }
    return result
}

/** 输入框中的一个 Custom Emoji span，同时保留本地 Rune 与 Telegram UTF-16 坐标。 */
public class CustomEmojiDraftEntity {
    public var runeOffset: Int32 = 0
    public var runeLength: Int32 = 0
    public var utf16Offset: Int32 = 0
    public var utf16Length: Int32 = 0
    public var documentId: Int64 = 0
    public var alt: String = ""
    public init() {}
}

/**
 * WP-D (S2-18/19/24): a formatting entity collected from the composer's RichEditor spans.
 * entityType uses the same bare strings MessageBubble.buildTextSegments consumes
 * ("bold" / "italic" / "underline" / "strike" / "code" / "pre" / "spoiler" / "blockquote" / "textUrl");
 * rune* offsets feed the local bubble, utf16* offsets feed the TL MessageEntity (Telegram counts
 * UTF-16 code units).
 */
public class DraftFormatEntity {
    public var entityType: String = ""
    public var runeOffset: Int32 = 0
    public var runeLength: Int32 = 0
    public var utf16Offset: Int32 = 0
    public var utf16Length: Int32 = 0
    public var url: String = ""
    public init() {}
}

/**
 * 聊天详情 ViewModel（Phase A5 增强版）
 * 
 * 对应 TelegramHarmony ChatViewModel.ets (457 行)
 * 
 * 新增功能:
 * - 新消息轮询（3s 间隔）— 实时显示新消息
 * - 回复消息状态管理，
 * - 编辑消息状态管理
 * - 服务端删除消息
 * - 服务端编辑消息
 * - 服务端转发消息
 */
@Observed
public class ChatRoomViewModel {

    /**
     * 服务端刷新时保留本地失败消息（对齐 iOS：失败消息留在列表带失败标记，可重试/删除）。
     * 此前任何一次轮询/刷新都用服务端历史整体覆盖 messageList，本地 status="failed"
     * 的气泡随即消失——用户看到「消息发不出去而且还不见了」（实测 PEER_FLOOD）。
     */
    private func mergeFailedLocals(fresh: ArrayList<Message>): ArrayList<Message> {
        // 单一事实源 = FailedMessageStore：失败消息跨页面和进程重启保留。
        let failed = failedStoreGet(this.chatId)
        if (failed.size == 0) { return fresh }
        var merged = ArrayList<Message>()
        for (m in fresh) { merged.add(m) }
        for (f in failed) {
            // 恢复本地 id 后推进计数器，避免重启后的新消息复用相同 id。
            if (f.id > this.messageIdCounter) { this.messageIdCounter = f.id }

            // iOS Postbox orders history by MessageIndex:
            // timestamp → namespace → id. Cloud namespace is 0 and Local is 1,
            // therefore a failed local message belongs at its original timestamp
            // (after cloud messages from the same second), not unconditionally at
            // the newest edge of every refreshed history snapshot.
            let updated = ArrayList<Message>()
            var inserted = false
            for (existing in merged) {
                if (!inserted) {
                    let comesBefore = existing.rawTimestamp > f.rawTimestamp ||
                        (existing.rawTimestamp == f.rawTimestamp &&
                            existing.status == "failed" && existing.id > f.id)
                    if (comesBefore) {
                        updated.add(f)
                        inserted = true
                    }
                }
                updated.add(existing)
            }
            if (!inserted) { updated.add(f) }
            merged = updated
        }
        return merged
    }

    /**
     * 所有发送类型统一的失败入口。
     *
     * 旧实现只有纯文本路径调用 failedStoreAdd；媒体、投票、联系人和位置消息仅修改
     * 内存 status，轮询或重启后必然消失。统一入口保证状态、落盘和 UI 刷新不可分离。
     */
    private func markMessageFailed(message: Message): Unit {
        // Message 是刻意保持非 @Observed 的纯数据对象，后台线程可先写失败状态；
        // 真正的 @Publish messageList 替换必须立即调度到 UIThread。此前先同步写
        // Preferences，再用普通 launch 刷新，磁盘 IO 会延迟失败图标且线程语义不明确。
        message.status = "failed"
        spawn(UIThread) {
            =>
            // 上一行已原地把 status 置为 failed（不影响排序键），只需重发快照。
            this.refreshMessageSnapshot()
        }
        // 当前发送 worker 保持 polling paused 直到落盘完成，避免历史刷新抢在失败消息
        // 进入 FailedMessageStore 之前覆盖本地消息；UI 刷新与落盘并行，不再互相阻塞。
        failedStoreAdd(this.chatId, this.chatName, message)
    }

    /**
     * 为本地生成的消息写入 iOS StoreMessage.timestamp 等价值。
     *
     * iOS 在 enqueue transaction 内取 network.context.globalTime()，消息进入发送队列前
     * 就已有真实 Unix 秒；UI 时间只是该时间戳的本地时区格式化结果。
     */
    private func stampLocalMessage(message: Message): Unit {
        let timestamp = DateTime.now().toUnixTimeStamp().toSeconds()
        message.rawTimestamp = timestamp
        message.time = formatMessageTime(timestamp)
        // 本地待发消息落 Local 命名空间。对齐 iOS Namespaces.Message.Local = 1
        // (SyncCore_Namespaces.swift:7)：同一秒内它必须排在已收云消息之后，
        // 而本地 id（计数器，初值 100）比服务端 id（≈1100）小，靠 id 排会排反。
        message.namespace = MessageHistoryView.NS_LOCAL
    }
    // ==================== 基础状态 ====================
    
    @Publish public var chatId: Int64 = 0
    @Publish public var chatName: String = ""
    @Publish public var peerType: String = "user"
    // 群作者角色缓存。历史刷新和推送都从这里补齐 iOS authorRank。
    private var senderRoleById: HashMap<Int64, String> = HashMap<Int64, String>()
    /**
     * 消息列表 —— **只读对外**。写入一律经 this.history 的算子。
     *
     * 结构（对齐 iOS）：
     *   权威有序容器  services/MessageHistoryView（= iOS OrderedHistoryViewEntries）
     *        ↓ onChanged 回调（= iOS ValuePipe.putNext）
     *   _messageList  仅作渲染镜像，唯一写者是 bindHistory 里的 launch{}（= UI 线程串行）
     *        ↓ prop
     *   messageList   对外只读快照
     *
     * 为什么必须这么拆：private 不限制**同类内部**访问，而原先 46 个写入点全在本类体内，
     * 单靠给字段加 private 挡不住它们。把权威状态搬到另一个类另一个文件后，
     * 外部直写会被编译器拒绝（实测：跨文件写私有字段报 can not access field）。
     *
     * @Publish + private 的合法性已实测（PROBE-V1 PASS）：宏展开为
     *   mut private prop _messageList { get/set }，private 被完整保留。
     */
    @Publish private var _messageList: ArrayList<Message> = ArrayList<Message>()

    public prop messageList: ArrayList<Message> {
        get() {
            return this._messageList
        }
    }

    /**
     * 权威有序容器。@Observed 禁止自定义构造函数（宏会自己生成带命名参数的 init，
     * 见 cj-macro-observed-and-publish.md:145），故此处先以 peerId=0 建好，
     * 进入具体会话时由 bindHistory 重绑。
     */
    private let history: MessageHistoryView = MessageHistoryView(peerId: 0)

    /**
     * 把一批历史消息**合并**进权威容器（已存在的按 identityKey 原地更新，新的有序插入）。
     *
     * ⚠️ 曾名 `setMessageList`，实现是 `history.replaceAll` —— 整表替换。已改，原因：
     *
     * `getHistory(limit: 30)` 只取最新 30 条，用它整表替换会**抹掉容器里更早的历史**。
     * 真机实测（`[RENDER-DBG]` count 序列 `30 → 50 → 30`）：
     *   ① 进会话先本地秒开 30 条（`loadMessages` 的 `insertMany(fromStore)`）
     *   ② 首屏尚未滚到底 → `onReachStart` 触发 `loadMoreHistory()` → `prependAll` 补 20 条更早历史，count=50
     *   ③ 网络 `getHistory(30)` 返回 → `replaceAll` → **刚补的 20 条被全部抹掉**，count 掉回 30
     * 后果不止列表变短：长度剧变还会把滚动位置带偏（进会话不停在底部），
     * 并触发大批组件回收/复用，是 `@Reusable` 落地后偶发「空气泡」的怀疑源头。
     *
     * 关于删除同步：`replaceAll` 唯一的额外语义是「服务端没返回的就删掉」，但它
     *   (a) 只覆盖最新 30 条，更早的删除本来就管不着；
     *   (b) 会误删 `prependAll` 合法加载的更早历史 —— 弊远大于利。
     * 删除走显式路径（`onDeleteMessages` / `deleteMessage` → `history.remove`），
     * 这也是 iOS 的做法：Postbox history view 由 `ViewTracker` 增量维护，
     * 删除经 `MessageHistoryTable` 的删除操作下发，而非整表替换。
     */
    private func mergeMessageList(items: ArrayList<Message>): Unit {
        let _ = this.history.insertMany(items)
    }

    /**
     * 重新发布当前快照 —— 用于「Message 对象字段被原地改动、但列表结构未变」的场景
     * （语音波形重绘、图片/文档下载回填等）。
     *
     * 不动权威容器，只重新推一次镜像。Message 是引用类型，原地改动已经生效，
     * 这里只是让 @Publish 观察到一个新的 ArrayList 实例从而触发重绘。
     *
     * 对齐 iOS：view 的条目内容变化同样经 pipe.putNext 推给订阅方
     * （ViewTracker.swift:235/330），而不是让调用方自己去改 view 的存储。
     *
     * 取代原先 ChatRoomPage.refreshMessageListForVoice 里的
     * `this.viewModel.messageList = updatedList` —— 那是唯一一处跨类直写，
     * 字段私有化后已被编译器拒绝。
     */
    public func refreshMessageSnapshot(): Unit {
        this.publishSnapshot()
    }

    /**
     * 媒体本地路径回填的**唯一入口**：落缓存 + 回填全部引用该资源的消息 + 推送。
     *
     * 为什么必须收口：Message 是非 @Observed 的纯数据对象，原地改字段不会触发任何 UI 更新。
     * 改造前靠 ChatRoomPage 每 500ms 的指纹轮询（内含 photoCount/docCount）兜底；批 3 删掉
     * 轮询后这条路断了，表现为图片下载完成落盘（实测 T+2.27s）却要 10-15 秒才上屏 ——
     * 期间只能等下一次偶然推送（10s 轮询的 replaceAll 或滑动分页）。
     *
     * 此前回填散落在 5 条下载链路、共 30+ 处直写字段，每一处都要人工记得推送，必然遗漏。
     * 收敛到本函数后，推送与回填不可分离；新增媒体类型也走它。
     *
     * 对齐 iOS 的取舍说明：iOS 的媒体可用性根本不在 Message 上 —— UI 节点各自订阅
     * MediaBox.resourceData(id)（Postbox/Sources/MediaBox.swift:731，51 个调用方），
     * 资源到位只更新那一个节点，Message 从不改变。仓颉无法照搬：没有节点级订阅
     * （混合工程不支持 @Reusable、无 Repeat、Image 不能绑定可观察流），
     * 所有刷新都必须经列表 key，而 MessageEntry.toString() 里正含这些路径字段。
     * 故路径保留在 Message 上，只把「写入必带推送」这条纪律搬过来。
     *
     * @param target     本次下载直接对应的消息（可能尚未进入 history，需单独回填）
     * @param resourceId photoId / documentId / webPagePhotoId
     * @param localUri   "file://" 开头的本地路径
     * @param kind       photo | doc | docThumb | webPhoto
     */
    private func applyMediaPath(target: Message, resourceId: Int64, localUri: String, kind: String,
                               clearDownloading!: Bool = false): Unit {
        // docThumb 不写缓存：photoPathCache 按 resourceId 单键存储，分不出真身和
        // 缩略图，而 RealMessageService.parseHistory 恢复时一律灌进 documentLocalPath。
        // GIF 黑框的根源就在这条链上——缩略图 jpg 进了缓存，每次解析历史都回灌成
        // documentLocalPath，气泡把 jpg 喂给 Video 组件，真 mp4 又因为
        // 「documentLocalPath 非空」永远不下载。缩略图本来就能从磁盘检查循环重建，
        // 不需要缓存。
        // Message objects delivered by UpdatesManager are shared by every live
        // ChatRoomViewModel subscriber. When another room fills the path first,
        // assignMediaPath() below sees "no change" here and this room would never
        // publish, leaving its bubble on the placeholder. The per-room cache tells
        // whether *this* room has already published the path.
        var changed = kind != "docThumb" &&
            !(this.photoPathCache.contains(resourceId) && this.photoPathCache[resourceId] == localUri)
        if (kind != "docThumb") {
            this.photoPathCache[resourceId] = localUri
        }
        if (this.assignMediaPath(target, localUri, kind)) { changed = true }
        if (clearDownloading && target.isFileDownloading) {
            target.isFileDownloading = false
            changed = true
        }
        for (m in this.history.items) {
            var matches = false
            if (kind == "photo") {
                matches = m.photoId == resourceId
            } else if (kind == "webPhoto") {
                matches = m.webPagePhotoId == resourceId
            } else {
                matches = m.documentId == resourceId
            }
            if (matches) {
                if (this.assignMediaPath(m, localUri, kind)) { changed = true }
                if (clearDownloading && m.isFileDownloading) {
                    m.isFileDownloading = false
                    changed = true
                }
            }
        }
        if (changed) {
            this.refreshMessageSnapshot()
            // Keep the local message/resource association durable. Storage Usage derives
            // its per-chat rows from the same persisted message index as Telegram-iOS'
            // MediaBox usage index; without this write, a downloaded path existed only in
            // the mounted room model and disappeared from storage statistics after exit.
            if (this.chatId != 0) {
                let persisted = ArrayList<Message>()
                persisted.add(target)
                getMessageHistoryStore().storeMessages(
                    this.chatId, persisted, peerType: this.peerType)
            }
        }
    }

    /** 按 kind 写入路径字段；返回 true 表示确实发生了变化。媒体路径不参与排序键。 */
    private func assignMediaPath(m: Message, localUri: String, kind: String): Bool {
        if (kind == "photo") {
            if (m.photoLocalPath == localUri) { return false }
            m.photoLocalPath = localUri
            return true
        }
        if (kind == "webPhoto") {
            if (m.webPagePhotoLocalPath == localUri) { return false }
            m.webPagePhotoLocalPath = localUri
            return true
        }
        if (kind == "docThumb") {
            // 只写 documentThumbnailPath。此前这里连 documentLocalPath 一起写，
            // 「缩略图下载完成」被下游当成「文件已下载」：GIF 气泡把 jpg 喂给
            // Video（黑框），真 mp4 的下载门卫（documentLocalPath.isEmpty()）也被
            // 永久堵死。文档气泡的预览读的是 documentThumbnailPath，不受影响。
            if (m.documentThumbnailPath == localUri) { return false }
            m.documentThumbnailPath = localUri
            return true
        }
        if (m.documentLocalPath == localUri) { return false }
        m.documentLocalPath = localUri
        return true
    }

    /**
     * Pick the concrete photo representation used by a chat bubble.
     *
     * This is Harmony's flattened equivalent of iOS' persisted
     * TelegramMediaImageRepresentation.resource: prefer y for y/w photos, otherwise use the
     * largest type that was actually present in the TL object. Empty is legacy-cache fallback.
     */
    private func photoBubbleType(m: Message): String {
        let largestType = m.photoLargestType
        return if (largestType == "y" || largestType == "w") {
            "y"
        } else if (largestType.size > 0) {
            largestType
        } else {
            "y"
        }
    }

    /** 只有非空文件才可作为媒体缓存；中断写入留下的 0-byte 文件必须重新下载。 */
    private func usableMediaFile(path: String): Bool {
        try {
            return FileIo.access(path) && FileIo.stat(path).size > 0
        } catch (_e: Exception) {
            return false
        }
    }
    @Publish public var inputText: String = ""
    @Publish public var isLoading: Bool = false
    @Publish public var hasMoreHistory: Bool = true
    // P2-112: 向下分页（有比当前最新消息更新的消息存在）
    @Publish public var hasMoreNewer: Bool = false
    /**
     * 初始历史加载是否已定案。
     *
     * loadMessages 会推送**三次**：失败消息 → 本地缓存秒开 → 网络结果，
     * 而 firstUnreadId 只在最后一次才有值。页面的「首帧滚动到未读锚点」若在
     * 前两次推送时就锁定，锚点必然落空（实测：进入会话不稳定停在锚点/底部）。
     * 本标志让页面知道「现在的 firstUnreadId 才是最终值」。
     */
    @Publish public var initialLoadDone: Bool = false

    // P2-112: 未读锚点（第一条未读消息 id）；0 = 全部已读或未知
    @Publish public var firstUnreadId: Int64 = 0
    // P2-112: 未读总数（来自 dialog readInboxMaxId 对比）
    @Publish public var unreadCountForAnchor: Int32 = 0
    // P2-112: 是否正在加载更新的消息（向下翻页）
    @Publish public var isLoadingNewer: Bool = false
    @Publish public var currentUserId: Int64 = 1
    
    // ==================== Phase A5: 回复状态 ====================

    // 正在回复的消息 ID（0 = 非回复模式）
    @Publish public var replyToMsgId: Int64 = 0
    // 回复预览文本
    @Publish public var replyToText: String = ""
    // 回复预览发送者名称
    @Publish public var replyToSenderName: String = ""
    // P2-115: quote reply — 引用文本（来自消息内容，随 inputReplyToMessage 一起发送）
    @Publish public var replyQuoteText: String = ""
    // P2-115: quote reply offset（字符偏移量，0 表示从头引用）
    public var replyQuoteOffset: Int32 = 0
    
    // ==================== Phase A5: 编辑状态 ====================
    
    // 正在编辑的消息 ID（0 = 非编辑模式）
    @Publish public var editingMsgId: Int64 = 0
    // 编辑中的原始文本
    @Publish public var editingOriginalText: String = ""
    
    // ==================== Phase Q10: 置顶消息 ====================

    @Publish public var pinnedMessageId: Int64 = 0
    @Publish public var pinnedMessageText: String = ""

    // ==================== P2-122: 多条置顶轮播 ====================

    // 所有置顶消息 ID（来自服务端 messages.search filter=InputMessagesFilterPinned）
    @Publish public var pinnedMessageIds: ArrayList<Int64> = ArrayList<Int64>()
    // 对应文案
    @Publish public var pinnedMessageTexts: ArrayList<String> = ArrayList<String>()
    // 当前显示的置顶序号（循环，0-based）
    @Publish public var currentPinnedIndex: Int32 = 0

    // ==================== P2-121: 副标题（presence / 群人数） ====================

    // 当前对话副标题（"online" / "last seen X ago" / "N members, M online" / "N subscribers"）
    @Publish public var subtitleText: String = ""
    // 是否当前有 typing 指示（由 typing handler 驱动，优先级高于 subtitleText）
    @Publish public var typingText: String = ""

    // ==================== OOM 修复: presence 定时刷新只重算文案，不再重发网络请求 ====================
    // 缓存最近一次从服务端拿到的 presence 原始字段，供定时刷新回调复用（不发 RPC）
    private var _lastPresenceIsOnline: Bool = false
    private var _lastPresenceWasOnline: Int32 = 0
    private var _lastPresenceStatusType: String = ""
    // 是否已经成功拿到过一次 presence 原始数据（避免定时回调在首次数据到达前空转）
    private var _presenceDataLoaded: Bool = false

    // ==================== P2-116: Reactor 列表状态 ====================

    // 当前显示的 reactor 列表（点击 reaction 计数后异步拉取）
    @Publish public var reactorsList: ArrayList<ReactorInfo> = ArrayList<ReactorInfo>()
    // 对应的消息 ID（0 = 未选中）
    @Publish public var reactorsListMsgId: Int64 = 0

    // ==================== P2-118: 已读参与者列表状态 ====================

    // 群消息已读参与者列表（长按勾/双击已读态时拉取）
    @Publish public var readParticipantsList: ArrayList<ReadParticipantRecord> = ArrayList<ReadParticipantRecord>()
    // 对应的消息 ID（0 = 未选中）
    @Publish public var readParticipantsMsgId: Int64 = 0

    // ==================== P2-117: 已读上报节流 ====================

    // 可见区已读上报的最大 msgId（防重复上报）
    private var _lastReportedReadId: Int32 = 0

    // ==================== 内部状态（非 @Publish）====================

    private var messageIdCounter: Int64 = 100
    public var scrollerRef: Option<Scroller> = None
    
    // Phase A5: 轮询控制
    private var _pollingActive: Bool = false
    // stop/start 可能发生在旧循环的 10s sleep 内；仅 Bool 会让旧循环在返回后“复活”。
    // 代次令牌确保每次 resume 只有最新循环可以继续。
    private var _pollingGeneration: Int64 = 0
    // 媒体资源订阅拥有独立生命周期，不能依附 10s 备用消息轮询。iOS 的 MediaBox
    // resourceData subscription 与 history polling 也是两条独立管线。
    private var _mediaActive: Bool = false
    private var _mediaGeneration: Int64 = 0
    // 暂停标志：sendMessage 等操作使用 MTProto 时设为 true，polling 暂停等待
    private var _pollingPaused: Bool = false
    // 轮询忙标志：在实际执行 MTProto 请求期间为 true
    // onBackPressed 需等待此标志为 false，避免并发 MTProto 访问
    private var _pollingBusy: Bool = false
    private var _reactionAvatarCallbackRegistered: Bool = false
    private var _pushSubscriptionToken: Int64 = -1
    private var _editSubscriptionToken: Int64 = -1
    private var _deleteSubscriptionToken: Int64 = -1
    private var _reactionSubscriptionToken: Int64 = -1
    private var _readOutboxSubscriptionToken: Int64 = -1
    
    // 照片路径缓存：photoId → "file://..." 路径
    // 避免 polling 创建新 Message 对象时丢失已下载的 photoLocalPath
    private var photoPathCache: HashMap<Int64, String> = HashMap<Int64, String>()
    
    // Phase P5-11: 对方已读到的最大消息 ID（用于蓝色双勾显示）
    private var _readOutboxMaxId: Int32 = 0

    // P2-119 r1: 两阶段举报 — 缓存服务端返回的 option bytes（与 UI 侧 reportOptionTexts 下标对应）
    private var _reportPendingOptionBytes: ArrayList<Array<Byte>> = ArrayList<Array<Byte>>()

    // ==================== P2-120: 慢速模式 / 发送限制 / 拦截状态 ====================

    /** 慢速模式超时秒数（0 = 未启用，> 0 = 每条消息间隔秒数） */
    @Publish public var slowmodeTimeoutSeconds: Int32 = 0

    /**
     * 下次允许发送的 Unix 时间戳（秒）；0 = 无等待。
     * 由两种路径写入:
     *   1. loadChatPermissions() 从 channelFull 解析（若服务端携带 slowmode_next_send_date）
     *   2. sendMessage() 收到 SLOWMODE_WAIT error 时按当前时间 + 剩余秒数估算
     */
    @Publish public var slowmodeNextSendTimestamp: Int64 = 0

    /** 当前用户在该群/频道是否被限制发言（defaultBannedRights.send_messages = true 且非管理员） */
    @Publish public var isRestrictedSendMsg: Bool = false

    /**
     * 当前用户是否将对方（私聊）加入了黑名单（contacts.block 过）。
     * true → 在输入区显示 "Unblock" 按钮，点击调用 unblockPeer()。
     */
    @Publish public var hasBlockedPeer: Bool = false

    /**
     * E5：当前账号未加入的频道 / 超级群（channel.left）。对位 iOS
     * ChatChannelSubscriberInputPanelNode.actionForPeer 的 participationStatus == .left 分支：
     * 输入区换成 Join 按钮。由 getHistory 响应里的 channel 对象权威回填。
     */
    public var channelJoinRequired: Bool = false
    /** channel.join_request（flags.29）：超级群需审批，iOS 显示 Group.ApplyToJoin。 */
    public var channelJoinRequestNeeded: Bool = false
    /** channel.broadcast（flags.5）：区分 "Join"（频道）与 "Join Group"（超级群）。 */
    public var channelIsBroadcast: Bool = false
    /**
     * S5-04: channelFull.linked_chat_id（iOS CachedChannelData.linkedDiscussionPeerId）。
     * 超级群上非 0 = 这是某频道的讨论群；频道上非 0 = 它有讨论群。由 loadChatPermissions 回填。
     */
    public var linkedChatId: Int64 = 0
    
    /**
     * 查询轮询是否正在执行 MTProto 请求
     * onBackPressed 使用此方法等待轮询完成后再执行 markAsRead / getDialogs
     */
    public func isPollingBusy(): Bool {
        return this._pollingBusy
    }
    
    // ==================== 初始化 ====================

    /**
     * 绑定/重绑权威容器到当前会话，并接上变更推送。
     *
     * 推送链路对齐 iOS：MessageHistoryView 不认识 UI（不 import ArkUI、不调 launch），
     * 主线程投递由本层负责 —— 等价于 iOS 的 deliverOnMainQueue。
     * launch{} 是唯一写 _messageList 的地方，因此渲染镜像天然单写者、无竞态
     * （kb.py《线程控制》：launch 将任务提交到主线程执行）。
     */
    private func bindHistory(chatId: Int64): Unit {
        this.resetMigratedHistory()
        this.history.rebind(peerId: chatId)
        this.history.setOnChanged({ => this.publishSnapshot() })
    }

    /**
     * 视图变更订阅者（当前只有 ChatRoomPage）。
     *
     * 对齐 iOS ValuePipe 的订阅端：Postbox 每次 transaction 提交后由 ViewTracker
     * 把新视图 putNext 给所有订阅方（ViewTracker.swift:235/330），UI 不去轮询。
     *
     * 取代 ChatRoomPage.startMessageSync 原先的 500ms 指纹轮询 —— 那种写法要求
     * 维护一份「哪些字段算变化」的清单，漏一个字段就漏一类刷新
     * （实测：指纹不含 content，导致对方编辑消息后本端不刷新，必须滑动分页才显现）。
     * 事件驱动没有这个失效模式：容器一变就通知，无需枚举字段。
     */
    private var _onMessagesChanged: Option<() -> Unit> = None

    public func setMessagesChangedHandler(handler: () -> Unit): Unit {
        this._onMessagesChanged = Some(handler)
    }

    public func clearMessagesChangedHandler(): Unit {
        this._onMessagesChanged = None
    }

    /**
     * 把权威容器的当前快照投递到 UI 线程：先更新渲染镜像，再通知订阅方。
     * 顺序不能颠倒 —— 订阅方回调里会读 messageList。
     */
    private func publishSnapshot(): Unit {
        // 显示列表不变量（断言级）：按 (timestamp, namespace, id) 严格升序、按 id 去重。
        // 违例说明有写入绕过了 MessageHistoryView 的算子——记录下来并兜底重排，
        // 绝不把乱序/重复的列表交给页面（对齐 iOS fixMonotony 的断言兜底）。
        let orderViolations = this.history.checkAndFixMonotony()
        if (orderViolations > 0) {
            Hilog.error(0, "CjTelegram",
                "[HistoryOrder] display list violated (timestamp,id) order/uniqueness: ${orderViolations} violation(s), repaired for peer=${this.chatId}")
        }
        // iOS ChatHistoryEntriesForView.swift:230：群升级服务消息（channelMigratedFromGroup /
        // groupMigratedToChannel）留在历史里但不产出列表条目 —— 不能渲染成 "Service message"。
        let snapshot = ArrayList<Message>()
        for (m in this.history.items) {
            if (!m.hiddenInHistory) { snapshot.add(m) }
        }
        // 已读态在 iOS 是**渲染期推导**、不存在消息对象上：history view 每次产出条目时用
        // readState.isOutgoingMessageIndexRead(index) 现算（MessageHistoryView.swift:1377-1388）。
        // 这里同样在每次发布快照时重算，于是「消息入列」与「已读回执到达」谁先谁后都不影响结果。
        // 此前只在收到回执时扫一遍渲染镜像 _messageList，而镜像的唯一写者是 UI 线程的
        // launch{}，回执线程读到的常常还不含刚发出的那条 —— 表现为「只有上一条变双勾、
        // 最新一条不变」。
        this.applyReadOutboxStatusToMessages(snapshot)
        launch {
            this._messageList = snapshot
            match (this._onMessagesChanged) {
                case Some(h) => h()
                case None => ()
            }
        }
    }

    public func initChatRoom(chatId: Int64, chatName: String) {
        this.bindHistory(chatId)
        this.chatId = chatId
        this.chatName = chatName
        this.loadMessages()
    }

    /**
     * 只读预览入口 —— 对应 iOS 的 makeChatController(mode: .standard(.previewing))
     * 且 canReadHistory.set(false)（ChatListController.swift:1932-1934）。
     *
     * 与 initChatRoomWithPeer 的差别是**只做减法**，复用同一套历史机制：
     *   保留：bindHistory（权威容器，按 id 去重定序）
     *         activateMediaPipeline（媒体令牌，逐实例独立，不与主聊天页互抢）
     *         loadMessages（本地秒开 + 媒体回填 + 后台网络刷新）
     *         loadMoreHistory（向上翻页）
     *   去掉：startPolling / registerChatRoomUpdateHandlers / registerReadOutboxHandler
     *         / registerMessageReactionsHandler / markAsRead
     *
     * 「预览不产生已读」因此是结构性保证：这条路径根本没有注册回执、也不会上报，
     * 而不是靠调用方记得别调 markAsRead。
     */
    public func initPreview(chatId: Int64, chatName: String, peerType: String): Unit {
        this.bindHistory(chatId)
        this.senderRoleById = HashMap<Int64, String>()
        this.chatId = chatId
        this.chatName = chatName
        this.peerType = peerType
        let realUserId = getCurrentUserId()
        if (realUserId != 0) {
            this.currentUserId = realUserId
        }
        this._readOutboxMaxId = getReadOutboxMaxId(peerType, chatId)
        this.activateMediaPipeline()
        this.loadMessages()
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] preview opened peer=${peerType}/${chatId} (no polling, no read receipts)")
    }

    /** 预览关闭：停掉媒体任务并清空容器，避免下次长按看到上一个会话的残留 */
    public func cleanupPreview(): Unit {
        this.clearMessagesChangedHandler()
        this.suspendMediaPipeline()
        this.history.clear()
    }

    // S4-13: Clear History from PeerInfo / chat list → drop the local view at once.
    private var _historyListenerToken: Int64 = 0

    private func subscribeHistoryCleared(): Unit {
        let svc = getRealMessageService()
        if (this._historyListenerToken != 0) { svc.removeHistoryChangedListener(this._historyListenerToken) }
        this._historyListenerToken = DateTime.now().toUnixTimeStamp().toNanoseconds()
        svc.addHistoryChangedListener(this._historyListenerToken, { peerId: Int64 =>
            if (peerId == this.chatId) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] history cleared for ${peerId} → clearing local view")
                launch {
                    this.history.clear()
                    this.loadMessages()
                }
            }
        })
    }

    public func initChatRoomWithPeer(chatId: Int64, chatName: String, peerType: String) {
        this.bindHistory(chatId)
        this.senderRoleById = HashMap<Int64, String>()
        this.chatId = chatId
        this.chatName = chatName
        this.peerType = peerType
        this.subscribeHistoryCleared()
        let realUserId = getCurrentUserId()
        if (realUserId != 0) {
            this.currentUserId = realUserId
        }
        // iOS ChatTitleView.swift:290：peerId == accountPeerId → Conversation.SavedMessages，无副标题。
        if (this.isSavedMessagesChat()) {
            this.chatName = savedMessagesChatTitle()
        }
        this.registerCurrentReactionAvatar()
        // P2-422: 启动时运行 TextFormatUtils 自检，确保 parseMarkdown 解析器行为正确
        let fmtOk = textFormatSelfCheck()
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] textFormatSelfCheck: ${fmtOk}")
        // Phase P5-11: 加载 readOutboxMaxId 缓存 + 注册实时回调
        this._readOutboxMaxId = getReadOutboxMaxId(peerType, chatId)
        this.registerReadOutboxHandler()
        this.registerChatRoomUpdateHandlers()
        this.registerMessageReactionsHandler()
        // 媒体资源使用独立生命周期令牌，必须先激活再加载。
        // 消息轮询暂停不应该意外取消已可见的图片任务。
        this.activateMediaPipeline()
        this.startPolling()
        this.loadMessages()
        // P2-121: 加载 presence 副标题（私聊: online/last seen；群组/频道: N members）
        this.loadPresenceSubtitle()
        // P2-122: 加载多条置顶消息列表
        this.loadPinnedMessages()
        // P2-120: 加载慢速模式 / 发送限制状态
        this.loadChatPermissions()
        // Phase A5: 轮询已在 loadMessages 前启动，同时充当媒体任务生命周期令牌。
    }

    /**
     * Keep reaction peer avatars reactive to the shared peer-photo cache.
     * iOS gets this invalidation from Postbox peer views; the Cangjie UI needs
     * an explicit @Publish list replacement when the self thumbnail/download
     * becomes available.
     */
    private func registerCurrentReactionAvatar(): Unit {
        if (this._reactionAvatarCallbackRegistered || this.currentUserId <= 0) { return }
        this._reactionAvatarCallbackRegistered = true
        getUserPhotoService().addPhotoReadyCallback({
            userId: Int64, path: String =>
            if (path.size > 0) {
                spawn(UIThread) {
                    =>
                    let affectedMessageIds = ArrayList<Int64>()
                    for (message in this.history.items) {
                        var containsPeer = false
                        for (reaction in message.reactions) {
                            for (peerId in reaction.peerIds) {
                                if (peerId == userId) {
                                    containsPeer = true
                                    break
                                }
                            }
                            if (containsPeer) { break }
                        }
                        if (containsPeer) { affectedMessageIds.add(message.id) }
                    }
                    for (messageId in affectedMessageIds) {
                        let _ = this.history.update(messageId, { message: Message =>
                            for (reaction in message.reactions) {
                                var index: Int64 = 0
                                while (index < Int64(reaction.peerIds.size)) {
                                    if (reaction.peerIds[index] == userId) {
                                        while (reaction.peerAvatarPaths.size <= index) {
                                            reaction.peerAvatarPaths.add("")
                                        }
                                        reaction.peerAvatarPaths[index] = path
                                    }
                                    index += 1
                                }
                            }
                        })
                    }
                }
            }
        })
        getUserPhotoService().requestCurrentUserProfile(this.currentUserId)
    }

    // ==================== P2-121: Presence 副标题加载 ====================

    /**
     * 从历史响应的 users/chats 中提取 presence 副标题
     *
     * 私聊: 解析 User.statusType/isOnline/wasOnline → 格式化 "online" / "last seen X ago"
     * 普通群 (chat): "N members"
     * 超级群/频道 (channel): "N members, M online" 或 "N subscribers"
     *
     * 使用 PeerPresenceStatusManagerService.formatText() 统一格式化。
     * 数据来源: loadMessages() 请求中的 historyResponse.users / .chats，
     * 无需额外 API 请求。
     */
    public func loadPresenceSubtitle(): Unit {
        // iOS ChatTitleView.swift:510：自聊天（Saved Messages）不显示在线状态副标题。
        if (this.isSavedMessagesChat()) {
            this.subtitleText = ""
            return
        }
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        // 人工反馈 #4：从通讯录进会话时副标题要等一次 getHistory RPC 回来才出现（"last seen 有时差"）。
        // 联系人列表 / 会话列表拉到的 UserResponse 早已带 isOnline/wasOnline/statusType 且已进
        // UserPhotoService.userCache，先用它同步算一版文案立刻上屏，RPC 回来再覆盖为最新值。
        if (peerTypeCopy == "user") {
            match (getUserPhotoService().getCachedUser(chatIdCopy)) {
                case Some(u) =>
                    this._lastPresenceIsOnline = u.isOnline
                    this._lastPresenceWasOnline = u.wasOnline
                    this._lastPresenceStatusType = u.statusType
                    this._presenceDataLoaded = true
                    let ppsvc = getPeerPresenceStatusManagerService()
                    let seeded = ppsvc.formatText(u.isOnline, u.wasOnline, u.statusType)
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-121 presence seeded from cache: ${seeded}")
                    this.subtitleText = seeded
                    ppsvc.reset(chatIdCopy, u.isOnline, u.wasOnline, u.statusType, { => this.refreshPresenceTextOnly() })
                case None => ()
            }
        } else {
            // contacts.resolveUsername carries the authoritative Chat object and
            // ResolveService caches it before navigation, matching iOS Postbox.
            // Seed the title subtitle synchronously instead of waiting for a
            // second history RPC whose compact chat object may omit the count.
            match (getRealChatListService().getCachedChat(peerTypeCopy, chatIdCopy)) {
                case Some(c) =>
                    let cnt = c.participantsCount
                    this.subtitleText = if (c.isChannel && !c.isMegagroup) {
                        if (cnt > 0) { "${formatChatPeerCount(cnt)} subscribers" } else { "channel" }
                    } else {
                        if (cnt > 0) { "${formatChatPeerCount(cnt)} members" } else { "group" }
                    }
                case None => ()
            }
        }
        spawn {
            try {
                let svc = getRealMessageService()
                let histResp = svc.getHistory(peerTypeCopy, chatIdCopy, limit: 1)

                if (peerTypeCopy == "user") {
                    // 私聊：从 users 中找对方的在线状态
                    for (u in histResp.users) {
                        if (u.id == chatIdCopy) {
                            // 缓存原始字段，供后续定时刷新回调复用（不再重发 getHistory）
                            this._lastPresenceIsOnline = u.isOnline
                            this._lastPresenceWasOnline = u.wasOnline
                            this._lastPresenceStatusType = u.statusType
                            this._presenceDataLoaded = true

                            let ppsvc = getPeerPresenceStatusManagerService()
                            let text = ppsvc.formatText(u.isOnline, u.wasOnline, u.statusType)
                            Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-121 presence: ${text}")
                            launch { this.subtitleText = text }
                            // 注册定时刷新：到期只重算文案（refreshPresenceTextOnly），
                            // 绝不重新调用 loadPresenceSubtitle（避免每次都重发 getHistory RPC 导致无界循环 OOM）
                            ppsvc.reset(
                                chatIdCopy,
                                u.isOnline,
                                u.wasOnline,
                                u.statusType,
                                { => this.refreshPresenceTextOnly() }
                            )
                            break
                        }
                    }
                } else if (peerTypeCopy == "chat") {
                    // 普通群：从 chats 拿 participantsCount
                    for (c in histResp.chats) {
                        if (c.id == chatIdCopy) {
                            let cnt = c.participantsCount
                            let text = if (cnt > 0) { "${formatChatPeerCount(cnt)} members" } else { "group" }
                            Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-121 group subtitle: ${text}")
                            launch { this.subtitleText = text }
                            break
                        }
                    }
                } else {
                    // channel/supergroup：iOS ChatTitleView.swift:688-720。
                    // 成员数取 CachedChannelData.participantsSummary.memberCount（channels.getFullChannel
                    // participants_count）；channel 对象的 participants_count 通常不下发（基础群升级来的
                    // 超级群恒为空），只作兜底。超级群 online > 1 时追加 ", N online"；
                    // 数不到成员时 Group.Status "group" / Channel.Status "channel"。
                    var found = false
                    var isBroadcast = false
                    var cnt: Int32 = 0
                    for (c in histResp.chats) {
                        if (c.id == chatIdCopy) {
                            found = true
                            isBroadcast = c.isChannel && !c.isMegagroup
                            cnt = c.participantsCount
                            break
                        }
                    }
                    if (found) {
                        var online: Int32 = 0
                        try {
                            let full = getRealMessageService().getFullChatInfo("channel", chatIdCopy)
                            if (full.membersCount > 0) { cnt = full.membersCount }
                            online = full.onlineCount
                        } catch (eFull: Exception) {
                            Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-121 channel full info failed: ${eFull}")
                        }
                        let text = if (isBroadcast) {
                            if (cnt > 0) { "${formatChatPeerCount(cnt)} subscribers" } else { "channel" }
                        } else if (cnt <= 0) {
                            "group"
                        } else {
                            let members = if (cnt == 1) { "1 member" } else { "${formatChatPeerCount(cnt)} members" }
                            if (online > 1) { "${members}, ${online} online" } else { members }
                        }
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-121 channel subtitle: ${text}")
                        launch { this.subtitleText = text }
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-121 loadPresenceSubtitle error: ${e}")
            }
        }
    }

    /**
     * OOM 修复：presence 定时器到期后的轻量文案重算入口。
     *
     * 对应 iOS PeerPresenceStatusManager.reset(presence:isOnline:) 的语义——
     * 定时刷新只应重新计算/重新格式化已知的 presence 文案，**不涉及任何网络请求**。
     *
     * 复用 loadPresenceSubtitle() 上一次拿到并缓存的 _lastPresenceIsOnline /
     * _lastPresenceWasOnline / _lastPresenceStatusType，只做:
     *   1. formatText() 重新计算文案（纯本地计算，无 IO）
     *   2. ppsvc.reset() 根据当前状态重新武装下一次定时器
     * 绝不调用 loadPresenceSubtitle() / getHistory()，避免每次到期都重发一次
     * 完整历史消息 RPC，形成无节流的网络+内存增长死循环（见 P2-121 OOM 崩溃修复）。
     *
     * 仅私聊（peerType == "user"）需要这个定时刷新链路；群组/频道副标题
     * 不随 presence 定时变化，不需要重新武装定时器。
     */
    public func refreshPresenceTextOnly(): Unit {
        if (this.peerType != "user") { return }
        if (!this._presenceDataLoaded) { return }

        let chatIdCopy = this.chatId
        let isOnlineCopy = this._lastPresenceIsOnline
        let wasOnlineCopy = this._lastPresenceWasOnline
        let statusTypeCopy = this._lastPresenceStatusType

        let ppsvc = getPeerPresenceStatusManagerService()
        let text = ppsvc.formatText(isOnlineCopy, wasOnlineCopy, statusTypeCopy)
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-121 presence text-only refresh: ${text}")
        launch { this.subtitleText = text }

        // 重新武装下一次定时器，回调仍指向本函数（不重新拉取数据）
        ppsvc.reset(
            chatIdCopy,
            isOnlineCopy,
            wasOnlineCopy,
            statusTypeCopy,
            { => this.refreshPresenceTextOnly() }
        )
    }

    /**
     * P2-121: 当 UpdatesManager 推送 userStatus 事件时更新私聊副标题
     *
     * ChatRoomPage.aboutToAppear 将此回调注册到 UpdatesManager 的 userStatus 更新流。
     * 仅在当前对话是该 userId 的私聊时更新。
     */
    /** 当前会话是否为 Saved Messages（与自己的私聊，iOS peerId == accountPeerId）。 */
    public func isSavedMessagesChat(): Bool {
        return this.peerType == "user" && this.chatId != 0 && this.chatId == this.currentUserId
    }

    public func onUserStatusUpdate(userId: Int64, isOnline: Bool): Unit {
        if (this.peerType != "user" || userId != this.chatId) { return }
        if (this.isSavedMessagesChat()) { return }
        let text = if (isOnline) { "online" } else { "last seen recently" }
        launch { this.subtitleText = text }
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-121 userStatus update: userId=${userId}, online=${isOnline}")
    }

    /**
     * P2-121: 当收到 typing 事件时，设置 typingText；5s 后清除（由 ChatTitleActivityService 管理）
     * ChatRoomPage 订阅 ChatTitleActivityService 回调后调用此方法同步 VM 状态。
     */
    public func setTypingText(text: String): Unit {
        launch { this.typingText = text }
    }

    // ==================== P2-122: 多条置顶消息加载 ====================

    /**
     * 加载当前对话的全部置顶消息
     *
     * 使用 messages.search with filter=InputMessagesFilterPinned (constructor 0x1bb00451)
     * 返回的消息按 id 降序（最新置顶在前）。
     * 置顶列表加载后：
     *   - pinnedMessageIds / pinnedMessageTexts 更新
     *   - currentPinnedIndex 重置为 0
     *   - pinnedMessageId / pinnedMessageText 同步为 index=0 的条目
     *
     * messages.search#29ee847a:
     *   flags:#  peer:InputPeer  q:string  from_id:flags.0?InputPeer
     *   top_msg_id:flags.1?int  saved_peer_id:flags.2?InputPeer
     *   filter:MessagesFilter  min_date:int  max_date:int
     *   offset_id:int  add_offset:int  limit:int  max_id:int  min_id:int  hash:long
     *
     * InputMessagesFilterPinned#1bb00451  (no fields)
     */
    public func loadPinnedMessages(): Unit {
        // S8-08：秘密聊天没有云端置顶（InputPeer 只有 user/chat/channel，buildInputPeer 对
        // secretChat 返回 InputPeerEmpty → messages.search 变成全局置顶搜索），此前把普通私聊的
        // "Pinned #1 of 3" 串进了秘密聊天页。iOS 秘密聊天不读 pinned（无 cloud message namespace）。
        if (this.isSecretChatPeer()) { return }
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        spawn {
            try {
                let client = getMTProtoClient()
                let svc = getRealMessageService()
                let req = MessagesSearch()
                req.peer = svc.buildInputPeer(peerTypeCopy, chatIdCopy)
                req.q = ""
                req.filter = InputMessagesFilterPinned()
                req.limit = 50
                let responseData = client.sendRequest(req.toBytes())
                if (responseData.size == 0) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-122 loadPinnedMessages: empty response")
                    return
                }
                let resp = MessagesHistoryResponse.deserialize(responseData)
                let newIds = ArrayList<Int64>()
                let newTexts = ArrayList<String>()
                for (m in resp.messages) {
                    newIds.add(Int64(m.id))
                    let text = if (m.message.size > 100) { m.message[0..100] + "..." } else { m.message }
                    newTexts.add(text)
                }
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-122 pinned: ${newIds.size} messages found")
                launch {
                    this.pinnedMessageIds = newIds
                    this.pinnedMessageTexts = newTexts
                    this.currentPinnedIndex = 0
                    if (!newIds.isEmpty()) {
                        this.pinnedMessageId = newIds[0]
                        this.pinnedMessageText = newTexts[0]
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-122 loadPinnedMessages error: ${e}")
            }
        }
    }

    /**
     * P2-122: 循环切换到下一条置顶消息
     *
     * 点击置顶条时调用 — 先跳转到当前消息，再 cycle index 切到下一条。
     * 返回当前 pinnedMessageId（供 ChatRoomPage 跳转到该消息）。
     */
    public func cyclePinnedMessage(): Int64 {
        if (this.pinnedMessageIds.isEmpty()) { return this.pinnedMessageId }
        let currentId = this.pinnedMessageIds[Int64(this.currentPinnedIndex)]
        let nextIndex = Int32((Int64(this.currentPinnedIndex) + 1) % this.pinnedMessageIds.size)
        this.currentPinnedIndex = nextIndex
        this.pinnedMessageId = this.pinnedMessageIds[Int64(nextIndex)]
        this.pinnedMessageText = this.pinnedMessageTexts[Int64(nextIndex)]
        return currentId
    }

    /**
     * P2-122: 置顶消息 + pm_oneside 选项（仅为自己置顶，不通知对方）
     *
     * iOS: PendingMessagesManager flag bit 2 = pm_oneside (0x4)
     * messages.updatePinnedMessage flags: bit0=silent, bit1=unpin, bit2=pm_oneside
     */
    public func pinMessageWithOptions(messageId: Int64, messageText: String, silent!: Bool = false, pmOneside!: Bool = false): Unit {
        this.pinnedMessageId = messageId
        this.pinnedMessageText = if (messageText.size > 100) { messageText[0..100] + "..." } else { messageText }
        // 追加到置顶列表头部
        let newIds = ArrayList<Int64>()
        newIds.add(messageId)
        for (id in this.pinnedMessageIds) {
            if (id != messageId) { newIds.add(id) }
        }
        let newTexts = ArrayList<String>()
        newTexts.add(this.pinnedMessageText)
        for (i in 0..this.pinnedMessageTexts.size) {
            if (i < this.pinnedMessageIds.size && this.pinnedMessageIds[i] != messageId) {
                newTexts.add(this.pinnedMessageTexts[i])
            }
        }
        this.pinnedMessageIds = newIds
        this.pinnedMessageTexts = newTexts
        this.currentPinnedIndex = 0
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-122 pinMessage: ${messageId}, silent=${silent}, pmOneside=${pmOneside}")

        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let msgIdCopy = Int32(messageId)
        let silentCopy = silent
        let pmOnesideCopy = pmOneside
        spawn {
            this._pollingPaused = true
            try {
                let client = getMTProtoClient()
                let svc = getRealMessageService()
                let req = MessagesUpdatePinnedMessage()
                req.peer = svc.buildInputPeer(peerTypeCopy, chatIdCopy)
                req.id = msgIdCopy
                req.unpin = false
                req.silent = silentCopy
                req.pmOneside = pmOnesideCopy
                let _ = client.sendRequest(req.toBytes())
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-122 pinMessage sent to server")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-122 pinMessage error: ${e}")
            }
            this._pollingPaused = false
        }
    }

    // ==================== Phase A5: 新消息轮询 ====================

    private func reactionListsEqual(
        lhs: ArrayList<ReactionData>,
        rhs: ArrayList<ReactionData>
    ): Bool {
        if (lhs.size != rhs.size) { return false }
        for (i in 0..lhs.size) {
            let a = lhs[i]
            let b = rhs[i]
            if (a.emoji != b.emoji || a.count != b.count ||
                a.isSelected != b.isSelected || a.peerIds.size != b.peerIds.size) {
                return false
            }
            for (j in 0..a.peerIds.size) {
                if (a.peerIds[j] != b.peerIds[j]) { return false }
            }
        }
        return true
    }
    
    /**
     * 启动新消息轮询（3s 间隔）
     * 
     * 参照 TelegramHarmony ChatViewModel.ets 的 polling 机制：
     * - 使用 merge 模式：只追加新消息，不替换整个列表
     * - 保护已有消息数据（包括已下载的照片路径）
     * - 使用 _pollingBusy 标志防止并发 MTProto 访问
     */
    public func startPolling() {
        if (this._pollingActive) { return }
        // S8-08：秘密聊天不走 messages.getHistory 备用轮询。
        if (this.isSecretChatPeer()) { return }
        this._pollingActive = true
        this._pollingGeneration += 1
        let generation = this._pollingGeneration
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        spawn {
            // Phase R10: 降级为 10s 备用轮询（实时更新由 UpdatesManager 推送）
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Message polling started (10s backup interval)")
            // 等待初始加载完成（loadMessages 完成后 isLoading=false）
            while (this._pollingActive && generation == this._pollingGeneration && this.isLoading) {
                sleep(Duration.millisecond * 500)
            }
            while (this._pollingActive && generation == this._pollingGeneration) {
                sleep(Duration.second * 10)
                if (!this._pollingActive || generation != this._pollingGeneration) { break }
                // 如果 sendMessage 等操作正在使用 MTProto，跳过这个周期
                if (this._pollingPaused || this.isLoading) { continue }
                this._pollingBusy = true
                try {
                    let messageService = getRealMessageService()
                    let historyResponse = messageService.getHistory(
                        peerTypeCopy,
                        chatIdCopy,
                        limit: 30
                    )
                    
                    if (historyResponse.messages.size > 0) {
                        let serverLatestId = Int64(historyResponse.messages[0].id)
                        let serverMessages = this.convertTLMessages(historyResponse)

                        // Existing-message fields such as reactions can change
                        // without changing the latest message id. Reconcile
                        // those deltas on every backup poll, while preserving
                        // local media paths and failed/sending state.
                        let serverById = HashMap<Int64, Message>()
                        for (serverMessage in serverMessages) {
                            serverById[serverMessage.id] = serverMessage
                        }
                        let existingIds = HashMap<Int64, Bool>()
                        let reactionPersist = ArrayList<Message>()
                        var reactionsChanged = false
                        for (localMessage in this.messageList) {
                            existingIds[localMessage.id] = true
                            if (serverById.contains(localMessage.id)) {
                                let serverMessage = serverById[localMessage.id]
                                if (!this.reactionListsEqual(localMessage.reactions, serverMessage.reactions)) {
                                    // Replace the plain Message instance instead
                                    // of mutating the UI-owned object from this
                                    // polling worker. Preserve downloaded local
                                    // presentation resources on the fresh model.
                                    serverMessage.photoLocalPath = localMessage.photoLocalPath
                                    serverMessage.documentLocalPath = localMessage.documentLocalPath
                                    serverMessage.documentThumbnailPath = localMessage.documentThumbnailPath
                                    serverMessage.webPagePhotoLocalPath = localMessage.webPagePhotoLocalPath
                                    reactionsChanged = true
                                    reactionPersist.add(serverMessage)
                                }
                            }
                        }

                        let newMessages = ArrayList<Message>()
                        for (serverMessage in serverMessages) {
                            if (!existingIds.contains(serverMessage.id)) {
                                newMessages.add(serverMessage)
                            }
                        }

                        if (reactionsChanged || !newMessages.isEmpty()) {
                            // 增量提交，取代原先的「轮询线程读快照 → 复制 → 整表回写」。
                            // 那是本工程最原始的竞态点：与本地发送 / 推送并发时两边互相覆盖，
                            // 表现为偶发丢消息。增量提交不依赖读到的旧快照，天然免疫。
                            //   · reactionPersist —— 同 id 同键，命中 insertLocked 的原地写路径
                            //     （对齐 iOS setLowerOrAtAnchorAtArrayIndex，MessageHistoryViewState.swift:987）
                            //   · newMessages     —— 二分定点插入（对齐 .InsertMessage）
                            if (!reactionPersist.isEmpty()) {
                                let _ = this.history.insertMany(reactionPersist)
                            }
                            if (!newMessages.isEmpty()) {
                                let _ = this.history.insertMany(newMessages)
                            }
                            // 取合并后的真实最后一条：history 保证按全序键升序，比原先
                            // 依赖「本地列表顺序 + 尾部追加」更可靠。
                            let mergedSnapshot = this.history.items
                            if (!mergedSnapshot.isEmpty()) {
                                let mergedLatestId: Int64 = mergedSnapshot[mergedSnapshot.size - 1].id
                                if (serverLatestId > mergedLatestId) {
                                    launch { this.hasMoreNewer = true }
                                }
                            }
                            if (!reactionPersist.isEmpty()) {
                                getMessageHistoryStore().storeMessages(chatIdCopy, reactionPersist, peerType: peerTypeCopy)
                            }
                            if (!newMessages.isEmpty()) {
                                let incomingMessages = newMessages
                                let _ = spawn {
                                    for (incoming in incomingMessages) {
                                        if (incoming.messageType == "text" && isSingleEmoji(incoming.content)) {
                                            let _ = prefetchAnimatedEmojiResource(incoming.content)
                                        }
                                    }
                                    this.downloadPhotosForMessages(incomingMessages, interactive: true, autosave: true)
                                }
                            }
                            Hilog.info(0, "CjTelegram",
                                "[ChatRoomVM] Polling: new=${newMessages.size}, reactionUpdates=${reactionPersist.size}, total=${mergedSnapshot.size}")
                        }
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Polling error: ${e}")
                    logExceptionStack("[ChatRoomVM] polling", e)
                }
                if (generation == this._pollingGeneration) { this._pollingBusy = false }
            }
            if (generation == this._pollingGeneration) { this._pollingBusy = false }
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Message polling stopped")
        }
    }
    
    /**
     * 停止轮询
     */
    public func stopPolling() {
        this._pollingActive = false
        this._pollingGeneration += 1
        let manager = getUpdatesManager()
        if (this._pushSubscriptionToken >= 0) { manager.removeChatRoomPushSubscriber(this._pushSubscriptionToken) }
        if (this._editSubscriptionToken >= 0) { manager.removeChatRoomEditSubscriber(this._editSubscriptionToken) }
        if (this._deleteSubscriptionToken >= 0) { manager.removeChatRoomDeleteSubscriber(this._deleteSubscriptionToken) }
        if (this._reactionSubscriptionToken >= 0) { manager.removeChatRoomReactionSubscriber(this._reactionSubscriptionToken) }
        if (this._readOutboxSubscriptionToken >= 0) { manager.removeReadOutboxSubscriber(this._readOutboxSubscriptionToken) }
        this._pushSubscriptionToken = -1
        this._editSubscriptionToken = -1
        this._deleteSubscriptionToken = -1
        this._reactionSubscriptionToken = -1
        this._readOutboxSubscriptionToken = -1
    }

    private func activateMediaPipeline(): Unit {
        this._mediaGeneration += 1
        this._mediaActive = true
    }

    public func suspendMediaPipeline(): Unit {
        this._mediaActive = false
        this._mediaGeneration += 1
    }

    /**
     * 同一 ChatRoomPage 暂时不可见后恢复。iOS viewWillDisappear 不会释放
     * history/MediaBox subscriptions；ArkUI onDisAppear 会在 push 子页和应用切后台时触发，
     * 因此返回后必须重建 active-room callbacks，并重试当前视口附近媒体。
     */
    public func resumeActiveRoom(visibleAnchorId: Int64): Unit {
        this.registerReadOutboxHandler()
        this.registerChatRoomUpdateHandlers()
        this.registerMessageReactionsHandler()
        this.registerCurrentReactionAvatar()
        this.activateMediaPipeline()
        this.startPolling()
        let mediaWindow = this.initialMediaWindow(this.messageList, visibleAnchorId)
        if (!mediaWindow.isEmpty()) {
            spawn {
                // 页面不可见期间下载可能被生命周期令牌中断；清理已指向不存在/空文件
                // 的路径，否则 downloadPhotosForMessages 会因 path 非空而错误跳过。
                for (message in mediaWindow) {
                    if (message.photoLocalPath.size > 0) {
                        let rawPath = if (message.photoLocalPath.startsWith("file://")) {
                            message.photoLocalPath[7..]
                        } else {
                            message.photoLocalPath
                        }
                        if (!this.usableMediaFile(rawPath)) {
                            message.photoLocalPath = ""
                            let _ = this.photoPathCache.remove(message.photoId)
                        }
                    }
                }
                this.downloadPhotosForMessages(mediaWindow)
                // 即使资源原本已在磁盘，也重新发布一次快照，让返回后的 Image 节点
                // 重新绑定 file URI；等价于 iOS MediaBox subscriber 重新进入可见状态。
                this.refreshMessageSnapshot()
            }
        }
        Hilog.info(0, "CjTelegram",
            "[ChatRoomVM] active room resumed, media=${mediaWindow.size}, anchor=${visibleAnchorId}")
    }

    /**
     * Telegram also delivers reaction changes as updateEditMessage containing
     * a complete Message. iOS feeds that update through Postbox, which replaces
     * the visible history item immediately. Keep the equivalent active-room
     * handlers registered and always publish their mutations on UIThread.
     */
    private func registerChatRoomUpdateHandlers(): Unit {
        let manager = getUpdatesManager()
        if (this._pushSubscriptionToken < 0) {
            this._pushSubscriptionToken = manager.addChatRoomPushSubscriber({ msg: Message =>
                spawn(UIThread) { => this.onNewMessagePush(msg) }
            })
        }
        if (this._editSubscriptionToken < 0) {
            this._editSubscriptionToken = manager.addChatRoomEditSubscriber({ msg: Message =>
                spawn(UIThread) { => this.onEditMessagePush(msg) }
            })
        }
        if (this._deleteSubscriptionToken < 0) {
            this._deleteSubscriptionToken = manager.addChatRoomDeleteSubscriber({ ids: ArrayList<Int64> =>
                spawn(UIThread) { => this.onDeleteMessagesPush(ids) }
            })
        }
    }

    /**
     * iOS applies updateMessageReactions directly to the Postbox message and
     * the active history view receives a replacement item. Register the active
     * chat for the equivalent peer+message-id delta.
     */
    private func registerMessageReactionsHandler(): Unit {
        if (this._reactionSubscriptionToken < 0) {
            this._reactionSubscriptionToken = getUpdatesManager().addChatRoomReactionSubscriber({
                peerId: Int64,
                msgId: Int64,
                counts: ArrayList<TLReactionCount> =>
                    this.onMessageReactionsPush(peerId, msgId, counts)
            })
        }
    }

    public func onMessageReactionsPush(
        peerId: Int64,
        msgId: Int64,
        counts: ArrayList<TLReactionCount>
    ): Unit {
        if (peerId != this.chatId) {
            Hilog.info(0, "CjTelegram",
                "[ChatRoomVM] Reaction push ignored for peer=${peerId}, active=${this.chatId}")
            return
        }
        let mapped = getRealMessageService().convertReactionCounts(
            counts,
            this.currentUserId,
            this.peerType,
            this.chatId,
            this.chatName
        )
        spawn(UIThread) {
            =>
            let _ = this.history.update(msgId, { message: Message =>
                message.reactions = mapped
            })
            var target: Option<Message> = None<Message>
            for (message in this.history.items) {
                if (message.id == msgId) {
                    target = Some(message)
                    break
                }
            }
            match (target) {
                case Some(changedMessage) =>
                    // Reaction 是可变 Message 的内容字段。必须通过权威容器提交，
                    // 由 update() 在锁外 notifyChanged → publishSnapshot → 页面重建。
                    // 直接改 messageList 中的共享引用再 refreshSnapshot 会绕过容器事务，
                    // 真机上会出现服务端数据已到、组件却保持旧内容。
                    let persistPeerId = this.chatId
                    let persistPeerType = this.peerType
                    let persistList = ArrayList<Message>()
                    persistList.add(changedMessage)
                    spawn {
                        getMessageHistoryStore().storeMessages(persistPeerId, persistList, peerType: persistPeerType)
                    }
                    Hilog.info(0, "CjTelegram",
                        "[ChatRoomVM] Reaction push applied: msgId=${msgId}, count=${mapped.size}")
                case None =>
                    Hilog.info(0, "CjTelegram",
                        "[ChatRoomVM] Reaction push target not loaded: msgId=${msgId}")
            }
        }
    }

    // ==================== 加载消息 ====================

    /** S8-08：当前会话是否为秘密聊天（peerType "secret" / PeerKey.SECRET_CHAT）。 */
    public func isSecretChatPeer(): Bool {
        return this.peerType == "secret" || this.peerType == "secretChat"
    }

    public func loadMessages() {
        this.isLoading = true
        this.initialLoadDone = false
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        // S8-08：秘密聊天没有云端 history（messages.getHistory 只接受普通 InputPeer），
        // 首屏直接以空历史定案；握手完成前也没有可拉取的消息。
        if (this.isSecretChatPeer()) {
            launch {
                this.hasMoreHistory = false
                this.hasMoreNewer = false
                this.initialLoadDone = true
                this.isLoading = false
            }
            return
        }
        // iOS ChatHistoryListNode.swift:49 historyMessageCount = 44。
        let historyWindowSize: Int32 = 44

        // E5：Join 面板先按已缓存的 channel peer 定（iOS ChatInterfaceStateInputPanels.swift:269
        // participationStatus == .left，peer 来自 Postbox：会话列表或 resolvePeerByName 写入）；
        // 随后 getHistory 响应里的 channel 对象再权威回填。
        if (peerTypeCopy == "channel") {
            match (getRealChatListService().getCachedChat("channel", chatIdCopy)) {
                case Some(cachedChannel) =>
                    if (cachedChannel.isChannel && cachedChannel.id == chatIdCopy) {
                        this.channelJoinRequired = cachedChannel.isLeft
                        this.channelJoinRequestNeeded = cachedChannel.requestToJoin
                        this.channelIsBroadcast = cachedChannel.isBroadcast
                    }
                case None => ()
            }
        }

        // iOS 的 local namespace 消息直接属于 Postbox history view，不依赖 cloud history
        // 是否存在或网络请求是否成功。仓颉必须先独立发布失败消息，随后本地/网络历史再合并。
        let failedImmediately = this.mergeFailedLocals(ArrayList<Message>())
        if (!failedImmediately.isEmpty()) {
            // 增量插入而非整表替换：失败消息与随后到达的本地缓存 / 网络历史是叠加关系，
            // 整表替换会让先到的一方被后到的一方抹掉。
            let _ = this.history.insertMany(failedImmediately)
            launch { this.isLoading = false }
            Hilog.info(0, "CjTelegram",
                "[ChatRoomVM] restored ${failedImmediately.size} failed message(s) before history load")
        }

        // ============ Phase FAST-1: 本地秒开（复刻 iOS Postbox local-first） ============
        // 进聊天页立即从本地 MessageHistoryTable 渲染已缓存历史，无需等 MTProto 往返、
        // 也无需等聊天列表轮询让路。本地空则 no-op，走后续网络路径。这是"消息加载慢"的
        // 主要修复：此前 loadMessages 直连纯网络 getHistory + 最多阻塞 3s 等轮询。
        // V7 S7-117：秒开渲染的本地云消息 id。最新一页回来后，比它上界更新、又不在回包里的
        // 本地帖子（频道离线期间被删除的最新几条）要移出视图，推送新到的消息不在此集合、不受影响。
        let localCloudIds = HashSet<Int64>()
        try {
            let localMsgs = getMessageHistoryStore().loadLocalMessages(
                chatIdCopy, historyWindowSize, 0, peerType: peerTypeCopy)
            if (localMsgs.size > 0) {
                for (lm in localMsgs) {
                    if (lm.namespace == MessageHistoryView.NS_CLOUD && lm.id > 0) { localCloudIds.add(lm.id) }
                }
                let fromStore = this.mergeFailedLocals(localMsgs)
                let _ = this.history.insertMany(fromStore)
                let localMediaWindow = this.initialMediaWindow(localMsgs, 0)
                if (!localMediaWindow.isEmpty()) {
                    // 与 iOS 可见节点订阅 MediaBox 等价：本地历史进入首帧时也必须
                    // 检查磁盘资源并启动缺失下载，不能只处理网络返回的最新 44 条。
                    spawn { this.downloadPhotosForMessages(localMediaWindow) }
                }
                launch { this.isLoading = false }
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] FAST local render: ${localMsgs.size} msgs (network refresh in bg)")
            }
        } catch (e0: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] local fast-render skipped: ${e0}")
        }

        spawn {
            try {
                let messageService = getRealMessageService()
                let historyResponse = messageService.getHistory(
                    peerTypeCopy,
                    chatIdCopy,
                    limit: historyWindowSize
                )

                var foundName = ""
                for (user in historyResponse.users) {
                    if (user.accessHash != 0) {
                        messageService.cacheUserAccessHash(user.id, user.accessHash)
                    }
                    if (user.id == chatIdCopy && this.chatName.startsWith("User ")) {
                        var realName = user.firstName
                        if (user.lastName.size > 0) { realName = realName + " " + user.lastName }
                        if (realName.size > 0) {
                            foundName = realName
                            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Updated chatName to: ${realName}")
                        }
                    }
                }
                for (chat in historyResponse.chats) {
                    if (chat.isChannel && chat.accessHash != 0) {
                        messageService.cacheChannelAccessHash(chat.id, chat.accessHash)
                    }
                    if (peerTypeCopy == "channel" && chat.isChannel && chat.id == chatIdCopy) {
                        // 公开频道未加入也能读历史；响应里的 channel 对象带权威 left 位。
                        getRealChatListService().cacheChatResponse(chat)
                        this.channelJoinRequired = chat.isLeft
                        this.channelJoinRequestNeeded = chat.requestToJoin
                        this.channelIsBroadcast = chat.isBroadcast
                    }
                    if (chat.id == chatIdCopy && this.chatName.startsWith("Chat ")) {
                        if (chat.title.size > 0) {
                            foundName = chat.title
                            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Updated chatName to: ${chat.title}")
                        }
                    }
                }
                this.loadSenderRoles(
                    peerTypeCopy,
                    chatIdCopy,
                    if (peerTypeCopy == "channel") {
                        messageService.getAccessHashForChannel(chatIdCopy)
                    } else { 0 }
                )

                let messages = this.convertTLMessages(historyResponse)
                // 网络回填本地表，供下次秒开；同时把本页覆盖的 id 区间移出 hole。
                try {
                    getMessageHistoryStore().storeHistoryFill(chatIdCopy, messages, peerType: peerTypeCopy,
                        serverCount: historyResponse.reliableCount())
                } catch (_bf: Exception) {}
                // 本地秒开的那批缓存若与最新一页之间隔着 hole（离线期间来了超过一页的新消息，
                // 或缓存本身是零散写入的），不能继续留在视图里：否则上翻时直接从这批旧缓存
                // 往下读，日期会从「今天」跳到几个月前。iOS 的历史视图在 hole 处停下并去网络补，
                // 这里等价地把 hole 以下的云消息移出视图（本地表不动），上翻从最新页底部按
                // offsetId 继续向服务端分页。
                var networkMinId: Int64 = 0
                var networkMaxId: Int64 = 0
                let networkIds = HashSet<Int64>()
                for (m in messages) {
                    if (m.namespace == MessageHistoryView.NS_CLOUD && m.id > 0) {
                        networkIds.add(m.id)
                        if (networkMinId == 0 || m.id < networkMinId) { networkMinId = m.id }
                        if (m.id > networkMaxId) { networkMaxId = m.id }
                    }
                }
                let pruneChannelStrays = normalizeDialogPeerType(peerTypeCopy) == "channel"
                let pruneMinId = networkMinId
                let pruneMaxId = networkMaxId
                var lowerIdFound: Int64 = networkMinId
                if (networkMinId > 0) {
                    match (getMessageHistoryStore().filledLowerBound(chatIdCopy, networkMinId, peerType: peerTypeCopy)) {
                        case Some(lo) => lowerIdFound = lo
                        case None => ()
                    }
                }
                let connectedLowerId = lowerIdFound

                let nameToUpdate = foundName
                let channelHasMore = historyResponse.messages.size >= Int64(historyWindowSize)
                // 超级群自己的历史一页就到头：若由基础群升级而来，窗口继续向旧群延伸（见 loadMoreMigratedHistory）。
                let continueMigrated = !channelHasMore && this.beginMigratedHistoryIfNeeded(chatIdCopy, peerTypeCopy)
                let hasMore = channelHasMore || continueMigrated
                Hilog.info(0, "CjTelegram",
                    "[HistoryHole] peer=${chatIdCopy} first page ${messages.size}/${historyResponse.messages.size} msgs [${networkMinId}..] connectedLowerId=${connectedLowerId} hasMore=${hasMore}")

                // P2-112: 计算未读锚点
                // readInboxMaxId = 本端已读到的最大入向消息 ID（0 = 全部已读/未知）
                // 第一条 id > readInboxMaxId 且非 isSent 的消息是"第一条未读"
                let readPos = getMessagesService().getReadPosition(chatIdCopy)
                let readInboxMaxId: Int32 = readPos.maxIncomingReadId
                var firstUnreadMsgId: Int64 = 0
                var unreadCnt: Int32 = 0
                if (readInboxMaxId > 0) {
                    for (m in messages) {
                        if (!m.isSent && Int32(m.id) > readInboxMaxId) {
                            if (firstUnreadMsgId == 0) { firstUnreadMsgId = m.id }
                            unreadCnt += 1
                        }
                    }
                }
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-112: readInboxMaxId=${readInboxMaxId}, firstUnreadId=${firstUnreadMsgId}, unreadCnt=${unreadCnt}")

                let firstUnreadCopy = firstUnreadMsgId
                let unreadCntCopy = unreadCnt
                launch {
                    if (nameToUpdate.size > 0) { this.chatName = nameToUpdate }
                    this.mergeMessageList(this.mergeFailedLocals(messages))
                    if (pruneChannelStrays && pruneMinId > 0) {
                        // 本地秒开渲染的频道缓存里，最新一页区间内服务端未返回的帖子已被删除
                        // （iOS HistoryViewStateValidation.swift:957-988 同样把它们移出视图）。
                        let strays = ArrayList<Int64>()
                        // V7 S7-117：这是 offsetId=0 的最新一页，iOS 的 filledRange 上界是 Int32.max
                        // （Holes.swift:506/1097-1143），比回包上界更新的本地缓存帖子同样已不在服务端
                        // （Whale Insider News 4817/4818 在最新页 [4696,4800] 之上，一直停在 "Loading…"）。
                        // 只处理秒开时从本地表读出的 id，推送刚到的新消息不在 localCloudIds 里。
                        let aboveTop = ArrayList<Int64>()
                        for (m in this.history.items) {
                            if (m.namespace != MessageHistoryView.NS_CLOUD || networkIds.contains(m.id)) { continue }
                            if (m.id >= pruneMinId && m.id <= pruneMaxId) {
                                strays.add(m.id)
                            } else if (m.id > pruneMaxId && localCloudIds.contains(m.id)) {
                                strays.add(m.id)
                                aboveTop.add(m.id)
                            }
                        }
                        for (id in strays) { let _ = this.history.remove(id) }
                        if (!strays.isEmpty()) {
                            Hilog.info(0, "CjTelegram",
                                "[HistoryValidation] removed ${strays.size} deleted channel post(s) from view, first=${strays[0]} aboveTop=${aboveTop.size} pageMax=${pruneMaxId}")
                        }
                        if (!aboveTop.isEmpty()) {
                            // 本地表里也删掉，否则下次秒开又会把已删帖子渲染出来。
                            let aboveCopy = aboveTop
                            spawn {
                                try {
                                    getMessageHistoryStore().removeMessages(chatIdCopy, aboveCopy, peerType: peerTypeCopy)
                                } catch (se: Exception) {
                                    Hilog.info(0, "CjTelegram", "[HistoryValidation] store removal above page top failed: ${se}")
                                }
                            }
                        }
                    }
                    if (connectedLowerId > 0) {
                        let evicted = this.history.removeCloudBelow(connectedLowerId)
                        if (evicted > 0) {
                            Hilog.info(0, "CjTelegram",
                                "[HistoryPaging] evicted ${evicted} cached msgs below hole, connectedLowerId=${connectedLowerId}")
                        }
                    }
                    this.hasMoreHistory = hasMore
                    // 恢复列表已经连续延伸到本地最新端；无需构造 newer hole。
                    // 下箭头由页面可见位置判断，点击时可直接滚到本列表末尾。
                    this.hasMoreNewer = false
                    this.firstUnreadId = firstUnreadCopy
                    this.unreadCountForAnchor = unreadCntCopy
                    // 置于最后：此时 firstUnreadId 已是最终值，页面可据此定案首帧滚动。
                    this.initialLoadDone = true
                }

                this.downloadPhotosForMessages(messages)
                launch { this.isLoading = false }
                if (continueMigrated) { this.loadMoreMigratedHistory() }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Failed to load messages: ${e}")
                logExceptionStack("[ChatRoomVM] loadMessages", e)
                launch {
                    this.initialLoadDone = true
                    this.isLoading = false
                }
            }
        }
    }
    
    /**
     * 将 TL 消息转换为 UI Message 列表
     * 
     * Phase Q1: 委托给 RealMessageService.parseMessages() 统一解析管线。
     * ViewModel 仅负责传入 photoPathCache 用于恢复已下载路径。
     */
    private func convertTLMessages(historyResponse: MessagesHistoryResponse): ArrayList<Message> {
        let messages = getRealMessageService().parseMessages(
            historyResponse,
            this.currentUserId,
            this.photoPathCache,
            conversationPeerType: this.peerType,
            conversationPeerId: this.chatId
        )
        this.applySenderRoles(messages)
        // Phase P5-11: 应用已读回执状态到消息列表
        this.applyReadOutboxStatusToMessages(messages)
        this.resolveReplyPreviews(messages)
        return messages
    }

    // 已请求过预览的被回复消息 id（含服务端已删除、取不回的），避免每次轮询重复拉取。
    private var _replyPreviewRequested: HashMap<Int64, Bool> = HashMap<Int64, Bool>()

    /**
     * 回复引用的被回复消息不在本页时补全预览。
     *
     * 对齐 iOS：ReplyMessageAttribute 只存 messageId，气泡渲染时从 Postbox 的
     * associatedMessages 取被回复消息（ChatMessageReplyInfoNode 的 arguments.message）；
     * 本地没有时由 TelegramCore 按 id 拉取缺失消息（messages.getMessages /
     * channels.getMessages）。此前鸿蒙侧只在同一页 30 条里找，被回复消息较早时引用只剩 "..."。
     * 顺序：先查已加载的会话历史，仍缺的再按 id 批量拉取。
     */
    private func resolveReplyPreviews(messages: ArrayList<Message>): Unit {
        var needsLookup = false
        for (m in messages) {
            if (m.replyToMsgId > 0 && m.replyToText.size == 0) {
                needsLookup = true
                break
            }
        }
        if (!needsLookup) { return }
        let loaded = HashMap<Int64, Message>()
        for (h in this.history.items) { loaded[h.id] = h }
        let missing = ArrayList<Int32>()
        let pending = ArrayList<Message>()
        for (m in messages) {
            if (m.replyToMsgId <= 0 || m.replyToText.size > 0) { continue }
            match (loaded.get(m.replyToMsgId)) {
                case Some(target) =>
                    m.replyToText = truncateRunes(target.content, 50)
                    if (m.replyToSenderName.size == 0) { m.replyToSenderName = target.senderName }
                case None =>
                    pending.add(m)
                    let requested = synchronized(this._replyPreviewLock) {
                        if (this._replyPreviewRequested.contains(m.replyToMsgId)) {
                            true
                        } else {
                            this._replyPreviewRequested[m.replyToMsgId] = true
                            false
                        }
                    }
                    if (!requested) { missing.add(Int32(m.replyToMsgId)) }
            }
        }
        if (missing.isEmpty()) { return }
        let peerTypeCopy = this.peerType
        let chatIdCopy = this.chatId
        spawn {
            try {
                let svc = getRealMessageService()
                let bytes = if (normalizeDialogPeerType(peerTypeCopy) == "channel") {
                    svc.getChannelMessages(chatIdCopy, svc.getAccessHashForChannel(chatIdCopy), missing)
                } else {
                    svc.getMessagesByIds(missing)
                }
                if (bytes.size == 0) { return }
                let fetched = svc.parseMessages(
                    MessagesHistoryResponse.deserialize(bytes),
                    this.currentUserId,
                    this.photoPathCache,
                    conversationPeerType: peerTypeCopy,
                    conversationPeerId: chatIdCopy
                )
                for (target in fetched) {
                    let text = truncateRunes(target.content, 50)
                    let sender = target.senderName
                    for (m in pending) {
                        if (m.replyToMsgId != target.id) { continue }
                        // 尚未入列的对象直接回填；已入列的经 history.update 触发重绘。
                        m.replyToText = text
                        if (m.replyToSenderName.size == 0) { m.replyToSenderName = sender }
                        let _ = this.history.update(m.id, { x: Message =>
                            x.replyToText = text
                            if (x.replyToSenderName.size == 0) { x.replyToSenderName = sender }
                        })
                    }
                }
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] reply previews fetched=${fetched.size} requested=${missing.size}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] reply preview fetch failed: ${e}")
            }
        }
    }
    private let _replyPreviewLock: Mutex = Mutex()

    private func applySenderRoles(messages: ArrayList<Message>): Unit {
        for (message in messages) {
            if (message.senderPeerType == "user" && this.senderRoleById.contains(message.senderId)) {
                message.senderRole = this.senderRoleById[message.senderId]
            }
        }
    }

    /**
     * 安全加载 iOS authorRank。频道使用带完整 ctor/Vector 边界检查的 PeerInfoService，
     * 不再调用此前导致进群闪退的旧 getChannelAdmins 手写解析器。
     */
    private func loadSenderRoles(peerType: String, peerId: Int64, accessHash: Int64): Unit {
        if (peerType != "chat" && peerType != "channel") { return }
        let roles = HashMap<Int64, String>()
        try {
            if (peerType == "channel") {
                let peerInfo = getPeerInfoService()
                if (accessHash != 0) {
                    peerInfo.registerChannelAccessHash(peerId, accessHash)
                }
                let result = peerInfo.getParticipantsByFilter(peerId, "admins", 0, 200, "")
                if (result.error.size > 0) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] author ranks skipped: ${result.error}")
                    return
                }
                for (member in result.members) {
                    roles[member.userId] = if (member.isCreator) {
                        "owner"
                    } else if (member.rank.size > 0) {
                        member.rank
                    } else if (member.isAdmin) {
                        "admin"
                    } else { "" }
                }
            } else {
                let full = getRealMessageService().getFullChatInfo("chat", peerId)
                for (participant in full.participants) {
                    if (participant.isCreator) {
                        roles[participant.userId] = "owner"
                    } else if (participant.isAdmin) {
                        roles[participant.userId] = "admin"
                    }
                }
            }
            this.senderRoleById = roles
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] author rank load failed safely: ${e}")
        }
    }

    /**
     * 只预取首屏附近媒体。iOS 由可见 item 的 MediaBox resourceData 订阅触发，
     * 不会因恢复位置而下载“锚点到最新端”的全部图片；这里取锚点前 6 条、后 38 条，
     * 无锚点则取末 44 条，兼顾首屏与下一屏。
     */
    private func initialMediaWindow(messages: ArrayList<Message>, anchorId: Int64): ArrayList<Message> {
        let result = ArrayList<Message>()
        if (messages.isEmpty()) { return result }
        var anchorIndex: Int64 = messages.size - 1
        if (anchorId > 0) {
            var i: Int64 = 0
            while (i < messages.size) {
                if (messages[i].id == anchorId) {
                    anchorIndex = i
                    break
                }
                i += 1
            }
        }
        var start = if (anchorId > 0) { anchorIndex - 6 } else { messages.size - 44 }
        if (start < 0) { start = 0 }
        var end = start + 44
        if (end > messages.size) { end = messages.size }
        var i = start
        while (i < end) {
            result.add(messages[i])
            i += 1
        }
        return result
    }

    /**
     * Resolve one sticker independently of the generic photo/document batch.
     * iOS starts MediaBox fetching as soon as the history item is delivered;
     * keeping stickers behind every missing photo and video thumbnail made a
     * newly received 50–250 KB animation wait seconds despite high RPC
     * priority. Animated resources also prepare frame 0/1 before their local
     * path is published, so the mounted bubble consumes a ready short-lived
     * representation instead of starting VP9/Lottie work on the UI deadline.
     */
    private func resolveStickerMessage(
        msg: Message,
        mediaGeneration: Int64,
        interactive: Bool,
        netStatus: NetworkStatus
    ): Unit {
        if (msg.documentId == 0 || msg.messageType != "sticker") { return }
        if (!this._mediaActive || mediaGeneration != this._mediaGeneration) { return }

        let isVideo = msg.documentMimeType.contains("webm")
        let isLottie = msg.documentMimeType.contains("tgs") ||
            msg.documentMimeType.contains("lottie")
        if (isVideo && !msg.documentLocalPath.isEmpty() &&
            !msg.documentLocalPath.endsWith(".webm")) {
            msg.documentLocalPath = ""
            let _ = this.photoPathCache.remove(msg.documentId)
            Hilog.info(0, "CjTelegram",
                "[ChatRoomVM] discarded invalid WebM sticker cache id=${msg.documentId}")
        }
        if (!msg.documentLocalPath.isEmpty()) { return }

        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) { return }
        let stickerDir = if (isLottie) {
            filesDir + "/anim_stickers"
        } else {
            filesDir + "/stickers"
        }
        try { FileIo.mkdir(stickerDir) } catch (_e: Exception) {}
        let ext = if (isLottie) {
            ".tgs"
        } else if (isVideo) {
            ".webm"
        } else if (msg.documentMimeType.contains("png")) {
            ".png"
        } else {
            ".webp"
        }
        let filePath = stickerDir + "/sticker_${msg.documentId}${ext}"
        let localUri = "file://" + filePath

        if (this.usableMediaFile(filePath)) {
            if (interactive && (isLottie || isVideo)) {
                let _ = preloadAnimatedStickerFileStream(
                    msg.documentId, localUri, isVideo)
            }
            this.applyMediaPath(msg, msg.documentId, localUri, "doc")
            return
        }

        let downloadService = getFileDownloadService()
        if (!downloadService.shouldAutoDownload("sticker", msg.documentSize, netStatus)) {
            Hilog.info(0, "CjTelegram",
                "[IncomingStickerPerf] auto-download suppressed id=${msg.documentId}")
            return
        }

        let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let priority: Int32 = if (interactive) { 95 } else { 10 }
        try {
            let bytes = downloadService.downloadDocument(
                msg.documentId,
                msg.documentAccessHash,
                msg.documentFileReference,
                msg.documentDcId,
                fileSize: msg.documentSize,
                priority: priority
            )
            let downloadedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
            if (bytes.isEmpty()) {
                Hilog.info(0, "CjTelegram",
                    "[IncomingStickerPerf] empty id=${msg.documentId} downloadMs=${downloadedAt - startedAt}")
                return
            }
            let file = FileIo.open(filePath, mode: 0o1101)
            FileIo.write(file.fd, bytes)
            FileIo.close(file)

            var prepared = false
            if (interactive && (isLottie || isVideo) && this._mediaActive &&
                mediaGeneration == this._mediaGeneration) {
                prepared = preloadAnimatedStickerFileStream(
                    msg.documentId, localUri, isVideo)
            }
            if (this._mediaActive && mediaGeneration == this._mediaGeneration) {
                this.applyMediaPath(msg, msg.documentId, localUri, "doc")
            }
            Hilog.info(0, "CjTelegram",
                "[IncomingStickerPerf] ready id=${msg.documentId} video=${isVideo} lottie=${isLottie} bytes=${bytes.size} downloadMs=${downloadedAt - startedAt} prepareMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - downloadedAt} prepared=${prepared}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[IncomingStickerPerf] failed id=${msg.documentId}: ${e}")
        }
    }

    /** photoIds with an in-flight visible (interactive) fetch; UI thread only. */
    private let _visiblePhotoFetches: HashSet<Int64> = HashSet<Int64>()

    /**
     * Visible-first photo fetch. iOS ChatMessageInteractiveMediaNode starts the
     * image fetch when its node is displayed (fetchControls.fetch on layout, gated by
     * visibilityPromise), so on-screen media never waits behind prefetch of pages the
     * user has already scrolled past. Here history pages still enqueue every photo at
     * background priority; the rows the List reports as visible are re-requested at
     * interactive priority, and FileDownloadService raises an already queued entry.
     * Must be called on the UI thread.
     */
    public func prioritizeVisibleMedia(visible: ArrayList<Message>): Unit {
        let pending = ArrayList<Message>()
        for (m in visible) {
            if (m.photoId == 0 || !m.photoLocalPath.isEmpty()) { continue }
            if (this._visiblePhotoFetches.contains(m.photoId)) { continue }
            let _ = this._visiblePhotoFetches.add(m.photoId)
            pending.add(m)
        }
        if (pending.isEmpty()) { return }
        let _ = spawn {
            this.downloadPhotosForMessages(pending, interactive: true)
            launch {
                for (m in pending) { let _ = this._visiblePhotoFetches.remove(m.photoId) }
            }
        }
    }

    /**
     * 为消息列表中的照片消息同步下载照片（必须在 spawn 内调用）
     * 下载完成后更新 Message.photoLocalPath 并刷新列表触发 UI 更新
     * 注意：此函数不会创建新线程，调用者必须保证已在后台线程中
     */
    /**
     * S7-93: the chat's auto-download peer type, as iOS ChatHistoryListNode.swift:380-405
     * computes automaticMediaDownloadPeerType — private chat → contact / otherPrivate,
     * basic group → group, channel → group for megagroups and channel for broadcasts.
     */
    private func autoDownloadPeerKind(): String {
        if (this.peerType == "user") {
            var isContact = false
            match (getRealChatListService().getCachedUser(this.chatId)) {
                case Some(u) => isContact = u.isContact
                case None =>
                    match (getPeerStore().getLocalPeer(this.chatId)) {
                        case Some(p) => isContact = p.isContact
                        case None => ()
                    }
            }
            return if (isContact) { "contact" } else { "otherPrivate" }
        }
        if (this.peerType == "channel") {
            var broadcast = this.channelIsBroadcast
            match (getRealChatListService().getCachedChat("channel", this.chatId)) {
                case Some(c) => broadcast = c.isBroadcast
                case None => ()
            }
            return if (broadcast) { "channel" } else { "group" }
        }
        return "group"
    }

    /**
     * S7-93: tap on a photo whose automatic download was suppressed by the auto-download
     * settings — fetch it on demand (iOS ChatMessageInteractiveMediaNode tap → fetch when
     * automaticDownload is .none). Must be called on the UI thread.
     */
    public func downloadPhotoOnTap(msg: Message): Unit {
        if (msg.photoId == 0 || msg.photoLocalPath.size > 0 || msg.photoDownloadState == 2) { return }
        this.setPhotoDownloadState(msg, 2)
        let target = msg
        let _ = spawn {
            let one = ArrayList<Message>()
            one.add(target)
            this.downloadPhotosForMessages(one, interactive: true, force: true, autosave: true)
            launch {
                if (target.photoLocalPath.isEmpty()) {
                    this.setPhotoDownloadState(target, 1)
                }
            }
        }
    }

    private func setPhotoDownloadState(msg: Message, state: Int32): Unit {
        var changed = false
        if (msg.photoDownloadState != state) {
            msg.photoDownloadState = state
            changed = true
        }
        for (m in this.history.items) {
            if (m.photoId == msg.photoId && m.photoDownloadState != state && m.photoLocalPath.isEmpty()) {
                m.photoDownloadState = state
                changed = true
            }
        }
        if (changed) { this.refreshMessageSnapshot() }
    }

    /**
     * Media paths are persisted with the message (IntermediateMessage EM_*_LOCAL_PATH) and kept in
     * this room's photoPathCache, but the files live in the media cache directories that Clear
     * Cache / auto-remove delete. iOS never stores a path: every media node asks MediaBox for the
     * resource and fetches it again when the file is gone (FetchedMediaResource.swift / MediaBox
     * resourceData). Here a cached path whose file is missing or empty is dropped so the normal
     * fetch below runs, instead of rendering an Image over a deleted file (blank bubble, black
     * gallery page). Only files inside the app media cache are checked; pending uploads keep
     * their picker URIs. Returns true when any field was cleared.
     */
    private func dropMissingMediaPaths(m: Message, filesDir: String): Bool {
        let cachePrefix = "file://" + filesDir + "/"
        var changed = false
        if (m.photoId != 0 && m.photoLocalPath.startsWith(cachePrefix) &&
            !this.usableMediaFile(m.photoLocalPath[7..])) {
            m.photoLocalPath = ""
            m.photoDownloadState = 0
            let _ = this.photoPathCache.remove(m.photoId)
            changed = true
        }
        // A downloaded file (documents/) is only the resource when it is exactly document.size
        // long; a wrong-length file is refetched instead of being handed to the system viewer.
        if (m.documentId != 0 && m.documentLocalPath.startsWith(cachePrefix) &&
            (!this.usableMediaFile(m.documentLocalPath[7..]) ||
                (m.documentLocalPath.startsWith(cachePrefix + "documents/") &&
                    !downloadedFileMatchesSize(m.documentLocalPath[7..], m.documentSize)))) {
            m.documentLocalPath = ""
            let _ = this.photoPathCache.remove(m.documentId)
            changed = true
        }
        if (m.documentId != 0 && m.documentThumbnailPath.startsWith(cachePrefix) &&
            !this.usableMediaFile(m.documentThumbnailPath[7..])) {
            m.documentThumbnailPath = ""
            changed = true
        }
        if (m.webPagePhotoId != 0 && m.webPagePhotoLocalPath.startsWith(cachePrefix) &&
            !this.usableMediaFile(m.webPagePhotoLocalPath[7..])) {
            m.webPagePhotoLocalPath = ""
            let _ = this.photoPathCache.remove(m.webPagePhotoId)
            changed = true
        }
        return changed
    }

    /** Photo ids whose file reference was already refreshed once in this room. */
    /** photoId → 上次发起 file_reference 复核的毫秒时间戳（V7 S7-117：此前永久只校验一次）。 */
    private let _photoRefRevalidated: HashMap<Int64, Int64> = HashMap<Int64, Int64>()
    private let _photoRefRevalidatedLock: Mutex = Mutex()
    /** 同一 photoId 两次复核之间的最短间隔；iOS 每次 FILE_REFERENCE_* 都重新 revalidate，
     *  这里只防止同一次失败风暴里反复打服务端。 */
    private static let PHOTO_REF_REVALIDATE_MIN_GAP_MS: Int64 = 15_000

    /**
     * iOS MultipartFetch.swift:356-395: a FILE_REFERENCE_* error revalidates the media reference
     * (FetchedMediaResource.swift:857 revalidateMediaResourceReference → .message → refetch the
     * message, :456) and retries the part with the fresh file_reference. Messages paged from the
     * local store carry the reference saved when they were first fetched, which the server
     * rejects once it expires. Refetch those messages (channels.getMessages / messages.getMessages),
     * copy the fresh photo reference onto the room's messages and fetch once more.
     *
     * V7 S7-117（Whale Insider News，channel 3015415927）："revalidated 0/2" 的根因：本地表里的
     * 两条帖子（4817/4818，photo …573/…574）在服务端已被删除 —— 最新一页 getHistory 的上界只到
     * 4800，channels.getMessages 对这两个 id 回的是 messageEmpty（解析日志 "Parsing 2 messages"
     * 后没有任何 [parseMedia] 行）。旧实现只按 (id, photoId) 精确匹配，messageEmpty 被
     * parseMessages 直接丢弃，于是两条帖子永远停在 "Loading…"，而且每个 photoId 终身只校验一次。
     * 现在对齐 iOS HistoryViewStateValidation.swift:957-988（validateBatch：服务端未返回的可见
     * 消息 _internal_deleteMessages）：messageEmpty → 把该帖子移出视图与本地表；返回的消息按
     * id 取其当前照片（含被编辑后换图、网页预览图）回填新 file_reference。
     * Background thread only. Returns the messages whose reference changed.
     */
    private func revalidatePhotoReferences(expired: ArrayList<Message>): ArrayList<Message> {
        let refreshed = ArrayList<Message>()
        let ids = ArrayList<Int32>()
        let pending = ArrayList<Message>()
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        for (m in expired) {
            if (m.id <= 0 || m.photoId == 0) { continue }
            let allowed = synchronized(this._photoRefRevalidatedLock) {
                let last = this._photoRefRevalidated.get(m.photoId) ?? 0
                if (nowMs - last < ChatRoomViewModel.PHOTO_REF_REVALIDATE_MIN_GAP_MS) {
                    false
                } else {
                    this._photoRefRevalidated[m.photoId] = nowMs
                    true
                }
            }
            if (!allowed) {
                Hilog.info(0, "CjTelegram",
                    "[ChatRoomVM] photo file_reference revalidation throttled msg=${m.id} photo=${m.photoId}")
                continue
            }
            pending.add(m)
            ids.add(Int32(m.id))
        }
        if (ids.isEmpty()) { return refreshed }
        let peerTypeCopy = this.peerType
        let chatIdCopy = this.chatId
        var idText = ""
        for (id in ids) { idText = idText + (if (idText.size > 0) { "," } else { "" }) + "${id}" }
        Hilog.info(0, "CjTelegram",
            "[ChatRoomVM] photo file_reference revalidate request peer=${peerTypeCopy}:${chatIdCopy} ids=[${idText}]")
        try {
            let svc = getRealMessageService()
            let isChannel = normalizeDialogPeerType(peerTypeCopy) == "channel"
            let bytes = if (isChannel) {
                svc.getChannelMessages(chatIdCopy, svc.getAccessHashForChannel(chatIdCopy), ids)
            } else {
                svc.getMessagesByIds(ids)
            }
            if (bytes.size < 8) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] photo file_reference revalidation: empty response")
                return refreshed
            }
            let response = MessagesHistoryResponse.deserialize(bytes)
            // 服务端明确回 messageEmpty 的 id：帖子已删除（iOS validateBatch 同样删除）。
            let emptyIds = HashSet<Int64>()
            let presentIds = HashSet<Int64>()
            for (tl in response.messages) {
                if (tl.isEmpty) { emptyIds.add(Int64(tl.id)) } else { presentIds.add(Int64(tl.id)) }
            }
            let fetched = svc.parseMessages(
                response,
                this.currentUserId,
                HashMap<Int64, String>(),
                conversationPeerType: peerTypeCopy,
                conversationPeerId: chatIdCopy
            )
            for (fresh in fetched) {
                Hilog.info(0, "CjTelegram",
                    "[ChatRoomVM] revalidate fetched msg=${fresh.id} photo=${fresh.photoId} ref=${fresh.photoFileReference.size}B webPhoto=${fresh.webPagePhotoId} webRef=${fresh.webPagePhotoFileReference.size}B")
                for (m in pending) {
                    if (m.id != fresh.id) { continue }
                    var newId: Int64 = 0
                    var newHash: Int64 = 0
                    var newRef = Array<Byte>(0, repeat: 0)
                    var newDc: Int32 = 0
                    if (fresh.photoId != 0 && fresh.photoFileReference.size > 0) {
                        // 同一条消息当前的照片（可能是编辑后换过的图）。
                        newId = fresh.photoId
                        newHash = fresh.photoAccessHash
                        newRef = fresh.photoFileReference
                        newDc = fresh.photoDcId
                    } else if (fresh.webPagePhotoId == m.photoId && fresh.webPagePhotoFileReference.size > 0) {
                        newId = fresh.webPagePhotoId
                        newHash = fresh.webPagePhotoAccessHash
                        newRef = fresh.webPagePhotoFileReference
                        newDc = fresh.webPagePhotoDcId
                    }
                    if (newId == 0) {
                        Hilog.info(0, "CjTelegram",
                            "[ChatRoomVM] revalidate msg=${m.id}: server copy has no photo (was photo=${m.photoId})")
                        continue
                    }
                    let oldPhotoId = m.photoId
                    let changedPhoto = newId != oldPhotoId
                    m.photoId = newId
                    m.photoFileReference = newRef
                    if (newHash != 0) { m.photoAccessHash = newHash }
                    if (newDc != 0) { m.photoDcId = newDc }
                    for (h in this.history.items) {
                        if (h.id == m.id || (h.photoId == oldPhotoId && oldPhotoId != 0)) {
                            h.photoId = newId
                            h.photoFileReference = newRef
                            if (newHash != 0) { h.photoAccessHash = newHash }
                            if (newDc != 0) { h.photoDcId = newDc }
                        }
                    }
                    Hilog.info(0, "CjTelegram",
                        "[ChatRoomVM] revalidate msg=${m.id}: photo ${oldPhotoId} -> ${newId} ref=${newRef.size}B changed=${changedPhoto}")
                    refreshed.add(m)
                }
            }
            // 已删除的帖子：移出视图 + 本地表（iOS HistoryViewStateValidation.swift:987）。
            let deleted = ArrayList<Int64>()
            for (m in pending) {
                if (emptyIds.contains(m.id) || (!presentIds.contains(m.id) && response.messages.size > 0 && !response.messagesTruncated)) {
                    deleted.add(m.id)
                }
            }
            if (!deleted.isEmpty()) {
                var delText = ""
                for (id in deleted) { delText = delText + (if (delText.size > 0) { "," } else { "" }) + "${id}" }
                Hilog.info(0, "CjTelegram",
                    "[HistoryValidation] peer=${peerTypeCopy}:${chatIdCopy} messages [${delText}] missing on server (messageEmpty) -> removed from view and store")
                try {
                    getMessageHistoryStore().removeMessages(chatIdCopy, deleted, peerType: peerTypeCopy)
                } catch (se: Exception) {
                    Hilog.info(0, "CjTelegram", "[HistoryValidation] store removal failed: ${se}")
                }
                launch {
                    var removedAny = false
                    for (id in deleted) {
                        if (this.history.remove(id)) { removedAny = true }
                    }
                    if (removedAny) { this.refreshMessageSnapshot() }
                }
            }
            Hilog.info(0, "CjTelegram",
                "[ChatRoomVM] photo file_reference revalidated ${refreshed.size}/${pending.size} deleted=${deleted.size} peer=${peerTypeCopy}:${chatIdCopy}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] photo file_reference revalidation failed: ${e}")
        }
        return refreshed
    }

    private func downloadPhotosForMessages(
        messages: ArrayList<Message>,
        interactive!: Bool = false,
        force!: Bool = false,
        autosave!: Bool = false
    ): Unit {
        let mediaGeneration = this._mediaGeneration
        let autoPeerKind = this.autoDownloadPeerKind()
        let mediaPriority: Int32 = if (interactive) { 80 } else { 10 }
        // P2-321b: snapshot network status once per batch (avoids repeated IPC per item)
        let _netStatus: NetworkStatus = ReachabilityService.getInstance().currentStatus()
        let _dlSvc = getFileDownloadService()


        let photosToDownload = ArrayList<Message>()
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] filesDir is EMPTY, skip photo download")
            return
        }
        var droppedMissing: Int64 = 0
        for (message in messages) {
            if (this.dropMissingMediaPaths(message, filesDir)) { droppedMissing += 1 }
        }
        if (droppedMissing > 0) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] dropped ${droppedMissing} cached media paths whose files are gone")
            this.refreshMessageSnapshot()
        }
        let expiredRefs = ArrayList<Message>()

        // Resource-level scheduling: sticker fetch/decode starts immediately
        // and never waits behind unrelated image work in this history batch.
        for (message in messages) {
            if (message.documentId != 0 && message.messageType == "sticker") {
                let stickerMessage = message
                let _ = spawn {
                    this.resolveStickerMessage(
                        stickerMessage, mediaGeneration, interactive, _netStatus)
                }
            }
        }
        let photoDir = filesDir + "/photos"
        try { FileIo.mkdir(photoDir) } catch (_e: Exception) {}
        var publishExistingPaths = false
        
        for (msg in messages) {
            if (msg.photoId != 0 && msg.photoLocalPath.isEmpty()) {
                let bubbleType = this.photoBubbleType(msg)
                let filePathPreferred = photoDir + "/photo_${msg.photoId}_${bubbleType}.jpg"
                let filePathM = photoDir + "/photo_${msg.photoId}_m.jpg"
                let filePathOld = photoDir + "/photo_${msg.photoId}.jpg"
                var foundPath = ""
                if (this.usableMediaFile(filePathPreferred)) {
                    foundPath = filePathPreferred
                } else {
                    if (this.usableMediaFile(filePathM)) {
                        foundPath = filePathM
                    } else {
                        if (this.usableMediaFile(filePathOld)) {
                            foundPath = filePathOld
                        }
                    }
                }
                if (foundPath.size > 0) {
                    let localUri = "file://" + foundPath
                    this.applyMediaPath(msg, msg.photoId, localUri, "photo")
                } else {
                    photosToDownload.add(msg)
                }
            } else if (msg.photoId != 0 && !this.photoPathCache.contains(msg.photoId)) {
                // Path already filled on a shared Message (another room, or the
                // local store); record it and publish once for this room.
                this.photoPathCache[msg.photoId] = msg.photoLocalPath
                publishExistingPaths = true
            }
        }
        if (publishExistingPaths) { this.refreshMessageSnapshot() }
        
        let downloadService = _dlSvc


        // P2-XXX: 分批并行下载照片（每批 N 张并发），替代原串行 while。
        // downloadPhoto 是 per-msgId 并发安全的（内部已 4 路分片并行）；N=4 → 最多 16 并发请求。
        // 下载并行、落盘+状态更新串行（保持单线程写 photoPathCache/messageList，避免并发写崩溃）。
        let batchN: Int64 = 4
        var dlIdx: Int64 = 0
        while (dlIdx < photosToDownload.size) {
            // 每批开始检查中断与自动下载门控
            if (!this._mediaActive || mediaGeneration != this._mediaGeneration) {
                break
            }
            // P2-321b: auto-download gate for photos
            if (!force && !downloadService.shouldAutoDownload("photo", 0, _netStatus, peerKind: autoPeerKind)) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] photo auto-download suppressed by gate (netStatus, dataSaving, or type toggle)")
                // S7-93: leave these photos on the manual-download affordance (iOS shows the
                // download arrow when automaticDownload == .none).
                var si = dlIdx
                var anySuppressed = false
                while (si < photosToDownload.size) {
                    let pm = photosToDownload[si]
                    si += 1
                    if (pm.photoDownloadState == 0) {
                        pm.photoDownloadState = 1
                        anySuppressed = true
                    }
                }
                if (anySuppressed) { this.refreshMessageSnapshot() }
                break
            }

            // 组装本批：每张 spawn 得 Future，闭包只捕获 let（每次迭代新绑定）
            let futs = ArrayList<Future<Array<UInt8>>>()
            let batchIds = ArrayList<Int64>()
            let batchPaths = ArrayList<String>()
            let batchMsgs = ArrayList<Message>()
            var bi: Int64 = 0
            while (bi < batchN && dlIdx < photosToDownload.size) {
                let msg = photosToDownload[dlIdx]
                dlIdx += 1
                bi += 1
                let photoIdCopy = msg.photoId
                let accessHashCopy = msg.photoAccessHash
                let fileRefCopy = msg.photoFileReference
                // 收到的图气泡清晰度：此前写死 "m"(320px)→在气泡物理宽被放大发糊
                // （"发的高清收的糊"：发的有本地原图，收的只下了 320px）。
                // 用 "y"(1280px≈720p) 对齐 iOS 清晰度；封顶 y（不下 "w"2560，气泡浪费/拖慢）。
                // 大照片(y/w)→"y"；照片最大只到 "x"→"x"；极小图(仅 s/m)→其最大 type。
                let bubbleType = this.photoBubbleType(msg)
                let filePath = photoDir + "/photo_${photoIdCopy}_${bubbleType}.jpg"
                futs.add(spawn {
                    downloadService.downloadPhoto(
                        photoIdCopy,
                        accessHashCopy,
                        fileRefCopy,
                        thumbSize: bubbleType,
                        priority: mediaPriority
                    )
                })
                batchIds.add(photoIdCopy)
                batchPaths.add(filePath)
                batchMsgs.add(msg)
            }

            // 收集：串行处理写盘 + 状态更新（单线程，避免 HashMap/列表并发写）
            var fi: Int64 = 0
            while (fi < futs.size) {
                let photoIdCopy = batchIds[fi]
                let filePath = batchPaths[fi]
                let msg = batchMsgs[fi]
                fi += 1
                try {
                    let photoBytes = futs[fi - 1].get()

                    if (photoBytes.size > 0) {
                        let file = FileIo.open(filePath, mode: 0o1101)
                        FileIo.write(file.fd, photoBytes)
                        FileIo.close(file)
                        let localUri = "file://" + filePath

                        this.applyMediaPath(msg, photoIdCopy, localUri, "photo")
                        // S7-95: Save to Camera Roll — iOS stores a chat photo right after its
                        // remote fetch (PhotoResources.swift:2035 storeDownloadedMedia). Limited to
                        // photos fetched for newly arrived messages or by tap: every save here
                        // raises the system save-confirmation dialog (no WRITE_IMAGEVIDEO), so
                        // back-filling a whole history page would stack one dialog per photo.
                        if (autosave && getSaveToCameraRollService().shouldAutosavePhoto(
                                this.peerType, this.chatId, this.channelIsBroadcast)) {
                            // W5 S7-95 / iOS StoreDownloadedMedia.swift:62-63：相册存的是
                            // largestImageRepresentation，且 resourceData 完整落盘后才写入；
                            // 气泡缓存的是 "x"(800px)，这里先取/下最大尺寸再交给自动保存。
                            let saveUri = this.downloadFullResPhoto(msg)
                            let autosaveUri = if (saveUri.size > 0) { saveUri } else { localUri }
                            Hilog.info(0, "CjTelegram", "[ChatRoomVM] autosave candidate photo=${photoIdCopy} bubble=${localUri} largest=${autosaveUri}")
                            getSaveToCameraRollService().autosaveDownloadedPhoto(
                                autosaveUri, this.peerType, this.chatId, this.channelIsBroadcast)
                        }

                    } else {
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Photo EMPTY data for id=${photoIdCopy}")
                        if (downloadService.takeFileReferenceExpired(photoIdCopy)) {
                            expiredRefs.add(msg)
                        }
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Photo FAILED for id=${photoIdCopy}: ${e}")
                }
            }
        }
        if (!expiredRefs.isEmpty() && this._mediaActive && mediaGeneration == this._mediaGeneration) {
            let refreshed = this.revalidatePhotoReferences(expiredRefs)
            if (!refreshed.isEmpty()) {
                // Refreshed references are fetched once more; _photoRefRevalidated stops a loop.
                this.downloadPhotosForMessages(refreshed, interactive: interactive, force: true, autosave: autosave)
            }
        }

        // ==================== 视频缩略图下载 ====================
        // 对有 documentId 的视频消息，下载缩略图用于预览显示
        let videosToDownload = ArrayList<Message>()
        let thumbDir = filesDir + "/thumbs"
        try { FileIo.mkdir(thumbDir) } catch (_e: Exception) {}
        
        for (msg in messages) {
            // video 气泡拿 documentLocalPath 当海报图（Image + 播放键），维持 kind "doc"；
            // GIF 气泡的 documentLocalPath 必须留给真 mp4（会直接喂 Video 组件），
            // 缩略图走 docThumb。此前两者都写 "doc"，GIF 的 mp4 下载门卫被缩略图堵死。
            let wantThumb = if (msg.messageType == "gif") {
                msg.documentThumbnailPath.isEmpty()
            } else {
                // video_note 气泡同样拿 documentLocalPath 当圆形海报图（iOS 圆形视频未下载前显示缩略图）
                (msg.messageType == "video" || msg.messageType == "video_note") && msg.documentLocalPath.isEmpty()
            }
            if (msg.documentId != 0 && wantThumb) {
                let filePath = thumbDir + "/thumb_${msg.documentId}.jpg"
                var fileExists = false
                try { fileExists = FileIo.access(filePath) } catch (_e: Exception) {}
                if (fileExists) {
                    let localUri = "file://" + filePath
                    this.applyMediaPath(msg, msg.documentId, localUri,
                        if (msg.messageType == "gif") { "docThumb" } else { "doc" })
                } else {
                    videosToDownload.add(msg)
                }
            }
        }
        
        if (!videosToDownload.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] ${videosToDownload.size} video thumbs to download")
        }
        
        for (msg in videosToDownload) {
            if (!this._mediaActive || mediaGeneration != this._mediaGeneration) { break }
            
            let docIdCopy = msg.documentId
            let accessHashCopy = msg.documentAccessHash
            let fileRefCopy = msg.documentFileReference
            
            try {
                let filePath = thumbDir + "/thumb_${docIdCopy}.jpg"
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Downloading video thumb id=${docIdCopy}")
                let thumbBytes = downloadService.downloadDocumentThumb(
                    docIdCopy,
                    accessHashCopy,
                    fileRefCopy,
                    thumbSize: "m"
                )
                
                if (thumbBytes.size > 0) {
                    let file = FileIo.open(filePath, mode: 0o1101)
                    FileIo.write(file.fd, thumbBytes)
                    FileIo.close(file)
                    let localUri = "file://" + filePath

                    this.applyMediaPath(msg, docIdCopy, localUri,
                        if (msg.messageType == "gif") { "docThumb" } else { "doc" })

                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Video thumb saved: ${localUri} (${thumbBytes.size} bytes)")
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Empty thumb for docId=${docIdCopy}")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Video thumb download failed for id=${docIdCopy}: ${e}")
            }
        }
        // Image documents are rendered by iOS as interactive media previews. Some
        // documents (including heatmap.png) do not publish a usable thumbnail
        // representation, so small image documents fall back to the original resource.
        let imageDocsToDownload = ArrayList<Message>()
        let imageDocThumbDir = filesDir + "/document_thumbs"
        try { FileIo.mkdir(imageDocThumbDir) } catch (_e: Exception) {}
        for (msg in messages) {
            if (msg.documentId != 0 && msg.messageType == "document" &&
                msg.documentMimeType.startsWith("image/") && msg.documentThumbnailPath.isEmpty()) {
                let imageExt = if (msg.documentMimeType.contains("png")) { ".png" } else { ".jpg" }
                let thumbPath = imageDocThumbDir + "/image_${msg.documentId}${imageExt}"
                var thumbExists = false
                try { thumbExists = FileIo.access(thumbPath) } catch (_e: Exception) {}
                if (thumbExists) {
                    let cachedUri = "file://" + thumbPath
                    this.applyMediaPath(msg, msg.documentId, cachedUri, "docThumb")
                } else {
                    imageDocsToDownload.add(msg)
                }
            }
        }
        // Each Telegram file resource can spend up to the transport timeout waiting for
        // a CDN part. Run independent image resources concurrently so one stale item
        // cannot hold every newer image document behind it.
        for (msg in imageDocsToDownload) {
            let imageMsg = msg
            let _ = spawn {
                if (!this._mediaActive || mediaGeneration != this._mediaGeneration) { return }
                let docId = imageMsg.documentId
                try {
                    if (!downloadService.shouldAutoDownload("photo", imageMsg.documentSize, _netStatus, peerKind: autoPeerKind)) {
                        return
                    }
                    let imageBytes = downloadService.downloadDocument(
                        docId, imageMsg.documentAccessHash, imageMsg.documentFileReference, imageMsg.documentDcId,
                        fileSize: imageMsg.documentSize, priority: mediaPriority
                    )
                    if (imageBytes.size > 0) {
                        let ext = if (imageMsg.documentMimeType.contains("png")) { ".png" } else { ".jpg" }
                        let imagePath = imageDocThumbDir + "/image_${docId}${ext}"
                        let file = FileIo.open(imagePath, mode: 0o1101)
                        FileIo.write(file.fd, imageBytes)
                        FileIo.close(file)
                        let localUri = "file://" + imagePath
                        this.applyMediaPath(imageMsg, docId, localUri, "docThumb")
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Image document preview saved: ${localUri}")
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Image document thumb failed: ${docId}: ${e}")
                }
            }
        }
        // ==================== Phase P2-2: GIF 文件下载 ====================
        let gifsToDownload = ArrayList<Message>()
        let gifDir = filesDir + "/gifs"
        try { FileIo.mkdir(gifDir) } catch (_e: Exception) {}

        for (msg in messages) {
            if (msg.documentId != 0 && msg.messageType == "gif" && msg.documentLocalPath.isEmpty()) {
                let ext = if (msg.documentMimeType.contains("gif")) { ".gif" } else { ".mp4" }
                let filePath = gifDir + "/gif_${msg.documentId}${ext}"
                var fileExists = false
                try { fileExists = FileIo.access(filePath) } catch (_e: Exception) {}
                if (fileExists) {
                    let localUri = "file://" + filePath
                    this.applyMediaPath(msg, msg.documentId, localUri, "doc")
                } else {
                    gifsToDownload.add(msg)
                }
            }
        }

        if (!gifsToDownload.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] ${gifsToDownload.size} GIFs to download")

            for (msg in gifsToDownload) {
                if (!this._mediaActive || mediaGeneration != this._mediaGeneration) { break }
                // P2-321b: auto-download gate for GIFs
                if (!downloadService.shouldAutoDownload("gif", msg.documentSize, _netStatus, peerKind: autoPeerKind)) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] gif auto-download suppressed by gate")
                    break
                }

                let docIdCopy = msg.documentId
                let ext = if (msg.documentMimeType.contains("gif")) { ".gif" } else { ".mp4" }
                let filePath = gifDir + "/gif_${docIdCopy}${ext}"

                try {
                    let gifBytes = downloadService.downloadDocument(
                        docIdCopy, msg.documentAccessHash, msg.documentFileReference, msg.documentDcId,
                        fileSize: msg.documentSize, priority: mediaPriority
                    )
                    if (gifBytes.size > 0) {
                        let file = FileIo.open(filePath, mode: 0o1101)
                        FileIo.write(file.fd, gifBytes)
                        FileIo.close(file)
                        let localUri = "file://" + filePath

                        this.applyMediaPath(msg, docIdCopy, localUri, "doc")
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] GIF saved: ${localUri} (${gifBytes.size} bytes)")
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] GIF download failed for id=${docIdCopy}: ${e}")
                }
            }
        }
        // ==================== Phase P7B-1: 网页预览缩略图下载 ====================
        let webThumbsToDownload = ArrayList<Message>()
        let webThumbDir = filesDir + "/web_thumbs"
        try { FileIo.mkdir(webThumbDir) } catch (_e: Exception) {}

        for (msg in messages) {
            if (msg.webPagePhotoId != 0 && msg.webPagePhotoLocalPath.isEmpty()) {
                let filePath = webThumbDir + "/webthumb_${msg.webPagePhotoId}_m.jpg"
                var fileExists = false
                try { fileExists = FileIo.access(filePath) } catch (_e: Exception) {}
                if (fileExists) {
                    let localUri = "file://" + filePath
                    this.applyMediaPath(msg, msg.webPagePhotoId, localUri, "webPhoto")
                } else {
                    // 也查内存缓存
                    if (this.photoPathCache.contains(msg.webPagePhotoId)) {
                        this.applyMediaPath(msg, msg.webPagePhotoId,
                            this.photoPathCache[msg.webPagePhotoId], "webPhoto")
                    } else {
                        webThumbsToDownload.add(msg)
                    }
                }
            }
        }

        if (!webThumbsToDownload.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] ${webThumbsToDownload.size} web page thumbs to download")

            for (msg in webThumbsToDownload) {
                if (!this._mediaActive || mediaGeneration != this._mediaGeneration) { break }

                let wpPhotoId = msg.webPagePhotoId
                let wpAccessHash = msg.webPagePhotoAccessHash
                let wpFileRef = msg.webPagePhotoFileReference

                try {
                    let filePath = webThumbDir + "/webthumb_${wpPhotoId}_m.jpg"
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Downloading webPage thumb id=${wpPhotoId}")
                    let photoBytes = downloadService.downloadPhoto(
                        wpPhotoId,
                        wpAccessHash,
                        wpFileRef,
                        thumbSize: "m",
                        priority: mediaPriority
                    )

                    if (photoBytes.size > 0) {
                        let file = FileIo.open(filePath, mode: 0o1101)
                        FileIo.write(file.fd, photoBytes)
                        FileIo.close(file)
                        let localUri = "file://" + filePath

                        this.applyMediaPath(msg, wpPhotoId, localUri, "webPhoto")
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] WebPage thumb saved: ${localUri} (${photoBytes.size} bytes)")
                    } else {
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Empty webPage thumb for id=${wpPhotoId}")
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] WebPage thumb download failed for id=${wpPhotoId}: ${e}")
                }
            }
        }
    }
    
    // ==================== Phase P5-14: 全屏高清照片下载 ====================

    /**
     * 下载全分辨率照片（用于 ImageViewer 全屏查看）
     * 
     * 使用 thumbSize "y" 获取最高分辨率，下载完成后返回本地 URI。
     * 如果 "y" 已缓存在磁盘则直接返回。
     * 调用者需在 spawn 内调用此方法。
     */
    public func downloadFullResPhoto(msg: Message): String {
        if (msg.photoId == 0) { return "" }
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) { return "" }

        let photoDir = filesDir + "/photos"
        try { FileIo.mkdir(photoDir) } catch (_e: Exception) {}

        // 选实际最大分辨率变体 type（对齐 iOS largestImageRepresentation），而非写死 "y"。
        // 修此前"很糊"：许多照片无 "y"(1280) 尺寸 → 请求 "y" 拿不到回退到 "m"(320)；
        // 或原图更大(w 2560+)时也只取 1280。用照片实际有的最大 type 才是清晰版。
        let sizeType = if (msg.photoLargestType.size > 0) { msg.photoLargestType } else { "y" }
        let filePathLargest = photoDir + "/photo_${msg.photoId}_${sizeType}.jpg"
        var fileExists = false
        try { fileExists = FileIo.access(filePathLargest) } catch (_e: Exception) {}
        if (fileExists) {
            return "file://" + filePathLargest
        }

        // 兼容旧缓存文件名（_y / _x）
        for (legacy in ["y", "x"]) {
            let lp = photoDir + "/photo_${msg.photoId}_${legacy}.jpg"
            var ex = false
            try { ex = FileIo.access(lp) } catch (_e: Exception) {}
            if (ex) { return "file://" + lp }
        }

        let downloadService = getFileDownloadService()
        try {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Downloading full-res photo id=${msg.photoId} (size=${sizeType})")
            let photoBytes = downloadService.downloadPhoto(
                msg.photoId,
                msg.photoAccessHash,
                msg.photoFileReference,
                thumbSize: sizeType
            )
            if (photoBytes.size > 0) {
                let file = FileIo.open(filePathLargest, mode: 0o1101)
                FileIo.write(file.fd, photoBytes)
                FileIo.close(file)
                let localUri = "file://" + filePathLargest
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Full-res photo saved: ${localUri} (${photoBytes.size} bytes)")
                return localUri
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Full-res photo download failed: ${e}")
        }
        return ""
    }

    // ==================== Phase H5: 文档/文件下载 ====================
    
    /**
     * 下载文档/文件消息到本地
     * 
     * 下载完成后更新 Message.documentLocalPath 并刷新列表
     * 支持所有文档类型（视频、语音、文件、GIF 等）
     * 
     * 注意：此方法应在 spawn 内调用
     */
    public func downloadDocumentForMessage(msg: Message): Unit {
        if (msg.documentId == 0 || msg.documentLocalPath.size > 0) { return }
        if (msg.isFileDownloading) { return }  // 防止重复下载
        
        // 标记下载开始
        msg.isFileDownloading = true
        for (m in this.messageList) {
            if (m.documentId == msg.documentId) { m.isFileDownloading = true }
        }
        // Publish the downloading state so the bubble shows its progress indicator
        // right away (iOS ChatMessageInteractiveFileNode switches to the fetching
        // status as soon as the fetch starts).
        this.refreshMessageSnapshot()
        
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) {
            msg.isFileDownloading = false
            return
        }
        
        let docDir = filesDir + "/documents"
        try { FileIo.mkdir(docDir) } catch (_e: Exception) {}
        
        // 根据 MIME 类型确定文件扩展名
        var ext = ""
        if (msg.documentFileName.size > 0) {
            let parts = msg.documentFileName.split(".")
            if (parts.size > 1) {
                ext = "." + parts[parts.size - 1]
            }
        }
        if (ext.size == 0) {
            if (msg.documentMimeType.contains("video")) { ext = ".mp4" }
            else if (msg.documentMimeType.contains("audio") || msg.documentMimeType.contains("ogg")) { ext = ".ogg" }
            else if (msg.documentMimeType.contains("pdf")) { ext = ".pdf" }
            else if (msg.documentMimeType.contains("gif")) { ext = ".gif" }
            else { ext = ".bin" }
        }
        
        let filePath = docDir + "/doc_${msg.documentId}${ext}"
        
        // 检查磁盘缓存：只有与 document.size 等长的文件才算已下载（iOS MediaBox 以 completeSize
        // 判定资源完整）；长度不符的旧文件删掉重下，不交给系统查看器。
        let fileExists = downloadedFileMatchesSize(filePath, msg.documentSize)
        if (!fileExists) {
            try { if (FileIo.access(filePath)) { FileIo.unlink(filePath) } } catch (_e: Exception) {}
        }
        if (fileExists) {
            let localUri = "file://" + filePath
            this.applyMediaPath(msg, msg.documentId, localUri, "doc", clearDownloading: true)
            // 前面已原地改过 Message 字段（内容/状态/下载路径，均不影响排序键）。
            // 原为「复制整表 + 整表回写」——回写才是竞态所在；现在只重发快照，不动权威容器。
            this.refreshMessageSnapshot()
            return
        }
        
        // 下载文件
        this._pollingPaused = true
        try {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Downloading document: id=${msg.documentId}, size=${msg.documentSize}")
            let downloadService = getFileDownloadService()
            let docBytes = downloadService.downloadDocument(
                msg.documentId,
                msg.documentAccessHash,
                msg.documentFileReference,
                msg.documentDcId,
                fileSize: msg.documentSize,
                priority: 90
            )
            
            // 先写临时文件、校验长度等于 document.size 后再改名为正式文件。
            if (docBytes.size > 0 &&
                writeDownloadedFileAtomically(filePath, docBytes, expectedSize: msg.documentSize)) {
                let localUri = "file://" + filePath
                
                this.applyMediaPath(msg, msg.documentId, localUri, "doc", clearDownloading: true)
                
                // 触发 UI 刷新
                // 前面已原地改过 Message 字段（内容/状态/下载路径，均不影响排序键）。
                // 原为「复制整表 + 整表回写」——回写才是竞态所在；现在只重发快照，不动权威容器。
                this.refreshMessageSnapshot()
                
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Document saved: ${localUri} (${docBytes.size} bytes)")
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Empty document data for id=${msg.documentId}")
                msg.isFileDownloading = false
                for (m in this.messageList) {
                    if (m.documentId == msg.documentId) { m.isFileDownloading = false }
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Document download failed: ${e}")
            msg.isFileDownloading = false
            for (m in this.messageList) {
                if (m.documentId == msg.documentId) { m.isFileDownloading = false }
            }
        }
        this._pollingPaused = false
    }
    
    /**
     * 下载语音文件 — 专用方法，不依赖 isFileDownloading 防重复
     * 下载完成后设置 msg.documentLocalPath，调用方可直接播放
     */
    public func downloadVoiceForMessage(msg: Message): Unit {
        if (msg.documentId == 0 || msg.documentLocalPath.size > 0) { return }
        
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) { return }
        
        let voiceDir = filesDir + "/voices"
        try { FileIo.mkdir(voiceDir) } catch (_e: Exception) {}
        
        var ext = ".wav"
        if (msg.documentFileName.size > 0) {
            let parts = msg.documentFileName.split(".")
            if (parts.size > 1) { ext = "." + parts[parts.size - 1] }
        }
        
        let filePath = voiceDir + "/voice_${msg.documentId}${ext}"
        
        var fileExists = false
        try { fileExists = FileIo.access(filePath) } catch (_e: Exception) {}
        if (fileExists) {
            this.applyMediaPath(msg, msg.documentId, filePath, "doc", clearDownloading: true)
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Voice cache hit: ${filePath}")
            return
        }
        
        msg.isFileDownloading = true
        this._pollingPaused = true
        try {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Downloading voice: id=${msg.documentId}, size=${msg.documentSize}")
            let downloadService = getFileDownloadService()
            let docBytes = downloadService.downloadDocument(
                msg.documentId,
                msg.documentAccessHash,
                msg.documentFileReference,
                msg.documentDcId,
                fileSize: msg.documentSize
            )
            
            if (docBytes.size > 0) {
                let file = FileIo.open(filePath, mode: 0o1101)
                FileIo.write(file.fd, docBytes)
                FileIo.close(file)
                
                this.applyMediaPath(msg, msg.documentId, filePath, "doc", clearDownloading: true)
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Voice saved: ${filePath} (${docBytes.size} bytes)")
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Empty voice data for id=${msg.documentId}")
                msg.isFileDownloading = false
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Voice download failed: ${e}")
            msg.isFileDownloading = false
        }
        this._pollingPaused = false
    }

    /**
     * 下载视频文件用于播放（暂停轮询，下载完整视频，返回本地 file:// 路径）
     * 
     * 与 downloadDocumentForMessage 不同的是：
     * 1. 保存到 /videos/ 目录（不是 /documents/）
     * 2. 返回文件路径（不更新 messageList）
     * 3. 始终使用 .mp4 扩展名
     * 
     * 注意：此方法应在 spawn 内调用
     */
    public func downloadVideoForPlayback(docId: Int64, accessHash: Int64, fileRef: Array<Byte>, dcId: Int32, fileSize: Int64): String {
        if (docId == 0) { return "" }
        
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) { return "" }
        
        let videoDir = filesDir + "/videos"
        try { FileIo.mkdir(videoDir) } catch (_e: Exception) {}
        let videoPath = videoDir + "/video_${docId}.mp4"
        
        // 检查缓存 + 验证文件大小（防止部分下载的损坏文件）
        var fileExists = false
        try { fileExists = FileIo.access(videoPath) } catch (_e: Exception) {}
        if (fileExists) {
            var cachedSize: Int64 = 0
            try { cachedSize = FileIo.stat(videoPath).size } catch (_e: Exception) {}
            if (fileSize > 0 && cachedSize < fileSize) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Video cache invalid: expected>=${fileSize}, actual=${cachedSize}, re-downloading")
                try { FileIo.unlink(videoPath) } catch (_e: Exception) {}
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Video cached: ${videoPath} (${cachedSize} bytes)")
                return "file://" + videoPath
            }
        }
        
        // 暂停轮询，下载视频
        this._pollingPaused = true
        var resultUri = ""
        try {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Downloading video: id=${docId}, size=${fileSize}")
            let downloadService = getFileDownloadService()
            let docBytes = downloadService.downloadDocument(
                docId,
                accessHash,
                fileRef,
                dcId,
                fileSize: fileSize
            )
            
            if (docBytes.size > 0 && (fileSize <= 0 || Int64(docBytes.size) >= fileSize)) {
                let file = FileIo.open(videoPath, mode: 0o1101)
                FileIo.write(file.fd, docBytes)
                FileIo.close(file)
                resultUri = "file://" + videoPath
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Video saved: ${resultUri} (${docBytes.size} bytes)")
            } else if (docBytes.size > 0) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Partial video data: got ${docBytes.size}/${fileSize} bytes, not caching")
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Empty video data for id=${docId}")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Video download failed: ${e}")
        }
        this._pollingPaused = false
        return resultUri
    }

    private func cacheVideoFromSend(videoData: Array<Byte>, messages: ArrayList<Message>, sentMsgId: Int64) {
        if (sentMsgId == 0 || videoData.size == 0) { return }
        for (m in messages) {
            if (m.id == sentMsgId && m.documentId != 0 && m.messageType == "video") {
                let cacheDir = getAppFilesDir() + "/videos"
                try { FileIo.mkdir(cacheDir) } catch (_e: Exception) {}
                let cachePath = cacheDir + "/video_${m.documentId}.mp4"
                var exists = false
                try { exists = FileIo.access(cachePath) } catch (_e: Exception) {}
                if (!exists) {
                    try {
                        let file = FileIo.open(cachePath, mode: 0o1101)
                        FileIo.write(file.fd, videoData)
                        FileIo.close(file)
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Cached sent video: video_${m.documentId}.mp4 (${videoData.size} bytes)")
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Failed to cache sent video: ${e}")
                    }
                }
                break
            }
        }
    }
    
    public func loadMockMessages() {
        this.isLoading = true
        // 原为 `this.messageList.add(mX)` —— 直接原地改列表，会绕过权威容器且不触发发布。
        // 改走 history 的有序插入算子（这也是全工程仅有的两处原地 add）。
        this.history.clear()
        let m1 = Message(); m1.id = 1; m1.content = "Hello!"; m1.time = "14:30"; m1.isSent = false; m1.status = "read"; m1.senderId = 2
        let _ = this.history.insert(m1)
        let m2 = Message(); m2.id = 2; m2.content = "Hi! How are you?"; m2.time = "14:31"; m2.isSent = true; m2.status = "read"; m2.senderId = 1
        let _ = this.history.insert(m2)
        this.isLoading = false
    }
    
    // ==================== 发送消息 ====================

    public func sendMessage(content: String, silent!: Bool = false, scheduleDate!: Int32 = 0,
        effectId!: Int64 = 0, onScheduled!: Option<(Bool) -> Unit> = None,
        formatEntities!: ArrayList<DraftFormatEntity> = ArrayList<DraftFormatEntity>()): Message {
        return this.sendMessageWithCustomEmojiEntities(
            content, ArrayList<CustomEmojiDraftEntity>(),
            silent: silent, scheduleDate: scheduleDate, effectId: effectId, onScheduled: onScheduled,
            formatEntities: formatEntities)
    }

    // ==================== S2-70: 定时消息（messages.getScheduledHistory / delete / sendNow） ====================

    /** 阻塞调用（在 spawn 中使用）：当前会话的定时消息，时间正序。 */
    public func loadScheduledMessages(): ArrayList<Message> {
        let response = getRealMessageService().getScheduledHistory(this.peerType, this.chatId)
        let messages = this.convertTLMessages(response)
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] scheduled messages loaded: ${messages.size}")
        return messages
    }

    public func deleteScheduledMessage(messageId: Int64): Bool {
        let ids = ArrayList<Int32>()
        ids.add(Int32(messageId))
        return getRealMessageService().deleteScheduledMessages(this.peerType, this.chatId, ids)
    }

    public func sendScheduledMessageNow(messageId: Int64): Bool {
        let ids = ArrayList<Int32>()
        ids.add(Int32(messageId))
        return getRealMessageService().sendScheduledMessagesNow(this.peerType, this.chatId, ids)
    }

    /**
     * 自定义 Emoji 与普通文本共享 messages.sendMessage；区别只是携带
     * messageEntityCustomEmoji，不能把 document 当作 Sticker 发送。
     */
    public func sendMessageWithCustomEmojiEntities(
        content: String, customEntities: ArrayList<CustomEmojiDraftEntity>,
        silent!: Bool = false, scheduleDate!: Int32 = 0, effectId!: Int64 = 0,
        onScheduled!: Option<(Bool) -> Unit> = None,
        formatEntities!: ArrayList<DraftFormatEntity> = ArrayList<DraftFormatEntity>()
    ): Message {
        this.messageIdCounter += 1
        // S2-70: a scheduled message never enters the live history (iOS keeps it in the
        // scheduledMessages namespace); only the request is sent and the caller opens
        // the Scheduled Messages screen on success.
        let isScheduled = scheduleDate > 0

        // Typed-markdown → entity 转换：在发送/存储/渲染前解析用户输入的 markdown 标记。
        // parseMarkdown 返回 (纯文本, 实体列表)；实体 offset/length 按纯文本码点口径，
        // 与 server 实体 (parseTextEntities) 及 MessageBubble.buildTextSegments 消费的口径一致。
        // 无 markdown 标记时 cleanText == content、parsedEntities 为空，行为与原来一致（无回归）。
        var cleanText = content
        var parsedEntities = Array<TextEntityData>(0, repeat: TextEntityData())
        if (customEntities.isEmpty() && formatEntities.isEmpty()) {
            let (parsedText, parsed) = parseMarkdown(content)
            cleanText = parsedText
            parsedEntities = parsed
        }
        // WP-D: formatting applied through the composer's Format menu (S2-18/19/24). The text is
        // already plain (no markdown markers); rune offsets go to the local bubble below, UTF-16
        // offsets go to the TL entities (iOS/TDLib MessageEntity semantics).
        if (!formatEntities.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendMessage formatEntities=${formatEntities.size}")
        }
        // Custom Emoji 坐标属于当前输入串；有 document span 时先保留原文，避免
        // markdown 去标记后让 entity 偏移。统一 attributed editor 阶段再合并变换。

        let newMessage = Message()
        newMessage.id = this.messageIdCounter
        newMessage.content = cleanText
        this.stampLocalMessage(newMessage)
        newMessage.isSent = true
        newMessage.status = "sending"
        newMessage.senderId = this.currentUserId
        // 挂载 typed-markdown 解析出的实体（与 server-entity 路径挂 textEntityList 口径一致）
        for (e in parsedEntities) {
            newMessage.textEntityList.add(e)
        }
        for (f in formatEntities) {
            let entity = TextEntityData()
            entity.entityType = f.entityType
            entity.offset = f.runeOffset
            entity.length = f.runeLength
            entity.url = f.url
            newMessage.textEntityList.add(entity)
        }
        for (custom in customEntities) {
            let entity = TextEntityData()
            entity.entityType = "customEmoji"
            entity.offset = custom.runeOffset
            entity.length = custom.runeLength
            entity.customEmojiDocumentId = custom.documentId
            newMessage.textEntityList.add(entity)
        }
        
        // 如果是回复消息，设置回复信息
        if (this.replyToMsgId > 0) {
            newMessage.replyToMsgId = this.replyToMsgId
            newMessage.replyToText = this.replyToText
            newMessage.replyToSenderName = this.replyToSenderName
        }
        
        // 添加到列表
        // 原为「复制整表 + 追加一条 + 整表回写」——两条并发路径会互相覆盖（丢消息）。
        // 改为增量插入：不读旧快照，只提交这一条，天然免疫丢更新。
        // 对齐 iOS .InsertMessage 操作（MessageHistoryView.swift:593）。
        if (!isScheduled) { let _ = this.history.insert(newMessage) }
        this.inputText = ""

        // 清除回复状态（先保存，再清零）
        let replyId = Int32(this.replyToMsgId)
        // P2-115: capture quote fields before clearing
        let quoteCopy = this.replyQuoteText
        let quoteOffsetCopy = this.replyQuoteOffset
        this.cancelReply()
        // P2-117: 发送成功后清除草稿（本地 + 服务端）
        this.clearDraftAfterSend()

        // 通过 MTProto 发送
        // 注意：发送完成后不调用 this.loadMessages()，避免与 polling 线程并发访问 MTProto
        // polling 会在 3 秒内自动刷新消息列表
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        // 发给 server 的也用 cleanText（纯文本，不含 markdown 标记），
        // 与正常文本消息一致；本地 textEntityList 已在 newMessage 上完成即时渲染。
        let contentCopy = cleanText
        // P2-120: 将 parseMarkdown 产出的 TextEntityData 转换为 TL 序列化实体对象，
        // 用于通过 sendMessageWithEntities 传给服务端，使接收方可见内联格式。
        let tlEntities = ArrayList<TLObject>()
        for (e in parsedEntities) {
            match (e.entityType) {
                case "bold"    => tlEntities.add(TLMessageEntityBold(e.offset, e.length))
                case "italic"  => tlEntities.add(TLMessageEntityItalic(e.offset, e.length))
                case "strike"  => tlEntities.add(TLMessageEntityStrike(e.offset, e.length))
                case "code"    => tlEntities.add(TLMessageEntityCode(e.offset, e.length))
                case "pre"     => tlEntities.add(TLMessageEntityPre(e.offset, e.length, ""))
                case "spoiler" => tlEntities.add(TLMessageEntitySpoiler(e.offset, e.length))
                case "textUrl" => tlEntities.add(TLMessageEntityTextUrl(e.offset, e.length, e.url))
                case _         => ()
            }
        }
        for (f in formatEntities) {
            match (f.entityType) {
                case "bold"       => tlEntities.add(TLMessageEntityBold(f.utf16Offset, f.utf16Length))
                case "italic"     => tlEntities.add(TLMessageEntityItalic(f.utf16Offset, f.utf16Length))
                case "underline"  => tlEntities.add(TLMessageEntityUnderline(f.utf16Offset, f.utf16Length))
                case "strike"     => tlEntities.add(TLMessageEntityStrike(f.utf16Offset, f.utf16Length))
                case "code"       => tlEntities.add(TLMessageEntityCode(f.utf16Offset, f.utf16Length))
                case "pre"        => tlEntities.add(TLMessageEntityPre(f.utf16Offset, f.utf16Length, ""))
                case "spoiler"    => tlEntities.add(TLMessageEntitySpoiler(f.utf16Offset, f.utf16Length))
                case "blockquote" => tlEntities.add(TLMessageEntityBlockquote(f.utf16Offset, f.utf16Length))
                case "textUrl"    => tlEntities.add(TLMessageEntityTextUrl(f.utf16Offset, f.utf16Length, f.url))
                case _            => ()
            }
        }
        for (custom in customEntities) {
            tlEntities.add(TLMessageEntityCustomEmoji(
                custom.utf16Offset, custom.utf16Length, custom.documentId))
        }
        let silentCopy = silent
        let scheduleCopy = scheduleDate
        let effectCopy = effectId
        spawn {
            // 暂停 polling，等待发送完成（避免并发 MTProto 访问）
            this._pollingPaused = true
            try {
                let messageService = getRealMessageService()
                var result = SendMessageResult()
                if (replyId > 0) {
                    // P2-115: pass quote fields (quoteText="" means no quote, ordinary reply)
                    result = messageService.sendMessageWithReply(peerTypeCopy, chatIdCopy, contentCopy, replyId, quoteText: quoteCopy, quoteOffset: quoteOffsetCopy,
                        silent: silentCopy, scheduleDate: scheduleCopy, effectId: effectCopy, entities: tlEntities)
                } else {
                    // P2-120: 有格式实体时走 sendMessageWithEntities，保证格式传达服务端
                    if (tlEntities.size > 0) {
                        result = messageService.sendMessageWithEntities(peerTypeCopy, chatIdCopy, contentCopy, tlEntities,
                            silent: silentCopy, scheduleDate: scheduleCopy, effectId: effectCopy)
                    } else {
                        result = messageService.sendMessage(peerTypeCopy, chatIdCopy, contentCopy,
                            silent: silentCopy, scheduleDate: scheduleCopy, effectId: effectCopy)
                    }
                }
                if (isScheduled) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Scheduled send result success=${result.success} err=${result.errorMessage}")
                    match (onScheduled) { case Some(cb) => cb(result.success); case None => () }
                    if (!result.success) {
                        let alertText = sendFailureAlertText(result.errorMessage)
                        launch { showAlert(title: "", message: alertText, confirmText: "OK", cancelText: "") }
                    }
                } else if (result.success) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Message sent successfully silent=${silentCopy}")

                    let isAnimatedEmojiSend = tlEntities.size == 0 && isSingleEmoji(contentCopy)

                    // 换号要**排在表情预热之前**：预热会下载并解析 TGS，可能耗时数百毫秒，
                    // 这期间本地条目还挂着计数器 id，推送/轮询带回的服务端条目比不上号、
                    // 被当成新消息插进来，等换号时就变成同一条消息两份
                    // （真机：发一个表情连着出现两个一模一样的气泡，服务端只有一条）。
                    // 状态仍留在 "sending"，气泡继续走占位分支，动画节点依旧等预热完再挂载。
                    
                    // Phase Q6: 立即用服务端返回的 ID/时间 更新本地消息
                    if (result.messageId != 0) {
                        // 这里改的 id / rawTimestamp / namespace **全是排序键组成部分**，
                        // 必须经 history.update 走「按旧键摘出 → 按新键插回 + 同步 byId」，
                        // 不能原地改完只重发快照 —— 那样数组顺序不再匹配键、byId 索引脱节，
                        // 实测表现为发送后消息闪一下（批 2 此处误判为「不影响排序键」）。
                        //
                        // namespace 由 Local 改回 Cloud：消息已被服务端确认，不再是待发状态。
                        // 对齐 iOS：本地消息发出后从 Namespaces.Message.Local 迁移到 .Cloud
                        // （SyncCore_Namespaces.swift:6-7），这决定它在同秒消息中的先后。
                        let localId = newMessage.id
                        let serverId = Int64(result.messageId)
                        let serverDate = Int64(result.date)
                        let _ = this.history.update(localId, { m: Message =>
                            m.id = serverId
                            // 媒体发送走 Updates 响应，其中只有 updateMessageID(id, random_id)、**没有 date**。
                            // 0 不能写进排序键（全序键 timestamp → namespace → id），
                            // 服务端时间由随后的 getHistory 增量合并时带回并原地修正。
                            if (serverDate > 0) {
                                m.rawTimestamp = serverDate
                                m.time = formatMessageTime(serverDate)
                            }
                            m.namespace = MessageHistoryView.NS_CLOUD
                        })
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Updated local msg: id=${result.messageId}, date=${result.date}")
                    } else {
                        // 兜底：服务端 id 取不到就无法换号，本地待发条目会与随后 push /
                        // getHistory 带回的服务端消息并存 = 同一条消息两份。
                        // 与媒体发送路径同一处理：移除本地条目，由服务端那条接管。
                        let _ = this.history.remove(newMessage.id)
                    }

                    // The animated-emoji metadata request uses the same MTProto
                    // client as sendMessage. Preload it only after send has been
                    // acknowledged, and before publishing the sent-state bubble,
                    // so the first mounted animation reads ready frames instead
                    // of requiring a chat reopen.
                    if (isAnimatedEmojiSend) {
                        let animationReady = preloadAnimatedEmojiStream(contentCopy)
                        Hilog.info(0, "CjTelegram",
                            "[ChatRoomVM] outgoing emoji animation ready=${animationReady}")
                    }

                    // 预热完成后再发布 sent 态气泡（此时动画节点才挂载，读到的是就绪帧）。
                    // 这里只置 "sent"；若对方的已读回执在本条还处于 sending 时就到了，
                    // 由 publishSnapshot 的推导在本次 update 触发的发布里补成 "read"。
                    if (result.messageId != 0) {
                        let _ = this.history.update(Int64(result.messageId), { m: Message =>
                            m.status = "sent"
                        })
                    }
                    
                    // 仍然拉取完整消息列表（后台刷新，确保一致性）
                    try {
                        let historyResponse = messageService.getHistory(
                            peerTypeCopy,
                            chatIdCopy,
                            limit: 30
                        )
                        let messages = this.convertTLMessages(historyResponse)
                        // 原为 setMessageList(...) → replaceAll：用服务端最新 30 条**整表替换**。
                        // 实测（RENDER-DBG）它是发送路径上唯一改变列表长度的一次推送 —— count 31→30，
                        // 把本地已有的第 31 条（最老一条）挤出视图，并触发一次结构性重排。
                        //
                        // 不能直接删除这次刷新：parseSendMessageResponse（RealMessageService.cj:2186-2195）
                        // 只解析了 flags/msgId/pts/ptsCount/date，**不解析 media 与 entities**；
                        // 而链接预览（webpage）和服务端自动识别的实体只能由这次 getHistory 带回来。
                        // 删掉会让发链接后预览延迟到下一次 10s 轮询。
                        //
                        // 故改为增量并入：服务端修正照常到达，但不截断、不改变列表长度。
                        // 同 id 同键的条目会命中 insertLocked 的「原地写」路径（MessageHistoryView.cj:408-418），
                        // 只换承载对象、位置不动。与批 2 本地缓存秒开那处改用 insertMany 的理由一致。
                        //
                        // 已知取舍：insertMany 不会移除服务端已删除的消息 —— 那条由
                        // updateDeleteMessages 推送专门处理（UpdatesManager.cj:1123 → onDeleteMessagesPush）。
                        let _ = this.history.insertMany(messages)
                        this.downloadPhotosForMessages(messages)
                    } catch (e2: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Post-send refresh failed: ${e2}")
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Send failed: ${result.errorCode} - ${result.errorMessage}")
                    this.markMessageFailed(newMessage)
                    // 对齐 iOS：发送失败必须告知用户原因（ChatControllerLoadDisplayNode.swift:5244-5285
                    // sendMessageReasonForError → 弹 Alert）。此前仅打日志、消息静默消失，
                    // 用户完全不知发生了什么（实测 PEER_FLOOD 被静默吞掉）。
                    let alertText = sendFailureAlertText(result.errorMessage)
                    launch { showAlert(title: "", message: alertText, confirmText: "OK", cancelText: "") }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Send exception: ${e}")
                this.markMessageFailed(newMessage)
            }
            this._pollingPaused = false
        }
        
        return newMessage
    }
    
    // ==================== Phase H1: 发送照片 ====================
    
    /**
     * 发送照片消息
     * 
     * 流程：创建本地占位消息 → 暂停 polling → 上传+发送 → 刷新消息列表
     * 
     * @param photoData 照片二进制数据
     * @param fileName 文件名
     * @param caption 照片说明文字
     */
    public func sendPhoto(photoData: Array<Byte>, fileName: String, caption: String): Unit {
        // 创建本地占位消息
        this.messageIdCounter += 1
        let newMessage = Message()
        newMessage.id = this.messageIdCounter
        newMessage.content = if (caption.size > 0) { caption } else { "[Photo]" }
        this.stampLocalMessage(newMessage)
        newMessage.isSent = true
        newMessage.status = "sending"
        newMessage.senderId = this.currentUserId
        newMessage.messageType = "photo"
        newMessage.mediaDescription = "[Photo]"
        
        // 添加到列表（可能从后台线程调用，需用 launch 更新 @Publish）
        // 原为「复制整表 + 追加一条 + 整表回写」——两条并发路径会互相覆盖（丢消息）。
        // 改为增量插入：不读旧快照，只提交这一条，天然免疫丢更新。
        // 对齐 iOS .InsertMessage 操作（MessageHistoryView.swift:593）。
        let _ = this.history.insert(newMessage)
        
        // 异步上传+发送
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let replyId = Int32(this.replyToMsgId)
        launch { this.cancelReply() }
        
        this._pollingPaused = true
        try {
            let messageService = getRealMessageService()
            let result = messageService.sendPhoto(
                peerTypeCopy,
                chatIdCopy,
                photoData,
                fileName,
                caption: caption,
                replyToMsgId: replyId
            )
            if (result.success) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Photo sent successfully")
                if (result.messageId != 0) {
                    // 本地 id → 服务端 id 必须走容器算子。直接改 newMessage.id 只动对象字段，
                    // 容器的 byId 索引会停在旧的本地 id、排序位置也不重算（MessageHistoryView.update
                    // 会同步索引并按新键重定位）。此前这个不一致被随后的 replaceAll 整表替换掩盖；
                    // 历史刷新改为增量合并后就会暴露成**同一条消息出现两份**。与文字路径 sendMessage 对齐。
                    let localId = newMessage.id
                    let serverId = Int64(result.messageId)
                    let serverDate = Int64(result.date)
                    let _ = this.history.update(localId, { m: Message =>
                        m.id = serverId
                        // 媒体发送走 Updates 响应，其中只有 updateMessageID(id, random_id)、**没有 date**。
                        // 0 不能写进排序键（全序键 timestamp → namespace → id），
                        // 服务端时间由随后的 getHistory 增量合并时带回并原地修正。
                        if (serverDate > 0) {
                            m.rawTimestamp = serverDate
                            m.time = formatMessageTime(serverDate)
                        }
                        m.status = "sent"
                        // 媒体路径此前漏了这行：namespace 停在 NS_LOCAL，已被服务端确认的消息
                        // 仍按「待发」参与全序排序（键序 timestamp → namespace → id），
                        // 同秒内会排到已收消息之后。文字路径一直有，媒体路径补齐。
                        m.namespace = MessageHistoryView.NS_CLOUD
                    })
                } else {
                    // 兜底：服务端 id 取不到就无法换号，本地待发条目会与随后 getHistory
                    // 带回的服务端消息**并存 = 同一条消息两份**（历史刷新改增量合并后暴露）。
                    // 移除本地条目，由服务端那条接管。旧代码是靠 replaceAll 整表替换
                    // 顺带清掉它的 —— 那个副作用现在没有了，必须显式处理。
                    let _ = this.history.remove(newMessage.id)
                }
                try {
                    let historyResponse = messageService.getHistory(
                        peerTypeCopy,
                        chatIdCopy,
                        limit: 30
                    )
                    let messages = this.convertTLMessages(historyResponse)
                    launch { this.mergeMessageList(this.mergeFailedLocals(messages)) }
                    this.downloadPhotosForMessages(messages)
                } catch (e2: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Post-photo refresh failed: ${e2}")
                }
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Photo send failed: ${result.errorMessage}")
                this.markMessageFailed(newMessage)
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendPhoto exception: ${e}")
            this.markMessageFailed(newMessage)
        }
        this._pollingPaused = false
    }

    /**
     * 发送文档/文件消息
     */
    // ==================== S3-25: Cancel Sending ====================

    private var _cancelledSendTags: ArrayList<Int64> = ArrayList<Int64>()
    private let _cancelledSendMutex = ReentrantMutex()

    private func isSendCancelled(tag: Int64): Bool {
        synchronized (this._cancelledSendMutex) {
            var i: Int64 = 0
            while (i < this._cancelledSendTags.size) {
                if (this._cancelledSendTags[i] == tag) {
                    this._cancelledSendTags.remove(at: i)
                    return true
                }
                i += 1
            }
        }
        return false
    }

    /**
     * iOS Conversation.ContextMenuCancelSending: abort the pending upload of a local
     * message (FileUploadService.cancelUploadByTag) and drop the local entry.
     * Returns false when the message is not a pending local send.
     */
    public func cancelSendingMessage(messageId: Int64): Bool {
        var pending = false
        for (m in this.messageList) {
            if (m.id == messageId) {
                pending = m.status == "sending" && m.namespace == MessageHistoryView.NS_LOCAL
                break
            }
        }
        if (!pending) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] cancelSendingMessage: ${messageId} is not a pending local message")
            return false
        }
        synchronized (this._cancelledSendMutex) { this._cancelledSendTags.add(messageId) }
        let found = getFileUploadService().cancelUploadByTag(messageId)
        let _ = this.history.remove(messageId)
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] cancelSendingMessage: ${messageId} upload=${found} removed")
        return true
    }

    public func sendDocument(fileData: Array<Byte>, fileName: String, mimeType: String, caption: String): Unit {
        this.messageIdCounter += 1
        let newMessage = Message()
        newMessage.id = this.messageIdCounter
        newMessage.content = if (caption.size > 0) { caption } else { "[File: ${fileName}]" }
        this.stampLocalMessage(newMessage)
        newMessage.isSent = true
        newMessage.status = "sending"
        newMessage.senderId = this.currentUserId
        newMessage.messageType = "document"
        newMessage.mediaDescription = "[File: ${fileName}]"
        newMessage.documentFileName = fileName
        newMessage.documentSize = Int64(fileData.size)
        newMessage.documentMimeType = mimeType
        if (mimeType.startsWith("audio/")) {
            newMessage.messageType = "audio"
            newMessage.mediaDescription = "[Audio]"
        }
        
        // 原为「复制整表 + 追加一条 + 整表回写」——两条并发路径会互相覆盖（丢消息）。
        // 改为增量插入：不读旧快照，只提交这一条，天然免疫丢更新。
        // 对齐 iOS .InsertMessage 操作（MessageHistoryView.swift:593）。
        let _ = this.history.insert(newMessage)
        
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        
        this._pollingPaused = true
        let uploadTag = newMessage.id
        try {
            let messageService = getRealMessageService()
            let result = messageService.sendDocument(
                peerTypeCopy,
                chatIdCopy,
                fileData,
                fileName,
                mimeType: mimeType,
                caption: caption,
                uploadTag: uploadTag
            )
            if (this.isSendCancelled(uploadTag)) {
                // S3-25: "Cancel Sending" removed the local message already; nothing to update.
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Document send cancelled by user tag=${uploadTag}")
            } else if (result.success) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Document sent successfully")
                if (result.messageId != 0) {
                    // 本地 id → 服务端 id 必须走容器算子。直接改 newMessage.id 只动对象字段，
                    // 容器的 byId 索引会停在旧的本地 id、排序位置也不重算（MessageHistoryView.update
                    // 会同步索引并按新键重定位）。此前这个不一致被随后的 replaceAll 整表替换掩盖；
                    // 历史刷新改为增量合并后就会暴露成**同一条消息出现两份**。与文字路径 sendMessage 对齐。
                    let localId = newMessage.id
                    let serverId = Int64(result.messageId)
                    let serverDate = Int64(result.date)
                    let _ = this.history.update(localId, { m: Message =>
                        m.id = serverId
                        // 媒体发送走 Updates 响应，其中只有 updateMessageID(id, random_id)、**没有 date**。
                        // 0 不能写进排序键（全序键 timestamp → namespace → id），
                        // 服务端时间由随后的 getHistory 增量合并时带回并原地修正。
                        if (serverDate > 0) {
                            m.rawTimestamp = serverDate
                            m.time = formatMessageTime(serverDate)
                        }
                        m.status = "sent"
                        // 媒体路径此前漏了这行：namespace 停在 NS_LOCAL，已被服务端确认的消息
                        // 仍按「待发」参与全序排序（键序 timestamp → namespace → id），
                        // 同秒内会排到已收消息之后。文字路径一直有，媒体路径补齐。
                        m.namespace = MessageHistoryView.NS_CLOUD
                    })
                } else {
                    // 兜底：服务端 id 取不到就无法换号，本地待发条目会与随后 getHistory
                    // 带回的服务端消息**并存 = 同一条消息两份**（历史刷新改增量合并后暴露）。
                    // 移除本地条目，由服务端那条接管。旧代码是靠 replaceAll 整表替换
                    // 顺带清掉它的 —— 那个副作用现在没有了，必须显式处理。
                    let _ = this.history.remove(newMessage.id)
                }
                try {
                    let historyResponse = messageService.getHistory(
                        peerTypeCopy,
                        chatIdCopy,
                        limit: 30
                    )
                    let messages = this.convertTLMessages(historyResponse)
                    launch { this.mergeMessageList(this.mergeFailedLocals(messages)) }
                    this.downloadPhotosForMessages(messages)
                } catch (e2: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Post-doc refresh failed: ${e2}")
                }
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Document send failed: ${result.errorMessage}")
                this.markMessageFailed(newMessage)
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendDocument exception: ${e}")
            this.markMessageFailed(newMessage)
        }
        this._pollingPaused = false
    }

    /**
     * P2-356: 粘贴板媒体发送 — MediaPasteboardUIComponent.onConfirm 真接调用方
     *
     * 调用链（完整）：
     *   MediaPasteboardUIComponent.buildBottomBar.sendButton.onClick()
     *     → collectSelected() → onConfirm(selected)
     *       → ChatRoomPage(onConfirm) → viewModel.sendPasteboardMediaItems(items)
     *         → 逐项 readPasteboardItemBytes(item.uri) → sendPhoto / sendDocument
     *           → RealMessageService.sendPhoto / sendDocument
     *             → FileUploadService.uploadFile → messages.sendMedia → server
     *
     * iOS 对应：MediaPasteboardScreen.swift → AttachmentController → mediaPasteboardScreen()
     *   confirmAction → 调用 inputPanelSendAction → sendMediaItems → sendMediaWithFileInfos
     *
     * 复用 PasteboardUtils C FFI（MediaPasteboardService/PasteboardBridge 已通过 dlopen
     * libpasteboard.so + libudmf.so 读取媒体 URI；本方法读取已有 URI 文件字节并 enqueue）
     */
    public func sendPasteboardMediaItems(items: ArrayList<PasteboardItem>): Unit {
        if (items.isEmpty()) {
            return
        }
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendPasteboardMediaItems: ${items.size} items")
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let _ = spawn {
            for (item in items) {
                if (item.uri.size == 0) {
                    continue
                }
                // 从 URI 路径读取字节（file:// 开头则去掉前缀）
                let filePath = if (item.uri.contains("file://")) {
                    item.uri.split("file://")[1]
                } else {
                    item.uri
                }
                try {
                    let fileData = readPasteboardFileBytes(filePath)
                    if (fileData.size == 0) {
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendPasteboardMediaItems: empty data for ${filePath}")
                        continue
                    }
                    if (item.mediaKind == "image") {
                        let fn = if (item.displayName.size > 0) { item.displayName } else { "paste_image.jpg" }
                        // 复用统一发送路径，确保失败占位、持久化和 UI 状态一致。
                        this.sendPhoto(fileData, fn, "")
                    } else {
                        let fn = if (item.displayName.size > 0) { item.displayName } else { "paste_file" }
                        let mime = if (item.mimeType.size > 0) { item.mimeType } else { "application/octet-stream" }
                        this.sendDocument(fileData, fn, mime, "")
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendPasteboardMediaItems: error for ${item.uri}: ${e}")
                }
            }
            // 发完刷新历史
            try {
                let msgSvc = getRealMessageService()
                let historyResponse = msgSvc.getHistory(peerTypeCopy, chatIdCopy, limit: 30)
                let messages = this.convertTLMessages(historyResponse)
                launch { this.mergeMessageList(this.mergeFailedLocals(messages)) }
                this.downloadPhotosForMessages(messages)
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendPasteboardMediaItems: refresh failed")
            }
        }
    }

    /**
     * 发送语音消息 — 带 documentAttributeAudio(voice=true) 使服务器正确标记为语音
     */
    public func sendVoice(fileData: Array<Byte>, fileName: String, duration: Int32, waveform: Array<Byte>,
                          mimeType!: String = "audio/wav"): Unit {
        this.messageIdCounter += 1
        let newMessage = Message()
        newMessage.id = this.messageIdCounter
        newMessage.content = "[Voice Message]"
        this.stampLocalMessage(newMessage)
        newMessage.isSent = true
        newMessage.status = "sending"
        newMessage.senderId = this.currentUserId
        newMessage.messageType = "voice"
        newMessage.mediaDescription = "[Voice Message]"
        newMessage.audioDuration = duration
        
        // 原为「复制整表 + 追加一条 + 整表回写」——两条并发路径会互相覆盖（丢消息）。
        // 改为增量插入：不读旧快照，只提交这一条，天然免疫丢更新。
        // 对齐 iOS .InsertMessage 操作（MessageHistoryView.swift:593）。
        let _ = this.history.insert(newMessage)
        
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        
        this._pollingPaused = true
        try {
            let messageService = getRealMessageService()
            let result = messageService.sendVoice(
                peerTypeCopy,
                chatIdCopy,
                fileData,
                fileName,
                mimeType: mimeType,
                duration: duration,
                waveform: waveform
            )
            if (result.success) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Voice sent successfully")
                if (result.messageId != 0) {
                    // 本地 id → 服务端 id 必须走容器算子。直接改 newMessage.id 只动对象字段，
                    // 容器的 byId 索引会停在旧的本地 id、排序位置也不重算（MessageHistoryView.update
                    // 会同步索引并按新键重定位）。此前这个不一致被随后的 replaceAll 整表替换掩盖；
                    // 历史刷新改为增量合并后就会暴露成**同一条消息出现两份**。与文字路径 sendMessage 对齐。
                    let localId = newMessage.id
                    let serverId = Int64(result.messageId)
                    let serverDate = Int64(result.date)
                    let _ = this.history.update(localId, { m: Message =>
                        m.id = serverId
                        // 媒体发送走 Updates 响应，其中只有 updateMessageID(id, random_id)、**没有 date**。
                        // 0 不能写进排序键（全序键 timestamp → namespace → id），
                        // 服务端时间由随后的 getHistory 增量合并时带回并原地修正。
                        if (serverDate > 0) {
                            m.rawTimestamp = serverDate
                            m.time = formatMessageTime(serverDate)
                        }
                        m.status = "sent"
                        // 媒体路径此前漏了这行：namespace 停在 NS_LOCAL，已被服务端确认的消息
                        // 仍按「待发」参与全序排序（键序 timestamp → namespace → id），
                        // 同秒内会排到已收消息之后。文字路径一直有，媒体路径补齐。
                        m.namespace = MessageHistoryView.NS_CLOUD
                    })
                } else {
                    // 兜底：服务端 id 取不到就无法换号，本地待发条目会与随后 getHistory
                    // 带回的服务端消息**并存 = 同一条消息两份**（历史刷新改增量合并后暴露）。
                    // 移除本地条目，由服务端那条接管。旧代码是靠 replaceAll 整表替换
                    // 顺带清掉它的 —— 那个副作用现在没有了，必须显式处理。
                    let _ = this.history.remove(newMessage.id)
                }
                try {
                    let historyResponse = messageService.getHistory(
                        peerTypeCopy,
                        chatIdCopy,
                        limit: 30
                    )
                    let messages = this.convertTLMessages(historyResponse)
                    launch { this.mergeMessageList(this.mergeFailedLocals(messages)) }
                    this.downloadPhotosForMessages(messages)
                } catch (e2: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Post-voice refresh failed: ${e2}")
                }
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Voice send failed: ${result.errorMessage}")
                this.markMessageFailed(newMessage)
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendVoice exception: ${e}")
            this.markMessageFailed(newMessage)
        }
        this._pollingPaused = false
    }

    /**
     * Phase P6-1: 发送视频消息
     * 
     * 创建本地占位消息 → 上传视频 → messages.sendMedia → 刷新列表
     */
    public func sendVideo(videoData: Array<Byte>, fileName: String, mimeType: String,
                          duration: Float64, width: Int32, height: Int32, caption: String,
                          thumbData!: Array<Byte> = Array<Byte>(0, repeat: 0)): Unit {
        this.messageIdCounter += 1
        let newMessage = Message()
        newMessage.id = this.messageIdCounter
        newMessage.content = if (caption.size > 0) { caption } else { "[Video]" }
        this.stampLocalMessage(newMessage)
        newMessage.isSent = true
        newMessage.status = "sending"
        newMessage.senderId = this.currentUserId
        newMessage.messageType = "video"
        newMessage.mediaDescription = "[Video]"
        newMessage.documentFileName = fileName
        
        // 原为「复制整表 + 追加一条 + 整表回写」——两条并发路径会互相覆盖（丢消息）。
        // 改为增量插入：不读旧快照，只提交这一条，天然免疫丢更新。
        // 对齐 iOS .InsertMessage 操作（MessageHistoryView.swift:593）。
        let _ = this.history.insert(newMessage)
        
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        
        this._pollingPaused = true
        try {
            let messageService = getRealMessageService()
            let result = messageService.sendVideo(
                peerTypeCopy,
                chatIdCopy,
                videoData,
                fileName,
                mimeType: mimeType,
                duration: duration,
                width: width,
                height: height,
                thumbData: thumbData,
                caption: caption
            )
            if (result.success) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Video sent successfully")
                if (result.messageId != 0) {
                    // 本地 id → 服务端 id 必须走容器算子。直接改 newMessage.id 只动对象字段，
                    // 容器的 byId 索引会停在旧的本地 id、排序位置也不重算（MessageHistoryView.update
                    // 会同步索引并按新键重定位）。此前这个不一致被随后的 replaceAll 整表替换掩盖；
                    // 历史刷新改为增量合并后就会暴露成**同一条消息出现两份**。与文字路径 sendMessage 对齐。
                    let localId = newMessage.id
                    let serverId = Int64(result.messageId)
                    let serverDate = Int64(result.date)
                    let _ = this.history.update(localId, { m: Message =>
                        m.id = serverId
                        // 媒体发送走 Updates 响应，其中只有 updateMessageID(id, random_id)、**没有 date**。
                        // 0 不能写进排序键（全序键 timestamp → namespace → id），
                        // 服务端时间由随后的 getHistory 增量合并时带回并原地修正。
                        if (serverDate > 0) {
                            m.rawTimestamp = serverDate
                            m.time = formatMessageTime(serverDate)
                        }
                        m.status = "sent"
                        // 媒体路径此前漏了这行：namespace 停在 NS_LOCAL，已被服务端确认的消息
                        // 仍按「待发」参与全序排序（键序 timestamp → namespace → id），
                        // 同秒内会排到已收消息之后。文字路径一直有，媒体路径补齐。
                        m.namespace = MessageHistoryView.NS_CLOUD
                    })
                } else {
                    // 兜底：服务端 id 取不到就无法换号，本地待发条目会与随后 getHistory
                    // 带回的服务端消息**并存 = 同一条消息两份**（历史刷新改增量合并后暴露）。
                    // 移除本地条目，由服务端那条接管。旧代码是靠 replaceAll 整表替换
                    // 顺带清掉它的 —— 那个副作用现在没有了，必须显式处理。
                    let _ = this.history.remove(newMessage.id)
                }
                try {
                    let historyResponse = messageService.getHistory(
                        peerTypeCopy,
                        chatIdCopy,
                        limit: 30
                    )
                    let messages = this.convertTLMessages(historyResponse)
                    launch { this.mergeMessageList(this.mergeFailedLocals(messages)) }
                    this.downloadPhotosForMessages(messages)
                    this.cacheVideoFromSend(videoData, messages, Int64(result.messageId))
                } catch (e2: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Post-video refresh failed: ${e2}")
                }
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Video send failed: ${result.errorMessage}")
                this.markMessageFailed(newMessage)
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendVideo exception: ${e}")
            this.markMessageFailed(newMessage)
        }
        this._pollingPaused = false
    }

    /**
     * Phase P6-11: 发送视频消息（圆形 Video Note）
     * 
     * 创建本地占位消息 → 上传视频 → messages.sendMedia(roundMessage) → 刷新列表
     */
    public func sendVideoNote(videoData: Array<Byte>, fileName: String, duration: Float64,
                              width!: Int32 = 400, height!: Int32 = 400,
                              thumbData!: Array<Byte> = Array<Byte>(0, repeat: 0),
                              thumbPath!: String = ""): Unit {
        this.messageIdCounter += 1
        let newMessage = Message()
        newMessage.id = this.messageIdCounter
        newMessage.content = "[Video Note]"
        this.stampLocalMessage(newMessage)
        newMessage.isSent = true
        newMessage.status = "sending"
        newMessage.senderId = this.currentUserId
        newMessage.messageType = "video_note"
        newMessage.mediaDescription = "[Video Note]"
        newMessage.documentFileName = fileName
        // 本地首帧缩略图：发送中就显示圆形画面（iOS 发送时气泡即时用本地预览）
        newMessage.documentLocalPath = thumbPath
        newMessage.videoDuration = Int32(duration)
        
        // 原为「复制整表 + 追加一条 + 整表回写」——两条并发路径会互相覆盖（丢消息）。
        // 改为增量插入：不读旧快照，只提交这一条，天然免疫丢更新。
        // 对齐 iOS .InsertMessage 操作（MessageHistoryView.swift:593）。
        let _ = this.history.insert(newMessage)
        
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        
        this._pollingPaused = true
        try {
            let messageService = getRealMessageService()
            let result = messageService.sendVideoNote(
                peerTypeCopy,
                chatIdCopy,
                videoData,
                fileName,
                duration: duration,
                width: width,
                height: height,
                thumbData: thumbData
            )
            if (result.success) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Video note sent successfully")
                if (result.messageId != 0) {
                    // 本地 id → 服务端 id 必须走容器算子。直接改 newMessage.id 只动对象字段，
                    // 容器的 byId 索引会停在旧的本地 id、排序位置也不重算（MessageHistoryView.update
                    // 会同步索引并按新键重定位）。此前这个不一致被随后的 replaceAll 整表替换掩盖；
                    // 历史刷新改为增量合并后就会暴露成**同一条消息出现两份**。与文字路径 sendMessage 对齐。
                    let localId = newMessage.id
                    let serverId = Int64(result.messageId)
                    let serverDate = Int64(result.date)
                    let _ = this.history.update(localId, { m: Message =>
                        m.id = serverId
                        // 媒体发送走 Updates 响应，其中只有 updateMessageID(id, random_id)、**没有 date**。
                        // 0 不能写进排序键（全序键 timestamp → namespace → id），
                        // 服务端时间由随后的 getHistory 增量合并时带回并原地修正。
                        if (serverDate > 0) {
                            m.rawTimestamp = serverDate
                            m.time = formatMessageTime(serverDate)
                        }
                        m.status = "sent"
                        // 媒体路径此前漏了这行：namespace 停在 NS_LOCAL，已被服务端确认的消息
                        // 仍按「待发」参与全序排序（键序 timestamp → namespace → id），
                        // 同秒内会排到已收消息之后。文字路径一直有，媒体路径补齐。
                        m.namespace = MessageHistoryView.NS_CLOUD
                    })
                } else {
                    // 兜底：服务端 id 取不到就无法换号，本地待发条目会与随后 getHistory
                    // 带回的服务端消息**并存 = 同一条消息两份**（历史刷新改增量合并后暴露）。
                    // 移除本地条目，由服务端那条接管。旧代码是靠 replaceAll 整表替换
                    // 顺带清掉它的 —— 那个副作用现在没有了，必须显式处理。
                    let _ = this.history.remove(newMessage.id)
                }
                try {
                    let historyResponse = messageService.getHistory(
                        peerTypeCopy,
                        chatIdCopy,
                        limit: 30
                    )
                    let messages = this.convertTLMessages(historyResponse)
                    launch { this.mergeMessageList(this.mergeFailedLocals(messages)) }
                    this.downloadPhotosForMessages(messages)
                } catch (e2: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Post-video-note refresh failed: ${e2}")
                }
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Video note send failed: ${result.errorMessage}")
                this.markMessageFailed(newMessage)
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendVideoNote exception: ${e}")
            this.markMessageFailed(newMessage)
        }
        this._pollingPaused = false
    }

    // ==================== Phase P7A-3: 发送投票消息 ====================

    /**
     * 发送投票消息
     * 
     * 创建本地占位消息 → 暂停 polling → messages.sendMedia(InputMediaPoll) → 刷新列表
     * 
     * @param question 投票问题
     * @param options 投票选项列表
     */
    public func sendPoll(question: String, options: ArrayList<String>): Unit {
        this.messageIdCounter += 1
        let newMessage = Message()
        newMessage.id = this.messageIdCounter
        newMessage.content = "[Poll: " + question + "]"
        this.stampLocalMessage(newMessage)
        newMessage.isSent = true
        newMessage.status = "sending"
        newMessage.senderId = this.currentUserId
        newMessage.messageType = "poll"
        newMessage.mediaDescription = "[Poll]"
        newMessage.pollQuestion = question
        
        // 原为「复制整表 + 追加一条 + 整表回写」——两条并发路径会互相覆盖（丢消息）。
        // 改为增量插入：不读旧快照，只提交这一条，天然免疫丢更新。
        // 对齐 iOS .InsertMessage 操作（MessageHistoryView.swift:593）。
        let _ = this.history.insert(newMessage)
        
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let replyId = Int32(this.replyToMsgId)
        launch { this.cancelReply() }
        
        spawn {
            this._pollingPaused = true
            try {
                let messageService = getRealMessageService()
                let result = messageService.sendPoll(
                    peerTypeCopy,
                    chatIdCopy,
                    question,
                    options,
                    replyToMsgId: replyId
                )
                if (result.success) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Poll sent successfully")
                    if (result.messageId != 0) {
                        // 本地 id → 服务端 id 必须走容器算子。直接改 newMessage.id 只动对象字段，
                        // 容器的 byId 索引会停在旧的本地 id、排序位置也不重算（MessageHistoryView.update
                        // 会同步索引并按新键重定位）。此前这个不一致被随后的 replaceAll 整表替换掩盖；
                        // 历史刷新改为增量合并后就会暴露成**同一条消息出现两份**。与文字路径 sendMessage 对齐。
                        let localId = newMessage.id
                        let serverId = Int64(result.messageId)
                        let serverDate = Int64(result.date)
                        let _ = this.history.update(localId, { m: Message =>
                            m.id = serverId
                            // 媒体发送走 Updates 响应，其中只有 updateMessageID(id, random_id)、**没有 date**。
                            // 0 不能写进排序键（全序键 timestamp → namespace → id），
                            // 服务端时间由随后的 getHistory 增量合并时带回并原地修正。
                            if (serverDate > 0) {
                                m.rawTimestamp = serverDate
                                m.time = formatMessageTime(serverDate)
                            }
                            m.status = "sent"
                            // 媒体路径此前漏了这行：namespace 停在 NS_LOCAL，已被服务端确认的消息
                            // 仍按「待发」参与全序排序（键序 timestamp → namespace → id），
                            // 同秒内会排到已收消息之后。文字路径一直有，媒体路径补齐。
                            m.namespace = MessageHistoryView.NS_CLOUD
                        })
                    } else {
                        // 兜底：服务端 id 取不到就无法换号，本地待发条目会与随后 getHistory
                        // 带回的服务端消息**并存 = 同一条消息两份**（历史刷新改增量合并后暴露）。
                        // 移除本地条目，由服务端那条接管。旧代码是靠 replaceAll 整表替换
                        // 顺带清掉它的 —— 那个副作用现在没有了，必须显式处理。
                        let _ = this.history.remove(newMessage.id)
                    }
                    try {
                        let historyResponse = messageService.getHistory(
                            peerTypeCopy,
                            chatIdCopy,
                            limit: 30
                        )
                        let messages = this.convertTLMessages(historyResponse)
                        launch { this.mergeMessageList(this.mergeFailedLocals(messages)) }
                        this.downloadPhotosForMessages(messages)
                    } catch (e2: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Post-poll refresh failed: ${e2}")
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Poll send failed: ${result.errorMessage}")
                    this.markMessageFailed(newMessage)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendPoll exception: ${e}")
                this.markMessageFailed(newMessage)
            }
            this._pollingPaused = false
        }
    }

    // ==================== Phase P7A-2: 发送联系人卡片 ====================

    /**
     * 发送联系人卡片消息
     * 
     * 创建本地占位消息 → 暂停 polling → messages.sendMedia(InputMediaContact) → 刷新列表
     * 
     * @param phoneNumber 电话号码
     * @param firstName 名
     * @param lastName 姓
     * @param vcard vCard 字符串（可为空）
     */
    public func sendContact(phoneNumber: String, firstName: String, lastName: String, vcard: String): Unit {
        this.messageIdCounter += 1
        let displayName = if (lastName.size > 0) { firstName + " " + lastName } else { firstName }
        let newMessage = Message()
        newMessage.id = this.messageIdCounter
        newMessage.content = ""
        this.stampLocalMessage(newMessage)
        newMessage.isSent = true
        newMessage.status = "sending"
        newMessage.senderId = this.currentUserId
        newMessage.messageType = "contact"
        newMessage.mediaDescription = "[Contact: " + displayName + "]"
        newMessage.contactDisplayName = displayName
        newMessage.contactPhone = phoneNumber
        
        // 原为「复制整表 + 追加一条 + 整表回写」——两条并发路径会互相覆盖（丢消息）。
        // 改为增量插入：不读旧快照，只提交这一条，天然免疫丢更新。
        // 对齐 iOS .InsertMessage 操作（MessageHistoryView.swift:593）。
        let _ = this.history.insert(newMessage)
        
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let replyId = Int32(this.replyToMsgId)
        launch { this.cancelReply() }
        
        spawn {
            this._pollingPaused = true
            try {
                let messageService = getRealMessageService()
                let result = messageService.sendContact(
                    peerTypeCopy,
                    chatIdCopy,
                    phoneNumber,
                    firstName,
                    lastName,
                    vcard: vcard,
                    replyToMsgId: replyId
                )
                if (result.success) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Contact sent successfully")
                    if (result.messageId != 0) {
                        // 本地 id → 服务端 id 必须走容器算子。直接改 newMessage.id 只动对象字段，
                        // 容器的 byId 索引会停在旧的本地 id、排序位置也不重算（MessageHistoryView.update
                        // 会同步索引并按新键重定位）。此前这个不一致被随后的 replaceAll 整表替换掩盖；
                        // 历史刷新改为增量合并后就会暴露成**同一条消息出现两份**。与文字路径 sendMessage 对齐。
                        let localId = newMessage.id
                        let serverId = Int64(result.messageId)
                        let serverDate = Int64(result.date)
                        let _ = this.history.update(localId, { m: Message =>
                            m.id = serverId
                            // 媒体发送走 Updates 响应，其中只有 updateMessageID(id, random_id)、**没有 date**。
                            // 0 不能写进排序键（全序键 timestamp → namespace → id），
                            // 服务端时间由随后的 getHistory 增量合并时带回并原地修正。
                            if (serverDate > 0) {
                                m.rawTimestamp = serverDate
                                m.time = formatMessageTime(serverDate)
                            }
                            m.status = "sent"
                            // 媒体路径此前漏了这行：namespace 停在 NS_LOCAL，已被服务端确认的消息
                            // 仍按「待发」参与全序排序（键序 timestamp → namespace → id），
                            // 同秒内会排到已收消息之后。文字路径一直有，媒体路径补齐。
                            m.namespace = MessageHistoryView.NS_CLOUD
                        })
                    } else {
                        // 兜底：服务端 id 取不到就无法换号，本地待发条目会与随后 getHistory
                        // 带回的服务端消息**并存 = 同一条消息两份**（历史刷新改增量合并后暴露）。
                        // 移除本地条目，由服务端那条接管。旧代码是靠 replaceAll 整表替换
                        // 顺带清掉它的 —— 那个副作用现在没有了，必须显式处理。
                        let _ = this.history.remove(newMessage.id)
                    }
                    try {
                        let historyResponse = messageService.getHistory(
                            peerTypeCopy,
                            chatIdCopy,
                            limit: 30
                        )
                        let messages = this.convertTLMessages(historyResponse)
                        launch { this.mergeMessageList(this.mergeFailedLocals(messages)) }
                        this.downloadPhotosForMessages(messages)
                    } catch (e2: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Post-contact refresh failed: ${e2}")
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Contact send failed: ${result.errorMessage}")
                    this.markMessageFailed(newMessage)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendContact exception: ${e}")
                this.markMessageFailed(newMessage)
            }
            this._pollingPaused = false
        }
    }

    // ==================== Phase P7A-1: 发送位置消息 ====================

    /**
     * 发送地理位置消息
     * 
     * 创建本地占位消息 → 暂停 polling → messages.sendMedia(InputMediaGeoPoint) → 刷新列表
     * 
     * @param lat 纬度
     * @param lng 经度
     */
    /** 附件面板：按引用发送已有文档/音乐；成功后拉取更新消息回填列表 */
    public func sendDocumentByReference(docId: Int64, accessHash: Int64, fileReference: Array<Byte>): Unit {
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let replyId = Int32(this.replyToMsgId)
        launch { this.cancelReply() }
        spawn {
            try {
                let result = getRealMessageService().sendDocumentByReference(
                    peerTypeCopy, chatIdCopy, docId, accessHash, fileReference, replyToMsgId: replyId)
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendDocumentByReference ok=${result.success}")
                if (result.success) { launch { this.loadNewerMessages() } }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendDocumentByReference failed: ${e}")
            }
        }
    }

    /** 附件面板 Location 页签：发送场馆 */
    public func sendVenue(lat: Float64, lng: Float64, title: String, address: String,
                          provider: String, venueId: String, venueType: String): Unit {
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let replyId = Int32(this.replyToMsgId)
        launch { this.cancelReply() }
        spawn {
            try {
                let result = getRealMessageService().sendVenue(
                    peerTypeCopy, chatIdCopy, lat, lng, title, address, provider, venueId, venueType,
                    replyToMsgId: replyId)
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendVenue ok=${result.success}")
                if (result.success) { launch { this.loadNewerMessages() } }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendVenue failed: ${e}")
            }
        }
    }

    public func sendLocation(lat: Float64, lng: Float64): Unit {
        this.messageIdCounter += 1
        let newMessage = Message()
        newMessage.id = this.messageIdCounter
        newMessage.content = "[Location]"
        this.stampLocalMessage(newMessage)
        newMessage.isSent = true
        newMessage.status = "sending"
        newMessage.senderId = this.currentUserId
        newMessage.messageType = "location"
        newMessage.mediaDescription = "[Location]"
        newMessage.locationLat = lat
        newMessage.locationLng = lng
        
        // 原为「复制整表 + 追加一条 + 整表回写」——两条并发路径会互相覆盖（丢消息）。
        // 改为增量插入：不读旧快照，只提交这一条，天然免疫丢更新。
        // 对齐 iOS .InsertMessage 操作（MessageHistoryView.swift:593）。
        let _ = this.history.insert(newMessage)
        
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let replyId = Int32(this.replyToMsgId)
        launch { this.cancelReply() }
        
        spawn {
            this._pollingPaused = true
            try {
                let messageService = getRealMessageService()
                let result = messageService.sendLocation(
                    peerTypeCopy,
                    chatIdCopy,
                    lat,
                    lng,
                    replyToMsgId: replyId
                )
                if (result.success) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Location sent successfully")
                    if (result.messageId != 0) {
                        // 本地 id → 服务端 id 必须走容器算子。直接改 newMessage.id 只动对象字段，
                        // 容器的 byId 索引会停在旧的本地 id、排序位置也不重算（MessageHistoryView.update
                        // 会同步索引并按新键重定位）。此前这个不一致被随后的 replaceAll 整表替换掩盖；
                        // 历史刷新改为增量合并后就会暴露成**同一条消息出现两份**。与文字路径 sendMessage 对齐。
                        let localId = newMessage.id
                        let serverId = Int64(result.messageId)
                        let serverDate = Int64(result.date)
                        let _ = this.history.update(localId, { m: Message =>
                            m.id = serverId
                            // 媒体发送走 Updates 响应，其中只有 updateMessageID(id, random_id)、**没有 date**。
                            // 0 不能写进排序键（全序键 timestamp → namespace → id），
                            // 服务端时间由随后的 getHistory 增量合并时带回并原地修正。
                            if (serverDate > 0) {
                                m.rawTimestamp = serverDate
                                m.time = formatMessageTime(serverDate)
                            }
                            m.status = "sent"
                            // 媒体路径此前漏了这行：namespace 停在 NS_LOCAL，已被服务端确认的消息
                            // 仍按「待发」参与全序排序（键序 timestamp → namespace → id），
                            // 同秒内会排到已收消息之后。文字路径一直有，媒体路径补齐。
                            m.namespace = MessageHistoryView.NS_CLOUD
                        })
                    } else {
                        // 兜底：服务端 id 取不到就无法换号，本地待发条目会与随后 getHistory
                        // 带回的服务端消息**并存 = 同一条消息两份**（历史刷新改增量合并后暴露）。
                        // 移除本地条目，由服务端那条接管。旧代码是靠 replaceAll 整表替换
                        // 顺带清掉它的 —— 那个副作用现在没有了，必须显式处理。
                        let _ = this.history.remove(newMessage.id)
                    }
                    try {
                        let historyResponse = messageService.getHistory(
                            peerTypeCopy,
                            chatIdCopy,
                            limit: 30
                        )
                        let messages = this.convertTLMessages(historyResponse)
                        launch { this.mergeMessageList(this.mergeFailedLocals(messages)) }
                        this.downloadPhotosForMessages(messages)
                    } catch (e2: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Post-location refresh failed: ${e2}")
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Location send failed: ${result.errorMessage}")
                    this.markMessageFailed(newMessage)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendLocation exception: ${e}")
                this.markMessageFailed(newMessage)
            }
            this._pollingPaused = false
        }
    }

    /**
     * 发送实时位置消息
     * 
     * 创建本地占位消息 → 暂停 polling → messages.sendMedia(InputMediaGeoLive) → 刷新列表
     * 
     * @param lat 纬度
     * @param lng 经度
     * @param period 分享持续时间（秒）
     */
    public func sendLiveLocation(lat: Float64, lng: Float64, period: Int32): Unit {
        this.messageIdCounter += 1
        let newMessage = Message()
        newMessage.id = this.messageIdCounter
        newMessage.content = "[Live Location]"
        this.stampLocalMessage(newMessage)
        newMessage.isSent = true
        newMessage.status = "sending"
        newMessage.senderId = this.currentUserId
        newMessage.messageType = "location"
        newMessage.mediaDescription = "[Live Location]"
        newMessage.locationLat = lat
        newMessage.locationLng = lng
        newMessage.isLiveLocation = true
        newMessage.liveLocationPeriod = period
        
        // 原为「复制整表 + 追加一条 + 整表回写」——两条并发路径会互相覆盖（丢消息）。
        // 改为增量插入：不读旧快照，只提交这一条，天然免疫丢更新。
        // 对齐 iOS .InsertMessage 操作（MessageHistoryView.swift:593）。
        let _ = this.history.insert(newMessage)
        
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let replyId = Int32(this.replyToMsgId)
        launch { this.cancelReply() }
        
        spawn {
            this._pollingPaused = true
            try {
                let messageService = getRealMessageService()
                let result = messageService.sendLiveLocation(
                    peerTypeCopy,
                    chatIdCopy,
                    lat,
                    lng,
                    period: period,
                    replyToMsgId: replyId
                )
                if (result.success) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Live location sent successfully")
                    if (result.messageId != 0) {
                        // 本地 id → 服务端 id 必须走容器算子。直接改 newMessage.id 只动对象字段，
                        // 容器的 byId 索引会停在旧的本地 id、排序位置也不重算（MessageHistoryView.update
                        // 会同步索引并按新键重定位）。此前这个不一致被随后的 replaceAll 整表替换掩盖；
                        // 历史刷新改为增量合并后就会暴露成**同一条消息出现两份**。与文字路径 sendMessage 对齐。
                        let localId = newMessage.id
                        let serverId = Int64(result.messageId)
                        let serverDate = Int64(result.date)
                        let _ = this.history.update(localId, { m: Message =>
                            m.id = serverId
                            // 媒体发送走 Updates 响应，其中只有 updateMessageID(id, random_id)、**没有 date**。
                            // 0 不能写进排序键（全序键 timestamp → namespace → id），
                            // 服务端时间由随后的 getHistory 增量合并时带回并原地修正。
                            if (serverDate > 0) {
                                m.rawTimestamp = serverDate
                                m.time = formatMessageTime(serverDate)
                            }
                            m.status = "sent"
                            // 媒体路径此前漏了这行：namespace 停在 NS_LOCAL，已被服务端确认的消息
                            // 仍按「待发」参与全序排序（键序 timestamp → namespace → id），
                            // 同秒内会排到已收消息之后。文字路径一直有，媒体路径补齐。
                            m.namespace = MessageHistoryView.NS_CLOUD
                        })
                    } else {
                        // 兜底：服务端 id 取不到就无法换号，本地待发条目会与随后 getHistory
                        // 带回的服务端消息**并存 = 同一条消息两份**（历史刷新改增量合并后暴露）。
                        // 移除本地条目，由服务端那条接管。旧代码是靠 replaceAll 整表替换
                        // 顺带清掉它的 —— 那个副作用现在没有了，必须显式处理。
                        let _ = this.history.remove(newMessage.id)
                    }
                    try {
                        let historyResponse = messageService.getHistory(
                            peerTypeCopy,
                            chatIdCopy,
                            limit: 30
                        )
                        let messages = this.convertTLMessages(historyResponse)
                        launch { this.mergeMessageList(this.mergeFailedLocals(messages)) }
                        this.downloadPhotosForMessages(messages)
                    } catch (e2: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Post-live-location refresh failed: ${e2}")
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Live location send failed: ${result.errorMessage}")
                    this.markMessageFailed(newMessage)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendLiveLocation exception: ${e}")
                this.markMessageFailed(newMessage)
            }
            this._pollingPaused = false
        }
    }

    // ==================== Phase A5: 回复管理 ====================
    
    /**
     * 设置回复目标消息
     */
    public func setReplyTo(messageId: Int64, text: String, senderName: String) {
        this.replyToMsgId = messageId
        this.replyToText = truncateRunes(text, 100)
        this.replyToSenderName = senderName
        // P2-115: 默认不带引用文本（普通回复）
        this.replyQuoteText = ""
        this.replyQuoteOffset = 0
        // 清除编辑状态（回复和编辑互斥）
        this.editingMsgId = 0
        this.editingOriginalText = ""
    }

    /**
     * P2-115: 设置带引用文本的回复（quote reply）
     * quoteText: 引用的部分文本；quoteOffset: 引用起始字符偏移量（0 = 从头）
     */
    public func setReplyToWithQuote(messageId: Int64, text: String, senderName: String, quoteText: String, quoteOffset: Int32) {
        this.replyToMsgId = messageId
        this.replyToText = truncateRunes(text, 100)
        this.replyToSenderName = senderName
        this.replyQuoteText = if (quoteText.size > 200) { quoteText[0..200] } else { quoteText }
        this.replyQuoteOffset = quoteOffset
        this.editingMsgId = 0
        this.editingOriginalText = ""
    }

    /**
     * 取消回复
     */
    public func cancelReply() {
        this.replyToMsgId = 0
        this.replyToText = ""
        this.replyToSenderName = ""
        this.replyQuoteText = ""
        this.replyQuoteOffset = 0
    }

    // ==================== P2-117: 草稿持久化 (含 reply_to) ====================

    /**
     * 保存草稿到本地 Preferences + 服务端 messages.saveDraft
     * - 本地：通过 ChatInterfaceStateService 按 chatId 分区存储草稿文本 + replyToMsgId
     * - 服务端：异步发送 MessagesSaveDraft RPC（含 reply_to 时设置 flags.4）
     *
     * iOS 对应: ManagedSynchronizeChatInputStateOperations.swift → messages.saveDraft
     * ctor 对照: Api42.swift:9033 buffer.appendInt32(-1391484580) = 0xad0fa15c
     */
    public func saveDraftWithReply(draftText: String): Unit {
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let replyId = Int32(this.replyToMsgId)

        // 本地持久化（带 reply 状态）
        let cisSvc = getChatInterfaceStateService()
        cisSvc.saveDraftState(chatIdCopy, draftText)
        if (replyId > 0) {
            cisSvc.setReplyState(chatIdCopy, this.replyToMsgId, this.replyToSenderName, this.replyToText)
        }
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-117 draft saved locally: '${draftText}', replyId=${replyId}")

        // 服务端异步同步
        let replyIdCopy = replyId
        spawn {
            try {
                let svc = getRealMessageService()
                let client = getMTProtoClient()
                let req = MessagesSaveDraft()
                req.message = draftText
                req.replyToMsgId = replyIdCopy
                req.peer = svc.buildInputPeer(peerTypeCopy, chatIdCopy)
                let _ = client.sendRequest(req.toBytes())
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-117 draft synced to server: peer=${chatIdCopy}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-117 draft server sync error: ${e}")
            }
        }
    }

    /**
     * 清除草稿（发送消息后调用）
     * 本地清除 + 服务端发送空草稿（messages.saveDraft message=""）
     */
    public func clearDraftAfterSend(): Unit {
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType

        // 本地清除（含 reply/edit 状态）
        let cisSvc = getChatInterfaceStateService()
        cisSvc.clearState(chatIdCopy)
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-117 draft + interface state cleared locally after send")

        // 服务端清除（空草稿）
        spawn {
            try {
                let svc = getRealMessageService()
                let client = getMTProtoClient()
                let req = MessagesSaveDraft()
                req.message = ""
                req.replyToMsgId = 0
                req.peer = svc.buildInputPeer(peerTypeCopy, chatIdCopy)
                let _ = client.sendRequest(req.toBytes())
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-117 draft cleared on server: peer=${chatIdCopy}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-117 draft server clear error: ${e}")
            }
        }
    }

    // ==================== Phase A5: 编辑管理 ====================
    
    /**
     * 开始编辑消息
     */
    public func startEditing(messageId: Int64, originalText: String) {
        this.editingMsgId = messageId
        this.editingOriginalText = originalText
        this.inputText = originalText
        // 清除回复状态
        this.cancelReply()
    }
    
    /**
     * 确认编辑
     */
    public func confirmEdit(newText: String) {
        let msgId = Int32(this.editingMsgId)
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        
        // 本地乐观更新
        for (msg in this.messageList) {
            if (msg.id == this.editingMsgId) {
                msg.content = newText
                msg.isEdited = true
                break
            }
        }
        // 触发 UI 刷新
        // 前面已原地改过 Message 字段（内容/状态/下载路径，均不影响排序键）。
        // 原为「复制整表 + 整表回写」——回写才是竞态所在；现在只重发快照，不动权威容器。
        this.refreshMessageSnapshot()
        
        this.cancelEdit()
        
        // 服务端编辑（暂停 polling 避免并发 MTProto 访问）
        spawn {
            this._pollingPaused = true
            try {
                let svc = getRealMessageService()
                let success = svc.editMessage(peerTypeCopy, chatIdCopy, msgId, newText)
                if (success) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Message edited successfully")
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Edit failed on server")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Edit exception: ${e}")
            }
            this._pollingPaused = false
        }
    }
    
    /**
     * 取消编辑
     */
    public func cancelEdit() {
        this.editingMsgId = 0
        this.editingOriginalText = ""
        this.inputText = ""
    }
    
    // ==================== Phase A5 / P2-114: 删除消息（服务端 + 本地）====================

    /**
     * 删除单条消息
     * P2-114: revoke=true → messages.deleteMessages 带 flags bit0 (Delete for Everyone)
     *         revoke=false → 仅删除自己一侧 (Delete for Me)
     * iOS PendingMessageManager.swift: MessagesDeleteMessages.revoke
     */
    public func deleteMessage(messageId: Int64, revoke!: Bool = true) {
        // 本地删除：改为增量移除（对齐 iOS .Remove 操作，MessageHistoryView.swift:595），
        // 不再「重建整表再回写」——那会覆盖并发写入。
        var failedLocal: Option<Message> = None
        for (msg in this.messageList) {
            if (msg.id == messageId && msg.status == "failed") {
                failedLocal = Some(msg)
            }
        }
        let _ = this.history.remove(messageId)

        // 失败消息从未到达服务端：只清理磁盘事实源，不发送 messages.deleteMessages。
        match (failedLocal) {
            case Some(message) =>
                failedStoreRemove(this.chatId, message)
                return
            case None => ()
        }

        // 服务端删除（暂停 polling 避免并发 MTProto 访问）
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let msgIdCopy = Int32(messageId)
        let revokeCopy = revoke
        spawn {
            // 本地消息表同步删除（iOS DeleteMessagesInteractively 先删 Postbox 再发请求），
            // 否则冷启动 local-first 读取会让被删消息复活。
            let localIds = ArrayList<Int64>()
            localIds.add(Int64(msgIdCopy))
            getMessageHistoryStore().removeMessages(chatIdCopy, localIds, peerType: peerTypeCopy)
            this._pollingPaused = true
            try {
                let svc = getRealMessageService()
                let ids = ArrayList<Int32>()
                ids.add(msgIdCopy)
                let _ = svc.deleteMessages(peerTypeCopy, chatIdCopy, ids, revoke: revokeCopy)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Delete exception: ${e}")
            }
            this._pollingPaused = false
        }
    }

    /**
     * P2-114: 批量删除选中的消息
     * messageIds: 要删除的消息 ID 列表
     * revoke: true = Delete for Everyone; false = Delete for Me
     */
    public func deleteMessages(messageIds: ArrayList<Int64>, revoke!: Bool = true) {
        if (messageIds.isEmpty()) { return }
        // 本地删除
        let deleteSet = HashMap<Int64, Bool>()
        for (id in messageIds) { deleteSet[id] = true }
        let failedIds = HashMap<Int64, Bool>()
        let failedMessages = ArrayList<Message>()
        for (msg in this.messageList) {
            if (deleteSet.contains(msg.id) && msg.status == "failed") {
                failedIds[msg.id] = true
                failedMessages.add(msg)
            }
        }
        // 逐条增量移除，取代「重建整表再回写」。
        for (id in messageIds) {
            let _ = this.history.remove(id)
        }
        for (message in failedMessages) {
            failedStoreRemove(this.chatId, message)
        }

        // 仅把真正存在于服务端的消息 ID 送入 deleteMessages。
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let revokeCopy = revoke
        let idsCopy = ArrayList<Int32>()
        for (id in messageIds) {
            if (!failedIds.contains(id)) { idsCopy.add(Int32(id)) }
        }
        if (idsCopy.isEmpty()) { return }
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Batch delete server=${idsCopy.size}, failedLocal=${failedMessages.size}, revoke=${revoke}")
        spawn {
            // 同 deleteMessage：本地消息表先删，再发服务端请求。
            let localIds = ArrayList<Int64>()
            for (id in idsCopy) { localIds.add(Int64(id)) }
            getMessageHistoryStore().removeMessages(chatIdCopy, localIds, peerType: peerTypeCopy)
            this._pollingPaused = true
            try {
                let svc = getRealMessageService()
                let _ = svc.deleteMessages(peerTypeCopy, chatIdCopy, idsCopy, revoke: revokeCopy)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Batch delete exception: ${e}")
            }
            this._pollingPaused = false
        }
    }
    
    // ==================== Phase P0-1: 转发消息（真实 API 调用）====================
    
    /**
     * 转发消息到目标对话
     * 
     * 数据流: UI → forwardMessage → RealMessageService.forwardMessages
     *   → messages.forwardMessages TL → MTProtoClient.sendRequest
     * 
     * 转发完成后如果目标是当前聊天，自动刷新消息列表
     */
    public func forwardMessage(messageId: Int64, toPeerType: String, toPeerId: Int64,
        dropAuthor!: Bool = false, dropMediaCaptions!: Bool = false,
        onResult!: Option<(Bool) -> Unit> = None): Unit {
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let msgIdCopy = Int32(messageId)
        let dropAuthorCopy = dropAuthor
        let dropCaptionsCopy = dropMediaCaptions

        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Forwarding msg ${messageId} to ${toPeerType}:${toPeerId} dropAuthor=${dropAuthor}")

        spawn {
            this._pollingPaused = true
            try {
                let svc = getRealMessageService()
                let ids = ArrayList<Int32>()
                ids.add(msgIdCopy)
                let success = svc.forwardMessages(
                    peerTypeCopy,
                    chatIdCopy,
                    toPeerType,
                    toPeerId,
                    ids,
                    dropAuthor: dropAuthorCopy,
                    dropMediaCaptions: dropCaptionsCopy
                )
                match (onResult) { case Some(cb) => cb(success); case None => () }
                if (success) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Message forwarded successfully")
                    // 如果目标是当前聊天，刷新消息列表以显示转发的消息
                    if (toPeerId == chatIdCopy && toPeerType == peerTypeCopy) {
                        try {
                            let messageService = getRealMessageService()
                            let historyResponse = messageService.getHistory(
                                peerTypeCopy,
                                chatIdCopy,
                                limit: 30
                            )
                            let messages = this.convertTLMessages(historyResponse)
                            launch { this.mergeMessageList(this.mergeFailedLocals(messages)) }
                            this.downloadPhotosForMessages(messages)
                        } catch (e2: Exception) {
                            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Post-forward refresh failed: ${e2}")
                        }
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Forward failed on server")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Forward exception: ${e}")
                match (onResult) { case Some(cb) => cb(false); case None => () }
            }
            this._pollingPaused = false
        }
    }

    /**
     * P2-115: 批量转发多条消息到目标聊天
     * dropAuthor: true = 不显示原发送者姓名（iOS hideSendersNames, bit11）
     * dropMediaCaptions: true = 不携带媒体 caption（iOS hideCaptions, bit12）
     */
    public func forwardMessages(messageIds: ArrayList<Int64>, toPeerType: String, toPeerId: Int64,
        dropAuthor!: Bool = false, dropMediaCaptions!: Bool = false,
        onResult!: Option<(Bool) -> Unit> = None): Unit {
        if (messageIds.isEmpty()) { return }
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let dropAuthorCopy = dropAuthor
        let dropCaptionsCopy = dropMediaCaptions
        let idsCopy = ArrayList<Int32>()
        for (id in messageIds) { idsCopy.add(Int32(id)) }

        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Batch forward ${messageIds.size} msgs to ${toPeerType}:${toPeerId}")

        spawn {
            this._pollingPaused = true
            try {
                let svc = getRealMessageService()
                let success = svc.forwardMessages(
                    peerTypeCopy,
                    chatIdCopy,
                    toPeerType,
                    toPeerId,
                    idsCopy,
                    dropAuthor: dropAuthorCopy,
                    dropMediaCaptions: dropCaptionsCopy
                )
                match (onResult) { case Some(cb) => cb(success); case None => () }
                if (success) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Batch forward success")
                    if (toPeerId == chatIdCopy && toPeerType == peerTypeCopy) {
                        try {
                            let messageService = getRealMessageService()
                            let historyResponse = messageService.getHistory(
                                peerTypeCopy,
                                chatIdCopy,
                                limit: 30
                            )
                            let messages = this.convertTLMessages(historyResponse)
                            launch { this.mergeMessageList(this.mergeFailedLocals(messages)) }
                            this.downloadPhotosForMessages(messages)
                        } catch (e2: Exception) {
                            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Post-batchforward refresh failed: ${e2}")
                        }
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Batch forward failed on server")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Batch forward exception: ${e}")
                match (onResult) { case Some(cb) => cb(false); case None => () }
            }
            this._pollingPaused = false
        }
    }

    // ==================== Phase Q10: 消息置顶 ====================

    /**
     * 置顶一条消息
     * 本地记录置顶状态 + 异步发送到服务端
     */
    public func pinMessage(messageId: Int64, messageText: String) {
        this.pinnedMessageId = messageId
        this.pinnedMessageText = if (messageText.size > 100) { messageText[0..100] + "..." } else { messageText }
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Pin message: ${messageId}")

        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let msgIdCopy = Int32(messageId)
        spawn {
            this._pollingPaused = true
            try {
                let svc = getRealMessageService()
                let success = svc.pinMessage(peerTypeCopy, chatIdCopy, msgIdCopy)
                if (success) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Message pinned on server")
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Pin failed on server")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Pin exception: ${e}")
            }
            this._pollingPaused = false
        }
    }

    /**
     * 取消置顶消息
     */
    public func unpinMessage() {
        let msgId = Int32(this.pinnedMessageId)
        this.pinnedMessageId = 0
        this.pinnedMessageText = ""
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Unpin message: ${msgId}")

        if (msgId <= 0) { return }
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        spawn {
            this._pollingPaused = true
            try {
                let svc = getRealMessageService()
                let success = svc.unpinMessage(peerTypeCopy, chatIdCopy, msgId)
                if (success) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] Message unpinned on server")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Unpin exception: ${e}")
            }
            this._pollingPaused = false
        }
    }

    // ==================== Phase P5-1: 投票 ====================

    /**
     * Send a vote on a poll option.
     * Updates local state optimistically, then sends messages.sendVote to server.
     */
    public func sendVote(messageId: Int64, optionIndex: Int64): Unit {
        // Find the message
        var targetMsg: Option<Message> = None
        for (m in this.messageList) {
            if (m.id == messageId) {
                targetMsg = Some(m)
                break
            }
        }
        match (targetMsg) {
            case None =>
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendVote: message ${messageId} not found")
                return
            case Some(msg) =>
                if (msg.pollClosed) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendVote: poll is closed")
                    return
                }
                if (optionIndex < 0 || optionIndex >= Int64(msg.pollOptions.size)) { return }

                let opt = msg.pollOptions[optionIndex]
                let optData = opt.optionData

                // Optimistic local update
                opt.chosen = true
                opt.voters = opt.voters + 1
                msg.pollTotalVoters = msg.pollTotalVoters + 1
                // Recalculate percentages
                for (o in msg.pollOptions) {
                    o.percentage = if (msg.pollTotalVoters > 0) { o.voters * 100 / msg.pollTotalVoters } else { 0 }
                }

                let chatIdCopy = this.chatId
                let peerTypeCopy = this.peerType
                let msgIdCopy = Int32(messageId)

                spawn {
                    try {
                        let client = getMTProtoClient()
                        let svc = getRealMessageService()
                        let req = MessagesSendVote()
                        req.msgId = msgIdCopy
                        req.peer = svc.buildInputPeer(peerTypeCopy, chatIdCopy)
                        req.options.add(optData)
                        let response = client.sendRequest(req.toBytes())
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendVote success: msgId=${msgIdCopy}, optIdx=${optionIndex}, resp=${response.size} bytes")
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendVote failed: ${e}")
                        // Revert optimistic update
                        opt.chosen = false
                        opt.voters = opt.voters - 1
                        msg.pollTotalVoters = msg.pollTotalVoters - 1
                        for (o in msg.pollOptions) {
                            o.percentage = if (msg.pollTotalVoters > 0) { o.voters * 100 / msg.pollTotalVoters } else { 0 }
                        }
                    }
                }
        }
    }

    // ==================== Phase H6: 消息 Reactions ====================

    private func currentReactionInitials(): String {
        match (getRealAuthService().getCurrentUser()) {
            case Some(me) =>
                var name = me.firstName
                if (me.lastName.size > 0) { name = name + " " + me.lastName }
                let initials = getNameInitials(name)
                return if (initials.size > 0) { initials } else { "?" }
            case None => return "?"
        }
    }

    private func currentReactionAvatarPath(): String {
        let photoService = getUserPhotoService()
        photoService.requestCurrentUserProfile(this.currentUserId)
        match (getRealAuthService().getCurrentUser()) {
            case Some(me) =>
                if (me.id == this.currentUserId) {
                    match (photoService.getCachedUser(me.id)) {
                        case Some(cached) =>
                            if (!cached.hasPhoto || me.hasPhoto) {
                                photoService.cacheUser(me)
                            }
                        case None => photoService.cacheUser(me)
                    }
                    photoService.requestFullPhotoDownload(me.id)
                }
            case None => ()
        }
        return photoService.getUserPhotoPath(this.currentUserId)
    }

    private func copyReactionPeers(source: ReactionData, target: ReactionData, includeCurrentUser: Bool): Unit {
        var hasCurrent = false
        for (i in 0..source.peerIds.size) {
            let peerId = source.peerIds[i]
            if (peerId == this.currentUserId) {
                hasCurrent = true
                if (!includeCurrentUser) { continue }
                // Optimistic data from older builds may still contain the
                // synthetic "ME" placeholder. Normalize the account peer on
                // every copy instead of carrying that stale UI value forward.
                target.peerIds.add(peerId)
                target.peerAvatarPaths.add(this.currentReactionAvatarPath())
                target.peerInitialsList.add(this.currentReactionInitials())
                continue
            }
            target.peerIds.add(peerId)
            target.peerAvatarPaths.add(if (i < source.peerAvatarPaths.size) { source.peerAvatarPaths[i] } else { "" })
            target.peerInitialsList.add(if (i < source.peerInitialsList.size) { source.peerInitialsList[i] } else { "?" })
        }
        if (includeCurrentUser && !hasCurrent && this.currentUserId > 0) {
            target.peerIds.add(this.currentUserId)
            target.peerAvatarPaths.add(this.currentReactionAvatarPath())
            target.peerInitialsList.add(this.currentReactionInitials())
        }
    }
    
    /**
     * 切换消息反应（点赞/爱心等）
     * 
     * 逻辑：
     * - 如果当前用户已选中该 emoji → 移除反应
     * - 如果当前用户未选中该 emoji → 发送该反应
     * 
     * 采用乐观更新：先本地更新 UI，再异步发送到服务端
     * 使用 _pollingPaused 机制避免与 polling 的 MTProto 并发
     */
    public func toggleReaction(messageId: Int64, emoji: String): Unit {
        // 查找目标消息
        var targetMsg: Option<Message> = None
        for (msg in this.messageList) {
            if (msg.id == messageId) {
                targetMsg = Some(msg)
                break
            }
        }
        
        let msg = match (targetMsg) {
            case Some(m) => m
            case None =>
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] toggleReaction: message ${messageId} not found")
                return
        }
        
        // 检查当前用户是否已选中该 emoji
        var alreadySelected = false
        for (r in msg.reactions) {
            if (r.emoji == emoji && r.isSelected) {
                alreadySelected = true
                break
            }
        }
        
        // 乐观更新本地 UI（peerInitials 在服务端刷新后会重新计算）
        let newReactions = ArrayList<ReactionData>()
        if (alreadySelected) {
            // 移除当前用户的反应
            for (r in msg.reactions) {
                if (r.emoji == emoji) {
                    if (r.count > 1) {
                        // 还有其他人的反应，只减1并取消选中
                        let updated = ReactionData(emoji: r.emoji, count: r.count - 1, isSelected: false, peerInitials: r.peerInitials)
                        this.copyReactionPeers(r, updated, false)
                        newReactions.add(updated)
                    }
                    // count == 1 且是自己的 → 不添加（完全移除）
                } else {
                    newReactions.add(r)
                }
            }
        } else {
            // 添加反应
            var found = false
            for (r in msg.reactions) {
                if (r.emoji == emoji) {
                    // 已存在该 emoji，增加计数并标记选中
                    let updated = ReactionData(emoji: r.emoji, count: r.count + 1, isSelected: true, peerInitials: r.peerInitials)
                    this.copyReactionPeers(r, updated, true)
                    newReactions.add(updated)
                    found = true
                } else {
                    // 取消其他 emoji 的选中状态（Telegram 只允许一个 reaction）
                    if (r.isSelected) {
                        if (r.count > 1) {
                            let updated = ReactionData(emoji: r.emoji, count: r.count - 1, isSelected: false, peerInitials: r.peerInitials)
                            this.copyReactionPeers(r, updated, false)
                            newReactions.add(updated)
                        }
                        // count == 1 且是自己的 → 移除
                    } else {
                        newReactions.add(r)
                    }
                }
            }
            if (!found) {
                // Full iOS-style account peer is available during the optimistic
                // transaction; do not invent a temporary "ME" display identity.
                let added = ReactionData(
                    emoji: emoji,
                    count: 1,
                    isSelected: true,
                    peerInitials: this.currentReactionInitials()
                )
                this.copyReactionPeers(ReactionData(), added, true)
                newReactions.add(added)
            }
        }
        
        // 通过 MessageHistoryView 的事务入口提交。它会显式发送变更通知；
        // 不能先改 messageList 里的共享 Message 再只重发快照，否则 ArkUI 可能复用
        // 旧的 MessageBubble，表现为 RPC 成功但 reaction 行完全没有变化。
        let _ = this.history.update(messageId, { stored: Message =>
            stored.reactions = newReactions
        })
        
        // 异步发送到服务端
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let msgIdCopy = Int32(messageId)
        let emojiCopy = if (alreadySelected) { "" } else { emoji }
        spawn {
            this._pollingPaused = true
            try {
                let svc = getRealMessageService()
                if (emojiCopy.size > 0) {
                    let success = svc.sendReaction(peerTypeCopy, chatIdCopy, msgIdCopy, emojiCopy)
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] sendReaction result: ${success}")
                } else {
                    let success = svc.removeReaction(peerTypeCopy, chatIdCopy, msgIdCopy)
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] removeReaction result: ${success}")
                }
                // Keep the optimistic state. An immediate getHistory can still return
                // the pre-reaction snapshot and overwrite the UI before Telegram has
                // propagated the update; normal Updates/polling performs convergence.
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] toggleReaction exception: ${e}")
            }
            this._pollingPaused = false
        }
    }
    
    // ==================== P2-116: Reactor 列表 ====================

    /**
     * 异步拉取消息的反应者列表，写入 reactorsList / reactorsListMsgId
     *
     * 调用 messages.getMessageReactionsList 真实 RPC，
     * 结果写入 @Publish reactorsList + reactorsListMsgId 触发 UI 重渲。
     * 遵守 S-001：spawn 内调用 RPC，launch 内写 @Publish 字段。
     */
    public func fetchReactorsList(msgId: Int64): Unit {
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] fetchReactorsList: msgId=${msgId}")
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let msgIdCopy = Int32(msgId)
        spawn {
            try {
                let svc = getRealMessageService()
                let list = svc.getReactorsList(peerTypeCopy, chatIdCopy, msgIdCopy)
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] fetchReactorsList: got ${list.size} reactors for msgId=${msgId}")
                let copied = ArrayList<ReactorInfo>()
                for (r in list) { copied.add(r) }
                launch {
                    var temp = this.reactorsList
                    temp = copied
                    this.reactorsList = temp
                    this.reactorsListMsgId = msgId
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] fetchReactorsList exception: ${e}")
            }
        }
    }

    // ==================== P2-118: 群消息已读参与者 ====================

    /**
     * 拉取群消息的已读参与者列表
     * messages.getMessageReadParticipants#31c1c44f peer:InputPeer msg_id:int
     * iOS ref: Api42.swift:7407, Api22.swift:791
     *
     * 遵守 S-001：spawn 内 RPC，launch 内写 @Publish 字段。
     */
    public func fetchReadParticipants(msgId: Int64): Unit {
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] fetchReadParticipants: msgId=${msgId}")
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let msgIdCopy = Int32(msgId)
        spawn {
            try {
                let svc = getRealMessageService()
                let list = svc.getReadParticipants(peerTypeCopy, chatIdCopy, msgIdCopy)
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] fetchReadParticipants: got ${list.size} participants for msgId=${msgId}")
                // Reader names: user cache, then this chat's senders, then users.getUsers.
                let senderNames = HashMap<Int64, String>()
                for (m in this.messageList) {
                    if (m.senderId != 0 && m.senderName.size > 0) { senderNames[m.senderId] = m.senderName }
                }
                fillReadParticipantNames(list, senderNames)
                let copied = ArrayList<ReadParticipantRecord>()
                for (r in list) { copied.add(r) }
                launch {
                    var temp = this.readParticipantsList
                    temp = copied
                    this.readParticipantsList = temp
                    this.readParticipantsMsgId = msgId
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] fetchReadParticipants exception: ${e}")
            }
        }
    }

    // ==================== P2-118: 可见区已读上报 ====================

    /**
     * 用户可见区消息已读上报 — 节流版
     * 当消息滚入可视区时调用，仅在 msgId > _lastReportedReadId 时上报 messages.readHistory。
     * 遵守 S-001：spawn 内调用 RPC。
     */
    public func reportVisibleRead(msgId: Int64): Unit {
        let maxId = Int32(msgId)
        if (maxId <= this._lastReportedReadId) { return }
        this._lastReportedReadId = maxId
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        spawn {
            try {
                let svc = getMessagesService()
                if (normalizeDialogPeerType(peerTypeCopy) == "channel") {
                    svc.applyMaxReadIndexForChannel(chatIdCopy, maxId)
                } else {
                    svc.applyMaxReadIndex(peerTypeCopy, chatIdCopy, maxId)
                }
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-118 visibleRead: msgId=${msgId} reported via readHistory")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-118 visibleRead error: ${e}")
            }
        }
    }

    // ==================== 加载更多历史 ====================

    /**
     * 本地翻页闸门 —— 与网络补洞的闸门（isLoading）分开。
     *
     * 此前两者共用 isLoading：本地那一页瞬间上屏了，但闸门要等**整个网络往返**才放开，
     * 用户继续上划时第二页无法开始，于是撞到顶部干等 —— 这就是「感觉得到加载」。
     * iOS 的 Postbox 本地读与网络 hole fill 是两条独立通道，本地能供上就永远不等网络。
     */
    private var _localPagingBusy: Bool = false
    private var _networkPagingBusy: Bool = false

    /** 预取判据用它，而不是 isLoading（后者只表示网络补洞在跑，用于 UI 提示） */
    public prop isPagingLocal: Bool {
        get() { return this._localPagingBusy }
    }

    public func loadMoreHistory() {
        if (!this.hasMoreHistory || this._localPagingBusy) { return }
        if (this._migratedActive) {
            this.loadMoreMigratedHistory()
            return
        }
        this._localPagingBusy = true
        
        // 锚点取视图里最旧的云消息（iOS hole fill 以 MessageIndex 为界，只看 Cloud namespace）：
        // 待发 / 失败的本地消息 id 不在服务端 id 空间里，拿它当 offsetId 会读错区段。
        var oldestId: Int32 = 0
        for (m in this.messageList) {
            if (m.namespace == MessageHistoryView.NS_CLOUD && m.id > 0 && m.id <= 2147483647) {
                oldestId = Int32(m.id)
                break
            }
        }
        
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let oldestIdCopy = oldestId
        
        spawn {
            // ============ 本地优先（与首屏 loadMessages 对齐） ============
            // iOS 的上翻走 Postbox hole fill，本地已有的区间根本不碰网络。
            // 本地页开大到 60：本地读很便宜，窗口越深越不容易在快速滑动时见底。
            var localFilled = false
            try {
                let localOlder = getMessageHistoryStore().loadLocalMessages(
                    chatIdCopy, 60, oldestIdCopy, peerType: peerTypeCopy)
                if (localOlder.size > 0) {
                    localFilled = this.history.prependAll(localOlder)
                    Hilog.info(0, "CjTelegram",
                        "[HistoryPaging] local hit ${localOlder.size} older msgs (changed=${localFilled}) offsetId=${oldestIdCopy}")
                    // 整页都要回填，不能用 initialMediaWindow ——
                    // 那个窗口只取批次里**最新的 44 条**（start = size - 44），
                    // 而用户往上划恰好是滑进这一页最老的那一段，
                    // 用窗口会让每页末尾若干条的图片/贴纸永远停在占位。
                    // 网络分支一直是整批 downloadPhotosForMessages，这里对齐它。
                    spawn { this.downloadPhotosForMessages(localOlder) }
                } else {
                    Hilog.info(0, "CjTelegram",
                        "[HistoryPaging] local miss offsetId=${oldestIdCopy}")
                }
            } catch (eLocal: Exception) {
                Hilog.info(0, "CjTelegram", "[HistoryPaging] local older load skipped: ${eLocal}")
            }

            // 本地这一页已经上屏 —— 立刻放开闸门，下一页可以马上继续，不等网络。
            this._localPagingBusy = false

            // 本地供得上就不打网络（等价于 iOS「本地已有区间不碰网络」）。
            // 锚点在 hole 里 / 恰为区间下界（loadLocalMessages 已打 [HistoryHole] ... -> network），
            // 或区间内本地没有更早的行，才以 offsetId=锚点 向服务端补洞，并借这次回包更新 hasMore。
            if (localFilled) { return }
            if (this._networkPagingBusy) {
                Hilog.info(0, "CjTelegram",
                    "[HistoryHole] peer=${chatIdCopy} anchor=${oldestIdCopy} network page already in flight")
                return
            }
            this._networkPagingBusy = true
            launch { this.isLoading = true }

            try {
                let messageService = getRealMessageService()
                let historyResponse = messageService.getHistory(
                    peerTypeCopy,
                    chatIdCopy,
                    limit: 44,
                    offsetId: oldestIdCopy
                )
                
                let olderMessages = this.convertTLMessages(historyResponse)
                
                // 原为「拼接 olderMessages + 当前整表 再回写」。改为增量并入：
                // 更早的消息按全序键天然落到前部，无需假设「拼在头部」总是对的。
                let channelHasMore = historyResponse.messages.size >= 44
                let continueMigrated = !channelHasMore && this.beginMigratedHistoryIfNeeded(chatIdCopy, peerTypeCopy)
                let hasMore = channelHasMore || continueMigrated
                let _ = this.history.prependAll(olderMessages)
                // iOS Postbox 会持久化 hole fill；否则页面重建后保存的 scroll anchor
                // 在本地历史表中找不到，只能错误回到最新端。空页也交给 storeHistoryFill：
                // 服务端正常回包且锚点以下没有消息时按 iOS 把整段 hole 填到 1（到头）。
                try {
                    getMessageHistoryStore().storeHistoryFill(chatIdCopy, olderMessages, peerType: peerTypeCopy,
                        offsetId: oldestIdCopy, serverCount: historyResponse.reliableCount())
                } catch (_storeError: Exception) {}
                this._networkPagingBusy = false
                launch {
                    this.hasMoreHistory = hasMore
                    this.isLoading = false
                }
                Hilog.info(0, "CjTelegram",
                    "[HistoryPaging] network filled ${olderMessages.size} older msgs hasMore=${hasMore}")
                // 上划分页返回的媒体必须和首屏、向下分页走同一资源获取链路。
                // 此前这里只 prepend 消息，照片资源从未进入 downloadPhotosForMessages，
                // 因而更早历史中的图片会永久停留在占位状态。
                if (!olderMessages.isEmpty()) {
                    this.downloadPhotosForMessages(olderMessages)
                }
                if (continueMigrated) { this.loadMoreMigratedHistory() }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Load more failed: ${e}")
                this._networkPagingBusy = false
                launch { this.isLoading = false }
            }
        }
    }
    
    // ==================== 升级群：旧基础群历史接在超级群下方 ====================
    //
    // iOS：channelFull.migrated_from_chat_id / migrated_from_max_id → CachedChannelData.migrationReference
    // （UpdateCachedPeerData.swift:790），聊天页以 associated 历史打开（ChatHistoryLocation 带
    // migrationReference），超级群自己的消息到头后继续读旧基础群 id <= max_id 的消息，按时间连续
    // 排在超级群第一条消息下方。旧群消息在服务端属于另一个 peer（messages.getHistory inputPeerChat），
    // 它的 id 与超级群 id 各自编号：落库仍按旧群 peer 原 id 存，并入本视图时映射到负数区间
    // （id - 2^31，保序、不与超级群云消息 / 本地消息 id 相撞，也不会被当作超级群翻页锚点）。

    private var _migratedResolvedFor: Int64 = 0      // 已查过 migrationReference 的超级群 id
    private var _migratedChatId: Int64 = 0            // 旧基础群 id（0 = 不是升级群）
    private var _migratedMaxId: Int32 = 0             // 旧群最后一条（升级服务消息）id
    private var _migratedOldestId: Int32 = 0          // 已并入视图的旧群最老消息原始 id
    private var _migratedActive: Bool = false         // 超级群历史已到头，上翻改读旧群

    private func resetMigratedHistory(): Unit {
        this._migratedResolvedFor = 0
        this._migratedChatId = 0
        this._migratedMaxId = 0
        this._migratedOldestId = 0
        this._migratedActive = false
    }

    /** 超级群历史到头时调用（后台线程）。是升级群则切到旧群历史并返回 true。 */
    private func beginMigratedHistoryIfNeeded(chatIdCopy: Int64, peerTypeCopy: String): Bool {
        if (normalizeDialogPeerType(peerTypeCopy) != "channel") { return false }
        if (this._migratedResolvedFor != chatIdCopy) {
            var fromChatId: Int64 = 0
            var fromMaxId: Int32 = 0
            try {
                let full = getRealMessageService().getFullChatInfo("channel", chatIdCopy)
                fromChatId = full.migratedFromChatId
                fromMaxId = full.migratedFromMaxId
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[MigratedHistory] getFullChannel failed: ${e}")
                return false
            }
            if (this.chatId != chatIdCopy) { return false }
            this._migratedResolvedFor = chatIdCopy
            this._migratedChatId = fromChatId
            this._migratedMaxId = fromMaxId
            this._migratedOldestId = 0
        }
        if (this._migratedChatId == 0) { return false }
        this._migratedActive = true
        Hilog.info(0, "CjTelegram",
            "[MigratedHistory] channel=${chatIdCopy} continues with basic group ${this._migratedChatId} maxId=${this._migratedMaxId}")
        return true
    }

    /** 旧群消息并入视图前：页内补回复预览，并把 id / 回复 id 映射到负数区间。返回本页最老原始 id。 */
    private func adoptMigratedMessages(msgs: ArrayList<Message>): Int32 {
        let byId = HashMap<Int64, Message>()
        var oldest: Int64 = 0
        for (m in msgs) {
            if (m.id > 0) {
                byId[m.id] = m
                if (oldest == 0 || m.id < oldest) { oldest = m.id }
            }
        }
        for (m in msgs) {
            if (m.replyToMsgId > 0 && m.replyToText.size == 0) {
                match (byId.get(m.replyToMsgId)) {
                    case Some(target) =>
                        m.replyToText = truncateRunes(target.content, 50)
                        if (m.replyToSenderName.size == 0) { m.replyToSenderName = target.senderName }
                    case None => ()
                }
            }
        }
        for (m in msgs) {
            if (m.id > 0) { m.id = migratedHistoryViewId(m.id) }
            if (m.replyToMsgId > 0) { m.replyToMsgId = migratedHistoryViewId(m.replyToMsgId) }
        }
        return Int32(oldest)
    }

    /** 上翻一页旧基础群历史：本地（按旧群 peer 落库的区间）优先，缺了再 messages.getHistory(inputPeerChat)。 */
    private func loadMoreMigratedHistory(): Unit {
        let migratedChatId = this._migratedChatId
        if (migratedChatId == 0 || this._localPagingBusy || this._networkPagingBusy) { return }
        this._localPagingBusy = true
        let chatIdCopy = this.chatId
        let offsetId: Int32 = if (this._migratedOldestId > 0) {
            this._migratedOldestId
        } else if (this._migratedMaxId > 0 && this._migratedMaxId < 2147483647) {
            this._migratedMaxId + 1
        } else { 0 }
        spawn {
            var localFilled = false
            if (offsetId > 0) {
                try {
                    let local = getMessageHistoryStore().loadLocalMessages(migratedChatId, 60, offsetId, peerType: "chat")
                    if (!local.isEmpty() && this.chatId == chatIdCopy) {
                        let oldest = this.adoptMigratedMessages(local)
                        localFilled = this.history.prependAll(local)
                        if (oldest > 0) { this._migratedOldestId = oldest }
                        spawn { this.downloadPhotosForMessages(local) }
                    }
                } catch (eLocal: Exception) {
                    Hilog.info(0, "CjTelegram", "[MigratedHistory] local page skipped: ${eLocal}")
                }
            }
            this._localPagingBusy = false
            if (localFilled || this.chatId != chatIdCopy) { return }
            this._networkPagingBusy = true
            launch { this.isLoading = true }
            try {
                let svc = getRealMessageService()
                let resp = svc.getHistory("chat", migratedChatId, limit: 44, offsetId: offsetId)
                let older = svc.parseMessages(resp, this.currentUserId, this.photoPathCache,
                    conversationPeerType: "chat", conversationPeerId: migratedChatId)
                try {
                    getMessageHistoryStore().storeHistoryFill(migratedChatId, older, peerType: "chat",
                        offsetId: offsetId, serverCount: resp.reliableCount())
                } catch (_storeError: Exception) {}
                let hasMore = resp.messages.size >= 44
                if (this.chatId == chatIdCopy) {
                    let oldest = this.adoptMigratedMessages(older)
                    let _ = this.history.prependAll(older)
                    if (oldest > 0) { this._migratedOldestId = oldest }
                    launch { this.hasMoreHistory = hasMore }
                }
                this._networkPagingBusy = false
                launch { this.isLoading = false }
                Hilog.info(0, "CjTelegram",
                    "[MigratedHistory] basic group ${migratedChatId} page ${older.size} msgs offsetId=${offsetId} hasMore=${hasMore}")
                if (!older.isEmpty()) { this.downloadPhotosForMessages(older) }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[MigratedHistory] load failed: ${e}")
                this._networkPagingBusy = false
                launch { this.isLoading = false }
            }
        }
    }

    // ==================== S024: 日历定位（围绕锚点消息加载） ====================

    /**
     * 围绕 anchorId 加载一窗历史（iOS ChatHistoryLocation.Scroll(.id) → hole fill around），
     * 供日历「跳到日期」使用：锚点不在当前列表时先拉取 anchor 前后各约 20 条并入 history，
     * 完成后在 UI 线程回调 onDone（调用方再 scrollToMessage）。
     */
    public func loadHistoryAround(anchorId: Int32, onDone: () -> Unit) {
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        launch { this.isLoading = true }
        spawn {
            try {
                let messageService = getRealMessageService()
                // offsetId=anchor+1, addOffset=-20：窗口覆盖 anchor 及其前后
                let historyResponse = messageService.getHistory(
                    peerTypeCopy,
                    chatIdCopy,
                    limit: 44,
                    offsetId: anchorId + 1,
                    addOffset: -20
                )
                let around = this.convertTLMessages(historyResponse)
                let _ = this.history.prependAll(around)
                var reachedHistoryStart = false
                if (!around.isEmpty()) {
                    try {
                        getMessageHistoryStore().storeHistoryFill(chatIdCopy, around, peerType: peerTypeCopy,
                            offsetId: anchorId + 1, addOffset: -20)
                    } catch (_storeError: Exception) {}
                    this.downloadPhotosForMessages(around)
                    // 窗口 = 20 条更新 + 锚点 + 23 条更早。更早方向回包不足说明服务端历史从本页最小 id
                    // 开始（iOS Holes.swift 对短回包的处理）：本地缓存里比它更早的云消息是离线期间
                    // 被删除/清空的残留，不能接在锚点上方（S2-10 日历跳转落点上方冒出已删旧消息）。
                    // 迁移超级群的更早历史在旧群 peer 里，不适用此推断。
                    if (!this._migratedActive) {
                        var olderReturned = 0
                        var pageMinId: Int64 = 0
                        for (m in around) {
                            if (m.namespace != MessageHistoryView.NS_CLOUD || m.id <= 0) { continue }
                            if (m.id < Int64(anchorId)) { olderReturned += 1 }
                            if (pageMinId == 0 || m.id < pageMinId) { pageMinId = m.id }
                        }
                        let olderRequested = 44 - 20 - 1
                        if (olderReturned < olderRequested && pageMinId > 1) {
                            reachedHistoryStart = true
                            let evicted = this.history.removeCloudBelow(pageMinId)
                            Hilog.info(0, "CjTelegram",
                                "[HistoryPaging] history start at ${pageMinId} (older ${olderReturned}/${olderRequested}): evicted ${evicted} cached older msg(s) from view")
                            try {
                                let _ = getMessageHistoryStore().markHistoryStart(chatIdCopy, pageMinId, peerType: peerTypeCopy)
                            } catch (_storeError: Exception) {}
                        }
                    }
                }
                Hilog.info(0, "CjTelegram", "[HistoryPaging] loadHistoryAround anchor=${anchorId} got ${around.size}")
                let historyStartReached = reachedHistoryStart
                launch {
                    this.isLoading = false
                    if (historyStartReached) { this.hasMoreHistory = false }
                    onDone()
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] loadHistoryAround failed: ${e}")
                launch {
                    this.isLoading = false
                    onDone()
                }
            }
        }
    }

    // ==================== P2-112: 向下分页（加载更新消息） ====================

    /**
     * 向下分页：加载比当前最新消息更新的消息
     *
     * 对照 iOS Holes.swift newer direction (start.id > end.id):
     *   offsetId = start.id + 1  (即 newestId + 1)
     *   addOffset = 0
     *   maxId = start.id + 1    (即 newestId + 1，上界排除 newestId 本身)
     *   minId = end.id = 1      (下界：任何比 newestId 更新的消息)
     *
     * 仓颉参数映射（对照 TL schema #4423e6c5）：
     *   offsetId   = newestId + 1   — 锚点在 newestId 之后，服务端从此往更新方向拉
     *   addOffset  = 0              — 不偏移，直接从 offsetId 往更新方向取
     *   limit      = 20
     *   maxId      = newestId + 1   — 上界：只返回 id >= offsetId 的消息
     *   minId      = 1              — 下界：接受所有更新消息
     */
    public func loadNewerMessages() {
        if (!this.hasMoreNewer || this.isLoadingNewer || this.isLoading) { return }
        this.isLoadingNewer = true

        var newestId: Int32 = 0
        if (!this.messageList.isEmpty()) {
            newestId = Int32(this.messageList[this.messageList.size - 1].id)
        }
        if (newestId == 0) {
            launch { this.isLoadingNewer = false }
            return
        }

        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let newestIdCopy = newestId

        spawn {
            try {
                let svc = getRealMessageService()
                // P2-112: 向下翻页请求 — 对照 iOS Holes.swift newer direction
                // offsetId=newestId+1, addOffset=0, maxId=newestId+1, minId=1
                let req = MessagesGetHistory()
                req.peer = svc.buildInputPeer(peerTypeCopy, chatIdCopy)
                req.offsetId = newestIdCopy + 1
                req.addOffset = 0
                req.limit = 20
                req.maxId = newestIdCopy + 1
                req.minId = 1
                req.offsetDate = 0
                req.hash = 0
                let client = getMTProtoClient()
                let responseData = client.sendRequest(req.toBytes())
                let historyResponse: MessagesHistoryResponse
                if (responseData.size == 0) {
                    historyResponse = MessagesHistoryResponse()
                } else {
                    historyResponse = MessagesHistoryResponse.deserialize(responseData)
                }
                let newerMessages = this.convertTLMessages(historyResponse)

                // 去重：只收集本地没有的消息，交给 history 增量并入（不再拼整表）。
                let existingIds = HashMap<Int64, Bool>()
                for (m in this.messageList) { existingIds[m.id] = true }
                let appendedMessages = ArrayList<Message>()
                for (m in newerMessages) {
                    if (!existingIds.contains(m.id)) {
                        appendedMessages.add(m)
                    }
                }
                // 使用不可变副本供 launch 闭包捕获
                let appendedCount = appendedMessages.size

                // 若返回消息数 >= limit 则可能还有更多；否则已是最新
                let stillHasMore = historyResponse.messages.size >= 20
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-112 loadNewerMessages: appended=${appendedCount}, stillHasMore=${stillHasMore}")
                if (appendedCount > 0) { let _ = this.history.insertMany(appendedMessages) }
                launch {
                    this.hasMoreNewer = stillHasMore
                    this.isLoadingNewer = false
                }
                if (appendedCount > 0) { this.downloadPhotosForMessages(appendedMessages) }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] loadNewerMessages failed: ${e}")
                launch { this.isLoadingNewer = false }
            }
        }
    }

    /**
     * 直接切回 upperBound（最新历史窗口）。对应 iOS scrollToEndOfHistory() 把
     * ChatHistoryLocation 切为 .upperBound，而不是逐页等待 newer hole 填充。
     */
    public func loadLatestHistory(): Unit {
        if (this.isLoadingNewer) { return }
        this.isLoadingNewer = true
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        spawn {
            try {
                let svc = getRealMessageService()
                let response = svc.getHistory(peerTypeCopy, chatIdCopy, limit: 44)
                let latestMessages = this.convertTLMessages(response)
                if (!latestMessages.isEmpty()) {
                    let _ = this.history.insertMany(latestMessages)
                    try { getMessageHistoryStore().storeHistoryFill(chatIdCopy, latestMessages, peerType: peerTypeCopy) } catch (_storeError: Exception) {}
                    this.downloadPhotosForMessages(latestMessages)
                }
                launch {
                    this.hasMoreNewer = false
                    this.isLoadingNewer = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] loadLatestHistory failed: ${e}")
                launch { this.isLoadingNewer = false }
            }
        }
    }

    // ==================== Phase P5-11: 已读回执处理 ====================

    /**
     * 注册 readOutbox 实时更新回调
     * 当对方阅读我发送的消息时，UpdatesManager 推送 (peerId, maxId)
     * 更新本地消息状态为 "read"，触发 UI 蓝色双勾显示
     */
    private func registerReadOutboxHandler(): Unit {
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        if (this._readOutboxSubscriptionToken < 0) {
            this._readOutboxSubscriptionToken = getUpdatesManager().addReadOutboxSubscriber({ peerType: String, peerId: Int64, maxId: Int32 =>
                if (isSameDialogPeer(peerType, peerId, peerTypeCopy, chatIdCopy)) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] ReadOutbox push: maxId=${maxId}")
                    this._readOutboxMaxId = maxId
                    setReadOutboxMaxId(peerType, peerId, maxId)
                    this.applyReadOutboxStatus(maxId)
                }
            })
        }
    }
    
    /**
     * 将所有已发送消息（id <= maxId）的状态更新为 "read"
     * 触发 UI 刷新使双勾变蓝
     */
    private func applyReadOutboxStatus(maxId: Int32): Unit {
        if (maxId > this._readOutboxMaxId) {
            this._readOutboxMaxId = maxId
        }
        // 只负责抬高水位并触发一次发布，具体推导交给 publishSnapshot ——
        // 它以权威容器 history 为准，不会漏掉渲染镜像里还没落地的最新一条。
        this.refreshMessageSnapshot()
    }
    
    /**
     * 当前会话的 readOutboxMaxId。
     *
     * 取本地字段与全局缓存的较大值：字段只由 updateReadHistoryOutbox 推送更新，
     * 而该推送受 pts 校验门控（pts 断层时会被丢弃、改走 getDifference）；
     * 全局缓存则会被会话列表刷新（dialog.readOutboxMaxId）另行写入。
     * 两条来源取 max，避免任一条链路延迟就让双勾迟迟不亮。
     */
    private func currentReadOutboxMaxId(): Int32 {
        let cached = getReadOutboxMaxId(this.peerType, this.chatId)
        if (cached > this._readOutboxMaxId) {
            this._readOutboxMaxId = cached
        }
        return this._readOutboxMaxId
    }

    /**
     * 初始加载/轮询后，根据缓存的 readOutboxMaxId 设置消息已读状态
     */
    private func applyReadOutboxStatusToMessages(messages: ArrayList<Message>): Unit {
        let maxId = this.currentReadOutboxMaxId()
        if (maxId <= 0) { return }
        for (m in messages) {
            if (m.isSent && m.status == "sent") {
                if (Int32(m.id) <= maxId) {
                    m.status = "read"
                }
            }
        }
    }

    // ==================== 标记已读 ====================

    public func markAsRead() {
        if (this.messageList.isEmpty()) { return }
        var maxIncomingId: Int64 = 0
        for (message in this.messageList) {
            if (!message.isSent && message.id > maxIncomingId && message.id <= 2147483647) {
                maxIncomingId = message.id
            }
        }
        if (maxIncomingId <= 0) { return }
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let maxIdCopy = Int32(maxIncomingId)
        spawn {
            let messageService = getMessagesService()
            if (normalizeDialogPeerType(peerTypeCopy) == "channel") {
                messageService.applyMaxReadIndexForChannel(chatIdCopy, maxIdCopy)
            } else {
                messageService.applyMaxReadIndex(peerTypeCopy, chatIdCopy, maxIdCopy)
            }
        }
    }
    
    public func receiveMessage(content: String, senderId: Int64, senderName: String) {
        this.messageIdCounter += 1
        let newMessage = Message()
        newMessage.id = this.messageIdCounter
        newMessage.content = content
        this.stampLocalMessage(newMessage)
        newMessage.isSent = false
        newMessage.status = "received"
        newMessage.senderId = senderId
        newMessage.senderName = senderName
        // 原为「复制整表 + 追加 + 整表回写」，与并发路径互相覆盖。改为增量插入。
        let _ = this.history.insert(newMessage)
    }
    
    public func getLastMessage(): Option<Message> {
        if (this.messageList.isEmpty()) { return None<Message> }
        return Some(this.messageList[this.messageList.size - 1])
    }
    
    public func clearMessages() {
        this.history.clear()
    }
    
    // ==================== Phase R4: 实时推送消息接收 ====================
    
    /**
     * 从 UpdatesManager 推送接收新消息
     * 
     * 检查消息是否属于当前聊天，如果是则追加到 messageList 末尾。
     * 避免重复（检查 ID 是否已存在）。
     */
    public func onNewMessagePush(msg: Message): Unit {
        if (msg.senderPeerType != "user" && msg.senderName.size == 0 && msg.senderId == this.chatId) {
            msg.senderName = this.chatName
        }
        if (msg.senderPeerType == "user" && this.senderRoleById.contains(msg.senderId)) {
            msg.senderRole = this.senderRoleById[msg.senderId]
        }
        // 检查是否属于当前聊天
        // 消息的 chatId 可能是发送者 ID（私聊）或群 ID（群聊）
        // 不做严格匹配 — 由调用方确保
        
        // 检查重复
        for (existing in this.messageList) {
            if (existing.id == msg.id) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] Duplicate push message ignored: id=${msg.id}")
                return
            }
        }
        
        // Start the resource fetch at update delivery time, before List diffing
        // and layout. iOS begins freeMediaFileInteractiveFetched from item
        // setup; the renderer itself still waits for stable visibility.
        let newList = ArrayList<Message>()
        newList.add(msg)
        let receivedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let _ = spawn {
            if (msg.messageType == "text" && isSingleEmoji(msg.content)) {
                let _ = prefetchAnimatedEmojiResource(msg.content)
            }
            this.downloadPhotosForMessages(newList, interactive: true, autosave: true)
            Hilog.info(0, "CjTelegram",
                "[IncomingMediaPerf] resources resolved message=${msg.id} elapsedMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - receivedAt}")
        }

        // 追加：改为增量插入，由全序键决定落点（不必假设「追加到末尾」总是对的 ——
        // 服务端消息可能比本地待发消息更早）。对齐 iOS .InsertMessage。
        let _ = this.history.insert(msg)

        Hilog.info(0, "CjTelegram", "[ChatRoomVM] Push message added: id=${msg.id}, type=${msg.messageType}")
    }
    
    /**
     * Phase R5: 从 UpdatesManager 推送接收编辑消息
     * 
     * 查找并替换 messageList 中对应 ID 的消息。
     */
    public func onEditMessagePush(msg: Message): Unit {
        var found = false
        for (existing in this.messageList) {
            if (existing.id == msg.id) {
                // 替换为编辑后的版本（保留照片本地路径）
                if (existing.photoLocalPath.size > 0 && msg.photoLocalPath.size == 0) {
                    msg.photoLocalPath = existing.photoLocalPath
                }
                if (existing.documentLocalPath.size > 0 && msg.documentLocalPath.size == 0) {
                    msg.documentLocalPath = existing.documentLocalPath
                }
                if (existing.documentThumbnailPath.size > 0 && msg.documentThumbnailPath.size == 0) {
                    msg.documentThumbnailPath = existing.documentThumbnailPath
                }
                // P7B-1: 保留网页预览缩略图路径
                if (existing.webPagePhotoLocalPath.size > 0 && msg.webPagePhotoLocalPath.size == 0) {
                    msg.webPagePhotoLocalPath = existing.webPagePhotoLocalPath
                }
                // A full updateEditMessage does not carry the locally derived
                // read-outbox state. Do not regress an already-read outgoing
                // bubble to "sent" merely because its reactions changed.
                if (existing.isSent && existing.status == "read") {
                    msg.status = "read"
                }
                found = true
            }
        }
        if (found) {
            // 同 id 覆盖：insert 命中「键未变则原地写」路径
            // （对齐 iOS setLowerOrAtAnchorAtArrayIndex，MessageHistoryViewState.swift:987）。
            let _ = this.history.insert(msg)
            let msgId = msg.id
            let persistPeerId = this.chatId
            let persistPeerType = this.peerType
            let persistList = ArrayList<Message>()
            persistList.add(msg)
            spawn {
                getMessageHistoryStore().storeMessages(persistPeerId, persistList, peerType: persistPeerType)
            }
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Edit push: updated message id=${msgId}")
        }
    }
    
    /**
     * Phase R5: 从 UpdatesManager 推送接收删除消息
     * 
     * 从 messageList 中移除指定 ID 的消息。
     */
    public func onDeleteMessagesPush(ids: ArrayList<Int64>): Unit {
        if (ids.isEmpty()) { return }
        
        // 逐条增量移除（对齐 iOS .Remove 操作，MessageHistoryView.swift:595）。
        // 原先「遍历整表重建 + 整表回写」的写法已删除 —— 回写正是竞态所在，
        // 且 history.remove 自带 O(1) id 索引，不需要预先构建 deleteSet。
        var deletedCount: Int64 = 0
        for (id in ids) {
            if (this.history.remove(id)) { deletedCount += 1 }
        }
        
        if (deletedCount > 0) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] Delete push: removed ${deletedCount} messages")
        }
    }

    // ==================== P2-119: Context Menu — Copy / Copy Link / Report / Save ====================

    /**
     * P2-119: 复制消息文本到系统剪贴板。
     *
     * 真实实现：通过 PasteboardUtils.copyText()（dlopen libpasteboard.so 路径），
     * 不使用内存桩 setClipboardText()。
     *
     * iOS 对应：ChatInterfaceStateContextMenus.swift:645 Conversation_ContextMenuCopy
     */
    public func copyMessageText(msgId: Int64): Unit {
        var text = ""
        for (msg in this.messageList) {
            if (msg.id == msgId) {
                text = msg.content
                break
            }
        }
        if (text.size == 0) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-119 copyMessageText: msg ${msgId} not found or empty")
            return
        }
        let ok = copyText(text)
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-119 copyMessageText: id=${msgId} ok=${ok}")
    }

    /**
     * P2-119: 导出消息链接并复制到剪贴板。
     *
     * 对于频道/超级群（peerType=="channel"）：调用 channels.exportMessageLink#e63fadeb 真实 RPC，
     * 解析响应中的 link 字符串后复制到剪贴板。
     *
     * 对于私聊/普通群：构造 t.me/c/<chatId>/<msgId> 格式链接（本地生成，无需 RPC），
     * 直接复制到剪贴板。
     *
     * iOS 对应：ChatInterfaceStateContextMenus.swift:686 Conversation_ContextMenuCopyLink
     *           → context.engine.messages.exportMessageLink(peerId:, messageId:, isThread:)
     *
     * ctor verified: python3 -c "print(hex(0xe63fadeb))" -> 0xe63fadeb
     * response: exportedMessageLink#5dab1af4 link:string html:string
     *           ctor: python3 -c "print(hex(0x5dab1af4))" -> 0x5dab1af4
     */
    public func exportMessageLink(msgId: Int64, onDone: () -> Unit): Unit {
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let msgIdI32 = Int32(msgId)
        spawn {
            var link = ""
            if (peerTypeCopy == "channel") {
                // True RPC: channels.exportMessageLink
                try {
                    let svc = getRealMessageService()
                    let client = getMTProtoClient()
                    let accessHash = svc.getAccessHashForChannel(chatIdCopy)
                    let ch = InputChannel()
                    ch.channelId = chatIdCopy
                    ch.accessHash = accessHash
                    let req = ChannelsExportMessageLink()
                    req.channel = ch
                    req.id = msgIdI32
                    let respBytes = client.sendRequest(req.toBytes())
                    if (respBytes.size >= 8) {
                        let d = TLDeserializer(respBytes)
                        let ctor = d.readUInt32()
                        // exportedMessageLink#5dab1af4 link:string html:string
                        if (ctor == 0x5dab1af4u32) {
                            link = d.readString()
                            Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-119 exportMessageLink: ${link}")
                        } else {
                            Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-119 exportMessageLink: unexpected ctor 0x${ctor}")
                        }
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-119 exportMessageLink RPC error: ${e}")
                }
                // Fallback link if RPC failed
                if (link.size == 0) {
                    link = "https://t.me/c/${chatIdCopy}/${msgId}"
                }
            } else {
                // Non-channel: build t.me/c/<chatId>/<msgId> fallback (no public link for private chats)
                link = "https://t.me/c/${chatIdCopy}/${msgId}"
            }
            if (link.size > 0) {
                let ok = copyText(link)
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-119 exportMessageLink copied=${ok} link=${link}")
            }
            launch { onDone() }
        }
    }

    /**
     * P2-119 r1: Phase-1 举报 — 向服务端请求举报原因列表（发空 option bytes）。
     *
     * 对应 iOS ReportContent.swift:60 — _internal_reportContent(option: nil/Data())
     * → 服务端返回 reportResultChooseOption#f0e4e0b6 (title, options[]) 或
     *   reportResultReported#8db33c4b（直接成功，无需选项）。
     *
     * API: messages.report#fc78af9b peer:InputPeer id:Vector<int> option:bytes message:string
     * ctor: 0xfc78af9b — python3 -c "print(hex(0xfc78af9b))" -> 0xfc78af9b
     * option = [] (空 bytes) → 触发服务端返回选项列表
     *
     * onOptions(optionTexts): 服务端返回选项列表时回调（UI 动态渲染菜单）
     * onReported():           服务端直接返回已举报（无选项）时回调
     * onError():              请求失败时回调
     */
    public func fetchReportOptions(msgId: Int64, onOptions: (Array<String>) -> Unit, onReported: () -> Unit, onError: () -> Unit): Unit {
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let msgIdI32 = Int32(msgId)
        spawn {
            try {
                let svc = getRealMessageService()
                let client = getMTProtoClient()
                let req = MessagesReport()
                req.peer = svc.buildInputPeer(peerTypeCopy, chatIdCopy)
                req.ids.add(msgIdI32)
                req.option = Array<Byte>(0, repeat: 0)
                req.message = ""
                let respBytes = client.sendRequest(req.toBytes())
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-119 fetchReportOptions id=${msgId} resp.size=${respBytes.size}")
                let result = ReportResultResponse.deserialize(respBytes)
                if (result.kind == "choose_option") {
                    var newBytes = ArrayList<Array<Byte>>()
                    var texts = ArrayList<String>()
                    for (opt in result.chooseOptions) {
                        texts.add(opt.text)
                        newBytes.add(opt.optionBytes)
                    }
                    this._reportPendingOptionBytes = newBytes
                    let textArr = texts.toArray()
                    launch { onOptions(textArr) }
                } else if (result.kind == "reported") {
                    launch { onReported() }
                } else if (result.kind == "add_comment") {
                    // Treat add_comment like reported for now (submit with the option bytes directly)
                    var newBytes = ArrayList<Array<Byte>>()
                    newBytes.add(result.addCommentOption)
                    this._reportPendingOptionBytes = newBytes
                    launch { onReported() }
                } else {
                    launch { onError() }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-119 fetchReportOptions error: ${e}")
                launch { onError() }
            }
        }
    }

    /**
     * P2-119 r1: Phase-2 举报 — 用服务端返回的 option bytes 提交最终举报。
     *
     * optionIndex 对应 fetchReportOptions onOptions 返回的 textArr 下标。
     * option bytes 来自服务端 messageReportOption#7903e3d9 的 option:bytes 字段，
     * 不能本地伪造（服务端按此 bytes 路由举报类型）。
     *
     * iOS ref: ReportContent.swift:60 再次调用 _internal_reportContent(option: selectedOption.option)
     *
     * 服务端可能再次返回 reportResultChooseOption（多级菜单）或 reportResultReported（最终成功）。
     * 当前实现：多级菜单时继续调用 onMoreOptions；最终成功时调用 onDone。
     */
    public func submitReport(msgId: Int64, optionIndex: Int64, onDone: () -> Unit, onMoreOptions: (Array<String>) -> Unit, onError: () -> Unit): Unit {
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        let msgIdI32 = Int32(msgId)
        let pendingCopy = this._reportPendingOptionBytes
        if (optionIndex < 0 || optionIndex >= pendingCopy.size) {
            Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-119 submitReport: invalid optionIndex ${optionIndex}, pending=${pendingCopy.size}")
            launch { onError() }
            return
        }
        let optionBytes = pendingCopy[optionIndex]
        spawn {
            try {
                let svc = getRealMessageService()
                let client = getMTProtoClient()
                let req = MessagesReport()
                req.peer = svc.buildInputPeer(peerTypeCopy, chatIdCopy)
                req.ids.add(msgIdI32)
                req.option = optionBytes
                req.message = ""
                let respBytes = client.sendRequest(req.toBytes())
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-119 submitReport id=${msgId} idx=${optionIndex} resp.size=${respBytes.size}")
                let result = ReportResultResponse.deserialize(respBytes)
                if (result.kind == "reported" || result.kind == "add_comment") {
                    launch { onDone() }
                } else if (result.kind == "choose_option") {
                    // Multi-level menu: update pending options, notify UI to show next level
                    var newBytes = ArrayList<Array<Byte>>()
                    var texts = ArrayList<String>()
                    for (opt in result.chooseOptions) {
                        texts.add(opt.text)
                        newBytes.add(opt.optionBytes)
                    }
                    this._reportPendingOptionBytes = newBytes
                    let textArr = texts.toArray()
                    launch { onMoreOptions(textArr) }
                } else {
                    launch { onError() }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-119 submitReport error: ${e}")
                launch { onError() }
            }
        }
    }

    /**
     * P2-119: 保存媒体到 Saved Messages（转发到自己）。
     *
     * iOS 对应：ChatInterfaceStateContextMenus.swift:1505 saveMediaToFiles
     *           实际语义在 Telegram 中是「Save to Saved Messages」（forward to self）。
     *
     * 实现：调用 forwardMessage(msgId, "user", currentUserId)，
     * currentUserId = 当前登录用户 ID（已在 initChatRoomWithPeer 中赋值）。
     */
    public func saveToSavedMessages(msgId: Int64): Unit {
        let selfId = this.currentUserId
        Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-119 saveToSavedMessages: msg=${msgId} selfId=${selfId}")
        this.forwardMessage(msgId, "user", selfId)
    }

    // ==================== P2-120: 聊天权限加载 ====================

    /**
     * 加载聊天权限状态（慢速模式、发送限制）。
     *
     * 对于 channel / supergroup：调用 channels.getFullChannel，
     * 从 channelFull.slowmode_timeout / defaultBannedRights 解析。
     * 对于普通 chat (group)：调用 messages.getFullChat，
     * ChatFullResponse.slowmodeSeconds 已是通用字段。
     *
     * 私聊：检查 contacts.getBlocked 判断是否已屏蔽对方。
     *
     * 对应 iOS ChatPresentationInterfaceState.swift ChatSlowmodeState /
     *   CachedChannelData.slowModeTimeout / defaultBannedRights
     */
    public func loadChatPermissions(): Unit {
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        spawn {
            if (peerTypeCopy == "user") {
                // 私聊：检查是否已屏蔽对方（contacts.isBlocked 暂不支持；
                // 用 sendMessage 路径的 USER_BLOCKED error 被动感知；
                // 这里仅尝试从 RealMessageService 的缓存里读黑名单状态）
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-120 user peer, skip slowmode check")
                return
            }
            // channel / supergroup / chat：读完整信息
            try {
                let msgSvc = getRealMessageService()
                let fullInfo = msgSvc.getFullChatInfo(peerTypeCopy, chatIdCopy)
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-120 getFullChatInfo: slowmode=${fullInfo.slowmodeSeconds}")
                if (fullInfo.stickerSetId != 0) {
                    let store = getEntityKeyboardStore()
                    let token = store.currentToken()
                    let peerPack = getStickersService().getStickerSet(
                        fullInfo.stickerSetId, fullInfo.stickerSetAccessHash)
                    if (peerPack.success) {
                        store.publishPeerStickerPack(
                            token, peerTypeCopy, chatIdCopy, peerPack)
                    }
                }
                if (fullInfo.emojiSetId != 0) {
                    let store = getEntityKeyboardStore()
                    let token = store.currentToken()
                    let peerPack = getStickersService().getStickerSet(
                        fullInfo.emojiSetId, fullInfo.emojiSetAccessHash)
                    if (peerPack.success) {
                        store.publishPeerEmojiPack(
                            token, peerTypeCopy, chatIdCopy, peerPack)
                    }
                }
                let captured = fullInfo.slowmodeSeconds
                let linked = fullInfo.linkedChatId
                let capturedMembers = fullInfo.membersCount
                launch {
                    this.slowmodeTimeoutSeconds = captured
                    this.linkedChatId = linked
                    // 两路都会写副标题：loadPresenceSubtitle 带 ", N online"（超级群），这里只在尚无在线数时补成员数
                    if (capturedMembers > 0 && !this.subtitleText.contains("online")) {
                        this.subtitleText = if (peerTypeCopy == "channel") {
                            "${formatChatPeerCount(capturedMembers)} subscribers"
                        } else {
                            "${formatChatPeerCount(capturedMembers)} members"
                        }
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-120 loadChatPermissions error: ${e}")
            }
        }
    }

    /**
     * 解除对当前私聊对方的屏蔽（contacts.unblock）。
     *
     * 对应 iOS ChatController「Unblock」按钮动作:
     *   context.engine.privacy.requestUpdatePeerIsBlocked(peerId, isBlocked: false)
     *
     * 成功后将 hasBlockedPeer 置 false，恢复输入框。
     */
    public func unblockPeer(): Unit {
        let chatIdCopy = this.chatId
        let peerTypeCopy = this.peerType
        spawn {
            try {
                let msgSvc = getRealMessageService()
                let accessHash = msgSvc.getAccessHashForUser(chatIdCopy)
                let req = ContactsUnblock()
                if (peerTypeCopy == "user") {
                    let peer = InputPeerUser()
                    peer.userId = chatIdCopy
                    peer.accessHash = accessHash
                    req.id = peer
                } else {
                    let peer = InputPeerEmpty()
                    req.id = peer
                }
                let mtproto = getMTProtoClient()
                let respData = mtproto.sendRequest(req.toBytes())
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-120 unblockPeer resp size=${respData.size}")
                launch {
                    this.hasBlockedPeer = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomVM] P2-120 unblockPeer error: ${e}")
            }
        }
    }
}

// formatMessageTime() 和 getNameInitials() 已移至 services/RealMessageService.cj
// viewmodels 通过 import ohos_app_cangjie_entry.services.* 自动可用

/**
 * P2-356: 读取粘贴板媒体文件字节（供 sendPasteboardMediaItems 使用）
 *
 * 逻辑同 ChatRoomPage.readFileBytes，在 viewmodel 侧复用 CoreFileKit.FileIo
 * （kit.CoreFileKit.* 已在 ChatRoomViewModel.cj 顶部 import）。
 *
 * @param filePath 本地文件路径（去除 file:// 前缀后的绝对路径）
 * @return 文件字节数组；读取失败时返回空数组（不崩）
 */
func readPasteboardFileBytes(filePath: String): Array<Byte> {
    if (filePath.size == 0) {
        return Array<Byte>(0, repeat: 0)
    }
    try {
        let file = FileIo.open(filePath, mode: 0o0)
        let stat = FileIo.stat(filePath)
        let fileSize = stat.size
        if (fileSize <= 0) {
            FileIo.close(file)
            return Array<Byte>(0, repeat: 0)
        }
        let buffer = Array<Byte>(fileSize, repeat: 0)
        let bytesRead = FileIo.read(file.fd, buffer)
        FileIo.close(file)
        return buffer
    } catch (e: Exception) {
        return Array<Byte>(0, repeat: 0)
    }
}

/**
 * 发送失败 → 用户可读提示（对齐 iOS PendingMessageManager.swift:90-110
 * sendMessageReasonForError 的错误分类 + ChatControllerLoadDisplayNode.swift:5244+ 的文案）。
 * 未识别的错误码也要给出兜底文案——静默失败是最差体验（实测 PEER_FLOOD 被吞）。
 */
public func sendFailureAlertText(errorMessage: String): String {
    let e = errorMessage
    if (e.startsWith("PEER_FLOOD")) {
        return "Sorry, you can only send messages to mutual contacts at the moment."
    }
    if (e.startsWith("SENDING_TOO_FAST")) {
        return "Sending messages too fast. Please wait a moment and try again."
    }
    if (e.startsWith("USER_BANNED_IN_CHANNEL")) {
        return "You can't send messages in this group."
    }
    if (e.startsWith("SLOWMODE_WAIT")) {
        return "Slow mode is enabled. Please wait before sending another message."
    }
    if (e.startsWith("CHAT_SEND_") && e.endsWith("_FORBIDDEN")) {
        return "Sending this type of content isn't allowed here."
    }
    if (e.startsWith("VOICE_MESSAGES_FORBIDDEN")) {
        return "This user doesn't accept voice messages."
    }
    if (e.startsWith("PRIVACY_PREMIUM_REQUIRED")) {
        return "Only Premium subscribers can message this user."
    }
    if (e.startsWith("SCHEDULE_TOO_MUCH")) {
        return "Too many scheduled messages."
    }
    if (e.startsWith("USER_IS_BLOCKED")) {
        return "You can't send messages to this user."
    }
    if (e.startsWith("FLOOD_WAIT")) {
        return "Too many requests. Please try again later."
    }
    return "Message not sent: ${e}"
}

/** 把仓颉异常的调用栈逐帧写进 hilog（e.toString() 只有消息，没有栈）。 */
func logExceptionStack(tag: String, e: Exception): Unit {
    var n = 0
    for (frame in e.getStackTrace()) {
        if (n >= 14) { break }
        Hilog.info(0, "CjTelegram", "${tag} stack#${n}: ${frame.declaringClass}.${frame.methodName} (${frame.fileName}:${frame.lineNumber})")
        n = n + 1
    }
}
