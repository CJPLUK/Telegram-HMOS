package ohos_app_cangjie_entry.providers

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getMessagesService, TelegramEngine_MessagesService,
    ReadPositionRecord, MessageOperationResult
}
import ohos_app_cangjie_entry.models.*
import std.collection.ArrayList
import std.collection.HashMap

/**
 * MessagesDataProvider — 将消息引擎 API 数据转为 UI 可用的 ViewModel
 *
 * 对应 iOS TelegramEngine.Messages 的 UI 适配层:
 *   - 对话消息历史视图（MessageViewData）
 *   - 已读位置快照（ReadPositionSummary）
 *   - 消息操作结果状态（MessagesOperationState）
 *
 * 职责：
 * - 汇聚 TelegramEngine_MessagesService 的多次调用，组装 UI 需要的聚合视图
 * - 维护分页游标（offsetId）供无限滚动使用
 * - 提供消息操作状态（lastDeleteResult / lastForwardResult）供 UI toast/反馈
 * - 委托 MessagesService 执行 TL 调用，不直接接触 MTProtoClient
 */

// ==================== UI 视图数据模型 ====================

/**
 * 消息历史视图数据（聚合给 ChatRoom UI 使用）
 *
 * 对应 iOS TelegramEngine.Messages 组装出的消息视图状态:
 * - messages:    当前已加载的消息列表（时间正序）
 * - hasMore:     是否还有更早的消息（用于无限滚动触发）
 * - isLoading:   正在加载中
 * - errorMessage: 最近一次加载错误（空字符串 = 无错误）
 */
public class MessageViewData {
    public var messages: ArrayList<Message> = ArrayList<Message>()
    public var hasMore: Bool = false
    public var isLoading: Bool = false
    public var errorMessage: String = ""
    public var oldestMessageId: Int32 = 0    // 当前最旧消息 ID（分页锚点）
    public var newestMessageId: Int32 = 0    // 当前最新消息 ID

    public init() {}
}

/**
 * 已读位置摘要（UI 快速查询）
 *
 * 聚合单个对话的已读状态字段，供消息气泡"已读/未读"标记使用。
 */
public class ReadPositionSummary {
    public var peerId: Int64 = 0
    public var maxIncomingReadId: Int32 = 0
    public var maxOutgoingReadId: Int32 = 0
    public var unreadCount: Int32 = 0

    public init() {}

    public init(record!: ReadPositionRecord) {
        this.peerId = record.peerId
        this.maxIncomingReadId = record.maxIncomingReadId
        this.maxOutgoingReadId = record.maxOutgoingReadId
        this.unreadCount = record.unreadCount
    }
}

/**
 * 消息操作状态（删除/转发反馈）
 */
public class MessagesOperationState {
    public var lastDeleteResult: MessageOperationResult = MessageOperationResult()
    public var lastForwardResult: MessageOperationResult = MessageOperationResult()
    public var lastSearchResults: ArrayList<Message> = ArrayList<Message>()
    public var lastPinSuccess: Bool = false

    public init() {}
}

// ==================== MessagesDataProvider ====================

public class MessagesDataProvider {
    private let messagesService: TelegramEngine_MessagesService = getMessagesService()

    // ==================== 消息历史加载 ====================

    /**
     * 初始加载消息历史（最新 N 条）
     *
     * 对应 iOS ChatController 首次进入聊天时触发的历史加载:
     *   TelegramEngine.Messages.getHistory → parseMessages pipeline
     *
     * 调用链:
     *   loadInitialHistory → MessagesService.getHistory
     *                      → RealMessageService.getHistory → MessagesGetHistory.toBytes
     *                      → MTProtoClient.sendRequest → MessagesHistoryResponse.deserialize
     *                      → RealMessageService.parseMessages → ArrayList<Message>
     *
     * @param peerType      对话类型（user / chat / channel）
     * @param peerId        对话 ID
     * @param limit         最多加载消息数（默认 20）
     * @param currentUserId 当前登录用户 ID
     * @param photoPathCache 已下载照片路径缓存
     * @return MessageViewData — 包含消息列表及分页状态
     */
    public func loadInitialHistory(
        peerType: String,
        peerId: Int64,
        limit!: Int32 = 20,
        currentUserId!: Int64 = 0,
        photoPathCache!: HashMap<Int64, String> = HashMap<Int64, String>()
    ): MessageViewData {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] loadInitialHistory: peerType=${peerType}, peerId=${peerId}, limit=${limit}")
        let viewData = MessageViewData()
        viewData.isLoading = true

        // P2-287f: 本地优先（离线可读）。先读本地 MessageHistoryTable，命中即返回；
        // 本地空/不足则网络回源并回填。DB 不可用时该入口内部安全降级为纯网络。
        let messages = messagesService.getHistoryLocalFirst(
            peerType, peerId,
            limit: limit,
            offsetId: 0,
            currentUserId: currentUserId,
            photoPathCache: photoPathCache
        )

        viewData.isLoading = false
        viewData.messages = messages

        if (!messages.isEmpty()) {
            // oldestMessageId: 列表首条（最旧），用于向前翻页
            viewData.oldestMessageId = Int32(messages[0].id)
            // newestMessageId: 列表末条（最新）
            viewData.newestMessageId = Int32(messages[messages.size - 1].id)
        }

        // 若返回数量 == limit，通常还有更多历史消息
        viewData.hasMore = (Int32(messages.size) >= limit)

        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] loadInitialHistory: got ${messages.size} messages, hasMore=${viewData.hasMore}")
        return viewData
    }

    /**
     * 加载更早的历史消息（向上滚动翻页）
     *
     * 对应 iOS LoadMessagesIfNecessary — 滚动到顶时触发
     * 调用链:
     *   loadMoreHistory → MessagesService.getHistorySlice
     *                   → RealMessageService.getHistory(offsetId)
     *
     * @param peerType      对话类型
     * @param peerId        对话 ID
     * @param offsetId      当前最旧消息 ID（翻页锚点）
     * @param limit         最多加载消息数（默认 20）
     * @param currentUserId 当前用户 ID
     * @param photoPathCache 已下载照片路径缓存
     * @return MessageViewData — 包含更早的消息列表及分页状态
     */
    public func loadMoreHistory(
        peerType: String,
        peerId: Int64,
        offsetId: Int32,
        limit!: Int32 = 20,
        currentUserId!: Int64 = 0,
        photoPathCache!: HashMap<Int64, String> = HashMap<Int64, String>()
    ): MessageViewData {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] loadMoreHistory: peerType=${peerType}, peerId=${peerId}, offsetId=${offsetId}, limit=${limit}")
        let viewData = MessageViewData()
        viewData.isLoading = true

        // P2-287f: 本地优先翻页（离线可读）。offsetId 作为锚点，本地命中 earlierMessages 即返回；
        // 本地无锚点/不足则网络回源并回填。DB 不可用时安全降级为纯网络。
        let messages = messagesService.getHistoryLocalFirst(
            peerType, peerId,
            limit: limit,
            offsetId: offsetId,
            currentUserId: currentUserId,
            photoPathCache: photoPathCache
        )

        viewData.isLoading = false
        viewData.messages = messages

        if (!messages.isEmpty()) {
            viewData.oldestMessageId = Int32(messages[0].id)
            viewData.newestMessageId = Int32(messages[messages.size - 1].id)
        }

        viewData.hasMore = (Int32(messages.size) >= limit)

        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] loadMoreHistory: got ${messages.size} messages, hasMore=${viewData.hasMore}")
        return viewData
    }

    // ==================== 已读位置同步 ====================

    /**
     * 应用最大已读位置（普通聊天/私聊/群组）
     *
     * 对应 iOS _internal_applyMaxReadIndexInteractively → messages.readHistory
     * 调用链:
     *   markAsRead → MessagesService.applyMaxReadIndex
     *              → RealMessageService.markAsRead → MessagesReadHistory.toBytes
     *              → MTProtoClient.sendRequest
     *
     * @param peerType 对话类型（user / chat）
     * @param peerId   对话 ID
     * @param maxId    最大已读消息 ID（0 = 全部已读）
     */
    public func markAsRead(peerType: String, peerId: Int64, maxId: Int32): Unit {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] markAsRead: peerType=${peerType}, peerId=${peerId}, maxId=${maxId}")
        messagesService.applyMaxReadIndex(peerType, peerId, maxId)
    }

    /**
     * 应用最大已读位置（频道）
     *
     * 对应 iOS channels.readHistory → ChannelsReadHistory TL 方法
     * 调用链:
     *   markChannelAsRead → MessagesService.applyMaxReadIndexForChannel
     *                     → RealMessageService.markAsRead("channel") → ChannelsReadHistory.toBytes
     *
     * @param peerId 频道 ID
     * @param maxId  最大已读消息 ID
     */
    public func markChannelAsRead(peerId: Int64, maxId: Int32): Unit {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] markChannelAsRead: peerId=${peerId}, maxId=${maxId}")
        messagesService.applyMaxReadIndexForChannel(peerId, maxId)
    }

    /**
     * 更新已读位置缓存（来自服务器推送或 Dialog 拉取）
     *
     * 对应 iOS TelegramEngine 维护的 readInboxMaxId / readOutboxMaxId 状态
     *
     * @param peerId            对话 ID
     * @param peerType          对话类型
     * @param maxIncomingReadId 本端已读最大 ID（-1 = 不更新）
     * @param maxOutgoingReadId 对方已读最大 ID（-1 = 不更新）
     * @param unreadCount       当前未读数（-1 = 不更新）
     */
    public func updateReadPositionFromServer(
        peerId: Int64,
        peerType: String,
        maxIncomingReadId!: Int32 = -1,
        maxOutgoingReadId!: Int32 = -1,
        unreadCount!: Int32 = -1
    ): Unit {
        messagesService.updateReadPositionCache(
            peerId, peerType,
            maxIncomingReadId: maxIncomingReadId,
            maxOutgoingReadId: maxOutgoingReadId,
            unreadCount: unreadCount
        )
    }

    /**
     * 获取对话的已读位置摘要
     *
     * @param peerId 对话 ID
     * @return ReadPositionSummary（已读位置摘要）
     */
    public func getReadPositionSummary(peerId: Int64): ReadPositionSummary {
        let record = messagesService.getReadPosition(peerId)
        return ReadPositionSummary(record: record)
    }

    // ==================== 消息删除 ====================

    /**
     * 删除消息并返回操作结果
     *
     * 对应 iOS DeleteMessagesInteractively — 交互式（用户操作触发的）消息删除
     * 调用链:
     *   deleteMessages → MessagesService.deleteMessages
     *                  → RealMessageService.deleteMessages
     *                  → MessagesDeleteMessages/ChannelsDeleteMessages.toBytes
     *                  → MTProtoClient.sendRequest
     *
     * @param peerType   对话类型（user / chat / channel）
     * @param peerId     对话 ID
     * @param messageIds 要删除的消息 ID 列表
     * @param revoke     是否为双方删除，默认 true
     * @return MessagesOperationState（含 lastDeleteResult）
     */
    public func deleteMessages(
        peerType: String,
        peerId: Int64,
        messageIds: ArrayList<Int32>,
        revoke!: Bool = true
    ): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] deleteMessages: count=${messageIds.size}, revoke=${revoke}")
        let state = MessagesOperationState()
        state.lastDeleteResult = messagesService.deleteMessages(peerType, peerId, messageIds, revoke: revoke)
        return state
    }

    // ==================== 消息转发 ====================

    /**
     * 转发消息到另一个对话
     *
     * 对应 iOS messages.forwardMessages — TL 批量转发
     * 调用链:
     *   forwardMessages → MessagesService.forwardMessages
     *                   → RealMessageService.forwardMessages
     *                   → MessagesForwardMessages.toBytes → MTProtoClient.sendRequest
     *
     * @param fromPeerType 来源对话类型
     * @param fromPeerId   来源对话 ID
     * @param toPeerType   目标对话类型
     * @param toPeerId     目标对话 ID
     * @param messageIds   要转发的消息 ID 列表
     * @return MessagesOperationState（含 lastForwardResult）
     */
    public func forwardMessages(
        fromPeerType: String,
        fromPeerId: Int64,
        toPeerType: String,
        toPeerId: Int64,
        messageIds: ArrayList<Int32>
    ): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] forwardMessages: count=${messageIds.size}")
        let state = MessagesOperationState()
        state.lastForwardResult = messagesService.forwardMessages(fromPeerType, fromPeerId, toPeerType, toPeerId, messageIds)
        return state
    }

    // ==================== 消息搜索 ====================

    /**
     * 搜索聊天内消息，返回包含搜索结果的操作状态
     *
     * 对应 iOS messages.search → 关键词匹配历史消息
     * 调用链:
     *   searchMessages → MessagesService.searchMessages
     *                  → RealMessageService.searchMessages → MessagesSearch.toBytes
     *                  → MTProtoClient.sendRequest → MessagesHistoryResponse.deserialize
     *
     * @param peerType    对话类型
     * @param peerId      对话 ID
     * @param query       搜索关键词
     * @param limit       最多返回结果数（默认 20）
     * @param currentUserId 当前用户 ID
     * @return MessagesOperationState（含 lastSearchResults）
     */
    public func searchMessages(
        peerType: String,
        peerId: Int64,
        query: String,
        limit!: Int32 = 20,
        currentUserId!: Int64 = 0
    ): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] searchMessages: q=${query}")
        let state = MessagesOperationState()
        state.lastSearchResults = messagesService.searchMessages(
            peerType, peerId, query,
            limit: limit,
            currentUserId: currentUserId
        )
        return state
    }

    // ==================== 消息置顶 ====================

    /**
     * 置顶消息
     *
     * 对应 iOS messages.updatePinnedMessage
     * 调用链: pinMessage → MessagesService.pinMessage → RealMessageService.pinMessage
     *                    → MessagesUpdatePinnedMessage.toBytes → MTProtoClient.sendRequest
     */
    public func pinMessage(
        peerType: String,
        peerId: Int64,
        messageId: Int32,
        silent!: Bool = true
    ): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] pinMessage: peerType=${peerType}, peerId=${peerId}, msgId=${messageId}")
        let state = MessagesOperationState()
        state.lastPinSuccess = messagesService.pinMessage(peerType, peerId, messageId, silent: silent)
        return state
    }

    /**
     * 取消置顶消息
     */
    public func unpinMessage(
        peerType: String,
        peerId: Int64,
        messageId: Int32
    ): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] unpinMessage: peerType=${peerType}, peerId=${peerId}, msgId=${messageId}")
        let state = MessagesOperationState()
        state.lastPinSuccess = messagesService.unpinMessage(peerType, peerId, messageId)
        return state
    }

    // ==================== P2-150: Drafts ====================

    /**
     * 清除所有云端草稿
     *
     * 对应 iOS clearCloudDraftsInteractively → messages.clearAllDrafts
     */
    public func clearCloudDrafts(): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] clearCloudDrafts")
        let state = MessagesOperationState()
        let ok = messagesService.clearCloudDrafts()
        state.lastDeleteResult = MessageOperationResult(ok: ok, count: 0)
        return state
    }

    // ==================== P2-150: Polls ====================

    /**
     * 投票（对应 iOS messages.sendVote）
     *
     * @param peerType 对话类型
     * @param peerId   对话 ID
     * @param msgId    投票消息 ID
     * @param options  选项 bytes 列表（从 PollOptionData.optionData 取）
     */
    public func votePoll(
        peerType: String,
        peerId: Int64,
        msgId: Int32,
        options: ArrayList<Array<Byte>>
    ): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] votePoll: count=${options.size}")
        let state = MessagesOperationState()
        let ok = messagesService.votePoll(peerType, peerId, msgId, options)
        state.lastDeleteResult = MessageOperationResult(ok: ok, count: 0)
        return state
    }

    /**
     * 关闭投票（对应 iOS editMessage with closed poll）
     */
    public func closePoll(peerType: String, peerId: Int64, msgId: Int32): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] closePoll")
        let state = MessagesOperationState()
        let ok = messagesService.closePoll(peerType, peerId, msgId)
        state.lastDeleteResult = MessageOperationResult(ok: ok, count: 0)
        return state
    }

    // ==================== P2-150: Reactions ====================

    /**
     * 设置消息 Reaction（对应 iOS messages.sendReaction）
     *
     * emoji 非空 = 添加/切换；emoji="" = 移除
     */
    public func setReaction(
        peerType: String,
        peerId: Int64,
        msgId: Int32,
        emoji: String
    ): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] setReaction: emoji=${emoji}")
        let state = MessagesOperationState()
        let ok = messagesService.setReaction(peerType, peerId, msgId, emoji)
        state.lastDeleteResult = MessageOperationResult(ok: ok, count: 0)
        return state
    }

    /**
     * 移除消息 Reaction
     */
    public func deleteReaction(peerType: String, peerId: Int64, msgId: Int32): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] deleteReaction")
        let state = MessagesOperationState()
        let ok = messagesService.deleteReaction(peerType, peerId, msgId)
        state.lastDeleteResult = MessageOperationResult(ok: ok, count: 0)
        return state
    }

    /**
     * 获取消息 Reactions（对应 iOS messages.getMessagesReactions）
     */
    public func getMessagesReactions(
        peerType: String,
        peerId: Int64,
        messageIds: ArrayList<Int32>
    ): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] getMessagesReactions: count=${messageIds.size}")
        let state = MessagesOperationState()
        let ok = messagesService.getMessagesReactions(peerType, peerId, messageIds)
        state.lastDeleteResult = MessageOperationResult(ok: ok, count: 0)
        return state
    }

    // ==================== P2-150: Bulk operations ====================

    /**
     * 删除频道内某用户的所有消息（对应 iOS channels.deleteParticipantHistory）
     */
    public func deleteAllByAuthor(
        peerId: Int64,
        targetUserId: Int64,
        targetAccessHash: Int64
    ): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] deleteAllByAuthor: targetUser=${targetUserId}")
        let state = MessagesOperationState()
        let ok = messagesService.deleteAllByAuthor(peerId, targetUserId, targetAccessHash)
        state.lastDeleteResult = MessageOperationResult(ok: ok, count: 0)
        return state
    }

    /**
     * 清除对话历史（对应 iOS messages.deleteHistory）
     *
     * @param peerType  对话类型
     * @param peerId    对话 ID
     * @param maxId     清除到此消息 ID（0=全部）
     * @param justClear 是否仅本端清除
     * @param revoke    是否双端删除
     */
    public func clearHistory(
        peerType: String,
        peerId: Int64,
        maxId!: Int32 = 0,
        justClear!: Bool = false,
        revoke!: Bool = true
    ): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] clearHistory: peer=${peerType}/${peerId}")
        let state = MessagesOperationState()
        let ok = messagesService.clearHistory(peerType, peerId, maxId: maxId, justClear: justClear, revoke: revoke)
        state.lastDeleteResult = MessageOperationResult(ok: ok, count: 0)
        return state
    }

    /**
     * 全部已读（对应 iOS MarkAllChatsAsRead）
     *
     * 内部调用 readHistory(maxId=Int32.Max) + readMentions
     */
    public func markAllRead(peerType: String, peerId: Int64): MessagesOperationState {
        Hilog.info(0, "CjTelegram", "[MessagesDataProvider] markAllRead: peer=${peerType}/${peerId}")
        let state = MessagesOperationState()
        let ok = messagesService.markAllRead(peerType, peerId)
        state.lastDeleteResult = MessageOperationResult(ok: ok, count: 0)
        return state
    }
}
