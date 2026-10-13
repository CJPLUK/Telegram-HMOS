package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import std.collection.ArrayList
import std.sync.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.components.SearchBar
import ohos_app_cangjie_entry.core.storage.{getAuthStorage, PresentationStringsSnapshot, currentPresentationStrings}
import ohos_app_cangjie_entry.models.LocalizationInfo
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.{getLocalizationService, getTranslateService, TranslationSettingsSnapshot, currentTranslationSettings}
import ohos_app_cangjie_entry.interop.{callArkAsync, SHARE_LINK}

private func languagePageJsonEscape(value: String): String {
    return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r")
}

public class LocalizationRowEntry <: ToString {
    public let info: LocalizationInfo
    public init(info: LocalizationInfo) { this.info = info }
    public func toString(): String { return this.info.languageCode }
}

/** Source parity: SettingsUI/Language Selection/LocalizationListControllerNode.swift. */
@HybridComponentEntry
@Component
public class LanguageSettingsPage {
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["translationSettings"] var translationSettings: TranslationSettingsSnapshot = currentTranslationSettings()
    @State var selectedLanguage: String = "en"
    @State var official: ArrayList<LocalizationInfo> = ArrayList<LocalizationInfo>()
    @State var saved: ArrayList<LocalizationInfo> = ArrayList<LocalizationInfo>()
    @State var isLoading: Bool = true
    @State var searchKeyword: String = ""
    @State var applyingCode: String = ""
    @State var isPremium: Bool = false
    @State var loaded: Bool = false
    @State var contentGeneration: Int64 = 0
    @State var showTranslationPremiumSheet: Bool = false
    @State var translationPremiumStage: Int32 = 0
    // S7-123: Edit mode for saved non-official packs (iOS LocalizationListController
    // editPressed / LocalizationListItemEditing; Edit is offered only while such packs exist,
    // LocalizationListControllerNode.swift:569-573).
    @State var isEditing: Bool = false
    @State var revealedCode: String = ""

    private func text(key: String, fallback: String): String {
        return this.presentationStrings.getOr(key, fallback)
    }

    private func ensureLoaded(): Unit {
        this.selectedLanguage = getAuthStorage().getLangCode()
        match (getAuthStorage().getUserData()) {
            case Some(user) => this.isPremium = user.isPremium
            case None => this.isPremium = false
        }
        // LocalizationListControllerNode.swift deliberately presents this as
        // disabled/off for non-Premium accounts, regardless of the persisted
        // default (TranslationSettings.defaultSettings.translateChats == true).
        if (this.loaded) { return }
        this.loaded = true
        this.loadLanguages()
    }

    private func loadLanguages(): Unit {
        let _ = spawn {
            let service = getLocalizationService()
            let _ = service.synchronizedLocalizationListState()
            let state = service.getLocalizationListState()
            let officialCopy = ArrayList<LocalizationInfo>()
            let savedCopy = ArrayList<LocalizationInfo>()
            // iOS updates MTApiEnvironment.langPackCode with the active language;
            // Telegram's response consequently presents that language first.
            // Preserve the server order for every other entry while reproducing
            // that active-first contract even if this process reused an older DC
            // connection initialized before preferences were restored.
            for (info in state.availableOfficialLocalizations) {
                if (info.languageCode == this.selectedLanguage) { officialCopy.add(info) }
            }
            for (info in state.availableOfficialLocalizations) {
                if (info.languageCode != this.selectedLanguage) { officialCopy.add(info) }
            }
            for (info in state.availableSavedLocalizations) {
                var duplicate = false
                for (officialInfo in officialCopy) {
                    if (officialInfo.languageCode == info.languageCode) { duplicate = true; break }
                }
                if (!duplicate) { savedCopy.add(info) }
            }
            launch {
                this.official = officialCopy
                this.saved = savedCopy
                this.isLoading = false
            }
        }
    }

    private func effectiveIgnoredLanguages(): Array<String> {
        let _ = this.translationSettings.ignoredLanguagesCsv
        return getTranslateService().effectiveIgnoredLanguages()
    }

    private func ignoredSummary(): String {
        let values = this.effectiveIgnoredLanguages()
        if (values.size == 1) {
            for (info in this.official) {
                if (info.languageCode == values[0] || info.languageCode.startsWith(values[0])) { return info.title }
            }
            if (values[0] == "en") { return "English" }
        }
        var result = ""
        var i: Int64 = 0
        while (i < values.size) {
            if (i > 0) { result = result + ", " }
            result = result + values[i]
            i = i + 1
        }
        return result
    }

    private func toggleShowTranslate(value: Bool): Unit {
        let service = getTranslateService()
        service.saveShowTranslateButton(value)
        if (!value && !service.getTranslateChatsEnabled()) {
            service.clearIgnoredLanguages()
        }
    }

    private func toggleTranslateChats(value: Bool): Unit {
        if (!this.isPremium) {
            // iOS PremiumDemoScreen(subject: .translation).
            this.translationPremiumStage = 0
            this.showTranslationPremiumSheet = true
            return
        }
        let service = getTranslateService()
        service.saveTranslateChatsEnabled(value)
        if (!value && !service.getShowTranslateButton()) {
            service.clearIgnoredLanguages()
        }
    }

    private func closeTranslationPremiumSheet(): Unit {
        this.showTranslationPremiumSheet = false
        this.translationPremiumStage = 0
    }

    @Builder
    private func translationPremiumSheet() {
        if (this.translationPremiumStage == 0) {
            TranslationPremiumDemoSheet(
                onClose: { => this.closeTranslationPremiumSheet() },
                onProceed: { => this.translationPremiumStage = 1 }
            )
        } else {
            PremiumPage(
                embedded: true,
                onClose: { => this.closeTranslationPremiumSheet() }
            )
        }
    }

    private func selectLanguage(code: String): Unit {
        if (code == this.selectedLanguage || this.applyingCode.size > 0) { return }
        this.applyingCode = code
        let _ = spawn {
            let success = getLocalizationService().downloadAndApplyLocalization(code)
            launch {
                if (success) {
                    this.selectedLanguage = code
                    let reordered = ArrayList<LocalizationInfo>()
                    for (info in this.official) { if (info.languageCode == code) { reordered.add(info) } }
                    for (info in this.official) { if (info.languageCode != code) { reordered.add(info) } }
                    this.official = reordered
                    this.contentGeneration = this.contentGeneration + 1
                }
                this.applyingCode = ""
            }
        }
    }

    private func openUnofficial(info: LocalizationInfo): Unit {
        let share = SheetInfo(title: this.text("Common_Share", "Share"), action: { =>
            if (info.platformUrl.size > 0) {
                let payload = "{\"url\":\"${languagePageJsonEscape(info.platformUrl)}\",\"title\":\"${languagePageJsonEscape(info.localizedTitle)}\"}"
                callArkAsync(SHARE_LINK, payload, { _ => () })
            }
        })
        let cancel = ActionSheetButtonOptions(value: this.text("Common_Cancel", "Cancel"), action: { => () })
        if (info.languageCode != this.selectedLanguage) {
            let change = SheetInfo(title: this.text("Localization_ApplyLanguage", "Change Language"), action: { => this.selectLanguage(info.languageCode) })
            getUIContext().showActionSheet(ActionSheetOptions(title: Some(info.localizedTitle), message: None,
                confirm: cancel, sheets: [change, share], autoCancel: true))
        } else {
            getUIContext().showActionSheet(ActionSheetOptions(title: Some(info.localizedTitle), message: None,
                confirm: cancel, sheets: [share], autoCancel: true))
        }
    }

    /** iOS removeItem → engine.localization.removeSavedLocalization (LocalizationListControllerNode.swift:409-411). */
    private func removeSaved(code: String): Unit {
        getLocalizationService().removeSavedLocalization(code)
        let remaining = ArrayList<LocalizationInfo>()
        for (info in this.saved) { if (info.languageCode != code) { remaining.add(info) } }
        this.saved = remaining
        this.revealedCode = ""
        if (remaining.isEmpty()) { this.isEditing = false }
    }

    /** iOS `editable: !selected && !searchMode && !info.isOfficial` (LocalizationListControllerNode.swift:115). */
    private func isRowEditable(info: LocalizationInfo, unofficial: Bool): Bool {
        return unofficial && this.searchKeyword.size == 0 && info.languageCode != this.selectedLanguage
    }

    private func matches(info: LocalizationInfo): Bool {
        if (this.searchKeyword.size == 0) { return true }
        let needle = this.searchKeyword.trimAscii().toAsciiLower()
        return info.title.toAsciiLower().startsWith(needle) || info.localizedTitle.toAsciiLower().startsWith(needle)
    }

    private func filteredRows(): ArrayList<LocalizationRowEntry> {
        let rows = ArrayList<LocalizationRowEntry>()
        for (info in this.saved) { if (this.matches(info)) { rows.add(LocalizationRowEntry(info)) } }
        for (info in this.official) { if (this.matches(info)) { rows.add(LocalizationRowEntry(info)) } }
        return rows
    }

    private func isSaved(code: String): Bool {
        for (info in this.saved) { if (info.languageCode == code) { return true } }
        return false
    }

    @Builder
    private func navBar() {
        Row {
            Button {
                Text("‹").fontSize(38).fontWeight(FontWeight.Regular).fontColor(0xFF000000)
            }
            .width(44).height(44).borderRadius(22).backgroundColor(0xFFFFFFFF)
            .onClick({ _ => routerPop() })
            Blank()
            Text(this.text("Settings_AppLanguage", "Language"))
                .fontSize(20).fontWeight(FontWeight.Bold).fontColor(0xFF000000)
            Blank()
            if (this.saved.size > 0) {
                Text(if (this.isEditing) { this.text("Common_Done", "Done") } else { this.text("Common_Edit", "Edit") })
                    .fontSize(17)
                    .fontWeight(if (this.isEditing) { FontWeight.Medium } else { FontWeight.Regular })
                    .fontColor(0xFF0A84FF)
                    .constraintSize(minWidth: 44).height(44).textAlign(TextAlign.End)
                    .onClick({ _ =>
                        this.isEditing = !this.isEditing
                        this.revealedCode = ""
                    })
            } else {
                Row {}.width(44)
            }
        }
        .width(100.percent).height(56.0 + getSafeAreaTop())
        .padding(left: 16, right: 16, top: getSafeAreaTop())
        .alignItems(VerticalAlign.Center).backgroundColor(0xFFF7F7F9)
    }

    @Builder
    private func sectionTitle(title: String) {
        Text(title.toAsciiUpper())
            .fontSize(13).fontColor(0xFF7A7A80)
            .width(100.percent).margin(left: 32, top: 22, bottom: 7)
    }

    @Builder
    private func translateRow(title: String, isOn: Bool, locked: Bool, action: (Bool) -> Unit) {
        Row {
            Text(title).fontSize(17).fontColor(0xFF111111).layoutWeight(1)
            if (locked) {
                Stack(alignContent: Alignment.Center) {
                    Toggle(ToggleType.Switch, isOn: false).enabled(false).opacity(0.75)
                    Image(@r(app.media.media_ic_lock))
                        .width(12).height(12).fillColor(0xFF85858A)
                }.width(52).height(34)
            } else {
                Toggle(ToggleType.Switch, isOn: isOn)
                    .selectedColor(0xFF34C759)
                    .onChange({ value: Bool => action(value) })
            }
        }
        .width(100.percent).height(52).padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center).backgroundColor(0xFFFFFFFF)
        .onClick({ _ => if (locked) { this.toggleTranslateChats(!isOn) } })
    }

    @Builder
    private func doNotTranslateRow() {
        Row {
            Text(this.text("Localization_DoNotTranslate", "Do Not Translate"))
                .fontSize(17).fontColor(0xFF111111).layoutWeight(1)
            Text(this.ignoredSummary())
                .fontSize(17).fontColor(0xFF8E8E93)
                .maxLines(1).textOverflow(TextOverflow.Ellipsis)
                .constraintSize(maxWidth: 170)
            Text("›").fontSize(26).fontColor(0xFFC7C7CC).margin(left: 7)
        }
        .width(100.percent).height(52).padding(left: 16, right: 13)
        .backgroundColor(0xFFFFFFFF).alignItems(VerticalAlign.Center)
        .onClick({ _ => routerPush("DoNotTranslateLanguagesPage", "") })
    }

    @Builder
    private func languageRow(info: LocalizationInfo, unofficial: Bool) {
        Row {
            if (this.isEditing && this.isRowEditable(info, unofficial)) {
                // iOS ItemListEditableItem: red minus control reveals the Delete action.
                Stack(alignContent: Alignment.Center) {
                    Circle().width(22).height(22).fill(0xFFFF3B30)
                    Row {}.width(11).height(2).backgroundColor(0xFFFFFFFF).borderRadius(1)
                }
                .width(38).height(44)
                .onClick({ _ =>
                    this.revealedCode = if (this.revealedCode == info.languageCode) { "" } else { info.languageCode }
                })
            }
            Column {
                Text(info.title).fontSize(17).fontColor(0xFF111111).maxLines(1)
                Text(info.localizedTitle).fontSize(15).fontColor(0xFF111111).maxLines(1).margin(top: 2)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.applyingCode == info.languageCode) {
                LoadingProgress().width(22).height(22).color(0xFF0A84FF)
            } else if (this.selectedLanguage == info.languageCode) {
                Text("✓").fontSize(24).fontWeight(FontWeight.Bold).fontColor(0xFF0A84FF)
            }
            if (this.isEditing && this.revealedCode == info.languageCode && this.isRowEditable(info, unofficial)) {
                Text(this.text("Common_Delete", "Delete"))
                    .fontSize(17).fontColor(0xFFFFFFFF)
                    .height(100.percent).padding(left: 16, right: 16)
                    .backgroundColor(0xFFFF3B30)
                    .onClick({ _ => this.removeSaved(info.languageCode) })
            }
        }
        .width(100.percent).height(63).padding(left: if (this.isEditing && this.isRowEditable(info, unofficial)) { 4 } else { 16 }, right: if (this.isEditing && this.revealedCode == info.languageCode) { 0 } else { 17 })
        .alignItems(VerticalAlign.Center).backgroundColor(0xFFFFFFFF)
        .onClick({ _ =>
            if (this.isEditing) {
                this.revealedCode = ""
            } else if (unofficial) {
                this.openUnofficial(info)
            } else {
                this.selectLanguage(info.languageCode)
            }
        })
    }

    @Builder
    private func pageBody(generation: Int64) {
        Column {
            this.navBar()
            Column {
                SearchBar(loading: false, backArrow: false, text: this.searchKeyword,
                    hint: this.text("Common_Search", "Search"),
                    onChange: { value: String => this.searchKeyword = value })
            }.width(100.percent).padding(left: 12, right: 12).backgroundColor(0xFFF7F7F9)

            if (this.isLoading) {
                Column { LoadingProgress().width(30).height(30) }
                    .layoutWeight(1).width(100.percent).justifyContent(FlexAlign.Center)
            } else {
                Scroll {
                    Column {
                        if (this.searchKeyword.size == 0) {
                            this.sectionTitle(this.text("Localization_TranslateMessages", "Translate Messages"))
                            Column {
                                this.translateRow(this.text("Localization_ShowTranslate", "Show Translate Button"), this.translationSettings.showTranslate, false, { v: Bool => this.toggleShowTranslate(v) })
                                Divider().strokeWidth(0.5).color(0xFFD7D7DA).margin(left: 16)
                                this.translateRow(this.text("Localization_TranslateEntireChat", "Translate Entire Chats"), if (this.isPremium) { this.translationSettings.translateChats } else { false }, !this.isPremium, { v: Bool => this.toggleTranslateChats(v) })
                                if (this.translationSettings.showTranslate || (this.isPremium && this.translationSettings.translateChats)) {
                                    Divider().strokeWidth(0.5).color(0xFFD7D7DA).margin(left: 16)
                                    this.doNotTranslateRow()
                                }
                            }.margin(left: 16, right: 16).borderRadius(12).clip(true)
                            Text(if (this.translationSettings.showTranslate) {
                                this.text("Localization_DoNotTranslateInfo", "Messages in the selected languages won't offer translation.")
                            } else {
                                this.text("Localization_ShowTranslateInfoExtended", "Show a 'Translate' button when holding down on a message.")
                            })
                                .fontSize(13).fontColor(0xFF7A7A80).width(100.percent)
                                .padding(left: 32, right: 32, top: 8)
                            this.sectionTitle(this.text("Localization_InterfaceLanguage", "Interface Language"))
                        }

                        Column {
                            ForEach(this.filteredRows(), itemGenerator: { row: LocalizationRowEntry, idx: Int64 =>
                                if (idx > 0) { Divider().strokeWidth(0.5).color(0xFFD7D7DA).margin(left: 16) }
                                this.languageRow(row.info, this.isSaved(row.info.languageCode))
                            })
                        }
                        .margin(left: 16, right: 16, bottom: 20).borderRadius(12).clip(true)
                    }.width(100.percent).justifyContent(FlexAlign.Start)
                }.layoutWeight(1).scrollBar(BarState.Off)
            }
        }
        .width(100.percent).height(100.percent)
        .backgroundColor(if (generation >= 0) { 0xFFF2F2F7 } else { 0xFFF2F2F7 }).padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }

    public func build() {
        // ArkUI keeps @Builder child identities stable even when their string
        // arguments change. Alternating structural branches recreates the
        // language surface in place, matching iOS PresentationData replacement
        // without introducing a navigation transition.
        Stack(alignContent: Alignment.Bottom) {
            if ((this.contentGeneration % 2) == 0) {
                this.pageBody(this.contentGeneration)
            } else {
                this.pageBody(this.contentGeneration)
            }
            if (this.showTranslationPremiumSheet) {
                Column { }
                    .width(100.percent).height(100.percent)
                    .backgroundColor(0x66000000)
                    .transition(TransitionEffect.OPACITY.animation(
                        AnimateParam(duration: 220, curve: Curve.EaseOut)))
                if (this.translationPremiumStage == 0) {
                    Column {
                        this.translationPremiumSheet()
                    }
                    .width(100.percent)
                    .borderRadius(topLeft: 28, topRight: 28)
                    .clip(true)
                    .transition(TransitionEffect.move(TransitionEdge.Bottom)
                        .animation(AnimateParam(duration: 320, curve: Curve.EaseOut)))
                } else {
                    Column {
                        this.translationPremiumSheet()
                    }
                    .width(100.percent).height(96.percent)
                    .borderRadius(topLeft: 28, topRight: 28)
                    .clip(true)
                    .transition(TransitionEffect.OPACITY.animation(
                        AnimateParam(duration: 220, curve: Curve.EaseInOut)))
                }
            }
        }
        .width(100.percent).height(100.percent)
    }
}
