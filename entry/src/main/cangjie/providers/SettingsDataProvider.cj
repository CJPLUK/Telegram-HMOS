package ohos_app_cangjie_entry.providers

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getTelegramCoreSettingsService, GlobalNotifySettingsData}

private var _settingsDataProviderInstance: Option<SettingsDataProvider> = None

public func getSettingsDataProvider(): SettingsDataProvider {
    match (_settingsDataProviderInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = SettingsDataProvider()
            _settingsDataProviderInstance = Some(inst)
            return inst
    }
}

/**
 * SettingsDataProvider — 设置数据标准化访问层
 *
 * 对应 iOS TelegramEngine 的 Settings 适配层
 * 职责：
 * - 为 Settings 相关页面提供统一的数据访问接口
 * - 委托 TelegramCoreSettingsService 执行读写
 * - 将底层数据转为 UI 可用的格式
 */
public class SettingsDataProvider {
    private let settingsService = getTelegramCoreSettingsService()

    // ic_settings_presentation_to_chat_list: single-slot listener for theme/locale changes
    private var _presentationListener: Option<() -> Unit> = None

    public func setPresentationListener(listener: () -> Unit): Unit {
        this._presentationListener = Some(listener)
    }

    public func firePresentationChanged(): Unit {
        match (this._presentationListener) {
            case Some(cb) => cb()
            case None => ()
        }
    }

    // ==================== 外观设置 ====================

    public func getAppearanceTheme(): Int32 {
        return this.settingsService.getAppearanceTheme()
    }

    public func saveAppearanceTheme(theme: Int32): Unit {
        this.settingsService.saveAppearanceTheme(theme)
    }

    public func getAppearanceTextSize(): Int32 {
        return this.settingsService.getAppearanceTextSize()
    }

    public func saveAppearanceTextSize(size: Int32): Unit {
        this.settingsService.saveAppearanceTextSize(size)
    }

    public func getChatBackground(): String {
        return this.settingsService.getChatBackground()
    }

    public func saveChatBackground(path: String): Unit {
        this.settingsService.saveChatBackground(path)
    }

    public func getAnimationEnabled(): Bool {
        return this.settingsService.getAnimationEnabled()
    }

    public func saveAnimationEnabled(enabled: Bool): Unit {
        this.settingsService.saveAnimationEnabled(enabled)
    }

    // ==================== 语言设置 ====================

    public func getLangCode(): String {
        return this.settingsService.getLangCode()
    }

    public func saveLangCode(code: String): Unit {
        this.settingsService.saveLangCode(code)
    }

    // ==================== 下载设置 ====================

    public func getDownloadPhotos(): Bool {
        return this.settingsService.getDownloadPhotos()
    }

    public func saveDownloadPhotos(enabled: Bool): Unit {
        this.settingsService.saveDownloadPhotos(enabled)
    }

    public func getDownloadVideos(): Bool {
        return this.settingsService.getDownloadVideos()
    }

    public func saveDownloadVideos(enabled: Bool): Unit {
        this.settingsService.saveDownloadVideos(enabled)
    }

    public func getDownloadFiles(): Bool {
        return this.settingsService.getDownloadFiles()
    }

    public func saveDownloadFiles(enabled: Bool): Unit {
        this.settingsService.saveDownloadFiles(enabled)
    }

    public func getSaveToGallery(): Bool {
        return this.settingsService.getSaveToGallery()
    }

    public func saveSaveToGallery(enabled: Bool): Unit {
        this.settingsService.saveSaveToGallery(enabled)
    }

    public func getDataSaving(): Bool {
        return this.settingsService.getDataSaving()
    }

    public func saveDataSaving(enabled: Bool): Unit {
        this.settingsService.saveDataSaving(enabled)
    }

    // ==================== 其他设置 ====================

    public func getArchiveKeepUnmuted(): Bool {
        return this.settingsService.getArchiveKeepUnmuted()
    }

    public func saveArchiveKeepUnmuted(enabled: Bool): Unit {
        this.settingsService.saveArchiveKeepUnmuted(enabled)
    }

    public func getPowerSaving(): Bool {
        return this.settingsService.getPowerSaving()
    }

    public func savePowerSaving(enabled: Bool): Unit {
        this.settingsService.savePowerSaving(enabled)
    }

    // ==================== 全局通知设置（服务器同步） ====================

    /**
     * 获取指定类型的全局通知设置
     * @param peerType "users" | "chats" | "broadcasts"
     */
    public func getGlobalNotifySettings(peerType: String): GlobalNotifySettingsData {
        return this.settingsService.getGlobalNotifySettings(peerType)
    }

    /**
     * 更新指定类型的全局通知设置
     */
    public func updateGlobalNotifySettings(peerType: String, muteUntil: Int32, showPreviews: Bool, silent: Bool): Bool {
        return this.settingsService.updateGlobalNotifySettings(peerType, muteUntil, showPreviews, silent)
    }
}
