package ohos_app_cangjie_entry.engine

import ohos_app_cangjie_entry.services.{getTelegramCoreSettingsService, getNotificationMuteSettingsService, GlobalNotifySettingsData}

/**
 * PreferencesEngineService — 用户偏好设置引擎
 *
 * 对应 iOS TelegramEngine.Preferences
 * 职责：
 * - 统一管理用户偏好：通知设置（全局 + 每对话）、内容设置
 * - 委托 TelegramCoreSettingsService 处理全局通知 (account.getNotifySettings, account.updateNotifySettings)
 * - 委托 NotificationMuteSettingsService 处理每对话静音
 * - 委托 TelegramCoreSettingsService 处理本地内容设置（下载、语言等）
 *
 * TL 方法：account.getNotifySettings, account.updateNotifySettings
 */
private var _preferencesEngineServiceInstance: Option<PreferencesEngineService> = None

public func getPreferencesEngineService(): PreferencesEngineService {
    match (_preferencesEngineServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PreferencesEngineService()
            _preferencesEngineServiceInstance = Some(inst)
            return inst
    }
}

public class PreferencesEngineService {
    private let settingsService = getTelegramCoreSettingsService()
    private let muteService = getNotificationMuteSettingsService()

    // ==================== 全局通知设置（服务器同步） ====================

    /**
     * 获取指定类型的全局通知设置（account.getNotifySettings）
     * @param peerType "users" | "chats" | "broadcasts"
     */
    public func getGlobalNotifySettings(peerType: String): GlobalNotifySettingsData {
        return this.settingsService.getGlobalNotifySettings(peerType)
    }

    /**
     * 更新指定类型的全局通知设置（account.updateNotifySettings）
     * @param peerType "users" | "chats" | "broadcasts"
     * @param muteUntil 0=取消静音, 2147483647=永久静音, 其他=静音至该 Unix 时间戳
     */
    public func updateGlobalNotifySettings(peerType: String, muteUntil: Int32, showPreviews: Bool, silent: Bool): Bool {
        return this.settingsService.updateGlobalNotifySettings(peerType, muteUntil, showPreviews, silent)
    }

    // ==================== 每对话通知设置（服务器同步） ====================

    /**
     * 获取指定用户/对话的通知设置（account.getPeerNotifySettings）
     * @return muteUntil: 0=未静音, 2147483647=永久静音, 其他=静音至该 Unix 时间戳
     */
    public func getPeerNotifySettings(userId: Int64): Int32 {
        return this.muteService.getNotifySettings(userId)
    }

    /**
     * 使用 accessHash 获取通知设置（当已有 accessHash 时避免重复查询）
     */
    public func getPeerNotifySettingsWithHash(userId: Int64, accessHash: Int64): Int32 {
        return this.muteService.getNotifySettingsWithHash(userId, accessHash)
    }

    /**
     * 更新指定用户/对话的静音设置（account.updatePeerNotifySettings）
     * @param muteUntil 0=取消静音, 2147483647=永久静音, Unix 时间戳=静音至该时间
     */
    public func updatePeerNotifySettings(userId: Int64, muteUntil: Int32): Bool {
        return this.muteService.updateNotifySettings(userId, muteUntil)
    }

    /**
     * 使用 accessHash 更新静音设置
     */
    public func updatePeerNotifySettingsWithHash(userId: Int64, accessHash: Int64, muteUntil: Int32): Bool {
        return this.muteService.updateNotifySettingsWithHash(userId, accessHash, muteUntil)
    }

    /**
     * 计算静音时长对应的 muteUntil 值
     * @param seconds 静音秒数，0=取消静音
     */
    public func muteUntilForDuration(seconds: Int64): Int32 {
        return this.muteService.muteUntilForDuration(seconds)
    }

    // ==================== 内容设置（本地 AuthStorage） ====================

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

    public func getLangCode(): String {
        return this.settingsService.getLangCode()
    }

    public func saveLangCode(code: String): Unit {
        this.settingsService.saveLangCode(code)
    }
}
