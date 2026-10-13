package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.collection.HashMap
import ohos.i18n.System as I18nSystem
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    LangpackGetLanguages,
    LangpackGetStrings,
    TLDeserializer
}
import ohos_app_cangjie_entry.core.mtproto.MTProtoConfig
import ohos_app_cangjie_entry.core.storage.{getAuthStorage, getI18n}
import ohos_app_cangjie_entry.models.LanguageInfo

/**
 * Language Suggestion Service (LanguageSuggestionUI)
 *
 * Suggests language packs based on system locale.
 * - Detects system locale (uses MTProtoConfig.SYSTEM_LANG_CODE as fallback)
 * - Queries available languages via langpack.getLanguages
 * - Matches system locale to suggest a language
 * - Applies selected language via langpack.getStrings + I18n
 *
 * iOS source: Telegram-iOS/submodules/LanguageSuggestionUI/LanguageSuggestionController.swift
 */
public func getLanguageSuggestionService(): LanguageSuggestionService {
    return LanguageSuggestionService()
}

public class LanguageSuggestionService {

    /**
     * Get system locale code (e.g. zh-Hans, en).
     * Uses ohos.i18n.System.getAppPreferredLanguage() to read the real device locale.
     * Falls back to MTProtoConfig.SYSTEM_LANG_CODE if the API throws.
     *
     * iOS equiv: Locale.current.languageCode (NSLocale.currentLocale.languageCode)
     * KB ref: ohos.i18n.System.getAppPreferredLanguage() confirmed in CalendarMessageScreen.cj
     */
    public func getSystemLocaleCode(): String {
        try {
            let lang = I18nSystem.getAppPreferredLanguage()
            if (lang.size > 0) {
                Hilog.info(0, "CjTelegram", "[LangSuggestion] device lang: " + lang)
                return lang
            }
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[LangSuggestion] getAppPreferredLanguage failed, fallback MTProtoConfig")
        }
        return MTProtoConfig.SYSTEM_LANG_CODE
    }

    /**
     * Query available languages from Telegram via langpack.getLanguages.
     */
    public func getAvailableLanguages(): ArrayList<LanguageInfo> {
        var result = ArrayList<LanguageInfo>()
        try {
            let client = getMTProtoClient()
            let req = LangpackGetLanguages()
            req.langPack = ""
            let data = client.sendRequest(req.toBytes())
            if (data.size > 8) {
                result = this.parseLanguages(data)
                Hilog.info(0, "CjTelegram", "[LangSuggestion] Loaded ${result.size} languages")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[LangSuggestion] Error loading languages: ${e}")
        }
        if (result.isEmpty()) {
            this.addDefaultLanguagesTo(result)
        }
        return result
    }

    /**
     * Suggest a language based on system locale.
     * Returns the best matching LanguageInfo, or None if current language matches or no suggestion.
     */
    public func getSuggestedLanguage(): Option<LanguageInfo> {
        let systemLocale = this.getSystemLocaleCode()
        let currentCode = getAuthStorage().getLangCode()
        if (systemLocale == "en" || systemLocale.size == 0) {
            return None
        }
        let available = this.getAvailableLanguages()
        let suggested = this.matchLocaleToLanguage(systemLocale, available)
        match (suggested) {
            case Some(lang) =>
                if (lang.langCode == currentCode) {
                    return None
                }
                return Some(lang)
            case None =>
                return None
        }
    }

    /**
     * Apply a language: persist, fetch strings, update I18n.
     */
    public func applyLanguage(langCode: String): Bool {
        let storage = getAuthStorage()
        let i18n = getI18n()
        storage.saveLangCode(langCode)
        i18n.langCode = langCode
        if (langCode == "en") {
            i18n.loadDefaults()
            Hilog.info(0, "CjTelegram", "[LangSuggestion] Set to English")
            return true
        }
        try {
            let client = getMTProtoClient()
            let req = LangpackGetStrings()
            req.langPack = "android"
            req.langCode = langCode
            let keys = req.keys
            keys.add("Settings")
            keys.add("Contacts")
            keys.add("Calls")
            keys.add("SavedMessages")
            keys.add("Devices")
            keys.add("ChatFolders")
            keys.add("NotificationsAndSounds")
            keys.add("PrivacyAndSecurity")
            keys.add("DataAndStorage")
            keys.add("Appearance")
            keys.add("Language")
            keys.add("LogOut")
            keys.add("Chats")
            keys.add("Search")
            keys.add("Message")
            keys.add("Send")
            keys.add("Photo")
            keys.add("Video")
            keys.add("File")
            keys.add("Done")
            keys.add("Cancel")
            keys.add("Save")
            keys.add("Delete")
            keys.add("Edit")
            keys.add("OK")
            keys.add("Loading")
            keys.add("Back")
            keys.add("SendMessage")
            keys.add("Call")
            keys.add("VideoCall")
            keys.add("BlockUser")
            keys.add("UnblockUser")
            keys.add("Premium")
            let data = client.sendRequest(req.toBytes())
            if (data.size > 8) {
                let map = this.parseLangPackStrings(data)
                if (map.size > 0) {
                    this.applyTranslationMap(map)
                    Hilog.info(0, "CjTelegram", "[LangSuggestion] Applied ${map.size} strings for ${langCode}")
                    return true
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[LangSuggestion] Error applying language: ${e}")
        }
        return true
    }

    private func parseLanguages(data: Array<Byte>): ArrayList<LanguageInfo> {
        let result = ArrayList<LanguageInfo>()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()
        if (constructor != 0x1cb5c415) {
            return result
        }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            try {
                let langConst = d.readUInt32()
                if (langConst == 0xeeca5ce3) {
                    let flags = d.readInt32()
                    let name = d.readString()
                    let nativeName = d.readString()
                    let langCode = d.readString()
                    if ((flags & 2) != 0) { let _ = d.readString() }
                    let _ = d.readString()
                    let _ = d.readInt32()
                    let _ = d.readInt32()
                    let _ = d.readString()
                    let info = LanguageInfo()
                    info.name = name
                    info.nativeName = nativeName
                    info.langCode = langCode
                    info.isOfficial = (flags & 1) != 0
                    result.add(info)
                }
            } catch (_e: Exception) {
                break
            }
            i = i + 1
        }
        return result
    }

    private func addDefaultLanguagesTo(target: ArrayList<LanguageInfo>): Unit {
        let defaults = [
            ("English", "English", "en"),
            ("Chinese (Simplified)", "简体中文", "zh-hans-raw"),
            ("Japanese", "日本語", "ja-raw"),
            ("Korean", "한국어", "ko"),
            ("German", "Deutsch", "de"),
            ("Spanish", "Español", "es"),
            ("French", "Français", "fr"),
            ("Italian", "Italiano", "it"),
            ("Portuguese", "Português", "pt-br"),
            ("Russian", "Русский", "ru")
        ]
        for (item in defaults) {
            let info = LanguageInfo()
            info.name = item[0]
            info.nativeName = item[1]
            info.langCode = item[2]
            info.isOfficial = true
            target.add(info)
        }
    }

    private func matchLocaleToLanguage(locale: String, available: ArrayList<LanguageInfo>): Option<LanguageInfo> {
        let lower = locale.toAsciiLower()
        for (lang in available) {
            let code = lang.langCode.toAsciiLower()
            if (code == lower) {
                return Some(lang)
            }
            if (code.startsWith(lower) || lower.startsWith(code)) {
                return Some(lang)
            }
        }
        if (lower.startsWith("zh")) {
            for (lang in available) {
                if (lang.langCode.contains("zh-hans") || lang.langCode.contains("zh-hans-raw")) {
                    return Some(lang)
                }
            }
        }
        if (lower.startsWith("ja")) {
            for (lang in available) {
                if (lang.langCode.contains("ja") || lang.langCode.contains("ja-raw")) {
                    return Some(lang)
                }
            }
        }
        if (lower.startsWith("ko")) {
            for (lang in available) {
                if (lang.langCode.contains("ko")) {
                    return Some(lang)
                }
            }
        }
        return None
    }

    private func parseLangPackStrings(data: Array<Byte>): HashMap<String, String> {
        let result = HashMap<String, String>()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()
        if (constructor != 0x1cb5c415) {
            return result
        }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            try {
                let strConst = d.readUInt32()
                match (strConst) {
                    case 0xcad181f6 =>
                        let key = d.readString()
                        let value = d.readString()
                        result[key] = value
                    case 0x6c47ac9f =>
                        let flags = d.readInt32()
                        let key = d.readString()
                        if ((flags & 1) != 0) { result[key + "_0"] = d.readString() }
                        if ((flags & 2) != 0) { result[key + "_1"] = d.readString() }
                        if ((flags & 4) != 0) { result[key + "_2"] = d.readString() }
                        if ((flags & 8) != 0) { result[key + "_3_10"] = d.readString() }
                        if ((flags & 16) != 0) { result[key + "_many"] = d.readString() }
                        let other = d.readString()
                        result[key] = other
                        result[key + "_any"] = other
                    case 0x2979eeb2 =>
                        let _ = d.readString()
                    case _ =>
                        break
                }
            } catch (_e: Exception) {
                break
            }
            i = i + 1
        }
        return result
    }

    private func applyTranslationMap(map: HashMap<String, String>): Unit {
        let i18n = getI18n()
        let mapping = HashMap<String, String>()
        mapping["Settings"] = "Settings.Title"
        mapping["Contacts"] = "Contacts.Title"
        mapping["Calls"] = "Tabs.Calls"
        mapping["Chats"] = "Tabs.Chats"
        mapping["SavedMessages"] = "Settings.SavedMessages"
        mapping["Devices"] = "Settings.Devices"
        mapping["ChatFolders"] = "Settings.ChatFolders"
        mapping["NotificationsAndSounds"] = "Settings.Notifications"
        mapping["PrivacyAndSecurity"] = "Settings.Privacy"
        mapping["DataAndStorage"] = "Settings.DataStorage"
        mapping["Appearance"] = "Settings.Appearance"
        mapping["Language"] = "Settings.Language"
        mapping["LogOut"] = "Settings.Logout"
        mapping["Search"] = "Common.Search"
        mapping["Message"] = "ChatRoom.TypeMessage"
        mapping["Send"] = "ChatRoom.Send"
        mapping["Photo"] = "ChatRoom.Photo"
        mapping["Video"] = "ChatRoom.Video"
        mapping["File"] = "ChatRoom.File"
        mapping["Done"] = "Common.Done"
        mapping["Cancel"] = "Common.Cancel"
        mapping["Save"] = "Common.Save"
        mapping["Delete"] = "Common.Delete"
        mapping["Edit"] = "Common.Edit"
        mapping["OK"] = "Common.OK"
        mapping["Loading"] = "Common.Loading"
        mapping["Back"] = "Common.Back"
        mapping["SendMessage"] = "Profile.SendMessage"
        mapping["Call"] = "Profile.Call"
        mapping["VideoCall"] = "Profile.VideoCall"
        mapping["BlockUser"] = "Profile.Block"
        mapping["UnblockUser"] = "Profile.Unblock"
        let translated = HashMap<String, String>()
        for ((serverKey, value) in map) {
            if (mapping.contains(serverKey)) {
                let i18nKey = mapping[serverKey]
                translated[i18nKey] = value
            } else {
                translated[serverKey] = value
            }
        }
        i18n.applyStrings(translated)
    }
}
