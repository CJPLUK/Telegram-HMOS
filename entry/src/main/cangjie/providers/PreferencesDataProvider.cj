package ohos_app_cangjie_entry.providers

import ohos_app_cangjie_entry.engine.getPreferencesEngineService
import ohos_app_cangjie_entry.services.GlobalNotifySettingsData

/**
 * PreferencesDataProvider — 偏好设置数据提供层
 *
 * 对应 iOS TelegramEngine.Preferences 的 UI 适配层
 * 职责：
 * - 将 PreferencesEngineService 的 API 数据转为 UI 可用的 ViewModel
 * - 为通知设置、内容设置等页面提供统一的数据访问接口
 * - 委托 PreferencesEngineService 执行读写
 */
public class PreferencesDataProvider {
    private let engine = getPreferencesEngineService()

    // ==================== 全局通知设置 ====================

    /**
     * 获取指定类型的全局通知设置（供 UI 显示）
     * @param peerType "users" | "chats" | "broadcasts"
     */
    public func getGlobalNotifySettings(peerType: String): GlobalNotifySettingsData {
        return this.engine.getGlobalNotifySettings(peerType)
    }

    /**
     * 更新指定类型的全局通知设置
     * @param peerType "users" | "chats" | "broadcasts"
     * @param muteUntil 0=取消静音, 2147483647=永久静音, 其他=静音至该 Unix 时间戳
     * @return 是否成功
     */
    public func updateGlobalNotifySettings(peerType: String, muteUntil: Int32, showPreviews: Bool, silent: Bool): Bool {
        return this.engine.updateGlobalNotifySettings(peerType, muteUntil, showPreviews, silent)
    }

    /**
     * 判断全局通知是否启用（muteUntil == 0 表示启用）
     */
    public func isGlobalNotifyEnabled(peerType: String): Bool {
        let data = this.engine.getGlobalNotifySettings(peerType)
        return !data.isMuted
    }

    // ==================== 每对话通知设置 ====================

    /**
     * 获取指定用户的通知设置
     * @return muteUntil: 0=未静音, 2147483647=永久静音
     */
    public func getPeerNotifySettings(userId: Int64): Int32 {
        return this.engine.getPeerNotifySettings(userId)
    }

    /**
     * 使用 accessHash 获取通知设置
     */
    public func getPeerNotifySettingsWithHash(userId: Int64, accessHash: Int64): Int32 {
        return this.engine.getPeerNotifySettingsWithHash(userId, accessHash)
    }

    /**
     * 更新指定用户的静音设置
     */
    public func updatePeerNotifySettings(userId: Int64, muteUntil: Int32): Bool {
        return this.engine.updatePeerNotifySettings(userId, muteUntil)
    }

    /**
     * 使用 accessHash 更新静音设置
     */
    public func updatePeerNotifySettingsWithHash(userId: Int64, accessHash: Int64, muteUntil: Int32): Bool {
        return this.engine.updatePeerNotifySettingsWithHash(userId, accessHash, muteUntil)
    }

    /**
     * 计算静音时长对应的 muteUntil 值
     */
    public func muteUntilForDuration(seconds: Int64): Int32 {
        return this.engine.muteUntilForDuration(seconds)
    }

    /**
     * 判断用户是否已静音
     */
    public func isPeerMuted(userId: Int64): Bool {
        return this.engine.getPeerNotifySettings(userId) > 0
    }

    // ==================== 内容设置（供 UI 显示） ====================

    public func getDownloadPhotos(): Bool {
        return this.engine.getDownloadPhotos()
    }

    public func saveDownloadPhotos(enabled: Bool): Unit {
        this.engine.saveDownloadPhotos(enabled)
    }

    public func getDownloadVideos(): Bool {
        return this.engine.getDownloadVideos()
    }

    public func saveDownloadVideos(enabled: Bool): Unit {
        this.engine.saveDownloadVideos(enabled)
    }

    public func getDownloadFiles(): Bool {
        return this.engine.getDownloadFiles()
    }

    public func saveDownloadFiles(enabled: Bool): Unit {
        this.engine.saveDownloadFiles(enabled)
    }

    public func getSaveToGallery(): Bool {
        return this.engine.getSaveToGallery()
    }

    public func saveSaveToGallery(enabled: Bool): Unit {
        this.engine.saveSaveToGallery(enabled)
    }

    public func getDataSaving(): Bool {
        return this.engine.getDataSaving()
    }

    public func saveDataSaving(enabled: Bool): Unit {
        this.engine.saveDataSaving(enabled)
    }

    public func getLangCode(): String {
        return this.engine.getLangCode()
    }

    public func saveLangCode(code: String): Unit {
        this.engine.saveLangCode(code)
    }
}
