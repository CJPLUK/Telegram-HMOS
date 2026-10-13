package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList
import std.sync.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}
import ohos_app_cangjie_entry.router.routerPop
import ohos_app_cangjie_entry.services.{getTranslateService, getSupportedLanguages, getPopularLanguages, TranslateLanguage, JsonParser, TranslationSettingsSnapshot, currentTranslationSettings}
import ohos_app_cangjie_entry.interop.{callArkAsync, LANGUAGE_DISPLAY_NAMES}

public class TranslationLanguageRow <: ToString {
    public let language: TranslateLanguage
    public let nativeName: String
    public init(language: TranslateLanguage, nativeName!: String = "") {
        this.language = language
        this.nativeName = nativeName
    }
    public func toString(): String { return this.language.code }
}

/** Source parity: TranslatonSettingsController.swift. */
@HybridComponentEntry
@Component
public class DoNotTranslateLanguagesPage {
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["translationSettings"] var translationSettings: TranslationSettingsSnapshot = currentTranslationSettings()
    @State var rows: ArrayList<TranslationLanguageRow> = ArrayList<TranslationLanguageRow>()
    @State var selected: Array<String> = Array<String>()
    @State var loaded: Bool = false

    private func text(key: String, fallback: String): String {
        return this.presentationStrings.getOr(key, fallback)
    }

    private func normalized(code: String): String {
        let raw = if (code.endsWith("-raw")) { code[0..(code.size - 4)] } else { code }
        if (raw.startsWith("zh")) { return "zh" }
        let parts = raw.split("-")
        return if (parts.size > 0) { parts[0] } else { raw }
    }

    private func contains(code: String): Bool {
        for (item in this.selected) { if (item == code) { return true } }
        return false
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let service = getTranslateService()
        let chosen = if (service.hasExplicitIgnoredLanguages()) {
            service.getIgnoredLanguages()
        } else {
            service.effectiveIgnoredLanguages()
        }
        this.selected = chosen
        let supported = this.sourceLanguages()
        let ordered = ArrayList<TranslationLanguageRow>()
        for (language in supported) { if (this.containsIn(chosen, language.code)) { ordered.add(TranslationLanguageRow(language)) } }
        for (language in supported) { if (!this.containsIn(chosen, language.code)) { ordered.add(TranslationLanguageRow(language)) } }
        this.rows = ordered
        this.loadNativeNames(ordered)
    }

    private func loadNativeNames(ordered: ArrayList<TranslationLanguageRow>): Unit {
        var codes = ""
        var i: Int64 = 0
        while (i < ordered.size) {
            if (i > 0) { codes = codes + "," }
            codes = codes + "\"${ordered[i].language.code}\""
            i = i + 1
        }
        callArkAsync(LANGUAGE_DISPLAY_NAMES, "{\"codes\":[${codes}]}", { response: String =>
            try {
                let names = JsonParser.parseObject(response).getArray("names")
                let updated = ArrayList<TranslationLanguageRow>()
                var index: Int64 = 0
                while (index < ordered.size) {
                    let name = if (index < names.size()) { names.getString(index) } else { ordered[index].language.name }
                    updated.add(TranslationLanguageRow(ordered[index].language, nativeName: name))
                    index = index + 1
                }
                launch { this.rows = updated }
            } catch (_e: Exception) {}
        })
    }

    private func containsIn(values: Array<String>, code: String): Bool {
        for (item in values) { if (item == code) { return true } }
        return false
    }

    /**
     * TranslatonSettingsController.swift builds one source list: popular languages first,
     * then every remaining supported language. The interface language is moved to the
     * first position within that source list. This order is independent of later toggles.
     */
    private func sourceLanguages(): ArrayList<TranslateLanguage> {
        let result = ArrayList<TranslateLanguage>()
        let interfaceCode = getTranslateService().normalizeLanguageCode(this.presentationStrings.langCode)
        let popular = getPopularLanguages()
        let supported = getSupportedLanguages()

        for (language in popular) {
            if (getTranslateService().normalizeLanguageCode(language.code) == interfaceCode && !this.languageContains(result, language.code)) {
                result.add(language)
            }
        }
        for (language in popular) {
            if (getTranslateService().normalizeLanguageCode(language.code) != interfaceCode && !this.languageContains(result, language.code)) {
                result.add(language)
            }
        }
        for (language in supported) {
            if (getTranslateService().normalizeLanguageCode(language.code) == interfaceCode && !this.languageContains(result, language.code)) {
                result.add(language)
            }
        }
        for (language in supported) {
            if (!this.languageContains(result, language.code)) { result.add(language) }
        }
        return result
    }

    private func languageContains(values: ArrayList<TranslateLanguage>, code: String): Bool {
        for (item in values) { if (item.code == code) { return true } }
        return false
    }

    private func toggle(code: String): Unit {
        let next = ArrayList<String>()
        let wasSelected = this.contains(code)
        for (item in this.selected) { if (item != code) { next.add(item) } }
        if (!wasSelected) { next.add(code) }
        let array = Array<String>(next.size, repeat: "")
        var i: Int64 = 0
        while (i < next.size) { array[i] = next[i]; i = i + 1 }
        this.selected = array
        getTranslateService().saveIgnoredLanguages(array)
    }

    private func nativeName(code: String, fallback: String): String {
        match (code) {
            case "en" => "English"
            case "ar" => "العربية"
            case "zh" => "简体中文"
            case "fr" => "Français"
            case "de" => "Deutsch"
            case "it" => "Italiano"
            case "ja" => "日本語"
            case "ko" => "한국어"
            case "pt-BR" => "Português (Brasil)"
            case "ru" => "Русский"
            case "es" => "Español"
            case "tr" => "Türkçe"
            case "uk" => "Українська"
            case "vi" => "Tiếng Việt"
            case _ => fallback
        }
    }

    public func build() {
        Column {
            Row {
                Button { Text("‹").fontSize(38).fontWeight(FontWeight.Regular).fontColor(0xFF000000) }
                    .width(44).height(44).borderRadius(22).backgroundColor(0xFFFFFFFF)
                    .onClick({ _ => routerPop() })
                Blank()
                Text(this.text("DoNotTranslate_Title", "Do Not Translate"))
                    .fontSize(20).fontWeight(FontWeight.Bold).fontColor(0xFF000000)
                Blank()
                Row {}.width(44)
            }
            .width(100.percent).height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .alignItems(VerticalAlign.Center).backgroundColor(0xFFF7F7F9)

            List {
                ForEach(this.rows, itemGenerator: { row: TranslationLanguageRow, idx: Int64 =>
                    ListItem {
                        Row {
                            Column {
                                Text(row.language.name).fontSize(17).fontColor(0xFF111111)
                                Text(if (row.nativeName.size > 0) { row.nativeName } else { this.nativeName(row.language.code, row.language.name) })
                                    .fontSize(15).fontColor(0xFF111111).margin(top: 2)
                            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                            if (this.contains(row.language.code)) {
                                Text("✓").fontSize(24).fontWeight(FontWeight.Bold).fontColor(0xFF0A84FF)
                            }
                        }
                        .width(100.percent).height(63).padding(left: 16, right: 17)
                        .backgroundColor(0xFFFFFFFF).alignItems(VerticalAlign.Center)
                        .onClick({ _ => this.toggle(row.language.code) })
                    }
                })
            }
            .layoutWeight(1).margin(left: 16, right: 16, top: 16, bottom: 16)
            .borderRadius(12).clip(true).backgroundColor(0xFFFFFFFF)
            .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xFFD7D7DA, startMargin: 16, endMargin: 0))
        }
        .width(100.percent).height(100.percent).backgroundColor(0xFFF2F2F7)
        .padding(bottom: getSafeAreaBottom()).onAppear({ => this.ensureLoaded() })
    }
}
