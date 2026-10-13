package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import ohos_app_cangjie_entry.core.storage.{getAuthStorage, getAppTheme, getChatBgDisplayPath}
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    AccountGetNotifySettings,
    AccountUpdateNotifySettings,
    AccountResetNotifySettings,
    AccountGetNotifyExceptions,
    TLDeserializer,
    TLConstructors,
    TLSerializer,
    UserResponse,
    ChatResponse,
    PeerResponse
}
import std.collection.HashMap
import std.collection.ArrayList

/**
 * TelegramCoreSettingsService — 设置数据层核心服务
 *
 * 对应 iOS TelegramCore/Sources/Settings 的核心逻辑
 * 职责：
 * - 账户设置：隐私、通知偏好（全局 users/chats/broadcasts/stories/reactions/contactJoined）
 * - 应用偏好：外观（主题、字体、聊天壁纸）、下载、语言等
 * - 本地读写 via AuthStorage
 * - 与服务器同步 via TL 方法（account.getNotifySettings, account.updateNotifySettings,
 *   account.getReactionsNotifySettings, account.setReactionsNotifySettings,
 *   account.getContactSignUpNotification, account.setContactSignUpNotification）
 */
private var _telegramCoreSettingsServiceInstance: Option<TelegramCoreSettingsService> = None

public func getTelegramCoreSettingsService(): TelegramCoreSettingsService {
    match (_telegramCoreSettingsServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCoreSettingsService()
            _telegramCoreSettingsServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 全局通知设置数据（users/chats/broadcasts）
 * 对应 iOS PeerNotifySettings
 */
public class GlobalNotifySettingsData {
    public var showPreviews: Bool = true
    public var silent: Bool = false
    public var muteUntil: Int32 = 0
    public var isMuted: Bool = false
    // 0=default, 1=unmuted, 2=muted — per-account story-mute tri-state.
    // 对位源 SyncCore_TelegramPeerNotificationSettings.swift:417-421 Mute.rawValue
    public var storyMute: Int32 = 0
    // 0=default, 1=hide, 2=show — stories hide-sender tri-state.
    // 对位源 SyncCore_TelegramPeerNotificationSettings.swift:417-427 HideSender.rawValue
    public var hideSender: Int32 = 0
}

/**
 * S7-56: reactionsNotifySettings#56e34970 — the ctor of the layer this client speaks
 * (MTProtoConfig.LAYER 214; td telegram_api.tl:1858, no poll_votes_notify_from). iOS pinned
 * 6ad963e5b6 is on layer 228 and uses #71e4ea58 (Api23.swift:369, added with layer 224 in
 * c165cbe434); a 214 connection gets #56e34970 back and must send it, otherwise the reply
 * never matched the parser (switch always Off) and the setter's body was rejected.
 */
let REACTIONS_NOTIFY_SETTINGS_L214: UInt32 = 0x56E34970

/**
 * Reactions 通知设置数据
 * 对应 iOS ReactionsNotifySettings#6d84a71c
 * flags#: messagesNotifyFrom:flags.0?ReactionNotificationsFrom
 *         storiesNotifyFrom:flags.1?ReactionNotificationsFrom
 *         pollVotesNotifyFrom:flags.2?ReactionNotificationsFrom
 *         sound:NotificationSound showPreviews:Bool
 *
 * ReactionNotificationsFrom:
 *   reactionNotificationsFromAll#4b9e22a0 (ctor 1268654752)
 *   reactionNotificationsFromContacts#bac3a61a (ctor -1161583078 = 0xBAC3A61A unsigned)
 */
public class ReactionsNotifySettingsData {
    public var messagesNotifyFromAll: Bool = true
    public var storiesNotifyFromAll: Bool = true
    public var showPreviews: Bool = true
    // flags 位未置 = .nobody（对位 ReactionsNotifySettings flags.0/flags.1 缺省）。
    // 位已置且 ctor 为 0x4B9E22A0 / 0xBAC3A61A 都是非 nobody。
    public var messagesIsNobody: Bool = true
    public var storiesIsNobody: Bool = true

    /** S7-56: iOS PeerReactionNotificationSettings.Sources — 0 nobody, 1 contacts, 2 everyone. */
    public func messagesSource(): Int32 {
        if (this.messagesIsNobody) { return 0 }
        return if (this.messagesNotifyFromAll) { 2 } else { 1 }
    }

    public func storiesSource(): Int32 {
        if (this.storiesIsNobody) { return 0 }
        return if (this.storiesNotifyFromAll) { 2 } else { 1 }
    }
}

/**
 * account.getNotifyExceptions 按 ST4 分桶后的例外计数。
 * 0 表示该桶无例外——调用方必须格式化成空串，禁止 "0 exceptions"。
 */
public class NotificationExceptionCounts {
    public var users: Int32 = 0
    public var groups: Int32 = 0
    public var channels: Int32 = 0
    public var stories: Int32 = 0
}

class NotifyExceptionRow {
    public var peerType: String = ""
    public var peerId: Int64 = 0
    public var muteIsDefault: Bool = true
    public var hasCustomSound: Bool = false
    public var storyIsDefault: Bool = true
}

// Preferences store name for local notification settings (persistent across cold restarts)
let NOTIF_LOCAL_PREFS = "notif_local"
// S3-02: iOS ReactionSettings.quickReaction（默认 👍，Settings → Stickers and Emoji → Quick Reaction）
let REACTION_SETTINGS_PREFS = "reaction_settings"
let KEY_QUICK_REACTION = "quick_reaction"
let KEY_NOTIF_LOCKSCREEN = "notif_display_name_lockscreen"
// diag-suite_settings_notifications-TC-0439-round3.md FIX-B + TC-0441-round4.md F-1：
// 复刻源侧 CounterTagSettings/PeerSummaryCounterTags 位集模型（原 KEY_NOTIF_BADGE_MUTED
// 单一 Bool「是否把静音会话计入角标」是自造语义，源侧本屏无此开关，已删除）。
let KEY_NOTIF_BADGE_TAGS = "notif_badge_include_tags"
let KEY_NOTIF_BADGE_MESSAGES = "notif_badge_count_messages"
// 底层 tag 位（对位 SyncCore_Namespaces.swift:281-293 PeerSummaryCounterTags）
public let BADGE_TAG_CONTACT: Int32 = 8       // 1 << 3
public let BADGE_TAG_NON_CONTACT: Int32 = 16  // 1 << 4
public let BADGE_TAG_GROUP: Int32 = 32        // 1 << 5
public let BADGE_TAG_BOT: Int32 = 128         // 1 << 7
public let BADGE_TAG_CHANNEL: Int32 = 256     // 1 << 8
public let BADGE_TAGS_ALL: Int32 = 440        // 8+16+32+128+256，对位 .all
// In-App Sounds/Vibrate/Preview — local-only (对位 InAppNotificationSettings.swift:30-42),
// 不再走 account.updateNotifySettings 的 silent/show_previews 位（那是 push 层设置，与本地表现无关）。
let KEY_INAPP_PLAY_SOUNDS = "notif_inapp_play_sounds"
let KEY_INAPP_VIBRATE = "notif_inapp_vibrate"
let KEY_INAPP_DISPLAY_PREVIEWS = "notif_inapp_display_previews"
let KEY_INAPP_DISPLAY_ALL_ACCOUNTS = "notif_inapp_display_from_all_accounts"

/**
 * TelegramCoreSettingsService
 * Single instance — badge/lockscreen local prefs persisted via HarmonyOS Preferences.
 */
public class TelegramCoreSettingsService {
    private let storage = getAuthStorage()

    // ==================== 外观设置（本地 AuthStorage） ====================

    public func getAppearanceTheme(): Int32 {
        return this.storage.getAppearanceTheme()
    }

    public func saveAppearanceTheme(theme: Int32): Unit {
        this.storage.saveAppearanceTheme(theme)
        let appTheme = getAppTheme()
        appTheme.applyTheme(theme)
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] Saved theme: ${theme}")
    }

    public func getAppearanceTextSize(): Int32 {
        return this.storage.getAppearanceTextSize()
    }

    public func saveAppearanceTextSize(size: Int32): Unit {
        this.storage.saveAppearanceTextSize(size)
        let appTheme = getAppTheme()
        appTheme.textSize = size
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] Saved textSize: ${size}")
    }

    public func getChatBackground(): String {
        return this.storage.getChatBackground()
    }

    public func saveChatBackground(path: String): Unit {
        this.storage.saveChatBackground(path)
        let appTheme = getAppTheme()
        appTheme.chatBackgroundPath = path
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] Saved chat background: ${path}")
    }

    /**
     * 验证壁纸文件存在且有效，返回可用于 Image 的 URI。
     * 对应 WallpaperBackgroundNode 的显示逻辑。
     */
    public func getVerifiedChatBackgroundUri(): String {
        let path = getChatBgDisplayPath()
        if (path.size == 0) { return "" }
        try {
            let exists = FileIo.access(path)
            if (exists) {
                let st = FileIo.stat(path)
                if (st.size > 1000) {
                    return "file://" + path
                }
            }
        } catch (_e: Exception) {}
        return ""
    }

    /**
     * 默认聊天背景色（无壁纸时使用）
     */
    public func getChatBackgroundFallbackColor(): UInt32 {
        return 0xE8E6DF
    }

    public func getAnimationEnabled(): Bool {
        return this.storage.getAnimationEnabled()
    }

    public func saveAnimationEnabled(enabled: Bool): Unit {
        this.storage.saveAnimationEnabled(enabled)
        let appTheme = getAppTheme()
        appTheme.animationEnabled = enabled
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] Saved animation: ${enabled}")
    }

    // ==================== 语言设置（本地 AuthStorage） ====================

    public func getLangCode(): String {
        return this.storage.getLangCode()
    }

    public func saveLangCode(code: String): Unit {
        this.storage.saveLangCode(code)
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] Saved langCode: ${code}")
    }

    // ==================== 下载设置（本地 AuthStorage） ====================

    public func getDownloadPhotos(): Bool {
        return this.storage.getDownloadPhotos()
    }

    public func saveDownloadPhotos(enabled: Bool): Unit {
        this.storage.saveDownloadPhotos(enabled)
    }

    public func getDownloadVideos(): Bool {
        return this.storage.getDownloadVideos()
    }

    public func saveDownloadVideos(enabled: Bool): Unit {
        this.storage.saveDownloadVideos(enabled)
    }

    public func getDownloadFiles(): Bool {
        return this.storage.getDownloadFiles()
    }

    public func saveDownloadFiles(enabled: Bool): Unit {
        this.storage.saveDownloadFiles(enabled)
    }

    public func getSaveToGallery(): Bool {
        return this.storage.getSaveToGallery()
    }

    public func saveSaveToGallery(enabled: Bool): Unit {
        this.storage.saveSaveToGallery(enabled)
    }

    public func getDataSaving(): Bool {
        return this.storage.getDataSaving()
    }

    public func saveDataSaving(enabled: Bool): Unit {
        this.storage.saveDataSaving(enabled)
    }

    // ==================== 其他本地设置 ====================

    public func getArchiveKeepUnmuted(): Bool {
        return this.storage.getArchiveKeepUnmuted()
    }

    public func saveArchiveKeepUnmuted(enabled: Bool): Unit {
        this.storage.saveArchiveKeepUnmuted(enabled)
    }

    public func getPowerSaving(): Bool {
        return this.storage.getPowerSaving()
    }

    public func savePowerSaving(enabled: Bool): Unit {
        this.storage.savePowerSaving(enabled)
    }

    // ==================== 省电 — 阈值 + 各项节能开关 ====================

    public func getPsThreshold(): Int32 {
        return this.storage.getPsThreshold()
    }
    public func savePsThreshold(value: Int32): Unit {
        this.storage.savePsThreshold(value)
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] ps threshold: ${value}")
    }

    public func getPsAutoplayVideo(): Bool { return this.storage.getPsAutoplayVideo() }
    public func savePsAutoplayVideo(v: Bool): Unit {
        this.storage.savePsAutoplayVideo(v)
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] ps autoplayVideo: ${v}")
    }

    public func getPsAutoplayGif(): Bool { return this.storage.getPsAutoplayGif() }
    public func savePsAutoplayGif(v: Bool): Unit {
        this.storage.savePsAutoplayGif(v)
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] ps autoplayGif: ${v}")
    }

    public func getPsLoopStickers(): Bool { return this.storage.getPsLoopStickers() }
    public func savePsLoopStickers(v: Bool): Unit {
        this.storage.savePsLoopStickers(v)
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] ps loopStickers: ${v}")
    }

    public func getPsLoopEmoji(): Bool { return this.storage.getPsLoopEmoji() }
    public func savePsLoopEmoji(v: Bool): Unit {
        this.storage.savePsLoopEmoji(v)
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] ps loopEmoji: ${v}")
    }

    public func getPsFullTranslucency(): Bool { return this.storage.getPsFullTranslucency() }
    public func savePsFullTranslucency(v: Bool): Unit {
        this.storage.savePsFullTranslucency(v)
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] ps fullTranslucency: ${v}")
    }

    public func getPsExtendBgWork(): Bool { return this.storage.getPsExtendBgWork() }
    public func savePsExtendBgWork(v: Bool): Unit {
        this.storage.savePsExtendBgWork(v)
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] ps extendBgWork: ${v}")
    }

    public func getPsAutodownloadBg(): Bool { return this.storage.getPsAutodownloadBg() }
    public func savePsAutodownloadBg(v: Bool): Unit {
        this.storage.savePsAutodownloadBg(v)
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] ps autodownloadBg: ${v}")
    }

    // ==================== 全局通知设置（服务器同步） ====================

    /**
     * 获取指定类型的全局通知设置（account.getNotifySettings）
     * iOS: Api42.swift:680 — account.getNotifySettings#12b3ad31 peer:InputNotifyPeer = PeerNotifySettings
     * @param peerType "users" | "chats" | "broadcasts"
     */
    public func getGlobalNotifySettings(peerType: String): GlobalNotifySettingsData {
        let result = GlobalNotifySettingsData()
        try {
            let client = getMTProtoClient()
            let req = AccountGetNotifySettings()
            req.peerType = peerType
            let data = client.sendRequest(req.toBytes())
            this.parsePeerNotifySettings(data, result)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] getGlobalNotifySettings error: ${e}")
        }
        return result
    }

    /**
     * 更新指定类型的全局通知设置（account.updateNotifySettings）
     * iOS: Api42.swift:1866 — account.updateNotifySettings#84be5b93 peer:InputNotifyPeer settings:InputPeerNotifySettings = Bool
     * @param peerType "users" | "chats" | "broadcasts"
     * @param muteUntil 0=取消静音, 2147483647=永久静音
     */
    public func updateGlobalNotifySettings(peerType: String, muteUntil: Int32, showPreviews: Bool, silent: Bool): Bool {
        try {
            let client = getMTProtoClient()
            let req = AccountUpdateNotifySettings()
            req.peerType = peerType
            req.muteUntil = muteUntil
            req.showPreviews = showPreviews
            req.silent = silent
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size >= 4) {
                let d = TLDeserializer(responseData)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errorCode = d.readInt32()
                    let errorMsg = d.readString()
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] updateGlobalNotifySettings error: ${errorCode} ${errorMsg}")
                    return false
                }
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] Updated global notify for ${peerType}: muteUntil=${muteUntil}")
                return true
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] updateGlobalNotifySettings exception: ${e}")
        }
        return false
    }

    /**
     * S7-64：account.resetNotifySettings（iOS NotificationsAndSounds.swift Reset All Notifications →
     * resetPeerNotificationSettings）。服务端清掉所有 per-peer 通知设置与例外，全局项回默认。
     */
    public func resetNotifySettings(): Bool {
        try {
            let responseData = getMTProtoClient().sendRequest(AccountResetNotifySettings().toBytes())
            if (responseData.size < 4) {
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] resetNotifySettings: empty response")
                return false
            }
            let d = TLDeserializer(responseData)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errorCode = d.readInt32()
                let errorMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] resetNotifySettings error: ${errorCode} ${errorMsg}")
                return false
            }
            let ok = ctor == TLConstructors.BOOL_TRUE
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] resetNotifySettings ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] resetNotifySettings exception: ${e}")
            return false
        }
    }

    private func parsePeerNotifySettings(data: Array<Byte>, out: GlobalNotifySettingsData): Unit {
        if (data.size < 8) { return }
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let _ = d.readString()
            return
        }
        if (constructor == 0x99622c0c) {
            let flags = d.readInt32()
            if ((flags & 1) != 0) {
                let boolVal = d.readUInt32()
                out.showPreviews = (boolVal == 0x997275b5)
            }
            if ((flags & 2) != 0) {
                let boolVal = d.readUInt32()
                out.silent = (boolVal == 0x997275b5)
            }
            if ((flags & 4) != 0) {
                out.muteUntil = d.readInt32()
                out.isMuted = out.muteUntil > 0
            }
            // iosSound / androidSound / otherSound — bits 3-5. Must consume before
            // storiesMuted (bit 6) / storiesHideSender (bit 7) or the cursor drifts
            // (TLDialogs.skipPeerNotifySettings).
            if ((flags & 8) != 0) { this.skipNotifySound(d) }
            if ((flags & 16) != 0) { this.skipNotifySound(d) }
            if ((flags & 32) != 0) { this.skipNotifySound(d) }
            if ((flags & 64) != 0) {
                let boolVal = d.readUInt32()
                out.storyMute = if (boolVal == 0x997275b5) { 2 } else { 1 }
            } else {
                out.storyMute = 0
            }
            if ((flags & 128) != 0) {
                let boolVal = d.readUInt32()
                out.hideSender = if (boolVal == 0x997275b5) { 1 } else { 2 }
            } else {
                out.hideSender = 0
            }
        }
    }

    private func skipNotifySound(d: TLDeserializer): Unit {
        let constructor = d.readUInt32()
        if (constructor == 0x97e8bebe) {
        } else if (constructor == 0x6f0c34df) {
        } else if (constructor == 0x830b9ae4) {
            let _ = d.readString()
            let _ = d.readString()
        } else if (constructor == 0xff6c8049) {
            let _ = d.readInt64()
        }
    }

    /**
     * Write privateChats.storySettings.mute + hideSender via account.updateNotifySettings
     * (inputNotifyUsers). Preserves muteUntil / showPreviews / silent so a stories
     * toggle does not wipe the users peer-notify bits.
     * storyMute: 0=default (flag omitted) / 1=unmuted (boolFalse) / 2=muted (boolTrue)
     * hideSender: 0=default (flag omitted) / 1=hide (boolTrue) / 2=show (boolFalse)
     */
    public func updateUsersStorySettings(
        muteUntil: Int32,
        showPreviews: Bool,
        silent: Bool,
        storyMute: Int32,
        hideSender: Int32
    ): Bool {
        try {
            let client = getMTProtoClient()
            let s = TLSerializer()
            s.writeUInt32(0x84be5b93)
            s.writeUInt32(0x193b4417)
            s.writeUInt32(0xcacb6ae2)
            var flags: Int32 = 1 | 2 | 4
            if (storyMute != 0) {
                flags = flags | 64
            }
            if (hideSender != 0) {
                flags = flags | 128
            }
            s.writeInt32(flags)
            if (showPreviews) {
                s.writeUInt32(0x997275b5)
            } else {
                s.writeUInt32(0xbc799737)
            }
            if (silent) {
                s.writeUInt32(0x997275b5)
            } else {
                s.writeUInt32(0xbc799737)
            }
            s.writeInt32(muteUntil)
            if (storyMute != 0) {
                if (storyMute == 2) {
                    s.writeUInt32(0x997275b5)
                } else {
                    s.writeUInt32(0xbc799737)
                }
            }
            if (hideSender != 0) {
                if (hideSender == 1) {
                    s.writeUInt32(0x997275b5)
                } else {
                    s.writeUInt32(0xbc799737)
                }
            }
            let responseData = client.sendRequest(s.getBytes())
            if (responseData.size >= 4) {
                let d = TLDeserializer(responseData)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errorCode = d.readInt32()
                    let errorMsg = d.readString()
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] updateUsersStorySettings error: ${errorCode} ${errorMsg}")
                    return false
                }
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] Updated users storySettings mute=${storyMute} hideSender=${hideSender}")
                return true
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] updateUsersStorySettings exception: ${e}")
        }
        return false
    }

    // ==================== Reactions 通知设置（服务器同步） ====================

    /**
     * 获取 reactions 通知设置
     * iOS: account.getReactionsNotifySettings (appendInt32(115172684) = 0x06DD654C) → ReactionsNotifySettings
     * ReactionsNotifySettings ctor on layer 214: 0x56E34970 (see REACTIONS_NOTIFY_SETTINGS_L214)
     *   flags:# messagesNotifyFrom:flags.0?ReactionNotificationsFrom
     *   storiesNotifyFrom:flags.1?ReactionNotificationsFrom
     *   pollVotesNotifyFrom:flags.2?ReactionNotificationsFrom
     *   sound:NotificationSound showPreviews:Bool
     * ReactionNotificationsFrom:
     *   reactionNotificationsFromAll     0x4B9E22A0 = 1268654752
     *   reactionNotificationsFromContacts 0xBAC3A61A = 3133384218 (Int32=-1161583078)
     */
    public func getReactionsNotifySettings(): ReactionsNotifySettingsData {
        let result = ReactionsNotifySettingsData()
        try {
            let client = getMTProtoClient()
            let s = TLSerializer()
            s.writeUInt32(0x06DD654C)
            let data = client.sendRequest(s.getBytes())
            this.parseReactionsNotifySettings(data, result)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] getReactionsNotifySettings error: ${e}")
        }
        return result
    }

    /**
     * 更新 reactions 通知设置
     * iOS: account.setReactionsNotifySettings (appendInt32(829220168) = 0x316CE548) → ReactionsNotifySettings
     *
     * ReactionsNotifySettings inner serialize (boxed):
     *   ctor 0x56E34970 (layer 214), flags(int32), [messagesNotifyFrom flags.0], [storiesNotifyFrom flags.1],
     *   [pollVotesNotifyFrom flags.2], sound (boxed NotificationSound), showPreviews (boxed Bool)
     * flags bits: 0=messagesNotifyFrom present, 1=storiesNotifyFrom present, 2=pollVotesNotifyFrom present
     * We set bits 0+1 (messages + stories) → flags = 3
     * sound = notificationSoundDefault ctor 0x97E8BEBE (appendInt32(-1746354498) unsigned)
     */
    public func setReactionsNotifySettings(messagesFromAll: Bool, storiesFromAll: Bool, showPreviews: Bool): Bool {
        try {
            let client = getMTProtoClient()
            let s = TLSerializer()
            s.writeUInt32(0x316CE548)
            s.writeUInt32(REACTIONS_NOTIFY_SETTINGS_L214)
            let flags: Int32 = 3
            s.writeInt32(flags)
            if (messagesFromAll) {
                s.writeUInt32(0x4B9E22A0)
            } else {
                s.writeUInt32(0xBAC3A61A)
            }
            if (storiesFromAll) {
                s.writeUInt32(0x4B9E22A0)
            } else {
                s.writeUInt32(0xBAC3A61A)
            }
            s.writeUInt32(0x97E8BEBE)
            if (showPreviews) {
                s.writeUInt32(TLConstructors.BOOL_TRUE)
            } else {
                s.writeUInt32(TLConstructors.BOOL_FALSE)
            }
            let responseData = client.sendRequest(s.getBytes())
            if (responseData.size >= 4) {
                let d = TLDeserializer(responseData)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errorCode = d.readInt32()
                    let errorMsg = d.readString()
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] setReactionsNotifySettings error: ${errorCode} ${errorMsg}")
                    return false
                }
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] Updated reactionsNotifySettings: messagesFromAll=${messagesFromAll}, storiesFromAll=${storiesFromAll}")
                return true
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] setReactionsNotifySettings exception: ${e}")
        }
        return false
    }

    /**
     * S7-56: account.setReactionsNotifySettings#316ce548 with reactionsNotifySettings#56e34970 (layer 214)
     * (iOS Api23.swift:369-390): messages_notify_from flags.0 / stories_notify_from flags.1 are
     * omitted for "nobody" (iOS ManagedGlobalNotificationSettings apiInputReactionsNotifySettings),
     * reactionNotificationsFromContacts#bac3a61a / FromAll#4b9e22a0 otherwise; show_previews
     * carries "Show Sender's Name" (hideSender != .hide).
     * Sources: 0 nobody, 1 contacts, 2 everyone.
     */
    public func setReactionsNotifySources(messages: Int32, stories: Int32, showPreviews: Bool): Bool {
        try {
            let s = TLSerializer()
            s.writeUInt32(0x316CE548)
            s.writeUInt32(REACTIONS_NOTIFY_SETTINGS_L214)
            var flags: Int32 = 0
            if (messages != 0) { flags = flags | 1 }
            if (stories != 0) { flags = flags | 2 }
            s.writeInt32(flags)
            if (messages != 0) { s.writeUInt32(if (messages == 2) { 0x4B9E22A0 } else { 0xBAC3A61A }) }
            if (stories != 0) { s.writeUInt32(if (stories == 2) { 0x4B9E22A0 } else { 0xBAC3A61A }) }
            s.writeUInt32(0x97E8BEBE)
            s.writeUInt32(if (showPreviews) { TLConstructors.BOOL_TRUE } else { TLConstructors.BOOL_FALSE })
            let responseData = getMTProtoClient().sendRequest(s.getBytes())
            if (responseData.size < 4) { return false }
            let d = TLDeserializer(responseData)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errorCode = d.readInt32()
                let errorMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] setReactionsNotifySources error: ${errorCode} ${errorMsg}")
                return false
            }
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] reactions notify: messages=${messages} stories=${stories} previews=${showPreviews}")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] setReactionsNotifySources exception: ${e}")
            return false
        }
    }

    private func parseReactionsNotifySettings(data: Array<Byte>, out: ReactionsNotifySettingsData): Unit {
        if (data.size < 8) { return }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let _ = d.readString()
            return
        }
        if (ctor == REACTIONS_NOTIFY_SETTINGS_L214 || ctor == 0x71E4EA58) {
            let flags = d.readInt32()
            // 位未置 = .nobody，不是 default true。0x4B9E22A0 / 0xBAC3A61A 都是非 nobody。
            if ((flags & 1) != 0) {
                let msgCtor = d.readUInt32()
                out.messagesNotifyFromAll = (msgCtor == 0x4B9E22A0)
                out.messagesIsNobody = false
            } else {
                out.messagesNotifyFromAll = false
                out.messagesIsNobody = true
            }
            if ((flags & 2) != 0) {
                let storyCtor = d.readUInt32()
                out.storiesNotifyFromAll = (storyCtor == 0x4B9E22A0)
                out.storiesIsNobody = false
            } else {
                // Reactions 副标题/On 用 storiesIsNobody；Stories 行仍读 storiesNotifyFromAll
                //（本 case 不重开 stories 三态 / C2）。
                out.storiesIsNobody = true
            }
            // poll_votes_notify_from (flags.2) exists only in the layer-224+ ctor 0x71E4EA58.
            if (ctor == 0x71E4EA58 && (flags & 4) != 0) { let _ = d.readUInt32() }
            // sound:NotificationSound, then show_previews:Bool.
            try {
                let soundCtor = d.readUInt32()
                if (soundCtor == 0x830B9AE4) {
                    let _ = d.readString()
                    let _ = d.readString()
                } else if (soundCtor == 0xFF6C8049) {
                    let _ = d.readInt64()
                }
                out.showPreviews = d.readUInt32() == TLConstructors.BOOL_TRUE
            } catch (_e: Exception) {}
        }
    }

    /**
     * account.getNotifyExceptions#53577479（flags=1<<1，不传 peer）。
     * 解析 Updates 里的 updateNotifySettings#bec268ef + notifyPeer#9fd40bd8，
     * 按 NotificationsAndSoundsController.swift:790-825 ST4 分桶。
     */
    public func fetchNotificationExceptions(): NotificationExceptionCounts {
        let result = NotificationExceptionCounts()
        try {
            let client = getMTProtoClient()
            let req = AccountGetNotifyExceptions()
            let data = client.sendRequest(req.toBytes())
            this.parseNotifyExceptionsUpdates(data, result)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] fetchNotificationExceptions error: ${e}")
        }
        Hilog.info(0, "CjTelegram",
            "[TelegramCoreSettings] fetchNotificationExceptions users=${result.users} groups=${result.groups} channels=${result.channels} stories=${result.stories}")
        return result
    }

    private func parseNotifyExceptionsUpdates(data: Array<Byte>, out: NotificationExceptionCounts): Unit {
        if (data.size < 4) { return }
        let d = TLDeserializer(data)
        let envelopeCtor = d.readUInt32()
        if (envelopeCtor == TLConstructors.RPC_ERROR || envelopeCtor == 0x2144ca19) {
            let _ = d.readInt32()
            let _ = d.readString()
            return
        }
        let rows = ArrayList<NotifyExceptionRow>()
        if (envelopeCtor == 0x78d4dec1) {
            this.collectOneNotifyExceptionUpdate(d, rows)
            this.bucketNotifyExceptions(rows, HashMap<Int64, String>(), HashMap<Int64, Bool>(),
                HashMap<Int64, String>(), HashMap<Int64, Bool>(), out)
            return
        }
        if (envelopeCtor != 0x74ae4240 && envelopeCtor != 0x725b04c3) {
            return
        }
        let updVecCtor = d.readUInt32()
        if (updVecCtor != TLConstructors.VECTOR) { return }
        let updCount = d.readInt32()
        var ui: Int32 = 0
        var parseOk = true
        while (ui < updCount) {
            if (!this.collectOneNotifyExceptionUpdate(d, rows)) {
                parseOk = false
                break
            }
            ui = ui + 1
        }
        if (!parseOk) { return }

        let userNames = HashMap<Int64, String>()
        let userIsSelf = HashMap<Int64, Bool>()
        let chatTitles = HashMap<Int64, String>()
        let chatIsBroadcast = HashMap<Int64, Bool>()
        let selfId = getCurrentUserId()
        if (selfId != 0) {
            userIsSelf.add(selfId, true)
        }

        let usersVecCtor = d.readUInt32()
        if (usersVecCtor != TLConstructors.VECTOR) { return }
        let usersCount = d.readInt32()
        var uj: Int32 = 0
        while (uj < usersCount) {
            let user = UserResponse.deserializeBoxed(d)
            if (user.isSelf && user.id != 0) {
                if (!userIsSelf.contains(user.id)) {
                    userIsSelf.add(user.id, true)
                }
            }
            if (!user.isEmpty && user.id != 0) {
                let name = this.userDisplayName(user)
                if (name.size > 0 && !userNames.contains(user.id)) {
                    userNames.add(user.id, name)
                }
            }
            uj = uj + 1
        }

        let chatsVecCtor = d.readUInt32()
        if (chatsVecCtor != TLConstructors.VECTOR) { return }
        let chatsCount = d.readInt32()
        var cj: Int32 = 0
        while (cj < chatsCount) {
            let chat = ChatResponse.deserializeBoxed(d)
            if (chat.id != 0) {
                if (chat.title.size > 0 && !chatTitles.contains(chat.id)) {
                    chatTitles.add(chat.id, chat.title)
                }
                if (!chatIsBroadcast.contains(chat.id)) {
                    chatIsBroadcast.add(chat.id, chat.isBroadcast)
                }
            }
            cj = cj + 1
        }

        this.bucketNotifyExceptions(rows, userNames, userIsSelf, chatTitles, chatIsBroadcast, out)
    }

    private func collectOneNotifyExceptionUpdate(d: TLDeserializer, rows: ArrayList<NotifyExceptionRow>): Bool {
        let updateCtor = d.readUInt32()
        if (updateCtor != 0xbec268ef) {
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] unexpected update 0x${updateCtor} in getNotifyExceptions")
            return false
        }
        let npCtor = d.readUInt32()
        if (npCtor == 0x9fd40bd8) {
            let peer = PeerResponse.deserializeBoxed(d)
            let row = NotifyExceptionRow()
            row.peerType = peer.type_
            row.peerId = peer.id
            this.consumeExceptionNotifySettings(d, row)
            if (peer.id > 0) {
                rows.add(row)
            }
            return true
        }
        if (npCtor == 0xb4c83b4c || npCtor == 0xc007cec3 || npCtor == 0xd612e8ef) {
            let skip = NotifyExceptionRow()
            this.consumeExceptionNotifySettings(d, skip)
            return true
        }
        if (npCtor == 0x226e6308) {
            let topicFlags = d.readInt32()
            let _ = PeerResponse.deserializeBoxed(d)
            if ((topicFlags & 1) != 0) { let _ = d.readInt32() }
            let skip = NotifyExceptionRow()
            this.consumeExceptionNotifySettings(d, skip)
            return true
        }
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] unknown NotifyPeer 0x${npCtor}")
        return false
    }

    private func consumeExceptionNotifySettings(d: TLDeserializer, row: NotifyExceptionRow): Unit {
        let nsCtor = d.readUInt32()
        if (nsCtor != 0x99622c0c) { return }
        let flags = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readUInt32() }
        if ((flags & 2) != 0) { let _ = d.readUInt32() }
        if ((flags & 4) != 0) {
            let _ = d.readInt32()
            row.muteIsDefault = false
        } else {
            row.muteIsDefault = true
        }
        if ((flags & 8) != 0) {
            row.hasCustomSound = this.consumeNotifySoundIsCustom(d)
        }
        if ((flags & 16) != 0) { this.skipNotifySound(d) }
        if ((flags & 32) != 0) { this.skipNotifySound(d) }
        var storyDefault = true
        if ((flags & 64) != 0) {
            let _ = d.readUInt32()
            storyDefault = false
        }
        if ((flags & 128) != 0) {
            let _ = d.readUInt32()
            storyDefault = false
        }
        if ((flags & 256) != 0) {
            if (this.consumeNotifySoundIsCustom(d)) {
                storyDefault = false
            }
        }
        if ((flags & 512) != 0) { this.skipNotifySound(d) }
        if ((flags & 1024) != 0) { this.skipNotifySound(d) }
        row.storyIsDefault = storyDefault
    }

    private func consumeNotifySoundIsCustom(d: TLDeserializer): Bool {
        let constructor = d.readUInt32()
        if (constructor == 0x97e8bebe) {
            return false
        } else if (constructor == 0x6f0c34df) {
            return true
        } else if (constructor == 0x830b9ae4) {
            let _ = d.readString()
            let _ = d.readString()
            return true
        } else if (constructor == 0xff6c8049) {
            let _ = d.readInt64()
            return true
        }
        return true
    }

    private func userDisplayName(user: UserResponse): String {
        var name = user.firstName
        if (user.lastName.size > 0) {
            if (name.size > 0) {
                name = "${name} ${user.lastName}"
            } else {
                name = user.lastName
            }
        }
        if (name.size == 0) { name = user.username }
        if (name.size == 0) { name = user.phone }
        return name
    }

    private func bucketNotifyExceptions(
        rows: ArrayList<NotifyExceptionRow>,
        userNames: HashMap<Int64, String>,
        userIsSelf: HashMap<Int64, Bool>,
        chatTitles: HashMap<Int64, String>,
        chatIsBroadcast: HashMap<Int64, Bool>,
        out: NotificationExceptionCounts
    ): Unit {
        let userSet = HashMap<Int64, Bool>()
        let groupSet = HashMap<Int64, Bool>()
        let channelSet = HashMap<Int64, Bool>()
        let storySet = HashMap<Int64, Bool>()
        for (row in rows) {
            let name = this.exceptionDisplayName(row.peerType, row.peerId, userNames, chatTitles)
            if (name.size == 0) { continue }
            if (row.peerType == "user" && userIsSelf.contains(row.peerId)) { continue }

            if (!row.storyIsDefault) {
                if (!storySet.contains(row.peerId)) {
                    storySet.add(row.peerId, true)
                    out.stories = out.stories + 1
                }
            }

            var countsAsException = false
            if (!row.muteIsDefault) {
                countsAsException = true
            } else if (row.hasCustomSound) {
                countsAsException = true
            }
            if (!countsAsException) { continue }

            if (row.peerType == "user") {
                if (!userSet.contains(row.peerId)) {
                    userSet.add(row.peerId, true)
                    out.users = out.users + 1
                }
            } else if (row.peerType == "channel" && chatIsBroadcast.contains(row.peerId)) {
                var isBroadcast = false
                match (chatIsBroadcast.get(row.peerId)) {
                    case Some(b) => isBroadcast = b
                    case None => isBroadcast = false
                }
                if (isBroadcast) {
                    if (!channelSet.contains(row.peerId)) {
                        channelSet.add(row.peerId, true)
                        out.channels = out.channels + 1
                    }
                } else {
                    if (!groupSet.contains(row.peerId)) {
                        groupSet.add(row.peerId, true)
                        out.groups = out.groups + 1
                    }
                }
            } else {
                if (!groupSet.contains(row.peerId)) {
                    groupSet.add(row.peerId, true)
                    out.groups = out.groups + 1
                }
            }
        }
    }

    private func exceptionDisplayName(
        peerType: String,
        peerId: Int64,
        userNames: HashMap<Int64, String>,
        chatTitles: HashMap<Int64, String>
    ): String {
        if (peerType == "user") {
            if (userNames.contains(peerId)) {
                match (userNames.get(peerId)) {
                    case Some(n) => return n
                    case None => return ""
                }
            }
            return ""
        }
        if (chatTitles.contains(peerId)) {
            match (chatTitles.get(peerId)) {
                case Some(n) => return n
                case None => return ""
            }
        }
        return ""
    }

    // ==================== Contact Joined 通知（服务器同步） ====================

    /**
     * 获取 contact joined Telegram 通知设置
     * iOS: account.getContactSignUpNotification (appendInt32(-1626880216) = 0x9F07C728) → Bool
     * Returns: boolTrue/boolFalse (the "silent" flag)
     * We interpret: server returns true=silent=true → contact notification DISABLED
     * So enabled = (response == boolFalse)
     */
    public func getContactSignUpNotification(): Bool {
        try {
            let client = getMTProtoClient()
            let s = TLSerializer()
            s.writeUInt32(0x9F07C728)
            let data = client.sendRequest(s.getBytes())
            if (data.size >= 4) {
                let d = TLDeserializer(data)
                let boolCtor = d.readUInt32()
                return (boolCtor == TLConstructors.BOOL_FALSE)
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] getContactSignUpNotification error: ${e}")
        }
        return true
    }

    /**
     * 设置 contact joined Telegram 通知
     * iOS: account.setContactSignUpNotification silent:Bool (appendInt32(-806076575) = 0xCFF43F61) → Bool
     * @param enabled true = notify when contact joins Telegram (silent=false)
     */
    public func setContactSignUpNotification(enabled: Bool): Bool {
        try {
            let client = getMTProtoClient()
            let s = TLSerializer()
            s.writeUInt32(0xCFF43F61)
            if (!enabled) {
                s.writeUInt32(TLConstructors.BOOL_TRUE)
            } else {
                s.writeUInt32(TLConstructors.BOOL_FALSE)
            }
            let responseData = client.sendRequest(s.getBytes())
            if (responseData.size >= 4) {
                let d = TLDeserializer(responseData)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errorCode = d.readInt32()
                    let errorMsg = d.readString()
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] setContactSignUpNotification error: ${errorCode} ${errorMsg}")
                    return false
                }
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] setContactSignUpNotification: enabled=${enabled}")
                return true
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] setContactSignUpNotification exception: ${e}")
        }
        return false
    }

    // ==================== 锁屏显示发送者名（Preferences 持久化） ====================

    /**
     * 获取锁屏是否显示发送者名
     * 对应 iOS InAppNotificationSettings.displayNameOnLockscreen
     * 默认 true（与 iOS 默认一致）。从 Preferences 读，冷重启不丢。
     */
    /** S3-02: iOS ReactionSettings.default.quickReaction = .builtin("👍"). */
    public func getQuickReaction(): String {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, REACTION_SETTINGS_PREFS)
                    let val = prefs.get(KEY_QUICK_REACTION, PreferencesValueType.StringData("👍"))
                    match (val) {
                        case PreferencesValueType.StringData(v) => return if (v.size > 0) { v } else { "👍" }
                        case _ => return "👍"
                    }
                } catch (_e: Exception) { return "👍" }
            case None => return "👍"
        }
    }

    public func saveQuickReaction(emoji: String): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, REACTION_SETTINGS_PREFS)
                    prefs.put(KEY_QUICK_REACTION, PreferencesValueType.StringData(emoji))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] quickReaction persisted: ${emoji}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveQuickReaction failed: ${_e}")
                }
            case None => ()
        }
    }

    public func getDisplayNameOnLockscreen(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    let val = prefs.get(KEY_NOTIF_LOCKSCREEN, PreferencesValueType.BoolData(true))
                    match (val) {
                        case PreferencesValueType.BoolData(b) => return b
                        case _ => return true
                    }
                } catch (_e: Exception) { return true }
            case None => return true
        }
    }

    public func saveDisplayNameOnLockscreen(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    prefs.put(KEY_NOTIF_LOCKSCREEN, PreferencesValueType.BoolData(enabled))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] displayNameOnLockscreen persisted: ${enabled}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveDisplayNameOnLockscreen failed: ${_e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveDisplayNameOnLockscreen: no context")
        }
    }

    // ==================== Badge 计数设置（Preferences 持久化） ====================

    /**
     * 获取 badge 计数所用的 tag 位集（对应 iOS InAppNotificationSettings.
     * totalUnreadCountIncludeTags，CounterTagSettings 展开后的完整
     * PeerSummaryCounterTags 位集）。缺省/无 context/异常均返回 BADGE_TAGS_ALL
     * （对位 defaultSettings.totalUnreadCountIncludeTags = .all）。从 Preferences
     * 读，冷重启不丢。整数编码走 PreferencesValueType.Integer（仓内先例
     * services/CallService.cj:2437、services/BadgeService.cj:71，同库 325 处在用）。
     */
    public func getBadgeIncludeTags(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    let val = prefs.get(KEY_NOTIF_BADGE_TAGS, PreferencesValueType.Integer(Int64(BADGE_TAGS_ALL)))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return BADGE_TAGS_ALL
                    }
                } catch (_e: Exception) { return BADGE_TAGS_ALL }
            case None => return BADGE_TAGS_ALL
        }
    }

    public func saveBadgeIncludeTags(tags: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    prefs.put(KEY_NOTIF_BADGE_TAGS, PreferencesValueType.Integer(Int64(tags)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] badgeIncludeTags persisted: ${tags}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveBadgeIncludeTags failed: ${_e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveBadgeIncludeTags: no context")
        }
    }

    /**
     * 按位更新单个 tag（对位 NotificationsAndSoundsController.swift:724-736
     * updateIncludeTag：读当前 summary → 压成两位（CounterTagSettings(summaryTags:)）
     * → 按入参改位（insert/remove）→ 展开回底层位集（toSumaryTags()）→ 写回）。
     * regular 位（.contact/.nonContact/.bot/.group 四位同进同出）本屏无 UI，只能经
     * 本函数的 else 分支被改；不得为它加任何页面入口。
     */
    public func updateBadgeIncludeTag(tagBit: Int32, include: Bool): Unit {
        let current = this.getBadgeIncludeTags()
        var regular = (current & BADGE_TAG_CONTACT) != 0
        var channels = (current & BADGE_TAG_CHANNEL) != 0
        if (tagBit == BADGE_TAG_CHANNEL) {
            channels = include
        } else {
            regular = include
        }
        var out: Int32 = 0
        if (regular) {
            out |= BADGE_TAG_CONTACT
            out |= BADGE_TAG_NON_CONTACT
            out |= BADGE_TAG_BOT
            out |= BADGE_TAG_GROUP
        }
        if (channels) {
            out |= BADGE_TAG_CHANNEL
        }
        this.saveBadgeIncludeTags(out)
    }

    /**
     * 页面侧包装：本屏只暴露 Include Channels 一个动作（对位源侧 UI 层只用
     * contains(.channels) / updateIncludeTag(.channels, value) 两个动作），位集
     * 本体不跨包外泄，调用方无需引入任何 BADGE_TAG_* 常量。
     */
    public func getBadgeIncludeChannels(): Bool {
        return (this.getBadgeIncludeTags() & BADGE_TAG_CHANNEL) != 0
    }

    public func setBadgeIncludeChannels(include: Bool): Unit {
        this.updateBadgeIncludeTag(BADGE_TAG_CHANNEL, include)
    }

    /**
     * 获取 badge 是否按消息数（true=消息数, false=对话数）
     * 对应 iOS InAppNotificationSettings.totalUnreadCountDisplayCategory
     * 默认 true（计消息数，与 iOS 默认一致）。从 Preferences 读，冷重启不丢。
     */
    public func getBadgeCountMessages(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    let val = prefs.get(KEY_NOTIF_BADGE_MESSAGES, PreferencesValueType.BoolData(true))
                    match (val) {
                        case PreferencesValueType.BoolData(b) => return b
                        case _ => return true
                    }
                } catch (_e: Exception) { return true }
            case None => return true
        }
    }

    public func saveBadgeCountMessages(byMessages: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    prefs.put(KEY_NOTIF_BADGE_MESSAGES, PreferencesValueType.BoolData(byMessages))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] badgeCountMessages persisted: ${byMessages}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveBadgeCountMessages failed: ${_e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveBadgeCountMessages: no context")
        }
    }

    // ==================== In-App Sounds/Vibrate/Preview（本地 Preferences 持久化） ====================

    /**
     * In-App Sounds 开关。对应 iOS InAppNotificationSettings.playSounds，默认 true。
     * 本地专属设置，不经服务端同步。从 Preferences 读，冷重启不丢。
     */
    public func getInAppPlaySounds(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    let val = prefs.get(KEY_INAPP_PLAY_SOUNDS, PreferencesValueType.BoolData(true))
                    match (val) {
                        case PreferencesValueType.BoolData(b) => return b
                        case _ => return true
                    }
                } catch (_e: Exception) { return true }
            case None => return true
        }
    }

    public func saveInAppPlaySounds(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    prefs.put(KEY_INAPP_PLAY_SOUNDS, PreferencesValueType.BoolData(enabled))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] inAppPlaySounds persisted: ${enabled}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveInAppPlaySounds failed: ${_e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveInAppPlaySounds: no context")
        }
    }

    /**
     * In-App Vibrate 开关。对应 iOS InAppNotificationSettings.vibrate，默认 false。
     * 本地专属设置，不经服务端同步。从 Preferences 读，冷重启不丢。
     */
    public func getInAppVibrate(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    let val = prefs.get(KEY_INAPP_VIBRATE, PreferencesValueType.BoolData(false))
                    match (val) {
                        case PreferencesValueType.BoolData(b) => return b
                        case _ => return false
                    }
                } catch (_e: Exception) { return false }
            case None => return false
        }
    }

    public func saveInAppVibrate(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    prefs.put(KEY_INAPP_VIBRATE, PreferencesValueType.BoolData(enabled))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] inAppVibrate persisted: ${enabled}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveInAppVibrate failed: ${_e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveInAppVibrate: no context")
        }
    }

    /**
     * In-App Preview（显示消息预览）开关。对应 iOS InAppNotificationSettings.displayPreviews，默认 true。
     * 本地专属设置，不经服务端同步。从 Preferences 读，冷重启不丢。
     */
    public func getInAppDisplayPreviews(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    let val = prefs.get(KEY_INAPP_DISPLAY_PREVIEWS, PreferencesValueType.BoolData(true))
                    match (val) {
                        case PreferencesValueType.BoolData(b) => return b
                        case _ => return true
                    }
                } catch (_e: Exception) { return true }
            case None => return true
        }
    }

    public func saveInAppDisplayPreviews(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    prefs.put(KEY_INAPP_DISPLAY_PREVIEWS, PreferencesValueType.BoolData(enabled))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] inAppDisplayPreviews persisted: ${enabled}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveInAppDisplayPreviews failed: ${_e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveInAppDisplayPreviews: no context")
        }
    }

    /**
     * SHOW NOTIFICATIONS FROM / All Accounts。对应 iOS
     * InAppNotificationSettings.displayNotificationsFromAllAccounts，默认 true。
     * 本地 Preferences，不经 account.updateNotifySettings。
     */
    public func getDisplayNotificationsFromAllAccounts(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    let val = prefs.get(KEY_INAPP_DISPLAY_ALL_ACCOUNTS, PreferencesValueType.BoolData(true))
                    match (val) {
                        case PreferencesValueType.BoolData(b) => return b
                        case _ => return true
                    }
                } catch (_e: Exception) { return true }
            case None => return true
        }
    }

    public func saveDisplayNotificationsFromAllAccounts(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NOTIF_LOCAL_PREFS)
                    prefs.put(KEY_INAPP_DISPLAY_ALL_ACCOUNTS, PreferencesValueType.BoolData(enabled))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] displayFromAllAccounts persisted: ${enabled}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveDisplayNotificationsFromAllAccounts failed: ${_e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] saveDisplayNotificationsFromAllAccounts: no context")
        }
    }

    // ==================== In-App 通知设置（服务器同步，legacy — 见 Hand-off） ====================

    /**
     * DEPRECATED（ic_nsnd_inapp_local_preferences）：此方法把 in-app 语义误接到了服务端
     * silent/show_previews 位（push 层设置），实际应使用本节新增的
     * getInAppPlaySounds/saveInAppPlaySounds 等本地 getter/setter。保留方法体与签名不动
     * （唯一调用点 NotificationSettingsPage.cj 不在本 host 文件的改动范围内，需由该调用点
     * 所属 feature 完成改绑；届时本方法应随之删除，见本 feature 交付报告 Hand-off）。
     * 更新 in-app 通知设置（showPreviews 和 silent）
     * 对 users/chats/broadcasts 三个 peerType 批量调 updateGlobalNotifySettings。
     * 保留各 peer 现有 muteUntil 不动（先 get 再 update）。
     * 对应 iOS updateAllInAppSettings 逻辑。
     * S-001: 调用方须在 spawn{} 中执行此方法。
     */
    public func updateInAppNotifySettings(showPreviews: Bool, silent: Bool): Unit {
        let peerTypes: Array<String> = ["users", "chats", "broadcasts"]
        for (peerType in peerTypes) {
            let current = this.getGlobalNotifySettings(peerType)
            let _ = this.updateGlobalNotifySettings(peerType, current.muteUntil, showPreviews, silent)
        }
        Hilog.info(0, "CjTelegram", "[TelegramCoreSettings] updateInAppNotifySettings: showPreviews=${showPreviews} silent=${silent}")
    }
}
