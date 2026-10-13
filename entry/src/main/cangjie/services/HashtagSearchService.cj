package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.collection.HashMap
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.Message

/**
 * 话题标签搜索服务 (hashtag_search)
 *
 * 对应 iOS HashtagSearchUI：通过 messages.searchGlobal 在全局范围内
 * 搜索包含指定 hashtag 的消息。
 *
 * TL 调用链：
 *   searchHashtag(query) → getMTProtoClient().sendRequest(MessagesSearchGlobal.toBytes())
 *                        → MessagesHistoryResponse.deserialize()
 *                        → ArrayList<Message>
 *
 * 分页支持：offsetId / offsetRate 用于加载更多结果。
 */
public class HashtagSearchResult {
    public var messages: ArrayList<Message> = ArrayList<Message>()
    public var totalCount: Int32 = 0
    public var nextOffsetId: Int32 = 0
    public var nextOffsetRate: Int32 = 0
    public var hasMore: Bool = false
}

public class HashtagSearchService {

    /**
     * 全局 hashtag 消息搜索。
     *
     * 使用 messages.searchGlobal (constructor 0x4bc6589a)，以 hashtag 字符串为
     * 关键词在所有对话中查找包含该话题标签的消息。
     *
     * @param query  完整 hashtag（含 '#'，如 "#telegram"）
     * @param limit  每页数量，默认 20
     * @param offsetId  分页偏移消息 id（首次传 0）
     * @param offsetRate 分页偏移速率（来自上一次响应 nextOffsetRate，首次传 0）
     */
    public func searchHashtag(
        query: String,
        limit!: Int32 = 20,
        offsetId!: Int32 = 0,
        offsetRate!: Int32 = 0,
        publicPosts!: Bool = false
    ): HashtagSearchResult {
        Hilog.info(0, "CjTelegram", "[HashtagSearchService] searchHashtag query='${query}' limit=${limit} publicPosts=${publicPosts}")
        let result = HashtagSearchResult()

        if (query.isEmpty()) {
            return result
        }

        let client = getMTProtoClient()

        let req = MessagesSearchGlobal()
        req.q = query
        req.limit = limit
        req.offsetId = offsetId
        req.offsetRate = offsetRate
        // S050: 公开帖子作用域走 broadcasts_only，对位 iOS publicPosts:true
        req.broadcastsOnly = publicPosts

        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[HashtagSearchService] empty response")
            return result
        }

        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMsg = checkD.readString()
                Hilog.info(0, "CjTelegram", "[HashtagSearchService] RPC error ${errorCode}: ${errorMsg}")
                return result
            }
        }

        let historyResp = MessagesHistoryResponse.deserialize(responseData)
        result.totalCount = historyResp.count

        // 构建用户/聊天名称映射
        let userNameMap = HashMap<Int64, String>()
        let chatNameMap = HashMap<Int64, String>()
        for (u in historyResp.users) {
            var name = u.firstName
            if (u.lastName.size > 0) {
                name = "${name} ${u.lastName}"
            }
            userNameMap[u.id] = name
        }
        for (ch in historyResp.chats) {
            chatNameMap[ch.id] = ch.title
        }

        // 将 TLMessage 转换为 Message 模型
        for (tlMsg in historyResp.messages) {
            if (tlMsg.isEmpty || tlMsg.isService) {
                continue
            }
            let msg = Message()
            msg.id = Int64(tlMsg.id)
            msg.content = tlMsg.message
            msg.rawTimestamp = Int64(tlMsg.date)
            msg.time = formatMessageTime(Int64(tlMsg.date))
            msg.isSent = tlMsg.isOutgoing
            msg.senderId = tlMsg.peerId.id

            let peerId = tlMsg.peerId.id
            if (chatNameMap.contains(peerId)) {
                msg.senderName = chatNameMap[peerId]
            } else if (userNameMap.contains(peerId)) {
                msg.senderName = userNameMap[peerId]
            } else {
                msg.senderName = "${peerId}"
            }

            msg.messageType = if (tlMsg.mediaType.size > 0) { tlMsg.mediaType } else { "text" }
            msg.mediaDescription = tlMsg.mediaDescription
            msg.forwardFromName = tlMsg.fwdFromName
            msg.replyToMsgId = Int64(tlMsg.replyToMsgId)
            msg.isEdited = tlMsg.editDate > 0
            msg.views = Int64(tlMsg.views)

            result.messages.add(msg)
        }

        // 从 messagesSlice 的 nextRate 推断分页信息
        result.hasMore = result.messages.size >= Int64(limit)
        if (result.messages.size > 0) {
            let lastMsg = result.messages[result.messages.size - 1]
            result.nextOffsetId = Int32(lastMsg.id)
        }

        Hilog.info(0, "CjTelegram", "[HashtagSearchService] found ${result.messages.size} messages")
        return result
    }
}

// ==================== DI 单例 ====================

var _hashtagSearchService: Option<HashtagSearchService> = None

public func getHashtagSearchService(): HashtagSearchService {
    match (_hashtagSearchService) {
        case Some(svc) => return svc
        case None =>
            let svc = HashtagSearchService()
            _hashtagSearchService = Some(svc)
            return svc
    }
}
