package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.random.Random

/**
 * Chat Send Message Action 服务
 *
 * 对应 iOS ChatSendMessageActionUI：封装「发送选项菜单」的三种发送模式：
 *   - 定时发送（schedule_date）：messages.sendMessage flags bit 10 (0x400)
 *   - 静默发送（no notification）：messages.sendMessage flags bit 5 (0x20)
 *   - 消息效果（effect_id）：messages.sendMessage flags bit 14 (0x4000)
 *
 * TL Schema (messages.sendMessage#f2154152):
 *   flags:#
 *   no_webpage:flags.1?true
 *   silent:flags.5?true
 *   background:flags.6?true
 *   clear_draft:flags.7?true
 *   noforwards:flags.14?true
 *   update_stickersets_order:flags.15?true
 *   invert_media:flags.16?true
 *   allow_paid_floodskip:flags.19?true
 *   peer:InputPeer
 *   reply_to:flags.0?InputReplyTo
 *   message:string
 *   random_id:long
 *   reply_markup:flags.2?ReplyMarkup
 *   entities:flags.3?Vector<MessageEntity>
 *   schedule_date:flags.10?int
 *   send_as:flags.13?InputPeer
 *   quick_reply_shortcut:flags.17?InputQuickReplyShortcut
 *   effect:flags.18?long
 *
 * 调用链: ChatSendMessageActionService.sendXxx → MessagesSendMessageFull.toBytes()
 *          → getMTProtoClient().sendRequest() → parseSendMessageResponse()
 */

private var _chatSendMessageActionServiceInstance: Option<ChatSendMessageActionService> = None

public func getChatSendMessageActionService(): ChatSendMessageActionService {
    match (_chatSendMessageActionServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ChatSendMessageActionService()
            _chatSendMessageActionServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 发送选项菜单的发送结果，包含成功状态和服务端消息 ID
 */
public class SendActionResult {
    public var success: Bool = false
    public var messageId: Int32 = 0
    public var errorMessage: String = ""

    public init() {}
}

public class ChatSendMessageActionService {
    private static let _rand = Random()

    public init() {}

    /**
     * 静默发送消息（不给接收方发通知）
     *
     * TL flags bit 5 = 0x20 (silent:flags.5?true)
     *
     * @param peerType  "user" / "chat" / "channel"
     * @param peerId    目标对等方 ID
     * @param text      消息正文
     * @param replyToMsgId 回复的消息 ID（0 = 不回复）
     * @return SendActionResult
     */
    public func sendSilentMessage(
        peerType: String,
        peerId: Int64,
        text: String,
        replyToMsgId!: Int32 = 0
    ): SendActionResult {
        Hilog.info(0, "CjTelegram", "[ChatSendMsgActionSvc] sendSilentMessage: peerType=${peerType}, peerId=${peerId}")
        let req = MessagesSendMessageFull()
        req.peer = buildInputPeer(peerType, peerId)
        req.message = text
        req.randomId = generateRandomId()
        req.silent = true
        req.replyToMsgId = replyToMsgId
        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())
        return parseSendResponse(responseData, "sendSilentMessage")
    }

    /**
     * 定时发送消息
     *
     * TL flags bit 10 = 0x400 (schedule_date:flags.10?int)
     *
     * @param peerType     目标对等方类型
     * @param peerId       目标对等方 ID
     * @param text         消息正文
     * @param scheduleDate Unix 时间戳（UTC 秒数），消息将在此时刻发出
     * @param replyToMsgId 回复的消息 ID（0 = 不回复）
     * @return SendActionResult
     */
    public func sendScheduledMessage(
        peerType: String,
        peerId: Int64,
        text: String,
        scheduleDate: Int32,
        replyToMsgId!: Int32 = 0
    ): SendActionResult {
        Hilog.info(0, "CjTelegram", "[ChatSendMsgActionSvc] sendScheduledMessage: peerType=${peerType}, peerId=${peerId}, scheduleDate=${scheduleDate}")
        let req = MessagesSendMessageFull()
        req.peer = buildInputPeer(peerType, peerId)
        req.message = text
        req.randomId = generateRandomId()
        req.scheduleDate = scheduleDate
        req.replyToMsgId = replyToMsgId
        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())
        return parseSendResponse(responseData, "sendScheduledMessage")
    }

    /**
     * 带消息效果发送
     *
     * TL flags bit 18 = 0x40000 (effect:flags.18?long)
     * effect_id 为 Telegram 预定义的动画效果 ID（Premium 功能）。
     *
     * @param peerType   目标对等方类型
     * @param peerId     目标对等方 ID
     * @param text       消息正文
     * @param effectId   消息效果 ID
     * @param replyToMsgId 回复的消息 ID（0 = 不回复）
     * @return SendActionResult
     */
    public func sendMessageWithEffect(
        peerType: String,
        peerId: Int64,
        text: String,
        effectId: Int64,
        replyToMsgId!: Int32 = 0
    ): SendActionResult {
        Hilog.info(0, "CjTelegram", "[ChatSendMsgActionSvc] sendMessageWithEffect: peerType=${peerType}, peerId=${peerId}, effectId=${effectId}")
        let req = MessagesSendMessageFull()
        req.peer = buildInputPeer(peerType, peerId)
        req.message = text
        req.randomId = generateRandomId()
        req.effectId = effectId
        req.replyToMsgId = replyToMsgId
        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())
        return parseSendResponse(responseData, "sendMessageWithEffect")
    }

    // ==================== 私有辅助 ====================

    private func buildInputPeer(peerType: String, peerId: Int64): TLObject {
        if (peerType == "user") {
            let peer = InputPeerUser()
            peer.userId = peerId
            let msgSvc = getRealMessageService()
            peer.accessHash = msgSvc.getAccessHashForUser(peerId)
            return peer
        } else if (peerType == "chat") {
            let peer = InputPeerChat()
            peer.chatId = peerId
            return peer
        } else if (peerType == "channel") {
            let peer = InputPeerChannel()
            peer.channelId = peerId
            return peer
        }
        return InputPeerEmpty()
    }

    private func generateRandomId(): Int64 {
        let high = Int64(_rand.nextUInt32() & 0x7FFFFFFF)
        let low = Int64(_rand.nextUInt32())
        return (high << 32) | (low & 0xFFFFFFFF)
    }

    private func parseSendResponse(responseData: Array<Byte>, methodName: String): SendActionResult {
        let result = SendActionResult()
        if (responseData.size < 4) {
            result.errorMessage = "empty response"
            return result
        }
        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        // updateShortSentMessage
        if (constructor == 0x9db9e03c) {
            let _ = d.readInt32()  // flags
            let msgId = d.readInt32()
            let _ = d.readInt32()  // pts
            let _ = d.readInt32()  // pts_count
            let _ = d.readInt32()  // date
            result.success = true
            result.messageId = msgId
            return result
        }
        // updates / updatesCombined / updateShort
        if (constructor == 0x74ae4240 || constructor == 0x725b04c3 || constructor == 0x78d4dec1) {
            result.success = true
            return result
        }
        // rpc_error
        if (constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMsg = d.readString()
            result.errorMessage = "${errorCode}: ${errorMsg}"
            Hilog.info(0, "CjTelegram", "[ChatSendMsgActionSvc] ${methodName} RPC error: ${errorCode} - ${errorMsg}")
            return result
        }
        result.success = true
        return result
    }
}

// ==================== MessagesSendMessageFull TL 对象 ====================

/**
 * messages.sendMessage#f2154152 完整版
 *
 * 支持 silent / schedule_date / effect 三个扩展 flag：
 *   bit 5  (0x020):   silent
 *   bit 10 (0x400):   schedule_date
 *   bit 18 (0x40000): effect
 *
 * 回复通过 reply_to (flags bit 0) 携带 inputReplyToMessage#22c0f6d5
 */
public class MessagesSendMessageFull <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var message: String = ""
    public var randomId: Int64 = 0
    public var silent: Bool = false
    public var scheduleDate: Int32 = 0
    public var effectId: Int64 = 0
    public var replyToMsgId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xf2154152 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.replyToMsgId > 0) { flags = flags | 1 }       // bit 0: reply_to
        if (this.silent) { flags = flags | 32 }                 // bit 5: silent
        if (this.scheduleDate > 0) { flags = flags | 1024 }     // bit 10: schedule_date
        if (this.effectId != 0) { flags = flags | 262144 }      // bit 18: effect

        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())

        // reply_to: inputReplyToMessage#22c0f6d5
        if (this.replyToMsgId > 0) {
            serializer.writeUInt32(0x22c0f6d5)
            serializer.writeInt32(0)               // flags
            serializer.writeInt32(this.replyToMsgId)
        }

        serializer.writeString(this.message)
        serializer.writeInt64(this.randomId)

        // schedule_date
        if (this.scheduleDate > 0) {
            serializer.writeInt32(this.scheduleDate)
        }

        // effect
        if (this.effectId != 0) {
            serializer.writeInt64(this.effectId)
        }
    }
}
