package ohos_app_cangjie_entry.services

import std.time.DateTime
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.models.Message
import std.collection.ArrayList
import std.collection.HashMap
import std.sync.{AtomicBool, Monitor}

/**
 * Phase R3: 更新管理器 — 中央调度服务
 * 
 * 职责:
 * 1. 接收 MTProtoClient 推送的 raw updates
 * 2. 按 constructor ID 分类识别更新类型
 * 3. 维护 seq/pts/qts 状态机
 * 4. 检测 gap 并自动触发 getDifference 补差
 * 5. 分发更新到各处理器 (CallService, ChatList, ChatRoom 等)
 * 
 * 对应 Telegram-iOS AccountStateManager + AccountStateSynchronizer
 */

// ==================== 更新类型分类 ====================

/**
 * 更新分类结果
 */
public class ClassifiedUpdate {
    public var updateType: String = "unknown"  // newMessage, deleteMessages, editMessage, readInbox, readOutbox, phoneCall, typing, other
    public var rawData: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var pts: Int32 = 0
    public var ptsCount: Int32 = 0
    public var seq: Int32 = 0
    public var seqStart: Int32 = 0
    public var date: Int32 = 0
    
    public init() {}
}

// ==================== 单例 ====================

private var _updatesManagerInstance: Option<UpdatesManager> = None

public func getUpdatesManager(): UpdatesManager {
    match (_updatesManagerInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = UpdatesManager()
            _updatesManagerInstance = Some(inst)
            return inst
    }
}

public class UpdatesManager {
    // 已知的同步状态
    private var currentPts: Int32 = 0
    private var lastDifferenceSyncMs: Int64 = 0
    private var currentQts: Int32 = 0
    private var currentDate: Int32 = 0
    private var currentSeq: Int32 = 0
    
    // 状态是否已初始化
    private var stateInitialized: Bool = false
    
    // 外部处理器回调
    // 通话更新订阅者。CallService 不再拥有 MTProtoClient 全局 callback，只订阅
    // UpdatesManager 已分类到通话域的事件；token 允许未来并存通话记录/诊断消费者。
    private let _subscriberMonitor = Monitor()
    private var _nextSubscriberToken: Int64 = 1
    private var _callSubscribers = HashMap<Int64, (Array<Byte>) -> Unit>()
    private var _chatListRefreshSubscribers = HashMap<Int64, () -> Unit>()
    private var _chatRoomPushSubscribers = HashMap<Int64, (Message) -> Unit>()
    private var _chatRoomEditSubscribers = HashMap<Int64, (Message) -> Unit>()
    private var _chatRoomDeleteSubscribers = HashMap<Int64, (ArrayList<Int64>) -> Unit>()
    private var _chatRoomReactionSubscribers = HashMap<Int64, (Int64, Int64, ArrayList<TLReactionCount>) -> Unit>()
    private var _readInboxSubscribers = HashMap<Int64, (String, Int64, Int32, Int32) -> Unit>()
    private var _readOutboxSubscribers = HashMap<Int64, (String, Int64, Int32) -> Unit>()
    private var _typingSubscribers = HashMap<Int64, (Int64) -> Unit>()
    private var _emojiInteractionSubscribers = HashMap<Int64, (Int64, String, Int64, String) -> Unit>()
    private var _userStatusSubscribers = HashMap<Int64, (Int64, Bool) -> Unit>()
    private var _committedMessageIds = HashMap<String, Bool>()
    private var _committedMessageIdCount: Int64 = 0
    // 频道 / 超级群的 pts 按频道独立编号（iOS AccountStateManagementUtils channelStates），
    // 与账号级 currentPts 不是同一序列，不能走 checkAndUpdatePts。
    private var _channelPts = HashMap<Int64, Int32>()

    // ==================== B3-1: 会话列表「带数据」推送 ====================
    //
    // 原实现中新消息到达时数据已在手 —— dispatchNewMessages 已解析出完整 Message、
    // handleUpdateShortMessage / handleUpdateShortChatMessage 已读出 userId/message/date ——
    // 却只发无数据的 notifyChatListRefresh()，迫使会话列表回源重拉全量 getDialogs
    // （真机实测每次 3452 字节）。
    //
    // 对齐 iOS：AccountStateManagementUtils → Postbox.addMessages →
    // ChatListTable.replay(historyOperationsByPeerId:) 从消息历史**派生**列表条目，
    // 绝不为单条消息重拉列表。仓颉侧 Chat.lastMessage 是反范式字段、无派生层，
    // 故以「直接更新 Chat 字段」等效实现。
    //
    // 参数取不可变值而非对象引用：回调在 MTProto 接收线程触发，接收方必须在 UI 线程
    // 应用（仓颉无隐式线程安全、ArrayList 非线程安全，见 KB《同步机制》），
    // 传值可杜绝跨线程共享可变状态。
    //
    // TODO(B3-1-followup): 编辑 / 删除消息尚未本地应用，仍走「信号 → 回源」路径。
    //   前置条件与补齐步骤见 docs/future_develop.md。
    //   摘要：编辑需先给 Chat 增加 lastMessageId（否则无法判断被编辑的是否为列表显示那条）；
    //        删除结构性做不到（本地无消息历史，取不到"上一条"），需启用 MessageHistoryTable
    //        或改为单会话定向回源。
    // 已读回执推送。stillUnread 是服务端下发的**权威**剩余未读数，非本地推算，故零漂移。
    // Phase R4: ChatRoom 新消息推送
    // Phase R5: ChatRoom 编辑/删除推送
    // updateMessageReactions(peerId, msgId, reactions) — existing-message delta
    // Phase R6: 已读状态推送
    // Phase R7: 输入指示推送
    // Interactive emoji: (userId, emoticon, cloud message id, interaction JSON)
    // Phase R8: 在线状态推送
    // Phase P5-15: 对话状态更新推送（pin/unread/mute）
    // callback(updateType, peerId, value): updateType="pin"|"unread"|"mute", value=true/false
    
    // Gap 计数器
    private var gapCount: Int32 = 0

    // getDifference 单飞守卫：同一时刻只允许一个同步在跑。
    //
    // 【为什么需要】triggerDifferenceSync 内部 fetchDifference → sendRequest 是
    // 阻塞式 RPC，而它的全部触发点都在 MTProto **接收线程** 上
    // （handleRawUpdate 的 updatesTooLong、checkAndUpdatePts 的 PTS 缺口，
    //  后者又由 handleUpdateShortMessage / handleUpdateShortChatMessage / handleUpdates 调用）。
    // codegraph 调用图证实这是自我死锁：
    //     fetchDifference → sendRequest            ← 阻塞等响应
    //     processMessage  → handleRPCResult        ← 投递响应的正是同一条接收线程
    //     handleDecryptedMessage → processMessage
    // 真机实测：updateShortMessage 到达后整整 60.02 秒（REQUEST_TIMEOUT）才继续，
    // 期间所有更新排队，解除后贴纸等在 0.1 秒内涌出。
    //
    // 【对齐 iOS】AccountStateManager 用独立 Queue + 操作队列 +
    // `guard !operation.isRunning`（AccountStateManager.swift:798-803）+ Signal 异步执行，
    // pollDifference 从不在网络读取线程上跑。此处以 spawn + CAS 等价实现。
    private let _diffInFlight = AtomicBool(false)
    private let _diffRequestedWhileInFlight = AtomicBool(false)
    
    /**
     * 初始化：从 AuthStorage 加载同步状态
     */
    public func initialize(): Unit {
        let storage = getAuthStorage()
        if (storage.hasSyncState()) {
            let (pts, qts, date, seq) = storage.getSyncState()
            this.currentPts = pts
            this.currentQts = qts
            this.currentDate = date
            this.currentSeq = seq
            this.stateInitialized = true
            Hilog.info(0, "CjTelegram", "[UpdatesManager] Initialized from storage: pts=${pts}, qts=${qts}, date=${date}, seq=${seq}")
        } else {
            // 活跃账号无游标（首次登录 / 刚切到从未同步过的账号）：不得沿用上一账号的
            // 内存 pts，否则第一条实时 update 就被当成缺口或重复。
            this.currentPts = 0
            this.currentQts = 0
            this.currentDate = 0
            this.currentSeq = 0
            this.stateInitialized = false
            Hilog.info(0, "CjTelegram", "[UpdatesManager] No stored sync state, will initialize on first getState")
        }
    }

    /**
     * 账号切换：丢弃上一账号的账号级 / 频道级 pts、去重表与补差节流，再按新账号游标
     * 重新初始化。由 AccountManagerService 在 activeSlot 切换后同步调用。
     */
    public func resetForAccountSwitch(): Unit {
        synchronized(this._subscriberMonitor) {
            this._channelPts = HashMap<Int64, Int32>()
            this._committedMessageIds = HashMap<String, Bool>()
            this._committedMessageIdCount = 0
        }
        this.lastDifferenceSyncMs = 0
        this.gapCount = 0
        this.initialize()
        Hilog.info(0, "CjTelegram", "[UpdatesManager] reset for account switch: pts=${this.currentPts}, initialized=${this.stateInitialized}")
    }
    
    /**
     * 更新同步状态 (由 R1 的 fetchAndStoreSyncState 或 R2 的 fetchDifference 调用后设置)
     */
    public func updateState(pts: Int32, qts: Int32, date: Int32, seq: Int32): Unit {
        this.currentPts = pts
        this.currentQts = qts
        this.currentDate = date
        this.currentSeq = seq
        this.stateInitialized = true
        
        // 同步写入 AuthStorage
        let storage = getAuthStorage()
        storage.saveSyncState(pts, qts, date, seq)
    }
    
    // ==================== 处理器注册 ====================

    private func nextSubscriberTokenLocked(): Int64 {
        let token = this._nextSubscriberToken
        this._nextSubscriberToken += 1
        return token
    }

    /** 同一 MessageId 只允许驱动一次 read state / Projection / notification。 */
    private func markFirstCommittedMessage(peerType: String, peerId: Int64, messageId: Int64): Bool {
        let key = "${normalizeDialogPeerType(peerType)}:${peerId}:${messageId}"
        return synchronized(this._subscriberMonitor) {
            if (this._committedMessageIds.contains(key)) { return false }
            if (this._committedMessageIdCount >= 4096) {
                this._committedMessageIds = HashMap<String, Bool>()
                this._committedMessageIdCount = 0
            }
            this._committedMessageIds[key] = true
            this._committedMessageIdCount += 1
            true
        }
    }

    private func callSubscriberSnapshot(): ArrayList<(Array<Byte>) -> Unit> { return synchronized(this._subscriberMonitor) { let r = ArrayList<(Array<Byte>) -> Unit>(); for ((_, h) in this._callSubscribers) { r.add(h) }; r } }
    private func chatListRefreshSubscriberSnapshot(): ArrayList<() -> Unit> { return synchronized(this._subscriberMonitor) { let r = ArrayList<() -> Unit>(); for ((_, h) in this._chatListRefreshSubscribers) { r.add(h) }; r } }
    private func chatRoomPushSubscriberSnapshot(): ArrayList<(Message) -> Unit> { return synchronized(this._subscriberMonitor) { let r = ArrayList<(Message) -> Unit>(); for ((_, h) in this._chatRoomPushSubscribers) { r.add(h) }; r } }
    private func chatRoomEditSubscriberSnapshot(): ArrayList<(Message) -> Unit> { return synchronized(this._subscriberMonitor) { let r = ArrayList<(Message) -> Unit>(); for ((_, h) in this._chatRoomEditSubscribers) { r.add(h) }; r } }
    private func chatRoomDeleteSubscriberSnapshot(): ArrayList<(ArrayList<Int64>) -> Unit> { return synchronized(this._subscriberMonitor) { let r = ArrayList<(ArrayList<Int64>) -> Unit>(); for ((_, h) in this._chatRoomDeleteSubscribers) { r.add(h) }; r } }
    private func chatRoomReactionSubscriberSnapshot(): ArrayList<(Int64, Int64, ArrayList<TLReactionCount>) -> Unit> { return synchronized(this._subscriberMonitor) { let r = ArrayList<(Int64, Int64, ArrayList<TLReactionCount>) -> Unit>(); for ((_, h) in this._chatRoomReactionSubscribers) { r.add(h) }; r } }
    private func readInboxSubscriberSnapshot(): ArrayList<(String, Int64, Int32, Int32) -> Unit> { return synchronized(this._subscriberMonitor) { let r = ArrayList<(String, Int64, Int32, Int32) -> Unit>(); for ((_, h) in this._readInboxSubscribers) { r.add(h) }; r } }
    private func readOutboxSubscriberSnapshot(): ArrayList<(String, Int64, Int32) -> Unit> { return synchronized(this._subscriberMonitor) { let r = ArrayList<(String, Int64, Int32) -> Unit>(); for ((_, h) in this._readOutboxSubscribers) { r.add(h) }; r } }
    private func typingSubscriberSnapshot(): ArrayList<(Int64) -> Unit> { return synchronized(this._subscriberMonitor) { let r = ArrayList<(Int64) -> Unit>(); for ((_, h) in this._typingSubscribers) { r.add(h) }; r } }
    private func emojiInteractionSubscriberSnapshot(): ArrayList<(Int64, String, Int64, String) -> Unit> { return synchronized(this._subscriberMonitor) { let r = ArrayList<(Int64, String, Int64, String) -> Unit>(); for ((_, h) in this._emojiInteractionSubscribers) { r.add(h) }; r } }
    private func userStatusSubscriberSnapshot(): ArrayList<(Int64, Bool) -> Unit> { return synchronized(this._subscriberMonitor) { let r = ArrayList<(Int64, Bool) -> Unit>(); for ((_, h) in this._userStatusSubscribers) { r.add(h) }; r } }
    
    /**
     * 注册通话更新处理器 (CallService)
     */
    public func addCallUpdateSubscriber(handler: (Array<Byte>) -> Unit): Int64 {
        return synchronized(this._subscriberMonitor) { let token = this.nextSubscriberTokenLocked(); this._callSubscribers[token] = handler; token }
    }

    public func removeCallUpdateSubscriber(token: Int64): Unit {
        synchronized(this._subscriberMonitor) { this._callSubscribers.remove(token) }
    }
    
    /**
     * 注册聊天列表刷新处理器 (ChatListViewModel)
     */
    public func addChatListRefreshSubscriber(handler: () -> Unit): Int64 {
        return synchronized(this._subscriberMonitor) { let token = this.nextSubscriberTokenLocked(); this._chatListRefreshSubscribers[token] = handler; token }
    }
    public func removeChatListRefreshSubscriber(token: Int64): Unit { synchronized(this._subscriberMonitor) { this._chatListRefreshSubscribers.remove(token) } }

    /**
     * Phase R4: 注册 ChatRoom 新消息推送处理器
     * ChatRoomViewModel 注册此回调以接收实时新消息
     */
    public func addChatRoomPushSubscriber(handler: (Message) -> Unit): Int64 {
        return synchronized(this._subscriberMonitor) { let token = this.nextSubscriberTokenLocked(); this._chatRoomPushSubscribers[token] = handler; token }
    }
    public func removeChatRoomPushSubscriber(token: Int64): Unit { synchronized(this._subscriberMonitor) { this._chatRoomPushSubscribers.remove(token) } }
    
    /**
     * Phase R5: 注册 ChatRoom 编辑消息推送处理器
     */
    public func addChatRoomEditSubscriber(handler: (Message) -> Unit): Int64 {
        return synchronized(this._subscriberMonitor) { let token = this.nextSubscriberTokenLocked(); this._chatRoomEditSubscribers[token] = handler; token }
    }
    public func removeChatRoomEditSubscriber(token: Int64): Unit { synchronized(this._subscriberMonitor) { this._chatRoomEditSubscribers.remove(token) } }
    
    /**
     * Phase R5: 注册 ChatRoom 删除消息推送处理器
     */
    public func addChatRoomDeleteSubscriber(handler: (ArrayList<Int64>) -> Unit): Int64 {
        return synchronized(this._subscriberMonitor) { let token = this.nextSubscriberTokenLocked(); this._chatRoomDeleteSubscribers[token] = handler; token }
    }
    public func removeChatRoomDeleteSubscriber(token: Int64): Unit { synchronized(this._subscriberMonitor) { this._chatRoomDeleteSubscribers.remove(token) } }

    public func addChatRoomReactionSubscriber(
        handler: (Int64, Int64, ArrayList<TLReactionCount>) -> Unit
    ): Int64 {
        return synchronized(this._subscriberMonitor) { let token = this.nextSubscriberTokenLocked(); this._chatRoomReactionSubscribers[token] = handler; token }
    }

    public func removeChatRoomReactionSubscriber(token: Int64): Unit { synchronized(this._subscriberMonitor) { this._chatRoomReactionSubscribers.remove(token) } }
    
    /**
     * Phase R7: 注册输入指示处理器 (userId)
     */
    public func addTypingSubscriber(handler: (Int64) -> Unit): Int64 {
        return synchronized(this._subscriberMonitor) { let token = this.nextSubscriberTokenLocked(); this._typingSubscribers[token] = handler; token }
    }
    public func removeTypingSubscriber(token: Int64): Unit { synchronized(this._subscriberMonitor) { this._typingSubscribers.remove(token) } }

    public func addEmojiInteractionSubscriber(
        handler: (Int64, String, Int64, String) -> Unit
    ): Int64 {
        return synchronized(this._subscriberMonitor) { let token = this.nextSubscriberTokenLocked(); this._emojiInteractionSubscribers[token] = handler; token }
    }

    public func removeEmojiInteractionSubscriber(token: Int64): Unit { synchronized(this._subscriberMonitor) { this._emojiInteractionSubscribers.remove(token) } }
    
    /**
     * Phase R8: 注册在线状态处理器 (userId, isOnline)
     */
    public func addUserStatusSubscriber(handler: (Int64, Bool) -> Unit): Int64 {
        return synchronized(this._subscriberMonitor) { let token = this.nextSubscriberTokenLocked(); this._userStatusSubscribers[token] = handler; token }
    }
    public func removeUserStatusSubscriber(token: Int64): Unit { synchronized(this._subscriberMonitor) { this._userStatusSubscribers.remove(token) } }
    
    /**
     * Phase R6: 注册已读 Inbox 处理器 (peerId, maxId, stillUnread)
     */
    public func addReadInboxSubscriber(handler: (String, Int64, Int32, Int32) -> Unit): Int64 {
        return synchronized(this._subscriberMonitor) { let token = this.nextSubscriberTokenLocked(); this._readInboxSubscribers[token] = handler; token }
    }
    public func removeReadInboxSubscriber(token: Int64): Unit { synchronized(this._subscriberMonitor) { this._readInboxSubscribers.remove(token) } }
    
    /**
     * Phase R6: 注册已读 Outbox 处理器 (peerId, maxId)
     */
    public func addReadOutboxSubscriber(handler: (String, Int64, Int32) -> Unit): Int64 {
        return synchronized(this._subscriberMonitor) { let token = this.nextSubscriberTokenLocked(); this._readOutboxSubscribers[token] = handler; token }
    }
    public func removeReadOutboxSubscriber(token: Int64): Unit { synchronized(this._subscriberMonitor) { this._readOutboxSubscribers.remove(token) } }
    
    // ==================== 核心入口: 处理 raw update ====================
    
    /**
     * 处理从 MTProtoClient 收到的 raw update 数据
     * 
     * 顶层构造器类型:
     * - updateShort#78d4dec1: 单个 update + date
     * - updateShortMessage#313bc7f8: 快捷新私聊消息
     * - updateShortChatMessage#4d6deea5: 快捷新群聊消息
     * - updateShortSentMessage#9015e101: 发送消息成功确认
     * - updates#74ae4240: 完整 updates (含 Vector<Update> + users + chats + date + seq)
     * - updatesCombined#725b04c3: 合并 updates (含 seqStart)
     * - updatesTooLong#e317af7e: 更新过多，需要 getDifference
     */
    public func handleRawUpdate(data: Array<Byte>): Unit {
        if (data.size < 4) { return }
        
        try {
            let d = TLDeserializer(data)
            let constructor = d.readUInt32()
            
            // gzip 解压递归
            if (constructor == 0x3072cfa1) {
                let compressedData = d.readBytes()
                let decompressed = decompress(compressedData)
                if (decompressed.size >= 4) {
                    handleRawUpdate(decompressed)
                }
                return
            }
            
            // updatesTooLong — 需要 getDifference
            if (constructor == 0xe317af7e) {
                Hilog.info(0, "CjTelegram", "[UpdatesManager] updatesTooLong received, triggering getDifference")
                // 接收线程：必须异步，否则阻塞式 getDifference 会自我死锁 60 秒。
                let _ = triggerDifferenceSyncAsync()
                return
            }
            
            // updateShort — 单个 update
            if (constructor == 0x78d4dec1) {
                handleUpdateShort(d, data)
                return
            }
            
            // updateShortMessage — 快捷新私聊消息
            if (constructor == 0x313bc7f8) {
                handleUpdateShortMessage(d)
                return
            }
            
            // updateShortChatMessage — 快捷新群聊消息
            if (constructor == 0x4d6deea5) {
                handleUpdateShortChatMessage(d)
                return
            }
            
            // updateShortSentMessage — 发送确认
            if (constructor == 0x9015e101) {
                // 发送确认在 RealMessageService 中处理，这里不需要额外动作
                Hilog.info(0, "CjTelegram", "[UpdatesManager] updateShortSentMessage (handled by sender)")
                return
            }
            
            // updates — 完整更新包
            if (constructor == 0x74ae4240) {
                handleUpdates(d, data)
                return
            }
            
            // updatesCombined — 合并更新包
            if (constructor == 0x725b04c3) {
                handleUpdatesCombined(d, data)
                return
            }
            
            // 未知构造器 — 转发给已注册的处理器（向后兼容 CallService）
            Hilog.info(0, "CjTelegram", "[UpdatesManager] Unknown update constructor: 0x${UInt32ToHex(constructor)}")
            forwardToCallHandler(data)
            let _ = triggerDifferenceSyncAsync()
            
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[UpdatesManager] Error handling update: ${e}")
            // 回退：转发给 CallService 做字节扫描
            forwardToCallHandler(data)
            let _ = triggerDifferenceSyncAsync()
        }
    }
    
    // ==================== 各类更新处理 ====================
    
    /**
     * updateShort#78d4dec1 update:Update date:int
     */
    private func handleUpdateShort(d: TLDeserializer, rawData: Array<Byte>): Unit {
        // 读 inner update constructor
        let innerCtor = d.readUInt32()
        Hilog.info(0, "CjTelegram", "[UpdatesManager] updateShort inner: 0x${UInt32ToHex(innerCtor)}")

        // Current layer: updateMessageReactions#1e297bfa.
        // Keep the older #5e1b3cb8 constructor for stored sessions that have
        // not negotiated the newest optional saved_peer_id field yet.
        if (innerCtor == 0x1e297bfa || innerCtor == 0x5e1b3cb8) {
            this.handleMessageReactionsUpdate(d)
            return
        }

        // updateRecentReactions#6f7863f4 has no fields. Telegram sends this
        // bookkeeping notification next to updateMessageReactions after a
        // peer reacts. Treating it as unknown used to abort the container (or
        // trigger an unnecessary getDifference), so the actual message delta
        // behind it was not published until the next getHistory poll.
        if (innerCtor == 0x6f7863f4) {
            Hilog.info(0, "CjTelegram", "[UpdatesManager] Recent reactions changed")
            return
        }

        // Entity Keyboard collection updates are independent from the PTS
        // message stream. Consume them in-place and refresh the account-scoped
        // Store, matching iOS CloudStickerPacks/CloudEmojiPacks invalidation.
        if (this.handleEntityKeyboardUpdate(d, innerCtor)) { return }

        // 群 Video Chat 推送（updateShort 包裹时同样就地消费）
        if (isGroupCallUpdateCtor(innerCtor)) {
            let _ = this.handleGroupCallUpdate(d, innerCtor)
            return
        }

        // S8-08：updateEncryption#b4a2e88d chat:EncryptedChat date:int（iOS Api0.swift:1228）。
        // 对端接受秘密聊天后服务端推 encryptedChat（g_b + fingerprint），交给 SecretChatsService
        // 完成 DH 并通知聊天页；此前当未知构造器丢弃，发起方永远停在握手态。
        if (innerCtor == 0xb4a2e88d) {
            if (!getTelegramCore_SecretChatsService().handleUpdateEncryption(d)) {
                let _ = triggerDifferenceSyncAsync()
            }
            return
        }

        // 通话相关 update — 转发给 CallService + 标记通话记录需要刷新
        if (innerCtor == 0xab0f6b1e || // updatePhoneCall
            innerCtor == 0x2661BF09) {  // updatePhoneCallSignalingData
            forwardToCallHandler(rawData)
            markCallHistoryNeedsRefresh()
            return
        }
        
        // updateUserName#a7848924 in updateShort
        if (innerCtor == 0xa7848924) {
            if (!this.handleUserNameUpdate(d)) { let _ = triggerDifferenceSyncAsync() }
            return
        }

        // Phase R7: typing in updateShort
        if (innerCtor == 0xc01e857f) {
            // updateUserTyping: flags + user_id + action
            let _ = d.readInt32()  // flags
            let typUserId = d.readInt64()
            let actionCtor = d.readUInt32()
            let _ = this.handleSendMessageAction(d, typUserId, actionCtor)
            return
        }
        
        // Phase P5-15: updateDialogPinned in updateShort
        if (innerCtor == 0x6e6fe51c) {
            let pinFlags = d.readInt32()
            let isPinned = (pinFlags & 1) != 0
            if ((pinFlags & 2) != 0) { let _ = d.readInt32() }  // folder_id
            let (peerType, peerId) = parseDialogPeer(d)
            if (peerId > 0) {
                notifyDialogUpdate("pin", peerType, peerId, isPinned)
            }
            return
        }

        // Phase P5-15: updateDialogUnreadMark in updateShort
        // 旧 #e16459c3 与当前层 #b658f23e（多 saved_peer_id:flags.1?Peer，Api29.swift
        // parse_updateDialogUnreadMark）；带 saved_peer_id 的是子对话标记，不改主会话行。
        if (innerCtor == 0xe16459c3 || innerCtor == 0xb658f23e) {
            let unreadFlags = d.readInt32()
            let isUnread = (unreadFlags & 1) != 0
            let (peerType, peerId) = parseDialogPeer(d)
            var hasSavedPeer = false
            if (innerCtor == 0xb658f23e && (unreadFlags & 2) != 0) {
                let _ = PeerResponse.deserializeBoxed(d)
                hasSavedPeer = true
            }
            if (peerId > 0 && !hasSavedPeer) {
                notifyDialogUpdate("unread", peerType, peerId, isUnread)
            }
            return
        }

        // Phase P5-15: updateNotifySettings in updateShort
        if (innerCtor == 0xbec268ef) {
            let npCtor = d.readUInt32()
            var notifyPeerId: Int64 = 0
            var notifyPeerType: String = ""
            if (npCtor == 0x9fd40bd8) {
                let peer = PeerResponse.deserializeBoxed(d)
                notifyPeerId = peer.id
                notifyPeerType = peer.type_
            }
            // Skip PeerNotifySettings — just trigger refresh
            if (notifyPeerId > 0) {
                notifyDialogUpdate("mute", notifyPeerType, notifyPeerId, true)
            }
            return
        }

        // 未识别的单条 update 不能静默视为已处理；刷新列表并补差恢复权威状态。
        notifyChatListRefresh()
        let _ = triggerDifferenceSyncAsync()
    }
    
    /**
     * updateShortMessage#313bc7f8 — 新私聊消息（不含完整 Message 对象）
     * flags:# out:flags.1?true mentioned:flags.4?true media_unread:flags.5?true silent:flags.13?true
     * id:int user_id:long message:string pts:int pts_count:int date:int
     * fwd_from:flags.2?MessageFwdHeader via_bot_id:flags.11?long 
     * reply_to:flags.3?MessageReplyHeader entities:flags.7?Vector<MessageEntity>
     * ttl_period:flags.25?int
     */
    private func handleUpdateShortMessage(d: TLDeserializer): Unit {
        let flags = d.readInt32()
        let _id = d.readInt32()
        let _userId = d.readInt64()
        let _message = d.readString()
        let pts = d.readInt32()
        let ptsCount = d.readInt32()
        let date = d.readInt32()
        
        Hilog.info(0, "CjTelegram", "[UpdatesManager] updateShortMessage: id=${_id}, pts=${pts}, ptsCount=${ptsCount}")

        // 更新 pts
        if (pts > 0 && !checkAndUpdatePts(pts, ptsCount)) {
            Hilog.info(0, "CjTelegram", "[UpdatesManager] short private message deferred to getDifference: id=${_id}")
            return
        }
        if (date > this.currentDate) {
            this.currentDate = date
        }

        // ★ 入口归一化：合成 TLMessage 交给 dispatchNewMessages 统一分发。
        //
        // 此处**曾只调 notifyChatListMessage**（只更新会话列表），从不推送给聊天室，
        // 于是停留在会话里收到的纯文本/emoji 只能等 10 秒兜底轮询捞回，平均延迟 5 秒。
        // 真机对照实证（同一会话依次收四条）：
        //   id=1090 纯文本 updateShortMessage → 无 Push message added
        //   id=1091 emoji  updateShortMessage → 无 Push message added
        //   id=1092 图片   完整 updates      → Push message added，1 毫秒上屏
        //   id=1093 贴纸   完整 updates      → Push message added，1 毫秒上屏
        // 差别只在于「压缩形式的短消息没有走 dispatchNewMessages」。
        //
        // 对齐 iOS UpdateMessageService.swift:63-88 —— 短消息形式同样被归一化成
        // 标准 Message 后走统一分发路径，而不是各自为政。
        //
        // dispatchNewMessages 内部已包含 notifyChatListMessage，故上面的直调已移除，
        // 否则会话列表会收到两次通知。
        let tlMsg = TLMessage()
        tlMsg.id = _id
        tlMsg.date = date
        tlMsg.message = _message
        tlMsg.isOutgoing = (flags & 2) != 0        // out:flags.1
        // fwd_from(flags.2) 未展开解析，但其存在性决定 Saved Messages 的方向（iOS effectivelyIncoming）
        tlMsg.hasForwardInfo = (flags & 4) != 0

        // 私聊的会话标识就是对端 user_id
        let peer = PeerResponse()
        peer.type_ = "user"
        peer.id = _userId
        tlMsg.peerId = peer

        // updateShortMessage#313bc7f8 结构上**没有 from_id**，只有 user_id（对端）。
        // 按 out 位补齐发送者，否则 parseMessage 判不出方向：
        //   out=1 自己发的 → from = 当前用户
        //   out=0 对方发的 → from = user_id
        let from = PeerResponse()
        from.type_ = "user"
        from.id = if (tlMsg.isOutgoing) { getCurrentUserId() } else { _userId }
        tlMsg.fromId = Some(from)

        // 未解析的可选字段：fwd_from(flags.2) / via_bot_id(flags.11) / reply_to(flags.3)
        // / entities(flags.7) / ttl_period(flags.25)。它们是变长结构，要读 entities
        // 必须先完整解析前面几个才能对齐偏移，出错即整包错位 —— 收益（首屏就带格式）
        // 不抵风险。缺失部分由随后按需触发的 getHistory 以同 id 增量合并原地补齐
        // （insertLocked 的「同键换承载对象」路径），首屏只是短暂无富文本格式。
        let batch = ArrayList<TLMessage>()
        batch.add(tlMsg)
        dispatchNewMessages(batch)

        // B3-1 followup: 此处**不再**调用 notifyChatListRefresh()。
        // 本函数只处理「新消息」这一种更新，已由上面的本地应用完整覆盖；
        // 再发刷新信号会额外触发一次全量 getDialogs 回源（实测 3452 字节/次）。
        // 真机实测：保留该调用时活跃聊天期每 2~3 秒回源一次（去抖下限），
        // 流量较改造前反而升高约一个数量级。
        // 若 pts 出现空洞，统一由 AccountUpdateCoordinator 的 difference barrier 校正。
    }
    
    /**
     * updateShortChatMessage#4d6deea5 — 新群聊消息
     */
    private func handleUpdateShortChatMessage(d: TLDeserializer): Unit {
        let flags = d.readInt32()
        let _id = d.readInt32()
        let _fromId = d.readInt64()
        let _chatId = d.readInt64()
        let _message = d.readString()
        let pts = d.readInt32()
        let ptsCount = d.readInt32()
        let date = d.readInt32()
        
        Hilog.info(0, "CjTelegram", "[UpdatesManager] updateShortChatMessage: id=${_id}, pts=${pts}, ptsCount=${ptsCount}")

        if (pts > 0 && !checkAndUpdatePts(pts, ptsCount)) {
            Hilog.info(0, "CjTelegram", "[UpdatesManager] short chat message deferred to getDifference: id=${_id}")
            return
        }
        if (date > this.currentDate) {
            this.currentDate = date
        }

        // ★ 入口归一化：同 handleUpdateShortMessage，合成 TLMessage 走统一分发。
        // 原先只调 notifyChatListMessage，群聊里的纯文本/emoji 同样要等轮询捞回。
        // dispatchNewMessages 内部已含 notifyChatListMessage，直调已移除以免重复通知。
        let tlMsg = TLMessage()
        tlMsg.id = _id
        tlMsg.date = date
        tlMsg.message = _message
        tlMsg.isOutgoing = (flags & 2) != 0

        // 群聊会话的 peer 是 chat_id（from_id 仅为发送者，不能用作会话标识）
        let peer = PeerResponse()
        peer.type_ = "chat"
        peer.id = _chatId
        tlMsg.peerId = peer

        // 群聊这条结构上**带 from_id**，直接用，无需按 out 位推断
        let from = PeerResponse()
        from.type_ = "user"
        from.id = _fromId
        tlMsg.fromId = Some(from)

        // 未解析的可选字段同 handleUpdateShortMessage，由后续增量合并补齐
        let batch = ArrayList<TLMessage>()
        batch.add(tlMsg)
        dispatchNewMessages(batch)

        // B3-1 followup: 同 handleUpdateShortMessage —— 本函数只处理新消息，
        // 已被本地应用完整覆盖，不再回源。理由与兜底策略见该函数注释。
    }
    
    /**
     * updates#74ae4240 — 完整更新包
     * updates:Vector<Update> users:Vector<User> chats:Vector<Chat> date:int seq:int
     * 
     * Phase R4: 解析 Vector<Update> 提取 updateNewMessage
     */
    private func handleUpdates(d: TLDeserializer, rawData: Array<Byte>): Unit {
        // 先转发给 CallService（它会扫描通话相关的 update）
        forwardToCallHandler(rawData)
        
        // 解析 updates Vector
        let newTLMessages = ArrayList<TLMessage>()
        let editedTLMessages = ArrayList<TLMessage>()  // Phase R5
        let deletedMessageIds = ArrayList<Int32>()      // Phase R5
        var hasNewMessages = false
        var needsDifference = false
        var channelPtsGap = false
        // 频道消息不在账号级 getDifference 里重放：已完整解析的这部分即使后面遇到未知
        // constructor 也照常应用，不随账号级批次一起回滚。
        let channelNewMessages = ArrayList<TLMessage>()
        let channelEditedMessages = ArrayList<TLMessage>()
        let batchStartPts = this.currentPts
        let batchStartQts = this.currentQts
        let batchStartDate = this.currentDate
        let batchStartSeq = this.currentSeq
        
        try {
            let vecCtor = d.readUInt32()
            if (vecCtor == TLConstructors.VECTOR) {
                let count = d.readInt32()
                for (_i in 0..Int64(count)) {
                    let updateCtor = d.readUInt32()

                    // updateMessageID#4e90bfd6 id:int random_id:long
                    // RPCs such as messages.startBot place this acknowledgement
                    // before the actual updateNewMessage entries in the same
                    // Updates container. It has no visible state of its own here,
                    // but its fields must be consumed so the following messages
                    // remain parseable by the shared updates state machine.
                    if (updateCtor == 0x4e90bfd6) {
                        let _ = d.readInt32()
                        let _ = d.readInt64()
                        continue
                    }

                    if (updateCtor == 0x1e297bfa || updateCtor == 0x5e1b3cb8) {
                        this.handleMessageReactionsUpdate(d)
                        continue
                    }

                    // updateRecentReactions#6f7863f4 = Update (fieldless).
                    // It commonly precedes the visible message-reaction delta
                    // in the same vector; consume it without aborting parsing.
                    if (updateCtor == 0x6f7863f4) {
                        Hilog.info(0, "CjTelegram", "[UpdatesManager] Recent reactions changed")
                        continue
                    }

                    if (this.handleEntityKeyboardUpdate(d, updateCtor)) {
                        continue
                    }

                    // 群 Video Chat：成员 / 通话状态 / 连接参数。解析失败则偏移不可信，走 difference。
                    if (isGroupCallUpdateCtor(updateCtor)) {
                        if (this.handleGroupCallUpdate(d, updateCtor)) { continue }
                        needsDifference = true
                        break
                    }

                    // S8-08：updateEncryption#b4a2e88d（updates 容器内同样就地消费，见 handleUpdateShort）。
                    if (updateCtor == 0xb4a2e88d) {
                        if (getTelegramCore_SecretChatsService().handleUpdateEncryption(d)) { continue }
                        needsDifference = true
                        break
                    }

                    // updateNewMessage#1f2b0afd message:Message pts:int pts_count:int
                    if (updateCtor == 0x1f2b0afd) {
                        let msg = TLMessage.deserializeBoxed(d)
                        let pts = d.readInt32()
                        let ptsCount = d.readInt32()
                        if (checkAndUpdatePts(pts, ptsCount) && msg.id != 0) {
                            newTLMessages.add(msg)
                            hasNewMessages = true
                        }
                        continue
                    }

                    // updateNewChannelMessage#62ba04d9 / updateEditChannelMessage#1b3f4df7
                    // message:Message pts:int pts_count:int（iOS Api0.swift:1253 / :1222）。
                    // 超级群（含由基础群升级而来的群）与频道的新消息只走这条；此前未识别，
                    // 整包被丢弃，只能等 getDifference（账号级差分不含频道消息）后的整表回源。
                    if (updateCtor == 0x62ba04d9 || updateCtor == 0x1b3f4df7) {
                        let channelMsg = TLMessage.deserializeBoxed(d)
                        let pts = d.readInt32()
                        let ptsCount = d.readInt32()
                        if (channelMsg.id != 0 && channelMsg.peerId.id != 0) {
                            let (apply, gap) = this.acceptChannelPts(channelMsg.peerId.id, pts, ptsCount)
                            if (gap) { channelPtsGap = true }
                            if (apply) {
                                if (updateCtor == 0x62ba04d9) {
                                    channelNewMessages.add(channelMsg)
                                } else {
                                    channelEditedMessages.add(channelMsg)
                                }
                            }
                        }
                        continue
                    }

                    // updateEditMessage#e40370a3 message:Message pts:int pts_count:int
                    // Phase R5: 捕获编辑的消息
                    if (updateCtor == 0xe40370a3) {
                        let editMsg = TLMessage.deserializeBoxed(d)
                        let pts = d.readInt32()
                        let ptsCount = d.readInt32()
                        // updateEditMessage is a complete authoritative Message
                        // snapshot and Telegram also uses it for reaction-only
                        // changes. If our pts is behind, start difference recovery
                        // as usual but still publish this forward snapshot to the
                        // active history immediately. Previously it was discarded,
                        // leaving the reaction stale until the 4s getHistory poll.
                        // Do not apply pts <= currentPts: those are duplicate/stale
                        // snapshots that could overwrite a newer edit.
                        let isForwardSnapshot = !this.stateInitialized || pts > this.currentPts
                        let ptsAccepted = checkAndUpdatePts(pts, ptsCount)
                        if ((ptsAccepted || isForwardSnapshot) && editMsg.id != 0) {
                            editedTLMessages.add(editMsg)
                            if (!ptsAccepted) {
                                Hilog.info(0, "CjTelegram",
                                    "[UpdatesManager] Applying forward edit during PTS recovery: msgId=${editMsg.id}, pts=${pts}")
                            }
                        }
                        continue
                    }
                    
                    // updateDeleteMessages#a20db0e5 messages:Vector<int> pts:int pts_count:int
                    // Phase R5: 捕获删除的消息 ID
                    if (updateCtor == 0xa20db0e5) {
                        let innerVec = d.readUInt32()
                        let batchDeletedIds = ArrayList<Int32>()
                        if (innerVec == TLConstructors.VECTOR) {
                            let delCount = d.readInt32()
                            for (_j in 0..Int64(delCount)) {
                                let delId = d.readInt32()
                                batchDeletedIds.add(delId)
                            }
                        }
                        let pts = d.readInt32()
                        let ptsCount = d.readInt32()
                        if (checkAndUpdatePts(pts, ptsCount)) {
                            for (deletedId in batchDeletedIds) {
                                deletedMessageIds.add(deletedId)
                            }
                        }
                        continue
                    }
                    
                    // updateReadHistoryInbox#9c974fdf
                    // Phase R6: 捕获已读状态 — 对方阅读了我发的消息
                    if (updateCtor == 0x9c974fdf) {
                        let flags = d.readInt32()
                        if ((flags & 1) != 0) { let _ = d.readInt32() }  // folder_id
                        let peer = PeerResponse.deserializeBoxed(d)
                        let maxId = d.readInt32()
                        let stillUnread = d.readInt32()
                        let pts = d.readInt32()
                        let ptsCount = d.readInt32()
                        if (checkAndUpdatePts(pts, ptsCount)) {
                            Hilog.info(0, "CjTelegram", "[UpdatesManager] ReadInbox: peer=${peer.id}, maxId=${maxId}, unread=${stillUnread}")
                            notifyReadInbox(peer.type_, peer.id, maxId, stillUnread)
                        }
                        continue
                    }
                    
                    // updateReadHistoryOutbox#2f2f21bf
                    // Phase R6: 对方读了我发的消息 → 双勾变蓝
                    if (updateCtor == 0x2f2f21bf) {
                        let peer = PeerResponse.deserializeBoxed(d)
                        let maxId = d.readInt32()
                        let pts = d.readInt32()
                        let ptsCount = d.readInt32()
                        if (checkAndUpdatePts(pts, ptsCount)) {
                            Hilog.info(0, "CjTelegram", "[UpdatesManager] ReadOutbox: peer=${peer.id}, maxId=${maxId}")
                            notifyReadOutbox(peer.type_, peer.id, maxId)
                        }
                        continue
                    }
                    
                    // Phase R7: updateUserTyping#c01e857f flags:# user_id:long action:SendMessageAction
                    if (updateCtor == 0xc01e857f) {
                        let _ = d.readInt32()
                        let typUserId = d.readInt64()
                        let actionCtor = d.readUInt32()
                        if (!this.handleSendMessageAction(d, typUserId, actionCtor)) {
                            needsDifference = true
                            break
                        }
                        continue
                    }
                    
                    // updatePeerSettings#6a7e7366 peer:Peer settings:PeerSettings（iOS
                    // AccountStateManagementUtils → CachedUserData.peerStatusSettings；S2-12 顶部栏）
                    if (updateCtor == 0x6a7e7366) {
                        let settingsPeer = PeerResponse.deserializeBoxed(d)
                        let settingsFlags = readPeerSettingsFlags(d)
                        Hilog.info(0, "CjTelegram", "[UpdatesManager] updatePeerSettings peer=${settingsPeer.type_}:${settingsPeer.id} flags=${settingsFlags}")
                        notifyPeerSettingsChanged(settingsPeer.type_, settingsPeer.id, settingsFlags)
                        continue
                    }

                    // updateUserName#a7848924 (Api0.swift:1318)
                    if (updateCtor == 0xa7848924) {
                        if (this.handleUserNameUpdate(d)) { continue }
                        needsDifference = true
                        break
                    }

                    // Phase R8: updateUserStatus#e5bdf8de user_id:long status:UserStatus
                    if (updateCtor == 0xe5bdf8de) {
                        let statusUserId = d.readInt64()
                        let statusCtor = d.readUInt32()
                        // userStatusOnline#edb93949 expires:int
                        if (statusCtor == 0xedb93949) {
                            let _ = d.readInt32()  // expires
                            // 人工反馈 #4b：先把共享用户缓存刷新，订阅方（联系人列表等）读缓存即得最新态
                            applyUserStatusToCache(statusUserId, true, 0)
                            notifyUserStatus(statusUserId, true)
                        }
                        // userStatusOffline#008c703f was_online:int
                        if (statusCtor == 0x008c703f) {
                            let wasOnline = d.readInt32()  // was_online
                            applyUserStatusToCache(statusUserId, false, wasOnline)
                            notifyUserStatus(statusUserId, false)
                        }
                        // userStatusEmpty = 0x09d05049 — no fields
                        // userStatusRecently etc — no extra fields we care about
                        continue
                    }
                    
                    // updatePhoneCall#ab0f6b1e phone_call:PhoneCall — 通话信令
                    // updatePhoneCallSignalingData#2661bf09 — 通话数据
                    if (updateCtor == 0xab0f6b1e || updateCtor == 0x2661BF09) {
                        // 已在 handleUpdates 开头通过 forwardToCallHandler 处理
                        // 标记通话记录需要刷新
                        markCallHistoryNeedsRefresh()
                        // 跳过此 update 的剩余字段 — 无法安全解析，停止向量解析
                        needsDifference = true
                        break
                    }
                    
                    // Phase P5-15: updateDialogPinned#6e6fe51c
                    // flags:# pinned:flags.0?true folder_id:flags.1?int peer:DialogPeer
                    if (updateCtor == 0x6e6fe51c) {
                        let pinFlags = d.readInt32()
                        let isPinned = (pinFlags & 1) != 0
                        if ((pinFlags & 2) != 0) { let _ = d.readInt32() }  // folder_id
                        let (peerType, peerId) = parseDialogPeer(d)
                        if (peerId > 0) {
                            notifyDialogUpdate("pin", peerType, peerId, isPinned)
                        }
                        continue
                    }

                    // Phase P5-15: updateDialogUnreadMark#e16459c3 / #b658f23e
                    // flags:# unread:flags.0?true peer:DialogPeer saved_peer_id:flags.1?Peer（仅 #b658f23e）
                    // iOS AccountStateManagementUtils.swift:1311：带 saved_peer_id 时只标子对话。
                    if (updateCtor == 0xe16459c3 || updateCtor == 0xb658f23e) {
                        let unreadFlags = d.readInt32()
                        let isUnread = (unreadFlags & 1) != 0
                        let (peerType, peerId) = parseDialogPeer(d)
                        var hasSavedPeer = false
                        if (updateCtor == 0xb658f23e && (unreadFlags & 2) != 0) {
                            let _ = PeerResponse.deserializeBoxed(d)
                            hasSavedPeer = true
                        }
                        if (peerId > 0 && !hasSavedPeer) {
                            notifyDialogUpdate("unread", peerType, peerId, isUnread)
                        }
                        continue
                    }

                    // Phase P5-15: updateNotifySettings#bec268ef
                    // peer:NotifyPeer settings:PeerNotifySettings
                    if (updateCtor == 0xbec268ef) {
                        // NotifyPeer: notifyPeer#9fd40bd8 peer:Peer | notifyUsers#b4c83b4c | notifyChats#c007cec3 | notifyBroadcasts#d612e8ef
                        let npCtor = d.readUInt32()
                        var notifyPeerId: Int64 = 0
                        var notifyPeerType: String = ""
                        if (npCtor == 0x9fd40bd8) {
                            // notifyPeer#9fd40bd8 peer:Peer
                            let peer = PeerResponse.deserializeBoxed(d)
                            notifyPeerId = peer.id
                            notifyPeerType = peer.type_
                        }
                        // PeerNotifySettings#99622c0c flags:# ... 
                        let nsCtor = d.readUInt32()
                        if (nsCtor == 0x99622c0c) {
                            let nsFlags = d.readInt32()
                            if ((nsFlags & 1) != 0) { let _ = d.readBool() }  // show_previews
                            if ((nsFlags & 2) != 0) { let _ = d.readBool() }  // silent
                            if ((nsFlags & 4) != 0) { let _ = d.readInt32() }  // mute_until
                            // Check mute state: if mute_until > 0, it's muted
                            let isMuted = (nsFlags & 4) != 0
                            if (notifyPeerId > 0) {
                                notifyDialogUpdate("mute", notifyPeerType, notifyPeerId, isMuted)
                            }
                            // Skip remaining optional fields
                            if ((nsFlags & 8) != 0) { let _ = d.readUInt32() }  // ios_sound (NotificationSound)
                            if ((nsFlags & 16) != 0) { let _ = d.readUInt32() }  // android_sound
                            if ((nsFlags & 32) != 0) { let _ = d.readUInt32() }  // other_sound
                        }
                        // Even if we can't fully parse, we triggered the refresh
                        continue
                    }

                    // 未知 update 类型 — 无法安全跳过，停止解析
                    Hilog.info(0, "CjTelegram", "[UpdatesManager] Unknown update 0x${UInt32ToHex(updateCtor)} in updates vector, stopping parse")
                    needsDifference = true
                    break
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[UpdatesManager] Error parsing updates vector: ${e}")
            needsDifference = true
        }

        if (needsDifference) {
            // 整个 container 视为一个提交单元。未知 constructor 之后无法证明已完整消费，
            // 回退本批已推进的同步游标，让 getDifference 从批次起点权威重放。
            this.currentPts = batchStartPts
            this.currentQts = batchStartQts
            this.currentDate = batchStartDate
            this.currentSeq = batchStartSeq
            getAuthStorage().saveSyncState(batchStartPts, batchStartQts, batchStartDate, batchStartSeq)
            newTLMessages.clear()
            editedTLMessages.clear()
            deletedMessageIds.clear()
            hasNewMessages = false
            let _ = triggerDifferenceSyncAsync()
        }
        
        if (!channelNewMessages.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[UpdatesManager] Got ${channelNewMessages.size} new channel messages from updates")
            dispatchNewMessages(channelNewMessages)
        }
        if (!channelEditedMessages.isEmpty()) {
            for (m in channelEditedMessages) { editedTLMessages.add(m) }
        }

        // 处理新消息
        if (hasNewMessages) {
            Hilog.info(0, "CjTelegram", "[UpdatesManager] Got ${newTLMessages.size} new messages from updates")
            dispatchNewMessages(newTLMessages)
        }
        
        // Phase R5: 处理编辑消息
        if (!editedTLMessages.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[UpdatesManager] Got ${editedTLMessages.size} edited messages")
            dispatchEditedMessages(editedTLMessages)
        }
        
        // Phase R5: 处理删除消息
        if (!deletedMessageIds.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[UpdatesManager] Got ${deletedMessageIds.size} deleted messages")
            dispatchDeletedMessages(deletedMessageIds)
        }

        // B3-1 followup: 条件回源。
        //
        // 新消息已在 dispatchNewMessages 内经 notifyChatListMessage 完成本地应用，
        // 无需回源；但编辑 / 删除尚未本地应用（结构性原因见 docs/future_develop.md），
        // 仍必须回源才能拿到正确的列表预览。
        //
        // 故仅当「本批次里存在新消息之外的变更」时才回源。
        // 若本批次只有新消息，跳过回源 —— 这正是本次要消除的冗余：
        // 真机实测保留无条件回源时，活跃聊天期每 2~3 秒就全量拉一次 getDialogs
        // （3452 字节/次），流量较改造前反而升高约一个数量级。
        //
        // typing / reactions / read / dialog 属性均有增量路径，不得因此回源。
        // 只有编辑/删除可能改变 top message 且当前 Chat 缺少 lastMessageId，才做恢复拉取。
        // 频道 pts 缺口：本端没有 getChannelDifference 通道，整表回源一次校正列表。
        if (!editedTLMessages.isEmpty() || !deletedMessageIds.isEmpty() || (channelPtsGap && !needsDifference)) {
            notifyChatListRefresh()
        }
    }

    /**
     * 频道 pts 连续性（iOS AccountStateManagementUtils.swift:1098 updateNewChannelMessage）：
     * 已知 pts >= 新 pts → 旧消息，跳过；已知 pts + ptsCount == pts → 连续，应用；
     * 否则为缺口（iOS 记 missingUpdatesFromChannels 走 getChannelDifference）。
     * 本端没有频道差分通道：缺口时仍应用这条服务端权威消息并推进到新 pts，
     * 同时返回 gap=true 让调用方整表回源；状态未知（本次启动首条）直接采纳。
     *
     * @return (是否应用, 是否出现缺口)
     */
    private func acceptChannelPts(channelId: Int64, pts: Int32, ptsCount: Int32): (Bool, Bool) {
        return synchronized(this._subscriberMonitor) {
            match (this._channelPts.get(channelId)) {
                case Some(known) =>
                    if (known >= pts) {
                        Hilog.info(0, "CjTelegram",
                            "[UpdatesManager] channel ${channelId} skip old update pts=${pts}, known=${known}")
                        (false, false)
                    } else {
                        let gap = known + ptsCount != pts
                        if (gap) {
                            Hilog.info(0, "CjTelegram",
                                "[UpdatesManager] channel ${channelId} pts hole ${known} + ${ptsCount} != ${pts}")
                        }
                        this._channelPts[channelId] = pts
                        (true, gap)
                    }
                case None =>
                    this._channelPts[channelId] = pts
                    (true, false)
            }
        }
    }

    /**
     * Consume the field-complete sticker/emoji collection updates supported by
     * the current Telegram layer. `flags.0` denotes mask packs and `flags.1`
     * denotes custom Emoji packs; neither bit denotes ordinary sticker packs.
     *
     * Returning false means the constructor is not one of these updates and the
     * caller must continue its normal dispatch. Mask-only updates are consumed
     * but deliberately ignored because Entity Keyboard never displays masks.
     */
    /**
     * 群 Video Chat 三个推送（iOS AccountStateManagementUtils.swift:5127-5200）：
     *   updateGroupCallParticipants#f2ebdb4e call:InputGroupCall participants:Vector<GroupCallParticipant> version:int
     *   updateGroupCall#97d64341 flags:# chat_id:flags.0?long call:GroupCall   （旧层 #14b24500 chat_id:long call）
     *   updateGroupCallConnection#0b783982 flags:# presentation:flags.0?true params:DataJSON
     * 返回 true = 已完整消费（流位置可信）。
     */
    private func handleGroupCallUpdate(d: TLDeserializer, ctor: UInt32): Bool {
        try {
            if (ctor == 0xf2ebdb4e) {
                if (d.readUInt32() != 0xd8aa840f) { return false }
                let callId = d.readInt64()
                let _ = d.readInt64()
                if (d.readUInt32() != 0x1cb5c415) { return false }
                let n = d.readInt32()
                let list = ArrayList<GroupCallParticipantInfo>()
                var i: Int64 = 0
                while (i < Int64(n)) {
                    match (getCallsService().parseGroupCallParticipant(d)) {
                        case Some(p) => list.add(p)
                        case None => return false
                    }
                    i = i + 1
                }
                let version = d.readInt32()
                Hilog.info(0, "CjTelegram", "[UpdatesManager] updateGroupCallParticipants n=${n} version=${version}")
                getGroupCallSession().applyParticipantUpdates(callId, list, version)
                return true
            }
            if (ctor == 0xd8326f0d) {
                // updateGroupCallMessage call:InputGroupCall message:GroupCallMessage
                // groupCallMessage#1a8afc7e flags:# id:int from_id:Peer date:int
                //   message:TextWithEntities paid_message_stars:flags.0?long
                if (d.readUInt32() != 0xd8aa840f) { return false }
                let callId = d.readInt64()
                let _ = d.readInt64()
                if (d.readUInt32() != 0x1a8afc7e) { return false }
                let mflags = d.readInt32()
                let msgId = Int64(d.readInt32())
                var fromId: Int64 = 0
                let peerCtor = d.readUInt32()
                if (peerCtor == 0x59511722 || peerCtor == 0x36c6019a || peerCtor == 0xa2a5371e) { fromId = d.readInt64() } else { return false }
                let date = Int64(d.readInt32())
                if (d.readUInt32() != 0x751f3146) { return false }
                let text = d.readString()
                skipMessageEntitiesVector(d)
                if ((mflags & 1) != 0) { let _ = d.readInt64() }
                Hilog.info(0, "CjTelegram", "[UpdatesManager] updateGroupCallMessage from=${fromId} len=${text.size}")
                getGroupCallSession().onIncomingMessage(callId, msgId, fromId, text, date)
                return true
            }
            if (ctor == 0x0b783982) {
                let _ = d.readInt32()
                if (d.readUInt32() != 0x7d748d04) { return false }
                let _ = d.readString()
                return true
            }
            // updateGroupCall
            var chatId: Int64 = 0
            if (ctor == 0x97d64341) {
                let flags = d.readInt32()
                if ((flags & 1) != 0) { chatId = d.readInt64() }
            } else {
                chatId = d.readInt64()
            }
            let callCtor = d.readUInt32()
            if (callCtor == 0x7780bcb4) {
                // groupCallDiscarded id:long access_hash:long duration:int
                let callId = d.readInt64()
                let _ = d.readInt64()
                let _ = d.readInt32()
                Hilog.info(0, "CjTelegram", "[UpdatesManager] updateGroupCall: discarded chat=${chatId}")
                getGroupCallSession().onCallDiscarded(callId)
                notifyActiveGroupCallChanged(chatId, 0, 0, 0)
                return true
            }
            if (callCtor == 0x553b0ba1) {
                let gflags = d.readInt32()
                let callId = d.readInt64()
                let callHash = d.readInt64()
                let count = d.readInt32()
                notifyActiveGroupCallChanged(chatId, callId, callHash, count)
                var title = ""
                var hasTitle = false
                if ((gflags & (1 << 3)) != 0) { title = d.readString(); hasTitle = true }
                if ((gflags & (1 << 4)) != 0) { let _ = d.readInt32() }
                var recordDate: Int32 = 0
                if ((gflags & (1 << 5)) != 0) { recordDate = d.readInt32() }
                if ((gflags & (1 << 7)) != 0) { let _ = d.readInt32() }
                if ((gflags & (1 << 10)) != 0) { let _ = d.readInt32() }
                let _ = d.readInt32()
                let _ = d.readInt32()
                if ((gflags & (1 << 16)) != 0) { let _ = d.readString() }
                getGroupCallSession().onCallInfo(callId, title, hasTitle, recordDate != 0, Int64(count))
                return true
            }
            return false
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[UpdatesManager] group call update parse failed: ${e}")
            return false
        }
    }

    private func handleEntityKeyboardUpdate(
        d: TLDeserializer, constructor: UInt32
    ): Bool {
        // updateNewStickerSet#688a30aa stickerset:messages.StickerSet
        if (constructor == 0x688a30aa) {
            let detail = parseStickerSetUpdate(d)
            if (detail.success) {
                getEntityKeyboardStore().applyRemoteNewStickerPack(detail)
                Hilog.info(0, "CjTelegram",
                    "[UpdatesManager] new sticker pack applied id=${detail.info.id}")
            }
            return true
        }

        // updateStickerSets#31c24808 flags:# masks:flags.0?true emojis:flags.1?true
        if (constructor == 0x31c24808) {
            let flags = d.readInt32()
            if ((flags & 2) != 0) {
                getEntityKeyboardStore().invalidateEmojiKeyboard()
                Hilog.info(0, "CjTelegram",
                    "[UpdatesManager] custom Emoji packs invalidated")
            } else if ((flags & 1) == 0) {
                getEntityKeyboardStore().invalidateStickerKeyboard()
                Hilog.info(0, "CjTelegram",
                    "[UpdatesManager] sticker packs invalidated")
            }
            return true
        }

        // updateStickerSetsOrder#0bb2d201 flags:# ... order:Vector<long>
        if (constructor == 0x0bb2d201) {
            let flags = d.readInt32()
            let vectorConstructor = d.readUInt32()
            if (vectorConstructor != TLConstructors.VECTOR) {
                throw Exception("Invalid updateStickerSetsOrder vector")
            }
            let count = d.readInt32()
            let order = ArrayList<Int64>()
            for (_i in 0..Int64(count)) { order.add(d.readInt64()) }
            let store = getEntityKeyboardStore()
            if ((flags & 2) != 0) {
                store.applyRemoteEmojiPackOrder(order.toArray())
            } else if ((flags & 1) == 0) {
                let _ = store.optimisticallyReorderStickerPacks(
                    store.currentToken(), order.toArray())
            }
            Hilog.info(0, "CjTelegram",
                "[UpdatesManager] sticker pack order applied count=${count} flags=${flags}")
            return true
        }
        return false
    }
    
    /**
     * updatesCombined — 类似 updates 但有 seqStart
     */
    private func handleUpdatesCombined(d: TLDeserializer, rawData: Array<Byte>): Unit {
        // updatesCombined starts with the same Vector<Update> as updates; only
        // its trailing seq_start/seq fields differ, which handleUpdates does
        // not need for dispatch. Parse the vector instead of discarding every
        // existing-message delta (reactions, edits, reads).
        Hilog.info(0, "CjTelegram", "[UpdatesManager] updatesCombined received")
        handleUpdates(d, rawData)
    }

    /**
     * updateMessageReactions flags:# peer:Peer msg_id:int
     * top_msg_id:flags.0?int saved_peer_id:flags.1?Peer
     * reactions:MessageReactions
     */
    private func handleMessageReactionsUpdate(d: TLDeserializer): Unit {
        let flags = d.readInt32()
        let peer = PeerResponse.deserializeBoxed(d)
        let msgId = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt32() }
        if ((flags & 2) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        let reactions = parseMessageReactions(d)
        Hilog.info(0, "CjTelegram",
            "[UpdatesManager] MessageReactions: peer=${peer.id}, msgId=${msgId}, count=${reactions.size}")
        let reactionSubscribers = this.chatRoomReactionSubscriberSnapshot()
        var reactionIndex: Int64 = 0
        while (reactionIndex < reactionSubscribers.size) {
            try {
                reactionSubscribers[reactionIndex](peer.id, Int64(msgId), reactions)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UpdatesManager] reaction subscriber=${reactionIndex} failed: ${e}")
            }
            reactionIndex += 1
        }
    }
    
    // ==================== pts/seq 状态机 ====================
    
    /**
     * 检查 pts 连续性并更新
     * 如果 newPts != currentPts + ptsCount → gap detected
     */
    private func checkAndUpdatePts(newPts: Int32, ptsCount: Int32): Bool {
        if (!this.stateInitialized) {
            this.currentPts = newPts
            this.stateInitialized = true
            let initialStorage = getAuthStorage()
            initialStorage.saveSyncState(this.currentPts, this.currentQts, this.currentDate, this.currentSeq)
            return true
        }
        
        let expectedPts = this.currentPts + ptsCount
        if (newPts == expectedPts) {
            // 连续，正常更新
            this.currentPts = newPts
            this.gapCount = 0
        } else if (newPts > expectedPts) {
            // Gap 检测到: 缺少 update
            this.gapCount += 1
            Hilog.info(0, "CjTelegram", "[UpdatesManager] PTS gap detected: expected ${expectedPts}, got ${newPts} (gap #${this.gapCount})")
            // 缺口后的 update 不能被当成连续状态提交，否则 getDifference 会从错误的
            // 新 pts 开始，永久跳过缺失区间。首个 gap 立即异步补差。
            let _ = triggerDifferenceSyncAsync()
            return false
        } else {
            // newPts < expectedPts: 重复 update, 忽略
            Hilog.info(0, "CjTelegram", "[UpdatesManager] Duplicate update ignored: pts=${newPts}, current=${this.currentPts}")
            return false
        }
        
        // 持久化
        let storage = getAuthStorage()
        storage.saveSyncState(this.currentPts, this.currentQts, this.currentDate, this.currentSeq)
        return true
    }
    
    /**
     * 异步触发 getDifference —— 接收线程零阻塞。
     *
     * 所有接收线程上的触发点都必须走本方法，不可直接调 triggerDifferenceSync
     * （后者内含阻塞式 RPC，在接收线程上执行即自我死锁，详见 _diffInFlight 处说明）。
     *
     * 单飞语义：抢不到守卫时记录 pending；当前同步结束后自动再执行一次，
     * 与 iOS AccountStateSynchronizer 的“同步期间继续积累同步请求”一致。
     *
     * @return true = 本次真正启动了同步；false = 已有同步在跑，本次放弃
     */
    private func triggerDifferenceSyncAsync(): Bool {
        if (!this._diffInFlight.compareAndSwap(false, true)) {
            this._diffRequestedWhileInFlight.store(true)
            Hilog.info(0, "CjTelegram", "[UpdatesManager] getDifference already in flight, queued one follow-up")
            return false
        }
        spawn {
            try {
                triggerDifferenceSync()
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UpdatesManager] async getDifference failed: ${e}")
            } finally {
                // 必须复位：若此处漏掉，守卫将永久为 true，之后再也不会触发 getDifference。
                this._diffInFlight.store(false)
                if (this._diffRequestedWhileInFlight.compareAndSwap(true, false)) {
                    let _ = this.triggerDifferenceSyncAsync()
                }
            }
        }
        return true
    }

    /**
     * 触发 getDifference 同步
     *
     * 注意：本方法内部 fetchDifference → sendRequest 为阻塞式 RPC。
     * 仅可在非接收线程上调用（forceDifference 由设置页的 spawn 调用，安全）；
     * 接收线程上的触发点一律走 triggerDifferenceSyncAsync。
     */
    private func triggerDifferenceSync(): Unit {
        // 合并短时间内的重复触发：一次同步还没跑完/刚跑完时，后续 update 不再各自发一次。
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        if (nowMs - this.lastDifferenceSyncMs < 2000) {
            return
        }
        this.lastDifferenceSyncMs = nowMs
        Hilog.info(0, "CjTelegram", "[UpdatesManager] Triggering getDifference sync...")
        let chatListService = getRealChatListService()
        let syncSlot = getAuthStorage().getActiveSlot()
        let newMsgs = chatListService.fetchDifference()
        if (syncSlot != getAuthStorage().getActiveSlot()) {
            // 补差期间切换了账号：结果属于上一账号，不得派生进当前账号的投影 / 消息表。
            Hilog.info(0, "CjTelegram",
                "[UpdatesManager] getDifference result discarded: started for slot=${syncSlot}, active slot=${getAuthStorage().getActiveSlot()}")
            return
        }
        if (newMsgs.size > 0) {
            Hilog.info(0, "CjTelegram", "[UpdatesManager] getDifference returned ${newMsgs.size} new messages")
            // difference 不是只用于修正 pts：把补回的消息走同一条本地应用链，
            // 否则可见 ChatRoom 与 Chats 仍要等待各自轮询才能看到缺口中的消息。
            dispatchNewMessages(newMsgs)
        }
        // 刷新状态
        let storage = getAuthStorage()
        if (storage.hasSyncState()) {
            let (pts, qts, date, seq) = storage.getSyncState()
            this.currentPts = pts
            this.currentQts = qts
            this.currentDate = date
            this.currentSeq = seq
        }
        notifyChatListRefresh()
    }
    
    // ==================== 分发回调 ====================
    
    private func forwardToCallHandler(data: Array<Byte>): Unit {
        let snapshot = this.callSubscriberSnapshot()
        var index: Int64 = 0
        while (index < snapshot.size) {
            try { snapshot[index](data) } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UpdatesManager] call subscriber=${index} failed: ${e}")
            }
            index += 1
        }
    }
    
    /**
     * 标记通话记录需要刷新
     * 当检测到通话相关 update（updatePhoneCall、通话 service message）时调用
     * CallHistoryPage 的同步循环会检测此标志并从 API 重新加载
     */
    private func markCallHistoryNeedsRefresh(): Unit {
        try {
            let callService = getCallService()
            callService.markCallHistoryRefresh()
        } catch (_e: Exception) {}
    }
    
    private func notifyChatListRefresh(): Unit {
        let subscribers = this.chatListRefreshSubscriberSnapshot()
        var index: Int64 = 0
        while (index < subscribers.size) {
            try { subscribers[index]() } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UpdatesManager] chatListRefresh subscriber=${index} failed: ${e}")
            }
            index += 1
        }
    }

    /** 已提交新消息直接应用到账号级 Projection；不依赖页面/ViewModel 生命周期。 */
    private func notifyChatListMessage(peerType: String, peerId: Int64, preview: String, messageType: String,
        date: Int64, outgoing: Bool): Unit {
        let normalizedPeerType = normalizeDialogPeerType(peerType)
        getChatListProjection().applyCommittedMessage(
            normalizedPeerType, peerId, preview, messageType, date, outgoing,
            !outgoing && !isConversationVisible(normalizedPeerType, peerId))
    }

    /** 服务端权威未读数直接应用到账号级 Projection。 */
    private func notifyChatListUnread(peerType: String, peerId: Int64, stillUnread: Int64): Unit {
        getChatListProjection().applyIncomingRead(
            normalizeDialogPeerType(peerType), peerId, stillUnread)
    }
    
    // ==================== Phase R4: 新消息分发 ====================
    
    /**
     * 将 TLMessage 列表转换为 Message 并分发到活跃的 ChatRoom
     */
    private func dispatchNewMessages(tlMessages: ArrayList<TLMessage>): Unit {
        if (tlMessages.isEmpty()) { return }
        
        let msgService = getRealMessageService()
        let currentUserId = getCurrentUserId()
        for (tlMsg in tlMessages) {
            // 检查是否是通话服务消息 — 触发通话记录刷新
            if (tlMsg.callId != 0 || tlMsg.mediaType == "phone_call") {
                Hilog.info(0, "CjTelegram", "[UpdatesManager] Phone call service message detected in updateNewMessage, triggering call history refresh")
                markCallHistoryNeedsRefresh()
            }
            
            // 转换 TLMessage → Message
            let userNames = HashMap<Int64, String>()
            let msg = msgService.parseMessage(tlMsg, currentUserId, userNames)
            
            // 检查是否属于当前打开的聊天
            // 私聊: msg 的 peer 是对方 userId（接收方）或自己（发送方）
            // 群聊: msg 的 peer 是 chatId
            let msgPeerType = this.extractPeerTypeFromTLMessage(tlMsg)
            let msgPeerId = this.extractPeerIdFromTLMessage(tlMsg)

            if (!this.markFirstCommittedMessage(msgPeerType, msgPeerId, msg.id)) {
                Hilog.info(0, "CjTelegram",
                    "[UpdatesManager] duplicate committed message suppressed peer=${msgPeerType}:${msgPeerId}, id=${msg.id}")
                continue
            }

            // Phase 4：先提交消息历史，再派生 Chats/通知。通知不得领先于本地消息真相源。
            let committedMessages = ArrayList<Message>()
            committedMessages.add(msg)
            getMessageHistoryStore().storeMessages(msgPeerId, committedMessages, peerType: msgPeerType)
            getDialogReadStateStore().applyIncomingMessage(
                msgPeerType,
                msgPeerId,
                !tlMsg.isOutgoing && !isConversationVisible(msgPeerType, msgPeerId)
            )

            // B3-1: 无论是否为当前打开的会话，都推给会话列表。
            // 原实现仅在 msgPeerId == selectedChatId 时把 msg 推给 ChatRoom，其余情况把
            // 已解析好的 Message 直接丢弃（只打一行日志），会话列表因此只能靠回源重拉。
            // 方向取 tlMsg.isOutgoing（由 (flags & 2) 解析）而非比较 senderId ——
            // 群匿名管理员 / send-as 场景下 from_id ≠ 自己但 out=1，比较 senderId 会误判
            // （见 RealMessageService.parseMessage 处的同款说明）。
            // 行预览的正文与类型必须取自同一条消息：此前只换正文、沿用上一条的 lastMessageType，
            // 上一条是视频时新到的照片行显示成 "📹 Video"。媒体消息与 getDialogs 路径共用
            // dialogPreviewText（iOS ChatListItemStrings），文本 / 服务消息沿用解析后的正文。
            let previewType = dialogPreviewType(tlMsg)
            let previewText = if (previewType == "text") { msg.content } else { dialogPreviewText(tlMsg) }
            if (tlMsg.isService && tlMsg.isMigrationAction) {
                // 群升级（messageActionChatMigrateTo / ChannelMigrateFrom）：iOS AccountStateManager.swift:2431
                // 不发通知；旧基础群随即 deactivated，列表只留新超级群（UpdatePeers CloudGroup notIncluded）。
                // 旧群行不再由推送派生，整表回源一次拿到带标题 / 头像的超级群行。
                if (normalizeDialogPeerType(msgPeerType) == "chat") {
                    getRealChatListService().markDialogRemoved("chat", msgPeerId)
                }
                notifyChatListRefresh()
            } else {
                notifyChatListMessage(msgPeerType, msgPeerId, previewText, previewType, Int64(tlMsg.date), tlMsg.isOutgoing)
                getNotificationCoordinator().handleIncomingCommitted(
                    msgPeerType, msgPeerId, msg, tlMsg.isOutgoing)
            }

            if (isConversationVisible(msgPeerType, msgPeerId)) {
                // 推送到所有活跃 ChatRoom 订阅者
                let subscribers = this.chatRoomPushSubscriberSnapshot()
                var index: Int64 = 0
                while (index < subscribers.size) {
                    try { subscribers[index](msg) } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[UpdatesManager] chatRoomPush subscriber=${index} failed: ${e}")
                    }
                    index += 1
                }
                
                let pushMsgId = msg.id
                Hilog.info(0, "CjTelegram", "[UpdatesManager] Dispatched new message to active chat: id=${pushMsgId}")
            } else {
                Hilog.info(0, "CjTelegram", "[UpdatesManager] New message for non-visible chat ${msgPeerType}:${msgPeerId}")
            }
        }
    }
    
    /**
     * 从 TLMessage 提取 peer ID（对话 ID）
     * 
     * peerId 是消息所属对话的 peer:
     * - user: peerId.id 是对方 userId
     * - chat: peerId.id 是 chatId
     * - channel: peerId.id 是 channelId
     */
    private func extractPeerIdFromTLMessage(tlMsg: TLMessage): Int64 {
        if (tlMsg.peerId.type_ == "user" && !tlMsg.isOutgoing) {
            match (tlMsg.fromId) {
                case Some(sender) =>
                    if (sender.type_ == "user" && sender.id > 0 && sender.id != getCurrentUserId()) {
                        return sender.id
                    }
                case None => ()
            }
        }
        return tlMsg.peerId.id
    }

    private func extractPeerTypeFromTLMessage(tlMsg: TLMessage): String {
        if (tlMsg.peerId.type_ == "user" && !tlMsg.isOutgoing) {
            match (tlMsg.fromId) {
                case Some(sender) =>
                    if (sender.type_ == "user" && sender.id > 0 && sender.id != getCurrentUserId()) {
                        return "user"
                    }
                case None => ()
            }
        }
        return normalizeDialogPeerType(tlMsg.peerId.type_)
    }
    
    // ==================== Phase R6: 已读状态分发 ====================
    
    private func notifyReadInbox(peerType: String, peerId: Int64, maxId: Int32, stillUnread: Int32): Unit {
        getDialogReadStateStore().applyIncomingRead(peerType, peerId, maxId, stillUnread)
        let subscribers = this.readInboxSubscriberSnapshot()
        let normalizedPeerType = normalizeDialogPeerType(peerType)
        var index: Int64 = 0
        while (index < subscribers.size) {
            try { subscribers[index](normalizedPeerType, peerId, maxId, stillUnread) } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UpdatesManager] readInbox subscriber=${index} failed: ${e}")
            }
            index += 1
        }

        // B3-1: stillUnread 是服务端下发的权威剩余未读数，直接本地应用，零漂移
        // （不同于新消息路径的 +1 推算）。
        // 对齐 iOS：未读态由独立的 ReadStateTable 维护并参与 ChatListTable 重算，
        // 同样不需要为一次已读回执重拉会话列表。
        notifyChatListUnread(peerType, peerId, Int64(stillUnread))
        getNotificationCoordinator().handleReadCommitted(peerType, peerId, stillUnread)

        // B3-1 followup: 不再回源。已读回执用的是服务端权威值，本地应用后不存在漂移，
        // 回源除了多传 3452 字节没有任何额外信息。
    }
    
    private func notifyReadOutbox(peerType: String, peerId: Int64, maxId: Int32): Unit {
        getDialogReadStateStore().applyOutgoingRead(peerType, peerId, maxId)
        let subscribers = this.readOutboxSubscriberSnapshot()
        let normalizedPeerType = normalizeDialogPeerType(peerType)
        var index: Int64 = 0
        while (index < subscribers.size) {
            try { subscribers[index](normalizedPeerType, peerId, maxId) } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UpdatesManager] readOutbox subscriber=${index} failed: ${e}")
            }
            index += 1
        }
    }
    
    // ==================== Phase R7/R8: typing + status 分发 ====================
    
    private func notifyUserTyping(userId: Int64): Unit {
        let subscribers = this.typingSubscriberSnapshot()
        var index: Int64 = 0
        while (index < subscribers.size) {
            try { subscribers[index](userId) } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UpdatesManager] typing subscriber=${index} failed: ${e}")
            }
            index += 1
        }
    }

    /** Consume one SendMessageAction without leaving the enclosing updates vector misaligned. */
    private func handleSendMessageAction(d: TLDeserializer, userId: Int64, actionCtor: UInt32): Bool {
        if (actionCtor == 0x25972bcb) {
            let emoticon = d.readString()
            let messageId = Int64(d.readInt32())
            let dataJsonCtor = d.readUInt32()
            if (dataJsonCtor != 0x7d748d04) { return false }
            let interactionJson = d.readString()
            Hilog.info(0, "CjTelegram", "[EmojiInteraction] received userId=${userId} msgId=${messageId} emoji=${emoticon}")
            let subscribers = this.emojiInteractionSubscriberSnapshot()
            var index: Int64 = 0
            while (index < subscribers.size) {
                try { subscribers[index](userId, emoticon, messageId, interactionJson) } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[UpdatesManager] emojiInteraction subscriber=${index} failed: ${e}")
                }
                index += 1
            }
            return true
        }
        if (actionCtor == 0xb665902e) {
            let emoticon = d.readString()
            Hilog.info(0, "CjTelegram", "[EmojiInteraction] seen emoji=${emoticon}")
            return true
        }
        // The activity types below have no payload.
        if (actionCtor == 0x16bf744e || actionCtor == 0xfd5ec8f5 ||
            actionCtor == 0xd52f73f7 || actionCtor == 0xa187d66f ||
            actionCtor == 0x243e1c66) {
            notifyUserTyping(userId)
            return true
        }
        return false
    }
    
    /**
     * 人工反馈 #4b：updateUserStatus 到达时同步刷新 UserPhotoService.userCache 里的 UserResponse，
     * 使联系人列表 / 资料页等只读缓存的界面能拿到最新的 isOnline / wasOnline / statusType。
     */
    private func applyUserStatusToCache(userId: Int64, isOnline: Bool, wasOnline: Int32): Unit {
        match (getUserPhotoService().getCachedUser(userId)) {
            case Some(u) =>
                u.isOnline = isOnline
                if (isOnline) {
                    u.statusType = "online"
                } else {
                    u.statusType = "offline"
                    if (wasOnline > 0) { u.wasOnline = wasOnline }
                }
            case None => ()
        }
    }

    /**
     * updateUserName#a7848924 user_id:long first_name:string last_name:string
     * usernames:Vector<Username> (Api29.swift parse_updateUserName; username#b4073647 flags:#
     * active:flags.1?true username:string, Api30.swift parse_username).
     * iOS AccountStateManagementUtils.swift:1510-1519 applies only the usernames to the peer.
     * Returns false when the payload cannot be consumed safely.
     */
    private func handleUserNameUpdate(d: TLDeserializer): Bool {
        let userId = d.readInt64()
        let _ = d.readString()  // first_name
        let _ = d.readString()  // last_name
        if (d.readUInt32() != TLConstructors.VECTOR) { return false }
        let count = d.readInt32()
        let usernames = ArrayList<String>()
        var activeUsername = ""
        for (_i in 0..Int64(count)) {
            if (d.readUInt32() != 0xb4073647) { return false }
            let flags = d.readInt32()
            let name = d.readString()
            usernames.add(name)
            if (activeUsername.size == 0 && (flags & (1 << 1)) != 0) { activeUsername = name }
        }
        match (getUserPhotoService().getCachedUser(userId)) {
            case Some(u) =>
                u.usernames = usernames
                u.username = activeUsername
            case None => ()
        }
        Hilog.info(0, "CjTelegram", "[UpdatesManager] updateUserName user=${userId} username='${activeUsername}' count=${count}")
        getRealAuthService().applySelfUsernamesUpdate(userId, usernames, activeUsername)
        return true
    }

    private func notifyUserStatus(userId: Int64, isOnline: Bool): Unit {
        let subscribers = this.userStatusSubscriberSnapshot()
        var index: Int64 = 0
        while (index < subscribers.size) {
            try { subscribers[index](userId, isOnline) } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UpdatesManager] userStatus subscriber=${index} failed: ${e}")
            }
            index += 1
        }
    }
    
    // ==================== Phase P5-15: 对话状态分发 ====================

    private func notifyDialogUpdate(updateType: String, peerType: String, peerId: Int64, value: Bool): Unit {
        let normalizedPeerType = normalizeDialogPeerType(peerType)
        Hilog.info(0, "CjTelegram", "[UpdatesManager] DialogUpdate: type=${updateType}, peer=${normalizedPeerType}:${peerId}, value=${value}")
        getChatListProjection().applyDialogUpdate(updateType, normalizedPeerType, peerId, value)
    }

    /**
     * Phase P5-15: 跳过 DialogPeer (boxed)
     * dialogPeer#e56dbf05 peer:Peer → return peerId
     * dialogPeerFolder#514519e2 folder_id:int → return 0
     */
    private func parseDialogPeer(d: TLDeserializer): (String, Int64) {
        let ctor = d.readUInt32()
        if (ctor == 0xe56dbf05) {
            // dialogPeer#e56dbf05 peer:Peer
            let peer = PeerResponse.deserializeBoxed(d)
            return (normalizeDialogPeerType(peer.type_), peer.id)
        }
        if (ctor == 0x514519e2) {
            // dialogPeerFolder#514519e2 folder_id:int
            let _ = d.readInt32()
            return ("", 0)
        }
        return ("", 0)
    }

    // ==================== Phase R5: 编辑/删除分发 ====================
    
    /**
     * 将编辑的 TLMessage 转换为 Message 并推送到活跃的 ChatRoom
     */
    private func dispatchEditedMessages(tlMessages: ArrayList<TLMessage>): Unit {
        let msgService = getRealMessageService()
        let currentUserId = getCurrentUserId()
        for (tlMsg in tlMessages) {
            let userNames = HashMap<Int64, String>()
            let msg = msgService.parseMessage(tlMsg, currentUserId, userNames)
            
            let msgPeerType = extractPeerTypeFromTLMessage(tlMsg)
            let msgPeerId = extractPeerIdFromTLMessage(tlMsg)
            if (isConversationVisible(msgPeerType, msgPeerId)) {
                let subscribers = this.chatRoomEditSubscriberSnapshot()
                var index: Int64 = 0
                while (index < subscribers.size) {
                    try { subscribers[index](msg) } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[UpdatesManager] chatRoomEdit subscriber=${index} failed: ${e}")
                    }
                    index += 1
                }
            }
        }
    }
    
    /**
     * 推送删除的消息 ID 到活跃的 ChatRoom
     */
    private func dispatchDeletedMessages(ids: ArrayList<Int32>): Unit {
        let idList = ArrayList<Int64>()
        for (id in ids) { idList.add(Int64(id)) }
        this.applyDeletedMessagesToStore(idList)
        
        let subscribers = this.chatRoomDeleteSubscriberSnapshot()
        var index: Int64 = 0
        while (index < subscribers.size) {
            try { subscribers[index](idList) } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UpdatesManager] chatRoomDelete subscriber=${index} failed: ${e}")
            }
            index += 1
        }
    }
    
    /**
     * updateDeleteMessages 落本地消息表：对齐 iOS AccountStateManagementUtils 的 .deleteMessages →
     * transaction.deleteMessages(messageIdsForGlobalIds(ids))。不论会话是否正打开都要删，
     * 否则重进会话 / 冷启动时 local-first 读取会让对端已删的消息复活。
     * 表扫描放后台执行，不阻塞 updates 处理链。
     */
    private func applyDeletedMessagesToStore(ids: ArrayList<Int64>): Unit {
        if (ids.isEmpty()) { return }
        let copy = ArrayList<Int64>(ids)
        spawn {
            getMessageHistoryStore().removeMessagesByGlobalIds(copy)
        }
    }

    /** updates.difference 的 other_updates 中带回的 updateDeleteMessages（与实时推送同一应用链）。 */
    public func applyDifferenceDeletedMessages(ids: ArrayList<Int32>): Unit {
        if (ids.isEmpty()) { return }
        Hilog.info(0, "CjTelegram", "[UpdatesManager] Deleted messages from difference: ${ids.size}")
        this.dispatchDeletedMessages(ids)
    }

    // ==================== 状态查询 ====================
    
    public func getCurrentPts(): Int32 { return this.currentPts }
    public func getCurrentQts(): Int32 { return this.currentQts }
    public func getCurrentDate(): Int32 { return this.currentDate }
    public func getCurrentSeq(): Int32 { return this.currentSeq }
    public func isInitialized(): Bool { return this.stateInitialized }
    public func getGapCount(): Int32 { return this.gapCount }

    /** AccountUpdateCoordinator 用此状态把实时 batch 留在自己的 FIFO 中，直到补差完成。 */
    public func isDifferenceSyncInFlight(): Bool { return this._diffInFlight.load() }

    /**
     * Phase P4-11: Public method to force a getDifference sync.
     * Called from SettingsBackendPage "Sync Now" button.
     */
    public func forceDifference(): Unit {
        this.triggerDifferenceSync()
    }

    /**
     * 应用「自己发出的消息」回包里带的 pts —— 对齐 iOS。
     *
     * iOS 把 sendMessage 的返回结果和实时 update 走同一条状态机：
     * updateShortSentMessage 的 pts/pts_count 经 AccountStateManagementUtils
     * 一并提交进账号状态，本地 pts 因此始终与服务端同步。
     *
     * 我们此前把这两个字段解析出来就丢了（SendMessageResult.pts 无人消费），
     * 于是**每发一条消息本地 pts 就落后一格**。真机日志：
     *   [UpdatesManager] PTS gap detected: expected 878, got 879
     * 落后之后每一条实时 update 都被 checkAndUpdatePts 判成 gap 丢弃 ——
     * 其中就包括 updateReadHistoryOutbox，已读双勾因此永远等不到实时回执，
     * 只能靠会话列表刷新兜底（表现为「只更新上一条、最新一条不变」），
     * 同时每次 gap 还要触发一次全量 getDifference，持续抖动。
     */
    public func applySentMessagePts(pts: Int32, ptsCount: Int32): Unit {
        this.applyRpcResultPts("sent-message", pts, ptsCount)
    }

    /**
     * Apply pts/pts_count returned directly by an RPC result such as
     * messages.AffectedHistory or messages.AffectedMessages.
     */
    public func applyRpcResultPts(source: String, pts: Int32, ptsCount: Int32): Unit {
        if (pts <= 0) { return }
        let accepted = this.checkAndUpdatePts(pts, ptsCount)
        Hilog.info(0, "CjTelegram",
            "[UpdatesManager] ${source} pts=${pts} count=${ptsCount} accepted=${accepted} current=${this.currentPts}")
    }

    /**
     * 媒体 / 贴纸发送返回的是 Updates，其中的 pts 无法可靠顺序解析
     * （TL 变长编码，遇到不认识的 update 就算不出长度，见 parseSendMessageResponse 的说明）。
     * 对齐 iOS 在无法直接应用更新时的处理：转而补差，让状态由服务端权威重放，
     * 而不是留下一个会把后续所有 update 都变成 gap 的空洞。
     */
    public func requestDifferenceSync(): Unit {
        let _ = this.triggerDifferenceSyncAsync()
    }

    /**
     * 应用 updates.difference 的 other_updates 里带回的已读水位。
     *
     * 对齐 iOS：difference 中的 other_updates 与实时 update 走同一条应用链
     * （两者都落到 updatedState.readOutbox / readInbox），因此补差窗口内
     * 对方的已读回执不会丢。我们此前整段跳过 other_updates，补差期间的回执无处可取。
     */
    public func applyDifferenceReadStates(states: ArrayList<DifferenceReadState>): Unit {
        for (s in states) {
            if (s.peerId == 0) { continue }
            if (s.outgoing) {
                Hilog.info(0, "CjTelegram",
                    "[UpdatesManager] ReadOutbox from difference: peer=${s.peerId}, maxId=${s.maxId}")
                this.notifyReadOutbox(s.peerType, s.peerId, s.maxId)
            } else {
                this.notifyReadInbox(s.peerType, s.peerId, s.maxId, s.stillUnread)
            }
        }
    }
}


func isGroupCallUpdateCtor(ctor: UInt32): Bool {
    return ctor == 0xf2ebdb4e || ctor == 0x0b783982 || ctor == 0x97d64341 || ctor == 0x14b24500 || ctor == 0xd8326f0d
}


// 群里 Video Chat 的开始 / 人数变化 / 结束（updateGroupCall 推送）。聊天页顶部 JOIN 条据此即时
// 刷新，不必靠轮询 getFullChat。callId == 0 表示已结束。
// S2-12: updatePeerSettings 推送 → 当前打开的聊天页重算顶部栏（peerType, peerId, peerSettings flags）。
var _peerSettingsListener: Option<(String, Int64, Int32) -> Unit> = None

public func setPeerSettingsListener(cb: Option<(String, Int64, Int32) -> Unit>): Unit {
    _peerSettingsListener = cb
}

public func notifyPeerSettingsChanged(peerType: String, peerId: Int64, flags: Int32): Unit {
    match (_peerSettingsListener) {
        case Some(cb) => cb(peerType, peerId, flags)
        case None => ()
    }
}

var _activeGroupCallListener: Option<(Int64, Int64, Int64, Int32) -> Unit> = None

public func setActiveGroupCallListener(cb: Option<(Int64, Int64, Int64, Int32) -> Unit>): Unit {
    _activeGroupCallListener = cb
}

/**
 * 聊天页 JOIN 条的数据源。服务器只把"别人"引起的变化推过来；自己发起 / 结束通话的结果在 RPC 响应里，
 * 不经过 update 通道，所以本端操作成功后要自己调一次。
 */
public func notifyActiveGroupCallChanged(chatId: Int64, callId: Int64, accessHash: Int64, count: Int32): Unit {
    match (_activeGroupCallListener) {
        case Some(cb) => try { cb(chatId, callId, accessHash, count) } catch (_: Exception) {}
        case None => ()
    }
}
