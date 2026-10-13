package ohos_app_cangjie_entry.core.mtproto

import std.collection.ArrayList

/**
 * TL API 方法定义
 * 
 * 对应 TelegramHarmony 的 TLMethods.ets
 * 每个类继承 TLObject，实现 getConstructorId() 和 serialize()
 */

// ==================== 连接初始化 ====================

public class InitConnection <: TLObject {
    public var apiId: Int32 = Int32(MTProtoConfig.getApiId())
    public var deviceModel: String = initConnectionDeviceModel()
    public var systemVersion: String = initConnectionSystemVersion()
    public var appVersion: String = MTProtoConfig.APP_VERSION
    public var systemLangCode: String = MTProtoConfig.SYSTEM_LANG_CODE
    public var langPack: String = MTProtoConfig.LANG_PACK
    public var langCode: String = MTProtoConfig.LANG_CODE
    public var query: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0xc1cd5ea9 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0) // flags
        serializer.writeInt32(this.apiId)
        serializer.writeString(this.deviceModel)
        serializer.writeString(this.systemVersion)
        serializer.writeString(this.appVersion)
        serializer.writeString(this.systemLangCode)
        serializer.writeString(this.langPack)
        serializer.writeString(this.langCode)
        serializer.writeRawBytes(this.query)
    }
}

public class InvokeWithLayer <: TLObject {
    public var layer: Int32 = MTProtoConfig.LAYER
    public var query: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0xda9b0d0d }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.layer)
        serializer.writeRawBytes(this.query)
    }
}

// ==================== 系统方法 ====================

public class HelpGetConfig <: TLObject {
    public func getConstructorId(): UInt32 { return 0xc4f9186b }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * help.getSupport#9cdf08cd = help.Support
 *
 * The response contains the account-specific support user.  It must not be
 * replaced with a public bot username: Telegram can return a different peer
 * for different accounts/regions.
 */
public class HelpGetSupport <: TLObject {
    public func getConstructorId(): UInt32 { return 0x9cdf08cd }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * help.getDeepLinkInfo#3fedc75f path:string = help.DeepLinkInfo
 */
public class HelpGetDeepLinkInfo <: TLObject {
    public var path: String = ""

    public func getConstructorId(): UInt32 { return 0x3fedc75f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.path)
    }
}

/**
 * help.getPremiumPromo#b81b93d4 = help.PremiumPromo
 * 获取 Premium 推广信息（功能列表、价格、视频）
 */
public class HelpGetPremiumPromo <: TLObject {
    public func getConstructorId(): UInt32 { return 0xb81b93d4 }
    public func serialize(serializer: TLSerializer) {}
}

public class TLPing <: TLObject {
    public var pingId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x7abe77ec }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.pingId)
    }
}

public class UpdatesGetState <: TLObject {
    public func getConstructorId(): UInt32 { return 0xedd4882a }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * updates.getDifference — 获取自指定状态以来的所有更新
 * Constructor: 0x19c2f763 (layer 170+)
 * flags: # pts_total_limit:flags.0?int
 * pts: int
 * date: int  
 * qts: int
 */
public class UpdatesGetDifference <: TLObject {
    public var pts: Int32 = 0
    public var date: Int32 = 0
    public var qts: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x19c2f763 }

    public func serialize(serializer: TLSerializer) {
        let flags: Int32 = 0  // no pts_total_limit
        serializer.writeInt32(flags)
        serializer.writeInt32(this.pts)
        serializer.writeInt32(this.date)
        serializer.writeInt32(this.qts)
    }
}

// ==================== 认证方法 ====================

public class CodeSettings <: TLObject {
    public var allowFlashcall: Bool = false
    public var currentNumber: Bool = false
    public var allowAppHash: Bool = false

    public func getConstructorId(): UInt32 { return 0xad253d78 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.allowFlashcall) { flags = flags | 1 }
        if (this.currentNumber) { flags = flags | 2 }
        if (this.allowAppHash) { flags = flags | 16 }
        serializer.writeInt32(flags)
    }
}

public class AuthSendCode <: TLObject {
    public var phoneNumber: String = ""
    public var apiId: Int32 = Int32(MTProtoConfig.getApiId())
    public var apiHash: String = MTProtoConfig.getApiHash()
    public var settings: CodeSettings = CodeSettings()

    public func getConstructorId(): UInt32 { return 0xa677244f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.phoneNumber)
        serializer.writeInt32(this.apiId)
        serializer.writeString(this.apiHash)
        // Boxed: write constructor ID + fields
        serializer.writeUInt32(this.settings.getConstructorId())
        this.settings.serialize(serializer)
    }
}

public class AuthSignIn <: TLObject {
    public var phoneNumber: String = ""
    public var phoneCodeHash: String = ""
    public var phoneCode: String = ""

    public func getConstructorId(): UInt32 { return 0x8d52a951 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.phoneCode.size > 0) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeString(this.phoneNumber)
        serializer.writeString(this.phoneCodeHash)
        if (this.phoneCode.size > 0) {
            serializer.writeString(this.phoneCode)
        }
    }
}

public class AuthSignUp <: TLObject {
    public var phoneNumber: String = ""
    public var phoneCodeHash: String = ""
    public var firstName: String = ""
    public var lastName: String = ""

    public func getConstructorId(): UInt32 { return 0xaac7b717 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0) // flags
        serializer.writeString(this.phoneNumber)
        serializer.writeString(this.phoneCodeHash)
        serializer.writeString(this.firstName)
        serializer.writeString(this.lastName)
    }
}

public class AuthLogOut <: TLObject {
    public func getConstructorId(): UInt32 { return 0x3e72ba19 }
    public func serialize(serializer: TLSerializer) {}
}

public class AuthExportAuthorization <: TLObject {
    public var dcId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xe5bfffcd }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.dcId)
    }
}

public class AuthImportAuthorization <: TLObject {
    public var id: Int64 = 0
    public var bytes: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0xa57a7dad }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.id)
        serializer.writeBytes(this.bytes)
    }
}

public class AuthResendCode <: TLObject {
    public var phoneNumber: String = ""
    public var phoneCodeHash: String = ""
    public var reason: String = ""  // flags.0?string (Layer 214)

    // auth.resendCode#cae47523 flags:# phone_number:string phone_code_hash:string reason:flags.0?string
    public func getConstructorId(): UInt32 { return 0xcae47523 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.reason.size > 0) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeString(this.phoneNumber)
        serializer.writeString(this.phoneCodeHash)
        if (this.reason.size > 0) { serializer.writeString(this.reason) }
    }
}

// ==================== Auth Transfer (QR Login) — Layer 108+ ====================

/**
 * auth.exportLoginToken#b7e085fe api_id:int api_hash:string except_ids:Vector<long> = auth.LoginToken
 * Generate login token for QR code login
 */
public class AuthExportLoginToken <: TLObject {
    public var apiId: Int32 = Int32(MTProtoConfig.getApiId())
    public var apiHash: String = MTProtoConfig.getApiHash()
    public var exceptIds: ArrayList<Int64> = ArrayList<Int64>()

    public func getConstructorId(): UInt32 { return 0xb7e085fe }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.apiId)
        serializer.writeString(this.apiHash)
        // Vector<long>
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.exceptIds.size))
        for (id in this.exceptIds) {
            serializer.writeInt64(id)
        }
    }
}

/**
 * auth.importLoginToken#95ac5ce4 token:bytes = auth.LoginToken
 * Login using redirected login token (DC mismatch during QR login)
 */
public class AuthImportLoginToken <: TLObject {
    public var token: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0x95ac5ce4 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeBytes(this.token)
    }
}

// ==================== Account Password Reset / Recovery ====================

/**
 * account.declinePasswordReset#4c9409f6 = Bool
 */
public class AccountDeclinePasswordReset <: TLObject {
    public func getConstructorId(): UInt32 { return 0x4c9409f6 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * account.confirmPasswordEmail#8fdf1920 code:string = Bool
 */
public class AccountConfirmPasswordEmail <: TLObject {
    public var code: String = ""

    public func getConstructorId(): UInt32 { return 0x8fdf1920 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.code)
    }
}

/**
 * account.resendPasswordEmail#7a7f2a15 = Bool
 * Resend code to verify 2FA recovery email
 */
public class AccountResendPasswordEmail <: TLObject {
    public func getConstructorId(): UInt32 { return 0x7a7f2a15 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * account.getTmpPassword#449e0b51 password:InputCheckPasswordSRP period:int = account.TmpPassword
 * Get temporary payment password (period in seconds, 60–86400)
 */
public class AccountGetTmpPassword <: TLObject {
    public var password: InputCheckPasswordSRP = InputCheckPasswordSRP()
    public var period: Int32 = 86400

    public func getConstructorId(): UInt32 { return 0x449e0b51 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(this.password.getConstructorId())
        this.password.serialize(serializer)
        serializer.writeInt32(this.period)
    }
}

// ==================== MessagesFilter 类型 ====================

public class InputMessagesFilterEmpty <: TLObject {
    public func getConstructorId(): UInt32 { return 0x57e2f66c }
    public func serialize(serializer: TLSerializer) {}
}

public class InputMessagesFilterPhotos <: TLObject {
    public func getConstructorId(): UInt32 { return 0x9609a51c }
    public func serialize(serializer: TLSerializer) {}
}

public class InputMessagesFilterVideo <: TLObject {
    public func getConstructorId(): UInt32 { return 0x9fc00e65 }
    public func serialize(serializer: TLSerializer) {}
}

public class InputMessagesFilterDocument <: TLObject {
    public func getConstructorId(): UInt32 { return 0x9eddf188 }
    public func serialize(serializer: TLSerializer) {}
}

public class InputMessagesFilterUrl <: TLObject {
    public func getConstructorId(): UInt32 { return 0x7ef0dd87 }
    public func serialize(serializer: TLSerializer) {}
}

public class InputMessagesFilterVoice <: TLObject {
    public func getConstructorId(): UInt32 { return 0x50f5c392 }
    public func serialize(serializer: TLSerializer) {}
}

public class InputMessagesFilterMusic <: TLObject {
    public func getConstructorId(): UInt32 { return 0x3751b49e }
    public func serialize(serializer: TLSerializer) {}
}

public class InputMessagesFilterPhoneCalls <: TLObject {
    public var missed: Bool = false

    public func getConstructorId(): UInt32 { return 0x80c99768 }
    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.missed) { flags = flags | 1 }
        serializer.writeInt32(flags)
    }
}

public class InputMessagesFilterGif <: TLObject {
    public func getConstructorId(): UInt32 { return 0xffc86587 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * P2-099: inputMessagesFilterPhotoVideo#56e9f0e4 — 同时过滤图片和视频
 * iOS ref: Api0.swift dict[1458172132] = parse_inputMessagesFilterPhotoVideo
 * python3 -c "print(hex(1458172132))" → 0x56e9f0e4
 */
public class InputMessagesFilterPhotoVideo <: TLObject {
    public func getConstructorId(): UInt32 { return 0x56e9f0e4 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * inputMessagesFilterRoundVoice —— 语音 + 圆形视频消息（iOS tagMask .voiceOrInstantVideo）。
 * ctor 取自 iOS Api18.swift:937（appendInt32(2054952868) == 0x7a7c17a4）。
 */
public class InputMessagesFilterRoundVoice <: TLObject {
    public func getConstructorId(): UInt32 { return 0x7a7c17a4 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * inputMessagesFilterPinned#1bb00451 — 仅返回置顶消息
 * P2-122: 用于 messages.search 拉取当前对话全部置顶消息
 * iOS ref: Api26.swift parse_inputMessagesFilterPinned
 */
public class InputMessagesFilterPinned <: TLObject {
    public func getConstructorId(): UInt32 { return 0x1bb00451 }
    public func serialize(serializer: TLSerializer) {}
}

// ==================== InputPeer 类型 ====================

public class InputPeerEmpty <: TLObject {
    public func getConstructorId(): UInt32 { return 0x7f3b18ea }
    public func serialize(serializer: TLSerializer) {}
}

public class InputPeerSelf <: TLObject {
    public func getConstructorId(): UInt32 { return 0x7da07ec9 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * inputUserSelf#f7c1b13f = InputUser
 * TL schema verified: 0xf7c1b13f
 * Used as InputUser for operations on the current account user
 */
public class InputUserSelf <: TLObject {
    public func getConstructorId(): UInt32 { return 0xf7c1b13f }
    public func serialize(serializer: TLSerializer) {}
}

public class InputPeerUser <: TLObject {
    public var userId: Int64 = 0
    public var accessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xDDE8A54C }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.userId)
        serializer.writeInt64(this.accessHash)
    }
}

/**
 * inputUser#f21158c6 user_id:long access_hash:long = InputUser;
 * 注意: 与 InputPeerUser 不同！contacts.addContact 等 API 需要 InputUser
 */
public class InputUser <: TLObject {
    public var userId: Int64 = 0
    public var accessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xf21158c6 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.userId)
        serializer.writeInt64(this.accessHash)
    }
}

public class InputPeerChat <: TLObject {
    public var chatId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x35a95cb9 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.chatId)
    }
}

public class InputPeerChannel <: TLObject {
    public var channelId: Int64 = 0
    public var accessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x27bcbbfc }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.channelId)
        serializer.writeInt64(this.accessHash)
    }
}

// ==================== InputChannel 类型 ====================
// Generated by tl_codegen.py from telegram_api.tl (P2-247)

/**
 * inputChannelEmpty#ee8c1e86 = InputChannel;
 * 空 InputChannel，用于占位
 */
public class InputChannelEmpty <: TLObject {
    public func getConstructorId(): UInt32 { return 0xee8c1e86 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * inputChannel#f35aec28 channel_id:long access_hash:long = InputChannel;
 * 频道/超级群引用，供 channels.* 方法使用
 * TL schema Layer 214 (telegram_api.tl:730)
 */
public class InputChannel <: TLObject {
    public var channelId: Int64 = 0
    public var accessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xf35aec28 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.channelId)
        serializer.writeInt64(this.accessHash)
    }
}

// ==================== 消息方法 ====================

public class MessagesGetDialogs <: TLObject {
    public var excludePinned: Bool = false
    public var folderId: Int32 = 0
    public var offsetDate: Int32 = 0
    public var offsetId: Int32 = 0
    public var offsetPeer: TLObject = InputPeerEmpty()
    public var limit: Int32 = 20
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xa0f4cb4f }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.excludePinned) { flags = flags | 1 }
        // folder_id (flags bit1) is unconditionally sent: iOS source
        // (FetchChatList.swift:279 `var flags: Int32 = 1 << 1`) always sets this
        // bit and always passes a concrete folderId (0 for the general/root
        // folder, groupId otherwise) — folder_id=0 is a valid, meaningful value,
        // not "absent". Gating on `folderId != 0` here previously made the main
        // list request (folderId=0) omit folder_id entirely, so the server never
        // filtered by folder and archived chats kept reappearing in the main list.
        flags = flags | 2
        serializer.writeInt32(flags)
        serializer.writeInt32(this.folderId)
        serializer.writeInt32(this.offsetDate)
        serializer.writeInt32(this.offsetId)
        serializer.writeRawBytes(this.offsetPeer.toBytes())
        serializer.writeInt32(this.limit)
        serializer.writeInt64(this.hash)
    }
}

public class MessagesSendMessage <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var message: String = ""
    public var randomId: Int64 = 0
    // flags-gated optional fields (iOS Api42 layer, all default absent)
    public var replyTo: Option<TLObject> = None        // bit0: InputReplyTo
    public var replyMarkup: Option<TLObject> = None    // bit2: ReplyMarkup
    public var entities: Option<ArrayList<TLObject>> = None  // bit3: Vector<MessageEntity>
    public var scheduleDate: Option<Int32> = None      // bit10: int
    public var scheduleRepeatPeriod: Option<Int32> = None    // bit24: int
    public var sendAs: Option<TLObject> = None         // bit13: InputPeer
    public var effect: Option<Int64> = None            // bit18: long
    public var allowPaidStars: Option<Int64> = None    // bit21: long
    // bit5: silent (S2-63 Send Without Sound — iOS sendMessage flags |= 1 << 5)
    public var silent: Bool = false

    // messages.sendMessage#fef48f62 (iOS Api42 layer; python: hex(-17526942 & 0xffffffff) == '0xfef48f62')
    public func getConstructorId(): UInt32 { return 0xfef48f62 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.silent) { flags = flags | (1 << 5) }
        match (this.replyTo) { case Some(_) => flags = flags | (1 << 0); case None => () }
        match (this.replyMarkup) { case Some(_) => flags = flags | (1 << 2); case None => () }
        match (this.entities) { case Some(_) => flags = flags | (1 << 3); case None => () }
        match (this.scheduleDate) { case Some(_) => flags = flags | (1 << 10); case None => () }
        match (this.sendAs) { case Some(_) => flags = flags | (1 << 13); case None => () }
        match (this.effect) { case Some(_) => flags = flags | (1 << 18); case None => () }
        match (this.allowPaidStars) { case Some(_) => flags = flags | (1 << 21); case None => () }
        match (this.scheduleRepeatPeriod) { case Some(_) => flags = flags | (1 << 24); case None => () }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        match (this.replyTo) { case Some(r) => serializer.writeRawBytes(r.toBytes()); case None => () }
        serializer.writeString(this.message)
        serializer.writeInt64(this.randomId)
        match (this.replyMarkup) { case Some(m) => serializer.writeRawBytes(m.toBytes()); case None => () }
        match (this.entities) {
            case Some(ents) =>
                serializer.writeUInt32(0x1cb5c415)
                serializer.writeInt32(Int32(ents.size))
                for (e in ents) { serializer.writeRawBytes(e.toBytes()) }
            case None => ()
        }
        match (this.scheduleDate) { case Some(d) => serializer.writeInt32(d); case None => () }
        match (this.scheduleRepeatPeriod) { case Some(p) => serializer.writeInt32(p); case None => () }
        match (this.sendAs) { case Some(s) => serializer.writeRawBytes(s.toBytes()); case None => () }
        match (this.effect) { case Some(e) => serializer.writeInt64(e); case None => () }
        match (this.allowPaidStars) { case Some(p) => serializer.writeInt64(p); case None => () }
    }
}

// ==================== Message Entity TL 序列化类 ====================
// 对应 iOS Api17.swift 中的 MessageEntity 各子类型
// 字段结构：offset:int length:int (以及 Pre 额外带 language:string, TextUrl 带 url:string)
// 构造器 ID 来自 iOS Api0.swift dict 映射（已与 TLDialogs.cj 反序列化侧一致核对）

// messageEntityBold#bd610bc9 offset:int length:int
public class TLMessageEntityBold <: TLObject {
    public var offset: Int32 = 0
    public var length: Int32 = 0
    public init(offset: Int32, length: Int32) {
        this.offset = offset
        this.length = length
    }
    public func getConstructorId(): UInt32 { return 0xbd610bc9 }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.length)
    }
}

// messageEntityItalic#826f8b60 offset:int length:int
public class TLMessageEntityItalic <: TLObject {
    public var offset: Int32 = 0
    public var length: Int32 = 0
    public init(offset: Int32, length: Int32) {
        this.offset = offset
        this.length = length
    }
    public func getConstructorId(): UInt32 { return 0x826f8b60 }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.length)
    }
}

// messageEntityStrike#bf0693d4 offset:int length:int
public class TLMessageEntityStrike <: TLObject {
    public var offset: Int32 = 0
    public var length: Int32 = 0
    public init(offset: Int32, length: Int32) {
        this.offset = offset
        this.length = length
    }
    public func getConstructorId(): UInt32 { return 0xbf0693d4 }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.length)
    }
}

// messageEntityCode#28a20571 offset:int length:int
public class TLMessageEntityCode <: TLObject {
    public var offset: Int32 = 0
    public var length: Int32 = 0
    public init(offset: Int32, length: Int32) {
        this.offset = offset
        this.length = length
    }
    public func getConstructorId(): UInt32 { return 0x28a20571 }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.length)
    }
}

// messageEntityPre#73924be0 offset:int length:int language:string
public class TLMessageEntityPre <: TLObject {
    public var offset: Int32 = 0
    public var length: Int32 = 0
    public var language: String = ""
    public init(offset: Int32, length: Int32, language: String) {
        this.offset = offset
        this.length = length
        this.language = language
    }
    public func getConstructorId(): UInt32 { return 0x73924be0 }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.length)
        serializer.writeString(this.language)
    }
}

// messageEntityUnderline#9c4e7e8b offset:int length:int
// (iOS Api17.swift: appendInt32(-1672577397) == 0x9c4e7e8b)
public class TLMessageEntityUnderline <: TLObject {
    public var offset: Int32 = 0
    public var length: Int32 = 0
    public init(offset: Int32, length: Int32) {
        this.offset = offset
        this.length = length
    }
    public func getConstructorId(): UInt32 { return 0x9c4e7e8b }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.length)
    }
}

// messageEntityBlockquote#f1ccaaac flags:# collapsed:flags.0?true offset:int length:int
// (iOS Api17.swift: appendInt32(-238245204) == 0xf1ccaaac)
public class TLMessageEntityBlockquote <: TLObject {
    public var offset: Int32 = 0
    public var length: Int32 = 0
    public var collapsed: Bool = false
    public init(offset: Int32, length: Int32) {
        this.offset = offset
        this.length = length
    }
    public func getConstructorId(): UInt32 { return 0xf1ccaaac }
    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.collapsed) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.length)
    }
}

// messageEntitySpoiler#32ca960f offset:int length:int
public class TLMessageEntitySpoiler <: TLObject {
    public var offset: Int32 = 0
    public var length: Int32 = 0
    public init(offset: Int32, length: Int32) {
        this.offset = offset
        this.length = length
    }
    public func getConstructorId(): UInt32 { return 0x32ca960f }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.length)
    }
}

// messageEntityTextUrl#76a6d327 offset:int length:int url:string
public class TLMessageEntityTextUrl <: TLObject {
    public var offset: Int32 = 0
    public var length: Int32 = 0
    public var url: String = ""
    public init(offset: Int32, length: Int32, url: String) {
        this.offset = offset
        this.length = length
        this.url = url
    }
    public func getConstructorId(): UInt32 { return 0x76a6d327 }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.length)
        serializer.writeString(this.url)
    }
}

// messageEntityCustomEmoji#c8cf05f8 offset:int length:int document_id:long
public class TLMessageEntityCustomEmoji <: TLObject {
    public var offset: Int32 = 0
    public var length: Int32 = 0
    public var documentId: Int64 = 0
    public init(offset: Int32, length: Int32, documentId: Int64) {
        this.offset = offset
        this.length = length
        this.documentId = documentId
    }
    public func getConstructorId(): UInt32 { return 0xc8cf05f8 }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.length)
        serializer.writeInt64(this.documentId)
    }
}

public class MessagesGetDialogFilters <: TLObject {
    public func getConstructorId(): UInt32 { return 0xefd48c89 }

    public func serialize(serializer: TLSerializer) {
    }
}

/**
 * messages.getSuggestedDialogFilters#a29cd42c = Vector<DialogFilterSuggested>
 * iOS ref: TelegramApi/Sources/Api42.swift getSuggestedDialogFilters().
 */
public class MessagesGetSuggestedDialogFilters <: TLObject {
    public func getConstructorId(): UInt32 { return 0xa29cd42c }

    public func serialize(serializer: TLSerializer) {
    }
}

public class MessagesGetHistory <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var offsetId: Int32 = 0
    public var offsetDate: Int32 = 0
    public var addOffset: Int32 = 0
    public var limit: Int32 = 20
    public var maxId: Int32 = 0
    public var minId: Int32 = 0
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x4423e6c5 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.offsetId)
        serializer.writeInt32(this.offsetDate)
        serializer.writeInt32(this.addOffset)
        serializer.writeInt32(this.limit)
        serializer.writeInt32(this.maxId)
        serializer.writeInt32(this.minId)
        serializer.writeInt64(this.hash)
    }
}

// ==================== 联系人方法 ====================

public class ContactsGetContacts <: TLObject {
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x5dd69e12 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

public class ContactsResolveUsername <: TLObject {
    public var username: String = ""
    public var referer: String = ""  // flags.0?string (Layer 214)

    // contacts.resolveUsername#725afbbc flags:# username:string referer:flags.0?string
    public func getConstructorId(): UInt32 { return 0x725afbbc }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.referer.size > 0) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeString(this.username)
        if (this.referer.size > 0) { serializer.writeString(this.referer) }
    }
}

// ==================== 联系人导入方法 ====================

/**
 * inputPhoneContact — 用于 contacts.importContacts 的联系人条目
 */
public class InputPhoneContact <: TLObject {
    public var clientId: Int64 = 0
    public var phone: String = ""
    public var firstName: String = ""
    public var lastName: String = ""

    public func getConstructorId(): UInt32 { return 0x6a1dc4be }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags (no optional note field; iOS Api9:988)
        serializer.writeInt64(this.clientId)
        serializer.writeString(this.phone)
        serializer.writeString(this.firstName)
        serializer.writeString(this.lastName)
    }
}

/**
 * contacts.importContacts — 通过手机号导入联系人
 * 返回 contacts.importedContacts
 */
public class ContactsImportContacts <: TLObject {
    public var contacts: ArrayList<InputPhoneContact> = ArrayList<InputPhoneContact>()

    public func getConstructorId(): UInt32 { return 0x2c800be5 }

    public func serialize(serializer: TLSerializer) {
        // Vector<InputPhoneContact>
        serializer.writeUInt32(0x1cb5c415)  // vector constructor
        serializer.writeInt32(Int32(this.contacts.size))
        for (c in this.contacts) {
            serializer.writeUInt32(c.getConstructorId())
            c.serialize(serializer)
        }
    }
}

// ==================== Phase B: 联系人高级方法 ====================

/**
 * contacts.search#05f58d0f (iOS Api42:4929 verified, python: 99978511 == 0x05f58d0f)
 * TL: contacts.search#05f58d0f flags:# q:string limit:int = contacts.Found
 * Field resync vs iOS layer: added flags(Int32) as first serialized field.
 * flags is currently unused (reserved for future optional fields); callers don't need to set it.
 * Old ctor 0x11f812d8 was wrong (stale .tl).
 */
public class ContactsSearch <: TLObject {
    public var flags: Int32 = 0
    public var q: String = ""
    public var limit: Int32 = 20

    public func getConstructorId(): UInt32 { return 0x05f58d0f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.flags)
        serializer.writeString(this.q)
        serializer.writeInt32(this.limit)
    }
}

/**
 * contacts.addContact#d9ba2e54 (iOS Api42:4565 verified, python: -642109868 == 0xd9ba2e54)
 * TL: contacts.addContact#d9ba2e54 flags:# add_phone_privacy_exception:flags.0?true
 *     id:InputUser first_name:string last_name:string phone:string note:flags.1?TextWithEntities = Updates
 * Field resync vs iOS layer:
 *   - Old ctor 0xe8f463d0 was stale.
 *   - flags.0 = add_phone_privacy_exception (Bool flag, default absent)
 *   - flags.1 = note (TextWithEntities, flag-gated, default absent for backward compat)
 *   - note serialized boxed as textWithEntities#751f3146 text:string entities:Vector<MessageEntity>
 * Backward compat: existing callers don't set note or addPhonePrivacyException; flags=0, note absent.
 */
public class ContactsAddContact <: TLObject {
    public var id: TLObject = InputPeerEmpty()  // InputUser (boxed)
    public var firstName: String = ""
    public var lastName: String = ""
    public var phone: String = ""
    public var addPhonePrivacyException: Bool = false  // flags.0
    public var noteText: String = ""                   // flags.1: note.text (if non-empty, note is sent)

    public func getConstructorId(): UInt32 { return 0xd9ba2e54 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.addPhonePrivacyException) { flags = flags | 1 }       // flags.0
        if (this.noteText.size > 0) { flags = flags | (1 << 1) }       // flags.1
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.id.toBytes())
        serializer.writeString(this.firstName)
        serializer.writeString(this.lastName)
        serializer.writeString(this.phone)
        if (this.noteText.size > 0) {
            // textWithEntities#751f3146 text:string entities:Vector<MessageEntity> (tl_codegen verified)
            serializer.writeUInt32(0x751f3146)
            serializer.writeString(this.noteText)
            // entities: empty vector
            serializer.writeUInt32(0x1cb5c415)  // vector ctor
            serializer.writeInt32(0)             // count = 0
        }
    }
}

/**
 * contacts.deleteContacts — 删除联系人
 */
public class ContactsDeleteContacts <: TLObject {
    public var idList: ArrayList<TLObject> = ArrayList<TLObject>()  // Vector<InputUser>

    public func getConstructorId(): UInt32 { return 0x096a0e00 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0x1cb5c415)  // vector
        serializer.writeInt32(Int32(this.idList.size))
        for (id in this.idList) {
            serializer.writeRawBytes(id.toBytes())
        }
    }
}

/**
 * contacts.getTopPeers#973478b6
 * flags:# correspondents:flags.0?true bots_pm:flags.1?true bots_inline:flags.2?true
 * phone_calls:flags.3?true forward_users:flags.4?true forward_chats:flags.5?true
 * groups:flags.10?true channels:flags.15?true bots_app:flags.16?true
 * offset:int limit:int hash:long = contacts.TopPeers
 *
 * P2-157b: 实现真实 getTopPeers RPC。
 * category flags：correspondents(bit 0) 对应最常联系人，是 top-peers UI 最核心的分类。
 * hash: Int64 用于增量（not_modified 时服务端返回 contacts.topPeersNotModified）。
 */
public class ContactsGetTopPeers <: TLObject {
    public var correspondents: Bool = true
    public var botsPm: Bool = false
    public var botsInline: Bool = false
    public var phoneCalls: Bool = false
    public var forwardUsers: Bool = false
    public var forwardChats: Bool = false
    public var groups: Bool = false
    public var channels: Bool = false
    public var botsApp: Bool = false
    public var offset: Int32 = 0
    public var limit: Int32 = 16
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x973478b6 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.correspondents) { flags = flags | 1 }
        if (this.botsPm) { flags = flags | 2 }
        if (this.botsInline) { flags = flags | 4 }
        if (this.phoneCalls) { flags = flags | 8 }
        if (this.forwardUsers) { flags = flags | 16 }
        if (this.forwardChats) { flags = flags | 32 }
        if (this.groups) { flags = flags | 1024 }
        if (this.channels) { flags = flags | 32768 }
        if (this.botsApp) { flags = flags | 65536 }
        serializer.writeInt32(flags)
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.limit)
        serializer.writeInt64(this.hash)
    }
}

/**
 * messages.createChat — 创建群组
 * messages.createChat#92ceddd4 flags:# users:Vector<InputUser> title:string ttl_period:flags.0?int
 */
public class MessagesCreateChat <: TLObject {
    public var users: ArrayList<TLObject> = ArrayList<TLObject>()  // Vector<InputUser>
    public var title: String = ""
    public var ttlPeriod: Option<Int32> = None

    public func getConstructorId(): UInt32 { return 0x92ceddd4 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        match (this.ttlPeriod) {
            case Some(_) => flags = flags | 1
            case None => ()
        }
        serializer.writeInt32(flags)
        // users: Vector<InputUser>
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.users.size))
        for (u in this.users) {
            serializer.writeRawBytes(u.toBytes())
        }
        serializer.writeString(this.title)
        match (this.ttlPeriod) {
            case Some(value) => serializer.writeInt32(value)
            case None => ()
        }
    }
}

/**
 * messages.addChatUser — 添加群组成员
 * messages.addChatUser#cbc6d107 chat_id:long user_id:InputUser fwd_limit:int
 */
public class MessagesAddChatUser <: TLObject {
    public var chatId: Int64 = 0
    public var userId: TLObject = InputPeerEmpty()
    public var fwdLimit: Int32 = 100

    public func getConstructorId(): UInt32 { return 0xcbc6d107 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.chatId)
        serializer.writeRawBytes(this.userId.toBytes())
        serializer.writeInt32(this.fwdLimit)
    }
}

/**
 * messages.deleteChatUser — 移除群组成员
 */
public class MessagesDeleteChatUser <: TLObject {
    public var chatId: Int64 = 0
    public var userId: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0xa2185cab }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags
        serializer.writeInt64(this.chatId)
        serializer.writeRawBytes(this.userId.toBytes())
    }
}

/**
 * messages.deleteChat#5bd0ee50 chat_id:long = Bool
 * 群主解散普通群（iOS ManagedCloudChatRemoveMessagesOperations.swift:301，
 * deleteGloballyIfPossible 时对 CloudGroup 走此方法而非 deleteChatUser(self)）。
 */
public class MessagesDeleteChat <: TLObject {
    public var chatId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x5bd0ee50 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.chatId)
    }
}

/**
 * messages.editChatTitle — 修改群组名称
 */
public class MessagesEditChatTitle <: TLObject {
    public var chatId: Int64 = 0
    public var title: String = ""

    public func getConstructorId(): UInt32 { return 0x73783ffd }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.chatId)
        serializer.writeString(this.title)
    }
}

// ==================== Phase C: 频道方法 ====================

/**
 * channels.createChannel — 创建频道
 * channels.createChannel#91006707 flags:# broadcast:flags.0?true megagroup:flags.1?true
 *   for_import:flags.3?true forum:flags.5?true title:string about:string ...
 */
public class ChannelsCreateChannel <: TLObject {
    public var broadcast: Bool = true
    public var megagroup: Bool = false
    public var title: String = ""
    public var about: String = ""

    public func getConstructorId(): UInt32 { return 0x91006707 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.broadcast) { flags = flags | 1 }
        if (this.megagroup) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeString(this.title)
        serializer.writeString(this.about)
    }
}

/**
 * channels.editTitle — 编辑频道标题
 */
public class ChannelsEditTitle <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var title: String = ""

    public func getConstructorId(): UInt32 { return 0x566decd0 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeString(this.title)
    }
}

// ==================== Phase P6-6: 群组头像上传 ====================

/**
 * inputChatUploadedPhoto#bdcdaec0 — 上传新头像
 * flags:#  file:flags.0?InputFile  video:flags.1?InputFile
 * video_start_ts:flags.2?double  video_emoji_markup:flags.3?VideoSize
 * 
 * 简化版：仅传 file（静态头像图片）
 */
public class InputChatUploadedPhoto <: TLObject {
    public var file: TLObject = InputPeerEmpty()  // InputFile from upload

    public func getConstructorId(): UInt32 { return 0xbdcdaec0 }

    public func serialize(serializer: TLSerializer) {
        // flags: bit 0 = has file
        serializer.writeInt32(1)
        serializer.writeRawBytes(this.file.toBytes())
    }
}

/**
 * channels.editPhoto#f12e57c9 — 修改频道/群组头像
 * channels.editPhoto#f12e57c9 channel:InputChannel photo:InputChatPhoto = Updates
 */
public class ChannelsEditPhoto <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var photo: TLObject = InputPeerEmpty()  // InputChatUploadedPhoto

    public func getConstructorId(): UInt32 { return 0xf12e57c9 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeRawBytes(this.photo.toBytes())
    }
}

/**
 * channels.updateUsername — 设置频道用户名
 * Constructor: 0x3514b3de
 * channel:InputChannel username:string = Bool
 */
public class ChannelsUpdateUsername <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var username: String = ""

    public func getConstructorId(): UInt32 { return 0x3514b3de }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeString(this.username)
    }
}

/**
 * channels.checkUsername#10e6bd2c channel:InputChannel username:string = Bool
 * (iOS Api42.swift:3358 verified, python: 283557164 == 0x10e6bd2c)
 *
 * 频道尚未创建时传 inputChannelEmpty（iOS AddressNames.swift:99 同法）：
 * 建公开频道前先校验用户名，避免频道建好后用户名静默失败。
 * boolTrue = 可用；boolFalse = 已被占用；RPC error USERNAME_INVALID / USERNAME_PURCHASE_AVAILABLE 等。
 */
public class ChannelsCheckUsername <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var username: String = ""

    public func getConstructorId(): UInt32 { return 0x10e6bd2c }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeString(this.username)
    }
}

/**
 * channels.inviteToChannel — 邀请加入频道
 */
public class ChannelsInviteToChannel <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var users: ArrayList<TLObject> = ArrayList<TLObject>()

    public func getConstructorId(): UInt32 { return 0xc9e33d54 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.users.size))
        for (u in this.users) {
            serializer.writeRawBytes(u.toBytes())
        }
    }
}

/**
 * channels.leaveChannel — 退出频道
 */
public class ChannelsLeaveChannel <: TLObject {
    public var channel: TLObject = InputChannelEmpty()

    public func getConstructorId(): UInt32 { return 0xf836aa95 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
    }
}

// ==================== Phase S8: 频道管理增强 ====================

/**
 * channels.deleteChannel — 删除频道/超级群
 * Constructor: 0xc0111fe3
 * channel:InputChannel = Updates
 */
public class ChannelsDeleteChannel <: TLObject {
    public var channel: TLObject = InputChannelEmpty()

    public func getConstructorId(): UInt32 { return 0xc0111fe3 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
    }
}

/**
 * channels.readHistory — 频道已读标记
 */
public class ChannelsReadHistory <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var maxId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xcc104937 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeInt32(this.maxId)
    }
}

// ==================== Phase S2: 群组/频道完整信息 ====================

/**
 * channels.getFullChannel — 获取频道/超级群完整信息
 * Constructor: 0x08736a09
 * channel:InputChannel = messages.ChatFull
 */
public class ChannelsGetFullChannel <: TLObject {
    public var channel: TLObject = InputChannelEmpty()  // InputChannel

    public func getConstructorId(): UInt32 { return 0x08736a09 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
    }
}

/**
 * messages.getFullChat — 获取基础群组完整信息
 * Constructor: 0xaeb00b34
 * chat_id:long = messages.ChatFull
 */
public class MessagesGetFullChat <: TLObject {
    public var chatId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xaeb00b34 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.chatId)
    }
}

// ==================== Phase S6: 编辑群组信息 ====================

/**
 * messages.editChatAbout — 修改群组/频道描述
 * Constructor: 0xdef60797
 * peer:InputPeer about:string = Bool
 */
public class MessagesEditChatAbout <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var about: String = ""

    public func getConstructorId(): UInt32 { return 0xdef60797 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.about)
    }
}

// ==================== Phase S3: 管理员管理 ====================

/**
 * ChatAdminRights — 管理员权限标志
 * Constructor: 0x5fb224d5
 * TL schema: chatAdminRights#5fb224d5 flags:# = ChatAdminRights
 * iOS ref: Api4.swift parse_chatAdminRights — single flags:Int32
 *
 * 各 bit 对应的权限（TL schema verified vs telegram_api.tl + iOS Api4.swift）：
 * bit 0:  change_info    — 修改群组信息
 * bit 1:  post_messages  — 发送消息（频道）
 * bit 2:  edit_messages  — 编辑消息（频道）
 * bit 3:  delete_messages — 删除消息
 * bit 4:  ban_users      — 封禁用户
 * bit 5:  invite_users   — 邀请用户
 * bit 7:  pin_messages   — 置顶消息
 * bit 9:  add_admins     — 添加管理员
 * bit 10: anonymous      — 匿名发言（P2-135 verified: bit 10 = 0x0400）
 * bit 11: manage_call    — 管理通话
 * bit 12: other          — 其他权限
 * bit 13: manage_topics  — 管理话题
 * bit 14: post_stories   — 发布故事（P2-135 added: bit 14 = 0x4000）
 * bit 15: edit_stories   — 编辑故事（P2-135 added: bit 15 = 0x8000）
 * bit 16: delete_stories — 删除故事（P2-135 added: bit 16 = 0x10000）
 *
 * flags 参考值（Python hex 验证，0 手算）：
 *   anonymous   = 1 << 10 = 1024  = 0x0400
 *   post_stories = 1 << 14 = 16384 = 0x4000
 *   edit_stories = 1 << 15 = 32768 = 0x8000
 *   delete_stories = 1 << 16 = 65536 = 0x10000
 */
public class ChatAdminRights <: TLObject {
    public var flags: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x5fb224d5 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.flags)
    }
}

/**
 * channels.editAdmin#9a98ad68 (iOS Api42:3500 verified, python: -1701270168 == 0x9a98ad68)
 * TL: channels.editAdmin#9a98ad68 flags:# channel:InputChannel user_id:InputUser
 *     admin_rights:ChatAdminRights rank:flags.0?string = Updates
 * Field resync vs iOS layer:
 *   - Old ctor 0xd33c8902 was stale.
 *   - flags added as first serialized field.
 *   - rank is now flag-gated at flags.0 (only serialized when non-empty).
 *   - ChatAdminRights stories flags (P2-135: bits 14/15/16) are in ChatAdminRights type — untouched.
 * Backward compat: callers setting req.rank = "" → flags.0=0 → rank absent (correct).
 *                  callers setting req.rank = "Title" → flags.0=1 → rank serialized.
 */
public class ChannelsEditAdmin <: TLObject {
    public var channel: TLObject = InputChannelEmpty()  // InputChannel (boxed)
    public var userId: TLObject = InputPeerEmpty()      // InputUser (boxed)
    public var adminRights: ChatAdminRights = ChatAdminRights()
    public var rank: String = ""  // 管理员头衔 (flag-gated flags.0)

    public func getConstructorId(): UInt32 { return 0x9a98ad68 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.rank.size > 0) { flags = flags | 1 }  // flags.0: rank present
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeRawBytes(this.userId.toBytes())
        serializer.writeRawBytes(this.adminRights.toBytes())
        if (this.rank.size > 0) {
            serializer.writeString(this.rank)
        }
    }
}

/**
 * channels.editCreator — 所有权转移（将频道所有者转让给另一用户）
 * Constructor: 0x8f38cd1f
 * TL: channels.editCreator#8f38cd1f channel:InputChannel user_id:InputUser
 *     password:InputCheckPasswordSRP = Updates
 *
 * iOS ref: telegram_api.tl line 2496
 *   channels.editCreator#8f38cd1f channel:InputChannel user_id:InputUser password:InputCheckPasswordSRP = Updates
 * ctor verified (python): 0x8f38cd1f = 2402864415
 *   struct.unpack('>i', struct.pack('>I', 0x8f38cd1f))[0] = -1892102881
 *   iOS big-endian signed int32 = -1892102881 (same as editBanned pattern)
 *
 * 序列化顺序（均 boxed）:
 *   1. InputChannel (boxed: ctor + channelId + accessHash)
 *   2. InputUser    (boxed: ctor + userId + accessHash)
 *   3. InputCheckPasswordSRP (boxed: ctor + srpId + A + M1)
 *
 * 响应: Updates 四变体 (0x74ae4240 / 0x725b04c3 / 0x78d4dec1 / 0xe317af7e)
 * SRP 计算由上层（调用方）完成并传入已构造的 InputCheckPasswordSRP 对象。
 */
public class ChannelsEditCreator <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var userId: TLObject = InputPeerEmpty()
    public var password: InputCheckPasswordSRP = InputCheckPasswordSRP()

    public func getConstructorId(): UInt32 { return 0x8f38cd1f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeRawBytes(this.userId.toBytes())
        serializer.writeUInt32(this.password.getConstructorId())
        this.password.serialize(serializer)
    }
}

// ==================== Phase S4: 封禁管理 ====================

/**
 * ChatBannedRights — 用户被禁止的权限
 * Constructor: 0x9f120418
 * 
 * 设置对应 bit 为 true 表示 **禁止** 该操作
 * bit 0:  view_messages    — 禁止查看消息
 * bit 1:  send_messages    — 禁止发送消息
 * bit 2:  send_media       — 禁止发送媒体
 * bit 3:  send_stickers    — 禁止发送贴纸
 * bit 4:  send_gifs        — 禁止发送 GIF
 * bit 5:  send_games       — 禁止发送游戏
 * bit 6:  send_inline      — 禁止使用内联机器人
 * bit 7:  embed_links      — 禁止嵌入链接
 * bit 8:  send_polls       — 禁止发送投票
 * bit 10: change_info      — 禁止修改群信息
 * bit 15: invite_users     — 禁止邀请用户
 * bit 17: pin_messages     — 禁止置顶消息
 * bit 18: manage_topics    — 禁止管理话题
 * until_date: int (0 = 永久)
 */
public class ChatBannedRights <: TLObject {
    public var flags: Int32 = 0
    public var untilDate: Int32 = 0  // 0 = 永久封禁

    public func getConstructorId(): UInt32 { return 0x9f120418 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.flags)
        serializer.writeInt32(this.untilDate)
    }
}

/**
 * channels.editBanned — 封禁/解封成员
 * Constructor: 0x96e6cd81
 *
 * channel:InputChannel participant:InputPeer banned_rights:ChatBannedRights
 *
 * 要完全解封：传入 flags=0 的 ChatBannedRights
 * 要踢出群组：设置 view_messages=true (bit 0)
 */
public class ChannelsEditBanned <: TLObject {
    public var channel: TLObject = InputChannelEmpty()  // InputChannel
    public var participant: TLObject = InputPeerEmpty()  // InputPeer
    public var bannedRights: ChatBannedRights = ChatBannedRights()

    public func getConstructorId(): UInt32 { return 0x96e6cd81 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeRawBytes(this.participant.toBytes())
        serializer.writeRawBytes(this.bannedRights.toBytes())
    }
}

/**
 * channels.getParticipants — 获取频道成员列表
 */
/**
 * channels.getParticipants — 获取频道成员列表
 * 
 * Phase S7: 支持多种过滤器
 * - 0xde3f3c79 channelParticipantsRecent (无参数)
 * - 0xb4608969 channelParticipantsAdmins (无参数)
 * - 0xb0d1865b channelParticipantsBots (无参数)
 * - 0xa3b54985 channelParticipantsKicked q:string
 * - 0x0702a40e channelParticipantsSearch q:string
 * - 0xbb6ae88d channelParticipantsBanned q:string
 */
public class ChannelsGetParticipants <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var filter: UInt32 = 0xde3f3c79  // channelParticipantsRecent
    public var filterQuery: String = ""  // 用于 search/kicked/banned 过滤器
    public var offset: Int32 = 0
    public var limit: Int32 = 100
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x77ced9d0 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        // filter (boxed constructor, per iOS Api4.swift ChannelParticipantsFilter.serialize)
        serializer.writeUInt32(this.filter)
        // Filters that carry q:string (iOS Api4.swift verified, 0 手算):
        //   0x0656ac4b channelParticipantsSearch  (iOS signed=106343499)
        //   0xa3b54985 channelParticipantsKicked  (iOS signed=-1548400251)
        //   0x1427a5e1 channelParticipantsBanned  (iOS signed=338142689)
        //   0xbb6ae88d channelParticipantsContacts (iOS signed=-1150621555)
        //   0x0702a40e legacy search ctor (older TL layer, kept for compat)
        let filterNeedsQuery = (
            this.filter == 0x0656ac4b ||
            this.filter == 0xa3b54985 ||
            this.filter == 0x1427a5e1 ||
            this.filter == 0xbb6ae88d ||
            this.filter == 0x0702a40e
        )
        if (filterNeedsQuery) {
            serializer.writeString(this.filterQuery)
        }
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.limit)
        serializer.writeInt64(this.hash)
    }
}

// ==================== 用户方法 ====================

/**
 * users.getUsers#0d91a548 id:Vector<InputUser> = Vector<User>
 *
 * iOS Telegram Api42.swift uses this method with inputUserSelf to hydrate the
 * current account peer.  Unlike users.getFullUser, its response is a plain
 * Vector<User>, so the normal UserResponse parser can retain profile-photo
 * metadata without parsing the much larger UserFull object first.
 */
public class UsersGetUsers <: TLObject {
    public var ids: ArrayList<TLObject> = ArrayList<TLObject>()

    public func getConstructorId(): UInt32 { return 0x0d91a548 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.ids.size))
        for (id in this.ids) {
            serializer.writeRawBytes(id.toBytes())
        }
    }
}

public class UsersGetFullUser <: TLObject {
    public var id: TLObject = InputPeerSelf()

    public func getConstructorId(): UInt32 { return 0xb60f5918 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.id.toBytes())
    }
}

public class MessagesReadHistory <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var maxId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x0e306d3a }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.maxId)
    }
}

// ==================== Phase D: 文件上传/下载方法 ====================

/**
 * upload.saveFilePart — 上传文件块
 */
public class UploadSaveFilePart <: TLObject {
    public var fileId: Int64 = 0
    public var filePart: Int32 = 0
    public var bytes: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0xb304a621 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.fileId)
        serializer.writeInt32(this.filePart)
        serializer.writeBytes(this.bytes)
    }
}

/**
 * upload.saveBigFilePart — 上传大文件块
 */
public class UploadSaveBigFilePart <: TLObject {
    public var fileId: Int64 = 0
    public var filePart: Int32 = 0
    public var fileTotalParts: Int32 = 0
    public var bytes: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0xde7b673d }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.fileId)
        serializer.writeInt32(this.filePart)
        serializer.writeInt32(this.fileTotalParts)
        serializer.writeBytes(this.bytes)
    }
}

/**
 * upload.getFile — 下载文件
 */
public class UploadGetFile <: TLObject {
    public var precise: Bool = false
    public var cdnSupported: Bool = false
    public var location: TLObject = InputPeerEmpty()  // InputFileLocation
    public var offset: Int64 = 0
    public var limit: Int32 = 524288  // 512KB default

    public func getConstructorId(): UInt32 { return 0xbe5335be }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.precise) { flags = flags | 1 }
        if (this.cdnSupported) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.location.toBytes())
        serializer.writeInt64(this.offset)
        serializer.writeInt32(this.limit)
    }
}

/**
 * inputDocumentFileLocation — 文档文件位置
 */
public class InputDocumentFileLocation <: TLObject {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var thumbSize: String = ""

    public func getConstructorId(): UInt32 { return 0xbad07584 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.id)
        serializer.writeInt64(this.accessHash)
        serializer.writeBytes(this.fileReference)
        serializer.writeString(this.thumbSize)
    }
}

/**
 * inputPhotoFileLocation — 图片文件位置
 */
public class InputPhotoFileLocation <: TLObject {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var thumbSize: String = ""

    public func getConstructorId(): UInt32 { return 0x40181ffe }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.id)
        serializer.writeInt64(this.accessHash)
        serializer.writeBytes(this.fileReference)
        serializer.writeString(this.thumbSize)
    }
}

/**
 * inputPeerPhotoFileLocation — 用户/群组头像位置
 */
public class InputPeerPhotoFileLocation <: TLObject {
    public var big: Bool = false
    public var peer: TLObject = InputPeerEmpty()
    public var photoId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x37257e99 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.big) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt64(this.photoId)
    }
}

/**
 * messages.sendMedia — 发送媒体消息
 *
 * iOS ref: Api42.swift L9405 buffer.appendInt32(53536639)
 * ctor verified (python): 53536639 & 0xFFFFFFFF = 0x0330e77f
 * TL schema cross-check: messages.sendMedia#0330e77f (Layer 214) ✓
 *
 * 字段布局 (iOS Api42.swift L9403-9444):
 *   flags:# peer:InputPeer replyTo:flags.0?InputReplyTo media:InputMedia
 *   message:string randomId:long replyMarkup:flags.2?ReplyMarkup
 *   entities:flags.3?Vector<MessageEntity> scheduleDate:flags.10?int
 *   (简化实现：仅序列化 peer/replyTo/media/message/randomId，flags=0或1)
 * 响应: Updates (四变体: 0x74ae4240/0x725b04c3/0x78d4dec1/0xe317af7e)
 *       或 updateShortSentMessage#9015e101 (iOS Api30.swift L219: appendInt32(-1877614335))
 */
public class MessagesSendMedia <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var media: TLObject = InputPeerEmpty()  // InputMedia
    public var message: String = ""
    public var randomId: Int64 = 0
    public var replyToMsgId: Int32 = 0
    /** silent:flags.5?true —— 静默发送（对方不响铃）。 */
    public var silent: Bool = false
    /** scheduleDate:flags.10?int —— 定时发送的 Unix 时间戳。 */
    public var scheduleDate: Option<Int32> = None

    public func getConstructorId(): UInt32 { return 0x0330e77f }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.replyToMsgId > 0) { flags = flags | 1 }
        if (this.silent) { flags = flags | (1 << 5) }
        match (this.scheduleDate) { case Some(_) => flags = flags | (1 << 10); case None => () }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        if (this.replyToMsgId > 0) {
            serializer.writeUInt32(0x3bd4b7c2)  // inputReplyToMessage; iOS Api13.swift L131: appendInt32(1003796418); python: hex(1003796418 & 0xffffffff) == 0x3bd4b7c2
            serializer.writeInt32(0)
            serializer.writeInt32(this.replyToMsgId)
        }
        serializer.writeRawBytes(this.media.toBytes())
        serializer.writeString(this.message)
        serializer.writeInt64(this.randomId)
        // scheduleDate 在 replyMarkup(flags.2) / entities(flags.3) 之后；
        // 这两个字段本实现不发，所以直接跟在 randomId 后面即可。
        match (this.scheduleDate) { case Some(d) => serializer.writeInt32(d); case None => () }
    }
}

/**
 * inputMediaUploadedPhoto — 上传图片媒体
 */
public class InputMediaUploadedPhoto <: TLObject {
    public var file: TLObject = InputPeerEmpty()  // InputFile
    // Fix4: iOS inputMediaUploadedPhoto#7d8375da (Api11.swift) layout —
    //   flags:# file:InputFile stickers:flags.0?Vector<InputDocument>
    //   ttl_seconds:flags.1?int video:flags.3?InputDocument
    // 该层构造子无 spoiler 字段（uploaded photo 不携带 spoiler）；spoiler 仅占位，不参与序列化。
    public var ttlSeconds: Int32 = 0    // flags.1: 阅后即焚秒数（0 = 不设置）
    public var spoiler: Bool = false    // 占位：该 ctor 无对应 flag 位

    public func getConstructorId(): UInt32 { return 0x7d8375da }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.ttlSeconds > 0) { flags = flags | 2 }  // bit1: ttl_seconds
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.file.toBytes())
        // stickers (flags.0) 暂不支持
        if (this.ttlSeconds > 0) {
            serializer.writeInt32(this.ttlSeconds)
        }
        // video (flags.3) 暂不支持
    }
}

/**
 * inputMediaUploadedDocument — 上传文档媒体
 * inputMediaUploadedDocument#37c9330 (Layer 214 correct ID)
 */
public class InputMediaUploadedDocument <: TLObject {
    public var file: TLObject = InputPeerEmpty()  // InputFile
    public var mimeType: String = "application/octet-stream"
    public var attributes: ArrayList<TLObject> = ArrayList<TLObject>()
    // Fix4: iOS inputMediaUploadedDocument#037c9330 (Api11.swift) layout —
    //   flags:# file:InputFile thumb:flags.2?InputFile mime_type:string
    //   attributes:Vector<DocumentAttribute> stickers:flags.0?Vector<InputDocument>
    //   video_cover:flags.6?InputPhoto video_timestamp:flags.7?int ttl_seconds:flags.1?int
    // 该层构造子无 spoiler 字段；spoiler 仅占位，不参与序列化。
    public var thumbFile: Option<TLObject> = None  // flags.2: 缩略图 InputFile
    public var ttlSeconds: Int32 = 0               // flags.1: 阅后即焚秒数
    public var spoiler: Bool = false               // 占位：该 ctor 无对应 flag 位

    public func getConstructorId(): UInt32 { return 0x037c9330 }

    public func serialize(serializer: TLSerializer) {
        let hasThumb = match (this.thumbFile) {
            case Some(_) => true
            case None => false
        }
        var flags: Int32 = 0
        if (hasThumb) { flags = flags | 4 }             // bit2: thumb
        if (this.ttlSeconds > 0) { flags = flags | 2 }  // bit1: ttl_seconds
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.file.toBytes())
        // thumb (flags.2) — 顺序在 file 之后、mime_type 之前
        if (hasThumb) {
            match (this.thumbFile) {
                case Some(tf) => serializer.writeRawBytes(tf.toBytes())
                case None => ()
            }
        }
        serializer.writeString(this.mimeType)
        // attributes: Vector<DocumentAttribute>
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.attributes.size))
        for (attr in this.attributes) {
            serializer.writeRawBytes(attr.toBytes())
        }
        // stickers (flags.0) / video_cover (flags.6) / video_timestamp (flags.7) 暂不支持
        // ttl_seconds (flags.1) — 顺序在最后
        if (this.ttlSeconds > 0) {
            serializer.writeInt32(this.ttlSeconds)
        }
    }
}

/**
 * inputFile — 已上传文件引用
 */
public class InputFileUploaded <: TLObject {
    public var id: Int64 = 0
    public var parts: Int32 = 0
    public var name: String = ""
    public var md5Checksum: String = ""

    public func getConstructorId(): UInt32 { return 0xf52ff27f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.id)
        serializer.writeInt32(this.parts)
        serializer.writeString(this.name)
        serializer.writeString(this.md5Checksum)
    }
}

/**
 * inputFileBig — 已上传大文件引用
 */
public class InputFileBig <: TLObject {
    public var id: Int64 = 0
    public var parts: Int32 = 0
    public var name: String = ""

    public func getConstructorId(): UInt32 { return 0xfa4f0bb5 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.id)
        serializer.writeInt32(this.parts)
        serializer.writeString(this.name)
    }
}

/**
 * documentAttributeFilename — 文件名属性
 */
public class DocumentAttributeFilenameTL <: TLObject {
    public var fileName: String = ""

    public func getConstructorId(): UInt32 { return 0x15590068 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.fileName)
    }
}

/**
 * Phase P6-1: documentAttributeVideo — 视频属性
 * documentAttributeVideo#43c57c48 (Layer 214 correct ID)
 * flags:# round_message:flags.0?true supports_streaming:flags.1?true
 * nosound:flags.3?true duration:double w:int h:int
 * preload_prefix_size:flags.2?int video_start_ts:flags.4?double video_codec:flags.5?string
 *
 * 简化序列化：仅使用 duration/w/h + supports_streaming
 */
public class DocumentAttributeVideo <: TLObject {
    public var roundMessage: Bool = false
    public var supportsStreaming: Bool = true
    public var duration: Float64 = 0.0
    public var w: Int32 = 0
    public var h: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x43c57c48 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.roundMessage) { flags = flags | 1 }
        if (this.supportsStreaming) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeDouble(this.duration)
        serializer.writeInt32(this.w)
        serializer.writeInt32(this.h)
    }
}

/**
 * documentAttributeAudio — 音频属性
 * Constructor: 0x9852f9c6
 * flags:# voice:flags.10?true duration:int title:flags.0?string
 *   performer:flags.1?string waveform:flags.2?bytes
 */
public class DocumentAttributeAudioTL <: TLObject {
    public var voice: Bool = false
    public var duration: Int32 = 0
    public var title: String = ""
    public var performer: String = ""
    public var waveform: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0x9852f9c6 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.voice) { flags = flags | 1024 }
        if (this.title.size > 0) { flags = flags | 1 }
        if (this.performer.size > 0) { flags = flags | 2 }
        if (this.waveform.size > 0) { flags = flags | 4 }
        serializer.writeInt32(flags)
        serializer.writeInt32(this.duration)
        if (this.title.size > 0) { serializer.writeString(this.title) }
        if (this.performer.size > 0) { serializer.writeString(this.performer) }
        if (this.waveform.size > 0) { serializer.writeBytes(this.waveform) }
    }
}

// ==================== Phase A4: 消息高级操作方法 ====================

/**
 * messages.deleteMessages — 删除消息
 * 对应 TelegramHarmony TLMethods.ets: MessagesDeleteMessages
 */
public class MessagesDeleteMessages <: TLObject {
    public var revoke: Bool = true   // true = 双向删除（对方也删除）
    public var idList: ArrayList<Int32> = ArrayList<Int32>()

    public func getConstructorId(): UInt32 { return 0xe58e95d2 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.revoke) { flags = flags | 1 }
        serializer.writeInt32(flags)
        // Vector<int>
        serializer.writeUInt32(0x1cb5c415)  // vector constructor
        serializer.writeInt32(Int32(this.idList.size))
        for (id in this.idList) {
            serializer.writeInt32(id)
        }
    }
}

/**
 * Phase P1-2: inputDialogPeer — 对话 Peer 封装
 * Constructor: 0xfcaafeb7
 * peer:InputPeer
 */
public class InputDialogPeer <: TLObject {
    public var peer: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0xfcaafeb7 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

/**
 * Phase P1-2: messages.toggleDialogPin — 置顶/取消置顶对话
 * Constructor: 0xa731e257
 * flags:# pinned:flags.0?true peer:InputDialogPeer
 */
public class MessagesToggleDialogPin <: TLObject {
    public var pinned: Bool = true
    public var peer: TLObject = InputDialogPeer()

    public func getConstructorId(): UInt32 { return 0xa731e257 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.pinned) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

/**
 * messages.reorderPinnedDialogs —— 按新顺序提交置顶会话。
 * ctor 取自 iOS Api42.swift:8939-8948（appendInt32(991616823) == 0x3b1adf37）：
 *   flags:# force:flags.0?true folder_id:int order:Vector<InputDialogPeer> = Bool
 * iOS ManagedSynchronizePinnedChatsOperations.swift:280 固定发 flags 1<<0（force）。
 */
public class MessagesReorderPinnedDialogs <: TLObject {
    public var folderId: Int32 = 0
    public var order: ArrayList<TLObject> = ArrayList<TLObject>()

    public func getConstructorId(): UInt32 { return 0x3b1adf37 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(1)
        serializer.writeInt32(this.folderId)
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.order.size))
        for (item in this.order) {
            serializer.writeRawBytes(item.toBytes())
        }
    }
}

/**
 * P2-104: messages.markDialogUnread — 标记/取消标记对话未读
 * Constructor: 0x8c5006f8
 * ctor verified: python3 -c "print(hex(-1940912392 & 0xFFFFFFFF))" -> 0x8c5006f8
 * iOS Api42.swift:8350 buffer.appendInt32(-1940912392)
 *
 * flags:#
 * unread:flags.0?true  (flag bit 0 = mark as unread; 0 = mark as read)
 * peer:InputDialogPeer
 */
public class MessagesMarkDialogUnread <: TLObject {
    public var unread: Bool = true
    public var peer: TLObject = InputDialogPeer()

    public func getConstructorId(): UInt32 { return 0x8c5006f8 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.unread) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

/**
 * Phase P1-1: messages.deleteHistory — 删除对话历史
 * Constructor: 0xb08f922a
 * flags:# just_clear:flags.0?true revoke:flags.1?true peer:InputPeer max_id:int
 * min_date:flags.2?int max_date:flags.3?int
 */
public class MessagesDeleteHistory <: TLObject {
    public var justClear: Bool = false
    public var revoke: Bool = true
    public var peer: TLObject = InputPeerEmpty()
    public var maxId: Int32 = 0
    public var minDate: Int32 = 0
    public var maxDate: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xb08f922a }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.justClear) { flags = flags | 1 }
        if (this.revoke) { flags = flags | 2 }
        if (this.minDate != 0) { flags = flags | 4 }
        if (this.maxDate != 0) { flags = flags | 8 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.maxId)
        if (this.minDate != 0) {
            serializer.writeInt32(this.minDate)
        }
        if (this.maxDate != 0) {
            serializer.writeInt32(this.maxDate)
        }
    }
}

/**
 * channels.deleteHistory — 清除频道/超级群历史
 *
 * iOS TelegramApi/Api42.swift:
 *   channels.deleteHistory#9baa9647 flags:# for_everyone:flags.0?true
 *   channel:InputChannel max_id:int = Updates
 */
public class ChannelsDeleteHistory <: TLObject {
    public var forEveryone: Bool = false
    public var channel: TLObject = InputChannelEmpty()
    public var maxId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x9baa9647 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.forEveryone) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeInt32(this.maxId)
    }
}

/**
 * channels.deleteMessages — 删除频道消息
 */
public class ChannelsDeleteMessages <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var idList: ArrayList<Int32> = ArrayList<Int32>()

    public func getConstructorId(): UInt32 { return 0x84c1fd4e }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.idList.size))
        for (id in this.idList) {
            serializer.writeInt32(id)
        }
    }
}

/**
 * messages.editMessage — 编辑消息
 * 对应 TelegramHarmony TLMethods.ets: MessagesEditMessage
 */
public class MessagesEditMessage <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var id: Int32 = 0
    public var message: String = ""
    // P2-150: closePoll support — when true, sends inputMediaPoll(closed=true) as media
    public var closePoll: Bool = false
    // P2-150b: stopLiveLocation support — when true, sends inputMediaGeoLive(stopped=true) as media
    public var stopLiveLocation: Bool = false
    // flags-gated optional fields (iOS Api42 layer, all default absent)
    public var replyMarkup: Option<TLObject> = None    // bit2: ReplyMarkup
    public var entities: Option<ArrayList<TLObject>> = None  // bit3: Vector<MessageEntity>
    public var scheduleDate: Option<Int32> = None      // bit15: int
    public var scheduleRepeatPeriod: Option<Int32> = None    // bit18: int
    public var quickReplyShortcutId: Option<Int32> = None    // bit17: int

    // messages.editMessage#b106e66c (iOS Api42 layer; python: hex(-1324947860 & 0xffffffff) == '0xb106e66c')
    public func getConstructorId(): UInt32 { return 0xb106e66c }

    public func serialize(serializer: TLSerializer) {
        let hasMedia = this.closePoll || this.stopLiveLocation
        var flags: Int32 = 0
        match (this.replyMarkup) { case Some(_) => flags = flags | (1 << 2); case None => () }
        match (this.entities) { case Some(_) => flags = flags | (1 << 3); case None => () }
        if (this.message.size > 0) { flags = flags | (1 << 11) }  // bit11: message
        if (hasMedia) { flags = flags | (1 << 14) }               // bit14: media
        match (this.scheduleDate) { case Some(_) => flags = flags | (1 << 15); case None => () }
        match (this.quickReplyShortcutId) { case Some(_) => flags = flags | (1 << 17); case None => () }
        match (this.scheduleRepeatPeriod) { case Some(_) => flags = flags | (1 << 18); case None => () }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.id)
        if (this.message.size > 0) {
            serializer.writeString(this.message)
        }
        if (this.closePoll) {
            // inputMediaPoll#883a4108 flags:# poll:Poll = InputMedia
            serializer.writeUInt32(0x883a4108)  // inputMediaPoll constructor (iOS Api11:463; was 0x0f94e5f1 — .tl lag)
            serializer.writeInt32(0)             // inputMediaPoll.flags (no optional fields set)
            // poll#966e2dbf id:long flags:# question:TextWithEntities answers:Vector<PollAnswer> ... hash:long
            serializer.writeUInt32(0x966e2dbf)   // poll constructor (iOS Api21:719; was 0x58747131 — .tl lag)
            serializer.writeInt64(0)             // poll.id (edit: server uses existing)
            serializer.writeInt32(1)             // poll.flags: closed=bit0
            // question = textWithEntities#751f3146 text:string entities:Vector<MessageEntity>
            serializer.writeUInt32(0x751f3146)   // textWithEntities constructor
            serializer.writeString("")           // text (close-only edit: empty)
            serializer.writeUInt32(0x1cb5c415)  // entities Vector header
            serializer.writeInt32(0)             // 0 entities
            // answers = Vector<PollAnswer>
            serializer.writeUInt32(0x1cb5c415)  // answers Vector header
            serializer.writeInt32(0)             // 0 answers (preserve existing)
            serializer.writeInt64(0)             // poll.hash (required per iOS Api21; always present)
        } else if (this.stopLiveLocation) {
            // inputMediaGeoLive#971fa843 flags:# stopped:flags.0?true geo_point:InputGeoPoint (tl_codegen verified)
            // For stopping: flags.0 = stopped = true; geo_point is still required per TL schema
            serializer.writeUInt32(0x971fa843)   // inputMediaGeoLive constructor
            serializer.writeInt32(1)             // flags: bit0 = stopped
            // geo_point: inputGeoPointEmpty#e4c123d6 (no lat/long needed for stop)
            serializer.writeUInt32(0xe4c123d6)   // inputGeoPointEmpty constructor
        }
        match (this.replyMarkup) { case Some(m) => serializer.writeRawBytes(m.toBytes()); case None => () }
        match (this.entities) {
            case Some(ents) =>
                serializer.writeUInt32(0x1cb5c415)
                serializer.writeInt32(Int32(ents.size))
                for (e in ents) { serializer.writeRawBytes(e.toBytes()) }
            case None => ()
        }
        match (this.scheduleDate) { case Some(d) => serializer.writeInt32(d); case None => () }
        match (this.scheduleRepeatPeriod) { case Some(p) => serializer.writeInt32(p); case None => () }
        match (this.quickReplyShortcutId) { case Some(q) => serializer.writeInt32(q); case None => () }
    }
}

/**
 * messages.forwardMessages — 转发消息
 * messages.forwardMessages#13704a7c (iOS Api42 layer; python: hex(326126204 & 0xffffffff) == '0x13704a7c')
 */
public class MessagesForwardMessages <: TLObject {
    public var fromPeer: TLObject = InputPeerEmpty()
    public var toPeer: TLObject = InputPeerEmpty()
    public var idList: ArrayList<Int32> = ArrayList<Int32>()
    public var randomIds: ArrayList<Int64> = ArrayList<Int64>()
    // flags-gated optional fields (iOS Api42 layer, all default absent)
    // TL: messages.forwardMessages#bb9fa475 silent:flags.5?true background:flags.6?true
    // iOS PendingMessageManager.swift:1246 — flags |= Int32(1 << 5) for NotificationInfoMessageAttribute.muted
    public var silent: Bool = false                    // bit5: silent forward (no notification)
    public var topMsgId: Option<Int32> = None          // bit9: int
    public var scheduleDate: Option<Int32> = None      // bit10: int
    // P2-115: drop_author (bit11) — hide sender name in forwarded message
    // iOS PendingMessageManager.swift:1280 — flags |= (1 << 11) when hideSendersNames
    public var dropAuthor: Bool = false                // bit11: true = hide sender name
    // P2-115: drop_media_captions (bit12) — drop media captions on forward
    // iOS PendingMessageManager.swift:1283 — flags |= (1 << 12) when hideCaptions
    public var dropMediaCaptions: Bool = false         // bit12: true = hide media captions
    public var sendAs: Option<TLObject> = None         // bit13: InputPeer
    public var effect: Option<Int64> = None            // bit18: long
    public var videoTimestamp: Option<Int32> = None    // bit20: int
    public var allowPaidStars: Option<Int64> = None    // bit21: long

    public func getConstructorId(): UInt32 { return 0x13704a7c }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.silent) { flags = flags | (1 << 5) }
        match (this.topMsgId) { case Some(_) => flags = flags | (1 << 9); case None => () }
        match (this.scheduleDate) { case Some(_) => flags = flags | (1 << 10); case None => () }
        if (this.dropAuthor) { flags = flags | (1 << 11) }
        if (this.dropMediaCaptions) { flags = flags | (1 << 12) }
        match (this.sendAs) { case Some(_) => flags = flags | (1 << 13); case None => () }
        match (this.effect) { case Some(_) => flags = flags | (1 << 18); case None => () }
        match (this.videoTimestamp) { case Some(_) => flags = flags | (1 << 20); case None => () }
        match (this.allowPaidStars) { case Some(_) => flags = flags | (1 << 21); case None => () }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.fromPeer.toBytes())
        // id: Vector<int>
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.idList.size))
        for (id in this.idList) {
            serializer.writeInt32(id)
        }
        // random_id: Vector<long>
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.randomIds.size))
        for (rid in this.randomIds) {
            serializer.writeInt64(rid)
        }
        serializer.writeRawBytes(this.toPeer.toBytes())
        match (this.topMsgId) { case Some(t) => serializer.writeInt32(t); case None => () }
        match (this.scheduleDate) { case Some(d) => serializer.writeInt32(d); case None => () }
        match (this.sendAs) { case Some(s) => serializer.writeRawBytes(s.toBytes()); case None => () }
        match (this.effect) { case Some(e) => serializer.writeInt64(e); case None => () }
        match (this.videoTimestamp) { case Some(v) => serializer.writeInt32(v); case None => () }
        match (this.allowPaidStars) { case Some(p) => serializer.writeInt64(p); case None => () }
    }
}

/**
 * messages.search — 搜索消息
 * 对应 TelegramHarmony TLMethods.ets: MessagesSearch
 */
/**
 * Phase S9: messages.search — 搜索消息（支持媒体类型过滤）
 * 
 * 过滤器类型:
 * - 0x57e2f66c inputMessagesFilterEmpty (默认)
 * - 0x9609a51c inputMessagesFilterPhotos
 * - 0x9fc00e65 inputMessagesFilterVideo
 * - 0x9eddf188 inputMessagesFilterDocument
 * - 0x7ef0dd87 inputMessagesFilterUrl
 * - 0x50f5c392 inputMessagesFilterVoice
 * - 0x3751b49e inputMessagesFilterMusic
 */
public class MessagesSearch <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var q: String = ""
    public var filter: TLObject = InputMessagesFilterEmpty()
    public var offsetId: Int32 = 0
    public var offsetDate: Int32 = 0
    public var addOffset: Int32 = 0
    public var limit: Int32 = 20
    public var maxId: Int32 = 0
    public var minId: Int32 = 0
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x29ee847a }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags (no from_id, saved_peer_id, saved_reaction, top_msg_id)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.q)
        serializer.writeRawBytes(this.filter.toBytes())
        serializer.writeInt32(0)  // min_date
        serializer.writeInt32(0)  // max_date
        serializer.writeInt32(this.offsetId)
        serializer.writeInt32(this.addOffset)
        serializer.writeInt32(this.limit)
        serializer.writeInt32(this.maxId)
        serializer.writeInt32(this.minId)
        serializer.writeInt64(this.hash)
    }
}

/**
 * P2-099: messages.search (date-range variant) — 按日期范围搜索媒体消息
 * 复用同一 constructor 0x29ee847a，但 min_date/max_date 字段不为 0。
 * iOS Api42.swift search() 参数: minDate:Int32, maxDate:Int32
 */
public class MessagesSearchByDate <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var q: String = ""
    public var filter: TLObject = InputMessagesFilterEmpty()
    public var minDate: Int32 = 0
    public var maxDate: Int32 = 0
    public var offsetId: Int32 = 0
    public var addOffset: Int32 = 0
    public var limit: Int32 = 20
    public var maxId: Int32 = 0
    public var minId: Int32 = 0
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x29ee847a }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.q)
        serializer.writeRawBytes(this.filter.toBytes())
        serializer.writeInt32(this.minDate)
        serializer.writeInt32(this.maxDate)
        serializer.writeInt32(this.offsetId)
        serializer.writeInt32(this.addOffset)
        serializer.writeInt32(this.limit)
        serializer.writeInt32(this.maxId)
        serializer.writeInt32(this.minId)
        serializer.writeInt64(this.hash)
    }
}

/**
 * messages.searchGlobal — 全局搜索消息
 * Constructor: 0x4bc6589a
 * flags:# folder_id:flags.0?int q:string filter:MessagesFilter
 * min_date:int max_date:int offset_rate:int offset_peer:InputPeer
 * offset_id:int limit:int
 */
public class MessagesSearchGlobal <: TLObject {
    public var folderId: Int32 = -1  // -1 = don't send folder_id
    public var q: String = ""
    public var filter: TLObject = InputMessagesFilterEmpty()
    public var minDate: Int32 = 0
    public var maxDate: Int32 = 0
    public var offsetRate: Int32 = 0
    public var offsetPeer: TLObject = InputPeerEmpty()
    public var offsetId: Int32 = 0
    public var limit: Int32 = 20
    // S050: broadcasts_only:flags.1?true —— 只搜频道公开帖子。
    // scheme: messages.searchGlobal#4bc6589a flags:# broadcasts_only:flags.1?true
    //         groups_only:flags.2?true users_only:flags.3?true folder_id:flags.0?int ...
    // 对位 iOS HashtagSearchGlobalChatContents(publicPosts: true)。
    public var broadcastsOnly: Bool = false

    public func getConstructorId(): UInt32 { return 0x4bc6589a }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.folderId >= 0) { flags = flags | 1 }
        if (this.broadcastsOnly) { flags = flags | 2 }
        serializer.writeInt32(flags)
        if (this.folderId >= 0) { serializer.writeInt32(this.folderId) }
        serializer.writeString(this.q)
        serializer.writeRawBytes(this.filter.toBytes())
        serializer.writeInt32(this.minDate)
        serializer.writeInt32(this.maxDate)
        serializer.writeInt32(this.offsetRate)
        serializer.writeRawBytes(this.offsetPeer.toBytes())
        serializer.writeInt32(this.offsetId)
        serializer.writeInt32(this.limit)
    }
}

/**
 * channels.searchPosts —— 公开频道帖子按 hashtag 搜索（→ messages.Messages）。
 * scheme 取自 iOS Api42.swift:4037-4053（appendInt32(-221973939) == 0xf2c4f24d）：
 *   flags:# hashtag:flags.0?string query:flags.1?string offset_rate:int
 *   offset_peer:InputPeer offset_id:int limit:int allow_paid_stars:flags.2?long
 * iOS _internal_searchHashtagPosts 只置 flags.0（hashtag），query / allow_paid_stars 不发。
 */
public class ChannelsSearchPosts <: TLObject {
    public var hashtag: String = ""
    public var offsetRate: Int32 = 0
    public var offsetPeer: TLObject = InputPeerEmpty()
    public var offsetId: Int32 = 0
    public var limit: Int32 = 10

    public func getConstructorId(): UInt32 { return 0xf2c4f24d }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(1)
        serializer.writeString(this.hashtag)
        serializer.writeInt32(this.offsetRate)
        serializer.writeRawBytes(this.offsetPeer.toBytes())
        serializer.writeInt32(this.offsetId)
        serializer.writeInt32(this.limit)
    }
}

/**
 * messages.sendMessage 增强版 — 支持回复
 * messages.sendMessage#fbf2340a (Layer 214 correct ID)
 * 当 replyToMsgId > 0 时，发送带回复的消息
 */
public class MessagesSendMessageWithReply <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var message: String = ""
    public var randomId: Int64 = 0
    public var replyToMsgId: Int32 = 0
    // P2-115: quote reply fields — iOS Api13.swift Cons_inputReplyToMessage
    // quoteText: flags.2?string (bit2 in inputReplyToMessage.flags)
    // quoteOffset: flags.4?int (bit4 in inputReplyToMessage.flags)
    public var quoteText: String = ""
    public var quoteOffset: Int32 = 0
    // S2-63 / S2-70: silent (bit5), schedule_date (bit10, 0 = absent), effect (bit18, 0 = absent)
    public var silent: Bool = false
    public var scheduleDate: Int32 = 0
    public var effectId: Int64 = 0
    // WP-D (S2-18/19/24): entities (bit3) so a formatted reply keeps its MessageEntity list.
    public var entities: Option<ArrayList<TLObject>> = None

    // messages.sendMessage#fef48f62 (iOS Api42 layer; python: hex(-17526942 & 0xffffffff) == '0xfef48f62')
    // CJ wrapper: replyToMsgId drives bit0 reply_to field; quoteText drives quoteText sub-flag
    public func getConstructorId(): UInt32 { return 0xfef48f62 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.replyToMsgId > 0) { flags = flags | 1 }  // bit0: reply_to present
        if (this.silent) { flags = flags | (1 << 5) }
        match (this.entities) { case Some(_) => flags = flags | (1 << 3); case None => () }
        if (this.scheduleDate > 0) { flags = flags | (1 << 10) }
        if (this.effectId != 0) { flags = flags | (1 << 18) }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        // reply_to: InputReplyTo (flags.0?)
        if (this.replyToMsgId > 0) {
            // inputReplyToMessage#3bd4b7c2; iOS Api13.swift L131: appendInt32(1003796418)
            serializer.writeUInt32(0x3bd4b7c2)
            // inputReplyToMessage.flags: bit2 = quoteText present; bit4 = quoteOffset present
            var replyFlags: Int32 = 0
            if (this.quoteText.size > 0) { replyFlags = replyFlags | (1 << 2) }
            if (this.quoteText.size > 0 && this.quoteOffset >= 0) { replyFlags = replyFlags | (1 << 4) }
            serializer.writeInt32(replyFlags)
            serializer.writeInt32(this.replyToMsgId)
            if (this.quoteText.size > 0) {
                serializer.writeString(this.quoteText)
            }
            if (this.quoteText.size > 0 && this.quoteOffset >= 0) {
                serializer.writeInt32(this.quoteOffset)
            }
        }
        serializer.writeString(this.message)
        serializer.writeInt64(this.randomId)
        // replyMarkup (bit2) absent; entities (bit3) Vector<MessageEntity>; field order after
        // random_id follows messages.sendMessage#fef48f62: schedule_date (bit10) … effect (bit18).
        match (this.entities) {
            case Some(ents) =>
                serializer.writeUInt32(0x1cb5c415)
                serializer.writeInt32(Int32(ents.size))
                for (e in ents) { serializer.writeRawBytes(e.toBytes()) }
            case None => ()
        }
        if (this.scheduleDate > 0) { serializer.writeInt32(this.scheduleDate) }
        if (this.effectId != 0) { serializer.writeInt64(this.effectId) }
    }
}

// ==================== S2-70: 定时消息 ====================

/** messages.getScheduledHistory#f516760b peer:InputPeer hash:long = messages.Messages（iOS Api42.swift:8254） */
public class MessagesGetScheduledHistory <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xf516760b }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt64(this.hash)
    }
}

/** messages.deleteScheduledMessages#59ae2b16 peer:InputPeer id:Vector<int> = Updates（iOS Api42.swift:6417） */
public class MessagesDeleteScheduledMessages <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var idList: ArrayList<Int32> = ArrayList<Int32>()

    public func getConstructorId(): UInt32 { return 0x59ae2b16 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.idList.size))
        for (id in this.idList) { serializer.writeInt32(id) }
    }
}

/** messages.sendScheduledMessages#bd38850a peer:InputPeer id:Vector<int> = Updates（iOS Api42.swift:9966） */
public class MessagesSendScheduledMessages <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var idList: ArrayList<Int32> = ArrayList<Int32>()

    public func getConstructorId(): UInt32 { return 0xbd38850a }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.idList.size))
        for (id in this.idList) { serializer.writeInt32(id) }
    }
}

// ==================== Phase H6: 消息 Reactions ====================

/**
 * messages.sendReaction — 发送/切换/移除消息反应
 * 
 * TL Schema: messages.sendReaction#d30d78d4
 * flags:# big:flags.1?true add_to_recent:flags.2?true
 * peer:InputPeer msg_id:int reaction:flags.0?Vector<Reaction>
 * 
 * Returns: Updates
 * 
 * 使用方式:
 * - emoji 非空: 发送该 emoji 作为 reaction（flags = 0x05, bit0 = has reaction, bit2 = add_to_recent）
 * - emoji 为空: 移除所有 reaction（flags = 0, 无 reaction 向量）
 */
/**
 * photos.uploadProfilePhoto — 上传用户头像 / 视频头像 (Phase L5 + P2-144)
 *
 * photos.uploadProfilePhoto#0388a3b5
 * iOS Api42.swift:12518 — flags field order (0-indexed bits):
 *   flags bit 5 (1<<5): bot (InputUser)          — sent BEFORE file/video
 *   flags bit 0 (1<<0): file (InputFile)          — static image
 *   flags bit 1 (1<<1): video (InputFile)         — video avatar
 *   flags bit 2 (1<<2): video_start_ts (double)   — video start timestamp
 *   flags bit 4 (1<<4): video_emoji_markup (VideoSize)
 *
 * Wire order per iOS: flags, [bot], [file], [video], [videoStartTs], [videoEmojiMarkup]
 * P2-144 adds video (bit1) + video_start_ts (bit2).
 * bot and video_emoji_markup are not exposed in this layer (kept as None path).
 */
/**
 * videoSizeEmojiMarkup#f85c413c emoji_id:long background_colors:Vector<int>
 *
 * Profile emoji avatars are stored by Telegram as a normal cover photo plus
 * this markup object in Photo.video_sizes.  The client renders the referenced
 * custom-emoji document over the supplied gradient colors.
 */
public class VideoSizeEmojiMarkup <: TLObject {
    public var emojiId: Int64 = 0
    public var backgroundColors: ArrayList<Int32> = ArrayList<Int32>()

    public func getConstructorId(): UInt32 { return 0xf85c413c }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.emojiId)
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.backgroundColors.size))
        for (color in this.backgroundColors) { serializer.writeInt32(color) }
    }
}

public class PhotosUploadProfilePhoto <: TLObject {
    public var file: Option<TLObject> = None        // InputFile (flags bit 0)
    public var video: Option<TLObject> = None       // InputFile (flags bit 1)
    public var videoStartTs: Option<Float64> = None // double (flags bit 2)
    public var videoEmojiMarkup: Option<TLObject> = None // VideoSize (flags bit 4)

    public func getConstructorId(): UInt32 { return 0x0388a3b5 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        match (this.file) {
            case Some(_) => flags = flags | 1        // bit 0
            case None => ()
        }
        match (this.video) {
            case Some(_) => flags = flags | 2        // bit 1
            case None => ()
        }
        match (this.videoStartTs) {
            case Some(_) => flags = flags | 4        // bit 2
            case None => ()
        }
        match (this.videoEmojiMarkup) {
            case Some(_) => flags = flags | 16       // bit 4
            case None => ()
        }
        serializer.writeInt32(flags)
        // bot (bit 5) is not set — skip
        match (this.file) {
            case Some(f) => serializer.writeRawBytes(f.toBytes())
            case None => ()
        }
        match (this.video) {
            case Some(v) => serializer.writeRawBytes(v.toBytes())
            case None => ()
        }
        match (this.videoStartTs) {
            case Some(ts) => serializer.writeDouble(ts)
            case None => ()
        }
        match (this.videoEmojiMarkup) {
            case Some(markup) => serializer.writeRawBytes(markup.toBytes())
            case None => ()
        }
    }
}

/**
 * photos.deletePhotos — 删除用户头像
 * 
 * Constructor: 0x87cf7f2f
 * id: Vector<InputPhoto>
 */
public class PhotosDeletePhotos <: TLObject {
    public var photoIds: ArrayList<Int64> = ArrayList<Int64>()
    public var accessHashes: ArrayList<Int64> = ArrayList<Int64>()
    public var fileReferences: ArrayList<Array<Byte>> = ArrayList<Array<Byte>>()

    public func getConstructorId(): UInt32 { return 0x87cf7f2f }

    public func serialize(serializer: TLSerializer) {
        // Vector header
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.photoIds.size))
        for (i in 0..this.photoIds.size) {
            // inputPhoto#3bb3b94a id:long access_hash:long file_reference:bytes
            serializer.writeUInt32(0x3bb3b94a)
            serializer.writeInt64(this.photoIds[i])
            serializer.writeInt64(this.accessHashes[i])
            serializer.writeBytes(this.fileReferences[i])
        }
    }
}

public class MessagesSendReaction <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var msgId: Int32 = 0
    public var emoji: String = ""              // 空 = 移除所有反应
    // P2-375: custom emoji reaction — document_id != 0 means use reactionCustomEmoji
    // iOS ref: Api22.swift case .reactionCustomEmoji => buffer.appendInt32(-1992950669) = 0x8935fc73
    public var customEmojiDocumentId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xd30d78d4 }

    public func serialize(serializer: TLSerializer) {
        let hasReaction = this.emoji.size > 0 || this.customEmojiDocumentId != 0
        var flags: Int32 = 0
        if (hasReaction) {
            flags = flags | 1   // bit 0: has reaction vector
            flags = flags | 4   // bit 2: add_to_recent
        }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.msgId)
        // reaction: Vector<Reaction> (if flags bit 0)
        if (hasReaction) {
            // Vector header
            serializer.writeUInt32(0x1cb5c415)  // vector constructor
            serializer.writeInt32(1)  // count = 1 (single reaction)
            if (this.customEmojiDocumentId != 0) {
                // reactionCustomEmoji#8935fc73 document_id:long
                // iOS: Api22.swift case .reactionCustomEmoji => buffer.appendInt32(-1992950669)
                // python: -1992950669 & 0xFFFFFFFF = 0x8935fc73  (ctor verified)
                serializer.writeUInt32(0x8935fc73)
                serializer.writeInt64(this.customEmojiDocumentId)
            } else {
                // reactionEmoji#1b2286b8 emoticon:string
                serializer.writeUInt32(0x1b2286b8)
                serializer.writeString(this.emoji)
            }
        }
    }
}

/**
 * messages.getMessageReactionsList — 获取消息反应者列表 (P2-116)
 *
 * TL Schema (telegram_api.tl:2345):
 *   messages.getMessageReactionsList#461b3f48
 *     flags:# peer:InputPeer id:int
 *     reaction:flags.0?Reaction offset:flags.1?string limit:int
 *     = messages.MessageReactionsList
 *
 * Returns: messages.messageReactionsList#31bd492d
 *   flags:# count:int reactions:Vector<MessagePeerReaction>
 *   chats:Vector<Chat> users:Vector<User> next_offset:flags.0?string
 *
 * messagePeerReaction#8c79b63c
 *   flags:# big:flags.0?true unread:flags.1?true my:flags.2?true
 *   peer_id:Peer date:int reaction:Reaction
 *
 * 使用方式:
 *   - 不过滤特定 emoji：flags=0，不传 reaction / offset
 *   - 只看某 emoji 的 reactor：flags=1，reaction = reactionEmoji
 */
public class MessagesGetMessageReactionsList <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var msgId: Int32 = 0
    public var limit: Int32 = 50

    public override func getConstructorId(): UInt32 { return 0x461b3f48 }

    public override func serialize(serializer: TLSerializer) {
        let flags: Int32 = 0  // no reaction filter, no offset
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.msgId)
        // reaction (flags.0) — absent
        // offset (flags.1) — absent
        serializer.writeInt32(this.limit)
    }
}

/**
 * account.getAuthorizations — 获取活跃会话列表 (Phase J2)
 * Constructor: 0xe320c158
 */
/**
 * inputMediaPoll — 发送投票 (Phase I4 / P2-150b fix)
 *
 * TL schema (telegram_api.tl:70):
 *   inputMediaPoll#f94e5f1 flags:# poll:Poll correct_answers:flags.0?Vector<bytes>
 *     solution:flags.1?string solution_entities:flags.1?Vector<MessageEntity> = InputMedia
 *
 * Inner Poll (telegram_api.tl:1219):
 *   poll#58747131 id:long flags:# closed:flags.0?true public_voters:flags.1?true
 *     multiple_choice:flags.2?true quiz:flags.3?true question:TextWithEntities
 *     answers:Vector<PollAnswer> close_period:flags.4?int close_date:flags.5?int = Poll
 *
 * PollAnswer (telegram_api.tl:1217):
 *   pollAnswer#ff16e2ca text:TextWithEntities option:bytes = PollAnswer
 *
 * TextWithEntities (telegram_api.tl:1604):
 *   textWithEntities#751f3146 text:string entities:Vector<MessageEntity> = TextWithEntities
 *
 * BUG FIX (P2-150b): previous code used poll ctor 0x86e18161 (wrong/nonexistent),
 * and serialized question/answers as bare strings instead of TextWithEntities boxed objects.
 * Both caused wire-level failures when sending new polls.
 */
public class InputMediaPoll <: TLObject {
    public var question: String = ""
    public var answers: ArrayList<String> = ArrayList<String>()
    public var anonymous: Bool = true
    public var multipleChoice: Bool = false
    public var quiz: Bool = false
    // quiz 正确答案的 option 索引（对应 pollAnswer.option 的 ASCII 数字字节）。
    public var correctAnswers: ArrayList<Int32> = ArrayList<Int32>()

    // 服务端 schema（telegram_api.tl）：inputMediaPoll#f94e5f1（非 iOS 更高层的 0x883a4108）。
    // 关键教训：contact#f8ab7dfb / geo#f9c44144 等能发的媒体 ctor 均与 td .tl 一致，证明服务端在这套 schema；
    // 之前有人把 poll 三个 ctor "升级"成 iOS Api21 的更高层版本（0x966e2dbf 等，布局带 hash/pollAnswer flags），
    // 与服务端 layer 不符 → 所有投票 MEDIA_INVALID（真机 hex 实证）。此处按 td .tl 权威布局改回。
    public func getConstructorId(): UInt32 { return 0x0f94e5f1 }

    public func serialize(serializer: TLSerializer) {
        // inputMediaPoll#f94e5f1 flags:# poll:Poll correct_answers:flags.0?Vector<bytes> solution:flags.1?string ...
        let hasCorrect = this.quiz && !this.correctAnswers.isEmpty()
        var mediaFlags: Int32 = 0
        if (hasCorrect) { mediaFlags = mediaFlags | 1 }  // flags.0: correct_answers
        serializer.writeInt32(mediaFlags)
        // poll#58747131 id:long flags:# closed.0 public_voters.1 multiple_choice.2 quiz.3
        //   question:TextWithEntities answers:Vector<PollAnswer> [close_period.4] [close_date.5]  ← 无 hash 字段
        serializer.writeUInt32(0x58747131)
        serializer.writeInt64(0)  // poll.id (server assigns)
        var pollFlags: Int32 = 0
        if (!this.anonymous) { pollFlags = pollFlags | 2 }   // bit1: public_voters
        if (this.multipleChoice) { pollFlags = pollFlags | 4 } // bit2: multiple_choice
        if (this.quiz) { pollFlags = pollFlags | 8 }           // bit3: quiz
        serializer.writeInt32(pollFlags)
        // poll.question: TextWithEntities#751f3146
        serializer.writeUInt32(0x751f3146)
        serializer.writeString(this.question)
        serializer.writeUInt32(0x1cb5c415)  // entities vector ctor
        serializer.writeInt32(0)            // 0 entities
        // poll.answers: Vector<PollAnswer>
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.answers.size))
        var optionIdx: Int32 = 0
        for (answer in this.answers) {
            // pollAnswer#ff16e2ca text:TextWithEntities option:bytes  ← 无 flags 字段（区别于 iOS 0x4b7d786a）
            serializer.writeUInt32(0xff16e2ca)
            // text: TextWithEntities#751f3146
            serializer.writeUInt32(0x751f3146)
            serializer.writeString(answer)
            serializer.writeUInt32(0x1cb5c415)  // entities vector
            serializer.writeInt32(0)            // 0 entities
            // option: bytes — opaqueIdentifier = 索引的 ASCII 数字字符串 "0"/"1"…(0x30,0x31)
            serializer.writeBytes("${optionIdx}".toArray())
            optionIdx += 1
        }
        // 注意：poll#58747131 无 hash:long（不要写）。
        // correct_answers:flags.0?Vector<bytes> — 正确项的 option 标识（同为 ASCII 数字字节）。
        if (hasCorrect) {
            serializer.writeUInt32(0x1cb5c415)  // Vector<bytes> ctor
            serializer.writeInt32(Int32(this.correctAnswers.size))
            for (idx in this.correctAnswers) {
                serializer.writeBytes("${idx}".toArray())
            }
        }
    }
}

/**
 * messages.sendVote — 投票 (Phase I4)
 * Constructor: 0x10ea6184
 */
public class MessagesSendVote <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var msgId: Int32 = 0
    public var options: ArrayList<Array<Byte>> = ArrayList<Array<Byte>>()

    public func getConstructorId(): UInt32 { return 0x10ea6184 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.msgId)
        // options vector
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.options.size))
        for (option in this.options) {
            serializer.writeBytes(option)
        }
    }
}

/**
 * inputMediaContact — 发送联系人卡片 (Phase I5)
 * Constructor: 0xf8ab7dfb
 */
public class InputMediaContact <: TLObject {
    public var phoneNumber: String = ""
    public var firstName: String = ""
    public var lastName: String = ""
    public var vcard: String = ""

    public func getConstructorId(): UInt32 { return 0xf8ab7dfb }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.phoneNumber)
        serializer.writeString(this.firstName)
        serializer.writeString(this.lastName)
        serializer.writeString(this.vcard)
    }
}

/**
 * messages.setTyping — 发送输入状态 (Phase I7)
 * Constructor: 0x58943ee2
 */
public class MessagesSetTyping <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var action: UInt32 = 0x16bf744e  // sendMessageTypingAction
    public var actionEmoticon: String = ""
    public var actionMessageId: Int32 = 0
    public var actionInteractionJson: String = ""

    public func getConstructorId(): UInt32 { return 0x58943ee2 }

    public func serialize(serializer: TLSerializer) {
        let flags: Int32 = 0
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeUInt32(this.action)
        // sendMessageEmojiInteraction#25972bcb
        if (this.action == 0x25972bcb) {
            serializer.writeString(this.actionEmoticon)
            serializer.writeInt32(this.actionMessageId)
            serializer.writeUInt32(0x7d748d04) // dataJSON
            serializer.writeString(this.actionInteractionJson)
        }
        // sendMessageEmojiInteractionSeen#b665902e
        if (this.action == 0xb665902e) {
            serializer.writeString(this.actionEmoticon)
        }
    }
}

/**
 * messages.saveDraft — 保存草稿到服务器
 * messages.saveDraft#d372c5ce (Layer 214 correct ID)
 * flags:# no_webpage:flags.1?true invert_media:flags.6?true
 * reply_to:flags.4?InputReplyTo peer:InputPeer message:string
 * entities:flags.3?Vector<MessageEntity> media:flags.5?InputMedia effect:flags.7?long
 */
public class MessagesSaveDraft <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var message: String = ""
    public var replyToMsgId: Int32 = 0
    // flags-gated optional fields (iOS Api42 layer, all default absent)
    public var entities: Option<ArrayList<TLObject>> = None  // bit3: Vector<MessageEntity>
    public var media: Option<TLObject> = None          // bit5: InputMedia
    public var effect: Option<Int64> = None            // bit7: long

    // messages.saveDraft#ad0fa15c (iOS Api42 layer; python: hex(-1391484580 & 0xffffffff) == '0xad0fa15c')
    public func getConstructorId(): UInt32 { return 0xad0fa15c }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        match (this.entities) { case Some(_) => flags = flags | (1 << 3); case None => () }
        if (this.replyToMsgId > 0) { flags = flags | (1 << 4) }   // bit4: reply_to present
        match (this.media) { case Some(_) => flags = flags | (1 << 5); case None => () }
        match (this.effect) { case Some(_) => flags = flags | (1 << 7); case None => () }
        serializer.writeInt32(flags)
        if (this.replyToMsgId > 0) {
            // inputReplyToMessage#3bd4b7c2 (ios Api13.swift L131: appendInt32(1003796418); python: hex(1003796418 & 0xffffffff) == 0x3bd4b7c2)
            serializer.writeUInt32(0x3bd4b7c2)
            serializer.writeInt32(0) // inputReplyToMessage.flags
            serializer.writeInt32(this.replyToMsgId)
        }
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.message)
        match (this.entities) {
            case Some(ents) =>
                serializer.writeUInt32(0x1cb5c415)
                serializer.writeInt32(Int32(ents.size))
                for (e in ents) { serializer.writeRawBytes(e.toBytes()) }
            case None => ()
        }
        match (this.media) { case Some(m) => serializer.writeRawBytes(m.toBytes()); case None => () }
        match (this.effect) { case Some(e) => serializer.writeInt64(e); case None => () }
    }
}

public class AccountGetAuthorizations <: TLObject {
    public func getConstructorId(): UInt32 { return 0xe320c158 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * account.resetAuthorization — 终止指定会话 (Phase J2)
 * Constructor: 0xdf77f3bc
 * hash: long — 会话 hash
 */
/**
 * inputGeoPoint — 地理坐标 (Phase I3)
 * Constructor: 0x48222faf
 */
public class InputGeoPoint <: TLObject {
    public var lat: Float64 = 0.0
    public var long: Float64 = 0.0

    public func getConstructorId(): UInt32 { return 0x48222faf }

    public func serialize(serializer: TLSerializer) {
        let flags: Int32 = 0
        serializer.writeInt32(flags)
        serializer.writeDouble(this.lat)
        serializer.writeDouble(this.long)
    }
}

/**
 * inputMediaGeoPoint — 发送地理位置 (Phase I3)
 * Constructor: 0xf9c44144
 */
public class InputMediaGeoPoint <: TLObject {
    public var geoPoint: InputGeoPoint = InputGeoPoint()

    public func getConstructorId(): UInt32 { return 0xf9c44144 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.geoPoint.toBytes())
    }
}

/**
 * inputMediaGeoLive — 发送/停止实时位置 (Phase I3 / P2-150b liveLocation stop)
 *
 * TL schema (telegram_api.tl:69):
 *   inputMediaGeoLive#971fa843 flags:#
 *     stopped:flags.0?true geo_point:InputGeoPoint heading:flags.2?int
 *     period:flags.1?int proximity_notification_radius:flags.3?int = InputMedia
 *
 * stopped=true: 停止实时位置分享 (liveLocation edit with stopped flag)
 * stopped=false + period set: 发送/更新实时位置
 */
public class InputMediaGeoLive <: TLObject {
    public var geoPoint: InputGeoPoint = InputGeoPoint()
    public var period: Int32 = 900  // 持续时间(秒)
    public var stopped: Bool = false  // true = stop live location sharing

    public func getConstructorId(): UInt32 { return 0x971fa843 }

    public func serialize(serializer: TLSerializer) {
        if (this.stopped) {
            // stopped=flags.0; geo_point is required by TL schema even when stopped
            serializer.writeInt32(1)             // flags: bit0 = stopped
            serializer.writeUInt32(0xe4c123d6)   // inputGeoPointEmpty#e4c123d6 (no fields; schema line 80)
        } else {
            let flags: Int32 = 2  // bit1 = period present
            serializer.writeInt32(flags)
            serializer.writeRawBytes(this.geoPoint.toBytes())
            serializer.writeInt32(this.period)
        }
    }
}

public class AccountResetAuthorization <: TLObject {
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xdf77f3bc }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

// ==================== Phase K: 通话信令 (phone.*) ====================

/**
 * phone.requestCall — 发起通话 (Phase K1)
 * Constructor: 0x42ff96ed
 * flags: bit 0 = video
 * user_id: InputUser
 * random_id: int
 * g_a_hash: bytes (DH gA hash)
 * protocol: PhoneCallProtocol
 */
public class PhoneRequestCall <: TLObject {
    public var isVideo: Bool = false
    public var userId: Int64 = 0
    public var userAccessHash: Int64 = 0
    public var randomId: Int32 = 0
    public var gAHash: Array<Byte> = Array<Byte>(0, repeat: 0)
    // Protocol fields
    public var minLayer: Int32 = 65
    public var maxLayer: Int32 = 92
    public var libraryVersions: ArrayList<String> = ArrayList<String>()

    public func getConstructorId(): UInt32 { return 0x42ff96ed }

    public func serialize(serializer: TLSerializer) {
        let flags: Int32 = if (this.isVideo) { 1 } else { 0 }
        serializer.writeInt32(flags)
        // inputUser#f21158c6 user_id:long access_hash:long
        serializer.writeUInt32(0xf21158c6)
        serializer.writeInt64(this.userId)
        serializer.writeInt64(this.userAccessHash)
        serializer.writeInt32(this.randomId)
        serializer.writeBytes(this.gAHash)
        // phoneCallProtocol#fc878fc8
        serializer.writeUInt32(0xfc878fc8)
        let protocolFlags: Int32 = (1 << 0) | (1 << 1)  // udp_p2p + udp_reflector
        serializer.writeInt32(protocolFlags)
        serializer.writeInt32(this.minLayer)
        serializer.writeInt32(this.maxLayer)
        // library_versions vector — must include ALL versions our tgcalls supports
        // so the peer can negotiate the highest common version
        serializer.writeUInt32(0x1cb5c415)
        if (this.libraryVersions.size == 0) {
            PhoneRequestCall.writeDefaultLibraryVersions(serializer)
        } else {
            serializer.writeInt32(Int32(this.libraryVersions.size))
            for (v in this.libraryVersions) {
                serializer.writeString(v)
            }
        }
    }

    /**
     * Write the set of tgcalls library versions we ACTUALLY implement.
     * libtgcalls_ohos.so 仅注册 InstanceV2Impl → GetVersions() = {7,8,9,12,13}.0.0。
     *
     * 严禁通告未实现的版本：iOS 被叫按其本机列表"字符串升序"选第一个我方也通告的版本
     * (selectVersionOnAccept)。此前通告 10.0.0/11.0.0（属 InstanceV2ReferenceImpl，
     * 我方未编译），iOS 升序恰好首选 10.0.0 → 对端跑 ReferenceImpl 等 offer，
     * 我方写死 12.0.0 发 SCTP INIT → 互不可解 → 通话永远连不上（真机实锤）。
     * 2.7.7/5.0.0（InstanceImpl 旧实现）同样未编译，一并移除。
     */
    public static func writeDefaultLibraryVersions(serializer: TLSerializer) {
        let versions = ["13.0.0", "12.0.0", "9.0.0", "8.0.0", "7.0.0"]
        serializer.writeInt32(Int32(versions.size))
        for (v in versions) {
            serializer.writeString(v)
        }
    }
}

/**
 * phone.acceptCall — 接受来电 (Phase K1)
 * Constructor: 0x3bd2b4a0
 * peer: InputPhoneCall
 * g_b: bytes (DH gB)
 * protocol: PhoneCallProtocol
 */
public class PhoneAcceptCall <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var gB: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var minLayer: Int32 = 65
    public var maxLayer: Int32 = 92
    // 版本协商：被叫从主叫通告列表中选定的单一版本（对齐 iOS selectVersionOnAccept 只回一个）
    public var libraryVersions: ArrayList<String> = ArrayList<String>()

    public func getConstructorId(): UInt32 { return 0x3bd2b4a0 }

    public func serialize(serializer: TLSerializer) {
        // inputPhoneCall#1e36fded id:long access_hash:long
        serializer.writeUInt32(0x1e36fded)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        serializer.writeBytes(this.gB)
        // phoneCallProtocol#fc878fc8
        serializer.writeUInt32(0xfc878fc8)
        let protocolFlags: Int32 = (1 << 0) | (1 << 1)
        serializer.writeInt32(protocolFlags)
        serializer.writeInt32(this.minLayer)
        serializer.writeInt32(this.maxLayer)
        // library_versions — 被叫选定的单一版本；未捕获主叫列表时回退默认（已实现）列表
        serializer.writeUInt32(0x1cb5c415)
        if (this.libraryVersions.size > 0) {
            serializer.writeInt32(Int32(this.libraryVersions.size))
            for (v in this.libraryVersions) {
                serializer.writeString(v)
            }
        } else {
            PhoneRequestCall.writeDefaultLibraryVersions(serializer)
        }
    }
}

/**
 * phone.confirmCall — 确认通话 (Phase K1)
 * Constructor: 0x2efe1722
 * peer: InputPhoneCall
 * g_a: bytes
 * key_fingerprint: long
 * protocol: PhoneCallProtocol
 */
public class PhoneConfirmCall <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var gA: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var keyFingerprint: Int64 = 0
    public var minLayer: Int32 = 65
    public var maxLayer: Int32 = 92
    // 版本协商：非空时只发这里的版本（协商结果，通常单元素——对齐 iOS caller 行为）
    public var libraryVersions: ArrayList<String> = ArrayList<String>()

    public func getConstructorId(): UInt32 { return 0x2efe1722 }

    public func serialize(serializer: TLSerializer) {
        // inputPhoneCall
        serializer.writeUInt32(0x1e36fded)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        serializer.writeBytes(this.gA)
        serializer.writeInt64(this.keyFingerprint)
        // phoneCallProtocol
        serializer.writeUInt32(0xfc878fc8)
        let protocolFlags: Int32 = (1 << 0) | (1 << 1)
        serializer.writeInt32(protocolFlags)
        serializer.writeInt32(this.minLayer)
        serializer.writeInt32(this.maxLayer)
        // library_versions — 协商出的单一版本；未捕获时回退默认（已实现）列表
        serializer.writeUInt32(0x1cb5c415)
        if (this.libraryVersions.size > 0) {
            serializer.writeInt32(Int32(this.libraryVersions.size))
            for (v in this.libraryVersions) {
                serializer.writeString(v)
            }
        } else {
            PhoneRequestCall.writeDefaultLibraryVersions(serializer)
        }
    }
}

/**
 * phone.discardCall — 结束/拒绝通话 (Phase K1)
 * Constructor: 0xb2cbc1c0
 * flags: bit 0 = video
 * peer: InputPhoneCall
 * duration: int
 * reason: PhoneCallDiscardReason
 * connection_id: long
 */
public class PhoneDiscardCall <: TLObject {
    public var isVideo: Bool = false
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var duration: Int32 = 0
    public var reason: String = "hangup"  // hangup, busy, disconnect, missed

    public func getConstructorId(): UInt32 { return 0xb2cbc1c0 }

    public func serialize(serializer: TLSerializer) {
        let flags: Int32 = if (this.isVideo) { 1 } else { 0 }
        serializer.writeInt32(flags)
        // inputPhoneCall
        serializer.writeUInt32(0x1e36fded)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        serializer.writeInt32(this.duration)
        // PhoneCallDiscardReason
        if (this.reason == "busy") {
            serializer.writeUInt32(0xfaf7e8c9)  // phoneCallDiscardReasonBusy
        } else if (this.reason == "disconnect") {
            serializer.writeUInt32(0xe095c1a0)  // phoneCallDiscardReasonDisconnect
        } else if (this.reason == "missed") {
            serializer.writeUInt32(0x85e42301)  // phoneCallDiscardReasonMissed
        } else {
            serializer.writeUInt32(0x57adc690)  // phoneCallDiscardReasonHangup
        }
        serializer.writeInt64(0)  // connection_id
    }
}

/**
 * phone.receivedCall — 确认收到来电 (Phase K1)
 * Constructor: 0x17d54f61
 * peer: InputPhoneCall
 */
public class PhoneReceivedCall <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x17d54f61 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0x1e36fded)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
    }
}

/**
 * phone.getCallConfig — 获取通话配置 (Phase K1)
 * Constructor: 0x55451fa9
 */
public class PhoneGetCallConfig <: TLObject {
    public func getConstructorId(): UInt32 { return 0x55451fa9 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * phone.saveCallDebug — 保存通话调试数据 (Phase K1)
 * Constructor: 0x277add7e
 * peer: InputPhoneCall
 * debug: DataJSON
 */
public class PhoneSaveCallDebug <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var debugData: String = "{}"

    public func getConstructorId(): UInt32 { return 0x277add7e }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0x1e36fded)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        // dataJSON#7d748d04
        serializer.writeUInt32(0x7d748d04)
        serializer.writeString(this.debugData)
    }
}

/**
 * phone.setCallRating — 评价通话质量 (Phase K1)
 * Constructor: 0x59ead627
 * flags: bit 0 = user_initiative
 * peer: InputPhoneCall
 * rating: int (1-5)
 * comment: string
 */
public class PhoneSetCallRating <: TLObject {
    public var userInitiative: Bool = true
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var rating: Int32 = 5
    public var comment: String = ""

    public func getConstructorId(): UInt32 { return 0x59ead627 }

    public func serialize(serializer: TLSerializer) {
        let flags: Int32 = if (this.userInitiative) { 1 } else { 0 }
        serializer.writeInt32(flags)
        serializer.writeUInt32(0x1e36fded)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        serializer.writeInt32(this.rating)
        serializer.writeString(this.comment)
    }
}

// ==================== Signaling Data ====================

/**
 * phone.sendSignalingData — 发送通话信令数据 (Phase K5)
 * Constructor: -8744061 (0xFF7A9383)
 * peer: InputPhoneCall
 * data: bytes
 * Returns: Bool
 * 
 * 参考: Telegram-iOS Api39.swift:11152-11162
 * 在通话 active 状态后，用于双向传输 WebRTC ICE/DTLS 信令数据
 */
public class PhoneSendSignalingData <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var data: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0xFF7A9383 }

    public func serialize(serializer: TLSerializer) {
        // inputPhoneCall#1e36fded id:long access_hash:long
        serializer.writeUInt32(0x1e36fded)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        // data:bytes
        serializer.writeBytes(this.data)
    }
}

// ==================== Group Call (phone.*) — TelegramEngine.Calls ====================

/**
 * inputGroupCall#d8aa840f id:long access_hash:long = InputGroupCall
 * 用于 phone.getGroupCall, phone.joinGroupCall 等
 */
public class InputGroupCall <: TLObject {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xd8aa840f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.id)
        serializer.writeInt64(this.accessHash)
    }
}

/**
 * phone.getGroupCall — 获取群组通话信息
 * phone.getGroupCall#41845db (Layer 214 correct ID)
 * call: InputGroupCall, limit: int
 */
public class PhoneGetGroupCall <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var limit: Int32 = 4

    public func getConstructorId(): UInt32 { return 0x041845db }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        serializer.writeInt32(this.limit)
    }
}

/**
 * phone.createGroupCall — 创建群组通话
 * phone.createGroupCall#48cdc6d8 (Layer 214 correct ID)
 * flags:# peer:InputPeer random_id:int title:flags.0?string schedule_date:flags.1?int
 */
public class PhoneCreateGroupCall <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var randomId: Int32 = 0
    public var title: String = ""
    public var scheduleDate: Int32 = 0  // 0 = 不预约

    public func getConstructorId(): UInt32 { return 0x48cdc6d8 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.title.size > 0) { flags = flags | 1 }
        if (this.scheduleDate > 0) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.randomId)
        if (this.title.size > 0) { serializer.writeString(this.title) }
        if (this.scheduleDate > 0) { serializer.writeInt32(this.scheduleDate) }
    }
}

/**
 * phone.getGroupParticipants — 获取群组通话参与者
 * phone.getGroupParticipants#c558d8ab (Layer 214 correct ID)
 * call:InputGroupCall ids:Vector<InputPeer> sources:Vector<int> offset:string limit:int
 */
public class PhoneGetGroupParticipants <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var offset: String = ""
    public var limit: Int32 = 50
    // iOS getGroupCallParticipants(ssrcs:)：按音频 ssrc 反查参与者（Int32 位模式）
    public var sources: Array<Int32> = Array<Int32>()

    public func getConstructorId(): UInt32 { return 0xc558d8ab }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        // ids: vector (empty)
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(0)
        // sources: vector<int>
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.sources.size))
        for (src in this.sources) { serializer.writeInt32(src) }
        serializer.writeString(this.offset)
        serializer.writeInt32(this.limit)
    }
}

/**
 * phone.sendGroupCallMessage#b1d11410 flags:# call:InputGroupCall random_id:long
 *   message:TextWithEntities allow_paid_stars:flags.0?long send_as:flags.1?InputPeer = Updates
 * iOS Api42.swift:12678（layer 228）。注意：layer 214 里没有这个方法（216 引入，222 定型），
 * 本端仍按 214 建链；服务器是否受理以真机实测为准。
 * textWithEntities#751f3146 text:string entities:Vector<MessageEntity>
 */
public class PhoneSendGroupCallMessage <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var randomId: Int64 = 0
    public var text: String = ""

    public func getConstructorId(): UInt32 { return 0xb1d11410 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        serializer.writeInt64(this.randomId)
        serializer.writeUInt32(0x751f3146)
        serializer.writeString(this.text)
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(0)
    }
}

/**
 * phone.toggleGroupCallSettings#974392f2 flags:# reset_invite_hash:flags.1?true call:InputGroupCall
 *   join_muted:flags.0?Bool messages_enabled:flags.2?Bool send_paid_messages_stars:flags.3?long = Updates
 * iOS Api42.swift toggleGroupCallSettings buffer.appendInt32(-1757179150) => 0x974392f2
 * 这里只发 messages_enabled（GroupCalls.swift:2667 updateMessagesEnabled，flags = 1<<2）。
 * messages_enabled 这一位 layer 214 没有，必须走 layer-228 派生会话。
 */
public class PhoneToggleGroupCallMessagesEnabled <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var enabled: Bool = true
    // true = 改的是 join_muted（flags.0，GroupCalls.swift:2658 updateDefaultParticipantsAreMuted），
    // false = 改的是 messages_enabled（flags.2）；值都放在 enabled 里。
    public var isJoinMuted: Bool = false

    public func getConstructorId(): UInt32 { return 0x974392f2 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(if (this.isJoinMuted) { 1 << 0 } else { 1 << 2 })
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        serializer.writeUInt32(if (this.enabled) { 0x997275b5 } else { 0xbc799737 })
    }
}

/**
 * phone.getGroupCallJoinAs#ef7c213a peer:InputPeer = phone.JoinAsPeers
 * iOS Api42.swift getGroupCallJoinAs buffer.appendInt32(-277077702) => 0xef7c213a
 * 返回 phone.joinAsPeers#afe5623f peers:Vector<Peer> chats:Vector<Chat> users:Vector<User>
 *（GroupCalls.swift cachedGroupCallDisplayAsAvailablePeers）。
 */
public class PhoneGetGroupCallJoinAs <: TLObject {
    public var peer: TLObject = InputPeerSelf()

    public func getConstructorId(): UInt32 { return 0xef7c213a }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

/**
 * phone.toggleGroupCallStartSubscription#219c34e6 call:InputGroupCall subscribed:Bool = Updates
 * iOS Api42.swift toggleGroupCallStartSubscription buffer.appendInt32(563885286) => 0x219c34e6
 * 预约通话的 "Set Reminder / Cancel Reminder"（GroupCalls.swift toggleScheduledGroupCallSubscription）。
 */
public class PhoneToggleGroupCallStartSubscription <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var subscribed: Bool = true

    public func getConstructorId(): UInt32 { return 0x219c34e6 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        serializer.writeUInt32(if (this.subscribed) { 0x997275b5 } else { 0xbc799737 })
    }
}

/**
 * phone.checkGroupCall#b59cf977 call:InputGroupCall sources:Vector<int> = Vector<int>
 * iOS Api42.swift checkGroupCall buffer.appendInt32(-1248003721) => 0xb59cf977
 * 返回服务端仍登记在册的 ssrc；自己的 ssrc 不在其中 → 需要整体重新 join
 *（PresentationGroupCall.swift:2865 startCheckingCallIfNeeded）。
 */
public class PhoneCheckGroupCall <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var sources: Array<Int32> = Array<Int32>()

    public func getConstructorId(): UInt32 { return 0xb59cf977 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.sources.size))
        for (src in this.sources) { serializer.writeInt32(src) }
    }
}

/**
 * phone.leaveGroupCall — 离开群组通话
 * Constructor: 0x500377f9 (1342404601)
 * call:InputGroupCall source:int
 */
public class PhoneLeaveGroupCall <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var source: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x500377f9 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        serializer.writeInt32(this.source)
    }
}

/**
 * phone.discardGroupCall — 结束群组通话
 * phone.discardGroupCall#7a777135 (Layer 214 correct ID)
 * call:InputGroupCall
 */
public class PhoneDiscardGroupCall <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x7a777135 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
    }
}

// ==================== Group Call Extended — P2-161 ====================

/**
 * dataJSON#7d748d04 data:string = DataJSON
 * 供 joinGroupCall / joinGroupCallPresentation 的 params 字段使用
 * TL codegen verified: tl_codegen.py --tl-name "phone.joinGroupCall"
 */
public class TLDataJson <: TLObject {
    public var data: String = ""

    public func getConstructorId(): UInt32 { return 0x7d748d04 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.data)
    }
}

/**
 * phone.joinGroupCall#8fb53057
 * TL: phone.joinGroupCall#8fb53057 flags:# muted:flags.0?true video_stopped:flags.2?true
 *     call:InputGroupCall join_as:InputPeer invite_hash:flags.1?string
 *     public_key:flags.3?int256 block:flags.3?bytes params:DataJSON = Updates
 * TL codegen verified: tl_codegen.py from telegram_api.tl (ctor 0x8fb53057)
 * iOS ref: GroupCalls.swift _internal_joinGroupCall line 703
 */
public class PhoneJoinGroupCall <: TLObject {
    public var muted: Bool = false
    public var videoStopped: Bool = false
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var joinAsPeer: TLObject = InputPeerSelf()
    public var inviteHash: String = ""
    public var joinPayload: String = ""

    public func getConstructorId(): UInt32 { return 0x8fb53057 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.muted) { flags = flags | (1 << 0) }
        if (this.videoStopped) { flags = flags | (1 << 2) }
        if (this.inviteHash.size > 0) { flags = flags | (1 << 1) }
        serializer.writeInt32(flags)
        // call: InputGroupCall#d8aa840f
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        // join_as: InputPeer
        serializer.writeRawBytes(this.joinAsPeer.toBytes())
        // invite_hash: flags.1?string
        if ((flags & (1 << 1)) != 0) {
            serializer.writeString(this.inviteHash)
        }
        // params: DataJSON#7d748d04
        serializer.writeUInt32(0x7d748d04)
        serializer.writeString(this.joinPayload)
    }
}

/**
 * phone.joinGroupCallPresentation#cbea6bc4
 * TL: phone.joinGroupCallPresentation#cbea6bc4 call:InputGroupCall params:DataJSON = Updates
 * TL codegen verified: tl_codegen.py from telegram_api.tl (ctor 0xcbea6bc4)
 * iOS ref: GroupCalls.swift _internal_joinGroupCallAsScreencast line 1052
 */
public class PhoneJoinGroupCallPresentation <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var joinPayload: String = ""

    public func getConstructorId(): UInt32 { return 0xcbea6bc4 }

    public func serialize(serializer: TLSerializer) {
        // call: InputGroupCall#d8aa840f
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        // params: DataJSON#7d748d04
        serializer.writeUInt32(0x7d748d04)
        serializer.writeString(this.joinPayload)
    }
}

/**
 * phone.inviteToGroupCall#7b393160
 * TL: phone.inviteToGroupCall#7b393160 call:InputGroupCall users:Vector<InputUser> = Updates
 * TL codegen verified: tl_codegen.py from telegram_api.tl (ctor 0x7b393160)
 * Vector uses VECTOR ctor 0x1cb5c415 then count then items
 * iOS ref: GroupCalls.swift _internal_inviteToGroupCall line 2826
 */
public class PhoneInviteToGroupCall <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    // users: Vec of (userId, accessHash) pairs as InputUser#f21158c6
    public var userIds: ArrayList<Int64> = ArrayList<Int64>()
    public var userAccessHashes: ArrayList<Int64> = ArrayList<Int64>()

    public func getConstructorId(): UInt32 { return 0x7b393160 }

    public func serialize(serializer: TLSerializer) {
        // call: InputGroupCall#d8aa840f
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        // users: Vector<InputUser> — VECTOR ctor 0x1cb5c415 + count + items
        serializer.writeUInt32(0x1cb5c415)
        let cnt = if (this.userIds.size <= this.userAccessHashes.size) { this.userIds.size } else { this.userAccessHashes.size }
        serializer.writeInt32(Int32(cnt))
        var idx: Int64 = 0
        while (idx < cnt) {
            // inputUser#f21158c6 user_id:long access_hash:long
            serializer.writeUInt32(0xf21158c6)
            serializer.writeInt64(this.userIds[idx])
            serializer.writeInt64(this.userAccessHashes[idx])
            idx = idx + 1
        }
    }
}

/**
 * phone.editGroupCallTitle#1ca6ac0a
 * TL: phone.editGroupCallTitle#1ca6ac0a call:InputGroupCall title:string = Updates
 * TL codegen verified: tl_codegen.py from telegram_api.tl (ctor 0x1ca6ac0a)
 * iOS ref: GroupCalls.swift _internal_editGroupCallTitle line 2902
 */
public class PhoneEditGroupCallTitle <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var title: String = ""

    public func getConstructorId(): UInt32 { return 0x1ca6ac0a }

    public func serialize(serializer: TLSerializer) {
        // call: InputGroupCall#d8aa840f
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
        serializer.writeString(this.title)
    }
}

/**
 * phone.exportGroupCallInvite#e6aa647f
 * TL: phone.exportGroupCallInvite#e6aa647f flags:# can_self_unmute:flags.0?true call:InputGroupCall
 *     = phone.ExportedGroupCallInvite
 * TL codegen verified: tl_codegen.py from telegram_api.tl (ctor 0xe6aa647f)
 * Response: phone.exportedGroupCallInvite#204bd158 link:string
 * iOS ref: GroupCalls.swift line 2850/2863
 */
public class PhoneExportGroupCallInvite <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var canSelfUnmute: Bool = false

    public func getConstructorId(): UInt32 { return 0xe6aa647f }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.canSelfUnmute) { flags = flags | (1 << 0) }
        serializer.writeInt32(flags)
        // call: InputGroupCall#d8aa840f
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
    }
}

/**
 * phone.startScheduledGroupCall#5680e342
 * TL: phone.startScheduledGroupCall#5680e342 call:InputGroupCall = Updates
 * TL codegen verified: tl_codegen.py from telegram_api.tl (ctor 0x5680e342)
 * iOS ref: GroupCalls.swift _internal_startScheduledGroupCall line 381
 */
public class PhoneStartScheduledGroupCall <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x5680e342 }

    public func serialize(serializer: TLSerializer) {
        // call: InputGroupCall#d8aa840f
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
    }
}

/**
 * phone.getGroupCallStreamChannels#1ab21940
 * TL: phone.getGroupCallStreamChannels#1ab21940 call:InputGroupCall = phone.GroupCallStreamChannels
 * Response: phone.groupCallStreamChannels#d0e482b2 channels:Vector<GroupCallStreamChannel>
 * groupCallStreamChannel#80eb48af channel:int scale:int last_timestamp_ms:long
 * TL codegen verified: tl_codegen.py from telegram_api.tl (ctor 0x1ab21940)
 */
public class PhoneGetGroupCallStreamChannels <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x1ab21940 }

    public func serialize(serializer: TLSerializer) {
        // call: InputGroupCall#d8aa840f
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(this.callId)
        serializer.writeInt64(this.callAccessHash)
    }
}

/**
 * phone.getGroupCallStreamRtmpUrl#5af4c73a (iOS Api42:12017 verified, python: 1525991226 == 0x5af4c73a)
 * TL: phone.getGroupCallStreamRtmpUrl#5af4c73a flags:# peer:InputPeer revoke:Bool
 *     = phone.GroupCallStreamRtmpUrl
 * Response: phone.groupCallStreamRtmpUrl#2dbf3432 url:string key:string
 * Field resync vs iOS layer:
 *   - Old ctor 0xdeb3abbf was stale.
 *   - flags(Int32) added as first serialized field (currently unused, reserved).
 *   - peer and revoke (boxed Bool via writeBool) unchanged.
 * Backward compat: existing callers set peer + revoke; flags defaults to 0.
 */
public class PhoneGetGroupCallStreamRtmpUrl <: TLObject {
    public var flags: Int32 = 0
    public var peer: TLObject = InputPeerEmpty()
    public var revoke: Bool = false

    public func getConstructorId(): UInt32 { return 0x5af4c73a }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.flags)
        serializer.writeRawBytes(this.peer.toBytes())
        // revoke: Bool (boxed) — boolTrue#997275b5 or boolFalse#bc799737
        serializer.writeBool(this.revoke)
    }
}

// ==================== DH Config ====================

/**
 * messages.getDhConfig — 获取 DH 加密配置 (g, p)
 * Constructor: 0x26cf8950
 * version: int
 * random_length: int
 */
public class MessagesGetDhConfig <: TLObject {
    public var version: Int32 = 0
    public var randomLength: Int32 = 256

    public func getConstructorId(): UInt32 { return 0x26cf8950 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.version)
        serializer.writeInt32(this.randomLength)
    }
}

// ==================== Phase S1: 邀请链接管理 ====================

/**
 * messages.exportChatInvite — 创建新的邀请链接
 * messages.exportChatInvite#a455de90 (Layer 214 correct ID)
 *
 * flags:# legacy_revoke_permanent:flags.2?true request_needed:flags.3?true
 * peer:InputPeer expire_date:flags.0?int usage_limit:flags.1?int title:flags.4?string
 */
public class MessagesExportChatInvite <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var expireDate: Int32 = 0      // flags.0  Unix timestamp，0 = 不设置
    public var usageLimit: Int32 = 0      // flags.1  使用上限，0 = 无限
    public var legacyRevokePermanent: Bool = false  // flags.2
    public var requestNeeded: Bool = false            // flags.3
    public var title: String = ""                      // flags.4

    public func getConstructorId(): UInt32 { return 0xa455de90 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.expireDate > 0) { flags = flags | 1 }
        if (this.usageLimit > 0) { flags = flags | 2 }
        if (this.legacyRevokePermanent) { flags = flags | 4 }
        if (this.requestNeeded) { flags = flags | 8 }
        if (this.title.size > 0) { flags = flags | 16 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        if (this.expireDate > 0) {
            serializer.writeInt32(this.expireDate)
        }
        if (this.usageLimit > 0) {
            serializer.writeInt32(this.usageLimit)
        }
        if (this.title.size > 0) {
            serializer.writeString(this.title)
        }
    }
}

/**
 * messages.getExportedChatInvites — 获取邀请链接列表
 * Constructor: 0xa2b5a3f6
 *
 * flags:# revoked:flags.3?true peer:InputPeer admin_id:InputUser
 * offset_date:flags.2?int offset_link:flags.2?string limit:int
 */
public class MessagesGetExportedChatInvites <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var adminId: TLObject = InputUserSelf()  // P2-168 fix: must be InputUser, use InputUserSelf for self
    public var revoked: Bool = false   // flags.3  获取已撤销链接
    public var offsetDate: Int32 = 0   // flags.2
    public var offsetLink: String = "" // flags.2
    public var limit: Int32 = 50

    public func getConstructorId(): UInt32 { return 0xa2b5a3f6 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.offsetDate > 0) { flags = flags | 4 }
        if (this.revoked) { flags = flags | 8 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeRawBytes(this.adminId.toBytes())
        if (this.offsetDate > 0) {
            serializer.writeInt32(this.offsetDate)
            serializer.writeString(this.offsetLink)
        }
        serializer.writeInt32(this.limit)
    }
}

/**
 * messages.editExportedChatInvite — 编辑或撤销邀请链接
 * Constructor: 0xbdca2f75
 * iOS ref: Api42.swift:6263 buffer.appendInt32(-1110823051) -> 0xbdca2f75
 *
 * flags:# revoked:flags.2?true peer:InputPeer link:string
 * expire_date:flags.0?int usage_limit:flags.1?int
 * request_needed:flags.3?Bool title:flags.4?string
 *
 * NOTE: request_needed is flags.3?Bool — when bit 3 is set a boxed Bool
 * (boolTrue#997275b5 / boolFalse#bc799737) must follow in the bitstream.
 * iOS: requestNeeded!.serialize(buffer, true) at flags & (1<<3).
 */
public class MessagesEditExportedChatInvite <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var link: String = ""
    public var revoked: Bool = false             // flags.2  撤销链接 (bit only)
    public var expireDate: Int32 = 0             // flags.0?int
    public var usageLimit: Int32 = 0             // flags.1?int
    public var requestNeeded: Bool = false       // flags.3?Bool payload value
    public var hasRequestNeeded: Bool = false    // true = include requestNeeded Bool in payload
    public var title: String = ""               // flags.4?string

    public func getConstructorId(): UInt32 { return 0xbdca2f75 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.expireDate > 0) { flags = flags | 1 }         // bit 0: expire_date?int
        if (this.usageLimit > 0) { flags = flags | 2 }         // bit 1: usage_limit?int
        if (this.revoked) { flags = flags | 4 }                // bit 2: revoked (no payload)
        if (this.hasRequestNeeded) { flags = flags | 8 }       // bit 3: request_needed?Bool
        if (this.title.size > 0) { flags = flags | 16 }        // bit 4: title?string
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.link)
        if (this.expireDate > 0) {
            serializer.writeInt32(this.expireDate)
        }
        if (this.usageLimit > 0) {
            serializer.writeInt32(this.usageLimit)
        }
        if (this.hasRequestNeeded) {
            serializer.writeBool(this.requestNeeded)
        }
        if (this.title.size > 0) {
            serializer.writeString(this.title)
        }
    }
}

/**
 * messages.deleteExportedChatInvite#d464a42b peer:InputPeer link:string = Bool
 */
public class MessagesDeleteExportedChatInvite <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var link: String = ""

    public func getConstructorId(): UInt32 { return 0xd464a42b }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.link)
    }
}

/**
 * messages.deleteRevokedExportedChatInvites — 批量删除全部已撤销的邀请链接（P2-170）
 * Constructor: 0x56987bd5
 * iOS ref: Api42.swift:6054 buffer.appendInt32(1452833749) -> 0x56987bd5
 *
 * peer:InputPeer admin_id:InputUser = Bool
 *
 * 删除指定 peer 下、由指定 admin 创建的全部撤销链接。
 * 对于"全部撤销"场景，admin_id 传 InputUserSelf。
 */
public class MessagesDeleteRevokedExportedChatInvites <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var adminId: TLObject = InputUserSelf()  // InputUser; use InputUserSelf for self

    public func getConstructorId(): UInt32 { return 0x56987bd5 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeRawBytes(this.adminId.toBytes())
    }
}

/**
 * messages.getChatInviteImporters#df04dd4e
 * TL schema (telegram_api.tl:2332):
 *   flags:#
 *   requested:flags.0?true          bit 0 — filter join requests (no payload)
 *   subscription_expired:flags.3?true bit 3 — filter expired subscriptions (no payload)
 *   peer:InputPeer                   always written
 *   link:flags.1?string              bit 1 — optional invite link filter
 *   q:flags.2?string                 bit 2 — optional search query
 *   offset_date:int                  always written (mandatory, no flags guard)
 *   offset_user:InputUser            always written (mandatory, no flags guard)
 *   limit:int                        always written
 * iOS ref: Api42.swift:6710-6732
 */
public class MessagesGetChatInviteImporters <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var link: String = ""
    public var requested: Bool = false
    public var subscriptionExpired: Bool = false
    public var q: String = ""
    public var offsetDate: Int32 = 0
    public var offsetUser: TLObject = InputPeerEmpty()
    public var limit: Int32 = 50

    public func getConstructorId(): UInt32 { return 0xdf04dd4e }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.requested) { flags = flags | 1 }           // bit 0: requested:flags.0?true
        if (this.link.size > 0) { flags = flags | 2 }       // bit 1: link:flags.1?string
        if (this.q.size > 0) { flags = flags | 4 }          // bit 2: q:flags.2?string
        if (this.subscriptionExpired) { flags = flags | 8 } // bit 3: subscription_expired:flags.3?true
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        if (this.link.size > 0) {
            serializer.writeString(this.link)
        }
        if (this.q.size > 0) {
            serializer.writeString(this.q)
        }
        serializer.writeInt32(this.offsetDate)       // offset_date:int — always written
        serializer.writeRawBytes(this.offsetUser.toBytes()) // offset_user:InputUser — always written
        serializer.writeInt32(this.limit)
    }
}

// ==================== P2-138: 入群请求审批 ====================

/**
 * messages.hideChatJoinRequest#7fe7e815
 * iOS ref: Api42.swift:8268 buffer.appendInt32(2145904661) -> 0x7FE7E815
 * flags:# approved:flags.0?true peer:InputPeer user_id:InputUser = Updates
 *
 * 批准或拒绝单个入群请求。
 * approved=true → 批准；approved 缺失(flags.0=0) → 拒绝
 */
public class MessagesHideChatJoinRequest <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var userId: TLObject = InputPeerEmpty()  // InputUser
    public var approved: Bool = false

    public func getConstructorId(): UInt32 { return 0x7fe7e815 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.approved) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeRawBytes(this.userId.toBytes())
    }
}

/**
 * messages.hideAllChatJoinRequests#e085f4ea
 * iOS ref: Api42.swift:8249 buffer.appendInt32(-528091926) -> 0xE085F4EA
 * flags:# approved:flags.0?true peer:InputPeer link:flags.1?string = Updates
 *
 * 批量批准或拒绝全部入群请求（可按链接过滤）。
 * approved=true → 全部批准；link 指定时只处理该链接的请求。
 */
public class MessagesHideAllChatJoinRequests <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var approved: Bool = false
    public var link: String = ""   // flags.1?string — 空字符串表示不过滤

    public func getConstructorId(): UInt32 { return 0xe085f4ea }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.approved) { flags = flags | 1 }
        if (this.link.size > 0) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        if (this.link.size > 0) {
            serializer.writeString(this.link)
        }
    }
}

// ==================== Phase Q10: 消息置顶 ====================

/**
 * messages.updatePinnedMessage — 置顶/取消置顶消息
 * 
 * TL Schema: messages.updatePinnedMessage#d2aaf7ec 
 *   flags:# silent:flags.0?true unpin:flags.1?true pm_oneside:flags.2?true 
 *   peer:InputPeer id:int = Updates;
 * 
 * @param peer 对话的 InputPeer
 * @param id 要置顶的消息 ID
 * @param unpin 是否取消置顶（true = 取消）
 * @param silent 是否静默（不通知群成员）
 */
// ==================== Phase T4.1: Notification Settings ====================

/**
 * account.getNotifySettings#12b3ad31 peer:InputNotifyPeer = PeerNotifySettings
 */
public class AccountGetNotifySettings <: TLObject {
    public var peerType: String = "users"  // "users", "chats", "broadcasts"
    
    public func getConstructorId(): UInt32 { return 0x12b3ad31 }
    
    public func serialize(serializer: TLSerializer) {
        // InputNotifyPeer based on type
        if (this.peerType == "users") {
            serializer.writeUInt32(0x193b4417)  // inputNotifyUsers
        } else if (this.peerType == "chats") {
            serializer.writeUInt32(0x4a95e84e)  // inputNotifyChats
        } else if (this.peerType == "broadcasts") {
            serializer.writeUInt32(0xb1db7c7e)  // inputNotifyBroadcasts
        } else {
            serializer.writeUInt32(0x193b4417)  // default to users
        }
    }
}

/**
 * ic_nsnd_notify_exceptions_rpc: account.getNotifyExceptions#53577479
 * flags:# compare_sound:flags.1?true peer:flags.0?InputNotifyPeer = Updates
 * 对位源 NotificationExceptionsList.swift:22-26（isStories=false 分支固定传 compare_sound,
 * 不传 peer → 取全部分类的例外列表）。
 * 本类只负责 RPC 定义本身；返回体 Updates 的解析、按分类分组、页面接线归属后续任务
 * （services/NotificationMuteSettingsService.cj / services/TelegramCoreSettingsService.cj），
 * 不在本条范围内。
 */
public class AccountGetNotifyExceptions <: TLObject {
    public func getConstructorId(): UInt32 { return 0x53577479 }

    public func serialize(serializer: TLSerializer) {
        // flags: bit1 (compare_sound) 固定置位；bit0 (peer) 不置 — 源侧固定传 nil
        let flags: Int32 = 1 << 1
        serializer.writeInt32(flags)
    }
}

/**
 * account.resetNotifySettings#db7e1747 = Bool
 * iOS ManagedGlobalNotificationSettings.swift:23 resetPeerNotificationSettings —— 清空服务端
 * 全部会话级通知设置与例外（Settings → Notifications → Reset All Notifications）。
 */
public class AccountResetNotifySettings <: TLObject {
    public func getConstructorId(): UInt32 { return 0xdb7e1747 }

    public func serialize(serializer: TLSerializer) {
        // 无字段
    }
}

/**
 * account.updateNotifySettings#84be5b93 peer:InputNotifyPeer settings:InputPeerNotifySettings = Bool
 */
public class AccountUpdateNotifySettings <: TLObject {
    public var peerType: String = "users"
    public var muteUntil: Int32 = 0       // 0 = unmute, 2147483647 = mute forever
    public var showPreviews: Bool = true
    public var silent: Bool = false
    // ic_nsnd_tl_sound_flag: 0 = 不携带 sound（flags.3 不置）；-1 = 显式静音
    // (notificationSoundNone#6f0c34df)；其余非 0 值 = 已选铃声 id
    // (notificationSoundRingtone#ff6c8049 id:long)。
    public var soundId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x84be5b93 }

    public func serialize(serializer: TLSerializer) {
        // InputNotifyPeer
        if (this.peerType == "users") {
            serializer.writeUInt32(0x193b4417)
        } else if (this.peerType == "chats") {
            serializer.writeUInt32(0x4a95e84e)
        } else if (this.peerType == "broadcasts") {
            serializer.writeUInt32(0xb1db7c7e)
        } else {
            serializer.writeUInt32(0x193b4417)
        }
        // InputPeerNotifySettings#cacb6ae2 flags:# show_previews:flags.0?Bool silent:flags.1?Bool mute_until:flags.2?int sound:flags.3?NotificationSound
        var flags: Int32 = 0
        flags = flags | 1   // bit 0: show_previews present
        flags = flags | 2   // bit 1: silent present
        flags = flags | 4   // bit 2: mute_until present
        if (this.soundId != 0) {
            flags = flags | (1 << 3)   // bit 3: sound present
        }
        serializer.writeUInt32(0xcacb6ae2)
        serializer.writeInt32(flags)
        // show_previews (boolTrue / boolFalse) — bit 0
        if (this.showPreviews) {
            serializer.writeUInt32(0x997275b5)  // boolTrue
        } else {
            serializer.writeUInt32(0xbc799737)  // boolFalse
        }
        // silent (boolTrue / boolFalse) — bit 1 (before mute_until)
        if (this.silent) {
            serializer.writeUInt32(0x997275b5)
        } else {
            serializer.writeUInt32(0xbc799737)
        }
        // mute_until — bit 2
        serializer.writeInt32(this.muteUntil)
        // sound (boxed NotificationSound) — bit 3
        if (this.soundId != 0) {
            if (this.soundId == -1) {
                serializer.writeUInt32(0x6f0c34df)  // notificationSoundNone
            } else {
                serializer.writeUInt32(0xff6c8049)  // notificationSoundRingtone#ff6c8049
                serializer.writeInt64(this.soundId)
            }
        }
    }
}

/**
 * Phase P1-3: account.updateNotifySettings — 单个对话的静音设置
 * 使用 inputNotifyPeer#b8bc5b0c(peer:InputPeer) 代替全局分类
 */
public class AccountUpdatePeerNotifySettings <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var muteUntil: Int32 = 0
    public var showPreviews: Bool = true
    public var silent: Bool = false
    // false 时不携带对应可选字段（flags.0 / flags.1 不置）。iOS 静音开关只改 mute_until，
    // show_previews 仅在显式设置时发送、silent 恒为 nil（ManagedPendingPeerNotificationSettings.swift:240）。
    public var includeShowPreviews: Bool = true
    public var includeSilent: Bool = true

    public func getConstructorId(): UInt32 { return 0x84be5b93 }

    public func serialize(serializer: TLSerializer) {
        // inputNotifyPeer#b8bc5b0c peer:InputPeer
        serializer.writeUInt32(0xb8bc5b0c)
        serializer.writeRawBytes(this.peer.toBytes())
        // InputPeerNotifySettings#cacb6ae2 flags:# show_previews:flags.0?Bool silent:flags.1?Bool mute_until:flags.2?int sound:flags.3?NotificationSound
        var flags: Int32 = 0
        if (this.includeShowPreviews) { flags = flags | 1 }   // bit 0: show_previews present
        if (this.includeSilent) { flags = flags | 2 }   // bit 1: silent present
        flags = flags | 4   // bit 2: mute_until present
        serializer.writeUInt32(0xcacb6ae2)
        serializer.writeInt32(flags)
        // show_previews — bit 0
        if (this.includeShowPreviews) {
            if (this.showPreviews) {
                serializer.writeUInt32(0x997275b5)  // boolTrue
            } else {
                serializer.writeUInt32(0xbc799737)  // boolFalse
            }
        }
        // silent — bit 1 (before mute_until)
        if (this.includeSilent) {
            if (this.silent) {
                serializer.writeUInt32(0x997275b5)
            } else {
                serializer.writeUInt32(0xbc799737)
            }
        }
        // mute_until — bit 2
        serializer.writeInt32(this.muteUntil)
    }
}

/**
 * Phase P3-1: account.updateProfile — 更新用户资料（姓名/bio）
 * Constructor: 0x78515775
 * flags:# first_name:flags.0?string last_name:flags.1?string about:flags.2?string
 */
public class AccountUpdateProfile <: TLObject {
    public var firstName: ?String = None
    public var lastName: ?String = None
    public var about: ?String = None

    public func getConstructorId(): UInt32 { return 0x78515775 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        match (this.firstName) {
            case Some(_) => flags = flags | 1
            case None => ()
        }
        match (this.lastName) {
            case Some(_) => flags = flags | 2
            case None => ()
        }
        match (this.about) {
            case Some(_) => flags = flags | 4
            case None => ()
        }
        serializer.writeInt32(flags)
        match (this.firstName) {
            case Some(v) => serializer.writeString(v)
            case None => ()
        }
        match (this.lastName) {
            case Some(v) => serializer.writeString(v)
            case None => ()
        }
        match (this.about) {
            case Some(v) => serializer.writeString(v)
            case None => ()
        }
    }
}

// ==================== Phase T4.2: Privacy Settings ====================

/**
 * account.getPrivacy#dadbc950 key:InputPrivacyKey = account.PrivacyRules
 * 
 * InputPrivacyKey constructors:
 *   inputPrivacyKeyStatusTimestamp#4f96cb18
 *   inputPrivacyKeyChatInvite#bdfb0426
 *   inputPrivacyKeyPhoneCall#fabadc5f
 *   inputPrivacyKeyPhoneP2P#db9e70d2
 *   inputPrivacyKeyForwards#a4dd4c08
 *   inputPrivacyKeyProfilePhoto#5719bacc
 *   inputPrivacyKeyPhoneNumber#0352dafa
 *   inputPrivacyKeyAddedByPhone#d1219bdd
 *   inputPrivacyKeyVoiceMessages#aee69d68
 *   inputPrivacyKeyAbout#3823cc40
 */
public class AccountGetPrivacy <: TLObject {
    public var keyConstructor: UInt32 = 0x4f96cb18  // default: statusTimestamp
    
    public func getConstructorId(): UInt32 { return 0xdadbc950 }
    
    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(this.keyConstructor)
    }
}

/**
 * account.setPrivacy#c9f81ce8 key:InputPrivacyKey rules:Vector<InputPrivacyRule> = account.PrivacyRules
 *
 * InputPrivacyRule constructors (tl_codegen verified, telegram_api.tl:585-596):
 *   inputPrivacyValueAllowAll#184b35ce
 *   inputPrivacyValueAllowContacts#0d09e07b
 *   inputPrivacyValueDisallowAll#d66b66c9
 *   inputPrivacyValueDisallowContacts#0ba52007
 *   inputPrivacyValueAllowUsers#131cc67f      users:Vector<InputUser>
 *   inputPrivacyValueDisallowUsers#90110467   users:Vector<InputUser>
 *   inputPrivacyValueAllowChatParticipants#840649cf  chats:Vector<long>
 *   inputPrivacyValueDisallowChatParticipants#e94f0f86 chats:Vector<long>
 *   inputPrivacyValueAllowCloseFriends#2f453e49
 *   inputPrivacyValueAllowPremium#77cdc9f1
 *
 * Serialization strategy: rules list is built externally; serialize emits the full vector.
 * For simple rules (no user/chat lists): set ruleConstructors with one entry.
 * For rules with user/chat lists: set ruleConstructors + ruleUserIds/ruleDisallowUserIds
 * or ruleChatIds/ruleDisallowChatIds. Allow and disallow chat-participant rules can both be
 * present in the same request (source ref: enableContacts branch in
 * UpdatedAccountPrivacySettings.swift:566-590) so they need distinct id lists, mirroring the
 * existing ruleUserIds/ruleDisallowUserIds split.
 */
public class AccountSetPrivacy <: TLObject {
    public var keyConstructor: UInt32 = 0x4f96cb18
    public var ruleConstructors: ArrayList<UInt32> = ArrayList<UInt32>()
    public var ruleUserIds: ArrayList<Int64> = ArrayList<Int64>()
    public var ruleDisallowUserIds: ArrayList<Int64> = ArrayList<Int64>()
    public var ruleChatIds: ArrayList<Int64> = ArrayList<Int64>()
    public var ruleDisallowChatIds: ArrayList<Int64> = ArrayList<Int64>()

    public func getConstructorId(): UInt32 { return 0xc9f81ce8 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(this.keyConstructor)
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.ruleConstructors.size))
        var i: Int64 = 0
        while (i < this.ruleConstructors.size) {
            let ctor = this.ruleConstructors[i]
            serializer.writeUInt32(ctor)
            if (ctor == 0x131cc67f) {
                // inputPrivacyValueAllowUsers: uses ruleUserIds
                serializer.writeUInt32(0x1cb5c415)
                serializer.writeInt32(Int32(this.ruleUserIds.size))
                var j: Int64 = 0
                while (j < this.ruleUserIds.size) {
                    serializer.writeRawBytes(makeInputUser(this.ruleUserIds[j]))
                    j = j + 1
                }
            } else if (ctor == 0x90110467) {
                // inputPrivacyValueDisallowUsers: uses ruleDisallowUserIds
                serializer.writeUInt32(0x1cb5c415)
                serializer.writeInt32(Int32(this.ruleDisallowUserIds.size))
                var j: Int64 = 0
                while (j < this.ruleDisallowUserIds.size) {
                    serializer.writeRawBytes(makeInputUser(this.ruleDisallowUserIds[j]))
                    j = j + 1
                }
            } else if (ctor == 0x840649cf) {
                // inputPrivacyValueAllowChatParticipants: uses ruleChatIds
                serializer.writeUInt32(0x1cb5c415)
                serializer.writeInt32(Int32(this.ruleChatIds.size))
                var j: Int64 = 0
                while (j < this.ruleChatIds.size) {
                    serializer.writeInt64(this.ruleChatIds[j])
                    j = j + 1
                }
            } else if (ctor == 0xe94f0f86) {
                // inputPrivacyValueDisallowChatParticipants: uses ruleDisallowChatIds
                serializer.writeUInt32(0x1cb5c415)
                serializer.writeInt32(Int32(this.ruleDisallowChatIds.size))
                var j: Int64 = 0
                while (j < this.ruleDisallowChatIds.size) {
                    serializer.writeInt64(this.ruleDisallowChatIds[j])
                    j = j + 1
                }
            }
            i = i + 1
        }
    }
}

func makeInputUser(userId: Int64): Array<Byte> {
    let s = TLSerializer()
    s.writeUInt32(0xf21158c6)
    s.writeInt64(userId)
    s.writeInt64(0)
    return s.getBytes()
}

/**
 * contacts.getBlocked#9a868f80 flags:# my_stories_from:flags.0?true offset:int limit:int = contacts.Blocked
 */
public class ContactsGetBlocked <: TLObject {
    public var offset: Int32 = 0
    public var limit: Int32 = 100
    
    public func getConstructorId(): UInt32 { return 0x9a868f80 }
    
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags
        serializer.writeInt32(this.offset)
        serializer.writeInt32(this.limit)
    }
}

// ==================== Phase T4.8: Language Settings ====================

/**
 * langpack.getLanguages#42c6978f lang_pack:string = Vector<LangPackLanguage>
 * Field name: lang_pack (platform identifier, not language code)
 */
public class LangpackGetLanguages <: TLObject {
    public var langPack: String = ""

    public func getConstructorId(): UInt32 { return 0x42c6978f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.langPack)
    }
}

/**
 * langpack.getStrings#efea3803 lang_pack:string lang_code:string keys:Vector<string> = Vector<LangPackString>
 */
public class LangpackGetStrings <: TLObject {
    public var langPack: String = "android"
    public var langCode: String = "en"
    public var keys: ArrayList<String> = ArrayList<String>()

    public func getConstructorId(): UInt32 { return 0xefea3803 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.langPack)
        serializer.writeString(this.langCode)
        // Vector<string>
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.keys.size))
        for (k in this.keys) {
            serializer.writeString(k)
        }
    }
}

// ==================== Phase P2-164: Localization ====================

/**
 * help.getCountriesList#735787a8 lang_code:string hash:int = help.CountriesList
 * (verified by tl_codegen.py from telegram_api.tl)
 */
public class HelpGetCountriesList <: TLObject {
    public var langCode: String = ""
    public var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x735787a8 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.langCode)
        serializer.writeInt32(this.hash)
    }
}

/**
 * langpack.getLangPack#f2f2330a lang_pack:string lang_code:string = LangPackDifference
 * (verified by tl_codegen.py from telegram_api.tl)
 */
public class LangpackGetLangPack <: TLObject {
    public var langPack: String = ""
    public var langCode: String = ""

    public func getConstructorId(): UInt32 { return 0xf2f2330a }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.langPack)
        serializer.writeString(this.langCode)
    }
}

/**
 * langpack.getDifference#cd984aa5 lang_pack:string lang_code:string from_version:int = LangPackDifference
 * (verified by tl_codegen.py from telegram_api.tl)
 */
public class LangpackGetDifference <: TLObject {
    public var langPack: String = ""
    public var langCode: String = ""
    public var fromVersion: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xcd984aa5 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.langPack)
        serializer.writeString(this.langCode)
        serializer.writeInt32(this.fromVersion)
    }
}

/**
 * langpack.getLanguage#6a596502 lang_pack:string lang_code:string = LangPackLanguage
 * (verified by tl_codegen.py from telegram_api.tl)
 */
public class LangpackGetLanguage <: TLObject {
    public var langPack: String = ""
    public var langCode: String = ""

    public func getConstructorId(): UInt32 { return 0x6a596502 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.langPack)
        serializer.writeString(this.langCode)
    }
}

public class MessagesUpdatePinnedMessage <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var id: Int32 = 0
    public var unpin: Bool = false
    public var silent: Bool = true  // 默认静默
    // P2-122: pm_oneside — 仅为自己置顶（私聊），不通知对方
    // iOS ref: Api42.swift updatePinnedMessage flags bit 2
    // python3 -c "print(hex(-760547348 & 0xFFFFFFFF))" → 0xd2aaf7ec ✓
    public var pmOneside: Bool = false

    public func getConstructorId(): UInt32 { return 0xd2aaf7ec }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.silent) { flags = flags | 1 }       // bit 0: silent
        if (this.unpin) { flags = flags | 2 }         // bit 1: unpin
        if (this.pmOneside) { flags = flags | 4 }     // bit 2: pm_oneside
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.id)
    }
}

// ==================== Phase P3-2: Username Management ====================

/**
 * account.checkUsername#2714d86c username:string = Bool
 * 检查用户名是否可用
 */
public class AccountCheckUsername <: TLObject {
    public var username: String = ""

    public func getConstructorId(): UInt32 { return 0x2714d86c }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.username)
    }
}

/**
 * account.updateUsername#3e0bdd7c username:string = User
 * 更新当前用户的用户名
 */
public class AccountUpdateUsername <: TLObject {
    public var username: String = ""

    public func getConstructorId(): UInt32 { return 0x3e0bdd7c }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.username)
    }
}

// ==================== Phase P4-1: 2FA Auth ====================

/**
 * account.getPassword#548a30f5 = account.Password
 * 获取当前账号的 2FA 密码参数 (SRP)
 */
public class AccountGetPassword <: TLObject {
    public func getConstructorId(): UInt32 { return 0x548a30f5 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * inputCheckPasswordSRP#d27ff082 srp_id:long A:bytes M1:bytes = InputCheckPasswordSRP
 */
public class InputCheckPasswordSRP <: TLObject {
    public var srpId: Int64 = 0
    public var srpA: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var srpM1: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0xd27ff082 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.srpId)
        serializer.writeBytes(this.srpA)
        serializer.writeBytes(this.srpM1)
    }
}

/**
 * auth.checkPassword#d18b4d16 password:InputCheckPasswordSRP = auth.Authorization
 * 使用 SRP 密码验证完成 2FA 登录
 */
public class AuthCheckPassword <: TLObject {
    public var password: InputCheckPasswordSRP = InputCheckPasswordSRP()

    public func getConstructorId(): UInt32 { return 0xd18b4d16 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(this.password.getConstructorId())
        this.password.serialize(serializer)
    }
}

/**
 * auth.requestPasswordRecovery#d897bc66 = auth.PasswordRecovery
 * Request recovery code for 2FA (only if recovery email configured)
 */
public class AuthRequestPasswordRecovery <: TLObject {
    public func getConstructorId(): UInt32 { return 0xd897bc66 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * auth.recoverPassword#37096c70 flags:# code:string new_settings:flags.0?account.PasswordInputSettings = auth.Authorization
 * Reset 2FA using recovery code from email
 */
public class AuthRecoverPassword <: TLObject {
    public var code: String = ""

    public func getConstructorId(): UInt32 { return 0x37096c70 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags: no new_settings
        serializer.writeString(this.code)
    }
}

/**
 * account.deleteAccount#a2c0cf74 flags:# reason:string password:flags.0?InputCheckPasswordSRP = Bool
 * Delete account. Omit password for 2FA accounts to trigger 7-day delayed deletion.
 */
public class AccountDeleteAccount <: TLObject {
    public var reason: String = ""
    public var hasPassword: Bool = false
    public var password: InputCheckPasswordSRP = InputCheckPasswordSRP()

    public func getConstructorId(): UInt32 { return 0xa2c0cf74 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasPassword) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeString(this.reason)
        if (this.hasPassword) {
            serializer.writeUInt32(this.password.getConstructorId())
            this.password.serialize(serializer)
        }
    }
}

// ==================== Phase P4-6: 2FA Password Settings ====================

/**
 * account.updatePasswordSettings#a59b102f 
 * password:InputCheckPasswordSRP new_settings:account.PasswordInputSettings = Bool
 * 
 * account.passwordInputSettings#c23727c9
 *   flags:# new_algo:flags.0?PasswordKdfAlgo new_password_hash:flags.0?bytes 
 *   hint:flags.0?string email:flags.1?string
 */
public class AccountUpdatePasswordSettings <: TLObject {
    // Current password proof (empty if no password set)
    public var hasCurrentPassword: Bool = false
    public var currentPasswordSRP: InputCheckPasswordSRP = InputCheckPasswordSRP()

    // New settings
    public var setNewPassword: Bool = false   // flags.0: set new password
    public var algoSalt1: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var algoSalt2: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var algoG: Int32 = 0
    public var algoP: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var newPasswordHash: Array<Byte> = Array<Byte>(0, repeat: 0)  // v = g^x mod p
    public var hint: String = ""
    public var setEmail: Bool = false          // flags.1: set email
    public var email: String = ""
    // flags.2: new_secure_settings — SecureSecretSettings
    // secureSecretSettings#1527bcac secure_algo:SecurePasswordKdfAlgo secure_secret:bytes secure_secret_id:long
    // SecurePasswordKdfAlgoSHA512#86471d92 salt:bytes
    public var setSecureSecret: Bool = false
    public var secureAlgoSalt: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var secureSecret: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var secureSecretId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xa59b102f }

    public func serialize(serializer: TLSerializer) {
        // password: InputCheckPasswordSRP (boxed)
        if (this.hasCurrentPassword) {
            serializer.writeUInt32(this.currentPasswordSRP.getConstructorId())
            this.currentPasswordSRP.serialize(serializer)
        } else {
            // inputCheckPasswordEmpty#9880f658 = InputCheckPasswordSRP
            serializer.writeUInt32(0x9880f658)
        }

        // new_settings: account.passwordInputSettings#c23727c9
        serializer.writeUInt32(0xc23727c9)
        var flags: Int32 = 0
        if (this.setNewPassword) { flags = flags | 1 }
        if (this.setEmail) { flags = flags | 2 }
        if (this.setSecureSecret) { flags = flags | 4 }
        serializer.writeInt32(flags)

        if (this.setNewPassword) {
            // new_algo: passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow
            // Constructor: 0x3a912d4a
            serializer.writeUInt32(0x3a912d4a)
            serializer.writeBytes(this.algoSalt1)
            serializer.writeBytes(this.algoSalt2)
            serializer.writeInt32(this.algoG)
            serializer.writeBytes(this.algoP)

            // new_password_hash: bytes (the verifier v, or empty to disable)
            serializer.writeBytes(this.newPasswordHash)

            // hint: string
            serializer.writeString(this.hint)
        }

        if (this.setEmail) {
            serializer.writeString(this.email)
        }

        if (this.setSecureSecret) {
            // new_secure_settings: secureSecretSettings#1527bcac
            serializer.writeUInt32(0x1527bcac)
            // secure_algo: SecurePasswordKdfAlgoSHA512#86471d92 salt:bytes
            serializer.writeUInt32(0x86471d92)
            serializer.writeBytes(this.secureAlgoSalt)
            // secure_secret: bytes
            serializer.writeBytes(this.secureSecret)
            // secure_secret_id: long
            serializer.writeInt64(this.secureSecretId)
        }
    }
}

/**
 * account.resetPassword#9308ce1b = account.ResetPasswordResult
 * Initiate 2FA password reset (logged-in user). Returns Ok / RequestedWait(until_date) / FailedWait(retry_date)
 */
public class AccountResetPassword <: TLObject {
    public func getConstructorId(): UInt32 { return 0x9308ce1b }
    public func serialize(serializer: TLSerializer) {}
}

// ==================== Settings: account.getAccountTTL / setAccountTTL ====================

/**
 * account.daysTTL#b8d0afdf days:int = account.AccountDaysTTL
 * 账号自毁天数（0=禁用）
 */
public class AccountDaysTTL <: TLObject {
    public var days: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xb8d0afdf }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.days)
    }
}

/**
 * account.getAccountTTL#8fc711d = account.AccountDaysTTL
 * 获取账号自毁天数
 */
public class AccountGetAccountTTL <: TLObject {
    public func getConstructorId(): UInt32 { return 0x8fc711d }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * account.setAccountTTL#2442485e ttl:AccountDaysTTL = Bool
 * 设置账号自毁天数（不活跃后自动删除账号）
 */
public class AccountSetAccountTTL <: TLObject {
    public var days: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x2442485e }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0xb8d0afdf)  // account.daysTTL
        serializer.writeInt32(this.days)
    }
}

/**
 * diag-suite_settings_data_storage-round3-data_storage_root-batch.md §F-B 改动 1：
 * account.getContentSettings#8b9b4dae = account.ContentSettings（无参）。
 * 响应 account.contentSettings#57e28221 flags:# sensitive_enabled:flags.0?true
 * sensitive_can_change:flags.1?true —— 位定义逐位照抄源侧 ContentSettings.swift:66
 * （不在本类里解析，调用方 SettingsService.getContentSettingsConfiguration() 直接读
 * flags 位）。ctor 值已用源侧 Api42.swift:555-558 的 buffer.appendInt32(-1952756306)
 * 复核（-1952756306 & 0xFFFFFFFF == 0x8b9b4dae）。
 */
public class AccountGetContentSettings <: TLObject {
    public func getConstructorId(): UInt32 { return 0x8b9b4dae }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * diag-suite_settings_data_storage-round3-data_storage_root-batch.md §F-B 改动 1：
 * account.setContentSettings#b574b16b flags:# sensitive_enabled:flags.0?true = Bool。
 * flags 位 0 = sensitiveContentEnabled（源侧 ContentSettings.swift:76-78，本类不含
 * 位 1——`canAdjustSensitiveContent` 只读不写，源侧同样从不在 setContentSettings 里
 * 设置该位）。ctor 值已用源侧 Api42.swift:1501-1505 的
 * buffer.appendInt32(-1250643605) 复核（-1250643605 & 0xFFFFFFFF == 0xb574b16b）。
 */
public class AccountSetContentSettings <: TLObject {
    public var sensitiveEnabled: Bool = false

    public func getConstructorId(): UInt32 { return 0xb574b16b }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.sensitiveEnabled) { flags = flags | 1 }
        serializer.writeInt32(flags)
    }
}

// ==================== Phase P4-2: Block/Unblock ====================

/**
 * contacts.block#2e2e8734 flags:# my_stories_from:flags.0?true id:InputPeer = Bool
 */
public class ContactsBlock <: TLObject {
    public var id: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0x2e2e8734 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags = 0 (main blocklist)
        serializer.writeRawBytes(this.id.toBytes())
    }
}

/**
 * contacts.unblock#b550d328 flags:# my_stories_from:flags.0?true id:InputPeer = Bool
 */
public class ContactsUnblock <: TLObject {
    public var id: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0xb550d328 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags = 0
        serializer.writeRawBytes(this.id.toBytes())
    }
}

/**
 * contacts.resetSaved#879537f1 = Bool
 */
public class ContactsResetSaved <: TLObject {
    public func getConstructorId(): UInt32 { return 0x879537f1 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * payments.clearSavedInfo#d83d70c1 flags:# credentials:flags.0?true info:flags.1?true = Bool
 * diag-suite_settings_privacy-TC-0127.md P4（DataPrivacySettingsPage「Clear payment &
 * shipping info」）：常量与 flags 位含义取自源侧生成层
 * submodules/TelegramApi/Sources/Api42.swift:11013 `clearSavedInfo(flags:)`
 * （buffer.appendInt32(-667062079) → 0xd83d70c1）+
 * submodules/TelegramCore/Sources/TelegramEngine/Payments/BotPaymentForm.swift:974
 * `_internal_clearBotPaymentInfo`（bit0=paymentInfo/credentials, bit1=shippingInfo）。
 * diag-suite_settings_privacy-TC-0130.md RC-2：源侧两位是逐位可选的掩码
 * （`DataPrivacySettingsController.swift:355-437` 两个 `ActionSheetCheckboxItem` 按各自
 * 勾选结果组装 flags），不是"单一按钮一次清两者"——本类据此提供两个可分别置位的字段，
 * 不再固定传两位全 1。
 */
public class PaymentsClearSavedInfo <: TLObject {
    public var credentials: Bool = true
    public var info: Bool = true

    public func getConstructorId(): UInt32 { return 0xd83d70c1 }
    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.credentials) { flags = flags | 1 }
        if (this.info) { flags = flags | 2 }
        serializer.writeInt32(flags)
    }
}

/**
 * contacts.getLocated#d348bc44 flags:# background:flags.1?true geo_point:InputGeoPoint self_expires:flags.0?int = Updates
 */
public class ContactsGetLocated <: TLObject {
    public var geoPoint: InputGeoPoint = InputGeoPoint()

    public func getConstructorId(): UInt32 { return 0xd348bc44 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags = 0 (no optional fields)
        serializer.writeRawBytes(this.geoPoint.toBytes())
    }
}

// ==================== Folders: Archive (folder_id 0=main, 1=archive) ====================

/**
 * inputFolderPeer#fbd2c296 peer:InputPeer folder_id:int = InputFolderPeer
 * 用于 folders.editPeerFolders 将对话移入/移出归档
 */
public class InputFolderPeer <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var folderId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xfbd2c296 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.folderId)
    }
}

/**
 * folders.editPeerFolders#6847d0ab folder_peers:Vector<InputFolderPeer> = Updates
 * 将对话移入指定文件夹（0=主列表，1=归档）
 */
public class FoldersEditPeerFolders <: TLObject {
    public var folderPeers: ArrayList<InputFolderPeer> = ArrayList<InputFolderPeer>()

    public func getConstructorId(): UInt32 { return 0x6847d0ab }

    public func serialize(serializer: TLSerializer) {
        // folder_peers:Vector<InputFolderPeer> — boxed vector header (toBytes() already prepends method ctor 0x6847d0ab)
        serializer.writeUInt32(0x1cb5c415)  // VECTOR ctor (iOS Api42:5012 appendInt32(481674261))
        serializer.writeInt32(Int32(this.folderPeers.size))
        for (fp in this.folderPeers) {
            serializer.writeRawBytes(fp.toBytes())
        }
    }
}

// ==================== Phase P6-10: Change Phone Number ====================

/**
 * account.sendChangePhoneCode#82574ae5 phone_number:string settings:CodeSettings = auth.SentCode
 */
public class AccountSendChangePhoneCode <: TLObject {
    public var phoneNumber: String = ""

    public func getConstructorId(): UInt32 { return 0x82574ae5 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.phoneNumber)
        // CodeSettings#ad253d78 flags:#
        serializer.writeUInt32(0xad253d78)
        serializer.writeInt32(0)  // flags = 0 (default settings)
    }
}

/**
 * account.changePhone#70c32edb phone_number:string phone_code_hash:string phone_code:string = User
 */
public class AccountChangePhone <: TLObject {
    public var phoneNumber: String = ""
    public var phoneCodeHash: String = ""
    public var phoneCode: String = ""

    public func getConstructorId(): UInt32 { return 0x70c32edb }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.phoneNumber)
        serializer.writeString(this.phoneCodeHash)
        serializer.writeString(this.phoneCode)
    }
}

// ==================== Telegram Passport (SecureId) ====================

/**
 * account.getAuthorizationForm#a929597a bot_id:long scope:string public_key:string = account.AuthorizationForm
 */
public class AccountGetAuthorizationForm <: TLObject {
    public var botId: Int64 = 0
    public var scope: String = ""
    public var publicKey: String = ""

    public func getConstructorId(): UInt32 { return 0xa929597a }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.botId)
        serializer.writeString(this.scope)
        serializer.writeString(this.publicKey)
    }
}

/**
 * account.acceptAuthorization#f3ed4c73 bot_id:long scope:string public_key:string value_hashes:Vector<SecureValueHash> credentials:SecureCredentialsEncrypted = Bool
 */
public class AccountAcceptAuthorization <: TLObject {
    public var botId: Int64 = 0
    public var scope: String = ""
    public var publicKey: String = ""
    public var valueHashesBytes: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var credentialsBytes: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0xf3ed4c73 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.botId)
        serializer.writeString(this.scope)
        serializer.writeString(this.publicKey)
        serializer.writeRawBytes(this.valueHashesBytes)
        serializer.writeRawBytes(this.credentialsBytes)
    }
}

/**
 * SecureValueType constructors for Passport
 */
public class SecureValueTypePassport <: TLObject {
    public func getConstructorId(): UInt32 { return 0x3dac6a00 }
    public func serialize(serializer: TLSerializer) {}
}

// secureValueTypeDriverLicense#6e425c4 (Layer 214 correct ID)
public class SecureValueTypeDriverLicense <: TLObject {
    public func getConstructorId(): UInt32 { return 0x06e425c4 }
    public func serialize(serializer: TLSerializer) {}
}

public class SecureValueTypeIdentityCard <: TLObject {
    public func getConstructorId(): UInt32 { return 0xa0d0744b }
    public func serialize(serializer: TLSerializer) {}
}

public class SecureValueTypePersonalDetails <: TLObject {
    public func getConstructorId(): UInt32 { return 0x9d2a81e3 }
    public func serialize(serializer: TLSerializer) {}
}

public class SecureValueTypeAddress <: TLObject {
    public func getConstructorId(): UInt32 { return 0xcbe31e26 }
    public func serialize(serializer: TLSerializer) {}
}

public class SecureValueTypePhone <: TLObject {
    public func getConstructorId(): UInt32 { return 0xb320aadb }
    public func serialize(serializer: TLSerializer) {}
}

public class SecureValueTypeEmail <: TLObject {
    public func getConstructorId(): UInt32 { return 0x8e3ca7ee }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * account.getSecureValue#73665bc2 types:Vector<SecureValueType> = Vector<SecureValue>
 */
public class AccountGetSecureValue <: TLObject {
    public var typeObjects: ArrayList<TLObject> = ArrayList<TLObject>()

    public func getConstructorId(): UInt32 { return 0x73665bc2 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.typeObjects.size))
        for (t in this.typeObjects) {
            serializer.writeUInt32(t.getConstructorId())
            t.serialize(serializer)
        }
    }
}

/**
 * account.saveSecureValue#899fe31d value:InputSecureValue secure_secret_id:long = SecureValue
 */
public class AccountSaveSecureValue <: TLObject {
    public var valueBytes: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var secureSecretId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x899fe31d }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.valueBytes)
        serializer.writeInt64(this.secureSecretId)
    }
}

/**
 * account.deleteSecureValue#b880bc4b types:Vector<SecureValueType> = Bool
 */
public class AccountDeleteSecureValue <: TLObject {
    public var typeObjects: ArrayList<TLObject> = ArrayList<TLObject>()

    public func getConstructorId(): UInt32 { return 0xb880bc4b }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.typeObjects.size))
        for (t in this.typeObjects) {
            serializer.writeUInt32(t.getConstructorId())
            t.serialize(serializer)
        }
    }
}

/**
 * account.sendVerifyPhoneCode#a5a356f9 phone_number:string settings:CodeSettings = auth.SentCode
 */
public class AccountSendVerifyPhoneCode <: TLObject {
    public var phoneNumber: String = ""

    public func getConstructorId(): UInt32 { return 0xa5a356f9 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.phoneNumber)
        serializer.writeUInt32(0xad253d78)
        serializer.writeInt32(0)
    }
}

/**
 * account.verifyPhone#4dd3a7f6 phone_number:string phone_code_hash:string phone_code:string = Bool
 */
public class AccountVerifyPhone <: TLObject {
    public var phoneNumber: String = ""
    public var phoneCodeHash: String = ""
    public var phoneCode: String = ""

    public func getConstructorId(): UInt32 { return 0x4dd3a7f6 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.phoneNumber)
        serializer.writeString(this.phoneCodeHash)
        serializer.writeString(this.phoneCode)
    }
}

/**
 * account.sendVerifyEmailCode#98e037bb purpose:EmailVerifyPurpose email:string = account.SentEmailCode
 * emailVerifyPurposePassport#bbf51685 = EmailVerifyPurpose
 */
public class AccountSendVerifyEmailCode <: TLObject {
    public var email: String = ""

    public func getConstructorId(): UInt32 { return 0x98e037bb }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0xbbf51685)
        serializer.writeString(this.email)
    }
}

/**
 * account.verifyEmail#32da4cf purpose:EmailVerifyPurpose verification:EmailVerification = account.EmailVerified
 * emailVerificationCode#922e55a9 code:string = EmailVerification (tl_codegen verified: 0x922e55a9)
 */
public class AccountVerifyEmail <: TLObject {
    public var code: String = ""

    public func getConstructorId(): UInt32 { return 0x32da4cf }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0xbbf51685)
        serializer.writeUInt32(0x922e55a9)  // emailVerificationCode (fixed: was 0x922e55a4)
        serializer.writeString(this.code)
    }
}

// ==================== Secure ID: getAllSecureValues + inputSecureFileUploaded ====================

/**
 * account.getAllSecureValues#b288bc7d = Vector<SecureValue>
 * Returns all stored SecureValue records without type filter.
 * Codegen verify: 0xb288bc7d (matches TL schema Layer 167+)
 */
public class AccountGetAllSecureValues <: TLObject {
    public func getConstructorId(): UInt32 { return 0xb288bc7d }

    public func serialize(serializer: TLSerializer) {}
}

/**
 * inputSecureFileUploaded#3334b0f0
 * id:long parts:int md5_checksum:string file_hash:bytes secret:bytes = InputSecureFile
 *
 * Codegen verify: 0x3334b0f0 (TL schema Layer 91+)
 * Used after encrypting a Passport document file and uploading chunks via saveFilePart.
 * file_hash: SHA256 of the unencrypted file bytes.
 * secret: 32-byte AES-256-CBC secret for this file (encrypted with passport secret).
 * md5_checksum: MD5 hex of the encrypted upload (parts <= 10 MB; empty for big).
 */
public class InputSecureFileUploaded <: TLObject {
    public var id: Int64 = 0
    public var parts: Int32 = 0
    public var md5Checksum: String = ""
    public var fileHash: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var secret: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0x3334b0f0 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.id)
        serializer.writeInt32(this.parts)
        serializer.writeString(this.md5Checksum)
        serializer.writeBytes(this.fileHash)
        serializer.writeBytes(this.secret)
    }
}

// ==================== TelegramEngine.AccountData: registerDevice / unregisterDevice ====================

/**
 * account.registerDevice#ec86017a flags:# no_muted:flags.0?true token_type:int token:string app_sandbox:Bool secret:bytes other_uids:Vector<long> = Bool
 */
public class AccountRegisterDevice <: TLObject {
    public var tokenType: Int32 = 1
    public var token: String = ""
    public var appSandbox: Bool = false
    public var secret: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var otherUids: ArrayList<Int64> = ArrayList<Int64>()
    public var noMuted: Bool = false

    public func getConstructorId(): UInt32 { return 0xec86017a }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.noMuted) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeInt32(this.tokenType)
        serializer.writeString(this.token)
        serializer.writeBool(this.appSandbox)
        serializer.writeBytes(this.secret)
        serializer.writeUInt32(TLConstructors.VECTOR)  // 0x1cb5c415 vector ctor (iOS Api42:1073)
        serializer.writeInt32(Int32(this.otherUids.size))
        for (uid in this.otherUids) {
            serializer.writeInt64(uid)
        }
    }
}

/**
 * account.unregisterDevice#6a0d3206 token_type:int token:string other_uids:Vector<long> = Bool
 */
public class AccountUnregisterDevice <: TLObject {
    public var tokenType: Int32 = 1
    public var token: String = ""
    public var otherUids: ArrayList<Int64> = ArrayList<Int64>()

    public func getConstructorId(): UInt32 { return 0x6a0d3206 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.tokenType)
        serializer.writeString(this.token)
        serializer.writeUInt32(TLConstructors.VECTOR)  // 0x1cb5c415 vector ctor (iOS Api42:1671)
        serializer.writeInt32(Int32(this.otherUids.size))
        for (uid in this.otherUids) {
            serializer.writeInt64(uid)
        }
    }
}

// ==================== help.TermsOfService ====================

/**
 * help.getTermsOfServiceUpdate#2ca51fd1 = help.TermsOfServiceUpdate
 */
public class HelpGetTermsOfServiceUpdate <: TLObject {
    public func getConstructorId(): UInt32 { return 0x2ca51fd1 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * help.acceptTermsOfService#ee72f79a id:DataJSON = Bool
 * DataJSON#7d748d04 data:string = DataJSON
 */
public class HelpAcceptTermsOfService <: TLObject {
    public var termsId: String = ""

    public func getConstructorId(): UInt32 { return 0xee72f79a }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0x7d748d04)
        serializer.writeString(this.termsId)
    }
}

/**
 * help.getPromoData#c0977421 = help.PromoData
 * 获取服务器建议列表（pending_suggestions, dismissed_suggestions）
 */
public class HelpGetPromoData <: TLObject {
    public func getConstructorId(): UInt32 { return 0xc0977421 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * help.dismissSuggestion#f50dbaa1 peer:InputPeer suggestion:string = Bool
 * 全局建议使用 InputPeerEmpty
 */
public class HelpDismissSuggestion <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var suggestion: String = ""

    public func getConstructorId(): UInt32 { return 0xf50dbaa1 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.suggestion)
    }
}

// ==================== SyncCore: messages.getPinnedDialogs / messages.getSavedGifs ====================

/**
 * messages.getPinnedDialogs#d6b94df2 folder_id:int = messages.PeerDialogs
 * 获取置顶对话列表，用于同步置顶状态
 */
public class MessagesGetPinnedDialogs <: TLObject {
    public var folderId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xd6b94df2 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.folderId)
    }
}

/**
 * messages.getSavedGifs#5cf09635 hash:long = messages.SavedGifs
 * 获取已保存的 GIF 列表，用于同步收藏 GIF
 */
public class MessagesGetSavedGifs <: TLObject {
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x5cf09635 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

// ==================== Notification Sound Selection (account.getSavedRingtones / saveRingtone / uploadRingtone) ====================

/**
 * inputDocument#1abfb575 id:long access_hash:long file_reference:bytes = InputDocument
 */
public class InputDocument <: TLObject {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0x1abfb575 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.id)
        serializer.writeInt64(this.accessHash)
        serializer.writeBytes(this.fileReference)
    }
}

/**
 * account.getSavedRingtones#e1902288 hash:long = account.SavedRingtones
 */
public class AccountGetSavedRingtones <: TLObject {
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xe1902288 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

/**
 * account.saveRingtone#3dea5b03 id:InputDocument unsave:Bool = account.SavedRingtone
 */
public class AccountSaveRingtone <: TLObject {
    public var id: TLObject = InputPeerEmpty()  // InputDocument
    public var unsave: Bool = false

    public func getConstructorId(): UInt32 { return 0x3dea5b03 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.id.toBytes())
        serializer.writeBool(this.unsave)
    }
}

/**
 * account.uploadRingtone#831a83a2 file:InputFile file_name:string mime_type:string = Document
 */
public class AccountUploadRingtone <: TLObject {
    public var file: TLObject = InputPeerEmpty()  // InputFile
    public var fileName: String = ""
    public var mimeType: String = "audio/mpeg"

    public func getConstructorId(): UInt32 { return 0x831a83a2 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.file.toBytes())
        serializer.writeString(this.fileName)
        serializer.writeString(this.mimeType)
    }
}

// ==================== In-App Purchase (payments.assignAppStoreTransaction) ====================

/**
 * inputStorePaymentPremiumSubscription#a6751e66 flags:# restore:flags.0?true upgrade:flags.1?true = InputStorePaymentPurpose
 * 用于 Premium 订阅、恢复购买、升级
 */
public class InputStorePaymentPremiumSubscription <: TLObject {
    public var restore: Bool = false
    public var upgrade: Bool = false

    public func getConstructorId(): UInt32 { return 0xa6751e66 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.restore) { flags = flags | 1 }
        if (this.upgrade) { flags = flags | 2 }
        serializer.writeInt32(flags)
    }
}

/** inputStorePaymentPremiumGiftCode#fb790393 */
public class InputStorePaymentPremiumGiftCode <: TLObject {
    public var users: ArrayList<TLObject> = ArrayList<TLObject>()
    public var currency: String = ""
    public var amount: Int64 = 0
    public var message: String = ""

    public func getConstructorId(): UInt32 { return 0xfb790393 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.message.size > 0) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.users.size))
        for (user in this.users) { serializer.writeRawBytes(user.toBytes()) }
        serializer.writeString(this.currency)
        serializer.writeInt64(this.amount)
        if (this.message.size > 0) {
            serializer.writeUInt32(0x751f3146)
            serializer.writeString(this.message)
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(0)
        }
    }
}

/** inputStorePaymentStarsTopup#f9a2a6cb */
public class InputStorePaymentStarsTopup <: TLObject {
    public var stars: Int64 = 0
    public var currency: String = ""
    public var amount: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xf9a2a6cb }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)
        serializer.writeInt64(this.stars)
        serializer.writeString(this.currency)
        serializer.writeInt64(this.amount)
    }
}

/**
 * payments.assignAppStoreTransaction#80ed747d receipt:bytes purpose:InputStorePaymentPurpose = Updates
 * 向 Telegram 服务器提交 App Store 收据
 */
public class PaymentsAssignAppStoreTransaction <: TLObject {
    public var receipt: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var purpose: TLObject = InputStorePaymentPremiumSubscription()

    public func getConstructorId(): UInt32 { return 0x80ed747d }

    public func serialize(serializer: TLSerializer) {
        serializer.writeBytes(this.receipt)
        serializer.writeRawBytes(this.purpose.toBytes())
    }
}

// ==================== Themes (account.getThemes / account.getChatThemes / account.saveTheme / account.installTheme) ====================

/**
 * inputThemeSlug#f5890df1 slug:string = InputTheme
 * 通过 slug 引用云端主题
 */
public class InputThemeSlug <: TLObject {
    public var slug: String = ""

    public func getConstructorId(): UInt32 { return 0xf5890df1 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.slug)
    }
}

/**
 * baseThemeClassic#c3a12462 = BaseTheme
 */
public class BaseThemeClassic <: TLObject {
    public func getConstructorId(): UInt32 { return 0xc3a12462 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * baseThemeDay#fbd81688 = BaseTheme
 */
public class BaseThemeDay <: TLObject {
    public func getConstructorId(): UInt32 { return 0xfbd81688 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * baseThemeNight#b7b31ea8 = BaseTheme
 */
public class BaseThemeNight <: TLObject {
    public func getConstructorId(): UInt32 { return 0xb7b31ea8 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * baseThemeTinted#6d5f77ee = BaseTheme
 */
public class BaseThemeTinted <: TLObject {
    public func getConstructorId(): UInt32 { return 0x6d5f77ee }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * baseThemeArctic#5b11125a = BaseTheme
 */
public class BaseThemeArctic <: TLObject {
    public func getConstructorId(): UInt32 { return 0x5b11125a }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * inputThemeSettings#8fde504f flags:# base_theme:BaseTheme accent_color:int
 *   outbox_accent_color:flags.3?int message_colors:flags.0?Vector<int>
 *   wallpaper:flags.1?InputWallPaper wallpaper_settings:flags.1?WallPaperSettings
 */
public class InputThemeSettings <: TLObject {
    public var animateMessageColors: Bool = false
    public var baseTheme: TLObject = BaseThemeClassic()
    public var accentColor: UInt32 = 0
    public var outboxAccentColor: Option<UInt32> = None
    public var messageColors: Array<UInt32> = Array<UInt32>()
    public var wallpaper: Option<TLObject> = None
    public var wallpaperSettings: Option<WallPaperSettings> = None

    public func getConstructorId(): UInt32 { return 0x8fde504f }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.messageColors.size > 0) { flags = flags | 1 }
        match (this.wallpaper) { case Some(_) => flags = flags | 2; case None => () }
        if (this.animateMessageColors) { flags = flags | 4 }
        match (this.outboxAccentColor) { case Some(_) => flags = flags | 8; case None => () }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.baseTheme.toBytes())
        serializer.writeUInt32(this.accentColor)
        match (this.outboxAccentColor) {
            case Some(color) => serializer.writeUInt32(color)
            case None => ()
        }
        if ((flags & 1) != 0) {
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(Int32(this.messageColors.size))
            for (color in this.messageColors) { serializer.writeUInt32(color) }
        }
        if ((flags & 2) != 0) {
            match (this.wallpaper) { case Some(value) => serializer.writeRawBytes(value.toBytes()); case None => () }
            match (this.wallpaperSettings) { case Some(value) => serializer.writeRawBytes(value.toBytes()); case None => () }
        }
    }
}

/** account.createTheme#652e4400 flags:# slug:string title:string document:flags.2?InputDocument settings:flags.3?Vector<InputThemeSettings> = Theme */
public class AccountCreateTheme <: TLObject {
    public var slug: String = ""
    public var title: String = ""
    public var document: Option<InputDocument> = None
    public var settings: Array<InputThemeSettings> = Array<InputThemeSettings>()

    public func getConstructorId(): UInt32 { return 0x652e4400 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        match (this.document) { case Some(_) => flags = flags | 4; case None => () }
        if (this.settings.size > 0) { flags = flags | 8 }
        serializer.writeInt32(flags)
        serializer.writeString(this.slug)
        serializer.writeString(this.title)
        match (this.document) { case Some(value) => serializer.writeRawBytes(value.toBytes()); case None => () }
        if ((flags & 8) != 0) {
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(Int32(this.settings.size))
            for (value in this.settings) { serializer.writeRawBytes(value.toBytes()) }
        }
    }
}

/** account.uploadTheme#1c3db333 flags:# file:InputFile thumb:flags.0?InputFile file_name:string mime_type:string = Document */
public class AccountUploadTheme <: TLObject {
    public var file: TLObject = InputFileUploaded()
    public var fileName: String = "theme.tgios-theme"
    public var mimeType: String = "application/x-tgtheme-ios"

    public func getConstructorId(): UInt32 { return 0x1c3db333 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)
        serializer.writeRawBytes(this.file.toBytes())
        serializer.writeString(this.fileName)
        serializer.writeString(this.mimeType)
    }
}

/**
 * account.getThemes#7206e458 flags:# format:flags.0?string hash:long = account.Themes
 * 获取所有云端主题列表（可选 format 过滤）
 */
public class AccountGetThemes <: TLObject {
    public var format: Option<String> = None
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x7206e458 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        match (this.format) {
            case Some(_) => flags = flags | 1
            case None => ()
        }
        serializer.writeInt32(flags)
        match (this.format) {
            case Some(fmt) => serializer.writeString(fmt)
            case None => ()
        }
        serializer.writeInt64(this.hash)
    }
}

/**
 * account.getChatThemes#d638de89 hash:long = account.Themes
 * 获取聊天主题列表
 */
public class AccountGetChatThemes <: TLObject {
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xd638de89 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

/**
 * account.saveTheme#f257106c flags:# unsave:flags.0?true theme:InputTheme = Bool
 * 保存（收藏）或取消收藏一个云端主题
 */
public class AccountSaveTheme <: TLObject {
    public var unsave: Bool = false
    public var theme: TLObject = InputThemeSlug()

    public func getConstructorId(): UInt32 { return 0xf257106c }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.unsave) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.theme.toBytes())
    }
}

/**
 * account.installTheme#c727bb3b (Layer 214 correct ID)
 * flags:# dark:flags.0?true theme:flags.1?InputTheme format:flags.2?string base_theme:flags.3?BaseTheme = Bool
 * 安装一个云端主题（dark 模式 / 指定 BaseTheme）
 */
public class AccountInstallTheme <: TLObject {
    public var dark: Bool = false
    public var theme: Option<TLObject> = None
    public var format: Option<String> = None
    public var baseTheme: Option<TLObject> = None

    public func getConstructorId(): UInt32 { return 0xc727bb3b }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.dark) { flags = flags | 1 }
        match (this.theme) {
            case Some(_) => flags = flags | 2
            case None => ()
        }
        match (this.format) {
            case Some(_) => flags = flags | 4
            case None => ()
        }
        match (this.baseTheme) {
            case Some(_) => flags = flags | 8
            case None => ()
        }
        serializer.writeInt32(flags)
        match (this.theme) {
            case Some(t) => serializer.writeRawBytes(t.toBytes())
            case None => ()
        }
        match (this.format) {
            case Some(fmt) => serializer.writeString(fmt)
            case None => ()
        }
        match (this.baseTheme) {
            case Some(bt) => serializer.writeRawBytes(bt.toBytes())
            case None => ()
        }
    }
}

// ==================== Payments TL Methods (telegram_engine_payments) ====================

/**
 * payments.getPaymentForm#37148dbb flags:# invoice:InputInvoice theme_params:flags.0?DataJSON = payments.PaymentForm
 * Constructor: 0x37148dbb
 * 获取支付表单（银行卡信息、发票、Provider 信息等）
 */
public class PaymentsGetPaymentForm <: TLObject {
    public var invoiceType: String = "message"  // "message" | "slug"
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var msgId: Int32 = 0
    public var slug: String = ""

    public func getConstructorId(): UInt32 { return 0x37148dbb }

    public func serialize(serializer: TLSerializer) {
        let flags: Int32 = 0  // no theme_params
        serializer.writeInt32(flags)
        // InputInvoice (boxed)
        if (this.invoiceType == "slug") {
            // inputInvoiceSlug#c326caef slug:string
            serializer.writeUInt32(0xc326caef)
            serializer.writeString(this.slug)
        } else {
            // inputInvoiceMessage#c5b56859 peer:InputPeer msg_id:int
            serializer.writeUInt32(0xc5b56859)
            // inputPeerUser#dde8a54c user_id:long access_hash:long
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
            serializer.writeInt32(this.msgId)
        }
    }
}

/**
 * payments.getPaymentForm using inputInvoicePremiumGiftStars.
 * Telegram iOS creates this invoice when "Pay with Stars" is selected for a
 * Premium gift; the returned form id must then be passed to sendStarsForm.
 */
public class PaymentsGetPremiumGiftStarsForm <: TLObject {
    public var user: TLObject = InputUserSelf()
    public var months: Int32 = 0
    public var message: String = ""

    public func getConstructorId(): UInt32 { return 0x37148dbb }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)
        this.serializeInvoice(serializer)
    }

    private func serializeInvoice(serializer: TLSerializer) {
        serializer.writeUInt32(0xdabab2ef)
        serializer.writeInt32(if (this.message.size > 0) { 1 } else { 0 })
        serializer.writeRawBytes(this.user.toBytes())
        serializer.writeInt32(this.months)
        if (this.message.size > 0) {
            serializer.writeUInt32(0x751f3146)
            serializer.writeString(this.message)
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(0)
        }
    }
}

/** payments.sendStarsForm#7998c914 for inputInvoicePremiumGiftStars. */
public class PaymentsSendPremiumGiftStarsForm <: TLObject {
    public var formId: Int64 = 0
    public var user: TLObject = InputUserSelf()
    public var months: Int32 = 0
    public var message: String = ""

    public func getConstructorId(): UInt32 { return 0x7998c914 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.formId)
        serializer.writeUInt32(0xdabab2ef)
        serializer.writeInt32(if (this.message.size > 0) { 1 } else { 0 })
        serializer.writeRawBytes(this.user.toBytes())
        serializer.writeInt32(this.months)
        if (this.message.size > 0) {
            serializer.writeUInt32(0x751f3146)
            serializer.writeString(this.message)
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(0)
        }
    }
}

public class PaymentsGetStarGiftForm <: TLObject {
    public var peer: TLObject = InputPeerSelf()
    public var giftId: Int64 = 0
    public var message: String = ""
    public var hideName: Bool = false
    public var includeUpgrade: Bool = false

    public func getConstructorId(): UInt32 { return 0x37148dbb }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)
        this.serializeInvoice(serializer)
    }
    private func serializeInvoice(serializer: TLSerializer) {
        serializer.writeUInt32(0xe8625e92)
        var flags: Int32 = 0
        if (this.hideName) { flags = flags | 1 }
        if (this.message.size > 0) { flags = flags | 2 }
        if (this.includeUpgrade) { flags = flags | 4 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt64(this.giftId)
        if (this.message.size > 0) {
            serializer.writeUInt32(0x751f3146)
            serializer.writeString(this.message)
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(0)
        }
    }
}

public class PaymentsSendStarGiftForm <: TLObject {
    public var formId: Int64 = 0
    public var peer: TLObject = InputPeerSelf()
    public var giftId: Int64 = 0
    public var message: String = ""
    public var hideName: Bool = false
    public var includeUpgrade: Bool = false

    public func getConstructorId(): UInt32 { return 0x7998c914 }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.formId)
        serializer.writeUInt32(0xe8625e92)
        var flags: Int32 = 0
        if (this.hideName) { flags = flags | 1 }
        if (this.message.size > 0) { flags = flags | 2 }
        if (this.includeUpgrade) { flags = flags | 4 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt64(this.giftId)
        if (this.message.size > 0) {
            serializer.writeUInt32(0x751f3146)
            serializer.writeString(this.message)
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(0)
        }
    }
}

public class PaymentsGetResaleStarGiftForm <: TLObject {
    public var slug: String = ""
    public var peer: TLObject = InputPeerSelf()
    public var ton: Bool = false

    public func getConstructorId(): UInt32 { return 0x37148dbb }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)
        this.serializeInvoice(serializer)
    }
    private func serializeInvoice(serializer: TLSerializer) {
        serializer.writeUInt32(0xc39f5324)
        serializer.writeInt32(if (this.ton) { 1 } else { 0 })
        serializer.writeString(this.slug)
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

public class PaymentsSendResaleStarGiftForm <: TLObject {
    public var formId: Int64 = 0
    public var slug: String = ""
    public var peer: TLObject = InputPeerSelf()
    public var ton: Bool = false

    public func getConstructorId(): UInt32 { return 0x7998c914 }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.formId)
        serializer.writeUInt32(0xc39f5324)
        serializer.writeInt32(if (this.ton) { 1 } else { 0 })
        serializer.writeString(this.slug)
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

public class PaymentsGetStarGiftTransferForm <: TLObject {
    public var msgId: Int32 = 0
    public var peer: TLObject = InputPeerSelf()

    public func getConstructorId(): UInt32 { return 0x37148dbb }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)
        this.serializeInvoice(serializer)
    }
    private func serializeInvoice(serializer: TLSerializer) {
        serializer.writeUInt32(0x4a5f5bd9)
        serializer.writeUInt32(0x69279795)
        serializer.writeInt32(this.msgId)
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

public class PaymentsSendStarGiftTransferForm <: TLObject {
    public var formId: Int64 = 0
    public var msgId: Int32 = 0
    public var peer: TLObject = InputPeerSelf()

    public func getConstructorId(): UInt32 { return 0x7998c914 }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.formId)
        serializer.writeUInt32(0x4a5f5bd9)
        serializer.writeUInt32(0x69279795)
        serializer.writeInt32(this.msgId)
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

/**
 * payments.validateRequestedInfo#b6c8f12b (Layer 214 correct ID)
 * flags:# save:flags.0?true invoice:InputInvoice info:PaymentRequestedInfo = payments.ValidatedRequestedInfo
 * 验证用户填写的支付信息（姓名/电话/邮件/地址）
 */
public class PaymentsValidateRequestedInfo <: TLObject {
    public var save: Bool = false
    public var invoiceType: String = "message"
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var msgId: Int32 = 0
    public var slug: String = ""
    // 用户信息字段
    public var name: String = ""
    public var phone: String = ""
    public var email: String = ""
    // 地址字段（可选，flags.3）
    public var hasAddress: Bool = false
    public var streetLine1: String = ""
    public var streetLine2: String = ""
    public var city: String = ""
    public var state: String = ""
    public var countryIso2: String = ""
    public var postCode: String = ""

    public func getConstructorId(): UInt32 { return 0xb6c8f12b }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.save) { flags = flags | 1 }
        serializer.writeInt32(flags)
        // InputInvoice (boxed)
        if (this.invoiceType == "slug") {
            serializer.writeUInt32(0xc326caef)
            serializer.writeString(this.slug)
        } else {
            serializer.writeUInt32(0xc5b56859)
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
            serializer.writeInt32(this.msgId)
        }
        // paymentRequestedInfo#909c3f94 flags:# name:flags.0?string phone:flags.1?string email:flags.2?string shipping_address:flags.3?PostAddress
        serializer.writeUInt32(0x909c3f94)
        var infoFlags: Int32 = 0
        if (this.name.size > 0) { infoFlags = infoFlags | 1 }
        if (this.phone.size > 0) { infoFlags = infoFlags | 2 }
        if (this.email.size > 0) { infoFlags = infoFlags | 4 }
        if (this.hasAddress) { infoFlags = infoFlags | 8 }
        serializer.writeInt32(infoFlags)
        if (this.name.size > 0) { serializer.writeString(this.name) }
        if (this.phone.size > 0) { serializer.writeString(this.phone) }
        if (this.email.size > 0) { serializer.writeString(this.email) }
        if (this.hasAddress) {
            // postAddress#1e8caaeb street_line1:string street_line2:string city:string state:string country_iso2:string post_code:string
            serializer.writeUInt32(0x1e8caaeb)
            serializer.writeString(this.streetLine1)
            serializer.writeString(this.streetLine2)
            serializer.writeString(this.city)
            serializer.writeString(this.state)
            serializer.writeString(this.countryIso2)
            serializer.writeString(this.postCode)
        }
    }
}

/**
 * payments.sendPaymentForm#2d03522f (Layer 214 correct ID)
 * flags:# form_id:long invoice:InputInvoice requested_info_id:flags.0?string shipping_option_id:flags.1?string credentials:InputPaymentCredentials tip_amount:flags.2?long = payments.PaymentResult
 * 发送支付表单（完成支付）
 */
public class PaymentsSendPaymentForm <: TLObject {
    public var formId: Int64 = 0
    public var invoiceType: String = "message"
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var msgId: Int32 = 0
    public var slug: String = ""
    public var requestedInfoId: String = ""
    public var shippingOptionId: String = ""
    // credentials type: "data" | "saved"
    public var credentialsType: String = "data"
    public var credentialsData: String = ""  // JSON string for type=data
    public var credentialsSaveOnServer: Bool = false
    public var savedCredentialsId: String = ""
    public var savedCredentialsTmpPassword: Array<Byte> = Array<Byte>(0, repeat: 0)
    // tip_amount: flags.2?long (iOS ref: _internal_sendBotPaymentForm tipAmount param)
    public var tipAmount: Int64 = 0
    public var hasTipAmount: Bool = false

    public func getConstructorId(): UInt32 { return 0x2d03522f }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.requestedInfoId.size > 0) { flags = flags | 1 }
        if (this.shippingOptionId.size > 0) { flags = flags | 2 }
        if (this.hasTipAmount && this.tipAmount > 0) { flags = flags | 4 }
        serializer.writeInt32(flags)
        serializer.writeInt64(this.formId)
        // InputInvoice (boxed)
        if (this.invoiceType == "slug") {
            serializer.writeUInt32(0xc326caef)
            serializer.writeString(this.slug)
        } else {
            serializer.writeUInt32(0xc5b56859)
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
            serializer.writeInt32(this.msgId)
        }
        if (this.requestedInfoId.size > 0) { serializer.writeString(this.requestedInfoId) }
        if (this.shippingOptionId.size > 0) { serializer.writeString(this.shippingOptionId) }
        // InputPaymentCredentials (boxed)
        if (this.credentialsType == "saved") {
            // inputPaymentCredentialsSaved#c10eb2cf id:string tmp_password:bytes
            serializer.writeUInt32(0xc10eb2cf)
            serializer.writeString(this.savedCredentialsId)
            serializer.writeBytes(this.savedCredentialsTmpPassword)
        } else {
            // inputPaymentCredentials#3417d728 flags:# save:flags.0?true data:DataJSON
            serializer.writeUInt32(0x3417d728)
            var credFlags: Int32 = 0
            if (this.credentialsSaveOnServer) { credFlags = credFlags | 1 }
            serializer.writeInt32(credFlags)
            // dataJSON#7d748d04 data:string
            serializer.writeUInt32(0x7d748d04)
            serializer.writeString(this.credentialsData)
        }
        // tip_amount: flags.2?long
        if (this.hasTipAmount && this.tipAmount > 0) {
            serializer.writeInt64(this.tipAmount)
        }
    }
}

/**
 * payments.getPaymentReceipt#2478d1cc peer:InputPeer msg_id:int = payments.PaymentReceipt
 * Constructor: 0x2478d1cc
 * 获取支付收据
 */
public class PaymentsGetPaymentReceipt <: TLObject {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var msgId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x2478d1cc }

    public func serialize(serializer: TLSerializer) {
        // inputPeerUser#dde8a54c
        serializer.writeUInt32(0xdde8a54c)
        serializer.writeInt64(this.peerId)
        serializer.writeInt64(this.peerAccessHash)
        serializer.writeInt32(this.msgId)
    }
}

/**
 * payments.getBankCardData#2e79d779 number:string = payments.BankCardData
 * Constructor: 0x2e79d779
 * 获取银行卡信息（银行名称 + 相关链接）
 */
public class PaymentsGetBankCardData <: TLObject {
    public var number: String = ""

    public func getConstructorId(): UInt32 { return 0x2e79d779 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.number)
    }
}

// ==================== LegacyDataImport: messages.initHistoryImport / messages.uploadImportedMedia / messages.startHistoryImport ====================

/**
 * messages.initHistoryImport#34090c3b peer:InputPeer file:InputFile media_count:int = messages.HistoryImport
 * Constructor: 0x34090c3b
 * 初始化聊天记录导入会话，返回 import_id 用于后续上传
 */
public class MessagesInitHistoryImport <: TLObject {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var peerType: String = "user"
    public var file: TLObject = InputFileUploaded()
    public var mediaCount: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x34090c3b }

    public func serialize(serializer: TLSerializer) {
        if (peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)
            serializer.writeInt64(this.peerId)
        } else {
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }
        serializer.writeRawBytes(this.file.toBytes())
        serializer.writeInt32(this.mediaCount)
    }
}

/**
 * messages.uploadImportedMedia#2a862092 peer:InputPeer import_id:long media:InputMedia = MessageMedia
 * Constructor: 0x2a862092
 * 上传导入媒体文件（图片/视频/文档），关联到导入会话
 */
public class MessagesUploadImportedMedia <: TLObject {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var peerType: String = "user"
    public var importId: Int64 = 0
    public var media: TLObject = InputMediaUploadedPhoto()

    public func getConstructorId(): UInt32 { return 0x2a862092 }

    public func serialize(serializer: TLSerializer) {
        if (peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)
            serializer.writeInt64(this.peerId)
        } else {
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }
        serializer.writeInt64(this.importId)
        serializer.writeRawBytes(this.media.toBytes())
    }
}

/**
 * messages.startHistoryImport#b43df344 peer:InputPeer import_id:long = Bool
 * Constructor: 0xb43df344
 * 提交开始处理已上传的聊天记录导入
 */
public class MessagesStartHistoryImport <: TLObject {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var peerType: String = "user"
    public var importId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xb43df344 }

    public func serialize(serializer: TLSerializer) {
        if (peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)
            serializer.writeInt64(this.peerId)
        } else {
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }
        serializer.writeInt64(this.importId)
    }
}

// ==================== TelegramEngineHistoryImport: messages.checkHistoryImport / messages.checkHistoryImportPeer ====================

/**
 * messages.checkHistoryImport#43fe19f3 (Layer 214 correct ID)
 * import_head:string = messages.HistoryImportParsed
 * 解析导入文件头，识别对话类型（私聊 / 群组）和标题
 */
public class MessagesCheckHistoryImport <: TLObject {
    public var importHead: String = ""

    public func getConstructorId(): UInt32 { return 0x43fe19f3 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.importHead)
    }
}

// ==================== P2-150: Messages gap TL methods ====================

// MessagesGetAllDrafts removed: dead code — clearCloudDrafts uses MessagesClearAllDrafts directly;
// no callers found in cangjie tree (grep confirmed). FIX-3 P2-150 rework.

/**
 * messages.clearAllDrafts#7e58ee9c (Layer 214, tl_codegen verified)
 * TL: messages.clearAllDrafts#7e58ee9c = Bool;
 * Clears all cloud drafts atomically (single RPC, server-side)
 */
public class MessagesClearAllDrafts <: TLObject {
    public func getConstructorId(): UInt32 { return 0x7e58ee9c }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * messages.readMentions#36e5bf4d (Layer 214, tl_codegen verified)
 * TL: messages.readMentions#36e5bf4d flags:# peer:InputPeer top_msg_id:flags.0?int = messages.AffectedHistory;
 * Marks all unread mentions in a dialog as read
 */
public class MessagesReadMentions <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var topMsgId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x36e5bf4d }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.topMsgId != 0) { flags = flags | (1 << 0) }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        if (this.topMsgId != 0) {
            serializer.writeInt32(this.topMsgId)
        }
    }
}

/**
 * channels.deleteParticipantHistory#367544db (Layer 214, tl_codegen verified)
 * TL: channels.deleteParticipantHistory#367544db channel:InputChannel participant:InputPeer = messages.AffectedHistory;
 * Deletes all messages from a participant in a channel/supergroup (admin-only)
 */
public class ChannelsDeleteParticipantHistory <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var participant: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0x367544db }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeRawBytes(this.participant.toBytes())
    }
}

/**
 * messages.getMessagesReactions#8bba90e6 (Layer 214, tl_codegen verified)
 * TL: messages.getMessagesReactions#8bba90e6 peer:InputPeer id:Vector<int> = Updates;
 * Fetches full reaction list for specified messages
 */
public class MessagesGetMessagesReactions <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var id: ArrayList<Int32> = ArrayList<Int32>()

    public func getConstructorId(): UInt32 { return 0x8bba90e6 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.id.size))
        for (item in this.id) {
            serializer.writeInt32(item)
        }
    }
}

// ==================== End P2-150 additions ====================

// ==================== P2-151: Peers — Resolve / Usernames / Notify / InviteLinks ====================

/**
 * contacts.resolvePhone#8af94344 phone:string = contacts.ResolvedPeer
 *
 * tl_codegen verified: 0x8af94344
 * Resolve a peer by phone number → returns contacts.resolvedPeer with peer:Peer + users + chats
 */
public class ContactsResolvePhone <: TLObject {
    public var phone: String = ""

    public func getConstructorId(): UInt32 { return 0x8af94344 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.phone)
    }
}

/**
 * channels.toggleUsername#50f24105 channel:InputChannel username:string active:Bool = Bool
 *
 * tl_codegen verified: 0x50f24105
 * Toggle active state of a given username on a channel/supergroup
 */
public class ChannelsToggleUsername <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var username: String = ""
    public var active: Bool = false

    public func getConstructorId(): UInt32 { return 0x50f24105 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeString(this.username)
        serializer.writeBool(this.active)
    }
}

/**
 * channels.reorderUsernames#b45ced1d channel:InputChannel order:Vector<string> = Bool
 *
 * tl_codegen verified: 0xb45ced1d
 * Reorder active usernames on a channel/supergroup
 */
public class ChannelsReorderUsernames <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var order: ArrayList<String> = ArrayList<String>()

    public func getConstructorId(): UInt32 { return 0xb45ced1d }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.order.size))
        for (item in this.order) {
            serializer.writeString(item)
        }
    }
}

/**
 * account.toggleUsername#58d6b376 username:string active:Bool = Bool
 *
 * tl_codegen verified: 0x58d6b376
 * Toggle active state of one of the current user's usernames
 */
public class AccountToggleUsername <: TLObject {
    public var username: String = ""
    public var active: Bool = false

    public func getConstructorId(): UInt32 { return 0x58d6b376 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.username)
        serializer.writeBool(this.active)
    }
}

/**
 * account.reorderUsernames#ef500eab order:Vector<string> = Bool
 *
 * tl_codegen verified: 0xef500eab
 * Reorder the current user's active usernames
 */
public class AccountReorderUsernames <: TLObject {
    public var order: ArrayList<String> = ArrayList<String>()

    public func getConstructorId(): UInt32 { return 0xef500eab }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.order.size))
        for (item in this.order) {
            serializer.writeString(item)
        }
    }
}

// ==================== End P2-151 additions ====================

/**
 * messages.checkHistoryImportPeer#5dc60f03 peer:InputPeer = messages.CheckedHistoryImportPeer
 * Constructor: 0x5dc60f03
 * 检查指定对话是否允许导入聊天记录，返回确认文本（空字符串表示无需确认）
 */
public class MessagesCheckHistoryImportPeer <: TLObject {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var peerType: String = "user"

    public func getConstructorId(): UInt32 { return 0x5dc60f03 }

    public func serialize(serializer: TLSerializer) {
        if (peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)
            serializer.writeInt64(this.peerId)
        } else {
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }
    }
}

// ==================== Phase P2-153: AccountData core ====================

/**
 * photos.updateProfilePhoto#09e82039 (tl_codegen verified)
 * TL: photos.updateProfilePhoto#9e82039 flags:# fallback:flags.0?true bot:flags.1?InputUser id:InputPhoto = photos.Photo;
 * Sets an already-uploaded photo as the current profile photo.
 * id: inputPhoto#3bb3b94a id:long access_hash:long file_reference:bytes
 */
public class PhotosUpdateProfilePhoto <: TLObject {
    public var photoId: Int64 = 0
    public var photoAccessHash: Int64 = 0
    public var photoFileReference: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0x09e82039 }

    public func serialize(serializer: TLSerializer) {
        let flags: Int32 = 0
        serializer.writeInt32(flags)
        // id: InputPhoto — inputPhoto#3bb3b94a (tl_codegen: 0x3bb3b94a)
        serializer.writeUInt32(0x3bb3b94a)
        serializer.writeInt64(this.photoId)
        serializer.writeInt64(this.photoAccessHash)
        serializer.writeBytes(this.photoFileReference)
    }
}

/**
 * account.updateBirthday#cc6e0c11 (tl_codegen verified)
 * TL: account.updateBirthday#cc6e0c11 flags:# birthday:flags.0?Birthday = Bool;
 * birthday#6c8e1e06 flags:# day:int month:int year:flags.0?int
 * Passing hasBirthday=false clears the birthday field.
 */
public class AccountUpdateBirthday <: TLObject {
    public var hasBirthday: Bool = false
    public var day: Int32 = 0
    public var month: Int32 = 0
    public var year: Int32 = 0    // 0 = not set

    public func getConstructorId(): UInt32 { return 0xcc6e0c11 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasBirthday) { flags = flags | 1 }
        serializer.writeInt32(flags)
        if (this.hasBirthday) {
            // birthday#6c8e1e06 (tl_codegen verified)
            serializer.writeUInt32(0x6c8e1e06)
            var bdFlags: Int32 = 0
            if (this.year > 0) { bdFlags = bdFlags | 1 }
            serializer.writeInt32(bdFlags)
            serializer.writeInt32(this.day)
            serializer.writeInt32(this.month)
            if (this.year > 0) { serializer.writeInt32(this.year) }
        }
    }
}

/**
 * account.updateColor#684d214e (iOS Api42:1800 verified, python: 1749885262 == 0x684d214e)
 * TL: account.updateColor#684d214e flags:# for_profile:flags.1?true color:flags.2?PeerColor = Bool
 * Field resync vs iOS layer:
 *   - Old ctor 0x7cefa15d was stale.
 *   - color is now a boxed PeerColor type (ctor peerColor#b54b5acf) not a bare Int32.
 *   - PeerColor: peerColor#b54b5acf flags2:# color:flags2.0?int background_emoji_id:flags2.1?long
 *   - for_profile stays at flags.1; color (PeerColor) at flags.2.
 *   - Old bare backgroundEmojiId at flags.0 removed from outer flags.
 * Backward compat: existing fields (color:Int32, backgroundEmojiId:Int64) retained;
 *   serialization now wraps them into a PeerColor object when color >= 0.
 */
public class AccountUpdateColor <: TLObject {
    public var forProfile: Bool = false
    public var color: Int32 = -1             // -1 = not set (embedded in PeerColor at flags2.0)
    public var backgroundEmojiId: Int64 = 0  // 0 = not set (embedded in PeerColor at flags2.1)
    public var collectibleId: Int64 = 0       // non-zero uses inputPeerColorCollectible

    public func getConstructorId(): UInt32 { return 0x684d214e }

    public func serialize(serializer: TLSerializer) {
        // Outer flags: bit 1 = for_profile, bit 2 = color (PeerColor) present
        var flags: Int32 = 0
        if (this.forProfile) { flags = flags | (1 << 1) }
        let hasColor = (this.collectibleId != 0 || this.color >= 0 || this.backgroundEmojiId != 0)
        if (hasColor) { flags = flags | (1 << 2) }
        serializer.writeInt32(flags)
        if (hasColor) {
            if (this.collectibleId != 0) {
                // inputPeerColorCollectible#b8ea86a9 collectible_id:long
                serializer.writeUInt32(0xb8ea86a9)
                serializer.writeInt64(this.collectibleId)
                return
            }
            // Serialize boxed PeerColor: peerColor#b54b5acf (python: -1253352753 == 0xb54b5acf)
            serializer.writeUInt32(0xb54b5acf)
            // Inner PeerColor flags: bit 0 = color present, bit 1 = background_emoji_id present
            var flags2: Int32 = 0
            if (this.color >= 0) { flags2 = flags2 | 1 }
            if (this.backgroundEmojiId != 0) { flags2 = flags2 | (1 << 1) }
            serializer.writeInt32(flags2)
            if (this.color >= 0) { serializer.writeInt32(this.color) }
            if (this.backgroundEmojiId != 0) { serializer.writeInt64(this.backgroundEmojiId) }
        }
    }
}

/**
 * account.updateEmojiStatus#fbd3de6b (tl_codegen verified)
 * TL: account.updateEmojiStatus#fbd3de6b emoji_status:EmojiStatus = Bool;
 * emojiStatus#e7ff068a flags:# document_id:long until:flags.0?int
 * emojiStatusEmpty#2de11aae clears the status
 */
public class AccountUpdateEmojiStatus <: TLObject {
    public var documentId: Int64 = 0   // 0 = clear (emojiStatusEmpty)
    public var until: Int32 = 0        // 0 = permanent

    public func getConstructorId(): UInt32 { return 0xfbd3de6b }

    public func serialize(serializer: TLSerializer) {
        if (this.documentId == 0) {
            // emojiStatusEmpty#2de11aae (tl_codegen: grep telegram_api.tl → emojiStatusEmpty#2de11aae)
            serializer.writeUInt32(0x2de11aae)
        } else {
            // emojiStatus#e7ff068a flags:# document_id:long until:flags.0?int (tl_codegen verified)
            serializer.writeUInt32(0xe7ff068a)
            var flags: Int32 = 0
            if (this.until > 0) { flags = flags | 1 }
            serializer.writeInt32(flags)
            serializer.writeInt64(this.documentId)
            if (this.until > 0) { serializer.writeInt32(this.until) }
        }
    }
}

/**
 * account.updatePersonalChannel#d94305e0 (tl_codegen verified)
 * TL: account.updatePersonalChannel#d94305e0 channel:InputChannel = Bool;
 * channel: inputChannel#f35aec28 channel_id:long access_hash:long
 * Use inputChannelEmpty#ee8c1e86 to clear the personal channel.
 */
public class AccountUpdatePersonalChannel <: TLObject {
    public var channelId: Int64 = 0
    public var channelAccessHash: Int64 = 0
    public var clearChannel: Bool = false

    public func getConstructorId(): UInt32 { return 0xd94305e0 }

    public func serialize(serializer: TLSerializer) {
        if (this.clearChannel) {
            // inputChannelEmpty#ee8c1e86 (tl_codegen: existing InputChannelEmpty)
            serializer.writeUInt32(0xee8c1e86)
        } else {
            // inputChannel#f35aec28 (existing InputChannel class)
            serializer.writeUInt32(0xf35aec28)
            serializer.writeInt64(this.channelId)
            serializer.writeInt64(this.channelAccessHash)
        }
    }
}

/**
 * account.toggleSponsoredMessages#b9d9a38d (tl_codegen verified)
 * TL: account.toggleSponsoredMessages#b9d9a38d enabled:Bool = Bool;
 * Toggles sponsored messages visibility (Telegram Premium feature).
 */
public class AccountToggleSponsoredMessages <: TLObject {
    public var enabled: Bool = false

    public func getConstructorId(): UInt32 { return 0xb9d9a38d }

    public func serialize(serializer: TLSerializer) {
        serializer.writeBool(this.enabled)
    }
}

/**
 * help.getTimezonesList#49b30240 (tl_codegen verified)
 * TL: help.getTimezonesList#49b30240 hash:int = help.TimezonesList;
 * hash: 0 = full fetch; non-zero = hash from previous fetch (incremental).
 * Response: help.timezonesListNotModified#970708cc (hash not changed)
 *           help.timezonesList#7b74ed71 timezones:Vector<Timezone> hash:int
 */
public class HelpGetTimezonesList <: TLObject {
    public var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x49b30240 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.hash)
    }
}

// ==================== Phase P2-152: 2FA / Password Layer ====================

/**
 * account.invalidateSignInCodes#ca8ae8ba codes:Vector<string> = Bool
 * (tl_codegen verified: 0xca8ae8ba)
 * iOS ref: _internal_invalidateLoginCodes in Authorization.swift:1427
 */
public class AccountInvalidateSignInCodes <: TLObject {
    public var codes: ArrayList<String> = ArrayList<String>()

    public func getConstructorId(): UInt32 { return 0xca8ae8ba }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.codes.size))
        for (item in this.codes) {
            serializer.writeString(item)
        }
    }
}

/**
 * account.getPasswordSettings#9cd4eaf9 password:InputCheckPasswordSRP = account.PasswordSettings
 * (tl_codegen verified: 0x9cd4eaf9)
 * iOS ref: _internal_requestTwoStepVerifiationSettings in TwoStepVerification.swift:60
 */
public class AccountGetPasswordSettings <: TLObject {
    public var password: InputCheckPasswordSRP = InputCheckPasswordSRP()

    public func getConstructorId(): UInt32 { return 0x9cd4eaf9 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(this.password.getConstructorId())
        this.password.serialize(serializer)
    }
}

// ==================== P2-155: Stars 生态读核心 TL 方法 ====================

/**
 * payments.getStarsStatus#4ea9b3bf flags:# peer:InputPeer = payments.StarsStatus
 * tl_codegen verified: 0x4ea9b3bf (Api42.swift:11211; appendInt32(1319744447))
 * iOS ref: _internal_requestStarsState → Api.functions.payments.getStarsStatus (Stars.swift:464)
 * Layer diff: added flags field; wire order: flags(int32) + peer(boxed)
 * 返回 payments.starsStatus#6c9ce8ed (balance:StarsAmount + history:Vector<StarsTransaction> + ...)
 */
public class PaymentsGetStarsStatus <: TLObject {
    public var flags: Int32 = 0
    public var peer: TLObject = InputPeerSelf()

    public func getConstructorId(): UInt32 { return 0x4ea9b3bf }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.flags)
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

/**
 * payments.getStarsTransactions#69da4557 flags:# inbound:flags.0?true outbound:flags.1?true
 *   ascending:flags.2?true subscription_id:flags.3?string peer:InputPeer offset:string limit:int
 *   = payments.StarsStatus
 * tl_codegen verified: 0x69da4557
 * iOS ref: _internal_requestStarsState → Api.functions.payments.getStarsTransactions (Stars.swift:458)
 */
public class PaymentsGetStarsTransactions <: TLObject {
    public var inbound: Bool = false
    public var outbound: Bool = false
    public var ascending: Bool = false
    public var subscriptionId: String = ""
    public var peer: TLObject = InputPeerSelf()
    public var offset: String = ""
    public var limit: Int32 = 20

    public func getConstructorId(): UInt32 { return 0x69da4557 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.inbound) { flags = flags | 1 }
        if (this.outbound) { flags = flags | 2 }
        if (this.ascending) { flags = flags | 4 }
        if (this.subscriptionId.size > 0) { flags = flags | 8 }
        serializer.writeInt32(flags)
        if (this.subscriptionId.size > 0) { serializer.writeString(this.subscriptionId) }
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.offset)
        serializer.writeInt32(this.limit)
    }
}

/**
 * inputStarsTransaction#206ae6d1 flags:# refund:flags.0?true id:string = InputStarsTransaction
 * tl_codegen verified: 0x206ae6d1
 * Used in payments.getStarsTransactionsByID
 */
public class InputStarsTransaction <: TLObject {
    public var refund: Bool = false
    public var id: String = ""

    public func getConstructorId(): UInt32 { return 0x206ae6d1 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.refund) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeString(this.id)
    }
}

/**
 * payments.getStarsTransactionsByID#2dca16b8 flags:# peer:InputPeer id:Vector<InputStarsTransaction>
 *   = payments.StarsStatus
 * tl_codegen verified: 0x2dca16b8 (Api42.swift:11279; appendInt32(768218808))
 * Layer diff: added flags field; wire order: flags(int32) + peer(boxed) + Vector<InputStarsTransaction>(boxed items)
 * iOS wire: buffer.appendInt32(481674261) == 0x1cb5c415 (vector ctor) then count then boxed items
 */
public class PaymentsGetStarsTransactionsByID <: TLObject {
    public var flags: Int32 = 0
    public var peer: TLObject = InputPeerSelf()
    public var ids: ArrayList<InputStarsTransaction> = ArrayList<InputStarsTransaction>()

    public func getConstructorId(): UInt32 { return 0x2dca16b8 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.ids.size))
        for (item in this.ids) {
            serializer.writeUInt32(item.getConstructorId())
            item.serialize(serializer)
        }
    }
}

/**
 * payments.getStarsTopupOptions#c00ec7d3 = Vector<StarsTopupOption>
 * tl_codegen verified: 0xc00ec7d3
 * iOS ref: _internal_starsTopUpOptions → Api.functions.payments.getStarsTopupOptions (Stars.swift:62)
 */
public class PaymentsGetStarsTopupOptions <: TLObject {
    public func getConstructorId(): UInt32 { return 0xc00ec7d3 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * payments.getStarsGiftOptions#d3c96bc8 flags:# user_id:flags.0?InputUser
 *   = Vector<StarsGiftOption>
 * tl_codegen verified: 0xd3c96bc8
 * iOS ref: _internal_starsGiftOptions → Api.functions.payments.getStarsGiftOptions (Stars.swift:137)
 * user_id is optional; pass InputUserSelf to get options for self
 */
public class PaymentsGetStarsGiftOptions <: TLObject {
    public var hasUserId: Bool = false
    public var userId: TLObject = InputUserSelf()

    public func getConstructorId(): UInt32 { return 0xd3c96bc8 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasUserId) { flags = flags | 1 }
        serializer.writeInt32(flags)
        if (this.hasUserId) { serializer.writeRawBytes(this.userId.toBytes()) }
    }
}

// ==================== P2-156: Privacy + Session Management ====================

/**
 * globalPrivacySettings#fe41b34f
 * TL schema (telegram_api.tl:1347) tl_codegen verified:
 *   flags.0  archive_and_mute_new_noncontact_peers
 *   flags.1  keep_archived_unmuted
 *   flags.2  keep_archived_folders
 *   flags.3  hide_read_marks
 *   flags.4  new_noncontact_peers_require_premium
 *   flags.7  display_gifts_button
 *   flags.5  noncontact_peers_paid_stars:long (optional)
 *   flags.6  disallowed_gifts (optional, skipped)
 * Used both as request body for setGlobalPrivacySettings and as response type.
 */
public class GlobalPrivacySettings <: TLObject {
    public var archiveAndMuteNewNoncontactPeers: Bool = false
    public var keepArchivedUnmuted: Bool = false
    public var keepArchivedFolders: Bool = false
    public var hideReadMarks: Bool = false
    public var newNoncontactPeersRequirePremium: Bool = false
    public var displayGiftsButton: Bool = false
    public var noncontactPeersPaidStars: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xfe41b34f }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.archiveAndMuteNewNoncontactPeers) { flags = flags | 1 }
        if (this.keepArchivedUnmuted) { flags = flags | 2 }
        if (this.keepArchivedFolders) { flags = flags | 4 }
        if (this.hideReadMarks) { flags = flags | 8 }
        if (this.newNoncontactPeersRequirePremium) { flags = flags | 16 }
        if (this.noncontactPeersPaidStars != 0) { flags = flags | 32 }
        if (this.displayGiftsButton) { flags = flags | 128 }
        serializer.writeInt32(flags)
        if (this.noncontactPeersPaidStars != 0) {
            serializer.writeInt64(this.noncontactPeersPaidStars)
        }
    }
}

/**
 * account.getGlobalPrivacySettings#eb2b4cf6 = GlobalPrivacySettings
 * tl_codegen verified: 0xeb2b4cf6 (telegram_api.tl:2111)
 */
public class AccountGetGlobalPrivacySettings <: TLObject {
    public func getConstructorId(): UInt32 { return 0xeb2b4cf6 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * account.setGlobalPrivacySettings#1edaaac2 settings:GlobalPrivacySettings = GlobalPrivacySettings
 * tl_codegen verified: 0x1edaaac2 (telegram_api.tl:2112)
 */
public class AccountSetGlobalPrivacySettings <: TLObject {
    public var settings: GlobalPrivacySettings = GlobalPrivacySettings()

    public func getConstructorId(): UInt32 { return 0x1edaaac2 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(this.settings.getConstructorId())
        this.settings.serialize(serializer)
    }
}

/**
 * contacts.editCloseFriends#ba6705f0 id:Vector<long> = Bool
 * tl_codegen verified: 0xba6705f0 (telegram_api.tl:2190)
 * privacyValueAllowCloseFriends#f7e8d89b used in rules when key=statusTimestamp etc.
 * inputPrivacyValueAllowCloseFriends#2f453e49 used in setPrivacy rules
 */
public class ContactsEditCloseFriends <: TLObject {
    public var id: ArrayList<Int64> = ArrayList<Int64>()

    public func getConstructorId(): UInt32 { return 0xba6705f0 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.id.size))
        for (userId in this.id) {
            serializer.writeInt64(userId)
        }
    }
}

/**
 * account.setAuthorizationTTL#bf899aa0 authorization_ttl_days:int = Bool
 * tl_codegen verified: 0xbf899aa0 (telegram_api.tl:2117)
 */
public class AccountSetAuthorizationTTL <: TLObject {
    public var authorizationTtlDays: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xbf899aa0 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.authorizationTtlDays)
    }
}

/**
 * account.changeAuthorizationSettings#40f48462
 *   flags:# confirmed:flags.3?true hash:long
 *   encrypted_requests_disabled:flags.0?Bool call_requests_disabled:flags.1?Bool = Bool
 * tl_codegen verified: 0x40f48462 (telegram_api.tl:2118)
 * Bool fields are optional — only serialized when the corresponding flag bit is set.
 */
public class AccountChangeAuthorizationSettings <: TLObject {
    public var confirmed: Bool = false
    public var hash: Int64 = 0
    public var hasEncryptedRequestsDisabled: Bool = false
    public var encryptedRequestsDisabled: Bool = false
    public var hasCallRequestsDisabled: Bool = false
    public var callRequestsDisabled: Bool = false

    public func getConstructorId(): UInt32 { return 0x40f48462 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasEncryptedRequestsDisabled) { flags = flags | 1 }
        if (this.hasCallRequestsDisabled) { flags = flags | 2 }
        if (this.confirmed) { flags = flags | 8 }
        serializer.writeInt32(flags)
        serializer.writeInt64(this.hash)
        if (this.hasEncryptedRequestsDisabled) {
            serializer.writeBool(this.encryptedRequestsDisabled)
        }
        if (this.hasCallRequestsDisabled) {
            serializer.writeBool(this.callRequestsDisabled)
        }
    }
}

/**
 * account.getWebAuthorizations#182e6d6f = account.WebAuthorizations
 * tl_codegen verified: 0x182e6d6f (telegram_api.tl:2073)
 */
public class AccountGetWebAuthorizations <: TLObject {
    public func getConstructorId(): UInt32 { return 0x182e6d6f }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * account.resetWebAuthorization#2d01b9ef hash:long = Bool
 * tl_codegen verified: 0x2d01b9ef (telegram_api.tl:2074)
 */
public class AccountResetWebAuthorization <: TLObject {
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x2d01b9ef }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

/**
 * account.resetWebAuthorizations#682d2594 = Bool
 * tl_codegen verified: 0x682d2594 (telegram_api.tl:2075)
 * Terminates all web sessions at once.
 */
public class AccountResetWebAuthorizations <: TLObject {
    public func getConstructorId(): UInt32 { return 0x682d2594 }
    public func serialize(serializer: TLSerializer) {}
}

// ==================== P2-160: Wallpaper / Chat Theme TL types ====================

/**
 * inputWallPaper#e630b979 id:long access_hash:long = InputWallPaper
 * tl_codegen verified: 0xe630b979 (telegram_api.tl:1233)
 * References an existing wallpaper by id + accessHash.
 */
public class InputWallPaperById <: TLObject {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xe630b979 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.id)
        serializer.writeInt64(this.accessHash)
    }
}

/**
 * wallPaperSettings#372efcd0
 * flags:# blur:flags.1?true motion:flags.2?true
 *   background_color:flags.0?int second_background_color:flags.4?int
 *   third_background_color:flags.5?int fourth_background_color:flags.6?int
 *   intensity:flags.3?int rotation:flags.4?int emoticon:flags.7?string
 * tl_codegen verified: 0x372efcd0 (telegram_api.tl:1242)
 *
 * Note: rotation and second_background_color share flags.4; both written when bit 4 is set.
 * Serialized as a boxed type (ctor written by caller via toBytes()).
 */
public class WallPaperSettings <: TLObject {
    public var blur: Bool = false
    public var motion: Bool = false
    public var backgroundColor: Int32 = 0
    public var secondBackgroundColor: Int32 = 0
    public var thirdBackgroundColor: Int32 = 0
    public var fourthBackgroundColor: Int32 = 0
    public var intensity: Int32 = 0
    public var rotation: Int32 = 0
    public var emoticon: String = ""

    public func getConstructorId(): UInt32 { return 0x372efcd0 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.blur) { flags = flags | 2 }
        if (this.motion) { flags = flags | 4 }
        if (this.backgroundColor != 0) { flags = flags | 1 }
        if (this.secondBackgroundColor != 0) { flags = flags | 16 }
        if (this.thirdBackgroundColor != 0) { flags = flags | 32 }
        if (this.fourthBackgroundColor != 0) { flags = flags | 64 }
        if (this.intensity != 0) { flags = flags | 8 }
        if (this.rotation != 0) { flags = flags | 16 }
        if (this.emoticon.size > 0) { flags = flags | 128 }
        serializer.writeInt32(flags)
        if ((flags & 1) != 0) { serializer.writeInt32(this.backgroundColor) }
        if ((flags & 16) != 0) { serializer.writeInt32(this.secondBackgroundColor) }
        if ((flags & 32) != 0) { serializer.writeInt32(this.thirdBackgroundColor) }
        if ((flags & 64) != 0) { serializer.writeInt32(this.fourthBackgroundColor) }
        if ((flags & 8) != 0) { serializer.writeInt32(this.intensity) }
        if ((flags & 16) != 0) { serializer.writeInt32(this.rotation) }
        if ((flags & 128) != 0) { serializer.writeString(this.emoticon) }
    }
}

/**
 * messages.setChatWallPaper#8ffacae1
 * flags:# for_both:flags.3?true revert:flags.4?true peer:InputPeer
 *   wallpaper:flags.0?InputWallPaper settings:flags.2?WallPaperSettings id:flags.1?int
 * tl_codegen verified: 0x8ffacae1 (telegram_api.tl:2381)
 * iOS: buffer.appendInt32(-1879389471) == 0x8ffacae1 unsigned
 *
 * Usage:
 *   - Set by wallpaper object: set wallpaper + hasWallpaper=true
 *   - Reuse existing (setExisting): set id + hasId=true
 *   - Revert to default: set revert=true, no wallpaper/id
 */
public class MessagesSetChatWallPaper <: TLObject {
    public var forBoth: Bool = false
    public var revert: Bool = false
    public var peer: TLObject = InputPeerEmpty()
    public var wallpaper: TLObject = InputPeerEmpty()
    public var hasWallpaper: Bool = false
    public var settings: WallPaperSettings = WallPaperSettings()
    public var hasSettings: Bool = false
    public var id: Int32 = 0
    public var hasId: Bool = false

    public func getConstructorId(): UInt32 { return 0x8ffacae1 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasWallpaper) { flags = flags | 1 }
        if (this.hasId) { flags = flags | 2 }
        if (this.hasSettings) { flags = flags | 4 }
        if (this.forBoth) { flags = flags | 8 }
        if (this.revert) { flags = flags | 16 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        if (this.hasWallpaper) {
            serializer.writeRawBytes(this.wallpaper.toBytes())
        }
        if (this.hasSettings) {
            serializer.writeRawBytes(this.settings.toBytes())
        }
        if (this.hasId) {
            serializer.writeInt32(this.id)
        }
    }
}

/**
 * messages.setChatTheme#081202c9 peer:InputPeer theme:InputChatTheme = Updates
 * iOS Api42.swift:9823 buffer.appendInt32(135398089); python: hex(135398089 & 0xffffffff) == '0x081202c9'
 * theme is boxed InputChatTheme: inputChatThemeEmpty#83268483 or inputChatTheme#c93de95c(emoticon)
 *
 * Sets the chat theme identified by the emoticon string.
 * Pass empty string to clear the theme (sends inputChatThemeEmpty).
 */
public class MessagesSetChatTheme <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var emoticon: String = ""

    // messages.setChatTheme#081202c9 (iOS Api42 layer; python: hex(135398089 & 0xffffffff) == '0x081202c9')
    // theme: InputChatTheme (boxed) — inlined: inputChatThemeEmpty or inputChatTheme(emoticon)
    public func getConstructorId(): UInt32 { return 0x081202c9 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        if (this.emoticon.isEmpty()) {
            // inputChatThemeEmpty#83268483 (python: hex(-2094627709 & 0xffffffff) == '0x83268483')
            serializer.writeUInt32(0x83268483)
        } else {
            // inputChatTheme#c93de95c emoticon:string (python: hex(-918689444 & 0xffffffff) == '0xc93de95c')
            serializer.writeUInt32(0xc93de95c)
            serializer.writeString(this.emoticon)
        }
    }
}

// ==================== P2-157: 联系人扩展方法 ====================

/**
 * contacts.acceptContact#f831a20f id:InputUser = Updates
 * tl_codegen verified via tl_codegen.py: 0xf831a20f (telegram_api.tl:2184)
 * iOS Api42.swift: buffer.appendInt32(-130764241) == 0xf831a20f unsigned
 *
 * Accept a contact request (share phone number back).
 */
public class ContactsAcceptContact <: TLObject {
    public var id: TLObject = InputPeerEmpty()  // InputUser

    public func getConstructorId(): UInt32 { return 0xf831a20f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.id.toBytes())
    }
}

/**
 * contacts.updateContactNote#139f63fb id:InputUser note:TextWithEntities = Bool
 * iOS Api42.swift: buffer.appendInt32(329212923) == 0x139f63fb (python: hex(329212923)='0x139f63fb')
 * Not in td/telegram_api.tl (layer 166+ addition); verified from iOS generated file.
 *
 * note is serialized as textWithEntities#751f3146 text:string entities:Vector<MessageEntity>
 * For plain text with no entities: 0x751f3146 + string + vector_ctor + count(0)
 */
public class ContactsUpdateContactNote <: TLObject {
    public var id: TLObject = InputPeerEmpty()  // InputUser
    public var noteText: String = ""

    public func getConstructorId(): UInt32 { return 0x139f63fb }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.id.toBytes())
        serializer.writeUInt32(0x751f3146)   // textWithEntities constructor
        serializer.writeString(this.noteText)
        serializer.writeUInt32(0x1cb5c415)   // vector constructor
        serializer.writeInt32(0)             // entities count = 0
    }
}

// ==================== P2-150b: Bots / AI / liveLocation TL methods ====================

/**
 * messages.startBot#e6df7378
 * TL (telegram_api.tl:2238):
 *   messages.startBot#e6df7378 bot:InputUser peer:InputPeer random_id:long start_param:string = Updates
 *
 * iOS ref: Api39.swift messages.startBot
 * Starts a bot conversation (deep-link or bot button) by sending /start with optional payload.
 */
public class MessagesStartBot <: TLObject {
    public var bot: TLObject = InputPeerEmpty()   // InputUser
    public var peer: TLObject = InputPeerEmpty()  // InputPeer
    public var randomId: Int64 = 0
    public var startParam: String = ""

    public func getConstructorId(): UInt32 { return 0xe6df7378 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.bot.toBytes())
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt64(this.randomId)
        serializer.writeString(this.startParam)
    }
}

/**
 * messages.transcribeAudio#269e9a49
 * TL (telegram_api.tl:2361):
 *   messages.transcribeAudio#269e9a49 peer:InputPeer msg_id:int = messages.TranscribedAudio
 *
 * Response: messages.transcribedAudio#cfb9d957 (telegram_api.tl:1524)
 *   flags:# pending:flags.0?true transcription_id:long text:string
 *   trial_remains_num:flags.1?int trial_remains_until_date:flags.1?int
 *
 * iOS ref: Api39.swift messages.transcribeAudio
 * Initiates server-side audio transcription for a voice message.
 * The response may be pending=true on first call; the result arrives via updateTranscribedAudio.
 */
public class MessagesTranscribeAudio <: TLObject {
    public var peer: TLObject = InputPeerEmpty()  // InputPeer
    public var msgId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x269e9a49 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.msgId)
    }
}

/**
 * TranscribeAudioResult — parsed response from messages.transcribeAudio
 *
 * messages.transcribedAudio#cfb9d957 flags:# pending:flags.0?true transcription_id:long
 *   text:string trial_remains_num:flags.1?int trial_remains_until_date:flags.1?int
 *
 * tl_codegen verified: 0xcfb9d957 (telegram_api.tl:1524)
 */
public class TranscribeAudioResult {
    public var pending: Bool = false
    public var transcriptionId: Int64 = 0
    public var text: String = ""
    public var trialRemainsNum: Int32 = 0
    public var trialRemainsUntilDate: Int32 = 0
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""

    public init() {}
}

// InlineBotResultsResponse and TranslateTextResult moved to services package:
// - InlineBotResultsResponse superseded by ContextQueryResponse (ChatContextQueryService.cj)
// - TranslateTextResult superseded by TranslateResult (TranslateService.cj)

// ==================== P2-153b: Telegram Business Account Suite ====================

/**
 * businessWeeklyOpen#120b1ab9 start_minute:int end_minute:int = BusinessWeeklyOpen
 * tl_codegen verified: 0x120b1ab9 (telegram_api.tl:1759)
 * Inline struct — serialized inline without boxing in BusinessWorkHours.weekly_open Vector.
 */
public class BusinessWeeklyOpen <: TLObject {
    public var startMinute: Int32 = 0
    public var endMinute: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x120b1ab9 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.startMinute)
        serializer.writeInt32(this.endMinute)
    }
}

/**
 * businessWorkHours#8c92b098 flags:# open_now:flags.0?true timezone_id:string
 *   weekly_open:Vector<BusinessWeeklyOpen> = BusinessWorkHours
 * tl_codegen verified: 0x8c92b098 (telegram_api.tl:1761)
 * Serialized as boxed type (ctor written by AccountUpdateBusinessWorkHours).
 */
public class BusinessWorkHours <: TLObject {
    public var openNow: Bool = false
    public var timezoneId: String = ""
    public var weeklyOpen: ArrayList<BusinessWeeklyOpen> = ArrayList<BusinessWeeklyOpen>()

    public func getConstructorId(): UInt32 { return 0x8c92b098 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.openNow) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeString(this.timezoneId)
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.weeklyOpen.size))
        for (period in this.weeklyOpen) {
            serializer.writeUInt32(period.getConstructorId())
            period.serialize(serializer)
        }
    }
}

/**
 * account.updateBusinessWorkHours#4b00e066 flags:# business_work_hours:flags.0?BusinessWorkHours = Bool
 * tl_codegen verified: 0x4b00e066 (telegram_api.tl:2138)
 * Set hasWorkHours=false to clear (remove) business work hours.
 */
public class AccountUpdateBusinessWorkHours <: TLObject {
    public var hasWorkHours: Bool = false
    public var workHours: BusinessWorkHours = BusinessWorkHours()

    public func getConstructorId(): UInt32 { return 0x4b00e066 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasWorkHours) { flags = flags | 1 }
        serializer.writeInt32(flags)
        if (this.hasWorkHours) {
            serializer.writeUInt32(this.workHours.getConstructorId())
            this.workHours.serialize(serializer)
        }
    }
}

/**
 * account.updateBusinessLocation#9e6b131a flags:# geo_point:flags.1?InputGeoPoint address:flags.0?string = Bool
 * tl_codegen verified: 0x9e6b131a (telegram_api.tl:2139)
 * Set hasAddress=false and hasGeoPoint=false to clear business location.
 */
public class AccountUpdateBusinessLocation <: TLObject {
    public var hasGeoPoint: Bool = false
    public var geoLat: Float64 = 0.0
    public var geoLon: Float64 = 0.0
    public var hasAddress: Bool = false
    public var address: String = ""

    public func getConstructorId(): UInt32 { return 0x9e6b131a }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasAddress) { flags = flags | 1 }
        if (this.hasGeoPoint) { flags = flags | 2 }
        serializer.writeInt32(flags)
        if (this.hasGeoPoint) {
            let gp = InputGeoPoint()
            gp.lat = this.geoLat
            gp.long = this.geoLon
            serializer.writeUInt32(gp.getConstructorId())
            gp.serialize(serializer)
        }
        if (this.hasAddress) { serializer.writeString(this.address) }
    }
}

/**
 * inputBusinessRecipients#6f8b32aa flags:# existing_chats:flags.0?true new_chats:flags.1?true
 *   contacts:flags.2?true non_contacts:flags.3?true exclude_selected:flags.5?true
 *   users:flags.4?Vector<InputUser> = InputBusinessRecipients
 * tl_codegen verified: 0x6f8b32aa (telegram_api.tl:1765)
 */
public class InputBusinessRecipients <: TLObject {
    public var existingChats: Bool = false
    public var newChats: Bool = false
    public var contacts: Bool = false
    public var nonContacts: Bool = false
    public var excludeSelected: Bool = false
    public var users: ArrayList<InputUser> = ArrayList<InputUser>()

    public func getConstructorId(): UInt32 { return 0x6f8b32aa }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.existingChats) { flags = flags | 1 }
        if (this.newChats) { flags = flags | 2 }
        if (this.contacts) { flags = flags | 4 }
        if (this.nonContacts) { flags = flags | 8 }
        if (this.users.size > 0) { flags = flags | 16 }
        if (this.excludeSelected) { flags = flags | 32 }
        serializer.writeInt32(flags)
        if (this.users.size > 0) {
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(Int32(this.users.size))
            for (u in this.users) {
                serializer.writeUInt32(u.getConstructorId())
                u.serialize(serializer)
            }
        }
    }
}

/**
 * inputBusinessGreetingMessage#194cb3b shortcut_id:int recipients:InputBusinessRecipients
 *   no_activity_days:int = InputBusinessGreetingMessage
 * tl_codegen verified: 0x0194cb3b (telegram_api.tl:1773)
 */
public class InputBusinessGreetingMessage <: TLObject {
    public var shortcutId: Int32 = 0
    public var recipients: InputBusinessRecipients = InputBusinessRecipients()
    public var noActivityDays: Int32 = 7

    public func getConstructorId(): UInt32 { return 0x0194cb3b }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.shortcutId)
        serializer.writeUInt32(this.recipients.getConstructorId())
        this.recipients.serialize(serializer)
        serializer.writeInt32(this.noActivityDays)
    }
}

/**
 * account.updateBusinessGreetingMessage#66cdafc4 flags:# message:flags.0?InputBusinessGreetingMessage = Bool
 * tl_codegen verified: 0x66cdafc4 (telegram_api.tl:2140)
 * hasMessage=false clears the greeting message.
 */
public class AccountUpdateBusinessGreetingMessage <: TLObject {
    public var hasMessage: Bool = false
    public var message: InputBusinessGreetingMessage = InputBusinessGreetingMessage()

    public func getConstructorId(): UInt32 { return 0x66cdafc4 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasMessage) { flags = flags | 1 }
        serializer.writeInt32(flags)
        if (this.hasMessage) {
            serializer.writeUInt32(this.message.getConstructorId())
            this.message.serialize(serializer)
        }
    }
}

/**
 * businessAwayMessageScheduleAlways#c9b9e2b9 = BusinessAwayMessageSchedule
 * tl_codegen verified: 0xc9b9e2b9 (telegram_api.tl:1769)
 */
public class BusinessAwayMessageScheduleAlways <: TLObject {
    public func getConstructorId(): UInt32 { return 0xc9b9e2b9 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * businessAwayMessageScheduleOutsideWorkHours#c3f2f501 = BusinessAwayMessageSchedule
 * tl_codegen verified: 0xc3f2f501 (telegram_api.tl:1770)
 */
public class BusinessAwayMessageScheduleOutsideWorkHours <: TLObject {
    public func getConstructorId(): UInt32 { return 0xc3f2f501 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * businessAwayMessageScheduleCustom#cc4d9ecc start_date:int end_date:int = BusinessAwayMessageSchedule
 * tl_codegen verified: 0xcc4d9ecc (telegram_api.tl:1771)
 */
public class BusinessAwayMessageScheduleCustom <: TLObject {
    public var startDate: Int32 = 0
    public var endDate: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xcc4d9ecc }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.startDate)
        serializer.writeInt32(this.endDate)
    }
}

/**
 * inputBusinessAwayMessage#832175e0 flags:# offline_only:flags.0?true shortcut_id:int
 *   schedule:BusinessAwayMessageSchedule recipients:InputBusinessRecipients = InputBusinessAwayMessage
 * tl_codegen verified: 0x832175e0 (telegram_api.tl:1777)
 * scheduleType: 0=always, 1=outsideWorkHours, 2=custom
 */
public class InputBusinessAwayMessage <: TLObject {
    public var offlineOnly: Bool = false
    public var shortcutId: Int32 = 0
    public var scheduleType: Int32 = 0        // 0=always, 1=outsideWorkHours, 2=custom
    public var scheduleStartDate: Int32 = 0
    public var scheduleEndDate: Int32 = 0
    public var recipients: InputBusinessRecipients = InputBusinessRecipients()

    public func getConstructorId(): UInt32 { return 0x832175e0 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.offlineOnly) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeInt32(this.shortcutId)
        if (this.scheduleType == 1) {
            let sched = BusinessAwayMessageScheduleOutsideWorkHours()
            serializer.writeUInt32(sched.getConstructorId())
        } else if (this.scheduleType == 2) {
            let sched = BusinessAwayMessageScheduleCustom()
            sched.startDate = this.scheduleStartDate
            sched.endDate = this.scheduleEndDate
            serializer.writeUInt32(sched.getConstructorId())
            sched.serialize(serializer)
        } else {
            let sched = BusinessAwayMessageScheduleAlways()
            serializer.writeUInt32(sched.getConstructorId())
        }
        serializer.writeUInt32(this.recipients.getConstructorId())
        this.recipients.serialize(serializer)
    }
}

/**
 * account.updateBusinessAwayMessage#a26a7fa5 flags:# message:flags.0?InputBusinessAwayMessage = Bool
 * tl_codegen verified: 0xa26a7fa5 (telegram_api.tl:2141)
 * hasMessage=false clears the away message.
 */
public class AccountUpdateBusinessAwayMessage <: TLObject {
    public var hasMessage: Bool = false
    public var message: InputBusinessAwayMessage = InputBusinessAwayMessage()

    public func getConstructorId(): UInt32 { return 0xa26a7fa5 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasMessage) { flags = flags | 1 }
        serializer.writeInt32(flags)
        if (this.hasMessage) {
            serializer.writeUInt32(this.message.getConstructorId())
            this.message.serialize(serializer)
        }
    }
}

/**
 * inputBusinessIntro#9c469cd flags:# title:string description:string sticker:flags.0?InputDocument
 *   = InputBusinessIntro
 * tl_codegen verified: 0x09c469cd (telegram_api.tl:1804)
 */
public class InputBusinessIntro <: TLObject {
    public var title: String = ""
    public var description: String = ""
    public var hasStickerDocId: Bool = false
    public var stickerDocId: Int64 = 0
    public var stickerAccessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x09c469cd }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasStickerDocId) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeString(this.title)
        serializer.writeString(this.description)
        if (this.hasStickerDocId) {
            // inputDocument#1abfb575 id:long access_hash:long file_reference:bytes
            serializer.writeUInt32(0x1abfb575)
            serializer.writeInt64(this.stickerDocId)
            serializer.writeInt64(this.stickerAccessHash)
            serializer.writeBytes(Array<Byte>(0, repeat: 0))
        }
    }
}

/**
 * account.updateBusinessIntro#a614d034 flags:# intro:flags.0?InputBusinessIntro = Bool
 * tl_codegen verified: 0xa614d034 (telegram_api.tl:2145)
 * hasIntro=false clears the intro.
 */
public class AccountUpdateBusinessIntro <: TLObject {
    public var hasIntro: Bool = false
    public var intro: InputBusinessIntro = InputBusinessIntro()

    public func getConstructorId(): UInt32 { return 0xa614d034 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasIntro) { flags = flags | 1 }
        serializer.writeInt32(flags)
        if (this.hasIntro) {
            serializer.writeUInt32(this.intro.getConstructorId())
            this.intro.serialize(serializer)
        }
    }
}

/**
 * businessBotRights#a0624cf7 flags:# reply:flags.0?true read_messages:flags.1?true ...
 * tl_codegen verified: 0xa0624cf7 (telegram_api.tl:1987)
 * We expose a single Int32 bitmask so callers can pass any flags combination.
 */
public class BusinessBotRights <: TLObject {
    public var flags: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xa0624cf7 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.flags)
    }
}

/**
 * inputBusinessBotRecipients#c4e5921e flags:# existing_chats:flags.0?true new_chats:flags.1?true
 *   contacts:flags.2?true non_contacts:flags.3?true exclude_selected:flags.5?true
 *   users:flags.4?Vector<InputUser> exclude_users:flags.6?Vector<InputUser>
 *   = InputBusinessBotRecipients
 * tl_codegen verified: 0xc4e5921e (telegram_api.tl:1815)
 */
public class InputBusinessBotRecipients <: TLObject {
    public var existingChats: Bool = false
    public var newChats: Bool = false
    public var contacts: Bool = false
    public var nonContacts: Bool = false
    public var excludeSelected: Bool = false
    public var users: ArrayList<InputUser> = ArrayList<InputUser>()
    public var excludeUsers: ArrayList<InputUser> = ArrayList<InputUser>()

    public func getConstructorId(): UInt32 { return 0xc4e5921e }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.existingChats) { flags = flags | 1 }
        if (this.newChats) { flags = flags | 2 }
        if (this.contacts) { flags = flags | 4 }
        if (this.nonContacts) { flags = flags | 8 }
        if (this.users.size > 0) { flags = flags | 16 }
        if (this.excludeSelected) { flags = flags | 32 }
        if (this.excludeUsers.size > 0) { flags = flags | 64 }
        serializer.writeInt32(flags)
        if (this.users.size > 0) {
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(Int32(this.users.size))
            for (u in this.users) {
                serializer.writeUInt32(u.getConstructorId())
                u.serialize(serializer)
            }
        }
        if (this.excludeUsers.size > 0) {
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(Int32(this.excludeUsers.size))
            for (u in this.excludeUsers) {
                serializer.writeUInt32(u.getConstructorId())
                u.serialize(serializer)
            }
        }
    }
}

/**
 * account.updateConnectedBot#66a08c7e flags:# deleted:flags.1?true
 *   rights:flags.0?BusinessBotRights bot:InputUser recipients:InputBusinessBotRecipients = Updates
 * tl_codegen verified: 0x66a08c7e (telegram_api.tl:2142)
 * deleted=true removes the connected bot. rights must be present when not deleting.
 */
public class AccountUpdateConnectedBot <: TLObject {
    public var deleted: Bool = false
    public var hasRights: Bool = false
    public var rights: BusinessBotRights = BusinessBotRights()
    public var bot: InputUser = InputUser()
    public var recipients: InputBusinessBotRecipients = InputBusinessBotRecipients()

    public func getConstructorId(): UInt32 { return 0x66a08c7e }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasRights) { flags = flags | 1 }
        if (this.deleted) { flags = flags | 2 }
        serializer.writeInt32(flags)
        if (this.hasRights) {
            serializer.writeUInt32(this.rights.getConstructorId())
            this.rights.serialize(serializer)
        }
        serializer.writeUInt32(this.bot.getConstructorId())
        this.bot.serialize(serializer)
        serializer.writeUInt32(this.recipients.getConstructorId())
        this.recipients.serialize(serializer)
    }
}

/**
 * account.getBotBusinessConnection#76a86270 connection_id:string = Updates
 * tl_codegen verified: 0x76a86270 (telegram_api.tl:2144)
 * Returns current connected bot info via Updates stream.
 */
public class AccountGetBotBusinessConnection <: TLObject {
    public var connectionId: String = ""

    public func getConstructorId(): UInt32 { return 0x76a86270 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.connectionId)
    }
}

/**
 * inputBusinessChatLink#11679fa7 flags:# message:string entities:flags.0?Vector<MessageEntity>
 *   title:flags.1?string = InputBusinessChatLink
 * tl_codegen verified: 0x11679fa7 (telegram_api.tl:1827)
 * For simplicity we support plain-text message only (no entities).
 */
public class InputBusinessChatLink <: TLObject {
    public var message: String = ""
    public var title: String = ""
    public var hasTitle: Bool = false

    public func getConstructorId(): UInt32 { return 0x11679fa7 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasTitle) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeString(this.message)
        if (this.hasTitle) { serializer.writeString(this.title) }
    }
}

/**
 * account.createBusinessChatLink#8851e68e link:InputBusinessChatLink = BusinessChatLink
 * tl_codegen verified: 0x8851e68e (telegram_api.tl:2149)
 */
public class AccountCreateBusinessChatLink <: TLObject {
    public var link: InputBusinessChatLink = InputBusinessChatLink()

    public func getConstructorId(): UInt32 { return 0x8851e68e }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(this.link.getConstructorId())
        this.link.serialize(serializer)
    }
}

/**
 * account.editBusinessChatLink#8c3410af slug:string link:InputBusinessChatLink = BusinessChatLink
 * tl_codegen verified: 0x8c3410af (telegram_api.tl:2150)
 */
public class AccountEditBusinessChatLink <: TLObject {
    public var slug: String = ""
    public var link: InputBusinessChatLink = InputBusinessChatLink()

    public func getConstructorId(): UInt32 { return 0x8c3410af }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.slug)
        serializer.writeUInt32(this.link.getConstructorId())
        this.link.serialize(serializer)
    }
}

/**
 * account.deleteBusinessChatLink#60073674 slug:string = Bool
 * tl_codegen verified: 0x60073674 (telegram_api.tl:2151)
 */
public class AccountDeleteBusinessChatLink <: TLObject {
    public var slug: String = ""

    public func getConstructorId(): UInt32 { return 0x60073674 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.slug)
    }
}

/**
 * account.getBusinessChatLinks#6f70dde1 = account.BusinessChatLinks
 * tl_codegen verified: 0x6f70dde1 (telegram_api.tl:2152)
 */
public class AccountGetBusinessChatLinks <: TLObject {
    public func getConstructorId(): UInt32 { return 0x6f70dde1 }
    public func serialize(serializer: TLSerializer) {}
}

// ==================== P2-153b: Quick Reply Shortcuts TL methods ====================

/**
 * messages.getQuickReplies#d483f2a8 hash:long = messages.QuickReplies
 * tl_codegen verified: 0xd483f2a8 (telegram_api.tl:2393)
 * hash=0 fetches all; hash from previous response enables incremental update.
 * Response:
 *   messages.quickReplies#c68d6695 quick_replies:Vector<QuickReply> messages:Vector<Message>
 *     chats:Vector<Chat> users:Vector<User>
 *   messages.quickRepliesNotModified#5f91eb5b (no changes)
 */
public class MessagesGetQuickReplies <: TLObject {
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xd483f2a8 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

/**
 * messages.editQuickReplyShortcut#5c003cef shortcut_id:int shortcut:string = Bool
 * tl_codegen verified: 0x5c003cef (telegram_api.tl:2396)
 * Renames an existing quick reply shortcut.
 */
public class MessagesEditQuickReplyShortcut <: TLObject {
    public var shortcutId: Int32 = 0
    public var shortcut: String = ""

    public func getConstructorId(): UInt32 { return 0x5c003cef }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.shortcutId)
        serializer.writeString(this.shortcut)
    }
}

/**
 * messages.deleteQuickReplyShortcut#3cc04740 shortcut_id:int = Bool
 * tl_codegen verified: 0x3cc04740 (telegram_api.tl:2397)
 */
public class MessagesDeleteQuickReplyShortcut <: TLObject {
    public var shortcutId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x3cc04740 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.shortcutId)
    }
}

/**
 * messages.getQuickReplyMessages#94a495c3 flags:# shortcut_id:int id:flags.0?Vector<int> hash:long
 *   = messages.Messages
 * tl_codegen verified: 0x94a495c3 (telegram_api.tl:2398)
 * id=empty list → fetch all messages in the shortcut (hash-based).
 */
public class MessagesGetQuickReplyMessages <: TLObject {
    public var shortcutId: Int32 = 0
    public var ids: ArrayList<Int32> = ArrayList<Int32>()
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x94a495c3 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.ids.size > 0) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeInt32(this.shortcutId)
        if (this.ids.size > 0) {
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(Int32(this.ids.size))
            for (id in this.ids) {
                serializer.writeInt32(id)
            }
        }
        serializer.writeInt64(this.hash)
    }
}

/**
 * messages.reorderQuickReplies#60331907 order:Vector<int> = Bool
 * tl_codegen verified: 0x60331907 (telegram_api.tl:2394)
 * Order is the new ordered list of shortcut_ids.
 */
public class MessagesReorderQuickReplies <: TLObject {
    public var order: ArrayList<Int32> = ArrayList<Int32>()

    public func getConstructorId(): UInt32 { return 0x60331907 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.order.size))
        for (id in this.order) {
            serializer.writeInt32(id)
        }
    }
}

/**
 * messages.updateDialogFiltersOrder#c563c1e4 order:Vector<int> = Bool
 * iOS ref: telegram_api.tl:2314, TelegramApi/Sources/Api42.swift:10363
 * TC-0015 (clist_filter_preset_editor): 上报聊天文件夹（DialogFilter）重排后的顺序。
 * order 是新的 filter id 顺序（含 All Chats 的 id==0）。
 */
public class MessagesUpdateDialogFiltersOrder <: TLObject {
    public var order: ArrayList<Int32> = ArrayList<Int32>()

    public func getConstructorId(): UInt32 { return 0xc563c1e4 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.order.size))
        for (id in this.order) {
            serializer.writeInt32(id)
        }
    }
}

/**
 * messages.updateDialogFilter#1ad4a04a flags:# id:int filter:flags.0?DialogFilter = Bool
 * iOS ref: telegram_api.tl:2313 (td submodule), ChatListFiltering.swift:524
 *   _internal_requestUpdateChatListFilter — flags bit 0 set iff filter != nil (present).
 *   filter == nil (bit0 unset, field omitted) = delete this single dialog filter by id.
 * TC-0015 round4 (clist_filter_preset_editor): 创建/更新单个 filter 的持久化 RPC，
 * 区别于只处理顺序的 messages.updateDialogFiltersOrder#c563c1e4。
 *
 * 与本仓库 DialogFilter 解析对称（core/mtproto/TLResponses.cj parseDialogFilter,
 * dialogFilter#aa472651 变体，iOS telegram_api.tl:1314）：
 *   dialogFilter#aa472651 flags:# ... id:int title:TextWithEntities emoticon:flags.25?string
 *     color:flags.27?int pinned_peers:Vector<InputPeer> include_peers:Vector<InputPeer>
 *     exclude_peers:Vector<InputPeer> = DialogFilter
 * ChatFolder 模型（models/ChatFolder.cj）当前不携带 peer 级 accessHash，本 feature
 * 范围内的新建/推荐添加文件夹在 iOS 侧同样以空 peer 集合创建（后续加入聊天走独立编辑流程，
 * 不在本 feature scope），故 pinned/include/exclude 三个 Vector 均以空 Vector 序列化，
 * 语义与 iOS ChatListFilter.apiFilter() 对新建空过滤器一致，无字段值捏造。
 */
public class MessagesUpdateDialogFilter <: TLObject {
    public var filterId: Int32 = 0
    public var title: String = ""
    // None = 删除该 filter（flags bit0 不置位，filter 字段省略）
    // Some = 创建/更新该 filter（flags bit0 置位，附带 DialogFilter 主体）
    public var hasFilter: Bool = true
    // S029 文件夹编辑器：dialogFilter#aa472651 布尔位 + emoticon + 三个 InputPeer 向量
    //（iOS ChatListFilter.apiFilter()，ChatListFiltering.swift）。peer 由 services 层
    // 用缓存 accessHash 解析为 boxed InputPeer（InputPeerUser/Chat/Channel）后填入。
    public var includeContacts: Bool = false
    public var includeNonContacts: Bool = false
    public var includeGroups: Bool = false
    public var includeChannels: Bool = false
    public var includeBots: Bool = false
    public var excludeMuted: Bool = false
    public var excludeRead: Bool = false
    public var excludeArchived: Bool = false
    public var emoticon: String = ""
    public var hasColor: Bool = false
    public var color: Int32 = 0
    public var isShared: Bool = false
    public var pinnedPeers: ArrayList<TLObject> = ArrayList<TLObject>()
    public var includePeers: ArrayList<TLObject> = ArrayList<TLObject>()
    public var excludePeers: ArrayList<TLObject> = ArrayList<TLObject>()

    public func getConstructorId(): UInt32 { return 0x1ad4a04a }

    private func writePeerVector(serializer: TLSerializer, peers: ArrayList<TLObject>) {
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(peers.size))
        for (p in peers) {
            serializer.writeUInt32(p.getConstructorId())
            p.serialize(serializer)
        }
    }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasFilter) {
            flags = flags | (1 << 0)
        }
        serializer.writeInt32(flags)
        serializer.writeInt32(this.filterId)
        if (this.hasFilter) {
            serializer.writeUInt32(if (this.isShared) { 0x96537bd7 } else { 0xaa472651 })
            var filterFlags: Int32 = 0
            if (!this.isShared) {
                if (this.includeContacts) { filterFlags = filterFlags | (1 << 0) }
                if (this.includeNonContacts) { filterFlags = filterFlags | (1 << 1) }
                if (this.includeGroups) { filterFlags = filterFlags | (1 << 2) }
                if (this.includeChannels) { filterFlags = filterFlags | (1 << 3) }
                if (this.includeBots) { filterFlags = filterFlags | (1 << 4) }
                if (this.excludeMuted) { filterFlags = filterFlags | (1 << 11) }
                if (this.excludeRead) { filterFlags = filterFlags | (1 << 12) }
                if (this.excludeArchived) { filterFlags = filterFlags | (1 << 13) }
            }
            if (this.emoticon.size > 0) { filterFlags = filterFlags | (1 << 25) }
            if (this.hasColor) { filterFlags = filterFlags | (1 << 27) }
            serializer.writeInt32(filterFlags)
            serializer.writeInt32(this.filterId)
            // title: TextWithEntities#751f3146 text:string entities:Vector<MessageEntity>
            serializer.writeUInt32(0x751f3146)
            serializer.writeString(this.title)
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(0) // entities count = 0
            if (this.emoticon.size > 0) { serializer.writeString(this.emoticon) }
            if (this.hasColor) { serializer.writeInt32(this.color) }
            this.writePeerVector(serializer, this.pinnedPeers)
            this.writePeerVector(serializer, this.includePeers)
            if (!this.isShared) { this.writePeerVector(serializer, this.excludePeers) }
        }
    }
}

public class MessagesToggleDialogFilterTags <: TLObject {
    public var enabled: Bool = false
    public func getConstructorId(): UInt32 { return 0xfd2dda49 }
    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(if (this.enabled) { TLConstructors.BOOL_TRUE } else { TLConstructors.BOOL_FALSE })
    }
}
// transcribeAudio response type TranscribeAudioResult remains below (no services-package duplicate).

// ==================== P2-154b: uploadMedia step TL classes ====================

/**
 * inputStickerSetEmpty#ffb62b95 = InputStickerSet
 * tl_codegen verified: 0xffb62b95 (telegram_api.tl:660)
 * Used as stickerset placeholder in documentAttributeSticker when uploading new stickers.
 */
public class InputStickerSetEmpty <: TLObject {
    public func getConstructorId(): UInt32 { return 0xffb62b95 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * documentAttributeSticker#6319d612
 * flags:# mask:flags.1?true alt:string stickerset:InputStickerSet mask_coords:flags.0?MaskCoords
 * tl_codegen verified: 0x6319d612 (telegram_api.tl:617)
 * iOS ImportStickers.swift L81: .documentAttributeSticker(flags:0, alt:alt, stickerset:.inputStickerSetEmpty, maskCoords:nil)
 */
public class DocumentAttributeSticker <: TLObject {
    public var alt: String = ""
    // stickerset: always inputStickerSetEmpty for upload context (mask=false, maskCoords=nil)

    public func getConstructorId(): UInt32 { return 0x6319d612 }

    public func serialize(serializer: TLSerializer) {
        // flags: 0 (mask=false, maskCoords absent)
        serializer.writeInt32(0)
        serializer.writeString(this.alt)
        // stickerset = inputStickerSetEmpty#ffb62b95 (no fields)
        serializer.writeUInt32(0xffb62b95)
        // flags.0 maskCoords absent — not serialized
    }
}

/**
 * documentAttributeImageSize#6c37c15c w:int h:int = DocumentAttribute
 * tl_codegen verified: 0x6c37c15c (telegram_api.tl:615)
 * iOS ImportStickers.swift L85: .documentAttributeImageSize(w: dimensions.width, h: dimensions.height)
 */
public class DocumentAttributeImageSize <: TLObject {
    public var w: Int32 = 512
    public var h: Int32 = 512

    public func getConstructorId(): UInt32 { return 0x6c37c15c }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.w)
        serializer.writeInt32(this.h)
    }
}

/**
 * messages.uploadMedia#14967978
 * flags:# business_connection_id:flags.0?string peer:InputPeer media:InputMedia = MessageMedia
 * tl_codegen verified: 0x14967978 (telegram_api.tl:2277)
 * We always use inputPeerSelf#7da07ec9 as peer; businessConnectionId not used.
 */
public class MessagesUploadMedia <: TLObject {
    public var media: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0x14967978 }

    public func serialize(serializer: TLSerializer) {
        // flags: 0 (no business_connection_id)
        serializer.writeInt32(0)
        // peer: inputPeerSelf#7da07ec9 (no fields)
        serializer.writeUInt32(0x7da07ec9)
        // media: serialize the provided InputMedia object
        serializer.writeRawBytes(this.media.toBytes())
    }
}

// ==================== Phase P2-152b: Passkey / FIDO2 TL Methods ====================

/**
 * account.getPasskeys#ea1f0c52 = account.Passkeys
 * Returns list of registered passkeys for current account.
 * iOS ref: Api42.swift L714 buffer.appendInt32(-367063982)
 * ctor verified: -367063982 -> 0xea1f0c52
 */
public class AccountGetPasskeys <: TLObject {
    public func getConstructorId(): UInt32 { return 0xea1f0c52 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * account.deletePasskey#f5b5563f id:string = Bool
 * Deletes a registered passkey by its credential id.
 * iOS ref: Api42.swift L257 buffer.appendInt32(-172665281)
 * ctor verified: -172665281 -> 0xf5b5563f
 */
public class AccountDeletePasskey <: TLObject {
    public var id: String = ""

    public func getConstructorId(): UInt32 { return 0xf5b5563f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.id)
    }
}

/**
 * account.initPasskeyRegistration#429547e8 = account.PasskeyRegistrationOptions
 * Initiates passkey registration; server returns a DataJSON with WebAuthn
 * PublicKeyCredentialCreationOptions for the platform authenticator.
 * iOS ref: Api42.swift L974 buffer.appendInt32(1117079528)
 * ctor verified: 1117079528 -> 0x429547e8
 */
public class AccountInitPasskeyRegistration <: TLObject {
    public func getConstructorId(): UInt32 { return 0x429547e8 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * account.registerPasskey#55b41fd6 credential:InputPasskeyCredential = Passkey
 * Completes passkey registration by sending the authenticator attestation.
 * credential is pre-serialized (boxed) InputPasskeyCredential bytes.
 * iOS ref: Api42.swift L1089 buffer.appendInt32(1437867990)
 * ctor verified: 1437867990 -> 0x55b41fd6
 *
 * InputPasskeyCredentialPublicKey#3c27b78f id:string rawId:string response:InputPasskeyResponse
 *   InputPasskeyResponseRegister#3e63935c clientData:DataJSON attestationData:bytes
 */
public class AccountRegisterPasskey <: TLObject {
    public var credentialId: String = ""
    public var rawId: String = ""
    public var clientDataJson: String = ""
    public var attestationData: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0x55b41fd6 }

    public func serialize(serializer: TLSerializer) {
        // credential: InputPasskeyCredentialPublicKey#3c27b78f (boxed)
        serializer.writeUInt32(0x3c27b78f)
        serializer.writeString(this.credentialId)
        serializer.writeString(this.rawId)
        // response: InputPasskeyResponseRegister#3e63935c (boxed)
        serializer.writeUInt32(0x3e63935c)
        // clientData: DataJSON#7d748d04 data:string (boxed)
        serializer.writeUInt32(0x7d748d04)
        serializer.writeString(this.clientDataJson)
        serializer.writeBytes(this.attestationData)
    }
}

/**
 * auth.initPasskeyLogin#518ad0b7 api_id:int api_hash:string = auth.PasskeyLoginOptions
 * Initiates a passkey login; server returns DataJSON with WebAuthn
 * PublicKeyCredentialRequestOptions for the platform authenticator.
 * iOS ref: Api42.swift L2466 buffer.appendInt32(1368051895)
 * ctor verified: 1368051895 -> 0x518ad0b7
 */
public class AuthInitPasskeyLogin <: TLObject {
    public var apiId: Int32 = 0
    public var apiHash: String = ""

    public func getConstructorId(): UInt32 { return 0x518ad0b7 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.apiId)
        serializer.writeString(this.apiHash)
    }
}

// ==================== P2-155b: Star Gifts TL 方法 ====================

/**
 * InputSavedStarGift 三个变体 (telegram_api.tl:1971-1973)
 *
 * inputSavedStarGiftUser#69279795 msg_id:int = InputSavedStarGift
 * inputSavedStarGiftChat#f101aa7f peer:InputPeer saved_id:long = InputSavedStarGift
 * inputSavedStarGiftSlug#2085c238 slug:string = InputSavedStarGift
 *
 * iOS ref: StarGiftReference.apiStarGiftReference (StarGifts.swift)
 * tl_codegen verified: 0x69279795 / 0xf101aa7f / 0x2085c238
 */
public class InputSavedStarGiftUser <: TLObject {
    public var msgId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x69279795 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.msgId)
    }
}

public class InputSavedStarGiftChat <: TLObject {
    public var peer: TLObject = InputPeerSelf()
    public var savedId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xf101aa7f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt64(this.savedId)
    }
}

public class InputSavedStarGiftSlug <: TLObject {
    public var slug: String = ""

    public func getConstructorId(): UInt32 { return 0x2085c238 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.slug)
    }
}

/**
 * payments.getStarGifts#c4563590 hash:int = payments.StarGifts
 * tl_codegen verified: 0xc4563590 (telegram_api.tl:2590)
 * iOS ref: getStarGifts in StarGifts.swift
 * 返回 payments.starGifts#901689ea hash:int gifts:Vector<StarGift>
 *   或 payments.starGiftsNotModified#a388a368
 *
 * hash=0 → 强制返回完整列表; hash=非0 → 可能返回 notModified
 */
public class PaymentsGetStarGifts <: TLObject {
    public var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xc4563590 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.hash)
    }
}

/**
 * payments.saveStarGift#2a2a697c flags:# unsave:flags.0?true stargift:InputSavedStarGift = Bool
 * tl_codegen verified: 0x2a2a697c (telegram_api.tl:2591)
 * iOS ref: _internal_updateStarGiftAddedToProfile (StarGifts.swift:1431-1449)
 * unsave=true → 从 profile 移除; unsave=false(flags.0 absent) → 添加到 profile
 */
public class PaymentsSaveStarGift <: TLObject {
    public var unsave: Bool = false
    public var stargift: TLObject = InputSavedStarGiftUser()

    public func getConstructorId(): UInt32 { return 0x2a2a697c }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.unsave) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeUInt32(this.stargift.getConstructorId())
        this.stargift.serialize(serializer)
    }
}

/**
 * payments.convertStarGift#74bf076b stargift:InputSavedStarGift = Bool
 * tl_codegen verified: 0x74bf076b (telegram_api.tl:2592)
 * iOS ref: _internal_convertStarGift (StarGifts.swift:1398-1429)
 * 将收到的礼物转换为 Stars 余额 (convert_stars 字段指示转换价值)
 */
public class PaymentsConvertStarGift <: TLObject {
    public var stargift: TLObject = InputSavedStarGiftUser()

    public func getConstructorId(): UInt32 { return 0x74bf076b }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(this.stargift.getConstructorId())
        this.stargift.serialize(serializer)
    }
}

/**
 * payments.upgradeStarGift#aed6e4f5 flags:# keep_original_details:flags.0?true
 *   stargift:InputSavedStarGift = Updates
 * tl_codegen verified: 0xaed6e4f5 (telegram_api.tl:2600)
 * iOS ref: _internal_upgradeStarGift (StarGifts.swift:1643-1714)
 * 响应: Updates (含 updateNewMessage with messageActionStarGiftUnique)
 * keep_original_details=true → 保留原始发送人信息 (需要付费 upgrade_stars)
 */
public class PaymentsUpgradeStarGift <: TLObject {
    public var keepOriginalDetails: Bool = false
    public var stargift: TLObject = InputSavedStarGiftUser()

    public func getConstructorId(): UInt32 { return 0xaed6e4f5 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.keepOriginalDetails) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeUInt32(this.stargift.getConstructorId())
        this.stargift.serialize(serializer)
    }
}

/**
 * payments.transferStarGift#7f18176a stargift:InputSavedStarGift to_id:InputPeer = Updates
 * tl_codegen verified: 0x7f18176a (telegram_api.tl:2601)
 * iOS ref: _internal_transferStarGift prepaid=true (StarGifts.swift:1604)
 * 响应: Updates (含新消息 action = messageActionStarGiftUnique)
 * 注意: 非 prepaid 转赠需先通过 sendStarsPaymentForm 走 invoice 路径
 */
public class PaymentsTransferStarGift <: TLObject {
    public var stargift: TLObject = InputSavedStarGiftUser()
    public var toId: TLObject = InputPeerSelf()

    public func getConstructorId(): UInt32 { return 0x7f18176a }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(this.stargift.getConstructorId())
        this.stargift.serialize(serializer)
        serializer.writeRawBytes(this.toId.toBytes())
    }
}

/**
 * payments.getStarGiftWithdrawalUrl#d06e93a8
 *   stargift:InputSavedStarGift password:InputCheckPasswordSRP
 *   = payments.StarGiftWithdrawalUrl
 * tl_codegen verified: 0xd06e93a8 (telegram_api.tl:2605)
 * iOS ref: getStarGiftWithdrawalUrl in TelegramEnginePayments.swift
 * 响应: payments.starGiftWithdrawalUrl#84aa3a9c url:string
 * 需要 2FA SRP 密码验证
 */
public class PaymentsGetStarGiftWithdrawalUrl <: TLObject {
    public var stargift: TLObject = InputSavedStarGiftUser()
    public var password: InputCheckPasswordSRP = InputCheckPasswordSRP()

    public func getConstructorId(): UInt32 { return 0xd06e93a8 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(this.stargift.getConstructorId())
        this.stargift.serialize(serializer)
        serializer.writeUInt32(this.password.getConstructorId())
        this.password.serialize(serializer)
    }
}

/**
 * StarsAmount — boxed serializable wrapper for wire use in method requests.
 * Two variants per iOS Api27.swift:1021-1091:
 *   starsAmount#bbb6b4a3 amount:long nanos:int   (standard Stars balance/price)
 *   starsTonAmount#74aee3e0 amount:long           (TON amount variant)
 * Use kind="stars" (default) for standard Stars pricing; kind="ton" for TON.
 * nanos is always 0 for integer star prices (no sub-unit fractional Stars yet).
 */
public class StarsAmount <: TLObject {
    public var kind: String = "stars"    // "stars" | "ton"
    public var amount: Int64 = 0         // Stars count (or TON amount for kind="ton")
    public var nanos: Int32 = 0          // fractional nanos (0 for integer star counts)

    public func getConstructorId(): UInt32 {
        if (this.kind == "ton") {
            return 0x74aee3e0
        }
        return 0xbbb6b4a3
    }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.amount)
        if (this.kind != "ton") {
            serializer.writeInt32(this.nanos)
        }
    }
}

/**
 * payments.updateStarGiftPrice#edbe6ccb stargift:InputSavedStarGift resellAmount:StarsAmount = Updates
 * tl_codegen verified: 0xedbe6ccb (Api42.swift:11592; appendInt32(-306287413))
 * iOS ref: updateStarGiftPrice in TelegramEnginePayments.swift
 * Layer diff: ctor changed; resell_stars:long replaced by resellAmount:StarsAmount (boxed)
 * Wire order: stargift(boxed) + resellAmount(boxed StarsAmount)
 * resellAmount.amount=0 → 下架 (停止转售); resellAmount.amount>0 → 设置转售价格
 */
public class PaymentsUpdateStarGiftPrice <: TLObject {
    public var stargift: TLObject = InputSavedStarGiftUser()
    public var resellAmount: StarsAmount = StarsAmount()

    public func getConstructorId(): UInt32 { return 0xedbe6ccb }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.stargift.toBytes())
        serializer.writeRawBytes(this.resellAmount.toBytes())
    }
}

/**
 * payments.getSavedStarGifts#a319e569 flags:# peer:InputPeer collection_id:flags.6?int
 *   offset:string limit:int = payments.SavedStarGifts
 * tl_codegen verified: 0xa319e569 (Api42.swift:10984; appendInt32(-1558583959))
 * iOS ref: getSavedStarGifts in StarGifts.swift:2011-2040 (TelegramCore)
 * Layer diff: ctor changed; flags bitmap resync per iOS current layer:
 *   bit 0: exclude_unsaved (exclude_hidden in filter)
 *   bit 1: exclude_saved   (exclude_displayed in filter)
 *   bit 2: exclude_unlimited
 *   bit 4: exclude_unique
 *   bit 5: sort_by_value
 *   bit 6: collection_id present (NEW — conditional int32 in wire)
 *   bit 7: exclude_limited_upgradable (NEW — split from old bit 3 exclude_limited)
 *   bit 8: exclude_limited_non_upgradable (NEW)
 *   bit 9: peer_color_mode (NEW)
 * Wire order: flags(int32) + peer(boxed) + [collection_id:int32 if bit6] + offset(string) + limit(int32)
 * 响应: payments.savedStarGifts#95f389b1 (分页列表 + count + gifts + next_offset + chats + users)
 */
public class PaymentsGetSavedStarGifts <: TLObject {
    public var excludeUnsaved: Bool = false             // bit 0
    public var excludeSaved: Bool = false               // bit 1
    public var excludeUnlimited: Bool = false           // bit 2
    public var excludeUnique: Bool = false              // bit 4
    public var sortByValue: Bool = false                // bit 5
    public var hasCollectionId: Bool = false            // bit 6 — presence gate for collectionId
    public var collectionId: Int32 = 0                  // bit 6: optional collection filter
    public var excludeLimitedUpgradable: Bool = false   // bit 7 (NEW)
    public var excludeLimitedNonUpgradable: Bool = false // bit 8 (NEW)
    public var peerColorMode: Bool = false              // bit 9 (NEW)
    public var peer: TLObject = InputPeerSelf()
    public var offset: String = ""
    public var limit: Int32 = 20

    public func getConstructorId(): UInt32 { return 0xa319e569 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.excludeUnsaved) { flags = flags | (1 << 0) }
        if (this.excludeSaved) { flags = flags | (1 << 1) }
        if (this.excludeUnlimited) { flags = flags | (1 << 2) }
        if (this.excludeUnique) { flags = flags | (1 << 4) }
        if (this.sortByValue) { flags = flags | (1 << 5) }
        if (this.hasCollectionId) { flags = flags | (1 << 6) }
        if (this.excludeLimitedUpgradable) { flags = flags | (1 << 7) }
        if (this.excludeLimitedNonUpgradable) { flags = flags | (1 << 8) }
        if (this.peerColorMode) { flags = flags | (1 << 9) }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        if (this.hasCollectionId) { serializer.writeInt32(this.collectionId) }
        serializer.writeString(this.offset)
        serializer.writeInt32(this.limit)
    }
}

/**
 * StarGiftAttributeIdEntry — serializable StarGiftAttributeId for getResaleStarGifts filter.
 * Variants (iOS Api27.swift:54-153):
 *   starGiftAttributeIdBackdrop#1f01c757  backdropId:int
 *   starGiftAttributeIdModel#48aaae3c     documentId:long
 *   starGiftAttributeIdPattern#4a162433   documentId:long
 * kind: "backdrop" | "model" | "pattern"
 */
public class StarGiftAttributeIdEntry {
    public var kind: String = "model"
    public var backdropId: Int32 = 0
    public var documentId: Int64 = 0

    public func toBytes(): Array<Byte> {
        let s = TLSerializer()
        if (kind == "backdrop") {
            s.writeUInt32(0x1f01c757)
            s.writeInt32(this.backdropId)
        } else if (kind == "pattern") {
            s.writeUInt32(0x4a162433)
            s.writeInt64(this.documentId)
        } else {
            s.writeUInt32(0x48aaae3c)
            s.writeInt64(this.documentId)
        }
        return s.getBytes()
    }
}

/**
 * payments.getResaleStarGifts#7a5fa236 flags:# sort_by_price:flags.1?true sort_by_num:flags.2?true
 *   attributes_hash:flags.0?long gift_id:long attributes:flags.3?Vector<StarGiftAttributeId>
 *   offset:string limit:int = payments.ResaleStarGifts
 * tl_codegen verified: 0x7a5fa236 (telegram_api.tl:2609)
 * iOS ref: getResaleStarGifts (Api42.swift:10923-10948)
 * Wire order: flags → [flags.0?attributesHash] → giftId → [flags.3?Vector<attributeId>] → offset → limit
 * P2-155g: attributes (flags.3) now supported for resale attribute filter
 */
public class PaymentsGetResaleStarGifts <: TLObject {
    public var sortByPrice: Bool = false
    public var sortByNum: Bool = false
    public var starsOnly: Bool = false
    public var attributesHash: Int64 = 0
    public var giftId: Int64 = 0
    public var offset: String = ""
    public var limit: Int32 = 20
    public var attributes: ArrayList<StarGiftAttributeIdEntry> = ArrayList<StarGiftAttributeIdEntry>()

    public func getConstructorId(): UInt32 { return 0x7a5fa236 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 1
        if (this.sortByPrice) { flags = flags | 2 }
        if (this.sortByNum) { flags = flags | 4 }
        if (this.attributes.size > 0) { flags = flags | 8 }
        if (this.starsOnly) { flags = flags | 32 }
        serializer.writeInt32(flags)
        serializer.writeInt64(this.attributesHash)
        serializer.writeInt64(this.giftId)
        if (this.attributes.size > 0) {
            serializer.writeUInt32(0x1cb5c415)
            serializer.writeInt32(Int32(this.attributes.size))
            for (attr in this.attributes) {
                serializer.writeRawBytes(attr.toBytes())
            }
        }
        serializer.writeString(this.offset)
        serializer.writeInt32(this.limit)
    }
}

/**
 * payments.getStarGiftUpgradePreview#9c9abcb1 gift_id:long = payments.StarGiftUpgradePreview
 * tl_codegen verified: 0x9c9abcb1 (telegram_api.tl:2599)
 * iOS ref: getStarGiftUpgradePreview in TelegramEnginePayments.swift
 * 响应: payments.starGiftUpgradePreview#167bd90b sample_attributes:Vector<StarGiftAttribute>
 */
public class PaymentsGetStarGiftUpgradePreview <: TLObject {
    public var giftId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x9c9abcb1 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.giftId)
    }
}

// ==================== P2-155c: Premium Gift Codes + Giveaways ====================

/**
 * payments.checkGiftCode#8e51b4c1 slug:string = payments.CheckedGiftCode
 * tl_codegen verified: 0x8e51b4c1 (telegram_api.tl:2572)
 * iOS ref: _internal_checkPremiumGiftCode (GiftCodes.swift:267)
 * Response: payments.checkedGiftCode#284a1096
 */
public class PaymentsCheckGiftCode <: TLObject {
    public var slug: String = ""

    public func getConstructorId(): UInt32 { return 0x8e51b4c1 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.slug)
    }
}

/**
 * payments.applyGiftCode#f6e26854 slug:string = Updates
 * tl_codegen verified: 0xf6e26854 (telegram_api.tl:2573)
 * iOS ref: _internal_applyPremiumGiftCode (GiftCodes.swift:295)
 * Response: Updates (updates#74ae4240 / updatesCombined#725b04c3 / updateShort#78d4dec1 / updatesTooLong#e317af7e)
 */
public class PaymentsApplyGiftCode <: TLObject {
    public var slug: String = ""

    public func getConstructorId(): UInt32 { return 0xf6e26854 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.slug)
    }
}

/**
 * payments.getPremiumGiftCodeOptions#2757ba54 flags:# boost_peer:flags.0?InputPeer = Vector<PremiumGiftCodeOption>
 * tl_codegen verified: 0x2757ba54 (telegram_api.tl:2571)
 * iOS ref: _internal_premiumGiftCodeOptions (GiftCodes.swift:199)
 * boost_peer is optional; pass None to get global options
 * Response: Vector<premiumGiftCodeOption#257e962b>
 */
public class PaymentsGetPremiumGiftCodeOptions <: TLObject {
    public var boostPeer: Option<TLObject> = None

    public func getConstructorId(): UInt32 { return 0x2757ba54 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        match (this.boostPeer) {
            case Some(_) => flags = flags | 1
            case None => ()
        }
        serializer.writeInt32(flags)
        match (this.boostPeer) {
            case Some(peer) => serializer.writeRawBytes(peer.toBytes())
            case None => ()
        }
    }
}

/**
 * payments.getGiveawayInfo#f4239425 peer:InputPeer msg_id:int = payments.GiveawayInfo
 * tl_codegen verified: 0xf4239425 (telegram_api.tl:2574)
 * iOS ref: _internal_getPremiumGiveawayInfo (GiftCodes.swift:109)
 * Response: payments.giveawayInfo#4367daa0 OR payments.giveawayInfoResults#e175e66f
 * peer: the chat/channel that created the giveaway
 */
public class PaymentsGetGiveawayInfo <: TLObject {
    public var peer: TLObject = InputPeerSelf()
    public var msgId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xf4239425 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.msgId)
    }
}

/**
 * inputStorePaymentPremiumGiveaway#160544ca flags:# only_new_subscribers:flags.0?true
 *   winners_are_visible:flags.3?true boost_peer:InputPeer additional_peers:flags.1?Vector<InputPeer>
 *   countries_iso2:flags.2?Vector<string> prize_description:flags.4?string random_id:long
 *   until_date:int currency:string amount:long = InputStorePaymentPurpose
 * tl_codegen verified: 0x160544ca (telegram_api.tl:1531)
 */
public class InputStorePaymentPremiumGiveaway <: TLObject {
    public var onlyNewSubscribers: Bool = false
    public var winnersAreVisible: Bool = false
    public var boostPeer: TLObject = InputPeerSelf()
    public var additionalPeers: ArrayList<TLObject> = ArrayList<TLObject>()
    public var countriesIso2: ArrayList<String> = ArrayList<String>()
    public var prizeDescription: Option<String> = None
    public var randomId: Int64 = 0
    public var untilDate: Int32 = 0
    public var currency: String = ""
    public var amount: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x160544ca }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.onlyNewSubscribers) { flags = flags | 1 }
        if (this.additionalPeers.size > 0) { flags = flags | 2 }
        if (this.countriesIso2.size > 0) { flags = flags | 4 }
        if (this.winnersAreVisible) { flags = flags | 8 }
        match (this.prizeDescription) {
            case Some(_) => flags = flags | 16
            case None => ()
        }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.boostPeer.toBytes())
        if (this.additionalPeers.size > 0) {
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(Int32(this.additionalPeers.size))
            for (ap in this.additionalPeers) {
                serializer.writeRawBytes(ap.toBytes())
            }
        }
        if (this.countriesIso2.size > 0) {
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(Int32(this.countriesIso2.size))
            for (cc in this.countriesIso2) {
                serializer.writeString(cc)
            }
        }
        match (this.prizeDescription) {
            case Some(desc) => serializer.writeString(desc)
            case None => ()
        }
        serializer.writeInt64(this.randomId)
        serializer.writeInt32(this.untilDate)
        serializer.writeString(this.currency)
        serializer.writeInt64(this.amount)
    }
}

/**
 * inputStorePaymentStarsGiveaway#751f08fa flags:# only_new_subscribers:flags.0?true
 *   winners_are_visible:flags.3?true stars:long boost_peer:InputPeer
 *   additional_peers:flags.1?Vector<InputPeer> countries_iso2:flags.2?Vector<string>
 *   prize_description:flags.4?string random_id:long until_date:int
 *   currency:string amount:long users:int = InputStorePaymentPurpose
 * tl_codegen verified: 0x751f08fa (telegram_api.tl:1534)
 */
public class InputStorePaymentStarsGiveaway <: TLObject {
    public var onlyNewSubscribers: Bool = false
    public var winnersAreVisible: Bool = false
    public var stars: Int64 = 0
    public var boostPeer: TLObject = InputPeerSelf()
    public var additionalPeers: ArrayList<TLObject> = ArrayList<TLObject>()
    public var countriesIso2: ArrayList<String> = ArrayList<String>()
    public var prizeDescription: Option<String> = None
    public var randomId: Int64 = 0
    public var untilDate: Int32 = 0
    public var currency: String = ""
    public var amount: Int64 = 0
    public var users: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x751f08fa }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.onlyNewSubscribers) { flags = flags | 1 }
        if (this.additionalPeers.size > 0) { flags = flags | 2 }
        if (this.countriesIso2.size > 0) { flags = flags | 4 }
        if (this.winnersAreVisible) { flags = flags | 8 }
        match (this.prizeDescription) {
            case Some(_) => flags = flags | 16
            case None => ()
        }
        serializer.writeInt32(flags)
        serializer.writeInt64(this.stars)
        serializer.writeRawBytes(this.boostPeer.toBytes())
        if (this.additionalPeers.size > 0) {
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(Int32(this.additionalPeers.size))
            for (ap in this.additionalPeers) {
                serializer.writeRawBytes(ap.toBytes())
            }
        }
        if (this.countriesIso2.size > 0) {
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(Int32(this.countriesIso2.size))
            for (cc in this.countriesIso2) {
                serializer.writeString(cc)
            }
        }
        match (this.prizeDescription) {
            case Some(desc) => serializer.writeString(desc)
            case None => ()
        }
        serializer.writeInt64(this.randomId)
        serializer.writeInt32(this.untilDate)
        serializer.writeString(this.currency)
        serializer.writeInt64(this.amount)
        serializer.writeInt32(this.users)
    }
}

/**
 * payments.launchPrepaidGiveaway#5ff58f20 peer:InputPeer giveaway_id:long
 *   purpose:InputStorePaymentPurpose = Updates
 * tl_codegen verified: 0x5ff58f20 (telegram_api.tl:2575)
 * iOS ref: _internal_launchPrepaidGiveaway (GiftCodes.swift:360)
 * Response: Updates (updates#74ae4240 / updatesCombined#725b04c3 / updateShort#78d4dec1 / updatesTooLong#e317af7e)
 * purpose must be InputStorePaymentPremiumGiveaway or InputStorePaymentStarsGiveaway
 */
public class PaymentsLaunchPrepaidGiveaway <: TLObject {
    public var peer: TLObject = InputPeerSelf()
    public var giveawayId: Int64 = 0
    public var purpose: TLObject = InputStorePaymentPremiumGiveaway()

    public func getConstructorId(): UInt32 { return 0x5ff58f20 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt64(this.giveawayId)
        serializer.writeRawBytes(this.purpose.toBytes())
    }
}

// ==================== P2-155d: Stars Subscriptions + Revenue ====================

/**
 * payments.getStarsSubscriptions#032512c5 flags:# missing_balance:flags.0?true
 *   peer:InputPeer offset:string = payments.StarsStatus
 * tl_codegen verified: 0x032512c5 (telegram_api.tl:2586)
 * iOS ref: Api42.swift L11227 buffer.appendInt32(52761285)
 * 返回 payments.starsStatus#6c9ce8ed；其 subscriptions 字段含分页后的订阅列表
 * missingBalance=true → 优先返回余额不足的订阅
 */
public class PaymentsGetStarsSubscriptions <: TLObject {
    public var missingBalance: Bool = false
    public var peer: TLObject = InputPeerSelf()
    public var offset: String = ""

    public func getConstructorId(): UInt32 { return 0x032512c5 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.missingBalance) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.offset)
    }
}

/**
 * payments.changeStarsSubscription#c7770878 flags:# peer:InputPeer
 *   subscription_id:string canceled:flags.0?Bool = Bool
 * tl_codegen verified: 0xc7770878 (telegram_api.tl:2587)
 * iOS ref: Api42.swift L10583 buffer.appendInt32(-948500360)
 * canceled present → 取消(true)/恢复(false) 订阅; canceled absent → 不改变取消状态
 */
public class PaymentsChangeStarsSubscription <: TLObject {
    public var peer: TLObject = InputPeerSelf()
    public var subscriptionId: String = ""
    public var hasCanceled: Bool = false
    public var canceled: Bool = false

    public func getConstructorId(): UInt32 { return 0xc7770878 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasCanceled) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.subscriptionId)
        if (this.hasCanceled) {
            if (this.canceled) {
                serializer.writeUInt32(0x997275b5)
            } else {
                serializer.writeUInt32(0xbc799737)
            }
        }
    }
}

/**
 * payments.fulfillStarsSubscription#cc5bebb3 peer:InputPeer subscription_id:string = Bool
 * tl_codegen verified: 0xcc5bebb3 (telegram_api.tl:2588)
 * iOS ref: Api42.swift L10767 buffer.appendInt32(-866391117)
 * 履行订阅（向 bot 订阅频道时手动确认，补充缺失余额后调用）
 */
public class PaymentsFulfillStarsSubscription <: TLObject {
    public var peer: TLObject = InputPeerSelf()
    public var subscriptionId: String = ""

    public func getConstructorId(): UInt32 { return 0xcc5bebb3 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.subscriptionId)
    }
}

/**
 * payments.getStarsRevenueStats#d91ffad6 flags:# dark:flags.0?true peer:InputPeer
 *   = payments.StarsRevenueStats
 * tl_codegen verified: 0xd91ffad6 (telegram_api.tl:2581)
 * iOS ref: Api42.swift L11175 buffer.appendInt32(-652215594)
 * 返回 payments.starsRevenueStats#c92bb73b:
 *   revenue_graph:StatsGraph status:StarsRevenueStatus usd_rate:double
 * StarsRevenueStatus#febe5491: flags current_balance available_balance overall_revenue
 *   next_withdrawal_at:flags.1?int
 * dark=true → 请求暗色主题图表
 */
public class PaymentsGetStarsRevenueStats <: TLObject {
    public var dark: Bool = false
    // P2-368: ton=true → 请求 TON 广告收入（flags bit 1）；false → Stars 收入（P2-369）
    // iOS ref: StarsRevenueStatistics.swift L186 flags |= (1 << 1) when ton=true
    public var ton: Bool = false
    public var peer: TLObject = InputPeerSelf()

    public func getConstructorId(): UInt32 { return 0xd91ffad6 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.dark) { flags = flags | 1 }
        if (this.ton) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

/**
 * payments.getStarsRevenueWithdrawalUrl (iOS layer)
 *   flags:# peer:InputPeer amount:flags.1?long password:InputCheckPasswordSRP
 *   = payments.StarsRevenueWithdrawalUrl
 * tl_codegen verified from iOS Api42.swift L11191: buffer.appendInt32(607378578)
 * → signed int32 607378578 → unsigned UInt32 0x2433dc92
 * Note: telegram_api.tl:2582 shows older ctor #13bbe8b3 without flags/amount;
 *       iOS client (newer layer) uses 0x2433dc92 with flags + optional amount.
 *       Using iOS ctor to match actual server deployed behavior.
 * 返回 payments.starsRevenueWithdrawalUrl#1dab80b7 url:string
 * amount present (flags.1) → 提现指定 Stars 金额; absent → 提现全部可用余额
 */
public class PaymentsGetStarsRevenueWithdrawalUrl <: TLObject {
    public var peer: TLObject = InputPeerSelf()
    // P2-368: ton=true → TON 提现 (flags bit 0), false → Stars 提现 (flags bit 1 = stars mode)
    // iOS ref: StarsRevenueStatistics.swift L424 flags |= 1 << 0 when ton; L427 |= 1 << 1 when stars
    public var ton: Bool = false
    public var hasAmount: Bool = false
    public var amount: Int64 = 0
    public var password: InputCheckPasswordSRP = InputCheckPasswordSRP()

    public func getConstructorId(): UInt32 { return 0x2433dc92 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.ton) { flags = flags | 1 }       // bit 0 = ton
        if (this.hasAmount) { flags = flags | 2 }  // bit 1 = amount present
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        if (this.hasAmount) { serializer.writeInt64(this.amount) }
        serializer.writeUInt32(this.password.getConstructorId())
        this.password.serialize(serializer)
    }
}

// ==================== P2-367: premium.getBoostsStatus / premium.getBoostsList ====================

/**
 * premium.getBoostsStatus#042f1f61 peer:InputPeer = premium.BoostsStatus
 * tl_codegen verified: 0x042f1f61
 * iOS ref: Api42.swift L12589 buffer.appendInt32(70197089)
 * python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',70197089))[0]))"
 * → 0x042f1f61
 * 返回 premium.boostsStatus#4959427a:
 *   flags:# level:int current_level_boosts:int boosts:int
 *   gift_boosts:flags.4?int next_level_boosts:flags.0?int
 *   premium_audience:flags.1?StatsPercentValue boost_url:string
 *   prepaid_giveaways:flags.3?Vector next_level_boosts 和 boosts 用于计算进度
 */
public class PremiumGetBoostsStatus <: TLObject {
    public var peer: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0x042f1f61 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

/**
 * premium.getBoostsList#60f67660 flags:# gifts:flags.0?true peer:InputPeer
 *   offset:string limit:int = premium.BoostsList
 * tl_codegen verified: 0x60f67660
 * iOS ref: Api42.swift L12571 buffer.appendInt32(1626764896)
 * python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',1626764896))[0]))"
 * → 0x60f67660
 * flags.0 = gifts: true → 请求 gift boosts（Tab Gifts）；false → 普通 boosts（Tab Boosts）
 * 返回 premium.boostsList#86f8613c:
 *   flags:# count:int boosts:Vector<Boost> next_offset:flags.0?string users:Vector<User>
 * Boost#4b3e14d6: flags:# id:string userId:flags.0?long giveaway_msg_id:flags.2?int
 *   date:int expires:int used_gift_slug:flags.4?string multiplier:flags.5?int stars:flags.6?long
 */
public class PremiumGetBoostsList <: TLObject {
    public var gifts: Bool = false
    public var peer: TLObject = InputPeerEmpty()
    public var offset: String = ""
    public var limit: Int32 = 50

    public func getConstructorId(): UInt32 { return 0x60f67660 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.gifts) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.offset)
        serializer.writeInt32(this.limit)
    }
}

// ==================== P2-146: 聊天历史自动删除定时 ====================

/**
 * messages.setHistoryTTL#b80e5fe4 peer:InputPeer period:int = Updates
 *
 * 设置指定 peer 的聊天历史自动删除定时（Auto-Delete Timer）。
 *
 * iOS 对应: Api.functions.messages.setHistoryTTL(peer:period:) in Api42.swift:9927
 * TL wire (iOS Api42.swift:9929): buffer.appendInt32(-1207017500) = 0xb80e5fe4
 *   peer.serialize(buffer, true)  -> boxed InputPeer
 *   serializeInt32(period, boxed: false)  -> unboxed Int32
 *
 * period 含义:
 *   0       = 关闭自动删除
 *   86400   = 24 小时
 *   604800  = 7 天
 *   2678400 = 31 天
 *   其他正整数 = 自定义秒数
 *
 * 响应: Updates (updates#74ae4240 / updatesCombined#725b04c3 /
 *               updateShort#78d4dec1 / updatesTooLong#e317af7e)
 */
public class MessagesSetHistoryTTL <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var period: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xb80e5fe4 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.period)
    }
}

/**
 * messages.editChatDefaultBannedRights — 设置群/频道的默认成员权限
 * Constructor: 0xa5866b41
 *
 * TL: messages.editChatDefaultBannedRights#a5866b41 peer:InputPeer banned_rights:ChatBannedRights = Updates
 *
 * iOS ref: Api42.swift L6200 buffer.appendInt32(-1517917375)
 * ctor verified (python): -1517917375 & 0xFFFFFFFF = 0xa5866b41
 * TL schema: telegram_api.tl:2296
 *
 * peer 为 boxed InputPeer 变体；banned_rights 为 boxed ChatBannedRights#9f120418
 *
 * ChatBannedRights 权限位定义（TL schema chatBannedRights#9f120418，ios Api4.swift L1371）：
 *   bit 0:  view_messages    bit 1:  send_messages   bit 2:  send_media
 *   bit 3:  send_stickers    bit 4:  send_gifs       bit 5:  send_games
 *   bit 6:  send_inline      bit 7:  embed_links     bit 8:  send_polls
 *   bit 10: change_info      bit 15: invite_users    bit 17: pin_messages
 *   bit 18: manage_topics    bit 19: send_photos     bit 20: send_videos
 *   bit 21: send_roundvideos bit 22: send_audios     bit 23: send_voices
 *   bit 24: send_docs        bit 25: send_plain
 *
 * 响应: Updates (4 变体)
 */
public class MessagesEditChatDefaultBannedRights <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var bannedRights: ChatBannedRights = ChatBannedRights()

    public func getConstructorId(): UInt32 { return 0xa5866b41 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeRawBytes(this.bannedRights.toBytes())
    }
}

/**
 * channels.toggleSlowMode — 设置超级群慢速模式间隔
 * Constructor: 0xedd49ef0
 *
 * TL: channels.toggleSlowMode#edd49ef0 channel:InputChannel seconds:int = Updates
 *
 * iOS ref: Api42.swift L4229 buffer.appendInt32(-304832784)
 * ctor verified (python): -304832784 & 0xFFFFFFFF = 0xedd49ef0
 * TL schema: telegram_api.tl:2498
 *
 * seconds 预设常量（服务端接受）: 0 / 10 / 30 / 60 / 300 / 900 / 3600
 *
 * 响应: Updates (4 变体)
 */
public class ChannelsToggleSlowMode <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var seconds: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xedd49ef0 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeInt32(this.seconds)
    }
}

/**
 * auth.finishPasskeyLogin#9857ad07 flags:# credential:InputPasskeyCredential
 *   from_dc_id:flags.0?int from_auth_key_id:flags.0?long = auth.Authorization
 * Completes passkey login by sending the authenticator assertion.
 * iOS ref: Api42.swift L2378 buffer.appendInt32(-1739084537)
 * ctor verified: -1739084537 -> 0x9857ad07
 *
 * InputPasskeyCredentialPublicKey#3c27b78f id:string rawId:string response:InputPasskeyResponse
 *   InputPasskeyResponseLogin#c31fc14a clientData:DataJSON authenticatorData:bytes
 *                               signature:bytes userHandle:string
 */
public class AuthFinishPasskeyLogin <: TLObject {
    public var credentialId: String = ""
    public var rawId: String = ""
    public var clientDataJson: String = ""
    public var authenticatorData: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var signature: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var userHandle: String = ""

    public func getConstructorId(): UInt32 { return 0x9857ad07 }

    public func serialize(serializer: TLSerializer) {
        // flags: 0 (fromDcId and fromAuthKeyId absent)
        serializer.writeInt32(0)
        // credential: InputPasskeyCredentialPublicKey#3c27b78f (boxed)
        serializer.writeUInt32(0x3c27b78f)
        serializer.writeString(this.credentialId)
        serializer.writeString(this.rawId)
        // response: InputPasskeyResponseLogin#c31fc14a (boxed)
        serializer.writeUInt32(0xc31fc14a)
        // clientData: DataJSON#7d748d04 data:string (boxed)
        serializer.writeUInt32(0x7d748d04)
        serializer.writeString(this.clientDataJson)
        serializer.writeBytes(this.authenticatorData)
        serializer.writeBytes(this.signature)
        serializer.writeString(this.userHandle)
    }
}

// ==================== P2-147: Reaction union variants ====================

/**
 * reactionEmoji#1b2286b8 emoticon:string = Reaction
 *
 * iOS ref: Api22.swift serialize case .reactionEmoji => buffer.appendInt32(455247544)
 * ctor verified (python): 455247544 => 0x1b2286b8
 */
public class ReactionEmoji <: TLObject {
    public var emoticon: String = ""

    public func getConstructorId(): UInt32 { return 0x1b2286b8 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.emoticon)
    }
}

/**
 * reactionCustomEmoji#8935fc73 document_id:long = Reaction
 *
 * iOS ref: Api22.swift serialize case .reactionCustomEmoji => buffer.appendInt32(-1992950669)
 * ctor verified (python): -1992950669 & 0xFFFFFFFF = 0x8935fc73
 */
public class ReactionCustomEmoji <: TLObject {
    public var documentId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x8935fc73 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.documentId)
    }
}

/**
 * reactionEmpty#79f5d419 = Reaction
 *
 * iOS ref: Api22.swift serialize case .reactionEmpty => buffer.appendInt32(2046153753)
 * ctor verified (python): 2046153753 => 0x79f5d419
 */
public class ReactionEmpty <: TLObject {
    public func getConstructorId(): UInt32 { return 0x79f5d419 }
    public func serialize(serializer: TLSerializer) {}
}

// ==================== P2-147: ChatReactions union variants ====================

/**
 * chatReactionsNone#eafc32bc = ChatReactions
 *
 * iOS ref: Api5.swift serialize case .chatReactionsNone => buffer.appendInt32(-352570692)
 * ctor verified (python): -352570692 & 0xFFFFFFFF = 0xeafc32bc
 * No fields.
 */
public class ChatReactionsNone <: TLObject {
    public func getConstructorId(): UInt32 { return 0xeafc32bc }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * chatReactionsAll#52928bca flags:# allow_custom:flags.0?true = ChatReactions
 *
 * iOS ref: Api5.swift serialize case .chatReactionsAll => buffer.appendInt32(1385335754)
 * ctor verified (python): 1385335754 => 0x52928bca
 * flags bit 0: allow_custom (optional flag, true if custom emoji reactions allowed)
 */
public class ChatReactionsAll <: TLObject {
    public var allowCustom: Bool = false

    public func getConstructorId(): UInt32 { return 0x52928bca }

    public func serialize(serializer: TLSerializer) {
        let flags: Int32 = if (this.allowCustom) { 1 } else { 0 }
        serializer.writeInt32(flags)
    }
}

/**
 * chatReactionsSome#661d4037 reactions:Vector<Reaction> = ChatReactions
 *
 * iOS ref: Api5.swift serialize case .chatReactionsSome:
 *   buffer.appendInt32(1713193015)  => ctor 0x661d4037
 *   buffer.appendInt32(481674261)   => vector ctor 0x1cb5c415 (TLConstructors.VECTOR)
 *   buffer.appendInt32(count)
 *   for item in reactions { item.serialize(buffer, true) }  => each Reaction boxed
 *
 * ctor verified (python): 1713193015 => 0x661d4037
 * vector ctor 481674261 => 0x1cb5c415 = TLConstructors.VECTOR (confirmed)
 */
public class ChatReactionsSome <: TLObject {
    public var reactions: ArrayList<TLObject> = ArrayList<TLObject>()

    public func getConstructorId(): UInt32 { return 0x661d4037 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.reactions.size))
        for (r in this.reactions) {
            serializer.writeRawBytes(r.toBytes())
        }
    }
}

// ==================== P2-147: messages.setChatAvailableReactions ====================

/**
 * messages.setChatAvailableReactions#864b2581 flags:# peer:InputPeer
 *   available_reactions:ChatReactions reactions_limit:flags.0?int
 *   paid_enabled:flags.1?Bool = Updates
 *
 * iOS ref: Api42.swift L9800 buffer.appendInt32(-2041895551)
 * ctor verified (python): -2041895551 & 0xFFFFFFFF = 0x864b2581
 *
 * Wire layout (iOS serialization order):
 *   flags (int32, unboxed)
 *   peer (boxed InputPeer variant)
 *   available_reactions (boxed ChatReactions variant)
 *   reactions_limit (int32, unboxed) — present if flags.0 set
 *   paid_enabled (boxed Bool)        — present if flags.1 set
 *
 * flags bits:
 *   bit 0 (0x01): reactions_limit present
 *   bit 1 (0x02): paid_enabled present
 */
public class MessagesSetChatAvailableReactions <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var availableReactions: TLObject = ChatReactionsNone()
    public var reactionsLimit: Option<Int32> = None
    public var paidEnabled: Option<Bool> = None

    public func getConstructorId(): UInt32 { return 0x864b2581 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        match (this.reactionsLimit) {
            case Some(_) => flags = flags | 1
            case None => ()
        }
        match (this.paidEnabled) {
            case Some(_) => flags = flags | 2
            case None => ()
        }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeRawBytes(this.availableReactions.toBytes())
        match (this.reactionsLimit) {
            case Some(limit) => serializer.writeInt32(limit)
            case None => ()
        }
        match (this.paidEnabled) {
            case Some(enabled) => serializer.writeBool(enabled)
            case None => ()
        }
    }
}

// ==================== P2-149: 讨论组 / pre-history / 群迁移 ====================

/**
 * channels.setDiscussionGroup#40582bb2 broadcast:InputChannel group:InputChannel = Bool
 *
 * 绑定/解绑频道的关联讨论组。
 * 解绑时 group 传 inputChannelEmpty#ee8c1e86。
 *
 * iOS ref: Api42.swift L4032 buffer.appendInt32(1079520178)
 * ctor verified (python): 1079520178 & 0xFFFFFFFF = 0x40582bb2
 * TL schema cross-check: channels.setDiscussionGroup#40582bb2 ✓
 *
 * 响应: Bool (boolTrue#997275b5 / boolFalse#bc799737)
 */
public class ChannelsSetDiscussionGroup <: TLObject {
    public var broadcast: TLObject = InputChannelEmpty()
    public var group: TLObject = InputChannelEmpty()

    public func getConstructorId(): UInt32 { return 0x40582bb2 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.broadcast.toBytes())
        serializer.writeRawBytes(this.group.toBytes())
    }
}

/**
 * channels.togglePreHistoryHidden#eabbb94c channel:InputChannel enabled:Bool = Updates
 *
 * 切换频道/超级群的历史消息对新成员的可见性。
 * enabled=true  → 隐藏历史（新成员看不到以前的消息）
 * enabled=false → 显示历史（historyAvailableForNewMembers=true 时传 boolFalse）
 *
 * iOS ref: Api42.swift L4197 buffer.appendInt32(-356796084)
 * ctor verified (python): -356796084 & 0xFFFFFFFF = 0xeabbb94c
 * TL schema cross-check: channels.togglePreHistoryHidden#eabbb94c ✓
 *
 * enabled 参数为 boxed Bool，使用 serializer.writeBool() 写入
 * 响应: Updates (四变体: 0x74ae4240/0x725b04c3/0x78d4dec1/0xe317af7e)
 */
public class ChannelsTogglePreHistoryHidden <: TLObject {
    public var channel: TLObject = InputChannelEmpty()
    public var enabled: Bool = false

    public func getConstructorId(): UInt32 { return 0xeabbb94c }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeBool(this.enabled)
    }
}

/**
 * messages.migrateChat#a2875319 chat_id:long = Updates
 *
 * 将基础群组（chat）升级迁移为超级群（supergroup/megagroup）。
 * chat_id 为 long（unboxed），不是 InputPeer。
 *
 * iOS ref: Api42.swift L8369 buffer.appendInt32(-1568189671)
 * ctor verified (python): -1568189671 & 0xFFFFFFFF = 0xa2875319
 * TL schema cross-check: messages.migrateChat#a2875319 ✓
 *
 * 响应: Updates (四变体: 0x74ae4240/0x725b04c3/0x78d4dec1/0xe317af7e)
 */
public class MessagesMigrateChat <: TLObject {
    public var chatId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xa2875319 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.chatId)
    }
}

// ==================== P2-155e-opt: payments.canPurchaseStore ====================

/**
 * payments.canPurchaseStore#4fdc5ea7 purpose:InputStorePaymentPurpose = Bool
 *
 * 服务端购买资格门控查询：向 Telegram 服务端确认当前用户是否具备执行指定
 * 店内购买（InputStorePaymentPurpose）的资格。返回 Bool（boolTrue/boolFalse）。
 *
 * iOS ref: Api42.swift:10568
 *   buffer.appendInt32(1339842215)  -> signed 1339842215 -> UInt32 0x4fdc5ea7 ✓
 *   purpose.serialize(buffer, true) -> boxed InputStorePaymentPurpose
 *
 * ctor verified (python):
 *   1339842215 & 0xFFFFFFFF = 0x4fdc5ea7  (matches gap label 0x4fdc5ea7)
 *
 * Response: Bool
 *   boolTrue#997275b5  (-1720552011 & 0xFFFFFFFF = 0x997275b5) -> true
 *   boolFalse#bc799737 (-1132882121 & 0xFFFFFFFF = 0xbc799737) -> false
 *   Both verified against iOS Api1.swift:1430-1438
 *
 * purpose is serialized boxed (includes constructor id); use writeRawBytes(purpose.toBytes()).
 */
public class PaymentsCanPurchaseStore <: TLObject {
    public var purpose: TLObject = InputStorePaymentPremiumSubscription()

    public func getConstructorId(): UInt32 { return 0x4fdc5ea7 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.purpose.toBytes())
    }
}

// ==================== P2-385: 贴纸发送/收藏 TL 类型 ====================

/**
 * inputDocumentEmpty — 空 document 引用
 *
 * iOS ref: Api9.swift L1130 case inputDocumentEmpty appendInt32(1928391342)
 * ctor verified (python): 1928391342 & 0xFFFFFFFF = 0x72f0eaae
 * TL schema: inputDocumentEmpty#72f0eaae ✓
 *
 * NOTE: InputDocument (non-empty) is already defined at line 4235 of this file.
 */
public class InputDocumentEmpty <: TLObject {
    public func getConstructorId(): UInt32 { return 0x72f0eaae }

    public func serialize(_serializer: TLSerializer) {}
}

/**
 * inputMediaDocument — 用已有 document（贴纸）作为媒体
 *
 * iOS ref: Api11.swift L332-349 serialize case .inputMediaDocument
 *          boxed appendInt32(-1468646731) → 0xa8763ab5
 * ctor verified (python): -1468646731 & 0xFFFFFFFF = 0xa8763ab5
 * TL schema: inputMediaDocument#a8763ab5 flags:# id:InputDocument
 *              videoCover:flags.3?InputPhoto videoTimestamp:flags.4?int
 *              ttlSeconds:flags.0?int query:flags.1?string ✓
 *
 * iOS 字段顺序 (Api11.swift L336-349):
 *   flags(int32) id(boxed InputDocument) [videoCover:flags.3] [videoTimestamp:flags.4]
 *   [ttlSeconds:flags.0] [query:flags.1]
 *
 * 贴纸场景: flags=0, 只填 id(InputDocument)，其余可选字段全不写。
 */
public class InputMediaDocument <: TLObject {
    public var id: TLObject = InputDocumentEmpty()
    public var ttlSeconds: Int32 = 0
    public var query: String = ""
    public var hasTtl: Bool = false
    public var hasQuery: Bool = false

    public func getConstructorId(): UInt32 { return 0xa8763ab5 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasTtl) { flags = flags | 1 }
        if (this.hasQuery) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.id.toBytes())
        if (this.hasTtl) { serializer.writeInt32(this.ttlSeconds) }
        if (this.hasQuery) { serializer.writeString(this.query) }
    }
}

/**
 * messages.faveSticker — 收藏/取消收藏贴纸
 *
 * iOS ref: Api42.swift L6462-6475
 *          buffer.appendInt32(-1174420133) → 0xb9ffc55b
 * ctor verified (python): -1174420133 & 0xFFFFFFFF = 0xb9ffc55b
 * TL schema: messages.faveSticker#b9ffc55b id:InputDocument unfave:Bool = Bool ✓
 *
 * iOS 字段顺序 (Api42.swift L6465-6466):
 *   id.serialize(buffer, true)   // boxed InputDocument
 *   unfave.serialize(buffer, true) // boxed Bool
 * 响应: boxed Bool (TLConstructors.BOOL_TRUE / BOOL_FALSE)
 */
public class MessagesFaveSticker <: TLObject {
    public var id: TLObject = InputDocumentEmpty()
    public var unfave: Bool = false

    public func getConstructorId(): UInt32 { return 0xb9ffc55b }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.id.toBytes())
        if (this.unfave) {
            serializer.writeUInt32(TLConstructors.BOOL_TRUE)
        } else {
            serializer.writeUInt32(TLConstructors.BOOL_FALSE)
        }
    }
}

/**
 * messages.saveRecentSticker#392718f8 flags:# id:InputDocument unsave:Bool = Bool
 *
 * iOS 在贴纸入队时同步更新 CloudRecentStickers，并用本接口把顺序同步到云端。
 */
public class MessagesSaveRecentSticker <: TLObject {
    public var id: TLObject = InputDocumentEmpty()
    public var unsave: Bool = false

    public func getConstructorId(): UInt32 { return 0x392718f8 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)
        serializer.writeRawBytes(this.id.toBytes())
        if (this.unsave) {
            serializer.writeUInt32(TLConstructors.BOOL_TRUE)
        } else {
            serializer.writeUInt32(TLConstructors.BOOL_FALSE)
        }
    }
}

// ==================== P2-133: 频道签名开关 / 限制转发保存 ====================

/**
 * channels.toggleSignatures#418d549c flags:# channel:InputChannel = Updates
 *
 * 切换频道消息的署名（签名）和个人资料链接显示。
 * 当前 iOS layer 使用 flags 版本（取代旧版 enabled:Bool 参数）：
 *   bit 0 (flags & 1): signatures_enabled — 是否在频道消息末尾显示发送者署名
 *   bit 1 (flags & 2): profiles_enabled  — 是否在署名中展示发送者个人资料链接
 *
 * iOS ref: Api42.swift L4213 buffer.appendInt32(1099781276)
 * ctor verified (python): 1099781276 & 0xFFFFFFFF = 0x418d549c
 * TL schema cross-check: channels.toggleSignatures#418d549c ✓
 *
 * 序列化顺序: flags(int, unboxed) → channel(InputChannel, boxed)
 * 响应: Updates 四变体 (0x74ae4240/0x725b04c3/0x78d4dec1/0xe317af7e)
 */
public class ChannelsToggleSignatures <: TLObject {
    public var flags: Int32 = 0
    public var channel: TLObject = InputChannelEmpty()

    public func getConstructorId(): UInt32 { return 0x418d549c }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.flags)
        serializer.writeRawBytes(this.channel.toBytes())
    }
}

/**
 * messages.toggleNoForwards#b2081a35 flags:# peer:InputPeer enabled:Bool
 *   requestMsgId:flags.0?int = Updates
 *
 * 切换 chat 或 channel 的"限制转发与保存内容"开关。
 * peer 为 InputPeer（支持 channel/chat/user）；enabled=true 即开启限制。
 * requestMsgId 为可选字段（flags.0?int），普通用途传 flags=0 即可。
 *
 * 注意: iOS 里 channels.toggleNoForwards 不存在；
 *   限制转发功能在 channel 场景下同样使用 messages.toggleNoForwards。
 *
 * iOS ref: Api42.swift L10119 buffer.appendInt32(-1308091851)
 * ctor verified (python): -1308091851 & 0xFFFFFFFF = 0xb2081a35
 * TL schema cross-check: messages.toggleNoForwards#b2081a35 ✓
 *
 * 序列化顺序: flags(int, unboxed) → peer(InputPeer, boxed) → enabled(Bool, boxed)
 *   → requestMsgId:flags.0?int (仅 flags bit 0 置位时出现)
 * 响应: Updates 四变体 (0x74ae4240/0x725b04c3/0x78d4dec1/0xe317af7e)
 */
public class MessagesToggleNoForwards <: TLObject {
    public var flags: Int32 = 0
    public var peer: TLObject = InputPeerEmpty()
    public var enabled: Bool = false

    public func getConstructorId(): UInt32 { return 0xb2081a35 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeBool(this.enabled)
    }
}

// ==================== P2-330: Global Auto-Delete (messages.DefaultHistoryTTL) ====================

/**
 * messages.getDefaultHistoryTTL#658b7188 = DefaultHistoryTTL
 * Response: defaultHistoryTTL#43b46b20 period:int
 * iOS ref: Api42.swift:6790 appendInt32(1703637384) -> 0x658b7188
 * ctor verified: python3 -c "print(hex(1703637384))" -> 0x658b7188
 */
public class MessagesGetDefaultHistoryTTL <: TLObject {
    public func getConstructorId(): UInt32 { return 0x658b7188 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * messages.setDefaultHistoryTTL#9eb51445 period:int = Bool
 * iOS ref: Api42.swift:9862 appendInt32(-1632299963) -> 0x9eb51445
 * ctor verified: python3 -c "print(hex(-1632299963 & 0xFFFFFFFF))" -> 0x9eb51445
 */
public class MessagesSetDefaultHistoryTTL <: TLObject {
    public var period: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x9eb51445 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.period)
    }
}

/**
 * messages.getMessageReadParticipants#31c1c44f peer:InputPeer msg_id:int = Vector<ReadParticipantDate>
 * iOS ref: Api42.swift:7407 buffer.appendInt32(834782287) → hex(834782287) = 0x31c1c44f
 * ctor verified: python3 -c "print(hex(834782287))" → 0x31c1c44f
 * Response: Vector<readParticipantDate#4a4ff172 user_id:long date:int>
 *   readParticipantDate ctor: hex(1246753138) = 0x4a4ff172
 */
public class MessagesGetMessageReadParticipants <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var msgId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x31c1c44f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.msgId)
    }
}

/**
 * messages.getOutboxReadDate#8c4bfe5d peer:InputPeer msg_id:int = OutboxReadDate
 * iOS ref: Api42.swift:7852 buffer.appendInt32(-1941176739) → 0x8c4bfe5d
 * Response: outboxReadDate#3bb842ac date:int (Api0.swift:776 dict[1001931436])
 */
public class MessagesGetOutboxReadDate <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var msgId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x8c4bfe5d }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.msgId)
    }
}

/**
 * messages.getSavedDialogs#1e91fc99 flags:# exclude_pinned:flags.0?true parent_peer:flags.1?InputPeer
 *   offset_date:int offset_id:int offset_peer:InputPeer limit:int hash:long = messages.SavedDialogs
 * iOS ref: Api42.swift:8148 buffer.appendInt32(512883865) → 0x1e91fc99
 */
public class MessagesGetSavedDialogs <: TLObject {
    public var excludePinned: Bool = false
    public var offsetDate: Int32 = 0
    public var offsetId: Int32 = 0
    public var offsetPeer: TLObject = InputPeerEmpty()
    public var limit: Int32 = 100
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x1e91fc99 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.excludePinned) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeInt32(this.offsetDate)
        serializer.writeInt32(this.offsetId)
        serializer.writeRawBytes(this.offsetPeer.toBytes())
        serializer.writeInt32(this.limit)
        serializer.writeInt64(this.hash)
    }
}

/**
 * messages.getSavedHistory#998ab009 flags:# parent_peer:flags.0?InputPeer peer:InputPeer offset_id:int
 *   offset_date:int add_offset:int limit:int max_id:int min_id:int hash:long = messages.Messages
 * iOS ref: Api42.swift:8209 buffer.appendInt32(-1718964215) → 0x998ab009
 */
public class MessagesGetSavedHistory <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var offsetId: Int32 = 0
    public var offsetDate: Int32 = 0
    public var addOffset: Int32 = 0
    public var limit: Int32 = 50
    public var maxId: Int32 = 0
    public var minId: Int32 = 0
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x998ab009 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.offsetId)
        serializer.writeInt32(this.offsetDate)
        serializer.writeInt32(this.addOffset)
        serializer.writeInt32(this.limit)
        serializer.writeInt32(this.maxId)
        serializer.writeInt32(this.minId)
        serializer.writeInt64(this.hash)
    }
}

// ==================== P2-119: Context Menu — Copy Link / Report ====================

/**
 * channels.exportMessageLink#e63fadeb flags:# grouped:flags.0?true thread:flags.1?true channel:InputChannel id:int = ExportedMessageLink
 *
 * ctor verified: python3 -c "print(hex(0xe63fadeb))" -> 0xe63fadeb
 * iOS ref: ChatInterfaceStateContextMenus.swift:1765 context.engine.messages.exportMessageLink(...)
 * TL schema: channels.exportMessageLink#e63fadeb flags:# grouped:flags.0?true thread:flags.1?true channel:InputChannel id:int
 *
 * Response: exportedMessageLink#5dab1af4 link:string html:string
 */
public class ChannelsExportMessageLink <: TLObject {
    public var grouped: Bool = false
    public var thread: Bool = false
    public var channel: TLObject = InputChannel()
    public var id: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xe63fadeb }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.grouped) { flags = flags | 1 }
        if (this.thread) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeInt32(this.id)
    }
}

/**
 * messages.report#fc78af9b peer:InputPeer id:Vector<int> option:bytes message:string = ReportResult
 *
 * ctor verified: python3 -c "print(hex(0xfc78af9b))" -> 0xfc78af9b
 * iOS ref: ReportContent.swift:60 account.network.request(Api.functions.messages.report(peer:, id:, option:, message:))
 *
 * P2-119 r1: option bytes MUST come from the server (messageReportOption.option field returned in
 * reportResultChooseOption response). Sending [] (empty) triggers the server to return option list.
 * Locally constructing inputReportReason* bytes is rejected by the server.
 *
 * Response parsed by ReportResultResponse.deserialize() in TLResponses.cj:
 *   reportResultChooseOption#f0e4e0b6 — server wants user to pick from options list
 *   reportResultAddComment#6f09ac31  — server wants optional comment
 *   reportResultReported#8db33c4b    — report submitted successfully
 */
public class MessagesReport <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var ids: ArrayList<Int32> = ArrayList<Int32>()
    public var option: Array<Byte> = Array<Byte>(0, repeat: 0)   // serialized inputReportReason* ctor
    public var message: String = ""

    public func getConstructorId(): UInt32 { return 0xfc78af9b }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
        // Vector<int>
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.ids.size))
        for (id in this.ids) {
            serializer.writeInt32(id)
        }
        serializer.writeBytes(this.option)
        serializer.writeString(this.message)
    }
}

// P2-119 r1: buildReportReasonBytes() removed.
// messages.report option:bytes must be server-provided (from reportResultChooseOption response),
// not locally constructed inputReportReason* ctors. See ReportResultResponse in TLResponses.cj.

// ==================== P2-AUDIT-coverage: confirmed-missing TL methods ====================

/**
 * updates.getChannelDifference#03173d78
 * flags:# force:flags.0?true channel:InputChannel filter:ChannelMessagesFilter pts:int limit:int
 * = updates.ChannelDifference
 *
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',51854712))[0]))"
 *   → 0x3173d78
 * iOS ref: Api42.swift:13793 buffer.appendInt32(51854712)
 *
 * filter variants:
 *   channelMessagesFilterEmpty#94d42ee7 (normal diff, no filter)
 *   channelMessagesFilter#cd77d957 flags:# exclude_new_messages:flags.1?true ranges:Vector<MessageRange>
 * iOS ref: Api0.swift:191-192
 */
public class UpdatesGetChannelDifference <: TLObject {
    public var channelId: Int64 = 0
    public var channelAccessHash: Int64 = 0
    public var pts: Int32 = 0
    public var limit: Int32 = 100

    public func getConstructorId(): UInt32 { return 0x03173d78 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags (no force)
        // channel: InputChannel#f35aec28 channel_id:long access_hash:long
        serializer.writeUInt32(0xf35aec28)
        serializer.writeInt64(this.channelId)
        serializer.writeInt64(this.channelAccessHash)
        // filter: channelMessagesFilterEmpty#94d42ee7
        serializer.writeUInt32(0x94d42ee7)
        serializer.writeInt32(this.pts)
        serializer.writeInt32(this.limit)
    }
}

/**
 * messages.getMessages#63c66506 id:Vector<InputMessage> = messages.Messages
 *
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',1673946374))[0]))"
 *   → 0x63c66506
 * iOS ref: Api42.swift:7423 buffer.appendInt32(1673946374)
 *
 * InputMessage.inputMessageID#a676a322 id:int
 * iOS ref: Api0.swift:439 dict[-1502174430] → 0xa676a322
 *
 * Fetch arbitrary messages by ID for regular chats/users.
 * For channel messages, use ChannelsGetMessages instead.
 */
public class MessagesGetMessages <: TLObject {
    public var ids: ArrayList<Int32> = ArrayList<Int32>()

    public func getConstructorId(): UInt32 { return 0x63c66506 }

    public func serialize(serializer: TLSerializer) {
        // Vector<InputMessage>: each item is inputMessageID#a676a322 id:int
        serializer.writeUInt32(0x1cb5c415)  // vector ctor
        serializer.writeInt32(Int32(this.ids.size))
        for (id in this.ids) {
            serializer.writeUInt32(0xa676a322)  // inputMessageID
            serializer.writeInt32(id)
        }
    }
}

/**
 * channels.getMessages#ad8c9a23 channel:InputChannel id:Vector<InputMessage> = messages.Messages
 *
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',-1383294429))[0]))"
 *   → 0xad8c9a23
 * iOS ref: Api42.swift:3756 buffer.appendInt32(-1383294429)
 *
 * Fetch arbitrary messages by ID within a channel (use channelId + accessHash).
 */
public class ChannelsGetMessages <: TLObject {
    public var channelId: Int64 = 0
    public var channelAccessHash: Int64 = 0
    public var ids: ArrayList<Int32> = ArrayList<Int32>()

    public func getConstructorId(): UInt32 { return 0xad8c9a23 }

    public func serialize(serializer: TLSerializer) {
        // channel: InputChannel#f35aec28
        serializer.writeUInt32(0xf35aec28)
        serializer.writeInt64(this.channelId)
        serializer.writeInt64(this.channelAccessHash)
        // Vector<InputMessage>
        serializer.writeUInt32(0x1cb5c415)  // vector ctor
        serializer.writeInt32(Int32(this.ids.size))
        for (id in this.ids) {
            serializer.writeUInt32(0xa676a322)  // inputMessageID
            serializer.writeInt32(id)
        }
    }
}

/**
 * messages.readReactions#9ec44f93
 * flags:# peer:InputPeer top_msg_id:flags.0?int saved_peer_id:flags.1?InputPeer
 * = messages.AffectedHistory
 *
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',-1631301741))[0]))"
 *   → 0x9ec44f93
 * iOS ref: Api42.swift:8549 buffer.appendInt32(-1631301741)
 *
 * Mark all reactions in a peer as read (clears unread reactions badge).
 * Normal usage: flags=0, top_msg_id absent, saved_peer_id absent.
 */
public class MessagesReadReactions <: TLObject {
    public var peerType: String = "user"
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x9ec44f93 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags (no top_msg_id, no saved_peer_id)
        // peer: InputPeer
        if (this.peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)  // inputPeerChannel
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (this.peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)  // inputPeerChat
            // Current TL: inputPeerChat#35a95cb9 chat_id:long. The old
            // 0x179be863/int form overflows for modern 64-bit basic-chat ids
            // (for example 5279129921) before readReactions reaches Telegram.
            serializer.writeInt64(this.peerId)
        } else {
            serializer.writeUInt32(0xdde8a54c)  // inputPeerUser
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }
    }
}

/**
 * messages.readDiscussion#f731a9f4 peer:InputPeer msg_id:int read_max_id:int = Bool
 *
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',-147740172))[0]))"
 *   → 0xf731a9f4
 * iOS ref: Api42.swift:8424 buffer.appendInt32(-147740172)
 *
 * Mark discussion messages as read up to read_max_id in the thread rooted at msg_id.
 */
public class MessagesReadDiscussion <: TLObject {
    public var peerType: String = "channel"
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var msgId: Int32 = 0
    public var readMaxId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xf731a9f4 }

    public func serialize(serializer: TLSerializer) {
        // peer: InputPeer
        if (this.peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (this.peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)
            serializer.writeInt64(this.peerId)
        } else {
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }
        serializer.writeInt32(this.msgId)
        serializer.writeInt32(this.readMaxId)
    }
}

/**
 * messages.getPeerDialogs#e470bcfd peers:Vector<InputDialogPeer> = messages.PeerDialogs
 *
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',-462373635))[0]))"
 *   → 0xe470bcfd
 * iOS ref: Api42.swift:7561 buffer.appendInt32(-462373635)
 *
 * InputDialogPeer.inputDialogPeer#e56dbf05 peer:InputPeer
 * Used to batch-fetch dialog metadata (read-max-id, unread counts, etc.) by peer list.
 */
public class MessagesGetPeerDialogs <: TLObject {
    public var peerType: String = "user"
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xe470bcfd }

    public func serialize(serializer: TLSerializer) {
        // Vector<InputDialogPeer> — single entry
        serializer.writeUInt32(0x1cb5c415)  // vector ctor
        serializer.writeInt32(1)
        // InputDialogPeer.inputDialogPeer#fcaafeb7 peer:InputPeer
        serializer.writeUInt32(0xfcaafeb7)
        if (this.peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (this.peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)
            serializer.writeInt64(this.peerId)
        } else {
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }
    }
}

/**
 * messages.editChatPhoto#35ddd674 chat_id:long photo:InputChatPhoto = Updates
 *
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',903730804))[0]))"
 *   → 0x35ddd674
 * iOS ref: Api42.swift:6231 buffer.appendInt32(903730804)
 *
 * photo:
 *   inputChatPhotoEmpty#1ca48f57 — remove chat photo
 *   inputChatUploadedPhoto (see existing InputChatUploadedPhoto in this file)
 */
public class MessagesEditChatPhoto <: TLObject {
    public var chatId: Int64 = 0
    public var removePhoto: Bool = true  // if true, send inputChatPhotoEmpty
    public var photo: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0x35ddd674 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.chatId)
        if (this.removePhoto) {
            // inputChatPhotoEmpty#1ca48f57
            serializer.writeUInt32(0x1ca48f57)
        } else {
            serializer.writeRawBytes(this.photo.toBytes())
        }
    }
}

/**
 * messages.editChatAdmin#a85bd1c2 chat_id:long user_id:InputUser is_admin:Bool = Bool
 *
 * ctor verified: python3 -c "print(hex(0xa85bd1c2))" → 0xa85bd1c2
 * iOS ref: Api42.swift:6164 buffer.appendInt32(-1470377534)
 *   python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',-1470377534))[0]))" → 0xa85bd1c2
 *
 * Legacy method for classic group chats (not supergroups/channels).
 * Supergroups use ChannelsEditAdmin.
 */
public class MessagesEditChatAdmin <: TLObject {
    public var chatId: Int64 = 0
    public var userId: Int64 = 0
    public var userAccessHash: Int64 = 0
    public var isAdmin: Bool = true

    public func getConstructorId(): UInt32 { return 0xa85bd1c2 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.chatId)
        // inputUser#f21158c6 user_id:long access_hash:long
        serializer.writeUInt32(0xf21158c6)
        serializer.writeInt64(this.userId)
        serializer.writeInt64(this.userAccessHash)
        // Bool: boolTrue#997275b5, boolFalse#bc799737
        if (this.isAdmin) {
            serializer.writeUInt32(0x997275b5)
        } else {
            serializer.writeUInt32(0xbc799737)
        }
    }
}

/**
 * messages.getWebPagePreview#570d6f6f flags:# message:string entities:flags.3?Vector<MessageEntity>
 * = messages.WebPagePreview
 *
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',1460498287))[0]))"
 *   → 0x570d6f6f
 * iOS ref: Api42.swift:8226 buffer.appendInt32(1460498287)
 *
 * Fetch link preview for a URL found in the message text.
 * Simple usage: flags=0, entities absent.
 */
public class MessagesGetWebPagePreview <: TLObject {
    public var message: String = ""

    public func getConstructorId(): UInt32 { return 0x570d6f6f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags (no entities)
        serializer.writeString(this.message)
    }
}

/**
 * messages.sendScreenshotNotification#a1405817
 * peer:InputPeer reply_to:InputReplyTo random_id:long = Updates
 *
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',-1589618665))[0]))"
 *   → 0xa1405817
 * iOS ref: Api42.swift:9642 buffer.appendInt32(-1589618665)
 *
 */
public class MessagesSendScreenshotNotification <: TLObject {
    public var peerType: String = "user"
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var replyToMsgId: Int32 = 0
    public var randomId: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xa1405817 }

    public func serialize(serializer: TLSerializer) {
        // peer: InputPeer
        if (this.peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (this.peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)
            serializer.writeInt64(this.peerId)
        } else {
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }
        // reply_to: inputReplyToMessage#3bd4b7c2 flags:# msg_id:int
        serializer.writeUInt32(0x3bd4b7c2)
        serializer.writeInt32(0)  // flags
        serializer.writeInt32(this.replyToMsgId)
        serializer.writeInt64(this.randomId)
    }
}

/**
 * messages.getBotCallbackAnswer#9342ca07
 * flags:# game:flags.1?true peer:InputPeer msg_id:int data:flags.0?bytes password:flags.2?InputCheckPasswordSRP
 * = messages.BotCallbackAnswer
 *
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',-1824339449))[0]))"
 *   → 0x9342ca07
 * iOS ref: Api42.swift:6687 buffer.appendInt32(-1824339449)
 *
 * Normal inline keyboard callback: flags=0, no data, no password, no game.
 * Callback with data: flags|=1, data=button.data
 */
public class MessagesGetBotCallbackAnswer <: TLObject {
    public var peerType: String = "user"
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var msgId: Int32 = 0
    public var callbackData: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var hasData: Bool = false

    public func getConstructorId(): UInt32 { return 0x9342ca07 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasData) { flags = flags | 1 }
        serializer.writeInt32(flags)
        // peer
        if (this.peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (this.peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)
            serializer.writeInt64(this.peerId)
        } else {
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }
        serializer.writeInt32(this.msgId)
        if (this.hasData) {
            serializer.writeBytes(this.callbackData)
        }
    }
}

/**
 * channels.joinChannel#7f6a1e22 channel:InputChannel = messages.ChatInviteJoinResult
 *
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',2137660962))[0]))"
 *   → 0x7f6a1e22
 * iOS ref: Api42.swift:3847 buffer.appendInt32(2137660962)
 *
 * Join a public channel by InputChannel.
 * Returns Updates containing the joined channel info.
 */
public class ChannelsJoinChannel <: TLObject {
    public var channelId: Int64 = 0
    public var channelAccessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x7f6a1e22 }

    public func serialize(serializer: TLSerializer) {
        // channel: InputChannel#f35aec28
        serializer.writeUInt32(0xf35aec28)
        serializer.writeInt64(this.channelId)
        serializer.writeInt64(this.channelAccessHash)
    }
}

/**
 * account.updateStatus#6628562c offline:Bool = Bool
 *
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',1713919532))[0]))"
 *   → 0x6628562c
 * iOS ref: Api42.swift:1937 buffer.appendInt32(1713919532)
 *
 * offline=true  → report user as offline
 * offline=false → report user as online
 */
public class AccountUpdateStatus <: TLObject {
    public var offline: Bool = false

    public func getConstructorId(): UInt32 { return 0x6628562c }

    public func serialize(serializer: TLSerializer) {
        // Bool: boolTrue#997275b5, boolFalse#bc799737
        if (this.offline) {
            serializer.writeUInt32(0x997275b5)
        } else {
            serializer.writeUInt32(0xbc799737)
        }
    }
}

// ==================== P2-174: chatlists.* Folder Invite Links ====================

/**
 * inputChatlistDialogFilter#f3e0da33 filter_id:int = InputChatlist
 *
 * ctor verified:
 *   python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',-203367885))[0]))"
 *   → 0xf3e0da33
 * iOS ref: Api9.swift:742 buffer.appendInt32(-203367885)
 *
 * Used as chatlist: InputChatlist parameter in all chatlists.* methods.
 * filterId corresponds to the DialogFilter.id stored server-side.
 */
public class InputChatlistDialogFilter <: TLObject {
    public var filterId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xf3e0da33 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.filterId)
    }
}

/**
 * chatlists.exportChatlistInvite chatlist:InputChatlist title:string peers:Vector<InputPeer>
 *   = chatlists.ExportedChatlistInvite
 *
 * ctor verified:
 *   python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',-2072885362))[0]))"
 *   → 0x8472478e
 * iOS ref: Api42.swift:4407 buffer.appendInt32(-2072885362)
 *
 * Creates a folder invite link for the given chatlist containing the specified peers.
 * Response: chatlists.ExportedChatlistInvite#10e6e3a6 (filter + invite)
 *   where invite is ExportedChatlistInvite#0c5181ac (flags title url peers)
 */
public class ChatlistsExportChatlistInvite <: TLObject {
    public var filterId: Int32 = 0
    public var title: String = ""
    public var peers: ArrayList<TLObject> = ArrayList<TLObject>()

    public func getConstructorId(): UInt32 { return 0x8472478e }

    public func serialize(serializer: TLSerializer) {
        // chatlist: InputChatlist = inputChatlistDialogFilter#f3e0da33
        serializer.writeUInt32(0xf3e0da33)
        serializer.writeInt32(this.filterId)
        // title: string
        serializer.writeString(this.title)
        // peers: Vector<InputPeer> (481674261 = VECTOR constructor 0x1cb5c415)
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(Int32(this.peers.size))
        for (p in this.peers) {
            serializer.writeUInt32(p.getConstructorId())
            p.serialize(serializer)
        }
    }
}

/**
 * chatlists.getExportedInvites chatlist:InputChatlist = chatlists.ExportedInvites
 *
 * ctor verified:
 *   python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',-838608253))[0]))"
 *   → 0xce03da83
 * iOS ref: Api42.swift:4443 buffer.appendInt32(-838608253)
 *
 * Returns all exported invite links for the given chatlist folder.
 * Response: chatlists.ExportedInvites#10ab6dc7 (invites chats users)
 *   where each invite is ExportedChatlistInvite#0c5181ac (flags title url peers)
 */
public class ChatlistsGetExportedInvites <: TLObject {
    public var filterId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xce03da83 }

    public func serialize(serializer: TLSerializer) {
        // chatlist: InputChatlist = inputChatlistDialogFilter#f3e0da33
        serializer.writeUInt32(0xf3e0da33)
        serializer.writeInt32(this.filterId)
    }
}

/**
 * chatlists.editExportedInvite flags:# chatlist:InputChatlist slug:string
 *   title:flags.1?string peers:flags.2?Vector<InputPeer> = ExportedChatlistInvite
 *
 * ctor verified:
 *   python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',1698543165))[0]))"
 *   → 0x653db63d
 * iOS ref: Api42.swift:4380 buffer.appendInt32(1698543165)
 *   flags bit 0 = revoked, bit 1 = has title update, bit 2 = has peers update
 *
 * Edits an existing folder invite link. slug is extracted from url after "https://t.me/addlist/".
 * Response: ExportedChatlistInvite#0c5181ac (flags title url peers)
 */
public class ChatlistsEditExportedInvite <: TLObject {
    public var filterId: Int32 = 0
    public var slug: String = ""
    public var title: String = ""
    public var hasTitle: Bool = false
    public var peers: ArrayList<TLObject> = ArrayList<TLObject>()
    public var hasPeers: Bool = false
    public var revoked: Bool = false

    public func getConstructorId(): UInt32 { return 0x653db63d }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.revoked) { flags = flags | 1 }
        if (this.hasTitle) { flags = flags | 2 }
        if (this.hasPeers) { flags = flags | 4 }
        serializer.writeInt32(flags)
        // chatlist: InputChatlist = inputChatlistDialogFilter#f3e0da33
        serializer.writeUInt32(0xf3e0da33)
        serializer.writeInt32(this.filterId)
        // slug: string
        serializer.writeString(this.slug)
        // title: flags.1?string
        if (this.hasTitle) {
            serializer.writeString(this.title)
        }
        // peers: flags.2?Vector<InputPeer>
        if (this.hasPeers) {
            serializer.writeUInt32(0x1cb5c415)
            serializer.writeInt32(Int32(this.peers.size))
            for (p in this.peers) {
                serializer.writeUInt32(p.getConstructorId())
                p.serialize(serializer)
            }
        }
    }
}

/**
 * chatlists.deleteExportedInvite chatlist:InputChatlist slug:string = Bool
 *
 * ctor verified:
 *   python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',1906072670))[0]))"
 *   → 0x719c5c5e
 * iOS ref: Api42.swift:4364 buffer.appendInt32(1906072670)
 *
 * Deletes a folder invite link. slug extracted from url after "https://t.me/addlist/".
 * Response: Bool (boolTrue#997275b5 on success)
 */
public class ChatlistsDeleteExportedInvite <: TLObject {
    public var filterId: Int32 = 0
    public var slug: String = ""

    public func getConstructorId(): UInt32 { return 0x719c5c5e }

    public func serialize(serializer: TLSerializer) {
        // chatlist: InputChatlist = inputChatlistDialogFilter#f3e0da33
        serializer.writeUInt32(0xf3e0da33)
        serializer.writeInt32(this.filterId)
        // slug: string
        serializer.writeString(this.slug)
    }
}

// ==================== P2-096: 日历日期标记 — messages.getSearchResultsCalendar ====================

/**
 * messages.getSearchResultsCalendar — 获取对话日历聚合（按天统计消息数 / 媒体数）
 *
 * tl_codegen verified: iOS Api42.swift L7998 buffer.appendInt32(1789130429)
 * python3 -c "print(hex(1789130429))" → 0x6aa3f6bd
 *
 * flags:#
 * peer:InputPeer
 * filter:MessagesFilter  (inputMessagesFilterEmpty=0x57e2f66c 取全部; 或指定媒体类型)
 * offset_id:int          (起始消息 ID，0 = 从最新开始)
 * offset_date:int        (起始日期，0 = 从最新开始)
 *
 * 响应: messages.searchResultsCalendar#147ee23c
 * iOS dict[343859772] → parse_searchResultsCalendar (Api0.swift:1557)
 * python3 -c "print(hex(343859772))" → 0x147ee23c
 *
 * 响应字段:
 *   flags:# count:int min_date:int min_msg_id:int
 *   offset_id_offset:flags.0?int
 *   periods:Vector<SearchResultsCalendarPeriod>
 *   messages:Vector<Message>  chats:Vector<Chat>  users:Vector<User>
 *
 * SearchResultsCalendarPeriod#c9b0539f:
 *   date:int min_msg_id:int max_msg_id:int count:int
 * python3 -c "print(hex(-911191137 & 0xFFFFFFFF))" → 0xc9b0539f
 */
public class MessagesGetSearchResultsCalendar <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var filter: TLObject = InputMessagesFilterEmpty()
    public var offsetId: Int32 = 0
    public var offsetDate: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x6aa3f6bd }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags (no savedPeerId)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeRawBytes(this.filter.toBytes())
        serializer.writeInt32(this.offsetId)
        serializer.writeInt32(this.offsetDate)
    }
}

/**
 * SearchResultsCalendarPeriod — 日历聚合周期（每天/每周统计）
 * Constructor: 0xc9b0539f
 * date:int min_msg_id:int max_msg_id:int count:int
 */
public class SearchResultsCalendarPeriod {
    public var date: Int32 = 0        // 该周期起始日期（Unix 时间戳，秒）
    public var minMsgId: Int32 = 0    // 该周期内最小消息 ID
    public var maxMsgId: Int32 = 0    // 该周期内最大消息 ID
    public var count: Int32 = 0       // 该周期内消息数量
}

// ==================== P2-368: TON 广告收入 — payments.getStarsRevenueAdsAccountUrl ====================

/**
 * payments.getStarsRevenueAdsAccountUrl peer:InputPeer = payments.StarsRevenueAdsAccountUrl
 * tl_codegen verified: iOS Api42.swift L11160 buffer.appendInt32(-774377531)
 * python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',-774377531))[0]))"
 * → 0xd1d7efc5
 * 响应: payments.starsRevenueAdsAccountUrl#394e7f21 url:string
 * iOS dict[961445665] = parse_starsRevenueAdsAccountUrl (Api0.swift:1603)
 * python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',961445665))[0]))"
 * → 0x394e7f21
 *
 * 获取频道 TON 广告账户管理 URL（Buy Ads / Monetization 入口）。
 * 用于 ChannelRevenueStatsPage "Buy Ads" 按钮 → 打开 WebView。
 */
public class PaymentsGetStarsRevenueAdsAccountUrl <: TLObject {
    public var peer: TLObject = InputPeerSelf()

    public func getConstructorId(): UInt32 { return 0xd1d7efc5 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

// ==================== P2-301/302: premium.applyBoost ====================

/**
 * premium.applyBoost#6b7da746 flags:# slots:flags.0?Vector<int> peer:InputPeer = premium.MyBoosts
 *
 * tl_codegen verified: 1803396934 → 0x6b7da746
 * iOS ref: Api.functions.premium.applyBoost (Api42.swift:12548)
 *   buffer.appendInt32(1803396934) → 0x6b7da746
 * python3: struct.unpack('<I',struct.pack('<i',1803396934))[0] == 0x6b7da746 ✓
 *
 * slots: 当前已有 boosts 中要被替换的 slot 下标（flags.0 控制是否传；为空 → 新增 boost）
 * peer:  要 boost 的频道 InputPeer（boxed）
 *
 * 响应: premium.myBoosts#9ae5ffe4 boosts:Vector<MyBoost>
 *   myBoost#c448415c flags:# slot:int peer:flags.0?Peer date:flags.1?int expires:flags.1?int
 *     cooldown_until_date:flags.2?int
 */
public class PremiumApplyBoost <: TLObject {
    public var slots: ArrayList<Int32> = ArrayList<Int32>()
    public var peer: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0x6b7da746 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.slots.size > 0) { flags = flags | 1 }
        serializer.writeInt32(flags)
        if (this.slots.size > 0) {
            serializer.writeUInt32(TLConstructors.VECTOR)
            serializer.writeInt32(Int32(this.slots.size))
            for (slot in this.slots) {
                serializer.writeInt32(slot)
            }
        }
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

// ==================== P2-090: channels.convertToGigagroup ====================

/**
 * channels.convertToGigagroup#b290c69 channel:InputChannel = Updates
 *
 * 将频道/超级群升级为 Gigagroup（大型广播群）。
 * 导入时若目标是普通群（chat），先 messages.migrateChat 升级到 supergroup，
 * 再可选 channels.convertToGigagroup 升级为 Gigagroup（iOS ChatImport 源码路径）。
 *
 * iOS ref: Api42.swift L3374 buffer.appendInt32(187239529)
 * python3 -c "print(hex(187239529 & 0xFFFFFFFF))" → 0xb290c69 ✓
 *
 * channel: InputChannel boxed (ctor 0xf35aec28 channel_id:long access_hash:long)
 * 响应: Updates（四变体同 migrateChat）
 */
public class ChannelsConvertToGigagroup <: TLObject {
    public var channelId: Int64 = 0
    public var channelAccessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x0b290c69 }

    public func serialize(serializer: TLSerializer) {
        // boxed InputChannel: ctor 0xf35aec28 + channelId:long + accessHash:long
        serializer.writeUInt32(0xf35aec28)
        serializer.writeInt64(this.channelId)
        serializer.writeInt64(this.channelAccessHash)
    }
}

// ==================== P2-061+063+064: Group Call Extended Methods ====================

/**
 * phone.toggleGroupCallRecord#f128c708
 * TL: phone.toggleGroupCallRecord#f128c708 flags:# start:flags.0?true
 *     video:flags.2?true call:InputGroupCall title:flags.1?string videoPortrait:flags.2?true
 * iOS Api42.swift L12371 buffer.appendInt32(-248985848) => 0xf128c708
 * flags: bit0=start(1=开始录制,0=停止), bit1=title, bit2=videoPortrait
 * P2-063: 语音房录制开关
 */
public class PhoneToggleGroupCallRecord <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    public var start: Bool = false
    public var title: String = ""
    public var hasTitle: Bool = false

    public func getConstructorId(): UInt32 { return 0xf128c708 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (start) { flags = flags | 1 }
        if (hasTitle && title.size > 0) { flags = flags | 2 }
        serializer.writeInt32(flags)
        // call: InputGroupCall#d8aa840f
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(callId)
        serializer.writeInt64(callAccessHash)
        if (hasTitle && title.size > 0) {
            serializer.writeString(title)
        }
    }
}

/**
 * phone.editGroupCallParticipant#a5273abf
 * TL: phone.editGroupCallParticipant#a5273abf flags:# call:InputGroupCall participant:InputPeer
 *     muted:flags.0?Bool volume:flags.1?int raiseHand:flags.2?Bool
 *     videoStopped:flags.3?Bool videoPaused:flags.4?Bool presentationPaused:flags.5?Bool
 * iOS Api42.swift L11853 buffer.appendInt32(-1524155713) => 0xa5273abf
 * P2-061: admin 静音/踢/音量控制
 */
public class PhoneEditGroupCallParticipant <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0
    // participant: InputPeer (userId or channelId)
    public var participantUserId: Int64 = 0
    public var participantAccessHash: Int64 = 0
    // flags
    public var muted: Bool = false
    public var hasMuted: Bool = false
    public var volume: Int32 = 0
    public var hasVolume: Bool = false
    public var raiseHand: Bool = false
    public var hasRaiseHand: Bool = false
    // 自己静音/举手：participant 用 inputPeerSelf（iOS updateMuteState peerId == accountPeerId）
    public var participantIsSelf: Bool = false
    public var participantPeerBytes: Array<Byte> = Array<Byte>()
    public var videoStopped: Bool = false
    public var hasVideoStopped: Bool = false
    public var videoPaused: Bool = false
    public var hasVideoPaused: Bool = false

    public func getConstructorId(): UInt32 { return 0xa5273abf }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (hasMuted) { flags = flags | 1 }
        if (hasVolume) { flags = flags | 2 }
        if (hasRaiseHand) { flags = flags | 4 }
        if (hasVideoStopped) { flags = flags | 8 }
        if (hasVideoPaused) { flags = flags | 16 }
        serializer.writeInt32(flags)
        // call: InputGroupCall#d8aa840f
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(callId)
        serializer.writeInt64(callAccessHash)
        if (participantPeerBytes.size > 0) {
            // 以频道/群身份入会（Display As）时，"自己"就是那个 peer
            serializer.writeRawBytes(participantPeerBytes)
        } else if (participantIsSelf) {
            // inputPeerSelf#7da07ec9
            serializer.writeUInt32(0x7da07ec9)
        } else {
            // participant: InputPeer → inputPeerUser#dde8a54c（此前误写成 inputUser#f21158c6）
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(participantUserId)
            serializer.writeInt64(participantAccessHash)
        }
        if (hasMuted) {
            // Bool boxed: boolTrue#997275b5 / boolFalse#bc799737
            if (muted) { serializer.writeUInt32(0x997275b5) } else { serializer.writeUInt32(0xbc799737) }
        }
        if (hasVolume) {
            serializer.writeInt32(volume)
        }
        if (hasRaiseHand) {
            if (raiseHand) { serializer.writeUInt32(0x997275b5) } else { serializer.writeUInt32(0xbc799737) }
        }
        if (hasVideoStopped) {
            if (videoStopped) { serializer.writeUInt32(0x997275b5) } else { serializer.writeUInt32(0xbc799737) }
        }
        if (hasVideoPaused) {
            if (videoPaused) { serializer.writeUInt32(0x997275b5) } else { serializer.writeUInt32(0xbc799737) }
        }
    }
}

/**
 * phone.leaveGroupCallPresentation#1c50d144
 * TL: phone.leaveGroupCallPresentation#1c50d144 call:InputGroupCall = Updates
 * iOS Api42.swift L12153 buffer.appendInt32(475058500) => 0x1c50d144
 * P2-064: 停止屏幕共享(screencast)
 */
public class PhoneLeaveGroupCallPresentation <: TLObject {
    public var callId: Int64 = 0
    public var callAccessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x1c50d144 }

    public func serialize(serializer: TLSerializer) {
        // call: InputGroupCall#d8aa840f
        serializer.writeUInt32(0xd8aa840f)
        serializer.writeInt64(callId)
        serializer.writeInt64(callAccessHash)
    }
}

// ==================== Fix TC-0435/TC-0436 R1: account.webBrowserSettings TL layer ====================
//
// Response constructors for account.WebBrowserSettings (parsed directly by SettingsService,
// not modeled as TLResponses.cj classes — kept local to the FIX-1 allowlist):
//   account.webBrowserSettings#79eb8cb3 flags:# externalExceptions:Vector<WebDomainException>
//       inappExceptions:Vector<WebDomainException> hash:long
//   account.webBrowserSettingsNotModified#c31c8f4e = account.WebBrowserSettings
//       (keep current cached value, do not clear)
//   webDomainException#933ca597 flags:# domain:string url:string title:string favicon:flags.0?long

/**
 * account.getWebBrowserSettings#56655768 hash:long = account.WebBrowserSettings
 */
public class AccountGetWebBrowserSettings <: TLObject {
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x56655768 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

/**
 * account.updateWebBrowserSettings#9adf82fe flags:# settings:WebBrowserSettings = Bool
 * flags bit0 = openExternalBrowser
 */
public class AccountUpdateWebBrowserSettings <: TLObject {
    public var openExternalBrowser: Bool = false

    public func getConstructorId(): UInt32 { return 0x9adf82fe }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.openExternalBrowser) { flags = flags | 1 }
        serializer.writeInt32(flags)
    }
}

/**
 * account.toggleWebBrowserSettingsException#60ed4229 flags:# open_external_browser:flags.0?Bool
 *     delete:flags.1?true url:string = Bool
 * bit0 present -> write Bool(openExternalBrowser); bit1 = delete
 */
public class AccountToggleWebBrowserSettingsException <: TLObject {
    public var openExternalBrowser: ?Bool = None
    public var delete: Bool = false
    public var url: String = ""

    public func getConstructorId(): UInt32 { return 0x60ed4229 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        match (this.openExternalBrowser) {
            case Some(_) => flags = flags | 1
            case None => ()
        }
        if (this.delete) { flags = flags | 2 }
        serializer.writeInt32(flags)
        match (this.openExternalBrowser) {
            case Some(v) => serializer.writeBool(v)
            case None => ()
        }
        serializer.writeString(this.url)
    }
}

/**
 * account.deleteWebBrowserSettingsExceptions#86a0765d = Bool
 */
public class AccountDeleteWebBrowserSettingsExceptions <: TLObject {
    public func getConstructorId(): UInt32 { return 0x86a0765d }

    public func serialize(serializer: TLSerializer) {
        // no parameters
    }
}

// ==================== 附件面板（AttachmentSheet）====================

/**
 * messages.searchSentMedia#107e31a0 q:string filter:MessagesFilter limit:int = messages.Messages
 * iOS AttachmentFileController「Recently Sent Files」= searchMessages(location: .sentMedia(tags: [.file]))
 * telegram_api.tl:2352
 */
public class MessagesSearchSentMedia <: TLObject {
    public var q: String = ""
    public var filter: TLObject = InputMessagesFilterDocument()
    public var limit: Int32 = 20

    public func getConstructorId(): UInt32 { return 0x107e31a0 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.q)
        serializer.writeRawBytes(this.filter.toBytes())
        serializer.writeInt32(this.limit)
    }
}

/**
 * inputMediaVenue#c13d1c11 geo_point:InputGeoPoint title:string address:string provider:string
 *   venue_id:string venue_type:string = InputMedia
 * iOS LocationPickerController「OR CHOOSE A PLACE」选中场馆后发送的媒体类型。telegram_api.tl:64
 */
public class InputMediaVenue <: TLObject {
    public var geoPoint: InputGeoPoint = InputGeoPoint()
    public var title: String = ""
    public var address: String = ""
    public var provider: String = "foursquare"
    public var venueId: String = ""
    public var venueType: String = ""

    public func getConstructorId(): UInt32 { return 0xc13d1c11 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.geoPoint.toBytes())
        serializer.writeString(this.title)
        serializer.writeString(this.address)
        serializer.writeString(this.provider)
        serializer.writeString(this.venueId)
        serializer.writeString(this.venueType)
    }
}
