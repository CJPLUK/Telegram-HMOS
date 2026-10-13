package ohos_app_cangjie_entry.providers

import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * PrivacyRulesData — cached per-key privacy state (simple values for UI display)
 */
public struct PrivacyRulesData {
    public var phoneNumber: String = "everybody"
    public var lastSeen: String = "everybody"
    public var profilePhoto: String = "everybody"
    public var forwards: String = "everybody"
    public var groups: String = "everybody"
    public var calls: String = "everybody"
    public var voiceMessages: String = "everybody"
    public var about: String = "everybody"
    public var birthday: String = "everybody"
    public var blockedCount: Int32 = 0
}

/**
 * GlobalPrivacyData — mirrors GlobalPrivacySettingsResponse for UI layer
 */
public struct GlobalPrivacyData {
    public var archiveAndMuteNewNoncontactPeers: Bool = false
    public var keepArchivedUnmuted: Bool = false
    public var keepArchivedFolders: Bool = false
    public var hideReadMarks: Bool = false
    public var newNoncontactPeersRequirePremium: Bool = false
    public var displayGiftsButton: Bool = false
    public var noncontactPeersPaidStars: Int64 = 0
}

/**
 * PrivacyDataProvider — thin adapter between UI and PrivacyEngineService.
 *
 * Exposes:
 *   - loadAllPrivacySettings()      → PrivacyRulesData (all key simple values)
 *   - updatePrivacyRule(key, value) → String (confirmed value)
 *   - updatePrivacyRuleCloseFriends(key) → String
 *   - updatePrivacyRulePremiumOnly(key)  → String
 *   - updatePrivacyRuleWithUsers(key, base, allowIds, disallowIds) → String
 *   - getFullPrivacyRules(key)       → PrivacyRulesResponse (full detail)
 *   - loadGlobalPrivacy()            → GlobalPrivacyData
 *   - updateGlobalPrivacy(...)       → GlobalPrivacyData
 *   - editCloseFriends(userIds)      → Bool
 *   - loadActiveSessions()           → AccountAuthorizationsResponse
 *   - terminateSession(hash)         → Bool
 *   - setSessionTtlDays(days)        → Bool
 *   - changeSessionSettings(...)     → Bool
 *   - confirmSession(hash)           → Bool
 *   - loadWebSessions()              → AccountWebAuthorizationsResponse
 *   - terminateWebSession(hash)      → Bool
 *   - terminateAllWebSessions()      → Bool
 *   - processNewAuthorizationUpdate(data) → Option<NewAuthorizationUpdate>
 *   - blockUser/unblockUser/getPrivacyDisplayText/cyclePrivacy
 */
public class PrivacyDataProvider {
    private let service: PrivacyEngineService = getPrivacyEngineService()

    // ==================== Gap 1: accountPrivacySettings fetch ====================

    public func loadAllPrivacySettings(): PrivacyRulesData {
        var data = PrivacyRulesData()
        data.phoneNumber = this.service.getPrivacy(PrivacyEngineService.KEY_PHONE_NUMBER)
        data.lastSeen = this.service.getPrivacy(PrivacyEngineService.KEY_LAST_SEEN)
        data.profilePhoto = this.service.getPrivacy(PrivacyEngineService.KEY_PROFILE_PHOTO)
        data.forwards = this.service.getPrivacy(PrivacyEngineService.KEY_FORWARDS)
        data.groups = this.service.getPrivacy(PrivacyEngineService.KEY_GROUPS)
        data.calls = this.service.getPrivacy(PrivacyEngineService.KEY_CALLS)
        data.voiceMessages = this.service.getPrivacy(PrivacyEngineService.KEY_VOICE_MESSAGES)
        data.about = this.service.getPrivacy(PrivacyEngineService.KEY_ABOUT)
        data.birthday = this.service.getPrivacy(PrivacyEngineService.KEY_BIRTHDAY)
        data.blockedCount = this.service.getBlockedCount()
        return data
    }

    /**
     * Fetch full PrivacyRulesResponse (includes user/chat exception lists).
     */
    public func getFullPrivacyRules(keyConstructor: UInt32): PrivacyRulesResponse {
        return this.service.getPrivacyRules(keyConstructor)
    }

    // ==================== Gap 2: selective per-rule updates ====================

    /**
     * Update a single key to a simple value ("everybody" | "contacts" | "nobody").
     */
    public func updatePrivacyRule(keyConstructor: UInt32, value: String): String {
        return this.service.setPrivacy(keyConstructor, value)
    }

    /**
     * Update key to close-friends-only visibility.
     */
    public func updatePrivacyRuleCloseFriends(keyConstructor: UInt32): String {
        return this.service.setPrivacyCloseFriends(keyConstructor)
    }

    /**
     * Update key to premium-subscribers-only visibility.
     */
    public func updatePrivacyRulePremiumOnly(keyConstructor: UInt32): String {
        return this.service.setPrivacyPremiumOnly(keyConstructor)
    }

    /**
     * Update key with explicit user exception lists.
     */
    public func updatePrivacyRuleWithUsers(
        keyConstructor: UInt32,
        baseValue: String,
        allowUserIds: ArrayList<Int64>,
        disallowUserIds: ArrayList<Int64>
    ): String {
        return this.service.setPrivacyWithUsers(keyConstructor, baseValue, allowUserIds, disallowUserIds)
    }

    // ==================== Gap 3: globalPrivacy ====================

    public func loadGlobalPrivacy(): GlobalPrivacyData {
        let resp = this.service.getGlobalPrivacySettings()
        var d = GlobalPrivacyData()
        d.archiveAndMuteNewNoncontactPeers = resp.archiveAndMuteNewNoncontactPeers
        d.keepArchivedUnmuted = resp.keepArchivedUnmuted
        d.keepArchivedFolders = resp.keepArchivedFolders
        d.hideReadMarks = resp.hideReadMarks
        d.newNoncontactPeersRequirePremium = resp.newNoncontactPeersRequirePremium
        d.displayGiftsButton = resp.displayGiftsButton
        d.noncontactPeersPaidStars = resp.noncontactPeersPaidStars
        return d
    }

    public func updateGlobalPrivacy(
        archiveMute: Bool,
        keepUnmuted: Bool,
        keepFolders: Bool,
        hideReadMarks: Bool,
        requirePremium: Bool,
        displayGiftsButton: Bool
    ): GlobalPrivacyData {
        let resp = this.service.setGlobalPrivacySettings(
            archiveMute, keepUnmuted, keepFolders, hideReadMarks, requirePremium, displayGiftsButton
        )
        var d = GlobalPrivacyData()
        d.archiveAndMuteNewNoncontactPeers = resp.archiveAndMuteNewNoncontactPeers
        d.keepArchivedUnmuted = resp.keepArchivedUnmuted
        d.keepArchivedFolders = resp.keepArchivedFolders
        d.hideReadMarks = resp.hideReadMarks
        d.newNoncontactPeersRequirePremium = resp.newNoncontactPeersRequirePremium
        d.displayGiftsButton = resp.displayGiftsButton
        d.noncontactPeersPaidStars = resp.noncontactPeersPaidStars
        return d
    }

    // ==================== Gap 4: closeFriends ====================

    public func editCloseFriends(userIds: ArrayList<Int64>): Bool {
        return this.service.editCloseFriends(userIds)
    }

    // ==================== Gap 5: activeSessions ====================

    public func loadActiveSessions(): AccountAuthorizationsResponse {
        return this.service.getActiveSessions()
    }

    public func terminateSession(hash: Int64): Bool {
        return this.service.terminateSession(hash)
    }

    public func setSessionTtlDays(days: Int32): Bool {
        return this.service.setSessionTtlDays(days)
    }

    public func changeSessionSettings(
        hash: Int64,
        confirmed: Bool,
        setEncrypted: Bool,
        encryptedRequestsDisabled: Bool,
        setCall: Bool,
        callRequestsDisabled: Bool
    ): Bool {
        return this.service.changeSessionSettings(hash, confirmed, setEncrypted, encryptedRequestsDisabled, setCall, callRequestsDisabled)
    }

    public func confirmSession(hash: Int64): Bool {
        return this.service.confirmSession(hash)
    }

    // ==================== Gap 6: webSessions ====================

    public func loadWebSessions(): AccountWebAuthorizationsResponse {
        return this.service.getWebSessions()
    }

    public func terminateWebSession(hash: Int64): Bool {
        return this.service.terminateWebSession(hash)
    }

    public func terminateAllWebSessions(): Bool {
        return this.service.terminateAllWebSessions()
    }

    // ==================== Gap 7: newSessionReview ====================

    public func processNewAuthorizationUpdate(updateData: Array<Byte>): Option<NewAuthorizationUpdate> {
        return this.service.processNewAuthorizationUpdate(updateData)
    }

    // ==================== Legacy: block/unblock ====================

    public func blockUser(userId: Int64, accessHash: Int64): Bool {
        return this.service.blockPeer(userId, accessHash)
    }

    public func unblockUser(userId: Int64, accessHash: Int64): Bool {
        return this.service.unblockPeer(userId, accessHash)
    }

    // ==================== UI helpers ====================

    public func getPrivacyDisplayText(value: String): String {
        if (value == "everybody") { return "Everybody" }
        if (value == "contacts") { return "My Contacts" }
        if (value == "nobody") { return "Nobody" }
        if (value == "close_friends") { return "Close Friends" }
        if (value == "premium") { return "Premium Users" }
        return value
    }

    public func cyclePrivacy(current: String): String {
        if (current == "everybody") { return "contacts" }
        if (current == "contacts") { return "nobody" }
        return "everybody"
    }
}
