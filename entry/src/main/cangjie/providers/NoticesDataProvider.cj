package ohos_app_cangjie_entry.providers

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getNoticesService,
    getTelegramEngineItemCacheService,
    JsonParser,
    JsonObject,
    JsonArray,
    ApplicationSpecificGlobalNotice
}
import ohos_app_cangjie_entry.core.mtproto.HelpPromoDataResponse
import std.collection.{ArrayList, HashMap}

/**
 * NoticesDataProvider — 将 Notices API 数据转为 UI 可用的 ViewModel
 *
 * 对应 iOS TelegramEngineNotices + Suggestions 的 UI 层适配:
 *   - getServerProvidedSuggestions / getDismissedSuggestions / dismissSuggestion / getPromoData
 *   - getPeerSpecificSuggestions / dismissPeerSpecificSuggestion  (peer 维度)
 *   - setNoticeEntry / getNoticeEntry                             (通用 notice 入口)
 *   - ApplicationSpecificGlobalNotice typed accessors              (P2-254 gap 1)
 *   - Full suggestion title mapping (P2-265 gap: suggestionIdToTitle 完整覆盖)
 *
 * 本地存储：
 *   ItemCacheService (telegram_item_cache Preferences):
 *     key "notices_dismissed_ids"            → 全局已 dismiss suggestion ID 列表
 *     key "notices_peer_dismissed_<peerId>"  → peer 维度已 dismiss 列表
 *     key "notices_peer_suggestions_<peerId>"→ peer 维度建议缓存
 *     key "notice_entry_<key>"               → 通用 notice 入口
 *     key "glo_<rawValue>"                   → ApplicationSpecificGlobalNotice 存储
 *     key "peer_<ns>_<peerId>_<subKey>"      → per-peer notice 存储
 *
 * 登出清理: 通过 emitted_integration_contract ic_notices_logout_clear 注入 AuthStorage.clearAll。
 */
public class NoticesDataProvider {
    private let noticesService = getNoticesService()
    private let cache = getTelegramEngineItemCacheService()
    private let dismissedCacheKey: String = "notices_dismissed_ids"

    /**
     * 获取需要展示的服务器建议列表（已过滤本地已 dismiss 的）
     * 对应 iOS TelegramEngine.Notices.getServerProvidedSuggestions(reload:)
     */
    public func getServerProvidedSuggestions(reload: Bool): ArrayList<NoticeSuggestion> {
        let promo = this.noticesService.getPromoData()
        let serverDismissed = promo.dismissedSuggestions
        let localDismissed = this.getLocalDismissedIds()
        let allDismissed = HashMap<String, Bool>()
        for (id in serverDismissed) { allDismissed[id] = true }
        for (id in localDismissed) { allDismissed[id] = true }

        let result = ArrayList<NoticeSuggestion>()
        for (id in promo.pendingSuggestions) {
            if (!allDismissed.contains(id)) {
                let item = NoticeSuggestion()
                item.id = id
                item.title = this.suggestionIdToTitle(id)
                result.add(item)
            }
        }
        return result
    }

    /**
     * 获取已 dismiss 的建议 ID 列表（服务器 + 本地）
     * 对应 iOS TelegramEngine.Notices.getServerDismissedSuggestions()
     */
    public func getDismissedSuggestions(): ArrayList<String> {
        let promo = this.noticesService.getPromoData()
        let result = ArrayList<String>()
        for (id in promo.dismissedSuggestions) { result.add(id) }
        for (id in this.getLocalDismissedIds()) { result.add(id) }
        return result
    }

    /**
     * Dismiss 指定全局建议（调用服务器 API + 更新本地缓存）
     * 对应 iOS TelegramEngine.Notices.dismissServerProvidedSuggestion(suggestion:)
     */
    public func dismissSuggestion(suggestion: String): Unit {
        let ok = this.noticesService.dismissSuggestion(suggestion)
        if (ok) {
            Hilog.info(0, "CjTelegram", "[NoticesDataProvider] Server dismiss OK: ${suggestion}")
        }
        this.addLocalDismissedId(suggestion)
    }

    /**
     * 获取 PromoData 原始数据（供需要完整信息的调用方使用）
     */
    public func getPromoData(): HelpPromoDataResponse {
        return this.noticesService.getPromoData()
    }

    /**
     * 获取 peer 维度的待处理建议（过滤已 dismiss）
     * 对应 iOS TelegramEngine.Notices.getPeerSpecificServerProvidedSuggestions(peerId:)
     * 对应 iOS PeerSpecificServerProvidedSuggestion（目前仅 CONVERT_GIGAGROUP）
     *
     * peerId: 频道/群组 peer ID（Int64）
     */
    public func getPeerSpecificSuggestions(peerId: Int64): ArrayList<NoticeSuggestion> {
        let ids = this.noticesService.getPeerSpecificSuggestions(peerId)
        let result = ArrayList<NoticeSuggestion>()
        for (id in ids) {
            let item = NoticeSuggestion()
            item.id = id
            item.title = this.peerSuggestionIdToTitle(id)
            result.add(item)
        }
        return result
    }

    /**
     * Dismiss peer 维度建议（server + 本地缓存）
     * 对应 iOS TelegramEngine.Notices.dismissPeerSpecificServerProvidedSuggestion(peerId:, suggestion:)
     * TL: help.dismissSuggestion#f50dbaa1 peer:InputPeer suggestion:string = Bool
     *
     * peerType: "channel" | "group" | "user"
     */
    public func dismissPeerSpecificSuggestion(peerId: Int64, peerType: String, accessHash: Int64, suggestion: String): Unit {
        let ok = this.noticesService.dismissPeerSuggestion(peerId, peerType, accessHash, suggestion)
        Hilog.info(0, "CjTelegram", "[NoticesDataProvider] dismissPeerSpecificSuggestion peerId=${peerId} suggestion=${suggestion} ok=${ok}")
    }

    /**
     * 更新 peer 建议缓存（由 FullChannel 请求响应后调用，注入 pendingSuggestions）
     */
    public func updatePeerSuggestionsCache(peerId: Int64, suggestions: ArrayList<String>): Unit {
        this.noticesService.setPeerSpecificSuggestions(peerId, suggestions)
    }

    /**
     * 写入通用 notice 入口（对应 iOS TelegramEngine.Notices.set<T>(id:, item:)）
     * key 格式: "<namespace>_<entryKey>" —— 由调用方按 iOS NoticeEntryKey 规范构造
     * value: 序列化字符串；空字符串表示删除（对应 iOS 传 nil）
     */
    public func setNoticeEntry(key: String, value: String): Unit {
        this.noticesService.setNoticeEntry(key, value)
    }

    /**
     * 读取通用 notice 入口
     * 对应 iOS NoticeTable.get(key:) → CodableEntry?
     */
    public func getNoticeEntry(key: String): Option<String> {
        return this.noticesService.getNoticeEntry(key)
    }

    /**
     * 标记 notice 为"已展示"（bool entry set to "1"）
     * 封装常见的 bool notice 写入，简化调用方
     */
    public func markNoticeSeen(key: String): Unit {
        this.noticesService.setNoticeEntry(key, "1")
    }

    /**
     * 检查 notice 是否已展示
     */
    public func isNoticeSeen(key: String): Bool {
        match (this.noticesService.getNoticeEntry(key)) {
            case Some(v) => return v == "1"
            case None => return false
        }
    }

    // ==========================================
    // ApplicationSpecificGlobalNotice typed accessors (P2-254)
    // Delegates to NoticesService with typed keys
    // ==========================================

    /** secretChatInlineBotUsage — Bool */
    public func getSecretChatInlineBotUsage(): Bool {
        return this.noticesService.getSecretChatInlineBotUsage()
    }
    public func setSecretChatInlineBotUsage(): Unit {
        this.noticesService.setSecretChatInlineBotUsage()
    }

    /** secretChatLinkPreviews — Variant(Bool) */
    public func getSecretChatLinkPreviews(): Option<Bool> {
        return this.noticesService.getSecretChatLinkPreviews()
    }
    public func setSecretChatLinkPreviews(value: Bool): Unit {
        this.noticesService.setSecretChatLinkPreviews(value)
    }

    /** archiveIntroDismissed — Variant(Bool) */
    public func getArchiveIntroDismissed(): Option<Bool> {
        return this.noticesService.getArchiveIntroDismissed()
    }
    public func setArchiveIntroDismissed(value: Bool): Unit {
        this.noticesService.setArchiveIntroDismissed(value)
    }

    /** proxyAdsAcknowledgment — Bool */
    public func getProxyAdsAcknowledgment(): Bool {
        return this.noticesService.getProxyAdsAcknowledgment()
    }
    public func setProxyAdsAcknowledgment(): Unit {
        this.noticesService.setProxyAdsAcknowledgment()
    }

    /** passcodeLockTips — Bool */
    public func getPasscodeLockTips(): Bool {
        return this.noticesService.getPasscodeLockTips()
    }
    public func setPasscodeLockTips(): Unit {
        this.noticesService.setPasscodeLockTips()
    }

    /** themeChangeTip — Bool */
    public func getThemeChangeTip(): Bool {
        return this.noticesService.getThemeChangeTip()
    }
    public func markThemeChangeTipAsSeen(): Unit {
        this.noticesService.markThemeChangeTipAsSeen()
    }

    /** volumeButtonToUnmute — Bool */
    public func getVolumeButtonToUnmute(): Bool {
        return this.noticesService.getVolumeButtonToUnmute()
    }
    public func setVolumeButtonToUnmute(): Unit {
        this.noticesService.setVolumeButtonToUnmute()
    }

    /** chatMediaMediaRecordingTips — Counter */
    public func getChatMediaMediaRecordingTips(): Int64 {
        return this.noticesService.getChatMediaMediaRecordingTips()
    }
    public func incrementChatMediaMediaRecordingTips(count: Int64): Unit {
        this.noticesService.incrementChatMediaMediaRecordingTips(count)
    }

    /** archiveChatTips — Counter */
    public func getArchiveChatTips(): Int64 {
        return this.noticesService.getArchiveChatTips()
    }
    public func incrementArchiveChatTips(count: Int64): Int64 {
        return this.noticesService.incrementArchiveChatTips(count)
    }

    /** chatFolderTips — Counter */
    public func getChatFolderTips(): Int64 {
        return this.noticesService.getChatFolderTips()
    }
    public func incrementChatFolderTips(count: Int64): Int64 {
        return this.noticesService.incrementChatFolderTips(count)
    }

    /** profileCallTips — Counter */
    public func getProfileCallTips(): Int64 {
        return this.noticesService.getProfileCallTips()
    }
    public func incrementProfileCallTips(count: Int64): Unit {
        this.noticesService.incrementProfileCallTips(count)
    }

    /** setPublicChannelLink (uses profileCallTips counter) */
    public func getSetPublicChannelLink(): Bool {
        return this.noticesService.getSetPublicChannelLink()
    }
    public func markAsSeenSetPublicChannelLink(): Unit {
        this.noticesService.markAsSeenSetPublicChannelLink()
    }

    /** callsTabTip — Counter */
    public func getCallsTabTip(): Int64 {
        return this.noticesService.getCallsTabTip()
    }
    public func incrementCallsTabTips(count: Int64): Int64 {
        return this.noticesService.incrementCallsTabTips(count)
    }

    /** chatMessageSearchResultsTip — Counter */
    public func getChatMessageSearchResultsTip(): Int64 {
        return this.noticesService.getChatMessageSearchResultsTip()
    }
    public func incrementChatMessageSearchResultsTip(count: Int64): Unit {
        this.noticesService.incrementChatMessageSearchResultsTip(count)
    }

    /** chatMessageOptionsTip / locationProximityAlertTip — Counter */
    public func getChatMessageOptionsTip(): Int64 {
        return this.noticesService.getChatMessageOptionsTip()
    }
    public func incrementChatMessageOptionsTip(count: Int64): Unit {
        this.noticesService.incrementChatMessageOptionsTip(count)
    }
    public func getLocationProximityAlertTip(): Int64 {
        return this.noticesService.getLocationProximityAlertTip()
    }
    public func incrementLocationProximityAlertTip(count: Int64): Unit {
        this.noticesService.incrementLocationProximityAlertTip(count)
    }

    /** chatTextSelectionTip — Counter */
    public func getChatTextSelectionTips(): Int64 {
        return this.noticesService.getChatTextSelectionTips()
    }
    public func incrementChatTextSelectionTips(count: Int64): Unit {
        this.noticesService.incrementChatTextSelectionTips(count)
    }

    /** replyQuoteTextSelectionTip — Counter */
    public func getReplyQuoteTextSelectionTips(): Int64 {
        return this.noticesService.getReplyQuoteTextSelectionTips()
    }
    public func incrementReplyQuoteTextSelectionTips(count: Int64): Unit {
        this.noticesService.incrementReplyQuoteTextSelectionTips(count)
    }

    /** messageViewsPrivacyTips — Counter */
    public func getMessageViewsPrivacyTips(): Int64 {
        return this.noticesService.getMessageViewsPrivacyTips()
    }
    public func incrementMessageViewsPrivacyTips(count: Int64): Unit {
        this.noticesService.incrementMessageViewsPrivacyTips(count)
    }

    /** nextChatSuggestionTip — Counter */
    public func getNextChatSuggestionTip(): Int64 {
        return this.noticesService.getNextChatSuggestionTip()
    }
    public func incrementNextChatSuggestionTip(count: Int64): Unit {
        this.noticesService.incrementNextChatSuggestionTip(count)
    }

    /** sharedMediaScrollingTooltip — Counter */
    public func getSharedMediaScrollingTooltip(): Int64 {
        return this.noticesService.getSharedMediaScrollingTooltip()
    }
    public func incrementSharedMediaScrollingTooltip(count: Int64): Unit {
        this.noticesService.incrementSharedMediaScrollingTooltip(count)
    }

    /** sharedMediaFastScrollingTooltip — Counter */
    public func getSharedMediaFastScrollingTooltip(): Int64 {
        return this.noticesService.getSharedMediaFastScrollingTooltip()
    }
    public func incrementSharedMediaFastScrollingTooltip(count: Int64): Unit {
        this.noticesService.incrementSharedMediaFastScrollingTooltip(count)
    }

    /** emojiTooltip — Counter */
    public func getEmojiTooltip(): Int64 {
        return this.noticesService.getEmojiTooltip()
    }
    public func incrementEmojiTooltip(count: Int64): Unit {
        this.noticesService.incrementEmojiTooltip(count)
    }

    /** audioTranscriptionSuggestion — Counter */
    public func getAudioTranscriptionSuggestion(): Int64 {
        return this.noticesService.getAudioTranscriptionSuggestion()
    }
    public func incrementAudioTranscriptionSuggestion(count: Int64): Int64 {
        return this.noticesService.incrementAudioTranscriptionSuggestion(count)
    }

    /** clearStorageDismissedTipSize — Counter */
    public func getClearStorageDismissedTipSize(): Int64 {
        return this.noticesService.getClearStorageDismissedTipSize()
    }
    public func setClearStorageDismissedTipSize(value: Int64): Unit {
        this.noticesService.setClearStorageDismissedTipSize(value)
    }

    /** audioRateOptionsTip — Counter */
    public func getAudioRateOptionsTip(): Int64 {
        return this.noticesService.getAudioRateOptionsTip()
    }
    public func incrementAudioRateOptionsTip(count: Int64): Int64 {
        return this.noticesService.incrementAudioRateOptionsTip(count)
    }

    /** chatForwardOptionsTip — Counter */
    public func getChatForwardOptionsTip(): Int64 {
        return this.noticesService.getChatForwardOptionsTip()
    }
    public func incrementChatForwardOptionsTip(count: Int64): Int64 {
        return this.noticesService.incrementChatForwardOptionsTip(count)
    }

    /** chatReplyOptionsTip — Counter */
    public func getChatReplyOptionsTip(): Int64 {
        return this.noticesService.getChatReplyOptionsTip()
    }
    public func incrementChatReplyOptionsTip(count: Int64): Int64 {
        return this.noticesService.incrementChatReplyOptionsTip(count)
    }

    /** storyStealthModeReplyCount — Counter */
    public func getStoryStealthModeReplyCount(): Int64 {
        return this.noticesService.getStoryStealthModeReplyCount()
    }
    public func setStoryStealthModeReplyCount(value: Int64): Unit {
        this.noticesService.setStoryStealthModeReplyCount(value)
    }

    /** TimestampAndCounter notices */
    public func getChatSpecificThemeLightPreviewTip(): (Int64, Int64) {
        return this.noticesService.getChatSpecificThemeLightPreviewTip()
    }
    public func incrementChatSpecificThemeLightPreviewTip(count: Int64, timestamp: Int64): Int64 {
        return this.noticesService.incrementChatSpecificThemeLightPreviewTip(count, timestamp)
    }

    public func getChatSpecificThemeDarkPreviewTip(): (Int64, Int64) {
        return this.noticesService.getChatSpecificThemeDarkPreviewTip()
    }
    public func incrementChatSpecificThemeDarkPreviewTip(count: Int64, timestamp: Int64): Int64 {
        return this.noticesService.incrementChatSpecificThemeDarkPreviewTip(count, timestamp)
    }

    public func getChatWallpaperLightPreviewTip(): (Int64, Int64) {
        return this.noticesService.getChatWallpaperLightPreviewTip()
    }
    public func incrementChatWallpaperLightPreviewTip(count: Int64, timestamp: Int64): Int64 {
        return this.noticesService.incrementChatWallpaperLightPreviewTip(count, timestamp)
    }

    public func getChatWallpaperDarkPreviewTip(): (Int64, Int64) {
        return this.noticesService.getChatWallpaperDarkPreviewTip()
    }
    public func incrementChatWallpaperDarkPreviewTip(count: Int64, timestamp: Int64): Int64 {
        return this.noticesService.incrementChatWallpaperDarkPreviewTip(count, timestamp)
    }

    public func getInteractiveEmojiSyncTip(): (Int64, Int64) {
        return this.noticesService.getInteractiveEmojiSyncTip()
    }
    public func incrementInteractiveEmojiSyncTip(count: Int64, timestamp: Int64): Int64 {
        return this.noticesService.incrementInteractiveEmojiSyncTip(count, timestamp)
    }

    public func getTranslationSuggestion(): (Int64, Int64) {
        return this.noticesService.getTranslationSuggestion()
    }
    public func incrementTranslationSuggestion(count: Int64, timestamp: Int64): Int64 {
        return this.noticesService.incrementTranslationSuggestion(count, timestamp)
    }

    /** Int64Array notices */
    public func getDismissedTrendingStickerPacks(): Option<ArrayList<Int64>> {
        return this.noticesService.getDismissedTrendingStickerPacks()
    }
    public func setDismissedTrendingStickerPacks(values: ArrayList<Int64>): Unit {
        this.noticesService.setDismissedTrendingStickerPacks(values)
    }

    public func getDismissedTrendingEmojiPacks(): Option<ArrayList<Int64>> {
        return this.noticesService.getDismissedTrendingEmojiPacks()
    }
    public func setDismissedTrendingEmojiPacks(values: ArrayList<Int64>): Unit {
        this.noticesService.setDismissedTrendingEmojiPacks(values)
    }

    /** forcedPasswordSetup */
    public func getForcedPasswordSetup(): Option<Int64> {
        return this.noticesService.getForcedPasswordSetup()
    }
    public func setForcedPasswordSetup(reloginDaysTimeout: Option<Int64>): Unit {
        this.noticesService.setForcedPasswordSetup(reloginDaysTimeout)
    }

    /** Per-peer notices */
    public func setIrrelevantPeerGeoReport(peerId: Int64): Unit {
        this.noticesService.setIrrelevantPeerGeoReport(peerId)
    }
    public func getIrrelevantPeerGeoReport(peerId: Int64): Bool {
        return this.noticesService.getIrrelevantPeerGeoReport(peerId)
    }

    public func getBotPaymentLiability(peerId: Int64): Bool {
        return this.noticesService.getBotPaymentLiability(peerId)
    }
    public func setBotPaymentLiability(peerId: Int64): Unit {
        this.noticesService.setBotPaymentLiability(peerId)
    }

    public func getBotGameNotice(peerId: Int64): Bool {
        return this.noticesService.getBotGameNotice(peerId)
    }
    public func setBotGameNotice(peerId: Int64): Unit {
        this.noticesService.setBotGameNotice(peerId)
    }

    public func getInlineBotLocationRequest(peerId: Int64): Option<Int64> {
        return this.noticesService.getInlineBotLocationRequest(peerId)
    }
    public func setInlineBotLocationRequest(peerId: Int64, value: Int64): Unit {
        this.noticesService.setInlineBotLocationRequest(peerId, value)
    }
    public func updateInlineBotLocationRequestState(peerId: Int64, timestamp: Int64): Bool {
        return this.noticesService.updateInlineBotLocationRequestState(peerId, timestamp)
    }

    public func getPsaAcknowledgment(peerId: Int64): Bool {
        return this.noticesService.getPsaAcknowledgment(peerId)
    }
    public func setPsaAcknowledgment(peerId: Int64): Unit {
        this.noticesService.setPsaAcknowledgment(peerId)
    }

    public func getDismissedPremiumGiftSuggestion(peerId: Int64): Option<Int64> {
        return this.noticesService.getDismissedPremiumGiftSuggestion(peerId)
    }
    public func setDismissedPremiumGiftSuggestion(peerId: Int64, timestamp: Int64): Unit {
        this.noticesService.setDismissedPremiumGiftSuggestion(peerId, timestamp)
    }

    public func getGroupEmojiPackSuggestion(peerId: Int64): Int64 {
        return this.noticesService.getGroupEmojiPackSuggestion(peerId)
    }
    public func incrementGroupEmojiPackSuggestion(peerId: Int64, count: Int64): Int64 {
        return this.noticesService.incrementGroupEmojiPackSuggestion(peerId, count)
    }

    public func getDismissedInvitationRequests(peerId: Int64): Option<ArrayList<Int64>> {
        return this.noticesService.getDismissedInvitationRequests(peerId)
    }
    public func setDismissedInvitationRequests(peerId: Int64, values: ArrayList<Int64>): Unit {
        this.noticesService.setDismissedInvitationRequests(peerId, values)
    }

    public func getDismissedBirthdayPremiumGiftTip(peerId: Int64): Bool {
        return this.noticesService.getDismissedBirthdayPremiumGiftTip(peerId)
    }
    public func setDismissedBirthdayPremiumGiftTip(peerId: Int64): Unit {
        this.noticesService.setDismissedBirthdayPremiumGiftTip(peerId)
    }

    public func getDisplayedPeerVerification(peerId: Int64): Bool {
        return this.noticesService.getDisplayedPeerVerification(peerId)
    }
    public func setDisplayedPeerVerification(peerId: Int64): Unit {
        this.noticesService.setDisplayedPeerVerification(peerId)
    }

    public func getDismissedPaidMessageWarning(peerId: Int64): Bool {
        return this.noticesService.getDismissedPaidMessageWarning(peerId)
    }
    public func setDismissedPaidMessageWarning(peerId: Int64): Unit {
        this.noticesService.setDismissedPaidMessageWarning(peerId)
    }

    public func getPermissionWarningTimestamp(permissionRaw: Int64): Option<Int64> {
        return this.noticesService.getPermissionWarningTimestamp(permissionRaw)
    }
    public func setPermissionWarningTimestamp(permissionRaw: Int64, value: Int64): Unit {
        this.noticesService.setPermissionWarningTimestamp(permissionRaw, value)
    }

    // ==========================================
    // Private helpers
    // ==========================================

    private func getLocalDismissedIds(): ArrayList<String> {
        match (this.cache.get(this.dismissedCacheKey)) {
            case Some(jsonStr) =>
                if (jsonStr.size > 0) {
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
                return ArrayList<String>()
            case None => return ArrayList<String>()
        }
    }

    private func addLocalDismissedId(id: String): Unit {
        let current = this.getLocalDismissedIds()
        if (!this.listContains(current, id)) {
            current.add(id)
            let obj = JsonObject()
            let arr = JsonArray()
            for (s in current) { arr.addString(s) }
            obj.setArray("ids", arr)
            this.cache.put(this.dismissedCacheKey, JsonParser.stringify(obj))
        }
    }

    private func listContains(list: ArrayList<String>, s: String): Bool {
        for (item in list) {
            if (item == s) { return true }
        }
        return false
    }

    /**
     * suggestionIdToTitle — 完整 iOS 建议 ID → 用户可见标题映射
     * P2-265 gap: 原先仅硬编码 8 条，现按 iOS ServerProvidedSuggestion 全量补齐
     *
     * 来源: iOS TelegramCore/Sources/TelegramEngine/Data/NoticesData.swift
     * struct ServerProvidedSuggestion / SuggestionsConfiguration
     */
    private func suggestionIdToTitle(id: String): String {
        match (id) {
            case "AUTOARCHIVE_POPULAR" => return "Auto-archive popular chats"
            case "NEWCOMER_TICKS" => return "Newcomer ticks"
            case "VALIDATE_PHONE_NUMBER" => return "Validate phone number"
            case "VALIDATE_PASSWORD" => return "Validate password"
            case "SETUP_PASSWORD" => return "Setup password"
            case "PREMIUM_UPGRADE" => return "Upgrade to Premium"
            case "PREMIUM_ANNUAL" => return "Annual Premium"
            case "PREMIUM_RESTORE" => return "Restore Premium"
            case "PREMIUM_CHRISTMAS" => return "Premium Christmas Gift"
            case "BIRTHDAY_SETUP" => return "Setup birthday"
            case "BIRTHDAY_CONTACTS_TODAY" => return "Birthdays today"
            case "PREMIUM_GRACE" => return "Premium grace period"
            case "STARS_SUBSCRIPTION_LOW_BALANCE" => return "Stars subscription low balance"
            case "USERPIC_SETUP" => return "Setup profile photo"
            case "SETUP_LOGIN_EMAIL" => return "Setup login email"
            case "SETUP_LOGIN_EMAIL_NOSKIP" => return "Setup login email (required)"
            case "SETUP_PASSKEY" => return "Setup passkey"
            case "CONVERT_GIGAGROUP" => return "Convert to Gigagroup"
            case "PREMIUM_ANNUAL_DISCOUNT" => return "Annual Premium discount"
            case "STARS_PURCHASE" => return "Purchase Stars"
            case "ENABLE_SENSITIVE_CONTENT" => return "Enable sensitive content"
            case "DISABLE_SENSITIVE_CONTENT" => return "Disable sensitive content"
            case _ => return id
        }
    }

    private func peerSuggestionIdToTitle(id: String): String {
        match (id) {
            case "CONVERT_GIGAGROUP" => return "Convert to Gigagroup"
            case _ => return id
        }
    }
}

/**
 * UI 可用的建议项
 */
public class NoticeSuggestion {
    public var id: String = ""
    public var title: String = ""
}
