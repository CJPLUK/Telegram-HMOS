package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.ChatResponse
import ohos_app_cangjie_entry.models.{Chat, ChatFolder, PeerKey}
import std.collection.ArrayList
import std.collection.HashMap
import std.collection.HashSet
import std.sync.Monitor
import std.time.DateTime

/**
 * ChatList 的账号级响应式投影出口。
 *
 * 初始/用户操作快照由 ViewModel 发布；账号级实时提交直接在本类应用并持久化，
 * 不再要求 Chats 页面或 ViewModel 已经创建。页面只订阅快照，不拥有更新处理器。
 * 发布时复制 ArrayList 容器，调用订阅者时不持锁，单个订阅者异常不会截断其他订阅者。
 */
public class ChatListProjectionSnapshot {
    public let generation: Int64
    public let chats: ArrayList<Chat>
    public let isLoading: Bool
    public let dialogFilters: ArrayList<ChatFolder>
    public let connectionStatus: String
    public let hasActiveProxy: Bool
    public let reason: String
    public let publishedAtMs: Int64

    public init(generation: Int64, chats: ArrayList<Chat>, isLoading: Bool,
        dialogFilters: ArrayList<ChatFolder>, connectionStatus: String,
        hasActiveProxy: Bool, reason: String, publishedAtMs: Int64) {
        this.generation = generation
        this.chats = chats
        this.isLoading = isLoading
        this.dialogFilters = dialogFilters
        this.connectionStatus = connectionStatus
        this.hasActiveProxy = hasActiveProxy
        this.reason = reason
        this.publishedAtMs = publishedAtMs
    }
}

private var _chatListProjectionInstance: Option<ChatListProjection> = None
private let _chatListProjectionInstanceMonitor = Monitor()

public func getChatListProjection(): ChatListProjection {
    return synchronized(_chatListProjectionInstanceMonitor) {
        match (_chatListProjectionInstance) {
            case Some(instance) => instance
            case None =>
                let instance = ChatListProjection()
                _chatListProjectionInstance = Some(instance)
                instance
        }
    }
}

public class ChatListProjection {
    private let _monitor = Monitor()
    private var _generation: Int64 = 0
    private var _nextSubscriberToken: Int64 = 1
    private var _chats = ArrayList<Chat>()
    private var _isLoading: Bool = true
    private var _dialogFilters = ArrayList<ChatFolder>()
    // 标题状态的两个独立输入，对位 iOS Account.swift:1329 combineLatest(stateManager.isUpdating,
    // network.connectionStatus)：transport 连通性来自 MTProto 连接事件 / VM 的初始探测；
    // "updating" 不是 transport 状态，而是 getDifference / getState 在途计数（AccountStateManager
    // .currentIsUpdatingValue，pollDifference 开始置 true、完成置 false）。快照里的
    // connectionStatus 永远由二者当场派生，不再保存任何调用方传入的 "updating" 快照值——
    // 旧实现把 VM 首屏 isLoading 折算成 "updating" 存进来，之后 isLoading 变回 false 时没有
    // 任何路径重算，账号切换后（新 client 在页面重建前就已连上，不会再来一次 Connected
    // 事件）标题永远停在 "Updating..."。
    private var _transportStatus: String = "online"
    private var _updatingDepth: Int64 = 0
    private var _hasActiveProxy: Bool = false
    private var _subscribers = HashMap<Int64, (ChatListProjectionSnapshot) -> Unit>()
    // 正在按 id 补拉实体（messages.getChats）的基础群，避免同一 peer 的连续消息重复请求。
    private var _pendingChatEntityFetch = HashSet<Int64>()
    // 当前投影所属的账号 slot（-1 = 尚未经历账号切换，沿用启动时的活跃账号）。
    private var _ownerSlot: Int32 = -1

    /** 当前投影所属账号 slot；-1 表示进程内尚未切换过账号。 */
    public func ownerSlot(): Int32 {
        return synchronized(this._monitor) { this._ownerSlot }
    }

    /**
     * 账号切换：在旧 client 断开、activeSlot 已指向新账号后同步调用，把投影整体归零并
     * 标记新 owner。对位 iOS 切账号时旧 AccountContext 连同其 ChatList view 整体释放、
     * 新账号从空 Postbox 视图重建。此后任何来自上一账号的迟到发布（旧 VM 在途加载、
     * 旧 client 残余 updates）都由各自入口按 slot 拒绝，不再进入本投影。
     */
    public func resetForAccountSwitch(slot: Int32): Unit {
        var snapshot: ChatListProjectionSnapshot
        synchronized(this._monitor) {
            this._generation += 1
            this._chats = ArrayList<Chat>()
            this._isLoading = true
            this._dialogFilters = ArrayList<ChatFolder>()
            this._updatingDepth = 0
            this._ownerSlot = slot
            snapshot = ChatListProjectionSnapshot(
                this._generation,
                ArrayList<Chat>(),
                this._isLoading,
                ArrayList<ChatFolder>(),
                this.derivedConnectionStatusLocked(),
                this._hasActiveProxy,
                "accountSwitch",
                DateTime.now().toUnixTimeStamp().toMilliseconds()
            )
        }
        let subscribers = this.subscriberSnapshot()
        var index: Int64 = 0
        while (index < subscribers.size) {
            try { subscribers[index](snapshot) } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListProjection] subscriber=${index} failed generation=${snapshot.generation}: ${e}")
            }
            index += 1
        }
        Hilog.info(0, "CjTelegram",
            "[ChatListProjection] reset for account switch → slot=${slot}, generation=${snapshot.generation}")
    }

    /** 调用方必须持有 _monitor。transport 离线时 connecting/waiting 优先于 updating。 */
    private func derivedConnectionStatusLocked(): String {
        if (this._transportStatus == "online" && this._updatingDepth > 0) { return "updating" }
        return this._transportStatus
    }

    /** VM 回灌的是派生值，可能带 "updating"；transport 层只记录 online/connecting/waiting。 */
    private func transportStatusOf(status: String): String {
        if (status == "updating") { return "online" }
        return status
    }

    /** App 启动即恢复本地列表，使后台消息到达时也有完整的投影基线。 */
    public func bootstrapFromStore(): Unit {
        let local = getChatListStore().loadLocalChats(0)
        if (!local.isEmpty()) {
            this.publish(local, false, ArrayList<ChatFolder>(), "online", false, "storeBootstrap")
        }
    }

    private func findChat(chats: ArrayList<Chat>, peerKey: PeerKey): Option<Chat> {
        for (chat in chats) {
            if (PeerKey.fromPeerType(chat.peerType, chat.id).equals(peerKey)) {
                return Some(chat)
            }
        }
        return None
    }

    /** 从已提交消息派生会话行；正常消息路径不触发 getDialogs。 */
    public func applyCommittedMessage(peerType: String, peerId: Int64, preview: String, messageType: String,
        date: Int64, outgoing: Bool, countAsUnread: Bool): Unit {
        if (peerId == 0) { return }
        let current = this.currentSnapshot()
        let peerKey = PeerKey.fromPeerType(peerType, peerId)
        match (this.findChat(current.chats, peerKey)) {
            case Some(chat) =>
                chat.lastMessage = preview
                chat.lastMessageType = messageType
                chat.lastMessageTimestamp = date
                chat.time = formatTimestamp(date)
                chat.lastMessageOutgoing = outgoing
                if (countAsUnread) {
                    chat.unreadCount += 1
                    chat.lastMessageRead = false
                }
            case None =>
                // iOS removePeerChat 把会话置为 chat list notIncluded：退群 / 删除后到达的
                // 服务消息（"X left the group"）只写历史，不会把会话重新放回列表。
                if (getRealChatListService().isDialogLocallyRemoved(peerKey.toPeerType(), peerId)) {
                    Hilog.info(0, "CjTelegram",
                        "[ChatListProjection] skip committed message for removed dialog ${peerKey.toPeerType()}/${peerId}")
                    return
                }
                let chat = Chat()
                chat.id = peerId
                chat.peerType = peerKey.toPeerType()
                chat.lastMessage = preview
                chat.lastMessageType = messageType
                chat.lastMessageTimestamp = date
                chat.time = formatTimestamp(date)
                chat.lastMessageOutgoing = outgoing
                chat.lastMessageRead = !countAsUnread
                chat.unreadCount = if (countAsUnread) { 1 } else { 0 }
                chat.isGroup = peerKey.namespace == PeerKey.BASIC_GROUP
                chat.isChannel = peerKey.namespace == PeerKey.CHANNEL
                match (getPeerStore().getLocalPeer(peerId, peerType: peerKey.toPeerType())) {
                    case Some(peer) =>
                        chat.name = peer.name
                        chat.avatarText = peer.avatarText
                        chat.avatarLocalPath = peer.avatarLocalPath
                        chat.username = peer.username
                    case None =>
                        chat.name = if (peerKey.namespace == PeerKey.USER) { "User ${peerId}" } else { "Chat ${peerId}" }
                        chat.avatarText = if (peerKey.namespace == PeerKey.USER) { "U" } else { "C" }
                        // 本地没有该群实体（例如实体随 Updates.chats 到达但未被消费）：
                        // 先用占位名出行，异步 messages.getChats 补拉，拿到后刷新标题并回写缓存。
                        this.requestMissingChatEntity(peerKey, peerId)
                }
                current.chats.add(chat)
        }
        let sorted = sortChatList(current.chats)
        this.publish(sorted, current.isLoading, current.dialogFilters,
            current.connectionStatus, current.hasActiveProxy, "incomingCommitted")
        getChatListStore().storeChats(sorted)
    }

    /**
     * 基础群实体缺失时按 id 补拉（messages.getChats）。频道需要 access_hash，走 getDifference /
     * getDialogs 的 chats 向量回源，这里不处理。同一 peer 在途时不重复请求。
     */
    private func requestMissingChatEntity(peerKey: PeerKey, peerId: Int64): Unit {
        if (peerKey.namespace != PeerKey.BASIC_GROUP) { return }
        let shouldFetch = synchronized(this._monitor) {
            if (this._pendingChatEntityFetch.contains(peerId)) {
                false
            } else {
                this._pendingChatEntityFetch.add(peerId)
                true
            }
        }
        if (!shouldFetch) { return }
        spawn {
            try {
                let ids = ArrayList<Int64>()
                ids.add(peerId)
                let fetched = getRealChatListService().fetchLegacyChats(ids)
                for (entity in fetched) {
                    if (entity.id == peerId && entity.title.size > 0) {
                        this.applyResolvedChatEntity(peerKey, entity)
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListProjection] fetch chat entity ${peerId} failed: ${e}")
            }
            synchronized(this._monitor) { this._pendingChatEntityFetch.remove(peerId) }
        }
    }

    /** 补拉到实体后只改该行的标题类字段，其余字段与顺序保持当前快照。 */
    private func applyResolvedChatEntity(peerKey: PeerKey, entity: ChatResponse): Unit {
        let current = this.currentSnapshot()
        match (this.findChat(current.chats, peerKey)) {
            case Some(chat) =>
                chat.name = entity.title
                chat.avatarText = entity.title.toRuneArray()[0].toString()
                chat.username = entity.username
                chat.participantsCount = Int64(entity.participantsCount)
                chat.avatarLocalPath = getUserPhotoService().getChatPhotoPath(entity.id)
                Hilog.info(0, "CjTelegram",
                    "[ChatListProjection] resolved chat entity ${peerKey.toPeerType()}/${entity.id} -> '${entity.title}'")
                this.publish(current.chats, current.isLoading, current.dialogFilters,
                    current.connectionStatus, current.hasActiveProxy, "chatEntityResolved")
                getChatListStore().storeChats(current.chats)
            case None => ()
        }
    }

    /** 服务端权威已读数直接覆盖投影，不做本地猜测。 */
    public func applyIncomingRead(peerType: String, peerId: Int64, stillUnread: Int64): Unit {
        let current = this.currentSnapshot()
        match (this.findChat(current.chats, PeerKey.fromPeerType(peerType, peerId))) {
            case Some(chat) =>
                chat.unreadCount = stillUnread
                if (stillUnread == 0) { chat.lastMessageRead = true }
                this.publish(current.chats, current.isLoading, current.dialogFilters,
                    current.connectionStatus, current.hasActiveProxy, "readCommitted")
                // 打开会话时在 UI 线程调用；落盘走后台（快照已拷贝）。
                getChatListStore().storeChatsAsync(current.chats)
            case None => ()
        }
    }

    public func applyDialogUpdate(updateType: String, peerType: String, peerId: Int64,
        value: Bool): Unit {
        let current = this.currentSnapshot()
        match (this.findChat(current.chats, PeerKey.fromPeerType(peerType, peerId))) {
            case Some(chat) =>
                if (updateType == "pin") {
                    chat.isPinned = value
                } else if (updateType == "unread") {
                    // M-2d：value=true 只置 isMarkedUnread 位，不改 unreadCount（对位
                    // applyInteractiveMarkUnread，MessageHistoryReadStateTable.swift:438-455）；
                    // value=false 清除 unreadCount 与 isMarkedUnread（对位已读推进边界
                    // markedUnread:false，MessageHistoryReadStateTable.swift:289/330）。
                    chat.isMarkedUnread = value
                    if (!value && chat.unreadCount > 0) { chat.unreadCount = 0 }
                } else if (updateType == "mute") {
                    chat.isMuted = value
                }
                let sorted = sortChatList(current.chats)
                this.publish(sorted, current.isLoading, current.dialogFilters,
                    current.connectionStatus, current.hasActiveProxy, "dialogCommitted")
                getChatListStore().storeChats(sorted)
            case None => ()
        }
    }

    /** MTProto transport 事件直接驱动标题状态，替代已删除的列表轮询。 */
    public func applyConnectionStatus(status: String): Unit {
        let transport = this.transportStatusOf(status)
        var changed = false
        synchronized(this._monitor) {
            if (this._transportStatus != transport) {
                this._transportStatus = transport
                changed = true
            }
        }
        if (changed) { this.republish("connectionEvent") }
    }

    /**
     * 一次 getDifference / getState 同步开始（iOS AccountStateManager.swift:810
     * pollDifference → currentIsUpdatingValue = true）。允许并发在途，按计数派生。
     */
    public func beginUpdating(): Unit {
        var before = ""
        var after = ""
        synchronized(this._monitor) {
            before = this.derivedConnectionStatusLocked()
            this._updatingDepth += 1
            after = this.derivedConnectionStatusLocked()
        }
        if (before != after) { this.republish("updatingBegan") }
    }

    /** 同步结束（AccountStateManager.swift:784/793 currentIsUpdatingValue = false）。 */
    public func endUpdating(): Unit {
        var before = ""
        var after = ""
        synchronized(this._monitor) {
            before = this.derivedConnectionStatusLocked()
            if (this._updatingDepth > 0) { this._updatingDepth -= 1 }
            after = this.derivedConnectionStatusLocked()
        }
        if (before != after) { this.republish("updatingEnded") }
    }

    /** 列表内容不变、仅派生状态变化时整体重发一次快照。 */
    private func republish(reason: String): Unit {
        let current = this.currentSnapshot()
        this.publish(current.chats, current.isLoading, current.dialogFilters,
            current.connectionStatus, current.hasActiveProxy, reason)
    }

    private func copyChats(source: ArrayList<Chat>): ArrayList<Chat> {
        let result = ArrayList<Chat>()
        for (chat in source) { result.add(chat.copy()) }
        return result
    }

    private func copyFilters(source: ArrayList<ChatFolder>): ArrayList<ChatFolder> {
        let result = ArrayList<ChatFolder>()
        for (filter in source) { result.add(filter.copy()) }
        return result
    }

    private func subscriberSnapshot(): ArrayList<(ChatListProjectionSnapshot) -> Unit> {
        return synchronized(this._monitor) {
            let result = ArrayList<(ChatListProjectionSnapshot) -> Unit>()
            for ((_, subscriber) in this._subscribers) { result.add(subscriber) }
            result
        }
    }

    public func currentSnapshot(): ChatListProjectionSnapshot {
        return synchronized(this._monitor) {
            ChatListProjectionSnapshot(
                this._generation,
                this.copyChats(this._chats),
                this._isLoading,
                this.copyFilters(this._dialogFilters),
                this.derivedConnectionStatusLocked(),
                this._hasActiveProxy,
                "current",
                DateTime.now().toUnixTimeStamp().toMilliseconds()
            )
        }
    }

    public func addSubscriber(subscriber: (ChatListProjectionSnapshot) -> Unit): Int64 {
        var token: Int64 = 0
        var initial: ChatListProjectionSnapshot
        synchronized(this._monitor) {
            token = this._nextSubscriberToken
            this._nextSubscriberToken += 1
            this._subscribers[token] = subscriber
            initial = ChatListProjectionSnapshot(
                this._generation,
                this.copyChats(this._chats),
                this._isLoading,
                this.copyFilters(this._dialogFilters),
                this.derivedConnectionStatusLocked(),
                this._hasActiveProxy,
                "subscribe",
                DateTime.now().toUnixTimeStamp().toMilliseconds()
            )
        }
        try { subscriber(initial) } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatListProjection] initial subscriber failed token=${token}: ${e}")
        }
        return token
    }

    public func removeSubscriber(token: Int64): Unit {
        synchronized(this._monitor) { this._subscribers.remove(token) }
    }

    public func publish(chats: ArrayList<Chat>, isLoading: Bool,
        dialogFilters: ArrayList<ChatFolder>, connectionStatus: String,
        hasActiveProxy: Bool, reason: String): Unit {
        var snapshot: ChatListProjectionSnapshot
        synchronized(this._monitor) {
            this._generation += 1
            this._chats = this.copyChats(chats)
            this._isLoading = isLoading
            this._dialogFilters = this.copyFilters(dialogFilters)
            this._transportStatus = this.transportStatusOf(connectionStatus)
            this._hasActiveProxy = hasActiveProxy
            snapshot = ChatListProjectionSnapshot(
                this._generation,
                this.copyChats(this._chats),
                this._isLoading,
                this.copyFilters(this._dialogFilters),
                this.derivedConnectionStatusLocked(),
                this._hasActiveProxy,
                reason,
                DateTime.now().toUnixTimeStamp().toMilliseconds()
            )
        }

        let subscribers = this.subscriberSnapshot()
        var index: Int64 = 0
        while (index < subscribers.size) {
            try { subscribers[index](snapshot) } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListProjection] subscriber=${index} failed generation=${snapshot.generation}: ${e}")
            }
            index += 1
        }
        Hilog.info(0, "CjTelegram",
            "[ChatListProjection] publish generation=${snapshot.generation}, chats=${snapshot.chats.size}, reason=${reason}")
    }
}
