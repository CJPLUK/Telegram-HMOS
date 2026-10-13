package ohos_app_cangjie_entry.core.mtproto

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import std.collection.ArrayList
/**
 * TL Dialog 和 Message 类型定义
 * 
 * 对应 TelegramHarmony 的 TLDialogs.ets
 * 用于解析 messages.getDialogs 和消息历史响应
 */

// ==================== Dialog 类型 ====================

public class TLDialog {
    public var peer: PeerResponse = PeerResponse()
    public var topMessage: Int32 = 0
    public var readInboxMaxId: Int32 = 0
    public var readOutboxMaxId: Int32 = 0
    public var unreadCount: Int32 = 0
    public var unreadMentionsCount: Int32 = 0
    public var unreadReactionsCount: Int32 = 0
    public var isPinned: Bool = false
    public var isMarkedUnread: Bool = false
    public var folderId: Int32 = 0
    public var pts: Int32 = 0
    // Phase Q9: 草稿消息文本
    public var draft: String = ""
    // iOS parity: 静音截止时间戳（Unix 秒；>now 表示静音中）——驱动会话行静音图标 + 徽章灰
    public var muteUntil: Int32 = 0

    public static func deserializeBoxed(d: TLDeserializer): TLDialog {
        let r = TLDialog()
        let constructor = d.readUInt32()

        if (constructor == 0xfc89f7f3 || constructor == 0xd58a08c6) {
            // dialog#fc89f7f3 (current, iOS dict[-58066957], Api5.swift:1709 parse_dialog) /
            // dialog#d58a08c6 (legacy layer, telegram_api.tl:218 — this is the ctor actually
            // observed on the wire from this server's getDialogs response).
            //
            // BUGFIX (device offset-instrumented, 2026-07-04): these two constructors do NOT
            // share the same field layout. #fc89f7f3 (current iOS layer) inserted a mandatory
            // unread_poll_votes_count:int field between unread_reactions_count and
            // notify_settings; #d58a08c6 (telegram_api.tl:218, no iOS dict entry — confirmed by
            // grepping Api0.swift, which only registers -58066957) has NO such field:
            //   dialog#d58a08c6 flags:# ... unread_reactions_count:int notify_settings:PeerNotifySettings ...
            // Raw getDialogs bytes confirmed on-device: at the offset immediately following
            // unread_reactions_count, the next 4 bytes are 0x99622c0c (peerNotifySettings ctor)
            // directly — there is no extra Int32 in between. Previously this code
            // unconditionally consumed an extra Int32 "unread_poll_votes_count" for BOTH
            // constructors, which desynced the deserializer by 4 bytes for every dialog sent
            // with the legacy #d58a08c6 ctor: notify_settings was mis-parsed as
            // {ctor=0(garbage), flags=peerNotifySettings' real ctor}, silently "succeeding" with
            // flags=0x99622c0c (many bits set) but actually just re-consuming the real ctor bytes
            // and desyncing the rest of the stream — the very next dialog's ctor field ended up
            // reading mid-struct garbage (`0x00000008` instead of 0xd58a08c6), which then
            // corrupted the following messages vector length too (observed on-device as
            // "[TLMessage] Unknown message constructor: 0").
            //
            // iOS Api5.swift:1709 parse_dialog field order (for #fc89f7f3 ONLY):
            //   flags(Int32), peer(boxed), top_message(Int32), read_inbox_max_id(Int32),
            //   read_outbox_max_id(Int32), unread_count(Int32), unread_mentions_count(Int32),
            //   unread_reactions_count(Int32), unread_poll_votes_count(Int32),
            //   notify_settings(boxed PeerNotifySettings),
            //   pts?[flags.0], draft?[flags.1], folder_id?[flags.4], ttl_period?[flags.5]
            let flags = d.readInt32()
            r.isPinned = (flags & 4) != 0
            r.isMarkedUnread = (flags & 8) != 0

            r.peer = PeerResponse.deserializeBoxed(d)
            r.topMessage = d.readInt32()
            r.readInboxMaxId = d.readInt32()
            r.readOutboxMaxId = d.readInt32()
            r.unreadCount = d.readInt32()
            r.unreadMentionsCount = d.readInt32()
            r.unreadReactionsCount = d.readInt32()
            // unread_poll_votes_count — mandatory field ONLY in the current #fc89f7f3 layer.
            // The legacy #d58a08c6 wire ctor (still sent by some servers/layers) does not have
            // this field; reading it unconditionally desyncs the rest of the response.
            if (constructor == 0xfc89f7f3) {
                let _ = d.readInt32() // unread_poll_votes_count
            }

            // PeerNotifySettings（解析 muteUntil，不再整段丢弃）
            r.muteUntil = skipPeerNotifySettings(d)

            if ((flags & 1) != 0) { r.pts = d.readInt32() }
            // Phase Q9: 解析草稿消息（不再丢弃）
            if ((flags & 2) != 0) { r.draft = parseDraftMessageCapture(d) }
            if ((flags & 16) != 0) { r.folderId = d.readInt32() }
            if ((flags & 32) != 0) { let _ = d.readInt32() } // ttl_period
        } else if (constructor == 0x71bd134c) {
            // dialogFolder - 匹配 TelegramHarmony 结构
            skipDialogFolder(d)
        }

        return r
    }
}

// 返回 muteUntil（Unix 秒；0=不静音，>now=静音中）。此前整段跳过导致 isMuted 恒 false、
// 未读徽章恒蓝——iOS 静音会话徽章应为灰色。
func skipPeerNotifySettings(d: TLDeserializer): Int32 {
    // 严格匹配 TelegramHarmony：不检查 constructor，直接读取 flags 和字段
    // 所有版本的 PeerNotifySettings 都使用相同的字段布局
    var _muteUntil: Int32 = 0
    let _ = d.readUInt32()  // constructor（不检查值）
    let flags = d.readInt32()
    // showPreviews - bit 0, Api.Bool (boxed = UInt32)
    if ((flags & 1) != 0) { let _ = d.readUInt32() }
    // silent - bit 1, Api.Bool (boxed)
    if ((flags & 2) != 0) { let _ = d.readUInt32() }
    // muteUntil - bit 2, Int32
    if ((flags & 4) != 0) { _muteUntil = d.readInt32() }
    // iosSound - bit 3
    if ((flags & 8) != 0) { skipNotificationSound(d) }
    // androidSound - bit 4
    if ((flags & 16) != 0) { skipNotificationSound(d) }
    // otherSound - bit 5
    if ((flags & 32) != 0) { skipNotificationSound(d) }
    // storiesMuted - bit 6, Api.Bool (boxed)
    if ((flags & 64) != 0) { let _ = d.readUInt32() }
    // storiesHideSender - bit 7, Api.Bool (boxed)
    if ((flags & 128) != 0) { let _ = d.readUInt32() }
    // storiesIosSound - bit 8
    if ((flags & 256) != 0) { skipNotificationSound(d) }
    // storiesAndroidSound - bit 9
    if ((flags & 512) != 0) { skipNotificationSound(d) }
    // storiesOtherSound - bit 10
    if ((flags & 1024) != 0) { skipNotificationSound(d) }
    return _muteUntil
}

func skipNotificationSound(d: TLDeserializer): Unit {
    // 严格匹配 TelegramHarmony
    let constructor = d.readUInt32()
    if (constructor == 0x97e8bebe) {
        // notificationSoundDefault - 无字段
    } else if (constructor == 0x6f0c34df) {
        // notificationSoundNone - 无字段
    } else if (constructor == 0x830b9ae4) {
        // notificationSoundLocal - title:string data:string
        let _ = d.readString()
        let _ = d.readString()
    } else if (constructor == 0xff6c8049) {
        // notificationSoundRingtone - id:long
        let _ = d.readInt64()
    }
}

/**
 * Phase Q9: 解析 DraftMessage 并返回草稿文本
 * 
 * draftMessageEmpty#1b0c841a — 无草稿
 * draftMessage#96eaa5eb (Layer 214) — 包含草稿文本
 * draftMessage#96c0e2a8 (旧版) — 同上
 */
func parseDraftMessageCapture(d: TLDeserializer): String {
    let constructor = d.readUInt32()
    if (constructor == 0x1b0c841a) {
        // draftMessageEmpty
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt32() } // date
        return ""
    }
    // draftMessage#96eaa5eb / #96c0e2a8 / #3fccf7ef
    let flags = d.readInt32()
    if ((flags & 16) != 0) { skipInputReplyTo(d) }  // reply_to - bit 4
    let message = d.readString()  // 草稿文本
    if ((flags & 8) != 0) { skipMessageEntitiesVector(d) }  // entities - bit 3
    if ((flags & 32) != 0) { skipInputMedia(d) }  // media - bit 5
    let _ = d.readInt32()  // date
    if ((flags & 128) != 0) { let _ = d.readInt64() }  // effect - bit 7
    if ((flags & 256) != 0) { skipSuggestedPost(d) }  // suggestedPost - bit 8 (iOS Api6.swift:669)
    if ((flags & 512) != 0) {  // richMessage - bit 9 (iOS Api6.swift:675)
        let _ = d.readUInt32()  // RichMessage boxed ctor
        skipRichMessage(d)
    }
    return message
}

func skipDraftMessage(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x1b0c841a) {
        // draftMessageEmpty
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt32() } // date
        return
    }
    // draftMessage#96eaa5eb (Layer 214) / #96c0e2a8 (old) / #3fccf7ef (older)
    // 严格匹配 TelegramHarmony - 所有版本的字段布局相同
    let flags = d.readInt32()
    if ((flags & 16) != 0) { skipInputReplyTo(d) }  // reply_to - bit 4
    let _ = d.readString()  // message
    if ((flags & 8) != 0) { skipMessageEntitiesVector(d) }  // entities - bit 3
    if ((flags & 32) != 0) { skipInputMedia(d) }  // media - bit 5
    let _ = d.readInt32()  // date
    if ((flags & 128) != 0) { let _ = d.readInt64() }  // effect - bit 7
    if ((flags & 256) != 0) { skipSuggestedPost(d) }  // suggestedPost - bit 8 (iOS Api6.swift:669)
    if ((flags & 512) != 0) {  // richMessage - bit 9 (iOS Api6.swift:675)
        let _ = d.readUInt32()  // RichMessage boxed ctor
        skipRichMessage(d)
    }
}

func skipInputReplyTo(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x3bd4b7c2) {
        // inputReplyToMessage#3bd4b7c2 (current iOS layer; Api0.swift dict[1003796418] →
        // Api13.swift parse_inputReplyToMessage:191-249). The previous ctor 0x22c0f6d5 + 5-field
        // layout matched an OUTDATED telegram_api.tl snapshot (input/.../third-party/td/.../telegram_api.tl:1667).
        // BUGFIX: when a draft's reply_to actually carries this (current) ctor, the old code fell
        // through to the "unknown variant" branch and consumed 0 bytes — silently desyncing every
        // subsequent TL value in the same getDialogs response, mirroring the dialog-ctor bug fixed
        // in c0c71d26, except silent instead of crashing.
        // Ground-truth 10-field layout (flags-gated fields marked with their bit):
        //   flags:# replyToMsgId:int
        //   topMsgId:flags.0?int  replyToPeerId:flags.1?InputPeer
        //   quoteText:flags.2?string  quoteEntities:flags.3?Vector<MessageEntity>
        //   quoteOffset:flags.4?int  monoforumPeerId:flags.5?InputPeer
        //   todoItemId:flags.6?int  pollOption:flags.7?bytes
        let flags = d.readInt32()
        let _ = d.readInt32()  // replyToMsgId
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // topMsgId - bit 0
        if ((flags & 2) != 0) { skipInputPeer(d) }  // replyToPeerId (InputPeer) - bit 1
        if ((flags & 4) != 0) { let _ = d.readBytes() }  // quoteText (TL string/bytes wire format) - bit 2
        if ((flags & 8) != 0) { skipMessageEntitiesVector(d) }  // quoteEntities - bit 3
        if ((flags & 16) != 0) { let _ = d.readInt32() }  // quoteOffset - bit 4
        if ((flags & 32) != 0) { skipInputPeer(d) }  // monoforumPeerId (InputPeer) - bit 5
        if ((flags & 64) != 0) { let _ = d.readInt32() }  // todoItemId - bit 6
        if ((flags & 128) != 0) { let _ = d.readBytes() }  // pollOption - bit 7
        return
    }
    if (constructor == 0x5881323a) {
        // inputReplyToStory#5881323a peer:InputPeer story_id:int
        // (Api0.swift dict[1484862010] → Api13.swift parse_inputReplyToStory:264-279). Ctor already
        // correct from prior fix; also corrected to use skipInputPeer (was PeerResponse.deserializeBoxed,
        // which parses bare Peer ctors [peerUser/peerChat/peerChannel], not InputPeer ctors
        // [inputPeerUser/inputPeerChat/inputPeerChannel/inputPeerSelf/inputPeerEmpty] — wrong ctor
        // namespace means this branch would also silently mis-consume bytes on a real story reply-to).
        skipInputPeer(d)  // peer (InputPeer)
        let _ = d.readInt32()  // storyId
        return
    }
    if (constructor == 0x69d66c45) {
        // inputReplyToMonoForum#69d66c45 monoforumPeerId:InputPeer
        // (Api0.swift dict[1775660101] → Api13.swift parse_inputReplyToMonoForum:251-263). Not
        // previously handled at all; added for completeness alongside the other two variants.
        skipInputPeer(d)  // monoforumPeerId (InputPeer)
        return
    }
    // Unknown InputReplyTo variant — log so future schema drift is visible, matching the
    // "unknown InputMedia" safety pattern used elsewhere in this file.
    Hilog.info(0, "CjTelegram", "[skipInputReplyTo] Unknown InputReplyTo ctor: 0x${toHex32(constructor)}, cannot safely skip")
}

// -------- Inner helpers for skipInputMedia --------

// inputPhoto#3bb3b94a id:long access_hash:long file_reference:bytes
// inputPhotoEmpty#1cd7bf0d — no fields
func skipBoxedInputPhoto(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x1cd7bf0d) { return }  // inputPhotoEmpty
    // inputPhoto#3bb3b94a
    let _ = d.readInt64()  // id
    let _ = d.readInt64()  // access_hash
    let _ = d.readBytes()  // file_reference
}

// inputDocument#1abfb575 id:long access_hash:long file_reference:bytes
// inputDocumentEmpty#72f0eaae — no fields
func skipBoxedInputDocument(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x72f0eaae) { return }  // inputDocumentEmpty
    // inputDocument#1abfb575
    let _ = d.readInt64()  // id
    let _ = d.readInt64()  // access_hash
    let _ = d.readBytes()  // file_reference
}

// inputFile#f52ff27f id:long parts:int name:string md5_checksum:string
// inputFileBig#fa4f0bb5 id:long parts:int name:string
func skipBoxedInputFile(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    let _ = d.readInt64()  // id
    let _ = d.readInt32()  // parts
    let _ = d.readString()  // name
    if (ctor == 0xf52ff27f) {
        let _ = d.readString()  // md5_checksum (inputFile only)
    }
}

// inputGeoPoint#48222faf flags:# lat:double long:double accuracy_radius?[0]:int
// inputGeoPointEmpty#e4c123d6 — no fields
func skipBoxedInputGeoPoint(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xe4c123d6) { return }  // inputGeoPointEmpty
    let flags = d.readInt32()
    let _ = d.readDouble()  // lat
    let _ = d.readDouble()  // long
    if ((flags & 1) != 0) { let _ = d.readInt32() }  // accuracy_radius
}

// inputDocument vector skip
func skipVectorInputDocument(d: TLDeserializer): Unit {
    let vecCtor = d.readUInt32()
    if (vecCtor != TLConstructors.VECTOR) { return }
    let count = d.readInt32()
    for (_ in 0..Int64(count)) {
        skipBoxedInputDocument(d)
    }
}

// InputUser polymorphic skip (TL schema: telegram_api.tl)
// inputUser#f21158c6        user_id:long access_hash:long
// inputUserEmpty#b98886cf   — no fields
// inputUserSelf#f7c1b13f    — no fields
// inputUserFromMessage#1da448e2 peer:InputPeer msg_id:int user_id:long
func skipBoxedInputUser(d: TLDeserializer): Unit {
    let userCtor = d.readUInt32()
    if (userCtor == 0xf21158c6) {
        // inputUser: userId:long access_hash:long
        let _ = d.readInt64()
        let _ = d.readInt64()
    } else if (userCtor == 0x1da448e2) {
        // inputUserFromMessage: peer:InputPeer msg_id:int user_id:long
        skipInputPeer(d)
        let _ = d.readInt32()
        let _ = d.readInt64()
    }
    // inputUserEmpty#b98886cf / inputUserSelf#f7c1b13f: 0 fields, fall through
}

// Main InputMedia skip — covers all common variants (iOS Api11.swift, Api0.swift dict entries)
func skipInputMedia(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    // inputMediaEmpty#9664f57f — no fields
    if (constructor == 0x9664f57f) { return }

    // inputMediaPhoto#e3af4434 flags:# id:InputPhoto ttl_seconds?[0]:int video?[2]:InputDocument
    if (constructor == 0xe3af4434) {
        let flags = d.readInt32()
        skipBoxedInputPhoto(d)
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // ttl_seconds
        if ((flags & 4) != 0) { skipBoxedInputDocument(d) }  // video
        return
    }

    // inputMediaDocument#a8763ab5 flags:# id:InputDocument video_cover?[3]:InputPhoto
    //   video_timestamp?[4]:int ttl_seconds?[0]:int query?[1]:string
    if (constructor == 0xa8763ab5) {
        let flags = d.readInt32()
        skipBoxedInputDocument(d)
        if ((flags & 8) != 0) { skipBoxedInputPhoto(d) }   // video_cover
        if ((flags & 16) != 0) { let _ = d.readInt32() }  // video_timestamp
        if ((flags & 1) != 0) { let _ = d.readInt32() }   // ttl_seconds
        if ((flags & 2) != 0) { let _ = d.readString() }  // query
        return
    }

    // inputMediaUploadedPhoto#7d8375da flags:# file:InputFile stickers?[0]:Vector<InputDocument>
    //   ttl_seconds?[1]:int video?[3]:InputDocument
    if (constructor == 0x7d8375da) {
        let flags = d.readInt32()
        skipBoxedInputFile(d)
        if ((flags & 1) != 0) { skipVectorInputDocument(d) }  // stickers
        if ((flags & 2) != 0) { let _ = d.readInt32() }       // ttl_seconds
        if ((flags & 8) != 0) { skipBoxedInputDocument(d) }   // video
        return
    }

    // inputMediaUploadedDocument#037c9330 flags:# file:InputFile thumb?[2]:InputFile mime_type:string
    //   attributes:Vector<DocumentAttribute> stickers?[0]:Vector<InputDocument>
    //   video_cover?[6]:InputPhoto video_timestamp?[7]:int ttl_seconds?[1]:int
    if (constructor == 0x037c9330) {
        let flags = d.readInt32()
        skipBoxedInputFile(d)
        if ((flags & 4) != 0) { skipBoxedInputFile(d) }         // thumb
        let _ = d.readString()                                   // mime_type
        // attributes: Vector<DocumentAttribute>
        let attrVecCtor = d.readUInt32()
        if (attrVecCtor == TLConstructors.VECTOR) {
            let attrCount = d.readInt32()
            for (_ in 0..Int64(attrCount)) { skipDocumentAttribute(d) }
        }
        if ((flags & 1) != 0) { skipVectorInputDocument(d) }    // stickers
        if ((flags & 64) != 0) { skipBoxedInputPhoto(d) }       // video_cover
        if ((flags & 128) != 0) { let _ = d.readInt32() }       // video_timestamp
        if ((flags & 2) != 0) { let _ = d.readInt32() }         // ttl_seconds
        return
    }

    // inputMediaGeoPoint#f9c44144 geo_point:InputGeoPoint
    if (constructor == 0xf9c44144) {
        skipBoxedInputGeoPoint(d)
        return
    }

    // inputMediaGeoLive#971fa843 flags:# geo_point:InputGeoPoint heading?[2]:int period?[1]:int
    //   proximity_notification_radius?[3]:int
    if (constructor == 0x971fa843) {
        let flags = d.readInt32()
        skipBoxedInputGeoPoint(d)
        if ((flags & 4) != 0) { let _ = d.readInt32() }  // heading
        if ((flags & 2) != 0) { let _ = d.readInt32() }  // period
        if ((flags & 8) != 0) { let _ = d.readInt32() }  // proximity_notification_radius
        return
    }

    // inputMediaContact#f8ab7dfb phone_number:string first_name:string last_name:string vcard:string
    if (constructor == 0xf8ab7dfb) {
        let _ = d.readString()  // phone_number
        let _ = d.readString()  // first_name
        let _ = d.readString()  // last_name
        let _ = d.readString()  // vcard
        return
    }

    // inputMediaDice#e66fbf7b emoticon:string
    if (constructor == 0xe66fbf7b) {
        let _ = d.readString()  // emoticon
        return
    }

    // inputMediaWebPage#c21b8849 flags:# url:string
    if (constructor == 0xc21b8849) {
        let _ = d.readInt32()   // flags
        let _ = d.readString()  // url
        return
    }

    // inputMediaPhotoExternal#e5bbfe1a flags:# url:string ttl_seconds?[0]:int
    if (constructor == 0xe5bbfe1a) {
        let flags = d.readInt32()
        let _ = d.readString()
        if ((flags & 1) != 0) { let _ = d.readInt32() }
        return
    }

    // inputMediaDocumentExternal#779600f9 flags:# url:string ttl_seconds?[0]:int
    //   video_cover?[2]:InputPhoto video_timestamp?[3]:int
    if (constructor == 0x779600f9) {
        let flags = d.readInt32()
        let _ = d.readString()
        if ((flags & 1) != 0) { let _ = d.readInt32() }
        if ((flags & 4) != 0) { skipBoxedInputPhoto(d) }
        if ((flags & 8) != 0) { let _ = d.readInt32() }
        return
    }

    // inputMediaPoll#883a4108 flags:# poll:Poll correct_answers?[0]:Vector<bytes>
    //   attached_media?[3]:InputMedia solution?[1]:string solution_entities?[1]:Vector<MessageEntity>
    //   solution_media?[2]:InputMedia
    if (constructor == 0x883a4108) {
        let flags = d.readInt32()
        skipPoll(d)  // boxed Poll (ctor already NOT read yet — skipPoll reads its ctor internally)
        if ((flags & 1) != 0) {  // correct_answers: Vector<bytes>
            let bytesVecCtor = d.readUInt32()
            if (bytesVecCtor == TLConstructors.VECTOR) {
                let bytesCount = d.readInt32()
                for (_ in 0..Int64(bytesCount)) { let _ = d.readBytes() }
            }
        }
        if ((flags & 8) != 0) { skipInputMedia(d) }            // attached_media (recursive)
        if ((flags & 2) != 0) { let _ = d.readString() }       // solution
        if ((flags & 2) != 0) { skipMessageEntitiesVector(d) } // solution_entities
        if ((flags & 4) != 0) { skipInputMedia(d) }            // solution_media (recursive)
        return
    }

    // inputMediaStory#89fdd778 peer:InputPeer id:int
    if (constructor == 0x89fdd778) {
        skipInputPeer(d)
        let _ = d.readInt32()  // id
        return
    }

    // inputMediaGame#d33f43f3 id:InputGame
    // InputGame is either inputGameID (53231223=0x032c3e77) or inputGameShortName (-1020139510=0xc331e80a)
    if (constructor == 0xd33f43f3) {
        let gameCtor = d.readUInt32()
        if (gameCtor == 0x032c3e77) {
            // inputGameID chat_id:long access_hash:long
            let _ = d.readInt64()
            let _ = d.readInt64()
        } else {
            // inputGameShortName#c331e80a bot_id:InputUser short_name:string
            skipBoxedInputUser(d)
            let _ = d.readString()  // short_name
        }
        return
    }

    // Unknown InputMedia — log and do not consume further (safest for unknown future variants)
    Hilog.info(0, "CjTelegram", "[skipInputMedia] Unknown InputMedia ctor: 0x${toHex32(constructor)}, cannot safely skip")
}

func skipDialogFolder(d: TLDeserializer): Unit {
    // 严格匹配 TelegramHarmony 的 skipDialogFolder
    let flags = d.readInt32()
    // skipFolder (boxed)
    let _ = d.readUInt32() // folder constructor
    let folderFlags = d.readInt32()
    let _ = d.readInt32() // id
    let _ = d.readString() // title
    if ((folderFlags & 8) != 0) { skipChatPhoto(d) } // photo
    // 继续 DialogFolder 的其余字段
    let _ = PeerResponse.deserializeBoxed(d)  // peer
    let _ = d.readInt32()  // topMessage
    let _ = d.readInt32()  // unreadMutedPeersCount
    let _ = d.readInt32()  // unreadUnmutedPeersCount
    let _ = d.readInt32()  // unreadMutedMessagesCount
    let _ = d.readInt32()  // unreadUnmutedMessagesCount
}

// ==================== Message 类型 ====================

public class TLMessage {
    public var id: Int32 = 0
    public var fromId: Option<PeerResponse> = None
    public var peerId: PeerResponse = PeerResponse()
    public var date: Int32 = 0
    public var message: String = ""
    public var isOutgoing: Bool = false
    public var isEmpty: Bool = false
    public var isService: Bool = false
    // P2-113: human-readable service action text ("Alice joined the group", etc.)
    public var serviceText: String = ""
    public var serviceScheduleDate: Int64 = 0   // messageActionGroupCallScheduled.schedule_date
    // messageActionChatDeleteUser 的 user_id：与发送者不同即"A removed B"
    public var actionUserId: Int64 = 0
    // messageActionChatAddUser 的 users：组 "A invited B, C"
    public var actionUserIds: ArrayList<Int64> = ArrayList<Int64>()
    // messageActionChatMigrateTo / messageActionChannelMigrateFrom（iOS .groupMigratedToChannel /
    // .channelMigratedFromGroup）：ChatHistoryEntriesForView.swift:230 不出气泡，
    // ServiceMessageStrings.swift:436 文案为空，AccountStateManager.swift:2431 不通知。
    public var isMigrationAction: Bool = false
    // messageActionChatMigrateTo.channel_id：基础群升级成的超级群
    public var migratedToChannelId: Int64 = 0
    // P2-113: album grouped id (flags bit 17); 0 = not grouped
    public var groupedId: Int64 = 0

    // Phase A2 新增: 媒体/转发/回复/编辑信息
    public var mediaType: String = ""         // photo/video/voice/audio/document/sticker/gif/location/contact/poll
    public var mediaDescription: String = ""  // "[Photo]", "[Video]", "[Voice Message]", etc.
    public var invoiceTitle: String = ""
    public var invoiceDescription: String = ""
    public var invoiceCurrency: String = ""
    public var invoiceTotalAmount: Int64 = 0
    public var invoiceStartParam: String = ""
    public var invoiceReceiptMsgId: Int32 = 0
    public var invoicePaymentButtonTitle: String = ""
    public var fwdFromName: String = ""       // 转发来源名称
    // messageMediaContact#70322949 phone_number / first_name / last_name（S2-96）
    public var contactPhone: String = ""
    public var contactFirstName: String = ""
    public var contactLastName: String = ""
    // fwd_from 头的归属信息（iOS StoreMessage_Telegram.swift:1172-1217 → forwardInfo / SourceAuthorInfoMessageAttribute），
    // 供 Saved Messages 判定方向（iOS MessageUtils.swift:348 effectivelyIncoming）。
    public var hasForwardInfo: Bool = false   // iOS forwardInfo != nil：from_id / post_author / from_name 任一存在
    public var fwdFromPeerId: Int64 = 0       // from_id（非 channel 时为 authorId）
    public var fwdFromPeerType: String = ""
    public var fwdSavedFromPeerId: Int64 = 0  // saved_from_id（flags.8）= originalAuthor
    public var fwdSavedOut: Bool = false      // saved_out（flags.11）= originalOutgoing
    public var fwdPostAuthor: String = ""     // post_author（flags.3）= iOS forwardInfo.authorSignature
    public var replyToMsgId: Int32 = 0        // 回复的消息 ID
    public var editDate: Int32 = 0            // 编辑时间（0 = 未编辑）
    public var editHide: Bool = false         // edit_hide(flags.21)：隐藏"edited"标记（bot/频道编辑常带）
    public var views: Int32 = 0               // 查看次数（频道）
    // messageReplies#83d60fc2（S5-04）：comments 位、回复数、讨论群 channel_id、max_id
    public var repliesCount: Int32 = 0
    public var repliesIsComments: Bool = false
    public var repliesChannelId: Int64 = 0
    public var repliesMaxId: Int32 = 0
    public var forwards: Int32 = 0            // 转发次数（频道）
    public var isPinned: Bool = false         // 是否置顶
    // messageActionSetMessagesTTL：period（-1 = 非该动作）/ auto_setting_from
    public var serviceTtlPeriod: Int32 = -1
    public var serviceTtlAutoFrom: Int64 = 0
    // S6-05：messageActionSetChatWallPaper#5060a3f4 flags:# same:flags.0?true for_both:flags.1?true wallpaper:WallPaper
    // （iOS TelegramMediaAction .setChatWallpaper(wallpaper, forBoth) / .setSameChatWallpaper）
    public var isWallpaperAction: Bool = false
    public var serviceWallpaperSame: Bool = false
    public var serviceWallpaperForBoth: Bool = false
    public var serviceWallpaperId: Int64 = 0
    public var serviceWallpaperAccessHash: Int64 = 0
    public var serviceWallpaperSlug: String = ""
    // reply_markup 回复键盘（0 无 / 1 keyboard / 2 hide / 3 forceReply / 4 inline）
    public var replyMarkupKind: Int32 = 0
    public var replyKeyboardRows: ArrayList<ArrayList<String>> = ArrayList<ArrayList<String>>()
    public var replyKeyboardSingleUse: Bool = false
    public var replyKeyboardResize: Bool = false
    public var replyKeyboardPlaceholder: String = ""
    // media_unread(flags.5)：语音/圆视频未被收听（iOS ConsumableContentMessageAttribute.consumed 取反）
    public var mediaUnread: Bool = false
    // ttl_period(flags.25)：消息自动删除计时（iOS AutoremoveTimeoutMessageAttribute）
    public var ttlPeriod: Int32 = 0

    // 照片元数据（用于下载和显示）
    public var photoId: Int64 = 0
    public var photoAccessHash: Int64 = 0
    public var photoFileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var photoDcId: Int32 = 0
    // Phase Q7: 照片尺寸（来自最大 PhotoSize 的 w/h）
    public var photoWidth: Int32 = 0
    public var photoHeight: Int32 = 0
    public var photoFileSize: Int32 = 0
    // 最大分辨率变体的 type（s/m/x/y/w）——下载全分辨率/保存时用它，而非写死 "y"
    public var photoLargestType: String = ""
    // Phase Q7: Stripped thumb（来自 photoStrippedSize 的 bytes，用于即时模糊预览）
    public var strippedThumb: Array<Byte> = Array<Byte>(0, repeat: 0)

    // Phase H: 文档元数据（视频/语音/文件/GIF/贴纸）
    public var documentId: Int64 = 0
    public var documentAccessHash: Int64 = 0
    public var documentFileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var documentDcId: Int32 = 0
    public var documentSize: Int64 = 0
    public var documentMimeType: String = ""
    public var documentFileName: String = ""
    // 视频属性
    public var videoDuration: Int32 = 0
    public var videoWidth: Int32 = 0
    public var videoHeight: Int32 = 0
    // 音频/语音属性
    public var audioDuration: Int32 = 0
    public var audioTitle: String = ""
    public var audioPerformer: String = ""
    // Phase Q2: 语音波形数据（来自 documentAttributeAudio.waveform）
    public var audioWaveform: Array<Byte> = Array<Byte>(0, repeat: 0)
    // Phase Q3: 贴纸 alt emoji（来自 documentAttributeSticker.alt）
    public var stickerAlt: String = ""
    // Phase Q5: 网页预览数据（来自 messageMediaWebPage.webPage）
    public var webPageUrl: String = ""
    public var webPageSiteName: String = ""
    public var webPageTitle: String = ""
    public var webPageDescription: String = ""
    // Phase P7B-1: 网页预览缩略图（来自 webPage.photo）
    public var webPagePhotoId: Int64 = 0
    public var webPagePhotoAccessHash: Int64 = 0
    public var webPagePhotoFileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var webPagePhotoDcId: Int32 = 0
    public var webPagePhotoWidth: Int32 = 0
    public var webPagePhotoHeight: Int32 = 0

    // Phase Q8: 投票数据（来自 messageMediaPoll）
    public var pollId: Int64 = 0
    public var pollQuestion: String = ""
    public var pollClosed: Bool = false
    public var pollQuiz: Bool = false
    public var pollMultipleChoice: Bool = false
    public var pollTotalVoters: Int32 = 0
    public var pollSolution: String = ""
    public var pollOptions: ArrayList<TLPollOption> = ArrayList<TLPollOption>()

    // Phase Q11: 富文本实体
    public var textEntities: ArrayList<TLTextEntity> = ArrayList<TLTextEntity>()

    // Phase T2: 通话消息数据 (messageActionPhoneCall)
    public var callId: Int64 = 0
    public var callReason: UInt32 = 0       // PhoneCallDiscardReason constructor (0=none)
    public var callIsVideo: Bool = false    // messageActionPhoneCall video:flags.2
    public var callDuration: Int32 = 0      // duration in seconds

    // Phase P5-13: 位置消息数据（来自 messageMediaGeo/messageMediaGeoLive）
    public var locationLat: Float64 = 0.0
    public var locationLng: Float64 = 0.0
    public var isLiveLocation: Bool = false
    public var liveLocationPeriod: Int32 = 0
    // P2-180: server heading from messageMediaGeoLive (flags.0 heading field); -1=none
    public var locationHeading: Int32 = -1
    // messageMediaVenue#2ec0533f：场馆标题/地址/提供方/id/类型（iOS TelegramMediaMap.venue）
    public var venueTitle: String = ""
    public var venueAddress: String = ""
    public var venueProvider: String = ""
    public var venueId: String = ""
    public var venueType: String = ""

    // Reactions 数据（Phase H6: 消息反应）
    public var reactions: ArrayList<TLReactionCount> = ArrayList<TLReactionCount>()

    public static func deserializeBoxed(d: TLDeserializer): TLMessage {
        let constructor = d.readUInt32()
        return deserializeWithConstructor(constructor, d)
    }

    public static func deserializeWithConstructor(constructor: UInt32, d: TLDeserializer): TLMessage {
        let r = TLMessage()

        if (constructor == 0x90a6ca84) {
            // messageEmpty
            r.isEmpty = true
            let flags = d.readInt32()
            r.id = d.readInt32()
            if ((flags & 1) != 0) { r.peerId = PeerResponse.deserializeBoxed(d) }
            return r
        }

        if (constructor == 0x7a800e0a) {
            // messageService#7a800e0a - 严格匹配 TelegramHarmony
            r.isService = true
            let flags = d.readInt32()
            r.isOutgoing = (flags & 2) != 0
            r.id = d.readInt32()
            if ((flags & 256) != 0) { r.fromId = Some(PeerResponse.deserializeBoxed(d)) }  // from_id - bit 8
            r.peerId = PeerResponse.deserializeBoxed(d)
            if ((flags & 268435456) != 0) { let _ = PeerResponse.deserializeBoxed(d) }  // saved_peer_id - bit 28
            if ((flags & 8) != 0) { skipMessageReplyHeader(d) }  // reply_to - bit 3
            r.date = d.readInt32()
            // Phase T2: Capture messageActionPhoneCall data before skipping
            parseMessageActionCapture(d, r)
            // reactions - bit 20 (1048576) — Phase H6: 解析而非跳过
            if ((flags & 1048576) != 0) { r.reactions = parseMessageReactions(d) }
            // ttl_period - bit 25 (33554432)
            if ((flags & 33554432) != 0) { let _ = d.readInt32() }
            // Set default message for non-call service messages
            if (r.callId == 0) {
                // 会话列表预览直接用动作文案（"started a video chat" 等），没有文案的动作才退回占位
                // 群升级动作在 iOS ServiceMessageStrings.swift:436 就是空串，不退回占位。
                r.message = if (r.serviceText.size > 0 || r.isMigrationAction) { r.serviceText } else { "[服务消息]" }
            }
            return r
        }

        // 验证是否为 message 构造器
        // 当前 ctor: 0x7600b9d3 (iOS dict[1979759059], current layer)
        // 兼容旧 ctor: 0x9cb490e9 (Layer 221), 0x9815cec8 (Layer 196+)
        if (constructor != 0x7600b9d3 && constructor != 0x9cb490e9 && constructor != 0x9815cec8) {
            Hilog.info(0, "CjTelegram", "[TLMessage] Unknown message constructor: ${constructor}")
            throw IllegalArgumentException("[TLMessage] Unknown message constructor: ${constructor}")
        }

        // message#7600b9d3 (current layer) / #9cb490e9 / #9815cec8
        // iOS parse_message field order (verified against Api16.swift:370):
        // flags(Int32), flags2(Int32), id(Int32),
        // from_id?[flags.8](boxed Peer), from_boosts_applied?[flags.29](Int32),
        // saved_from_name?[flags2.12](String),  <-- ADDED: new field in current layer
        // peer_id(boxed Peer), saved_peer_id?[flags.28](boxed Peer),
        // fwd_from?[flags.2](boxed), via_bot_id?[flags.11](Int64),
        // via_business_bot_id?[flags2.0](Int64),
        // saved_from_sent_message?[flags2.19](boxed),  <-- ADDED: new field in current layer
        // reply_to?[flags.3](boxed), date(Int32), message(String), ...
        let flags = d.readInt32()
        let flags2 = d.readInt32()  // 所有当前 ctor 都必须读 flags2

        r.isOutgoing = (flags & 2) != 0
        r.isPinned = (flags & (1 << 24)) != 0  // pinned flag = bit 24
        r.mediaUnread = (flags & (1 << 5)) != 0  // media_unread flag = bit 5
        r.id = d.readInt32()

        if ((flags & (1 << 8)) != 0) { r.fromId = Some(PeerResponse.deserializeBoxed(d)) }
        if ((flags & (1 << 29)) != 0) { let _ = d.readInt32() } // from_boosts_applied
        // saved_from_name (flags2 bit 12) — new field in 0x7600b9d3; skip for all ctors
        if ((flags2 & (1 << 12)) != 0) { let _ = d.readString() } // saved_from_name

        r.peerId = PeerResponse.deserializeBoxed(d)

        if ((flags & (1 << 28)) != 0) { let _ = PeerResponse.deserializeBoxed(d) } // savedPeerId
        // Phase A2: 解析转发信息（捕获 fromName）
        if ((flags & 4) != 0) { parseMessageFwdHeaderInto(d, r) }
        if ((flags & (1 << 11)) != 0) { let _ = d.readInt64() } // via_bot_id
        if ((flags2 & 1) != 0) { let _ = d.readInt64() } // via_business_bot_id (flags2 bit 0)
        // saved_from_sent_message (flags2 bit 19) — new field in 0x7600b9d3; skip boxed
        if ((flags2 & (1 << 19)) != 0) { let _ = PeerResponse.deserializeBoxed(d) } // saved_from_sent_message (Peer)
        // Phase A2: 解析回复信息（捕获 replyToMsgId）
        if ((flags & 8) != 0) { r.replyToMsgId = parseMessageReplyHeaderId(d) }

        r.date = d.readInt32()
        r.message = d.readString()

        // ============ 严格匹配 TelegramHarmony 的字段顺序 ============
        // Phase A2: 解析媒体类型（捕获 mediaType + mediaDescription + 照片元数据）
        if ((flags & 512) != 0) {
            let mediaInfo = parseMessageMediaTypeWithPhoto(d, Some(r))
            r.mediaType = mediaInfo[0]
            r.mediaDescription = mediaInfo[1]
            // 如果消息文本为空且不是 photo（photo 会显示图片），用媒体描述作为显示文本
            if (r.message.isEmpty() && !r.mediaDescription.isEmpty() && r.mediaType != "photo") {
                r.message = r.mediaDescription
            }
        }
        // replyMarkup - flags bit 6 (64)
        if ((flags & 64) != 0) {
            if (r.mediaType == "invoice") {
                captureInvoiceReplyMarkup(d, r)
            } else {
                captureReplyKeyboardMarkup(d, r)
            }
        }
        // entities - flags bit 7 (128) - Phase Q11: 捕获实体
        if ((flags & 128) != 0) { r.textEntities = parseMessageEntitiesCapture(d) }
        // Phase A2: 捕获 views + forwards（频道消息）
        if ((flags & 1024) != 0) {
            r.views = d.readInt32()
            r.forwards = d.readInt32()
        }
        // replies - flags bit 23 (8388608) — S5-04: 解析而非跳过（iOS ReplyThreadMessageAttribute）
        if ((flags & 8388608) != 0) { parseMessageRepliesInto(d, r) }
        // Phase A2: 捕获 editDate
        if ((flags & 32768) != 0) { r.editDate = d.readInt32() }
        // edit_hide(flags.21=2097152)：布尔位，隐藏"edited"标记（audit P2-5）
        r.editHide = (flags & 2097152) != 0
        // postAuthor - flags bit 16 (65536)
        if ((flags & 65536) != 0) { let _ = d.readString() }
        // groupedId - flags bit 17 (131072) — P2-113: capture for album mosaic
        if ((flags & 131072) != 0) { r.groupedId = d.readInt64() }
        // reactions - flags bit 20 (1048576) — Phase H6: 解析而非跳过
        if ((flags & 1048576) != 0) { r.reactions = parseMessageReactions(d) }
        // restrictionReason - flags bit 22 (4194304)
        if ((flags & 4194304) != 0) { skipVector(d) }
        // ttlPeriod - flags bit 25 (33554432)
        if ((flags & 33554432) != 0) { r.ttlPeriod = d.readInt32() }
        // quickReplyShortcutId - flags bit 30 (1073741824)
        if ((flags & 1073741824) != 0) { let _ = d.readInt32() }
        // flags2 字段（两个 constructor 都适用 — 匹配 TelegramHarmony）
        // effect - flags2 bit 2 (4)
        if ((flags2 & 4) != 0) { let _ = d.readInt64() }
        // factcheck - flags2 bit 3 (8)
        if ((flags2 & 8) != 0) { skipFactCheck(d) }
        // reportDeliveryUntilDate - flags2 bit 5 (32)
        if ((flags2 & 32) != 0) { let _ = d.readInt32() }
        // paidMessageStars - flags2 bit 6 (64)
        if ((flags2 & 64) != 0) { let _ = d.readInt64() }
        // suggestedPost - flags2 bit 7 (128)
        if ((flags2 & 128) != 0) { skipSuggestedPost(d) }
        // scheduleRepeatPeriod - flags2 bit 10 (1024)
        if ((flags2 & 1024) != 0) { let _ = d.readInt32() }
        // summaryFromLanguage - flags2 bit 11 (2048)
        if ((flags2 & 2048) != 0) { let _ = d.readString() }
        // richMessage - flags2 bit 13 (8192) — iOS Api16.swift:527 (_36, last field of message#)
        // Boxed Api.RichMessage: read ctor first, then delegate to skipRichMessage
        if ((flags2 & 8192) != 0) {
            let _ = d.readUInt32()  // RichMessage ctor (-1158439541 / 0xbaf39d8b)
            skipRichMessage(d)
        }

        return r
    }
}

// ==================== Phase A2: 解析函数（捕获数据）====================

/**
 * 解析 MessageMedia 类型 — 仅提取类型和描述文本，通过 peek + reset 复用 skipMessageMedia
 * 
 * 返回: (mediaType, mediaDescription)
 * mediaType: "photo", "video", "voice", "audio", "document", "sticker", "gif", "location", "contact", "poll", etc.
 * mediaDescription: "[Photo]", "[Video]", "[Voice Message]", "[File: name.pdf]", etc.
 */
func parseMessageMediaType(d: TLDeserializer): Array<String> {
    return parseMessageMediaTypeWithPhoto(d, None)
}

/**
 * 解析媒体类型，如果是 photo 类型则将元数据写入 TLMessage
 */
func parseMessageMediaTypeWithPhoto(d: TLDeserializer, msg: Option<TLMessage>): Array<String> {
    let savedOffset = d.getOffset()
    let constructor = d.readUInt32()

    var mediaType = ""
    var mediaDesc = ""

    if (constructor == 0x3ded6320) {
        // messageMediaEmpty — 无媒体
        return ["", ""]
    } else if (constructor == 0xe216eb63 || constructor == 0x695150d7) {
        // messageMediaPhoto#e216eb63 (current, iOS dict[-501814429]) / #695150d7 (legacy)
        // iOS Api17.swift:2112 parse_messageMediaPhoto:
        //   flags(Int32), photo?[flags.0](boxed Photo), ttl_seconds?[flags.2](Int32), video?[flags.4](boxed Document)
        mediaType = "photo"
        mediaDesc = "[Photo]"
        // 捕获照片元数据
        let flags = d.readInt32()
        if ((flags & 1) != 0) {
            let photoConstructor = d.readUInt32()
            if (photoConstructor == 0x2331b22d) {
                // photoEmpty#2331b22d id:long = Photo
                let _ = d.readInt64()  // 必须消费 id 字段，否则反序列化器位置错乱
            } else {
                // photo#fb197a65 或其他版本的 Photo — 完整照片
                let photoFlags = d.readInt32()
                let photoId = d.readInt64()
                let accessHash = d.readInt64()
                let fileReference = d.readBytes()
                let _ = d.readInt32() // date
                // Phase Q7: 解析 sizes vector，捕获最大分辨率 + stripped thumb
                var maxW: Int32 = 0
                var maxH: Int32 = 0
                var maxFileSize: Int32 = 0
                var maxType: String = ""
                var strippedBytes = Array<Byte>(0, repeat: 0)
                let vecConst = d.readUInt32()
                if (vecConst == TLConstructors.VECTOR) {
                    let count = d.readInt32()
                    for (_i in 0..Int64(count)) {
                        let (w, h, sz, isStripped, thumbData, t) = parsePhotoSizeCapture(d)
                        if (isStripped && thumbData.size > 0) {
                            strippedBytes = thumbData
                        } else if (w > maxW) {
                            maxW = w
                            maxH = h
                            maxFileSize = sz
                            maxType = t  // 最大分辨率变体的 type（下载全分辨率/保存用，对齐 iOS 选最大表示）
                        }
                    }
                }
                // 跳过 video_sizes
                if ((photoFlags & 2) != 0) {
                    let vecConst2 = d.readUInt32()
                    if (vecConst2 == TLConstructors.VECTOR) {
                        let count2 = d.readInt32()
                        for (_i in 0..Int64(count2)) { skipVideoSize(d) }
                    }
                }
                let dcId = d.readInt32()
                // 存储到 TLMessage
                match (msg) {
                    case Some(m) =>
                        m.photoId = photoId
                        m.photoAccessHash = accessHash
                        m.photoFileReference = fileReference
                        m.photoDcId = dcId
                        m.photoWidth = maxW
                        m.photoHeight = maxH
                        m.photoFileSize = maxFileSize
                        m.photoLargestType = maxType
                        m.strippedThumb = strippedBytes
                        Hilog.info(0, "CjTelegram", "[parseMedia] Photo: id=${photoId}, dcId=${dcId}, size=${maxW}x${maxH}, fileSize=${maxFileSize}, hasThumb=${strippedBytes.size > 0}")
                    case None => ()
                }
            }
        }
        if ((flags & 4) != 0) { let _ = d.readInt32() } // ttl_seconds - flags.2
        // video (flags.4) — new field in 0xe216eb63; skip boxed Document
        if ((flags & 16) != 0) { skipDocument(d) } // video:flags.4?Document
        return [mediaType, mediaDesc]
    } else if (constructor == 0x56e0d474) {
        // messageMediaGeo#56e0d474 geo:GeoPoint
        // Phase P5-13: 解析 GeoPoint 提取经纬度
        mediaType = "location"
        let geoConstructor = d.readUInt32()
        if (geoConstructor != 0x1117dd5f) {
            // geoPoint#b2a2f663 flags:# long:double lat:double access_hash:long accuracy_radius:flags.0?int
            let geoFlags = d.readInt32()
            let lng = d.readDouble()
            let lat = d.readDouble()
            let _ = d.readInt64()  // access_hash
            if ((geoFlags & 1) != 0) { let _ = d.readInt32() }  // accuracy_radius
            match (msg) {
                case Some(m) =>
                    m.locationLat = lat
                    m.locationLng = lng
                case None => ()
            }
            let latStr = "${lat}"
            let lngStr = "${lng}"
            // 截取前 8 个字符作为坐标显示
            let shortLat = if (latStr.size > 8) { latStr[0..8] } else { latStr }
            let shortLng = if (lngStr.size > 8) { lngStr[0..8] } else { lngStr }
            mediaDesc = "${shortLat}, ${shortLng}"
        } else {
            mediaDesc = "[Location]"
        }
        return [mediaType, mediaDesc]
    } else if (constructor == 0xb940c666) {
        // messageMediaGeoLive#b940c666 flags:# geo:GeoPoint heading:flags.0?int period:int proximity_notification_radius:flags.1?int
        // Phase P5-13: 解析实时位置的 GeoPoint
        mediaType = "location"
        let liveFlags = d.readInt32()
        let geoConstructor2 = d.readUInt32()
        if (geoConstructor2 != 0x1117dd5f) {
            let geoFlags2 = d.readInt32()
            let lng2 = d.readDouble()
            let lat2 = d.readDouble()
            let _ = d.readInt64()  // access_hash
            if ((geoFlags2 & 1) != 0) { let _ = d.readInt32() }  // accuracy_radius
            match (msg) {
                case Some(m) =>
                    m.locationLat = lat2
                    m.locationLng = lng2
                    m.isLiveLocation = true
                case None => ()
            }
            let latStr2 = "${lat2}"
            let lngStr2 = "${lng2}"
            let shortLat2 = if (latStr2.size > 8) { latStr2[0..8] } else { latStr2 }
            let shortLng2 = if (lngStr2.size > 8) { lngStr2[0..8] } else { lngStr2 }
            mediaDesc = "${shortLat2}, ${shortLng2}"
        } else {
            mediaDesc = "[Live Location]"
            match (msg) {
                case Some(m) => m.isLiveLocation = true
                case None => ()
            }
        }
        // P2-180: capture server-provided heading (flags.0) into Message.locationHeading
        if ((liveFlags & 1) != 0) {
            let serverHeading = d.readInt32()
            match (msg) {
                case Some(m) => m.locationHeading = serverHeading
                case None => ()
            }
        }
        let livePeriod = d.readInt32()  // period
        match (msg) {
            case Some(m) => m.liveLocationPeriod = livePeriod
            case None => ()
        }
        if ((liveFlags & 2) != 0) { let _ = d.readInt32() }  // proximity_notification_radius
        return [mediaType, mediaDesc]
    } else if (constructor == 0x70322949) {
        // messageMediaContact — 读取联系人名称
        let contactPhone = d.readString()    // phone
        let firstName = d.readString()
        let lastName = d.readString()
        mediaType = "contact"
        mediaDesc = "[Contact: ${firstName} ${lastName}]"
        // S2-96: iOS ChatMessageContactBubbleContentNode shows displayName + formatted phone.
        match (msg) {
            case Some(m) =>
                m.contactPhone = contactPhone
                m.contactFirstName = firstName
                m.contactLastName = lastName
            case None => ()
        }
        // 不 reset — 但我们需要 reset 后用 skipMessageMedia 来完整跳过
        // 所以先记录名称，然后 reset
    } else if (constructor == 0x9f84f49e) {
        mediaType = "unsupported"
        mediaDesc = "[Unsupported Media]"
    } else if (constructor == 0x52d8ccd9 || constructor == 0x4cf4d72d || constructor == 0xdd570ee5) {
        // messageMediaDocument — 需要检测子类型 + 捕获文档元数据
        let docInfo = peekDocumentSubtypeWithMeta(d, constructor, msg)
        mediaType = docInfo[0]
        mediaDesc = docInfo[1]
        // 已经完整解析，直接返回
        return [mediaType, mediaDesc]
    } else if (constructor == 0xddf10c3b || constructor == 0xa32dd600) {
        // messageMediaWebPage — Phase Q5: 解析 WebPage 提取预览数据
        mediaType = "webpage"
        // 新版 0xddf10c3b 有 flags
        if (constructor == 0xddf10c3b) {
            let _ = d.readInt32()  // flags
        }
        // 解析 WebPage 并捕获到 TLMessage
        match (msg) {
            case Some(m) => parseWebPageCapture(d, m)
            case None => skipWebPage(d)
        }
        mediaDesc = ""  // 网页预览不单独作为 mediaDescription
        // 已完整解析，直接返回
        return [mediaType, mediaDesc]
    } else if (constructor == 0x2ec0533f) {
        // messageMediaVenue#2ec0533f geo:GeoPoint title:string address:string provider:string
        //   venue_id:string venue_type:string —— 与 messageMediaGeo 同走 "location" 渲染分支，
        //   iOS ChatMessageMapBubbleContentNode 在地图下方画 venue.title / venue.address。
        mediaType = "location"
        let geoConstructor = d.readUInt32()
        var lat = 0.0
        var lng = 0.0
        if (geoConstructor != 0x1117dd5f) {
            let geoFlags = d.readInt32()
            lng = d.readDouble()
            lat = d.readDouble()
            let _ = d.readInt64()  // access_hash
            if ((geoFlags & 1) != 0) { let _ = d.readInt32() }  // accuracy_radius
        }
        let title = d.readString()
        let address = d.readString()
        let provider = d.readString()
        let venueId = d.readString()
        let venueType = d.readString()
        match (msg) {
            case Some(m) =>
                m.locationLat = lat
                m.locationLng = lng
                m.venueTitle = title
                m.venueAddress = address
                m.venueProvider = provider
                m.venueId = venueId
                m.venueType = venueType
            case None => ()
        }
        mediaDesc = if (title.size > 0) { title } else { "[Venue]" }
        return [mediaType, mediaDesc]
    } else if (constructor == 0xfdb19008) {
        mediaType = "game"
        mediaDesc = "[Game]"
    } else if (constructor == 0x773f4e66 || constructor == 0x4bd6e798) {
        // messageMediaPoll#773f4e66 (current, iOS dict[2000637542]) — flags:Int32 poll:Poll results:PollResults attachedMedia?[flags.0]:MessageMedia
        // messageMediaPoll#4bd6e798 (legacy)              — poll:Poll results:PollResults (no flags, no attachedMedia)
        mediaType = "poll"
        // Phase Q8: 解析完整投票数据（不再只是 skip）
        // 新版 0x773f4e66 有前置 flags，旧版 0x4bd6e798 无 flags
        let pollFlags: Int32 = if (constructor == 0x773f4e66) { d.readInt32() } else { 0 }
        match (msg) {
            case Some(m) =>
                parsePollCapture(d, m)
                parsePollResultsCapture(d, m)
                // 新版 attachedMedia?[flags.0] — 跳过
                if ((pollFlags & 1) != 0) { skipMessageMedia(d) }
                // 将投票选项与结果合并
                mergePollResults(m)
                mediaDesc = if (m.pollQuestion.size > 0) { m.pollQuestion } else { "[Poll]" }
                return [mediaType, mediaDesc]
            case None => ()
        }
        // None path — need to skip the poll+results+attachedMedia
        skipPoll(d)
        skipPollResults(d)
        if ((pollFlags & 1) != 0) { skipMessageMedia(d) }
        mediaDesc = "[Poll]"
        return [mediaType, mediaDesc]
    } else if (constructor == 0x08cbec07 || constructor == 0x3f7ee58b) {
        mediaType = "dice"
        mediaDesc = "[Dice]"
    } else if (constructor == 0x68cb6283 || constructor == 0xc6b68300) {
        mediaType = "story"
        mediaDesc = "[Story]"
    } else if (constructor == 0xaa073beb || constructor == 0xdaad85b0) {
        mediaType = "giveaway"
        mediaDesc = "[Giveaway]"
    } else if (constructor == 0xa8852491) {
        mediaType = "paidMedia"
        mediaDesc = "[Paid Media]"
    } else if (constructor == 0xf6a548d3) {
        mediaType = "invoice"
        mediaDesc = "[Invoice]"
        let flags = d.readInt32()
        let title = d.readString()
        let description = d.readString()
        if ((flags & 1) != 0) { skipWebDocument(d) }
        let receiptMsgId = if ((flags & 4) != 0) { d.readInt32() } else { Int32(0) }
        let currency = d.readString()
        let totalAmount = d.readInt64()
        let startParam = d.readString()
        if ((flags & 16) != 0) { skipExtendedMedia(d) }
        match (msg) {
            case Some(m) =>
                m.invoiceTitle = title
                m.invoiceDescription = description
                m.invoiceCurrency = currency
                m.invoiceTotalAmount = totalAmount
                m.invoiceStartParam = startParam
                m.invoiceReceiptMsgId = receiptMsgId
            case None => ()
        }
        return [mediaType, mediaDesc]
    } else {
        mediaType = "other"
        mediaDesc = ""
    }

    // Reset 到 media 开始位置，用原始 skipMessageMedia 完整跳过
    d.setOffset(savedOffset)
    skipMessageMedia(d)

    return [mediaType, mediaDesc]
}

/**
 * 窥探 Document 子类型（video/voice/audio/sticker/gif/document）
 * 解析 document 的 attributes 来确定具体类型
 * 
 * 注意：此函数完整解析 messageMediaDocument，不需要 reset
 */
func peekDocumentSubtype(d: TLDeserializer, constructor: UInt32): Array<String> {
    return peekDocumentSubtypeWithMeta(d, constructor, None)
}

/**
 * 窥探 Document 子类型并捕获元数据到 TLMessage（如果提供）
 */
func peekDocumentSubtypeWithMeta(d: TLDeserializer, constructor: UInt32, msg: Option<TLMessage>): Array<String> {
    var docType = "document"
    var docDesc = "[File]"
    var fileName = ""

    if (constructor == 0x52d8ccd9) {
        // messageMediaDocument#52d8ccd9 (Layer 221)
        let flags = d.readInt32()
        if ((flags & 1) != 0) {
            // 解析 document 以提取类型 + 捕获元数据
            let docInfo = parseDocumentForTypeWithMeta(d, msg)
            docType = docInfo[0]
            docDesc = docInfo[1]
            fileName = docInfo[2]
        }
        if ((flags & 32) != 0) { skipDocumentVector(d) }  // altDocuments
        if ((flags & 512) != 0) { skipPhoto(d) }          // videoCover
        if ((flags & 1024) != 0) { let _ = d.readInt32() } // videoTimestamp
        if ((flags & 4) != 0) { let _ = d.readInt32() }   // ttlSeconds
    } else if (constructor == 0x4cf4d72d || constructor == 0xdd570ee5) {
        // 旧版 messageMediaDocument
        let flags = d.readInt32()
        if ((flags & 4) != 0) {
            let docInfo = parseDocumentForTypeWithMeta(d, msg)
            docType = docInfo[0]
            docDesc = docInfo[1]
            fileName = docInfo[2]
        }
        if ((flags & 32) != 0) { skipDocument(d) }        // altDocument
        if ((flags & 1) != 0) { let _ = d.readInt32() }   // ttlSeconds
    }

    return [docType, docDesc]
}

func parseDocumentForType(d: TLDeserializer): Array<String> {
    return parseDocumentForTypeWithMeta(d, None)
}

/**
 * 解析 Document 结构以提取类型信息 + 捕获元数据
 * 基于 TelegramHarmony 的 parseMessageMediaDocumentNew 逻辑
 * 
 * 返回: [type, description, fileName]
 * 如果 msg 不为 None，将文档元数据写入 TLMessage
 */
func parseDocumentForTypeWithMeta(d: TLDeserializer, msg: Option<TLMessage>): Array<String> {
    let constructor = d.readUInt32()
    if (constructor == 0x36f8c871) {
        // documentEmpty
        let _ = d.readInt64()
        return ["document", "[File]", ""]
    }

    // document#8fd4c4d8
    let flags = d.readInt32()
    let docId = d.readInt64()  // id
    let docAccessHash = d.readInt64()  // access_hash
    let docFileReference = d.readBytes()  // file_reference
    let _ = d.readInt32()  // date
    let mimeType = d.readString()  // mime_type — 用于类型检测
    let docSize = d.readInt64()  // size

    // Preserve Telegram's exact immediate thumbnail for documents. iOS keeps
    // this representation visible while the full sticker resource is fetched
    // and only removes it after the animation renderer publishes frame zero.
    var documentStrippedThumb = Array<Byte>(0, repeat: 0)
    // thumbs
    if ((flags & 1) != 0) {
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let (_w, _h, _sz, isStripped, thumbData, _type) = parsePhotoSizeCapture(d)
                if (isStripped && !thumbData.isEmpty()) {
                    documentStrippedThumb = thumbData
                }
            }
        }
    }
    // video_thumbs
    if ((flags & 2) != 0) {
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { skipVideoSize(d) }
        }
    }
    let docDcId = d.readInt32()  // dc_id

    // 解析 attributes 来确定子类型
    var isVideo = false
    var isRoundVideo = false
    var isVoice = false
    var isAudio = false
    var isSticker = false
    var isAnimated = false
    var fileName = ""
    var videoDuration: Int32 = 0
    var videoWidth: Int32 = 0
    var videoHeight: Int32 = 0
    var audioDuration: Int32 = 0
    var audioTitle = ""
    var audioPerformer = ""
    var audioWaveform = Array<Byte>(0, repeat: 0)
    var stickerAlt = ""

    let attrVecConst = d.readUInt32()
    if (attrVecConst == TLConstructors.VECTOR) {
        let attrCount = d.readInt32()
        for (_i in 0..Int64(attrCount)) {
            let attrConstructor = d.readUInt32()

            if (attrConstructor == 0x43C57C48 || attrConstructor == 0xd38ff1c2) {
                // documentAttributeVideo (0x43C57C48 = Layer 190+, 0xd38ff1c2 = 中间版本)
                // 严格匹配 TelegramHarmony skipDocumentAttribute 的字段顺序:
                // flags:# duration:double w:int h:int preload_prefix_size:flags.2?int video_start_ts:flags.4?double video_codec:flags.5?string
                isVideo = true
                let attrFlags = d.readInt32()
                // flags.0 = roundMessage (圆形视频消息)
                if ((attrFlags & 1) != 0) { isRoundVideo = true }
                let dur = d.readDouble()  // duration (double)
                videoDuration = Int32(dur)
                videoWidth = d.readInt32()   // w
                videoHeight = d.readInt32()   // h
                if ((attrFlags & 4) != 0) { let _ = d.readInt32() }    // preload_prefix_size - bit 2
                if ((attrFlags & 16) != 0) { let _ = d.readDouble() }  // video_start_ts - bit 4
                if ((attrFlags & 32) != 0) { let _ = d.readString() }  // video_codec - bit 5 (仅 0x43C57C48)
            } else if (attrConstructor == 0xef02ce6) {
                // documentAttributeVideo (旧版) — duration 是 int 而不是 double
                isVideo = true
                let attrFlags = d.readInt32()
                if ((attrFlags & 1) != 0) { isRoundVideo = true }
                let dur = d.readInt32()  // duration (int)
                videoDuration = dur
                videoWidth = d.readInt32()   // w
                videoHeight = d.readInt32()   // h
            } else if (attrConstructor == 0x9852f9c6) {
                // documentAttributeAudio#9852f9c6
                // flags:# voice:flags.10 duration:int title:flags.0?string
                //   performer:flags.1?string waveform:flags.2?bytes
                let attrFlags = d.readInt32()
                isVoice = (attrFlags & 1024) != 0  // voice flag = bit 10
                if (!isVoice) { isAudio = true }
                audioDuration = d.readInt32()  // duration
                if ((attrFlags & 1) != 0) { audioTitle = d.readString() }   // title
                if ((attrFlags & 2) != 0) { audioPerformer = d.readString() }   // performer
                // Phase Q2: 捕获 waveform 字节数据（而非丢弃）
                if ((attrFlags & 4) != 0) { audioWaveform = d.readBytes() }    // waveform
            } else if (attrConstructor == 0x6319d612) {
                // documentAttributeSticker#6319d612
                // flags:# mask:flags.1 alt:string stickerset:InputStickerSet
                //   mask_coords:flags.0?MaskCoords
                isSticker = true
                let attrFlags = d.readInt32()
                stickerAlt = d.readString()  // Phase Q3: 捕获 alt emoji
                skipInputStickerSet(d)
                if ((attrFlags & 1) != 0) {
                    let _ = d.readInt32()
                    let _ = d.readDouble()
                    let _ = d.readDouble()
                    let _ = d.readDouble()
                }
            } else if (attrConstructor == 0x11b58939) {
                // documentAttributeAnimated
                isAnimated = true
            } else if (attrConstructor == 0x15590068) {
                // documentAttributeFilename
                fileName = d.readString()
            } else if (attrConstructor == 0x6c37c15c) {
                // documentAttributeImageSize
                let _ = d.readInt32()
                let _ = d.readInt32()
            } else if (attrConstructor == 0x9801d2f7) {
                // documentAttributeHasStickers — 无字段
            } else if (attrConstructor == 0xfd149899) {
                // documentAttributeCustomEmoji
                let _ = d.readInt32()
                let _ = d.readString()
                skipInputStickerSet(d)
            } else {
                // 未知属性 — 无法安全跳过(不知道字段长度)，抛出异常触发恢复
                Hilog.info(0, "CjTelegram", "[parseDocumentForType] Unknown attr constructor: ${attrConstructor}")
                throw IllegalArgumentException("[parseDocumentForType] Unknown attr constructor: ${attrConstructor}")
            }
        }
    }

    // Phase H: 将文档元数据写入 TLMessage
    match (msg) {
        case Some(m) =>
            m.documentId = docId
            m.documentAccessHash = docAccessHash
            m.documentFileReference = docFileReference
            m.documentDcId = docDcId
            m.documentSize = docSize
            m.documentMimeType = mimeType
            m.documentFileName = fileName
            m.videoDuration = videoDuration
            m.videoWidth = videoWidth
            m.videoHeight = videoHeight
            m.audioDuration = audioDuration
            m.audioTitle = audioTitle
            m.audioPerformer = audioPerformer
            m.audioWaveform = audioWaveform
            m.stickerAlt = stickerAlt
            m.strippedThumb = documentStrippedThumb
            Hilog.info(0, "CjTelegram", "[parseDocument] Captured: id=${docId}, mime=${mimeType}, size=${docSize}, file=${fileName}, video=${isVideo}(${videoDuration}s ${videoWidth}x${videoHeight}), waveform=${audioWaveform.size}B, stickerAlt=${stickerAlt}")
        case None => ()
    }

    // 基于属性确定子类型（匹配 TelegramHarmony 的逻辑）
    if (isSticker) {
        // Phase Q3: 使用 alt emoji 作为 mediaDescription（如 "😂"）
        let stickerDesc = if (stickerAlt.size > 0) { stickerAlt } else { "[Sticker]" }
        return ["sticker", stickerDesc, fileName]
    }
    if (isAnimated && !isVideo) {
        return ["gif", "[GIF]", fileName]
    }
    // 圆形视频消息同时带 documentAttributeVideo(round_message) 与 documentAttributeAudio(voice, waveform)
    //（服务端为视频消息补的波形/转写属性），必须先于 voice 判定 —— 对位 iOS
    // ChatMessageBubbleItemNode.swift:205 先判 file.isInstantVideo。此前先判 isVoice，
    // 真机上对端的 400x400 视频消息被当成语音气泡（2026-09-11 复现）。
    if (isVideo && isRoundVideo) {
        let durationStr = formatDuration(videoDuration)
        return ["video_note", "[Video Note ${durationStr}]", fileName]
    }
    if (isVoice) {
        return ["voice", "[Voice Message]", fileName]
    }
    if (isAudio) {
        return ["audio", "[Audio]", fileName]
    }
    if (isVideo) {
        // 区分视频和 GIF（round message / animated）
        if (mimeType == "video/mp4" && isAnimated) {
            return ["gif", "[GIF]", fileName]
        }
        let durationStr = formatDuration(videoDuration)
        return ["video", "[Video ${durationStr}]", fileName]
    }

    // 普通文件
    if (fileName.size > 0) {
        return ["document", "[File: ${fileName}]", fileName]
    }
    return ["document", "[File]", fileName]
}

/**
 * 格式化时长（秒 → MM:SS）
 */
func formatDuration(seconds: Int32): String {
    let mins = seconds / 60
    let secs = seconds % 60
    let mStr = if (mins < 10) { "0${mins}" } else { "${mins}" }
    let sStr = if (secs < 10) { "0${secs}" } else { "${secs}" }
    return "${mStr}:${sStr}"
}

/**
 * 解析 messageFwdHeader 并把来源名称 + 归属信息写入 TLMessage。
 * 字段顺序与 iOS Api17.swift:1148 parse_messageFwdHeader 一致；
 * forwardInfo 存在性按 iOS StoreMessage_Telegram.swift:1187-1217：from_id 或 post_author/from_name。
 */
func parseMessageFwdHeaderInto(d: TLDeserializer, msg: TLMessage): Unit {
    let _ = d.readUInt32() // constructor
    let flags = d.readInt32()
    var hasFromId = false
    if ((flags & 1) != 0) {
        let fromPeer = PeerResponse.deserializeBoxed(d)
        msg.fwdFromPeerId = fromPeer.id
        msg.fwdFromPeerType = fromPeer.type_
        hasFromId = true
    }
    if ((flags & 32) != 0) { msg.fwdFromName = d.readString() }  // from_name
    let _ = d.readInt32()  // date
    if ((flags & 4) != 0) { let _ = d.readInt32() }  // channel_post
    var postAuthor = ""
    if ((flags & 8) != 0) { postAuthor = d.readString() }  // post_author
    if ((flags & 16) != 0) { let _ = PeerResponse.deserializeBoxed(d) }  // saved_from_peer
    if ((flags & 16) != 0) { let _ = d.readInt32() }  // saved_from_msg_id
    if ((flags & 256) != 0) { msg.fwdSavedFromPeerId = PeerResponse.deserializeBoxed(d).id }  // saved_from_id
    if ((flags & 512) != 0) { let _ = d.readString() }  // saved_from_name
    if ((flags & 1024) != 0) { let _ = d.readInt32() }  // saved_date
    if ((flags & 64) != 0) { let _ = d.readString() }  // psa_type
    msg.fwdSavedOut = (flags & (1 << 11)) != 0
    msg.fwdPostAuthor = postAuthor
    msg.hasForwardInfo = hasFromId || postAuthor.size > 0 || msg.fwdFromName.size > 0
}

/**
 * 解析 FwdHeader 并提取转发来源名称
 * 其他字段正常跳过
 */
func parseMessageFwdHeaderName(d: TLDeserializer): String {
    let _ = d.readUInt32() // constructor
    let flags = d.readInt32()
    var fromName = ""
    if ((flags & 1) != 0) { let _ = PeerResponse.deserializeBoxed(d) }  // fromId
    if ((flags & 32) != 0) { fromName = d.readString() }  // fromName
    let _ = d.readInt32()  // date
    if ((flags & 4) != 0) { let _ = d.readInt32() }
    if ((flags & 8) != 0) { let _ = d.readString() }
    if ((flags & 16) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
    if ((flags & 16) != 0) { let _ = d.readInt32() }
    if ((flags & 256) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
    if ((flags & 512) != 0) { let _ = d.readString() }
    if ((flags & 1024) != 0) { let _ = d.readInt32() }
    if ((flags & 64) != 0) { let _ = d.readString() }
    return fromName
}

/**
 * 解析 ReplyHeader 并提取 replyToMsgId
 * 其他字段正常跳过
 */
func parseMessageReplyHeaderId(d: TLDeserializer): Int32 {
    let constructor = d.readUInt32()
    let flags = d.readInt32()
    var replyToMsgId: Int32 = 0
    if ((flags & 16) != 0) { replyToMsgId = d.readInt32() }  // replyToMsgId - bit 4
    if ((flags & 1) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
    if ((flags & 32) != 0) { skipMessageFwdHeader(d) }
    if ((flags & 256) != 0) { skipMessageMedia(d) }
    if ((flags & 2) != 0) { let _ = d.readInt32() }
    if ((flags & 64) != 0) { let _ = d.readString() }
    if ((flags & 128) != 0) { skipMessageEntitiesVector(d) }
    if ((flags & 1024) != 0) { let _ = d.readInt32() }   // quoteOffset - bit 10
    if ((flags & 2048) != 0) { let _ = d.readInt32() }   // todoItemId - bit 11
    if ((flags & 4096) != 0) { let _ = d.readBytes() }   // pollOption - bit 12 (iOS Api18.swift:667)
    return replyToMsgId
}

// ==================== 原始跳过函数（保持不变）====================

func skipMessageReplyHeader(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    // 支持 Layer 214 (0x6917560b) 和旧版 (0x9ce2bb64, 0xa6d57763) - 匹配 TelegramHarmony
    let flags = d.readInt32()
    if ((flags & 16) != 0) { let _ = d.readInt32() }  // replyToMsgId - bit 4
    if ((flags & 1) != 0) { let _ = PeerResponse.deserializeBoxed(d) }  // replyToPeerId - bit 0
    if ((flags & 32) != 0) { skipMessageFwdHeader(d) }  // replyFrom - bit 5
    if ((flags & 256) != 0) { skipMessageMedia(d) }  // replyMedia - bit 8
    if ((flags & 2) != 0) { let _ = d.readInt32() }  // replyToTopId - bit 1
    if ((flags & 64) != 0) { let _ = d.readString() }  // quoteText - bit 6
    if ((flags & 128) != 0) { skipMessageEntitiesVector(d) }  // quoteEntities - bit 7
    if ((flags & 1024) != 0) { let _ = d.readInt32() }  // quoteOffset - bit 10
    if ((flags & 2048) != 0) { let _ = d.readInt32() }  // todoItemId - bit 11
    if ((flags & 4096) != 0) { let _ = d.readBytes() }  // pollOption - bit 12 (iOS Api18.swift:667)
}

func skipMessageFwdHeader(d: TLDeserializer): Unit {
    let _ = d.readUInt32() // constructor
    let flags = d.readInt32()
    if ((flags & 1) != 0) { let _ = PeerResponse.deserializeBoxed(d) }  // fromId - bit 0
    if ((flags & 32) != 0) { let _ = d.readString() }  // fromName - bit 5
    let _ = d.readInt32()  // date - always present
    if ((flags & 4) != 0) { let _ = d.readInt32() }  // channelPost - bit 2
    if ((flags & 8) != 0) { let _ = d.readString() }  // postAuthor - bit 3
    if ((flags & 16) != 0) { let _ = PeerResponse.deserializeBoxed(d) }  // savedFromPeer - bit 4
    if ((flags & 16) != 0) { let _ = d.readInt32() }  // savedFromMsgId - bit 4
    if ((flags & 256) != 0) { let _ = PeerResponse.deserializeBoxed(d) }  // savedFromId - bit 8
    if ((flags & 512) != 0) { let _ = d.readString() }  // savedFromName - bit 9
    if ((flags & 1024) != 0) { let _ = d.readInt32() }  // savedDate - bit 10
    if ((flags & 64) != 0) { let _ = d.readString() }  // psaType - bit 6
}

// ==================== Phase T2: MessageAction Capture ====================

/**
 * Parse messageAction — if it's messageActionPhoneCall, capture call data into TLMessage.
 * For all other action types, fall back to skipMessageAction.
 */
func parseMessageActionCapture(d: TLDeserializer, msg: TLMessage): Unit {
    let constructor = d.readUInt32()
    
    // messageActionPhoneCall#80e11a7f flags:# call_id:long reason:flags.0?PhoneCallDiscardReason duration:flags.1?int
    if (constructor == 0x80e11a7f) {
        let flags = d.readInt32()
        msg.callIsVideo = (flags & 4) != 0  // video:flags.2 (TelegramMediaAction.swift:50)
        msg.callId = d.readInt64()  // call_id
        if ((flags & 1) != 0) {
            msg.callReason = d.readUInt32()  // PhoneCallDiscardReason constructor
        }
        if ((flags & 2) != 0) {
            msg.callDuration = d.readInt32()  // duration in seconds
        }
        // iOS parity（会话列表通话预览，EnumeratePeerCall / CallListCallItem 文案）：
        // outgoing 接通=Outgoing Call，未接通(无时长)=Canceled Call；
        // incoming missed=Missed Call，接通=Incoming Call，未接通=Canceled Call。
        // 会话列表预览**不带时长**（时长仅在通话记录详情/气泡显示）。
        var callText = ""
        if (msg.isOutgoing) {
            if (msg.callDuration > 0) {
                callText = "Outgoing Call"
            } else {
                callText = "Canceled Call"
            }
        } else {
            if (msg.callReason == 0x85e42301) {
                callText = "Missed Call"
            } else if (msg.callDuration > 0) {
                callText = "Incoming Call"
            } else {
                callText = "Canceled Call"
            }
        }
        msg.message = callText
        msg.mediaType = "phone_call"
        return
    }
    
    // messageActionSetMessagesTTL#3c134d7b flags:# period:int auto_setting_from:flags.0?long
    // （iOS Api0 dict[1007897979]）：记下 period，气泡全文由 RealMessageService 按
    // iOS ServiceMessageStrings.swift:438-510 生成；这里的短文案只给会话列表预览用。
    if (constructor == 0x3c134d7b) {
        let flags = d.readInt32()
        msg.serviceTtlPeriod = d.readInt32()
        if ((flags & 1) != 0) { msg.serviceTtlAutoFrom = d.readInt64() }
        msg.serviceText = if (msg.serviceTtlPeriod > 0) {
            "set messages to automatically delete"
        } else {
            "disabled the auto-delete timer"
        }
        return
    }

    // P2-113: Capture human-readable service action text for key action types
    // messageActionEmpty#b6aef7b0 — no body, no text
    if (constructor == 0xb6aef7b0) {
        msg.serviceText = ""
        return
    }
    // messageActionChatDeletePhoto#95e3fbef — no body
    if (constructor == 0x95e3fbef) {
        msg.serviceText = "Group photo removed"
        return
    }
    // messageActionPinMessage#94bd38ed — no body
    if (constructor == 0x94bd38ed) {
        msg.serviceText = "pinned a message"
        return
    }
    // messageActionHistoryClear#9fbab604 — no body
    if (constructor == 0x9fbab604) {
        msg.serviceText = "History was cleared"
        return
    }
    // messageActionScreenshotTaken#4792929b — no body
    if (constructor == 0x4792929b) {
        msg.serviceText = "took a screenshot"
        return
    }
    // messageActionContactSignUp#f3f25f76 — no body
    if (constructor == 0xf3f25f76) {
        msg.serviceText = "joined Telegram"
        return
    }
    // messageActionChatJoinedByRequest#ebbca3cb — no body
    if (constructor == 0xebbca3cb) {
        msg.serviceText = "joined the group via invite link"
        return
    }
    // messageActionChatEditTitle#b5a1ce5a title:string
    if (constructor == 0xb5a1ce5a) {
        let title = d.readString()
        msg.serviceText = "Group renamed to \"${title}\""
        return
    }
    // messageActionChatEditPhoto#7fcb13a8 photo:Photo — skip photo
    if (constructor == 0x7fcb13a8) {
        skipPhoto(d)
        msg.serviceText = "Group photo updated"
        return
    }
    // messageActionChatDeleteUser#a43f30cc user_id:long
    if (constructor == 0xa43f30cc) {
        msg.actionUserId = d.readInt64()
        msg.serviceText = "left the group"
        return
    }
    // messageActionChatJoinedByLink#031224c3 inviter_id:long
    if (constructor == 0x031224c3) {
        let _ = d.readInt64()
        msg.serviceText = "joined the group via invite link"
        return
    }
    // messageActionChannelCreate#95d2ac92 title:string
    if (constructor == 0x95d2ac92) {
        let title = d.readString()
        msg.serviceText = "Channel \"${title}\" created"
        return
    }
    // messageActionChatCreate#bd47cbad title:string users:Vector<long>
    if (constructor == 0xbd47cbad) {
        let title = d.readString()
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { let _ = d.readInt64() }
        }
        msg.serviceText = "Group \"${title}\" created"
        return
    }
    // messageActionChatAddUser#15cefd00 users:Vector<long>
    if (constructor == 0x15cefd00) {
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { msg.actionUserIds.add(d.readInt64()) }
        }
        msg.serviceText = "added members to the group"
        return
    }
    // messageActionCustomAction#fae69f56 message:string
    if (constructor == 0xfae69f56) {
        msg.serviceText = d.readString()
        return
    }

    // ── 群 Video Chat 服务消息（iOS ServiceMessageStrings.swift:683-726 / :796-802）──
    // messageActionGroupCall#7a0d7f42 flags:# call:InputGroupCall duration:flags.0?int
    if (constructor == 0x7a0d7f42) {
        let flags = d.readInt32()
        skipBoxedInputGroupCall(d)
        if ((flags & 1) != 0) {
            let duration = d.readInt32()
            // Notification.VoiceChatEndedGroup：「%1$@ ended the video chat (%2$@)」
            msg.serviceText = "ended the video chat (${formatCallDurationText(duration)})"
        } else {
            // Notification.VoiceChatStarted：「%@ started a video chat」
            msg.serviceText = "started a video chat"
        }
        return
    }
    // messageActionGroupCallScheduled#b3a07661 call:InputGroupCall schedule_date:int
    if (constructor == 0xb3a07661) {
        skipBoxedInputGroupCall(d)
        // 时间文案要按本地时区排版，core 层不能依赖 utils：这里只带出时间戳，由 services 层补 " for today at 22:51"
        msg.serviceScheduleDate = Int64(d.readInt32())
        msg.serviceText = "scheduled a video chat"
        return
    }
    // messageActionInviteToGroupCall#502f92f7 call:InputGroupCall users:Vector<long>
    if (constructor == 0x502f92f7) {
        skipBoxedInputGroupCall(d)
        skipInt64Vector(d)
        msg.serviceText = "invited members to the video chat"
        return
    }

    // messageActionChatMigrateTo#e1037f92 channel_id:long（iOS Api0 dict[-519864430]）
    if (constructor == 0xe1037f92) {
        msg.migratedToChannelId = d.readInt64()
        msg.isMigrationAction = true
        msg.serviceText = ""
        return
    }
    // messageActionChannelMigrateFrom#ea3948e9 title:string chat_id:long（iOS Api0 dict[-365344535]）
    if (constructor == 0xea3948e9) {
        let _ = d.readString()
        let _ = d.readInt64()
        msg.isMigrationAction = true
        msg.serviceText = ""
        return
    }

    // S6-05：messageActionSetChatWallPaper#5060a3f4 flags:# same:flags.0?true for_both:flags.1?true
    // wallpaper:WallPaper（iOS Api0 dict[1348510708]；0xe7e75f97 同 skipMessageActionWithConstructor
    // 的旧层变体）。整句文案由 RealMessageService 按 iOS ServiceMessageStrings.swift:1068-1096 生成，
    // 这里的短文案只给会话列表预览用；壁纸身份（id/access_hash/slug）留给气泡取缩略图。
    if (constructor == 0x5060a3f4 || constructor == 0xe7e75f97) {
        let flags = d.readInt32()
        msg.isWallpaperAction = true
        msg.serviceWallpaperSame = (flags & 1) != 0
        msg.serviceWallpaperForBoth = (flags & 2) != 0
        let (wpId, wpHash, wpSlug) = parseWallPaperRef(d)
        msg.serviceWallpaperId = wpId
        msg.serviceWallpaperAccessHash = wpHash
        msg.serviceWallpaperSlug = wpSlug
        msg.serviceText = if (msg.serviceWallpaperSame) {
            "set the same wallpaper for this chat"
        } else {
            "set a new wallpaper for this chat"
        }
        return
    }

    // For all other action types, skip and show generic text
    msg.serviceText = "Service message"
    skipMessageActionWithConstructor(constructor, d)
}

// ==================== MessageAction 跳过函数 ====================

func skipMessageAction(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    skipMessageActionWithConstructor(constructor, d)
}

func skipMessageActionWithConstructor(constructor: UInt32, d: TLDeserializer): Unit {
    // ── no-body variants ────────────────────────────────────────────────────────
    // messageActionEmpty#b6aef7b0
    if (constructor == 0xb6aef7b0) { return }
    // messageActionChatDeletePhoto#95e3fbef
    if (constructor == 0x95e3fbef) { return }
    // messageActionPinMessage#94bd38ed
    if (constructor == 0x94bd38ed) { return }
    // messageActionHistoryClear#9fbab604  (Api0 dict[-1615153660])
    if (constructor == 0x9fbab604) { return }
    // messageActionScreenshotTaken#4792929b
    if (constructor == 0x4792929b) { return }
    // messageActionContactSignUp#f3f25f76
    if (constructor == 0xf3f25f76) { return }
    // messageActionChatJoinedByRequest#ebbca3cb
    if (constructor == 0xebbca3cb) { return }

    // ── simple single-field variants ────────────────────────────────────────────
    // messageActionChatEditTitle#b5a1ce5a title:string
    if (constructor == 0xb5a1ce5a) { let _ = d.readString(); return }
    // messageActionChatEditPhoto#7fcb13a8 photo:Photo
    if (constructor == 0x7fcb13a8) { skipPhoto(d); return }
    // messageActionChatDeleteUser#a43f30cc user_id:long
    if (constructor == 0xa43f30cc) { let _ = d.readInt64(); return }
    // messageActionChatJoinedByLink#031224c3 inviter_id:long
    if (constructor == 0x031224c3) { let _ = d.readInt64(); return }
    // messageActionChannelCreate#95d2ac92 title:string
    if (constructor == 0x95d2ac92) { let _ = d.readString(); return }
    // messageActionChatMigrateTo#e1037f92 channel_id:long
    if (constructor == 0xe1037f92) { let _ = d.readInt64(); return }
    // messageActionCustomAction#fae69f56 message:string
    if (constructor == 0xfae69f56) { let _ = d.readString(); return }
    // messageActionSuggestProfilePhoto#57de635e photo:Photo
    if (constructor == 0x57de635e) { skipPhoto(d); return }
    // messageActionWebViewDataSent#b4c38cb5 text:string
    if (constructor == 0xb4c38cb5) { let _ = d.readString(); return }
    // messageActionChangeCreator#e188503b newCreatorId:long
    // Api16: parse_messageActionChangeCreator reads Int64 (single field)
    if (constructor == 0xe188503b) { let _ = d.readInt64(); return }
    // messageActionManagedBotCreated#16605e3e botId:long
    if (constructor == 0x16605e3e) { let _ = d.readInt64(); return }
    // messageActionNewCreatorPending#b07ed085 newCreatorId:long
    if (constructor == 0xb07ed085) { let _ = d.readInt64(); return }
    // messageActionSuggestedPostRefund#69f916f8 flags:#
    if (constructor == 0x69f916f8) { let _ = d.readInt32(); return }

    // ── messageActionChatCreate#bd47cbad title:string users:Vector<long> ────────
    if (constructor == 0xbd47cbad) {
        let _ = d.readString()
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { let _ = d.readInt64() }
        }
        return
    }

    // ── messageActionChatAddUser#15cefd00 users:Vector<long> ────────────────────
    if (constructor == 0x15cefd00) {
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { let _ = d.readInt64() }
        }
        return
    }

    // ── messageActionChannelMigrateFrom#ea3948e9 title:string chat_id:long ──────
    if (constructor == 0xea3948e9) { let _ = d.readString(); let _ = d.readInt64(); return }

    // ── messageActionGameScore#92a72876 game_id:long score:int ──────────────────
    if (constructor == 0x92a72876) { let _ = d.readInt64(); let _ = d.readInt32(); return }

    // ── messageActionPhoneCall#80e11a7f ──────────────────────────────────────────
    // flags:# call_id:long reason:flags.0?PhoneCallDiscardReason duration:flags.1?int
    if (constructor == 0x80e11a7f) {
        let flags = d.readInt32()
        let _ = d.readInt64()  // call_id
        if ((flags & 1) != 0) { let _ = d.readUInt32() }  // PhoneCallDiscardReason ctor
        if ((flags & 2) != 0) { let _ = d.readInt32() }   // duration
        return
    }

    // ── messageActionBotAllowed#c516d679 ────────────────────────────────────────
    // flags:# attach_menu:flags.2?true web_app:flags.3?true domain:flags.0?string app:flags.1?BotApp
    if (constructor == 0xc516d679) {
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readString() }  // domain
        if ((flags & 2) != 0) { skipBotApp(d) }           // app (boxed BotApp)
        return
    }

    // ── messageActionSecureValuesSent#d95c6154 / messageActionSecureValuesSentMe#1b287353 ──
    if (constructor == 0xd95c6154) {
        skipGenericVector(d)  // types:Vector<SecureValueType>
        return
    }
    if (constructor == 0x1b287353) {
        skipGenericVector(d)              // values:Vector<SecureValue>
        skipSecureCredentialsEncrypted(d) // credentials:SecureCredentialsEncrypted (boxed)
        return
    }

    // ── COLLISION FIX: messageActionGeoProximityReached#98e0d697 ────────────────
    // Api0 dict[-1730095465] = 0x98e0d697  (previously incorrectly mapped to HistoryClear)
    // from_id:Peer(boxed) to_id:Peer(boxed) distance:int
    if (constructor == 0x98e0d697) {
        let _ = PeerResponse.deserializeBoxed(d)  // from_id (boxed Peer: read ctor sig + fields)
        let _ = PeerResponse.deserializeBoxed(d)  // to_id
        let _ = d.readInt32()                     // distance
        return
    }

    // ── messageActionGroupCall#7a0d7f42 ─────────────────────────────────────────
    // flags:# call:InputGroupCall(boxed) duration:flags.0?int
    // FIXED: call is boxed InputGroupCall — must read ctor sig (4 bytes) before id+access_hash
    if (constructor == 0x7a0d7f42) {
        let flags = d.readInt32()
        let _ = d.readUInt32()  // InputGroupCall ctor sig (inputGroupCall#d8aa840f)
        let _ = d.readInt64()   // call.id
        let _ = d.readInt64()   // call.access_hash
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // duration
        return
    }

    // ── messageActionGroupCallScheduled#b3a07661 ────────────────────────────────
    // call:InputGroupCall(boxed) schedule_date:int
    // FIXED: boxed InputGroupCall — must read ctor sig first
    if (constructor == 0xb3a07661) {
        let _ = d.readUInt32()  // InputGroupCall ctor sig
        let _ = d.readInt64()   // call.id
        let _ = d.readInt64()   // call.access_hash
        let _ = d.readInt32()   // schedule_date
        return
    }

    // ── messageActionInviteToGroupCall#502f92f7 ──────────────────────────────────
    // call:InputGroupCall(boxed) users:Vector<long>
    // FIXED: boxed InputGroupCall — must read ctor sig first
    if (constructor == 0x502f92f7) {
        let _ = d.readUInt32()  // InputGroupCall ctor sig
        let _ = d.readInt64()   // call.id
        let _ = d.readInt64()   // call.access_hash
        skipInt64Vector(d)      // users
        return
    }

    // ── COLLISION FIX: messageActionSetMessagesTTL#3c134d7b ─────────────────────
    // Api0 dict[1007897979] = 0x3c134d7b  (previously incorrectly mapped to WebViewDataSentMe)
    // flags:# period:int auto_setting_from:flags.0?long
    if (constructor == 0x3c134d7b) {
        let flags = d.readInt32()
        let _ = d.readInt32()  // period
        if ((flags & 1) != 0) { let _ = d.readInt64() }  // auto_setting_from
        return
    }

    // ── COLLISION FIX: messageActionWebViewDataSentMe#47dd8079 ──────────────────
    // Api0 dict[1205698681] = 0x47dd8079  (previously incorrectly mapped to SetChatTheme)
    // text:string data:string
    if (constructor == 0x47dd8079) {
        let _ = d.readString()  // text (button text)
        let _ = d.readString()  // data
        return
    }

    // ── messageActionSetChatTheme#b91bbd3a ───────────────────────────────────────
    // Api0 dict[-1189364422] = 0xb91bbd3a
    // theme:ChatTheme(boxed)
    if (constructor == 0xb91bbd3a) {
        skipChatTheme(d)  // ChatTheme (boxed) — two variants: chatTheme#c3dffc04 / chatThemeUniqueGift#3458f9c8
        return
    }

    // ── messageActionSetChatWallPaper#5060a3f4 ───────────────────────────────────
    // Api0 dict[1348510708] = 0x5060a3f4  flags:# wallpaper:WallPaper(boxed)
    if (constructor == 0x5060a3f4 || constructor == 0xe7e75f97) {
        let _ = d.readInt32()  // flags
        skipWallPaper(d)
        return
    }

    // ── messageActionTopicCreate#0d999256 ────────────────────────────────────────
    // Api0 dict[228168278] = 0x0d999256
    // flags:# title:string icon_color:int icon_emoji_id:flags.0?long
    if (constructor == 0x0d999256 || constructor == 0x0c0787d6) {
        let flags = d.readInt32()
        let _ = d.readString()   // title
        let _ = d.readInt32()    // icon_color
        if ((flags & 1) != 0) { let _ = d.readInt64() }  // icon_emoji_id
        return
    }

    // ── messageActionTopicEdit#c0944820 ──────────────────────────────────────────
    // flags:# title:flags.0?string icon_emoji_id:flags.1?long closed:flags.2?Bool hidden:flags.3?Bool
    if (constructor == 0xc0944820) {
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readString() }   // title
        if ((flags & 2) != 0) { let _ = d.readInt64() }    // icon_emoji_id
        if ((flags & 4) != 0) { let _ = d.readUInt32() }   // closed (boxed Bool)
        if ((flags & 8) != 0) { let _ = d.readUInt32() }   // hidden (boxed Bool)
        return
    }

    // ── messageActionRequestedPeer#31518e9b buttonId:int peers:Vector<Peer> ──────
    if (constructor == 0x31518e9b) {
        let _ = d.readInt32()   // buttonId
        skipGenericVector(d)    // peers:Vector<Peer> (boxed elements)
        return
    }

    // ── messageActionRequestedPeerSentMe#93b31848 buttonId:int peers:Vector<RequestedPeer> ──
    if (constructor == 0x93b31848) {
        let _ = d.readInt32()   // buttonId
        skipGenericVector(d)    // peers:Vector<RequestedPeer>
        return
    }

    // ── messageActionChatJoinedByRequest (no body) already done above ─────────

    // ── messageActionPaymentSent#c624b16e (current layer) ────────────────────────
    // Api0 dict[-970673810] = 0xc624b16e
    // flags:# currency:string total_amount:long invoice_slug:flags.0?string subscription_until_date:flags.4?int
    // Also support legacy ctors 0x96163f56 / 0x8f31b327
    if (constructor == 0xc624b16e || constructor == 0x96163f56 || constructor == 0x8f31b327) {
        let flags = d.readInt32()
        let _ = d.readString()    // currency
        let _ = d.readInt64()     // totalAmount
        if ((flags & 1) != 0) { let _ = d.readString() }   // invoiceSlug
        if ((flags & 16) != 0) { let _ = d.readInt32() }   // subscriptionUntilDate
        return
    }

    // ── messageActionPaymentSentMe#ffa00ccc ──────────────────────────────────────
    // Api0 dict[-6288180] = 0xffa00ccc
    // flags:# currency:string total_amount:long payload:bytes info:flags.0?PaymentRequestedInfo
    //   shipping_option_id:flags.1?string charge:PaymentCharge subscription_until_date:flags.4?int
    if (constructor == 0xffa00ccc) {
        let flags = d.readInt32()
        let _ = d.readString()    // currency
        let _ = d.readInt64()     // totalAmount
        let _ = d.readBytes()     // payload
        if ((flags & 1) != 0) { skipPaymentRequestedInfo(d) }  // info (PaymentRequestedInfo, boxed)
        if ((flags & 2) != 0) { let _ = d.readString() }       // shippingOptionId
        skipPaymentCharge(d)      // charge:PaymentCharge (always present, boxed)
        if ((flags & 16) != 0) { let _ = d.readInt32() }       // subscriptionUntilDate
        return
    }

    // ── messageActionPaymentRefunded#41b3e202 (current layer) ────────────────────
    // Api0 dict[1102307842] = 0x41b3e202
    // flags:# peer:Peer(boxed) currency:string total_amount:long payload:flags.0?bytes charge:PaymentCharge(boxed)
    if (constructor == 0x41b3e202) {
        let flags = d.readInt32()
        let _ = PeerResponse.deserializeBoxed(d)  // peer (boxed)
        let _ = d.readString()                    // currency
        let _ = d.readInt64()                     // totalAmount
        if ((flags & 1) != 0) { let _ = d.readBytes() }   // payload
        skipPaymentCharge(d)                      // charge:PaymentCharge (always present, boxed)
        return
    }

    // ── messageActionPaidMessagesPrice#84b88578 ──────────────────────────────────
    // Api0 dict[-2068281992] = 0x84b88578  flags:# stars:long
    if (constructor == 0x84b88578) {
        let _ = d.readInt32()   // flags
        let _ = d.readInt64()   // stars
        return
    }

    // ── messageActionPaidMessagesRefunded#ac1f1fcd ────────────────────────────────
    // Api0 dict[-1407246387] = 0xac1f1fcd  count:int stars:long
    // Note: parse_messageActionPaidMessagesRefunded reads Int32 then Int64
    if (constructor == 0xac1f1fcd) {
        let _ = d.readInt32()   // count (flags-like)
        let _ = d.readInt64()   // stars
        return
    }

    // ── COLLISION FIX: messageActionGiftStars#45d5b021 ────────────────────────────
    // Api0 dict[1171632161] = 0x45d5b021  (previously incorrectly mapped to PaymentRefunded)
    // flags:# currency:string amount:long stars:long
    //   crypto_currency:flags.0?string crypto_amount:flags.0?long transaction_id:flags.1?string
    if (constructor == 0x45d5b021) {
        let flags = d.readInt32()
        let _ = d.readString()   // currency
        let _ = d.readInt64()    // amount
        let _ = d.readInt64()    // stars
        if ((flags & 1) != 0) { let _ = d.readString() }   // cryptoCurrency
        if ((flags & 1) != 0) { let _ = d.readInt64() }    // cryptoAmount
        if ((flags & 2) != 0) { let _ = d.readString() }   // transactionId (string, NOT int64)
        return
    }

    // ── messageActionGiftPremium#48e91302 (current layer) ────────────────────────
    // Api0 dict[1223234306] = 0x48e91302
    // flags:# currency:string amount:long months:int
    //   crypto_currency:flags.0?string crypto_amount:flags.0?long message:flags.1?TextWithEntities(boxed)
    if (constructor == 0x48e91302) {
        let flags = d.readInt32()
        let _ = d.readString()   // currency
        let _ = d.readInt64()    // amount
        let _ = d.readInt32()    // months (called "days" in GiftCode, "months" here per field name)
        if ((flags & 1) != 0) { let _ = d.readString() }   // cryptoCurrency
        if ((flags & 1) != 0) { let _ = d.readInt64() }    // cryptoAmount
        if ((flags & 2) != 0) { skipTextWithEntities(d) }  // message (boxed TextWithEntities)
        return
    }

    // ── messageActionGiftCode#31c48347 (current layer) ───────────────────────────
    // Api0 dict[834962247] = 0x31c48347
    // flags:# boost_peer:flags.1?Peer(boxed) months:int slug:string
    //   currency:flags.2?string amount:flags.2?long crypto_currency:flags.3?string
    //   crypto_amount:flags.3?long message:flags.4?TextWithEntities(boxed)
    if (constructor == 0x31c48347) {
        let flags = d.readInt32()
        if ((flags & 2) != 0) { let _ = PeerResponse.deserializeBoxed(d) }  // boostPeer
        let _ = d.readInt32()   // months (days)
        let _ = d.readString()  // slug
        if ((flags & 4) != 0) { let _ = d.readString() }   // currency
        if ((flags & 4) != 0) { let _ = d.readInt64() }    // amount
        if ((flags & 8) != 0) { let _ = d.readString() }   // cryptoCurrency
        if ((flags & 8) != 0) { let _ = d.readInt64() }    // cryptoAmount
        if ((flags & 16) != 0) { skipTextWithEntities(d) } // message (boxed TextWithEntities)
        return
    }

    // ── messageActionGiftTon#a8a3c699 ────────────────────────────────────────────
    // Api0 dict[-1465661799] = 0xa8a3c699
    // flags:# currency:string amount:long crypto_currency:string crypto_amount:long
    //   transaction_id:flags.0?string
    if (constructor == 0xa8a3c699) {
        let flags = d.readInt32()
        let _ = d.readString()   // currency
        let _ = d.readInt64()    // amount
        let _ = d.readString()   // cryptoCurrency
        let _ = d.readInt64()    // cryptoAmount
        if ((flags & 1) != 0) { let _ = d.readString() }  // transactionId
        return
    }

    // ── messageActionPrizeStars#b00c47a2 (current layer) ─────────────────────────
    // Api0 dict[-1341372510] = 0xb00c47a2
    // flags:# stars:long transaction_id:string boost_peer:Peer(boxed) giveaway_msg_id:int
    if (constructor == 0xb00c47a2) {
        let flags = d.readInt32()
        let _ = d.readInt64()                     // stars
        let _ = d.readString()                    // transactionId
        let _ = PeerResponse.deserializeBoxed(d)  // boostPeer (boxed)
        let _ = d.readInt32()                     // giveawayMsgId
        return
    }

    // ── messageActionGiveawayLaunch#a80f51e4 (current layer) ─────────────────────
    // Api0 dict[-1475391004] = 0xa80f51e4  flags:# stars:flags.0?long
    if (constructor == 0xa80f51e4) {
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt64() }  // stars
        return
    }

    // ── messageActionGiveawayResults#87e2f155 (current layer) ────────────────────
    // Api0 dict[-2015170219] = 0x87e2f155  flags:# winners_count:int unclaimed_count:int
    if (constructor == 0x87e2f155) {
        let _ = d.readInt32()   // flags
        let _ = d.readInt32()   // winnersCount
        let _ = d.readInt32()   // unclaimedCount
        return
    }

    // ── messageActionBoostApply#cc02aa6d (current layer) ─────────────────────────
    // Api0 dict[-872240531] = 0xcc02aa6d  boosts:int
    if (constructor == 0xcc02aa6d) { let _ = d.readInt32(); return }

    // ── messageActionNoForwardsRequest#3e2793ba ────────────────────────────────────
    // Api0 dict[1042781114] = 0x3e2793ba
    // flags:# prev_value:Bool(boxed) new_value:Bool(boxed)
    if (constructor == 0x3e2793ba) {
        let _ = d.readInt32()   // flags
        let _ = d.readUInt32()  // prevValue (boxed Bool)
        let _ = d.readUInt32()  // newValue (boxed Bool)
        return
    }

    // ── messageActionNoForwardsToggle#bf7d6572 ────────────────────────────────────
    // Api0 dict[-1082301070] = 0xbf7d6572
    // prev_value:Bool(boxed) new_value:Bool(boxed)
    if (constructor == 0xbf7d6572) {
        let _ = d.readUInt32()  // prevValue
        let _ = d.readUInt32()  // newValue
        return
    }

    // ── messageActionSuggestBirthday#2c8f2a25 ─────────────────────────────────────
    // Api0 dict[747579941] = 0x2c8f2a25  birthday:Birthday(boxed)
    if (constructor == 0x2c8f2a25) {
        skipBirthday(d)  // Birthday (boxed): ctor + flags:int + day:int + month:int + flags.0?year:int
        return
    }

    // ── messageActionSuggestedPostApproval#ee7a1596 ────────────────────────────────
    // Api0 dict[-293988970] = 0xee7a1596
    // flags:# reject_comment:flags.2?string schedule_date:flags.3?int price:flags.4?StarsAmount(boxed)
    if (constructor == 0xee7a1596) {
        let flags = d.readInt32()
        if ((flags & 4) != 0) { let _ = d.readString() }   // rejectComment
        if ((flags & 8) != 0) { let _ = d.readInt32() }    // scheduleDate
        if ((flags & 16) != 0) { skipStarsAmount(d) }      // price (StarsAmount, boxed)
        return
    }

    // ── messageActionSuggestedPostSuccess#95ddcf69 ────────────────────────────────
    // Api0 dict[-1780625559] = 0x95ddcf69  price:StarsAmount(boxed)
    if (constructor == 0x95ddcf69) {
        skipStarsAmount(d)  // price (StarsAmount, boxed)
        return
    }

    // ── messageActionTodoAppendTasks#c7edbc83 ─────────────────────────────────────
    // Api0 dict[-940721021] = 0xc7edbc83  list:Vector<TodoItem>
    if (constructor == 0xc7edbc83) {
        skipGenericVector(d)  // Vector<TodoItem>
        return
    }

    // ── messageActionTodoCompletions#cc7c5c89 ─────────────────────────────────────
    // Api0 dict[-864265079] = 0xcc7c5c89  completed:Vector<int> incompleted:Vector<int>
    if (constructor == 0xcc7c5c89) {
        // completed: Vector<int>
        let vecCtor1 = d.readUInt32()
        if (vecCtor1 == TLConstructors.VECTOR) {
            let cnt1 = d.readInt32()
            for (_i in 0..Int64(cnt1)) { let _ = d.readInt32() }
        }
        // incompleted: Vector<int>
        let vecCtor2 = d.readUInt32()
        if (vecCtor2 == TLConstructors.VECTOR) {
            let cnt2 = d.readInt32()
            for (_i in 0..Int64(cnt2)) { let _ = d.readInt32() }
        }
        return
    }

    // ── messageActionPollAppendAnswer#9da1cd6c ────────────────────────────────────
    // Api0 dict[-1650340500] = 0x9da1cd6c  answer:PollAnswer(boxed)
    if (constructor == 0x9da1cd6c) {
        skipPollAnswer(d)  // PollAnswer (boxed): ctor + TextWithEntities + option:bytes
        return
    }

    // ── messageActionPollDeleteAnswer#399674dc ────────────────────────────────────
    // Api0 dict[966161628] = 0x399674dc  answer:PollAnswer(boxed)
    if (constructor == 0x399674dc) {
        skipPollAnswer(d)  // PollAnswer (boxed): ctor + TextWithEntities + option:bytes
        return
    }

    // ── messageActionConferenceCall#2ffe2f7a ──────────────────────────────────────
    // Api0 dict[805187450] = 0x2ffe2f7a
    // flags:# call_id:long duration:flags.2?int other_participants:flags.3?Vector<Peer>
    if (constructor == 0x2ffe2f7a) {
        let flags = d.readInt32()
        let _ = d.readInt64()    // callId
        if ((flags & 4) != 0) { let _ = d.readInt32() }   // duration
        if ((flags & 8) != 0) { skipGenericVector(d) }     // otherParticipants:Vector<Peer>
        return
    }

    // ── messageActionStarGift#ea2c31d3 ───────────────────────────────────────────
    // Api0 dict[-366202413] = 0xea2c31d3
    // Very complex: flags:# gift:StarGift(boxed) message:flags.1?TextWithEntities(boxed)
    //   convert_stars:flags.4?long upgrade_msg_id:flags.5?int upgrade_stars:flags.8?long
    //   from_id:flags.11?Peer(boxed) peer:flags.12?Peer(boxed) saved_id:flags.12?long
    //   prepaid_upgrade_hash:flags.14?string gift_msg_id:flags.15?int to_id:flags.18?Peer(boxed)
    //   gift_num:flags.19?int
    if (constructor == 0xea2c31d3) {
        let flags = d.readInt32()
        skipStarGiftBoxed(d)                                    // gift:StarGift (always present)
        if ((flags & 2) != 0) { skipTextWithEntities(d) }      // message flags.1
        if ((flags & 16) != 0) { let _ = d.readInt64() }       // convertStars flags.4
        if ((flags & 32) != 0) { let _ = d.readInt32() }       // upgradeMsgId flags.5
        if ((flags & 256) != 0) { let _ = d.readInt64() }      // upgradeStars flags.8
        if ((flags & 2048) != 0) { let _ = PeerResponse.deserializeBoxed(d) }  // fromId flags.11
        if ((flags & 4096) != 0) { let _ = PeerResponse.deserializeBoxed(d) }  // peer flags.12
        if ((flags & 4096) != 0) { let _ = d.readInt64() }     // savedId flags.12
        if ((flags & 16384) != 0) { let _ = d.readString() }   // prepaidUpgradeHash flags.14
        if ((flags & 32768) != 0) { let _ = d.readInt32() }    // giftMsgId flags.15
        if ((flags & 262144) != 0) { let _ = PeerResponse.deserializeBoxed(d) } // toId flags.18
        if ((flags & 524288) != 0) { let _ = d.readInt32() }   // giftNum flags.19
        return
    }

    // ── messageActionStarGiftUnique#e6c31522 ──────────────────────────────────────
    // Api0 dict[-423422686] = 0xe6c31522
    // flags:# gift:StarGift(boxed)
    //   can_export_at:flags.3?int transfer_stars:flags.4?long from_id:flags.6?Peer(boxed)
    //   peer:flags.7?Peer(boxed) saved_id:flags.7?long resale_amount:flags.8?StarsAmount(boxed)
    //   can_transfer_at:flags.9?int can_resell_at:flags.10?int
    //   drop_original_details_stars:flags.12?long can_craft_at:flags.15?int
    if (constructor == 0xe6c31522) {
        let flags = d.readInt32()
        skipStarGiftBoxed(d)                                    // gift:StarGift (always present)
        if ((flags & 8) != 0) { let _ = d.readInt32() }        // canExportAt flags.3
        if ((flags & 16) != 0) { let _ = d.readInt64() }       // transferStars flags.4
        if ((flags & 64) != 0) { let _ = PeerResponse.deserializeBoxed(d) }  // fromId flags.6
        if ((flags & 128) != 0) { let _ = PeerResponse.deserializeBoxed(d) } // peer flags.7
        if ((flags & 128) != 0) { let _ = d.readInt64() }      // savedId flags.7
        if ((flags & 256) != 0) { skipStarsAmount(d) }          // resaleAmount:StarsAmount flags.8
        if ((flags & 512) != 0) { let _ = d.readInt32() }      // canTransferAt flags.9
        if ((flags & 1024) != 0) { let _ = d.readInt32() }     // canResellAt flags.10
        if ((flags & 4096) != 0) { let _ = d.readInt64() }     // dropOriginalDetailsStars flags.12
        if ((flags & 32768) != 0) { let _ = d.readInt32() }    // canCraftAt flags.15
        return
    }

    // ── messageActionStarGiftPurchaseOffer#774278d4 ───────────────────────────────
    // Api0 dict[2000845012] = 0x774278d4
    // flags:# gift:StarGift(boxed) price:StarsAmount(boxed) expires_at:int
    if (constructor == 0x774278d4) {
        let _ = d.readInt32()   // flags
        skipStarGiftBoxed(d)    // gift
        skipStarsAmount(d)      // price:StarsAmount (boxed)
        let _ = d.readInt32()   // expiresAt
        return
    }

    // ── messageActionStarGiftPurchaseOfferDeclined#73ada76b ──────────────────────
    // Api0 dict[1940760427] = 0x73ada76b
    // flags:# gift:StarGift(boxed) price:StarsAmount(boxed)
    if (constructor == 0x73ada76b) {
        let _ = d.readInt32()   // flags
        skipStarGiftBoxed(d)    // gift
        skipStarsAmount(d)      // price:StarsAmount (boxed)
        return
    }

    // ── 其他未知的 action 类型 — 抛出异常以触发消息解析恢复 ────────────────────────
    Hilog.info(0, "CjTelegram", "[skipMessageAction] Unknown action constructor: 0x${toHex32(constructor)}")
    throw IllegalArgumentException("[skipMessageAction] Unknown action constructor: 0x${toHex32(constructor)}")
}

// ==================== Boxed Type Skip Helpers (for skipMessageActionWithConstructor) ====================

/**
 * skipPaymentCharge — skip a boxed PaymentCharge.
 * paymentCharge#ea02c27e (Api0 dict[-368917890]) id:string providerChargeId:string
 * iOS ref: Api20.swift parse_paymentCharge — reads two strings
 */
func skipPaymentCharge(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()  // paymentCharge#ea02c27e
    if (ctor == 0xea02c27e) {
        let _ = d.readString()  // id
        let _ = d.readString()  // providerChargeId
    }
    // Unknown constructor: silently ignore (no fields consumed beyond ctor)
}

/**
 * skipStarsAmount — skip a boxed StarsAmount.
 * Two variants (iOS Api27.swift):
 *   starsAmount#bbb6b4a3  (Api0 dict[-1145654109]) amount:long nanos:int
 *   starsTonAmount#74aee3e0 (Api0 dict[1957618656]) amount:long
 */
func skipStarsAmount(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xbbb6b4a3) {
        // starsAmount: amount:long nanos:int
        let _ = d.readInt64()  // amount
        let _ = d.readInt32()  // nanos
    } else if (ctor == 0x74aee3e0) {
        // starsTonAmount: amount:long
        let _ = d.readInt64()  // amount
    }
    // Unknown constructor: no additional fields consumed
}

/**
 * skipBirthday — skip a boxed Birthday.
 * birthday#6c8e1e06 (Api0 dict[1821253126]) flags:# day:int month:int year:flags.0?int
 * iOS ref: Api1.swift parse_birthday — reads flags + day + month + optional year
 */
func skipBirthday(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()  // birthday#6c8e1e06
    if (ctor == 0x6c8e1e06) {
        let flags = d.readInt32()  // flags
        let _ = d.readInt32()      // day
        let _ = d.readInt32()      // month
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // year (flags.0)
    }
}

/**
 * skipSecureCredentialsEncrypted — skip a boxed SecureCredentialsEncrypted.
 * secureCredentialsEncrypted#33f0ea47 (Api0 dict[871426631]) data:bytes hash:bytes secret:bytes
 * iOS ref: Api25.swift parse_secureCredentialsEncrypted — reads three byte buffers
 */
func skipSecureCredentialsEncrypted(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()  // secureCredentialsEncrypted#33f0ea47
    if (ctor == 0x33f0ea47) {
        let _ = d.readBytes()  // data
        let _ = d.readBytes()  // hash
        let _ = d.readBytes()  // secret
    }
}

/**
 * skipPaymentRequestedInfo — skip a boxed PaymentRequestedInfo (package-level).
 * paymentRequestedInfo#909c3f94 (Api0 dict[-1868808300])
 * flags:# name:flags.0?string phone:flags.1?string email:flags.2?string
 *   shipping_address:flags.3?PostAddress(boxed)
 * iOS ref: Api20.swift parse_paymentRequestedInfo
 * PostAddress fields: street_line1:string street_line2:string city:string state:string
 *   country_iso2:string post_code:string
 */
func skipPaymentRequestedInfo(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()  // paymentRequestedInfo#909c3f94
    if (ctor == 0x909c3f94) {
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readString() }   // name
        if ((flags & 2) != 0) { let _ = d.readString() }   // phone
        if ((flags & 4) != 0) { let _ = d.readString() }   // email
        if ((flags & 8) != 0) {
            // PostAddress (boxed): read ctor then 6 strings
            let _ = d.readUInt32()  // PostAddress ctor (postAddress#1e8caaeb)
            let _ = d.readString()  // street_line1
            let _ = d.readString()  // street_line2
            let _ = d.readString()  // city
            let _ = d.readString()  // state
            let _ = d.readString()  // country_iso2
            let _ = d.readString()  // post_code
        }
    }
}

/**
 * skipChatTheme — skip a boxed ChatTheme.
 * Two variants (iOS Api5.swift, Api0.swift):
 *   chatTheme#c3dffc04 (Api0 dict[-1008731132]) emoticon:string
 *   chatThemeUniqueGift#3458f9c8 (Api0 dict[878246344]) gift:StarGift(boxed) theme_settings:Vector<ThemeSettings>(boxed)
 */
func skipChatTheme(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xc3dffc04) {
        // chatTheme: emoticon:string
        let _ = d.readString()  // emoticon
    } else if (ctor == 0x3458f9c8) {
        // chatThemeUniqueGift: gift:StarGift(boxed) theme_settings:Vector<ThemeSettings>(boxed)
        skipStarGiftBoxed(d)  // gift
        // theme_settings: Vector<ThemeSettings>(boxed elements)
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                skipThemeSettings(d)  // each ThemeSettings is non-boxed inside vector
            }
        }
    }
    // Unknown constructor: no additional fields
}

// ==================== Message 字段跳过函数 ====================

/**
 * 跳过 MessageMedia（所有常见类型）
 */
func skipMessageMedia(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    
    // messageMediaEmpty#3ded6320
    if (constructor == 0x3ded6320) { return }
    
    // messageMediaPhoto#e216eb63 (current, iOS dict[-501814429]) — flags:Int32 photo?[flags.0](boxed Photo) ttl_seconds?[flags.2](Int32) video?[flags.4](boxed Document)
    // messageMediaPhoto#695150d7 (legacy)                        — flags:Int32 photo?[flags.0](boxed Photo) ttl_seconds?[flags.2](Int32)
    if (constructor == 0xe216eb63 || constructor == 0x695150d7) {
        let flags = d.readInt32()
        if ((flags & 1) != 0) { skipPhoto(d) }          // photo?[flags.0]
        if ((flags & 4) != 0) { let _ = d.readInt32() } // ttl_seconds?[flags.2]
        // video?[flags.4] — new field in 0xe216eb63; safe to check for both (legacy never sets bit 4)
        if ((flags & 16) != 0) { skipDocument(d) }       // video?[flags.4]:Document(boxed)
        return
    }
    
    // messageMediaGeo#56e0d474
    if (constructor == 0x56e0d474) {
        skipGeoPoint(d)
        return
    }
    
    // messageMediaContact#70322949
    if (constructor == 0x70322949) {
        let _ = d.readString()
        let _ = d.readString()
        let _ = d.readString()
        let _ = d.readString()
        let _ = d.readInt64()
        return
    }
    
    // messageMediaUnsupported#9f84f49e
    if (constructor == 0x9f84f49e) { return }
    
    // messageMediaDocument#52d8ccd9 (Layer 221 - 新构造器，严格匹配 TelegramHarmony)
    if (constructor == 0x52d8ccd9) {
        let flags = d.readInt32()
        if ((flags & 1) != 0) { skipDocument(d) }         // document - bit 0
        if ((flags & 32) != 0) { skipDocumentVector(d) }  // altDocuments - bit 5 (Vector<Document>)
        if ((flags & 512) != 0) { skipPhoto(d) }          // videoCover - bit 9
        if ((flags & 1024) != 0) { let _ = d.readInt32() } // videoTimestamp - bit 10
        if ((flags & 4) != 0) { let _ = d.readInt32() }   // ttlSeconds - bit 2
        return
    }
    
    // messageMediaDocument#4cf4d72d (old) / #dd570ee5 (old)
    if (constructor == 0x4cf4d72d || constructor == 0xdd570ee5) {
        let flags = d.readInt32()
        if ((flags & 4) != 0) { skipDocument(d) }   // document - bit 2
        if ((flags & 32) != 0) { skipDocument(d) }  // altDocument - bit 5
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // ttlSeconds - bit 0
        return
    }
    
    // messageMediaWebPage#ddf10c3b / #a32dd600
    if (constructor == 0xddf10c3b || constructor == 0xa32dd600) {
        let _ = d.readInt32()
        skipWebPage(d)
        return
    }
    
    // messageMediaVenue#2ec0533f
    if (constructor == 0x2ec0533f) {
        skipGeoPoint(d)
        let _ = d.readString()
        let _ = d.readString()
        let _ = d.readString()
        let _ = d.readString()
        let _ = d.readString()
        return
    }
    
    // messageMediaGame#fdb19008
    if (constructor == 0xfdb19008) {
        skipGame(d)
        return
    }
    
    // messageMediaInvoice#f6a548d3
    if (constructor == 0xf6a548d3) {
        let flags = d.readInt32()
        let _ = d.readString()
        let _ = d.readString()
        if ((flags & 1) != 0) { skipWebDocument(d) }
        if ((flags & 4) != 0) { let _ = d.readInt32() }
        let _ = d.readString()
        let _ = d.readInt64()
        let _ = d.readString()
        if ((flags & 16) != 0) { skipExtendedMedia(d) }
        return
    }
    
    // messageMediaGeoLive#b940c666
    if (constructor == 0xb940c666) {
        let flags = d.readInt32()
        skipGeoPoint(d)
        if ((flags & 1) != 0) { let _ = d.readInt32() }
        let _ = d.readInt32()
        if ((flags & 2) != 0) { let _ = d.readInt32() }
        return
    }
    
    // messageMediaPoll#773f4e66 (current, iOS dict[2000637542]) — flags:Int32 poll:Poll(boxed) results:PollResults(boxed) attachedMedia?[flags.0]:MessageMedia(boxed)
    // messageMediaPoll#4bd6e798 (legacy)                      — poll:Poll(boxed) results:PollResults(boxed)
    if (constructor == 0x773f4e66 || constructor == 0x4bd6e798) {
        let pollSkipFlags: Int32 = if (constructor == 0x773f4e66) { d.readInt32() } else { 0 }
        skipPoll(d)
        skipPollResults(d)
        if ((pollSkipFlags & 1) != 0) { skipMessageMedia(d) }  // attachedMedia?[flags.0]
        return
    }
    
    // messageMediaDice#08cbec07 (Layer 221 新构造器)
    if (constructor == 0x08cbec07) {
        let flags = d.readInt32()
        let _ = d.readInt32()   // value
        let _ = d.readString()  // emoticon
        if ((flags & 1) != 0) { skipEmojiGameOutcome(d) }  // gameOutcome - bit 0
        return
    }
    
    // messageMediaDice#3f7ee58b (old)
    if (constructor == 0x3f7ee58b) {
        let _ = d.readInt32()
        let _ = d.readString()
        return
    }
    
    // messageMediaStory#68cb6283 / #c6b68300
    if (constructor == 0x68cb6283 || constructor == 0xc6b68300) {
        let flags = d.readInt32()
        let _ = PeerResponse.deserializeBoxed(d)
        let _ = d.readInt32()
        if ((flags & 1) != 0) { skipStoryItem(d) }
        return
    }
    
    // messageMediaGiveaway#aa073beb (Layer 221) / #daad85b0 (old)
    if (constructor == 0xaa073beb || constructor == 0xdaad85b0) {
        let flags = d.readInt32()
        skipInt64Vector(d)  // channels
        if ((flags & 2) != 0) { skipStringVector(d) }  // countriesIso2 - bit 1
        if ((flags & 8) != 0) { let _ = d.readString() }  // prizeDescription - bit 3
        let _ = d.readInt32()  // quantity
        if ((flags & 16) != 0) { let _ = d.readInt32() }  // months - bit 4
        if ((flags & 32) != 0) { let _ = d.readInt64() }  // stars - bit 5
        let _ = d.readInt32()  // untilDate
        return
    }
    
    // messageMediaPaidMedia#a8852491
    if (constructor == 0xa8852491) {
        let _ = d.readInt64()  // starsAmount
        skipExtendedMediaVector(d)  // extendedMedia
        return
    }
    
    // 其他未知的 media 类型 — 抛出异常以触发消息解析恢复
    Hilog.info(0, "CjTelegram", "[skipMessageMedia] Unknown media constructor: ${constructor}")
    throw IllegalArgumentException("[skipMessageMedia] Unknown media constructor: ${constructor}")
}

// Helper: skip Vector<Document>
func skipDocumentVector(d: TLDeserializer): Unit {
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            skipDocument(d)
        }
    }
}

// Helper: skip Vector<Int64>
func skipInt64Vector(d: TLDeserializer): Unit {
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            let _ = d.readInt64()
        }
    }
}

// Helper: skip Vector<String>
func skipStringVector(d: TLDeserializer): Unit {
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            let _ = d.readString()
        }
    }
}

// Helper: skip Vector<MessageExtendedMedia>
func skipExtendedMediaVector(d: TLDeserializer): Unit {
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            skipExtendedMedia(d)
        }
    }
}

// skipEmojiGameOutcome (Layer 221)
func skipEmojiGameOutcome(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor
    // emojiGameOutcome has simple fields
    let _ = d.readInt32()   // flags/data
}

// skipForumTopic - 匹配 TelegramHarmony
func skipForumTopic(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    // forumTopicDeleted (0x023f109b)
    if (constructor == 0x023f109b) {
        let _ = d.readInt32() // id
        return
    }
    // forumTopic (0x71701da9)
    if (constructor == 0x71701da9) {
        let flags = d.readInt32()
        let _ = d.readInt32() // id
        let _ = d.readInt32() // date
        let _ = d.readString() // title
        let _ = d.readInt32() // icon_color
        if ((flags & 1) != 0) { let _ = d.readInt64() } // icon_emoji_id
        let _ = d.readInt32() // top_message
        let _ = d.readInt32() // read_inbox_max_id
        let _ = d.readInt32() // read_outbox_max_id
        let _ = d.readInt32() // unread_count
        let _ = d.readInt32() // unread_mentions_count
        let _ = d.readInt32() // unread_reactions_count
        let _ = PeerResponse.deserializeBoxed(d) // from_id
        let _ = skipPeerNotifySettings(d) // notify_settings
        if ((flags & 16) != 0) { skipDraftMessage(d) } // draft
    }
}

// skipSuggestedPost — verified vs Api28.swift parse_suggestedPost + Api0.swift dict[244201445]
// suggestedPost#e92035ea flags:Int32 price?[flags.3]:StarsAmount(boxed) schedule_date?[flags.0]:Int32
// Old code: had wrong bit 1 for sendAsPeerId (field does not exist); missing bit 3 for price:StarsAmount.
func skipSuggestedPost(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    if ((flags & 8) != 0) { skipStarsAmount(d) }   // price?[flags.3]:StarsAmount (boxed)
    if ((flags & 1) != 0) { let _ = d.readInt32() }  // schedule_date?[flags.0]:Int32
}

// skipBotApp - 匹配 TelegramHarmony
func skipBotApp(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x5da674b7) { return }  // botAppNotModified
    // botApp
    let flags = d.readInt32()
    let _ = d.readInt64()   // id
    let _ = d.readInt64()   // accessHash
    let _ = d.readString()  // shortName
    let _ = d.readString()  // title
    let _ = d.readString()  // description
    skipPhoto(d)            // photo
    if ((flags & 1) != 0) { skipDocument(d) }  // document
    let _ = d.readInt64()   // hash
}

// skipSearchPostsFlood - 匹配 TelegramHarmony
func skipSearchPostsFlood(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x6e0b4774) {
        // searchPostsFlood#6e0b4774 flood_wait_seconds:int
        let _ = d.readInt32()
    }
    // 其他构造器无字段
}

/**
 * 跳过 Photo
 */
public func skipPhoto(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x2331b22d) {
        // photoEmpty
        let _ = d.readInt64()  // id
        return
    }
    // photo#fb197a65
    let flags = d.readInt32()
    let _ = d.readInt64()  // id
    let _ = d.readInt64()  // access_hash
    let _ = d.readBytes()  // file_reference
    let _ = d.readInt32()  // date
    // sizes: Vector<PhotoSize>
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            skipPhotoSize(d)
        }
    }
    // video_sizes: flags.1?Vector<VideoSize>
    if ((flags & 2) != 0) {
        let vecConst2 = d.readUInt32()
        if (vecConst2 == TLConstructors.VECTOR) {
            let count2 = d.readInt32()
            for (_i in 0..Int64(count2)) {
                skipVideoSize(d)
            }
        }
    }
    let _ = d.readInt32()  // dc_id
}

/**
 * 跳过 PhotoSize — 严格匹配 TelegramHarmony TLDialogs.ets skipPhotoSize
 * 
 * 支持的构造器（Layer 214）：
 *   photoSizeEmpty#0e17e23c type:string
 *   photoSize#75c78e60 type:string w:int h:int size:int
 *   photoCachedSize#021e1ad6 type:string w:int h:int bytes:bytes
 *   photoStrippedSize#e0b0bc2e type:string bytes:bytes
 *   photoSizeProgressive#fa3efb95 type:string w:int h:int sizes:Vector<int>
 *   photoPathSize#d8214d41 type:string bytes:bytes
 *   photoPathSize#6f8bf5a0 (旧版) type:string bytes:bytes
 */
func skipPhotoSize(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x0e17e23c) {
        // photoSizeEmpty#0e17e23c type:string
        let _ = d.readString()  // type
        return
    }
    if (constructor == 0x75c78e60) {
        // photoSize#75c78e60 type:string w:int h:int size:int
        let _ = d.readString()  // type
        let _ = d.readInt32()  // w
        let _ = d.readInt32()  // h
        let _ = d.readInt32()  // size
        return
    }
    if (constructor == 0x021e1ad6) {
        // photoCachedSize#021e1ad6 type:string w:int h:int bytes:bytes
        let _ = d.readString()  // type
        let _ = d.readInt32()  // w
        let _ = d.readInt32()  // h
        let _ = d.readBytes()  // bytes
        return
    }
    if (constructor == 0xe0b0bc2e) {
        // photoStrippedSize#e0b0bc2e type:string bytes:bytes
        let _ = d.readString()  // type
        let _ = d.readBytes()  // bytes
        return
    }
    if (constructor == 0xfa3efb95) {
        // photoSizeProgressive#fa3efb95 type:string w:int h:int sizes:Vector<int>
        let _ = d.readString()  // type
        let _ = d.readInt32()  // w
        let _ = d.readInt32()  // h
        // sizes: Vector<int>
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let _ = d.readInt32()
            }
        }
        return
    }
    if (constructor == 0xd8214d41 || constructor == 0x6f8bf5a0) {
        // photoPathSize#d8214d41 type:string bytes:bytes (Layer 214)
        // photoPathSize#6f8bf5a0 type:string bytes:bytes (旧版)
        let _ = d.readString()  // type
        let _ = d.readBytes()  // bytes
        return
    }
    Hilog.info(0, "CjTelegram", "[skipPhotoSize] Unknown constructor: ${constructor}")
}

/**
 * Phase Q7: 解析 PhotoSize 并捕获尺寸/大小信息
 * 
 * 返回 (width, height, fileSize, isStripped, strippedBytes)
 * 用于选择最大分辨率的 PhotoSize 以及提取 stripped thumb 数据
 * 
 * 与 skipPhotoSize 结构相同，但不丢弃数据。
 */
func parsePhotoSizeCapture(d: TLDeserializer): (Int32, Int32, Int32, Bool, Array<Byte>, String) {
    let constructor = d.readUInt32()
    if (constructor == 0x0e17e23c) {
        // photoSizeEmpty#0e17e23c type:string
        let t = d.readString()
        return (0, 0, 0, false, Array<Byte>(0, repeat: 0), t)
    }
    if (constructor == 0x75c78e60) {
        // photoSize#75c78e60 type:string w:int h:int size:int
        let t = d.readString()
        let w = d.readInt32()
        let h = d.readInt32()
        let sz = d.readInt32()
        return (w, h, sz, false, Array<Byte>(0, repeat: 0), t)
    }
    if (constructor == 0x021e1ad6) {
        // photoCachedSize#021e1ad6 type:string w:int h:int bytes:bytes
        let t = d.readString()
        let w = d.readInt32()
        let h = d.readInt32()
        let _ = d.readBytes()
        return (w, h, 0, false, Array<Byte>(0, repeat: 0), t)
    }
    if (constructor == 0xe0b0bc2e) {
        // photoStrippedSize#e0b0bc2e type:string bytes:bytes
        // 这是即时模糊预览数据（JPEG 头 + 极低分辨率像素）
        let t = d.readString()
        let thumbBytes = d.readBytes()
        return (0, 0, 0, true, thumbBytes, t)
    }
    if (constructor == 0xfa3efb95) {
        // photoSizeProgressive#fa3efb95 type:string w:int h:int sizes:Vector<int>
        let t = d.readString()
        let w = d.readInt32()
        let h = d.readInt32()
        let vecConst = d.readUInt32()
        var maxSize: Int32 = 0
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let s = d.readInt32()
                if (s > maxSize) { maxSize = s }
            }
        }
        return (w, h, maxSize, false, Array<Byte>(0, repeat: 0), t)
    }
    if (constructor == 0xd8214d41 || constructor == 0x6f8bf5a0) {
        // photoPathSize type:string bytes:bytes
        let _ = d.readString()
        let _ = d.readBytes()
        return (0, 0, 0, false, Array<Byte>(0, repeat: 0), "")
    }
    Hilog.info(0, "CjTelegram", "[parsePhotoSizeCapture] Unknown constructor: ${constructor}")
    return (0, 0, 0, false, Array<Byte>(0, repeat: 0), "")
}

/**
 * 跳过 VideoSize — 严格匹配 TelegramHarmony TLDialogs.ets skipVideoSize
 * 
 * 支持的构造器（Layer 214）：
 *   videoSize#de33b094 flags:# type:string w:int h:int size:int video_start_ts:flags.0?double
 *   videoSize#7be31cfd (旧版) 同上
 *   videoSizeStickerMarkup#0da082fe stickerset:InputStickerSet sticker_id:long background_colors:Vector<int>
 *   videoSizeEmojiMarkup#f85c413c emoji_id:long background_colors:Vector<int>
 */
func skipVideoSize(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0xde33b094 || constructor == 0x7be31cfd) {
        // videoSize#de33b094 (Layer 214) / videoSize#7be31cfd (旧版)
        // flags:# type:string w:int h:int size:int video_start_ts:flags.0?double
        let flags = d.readInt32()
        let _ = d.readString()  // type
        let _ = d.readInt32()  // w
        let _ = d.readInt32()  // h
        let _ = d.readInt32()  // size
        if ((flags & 1) != 0) { let _ = d.readDouble() }  // video_start_ts
        return
    }
    if (constructor == 0xf85c413c) {
        // videoSizeEmojiMarkup#f85c413c emoji_id:long background_colors:Vector<int>
        let _ = d.readInt64()  // emoji_id
        // background_colors: Vector<int>
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let _ = d.readInt32()
            }
        }
        return
    }
    if (constructor == 0x0da082fe) {
        // videoSizeStickerMarkup#0da082fe stickerset:InputStickerSet sticker_id:long background_colors:Vector<int>
        skipInputStickerSet(d)  // stickerset (boxed InputStickerSet)
        let _ = d.readInt64()  // sticker_id
        // background_colors: Vector<int>
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let _ = d.readInt32()
            }
        }
        return
    }
    // 未知构造器 — 按旧格式 videoSize 尝试解析（匹配 TelegramHarmony 的 default 分支）
    Hilog.info(0, "CjTelegram", "[skipVideoSize] Unknown constructor: ${constructor}, attempting fallback parse")
    let flags = d.readInt32()
    let _ = d.readString()  // type
    let _ = d.readInt32()  // w
    let _ = d.readInt32()  // h
    let _ = d.readInt32()  // size
    if ((flags & 1) != 0) { let _ = d.readDouble() }  // video_start_ts
}

func skipInputStickerSet(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0xffb62b95) { return }  // inputStickerSetEmpty
    if (constructor == 0x9de7a269) {
        let _ = d.readInt64()  // id
        let _ = d.readInt64()  // access_hash
        return
    }
    if (constructor == 0x861cc8a0) {
        let _ = d.readString()  // short_name
        return
    }
}

/**
 * 跳过 GeoPoint
 */
public func skipGeoPoint(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x1117dd5f) { return }  // geoPointEmpty
    // geoPoint - 严格匹配 TelegramHarmony
    let flags = d.readInt32()
    let _ = d.readDouble()  // long
    let _ = d.readDouble()  // lat
    let _ = d.readInt64()   // accessHash (CRITICAL - 之前缺失!)
    if ((flags & 1) != 0) { let _ = d.readInt32() }  // accuracy_radius
}

/**
 * 跳过 Document
 */
func skipDocument(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x36f8c871) {
        // documentEmpty
        let _ = d.readInt64()  // id
        return
    }
    // document#8fd4c4d8
    let flags = d.readInt32()
    let _ = d.readInt64()  // id
    let _ = d.readInt64()  // access_hash
    let _ = d.readBytes()  // file_reference
    let _ = d.readInt32()  // date
    let _ = d.readString()  // mime_type
    let _ = d.readInt64()  // size (Layer 214: long)
    // thumbs: flags.0?Vector<PhotoSize>
    if ((flags & 1) != 0) {
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                skipPhotoSize(d)
            }
        }
    }
    // video_thumbs: flags.1?Vector<VideoSize>
    if ((flags & 2) != 0) {
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                skipVideoSize(d)
            }
        }
    }
    let _ = d.readInt32()  // dc_id
    // attributes: Vector<DocumentAttribute>
    let vecConst2 = d.readUInt32()
    if (vecConst2 == TLConstructors.VECTOR) {
        let count2 = d.readInt32()
        for (_i in 0..Int64(count2)) {
            skipDocumentAttribute(d)
        }
    }
}

public func skipDocumentAttribute(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    
    if (constructor == 0x6c37c15c) {
        // documentAttributeImageSize w:int h:int
        let _ = d.readInt32()
        let _ = d.readInt32()
        return
    }
    if (constructor == 0x11b58939) {
        // documentAttributeAnimated
        return
    }
    if (constructor == 0x6319d612) {
        // documentAttributeSticker flags:# mask:flags.1?true alt:string stickerset:InputStickerSet mask_coords:flags.0?MaskCoords
        let flags = d.readInt32()
        let _ = d.readString()  // alt
        skipInputStickerSet(d)  // stickerset
        if ((flags & 1) != 0) {
            // MaskCoords: n:int x:double y:double zoom:double
            let _ = d.readInt32()
            let _ = d.readDouble()
            let _ = d.readDouble()
            let _ = d.readDouble()
        }
        return
    }
    if (constructor == 0x43C57C48 || constructor == 0xd38ff1c2) {
        // documentAttributeVideo (0x43C57C48 = Layer 190+, 0xd38ff1c2 = 中间版本)
        // 严格匹配 TelegramHarmony: flags:# duration:double w:int h:int 
        // preload_prefix_size:flags.2?int video_start_ts:flags.4?double video_codec:flags.5?string
        let flags = d.readInt32()
        let _ = d.readDouble()  // duration
        let _ = d.readInt32()   // w
        let _ = d.readInt32()   // h
        if ((flags & 4) != 0) { let _ = d.readInt32() }    // preload_prefix_size - bit 2
        if ((flags & 16) != 0) { let _ = d.readDouble() }  // video_start_ts - bit 4
        if ((flags & 32) != 0) { let _ = d.readString() }  // video_codec - bit 5 (仅 0x43C57C48)
        return
    }
    if (constructor == 0xef02ce6) {
        // documentAttributeVideo (旧版) — duration 是 int 而不是 double
        let flags = d.readInt32()
        let _ = d.readInt32()   // duration (int)
        let _ = d.readInt32()   // w
        let _ = d.readInt32()   // h
        return
    }
    if (constructor == 0x9852f9c6) {
        // documentAttributeAudio flags:# voice:flags.10?true duration:int title:flags.0?string performer:flags.1?string waveform:flags.2?bytes
        let flags = d.readInt32()
        let _ = d.readInt32()  // duration
        if ((flags & 1) != 0) { let _ = d.readString() }  // title
        if ((flags & 2) != 0) { let _ = d.readString() }  // performer
        if ((flags & 4) != 0) { let _ = d.readBytes() }   // waveform
        return
    }
    if (constructor == 0x15590068) {
        // documentAttributeFilename file_name:string
        let _ = d.readString()
        return
    }
    if (constructor == 0x9801d2f7) {
        // documentAttributeHasStickers
        return
    }
    if (constructor == 0xfd149899) {
        // documentAttributeCustomEmoji flags:# free:flags.0?true text_color:flags.1?true alt:string stickerset:InputStickerSet
        let _ = d.readInt32()  // flags
        let _ = d.readString()  // alt
        skipInputStickerSet(d)
        return
    }
    // 未知的 DocumentAttribute 类型 — 无法安全跳过，抛出异常触发恢复
    Hilog.info(0, "CjTelegram", "[skipDocumentAttribute] Unknown constructor: ${constructor}")
    throw IllegalArgumentException("[skipDocumentAttribute] Unknown constructor: ${constructor}")
}

/**
 * Phase Q5: 解析 WebPage 并捕获预览数据到 TLMessage
 * 
 * webPage#e89c45b2 flags:# id:long url:string display_url:string hash:int
 *   type:flags.0?string site_name:flags.1?string title:flags.2?string
 *   description:flags.3?string photo:flags.4?Photo ...
 */
func parseWebPageCapture(d: TLDeserializer, m: TLMessage): Unit {
    let constructor = d.readUInt32()

    // webPageEmpty: current 0x211a1788 (iOS dict[555358088]); old 0xeb1477e8 compat
    if (constructor == 0x211a1788 || constructor == 0xeb1477e8) {
        let flags = d.readInt32()
        let _ = d.readInt64()  // id
        if ((flags & 1) != 0) { m.webPageUrl = d.readString() }
        return
    }
    // webPagePending: current 0xb0d13e47 (iOS dict[-1328464313]); old 0xc586da1c compat
    if (constructor == 0xb0d13e47 || constructor == 0xc586da1c) {
        let flags = d.readInt32()
        let _ = d.readInt64()  // id
        if ((flags & 1) != 0) { m.webPageUrl = d.readString() }
        let _ = d.readInt32()  // date
        return
    }
    if (constructor == 0xe89c45b2) {
        // webPage — 捕获 url, site_name, title, description
        let flags = d.readInt32()
        let _ = d.readInt64()  // id
        m.webPageUrl = d.readString()  // url
        let _ = d.readString()  // display_url
        let _ = d.readInt32()  // hash
        if ((flags & 1) != 0) { let _ = d.readString() }  // type
        if ((flags & 2) != 0) { m.webPageSiteName = d.readString() }  // site_name
        if ((flags & 4) != 0) { m.webPageTitle = d.readString() }  // title
        if ((flags & 8) != 0) { m.webPageDescription = d.readString() }  // description
        if ((flags & 16) != 0) {
            // P7B-1: 解析 webPage.photo 并捕获缩略图元数据
            let photoConstructor = d.readUInt32()
            if (photoConstructor == 0x2331b22d) {
                // photoEmpty
                let _ = d.readInt64()
            } else {
                // photo#fb197a65
                let photoFlags = d.readInt32()
                let photoId = d.readInt64()
                let accessHash = d.readInt64()
                let fileRef = d.readBytes()
                let _ = d.readInt32() // date
                // Preserve the largest representation dimensions, matching iOS
                // TelegramMediaImage representation-based media layout.
                let vecConstP = d.readUInt32()
                if (vecConstP == TLConstructors.VECTOR) {
                    let countP = d.readInt32()
                    var maxArea: Int64 = 0
                    for (_i in 0..Int64(countP)) {
                        let (w, h, _size, _stripped, _bytes, _t) = parsePhotoSizeCapture(d)
                        let area = Int64(w) * Int64(h)
                        if (area > maxArea) {
                            maxArea = area
                            m.webPagePhotoWidth = w
                            m.webPagePhotoHeight = h
                        }
                    }
                }
                // video_sizes: flags.1?Vector<VideoSize>
                if ((photoFlags & 2) != 0) {
                    let vecConstV = d.readUInt32()
                    if (vecConstV == TLConstructors.VECTOR) {
                        let countV = d.readInt32()
                        for (_i in 0..Int64(countV)) { skipVideoSize(d) }
                    }
                }
                let dcId = d.readInt32()
                m.webPagePhotoId = photoId
                m.webPagePhotoAccessHash = accessHash
                m.webPagePhotoFileReference = fileRef
                m.webPagePhotoDcId = dcId
                Hilog.info(0, "CjTelegram", "[parseWebPage] Photo captured: id=${photoId}, dc=${dcId}")
            }
        }
        if ((flags & 32) != 0) { let _ = d.readString() }  // embed_url
        if ((flags & 32) != 0) { let _ = d.readString() }  // embed_type
        if ((flags & 64) != 0) { let _ = d.readInt32() }  // embed_width
        if ((flags & 64) != 0) { let _ = d.readInt32() }  // embed_height
        if ((flags & 128) != 0) { let _ = d.readInt32() }  // duration
        if ((flags & 256) != 0) { let _ = d.readString() }  // author
        if ((flags & 512) != 0) { skipDocument(d) }  // document
        if ((flags & 1024) != 0) { skipPage(d) }  // cached_page
        if ((flags & 4096) != 0) {
            let vecConst = d.readUInt32()
            if (vecConst == TLConstructors.VECTOR) {
                let count = d.readInt32()
                for (_i in 0..Int64(count)) { skipWebPageAttribute(d) }
            }
        }
        Hilog.info(0, "CjTelegram", "[parseWebPage] Captured: site=${m.webPageSiteName}, title=${m.webPageTitle}")
        return
    }
    if (constructor == 0x7311ca11) {
        // webPageNotModified
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt32() }
        return
    }
}

/**
 * 跳过 WebPage - 简化版
 */
func skipWebPage(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    // webPageEmpty: current layer 0x211a1788 (iOS dict[555358088])
    // old layer 0xeb1477e8 kept for compat
    // iOS parse_webPageEmpty: flags:int id:long url:flags.0?string
    if (constructor == 0x211a1788 || constructor == 0xeb1477e8) {
        let flags = d.readInt32()
        let _ = d.readInt64()  // id
        if ((flags & 1) != 0) { let _ = d.readString() }  // url
        return
    }
    // webPagePending: current layer 0xb0d13e47 (iOS dict[-1328464313])
    // old layer 0xc586da1c kept for compat
    // iOS parse_webPagePending: flags:int id:long url:flags.0?string date:int
    if (constructor == 0xb0d13e47 || constructor == 0xc586da1c) {
        let flags = d.readInt32()
        let _ = d.readInt64()  // id
        if ((flags & 1) != 0) { let _ = d.readString() }  // url
        let _ = d.readInt32()  // date
        return
    }
    if (constructor == 0xe89c45b2) {
        // webPage - very complex, try to skip essential fields
        let flags = d.readInt32()
        let _ = d.readInt64()  // id
        let _ = d.readString()  // url
        let _ = d.readString()  // display_url
        let _ = d.readInt32()  // hash
        if ((flags & 1) != 0) { let _ = d.readString() }  // type
        if ((flags & 2) != 0) { let _ = d.readString() }  // site_name
        if ((flags & 4) != 0) { let _ = d.readString() }  // title
        if ((flags & 8) != 0) { let _ = d.readString() }  // description
        if ((flags & 16) != 0) { skipPhoto(d) }  // photo
        if ((flags & 32) != 0) { let _ = d.readString() }  // embed_url
        if ((flags & 32) != 0) { let _ = d.readString() }  // embed_type
        if ((flags & 64) != 0) { let _ = d.readInt32() }  // embed_width
        if ((flags & 64) != 0) { let _ = d.readInt32() }  // embed_height
        if ((flags & 128) != 0) { let _ = d.readInt32() }  // duration
        if ((flags & 256) != 0) { let _ = d.readString() }  // author
        if ((flags & 512) != 0) { skipDocument(d) }  // document
        if ((flags & 1024) != 0) {
            // cached_page: Page
            skipPage(d)
        }
        if ((flags & 4096) != 0) {
            // attributes: Vector<WebPageAttribute>
            let vecConst = d.readUInt32()
            if (vecConst == TLConstructors.VECTOR) {
                let count = d.readInt32()
                for (_i in 0..Int64(count)) {
                    skipWebPageAttribute(d)
                }
            }
        }
        return
    }
    if (constructor == 0x7311ca11) {
        // webPageNotModified flags:# cached_page_views:flags.0?int
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt32() }
        return
    }
}

/**
 * 跳过 Page — page#98657f0d / pageNotModified#b7de36f2
 *
 * page#98657f0d (iOS Api0.swift:837 parse_page, Api20.swift):
 *   flags:Int32  url:string
 *   blocks:Vector<PageBlock>   — each element BOXED, skip via skipPageBlock per element
 *   photos:Vector<Photo>       — skip via skipPhoto
 *   documents:Vector<Document> — skip via skipDocument
 *   views?[flags.3]:Int32
 *
 * pageNotModified#b7de36f2 — no fields (just the ctor)
 *
 * P2-AUDIT-read3: fixed blocks vector to use skipPageBlock instead of skipGenericVector
 * to avoid stream desync from incorrect per-element skip.
 */
func skipPage(d: TLDeserializer): Unit {
    let pageCtor = d.readUInt32()  // constructor
    if (pageCtor == 0xb7de36f2) { return }  // pageNotModified — no fields
    // page#98657f0d
    let flags = d.readInt32()
    let _ = d.readString()  // url
    // blocks: Vector<PageBlock> — each element is BOXED; must use skipPageBlock per element
    let blocksCtor = d.readUInt32()
    if (blocksCtor == TLConstructors.VECTOR) {
        let blockCount = d.readInt32()
        for (_i in 0..Int64(blockCount)) {
            skipPageBlock(d)
        }
    }
    // photos: Vector<Photo>
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            skipPhoto(d)
        }
    }
    // documents: Vector<Document>
    let vecConst2 = d.readUInt32()
    if (vecConst2 == TLConstructors.VECTOR) {
        let count2 = d.readInt32()
        for (_i in 0..Int64(count2)) {
            skipDocument(d)
        }
    }
    if ((flags & 8) != 0) { let _ = d.readInt32() }  // views
}

/**
 * 跳过一个泛型 Vector，每个元素当作 boxed object 尝试跳过
 */
func skipGenericVector(d: TLDeserializer): Unit {
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            skipBoxedObject(d)
        }
    }
}

func skipWebPageAttribute(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x54b56617) {
        // webPageAttributeTheme#54b56617 (iOS dict[1421174295])
        // iOS Api31.swift:616 parse_webPageAttributeTheme
        // flags:# documents:flags.0?Vector<Document> settings:flags.1?ThemeSettings
        let flags = d.readInt32()
        if ((flags & 1) != 0) {
            let vecConst = d.readUInt32()
            if (vecConst == TLConstructors.VECTOR) {
                let count = d.readInt32()
                for (_i in 0..Int64(count)) { skipDocument(d) }
            }
        }
        if ((flags & 2) != 0) { skipThemeSettings(d) }
        return
    }
    if (constructor == 0x2e94c3e7) {
        // webPageAttributeStory#2e94c3e7 (iOS dict[781501415])
        // iOS Api31.swift:590 parse_webPageAttributeStory
        // flags:# peer:Peer(boxed) id:int story:flags.0?StoryItem
        let flags = d.readInt32()
        let _ = PeerResponse.deserializeBoxed(d)  // peer
        let _ = d.readInt32()                     // id
        if ((flags & 1) != 0) { skipStoryItem(d) }
        return
    }
    if (constructor == 0x50cc03d3) {
        // webPageAttributeStickerSet#50cc03d3 (iOS dict[1355547603])
        // iOS Api31.swift:574 parse_webPageAttributeStickerSet
        // flags:# stickers:Vector<Document>
        let _ = d.readInt32()  // flags
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { skipDocument(d) }
        }
        return
    }
    if (constructor == 0xcf6f6db8) {
        // webPageAttributeUniqueStarGift#cf6f6db8 (iOS dict[-814781000])
        // iOS Api31.swift:641 parse_webPageAttributeUniqueStarGift
        // gift:StarGift(boxed) — delegate to skipStarGiftBoxed (TLResponses.cj, same package)
        skipStarGiftBoxed(d)
        return
    }
    // Other known ctors with no required deep parse — log and skip (cannot safely skip unknown fields)
    Hilog.info(0, "CjTelegram", "[skipWebPageAttribute] Unknown ctor: 0x${toHex32(constructor)}, skipping safely")
}

func skipThemeSettings(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    let _ = d.readString()  // base_theme constructor
    let _ = d.readInt32()  // accent_color
    if ((flags & 8) != 0) { let _ = d.readInt32() }  // outbox_accent_color
    if ((flags & 1) != 0) {
        // message_colors: Vector<int>
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let _ = d.readInt32()
            }
        }
    }
    if ((flags & 2) != 0) { skipWallPaper(d) }
}

func skipWallPaper(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0xe0804116) {
        // wallPaperNoFile
        let flags = d.readInt32()
        let _ = d.readInt64()  // id
        if ((flags & 4) != 0) { skipWallPaperSettings(d) }
        return
    }
    // wallPaper
    let _ = d.readInt64()  // id
    let flags = d.readInt32()
    let _ = d.readInt64()  // access_hash
    let _ = d.readString()  // slug
    skipDocument(d)  // document
    if ((flags & 4) != 0) { skipWallPaperSettings(d) }
}

/**
 * S6-05：读出 WallPaper 的身份字段 (id, access_hash, slug)，其余字节按 skipWallPaper 同样消耗。
 * wallPaper#a437c3ed id:long flags:# access_hash:long slug:string document:Document settings:flags.2?WallPaperSettings
 * wallPaperNoFile#e0804116 id:long flags:# settings:flags.2?WallPaperSettings → (id, 0, "")
 */
func parseWallPaperRef(d: TLDeserializer): (Int64, Int64, String) {
    let constructor = d.readUInt32()
    if (constructor == 0xe0804116) {
        let id = d.readInt64()
        let flags = d.readInt32()
        if ((flags & 4) != 0) { skipWallPaperSettings(d) }
        return (id, 0, "")
    }
    let id = d.readInt64()
    let flags = d.readInt32()
    let accessHash = d.readInt64()
    let slug = d.readString()
    skipDocument(d)
    if ((flags & 4) != 0) { skipWallPaperSettings(d) }
    return (id, accessHash, slug)
}

func skipWallPaperSettings(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    if ((flags & 1) != 0) { let _ = d.readInt32() }  // background_color
    if ((flags & 16) != 0) { let _ = d.readInt32() }  // second_background_color
    if ((flags & 32) != 0) { let _ = d.readInt32() }  // third_background_color
    if ((flags & 64) != 0) { let _ = d.readInt32() }  // fourth_background_color
    if ((flags & 8) != 0) { let _ = d.readInt32() }  // intensity
    if ((flags & 16) != 0) { let _ = d.readInt32() }  // rotation
    if ((flags & 128) != 0) { let _ = d.readString() }  // emoticon
}

func skipGame(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    let _ = d.readInt64()  // id
    let _ = d.readInt64()  // access_hash
    let _ = d.readString()  // short_name
    let _ = d.readString()  // title
    let _ = d.readString()  // description
    skipPhoto(d)  // photo
    if ((flags & 1) != 0) { skipDocument(d) }  // document
}

func skipWebDocument(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x1c570ed1) {
        // webDocument
        let _ = d.readString()  // url
        let _ = d.readInt64()   // access_hash
        let _ = d.readInt32()   // size
        let _ = d.readString()  // mime_type
        // attributes: Vector<DocumentAttribute>
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                skipDocumentAttribute(d)
            }
        }
        return
    }
    if (constructor == 0xf9c8bcc6) {
        // webDocumentNoProxy
        let _ = d.readString()  // url
        let _ = d.readInt32()   // size
        let _ = d.readString()  // mime_type
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                skipDocumentAttribute(d)
            }
        }
        return
    }
}

func skipExtendedMedia(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0xad628cc8) {
        // messageExtendedMediaPreview
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // w
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // h
        if ((flags & 2) != 0) { skipPhotoSize(d) }  // thumb
        if ((flags & 4) != 0) { let _ = d.readInt32() }  // video_duration
        return
    }
    if (constructor == 0xee479c64) {
        // messageExtendedMedia (contains a MessageMedia)
        skipMessageMedia(d)
        return
    }
}

/**
 * Phase Q8: 解析 Poll 对象并捕获数据到 TLMessage
 * 
 * poll#58747571 flags:# id:long closed:flags.0?true public_voters:flags.1?true 
 * multiple_choice:flags.2?true quiz:flags.3?true 
 * question:TextWithEntities answers:Vector<PollAnswer> 
 * close_period:flags.4?int close_date:flags.5?int = Poll;
 */
func parsePollCapture(d: TLDeserializer, msg: TLMessage): Unit {
    let _ = d.readUInt32()  // constructor (poll#58747571)
    msg.pollId = d.readInt64()
    let flags = d.readInt32()
    
    msg.pollClosed = (flags & 1) != 0
    msg.pollMultipleChoice = (flags & 4) != 0
    msg.pollQuiz = (flags & 8) != 0
    
    // question: TextWithEntities (Layer 214)
    let _ = d.readUInt32()  // TextWithEntities constructor
    msg.pollQuestion = d.readString()
    skipMessageEntitiesVector(d)  // entities
    
    // answers: Vector<PollAnswer>
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            let opt = TLPollOption()
            let _ = d.readUInt32()  // PollAnswer constructor
            // text: TextWithEntities
            let _ = d.readUInt32()  // TextWithEntities constructor
            opt.text = d.readString()
            skipMessageEntitiesVector(d)  // entities
            opt.optionBytes = d.readBytes()
            msg.pollOptions.add(opt)
        }
    }
    
    if ((flags & 16) != 0) { let _ = d.readInt32() }  // close_period
    if ((flags & 32) != 0) { let _ = d.readInt32() }  // close_date
}

/**
 * Phase Q8: 解析 PollResults 对象并捕获数据到 TLMessage
 *
 * pollResults#7adf2420 flags:# min:flags.0?true results:flags.1?Vector<PollAnswerVoters>
 * total_voters:flags.2?int recent_voters:flags.3?Vector<Peer>
 * solution:flags.4?string solution_entities:flags.4?Vector<MessageEntity>
 * solution_media:flags.5?MessageMedia = PollResults;
 * iOS Api21.swift:1090 parse_pollResults
 *
 * pollAnswerVoters#3b6ddad2 flags:# option:bytes voters:flags.2?int recent_voters:flags.2?Vector<Peer>
 * iOS Api21.swift:989 parse_pollAnswerVoters
 */
func parsePollResultsCapture(d: TLDeserializer, msg: TLMessage): Unit {
    let _ = d.readUInt32()  // constructor (pollResults#7adf2420)
    let flags = d.readInt32()

    // results: Vector<PollAnswerVoters> (flags.1)
    if ((flags & 2) != 0) {
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                // pollAnswerVoters#3b6ddad2 flags:# chosen:flags.0 correct:flags.1 option:bytes voters:int
                // ⚠️ voters 是必填 int（telegram_api.tl + 真机 1520B dump 逐字节复盘实锤）。
                // 此前照抄 iOS Api21（更高 layer, voters:flags.2?int + recent_voters）导致
                // 每个元素少读 4B → chats/users 向量整体错位 → 新登录后名字/头像大面积缺失。
                let _ = d.readUInt32()   // constructor
                let avf = d.readInt32()  // flags
                let chosen = (avf & 1) != 0
                let correct = (avf & 2) != 0
                let optBytes = d.readBytes()  // option:bytes (iOS parseBytes, NOT string)
                let voters: Int32 = d.readInt32()

                // 将结果直接匹配到对应的 pollOption
                for (opt in msg.pollOptions) {
                    if (optionBytesMatch(opt.optionBytes, optBytes)) {
                        opt.voters = voters
                        opt.chosen = chosen
                        opt.correct = correct
                        break
                    }
                }
            }
        }
    }

    // total_voters:flags.2?int
    if ((flags & 4) != 0) { msg.pollTotalVoters = d.readInt32() }

    // recent_voters:flags.3?Vector<Peer>
    if ((flags & 8) != 0) {
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { let _ = PeerResponse.deserializeBoxed(d) }
        }
    }

    // solution:flags.4?string
    if ((flags & 16) != 0) { msg.pollSolution = d.readString() }
    // solution_entities:flags.4?Vector<MessageEntity>
    if ((flags & 16) != 0) { skipMessageEntitiesVector(d) }
    // solution_media:flags.5?MessageMedia(boxed) — iOS Api21.swift:1120
    if ((flags & 32) != 0) { skipMessageMedia(d) }
}

/**
 * Phase Q8: 比较 option bytes 是否相同
 */
func optionBytesMatch(a: Array<Byte>, b: Array<Byte>): Bool {
    if (a.size != b.size) { return false }
    for (i in 0..Int64(a.size)) {
        if (a[i] != b[i]) { return false }
    }
    return true
}

/**
 * Phase Q8: 合并投票结果（占位函数 — 实际合并已在 parsePollResultsCapture 内完成）
 */
func mergePollResults(msg: TLMessage): Unit {
    // 结果已在 parsePollResultsCapture 中直接写入 pollOptions
    // 此函数保留供未来扩展（如计算百分比等）
    Hilog.info(0, "CjTelegram", "[parsePoll] Question: ${msg.pollQuestion}, options: ${msg.pollOptions.size}, totalVoters: ${msg.pollTotalVoters}")
}

func skipPoll(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor
    let _ = d.readInt64()   // id
    let flags = d.readInt32()
    // question: TextWithEntities (Layer 214)
    let _ = d.readUInt32()  // TextWithEntities constructor
    let _ = d.readString()  // text
    skipMessageEntitiesVector(d)  // entities
    // answers: Vector<PollAnswer>
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            skipPollAnswer(d)
        }
    }
    if ((flags & 16) != 0) { let _ = d.readInt32() }  // close_period (flags.4)
    if ((flags & 32) != 0) { let _ = d.readInt32() }  // close_date (flags.5)
}

func skipPollAnswer(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor
    // text: TextWithEntities  
    let _ = d.readUInt32()  // TextWithEntities constructor
    let _ = d.readString()  // text
    skipMessageEntitiesVector(d)  // entities
    let _ = d.readBytes()  // option (bytes)
}

func skipPollResults(d: TLDeserializer): Unit {
    // pollResults#7adf2420 flags:# min:flags.0 results:flags.1?Vector<PollAnswerVoters>
    //   total_voters:flags.2?int recent_voters:flags.3?Vector<Peer>
    //   solution:flags.4?string solution_entities:flags.4?Vector<MessageEntity>
    //   solution_media:flags.5?MessageMedia
    // iOS Api21.swift:1090 parse_pollResults
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    if ((flags & 2) != 0) {
        // results: Vector<PollAnswerVoters> (flags.1)
        // pollAnswerVoters#3b6ddad2 flags:# option:bytes voters:flags.2?int recent_voters:flags.2?Vector<Peer>
        // iOS Api21.swift:989 parse_pollAnswerVoters
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                // pollAnswerVoters#3b6ddad2 flags:# chosen:flags.0 correct:flags.1 option:bytes voters:int
                // ⚠️ voters 必填 int（telegram_api.tl 为准，勿抄 iOS 更高 layer 的条件字段）
                let _ = d.readUInt32()    // constructor (pollAnswerVoters#3b6ddad2)
                let _ = d.readInt32()     // flags (chosen/correct 布尔位)
                let _ = d.readBytes()     // option:bytes (NOT string — iOS parseBytes)
                let _ = d.readInt32()     // voters:int (mandatory)
            }
        }
    }
    if ((flags & 4) != 0) { let _ = d.readInt32() }   // total_voters:flags.2?int
    if ((flags & 8) != 0) {
        // recent_voters:flags.3?Vector<Peer>
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { let _ = PeerResponse.deserializeBoxed(d) }
        }
    }
    if ((flags & 16) != 0) { let _ = d.readString() }  // solution:flags.4?string
    if ((flags & 16) != 0) { skipMessageEntitiesVector(d) }  // solution_entities:flags.4?Vector<MessageEntity>
    if ((flags & 32) != 0) { skipMessageMedia(d) }  // solution_media:flags.5?MessageMedia(boxed)
}

func skipStoryItem(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x51e6ee4f) {
        // storyItemDeleted (iOS dict[1374088783])
        let _ = d.readInt32()  // id
        return
    }
    // storyItemSkipped: current layer 0xffadc913 (iOS dict[-5388013])
    // old layer 0xb0edac3e kept for compat
    // iOS parse_storyItemSkipped: flags:int id:int date:int expire_date:int (4 ints, no optionals)
    if (constructor == 0xffadc913 || constructor == 0xb0edac3e) {
        let _ = d.readInt32()  // flags
        let _ = d.readInt32()  // id
        let _ = d.readInt32()  // date
        let _ = d.readInt32()  // expire_date
        return
    }
    // storyItem - very complex, simplified skip
    let _ = d.readInt32()  // flags
    let _ = d.readInt32()  // id
    let _ = d.readInt32()  // date
    // ... too complex, bail out
}

/**
 * 跳过 ReplyMarkup
 */
public func skipReplyMarkup(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0xa03e5b85) {
        // replyKeyboardHide
        let _ = d.readInt32()  // flags
        return
    }
    if (constructor == 0x86b40b08) {
        // replyKeyboardForceReply flags:# ... placeholder:flags.3?string
        let flags = d.readInt32()
        if ((flags & 8) != 0) { let _ = d.readString() }  // placeholder (flags.3)
        return
    }
    if (constructor == 0x85dd99d1) {
        // replyKeyboardMarkup flags:# ... rows:Vector<KeyboardButtonRow> placeholder:flags.3?string
        let flags = d.readInt32()
        skipKeyboardButtonRows(d)
        if ((flags & 8) != 0) { let _ = d.readString() }  // placeholder
        return
    }
    if (constructor == 0x48a30254) {
        // replyInlineMarkup rows:Vector<KeyboardButtonRow>
        skipKeyboardButtonRows(d)
        return
    }
}

/** Capture the source keyboardButtonBuy title while preserving all other rows. */
func captureInvoiceReplyMarkup(d: TLDeserializer, msg: TLMessage): Unit {
    let constructor = d.readUInt32()
    if (constructor != 0x48a30254) {
        d.setOffset(d.getOffset() - 4)
        skipReplyMarkup(d)
        return
    }
    let vecConst = d.readUInt32()
    if (vecConst != TLConstructors.VECTOR) { return }
    let rowCount = d.readInt32()
    for (_row in 0..Int64(rowCount)) {
        let _ = d.readUInt32()
        let buttonVec = d.readUInt32()
        if (buttonVec != TLConstructors.VECTOR) { continue }
        let buttonCount = d.readInt32()
        for (_button in 0..Int64(buttonCount)) {
            let saved = d.getOffset()
            let buttonConstructor = d.readUInt32()
            if (buttonConstructor == 0xafd93fbb) {
                // Layer 214: keyboardButtonBuy#afd93fbb text:string
                let title = d.readString()
                if (msg.invoicePaymentButtonTitle.size == 0) {
                    msg.invoicePaymentButtonTitle = title
                }
            } else if (buttonConstructor == 0x3fa53905) {
                let flags = d.readInt32()
                if ((flags & (1 << 10)) != 0) {
                    let _ = d.readUInt32()
                    skipKeyboardButtonStyle(d)
                }
                let title = d.readString()
                if (msg.invoicePaymentButtonTitle.size == 0) {
                    msg.invoicePaymentButtonTitle = title
                }
            } else {
                d.setOffset(saved)
                skipKeyboardButton(d)
            }
        }
    }
}

/**
 * 回复键盘（iOS ReplyMarkupMessageAttribute）：replyKeyboardMarkup 记下每行按钮文字，
 * hide / forceReply / inline 只记类型。其余字段按原 skipReplyMarkup 的字段顺序消费。
 */
func captureReplyKeyboardMarkup(d: TLDeserializer, msg: TLMessage): Unit {
    let constructor = d.peekUInt32()
    if (constructor != 0x85dd99d1) {
        if (constructor == 0xa03e5b85) {
            msg.replyMarkupKind = 2
        } else if (constructor == 0x86b40b08) {
            msg.replyMarkupKind = 3
        } else if (constructor == 0x48a30254) {
            msg.replyMarkupKind = 4
        }
        skipReplyMarkup(d)
        return
    }
    let _ = d.readUInt32()
    // replyKeyboardMarkup#85dd99d1 flags:# resize:flags.0 single_use:flags.1 selective:flags.2
    //   persistent:flags.4 rows:Vector<KeyboardButtonRow> placeholder:flags.3?string
    let flags = d.readInt32()
    msg.replyMarkupKind = 1
    msg.replyKeyboardResize = (flags & 1) != 0
    msg.replyKeyboardSingleUse = (flags & 2) != 0
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let rowCount = d.readInt32()
        for (_row in 0..Int64(rowCount)) {
            let _ = d.readUInt32()  // keyboardButtonRow
            let buttonVec = d.readUInt32()
            if (buttonVec != TLConstructors.VECTOR) { continue }
            let buttonCount = d.readInt32()
            let row = ArrayList<String>()
            for (_button in 0..Int64(buttonCount)) {
                row.add(readKeyboardButtonText(d))
            }
            msg.replyKeyboardRows.add(row)
        }
    }
    if ((flags & 8) != 0) { msg.replyKeyboardPlaceholder = d.readString() }
}

/** 读一个 KeyboardButton 并返回按钮文字；非纯文字类按钮交给 skipKeyboardButton 并返回其文字（若可得）。 */
func readKeyboardButtonText(d: TLDeserializer): String {
    let saved = d.getOffset()
    let constructor = d.readUInt32()
    // Layer 214：keyboardButton#a2fa4880 / requestPhone#b16a6c29 / requestGeoLocation#fc796b3f 只有 text
    if (constructor == 0xa2fa4880 || constructor == 0xb16a6c29 || constructor == 0xfc796b3f) {
        return d.readString()
    }
    // 当前层：keyboardButton#7d170cff / requestPhone#417efd8f / requestGeoLocation#aa40f94d：flags style?[10] text
    if (constructor == 0x7d170cff || constructor == 0x417efd8f || constructor == 0xaa40f94d) {
        let flags = d.readInt32()
        if ((flags & (1 << 10)) != 0) {
            let _ = d.readUInt32()
            skipKeyboardButtonStyle(d)
        }
        return d.readString()
    }
    d.setOffset(saved)
    skipKeyboardButton(d)
    return ""
}

func skipKeyboardButtonRows(d: TLDeserializer): Unit {
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            skipKeyboardButtonRow(d)
        }
    }
}

func skipKeyboardButtonRow(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor
    // buttons: Vector<KeyboardButton>
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            skipKeyboardButton(d)
        }
    }
}

// skipKeyboardButtonStyle — keyboardButtonStyle#4fdd3430
// flags:Int32  icon?[flags.3]:Int64
// Called AFTER the outer constructor is already confirmed as 0x4fdd3430.
func skipKeyboardButtonStyle(d: TLDeserializer): Unit {
    let styleFlags = d.readInt32()
    if ((styleFlags & 8) != 0) { let _ = d.readInt64() }  // icon - bit 3
}

// skipRequestPeerType — skips one boxed RequestPeerType (reads ctor + fields)
// Variants (all start with flags:Int32, then optional boxed fields):
//   requestPeerTypeUser#5f3b8a00    flags bot?[0]:Bool premium?[1]:Bool
//   requestPeerTypeBroadcast#339bef6c flags hasUsername?[3]:Bool userAdminRights?[1]:ChatAdminRights botAdminRights?[2]:ChatAdminRights
//   requestPeerTypeChat#c9f06e1b   flags hasUsername?[3]:Bool forum?[4]:Bool userAdminRights?[1]:ChatAdminRights botAdminRights?[2]:ChatAdminRights
//   requestPeerTypeCreateBot#3e81e078 flags suggestedName?[1]:string suggestedUsername?[2]:string
// ChatAdminRights#5fb224d4 is just flags:Int32.
func skipRequestPeerType(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    let flags = d.readInt32()
    if (ctor == 0x5f3b8a00) {
        // requestPeerTypeUser: bot?[0]:Bool premium?[1]:Bool (both boxed UInt32)
        if ((flags & 1) != 0) { let _ = d.readUInt32() }   // bot:Bool
        if ((flags & 2) != 0) { let _ = d.readUInt32() }   // premium:Bool
    } else if (ctor == 0x339bef6c) {
        // requestPeerTypeBroadcast: hasUsername?[3]:Bool userAdminRights?[1]:ChatAdminRights botAdminRights?[2]:ChatAdminRights
        if ((flags & 8) != 0) { let _ = d.readUInt32() }   // hasUsername:Bool (boxed)
        if ((flags & 2) != 0) { let _ = d.readUInt32(); let _ = d.readInt32() }  // userAdminRights ctor + flags:Int32
        if ((flags & 4) != 0) { let _ = d.readUInt32(); let _ = d.readInt32() }  // botAdminRights ctor + flags:Int32
    } else if (ctor == 0xc9f06e1b) {
        // requestPeerTypeChat: hasUsername?[3]:Bool forum?[4]:Bool userAdminRights?[1]:ChatAdminRights botAdminRights?[2]:ChatAdminRights
        if ((flags & 8) != 0) { let _ = d.readUInt32() }   // hasUsername:Bool (boxed)
        if ((flags & 16) != 0) { let _ = d.readUInt32() }  // forum:Bool (boxed)
        if ((flags & 2) != 0) { let _ = d.readUInt32(); let _ = d.readInt32() }  // userAdminRights
        if ((flags & 4) != 0) { let _ = d.readUInt32(); let _ = d.readInt32() }  // botAdminRights
    } else if (ctor == 0x3e81e078) {
        // requestPeerTypeCreateBot: suggestedName?[1]:string suggestedUsername?[2]:string
        if ((flags & 2) != 0) { let _ = d.readString() }   // suggestedName
        if ((flags & 4) != 0) { let _ = d.readString() }   // suggestedUsername
    }
    // unknown ctor: only flags was read, cannot safely skip — leave as best effort
}

// skipKeyboardButton — current iOS layer (verified against Api15.swift + Api0.swift dict)
// ALL variants share the common prefix:
//   flags:Int32  style?[flags.10]:KeyboardButtonStyle  [+ variant-specific fields]  text:string
// EXCEPT keyboardButtonRequestPoll where quiz?[0]:Bool comes BEFORE text.
// EXCEPT keyboardButtonRequestPeer where button_id, peer_type, max_quantity come AFTER text.
//
// Ctor table (verified vs Api0.swift dict + python hex conversion):
//   keyboardButton#7d170cff           (was 0xa2fa4880)
//   keyboardButtonUrl#d80c25ec        (was 0x258aff05)
//   keyboardButtonCallback#e62bc960   (was 0x35bbdb6b)
//   keyboardButtonRequestPhone#417efd8f (was 0xb16a6c29)
//   keyboardButtonRequestGeoLocation#aa40f94d (was 0xfc796b3f)
//   keyboardButtonSwitchInline#991399fc (was 0x93b9fbb5)
//   keyboardButtonGame#89c590f9       (was 0x50f41ccf)
//   keyboardButtonBuy#3fa53905        (was 0xafd93fbb)
//   keyboardButtonUrlAuth#f51006f9    (was 0x10b78d29)
//   keyboardButtonRequestPoll#7a11d782 (was 0xbbc7515d)
//   keyboardButtonCopy#bcc4af10       (NEW — copyText:string)
//   keyboardButtonUserProfile#c0fd5d09 (NEW — userId:Int64)
//   keyboardButtonWebView#e846b1a0    (NEW — url:string)
//   keyboardButtonSimpleWebView#e15c4370 (NEW — url:string)
//   keyboardButtonRequestPeer#5b0f15f5 (NEW — buttonId:Int32 peerType:RequestPeerType maxQuantity:Int32)
func skipKeyboardButton(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()

    // Layer 214 constructors used by the negotiated target protocol. These
    // predate KeyboardButtonStyle, so they must be consumed before reading
    // the flags/style prefix used by the current iOS layer.
    if (constructor == 0x35bbdb6b) {
        let _ = d.readInt32()  // flags (requires_password is a boolean bit)
        let _ = d.readString() // text
        let _ = d.readBytes()  // callback data
        return
    }
    if (constructor == 0xafd93fbb) {
        let _ = d.readString() // text
        return
    }
    // Layer 214 其余无 style 前缀的旧构造（telegram_api.tl layer 203/214 同号）：
    //   keyboardButton#a2fa4880 text / requestPhone#b16a6c29 text / requestGeoLocation#fc796b3f text /
    //   game#50f41ccf text
    if (constructor == 0xa2fa4880 || constructor == 0xb16a6c29 || constructor == 0xfc796b3f ||
        constructor == 0x50f41ccf) {
        let _ = d.readString()
        return
    }
    //   url#258aff05 / webView#13767230 / simpleWebView#a0c0505c / copy#75d2698e：text + string
    if (constructor == 0x258aff05 || constructor == 0x13767230 || constructor == 0xa0c0505c ||
        constructor == 0x75d2698e) {
        let _ = d.readString()
        let _ = d.readString()
        return
    }
    //   userProfile#308660c1 text user_id:long
    if (constructor == 0x308660c1) {
        let _ = d.readString()
        let _ = d.readInt64()
        return
    }
    //   switchInline#93b9fbb5 flags text query peer_types?[1]
    if (constructor == 0x93b9fbb5) {
        let oflags = d.readInt32()
        let _ = d.readString()
        let _ = d.readString()
        if ((oflags & 2) != 0) {
            let vecCtor = d.readUInt32()
            if (vecCtor == TLConstructors.VECTOR) {
                let cnt = d.readInt32()
                for (_ in 0..Int64(cnt)) { let _ = d.readUInt32() }
            }
        }
        return
    }
    //   urlAuth#10b78d29 flags text fwd_text?[0] url button_id
    if (constructor == 0x10b78d29) {
        let oflags = d.readInt32()
        let _ = d.readString()
        if ((oflags & 1) != 0) { let _ = d.readString() }
        let _ = d.readString()
        let _ = d.readInt32()
        return
    }
    //   requestPoll#bbc7515d flags quiz?[0]:Bool text
    if (constructor == 0xbbc7515d) {
        let oflags = d.readInt32()
        if ((oflags & 1) != 0) { let _ = d.readBool() }
        let _ = d.readString()
        return
    }
    //   requestPeer#53d7bfd8 text button_id peer_type max_quantity
    if (constructor == 0x53d7bfd8) {
        let _ = d.readString()
        let _ = d.readInt32()
        skipRequestPeerType(d)
        let _ = d.readInt32()
        return
    }

    let flags = d.readInt32()
    // style?[flags.10]:KeyboardButtonStyle (boxed; ctor must be 0x4fdd3430)
    if ((flags & (1 << 10)) != 0) {
        let _ = d.readUInt32()  // KeyboardButtonStyle ctor (0x4fdd3430)
        skipKeyboardButtonStyle(d)
    }
    // keyboardButton#7d170cff flags:# style?[10] text:string
    if (constructor == 0x7d170cff) {
        let _ = d.readString()
        return
    }
    // keyboardButtonBuy#3fa53905 flags:# style?[10] text:string
    if (constructor == 0x3fa53905) {
        let _ = d.readString()
        return
    }
    // keyboardButtonGame#89c590f9 flags:# style?[10] text:string
    if (constructor == 0x89c590f9) {
        let _ = d.readString()
        return
    }
    // keyboardButtonRequestPhone#417efd8f flags:# style?[10] text:string
    if (constructor == 0x417efd8f) {
        let _ = d.readString()
        return
    }
    // keyboardButtonRequestGeoLocation#aa40f94d flags:# style?[10] text:string
    if (constructor == 0xaa40f94d) {
        let _ = d.readString()
        return
    }
    // keyboardButtonUserProfile#c0fd5d09 flags:# style?[10] text:string userId:Int64
    if (constructor == 0xc0fd5d09) {
        let _ = d.readString()
        let _ = d.readInt64()  // userId
        return
    }
    // keyboardButtonUrl#d80c25ec flags:# style?[10] text:string url:string
    if (constructor == 0xd80c25ec) {
        let _ = d.readString()
        let _ = d.readString()
        return
    }
    // keyboardButtonSimpleWebView#e15c4370 flags:# style?[10] text:string url:string
    if (constructor == 0xe15c4370) {
        let _ = d.readString()
        let _ = d.readString()
        return
    }
    // keyboardButtonWebView#e846b1a0 flags:# style?[10] text:string url:string
    if (constructor == 0xe846b1a0) {
        let _ = d.readString()
        let _ = d.readString()
        return
    }
    // keyboardButtonCopy#bcc4af10 flags:# style?[10] text:string copyText:string
    if (constructor == 0xbcc4af10) {
        let _ = d.readString()
        let _ = d.readString()
        return
    }
    // keyboardButtonCallback#e62bc960 flags:# style?[10] text:string data:bytes
    if (constructor == 0xe62bc960) {
        let _ = d.readString()
        let _ = d.readBytes()
        return
    }
    // keyboardButtonSwitchInline#991399fc flags:# style?[10] text:string query:string peerTypes?[flags.1]:Vector<InlineQueryPeerType>
    // InlineQueryPeerType variants have no fields (all are empty ctors), so skip vector by consuming ctors only.
    if (constructor == 0x991399fc) {
        let _ = d.readString()
        let _ = d.readString()
        if ((flags & 2) != 0) {
            // Vector<InlineQueryPeerType> — all variants are empty (no fields)
            let vecCtor = d.readUInt32()
            if (vecCtor == TLConstructors.VECTOR) {
                let cnt = d.readInt32()
                for (_ in 0..Int64(cnt)) {
                    let _ = d.readUInt32()  // InlineQueryPeerType ctor (no fields in any variant)
                }
            }
        }
        return
    }
    // keyboardButtonUrlAuth#f51006f9 flags:# style?[10] text:string fwdText?[flags.0]:string url:string buttonId:Int32
    if (constructor == 0xf51006f9) {
        let _ = d.readString()
        if ((flags & 1) != 0) { let _ = d.readString() }  // fwdText
        let _ = d.readString()
        let _ = d.readInt32()
        return
    }
    // keyboardButtonRequestPoll#7a11d782 flags:# style?[10] quiz?[flags.0]:Bool text:string
    if (constructor == 0x7a11d782) {
        if ((flags & 1) != 0) { let _ = d.readBool() }  // quiz:Bool (boxed)
        let _ = d.readString()
        return
    }
    // keyboardButtonRequestPeer#5b0f15f5 flags:# style?[10] text:string buttonId:Int32 peerType:RequestPeerType maxQuantity:Int32
    if (constructor == 0x5b0f15f5) {
        let _ = d.readString()
        let _ = d.readInt32()   // buttonId
        skipRequestPeerType(d)  // boxed RequestPeerType
        let _ = d.readInt32()   // maxQuantity
        return
    }
    // Unknown keyboard button constructor — log and skip text (best effort)
    Hilog.info(0, "CjTelegram", "[skipKeyboardButton] Unknown ctor: 0x${toHex32(constructor)}")
    let _ = d.readString()
}

/**
 * Phase Q11: 解析 MessageEntity Vector 并捕获实体数据
 */
func parseMessageEntitiesCapture(d: TLDeserializer): ArrayList<TLTextEntity> {
    let result = ArrayList<TLTextEntity>()
    let vecConst = d.readUInt32()
    if (vecConst != TLConstructors.VECTOR) { return result }
    let count = d.readInt32()
    for (_i in 0..Int64(count)) {
        let entity = parseMessageEntityCapture(d)
        if (entity.entityType.size > 0) {
            result.add(entity)
        }
    }
    return result
}

/**
 * Phase Q11: 解析单个 MessageEntity 并返回 TLTextEntity
 * ctor→标签→字段全部对 iOS Api0.swift dict + Api17.swift parse_messageEntity* 核验重建
 */
func parseMessageEntityCapture(d: TLDeserializer): TLTextEntity {
    let entity = TLTextEntity()
    let constructor = d.readUInt32()

    // messageEntityBlockquote#f1ccaaac flags:int offset:int length:int
    // HIGH-1: iOS parse_messageEntityBlockquote 读 3 个 int (flags+offset+length)
    // collapsed 标志位在 flags.0，不影响 offset/length 的读取顺序
    if (constructor == 0xf1ccaaac) {
        entity.entityType = "blockquote"
        let _ = d.readInt32()      // flags (collapsed:flags.0?true)
        entity.offset = d.readInt32()
        entity.length = d.readInt32()
        return entity
    }

    // messageEntityFormattedDate#904ac7c7 flags:int offset:int length:int date:int
    if (constructor == 0x904ac7c7) {
        entity.entityType = "formattedDate"
        let _ = d.readInt32()  // flags
        entity.offset = d.readInt32()
        entity.length = d.readInt32()
        let _ = d.readInt32()  // date
        return entity
    }

    // messageEntityPre#73924be0 offset:int length:int language:string
    if (constructor == 0x73924be0) {
        entity.entityType = "pre"
        entity.offset = d.readInt32()
        entity.length = d.readInt32()
        entity.language = d.readString()
        return entity
    }

    // messageEntityTextUrl#76a6d327 offset:int length:int url:string
    if (constructor == 0x76a6d327) {
        entity.entityType = "textUrl"
        entity.offset = d.readInt32()
        entity.length = d.readInt32()
        entity.url = d.readString()
        return entity
    }

    // messageEntityDiffReplace#c6c1e5a7 offset:int length:int old_text:string
    if (constructor == 0xc6c1e5a7) {
        entity.entityType = "diffReplace"
        entity.offset = d.readInt32()
        entity.length = d.readInt32()
        let _ = d.readString()  // old_text
        return entity
    }

    // messageEntityMentionName#dc7b1140 offset:int length:int user_id:long
    if (constructor == 0xdc7b1140) {
        entity.entityType = "mentionName"
        entity.offset = d.readInt32()
        entity.length = d.readInt32()
        entity.userId = d.readInt64()
        return entity
    }

    // messageEntityCustomEmoji#c8cf05f8 offset:int length:int document_id:long
    if (constructor == 0xc8cf05f8) {
        entity.entityType = "customEmoji"
        entity.offset = d.readInt32()
        entity.length = d.readInt32()
        entity.documentId = d.readInt64()
        // 保留这条：这个账号（无 Premium）收不到也发不出带正文自定义表情的消息，
        // B-4 的端到端验证一直卡在这里。哪天真收到一条，日志会立刻告诉你去哪验。
        Hilog.info(0, "CjTelegram",
            "[InlineCustomEmoji] 正文自定义表情 docId=${entity.documentId} off=${entity.offset}")
        return entity
    }

    // 简单类型: offset:int length:int (逐变体对 iOS Api0 dict + Api17 parse 核验)
    //   0xbb92ba95 messageEntityUnknown    (iOS dict[-1148011883])
    //   0xfa04579d messageEntityMention    (iOS dict[-100378723])
    //   0x6f635b0d messageEntityHashtag    (iOS dict[1868782349])
    //   0x6cef8ac7 messageEntityBotCommand (iOS dict[1827637959])
    //   0x6ed02538 messageEntityUrl        (iOS dict[1859134776])
    //   0x64e475c2 messageEntityEmail      (iOS dict[1692693954])
    //   0xbd610bc9 messageEntityBold       (iOS dict[-1117713463])
    //   0x826f8b60 messageEntityItalic     (iOS dict[-2106619040])
    //   0x28a20571 messageEntityCode       (iOS dict[681706865])
    //   0x9b69e34b messageEntityPhone      (iOS dict[-1687559349]) -- 旧误标 Underline
    //   0x9c4e7e8b messageEntityUnderline  (iOS dict[-1672577397]) -- 旧误标 Cashtag
    //   0xbf0693d4 messageEntityStrike     (iOS dict[-1090087980])
    //   0x4c4e743f messageEntityCashtag    (iOS dict[1280209983])  -- 旧缺失
    //   0x761e6af4 messageEntityBankCard   (iOS dict[1981704948])  -- 旧缺失
    //   0x32ca960f messageEntitySpoiler    (iOS dict[852137487])   -- 旧误标 BankCard
    //   0x0652c1c5 messageEntityDiffDelete (iOS dict[106086853])   -- 新增
    //   0x71777116 messageEntityDiffInsert (iOS dict[1903653142])  -- 新增
    // 删除死值: 0x020df5d0 (iOS dict 0 命中)
    if (constructor == 0xbb92ba95) { entity.entityType = "unknown" }
    if (constructor == 0xfa04579d) { entity.entityType = "mention" }
    if (constructor == 0x6f635b0d) { entity.entityType = "hashtag" }
    if (constructor == 0x6cef8ac7) { entity.entityType = "botCommand" }
    if (constructor == 0x6ed02538) { entity.entityType = "url" }
    if (constructor == 0x64e475c2) { entity.entityType = "email" }
    if (constructor == 0xbd610bc9) { entity.entityType = "bold" }
    if (constructor == 0x826f8b60) { entity.entityType = "italic" }
    if (constructor == 0x28a20571) { entity.entityType = "code" }
    if (constructor == 0x9b69e34b) { entity.entityType = "phone" }       // 旧误标 underline
    if (constructor == 0x9c4e7e8b) { entity.entityType = "underline" }   // 旧误标 cashtag
    if (constructor == 0xbf0693d4) { entity.entityType = "strike" }
    if (constructor == 0x4c4e743f) { entity.entityType = "cashtag" }     // 旧缺失
    if (constructor == 0x761e6af4) { entity.entityType = "bankCard" }    // 旧缺失
    if (constructor == 0x32ca960f) { entity.entityType = "spoiler" }     // 旧误标 bankCard
    if (constructor == 0x0652c1c5) { entity.entityType = "diffDelete" }  // 新增
    if (constructor == 0x71777116) { entity.entityType = "diffInsert" }  // 新增

    if (entity.entityType.size > 0) {
        entity.offset = d.readInt32()
        entity.length = d.readInt32()
        return entity
    }

    // 未知类型: 读 offset + length 跳过
    entity.entityType = ""
    let _ = d.readInt32()
    let _ = d.readInt32()
    return entity
}

/**
 * 跳过 MessageEntity Vector
 */
public func skipMessageEntitiesVector(d: TLDeserializer): Unit {
    let vecConst = d.readUInt32()
    if (vecConst != TLConstructors.VECTOR) { return }
    let count = d.readInt32()
    for (_i in 0..Int64(count)) {
        skipMessageEntity(d)
    }
}

func skipMessageEntity(d: TLDeserializer): Unit {
    // iOS Api0.swift dict + Api17.swift parse_messageEntity* 逐变体核验重建
    // 正确 ctor→标签→字段映射（python 验 Api0 dict signed int → hex）
    let constructor = d.readUInt32()

    // messageEntityBlockquote#f1ccaaac flags:int offset:int length:int
    // HIGH-1 根因：iOS parse_messageEntityBlockquote 读 3 个 int (flags+offset+length)
    // 旧代码仅读 2 个 int 导致流错位，必须读 3 个
    if (constructor == 0xf1ccaaac) {
        let _ = d.readInt32()  // flags (collapsed:flags.0?true)
        let _ = d.readInt32()  // offset
        let _ = d.readInt32()  // length
        return
    }

    // messageEntityFormattedDate#904ac7c7 flags:int offset:int length:int date:int
    // iOS parse_messageEntityFormattedDate 读 4 个 int
    if (constructor == 0x904ac7c7) {
        let _ = d.readInt32()  // flags
        let _ = d.readInt32()  // offset
        let _ = d.readInt32()  // length
        let _ = d.readInt32()  // date
        return
    }

    // messageEntityPre#73924be0 offset:int length:int language:string
    if (constructor == 0x73924be0) {
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readString()
        return
    }

    // messageEntityTextUrl#76a6d327 offset:int length:int url:string
    if (constructor == 0x76a6d327) {
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readString()
        return
    }

    // messageEntityDiffReplace#c6c1e5a7 offset:int length:int old_text:string
    // iOS parse_messageEntityDiffReplace: readInt32 + readInt32 + parseString
    if (constructor == 0xc6c1e5a7) {
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readString()
        return
    }

    // messageEntityMentionName#dc7b1140 offset:int length:int user_id:long
    if (constructor == 0xdc7b1140) {
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readInt64()
        return
    }

    // messageEntityCustomEmoji#c8cf05f8 offset:int length:int document_id:long
    if (constructor == 0xc8cf05f8) {
        let _ = d.readInt32()
        let _ = d.readInt32()
        let dropped = d.readInt64()
        // 这条是警报而非诊断：走到这里说明该消息路径**丢弃**了正文自定义表情。
        // 若日志里出现它而气泡上没渲染出表情，先怀疑这条路径而不是渲染层。
        Hilog.info(0, "CjTelegram",
            "[InlineCustomEmoji] 警告：跳过路径丢弃了自定义表情 docId=${dropped}")
        return
    }

    // 简单类型：offset:int length:int (2 个 int)
    // 逐变体对 iOS Api0 dict + Api17.swift parse 核验：
    //   0xbb92ba95 messageEntityUnknown    (iOS dict[-1148011883])
    //   0xfa04579d messageEntityMention    (iOS dict[-100378723])
    //   0x6f635b0d messageEntityHashtag    (iOS dict[1868782349])
    //   0x6cef8ac7 messageEntityBotCommand (iOS dict[1827637959])
    //   0x6ed02538 messageEntityUrl        (iOS dict[1859134776])
    //   0x64e475c2 messageEntityEmail      (iOS dict[1692693954])
    //   0xbd610bc9 messageEntityBold       (iOS dict[-1117713463])
    //   0x826f8b60 messageEntityItalic     (iOS dict[-2106619040])
    //   0x28a20571 messageEntityCode       (iOS dict[681706865])
    //   0x9b69e34b messageEntityPhone      (iOS dict[-1687559349]) -- 旧代码误标 Underline
    //   0x9c4e7e8b messageEntityUnderline  (iOS dict[-1672577397]) -- 旧代码误标 Cashtag
    //   0xbf0693d4 messageEntityStrike     (iOS dict[-1090087980])
    //   0x4c4e743f messageEntityCashtag    (iOS dict[1280209983])  -- 旧代码缺失
    //   0x761e6af4 messageEntityBankCard   (iOS dict[1981704948])  -- 旧代码缺失
    //   0x32ca960f messageEntitySpoiler    (iOS dict[852137487])   -- 旧代码误标 BankCard
    //   0x0652c1c5 messageEntityDiffDelete (iOS dict[106086853])   -- 新增
    //   0x71777116 messageEntityDiffInsert (iOS dict[1903653142])  -- 新增
    // 删除死值: 0x020df5d0 (iOS dict 0 命中), 0x9b69e34b 已重标 Phone
    if (constructor == 0xbb92ba95 || // messageEntityUnknown
        constructor == 0xfa04579d || // messageEntityMention
        constructor == 0x6f635b0d || // messageEntityHashtag
        constructor == 0x6cef8ac7 || // messageEntityBotCommand
        constructor == 0x6ed02538 || // messageEntityUrl
        constructor == 0x64e475c2 || // messageEntityEmail
        constructor == 0xbd610bc9 || // messageEntityBold
        constructor == 0x826f8b60 || // messageEntityItalic
        constructor == 0x28a20571 || // messageEntityCode
        constructor == 0x9b69e34b || // messageEntityPhone (旧代码误标 Underline)
        constructor == 0x9c4e7e8b || // messageEntityUnderline (旧代码误标 Cashtag)
        constructor == 0xbf0693d4 || // messageEntityStrike
        constructor == 0x4c4e743f || // messageEntityCashtag (旧代码缺失)
        constructor == 0x761e6af4 || // messageEntityBankCard (旧代码缺失)
        constructor == 0x32ca960f || // messageEntitySpoiler (旧代码误标 BankCard)
        constructor == 0x0652c1c5 || // messageEntityDiffDelete (新增)
        constructor == 0x71777116) { // messageEntityDiffInsert (新增)
        let _ = d.readInt32()  // offset
        let _ = d.readInt32()  // length
        return
    }

    // 默认：尝试读 offset + length
    let _ = d.readInt32()
    let _ = d.readInt32()
}

/**
 * messageReplies#83d60fc2 flags:# comments:flags.0?true replies:int replies_pts:int
 *   recent_repliers:flags.1?Vector<Peer> channel_id:flags.0?long max_id:flags.2?int read_max_id:flags.3?int
 * （iOS Api18.swift:472 parse_messageReplies）
 */
func parseMessageRepliesInto(d: TLDeserializer, msg: TLMessage): Unit {
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    msg.repliesIsComments = (flags & 1) != 0
    msg.repliesCount = d.readInt32()  // replies
    let _ = d.readInt32()  // replies_pts
    if ((flags & 2) != 0) {
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let _ = PeerResponse.deserializeBoxed(d)
            }
        }
    }
    if ((flags & 1) != 0) { msg.repliesChannelId = d.readInt64() }  // channel_id
    if ((flags & 4) != 0) { msg.repliesMaxId = d.readInt32() }  // max_id
    if ((flags & 8) != 0) { let _ = d.readInt32() }  // read_max_id
}

/**
 * 跳过 MessageReplies
 */
func skipMessageReplies(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    let _ = d.readInt32()  // replies
    let _ = d.readInt32()  // replies_pts
    if ((flags & 2) != 0) {
        // recent_repliers: Vector<Peer>
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let _ = PeerResponse.deserializeBoxed(d)
            }
        }
    }
    if ((flags & 1) != 0) { let _ = d.readInt64() }  // channel_id
    if ((flags & 4) != 0) { let _ = d.readInt32() }  // max_id
    if ((flags & 8) != 0) { let _ = d.readInt32() }  // read_max_id
}

/**
 * Phase Q11: 富文本实体
 * type: bold, italic, code, pre, textUrl, strike, underline, mention, hashtag, url, email, spoiler, blockquote, botCommand, customEmoji
 */
public class TLTextEntity {
    public var entityType: String = ""
    public var offset: Int32 = 0
    public var length: Int32 = 0
    public var url: String = ""        // for textUrl
    public var language: String = ""   // for pre
    public var userId: Int64 = 0       // for mentionName
    public var documentId: Int64 = 0   // for customEmoji
    
    public init() {}
}

/**
 * Phase Q8: 投票选项数据
 * 每个选项包含文本、option 标识、投票人数、是否被当前用户选中、是否为正确答案
 */
public class TLPollOption {
    public var text: String = ""
    public var optionBytes: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var voters: Int32 = 0
    public var chosen: Bool = false
    public var correct: Bool = false

    public init() {}
}

/**
 * TLReactionCount: 单个 Reaction 的解析数据
 * 
 * 对应 TL Schema: reactionCount#a3d1cb80
 * flags:# chosen_order:flags.0?int reaction:Reaction count:int
 */
public class TLReactionCount {
    public var emoji: String = ""
    // reactionCustomEmoji 的 document_id（0 = 普通 emoji 反应）。
    // 此前这里直接被丢掉、emoji 写成 "[Custom]"，自定义表情反应因此发得出去、显示不出来。
    public var customEmojiDocumentId: Int64 = 0
    public var count: Int32 = 0
    public var isChosen: Bool = false  // chosen_order 存在 = 当前用户已选中
    // recent_reactions 中的 peer IDs（用于显示谁回复了该 reaction）
    public var recentPeerIds: ArrayList<Int64> = ArrayList<Int64>()
    
    public init() {}
}

/**
 * 解析 MessageReactions（Phase H6: 从跳过改为解析）
 * 
 * TL Schema: messageReactions#a339f0b
 * flags:# min:flags.0?true can_see_list:flags.2?true reactions_as_tags:flags.3?true
 * results:Vector<ReactionCount> recent_reactions:flags.1?Vector<MessagePeerReaction>
 * top_reactors:flags.4?Vector<MessageReactor>
 */
public func parseMessageReactions(d: TLDeserializer): ArrayList<TLReactionCount> {
    let result = ArrayList<TLReactionCount>()
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    // results: Vector<ReactionCount> — 解析！
    let vecConst = d.readUInt32()
    if (vecConst == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            let rc = parseReactionCount(d)
            // 跳过 reactionEmpty；自定义表情没有 emoticon，靠 document_id 识别
            if (rc.emoji.size > 0 || rc.customEmojiDocumentId != 0) {
                result.add(rc)
            }
        }
    }
    // recent_reactions - flags bit 1（解析 peer ID 和 emoji，用于显示"谁回复了"）
    if ((flags & 2) != 0) {
        let vecConst2 = d.readUInt32()
        if (vecConst2 == TLConstructors.VECTOR) {
            let count2 = d.readInt32()
            for (_i in 0..Int64(count2)) {
                // 解析 MessagePeerReaction: flags peer_id date reaction
                let _ = d.readUInt32()  // constructor
                let _peerFlags = d.readInt32()
                let peer = PeerResponse.deserializeBoxed(d)  // peer_id
                let _ = d.readInt32()  // date
                let reaction = parseReaction(d)
                // 将 peerId 归到对应的那条反应上（自定义表情按 document_id 匹配）
                for (rc in result) {
                    if (reaction.customEmojiDocumentId != 0) {
                        if (rc.customEmojiDocumentId == reaction.customEmojiDocumentId) {
                            rc.recentPeerIds.add(peer.id)
                            break
                        }
                    } else if (rc.emoji.size > 0 && rc.emoji == reaction.emoji) {
                        rc.recentPeerIds.add(peer.id)
                        break
                    }
                }
            }
        }
    }
    // top_reactors - flags bit 4 (Layer 214 新增，匹配 TelegramHarmony)（仍然跳过）
    if ((flags & 16) != 0) {
        let vecConst3 = d.readUInt32()
        if (vecConst3 == TLConstructors.VECTOR) {
            let count3 = d.readInt32()
            for (_i in 0..Int64(count3)) {
                skipMessageReactor(d)
            }
        }
    }
    return result
}

func skipMessageReactor(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    if ((flags & 8) != 0) { let _ = PeerResponse.deserializeBoxed(d) }  // peer_id - bit 3
    let _ = d.readInt32()  // count
}

/**
 * 解析 ReactionCount — 提取 emoji + count + isChosen
 * 
 * TL Schema: reactionCount#a3d1cb80
 * flags:# chosen_order:flags.0?int reaction:Reaction count:int
 */
func parseReactionCount(d: TLDeserializer): TLReactionCount {
    let rc = TLReactionCount()
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    rc.isChosen = (flags & 1) != 0  // chosen_order 存在 = 当前用户选中
    if ((flags & 1) != 0) { let _ = d.readInt32() }  // chosen_order value
    let reaction = parseReaction(d)
    rc.emoji = reaction.emoji
    rc.customEmojiDocumentId = reaction.customEmojiDocumentId
    rc.count = d.readInt32()  // count
    return rc
}

/** 一条 Reaction 的解析结果：普通表情给 emoji，自定义表情给 document_id */
public class TLReactionValue {
    public var emoji: String = ""
    public var customEmojiDocumentId: Int64 = 0

    public init() {}
}

/**
 * 解析 Reaction
 *
 * reactionEmpty#79f5d419 → 空
 * reactionEmoji#1b2286b8 emoticon:string → emoticon
 * reactionCustomEmoji#8935fc73 document_id:long → documentId（对应 iOS .custom(fileId)）
 * reactionPaid#523da4eb → "⭐"
 */
func parseReaction(d: TLDeserializer): TLReactionValue {
    let value = TLReactionValue()
    let constructor = d.readUInt32()
    if (constructor == 0x79f5d419) {
        // reactionEmpty
        return value
    }
    if (constructor == 0x1b2286b8) {
        // reactionEmoji emoticon:string
        value.emoji = d.readString()
        return value
    }
    if (constructor == 0x8935fc73) {
        // reactionCustomEmoji document_id:long
        value.customEmojiDocumentId = d.readInt64()
        return value
    }
    if (constructor == 0x523da4eb) {
        // reactionPaid (无额外字段)
        value.emoji = "⭐"
        return value
    }
    // 未知 reaction 类型，安全跳过
    Hilog.info(0, "CjTelegram", "[TLDialogs] Unknown reaction constructor: ${constructor}")
    return value
}

/**
 * 跳过 Reaction（用于 skipMessagePeerReaction 等不需要解析的场景）
 */
func skipReaction(d: TLDeserializer): Unit {
    let _ = parseReaction(d)
}

func skipMessagePeerReaction(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    let _ = PeerResponse.deserializeBoxed(d)  // peer_id
    let _ = d.readInt32()  // date
    skipReaction(d)  // reaction
}

/**
 * 跳过 FactCheck
 */
// skipFactCheck — verified vs Api7.swift parse_factCheck + Api0.swift dict[-1197736753]
// factCheck#b89b2a6c flags:Int32 country?[flags.1]:string text?[flags.1]:TextWithEntities hash:Int64
// textWithEntities#dc3d824f text:string entities:Vector<MessageEntity>
// Old code used (flags & 1) = bit 0; correct is (flags & 2) = bit 1.
// Old code also missed country:string before text.
func skipFactCheck(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    if ((flags & 2) != 0) {
        // country?[flags.1]:string
        let _ = d.readString()
        // text?[flags.1]:TextWithEntities (boxed)
        let _ = d.readUInt32()  // TextWithEntities ctor
        let _ = d.readString()  // text
        skipMessageEntitiesVector(d)  // entities
    }
    let _ = d.readInt64()  // hash
}

// ==================== 会话列表响应 ====================

public class MessagesDialogsResponse {
    public var dialogs: ArrayList<TLDialog> = ArrayList<TLDialog>()
    public var messages: ArrayList<TLMessage> = ArrayList<TLMessage>()
    public var chats: ArrayList<ChatResponse> = ArrayList<ChatResponse>()
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()
    public var count: Int32 = 0

    public static func deserialize(data: Array<Byte>): MessagesDialogsResponse {
        let r = MessagesDialogsResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()

        Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Constructor: ${constructor}")

        // messages.dialogsNotModified#f0e3e596
        if (constructor == 0xf0e3e596) {
            r.count = d.readInt32()
            Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Not modified, count=${r.count}")
            return r
        }

        // messages.dialogs#15ba6c40 or messages.dialogsSlice#71e094f3
        if (constructor == 0x71e094f3) {
            r.count = d.readInt32()
            Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Slice, count=${r.count}")
        }

        // dialogs vector
        let _ = d.readUInt32() // vector constructor
        let dialogsCount = d.readInt32()
        Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Parsing ${dialogsCount} dialogs...")
        var dialogsFailed = false
        for (_i in 0..Int64(dialogsCount)) {
            try {
                r.dialogs.add(TLDialog.deserializeBoxed(d))
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Error parsing dialog ${_i}: ${e}")
                dialogsFailed = true
                break
            }
        }

        // messages vector — 匹配 TelegramHarmony: break 后继续解析
        var messagesFailed = false
        if (!dialogsFailed) {
            let msgsVecId = d.readUInt32()
            let msgsCount = d.readInt32()
            Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Parsing ${msgsCount} messages...")
            for (_i in 0..Int64(msgsCount)) {
                try {
                    r.messages.add(TLMessage.deserializeBoxed(d))
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Error parsing message ${_i}: ${e}")
                    messagesFailed = true
                    break
                }
            }
        } else {
            messagesFailed = true
        }

        // 如果消息解析失败，尝试扫描恢复 chats/users vectors
        if (messagesFailed) {
            Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Messages failed, attempting scan recovery for chats/users...")
            scanRecoverChatsAndUsers(d, data, r.chats, r.users)
            return r
        }

        // chats vector
        var chatsFailed = false
        let chatsVecId = d.readUInt32()
        let chatsCount = d.readInt32()
        Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Parsing ${chatsCount} chats...")
        for (_i in 0..Int64(chatsCount)) {
            try {
                r.chats.add(ChatResponse.deserializeBoxed(d))
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Error parsing chat ${_i}: ${e}")
                chatsFailed = true
                break
            }
        }

        if (chatsFailed) {
            Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Chats failed, attempting scan recovery for users...")
            scanRecoverUsers(d, data, r.users)
            return r
        }

        // users vector
        let usersVecId = d.readUInt32()
        let usersCount = d.readInt32()
        Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Parsing ${usersCount} users...")
        for (_i in 0..Int64(usersCount)) {
            try {
                r.users.add(UserResponse.deserializeBoxed(d))
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Error parsing user ${_i}: ${e}")
                dumpDialogsPayload(data)
                break
            }
        }

        Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] Parsing complete: ${r.dialogs.size} dialogs, ${r.messages.size} messages, ${r.chats.size} chats, ${r.users.size} users")
        return r
    }
}

/**
 * 诊断探针：users 向量解析失败（前段静默错位）时把完整原始响应转储到沙箱文件，
 * 供离线按 telegram_api.tl 逐字节复盘定位吃错字节的 ctor。定位后可移除。
 */
func dumpDialogsPayload(data: Array<Byte>): Unit {
    try {
        let path = "/data/storage/el2/base/haps/entry/files/tl_dialogs_dump.bin"
        let f = FileIo.open(path, mode: 0o1101)
        let _ = FileIo.write(f.fd, data)
        FileIo.close(f)
        Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] payload dumped: ${data.size}B -> ${path}")
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[MessagesDialogsResponse] payload dump failed: ${e}")
    }
}

func isKnownUserConstructor(ctor: UInt32): Bool {
    // 0x31774388 = current-layer user# ctor (see UserResponse.deserializeWithConstructor in
    // TLResponses.cj); was missing here so scan-recovery rejected valid current-layer users vectors.
    return ctor == 0xd3bc4b7a || ctor == 0x215c4438 || ctor == 0x20b1422 || ctor == 0x317a5722 || ctor == 0x31774388
}

func isKnownChatConstructor(ctor: UInt32): Bool {
    return ctor == 0x29562865 || ctor == 0x41cbf256 || ctor == 0x6592a1a7 ||
           ctor == 0xfe685355 || ctor == 0x1c32b11c || ctor == 0x17d493d5
}

/**
 * 扫描恢复：在数据中搜索 VECTOR 标记 (0x1cb5c415) 来找到 chats 和 users vectors
 * 策略：收集所有 vector 标记位置，从末尾向前扫描，通过 peek 第一个元素的 constructor
 * 来判断是 users 还是 chats vector，避免将消息内部的 vector 误认为 chats/users
 */
func scanRecoverChatsAndUsers(d: TLDeserializer, data: Array<Byte>,
    chatsList: ArrayList<ChatResponse>, usersList: ArrayList<UserResponse>): Unit {
    let vectorPositions = ArrayList<Int64>()
    var scanPos: Int64 = 0
    while (scanPos < Int64(data.size) - 12) {
        if (UInt8(data[scanPos]) == 0x15 && UInt8(data[scanPos + 1]) == 0xc4 &&
            UInt8(data[scanPos + 2]) == 0xb5 && UInt8(data[scanPos + 3]) == 0x1c) {
            vectorPositions.add(scanPos)
        }
        scanPos++
    }

    Hilog.info(0, "CjTelegram", "[ScanRecover] Found ${vectorPositions.size} vector markers, scanning backwards...")

    var foundUsers = false
    var foundChats = false

    var idx = vectorPositions.size - 1
    while (idx >= 0 && (!foundUsers || !foundChats)) {
        let pos = vectorPositions[idx]
        let count = (Int64(UInt8(data[pos + 4]))) |
                    (Int64(UInt8(data[pos + 5])) << 8) |
                    (Int64(UInt8(data[pos + 6])) << 16) |
                    (Int64(UInt8(data[pos + 7])) << 24)

        if (count > 0 && count < 500 && pos + 12 <= Int64(data.size)) {
            let firstCtor = UInt32(UInt8(data[pos + 8])) |
                           (UInt32(UInt8(data[pos + 9])) << 8) |
                           (UInt32(UInt8(data[pos + 10])) << 16) |
                           (UInt32(UInt8(data[pos + 11])) << 24)

            if (!foundUsers && isKnownUserConstructor(firstCtor)) {
                Hilog.info(0, "CjTelegram", "[ScanRecover] Users vector at pos ${pos}, count=${count}, ctor=${firstCtor}")
                d.setOffset(pos + 8)
                let tempUsers = ArrayList<UserResponse>()
                for (_i in 0..count) {
                    try {
                        tempUsers.add(UserResponse.deserializeBoxed(d))
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ScanRecover] User parse stopped at ${_i}: ${e}")
                        break
                    }
                }
                if (tempUsers.size > 0) {
                    for (u in tempUsers) { usersList.add(u) }
                    Hilog.info(0, "CjTelegram", "[ScanRecover] Recovered ${tempUsers.size} users")
                    foundUsers = true
                }
            } else if (!foundChats && isKnownChatConstructor(firstCtor)) {
                Hilog.info(0, "CjTelegram", "[ScanRecover] Chats vector at pos ${pos}, count=${count}, ctor=${firstCtor}")
                d.setOffset(pos + 8)
                let tempChats = ArrayList<ChatResponse>()
                for (_i in 0..count) {
                    try {
                        tempChats.add(ChatResponse.deserializeBoxed(d))
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ScanRecover] Chat parse stopped at ${_i}: ${e}")
                        break
                    }
                }
                if (tempChats.size > 0) {
                    for (c in tempChats) { chatsList.add(c) }
                    Hilog.info(0, "CjTelegram", "[ScanRecover] Recovered ${tempChats.size} chats")
                    foundChats = true
                }
            }
        }
        idx -= 1
    }

    Hilog.info(0, "CjTelegram", "[ScanRecover] Complete: ${chatsList.size} chats, ${usersList.size} users")
}

/**
 * 扫描恢复：仅恢复 users vector（从末尾向前扫描，通过 constructor 验证）
 */
func scanRecoverUsers(d: TLDeserializer, data: Array<Byte>, usersList: ArrayList<UserResponse>): Unit {
    let vectorPositions = ArrayList<Int64>()
    var scanPos: Int64 = 0
    while (scanPos < Int64(data.size) - 12) {
        if (UInt8(data[scanPos]) == 0x15 && UInt8(data[scanPos + 1]) == 0xc4 &&
            UInt8(data[scanPos + 2]) == 0xb5 && UInt8(data[scanPos + 3]) == 0x1c) {
            vectorPositions.add(scanPos)
        }
        scanPos++
    }

    var idx = vectorPositions.size - 1
    while (idx >= 0) {
        let pos = vectorPositions[idx]
        let count = (Int64(UInt8(data[pos + 4]))) |
                    (Int64(UInt8(data[pos + 5])) << 8) |
                    (Int64(UInt8(data[pos + 6])) << 16) |
                    (Int64(UInt8(data[pos + 7])) << 24)

        if (count > 0 && count < 500 && pos + 12 <= Int64(data.size)) {
            let firstCtor = UInt32(UInt8(data[pos + 8])) |
                           (UInt32(UInt8(data[pos + 9])) << 8) |
                           (UInt32(UInt8(data[pos + 10])) << 16) |
                           (UInt32(UInt8(data[pos + 11])) << 24)

            if (isKnownUserConstructor(firstCtor)) {
                Hilog.info(0, "CjTelegram", "[ScanRecover] Users vector at pos ${pos}, count=${count}")
                d.setOffset(pos + 8)
                let tempUsers = ArrayList<UserResponse>()
                for (_i in 0..count) {
                    try {
                        tempUsers.add(UserResponse.deserializeBoxed(d))
                    } catch (e: Exception) { break }
                }
                if (tempUsers.size > 0) {
                    for (u in tempUsers) { usersList.add(u) }
                    Hilog.info(0, "CjTelegram", "[ScanRecover] Recovered ${tempUsers.size} users")
                    return
                }
            }
        }
        idx -= 1
    }
    Hilog.info(0, "CjTelegram", "[ScanRecover] No users vector found")
}

// ==================== 消息历史响应 ====================

public class MessagesHistoryResponse {
    public var messages: ArrayList<TLMessage> = ArrayList<TLMessage>()
    public var chats: ArrayList<ChatResponse> = ArrayList<ChatResponse>()
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()
    public var count: Int32 = 0
    public var pts: Int32 = 0
    /** messages 向量中途解析失败、后面的消息被丢弃（只剩前面已解析的那几条）。 */
    public var messagesTruncated: Bool = false

    /**
     * 可用来判定「服务端正常回包」的会话消息总数：消息向量被截断时返回 0，
     * 防止把「解析失败导致的空页」当成「锚点以下已没有消息」。
     */
    public func reliableCount(): Int32 {
        if (this.messagesTruncated) { return 0 }
        return this.count
    }

    public static func deserialize(data: Array<Byte>): MessagesHistoryResponse {
        let r = MessagesHistoryResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()
        var isChannelMessages = false

        Hilog.info(0, "CjTelegram", "[MessagesHistoryResponse] Constructor: ${constructor}")

        // messages.messagesNotModified#74535f21 - 没有新消息
        if (constructor == 0x74535f21) {
            r.count = d.readInt32()
            Hilog.info(0, "CjTelegram", "[MessagesHistoryResponse] Messages not modified, count=${r.count}")
            return r
        }

        // messages.messagesSlice#762b263d (Layer 214) - 有 search_flood 字段
        if (constructor == 0x762b263d) {
            let flags = d.readInt32()
            r.count = d.readInt32()
            if ((flags & 1) != 0) { let _ = d.readInt32() } // next_rate - bit 0
            if ((flags & 4) != 0) { let _ = d.readInt32() } // offset_id_offset - bit 2
            if ((flags & 8) != 0) { skipSearchPostsFlood(d) } // search_flood - bit 3
        }

        // messages.messagesSlice#5f206716 (另一版本，带 search_flood)
        if (constructor == 0x5f206716) {
            let flags = d.readInt32()
            r.count = d.readInt32()
            if ((flags & 1) != 0) { let _ = d.readInt32() } // next_rate - bit 0
            if ((flags & 4) != 0) { let _ = d.readInt32() } // offset_id_offset - bit 2
            if ((flags & 8) != 0) { skipSearchPostsFlood(d) } // search_flood - bit 3
        }

        // messages.messagesSlice#3a54685e (旧版本，无 search_flood)
        if (constructor == 0x3a54685e) {
            let flags = d.readInt32()
            r.count = d.readInt32()
            if ((flags & 1) != 0) { let _ = d.readInt32() } // next_rate - bit 0
            if ((flags & 4) != 0) { let _ = d.readInt32() } // offset_id_offset - bit 2
        }

        // messages.channelMessages#c776ba4e - 严格匹配 TelegramHarmony
        // 注意：字段顺序是 flags, pts, count, offset_id_offset!
        if (constructor == 0xc776ba4e) {
            isChannelMessages = true
            let flags = d.readInt32()
            r.pts = d.readInt32()  // pts 在 count 前面！
            r.count = d.readInt32()
            if ((flags & 4) != 0) { let _ = d.readInt32() } // offset_id_offset - bit 2
        }

        // messages vector
        var messagesFailed = false
        let msgsVecId = d.readUInt32()
        let msgsCount = d.readInt32()
        Hilog.info(0, "CjTelegram", "[MessagesHistoryResponse] Parsing ${msgsCount} messages...")
        for (_i in 0..Int64(msgsCount)) {
            try {
                r.messages.add(TLMessage.deserializeBoxed(d))
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[MessagesHistoryResponse] Error parsing message ${_i}: ${e}")
                messagesFailed = true
                break
            }
        }

        // 如果消息解析失败，尝试扫描恢复
        if (messagesFailed) {
            r.messagesTruncated = true
            Hilog.info(0, "CjTelegram", "[MessagesHistoryResponse] Messages failed, attempting scan recovery...")
            scanRecoverChatsAndUsers(d, data, r.chats, r.users)
            return r
        }

        // channelMessages 有 topics 向量（必须跳过）
        if (isChannelMessages) {
            let topicsVecId = d.readUInt32()
            if (topicsVecId == TLConstructors.VECTOR) {
                let topicsCount = d.readInt32()
                Hilog.info(0, "CjTelegram", "[MessagesHistoryResponse] Skipping ${topicsCount} topics")
                for (_i in 0..Int64(topicsCount)) {
                    skipForumTopic(d)
                }
            }
        }

        // chats vector
        let chatsVecId = d.readUInt32()
        let chatsCount = d.readInt32()
        Hilog.info(0, "CjTelegram", "[MessagesHistoryResponse] Parsing ${chatsCount} chats...")
        for (_i in 0..Int64(chatsCount)) {
            try {
                r.chats.add(ChatResponse.deserializeBoxed(d))
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[MessagesHistoryResponse] Error parsing chat ${_i}: ${e}")
                break
            }
        }

        // users vector
        let usersVecId = d.readUInt32()
        let usersCount = d.readInt32()
        Hilog.info(0, "CjTelegram", "[MessagesHistoryResponse] Parsing ${usersCount} users...")
        for (_i in 0..Int64(usersCount)) {
            try {
                r.users.add(UserResponse.deserializeBoxed(d))
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[MessagesHistoryResponse] Error parsing user ${_i}: ${e}")
                break
            }
        }

        Hilog.info(0, "CjTelegram", "[MessagesHistoryResponse] Parsing complete: ${r.messages.size} msgs, ${r.chats.size} chats, ${r.users.size} users")
        return r
    }
}


/** inputGroupCall#d8aa840f id+hash / inputGroupCallSlug#fe06823f slug / inputGroupCallInviteMessage#8c10603f msg_id */
func skipBoxedInputGroupCall(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xd8aa840f) { let _ = d.readInt64(); let _ = d.readInt64() }
    else if (ctor == 0xfe06823f) { let _ = d.readString() }
    else if (ctor == 0x8c10603f) { let _ = d.readInt32() }
}

func formatCallDurationText(seconds: Int32): String {
    if (seconds < 60) { return if (seconds == 1) { "1 second" } else { "${seconds} seconds" } }
    let minutes = seconds / 60
    if (minutes < 60) { return if (minutes == 1) { "1 minute" } else { "${minutes} minutes" } }
    let hours = minutes / 60
    return if (hours == 1) { "1 hour" } else { "${hours} hours" }
}
