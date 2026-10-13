package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings, PresentationSnapshot, currentPresentation}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getFileDownloadService
import ohos_app_cangjie_entry.services.AutoDownloadNetworkSettings
import ohos_app_cangjie_entry.services.AutoDownloadConnectionKind
import ohos_app_cangjie_entry.services.AutoDownloadCategoryKind
import ohos_app_cangjie_entry.services.AutoDownloadPeerKind
import ohos_app_cangjie_entry.services.MediaAutoDownloadCategory
import ohos_app_cangjie_entry.services.effectiveCategories
import ohos_app_cangjie_entry.services.autodownloadDataSizeString
import ohos_app_cangjie_entry.components.{ItemListSectionHeader, ItemListSeparator, ItemListToggleRow}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * TC-0427 F1/F2 — the source's per-category screen (Photos / Stories / Videos / Files,
 * reached from AutodownloadConnectionTypePage), absent in the target before this round.
 * Source: AutodownloadMediaCategoryController.swift.
 *
 * This is the screen TC-0427 actually exercises (`Using Wi-Fi` -> `Videos` / `Files` ->
 * `Documents`): the continuous 512 KB..1.5 GB size slider (A group) and the
 * `Preload Larger Videos` >2 MB enable/disable + non-destructive-when-disabled gate
 * (B group). Anchors ported verbatim from AutodownloadSizeLimitItem.swift:12-49
 * (segment-linear interpolation, not a uniform scale).
 *
 * D-125/D-156: the slider label, min/max endpoint labels and the preload info text are
 * all bare `@State` fields recomputed synchronously by `refresh()`/`onSlide()` — never
 * a function-call return passed straight into a child. Peer toggles use
 * `ItemListToggleRow` (its `isOn` is `@Prop`, called here with this component's own
 * bare `@State` fields, per that component's documented contract). The size row,
 * min/max labels and the preload switch are hand-rolled native controls (not
 * `ItemListDisclosureRow`/`ItemListToggleRow`) because both need a continuously
 * reactive display (`Slider` drag / a size-crossing-2MB enabled flip) that a
 * plain-`var`-typed shared-component field cannot deliver without editing
 * `ItemListComponents.cj`, which is out of this round's six-file allowlist.
 */
private class SizeAnchor {
    public var pos: Float64
    public var bytes: Int64
    public init(pos!: Float64, bytes!: Int64) {
        this.pos = pos
        this.bytes = bytes
    }
}

// TC-0427 round4 (C1-b): ArkUI `Slider`'s `step` defaults to `1.0` (SDK decl
// `ohos.arkui.component.slider.cj.d` `step!: ?Float64 = None` resolved by the wrapper
// as `step ?? 1.0`, matching the official `slider.d.ts:571 step?: number` doc's
// `@default 1`; see `dev_pattern.md` D-199). On the `[0,1]` unit domain this collapses
// the reachable set to `{0.0, 1.0}` — the slider degenerates into a two-value switch and
// the `1 MB` / `10 MB` / `100 MB` anchors (the last is the source's default) become
// unreachable. `step` is therefore not an omittable parameter here: omitting it is not
// "the SDK's continuous resolution", it is choosing `step = 1.0`.
//
// Fix (same shape as this repo's precedent for the same source item, `SaveIncomingMediaPage.cj`):
// widen `[0,1]` to the integer domain `[0, SLIDER_POS_SCALE]` before handing it to the
// control, undo the scale in the `onChange` callback. `1/1000` is the coarsest uniform
// grid on which all 5 anchors (`0.000 / 0.257 / 0.520 / 0.763 / 1.000`, all three-decimal
// in the source table `AutodownloadSizeLimitItem.swift:12-18`) land exactly — the ratio is
// derived from the source table's decimal precision, not guessed. Under IEEE754,
// `257.0/1000.0`, `520.0/1000.0`, `763.0/1000.0` equal the source literals bit-for-bit, and
// `0/1000 = 0.0`, `1000/1000 = 1.0` exactly, so both endpoints (512 KB / 1.5 GB) are
// unaffected. `sizeAnchors()` / `sliderPosForSize()` / `sizeForSliderPos()` / `onSlide(pos:)`
// stay untouched — `onSlide`'s parameter is still `[0,1]`; the scale/unscale only happens at
// the control boundary. No `.showSteps(true)` (the source has no tick marks; adding one would
// invent a visual element the source doesn't have).
private let SLIDER_POS_SCALE: Float64 = 1000.0

// Source: AutodownloadSizeLimitItem.swift:12-18 `autodownloadSizeValues`.
private func sizeAnchors(): Array<SizeAnchor> {
    return [
        SizeAnchor(pos: 0.000, bytes: 512 * 1024),
        SizeAnchor(pos: 0.257, bytes: 1024 * 1024),
        SizeAnchor(pos: 0.520, bytes: 10 * 1024 * 1024),
        SizeAnchor(pos: 0.763, bytes: 100 * 1024 * 1024),
        SizeAnchor(pos: 1.000, bytes: 1536 * 1024 * 1024)
    ]
}

// Source: AutodownloadSizeLimitItem.swift:20-33 `sliderValue(for:)`.
private func sliderPosForSize(size: Int64): Float64 {
    let anchors = sizeAnchors()
    var i: Int64 = 1
    while (i < anchors.size) {
        let prev = anchors[i - 1]
        let cur = anchors[i]
        if (cur.bytes > size) {
            return prev.pos + Float64(size - prev.bytes) / Float64(cur.bytes - prev.bytes) * (cur.pos - prev.pos)
        } else if (prev.bytes == size) {
            return prev.pos
        } else if (cur.bytes == size || i == anchors.size - 1) {
            return cur.pos
        }
        i += 1
    }
    return 0.0
}

// Source: AutodownloadSizeLimitItem.swift:35-49 `sizeValue(for:)`.
private func sizeForSliderPos(pos: Float64): Int64 {
    let anchors = sizeAnchors()
    var i: Int64 = 1
    while (i < anchors.size) {
        let prev = anchors[i - 1]
        let cur = anchors[i]
        if (cur.pos > pos) {
            let delta = (pos - prev.pos) / (cur.pos - prev.pos) * Float64(cur.bytes - prev.bytes)
            return prev.bytes + Int64(delta)
        } else if (prev.pos == pos) {
            return prev.bytes
        } else if (cur.pos == pos || i == anchors.size - 1) {
            return cur.bytes
        }
        i += 1
    }
    return 0
}

private let PRELOAD_ENABLE_THRESHOLD: Int64 = 2 * 1024 * 1024

@HybridComponentEntry
@Component
public class AutodownloadMediaCategoryPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var connectionKind: String = "cellular"   // "cellular" | "wifi" — route param
    @State var category: String = "video"            // "photo" | "video" | "file" | "story" — route param
    @State var paramParsed: Bool = false

    // ── peer toggles (photo/video/file: all four; story: contacts + conditional otherPrivate) ──
    @State var contacts: Bool = true
    @State var otherPrivate: Bool = true
    @State var groups: Bool = true
    @State var channels: Bool = true

    // ── size (video/file only) ──
    @State var sizeLimit: Int64 = 0
    @State var sliderPos: Float64 = 0.0
    @State var sizeTitleLabel: String = ""     // "up to <size>" — D-125 bare mirror
    @State var minEdgeLabel: String = ""       // "512 KB" — D-125 bare mirror
    @State var maxEdgeLabel: String = ""       // "1.5 GB" — D-125 bare mirror

    // Section header strings — D-125 bare mirrors (diag-suite_settings_data_storage-
    // TC-0426.md RC-C M1-b). `category` is only reassigned from its "video" literal
    // initial value inside `.onAppear` (after the first `build()`), so
    // `ItemListSectionHeader`'s now-`@Prop` `title:` call sites below must be fed from
    // these fields — never straight from `peerHeaderText()`/`sizeHeaderText()` — or the
    // header stays on its first-frame value forever.
    @State var peerHeaderLabel: String = ""    // AUTO-DOWNLOAD <category> — D-125 bare mirror
    @State var sizeHeaderLabel: String = ""    // MAXIMUM <category> SIZE — D-125 bare mirror

    // ── predownload (video only; underlying value survives being disabled — B4) ──
    @State var predownload: Bool = false
    @State var preloadInfoText: String = ""

    private func connKind(): AutoDownloadConnectionKind {
        if (this.connectionKind == "wifi") { return AutoDownloadConnectionKind.ConnWifi }
        return AutoDownloadConnectionKind.ConnCellular
    }

    private func categoryKind(): AutoDownloadCategoryKind {
        match (this.category) {
            case "photo" => return AutoDownloadCategoryKind.CategoryPhoto
            case "video" => return AutoDownloadCategoryKind.CategoryVideo
            case "file" => return AutoDownloadCategoryKind.CategoryFile
            case _ => return AutoDownloadCategoryKind.CategoryStories
        }
    }

    private func isStory(): Bool { return this.category == "story" }
    private func hasSize(): Bool { return this.category == "video" || this.category == "file" }
    private func isVideo(): Bool { return this.category == "video" }

    private func parseRouteParamOnce(): Unit {
        if (this.paramParsed) { return }
        this.paramParsed = true
        let raw = takePending("AutodownloadMediaCategoryPage")
        if (raw.size > 0 && raw != "{}") {
            let parts = raw.split("|")
            if (parts.size >= 1) {
                let c = parts[0].trimAscii()
                if (c == "wifi") { this.connectionKind = "wifi" } else { this.connectionKind = "cellular" }
            }
            if (parts.size >= 2) {
                let cat = parts[1].trimAscii()
                match (cat) {
                    case "photo" | "video" | "file" | "story" => this.category = cat
                    case _ => this.category = "video"
                }
            }
        }
    }

    private func preloadEnabled(): Bool { return this.sizeLimit > PRELOAD_ENABLE_THRESHOLD }

    private func refreshSizeLabels(): Unit {
        let sizeText = autodownloadDataSizeString(this.sizeLimit)
        this.sizeTitleLabel = "up to ${sizeText}"
        this.preloadInfoText = "Preload the first seconds of videos larger than ${sizeText} for instant playback."
    }

    private func refresh(): Unit {
        this.peerHeaderLabel = this.peerHeaderText()
        this.sizeHeaderLabel = this.sizeHeaderText()
        let s = getFileDownloadService().getAutoDownloadNetworkSettings()
        let conn = if (this.connectionKind == "wifi") { s.wifi } else { s.cellular }
        let cats = effectiveCategories(conn)
        let cat: MediaAutoDownloadCategory = match (this.category) {
            case "photo" => cats.photo
            case "video" => cats.video
            case "file" => cats.file
            case _ => cats.stories
        }
        this.contacts = cat.contacts
        this.otherPrivate = cat.otherPrivate
        this.groups = cat.groups
        this.channels = cat.channels
        this.predownload = cat.predownload
        if (this.hasSize()) {
            this.sizeLimit = cat.sizeLimit
            this.sliderPos = sliderPosForSize(cat.sizeLimit)
            this.refreshSizeLabels()
            this.minEdgeLabel = autodownloadDataSizeString(512 * 1024)
            this.maxEdgeLabel = autodownloadDataSizeString(1536 * 1024 * 1024)
        }
    }

    private func setPeer(peer: AutoDownloadPeerKind, value: Bool): Unit {
        getFileDownloadService().setCategoryPeer(this.connKind(), this.categoryKind(), peer, value)
        Hilog.info(0, "CjTelegram", "[AutodownloadMediaCategory] ${this.connectionKind}.${this.category} peer updated")
    }

    // Live-follows the drag (A2): every slider event updates the bare @State labels;
    // persistence happens on every event too (source: adjustSize has no "commit"
    // buffer — A6 requires the value to already be on disk before the case's
    // force-stop). If this category currently has predownload=true and the drag moves
    // size back below the 2 MB threshold, the underlying `predownload` bit is left
    // untouched (B4) — `preloadEnabled()` alone gates the switch's *displayed* value
    // and its interactivity, source parity (`value && enabled` display rule).
    private func onSlide(pos: Float64): Unit {
        this.sliderPos = pos
        let bytes = sizeForSliderPos(pos)
        this.sizeLimit = bytes
        this.refreshSizeLabels()
        getFileDownloadService().setCategorySizeLimit(this.connKind(), this.categoryKind(), bytes)
    }

    // TC-0427 round3 fix (B1 + S11, same root cause, two required guards — see
    // diag-suite_settings_data_storage-TC-0427-round3.md 修法方向 改动2): the platform
    // echoes `isOn` back through `onChange` whenever the declarative binding is
    // rewritten by refresh()/setPeer-style code (not only on real user taps). This
    // callback must therefore *adopt* the delivered value (never blindly negate it)
    // and must be idempotent (no-op when the delivered value already equals the
    // authoritative model) — source parity: ItemListSwitchItem.swift:549-550 uses
    // setOn() for programmatic reconciliation, which does not redispatch
    // .valueChanged, so `updated` is never invoked by an echo on the source side.
    private func setPredownload(on: Bool): Unit {
        if (!this.preloadEnabled()) { return }   // disabled: no user-intent path (source parity: enabled:false + hidden gesture node)
        if (on == this.predownload) { return }   // echo: display already matches authority — no-op, no write, no preset=custom
        this.predownload = on
        getFileDownloadService().setCategoryPredownload(this.connKind(), this.categoryKind(), on)
        Hilog.info(0, "CjTelegram", "[AutodownloadMediaCategory] ${this.connectionKind}.${this.category}.predownload=${on}")
    }

    private func titleText(): String {
        match (this.category) {
            case "photo" => return "Photos"
            case "video" => return "Videos"
            // Source uses the AutoDownloadSettings_DocumentsTitle localization key,
            // whose current English value is "Files" (confirmed on the running source).
            case "file" => return trSource("Files")
            case _ => return "Stories"
        }
    }

    // Source-exact strings (Localizable.strings:4192-4194):
    // AutoDownloadSettings.AutodownloadPhotos / AutodownloadVideos / AutodownloadFiles.
    // Stories has no header on this screen — source appends `.peerHeader` only in the
    // non-story branch (AutodownloadMediaCategoryController.swift:281-286).
    private func peerHeaderText(): String {
        match (this.category) {
            case "photo" => return "AUTO-DOWNLOAD PHOTOS"
            case "video" => return "AUTO-DOWNLOAD VIDEOS AND GIFS"
            case _ => return "AUTO-DOWNLOAD FILES AND MUSIC"
        }
    }

    private func sizeHeaderText(): String {
        if (this.isVideo()) { return "MAXIMUM VIDEO SIZE" } else { return "MAXIMUM FILE SIZE" }
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
                    // TC-0427 round3 fix, static peer-echo prediction (see diag-...-
                    // TC-0427-round3.md 给 Coordinator 的建议 §2, verified while fixing
                    // B1/S11): refresh() (onAppear) can rewrite these @State peer fields
                    // away from their `true` initial value the moment a low/mid preset's
                    // stored value is `false`. That declarative rewrite echoes back
                    // through ItemListToggleRow -> Toggle.onChange exactly once (the
                    // shared engine forwards every platform onChange unconditionally —
                    // components/ItemListComponents.cj:587-589 — an echo that happens
                    // not to repeat is still forwarded once), and every one of these
                    // call sites used to call setPeer() unconditionally on that forward,
                    // silently writing preset=custom on a purely read-only screen visit —
                    // same class of defect as S11, just non-oscillating. Guarding on
                    // `on != <field>` blocks only the echo (a real user tap always
                    // delivers `on` different from the field it's bound to) while
                    // leaving every genuine tap unaffected.
                    if (this.isStory()) {
                        // ── Stories: no header, Contacts + conditional Archived Contacts ──
                        Column {
                            ItemListToggleRow(
                                title: "Contacts",
                                isOn: this.contacts,
                                onChange: { on: Bool =>
                                    if (on != this.contacts) {
                                        this.contacts = on
                                        this.setPeer(AutoDownloadPeerKind.PeerContacts, on)
                                    }
                                }
                            )
                            if (this.contacts) {
                                ItemListSeparator()
                                ItemListToggleRow(
                                    title: "Archived Contacts",
                                    isOn: this.otherPrivate,
                                    onChange: { on: Bool =>
                                        if (on != this.otherPrivate) {
                                            this.otherPrivate = on
                                            this.setPeer(AutoDownloadPeerKind.PeerOtherPrivate, on)
                                        }
                                    }
                                )
                            }
                        }
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(26)
                        .margin(left: 16, right: 16, top: 16)
                    } else {
                        // ── Photos/Videos/Files: header + 4 peer toggles ──
                        ItemListSectionHeader(title: this.peerHeaderLabel, topPad: 16)
                        Column {
                            ItemListToggleRow(
                                title: "Contacts",
                                isOn: this.contacts,
                                onChange: { on: Bool =>
                                    if (on != this.contacts) {
                                        this.contacts = on
                                        this.setPeer(AutoDownloadPeerKind.PeerContacts, on)
                                    }
                                }
                            )
                            ItemListSeparator()
                            ItemListToggleRow(
                                title: "Other Private Chats",
                                isOn: this.otherPrivate,
                                onChange: { on: Bool =>
                                    if (on != this.otherPrivate) {
                                        this.otherPrivate = on
                                        this.setPeer(AutoDownloadPeerKind.PeerOtherPrivate, on)
                                    }
                                }
                            )
                            ItemListSeparator()
                            ItemListToggleRow(
                                title: "Group Chats",
                                isOn: this.groups,
                                onChange: { on: Bool =>
                                    if (on != this.groups) {
                                        this.groups = on
                                        this.setPeer(AutoDownloadPeerKind.PeerGroups, on)
                                    }
                                }
                            )
                            ItemListSeparator()
                            ItemListToggleRow(
                                title: "Channels",
                                isOn: this.channels,
                                onChange: { on: Bool =>
                                    if (on != this.channels) {
                                        this.channels = on
                                        this.setPeer(AutoDownloadPeerKind.PeerChannels, on)
                                    }
                                }
                            )
                        }
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(26)
                        .margin(left: 16, right: 16)
                    }

                    // ── size slider (video/file only) ──
                    if (this.hasSize()) {
                        ItemListSectionHeader(title: this.sizeHeaderLabel, topPad: 24)

                        Column {
                            Row {
                                Text(this.minEdgeLabel)
                                    .fontSize(13).fontColor(this.presentation.secondaryTextColor)
                                    .layoutWeight(1)
                                Text(this.sizeTitleLabel)
                                    .fontSize(17).fontColor(this.presentation.textColor)
                                    .layoutWeight(2).textAlign(TextAlign.Center)
                                Text(this.maxEdgeLabel)
                                    .fontSize(13).fontColor(this.presentation.secondaryTextColor)
                                    .layoutWeight(1).textAlign(TextAlign.End)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 4)

                            // Continuous slider (A group). Domain integerized via
                            // `SLIDER_POS_SCALE` — see the derivation comment at that
                            // constant's definition. `onSlide(pos:)` still takes `[0,1]`;
                            // the anchor table and both mapping functions are untouched.
                            Slider(value: this.sliderPos * SLIDER_POS_SCALE, min: 0.0, max: SLIDER_POS_SCALE, step: 1.0)
                                .width(100.percent)
                                .padding(left: 16, right: 16, bottom: 12)
                                .onChange({ value: Float64, _mode: SliderChangeMode =>
                                    this.onSlide(value / SLIDER_POS_SCALE)
                                })

                            // Source keeps the preload switch in the same block as the size
                            // slider, separated by a single item divider.
                            if (this.isVideo()) {
                                ItemListSeparator()
                                if (this.sizeLimit > PRELOAD_ENABLE_THRESHOLD) {
                                    ItemListToggleRow(
                                        title: "Preload Larger Videos",
                                        isOn: this.predownload,
                                        enabled: true,
                                        onChange: { on: Bool => this.setPredownload(on) }
                                    )
                                } else {
                                    // isOn: false is a literal — source parity with
                                    // `value && enabled` at enabled==false
                                    // (AutodownloadMediaCategoryController.swift:214). The
                                    // underlying `predownload` bit is left untouched on this
                                    // branch (B4 semantics).
                                    ItemListToggleRow(
                                        title: "Preload Larger Videos",
                                        isOn: false,
                                        enabled: false,
                                        onChange: { _: Bool => }
                                    )
                                }
                            }
                        }
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(26)
                        .clip(true)
                        .margin(left: 16, right: 16)

                        if (this.isVideo()) {
                            Text(this.preloadInfoText)
                                .fontSize(13)
                                .fontColor(this.presentation.secondaryTextColor)
                                .padding(left: 32, right: 32)
                                .margin(top: 8, bottom: 32)
                                .width(100.percent)
                        }
                    }
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
            this.refresh()
        })
    }
}
