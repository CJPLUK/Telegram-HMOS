package ohos_app_cangjie_entry.app

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog

/**
 * P2-010: Account Switch Root-Rebuild Bridge
 *
 * iOS reference: AccountManager.switchToAccount → rebuild RootController + restore settings tab.
 *
 * Mechanism:
 *   1. After switchAccount(slot) completes, call signalAccountSwitched(settingsTab).
 *   2. signalAccountSwitched bumps AppStorage["accountSwitchVersion"] (UI thread required).
 *   3. EntryView subscribes via @StorageLink["accountSwitchVersion"] and reloads login state.
 *   4. MainTabPage checks AppStorage["switchingDataTab"] to restore the settings tab.
 *
 * Key constants exposed for EntryView and MainTabPage.
 */

/** AppStorage key: bumped on every account switch to trigger EntryView rebuild. */
public let ACCOUNT_SWITCH_VERSION_KEY: String = "accountSwitchVersion"

/** AppStorage key: target tab index to restore after account switch (-1 = no restore). */
public let SWITCHING_DATA_TAB_KEY: String = "switchingDataTab"

/** Tab index for Settings tab in MainTabPage (iOS switchingData restores Settings). */
public let SETTINGS_TAB_INDEX: Int32 = 3

/**
 * Initialize AppStorage keys for account switch bridge.
 * Must be called on UI thread (e.g., from MainTabPage.aboutToAppear or EntryView.aboutToAppear).
 * Idempotent (setOrCreate skips if key already exists).
 */
public func initAccountSwitchBridge(): Unit {
    let _ = AppStorage.setOrCreate<Int64>(ACCOUNT_SWITCH_VERSION_KEY, 0)
    let _ = AppStorage.setOrCreate<Int32>(SWITCHING_DATA_TAB_KEY, -1)
    Hilog.info(0, "CjTelegram", "[AccountSwitchBridge] AppStorage keys initialized")
}

/**
 * P2-010: Signal root-rebuild after account switch.
 * Must be called on UI thread (use launch{} if called from spawn).
 *
 * @param restoreSettingsTab  true = set switchingDataTab=3 (iOS switchingData behavior).
 *                            Caller passes true when switching accounts from SettingsPage.
 */
public func signalAccountSwitched(restoreSettingsTab: Bool): Unit {
    if (restoreSettingsTab) {
        let _ = AppStorage.set<Int32>(SWITCHING_DATA_TAB_KEY, SETTINGS_TAB_INDEX)
        Hilog.info(0, "CjTelegram", "[AccountSwitchBridge] switchingDataTab set to ${SETTINGS_TAB_INDEX}")
    } else {
        // An account-row switch follows Telegram iOS back to Chats. Explicitly
        // clear any older restore request before MainTabPage is reconstructed.
        let _ = AppStorage.set<Int32>(SWITCHING_DATA_TAB_KEY, -1)
        Hilog.info(0, "CjTelegram", "[AccountSwitchBridge] switchingDataTab cleared")
    }
    match (AppStorage.get<Int64>(ACCOUNT_SWITCH_VERSION_KEY)) {
        case Some(v) =>
            let _ = AppStorage.set<Int64>(ACCOUNT_SWITCH_VERSION_KEY, v + 1)
            Hilog.info(0, "CjTelegram", "[AccountSwitchBridge] accountSwitchVersion -> ${v + 1}")
        case None =>
            let _ = AppStorage.setOrCreate<Int64>(ACCOUNT_SWITCH_VERSION_KEY, 1)
            Hilog.info(0, "CjTelegram", "[AccountSwitchBridge] accountSwitchVersion created at 1")
    }
}

/**
 * P2-010: Consume the pending switchingDataTab value.
 * Called by MainTabPage.aboutToAppear to restore the settings tab, then clears the key.
 * Returns SETTINGS_TAB_INDEX if a tab restore is pending, -1 otherwise.
 */
public func consumeSwitchingDataTab(): Int32 {
    match (AppStorage.get<Int32>(SWITCHING_DATA_TAB_KEY)) {
        case Some(tab) =>
            if (tab >= 0) {
                let _ = AppStorage.set<Int32>(SWITCHING_DATA_TAB_KEY, -1)
                Hilog.info(0, "CjTelegram", "[AccountSwitchBridge] consumeSwitchingDataTab: restoring tab=${tab}")
                return tab
            }
            return -1
        case None => return -1
    }
}
