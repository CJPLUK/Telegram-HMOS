package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.*
import std.collection.ArrayList
import std.collection.HashMap

/**
 * TelegramEngine_MessagesService — 消息引擎服务层
 *
 * 对应 iOS TelegramEngine.Messages 命名空间下的核心功能:
 *   - ApplyMaxReadIndexInteractively  → applyMaxReadIndex / applyMaxReadIndexForChannel
 *   - LoadMessagesIfNecessary / InstallInteractiveReadMessagesAction → interactiveReadMarker
 *   - DeleteMessages / DeleteMessagesInteractively → deleteMessages
 *   - ForwardGame / (ForwardMessages) → forwardMessages
 *   - messages.getHistory / messages.getHistorySlice → getHistory / getHistorySlice
 *
 * 设计：委托 RealMessageService 执行真实 TL 调用，
 * 本层只负责引擎语义封装（已读状态管理、消息历史视图、消息操作）。
 */

// ==================== 已读位置记录 ====================

/**
 * 已读位置快照
 *
 * 对应 iOS MessageIndex / IncomingMessageReadState 的最精简子集：
 * - peerId: 对话 ID
 * - peerType: 对话类型（user / chat / channel）
 * - maxIncomingReadId: 本端已读到的最大消息 ID（来自 readInboxMaxId）
 * - maxOutgoingReadId: 对方已读到的最大消息 ID（来自 readOutboxMaxId）
 * - unreadCount: 本对话未读数（来自 dialog.unreadCount）
 */
public class ReadPositionRecord {
    public var peerId: Int64 = 0
    public var peerType: String = ""
    public var maxIncomingReadId: Int32 = 0
    public var maxOutgoingReadId: Int32 = 0
    public var unreadCount: Int32 = 0

    public init() {}

    public init(
        peerId!: Int64,
        peerType!: String,
        maxIncomingReadId!: Int32,
        maxOutgoingReadId!: Int32,
        unreadCount!: Int32
    ) {
        this.peerId = peerId
        this.peerType = peerType
        this.maxIncomingReadId = maxIncomingReadId
        this.maxOutgoingReadId = maxOutgoingReadId
        this.unreadCount = unreadCount
    }
}

/**
 * 消息操作结果
 */
public class MessageOperationResult {
    public var success: Bool = false
    public var affectedCount: Int32 = 0
    public var errorMessage: String = ""

    public init() {}

    public init(ok!: Bool, count!: Int32) {
        this.success = ok
        this.affectedCount = count
    }
}

// ==================== 单例访问器 ====================

private var _messagesServiceInstance: Option<TelegramEngine_MessagesService> = None

public func getMessagesService(): TelegramEngine_MessagesService {
    match (_messagesServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramEngine_MessagesService()
            _messagesServiceInstance = Some(inst)
            return inst
    }
}

// ==================== TelegramEngine_MessagesService ====================

/**
 * 消息引擎服务
 *
 * 封装已读位置同步、消息历史加载、消息删除/转发等引擎层操作。
 * 所有 TL 网络调用委托给 getRealMessageService()。
 */
public class TelegramEngine_MessagesService {
    // 已读位置缓存 — peerId → ReadPositionRecord
    private var _readPositionCache: HashMap<Int64, ReadPositionRecord> = HashMap<Int64, ReadPositionRecord>()

    // ==================== 已读位置同步 ====================

    /**
     * 交互式应用最大已读位置（普通聊天/私聊/群组）
     *
     * 对应 iOS _internal_applyMaxReadIndexInteractively:
     *   stateManager.notifyAppliedIncomingReadMessages([index.id])
     *   → messages.readHistory(peer, maxId)
     *
     * 调用链:
     *   applyMaxReadIndex → RealMessageService.markAsRead → MessagesReadHistory.toBytes → MTProtoClient.sendRequest
     *
     * @param peerType 对话类型（user / chat）
     * @param peerId   对话 ID
     * @param maxId    最大已读消息 ID（0 = 读全部）
     */
    public func applyMaxReadIndex(peerType: String, peerId: Int64, maxId: Int32): Unit {
        Hilog.info(0, "CjTelegram", "[MessagesService] applyMaxReadIndex: peerType=${peerType}, peerId=${peerId}, maxId=${maxId}")
        updateReadPositionCache(peerId, peerType, maxIncomingReadId: maxId)
        // Match iOS Postbox's interactive read transaction: update the local read
        // state and chat-list projection in the same action that schedules the RPC.
        // The badge therefore disappears as soon as content is visible, and the
        // server acknowledgement only makes that optimistic state authoritative.
        getDialogReadStateStore().applyIncomingRead(peerType, peerId, maxId, 0)
        getChatListProjection().applyIncomingRead(peerType, peerId, 0)
        getRealMessageService().markAsRead(peerType, peerId, maxId)
    }

    /**
     * 交互式应用最大已读位置（频道）
     *
     * 对应 iOS channels.readHistory(channel, maxId)
     * 调用链:
     *   applyMaxReadIndexForChannel → RealMessageService.markAsRead(peerType="channel") → ChannelsReadHistory.toBytes
     *
     * @param peerId 频道 ID
     * @param maxId  最大已读消息 ID
     */
    public func applyMaxReadIndexForChannel(peerId: Int64, maxId: Int32): Unit {
        Hilog.info(0, "CjTelegram", "[MessagesService] applyMaxReadIndexForChannel: peerId=${peerId}, maxId=${maxId}")
        updateReadPositionCache(peerId, "channel", maxIncomingReadId: maxId)
        getDialogReadStateStore().applyIncomingRead("channel", peerId, maxId, 0)
        getChatListProjection().applyIncomingRead("channel", peerId, 0)
        getRealMessageService().markAsRead("channel", peerId, maxId)
    }

    /**
     * 更新本地已读位置缓存
     *
     * 仅在内存中维护，供 UI 快速查询当前已读状态，不写磁盘。
     */
    public func updateReadPositionCache(
        peerId: Int64,
        peerType: String,
        maxIncomingReadId!: Int32 = -1,
        maxOutgoingReadId!: Int32 = -1,
        unreadCount!: Int32 = -1
    ): Unit {
        let record = match (_readPositionCache.get(peerId)) {
            case Some(r) => r
            case None =>
                let r = ReadPositionRecord(
                    peerId: peerId,
                    peerType: peerType,
                    maxIncomingReadId: 0,
                    maxOutgoingReadId: 0,
                    unreadCount: 0
                )
                _readPositionCache[peerId] = r
                r
        }
        if (maxIncomingReadId >= 0) { record.maxIncomingReadId = maxIncomingReadId }
        if (maxOutgoingReadId >= 0) { record.maxOutgoingReadId = maxOutgoingReadId }
        if (unreadCount >= 0) { record.unreadCount = unreadCount }
    }

    /**
     * 获取对话的已读位置快照
     *
     * @param peerId 对话 ID
     * @return 已读位置记录，若无缓存则返回空记录
     */
    public func getReadPosition(peerId: Int64): ReadPositionRecord {
        match (_readPositionCache.get(peerId)) {
            case Some(r) => return r
            case None => return ReadPositionRecord()
        }
    }

    // ==================== 消息历史视图 ====================

    /**
     * 加载消息历史
     *
     * 对应 iOS messages.getHistory → MessagesHistoryResponse → parseMessages pipeline
     * 调用链:
     *   getHistory → RealMessageService.getHistory → MessagesGetHistory.toBytes → MTProtoClient.sendRequest
     *               → MessagesHistoryResponse.deserialize → parseMessages → ArrayList<Message>
     *
     * @param peerType  对话类型（user / chat / channel）
     * @param peerId    对话 ID
     * @param limit     最多返回消息数，默认 20
     * @param offsetId  从此消息 ID 之前加载（分页，0 = 最新）
     * @param currentUserId 当前用户 ID（用于 isSent 标记）
     * @param photoPathCache 已下载照片路径缓存
     * @return 按时间正序排列的 Message 列表
     */
    public func getHistory(
        peerType: String,
        peerId: Int64,
        limit!: Int32 = 20,
        offsetId!: Int32 = 0,
        currentUserId!: Int64 = 0,
        photoPathCache!: HashMap<Int64, String> = HashMap<Int64, String>()
    ): ArrayList<Message> {
        Hilog.info(0, "CjTelegram", "[MessagesService] getHistory: peerType=${peerType}, peerId=${peerId}, limit=${limit}, offsetId=${offsetId}")
        let msgService = getRealMessageService()
        let historyResponse = msgService.getHistory(peerType, peerId, limit: limit, offsetId: offsetId)
        if (historyResponse.messages.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[MessagesService] getHistory: empty response")
            return ArrayList<Message>()
        }
        let messages = msgService.parseMessages(historyResponse, currentUserId, photoPathCache)
        Hilog.info(0, "CjTelegram", "[MessagesService] getHistory: parsed ${messages.size} messages")
        return messages
    }

    /**
     * 加载更早的消息历史（向前翻页）
     *
     * 对应 iOS LoadMessagesIfNecessary — 滚动到顶端时触发历史消息加载
     * 调用链：getHistorySlice → RealMessageService.getHistory(offsetId=oldestMessageId)
     *
     * @param peerType      对话类型
     * @param peerId        对话 ID
     * @param offsetId      已有最旧消息的 ID（作为分页锚点）
     * @param limit         最多加载消息数，默认 20
     * @param currentUserId 当前用户 ID
     * @param photoPathCache 已下载照片路径缓存
     * @return 更早的消息列表（按时间正序）
     */
    public func getHistorySlice(
        peerType: String,
        peerId: Int64,
        offsetId: Int32,
        limit!: Int32 = 20,
        currentUserId!: Int64 = 0,
        photoPathCache!: HashMap<Int64, String> = HashMap<Int64, String>()
    ): ArrayList<Message> {
        Hilog.info(0, "CjTelegram", "[MessagesService] getHistorySlice: peerType=${peerType}, peerId=${peerId}, offsetId=${offsetId}, limit=${limit}")
        return getHistory(
            peerType,
            peerId,
            limit: limit,
            offsetId: offsetId,
            currentUserId: currentUserId,
            photoPathCache: photoPathCache
        )
    }

    // ==================== 本地优先消息历史（离线可读，P2-287f）====================

    /**
     * 本地优先加载消息历史（初始/翻页统一入口）。
     *
     * 委托 RealMessageService.getHistoryLocalFirst：先读本地 MessageHistoryTable，命中即返回
     * （离线可读）；本地空/不足则网络回源并回填本地。DB 不可用时安全降级为纯网络。
     *
     * 与 getHistory 的对外语义一致（返回时间正序 ArrayList<Message>），仅多了本地持久化闭环。
     * 原 getHistory / getHistorySlice（纯网络）保留不变作为回退路径。
     */
    public func getHistoryLocalFirst(
        peerType: String,
        peerId: Int64,
        limit!: Int32 = 20,
        offsetId!: Int32 = 0,
        currentUserId!: Int64 = 0,
        photoPathCache!: HashMap<Int64, String> = HashMap<Int64, String>()
    ): ArrayList<Message> {
        Hilog.info(0, "CjTelegram", "[MessagesService] getHistoryLocalFirst: peerType=${peerType}, peerId=${peerId}, limit=${limit}, offsetId=${offsetId}")
        return getRealMessageService().getHistoryLocalFirst(
            peerType,
            peerId,
            limit: limit,
            offsetId: offsetId,
            currentUserId: currentUserId,
            photoPathCache: photoPathCache
        )
    }

    // ==================== 消息删除 ====================

    /**
     * 删除消息（交互式，对应 iOS DeleteMessagesInteractively）
     *
     * 根据对话类型选择 messages.deleteMessages 或 channels.deleteMessages。
     * 调用链:
     *   deleteMessages → RealMessageService.deleteMessages
     *                  → MessagesDeleteMessages/ChannelsDeleteMessages.toBytes
     *                  → MTProtoClient.sendRequest
     *
     * @param peerType   对话类型（user / chat / channel）
     * @param peerId     对话 ID
     * @param messageIds 要删除的消息 ID 列表
     * @param revoke     是否为双方删除（revoke=true），默认 true
     * @return MessageOperationResult
     */
    public func deleteMessages(
        peerType: String,
        peerId: Int64,
        messageIds: ArrayList<Int32>,
        revoke!: Bool = true
    ): MessageOperationResult {
        Hilog.info(0, "CjTelegram", "[MessagesService] deleteMessages: peerType=${peerType}, peerId=${peerId}, count=${messageIds.size}, revoke=${revoke}")
        if (messageIds.isEmpty()) {
            return MessageOperationResult(ok: true, count: 0)
        }
        let ok = getRealMessageService().deleteMessages(peerType, peerId, messageIds, revoke: revoke)
        let result = MessageOperationResult(ok: ok, count: if (ok) { Int32(messageIds.size) } else { 0 })
        if (!ok) { result.errorMessage = "deleteMessages failed" }
        Hilog.info(0, "CjTelegram", "[MessagesService] deleteMessages: success=${ok}")
        return result
    }

    // ==================== 消息转发 ====================

    /**
     * 转发消息到另一个对话
     *
     * 对应 iOS messages.forwardMessages — TL 批量转发
     * 调用链:
     *   forwardMessages → RealMessageService.forwardMessages
     *                   → MessagesForwardMessages.toBytes → MTProtoClient.sendRequest
     *
     * @param fromPeerType 来源对话类型
     * @param fromPeerId   来源对话 ID
     * @param toPeerType   目标对话类型
     * @param toPeerId     目标对话 ID
     * @param messageIds   要转发的消息 ID 列表
     * @return MessageOperationResult
     */
    public func forwardMessages(
        fromPeerType: String,
        fromPeerId: Int64,
        toPeerType: String,
        toPeerId: Int64,
        messageIds: ArrayList<Int32>
    ): MessageOperationResult {
        Hilog.info(0, "CjTelegram", "[MessagesService] forwardMessages: from=${fromPeerType}/${fromPeerId}, to=${toPeerType}/${toPeerId}, count=${messageIds.size}")
        if (messageIds.isEmpty()) {
            return MessageOperationResult(ok: true, count: 0)
        }
        let ok = getRealMessageService().forwardMessages(fromPeerType, fromPeerId, toPeerType, toPeerId, messageIds)
        let result = MessageOperationResult(ok: ok, count: if (ok) { Int32(messageIds.size) } else { 0 })
        if (!ok) { result.errorMessage = "forwardMessages failed" }
        Hilog.info(0, "CjTelegram", "[MessagesService] forwardMessages: success=${ok}")
        return result
    }

    // ==================== 消息搜索 ====================

    /**
     * 搜索聊天内消息
     *
     * 对应 iOS messages.search — 在指定对话内按关键词搜索消息
     * 调用链:
     *   searchMessages → RealMessageService.searchMessages
     *                  → MessagesSearch.toBytes → MTProtoClient.sendRequest
     *
     * @param peerType    对话类型
     * @param peerId      对话 ID
     * @param query       搜索关键词
     * @param limit       最多返回结果数，默认 20
     * @param offsetId    分页锚点，默认 0
     * @param currentUserId 当前用户 ID
     * @return 匹配的消息列表（按时间正序）
     */
    public func searchMessages(
        peerType: String,
        peerId: Int64,
        query: String,
        limit!: Int32 = 20,
        offsetId!: Int32 = 0,
        currentUserId!: Int64 = 0
    ): ArrayList<Message> {
        Hilog.info(0, "CjTelegram", "[MessagesService] searchMessages: peerType=${peerType}, peerId=${peerId}, q=${query}")
        let msgService = getRealMessageService()
        let historyResponse = msgService.searchMessages(peerType, peerId, query, limit: limit, offsetId: offsetId)
        if (historyResponse.messages.isEmpty()) {
            return ArrayList<Message>()
        }
        let messages = msgService.parseMessages(historyResponse, currentUserId, HashMap<Int64, String>())
        Hilog.info(0, "CjTelegram", "[MessagesService] searchMessages: found ${messages.size} messages")
        return messages
    }

    // ==================== 消息置顶 ====================

    /**
     * 置顶消息
     *
     * 对应 iOS messages.updatePinnedMessage — 置顶指定消息
     * 调用链: pinMessage → RealMessageService.pinMessage → MessagesUpdatePinnedMessage.toBytes
     *
     * @param peerType  对话类型
     * @param peerId    对话 ID
     * @param messageId 要置顶的消息 ID
     * @param silent    是否静默（不通知成员），默认 true
     * @return 是否成功
     */
    public func pinMessage(
        peerType: String,
        peerId: Int64,
        messageId: Int32,
        silent!: Bool = true
    ): Bool {
        Hilog.info(0, "CjTelegram", "[MessagesService] pinMessage: peerType=${peerType}, peerId=${peerId}, msgId=${messageId}")
        return getRealMessageService().pinMessage(peerType, peerId, messageId, silent: silent)
    }

    /**
     * 取消置顶消息
     *
     * 调用链: unpinMessage → RealMessageService.unpinMessage → MessagesUpdatePinnedMessage(unpin=true).toBytes
     */
    public func unpinMessage(peerType: String, peerId: Int64, messageId: Int32): Bool {
        Hilog.info(0, "CjTelegram", "[MessagesService] unpinMessage: peerType=${peerType}, peerId=${peerId}, msgId=${messageId}")
        return getRealMessageService().unpinMessage(peerType, peerId, messageId)
    }

    // ==================== P2-150: Drafts ====================

    /**
     * 清除所有云端草稿（对应 iOS clearCloudDraftsInteractively）
     *
     * 调用链:
     *   clearCloudDrafts → RealMessageService.clearCloudDrafts
     *                    → MessagesClearAllDrafts.toBytes → MTProtoClient.sendRequest
     *
     * @return 是否成功
     */
    public func clearCloudDrafts(): Bool {
        Hilog.info(0, "CjTelegram", "[MessagesService] clearCloudDrafts")
        return getRealMessageService().clearCloudDrafts()
    }

    // ==================== P2-150: Polls ====================

    /**
     * 投票（对应 iOS messages.sendVote）
     *
     * 调用链:
     *   votePoll → RealMessageService.votePoll → MessagesSendVote.toBytes → MTProtoClient
     *
     * @param peerType 对话类型
     * @param peerId   对话 ID
     * @param msgId    投票消息 ID
     * @param options  选项 bytes（从 PollOptionData.optionData 取，服务端 opaque bytes）
     * @return 是否成功
     */
    public func votePoll(peerType: String, peerId: Int64, msgId: Int32, options: ArrayList<Array<Byte>>): Bool {
        Hilog.info(0, "CjTelegram", "[MessagesService] votePoll: peer=${peerType}/${peerId}, msgId=${msgId}")
        return getRealMessageService().votePoll(peerType, peerId, msgId, options)
    }

    /**
     * 关闭投票（对应 iOS editMessage with closed poll）
     *
     * @param peerType 对话类型
     * @param peerId   对话 ID
     * @param msgId    投票消息 ID
     * @return 是否成功
     */
    public func closePoll(peerType: String, peerId: Int64, msgId: Int32): Bool {
        Hilog.info(0, "CjTelegram", "[MessagesService] closePoll: peer=${peerType}/${peerId}, msgId=${msgId}")
        return getRealMessageService().closePoll(peerType, peerId, msgId)
    }

    // ==================== P2-150: Reactions ====================

    /**
     * 设置消息 Reaction（对应 iOS messages.sendReaction）
     *
     * emoji 非空 = 添加/切换 reaction；emoji="" = 移除
     * 调用链: setReaction → RealMessageService.setReaction → MessagesSendReaction.toBytes
     *
     * @param peerType 对话类型
     * @param peerId   对话 ID
     * @param msgId    消息 ID
     * @param emoji    Reaction emoji（如 "👍"、"❤️"）；空字符串移除
     * @return 是否成功
     */
    public func setReaction(peerType: String, peerId: Int64, msgId: Int32, emoji: String): Bool {
        Hilog.info(0, "CjTelegram", "[MessagesService] setReaction: peer=${peerType}/${peerId}, msgId=${msgId}, emoji=${emoji}")
        return getRealMessageService().setReaction(peerType, peerId, msgId, emoji)
    }

    /**
     * 移除消息 Reaction（对应 iOS messages.sendReaction 空 emoji）
     */
    public func deleteReaction(peerType: String, peerId: Int64, msgId: Int32): Bool {
        Hilog.info(0, "CjTelegram", "[MessagesService] deleteReaction: peer=${peerType}/${peerId}, msgId=${msgId}")
        return getRealMessageService().removeReaction(peerType, peerId, msgId)
    }

    /**
     * 获取消息 Reactions（对应 iOS messages.getMessagesReactions）
     *
     * @param peerType   对话类型
     * @param peerId     对话 ID
     * @param messageIds 要查询的消息 ID 列表
     * @return 是否成功
     */
    public func getMessagesReactions(peerType: String, peerId: Int64, messageIds: ArrayList<Int32>): Bool {
        Hilog.info(0, "CjTelegram", "[MessagesService] getMessagesReactions: peer=${peerType}/${peerId}, count=${messageIds.size}")
        return getRealMessageService().getMessagesReactions(peerType, peerId, messageIds)
    }

    // ==================== P2-150: Bulk operations ====================

    /**
     * 删除频道内某用户的所有消息（对应 iOS channels.deleteParticipantHistory）
     *
     * 仅适用于 supergroup / channel（peerType="channel"）。
     * 调用链: deleteAllByAuthor → RealMessageService.deleteAllByAuthor
     *                          → ChannelsDeleteParticipantHistory.toBytes → MTProtoClient
     *
     * @param peerId          频道/超级群 ID
     * @param targetUserId    目标用户 ID
     * @param targetAccessHash 目标用户 accessHash
     * @return 是否成功
     */
    public func deleteAllByAuthor(peerId: Int64, targetUserId: Int64, targetAccessHash: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[MessagesService] deleteAllByAuthor: peerId=${peerId}, targetUser=${targetUserId}")
        return getRealMessageService().deleteAllByAuthor(peerId, targetUserId, targetAccessHash)
    }

    /**
     * 清除对话历史（对应 iOS messages.deleteHistory）
     *
     * 调用链: clearHistory → RealMessageService.clearHistory → MessagesDeleteHistory.toBytes
     *
     * @param peerType  对话类型
     * @param peerId    对话 ID
     * @param maxId     清除到此消息 ID（0=全部）
     * @param justClear 是否仅本端清除
     * @param revoke    是否双端删除
     * @return 是否成功
     */
    public func clearHistory(peerType: String, peerId: Int64, maxId!: Int32 = 0, justClear!: Bool = false, revoke!: Bool = true): Bool {
        Hilog.info(0, "CjTelegram", "[MessagesService] clearHistory: peer=${peerType}/${peerId}, maxId=${maxId}")
        return getRealMessageService().clearHistory(peerType, peerId, maxId: maxId, justClear: justClear, revoke: revoke)
    }

    /**
     * 全部已读（对应 iOS MarkAllChatsAsRead — messages.readHistory + messages.readMentions）
     *
     * 调用链: markAllRead → RealMessageService.markAllRead
     *                     → MessagesReadHistory/ChannelsReadHistory + MessagesReadMentions
     *
     * @param peerType 对话类型
     * @param peerId   对话 ID
     * @return 是否成功
     */
    public func markAllRead(peerType: String, peerId: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[MessagesService] markAllRead: peer=${peerType}/${peerId}")
        return getRealMessageService().markAllRead(peerType, peerId)
    }

    // ==================== 辅助 ====================

    /**
     * 清空已读位置缓存（登出/切换账号时使用）
     */
    public func clearReadPositionCache(): Unit {
        _readPositionCache = HashMap<Int64, ReadPositionRecord>()
        Hilog.info(0, "CjTelegram", "[MessagesService] clearReadPositionCache")
    }
}
