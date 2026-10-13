package ohos_app_cangjie_entry.models

import std.collection.ArrayList

/**
 * Language info from langpack.getLanguages (LangPackLanguage)
 * Shared by LanguageSettingsPage and LanguageSuggestionService
 */
public class LanguageInfo {
    public var name: String = ""
    public var nativeName: String = ""
    public var langCode: String = ""
    public var isOfficial: Bool = false

    public init() {}
}

public class LanguageInfoEntry <: ToString {
    public let lang: LanguageInfo

    public init(l: LanguageInfo) {
        this.lang = l
    }

    public func toString(): String {
        return this.lang.langCode
    }
}

/**
 * Rich localization info from langpack.getLanguage (LangPackLanguage, full fields)
 * Used by LocalizationService for preview and download/apply flows.
 * iOS equivalent: LocalizationInfo in TelegramCore/SyncCore_LocalizationInfo.swift
 */
public class LocalizationInfo {
    public var languageCode: String = ""
    public var baseLanguageCode: String = ""
    public var customPluralizationCode: String = ""
    public var title: String = ""
    public var localizedTitle: String = ""
    public var isOfficial: Bool = false
    public var totalStringCount: Int32 = 0
    public var translatedStringCount: Int32 = 0
    public var platformUrl: String = ""

    public init() {}
}

/**
 * Localization list state: available official + saved localizations.
 * iOS equivalent: LocalizationListState in SyncCore_LocalizationListState.swift
 * Stored in memory (session-scoped); lang code persisted in AuthStorage.
 */
public class LocalizationListState {
    public var availableOfficialLocalizations: ArrayList<LocalizationInfo> = ArrayList<LocalizationInfo>()
    public var availableSavedLocalizations: ArrayList<LocalizationInfo> = ArrayList<LocalizationInfo>()

    public init() {}
}

/**
 * Suggested localization info bundle.
 * iOS equivalent: SuggestedLocalizationInfo in TelegramCore.
 * Contains the suggested language + extracted key strings + available language list.
 */
public class SuggestedLocalizationInfo {
    public var languageCode: String = ""
    public var extractedStrings: ArrayList<(String, String)> = ArrayList<(String, String)>()
    public var availableLocalizations: ArrayList<LocalizationInfo> = ArrayList<LocalizationInfo>()

    public init() {}
}

/**
 * Country phone code info from help.CountryCode TL type.
 * iOS equivalent: Country.CountryCode in TelegramCore/Countries.swift
 */
public class CountryCodeInfo {
    public var code: String = ""
    public var prefixes: ArrayList<String> = ArrayList<String>()
    public var patterns: ArrayList<String> = ArrayList<String>()

    public init() {}
}

/**
 * Country info from help.getCountriesList (help.Country TL type).
 * iOS equivalent: Country in TelegramCore/Countries.swift
 * Fields: iso2 (id), defaultName (name), localizedName (name flag.1), countryCodes, hidden (flag.0)
 */
public class CountryInfo {
    public var iso2: String = ""
    public var defaultName: String = ""
    public var localizedName: String = ""
    public var countryCodes: ArrayList<CountryCodeInfo> = ArrayList<CountryCodeInfo>()
    public var hidden: Bool = false

    public init() {}
}
