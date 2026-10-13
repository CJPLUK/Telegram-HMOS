package ohos_app_cangjie_entry.services

import kit.ArkData.*
import kit.ArkUI.{AppStorage, launch}
import kit.PerformanceAnalysisKit.Hilog

/**
 * Calls tab visibility (iOS CallListSettings.showTab).
 *
 * iOS keeps it in accountManager shared data (ApplicationSpecificSharedDataKeys.callListSettings),
 * so the value is app-wide, not per account; CallListSettings.defaultSettings.showTab = true.
 * The Recent Calls page opened from Settings writes it (CallListControllerNode.swift:397
 * updateShowCallsTab), and the root tab bar reads it back through AppStorage.
 */
public let CALL_LIST_SHOW_TAB_KEY: String = "callListShowTab"

private let CALL_LIST_SETTINGS_STORE: String = "telegram_call_list_settings"
private let CALL_LIST_SHOW_TAB_PREF: String = "showTab"

/** Persisted value, default true. Used as the initial value of @StorageLink[CALL_LIST_SHOW_TAB_KEY]. */
public func isCallsTabShown(): Bool {
    match (getGlobalAbilityContext()) {
        case None => return true
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, CALL_LIST_SETTINGS_STORE)
                match (prefs.get(CALL_LIST_SHOW_TAB_PREF, PreferencesValueType.BoolData(true))) {
                    case PreferencesValueType.BoolData(b) => return b
                    case _ => return true
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[CallListSettings] read failed: ${e}")
                return true
            }
    }
}

/** Persists the value and publishes it to AppStorage so the tab bar updates at once. */
public func setCallsTabShown(value: Bool): Unit {
    match (getGlobalAbilityContext()) {
        case None => ()
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, CALL_LIST_SETTINGS_STORE)
                prefs.put(CALL_LIST_SHOW_TAB_PREF, PreferencesValueType.BoolData(value))
                prefs.flush()
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[CallListSettings] write failed: ${e}")
            }
    }
    launch {
        let _ = AppStorage.setOrCreate<Bool>(CALL_LIST_SHOW_TAB_KEY, value)
    }
}

private var _callListSettingsService: Option<CallListSettingsService> = None

public func getCallListSettingsService(): CallListSettingsService {
    match (_callListSettingsService) {
        case Some(service) => return service
        case None =>
            let service = CallListSettingsService()
            _callListSettingsService = Some(service)
            return service
    }
}

/** Compatibility facade for pages that predate the shared AppStorage binding. */
public class CallListSettingsService {
    private var _changed: Option<(Bool) -> Unit> = None

    public func setChangedCallback(callback: (Bool) -> Unit): Unit {
        this._changed = Some(callback)
    }

    public func getShowTab(): Bool {
        return isCallsTabShown()
    }

    public func setShowTab(show: Bool): Unit {
        setCallsTabShown(show)
        match (this._changed) {
            case Some(callback) => callback(show)
            case None => ()
        }
    }
}
