package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*

/**
 * 归档入口的「隐藏在列表上方」设置。
 *
 * 对位 iOS ChatArchiveSettings.isHiddenByDefault（ApplicationSpecificPreferencesKeys.chatArchiveSettings，
 * 账号本地偏好，不上服务端）：
 *   - false（默认）：Archived Chats 行常驻主列表顶部；
 *   - true：行默认不显示，在 All Chats 顶部下拉时临时露出（ChatListNode.revealScrollHiddenItem）。
 * 由 Archived Chats 行长按菜单的 Hide Above the List / Pin in the list 切换
 * （ChatListController.toggleArchivedFolderHiddenByDefault）。
 */
private let ARCHIVE_SETTINGS_STORE: String = "telegram_chat_archive"

public func isChatArchiveHiddenByDefault(): Bool {
    match (getGlobalAbilityContext()) {
        case None => return false
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, ARCHIVE_SETTINGS_STORE)
                let value = prefs.get(archiveHiddenKey(), PreferencesValueType.Integer(0))
                match (value) {
                    case PreferencesValueType.Integer(n) => return n != 0
                    case _ => return false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatArchiveSettings] read failed: ${e}")
                return false
            }
    }
}

public func setChatArchiveHiddenByDefault(hidden: Bool): Unit {
    match (getGlobalAbilityContext()) {
        case None => ()
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, ARCHIVE_SETTINGS_STORE)
                let v: Int64 = if (hidden) { 1 } else { 0 }
                prefs.put(archiveHiddenKey(), PreferencesValueType.Integer(v))
                prefs.flush()
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatArchiveSettings] write failed: ${e}")
            }
    }
}

private func archiveHiddenKey(): String {
    return "isHiddenByDefault_${getCurrentUserId()}"
}
