package ohos_app_cangjie_entry.core.mtproto

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.collection.HashMap
import ohos_app_cangjie_entry.models.{ChatFolder, ChatFolderPeer}
/**
 * TL API 响应类型定义
 * 
 * 对应 TelegramHarmony 的 TLResponses.ets
 */

// ==================== 认证响应 ====================

/**
 * P2-013: 验证码投递类型
 * 对应 TL auth.SentCodeType* constructor 完整集
 * ctor 验证来源: iOS Api0.swift auth.SentCodeType enum
 *
 * sentCodeTypeApp#3dbb5986              — Telegram app 内接收（最高优先级）
 * sentCodeTypeSms#c000bba2              — 短信
 * sentCodeTypeCall#5353e5a7             — 语音通话
 * sentCodeTypeFlashCall#ab03c6d9        — 闪拨（来电后挂断，记录来电号码）
 * sentCodeTypeMissedCall#82006484       — 未接来电（前缀匹配）[r1 corrected from 0xe820f71e]
 * sentCodeTypeEmailCode#f450f59b        — 邮件 [r1 corrected from 0xf450b6d9]
 * sentCodeTypeFragmentSms#d9565c39      — Fragment.com 短信（Privacy）
 * sentCodeTypeFirebaseSms#009fd736      — Firebase SMS [r1 corrected from 0xe57b1432]
 * sentCodeTypeSetUpEmailRequired#a5491dea — 需要设置邮箱
 * sentCodeTypeSmsWord#a416ac81          — 单词短信（以单词开头）[r1 corrected from 0xa416c5ad]
 * sentCodeTypeSmsPhrase#b37794af        — 短语短信 [r1 corrected from 0xb37794f9]
 */
public enum SentCodeType {
    | App
    | Sms
    | Call
    | FlashCall
    | MissedCall
    | Email
    | Fragment
    | FirebaseSms
    | SetUpEmailRequired
    | SmsWord
    | SmsPhrase
    | Unknown

    public func ordinal(): Int32 {
        match (this) {
            case App => 0
            case Sms => 1
            case Call => 2
            case FlashCall => 3
            case MissedCall => 4
            case Email => 5
            case Fragment => 6
            case FirebaseSms => 7
            case SetUpEmailRequired => 8
            case SmsWord => 9
            case SmsPhrase => 10
            case Unknown => 11
        }
    }

    public operator func ==(right: SentCodeType): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: SentCodeType): Bool {
        return this.ordinal() != right.ordinal()
    }

    /**
     * P2-013: 返回投递类型对应的 UI 文案
     * 对应 iOS authorizationCurrentOptionText() 的各分支
     */
    public func deliveryDescription(): String {
        match (this) {
            case App => "via Telegram"
            case Sms => "via SMS"
            case Call => "via phone call"
            case FlashCall => "via flash call"
            case MissedCall => "via missed call"
            case Email => "to your email"
            case Fragment => "via Fragment SMS"
            case FirebaseSms => "via SMS"
            case SetUpEmailRequired => "Set up email first"
            case SmsWord => "via SMS (word code)"
            case SmsPhrase => "via SMS (phrase code)"
            case Unknown => "via Telegram"
        }
    }

    /**
     * 返回验证码提示标题（"We've sent the code ...")
     */
    public func deliveryTitle(): String {
        match (this) {
            case App => "We've sent the code via Telegram to"
            case Sms => "We've sent an SMS with a code to"
            case Call => "We're calling you at"
            case FlashCall => "We're calling you at"
            case MissedCall => "Missed call from a number starting with"
            case Email => "We've sent the code to your email"
            case Fragment => "We've sent the code via Fragment SMS to"
            case FirebaseSms => "We've sent an SMS with a code to"
            case SetUpEmailRequired => "Please set up your email address first"
            case SmsWord => "We've sent a word code via SMS to"
            case SmsPhrase => "We've sent a phrase code via SMS to"
            case Unknown => "We've sent the code to"
        }
    }

    /**
     * 是否是电话号码展示型（通话类型显示来电号码前缀，其余显示目标号码）
     */
    public func showsPhoneNumber(): Bool {
        match (this) {
            case SetUpEmailRequired => false
            case Email => false
            case _ => true
        }
    }

    /**
     * QA #6-fix: 页面大标题文案 —— 对齐 iOS AuthorizationSequenceCodeEntryControllerNode
     * .containerLayoutUpdated() 的 titleNode switch：missedCall 走 Login_EnterMissingDigits
     * （"Enter Missing Digits"），其余分支（sms/app/call/flashCall/fragment/firebase/email/
     * setUpEmailRequired/word/phrase/unknown）英文文案均为 "Enter Code"，故只有 MissedCall
     * 需要单独区分，其余保持原 "Enter Code" 不变。
     */
    public func titleText(): String {
        match (this) {
            case MissedCall => "Enter Missing Digits"
            case _ => "Enter Code"
        }
    }
}

/**
 * P2-014: auth.codeType — next delivery method
 * auth.codeTypeSms#72a3158c       = auth.CodeType
 * auth.codeTypeCall#741cd3e3      = auth.CodeType
 * auth.codeTypeFlashCall#226ccefb = auth.CodeType
 * auth.codeTypeMissedCall#d61ad6ee= auth.CodeType
 * auth.codeTypeFragmentSms#06ed998c= auth.CodeType
 * ctor values verified via python struct.unpack against iOS Api0.swift dict[] entries
 */
public enum AuthCodeNextType {
    | SmsNext
    | CallNext
    | FlashCallNext
    | MissedCallNext
    | FragmentSmsNext
    | NoneNext

    public func ordinal(): Int32 {
        match (this) {
            case SmsNext => 0
            case CallNext => 1
            case FlashCallNext => 2
            case MissedCallNext => 3
            case FragmentSmsNext => 4
            case NoneNext => 5
        }
    }

    public operator func ==(right: AuthCodeNextType): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: AuthCodeNextType): Bool {
        return this.ordinal() != right.ordinal()
    }

    /**
     * P2-014: Label for the "switch delivery method" button
     * Mirrors iOS authorizationNextOptionText() active-case labels
     */
    public func switchButtonLabel(): String {
        match (this) {
            case SmsNext => "Get code via SMS"
            case CallNext => "Call me"
            case FlashCallNext => "Flash call"
            case MissedCallNext => "Missed call"
            case FragmentSmsNext => "Get code via Fragment SMS"
            case NoneNext => ""
        }
    }
}

/**
 * P2-014: parse auth.codeType constructor to AuthCodeNextType
 */
func parseAuthCodeNextType(ctor: UInt32): AuthCodeNextType {
    if (ctor == 0x72a3158c) { return AuthCodeNextType.SmsNext }
    if (ctor == 0x741cd3e3) { return AuthCodeNextType.CallNext }
    if (ctor == 0x226ccefb) { return AuthCodeNextType.FlashCallNext }
    if (ctor == 0xd61ad6ee) { return AuthCodeNextType.MissedCallNext }
    if (ctor == 0x06ed998c) { return AuthCodeNextType.FragmentSmsNext }
    return AuthCodeNextType.NoneNext
}

/**
 * auth.sentCode 响应
 * P2-014: now also parses nextType (flags.1) instead of discarding it
 */
public class AuthSentCodeResponse {
    public var codeType: SentCodeType = SentCodeType.Unknown
    public var codeLength: Int32 = 0
    public var phoneCodeHash: String = ""
    public var timeout: Int32 = 0
    // P2-014: next available delivery method (None if server didn't send one)
    public var nextType: AuthCodeNextType = AuthCodeNextType.NoneNext

    public static func deserialize(data: Array<Byte>): AuthSentCodeResponse {
        let r = AuthSentCodeResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()

        if (constructor == 0x5e002502) {
            let flags = d.readInt32()
            // 解析 SentCodeType（boxed）——同时取回验证码位数
            let codeTypeConstructor = d.readUInt32()
            let (parsedType, parsedLength) = parseSentCodeType(codeTypeConstructor, d)
            r.codeType = parsedType
            r.codeLength = parsedLength

            r.phoneCodeHash = d.readString()

            // P2-014: parse nextType (flags.1) — was previously discarded
            if ((flags & 2) != 0) {
                let nextTypeCtor = d.readUInt32()
                r.nextType = parseAuthCodeNextType(nextTypeCtor)
            }
            if ((flags & 4) != 0) {
                r.timeout = d.readInt32()
            }
        }

        return r
    }
}

/**
 * P2-013 r1: 解析 TL auth.SentCodeType 完整变体
 * ctor 值经 python struct.unpack 对 iOS Api0.swift dict[] 逐个验证
 * (signed-dec → unsigned-hex via struct.unpack('<I', struct.pack('<i', N))[0])
 *
 * sentCodeTypeApp#3dbb5986              length:int32
 * sentCodeTypeSms#c000bba2              length:int32
 * sentCodeTypeCall#5353e5a7             length:int32
 * sentCodeTypeFlashCall#ab03c6d9        pattern:string
 * sentCodeTypeMissedCall#82006484       prefix:string length:int32
 * sentCodeTypeEmailCode#f450f59b        flags:int32 email_pattern:string length:int32 [resetAvailablePeriod:int32]? [resetPendingDate:int32]?
 * sentCodeTypeFragmentSms#d9565c39      url:string length:int32
 * sentCodeTypeFirebaseSms#009fd736      flags:int32 [nonce:bytes]? [playIntegrityProjectId:int64 playIntegrityNonce:bytes]? [receipt:string pushTimeout:int32]? length:int32
 * sentCodeTypeSetUpEmailRequired#a5491dea flags:int32
 * sentCodeTypeSmsWord#a416ac81          flags:int32 [beginning:string]?
 * sentCodeTypeSmsPhrase#b37794af        flags:int32 [beginning:string]?
 *
 * Field reading order verified against Api33.swift parse_sentCodeType* functions.
 */
// 返回 (类型, 验证码位数)。位数来自各变体的 length:int32 字段（无该字段的变体返回 0）。
// 此前该函数只返回类型、把 length 用 `let _ =` 丢弃，导致 AuthSentCodeResponse.codeLength
// 恒为 0，UI 只能写死 5 位——中国短信 6 位就填不满/不自动提交。现把 length 一并返回。
func parseSentCodeType(constructor: UInt32, d: TLDeserializer): (SentCodeType, Int32) {
    if (constructor == 0x3dbb5986) {
        // sentCodeTypeApp — length:int32
        let length = d.readInt32()
        return (SentCodeType.App, length)
    } else if (constructor == 0xc000bba2) {
        // sentCodeTypeSms — length:int32
        let length = d.readInt32()
        return (SentCodeType.Sms, length)
    } else if (constructor == 0x5353e5a7) {
        // sentCodeTypeCall — length:int32
        let length = d.readInt32()
        return (SentCodeType.Call, length)
    } else if (constructor == 0xab03c6d9) {
        // sentCodeTypeFlashCall — pattern:string（无 length；iOS 固定按 6 位处理）
        let _ = d.readString()
        return (SentCodeType.FlashCall, 6)
    } else if (constructor == 0x82006484) {
        // sentCodeTypeMissedCall — prefix:string length:int32
        // iOS: parse_sentCodeTypeMissedCall reads String then Int32
        let _ = d.readString()
        let length = d.readInt32()
        return (SentCodeType.MissedCall, length)
    } else if (constructor == 0xf450f59b) {
        // sentCodeTypeEmailCode — flags:int32 email_pattern:string length:int32
        //   bit3 → resetAvailablePeriod:int32
        //   bit4 → resetPendingDate:int32
        // iOS: parse_sentCodeTypeEmailCode field order verified
        let flags = d.readInt32()
        let _ = d.readString()
        let length = d.readInt32()
        if ((flags & (1 << 3)) != 0) {
            let _ = d.readInt32()
        }
        if ((flags & (1 << 4)) != 0) {
            let _ = d.readInt32()
        }
        return (SentCodeType.Email, length)
    } else if (constructor == 0xd9565c39) {
        // sentCodeTypeFragmentSms — url:string length:int32
        // iOS: parse_sentCodeTypeFragmentSms reads String then Int32
        let _ = d.readString()
        let length = d.readInt32()
        return (SentCodeType.Fragment, length)
    } else if (constructor == 0x009fd736) {
        // sentCodeTypeFirebaseSms — flags:int32 [conditional fields] length:int32
        //   bit0 → nonce:bytes
        //   bit2 → playIntegrityProjectId:int64 + playIntegrityNonce:bytes
        //   bit1 → receipt:string + pushTimeout:int32
        //   always → length:int32
        // iOS: parse_sentCodeTypeFirebaseSms field order verified
        let flags = d.readInt32()
        if ((flags & (1 << 0)) != 0) {
            let _ = d.readBytes()
        }
        if ((flags & (1 << 2)) != 0) {
            let _ = d.readInt64()
            let _ = d.readBytes()
        }
        if ((flags & (1 << 1)) != 0) {
            let _ = d.readString()
            let _ = d.readInt32()
        }
        let length = d.readInt32()
        return (SentCodeType.FirebaseSms, length)
    } else if (constructor == 0xa5491dea) {
        // sentCodeTypeSetUpEmailRequired — flags:int32（无 length）
        // iOS: parse_sentCodeTypeSetUpEmailRequired reads Int32 flags
        let _ = d.readInt32()
        return (SentCodeType.SetUpEmailRequired, 0)
    } else if (constructor == 0xa416ac81) {
        // sentCodeTypeSmsWord — flags:int32 [beginning:string]? (bit0)（无 length）
        // iOS: parse_sentCodeTypeSmsWord reads flags then conditional string
        let flags = d.readInt32()
        if ((flags & (1 << 0)) != 0) {
            let _ = d.readString()
        }
        return (SentCodeType.SmsWord, 0)
    } else if (constructor == 0xb37794af) {
        // sentCodeTypeSmsPhrase — flags:int32 [beginning:string]? (bit0)（无 length）
        // iOS: parse_sentCodeTypeSmsPhrase reads flags then conditional string
        let flags = d.readInt32()
        if ((flags & (1 << 0)) != 0) {
            let _ = d.readString()
        }
        return (SentCodeType.SmsPhrase, 0)
    }
    return (SentCodeType.Unknown, 0)
}

/**
 * auth.passwordRecovery#137948a5 email_pattern:string = auth.PasswordRecovery
 */
public class AuthPasswordRecoveryResponse {
    public var emailPattern: String = ""

    public static func deserialize(data: Array<Byte>): AuthPasswordRecoveryResponse {
        let r = AuthPasswordRecoveryResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()
        if (constructor == 0x137948a5) {
            r.emailPattern = d.readString()
        }
        return r
    }
}

/**
 * auth.authorization 响应
 */
public class AuthAuthorizationResponse {
    public var signUpRequired: Bool = false
    public var user: Option<UserResponse> = None

    public static func deserialize(data: Array<Byte>): AuthAuthorizationResponse {
        let r = AuthAuthorizationResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()

        if (constructor == 0x44747e9a) {
            // auth.authorizationSignUpRequired
            r.signUpRequired = true
        } else if (constructor == 0x2ea2c0d4) {
            // auth.authorization
            let flags = d.readInt32()
            if ((flags & 2) != 0) {
                // setup_password_required
            }
            if ((flags & 4) != 0) {
                let _ = d.readInt32() // otherwise_relogin_days
            }
            if ((flags & 1) != 0) {
                let _ = d.readInt32() // tmp_sessions
            }
            if ((flags & 8) != 0) {
                let _ = d.readBytes() // future_auth_token
            }
            r.user = Some(UserResponse.deserializeBoxed(d))
        }

        return r
    }
}

/**
 * 用户响应
 */
public class UserResponse {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var firstName: String = ""
    public var lastName: String = ""
    public var username: String = ""
    // usernames?[flags2.0]（username#b4073647 flags:# editable:flags.0?true active:flags.1?true username:string）。
    // 自可收藏用户名起，服务器对拥有多个用户名的用户把 `username` 留空、全部放进 `usernames`；
    // 解析时若 `username` 为空则回填为 active 的那条（iOS TelegramUser.usernames / addressName 语义）。
    public var usernames: ArrayList<String> = ArrayList<String>()
    public var phone: String = ""
    public var isBot: Bool = false
    // bot_has_main_app: flags2.13（telegram_api.tl user#20b1422）— iOS ChatListItem 据此显示 OPEN 按钮
    public var botHasMainApp: Bool = false
    public var isSelf: Bool = false
    public var isContact: Bool = false
    public var isSupport: Bool = false
    public var isPremium: Bool = false
    public var botSubscriberCount: Int32 = 0
    // Badge flags — iOS TelegramUser.swift TelegramApi/Sources/Api30.swift parse_user:
    //   isVerified: flags.17 (iOS: flags & (1 << 17))
    //   isScam:     flags.24 (iOS: flags & (1 << 24))
    //   isFake:     flags.26 (iOS: flags & (1 << 26))
    public var isVerified: Bool = false
    public var isScam: Bool = false
    public var isFake: Bool = false
    public var isEmpty: Bool = false
    // User status fields
    public var isOnline: Bool = false
    public var wasOnline: Int32 = 0   // Unix timestamp (seconds) when user was last online
    public var statusType: String = "empty" // "online", "offline", "recently", "lastWeek", "lastMonth", "empty"
    // User profile photo fields (Phase L1)
    public var hasPhoto: Bool = false
    public var photoId: Int64 = 0
    public var photoDcId: Int32 = 0
    public var strippedThumb: Array<Byte> = Array<Byte>(0, repeat: 0)
    // Server-authoritative nameColor/profileColor preset index (flags2.8/flags2.9, boxed PeerColor).
    // Source: TelegramUser.swift:146-158 apiUser.color/profile_color -> TelegramUser.nameColor/
    // profileColor as PeerColor.preset(rawValue: color). None = server did not send this PeerColor
    // field at all (flags2 bit unset) — distinct from Some(0), which means the server sent the
    // field with preset index 0. Consumers must not collapse None into a literal default here;
    // that decision (server value vs local override vs literal fallback) belongs to the reader.
    public var nameColorIndex: Option<Int32> = None
    public var profileColorIndex: Option<Int32> = None

    public static func deserializeBoxed(d: TLDeserializer): UserResponse {
        let constructor = d.readUInt32()
        return deserializeWithConstructor(constructor, d)
    }

    public static func deserializeWithConstructor(constructor: UInt32, d: TLDeserializer): UserResponse {
        let r = UserResponse()

        if (constructor == 0xd3bc4b7a) {
            // userEmpty
            r.isEmpty = true
            r.id = d.readInt64()
            Hilog.info(0, "CjTelegram", "[UserResponse] userEmpty id=${r.id}")
            return r
        }

        // Accept current ctor 0x31774388 and legacy ctors 0x317a5722, 0x20b1422
        if (constructor != 0x31774388 && constructor != 0x317a5722 && constructor != 0x20b1422) {
            Hilog.info(0, "CjTelegram", "[UserResponse] Unknown user constructor: ${constructor}, attempting parse")
            // Fall through — attempt to parse with current field layout for forward compat
        }

        Hilog.info(0, "CjTelegram", "[UserResponse] constructor=${constructor}, offset=${d.getOffset()}")

        // user#31774388 (current, iOS dict[829899656]) / #317a5722 (Layer 214) / #20b1422 (Layer 188+)
        // iOS Api30.swift:901 parse_user field order:
        //   flags(Int32), flags2(Int32) always, id(Int64),
        //   access_hash?[flags.0](Int64), first_name?[flags.1](String), last_name?[flags.2](String),
        //   username?[flags.3](String), phone?[flags.4](String),
        //   photo?[flags.5](boxed UserProfilePhoto), status?[flags.6](boxed UserStatus),
        //   bot_info_version?[flags.14](Int32), restriction_reason?[flags.18](vector),
        //   bot_inline_placeholder?[flags.19](String), lang_code?[flags.22](String),
        //   emoji_status?[flags.30](boxed EmojiStatus),
        //   usernames?[flags2.0](vector), stories_max_id?[flags2.5](boxed RecentStory),
        //   color?[flags2.8](boxed PeerColor), profile_color?[flags2.9](boxed PeerColor),
        //   bot_active_users?[flags2.12](Int32), bot_verification_icon?[flags2.14](Int64),
        //   send_paid_messages_stars?[flags2.15](Int64)
        let flags = d.readInt32()
        // flags2 is ALWAYS present for all supported ctors (0x31774388, 0x317a5722, 0x20b1422)
        let flags2 = d.readInt32()

        r.id = d.readInt64()
        r.isSelf = (flags & (1 << 10)) != 0
        r.isContact = (flags & (1 << 11)) != 0
        r.isBot = (flags & (1 << 14)) != 0
        r.botHasMainApp = (flags2 & (1 << 13)) != 0  // bot_has_main_app (flags2.13, 纯标志位无载荷)
        r.isSupport = (flags & (1 << 23)) != 0
        // Badge flags — iOS TelegramUser.swift / Api30.swift parse_user verified sources:
        //   isVerified: flags.17  isScam: flags.24  isFake: flags.26
        r.isVerified = (flags & (1 << 17)) != 0
        r.isScam = (flags & (1 << 24)) != 0
        r.isFake = (flags & (1 << 26)) != 0
        r.isPremium = (flags & (1 << 28)) != 0

        if ((flags & 1) != 0) { r.accessHash = d.readInt64() }
        if ((flags & 2) != 0) { r.firstName = d.readString() }
        if ((flags & 4) != 0) { r.lastName = d.readString() }
        if ((flags & 8) != 0) { r.username = d.readString() }
        if ((flags & 16) != 0) { r.phone = d.readString() }

        // 解析用户头像（Phase L1：不再跳过，提取 photoId/dcId/strippedThumb）
        if ((flags & 32) != 0) { parseUserProfilePhoto(d, r) }  // photo
        if ((flags & 64) != 0) { parseUserStatus(d, r) }  // status
        if ((flags & (1 << 14)) != 0) { let _ = d.readInt32() }  // bot_info_version
        if ((flags & (1 << 18)) != 0) { skipVector(d) }  // restriction_reason
        if ((flags & (1 << 19)) != 0) { let _ = d.readString() }  // bot_inline_placeholder
        if ((flags & (1 << 22)) != 0) { let _ = d.readString() }  // lang_code
        if ((flags & (1 << 30)) != 0) { skipEmojiStatus(d) }  // emoji_status
        if ((flags2 & 1) != 0) { parseUserUsernames(d, r) }  // usernames (flags2.0)
        // stories_max_id (flags2.5): boxed RecentStory#711d692d flags:# max_id?[flags.1](Int32)
        if ((flags2 & (1 << 5)) != 0) { skipRecentStory(d) }  // stories_max_id (flags2.5)
        if ((flags2 & (1 << 8)) != 0) { r.nameColorIndex = parsePeerColorValue(d) }  // color (flags2.8)
        if ((flags2 & (1 << 9)) != 0) { r.profileColorIndex = parsePeerColorValue(d) }  // profile_color (flags2.9)
        if ((flags2 & (1 << 12)) != 0) { r.botSubscriberCount = d.readInt32() }  // bot_active_users (flags2.12)
        if ((flags2 & (1 << 14)) != 0) { let _ = d.readInt64() }  // bot_verification_icon (flags2.14)
        if ((flags2 & (1 << 15)) != 0) { let _ = d.readInt64() }  // send_paid_messages_stars (flags2.15)

        let nameColorLog = match (r.nameColorIndex) {
            case Some(v) => "${v}"
            case None => "unset"
        }
        let profileColorLog = match (r.profileColorIndex) {
            case Some(v) => "${v}"
            case None => "unset"
        }
        Hilog.info(0, "CjTelegram", "[UserResponse] Parsed: id=${r.id}, firstName='${r.firstName}', lastName='${r.lastName}', accessHash=${r.accessHash}, nameColorIndex=${nameColorLog}, profileColorIndex=${profileColorLog}")
        return r
    }
}

func parseUserProfilePhoto(d: TLDeserializer, user: UserResponse): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x4f11bae1) {
        Hilog.info(0, "CjTelegram", "[AVT] parse userId=${user.id}: photoEmpty")
        return
    }
    // userProfilePhoto#82d1f706
    let flags = d.readInt32()
    user.photoId = d.readInt64()
    if ((flags & 2) != 0) {
        user.strippedThumb = d.readBytes()
    }
    user.photoDcId = d.readInt32()
    user.hasPhoto = true
    Hilog.info(0, "CjTelegram", "[AVT] parse userId=${user.id}: hasPhoto=true photoId=${user.photoId} dc=${user.photoDcId} thumbSz=${user.strippedThumb.size} flags=${flags}")
}

// 保留跳过版本供 TLDialogs 等其他地方使用
func skipUserProfilePhoto(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x4f11bae1) {
        // userProfilePhotoEmpty
        return
    }
    // userProfilePhoto#82d1f706
    let flags = d.readInt32()
    let _ = d.readInt64() // photo_id
    if ((flags & 2) != 0) {
        let _ = d.readBytes() // stripped_thumb
    }
    let _ = d.readInt32() // dc_id
}

func parseUserStatus(d: TLDeserializer, user: UserResponse): Unit {
    let constructor = d.readUInt32()
    // userStatusEmpty#09d05049
    if (constructor == 0x09d05049) {
        user.statusType = "empty"
        return
    }
    // userStatusOnline#edb93949 - has expires:int
    if (constructor == 0xedb93949) {
        let _ = d.readInt32() // expires
        user.isOnline = true
        user.statusType = "online"
        return
    }
    // userStatusOffline#008c703f - has was_online:int
    if (constructor == 0x008c703f) {
        user.wasOnline = d.readInt32()
        user.isOnline = false
        user.statusType = "offline"
        return
    }
    // userStatusRecently - 新旧两版构造器:
    //   old: #e26f42f1, #7bf09fc
    //   new (Layer 188+): #7b197dc8 flags:# by_me:flags.0?true
    if (constructor == 0xe26f42f1 || constructor == 0x7bf09fc || constructor == 0x7b197dc8) {
        let _ = d.readInt32()  // flags
        user.statusType = "recently"
        return
    }
    // userStatusLastWeek - 新旧两版构造器:
    //   old: #77ebc742, #541a1d1a
    //   new (Layer 188+): #b393c580 flags:# by_me:flags.0?true
    if (constructor == 0x77ebc742 || constructor == 0x541a1d1a || constructor == 0xb393c580) {
        let _ = d.readInt32()  // flags
        user.statusType = "lastWeek"
        return
    }
    // userStatusLastMonth - 新旧两版构造器:
    //   old: #b197c698
    //   new (Layer 188+): #65899777 flags:# by_me:flags.0?true
    if (constructor == 0xb197c698 || constructor == 0x65899777) {
        let _ = d.readInt32()  // flags
        user.statusType = "lastMonth"
        return
    }
    // 未知 status - 安全回退：所有新版 status 都有 flags:int，消费它以保持 deserializer 位置正确
    Hilog.info(0, "CjTelegram", "[parseUserStatus] Unknown constructor: ${constructor}, consuming flags:int as fallback")
    let _ = d.readInt32()  // flags (安全回退)
}

// ==================== RPC 错误响应 ====================

public class RPCErrorResponse {
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""

    public static func deserialize(data: Array<Byte>): RPCErrorResponse {
        let r = RPCErrorResponse()
        let d = TLDeserializer(data)
        let _ = d.readUInt32() // constructor
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
}

// ==================== Peer 响应 ====================

public class PeerResponse {
    public var type_: String = ""  // "user", "chat", "channel"
    public var id: Int64 = 0

    public static func deserializeBoxed(d: TLDeserializer): PeerResponse {
        let r = PeerResponse()
        let constructor = d.readUInt32()
        if (constructor == 0x59511722) {
            r.type_ = "user"
        } else if (constructor == 0x36c6019a) {
            r.type_ = "chat"
        } else if (constructor == 0xa2a5371e) {
            r.type_ = "channel"
        }
        r.id = d.readInt64()
        return r
    }
}

// ==================== Chat 响应 ====================

public class ChatResponse {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var title: String = ""
    public var username: String = ""
    public var isChannel: Bool = false
    public var isMegagroup: Bool = false
    public var isBroadcast: Bool = false
    public var isCreator: Bool = false
    public var canInviteUsers: Bool = false
    public var isMigrated: Bool = false
    // chat.migrated_to:flags.6?InputChannel → iOS TelegramGroup.migrationReference（ApiGroupOrChannel.swift:72-77）
    public var migratedToChannelId: Int64 = 0
    public var migratedToAccessHash: Int64 = 0
    public var requestToJoin: Bool = false
    public var isLeft: Bool = false
    public var canEditInfo: Bool = false
    public var hasVoiceChat: Bool = false
    // call_not_empty (flags.24): iOS TelegramChannel/TelegramGroup .hasActiveVoiceChat (ApiGroupOrChannel.swift:97,164)
    public var hasActiveVoiceChat: Bool = false
    public var isVerified: Bool = false
    public var isScam: Bool = false
    public var isFake: Bool = false
    public var participantsCount: Int32 = 0
    public var hasPhoto: Bool = false
    public var photoId: Int64 = 0
    public var photoDcId: Int32 = 0
    public var strippedThumb: Array<Byte> = Array<Byte>(0, repeat: 0)
    // Channel flags parsed from channel.flags (TL schema channel#7482147e):
    //   signaturesEnabled: flags.11 (1 << 11 = 2048) — Sign Messages on/off
    //   noForwardsEnabled: flags.27 (1 << 27 = 134217728) — Restrict Saving Content on/off
    public var signaturesEnabled: Bool = false
    public var noForwardsEnabled: Bool = false
    // 当前账号在该群的管理员权限位（chatAdminRights.flags；非管理员为 0）。
    public var adminRightsFlags: Int32 = 0
    // 群默认权限位（chatBannedRights.flags；置位 = 该动作被禁止）。
    // iOS TelegramGroup.defaultBannedRights / TelegramChannel.defaultBannedRights，
    // hasBannedPermission(.banChangeInfo) 等判断都依赖它。
    public var defaultBannedRightsFlags: Int32 = 0
    // 当前账号在该超级群被限制的权限位（channel.banned_rights.flags）。
    public var bannedRightsFlags: Int32 = 0

    public static func deserializeBoxed(d: TLDeserializer): ChatResponse {
        let constructor = d.readUInt32()
        return deserializeWithConstructor(constructor, d)
    }

    public static func deserializeWithConstructor(constructor: UInt32, d: TLDeserializer): ChatResponse {
        let r = ChatResponse()

        if (constructor == 0x29562865) {
            // chatEmpty
            r.id = d.readInt64()
            return r
        }

        if (constructor == 0x41cbf256) {
            // chat
            let flags = d.readInt32()
            r.isCreator = (flags & 1) != 0
            r.isLeft = (flags & 6) != 0
            // deactivated（flags.5）：iOS FetchChatList.swift:93 按此位把基础群排除出列表，
            // 升级后的旧群同时带 migrated_to（flags.6，下方解析）。
            if ((flags & 32) != 0) { r.isMigrated = true }
            r.hasVoiceChat = (flags & (1 << 23)) != 0
            r.hasActiveVoiceChat = (flags & (1 << 24)) != 0
            r.id = d.readInt64()
            r.title = d.readString()
            parseChatPhoto(d, r)
            r.participantsCount = d.readInt32()
            let _ = d.readInt32() // date
            let _ = d.readInt32() // version
            if ((flags & 64) != 0) { // migrated_to
                r.isMigrated = true
                let migratedCtor = d.readUInt32()
                if (migratedCtor == 0xf35aec28) {
                    // inputChannel#f35aec28 channel_id:long access_hash:long
                    r.migratedToChannelId = d.readInt64()
                    r.migratedToAccessHash = d.readInt64()
                } else if (migratedCtor == 0x5b934f9d) {
                    // inputChannelFromMessage#5b934f9d peer:InputPeer msg_id:int channel_id:long
                    skipInputPeer(d)
                    let _ = d.readInt32()
                    r.migratedToChannelId = d.readInt64()
                } else if (migratedCtor != 0xee8c1e86) {
                    let _ = d.readInt64()
                    let _ = d.readInt64()
                }
            }
            if ((flags & (1 << 14)) != 0) {
                let rights = parseChatAdminRightsFlags(d)
                r.adminRightsFlags = rights
                r.canInviteUsers = (rights & (1 << 5)) != 0
                r.canEditInfo = (rights & ((1 << 0) | (1 << 4) | (1 << 5) | (1 << 9))) != 0
            }
            if ((flags & (1 << 18)) != 0) { r.defaultBannedRightsFlags = parseChatBannedRightsFlags(d) }
            return r
        }

        if (constructor == 0x6592a1a7) {
            // chatForbidden
            r.isLeft = true
            r.id = d.readInt64()
            r.title = d.readString()
            return r
        }

        // channel#fe685355 (Layer 214) 或 channel#1c32b11c (旧版本) - 严格匹配 TelegramHarmony
        if (constructor == 0xfe685355 || constructor == 0x1c32b11c) {
            r.isChannel = true
            let flags = d.readInt32()
            let flags2 = d.readInt32()
            r.id = d.readInt64()
            r.isCreator = (flags & 1) != 0
            r.isLeft = (flags & 6) != 0
            r.hasVoiceChat = (flags & (1 << 23)) != 0
            r.hasActiveVoiceChat = (flags & (1 << 24)) != 0
            r.isBroadcast = (flags & 32) != 0
            r.isVerified = (flags & 128) != 0
            r.isMegagroup = (flags & 256) != 0  // bit 8
            r.requestToJoin = (flags & (1 << 29)) != 0
            r.isScam = (flags & (1 << 19)) != 0
            r.isFake = (flags & (1 << 25)) != 0
            // channel.flags.11 (1<<11=2048): signatures enabled (Sign Messages)
            r.signaturesEnabled = (flags & 2048) != 0
            // channel.flags.27 (1<<27=134217728): noforwards (Restrict Saving Content)
            r.noForwardsEnabled = (flags & 134217728) != 0
            if ((flags & 8192) != 0) { r.accessHash = d.readInt64() }  // bit 13
            r.title = d.readString()
            if ((flags & 64) != 0) { r.username = d.readString() }  // bit 6
            parseChatPhoto(d, r)
            let _ = d.readInt32() // date
            // 严格按照 TelegramHarmony 顺序读取
            if ((flags & 512) != 0) { skipVector(d) }  // restriction_reason - bit 9
            if ((flags & 16384) != 0) {
                let rights = parseChatAdminRightsFlags(d)
                r.adminRightsFlags = rights
                r.canInviteUsers = (rights & (1 << 5)) != 0
                // iOS permits channel editing for every administrator; the editor
                // itself constrains fields by the detailed rights object.
                r.canEditInfo = true
            }
            if ((flags & 32768) != 0) { r.bannedRightsFlags = parseChatBannedRightsFlags(d) }  // banned_rights - bit 15
            if ((flags & 262144) != 0) { r.defaultBannedRightsFlags = parseChatBannedRightsFlags(d) }  // default_banned_rights - bit 18
            if ((flags & 131072) != 0) { r.participantsCount = d.readInt32() }  // participants_count - bit 17
            // flags2 字段
            if ((flags2 & 1) != 0) { skipVector(d) }  // usernames - flags2 bit 0
            if ((flags2 & 16) != 0) { skipRecentStory(d) }  // storiesMaxId - flags2 bit 4 (boxed RecentStory#711d692d, iOS Api4.swift:1076)
            if ((flags2 & 128) != 0) { skipPeerColor(d) }  // color - flags2 bit 7
            if ((flags2 & 256) != 0) { skipPeerColor(d) }  // profileColor - flags2 bit 8
            if ((flags2 & 512) != 0) { skipEmojiStatus(d) }  // emojiStatus - flags2 bit 9
            if ((flags2 & 1024) != 0) { let _ = d.readInt32() }  // level - flags2 bit 10
            if ((flags2 & 2048) != 0) { let _ = d.readInt32() }  // subscriptionUntilDate - flags2 bit 11
            if ((flags2 & 8192) != 0) { let _ = d.readInt64() }  // botVerificationIcon - flags2 bit 13
            if ((flags2 & 16384) != 0) { let _ = d.readInt64() }  // sendPaidMessagesStars - flags2 bit 14
            if ((flags2 & 262144) != 0) { let _ = d.readInt64() }  // linkedMonoforumId - flags2 bit 18
            return r
        }

        if (constructor == 0x17d493d5) {
            // channelForbidden - 匹配 TelegramHarmony
            r.isChannel = true
            r.isLeft = true
            let flags = d.readInt32()
            r.id = d.readInt64()
            r.accessHash = d.readInt64()
            r.title = d.readString()
            if ((flags & 65536) != 0) { let _ = d.readInt32() }  // untilDate - bit 16
            return r
        }

        return r
    }
}

// Folder 等只需要消费 photo 字段、不持有 ChatResponse 的协议对象仍复用此兼容路径。
func skipChatPhoto(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x37c1011c) { return }
    let flags = d.readInt32()
    let _ = d.readInt64()
    if ((flags & 2) != 0) { let _ = d.readBytes() }
    let _ = d.readInt32()
}

func parseChatPhoto(d: TLDeserializer, chat: ChatResponse): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x37c1011c) {
        return
    }
    // chatPhoto#1c6e1c11
    let flags = d.readInt32()
    chat.photoId = d.readInt64()
    if ((flags & 2) != 0) {
        chat.strippedThumb = d.readBytes()
    }
    chat.photoDcId = d.readInt32()
    chat.hasPhoto = chat.photoId != 0
    Hilog.info(0, "CjTelegram", "[AVT] parse chatId=${chat.id}: hasPhoto=${chat.hasPhoto} photoId=${chat.photoId} dc=${chat.photoDcId}")
}

func skipInputChannel(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0xee8c1e86) { return } // inputChannelEmpty
    if (constructor == 0xf35aec28) {
        // inputChannel
        let _ = d.readInt64() // channel_id
        let _ = d.readInt64() // access_hash
        return
    }
    if (constructor == 0x5b934f9d) {
        // inputChannelFromMessage
        skipInputPeer(d)  // peer
        let _ = d.readInt32() // msg_id
        let _ = d.readInt64() // channel_id
        return
    }
    // unknown - try basic skip
    let _ = d.readInt64() // channel_id
    let _ = d.readInt64() // access_hash
}

// InputPeer full ctor set (ground truth: Api0.swift dict + Api12.swift parse_inputPeer*):
//   inputPeerEmpty#7f3b18ea — no fields
//   inputPeerSelf#7da07ec9 — no fields
//   inputPeerChat#35a95cb9 — chat_id:long
//   inputPeerUser#dde8a54c — user_id:long access_hash:long
//   inputPeerChannel#27bcbbfc — channel_id:long access_hash:long
//   inputPeerUserFromMessage#a87b0a1c — peer:InputPeer(boxed) msg_id:int user_id:long
//   inputPeerChannelFromMessage#bd2a0840 — peer:InputPeer(boxed) msg_id:int channel_id:long
func skipInputPeer(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x7f3b18ea) { return } // inputPeerEmpty
    if (constructor == 0x7da07ec9) { return } // inputPeerSelf
    if (constructor == 0xdde8a54c) {
        // inputPeerUser
        let _ = d.readInt64()
        let _ = d.readInt64()
        return
    }
    if (constructor == 0x35a95cb9) {
        // inputPeerChat
        let _ = d.readInt64()
        return
    }
    if (constructor == 0x27bcbbfc) {
        // inputPeerChannel
        let _ = d.readInt64()
        let _ = d.readInt64()
        return
    }
    if (constructor == 0xa87b0a1c) {
        // inputPeerUserFromMessage#a87b0a1c peer:InputPeer(boxed) msg_id:int user_id:long
        // (Api0.swift dict[-1468331492] -> Api12.swift parse_inputPeerUserFromMessage:452-469).
        // Nested peer is itself a boxed InputPeer, so recurse into skipInputPeer to consume it
        // before reading the trailing msg_id/user_id scalars.
        skipInputPeer(d) // peer (nested boxed InputPeer)
        let _ = d.readInt32() // msgId
        let _ = d.readInt64() // userId
        return
    }
    if (constructor == 0xbd2a0840) {
        // inputPeerChannelFromMessage#bd2a0840 peer:InputPeer(boxed) msg_id:int channel_id:long
        // (Api0.swift dict[-1121318848] -> Api12.swift parse_inputPeerChannelFromMessage:402-420).
        skipInputPeer(d) // peer (nested boxed InputPeer)
        let _ = d.readInt32() // msgId
        let _ = d.readInt64() // channelId
        return
    }
    // Unknown InputPeer variant — previously this fell through and returned having consumed
    // ZERO bytes, silently desyncing every subsequent TL value in the same response (this is
    // exactly the class of bug fixed for dialog# in c0c71d26 and inputReplyToMessage# in
    // 6dc74c20/skipInputReplyTo). We cannot safely guess an unknown layout's field count, so we
    // only log for visibility into future schema drift; the caller's downstream parse will still
    // desync, but at least it is now observable in Hilog instead of silent.
    Hilog.info(0, "CjTelegram", "[skipInputPeer] Unknown InputPeer ctor: 0x${toHex32(constructor)}, cannot safely skip")
}

func skipChatAdminRights(d: TLDeserializer): Unit {
    let _ = parseChatAdminRightsFlags(d)
}

func parseChatAdminRightsFlags(d: TLDeserializer): Int32 {
    let _ = d.readUInt32() // constructor
    return d.readInt32() // flags
}

func skipChatBannedRights(d: TLDeserializer): Unit {
    let _ = d.readUInt32() // constructor
    let _ = d.readInt32() // flags
    let _ = d.readInt32() // until_date
}

/** chatBannedRights#9f120418 flags:# ... until_date:int — 只取 flags 位。 */
func parseChatBannedRightsFlags(d: TLDeserializer): Int32 {
    let _ = d.readUInt32() // constructor
    let flags = d.readInt32()
    let _ = d.readInt32() // until_date
    return flags
}

/**
 * 跳过一个泛型 Vector（读取每个元素为 boxed TL object）
 * 适用于 Vector<RestrictionReason>, Vector<Username> 等
 */
/**
 * 解析 user.usernames:Vector<Username>（username#b4073647 flags:# editable:flags.0?true
 * active:flags.1?true username:string）。全部收进 r.usernames；`r.username` 为空时回填为
 * 第一条 active 用户名（没有 active 则取第一条），与 iOS `TelegramUser.addressName` 一致。
 */
func parseUserUsernames(d: TLDeserializer, r: UserResponse): Unit {
    let vectorConstructor = d.readUInt32()
    if (vectorConstructor != TLConstructors.VECTOR) { return }
    let count = d.readInt32()
    var firstActive = ""
    var first = ""
    for (_i in 0..Int64(count)) {
        let ctor = d.readUInt32()
        if (ctor != 0xb4073647) {
            // 未知构造器：无法安全继续解析该向量，停止（后续字段可能错位，但不抛异常）
            Hilog.info(0, "CjTelegram", "[UserResponse] unknown Username ctor: ${ctor}")
            return
        }
        let uflags = d.readInt32()
        let name = d.readString()
        let active = (uflags & (1 << 1)) != 0
        r.usernames.add(name)
        if (first.size == 0) { first = name }
        if (active && firstActive.size == 0) { firstActive = name }
    }
    if (r.username.size == 0) {
        r.username = if (firstActive.size > 0) { firstActive } else { first }
    }
}

func skipVector(d: TLDeserializer): Unit {
    let vectorConstructor = d.readUInt32()
    if (vectorConstructor != TLConstructors.VECTOR) {
        // 不是标准 vector，无法跳过
        return
    }
    let count = d.readInt32()
    for (_i in 0..Int64(count)) {
        skipBoxedObject(d)
    }
}

/**
 * 跳过一个 boxed TL object（读取 constructor + 根据类型跳过字段）
 * 用于通用跳过未知类型
 */
func skipBoxedObject(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    // RestrictionReason#d072acb4 platform:string reason:string text:string
    if (constructor == 0xd072acb4) {
        let _ = d.readString() // platform
        let _ = d.readString() // reason
        let _ = d.readString() // text
        return
    }
    // Username#b4073647 flags:# editable:flags.0?true active:flags.1?true username:string
    if (constructor == 0xb4073647) {
        let _ = d.readInt32() // flags
        let _ = d.readString() // username
        return
    }
    // 其他未知类型 - 无法安全跳过，什么都不做
}

/**
 * 跳过 EmojiStatus
 *
 * emojiStatusEmpty#2de11aae (iOS dict[769727150])        — 无字段
 * emojiStatus#e7ff068a     (iOS dict[-402717046])        — flags:Int32 document_id:Int64 until?[flags.0]:Int32
 * emojiStatusCollectible#7184603b (iOS dict[1904500795]) — flags:Int32 collectible_id:Int64 document_id:Int64
 *                                                           title:String slug:String pattern_document_id:Int64
 *                                                           center_color:Int32 edge_color:Int32 pattern_color:Int32
 *                                                           text_color:Int32 until?[flags.0]:Int32
 * iOS Api6.swift:1431 parse_emojiStatus + :1450 parse_emojiStatusCollectible
 */
func skipEmojiStatus(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x2de11aae) {
        // emojiStatusEmpty#2de11aae — no fields
        return
    }
    if (constructor == 0xe7ff068a) {
        // emojiStatus#e7ff068a (iOS dict[-402717046])
        // flags:Int32 document_id:Int64 until?[flags.0]:Int32
        // NOTE: flags is FIRST (before documentId) — fixes HIGH-2 desync
        let flags = d.readInt32()   // flags (MUST read before document_id)
        let _ = d.readInt64()       // document_id
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // until?[flags.0]
        return
    }
    if (constructor == 0x7184603b) {
        // emojiStatusCollectible#7184603b (iOS dict[1904500795])
        // flags:Int32 collectible_id:Int64 document_id:Int64 title:String slug:String
        // pattern_document_id:Int64 center_color:Int32 edge_color:Int32 pattern_color:Int32
        // text_color:Int32 until?[flags.0]:Int32
        // iOS Api6.swift:1450 parse_emojiStatusCollectible
        let flags = d.readInt32()    // flags
        let _ = d.readInt64()        // collectible_id
        let _ = d.readInt64()        // document_id
        let _ = d.readString()       // title
        let _ = d.readString()       // slug
        let _ = d.readInt64()        // pattern_document_id
        let _ = d.readInt32()        // center_color
        let _ = d.readInt32()        // edge_color
        let _ = d.readInt32()        // pattern_color
        let _ = d.readInt32()        // text_color
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // until?[flags.0]
        return
    }
    // Unknown EmojiStatus variant — compat skip (flags:int32 + document_id:int64)
    Hilog.info(0, "CjTelegram", "[skipEmojiStatus] Unknown ctor: 0x${toHex32(constructor)}, attempting compat skip")
    let _ = d.readInt32()  // flags (compat)
    let _ = d.readInt64()  // document_id (compat)
}

/**
 * 跳过 RecentStory (boxed)
 * recentStory#711d692d flags:# max_id:flags.1?int
 * iOS Api23.swift:275 parse_recentStory
 */
func skipRecentStory(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor (0x711d692d)
    let flags = d.readInt32()
    if ((flags & 2) != 0) { let _ = d.readInt32() }  // max_id (flags bit 1)
}

/**
 * 跳过 PeerColor (boxed, with constructor)
 */
func skipPeerColor(d: TLDeserializer): Unit {
    let _ = parsePeerColorCollectibleId(d)
}

/**
 * 解析 PeerColor，并在 peerColorCollectible / inputPeerColorCollectible 两个变体中
 * 返回 collectibleId。普通 peerColor 返回 0。
 *
 * R-135 同类点扩展（非本轮 required_fix，见 TLResponses.cj 同函数族 required_fix 的交付说明）：
 * 新增 0xb8ea86a9 分支——PeerColor 联合类型的第三个真实构造子 inputPeerColorCollectible 此前
 * 未被处理，落入下面的 peerColor#b54b5acf 兜底分支，与 parsePeerColorValue() 曾经的缺口是同一份
 * 失效模式（未知 ctor 被当成 peerColor 解析）。inputPeerColorCollectible#b8ea86a9 的线格式
 * （iOS Api20.swift:1256-1266 parse_inputPeerColorCollectible）只有一个字段 collectibleId:long，
 * 且恰好就是本函数要返回的值，故直接读取并返回，不走兜底分支。
 */
func parsePeerColorCollectibleId(d: TLDeserializer): Int64 {
    let ctor = d.readUInt32()
    if (ctor == 0xb8ea86a9) {
        // inputPeerColorCollectible#b8ea86a9 collectible_id:long — 无 flags，唯一字段
        return d.readInt64()
    }
    if (ctor == 0xb9c0639a) {
        // peerColorCollectible#b9c0639a flags:# collectible_id:long gift_emoji_id:long
        // background_emoji_id:long accent_color:int colors:Vector<int>
        // dark_accent_color:flags.0?int dark_colors:flags.1?Vector<int>
        let flags = d.readInt32()
        let collectibleId = d.readInt64()
        let _ = d.readInt64()
        let _ = d.readInt64()
        let _ = d.readInt32()
        let colorsCtor = d.readUInt32()
        if (colorsCtor == TLConstructors.VECTOR) {
            let colorsCount = d.readInt32()
            for (_i in 0..Int64(colorsCount)) { let _ = d.readInt32() }
        }
        if ((flags & 1) != 0) { let _ = d.readInt32() }
        if ((flags & 2) != 0) {
            let darkCtor = d.readUInt32()
            if (darkCtor == TLConstructors.VECTOR) {
                let darkCount = d.readInt32()
                for (_i in 0..Int64(darkCount)) { let _ = d.readInt32() }
            }
        }
        return collectibleId
    }
    if (ctor == 0xb54b5acf) {
        // peerColor#b54b5acf flags:# color:flags.0?int background_emoji_id:flags.1?long
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt32() }
        if ((flags & 2) != 0) { let _ = d.readInt64() }
        return 0
    }
    // R-135: PeerColor 联合类型只注册了 3 个构造子（Api0.swift:839-841），三个显式 if
    // 均未命中说明遇到未知/损坏 ctor——不猜测线格式，记录后按保守默认值返回。
    Hilog.info(0, "CjTelegram", "[parsePeerColorCollectibleId] Unknown ctor: 0x${toHex32(ctor)}")
    return 0
}

/**
 * 解析 PeerColor(boxed)，返回该 PeerColor 承载的 color/accent_color 索引（TC-0402 #3 修法方向 1）。
 * 字节消费与上面 parsePeerColorCollectibleId 完全一致、逐字段同构（同一组构造子、同一读取顺序），
 * 仅把返回值从 collectibleId 换成 color/accent_color——不改变、不复用其调用点（:5632 附近的
 * collectibleColorId 用法继续走 parsePeerColorCollectibleId，本函数只服务 UserResponse 的
 * nameColorIndex/profileColorIndex）。
 *
 * R-135 required_fix：PeerColor 联合类型有三个真实构造子（Api0.swift:839-841），此前本函数只识别
 * peerColorCollectible#b9c0639a，第三个构造子 inputPeerColorCollectible#b8ea86a9 落入 peerColor
 * 兜底分支——把它唯一的 8 字节 collectibleId 字段拆开当 flags/color/background_emoji_id 读，消费
 * 字节数与其真实线格式不符，导致游标永久错位（后续 bot_active_users/bot_verification_icon/
 * send_paid_messages_stars 以及外层继续读的所有字段全部从错误偏移解释）。现按各自真实线格式分支：
 * - inputPeerColorCollectible#b8ea86a9：唯一字段 collectibleId:long（8 字节，无 flags）。iOS
 *   TelegramUser.swift:149-170 / :280-301 的穷尽 switch 对该 case 是 `case .inputPeerColorCollectible: break`
 *   ——不产出 nameColor，故这里只消费 8 字节、返回 None。
 * - peerColorCollectible#b9c0639a：返回 Some(accent_color)（普通 color 与 accent_color 在此场景
 *   下是同一语义槽位——报告"修法方向 1"允许 collectible 的扩展字段继续跳过，但 accent_color 必须落地）。
 * - peerColor#b54b5acf：flags.0 位若置位则返回 Some(color)，否则返回 None（该 PeerColor 只带
 *   background_emoji_id、未下发 color 索引，属合法的"该字段确实没有 color 值"而非"未解析"）。
 * 对应源侧 submodules/TelegramCore/Sources/ApiUtils/TelegramUser.swift:146-158
 * （apiUser.color -> nameColor = .preset(PeerNameColor(rawValue: color))）。
 *
 * D-191 required_fix：peerColorCollectible 分支的 accent_color 下游语义是 RGB 位模式（iOS
 * TelegramUser.swift:162 `UInt32(bitPattern: accentColor)`），不是可比较大小的有符号数值。改用
 * d.readUInt32() 取得位模式后，按 ByteUtils.bytesToInt32()（同文件同仓已有先例，见
 * core/mtproto/ByteUtils.cj:190-200）的两段式写法转回 Option<Int32> 字段——不能直接
 * `Int32(uint32Value)`，UInt32 > Int32.Max 时该构造子会抛 OverflowException（TLSerialization.cj:119
 * 注释同一陷阱）；这里手工按位模式做符号位判定+截断，二进制内容保持不变、不引入符号扩展错误。
 */
func parsePeerColorValue(d: TLDeserializer): Option<Int32> {
    let ctor = d.readUInt32()
    if (ctor == 0xb8ea86a9) {
        // inputPeerColorCollectible#b8ea86a9 collectible_id:long — 无 flags，唯一字段
        // 消费但不使用：该 ctor 下 iOS 源侧穷尽 switch 显式 break，不产出 nameColor/profileColor。
        let _ = d.readInt64()  // collectible_id
        return None
    }
    if (ctor == 0xb9c0639a) {
        // peerColorCollectible#b9c0639a flags:# collectible_id:long gift_emoji_id:long
        // background_emoji_id:long accent_color:int colors:Vector<int>
        // dark_accent_color:flags.0?int dark_colors:flags.1?Vector<int>
        let flags = d.readInt32()
        let _ = d.readInt64()  // collectible_id
        let _ = d.readInt64()  // gift_emoji_id
        let _ = d.readInt64()  // background_emoji_id
        // accent_color 下游语义是 RGB 位模式（D-191），按 UInt32 读取后位模式保持地转回 Int32。
        let accentColorBits = d.readUInt32()
        let accentColorU64 = Int64(accentColorBits)
        let accentColor: Int32 = if (accentColorU64 > 0x7FFFFFFF) {
            Int32(accentColorU64 - 0x100000000)
        } else {
            Int32(accentColorU64)
        }
        let colorsCtor = d.readUInt32()
        if (colorsCtor == TLConstructors.VECTOR) {
            let colorsCount = d.readInt32()
            for (_i in 0..Int64(colorsCount)) { let _ = d.readInt32() }
        }
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // dark_accent_color
        if ((flags & 2) != 0) {
            let darkCtor = d.readUInt32()
            if (darkCtor == TLConstructors.VECTOR) {
                let darkCount = d.readInt32()
                for (_i in 0..Int64(darkCount)) { let _ = d.readInt32() }
            }
        }
        return Some(accentColor)
    }
    if (ctor == 0xb54b5acf) {
        // peerColor#b54b5acf flags:# color:flags.0?int background_emoji_id:flags.1?long
        let flags = d.readInt32()
        var color: Option<Int32> = None
        if ((flags & 1) != 0) { color = Some(d.readInt32()) }
        if ((flags & 2) != 0) { let _ = d.readInt64() }  // background_emoji_id
        return color
    }
    // R-135: PeerColor 联合类型只注册了 3 个构造子（Api0.swift:839-841），三个显式 if
    // 均未命中说明遇到未知/损坏 ctor——不猜测线格式，记录后按保守默认值返回。
    Hilog.info(0, "CjTelegram", "[parsePeerColorValue] Unknown ctor: 0x${toHex32(ctor)}")
    return None
}

/**
 * 跳过 Vector<InputPeer>
 */
func skipVectorOfInputPeer(d: TLDeserializer): Unit {
    let vecCtor = d.readUInt32()
    if (vecCtor != TLConstructors.VECTOR) { return }
    let count = d.readInt32()
    for (_i in 0..Int64(count)) {
        skipInputPeer(d)
    }
}

/**
 * P2-101 r1: 解析 Vector<InputPeer>，返回 peer ID 列表
 *
 * iOS InputPeer 各 ctor（Api12.swift:388-467，dict 来自 Api0.swift:456-462）:
 *   inputPeerEmpty              #7f3b18ea — 无字段
 *   inputPeerSelf               #7da07ec9 — 无字段，表示当前用户（跳过，无静态 id）
 *   inputPeerUser               #dde8a54c — user_id:Int64 access_hash:Int64
 *   inputPeerChat               #35a95cb9 — chat_id:Int64
 *   inputPeerChannel            #27bcbbfc — channel_id:Int64 access_hash:Int64
 *   inputPeerChannelFromMessage #bd2a0840 — peer:InputPeer msg_id:Int32 channel_id:Int64
 *   inputPeerUserFromMessage    #a87b0a1c — peer:InputPeer msg_id:Int32 user_id:Int64
 */
func parseInputPeerVectorToIds(d: TLDeserializer): ArrayList<Int64> {
    let ids = ArrayList<Int64>()
    let vecCtor = d.readUInt32()
    if (vecCtor != TLConstructors.VECTOR) { return ids }
    let count = d.readInt32()
    for (_i in 0..Int64(count)) {
        let ctor = d.readUInt32()
        if (ctor == 0x7f3b18ea) {
            // inputPeerEmpty — no fields
        } else if (ctor == 0x7da07ec9) {
            // inputPeerSelf — no fields; current user (no static id available here)
        } else if (ctor == 0xdde8a54c) {
            // inputPeerUser — user_id:Int64 access_hash:Int64
            let userId = d.readInt64()
            let _ = d.readInt64()
            ids.add(userId)
        } else if (ctor == 0x35a95cb9) {
            // inputPeerChat — chat_id:Int64
            ids.add(d.readInt64())
        } else if (ctor == 0x27bcbbfc) {
            // inputPeerChannel — channel_id:Int64 access_hash:Int64
            let channelId = d.readInt64()
            let _ = d.readInt64()
            ids.add(channelId)
        } else if (ctor == 0xbd2a0840) {
            // inputPeerChannelFromMessage — peer:InputPeer msg_id:Int32 channel_id:Int64
            skipInputPeer(d)
            let _ = d.readInt32()
            ids.add(d.readInt64())
        } else if (ctor == 0xa87b0a1c) {
            // inputPeerUserFromMessage — peer:InputPeer msg_id:Int32 user_id:Int64
            skipInputPeer(d)
            let _ = d.readInt32()
            ids.add(d.readInt64())
        } else {
            Hilog.info(0, "CjTelegram", "[parseInputPeerVectorToIds] unknown ctor: 0x${toHex32(ctor)}")
        }
    }
    return ids
}

func parseInputPeerVector(d: TLDeserializer): ArrayList<ChatFolderPeer> {
    let peers = ArrayList<ChatFolderPeer>()
    let vecCtor = d.readUInt32()
    if (vecCtor != TLConstructors.VECTOR) { return peers }
    let count = d.readInt32()
    for (_i in 0..Int64(count)) {
        let ctor = d.readUInt32()
        let peer = ChatFolderPeer()
        if (ctor == 0xdde8a54c) {
            peer.peerType = "user"
            peer.id = d.readInt64()
            peer.accessHash = d.readInt64()
            peers.add(peer)
        } else if (ctor == 0x35a95cb9) {
            peer.peerType = "chat"
            peer.id = d.readInt64()
            peers.add(peer)
        } else if (ctor == 0x27bcbbfc) {
            peer.peerType = "channel"
            peer.id = d.readInt64()
            peer.accessHash = d.readInt64()
            peers.add(peer)
        } else if (ctor == 0x7f3b18ea || ctor == 0x7da07ec9) {
            // Empty/self have no payload and cannot be edited as an explicit list entry here.
        } else if (ctor == 0xbd2a0840) {
            skipInputPeer(d)
            let _ = d.readInt32()
            peer.peerType = "channel"
            peer.id = d.readInt64()
            peers.add(peer)
        } else if (ctor == 0xa87b0a1c) {
            skipInputPeer(d)
            let _ = d.readInt32()
            peer.peerType = "user"
            peer.id = d.readInt64()
            peers.add(peer)
        }
    }
    return peers
}

/**
 * 跳过 Vector<MessageEntity>
 */
func skipVectorOfMessageEntity(d: TLDeserializer): Unit {
    let vecCtor = d.readUInt32()
    if (vecCtor != TLConstructors.VECTOR) { return }
    let count = d.readInt32()
    for (_i in 0..Int64(count)) {
        skipMessageEntity(d)
    }
}

/**
 * 跳过 TextWithEntities
 */
func skipTextWithEntities(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor != 0x751f3146) {
        // 非 textWithEntities，尝试跳过：string + vector
        let _ = d.readString()
        skipVectorOfMessageEntity(d)
        return
    }
    let _ = d.readString() // text
    skipVectorOfMessageEntity(d)
}

/**
 * 跳过 TextWithEntities 的剩余部分（constructor 已读取且非 textWithEntities 时）
 */
func skipTextWithEntitiesRemainder(d: TLDeserializer): Unit {
    let _ = d.readString()
    skipVectorOfMessageEntity(d)
}

/**
 * 解析单个 DialogFilter 为 ChatFolder
 * dialogFilter#aa472651 flags:# ... id:int title:TextWithEntities emoticon:flags.25?string ...
 * dialogFilterDefault#363293ae（零字段构造子）——服务端表示隐式 All Chats（id==0）的方式，
 * 需与 ChatFoldersPage.applyLoadedFilters()/loadPersistedFolders() 中硬编码的 All Chats
 * 默认值（name="全部聊天", icon="💬", filterType="all"）保持一致，避免"缓存分支"与
 * "无缓存兜底分支"两处展示不一致（TC-0015 归因修复）。
 */
func parseDialogFilter(d: TLDeserializer): ChatFolder {
    let folder = ChatFolder()
    let constructor = d.readUInt32()
    if (constructor == 0x363293ae) { // dialogFilterDefault：零字段，无需额外 read()
        folder.id = 0
        folder.name = "全部聊天"
        folder.icon = "💬"
        folder.filterType = "all"
        return folder
    }
    let isShared = constructor == 0x96537bd7
    if (constructor != 0xaa472651 && !isShared) { return folder }
    folder.isShared = isShared
    folder.hasSharedLinks = isShared
    let flags = d.readInt32()
    // dialogFilter#aa472651 布尔位（telegram_api.tl:1314）：
    //   contacts:flags.0 non_contacts:flags.1 groups:flags.2 broadcasts:flags.3 bots:flags.4
    //   exclude_muted:flags.11 exclude_read:flags.12 exclude_archived:flags.13
    folder.includeContacts = (flags & (1 << 0)) != 0
    folder.includeNonContacts = (flags & (1 << 1)) != 0
    folder.includeGroups = (flags & (1 << 2)) != 0
    folder.includeChannels = (flags & (1 << 3)) != 0
    folder.includeBots = (flags & (1 << 4)) != 0
    folder.excludeMuted = (flags & (1 << 11)) != 0
    folder.excludeRead = (flags & (1 << 12)) != 0
    folder.excludeArchived = (flags & (1 << 13)) != 0
    folder.id = d.readInt32()
    // title: TextWithEntities
    let titleCtor = d.readUInt32()
    if (titleCtor == 0x751f3146) {
        folder.name = d.readString()
        skipVectorOfMessageEntity(d)
    } else {
        skipTextWithEntitiesRemainder(d)
    }
    if ((flags & (1 << 25)) != 0) {
        folder.icon = d.readString()
        folder.emoticon = folder.icon
    }
    if ((flags & (1 << 27)) != 0) {
        folder.color = d.readInt32()
        folder.hasColor = true
    }
    let pinnedPeerRefs = parseInputPeerVector(d)
    for (peer in pinnedPeerRefs) { folder.pinnedPeers.add(peer.id) }
    folder.includePeerRefs = parseInputPeerVector(d)
    if (!isShared) {
        folder.excludePeerRefs = parseInputPeerVector(d)
    }
    for (peer in folder.includePeerRefs) { folder.includePeers.add(peer.id) }
    for (peer in folder.excludePeerRefs) { folder.excludePeers.add(peer.id) }
    return folder
}

/**
 * 跳过 DialogFilter（当不需要解析时）
 */
func skipDialogFilter(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    let isShared = constructor == 0x96537bd7
    if (constructor != 0xaa472651 && !isShared) { return }
    let flags = d.readInt32()
    let _ = d.readInt32() // id
    skipTextWithEntities(d)  // title
    if ((flags & (1 << 25)) != 0) { let _ = d.readString() } // emoticon
    if ((flags & (1 << 27)) != 0) { let _ = d.readInt32() } // color
    skipVectorOfInputPeer(d)
    skipVectorOfInputPeer(d)
    if (!isShared) { skipVectorOfInputPeer(d) }
}

/**
 * messages.DialogFilters 响应
 * messages.dialogFilters#2ad93719 flags:# tags_enabled:flags.0?true filters:Vector<DialogFilter>
 */
public class DialogFiltersResponse {
    public var filters: ArrayList<ChatFolder> = ArrayList<ChatFolder>()
    public var tagsEnabled: Bool = false

    public static func deserialize(data: Array<Byte>): DialogFiltersResponse {
        let r = DialogFiltersResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()
        if (constructor != 0x2ad93719) { return r } // messages.dialogFilters
        let flags = d.readInt32()
        // `tags_enabled:flags.0?true` is encoded by the flag itself and has no
        // boxed Bool payload. Reading four bytes here consumes the vector ctor.
        if ((flags & 1) != 0) { r.tagsEnabled = true }
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let folder = parseDialogFilter(d)
                r.filters.add(folder)
            }
        }
        return r
    }
}

/**
 * messages.getSuggestedDialogFilters returns a bare Vector<DialogFilterSuggested>.
 * dialogFilterSuggested#77744d4a filter:DialogFilter description:string
 */
public class SuggestedDialogFiltersResponse {
    public var filters: ArrayList<ChatFolder> = ArrayList<ChatFolder>()

    public static func deserialize(data: Array<Byte>): SuggestedDialogFiltersResponse {
        let r = SuggestedDialogFiltersResponse()
        let d = TLDeserializer(data)
        if (d.readUInt32() != TLConstructors.VECTOR) { return r }
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            if (d.readUInt32() != 0x77744d4a) { return r }
            let folder = parseDialogFilter(d)
            folder.description = d.readString()
            r.filters.add(folder)
        }
        return r
    }
}

// ==================== Phase B: 联系人列表响应 ====================

/**
 * contacts.contacts 响应 — 联系人列表
 * 对应 TelegramHarmony TLResponses.ets
 */
public class ContactsContactsResponse {
    public var contactUserIds: ArrayList<Int64> = ArrayList<Int64>()
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()
    public var savedCount: Int32 = 0

    public static func deserialize(data: Array<Byte>): ContactsContactsResponse {
        let r = ContactsContactsResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()

        // contacts.contactsNotModified#b74ba9d2
        if (constructor == 0xb74ba9d2) {
            Hilog.info(0, "CjTelegram", "[ContactsResponse] contactsNotModified")
            return r
        }

        // contacts.contacts#eae87e42
        if (constructor == 0xeae87e42) {
            // contacts: Vector<Contact>
            let vecConst = d.readUInt32()
            if (vecConst == TLConstructors.VECTOR) {
                let count = d.readInt32()
                Hilog.info(0, "CjTelegram", "[ContactsResponse] Parsing ${count} contacts")
                for (_i in 0..Int64(count)) {
                    // contact#145ade0b user_id:long mutual:Bool
                    let _ = d.readUInt32()  // constructor
                    let userId = d.readInt64()
                    let _ = d.readUInt32()  // mutual (Bool boxed)
                    r.contactUserIds.add(userId)
                }
            }

            // saved_count
            r.savedCount = d.readInt32()

            // users: Vector<User>
            let usersVecConst = d.readUInt32()
            if (usersVecConst == TLConstructors.VECTOR) {
                let usersCount = d.readInt32()
                Hilog.info(0, "CjTelegram", "[ContactsResponse] Parsing ${usersCount} users")
                for (_i in 0..Int64(usersCount)) {
                    try {
                        r.users.add(UserResponse.deserializeBoxed(d))
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ContactsResponse] Error parsing user: ${e}")
                        break
                    }
                }
            }

            Hilog.info(0, "CjTelegram", "[ContactsResponse] Done: ${r.contactUserIds.size} contacts, ${r.users.size} users")
        }

        return r
    }
}

/**
 * contacts.found 响应 — 联系人搜索结果
 */
public class ContactsFoundResponse {
    // my_results / results 保留服务端顺序（iOS SearchPeers.swift _internal_searchPeers 按这两个
    // Peer 列表的顺序从 chats/users 取 peer，分别渲染为本地段与全局段）。
    public var myResults: ArrayList<PeerResponse> = ArrayList<PeerResponse>()
    public var results: ArrayList<PeerResponse> = ArrayList<PeerResponse>()
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()
    public var chats: ArrayList<ChatResponse> = ArrayList<ChatResponse>()

    public static func deserialize(data: Array<Byte>): ContactsFoundResponse {
        let r = ContactsFoundResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()

        // contacts.found#b3134d9d my_results:Vector<Peer> results:Vector<Peer> chats:Vector<Chat> users:Vector<User>
        if (constructor == 0xb3134d9d) {
            // my_results: Vector<Peer>
            let myVec = d.readUInt32()
            if (myVec == TLConstructors.VECTOR) {
                let myCount = d.readInt32()
                for (_i in 0..Int64(myCount)) {
                    r.myResults.add(PeerResponse.deserializeBoxed(d))
                }
            }
            // results: Vector<Peer>
            let resVec = d.readUInt32()
            if (resVec == TLConstructors.VECTOR) {
                let resCount = d.readInt32()
                for (_i in 0..Int64(resCount)) {
                    r.results.add(PeerResponse.deserializeBoxed(d))
                }
            }
            // chats: Vector<Chat>
            let chatsVec = d.readUInt32()
            if (chatsVec == TLConstructors.VECTOR) {
                let chatsCount = d.readInt32()
                for (_i in 0..Int64(chatsCount)) {
                    try { r.chats.add(ChatResponse.deserializeBoxed(d)) } catch (_e: Exception) { break }
                }
            }
            // users: Vector<User>
            let usersVec = d.readUInt32()
            if (usersVec == TLConstructors.VECTOR) {
                let usersCount = d.readInt32()
                for (_i in 0..Int64(usersCount)) {
                    try { r.users.add(UserResponse.deserializeBoxed(d)) } catch (_e: Exception) { break }
                }
            }
        }

        return r
    }
}

// ==================== 联系人导入响应 ====================

/**
 * contacts.importedContacts 响应
 * 返回导入结果，包含已注册 Telegram 的用户列表
 */
public class ContactsImportedContactsResponse {
    public var importedCount: Int32 = 0
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()
    public var retryContacts: ArrayList<Int64> = ArrayList<Int64>()

    public static func deserialize(data: Array<Byte>): ContactsImportedContactsResponse {
        let r = ContactsImportedContactsResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()

        // contacts.importedContacts#77d01c3b
        if (constructor == 0x77d01c3b) {
            // imported: Vector<ImportedContact>
            let impVec = d.readUInt32()
            if (impVec == TLConstructors.VECTOR) {
                let impCount = d.readInt32()
                r.importedCount = impCount
                for (_i in 0..Int64(impCount)) {
                    // importedContact#c13e3c50 user_id:long client_id:long
                    let _ = d.readUInt32()  // constructor
                    let _ = d.readInt64()   // user_id
                    let _ = d.readInt64()   // client_id
                }
            }

            // popular_invites: Vector<PopularContact>
            let popVec = d.readUInt32()
            if (popVec == TLConstructors.VECTOR) {
                let popCount = d.readInt32()
                for (_i in 0..Int64(popCount)) {
                    // popularContact#5ce14175 client_id:long importers:int
                    let _ = d.readUInt32()  // constructor
                    let _ = d.readInt64()   // client_id
                    let _ = d.readInt32()   // importers
                }
            }

            // retry_contacts: Vector<long>
            let retryVec = d.readUInt32()
            if (retryVec == TLConstructors.VECTOR) {
                let retryCount = d.readInt32()
                for (_i in 0..Int64(retryCount)) {
                    r.retryContacts.add(d.readInt64())
                }
            }

            // users: Vector<User>
            let usersVec = d.readUInt32()
            if (usersVec == TLConstructors.VECTOR) {
                let usersCount = d.readInt32()
                for (_i in 0..Int64(usersCount)) {
                    try {
                        r.users.add(UserResponse.deserializeBoxed(d))
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ImportedContacts] Error parsing user: ${e}")
                        break
                    }
                }
            }

            Hilog.info(0, "CjTelegram", "[ImportedContacts] imported=${r.importedCount}, users=${r.users.size}")
        }

        return r
    }
}

// ==================== P2-157b: Top Peers 响应 ====================

/**
 * 单个 TopPeer wire 条目
 * topPeer#edcdc05b peer:Peer rating:double = TopPeer
 * 注意：peer 字段是 boxed Peer（peerUser/peerChat/peerChannel），不预先读 constructor。
 */
public class TopPeerEntry {
    public var peerType: String = "user"  // "user", "chat", "channel"
    public var peerId: Int64 = 0
    public var rating: Float64 = 0.0
}

/**
 * contacts.topPeers 完整响应（P2-157b）
 *
 * 三个可能 constructor：
 *   contacts.topPeersNotModified#de266ef5 — 无字段，表示服务端缓存未变
 *   contacts.topPeersDisabled#b52c939d    — 无字段，表示 top peers 功能被禁用
 *   contacts.topPeers#70b772a8            — categories:Vector<TopPeerCategoryPeers>
 *                                            chats:Vector<Chat> users:Vector<User>
 *
 * categories → TopPeerCategoryPeers:
 *   topPeerCategoryPeers#fb834291 category:TopPeerCategory count:int peers:Vector<TopPeer>
 *
 * TopPeerCategory 各 constructor（无字段，只有 constructor id）
 *   correspondents#0637b7ed, groups#bd17a14a, channels#161d9628, bots_pm#ab661b5b, 等
 */
public class ContactsTopPeersResponse {
    public var notModified: Bool = false
    public var disabled: Bool = false
    public var peers: ArrayList<TopPeerEntry> = ArrayList<TopPeerEntry>()
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()

    public static func deserialize(data: Array<Byte>): ContactsTopPeersResponse {
        let r = ContactsTopPeersResponse()
        if (data.size < 4) {
            return r
        }
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()

        if (constructor == 0xde266ef5) {
            r.notModified = true
            Hilog.info(0, "CjTelegram", "[TopPeers] not modified")
            return r
        }

        if (constructor == 0xb52c939d) {
            r.disabled = true
            Hilog.info(0, "CjTelegram", "[TopPeers] disabled")
            return r
        }

        if (constructor != 0x70b772a8) {
            Hilog.info(0, "CjTelegram", "[TopPeers] unknown constructor: ${constructor}")
            return r
        }

        // contacts.topPeers#70b772a8 categories:Vector<TopPeerCategoryPeers> chats:Vector<Chat> users:Vector<User>

        // --- categories: Vector<TopPeerCategoryPeers> ---
        let catVecCtor = d.readUInt32()
        if (catVecCtor == TLConstructors.VECTOR) {
            let catCount = d.readInt32()
            var catIdx: Int64 = 0
            while (catIdx < Int64(catCount)) {
                catIdx = catIdx + 1
                // topPeerCategoryPeers#fb834291 category:TopPeerCategory count:int peers:Vector<TopPeer>
                let catPeersCtor = d.readUInt32()
                if (catPeersCtor != 0xfb834291) {
                    Hilog.info(0, "CjTelegram", "[TopPeers] unexpected catPeers ctor ${catPeersCtor}, skipping rest")
                    return r
                }
                // category: TopPeerCategory — one of many box constructors, all have no fields
                let _ = d.readUInt32()  // TopPeerCategory constructor (no fields)
                let _ = d.readInt32()   // count:int (total count hint from server)
                // peers: Vector<TopPeer>
                let peersVecCtor = d.readUInt32()
                if (peersVecCtor == TLConstructors.VECTOR) {
                    let peersCount = d.readInt32()
                    var pIdx: Int64 = 0
                    while (pIdx < Int64(peersCount)) {
                        pIdx = pIdx + 1
                        // topPeer#edcdc05b peer:Peer rating:double
                        let topPeerCtor = d.readUInt32()
                        if (topPeerCtor != 0xedcdc05b) {
                            Hilog.info(0, "CjTelegram", "[TopPeers] unexpected topPeer ctor ${topPeerCtor}")
                            return r
                        }
                        let entry = TopPeerEntry()
                        // peer: Peer (boxed) — peerUser/peerChat/peerChannel, each has one Int64 id
                        let peerCtor = d.readUInt32()
                        entry.peerId = d.readInt64()
                        if (peerCtor == 0x59511722) {
                            entry.peerType = "user"
                        } else if (peerCtor == 0x36c6019a) {
                            entry.peerType = "chat"
                        } else if (peerCtor == 0xa2a5371e) {
                            entry.peerType = "channel"
                        } else {
                            entry.peerType = "user"
                        }
                        // rating: double (8 bytes IEEE 754 little-endian)
                        entry.rating = d.readDouble()
                        r.peers.add(entry)
                    }
                }
            }
        }

        // --- chats: Vector<Chat> — parse and skip (only need users for ContactDisplayData) ---
        let chatsVecCtor = d.readUInt32()
        if (chatsVecCtor == TLConstructors.VECTOR) {
            let chatsCount = d.readInt32()
            var chIdx: Int64 = 0
            while (chIdx < Int64(chatsCount)) {
                chIdx = chIdx + 1
                let _ = ChatResponse.deserializeBoxed(d)
            }
        }

        // --- users: Vector<User> ---
        let usersVecCtor = d.readUInt32()
        if (usersVecCtor == TLConstructors.VECTOR) {
            let usersCount = d.readInt32()
            var uIdx: Int64 = 0
            while (uIdx < Int64(usersCount)) {
                uIdx = uIdx + 1
                try {
                    r.users.add(UserResponse.deserializeBoxed(d))
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TopPeers] error parsing user: ${e}")
                    break
                }
            }
        }

        Hilog.info(0, "CjTelegram", "[TopPeers] parsed: peers=${r.peers.size} users=${r.users.size}")
        return r
    }
}

// ==================== Phase K: 通话响应 ====================

/**
 * 通话连接信息
 */
public class PhoneConnectionResponse {
    public var id: Int64 = 0
    public var ip: String = ""
    public var ipv6: String = ""
    public var port: Int32 = 0
    public var peerTag: Array<Byte> = Array<Byte>(0, repeat: 0)
    // WebRTC fields
    public var isWebrtc: Bool = false
    public var username: String = ""
    public var password: String = ""
    public var turn: Bool = false
    public var stun: Bool = false
}

/**
 * 通话响应 — phone.PhoneCall wrapper
 * 包含 phoneCall* 对象 + users vector
 */
public class PhoneCallResponse {
    // 通话状态类型
    public var callType: String = "empty"  // empty, waiting, requested, accepted, active, discarded

    // 通话基本信息
    public var callId: Int64 = 0
    public var accessHash: Int64 = 0
    public var date: Int32 = 0
    public var adminId: Int64 = 0   // 发起方
    public var participantId: Int64 = 0  // 接听方
    public var isVideo: Bool = false

    // DH 数据
    public var gAHash: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var gA: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var gB: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var keyFingerprint: Int64 = 0

    // 连接信息 (active 状态)
    public var connections: ArrayList<PhoneConnectionResponse> = ArrayList<PhoneConnectionResponse>()

    // 协议信息
    public var minLayer: Int32 = 0
    public var maxLayer: Int32 = 0
    // 版本协商：accepted/active 携带的 protocol.library_versions（对端/服务器回显的协商结果）
    public var libraryVersions: ArrayList<String> = ArrayList<String>()

    // 结束信息 (discarded 状态)
    public var discardReason: String = ""  // hangup, busy, disconnect, missed
    public var duration: Int32 = 0
    public var needRating: Bool = false
    public var needDebug: Bool = false

    // 收到时间 (waiting 状态)
    public var receiveDate: Int32 = 0

    // users
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()

    /**
     * 解析 phone.phoneCall 响应
     * phone.phoneCall#ec82e140 phone_call:PhoneCall users:Vector<User>
     */
    public static func deserialize(data: Array<Byte>): PhoneCallResponse {
        let r = PhoneCallResponse()
        let d = TLDeserializer(data)
        let outerConstructor = d.readUInt32()

        // phone.phoneCall#ec82e140
        if (outerConstructor == 0xec82e140) {
            // phoneCall 对象 (boxed)
            parsePhoneCall(d, r)

            // users vector
            let usersVec = d.readUInt32()
            if (usersVec == TLConstructors.VECTOR) {
                let usersCount = d.readInt32()
                for (_i in 0..Int64(usersCount)) {
                    try {
                        r.users.add(UserResponse.deserializeBoxed(d))
                    } catch (_e: Exception) {
                        break
                    }
                }
            }
        }

        return r
    }
}

/**
 * 解析 phoneCall 对象（boxed，带 constructor）
 */
func parsePhoneCall(d: TLDeserializer, r: PhoneCallResponse): Unit {
    let constructor = d.readUInt32()

    if (constructor == 0x5366c915) {
        // phoneCallEmpty#5366c915 id:long
        r.callType = "empty"
        r.callId = d.readInt64()
    } else if (constructor == 0xc5226f17) {
        // phoneCallWaiting#c5226f17 flags:# video:flags.6 id:long access_hash:long date:int
        //   admin_id:long participant_id:long protocol:PhoneCallProtocol receive_date:flags.0?int
        r.callType = "waiting"
        let flags = d.readInt32()
        r.isVideo = (flags & (1 << 6)) != 0
        r.callId = d.readInt64()
        r.accessHash = d.readInt64()
        r.date = d.readInt32()
        r.adminId = d.readInt64()
        r.participantId = d.readInt64()
        // skip protocol
        skipPhoneCallProtocol(d)
        if ((flags & 1) != 0) {
            r.receiveDate = d.readInt32()
        }
    } else if (constructor == 0x14b0ed0c) {
        // phoneCallRequested#14b0ed0c flags:# video:flags.6 id:long access_hash:long date:int
        //   admin_id:long participant_id:long g_a_hash:bytes protocol:PhoneCallProtocol
        r.callType = "requested"
        let flags = d.readInt32()
        r.isVideo = (flags & (1 << 6)) != 0
        r.callId = d.readInt64()
        r.accessHash = d.readInt64()
        r.date = d.readInt32()
        r.adminId = d.readInt64()
        r.participantId = d.readInt64()
        r.gAHash = d.readBytes()
        skipPhoneCallProtocol(d)
    } else if (constructor == 0x3660c311) {
        // phoneCallAccepted#3660c311 flags:# video:flags.6 id:long access_hash:long date:int
        //   admin_id:long participant_id:long g_b:bytes protocol:PhoneCallProtocol
        r.callType = "accepted"
        let flags = d.readInt32()
        r.isVideo = (flags & (1 << 6)) != 0
        r.callId = d.readInt64()
        r.accessHash = d.readInt64()
        r.date = d.readInt32()
        r.adminId = d.readInt64()
        r.participantId = d.readInt64()
        r.gB = d.readBytes()
        parsePhoneCallProtocolInto(d, r)
    } else if (constructor == 0x30535AF5 || constructor == 0x967f7c67) {
        // phoneCall#30535af5 (current layer) / phoneCall#967f7c67 (legacy)
        // flags:# p2p_allowed:flags.5 video:flags.6 id:long access_hash:long
        //   date:int admin_id:long participant_id:long g_a_or_b:bytes key_fingerprint:long
        //   protocol:PhoneCallProtocol connections:Vector<PhoneConnection> start_date:int
        //   custom_parameters:flags.7?DataJSON  (新增字段, 仅 0x30535AF5)
        r.callType = "active"
        let flags = d.readInt32()
        r.isVideo = (flags & (1 << 6)) != 0
        r.callId = d.readInt64()
        r.accessHash = d.readInt64()
        r.date = d.readInt32()
        r.adminId = d.readInt64()
        r.participantId = d.readInt64()
        r.gA = d.readBytes()  // g_a_or_b
        r.keyFingerprint = d.readInt64()
        parsePhoneCallProtocolInto(d, r)
        // connections vector
        let connVec = d.readUInt32()
        if (connVec == TLConstructors.VECTOR) {
            let connCount = d.readInt32()
            for (_i in 0..Int64(connCount)) {
                r.connections.add(parsePhoneConnection(d))
            }
        }
        // start_date:int
        try { let _ = d.readInt32() } catch (_: Exception) {}
        // custom_parameters:flags.7?DataJSON (仅 0x30535AF5)
        if (constructor == 0x30535AF5 && (flags & (1 << 7)) != 0) {
            try {
                let _ = d.readUInt32()  // dataJSON constructor
                let _ = d.readString()  // data string
            } catch (_: Exception) {}
        }
    } else if (constructor == 0x50ca4de1) {
        // phoneCallDiscarded#50ca4de1 flags:# need_rating:flags.2 need_debug:flags.3
        //   video:flags.6 id:long reason:flags.0?PhoneCallDiscardReason duration:flags.1?int
        r.callType = "discarded"
        let flags = d.readInt32()
        r.needRating = (flags & (1 << 2)) != 0
        r.needDebug = (flags & (1 << 3)) != 0
        r.isVideo = (flags & (1 << 6)) != 0
        r.callId = d.readInt64()
        if ((flags & 1) != 0) {
            let reasonConstructor = d.readUInt32()
            r.discardReason = parseDiscardReason(reasonConstructor)
        }
        if ((flags & 2) != 0) {
            r.duration = d.readInt32()
        }
    }
}

/**
 * 解析 PhoneConnection
 */
func parsePhoneConnection(d: TLDeserializer): PhoneConnectionResponse {
    let conn = PhoneConnectionResponse()
    let constructor = d.readUInt32()

    if (constructor == 0x9cc123c7) {
        // phoneConnection#9cc123c7 flags:# tcp:flags.0 id:long ip:string ipv6:string port:int peer_tag:bytes
        let flags = d.readInt32()
        let _ = flags
        conn.id = d.readInt64()
        conn.ip = d.readString()
        conn.ipv6 = d.readString()
        conn.port = d.readInt32()
        conn.peerTag = d.readBytes()
    } else if (constructor == 0x635fe375) {
        // phoneConnectionWebrtc#635fe375 flags:# turn:flags.0 stun:flags.1
        //   id:long ip:string ipv6:string port:int username:string password:string
        let flags = d.readInt32()
        conn.isWebrtc = true
        conn.turn = (flags & 1) != 0
        conn.stun = (flags & 2) != 0
        conn.id = d.readInt64()

        // === DIAGNOSTIC: dump raw hex at ip field position ===
        let ipOffset = d.getOffset()
        let ipHex = d.dumpHex(64)  // dump 64 bytes from current position
        Hilog.info(0, "CjTelegram", "[parsePhoneConnection] WebRTC id=${conn.id} flags=${flags}")
        Hilog.info(0, "CjTelegram", "[parsePhoneConnection] ip starts at offset=${ipOffset}, hex: ${ipHex}")

        conn.ip = d.readString()
        let ipv6Offset = d.getOffset()
        Hilog.info(0, "CjTelegram", "[parsePhoneConnection] ip='${conn.ip}' (${conn.ip.size} chars), next offset=${ipv6Offset}")

        conn.ipv6 = d.readString()
        let portOffset = d.getOffset()
        Hilog.info(0, "CjTelegram", "[parsePhoneConnection] ipv6='${conn.ipv6}' (${conn.ipv6.size} chars), next offset=${portOffset}")

        conn.port = d.readInt32()
        Hilog.info(0, "CjTelegram", "[parsePhoneConnection] port=${conn.port}")

        conn.username = d.readString()
        Hilog.info(0, "CjTelegram", "[parsePhoneConnection] username='${conn.username}' (${conn.username.size} chars)")

        conn.password = d.readString()
        Hilog.info(0, "CjTelegram", "[parsePhoneConnection] password='${conn.password.size} chars'")
    } else {
        Hilog.info(0, "CjTelegram", "[parsePhoneConnection] UNKNOWN constructor=${constructor}")
    }

    return conn
}

/**
 * 跳过 PhoneCallProtocol
 */
func skipPhoneCallProtocol(d: TLDeserializer): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0xfc878fc8) {
        let _ = d.readInt32()  // flags
        let _ = d.readInt32()  // min_layer
        let _ = d.readInt32()  // max_layer
        // library_versions vector
        let vecConstructor = d.readUInt32()
        if (vecConstructor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let _ = d.readString()
            }
        }
    }
}

/**
 * 解析 PhoneCallProtocol 并把 min/max layer 与 library_versions 存入 response。
 * 版本协商修复：accepted/active 里的 versions 是对端选定的协商结果，
 * 引擎必须跑它——此前用 skipPhoneCallProtocol 全部丢弃（同 codeLength 旧病）。
 * 读取推进量与 skip 完全一致，不影响后续字段（connections 等）解析。
 */
func parsePhoneCallProtocolInto(d: TLDeserializer, r: PhoneCallResponse): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0xfc878fc8) {
        let _ = d.readInt32()  // flags
        r.minLayer = d.readInt32()
        r.maxLayer = d.readInt32()
        let vecConstructor = d.readUInt32()
        if (vecConstructor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                r.libraryVersions.add(d.readString())
            }
        }
    }
}

/**
 * 解析通话结束原因
 */
func parseDiscardReason(constructor: UInt32): String {
    if (constructor == 0x85e42301) { return "missed" }
    if (constructor == 0xe095c1a0) { return "disconnect" }
    if (constructor == 0xfaf7e8c9) { return "busy" }
    return "hangup"  // 0x57adc690
}

// ==================== 联系人响应（已有）====================

public class ContactsResolvedPeerResponse {
    public var peer: PeerResponse = PeerResponse()
    public var chats: ArrayList<ChatResponse> = ArrayList<ChatResponse>()
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()

    public static func deserialize(data: Array<Byte>): ContactsResolvedPeerResponse {
        let r = ContactsResolvedPeerResponse()
        let d = TLDeserializer(data)
        let _ = d.readUInt32() // constructor
        r.peer = PeerResponse.deserializeBoxed(d)

        // chats vector
        let _ = d.readUInt32() // vector
        let chatsCount = d.readInt32()
        for (_i in 0..Int64(chatsCount)) {
            r.chats.add(ChatResponse.deserializeBoxed(d))
        }

        // users vector
        let _ = d.readUInt32() // vector
        let usersCount = d.readInt32()
        for (_i in 0..Int64(usersCount)) {
            r.users.add(UserResponse.deserializeBoxed(d))
        }

        return r
    }
}

// ==================== DH Config Response ====================

/**
 * messages.DhConfig 响应
 * 
 * messages.dhConfig#2c221edd g:int p:bytes version:int random:bytes
 * messages.dhConfigNotModified#c0e24635 random:bytes
 */
public class DhConfigResponse {
    public var g: Int32 = 0
    public var p: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var version: Int32 = 0
    public var random: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var isModified: Bool = false

    public static func deserialize(data: Array<Byte>): DhConfigResponse {
        let r = DhConfigResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()

        if (constructor == 0x2c221edd) {
            // messages.dhConfig
            r.isModified = true
            r.g = d.readInt32()
            r.p = d.readBytes()
            r.version = d.readInt32()
            r.random = d.readBytes()
        } else if (constructor == 0xc0e24635) {
            // messages.dhConfigNotModified
            r.isModified = false
            r.random = d.readBytes()
        }

        return r
    }
}

// ==================== Updates State Response ====================

/**
 * updates.state#a56c2a3e pts:int qts:int date:int seq:int unread_count:int
 */
public class UpdatesStateResponse {
    public var pts: Int32 = 0
    public var qts: Int32 = 0
    public var date: Int32 = 0
    public var seq: Int32 = 0
    public var unreadCount: Int32 = 0

    public static func deserialize(data: Array<Byte>): UpdatesStateResponse {
        let r = UpdatesStateResponse()
        if (data.size < 4) { return r }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == 0xa56c2a3e) {
            r.pts = d.readInt32()
            r.qts = d.readInt32()
            r.date = d.readInt32()
            r.seq = d.readInt32()
            r.unreadCount = d.readInt32()
        }
        return r
    }
}

// ==================== Phase R2: Updates Difference Response ====================

/**
 * updates.differenceEmpty#5d75a138 date:int seq:int
 * updates.difference#00f49d63 new_messages:Vector<Message> new_encrypted_messages:Vector<EncryptedMessage>
 *   other_updates:Vector<Update> chats:Vector<Chat> users:Vector<User> state:updates.State
 * updates.differenceSlice#a8fb1981 (same as difference but with intermediate_state)
 * updates.differenceTooLong#4afe8f6d pts:int
 *
 * 解析 getDifference 的响应，提取新消息和更新后的同步状态。
 */
/**
 * updates.difference 的 other_updates 里带回的已读水位。
 *
 * iOS 把 difference 的 other_updates 与实时 update 走同一条应用链
 * （AccountStateManagementUtils.swift 对两者都调 updatedState.readOutbox/readInbox），
 * 所以补差期间对方的已读回执不会丢。我们此前整段跳过 other_updates，
 * 补差窗口内的已读回执就无处可取。
 */
public class DifferenceReadState {
    public var peerType: String = ""
    public var peerId: Int64 = 0
    public var maxId: Int32 = 0
    public var stillUnread: Int32 = 0
    /** true = updateReadHistoryOutbox（对方读了我发的）；false = updateReadHistoryInbox */
    public var outgoing: Bool = false

    public init() {}
}

public class UpdatesDifferenceResponse {
    // 响应类型
    public var responseType: String = "unknown"  // "empty", "difference", "differenceSlice", "differenceTooLong"
    
    // 新消息 (TLMessage 列表)
    public var newMessages: ArrayList<TLMessage> = ArrayList<TLMessage>()

    // other_updates 里解析出的已读水位
    public var readStates: ArrayList<DifferenceReadState> = ArrayList<DifferenceReadState>()

    // other_updates 里 updateDeleteMessages 带回的（账号全局）消息 id
    public var deletedMessageIds: ArrayList<Int32> = ArrayList<Int32>()

    // 顺序解析是否在 other_updates 处被未知构造器截断（截断后 chats/users 不可信）
    public var otherUpdatesTruncated: Bool = false
    
    // 用户和聊天缓存
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()
    public var chats: ArrayList<ChatResponse> = ArrayList<ChatResponse>()
    
    // 更新后的同步状态
    public var pts: Int32 = 0
    public var qts: Int32 = 0
    public var date: Int32 = 0
    public var seq: Int32 = 0
    
    // 是否还有更多差异需要拉取 (differenceSlice)
    public var hasMore: Bool = false
    
    // differenceTooLong 时的 pts
    public var tooLongPts: Int32 = 0

    public static func deserialize(data: Array<Byte>): UpdatesDifferenceResponse {
        let r = UpdatesDifferenceResponse()
        if (data.size < 4) { return r }
        let d = TLDeserializer(data)
        
        // 可能包裹在 gzip 或 rpc_result 中，直接读构造器
        let ctor = d.readUInt32()
        
        // differenceEmpty
        if (ctor == 0x5d75a138) {
            r.responseType = "empty"
            r.date = d.readInt32()
            r.seq = d.readInt32()
            return r
        }
        
        // differenceTooLong
        if (ctor == 0x4afe8f6d) {
            r.responseType = "differenceTooLong"
            r.tooLongPts = d.readInt32()
            r.pts = r.tooLongPts
            return r
        }
        
        // difference or differenceSlice
        // iOS dict[16030880]=0x00f49ca0 (current layer); 0x00f49d63 kept for compat
        if (ctor == 0x00f49ca0 || ctor == 0x00f49d63 || ctor == 0xa8fb1981) {
            r.responseType = if (ctor == 0x00f49ca0 || ctor == 0x00f49d63) { "difference" } else { "differenceSlice" }
            r.hasMore = (ctor == 0xa8fb1981)
            
            // new_messages: Vector<Message>
            let msgVecCtor = d.readUInt32()
            if (msgVecCtor == TLConstructors.VECTOR) {
                let msgCount = d.readInt32()
                for (_i in 0..Int64(msgCount)) {
                    let msg = TLMessage.deserializeBoxed(d)
                    if (msg.id != 0) {
                        r.newMessages.add(msg)
                    }
                }
            }
            
            // new_encrypted_messages: Vector<EncryptedMessage> — 跳过
            let encVecCtor = d.readUInt32()
            if (encVecCtor == TLConstructors.VECTOR) {
                let encCount = d.readInt32()
                for (_i in 0..Int64(encCount)) {
                    // 跳过 EncryptedMessage — 先读构造器判断大小
                    skipEncryptedMessage(d)
                }
            }
            
            // other_updates: Vector<Update>
            //
            // 此前这里对每个元素调 skipUpdate，而 skipUpdate 遇到未知构造器是
            // **直接 return、不消费 body** —— TL 变长编码下这等于让游标就地失效，
            // 后面的 chats / users / state 全部读成垃圾（真机表现：32 条消息却解析出
            // 0 个 user，末尾的 updates.State 也读不到 → pts 恒为 0 → 同步状态永不推进）。
            //
            // 改为：能认出来的就完整消费（顺带把已读水位取出来交给状态机应用，
            // 对齐 iOS 把 other_updates 与实时 update 走同一条应用链），
            // 一旦遇到不认识的类型立即停止顺序解析并标记 —— 后续字段一律不再尝试读，
            // state 交由尾部定长解析兜底。
            let updVecCtor = d.readUInt32()
            if (updVecCtor == TLConstructors.VECTOR) {
                let updCount = d.readInt32()
                for (_i in 0..Int64(updCount)) {
                    if (!parseDifferenceUpdate(d, r)) {
                        r.otherUpdatesTruncated = true
                        break
                    }
                }
            } else {
                r.otherUpdatesTruncated = true
            }

            if (r.otherUpdatesTruncated) {
                Hilog.info(0, "CjTelegram",
                    "[Difference] other_updates truncated at unknown ctor; chats/users skipped, state read from tail")
                r.parseTrailingState(data)
                return r
            }

            // chats: Vector<Chat>
            let chatVecCtor = d.readUInt32()
            if (chatVecCtor == TLConstructors.VECTOR) {
                let chatCount = d.readInt32()
                for (_i in 0..Int64(chatCount)) {
                    let chat = ChatResponse.deserializeBoxed(d)
                    r.chats.add(chat)
                }
            }
            
            // users: Vector<User>
            let userVecCtor = d.readUInt32()
            if (userVecCtor == TLConstructors.VECTOR) {
                let userCount = d.readInt32()
                for (_i in 0..Int64(userCount)) {
                    let user = UserResponse.deserializeBoxed(d)
                    r.users.add(user)
                }
            }
            
            // state / intermediate_state: updates.State
            let stateCtor = d.readUInt32()
            if (stateCtor == 0xa56c2a3e) {
                r.pts = d.readInt32()
                r.qts = d.readInt32()
                r.date = d.readInt32()
                r.seq = d.readInt32()
                let _ = d.readInt32()  // unread_count
            } else {
                // 顺序解析没落到 state 上 —— 中段的 skipEncryptedMessage / skipUpdate /
                // Chat / User 只要与服务端当前 layer 有一处对不上，游标就错位，
                // 后面的字段全部读废。
                //
                // 后果极其严重且不显眼：pts 保持 0 → fetchDifference 的
                // `if (diff.pts > 0)` 不成立 → 同步状态永不推进 → 之后每一条实时
                // update 都被 checkAndUpdatePts 判成 gap 丢弃、再触发一次 getDifference，
                // 形成「反复全量补差但永远补不上」的死循环。真机实测：pts 卡在 802、
                // 服务端已到 877，updateReadHistoryOutbox 一次都没进来，
                // 表现为已读双勾只能靠会话列表刷新兜底、最新一条永远不变。
                //
                // updates.State 恒为本响应的**最后一个字段**且定长：
                //   updates.state#a56c2a3e pts:int qts:int date:int seq:int unread_count:int
                // = 4 + 5*4 = 24 字节。直接从尾部取，绕开中段解析的不确定性。
                r.parseTrailingState(data)
            }
            
            return r
        }
        
        return r
    }

    /**
     * 从响应尾部直接取 updates.State（定长 24 字节，恒为最后一个字段）。
     * 仅在顺序解析未能落到 state 时兜底；ctor 不匹配则保持 pts=0 不动，
     * 让调用方沿用旧状态而不是写入一个错误的 pts。
     */
    private func parseTrailingState(data: Array<Byte>): Unit {
        let stateSize: Int64 = 24
        if (data.size < stateSize) { return }
        let tail = Array<Byte>(stateSize, repeat: 0)
        for (i in 0..stateSize) {
            tail[i] = data[data.size - stateSize + i]
        }
        let td = TLDeserializer(tail)
        if (td.readUInt32() != 0xa56c2a3e) {
            Hilog.info(0, "CjTelegram", "[Difference] trailing state ctor mismatch, sync state left unchanged")
            return
        }
        this.pts = td.readInt32()
        this.qts = td.readInt32()
        this.date = td.readInt32()
        this.seq = td.readInt32()
        Hilog.info(0, "CjTelegram",
            "[Difference] recovered state from tail: pts=${this.pts}, qts=${this.qts}, date=${this.date}, seq=${this.seq}")
    }
}

// ==================== P2-090: messages.migrateChat Updates 解析 ====================

/**
 * messages.migrateChat 返回 Updates，其中 chats[] 包含新建的 supergroup Channel。
 * 本函数从 Updates 中提取新 Channel 的 (channelId, accessHash)。
 *
 * TL schema 四变体:
 *   updates#74ae4240         updates:Vector<Update> users:Vector<User> chats:Vector<Chat> date:int seq:int
 *   updatesCombined#725b04c3 updates:Vector<Update> users:Vector<User> chats:Vector<Chat> date:int seq_start:int seq:int
 *   updateShort#78d4dec1     update:Update date:int
 *   updatesTooLong#e317af7e  (no fields)
 *
 * skipUpdate 已支持 updateChannel#635b4c09 channel_id:long（migrateChat 返回的主要 update 类型）。
 * 其余 update 类型无法安全跳过时，parse 会提前结束，chats 提取可能失败 → 返回 (0, 0)。
 *
 * iOS 参考: ConvertGroupToSupergroup.swift — 提取 != 原 peerId 的 new peer from Updates.chats
 *
 * 返回: (newChannelId, newChannelAccessHash)。两者均为 0 表示未能提取。
 */
public func parseMigrateChatResult(data: Array<Byte>, originalChatId: Int64): (Int64, Int64) {
    if (data.size < 4) { return (0, 0) }
    let d = TLDeserializer(data)
    try {
        let ctor = d.readUInt32()

        // RPC_ERROR — 迁移失败，不应调用到此函数
        if (ctor == TLConstructors.RPC_ERROR) {
            return (0, 0)
        }

        // updatesTooLong#e317af7e — no fields; cannot extract channel
        if (ctor == 0xe317af7e) {
            return (0, 0)
        }

        // updateShort#78d4dec1 update:Update date:int — 单条 Update，通常不携带 chats 向量
        if (ctor == 0x78d4dec1) {
            return (0, 0)
        }

        // updates#74ae4240 or updatesCombined#725b04c3
        // Field order: updates:Vector<Update> users:Vector<User> chats:Vector<Chat> date:int [seq_start:int] seq:int
        if (ctor == 0x74ae4240 || ctor == 0x725b04c3) {
            // 1. skip updates vector
            let updVecCtor = d.readUInt32()
            if (updVecCtor == TLConstructors.VECTOR) {
                let updCount = d.readInt32()
                var i: Int32 = 0
                while (i < updCount) {
                    skipUpdate(d)
                    i = i + 1
                }
            }

            // 2. skip users vector
            let usersVecCtor = d.readUInt32()
            if (usersVecCtor == TLConstructors.VECTOR) {
                let usersCount = d.readInt32()
                var i: Int32 = 0
                while (i < usersCount) {
                    let _ = UserResponse.deserializeBoxed(d)
                    i = i + 1
                }
            }

            // 3. parse chats vector — find first Channel entry whose id != originalChatId
            let chatsVecCtor = d.readUInt32()
            if (chatsVecCtor == TLConstructors.VECTOR) {
                let chatsCount = d.readInt32()
                var i: Int32 = 0
                while (i < chatsCount) {
                    let chat = ChatResponse.deserializeBoxed(d)
                    if (chat.isChannel && chat.id != originalChatId) {
                        Hilog.info(0, "CjTelegram", "[parseMigrateChatResult] found new channel id=${chat.id} accessHash=${chat.accessHash}")
                        return (chat.id, chat.accessHash)
                    }
                    i = i + 1
                }
                // Fallback: if all channels have the same id (unlikely), take the first channel
                Hilog.info(0, "CjTelegram", "[parseMigrateChatResult] no channel with different id found in chats vector")
            }
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[parseMigrateChatResult] parse exception: ${e}")
    }
    return (0, 0)
}

/**
 * 跳过 EncryptedMessage (简单实现 — 读构造器 + 基本字段)
 */
/**
 * 解析 updates.difference 的 other_updates 中的一个元素。
 *
 * TL 是变长编码，**不认识的构造器无法跳过**（不知道结构就算不出长度）。
 * 因此本函数只处理能完整消费的类型，遇到未知类型返回 false，
 * 由调用方立即停止顺序解析 —— 继续读只会拿到错位的垃圾。
 *
 * 认得的类型里，已读水位会被收集进 r.readStates 交给状态机应用；
 * 其余类型只推进游标、不产出（新消息由 new_messages 字段单独带回）。
 *
 * @return true = 已完整消费该元素；false = 未知类型，此后游标不可信
 */
func parseDifferenceUpdate(d: TLDeserializer, r: UpdatesDifferenceResponse): Bool {
    let ctor = d.readUInt32()

    // updateReadHistoryOutbox#2f2f21bf peer:Peer max_id:int pts:int pts_count:int
    if (ctor == 0x2f2f21bf) {
        let peer = PeerResponse.deserializeBoxed(d)
        let maxId = d.readInt32()
        let _ = d.readInt32()  // pts
        let _ = d.readInt32()  // pts_count
        let entry = DifferenceReadState()
        entry.peerType = peer.type_
        entry.peerId = peer.id
        entry.maxId = maxId
        entry.outgoing = true
        r.readStates.add(entry)
        return true
    }

    // updateReadHistoryInbox#9e84bc99 (current) / #9c974fdf (legacy)
    // flags, folder_id?[0], peer, top_msg_id?[1], max_id, still_unread, pts, pts_count
    if (ctor == 0x9e84bc99 || ctor == 0x9c974fdf) {
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // folder_id
        let peer = PeerResponse.deserializeBoxed(d)
        if ((flags & 2) != 0) { let _ = d.readInt32() }  // top_msg_id
        let maxId = d.readInt32()
        let stillUnread = d.readInt32()
        let _ = d.readInt32()  // pts
        let _ = d.readInt32()  // pts_count
        let entry = DifferenceReadState()
        entry.peerType = peer.type_
        entry.peerId = peer.id
        entry.maxId = maxId
        entry.stillUnread = stillUnread
        entry.outgoing = false
        r.readStates.add(entry)
        return true
    }

    // updateRecentReactions#6f7863f4 — 无字段
    if (ctor == 0x6f7863f4) {
        return true
    }

    // updateNewMessage#1f2b0afd / updateEditMessage#e40370a3 — message:Message pts:int pts_count:int
    if (ctor == 0x1f2b0afd || ctor == 0xe40370a3) {
        let _ = TLMessage.deserializeBoxed(d)
        let _ = d.readInt32()
        let _ = d.readInt32()
        return true
    }

    // updateDeleteMessages#a20db0e5 messages:Vector<int> pts:int pts_count:int
    if (ctor == 0xa20db0e5) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { r.deletedMessageIds.add(d.readInt32()) }
        }
        let _ = d.readInt32()
        let _ = d.readInt32()
        return true
    }

    // updateChannel#635b4c09 channel_id:long
    if (ctor == 0x635b4c09) {
        let _ = d.readInt64()
        return true
    }

    return false
}

func skipEncryptedMessage(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    // encryptedMessage#ed18c118 random_id:long chat_id:int date:int bytes:bytes file:EncryptedFile
    if (ctor == 0xed18c118) {
        let _ = d.readInt64()  // random_id
        let _ = d.readInt32()  // chat_id
        let _ = d.readInt32()  // date
        let _ = d.readBytes()  // bytes
        // EncryptedFile — skip
        let fileCtor = d.readUInt32()
        if (fileCtor == 0xa8008cd8) {
            // encryptedFile: id, access_hash, size, dc_id, key_fingerprint
            let _ = d.readInt64()
            let _ = d.readInt64()
            let _ = d.readInt64()  // size (long in layer 170+)
            let _ = d.readInt32()
            let _ = d.readInt32()
        }
        // encryptedFileEmpty = 0xc21f497e — no fields
        return
    }
    // encryptedMessageService#23734b06 random_id:long chat_id:int date:int bytes:bytes
    if (ctor == 0x23734b06) {
        let _ = d.readInt64()
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readBytes()
        return
    }
}

/**
 * 跳过 Update (极其复杂 — 有 100+ 种类型)
 * 简单策略：读构造器，尝试跳过已知类型，未知则 break
 */
public func skipUpdate(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()

    // updateRecentReactions#6f7863f4 = Update. This constructor is fieldless
    // and frequently appears in updates.difference together with a reaction
    // delta; failing to recognize it leaves the vector cursor misaligned.
    if (ctor == 0x6f7863f4) {
        return
    }
    
    // updateNewMessage#1f2b0afd message:Message pts:int pts_count:int
    if (ctor == 0x1f2b0afd) {
        let msg = TLMessage.deserializeBoxed(d)
        let _ = d.readInt32()  // pts
        let _ = d.readInt32()  // pts_count
        return
    }
    
    // updateDeleteMessages#a20db0e5 messages:Vector<int> pts:int pts_count:int
    if (ctor == 0xa20db0e5) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let _ = d.readInt32()
            }
        }
        let _ = d.readInt32()  // pts
        let _ = d.readInt32()  // pts_count
        return
    }
    
    // updateReadHistoryInbox#9e84bc99 (current, iOS dict[-1635468135]) / #9c974fdf (legacy)
    // iOS Api29.swift:6966: flags, folder_id?[0], peer(boxed), top_msg_id?[1], max_id, still_unread, pts, pts_count
    if (ctor == 0x9e84bc99 || ctor == 0x9c974fdf) {
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // folder_id (flags.0)
        let _ = PeerResponse.deserializeBoxed(d)  // peer
        if ((flags & 2) != 0) { let _ = d.readInt32() }  // top_msg_id (flags.1) — new field in 0x9e84bc99
        let _ = d.readInt32()  // max_id
        let _ = d.readInt32()  // still_unread_count
        let _ = d.readInt32()  // pts
        let _ = d.readInt32()  // pts_count
        return
    }
    
    // updateReadHistoryOutbox#2f2f21bf peer:Peer max_id:int pts:int pts_count:int
    if (ctor == 0x2f2f21bf) {
        let _ = PeerResponse.deserializeBoxed(d)
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readInt32()
        return
    }
    
    // updateEditMessage#e40370a3 message:Message pts:int pts_count:int
    if (ctor == 0xe40370a3) {
        let msg = TLMessage.deserializeBoxed(d)
        let _ = d.readInt32()
        let _ = d.readInt32()
        return
    }
    
    // updatePeerLocated#b4afcfb0 (current, iOS dict[-1263546448]) / #b4ac292b (legacy)
    // peers: Vector<PeerLocated> — body structure unchanged, only ctor changed
    // iOS parse_updatePeerLocated: readInt32 (VECTOR ctor) → parseVector → readInt32 (count) → per-element readInt32 (ctor) + body
    if (ctor == 0xb4afcfb0 || ctor == 0xb4ac292b) {
        let _vecCtor = d.readUInt32()  // VECTOR ctor 0x1cb5c415 — must be consumed before count
        let peersCount = d.readInt32()
        var j: Int32 = 0
        while (j < peersCount) {
            let peerCtor = d.readUInt32()
            if (peerCtor == 0xca461b5d) {
                let _ = PeerResponse.deserializeBoxed(d)
                let _ = d.readInt32()
                let _ = d.readInt32()
            } else if (peerCtor == 0xf8ec284b || peerCtor == 0xd0bc34c8) {
                let _ = d.readInt32()
            } else {
                skipBoxedObject(d)
            }
            j = j + 1
        }
        return
    }

    // updateChannel#635b4c09 channel_id:long
    // iOS Api29.swift dict[1666927625] = parse_updateChannel; field: channelId:long
    if (ctor == 0x635b4c09) {
        let _ = d.readInt64()  // channel_id
        return
    }

    // 其他 update 类型太多，无法全部处理
    // 对于未知类型，我们无法安全跳过（不知道长度）
    // 所以只能 early return — 后续数据可能不完整
    // 实际使用中 new_messages 是最重要的数据，后面的可以容错
    return
}

/**
 * 跳过已读取 constructor 的 Update 的 body（用于 parsePeersNearby 循环中）
 */
func skipUpdateWithConstructor(ctor: UInt32, d: TLDeserializer): Unit {
    if (ctor == 0x6f7863f4) {
        return
    }
    if (ctor == 0xb4afcfb0 || ctor == 0xb4ac292b) {
        let _vecCtor = d.readUInt32()  // VECTOR ctor 0x1cb5c415 — must be consumed before count
        let peersCount = d.readInt32()
        var j: Int32 = 0
        while (j < peersCount) {
            let peerCtor = d.readUInt32()
            if (peerCtor == 0xca461b5d) {
                let _ = PeerResponse.deserializeBoxed(d)
                let _ = d.readInt32()
                let _ = d.readInt32()
            } else if (peerCtor == 0xf8ec284b || peerCtor == 0xd0bc34c8) {
                let _ = d.readInt32()
            } else {
                skipBoxedObject(d)
            }
            j = j + 1
        }
        return
    }
    if (ctor == 0x1f2b0afd) {
        let msg = TLMessage.deserializeBoxed(d)
        let _ = d.readInt32()
        let _ = d.readInt32()
        return
    }
    if (ctor == 0xa20db0e5) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { let _ = d.readInt32() }
        }
        let _ = d.readInt32()
        let _ = d.readInt32()
        return
    }
    if (ctor == 0x9e84bc99 || ctor == 0x9c974fdf) {
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt32() }  // folder_id
        let _ = PeerResponse.deserializeBoxed(d)
        if ((flags & 2) != 0) { let _ = d.readInt32() }  // top_msg_id — new in 0x9e84bc99
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readInt32()
        return
    }
    if (ctor == 0x2f2f21bf) {
        let _ = PeerResponse.deserializeBoxed(d)
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readInt32()
        return
    }
    if (ctor == 0xe40370a3) {
        let msg = TLMessage.deserializeBoxed(d)
        let _ = d.readInt32()
        let _ = d.readInt32()
        return
    }
}

// ==================== Phase S2: messages.ChatFull 响应 ====================

/**
 * 群组/频道完整信息响应
 * 
 * messages.chatFull#e5d7d19c full_chat:ChatFull chats:Vector<Chat> users:Vector<User>
 * 
 * 我们只提取关键的描述性字段，跳过大部分复杂字段
 */
/**
 * chatParticipant#c02d4007 user_id:long inviter_id:long date:int
 * chatParticipantCreator#e46bcee4 user_id:long
 * chatParticipantAdmin#a0933f5b user_id:long inviter_id:long date:int
 * （telegram_api.tl:134-136）
 */
public class ChatParticipantEntry {
    public var userId: Int64 = 0
    public var inviterId: Int64 = 0
    public var date: Int32 = 0
    public var isAdmin: Bool = false
    public var isCreator: Bool = false
}

func parseChatParticipantEntry(d: TLDeserializer): ChatParticipantEntry {
    let e = ChatParticipantEntry()
    let ctor = d.readUInt32()
    if (ctor == 0xc02d4007) {
        e.userId = d.readInt64()
        e.inviterId = d.readInt64()
        e.date = d.readInt32()
    } else if (ctor == 0xe46bcee4) {
        e.userId = d.readInt64()
        e.isCreator = true
        e.isAdmin = true
    } else if (ctor == 0xa0933f5b) {
        e.userId = d.readInt64()
        e.inviterId = d.readInt64()
        e.date = d.readInt32()
        e.isAdmin = true
    } else {
        Hilog.info(0, "CjTelegram", "[parseChatParticipantEntry] unknown ctor: 0x${toHex32(ctor)}")
    }
    return e
}

public class ChatFullResponse {
    public var about: String = ""         // 群组/频道描述
    public var membersCount: Int32 = 0    // 成员总数
    public var onlineCount: Int32 = 0     // 在线人数
    public var inviteLink: String = ""    // 永久邀请链接
    public var isChannel: Bool = false    // 是否为频道
    public var linkedChatId: Int64 = 0    // 关联聊天 ID
    public var slowmodeSeconds: Int32 = 0 // 慢速模式秒数
    public var canViewParticipants: Bool = true
    // channelFull.flags2.0 can_delete_channel → iOS CachedChannelFlags.canDeleteHistory：
    // PeerInfo More 菜单 "Delete Group" 与 "Clear Messages for everyone" 的门槛。
    // 进行中的 Video Chat（0 = 没有）
    public var activeCallId: Int64 = 0
    public var activeCallAccessHash: Int64 = 0
    public var canDeleteChannel: Bool = false
    // channelFull.flags.6 / chatFull.flags.7 can_set_username → CachedChannelFlags.canChangeUsername
    public var canSetUsername: Bool = false
    // channelFull.flags.10 hidden_prehistory（Chat History for New Members = Hidden）
    public var hiddenPrehistory: Bool = false
    // channelFull.migrated_from_chat_id / migrated_from_max_id（flags.4）→ iOS
    // CachedChannelData.migrationReference（UpdateCachedPeerData.swift:790）
    public var migratedFromChatId: Int64 = 0
    public var migratedFromMaxId: Int32 = 0
    public var adminsCount: Int32 = 0
    public var kickedCount: Int32 = 0
    public var bannedCount: Int32 = 0
    // S2-72: chatFull / channelFull bot_info → 群里机器人的命令（iOS CachedGroupData.botInfos）
    public var botCommands: ArrayList<(String, String)> = ArrayList<(String, String)>()
    public var ttlPeriod: Int32 = 0
    public var stickerSetId: Int64 = 0
    public var stickerSetAccessHash: Int64 = 0
    public var emojiSetId: Int64 = 0
    public var emojiSetAccessHash: Int64 = 0
    // 基础群（chatFull#2633421b）参与者列表：iOS 同样从 messages.getFullChat 的
    // participants:ChatParticipants 取基础群成员（channels.getParticipants 对基础群返回 CHANNEL_INVALID）。
    public var participants: ArrayList<ChatParticipantEntry> = ArrayList<ChatParticipantEntry>()
    public var participantsForbidden: Bool = false
    // messages.chatFull 尾部 users:Vector<User>，用于解析参与者姓名/accessHash
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()

    /**
     * 从原始响应 bytes 中解析
     * 外层: messages.chatFull#e5d7d19c
     * 内层: chatFull#c9d31138 或 channelFull#44c054a7 (或其他版本)
     */
    public static func deserialize(data: Array<Byte>): ChatFullResponse {
        var result = ChatFullResponse()
        if (data.size < 8) { return result }
        
        let d = TLDeserializer(data)
        let outerCtor = d.readUInt32()
        
        // messages.chatFull#e5d7d19c
        if (outerCtor != 0xe5d7d19c) {
            // 可能是 RPC error
            if (outerCtor == TLConstructors.RPC_ERROR || outerCtor == 0x2144ca19) {
                return result
            }
            return result
        }
        
        // full_chat: ChatFull (boxed)
        let innerCtor = d.readUInt32()
        
        // chatFull#2633421b (current, iOS dict[640893467]) / #c9d31138 (legacy)
        if (innerCtor == 0x2633421b || innerCtor == 0xc9d31138) {
            result.isChannel = false
            result = parseChatFull(d, result)
            return result
        }
        
        // channelFull — 有多个版本（layer 依赖）
        // channelFull#44c054a7 (layer 185+)
        // channelFull#f2355507 (layer 167+)
        // 我们尝试通用解析关键字段
        result.isChannel = true
        result = parseChannelFull(d, result)
        return result
    }
}

/**
 * 解析 chatFull (基础群组)
 * chatFull#c9d31138 flags:# ... about:string ...
 */
func parseChatFull(d: TLDeserializer, result: ChatFullResponse): ChatFullResponse {
    var r = result
    try {
        // chatFull#2633421b flags:# id:long about:string participants:ChatParticipants
        //   chat_photo:flags.2?Photo notify_settings:PeerNotifySettings exported_invite:flags.13?ExportedChatInvite
        //   bot_info:flags.3?Vector<BotInfo> pinned_msg_id:flags.6?int folder_id:flags.11?int
        //   call:flags.12?InputGroupCall ttl_period:flags.14?int groupcall_default_join_as:flags.15?Peer
        //   theme_emoticon:flags.16?string requests_pending:flags.17?int recent_requesters:flags.17?Vector<long>
        //   available_reactions:flags.18?ChatReactions reactions_limit:flags.20?int   (telegram_api.tl:131)
        let flags = d.readInt32()
        r.canSetUsername = (flags & (1 << 7)) != 0
        let _ = d.readInt64() // id
        r.about = d.readString() // about

        // participants: ChatParticipants (boxed)
        let pCtor = d.readUInt32()
        if (pCtor == 0x3cbc93f8) {
            // chatParticipants#3cbc93f8 chat_id:long participants:Vector<ChatParticipant> version:int
            let _ = d.readInt64()
            let vec = d.readUInt32()
            if (vec == TLConstructors.VECTOR) {
                let n = d.readInt32()
                for (_i in 0..Int64(n)) {
                    let e = parseChatParticipantEntry(d)
                    if (e.userId > 0) { r.participants.add(e) }
                }
            }
            let _ = d.readInt32() // version
        } else if (pCtor == 0x8763d3e1) {
            // chatParticipantsForbidden#8763d3e1 flags:# chat_id:long self_participant:flags.0?ChatParticipant
            r.participantsForbidden = true
            r.canViewParticipants = false
            let pf = d.readInt32()
            let _ = d.readInt64()
            if ((pf & 1) != 0) {
                let e = parseChatParticipantEntry(d)
                if (e.userId > 0) { r.participants.add(e) }
            }
        } else {
            Hilog.info(0, "CjTelegram", "[parseChatFull] unknown ChatParticipants ctor: 0x${toHex32(pCtor)}")
            return r
        }
        r.membersCount = Int32(r.participants.size)

        if ((flags & (1 << 2)) != 0) { skipPhoto(d) }
        let _ = skipPeerNotifySettings(d)
        if ((flags & (1 << 13)) != 0) { skipExportedChatInviteBoxed(d) }
        if ((flags & (1 << 3)) != 0) {
            let vc = d.readUInt32()
            if (vc == TLConstructors.VECTOR) {
                let n = d.readInt32()
                for (_i in 0..Int64(n)) { readBotInfoCommandsInto(d, r) }
            }
        }
        if ((flags & (1 << 6)) != 0) { let _ = d.readInt32() }
        if ((flags & (1 << 11)) != 0) { let _ = d.readInt32() }
        if ((flags & (1 << 12)) != 0) { readFullInputGroupCall(d, r) }
        if ((flags & (1 << 14)) != 0) { r.ttlPeriod = d.readInt32() }
        if ((flags & (1 << 15)) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        if ((flags & (1 << 16)) != 0) { let _ = d.readString() }
        if ((flags & (1 << 17)) != 0) {
            let _ = d.readInt32()
            skipChannelFullLongVector(d)
        }
        if ((flags & (1 << 18)) != 0) { skipChannelFullChatReactions(d) }
        if ((flags & (1 << 20)) != 0) { let _ = d.readInt32() }

        // messages.chatFull 尾部：chats:Vector<Chat> users:Vector<User>
        let cv = d.readUInt32()
        if (cv == TLConstructors.VECTOR) {
            let n = d.readInt32()
            for (_i in 0..Int64(n)) { let _ = ChatResponse.deserializeBoxed(d) }
        }
        let uv = d.readUInt32()
        if (uv == TLConstructors.VECTOR) {
            let n = d.readInt32()
            for (_i in 0..Int64(n)) { r.users.add(UserResponse.deserializeBoxed(d)) }
        }
        Hilog.info(0, "CjTelegram", "[parseChatFull] participants=${r.participants.size} users=${r.users.size}")
    } catch (e: Exception) {
        // 解析失败容错：已取到的 about/participants 保留
        let at = d.getOffset()
        Hilog.info(0, "CjTelegram", "[parseChatFull] partial parse: ${e} participants=${r.participants.size} offset=${at}/${d.getBufferSize()}")
    }
    return r
}

// ===== channelFull skip helpers (iOS Api4.swift parse_channelFull 字段顺序逐字对照) =====

// 跳过 GeoPoint (boxed) — geoPoint#b2a2f663 flags:int long:double lat:double access_hash:long accuracyRadius?[0]:int
// geoPointEmpty#1117dd5f — 无字段
// 注：iOS parse_geoPoint Api7.swift:1514; 入口已读 constructor
func skipGeoPointBody(d: TLDeserializer, constructor: UInt32): Unit {
    if (constructor == 0x1117dd5f) { return }  // geoPointEmpty — 无字段
    // geoPoint#b2a2f663 (iOS dict[-1297942941] = 0xb2a2f663)
    let flags = d.readInt32()
    let _ = d.readInt64()   // long (double 实际 8 bytes，readInt64 跳过同样 8 bytes)
    let _ = d.readInt64()   // lat (double)
    let _ = d.readInt64()   // access_hash
    if ((flags & 1) != 0) { let _ = d.readInt32() }  // accuracy_radius?[flags.0]
}

// 跳过 ChannelLocation (boxed) — 读 constructor 后分派
// channelLocationEmpty#209b82db — 无字段
// channelLocation#9050b67f geo_point:GeoPoint address:string
func skipChannelLocationBoxed(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x209b82db) { return }  // channelLocationEmpty
    // channelLocation#9050b67f
    let geoCtor = d.readUInt32()
    skipGeoPointBody(d, geoCtor)
    let _ = d.readString()  // address
}

// 跳过 Api.StickerSet (boxed, inline) — iOS Api28.swift:673 parse_stickerSet
// stickerSet#2dd17c3f flags:int installed_date?[0]:int id:long access_hash:long
//   title:string short_name:string thumbs?[4]:Vector<PhotoSize> thumb_dc_id?[4]:int
//   thumb_version?[4]:int thumb_document_id?[8]:long count:int hash:int
func readStickerSetReferenceBoxed(d: TLDeserializer): (Int64, Int64) {
    let _ = d.readUInt32()  // constructor (stickerSet#2dd17c3f — не проверяем)
    let flags = d.readInt32()
    if ((flags & 1) != 0) { let _ = d.readInt32() }   // installed_date?[0]
    let id = d.readInt64()
    let accessHash = d.readInt64()
    let _ = d.readString()  // title
    let _ = d.readString()  // short_name
    // thumbs?[4]: Vector<PhotoSize>
    if ((flags & 16) != 0) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                skipPhotoSize(d)
            }
        }
        let _ = d.readInt32()   // thumb_dc_id?[4]
        let _ = d.readInt32()   // thumb_version?[4]
    }
    // thumb_document_id?[8]
    if ((flags & 256) != 0) { let _ = d.readInt64() }
    let _ = d.readInt32()   // count
    let _ = d.readInt32()   // hash
    return (id, accessHash)
}

func skipStickerSetBoxed(d: TLDeserializer): Unit {
    let _ = readStickerSetReferenceBoxed(d)
}

// 跳过 BotCommand (boxed, constructor already read by caller)
// botCommand#c27ac8c7 command:string description:string
func skipBotCommandBody(d: TLDeserializer): Unit {
    let _ = d.readString()  // command
    let _ = d.readString()  // description
}

// 跳过 BotMenuButton (boxed)
// botMenuButtonDefault#7533a588 — 无字段
// botMenuButtonCommands#4258c205 — 无字段
// botMenuButton#c7b57ce6 text:string url:string
func skipBotMenuButtonBoxed(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x7533a588 || ctor == 0x4258c205) { return }
    // botMenuButton#c7b57ce6
    let _ = d.readString()
    let _ = d.readString()
}

// 跳过 BotAppSettings (boxed, constructor already read) — iOS Api2.swift:168
// botAppSettings#9e39b178 flags:int placeholder_path?[0]:bytes
//   background_color?[1]:int background_dark_color?[2]:int
//   header_color?[3]:int header_dark_color?[4]:int
func skipBotAppSettingsBody(d: TLDeserializer): Unit {
    let flags = d.readInt32()
    if ((flags & 1) != 0) { let _ = d.readBytes() }
    if ((flags & 2) != 0) { let _ = d.readInt32() }
    if ((flags & 4) != 0) { let _ = d.readInt32() }
    if ((flags & 8) != 0) { let _ = d.readInt32() }
    if ((flags & 16) != 0) { let _ = d.readInt32() }
}

// 跳过 BotVerifierSettings (boxed, constructor already read) — iOS Api2.swift:1638
// botVerifierSettings#54c4e23b flags:int icon:long company:string custom_description?[0]:string
func skipBotVerifierSettingsBody(d: TLDeserializer): Unit {
    let flags = d.readInt32()
    let _ = d.readInt64()   // icon
    let _ = d.readString()  // company
    if ((flags & 1) != 0) { let _ = d.readString() }
}

// S2-72: 读单个 BotInfo (boxed)，把 commands 追加到 ChatFullResponse.botCommands（其余字段跳过）
func readBotInfoCommandsInto(d: TLDeserializer, r: ChatFullResponse): Unit {
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    if ((flags & 1) != 0) { let _ = d.readInt64() }   // user_id?[0]
    if ((flags & 2) != 0) { let _ = d.readString() }  // description?[1]
    if ((flags & 16) != 0) { skipPhoto(d) }            // description_photo?[4]
    if ((flags & 32) != 0) { skipDocument(d) }         // description_document?[5]
    if ((flags & 4) != 0) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let _ = d.readUInt32()  // botCommand#c27ac8c7
                let command = d.readString()
                let description = d.readString()
                r.botCommands.add((command, description))
            }
        }
    }
    if ((flags & 8) != 0) { skipBotMenuButtonBoxed(d) }
    if ((flags & 128) != 0) { let _ = d.readString() }
    if ((flags & 256) != 0) {
        let _ = d.readUInt32()
        skipBotAppSettingsBody(d)
    }
    if ((flags & 512) != 0) {
        let _ = d.readUInt32()
        skipBotVerifierSettingsBody(d)
    }
}

// 跳过单个 BotInfo (boxed) — iOS Api2.swift:576 parse_botInfo
// botInfo#4d8a0299 flags:int user_id?[0]:long description?[1]:string
//   description_photo?[4]:Photo(boxed) description_document?[5]:Document(boxed)
//   commands?[2]:Vector<BotCommand> menu_button?[3]:BotMenuButton(boxed)
//   privacy_policy_url?[7]:string app_settings?[8]:BotAppSettings(boxed)
//   verifier_settings?[9]:BotVerifierSettings(boxed)
func skipBotInfoBoxed(d: TLDeserializer): Unit {
    let _ = d.readUInt32()  // constructor (不检查)
    let flags = d.readInt32()
    if ((flags & 1) != 0) { let _ = d.readInt64() }   // user_id?[0]
    if ((flags & 2) != 0) { let _ = d.readString() }  // description?[1]
    if ((flags & 16) != 0) { skipPhoto(d) }            // description_photo?[4] (boxed)
    if ((flags & 32) != 0) { skipDocument(d) }         // description_document?[5] (boxed)
    // commands?[2]: Vector<BotCommand>
    if ((flags & 4) != 0) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let _ = d.readUInt32()  // constructor (botCommand#c27ac8c7)
                skipBotCommandBody(d)
            }
        }
    }
    // menu_button?[3]: BotMenuButton (boxed)
    if ((flags & 8) != 0) { skipBotMenuButtonBoxed(d) }
    if ((flags & 128) != 0) { let _ = d.readString() }  // privacy_policy_url?[7]
    // app_settings?[8]: BotAppSettings (boxed, read ctor first)
    if ((flags & 256) != 0) {
        let _ = d.readUInt32()
        skipBotAppSettingsBody(d)
    }
    // verifier_settings?[9]: BotVerifierSettings (boxed, read ctor first)
    if ((flags & 512) != 0) {
        let _ = d.readUInt32()
        skipBotVerifierSettingsBody(d)
    }
}

// 跳过 StarsSubscriptionPricing (boxed, constructor already read)
// starsSubscriptionPricing#5416d58 period:int amount:long
func skipStarsSubscriptionPricingBody(d: TLDeserializer): Unit {
    let _ = d.readInt32()  // period
    let _ = d.readInt64()  // amount
}

// 跳过 Api.ExportedChatInvite (boxed) — iOS Api7.swift:601 parse_chatInviteExported
// chatInvitePublicJoinRequests#ede0084d — 无字段
// chatInviteExported#ab4a819 flags:int link:string admin_id:long date:int
//   start_date?[4]:int expire_date?[1]:int usage_limit?[2]:int usage?[3]:int
//   requested?[7]:int subscription_expired?[10]:int title?[8]:string
//   subscription_pricing?[9]:StarsSubscriptionPricing(boxed)
func skipExportedChatInviteBoxed(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xede0084d) { return }  // chatInvitePublicJoinRequests — 无字段
    // chatInviteExported#0ab4a819
    let flags = d.readInt32()
    let _ = d.readString()  // link
    let _ = d.readInt64()   // admin_id
    let _ = d.readInt32()   // date
    if ((flags & 16) != 0) { let _ = d.readInt32() }   // start_date?[4]
    if ((flags & 2) != 0)  { let _ = d.readInt32() }   // expire_date?[1]
    if ((flags & 4) != 0)  { let _ = d.readInt32() }   // usage_limit?[2]
    if ((flags & 8) != 0)  { let _ = d.readInt32() }   // usage?[3]
    if ((flags & 128) != 0){ let _ = d.readInt32() }   // requested?[7]
    if ((flags & 1024) != 0){ let _ = d.readInt32() }  // subscription_expired?[10]
    if ((flags & 256) != 0) { let _ = d.readString() } // title?[8]
    if ((flags & 512) != 0) {
        let _ = d.readUInt32()  // constructor
        skipStarsSubscriptionPricingBody(d)
    }
}

func skipChannelFullLongVector(d: TLDeserializer): Unit {
    if (d.readUInt32() != TLConstructors.VECTOR) { return }
    let count = d.readInt32()
    for (_i in 0..Int64(count)) { let _ = d.readInt64() }
}

/**
 * chatFull.call / channelFull.call：进行中的 Video Chat（iOS CachedGroupData/CachedChannelData.activeCall）。
 * 仅 inputGroupCall#d8aa840f 携带 id+access_hash；slug / inviteMessage 形式原样跳过。
 */
func readFullInputGroupCall(d: TLDeserializer, r: ChatFullResponse): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xd8aa840f) {
        r.activeCallId = d.readInt64()
        r.activeCallAccessHash = d.readInt64()
    }
    else if (ctor == 0x8c10603f) { let _ = d.readInt32() }
    else if (ctor == 0xfe06823f) { let _ = d.readString() }
}

func skipChannelFullInputGroupCall(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xd8aa840f) { let _ = d.readInt64(); let _ = d.readInt64() }
    else if (ctor == 0x8c10603f) { let _ = d.readInt32() }
    else if (ctor == 0xfe06823f) { let _ = d.readString() }
}

func skipChannelFullChatReactions(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x52928bca) { let _ = d.readInt32() }
    else if (ctor == 0x661d4037) {
        if (d.readUInt32() == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { skipReaction(d) }
        }
    }
    // chatReactionsNone#eafc32bc has no fields.
}

func skipChannelFullStoryFwdHeader(d: TLDeserializer): Unit {
    let _ = d.readUInt32()
    let flags = d.readInt32()
    if ((flags & 1) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
    if ((flags & 2) != 0) { let _ = d.readString() }
    if ((flags & 4) != 0) { let _ = d.readInt32() }
}

func skipChannelFullMediaAreaCoordinates(d: TLDeserializer): Unit {
    let _ = d.readUInt32()
    let flags = d.readInt32()
    // x, y, w, h, rotation are boxed as five IEEE754 64-bit values.
    for (_i in 0..5) { let _ = d.readInt64() }
    if ((flags & 1) != 0) { let _ = d.readInt64() }
}

func skipChannelFullGeoPoint(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    skipGeoPointBody(d, ctor)
}

func skipChannelFullGeoPointAddress(d: TLDeserializer): Unit {
    let _ = d.readUInt32()
    let flags = d.readInt32()
    let _ = d.readString()
    if ((flags & 1) != 0) { let _ = d.readString() }
    if ((flags & 2) != 0) { let _ = d.readString() }
    if ((flags & 4) != 0) { let _ = d.readString() }
}

func skipChannelFullInputChannel(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xf35aec28) { let _ = d.readInt64(); let _ = d.readInt64() }
    else if (ctor == 0x5b934f9d) {
        skipInputPeer(d)
        let _ = d.readInt32()
        let _ = d.readInt64()
    }
}

func skipChannelFullMediaArea(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xcad5452d) {
        let flags = d.readInt32()
        skipChannelFullMediaAreaCoordinates(d)
        skipChannelFullGeoPoint(d)
        if ((flags & 1) != 0) { skipChannelFullGeoPointAddress(d) }
    } else if (ctor == 0x14455871) {
        let _ = d.readInt32()
        skipChannelFullMediaAreaCoordinates(d)
        skipReaction(d)
    } else if (ctor == 0xbe82db9c) {
        skipChannelFullMediaAreaCoordinates(d)
        skipChannelFullGeoPoint(d)
        for (_i in 0..5) { let _ = d.readString() }
    } else if (ctor == 0xb282217f) {
        skipChannelFullMediaAreaCoordinates(d)
        let _ = d.readInt64()
        let _ = d.readString()
    } else if (ctor == 0x770416af) {
        skipChannelFullMediaAreaCoordinates(d)
        let _ = d.readInt64()
        let _ = d.readInt32()
    } else if (ctor == 0x2271f2bf) {
        skipChannelFullMediaAreaCoordinates(d)
        skipChannelFullInputChannel(d)
        let _ = d.readInt32()
    } else if (ctor == 0x37381085) {
        skipChannelFullMediaAreaCoordinates(d)
        let _ = d.readString()
    } else if (ctor == 0x49a6549c) {
        skipChannelFullMediaAreaCoordinates(d)
        let _ = d.readString()
        let _ = d.readInt64()
        let _ = d.readInt32()
    } else if (ctor == 0x5787686d) {
        skipChannelFullMediaAreaCoordinates(d)
        let _ = d.readString()
    }
}

func skipChannelFullPrivacyRule(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xb8905fb2 || ctor == 0xe4621141 || ctor == 0x6b134e8e ||
        ctor == 0x41c87565) {
        skipChannelFullLongVector(d)
    }
}

func skipChannelFullStoryViews(d: TLDeserializer): Unit {
    let _ = d.readUInt32()
    let flags = d.readInt32()
    let _ = d.readInt32()
    if ((flags & 4) != 0) { let _ = d.readInt32() }
    if ((flags & 8) != 0 && d.readUInt32() == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            let _ = d.readUInt32()
            let reactionFlags = d.readInt32()
            if ((reactionFlags & 1) != 0) { let _ = d.readInt32() }
            skipReaction(d)
            let _ = d.readInt32()
        }
    }
    if ((flags & 16) != 0) { let _ = d.readInt32() }
    if ((flags & 1) != 0) { skipChannelFullLongVector(d) }
}

/** Current-layer StoryItem skipper used only to reach channelFull.emojiset. */
func skipChannelFullStoryItem(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x51e6ee4f) { let _ = d.readInt32(); return }
    if (ctor == 0xffadc913 || ctor == 0xb0edac3e) {
        for (_i in 0..4) { let _ = d.readInt32() }
        return
    }
    let flags = d.readInt32()
    let _ = d.readInt32()
    let _ = d.readInt32()
    if ((flags & (1 << 18)) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
    if ((flags & (1 << 17)) != 0) { skipChannelFullStoryFwdHeader(d) }
    let _ = d.readInt32()
    if ((flags & 1) != 0) { let _ = d.readString() }
    if ((flags & 2) != 0) { skipMessageEntitiesVector(d) }
    skipMessageMedia(d)
    if ((flags & (1 << 14)) != 0 && d.readUInt32() == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) { skipChannelFullMediaArea(d) }
    }
    if ((flags & 4) != 0 && d.readUInt32() == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) { skipChannelFullPrivacyRule(d) }
    }
    if ((flags & 8) != 0) { skipChannelFullStoryViews(d) }
    if ((flags & (1 << 15)) != 0) { skipReaction(d) }
    if ((flags & (1 << 19)) != 0) {
        if (d.readUInt32() == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { let _ = d.readInt32() }
        }
    }
    if ((flags & (1 << 20)) != 0) { skipDocument(d) }
}

func skipChannelFullPeerStories(d: TLDeserializer): Unit {
    let _ = d.readUInt32()
    let flags = d.readInt32()
    let _ = PeerResponse.deserializeBoxed(d)
    if ((flags & 1) != 0) { let _ = d.readInt32() }
    if (d.readUInt32() == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) { skipChannelFullStoryItem(d) }
    }
}

/**
 * 解析 channelFull (频道/超级群)
 *
 * 字段顺序严格对照 iOS Api4.swift:1764 parse_channelFull。
 * 目标：读/跳每个字段直到 slowmode_seconds(flags.17) 并提取其值。
 *
 * channelFull#44c054a7 / #f2355507 (多 layer 版本共用同一字段布局)
 *   flags:#  flags2:#
 *   id:long  about:string
 *   participants_count?[0]:int  admins_count?[1]:int
 *   kicked_count?[2]:int  banned_count?[2]:int  online_count?[13]:int
 *   read_inbox_max_id:int  read_outbox_max_id:int  unread_count:int
 *   chat_photo:Photo(boxed)  notify_settings:PeerNotifySettings(boxed)
 *   exported_invite?[23]:ExportedChatInvite(boxed)
 *   bot_info:Vector<BotInfo>
 *   migrated_from_chat_id?[4]:long  migrated_from_max_id?[4]:int
 *   pinned_msg_id?[5]:int
 *   stickerset?[8]:StickerSet(boxed)
 *   available_min_id?[9]:int  folder_id?[11]:int  linked_chat_id?[14]:long
 *   location?[15]:ChannelLocation(boxed)
 *   slowmode_seconds?[17]:int   ← 目标字段
 */
func parseChannelFull(d: TLDeserializer, result: ChatFullResponse): ChatFullResponse {
    var r = result
    try {
        // 1. flags (Int32) — iOS _1
        let flags = d.readInt32()
        r.canViewParticipants = (flags & 8) != 0  // bit 3: can_view_participants
        r.canSetUsername = (flags & (1 << 6)) != 0
        r.hiddenPrehistory = (flags & (1 << 10)) != 0

        // 2. flags2 (Int32) — iOS _2
        let flags2 = d.readInt32()
        r.canDeleteChannel = (flags2 & 1) != 0  // flags2.0 can_delete_channel

        // 3. id (Int64) — iOS _3
        let _ = d.readInt64()

        // 4. about (String) — iOS _4
        r.about = d.readString()

        // 5. participants_count?[0] — iOS _5
        if ((flags & (1 << 0)) != 0) { r.membersCount = d.readInt32() }

        // 6. admins_count?[1] — iOS _6
        if ((flags & (1 << 1)) != 0) { r.adminsCount = d.readInt32() }

        // 7. kicked_count?[2] — iOS _7
        if ((flags & (1 << 2)) != 0) { r.kickedCount = d.readInt32() }

        // 8. banned_count?[2] — iOS _8 (same bit as kicked_count, both present when bit2 set)
        if ((flags & (1 << 2)) != 0) { r.bannedCount = d.readInt32() }

        // 9. online_count?[13] — iOS _9
        if ((flags & (1 << 13)) != 0) { r.onlineCount = d.readInt32() }

        // 10. read_inbox_max_id (always) — iOS _10
        let _ = d.readInt32()

        // 11. read_outbox_max_id (always) — iOS _11
        let _ = d.readInt32()

        // 12. unread_count (always) — iOS _12
        let _ = d.readInt32()

        // 13. chat_photo (always, boxed Photo) — iOS _13
        skipPhoto(d)

        // 14. notify_settings (always, boxed PeerNotifySettings) — iOS _14
        let _ = skipPeerNotifySettings(d)

        // 15. exported_invite?[23] (boxed ExportedChatInvite) — iOS _15
        if ((flags & (1 << 23)) != 0) { skipExportedChatInviteBoxed(d) }

        // 16. bot_info (always, Vector<BotInfo>) — iOS _16；S2-72 记下命令
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let botCount = d.readInt32()
            for (_i in 0..Int64(botCount)) {
                readBotInfoCommandsInto(d, r)
            }
        }

        // 17. migrated_from_chat_id?[4] (Int64) — iOS _17
        if ((flags & (1 << 4)) != 0) { r.migratedFromChatId = d.readInt64() }

        // 18. migrated_from_max_id?[4] (Int32) — iOS _18
        if ((flags & (1 << 4)) != 0) { r.migratedFromMaxId = d.readInt32() }

        // 19. pinned_msg_id?[5] (Int32) — iOS _19
        if ((flags & (1 << 5)) != 0) { let _ = d.readInt32() }

        // 20. stickerset?[8] (boxed StickerSet) — iOS _20
        if ((flags & (1 << 8)) != 0) {
            let (id, accessHash) = readStickerSetReferenceBoxed(d)
            r.stickerSetId = id
            r.stickerSetAccessHash = accessHash
        }

        // 21. available_min_id?[9] (Int32) — iOS _21
        if ((flags & (1 << 9)) != 0) { let _ = d.readInt32() }

        // 22. folder_id?[11] (Int32) — iOS _22
        if ((flags & (1 << 11)) != 0) { let _ = d.readInt32() }

        // 23. linked_chat_id?[14] (Int64) — iOS _23
        if ((flags & (1 << 14)) != 0) { r.linkedChatId = d.readInt64() }

        // 24. location?[15] (boxed ChannelLocation) — iOS _24
        if ((flags & (1 << 15)) != 0) { skipChannelLocationBoxed(d) }

        // 25. slowmode_seconds?[17] (Int32) — iOS _25  TARGET
        if ((flags & (1 << 17)) != 0) { r.slowmodeSeconds = d.readInt32() }

        // 26..42: keep exact current-layer order so emojiset (flags2.10) is reachable.
        if ((flags & (1 << 18)) != 0) { let _ = d.readInt32() }
        if ((flags & (1 << 12)) != 0) { let _ = d.readInt32() }
        let _ = d.readInt32() // pts
        if ((flags & (1 << 21)) != 0) { readFullInputGroupCall(d, r) }
        if ((flags & (1 << 24)) != 0) { r.ttlPeriod = d.readInt32() }  // ttl_period
        if ((flags & (1 << 25)) != 0) { skipStringVector(d) }
        if ((flags & (1 << 26)) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        if ((flags & (1 << 27)) != 0) { let _ = d.readString() }
        if ((flags & (1 << 28)) != 0) {
            let _ = d.readInt32()
            skipChannelFullLongVector(d)
        }
        if ((flags & (1 << 29)) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        if ((flags & (1 << 30)) != 0) { skipChannelFullChatReactions(d) }
        if ((flags2 & (1 << 13)) != 0) { let _ = d.readInt32() }
        if ((flags2 & (1 << 4)) != 0) { skipChannelFullPeerStories(d) }
        if ((flags2 & (1 << 7)) != 0) { skipWallPaper(d) }
        if ((flags2 & (1 << 8)) != 0) { let _ = d.readInt32() }
        if ((flags2 & (1 << 9)) != 0) { let _ = d.readInt32() }
        if ((flags2 & (1 << 10)) != 0) {
            let (id, accessHash) = readStickerSetReferenceBoxed(d)
            r.emojiSetId = id
            r.emojiSetAccessHash = accessHash
        }

    } catch (_: Exception) {
        // 解析失败容错：已读取的字段不丢弃，slowmodeSeconds 保持默认 0
    }
    return r
}

// ==================== Phase P4-1: 2FA Password Response ====================

/**
 * account.password#957b50fb 响应
 * 
 * 包含 SRP 参数用于 2FA 密码验证
 */
public class AccountPasswordResponse {
    public var hasPassword: Bool = false
    public var hasRecovery: Bool = false
    public var hasSecureValues: Bool = false
    public var hint: String = ""
    public var emailUnconfirmedPattern: String = ""
    public var srpId: Int64 = 0
    public var srpB: Array<Byte> = Array<Byte>(0, repeat: 0)
    // current_algo fields (passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow)
    public var algoSalt1: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var algoSalt2: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var algoG: Int32 = 0
    public var algoP: Array<Byte> = Array<Byte>(0, repeat: 0)
    // new_algo fields (always present; parallel to current, never overwrite current)
    public var newAlgoSalt1: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var newAlgoSalt2: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var newAlgoG: Int32 = 0
    public var newAlgoP: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var newSecureAlgoConstructor: UInt32 = 0
    public var newSecureAlgoSalt: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var secureRandom: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var pendingResetDate: Int32 = 0
    public var loginEmailPattern: String = ""

    /**
     * account.password#957b50fb
     * flags:# has_recovery:flags.0?true has_secure_values:flags.1?true has_password:flags.2?true
     * current_algo:flags.2?PasswordKdfAlgo srp_B:flags.2?bytes srp_id:flags.2?long
     * hint:flags.3?string email_unconfirmed_pattern:flags.4?string
     * new_algo:PasswordKdfAlgo new_secure_algo:SecurePasswordKdfAlgo secure_random:bytes
     * pending_reset_date:flags.5?int login_email_pattern:flags.6?string
     */
    public static func deserialize(data: Array<Byte>): AccountPasswordResponse {
        let r = AccountPasswordResponse()
        let d = TLDeserializer(data)
        
        try {
            let constructor = d.readUInt32()
            Hilog.info(0, "CjTelegram", "[AccountPassword] constructor: 0x${toHex32(constructor)}")
            
            if (constructor != 0x957b50fb) {
                Hilog.info(0, "CjTelegram", "[AccountPassword] Unexpected constructor")
                return r
            }
            
            let flags = d.readInt32()
            r.hasRecovery = (flags & 1) != 0      // bit 0
            r.hasSecureValues = (flags & 2) != 0   // bit 1
            r.hasPassword = (flags & 4) != 0       // bit 2
            
            Hilog.info(0, "CjTelegram", "[AccountPassword] hasPassword: ${r.hasPassword}, hasRecovery: ${r.hasRecovery}")
            
            // current_algo (flags.2)
            if (r.hasPassword) {
                let algoConstructor = d.readUInt32()
                Hilog.info(0, "CjTelegram", "[AccountPassword] algo constructor: 0x${toHex32(algoConstructor)}")
                
                if (algoConstructor == 0x3a912d4a) {
                    // passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow
                    r.algoSalt1 = d.readBytes()
                    r.algoSalt2 = d.readBytes()
                    r.algoG = d.readInt32()
                    r.algoP = d.readBytes()
                    Hilog.info(0, "CjTelegram", "[AccountPassword] SRP algo: salt1=${r.algoSalt1.size}B, salt2=${r.algoSalt2.size}B, g=${r.algoG}, p=${r.algoP.size}B")
                }
                
                // srp_B (flags.2)
                r.srpB = d.readBytes()
                // srp_id (flags.2)
                r.srpId = d.readInt64()
                Hilog.info(0, "CjTelegram", "[AccountPassword] srpB=${r.srpB.size}B, srpId=${r.srpId}")
            }
            
            // hint (flags.3)
            if ((flags & 8) != 0) {
                r.hint = d.readString()
                Hilog.info(0, "CjTelegram", "[AccountPassword] hint: ${r.hint}")
            }
            
            // email_unconfirmed_pattern (flags.4)
            if ((flags & 16) != 0) {
                r.emailUnconfirmedPattern = d.readString()
            }

            // new_algo:PasswordKdfAlgo — always present. Cursor matches
            // SettingsService.parseLoginEmailPattern / Api0.swift PasswordKdfAlgo dict:
            // 982592842 = 0x3a912d4a (ModPow, 4 fields) / -732254058 = 0xd45ab096 (unknown, 0 fields).
            let newAlgoCtor = d.readUInt32()
            Hilog.info(0, "CjTelegram", "[AccountPassword] new_algo constructor: 0x${toHex32(newAlgoCtor)}")
            if (newAlgoCtor == 0x3a912d4a) {
                r.newAlgoSalt1 = d.readBytes()
                r.newAlgoSalt2 = d.readBytes()
                r.newAlgoG = d.readInt32()
                r.newAlgoP = d.readBytes()
                Hilog.info(0, "CjTelegram", "[AccountPassword] new_algo: salt1=${r.newAlgoSalt1.size}B, salt2=${r.newAlgoSalt2.size}B, g=${r.newAlgoG}, p=${r.newAlgoP.size}B")
            } else if (newAlgoCtor == 0xd45ab096) {
                // passwordKdfAlgoUnknown — no fields; do not read salt/g/p.
            } else {
                Hilog.info(0, "CjTelegram", "[AccountPassword] PARSE_FAILED unknown new_algo ctor 0x${toHex32(newAlgoCtor)}")
                return r
            }

            // NotSet has no current_algo. Existing Create Password callers read algo*.
            // Copy next into current slots only when hasPassword=false. Never overwrite
            // current algo*/srp* when hasPassword=true.
            if (!r.hasPassword) {
                r.algoSalt1 = r.newAlgoSalt1
                r.algoSalt2 = r.newAlgoSalt2
                r.algoG = r.newAlgoG
                r.algoP = r.newAlgoP
                Hilog.info(0, "CjTelegram", "[AccountPassword] no current_algo; using new_algo: salt1=${r.algoSalt1.size}B, salt2=${r.algoSalt2.size}B, g=${r.algoG}, p=${r.algoP.size}B")
            }

            // new_secure_algo:SecurePasswordKdfAlgo — always present.
            // Api0.swift: 4883767 = 0x4a8537 (unknown, 0) / -1141711456 = 0xbbf2dda0 (salt)
            // / -2042159726 = 0x86471d92 (salt). Unknown ctor: stop, do not half-decode.
            let newSecureAlgoCtor = d.readUInt32()
            r.newSecureAlgoConstructor = newSecureAlgoCtor
            if (newSecureAlgoCtor == 0x004a8537) {
                // securePasswordKdfAlgoUnknown — no fields.
            } else if (newSecureAlgoCtor == 0xbbf2dda0) {
                r.newSecureAlgoSalt = d.readBytes()
            } else if (newSecureAlgoCtor == 0x86471d92) {
                r.newSecureAlgoSalt = d.readBytes()
            } else {
                Hilog.info(0, "CjTelegram", "[AccountPassword] PARSE_FAILED unknown new_secure_algo ctor 0x${toHex32(newSecureAlgoCtor)}")
                return r
            }

            r.secureRandom = d.readBytes()

            // pending_reset_date (flags.5) / login_email_pattern (flags.6)
            if ((flags & 32) != 0) {
                r.pendingResetDate = d.readInt32()
            }
            if ((flags & 64) != 0) {
                r.loginEmailPattern = d.readString()
            }
            
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AccountPassword] Parse error: ${e}")
        }
        
        return r
    }
}

/**
 * account.ResetPasswordResult 响应
 * resetPasswordOk#e926d63e | resetPasswordRequestedWait#e9effc7d until_date:int | resetPasswordFailedWait#e3779861 retry_date:int
 */
public class AccountResetPasswordResponse {
    public var kind: String = "unknown"  // "ok" | "requestedWait" | "failedWait"
    public var untilDate: Int32 = 0
    public var retryDate: Int32 = 0

    public static func deserialize(data: Array<Byte>): AccountResetPasswordResponse {
        let r = AccountResetPasswordResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()
        if (constructor == 0xe926d63e) {
            r.kind = "ok"
        } else if (constructor == 0xe9effc7d) {
            r.kind = "requestedWait"
            r.untilDate = d.readInt32()
        } else if (constructor == 0xe3779861) {
            r.kind = "failedWait"
            r.retryDate = d.readInt32()
        }
        return r
    }
}

/**
 * auth.LoginToken 响应 (QR code login)
 * auth.loginToken#629f1980 expires:int token:bytes
 * auth.loginTokenMigrateTo#68e9916 dc_id:int token:bytes
 * auth.loginTokenSuccess#390d5c5e authorization:auth.Authorization
 */
public class AuthLoginTokenResponse {
    public var kind: String = "unknown"  // "token" | "migrateTo" | "success"
    public var expires: Int32 = 0
    public var token: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var dcId: Int32 = 0
    public var authorization: Option<UserResponse> = None

    public static func deserialize(data: Array<Byte>): AuthLoginTokenResponse {
        let r = AuthLoginTokenResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()

        if (constructor == 0x629f1980) {
            r.kind = "token"
            r.expires = d.readInt32()
            r.token = d.readBytes()
        } else if (constructor == 0x068e9916) {
            r.kind = "migrateTo"
            r.dcId = d.readInt32()
            r.token = d.readBytes()
        } else if (constructor == 0x390d5c5e) {
            r.kind = "success"
            r.authorization = Some(UserResponse.deserializeBoxed(d))
        }
        return r
    }
}

/**
 * account.TmpPassword 响应
 * account.tmpPassword#db64fd34 tmp_password:bytes valid_until:int
 */
public class AccountTmpPasswordResponse {
    public var tmpPassword: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var validUntil: Int32 = 0

    public static func deserialize(data: Array<Byte>): AccountTmpPasswordResponse {
        let r = AccountTmpPasswordResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()
        if (constructor == 0xdb64fd34) {
            r.tmpPassword = d.readBytes()
            r.validUntil = d.readInt32()
        }
        return r
    }
}

func toHex32(v: UInt32): String {
    let hexChars = "0123456789abcdef"
    let hexRunes = hexChars.toRuneArray()
    var result = ""
    var remaining = v
    for (_i in 0..8) {
        let nibble = Int64((remaining >> 28) & 0xF)
        result = result + hexRunes[nibble].toString()
        remaining = remaining << 4
    }
    return result
}

// ==================== Phase P4-3: contacts.blocked 响应 ====================

/**
 * 屏蔽用户条目
 */
public class BlockedPeerEntry {
    public var peerId: Int64 = 0
    public var date: Int32 = 0
}

/**
 * contacts.blocked / contacts.blockedSlice 响应
 * 
 * contacts.blocked#0ade40ac blocked:Vector<PeerBlocked> chats:Vector<Chat> users:Vector<User>
 * contacts.blockedSlice#e1664194 count:int blocked:Vector<PeerBlocked> chats:Vector<Chat> users:Vector<User>
 * 
 * PeerBlocked#e8fd8014 peer_id:Peer date:int
 */
public class ContactsBlockedResponse {
    public var count: Int32 = 0
    public var blocked: ArrayList<BlockedPeerEntry> = ArrayList<BlockedPeerEntry>()
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()

    public static func deserialize(data: Array<Byte>): ContactsBlockedResponse {
        let r = ContactsBlockedResponse()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()

        // contacts.blocked#0ade1591 (current layer; iOS dict[182326673]=0x0ade1591; 0x0ade40ac kept compat)
        // contacts.blockedSlice#e1664194
        let isSlice = (constructor == 0xe1664194)
        if (constructor != 0x0ade1591 && constructor != 0x0ade40ac && constructor != 0xe1664194) {
            Hilog.info(0, "CjTelegram", "[BlockedResponse] Unknown constructor: ${constructor}")
            return r
        }

        if (isSlice) {
            r.count = d.readInt32()
            Hilog.info(0, "CjTelegram", "[BlockedResponse] blockedSlice, total count = ${r.count}")
        }

        // blocked: Vector<PeerBlocked>
        let blockedVec = d.readUInt32()
        if (blockedVec == TLConstructors.VECTOR) {
            let blockedCount = d.readInt32()
            Hilog.info(0, "CjTelegram", "[BlockedResponse] Parsing ${blockedCount} blocked entries")
            for (_i in 0..Int64(blockedCount)) {
                let entry = BlockedPeerEntry()
                let peerBlockedCtor = d.readUInt32()
                // peerBlocked#e8fd8014 peer_id:Peer date:int
                if (peerBlockedCtor == 0xe8fd8014) {
                    // Peer: peerUser#59511722 user_id:long
                    //        peerChat#36c6019a chat_id:long
                    //        peerChannel#a2a5371e channel_id:long
                    let peerCtor = d.readUInt32()
                    let peerId = d.readInt64()
                    entry.peerId = peerId
                    entry.date = d.readInt32()
                    r.blocked.add(entry)
                }
            }
        }

        // chats: Vector<Chat> — skip
        let chatsVec = d.readUInt32()
        if (chatsVec == TLConstructors.VECTOR) {
            let chatsCount = d.readInt32()
            for (_i in 0..Int64(chatsCount)) {
                try {
                    let _ = ChatResponse.deserializeBoxed(d)
                } catch (_e: Exception) {
                    break
                }
            }
        }

        // users: Vector<User>
        let usersVec = d.readUInt32()
        if (usersVec == TLConstructors.VECTOR) {
            let usersCount = d.readInt32()
            Hilog.info(0, "CjTelegram", "[BlockedResponse] Parsing ${usersCount} users")
            for (_i in 0..Int64(usersCount)) {
                try {
                    r.users.add(UserResponse.deserializeBoxed(d))
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[BlockedResponse] Error parsing user: ${e}")
                    break
                }
            }
        }

        if (!isSlice) {
            r.count = Int32(r.blocked.size)
        }

        Hilog.info(0, "CjTelegram", "[BlockedResponse] Done: ${r.blocked.size} blocked, ${r.users.size} users")
        return r
    }
}

// ==================== help.TermsOfServiceUpdate (TelegramEngine.AccountData) ====================

/**
 * help.getTermsOfServiceUpdate response
 * termsOfServiceUpdateEmpty#e3309f7f expires:int
 * termsOfServiceUpdate#28ecf961 expires:int terms_of_service:help.TermsOfService
 * help.TermsOfService: termsOfService#780a0310 flags:# id:DataJSON text:string entities:Vector<MessageEntity> min_age_confirm:flags.0?int
 */
public class HelpTermsOfServiceUpdateResponse {
    public var hasUpdate: Bool = false
    public var expires: Int32 = 0
    public var termsId: String = ""
    public var text: String = ""

    public static func deserialize(data: Array<Byte>): HelpTermsOfServiceUpdateResponse {
        let r = HelpTermsOfServiceUpdateResponse()
        if (data.size < 8) { return r }
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            return r
        }
        if (constructor == 0xe3309f7f) {
            r.expires = d.readInt32()
            return r
        }
        if (constructor == 0x28ecf961) {
            r.hasUpdate = true
            r.expires = d.readInt32()
            let tosCtor = d.readUInt32()
            if (tosCtor == 0x780a0310) {
                let flags = d.readInt32()
                let dataJsonCtor = d.readUInt32()
                if (dataJsonCtor == 0x7d748d04) {
                    r.termsId = d.readString()
                }
                r.text = d.readString()
                skipMessageEntitiesVector(d)
                if ((flags & 1) != 0) { let _ = d.readInt32() }
            }
        }
        return r
    }
}

// ==================== help.DeepLinkInfo ====================

/**
 * help.DeepLinkInfo 解析结果
 * deepLinkInfo#6a4ee832 flags:# message:string entities:flags.1?Vector<MessageEntity> update_app:flags.2?true = help.DeepLinkInfo
 * deepLinkInfoEmpty#66afa166 = help.DeepLinkInfo (iOS dict[1722786150]=0x66afa166; old 0xde66adb3 kept compat)
 */
public class DeepLinkInfoResponse {
    public var message: String = ""
    public var updateApp: Bool = false

    public static func deserialize(data: Array<Byte>): Option<DeepLinkInfoResponse> {
        if (data.size < 4) { return None }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        // 0x66afa166 = current layer deepLinkInfoEmpty; 0xde66adb3 = old layer, kept compat
        if (ctor == 0x66afa166 || ctor == 0xde66adb3) {
            return None
        }
        if (ctor == 0x6a4ee832) {
            let r = DeepLinkInfoResponse()
            let flags = d.readInt32()
            r.message = d.readString()
            if ((flags & 2) != 0) {
                skipMessageEntitiesVector(d)
            }
            r.updateApp = (flags & 4) != 0
            return Some(r)
        }
        return None
    }
}

// ==================== help.PromoData (help.getPromoData) ====================

/**
 * help.getPromoData 响应
 * help.promoDataEmpty#98f6ac75 expires:int | help.promoData#08a4d87a flags:# ...
 */
public class HelpPromoDataResponse {
    public var pendingSuggestions: ArrayList<String> = ArrayList<String>()
    public var dismissedSuggestions: ArrayList<String> = ArrayList<String>()

    public static func deserialize(data: Array<Byte>): HelpPromoDataResponse {
        let r = HelpPromoDataResponse()
        if (data.size < 4) { return r }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let _ = d.readString()
            return r
        }
        if (ctor == 0x98f6ac75) {
            let _ = d.readInt32()  // expires
            return r
        }
        if (ctor == 0x08a4d87a) {
            let flags = d.readInt32()
            if ((flags & 1) != 0) { let _ = d.readUInt32() }  // proxy
            let _ = d.readInt32()  // expires
            if ((flags & 8) != 0) { skipInputPeer(d) }  // peer
            if ((flags & 2) != 0) { let _ = d.readString() }  // psa_type
            if ((flags & 4) != 0) { let _ = d.readString() }  // psa_message
            readVectorOfStrings(d, r.pendingSuggestions)
            readVectorOfStrings(d, r.dismissedSuggestions)
            if ((flags & 16) != 0) { skipPendingSuggestion(d) }  // custom_pending_suggestion
            skipVector(d)   // chats
            skipVector(d)   // users
        }
        return r
    }
}

func readVectorOfStrings(d: TLDeserializer, out: ArrayList<String>): Unit {
    let vecCtor = d.readUInt32()
    if (vecCtor != TLConstructors.VECTOR) { return }
    let count = d.readInt32()
    for (_i in 0..Int64(count)) {
        out.add(d.readString())
    }
}

func skipPendingSuggestion(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xcd0c5832) {
        let _ = d.readString()  // type
        let _ = d.readString()  // text
        skipVectorOfMessageEntity(d)
    }
}

// ==================== help.AppUpdate (help.getAppUpdate) ====================

/**
 * help.getAppUpdate 响应
 * help.appUpdate#ccbbce30 flags:# can_not_skip:flags.0?true id:int version:string text:string entities:Vector<MessageEntity> document:flags.1?Document url:flags.2?string sticker:flags.3?Document
 * help.noAppUpdate#c45a6536
 */
public class HelpAppUpdateResponse {
    public var hasUpdate: Bool = false
    public var version: String = ""
    public var text: String = ""
    public var url: String = ""
    public var blocking: Bool = false

    public static func deserialize(data: Array<Byte>): HelpAppUpdateResponse {
        let r = HelpAppUpdateResponse()
        if (data.size < 4) { return r }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == 0xc45a6536) {
            return r
        }
        if (ctor == 0xccbbce30) {
            r.hasUpdate = true
            let flags = d.readInt32()
            r.blocking = (flags & 1) != 0
            let _ = d.readInt32()
            r.version = d.readString()
            r.text = d.readString()
            skipMessageEntitiesVector(d)
            // document: flags.1?Document — must skip before url
            if ((flags & 2) != 0) {
                skipDocument(d)
            }
            if ((flags & 4) != 0) {
                r.url = d.readString()
            }
        }
        return r
    }
}

// ==================== Phase TEPNB: Peers Nearby (contacts.getLocated) ====================

/**
 * 附近单个用户/群组条目
 */
public class PeerNearbyEntry {
    public var displayName: String = ""
    public var peerId: Int64 = 0
    public var peerType: String = "user"
    public var distance: Int32 = 0
    public var expires: Int32 = 0
}

/**
 * contacts.getLocated 解析结果
 */
public class PeersNearbyResult {
    public var nearbyUsers: ArrayList<PeerNearbyEntry> = ArrayList<PeerNearbyEntry>()
    public var nearbyGroups: ArrayList<PeerNearbyEntry> = ArrayList<PeerNearbyEntry>()
    public var nearbyChannels: ArrayList<PeerNearbyEntry> = ArrayList<PeerNearbyEntry>()
    public var selfExpires: Int32 = 0
}

/**
 * 解析 contacts.getLocated 返回的 Updates，提取 updatePeerLocated
 */
public func parsePeersNearbyFull(data: Array<Byte>): PeersNearbyResult {
    let r = PeersNearbyResult()
    if (data.size < 8) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0x74ae4240) {
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt32() }
        if ((flags & 2) != 0) { let _ = d.readInt32() }
        if ((flags & 4) != 0) { let _ = d.readInt32() }
        if ((flags & 8) != 0) { let _ = d.readInt32() }
        let updatesCount = d.readInt32()
        var i: Int32 = 0
        while (i < updatesCount) {
            let updateCtor = d.readUInt32()
            if (updateCtor == 0xb4afcfb0 || updateCtor == 0xb4ac292b) {
                let _vecCtor = d.readUInt32()  // VECTOR ctor 0x1cb5c415 — must be consumed before count
                let peersCount = d.readInt32()
                var j: Int32 = 0
                while (j < peersCount) {
                    let peerCtor = d.readUInt32()
                    if (peerCtor == 0xca461b5d) {
                        let entry = PeerNearbyEntry()
                        let peerResp = PeerResponse.deserializeBoxed(d)
                        entry.peerId = peerResp.id
                        entry.peerType = peerResp.type_
                        entry.expires = d.readInt32()
                        entry.distance = d.readInt32()
                        r.nearbyUsers.add(entry)
                    } else if (peerCtor == 0xf8ec284b || peerCtor == 0xd0bc34c8) {
                        r.selfExpires = d.readInt32()
                    } else {
                        skipBoxedObject(d)
                    }
                    j = j + 1
                }
            } else {
                skipUpdateWithConstructor(updateCtor, d)
            }
            i = i + 1
        }
        let usersVecCtor = d.readUInt32()
        if (usersVecCtor == TLConstructors.VECTOR) {
            let usersCount = d.readInt32()
            let userNameMap = HashMap<Int64, String>()
            var ui: Int32 = 0
            while (ui < usersCount) {
                let u = UserResponse.deserializeBoxed(d)
                var name = u.firstName
                if (u.lastName.size > 0) { name = "${name} ${u.lastName}" }
                if (name.size == 0) { name = u.username }
                if (name.size == 0) { name = u.id.toString() }
                userNameMap[u.id] = name
                ui = ui + 1
            }
            for (entry in r.nearbyUsers) {
                if (userNameMap.contains(entry.peerId)) {
                    entry.displayName = userNameMap[entry.peerId]
                }
            }
        }
    }
    return r
}

/**
 * 解析 Updates 中 updatePeerLocated 的 peers 数量（不含 peerSelfLocated）
 */
public func parseUpdatesPeersNearbyCount(data: Array<Byte>): Int32 {
    var count: Int32 = 0
    if (data.size < 8) { return 0 }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0x74ae4240) {
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readInt32() }
        if ((flags & 2) != 0) { let _ = d.readInt32() }
        if ((flags & 4) != 0) { let _ = d.readInt32() }
        if ((flags & 8) != 0) { let _ = d.readInt32() }
        let updatesCount = d.readInt32()
        var i: Int32 = 0
        while (i < updatesCount) {
            let updateCtor = d.readUInt32()
            if (updateCtor == 0xb4afcfb0 || updateCtor == 0xb4ac292b) {
                let _vecCtor = d.readUInt32()  // VECTOR ctor 0x1cb5c415 — must be consumed before count
                let peersCount = d.readInt32()
                var j: Int32 = 0
                while (j < peersCount) {
                    let peerCtor = d.readUInt32()
                    if (peerCtor == 0xca461b5d) {
                        count = count + 1
                        let _ = PeerResponse.deserializeBoxed(d)
                        let _ = d.readInt32()
                        let _ = d.readInt32()
                    } else if (peerCtor == 0xf8ec284b || peerCtor == 0xd0bc34c8) {
                        let _ = d.readInt32()
                    } else {
                        skipBoxedObject(d)
                    }
                    j = j + 1
                }
            } else {
                skipUpdateWithConstructor(updateCtor, d)
            }
            i = i + 1
        }
    }
    return count
}

// ==================== account.Themes response ====================

/**
 * account.themes / account.themesNotModified 容器构造器值取自 Api0.swift 派发表（schema 生成），随 layer 变动；
 * 手写解析点位与请求层协议版本无机械绑定，改动 LAYER 时必须同步核对这两个值。
 * Api0.swift:1403 dict[-1707242387] = account.Themes.parse_themes         ⇒ 0x9a3d8c6d
 * Api0.swift:1404 dict[-199313886]  = account.Themes.parse_themesNotModified ⇒ 0xf41eb622
 */
public let TL_ACCOUNT_THEMES: UInt32 = 0x9a3d8c6d
public let TL_ACCOUNT_THEMES_NOT_MODIFIED: UInt32 = 0xf41eb622

/**
 * 单条 ThemeSettings（Api1.swift 对位，boxed 构造器 0xfa58b6d4）的解析结果。
 * 字段名逐一对齐 TLThemeInfo 既有的单值字段（去掉 `settings`/`wallpaper` 前缀后同名），
 * 不新造命名——`TLThemeInfo` 的单值字段就是 `settingsEntries[0]` 的镜像。
 */
public class TLThemeSettingsEntry {
    public var baseTheme: String = ""
    public var accentColor: Int32 = 0
    public var outboxAccentColor: Int32 = 0
    public var messageColors: Array<UInt32> = Array<UInt32>()
    public var hasWallpaper: Bool = false
    public var wallpaperId: Int64 = 0
    public var wallpaperSlug: String = ""
    public var wallpaperColors: Array<UInt32> = Array<UInt32>()
    public var wallpaperIntensity: Int32 = 0
    public var wallpaperHasIntensity: Bool = false
}

/**
 * 单个 Theme 的基础信息（从 account.themes Vector<Theme> 解析）
 * theme#a00e67d6 flags:# creator:flags.0?true default:flags.1?true for_chat:flags.5?true id:long access_hash:long slug:string title:string
 *   document:flags.2?Document settings:flags.3?Vector<ThemeSettings> emoticon:flags.6?string installs_count:flags.4?int
 */
public class TLThemeInfo {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var slug: String = ""
    public var title: String = ""
    public var isDefault: Bool = false
    public var isCreator: Bool = false
    public var isDark: Bool = false
    public var emoticon: String = ""
    public var hasSettings: Bool = false
    public var settingsBaseTheme: String = ""
    public var settingsAccentColor: Int32 = 0
    // settingsOutboxAccentColor（ThemeSettings.outbox_accent_color, flags.3）：源侧 ApiUtils/Theme.swift:52
    // 同样入模型，本轮下游暂不消费，但同一处解析顺手补齐，避免下一轮再动这段字节游标（诊断报告 M-1c 第1条）。
    public var settingsOutboxAccentColor: Int32 = 0
    // settingsMessageColors（ThemeSettings.message_colors, flags.0）：气泡渐变色数组，按读入顺序，不排序不去重
    // （对位 ApiUtils/Theme.swift:52 messageColors?.map(UInt32.init(bitPattern:))）。
    public var settingsMessageColors: Array<UInt32> = Array<UInt32>()
    public var hasWallpaper: Bool = false
    public var wallpaperId: Int64 = 0
    public var wallpaperSlug: String = ""
    // wallpaperColors（WallPaperSettings 的 background/second/third/fourth_background_color）：壁纸渐变色数组，
    // 按 background→second→third→fourth 顺序 append，只 append 该 flag 位为真的那些
    // （对位 ApiUtils/Wallpaper.swift:13-28 WallpaperSettings.init(apiWallpaperSettings:)）。
    public var wallpaperColors: Array<UInt32> = Array<UInt32>()
    // wallpaperIntensity（WallPaperSettings.intensity, flags.3）：首条 settings 的壁纸强度，与上面的
    // 单值字段同规则——只是 settingsEntries[0] 的镜像，供尚未切到 settingsEntries 的既有消费方直接读取
    // （诊断报告 TC-0507-round7 F-B1/F-B2）。
    public var wallpaperIntensity: Int32 = 0
    public var wallpaperHasIntensity: Bool = false
    // settingsEntries：保留 Vector<ThemeSettings> 的全部元素（此前 :4050 的 `if (!info.hasSettings)` 只留首条，
    // 导致夜间态取不到各主题自己的夜间 ThemeSettings——诊断报告 TC-0507-round7 RC-B）。每条各自带
    // baseTheme/accentColor/outboxAccentColor/messageColors/该条自己的 wallpaper(id/slug/colors/intensity)，
    // 选哪一档（日/夜）交给消费方按 baseTheme 判定，本层不做选择、不做过滤。上面的单值字段保持只镜像首条，
    // 不因本次改动而变化，既有消费方零回归。
    public var settingsEntries: ArrayList<TLThemeSettingsEntry> = ArrayList<TLThemeSettingsEntry>()
}

/**
 * BaseTheme（无字段的 boxed 枚举，Api1.swift:1288-1320）构造器 → 名称
 */
func themeBaseThemeName(ctor: UInt32): String {
    if (ctor == 0x5b11125a) { return "arctic" }
    if (ctor == 0xc3a12462) { return "classic" }
    if (ctor == 0xfbd81688) { return "day" }
    if (ctor == 0xb7b31ea8) { return "night" }
    if (ctor == 0x6d5f77ee) { return "tinted" }
    return ""
}

/**
 * 解析 WallPaperSettings（Api30.swift 对位）的四个背景色（壁纸调色板）+ intensity。
 * 字节消耗量与 TLDialogs.cj:3176 skipWallPaperSettings() 逐字节相同——flags 位布局与读取顺序照抄该函数，
 * 一字不改；只把「读完即弃」改为「收集」（四色 + intensity），rotation/emoticon 仍按原样丢弃（不在本轮范围内）。
 * wallPaperSettings#372efcd0 flags:# blur:flags.1?true motion:flags.2?true background_color:flags.0?int
 *   second_background_color:flags.4?int third_background_color:flags.5?int fourth_background_color:flags.6?int
 *   intensity:flags.3?int rotation:flags.4?int emoticon:flags.7?string
 * （TLMethods.cj:6263-6297 WallPaperSettings 的序列化实现同一构造器、同一字段序，rotation 与
 * second_background_color 共享 flags.4 已在该处核实为协议本身如此，非笔误）。
 * 四色按 background→second→third→fourth 顺序 append，只 append 该 flag 位为真的那些
 * （对位源侧 ApiUtils/Wallpaper.swift:13-28 的 if let … colors.append 序列，诊断报告 M-1c 第4条）。
 * intensity 现在带出（此前恒丢弃）——对位 ApiUtils/Wallpaper.swift:13-28 的 intensity 字段，
 * 供夜间挖空强度使用（诊断报告 TC-0507-round7 F-B1）。
 * 返回：(wallpaperColors, intensity)
 */
func parseWallPaperSettingsColors(d: TLDeserializer): (Array<UInt32>, Int32, Bool) {
    let _ = d.readUInt32()  // constructor
    let flags = d.readInt32()
    let colors = ArrayList<UInt32>()
    if ((flags & 1) != 0) { colors.add(d.readUInt32()) }  // background_color
    if ((flags & 16) != 0) { colors.add(d.readUInt32()) }  // second_background_color
    if ((flags & 32) != 0) { colors.add(d.readUInt32()) }  // third_background_color
    if ((flags & 64) != 0) { colors.add(d.readUInt32()) }  // fourth_background_color
    var intensity: Int32 = 0
    let hasIntensity = (flags & 8) != 0
    if (hasIntensity) { intensity = d.readInt32() }  // intensity（现在带出，不再丢弃）
    if ((flags & 16) != 0) { let _ = d.readInt32() }  // rotation（与 second_background_color 共享 flags.4，不消费）
    if ((flags & 128) != 0) { let _ = d.readString() }  // emoticon（不消费，仅推进游标）
    return (colors.toArray(), intensity, hasIntensity)
}

/**
 * 解析 ThemeSettings.wallpaper（WallPaper，boxed，Api30.swift:1983-2016）的最小可用身份信息（id/slug）
 * 与 WallPaperSettings 调色板 + intensity（诊断报告 M-1c 第3条 / TC-0507-round7 F-B1：原先经
 * skipWallPaperSettings() 读完即弃，现改为 parseWallPaperSettingsColors() 收集）。document 字段仍复用
 * 既有 skipDocument 正确消耗字节，不重复实现。
 * wallPaper#a437c3ed id:long flags:# access_hash:long slug:string document:Document settings:flags.2?WallPaperSettings
 * wallPaperNoFile#e0804116 id:long flags:# settings:flags.2?WallPaperSettings
 * 返回：(id, slug, wallpaperColors, wallpaperIntensity)
 */
func parseThemeWallPaperIdentity(d: TLDeserializer): (Int64, String, Array<UInt32>, Int32, Bool) {
    let constructor = d.readUInt32()
    if (constructor == 0xe0804116) {
        let id = d.readInt64()
        let flags = d.readInt32()
        var colors = Array<UInt32>()
        var intensity: Int32 = 0
        var hasIntensity = false
        if ((flags & 4) != 0) {
            let (c, iv, hasIv) = parseWallPaperSettingsColors(d)
            colors = c
            intensity = iv
            hasIntensity = hasIv
        }
        return (id, "", colors, intensity, hasIntensity)
    }
    // wallPaper#a437c3ed（含未识别构造器的兜底：字段序与 wallPaper 相同）
    let id = d.readInt64()
    let flags = d.readInt32()
    let _ = d.readInt64() // access_hash
    let slug = d.readString()
    skipDocument(d)
    var colors = Array<UInt32>()
    var intensity: Int32 = 0
    var hasIntensity = false
    if ((flags & 4) != 0) {
        let (c, iv, hasIv) = parseWallPaperSettingsColors(d)
        colors = c
        intensity = iv
        hasIntensity = hasIv
    }
    return (id, slug, colors, intensity, hasIntensity)
}

/**
 * 解析 account.getThemes / account.getChatThemes 的响应
 * account.themes#9a3d8c6d hash:long themes:Vector<Theme>
 * account.themesNotModified#f41eb622
 * 返回：(已修改: Bool, hash: Int64, themes: ArrayList<TLThemeInfo>)
 */
public func parseAccountThemesResponse(data: Array<Byte>): (Bool, Int64, ArrayList<TLThemeInfo>) {
    let themes = ArrayList<TLThemeInfo>()
    if (data.size < 4) { return (false, 0, themes) }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TL_ACCOUNT_THEMES_NOT_MODIFIED) {
        // account.themesNotModified — 无变化
        return (false, 0, themes)
    }
    if (ctor != TL_ACCOUNT_THEMES) {
        // 未知构造器，返回空
        return (true, 0, themes)
    }
    // account.themes#9a3d8c6d hash:long themes:Vector<Theme>
    let hash = d.readInt64()
    // D-189: Vector<T> 自身的装箱构造子（0x1cb5c415）必须先读，不能直接把 count
    // 当成紧随 hash 之后的下一个字段（对照本文件 BankCardDataResponse.deserialize）。
    let vecCtor = d.readUInt32()
    if (vecCtor != TLConstructors.VECTOR) {
        // 未识别 Vector<Theme> 构造器，无法安全解析后续元素
        return (true, hash, themes)
    }
    let count = d.readInt32()
    var i: Int32 = 0
    while (i < count) {
        let themeCtor = d.readUInt32()
        if (themeCtor == 0xa00e67d6) {
            let info = TLThemeInfo()
            let flags = d.readInt32()
            info.isCreator = (flags & 1) != 0
            info.isDefault = (flags & 2) != 0
            info.id = d.readInt64()
            info.accessHash = d.readInt64()
            info.slug = d.readString()
            info.title = d.readString()
            // document (optional flags.2) — Document type, skip via skipDocument
            if ((flags & 4) != 0) {
                skipDocument(d)
            }
            // settings (optional flags.3) — Vector<ThemeSettings>；解析首个元素的 baseTheme/accentColor/wallpaper
            if ((flags & 8) != 0) {
                let settingsVecCtor = d.readUInt32()
                if (settingsVecCtor == TLConstructors.VECTOR) {
                    let settingsCount = d.readInt32()
                    var si: Int32 = 0
                    while (si < settingsCount) {
                        let settingsCtor = d.readUInt32()
                        if (settingsCtor == 0xfa58b6d4) {
                            let sFlags = d.readInt32()
                            let baseThemeCtor = d.readUInt32()
                            let baseThemeName = themeBaseThemeName(baseThemeCtor)
                            let accentColor = d.readInt32()
                            var outboxAccentColor: Int32 = 0
                            if ((sFlags & 8) != 0) {
                                outboxAccentColor = d.readInt32() // outbox_accent_color (flags.3)
                            }
                            var messageColors = Array<UInt32>()
                            if ((sFlags & 1) != 0) {
                                // message_colors: Vector<int> (flags.0)，按读入顺序收集，不排序不去重
                                // （对位源侧 ApiUtils/Theme.swift:52 messageColors?.map(UInt32.init(bitPattern:))
                                //   逐元素同序 map，诊断报告 M-1c 第2条）
                                let mcVecCtor = d.readUInt32()
                                if (mcVecCtor == TLConstructors.VECTOR) {
                                    let mcCount = d.readInt32()
                                    let mcList = ArrayList<UInt32>()
                                    var mi: Int32 = 0
                                    while (mi < mcCount) {
                                        mcList.add(d.readUInt32())
                                        mi = mi + 1
                                    }
                                    messageColors = mcList.toArray()
                                }
                            }
                            var wpId: Int64 = 0
                            var wpSlug: String = ""
                            var wpColors = Array<UInt32>()
                            var wpIntensity: Int32 = 0
                            var wpHasIntensity = false
                            var hasWp = false
                            if ((sFlags & 2) != 0) {
                                // wallpaper (flags.1)
                                hasWp = true
                                let (parsedId, parsedSlug, parsedColors, parsedIntensity, parsedHasIntensity) = parseThemeWallPaperIdentity(d)
                                wpId = parsedId
                                wpSlug = parsedSlug
                                wpColors = parsedColors
                                wpIntensity = parsedIntensity
                                wpHasIntensity = parsedHasIntensity
                            }
                            // TC-0507-round7 F-B1：保留 Vector<ThemeSettings> 的全部元素（此前只留首条），
                            // 每条各自带自己的 baseTheme/accentColor/.../wallpaper。这一步在 `if (!info.hasSettings)`
                            // 之外、对每个成功解析的 ThemeSettings 元素都执行，不受首条守卫影响。
                            let entry = TLThemeSettingsEntry()
                            entry.baseTheme = baseThemeName
                            entry.accentColor = accentColor
                            entry.outboxAccentColor = outboxAccentColor
                            entry.messageColors = messageColors
                            entry.hasWallpaper = hasWp
                            entry.wallpaperId = wpId
                            entry.wallpaperSlug = wpSlug
                            entry.wallpaperColors = wpColors
                            entry.wallpaperIntensity = wpIntensity
                            entry.wallpaperHasIntensity = wpHasIntensity
                            info.settingsEntries.add(entry)
                            if (!info.hasSettings) {
                                // 单值字段维持「只镜像首条」的既有语义不变，既有消费方零回归。
                                info.hasSettings = true
                                info.settingsBaseTheme = baseThemeName
                                info.settingsAccentColor = accentColor
                                info.settingsOutboxAccentColor = outboxAccentColor
                                info.settingsMessageColors = messageColors
                                info.hasWallpaper = hasWp
                                info.wallpaperId = wpId
                                info.wallpaperSlug = wpSlug
                                info.wallpaperColors = wpColors
                                info.wallpaperIntensity = wpIntensity
                                info.wallpaperHasIntensity = wpHasIntensity
                            }
                        } else {
                            // 未识别 ThemeSettings 构造器，无法安全跳过其余字节；放弃本 theme 剩余 settings 解析
                            si = settingsCount
                        }
                        si = si + 1
                    }
                }
            }
            // emoticon (optional flags.6)
            if ((flags & 64) != 0) {
                info.emoticon = d.readString()
            }
            // installsCount (optional flags.4)
            if ((flags & 16) != 0) {
                let _ = d.readInt32()
            }
            themes.add(info)
        } else {
            // 未知 theme 格式，跳过
            skipBoxedObject(d)
        }
        i = i + 1
    }
    return (true, hash, themes)
}

// ==================== Payments Responses (telegram_engine_payments) ====================

/**
 * 银行卡 URL 信息
 */
public class BankCardUrlInfo {
    public var title: String = ""
    public var url: String = ""
}

/**
 * 银行卡数据响应（payments.getBankCardData）
 * payments.bankCardData#3e24e573 title:string open_urls:Vector<BankCardOpenUrl>
 */
public class BankCardDataResponse {
    public var title: String = ""
    public var openUrls: ArrayList<BankCardUrlInfo> = ArrayList<BankCardUrlInfo>()
    public var success: Bool = false
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""

    public static func deserialize(data: Array<Byte>): BankCardDataResponse {
        let r = BankCardDataResponse()
        if (data.size < 4) { return r }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            r.errorCode = d.readInt32()
            r.errorMessage = d.readString()
            return r
        }
        // payments.bankCardData#3e24e573
        if (ctor != 0x3e24e573) { return r }
        r.title = d.readString()
        // Vector<BankCardOpenUrl>
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                // bankCardOpenUrl#f568028a url:string name:string
                let urlCtor = d.readUInt32()
                if (urlCtor == 0xf568028a) {
                    let entry = BankCardUrlInfo()
                    entry.url = d.readString()
                    entry.title = d.readString()
                    r.openUrls.add(entry)
                }
                i = i + 1
            }
        }
        r.success = true
        return r
    }
}

/**
 * 价格条目
 */
public class PaymentPriceEntry {
    public var label: String = ""
    public var amount: Int64 = 0
}

/**
 * 支付表单响应（payments.getPaymentForm）
 * payments.paymentForm#a0058751 flags:# can_save_credentials:flags.2?true password_missing:flags.3?true form_id:long bot_id:long title:string description:string photo:flags.5?WebDocument invoice:Invoice provider_id:long url:string native_provider:flags.6?string native_params:flags.6?DataJSON ...
 * payments.paymentFormStars#b0b9c69f (Stars 变体)
 * payments.paymentFormStarGift#9e02c3cf (StarGift 变体)
 */
public class PaymentFormResponse {
    public var success: Bool = false
    public var formId: Int64 = 0
    public var botId: Int64 = 0
    public var title: String = ""
    public var description: String = ""
    public var currency: String = ""
    public var prices: ArrayList<PaymentPriceEntry> = ArrayList<PaymentPriceEntry>()
    public var canSaveCredentials: Bool = false
    public var passwordMissing: Bool = false
    public var url: String = ""
    public var nativeProvider: String = ""
    public var nativeParamsJson: String = ""
    public var isTest: Bool = false
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""

    public static func deserialize(data: Array<Byte>): PaymentFormResponse {
        let r = PaymentFormResponse()
        if (data.size < 4) { return r }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            r.errorCode = d.readInt32()
            r.errorMessage = d.readString()
            return r
        }
        // payments.paymentForm#a0058751
        if (ctor == 0xa0058751) {
            let flags = d.readInt32()
            r.canSaveCredentials = (flags & 4) != 0
            r.passwordMissing = (flags & 8) != 0
            r.formId = d.readInt64()
            r.botId = d.readInt64()
            r.title = d.readString()
            r.description = d.readString()
            // photo (flags.5)
            if ((flags & 32) != 0) { skipBoxedObject(d) }
            // invoice (boxed) — invoice#5db95a15
            let invCtor = d.readUInt32()
            if (invCtor == 0x5db95a15) {
                parseInvoiceFields(d, r)
            }
            let _ = d.readInt64() // provider_id
            r.url = d.readString()
            // native_provider (flags.6)
            if ((flags & 64) != 0) {
                r.nativeProvider = d.readString()
            }
            // native_params (flags.6): dataJSON#7d748d04 data:string
            if ((flags & 64) != 0) {
                let djCtor = d.readUInt32()
                if (djCtor == 0x7d748d04) {
                    r.nativeParamsJson = d.readString()
                }
            }
            r.success = true
        // paymentFormStars: iOS dict[2079764828]=0x7bf6b15c (old 0xb0b9c69f kept compat)
        // paymentFormStarGift: iOS dict[-1272590367]=0xb425cfe1 (old 0x9e02c3cf kept compat)
        } else if (ctor == 0x7bf6b15c || ctor == 0xb425cfe1 || ctor == 0xb0b9c69f || ctor == 0x9e02c3cf) {
            // Stars / StarGift variants — simplified parse
            let flags = d.readInt32()
            let _ = flags
            r.formId = d.readInt64()
            r.botId = d.readInt64()
            r.title = d.readString()
            r.description = d.readString()
            // photo (flags.0 in Stars variant or flags.5)
            if ((flags & 1) != 0 || (flags & 32) != 0) { skipBoxedObject(d) }
            // invoice
            let invCtor2 = d.readUInt32()
            if (invCtor2 == 0x5db95a15) {
                parseInvoiceFields(d, r)
            }
            r.success = true
        }
        return r
    }
}

func parseInvoiceFields(d: TLDeserializer, r: PaymentFormResponse): Unit {
    // invoice#5db95a15 flags:# test:flags.0?true ... currency:string prices:Vector<LabeledPrice>
    let invFlags = d.readInt32()
    r.isTest = (invFlags & 1) != 0
    // Skip name_requested(1), phone_requested(2), email_requested(3), shipping_address_requested(4), flexible(5), phone_to_provider(6), email_to_provider(7), recurring(8)
    r.currency = d.readString()
    // prices: Vector<LabeledPrice>
    let vecCtor = d.readUInt32()
    if (vecCtor == TLConstructors.VECTOR) {
        let priceCount = d.readInt32()
        var pi: Int32 = 0
        while (pi < priceCount) {
            // labeledPrice#cb296bf8 label:string amount:long
            let priceCtor = d.readUInt32()
            if (priceCtor == 0xcb296bf8) {
                let entry = PaymentPriceEntry()
                entry.label = d.readString()
                entry.amount = d.readInt64()
                r.prices.add(entry)
            }
            pi = pi + 1
        }
    }
    // max_tip_amount (flags.8)
    if ((invFlags & 256) != 0) { let _ = d.readInt64() }
    // suggested_tip_amounts (flags.8): Vector<long>
    if ((invFlags & 256) != 0) {
        let stvc = d.readUInt32()
        if (stvc == TLConstructors.VECTOR) {
            let stc = d.readInt32()
            var si: Int32 = 0
            while (si < stc) { let _ = d.readInt64(); si = si + 1 }
        }
    }
    // terms_url (flags.10)
    if ((invFlags & 1024) != 0) { let _ = d.readString() }
    // subscription_period (flags.9)
    if ((invFlags & 512) != 0) { let _ = d.readInt32() }
}

/**
 * payments.ValidatedRequestedInfo — 验证请求信息响应
 * payments.validatedRequestedInfo#d1451883 flags:# id:flags.0?string shipping_options:flags.1?Vector<ShippingOption>
 */
public class ValidatedRequestedInfoResponse {
    public var success: Bool = false
    public var validatedInfoId: String = ""
    public var shippingOptions: ArrayList<ShippingOptionInfo> = ArrayList<ShippingOptionInfo>()
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public class ShippingOptionInfo {
    public var id: String = ""
    public var title: String = ""
    public var prices: ArrayList<PaymentPriceEntry> = ArrayList<PaymentPriceEntry>()
}

public func parseValidatedRequestedInfo(data: Array<Byte>): ValidatedRequestedInfoResponse {
    let r = ValidatedRequestedInfoResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    // payments.validatedRequestedInfo#d1451883
    if (ctor != 0xd1451883) { return r }
    let flags = d.readInt32()
    if ((flags & 1) != 0) { r.validatedInfoId = d.readString() }
    if ((flags & 2) != 0) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                // shippingOption#b6213cdf id:string title:string prices:Vector<LabeledPrice>
                let optCtor = d.readUInt32()
                if (optCtor == 0xb6213cdf) {
                    let opt = ShippingOptionInfo()
                    opt.id = d.readString()
                    opt.title = d.readString()
                    let pvc = d.readUInt32()
                    if (pvc == TLConstructors.VECTOR) {
                        let pc = d.readInt32()
                        var pi: Int32 = 0
                        while (pi < pc) {
                            let lpCtor = d.readUInt32()
                            if (lpCtor == 0xcb296bf8) {
                                let pe = PaymentPriceEntry()
                                pe.label = d.readString()
                                pe.amount = d.readInt64()
                                opt.prices.add(pe)
                            }
                            pi = pi + 1
                        }
                    }
                    r.shippingOptions.add(opt)
                }
                i = i + 1
            }
        }
    }
    r.success = true
    return r
}

/**
 * 支付结果响应（payments.sendPaymentForm）
 * payments.paymentResult#4e5f810d updates:Updates
 * payments.paymentVerificationNeeded#d8411139 url:string
 */
public class PaymentResultResponse {
    public var success: Bool = false
    public var verificationRequired: Bool = false
    public var verificationUrl: String = ""
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
    public var priceChanged: Bool = false
    public var updatedPrice: Int64 = 0
    public var updatedCurrency: String = ""
}

public func parsePaymentResult(data: Array<Byte>): PaymentResultResponse {
    let r = PaymentResultResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    // payments.paymentResult#4e5f810d
    if (ctor == 0x4e5f810d) {
        r.success = true
        return r
    }
    // payments.paymentVerificationNeeded#d8411139 url:string
    if (ctor == 0xd8411139) {
        r.verificationRequired = true
        r.verificationUrl = d.readString()
        r.success = true
        return r
    }
    return r
}

/**
 * 支付收据响应（payments.getPaymentReceipt）
 * payments.paymentReceipt#70c4fe03 flags:# date:int bot_id:long provider_id:long title:string description:string photo:flags.2?WebDocument invoice:Invoice info:flags.0?PaymentRequestedInfo shipping:flags.1?ShippingOption tip_amount:flags.3?long currency:string total_amount:long credentials_title:string users:Vector<User>
 * payments.paymentReceiptStars#daf0f42 ...
 */
public class PaymentReceiptResponse {
    public var success: Bool = false
    public var date: Int32 = 0
    public var botId: Int64 = 0
    public var title: String = ""
    public var description: String = ""
    public var currency: String = ""
    public var totalAmount: Int64 = 0
    public var credentialsTitle: String = ""
    public var prices: ArrayList<PaymentPriceEntry> = ArrayList<PaymentPriceEntry>()
    public var transactionId: String = ""
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""

    public static func deserialize(data: Array<Byte>): PaymentReceiptResponse {
        let r = PaymentReceiptResponse()
        if (data.size < 4) { return r }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            r.errorCode = d.readInt32()
            r.errorMessage = d.readString()
            return r
        }
        // payments.paymentReceipt#70c4fe03
        if (ctor == 0x70c4fe03) {
            let flags = d.readInt32()
            r.date = d.readInt32()
            r.botId = d.readInt64()
            let _ = d.readInt64() // provider_id
            r.title = d.readString()
            r.description = d.readString()
            // photo (flags.2)
            if ((flags & 4) != 0) { skipBoxedObject(d) }
            // invoice (boxed)
            let invCtor = d.readUInt32()
            if (invCtor == 0x5db95a15) {
                let _ = d.readInt32() // invFlags
                let _ = d.readString() // currency (parse after)
                let vecCtor = d.readUInt32()
                if (vecCtor == TLConstructors.VECTOR) {
                    let pc = d.readInt32()
                    var pi: Int32 = 0
                    while (pi < pc) {
                        let lpCtor = d.readUInt32()
                        if (lpCtor == 0xcb296bf8) {
                            let pe = PaymentPriceEntry()
                            pe.label = d.readString()
                            pe.amount = d.readInt64()
                            r.prices.add(pe)
                        }
                        pi = pi + 1
                    }
                }
            }
            // info (flags.0)
            if ((flags & 1) != 0) { skipBoxedObject(d) }
            // shipping (flags.1)
            if ((flags & 2) != 0) { skipBoxedObject(d) }
            // tip_amount (flags.3)
            if ((flags & 8) != 0) { let _ = d.readInt64() }
            r.currency = d.readString()
            r.totalAmount = d.readInt64()
            r.credentialsTitle = d.readString()
            r.success = true
        // paymentReceiptStars: iOS dict[-625215430]=0xdabbf83a (old 0x0daf0f42 kept compat)
        } else if (ctor == 0xdabbf83a || ctor == 0x0daf0f42) {
            // payments.paymentReceiptStars variant
            let flags = d.readInt32()
            let _ = flags
            r.date = d.readInt32()
            r.botId = d.readInt64()
            r.title = d.readString()
            r.description = d.readString()
            // photo (flags.2)
            if ((flags & 4) != 0) { skipBoxedObject(d) }
            // invoice
            let invCtor2 = d.readUInt32()
            if (invCtor2 == 0x5db95a15) {
                let _ = d.readInt32()
                let _ = d.readString()
                let vecCtor2 = d.readUInt32()
                if (vecCtor2 == TLConstructors.VECTOR) {
                    let pc2 = d.readInt32()
                    var pi2: Int32 = 0
                    while (pi2 < pc2) {
                        let lpCtor2 = d.readUInt32()
                        if (lpCtor2 == 0xcb296bf8) {
                            let pe2 = PaymentPriceEntry()
                            pe2.label = d.readString()
                            pe2.amount = d.readInt64()
                            r.prices.add(pe2)
                        }
                        pi2 = pi2 + 1
                    }
                }
            }
            r.currency = d.readString()
            r.totalAmount = d.readInt64()
            r.transactionId = d.readString()
            r.success = true
        }
        return r
    }
}

// ==================== Phase P2-152: 2FA Password Layer ====================

/**
 * TwoStepVerificationConfig — typed 2FA configuration
 * Derived from account.password#957b50fb (deserialized via AccountPasswordResponse)
 * iOS ref: TwoStepVerificationConfiguration enum in TelegramEngineAuth.swift
 */
public class TwoStepVerificationConfig {
    public var hasPassword: Bool = false
    public var hint: String = ""
    public var hasRecoveryEmail: Bool = false
    public var hasSecureValues: Bool = false
    public var emailUnconfirmedPattern: String = ""
    public var pendingResetDate: Int32 = 0
    // SRP params (only meaningful if hasPassword)
    public var srpId: Int64 = 0
    public var srpB: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var algoSalt1: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var algoSalt2: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var algoG: Int32 = 0
    public var algoP: Array<Byte> = Array<Byte>(0, repeat: 0)
}

/**
 * AccountPasswordSettingsResponse — response from account.getPasswordSettings
 *
 * account.passwordSettings#9a5c33e5
 *   flags:# email:flags.0?string secure_settings:flags.1?SecureSecretSettings = account.PasswordSettings
 *
 * secureSecretSettings#1527bcac
 *   secure_algo:SecurePasswordKdfAlgo secure_secret:bytes secure_secret_id:long = SecureSecretSettings
 *   (tl_codegen verified: 0x9a5c33e5, 0x1527bcac)
 *
 * iOS ref: _internal_requestTwoStepVerifiationSettings TwoStepVerification.swift:60-88
 */
public class AccountPasswordSettingsResponse {
    public var email: String = ""
    public var hasSecureSettings: Bool = false
    // SecureSecretSettings fields (secureSecretSettings#1527bcac)
    public var secureSecret: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var secureSecretId: Int64 = 0
    // SecurePasswordKdfAlgo variant (algo type)
    // securePasswordKdfAlgoPBKDF2HMACSHA512iter100000#bbf2dda0 salt:bytes
    // securePasswordKdfAlgoSHA512#86471d92 salt:bytes
    // securePasswordKdfAlgoUnknown#4a8537
    public var secureAlgoType: Int32 = 0  // 0=unknown, 1=PBKDF2HMACSHA512, 2=SHA512
    public var secureAlgoSalt: Array<Byte> = Array<Byte>(0, repeat: 0)

    public static func deserialize(data: Array<Byte>): AccountPasswordSettingsResponse {
        let r = AccountPasswordSettingsResponse()
        let d = TLDeserializer(data)
        try {
            let ctor = d.readUInt32()
            Hilog.info(0, "CjTelegram", "[PasswordSettings] ctor: 0x${toHex32(ctor)}")
            if (ctor != 0x9a5c33e5) {
                Hilog.info(0, "CjTelegram", "[PasswordSettings] Unexpected ctor, expected account.passwordSettings")
                return r
            }
            let flags = d.readInt32()
            // email: flags.0?string
            if ((flags & 1) != 0) {
                r.email = d.readString()
                Hilog.info(0, "CjTelegram", "[PasswordSettings] email: ${r.email}")
            }
            // secure_settings: flags.1?SecureSecretSettings
            if ((flags & 2) != 0) {
                r.hasSecureSettings = true
                let ssCtor = d.readUInt32()
                if (ssCtor == 0x1527bcac) {
                    // secureSecretSettings: secure_algo + secure_secret + secure_secret_id
                    let algoCtor = d.readUInt32()
                    if (algoCtor == 0xbbf2dda0) {
                        r.secureAlgoType = 1  // PBKDF2HMACSHA512
                        r.secureAlgoSalt = d.readBytes()
                    } else if (algoCtor == 0x86471d92) {
                        r.secureAlgoType = 2  // SHA512
                        r.secureAlgoSalt = d.readBytes()
                    } else {
                        r.secureAlgoType = 0  // unknown
                    }
                    r.secureSecret = d.readBytes()
                    r.secureSecretId = d.readInt64()
                    Hilog.info(0, "CjTelegram", "[PasswordSettings] secureSecret: ${r.secureSecret.size}B id=${r.secureSecretId}")
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PasswordSettings] Parse error: ${e}")
        }
        return r
    }
}

/**
 * CachedTwoStepPasswordToken — cached 2FA token for payment/reuse
 * Mirrors iOS TemporaryTwoStepPasswordToken (TwoStepVerification.swift:340-390)
 * Stored in Preferences with timestamp for expiry check.
 * key "2fa_cached_token" = base64(tmpPassword)
 * key "2fa_token_valid_until" = Int64(validUntil epoch seconds)
 */
public class CachedTwoStepPasswordToken {
    public var tmpPassword: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var validUntil: Int32 = 0
}

// ==================== P2-155: Stars 生态读核心 TL 响应类型 ====================

/**
 * starsAmount#bbb6b4a3 amount:long nanos:int = StarsAmount
 * tl_codegen verified: 0xbbb6b4a3
 * iOS ref: StarsAmount(apiAmount:) in Stars.swift:351-353
 * 注意: balance 不是裸 long — 是 starsAmount 结构体 (amount:long nanos:int)
 * nanos 表示星的小数部分 (预留精度，目前通常为 0)
 */
public class StarsAmountData {
    public var amount: Int64 = 0
    public var nanos: Int32 = 0
    public var isTon: Bool = false
}

func parseStarsAmount(d: TLDeserializer): StarsAmountData {
    let r = StarsAmountData()
    let ctor = d.readUInt32()
    if (ctor == 0xbbb6b4a3) {
        r.amount = d.readInt64()
        r.nanos = d.readInt32()
    } else if (ctor == 0x74aee3e0) {
        r.amount = d.readInt64()
        r.isTon = true
    }
    return r
}

/**
 * StarsTransactionPeer variants (peer type for starsTransaction.peer)
 * starsTransactionPeerUnsupported#95f2bfe4
 * starsTransactionPeerAppStore#b457b375
 * starsTransactionPeerPlayMarket#7b560a0b
 * starsTransactionPeerPremiumBot#250dbaf8
 * starsTransactionPeerFragment#e92fd902
 * starsTransactionPeer#d80da15d peer:Peer
 * starsTransactionPeerAds#60682812
 * starsTransactionPeerAPI#f9677aad
 * iOS ref: StarsContext.State.Transaction.Peer (Stars.swift:68-100)
 */
public class StarsTransactionPeerData {
    public var peerType: String = "unknown"
    public var peerId: Int64 = 0
}

func parseStarsTransactionPeer(d: TLDeserializer): StarsTransactionPeerData {
    let r = StarsTransactionPeerData()
    let ctor = d.readUInt32()
    if (ctor == 0x95f2bfe4) {
        r.peerType = "unsupported"
    } else if (ctor == 0xb457b375) {
        r.peerType = "appStore"
    } else if (ctor == 0x7b560a0b) {
        r.peerType = "playMarket"
    } else if (ctor == 0x250dbaf8) {
        r.peerType = "premiumBot"
    } else if (ctor == 0xe92fd902) {
        r.peerType = "fragment"
    } else if (ctor == 0xd80da15d) {
        r.peerType = "peer"
        let peerResponse = PeerResponse.deserializeBoxed(d)
        r.peerId = peerResponse.id
    } else if (ctor == 0x60682812) {
        r.peerType = "ads"
    } else if (ctor == 0xf9677aad) {
        r.peerType = "api"
    }
    return r
}

/**
 * starsTransaction#13659eb0 flags:# ... id:string stars:StarsAmount date:int peer:StarsTransactionPeer
 *   title:flags.0?string description:flags.1?string photo:flags.2?WebDocument
 *   transaction_date:flags.5?int transaction_url:flags.5?string ... = StarsTransaction
 * iOS dict[325426864]=0x13659eb0 (current layer); old 0xa39fd94a kept compat
 * iOS ref: StarsContext.State.Transaction (Stars.swift:103-230)
 */
public class StarsTransactionEntry {
    public var id: String = ""
    public var starsAmount: Int64 = 0
    public var starsNanos: Int32 = 0
    public var date: Int32 = 0
    public var peer: StarsTransactionPeerData = StarsTransactionPeerData()
    public var title: String = ""
    public var description: String = ""
    public var transactionDate: Int32 = 0
    public var transactionUrl: String = ""
    public var isRefund: Bool = false
    public var isPending: Bool = false
    public var isFailed: Bool = false
}

func parseStarsTransaction(d: TLDeserializer): StarsTransactionEntry {
    let r = StarsTransactionEntry()
    let ctor = d.readUInt32()
    // 0x13659eb0 = current layer (iOS dict[325426864]); 0xa39fd94a = old layer, kept compat
    if (ctor != 0x13659eb0 && ctor != 0xa39fd94a) { return r }
    let flags = d.readInt32()
    r.isRefund = (flags & 8) != 0
    r.isPending = (flags & 16) != 0
    r.isFailed = (flags & 64) != 0
    r.id = d.readString()
    let amt = parseStarsAmount(d)
    r.starsAmount = amt.amount
    r.starsNanos = amt.nanos
    r.date = d.readInt32()
    r.peer = parseStarsTransactionPeer(d)
    if ((flags & 1) != 0) { r.title = d.readString() }
    if ((flags & 2) != 0) { r.description = d.readString() }
    if ((flags & 4) != 0) { skipBoxedObject(d) }
    if ((flags & 32) != 0) { r.transactionDate = d.readInt32() }
    if ((flags & 32) != 0) { r.transactionUrl = d.readString() }
    if ((flags & 128) != 0) { let _ = d.readBytes() }
    if ((flags & 256) != 0) { let _ = d.readInt32() }
    if ((flags & 512) != 0) { skipVector(d) }
    if ((flags & 4096) != 0) { let _ = d.readInt32() }
    if ((flags & 8192) != 0) { let _ = d.readInt32() }
    if ((flags & 16384) != 0) { skipBoxedObject(d) }
    if ((flags & 32768) != 0) { let _ = d.readInt32() }
    if ((flags & 65536) != 0) { let _ = d.readInt32() }
    if ((flags & 131072) != 0) { let _ = PeerResponse.deserializeBoxed(d); let _ = parseStarsAmount(d) }
    if ((flags & 524288) != 0) { let _ = d.readInt32() }
    if ((flags & 1048576) != 0) { let _ = d.readInt32() }
    if ((flags & 2097152) != 0) {}
    if ((flags & 4194304) != 0) {}
    return r
}

/**
 * starsTopupOption#0bd915c0 flags:# extended:flags.1?true stars:long store_product:flags.0?string
 *   currency:string amount:long = StarsTopupOption
 * tl_codegen verified: 0x0bd915c0
 * iOS ref: StarsTopUpOption (Stars.swift:61-126)
 */
public class StarsTopupOptionEntry {
    public var stars: Int64 = 0
    public var storeProduct: String = ""
    public var currency: String = ""
    public var amount: Int64 = 0
    public var isExtended: Bool = false
}

func parseStarsTopupOption(d: TLDeserializer): StarsTopupOptionEntry {
    let r = StarsTopupOptionEntry()
    let ctor = d.readUInt32()
    if (ctor != 0x0bd915c0) { return r }
    let flags = d.readInt32()
    r.isExtended = (flags & 2) != 0
    r.stars = d.readInt64()
    if ((flags & 1) != 0) { r.storeProduct = d.readString() }
    r.currency = d.readString()
    r.amount = d.readInt64()
    return r
}

/**
 * starsGiftOption#5e0589f1 flags:# extended:flags.1?true stars:long store_product:flags.0?string
 *   currency:string amount:long = StarsGiftOption
 * tl_codegen verified: 0x5e0589f1
 * iOS ref: StarsGiftOption (Stars.swift:128-175)
 */
public class StarsGiftOptionEntry {
    public var stars: Int64 = 0
    public var storeProduct: String = ""
    public var currency: String = ""
    public var amount: Int64 = 0
    public var isExtended: Bool = false
}

func parseStarsGiftOption(d: TLDeserializer): StarsGiftOptionEntry {
    let r = StarsGiftOptionEntry()
    let ctor = d.readUInt32()
    if (ctor != 0x5e0589f1) { return r }
    let flags = d.readInt32()
    r.isExtended = (flags & 2) != 0
    r.stars = d.readInt64()
    if ((flags & 1) != 0) { r.storeProduct = d.readString() }
    r.currency = d.readString()
    r.amount = d.readInt64()
    return r
}

/**
 * payments.starsStatus#6c9ce8ed flags:# balance:StarsAmount
 *   subscriptions:flags.1?Vector<StarsSubscription>
 *   subscriptions_next_offset:flags.2?string
 *   subscriptions_missing_balance:flags.4?long
 *   history:flags.3?Vector<StarsTransaction>
 *   next_offset:flags.0?string
 *   chats:Vector<Chat> users:Vector<User> = payments.StarsStatus
 * tl_codegen verified: 0x6c9ce8ed
 * iOS ref: _internal_requestStarsState parse block (Stars.swift:470-549)
 * Outer wrapper: payments.starsStatus (this is the direct response ctor)
 * Inner: StarsAmount (balance) + Vector<StarsTransaction> (history) + Vector<User/Chat>
 */
public class StarsStatusResponse {
    public var success: Bool = false
    public var balanceAmount: Int64 = 0
    public var balanceNanos: Int32 = 0
    public var nextOffset: String = ""
    public var transactions: ArrayList<StarsTransactionEntry> = ArrayList<StarsTransactionEntry>()
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseStarsStatus(data: Array<Byte>): StarsStatusResponse {
    let r = StarsStatusResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    if (ctor != 0x6c9ce8ed) { return r }
    let flags = d.readInt32()
    let bal = parseStarsAmount(d)
    r.balanceAmount = bal.amount
    r.balanceNanos = bal.nanos
    if ((flags & 2) != 0) {
        let subVec = d.readUInt32()
        if (subVec == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            var si: Int32 = 0
            while (si < cnt) {
                skipBoxedObject(d)
                si = si + 1
            }
        }
    }
    if ((flags & 4) != 0) { let _ = d.readString() }
    if ((flags & 16) != 0) { let _ = d.readInt64() }
    if ((flags & 8) != 0) {
        let histVec = d.readUInt32()
        if (histVec == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            var hi: Int32 = 0
            while (hi < cnt) {
                let tx = parseStarsTransaction(d)
                r.transactions.add(tx)
                hi = hi + 1
            }
        }
    }
    if ((flags & 1) != 0) { r.nextOffset = d.readString() }
    let chatsVec = d.readUInt32()
    if (chatsVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var ci: Int32 = 0
        while (ci < cnt) {
            let _ = ChatResponse.deserializeBoxed(d)
            ci = ci + 1
        }
    }
    let usersVec = d.readUInt32()
    if (usersVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var ui: Int32 = 0
        while (ui < cnt) {
            let _ = UserResponse.deserializeBoxed(d)
            ui = ui + 1
        }
    }
    r.success = true
    return r
}

/**
 * Vector<StarsTopupOption> 响应（payments.getStarsTopupOptions 返回值）
 * 外层是裸 Vector (0x1cb5c415)，内含 starsTopupOption#0bd915c0 条目
 */
public class StarsTopupOptionsResponse {
    public var success: Bool = false
    public var options: ArrayList<StarsTopupOptionEntry> = ArrayList<StarsTopupOptionEntry>()
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseStarsTopupOptions(data: Array<Byte>): StarsTopupOptionsResponse {
    let r = StarsTopupOptionsResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    if (ctor != TLConstructors.VECTOR) { return r }
    let cnt = d.readInt32()
    var i: Int32 = 0
    while (i < cnt) {
        let opt = parseStarsTopupOption(d)
        r.options.add(opt)
        i = i + 1
    }
    r.success = true
    return r
}

/**
 * Vector<StarsGiftOption> 响应（payments.getStarsGiftOptions 返回值）
 * 外层是裸 Vector (0x1cb5c415)，内含 starsGiftOption#5e0589f1 条目
 */
public class StarsGiftOptionsResponse {
    public var success: Bool = false
    public var options: ArrayList<StarsGiftOptionEntry> = ArrayList<StarsGiftOptionEntry>()
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseStarsGiftOptions(data: Array<Byte>): StarsGiftOptionsResponse {
    let r = StarsGiftOptionsResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    if (ctor != TLConstructors.VECTOR) { return r }
    let cnt = d.readInt32()
    var i: Int32 = 0
    while (i < cnt) {
        let opt = parseStarsGiftOption(d)
        r.options.add(opt)
        i = i + 1
    }
    r.success = true
    return r
}

/**
 * AccountSentEmailCodeResponse — response from account.sendVerifyEmailCode
 * account.sentEmailCode#811f854f email_pattern:string length:int = account.SentEmailCode
 * (tl_codegen verified: 0x811f854f)
 */
public class AccountSentEmailCodeResponse {
    public var emailPattern: String = ""
    public var length: Int32 = 0

    public static func deserialize(data: Array<Byte>): AccountSentEmailCodeResponse {
        let r = AccountSentEmailCodeResponse()
        let d = TLDeserializer(data)
        try {
            let ctor = d.readUInt32()
            if (ctor == 0x811f854f) {
                r.emailPattern = d.readString()
                r.length = d.readInt32()
                Hilog.info(0, "CjTelegram", "[SentEmailCode] emailPattern=${r.emailPattern} len=${r.length}")
            } else {
                Hilog.info(0, "CjTelegram", "[SentEmailCode] Unexpected ctor: 0x${toHex32(ctor)}")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SentEmailCode] Parse error: ${e}")
        }
        return r
    }
}

/**
 * AccountEmailVerifiedResponse — response from account.verifyEmail
 * account.emailVerified#2b96cd1b email:string = account.EmailVerified
 * account.emailVerifiedLogin#e1bb0d61 email:string sent_code:auth.SentCode = account.EmailVerified
 * (tl_codegen verified: 0x2b96cd1b, 0xe1bb0d61)
 * iOS ref: verifyLoginEmailChange Authorization.swift:856
 */
public class AccountEmailVerifiedResponse {
    public var verified: Bool = false
    public var email: String = ""
    public var isLoginVariant: Bool = false  // true if emailVerifiedLogin
}

public func deserializeAccountEmailVerified(data: Array<Byte>): AccountEmailVerifiedResponse {
    let r = AccountEmailVerifiedResponse()
    let d = TLDeserializer(data)
    try {
        let ctor = d.readUInt32()
        if (ctor == 0x2b96cd1b) {
            r.verified = true
            r.email = d.readString()
            Hilog.info(0, "CjTelegram", "[EmailVerified] verified, email=${r.email}")
        } else if (ctor == 0xe1bb0d61) {
            r.verified = true
            r.isLoginVariant = true
            r.email = d.readString()
            Hilog.info(0, "CjTelegram", "[EmailVerified] emailVerifiedLogin, email=${r.email}")
        } else {
            Hilog.info(0, "CjTelegram", "[EmailVerified] Unexpected ctor: 0x${toHex32(ctor)}")
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[EmailVerified] Parse error: ${e}")
    }
    return r
}

// ==================== P2-156: Privacy + Session Management Responses ====================

/**
 * GlobalPrivacySettingsResponse
 * Parses: globalPrivacySettings#fe41b34f (tl_codegen verified, telegram_api.tl:1347)
 *   flags:# bit0=archive_and_mute_new_noncontact_peers  bit1=keep_archived_unmuted
 *           bit2=keep_archived_folders                  bit3=hide_read_marks
 *           bit4=new_noncontact_peers_require_premium   bit7=display_gifts_button
 *           bit5=noncontact_peers_paid_stars:long(opt)  bit6=disallowed_gifts(opt,skip)
 */
public class GlobalPrivacySettingsResponse {
    public var archiveAndMuteNewNoncontactPeers: Bool = false
    public var keepArchivedUnmuted: Bool = false
    public var keepArchivedFolders: Bool = false
    public var hideReadMarks: Bool = false
    public var newNoncontactPeersRequirePremium: Bool = false
    public var displayGiftsButton: Bool = false
    public var noncontactPeersPaidStars: Int64 = 0

    public static func deserialize(data: Array<Byte>): GlobalPrivacySettingsResponse {
        let r = GlobalPrivacySettingsResponse()
        if (data.size < 8) { return r }
        let d = TLDeserializer(data)
        try {
            let ctor = d.readUInt32()
            if (ctor == 0xfe41b34f) {
                let flags = d.readInt32()
                r.archiveAndMuteNewNoncontactPeers = (flags & 1) != 0
                r.keepArchivedUnmuted = (flags & 2) != 0
                r.keepArchivedFolders = (flags & 4) != 0
                r.hideReadMarks = (flags & 8) != 0
                r.newNoncontactPeersRequirePremium = (flags & 16) != 0
                if ((flags & 32) != 0) {
                    r.noncontactPeersPaidStars = d.readInt64()
                }
                if ((flags & 64) != 0) {
                    let _ = d.readUInt32()  // disallowedGiftsSettings#71f276c4 ctor
                    let _ = d.readInt32()   // disallowedGiftsSettings flags:# (inner flags word)
                }
                r.displayGiftsButton = (flags & 128) != 0
                Hilog.info(0, "CjTelegram", "[GlobalPrivacy] parsed: archiveMute=${r.archiveAndMuteNewNoncontactPeers} keepUnmuted=${r.keepArchivedUnmuted} hideReads=${r.hideReadMarks} requirePremium=${r.newNoncontactPeersRequirePremium}")
            } else {
                Hilog.info(0, "CjTelegram", "[GlobalPrivacy] unexpected ctor: 0x${toHex32(ctor)}")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[GlobalPrivacy] parse error: ${e}")
        }
        return r
    }
}

/**
 * AuthorizationInfo — one session entry from account.authorizations
 * Parses: authorization#ad01d61d (tl_codegen verified, telegram_api.tl:639)
 *   flags:# current:0 official_app:1 password_pending:2
 *           encrypted_requests_disabled:3 call_requests_disabled:4 unconfirmed:5
 *   hash:long device_model:string platform:string system_version:string
 *   api_id:int app_name:string app_version:string
 *   date_created:int date_active:int ip:string country:string region:string
 */
public class AuthorizationInfo {
    public var isCurrent: Bool = false
    public var isOfficialApp: Bool = false
    public var isUnconfirmed: Bool = false
    // authorization#ad01d61d flags.2 password_pending / flags.3 encrypted_requests_disabled /
    // flags.4 call_requests_disabled, and api_id (iOS RecentAccountSession.swift:107-122).
    public var passwordPending: Bool = false
    public var encryptedRequestsDisabled: Bool = false
    public var callRequestsDisabled: Bool = false
    public var apiId: Int32 = 0
    public var hash: Int64 = 0
    public var deviceModel: String = ""
    public var platform: String = ""
    public var systemVersion: String = ""
    public var appName: String = ""
    public var appVersion: String = ""
    public var dateCreated: Int32 = 0
    public var dateActive: Int32 = 0
    public var ip: String = ""
    public var country: String = ""
    public var region: String = ""
}

/**
 * AccountAuthorizationsResponse — outer wrapper
 * Parses: account.authorizations#4bff8ea0 (tl_codegen verified, telegram_api.tl:641)
 *   authorization_ttl_days:int authorizations:Vector<Authorization>
 */
public class AccountAuthorizationsResponse {
    public var authorizationTtlDays: Int32 = 0
    public var sessions: ArrayList<AuthorizationInfo> = ArrayList<AuthorizationInfo>()

    public static func deserialize(data: Array<Byte>): AccountAuthorizationsResponse {
        let r = AccountAuthorizationsResponse()
        if (data.size < 8) { return r }
        let d = TLDeserializer(data)
        try {
            let outerCtor = d.readUInt32()
            if (outerCtor != 0x4bff8ea0) {
                Hilog.info(0, "CjTelegram", "[Authorizations] unexpected outer ctor: 0x${toHex32(outerCtor)}")
                return r
            }
            r.authorizationTtlDays = d.readInt32()
            let vecCtor = d.readUInt32()
            if (vecCtor != 0x1cb5c415) {
                Hilog.info(0, "CjTelegram", "[Authorizations] expected vector ctor, got: 0x${toHex32(vecCtor)}")
                return r
            }
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                let itemCtor = d.readUInt32()
                if (itemCtor == 0xad01d61d) {
                    let info = AuthorizationInfo()
                    let flags = d.readInt32()
                    info.isCurrent = (flags & 1) != 0
                    info.isOfficialApp = (flags & 2) != 0
                    info.isUnconfirmed = (flags & 32) != 0
                    info.passwordPending = (flags & 4) != 0
                    info.encryptedRequestsDisabled = (flags & 8) != 0
                    info.callRequestsDisabled = (flags & 16) != 0
                    info.hash = d.readInt64()
                    info.deviceModel = d.readString()
                    info.platform = d.readString()
                    info.systemVersion = d.readString()
                    info.apiId = d.readInt32()
                    info.appName = d.readString()
                    info.appVersion = d.readString()
                    info.dateCreated = d.readInt32()
                    info.dateActive = d.readInt32()
                    info.ip = d.readString()
                    info.country = d.readString()
                    info.region = d.readString()
                    r.sessions.add(info)
                } else {
                    Hilog.info(0, "CjTelegram", "[Authorizations] unknown session ctor: 0x${toHex32(itemCtor)}, stopping")
                    i = count
                }
                i = i + 1
            }
            Hilog.info(0, "CjTelegram", "[Authorizations] parsed ${r.sessions.size} sessions, ttl=${r.authorizationTtlDays}d")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[Authorizations] parse error: ${e}")
        }
        return r
    }
}

/**
 * WebAuthorizationInfo — one web session entry
 * Parses: webAuthorization#a6f8f452 (tl_codegen verified, telegram_api.tl:1088)
 *   hash:long bot_id:long domain:string browser:string platform:string
 *   date_created:int date_active:int ip:string region:string
 */
public class WebAuthorizationInfo {
    public var hash: Int64 = 0
    public var botId: Int64 = 0
    public var domain: String = ""
    public var browser: String = ""
    public var platform: String = ""
    public var dateCreated: Int32 = 0
    public var dateActive: Int32 = 0
    public var ip: String = ""
    public var region: String = ""
}

/**
 * AccountWebAuthorizationsResponse — outer wrapper
 * Parses: account.webAuthorizations#ed56c9fc (tl_codegen verified, telegram_api.tl:1090)
 *   authorizations:Vector<WebAuthorization> users:Vector<User>
 */
public class AccountWebAuthorizationsResponse {
    public var sessions: ArrayList<WebAuthorizationInfo> = ArrayList<WebAuthorizationInfo>()

    public static func deserialize(data: Array<Byte>): AccountWebAuthorizationsResponse {
        let r = AccountWebAuthorizationsResponse()
        if (data.size < 8) { return r }
        let d = TLDeserializer(data)
        try {
            let outerCtor = d.readUInt32()
            if (outerCtor != 0xed56c9fc) {
                Hilog.info(0, "CjTelegram", "[WebAuthorizations] unexpected outer ctor: 0x${toHex32(outerCtor)}")
                return r
            }
            let vecCtor = d.readUInt32()
            if (vecCtor != 0x1cb5c415) {
                Hilog.info(0, "CjTelegram", "[WebAuthorizations] expected vector ctor, got: 0x${toHex32(vecCtor)}")
                return r
            }
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                let itemCtor = d.readUInt32()
                if (itemCtor == 0xa6f8f452) {
                    let info = WebAuthorizationInfo()
                    info.hash = d.readInt64()
                    info.botId = d.readInt64()
                    info.domain = d.readString()
                    info.browser = d.readString()
                    info.platform = d.readString()
                    info.dateCreated = d.readInt32()
                    info.dateActive = d.readInt32()
                    info.ip = d.readString()
                    info.region = d.readString()
                    r.sessions.add(info)
                } else {
                    Hilog.info(0, "CjTelegram", "[WebAuthorizations] unknown ctor: 0x${toHex32(itemCtor)}, stopping")
                    i = count
                }
                i = i + 1
            }
            Hilog.info(0, "CjTelegram", "[WebAuthorizations] parsed ${r.sessions.size} web sessions")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[WebAuthorizations] parse error: ${e}")
        }
        return r
    }
}

/**
 * NewAuthorizationUpdate — parsed from updateNewAuthorization#8951abef
 * TL (tl_codegen verified, telegram_api.tl:327):
 *   flags:# unconfirmed:flags.0?true hash:long
 *   date:flags.0?int device:flags.0?string location:flags.0?string = Update
 * All optional fields share bit 0 — if unconfirmed is set, the rest are present.
 */
public class NewAuthorizationUpdate {
    public var isUnconfirmed: Bool = false
    public var hash: Int64 = 0
    public var date: Int32 = 0
    public var device: String = ""
    public var location: String = ""
}

public func deserializeNewAuthorizationUpdate(data: Array<Byte>): Option<NewAuthorizationUpdate> {
    if (data.size < 8) { return None }
    let d = TLDeserializer(data)
    try {
        let ctor = d.readUInt32()
        if (ctor != 0x8951abef) { return None }
        let info = NewAuthorizationUpdate()
        let flags = d.readInt32()
        info.isUnconfirmed = (flags & 1) != 0
        info.hash = d.readInt64()
        if ((flags & 1) != 0) {
            info.date = d.readInt32()
            info.device = d.readString()
            info.location = d.readString()
        }
        Hilog.info(0, "CjTelegram", "[NewAuth] hash=${info.hash} unconfirmed=${info.isUnconfirmed} device=${info.device}")
        return Some(info)
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[NewAuth] parse error: ${e}")
        return None
    }
}

/**
 * PrivacyRulesResponse — full parsed account.privacyRules#50a04e45
 * Parses the complete rule set including all PrivacyRule variants.
 * TL schema (telegram_api.tl:598-609, 611):
 *   privacyValueAllowAll#65427b82
 *   privacyValueAllowContacts#fffe1bac
 *   privacyValueDisallowAll#8b73e763
 *   privacyValueDisallowContacts#f888fa1a
 *   privacyValueAllowCloseFriends#f7e8d89b
 *   privacyValueAllowPremium#ece9814b
 *   privacyValueAllowBots#21461b5d
 *   privacyValueDisallowBots#f6a5f82f
 *   privacyValueAllowUsers#b8905fb2        users:Vector<long>
 *   privacyValueDisallowUsers#e4621141     users:Vector<long>
 *   privacyValueAllowChatParticipants#6b134e8e   chats:Vector<long>
 *   privacyValueDisallowChatParticipants#41c87565 chats:Vector<long>
 */
public class PrivacyRulesResponse {
    // Reduction is a state machine over the two allow rules only (allowAll / allowContacts),
    // never a "last rule wins" fold — see PrivacySettings.swift:221-284 `current`.
    // Default with no allow rule present is "nobody" (source: current = .disableEveryone).
    public var primaryValue: String = "nobody"
    public var allowUsers: ArrayList<Int64> = ArrayList<Int64>()
    public var disallowUsers: ArrayList<Int64> = ArrayList<Int64>()
    public var allowChats: ArrayList<Int64> = ArrayList<Int64>()
    public var disallowChats: ArrayList<Int64> = ArrayList<Int64>()
    public var hasCloseFriends: Bool = false
    public var hasPremiumOnly: Bool = false
    public var hasBots: Bool = false
    // true only if the rule loop ran to completion without error; false on any early
    // return or parse exception. Callers must not trust primaryValue/flags when false.
    public var parsed: Bool = false
    // Peer weight tables from the response's trailing chats/users vectors (TL:
    // account.privacyRules#50a04e45 rules chats users). userCount source for
    // exception-count labels: presence in peerUserIds => weight 1; presence in
    // peerChatUserCounts => weight is the chat/channel participant count.
    // A peer id absent from both tables must be treated as "not counted", matching
    // source's `peers[id]`-miss-drops behavior (PrivacySettings.swift:238-244).
    public var peerUserIds: HashMap<Int64, Bool> = HashMap<Int64, Bool>()
    public var peerChatUserCounts: HashMap<Int64, Int64> = HashMap<Int64, Int64>()

    public static func deserialize(data: Array<Byte>): PrivacyRulesResponse {
        let r = PrivacyRulesResponse()
        if (data.size < 8) { return r }
        let d = TLDeserializer(data)
        try {
            let outerCtor = d.readUInt32()
            if (outerCtor != 0x50a04e45) {
                Hilog.info(0, "CjTelegram", "[PrivacyRules] unexpected ctor: 0x${toHex32(outerCtor)}")
                return r
            }
            let vecCtor = d.readUInt32()
            if (vecCtor != 0x1cb5c415) { return r }
            let ruleCount = d.readInt32()
            var i: Int32 = 0
            // Guards the trailing chats/users vectors below: only safe to read them
            // when every rule ctor in the loop was recognized (byte offset trustworthy).
            var rulesComplete = true
            while (i < ruleCount) {
                let ruleCtor = d.readUInt32()
                if (ruleCtor == 0x65427b82) {
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] rule 0x${toHex32(ruleCtor)}")
                    r.primaryValue = "everybody"
                } else if (ruleCtor == 0xfffe1bac) {
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] rule 0x${toHex32(ruleCtor)}")
                    r.primaryValue = "contacts"
                } else if (ruleCtor == 0x8b73e763) {
                    // disallowAll: does not participate in the reduction (source: break).
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] rule 0x${toHex32(ruleCtor)}")
                } else if (ruleCtor == 0xf888fa1a) {
                    // disallowContacts: does not participate in the reduction (source: break).
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] rule 0x${toHex32(ruleCtor)}")
                } else if (ruleCtor == 0xf7e8d89b) {
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] rule 0x${toHex32(ruleCtor)}")
                    r.hasCloseFriends = true
                } else if (ruleCtor == 0xece9814b) {
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] rule 0x${toHex32(ruleCtor)}")
                    r.hasPremiumOnly = true
                } else if (ruleCtor == 0x21461b5d) {
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] rule 0x${toHex32(ruleCtor)}")
                    r.hasBots = true
                } else if (ruleCtor == 0xf6a5f82f) {
                    // disallowBots: does not participate in the reduction (source: break).
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] rule 0x${toHex32(ruleCtor)}")
                } else if (ruleCtor == 0xb8905fb2) {
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] rule 0x${toHex32(ruleCtor)}")
                    let uVec = d.readUInt32()
                    if (uVec == 0x1cb5c415) {
                        let uCount = d.readInt32()
                        var j: Int32 = 0
                        while (j < uCount) {
                            r.allowUsers.add(d.readInt64())
                            j = j + 1
                        }
                    }
                } else if (ruleCtor == 0xe4621141) {
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] rule 0x${toHex32(ruleCtor)}")
                    let uVec = d.readUInt32()
                    if (uVec == 0x1cb5c415) {
                        let uCount = d.readInt32()
                        var j: Int32 = 0
                        while (j < uCount) {
                            r.disallowUsers.add(d.readInt64())
                            j = j + 1
                        }
                    }
                } else if (ruleCtor == 0x6b134e8e) {
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] rule 0x${toHex32(ruleCtor)}")
                    let cVec = d.readUInt32()
                    if (cVec == 0x1cb5c415) {
                        let cCount = d.readInt32()
                        var j: Int32 = 0
                        while (j < cCount) {
                            r.allowChats.add(d.readInt64())
                            j = j + 1
                        }
                    }
                } else if (ruleCtor == 0x41c87565) {
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] rule 0x${toHex32(ruleCtor)}")
                    let cVec = d.readUInt32()
                    if (cVec == 0x1cb5c415) {
                        let cCount = d.readInt32()
                        var j: Int32 = 0
                        while (j < cCount) {
                            r.disallowChats.add(d.readInt64())
                            j = j + 1
                        }
                    }
                } else {
                    // Unrecognized ctor: the TL stream has no generic-payload skip for
                    // PrivacyRule, so stopping here is the only safe choice.
                    Hilog.info(0, "CjTelegram", "[PrivacyRules] unknown rule ctor: 0x${toHex32(ruleCtor)}, stopping")
                    i = ruleCount
                    rulesComplete = false
                }
                i = i + 1
            }
            // account.privacyRules#50a04e45 rules:Vector<PrivacyRule> chats:Vector<Chat>
            // users:Vector<User> — the rules vector above was only ever consumed, never
            // the two trailing vectors (Api32.swift:18-40 serialize order: rules, chats,
            // users). Precedent for this exact shape: ContactsResolvedPeerResponse
            // (TLResponses.cj:1875-1889) reads chats then users the same way.
            if (rulesComplete) {
                let chatsVecCtor = d.readUInt32()
                if (chatsVecCtor == 0x1cb5c415) {
                    let chatsCount = d.readInt32()
                    var ci: Int32 = 0
                    while (ci < chatsCount) {
                        let chat = ChatResponse.deserializeBoxed(d)
                        // Channel participants_count is flags.17-optional on the wire;
                        // when absent it falls back to 1 (source: SelectivePrivacyPeer
                        // for a TelegramChannel has no participantCount => userCount
                        // falls to the `else { return 1 }` branch, PrivacySettings.swift:28-36).
                        // Legacy chat/chatEmpty/chatForbidden take participantsCount as-is
                        // (ApiGroupOrChannel.swift:69-106; ChatResponse defaults it to 0
                        // for the empty/forbidden ctors, matching source).
                        let userCount: Int64 = if (chat.isChannel) {
                            if (chat.participantsCount > 0) { Int64(chat.participantsCount) } else { 1 }
                        } else {
                            Int64(chat.participantsCount)
                        }
                        r.peerChatUserCounts[chat.id] = userCount
                        ci = ci + 1
                    }
                }
                let usersVecCtor = d.readUInt32()
                if (usersVecCtor == 0x1cb5c415) {
                    let usersCount = d.readInt32()
                    var ui: Int32 = 0
                    while (ui < usersCount) {
                        // Not gated on ctor kind: source treats userEmpty the same as a
                        // resolved TelegramUser for peer weighting (userCount == 1).
                        let user = UserResponse.deserializeBoxed(d)
                        r.peerUserIds[user.id] = true
                        ui = ui + 1
                    }
                }
            }
            r.parsed = true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyRules] parse error: ${e}")
        }
        return r
    }
}

// ==================== Phase P2-152b: Passkey / FIDO2 Response Types ====================

/**
 * PasskeyInfo — one registered passkey entry.
 * Parses: passkey#98613ebf flags:# id:string name:string date:int
 *   softwareEmojiId:flags.0?long lastUsageDate:flags.1?int
 * iOS ref: Api20.swift parse_passkey; ctor -1738457409 -> 0x98613ebf
 */
public class PasskeyInfo {
    public var id: String = ""
    public var name: String = ""
    public var date: Int32 = 0
    public var softwareEmojiId: Int64 = 0
    public var hasSoftwareEmojiId: Bool = false
    public var lastUsageDate: Int32 = 0
    public var hasLastUsageDate: Bool = false
}

/**
 * AccountPasskeysResponse — wraps account.getPasskeys response.
 * Parses: account.passkeys#f8e0aa1c passkeys:Vector<Passkey>
 * iOS ref: Api31.swift parse_passkeys; ctor -119494116 -> 0xf8e0aa1c
 */
public class AccountPasskeysResponse {
    public var passkeys: ArrayList<PasskeyInfo> = ArrayList<PasskeyInfo>()

    public static func deserialize(data: Array<Byte>): AccountPasskeysResponse {
        let r = AccountPasskeysResponse()
        if (data.size < 8) { return r }
        let d = TLDeserializer(data)
        try {
            let outerCtor = d.readUInt32()
            if (outerCtor != 0xf8e0aa1c) {
                Hilog.info(0, "CjTelegram", "[Passkeys] unexpected outer ctor: 0x${toHex32(outerCtor)}")
                return r
            }
            let vecCtor = d.readUInt32()
            if (vecCtor != TLConstructors.VECTOR) {
                Hilog.info(0, "CjTelegram", "[Passkeys] expected vector ctor, got: 0x${toHex32(vecCtor)}")
                return r
            }
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                let itemCtor = d.readUInt32()
                if (itemCtor == 0x98613ebf) {
                    let info = PasskeyInfo()
                    let flags = d.readInt32()
                    info.id = d.readString()
                    info.name = d.readString()
                    info.date = d.readInt32()
                    if ((flags & 1) != 0) {
                        info.softwareEmojiId = d.readInt64()
                        info.hasSoftwareEmojiId = true
                    }
                    if ((flags & 2) != 0) {
                        info.lastUsageDate = d.readInt32()
                        info.hasLastUsageDate = true
                    }
                    r.passkeys.add(info)
                } else {
                    Hilog.info(0, "CjTelegram", "[Passkeys] unknown passkey ctor: 0x${toHex32(itemCtor)}, stopping")
                    i = count
                }
                i = i + 1
            }
            Hilog.info(0, "CjTelegram", "[Passkeys] parsed ${r.passkeys.size} passkeys")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[Passkeys] parse error: ${e}")
        }
        return r
    }
}

/**
 * PasskeyRegistrationOptionsResponse — wraps account.initPasskeyRegistration response.
 * Parses: account.passkeyRegistrationOptions#e16b5ce1 options:DataJSON
 * DataJSON#7d748d04 data:string
 * iOS ref: Api31.swift parse_passkeyRegistrationOptions; ctor -513057567 -> 0xe16b5ce1
 * The options JSON is a WebAuthn PublicKeyCredentialCreationOptions object.
 */
public class PasskeyRegistrationOptionsResponse {
    public var optionsJson: String = ""

    public static func deserialize(data: Array<Byte>): PasskeyRegistrationOptionsResponse {
        let r = PasskeyRegistrationOptionsResponse()
        if (data.size < 8) { return r }
        let d = TLDeserializer(data)
        try {
            let outerCtor = d.readUInt32()
            if (outerCtor != 0xe16b5ce1) {
                Hilog.info(0, "CjTelegram", "[PasskeyRegOptions] unexpected outer ctor: 0x${toHex32(outerCtor)}")
                return r
            }
            // DataJSON#7d748d04 data:string (boxed)
            let dataCtor = d.readUInt32()
            if (dataCtor == 0x7d748d04) {
                r.optionsJson = d.readString()
            }
            Hilog.info(0, "CjTelegram", "[PasskeyRegOptions] options json length=${r.optionsJson.size}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PasskeyRegOptions] parse error: ${e}")
        }
        return r
    }
}

/**
 * PasskeyLoginOptionsResponse — wraps auth.initPasskeyLogin response.
 * Parses: auth.passkeyLoginOptions#e2037789 options:DataJSON
 * DataJSON#7d748d04 data:string
 * iOS ref: Api33.swift parse_passkeyLoginOptions; ctor -503089271 -> 0xe2037789
 * The options JSON is a WebAuthn PublicKeyCredentialRequestOptions object.
 */
public class PasskeyLoginOptionsResponse {
    public var optionsJson: String = ""

    public static func deserialize(data: Array<Byte>): PasskeyLoginOptionsResponse {
        let r = PasskeyLoginOptionsResponse()
        if (data.size < 8) { return r }
        let d = TLDeserializer(data)
        try {
            let outerCtor = d.readUInt32()
            if (outerCtor != 0xe2037789) {
                Hilog.info(0, "CjTelegram", "[PasskeyLoginOptions] unexpected outer ctor: 0x${toHex32(outerCtor)}")
                return r
            }
            // DataJSON#7d748d04 data:string (boxed)
            let dataCtor = d.readUInt32()
            if (dataCtor == 0x7d748d04) {
                r.optionsJson = d.readString()
            }
            Hilog.info(0, "CjTelegram", "[PasskeyLoginOptions] options json length=${r.optionsJson.size}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PasskeyLoginOptions] parse error: ${e}")
        }
        return r
    }
}

// ==================== P2-155b: Star Gifts TL 响应类型 ====================

/**
 * StarGift 类型 (两个变体) — 当前 iOS layer (Api26.swift:1195-1427, Api0.swift:1045-1046):
 *
 * starGift#313a9547 (signed 825922887) flags:int id:long sticker:Document(boxed) stars:long
 *   availabilityRemains:flags.0?int availabilityTotal:flags.0?int availabilityResale:flags.4?long
 *   convertStars:long firstSaleDate:flags.1?int lastSaleDate:flags.1?int
 *   upgradeStars:flags.3?long resellMinStars:flags.4?long title:flags.5?string
 *   releasedBy:flags.6?Peer(boxed) perUserTotal:flags.8?int perUserRemains:flags.8?int
 *   lockedUntilDate:flags.9?int auctionSlug:flags.11?string giftsPerRound:flags.11?int
 *   auctionStartDate:flags.11?int upgradeVariants:flags.12?int
 *   background:flags.13?StarGiftBackground(boxed) = StarGift
 *
 * starGiftUnique#85f0a9cd (signed -2047825459) flags:int id:long giftId:long title:string
 *   slug:string num:int ownerId:flags.0?Peer(boxed) ownerName:flags.1?string
 *   ownerAddress:flags.2?string attributes:Vector<StarGiftAttribute>(boxed)
 *   availabilityIssued:int availabilityTotal:int giftAddress:flags.3?string
 *   resellAmount:flags.4?Vector<StarsAmount>(boxed) releasedBy:flags.5?Peer(boxed)
 *   valueAmount:flags.8?long valueCurrency:flags.8?string valueUsdAmount:flags.8?long
 *   themePeer:flags.10?Peer(boxed) peerColor:flags.11?PeerColor(boxed)
 *   hostId:flags.12?Peer(boxed) offerMinStars:flags.13?int
 *   craftChancePermille:flags.16?int = StarGift
 *
 * iOS ref: Api26.swift:1195-1427, Api0.swift:1045-1046
 * P2-155h: aligned from stale 0xc62aca28/0x6411db89 to current layer 0x313a9547/0x85f0a9cd
 */
public class StarGiftEntry {
    public var isUnique: Bool = false
    public var id: Int64 = 0
    public var stars: Int64 = 0
    public var convertStars: Int64 = 0
    public var upgradeStars: Int64 = 0
    public var resellMinStars: Int64 = 0
    public var resellStars: Int64 = 0
    public var resellTon: Int64 = 0
    public var isLimited: Bool = false
    public var isSoldOut: Bool = false
    public var isBirthday: Bool = false
    public var requiresPremium: Bool = false
    public var isAuction: Bool = false
    public var availabilityRemains: Int32 = 0
    public var availabilityTotal: Int32 = 0
    public var availabilityResale: Int64 = 0
    public var perUserTotal: Int32 = 0
    public var perUserRemains: Int32 = 0
    public var lockedUntilDate: Int32 = 0
    public var auctionSlug: String = ""
    public var auctionGiftsPerRound: Int32 = 0
    public var auctionStartDate: Int32 = 0
    public var upgradeVariantsCount: Int32 = 0
    public var title: String = ""
    public var slug: String = ""
    public var num: Int32 = 0
    public var ownerId: Int64 = 0
    public var ownerType: String = ""
    public var ownerName: String = ""
    public var ownerAddress: String = ""
    public var availabilityIssued: Int32 = 0
    public var availabilityUniqueTotal: Int32 = 0
    public var valueAmount: Int64 = 0
    public var valueCurrency: String = ""
    public var valueUsdAmount: Int64 = 0
    public var collectibleColorId: Int64 = 0
    public var peerColorAvailable: Bool = false
    public var documentId: Int64 = 0
    public var documentAccessHash: Int64 = 0
    public var documentFileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var documentDcId: Int32 = 0
    public var documentMimeType: String = ""
    public var documentSize: Int64 = 0
    public var modelName: String = ""
    public var backdropName: String = ""
    public var patternName: String = ""
    public var backdropId: Int32 = 0
    public var centerColor: Int32 = 0
    public var edgeColor: Int32 = 0
    public var patternColor: Int32 = 0
    public var textColor: Int32 = 0
}

func parseStarGiftDocument(d: TLDeserializer, gift: StarGiftEntry): Unit {
    let constructor = d.readUInt32()
    if (constructor == 0x36f8c871) { gift.documentId = d.readInt64(); return }
    let flags = d.readInt32()
    gift.documentId = d.readInt64()
    gift.documentAccessHash = d.readInt64()
    gift.documentFileReference = d.readBytes()
    let _ = d.readInt32()
    gift.documentMimeType = d.readString()
    gift.documentSize = d.readInt64()
    if ((flags & 1) != 0) {
        let vector = d.readUInt32()
        if (vector == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { skipPhotoSize(d) }
        }
    }
    if ((flags & 2) != 0) {
        let vector = d.readUInt32()
        if (vector == TLConstructors.VECTOR) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) { skipVideoSize(d) }
        }
    }
    gift.documentDcId = d.readInt32()
    let attributes = d.readUInt32()
    if (attributes == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_i in 0..Int64(count)) { skipDocumentAttribute(d) }
    }
}

func parseUniqueStarGiftAttribute(d: TLDeserializer, gift: StarGiftEntry): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x9f2504e4) {
        gift.backdropName = d.readString()
        gift.backdropId = d.readInt32()
        gift.centerColor = d.readInt32()
        gift.edgeColor = d.readInt32()
        gift.patternColor = d.readInt32()
        gift.textColor = d.readInt32()
        skipStarGiftAttributeRarityBoxed(d)
    } else if (ctor == 0x565251e2) {
        let _ = d.readInt32()
        gift.modelName = d.readString()
        parseStarGiftDocument(d, gift)
        skipStarGiftAttributeRarityBoxed(d)
    } else if (ctor == 0x4e7085ea) {
        gift.patternName = d.readString()
        skipDocument(d)
        skipStarGiftAttributeRarityBoxed(d)
    } else if (ctor == 0xe0bff26c) {
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        let _ = PeerResponse.deserializeBoxed(d)
        let _ = d.readInt32()
        if ((flags & 2) != 0) { skipTextWithEntities(d) }
    }
}

func parseStarGift(d: TLDeserializer): StarGiftEntry {
    let r = StarGiftEntry()
    let ctor = d.readUInt32()
    if (ctor == 0x313a9547 || ctor == 0x80ac53c3 || ctor == 0xc62aca28) {
        // starGift#313a9547 — current iOS layer (Api26.swift:1195, Api0.swift:1045 dict[825922887])
        let flags = d.readInt32()
        r.isLimited = (flags & 0x1) != 0
        r.isSoldOut = (flags & 0x2) != 0
        r.isBirthday = (flags & 0x4) != 0
        r.requiresPremium = (flags & 0x80) != 0
        r.isAuction = (flags & 0x800) != 0
        r.peerColorAvailable = (flags & 0x400) != 0
        r.id = d.readInt64()
        parseStarGiftDocument(d, r)
        r.stars = d.readInt64()
        // flags.0: availabilityRemains + availabilityTotal
        if ((flags & 0x1) != 0) { r.availabilityRemains = d.readInt32() }
        if ((flags & 0x1) != 0) { r.availabilityTotal = d.readInt32() }
        // flags.4: availabilityResale
        if ((flags & 0x10) != 0) { r.availabilityResale = d.readInt64() }
        // convertStars (always)
        r.convertStars = d.readInt64()
        // flags.1: firstSaleDate + lastSaleDate (skip)
        if ((flags & 0x2) != 0) { let _ = d.readInt32() }
        if ((flags & 0x2) != 0) { let _ = d.readInt32() }
        // flags.3: upgradeStars
        if ((flags & 0x8) != 0) { r.upgradeStars = d.readInt64() }
        // flags.4: resellMinStars
        if ((flags & 0x10) != 0) { r.resellMinStars = d.readInt64() }
        // flags.5: title
        if ((flags & 0x20) != 0) { r.title = d.readString() }
        if (ctor == 0x313a9547) {
            // Fields introduced after starGift#c62aca28.
            if ((flags & 0x40) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
            if ((flags & 0x100) != 0) { r.perUserTotal = d.readInt32() }
            if ((flags & 0x100) != 0) { r.perUserRemains = d.readInt32() }
            if ((flags & 0x200) != 0) { r.lockedUntilDate = d.readInt32() }
            if ((flags & 0x800) != 0) { r.auctionSlug = d.readString() }
            if ((flags & 0x800) != 0) { r.auctionGiftsPerRound = d.readInt32() }
            if ((flags & 0x800) != 0) { r.auctionStartDate = d.readInt32() }
            if ((flags & 0x1000) != 0) { r.upgradeVariantsCount = d.readInt32() }
            if ((flags & 0x2000) != 0) {
                let bgCtor = d.readUInt32()
                if (bgCtor == 0xaff56398) {
                    r.centerColor = d.readInt32()
                    r.edgeColor = d.readInt32()
                    r.textColor = d.readInt32()
                }
            }
        } else if (ctor == 0x80ac53c3) {
            // Layer 216 variant: released_by, per-user limits and lock date,
            // but no auction/background fields yet.
            if ((flags & 0x40) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
            if ((flags & 0x100) != 0) { r.perUserTotal = d.readInt32() }
            if ((flags & 0x100) != 0) { r.perUserRemains = d.readInt32() }
            if ((flags & 0x200) != 0) { r.lockedUntilDate = d.readInt32() }
        }
    } else if (ctor == 0x6411db89) {
        // starGiftUnique#6411db89 — older negotiated layer, without collectible PeerColor.
        r.isUnique = true
        let flags = d.readInt32()
        r.id = d.readInt64()
        r.title = d.readString()
        r.slug = d.readString()
        r.num = d.readInt32()
        if ((flags & 0x1) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        if ((flags & 0x2) != 0) { let _ = d.readString() }
        if ((flags & 0x4) != 0) { let _ = d.readString() }
        let attrVec = d.readUInt32()
        if (attrVec == TLConstructors.VECTOR) {
            let attrCnt = d.readInt32()
            for (_i in 0..Int64(attrCnt)) { parseUniqueStarGiftAttribute(d, r) }
        }
        let _ = d.readInt32()
        let _ = d.readInt32()
        if ((flags & 0x8) != 0) { let _ = d.readString() }
        if ((flags & 0x10) != 0) { r.resellStars = d.readInt64() }
    } else if (ctor == 0x85f0a9cd) {
        // starGiftUnique#85f0a9cd — current iOS layer (Api26.swift:1309, Api0.swift:1046 dict[-2047825459])
        r.isUnique = true
        let flags = d.readInt32()
        r.id = d.readInt64()
        // giftId (Int64) — new mandatory field in current layer (Api26.swift:1313-1315)
        let _ = d.readInt64()
        r.title = d.readString()
        r.slug = d.readString()
        r.num = d.readInt32()
        // flags.0: ownerId Peer(boxed)
        if ((flags & 0x1) != 0) {
            let owner = PeerResponse.deserializeBoxed(d)
            r.ownerId = owner.id
            r.ownerType = owner.type_
        }
        // flags.1: ownerName
        if ((flags & 0x2) != 0) { r.ownerName = d.readString() }
        // flags.2: ownerAddress
        if ((flags & 0x4) != 0) { r.ownerAddress = d.readString() }
        // attributes: Vector<StarGiftAttribute>(boxed) — always present (Api26.swift:1336-1339)
        let attrVec = d.readUInt32()
        if (attrVec == TLConstructors.VECTOR) {
            let attrCnt = d.readInt32()
            for (_i in 0..Int64(attrCnt)) {
                parseUniqueStarGiftAttribute(d, r)
            }
        }
        // availabilityIssued + availabilityTotal (always)
        r.availabilityIssued = d.readInt32()
        r.availabilityUniqueTotal = d.readInt32()
        // flags.3: giftAddress
        if ((flags & 0x8) != 0) { let _ = d.readString() }
        // flags.4: resellAmount Vector<StarsAmount>(boxed) — was resellStars:long in old layer
        if ((flags & 0x10) != 0) {
            let rsVec = d.readUInt32()
            if (rsVec == TLConstructors.VECTOR) {
                let rsCnt = d.readInt32()
                for (_i in 0..Int64(rsCnt)) {
                    let amount = parseStarsAmount(d)
                    if (amount.isTon && r.resellTon == 0) { r.resellTon = amount.amount }
                    if (!amount.isTon && r.resellStars == 0) { r.resellStars = amount.amount }
                }
            }
        }
        // flags.5: releasedBy Peer(boxed) — new in current layer (Api26.swift:1354-1358)
        if ((flags & 0x20) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        // flags.8: valueAmount + valueCurrency + valueUsdAmount — new (Api26.swift:1360-1371)
        if ((flags & 0x100) != 0) { r.valueAmount = d.readInt64() }
        if ((flags & 0x100) != 0) { r.valueCurrency = d.readString() }
        if ((flags & 0x100) != 0) { r.valueUsdAmount = d.readInt64() }
        // flags.10: themePeer Peer(boxed) — new (Api26.swift:1372-1377)
        if ((flags & 0x400) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        // flags.11: peerColor PeerColor(boxed) — new (Api26.swift:1378-1383)
        if ((flags & 0x800) != 0) { r.collectibleColorId = parsePeerColorCollectibleId(d) }
        // flags.12: hostId Peer(boxed) — new (Api26.swift:1384-1389)
        if ((flags & 0x1000) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        // flags.13: offerMinStars — new (Api26.swift:1390-1393)
        if ((flags & 0x2000) != 0) { let _ = d.readInt32() }
        // flags.16: craftChancePermille — new (Api26.swift:1394-1397)
        if ((flags & 0x10000) != 0) { let _ = d.readInt32() }
    } else {
        Hilog.info(0, "CjTelegram", "[parseStarGift] unknown constructor=0x${toHex32(ctor)} offset=${d.getOffset()}")
    }
    return r
}

/**
 * savedStarGift#dfda0499 flags:#
 *   name_hidden:flags.0?true unsaved:flags.5?true refunded:flags.9?true
 *   can_upgrade:flags.10?true pinned_to_top:flags.12?true
 *   from_id:flags.1?Peer date:int gift:StarGift
 *   message:flags.2?TextWithEntities msg_id:flags.3?int
 *   saved_id:flags.11?long convert_stars:flags.4?long upgrade_stars:flags.6?long
 *   can_export_at:flags.7?int transfer_stars:flags.8?long
 *   can_transfer_at:flags.13?int can_resell_at:flags.14?int = SavedStarGift
 *
 * tl_codegen verified: 0xdfda0499 (telegram_api.tl:1967)
 * iOS ref: ProfileGiftsContext.State.StarGift (StarGifts.swift)
 */
public class SavedStarGiftEntry {
    public var isNameHidden: Bool = false
    public var isUnsaved: Bool = false
    public var isRefunded: Bool = false
    public var canUpgrade: Bool = false
    public var isPinnedToTop: Bool = false
    public var fromPeerId: Int64 = 0
    public var date: Int32 = 0
    public var gift: StarGiftEntry = StarGiftEntry()
    public var msgId: Int32 = 0
    public var savedId: Int64 = 0
    public var convertStars: Int64 = 0
    public var upgradeStars: Int64 = 0
    public var transferStars: Int64 = 0
    public var canExportAt: Int32 = 0
    public var canTransferAt: Int32 = 0
    public var canResellAt: Int32 = 0
}

func parseSavedStarGift(d: TLDeserializer): SavedStarGiftEntry {
    let r = SavedStarGiftEntry()
    let ctor = d.readUInt32()
    // current layer 0x41df43fc (iOS dict[1105150972]); old 0xdfda0499 kept for compat
    if (ctor != 0x41df43fc && ctor != 0xdfda0499) { return r }
    let flags = d.readInt32()
    r.isNameHidden = (flags & 1) != 0
    r.isUnsaved = (flags & 32) != 0
    r.isRefunded = (flags & 512) != 0
    r.canUpgrade = (flags & 1024) != 0
    r.isPinnedToTop = (flags & 4096) != 0
    if ((flags & 2) != 0) { let p = PeerResponse.deserializeBoxed(d); r.fromPeerId = p.id }
    r.date = d.readInt32()
    r.gift = parseStarGift(d)
    if ((flags & 4) != 0) { skipTextWithEntities(d) }
    if ((flags & 8) != 0) { r.msgId = d.readInt32() }
    if ((flags & 2048) != 0) { r.savedId = d.readInt64() }
    if ((flags & 16) != 0) { r.convertStars = d.readInt64() }
    if ((flags & 64) != 0) { r.upgradeStars = d.readInt64() }
    if ((flags & 128) != 0) { r.canExportAt = d.readInt32() }
    if ((flags & 256) != 0) { r.transferStars = d.readInt64() }
    if ((flags & 8192) != 0) { r.canTransferAt = d.readInt32() }
    if ((flags & 16384) != 0) { r.canResellAt = d.readInt32() }
    return r
}

/**
 * payments.starGifts#2ed82995 hash:int gifts:Vector<StarGift> = payments.StarGifts (iOS dict[785918357])
 * payments.starGiftsNotModified#a388a368 = payments.StarGifts
 * old ctor 0x901689ea kept for compat
 */
public class StarGiftsResponse {
    public var success: Bool = false
    public var notModified: Bool = false
    public var hash: Int32 = 0
    public var gifts: ArrayList<StarGiftEntry> = ArrayList<StarGiftEntry>()
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseStarGifts(data: Array<Byte>): StarGiftsResponse {
    let r = StarGiftsResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    if (ctor == 0xa388a368) {
        r.notModified = true
        r.success = true
        return r
    }
    // 0x2ed82995 = current layer (iOS dict[785918357]); 0x901689ea = old layer, kept compat
    if (ctor != 0x2ed82995 && ctor != 0x901689ea) { return r }
    r.hash = d.readInt32()
    let vecCtor = d.readUInt32()
    if (vecCtor == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var i: Int32 = 0
        while (i < cnt) {
            let g = parseStarGift(d)
            r.gifts.add(g)
            i = i + 1
        }
    }
    r.success = true
    return r
}

/**
 * payments.savedStarGifts#95f389b1 flags:# count:int
 *   chat_notifications_enabled:flags.1?Bool
 *   gifts:Vector<SavedStarGift>
 *   next_offset:flags.0?string chats:Vector<Chat> users:Vector<User>
 *   = payments.SavedStarGifts
 * tl_codegen verified: 0x95f389b1 (telegram_api.tl:1969)
 * iOS ref: ProfileGiftsContext (StarGifts.swift)
 * Outer: payments.savedStarGifts (direct response ctor)
 * Inner: count + flags.1(Bool) + Vector<SavedStarGift> + flags.0(string) + Vector<Chat> + Vector<User>
 */
public class SavedStarGiftsResponse {
    public var success: Bool = false
    public var count: Int32 = 0
    public var gifts: ArrayList<SavedStarGiftEntry> = ArrayList<SavedStarGiftEntry>()
    public var nextOffset: String = ""
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseSavedStarGifts(data: Array<Byte>): SavedStarGiftsResponse {
    let r = SavedStarGiftsResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    if (ctor != 0x95f389b1) { return r }
    let flags = d.readInt32()
    r.count = d.readInt32()
    if ((flags & 2) != 0) { let _ = d.readUInt32() }
    let giftsVec = d.readUInt32()
    if (giftsVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var i: Int32 = 0
        while (i < cnt) {
            let g = parseSavedStarGift(d)
            r.gifts.add(g)
            i = i + 1
        }
    }
    if ((flags & 1) != 0) { r.nextOffset = d.readString() }
    let chatsVec = d.readUInt32()
    if (chatsVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var ci: Int32 = 0
        while (ci < cnt) {
            let _ = ChatResponse.deserializeBoxed(d)
            ci = ci + 1
        }
    }
    let usersVec = d.readUInt32()
    if (usersVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var ui: Int32 = 0
        while (ui < cnt) {
            let _ = UserResponse.deserializeBoxed(d)
            ui = ui + 1
        }
    }
    r.success = true
    return r
}

/**
 * payments.starGiftWithdrawalUrl#84aa3a9c url:string = payments.StarGiftWithdrawalUrl
 * tl_codegen verified: 0x84aa3a9c (telegram_api.tl:1975)
 * iOS ref: getStarGiftWithdrawalUrl (TelegramEnginePayments.swift)
 */
public class StarGiftWithdrawalUrlResponse {
    public var success: Bool = false
    public var url: String = ""
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseStarGiftWithdrawalUrl(data: Array<Byte>): StarGiftWithdrawalUrlResponse {
    let r = StarGiftWithdrawalUrlResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    if (ctor != 0x84aa3a9c) { return r }
    r.url = d.readString()
    r.success = true
    return r
}

/**
 * payments.resaleStarGifts#947a12df flags:#
 *   count:int gifts:Vector<StarGift> next_offset:flags.0?string
 *   attributes:flags.1?Vector<StarGiftAttribute> attributes_hash:flags.1?long
 *   chats:Vector<Chat> counters:flags.2?Vector<StarGiftAttributeCounter> users:Vector<User>
 *   = payments.ResaleStarGifts
 * tl_codegen verified: 0x947a12df (telegram_api.tl:2002)
 * iOS ref: getResaleStarGifts (TelegramEnginePayments.swift)
 * Outer: payments.resaleStarGifts (direct response ctor)
 * StarGiftAttribute Vector + counters Vector are skipped (complex nested types not needed for list display)
 */
public class ResaleStarGiftsResponse {
    public var success: Bool = false
    public var count: Int32 = 0
    public var gifts: ArrayList<StarGiftEntry> = ArrayList<StarGiftEntry>()
    public var nextOffset: String = ""
    public var attributes: ArrayList<StarGiftAttributeEntry> = ArrayList<StarGiftAttributeEntry>()
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseResaleStarGifts(data: Array<Byte>): ResaleStarGiftsResponse {
    let r = ResaleStarGiftsResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    if (ctor != 0x947a12df) { return r }
    let flags = d.readInt32()
    r.count = d.readInt32()
    let giftsVec = d.readUInt32()
    if (giftsVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var i: Int32 = 0
        while (i < cnt) {
            let g = parseStarGift(d)
            r.gifts.add(g)
            i = i + 1
        }
    }
    if ((flags & 1) != 0) { r.nextOffset = d.readString() }
    if ((flags & 2) != 0) {
        let attrsVec = d.readUInt32()
        if (attrsVec == TLConstructors.VECTOR) {
            let attrCount = d.readInt32()
            for (_i in 0..Int64(attrCount)) { r.attributes.add(parseStarGiftAttributeBoxed(d)) }
        }
    }
    if ((flags & 2) != 0) { let _ = d.readInt64() }
    let resolvedChats = ArrayList<ChatResponse>()
    let chatsVec = d.readUInt32()
    if (chatsVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var ci: Int32 = 0
        while (ci < cnt) {
            resolvedChats.add(ChatResponse.deserializeBoxed(d))
            ci = ci + 1
        }
    }
    if ((flags & 4) != 0) {
        let countersVec = d.readUInt32()
        if (countersVec == TLConstructors.VECTOR) {
            let counterCount = d.readInt32()
            for (_i in 0..Int64(counterCount)) {
                let counterCtor = d.readUInt32()
                if (counterCtor == 0x2eb1b658) {
                    let idCtor = d.readUInt32()
                    var documentId: Int64 = 0
                    var backdropId: Int32 = 0
                    var kind = ""
                    if (idCtor == 0x48aaae3c) { kind = "model"; documentId = d.readInt64() }
                    else if (idCtor == 0x4a162433) { kind = "pattern"; documentId = d.readInt64() }
                    else if (idCtor == 0x1f01c757) { kind = "backdrop"; backdropId = d.readInt32() }
                    let value = d.readInt32()
                    for (attribute in r.attributes) {
                        if ((kind == "backdrop" && attribute.kind == kind && attribute.backdropId == backdropId) ||
                            (kind != "backdrop" && attribute.kind == kind && attribute.documentId == documentId)) {
                            attribute.count = value
                        }
                    }
                }
            }
        }
    }
    let resolvedUsers = ArrayList<UserResponse>()
    let usersVec = d.readUInt32()
    if (usersVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var ui: Int32 = 0
        while (ui < cnt) {
            resolvedUsers.add(UserResponse.deserializeBoxed(d))
            ui = ui + 1
        }
    }
    for (gift in r.gifts) {
        if (gift.ownerName.size == 0 && gift.ownerId != 0) {
            if (gift.ownerType == "user") {
                for (user in resolvedUsers) {
                    if (user.id == gift.ownerId) {
                        gift.ownerName = user.firstName
                        if (user.lastName.size > 0) {
                            gift.ownerName = if (gift.ownerName.size > 0) { "${gift.ownerName} ${user.lastName}" } else { user.lastName }
                        }
                        if (gift.ownerName.size == 0 && user.username.size > 0) { gift.ownerName = "@${user.username}" }
                        break
                    }
                }
            } else {
                for (chat in resolvedChats) {
                    if (chat.id == gift.ownerId) { gift.ownerName = chat.title; break }
                }
            }
        }
    }
    r.success = true
    return r
}

/**
 * Updates bool response for star gift operations that return Updates
 * (payments.upgradeStarGift, payments.transferStarGift, payments.updateStarGiftPrice)
 *
 * Updates 响应 ctor 集合:
 *   updates#74ae4240
 *   updatesCombined#725b04c3
 *   updateShort#78d4dec1
 *   updatesTooLong#e317af7e
 *
 * 这些操作的 Updates 响应内容需由 MTProto 状态机处理；
 * 此处仅解析"是否成功"标志供服务层使用。
 */
public class StarGiftUpdatesResponse {
    public var success: Bool = false
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseStarGiftUpdates(data: Array<Byte>): StarGiftUpdatesResponse {
    let r = StarGiftUpdatesResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    if (ctor == 0x74ae4240 || ctor == 0x725b04c3 || ctor == 0x78d4dec1 || ctor == 0xe317af7e) {
        r.success = true
    }
    return r
}

/**
 * Bool response for star gift operations that return Bool
 * (payments.convertStarGift, payments.saveStarGift)
 *
 * boolTrue#997275b5 / boolFalse#bc799737
 */
public class StarGiftBoolResponse {
    public var success: Bool = false
    public var result: Bool = false
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseStarGiftBool(data: Array<Byte>): StarGiftBoolResponse {
    let r = StarGiftBoolResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    r.success = true
    r.result = (ctor == TLConstructors.BOOL_TRUE)
    return r
}

// ==================== P2-155c: Premium Gift Codes + Giveaways Responses ====================

/**
 * payments.checkedGiftCode#eb983f8f flags:# via_giveaway:flags.2?true (iOS dict[-342343793]; old 0x284a1096 compat)
 *   from_id:flags.4?Peer giveaway_msg_id:flags.3?int to_id:flags.0?long
 *   date:int months:int used_date:flags.1?int chats:Vector<Chat> users:Vector<User>
 *   = payments.CheckedGiftCode
 * iOS dict[-342343793]=0xeb983f8f (current layer); old 0x284a1096 kept compat
 * iOS ref: _internal_checkPremiumGiftCode parse block (GiftCodes.swift:274-281)
 *
 * Flag map:
 *   flags.0  → to_id present (long)
 *   flags.1  → used_date present (int)
 *   flags.2  → via_giveaway (true flag, no data)
 *   flags.3  → giveaway_msg_id present (int)
 *   flags.4  → from_id present (Peer, boxed)
 *
 * Peer (boxed) variants:
 *   peerUser#59511722    user_id:long
 *   peerChat#36c6019a   chat_id:long
 *   peerChannel#a2a5371e channel_id:long
 */
public class CheckedGiftCodeResponse {
    public var success: Bool = false
    public var viaGiveaway: Bool = false
    public var fromPeerId: Int64 = 0
    public var fromPeerType: String = ""
    public var giveawayMsgId: Int32 = 0
    public var toPeerId: Int64 = 0
    public var date: Int32 = 0
    public var months: Int32 = 0
    public var usedDate: Int32 = 0
    public var isUsed: Bool = false
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseCheckedGiftCode(data: Array<Byte>): CheckedGiftCodeResponse {
    let r = CheckedGiftCodeResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    try {
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            r.errorCode = d.readInt32()
            r.errorMessage = d.readString()
            return r
        }
        // 0xeb983f8f = current layer (iOS dict[-342343793]); 0x284a1096 = old layer, kept compat
        if (ctor != 0xeb983f8f && ctor != 0x284a1096) {
            r.errorMessage = "unexpected ctor"
            return r
        }
        let flags = d.readInt32()
        r.viaGiveaway = (flags & 4) != 0
        if ((flags & 16) != 0) {
            let fromPeer = PeerResponse.deserializeBoxed(d)
            r.fromPeerType = fromPeer.type_
            r.fromPeerId = fromPeer.id
        }
        if ((flags & 8) != 0) { r.giveawayMsgId = d.readInt32() }
        if ((flags & 1) != 0) { r.toPeerId = d.readInt64() }
        r.date = d.readInt32()
        r.months = d.readInt32()
        if ((flags & 2) != 0) {
            r.usedDate = d.readInt32()
            r.isUsed = true
        }
        let chatsVec = d.readUInt32()
        if (chatsVec == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            var ci: Int32 = 0
            while (ci < cnt) {
                let _ = ChatResponse.deserializeBoxed(d)
                ci = ci + 1
            }
        }
        let usersVec = d.readUInt32()
        if (usersVec == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            var ui: Int32 = 0
            while (ui < cnt) {
                let _ = UserResponse.deserializeBoxed(d)
                ui = ui + 1
            }
        }
        r.success = true
    } catch (e: Exception) {
        r.errorMessage = e.toString()
    }
    return r
}

/**
 * payments.giveawayInfo#4367daa0 flags:# participating:flags.0?true
 *   preparing_results:flags.3?true start_date:int joined_too_early_date:flags.1?int
 *   admin_disallowed_chat_id:flags.2?long disallowed_country:flags.4?string
 *   = payments.GiveawayInfo
 *
 * payments.giveawayInfoResults#e175e66f flags:# winner:flags.0?true refunded:flags.1?true
 *   start_date:int gift_code_slug:flags.3?string stars_prize:flags.4?long
 *   finish_date:int winners_count:int activated_count:flags.2?int
 *   = payments.GiveawayInfo
 *
 * tl_codegen verified: 0x4367daa0 / 0xe175e66f (telegram_api.tl:1696-1697)
 * iOS ref: _internal_getPremiumGiveawayInfo parse block (GiftCodes.swift:117-143)
 *
 * infoType values: "ongoing", "results"
 * ongoingStatus values: "notQualified", "notAllowed_tooEarly", "notAllowed_admin", "notAllowed_country", "participating", "almostOver"
 * resultStatus values: "notWon", "wonPremium", "wonStars", "refunded"
 */
public class GiveawayInfoResponse {
    public var success: Bool = false
    public var infoType: String = ""
    public var startDate: Int32 = 0
    public var ongoingStatus: String = ""
    public var joinedTooEarlyDate: Int32 = 0
    public var adminDisallowedChatId: Int64 = 0
    public var disallowedCountry: String = ""
    public var resultStatus: String = ""
    public var giftCodeSlug: String = ""
    public var starsPrize: Int64 = 0
    public var finishDate: Int32 = 0
    public var winnersCount: Int32 = 0
    public var activatedCount: Int32 = 0
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseGiveawayInfo(data: Array<Byte>): GiveawayInfoResponse {
    let r = GiveawayInfoResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    try {
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            r.errorCode = d.readInt32()
            r.errorMessage = d.readString()
            return r
        }
        if (ctor == 0x4367daa0) {
            r.infoType = "ongoing"
            let flags = d.readInt32()
            let participating = (flags & 1) != 0
            let preparingResults = (flags & 8) != 0
            r.startDate = d.readInt32()
            let joinedTooEarly = if ((flags & 2) != 0) { d.readInt32() } else { 0i32 }
            let adminDisallowed = if ((flags & 4) != 0) { d.readInt64() } else { 0i64 }
            let disallowedCountryStr = if ((flags & 16) != 0) { d.readString() } else { "" }
            if (preparingResults) {
                r.ongoingStatus = "almostOver"
            } else if (participating) {
                r.ongoingStatus = "participating"
            } else if (disallowedCountryStr.size > 0) {
                r.ongoingStatus = "notAllowed_country"
                r.disallowedCountry = disallowedCountryStr
            } else if ((flags & 2) != 0) {
                r.ongoingStatus = "notAllowed_tooEarly"
                r.joinedTooEarlyDate = joinedTooEarly
            } else if ((flags & 4) != 0) {
                r.ongoingStatus = "notAllowed_admin"
                r.adminDisallowedChatId = adminDisallowed
            } else {
                r.ongoingStatus = "notQualified"
            }
            r.success = true
        } else if (ctor == 0xe175e66f) {
            r.infoType = "results"
            let flags = d.readInt32()
            let winner = (flags & 1) != 0
            let refunded = (flags & 2) != 0
            r.startDate = d.readInt32()
            let slugVal = if ((flags & 8) != 0) { d.readString() } else { "" }
            let starsVal = if ((flags & 16) != 0) { d.readInt64() } else { 0i64 }
            r.finishDate = d.readInt32()
            r.winnersCount = d.readInt32()
            r.activatedCount = if ((flags & 4) != 0) { d.readInt32() } else { 0 }
            if (refunded) {
                r.resultStatus = "refunded"
            } else if (starsVal > 0i64) {
                r.resultStatus = "wonStars"
                r.starsPrize = starsVal
            } else if (slugVal.size > 0) {
                r.resultStatus = "wonPremium"
                r.giftCodeSlug = slugVal
            } else {
                r.resultStatus = "notWon"
            }
            if (winner) {
                r.resultStatus = if (slugVal.size > 0) { "wonPremium" } else { r.resultStatus }
            }
            r.success = true
        } else {
            r.errorMessage = "unexpected ctor"
        }
    } catch (e: Exception) {
        r.errorMessage = e.toString()
    }
    return r
}

/**
 * Vector<PremiumGiftCodeOption> response (payments.getPremiumGiftCodeOptions)
 * Outer: Vector (0x1cb5c415)
 * Each item: premiumGiftCodeOption#257e962b flags:# users:int months:int
 *   store_product:flags.0?string store_quantity:flags.1?int currency:string amount:long
 * tl_codegen verified: 0x257e962b (telegram_api.tl:1692)
 * iOS ref: _internal_premiumGiftCodeOptions parse block (GiftCodes.swift:204)
 */
public class PremiumGiftCodeOptionEntry {
    public var users: Int32 = 0
    public var months: Int32 = 0
    public var storeProduct: String = ""
    public var storeQuantity: Int32 = 1
    public var currency: String = ""
    public var amount: Int64 = 0
}

public class PremiumGiftCodeOptionsResponse {
    public var success: Bool = false
    public var options: ArrayList<PremiumGiftCodeOptionEntry> = ArrayList<PremiumGiftCodeOptionEntry>()
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parsePremiumGiftCodeOptions(data: Array<Byte>): PremiumGiftCodeOptionsResponse {
    let r = PremiumGiftCodeOptionsResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    try {
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            r.errorCode = d.readInt32()
            r.errorMessage = d.readString()
            return r
        }
        if (ctor != TLConstructors.VECTOR) {
            r.errorMessage = "expected Vector"
            return r
        }
        let cnt = d.readInt32()
        var i: Int32 = 0
        while (i < cnt) {
            let optCtor = d.readUInt32()
            if (optCtor == 0x257e962b) {
                let entry = PremiumGiftCodeOptionEntry()
                let flags = d.readInt32()
                entry.users = d.readInt32()
                entry.months = d.readInt32()
                if ((flags & 1) != 0) { entry.storeProduct = d.readString() }
                if ((flags & 2) != 0) { entry.storeQuantity = d.readInt32() }
                entry.currency = d.readString()
                entry.amount = d.readInt64()
                r.options.add(entry)
            }
            i = i + 1
        }
        r.success = true
    } catch (e: Exception) {
        r.errorMessage = e.toString()
    }
    return r
}

// ==================== P2-155d: Stars Subscriptions + Revenue Responses ====================

/**
 * StarsSubscriptionsResponse — wraps payments.getStarsSubscriptions response.
 * Returns payments.starsStatus#6c9ce8ed; we extract the subscriptions sub-list.
 *
 * starsSubscription#2e6eab1a flags:# canceled:0 can_refulfill:1 missing_balance:2
 *   bot_canceled:7 id:string peer:Peer until_date:int pricing:StarsSubscriptionPricing
 *   chat_invite_hash:3?string title:4?string photo:5?WebDocument invoice_slug:6?string
 * starsSubscriptionPricing#05416d58 period:int amount:long
 *
 * TL verified: starsSubscription=0x2e6eab1a, starsSubscriptionPricing=0x05416d58
 * (telegram_api.tl:1908+1910)
 */
public class StarsSubscriptionEntry {
    public var id: String = ""
    public var canceled: Bool = false
    public var canRefulfill: Bool = false
    public var missingBalance: Bool = false
    public var botCanceled: Bool = false
    public var peerType: String = ""
    public var peerId: Int64 = 0
    public var untilDate: Int32 = 0
    public var pricingPeriod: Int32 = 0
    public var pricingAmount: Int64 = 0
    public var chatInviteHash: String = ""
    public var title: String = ""
    public var invoiceSlug: String = ""
}

public class StarsSubscriptionsResponse {
    public var success: Bool = false
    public var balanceAmount: Int64 = 0
    public var balanceNanos: Int32 = 0
    public var subscriptionsNextOffset: String = ""
    public var subscriptionsMissingBalance: Int64 = 0
    public var subscriptions: ArrayList<StarsSubscriptionEntry> = ArrayList<StarsSubscriptionEntry>()
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

func parseStarsSubscriptionPricing(d: TLDeserializer): (Int32, Int64) {
    let ctor = d.readUInt32()
    if (ctor == 0x05416d58) {
        let period = d.readInt32()
        let amount = d.readInt64()
        return (period, amount)
    }
    return (0i32, 0i64)
}

func parseStarsSubscriptionEntry(d: TLDeserializer): StarsSubscriptionEntry {
    let entry = StarsSubscriptionEntry()
    let ctor = d.readUInt32()
    if (ctor != 0x2e6eab1a) {
        return entry
    }
    let flags = d.readInt32()
    entry.canceled = (flags & 1) != 0
    entry.canRefulfill = (flags & 2) != 0
    entry.missingBalance = (flags & 4) != 0
    entry.botCanceled = (flags & 128) != 0
    entry.id = d.readString()
    let peer = PeerResponse.deserializeBoxed(d)
    entry.peerType = peer.type_
    entry.peerId = peer.id
    entry.untilDate = d.readInt32()
    let (period, amount) = parseStarsSubscriptionPricing(d)
    entry.pricingPeriod = period
    entry.pricingAmount = amount
    if ((flags & 8) != 0) { entry.chatInviteHash = d.readString() }
    if ((flags & 16) != 0) { entry.title = d.readString() }
    if ((flags & 32) != 0) { skipWebDocument(d) }
    if ((flags & 64) != 0) { entry.invoiceSlug = d.readString() }
    return entry
}

public func parseStarsSubscriptions(data: Array<Byte>): StarsSubscriptionsResponse {
    let r = StarsSubscriptionsResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    if (ctor != 0x6c9ce8ed) { return r }
    let flags = d.readInt32()
    let bal = parseStarsAmount(d)
    r.balanceAmount = bal.amount
    r.balanceNanos = bal.nanos
    if ((flags & 2) != 0) {
        let subVec = d.readUInt32()
        if (subVec == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            var si: Int32 = 0
            while (si < cnt) {
                let sub = parseStarsSubscriptionEntry(d)
                r.subscriptions.add(sub)
                si = si + 1
            }
        }
    }
    if ((flags & 4) != 0) { r.subscriptionsNextOffset = d.readString() }
    if ((flags & 16) != 0) { r.subscriptionsMissingBalance = d.readInt64() }
    if ((flags & 8) != 0) {
        let histVec = d.readUInt32()
        if (histVec == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            var hi: Int32 = 0
            while (hi < cnt) {
                skipBoxedStarsTransaction(d)
                hi = hi + 1
            }
        }
    }
    if ((flags & 1) != 0) { let _ = d.readString() }
    let chatsVec = d.readUInt32()
    if (chatsVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var ci: Int32 = 0
        while (ci < cnt) {
            let _ = ChatResponse.deserializeBoxed(d)
            ci = ci + 1
        }
    }
    let usersVec = d.readUInt32()
    if (usersVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var ui: Int32 = 0
        while (ui < cnt) {
            let _ = UserResponse.deserializeBoxed(d)
            ui = ui + 1
        }
    }
    r.success = true
    return r
}

/**
 * skipStarGiftAttributeRarityBoxed — skip a boxed StarGiftAttributeRarity.
 * Variants (from Api27.swift serialize, Api0.swift dispatch):
 *   starGiftAttributeRarity#36437737  permille:int
 *   starGiftAttributeRarityEpic#78fbf3a8       (no fields)
 *   starGiftAttributeRarityLegendary#cef7e7a8  (no fields)
 *   starGiftAttributeRarityRare#f08d516b       (no fields)
 *   starGiftAttributeRarityUncommon#dbce6389   (no fields)
 * iOS ref: Api27.swift:176-200
 */
func skipStarGiftAttributeRarityBoxed(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x36437737) {
        let _ = d.readInt32()
    }
}

/**
 * parseStarGiftAttributeRarityPermille — read a boxed StarGiftAttributeRarity and return permille.
 * Named variants are mapped to well-known permille values matching iOS treatment:
 *   starGiftAttributeRarity#36437737       → explicit permille field
 *   starGiftAttributeRarityUncommon#dbce6389 → 200 permille
 *   starGiftAttributeRarityRare#f08d516b   → 50 permille
 *   starGiftAttributeRarityEpic#78fbf3a8   → 10 permille
 *   starGiftAttributeRarityLegendary#cef7e7a8 → 1 permille
 * iOS ref: Api27.swift:218-240
 */
func parseStarGiftAttributeRarityPermille(d: TLDeserializer): Int32 {
    let ctor = d.readUInt32()
    if (ctor == 0x36437737) {
        return d.readInt32()
    } else if (ctor == 0xdbce6389) {
        return 200
    } else if (ctor == 0xf08d516b) {
        return 50
    } else if (ctor == 0x78fbf3a8) {
        return 10
    } else if (ctor == 0xcef7e7a8) {
        return 1
    }
    return 0
}

/**
 * skipStarGiftAttributeBoxed — skip a boxed StarGiftAttribute.
 * Variants (from Api26.swift, Api0.swift dispatch):
 *   starGiftAttributeBackdrop#9f2504e4     name:string backdropId:int centerColor:int edgeColor:int patternColor:int textColor:int rarity:StarGiftAttributeRarity(boxed)
 *   starGiftAttributeModel#565251e2        flags:int name:string document:Document(boxed) rarity:StarGiftAttributeRarity(boxed)
 *   starGiftAttributeOriginalDetails#e0bff26c flags:int senderId:flags.0?Peer(boxed) recipientId:Peer(boxed) date:int message:flags.1?TextWithEntities(boxed)
 *   starGiftAttributePattern#4e7085ea      name:string document:Document(boxed) rarity:StarGiftAttributeRarity(boxed)
 * iOS ref: Api26.swift:1626-1734, Api0.swift:1048-1051
 */
func skipStarGiftAttributeBoxed(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x9f2504e4) {
        let _ = d.readString()
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readInt32()
        skipStarGiftAttributeRarityBoxed(d)
    } else if (ctor == 0x565251e2) {
        let _ = d.readInt32()
        let _ = d.readString()
        skipDocument(d)
        skipStarGiftAttributeRarityBoxed(d)
    } else if (ctor == 0xe0bff26c) {
        let flags2 = d.readInt32()
        if ((flags2 & 1) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        let _ = PeerResponse.deserializeBoxed(d)
        let _ = d.readInt32()
        if ((flags2 & 2) != 0) { skipTextWithEntities(d) }
    } else if (ctor == 0x4e7085ea) {
        let _ = d.readString()
        skipDocument(d)
        skipStarGiftAttributeRarityBoxed(d)
    }
}

/**
 * skipWebDocumentBoxed — skip a boxed WebDocument from deserializer.
 * Variants (from Api30.swift:2385-2431, Api0.swift:1330-1331):
 *   webDocument#1c570ed1        url:string accessHash:long size:int mimeType:string attributes:Vector<DocumentAttribute>
 *   webDocumentNoProxy#f9c8bcc6 url:string size:int mimeType:string attributes:Vector<DocumentAttribute>
 * iOS ref: Api30.swift:2385-2431
 */
func skipWebDocumentBoxed(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x1c570ed1) {
        let _ = d.readString()
        let _ = d.readInt64()
        let _ = d.readInt32()
        let _ = d.readString()
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_i in 0..Int64(cnt)) {
                skipDocumentAttribute(d)
            }
        }
    } else if (ctor == 0xf9c8bcc6) {
        let _ = d.readString()
        let _ = d.readInt32()
        let _ = d.readString()
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_i in 0..Int64(cnt)) {
                skipDocumentAttribute(d)
            }
        }
    }
}

/**
 * skipStarGiftBoxed — skip a boxed StarGift from deserializer.
 * Variants (from Api26.swift serialize, Api0.swift dispatch):
 *   starGift#313a9547 (signed 825922887) flags:int id:long sticker:Document(boxed) stars:long
 *     availabilityRemains:flags.0?int availabilityTotal:flags.0?int availabilityResale:flags.4?long
 *     convertStars:long firstSaleDate:flags.1?int lastSaleDate:flags.1?int
 *     upgradeStars:flags.3?long resellMinStars:flags.4?long title:flags.5?string
 *     releasedBy:flags.6?Peer(boxed) perUserTotal:flags.8?int perUserRemains:flags.8?int
 *     lockedUntilDate:flags.9?int auctionSlug:flags.11?string giftsPerRound:flags.11?int auctionStartDate:flags.11?int
 *     upgradeVariants:flags.12?int background:flags.13?StarGiftBackground(boxed)
 *   starGiftUnique#85f0a9cd (signed -2047825459) flags:int id:long giftId:long title:string slug:string num:int
 *     ownerId:flags.0?Peer(boxed) ownerName:flags.1?string ownerAddress:flags.2?string
 *     attributes:Vector<StarGiftAttribute>(boxed) availabilityIssued:int availabilityTotal:int
 *     giftAddress:flags.3?string resellAmount:flags.4?Vector<StarsAmount>(boxed)
 *     releasedBy:flags.5?Peer(boxed)
 *     valueAmount:flags.8?long valueCurrency:flags.8?string valueUsdAmount:flags.8?long
 *     themePeer:flags.10?Peer(boxed) peerColor:flags.11?StarGiftBackground(boxed)
 *     hostId:flags.12?Peer(boxed) offerMinStars:flags.13?int craftChancePermille:flags.16?int
 * iOS ref: Api26.swift:1056-1182, Api0.swift:1045-1046
 * StarGiftBackground#aff56398 centerColor:int edgeColor:int textColor:int (Api27.swift:763-772, Api0.swift:1068)
 */
func skipStarGiftBoxed(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x313a9547) {
        let flags2 = d.readInt32()
        let _ = d.readInt64()
        skipDocument(d)
        let _ = d.readInt64()
        if ((flags2 & 0x1) != 0) { let _ = d.readInt32() }
        if ((flags2 & 0x1) != 0) { let _ = d.readInt32() }
        if ((flags2 & 0x10) != 0) { let _ = d.readInt64() }
        let _ = d.readInt64()
        if ((flags2 & 0x2) != 0) { let _ = d.readInt32() }
        if ((flags2 & 0x2) != 0) { let _ = d.readInt32() }
        if ((flags2 & 0x8) != 0) { let _ = d.readInt64() }
        if ((flags2 & 0x10) != 0) { let _ = d.readInt64() }
        if ((flags2 & 0x20) != 0) { let _ = d.readString() }
        if ((flags2 & 0x40) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        if ((flags2 & 0x100) != 0) { let _ = d.readInt32() }
        if ((flags2 & 0x100) != 0) { let _ = d.readInt32() }
        if ((flags2 & 0x200) != 0) { let _ = d.readInt32() }
        if ((flags2 & 0x800) != 0) { let _ = d.readString() }
        if ((flags2 & 0x800) != 0) { let _ = d.readInt32() }
        if ((flags2 & 0x800) != 0) { let _ = d.readInt32() }
        if ((flags2 & 0x1000) != 0) { let _ = d.readInt32() }
        if ((flags2 & 0x2000) != 0) {
            let bgCtor = d.readUInt32()
            if (bgCtor == 0xaff56398) {
                let _ = d.readInt32()
                let _ = d.readInt32()
                let _ = d.readInt32()
            }
        }
    } else if (ctor == 0x85f0a9cd) {
        let flags2 = d.readInt32()
        let _ = d.readInt64()
        let _ = d.readInt64()
        let _ = d.readString()
        let _ = d.readString()
        let _ = d.readInt32()
        if ((flags2 & 0x1) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        if ((flags2 & 0x2) != 0) { let _ = d.readString() }
        if ((flags2 & 0x4) != 0) { let _ = d.readString() }
        let attrVec = d.readUInt32()
        if (attrVec == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_i in 0..Int64(cnt)) {
                skipStarGiftAttributeBoxed(d)
            }
        }
        let _ = d.readInt32()
        let _ = d.readInt32()
        if ((flags2 & 0x8) != 0) { let _ = d.readString() }
        if ((flags2 & 0x10) != 0) {
            let rsVec = d.readUInt32()
            if (rsVec == TLConstructors.VECTOR) {
                let cnt = d.readInt32()
                for (_i in 0..Int64(cnt)) {
                    let _ = parseStarsAmount(d)
                }
            }
        }
        if ((flags2 & 0x20) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        if ((flags2 & 0x100) != 0) { let _ = d.readInt64() }
        if ((flags2 & 0x100) != 0) { let _ = d.readString() }
        if ((flags2 & 0x100) != 0) { let _ = d.readInt64() }
        if ((flags2 & 0x400) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        if ((flags2 & 0x800) != 0) {
            let peerColorCtor = d.readUInt32()
            if (peerColorCtor == 0xb54b5acf) {
                let peerColorFlags = d.readInt32()
                if ((peerColorFlags & 0x1) != 0) { let _ = d.readInt32() }
                if ((peerColorFlags & 0x2) != 0) { let _ = d.readInt64() }
            }
        }
        if ((flags2 & 0x1000) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        if ((flags2 & 0x2000) != 0) { let _ = d.readInt32() }
        if ((flags2 & 0x10000) != 0) { let _ = d.readInt32() }
    }
}

/**
 * skipBoxedStarsTransaction — skip one starsTransaction entry from deserializer.
 * Used when parsing subscriptions (history field entries are not needed there).
 *
 * starsTransaction#a39fd94a flags:# refund:flags.3?true pending:flags.4?true failed:flags.6?true
 *   gift:flags.10?true reaction:flags.11?true stargift_upgrade:flags.18?true
 *   business_transfer:flags.21?true stargift_resale:flags.22?true
 *   id:string stars:StarsAmount(boxed) date:int peer:StarsTransactionPeer(boxed)
 *   title:flags.0?string description:flags.1?string photo:flags.2?WebDocument(boxed)
 *   transaction_date:flags.5?int transaction_url:flags.5?string
 *   bot_payload:flags.7?bytes msg_id:flags.8?int
 *   extended_media:flags.9?Vector<MessageMedia>(boxed)
 *   subscription_period:flags.12?int giveaway_post_id:flags.13?int
 *   stargift:flags.14?StarGift(boxed) floodskip_number:flags.15?int
 *   starref_commission_permille:flags.16?int
 *   starref_peer:flags.17?Peer(boxed) starref_amount:flags.17?StarsAmount(boxed)
 *   paid_messages:flags.19?int premium_gift_months:flags.20?int
 *   ads_proceeds_from_date:flags.23?int ads_proceeds_to_date:flags.23?int
 *
 * Field order and types verified against iOS Api27.swift:1845-1976 (parse_starsTransaction)
 * and telegram_api.tl:1880.
 * Flags.3/4/6/10/11/18/21/22 are boolean-only (no wire data to read).
 */
func skipBoxedStarsTransaction(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    // 0x13659eb0 = current layer (iOS dict[325426864]); 0xa39fd94a = old layer, kept compat
    if (ctor != 0x13659eb0 && ctor != 0xa39fd94a) { return }
    let flags = d.readInt32()
    let _ = d.readString()
    let _ = parseStarsAmount(d)
    let _ = d.readInt32()
    skipStarsTransactionPeer(d)
    if ((flags & 0x1) != 0) { let _ = d.readString() }
    if ((flags & 0x2) != 0) { let _ = d.readString() }
    if ((flags & 0x4) != 0) { skipWebDocumentBoxed(d) }
    if ((flags & 0x20) != 0) { let _ = d.readInt32() }
    if ((flags & 0x20) != 0) { let _ = d.readString() }
    if ((flags & 0x80) != 0) { let _ = d.readBytes() }
    if ((flags & 0x100) != 0) { let _ = d.readInt32() }
    if ((flags & 0x200) != 0) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            var k: Int32 = 0
            while (k < cnt) {
                skipBoxedObject(d)
                k = k + 1
            }
        }
    }
    if ((flags & 0x1000) != 0) { let _ = d.readInt32() }
    if ((flags & 0x2000) != 0) { let _ = d.readInt32() }
    if ((flags & 0x4000) != 0) { skipStarGiftBoxed(d) }
    if ((flags & 0x8000) != 0) { let _ = d.readInt32() }
    if ((flags & 0x10000) != 0) { let _ = d.readInt32() }
    if ((flags & 0x20000) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
    if ((flags & 0x20000) != 0) { let _ = parseStarsAmount(d) }
    if ((flags & 0x80000) != 0) { let _ = d.readInt32() }
    if ((flags & 0x100000) != 0) { let _ = d.readInt32() }
    if ((flags & 0x800000) != 0) { let _ = d.readInt32() }
    if ((flags & 0x800000) != 0) { let _ = d.readInt32() }
}

/**
 * skipStarsTransactionPeer — skip a StarsTransactionPeer (already dispatched, ctor already read by caller).
 * This function reads the ctor itself (boxed variant).
 *
 * 8 variants (from Api27.swift:1999-2042 serialize, Api0.swift:1083-1090 dispatch):
 *   starsTransactionPeer#d80da15d        peer:Peer(boxed)
 *   starsTransactionPeerAPI#f9677aad     (no fields)
 *   starsTransactionPeerAds#60682812     (no fields)
 *   starsTransactionPeerAppStore#b457b375 (no fields)
 *   starsTransactionPeerFragment#e92fd902 (no fields)
 *   starsTransactionPeerPlayMarket#7b560a0b (no fields)
 *   starsTransactionPeerPremiumBot#250dbaf8 (no fields)
 *   starsTransactionPeerUnsupported#95f2bfe4 (no fields)
 *
 * Hallucinated ctors removed: 0x13bd9b6f / 0x29111fc1 / 0x373bfd55 / 0x1b20b6fc
 * (not present in Api0.swift dispatch or telegram_api.tl StarsTransactionPeer type)
 */
func skipStarsTransactionPeer(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xd80da15d) {
        let _ = PeerResponse.deserializeBoxed(d)
    } else if (ctor == 0xf9677aad) {
        return
    } else if (ctor == 0x60682812) {
        return
    } else if (ctor == 0xb457b375) {
        return
    } else if (ctor == 0xe92fd902) {
        return
    } else if (ctor == 0x7b560a0b) {
        return
    } else if (ctor == 0x250dbaf8) {
        return
    } else if (ctor == 0x95f2bfe4) {
        return
    }
}

/**
 * Bool response parser (for changeStarsSubscription / fulfillStarsSubscription).
 * boolTrue#997275b5 | boolFalse#bc799737
 * tl_codegen verified: 0x997275b5 / 0xbc799737
 */
public class TLBoolResponse {
    public var success: Bool = false
    public var result: Bool = false
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseTLBool(data: Array<Byte>): TLBoolResponse {
    let r = TLBoolResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    r.success = true
    r.result = (ctor == 0x997275b5)
    return r
}

/**
 * StarsRevenueStatsResponse — wraps payments.getStarsRevenueStats response.
 *
 * payments.starsRevenueStats#6c207376 flags:# topHoursGraph:flags.0?StatsGraph (iOS dict[1814066038]; old 0xc92bb73b compat)
 *   revenue_graph:StatsGraph status:StarsRevenueStatus usd_rate:double
 *
 * starsRevenueStatus#febe5491 flags:# withdrawal_enabled:0 current_balance:StarsAmount
 *   available_balance:StarsAmount overall_revenue:StarsAmount next_withdrawal_at:1?int
 *
 * StatsGraph variants (all boxed):
 *   statsGraphAsync#4a27eb2d token:string
 *   statsGraphError#bedc9822 error:string
 *   statsGraph#8ea464b6 flags:# json:DataJSON zoom_token:flags.0?string
 *   DataJSON#7d748d04 data:string
 *
 * TL verified: starsRevenueStats=0x6c207376 (iOS dict[1814066038]; old 0xc92bb73b compat), starsRevenueStatus=0xfebe5491
 * (telegram_api.tl:1890+1892; iOS Api27.swift L1434; Api39.swift L769)
 */
public class StarsRevenueStatsResponse {
    public var success: Bool = false
    public var withdrawalEnabled: Bool = false
    public var currentBalanceAmount: Int64 = 0
    public var currentBalanceNanos: Int32 = 0
    public var availableBalanceAmount: Int64 = 0
    public var availableBalanceNanos: Int32 = 0
    public var overallRevenueAmount: Int64 = 0
    public var overallRevenueNanos: Int32 = 0
    public var nextWithdrawalAt: Int32 = 0
    public var hasNextWithdrawalAt: Bool = false
    public var usdRate: Float64 = 0.0
    public var revenueGraphToken: String = ""
    public var revenueGraphError: String = ""
    public var revenueGraphJson: String = ""
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

// ==================== P2-AUDIT-read3: skipRichText / skipPageBlock / skipPageCaption ====================
//
// Verified against iOS sources:
//   RichText variants — Api0.swift:945-973, Api24.swift:699-1090
//   PageBlock variants — Api0.swift:758-795, Api19.swift:1289-1938
//   PageCaption        — Api0.swift:797, Api20.swift:35-52
//   PageListItem       — Api0.swift:798-799, Api20.swift:114-145
//   PageListOrderedItem— Api0.swift:800-801, Api20.swift:237-298
//   PageRelatedArticle — Api0.swift:802, Api20.swift:363-404
//   PageTableCell      — Api0.swift:803, Api20.swift:453-480
//   PageTableRow       — Api0.swift:804, Api20.swift:518-530
//   InputGeoPoint      — Api0.swift:398-399, Api10.swift:635-659
//   GeoPoint           — Api0.swift:308-309, Api7.swift:1514-1541

/**
 * skipRichText — recursively skip one boxed RichText value.
 *
 * Reads the boxed ctor (Int32 from wire) then skips fields per variant.
 * Recursive for textConcat (Vector<RichText>) and all wrapper variants (text:RichText).
 *
 * RichText ctor table (Api0.swift:945-973):
 *   textAnchor         0x35553762  text:RichText  name:string
 *   textAutoEmail      0xc556a45d  text:RichText
 *   textAutoPhone      0x24c26789  text:RichText
 *   textAutoUrl        0xac6a83aa  text:RichText
 *   textBankCard       0xb956812d  text:RichText
 *   textBold           0x6724abc4  text:RichText
 *   textBotCommand     0x02ff29d3  text:RichText
 *   textCashtag        0x7b9e1801  text:RichText
 *   textConcat         0x7e6260d7  texts:Vector<RichText>
 *   textCustomEmoji    0xa26156c0  documentId:Int64  alt:string
 *   textDate           0xa5b45e2b  flags:Int32  text:RichText  date:Int32
 *   textEmail          0xde5a0dd6  text:RichText  email:string
 *   textEmpty          0xdc3d824f  (no fields)
 *   textFixed          0x6c3f19b9  text:RichText
 *   textHashtag        0x519524ea  text:RichText
 *   textImage          0x081ccf4f  documentId:Int64  w:Int32  h:Int32
 *   textItalic         0xd912a59c  text:RichText
 *   textMarked         0x034b8621  text:RichText
 *   textMath           0x9d2eac97  source:string
 *   textMention        0xcd24cf44  text:RichText
 *   textMentionName    0x01a9fbfc  text:RichText  userId:Int64
 *   textPhone          0x1ccb966a  text:RichText  phone:string
 *   textPlain          0x744694e0  text:string
 *   textSpoiler        0x4c2a5d62  text:RichText
 *   textStrike         0x9bf8bb95  text:RichText
 *   textSubscript      0xed6a8504  text:RichText
 *   textSuperscript    0xc7fb5e01  text:RichText
 *   textUnderline      0xc12622c4  text:RichText
 *   textUrl            0x3c2884c1  text:RichText  url:string  webpageId:Int64
 */
func skipRichText(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    // textEmpty#dc3d824f — no fields
    if (ctor == 0xdc3d824f) { return }
    // textPlain#744694e0 — text:string
    if (ctor == 0x744694e0) { let _ = d.readString(); return }
    // textConcat#7e6260d7 — texts:Vector<RichText> (boxed vector, each element boxed RichText)
    if (ctor == 0x7e6260d7) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_ in 0..Int64(cnt)) { skipRichText(d) }
        }
        return
    }
    // textCustomEmoji#a26156c0 — documentId:Int64  alt:string
    if (ctor == 0xa26156c0) { let _ = d.readInt64(); let _ = d.readString(); return }
    // textImage#081ccf4f — documentId:Int64  w:Int32  h:Int32
    if (ctor == 0x081ccf4f) { let _ = d.readInt64(); let _ = d.readInt32(); let _ = d.readInt32(); return }
    // textMath#9d2eac97 — source:string
    if (ctor == 0x9d2eac97) { let _ = d.readString(); return }
    // textDate#a5b45e2b — flags:Int32  text:RichText  date:Int32
    if (ctor == 0xa5b45e2b) { let _ = d.readInt32(); skipRichText(d); let _ = d.readInt32(); return }
    // textAnchor#35553762 — text:RichText  name:string
    if (ctor == 0x35553762) { skipRichText(d); let _ = d.readString(); return }
    // textEmail#de5a0dd6 — text:RichText  email:string
    if (ctor == 0xde5a0dd6) { skipRichText(d); let _ = d.readString(); return }
    // textPhone#1ccb966a — text:RichText  phone:string
    if (ctor == 0x1ccb966a) { skipRichText(d); let _ = d.readString(); return }
    // textMentionName#01a9fbfc — text:RichText  userId:Int64
    if (ctor == 0x01a9fbfc) { skipRichText(d); let _ = d.readInt64(); return }
    // textUrl#3c2884c1 — text:RichText  url:string  webpageId:Int64
    if (ctor == 0x3c2884c1) { skipRichText(d); let _ = d.readString(); let _ = d.readInt64(); return }
    // All "text:RichText" single-wrapped variants (one nested RichText, no other fields):
    //   textAutoEmail  0xc556a45d
    //   textAutoPhone  0x24c26789
    //   textAutoUrl    0xac6a83aa
    //   textBankCard   0xb956812d
    //   textBold       0x6724abc4
    //   textBotCommand 0x02ff29d3
    //   textCashtag    0x7b9e1801
    //   textFixed      0x6c3f19b9
    //   textHashtag    0x519524ea
    //   textItalic     0xd912a59c
    //   textMarked     0x034b8621
    //   textMention    0xcd24cf44
    //   textSpoiler    0x4c2a5d62
    //   textStrike     0x9bf8bb95
    //   textSubscript  0xed6a8504
    //   textSuperscript 0xc7fb5e01
    //   textUnderline  0xc12622c4
    if (ctor == 0xc556a45d || ctor == 0x24c26789 || ctor == 0xac6a83aa || ctor == 0xb956812d ||
        ctor == 0x6724abc4 || ctor == 0x02ff29d3 || ctor == 0x7b9e1801 || ctor == 0x6c3f19b9 ||
        ctor == 0x519524ea || ctor == 0xd912a59c || ctor == 0x034b8621 || ctor == 0xcd24cf44 ||
        ctor == 0x4c2a5d62 || ctor == 0x9bf8bb95 || ctor == 0xed6a8504 || ctor == 0xc7fb5e01 ||
        ctor == 0xc12622c4) {
        skipRichText(d)
        return
    }
    // Unknown RichText ctor — log and treat as textEmpty (no fields safe assumption)
    Hilog.info(0, "CjTelegram", "[skipRichText] Unknown ctor: 0x${toHex32(ctor)}, treating as empty")
}

/**
 * skipPageCaption — skip one boxed PageCaption.
 *
 * pageCaption#1869903447  text:RichText  credit:RichText
 * (Api0.swift:797, Api20.swift:35-52)
 */
func skipPageCaption(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x6f747657) {
        // pageCaption#1869903447 — text:RichText  credit:RichText
        skipRichText(d)  // text
        skipRichText(d)  // credit
        return
    }
    // Unknown ctor — skip conservatively
    Hilog.info(0, "CjTelegram", "[skipPageCaption] Unknown ctor: 0x${toHex32(ctor)}")
}

/**
 * skipInputGeoPoint — skip one boxed InputGeoPoint.
 *
 * inputGeoPointEmpty  0xe4c123d6  (no fields)
 * inputGeoPoint       0x481d2831  flags:Int32  lat:Double  long:Double  accuracyRadius?[flags.0]:Int32
 * (Api0.swift:398-399, Api10.swift:635-659)
 */
func skipInputGeoPoint(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xe4c123d6) { return }  // inputGeoPointEmpty#-457104426
    // inputGeoPoint#1210199983 = 0x48222faf: flags:Int32 lat:Double long:Double [accuracyRadius:Int32]
    let flags = d.readInt32()
    let _ = d.readDouble()   // lat
    let _ = d.readDouble()   // long
    if ((flags & 1) != 0) { let _ = d.readInt32() }  // accuracyRadius
}

/**
 * skipPageListItem — skip one boxed PageListItem.
 *
 * pageListItemBlocks#63455ffd  flags:Int32  blocks:Vector<PageBlock>
 * pageListItemText  #2f51bd02  flags:Int32  text:RichText
 * (Api0.swift:798-799, Api20.swift:114-145)
 */
func skipPageListItem(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x63ca67aa) {
        // pageListItemBlocks#1674209194 = 0x63ca67aa: flags:Int32 + Vector<PageBlock>
        let _ = d.readInt32()  // flags
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_ in 0..Int64(cnt)) { skipPageBlock(d) }
        }
        return
    }
    if (ctor == 0x2f58683c) {
        // pageListItemText#794323004 = 0x2f58683c: flags:Int32 + RichText
        let _ = d.readInt32()  // flags
        skipRichText(d)
        return
    }
    Hilog.info(0, "CjTelegram", "[skipPageListItem] Unknown ctor: 0x${toHex32(ctor)}")
}

/**
 * skipPageListOrderedItem — skip one boxed PageListOrderedItem.
 *
 * pageListOrderedItemBlocks#9fb2ac70  flags:Int32  num?[flags.2]:string  blocks:Vector<PageBlock>
 *                                      value?[flags.3]:Int32  type?[flags.4]:string
 * pageListOrderedItemText  #14f21349  flags:Int32  num?[flags.2]:string  text:RichText
 *                                      value?[flags.3]:Int32  type?[flags.4]:string
 * (Api0.swift:800-801, Api20.swift:237-298)
 */
func skipPageListOrderedItem(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    let flags = d.readInt32()
    if ((flags & 4) != 0) { let _ = d.readString() }  // num?[flags.2]
    if (ctor == 0x8ff2d5f0) {
        // pageListOrderedItemBlocks#-1879910928 = 0x8ff2d5f0 — blocks:Vector<PageBlock>
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_ in 0..Int64(cnt)) { skipPageBlock(d) }
        }
    } else if (ctor == 0x15031189) {
        // pageListOrderedItemText#352522633 = 0x15031189 — text:RichText
        skipRichText(d)
    } else {
        Hilog.info(0, "CjTelegram", "[skipPageListOrderedItem] Unknown ctor: 0x${toHex32(ctor)}")
        return
    }
    if ((flags & 8) != 0) { let _ = d.readInt32() }   // value?[flags.3]
    if ((flags & 16) != 0) { let _ = d.readString() }  // type?[flags.4]
}

/**
 * skipPageRelatedArticle — skip one boxed PageRelatedArticle.
 *
 * pageRelatedArticle#b390dc08  flags:Int32  url:string  webpageId:Int64
 *   title?[flags.0]:string  description?[flags.1]:string  photoId?[flags.2]:Int64
 *   author?[flags.3]:string  publishedDate?[flags.4]:Int32
 * (Api0.swift:802, Api20.swift:363-404)
 */
func skipPageRelatedArticle(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor != 0xb390dc08) {
        Hilog.info(0, "CjTelegram", "[skipPageRelatedArticle] Unknown ctor: 0x${toHex32(ctor)}")
        return
    }
    let flags = d.readInt32()
    let _ = d.readString()   // url
    let _ = d.readInt64()    // webpageId
    if ((flags & 1) != 0) { let _ = d.readString() }   // title
    if ((flags & 2) != 0) { let _ = d.readString() }   // description
    if ((flags & 4) != 0) { let _ = d.readInt64() }    // photoId
    if ((flags & 8) != 0) { let _ = d.readString() }   // author
    if ((flags & 16) != 0) { let _ = d.readInt32() }   // publishedDate
}

/**
 * skipPageTableCell — skip one boxed PageTableCell.
 *
 * pageTableCell#34566b6a  flags:Int32  text?[flags.7]:RichText  colspan?[flags.1]:Int32  rowspan?[flags.2]:Int32
 * (Api0.swift:803, Api20.swift:453-480)
 */
func skipPageTableCell(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor != 0x34566b6a) {
        Hilog.info(0, "CjTelegram", "[skipPageTableCell] Unknown ctor: 0x${toHex32(ctor)}")
        return
    }
    let flags = d.readInt32()
    if ((flags & 128) != 0) { skipRichText(d) }   // text?[flags.7]
    if ((flags & 2) != 0) { let _ = d.readInt32() }    // colspan?[flags.1]
    if ((flags & 4) != 0) { let _ = d.readInt32() }    // rowspan?[flags.2]
}

/**
 * skipPageTableRow — skip one boxed PageTableRow.
 *
 * pageTableRow#e0c0c5e5  cells:Vector<PageTableCell>
 * (Api0.swift:804, Api20.swift:518-530)
 */
func skipPageTableRow(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor != 0xe0c0c5e5) {
        Hilog.info(0, "CjTelegram", "[skipPageTableRow] Unknown ctor: 0x${toHex32(ctor)}")
        return
    }
    let vecCtor = d.readUInt32()
    if (vecCtor == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        for (_ in 0..Int64(cnt)) { skipPageTableCell(d) }
    }
}

/**
 * skipPageBlock — skip one UNBOXED PageBlock value.
 *
 * Reads the ctor (UInt32) and dispatches per variant.
 * Recursive for variants containing Vector<PageBlock> or nested PageBlock.
 *
 * Full PageBlock ctor table (Api0.swift:758-795 + Api19.swift:1289-1938):
 *
 *   inputPageBlockMap  0x574b617f  geo:InputGeoPoint(boxed) zoom w h caption:PageCaption(boxed)
 *   pageBlockUnsupported 0x13567e8a (no fields)
 *   pageBlockDivider   0xdb20b188  (no fields)
 *   pageBlockAnchor    0xce0d37b0  name:string
 *   pageBlockMath      0x59080c20  source:string
 *   pageBlockTitle     0x70abc3fd  text:RichText(boxed)
 *   pageBlockSubtitle  0x8ffa9a1f  text:RichText(boxed)
 *   pageBlockHeader    0xbfd064ec  text:RichText(boxed)
 *   pageBlockSubheader 0xf12bb6e1  text:RichText(boxed)
 *   pageBlockFooter    0x48870999  text:RichText(boxed)
 *   pageBlockParagraph 0x467a0766  text:RichText(boxed)
 *   pageBlockKicker    0x1e148390  text:RichText(boxed)
 *   pageBlockHeading1  0xbaff072f  text:RichText(boxed)
 *   pageBlockHeading2  0x096b2aec  text:RichText(boxed)
 *   pageBlockHeading3  0x67e731ad  text:RichText(boxed)
 *   pageBlockHeading4  0xb532772b  text:RichText(boxed)
 *   pageBlockHeading5  0xdbbe6c6a  text:RichText(boxed)
 *   pageBlockHeading6  0x682a41a9  text:RichText(boxed)
 *   pageBlockThinking  0x3c29a3e2  text:RichText(boxed)
 *   pageBlockPreformatted 0xc070d93e text:RichText(boxed)  language:string
 *   pageBlockAuthorDate 0xbaafe5e0  author:RichText(boxed)  publishedDate:Int32
 *   pageBlockBlockquote 0x263d7c26  text:RichText(boxed)  caption:RichText(boxed)
 *   pageBlockPullquote  0x4f4456d3  text:RichText(boxed)  caption:RichText(boxed)
 *   pageBlockBlockquoteBlocks 0x0e6e47c4 blocks:Vector<PageBlock>  caption:RichText(boxed)
 *   pageBlockCover     0x39f23300  cover:PageBlock(boxed)
 *   pageBlockDetails   0x76768bed  flags:Int32  blocks:Vector<PageBlock>  title:RichText(boxed)
 *   pageBlockSlideshow 0x031f9590  items:Vector<PageBlock>  caption:PageCaption(boxed)
 *   pageBlockCollage   0x65a0fa4d  items:Vector<PageBlock>  caption:PageCaption(boxed)
 *   pageBlockEmbedPost 0xf259a80b  url:string  webpageId:Int64  authorPhotoId:Int64  author:string
 *                                  date:Int32  blocks:Vector<PageBlock>  caption:PageCaption(boxed)
 *   pageBlockPhoto     0x1759c560  flags:Int32  photoId:Int64  caption:PageCaption(boxed)
 *                                  url?[flags.0]:string  webpageId?[flags.0]:Int64
 *   pageBlockVideo     0x7c8fe7b6  flags:Int32  videoId:Int64  caption:PageCaption(boxed)
 *   pageBlockAudio     0x804361ea  audioId:Int64  caption:PageCaption(boxed)
 *   pageBlockEmbed     0xa8718dc5  flags:Int32  url?[flags.1]:string  html?[flags.2]:string
 *                                  posterPhotoId?[flags.4]:Int64  w?[flags.5]:Int32  h?[flags.5]:Int32
 *                                  caption:PageCaption(boxed)
 *   pageBlockMap       0xa44f3ef6  geo:GeoPoint(boxed)  zoom:Int32  w:Int32  h:Int32  caption:PageCaption(boxed)
 *   pageBlockList      0xe4e88011  items:Vector<PageListItem>
 *   pageBlockOrderedList 0x1fd6f6c1 flags:Int32  items:Vector<PageListOrderedItem>
 *                                   start?[flags.0]:Int32  type?[flags.1]:string
 *   pageBlockTable     0xbf4dea82  flags:Int32  title:RichText(boxed)  rows:Vector<PageTableRow>
 *   pageBlockRelatedArticles 0x16115a96 title:RichText(boxed)  articles:Vector<PageRelatedArticle>
 *   pageBlockChannel   0xef1751b5  channel:Chat(boxed) — skip by delegating to ChatResponse deserialization
 */
func skipPageBlock(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()

    // --- No-field variants ---
    if (ctor == 0x13567e8a) { return }  // pageBlockUnsupported
    if (ctor == 0xdb20b188) { return }  // pageBlockDivider

    // --- Single string ---
    if (ctor == 0xce0d37b0) { let _ = d.readString(); return }  // pageBlockAnchor: name:string
    if (ctor == 0x59080c20) { let _ = d.readString(); return }  // pageBlockMath: source:string

    // --- Single RichText(boxed) ---
    if (ctor == 0x70abc3fd || ctor == 0x8ffa9a1f || ctor == 0xbfd064ec || ctor == 0xf12bb6e1 ||
        ctor == 0x48870999 || ctor == 0x467a0766 || ctor == 0x1e148390 || ctor == 0xbaff072f ||
        ctor == 0x096b2aec || ctor == 0x67e731ad || ctor == 0xb532772b || ctor == 0xdbbe6c6a ||
        ctor == 0x682a41a9 || ctor == 0x3c29a3e2) {
        // pageBlockTitle/Subtitle/Header/Subheader/Footer/Paragraph/Kicker/Heading1-6/Thinking
        skipRichText(d)
        return
    }

    // pageBlockPreformatted 0xc070d93e — text:RichText(boxed)  language:string
    if (ctor == 0xc070d93e) { skipRichText(d); let _ = d.readString(); return }

    // pageBlockAuthorDate 0xbaafe5e0 — author:RichText(boxed)  publishedDate:Int32
    if (ctor == 0xbaafe5e0) { skipRichText(d); let _ = d.readInt32(); return }

    // pageBlockBlockquote 0x263d7c26 — text:RichText(boxed)  caption:RichText(boxed)
    if (ctor == 0x263d7c26) { skipRichText(d); skipRichText(d); return }

    // pageBlockPullquote 0x4f4456d3 — text:RichText(boxed)  caption:RichText(boxed)
    if (ctor == 0x4f4456d3) { skipRichText(d); skipRichText(d); return }

    // pageBlockBlockquoteBlocks 0x0e6e47c4 — blocks:Vector<PageBlock>  caption:RichText(boxed)
    if (ctor == 0x0e6e47c4) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_ in 0..Int64(cnt)) { skipPageBlock(d) }
        }
        skipRichText(d)  // caption
        return
    }

    // pageBlockCover 0x39f23300 — cover:PageBlock(boxed)  — single nested boxed PageBlock
    if (ctor == 0x39f23300) { skipPageBlock(d); return }

    // pageBlockDetails 0x76768bed — flags:Int32  blocks:Vector<PageBlock>  title:RichText(boxed)
    if (ctor == 0x76768bed) {
        let _ = d.readInt32()  // flags
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_ in 0..Int64(cnt)) { skipPageBlock(d) }
        }
        skipRichText(d)  // title
        return
    }

    // pageBlockSlideshow 0x031f9590 — items:Vector<PageBlock>  caption:PageCaption(boxed)
    if (ctor == 0x031f9590) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_ in 0..Int64(cnt)) { skipPageBlock(d) }
        }
        skipPageCaption(d)
        return
    }

    // pageBlockCollage 0x65a0fa4d — items:Vector<PageBlock>  caption:PageCaption(boxed)
    if (ctor == 0x65a0fa4d) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_ in 0..Int64(cnt)) { skipPageBlock(d) }
        }
        skipPageCaption(d)
        return
    }

    // pageBlockEmbedPost 0xf259a80b — url:string webpageId:Int64 authorPhotoId:Int64
    //   author:string date:Int32 blocks:Vector<PageBlock> caption:PageCaption(boxed)
    if (ctor == 0xf259a80b) {
        let _ = d.readString()   // url
        let _ = d.readInt64()    // webpageId
        let _ = d.readInt64()    // authorPhotoId
        let _ = d.readString()   // author
        let _ = d.readInt32()    // date
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_ in 0..Int64(cnt)) { skipPageBlock(d) }
        }
        skipPageCaption(d)
        return
    }

    // pageBlockPhoto 0x1759c560 — flags:Int32  photoId:Int64  caption:PageCaption(boxed)
    //   url?[flags.0]:string  webpageId?[flags.0]:Int64
    if (ctor == 0x1759c560) {
        let flags = d.readInt32()
        let _ = d.readInt64()   // photoId
        skipPageCaption(d)
        if ((flags & 1) != 0) { let _ = d.readString() }   // url
        if ((flags & 1) != 0) { let _ = d.readInt64() }    // webpageId
        return
    }

    // pageBlockVideo 0x7c8fe7b6 — flags:Int32  videoId:Int64  caption:PageCaption(boxed)
    if (ctor == 0x7c8fe7b6) {
        let _ = d.readInt32()   // flags
        let _ = d.readInt64()   // videoId
        skipPageCaption(d)
        return
    }

    // pageBlockAudio 0x804361ea — audioId:Int64  caption:PageCaption(boxed)
    if (ctor == 0x804361ea) {
        let _ = d.readInt64()   // audioId
        skipPageCaption(d)
        return
    }

    // pageBlockEmbed 0xa8718dc5 — flags:Int32  url?[flags.1]:string  html?[flags.2]:string
    //   posterPhotoId?[flags.4]:Int64  w?[flags.5]:Int32  h?[flags.5]:Int32  caption:PageCaption(boxed)
    if (ctor == 0xa8718dc5) {
        let flags = d.readInt32()
        if ((flags & 2) != 0) { let _ = d.readString() }    // url
        if ((flags & 4) != 0) { let _ = d.readString() }    // html
        if ((flags & 16) != 0) { let _ = d.readInt64() }    // posterPhotoId
        if ((flags & 32) != 0) { let _ = d.readInt32() }    // w
        if ((flags & 32) != 0) { let _ = d.readInt32() }    // h
        skipPageCaption(d)
        return
    }

    // pageBlockMap 0xa44f3ef6 — geo:GeoPoint(boxed)  zoom:Int32  w:Int32  h:Int32  caption:PageCaption(boxed)
    if (ctor == 0xa44f3ef6) {
        skipGeoPoint(d)          // geo (reads its own ctor)
        let _ = d.readInt32()   // zoom
        let _ = d.readInt32()   // w
        let _ = d.readInt32()   // h
        skipPageCaption(d)
        return
    }

    // inputPageBlockMap 0x574b617f — geo:InputGeoPoint(boxed)  zoom w h  caption:PageCaption(boxed)
    if (ctor == 0x574b617f) {
        skipInputGeoPoint(d)    // reads its own ctor
        let _ = d.readInt32()   // zoom
        let _ = d.readInt32()   // w
        let _ = d.readInt32()   // h
        skipPageCaption(d)
        return
    }

    // pageBlockList 0xe4e88011 — items:Vector<PageListItem>
    if (ctor == 0xe4e88011) {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_ in 0..Int64(cnt)) { skipPageListItem(d) }
        }
        return
    }

    // pageBlockOrderedList 0x1fd6f6c1 — flags:Int32  items:Vector<PageListOrderedItem>
    //   start?[flags.0]:Int32  type?[flags.1]:string
    if (ctor == 0x1fd6f6c1) {
        let flags = d.readInt32()
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_ in 0..Int64(cnt)) { skipPageListOrderedItem(d) }
        }
        if ((flags & 1) != 0) { let _ = d.readInt32() }   // start
        if ((flags & 2) != 0) { let _ = d.readString() }  // type
        return
    }

    // pageBlockTable 0xbf4dea82 — flags:Int32  title:RichText(boxed)  rows:Vector<PageTableRow>
    if (ctor == 0xbf4dea82) {
        let _ = d.readInt32()  // flags
        skipRichText(d)        // title
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_ in 0..Int64(cnt)) { skipPageTableRow(d) }
        }
        return
    }

    // pageBlockRelatedArticles 0x16115a96 — title:RichText(boxed)  articles:Vector<PageRelatedArticle>
    if (ctor == 0x16115a96) {
        skipRichText(d)   // title
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let cnt = d.readInt32()
            for (_ in 0..Int64(cnt)) { skipPageRelatedArticle(d) }
        }
        return
    }

    // pageBlockChannel 0xef1751b5 — channel:Chat(boxed)
    // Chat is a polymorphic boxed type; delegate to ChatResponse.deserializeWithConstructor
    if (ctor == 0xef1751b5) {
        let chatCtor = d.readUInt32()
        let _ = ChatResponse.deserializeWithConstructor(chatCtor, d)
        return
    }

    // Unknown PageBlock ctor — cannot safely skip; log for diagnostics
    Hilog.info(0, "CjTelegram", "[skipPageBlock] Unknown ctor: 0x${toHex32(ctor)}, stream may desync")
}

/**
 * skipRichMessage — skip a boxed Api.RichMessage from the wire stream.
 *
 * iOS wire layout (Api24.swift:109 parse_richMessage, ctor -1158439541 = 0xbb02aa9d):
 *   flags:int
 *   blocks:Vector<PageBlock>   (each element is a BOXED PageBlock — skip via skipPageBlock per element)
 *   photos:Vector<Photo>       (each element boxed — skip via skipPhoto)
 *   documents:Vector<Document> (each element boxed — skip via skipDocument)
 *
 * Called after reading the boxed constructor (readUInt32 already consumed by caller context).
 * Actually called by the TLDialogs.cj message# handler via: skipRichMessage(d)
 * which is invoked AFTER the outer boxed skip (readUInt32 for the RichMessage ctor).
 */
func skipRichMessage(d: TLDeserializer): Unit {
    // ctor already consumed by the outer boxed-read in message# handler
    let _ = d.readInt32()  // flags
    // blocks: Vector<PageBlock> — each element is BOXED, must skip via skipPageBlock
    let blocksCtor = d.readUInt32()
    if (blocksCtor == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        for (_ in 0..Int64(cnt)) { skipPageBlock(d) }
    }
    // photos: Vector<Photo>
    let photoCt = d.readUInt32()
    if (photoCt == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_ in 0..Int64(count)) {
            skipPhoto(d)
        }
    }
    // documents: Vector<Document>
    let docCt = d.readUInt32()
    if (docCt == TLConstructors.VECTOR) {
        let count = d.readInt32()
        for (_ in 0..Int64(count)) {
            skipDocument(d)
        }
    }
}

func skipStatsGraph(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x4a27eb2d) {
        let _ = d.readString()
    } else if (ctor == 0xbedc9822) {
        let _ = d.readString()
    } else if (ctor == 0x8ea464b6) {
        let flags = d.readInt32()
        let _ = d.readUInt32()
        let _ = d.readString()
        if ((flags & 1) != 0) { let _ = d.readString() }
    }
}

func readStatsGraph(d: TLDeserializer, response: StarsRevenueStatsResponse): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x4a27eb2d) {
        response.revenueGraphToken = d.readString()
    } else if (ctor == 0xbedc9822) {
        response.revenueGraphError = d.readString()
    } else if (ctor == 0x8ea464b6) {
        let flags = d.readInt32()
        let _ = d.readUInt32()
        response.revenueGraphJson = d.readString()
        if ((flags & 1) != 0) { let _ = d.readString() }
    }
}

func parseStarsRevenueStatus(d: TLDeserializer, response: StarsRevenueStatsResponse): Unit {
    let ctor = d.readUInt32()
    if (ctor != 0xfebe5491) { return }
    let flags = d.readInt32()
    response.withdrawalEnabled = (flags & 1) != 0
    let cur = parseStarsAmount(d)
    response.currentBalanceAmount = cur.amount
    response.currentBalanceNanos = cur.nanos
    let avail = parseStarsAmount(d)
    response.availableBalanceAmount = avail.amount
    response.availableBalanceNanos = avail.nanos
    let overall = parseStarsAmount(d)
    response.overallRevenueAmount = overall.amount
    response.overallRevenueNanos = overall.nanos
    if ((flags & 2) != 0) {
        response.nextWithdrawalAt = d.readInt32()
        response.hasNextWithdrawalAt = true
    }
}

public func parseStarsRevenueStats(data: Array<Byte>): StarsRevenueStatsResponse {
    let r = StarsRevenueStatsResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    // 0x6c207376 = current layer (iOS dict[1814066038]); 0xc92bb73b = old layer, kept compat
    if (ctor != 0x6c207376 && ctor != 0xc92bb73b) { return r }
    let flags = d.readInt32()
    if ((flags & 1) != 0) { skipStatsGraph(d) }
    readStatsGraph(d, r)
    parseStarsRevenueStatus(d, r)
    r.usdRate = d.readDouble()
    r.success = true
    return r
}

/**
 * StarsRevenueWithdrawalUrlResponse — wraps payments.getStarsRevenueWithdrawalUrl response.
 * payments.starsRevenueWithdrawalUrl#1dab80b7 url:string
 * tl_codegen verified: 0x1dab80b7 (telegram_api.tl:1894; iOS Api39.swift L819 appendInt32(497778871))
 */
public class StarsRevenueWithdrawalUrlResponse {
    public var success: Bool = false
    public var url: String = ""
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseStarsRevenueWithdrawalUrl(data: Array<Byte>): StarsRevenueWithdrawalUrlResponse {
    let r = StarsRevenueWithdrawalUrlResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    if (ctor != 0x1dab80b7) { return r }
    r.url = d.readString()
    r.success = true
    return r
}

// ==================== P2-368: TON 广告收入 — StarsRevenueAdsAccountUrl ====================

/**
 * StarsRevenueAdsAccountUrlResponse — wraps payments.getStarsRevenueAdsAccountUrl response.
 * payments.starsRevenueAdsAccountUrl#394e7f21 url:string
 * tl_codegen verified: iOS Api0.swift:1603 dict[961445665]
 * python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',961445665))[0]))"
 * → 0x394e7f21
 */
public class StarsRevenueAdsAccountUrlResponse {
    public var success: Bool = false
    public var url: String = ""
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

public func parseStarsRevenueAdsAccountUrl(data: Array<Byte>): StarsRevenueAdsAccountUrlResponse {
    let r = StarsRevenueAdsAccountUrlResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    if (ctor != 0x394e7f21) { return r }
    r.url = d.readString()
    r.success = true
    return r
}

// ==================== P2-155g: StarGiftAttribute parse + StarGiftUpgradePreview ====================

/**
 * StarGiftAttributeEntry — deserialized StarGiftAttribute variant.
 * Covers all 4 variants from iOS Api26.swift:1493-1735 / Api0.swift:1048-1051:
 *   starGiftAttributeBackdrop#9f2504e4  name backdropId centerColor edgeColor patternColor textColor rarityPermille
 *   starGiftAttributeModel#565251e2     name rarityPermille  (document skipped — not needed for preview UI)
 *   starGiftAttributePattern#4e7085ea   name rarityPermille  (document skipped)
 *   starGiftAttributeOriginalDetails#e0bff26c (no display fields exposed)
 *
 * kind: "backdrop" | "model" | "pattern" | "originalDetails"
 */
public class StarGiftAttributeEntry {
    public var kind: String = ""
    public var name: String = ""
    public var rarityPermille: Int32 = 0
    public var centerColor: Int32 = 0
    public var edgeColor: Int32 = 0
    public var patternColor: Int32 = 0
    public var textColor: Int32 = 0
    public var backdropId: Int32 = 0
    public var documentId: Int64 = 0
    public var count: Int32 = 0
}

/**
 * parseStarGiftAttributeBoxed — read one boxed StarGiftAttribute from the wire,
 * returning a filled StarGiftAttributeEntry.
 *
 * Wire layout per iOS Api26.swift parse functions:
 *
 * backdrop#9f2504e4:
 *   name:string backdropId:int centerColor:int edgeColor:int patternColor:int textColor:int
 *   rarity:StarGiftAttributeRarity(boxed)
 *
 * model#565251e2:
 *   flags:int name:string document:Document(boxed) rarity:StarGiftAttributeRarity(boxed)
 *
 * pattern#4e7085ea:
 *   name:string document:Document(boxed) rarity:StarGiftAttributeRarity(boxed)
 *
 * originalDetails#e0bff26c:
 *   flags:int senderId:flags.0?Peer(boxed) recipientId:Peer(boxed) date:int
 *   message:flags.1?TextWithEntities(boxed)
 *
 * iOS ref: Api26.swift:1626-1734, Api0.swift:1048-1051
 */
func parseStarGiftAttributeBoxed(d: TLDeserializer): StarGiftAttributeEntry {
    let entry = StarGiftAttributeEntry()
    let ctor = d.readUInt32()
    if (ctor == 0x9f2504e4) {
        entry.kind = "backdrop"
        entry.name = d.readString()
        entry.backdropId = d.readInt32()
        entry.centerColor = d.readInt32()
        entry.edgeColor = d.readInt32()
        entry.patternColor = d.readInt32()
        entry.textColor = d.readInt32()
        entry.rarityPermille = parseStarGiftAttributeRarityPermille(d)
    } else if (ctor == 0x565251e2) {
        entry.kind = "model"
        let _ = d.readInt32()
        entry.name = d.readString()
        let document = StarGiftEntry()
        parseStarGiftDocument(d, document)
        entry.documentId = document.documentId
        entry.rarityPermille = parseStarGiftAttributeRarityPermille(d)
    } else if (ctor == 0x4e7085ea) {
        entry.kind = "pattern"
        entry.name = d.readString()
        let document = StarGiftEntry()
        parseStarGiftDocument(d, document)
        entry.documentId = document.documentId
        entry.rarityPermille = parseStarGiftAttributeRarityPermille(d)
    } else if (ctor == 0xe0bff26c) {
        entry.kind = "originalDetails"
        let flags2 = d.readInt32()
        if ((flags2 & 1) != 0) { let _ = PeerResponse.deserializeBoxed(d) }
        let _ = PeerResponse.deserializeBoxed(d)
        let _ = d.readInt32()
        if ((flags2 & 2) != 0) { skipTextWithEntities(d) }
    }
    return entry
}

/**
 * StarGiftUpgradePriceEntry — one starGiftUpgradePrice entry.
 * starGiftUpgradePrice#99ea331d date:int upgrade_stars:long
 * iOS ref: Api27.swift:883-930
 * Ctor: -1712704739 signed = 0x99ea331d unsigned (from Api27.swift:901)
 */
public class StarGiftUpgradePriceEntry {
    public var date: Int32 = 0
    public var upgradeStars: Int64 = 0
}

/**
 * parseStarGiftUpgradePriceBoxed — read one boxed starGiftUpgradePrice.
 * Wire: ctor(uint32) + date:int + upgradeStars:long
 * iOS ref: Api27.swift:916-929
 */
func parseStarGiftUpgradePriceBoxed(d: TLDeserializer): StarGiftUpgradePriceEntry {
    let entry = StarGiftUpgradePriceEntry()
    let ctor = d.readUInt32()
    if (ctor == 0x99ea331d) {
        entry.date = d.readInt32()
        entry.upgradeStars = d.readInt64()
    }
    return entry
}

/**
 * StarGiftUpgradePreviewResponse — parsed response for payments.getStarGiftUpgradePreview.
 *
 * payments.starGiftUpgradePreview#3de1dfed
 *   sample_attributes:Vector<StarGiftAttribute>(boxed)
 *   prices:Vector<StarGiftUpgradePrice>(boxed)
 *   next_prices:Vector<StarGiftUpgradePrice>(boxed)
 *
 * Constructor 0x3de1dfed = 1038213101 signed (from Api39.swift:492)
 * iOS ref: Api39.swift:472-543
 */
public class StarGiftUpgradePreviewResponse {
    public var success: Bool = false
    public var sampleAttributes: ArrayList<StarGiftAttributeEntry> = ArrayList<StarGiftAttributeEntry>()
    public var prices: ArrayList<StarGiftUpgradePriceEntry> = ArrayList<StarGiftUpgradePriceEntry>()
    public var nextPrices: ArrayList<StarGiftUpgradePriceEntry> = ArrayList<StarGiftUpgradePriceEntry>()
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
}

/**
 * parseStarGiftUpgradePreview — top-level parse for payments.getStarGiftUpgradePreview response.
 *
 * Wire layout (from Api39.swift:520-542):
 *   [vector ctor 0x1cb5c415] [count] [StarGiftAttribute boxed ...]  — sampleAttributes
 *   [vector ctor 0x1cb5c415] [count] [StarGiftUpgradePrice boxed ...] — prices
 *   [vector ctor 0x1cb5c415] [count] [StarGiftUpgradePrice boxed ...] — nextPrices
 *
 * iOS ref: Api39.swift:520-542, Api0.swift:1599 (dispatch key 1038213101)
 */
public func parseStarGiftUpgradePreview(data: Array<Byte>): StarGiftUpgradePreviewResponse {
    let r = StarGiftUpgradePreviewResponse()
    if (data.size < 4) { return r }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        r.errorCode = d.readInt32()
        r.errorMessage = d.readString()
        return r
    }
    if (ctor != 0x3de1dfed) { return r }
    let attrVec = d.readUInt32()
    if (attrVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var i: Int32 = 0
        while (i < cnt) {
            let attr = parseStarGiftAttributeBoxed(d)
            r.sampleAttributes.add(attr)
            i = i + 1
        }
    }
    let priceVec = d.readUInt32()
    if (priceVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var i: Int32 = 0
        while (i < cnt) {
            let price = parseStarGiftUpgradePriceBoxed(d)
            r.prices.add(price)
            i = i + 1
        }
    }
    let nextPriceVec = d.readUInt32()
    if (nextPriceVec == TLConstructors.VECTOR) {
        let cnt = d.readInt32()
        var i: Int32 = 0
        while (i < cnt) {
            let price = parseStarGiftUpgradePriceBoxed(d)
            r.nextPrices.add(price)
            i = i + 1
        }
    }
    r.success = true
    return r
}

/**
 * PasskeyCreatedResponse — wraps account.registerPasskey response.
 * Parses: passkey#98613ebf flags:# id:string name:string date:int
 *   softwareEmojiId:flags.0?long lastUsageDate:flags.1?int
 * iOS ref: Api42.swift L1089; same passkey type as in passkeys list
 */
public class PasskeyCreatedResponse {
    public var info: Option<PasskeyInfo> = None

    public static func deserialize(data: Array<Byte>): PasskeyCreatedResponse {
        let r = PasskeyCreatedResponse()
        if (data.size < 8) { return r }
        let d = TLDeserializer(data)
        try {
            let ctor = d.readUInt32()
            if (ctor == 0x98613ebf) {
                let info = PasskeyInfo()
                let flags = d.readInt32()
                info.id = d.readString()
                info.name = d.readString()
                info.date = d.readInt32()
                if ((flags & 1) != 0) {
                    info.softwareEmojiId = d.readInt64()
                    info.hasSoftwareEmojiId = true
                }
                if ((flags & 2) != 0) {
                    info.lastUsageDate = d.readInt32()
                    info.hasLastUsageDate = true
                }
                r.info = Some(info)
                Hilog.info(0, "CjTelegram", "[PasskeyCreated] passkey id=${info.id} name=${info.name}")
            } else {
                Hilog.info(0, "CjTelegram", "[PasskeyCreated] unexpected ctor: 0x${toHex32(ctor)}")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PasskeyCreated] parse error: ${e}")
        }
        return r
    }
}

// ==================== P2-138: 邀请链接入群请求审批响应 ====================

/**
 * ChatInviteImporterData — 单个 chatInviteImporter 条目
 *
 * TL Schema (iOS Api5.swift): chatInviteImporter#8c5adfd9
 *   flags:# requested:flags.0?true via_chatlist:flags.3?true
 *   user_id:long date:int about:flags.2?string approved_by:flags.1?long
 *
 * iOS ref: Api5.swift:parse_chatInviteImporter
 *   flags.0 → requested (pending approval)
 *   flags.1 → approved_by (Int64)
 *   flags.2 → about (String)
 *   flags.3 → via_chatlist
 */
public class ChatInviteImporterData {
    public var userId: Int64 = 0
    public var date: Int32 = 0
    public var requested: Bool = false
    public var viaChatlist: Bool = false
    public var about: String = ""
    public var approvedBy: Int64 = 0
    public var hasApprovedBy: Bool = false
}

/**
 * 解析单个 chatInviteImporter 条目（constructor 已读取，非 boxed）
 * 用于 P2-138: getChatInviteImportersWithData
 */
func parseChatInviteImporter(d: TLDeserializer): ChatInviteImporterData {
    let item = ChatInviteImporterData()
    let flags = d.readInt32()
    item.requested = (flags & 1) != 0
    item.viaChatlist = (flags & 8) != 0
    item.userId = d.readInt64()
    item.date = d.readInt32()
    if ((flags & 4) != 0) { item.about = d.readString() }
    if ((flags & 2) != 0) {
        item.approvedBy = d.readInt64()
        item.hasApprovedBy = true
    }
    return item
}

/**
 * messages.ChatInviteImporters 响应
 *
 * TL Schema: messages.chatInviteImporters#81b6b00a
 *   count:int importers:Vector<ChatInviteImporter> users:Vector<User>
 *
 * iOS ref: Api36.swift:parse_chatInviteImporters
 *   count: Int32 (直接读，不是 boxed)
 *   importers: 读 vector constructor (0x1cb5c415) → count → 每项读 boxed ctor(0x8c5adfd9) + fields
 *   users: 读 vector constructor (0x1cb5c415) → count → 每项用 UserResponse.deserializeBoxed
 */
public class ChatInviteImportersResponse {
    public var count: Int32 = 0
    public var importers: ArrayList<ChatInviteImporterData> = ArrayList<ChatInviteImporterData>()
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()

    public static func deserialize(data: Array<Byte>): ChatInviteImportersResponse {
        let r = ChatInviteImportersResponse()
        if (data.size < 4) { return r }
        let d = TLDeserializer(data)
        let outerCtor = d.readUInt32()

        if (outerCtor == TLConstructors.RPC_ERROR || outerCtor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[ChatInviteImporters] RPC error: ${errMsg}")
            return r
        }

        if (outerCtor != 0x81b6b00a) {
            Hilog.info(0, "CjTelegram", "[ChatInviteImporters] unexpected ctor: 0x${toHex32(outerCtor)}")
            return r
        }

        r.count = d.readInt32()

        // importers: Vector<ChatInviteImporter>
        let importerVecCtor = d.readUInt32()
        if (importerVecCtor == TLConstructors.VECTOR) {
            let importerCount = d.readInt32()
            Hilog.info(0, "CjTelegram", "[ChatInviteImporters] parsing ${importerCount} importers")
            var idx: Int64 = 0
            while (idx < Int64(importerCount)) {
                idx = idx + 1
                // each importer is boxed: ctor 0x8c5adfd9 + fields
                let itemCtor = d.readUInt32()
                if (itemCtor == 0x8c5adfd9) {
                    try {
                        r.importers.add(parseChatInviteImporter(d))
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatInviteImporters] error parsing importer: ${e}")
                        break
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatInviteImporters] unexpected importer ctor: 0x${toHex32(itemCtor)}")
                    break
                }
            }
        }

        // users: Vector<User> — use UserResponse.deserializeBoxed for full variant coverage
        let usersVecCtor = d.readUInt32()
        if (usersVecCtor == TLConstructors.VECTOR) {
            let usersCount = d.readInt32()
            Hilog.info(0, "CjTelegram", "[ChatInviteImporters] parsing ${usersCount} users")
            var uIdx: Int64 = 0
            while (uIdx < Int64(usersCount)) {
                uIdx = uIdx + 1
                try {
                    r.users.add(UserResponse.deserializeBoxed(d))
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatInviteImporters] error parsing user: ${e}")
                    break
                }
            }
        }

        Hilog.info(0, "CjTelegram", "[ChatInviteImporters] count=${r.count} importers=${r.importers.size} users=${r.users.size}")
        return r
    }
}

/**
 * Updates 成功标志响应 — hideChatJoinRequest / hideAllChatJoinRequests 返回 Updates
 *
 * Updates constructor 集合 (iOS: Updates.swift):
 *   updates#74ae4240
 *   updatesCombined#725b04c3
 *   updateShort#78d4dec1
 *   updatesTooLong#e317af7e
 *
 * 仅判断操作是否成功，不需要处理 Updates 内容。
 */
public class JoinRequestUpdatesResponse {
    public var success: Bool = false
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""

    public static func deserialize(data: Array<Byte>): JoinRequestUpdatesResponse {
        let r = JoinRequestUpdatesResponse()
        if (data.size < 4) { return r }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            r.errorCode = d.readInt32()
            r.errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[JoinRequestUpdates] error: ${r.errorCode} ${r.errorMessage}")
            return r
        }
        if (ctor == 0x74ae4240 || ctor == 0x725b04c3 || ctor == 0x78d4dec1 || ctor == 0xe317af7e) {
            r.success = true
        }
        Hilog.info(0, "CjTelegram", "[JoinRequestUpdates] success=${r.success} ctor=0x${toHex32(ctor)}")
        return r
    }
}

// ==================== P2-119 r1: messages.report ReportResult Response ====================

/**
 * MessageReportOption — one server-side option returned by reportResultChooseOption.
 *
 * TL: messageReportOption#7903e3d9 text:string option:bytes = MessageReportOption
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I', struct.pack('<i', 2030298073))[0]))"
 *   → 0x7903e3d9
 * iOS ref: Api18.swift:740 parse_messageReportOption — reads text:String then option:Buffer
 */
public class MessageReportOption {
    public var text: String = ""
    public var optionBytes: Array<Byte> = Array<Byte>(0, repeat: 0)
}

/**
 * ReportResultResponse — parsed result of messages.report#fc78af9b
 *
 * Three variants from TL schema (telegram_api.tl:1926-1928):
 *   reportResultChooseOption#f0e4e0b6 title:string options:Vector<MessageReportOption>
 *   reportResultAddComment#6f09ac31  flags:# optional:flags.0?true option:bytes
 *   reportResultReported#8db33c4b   (no fields)
 *
 * Ctor values verified against iOS Api23.swift serialize() int32 constants and TL schema:
 *   reportResultChooseOption: python3 -c "import struct; print(hex(struct.unpack('<I', struct.pack('<i', -253435722))[0]))"  → 0xf0e4e0b6
 *   reportResultAddComment:   python3 -c "print(hex(1862904881))"  → 0x6f09ac31
 *   reportResultReported:     python3 -c "import struct; print(hex(struct.unpack('<I', struct.pack('<i', -1917633461))[0]))" → 0x8db33c4b
 *
 * iOS ref: ReportContent.swift:72 map { result -> ReportContentResult in ... } + Api23.swift:654-686
 */
public class ReportResultResponse {
    // "choose_option" | "add_comment" | "reported" | "unknown"
    public var kind: String = "unknown"
    // For choose_option:
    public var chooseTitle: String = ""
    public var chooseOptions: ArrayList<MessageReportOption> = ArrayList<MessageReportOption>()
    // For add_comment:
    public var addCommentOptional: Bool = false
    public var addCommentOption: Array<Byte> = Array<Byte>(0, repeat: 0)

    public static func deserialize(data: Array<Byte>): ReportResultResponse {
        let r = ReportResultResponse()
        if (data.size < 4) {
            Hilog.info(0, "CjTelegram", "[ReportResult] data too short: ${data.size}")
            return r
        }
        let d = TLDeserializer(data)
        try {
            let ctor = d.readUInt32()
            if (ctor == 0xf0e4e0b6u32) {
                // reportResultChooseOption: title:string options:Vector<MessageReportOption>
                r.kind = "choose_option"
                r.chooseTitle = d.readString()
                // Vector header: 0x1cb5c415 + count
                let vecCtor = d.readUInt32()
                if (vecCtor == 0x1cb5c415u32) {
                    let count = d.readInt32()
                    var i: Int32 = 0
                    while (i < count) {
                        let optCtor = d.readUInt32()
                        if (optCtor == 0x7903e3d9u32) {
                            let opt = MessageReportOption()
                            opt.text = d.readString()
                            opt.optionBytes = d.readBytes()
                            r.chooseOptions.add(opt)
                        } else {
                            Hilog.info(0, "CjTelegram", "[ReportResult] unexpected option ctor: 0x${toHex32(optCtor)}")
                        }
                        i++
                    }
                }
                Hilog.info(0, "CjTelegram", "[ReportResult] choose_option title='${r.chooseTitle}' count=${r.chooseOptions.size}")
            } else if (ctor == 0x6f09ac31u32) {
                // reportResultAddComment: flags:# optional:flags.0?true option:bytes
                r.kind = "add_comment"
                let flags = d.readInt32()
                r.addCommentOptional = (flags & 1) != 0
                r.addCommentOption = d.readBytes()
                Hilog.info(0, "CjTelegram", "[ReportResult] add_comment optional=${r.addCommentOptional}")
            } else if (ctor == 0x8db33c4bu32) {
                // reportResultReported: no fields
                r.kind = "reported"
                Hilog.info(0, "CjTelegram", "[ReportResult] reported (direct success)")
            } else {
                Hilog.info(0, "CjTelegram", "[ReportResult] unknown ctor: 0x${toHex32(ctor)}")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ReportResult] parse error: ${e}")
        }
        return r
    }
}

// ==================== P2-330: Global Auto-Delete Response ====================

/**
 * DefaultHistoryTTLResponse — parses defaultHistoryTTL#43b46b20 period:int
 * iOS ref: Api5.swift:1563 appendInt32(1135897376) -> 0x43b46b20
 * ctor verified: python3 -c "print(hex(1135897376))" -> 0x43b46b20
 */
public class DefaultHistoryTTLResponse {
    public var period: Int32 = 0

    public static func deserialize(data: Array<Byte>): DefaultHistoryTTLResponse {
        let r = DefaultHistoryTTLResponse()
        if (data.size < 8) { return r }
        let d = TLDeserializer(data)
        try {
            let ctor = d.readUInt32()
            if (ctor == 0x43b46b20) {
                r.period = d.readInt32()
                Hilog.info(0, "CjTelegram", "[DefaultHistoryTTL] period=${r.period}")
            } else {
                Hilog.info(0, "CjTelegram", "[DefaultHistoryTTL] unexpected ctor: 0x${toHex32(ctor)}")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[DefaultHistoryTTL] parse error: ${e}")
        }
        return r
    }
}
