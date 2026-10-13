package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList

// =====================================================================
// TL Method: messages.getSponsoredMessages
// messages.getSponsoredMessages#3d6ce850 flags:# peer:InputPeer msgId:flags.0?int = messages.SponsoredMessages;
// Constructor: 0x3d6ce850  (Api42.swift:8056 appendInt32(1030547536), python: struct.unpack('<I',struct.pack('<i',1030547536)) => 0x3d6ce850)
// Namespace: messages. (NOT channels.)
// iOS: Api.functions.messages.getSponsoredMessages(flags:Int32, peer:Api.InputPeer, msgId:Int32?)
// =====================================================================
class MessagesGetSponsoredMessages <: TLObject {
    // peer represented as InputPeerChannel for channel-based sponsored messages
    public var channelId: Int64 = 0
    public var accessHash: Int64 = 0
    // flags: # (bare Int32); msgId is flags.0?int (optional, not used in basic call)
    public var flags: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x3d6ce850u32 }

    public func serialize(serializer: TLSerializer) {
        // flags: # (bare Int32, must be written first per iOS serialize order)
        serializer.writeInt32(this.flags)
        // peer: InputPeer  — for channel peers use InputPeerChannel#27bcbbfc (channel_id:long access_hash:long)
        let peer = InputPeerChannel()
        peer.channelId = this.channelId
        peer.accessHash = this.accessHash
        serializer.writeRawBytes(peer.toBytes())
        // msgId: flags.0?int — omitted when flags=0
    }
}

// =====================================================================
// TL Method: messages.viewSponsoredMessage
// messages.viewSponsoredMessage#269e3643 random_id:bytes = Bool;
// Constructor: 0x269e3643  (Api42.swift:10491 appendInt32(647902787), python: struct.unpack('<I',struct.pack('<i',647902787)) => 0x269e3643)
// Namespace: messages. (NOT channels.)
// iOS: Api.functions.messages.viewSponsoredMessage(randomId:Buffer)
// No channel/peer field — only random_id:bytes
// =====================================================================
class MessagesViewSponsoredMessage <: TLObject {
    public var randomId: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0x269e3643u32 }

    public func serialize(serializer: TLSerializer) {
        // random_id: bytes  (sole field per iOS Api42:10492)
        serializer.writeBytes(this.randomId)
    }
}

// =====================================================================
// TL Method: messages.clickSponsoredMessage
// messages.clickSponsoredMessage#8235057e flags:# random_id:bytes = Bool;
// Constructor: 0x8235057e  (Api42.swift:5745 appendInt32(-2110454402), python: struct.unpack('<I',struct.pack('<i',-2110454402)) => 0x8235057e)
// Namespace: messages. (NOT channels.)
// iOS: Api.functions.messages.clickSponsoredMessage(flags:Int32, randomId:Buffer)
// flags:# must be serialized FIRST (bare Int32), then random_id:bytes
// =====================================================================
class MessagesClickSponsoredMessage <: TLObject {
    // flags:# — bare Int32; no optional fields active in basic call so flags=0
    public var flags: Int32 = 0
    public var randomId: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0x8235057eu32 }

    public func serialize(serializer: TLSerializer) {
        // flags: # (bare Int32) — MUST be written first per iOS serialize order (Api42:5746)
        serializer.writeInt32(this.flags)
        // random_id: bytes (Api42:5747)
        serializer.writeBytes(this.randomId)
    }
}

// =====================================================================
// Model: SponsoredMessage
// Parsed from messages.SponsoredMessages response
// =====================================================================
public class SponsoredMessage {
    public var randomId: Array<Byte> = Array<Byte>(0, repeat: 0)
    // message: string (required) — 广告正文
    public var message: String = ""
    // url: flags.11?string — 跳转链接
    public var url: String = ""
    // button_text: string (required) — 按钮文本（如 "Open"）
    public var buttonText: String = ""
    // start_param: flags.0?string — bot deep-link 参数
    public var startParam: String = ""
    // sponsor_info: flags.7?string — 赞助商说明（可含 markdown 链接）
    public var sponsorInfo: String = ""
    // additional_info: flags.8?string — 附加说明
    public var additionalInfo: String = ""
    // from_id peer info (flags.3?Peer) — 来源频道/用户 id
    public var channelId: Int64 = 0
    public var channelAccessHash: Int64 = 0
    public var channelTitle: String = ""
}

// =====================================================================
// AdService singleton
// =====================================================================
private var _adServiceInstance: Option<AdService> = None

public func getAdService(): AdService {
    match (_adServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = AdService()
            _adServiceInstance = Some(inst)
            return inst
    }
}

/**
 * AdService — 赞助消息（广告）服务
 * 对应 Telegram iOS AdUI/Sources/AdInfoScreen.swift + TelegramCore sponsoredMessages API
 * 调用链: AdService → getMTProtoClient().sendRequest() → messages.getSponsoredMessages / viewSponsoredMessage / clickSponsoredMessage
 */
public class AdService {

    /**
     * 获取频道赞助消息列表
     * TL: messages.getSponsoredMessages#3d6ce850 flags:# peer:InputPeer msgId:flags.0?int = messages.SponsoredMessages
     * @param channelId   频道 peer id
     * @param accessHash  频道 access hash
     * @return SponsoredMessage 列表（通常0或1条）
     */
    public func getSponsoredMessages(channelId: Int64, accessHash: Int64): ArrayList<SponsoredMessage> {
        let client = getMTProtoClient()
        let req = MessagesGetSponsoredMessages()
        req.channelId = channelId
        req.accessHash = accessHash
        req.flags = 0

        Hilog.info(0, "CjTelegram", "[AdService] getSponsoredMessages channel=${channelId}")
        let responseData = client.sendRequest(req.toBytes())
        Hilog.info(0, "CjTelegram", "[AdService] getSponsoredMessages response size=${responseData.size}")

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[AdService] getSponsoredMessages empty response")
            return ArrayList<SponsoredMessage>()
        }

        let checkD = TLDeserializer(responseData)
        let checkConstructor = checkD.readUInt32()
        if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
            let errorCode = checkD.readInt32()
            let errorMsg = checkD.readString()
            Hilog.info(0, "CjTelegram", "[AdService] getSponsoredMessages RPC error ${errorCode}: ${errorMsg}")
            return ArrayList<SponsoredMessage>()
        }

        return parseSponsoredMessagesResponse(responseData)
    }

    /**
     * 标记赞助消息已查看
     * TL: messages.viewSponsoredMessage#269e3643 random_id:bytes = Bool
     * @param channelId   频道 peer id (retained for caller compatibility; not part of TL request)
     * @param accessHash  频道 access hash (retained for caller compatibility; not part of TL request)
     * @param randomId    消息 random_id bytes
     * @return true=成功
     */
    public func viewSponsoredMessage(channelId: Int64, accessHash: Int64, randomId: Array<Byte>): Bool {
        let client = getMTProtoClient()
        let req = MessagesViewSponsoredMessage()
        req.randomId = randomId

        Hilog.info(0, "CjTelegram", "[AdService] viewSponsoredMessage channel=${channelId} randomIdLen=${randomId.size}")
        let responseData = client.sendRequest(req.toBytes())
        Hilog.info(0, "CjTelegram", "[AdService] viewSponsoredMessage response size=${responseData.size}")

        if (responseData.size < 4) {
            return false
        }
        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        return constructor == TLConstructors.BOOL_TRUE
    }

    /**
     * 标记赞助消息已点击（用户主动点击广告链接）
     * TL: messages.clickSponsoredMessage#8235057e flags:# random_id:bytes = Bool
     * flags:# is bare Int32 serialized FIRST; no optional flags active in basic call (flags=0)
     * @param channelId   频道 peer id (retained for caller compatibility; not part of TL request)
     * @param accessHash  频道 access hash (retained for caller compatibility; not part of TL request)
     * @param randomId    消息 random_id bytes
     * @return true=成功
     */
    public func clickSponsoredMessage(channelId: Int64, accessHash: Int64, randomId: Array<Byte>): Bool {
        let client = getMTProtoClient()
        let req = MessagesClickSponsoredMessage()
        req.flags = 0
        req.randomId = randomId

        Hilog.info(0, "CjTelegram", "[AdService] clickSponsoredMessage channel=${channelId} randomIdLen=${randomId.size}")
        let responseData = client.sendRequest(req.toBytes())
        Hilog.info(0, "CjTelegram", "[AdService] clickSponsoredMessage response size=${responseData.size}")

        if (responseData.size < 4) {
            return false
        }
        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        return constructor == TLConstructors.BOOL_TRUE
    }

    /**
     * 解析 messages.SponsoredMessages 响应
     * messages.sponsoredMessages#c9EE1D87 flags:# posts_between:flags.0?int messages:Vector<SponsoredMessage> ...
     * Constructor: 0xc9ee1d87  (sponsoredMessages)  /  0x1839490f (sponsoredMessagesEmpty)
     * SponsoredMessage constructor: 0x3a836df8
     * fields: flags random_id:bytes from_id:?Peer chat_invite:?ChatInvite ... message:string ... url:?string
     */
    private func parseSponsoredMessagesResponse(data: Array<Byte>): ArrayList<SponsoredMessage> {
        let result = ArrayList<SponsoredMessage>()
        if (data.size < 4) {
            return result
        }
        let d = TLDeserializer(data)
        let responseConstructor = d.readUInt32()

        // sponsoredMessagesEmpty#1839490f — no ads
        if (responseConstructor == 0x1839490f) {
            Hilog.info(0, "CjTelegram", "[AdService] sponsoredMessagesEmpty — no sponsored messages")
            return result
        }

        // sponsoredMessages#c9ee1d87 flags:# posts_between:flags.0?int messages:Vector<SponsoredMessage> chats:Vector<Chat> users:Vector<User>
        if (responseConstructor != 0xc9ee1d87) {
            Hilog.info(0, "CjTelegram", "[AdService] Unknown sponsoredMessages constructor: ${responseConstructor}")
            return result
        }

        let flags = d.readUInt32()
        // posts_between is flags.0 optional int
        if ((flags & 1u32) != 0u32) {
            let _ = d.readInt32()
        }

        // messages: Vector<SponsoredMessage>
        let vecConstructor = d.readUInt32()
        if (vecConstructor != TLConstructors.VECTOR) {
            Hilog.info(0, "CjTelegram", "[AdService] Expected VECTOR for messages, got ${vecConstructor}")
            return result
        }
        let msgCount = d.readInt32()
        Hilog.info(0, "CjTelegram", "[AdService] Parsing ${msgCount} sponsored messages")

        var i: Int32 = 0
        while (i < msgCount) {
            let msgConstructor = d.readUInt32()
            // sponsoredMessage#3a836df8 flags:# ... random_id:bytes ...
            if (msgConstructor != 0x3a836df8) {
                Hilog.info(0, "CjTelegram", "[AdService] Unknown SponsoredMessage constructor: ${msgConstructor}, skipping rest")
                return result
            }
            let msgFlags = d.readUInt32()
            let sm = SponsoredMessage()
            // random_id: bytes
            sm.randomId = d.readBytes()
            // from_id: flags.3?Peer
            if ((msgFlags & 8u32) != 0u32) {
                // skip Peer (4 bytes constructor + fields)
                let _ = d.readUInt32()
                let _ = d.readInt64()
            }
            // chat_invite: flags.4?ChatInvite — skip if present (complex)
            if ((msgFlags & 16u32) != 0u32) {
                // ChatInvite is complex, skip string (invite hash)
                let _ = d.readString()
            }
            // chat_invite_hash: flags.4?string
            if ((msgFlags & 16u32) != 0u32) {
                let _ = d.readString()
            }
            // channel_post: flags.2?int
            if ((msgFlags & 4u32) != 0u32) {
                let _ = d.readInt32()
            }
            // start_param: flags.0?string
            if ((msgFlags & 1u32) != 0u32) {
                sm.startParam = d.readString()
            }
            // app: flags.9?BotApp — complex, skip
            // webpage: flags.10?SponsoredWebPage — complex, skip
            // message: string (required)
            sm.message = d.readString()
            // entities: flags.1?Vector<MessageEntity> — skip
            if ((msgFlags & 2u32) != 0u32) {
                let entVec = d.readUInt32()
                if (entVec == TLConstructors.VECTOR) {
                    let entCount = d.readInt32()
                    var ei: Int32 = 0
                    while (ei < entCount) {
                        let _ = d.readUInt32() // entity constructor
                        let _ = d.readInt32()  // offset
                        let _ = d.readInt32()  // length
                        ei += 1
                    }
                }
            }
            // url: flags.11?string
            if ((msgFlags & 2048u32) != 0u32) {
                sm.url = d.readString()
            }
            // button_text: string (required)
            sm.buttonText = d.readString()
            // sponsor_info: flags.7?string — 赞助商信息（可含 markdown 链接）
            if ((msgFlags & 128u32) != 0u32) {
                sm.sponsorInfo = d.readString()
            }
            // additional_info: flags.8?string — 附加说明
            if ((msgFlags & 256u32) != 0u32) {
                sm.additionalInfo = d.readString()
            }
            result.add(sm)
            i += 1
        }
        return result
    }
}
