package ohos_app_cangjie_entry.adapters

import ohos_app_cangjie_entry.services.{getTelegramCoreSettingsService, GlobalNotifySettingsData}

/**
 * TelegramCore Settings 对外接口适配层 (TCSET-IF-1)
 *
 * 对应 iOS TelegramCore/Settings 对外 API
 * 为上层业务提供统一的设置访问接口，委托 TelegramCoreSettingsService 实现
 *
 * 使用方式：
 *   let adapter = getTelegramCore_SettingsAdapter()
 *   let theme = adapter.getAppearanceTheme()
 *   adapter.saveAppearanceTheme(1)
 */
private var _adapterInstance: Option<TelegramCore_SettingsAdapter> = None

public func getTelegramCore_SettingsAdapter(): TelegramCore_SettingsAdapter {
    match (_adapterInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCore_SettingsAdapter()
            _adapterInstance = Some(inst)
            return inst
    }
}

public class TelegramCore_SettingsAdapter {
    public init() {}

    // ==================== 外观设置 ====================

    public func getAppearanceTheme(): Int32 {
        return getTelegramCoreSettingsService().getAppearanceTheme()
    }

    public func saveAppearanceTheme(theme: Int32): Unit {
        getTelegramCoreSettingsService().saveAppearanceTheme(theme)
    }

    public func getAppearanceTextSize(): Int32 {
        return getTelegramCoreSettingsService().getAppearanceTextSize()
    }

    public func saveAppearanceTextSize(size: Int32): Unit {
        getTelegramCoreSettingsService().saveAppearanceTextSize(size)
    }

    public func getChatBackground(): String {
        return getTelegramCoreSettingsService().getChatBackground()
    }

    public func saveChatBackground(path: String): Unit {
        getTelegramCoreSettingsService().saveChatBackground(path)
    }

    public func getVerifiedChatBackgroundUri(): String {
        return getTelegramCoreSettingsService().getVerifiedChatBackgroundUri()
    }

    public func getChatBackgroundFallbackColor(): UInt32 {
        return getTelegramCoreSettingsService().getChatBackgroundFallbackColor()
    }

    public func getAnimationEnabled(): Bool {
        return getTelegramCoreSettingsService().getAnimationEnabled()
    }

    public func saveAnimationEnabled(enabled: Bool): Unit {
        getTelegramCoreSettingsService().saveAnimationEnabled(enabled)
    }

    // ==================== 语言设置 ====================

    public func getLangCode(): String {
        return getTelegramCoreSettingsService().getLangCode()
    }

    public func saveLangCode(code: String): Unit {
        getTelegramCoreSettingsService().saveLangCode(code)
    }

    // ==================== 下载设置 ====================

    public func getDownloadPhotos(): Bool {
        return getTelegramCoreSettingsService().getDownloadPhotos()
    }

    public func saveDownloadPhotos(enabled: Bool): Unit {
        getTelegramCoreSettingsService().saveDownloadPhotos(enabled)
    }

    public func getDownloadVideos(): Bool {
        return getTelegramCoreSettingsService().getDownloadVideos()
    }

    public func saveDownloadVideos(enabled: Bool): Unit {
        getTelegramCoreSettingsService().saveDownloadVideos(enabled)
    }

    public func getDownloadFiles(): Bool {
        return getTelegramCoreSettingsService().getDownloadFiles()
    }

    public func saveDownloadFiles(enabled: Bool): Unit {
        getTelegramCoreSettingsService().saveDownloadFiles(enabled)
    }

    public func getSaveToGallery(): Bool {
        return getTelegramCoreSettingsService().getSaveToGallery()
    }

    public func saveSaveToGallery(enabled: Bool): Unit {
        getTelegramCoreSettingsService().saveSaveToGallery(enabled)
    }

    public func getDataSaving(): Bool {
        return getTelegramCoreSettingsService().getDataSaving()
    }

    public func saveDataSaving(enabled: Bool): Unit {
        getTelegramCoreSettingsService().saveDataSaving(enabled)
    }

    // ==================== 其他设置 ====================

    public func getArchiveKeepUnmuted(): Bool {
        return getTelegramCoreSettingsService().getArchiveKeepUnmuted()
    }

    public func saveArchiveKeepUnmuted(enabled: Bool): Unit {
        getTelegramCoreSettingsService().saveArchiveKeepUnmuted(enabled)
    }

    public func getPowerSaving(): Bool {
        return getTelegramCoreSettingsService().getPowerSaving()
    }

    public func savePowerSaving(enabled: Bool): Unit {
        getTelegramCoreSettingsService().savePowerSaving(enabled)
    }

    // ==================== 全局通知设置 ====================

    public func getGlobalNotifySettings(peerType: String): GlobalNotifySettingsData {
        return getTelegramCoreSettingsService().getGlobalNotifySettings(peerType)
    }

    public func updateGlobalNotifySettings(peerType: String, muteUntil: Int32, showPreviews: Bool, silent: Bool): Bool {
        return getTelegramCoreSettingsService().updateGlobalNotifySettings(peerType, muteUntil, showPreviews, silent)
    }
}
