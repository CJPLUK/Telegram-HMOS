package ohos_app_cangjie_entry.services

import std.collection.ArrayList
import std.collection.HashMap
import kit.PerformanceAnalysisKit.Hilog
import kit.ArkUI.launch
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.models.{
    LanguageInfo,
    LocalizationInfo,
    LocalizationListState,
    SuggestedLocalizationInfo,
    CountryInfo,
    CountryCodeInfo
}
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    LangpackGetLanguages,
    LangpackGetStrings,
    LangpackGetLanguage,
    LangpackGetLangPack,
    HelpGetCountriesList,
    TLDeserializer
}
import ohos_app_cangjie_entry.core.storage.{getAuthStorage, getI18n, publishPresentationStrings}

/**
 * LocalizationService — 本地化服务
 *
 * 对应 iOS TelegramEngine.Localization 的 6 个核心能力
 * 完整实现 P2-164 所需的所有 gap:
 *   1. getCountriesList      — help.getCountriesList#735787a8
 *   2. synchronizedLocalizationListState — langpack.getLanguages#42c6978f
 *   3. suggestedLocalizationInfo — langpack.getLanguages + langpack.getStrings
 *   4. requestLocalizationPreview — langpack.getLanguage#6a596502
 *   5. downloadAndApplyLocalization — langpack.getLangPack#f2f2330a
 *   6. removeSavedLocalization — in-memory list update
 *
 * TL constructor IDs all verified by tl_codegen.py from telegram_api.tl.
 */
public func getLocalizationService(): LocalizationService {
    let svc = LocalizationService()
    loadLocalizationListState()
    loadCountriesCache()
    return svc
}

// In-memory localization list state (session-scoped, mirrors iOS postbox.transaction pattern)
var _localizationListState: LocalizationListState = LocalizationListState()

// In-memory countries cache: hash -> list
var _countriesCache: ArrayList<CountryInfo> = ArrayList<CountryInfo>()
var _countriesCacheHash: Int32 = 0

// ==================== FIX-1: Localization list persistence ====================

/**
 * Serialize availableSavedLocalizations to JSON array string and persist via AuthStorage.
 * Format: [{"lc":"en","blc":"","cpc":"","t":"English","lt":"English","o":1,"ts":1000,"tr":800,"pu":""}]
 */
func saveLocalizationListState(): Unit {
    let saved = _localizationListState.availableSavedLocalizations
    let arr = JsonArray()
    var i: Int64 = 0
    while (i < saved.size) {
        let info = saved[i]
        let obj = JsonObject()
        obj.setString("lc", info.languageCode)
        obj.setString("blc", info.baseLanguageCode)
        obj.setString("cpc", info.customPluralizationCode)
        obj.setString("t", info.title)
        obj.setString("lt", info.localizedTitle)
        let oFlag: Int64 = if (info.isOfficial) { 1 } else { 0 }
        obj.setInt("o", oFlag)
        obj.setInt("ts", Int64(info.totalStringCount))
        obj.setInt("tr", Int64(info.translatedStringCount))
        obj.setString("pu", info.platformUrl)
        arr.addObject(obj)
        i = i + 1
    }
    let json = arr.toJsonString()
    getAuthStorage().saveLocalizationSavedList(json)
}

/**
 * Load availableSavedLocalizations from AuthStorage Preferences on startup.
 */
func loadLocalizationListState(): Unit {
    let json = getAuthStorage().getLocalizationSavedList()
    if (json.size == 0) {
        return
    }
    try {
        let arr = JsonParser.parseArray(json)
        let result = ArrayList<LocalizationInfo>()
        var i: Int64 = 0
        while (i < arr.size()) {
            let obj = arr.getObject(i)
            let info = LocalizationInfo()
            info.languageCode = obj.getString("lc")
            info.baseLanguageCode = obj.getString("blc")
            info.customPluralizationCode = obj.getString("cpc")
            info.title = obj.getString("t")
            info.localizedTitle = obj.getString("lt")
            info.isOfficial = obj.getInt("o") != 0
            info.totalStringCount = Int32(obj.getInt("ts"))
            info.translatedStringCount = Int32(obj.getInt("tr"))
            info.platformUrl = obj.getString("pu")
            result.add(info)
            i = i + 1
        }
        _localizationListState.availableSavedLocalizations = result
        Hilog.info(0, "CjTelegram", "[LocalizationService] Loaded ${result.size} saved localizations from Preferences")
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[LocalizationService] Failed to load localization list: ${e}")
    }
}

// ==================== FIX-2: Countries cache persistence ====================

/**
 * Persist _countriesCache + _countriesCacheHash to AuthStorage Preferences.
 * Each CountryInfo serialized as JSON object; code list uses first code only for compactness.
 */
func saveCountriesCache(): Unit {
    let arr = JsonArray()
    var i: Int64 = 0
    while (i < _countriesCache.size) {
        let c = _countriesCache[i]
        let obj = JsonObject()
        obj.setString("iso2", c.iso2)
        obj.setString("dn", c.defaultName)
        obj.setString("ln", c.localizedName)
        let hFlag: Int64 = if (c.hidden) { 1 } else { 0 }
        obj.setInt("h", hFlag)
        // Store countryCodes as comma-separated codes string for compactness
        var codesStr = ""
        var ci: Int64 = 0
        while (ci < c.countryCodes.size) {
            let cc = c.countryCodes[ci]
            if (ci > 0) {
                codesStr = codesStr + ","
            }
            codesStr = codesStr + cc.code
            ci = ci + 1
        }
        obj.setString("cc", codesStr)
        arr.addObject(obj)
        i = i + 1
    }
    let json = arr.toJsonString()
    let storage = getAuthStorage()
    storage.saveCountriesCacheHash(_countriesCacheHash)
    storage.saveCountriesCacheData(json)
}

/**
 * Restore _countriesCache + _countriesCacheHash from AuthStorage Preferences on startup.
 */
func loadCountriesCache(): Unit {
    let storage = getAuthStorage()
    let hash = storage.getCountriesCacheHash()
    let json = storage.getCountriesCacheData()
    if (json.size == 0) {
        return
    }
    try {
        let arr = JsonParser.parseArray(json)
        let result = ArrayList<CountryInfo>()
        var i: Int64 = 0
        while (i < arr.size()) {
            let obj = arr.getObject(i)
            let c = CountryInfo()
            c.iso2 = obj.getString("iso2")
            c.defaultName = obj.getString("dn")
            c.localizedName = obj.getString("ln")
            c.hidden = obj.getInt("h") != 0
            // Restore countryCodes from comma-separated string
            let codesStr = obj.getString("cc")
            if (codesStr.size > 0) {
                let parts = codesStr.split(",")
                for (part in parts) {
                    let trimmed = part.trimAscii()
                    if (trimmed.size > 0) {
                        let cc = CountryCodeInfo()
                        cc.code = trimmed
                        c.countryCodes.add(cc)
                    }
                }
            }
            result.add(c)
            i = i + 1
        }
        _countriesCache = result
        _countriesCacheHash = hash
        Hilog.info(0, "CjTelegram", "[LocalizationService] Loaded ${result.size} countries from Preferences (hash=${hash})")
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[LocalizationService] Failed to load countries cache: ${e}")
    }
}

public class LocalizationService {
    private let langSuggestion = getLanguageSuggestionService()

    // ==================== Existing methods (unchanged) ====================

    public func fetchAvailableLanguages(): ArrayList<LanguageInfo> {
        return this.langSuggestion.getAvailableLanguages()
    }

    public func getCurrentLangCode(): String {
        return getAuthStorage().getLangCode()
    }

    public func applyLanguage(langCode: String): Bool {
        return this.langSuggestion.applyLanguage(langCode)
    }

    public func getTranslation(key: String): String {
        return getI18n().get(key)
    }

    // ==================== Gap 1: getCountriesList ====================

    /**
     * Fetch countries list via help.getCountriesList with hash validation (FIX-4).
     * Always sends hash-validated request (aligns with iOS reactive pattern).
     * iOS: _internal_getCountriesList in TelegramCore/Countries.swift
     *
     * help.countriesListNotModified#93cc1f32 — hash matched, return cached
     * help.countriesList#87d0759e countries:Vector<help.Country> hash:int — full list
     * forceUpdate=false → send stored hash; server returns notModified(0x93cc1f32) → return cache.
     * Server returns countriesList(0x87d0759e) → update cache, persist, return new list.
     * forceUpdate=true → send hash=0 to force full reload.
     */
    public func getCountriesList(langCode: String, forceUpdate: Bool): ArrayList<CountryInfo> {
        try {
            let client = getMTProtoClient()
            let req = HelpGetCountriesList()
            req.langCode = langCode
            req.hash = if (forceUpdate) { 0 } else { _countriesCacheHash }
            let data = client.sendRequest(req.toBytes())
            if (data.size > 4) {
                let d = TLDeserializer(data)
                let constructor = d.readUInt32()
                if (constructor == 0x93cc1f32) {
                    // help.countriesListNotModified#93cc1f32 — hash matched, return cache
                    Hilog.info(0, "CjTelegram", "[LocalizationService] Countries list not modified (hash match)")
                    if (_countriesCache.size > 0) {
                        return _countriesCache
                    }
                    return this.defaultCountries()
                }
                if (constructor == 0x87d0759e) {
                    // help.countriesList#87d0759e — full list updated
                    let countries = this.parseCountriesList(d)
                    let newHash = d.readInt32()
                    _countriesCache = countries
                    _countriesCacheHash = newHash
                    saveCountriesCache()
                    Hilog.info(0, "CjTelegram", "[LocalizationService] Loaded ${countries.size} countries (hash=${newHash})")
                    return countries
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalizationService] getCountriesList error: ${e}")
        }
        if (_countriesCache.size > 0) {
            return _countriesCache
        }
        return this.defaultCountries()
    }

    private func parseCountriesList(d: TLDeserializer): ArrayList<CountryInfo> {
        let result = ArrayList<CountryInfo>()
        // expect Vector constructor
        let vecConst = d.readUInt32()
        if (vecConst != 0x1cb5c415) {
            return result
        }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            try {
                let countryConst = d.readUInt32()
                if (countryConst == 0xc3878e23) {
                    // help.country#c3878e23 flags:# hidden:flags.0?true iso2:string default_name:string name:flags.1?string country_codes:Vector<help.CountryCode>
                    let flags = d.readInt32()
                    let iso2 = d.readString()
                    let defaultName = d.readString()
                    var localizedName: String = ""
                    if ((flags & 2) != 0) {
                        localizedName = d.readString()
                    }
                    let codes = this.parseCountryCodes(d)
                    let country = CountryInfo()
                    country.iso2 = iso2
                    country.defaultName = defaultName
                    country.localizedName = localizedName
                    country.countryCodes = codes
                    country.hidden = (flags & 1) != 0
                    result.add(country)
                }
            } catch (_e: Exception) {
                break
            }
            i = i + 1
        }
        return result
    }

    private func parseCountryCodes(d: TLDeserializer): ArrayList<CountryCodeInfo> {
        let result = ArrayList<CountryCodeInfo>()
        let vecConst = d.readUInt32()
        if (vecConst != 0x1cb5c415) {
            return result
        }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            try {
                let codeConst = d.readUInt32()
                if (codeConst == 0x4203c5ef) {
                    // help.countryCode#4203c5ef flags:# country_code:string prefixes:flags.0?Vector<string> patterns:flags.1?Vector<string>
                    let flags = d.readInt32()
                    let codeStr = d.readString()
                    let prefixes = ArrayList<String>()
                    if ((flags & 1) != 0) {
                        this.readStringVector(d, prefixes)
                    }
                    let patterns = ArrayList<String>()
                    if ((flags & 2) != 0) {
                        this.readStringVector(d, patterns)
                    }
                    let cc = CountryCodeInfo()
                    cc.code = codeStr
                    cc.prefixes = prefixes
                    cc.patterns = patterns
                    result.add(cc)
                }
            } catch (_e: Exception) {
                break
            }
            i = i + 1
        }
        return result
    }

    private func readStringVector(d: TLDeserializer, target: ArrayList<String>): Unit {
        let vecConst = d.readUInt32()
        if (vecConst != 0x1cb5c415) {
            return
        }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            try {
                let s = d.readString()
                target.add(s)
            } catch (_e: Exception) {
                break
            }
            i = i + 1
        }
    }

    private func defaultCountries(): ArrayList<CountryInfo> {
        let defaults = [
            ("US", "United States", "+1"),
            ("GB", "United Kingdom", "+44"),
            ("CN", "China", "+86"),
            ("RU", "Russia", "+7"),
            ("DE", "Germany", "+49"),
            ("FR", "France", "+33"),
            ("JP", "Japan", "+81"),
            ("KR", "South Korea", "+82"),
            ("IN", "India", "+91"),
            ("BR", "Brazil", "+55")
        ]
        let result = ArrayList<CountryInfo>()
        for (item in defaults) {
            let c = CountryInfo()
            c.iso2 = item[0]
            c.defaultName = item[1]
            let cc = CountryCodeInfo()
            cc.code = item[2]
            c.countryCodes.add(cc)
            result.add(c)
        }
        return result
    }

    // ==================== Gap 2: synchronizedLocalizationListState ====================

    /**
     * Sync available localization list from server.
     * Calls langpack.getLanguages, updates in-memory LocalizationListState.
     * iOS: _internal_synchronizedLocalizationListState in LocalizationListState.swift
     */
    public func synchronizedLocalizationListState(): Bool {
        try {
            let client = getMTProtoClient()
            let req = LangpackGetLanguages()
            req.langPack = ""
            let data = client.sendRequest(req.toBytes())
            if (data.size > 8) {
                let infos = this.parseLangPackLanguages(data)
                if (infos.size > 0) {
                    _localizationListState.availableOfficialLocalizations = infos
                    Hilog.info(0, "CjTelegram", "[LocalizationService] Synced ${infos.size} official localizations")
                    return true
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalizationService] synchronizedLocalizationListState error: ${e}")
        }
        return false
    }

    /**
     * Get current localization list state (in-memory).
     */
    public func getLocalizationListState(): LocalizationListState {
        return _localizationListState
    }

    // ==================== Gap 3: suggestedLocalizationInfo ====================

    /**
     * Get suggested localization info for a given language code.
     * Fetches language list + selected strings for the suggested language.
     * iOS: _internal_suggestedLocalizationInfo in Localizations.swift
     */
    public func suggestedLocalizationInfo(languageCode: String, extractKeys: ArrayList<String>): Option<SuggestedLocalizationInfo> {
        try {
            let client = getMTProtoClient()

            // 1. Fetch full language list
            let langReq = LangpackGetLanguages()
            langReq.langPack = ""
            let langData = client.sendRequest(langReq.toBytes())
            let availableInfos = if (langData.size > 8) {
                this.parseLangPackLanguages(langData)
            } else {
                ArrayList<LocalizationInfo>()
            }

            // 2. Fetch selected strings for the suggested language
            let strReq = LangpackGetStrings()
            strReq.langPack = ""
            strReq.langCode = languageCode
            for (k in extractKeys) {
                strReq.keys.add(k)
            }
            let strData = client.sendRequest(strReq.toBytes())
            let extractedPairs = this.parseLangPackStringsAsPairs(strData)

            let info = SuggestedLocalizationInfo()
            info.languageCode = languageCode
            info.extractedStrings = extractedPairs
            info.availableLocalizations = availableInfos
            Hilog.info(0, "CjTelegram", "[LocalizationService] suggestedLocalizationInfo for ${languageCode}: ${extractedPairs.size} strings, ${availableInfos.size} langs")
            return Some(info)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalizationService] suggestedLocalizationInfo error: ${e}")
            return None
        }
    }

    private func parseLangPackStringsAsPairs(data: Array<Byte>): ArrayList<(String, String)> {
        let result = ArrayList<(String, String)>()
        if (data.size < 8) {
            return result
        }
        let d = TLDeserializer(data)
        let vecConst = d.readUInt32()
        if (vecConst != 0x1cb5c415) {
            return result
        }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            try {
                let strConst = d.readUInt32()
                if (strConst == 0xcad181f6) {
                    // langPackString#cad181f6 key:string value:string
                    let key = d.readString()
                    let value = d.readString()
                    result.add((key, value))
                } else if (strConst == 0x6c47ac9f) {
                    // langPackStringPluralized#6c47ac9f flags:# key:string ...optional... other_value:string
                    let flags = d.readInt32()
                    let key = d.readString()
                    if ((flags & 1) != 0) { result.add((key + "_0", d.readString())) }
                    if ((flags & 2) != 0) { result.add((key + "_1", d.readString())) }
                    if ((flags & 4) != 0) { result.add((key + "_2", d.readString())) }
                    if ((flags & 8) != 0) { result.add((key + "_3_10", d.readString())) }
                    if ((flags & 16) != 0) { result.add((key + "_many", d.readString())) }
                    let other = d.readString()
                    result.add((key, other))
                    result.add((key + "_any", other))
                } else if (strConst == 0x2979eeb2) {
                    // langPackStringDeleted#2979eeb2 key:string
                    let key = d.readString()
                    result.add((key, ""))
                } else {
                    break
                }
            } catch (_e: Exception) {
                break
            }
            i = i + 1
        }
        return result
    }

    // ==================== Gap 4: requestLocalizationPreview ====================

    /**
     * Request a preview (metadata) for a specific language pack.
     * Calls langpack.getLanguage#6a596502 to get LangPackLanguage.
     * iOS: _internal_requestLocalizationPreview in LocalizationPreview.swift
     */
    public func requestLocalizationPreview(identifier: String): Option<LocalizationInfo> {
        try {
            let client = getMTProtoClient()
            let req = LangpackGetLanguage()
            req.langPack = ""
            req.langCode = identifier
            let data = client.sendRequest(req.toBytes())
            if (data.size > 4) {
                let d = TLDeserializer(data)
                let langInfo = this.parseSingleLangPackLanguage(d)
                match (langInfo) {
                    case Some(info) =>
                        Hilog.info(0, "CjTelegram", "[LocalizationService] Preview for ${identifier}: ${info.title} (${info.translatedStringCount} strings)")
                        return Some(info)
                    case None => return None
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalizationService] requestLocalizationPreview error: ${e}")
        }
        return None
    }

    // ==================== Gap 5: downloadAndApplyLocalization ====================

    /**
     * Download full language pack and apply it to the app.
     * Calls langpack.getLangPack#f2f2330a, parses LangPackDifference, applies strings via I18n.
     * If preview has baseLangCode, also downloads base pack (same flow as iOS secondary component).
     * iOS: _internal_downloadAndApplyLocalization in Localizations.swift
     */
    public func downloadAndApplyLocalization(languageCode: String): Bool {
        if (languageCode == "en") {
            // iOS keeps English as a server localization too: the primary component is
            // synchronised with langpack.getDifference (ManagedLocalizationUpdatesOperations
            // .swift:155-185), so server wording (e.g. "Background Updates") overrides the
            // bundled strings. Built-in defaults first, then the cached / downloaded pack.
            let storage = getAuthStorage()
            let i18n = getI18n()
            i18n.langCode = "en"
            i18n.loadDefaults()
            if (!this.downloadLangPackAndApply("en")) {
                let _ = this.loadLangPackData("en")
            }
            storage.saveLangCode("en")
            storage.saveLangBaseCode("")
            publishPresentationStrings()
            return true
        }
        // Step 1: get preview metadata
        let preview = this.requestLocalizationPreview(languageCode)
        match (preview) {
            case Some(info) =>
                // iOS builds PresentationStrings from the base component first and then
                // overlays the selected component. Reversing this order makes base strings
                // overwrite the selected language.
                let i18n = getI18n()
                i18n.loadDefaults()
                if (info.baseLanguageCode.size > 0) {
                    let baseApplied = this.downloadLangPackAndApply(info.baseLanguageCode)
                    if (!baseApplied) {
                        return false
                    }
                }
                let primaryApplied = this.downloadLangPackAndApply(info.languageCode)
                if (!primaryApplied) {
                    return false
                }
                // Step 4: persist lang code
                let storage = getAuthStorage()
                storage.saveLangCode(info.languageCode)
                storage.saveLangBaseCode(info.baseLanguageCode)
                i18n.langCode = info.languageCode
                // Step 5: update saved localizations list (insert at front, dedup)
                this.upsertSavedLocalization(info)
                publishPresentationStrings()
                Hilog.info(0, "CjTelegram", "[LocalizationService] downloadAndApplyLocalization done: ${info.languageCode}")
                return true
            case None =>
                // fallback: direct download without preview
                getI18n().loadDefaults()
                let applied = this.downloadLangPackAndApply(languageCode)
                if (applied) {
                    let storage = getAuthStorage()
                    storage.saveLangCode(languageCode)
                    storage.saveLangBaseCode("")
                    let i18n = getI18n()
                    i18n.langCode = languageCode
                    publishPresentationStrings()
                }
                return applied
        }
    }

    /**
     * Download LangPackDifference and apply strings directly.
     * langpack.getLangPack#f2f2330a → LangPackDifference#f385c1f6
     * Both constructor IDs verified by tl_codegen.py.
     */
    private func downloadLangPackAndApply(langCode: String): Bool {
        try {
            let client = getMTProtoClient()
            let req = LangpackGetLangPack()
            req.langPack = ""
            req.langCode = langCode
            let data = client.sendRequest(req.toBytes())
            let applied = this.applyLangPackData(data, langCode)
            if (applied) {
                this.saveLangPackData(langCode, data)
            }
            return applied
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalizationService] downloadLangPackAndApply error for ${langCode}: ${e}")
            return false
        }
    }

    private func applyLangPackData(data: Array<Byte>, langCode: String): Bool {
        try {
            if (data.size < 8) { return false }
            let d = TLDeserializer(data)
            let constructor = d.readUInt32()
            if (constructor != 0xf385c1f6) {
                return false
            }
            // langPackDifference: lang_code from_version version strings:Vector<LangPackString>
            // 只接受与请求一致的语言包：缓存或响应里是别的语言时不能覆盖到当前语言上
            let packCode = d.readString()
            if (packCode != langCode && !packCode.startsWith(langCode + "-")) {
                Hilog.info(0, "CjTelegram", "[LocalizationService] LangPack code mismatch: got ${packCode}, want ${langCode}")
                return false
            }
            let _ = d.readInt32()
            let _ = d.readInt32()
            // now d is positioned at Vector<LangPackString>
            let vecConst = d.readUInt32()
            if (vecConst != 0x1cb5c415) {
                return false
            }
            let count = d.readInt32()
            let map = HashMap<String, String>()
            var i: Int32 = 0
            while (i < count) {
                try {
                    let strConst = d.readUInt32()
                    if (strConst == 0xcad181f6) {
                        let key = d.readString()
                        let value = d.readString()
                        map.add(key, value)
                    } else if (strConst == 0x6c47ac9f) {
                        let flags = d.readInt32()
                        let key = d.readString()
                        if ((flags & 1) != 0) { map.add(key + "_0", d.readString()) }
                        if ((flags & 2) != 0) { map.add(key + "_1", d.readString()) }
                        if ((flags & 4) != 0) { map.add(key + "_2", d.readString()) }
                        if ((flags & 8) != 0) { map.add(key + "_3_10", d.readString()) }
                        if ((flags & 16) != 0) { map.add(key + "_many", d.readString()) }
                        let other = d.readString()
                        map.add(key, other)
                        map.add(key + "_any", other)
                    } else if (strConst == 0x2979eeb2) {
                        let _ = d.readString()
                    } else {
                        break
                    }
                } catch (_e: Exception) {
                    break
                }
                i = i + 1
            }
            if (map.size > 0) {
                let i18n = getI18n()
                i18n.applyStrings(map)
                Hilog.info(0, "CjTelegram", "[LocalizationService] Applied LangPack ${map.size} strings for ${langCode}")
                return true
            }
            return false
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalizationService] applyLangPackData error for ${langCode}: ${e}")
            return false
        }
    }

    private func langPackCachePath(langCode: String): String {
        let filesDir = getAppFilesDir()
        if (filesDir.size == 0) { return "" }
        return filesDir + "/localization/" + langCode + ".tl"
    }

    private func saveLangPackData(langCode: String, data: Array<Byte>): Unit {
        let path = this.langPackCachePath(langCode)
        if (path.size == 0) { return }
        try {
            FileIo.mkdir(getAppFilesDir() + "/localization")
        } catch (_e: Exception) {}
        try {
            let file = FileIo.open(path, mode: 0o1101)
            let _ = FileIo.write(file.fd, data)
            FileIo.close(file)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalizationService] save lang pack failed: ${e}")
        }
    }

    private func loadLangPackData(langCode: String): Bool {
        let path = this.langPackCachePath(langCode)
        if (path.size == 0) { return false }
        try {
            if (!FileIo.access(path)) { return false }
            let stat = FileIo.stat(path)
            if (stat.size <= 0) { return false }
            let file = FileIo.open(path, mode: 0o0)
            let data = Array<Byte>(stat.size, repeat: 0)
            let _ = FileIo.read(file.fd, data)
            FileIo.close(file)
            return this.applyLangPackData(data, langCode)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalizationService] load lang pack failed: ${e}")
            return false
        }
    }

    /** Restore the complete selected pack before the root tabs are drawn. */
    public func restoreActiveLocalization(): Bool {
        let storage = getAuthStorage()
        let code = storage.getLangCode()
        let i18n = getI18n()
        i18n.langCode = code
        i18n.loadDefaults()
        if (code == "en") {
            // Cached server English pack over the bundled defaults, then refresh it in the
            // background (iOS synchronizeLocalizationUpdates for the "en" primary component).
            let _ = this.loadLangPackData("en")
            publishPresentationStrings()
            this.synchronizeEnglishLocalization()
            return true
        }
        let base = storage.getLangBaseCode()
        if (base.size > 0 && !this.loadLangPackData(base)) { return false }
        let restored = this.loadLangPackData(code)
        if (restored) {
            publishPresentationStrings()
        }
        return restored
    }

    private func synchronizeEnglishLocalization(): Unit {
        let svc = this
        let _ = spawn {
            try {
                let client = getMTProtoClient()
                let req = LangpackGetLangPack()
                req.langPack = ""
                req.langCode = "en"
                let data = client.sendRequest(req.toBytes())
                if (data.size < 8) { return }
                // The string table is read by the UI thread (tr/trSource): rebuild it there.
                launch {
                    if (getAuthStorage().getLangCode() == "en" && getI18n().langCode == "en") {
                        getI18n().loadDefaults()
                        if (svc.applyLangPackData(data, "en")) {
                            svc.saveLangPackData("en", data)
                        } else {
                            let _ = svc.loadLangPackData("en")
                        }
                        publishPresentationStrings()
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[LocalizationService] English localization sync failed: ${e}")
            }
        }
    }

    private func upsertSavedLocalization(info: LocalizationInfo): Unit {
        let saved = _localizationListState.availableSavedLocalizations
        // Remove existing entry for same lang code (dedup, like iOS)
        let toRemove = ArrayList<Int64>()
        var idx: Int64 = 0
        while (idx < saved.size) {
            if (saved[idx].languageCode == info.languageCode) {
                toRemove.add(idx)
            }
            idx = idx + 1
        }
        var ri: Int64 = toRemove.size - 1
        while (ri >= 0) {
            saved.remove(at: toRemove[ri])
            ri = ri - 1
        }
        // Insert at front (most recently used first)
        saved.add(info, at: 0)
        // FIX-1: persist after mutation
        saveLocalizationListState()
    }

    // ==================== Gap 6: removeSavedLocalization ====================

    /**
     * Remove a saved localization by language code.
     * iOS: _internal_removeSavedLocalization in LocalizationListState.swift
     */
    public func removeSavedLocalization(languageCode: String): Unit {
        let saved = _localizationListState.availableSavedLocalizations
        let toRemove = ArrayList<Int64>()
        var idx: Int64 = 0
        while (idx < saved.size) {
            if (saved[idx].languageCode == languageCode) {
                toRemove.add(idx)
            }
            idx = idx + 1
        }
        var ri: Int64 = toRemove.size - 1
        while (ri >= 0) {
            saved.remove(at: toRemove[ri])
            ri = ri - 1
        }
        Hilog.info(0, "CjTelegram", "[LocalizationService] Removed saved localization: ${languageCode}")
        // FIX-1: persist after removal
        saveLocalizationListState()
    }

    // ==================== Shared parsing helpers ====================

    /**
     * Parse a Vector<LangPackLanguage> response buffer to ArrayList<LocalizationInfo>.
     * Constructor: langPackLanguage#eeca5ce3 (verified by tl_codegen.py)
     */
    private func parseLangPackLanguages(data: Array<Byte>): ArrayList<LocalizationInfo> {
        let result = ArrayList<LocalizationInfo>()
        if (data.size < 8) {
            return result
        }
        let d = TLDeserializer(data)
        let vecConst = d.readUInt32()
        if (vecConst != 0x1cb5c415) {
            return result
        }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            try {
                let langConst = d.readUInt32()
                if (langConst == 0xeeca5ce3) {
                    // langPackLanguage#eeca5ce3 flags:# official:flags.0?true rtl:flags.2?true beta:flags.3?true
                    //   name:string native_name:string lang_code:string
                    //   base_lang_code:flags.1?string plural_code:string
                    //   strings_count:int translated_count:int translations_url:string
                    let flags = d.readInt32()
                    let name = d.readString()
                    let nativeName = d.readString()
                    let langCode = d.readString()
                    var baseLangCode: String = ""
                    if ((flags & 2) != 0) {
                        baseLangCode = d.readString()
                    }
                    let pluralCode = d.readString()
                    let stringsCount = d.readInt32()
                    let translatedCount = d.readInt32()
                    let translationsUrl = d.readString()
                    let info = LocalizationInfo()
                    info.languageCode = langCode
                    info.baseLanguageCode = baseLangCode
                    info.customPluralizationCode = pluralCode
                    info.title = name
                    info.localizedTitle = nativeName
                    info.isOfficial = (flags & 1) != 0
                    info.totalStringCount = stringsCount
                    info.translatedStringCount = translatedCount
                    info.platformUrl = translationsUrl
                    result.add(info)
                }
            } catch (_e: Exception) {
                break
            }
            i = i + 1
        }
        return result
    }

    /**
     * Parse a single LangPackLanguage from a TLDeserializer (for langpack.getLanguage response).
     * langPackLanguage#eeca5ce3
     */
    private func parseSingleLangPackLanguage(d: TLDeserializer): Option<LocalizationInfo> {
        try {
            let langConst = d.readUInt32()
            if (langConst != 0xeeca5ce3) {
                return None
            }
            let flags = d.readInt32()
            let name = d.readString()
            let nativeName = d.readString()
            let langCode = d.readString()
            var baseLangCode: String = ""
            if ((flags & 2) != 0) {
                baseLangCode = d.readString()
            }
            let pluralCode = d.readString()
            let stringsCount = d.readInt32()
            let translatedCount = d.readInt32()
            let translationsUrl = d.readString()
            let info = LocalizationInfo()
            info.languageCode = langCode
            info.baseLanguageCode = baseLangCode
            info.customPluralizationCode = pluralCode
            info.title = name
            info.localizedTitle = nativeName
            info.isOfficial = (flags & 1) != 0
            info.totalStringCount = stringsCount
            info.translatedStringCount = translatedCount
            info.platformUrl = translationsUrl
            return Some(info)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalizationService] parseSingleLangPackLanguage error: ${e}")
            return None
        }
    }
}
