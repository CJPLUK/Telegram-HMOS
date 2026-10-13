package ohos_app_cangjie_entry.core.storage

import std.collection.HashMap
import std.sync.*
import kit.PerformanceAnalysisKit.Hilog
import kit.ArkUI.AppStorage
import kit.ArkUI.launch

public let PRESENTATION_STRINGS_KEY = "presentationStrings"

/**
 * Global internationalisation singleton.
 *
 * Holds a key→value translation map loaded from langpack.getStrings.
 * Access translations with  tr("Settings.Title")  which falls back to the key itself.
 *
 * Builtin English defaults are populated on init so the UI always has text.
 */
public class I18nManager {
    public var langCode: String = "en"
    public var strings: HashMap<String, String> = HashMap<String, String>()

    public init() {
        this.loadDefaults()
    }

    /**
     * Populate English defaults for the most common UI strings.
     */
    public func loadDefaults(): Unit {
        // A language change replaces the complete PresentationStrings object on iOS.
        // Keeping entries from the previous pack would create a mixed-language UI.
        this.strings.clear()
        let d = this.strings
        // Tabs
        d["Tabs.Contacts"] = "Contacts"
        d["Tabs.Calls"] = "Calls"
        d["Tabs.Chats"] = "Chats"
        d["Tabs.Settings"] = "Settings"
        // Settings page
        d["Settings.Title"] = "Settings"
        d["Settings.EditProfile"] = "Edit Profile"
        d["Settings.SavedMessages"] = "Saved Messages"
        d["Settings.Devices"] = "Devices"
        d["Settings.ChatFolders"] = "Chat Folders"
        d["Settings.Notifications"] = "Notifications and Sounds"
        d["Settings.Privacy"] = "Privacy and Security"
        d["Settings.DataStorage"] = "Data and Storage"
        d["Settings.Appearance"] = "Appearance"
        d["Settings.Language"] = "Language"
        d["Settings.Premium"] = "Telegram Premium"
        d["Settings.Logout"] = "Log Out"
        // Chat list
        d["ChatList.Title"] = "Chats"
        d["ChatList.Search"] = "Search"
        d["ChatList.NoChats"] = "No chats yet"
        // Chat room
        d["ChatRoom.TypeMessage"] = "Message"
        d["ChatRoom.Send"] = "Send"
        d["ChatRoom.Photo"] = "Photo"
        d["ChatRoom.Video"] = "Video"
        d["ChatRoom.File"] = "File"
        d["ChatRoom.Location"] = "Location"
        d["ChatRoom.Contact"] = "Contact"
        // Profile
        d["Profile.SendMessage"] = "Send Message"
        d["Profile.Call"] = "Call"
        d["Profile.VideoCall"] = "Video Call"
        d["Profile.Block"] = "Block User"
        d["Profile.Unblock"] = "Unblock User"
        // Common
        d["Common.Done"] = "Done"
        d["Common.Cancel"] = "Cancel"
        d["Common.Save"] = "Save"
        d["Common.Delete"] = "Delete"
        d["Common.Edit"] = "Edit"
        d["Common.Back"] = "Back"
        d["Common.OK"] = "OK"
        d["Common.Loading"] = "Loading..."
        d["Common.Search"] = "Search"
        // Language
        d["Language.Title"] = "Language"
        d["Language.Applied"] = "Language applied"
        // Contacts
        d["Contacts.Title"] = "Contacts"

        // Explicit PresentationStrings keys currently consumed by target UI.
        // These are source keys (not target aliases).  Several English values
        // intentionally occur under more than one key in Localizable.strings;
        // a reverse English-value index cannot preserve those duplicates.
        d["CallSettings.RecentCalls"] = "Recent Calls"
        d["Calls.All"] = "All"
        d["Calls.Missed"] = "Missed"
        d["Calls.NoVoiceAndVideoCallsPlaceholder"] = "Your recent voice and video calls will appear here."
        d["Calls.StartNewCall"] = "Start New Call"
        d["Calls.TabTitle"] = "Calls"
        d["Contacts.InviteFriends"] = "Invite Friends"
        d["Contacts.Sort"] = "Sort"
        d["Contacts.TabTitle"] = "Contacts"
        d["DialogList.TabTitle"] = "Chats"
        d["DialogList.You"] = "You"
        d["Gift.Store.Balance.MyStars"] = "My Stars"
        d["Settings.AddAccount"] = "Add Account"
        d["Settings.AppLanguage"] = "Language"
        d["Settings.Business"] = "Telegram Business"
        d["Settings.ChangeProfilePhoto"] = "Change Profile Photo"
        d["Settings.ChatFolders"] = "Chat Folders"
        d["Settings.ChatSettings"] = "Data and Storage"
        d["Settings.Devices"] = "Devices"
        d["Settings.FAQ"] = "Telegram FAQ"
        d["Settings.MyProfile"] = "My Profile"
        d["Settings.NotificationsAndSounds"] = "Notifications and Sounds"
        d["Settings.PowerSaving"] = "Power Saving"
        d["Settings.PowerSavingOff"] = "Off"
        d["Settings.PowerSavingOn"] = "On"
        d["Settings.PrivacySettings"] = "Privacy and Security"
        d["Settings.SavedMessages"] = "Saved Messages"
        d["Settings.SendGift"] = "Send a Gift"
        d["Settings.Support"] = "Ask a Question"
        d["Settings.Tips"] = "Telegram Features"
        d["Localization.LanguageName"] = "English"

        // Date strings are consumed by the source-aligned relative timestamp
        // formatter even when no view contains their English values as literals.
        // Keep the complete source English date component available so switching
        // back from a downloaded pack cannot retain that pack's weekday/months.
        d["Month.ShortJanuary"] = "Jan"
        d["Month.ShortFebruary"] = "Feb"
        d["Month.ShortMarch"] = "Mar"
        d["Month.ShortApril"] = "Apr"
        d["Month.ShortMay"] = "May"
        d["Month.ShortJune"] = "Jun"
        d["Month.ShortJuly"] = "Jul"
        d["Month.ShortAugust"] = "Aug"
        d["Month.ShortSeptember"] = "Sep"
        d["Month.ShortOctober"] = "Oct"
        d["Month.ShortNovember"] = "Nov"
        d["Month.ShortDecember"] = "Dec"
        d["Weekday.ShortMonday"] = "Mon"
        d["Weekday.ShortTuesday"] = "Tue"
        d["Weekday.ShortWednesday"] = "Wed"
        d["Weekday.ShortThursday"] = "Thu"
        d["Weekday.ShortFriday"] = "Fri"
        d["Weekday.ShortSaturday"] = "Sat"
        d["Weekday.ShortSunday"] = "Sun"
        d["Weekday.Today"] = "Today"
        d["Weekday.Yesterday"] = "Yesterday"
        // CalendarMessageScreen weekday headers (iOS gridDayName → Calendar_Short*).
        // Several English values collapse to the same letter, so the reverse
        // English-value index cannot carry them; keep the explicit keys here.
        d["Calendar.ShortSun"] = "S"
        d["Calendar.ShortMon"] = "M"
        d["Calendar.ShortTue"] = "T"
        d["Calendar.ShortWed"] = "W"
        d["Calendar.ShortThu"] = "T"
        d["Calendar.ShortFri"] = "F"
        d["Calendar.ShortSat"] = "S"
        // In-chat search bar (iOS ChatSearchNavigationContentNode / ChatSearchResultsController).
        d["Conversation.SearchPlaceholder"] = "Search this chat"
        d["Conversation.SearchNoResults"] = "No Results"

        // Telegram iOS always has its complete English localization component
        // available.  This source-derived component also prevents mounted rows
        // from retaining the previous language when switching back to English.
        applySourceEnglishDefaults(d)
    }

    /**
     * Apply a batch of key→value translations (from server response).
     */
    public func applyStrings(map: HashMap<String, String>): Unit {
        for ((k, v) in map) {
            this.strings[k] = v
        }
        Hilog.info(0, "CjTelegram", "[I18n] Applied ${map.size} translated strings for lang=${this.langCode}")
    }

    public func get(key: String): String {
        if (this.strings.contains(key)) {
            return this.strings[key]
        }
        return key
    }


    public func getOr(key: String, fallback: String): String {
        if (this.strings.contains(key)) {
            return this.strings[key]
        }
        // PresentationStrings exposes Swift identifiers such as
        // `Settings_AppLanguage`, while Telegram's lang-pack payload stores
        // the canonical key `Settings.AppLanguage`.
        let canonical = key.replace("_", ".")
        if (this.strings.contains(canonical)) {
            return this.strings[canonical]
        }
        return fallback
    }
}

/**
 * Immutable language presentation value.
 *
 * Telegram iOS replaces `PresentationData.strings` as a complete
 * `PresentationStrings` value after the base and primary components have both
 * been assembled.  UI consumers observe that value; they do not observe a
 * separate invalidation counter.  This class is the target-side counterpart:
 * every instance owns a private copy of the completed string table and is
 * replaced atomically in AppStorage.
 */
public class PresentationStringsSnapshot {
    public let langCode: String
    private let strings: HashMap<String, String>

    public init(langCode: String, source: HashMap<String, String>) {
        this.langCode = langCode
        this.strings = HashMap<String, String>()
        for ((key, value) in source) {
            this.strings[key] = value
        }
    }

    public func get(key: String): String {
        if (this.strings.contains(key)) {
            return this.strings[key]
        }
        return key
    }

    public func getOr(key: String, fallback: String): String {
        if (this.strings.contains(key)) {
            return this.strings[key]
        }
        let canonical = key.replace("_", ".")
        if (this.strings.contains(canonical)) {
            return this.strings[canonical]
        }
        return fallback
    }
}

// ==================== Global singleton ====================

var _i18n: I18nManager = I18nManager()
var _currentPresentationStrings: PresentationStringsSnapshot = PresentationStringsSnapshot(
    _i18n.langCode,
    _i18n.strings
)
let _presentationStringsMutex: Mutex = Mutex()

public func getI18n(): I18nManager {
    return _i18n
}

/**
 * Shorthand translation function.
 * Usage:  tr("Settings.Title")  →  "Settings" (or translated value)
 */
public func tr(key: String): String {
    return _i18n.get(key)
}

/** Telegram language-pack key lookup with an English fallback. */
public func trOr(key: String, fallback: String): String {
    return _i18n.getOr(key, fallback)
}

/**
 * Resolve a source English fallback through the canonical key generated from
 * Telegram-iOS's Localizable.strings. Migrated screens should prefer trOr()
 * with an explicit key; this keeps still-literal source UI text synchronized
 * without inventing target-only keys or a separate translation table.
 */
public func trSource(english: String): String {
    let key = sourceKeyForEnglish(english)
    if (key.size == 0) {
        return english
    }
    return _i18n.getOr(key, english)
}

public func currentPresentationStrings(): PresentationStringsSnapshot {
    _presentationStringsMutex.lock()
    let result = _currentPresentationStrings
    _presentationStringsMutex.unlock()
    return result
}

/**
 * Publish one fully assembled string presentation value.
 *
 * Callers invoke this only after applying the English defaults, optional base
 * component and selected component.  The UI therefore never observes a
 * partially overlaid pack, matching the source `PresentationStrings` update.
 */
public func publishPresentationStrings(): PresentationStringsSnapshot {
    let snapshot = PresentationStringsSnapshot(_i18n.langCode, _i18n.strings)
    _presentationStringsMutex.lock()
    _currentPresentationStrings = snapshot
    _presentationStringsMutex.unlock()
    launch {
        let _ = AppStorage.setOrCreate<PresentationStringsSnapshot>(PRESENTATION_STRINGS_KEY, snapshot)
    }
    return snapshot
}

/**
 * Called at app startup to restore persisted language code.
 */
public func initI18n(): Unit {
    let storage = getAuthStorage()
    let code = storage.getLangCode()
    _i18n.langCode = code
    let snapshot = PresentationStringsSnapshot(_i18n.langCode, _i18n.strings)
    _presentationStringsMutex.lock()
    _currentPresentationStrings = snapshot
    _presentationStringsMutex.unlock()
    let _ = AppStorage.setOrCreate<PresentationStringsSnapshot>(PRESENTATION_STRINGS_KEY, snapshot)
    Hilog.info(0, "CjTelegram", "[I18n] Initialized with langCode=${code}")
}
