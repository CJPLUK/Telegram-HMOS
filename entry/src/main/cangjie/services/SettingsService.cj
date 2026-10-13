package ohos_app_cangjie_entry.services

import std.collection.ArrayList
import std.convert.*
import std.time.DateTime
import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import ohos_app_cangjie_entry.core.storage.{getAuthStorage, AuthStorage, registerLogoutHook, trOr}
import ohos_app_cangjie_entry.router.routerPush
import ohos_app_cangjie_entry.core.mtproto.{TLObject, ChatResponse}
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    TLDeserializer,
    TLSerializer,
    TLConstructors,
    AccountGetAuthorizations,
    AccountResetAuthorization,
    AccountUpdateProfile,
    AccountGetPrivacy,
    AccountSetPrivacy,
    AccountGetPassword,
    AccountDeleteAccount,
    AuthLogOut,
    AccountGetAccountTTL,
    AccountSetAccountTTL,
    AccountGetContentSettings,
    AccountSetContentSettings,
    AccountGetNotifySettings,
    AccountUpdateNotifySettings,
    AccountCheckUsername,
    AccountUpdateUsername,
    PhotosUploadProfilePhoto,
    VideoSizeEmojiMarkup,
    PhotosUpdateProfilePhoto,
    PhotosDeletePhotos,
    AccountUpdateBirthday,
    AccountUpdateColor,
    AccountUpdateEmojiStatus,
    AccountUpdatePersonalChannel,
    AccountToggleSponsoredMessages,
    HelpGetTimezonesList,
    AccountUpdateBusinessWorkHours,
    BusinessWorkHours,
    BusinessWeeklyOpen,
    AccountUpdateBusinessLocation,
    AccountUpdateBusinessGreetingMessage,
    InputBusinessGreetingMessage,
    InputBusinessRecipients,
    AccountUpdateBusinessAwayMessage,
    InputBusinessAwayMessage,
    AccountUpdateBusinessIntro,
    InputBusinessIntro,
    AccountUpdateConnectedBot,
    BusinessBotRights,
    InputBusinessBotRecipients,
    InputUser,
    AccountGetBotBusinessConnection,
    AccountCreateBusinessChatLink,
    AccountEditBusinessChatLink,
    AccountDeleteBusinessChatLink,
    AccountGetBusinessChatLinks,
    InputBusinessChatLink,
    MessagesGetQuickReplies,
    MessagesEditQuickReplyShortcut,
    MessagesDeleteQuickReplyShortcut,
    MessagesGetQuickReplyMessages,
    MessagesReorderQuickReplies,
    AccountGetWebBrowserSettings,
    AccountUpdateWebBrowserSettings,
    AccountToggleWebBrowserSettingsException,
    AccountDeleteWebBrowserSettingsExceptions
}
// ======================================================================
// Data types
// ======================================================================

/**
 * Represents a single active session / authorized device.
 * Maps to Telegram authorization TL object.
 */
public class AuthorizationSession {
    public var hash: Int64 = 0
    public var deviceModel: String = ""
    public var platform: String = ""
    public var systemVersion: String = ""
    public var apiId: Int32 = 0
    public var appName: String = ""
    public var appVersion: String = ""
    public var dateCreated: Int32 = 0
    public var dateActive: Int32 = 0
    public var ip: String = ""
    public var country: String = ""
    public var region: String = ""
    public var isCurrent: Bool = false
    public var isOfficialApp: Bool = false
    public var isPasswordPending: Bool = false
    public var isUnconfirmed: Bool = false
    public var encryptedRequestsDisabled: Bool = false
    public var callRequestsDisabled: Bool = false
}

/**
 * Privacy rule value
 * - 0 = Everyone
 * - 1 = Contacts
 * - 2 = Nobody
 */
public class PrivacySettingResult {
    public var keyCode: String = ""  // "statusTimestamp", "chatInvite", "phoneCall", etc.
    public var value: Int32 = 0      // 0=Everyone, 1=Contacts, 2=Nobody
}

/**
 * Account TTL (auto-delete) settings
 */
public class AccountTTLData {
    public var days: Int32 = 180
}

/**
 * Two-step verification (2SV) status
 */
public class TwoStepVerificationStatus {
    public var hasPassword: Bool = false
    public var hasRecoveryEmailAddress: Bool = false
    public var hasSecureValues: Bool = false
    public var pendingResetDate: Int32 = 0
    public var emailUnconfirmedPattern: String = ""
    public var hint: String = ""
}

// ==================== P2-153 Data Types ====================

/**
 * Result of photos.uploadProfilePhoto + photos.updateProfilePhoto.
 * Returns the new photo's id/access_hash for local caching.
 * iOS ref: UploadedPeerPhoto / photos.Photo in TelegramEngineAccountData.
 */
public class ProfilePhotoResult {
    public var success: Bool = false
    public var photoId: Int64 = 0
    public var accessHash: Int64 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
}

/**
 * Birthday data — mirrors birthday#6c8e1e06 TL type.
 * iOS ref: TelegramBirthday in TelegramCore/Sources/ApiUtils/TelegramBirthday.swift
 */
public class BirthdayData {
    public var day: Int32 = 0
    public var month: Int32 = 0
    public var year: Int32 = 0    // 0 = not set
}

/**
 * iOS stringForCompactBirthday (TelegramStringFormatting/PresenceStrings.swift:187-202):
 * "15 Mar 1990", plus " (35 years old)" when showAge and the year is known.
 */
public func compactBirthdayString(bd: BirthdayData, showAge!: Bool = false): String {
    let monthKeys: Array<(String, String)> = [
        ("Month.ShortJanuary", "Jan"), ("Month.ShortFebruary", "Feb"), ("Month.ShortMarch", "Mar"),
        ("Month.ShortApril", "Apr"), ("Month.ShortMay", "May"), ("Month.ShortJune", "Jun"),
        ("Month.ShortJuly", "Jul"), ("Month.ShortAugust", "Aug"), ("Month.ShortSeptember", "Sep"),
        ("Month.ShortOctober", "Oct"), ("Month.ShortNovember", "Nov"), ("Month.ShortDecember", "Dec")
    ]
    var text = "${bd.day}"
    let mi = Int64(bd.month) - 1
    if (mi >= 0 && mi < 12) {
        let (key, fallback) = monthKeys[mi]
        text = text + " " + trOr(key, fallback)
    }
    if (bd.year > 0) {
        text = text + " ${bd.year}"
        if (showAge) {
            let now = DateTime.now()
            var age = Int64(now.year) - Int64(bd.year)
            let curMonth = Int64(now.month.toInteger())
            if (curMonth < Int64(bd.month) || (curMonth == Int64(bd.month) && Int64(now.dayOfMonth) < Int64(bd.day))) {
                age = age - 1
            }
            if (age > 0) {
                let ageText = if (age == 1) { trOr("UserInfo.Age_1", "%@ year old") } else { trOr("UserInfo.Age_any", "%@ years old") }
                text = text + " (" + ageText.replace("%@", "${age}") + ")"
            }
        }
    }
    return text
}

/**
 * Timezone item — mirrors timezone#ff9289f5 TL type.
 * iOS ref: TelegramCore/Sources/ApiUtils/TelegramTimezone.swift
 */
public class TimezoneInfo {
    public var id: String = ""
    public var name: String = ""
    public var utcOffset: Int32 = 0
}

// ==================== P2-153b Data Types ====================

/**
 * One time-window within a week for business work hours.
 * Maps to businessWeeklyOpen#120b1ab9 TL type.
 * startMinute / endMinute: minutes since Monday 00:00.
 */
public class BusinessWeeklyOpenData {
    public var startMinute: Int32 = 0
    public var endMinute: Int32 = 0
}

/**
 * Business work hours (timezone + weekly schedule).
 * Maps to businessWorkHours#8c92b098 TL type.
 */
public class BusinessWorkHoursData {
    public var openNow: Bool = false
    public var timezoneId: String = ""
    public var weeklyOpen: ArrayList<BusinessWeeklyOpenData> = ArrayList<BusinessWeeklyOpenData>()
}

/**
 * Business location (optional geo + address).
 * Maps to businessLocation#ac5c1af7 TL type.
 */
public class BusinessLocationData {
    public var hasGeoPoint: Bool = false
    public var geoLat: Float64 = 0.0
    public var geoLon: Float64 = 0.0
    public var address: String = ""
}

/**
 * Business recipients filter (who receives the greeting/away message).
 * Maps to inputBusinessRecipients#6f8b32aa TL type.
 * userIds: list of user_id values for explicit user selection.
 */
public class BusinessRecipientsData {
    public var existingChats: Bool = true
    public var newChats: Bool = true
    public var contacts: Bool = true
    public var nonContacts: Bool = false
    public var excludeSelected: Bool = false
    public var userIds: ArrayList<Int64> = ArrayList<Int64>()
    public var userAccessHashes: ArrayList<Int64> = ArrayList<Int64>()
}

/**
 * Business greeting message setup.
 * Maps to inputBusinessGreetingMessage#194cb3b TL type.
 */
public class BusinessGreetingMessageData {
    public var shortcutId: Int32 = 0
    public var recipients: BusinessRecipientsData = BusinessRecipientsData()
    public var noActivityDays: Int32 = 7
}

/**
 * Away message schedule type.
 *  0 = always
 *  1 = outsideWorkHours
 *  2 = custom (startDate/endDate required)
 */
public class BusinessAwayMessageScheduleData {
    public var scheduleType: Int32 = 0
    public var startDate: Int32 = 0
    public var endDate: Int32 = 0
}

/**
 * Business away message setup.
 * Maps to inputBusinessAwayMessage#832175e0 TL type.
 */
public class BusinessAwayMessageData {
    public var offlineOnly: Bool = false
    public var shortcutId: Int32 = 0
    public var schedule: BusinessAwayMessageScheduleData = BusinessAwayMessageScheduleData()
    public var recipients: BusinessRecipientsData = BusinessRecipientsData()
}

/**
 * Business intro (title + description + optional sticker).
 * Maps to inputBusinessIntro#9c469cd TL type.
 */
public class BusinessIntroData {
    public var title: String = ""
    public var description: String = ""
    public var hasStickerDocId: Bool = false
    public var stickerDocId: Int64 = 0
    public var stickerAccessHash: Int64 = 0
}

/**
 * Connected bot info for account.updateConnectedBot.
 * iOS ref: TelegramAccountConnectedBot in QuickReplyMessages.swift:1249
 */
public class ConnectedBotData {
    public var botUserId: Int64 = 0
    public var botAccessHash: Int64 = 0
    public var rightFlags: Int32 = 0
    public var recipients: BusinessRecipientsData = BusinessRecipientsData()
}

/**
 * Bot-business connection info returned by account.getBotBusinessConnection.
 * Maps to botBusinessConnection#8f34b2f5 TL type.
 */
public class BotBusinessConnectionData {
    public var disabled: Bool = false
    public var connectionId: String = ""
    public var userId: Int64 = 0
    public var dcId: Int32 = 0
    public var date: Int32 = 0
    public var rightFlags: Int32 = 0
}

/**
 * A single business chat link.
 * Maps to businessChatLink#b4ae666f TL type.
 */
public class BusinessChatLinkData {
    public var link: String = ""
    public var message: String = ""
    public var title: String = ""
    public var views: Int32 = 0
}

/**
 * Quick reply shortcut (summary).
 * Maps to quickReply#0697102b TL type.
 */
public class QuickReplyShortcutData {
    public var shortcutId: Int32 = 0
    public var shortcut: String = ""
    public var topMessage: Int32 = 0
    public var count: Int32 = 0
}

// ==================== FIX TC-0435/TC-0436 R1: Web Browser account settings ====================

/**
 * One domain exception entry (allow/deny in-app browser override for a single domain).
 * Maps to webDomainException#933ca597 TL type.
 * iOS ref: TelegramCore/Sources/Settings/AccountWebBrowserSettings.swift AccountWebBrowserException.
 */
public class WebBrowserException {
    public var domain: String = ""
    public var url: String = ""
    public var title: String = ""
    public var favicon: Int64 = 0
}

/**
 * Account-level web browser settings state.
 * Maps to account.webBrowserSettings#79eb8cb3 TL type.
 * iOS ref: TelegramCore/Sources/Settings/AccountWebBrowserSettings.swift AccountWebBrowserSettings.
 * Default mirrors AccountWebBrowserSettings.defaultSettings (openExternalBrowser=false, empty lists, hash=0).
 */
public class WebBrowserSettingsState {
    public var openExternalBrowser: Bool = false
    public var externalExceptions: ArrayList<WebBrowserException> = ArrayList<WebBrowserException>()
    public var inAppExceptions: ArrayList<WebBrowserException> = ArrayList<WebBrowserException>()
    public var hash: Int64 = 0
}

// Preferences store/keys for the R1 cache (self-contained, does not extend AuthStorage's schema).
// D-163: this store is account-scoped but not (yet) in AuthStorage.cj:clearAll()'s logout
// enumeration, and SettingsService is a lazy singleton that outlives logout — see
// SettingsService.invalidateWebBrowserSettingsCache() and this feature's
// emitted_integration_contracts[ic_wbs_cache_invalidate_on_logout] for the explicit invalidate
// hook + hand-off (core/storage/AuthStorage.cj isn't in this feature's allowlist).
let WEB_BROWSER_SETTINGS_STORE_NAME: String = "telegram_web_browser_settings"
let KEY_WBS_OPEN_EXTERNAL: String = "open_external_browser"
let KEY_WBS_HASH: String = "hash"
let KEY_WBS_EXTERNAL_EXCEPTIONS: String = "external_exceptions"
let KEY_WBS_INAPP_EXCEPTIONS: String = "inapp_exceptions"
// Field separator used inside one serialized exception entry (domain\u{1E}url\u{1E}title\u{1E}favicon).
let WBS_FIELD_SEP: String = "\u{1E}"

// ======================================================================
// SettingsService
// ======================================================================

/**
 * SettingsService — Central API service for Settings UI.
 *
 * Corresponds to iOS SettingsUI + TelegramCore/Sources/Settings.
 * Encapsulates all TL method calls used across settings sub-pages.
 *
 * Call chain: SettingsService → MTProtoClient.send() → Telegram server.
 * Local prefs are stored / retrieved via AuthStorage.
 *
 * TL methods covered:
 *  - account.getAuthorizations / account.resetAuthorization
 *  - account.updateProfile
 *  - account.getPrivacy / account.setPrivacy
 *  - account.getPassword (2SV status)
 *  - account.deleteAccount
 *  - account.getAccountTTL / account.setAccountTTL
 *  - account.getNotifySettings / account.updateNotifySettings
 *  - account.checkUsername / account.updateUsername
 */
public class SettingsService {

    // Preferences store for FIX TC-0435/TC-0436 R1 web browser settings cache
    // (self-contained: this service does not extend AuthStorage's schema).
    // D-163: must be invalidated on logout via invalidateWebBrowserSettingsCache() — see that
    // method's doc comment and the comment on WEB_BROWSER_SETTINGS_STORE_NAME above.
    private var _wbsPrefs: Option<Preferences> = None

    // ========== Authorized sessions (account.getAuthorizations) ==========

    /**
     * Fetches all active authorized sessions from the server.
     * iOS ref: RecentSessionsController + DevicesPage
     * TL: account.getAuthorizations#e320c158 = account.Authorizations
     */
    public func getAuthorizations(): ArrayList<AuthorizationSession> {
        let result = ArrayList<AuthorizationSession>()
        try {
            let client = getMTProtoClient()
            let req = AccountGetAuthorizations()
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return result }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] getAuthorizations error: ${errCode} ${errMsg}")
                return result
            }
            // account.authorizations#ad01d61d authorization_ttl_days:int authorizations:Vector<authorization>
            if (ctor == 0xad01d61d) {
                let _ = d.readInt32()  // authorization_ttl_days
                let vecCtor = d.readUInt32()
                if (vecCtor != 0x1cb5c415) { return result }
                let count = d.readInt32()
                var i: Int32 = 0
                while (i < count && data.size > 16) {
                    let session = SettingsService.parseAuthorization(d)
                    result.add(session)
                    i = i + 1
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] getAuthorizations exception: ${e}")
        }
        return result
    }

    private static func parseAuthorization(d: TLDeserializer): AuthorizationSession {
        let s = AuthorizationSession()
        try {
            let authCtor = d.readUInt32()
            if (authCtor == 0xad01d61d || authCtor == 0x1e7482c4) {
                // authorization#1e7482c4 flags:# ...
                let flags = d.readInt32()
                s.isCurrent = (flags & 1) != 0
                s.isOfficialApp = (flags & 2) != 0
                s.isPasswordPending = (flags & 4) != 0
                s.isUnconfirmed = (flags & 32) != 0
                s.encryptedRequestsDisabled = (flags & 8) != 0
                s.callRequestsDisabled = (flags & 16) != 0
                s.hash = d.readInt64()
                s.deviceModel = d.readString()
                s.platform = d.readString()
                s.systemVersion = d.readString()
                s.apiId = d.readInt32()
                s.appName = d.readString()
                s.appVersion = d.readString()
                s.dateCreated = d.readInt32()
                s.dateActive = d.readInt32()
                s.ip = d.readString()
                s.country = d.readString()
                s.region = d.readString()
            }
        } catch (_e: Exception) {}
        return s
    }

    /**
     * Terminates a specific authorized session by its hash.
     * TL: account.resetAuthorization#df77f3bc hash:long = Bool
     * Returns true on success.
     */
    public func resetAuthorization(hash: Int64): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountResetAuthorization()
            req.hash = hash
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] resetAuthorization error: ${errCode} ${errMsg}")
                return false
            }
            // boolTrue#997275b5
            let success = (ctor == 0x997275b5)
            Hilog.info(0, "CjTelegram", "[SettingsService] resetAuthorization hash=${hash}: ${success}")
            return success
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] resetAuthorization exception: ${e}")
            return false
        }
    }

    // ========== Profile update (account.updateProfile) ==========

    /**
     * Updates the user's display name and/or bio.
     * TL: account.updateProfile#78515775 flags:# first_name:flags.0?string last_name:flags.1?string about:flags.2?string = User
     * Returns true if the server returned a User object (not RPC_ERROR).
     */
    public func updateProfile(firstName: ?String, lastName: ?String, about: ?String): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateProfile()
            req.firstName = firstName
            req.lastName = lastName
            req.about = about
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateProfile error: ${errCode} ${errMsg}")
                return false
            }
            // User object — various constructors; any non-error response is success
            Hilog.info(0, "CjTelegram", "[SettingsService] updateProfile success")
            // Update local storage
            let storage = getAuthStorage()
            match (storage.getUserData()) {
                case Some(userData) =>
                    match (firstName) {
                        case Some(fn) => userData.firstName = fn
                        case None => ()
                    }
                    match (lastName) {
                        case Some(ln) => userData.lastName = ln
                        case None => ()
                    }
                    storage.saveUserData(userData)
                case None => ()
            }
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateProfile exception: ${e}")
            return false
        }
    }

    // ========== Privacy settings (account.getPrivacy / account.setPrivacy) ==========

    /**
     * Maps privacy key name to TL constructor UInt32.
     * Keys: "statusTimestamp", "chatInvite", "phoneCall", "phoneP2P",
     *       "forwards", "profilePhoto", "phoneNumber", "addedByPhone",
     *       "voiceMessages", "about"
     */
    private static func privacyKeyConstructor(key: String): UInt32 {
        if (key == "statusTimestamp") { return 0x4f96cb18 }
        if (key == "chatInvite") { return 0xbdfb0426 }
        if (key == "phoneCall") { return 0xfabadc5f }
        if (key == "phoneP2P") { return 0xdb9e70d2 }
        if (key == "forwards") { return 0xa4dd4c08 }
        if (key == "profilePhoto") { return 0x5719bacc }
        if (key == "phoneNumber") { return 0x0352dafa }
        if (key == "addedByPhone") { return 0xd1219bdd }
        if (key == "voiceMessages") { return 0xaee69d68 }
        if (key == "about") { return 0x3823cc40 }
        return 0x4f96cb18  // fallback: statusTimestamp
    }

    /**
     * Maps privacy rule constructor to Int32 value (0=Everyone, 1=Contacts, 2=Nobody).
     */
    private static func privacyRuleValue(ruleCtor: UInt32): Int32 {
        if (ruleCtor == 0x184b35ce) { return 0 }  // allowAll
        if (ruleCtor == 0x0d09e07b) { return 1 }  // allowContacts
        if (ruleCtor == 0xd66b66c9) { return 2 }  // disallowAll
        return 0
    }

    /**
     * Maps Int32 privacy value to TL rule constructor.
     * 0=Everyone → inputPrivacyValueAllowAll
     * 1=Contacts → inputPrivacyValueAllowContacts
     * 2=Nobody   → inputPrivacyValueDisallowAll
     */
    private static func privacyValueToRuleConstructor(value: Int32): UInt32 {
        if (value == 0) { return 0x184b35ce }
        if (value == 1) { return 0x0d09e07b }
        if (value == 2) { return 0xd66b66c9 }
        return 0x184b35ce
    }

    /**
     * Fetches privacy setting for a given key.
     * TL: account.getPrivacy#dadbc950 key:InputPrivacyKey = account.PrivacyRules
     * Returns 0=Everyone, 1=Contacts, 2=Nobody.
     * Returns -1 on error.
     */
    public func getPrivacy(key: String): Int32 {
        try {
            let client = getMTProtoClient()
            let req = AccountGetPrivacy()
            req.keyConstructor = SettingsService.privacyKeyConstructor(key)
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return -1 }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] getPrivacy error: ${errCode} ${errMsg}")
                return -1
            }
            // account.privacyRules#50a04e45 rules:Vector<PrivacyRule> chats:Vector<Chat> users:Vector<User>
            if (ctor == 0x50a04e45) {
                let vecCtor = d.readUInt32()
                if (vecCtor == 0x1cb5c415) {
                    let count = d.readInt32()
                    if (count > 0) {
                        let ruleCtor = d.readUInt32()
                        return SettingsService.privacyRuleValue(ruleCtor)
                    }
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] getPrivacy exception: ${e}")
        }
        return 0  // default: Everyone
    }

    /**
     * Sets privacy setting for a given key.
     * TL: account.setPrivacy#c9f81ce8 key:InputPrivacyKey rules:Vector<InputPrivacyRule> = account.PrivacyRules
     * value: 0=Everyone, 1=Contacts, 2=Nobody
     * Returns true on success.
     */
    public func setPrivacy(key: String, value: Int32): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountSetPrivacy()
            req.keyConstructor = SettingsService.privacyKeyConstructor(key)
            req.ruleConstructors.add(SettingsService.privacyValueToRuleConstructor(value))
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] setPrivacy error: ${errCode} ${errMsg}")
                return false
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] setPrivacy ${key}=${value} success")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] setPrivacy exception: ${e}")
            return false
        }
    }

    // ========== Web browser settings (account.getWebBrowserSettings / updateWebBrowserSettings /
    //             toggleWebBrowserSettingsException / deleteWebBrowserSettingsExceptions) ==========
    // FIX TC-0435/TC-0436 R1 (diag-suite_settings_data_storage-TC-0435.md §6.1).
    // iOS ref: TelegramCore/Sources/Settings/AccountWebBrowserSettings.swift

    /**
     * Cache-only read of the account-level web browser settings — never touches the network.
     *
     * FIX TC-0435/TC-0436 R2/R3 (diag-suite_settings_data_storage-TC-0435-round2.md 增量 D-1 +
     * diag-suite_settings_data_storage-TC-0436.md §6.3 FIX-8). Both new consumers run on the UI
     * thread (the Privacy entry row label, and BrowserService.getEffectiveBrowserMode on every
     * link tap), so they must not call getWebBrowserSettings() — that one issues a blocking
     * MTProtoClient.sendRequest and would freeze the UI thread (R-138).
     */
    public func getCachedWebBrowserSettings(): WebBrowserSettingsState {
        return this.loadWebBrowserSettingsCache()
    }

    /**
     * True when the account-level cache has actually been written at least once.
     *
     * FIX-8 边界条件: BrowserService falls back to its own local `open_external_browser`
     * Preferences key when the account-level cache is not yet available (cold start before the
     * first account.getWebBrowserSettings round trip), so callers need to tell "cached
     * openExternalBrowser == false" apart from "no cache at all". loadWebBrowserSettingsCache()
     * cannot express that difference — it returns the same default state in both cases.
     */
    public func hasWebBrowserSettingsCache(): Bool {
        this.ensureWbsPrefs()
        match (this._wbsPrefs) {
            case None => return false
            case Some(prefs) =>
                try {
                    return prefs.has(KEY_WBS_OPEN_EXTERNAL)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SettingsService] hasWebBrowserSettingsCache exception: ${e}")
                    return false
                }
        }
    }

    /**
     * Fetches account-level web browser settings, hash-cached like getTimezonesList.
     * Returns the cache immediately merged in (cache-first is the caller's job via UI —
     * this returns whatever is authoritative after this call: fresh from server, or the
     * existing cache on notModified/error/no-network).
     * TL: account.getWebBrowserSettings#56655768 hash:long = account.WebBrowserSettings
     * forceUpdate=true sends hash=0 (bypass the server-side notModified short-circuit).
     */
    public func getWebBrowserSettings(forceUpdate: Bool): WebBrowserSettingsState {
        let cached = this.loadWebBrowserSettingsCache()
        try {
            let client = getMTProtoClient()
            let req = AccountGetWebBrowserSettings()
            req.hash = if (forceUpdate) { 0 } else { cached.hash }
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return cached }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] getWebBrowserSettings error: ${errCode} ${errMsg}")
                return cached
            }
            // account.webBrowserSettingsNotModified#c31c8f4e — keep the cached value, do not clear
            if (ctor == 0xc31c8f4e) {
                Hilog.info(0, "CjTelegram", "[SettingsService] getWebBrowserSettings: not modified, using cache")
                return cached
            }
            // account.webBrowserSettings#79eb8cb3
            if (ctor == 0x79eb8cb3) {
                let fresh = SettingsService.parseWebBrowserSettingsBody(d)
                this.saveWebBrowserSettingsCache(fresh)
                Hilog.info(0, "CjTelegram", "[SettingsService] getWebBrowserSettings: fetched, hash=${fresh.hash}")
                return fresh
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] getWebBrowserSettings: unexpected ctor 0x${ctor.toString()}")
            return cached
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] getWebBrowserSettings exception: ${e}")
            return cached
        }
    }

    /**
     * Sets the account-level "open external browser" flag.
     * TL: account.updateWebBrowserSettings#9adf82fe flags:# (bit0=open_external_browser) = account.WebBrowserSettings
     * Overwrites the cache entirely from the response body (iOS storeAccountWebBrowserSettings);
     * never optimistically writes the local cache ahead of the response.
     */
    public func updateWebBrowserSettings(openExternalBrowser: Bool): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateWebBrowserSettings()
            req.openExternalBrowser = openExternalBrowser
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateWebBrowserSettings error: ${errCode} ${errMsg}")
                return false
            }
            if (ctor == 0xc31c8f4e) {
                Hilog.info(0, "CjTelegram", "[SettingsService] updateWebBrowserSettings: not modified")
                return true
            }
            if (ctor == 0x79eb8cb3) {
                let fresh = SettingsService.parseWebBrowserSettingsBody(d)
                this.saveWebBrowserSettingsCache(fresh)
                Hilog.info(0, "CjTelegram", "[SettingsService] updateWebBrowserSettings ${openExternalBrowser}: success")
                return true
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] updateWebBrowserSettings: unexpected ctor 0x${ctor.toString()}")
            return false
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateWebBrowserSettings exception: ${e}")
            return false
        }
    }

    /**
     * Adds/removes a single domain exception (or, when openExternalBrowser is None, deletes it
     * from whichever list currently holds it — see iOS withAppliedExceptionUpdate).
     *
     * TL: account.toggleWebBrowserSettingsException#60ed4229 flags:# open_external_browser:flags.0?Bool
     *     delete:flags.1?true url:string
     *
     * iOS ref (TelegramCore/Sources/Settings/AccountWebBrowserSettings.swift:183-209) applies the
     * diff carried in the RPC response's `Updates.allUpdates` (`updateWebBrowserSettings#c39a2ade` /
     * `updateWebBrowserException#140502d1` Update variants — ctor ids confirmed from
     * input/Telegram-iOS submodules/TelegramApi/Sources/Api0.swift:1322-1323 dict entries, field
     * layout from the Cons_updateWebBrowserSettings/Cons_updateWebBrowserException generated structs
     * in Api29.swift). This decodes that Updates envelope (applyWebBrowserUpdatesEnvelope below) and
     * applies the same local diff the source applies, instead of force-refetching: a non-error
     * response with zero matching Update variants is a real "landed but nothing to locally apply"
     * case the source expresses by returning `updated=false` without writing the cache — refetching
     * can never express that case (it always returns *some* cache state), and a refetch that itself
     * hits a network error right after a successful write would silently report true over a cache
     * that's actually stale.
     *
     * Returns true only if at least one of the two Update variants was found and applied (mirrors
     * iOS's `updated` bool). Returns false and leaves the cache untouched on RPC error, a response
     * too short to contain an envelope, or zero matching Update variants in the envelope.
     */
    public func toggleWebBrowserException(openExternalBrowser: ?Bool, delete: Bool, url: String): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountToggleWebBrowserSettingsException()
            req.openExternalBrowser = openExternalBrowser
            req.delete = delete
            req.url = url
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] toggleWebBrowserException error: ${errCode} ${errMsg}")
                return false
            }
            // Non-error response is a boxed Updates envelope carrying the diff — decode it and apply
            // locally (see doc comment above); never force a second network round trip.
            let cached = this.loadWebBrowserSettingsCache()
            let (applied, next) = SettingsService.applyWebBrowserUpdatesEnvelope(d, ctor, cached)
            if (applied) {
                this.saveWebBrowserSettingsCache(next)
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] toggleWebBrowserException url=${url} delete=${delete}: applied=${applied}")
            return applied
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] toggleWebBrowserException exception: ${e}")
            return false
        }
    }

    /**
     * Clears both domain exception lists.
     * TL: account.deleteWebBrowserSettingsExceptions#86a0765d = account.WebBrowserSettings
     */
    public func deleteWebBrowserExceptions(): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountDeleteWebBrowserSettingsExceptions()
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteWebBrowserExceptions error: ${errCode} ${errMsg}")
                return false
            }
            if (ctor == 0xc31c8f4e) {
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteWebBrowserExceptions: not modified")
                return true
            }
            if (ctor == 0x79eb8cb3) {
                let fresh = SettingsService.parseWebBrowserSettingsBody(d)
                this.saveWebBrowserSettingsCache(fresh)
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteWebBrowserExceptions: success")
                return true
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] deleteWebBrowserExceptions: unexpected ctor 0x${ctor.toString()}")
            return false
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] deleteWebBrowserExceptions exception: ${e}")
            return false
        }
    }

    // ---- response parsing helpers ----

    private static func parseWebDomainException(d: TLDeserializer): WebBrowserException {
        let e = WebBrowserException()
        try {
            let ctor = d.readUInt32()
            // webDomainException#933ca597 flags:int domain:string url:string title:string favicon:flags.0?long
            if (ctor == 0x933ca597) {
                let flags = d.readInt32()
                e.domain = d.readString()
                e.url = d.readString()
                e.title = d.readString()
                if ((flags & 1) != 0) {
                    e.favicon = d.readInt64()
                }
            }
        } catch (_e: Exception) {}
        return e
    }

    private static func parseWebDomainExceptionVector(d: TLDeserializer): ArrayList<WebBrowserException> {
        let result = ArrayList<WebBrowserException>()
        let vecCtor = d.readUInt32()
        if (vecCtor != TLConstructors.VECTOR) { return result }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            result.add(SettingsService.parseWebDomainException(d))
            i = i + 1
        }
        return result
    }

    /**
     * account.webBrowserSettings#79eb8cb3 flags:int externalExceptions:Vector<WebDomainException>
     *     inappExceptions:Vector<WebDomainException> hash:long
     * openExternalBrowser is flags bit0 (iOS AccountWebBrowserSettings.init(apiWebBrowserSettings:):
     * `(data.flags & (1 << 0)) != 0`). Ctor already consumed by the caller.
     */
    private static func parseWebBrowserSettingsBody(d: TLDeserializer): WebBrowserSettingsState {
        let s = WebBrowserSettingsState()
        let flags = d.readInt32()
        s.openExternalBrowser = (flags & 1) != 0
        s.externalExceptions = SettingsService.parseWebDomainExceptionVector(d)
        s.inAppExceptions = SettingsService.parseWebDomainExceptionVector(d)
        s.hash = d.readInt64()
        return s
    }

    // ---- toggleWebBrowserSettingsException Updates envelope decoding ----
    // account.toggleWebBrowserSettingsException returns a boxed Updates envelope (one of the four
    // standard variants below) carrying the diff as nested Update entries, not a fresh
    // account.webBrowserSettings body. Envelope ctor ids are the same four already decoded elsewhere
    // in this codebase (core/mtproto/TLResponses.cj parseMigrateChatResult/skipStarGiftUpdates,
    // services/CallsService.cj). Ctor ids for the two nested Update variants are confirmed from
    // input/Telegram-iOS submodules/TelegramApi/Sources/Api0.swift:1322-1323
    // (`dict[-1013306658] = updateWebBrowserSettings`, `dict[335872721] = updateWebBrowserException`)
    // and their Cons_* field layout in Api29.swift.

    /**
     * updates#74ae4240 updates:Vector<Update> users:Vector<User> chats:Vector<Chat> date:int seq:int
     * updatesCombined#725b04c3 updates:Vector<Update> users:Vector<User> chats:Vector<Chat> date:int seq_start:int seq:int
     * updateShort#78d4dec1 update:Update date:int
     * updatesTooLong#e317af7e (no fields)
     *
     * Applies every updateWebBrowserSettings/updateWebBrowserException entry found (in vector order,
     * mirroring iOS's `for update in result.allUpdates`) onto `base` and returns (applied, result).
     * applied=false (result is base, untouched) when the envelope carries neither variant — caller
     * must not persist the cache in that case (source's "updated" bool; see toggleWebBrowserException
     * doc comment).
     *
     * Any *other* Update variant encountered inside the updates vector stops the scan: this package
     * has no visibility into core/mtproto's internal (non-public) skipUpdate*() helpers to safely
     * skip an unknown variant's body — the same "尽力而为" limitation core/mtproto/TLResponses.cj's
     * own skipUpdate() doc comment already accepts for its callers. Web-browser diffs already found
     * before that point are kept.
     */
    private static func applyWebBrowserUpdatesEnvelope(d: TLDeserializer, envelopeCtor: UInt32, base: WebBrowserSettingsState): (Bool, WebBrowserSettingsState) {
        var settings = base
        var applied = false

        if (envelopeCtor == 0xe317af7e) {
            // updatesTooLong — no updates carried
            return (false, settings)
        }

        if (envelopeCtor == 0x78d4dec1) {
            // updateShort — single Update, no vector wrapper
            let updCtor = d.readUInt32()
            let (ok, next) = SettingsService.applyOneWebBrowserUpdate(updCtor, d, settings)
            if (ok) {
                applied = true
                settings = next
            }
            return (applied, settings)
        }

        if (envelopeCtor == 0x74ae4240 || envelopeCtor == 0x725b04c3) {
            let updVecCtor = d.readUInt32()
            if (updVecCtor != TLConstructors.VECTOR) { return (applied, settings) }
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                let updCtor = d.readUInt32()
                if (updCtor == 0xc39a2ade || updCtor == 0x140502d1) {
                    let (ok, next) = SettingsService.applyOneWebBrowserUpdate(updCtor, d, settings)
                    if (ok) {
                        applied = true
                        settings = next
                    }
                } else {
                    break
                }
                i = i + 1
            }
            return (applied, settings)
        }

        return (applied, settings)
    }

    /**
     * Decodes and applies a single already-ctor-read Update entry onto `base` if it's one of the
     * two web-browser variants; returns (false, base) unchanged for anything else.
     */
    private static func applyOneWebBrowserUpdate(ctor: UInt32, d: TLDeserializer, base: WebBrowserSettingsState): (Bool, WebBrowserSettingsState) {
        // updateWebBrowserSettings#c39a2ade flags:# = Update — bit0 is the new openExternalBrowser
        // value (iOS withUpdatedOpenExternalBrowser((flags & (1 << 0)) != 0)).
        if (ctor == 0xc39a2ade) {
            let flags = d.readInt32()
            base.openExternalBrowser = (flags & 1) != 0
            base.hash = 0
            return (true, base)
        }
        // updateWebBrowserException#140502d1 flags:# open_external_browser:flags.0?Bool
        //     exception:WebDomainException — flags bit1 = delete (iOS `flags & (1 << 1)`); exception
        // is the boxed webDomainException#933ca597 already decoded by parseWebDomainException.
        if (ctor == 0x140502d1) {
            let flags = d.readInt32()
            var openExternalBrowser: ?Bool = None
            if ((flags & 1) != 0) {
                let boolCtor = d.readUInt32()
                openExternalBrowser = Some(boolCtor == 0x997275b5)
            }
            let exception = SettingsService.parseWebDomainException(d)
            let delete = (flags & 2) != 0
            let next = SettingsService.applyExceptionDiff(base, openExternalBrowser, delete, exception)
            return (true, next)
        }
        return (false, base)
    }

    /**
     * Mirrors iOS AccountWebBrowserSettings.withAppliedExceptionUpdate (:62-93): removes any
     * existing entry matching by non-empty url or by domain from the target list(s), then (when not
     * deleting) appends `exception`. Resets hash to 0 like the source, forcing the next
     * getWebBrowserSettings(false) to bypass the notModified short-circuit and fetch canonical state.
     */
    private static func applyExceptionDiff(base: WebBrowserSettingsState, openExternalBrowser: ?Bool, delete: Bool, exception: WebBrowserException): WebBrowserSettingsState {
        var externalExceptions = base.externalExceptions
        var inAppExceptions = base.inAppExceptions

        if (delete) {
            match (openExternalBrowser) {
                case Some(true) => externalExceptions = SettingsService.removeMatchingException(externalExceptions, exception)
                case Some(false) => inAppExceptions = SettingsService.removeMatchingException(inAppExceptions, exception)
                case None =>
                    externalExceptions = SettingsService.removeMatchingException(externalExceptions, exception)
                    inAppExceptions = SettingsService.removeMatchingException(inAppExceptions, exception)
            }
        } else {
            match (openExternalBrowser) {
                case Some(true) =>
                    externalExceptions = SettingsService.removeMatchingException(externalExceptions, exception)
                    externalExceptions.add(exception)
                case Some(false) =>
                    inAppExceptions = SettingsService.removeMatchingException(inAppExceptions, exception)
                    inAppExceptions.add(exception)
                case None => ()
            }
        }

        base.externalExceptions = externalExceptions
        base.inAppExceptions = inAppExceptions
        base.hash = 0
        return base
    }

    // Predicate mirrors iOS removeMatching: remove if (exception.url non-empty AND item.url matches)
    // OR item.domain matches.
    private static func removeMatchingException(list: ArrayList<WebBrowserException>, exception: WebBrowserException): ArrayList<WebBrowserException> {
        let result = ArrayList<WebBrowserException>()
        for (item in list) {
            var removed = false
            if (exception.url.size > 0 && item.url == exception.url) {
                removed = true
            } else if (item.domain == exception.domain) {
                removed = true
            }
            if (!removed) {
                result.add(item)
            }
        }
        return result
    }

    // ---- Preferences cache (self-contained store; see WEB_BROWSER_SETTINGS_STORE_NAME) ----

    private func ensureWbsPrefs(): Unit {
        match (this._wbsPrefs) {
            case Some(_) => ()
            case None =>
                match (getGlobalAbilityContext()) {
                    case None =>
                        Hilog.info(0, "CjTelegram", "[SettingsService] No ability context — web browser settings cache in-memory only")
                    case Some(ctx) =>
                        try {
                            let prefs = Preferences.getPreferences(ctx, WEB_BROWSER_SETTINGS_STORE_NAME)
                            this._wbsPrefs = Some(prefs)
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[SettingsService] web browser settings prefs open failed: ${e}")
                        }
                }
        }
    }

    private func loadWebBrowserSettingsCache(): WebBrowserSettingsState {
        let s = WebBrowserSettingsState()
        this.ensureWbsPrefs()
        match (this._wbsPrefs) {
            case None => return s
            case Some(prefs) =>
                try {
                    let openVal = prefs.get(KEY_WBS_OPEN_EXTERNAL, PreferencesValueType.Integer(0))
                    match (openVal) {
                        case PreferencesValueType.Integer(n) => s.openExternalBrowser = (n != 0)
                        case _ => ()
                    }
                    let hashVal = prefs.get(KEY_WBS_HASH, PreferencesValueType.Integer(0))
                    match (hashVal) {
                        case PreferencesValueType.Integer(n) => s.hash = n
                        case _ => ()
                    }
                    s.externalExceptions = SettingsService.decodeExceptionList(SettingsService.readWbsStringArray(prefs, KEY_WBS_EXTERNAL_EXCEPTIONS))
                    s.inAppExceptions = SettingsService.decodeExceptionList(SettingsService.readWbsStringArray(prefs, KEY_WBS_INAPP_EXCEPTIONS))
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SettingsService] loadWebBrowserSettingsCache exception: ${e}")
                }
        }
        return s
    }

    private func saveWebBrowserSettingsCache(s: WebBrowserSettingsState): Unit {
        this.ensureWbsPrefs()
        match (this._wbsPrefs) {
            case None => ()
            case Some(prefs) =>
                try {
                    let openN: Int64 = if (s.openExternalBrowser) { 1 } else { 0 }
                    prefs.put(KEY_WBS_OPEN_EXTERNAL, PreferencesValueType.Integer(openN))
                    prefs.put(KEY_WBS_HASH, PreferencesValueType.Integer(s.hash))
                    prefs.put(KEY_WBS_EXTERNAL_EXCEPTIONS, PreferencesValueType.StringArray(SettingsService.encodeExceptionList(s.externalExceptions)))
                    prefs.put(KEY_WBS_INAPP_EXCEPTIONS, PreferencesValueType.StringArray(SettingsService.encodeExceptionList(s.inAppExceptions)))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SettingsService] saveWebBrowserSettingsCache exception: ${e}")
                }
        }
    }

    /**
     * D-163 fix: explicit invalidate hook for the account-scoped web browser settings Preferences
     * cache (telegram_web_browser_settings). SettingsService is a lazy singleton that outlives
     * account logout, and this store is not (yet) in AuthStorage.cj:clearAll()'s logout enumeration
     * — core/storage/AuthStorage.cj isn't in this feature's allowlist, so it can't be registered
     * there directly. Must be called from the logout path instead; see this feature's
     * emitted_integration_contracts[ic_wbs_cache_invalidate_on_logout] for the structured hand-off
     * (host_site: core/storage/AuthStorage.cj AuthStorage.clearAll()).
     *
     * Clears both the on-disk store and the in-memory Preferences handle, so a read immediately
     * after this call (same process, no restart needed) sees defaults — same shape as the existing
     * telegram_stickers_cache / telegram_themes_cache / telegram_contacts_settings clears already in
     * clearAll().
     */
    public func invalidateWebBrowserSettingsCache(): Unit {
        this.ensureWbsPrefs()
        match (this._wbsPrefs) {
            case Some(prefs) =>
                try {
                    prefs.clear()
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[SettingsService] web browser settings cache invalidated")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SettingsService] invalidateWebBrowserSettingsCache error: ${e}")
                }
            case None => ()
        }
        this._wbsPrefs = None
    }

    private static func readWbsStringArray(prefs: Preferences, key: String): Array<String> {
        try {
            let raw = prefs.get(key, PreferencesValueType.StringArray([]))
            match (raw) {
                case PreferencesValueType.StringArray(arr) => return arr
                case _ => return []
            }
        } catch (e: Exception) {
            return []
        }
    }

    // Serialized entry: domain\u{1E}url\u{1E}title\u{1E}favicon
    private static func encodeExceptionList(list: ArrayList<WebBrowserException>): Array<String> {
        let src = list
        return Array<String>(src.size, { i: Int64 =>
            let e = src[i]
            e.domain + WBS_FIELD_SEP + e.url + WBS_FIELD_SEP + e.title + WBS_FIELD_SEP + e.favicon.toString()
        })
    }

    private static func decodeExceptionList(arr: Array<String>): ArrayList<WebBrowserException> {
        let result = ArrayList<WebBrowserException>()
        for (entry in arr) {
            if (entry.size == 0) { continue }
            let parts = entry.split(WBS_FIELD_SEP)
            if (parts.size < 3) { continue }
            let e = WebBrowserException()
            e.domain = parts[0]
            e.url = parts[1]
            e.title = parts[2]
            if (parts.size > 3) {
                e.favicon = try { Int64.parse(parts[3]) } catch (_: Exception) { 0 }
            }
            result.add(e)
        }
        return result
    }

    // ========== Two-step verification (account.getPassword) ==========

    /**
     * Fetches 2-step verification status.
     * TL: account.getPassword#548a30f5 = account.Password
     */
    public func getTwoStepVerificationStatus(): TwoStepVerificationStatus {
        let result = TwoStepVerificationStatus()
        try {
            let client = getMTProtoClient()
            let req = AccountGetPassword()
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return result }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] getPassword error: ${errCode} ${errMsg}")
                return result
            }
            // account.password#957b50fb flags:# ...
            if (ctor == 0x957b50fb) {
                let flags = d.readInt32()
                result.hasPassword = (flags & 4) != 0
                result.hasRecoveryEmailAddress = (flags & 32) != 0
                result.hasSecureValues = (flags & 64) != 0
                if ((flags & 16) != 0) {
                    result.pendingResetDate = d.readInt32()
                }
                if ((flags & 8) != 0) {
                    result.emailUnconfirmedPattern = d.readString()
                }
                Hilog.info(0, "CjTelegram", "[SettingsService] getPassword: hasPassword=${result.hasPassword}")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] getPassword exception: ${e}")
        }
        return result
    }

    // ========== Account deletion (account.deleteAccount) ==========

    /**
     * Requests account deletion.
     * TL: account.deleteAccount#a2c0cf74 flags:# reason:string password:flags.0?InputCheckPasswordSRP = Bool
     * reason: reason for deletion
     * Returns true on success (boolTrue).
     */
    public func deleteAccount(reason: String): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountDeleteAccount()
            req.reason = reason
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteAccount error: ${errCode} ${errMsg}")
                return false
            }
            return (ctor == 0x997275b5)  // boolTrue
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] deleteAccount exception: ${e}")
            return false
        }
    }

    // ========== Logout (auth.logOut) ==========

    /**
     * Logs out the current account.
     * TL: auth.logOut#3e72ba19 = auth.LoggedOut
     * iOS ref: Api42.swift:2482 appendInt32(1047706137) -> 0x3e72ba19
     * Returns true if the server returned a loggedOut response (flags + optional futureAuthToken).
     * Any non-error response is treated as success.
     */
    public func logOut(): Bool {
        try {
            let client = getMTProtoClient()
            let req = AuthLogOut()
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] logOut error: ${errCode} ${errMsg}")
                return false
            }
            // auth.loggedOut#c3a2835f flags:# future_auth_token:flags.0?bytes = auth.LoggedOut
            Hilog.info(0, "CjTelegram", "[SettingsService] logOut success ctor=0x${ctor.toString()}")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] logOut exception: ${e}")
            return false
        }
    }

    // ========== Account TTL (account.getAccountTTL / account.setAccountTTL) ==========

    /**
     * Fetches the account self-destruction TTL (in days).
     * TL: account.getAccountTTL#8caa9a96 = AccountDaysTTL
     */
    public func getAccountTTL(): Int32 {
        try {
            let client = getMTProtoClient()
            let req = AccountGetAccountTTL()
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return 180 }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] getAccountTTL error: ${errCode} ${errMsg}")
                return 180
            }
            // accountDaysTTL#b8d0afdf days:int
            if (ctor == 0xb8d0afdf) {
                return d.readInt32()
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] getAccountTTL exception: ${e}")
        }
        return 180
    }

    /**
     * Sets the account self-destruction TTL.
     * TL: account.setAccountTTL#2442485e value:AccountDaysTTL = Bool
     * days: 30 | 90 | 180 | 365
     * Returns true on success.
     */
    public func setAccountTTL(days: Int32): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountSetAccountTTL()
            req.days = days
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] setAccountTTL error: ${errCode} ${errMsg}")
                return false
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] setAccountTTL days=${days} success")
            return (ctor == 0x997275b5)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] setAccountTTL exception: ${e}")
            return false
        }
    }

    // ========== Notification settings (account.getNotifySettings / account.updateNotifySettings) ==========

    /**
     * Fetches global notification settings for a peer type.
     * peerType: "users" | "chats" | "broadcasts"
     * Returns mute status and show-preview flag.
     * Delegates to TelegramCoreSettingsService which already implements this.
     */
    public func getGlobalNotifySettings(peerType: String): GlobalNotifySettingsData {
        return getTelegramCoreSettingsService().getGlobalNotifySettings(peerType)
    }

    /**
     * Updates global notification settings.
     * Delegates to TelegramCoreSettingsService which already implements this.
     */
    public func updateGlobalNotifySettings(peerType: String, muteUntil: Int32, showPreviews: Bool, silent: Bool): Bool {
        return getTelegramCoreSettingsService().updateGlobalNotifySettings(peerType, muteUntil, showPreviews, silent)
    }

    /**
     * F-A1c 透传重载（diag-suite_settings_notifications-TC-0446.md，ic_nsnd_settings_service_sound_param）：
     * 分类子屏（pages/NotificationsPeerCategoryPage.cj）提交/刷新铃声选择后，携带 soundId
     * 一并推送账号级 notify settings，对位源侧 completion 回写 `settings.<category>.sound` 后的
     * `apiInputPeerNotifySettings` 上传（ManagedGlobalNotificationSettings.swift:320-336）。
     * 下游两跳仍缺：`services/TelegramCoreSettingsService.cj`（当前无 owner，见诊断报告 F-A1c）
     * 与 `core/mtproto/TLMethods.cj` 的 `AccountUpdateNotifySettings` 序列化（owner
     * `net_telegram_api`，另按 `ic_nsnd_tl_sound_flag` 上报）都不在本 feature allowlist 内、
     * 尚未接住 soundId 参数。本重载先把本 feature 允许范围内能做的一段透传接好——调用点已在
     * pages/NotificationsPeerCategoryPage.cj 接入；下游两个契约落地后无需再改本文件，soundId
     * 会自动开始真正到达服务端。
     */
    public func updateGlobalNotifySettings(peerType: String, muteUntil: Int32, showPreviews: Bool, silent: Bool, soundId: Int64): Bool {
        if (soundId != 0) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateGlobalNotifySettings soundId=${soundId} captured; not yet serialized server-side (TLMethods.cj flags.3 pending ic_nsnd_tl_sound_flag)")
        }
        return getTelegramCoreSettingsService().updateGlobalNotifySettings(peerType, muteUntil, showPreviews, silent)
    }

    // ========== Username (account.checkUsername / account.updateUsername) ==========

    /**
     * Checks whether a username is available.
     * TL: account.checkUsername#2714d86c username:string = Bool
     * Returns: true = available, false = taken or invalid, null-like = network error
     */
    public func checkUsername(username: String): Int32 {
        // Returns: 1=available, 0=taken, -1=error
        try {
            let client = getMTProtoClient()
            let req = AccountCheckUsername()
            req.username = username
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return -1 }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] checkUsername error: ${errCode} ${errMsg}")
                return -1
            }
            if (ctor == 0x997275b5) { return 1 }  // boolTrue = available
            if (ctor == 0xbc799737) { return 0 }  // boolFalse = taken
            return -1
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] checkUsername exception: ${e}")
            return -1
        }
    }

    /**
     * Updates the account username.
     * TL: account.updateUsername#3e0bdd7c username:string = User
     * Returns true on success (server returned User object).
     */
    public func updateUsername(username: String): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateUsername()
            req.username = username
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateUsername error: ${errCode} ${errMsg}")
                return false
            }
            // User object = success; update local storage
            let storage = getAuthStorage()
            match (storage.getUserData()) {
                case Some(userData) =>
                    userData.username = username
                    storage.saveUserData(userData)
                case None => ()
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] updateUsername=${username} success")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateUsername exception: ${e}")
            return false
        }
    }

    // ==================== P2-153 Gap 1: Photo / Avatar Management ====================

    /**
     * Uploads bytes as a profile photo and sets it as current.
     *
     * iOS ref: uploadProfilePhoto (Account.swift → photos.uploadProfilePhoto + photos.updateProfilePhoto)
     * Flow:
     *   1. Upload file bytes via FileUploadService → InputFile (InputFileUploaded or InputFileBig)
     *   2. Call photos.uploadProfilePhoto#0388a3b5 → photos.Photo (extract id/access_hash)
     *   3. Call photos.updateProfilePhoto#09e82039 with that InputPhoto
     *
     * TL ctor IDs (tl_codegen verified):
     *   photos.uploadProfilePhoto = 0x0388a3b5
     *   photos.updateProfilePhoto = 0x09e82039
     *   photos.photo#fb197a65     (response)
     *   inputPhoto#3bb3b94a (used by updateProfilePhoto)
     */
    public func uploadAndSetProfilePhoto(imageBytes: Array<Byte>, fileName: String): ProfilePhotoResult {
        let result = ProfilePhotoResult()
        Hilog.info(0, "CjTelegram", "[SettingsService] uploadAndSetProfilePhoto: ${imageBytes.size} bytes")
        let uploadSvc = getFileUploadService()
        let inputFileOpt = uploadSvc.uploadFile(imageBytes, fileName)
        match (inputFileOpt) {
            case None =>
                Hilog.info(0, "CjTelegram", "[SettingsService] uploadAndSetProfilePhoto: file upload failed")
                return result
            case Some(inputFile) =>
                let client = getMTProtoClient()
                // Step 2: photos.uploadProfilePhoto (flags bit0 = has file)
                let uploadReq = PhotosUploadProfilePhoto()
                uploadReq.file = Some(inputFile)
                let uploadData = client.sendRequest(uploadReq.toBytes())
                if (uploadData.size < 4) {
                    Hilog.info(0, "CjTelegram", "[SettingsService] uploadProfilePhoto: empty response")
                    return result
                }
                let d1 = TLDeserializer(uploadData)
                let ctor1 = d1.readUInt32()
                if (ctor1 == TLConstructors.RPC_ERROR || ctor1 == 0x2144ca19) {
                    let errCode = d1.readInt32()
                    let errMsg = d1.readString()
                    Hilog.info(0, "CjTelegram", "[SettingsService] uploadProfilePhoto RPC error: ${errCode} ${errMsg}")
                    return result
                }
                // photos.photo#20212ca8 photo:Photo users:Vector<User>  (outer wrapper)
                // photo#fb197a65 flags:# id:long access_hash:long file_reference:bytes ... (inner Photo)
                var photoId: Int64 = 0
                var photoAccessHash: Int64 = 0
                var photoFileRef: Array<Byte> = Array<Byte>(0, repeat: 0)
                if (ctor1 == 0x20212ca8) {
                    // inner photo#fb197a65 follows
                    let photoCtor = d1.readUInt32()
                    if (photoCtor == 0xfb197a65) {
                        let flags = d1.readInt32()
                        let _ = flags
                        photoId = d1.readInt64()
                        photoAccessHash = d1.readInt64()
                        photoFileRef = d1.readBytes()
                    }
                }
                if (photoId == 0) {
                    // Couldn't parse photo — try updateProfilePhoto with inputPhotoEmpty
                    Hilog.info(0, "CjTelegram", "[SettingsService] uploadProfilePhoto: could not parse photo.id, photo may still be set")
                    result.success = true
                    return result
                }
                // Step 3: photos.updateProfilePhoto
                let updateReq = PhotosUpdateProfilePhoto()
                updateReq.photoId = photoId
                updateReq.photoAccessHash = photoAccessHash
                updateReq.photoFileReference = photoFileRef
                let updateData = client.sendRequest(updateReq.toBytes())
                if (updateData.size < 4) {
                    Hilog.info(0, "CjTelegram", "[SettingsService] updateProfilePhoto: empty response")
                    result.success = true  // upload succeeded, set may not be confirmed
                    return result
                }
                let d2 = TLDeserializer(updateData)
                let ctor2 = d2.readUInt32()
                if (ctor2 == TLConstructors.RPC_ERROR || ctor2 == 0x2144ca19) {
                    let errCode2 = d2.readInt32()
                    let errMsg2 = d2.readString()
                    Hilog.info(0, "CjTelegram", "[SettingsService] updateProfilePhoto RPC error: ${errCode2} ${errMsg2}")
                    return result
                }
                result.success = true
                result.photoId = photoId
                result.accessHash = photoAccessHash
                result.fileReference = photoFileRef
                Hilog.info(0, "CjTelegram", "[SettingsService] uploadAndSetProfilePhoto success photoId=${photoId}")
                return result
        }
    }

    /**
     * Source-equivalent custom emoji avatar upload.  Telegram stores the JPEG
     * cover as the ordinary profile photo and the animated custom emoji as
     * video_emoji_markup on that same Photo.
     */
    public func uploadAndSetProfileEmojiAvatar(
        imageBytes: Array<Byte>,
        fileName: String,
        emojiDocumentId: Int64,
        backgroundColors: ArrayList<Int32>
    ): ProfilePhotoResult {
        let result = ProfilePhotoResult()
        if (imageBytes.isEmpty() || emojiDocumentId == 0 || backgroundColors.isEmpty()) {
            return result
        }
        match (getFileUploadService().uploadFile(imageBytes, fileName)) {
            case None => return result
            case Some(inputFile) =>
                let markup = VideoSizeEmojiMarkup()
                markup.emojiId = emojiDocumentId
                markup.backgroundColors = backgroundColors
                let request = PhotosUploadProfilePhoto()
                request.file = Some(inputFile)
                request.videoEmojiMarkup = Some(markup)
                let response = getMTProtoClient().sendRequest(request.toBytes())
                if (response.size < 4) { return result }
                let d = TLDeserializer(response)
                let outerCtor = d.readUInt32()
                if (outerCtor == TLConstructors.RPC_ERROR || outerCtor == 0x2144ca19) {
                    let code = d.readInt32()
                    let message = d.readString()
                    Hilog.info(0, "CjTelegram", "[SettingsService] emoji avatar RPC error: ${code} ${message}")
                    return result
                }
                if (outerCtor == 0x20212ca8) {
                    let photoCtor = d.readUInt32()
                    if (photoCtor == 0xfb197a65) {
                        let _ = d.readInt32()
                        result.photoId = d.readInt64()
                        result.accessHash = d.readInt64()
                        result.fileReference = d.readBytes()
                    }
                }
                result.success = true
                Hilog.info(0, "CjTelegram", "[SettingsService] emoji avatar uploaded doc=${emojiDocumentId} photo=${result.photoId}")
                return result
        }
    }

    // ==================== P2-144: Video / Animated Profile Photo ====================

    /**
     * Uploads a video file as an animated profile avatar and sets it as current.
     *
     * iOS ref: Api42.swift:12518 photos.uploadProfilePhoto — video (flags.1) + videoStartTs (flags.2)
     * Flow:
     *   1. Upload video bytes via FileUploadService → InputFile
     *   2. Call photos.uploadProfilePhoto#0388a3b5 with video (bit1) + video_start_ts (bit2)
     *   3. Call photos.updateProfilePhoto#09e82039 with the returned InputPhoto
     *
     * videoBytes:    raw MP4/video bytes
     * videoFileName: file name sent to Telegram (e.g. "video.mp4")
     * videoStartTs:  playback start timestamp in seconds (0.0 = from beginning)
     *
     * TL wire layout (iOS-verified, 0-indexed):
     *   flags (Int32): bit1=1 (video present), bit2=1 (videoStartTs present)
     *   video (InputFile): serialized InputFile from FileUploadService
     *   videoStartTs (double): IEEE 754 little-endian 8-byte double
     */
    public func uploadAndSetProfileVideoPhoto(
        videoBytes: Array<Byte>,
        videoFileName: String,
        videoStartTs: Float64
    ): ProfilePhotoResult {
        let result = ProfilePhotoResult()
        Hilog.info(0, "CjTelegram", "[SettingsService] uploadAndSetProfileVideoPhoto: ${videoBytes.size} bytes ts=${videoStartTs}")
        let uploadSvc = getFileUploadService()
        let inputFileOpt = uploadSvc.uploadFile(videoBytes, videoFileName)
        match (inputFileOpt) {
            case None =>
                Hilog.info(0, "CjTelegram", "[SettingsService] uploadAndSetProfileVideoPhoto: video upload failed")
                return result
            case Some(inputVideo) =>
                let client = getMTProtoClient()
                let uploadReq = PhotosUploadProfilePhoto()
                uploadReq.video = Some(inputVideo)
                uploadReq.videoStartTs = Some(videoStartTs)
                let uploadData = client.sendRequest(uploadReq.toBytes())
                if (uploadData.size < 4) {
                    Hilog.info(0, "CjTelegram", "[SettingsService] uploadAndSetProfileVideoPhoto: empty response")
                    return result
                }
                let d1 = TLDeserializer(uploadData)
                let ctor1 = d1.readUInt32()
                if (ctor1 == TLConstructors.RPC_ERROR || ctor1 == 0x2144ca19) {
                    let errCode = d1.readInt32()
                    let errMsg = d1.readString()
                    Hilog.info(0, "CjTelegram", "[SettingsService] uploadAndSetProfileVideoPhoto RPC error: ${errCode} ${errMsg}")
                    return result
                }
                var photoId: Int64 = 0
                var photoAccessHash: Int64 = 0
                var photoFileRef: Array<Byte> = Array<Byte>(0, repeat: 0)
                if (ctor1 == 0x20212ca8) {
                    let photoCtor = d1.readUInt32()
                    if (photoCtor == 0xfb197a65) {
                        let flagsInner = d1.readInt32()
                        let _ = flagsInner
                        photoId = d1.readInt64()
                        photoAccessHash = d1.readInt64()
                        photoFileRef = d1.readBytes()
                    }
                }
                if (photoId == 0) {
                    Hilog.info(0, "CjTelegram", "[SettingsService] uploadAndSetProfileVideoPhoto: could not parse photo.id")
                    result.success = true
                    return result
                }
                let updateReq = PhotosUpdateProfilePhoto()
                updateReq.photoId = photoId
                updateReq.photoAccessHash = photoAccessHash
                updateReq.photoFileReference = photoFileRef
                let updateData = client.sendRequest(updateReq.toBytes())
                if (updateData.size < 4) {
                    Hilog.info(0, "CjTelegram", "[SettingsService] uploadAndSetProfileVideoPhoto: updateProfilePhoto empty response")
                    result.success = true
                    return result
                }
                let d2 = TLDeserializer(updateData)
                let ctor2 = d2.readUInt32()
                if (ctor2 == TLConstructors.RPC_ERROR || ctor2 == 0x2144ca19) {
                    let errCode2 = d2.readInt32()
                    let errMsg2 = d2.readString()
                    Hilog.info(0, "CjTelegram", "[SettingsService] uploadAndSetProfileVideoPhoto updateProfilePhoto error: ${errCode2} ${errMsg2}")
                    return result
                }
                result.success = true
                result.photoId = photoId
                result.accessHash = photoAccessHash
                result.fileReference = photoFileRef
                Hilog.info(0, "CjTelegram", "[SettingsService] uploadAndSetProfileVideoPhoto success photoId=${photoId}")
                return result
        }
    }

    /**
     * Deletes profile photos by their (id, access_hash, file_reference) tuples.
     *
     * iOS ref: deletePhoto in Account.swift / photos.deletePhotos#87cf7f2f
     * TL ctor (tl_codegen verified): photos.deletePhotos = 0x87cf7f2f
     * Returns array of deleted photo IDs (Long).
     */
    public func deleteProfilePhotos(
        photoIds: ArrayList<Int64>,
        accessHashes: ArrayList<Int64>,
        fileReferences: ArrayList<Array<Byte>>
    ): ArrayList<Int64> {
        let deletedIds = ArrayList<Int64>()
        if (photoIds.size == 0) { return deletedIds }
        try {
            let client = getMTProtoClient()
            let req = PhotosDeletePhotos()
            req.photoIds = photoIds
            req.accessHashes = accessHashes
            req.fileReferences = fileReferences
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return deletedIds }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteProfilePhotos RPC error: ${errCode} ${errMsg}")
                return deletedIds
            }
            // Response: Vector<long> — deleted photo IDs
            if (ctor == TLConstructors.VECTOR) {
                let count = d.readInt32()
                var i: Int32 = 0
                while (i < count) {
                    deletedIds.add(d.readInt64())
                    i += 1
                }
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] deleteProfilePhotos: deleted ${deletedIds.size}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] deleteProfilePhotos exception: ${e}")
        }
        return deletedIds
    }

    // ==================== P2-141b: Delete Own Profile Photo (real photoId) ====================

    /**
     * Fetches the current user's own profile photo list via photos.getUserPhotos,
     * then deletes the first (i.e. current) photo with its real id/access_hash/file_reference.
     *
     * iOS ref: deletePhoto in Account.swift — passes a real InputPhoto to photos.deletePhotos.
     * The previous implementation (EditProfilePage.cj) called deleteProfilePhotos with photoId=0,
     * which is not a valid InputPhoto — the server silently ignores it.
     *
     * TL wire layout:
     *   Request:  photos.getUserPhotos#91cd32a8
     *               userId:InputUser = inputUserSelf#f7c1b13f (no fields)
     *               offset:int = 0
     *               max_id:long = 0
     *               limit:int = 1
     *   Response: photos.photos#8dca6aa5   photos:Vector<Photo> users:Vector<User>
     *          OR photos.photosSlice#15051f54 count:int photos:Vector<Photo> users:Vector<User>
     *   Each Photo: photo#fb197a65 flags:# id:long access_hash:long file_reference:bytes ...
     *
     *   Delete:   photos.deletePhotos#87cf7f2f id:Vector<InputPhoto>
     *               where InputPhoto = inputPhoto#3bb3b94a id:long access_hash:long file_reference:bytes
     *
     * iOS ctor python verification:
     *   getUserPhotos:  hex(-1848823128 & 0xffffffff) = 0x91cd32a8  (Api42.swift:12455)
     *   inputUserSelf:  hex(-138301121  & 0xffffffff) = 0xf7c1b13f  (Api14.swift:792)
     *   photos.photos:  hex(-1916114267 & 0xffffffff) = 0x8dca6aa5  (Api0.swift:1620 key)
     *   photos.photosSlice: 352657236 = 0x15051f54                  (Api39.swift:1994)
     *   photo#fb197a65: already used in uploadAndSetProfilePhoto
     *   deletePhotos:   0x87cf7f2f                                   (TLMethods.cj:2041)
     *   inputPhoto:     0x3bb3b94a                                   (TLMethods.cj:2048)
     *
     * Returns true if at least one photo was deleted, false on error or no photos found.
     */
    public func deleteOwnProfilePhoto(): Bool {
        try {
            let client = getMTProtoClient()
            // Build photos.getUserPhotos#91cd32a8 request manually
            // (no PhotosGetUserPhotos class in TLMethods; serialize inline)
            let reqSer = TLSerializer()
            // ctor: photos.getUserPhotos#91cd32a8
            reqSer.writeUInt32(0x91cd32a8)
            // userId: inputUserSelf#f7c1b13f (no fields beyond ctor)
            reqSer.writeUInt32(0xf7c1b13f)
            // offset: int = 0
            reqSer.writeInt32(0)
            // max_id: long = 0
            reqSer.writeInt64(0)
            // limit: int = 1  (only need current photo)
            reqSer.writeInt32(1)
            let reqData = reqSer.getBytes()
            let data = client.sendRequest(reqData)
            if (data.size < 4) {
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteOwnProfilePhoto: getUserPhotos empty response")
                return false
            }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteOwnProfilePhoto: getUserPhotos RPC error: ${errCode} ${errMsg}")
                return false
            }
            // photos.photosSlice#15051f54 count:int photos:Vector<Photo> users:Vector<User>
            if (ctor == 0x15051f54) {
                let _ = d.readInt32()  // total count — skip
            } else if (ctor != 0x8dca6aa5) {
                // Neither photos.photos nor photos.photosSlice
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteOwnProfilePhoto: unexpected getUserPhotos ctor 0x${ctor.toString()}")
                return false
            }
            // Both variants continue here: photos:Vector<Photo>
            let vecCtor = d.readUInt32()
            if (vecCtor != TLConstructors.VECTOR) {
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteOwnProfilePhoto: expected Vector, got 0x${vecCtor.toString()}")
                return false
            }
            let photoCount = d.readInt32()
            if (photoCount == 0) {
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteOwnProfilePhoto: no profile photos found")
                return false
            }
            // Parse first photo#fb197a65 flags:# id:long access_hash:long file_reference:bytes ...
            let photoCtor = d.readUInt32()
            if (photoCtor != 0xfb197a65) {
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteOwnProfilePhoto: unexpected photo ctor 0x${photoCtor.toString()}")
                return false
            }
            let _ = d.readInt32()  // flags — skip
            let photoId = d.readInt64()
            let accessHash = d.readInt64()
            let fileRef = d.readBytes()
            if (photoId == 0) {
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteOwnProfilePhoto: parsed photoId=0 (unexpected)")
                return false
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] deleteOwnProfilePhoto: fetched photoId=${photoId}, calling deleteProfilePhotos")
            let photoIds = ArrayList<Int64>()
            let accessHashes = ArrayList<Int64>()
            let fileRefs = ArrayList<Array<Byte>>()
            photoIds.add(photoId)
            accessHashes.add(accessHash)
            fileRefs.add(fileRef)
            let deleted = this.deleteProfilePhotos(photoIds, accessHashes, fileRefs)
            let ok = deleted.size > 0
            Hilog.info(0, "CjTelegram", "[SettingsService] deleteOwnProfilePhoto: deleted=${ok} photoId=${photoId}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] deleteOwnProfilePhoto exception: ${e}")
            return false
        }
    }

    // ==================== P2-153 Gap 2: Birthday ====================

    // rpc_error message of the last failed updateBirthday ("" on success / transport failure).
    // iOS Birthdays.swift:92 maps a FLOOD_WAIT prefix to UpdateBirthdayError.flood.
    public var lastBirthdayError: String = ""

    /**
     * Sets or clears the user's birthday.
     *
     * iOS ref: updateBirthday in Account.swift (account.updateBirthday#cc6e0c11)
     * TL ctor (tl_codegen verified): 0xcc6e0c11
     * birthday#6c8e1e06 (tl_codegen verified): 0x6c8e1e06
     * Passing None clears the birthday.
     * Local mirror persisted to Preferences as JSON "day,month,year".
     */
    public func updateBirthday(birthday: Option<BirthdayData>): Bool {
        this.lastBirthdayError = ""
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateBirthday()
            match (birthday) {
                case Some(bd) =>
                    req.hasBirthday = true
                    req.day = bd.day
                    req.month = bd.month
                    req.year = bd.year
                case None =>
                    req.hasBirthday = false
            }
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateBirthday RPC error: ${errCode} ${errMsg}")
                this.lastBirthdayError = errMsg
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            if (ok) {
                let storage = getAuthStorage()
                match (birthday) {
                    case Some(bd) =>
                        let json = "${bd.day},${bd.month},${bd.year}"
                        storage.saveProfileBirthday(json)
                    case None =>
                        storage.saveProfileBirthday("")
                }
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] updateBirthday: ${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateBirthday exception: ${e}")
            return false
        }
    }

    /**
     * Returns the locally cached birthday (None if not set).
     */
    public func getCachedBirthday(): Option<BirthdayData> {
        let storage = getAuthStorage()
        let json = storage.getProfileBirthday()
        if (json.size == 0) { return None }
        let parts = json.split(",")
        if (parts.size < 3) { return None }
        var day: Int32 = 0
        var month: Int32 = 0
        var year: Int32 = 0
        for (ch in parts[0]) {
            let code = UInt32(ch)
            if (code >= 48 && code <= 57) { day = day * 10 + Int32(code - 48) }
        }
        for (ch in parts[1]) {
            let code = UInt32(ch)
            if (code >= 48 && code <= 57) { month = month * 10 + Int32(code - 48) }
        }
        for (ch in parts[2]) {
            let code = UInt32(ch)
            if (code >= 48 && code <= 57) { year = year * 10 + Int32(code - 48) }
        }
        if (day == 0 || month == 0) { return None }
        let bd = BirthdayData()
        bd.day = day
        bd.month = month
        bd.year = year
        return Some(bd)
    }

    // ==================== P2-153 Gap 3: nameColor + emojiStatus ====================

    /**
     * Updates the user's name color and optional background emoji for chat/message headers.
     *
     * iOS ref: updateNameColor (AccountData.swift → account.updateColor#684d214e)
     * TL ctor (tl_codegen verified): 0x684d214e
     * forProfile=false → message name color, forProfile=true → profile accent color
     * color: -1 = reset to default (flag bit2 not set)
     * backgroundEmojiId: 0 = no emoji (flag bit0 not set)
     * Local mirror persisted to Preferences.
     */
    public func updateNameColor(forProfile: Bool, color: Int32, backgroundEmojiId: Int64): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateColor()
            req.forProfile = forProfile
            req.color = color
            req.backgroundEmojiId = backgroundEmojiId
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateNameColor RPC error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            if (ok) {
                getAuthStorage().saveProfileNameColor(color, backgroundEmojiId)
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] updateNameColor forProfile=${forProfile} color=${color} ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateNameColor exception: ${e}")
            return false
        }
    }

    /** Applies an owned unique gift's collectible style to the user's name color. */
    public func updateNameCollectibleColor(collectibleId: Int64): Bool {
        if (collectibleId == 0) { return false }
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateColor()
            req.forProfile = false
            req.collectibleId = collectibleId
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateNameCollectibleColor RPC error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            Hilog.info(0, "CjTelegram", "[SettingsService] updateNameCollectibleColor id=${collectibleId} ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateNameCollectibleColor exception: ${e}")
            return false
        }
    }

    /**
     * Updates the user's emoji status.
     *
     * iOS ref: updateEmojiStatus (AccountData.swift → account.updateEmojiStatus#fbd3de6b)
     * TL ctor (tl_codegen verified): 0xfbd3de6b
     * emojiStatus#e7ff068a (tl_codegen verified): 0xe7ff068a
     * emojiStatusEmpty#2de11aae (tl_codegen verified): 0x2de11aae
     * documentId=0 → clears the emoji status (emojiStatusEmpty)
     * until=0 → permanent (no expiry flag)
     */
    public func updateEmojiStatus(documentId: Int64, until: Int32): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateEmojiStatus()
            req.documentId = documentId
            req.until = until
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateEmojiStatus RPC error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            if (ok) {
                getAuthStorage().saveProfileEmojiStatus(documentId, until)
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] updateEmojiStatus docId=${documentId} until=${until} ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateEmojiStatus exception: ${e}")
            return false
        }
    }

    // ==================== P2-153 Gap 4: Personal Channel ====================

    /**
     * Sets the user's personal channel (shown on profile page).
     *
     * iOS ref: updatePersonalChannel (AccountData.swift → account.updatePersonalChannel#d94305e0)
     * TL ctor (tl_codegen verified): 0xd94305e0
     * channelId=0, clearChannel=true → removes personal channel link
     * Local mirror persisted to Preferences.
     */
    public func updatePersonalChannel(channelId: Int64, accessHash: Int64): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdatePersonalChannel()
            if (channelId == 0) {
                req.clearChannel = true
            } else {
                req.channelId = channelId
                req.channelAccessHash = accessHash
                req.clearChannel = false
            }
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updatePersonalChannel RPC error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            if (ok) {
                getAuthStorage().saveProfilePersonalChannelId(channelId)
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] updatePersonalChannel channelId=${channelId} ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updatePersonalChannel exception: ${e}")
            return false
        }
    }

    /**
     * S7-48: channels the user may set as the personal channel — iOS
     * adminedPublicChannels(scope: .forPersonalProfile) → channels.getAdminedPublicChannels
     * (flags.2 for_personal; AddressNames.swift:560-572) → messages.chats / messages.chatsSlice.
     */
    public func getPersonalChannelCandidates(): ArrayList<ChatResponse> {
        let out = ArrayList<ChatResponse>()
        try {
            let req = ChannelsGetAdminedPublicChannelsRequest()
            req.flags = 1 << 2
            let data = getMTProtoClient().sendRequest(req.toBytes())
            if (data.size < 8) { return out }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == 0x9cd81144) {
                let _ = d.readInt32()   // messages.chatsSlice count
            } else if (ctor != 0x64ff9fd5) {
                Hilog.info(0, "CjTelegram", "[SettingsService] getAdminedPublicChannels unexpected ctor ${ctor}")
                return out
            }
            let vec = d.readUInt32()
            if (vec != 0x1cb5c415) { return out }
            let n = d.readInt32()
            var i: Int32 = 0
            while (i < n) {
                let chat = ChatResponse.deserializeBoxed(d)
                if (chat.isChannel && chat.id != 0) {
                    out.add(chat)
                    getRealChatListService().cacheChatResponse(chat)
                }
                i += 1
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] getPersonalChannelCandidates error: ${e}")
        }
        return out
    }

    /** S7-48: title / username of the personal channel, persisted beside its id. */
    public func savePersonalChannelInfo(title: String, username: String, isBroadcast: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_personal_channel")
                    let slot = getAuthStorage().getActiveSlot()
                    prefs.put("title_${slot}", PreferencesValueType.StringData(title))
                    prefs.put("username_${slot}", PreferencesValueType.StringData(username))
                    prefs.put("broadcast_${slot}", PreferencesValueType.Integer(if (isBroadcast) { 1 } else { 0 }))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    public func getPersonalChannelTitle(): String {
        return this.personalChannelPref("title")
    }

    public func getPersonalChannelUsername(): String {
        return this.personalChannelPref("username")
    }

    private func personalChannelPref(key: String): String {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_personal_channel")
                    let slot = getAuthStorage().getActiveSlot()
                    match (prefs.get("${key}_${slot}", PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(v) => return v
                        case _ => return ""
                    }
                } catch (_e: Exception) { return "" }
            case None => return ""
        }
    }

    public func getPersonalChannelId(): Int64 {
        return getAuthStorage().getProfilePersonalChannelId()
    }

    // ==================== P2-153 Gap 5: Ad Toggle ====================

    /**
     * Toggles sponsored messages (ad) visibility for the current user.
     *
     * iOS ref: toggleAdMessages (AccountData.swift → account.toggleSponsoredMessages#b9d9a38d)
     * TL ctor (tl_codegen verified): 0xb9d9a38d
     * enabled=true → show sponsored messages; enabled=false → hide (requires Telegram Premium)
     */
    public func toggleSponsoredMessages(enabled: Bool): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountToggleSponsoredMessages()
            req.enabled = enabled
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] toggleSponsoredMessages RPC error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            Hilog.info(0, "CjTelegram", "[SettingsService] toggleSponsoredMessages enabled=${enabled} ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] toggleSponsoredMessages exception: ${e}")
            return false
        }
    }

    // ==================== P2-153 Gap 6: Timezones ====================

    /**
     * Fetches the global timezone list, with hash-based incremental caching.
     *
     * iOS ref: getTimezones / TimezoneList.swift (help.getTimezonesList#49b30240)
     * TL ctor (tl_codegen verified): 0x49b30240
     * Response:
     *   help.timezonesListNotModified#970708cc → return cached list
     *   help.timezonesList#7b74ed71 timezones:Vector<Timezone> hash:int
     *     → parse + cache + return
     * timezone#ff9289f5 id:string name:string utc_offset:int (tl_codegen: 0xff9289f5)
     * Cache: hash + JSON stored in AuthStorage Preferences.
     *        JSON format: "id|name|utcOffset;" repeated.
     */
    public func getTimezonesList(): ArrayList<TimezoneInfo> {
        let result = ArrayList<TimezoneInfo>()
        let storage = getAuthStorage()
        let cachedHash = storage.getTimezonesCacheHash()
        try {
            let client = getMTProtoClient()
            let req = HelpGetTimezonesList()
            req.hash = cachedHash
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) {
                return loadTimezonesFromCache(storage)
            }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] getTimezonesList RPC error: ${errCode} ${errMsg}")
                return loadTimezonesFromCache(storage)
            }
            // help.timezonesListNotModified#970708cc — cache still valid
            if (ctor == 0x970708cc) {
                Hilog.info(0, "CjTelegram", "[SettingsService] getTimezonesList: not modified, using cache hash=${cachedHash}")
                return loadTimezonesFromCache(storage)
            }
            // help.timezonesList#7b74ed71 timezones:Vector<Timezone> hash:int
            if (ctor == 0x7b74ed71) {
                let vecCtor = d.readUInt32()
                if (vecCtor == TLConstructors.VECTOR) {
                    let count = d.readInt32()
                    var i: Int32 = 0
                    while (i < count) {
                        // timezone#ff9289f5 id:string name:string utc_offset:int (tl_codegen verified)
                        let tzCtor = d.readUInt32()
                        if (tzCtor == 0xff9289f5) {
                            let tz = TimezoneInfo()
                            tz.id = d.readString()
                            tz.name = d.readString()
                            tz.utcOffset = d.readInt32()
                            result.add(tz)
                        }
                        i += 1
                    }
                }
                let newHash = d.readInt32()
                // Persist to cache
                let cacheJson = buildTimezonesCacheJson(result)
                storage.saveTimezonesCache(newHash, cacheJson)
                Hilog.info(0, "CjTelegram", "[SettingsService] getTimezonesList: fetched ${result.size} timezones, hash=${newHash}")
                return result
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] getTimezonesList exception: ${e}")
        }
        return loadTimezonesFromCache(storage)
    }

    private func loadTimezonesFromCache(storage: AuthStorage): ArrayList<TimezoneInfo> {
        let result = ArrayList<TimezoneInfo>()
        let json = storage.getTimezonesCacheJson()
        if (json.size == 0) { return result }
        let entries = json.split(";")
        for (entry in entries) {
            if (entry.size == 0) { continue }
            let parts = entry.split("|")
            if (parts.size < 3) { continue }
            let tz = TimezoneInfo()
            tz.id = parts[0]
            tz.name = parts[1]
            var offset: Int32 = 0
            var negative = false
            let offsetStr = parts[2]
            var startIdx: Int64 = 0
            if (offsetStr.size > 0) {
                let firstRune = offsetStr[0]
                if (UInt32(firstRune) == 45) {  // '-'
                    negative = true
                    startIdx = 1
                }
            }
            var ci: Int64 = startIdx
            while (ci < offsetStr.size) {
                let code = UInt32(offsetStr[ci])
                if (code >= 48 && code <= 57) { offset = offset * 10 + Int32(code - 48) }
                ci += 1
            }
            if (negative) { offset = -offset }
            tz.utcOffset = offset
            result.add(tz)
        }
        return result
    }

    private func buildTimezonesCacheJson(list: ArrayList<TimezoneInfo>): String {
        var sb: String = ""
        for (tz in list) {
            sb = sb + tz.id + "|" + tz.name + "|" + Int64(tz.utcOffset).toString() + ";"
        }
        return sb
    }
    // ==================== P2-153b Gap 1: Business Work Hours ====================

    /**
     * Updates or clears business work hours.
     *
     * iOS ref: updateAccountBusinessHours in TelegramEngineAccountData.swift:185
     * TL: account.updateBusinessWorkHours#4b00e066 flags:# business_work_hours:flags.0?BusinessWorkHours = Bool
     * businessWorkHours#8c92b098: flags:# open_now:flags.0?true timezone_id:string weekly_open:Vector<BusinessWeeklyOpen>
     * businessWeeklyOpen#120b1ab9: start_minute:int end_minute:int
     *
     * TL ctor chain (tl_codegen verified):
     *   outer:  0x4b00e066 (account.updateBusinessWorkHours)
     *   inner:  0x8c92b098 (businessWorkHours)
     *   vector elements: 0x120b1ab9 (businessWeeklyOpen)
     *
     * workHours=None clears the schedule.
     */
    public func updateBusinessWorkHours(workHours: Option<BusinessWorkHoursData>): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateBusinessWorkHours()
            match (workHours) {
                case Some(wh) =>
                    req.hasWorkHours = true
                    req.workHours.openNow = wh.openNow
                    req.workHours.timezoneId = wh.timezoneId
                    for (period in wh.weeklyOpen) {
                        let p = BusinessWeeklyOpen()
                        p.startMinute = period.startMinute
                        p.endMinute = period.endMinute
                        req.workHours.weeklyOpen.add(p)
                    }
                case None =>
                    req.hasWorkHours = false
            }
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessWorkHours error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessWorkHours ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessWorkHours exception: ${e}")
            return false
        }
    }

    // ==================== P2-153b Gap 2: Business Location ====================

    /**
     * Updates or clears business location.
     *
     * iOS ref: updateAccountBusinessLocation in TelegramEngineAccountData.swift:208
     * TL: account.updateBusinessLocation#9e6b131a flags:# geo_point:flags.1?InputGeoPoint address:flags.0?string = Bool
     * inputGeoPoint#48222faf: flags:# lat:double long:double accuracy_radius:flags.0?int
     *
     * TL ctor chain (tl_codegen verified):
     *   outer: 0x9e6b131a (account.updateBusinessLocation)
     *   optional geo: 0x48222faf (inputGeoPoint)
     *
     * location=None clears the location.
     */
    public func updateBusinessLocation(location: Option<BusinessLocationData>): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateBusinessLocation()
            match (location) {
                case Some(loc) =>
                    if (loc.address.size > 0) {
                        req.hasAddress = true
                        req.address = loc.address
                    }
                    if (loc.hasGeoPoint) {
                        req.hasGeoPoint = true
                        req.geoLat = loc.geoLat
                        req.geoLon = loc.geoLon
                    }
                case None => ()
            }
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessLocation error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessLocation ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessLocation exception: ${e}")
            return false
        }
    }

    // ==================== P2-153b Gap 3: Business Greeting Message ====================

    /**
     * Updates or clears the business greeting message.
     *
     * iOS ref: _internal_updateBusinessGreetingMessage in QuickReplyMessages.swift:951
     * TL: account.updateBusinessGreetingMessage#66cdafc4 flags:# message:flags.0?InputBusinessGreetingMessage = Bool
     * inputBusinessGreetingMessage#194cb3b: shortcut_id:int recipients:InputBusinessRecipients no_activity_days:int
     * inputBusinessRecipients#6f8b32aa: flags:# ... users:flags.4?Vector<InputUser>
     *
     * TL ctor chain (tl_codegen verified):
     *   outer: 0x66cdafc4 (account.updateBusinessGreetingMessage)
     *   greeting: 0x0194cb3b (inputBusinessGreetingMessage)
     *   recipients: 0x6f8b32aa (inputBusinessRecipients)
     *   users vector elements: 0xf21158c6 (inputUser)
     *
     * greeting=None clears the greeting.
     */
    public func updateBusinessGreetingMessage(greeting: Option<BusinessGreetingMessageData>): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateBusinessGreetingMessage()
            match (greeting) {
                case Some(g) =>
                    req.hasMessage = true
                    req.message.shortcutId = g.shortcutId
                    req.message.noActivityDays = g.noActivityDays
                    SettingsService.fillInputBusinessRecipients(req.message.recipients, g.recipients)
                case None =>
                    req.hasMessage = false
            }
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessGreetingMessage error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessGreetingMessage ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessGreetingMessage exception: ${e}")
            return false
        }
    }

    private static func fillInputBusinessRecipients(target: InputBusinessRecipients, src: BusinessRecipientsData) {
        target.existingChats = src.existingChats
        target.newChats = src.newChats
        target.contacts = src.contacts
        target.nonContacts = src.nonContacts
        target.excludeSelected = src.excludeSelected
        var i: Int64 = 0
        while (i < src.userIds.size && i < src.userAccessHashes.size) {
            let u = InputUser()
            u.userId = src.userIds[i]
            u.accessHash = src.userAccessHashes[i]
            target.users.add(u)
            i += 1
        }
    }

    // ==================== P2-153b Gap 4: Business Away Message ====================

    /**
     * Updates or clears the business away message.
     *
     * iOS ref: _internal_updateBusinessAwayMessage in QuickReplyMessages.swift:993
     * TL: account.updateBusinessAwayMessage#a26a7fa5 flags:# message:flags.0?InputBusinessAwayMessage = Bool
     * inputBusinessAwayMessage#832175e0: flags:# offline_only:flags.0?true shortcut_id:int
     *   schedule:BusinessAwayMessageSchedule recipients:InputBusinessRecipients
     *
     * TL ctor chain (tl_codegen verified):
     *   outer:    0xa26a7fa5 (account.updateBusinessAwayMessage)
     *   away:     0x832175e0 (inputBusinessAwayMessage)
     *   schedule: 0xc9b9e2b9 (always) | 0xc3f2f501 (outsideWorkHours) | 0xcc4d9ecc (custom)
     *   recipients: 0x6f8b32aa (inputBusinessRecipients)
     *
     * away=None clears the away message.
     */
    public func updateBusinessAwayMessage(away: Option<BusinessAwayMessageData>): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateBusinessAwayMessage()
            match (away) {
                case Some(a) =>
                    req.hasMessage = true
                    req.message.offlineOnly = a.offlineOnly
                    req.message.shortcutId = a.shortcutId
                    req.message.scheduleType = a.schedule.scheduleType
                    req.message.scheduleStartDate = a.schedule.startDate
                    req.message.scheduleEndDate = a.schedule.endDate
                    SettingsService.fillInputBusinessRecipients(req.message.recipients, a.recipients)
                case None =>
                    req.hasMessage = false
            }
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessAwayMessage error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessAwayMessage ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessAwayMessage exception: ${e}")
            return false
        }
    }

    // ==================== P2-153b Gap 5: Business Intro ====================

    /**
     * Updates or clears the business intro (title + description + optional sticker).
     *
     * iOS ref: _internal_updateBusinessIntro in QuickReplyMessages.swift:1051
     * TL: account.updateBusinessIntro#a614d034 flags:# intro:flags.0?InputBusinessIntro = Bool
     * inputBusinessIntro#9c469cd: flags:# title:string description:string sticker:flags.0?InputDocument
     *
     * TL ctor chain (tl_codegen verified):
     *   outer: 0xa614d034 (account.updateBusinessIntro)
     *   intro: 0x09c469cd (inputBusinessIntro)
     *   optional sticker doc: 0x1abfb575 (inputDocument)
     *
     * intro=None clears the intro.
     */
    public func updateBusinessIntro(intro: Option<BusinessIntroData>): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateBusinessIntro()
            match (intro) {
                case Some(bi) =>
                    req.hasIntro = true
                    req.intro.title = bi.title
                    req.intro.description = bi.description
                    req.intro.hasStickerDocId = bi.hasStickerDocId
                    req.intro.stickerDocId = bi.stickerDocId
                    req.intro.stickerAccessHash = bi.stickerAccessHash
                case None =>
                    req.hasIntro = false
            }
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessIntro error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessIntro ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateBusinessIntro exception: ${e}")
            return false
        }
    }

    // ==================== P2-153b Gap 6: Connected Bot ====================

    /**
     * Sets or removes the connected business bot.
     *
     * iOS ref: _internal_setAccountConnectedBot in QuickReplyMessages.swift:1249
     * TL: account.updateConnectedBot#66a08c7e flags:# deleted:flags.1?true
     *   rights:flags.0?BusinessBotRights bot:InputUser recipients:InputBusinessBotRecipients = Updates
     * businessBotRights#a0624cf7: flags:#
     * inputBusinessBotRecipients#c4e5921e: flags:# ... users:flags.4?Vector<InputUser> exclude_users:flags.6?Vector<InputUser>
     *
     * TL ctor chain (tl_codegen verified):
     *   outer:      0x66a08c7e (account.updateConnectedBot)
     *   rights:     0xa0624cf7 (businessBotRights)
     *   bot:        0xf21158c6 (inputUser)
     *   recipients: 0xc4e5921e (inputBusinessBotRecipients)
     *   user vectors: 0x1cb5c415 (Vector) + 0xf21158c6 (inputUser) each
     *
     * bot=None removes the connected bot.
     */
    public func updateConnectedBot(bot: Option<ConnectedBotData>): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateConnectedBot()
            match (bot) {
                case Some(b) =>
                    req.deleted = false
                    req.hasRights = true
                    req.rights.flags = b.rightFlags
                    req.bot.userId = b.botUserId
                    req.bot.accessHash = b.botAccessHash
                    req.recipients.existingChats = b.recipients.existingChats
                    req.recipients.newChats = b.recipients.newChats
                    req.recipients.contacts = b.recipients.contacts
                    req.recipients.nonContacts = b.recipients.nonContacts
                    req.recipients.excludeSelected = b.recipients.excludeSelected
                    var i: Int64 = 0
                    while (i < b.recipients.userIds.size && i < b.recipients.userAccessHashes.size) {
                        let u = InputUser()
                        u.userId = b.recipients.userIds[i]
                        u.accessHash = b.recipients.userAccessHashes[i]
                        req.recipients.users.add(u)
                        i += 1
                    }
                case None =>
                    req.deleted = true
                    req.hasRights = false
            }
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] updateConnectedBot error: ${errCode} ${errMsg}")
                return false
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] updateConnectedBot success ctor=0x${ctor.toString()}")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] updateConnectedBot exception: ${e}")
            return false
        }
    }

    /**
     * Fetches current connected bot connection info.
     *
     * iOS ref: account.getBotBusinessConnection → confirmBotConnectionReview in TelegramEngineAccountData.swift:285
     * TL: account.getBotBusinessConnection#76a86270 connection_id:string = Updates
     * Response: Updates with embedded botBusinessConnection#8f34b2f5 in its updates list.
     *   botBusinessConnection#8f34b2f5 flags:# disabled:flags.1?true connection_id:string
     *   user_id:long dc_id:int date:int rights:flags.2?BusinessBotRights
     * tl_codegen verified: outer 0x76a86270, inner 0x8f34b2f5
     */
    public func getBotBusinessConnection(connectionId: String): Option<BotBusinessConnectionData> {
        try {
            let client = getMTProtoClient()
            let req = AccountGetBotBusinessConnection()
            req.connectionId = connectionId
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return None }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] getBotBusinessConnection error: ${errCode} ${errMsg}")
                return None
            }
            // account.getBotBusinessConnection = Updates (schema line 2144)
            // updateBotBusinessConnect#8ae5c97a connection:BotBusinessConnection qts:int = Update
            // botBusinessConnection#8f34b2f5 flags:# disabled:flags.1?true connection_id:string
            //   user_id:long dc_id:int date:int rights:flags.2?BusinessBotRights
            //
            // updates#74ae4240 updates:Vector<Update> users chats date seq
            // updatesCombined#725b04c3 updates:Vector<Update> users chats date seq_start seq
            // updateShort#78d4dec1 update:Update date
            if (ctor == 0x74ae4240 || ctor == 0x725b04c3) {
                // updates:Vector<Update> — this RPC schema guarantees exactly 1 update
                let vecCtor = d.readUInt32()
                if (vecCtor != 0x1cb5c415) { return None }
                let updateCount = d.readInt32()
                if (updateCount < 1) { return None }
                let updateCtor = d.readUInt32()
                if (updateCtor == 0x8ae5c97a) {
                    let connCtor = d.readUInt32()
                    if (connCtor == 0x8f34b2f5) {
                        return SettingsService.parseBotBusinessConnection(d)
                    }
                }
                return None
            }
            if (ctor == 0x78d4dec1) {
                // updateShort — single Update embedded directly
                let updateCtor = d.readUInt32()
                if (updateCtor == 0x8ae5c97a) {
                    let connCtor = d.readUInt32()
                    if (connCtor == 0x8f34b2f5) {
                        return SettingsService.parseBotBusinessConnection(d)
                    }
                }
                return None
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] getBotBusinessConnection: unexpected Updates ctor")
            return None
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] getBotBusinessConnection exception: ${e}")
            return None
        }
    }

    // Parse botBusinessConnection#8f34b2f5 fields (ctor already consumed by caller).
    // flags:# disabled:flags.1?true connection_id:string user_id:long dc_id:int date:int
    //   rights:flags.2?BusinessBotRights (businessBotRights#a0624cf7 flags:#)
    private static func parseBotBusinessConnection(d: TLDeserializer): Option<BotBusinessConnectionData> {
        let result = BotBusinessConnectionData()
        let flags = d.readInt32()
        result.disabled = (flags & 2) != 0
        result.connectionId = d.readString()
        result.userId = d.readInt64()
        result.dcId = d.readInt32()
        result.date = d.readInt32()
        if ((flags & 4) != 0) {
            let rightsCtor = d.readUInt32()
            if (rightsCtor == 0xa0624cf7) {
                result.rightFlags = d.readInt32()
            }
        }
        Hilog.info(0, "CjTelegram", "[SettingsService] getBotBusinessConnection userId=${result.userId}")
        return Some(result)
    }

    // ==================== P2-153b Gap 7: Business Chat Links ====================

    /**
     * Creates a new business chat link.
     *
     * iOS ref: _internal_createBusinessChatLink in TelegramEngineAccountData.swift:293
     * TL: account.createBusinessChatLink#8851e68e link:InputBusinessChatLink = BusinessChatLink
     * inputBusinessChatLink#11679fa7: flags:# message:string entities:flags.0?Vector<MessageEntity> title:flags.1?string
     * businessChatLink#b4ae666f: flags:# link:string message:string entities:flags.0?... title:flags.1?... views:int
     *
     * TL ctor chain (tl_codegen verified):
     *   outer: 0x8851e68e (account.createBusinessChatLink)
     *   input: 0x11679fa7 (inputBusinessChatLink)
     *   response: 0xb4ae666f (businessChatLink)
     */
    public func createBusinessChatLink(message: String, title: String): Option<BusinessChatLinkData> {
        try {
            let client = getMTProtoClient()
            let req = AccountCreateBusinessChatLink()
            req.link.message = message
            if (title.size > 0) {
                req.link.hasTitle = true
                req.link.title = title
            }
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return None }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] createBusinessChatLink error: ${errCode} ${errMsg}")
                return None
            }
            return SettingsService.parseBusinessChatLink(d, ctor)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] createBusinessChatLink exception: ${e}")
            return None
        }
    }

    /**
     * Edits an existing business chat link by slug.
     *
     * iOS ref: _internal_editBusinessChatLink in TelegramEngineAccountData.swift:297
     * TL: account.editBusinessChatLink#8c3410af slug:string link:InputBusinessChatLink = BusinessChatLink
     * tl_codegen verified: 0x8c3410af
     */
    public func editBusinessChatLink(slug: String, message: String, title: String): Option<BusinessChatLinkData> {
        try {
            let client = getMTProtoClient()
            let req = AccountEditBusinessChatLink()
            req.slug = slug
            req.link.message = message
            if (title.size > 0) {
                req.link.hasTitle = true
                req.link.title = title
            }
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return None }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] editBusinessChatLink error: ${errCode} ${errMsg}")
                return None
            }
            return SettingsService.parseBusinessChatLink(d, ctor)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] editBusinessChatLink exception: ${e}")
            return None
        }
    }

    /**
     * Deletes a business chat link by slug.
     *
     * iOS ref: _internal_deleteBusinessChatLink in TelegramEngineAccountData.swift:301
     * TL: account.deleteBusinessChatLink#60073674 slug:string = Bool
     * tl_codegen verified: 0x60073674
     */
    public func deleteBusinessChatLink(slug: String): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountDeleteBusinessChatLink()
            req.slug = slug
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteBusinessChatLink error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            Hilog.info(0, "CjTelegram", "[SettingsService] deleteBusinessChatLink slug=${slug} ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] deleteBusinessChatLink exception: ${e}")
            return false
        }
    }

    /**
     * Fetches all business chat links for the current account.
     *
     * iOS ref: _internal_refreshBusinessChatLinks in TelegramEngineAccountData.swift:305
     * TL: account.getBusinessChatLinks#6f70dde1 = account.BusinessChatLinks
     * account.businessChatLinks#ec43a2d1: links:Vector<BusinessChatLink> chats:... users:...
     * businessChatLink#b4ae666f: flags:# link:string message:string ... views:int
     *
     * TL ctor chain (tl_codegen verified):
     *   outer: 0x6f70dde1 (account.getBusinessChatLinks)
     *   response: 0xec43a2d1 (account.businessChatLinks)
     *   vector: 0x1cb5c415 + 0xb4ae666f (businessChatLink) each
     */
    public func getBusinessChatLinks(): ArrayList<BusinessChatLinkData> {
        let result = ArrayList<BusinessChatLinkData>()
        try {
            let client = getMTProtoClient()
            let req = AccountGetBusinessChatLinks()
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return result }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] getBusinessChatLinks error: ${errCode} ${errMsg}")
                return result
            }
            if (ctor == 0xec43a2d1) {
                let vecCtor = d.readUInt32()
                if (vecCtor == TLConstructors.VECTOR) {
                    let count = d.readInt32()
                    var i: Int32 = 0
                    while (i < count) {
                        let linkCtor = d.readUInt32()
                        match (SettingsService.parseBusinessChatLink(d, linkCtor)) {
                            case Some(link) => result.add(link)
                            case None => ()
                        }
                        i += 1
                    }
                }
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] getBusinessChatLinks: ${result.size} links")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] getBusinessChatLinks exception: ${e}")
        }
        return result
    }

    private static func parseBusinessChatLink(d: TLDeserializer, ctor: UInt32): Option<BusinessChatLinkData> {
        if (ctor != 0xb4ae666f) { return None }
        let link = BusinessChatLinkData()
        try {
            let flags = d.readInt32()
            link.link = d.readString()
            link.message = d.readString()
            if ((flags & 1) != 0) {
                let _ = d.readUInt32()  // skip entities vector ctor
                let entCount = d.readInt32()
                var ei: Int32 = 0
                while (ei < entCount) {
                    let _ = d.readUInt32()
                    let _ = d.readInt32()
                    let _ = d.readInt32()
                    ei += 1
                }
            }
            if ((flags & 2) != 0) {
                link.title = d.readString()
            }
            link.views = d.readInt32()
        } catch (_e: Exception) {}
        return Some(link)
    }

    // ==================== P2-153b Gap 8: Quick Reply Shortcuts ====================

    /**
     * Fetches the list of quick reply shortcuts (incremental, hash-based).
     *
     * iOS ref: _internal_shortcutMessageList → Api.functions.messages.getQuickReplies
     *   in QuickReplyMessages.swift:728
     * TL: messages.getQuickReplies#d483f2a8 hash:long = messages.QuickReplies
     * messages.quickReplies#c68d6695: quick_replies:Vector<QuickReply> messages:... chats:... users:...
     * messages.quickRepliesNotModified#5f91eb5b
     * quickReply#0697102b: shortcut_id:int shortcut:string top_message:int count:int
     *
     * TL ctor chain (tl_codegen verified):
     *   outer: 0xd483f2a8 (messages.getQuickReplies)
     *   response full: 0xc68d6695 (messages.quickReplies)
     *   response cached: 0x5f91eb5b (messages.quickRepliesNotModified)
     *   vector elements: 0x0697102b (quickReply)
     *
     * hash=0 fetches everything; pass the hash from the last response for incremental updates.
     * Returns empty list when not modified (caller uses cached data).
     */
    public func getQuickReplyShortcuts(hash: Int64): ArrayList<QuickReplyShortcutData> {
        let result = ArrayList<QuickReplyShortcutData>()
        try {
            let client = getMTProtoClient()
            let req = MessagesGetQuickReplies()
            req.hash = hash
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return result }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] getQuickReplyShortcuts error: ${errCode} ${errMsg}")
                return result
            }
            if (ctor == 0x5f91eb5b) {
                Hilog.info(0, "CjTelegram", "[SettingsService] getQuickReplyShortcuts: not modified")
                return result
            }
            if (ctor == 0xc68d6695) {
                let vecCtor = d.readUInt32()
                if (vecCtor == TLConstructors.VECTOR) {
                    let count = d.readInt32()
                    var i: Int32 = 0
                    while (i < count) {
                        let qrCtor = d.readUInt32()
                        if (qrCtor == 0x0697102b) {
                            let qr = QuickReplyShortcutData()
                            qr.shortcutId = d.readInt32()
                            qr.shortcut = d.readString()
                            qr.topMessage = d.readInt32()
                            qr.count = d.readInt32()
                            result.add(qr)
                        }
                        i += 1
                    }
                }
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] getQuickReplyShortcuts: ${result.size} shortcuts")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] getQuickReplyShortcuts exception: ${e}")
        }
        return result
    }

    /**
     * Renames an existing quick reply shortcut.
     *
     * iOS ref: _internal_editMessageShortcut → messages.editQuickReplyShortcut in QuickReplyMessages.swift:314
     * TL: messages.editQuickReplyShortcut#5c003cef shortcut_id:int shortcut:string = Bool
     * tl_codegen verified: 0x5c003cef
     */
    public func editQuickReplyShortcut(shortcutId: Int32, shortcut: String): Bool {
        try {
            let client = getMTProtoClient()
            let req = MessagesEditQuickReplyShortcut()
            req.shortcutId = shortcutId
            req.shortcut = shortcut
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] editQuickReplyShortcut error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            Hilog.info(0, "CjTelegram", "[SettingsService] editQuickReplyShortcut id=${shortcutId} ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] editQuickReplyShortcut exception: ${e}")
            return false
        }
    }

    /**
     * Deletes a quick reply shortcut and all its messages.
     *
     * iOS ref: _internal_deleteMessageShortcuts → messages.deleteQuickReplyShortcut
     *   in ManagedCloudChatRemoveMessagesOperations.swift:427
     * TL: messages.deleteQuickReplyShortcut#3cc04740 shortcut_id:int = Bool
     * tl_codegen verified: 0x3cc04740
     */
    public func deleteQuickReplyShortcut(shortcutId: Int32): Bool {
        try {
            let client = getMTProtoClient()
            let req = MessagesDeleteQuickReplyShortcut()
            req.shortcutId = shortcutId
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] deleteQuickReplyShortcut error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            Hilog.info(0, "CjTelegram", "[SettingsService] deleteQuickReplyShortcut id=${shortcutId} ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] deleteQuickReplyShortcut exception: ${e}")
            return false
        }
    }

    /**
     * Reorders quick reply shortcuts by providing the desired shortcut_id order.
     *
     * iOS ref: _internal_reorderMessageShortcuts in QuickReplyMessages.swift
     * TL: messages.reorderQuickReplies#60331907 order:Vector<int> = Bool
     * tl_codegen verified: 0x60331907
     * order: full ordered list of shortcut_ids (same as iOS reorderQuickReplies param)
     */
    public func reorderQuickReplyShortcuts(order: ArrayList<Int32>): Bool {
        try {
            let client = getMTProtoClient()
            let req = MessagesReorderQuickReplies()
            for (id in order) {
                req.order.add(id)
            }
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] reorderQuickReplyShortcuts error: ${errCode} ${errMsg}")
                return false
            }
            let ok = (ctor == TLConstructors.BOOL_TRUE)
            Hilog.info(0, "CjTelegram", "[SettingsService] reorderQuickReplyShortcuts ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] reorderQuickReplyShortcuts exception: ${e}")
            return false
        }
    }

    /**
     * Fetches messages for a specific quick reply shortcut.
     *
     * iOS ref: messages.getQuickReplyMessages in AccountViewTracker.swift:84
     * TL: messages.getQuickReplyMessages#94a495c3 flags:# shortcut_id:int id:flags.0?Vector<int> hash:long
     *   = messages.Messages
     * tl_codegen verified: 0x94a495c3
     * ids=empty → fetch all messages; hash=0 → no caching.
     * Returns raw count of messages parsed from the Messages response.
     */
    public func getQuickReplyMessages(shortcutId: Int32, ids: ArrayList<Int32>): Int32 {
        try {
            let client = getMTProtoClient()
            let req = MessagesGetQuickReplyMessages()
            req.shortcutId = shortcutId
            for (id in ids) {
                req.ids.add(id)
            }
            req.hash = 0
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return 0 }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] getQuickReplyMessages error: ${errCode} ${errMsg}")
                return 0
            }
            // messages.Messages variants (schema lines 289-292):
            // messages.messages#8c718e87 messages:Vector<Message> chats users
            //   — no count field; count is the vector element count itself
            // messages.messagesSlice#3a54685e flags:# count:int next_rate? offset_id_offset? messages:Vector ...
            // messages.channelMessages#c776ba4e flags:# pts:int count:int offset_id_offset? messages:Vector ...
            // messages.messagesNotModified#74535f21 count:int
            if (ctor == 0x8c718e87) {
                // messages.messages — no count; read vector ctor+count to get message count
                let vecCtor = d.readUInt32()
                if (vecCtor == 0x1cb5c415) {
                    let countField = d.readInt32()
                    Hilog.info(0, "CjTelegram", "[SettingsService] getQuickReplyMessages(messages) shortcutId=${shortcutId}: ${countField}")
                    return countField
                }
                return 0
            }
            if (ctor == 0x3a54685e) {
                // messages.messagesSlice — flags:int count:int ...
                let _flags = d.readInt32()
                let countField = d.readInt32()
                Hilog.info(0, "CjTelegram", "[SettingsService] getQuickReplyMessages(slice) shortcutId=${shortcutId}: ${countField}")
                return countField
            }
            if (ctor == 0xc776ba4e) {
                // messages.channelMessages — flags:int pts:int count:int ...
                let _flags = d.readInt32()
                let _pts = d.readInt32()
                let countField = d.readInt32()
                Hilog.info(0, "CjTelegram", "[SettingsService] getQuickReplyMessages(channel) shortcutId=${shortcutId}: ${countField}")
                return countField
            }
            if (ctor == 0x74535f21) {
                // messages.messagesNotModified — count:int only
                let countField = d.readInt32()
                Hilog.info(0, "CjTelegram", "[SettingsService] getQuickReplyMessages(notModified) shortcutId=${shortcutId}: ${countField}")
                return countField
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] getQuickReplyMessages: unexpected ctor 0x${ctor.toString()}")
            return 0
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] getQuickReplyMessages exception: ${e}")
            return 0
        }
    }

    // ========== Sensitive content settings (account.getContentSettings / account.setContentSettings) ==========
    // diag-suite_settings_data_storage-round3-data_storage_root-batch.md §F-B 改动 2.
    // 对位 TelegramCore ContentSettings.swift:60-88。

    /**
     * 对位 `contentSettingsConfiguration(network:)`（ContentSettings.swift:60-72）。
     * 请求失败（异常/空响应/RPC error）时按源侧 `catch { .single(.default) }` 返回
     * `(false, false)`，不抛异常、不返回 Option 让调用点再决策。
     * flags 位定义逐位照抄源侧 :66 —— 位 0 = sensitiveContentEnabled，位 1 = canAdjustSensitiveContent。
     */
    public func getContentSettingsConfiguration(): (sensitiveEnabled: Bool, canAdjust: Bool) {
        try {
            let client = getMTProtoClient()
            let req = AccountGetContentSettings()
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) { return (false, false) }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[SettingsService] getContentSettingsConfiguration error: ${errCode} ${errMsg}")
                return (false, false)
            }
            // account.contentSettings#57e28221 flags:# sensitive_enabled:flags.0?true sensitive_can_change:flags.1?true
            if (ctor == 0x57e28221) {
                let flags = d.readInt32()
                let sensitiveEnabled = (flags & 1) != 0
                let canAdjust = (flags & 2) != 0
                Hilog.info(0, "CjTelegram", "[SettingsService] getContentSettingsConfiguration: sensitiveEnabled=${sensitiveEnabled} canAdjust=${canAdjust}")
                return (sensitiveEnabled, canAdjust)
            }
            Hilog.info(0, "CjTelegram", "[SettingsService] getContentSettingsConfiguration: unexpected ctor 0x${ctor.toString()}")
            return (false, false)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] getContentSettingsConfiguration exception: ${e}")
            return (false, false)
        }
    }

    /**
     * 对位 `updateRemoteContentSettingsConfiguration(postbox:network:sensitiveContentEnabled:)`
     * （ContentSettings.swift:74-88）：写远端后调一次既有的 `getAppConfig()` 刷新 app config
     * （对位源侧 `updateAppConfigurationOnce`）。返回写入是否成功（RPC 层 Bool）；刷新
     * app config 的结果不影响本函数返回值（对位源侧写完即忽略刷新结果本身）。
     */
    public func setSensitiveContentEnabled(enabled: Bool): Bool {
        var ok = false
        try {
            let client = getMTProtoClient()
            let req = AccountSetContentSettings()
            req.sensitiveEnabled = enabled
            let data = client.sendRequest(req.toBytes())
            if (data.size >= 4) {
                let d = TLDeserializer(data)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errCode = d.readInt32()
                    let errMsg = d.readString()
                    Hilog.info(0, "CjTelegram", "[SettingsService] setSensitiveContentEnabled error: ${errCode} ${errMsg}")
                } else {
                    ok = (ctor == 0x997275b5)
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SettingsService] setSensitiveContentEnabled exception: ${e}")
        }
        if (ok) {
            let _ = getTelegramEngineDataService().getAppConfig()
        }
        Hilog.info(0, "CjTelegram", "[SettingsService] setSensitiveContentEnabled(${enabled})=${ok}")
        return ok
    }

    /**
     * 对位 `AgeVerificationScreen.swift:23-29` 的年龄验证谓词：读 app config 的
     * `need_age_video_verification` 布尔，缺键或非布尔时返回 false（对位源侧 `as? Bool`
     * 失败即 false）。目标侧 `getAppConfig()`（`services/DataService.cj:259`）已在工作，
     * 本函数只做本地解析，不新增网络调用（复刻 pages/DebugSettingsPage.cj
     * resolveShowTest1Gate 同款：结果落到 configJson 再本地 JsonParser 判定）。
     */
    public func needAgeVideoVerification(): Bool {
        let appConfig = getTelegramEngineDataService().getAppConfig()
        let configJson = match (appConfig) {
            case Some(cfg) => cfg.configJson
            case None => ""
        }
        if (configJson.size == 0) {
            return false
        }
        let obj = JsonParser.parseObject(configJson)
        if (!obj.has("need_age_video_verification")) {
            return false
        }
        return obj.getBool("need_age_video_verification")
    }
}

// ======================================================================
// Login email pattern parsing (moved here from pages/LoginEmailPage.cj —
// diag-suite_settings_privacy-TC-0143-round2.md M1 + M5(c): this feature owns
// SettingsService.cj, so the account.getPassword decode + its two consumers
// (PrivacySettingsPage.cj, LoginEmailPage.cj) can share one implementation
// instead of a package-private copy living inside an unreachable page.)
// ======================================================================

/**
 * Parse loginEmailPattern (flags.6) from account.getPassword response.
 * account.password#957b50fb
 *   flags:# has_recovery:flags.0?true has_secure_values:flags.1?true has_password:flags.2?true
 *   current_algo:flags.2?PasswordKdfAlgo srp_B:flags.2?bytes srp_id:flags.2?long
 *   hint:flags.3?string email_unconfirmed_pattern:flags.4?string
 *   new_algo:PasswordKdfAlgo new_secure_algo:SecurePasswordKdfAlgo secure_random:bytes
 *   pending_reset_date:flags.5?int login_email_pattern:flags.6?string
 *
 * M1 fix (diag-suite_settings_privacy-TC-0143-round2.md §RC-1/§修法方向 M1): both boxed
 * fields (`new_algo`: PasswordKdfAlgo, `new_secure_algo`: SecurePasswordKdfAlgo) are now
 * decoded via a full constructor-dispatch table (every known constructor's exact field
 * count from telegram_api.tl), not a single hard-coded constructor with silent fall-through
 * for anything else. An unrecognized constructor aborts parsing immediately (mirrors the
 * source's `Api.parse` returning nil on any unrecognized boxed value — no half-decoded
 * result is ever produced).
 */
public func parseLoginEmailPattern(data: Array<Byte>): String {
    if (data.size < 8) { return "" }
    let d = TLDeserializer(data)
    try {
        let ctor = d.readUInt32()
        if (ctor != 0x957b50fb) { return "" }
        let flags = d.readInt32()
        let hasPassword = (flags & 4) != 0
        if (hasPassword) {
            let algoCtor = d.readUInt32()
            if (algoCtor == 0x3a912d4a) {
                let _s1 = d.readBytes()
                let _s2 = d.readBytes()
                let _g = d.readInt32()
                let _p = d.readBytes()
            }
            let _srpB = d.readBytes()
            let _srpId = d.readInt64()
        }
        if ((flags & 8) != 0) {
            let _hint = d.readString()
        }
        if ((flags & 16) != 0) {
            let _emailUnconf = d.readString()
        }
        // new_algo:PasswordKdfAlgo — passwordKdfAlgoModPow#3a912d4a (4 fields) /
        // passwordKdfAlgoUnknown#d45ab096 (0 fields); anything else aborts.
        let newAlgoCtor = d.readUInt32()
        if (newAlgoCtor == 0x3a912d4a) {
            let _ns1 = d.readBytes()
            let _ns2 = d.readBytes()
            let _ng = d.readInt32()
            let _np = d.readBytes()
        } else if (newAlgoCtor == 0xd45ab096) {
            // passwordKdfAlgoUnknown — no fields.
        } else {
            Hilog.info(0, "CjTelegram", "[LoginEmail] PARSE_FAILED parseLoginEmailPattern: unknown new_algo ctor 0x${newAlgoCtor.toString()}")
            return ""
        }
        // new_secure_algo:SecurePasswordKdfAlgo — securePasswordKdfAlgoUnknown#4a8537
        // (0 fields) / securePasswordKdfAlgoPBKDF2HMACSHA512iter100000#bbf2dda0 (1 salt
        // bytes) / securePasswordKdfAlgoSHA512#86471d92 (1 salt bytes); anything else aborts.
        let newSecureAlgoCtor = d.readUInt32()
        if (newSecureAlgoCtor == 0x004a8537) {
            // securePasswordKdfAlgoUnknown — no fields.
        } else if (newSecureAlgoCtor == 0xbbf2dda0) {
            let _salt = d.readBytes()
        } else if (newSecureAlgoCtor == 0x86471d92) {
            let _salt = d.readBytes()
        } else {
            Hilog.info(0, "CjTelegram", "[LoginEmail] PARSE_FAILED parseLoginEmailPattern: unknown new_secure_algo ctor 0x${newSecureAlgoCtor.toString()}")
            return ""
        }
        let _secRand = d.readBytes()
        if ((flags & 32) != 0) {
            let _pendingReset = d.readInt32()
        }
        if ((flags & 64) != 0) {
            let pattern = d.readString()
            Hilog.info(0, "CjTelegram", "[LoginEmail] loginEmailPattern: ${pattern}")
            return pattern
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[LoginEmail] PARSE_FAILED parseLoginEmailPattern: exception ${e}")
    }
    return ""
}

/**
 * Shared result for the Settings account-add entry point.
 *
 * The account-manager callbacks keep this services package from importing
 * core.services back through its existing core.services -> services edge.
 */
public enum SettingsAddAccountOutcome {
    | Started(Int32, Int32)
    | LimitPresented
    | AlreadyInProgress
}

/**
 * Starts the account-add flow shared by the Settings row and tab context menu.
 *
 * Slot repair, account-limit calculation, slot allocation, and routing live
 * together here so every Settings entry point has identical behavior.
 */
public func startSettingsAddAccountFlow(
    isAddingAccount!: () -> Bool,
    repairDuplicateAuthorizedSlots!: () -> Unit,
    addAccount!: () -> Option<(Int32, Int32)>
): SettingsAddAccountOutcome {
    Hilog.info(0, "CjTelegram", "[SettingsService] Add account requested")
    if (isAddingAccount()) {
        return SettingsAddAccountOutcome.AlreadyInProgress
    }

    repairDuplicateAuthorizedSlots()
    let currentAccounts = getTelegramCoreAccountManagerService().getLoggedInAccounts()
    var maximumAccounts: Int64 = 3
    for (account in currentAccounts) {
        if (account.isPremium) {
            maximumAccounts = 4
        }
    }
    if (currentAccounts.size >= maximumAccounts) {
        routerPush("PremiumLimitUpsellPage", "accounts")
        return SettingsAddAccountOutcome.LimitPresented
    }

    match (addAccount()) {
        case Some(slotPair) =>
            let (newSlot, originalSlot) = slotPair
            Hilog.info(0, "CjTelegram", "[SettingsService] addAccount: newSlot=${newSlot} originalSlot=${originalSlot}")
            routerPush("PhoneInputPage", "addaccount:${newSlot}:${originalSlot}")
            return SettingsAddAccountOutcome.Started(newSlot, originalSlot)
        case None =>
            return SettingsAddAccountOutcome.AlreadyInProgress
    }
}

// ======================================================================
// Singleton accessor
// ======================================================================

private var _settingsServiceInstance: Option<SettingsService> = None

public func getSettingsService(): SettingsService {
    match (_settingsServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = SettingsService()
            _settingsServiceInstance = Some(inst)
            // ic_wbs_cache_invalidate_on_logout / D-177: core/storage 不能反向 import
            // services（循环依赖），改用 core/storage/AuthStorage.cj 已暴露的
            // registerLogoutHook() 依赖倒置回调注册表——把 invalidateWebBrowserSettingsCache
            // 包装成无参闭包，clearAll() 登出时会按注册顺序调用。
            registerLogoutHook({ => inst.invalidateWebBrowserSettingsCache() })
            return inst
    }
}

/** channels.getAdminedPublicChannels#f8b036af flags:# (iOS Api42.swift:3630-3633). */
class ChannelsGetAdminedPublicChannelsRequest <: TLObject {
    public var flags: Int32 = 0
    public func getConstructorId(): UInt32 { return 0xf8b036af }
    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.flags)
    }
}
