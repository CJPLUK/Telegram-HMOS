package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings, PresentationSnapshot, currentPresentation}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.getFileDownloadService
import ohos_app_cangjie_entry.services.AutoDownloadNetworkSettings
import ohos_app_cangjie_entry.services.AutoDownloadConnectionKind
import ohos_app_cangjie_entry.services.AutoDownloadPresetKind
import ohos_app_cangjie_entry.services.MediaAutoDownloadCategory
import ohos_app_cangjie_entry.services.MediaAutoDownloadConnection
import ohos_app_cangjie_entry.services.effectiveCategories
import ohos_app_cangjie_entry.services.autodownloadDataSizeString
import ohos_app_cangjie_entry.components.{ItemListSectionHeader, ItemListSeparator}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.subscribe
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * TC-0427 FIX-2 step 2 — the source's `Using Cellular` / `Using Wi-Fi` connection-type
 * screen, absent in the target before this round (F1). Source:
 * AutodownloadConnectionTypeController.swift — `autodownloadMediaConnectionTypeControllerEntries`
 * (:286-318): master switch -> `DATA USAGE` header -> preset control (3 named presets,
 * +1 `Custom` slot only when the connection currently carries a `.custom` override) ->
 * `TYPES OF MEDIA` header -> Photos/Stories/Videos/Files jump rows -> voice-messages
 * footnote.
 *
 * Rows here are hand-rolled (not `ItemListDisclosureRow`/`ItemListToggleRow`) because
 * the master switch must reactively greyscale/disable the preset control and the four
 * jump rows — `ItemListComponents.cj` is out of this round's allowlist (routed-not-owned
 * files list explicitly names only the six FIX-2 files; that component file isn't one
 * of them), and its `enabled`-style props are plain `var` (only captured once at
 * construction, dev_pattern.md D-125), so a shared-component call site could not have
 * made this reactive anyway. Native ArkUI primitives re-evaluate on every parent
 * `build()`, so binding them straight to this page's own `@State` fields is correctly
 * reactive without touching that file.
 */
@HybridComponentEntry
@Component
public class AutodownloadConnectionTypePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var connectionKind: String = "cellular"   // "cellular" | "wifi" — route param
    @State var master: Bool = true
    @State var presetIndex: Int64 = 1                // 0=Low 1=Medium 2=High 3=Custom
    @State var hasCustom: Bool = false
    @State var photosDetail: String = ""
    @State var storiesDetail: String = ""
    @State var videosDetail: String = ""
    @State var filesDetail: String = ""
    @State var paramParsed: Bool = false
    @State var loaded: Bool = false

    // NavDestination stays mounted while a media-category child is pushed. The ArkTS
    // shell forwards every return visibility event so these summaries are re-derived
    // from FileDownloadService instead of retaining the values captured before push.
    private let shownEvent: String = "settings.autodownloadConnectionType.shown"

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        subscribe(this.shownEvent, { _payload: String => this.refresh() })
    }

    private func connKind(): AutoDownloadConnectionKind {
        if (this.connectionKind == "wifi") { return AutoDownloadConnectionKind.ConnWifi }
        return AutoDownloadConnectionKind.ConnCellular
    }

    private func currentConnection(): MediaAutoDownloadConnection {
        let s = getFileDownloadService().getAutoDownloadNetworkSettings()
        if (this.connectionKind == "wifi") { return s.wifi }
        return s.cellular
    }

    // Route param is only ever parsed once; `refresh()` below is re-run on every
    // `.onAppear` (including the return-visit after the category subscreen changes
    // something), so live data is never gated behind the one-time parse.
    private func parseRouteParamOnce(): Unit {
        if (this.paramParsed) { return }
        this.paramParsed = true
        let raw = takePending("AutodownloadConnectionTypePage")
        if (raw.size > 0 && raw != "{}") {
            let trimmed = raw.trimAscii()
            if (trimmed == "wifi") { this.connectionKind = "wifi" } else { this.connectionKind = "cellular" }
        }
    }

    private func presetIndexFor(p: AutoDownloadPresetKind): Int64 {
        match (p) {
            case AutoDownloadPresetKind.PresetLow => return 0
            case AutoDownloadPresetKind.PresetMedium => return 1
            case AutoDownloadPresetKind.PresetHigh => return 2
            case AutoDownloadPresetKind.PresetCustom => return 3
        }
    }

    private func indexToPreset(n: Int64): AutoDownloadPresetKind {
        match (n) {
            case 0 => return AutoDownloadPresetKind.PresetLow
            case 1 => return AutoDownloadPresetKind.PresetMedium
            case 2 => return AutoDownloadPresetKind.PresetHigh
            case _ => return AutoDownloadPresetKind.PresetCustom
        }
    }

    private func presetLabel(n: Int64): String {
        match (n) {
            case 0 => return "Low"
            case 1 => return "Medium"
            case 2 => return "High"
            case _ => return "Custom"
        }
    }

    private func joinTypeList(types: ArrayList<String>): String {
        var out = ""
        var idx: Int64 = 0
        let n = types.size
        for (t in types) {
            if (idx > 0) {
                if (idx == n - 1) { out = out + " and " } else { out = out + ", " }
            }
            out = out + t
            idx += 1
        }
        return out
    }

    // Source: stringForAutomaticDownloadPeers (AutodownloadConnectionTypeController.swift
    // :222-284). Story branch never carries a size; photo never carries a size either
    // (source only computes `size` `if category == .video || category == .file`).
    private func detailForStory(cat: MediaAutoDownloadCategory): String {
        if (cat.contacts && cat.otherPrivate) { return "On for all chats" }
        if (cat.contacts) { return "On for contacts" }
        return "Off for all chats"
    }

    private func detailForPeers(cat: MediaAutoDownloadCategory, hasSize!: Bool): String {
        var sizeText: Option<String> = None
        if (hasSize) { sizeText = Some(autodownloadDataSizeString(cat.sizeLimit)) }
        if (cat.contacts && cat.otherPrivate && cat.groups && cat.channels) {
            match (sizeText) {
                case Some(s) => return "Up to ${s} for all chats"
                case None => return "On for all chats"
            }
        }
        let types = ArrayList<String>()
        if (cat.contacts) { types.add("Contacts") }
        if (cat.otherPrivate) { types.add("PM") }
        if (cat.groups) { types.add("Groups") }
        if (cat.channels) { types.add("Channels") }
        if (types.size == 0) { return "Off for all chats" }
        let joined = this.joinTypeList(types)
        match (sizeText) {
            case Some(s) => return "Up to ${s} for ${joined}"
            case None => return "On for ${joined}"
        }
    }

    private func refresh(): Unit {
        let conn = this.currentConnection()
        this.master = conn.enabled
        this.hasCustom = conn.custom.isSome()
        this.presetIndex = this.presetIndexFor(conn.preset)
        let cats = effectiveCategories(conn)
        this.photosDetail = this.detailForPeers(cats.photo, hasSize: false)
        this.storiesDetail = this.detailForStory(cats.stories)
        this.videosDetail = this.detailForPeers(cats.video, hasSize: true)
        this.filesDetail = this.detailForPeers(cats.file, hasSize: true)
    }

    private func setMaster(v: Bool): Unit {
        this.master = v
        getFileDownloadService().setConnectionEnabled(this.connKind(), v)
        Hilog.info(0, "CjTelegram", "[AutodownloadConnectionType] ${this.connectionKind}.master=${v}")
    }

    private func setPreset(idx: Int64): Unit {
        getFileDownloadService().setConnectionPreset(this.connKind(), this.indexToPreset(idx))
        this.refresh()
    }

    private func openCategory(cat: String): Unit {
        if (!this.master) { return }
        routerPush("AutodownloadMediaCategoryPage", "${this.connectionKind}|${cat}")
    }

    private func titleText(): String {
        if (this.connectionKind == "wifi") { return "Using Wi-Fi" } else { return "Using Cellular" }
    }

    private func rowTitleColor(): UInt32 {
        if (this.master) { return this.presentation.textColor } else { return this.presentation.secondaryTextColor }
    }

    private func sliderMax(): Float64 {
        if (this.hasCustom) { return 3.0 } else { return 2.0 }
    }

    public func build() {
        Column {
            Row {
                Row {
                    Image(@r(app.media.callui_v2_back)).width(10).height(18).fillColor(this.presentation.accentColor)
                }
                .width(44).height(44).borderRadius(22)
                .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
                .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
                .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(this.titleText())
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Row { }.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.navBarColor)
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    // ── master switch (source stableId 0, no header) ──
                    Column {
                        Row {
                            Text(trSource("Auto-Download Media"))
                                .fontSize(17)
                                .fontColor(this.presentation.textColor)
                                .layoutWeight(1)
                            Toggle(ToggleType.Switch, isOn: this.master)
                                .selectedColor(0x34C759)
                                .onChange({ on: Bool => this.setMaster(on) })
                        }
                        .width(100.percent)
                        .constraintSize(minHeight: 56)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .margin(left: 16, right: 16, top: 16)

                    // ── DATA USAGE preset control ──
                    ItemListSectionHeader(title: "DATA USAGE", topPad: 24)

                    Column {
                        Row {
                            Text(trSource("Low")).fontSize(13).fontColor(this.presentation.secondaryTextColor).layoutWeight(1)
                            Text(trSource("Medium")).fontSize(13).fontColor(this.presentation.secondaryTextColor).layoutWeight(1).textAlign(TextAlign.Center)
                            if (this.hasCustom) {
                                Text(trSource("High")).fontSize(13).fontColor(this.presentation.secondaryTextColor).layoutWeight(1).textAlign(TextAlign.Center)
                                Text(trSource("Custom")).fontSize(13).fontColor(this.presentation.secondaryTextColor).layoutWeight(1).textAlign(TextAlign.End)
                            } else {
                                Text(trSource("High")).fontSize(13).fontColor(this.presentation.secondaryTextColor).layoutWeight(1).textAlign(TextAlign.End)
                            }
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 12)

                        Slider(value: Float64(this.presetIndex), min: 0.0, max: this.sliderMax(), step: 1.0)
                            .width(100.percent)
                            .showSteps(true)
                            .padding(left: 16, right: 16, top: 4)
                            .enabled(this.master)
                            .opacity(if (this.master) { 1.0 } else { 0.4 })
                            .onChange({ value: Float64, mode: SliderChangeMode =>
                                if (mode == SliderChangeMode.End) {
                                    this.setPreset(Int64(value))
                                }
                            })

                        Row {}.height(12)
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .margin(left: 16, right: 16)

                    // ── TYPES OF MEDIA jump rows (source stableId 4-7) ──
                    ItemListSectionHeader(title: "TYPES OF MEDIA", topPad: 24)

                    Column {
                        // Diag-suite_settings_data_storage-TC-0425.md RC-A M1: title +
                        // detail used to sit in the same row racing for width (title
                        // `layoutWeight(1)` vs an unconstrained detail `Text`), so a long
                        // detail string could squeeze the title node to zero width and
                        // overflow the chevron. Source (`ItemListDisclosureItem.swift`
                        // `.detailText` style) measures title and detail as two
                        // independently-clamped single lines, title above detail, each
                        // its own tail-truncated line — reproduced below via a `Column`
                        // that alone carries the flex weight, height derived from content
                        // (`constraintSize(minHeight: 44)` + 13pt vertical padding instead
                        // of a fixed 44 row height).
                        Row {
                            Image(@r(app.media.autodl_ic_photo)).width(29).height(29).margin(right: 16)
                            Column {
                                Text(trSource("Photos"))
                                    .fontSize(17)
                                    .fontColor(this.rowTitleColor())
                                    .width(100.percent)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                Text(this.photosDetail)
                                    .fontSize(15)
                                    .fontColor(this.presentation.secondaryTextColor)
                                    .width(100.percent)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .margin(top: 1)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                            Image(@r(app.media.item_list_disclosure_arrow)).width(8).height(14)
                                .fillColor(this.presentation.disclosureArrowColor).margin(left: 6)
                        }
                        .width(100.percent)
                        .constraintSize(minHeight: 44)
                        .padding(left: 16, right: 16, top: 13, bottom: 13)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _evt => this.openCategory("photo") })
                        ItemListSeparator(leftInset: 61)

                        Row {
                            Image(@r(app.media.autodl_ic_stories)).width(29).height(29).margin(right: 16)
                            Column {
                                Text(trSource("Stories"))
                                    .fontSize(17)
                                    .fontColor(this.rowTitleColor())
                                    .width(100.percent)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                Text(this.storiesDetail)
                                    .fontSize(15)
                                    .fontColor(this.presentation.secondaryTextColor)
                                    .width(100.percent)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .margin(top: 1)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                            Image(@r(app.media.item_list_disclosure_arrow)).width(8).height(14)
                                .fillColor(this.presentation.disclosureArrowColor).margin(left: 6)
                        }
                        .width(100.percent)
                        .constraintSize(minHeight: 44)
                        .padding(left: 16, right: 16, top: 13, bottom: 13)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _evt => this.openCategory("story") })
                        ItemListSeparator(leftInset: 61)

                        Row {
                            Image(@r(app.media.autodl_ic_video)).width(29).height(29).margin(right: 16)
                            Column {
                                Text(trSource("Videos"))
                                    .fontSize(17)
                                    .fontColor(this.rowTitleColor())
                                    .width(100.percent)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                Text(this.videosDetail)
                                    .fontSize(15)
                                    .fontColor(this.presentation.secondaryTextColor)
                                    .width(100.percent)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .margin(top: 1)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                            Image(@r(app.media.item_list_disclosure_arrow)).width(8).height(14)
                                .fillColor(this.presentation.disclosureArrowColor).margin(left: 6)
                        }
                        .width(100.percent)
                        .constraintSize(minHeight: 44)
                        .padding(left: 16, right: 16, top: 13, bottom: 13)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _evt => this.openCategory("video") })
                        ItemListSeparator(leftInset: 61)

                        Row {
                            Image(@r(app.media.autodl_ic_file)).width(29).height(29).margin(right: 16)
                            Column {
                                Text(trSource("Files"))
                                    .fontSize(17)
                                    .fontColor(this.rowTitleColor())
                                    .width(100.percent)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                Text(this.filesDetail)
                                    .fontSize(15)
                                    .fontColor(this.presentation.secondaryTextColor)
                                    .width(100.percent)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .margin(top: 1)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                            Image(@r(app.media.item_list_disclosure_arrow)).width(8).height(14)
                                .fillColor(this.presentation.disclosureArrowColor).margin(left: 6)
                        }
                        .width(100.percent)
                        .constraintSize(minHeight: 44)
                        .padding(left: 16, right: 16, top: 13, bottom: 13)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _evt => this.openCategory("file") })
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .margin(left: 16, right: 16)

                    Text(trSource("Voice messages are tiny, they are always downloaded automatically."))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .padding(left: 32, right: 32)
                        .margin(top: 8, bottom: 32)
                        .width(100.percent)
                }
            }
            .align(Alignment.Top)
            .layoutWeight(1)
            .backgroundColor(this.presentation.backgroundColor)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ =>
            this.parseRouteParamOnce()
            this.ensureLoaded()
            this.refresh()
        })
    }
}
