package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashMap}
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.Message

/**
 * S5-04: 频道帖子的评论线程 / 群消息的回复线程（iOS ChatController subject .replyThread：
 * fetchChannelReplyThreadMessage → messages.getDiscussionMessage，随后 messages.getReplies）。
 */

/** messages.getDiscussionMessage#446972fd peer:InputPeer msg_id:int = messages.DiscussionMessage（iOS Api42.swift:7211） */
public class MessagesGetDiscussionMessage <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var msgId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x446972fd }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.msgId)
    }
}

/**
 * messages.getReplies#22ddd30c peer:InputPeer msg_id:int offset_id:int offset_date:int add_offset:int
 *   limit:int max_id:int min_id:int hash:long = messages.Messages（iOS Api42.swift:8109）
 */
public class MessagesGetReplies <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var msgId: Int32 = 0
    public var offsetId: Int32 = 0
    public var offsetDate: Int32 = 0
    public var addOffset: Int32 = 0
    public var limit: Int32 = 50
    public var maxId: Int32 = 0
    public var minId: Int32 = 0
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x22ddd30c }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.msgId)
        serializer.writeInt32(this.offsetId)
        serializer.writeInt32(this.offsetDate)
        serializer.writeInt32(this.addOffset)
        serializer.writeInt32(this.limit)
        serializer.writeInt32(this.maxId)
        serializer.writeInt32(this.minId)
        serializer.writeInt64(this.hash)
    }
}

/** 线程结果：讨论群里的根消息 + 回复列表（时间正序）。 */
public class MessageThreadResult {
    public var success: Bool = false
    public var errorMessage: String = ""
    /** 线程所在 peer（频道评论 → 讨论群 channel；群回复 → 群本身） */
    public var threadPeerType: String = "channel"
    public var threadPeerId: Int64 = 0
    public var rootMessageId: Int64 = 0
    public var rootMessage: Option<Message> = None
    public var replies: ArrayList<Message> = ArrayList<Message>()
    /**
     * iOS fetchChannelReplyThreadMessage isChannelPost: messages.discussionMessage carries the
     * channel post ahead of its discussion-group copy, so more than one message = comments thread.
     */
    public var isChannelPost: Bool = false
}

public class MessageThreadService {
    /**
     * messages.discussionMessage#a6341782 flags:# messages:Vector<Message> max_id:flags.0?int
     *   read_inbox_max_id:flags.1?int read_outbox_max_id:flags.2?int unread_count:int
     *   chats:Vector<Chat> users:Vector<User>（iOS Api36.swift:1195）
     */
    public func loadThread(peerType: String, peerId: Int64, messageId: Int64): MessageThreadResult {
        let result = MessageThreadResult()
        let msgSvc = getRealMessageService()
        let client = getMTProtoClient()
        let req = MessagesGetDiscussionMessage()
        req.peer = msgSvc.buildInputPeer(peerType, peerId)
        req.msgId = Int32(messageId)
        Hilog.info(0, "CjTelegram", "[MessageThread] getDiscussionMessage peer=${peerType}:${peerId} msg=${messageId}")
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            result.errorMessage = "empty response"
            return result
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == 0x2144ca19) {
            let code = d.readInt32()
            let text = d.readString()
            result.errorMessage = "${code}: ${text}"
            Hilog.info(0, "CjTelegram", "[MessageThread] getDiscussionMessage RPC error ${code} ${text}")
            return result
        }
        if (ctor != 0xa6341782) {
            result.errorMessage = "unexpected constructor ${ctor}"
            Hilog.info(0, "CjTelegram", "[MessageThread] unexpected constructor ${ctor}")
            return result
        }
        let flags = d.readInt32()
        let history = MessagesHistoryResponse()
        let vec = d.readUInt32()
        if (vec != TLConstructors.VECTOR) {
            result.errorMessage = "bad messages vector"
            return result
        }
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            history.messages.add(TLMessage.deserializeBoxed(d))
        }
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // max_id
        if ((flags & 2) != 0) { let _ = d.readInt32() }  // read_inbox_max_id
        if ((flags & 4) != 0) { let _ = d.readInt32() }  // read_outbox_max_id
        let _ = d.readInt32()  // unread_count
        let chatsVec = d.readUInt32()
        if (chatsVec == TLConstructors.VECTOR) {
            let chatsCount = d.readInt32()
            for (_i in 0..Int64(chatsCount)) { history.chats.add(ChatResponse.deserializeBoxed(d)) }
        }
        let usersVec = d.readUInt32()
        if (usersVec == TLConstructors.VECTOR) {
            let usersCount = d.readInt32()
            for (_i in 0..Int64(usersCount)) { history.users.add(UserResponse.deserializeBoxed(d)) }
        }
        let chatList = getRealChatListService()
        for (u in history.users) { chatList.cacheUserResponse(u) }
        for (c in history.chats) { chatList.cacheChatResponse(c) }
        if (history.messages.isEmpty()) {
            result.errorMessage = "no discussion message"
            return result
        }
        // iOS fetchChannelReplyThreadMessage: the last element is the message inside the
        // discussion group (the thread root); earlier ones are the channel post itself.
        let root = history.messages[history.messages.size - 1]
        result.isChannelPost = history.messages.size > 1
        result.threadPeerType = root.peerId.type_
        result.threadPeerId = root.peerId.id
        result.rootMessageId = Int64(root.id)
        let parsedRoots = msgSvc.parseMessages(history, getCurrentUserId(), HashMap<Int64, String>(),
            conversationPeerType: result.threadPeerType, conversationPeerId: result.threadPeerId)
        for (m in parsedRoots) {
            if (m.id == result.rootMessageId) { result.rootMessage = Some(m) }
        }
        Hilog.info(0, "CjTelegram", "[MessageThread] root ${result.threadPeerType}:${result.threadPeerId} msg=${result.rootMessageId} (${history.messages.size} msgs)")

        // Replies
        let repliesReq = MessagesGetReplies()
        repliesReq.peer = msgSvc.buildInputPeer(result.threadPeerType, result.threadPeerId)
        repliesReq.msgId = Int32(result.rootMessageId)
        repliesReq.limit = 50
        let repliesData = client.sendRequest(repliesReq.toBytes())
        if (repliesData.size >= 4) {
            let rd = TLDeserializer(repliesData)
            let rctor = rd.readUInt32()
            if (rctor == 0x2144ca19) {
                let code = rd.readInt32()
                let text = rd.readString()
                Hilog.info(0, "CjTelegram", "[MessageThread] getReplies RPC error ${code} ${text}")
            } else {
                let repliesHistory = MessagesHistoryResponse.deserialize(repliesData)
                for (u in repliesHistory.users) { chatList.cacheUserResponse(u) }
                for (c in repliesHistory.chats) { chatList.cacheChatResponse(c) }
                let parsed = msgSvc.parseMessages(repliesHistory, getCurrentUserId(), HashMap<Int64, String>(),
                    conversationPeerType: result.threadPeerType, conversationPeerId: result.threadPeerId)
                for (m in parsed) {
                    if (m.id != result.rootMessageId) { result.replies.add(m) }
                }
                Hilog.info(0, "CjTelegram", "[MessageThread] replies=${result.replies.size}")
            }
        }
        result.success = true
        return result
    }
}

private var _messageThreadService: Option<MessageThreadService> = None

public func getMessageThreadService(): MessageThreadService {
    match (_messageThreadService) {
        case Some(s) => return s
        case None =>
            let s = MessageThreadService()
            _messageThreadService = Some(s)
            return s
    }
}
