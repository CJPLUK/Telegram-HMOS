package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    HelpGetPromoData,
    HelpDismissSuggestion,
    InputPeerEmpty,
    InputPeerUser,
    InputPeerChannel,
    HelpPromoDataResponse,
    TLConstructors,
    TLDeserializer
}
import std.collection.{ArrayList, HashMap}
import std.convert.*

// ==========================================
// ApplicationSpecificGlobalNotice constants
// Mirrors iOS TelegramNotices/Sources/Notices.swift ApplicationSpecificGlobalNotice enum
// rawValue = Int64 storage key suffix for globalNamespace (ns=2)
// ==========================================

/**
 * ApplicationSpecificGlobalNotice — global notice key constants
 * Maps 1:1 to iOS ApplicationSpecificGlobalNotice enum rawValues.
 * Used as suffix in ItemCacheService key "glo_<rawValue>".
 */
public class ApplicationSpecificGlobalNotice {
    public static let secretChatInlineBotUsage: Int64 = 0
    public static let secretChatLinkPreviews: Int64 = 1
    public static let proxyAdsAcknowledgment: Int64 = 2
    public static let chatMediaMediaRecordingTips: Int64 = 3
    public static let profileCallTips: Int64 = 4
    public static let setPublicChannelLink: Int64 = 5
    public static let passcodeLockTips: Int64 = 6
    public static let contactsPermissionWarning: Int64 = 7
    public static let notificationsPermissionWarning: Int64 = 8
    public static let volumeButtonToUnmuteTip: Int64 = 9
    public static let archiveChatTips: Int64 = 10
    public static let archiveIntroDismissed: Int64 = 11
    public static let cellularDataPermissionWarning: Int64 = 13
    public static let chatMessageSearchResultsTip: Int64 = 14
    public static let chatMessageOptionsTip: Int64 = 15
    public static let chatTextSelectionTip: Int64 = 16
    public static let themeChangeTip: Int64 = 17
    public static let callsTabTip: Int64 = 18
    public static let chatFolderTips: Int64 = 19
    public static let locationProximityAlertTip: Int64 = 20
    public static let nextChatSuggestionTip: Int64 = 21
    public static let dismissedTrendingStickerPacks: Int64 = 22
    public static let chatForwardOptionsTip: Int64 = 24
    public static let messageViewsPrivacyTips: Int64 = 25
    public static let chatSpecificThemeLightPreviewTip: Int64 = 26
    public static let chatSpecificThemeDarkPreviewTip: Int64 = 27
    public static let interactiveEmojiSyncTip: Int64 = 28
    public static let sharedMediaScrollingTooltip: Int64 = 29
    public static let sharedMediaFastScrollingTooltip: Int64 = 30
    public static let forcedPasswordSetup: Int64 = 31
    public static let emojiTooltip: Int64 = 32
    public static let audioTranscriptionSuggestion: Int64 = 33
    public static let clearStorageDismissedTipSize: Int64 = 34
    public static let dismissedTrendingEmojiPacks: Int64 = 35
    public static let audioRateOptionsTip: Int64 = 36
    public static let translationSuggestion: Int64 = 37
    public static let sendWhenOnlineTip: Int64 = 38
    public static let chatWallpaperLightPreviewTip: Int64 = 39
    public static let chatWallpaperDarkPreviewTip: Int64 = 40
    public static let displayChatListContacts: Int64 = 41
    public static let displayChatListStoriesTooltip: Int64 = 42
    public static let storiesCameraTooltip: Int64 = 43
    public static let storiesDualCameraTooltip: Int64 = 44
    public static let displayChatListArchiveTooltip: Int64 = 45
    public static let displayStoryReactionTooltip: Int64 = 46
    public static let storyStealthModeReplyCount: Int64 = 47
    public static let viewOnceTooltip: Int64 = 48
    public static let displayStoryUnmuteTooltip: Int64 = 49
    public static let chatReplyOptionsTip: Int64 = 50
    public static let displayStoryInteractionGuide: Int64 = 51
    public static let replyQuoteTextSelectionTip: Int64 = 53
    public static let multipleReactionsSuggestion: Int64 = 56
    public static let savedMessagesChatsSuggestion: Int64 = 57
    public static let voiceMessagesPlayOnceSuggestion: Int64 = 58
    public static let incomingVoiceMessagePlayOnceTip: Int64 = 59
    public static let outgoingVoiceMessagePlayOnceTip: Int64 = 60
    public static let videoMessagesPlayOnceSuggestion: Int64 = 61
    public static let incomingVideoMessagePlayOnceTip: Int64 = 62
    public static let outgoingVideoMessagePlayOnceTip: Int64 = 63
    public static let savedMessageTagLabelSuggestion: Int64 = 65
    public static let monetizationIntroDismissed: Int64 = 70
    public static let businessBotMessageTooltip: Int64 = 71
    public static let captionAboveMediaTooltip: Int64 = 75
    public static let channelSendGiftTooltip: Int64 = 76
    public static let starGiftWearTips: Int64 = 77
    public static let channelSuggestTooltip: Int64 = 78
    public static let multipleStoriesTooltip: Int64 = 79
    public static let voiceMessagesPauseSuggestion: Int64 = 80
    public static let videoMessagesPauseSuggestion: Int64 = 81
    public static let voiceMessagesResumeTrimWarning: Int64 = 82
    public static let globalPostsSearch: Int64 = 83
    public static let giftAuctionTips: Int64 = 84
    public static let giftCraftingTips: Int64 = 85
    public static let copyProtectionTips: Int64 = 86
    public static let aiTextProcessingStyleSelectionTips: Int64 = 87
    public static let savedMessagesChatListView: Int64 = 88
    public static let guestChatMessageTooltip: Int64 = 89
}

// ==========================================
// Namespace constants (iOS ApplicationSpecificNoticeKeys)
// ==========================================
private let noticeNsGlobal: Int64 = 2
private let noticeNsPermissions: Int64 = 3
private let noticeNsPeerReport: Int64 = 4
private let noticeNsInlineBotLocation: Int64 = 5
private let noticeNsPsaAck: Int64 = 6
private let noticeNsBotGame: Int64 = 7
private let noticeNsPeerInviteRequests: Int64 = 8
private let noticeNsDismissedPremiumGift: Int64 = 9
private let noticeNsGroupEmojiPack: Int64 = 9
private let noticeNsBotPayment: Int64 = 1
private let noticeNsDismissedBirthdayPremiumGiftTip: Int64 = 10
private let noticeNsDisplayedPeerVerification: Int64 = 11
private let noticeNsDismissedPaidMessageWarning: Int64 = 11

// ==========================================
// Key construction helpers
// ==========================================

// Global key: "glo_<rawValue>"
private func globalNoticeKey(rawValue: Int64): String {
    return "glo_${rawValue}"
}

// Per-peer key with sub-key (usually 0): "peer_<ns>_<peerId>_<subKey>"
private func peerNoticeKey(ns: Int64, peerId: Int64, subKey: Int64): String {
    return "peer_${ns}_${peerId}_${subKey}"
}

// ==========================================
// Storage value encoding/decoding helpers
// ==========================================

// Bool notice: "1" = seen, absent = not seen
private func encodeBool(): String { return "1" }

// Counter notice: store as decimal string
private func encodeCounter(value: Int64): String { return value.toString() }
private func decodeCounter(s: String): Int64 {
    try {
        return Int64.parse(s)
    } catch (_: Exception) {
        return 0
    }
}

// Variant notice (bool with explicit value): "1" or "0"
private func encodeVariant(value: Bool): String {
    if (value) { return "1" }
    return "0"
}
private func decodeVariant(s: String): Bool { return s == "1" }

// Timestamp notice: store timestamp as decimal string
private func encodeTimestamp(value: Int64): String { return value.toString() }
private func decodeTimestamp(s: String): Int64 {
    try {
        return Int64.parse(s)
    } catch (_: Exception) {
        return 0
    }
}

// TimestampAndCounter: JSON {"v":counter,"t":timestamp}
private func encodeTimestampAndCounter(counter: Int64, timestamp: Int64): String {
    return "{\"v\":${counter},\"t\":${timestamp}}"
}
private func decodeTimestampAndCounter(s: String): (Int64, Int64) {
    let obj = JsonParser.parseObject(s)
    let counter = obj.getInt("v")
    let timestamp = obj.getInt("t")
    return (counter, timestamp)
}

// Int64 array: JSON {"v":[1,2,3]}
private func encodeInt64Array(values: ArrayList<Int64>): String {
    var arrStr = "["
    var first = true
    for (v in values) {
        if (!first) { arrStr += "," }
        arrStr += v.toString()
        first = false
    }
    arrStr += "]"
    return "{\"v\":${arrStr}}"
}
private func decodeInt64Array(s: String): ArrayList<Int64> {
    let result = ArrayList<Int64>()
    let obj = JsonParser.parseObject(s)
    let arr = obj.getArray("v")
    var i: Int64 = 0
    while (i < arr.size()) {
        let v = arr.getInt(i)
        result.add(v)
        i = i + 1
    }
    return result
}

// ==========================================
// NoticesService — main service class
// ==========================================

/**
 * NoticesService — 服务器建议/提示服务 + 本地 notice 入口
 *
 * 对应 iOS TelegramEngine.Notices:
 *   - set<T>(id:, item:)                            → setNoticeEntry / getNoticeEntry
 *   - getServerProvidedSuggestions                  → getPromoData (existing)
 *   - dismissServerProvidedSuggestion               → dismissSuggestion (existing)
 *   - getPeerSpecificServerProvidedSuggestions      → getPeerSpecificSuggestions (new)
 *   - dismissPeerSpecificServerProvidedSuggestion   → dismissPeerSuggestion (new)
 *
 * TL 构造器核对（已对照 telegram_api.tl + iOS Api42.swift）:
 *   help.getPromoData#c0977421     — iOS appendInt32(-1063816159) = 0xC0977421 [OK]
 *   help.dismissSuggestion#f50dbaa1 — iOS appendInt32(-183649631) = 0xF50DBAA1 [OK]
 *   Bool true: 0x997275b5, Bool false: 0xbc799737
 *   RPC error: 0x2144ca19
 *
 * 本地缓存:
 *   已 dismiss 的全局建议 ID 列表 → ItemCacheService key "notices_dismissed_ids"
 *   已 dismiss 的 peer 建议列表   → ItemCacheService key "notices_peer_dismissed_<peerId>"
 *   通用 notice 入口 (bool/counter/ts) → ItemCacheService key "notice_entry_<key>"
 *   ApplicationSpecificGlobalNotice → ItemCacheService key "glo_<rawValue>"
 *   Per-peer notices → ItemCacheService key "peer_<ns>_<peerId>_<subKey>"
 *   所有键均在 ItemCacheService (telegram_item_cache) 中持久化；
 *   登出清理通过 emitted_integration_contract ic_notices_logout_clear 注入 AuthStorage.clearAll.
 */
public func getNoticesService(): NoticesService {
    return NoticesService()
}

public class NoticesService {
    /**
     * 获取服务器建议数据（pending_suggestions, dismissed_suggestions）
     * 对应 iOS _internal_getServerProvidedSuggestions / help.getPromoData
     */
    public func getPromoData(): HelpPromoDataResponse {
        try {
            let client = getMTProtoClient()
            let req = HelpGetPromoData()
            let data = client.sendRequest(req.toBytes())
            return HelpPromoDataResponse.deserialize(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[NoticesService] getPromoData exception: ${e}")
            return HelpPromoDataResponse()
        }
    }

    /**
     * 全局建议 dismiss（peer = InputPeerEmpty）
     * 对应 iOS _internal_dismissServerProvidedSuggestion
     * TL: help.dismissSuggestion#f50dbaa1 peer:InputPeer suggestion:string = Bool
     * 外层响应: Bool (boolTrue#997275b5 / boolFalse#bc799737 / rpc_error#2144ca19)
     */
    public func dismissSuggestion(suggestion: String): Bool {
        try {
            let client = getMTProtoClient()
            let req = HelpDismissSuggestion()
            req.peer = InputPeerEmpty()
            req.suggestion = suggestion
            let data = client.sendRequest(req.toBytes())
            if (data.size >= 4) {
                let d = TLDeserializer(data)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.BOOL_TRUE || ctor == 0x997275b5) { return true }
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let _ = d.readInt32()
                    let msg = d.readString()
                    Hilog.info(0, "CjTelegram", "[NoticesService] dismissSuggestion RPC error: ${msg}")
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[NoticesService] dismissSuggestion exception: ${e}")
        }
        return false
    }

    /**
     * Peer 维度建议 dismiss（channel / group）
     * 对应 iOS _internal_dismissPeerSpecificServerProvidedSuggestion
     * TL: help.dismissSuggestion#f50dbaa1 peer:InputPeer suggestion:string = Bool
     *
     * peerType: "channel" | "group" | "user"
     * 对 channel/megagroup 使用 InputPeerChannel；对 user 使用 InputPeerUser。
     * 成功后在本地缓存中记录，避免下次重复展示（Postbox 已在 iOS 端更新 pendingSuggestions，
     * Cangjie 无 Postbox，用 ItemCacheService 本地记录替代）。
     */
    public func dismissPeerSuggestion(peerId: Int64, peerType: String, accessHash: Int64, suggestion: String): Bool {
        var serverOk: Bool = false
        try {
            let client = getMTProtoClient()
            let req = HelpDismissSuggestion()
            if (peerType == "user") {
                let p = InputPeerUser()
                p.userId = peerId
                p.accessHash = accessHash
                req.peer = p
            } else {
                let p = InputPeerChannel()
                p.channelId = peerId
                p.accessHash = accessHash
                req.peer = p
            }
            req.suggestion = suggestion
            let data = client.sendRequest(req.toBytes())
            if (data.size >= 4) {
                let d = TLDeserializer(data)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.BOOL_TRUE || ctor == 0x997275b5) { serverOk = true }
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let _ = d.readInt32()
                    let msg = d.readString()
                    Hilog.info(0, "CjTelegram", "[NoticesService] dismissPeerSuggestion RPC error: ${msg}")
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[NoticesService] dismissPeerSuggestion exception: ${e}")
        }
        this.addLocalPeerDismissedSuggestion(peerId, suggestion)
        Hilog.info(0, "CjTelegram", "[NoticesService] dismissPeerSuggestion peerId=${peerId} suggestion=${suggestion} serverOk=${serverOk}")
        return serverOk
    }

    /**
     * 获取 peer 维度的待处理建议（本地缓存优先）
     * 对应 iOS _internal_getPeerSpecificServerProvidedSuggestions
     * iOS 从 CachedChannelData.pendingSuggestions 读取；Cangjie 无 Postbox，
     * 使用 ItemCacheService key "notices_peer_suggestions_<peerId>" 存储服务器返回的值，
     * 过滤掉本地已 dismiss 的条目后返回。
     */
    public func getPeerSpecificSuggestions(peerId: Int64): ArrayList<String> {
        let allSuggestions = this.loadPeerSuggestionsFromCache(peerId)
        let dismissed = this.loadPeerDismissedSuggestions(peerId)
        let dismissedMap = HashMap<String, Bool>()
        for (s in dismissed) { dismissedMap[s] = true }
        let result = ArrayList<String>()
        for (s in allSuggestions) {
            if (!dismissedMap.contains(s)) {
                result.add(s)
            }
        }
        return result
    }

    /**
     * 更新 peer 维度建议缓存（由上层在收到 FullChannel/FullChat 后调用）
     * 对应 iOS CachedChannelData.pendingSuggestions 的写路径（来自 channels.getFullChannel 响应）
     */
    public func setPeerSpecificSuggestions(peerId: Int64, suggestions: ArrayList<String>): Unit {
        let cache = getTelegramEngineItemCacheService()
        let key = "notices_peer_suggestions_${peerId}"
        let obj = JsonObject()
        let arr = JsonArray()
        for (s in suggestions) { arr.addString(s) }
        obj.setArray("ids", arr)
        cache.put(key, JsonParser.stringify(obj))
        Hilog.info(0, "CjTelegram", "[NoticesService] setPeerSpecificSuggestions peerId=${peerId} count=${suggestions.size}")
    }

    /**
     * 通用 notice 入口写入（对应 iOS TelegramEngine.Notices.set<T>(id:, item:)）
     * 在 iOS 中 item 是 Codable；Cangjie 层以 String（序列化后）存储于 ItemCacheService。
     * key 格式: "notice_entry_<namespace>_<entryKey>"（由调用方自行构造以匹配 iOS NoticeEntryKey）
     * value: 序列化的 notice 值；传空字符串表示删除（对应 iOS 传 nil）
     */
    public func setNoticeEntry(key: String, value: String): Unit {
        let cache = getTelegramEngineItemCacheService()
        let storageKey = "notice_entry_${key}"
        if (value.size == 0) {
            cache.remove(storageKey)
            Hilog.info(0, "CjTelegram", "[NoticesService] setNoticeEntry removed key=${key}")
        } else {
            cache.put(storageKey, value)
            Hilog.info(0, "CjTelegram", "[NoticesService] setNoticeEntry key=${key} value_len=${value.size}")
        }
    }

    /**
     * 通用 notice 入口读取（对应 iOS NoticeTable.get(key:)）
     */
    public func getNoticeEntry(key: String): Option<String> {
        let cache = getTelegramEngineItemCacheService()
        let storageKey = "notice_entry_${key}"
        return cache.get(storageKey)
    }

    // ==========================================
    // ApplicationSpecificNotice — Global bool notices
    // "glo_<rawValue>" key, value "1" = seen
    // ==========================================

    /**
     * secretChatInlineBotUsage (raw=0) — Bool
     * iOS: getSecretChatInlineBotUsage / setSecretChatInlineBotUsage
     */
    public func getSecretChatInlineBotUsage(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.secretChatInlineBotUsage)
    }
    public func setSecretChatInlineBotUsage(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.secretChatInlineBotUsage)
    }

    /**
     * archiveIntroDismissed (raw=11) — Variant(Bool)
     * iOS: setArchiveIntroDismissed(value:Bool) / archiveIntroDismissedKey()
     */
    public func getArchiveIntroDismissed(): Option<Bool> {
        return this.readGlobalVariant(ApplicationSpecificGlobalNotice.archiveIntroDismissed)
    }
    public func setArchiveIntroDismissed(value: Bool): Unit {
        this.writeGlobalVariant(ApplicationSpecificGlobalNotice.archiveIntroDismissed, value)
    }

    /**
     * secretChatLinkPreviews (raw=1) — Variant(Bool)
     * iOS: getSecretChatLinkPreviews / setSecretChatLinkPreviews(value:Bool)
     */
    public func getSecretChatLinkPreviews(): Option<Bool> {
        return this.readGlobalVariant(ApplicationSpecificGlobalNotice.secretChatLinkPreviews)
    }
    public func setSecretChatLinkPreviews(value: Bool): Unit {
        this.writeGlobalVariant(ApplicationSpecificGlobalNotice.secretChatLinkPreviews, value)
    }

    /**
     * proxyAdsAcknowledgment (raw=2) — Bool
     */
    public func getProxyAdsAcknowledgment(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.proxyAdsAcknowledgment)
    }
    public func setProxyAdsAcknowledgment(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.proxyAdsAcknowledgment)
    }

    /**
     * passcodeLockTips (raw=6) — Bool
     */
    public func getPasscodeLockTips(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.passcodeLockTips)
    }
    public func setPasscodeLockTips(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.passcodeLockTips)
    }

    /**
     * themeChangeTip (raw=17) — Bool
     */
    public func getThemeChangeTip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.themeChangeTip)
    }
    public func markThemeChangeTipAsSeen(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.themeChangeTip)
    }

    /**
     * volumeButtonToUnmuteTip (raw=9) — Bool
     */
    public func getVolumeButtonToUnmute(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.volumeButtonToUnmuteTip)
    }
    public func setVolumeButtonToUnmute(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.volumeButtonToUnmuteTip)
    }

    /**
     * monetizationIntroDismissed (raw=70) — Bool
     */
    public func getMonetizationIntroDismissed(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.monetizationIntroDismissed)
    }
    public func setMonetizationIntroDismissed(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.monetizationIntroDismissed)
    }

    /**
     * businessBotMessageTooltip (raw=71) — Bool
     */
    public func getBusinessBotMessageTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.businessBotMessageTooltip)
    }
    public func setBusinessBotMessageTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.businessBotMessageTooltip)
    }

    /**
     * captionAboveMediaTooltip (raw=75) — Bool
     */
    public func getCaptionAboveMediaTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.captionAboveMediaTooltip)
    }
    public func setCaptionAboveMediaTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.captionAboveMediaTooltip)
    }

    /**
     * channelSendGiftTooltip (raw=76) — Bool
     */
    public func getChannelSendGiftTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.channelSendGiftTooltip)
    }
    public func setChannelSendGiftTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.channelSendGiftTooltip)
    }

    /**
     * starGiftWearTips (raw=77) — Bool
     */
    public func getStarGiftWearTips(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.starGiftWearTips)
    }
    public func setStarGiftWearTips(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.starGiftWearTips)
    }

    /**
     * channelSuggestTooltip (raw=78) — Bool
     */
    public func getChannelSuggestTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.channelSuggestTooltip)
    }
    public func setChannelSuggestTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.channelSuggestTooltip)
    }

    /**
     * multipleStoriesTooltip (raw=79) — Bool
     */
    public func getMultipleStoriesTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.multipleStoriesTooltip)
    }
    public func setMultipleStoriesTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.multipleStoriesTooltip)
    }

    /**
     * viewOnceTooltip (raw=48) — Bool
     */
    public func getViewOnceTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.viewOnceTooltip)
    }
    public func setViewOnceTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.viewOnceTooltip)
    }

    /**
     * displayChatListContacts (raw=41) — Bool
     */
    public func getDisplayChatListContacts(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.displayChatListContacts)
    }
    public func setDisplayChatListContacts(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.displayChatListContacts)
    }

    /**
     * displayChatListStoriesTooltip (raw=42) — Bool
     */
    public func getDisplayChatListStoriesTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.displayChatListStoriesTooltip)
    }
    public func setDisplayChatListStoriesTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.displayChatListStoriesTooltip)
    }

    /**
     * storiesCameraTooltip (raw=43) — Bool
     */
    public func getStoriesCameraTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.storiesCameraTooltip)
    }
    public func setStoriesCameraTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.storiesCameraTooltip)
    }

    /**
     * storiesDualCameraTooltip (raw=44) — Bool
     */
    public func getStoriesDualCameraTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.storiesDualCameraTooltip)
    }
    public func setStoriesDualCameraTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.storiesDualCameraTooltip)
    }

    /**
     * displayChatListArchiveTooltip (raw=45) — Bool
     */
    public func getDisplayChatListArchiveTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.displayChatListArchiveTooltip)
    }
    public func setDisplayChatListArchiveTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.displayChatListArchiveTooltip)
    }

    /**
     * displayStoryReactionTooltip (raw=46) — Bool
     */
    public func getDisplayStoryReactionTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.displayStoryReactionTooltip)
    }
    public func setDisplayStoryReactionTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.displayStoryReactionTooltip)
    }

    /**
     * displayStoryUnmuteTooltip (raw=49) — Bool
     */
    public func getDisplayStoryUnmuteTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.displayStoryUnmuteTooltip)
    }
    public func setDisplayStoryUnmuteTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.displayStoryUnmuteTooltip)
    }

    /**
     * displayStoryInteractionGuide (raw=51) — Bool
     */
    public func getDisplayStoryInteractionGuide(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.displayStoryInteractionGuide)
    }
    public func setDisplayStoryInteractionGuide(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.displayStoryInteractionGuide)
    }

    /**
     * multipleReactionsSuggestion (raw=56) — Bool
     */
    public func getMultipleReactionsSuggestion(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.multipleReactionsSuggestion)
    }
    public func setMultipleReactionsSuggestion(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.multipleReactionsSuggestion)
    }

    /**
     * savedMessagesChatsSuggestion (raw=57) — Bool
     */
    public func getSavedMessagesChatsSuggestion(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.savedMessagesChatsSuggestion)
    }
    public func setSavedMessagesChatsSuggestion(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.savedMessagesChatsSuggestion)
    }

    /**
     * voiceMessagesPlayOnceSuggestion (raw=58) — Bool
     */
    public func getVoiceMessagesPlayOnceSuggestion(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.voiceMessagesPlayOnceSuggestion)
    }
    public func setVoiceMessagesPlayOnceSuggestion(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.voiceMessagesPlayOnceSuggestion)
    }

    /**
     * videoMessagesPlayOnceSuggestion (raw=61) — Bool
     */
    public func getVideoMessagesPlayOnceSuggestion(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.videoMessagesPlayOnceSuggestion)
    }
    public func setVideoMessagesPlayOnceSuggestion(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.videoMessagesPlayOnceSuggestion)
    }

    /**
     * savedMessageTagLabelSuggestion (raw=65) — Bool
     */
    public func getSavedMessageTagLabelSuggestion(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.savedMessageTagLabelSuggestion)
    }
    public func setSavedMessageTagLabelSuggestion(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.savedMessageTagLabelSuggestion)
    }

    /**
     * voiceMessagesPauseSuggestion (raw=80) — Bool
     */
    public func getVoiceMessagesPauseSuggestion(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.voiceMessagesPauseSuggestion)
    }
    public func setVoiceMessagesPauseSuggestion(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.voiceMessagesPauseSuggestion)
    }

    /**
     * videoMessagesPauseSuggestion (raw=81) — Bool
     */
    public func getVideoMessagesPauseSuggestion(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.videoMessagesPauseSuggestion)
    }
    public func setVideoMessagesPauseSuggestion(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.videoMessagesPauseSuggestion)
    }

    /**
     * voiceMessagesResumeTrimWarning (raw=82) — Bool
     */
    public func getVoiceMessagesResumeTrimWarning(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.voiceMessagesResumeTrimWarning)
    }
    public func setVoiceMessagesResumeTrimWarning(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.voiceMessagesResumeTrimWarning)
    }

    /**
     * globalPostsSearch (raw=83) — Bool
     */
    public func getGlobalPostsSearch(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.globalPostsSearch)
    }
    public func setGlobalPostsSearch(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.globalPostsSearch)
    }

    /**
     * giftAuctionTips (raw=84) — Bool
     */
    public func getGiftAuctionTips(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.giftAuctionTips)
    }
    public func setGiftAuctionTips(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.giftAuctionTips)
    }

    /**
     * giftCraftingTips (raw=85) — Bool
     */
    public func getGiftCraftingTips(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.giftCraftingTips)
    }
    public func setGiftCraftingTips(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.giftCraftingTips)
    }

    /**
     * copyProtectionTips (raw=86) — Bool
     */
    public func getCopyProtectionTips(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.copyProtectionTips)
    }
    public func setCopyProtectionTips(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.copyProtectionTips)
    }

    /**
     * aiTextProcessingStyleSelectionTips (raw=87) — Bool
     */
    public func getAiTextProcessingStyleSelectionTips(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.aiTextProcessingStyleSelectionTips)
    }
    public func setAiTextProcessingStyleSelectionTips(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.aiTextProcessingStyleSelectionTips)
    }

    /**
     * savedMessagesChatListView (raw=88) — Bool
     */
    public func getSavedMessagesChatListView(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.savedMessagesChatListView)
    }
    public func setSavedMessagesChatListView(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.savedMessagesChatListView)
    }

    /**
     * guestChatMessageTooltip (raw=89) — Bool
     */
    public func getGuestChatMessageTooltip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.guestChatMessageTooltip)
    }
    public func setGuestChatMessageTooltip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.guestChatMessageTooltip)
    }

    /**
     * sendWhenOnlineTip (raw=38) — Bool
     */
    public func getSendWhenOnlineTip(): Bool {
        return this.readGlobalBool(ApplicationSpecificGlobalNotice.sendWhenOnlineTip)
    }
    public func setSendWhenOnlineTip(): Unit {
        this.writeGlobalBool(ApplicationSpecificGlobalNotice.sendWhenOnlineTip)
    }

    // ==========================================
    // Counter-typed notices (Int64 value, increment supported)
    // ==========================================

    /**
     * chatMediaMediaRecordingTips (raw=3) — Counter
     * iOS: getChatMediaMediaRecordingTips / incrementChatMediaMediaRecordingTips
     */
    public func getChatMediaMediaRecordingTips(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.chatMediaMediaRecordingTips)
    }
    public func incrementChatMediaMediaRecordingTips(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.chatMediaMediaRecordingTips, count)
    }

    /**
     * archiveChatTips (raw=10) — Counter
     * iOS: getArchiveChatTips / incrementArchiveChatTips → returns previousValue
     */
    public func getArchiveChatTips(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.archiveChatTips)
    }
    public func incrementArchiveChatTips(count: Int64): Int64 {
        return this.incrementGlobalCounterReturnPrev(ApplicationSpecificGlobalNotice.archiveChatTips, count)
    }

    /**
     * chatFolderTips (raw=19) — Counter
     * iOS: incrementChatFolderTips → returns previousValue
     */
    public func getChatFolderTips(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.chatFolderTips)
    }
    public func incrementChatFolderTips(count: Int64): Int64 {
        return this.incrementGlobalCounterReturnPrev(ApplicationSpecificGlobalNotice.chatFolderTips, count)
    }

    /**
     * profileCallTips (raw=4) — Counter
     */
    public func getProfileCallTips(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.profileCallTips)
    }
    public func incrementProfileCallTips(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.profileCallTips, count)
    }
    /**
     * setPublicChannelLink (raw=5) — Counter (iOS uses profileCallTips key, same raw=4)
     * iOS: getSetPublicChannelLink reads profileCallTips counter < 1
     *      markAsSeenSetPublicChannelLink sets profileCallTips counter to 1
     */
    public func getSetPublicChannelLink(): Bool {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.profileCallTips) < 1
    }
    public func markAsSeenSetPublicChannelLink(): Unit {
        let cache = getTelegramEngineItemCacheService()
        let key = globalNoticeKey(ApplicationSpecificGlobalNotice.profileCallTips)
        cache.put(key, encodeCounter(1))
    }

    /**
     * callsTabTip (raw=18) — Counter
     * iOS: getCallsTabTip / incrementCallsTabTips (clamps +min(3,count)) → returns previousValue
     */
    public func getCallsTabTip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.callsTabTip)
    }
    public func incrementCallsTabTips(count: Int64): Int64 {
        let prev = this.readGlobalCounter(ApplicationSpecificGlobalNotice.callsTabTip)
        var clampedCount = count
        if (clampedCount > 3) { clampedCount = 3 }
        let newVal = prev + clampedCount
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(ApplicationSpecificGlobalNotice.callsTabTip), encodeCounter(newVal))
        return prev
    }

    /**
     * chatMessageSearchResultsTip (raw=14) — Counter
     */
    public func getChatMessageSearchResultsTip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.chatMessageSearchResultsTip)
    }
    public func incrementChatMessageSearchResultsTip(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.chatMessageSearchResultsTip, count)
    }

    /**
     * chatMessageOptionsTip (raw=15) — Counter
     * locationProximityAlertTip also uses chatMessageOptionsTip key (iOS parity)
     */
    public func getChatMessageOptionsTip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.chatMessageOptionsTip)
    }
    public func incrementChatMessageOptionsTip(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.chatMessageOptionsTip, count)
    }
    public func getLocationProximityAlertTip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.chatMessageOptionsTip)
    }
    public func incrementLocationProximityAlertTip(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.chatMessageOptionsTip, count)
    }

    /**
     * chatTextSelectionTip (raw=16) — Counter
     */
    public func getChatTextSelectionTips(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.chatTextSelectionTip)
    }
    public func incrementChatTextSelectionTips(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.chatTextSelectionTip, count)
    }

    /**
     * replyQuoteTextSelectionTip (raw=53) — Counter
     */
    public func getReplyQuoteTextSelectionTips(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.replyQuoteTextSelectionTip)
    }
    public func incrementReplyQuoteTextSelectionTips(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.replyQuoteTextSelectionTip, count)
    }

    /**
     * messageViewsPrivacyTips (raw=25) — Counter
     */
    public func getMessageViewsPrivacyTips(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.messageViewsPrivacyTips)
    }
    public func incrementMessageViewsPrivacyTips(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.messageViewsPrivacyTips, count)
    }

    /**
     * nextChatSuggestionTip (raw=21) — Counter
     */
    public func getNextChatSuggestionTip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.nextChatSuggestionTip)
    }
    public func incrementNextChatSuggestionTip(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.nextChatSuggestionTip, count)
    }

    /**
     * sharedMediaScrollingTooltip (raw=29) — Counter
     */
    public func getSharedMediaScrollingTooltip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.sharedMediaScrollingTooltip)
    }
    public func incrementSharedMediaScrollingTooltip(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.sharedMediaScrollingTooltip, count)
    }

    /**
     * sharedMediaFastScrollingTooltip (raw=30) — Counter
     */
    public func getSharedMediaFastScrollingTooltip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.sharedMediaFastScrollingTooltip)
    }
    public func incrementSharedMediaFastScrollingTooltip(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.sharedMediaFastScrollingTooltip, count)
    }

    /**
     * emojiTooltip (raw=32) — Counter
     */
    public func getEmojiTooltip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.emojiTooltip)
    }
    public func incrementEmojiTooltip(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.emojiTooltip, count)
    }

    /**
     * audioTranscriptionSuggestion (raw=33) — Counter
     * iOS: getAudioTranscriptionSuggestion / incrementAudioTranscriptionSuggestion → returns previousValue
     */
    public func getAudioTranscriptionSuggestion(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.audioTranscriptionSuggestion)
    }
    public func incrementAudioTranscriptionSuggestion(count: Int64): Int64 {
        return this.incrementGlobalCounterReturnPrev(ApplicationSpecificGlobalNotice.audioTranscriptionSuggestion, count)
    }

    /**
     * clearStorageDismissedTipSize (raw=34) — Counter (iOS uses it as a storage size value)
     */
    public func getClearStorageDismissedTipSize(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.clearStorageDismissedTipSize)
    }
    public func setClearStorageDismissedTipSize(value: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(ApplicationSpecificGlobalNotice.clearStorageDismissedTipSize), encodeCounter(value))
    }

    /**
     * audioRateOptionsTip (raw=36) — Counter
     * iOS: getAudioRateOptionsTip / incrementAudioRateOptionsTip → returns previousValue
     */
    public func getAudioRateOptionsTip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.audioRateOptionsTip)
    }
    public func incrementAudioRateOptionsTip(count: Int64): Int64 {
        return this.incrementGlobalCounterReturnPrev(ApplicationSpecificGlobalNotice.audioRateOptionsTip, count)
    }

    /**
     * chatForwardOptionsTip (raw=24) — Counter → returns previousValue
     */
    public func getChatForwardOptionsTip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.chatForwardOptionsTip)
    }
    public func incrementChatForwardOptionsTip(count: Int64): Int64 {
        return this.incrementGlobalCounterReturnPrev(ApplicationSpecificGlobalNotice.chatForwardOptionsTip, count)
    }

    /**
     * chatReplyOptionsTip (raw=50) — Counter → returns previousValue
     */
    public func getChatReplyOptionsTip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.chatReplyOptionsTip)
    }
    public func incrementChatReplyOptionsTip(count: Int64): Int64 {
        return this.incrementGlobalCounterReturnPrev(ApplicationSpecificGlobalNotice.chatReplyOptionsTip, count)
    }

    /**
     * storyStealthModeReplyCount (raw=47) — Counter
     */
    public func getStoryStealthModeReplyCount(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.storyStealthModeReplyCount)
    }
    public func setStoryStealthModeReplyCount(value: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(ApplicationSpecificGlobalNotice.storyStealthModeReplyCount), encodeCounter(value))
    }

    /**
     * incomingVoiceMessagePlayOnceTip (raw=59) — Counter
     */
    public func getIncomingVoiceMessagePlayOnceTip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.incomingVoiceMessagePlayOnceTip)
    }
    public func incrementIncomingVoiceMessagePlayOnceTip(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.incomingVoiceMessagePlayOnceTip, count)
    }

    /**
     * outgoingVoiceMessagePlayOnceTip (raw=60) — Counter
     */
    public func getOutgoingVoiceMessagePlayOnceTip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.outgoingVoiceMessagePlayOnceTip)
    }
    public func incrementOutgoingVoiceMessagePlayOnceTip(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.outgoingVoiceMessagePlayOnceTip, count)
    }

    /**
     * incomingVideoMessagePlayOnceTip (raw=62) — Counter
     */
    public func getIncomingVideoMessagePlayOnceTip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.incomingVideoMessagePlayOnceTip)
    }
    public func incrementIncomingVideoMessagePlayOnceTip(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.incomingVideoMessagePlayOnceTip, count)
    }

    /**
     * outgoingVideoMessagePlayOnceTip (raw=63) — Counter
     */
    public func getOutgoingVideoMessagePlayOnceTip(): Int64 {
        return this.readGlobalCounter(ApplicationSpecificGlobalNotice.outgoingVideoMessagePlayOnceTip)
    }
    public func incrementOutgoingVideoMessagePlayOnceTip(count: Int64): Unit {
        this.incrementGlobalCounter(ApplicationSpecificGlobalNotice.outgoingVideoMessagePlayOnceTip, count)
    }

    // ==========================================
    // TimestampAndCounter-typed notices
    // JSON {"v":counter,"t":timestamp}
    // ==========================================

    /**
     * chatSpecificThemeLightPreviewTip (raw=26) — TimestampAndCounter
     * iOS: getChatSpecificThemeLightPreviewTip → (counter, timestamp)
     *      incrementChatSpecificThemeLightPreviewTip → previousCounter
     */
    public func getChatSpecificThemeLightPreviewTip(): (Int64, Int64) {
        return this.readGlobalTimestampAndCounter(ApplicationSpecificGlobalNotice.chatSpecificThemeLightPreviewTip)
    }
    public func incrementChatSpecificThemeLightPreviewTip(count: Int64, timestamp: Int64): Int64 {
        let (prev, _) = this.readGlobalTimestampAndCounter(ApplicationSpecificGlobalNotice.chatSpecificThemeLightPreviewTip)
        let newVal = prev + count
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(ApplicationSpecificGlobalNotice.chatSpecificThemeLightPreviewTip),
            encodeTimestampAndCounter(newVal, timestamp))
        return prev
    }

    /**
     * chatSpecificThemeDarkPreviewTip (raw=27) — TimestampAndCounter
     */
    public func getChatSpecificThemeDarkPreviewTip(): (Int64, Int64) {
        return this.readGlobalTimestampAndCounter(ApplicationSpecificGlobalNotice.chatSpecificThemeDarkPreviewTip)
    }
    public func incrementChatSpecificThemeDarkPreviewTip(count: Int64, timestamp: Int64): Int64 {
        let (prev, _) = this.readGlobalTimestampAndCounter(ApplicationSpecificGlobalNotice.chatSpecificThemeDarkPreviewTip)
        let newVal = prev + count
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(ApplicationSpecificGlobalNotice.chatSpecificThemeDarkPreviewTip),
            encodeTimestampAndCounter(newVal, timestamp))
        return prev
    }

    /**
     * chatWallpaperLightPreviewTip (raw=39) — TimestampAndCounter
     */
    public func getChatWallpaperLightPreviewTip(): (Int64, Int64) {
        return this.readGlobalTimestampAndCounter(ApplicationSpecificGlobalNotice.chatWallpaperLightPreviewTip)
    }
    public func incrementChatWallpaperLightPreviewTip(count: Int64, timestamp: Int64): Int64 {
        let (prev, _) = this.readGlobalTimestampAndCounter(ApplicationSpecificGlobalNotice.chatWallpaperLightPreviewTip)
        let newVal = prev + count
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(ApplicationSpecificGlobalNotice.chatWallpaperLightPreviewTip),
            encodeTimestampAndCounter(newVal, timestamp))
        return prev
    }

    /**
     * chatWallpaperDarkPreviewTip (raw=40) — TimestampAndCounter
     */
    public func getChatWallpaperDarkPreviewTip(): (Int64, Int64) {
        return this.readGlobalTimestampAndCounter(ApplicationSpecificGlobalNotice.chatWallpaperDarkPreviewTip)
    }
    public func incrementChatWallpaperDarkPreviewTip(count: Int64, timestamp: Int64): Int64 {
        let (prev, _) = this.readGlobalTimestampAndCounter(ApplicationSpecificGlobalNotice.chatWallpaperDarkPreviewTip)
        let newVal = prev + count
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(ApplicationSpecificGlobalNotice.chatWallpaperDarkPreviewTip),
            encodeTimestampAndCounter(newVal, timestamp))
        return prev
    }

    /**
     * interactiveEmojiSyncTip (raw=28) — TimestampAndCounter
     */
    public func getInteractiveEmojiSyncTip(): (Int64, Int64) {
        return this.readGlobalTimestampAndCounter(ApplicationSpecificGlobalNotice.interactiveEmojiSyncTip)
    }
    public func incrementInteractiveEmojiSyncTip(count: Int64, timestamp: Int64): Int64 {
        let (prev, _) = this.readGlobalTimestampAndCounter(ApplicationSpecificGlobalNotice.interactiveEmojiSyncTip)
        let newVal = prev + count
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(ApplicationSpecificGlobalNotice.interactiveEmojiSyncTip),
            encodeTimestampAndCounter(newVal, timestamp))
        return prev
    }

    /**
     * translationSuggestion (raw=37) — TimestampAndCounter
     * iOS: translationSuggestion / incrementTranslationSuggestion → previousValue
     * Note: iOS skips increment if stored timestamp > new timestamp
     */
    public func getTranslationSuggestion(): (Int64, Int64) {
        return this.readGlobalTimestampAndCounter(ApplicationSpecificGlobalNotice.translationSuggestion)
    }
    public func incrementTranslationSuggestion(count: Int64, timestamp: Int64): Int64 {
        let (currentVal, currentTs) = this.readGlobalTimestampAndCounter(ApplicationSpecificGlobalNotice.translationSuggestion)
        if (currentTs > timestamp) {
            return currentVal
        }
        let prevVal = currentVal
        var newVal = currentVal + count
        if (newVal < 0) { newVal = 0 }
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(ApplicationSpecificGlobalNotice.translationSuggestion),
            encodeTimestampAndCounter(newVal, timestamp))
        return prevVal
    }

    // ==========================================
    // Int64Array-typed notices
    // JSON {"v":[1,2,3]}
    // ==========================================

    /**
     * dismissedTrendingStickerPacks (raw=22) — Int64Array
     * iOS: dismissedTrendingStickerPacks / setDismissedTrendingStickerPacks
     */
    public func getDismissedTrendingStickerPacks(): Option<ArrayList<Int64>> {
        return this.readGlobalInt64Array(ApplicationSpecificGlobalNotice.dismissedTrendingStickerPacks)
    }
    public func setDismissedTrendingStickerPacks(values: ArrayList<Int64>): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(ApplicationSpecificGlobalNotice.dismissedTrendingStickerPacks),
            encodeInt64Array(values))
    }

    /**
     * dismissedTrendingEmojiPacks (raw=35) — Int64Array
     */
    public func getDismissedTrendingEmojiPacks(): Option<ArrayList<Int64>> {
        return this.readGlobalInt64Array(ApplicationSpecificGlobalNotice.dismissedTrendingEmojiPacks)
    }
    public func setDismissedTrendingEmojiPacks(values: ArrayList<Int64>): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(ApplicationSpecificGlobalNotice.dismissedTrendingEmojiPacks),
            encodeInt64Array(values))
    }

    // ==========================================
    // Per-peer notices
    // ==========================================

    /**
     * Timestamp per-peer notice: forcedPasswordSetup (raw=31 = secretChatInlineBotUsage iOS quirk)
     * iOS: setForcedPasswordSetup sets/clears forcedPasswordSetup counter
     */
    public func getForcedPasswordSetup(): Option<Int64> {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(globalNoticeKey(ApplicationSpecificGlobalNotice.forcedPasswordSetup))) {
            case Some(s) =>
                if (s.size == 0) { return None }
                return Some(decodeCounter(s))
            case None => return None
        }
    }
    public func setForcedPasswordSetup(reloginDaysTimeout: Option<Int64>): Unit {
        let cache = getTelegramEngineItemCacheService()
        let key = globalNoticeKey(ApplicationSpecificGlobalNotice.forcedPasswordSetup)
        match (reloginDaysTimeout) {
            case Some(days) => cache.put(key, encodeCounter(days))
            case None => cache.remove(key)
        }
    }

    /**
     * Per-peer irrelevant geo report notice (ns=4, subKey=0) — Bool
     * iOS: setIrrelevantPeerGeoReport
     */
    public func setIrrelevantPeerGeoReport(peerId: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(peerNoticeKey(noticeNsPeerReport, peerId, 0), encodeBool())
    }
    public func getIrrelevantPeerGeoReport(peerId: Int64): Bool {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(peerNoticeKey(noticeNsPeerReport, peerId, 0))) {
            case Some(_) => return true
            case None => return false
        }
    }

    /**
     * Per-peer bot payment liability (ns=1, subKey=0) — Bool
     * iOS: getBotPaymentLiability / setBotPaymentLiability
     */
    public func getBotPaymentLiability(peerId: Int64): Bool {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(peerNoticeKey(noticeNsBotPayment, peerId, 0))) {
            case Some(_) => return true
            case None => return false
        }
    }
    public func setBotPaymentLiability(peerId: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(peerNoticeKey(noticeNsBotPayment, peerId, 0), encodeBool())
    }

    /**
     * Per-peer bot game notice (ns=7, subKey=0) — Bool
     * iOS: getBotGameNotice / setBotGameNotice
     */
    public func getBotGameNotice(peerId: Int64): Bool {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(peerNoticeKey(noticeNsBotGame, peerId, 0))) {
            case Some(_) => return true
            case None => return false
        }
    }
    public func setBotGameNotice(peerId: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(peerNoticeKey(noticeNsBotGame, peerId, 0), encodeBool())
    }

    /**
     * Per-peer inline bot location request notice (ns=5, subKey=0) — Timestamp
     * iOS: getInlineBotLocationRequest / setInlineBotLocationRequest / updateInlineBotLocationRequestState
     */
    public func getInlineBotLocationRequest(peerId: Int64): Option<Int64> {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(peerNoticeKey(noticeNsInlineBotLocation, peerId, 0))) {
            case Some(s) => return Some(decodeTimestamp(s))
            case None => return None
        }
    }
    public func setInlineBotLocationRequest(peerId: Int64, value: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(peerNoticeKey(noticeNsInlineBotLocation, peerId, 0), encodeTimestamp(value))
    }
    /**
     * iOS updateInlineBotLocationRequestState: returns false if existing (value==0 || ts <= stored+10min)
     */
    public func updateInlineBotLocationRequestState(peerId: Int64, timestamp: Int64): Bool {
        match (this.getInlineBotLocationRequest(peerId)) {
            case Some(existing) =>
                if (existing == 0 || timestamp <= existing + 600) {
                    return false
                }
                this.setInlineBotLocationRequest(peerId, timestamp)
                return true
            case None =>
                this.setInlineBotLocationRequest(peerId, timestamp)
                return true
        }
    }
    public func inlineBotLocationRequestStatus(peerId: Int64): Bool {
        match (this.getInlineBotLocationRequest(peerId)) {
            case Some(v) => return v == 0
            case None => return false
        }
    }

    /**
     * Per-peer PSA acknowledgement (ns=6, subKey=0) — Bool
     * iOS: getPsaAcknowledgment / setPsaAcknowledgment
     */
    public func getPsaAcknowledgment(peerId: Int64): Bool {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(peerNoticeKey(noticeNsPsaAck, peerId, 0))) {
            case Some(_) => return true
            case None => return false
        }
    }
    public func setPsaAcknowledgment(peerId: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(peerNoticeKey(noticeNsPsaAck, peerId, 0), encodeBool())
    }

    /**
     * Per-peer dismissed premium gift notice (ns=9, subKey=0) — Timestamp
     * iOS: dismissedPremiumGiftSuggestion / incrementDismissedPremiumGiftSuggestion
     */
    public func getDismissedPremiumGiftSuggestion(peerId: Int64): Option<Int64> {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(peerNoticeKey(noticeNsDismissedPremiumGift, peerId, 0))) {
            case Some(s) => return Some(decodeTimestamp(s))
            case None => return None
        }
    }
    public func setDismissedPremiumGiftSuggestion(peerId: Int64, timestamp: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(peerNoticeKey(noticeNsDismissedPremiumGift, peerId, 0), encodeTimestamp(timestamp))
    }

    /**
     * Per-peer group emoji pack suggestion (ns=9, subKey=0) — Counter
     * iOS: groupEmojiPackSuggestion / incrementGroupEmojiPackSuggestion → previousValue
     * Note: iOS uses same namespace=9 as dismissedPremiumGift — same key space, shared by iOS design
     */
    public func getGroupEmojiPackSuggestion(peerId: Int64): Int64 {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(peerNoticeKey(noticeNsGroupEmojiPack, peerId, 0))) {
            case Some(s) => return decodeCounter(s)
            case None => return 0
        }
    }
    public func incrementGroupEmojiPackSuggestion(peerId: Int64, count: Int64): Int64 {
        let prev = this.getGroupEmojiPackSuggestion(peerId)
        let cache = getTelegramEngineItemCacheService()
        cache.put(peerNoticeKey(noticeNsGroupEmojiPack, peerId, 0), encodeCounter(prev + count))
        return prev
    }

    /**
     * Per-peer dismissed invitation requests (ns=8, subKey=0) — Int64Array
     * iOS: dismissedInvitationRequests / setDismissedInvitationRequests
     */
    public func getDismissedInvitationRequests(peerId: Int64): Option<ArrayList<Int64>> {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(peerNoticeKey(noticeNsPeerInviteRequests, peerId, 0))) {
            case Some(s) =>
                if (s.size == 0) { return None }
                return Some(decodeInt64Array(s))
            case None => return None
        }
    }
    public func setDismissedInvitationRequests(peerId: Int64, values: ArrayList<Int64>): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(peerNoticeKey(noticeNsPeerInviteRequests, peerId, 0), encodeInt64Array(values))
    }

    /**
     * Per-peer dismissed birthday premium gift tip (ns=10, subKey=0) — Bool
     */
    public func getDismissedBirthdayPremiumGiftTip(peerId: Int64): Bool {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(peerNoticeKey(noticeNsDismissedBirthdayPremiumGiftTip, peerId, 0))) {
            case Some(_) => return true
            case None => return false
        }
    }
    public func setDismissedBirthdayPremiumGiftTip(peerId: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(peerNoticeKey(noticeNsDismissedBirthdayPremiumGiftTip, peerId, 0), encodeBool())
    }

    /**
     * Per-peer displayed peer verification (ns=11, subKey=0) — Bool
     */
    public func getDisplayedPeerVerification(peerId: Int64): Bool {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(peerNoticeKey(noticeNsDisplayedPeerVerification, peerId, 0))) {
            case Some(_) => return true
            case None => return false
        }
    }
    public func setDisplayedPeerVerification(peerId: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(peerNoticeKey(noticeNsDisplayedPeerVerification, peerId, 0), encodeBool())
    }

    /**
     * Per-peer dismissed paid message warning (ns=11, subKey=0) — Bool
     * Note: iOS uses same namespace=11 as displayedPeerVerification
     */
    public func getDismissedPaidMessageWarning(peerId: Int64): Bool {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(peerNoticeKey(noticeNsDismissedPaidMessageWarning, peerId, 0))) {
            case Some(_) => return true
            case None => return false
        }
    }
    public func setDismissedPaidMessageWarning(peerId: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(peerNoticeKey(noticeNsDismissedPaidMessageWarning, peerId, 0), encodeBool())
    }

    /**
     * Permission warning timestamp (ns=3, subKey=raw)
     * iOS: setPermissionWarning(permission:, value:) / getTimestampValue
     * permissionKind: "contacts"=7, "notifications"=8, "cellularData"=13
     */
    public func getPermissionWarningTimestamp(permissionRaw: Int64): Option<Int64> {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(peerNoticeKey(noticeNsPermissions, 0, permissionRaw))) {
            case Some(s) => return Some(decodeTimestamp(s))
            case None => return None
        }
    }
    public func setPermissionWarningTimestamp(permissionRaw: Int64, value: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(peerNoticeKey(noticeNsPermissions, 0, permissionRaw), encodeTimestamp(value))
    }

    // ==========================================
    // Peer suggestions (legacy, used by NoticesDataProvider)
    // ==========================================

    private func loadPeerSuggestionsFromCache(peerId: Int64): ArrayList<String> {
        let cache = getTelegramEngineItemCacheService()
        let key = "notices_peer_suggestions_${peerId}"
        match (cache.get(key)) {
            case Some(jsonStr) =>
                if (jsonStr.size > 0) {
                    return this.parseStringArray(jsonStr)
                }
                return ArrayList<String>()
            case None => return ArrayList<String>()
        }
    }

    private func loadPeerDismissedSuggestions(peerId: Int64): ArrayList<String> {
        let cache = getTelegramEngineItemCacheService()
        let key = "notices_peer_dismissed_${peerId}"
        match (cache.get(key)) {
            case Some(jsonStr) =>
                if (jsonStr.size > 0) {
                    return this.parseStringArray(jsonStr)
                }
                return ArrayList<String>()
            case None => return ArrayList<String>()
        }
    }

    private func addLocalPeerDismissedSuggestion(peerId: Int64, suggestion: String): Unit {
        let current = this.loadPeerDismissedSuggestions(peerId)
        if (!this.listContains(current, suggestion)) {
            current.add(suggestion)
            let cache = getTelegramEngineItemCacheService()
            let key = "notices_peer_dismissed_${peerId}"
            let obj = JsonObject()
            let arr = JsonArray()
            for (s in current) { arr.addString(s) }
            obj.setArray("ids", arr)
            cache.put(key, JsonParser.stringify(obj))
        }
    }

    private func parseStringArray(jsonStr: String): ArrayList<String> {
        let obj = JsonParser.parseObject(jsonStr)
        let arr = obj.getArray("ids")
        let result = ArrayList<String>()
        var i: Int64 = 0
        while (i < arr.size()) {
            let s = arr.getString(i)
            if (s.size > 0) { result.add(s) }
            i = i + 1
        }
        return result
    }

    private func listContains(list: ArrayList<String>, s: String): Bool {
        for (item in list) {
            if (item == s) { return true }
        }
        return false
    }

    // ==========================================
    // Internal generic notice helpers
    // ==========================================

    private func readGlobalBool(rawValue: Int64): Bool {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(globalNoticeKey(rawValue))) {
            case Some(_) => return true
            case None => return false
        }
    }
    private func writeGlobalBool(rawValue: Int64): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(rawValue), encodeBool())
    }

    private func readGlobalVariant(rawValue: Int64): Option<Bool> {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(globalNoticeKey(rawValue))) {
            case Some(s) => return Some(decodeVariant(s))
            case None => return None
        }
    }
    private func writeGlobalVariant(rawValue: Int64, value: Bool): Unit {
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(rawValue), encodeVariant(value))
    }

    private func readGlobalCounter(rawValue: Int64): Int64 {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(globalNoticeKey(rawValue))) {
            case Some(s) => return decodeCounter(s)
            case None => return 0
        }
    }
    private func incrementGlobalCounter(rawValue: Int64, delta: Int64): Unit {
        let prev = this.readGlobalCounter(rawValue)
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(rawValue), encodeCounter(prev + delta))
    }
    private func incrementGlobalCounterReturnPrev(rawValue: Int64, delta: Int64): Int64 {
        let prev = this.readGlobalCounter(rawValue)
        let cache = getTelegramEngineItemCacheService()
        cache.put(globalNoticeKey(rawValue), encodeCounter(prev + delta))
        return prev
    }

    private func readGlobalTimestampAndCounter(rawValue: Int64): (Int64, Int64) {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(globalNoticeKey(rawValue))) {
            case Some(s) =>
                if (s.size == 0) { return (0, 0) }
                return decodeTimestampAndCounter(s)
            case None => return (0, 0)
        }
    }

    private func readGlobalInt64Array(rawValue: Int64): Option<ArrayList<Int64>> {
        let cache = getTelegramEngineItemCacheService()
        match (cache.get(globalNoticeKey(rawValue))) {
            case Some(s) =>
                if (s.size == 0) { return None }
                return Some(decodeInt64Array(s))
            case None => return None
        }
    }
}
