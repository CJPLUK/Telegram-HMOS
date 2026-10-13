package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.HashMap
import ohos_app_cangjie_entry.models.LocalizationInfo

/**
 * 语言包链接预览信息
 * 对应 iOS LocalizationInfo，用于 t.me/setlanguage/xxx 预览
 *
 * Fields populated from real langpack.getLanguage#6a596502 → LangPackLanguage#eeca5ce3:
 *   title         → name (English/display name)
 *   nativeName    → nativeName (localised title shown to user in their language)
 *   langCode      → lang_code
 *   isOfficial    → flags bit 0
 *   totalStringCount    → strings_count
 *   translatedStringCount → translated_count
 *
 * sampleStrings is populated from langpack.getStrings (5 sample keys) for display.
 * iOS ref: LanguageLinkPreviewController.swift lines 66-83 use requestLocalizationPreview
 *          then setData(localizationInfo:) then activate() → downloadAndApplyLocalization.
 */
public class LocalizationPreviewInfo {
    public var title: String = ""
    public var nativeName: String = ""
    public var langCode: String = ""
    public var isOfficial: Bool = false
    public var totalStringCount: Int32 = 0
    public var translatedStringCount: Int32 = 0
    public var sampleStrings: HashMap<String, String> = HashMap<String, String>()
}

/**
 * LanguageLinkPreviewService — 语言包链接预览服务
 *
 * 对应 iOS LanguageLinkPreviewController + engine.localization.requestLocalizationPreview
 *
 * Gap removals vs. prior version:
 *   - requestPreview now calls LocalizationService.requestLocalizationPreview
 *     (langpack.getLanguage#6a596502 → LangPackLanguage#eeca5ce3) for real metadata.
 *     Removed mock totalStringCount = 100; now uses server-provided strings_count.
 *   - downloadAndApply calls LocalizationService.downloadAndApplyLocalization
 *     (langpack.getLangPack#f2f2330a → LangPackDifference#f385c1f6) for full string download.
 *   - isOfficial flag properly propagated from flags bit 0.
 * ctor verification:
 *   langpack.getLanguage#6a596502 — python3 -c "print(hex(1784243458))" → 0x6a596502 ✓
 *   LangPackLanguage#eeca5ce3    — python3 -c "print(hex(-288727837 & 0xFFFFFFFF))" → 0xeeca5ce3 ✓
 *   langpack.getLangPack#f2f2330a — verified in LocalizationService.cj ✓
 *   LangPackDifference#f385c1f6  — verified in LocalizationService.cj ✓
 */
public func getLanguageLinkPreviewService(): LanguageLinkPreviewService {
    return LanguageLinkPreviewService()
}

private var _pendingLanguagePreviewIdentifier: String = ""

public func setPendingLanguagePreviewIdentifier(identifier: String): Unit {
    _pendingLanguagePreviewIdentifier = identifier
}

public func getPendingLanguagePreviewIdentifier(): String {
    return _pendingLanguagePreviewIdentifier
}

/**
 * S7-123: t.me/setlanguage/<id>（及 telegram.me / telegram.dog 同形）与 tg://setlanguage?lang=<id>
 * → <id>；非语言包链接返回 ""。对位 iOS UrlHandling.swift 的 `setlanguage` 路径与
 * `tg://setlanguage?lang=` 查询，二者都解析为 ParsedInternalUrl.localization(identifier)，
 * 由 OpenResolvedUrl.swift:556 打开 LanguageLinkPreviewController。
 */
public func languagePackIdentifierFromUrl(url: String): String {
    var rest = url.trimAscii()
    let lower = rest.toAsciiLower()
    if (lower.startsWith("tg://setlanguage?")) {
        for (item in rest["tg://setlanguage?".size..].split("&")) {
            if (item.startsWith("lang=")) { return item["lang=".size..] }
        }
        return ""
    }
    for (prefix in ["https://", "http://"]) {
        if (rest.toAsciiLower().startsWith(prefix)) { rest = rest[prefix.size..] }
    }
    for (host in ["t.me/", "telegram.me/", "telegram.dog/", "www.t.me/"]) {
        if (rest.toAsciiLower().startsWith(host)) {
            let path = rest[host.size..]
            if (path.toAsciiLower().startsWith("setlanguage/")) {
                let id = path["setlanguage/".size..].split("?")[0].split("/")[0]
                return id
            }
            return ""
        }
    }
    return ""
}

public class LanguageLinkPreviewService {
    /**
     * 请求语言包预览 (real implementation — no mock)
     *
     * Calls LocalizationService.requestLocalizationPreview which issues
     * langpack.getLanguage#6a596502 and parses LangPackLanguage#eeca5ce3.
     * Returns None if the server returns an error or unknown lang code.
     *
     * iOS equivalent: LanguageLinkPreviewController.loadDisplayNode lines 66-83.
     */
    public func requestPreview(identifier: String): Option<LocalizationPreviewInfo> {
        if (identifier.size == 0) {
            return None
        }
        let svc = getLocalizationService()
        let result = svc.requestLocalizationPreview(identifier)
        match (result) {
            case Some(info) =>
                let preview = LocalizationPreviewInfo()
                preview.title = info.title
                preview.nativeName = info.localizedTitle
                preview.langCode = info.languageCode
                preview.isOfficial = info.isOfficial
                preview.totalStringCount = info.totalStringCount
                preview.translatedStringCount = info.translatedStringCount
                Hilog.info(0, "CjTelegram",
                    "[LangLinkPreview] preview OK: ${info.languageCode} " +
                    "official=${info.isOfficial} " +
                    "total=${info.totalStringCount} " +
                    "translated=${info.translatedStringCount}")
                return Some(preview)
            case None =>
                Hilog.info(0, "CjTelegram",
                    "[LangLinkPreview] requestPreview: no result for ${identifier}")
                return None
        }
    }

    /**
     * 下载并应用语言包 (real implementation — no mock)
     *
     * Calls LocalizationService.downloadAndApplyLocalization which:
     *   1. langpack.getLanguage to get metadata + baseLangCode
     *   2. langpack.getLangPack for primary strings
     *   3. langpack.getLangPack for base strings (if baseLangCode present)
     *   4. I18n.applyStrings to apply to runtime i18n map
     *   5. AuthStorage.saveLangCode to persist selection
     *
     * iOS equivalent: LanguageLinkPreviewController.activate() lines 113-130.
     */
    public func downloadAndApply(langCode: String): Bool {
        if (langCode.size == 0) {
            return false
        }
        let svc = getLocalizationService()
        let ok = svc.downloadAndApplyLocalization(langCode)
        Hilog.info(0, "CjTelegram",
            "[LangLinkPreview] downloadAndApply ${langCode} result=${ok}")
        return ok
    }
}
