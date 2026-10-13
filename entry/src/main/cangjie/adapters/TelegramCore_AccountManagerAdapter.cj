package ohos_app_cangjie_entry.adapters

import std.collection.ArrayList
import ohos_app_cangjie_entry.core.storage.{StoredUserData, StoredSessionData, AccountInfo}
import ohos_app_cangjie_entry.core.services.getTelegramCore_AccountManagerService
import ohos_app_cangjie_entry.services.{
    getSettingsService,
    ProfilePhotoResult,
    BirthdayData,
    TimezoneInfo,
    BusinessWorkHoursData,
    BusinessWeeklyOpenData,
    BusinessLocationData,
    BusinessRecipientsData,
    BusinessGreetingMessageData,
    BusinessAwayMessageData,
    BusinessAwayMessageScheduleData,
    BusinessIntroData,
    ConnectedBotData,
    BotBusinessConnectionData,
    BusinessChatLinkData,
    QuickReplyShortcutData
}
/**
 * TelegramCore 账户管理器适配层 — 对外接口
 *
 * 对应 Telegram-iOS TelegramCore/Account 对外 API
 * 为上层业务提供 isLoggedIn、logout、getCurrentUserData 等易用接口
 */
private var _adapterInstance: Option<TelegramCore_AccountManagerAdapter> = None

public func getTelegramCore_AccountManagerAdapter(): TelegramCore_AccountManagerAdapter {
    match (_adapterInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCore_AccountManagerAdapter()
            _adapterInstance = Some(inst)
            return inst
    }
}

public class TelegramCore_AccountManagerAdapter {
    public init() {}

    /**
     * 是否已登录
     */
    public func isLoggedIn(): Bool {
        return getTelegramCore_AccountManagerService().isLoggedIn()
    }

    /**
     * 获取当前 DC ID
     */
    public func getCurrentDcId(): Int64 {
        return getTelegramCore_AccountManagerService().getCurrentDcId()
    }

    /**
     * 获取当前用户数据
     */
    public func getCurrentUserData(): Option<StoredUserData> {
        return getTelegramCore_AccountManagerService().getCurrentUserData()
    }

    /**
     * 获取当前会话数据
     */
    public func getSessionData(): Option<StoredSessionData> {
        return getTelegramCore_AccountManagerService().getSessionData()
    }

    /**
     * 获取账户中间状态
     * 0=unauthorized, 1=awaitingCode, 2=awaitingPassword, 3=authorized
     */
    public func getAccountIntermediateState(): Int32 {
        return getTelegramCore_AccountManagerService().getAccountIntermediateState()
    }

    /**
     * 获取当前账户信息（userId, firstName, lastName, phone, username）
     */
    public func getCurrentAccountInfo(): Option<AccountInfo> {
        return getTelegramCore_AccountManagerService().getCurrentAccountInfo()
    }

    /**
     * 切换到指定账户
     * 单账户模式下：仅当 userId 与当前用户一致时返回 true
     */
    public func switchToAccount(userId: Int64): Bool {
        return getTelegramCore_AccountManagerService().switchToAccount(userId)
    }

    /**
     * 登出（完整清理：RealAuthService + NetworkService.resetGlobalClient）
     */
    public func logout(): Unit {
        getTelegramCore_AccountManagerService().logout()
    }

    // ==================== P2-153: AccountData core gaps ====================

    /**
     * Gap 1: uploadAndSetProfilePhoto
     * Uploads image bytes and sets as current profile photo.
     * iOS ref: uploadProfilePhoto / Account.swift
     * TL: photos.uploadProfilePhoto#0388a3b5 + photos.updateProfilePhoto#09e82039
     */
    public func uploadAndSetProfilePhoto(imageBytes: Array<Byte>, fileName: String): ProfilePhotoResult {
        return getSettingsService().uploadAndSetProfilePhoto(imageBytes, fileName)
    }

    /**
     * Gap 1b: deleteProfilePhotos
     * Deletes one or more profile photos.
     * iOS ref: deletePhoto / Account.swift
     * TL: photos.deletePhotos#87cf7f2f
     */
    public func deleteProfilePhotos(
        photoIds: ArrayList<Int64>,
        accessHashes: ArrayList<Int64>,
        fileReferences: ArrayList<Array<Byte>>
    ): ArrayList<Int64> {
        return getSettingsService().deleteProfilePhotos(photoIds, accessHashes, fileReferences)
    }

    /**
     * Gap 2: updateBirthday
     * Sets or clears the user's birthday (None = clear).
     * iOS ref: updateBirthday / AccountData.swift
     * TL: account.updateBirthday#cc6e0c11
     */
    public func updateBirthday(birthday: Option<BirthdayData>): Bool {
        return getSettingsService().updateBirthday(birthday)
    }

    /**
     * Gap 2b: getCachedBirthday — returns locally persisted birthday.
     */
    public func getCachedBirthday(): Option<BirthdayData> {
        return getSettingsService().getCachedBirthday()
    }

    /**
     * Gap 3a: updateNameColor
     * Updates name/profile color and optional background emoji.
     * iOS ref: updateNameColor / AccountData.swift
     * TL: account.updateColor#7cefa15d
     */
    public func updateNameColor(forProfile: Bool, color: Int32, backgroundEmojiId: Int64): Bool {
        return getSettingsService().updateNameColor(forProfile, color, backgroundEmojiId)
    }

    /**
     * Gap 3b: updateEmojiStatus
     * Sets or clears the emoji status (documentId=0 = clear).
     * iOS ref: updateEmojiStatus / AccountData.swift
     * TL: account.updateEmojiStatus#fbd3de6b
     */
    public func updateEmojiStatus(documentId: Int64, until: Int32): Bool {
        return getSettingsService().updateEmojiStatus(documentId, until)
    }

    /**
     * Gap 4: updatePersonalChannel
     * Sets or clears the personal channel shown on profile.
     * channelId=0 → clear.
     * iOS ref: updatePersonalChannel / AccountData.swift
     * TL: account.updatePersonalChannel#d94305e0
     */
    public func updatePersonalChannel(channelId: Int64, accessHash: Int64): Bool {
        return getSettingsService().updatePersonalChannel(channelId, accessHash)
    }

    /**
     * Gap 5: toggleSponsoredMessages
     * Enables or disables sponsored messages (Premium).
     * iOS ref: toggleAdMessages / AccountData.swift
     * TL: account.toggleSponsoredMessages#b9d9a38d
     */
    public func toggleSponsoredMessages(enabled: Bool): Bool {
        return getSettingsService().toggleSponsoredMessages(enabled)
    }

    /**
     * Gap 6: getTimezonesList
     * Returns full timezone list with incremental hash caching.
     * iOS ref: getTimezones / TimezoneList.swift
     * TL: help.getTimezonesList#49b30240
     */
    public func getTimezonesList(): ArrayList<TimezoneInfo> {
        return getSettingsService().getTimezonesList()
    }

    // ==================== P2-153b: Telegram Business Account Suite ====================

    /**
     * Business-1: updateBusinessWorkHours
     * Sets or clears the business work hours schedule.
     * iOS ref: updateAccountBusinessHours in TelegramEngineAccountData.swift:185
     * TL: account.updateBusinessWorkHours#4b00e066
     * workHours=None clears the schedule.
     */
    public func updateBusinessWorkHours(workHours: Option<BusinessWorkHoursData>): Bool {
        return getSettingsService().updateBusinessWorkHours(workHours)
    }

    /**
     * Business-2: updateBusinessLocation
     * Sets or clears the business address + geo coordinates.
     * iOS ref: updateAccountBusinessLocation in TelegramEngineAccountData.swift:208
     * TL: account.updateBusinessLocation#9e6b131a
     * location=None clears the location.
     */
    public func updateBusinessLocation(location: Option<BusinessLocationData>): Bool {
        return getSettingsService().updateBusinessLocation(location)
    }

    /**
     * Business-3: updateBusinessGreetingMessage
     * Sets or clears the business greeting message (auto-reply for new/inactive chats).
     * iOS ref: _internal_updateBusinessGreetingMessage in QuickReplyMessages.swift:951
     * TL: account.updateBusinessGreetingMessage#66cdafc4
     * greeting=None clears the greeting.
     */
    public func updateBusinessGreetingMessage(greeting: Option<BusinessGreetingMessageData>): Bool {
        return getSettingsService().updateBusinessGreetingMessage(greeting)
    }

    /**
     * Business-4: updateBusinessAwayMessage
     * Sets or clears the business away message (auto-reply outside hours / offline).
     * iOS ref: _internal_updateBusinessAwayMessage in QuickReplyMessages.swift:993
     * TL: account.updateBusinessAwayMessage#a26a7fa5
     * away=None clears the away message.
     */
    public func updateBusinessAwayMessage(away: Option<BusinessAwayMessageData>): Bool {
        return getSettingsService().updateBusinessAwayMessage(away)
    }

    /**
     * Business-5: updateBusinessIntro
     * Sets or clears the business profile intro (title + description + optional sticker).
     * iOS ref: _internal_updateBusinessIntro in QuickReplyMessages.swift:1051
     * TL: account.updateBusinessIntro#a614d034
     * intro=None clears the intro.
     */
    public func updateBusinessIntro(intro: Option<BusinessIntroData>): Bool {
        return getSettingsService().updateBusinessIntro(intro)
    }

    /**
     * Business-6a: updateConnectedBot
     * Connects or disconnects a bot from the business account.
     * iOS ref: _internal_setAccountConnectedBot in QuickReplyMessages.swift:1249
     * TL: account.updateConnectedBot#66a08c7e
     * bot=None removes the connected bot.
     */
    public func updateConnectedBot(bot: Option<ConnectedBotData>): Bool {
        return getSettingsService().updateConnectedBot(bot)
    }

    /**
     * Business-6b: getBotBusinessConnection
     * Fetches current connected bot connection info by connection ID.
     * iOS ref: confirmBotConnectionReview in TelegramEngineAccountData.swift:285
     * TL: account.getBotBusinessConnection#76a86270
     */
    public func getBotBusinessConnection(connectionId: String): Option<BotBusinessConnectionData> {
        return getSettingsService().getBotBusinessConnection(connectionId)
    }

    /**
     * Business-7a: createBusinessChatLink
     * Creates a new business chat link with a preset message.
     * iOS ref: _internal_createBusinessChatLink in TelegramEngineAccountData.swift:293
     * TL: account.createBusinessChatLink#8851e68e
     */
    public func createBusinessChatLink(message: String, title: String): Option<BusinessChatLinkData> {
        return getSettingsService().createBusinessChatLink(message, title)
    }

    /**
     * Business-7b: editBusinessChatLink
     * Edits an existing business chat link (identified by slug).
     * iOS ref: _internal_editBusinessChatLink in TelegramEngineAccountData.swift:297
     * TL: account.editBusinessChatLink#8c3410af
     */
    public func editBusinessChatLink(slug: String, message: String, title: String): Option<BusinessChatLinkData> {
        return getSettingsService().editBusinessChatLink(slug, message, title)
    }

    /**
     * Business-7c: deleteBusinessChatLink
     * Deletes a business chat link by its slug.
     * iOS ref: _internal_deleteBusinessChatLink in TelegramEngineAccountData.swift:301
     * TL: account.deleteBusinessChatLink#60073674
     */
    public func deleteBusinessChatLink(slug: String): Bool {
        return getSettingsService().deleteBusinessChatLink(slug)
    }

    /**
     * Business-7d: getBusinessChatLinks
     * Fetches all business chat links for the current account.
     * iOS ref: _internal_refreshBusinessChatLinks in TelegramEngineAccountData.swift:305
     * TL: account.getBusinessChatLinks#6f70dde1
     */
    public func getBusinessChatLinks(): ArrayList<BusinessChatLinkData> {
        return getSettingsService().getBusinessChatLinks()
    }

    /**
     * QuickReply-1: getQuickReplyShortcuts
     * Fetches the list of quick reply shortcuts (incremental with hash).
     * iOS ref: _internal_shortcutMessageList in QuickReplyMessages.swift:728
     * TL: messages.getQuickReplies#d483f2a8
     * hash=0 for full fetch; pass last hash for incremental update.
     * Returns empty list when server says "not modified" (use cached data).
     */
    public func getQuickReplyShortcuts(hash: Int64): ArrayList<QuickReplyShortcutData> {
        return getSettingsService().getQuickReplyShortcuts(hash)
    }

    /**
     * QuickReply-2: editQuickReplyShortcut
     * Renames an existing quick reply shortcut.
     * iOS ref: _internal_editMessageShortcut in QuickReplyMessages.swift:314
     * TL: messages.editQuickReplyShortcut#5c003cef
     */
    public func editQuickReplyShortcut(shortcutId: Int32, shortcut: String): Bool {
        return getSettingsService().editQuickReplyShortcut(shortcutId, shortcut)
    }

    /**
     * QuickReply-3: deleteQuickReplyShortcut
     * Deletes a quick reply shortcut and all its messages.
     * iOS ref: _internal_deleteMessageShortcuts in ManagedCloudChatRemoveMessagesOperations.swift:427
     * TL: messages.deleteQuickReplyShortcut#3cc04740
     */
    public func deleteQuickReplyShortcut(shortcutId: Int32): Bool {
        return getSettingsService().deleteQuickReplyShortcut(shortcutId)
    }

    /**
     * QuickReply-4: reorderQuickReplyShortcuts
     * Reorders quick reply shortcuts to match the given ordered list of shortcut IDs.
     * iOS ref: _internal_reorderMessageShortcuts in QuickReplyMessages.swift
     * TL: messages.reorderQuickReplies#60331907
     */
    public func reorderQuickReplyShortcuts(order: ArrayList<Int32>): Bool {
        return getSettingsService().reorderQuickReplyShortcuts(order)
    }

    /**
     * QuickReply-5: getQuickReplyMessages
     * Fetches messages for a specific quick reply shortcut.
     * iOS ref: messages.getQuickReplyMessages in AccountViewTracker.swift:84
     * TL: messages.getQuickReplyMessages#94a495c3
     * ids=empty to fetch all messages in the shortcut.
     * Returns parsed message count from server response.
     */
    public func getQuickReplyMessages(shortcutId: Int32, ids: ArrayList<Int32>): Int32 {
        return getSettingsService().getQuickReplyMessages(shortcutId, ids)
    }
}
