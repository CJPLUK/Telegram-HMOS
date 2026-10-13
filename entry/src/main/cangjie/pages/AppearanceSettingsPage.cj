package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.unicode.*
import ohos_app_cangjie_entry.core.storage.{getAuthStorage, PresentationSnapshot, currentPresentation, recomputePresentation, themeIconColors, ThemeIconColors, THEME_KIND_DAY_CLASSIC, THEME_KIND_DAY, THEME_KIND_NIGHT, THEME_KIND_NIGHT_ACCENT, PresentationStringsSnapshot, currentPresentationStrings}
import ohos_app_cangjie_entry.services.{getWallpaperBackgroundService, WallpaperType, WallpaperInfo, saveActiveThemeWallpaper, clearActiveThemeWallpapers, getThemesEngineService, getGlobalAbilityContext, gradientPositionsForPhase, gradientComputePixel, ThemeItem, getAppliedCloudThemeSlug, clearAppliedCloudTheme, AppliedCloudTheme, saveAppliedCloudTheme, clearSelectedWallpaper}
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.{subscribe, callArkOnJSTask}
import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.utils.formatMessageTimestampAt
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * Appearance Settings — entry-driven rebuild (TC-0400 round).
 *
 * build() walks the same 18-entry, stableId 0-17 model as
 * ThemeSettingsController.swift:123-141 / :160- (source authority), in order. Only three
 * section headers survive from the previous ad hoc rebuild: COLOR THEME (#0), APP ICON (#12),
 * OTHER (#14). Entry #15 (sendWithCmdEnter) is source-conditional on iPad and is never shown on
 * this platform, matching source's own conditional omission rather than a target-side gap.
 *
 * Two entries (#7 autoNightTheme, #8 textSize) render disclosure rows whose destination screens
 * (AutoNightSettingsPage, TextSizeSelectionPage) are separate rounds not built here — see the
 * feature hand-off report for the exact right-value sourcing decision on each.
 *
 * Theme selection follows ThemeSettingsController's carousel directly. Night Mode remains the
 * separate automaticThemeSwitchSetting.force control; the source has no extra mode selector here.
 */
@HybridComponentEntry
@Component
public class AppearanceSettingsPage {
    // ic_presentation_snapshot_consumption (first-wave obligor): every colour and font size this
    // screen renders comes from this snapshot field. No 0xFFFFFF/0x000000 literals for screen
    // chrome — the #2 themes carousel's per-preset card colours (see buildCarouselCard below) are
    // sourced from core/storage/AppTheme.cj:themeIconColors(), not from a literal table here;
    // they describe four *other* themes' fixed colour identities, not this screen's own live chrome.
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()

    private func localized(key: String, fallback: String): String {
        return this.presentationStrings.getOr(key, fallback)
    }

    // ---- #2 themes carousel: which built-in preset card is selected ----
    @State var themePresetIndex: Int32 = 0
    // S7-106: slug of the applied cloud chat theme ("" = a built-in theme is current), mirrors
    // ThemeSettingsController's currentTheme for the carousel selection ring.
    @State var appliedCloudSlug: String = ""
    @State var selectedChatThemeSlug: String = ""
    @State var carouselIsDark: Bool = false
    @State var carouselMountToggle: Bool = false

    // TC-0400 round12 F-C (diag-suite_settings_appearance-TC-0400-round12.md §6 F-C 第 1 条):
    // the carousel's non-auto-night branch now renders the built-in dayClassic card plus every
    // loaded cloud theme with a non-empty emoticon (source: ThemeSettingsController.swift:1148-
    // 1150 chatThemes), not four fixed built-in presets. This is this page's own copy of the same
    // load — pages/ChatThemesPage.cj's chatThemeItems is a separate @Component instance's state,
    // not something this page can read.
    @State var chatThemeItems: Array<ThemeItem> = Array<ThemeItem>()

    // ---- #6 autoNight master switch ----
    @State var autoNightEnabled: Bool = false

    // ---- #7 autoNightTheme: real persisted mode (TC-0403 D1 fix) ----
    // Bare @State (not a function-call result) so that re-assigning it — at loadSettings() and
    // at the onAppearanceShown() handler below — is itself what triggers this NavDestination to
    // rebuild (same bare-@State-drives-rebuild mechanism D-125 already documents for the two
    // *RightValueMirror fields further down). Before this field existed, autoNightThemeRightValue()
    // was a hardcoded literal with no @State dependency at all, so nothing could ever signal a
    // rebuild — that was the actual defect (diag-suite_settings_appearance-TC-0403-round1.md D1),
    // not just "the literal is wrong". Default 3 matches ThemesEngineService.getAutoNightMode()'s
    // own default (System).
    @State var autoNightMode: Int32 = 3

    // TC-0403 D1: event name literal must match entry/src/main/ets/pages/AppearanceSettingsPage.ets's
    // dispatchEvent(APPEARANCE_SETTINGS_SHOWN_EVENT, ...) verbatim (same cross-file-literal
    // precedent as auth/PhoneInputPage.cj's phoneInputShownEvent / PhoneInputPage.ets — interop.cj
    // is not in this feature's target_files, so no shared constant is introduced).
    private let appearanceShownEvent: String = "settings.appearanceSettingsPage.shown"

    // ---- #12/#13 app icon selection ----
    @State var selectedAppIconIndex: Int32 = 0

    // ---- #16 showNextMediaOnTap ----
    // F-6 (diag-suite_settings_appearance-TC-0400-round4.md, ⑭): default true to match
    // MediaDisplaySettings.swift:8-10 defaultSettings(showNextMediaOnTap: true) — this is the
    // compile-time default only, mirroring loadShowNextMediaOnTap()'s never-written-yet fallback
    // below; an account that has explicitly written `0` still loads false via loadSettings().
    @State var showNextMediaOnTap: Bool = true

    // ---- #7/#8 disclosure-row right values, mirrored into bare @State fields (D-125) ----
    // ItemListDisclosureRow(value:) call sites only enter the macro's build() dependency graph
    // when the argument is a bare this.<@State field> reference; a function-call result
    // (this.autoNightThemeRightValue()) never enters that graph, so the row would not re-build
    // when this.presentation changes even though this parent recomputes correctly (D-125,
    // established from device hilog on PhoneInputPage). ItemListToggleRow.isOn a few lines below
    // in build() already receives a bare @State field (this.autoNightEnabled /
    // this.showNextMediaOnTap) for the same reason; these two mirrors + refreshRightValueMirrors()
    // give the two ItemListDisclosureRow call sites the same treatment.
    @State var autoNightThemeRightValueMirror: String = "System"
    @State var textSizeRightValueMirror: String = ""

    // ---- #0 COLOR THEME section header, mirrored into a bare @State field (D-125) ----
    // diag-suite_settings_appearance-TC-0402-round8.md RC-1 / F-1. ItemListSectionHeader.title is
    // already @Prop (components/ItemListComponents.cj:196), so the child half of the channel was
    // never the problem — the parent half was: the call site used to pass
    // colorThemeHeaderTitle(this.presentation.autoNightModeTriggered), a *function-call result*,
    // which per D-125 never enters the macro's build() dependency graph. That node was therefore
    // never re-built when this.presentation changed, so its @Prop never received a new value and
    // the header froze at whatever it evaluated to at mount time. Measured on device: entering
    // the screen in light and then switching the system to dark left the header at "COLOR THEME"
    // for the entire dark period and it was still there after switching back — the triggered
    // title never rendered once in that session.
    // Same treatment as the two right-value mirrors above; refreshed by the single probe.
    // Initial value is the non-triggered title, so the first frame is pixel-identical to before.
    @State var colorThemeHeaderTitleMirror: String = "COLOR THEME"

    // ---- #6 Night Mode row `enabled`, mirror + dedicated remount toggle (D-156/D-160/D-184) ----
    // diag-suite_settings_appearance-TC-0402-round8.md RC-2 / F-2 (case criteria C1 + C2).
    // ItemListToggleRow.enabled is an *undecorated* `public var` (components/ItemListComponents.cj
    // :460), so unlike title/isOn above it has no parent re-feed channel at all: per D-197 an
    // undecorated field (and equally a child-side @State) is assigned once at construction and
    // never re-applied; only @Prop/@Link establish a live parent to child channel. On top of that
    // the call site passed a compound boolean expression, which D-125 independently keeps out of
    // the dependency graph. Two separate blocks, so fixing either alone still leaves the row
    // frozen — hence a remount guard rather than only rewriting the call site.
    // Consequence measured on device: the screen mounts in system light with
    // autoNightModeTriggered=false, giving enabled = !false || false = true, frozen; the system
    // then goes dark, source requires enabled=false, but the row keeps the stale `true` — so no
    // disabled treatment (C1) and the switch still flips on tap (C2). Both are the one stale value.
    // Why a remount guard and not @Prop-ising the field: @Prop-ising is the structurally correct
    // fix, but @Prop takes no default value in this SDK (S-141) and ItemListToggleRow has 78 call
    // sites of which only 2 pass `enabled:`, so it would force 76 edits across a dozen features'
    // allowlists. The diagnosis made that scope call; this is D-184's established downgrade path.
    // Dedicated fields on purpose (D-160 step 2): nothing else may flip this toggle as a side
    // effect. Initial `true` equals ItemListToggleRow.enabled's own default and the guard only
    // flips when the value really changes, so the light steady state is pixel-identical to before.
    @State var nightModeRowEnabledMirror: Bool = true
    @State var nightModeRowMountToggle: Bool = false

    // ---- #1 chatPreview child-component inputs, mirrored into bare @State fields (D-125) ----
    // Exact same mechanism as the two right-value mirrors above, applied to the preview block's
    // three child call sites (WallpaperBackgroundComponent + two MessageBubble). Before this,
    // those call sites passed `this.presentation.<field>` (nested field access) and
    // `this.previewWallpaper()` (function-call result) — the two forms D-125 names explicitly as
    // *not* entering the macro's build() dependency graph. Consequence measured on device
    // (diag-suite_settings_appearance-TC-0401-round6.md, RC-B, full-frame sampling of all 12
    // frames): toggling Night Mode on this same screen re-ran this parent's build() correctly but
    // never re-drove the already-mounted children, so the bubbles and the reply quote stayed
    // frozen at the light snapshot's colours; a cold start straight into dark rendered them
    // correctly, which is what isolates the failure to "mounted instance is never re-fed" rather
    // than "child does not subscribe".
    // Initial values reproduce the light PresentationSnapshot (core/storage/AppTheme.cj:601/604/
    // 605/590) and WallpaperInfo's own defaults (services/WallpaperBackgroundService.cj:208-227),
    // so the first frame is pixel-identical to before; refreshRightValueMirrors() overwrites all
    // of them at the top of every build() pass, before any of the three call sites below is
    // constructed.
    @State var previewBubbleOutColor: UInt32 = 0xE8F5E9
    @State var previewBubbleInColor: UInt32 = 0xF0F0F0
    @State var previewBubbleTextColor: UInt32 = 0x000000
    @State var previewIsDark: Bool = false
    // Reply-quote author colour: the account's *name* colour, not the global accent — source's
    // ChatPreviewMessageItem(..., nameColor:) colours the preview reply author with the same value
    // the "Your Color" row shows (see nameColorHex() below, and ChatMessageReplyInfoNode.swift
    // :251-261). nameColorHex() is a function call, so it needs a mirror for exactly the same
    // D-125 reason — it must not be written directly at the call site.
    @State var previewReplyAuthorColor: UInt32 = 0x4897D8
    // Wallpaper: one mirror per WallpaperBackgroundComponent argument. Deliberately eight flat
    // fields rather than one mirrored WallpaperInfo — passing `this.previewWpInfo.wallpaperType`
    // would re-introduce the nested-field-access form D-125 rules out.
    @State var previewWpType: WallpaperType = WallpaperType.SolidColor
    @State var previewWpSolid: UInt32 = 0xFFE8E6DF
    @State var previewWpGradStart: UInt32 = 0xFF8CA0D8
    @State var previewWpGradEnd: UInt32 = 0xFF4A5F9E
    @State var previewWpGradAngle: Float64 = 180.0
    @State var previewWpImageUri: String = ""
    @State var previewWpGradColors: Array<UInt32> = [0xFF7FA381, 0xFFD3B48F, 0xFF336F55, 0xFFFBE37D]
    @State var previewWpPhase: Int32 = 0
    // TC-0402 round12 修法3: patternFile/patternOverlayEnabled 镜像，逐点同型于上面 8 个既有
    // 镜像——同样是普通 var（非 @Prop）参数，只在本页调用点传参（见 D-125 与 round12 §5 修法3
    // 的边界条件：不得把组件那两个字段升级成 @Prop，会强制另外 10 个不在本 feature allowlist
    // 内的调用点显式传参）。
    @State var previewWpPatternFile: String = ""
    @State var previewWpPatternOverlay: Bool = false
    // TC-0402 round13 F-3.3 (diag-suite_settings_appearance-TC-0402-round13.md §6): patternIntensity
    // mirror, same shape as the pair above — the preview call site was passing zero patternIntensity
    // arguments, so the component fell back to its own default (+0.5) and the negative intensity the
    // service layer computes for the dark theme default never reached the preview block (blocking
    // the invert path in WallpaperBackgroundComponent's build()).
    @State var previewWpPatternIntensity: Float64 = 0.5
    // D-160/D-184 remount guard toggle for the two preview MessageBubble instances. Dedicated on
    // purpose (not reused from any other boolean state) so nothing else can flip it as a side
    // effect. Why a remount is needed at all: the mirrors above fix the *parent* half — they make
    // this build() re-run and re-evaluate the arguments — but MessageBubble's six theme fields are
    // @State, and the macro's @State init assign is a one-off value copy at construction
    // (state_macro_manage/cj_generate_var_decl.cj:206-214: `ObservedProperty(info, v.get())`),
    // not a live channel like @Prop's `v.createProp(info)`. So an already-mounted bubble is never
    // re-fed. Flipping this toggle moves the mount point to the other if/else branch, whose
    // different branchId makes the framework tear the old instance down and construct a new one —
    // and that new construction is what re-runs the @State init with the current mirror values.
    // Initial value false (⇒ first render takes the else branch) matches both in-repo precedents,
    // pages/SettingsPage.cj:1308 and pages/ChatQrCodeSharePage.cj.
    @State var previewBubbleMountToggle: Bool = false

    // ---- #1 chatPreview block height = measured content height ----
    // diag-suite_settings_appearance-TC-0400-round7.md RC-1 / F-1. The preview Stack below
    // declares no height of its own (round4's F-2 removed the fixed .height(180)), and its only
    // child that declares one is WallpaperBackgroundComponent's root node,
    // components/WallpaperBackgroundComponent.cj:418-419 .width(100.percent).height(100.percent).
    // ArkUI resolves a percentage height against the layout constraint handed down by the parent
    // when the parent itself has no determinate height — here the enclosing Scroll's viewport —
    // so the wallpaper measured 2230px and, being the tallest child, dragged the Stack to that
    // height; the 680px content Column was then centred by Stack's default Alignment.Center,
    // leaving 775px of bare wallpaper above and 775px below. The symmetry to the pixel is what
    // identifies the mechanism: the container's height had nothing to do with its content.
    // NB this supersedes round6's reading, which treated the inflated preview as a downstream
    // consequence of the reply colour-bar expansion in MessageBubble. It is not: the colour bar
    // was fixed and the container grew (1582px -> 2230px), because the colour bar had been
    // clamping the percentage evaluation, not causing it.
    // Fix inverts the dependency back to the source's direction: source computes the block from
    // its content (ThemeSettingsChatPreviewItem.swift:211-215, contentSize = 4.0 + 4.0 + the sum
    // of the message node heights) and only then frames the wallpaper node to that size
    // (:294-295 backgroundNode.frame = backgroundFrame...). Here the content Column reports its
    // measured height through onAreaChange, the Stack takes that height, and the wallpaper's
    // 100.percent then resolves correctly against a determinate parent — so
    // WallpaperBackgroundComponent needs no change (its percentage form is right for its other
    // call sites, and that file is not in this feature's allowlist either way).
    // Initial value only stands in for the very first frame, before the first onAreaChange:
    // 202 = the 680px content measured this round / 3.5 + the Column's own 4vp+4vp padding.
    // Deliberately NOT a constant container height — round4 removed one of those on purpose.
    @State var previewContentHeight: Float64 = 202.0

    // ---- 混合工程首帧加载守卫 ----
    @State var loaded: Bool = false

    // ==================== #0 COLOR THEME ====================

    // Source: presentationData.autoNightModeTriggered ? Appearance_ColorThemeNight :
    // Appearance_ColorTheme (ThemeSettingsController.swift:419). Fully sourceable today because
    // PresentationSnapshot already carries autoNightModeTriggered — its evaluator (TC-0402/0403
    // F7, a separate feature) is not wired yet so this reads constant false for now, which is the
    // correct current value, not a fabricated one.
    private func colorThemeHeaderTitle(triggered: Bool): String {
        if (triggered) {
            return this.localized("Appearance_ColorThemeNight", "COLOR THEME — AUTO-NIGHT MODE")
        }
        return this.localized("Appearance_ColorTheme", "COLOR THEME")
    }

    private func saveTheme(theme: Int32): Unit {
        let storage = getAuthStorage()
        storage.saveAppearanceTheme(theme)
        // TC-0401 F2/"同时必须修": write the setting, then let the single recompute entry point
        // derive the new snapshot and publish it. No local applyTheme, no separate accent patch-up.
        let _ = recomputePresentation()
        Hilog.info(0, "CjTelegram", "[AppearanceSettings] Saved theme: ${theme}")
    }

    // ==================== #1 chatPreview ====================

    // Source ThemeSettingsController.swift:424-436: default reply author is
    // Appearance_PreviewReplyAuthor ("Lucio"), replaced by the account's display name only when
    // the account has a custom name colour. This target has no account-peer / display-name lookup
    // available yet (nameColor picking itself moved behind the not-yet-built #5 disclosure
    // destination), so this renders the same default-account state source renders when there is
    // no custom name colour — not an invented value.
    private func chatPreviewAuthorName(): String {
        return this.localized("Appearance_PreviewReplyAuthor", "Lucio")
    }

    private func previewWallpaper(): WallpaperInfo {
        return getWallpaperBackgroundService().getCurrentWallpaper()
    }

    // TC-0400 round3 F-1 (diag-suite_settings_appearance-TC-0400-round3.md RC-A-2): the preview
    // block must walk the same message-bubble renderer as the real chat (components/
    // MessageBubble.cj) instead of a hand-rolled Column/Text pair, so tail + timestamp + read
    // double-check all come from one real pipeline instead of being separately re-implemented.
    // Field values are the two ChatPreviewMessageItem fixtures (ThemeSettingsChatPreviewItem.swift
    // :163-172), rawTimestamp = 66000 for both.
    private func previewIncomingMessage(): Message {
        let msg = Message()
        msg.rawTimestamp = 66000
        msg.time = formatMessageTimestampAt(66000, 66000, true)
        msg.isLastInGroup = true
        msg.isSingleMessage = true
        msg.isSent = false
        // F-3r (diag-suite_settings_appearance-TC-0400.md / round4 F-3): do NOT set senderName
        // here. Source's incoming preview fixture (ThemeSettingsChatPreviewItem.swift:172)
        // constructs `author: nil` for the incoming message — only the reply block below gets an
        // author. MessageBubble.cj's independent-author-name row only renders when senderName is
        // non-empty (models/Message.cj:23 default is ""), so leaving this unset here reproduces
        // source's actual behaviour instead of fabricating an extra name row source never shows.
        msg.content = this.localized("Appearance_PreviewIncomingText", "Ah you kids today with techno music! Enjoy the classics, like Hasselhoff!")
        msg.replyToMsgId = 3
        msg.replyToSenderName = this.chatPreviewAuthorName()
        msg.replyToText = this.localized("Appearance_PreviewReplyText", "Reinhardt, we need to find you some...")
        return msg
    }

    private func previewOutgoingMessage(): Message {
        let msg = Message()
        msg.rawTimestamp = 66000
        msg.time = formatMessageTimestampAt(66000, 66000, true)
        msg.isLastInGroup = true
        msg.isSingleMessage = true
        msg.isSent = true
        msg.status = "read"
        msg.content = this.localized("Appearance_PreviewOutgoingText", "I can't take you seriously right now. Sorry..")
        return msg
    }

    // ==================== #2 themes carousel ====================
    // Per-preset design tokens: each slide previews a *different* built-in theme's fixed colour
    // identity (dayClassic/nightAccent/day/night), analogous to source's PresentationThemeReference
    // colour tables — these are theme *data*, not this screen's own live chrome, so they are
    // intentionally literal rather than sourced from the live presentation snapshot.
    // F-5 (diag-suite_settings_appearance-TC-0402-round6.md): identity set collapsed from five
    // to the four source carries (ThemeSettingsController.swift:1128-1139 defaultThemes):
    // 0=dayClassic, 1=nightAccent, 2=day, 3=night. Tinted/Arctic (former indices 3/4) do not
    // exist in source's defaultThemes and are dropped; former Tinted's colour identity (the
    // accent-tinted dark tone) is reused for nightAccent rather than invented anew.
    // TC-0415 B3b (diag-suite_settings_appearance-TC-0400-round10.md dispatch): "Night Accent" was
    // a fabricated literal matching neither the source constant
    // (Appearance.ThemeCarouselTintedNight, Localizable.strings:4734 = "Tinted Night") nor any
    // observed reference runtime value. Corrected to the source string.
    private func presetName(index: Int32): String {
        if (index == 0) { return this.localized("Appearance_ThemeCarouselClassic", "Classic") }
        if (index == 1) { return this.localized("Appearance_ThemeCarouselTintedNight", "Tinted Night") }
        if (index == 2) { return this.localized("Appearance_ThemeCarouselDay", "Day") }
        return this.localized("Appearance_ThemeCarouselNewNight", "Night")
    }

    // TC-0400 round9 F-4: the three index-keyed literal colour tables that used to live here
    // (presetBgColor / presetIncomingBubbleColor / presetOutgoingBubbleColor) were the "pull an
    // approximation out of the visible appearance" artefact diag-suite_settings_appearance-
    // TC-0400-round9.md N-3 flags — deleted. Card colours now come from a real per-theme input
    // (core/storage/AppTheme.cj:themeIconColors(kind), F-4's own owner core_presentation_data),
    // not from a table keyed by carousel position, matching source's per-theme
    // themeIconImage(...) call (ThemeCarouselItem.swift:408). THEME_KIND_* already lines up
    // 1:1 with this file's existing 0=dayClassic/1=nightAccent/2=day/3=night carousel index, so
    // the carousel's own `index` argument is passed straight through.

    // TC-0400 RC-2 item 4: bubble shapes only, no text (see build()'s carousel comment for why),
    // so the two per-index text-colour functions that used to feed "Hello!"/"How are you?" are
    // gone along with that text — nothing else in this file referenced them.

    private func carouselBuiltinKind(index: Int32): Int32 {
        if (this.carouselIsDark) { return THEME_KIND_NIGHT }
        return index
    }

    @Builder
    func buildCarouselCard(index: Int32) {
        // S-005: @Builder bodies cannot bind a `let` (macro rejects any non-UI statement), so
        // themeIconColors(index) is called again at each use site below rather than cached once.
        // TC-0400 round10 F-1 (diag-suite_settings_appearance-TC-0400-round10.md): the previous
        // Column/Row flat-colour mock (zero Image/Canvas nodes, E1-a FAIL for the 4th time) is
        // replaced by a real Canvas-backed thumbnail — see ThemeCarouselCardCanvas below.
        // TC-0400 round12 F-B (diag-suite_settings_appearance-TC-0400-round12.md §3.2/§6 F-B):
        // the outer Stack is now the source's *container* geometry (90x120, ListView item pitch,
        // ThemeCarouselItem.swift:394/:427 containerNode.frame) with no chrome of its own; a new
        // inner 82x108 Stack at offset (4,6) carries the Canvas plus the rounded clip/selection
        // border — the source's actual painted thumbnail (imageNode.frame, :434-436), leaving an
        // 8pt gap visible between adjacent cards' painted content even though the containers
        // themselves are pitch-adjacent (pitch 90, no inter-container margin).
        Stack {
            Stack {
                ThemeCarouselCardCanvas(
                    wallpaperColors: themeIconColors(this.carouselBuiltinKind(index)).wallpaperColors,
                    incomingColor: themeIconColors(this.carouselBuiltinKind(index)).incomingBubbleColor,
                    outgoingColor: themeIconColors(this.carouselBuiltinKind(index)).outgoingBubbleColor,
                    fallbackColor: themeIconColors(this.carouselBuiltinKind(index)).backgroundColor,
                    canvasW: 90.0,
                    canvasH: 120.0,
                    drawBackground: true
                )
                Text("🏠")
                    .fontSize(26)
                    .margin(top: 68)
            }
            .width(82)
            .height(108)
            .margin(left: 4, top: 6)
            .borderRadius(14)
            .clip(true)
            // F-8: radius 12 -> 14, matching ThemeCarouselItem.swift:239 imageNode.cornerRadius
            // = 14.0. round12 F-B: selection ring moved onto the thumbnail (source
            // overlayNode.frame hugs imageNode, :438, not containerNode) off the outer 90x120 Stack.
            .border(width: if (this.themePresetIndex == index && this.appliedCloudSlug.isEmpty() && this.selectedChatThemeSlug.size == 0) { 3 } else { 0 }, color: this.presentation.accentColor, radius: 14)
        }
        // ThemeCarouselItem.swift:427 containerNode.frame is a *portrait* 90×120, not the 120×90
        // this file had — :394's 120×90 is the pre-rotation ListView-coordinate contentSize
        // (:855-857 swaps the ListView's own bounds width/height), not the on-screen card size.
        .width(90)
        .height(120)
        .alignContent(Alignment.TopStart)
        // round12 F-B: no inter-container margin (source ListView item pitch is a flat 90, cards
        // are pitch-adjacent); the visible gap between painted thumbnails now comes entirely from
        // the inner Stack's own (4,6) offset above, not from a margin on this outer chrome.
        .margin(right: 0)
        .onClick({ evt => this.applyThemePreset(index) })
    }

    // TC-0400 round12 F-C (diag-suite_settings_appearance-TC-0400-round12.md §6 F-C): cloud-theme
    // sibling of buildCarouselCard() above — same 90x120 container / 82x108 thumbnail geometry.
    // The source entry carousel applies cloud themes directly and remains on this page; the
    // selected slug therefore drives the outline and is persisted by ThemesEngineService.
    @Builder
    func buildCloudCarouselCard(item: ThemeItem) {
        Stack {
            Stack {
                ThemeCarouselCardCanvas(
                    wallpaperColors: this.cloudCardColorsForMode(item, this.carouselIsDark).wallpaperColors,
                    incomingColor: this.cloudCardColorsForMode(item, this.carouselIsDark).incomingBubbleColor,
                    outgoingColor: this.cloudCardColorsForMode(item, this.carouselIsDark).outgoingBubbleColor,
                    fallbackColor: this.cloudCardColorsForMode(item, this.carouselIsDark).backgroundColor,
                    canvasW: 90.0,
                    canvasH: 120.0,
                    drawBackground: true
                )
                Text(item.emoticon)
                    .fontSize(26)
                    .margin(top: 68)
            }
            .width(82)
            .height(108)
            .margin(left: 4, top: 6)
            .borderRadius(14)
            .clip(true)
            // S7-106: selected when this cloud theme is the applied one (ThemeCarouselItem
            // selection = currentTheme.index == theme.index).
            .border(
                width: if (this.appliedCloudSlug == item.slug || this.selectedChatThemeSlug == item.slug) { 3 } else { 0 },
                color: this.cloudCardColorsForMode(item, this.carouselIsDark).outgoingBubbleColor,
                radius: 14
            )
        }
        .width(90)
        .height(120)
        .alignContent(Alignment.TopStart)
        .margin(right: 0)
        // S7-105：对位 ThemeSettingsController.swift:324-327 ThemeCarouselThemeItem.updatedTheme →
        // arguments.selectTheme(theme)：轮播点按直接应用（selectThemeImpl），不是进 ThemePreviewController。
        .onClick({ evt => this.applyCloudThemeFromCarousel(item) })
    }

    /**
     * S7-105：轮播里点云主题卡片 → 立即应用（iOS selectThemeImpl：.cloud 主题成为当前主题，
     * themeSpecificChatWallpapers[updatedTheme.index] = nil），页面上方聊天预览与界面配色随
     * recomputePresentation() 立即改变。落库形态与 ThemePreviewPage.onApplyClick 的云主题分支一致。
     */
    private func applyCloudThemeFromCarousel(item: ThemeItem): Unit {
        let cloud = AppliedCloudTheme()
        cloud.slug = item.slug
        cloud.wallpaperColors = item.wallpaperColors
        cloud.wallpaperIntensity = item.wallpaperIntensity
        cloud.wallpaperSlug = item.wallpaperSlug
        cloud.baseIsDark = item.settingsBaseTheme == "night" || item.settingsBaseTheme == "tinted"
        if (item.hasSettings) {
            cloud.baseTheme = if (item.settingsBaseTheme.isEmpty()) { "classic" } else { item.settingsBaseTheme }
            cloud.accentColor = UInt32(Int64(item.settingsAccentColor) & 0xFFFFFFFF)
            cloud.outgoingAccentColor = UInt32(Int64(item.settingsOutboxAccentColor) & 0xFFFFFFFF)
            cloud.messageColors = item.settingsMessageColors
        }
        saveAppliedCloudTheme(cloud)
        clearSelectedWallpaper()
        let targetTheme: Int32 = if (cloud.baseIsDark) { 1 } else { 0 }
        getAuthStorage().saveAppearanceTheme(targetTheme)
        let _ = recomputePresentation()
        this.appliedCloudSlug = item.slug
        this.themePresetIndex = getThemesEngineService().getThemePreset()
        // 同步写入 ThemesEngineService 的 selectedChatTheme（slug/palette）+ 双明暗变体壁纸槽，
        // 并经 account.saveTheme/installTheme 上云（iOS selectThemeImpl 的 applyTheme(account) 半边）。
        this.applyCloudTheme(item)
        // 把本次派生出的快照同步灌进本页 @StorageLink（同时写 AppStorage），预览气泡镜像在本轮
        // 就取到新色，不再依赖 publishPresentation() 的 launch{} 时序。
        this.presentation = recomputePresentation()
        let _ = this.refreshRightValueMirrors()
        Hilog.info(0, "CjTelegram", "[AppearanceSettings] Applied cloud theme from carousel slug=${item.slug} theme=${targetTheme}")
    }

    private func applyThemePreset(index: Int32): Unit {
        this.themePresetIndex = index
        let svc = getThemesEngineService()
        svc.saveThemePreset(index)
        // Selecting a built-in theme replaces an applied cloud theme (selectThemeImpl →
        // withUpdatedTheme(.builtin)); the wallpaper then comes from the built-in theme's slot.
        clearAppliedCloudTheme()
        this.appliedCloudSlug = ""
        this.selectedChatThemeSlug = ""
        clearActiveThemeWallpapers()
        svc.saveSelectedChatThemeSlug("")
        // S7-106：云主题的强调色/气泡色随之撤销（明暗未变时下方 saveTheme 不会触发重算）。
        // 同步灌进本页 @StorageLink（见 applyCloudThemeFromCarousel 同型注释）。
        this.presentation = recomputePresentation()
        spawn {
            let _ = svc.installTheme(false, None, None, Some(0))
        }
        // Presets carry an inherent light/dark identity (nightAccent/night are dark, dayClassic/day
        // are light). ThemesEngineService's persisted themePreset value has no consumer of its
        // own (computeSnapshot() never reads it), so without this the carousel would be purely
        // decorative — selecting "Night" would change nothing the user can see. Driving the real
        // theme selector from it is what gives preset selection an actual observable effect.
        // F-5: dark identities are now nightAccent(1) and night(3) (dayClassic=0, day=2 are light).
        if (index == 1 || index == 3) {
            if (this.presentation.theme != 1) {
                this.saveTheme(1)
            }
        } else {
            if (this.presentation.theme != 0) {
                this.saveTheme(0)
            }
        }
        let _ = this.refreshRightValueMirrors()
        Hilog.info(0, "CjTelegram", "[AppearanceSettings] Applied theme preset: ${index}")
    }

    private func cloudVariantIndex(item: ThemeItem, isDark: Bool): Int64 {
        var i: Int64 = 0
        while (i < item.settingsVariants.size) {
            let baseTheme = item.settingsVariants[i].baseTheme
            if (isDark) {
                if (baseTheme == "night" || baseTheme == "tinted") { return i }
            } else {
                if (baseTheme == "classic" || baseTheme == "day") { return i }
            }
            i++
        }
        return if (item.settingsVariants.size > 0) { 0 } else { -1 }
    }

    private func cloudCardColorsForMode(item: ThemeItem, isDark: Bool): ThemeIconColors {
        let variantIndex = this.cloudVariantIndex(item, isDark)
        if (variantIndex < 0) { return cloudCardColors(item) }
        let variant = item.settingsVariants[variantIndex]
        let variantItem = ThemeItem()
        variantItem.hasSettings = true
        variantItem.settingsBaseTheme = variant.baseTheme
        variantItem.settingsAccentColor = variant.accentColor
        variantItem.settingsMessageColors = variant.messageColors
        variantItem.wallpaperColors = variant.wallpaperColors
        return cloudCardColors(variantItem)
    }

    /** Resolve the ThemeSettings wallpaper exactly once for a concrete light/dark variant. */
    private func cloudWallpaperForMode(item: ThemeItem, isDark: Bool): WallpaperInfo {
        let info = WallpaperInfo()
        let variantIndex = this.cloudVariantIndex(item, isDark)
        var baseTheme = if (isDark) { "night" } else { "classic" }
        var hasWallpaper = item.hasWallpaper
        var wallpaperSlug = item.wallpaperSlug
        var wallpaperColors = item.wallpaperColors
        var wallpaperIntensity = item.wallpaperIntensity
        var wallpaperHasIntensity = item.wallpaperHasIntensity
        if (variantIndex >= 0) {
            let variant = item.settingsVariants[variantIndex]
            baseTheme = variant.baseTheme
            hasWallpaper = variant.hasWallpaper
            wallpaperSlug = variant.wallpaperSlug
            wallpaperColors = variant.wallpaperColors
            wallpaperIntensity = variant.wallpaperIntensity
            wallpaperHasIntensity = variant.wallpaperHasIntensity
        }

        if (hasWallpaper) {
            var colors = this.opaqueWallpaperColors(wallpaperColors)
            // A file wallpaper may omit its settings colour array. Source keeps the file/pattern
            // identity but lets the effective base theme provide the background behind it.
            if (colors.size == 0) {
                if (baseTheme == "day" || baseTheme == "arctic") {
                    colors = [0xFFFFFFFF]
                } else {
                    var fallbackKind = THEME_KIND_DAY_CLASSIC
                    if (baseTheme == "night") { fallbackKind = THEME_KIND_NIGHT }
                    else if (baseTheme == "tinted") { fallbackKind = THEME_KIND_NIGHT_ACCENT }
                    colors = this.opaqueWallpaperColors(themeIconColors(fallbackKind).wallpaperColors)
                }
            }
            if (colors.size == 1) {
                info.wallpaperType = WallpaperType.SolidColor
                info.solidColor = colors[0]
                info.gradientColors = colors
            } else if (colors.size == 2) {
                info.wallpaperType = WallpaperType.TwoColorGradient
                info.gradientColorStart = colors[0]
                info.gradientColorEnd = colors[1]
                info.gradientColors = colors
            } else if (colors.size > 2) {
                info.wallpaperType = WallpaperType.MultiColorGradient
                info.gradientColors = colors
            }
            info.patternIntensity = Float64(if (wallpaperHasIntensity) { wallpaperIntensity } else { Int32(50) }) / 100.0
            info.patternOverlayEnabled = wallpaperSlug.size > 0
            info.isDarkMode = isDark
            return info
        }

        // No explicit ThemeSettings wallpaper: source falls back to the selected base theme's
        // default wallpaper. Day is plain white; classic/night/tinted use their built-in pattern.
        if (baseTheme == "day" || baseTheme == "arctic") {
            info.wallpaperType = WallpaperType.SolidColor
            info.solidColor = 0xFFFFFFFF
            info.gradientColors = [0xFFFFFFFF]
            info.patternOverlayEnabled = false
            info.patternIntensity = 0.0
            info.isDarkMode = false
            return info
        }
        var kind = THEME_KIND_DAY_CLASSIC
        if (baseTheme == "night") { kind = THEME_KIND_NIGHT }
        else if (baseTheme == "tinted") { kind = THEME_KIND_NIGHT_ACCENT }
        let defaults = themeIconColors(kind)
        info.wallpaperType = WallpaperType.MultiColorGradient
        info.gradientColors = this.opaqueWallpaperColors(defaults.wallpaperColors)
        info.patternIntensity = if (baseTheme == "night") { -0.34 } else { 0.5 }
        info.patternFile = getWallpaperBackgroundService().getDefaultPatternFile()
        info.patternOverlayEnabled = true
        info.isDarkMode = isDark
        return info
    }

    private func persistCloudThemeWallpapers(item: ThemeItem): Unit {
        let wallpaperSvc = getWallpaperBackgroundService()
        let lightInfo = this.cloudWallpaperForMode(item, false)
        let darkInfo = this.cloudWallpaperForMode(item, true)
        saveActiveThemeWallpaper(false, lightInfo)
        saveActiveThemeWallpaper(true, darkInfo)

        // Explicit pattern documents are not the built-in pattern. Resolve each selected variant
        // by slug, then replace the persisted initial record with the downloaded raster layer.
        var lightSlug = item.wallpaperSlug
        var darkSlug = item.wallpaperSlug
        let lightIndex = this.cloudVariantIndex(item, false)
        let darkIndex = this.cloudVariantIndex(item, true)
        if (lightIndex >= 0) { lightSlug = item.settingsVariants[lightIndex].wallpaperSlug }
        if (darkIndex >= 0) { darkSlug = item.settingsVariants[darkIndex].wallpaperSlug }
        if (lightInfo.patternOverlayEnabled && lightSlug.size > 0) {
            wallpaperSvc.resolveThemePatternFile(lightSlug, { uri: String =>
                if (uri.size > 0) {
                    lightInfo.patternFile = uri
                    saveActiveThemeWallpaper(false, lightInfo)
                    launch {
                        if (!this.presentation.isDark && this.selectedChatThemeSlug == item.slug) {
                            this.previewWpPatternFile = uri
                            this.previewWpPatternOverlay = true
                        }
                    }
                }
            })
        }
        if (darkInfo.patternOverlayEnabled && darkSlug.size > 0) {
            wallpaperSvc.resolveThemePatternFile(darkSlug, { uri: String =>
                if (uri.size > 0) {
                    darkInfo.patternFile = uri
                    saveActiveThemeWallpaper(true, darkInfo)
                    launch {
                        if (this.presentation.isDark && this.selectedChatThemeSlug == item.slug) {
                            this.previewWpPatternFile = uri
                            this.previewWpPatternOverlay = true
                        }
                    }
                }
            })
        }
    }

    private func applyCloudThemeVariant(item: ThemeItem, isDark: Bool): Unit {
        let variantIndex = this.cloudVariantIndex(item, isDark)
        var accent: UInt32 = cloudColorInt32Bits(item.settingsAccentColor) & 0x00FFFFFFu32
        var bubble: UInt32 = 0
        if (variantIndex >= 0) {
            let variant = item.settingsVariants[variantIndex]
            accent = cloudColorInt32Bits(variant.accentColor) & 0x00FFFFFFu32
            if (variant.messageColors.size > 0) {
                bubble = variant.messageColors[variant.messageColors.size / 2] & 0x00FFFFFFu32
            }
        }
        getThemesEngineService().saveSelectedChatThemePalette(accent, bubble)
    }

    private func applyCloudTheme(item: ThemeItem): Unit {
        this.selectedChatThemeSlug = item.slug
        let svc = getThemesEngineService()
        this.persistCloudThemeWallpapers(item)
        svc.saveSelectedChatThemeSlug(item.slug)
        this.applyCloudThemeVariant(item, this.presentation.isDark)
        let slug = item.slug
        let dark = this.presentation.isDark
        spawn {
            let _ = svc.saveTheme(slug, false)
            let _ = svc.installTheme(dark, Some(slug), None, None)
        }
    }

    private func selectedCloudTheme(): Option<ThemeItem> {
        if (this.selectedChatThemeSlug.size == 0) { return None }
        for (item in this.chatThemeItems) {
            if (item.slug == this.selectedChatThemeSlug) { return Some(item) }
        }
        return None
    }

    private func opaqueWallpaperColors(colors: Array<UInt32>): Array<UInt32> {
        let result = ArrayList<UInt32>()
        for (color in colors) {
            result.add(color | 0xFF000000u32)
        }
        return result.toArray()
    }

    // ==================== #5 nameColor ("Your Color" row swatch) ====================
    // TC-0400 RC-1 (diag-suite_settings_appearance-TC-0400-round2.md F-2, corrected direction):
    // source's nameColor is never-empty (accountPeer.nameColor ?? .preset(.blue)) so the first
    // swatch always renders; profileColor is genuinely optional and a second swatch is appended
    // only when the user has ever set one. The "has ever set one" presence sentinel cannot be
    // sourced from ThemesEngineService.getProfileHeaderColorIndex() alone (it returns a
    // non-optional Int32 defaulting to 0, indistinguishable from "explicitly chose index 0"), and
    // ThemesEngineService.cj is not in this feature's target_files this round — adding a
    // has-been-set flag there would be an out-of-allowlist edit. EditProfilePage.cj:131-140 /
    // :200 (hasProfileColorSet(), read-only precedent, not modified here) already solved the same
    // problem with a different sentinel: AuthStorage.getProfileNameColor() returns -1 when its own
    // key was never written, so ">= 0" is reused here as the same presence gate without touching
    // any file outside this feature's allowlist.
    //
    // Colour table: local to this file (not a converged/shared table — the round-2 report's F-3
    // "collapse into one shared colour table" direction touches ProfileColorPage.cj, which has no
    // feature owner, and EditProfilePage.cj, which belongs to two other completed features;
    // neither is in this feature's allowlist, so this round does not attempt that convergence).
    // The 8 values mirror ProfileColorPage.cj:34-42, the write-end authority for these indices
    // (saveProfileNameColorIndex/saveProfileHeaderColorIndex persist against that same palette).
    // No dark variant: source's PeerNameColors dark table was not obtainable within this file's
    // allowlist, so both appearances render the light-mode hex (disclosed limitation, not an
    // invented dark value).
    private func profileSwatchPalette(): Array<UInt32> {
        return [
            0x4897D8, 0x45B72D, 0xE68A2E, 0xD7615B,
            0x9B63DC, 0x42A9C1, 0xCC5B92, 0x94A1AE
        ]
    }

    private func profileSwatchHex(index: Int32): UInt32 {
        let palette = this.profileSwatchPalette()
        if (index < 0 || Int64(index) >= palette.size) {
            return palette[palette.size - 1]
        }
        return palette[Int64(index)]
    }

    // Also reused by the #1 chatPreview reply quote (RC-2 item 7): source's
    // ChatPreviewMessageItem(..., nameColor: nameColor) colours the reply author with the same
    // account name colour as the "Your Color" row, not the global accent.
    private func nameColorHex(): UInt32 {
        return this.profileSwatchHex(getThemesEngineService().getProfileNameColorIndex())
    }

    private func yourColorSwatchCount(): Int32 {
        if (getAuthStorage().getProfileNameColor() >= 0) {
            return 2
        }
        return 1
    }

    private func yourColorSwatchHex(slot: Int32): UInt32 {
        if (slot == 1) {
            return this.profileSwatchHex(getThemesEngineService().getProfileHeaderColorIndex())
        }
        return this.nameColorHex()
    }

    // Page-local render, not routed through the shared ItemListDisclosureRow primitive: the
    // primitive's label region only has badgeText/value(String) slots (components/
    // ItemListComponents.cj:544-629), no graphic "swatch" slot. Adding one is F-1's job, owned by
    // uif_itemlist_items (currently test_failed, tracked separately, components/
    // ItemListComponents.cj is explicitly out of this feature's allowlist this round). This
    // renders a self-contained row that matches ItemListDisclosureRow's visual language (title /
    // trailing content / chevron, ITEM_LIST_* colour tokens, 44vp row height) so the two rows read
    // as one family until the shared primitive gets its slot and this can be folded back in.
    @Builder
    func buildYourColorSwatch(slot: Int32) {
        Column {}
            .width(22)
            .height(22)
            .borderRadius(11)
            .backgroundColor(this.yourColorSwatchHex(slot))
            .margin(left: if (slot == 0) { 0 } else { -6 })
    }

    // ==================== #7 autoNightTheme right value ====================

    // Source formula (ThemeSettingsController.swift:453-467) maps automaticThemeSwitchSetting's
    // four-value trigger (system/explicitNone/timeBased/brightness) to
    // System/Disabled/Scheduled/Automatic. TC-0403's AutoNightSettingsPage now owns the real
    // trigger model (canonical value domain documented at pages/AutoNightSettingsPage.cj:20-27:
    // 0=Disabled, 1=Scheduled, 3=System, 5=Automatic; legacy 2="Sunset to Sunrise" migrates to 1
    // on that page's first load, but this row can still observe a not-yet-migrated 2 for an
    // account that has never opened that page, so it is mapped the same as 1 here rather than
    // falling through to the default).
    //
    // TC-0403 D1 fix (diag-suite_settings_appearance-TC-0403-round1.md): this is now a pure
    // mapping over this.autoNightMode instead of a hardcoded literal — see that field's doc
    // comment for why the field itself (not just this function) was the actual defect.
    private func autoNightThemeRightValue(): String {
        if (this.autoNightMode == 0) {
            return this.localized("Appearance_AutoNightThemeDisabled", "Disabled")
        }
        if (this.autoNightMode == 1 || this.autoNightMode == 2) {
            return this.localized("AutoNightTheme_Scheduled", "Scheduled")
        }
        if (this.autoNightMode == 5) {
            return this.localized("AutoNightTheme_Automatic", "Automatic")
        }
        // 3 (System) and any other/unreachable value: source's default trigger is .system.
        return this.localized("Appearance_TextSize_Automatic", "System")
    }

    // TC-0403 D1: re-reads the real persisted mode and assigns it to the bare @State field above.
    // Registered once (see ensureLoaded()) against the .ets shell's onShown dispatch, so this runs
    // every time this NavDestination becomes visible again — including the return trip from
    // AutoNightSettingsPage after the user changes the mode there, which is exactly the path the
    // build()-time refresh probe below cannot cover on its own (this NavDestination stays mounted
    // across that push/pop, so nothing else re-triggers its build()).
    private func onAppearanceShown(): Unit {
        this.autoNightMode = getThemesEngineService().getAutoNightMode()
        // S7-106: a theme applied from ThemePreviewPage must show in the carousel selection and
        // the chat preview as soon as this page is visible again (ThemeSettingsController reacts
        // to presentationThemeSettings updates the same way).
        this.themePresetIndex = getThemesEngineService().getThemePreset()
        this.appliedCloudSlug = getAppliedCloudThemeSlug()
        this.selectedChatThemeSlug = getThemesEngineService().getSelectedChatThemeSlug()
        let _ = this.refreshRightValueMirrors()
    }

    // ==================== #6 autoNight toggle ====================

    private func applyAppearanceSystemBars(isDark: Bool): Unit {
        let payload = if (isDark) { "{\"dark\":true}" } else { "{\"dark\":false}" }
        callArkOnJSTask("appearance.systemBars", payload, { _ => () })
    }

    private func setAutoNightEnabled(enabled: Bool): Unit {
        this.autoNightEnabled = enabled
        getThemesEngineService().saveAutoNightEnabled(enabled)
        match (this.selectedCloudTheme()) {
            case Some(item) => this.applyCloudThemeVariant(item, enabled)
            case None => ()
        }
        let _ = recomputePresentation()
        this.applyAppearanceSystemBars(enabled)
        Hilog.info(0, "CjTelegram", "[AppearanceSettings] AutoNight enabled: ${enabled}")
    }

    // ==================== #8 textSize right value ====================

    // Source formula (ThemeSettingsController.swift:470-479): useSystemFont -> "System"; equal
    // sizes -> "<n>pt"; unequal -> "<n>pt / <n>pt". Fully sourceable: PresentationSnapshot already
    // carries useSystemFont/chatFontSize/listsFontSize (TC-0401 F1/F4, core_presentation_data).
    private func textSizeRightValue(): String {
        if (this.presentation.useSystemFont) {
            return this.localized("Appearance_TextSize_Automatic", "System")
        }
        if (this.presentation.chatFontSize == this.presentation.listsFontSize) {
            return "${this.presentation.chatFontSize}pt"
        }
        return "${this.presentation.chatFontSize}pt / ${this.presentation.listsFontSize}pt"
    }

    // D-116 workaround: build() cannot contain a plain assignment statement, only UI-component
    // expressions, so this refresh runs as a zero-height probe (Text(this.refreshRightValueMirrors())
    // at the top of build()) whose return value is consumed by that UI component parameter — the
    // only legal way to execute plain statements once per build() pass.
    private func refreshRightValueMirrors(): String {
        this.autoNightThemeRightValueMirror = this.autoNightThemeRightValue()
        this.textSizeRightValueMirror = this.textSizeRightValue()
        // #0 COLOR THEME section header (D-125, RC-1 of diag-...-TC-0402-round8.md). Unconditional
        // assignment, deliberately placed before the preview-bubble change guard below: the header
        // has nothing to do with the bubble colours and must not be able to influence when that
        // guard flips previewBubbleMountToggle. colorThemeHeaderTitle(triggered:) itself is left
        // untouched — its two literals, em dash included, are the source's own
        // Appearance_ColorThemeNight / Appearance_ColorTheme values.
        this.colorThemeHeaderTitleMirror = this.colorThemeHeaderTitle(this.presentation.autoNightModeTriggered)
        // #6 Night Mode row enabled state (RC-2 of the same report, criteria C1 + C2). The value
        // formula is source parity with ThemeSettingsController.swift:452's 4th argument and is
        // kept verbatim; all that is added is a way for it to reach an already-mounted row.
        // Own change guard, kept separate from the preview-bubble guard below so neither can
        // trigger the other's remount. Termination is the same two-pass shape: pass 1 finds a
        // difference, writes the mirror and flips the toggle, which schedules one more pass;
        // pass 2 finds them equal and neither writes nor flips.
        let nextNightRowEnabled = !this.presentation.autoNightModeTriggered || this.autoNightEnabled
        if (nextNightRowEnabled != this.nightModeRowEnabledMirror) {
            this.nightModeRowEnabledMirror = nextNightRowEnabled
            this.nightModeRowMountToggle = !this.nightModeRowMountToggle
        }
        if (this.carouselIsDark != this.presentation.isDark) {
            this.carouselIsDark = this.presentation.isDark
            this.carouselMountToggle = !this.carouselMountToggle
            this.applyAppearanceSystemBars(this.presentation.isDark)
        }
        // #1 chatPreview child inputs (D-125), refreshed by the same single probe. There must not
        // be a second zero-height probe in this file — this one is it (see the comment above).
        // previewWallpaper() is called exactly once per build() pass here and its fields are fanned
        // out into the flat mirrors; the call site used to invoke it nine times inline, which was
        // both redundant and (per D-125) invisible to the macro's dependency graph anyway.
        let wp = this.previewWallpaper()
        this.previewWpType = wp.wallpaperType
        this.previewWpSolid = wp.solidColor
        this.previewWpGradStart = wp.gradientColorStart
        this.previewWpGradEnd = wp.gradientColorEnd
        this.previewWpGradAngle = wp.gradientAngle
        this.previewWpImageUri = wp.imageUri
        this.previewWpGradColors = wp.gradientColors
        this.previewWpPhase = wp.phase
        this.previewWpPatternFile = wp.patternFile
        this.previewWpPatternOverlay = wp.patternOverlayEnabled
        // TC-0402 round13 F-3.3: patternIntensity mirror, same shape as the two lines above.
        this.previewWpPatternIntensity = wp.patternIntensity
        this.previewIsDark = this.presentation.isDark
        // The four values actually fed to the two MessageBubble instances are written behind a
        // change guard that also flips the D-160 remount toggle, so a bubble rebuild happens on
        // real theme changes only and not on every build() pass (same shape as the precedent,
        // pages/SettingsPage.cj:162-166). previewIsDark and the previewWp* mirrors above are
        // deliberately NOT part of this condition: they feed WallpaperBackgroundComponent, which
        // is not inside the guard (see the mount point for why).
        // Termination: pass 1 sees a difference, writes the mirrors and flips the toggle; those
        // @State writes schedule one more pass; pass 2 finds every value equal, so it neither
        // writes nor flips. Two passes, then stable.
        var newBubbleOut = this.presentation.bubbleOutColor
        var newBubbleIn = this.presentation.bubbleInColor
        match (this.selectedCloudTheme()) {
            case Some(item) =>
                let cloudColors = this.cloudCardColorsForMode(item, this.presentation.isDark)
                newBubbleOut = cloudColors.outgoingBubbleColor
                newBubbleIn = cloudColors.incomingBubbleColor
            case None => ()
        }
        let newBubbleText = this.presentation.textColor
        let newReplyAuthor = this.nameColorHex()
        if (newBubbleOut != this.previewBubbleOutColor || newBubbleIn != this.previewBubbleInColor ||
            newBubbleText != this.previewBubbleTextColor ||
            newReplyAuthor != this.previewReplyAuthorColor) {
            this.previewBubbleOutColor = newBubbleOut
            this.previewBubbleInColor = newBubbleIn
            this.previewBubbleTextColor = newBubbleText
            this.previewReplyAuthorColor = newReplyAuthor
            this.previewBubbleMountToggle = !this.previewBubbleMountToggle
        }
        return ""
    }

    // ==================== #12/#13 App Icon ====================

    private func saveAppIcon(index: Int32): Unit {
        if (this.appIconRequiresPremium(index) && !this.accountIsPremium()) {
            routerPush("PremiumDemoPage", "app_icons")
            return
        }
        this.selectedAppIconIndex = index
        getThemesEngineService().saveAppIconIndex(index)
        Hilog.info(0, "CjTelegram", "[AppearanceSettings] AppIcon saved: index=${index}")
    }

    private func accountIsPremium(): Bool {
        match (getAuthStorage().getUserData()) {
            case Some(user) => return user.isPremium
            case None => return false
        }
    }

    // TC-0400 round3 F-5a (diag-suite_settings_appearance-TC-0400-round3.md RC-E, ❽): full
    // 11-icon grid, source order/naming AppDelegate.swift:952-967 +
    // ThemeSettingsAppIconItem.swift:379-406 + en.lproj/Localizable.strings:4570-4577,7858-7860
    // (source code literal values, not the server-overridden strings the reference frame shows —
    // case G13). Artwork for all 11 now exists: index 0 is the pre-existing startIcon.png
    // (BlueIcon's converted asset); indices 1-10 are this round's F-5b conversions of the
    // remaining Telegram/Telegram-iOS/<Name>.alticon/<Name>@3x.png sources into
    // resources/base/media/appicon_*.png (target_files already lists all ten — see feature
    // hand-off report for the exact source-name -> target-name mapping).
    private func appIconCount(): Int32 {
        return 11
    }

    private func appIconLabel(index: Int32): String {
        if (index == 0) { return this.localized("Appearance_AppIconDefault", "Default") }
        if (index == 1) { return this.localized("Appearance_AppIconNew2", "Aqua") }
        if (index == 2) { return this.localized("Appearance_AppIconNew1", "Sunset") }
        if (index == 3) { return this.localized("Appearance_AppIconDefaultX", "Default X") }
        if (index == 4) { return this.localized("Appearance_AppIconClassic", "Classic") }
        if (index == 5) { return this.localized("Appearance_AppIconClassicX", "Classic X") }
        if (index == 6) { return this.localized("Appearance_AppIconFilled", "Filled") }
        if (index == 7) { return this.localized("Appearance_AppIconFilledX", "Filled X") }
        if (index == 8) { return this.localized("Appearance_AppIconPremium", "Premium") }
        if (index == 9) { return this.localized("Appearance_AppIconTurbo", "Turbo") }
        return this.localized("Appearance_AppIconBlack", "Black")
    }

    // Source: ThemeSettingsAppIconItem.swift:406 `locked: !item.isPremium && icon.isPremium`.
    // This target has no premium-account state reachable from this file's allowlist, so
    // `isPremium` is treated as permanently false — the lock badge renders for these three
    // regardless of account, matching the reference frame (all three visibly locked there too).
    private func appIconRequiresPremium(index: Int32): Bool {
        return index == 8 || index == 9 || index == 10
    }

    // D-133: `@r()` has no verified value-level-if-expression precedent, so the per-index
    // artwork pick is a component-level if/else chain (11 full Image(...) branches) rather than
    // `Image(if (...) { @r(...) } else { @r(...) })`.
    @Builder
    func buildAppIconCell(index: Int32) {
        if (index >= this.appIconCount()) {
            // Grid slot for an icon whose artwork has not landed yet (defensive: appIconCount()
            // is 11 today, but the four-column row layout below always emits cells 0..10, so this
            // keeps the grid non-jagged if that ever changes without also editing the row layout).
            Column {}
                .width(60)
                .margin(top: 6)
        } else {
            Column {
                Stack {
                    if (index == 0) {
                        Image(@r(app.media.startIcon))
                            .width(60)
                            .height(60)
                            .borderRadius(14)
                            .clip(true)
                    } else if (index == 1) {
                        Image(@r(app.media.appicon_aqua))
                            .width(60)
                            .height(60)
                            .borderRadius(14)
                            .clip(true)
                    } else if (index == 2) {
                        Image(@r(app.media.appicon_sunset))
                            .width(60)
                            .height(60)
                            .borderRadius(14)
                            .clip(true)
                    } else if (index == 3) {
                        Image(@r(app.media.appicon_default_x))
                            .width(60)
                            .height(60)
                            .borderRadius(14)
                            .clip(true)
                    } else if (index == 4) {
                        Image(@r(app.media.appicon_classic))
                            .width(60)
                            .height(60)
                            .borderRadius(14)
                            .clip(true)
                    } else if (index == 5) {
                        Image(@r(app.media.appicon_classic_x))
                            .width(60)
                            .height(60)
                            .borderRadius(14)
                            .clip(true)
                    } else if (index == 6) {
                        Image(@r(app.media.appicon_filled))
                            .width(60)
                            .height(60)
                            .borderRadius(14)
                            .clip(true)
                    } else if (index == 7) {
                        Image(@r(app.media.appicon_filled_x))
                            .width(60)
                            .height(60)
                            .borderRadius(14)
                            .clip(true)
                    } else if (index == 8) {
                        Image(@r(app.media.appicon_premium))
                            .width(60)
                            .height(60)
                            .borderRadius(14)
                            .clip(true)
                    } else if (index == 9) {
                        Image(@r(app.media.appicon_turbo))
                            .width(60)
                            .height(60)
                            .borderRadius(14)
                            .clip(true)
                    } else {
                        Image(@r(app.media.appicon_black))
                            .width(60)
                            .height(60)
                            .borderRadius(14)
                            .clip(true)
                    }

                    // F-3/RC-B fix applied here too: radius folded into the same .border() call
                    // instead of a preceding standalone .borderRadius(), which border(radius
                    // default) would otherwise clear back to 0 (common_component.cj:1075-1090).
                    if (this.selectedAppIconIndex == index) {
                        Column {}
                            .width(60)
                            .height(60)
                            .border(width: 3, color: this.presentation.accentColor, radius: 14)
                    } else {
                        // Source: ThemeSettingsAppIconItem.swift generateBorderImage's `bordered`
                        // branch draws a 40%-opacity outline on unselected icons too.
                        Column {}
                            .width(60)
                            .height(60)
                            .border(width: 1, color: ITEM_LIST_CHEVRON, radius: 14)
                            .opacity(0.4)
                    }

                    // Source: ThemeSettingsAppIconItem.swift:12-35 generateBorderImage /
                    // :187 lockNode.frame = (bounds.width - 24, 4, ...) — purple circular badge,
                    // top-right of the icon, over a lock glyph reused from the existing premium
                    // lock icon (components/ItemListComponents.cj:490 precedent).
                    if (this.appIconRequiresPremium(index) && !this.accountIsPremium()) {
                        Stack {
                            Column {}
                                .width(16)
                                .height(16)
                                .borderRadius(8)
                                .backgroundColor(0x9B63DC)
                            Image(@r(app.media.misc_ic_premiumlock))
                                .width(9)
                                .height(9)
                                .fillColor(0xFFFFFF)
                        }
                        .width(16)
                        .height(16)
                        .position(x: 40, y: 4)
                    }
                }
                .width(60)
                .height(60)
                // Source :406: selected -> itemAccentColor + Font.medium(12.0); unselected ->
                // itemPrimaryTextColor (this row's own primary text colour, not the dimmer
                // secondary tone the single-cell version used for both states).
                Text(this.appIconLabel(index))
                    .fontSize(12)
                    .fontWeight(if (this.selectedAppIconIndex == index) { FontWeight.Medium } else { FontWeight.Regular })
                    .fontColor(if (this.selectedAppIconIndex == index) { this.presentation.accentColor } else { this.presentation.textColor })
                    .margin(top: 6)
            }
            .alignItems(HorizontalAlign.Center)
            .onClick({ evt => this.saveAppIcon(index) })
        }
    }

    // ==================== #16 showNextMediaOnTap ====================
    private func loadShowNextMediaOnTap(): Bool {
        return getThemesEngineService().getShowNextMediaOnTap()
    }

    private func saveShowNextMediaOnTap(enabled: Bool): Unit {
        this.showNextMediaOnTap = enabled
        getThemesEngineService().saveShowNextMediaOnTap(enabled)
    }

    // ==================== Lifecycle ====================

    // F-P1（diag-suite_settings_appearance-TC-0401-round5.md RC-P1，blocking，single-item fix）:
    // :992's `enabled: !this.presentation.autoNightModeTriggered || this.autoNightEnabled`
    // reads this.autoNightEnabled as its second operand, but that field's real value was only
    // ever loaded in loadSettings() (called from ensureLoaded(), triggered by .onAppear below) —
    // which necessarily runs *after* the first build(). On that one and only evaluation that
    // freezes into ItemListToggleRow's undecorated `enabled` field (D-156: assigned once at
    // first construction, never re-applied), this.autoNightEnabled was still its compile-time
    // default `false`. Once uif_tabbarui's cold-start themes-engine construction
    // (MainTabPage.cj:223) made autoNightModeTriggered true on cold start, that first-build
    // evaluation became `!true || false` = `false` and stayed frozen there forever — the row's
    // isOn (a @Prop, which *does* re-apply) later flips to true via loadSettings(), so the
    // switch renders ON while permanently unclickable, with no in-app recovery path.
    // Fix: synchronously read the same persisted value one step earlier, in aboutToAppear()
    // (runs before the first build()), so the frozen `enabled` field's one live evaluation
    // already has the true value. getAutoNightEnabled() is a synchronous Preferences read (no
    // spawn/launch/async in loadSettings()'s body), so this is safe to call from aboutToAppear().
    // Existing precedent for this exact pattern, same reason, same kind of undecorated field:
    // pages/ArchiveSettingsPage.cj:82-88 (isPremium moved from ensureLoaded() to aboutToAppear()
    // for the same "must be true before first build()" reason).
    // Do NOT remove the assignment in loadSettings() below — it still needs to cover the
    // "returned from a sub-screen" re-entry path; this is an addition, not a move. Do NOT touch
    // :992's expression or :52's declaration — both are already correct.
    public override func aboutToAppear(): Unit {
        this.autoNightEnabled = getThemesEngineService().getAutoNightEnabled()
    }

    // 混合工程迁移（recipe §12 Phase 4）：aboutToAppear 实逻辑 → ensureLoaded()（.onAppear 触发，一次性守卫）
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // TC-0403 D1: one-time subscription registration (D6 "生命周期按需通信" pattern, same
        // precedent as auth/PhoneInputPage.cj:165) — the `loaded` guard above ensures this only
        // registers once, so this handler never accumulates duplicate subscriptions across
        // repeated .onAppear triggers.
        subscribe(this.appearanceShownEvent, { _payload: String => this.onAppearanceShown() })
        this.loadSettings()
        this.loadChatThemes()
    }

    // TC-0400 round12 F-C 第 1 条：形态逐字照搬 pages/ChatThemesPage.cj:loadChatThemes()
    // 的 spawn+launch 范式（同一个 getThemesEngineService().getChatThemes(0) 调用，独立状态）。
    private func loadChatThemes(): Unit {
        spawn {
            let result = getThemesEngineService().getChatThemes(0)
            let items = result.themes.toArray()
            launch {
                this.chatThemeItems = items
                for (item in items) {
                    if (item.slug == this.selectedChatThemeSlug) {
                        this.persistCloudThemeWallpapers(item)
                    }
                }
            }
        }
    }

    // F-C 第 2 条过滤：轮播只吃带 emoticon 的云主题（对位 ThemeSettingsController.swift:1148-1150
    // chatThemes = cloudThemes.filter{emoticon != nil}）。提出成独立函数而不是内联 let——build()/
    // @Builder 体内禁止 let（S-005），ForEach 的数据源表达式不能自己带 let。
    private func filteredChatThemeItems(): Array<ThemeItem> {
        let result = ArrayList<ThemeItem>()
        for (item in this.chatThemeItems) {
            if (item.emoticon != "") {
                result.add(item)
            }
        }
        return result.toArray()
    }

    @Builder
    func buildAppearanceThemeCarouselItems() {
        this.buildCarouselCard(0)
        ForEach(this.filteredChatThemeItems(), itemGenerator: { item: ThemeItem, _idx: Int64 =>
            this.buildCloudCarouselCard(item)
        })
    }

    /**
     * Loads every @State selector this page owns from its true persisted source. Dead-state
     * prevention: fields reflect persisted values, not hardcoded defaults.
     *
     * getThemesEngineService() below is this page's construction site for the themes-engine
     * singleton (hazard carried over unchanged from the previous version, still at this same
     * call site): first construction registers this feature's PresentationExtras provider and
     * starts the auto-night evaluator timer (core/storage/AppTheme.cj's
     * registerPresentationExtrasProvider doc). A session that never opens this screen still has
     * no other reachable call path to it (documented gap, tracked by this feature's emitted
     * ic_themes_engine_cold_start_bootstrap contract, not something this Worker's allowlist can
     * fix at the call-site end). This call must not be removed as incidental cleanup.
     */
    private func loadSettings(): Unit {
        let svc = getThemesEngineService()
        this.themePresetIndex = svc.getThemePreset()
        this.appliedCloudSlug = getAppliedCloudThemeSlug()
        this.selectedChatThemeSlug = svc.getSelectedChatThemeSlug()
        this.autoNightEnabled = svc.getAutoNightEnabled()
        // TC-0403 D1: real persisted mode, assignment site 1 of 2 (site 2 is
        // onAppearanceShown(), triggered by the .ets shell's onShown dispatch on return).
        this.autoNightMode = svc.getAutoNightMode()
        this.selectedAppIconIndex = svc.getAppIconIndex()
        this.showNextMediaOnTap = this.loadShowNextMediaOnTap()
        this.applyAppearanceSystemBars(this.presentation.isDark)

        Hilog.info(0, "CjTelegram", "[AppearanceSettings] Loaded: theme=${this.presentation.theme} preset=${this.themePresetIndex} autoNight=${this.autoNightEnabled} autoNightMode=${this.autoNightMode} appIcon=${this.selectedAppIconIndex}")
    }

    // MessageBubble is the renderer; it never reads the theme itself (its own :177-183 comment
    // fixes that invariant, mirroring source ThemeSettingsChatPreviewItem.swift:172 passing
    // `theme:` in). This file is the caller that feeds it. All six theme inputs are bare
    // this.<@State mirror> references or literals per D-125. The snapshot exposes no separate
    // incoming/outgoing body-text dimension, so both text slots share previewBubbleTextColor, as
    // the component's own comment agrees. bubbleOutAccentTextColor keeps the component's
    // day-classic default 0x00A700: the snapshot has no bubble-scoped outgoing accentTextColor to
    // source it from, so passing the literal is pixel-identical to not passing it.
    // Extracted into no-arg @Builder functions so the two identical if/else branches at the mount
    // point below do not have to keep two copies of these argument lists in sync (D-160 step ①).
    @Builder
    func buildPreviewIncomingBubble() {
        MessageBubble(
            message: this.previewIncomingMessage(),
            voicePlaybackEpoch: 0,
            bubbleOutColor: this.previewBubbleOutColor,
            bubbleInColor: this.previewBubbleInColor,
            bubbleOutTextColor: this.previewBubbleTextColor,
            bubbleInTextColor: this.previewBubbleTextColor,
            replyAuthorAccentColor: this.previewReplyAuthorColor,
            bubbleOutAccentTextColor: 0x00A700
        )
    }

    // D-160 step 1: the remounted subtree lives in its own no-arg @Builder so the two identical
    // branches at the mount point do not each carry a copy of the argument list. Only `enabled:`
    // changes relative to the previous inline call — it now reads the bare @State mirror instead
    // of recomputing `!this.presentation.autoNightModeTriggered || this.autoNightEnabled` inline.
    // The formula itself moved to refreshRightValueMirrors() unchanged; it is source parity with
    // ThemeSettingsController.swift:452's 4th argument and was never the defect. isOn and onChange
    // are untouched: isOn is a bare @State against a @Prop field and is measured correct, and
    // onChange writes `force` exactly as the source's :584-590 does.
    // Scope note: this closes "can the disabled state be entered at all", which is what C1 and C2
    // assert. It does not attempt the source's 60% disabled overlay — ItemListToggleRow already
    // greys its own title from `enabled` (components/ItemListComponents.cj:476-481), and matching
    // the overlay pixel-for-pixel is a separate item on a component outside this allowlist.
    @Builder
    func buildNightModeToggleRow() {
        ItemListToggleRow(
            title: this.localized("Appearance_NightTheme", "Night Mode"),
            isOn: this.autoNightEnabled,
            onChange: { isOn: Bool => this.setAutoNightEnabled(isOn) },
            enabled: this.nightModeRowEnabledMirror
        )
    }

    @Builder
    func buildPreviewOutgoingBubble() {
        MessageBubble(
            message: this.previewOutgoingMessage(),
            voicePlaybackEpoch: 0,
            bubbleOutColor: this.previewBubbleOutColor,
            bubbleInColor: this.previewBubbleInColor,
            bubbleOutTextColor: this.previewBubbleTextColor,
            bubbleInTextColor: this.previewBubbleTextColor,
            replyAuthorAccentColor: this.previewReplyAuthorColor,
            bubbleOutAccentTextColor: 0x00A700
        )
    }

    public func build() {
        Column {
            // D-125 refresh probe: zero-height, invisible, runs refreshRightValueMirrors() once
            // per build() pass so the two ItemListDisclosureRow(value:) call sites and the #1
            // chatPreview block's three child call sites (WallpaperBackgroundComponent + two
            // MessageBubble) below always read this build()'s current this.presentation-derived
            // values via their mirrors. This is the file's only such probe and must stay the only
            // one — new mirrored values are added inside refreshRightValueMirrors(), never by
            // adding a second probe.
            Text(this.refreshRightValueMirrors()).height(0).fontSize(0)

            // Navigation bar. F6: real back-chevron artwork + "Back" label, replacing the U+2190
            // glyph that previously stood in for a navigation icon.
            Row {
                Row {
                    Image(@r(app.media.callui_v2_back))
                        .width(10)
                        .height(18)
                        .fillColor(this.presentation.accentColor)
                }
                .width(44)
                .height(44)
                .borderRadius(22)
                .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
                .onClick({ evt => routerPop() })
                Blank().layoutWeight(1)
                Text(this.localized("Appearance_Title", "Appearance"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Row {}.width(60)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            // F-1 (diag-suite_settings_appearance-TC-0400-round4.md, RC-A-1): this screen's
            // nav bar is a glass bar (ItemListController.swift:286) that paints no opaque fill
            // of its own — it shows through to the screen's own backgroundColor, not the shared
            // navBarColor token (that token is for screens with an opaque bar, e.g.
            // ChatListPage.cj). Deliberately not changed on core/storage/AppTheme.cj's navBarColor
            // itself: another consumer (ChatListPage.cj) needs it to stay a solid different tone,
            // and dark-mode has navBarColor == backgroundColor already so this is a zero-visual-
            // change edit there.
            .backgroundColor(this.presentation.backgroundColor)
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {

                    // ========= #0 COLOR THEME =========
                    // TC-0400-round9 F-1 (diag-suite_settings_appearance-TC-0400-round9.md N-1):
                    // the Light/Dark/System card that used to sit here was deleted. Source
                    // (ThemeSettingsController.swift:420-437) appends .chatPreview immediately
                    // after .themeListHeader with no entry in between; this target now matches
                    // that shape. The prior comment on this spot claimed the deleted block was
                    // "the only UI call site anywhere in the target tree for
                    // AuthStorage.saveAppearanceTheme()" — that was false even at the time it was
                    // written: applyThemePreset() (:379-398, called from the carousel below) has
                    // always called this.saveTheme(1)/this.saveTheme(0) at :390/:394, and
                    // ChatThemesPage.cj:516/:521 has always called
                    // getAuthStorage().saveAppearanceTheme(1/0) directly. Both remain the manual
                    // light/dark write paths (source's `themeReference` selection equivalent).
                    // The deleted card's "System" state (theme==2) had no source counterpart and
                    // duplicated the already-implemented Auto-Night "follow system" path
                    // (core/storage/AppTheme.cj:612-631 computeSnapshot()'s themeVal==2 branch,
                    // reachable via the Auto-Night Theme row / AutoNightSettingsPage.cj mode==3);
                    // that computeSnapshot() branch is left untouched so devices that already
                    // persisted theme==2 keep following the system appearance.
                    ItemListSectionHeader(title: this.colorThemeHeaderTitleMirror, topPad: 16)

                    // ========= #1 chatPreview / #2 themes carousel / #3 chatTheme / #4 wallpaper / #5 nameColor =========
                    // TC-0400 round3 F-2 (diag-suite_settings_appearance-TC-0400-round3.md RC-A-1,
                    // ❷): source groups the chat preview, the themes carousel and the Chat
                    // Themes/Chat Background/Your Color rows under ONE continuous ItemList card
                    // (ThemeSettingsChatPreviewItem.swift:211 itemListNeighborsGroupedInsets;
                    // ThemeSettingsController.swift:438 groups all five under the same section).
                    // They previously stood as three separate "island" cards, each drawing its own
                    // backgroundColor/borderRadius — that is also why the preview block's top
                    // corners rendered square: its own .borderRadius/.clip sat on a padding box
                    // wider than the visible wallpaper content, so the rounding landed off-screen.
                    // This single outer Column now owns the card chrome (background/radius/clip/
                    // inset); the inset amount itself is unchanged (still 16 each side, ≈0.915 of
                    // screen width — matches source ≈0.93, do not widen it further), it has simply
                    // moved from each inner segment's own padding/margin to this one wrapper's
                    // .margin(). No separator between preview and carousel (source has none there).
                    Column {
                        // F-1 (RC-A-2, ❸/❹): preview bubbles now walk the real message-bubble
                        // renderer (components/MessageBubble.cj) instead of a hand-rolled
                        // Column/Text pair, so tail + timestamp + read double-check all come from
                        // the one real pipeline that component already implements, instead of
                        // being separately re-approximated here. MessageBubble is not in this
                        // feature's allowlist — called, not modified; message field values are the
                        // ChatPreviewMessageItem fixtures (see previewIncomingMessage/
                        // previewOutgoingMessage doc above previewWallpaper()).
                        Stack {
                            // D-125: every argument below is a bare this.<@State field>, refreshed
                            // once per build() pass by the single zero-height probe at the top of
                            // build(). fallbackColor is the one exception and is left as the direct
                            // service call on purpose: getFallbackColor() returns a constant that
                            // does not vary with the theme, so it carries no update to deliver.
                            WallpaperBackgroundComponent(
                                wallpaperType: this.previewWpType,
                                solidColor: this.previewWpSolid,
                                gradientColorStart: this.previewWpGradStart,
                                gradientColorEnd: this.previewWpGradEnd,
                                gradientAngle: this.previewWpGradAngle,
                                imageUri: this.previewWpImageUri,
                                fallbackColor: getWallpaperBackgroundService().getFallbackColor(),
                                gradientColors: this.previewWpGradColors,
                                phase: this.previewWpPhase,
                                isDarkMode: this.previewIsDark,
                                patternFile: this.previewWpPatternFile,
                                patternOverlayEnabled: this.previewWpPatternOverlay,
                                patternIntensity: this.previewWpPatternIntensity
                            )
                            Column {
                                // D-160/D-184 双相同分支挂载守卫。两个分支逐字相同，唯一的作用是
                                // 它们在源码里位于 if 与 else 两个不同位置：宏按出现顺序分配
                                // branchId（state_macro_manage/cj_component_define.cj:1094-1122，
                                // if 体拿 0、else 体拿 1），而 custom_view.cj:790-799 的
                                // ifElseBranchUpdateFunction 在 branchId 与当前值相同时直接
                                // return（"IfElse branch unchanged, no work to do"），只有 branchId
                                // 变化才会执行分支体、重新构造子组件。previewBubbleMountToggle 在
                                // 探针里随主题色真实变化翻转，于是每次换肤都强制销毁重建这两个
                                // 气泡，新实例的 @State init 复制到当前镜像值。
                                // WallpaperBackgroundComponent 故意留在守卫之外：它的入参同样无法
                                // 回灌，但它自带 canvas 渐变动画与 phase 状态，销毁重建会重启动画
                                // （D-160 边界条件 ②），而壁纸随主题变这一半的规格与归属本轮均未
                                // 确定，不在本轮取证面内 —— 该机制缺口改为按 7b emit 契约交给
                                // 该组件的 owner，不在这里顺手改变它的渲染行为。
                                if (this.previewBubbleMountToggle) {
                                    this.buildPreviewIncomingBubble()
                                    this.buildPreviewOutgoingBubble()
                                } else {
                                    this.buildPreviewIncomingBubble()
                                    this.buildPreviewOutgoingBubble()
                                }
                            }
                            .width(100.percent)
                            // F-2 (diag-suite_settings_appearance-TC-0400-round4.md): fixed
                            // .height(180) + bottom-anchoring replaced by intrinsic content-driven
                            // padding — source's block height is derived purely from
                            // ThemeSettingsChatPreviewItem.swift:211's `4.0 + 4.0` insets around
                            // the message nodes, not a hardcoded container height, and the extra
                            // slack this fixed height introduced was standing in for #7 (the
                            // now-removed spurious author-name row) and #14b (the not-yet-fixed
                            // timestamp row), not a real content requirement of its own.
                            .padding(top: 4, bottom: 4)
                            // RC-1 / F-1 of diag-suite_settings_appearance-TC-0400-round7.md.
                            // Measure the *content* and hand its height to the Stack below, so the
                            // block is sized by what is in it — source's
                            // ThemeSettingsChatPreviewItem.swift:211-215 accumulates the message
                            // node heights into contentSize and derives the block from that. The
                            // measurement source has to be this Column and not the Stack: the
                            // Stack's height is the thing being computed, and reading it back
                            // would close a loop on itself. Same shape as the in-repo precedent
                            // components/MessageBubble.cj:3060-3063 (content Column's onAreaChange
                            // writes a bare @State that a sibling node then consumes as a size).
                            // Area.height is a Length; .value is its Float64 vp magnitude.
                            // 0.5vp deadband before writing, matching
                            // pages/TwoFactorCreatePasswordPage.cj:677-686: the write feeds a
                            // @State that decides the parent of the very node being measured, so
                            // sub-pixel jitter must not be able to schedule layout passes forever.
                            // The fixed point itself is unconditionally stable — this Column is
                            // content-sized and does not consult its parent's height — so the
                            // deadband only rules out float noise, it does not create the
                            // convergence.
                            .onAreaChange({ _: Area, newArea: Area =>
                                let h = newArea.height.value
                                if (h > this.previewContentHeight + 0.5 || h < this.previewContentHeight - 0.5) {
                                    this.previewContentHeight = h
                                }
                            })
                        }
                        // F-1 (diag-suite_settings_appearance-TC-0400-round7.md): the block's one
                        // and only height declaration, and it is a measurement, not a constant.
                        // Without it this Stack has no determinate height, WallpaperBackgroundComponent's
                        // .height(100.percent) resolves against the enclosing Scroll's viewport
                        // instead of against the content, and the wallpaper — the only child that
                        // declares a height — becomes the thing that sizes the container: measured
                        // 2230px against 708px of content, with the content centred and 775px of
                        // bare wallpaper above and below it. With a determinate parent the same
                        // 100.percent resolves to "as tall as the content", which is the source's
                        // direction (:294 frames the background node to the already-computed size).
                        // Deliberately not a magic number: round4's F-2 removed a fixed
                        // .height(180) here precisely because the source derives this from content,
                        // and putting a constant back would just freeze the block at a different
                        // wrong height. Nothing else on this Stack changes — no width, no clip, no
                        // borderRadius, no margin, and not alignContent either: once the height
                        // equals the content height, Center and Top are visually the same, and
                        // moving the alignment would displace the wallpaper for no measured reason.
                        .height(this.previewContentHeight)
                        // F-2: no own width/clip/borderRadius/padding/margin any more — the merged
                        // card's own .clip(true) below crops this (the card's first child) into
                        // "top corners round, bottom square", which is the source shape. The
                        // WallpaperBackgroundComponent above carries its own .width(100.percent)
                        // (components/WallpaperBackgroundComponent.cj), so this Stack still fills
                        // the card's resolved width without declaring one itself — same
                        // no-width-on-container/width-on-children pattern already used by every
                        // other grouped card in this file.
                        // F-2 (round4) dropped this Stack's own fixed .height(180), which was the
                        // right call — but the expectation recorded here at the time, that
                        // WallpaperBackgroundComponent's .height(100.percent) would "stretch to
                        // match" the content, had the dependency backwards, and with no height at
                        // either level the percentage resolved against the scroll viewport instead.
                        // Corrected above: the height is declared here again, but as the measured
                        // content height rather than a constant, and the wallpaper now stretches to
                        // match it for real.

                        // ========= #2 themes carousel =========
                        // TC-0400 RC-2 items 2/3/4/5 (diag-suite_settings_appearance-TC-0400-round2.md
                        // F-5): replaced the one-page-at-a-time Swiper with a horizontally scrolling
                        // multi-card row (source: ThemeCarouselItem.swift:704, a horizontal ListView
                        // with same-screen multiple cards visible, contentSize 120x90). Selecting a
                        // theme now happens only via each card's own onClick — there is no
                        // scroll-position-driven side effect, so browsing the carousel can no longer
                        // change the persisted theme by itself (source: ThemeCarouselThemeIconItem
                        // .selected(listView:) only fires on click, not on scroll). Each card's border
                        // now carries the same radius as the card body (F-3 fix, folded into the
                        // same .border() call — see buildCarouselCard) so the selection outline is a
                        // rounded rect, not a right-angle box (source: cornerCurve = .continuous).
                        // Bubble shapes are kept, the sample "Hello!"/"How are you?" copy is
                        // dropped (source's themeIconImage draws a wallpaper-thumbnail card background
                        // behind the bubble shapes, no text). The wallpaper-thumbnail background itself
                        // is NOT drawn here — resource_catalog.json has no per-preset wallpaper
                        // thumbnail media (only settings_ic_wallpaper, an unrelated icon) and this
                        // file's allowlist cannot originate new resource conversions; disclosed as a
                        // known limitation rather than approximated with a fabricated asset. RC-C's
                        // full fix (a themed image + emoticon pipeline) needs a new data API on
                        // core/storage/AppTheme.cj, which is core_presentation_data's file, not this
                        // feature's allowlist — tracked separately, not attempted here (see hand-off
                        // report). The per-preset name label below the card is also dropped (source
                        // has no card-caption text; the name lives only in the accessibility string).
                        // F-2: dropped own borderRadius/margin(left,right) — the merged card's own
                        // chrome now covers both; kept own backgroundColor/width/margin(top) as an
                        // internal segment, and kept .width(100.percent) so Scroll still has a
                        // resolved width to scroll horizontally within.
                        // Source keeps the same dayClassic + cloud-theme identities when Night
                        // Mode changes; only each card's light/dark rendering variant changes.
                        // The mount guard forces the Canvas-backed thumbnails to be reconstructed
                        // when that variant changes.
                        Scroll {
                            Row {
                                if (this.carouselMountToggle) {
                                    this.buildAppearanceThemeCarouselItems()
                                } else {
                                    this.buildAppearanceThemeCarouselItems()
                                }
                            }
                            // round12 F-B B-2 item 6: top/bottom padding narrowed from 12/12 to
                            // 11/2 — the 82x108 thumbnail (with its own 6vp top offset baked in,
                            // see buildCarouselCard()'s inner Stack) needs less top padding on this
                            // Row to land the carousel band height at 133 (see this Scroll's own
                            // .height below), matching the reference AX gap between the preview
                            // block's bottom and the `Chat Themes` row's top.
                            .padding(left: 12, right: 12, top: 11, bottom: 2)
                        }
                        .scrollable(ScrollDirection.Horizontal)
                        // F-4 (diag-suite_settings_appearance-TC-0400-round4.md, ⑩前半): source's
                        // horizontal ListView (ThemeCarouselItem.swift:704) has no visible
                        // scrollbar track; only this one attribute changes, sizing/background/
                        // margin below are untouched.
                        .scrollBar(BarState.Off)
                        .width(100.percent)
                        // round12 F-B B-2 item 5: 114 -> 133 = 11.3 + 120 + 2 (reference AX: preview
                        // block bottom 305pt, card container 316.33-436.33pt, `Chat Themes` row top
                        // 438.33pt) — the carousel band now has enough height for the full 120vp
                        // card container plus the narrowed 11/2 padding above.
                        .height(133)
                        .backgroundColor(this.presentation.cardColor)
                        // TC-0400 round10 R-2: the source gap between the preview block's bottom
                        // and this carousel's top is already expressed by this Scroll's own
                        // .padding(top:) above (round12 F-B narrowed it to 11, see above) — an
                        // extra margin here was pure surplus (diag round10 §「真实偏差」), still
                        // true after round12's repaint.
                        .margin(top: 0)

                        // ========= #3 chatTheme / #4 wallpaper / #5 nameColor =========
                        // F1 boundary condition: the deleted ACCENT COLOR palette rides #3 (its real
                        // destination is the Chat Themes sub-screen in source, ThemePickerController)
                        // and the deleted PROFILE COLOR picker rides #5 (its real destination is
                        // UserAppearanceScreen) — converted to disclosure rows rather than dropped.
                        // #4's destination, WallpaperPickerPage, already exists and already owns full
                        // wallpaper-selection state independently, so the inline preset/cloud-gallery
                        // UI that used to live on this page is genuinely redundant now, not a
                        // capability loss.
                        // F-2: dropped own borderRadius/margin(left,right) — merged card's chrome
                        // covers both; kept own backgroundColor and margin(top) as an internal
                        // segment.
                        Column {
                            ItemListDisclosureRow(
                                title: this.localized("Settings_ChatThemes", "Chat Themes"),
                                value: "",
                                onClick: { => routerPush("ChatThemesPage", "") }
                            )
                            ItemListSeparator()
                            ItemListDisclosureRow(
                                title: this.localized("Settings_ChatBackground", "Chat Wallpaper"),
                                value: "",
                                onClick: { => routerPush("WallpaperPickerPage", "") }
                            )
                            ItemListSeparator()
                            // TC-0404 F4 fix: UserAppearanceScreen is NOT a regression — this
                            // capability is already implemented, registered, and reachable as
                            // pages/ProfileColorPage.cj (via EditProfilePage.cj:584 Edit Profile ->
                            // Your Color). Source's ThemeSettingsController.swift:579 and Edit
                            // Profile both push the same UserAppearanceScreen; this row previously
                            // pointed at a dead route name with no destination ever built. Repointing
                            // it at the existing page restores source's second (Appearance-side)
                            // entry point without duplicating ProfileColorPage's already-working
                            // read/write logic.
                            // TC-0400 RC-1: hand-rolled row (see buildYourColorSwatch doc above for
                            // why this does not call ItemListDisclosureRow here).
                            // TC-0401 round6 RC-A: this title was the one row in this card still
                            // rendering near-black on a dark card. Its siblings go through
                            // ItemListDisclosureRow, which holds its own @StorageLink["presentation"]
                            // (components/ItemListComponents.cj:664) and paints its title with
                            // this.presentation.textColor (:770) — that is the whole reason only this
                            // hand-rolled row stayed dark. Reading the snapshot inline here is the
                            // same shape the rest of this file already uses (the enclosing card's own
                            // .backgroundColor(this.presentation.cardColor) a few lines below is one
                            // of 20+): D-125 constrains arguments handed to child components, not a
                            // component painting its own elements from a field its build() reads.
                            Row {
                                Text(this.localized("Settings_YourColor", "Your Color"))
                                    .fontSize(17)
                                    .fontColor(this.presentation.textColor)
                                    .layoutWeight(1)
                                Row {
                                    this.buildYourColorSwatch(0)
                                    if (this.yourColorSwatchCount() > 1) {
                                        this.buildYourColorSwatch(1)
                                    }
                                }
                                .margin(right: 6)
                                // TC-0400-round9 F-2 (diag-suite_settings_appearance-TC-0400-round9.md
                                // N-4): was Text("›") glyph. Matches the other 8 disclosure rows on
                                // this screen, which go through ItemListDisclosureRow
                                // (components/ItemListComponents.cj:789/864): same resource, same
                                // 7x12 size, same live-theme fillColor (this.presentation is already
                                // read a few lines above in this same hand-rolled row).
                                Image(@r(app.media.item_list_disclosure_arrow))
                                    .width(7)
                                    .height(12)
                                    .fillColor(this.presentation.disclosureArrowColor)
                            }
                            .width(100.percent)
                            .height(44)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ evt => routerPush("ProfileColorPage", "") })
                        }
                        .backgroundColor(this.presentation.cardColor)
                        // TC-0400 round10 R-2: source gap between the carousel's bottom and this
                        // "Chat Themes" row's top is only 2pt — an extra 24vp margin here was
                        // surplus (diag round10 §「真实偏差」), same reasoning as the carousel's
                        // own margin fix above.
                        .margin(top: 0)
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(12)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24)

                    // ========= #6 autoNight / #7 autoNightTheme =========
                    Column {
                        // TC-0402 RC-C fix: source parity ThemeSettingsController.swift:452, 4th
                        // arg `!autoNightModeTriggered || force`. Fix (diag-suite_settings_appearance-
                        // TC-0401-round4.md, "附带发现"): the previous comment here claimed this
                        // target has no reachable path that ever produces `force=true` and dropped
                        // the `|| force` term — that premise was wrong on this target. Here `force`
                        // is this Night Mode switch itself: services/ThemesEngineService.cj:1356
                        // `let force = this.getAutoNightEnabled()` (reads the same persisted
                        // auto_night_enabled this row writes via setAutoNightEnabled below), and
                        // :1357-1361 `autoNightTriggered = if (force) { true } else { eval(trigger) }`.
                        // Dropping `|| force` meant that once the user switched this ON,
                        // `autoNightModeTriggered` becomes true and the row disables itself on the
                        // next mount — the switch that turns auto-night on is not supposed to also
                        // be the thing that locks itself out. `this.autoNightEnabled` is the bare
                        // @State mirror of that same persisted value (loaded in loadSettings(),
                        // written in setAutoNightEnabled()), so it is available without an extra
                        // service call. That formula now lives in refreshRightValueMirrors() and
                        // reaches this row through nightModeRowEnabledMirror; it is unchanged, only
                        // relocated — see the remount-guard note directly below for why.
                        // RC-2 / F-2 of diag-suite_settings_appearance-TC-0402-round8.md (criteria
                        // C1 + C2). D-160 double-identical-branch remount guard: the two branches
                        // are byte-for-byte the same call, and the only thing that distinguishes
                        // them is that they sit at two different source positions, so the macro
                        // assigns them different branchIds. Flipping nightModeRowMountToggle
                        // therefore changes which branchId is live, which is what makes the
                        // framework tear the row down and construct a new one — and a new
                        // construction is the only moment an undecorated `enabled` field is ever
                        // assigned. Note the guard works because an *unchanged* branch does not run
                        // its body at all (ifElseBranchUpdateFunction returns early on an unchanged
                        // branchId); a re-run of the same branch would not help here anyway, since
                        // it would reuse the existing child instance rather than re-init it.
                        // Safe to rely on a real destroy/rebuild here: ItemListToggleRow is not
                        // @Reusable (components/MessageBubble.cj:83 is the only @Reusable UI
                        // component in the tree), so there is no reuse cache to hand back a stale
                        // instance and no canvas-context lifetime to strand.
                        if (this.nightModeRowMountToggle) {
                            this.buildNightModeToggleRow()
                        } else {
                            this.buildNightModeToggleRow()
                        }
                        ItemListSeparator()
                        ItemListDisclosureRow(
                            title: this.localized("Appearance_AutoNightTheme", "Auto-Night Theme"),
                            value: this.autoNightThemeRightValueMirror,
                            onClick: { => routerPush("AutoNightSettingsPage", "") }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(12)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24)

                    // ========= #8 textSize / #9 bubbleSettings / #10 powerSaving (rendered title
                    // "Animations") / #11 stickersAndEmoji =========
                    // F-5 (diag-suite_settings_appearance-TC-0400-round4.md, ⑪): merged into one
                    // card — source assembles .textSize/.bubbleSettings and .powerSaving/
                    // .stickersAndEmoji into the same ThemeSettingsControllerSection.message
                    // section (ThemeSettingsController.swift:143-158), so they render as one card
                    // with one set of rounded corners, not two separately-chromed cards. Row
                    // order and each row's routerPush target are unchanged; only the card
                    // boundary and the added separator between "Message Corners" and "Animations"
                    // are new. Source's .powerSaving case renders with title
                    // AppearanceSettings_Animations ("Animations") but opens Power Saving
                    // settings, not an inline animation toggle — the previous rebuild's standalone
                    // "ANIMATIONS" toggle section was a misreading of this row, not a real entry;
                    // both destinations already exist as real pages.
                    Column {
                        ItemListDisclosureRow(
                            title: this.localized("Appearance_TextSizeSetting", "Text Size"),
                            value: this.textSizeRightValueMirror,
                            onClick: { => routerPush("TextSizeSelectionPage", "") }
                        )
                        ItemListSeparator()
                        ItemListDisclosureRow(
                            title: this.localized("Appearance_BubbleCornersSetting", "Message Corners"),
                            value: "",
                            onClick: { => routerPush("BubbleSettingsPage", "") }
                        )
                        ItemListSeparator()
                        ItemListDisclosureRow(
                            title: this.localized("AppearanceSettings_Animations", "Animations"),
                            value: "",
                            onClick: { => routerPush("PowerSavingSettingsPage", "") }
                        )
                        ItemListSeparator()
                        ItemListDisclosureRow(
                            title: this.localized("ChatSettings_StickersAndReactions", "Stickers and Emoji"),
                            value: "",
                            onClick: { => routerPush("StickersSettingsPage", "") }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(12)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24)

                    // ========= #12 APP ICON / #13 iconItem =========
                    // TC-0400 round3 F-5a/F-5b (RC-E, ❽): full 11-icon 4-column grid with real
                    // artwork for every cell (F-5b converted the remaining 10 sources this round —
                    // see appIconCount()/buildAppIconCell() doc above for the mapping), premium
                    // lock badges, per-cell rounded selection frame, and unselected-cell outline —
                    // replacing the single hand-rolled "Default" cell. Grid version of
                    // AppDelegate.swift:952-967 order, 4 columns per
                    // ThemeSettingsAppIconItem.swift:355-360 (`i % 4 == 0` row break).
                    ItemListSectionHeader(title: this.localized("Appearance_AppIcon", "App Icon").toUpper(), topPad: 24)
                    Column {
                        Row {
                            this.buildAppIconCell(0)
                            this.buildAppIconCell(1)
                            this.buildAppIconCell(2)
                            this.buildAppIconCell(3)
                        }
                        .width(100.percent)
                        .justifyContent(FlexAlign.SpaceBetween)
                        .padding(left: 16, right: 16, top: 16)

                        Row {
                            this.buildAppIconCell(4)
                            this.buildAppIconCell(5)
                            this.buildAppIconCell(6)
                            this.buildAppIconCell(7)
                        }
                        .width(100.percent)
                        .justifyContent(FlexAlign.SpaceBetween)
                        .padding(left: 16, right: 16, top: 16)

                        Row {
                            this.buildAppIconCell(8)
                            this.buildAppIconCell(9)
                            this.buildAppIconCell(10)
                            // Index 11 is intentionally beyond appIconCount() (11 real icons,
                            // indices 0..10) — this renders buildAppIconCell's invisible-spacer
                            // branch so the 4th column keeps the same width in every row and the
                            // three real cells above stay left-aligned under their own columns
                            // instead of re-spreading across the full row width.
                            this.buildAppIconCell(11)
                        }
                        .width(100.percent)
                        .justifyContent(FlexAlign.SpaceBetween)
                        .padding(left: 16, right: 16, top: 16, bottom: 16)
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(12)
                    .margin(left: 16, right: 16)

                    // ========= #14 OTHER / #16 showNextMediaOnTap / #17 info =========
                    ItemListSectionHeader(title: this.localized("Appearance_Other", "Other").toUpper(), topPad: 24)
                    Column {
                        ItemListToggleRow(
                            title: this.localized("Appearance_ShowNextMediaOnTap", "Show Next Media on Tap"),
                            isOn: this.showNextMediaOnTap,
                            onChange: { isOn: Bool => this.saveShowNextMediaOnTap(isOn) }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(12)
                    .clip(true)
                    .margin(left: 16, right: 16)

                    ItemListSectionFooter(
                        text: this.localized("Appearance_ShowNextMediaOnTapInfo", "Tap near the edge of the screen while viewing media to navigate between photos.")
                    )
                }
                .padding(bottom: 32)
            }
            .layoutWeight(1)
            .backgroundColor(this.presentation.backgroundColor)
        }
        .width(100.percent)
        .height(100.percent)
        // Rework round 1 (safe_area_padding_scoped_below_sibling_navbar):
        // moved here from the inner Scroll — this outer Column is build()'s true root and the
        // one that actually contains both the self-drawn nav bar Row (line 728-760) and the
        // Scroll as siblings, matching CountrySelectionPage.cj:410-419's identical shape. Padding
        // on the Scroll alone left the nav bar Row unprotected from the status bar.
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .backgroundColor(this.presentation.backgroundColor)
        .onAppear({ => this.ensureLoaded() })
    }
}

/**
 * ThemeCarouselCardCanvas — Canvas-backed thumbnail for one built-in theme identity's carousel
 * card (this file's #2 carousel) or grid/row card (pages/ChatThemesPage.cj's F2 grid and F3 base
 * row — same package, reused directly, no second copy of this drawing logic).
 *
 * diag-suite_settings_appearance-TC-0400-round10.md F-1 §6: mirrors
 * components/MessageBubble.cj:3770-4004 MessageBubbleShape's own-ctx-per-instance +
 * zero-height-probe repaint shape (colour/size change is the only thing that would otherwise have
 * no repaint channel — Canvas only fires .onReady once and .onAreaChange when its measured area
 * actually changes). Values are plain @Prop fields read once per instance, not passed through any
 * @Builder-func parameter — D-219 (this file's own dispatch note) only freezes @Builder func
 * *parameters*; @Component @Prop fields are the standard ArkUI channel MessageBubbleShape already
 * proves works, and every value fed in here is a per-theme-identity constant that never changes
 * for the lifetime of one card instance, so there is nothing that would need D-219's "read @State
 * directly, drop the parameter" workaround in the first place.
 *
 * Background: solid / 2-stop linear gradient / 4-point software gradient, matching
 * WallpaperResources.swift:1610-1633 themeIconImage()'s three branches by wallpaperColors.size.
 * The >=3 branch is the same tile loop as components/WallpaperBackgroundComponent.cj:236-266
 * drawMultiColorGradient(), with `this.gradientColors` swapped for the wallpaperColors @Prop and
 * phase fixed at 0 (SoftwareGradientBackground.swift:246-249 generatePreview() is
 * shiftArray(offset: 0) — a static preview, not the live animated background, so phase must not
 * vary or animate here).
 *
 * Two bubble swatches: geometry given in WallpaperResources.swift:1744 (incoming) / :1805
 * (outgoing, after its horizontal mirror) in the source's 82x108 image-coordinate space, scaled to
 * this card's actual size. Sticker layer (ThemeCarouselItem.swift:449/:876) intentionally left
 * blank — emoji resource pipeline not wired, same boundary condition as round9 F-4's "leave the
 * sticker slot empty" and case TC-0400's E1-c registered-not-failed treatment.
 */
@Component
public class ThemeCarouselCardCanvas {
    @Prop var wallpaperColors: Array<UInt32>
    @Prop var incomingColor: UInt32
    @Prop var outgoingColor: UInt32
    @Prop var fallbackColor: UInt32
    @Prop var canvasW: Float64
    @Prop var canvasH: Float64
    @Prop var drawBackground: Bool

    // D-190: ctx must share the Canvas node's own construction, not live across a reuse pool —
    // this class is not @Reusable, so a plain per-instance `let` (same pattern as
    // MessageBubbleShape.ctx) is enough.
    private let ctx: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    // Measured area: starts at the caller-declared canvasW/canvasH (AppearanceSettingsPage's
    // fixed 90x120 carousel chrome and ChatThemesPage's fixed 90x120 argument both settle here
    // immediately; the Canvas below still fills its parent by percentage and self-corrects via
    // onAreaChange for any container that resolves to a different real size, e.g. a fr-sized grid
    // column) — this makes the very first onReady paint (which can fire before layout resolves)
    // non-blank instead of 0x0.
    private var measuredW: Float64 = 0.0
    private var measuredH: Float64 = 0.0

    // Repaint dedupe bookkeeping — plain var (not @State), same reasoning as
    // MessageBubbleShape.paintedFill etc: these only gate the repaint decision, they are never
    // themselves read by build()'s render tree, so making them @State would create a redundant
    // rebuild loop against the zero-height probe below.
    private var paintedIncoming: UInt32 = 0
    private var paintedOutgoing: UInt32 = 0
    private var paintedFallback: UInt32 = 0
    private var paintedW: Float64 = -1.0
    private var paintedH: Float64 = -1.0
    private var paintedColorsKey: String = ""
    private var paintedDrawBackground: Bool = true

    private func wallpaperColorsKey(): String {
        var key = ""
        for (c in this.wallpaperColors) {
            key = key + c.toString() + ","
        }
        return key
    }

    /** Returned value feeds a zero-height Text probe — same technique as MessageBubbleShape. */
    private func repaintIfChanged(): String {
        this.paintCardIfChanged(this.measuredW, this.measuredH)
        return ""
    }

    /**
     * Source ThemeCarouselThemeItemIconNode keeps the generated themeIconImage in imageNode and
     * only replaces it when the theme reference, wallpaper, night mode or channel mode changes.
     * Moving that node while its containing list scrolls never regenerates the preview image.
     *
     * Keep the same invariant here for every paint entry point. ArkUI onAreaChange also fires when
     * a node's screen position changes inside the outer vertical Scroll; without this gate every
     * scroll frame used to rerun the 80x80 software-gradient loop even though neither the card's
     * content nor its size changed.
     */
    private func paintCardIfChanged(width: Float64, height: Float64): Unit {
        let key = this.wallpaperColorsKey()
        if (key != this.paintedColorsKey ||
            this.incomingColor != this.paintedIncoming ||
            this.outgoingColor != this.paintedOutgoing ||
            this.fallbackColor != this.paintedFallback ||
            this.drawBackground != this.paintedDrawBackground ||
            width != this.paintedW || height != this.paintedH) {
            this.paintCard(width, height)
        }
    }

    private func paintCard(width: Float64, height: Float64): Unit {
        this.paintedColorsKey = this.wallpaperColorsKey()
        this.paintedIncoming = this.incomingColor
        this.paintedOutgoing = this.outgoingColor
        this.paintedFallback = this.fallbackColor
        this.paintedDrawBackground = this.drawBackground
        this.paintedW = width
        this.paintedH = height
        this.drawCard(width, height)
    }

    public func build() {
        Stack {
            Text(this.repaintIfChanged()).height(0).fontSize(0)
            Canvas(this.ctx)
                .width(100.percent)
                .height(100.percent)
                .onReady({ =>
                    this.measuredW = this.canvasW
                    this.measuredH = this.canvasH
                    this.paintCardIfChanged(this.measuredW, this.measuredH)
                })
                .onAreaChange({ _: Area, newArea: Area =>
                    let width = newArea.width.value
                    let height = newArea.height.value
                    // Position-only callbacks are the normal case while the page scrolls. Leave
                    // the cached Canvas content untouched unless layout changed its actual size.
                    if (width != this.measuredW || height != this.measuredH) {
                        this.measuredW = width
                        this.measuredH = height
                        this.paintCardIfChanged(width, height)
                    }
                })
        }
        .width(100.percent)
        .height(100.percent)
    }

    /** Rounded-rect fill via the same arcTo path technique MessageBubble.cj:3922-3933 uses. */
    private func fillRoundedRect(x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, color: UInt32): Unit {
        let ctx = this.ctx
        ctx.fillStyle = color
        ctx.beginPath()
        ctx.moveTo(x + radius, y)
        ctx.lineTo(x + w - radius, y)
        ctx.arcTo(x + w, y, x + w, y + radius, radius)
        ctx.lineTo(x + w, y + h - radius)
        ctx.arcTo(x + w, y + h, x + w - radius, y + h, radius)
        ctx.lineTo(x + radius, y + h)
        ctx.arcTo(x, y + h, x, y + h - radius, radius)
        ctx.lineTo(x, y + radius)
        ctx.arcTo(x, y, x + radius, y, radius)
        ctx.closePath()
        ctx.fill()
    }

    private func drawCard(width: Float64, height: Float64): Unit {
        if (width <= 0.0 || height <= 0.0) {
            return
        }
        let ctx = this.ctx
        ctx.clearRect(0.0, 0.0, width, height)

        // Background — F-1 §6 first bullet, three branches matching
        // WallpaperResources.swift:1610-1633.
        let colors = this.wallpaperColors
        if (!this.drawBackground) {
            // WallpaperBackgroundComponent is mounted below this canvas; retain transparent
            // pixels here and paint only the message bubbles.
        } else if (colors.size >= 3) {
            let tileW: Int64 = 80
            let tileH: Int64 = 80
            let positions = gradientPositionsForPhase(0)
            let scaleX = width / Float64(tileW)
            let scaleY = height / Float64(tileH)
            for (py in 0..tileH) {
                let wy = Float64(py) / Float64(tileH)
                for (px in 0..tileW) {
                    let wx = Float64(px) / Float64(tileW)
                    let pixelArgb = gradientComputePixel(wx, wy, colors, positions)
                    ctx.fillStyle = pixelArgb
                    ctx.fillRect(
                        Float64(px) * scaleX,
                        Float64(py) * scaleY,
                        scaleX + 1.0,
                        scaleY + 1.0
                    )
                }
            }
        } else if (colors.size == 2) {
            let gradient = ctx.createLinearGradient(0.0, 0.0, 0.0, height)
            gradient.addColorStop(0.0, colors[0])
            gradient.addColorStop(1.0, colors[1])
            ctx.fillStyle = gradient
            ctx.fillRect(0.0, 0.0, width, height)
        } else {
            let fill = if (colors.size == 1) { colors[0] } else { this.fallbackColor }
            ctx.fillStyle = fill
            ctx.fillRect(0.0, 0.0, width, height)
        }

        // Two bubble swatches — F-1 §6 second bullet, geometry given in the source's 82x108 image
        // space (WallpaperResources.swift:1744 incoming / :1805 outgoing after its horizontal
        // mirror), scaled to this card's actual size.
        let scaleX = width / 82.0
        let scaleY = height / 108.0
        let cornerRadius = 12.0 * scaleY
        // outgoing: on top, right-inset 8 (source mirrors it horizontally; net effect is a right
        // inset instead of the pre-fix code's left/bottom placement).
        this.fillRoundedRect(
            (82.0 - 8.0 - 48.0) * scaleX, 12.0 * scaleY, 48.0 * scaleX, 24.0 * scaleY,
            cornerRadius, this.outgoingColor)
        // incoming: in the middle, left-inset 8.
        this.fillRoundedRect(
            8.0 * scaleX, 40.0 * scaleY, 48.0 * scaleX, 24.0 * scaleY,
            cornerRadius, this.incomingColor)
    }
}
