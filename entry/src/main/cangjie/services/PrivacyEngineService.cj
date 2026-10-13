package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.collection.HashMap
import std.sync.Mutex
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.core.storage.*

/**
 * Privacy Engine Service — 隐私设置 + 会话管理
 *
 * Covers:
 *   Gap 1 — accountPrivacySettings fetch (account.getPrivacy#dadbc950)
 *            Response: account.privacyRules#50a04e45, all PrivacyRule variants
 *   Gap 2 — selective per-rule updates (account.setPrivacy#c9f81ce8)
 *            Full InputPrivacyRule variants: allow/disallow users/chats/closeFriends/premium
 *   Gap 3 — globalPrivacy (account.getGlobalPrivacySettings#eb2b4cf6 / setGlobalPrivacySettings#1edaaac2)
 *            Response: globalPrivacySettings#fe41b34f — all flags bits 0-7
 *   Gap 4 — closeFriends (contacts.editCloseFriends#ba6705f0)
 *            inputPrivacyValueAllowCloseFriends#2f453e49 in setPrivacy rules
 *   Gap 5 — activeSessions (account.getAuthorizations#e320c158, resetAuthorization#df77f3bc,
 *            setAuthorizationTTL#bf899aa0, changeAuthorizationSettings#40f48462)
 *            Response: account.authorizations#4bff8ea0 + authorization#ad01d61d inner
 *   Gap 6 — webSessions (account.getWebAuthorizations#182e6d6f, resetWebAuthorization#2d01b9ef,
 *            resetWebAuthorizations#682d2594)
 *            Response: account.webAuthorizations#ed56c9fc + webAuthorization#a6f8f452
 *   Gap 7 — newSessionReview (updateNewAuthorization#8951abef processing)
 *
 * InputPrivacyKey constructors (telegram_api.tl:557-568):
 *   inputPrivacyKeyStatusTimestamp#4f96cb18  (Last Seen)
 *   inputPrivacyKeyChatInvite#bdfb0426       (Groups)
 *   inputPrivacyKeyPhoneCall#fabadc5f        (Calls)
 *   inputPrivacyKeyPhoneP2P#db9e70d2         (P2P)
 *   inputPrivacyKeyForwards#a4dd4c08         (Forwards)
 *   inputPrivacyKeyProfilePhoto#5719bacc     (Profile Photo)
 *   inputPrivacyKeyPhoneNumber#0352dafa      (Phone Number)
 *   inputPrivacyKeyAddedByPhone#d1219bdd     (Added by Phone)
 *   inputPrivacyKeyVoiceMessages#aee69d68    (Voice Messages)
 *   inputPrivacyKeyAbout#3823cc40            (Bio/About)
 *   inputPrivacyKeyBirthday#d65a11cc         (Birthday)
 */
public func getPrivacyEngineService(): PrivacyEngineService {
    return PrivacyEngineService()
}

// S7-85: last server state per privacy key (account.getPrivacy / account.setPrivacy both return
// account.privacyRules). iOS PrivacyAndSecurityController fetches the settings once and hands the
// current SelectivePrivacySettings to SelectivePrivacySettingsController (no second request) and
// updateSelectiveAccountPrivacySettings never re-reads; the detail page opens from this cache the
// same way instead of waiting on another account.getPrivacy behind the root screen's burst.
// Keyed by "<userId>:<key ctor>" so another account never sees these values.
let _privacyRulesCacheMutex: Mutex = Mutex()
let _privacyRulesCache: HashMap<String, PrivacyRulesResponse> = HashMap<String, PrivacyRulesResponse>()

func privacyRulesCacheKey(keyConstructor: UInt32): String {
    let uid = match (getAuthStorage().getUserData()) {
        case Some(u) => u.id
        case None => 0
    }
    return "${uid}:${keyConstructor}"
}

public class PrivacyEngineService {

    public static let KEY_PHONE_NUMBER: UInt32 = 0x0352dafa
    public static let KEY_LAST_SEEN: UInt32 = 0x4f96cb18
    public static let KEY_PROFILE_PHOTO: UInt32 = 0x5719bacc
    public static let KEY_FORWARDS: UInt32 = 0xa4dd4c08
    public static let KEY_GROUPS: UInt32 = 0xbdfb0426
    public static let KEY_CALLS: UInt32 = 0xfabadc5f
    public static let KEY_VOICE_MESSAGES: UInt32 = 0xaee69d68
    public static let KEY_ADDED_BY_PHONE: UInt32 = 0xd1219bdd
    public static let KEY_ABOUT: UInt32 = 0x3823cc40
    public static let KEY_BIRTHDAY: UInt32 = 0xd65a11cc
    // diag-suite_settings_privacy-TC-0127.md P6 边界条件 2（PRIVACY 段补齐 12 行）：
    // 两个新增分类的真实 InputPrivacyKey 常量。本仓 telegram_api.tl 摘录未收录这两个
    // 较新 key，值取自源侧生成层 submodules/TelegramApi/Sources/Api0.swift 的
    // dict[<decimal>] 注册表（parse_inputPrivacyKeySavedMusic / parse_inputPrivacyKeyStarGiftsAutoSave），
    // 十进制转十六进制核对过 KEY_ABOUT/KEY_BIRTHDAY 两个既有值同源可推导，方法一致：
    //   inputPrivacyKeySavedMusic       = 1304334886  = 0x4dbe9226
    //   inputPrivacyKeyStarGiftsAutoSave = -512548031 (mod 2^32) = 0xe1732341
    // 只用于 getPrivacyRules() 只读查询（account.getPrivacy 是读请求，不写账号），不涉及
    // setPrivacy 写路径——这两个新分类本轮暂不提供就地编辑入口（见 PrivacySettingsPage.cj
    // 交付说明），故未验证写路径的参数序列化，读路径的 keyConstructor 用法与既有 8 个
    // key 完全一致（同一 AccountGetPrivacy 请求结构），风险面小。
    public static let KEY_SAVED_MUSIC: UInt32 = 0x4dbe9226
    public static let KEY_STAR_GIFTS_AUTO_SAVE: UInt32 = 0xe1732341

    public static let RULE_ALLOW_ALL: UInt32 = 0x184b35ce
    public static let RULE_ALLOW_CONTACTS: UInt32 = 0x0d09e07b
    public static let RULE_DISALLOW_ALL: UInt32 = 0xd66b66c9
    public static let RULE_DISALLOW_CONTACTS: UInt32 = 0x0ba52007
    public static let RULE_ALLOW_USERS: UInt32 = 0x131cc67f
    public static let RULE_DISALLOW_USERS: UInt32 = 0x90110467
    public static let RULE_ALLOW_CHAT_PARTICIPANTS: UInt32 = 0x840649cf
    public static let RULE_DISALLOW_CHAT_PARTICIPANTS: UInt32 = 0xe94f0f86
    public static let RULE_ALLOW_CLOSE_FRIENDS: UInt32 = 0x2f453e49
    public static let RULE_ALLOW_PREMIUM: UInt32 = 0x77cdc9f1

    // ==================== Gap 1: accountPrivacySettings fetch ====================

    /**
     * Fetch full privacy rules for a key.
     * Returns a PrivacyRulesResponse with primaryValue + allowUsers/disallowUsers/chats lists.
     * iOS ref: TelegramCore Engine.Privacy.requestAccountPrivacySettings (Privacy.swift)
     */
    public func getPrivacyRules(keyConstructor: UInt32): PrivacyRulesResponse {
        try {
            let client = getMTProtoClient()
            let req = AccountGetPrivacy()
            req.keyConstructor = keyConstructor
            let data = client.sendRequest(req.toBytes())
            let rules = PrivacyRulesResponse.deserialize(data)
            this.storeCachedPrivacyRules(keyConstructor, rules)
            return rules
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] getPrivacyRules error: ${e}")
            return PrivacyRulesResponse()
        }
    }

    /** S7-85: the last parsed server rules for this key (from a get or a set), if any. */
    public func cachedPrivacyRules(keyConstructor: UInt32): Option<PrivacyRulesResponse> {
        let k = privacyRulesCacheKey(keyConstructor)
        var found: Option<PrivacyRulesResponse> = None
        synchronized(_privacyRulesCacheMutex) {
            found = _privacyRulesCache.get(k)
        }
        return found
    }

    /** Cached rules when present, otherwise account.getPrivacy. */
    public func getPrivacyRulesCachedFirst(keyConstructor: UInt32): PrivacyRulesResponse {
        match (this.cachedPrivacyRules(keyConstructor)) {
            case Some(r) => return r
            case None => return this.getPrivacyRules(keyConstructor)
        }
    }

    private func storeCachedPrivacyRules(keyConstructor: UInt32, rules: PrivacyRulesResponse): Unit {
        if (!rules.parsed) { return }
        let k = privacyRulesCacheKey(keyConstructor)
        synchronized(_privacyRulesCacheMutex) {
            _privacyRulesCache[k] = rules
        }
    }

    /**
     * Fetch simple privacy value ("everybody" | "contacts" | "nobody" | "close_friends" | "premium").
     * For backward compatibility with existing callers.
     */
    public func getPrivacy(keyConstructor: UInt32): String {
        let rules = this.getPrivacyRules(keyConstructor)
        return rules.primaryValue
    }

    // ==================== Gap 2: selective per-rule updates ====================

    /**
     * Set privacy to a simple value: "everybody" | "contacts" | "nobody".
     * iOS ref: TelegramCore Engine.Privacy.updateSelectiveAccountPrivacySettings.
     */
    public func setPrivacy(keyConstructor: UInt32, value: String): String {
        let req = AccountSetPrivacy()
        req.keyConstructor = keyConstructor
        req.ruleConstructors.add(this.valueToRuleCtor(value))
        return this.sendSetPrivacy(req, keyConstructor)
    }

    /**
     * Set privacy to "close_friends" — uses inputPrivacyValueAllowCloseFriends#2f453e49.
     * Combined with an optional disallow rule for non-close-friends.
     * iOS ref: selectivePrivacySettingsWithCloseFriends.
     */
    public func setPrivacyCloseFriends(keyConstructor: UInt32): String {
        let req = AccountSetPrivacy()
        req.keyConstructor = keyConstructor
        req.ruleConstructors.add(PrivacyEngineService.RULE_ALLOW_CLOSE_FRIENDS)
        req.ruleConstructors.add(PrivacyEngineService.RULE_DISALLOW_ALL)
        return this.sendSetPrivacy(req, keyConstructor)
    }

    /**
     * Set privacy to "premium_only" — uses inputPrivacyValueAllowPremium#77cdc9f1.
     * iOS ref: selectivePrivacySettingsWithPremium.
     */
    public func setPrivacyPremiumOnly(keyConstructor: UInt32): String {
        let req = AccountSetPrivacy()
        req.keyConstructor = keyConstructor
        req.ruleConstructors.add(PrivacyEngineService.RULE_ALLOW_PREMIUM)
        req.ruleConstructors.add(PrivacyEngineService.RULE_DISALLOW_ALL)
        return this.sendSetPrivacy(req, keyConstructor)
    }

    /**
     * Set privacy with explicit user (and, optionally, chat/group) exception lists.
     * baseValue: "everybody" | "contacts" | "nobody"
     * allowUserIds: additional users to allow (empty list = none)
     * disallowUserIds: users to disallow even if base allows (empty list = none)
     * allowChatIds!: additional chats/groups to allow (default empty = none; existing callers unaffected)
     * disallowChatIds!: chats/groups to disallow even if base allows (default empty = none)
     * iOS ref: TelegramCore SelectivePrivacySettings with allowedPeers/disallowedPeers;
     * rule emission order mirrors UpdatedAccountPrivacySettings.swift:566-590
     * (.enableContacts branch: allow users, allow chats, disallow users, disallow chats, base value).
     */
    public func setPrivacyWithUsers(keyConstructor: UInt32, baseValue: String,
                                    allowUserIds: ArrayList<Int64>, disallowUserIds: ArrayList<Int64>,
                                    allowChatIds!: ArrayList<Int64> = ArrayList<Int64>(),
                                    disallowChatIds!: ArrayList<Int64> = ArrayList<Int64>()): String {
        let req = AccountSetPrivacy()
        req.keyConstructor = keyConstructor
        if (allowUserIds.size > 0) {
            req.ruleConstructors.add(PrivacyEngineService.RULE_ALLOW_USERS)
            var i: Int64 = 0
            while (i < allowUserIds.size) {
                req.ruleUserIds.add(allowUserIds[i])
                i = i + 1
            }
        }
        if (allowChatIds.size > 0) {
            req.ruleConstructors.add(PrivacyEngineService.RULE_ALLOW_CHAT_PARTICIPANTS)
            var i: Int64 = 0
            while (i < allowChatIds.size) {
                req.ruleChatIds.add(allowChatIds[i])
                i = i + 1
            }
        }
        if (disallowUserIds.size > 0) {
            req.ruleConstructors.add(PrivacyEngineService.RULE_DISALLOW_USERS)
            var i: Int64 = 0
            while (i < disallowUserIds.size) {
                req.ruleDisallowUserIds.add(disallowUserIds[i])
                i = i + 1
            }
        }
        if (disallowChatIds.size > 0) {
            req.ruleConstructors.add(PrivacyEngineService.RULE_DISALLOW_CHAT_PARTICIPANTS)
            var i: Int64 = 0
            while (i < disallowChatIds.size) {
                req.ruleDisallowChatIds.add(disallowChatIds[i])
                i = i + 1
            }
        }
        req.ruleConstructors.add(this.valueToRuleCtor(baseValue))
        return this.sendSetPrivacy(req, keyConstructor)
    }

    private func sendSetPrivacy(req: AccountSetPrivacy, keyConstructor: UInt32): String {
        try {
            let client = getMTProtoClient()
            let data = client.sendRequest(req.toBytes())
            if (data.size >= 4) {
                let d = TLDeserializer(data)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR) {
                    let code = d.readInt32()
                    let msg = d.readString()
                    Hilog.info(0, "CjTelegram", "[PrivacyEngine] setPrivacy RPC error ${code}: ${msg}")
                } else {
                    Hilog.info(0, "CjTelegram", "[PrivacyEngine] setPrivacy success for key 0x${keyConstructor}")
                    // account.setPrivacy returns the new account.privacyRules: use it instead of
                    // a second account.getPrivacy (iOS applies the reply, no re-read).
                    let rules = PrivacyRulesResponse.deserialize(data)
                    if (rules.parsed) {
                        this.storeCachedPrivacyRules(keyConstructor, rules)
                        return rules.primaryValue
                    }
                }
            }
            return this.getPrivacy(keyConstructor)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] setPrivacy error: ${e}")
            return this.getPrivacy(keyConstructor)
        }
    }

    private func valueToRuleCtor(value: String): UInt32 {
        if (value == "everybody") { return PrivacyEngineService.RULE_ALLOW_ALL }
        if (value == "contacts") { return PrivacyEngineService.RULE_ALLOW_CONTACTS }
        return PrivacyEngineService.RULE_DISALLOW_ALL
    }

    // ==================== Gap 3: globalPrivacy ====================

    /**
     * Fetch global privacy settings.
     * account.getGlobalPrivacySettings#eb2b4cf6 → globalPrivacySettings#fe41b34f
     * iOS ref: TelegramCore Engine.Privacy.requestGlobalPrivacySettings.
     */
    public func getGlobalPrivacySettings(): GlobalPrivacySettingsResponse {
        try {
            let client = getMTProtoClient()
            let req = AccountGetGlobalPrivacySettings()
            let data = client.sendRequest(req.toBytes())
            let result = GlobalPrivacySettingsResponse.deserialize(data)
            let storage = getAuthStorage()
            storage.saveGlobalPrivacyCache(
                result.archiveAndMuteNewNoncontactPeers,
                result.keepArchivedUnmuted,
                result.hideReadMarks,
                result.newNoncontactPeersRequirePremium
            )
            return result
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] getGlobalPrivacySettings error: ${e}")
            let r = GlobalPrivacySettingsResponse()
            let storage = getAuthStorage()
            let (archiveMute, keepUnmuted, hideReads, requirePremium) = storage.getGlobalPrivacyCache()
            r.archiveAndMuteNewNoncontactPeers = archiveMute
            r.keepArchivedUnmuted = keepUnmuted
            r.hideReadMarks = hideReads
            r.newNoncontactPeersRequirePremium = requirePremium
            return r
        }
    }

    /**
     * Update global privacy settings.
     * account.setGlobalPrivacySettings#1edaaac2 settings:GlobalPrivacySettings → GlobalPrivacySettings
     * iOS ref: TelegramCore Engine.Privacy.updateGlobalPrivacySettings.
     */
    public func setGlobalPrivacySettings(
        archiveMute: Bool,
        keepUnmuted: Bool,
        keepFolders: Bool,
        hideReadMarks: Bool,
        requirePremium: Bool,
        displayGiftsButton: Bool
    ): GlobalPrivacySettingsResponse {
        try {
            let client = getMTProtoClient()
            let req = AccountSetGlobalPrivacySettings()
            req.settings.archiveAndMuteNewNoncontactPeers = archiveMute
            req.settings.keepArchivedUnmuted = keepUnmuted
            req.settings.keepArchivedFolders = keepFolders
            req.settings.hideReadMarks = hideReadMarks
            req.settings.newNoncontactPeersRequirePremium = requirePremium
            req.settings.displayGiftsButton = displayGiftsButton
            let data = client.sendRequest(req.toBytes())
            let result = GlobalPrivacySettingsResponse.deserialize(data)
            let storage = getAuthStorage()
            storage.saveGlobalPrivacyCache(
                result.archiveAndMuteNewNoncontactPeers,
                result.keepArchivedUnmuted,
                result.hideReadMarks,
                result.newNoncontactPeersRequirePremium
            )
            return result
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] setGlobalPrivacySettings error: ${e}")
            return this.getGlobalPrivacySettings()
        }
    }

    // ==================== Gap 4: closeFriends ====================

    /**
     * Set the close friends list by user IDs.
     * contacts.editCloseFriends#ba6705f0 id:Vector<long> = Bool
     * iOS ref: TelegramCore Engine.Contacts.updateCloseFriends.
     */
    public func editCloseFriends(userIds: ArrayList<Int64>): Bool {
        try {
            let client = getMTProtoClient()
            let req = ContactsEditCloseFriends()
            var i: Int64 = 0
            while (i < userIds.size) {
                req.id.add(userIds[i])
                i = i + 1
            }
            let data = client.sendRequest(req.toBytes())
            return this.parseBoolResponse(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] editCloseFriends error: ${e}")
            return false
        }
    }

    // ==================== Gap 5: activeSessions ====================

    /**
     * Fetch all active sessions.
     * account.getAuthorizations#e320c158 → account.authorizations#4bff8ea0
     * iOS ref: TelegramCore Engine.Sessions.requestSessionList (AccountAuthorization.swift).
     */
    public func getActiveSessions(): AccountAuthorizationsResponse {
        try {
            let client = getMTProtoClient()
            let req = AccountGetAuthorizations()
            let data = client.sendRequest(req.toBytes())
            return AccountAuthorizationsResponse.deserialize(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] getActiveSessions error: ${e}")
            return AccountAuthorizationsResponse()
        }
    }

    /**
     * Terminate a specific session by hash.
     * account.resetAuthorization#df77f3bc hash:long = Bool
     * iOS ref: TelegramCore Engine.Sessions.terminateOtherSession.
     */
    public func terminateSession(hash: Int64): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountResetAuthorization()
            req.hash = hash
            let data = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] terminateSession hash=${hash}")
            return this.parseBoolResponse(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] terminateSession error: ${e}")
            return false
        }
    }

    /**
     * Set the auto-terminate TTL for inactive sessions (in days).
     * account.setAuthorizationTTL#bf899aa0 authorization_ttl_days:int = Bool
     * iOS ref: TelegramCore Engine.Sessions.updateSessionIdleTimeout.
     */
    public func setSessionTtlDays(days: Int32): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountSetAuthorizationTTL()
            req.authorizationTtlDays = days
            let data = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] setSessionTtlDays days=${days}")
            return this.parseBoolResponse(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] setSessionTtlDays error: ${e}")
            return false
        }
    }

    /**
     * Change per-session settings (encrypted/call requests disabled).
     * account.changeAuthorizationSettings#40f48462
     *   flags:# confirmed:flags.3?true hash:long
     *   encrypted_requests_disabled:flags.0?Bool call_requests_disabled:flags.1?Bool = Bool
     * iOS ref: TelegramCore Engine.Sessions.updateAuthorizationSetting.
     *
     * setEncrypted / setCall: whether to include those optional Bool fields.
     * If setEncrypted is false, encryptedRequestsDisabled is ignored (flag not set).
     */
    public func changeSessionSettings(
        hash: Int64,
        confirmed: Bool,
        setEncrypted: Bool,
        encryptedRequestsDisabled: Bool,
        setCall: Bool,
        callRequestsDisabled: Bool
    ): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountChangeAuthorizationSettings()
            req.hash = hash
            req.confirmed = confirmed
            req.hasEncryptedRequestsDisabled = setEncrypted
            req.encryptedRequestsDisabled = encryptedRequestsDisabled
            req.hasCallRequestsDisabled = setCall
            req.callRequestsDisabled = callRequestsDisabled
            let data = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] changeSessionSettings hash=${hash} confirmed=${confirmed}")
            return this.parseBoolResponse(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] changeSessionSettings error: ${e}")
            return false
        }
    }

    // ==================== Gap 6: webSessions ====================

    /**
     * Fetch all web (bot) sessions.
     * account.getWebAuthorizations#182e6d6f → account.webAuthorizations#ed56c9fc
     * iOS ref: TelegramCore Engine.Sessions.requestWebSessions.
     */
    public func getWebSessions(): AccountWebAuthorizationsResponse {
        try {
            let client = getMTProtoClient()
            let req = AccountGetWebAuthorizations()
            let data = client.sendRequest(req.toBytes())
            return AccountWebAuthorizationsResponse.deserialize(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] getWebSessions error: ${e}")
            return AccountWebAuthorizationsResponse()
        }
    }

    /**
     * Terminate a specific web session by hash.
     * account.resetWebAuthorization#2d01b9ef hash:long = Bool
     * iOS ref: TelegramCore Engine.Sessions.removeWebSession.
     */
    public func terminateWebSession(hash: Int64): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountResetWebAuthorization()
            req.hash = hash
            let data = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] terminateWebSession hash=${hash}")
            return this.parseBoolResponse(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] terminateWebSession error: ${e}")
            return false
        }
    }

    /**
     * Terminate all web sessions at once.
     * account.resetWebAuthorizations#682d2594 = Bool
     * iOS ref: TelegramCore Engine.Sessions.removeAllWebSessions.
     */
    public func terminateAllWebSessions(): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountResetWebAuthorizations()
            let data = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] terminateAllWebSessions")
            return this.parseBoolResponse(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] terminateAllWebSessions error: ${e}")
            return false
        }
    }

    // ==================== Gap 7: newSessionReview ====================

    /**
     * Process an incoming updateNewAuthorization#8951abef update.
     * Returns Some(info) if the update is unconfirmed (user needs to review/confirm).
     * The caller should surface a notification and optionally call confirmSession(hash).
     * iOS ref: TelegramCore updateNewAuthorization handler in AccountSessionsController.swift.
     */
    public func processNewAuthorizationUpdate(updateData: Array<Byte>): Option<NewAuthorizationUpdate> {
        let result = deserializeNewAuthorizationUpdate(updateData)
        match (result) {
            case Some(info) =>
                if (info.isUnconfirmed) {
                    Hilog.info(0, "CjTelegram", "[PrivacyEngine] New unconfirmed session: device=${info.device} loc=${info.location}")
                } else {
                    Hilog.info(0, "CjTelegram", "[PrivacyEngine] New authorized session: hash=${info.hash}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[PrivacyEngine] processNewAuthorizationUpdate: not a newAuthorization update")
        }
        return result
    }

    /**
     * Confirm a new session (mark as reviewed by calling changeAuthorizationSettings with confirmed=true).
     * This dismisses the "new login" review notification for that session.
     * iOS ref: TelegramCore Engine.Sessions.confirmSession.
     */
    public func confirmSession(hash: Int64): Bool {
        return this.changeSessionSettings(hash, true, false, false, false, false)
    }

    // ==================== Gap 8: Account Self-Destruct TTL ====================

    /**
     * Get the account self-destruct period in days.
     * account.getAccountTTL#08fc711d = account.AccountDaysTTL
     * Response: account.daysTTL#b8d0afdf days:int
     * iOS ref: TelegramCore Engine.Account.requestAccountTTL (AccountPrivacy.swift).
     * ctor verified: iOS Api42.swift L353 appendInt32(150761757) -> 0x08fc711d
     */
    public func getAccountTtlDays(): Int32 {
        try {
            let client = getMTProtoClient()
            let req = AccountGetAccountTTL()
            let data = client.sendRequest(req.toBytes())
            return this.parseAccountDaysTTL(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] getAccountTtlDays error: ${e}")
            return 180
        }
    }

    /**
     * Set the account self-destruct period in days.
     * account.setAccountTTL#2442485e ttl:AccountDaysTTL = Bool
     * iOS ref: TelegramCore Engine.Account.updateAccountTTL (AccountPrivacy.swift).
     * ctor verified: iOS Api42.swift L1458 appendInt32(608323678) -> 0x2442485e
     */
    public func setAccountTtlDays(days: Int32): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountSetAccountTTL()
            req.days = days
            let data = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] setAccountTtlDays days=${days}")
            return this.parseBoolResponse(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] setAccountTtlDays error: ${e}")
            return false
        }
    }

    private func parseAccountDaysTTL(data: Array<Byte>): Int32 {
        if (data.size < 8) { return 180 }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == 0xb8d0afdf) {
            let days = d.readInt32()
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] accountTTL days=${days}")
            return days
        }
        Hilog.info(0, "CjTelegram", "[PrivacyEngine] parseAccountDaysTTL unexpected ctor: ${ctor}")
        return 180
    }

    // ==================== P2-330: Global Auto-Delete (messages.DefaultHistoryTTL) ====================

    /**
     * Fetch the global default message auto-delete period in seconds.
     * messages.getDefaultHistoryTTL#658b7188 → defaultHistoryTTL#43b46b20 period:int
     * period=0 means auto-delete is off.
     * iOS ref: ManagedConfigurationUpdates.swift — defaultHistoryTtl field.
     * ctor verified: python3 -c "print(hex(1703637384))" -> 0x658b7188
     */
    public func getDefaultHistoryTtlSeconds(): Int32 {
        try {
            let client = getMTProtoClient()
            let req = MessagesGetDefaultHistoryTTL()
            let data = client.sendRequest(req.toBytes())
            let resp = DefaultHistoryTTLResponse.deserialize(data)
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] getDefaultHistoryTtl period=${resp.period}")
            return resp.period
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] getDefaultHistoryTtl error: ${e}")
            return 0
        }
    }

    /**
     * Set the global default message auto-delete period in seconds.
     * messages.setDefaultHistoryTTL#9eb51445 period:int = Bool
     * period=0 disables auto-delete; use 86400 (1d), 604800 (1w), 2592000 (1mo).
     * iOS ref: ManagedConfigurationUpdates.swift — setDefaultHistoryTTL API call.
     * ctor verified: python3 -c "print(hex(-1632299963 & 0xFFFFFFFF))" -> 0x9eb51445
     */
    public func setDefaultHistoryTtlSeconds(period: Int32): Bool {
        try {
            let client = getMTProtoClient()
            let req = MessagesSetDefaultHistoryTTL()
            req.period = period
            let data = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] setDefaultHistoryTtl period=${period}")
            return this.parseBoolResponse(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] setDefaultHistoryTtl error: ${e}")
            return false
        }
    }

    // ==================== Gap 9: Passkeys ====================

    /**
     * Fetch all registered passkeys.
     * account.getPasskeys#ea1f0c52 = account.Passkeys
     * Response: account.passkeys#f8e0aa1c passkeys:Vector<Passkey>
     * iOS ref: Api42.swift L714 appendInt32(-367063982) -> 0xea1f0c52
     */
    public func getPasskeysList(): AccountPasskeysResponse {
        try {
            let client = getMTProtoClient()
            let req = AccountGetPasskeys()
            let data = client.sendRequest(req.toBytes())
            return AccountPasskeysResponse.deserialize(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] getPasskeysList error: ${e}")
            return AccountPasskeysResponse()
        }
    }

    /**
     * Delete a registered passkey by credential ID.
     * account.deletePasskey#f5b5563f id:string = Bool
     * iOS ref: Api42.swift L257 appendInt32(-172665281) -> 0xf5b5563f
     */
    public func deletePasskeyById(id: String): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountDeletePasskey()
            req.id = id
            let data = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] deletePasskeyById id=${id}")
            return this.parseBoolResponse(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] deletePasskeyById error: ${e}")
            return false
        }
    }

    // ==================== Legacy: block/unblock/getBlockedCount ====================

    public func blockPeer(userId: Int64, accessHash: Int64): Bool {
        try {
            let client = getMTProtoClient()
            let req = ContactsBlock()
            let peer = InputPeerUser()
            peer.userId = userId
            peer.accessHash = accessHash
            req.id = peer
            let data = client.sendRequest(req.toBytes())
            return this.parseBoolResponse(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] blockPeer error")
            return false
        }
    }

    public func unblockPeer(userId: Int64, accessHash: Int64): Bool {
        try {
            let client = getMTProtoClient()
            let req = ContactsUnblock()
            let peer = InputPeerUser()
            peer.userId = userId
            peer.accessHash = accessHash
            req.id = peer
            let data = client.sendRequest(req.toBytes())
            return this.parseBoolResponse(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] unblockPeer error")
            return false
        }
    }

    public func getBlockedCount(): Int32 {
        try {
            let client = getMTProtoClient()
            let req = ContactsGetBlocked()
            req.offset = 0
            req.limit = 1
            let data = client.sendRequest(req.toBytes())
            return this.parseBlockedCount(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PrivacyEngine] getBlockedCount error: ${e}")
            return 0
        }
    }

    // ==================== Private helpers ====================

    private func parseBoolResponse(data: Array<Byte>): Bool {
        if (data.size < 4) { return false }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        return ctor == 0x997275b5
    }

    private func parseBlockedCount(data: Array<Byte>): Int32 {
        if (data.size < 8) { return 0 }
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()
        if (constructor == 0xe1664194) {
            return d.readInt32()
        }
        if (constructor == 0x0ade1591) {
            let _ = d.readUInt32()
            return d.readInt32()
        }
        return 0
    }
}
