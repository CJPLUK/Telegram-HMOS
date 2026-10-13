package ohos_app_cangjie_entry.app

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import ohos_app_cangjie_entry.core.storage.{getAppThemeTextColor, getAppThemeAccentColor, getAppThemeNavBarColor, getAppThemeBackground}
import ohos_app_cangjie_entry.router.*

/**
 * P2-009 M1: Shared navigation bar back-control primitive (NavigationBarImpl equivalent).
 *
 * iOS reference: submodules/TelegramUI/Components/NavigationBarImpl/Sources/NavigationBarImpl.swift
 * `updateLeftButton(animated:)` (:441-486) computes the left-side control from the container's
 * `previousItem` (three states — nil / .item / .close) and always renders it as a graphic node
 * (`backButtonArrow: ASImageNode`, :563/:617-620/:639/:769), never as free-standing text.
 *
 * Style fork (case doc fc389705 boundary — see hand-off report): `:459-462`
 * `if backTitle != nil { if case .glass = theme.style { backTitle = "" } }` only clears the
 * caption under `.glass`. ~57 sites across the source construct `NavigationBarPresentationData`
 * without a `style:` argument (defaults to `.legacy`, e.g. ChatSearchResultsController.swift:37) —
 * those keep a real caption. This primitive therefore takes an explicit `NavBarStyle` and must
 * not hardcode "no caption" for every caller; per-page style selection is wired during the M3
 * retrofit (out of scope this round — this file is a zero-consumer primitive until then).
 *
 * Geometry:
 * - Glass back arrow = literal vector migration of `glassBackArrowImage` (NavigationButtonNode.swift:8-23)
 *   — 44x44 canvas, open polyline (24.6,14)->(17,22)->(24.6,30), stroke width 2.0, round cap/join,
 *   rendered `.alwaysTemplate` and tinted via `iconView.tintColor = component.color` at the call site
 *   (:145 of that file) — i.e. the source stroke color itself is irrelevant, only the shape matters.
 *   Rendered here as `Path().commands(...).stroke(...)` (open stroke, matches source), NOT as
 *   `Image(nav_back_arrow_glass.svg).fillColor(...)`: that SVG is `fill="none" stroke="#FFFFFF"`
 *   (an open chevron), and ArkUI's `Image.fillColor()` recolors the image's alpha mask as a *filled*
 *   shape, turning the open chevron into a solid triangle — the exact bug fixed on the same primitive
 *   in `pages/DevicesPage.cj` (TC-0134-round4 §6.2/§3.3, `backArrowCommands()`) and replicated here
 *   as `navBackArrowGlassCommands()`. `nav_back_arrow_glass.svg` itself is left in place (still a
 *   faithful geometry reference, just not consumed via `Image` anymore).
 * - Legacy icon = literal vector migration of `NavigationBarTheme.generateBackArrowImage`
 *   (submodules/Display/Source/NavigationBar.swift:8-16) — 13x22 canvas, filled SVG path
 *   "M3.6,11.5 L11.5,3.6 C12.1,3.0 12.1,2.0 11.5,1.4 C11.0,0.9 10.0,0.9 9.4,1.4 L0.4,10.4
 *   C-0.1,11.0 -0.1,12.0 0.4,12.6 L9.4,21.6 C10.0,22.1 11.0,22.1 11.5,21.6 C12.1,21.0 12.1,20.0
 *   11.5,19.4 Z" (exact source coordinates preserved) — stored as
 *   resources/base/media/nav_back_arrow_legacy.svg.
 * - Close icon reuses the already-converted `nav_ic_close` resource, the vector equivalent of the
 *   "Navigation/Close" bundle image consumed by `glassCloseImage` (NavigationButtonNode.swift:25-27).
 * - Glass circular background (`cornerRadius = height * 0.5`, NavigationBarImpl.swift:1022) is
 *   migrated as `.width(44).height(44).borderRadius(22)`; legacy has no such background container
 *   (source `.legacy` back button is a plain UIBarButtonItem, no `leftButtonsBackgroundView`).
 * - Legacy caption text: the source 4-level fallback (`customBackButtonText` ->
 *   `leftBarButtonItem.title` -> `previousItem.item`'s `backBarButtonItem.title ?? strings.back` /
 *   `title ?? strings.back` -> nil for `.close`) needs a previous-screen title registry this
 *   primitive does not have inputs for; this migration uses the chain's own terminal fallback
 *   value (`strings.back` == "Back") rather than inventing a value — see hand-off report.
 *
 * G-10 round (diag-suite_settings_privacy-E12-batch.md §七 G-10, basis-primitive scope only —
 * host page migration explicitly held back this round, see that report's boundary condition):
 * - Nav-area background: the outer bar `Row` in every branch now reads `getAppThemeBackground()`
 *   (the same list/page background token `pages/PrivacySettingsPage.cj` already hardcodes as
 *   `0xF2F2F7`), not `getAppThemeNavBarColor()` (resolves to opaque `0xFFFFFF` white in the light
 *   theme). Source has no literal `0xEFEFF4` constant reachable from this primitive's inputs —
 *   `list.blocksBackgroundColor` (`DefaultDayPresentationTheme.swift:473`) and the nav bar's own
 *   `blurredBackgroundColor`/`opaqueBackgroundColor` (`:419-420`, `0xf2f2f2`/`0xf7f7f7`-derived) are
 *   two visually-adjacent-but-distinct source tokens, neither equal to `0xEFEFF4` bit-for-bit —
 *   `getAppThemeBackground()` was picked because it is the one this project already treats as "the
 *   list/page background" (see the `PrivacySettingsPage.cj` precedent above), matching the report's
 *   intent ("同列表底色，不是不透明白条") more directly than introducing a second background field.
 *   The round `.glass` tray backgrounds (back/close circle, new right-button `.generic` pill below)
 *   deliberately keep `getAppThemeNavBarColor()` — that token is this project's existing, previously
 *   reviewed approximation of the source's separate frosted "panel" glass material
 *   (`GlassContextExtractableContainer`, NavigationBarImpl.swift:667-675), not the flat nav-area fill.
 * - Right-button slot (`NavBarRightButtonContent` + `NavBarButtonKind` below): migrates
 *   `NavigationButtonNodeImpl.ContentType` (`NavigationButtonNode.swift:536-540`, cases
 *   `.generic`/`.accent`/`.accentDisabled`) and its two consumption sites — foreground color
 *   (`NavigationBarImpl.swift:961-971`) and tray tint (`:1048-1059`). `.generic` (used for the
 *   `"___done"`-title-less items, e.g. the "Edit" text button, `commonContentType`
 *   `NavigationButtonNode.swift:824-848`) renders in the tray/"panel" material with
 *   `theme.buttonColor` foreground, where `theme` is a `NavigationBarTheme`
 *   (`Display/Source/NavigationBar.swift:20`) populated by a **style-forked** convenience
 *   initializer (`TelegramPresentationData/Sources/ComponentsThemes.swift:49-72`): the `.legacy`
 *   branch assigns `rootNavigationBar.buttonColor` (-> `defaultDayAccentColor`,
 *   `DefaultDayPresentationTheme.swift:413`, accent BLUE), but the `.glass` branch — the one this
 *   primitive's `NavBarStyle.Glass` actually corresponds to, and the one SettingsUI pages construct
 *   via `ItemListController.swift:286` (`style: .glass`) — assigns
 *   `chat.inputPanel.panelControlColor` instead (`DefaultDayPresentationTheme.swift:945`, pure
 *   BLACK `0x000000`). So `.generic` foreground here is black, not blue. Confirmed by pixel-sampling
 *   the source ground-truth screenshot
 *   (`e2e/reference/ios/TC-0132/ui_comparison/source_page_exception_peers/screenshot.png`): the
 *   "Edit" text samples `RGB(0,0,0)`, while the adjacent "Add Users or Groups" blue text samples
 *   `RGB(35,152,255)` — distinct hues, independently re-verified by Coordinator via PIL sampling.
 *   An earlier revision of this comment (and the correspondingly wrong code) cited
 *   `DefaultDayPresentationTheme.swift:413` directly — that citation is the `.legacy`-branch value,
 *   not the one live on this `.glass` primitive; see `dev_pattern.md` D-214 (this mistake is the
 *   worked example that rule documents). The `e2e/.../UI_comparison.md` Diff-3 row's original text
 *   description ("源：白色 pill/圆形底 + 蓝字") was itself wrong — it contradicted the very
 *   screenshot it cited — and has since been corrected in that file; do not re-derive from that
 *   stale text. `.accent` (used for the enabled `"___done"` item, i.e. the edit-mode checkmark) is
 *   unaffected by any of the above: it renders a solid `theme.accentButtonColor` tray with
 *   `theme.accentForegroundColor` foreground — white (`itemCheckColors.foregroundColor: 0xffffff`,
 *   `:508`) — confirmed against Diff-4 (source: "蓝色实心圆底 + 白色对勾").
 */

// Distinguishes the two navigation-bar caption regimes actually alive in the source (see file
// doc comment). Not a routing/stack concern (NavPreviousItem in router.cj already owns that
// orthogonal axis) — this is purely NavigationBarTheme's `style` property.
public enum NavBarStyle {
    | Glass
    | Legacy
}

// G-10 round: two visual forms for the `.glass` right-button tray, migrated from
// `NavigationButtonNodeImpl.ContentType` (NavigationButtonNode.swift:536-540) — see file doc
// comment for the full color derivation. `AccentDisabled` from the source enum is intentionally
// not modeled: the source only reaches it for a disabled `"___done"` checkmark, which is a
// page-level enable/disable decision outside this primitive's inputs (no consumer wires it yet).
public enum NavBarButtonKind {
    | Generic
    | Accent
}

// Right-side nav bar button content, mirroring the left-side `previousItem`/style split: `NoButton`
// preserves today's zero-content trailing balance spacer exactly; `TextButtonContent` and
// `IconButtonContent` carry the label/icon plus which of the two `NavBarButtonKind` trays to render.
public enum NavBarRightButtonContent {
    | NoButton
    | TextButtonContent(String, NavBarButtonKind)
    | IconButtonContent(AppResource, NavBarButtonKind)
}

// P2-009 M1: predicate helpers for use inside @Builder bodies (S-005: no let/var inside
// @Builder/build() — pattern precedented by CameraThumbnailHelper.hasCameraThumbnail() /
// ChatMessageBackgroundComponent.isNone(), both plain top-level/member funcs that `match` a
// custom enum and are called from @Builder conditionals).
func navPreviousItemIsNone(item: NavPreviousItem): Bool {
    match (item) {
        case NavPreviousItem.None => true
        case _ => false
    }
}

func navPreviousItemIsClose(item: NavPreviousItem): Bool {
    match (item) {
        case NavPreviousItem.Close => true
        case _ => false
    }
}

func navBarStyleIsGlass(style: NavBarStyle): Bool {
    match (style) {
        case NavBarStyle.Glass => true
        case NavBarStyle.Legacy => false
    }
}

// G-10 round: right-button content predicates/extractors, same match-outside-@Builder pattern as
// navPreviousItemIsNone/navPreviousItemIsClose above (S-005 forbids let/var — and therefore
// value-binding match arms — inside the @Builder body itself).
func navBarRightButtonIsNone(content: NavBarRightButtonContent): Bool {
    match (content) {
        case NavBarRightButtonContent.NoButton => true
        case _ => false
    }
}

func navBarRightButtonIsText(content: NavBarRightButtonContent): Bool {
    match (content) {
        case NavBarRightButtonContent.TextButtonContent(_, _) => true
        case _ => false
    }
}

func navBarRightButtonText(content: NavBarRightButtonContent): String {
    match (content) {
        case NavBarRightButtonContent.TextButtonContent(text, _) => text
        case _ => ""
    }
}

func navBarRightButtonIcon(content: NavBarRightButtonContent): AppResource {
    match (content) {
        case NavBarRightButtonContent.IconButtonContent(res, _) => res
        // Unreachable in practice (only called from the icon-button @Builder branch, gated by
        // navBarRightButtonIsText's negation); AppResource has no zero value, so a real icon
        // resource is still returned rather than leaving this a partial match.
        case _ => navCloseIconRes()
    }
}

func navBarRightButtonKind(content: NavBarRightButtonContent): NavBarButtonKind {
    match (content) {
        case NavBarRightButtonContent.TextButtonContent(_, kind) => kind
        case NavBarRightButtonContent.IconButtonContent(_, kind) => kind
        case NavBarRightButtonContent.NoButton => NavBarButtonKind.Generic
    }
}

// Tray background per NavigationBarImpl.swift:1048-1059 (`rightButtonsColor`): `.generic` keeps the
// tray's existing "panel" glass material (this project's `getAppThemeNavBarColor()` approximation,
// same token as the back/close tray); `.accent` overrides it with a solid `theme.accentButtonColor`
// fill — this project's accent blue, `getAppThemeAccentColor()`.
func navBarButtonTrayColor(kind: NavBarButtonKind): UInt32 {
    match (kind) {
        case NavBarButtonKind.Accent => getAppThemeAccentColor()
        case NavBarButtonKind.Generic => getAppThemeNavBarColor()
    }
}

// Foreground (text/icon) color per NavigationBarImpl.swift:961-971: `.generic` uses
// `theme.buttonColor`, which on this primitive's live `.glass` branch (see file doc comment for
// the full style-fork derivation) resolves to `chat.inputPanel.panelControlColor`
// (DefaultDayPresentationTheme.swift:945) — pure black, not the `.legacy`-branch accent blue at
// DefaultDayPresentationTheme.swift:413. Literal `0x000000` (no theme-color token) to match this
// project's existing precedent for the same source constant, `pages/DevicesPage.cj:630`
// `.fontColor(0x000000)`. `.accent` uses `theme.accentForegroundColor` (white,
// DefaultDayPresentationTheme.swift:508) for contrast against the solid accent tray.
func navBarButtonForegroundColor(kind: NavBarButtonKind): UInt32 {
    match (kind) {
        case NavBarButtonKind.Accent => 0xFFFFFF
        case NavBarButtonKind.Generic => 0x000000
    }
}

// P2-009 M1: `@r(...)` resource-macro accessors, extracted to plain top-level funcs.
// Precedent: components/CallControls.cj `getCallV2IconRes` (`return @r(app.media.callui_v2_mute)`
// etc.) consumed by pages/CallScreen.cj as `Image(getCallV2IconRes("speaker"))`. `@r(...)` written
// directly inline as an `Image(...)` constructor argument inside a top-level `@Builder` body does
// not macro-expand (undeclared identifier 'r'); wrapping it in a plain func and calling that func
// from the @Builder body does.
func navBackArrowLegacyRes(): AppResource {
    return @r(app.media.nav_back_arrow_legacy)
}

func navCloseIconRes(): AppResource {
    return @r(app.media.nav_ic_close)
}

// P2-009 M1 fix (diag-suite_session_shell-TC-0021-round2.md F-1.1): Path command string for the
// `.glass` back arrow, replacing the removed `navBackArrowGlassRes()` Image accessor (see file doc
// comment above for why `.fillColor()` on that SVG was wrong). Geometry/scale ported from
// `pages/DevicesPage.cj:728 backArrowCommands()` — same coordinates, same vp->px density scaling
// (ArkUI `Path.commands` consumes px; `.width`/`.height`/`.strokeWidth` consume vp — round5 N1').
// That helper is a `@Component` member and reads `this.getUIContext().vp2px(...)`; this file's
// `buildTelegramNavBar` is a top-level `@Builder` func with no `this`, so this version uses the
// free top-level `getDefaultDisplaySync()` (ohos.display, no UIContext needed) directly instead of
// attempting the `vp2px` branch first — precedented as the same function's own fallback branch.
private func navBackArrowGlassCommands(): String {
    let scale: Float64 = Float64(getDefaultDisplaySync().densityPixels)
    let xRight: Float64 = 24.6 * scale
    let xApex: Float64 = 17.0 * scale
    let yTop: Float64 = 14.0 * scale
    let yMid: Float64 = 22.0 * scale
    let yBottom: Float64 = 30.0 * scale
    return "M${xRight} ${yTop} L${xApex} ${yMid} L${xRight} ${yBottom}"
}

/**
 * Build the shared themed navigation bar: centered title + left-side back/close control
 * driven by `previousItem` (see router.cj `navPreviousItem(route)`) and `style`
 * (see `NavBarStyle` doc above — `.glass` pages must pass `NavBarStyle.Glass`,
 * `.legacy` pages — the ~57 sites that omit `style:` on the source side — must pass
 * `NavBarStyle.Legacy`; never hardcode one for all callers).
 * Top-level @Builder per D-001 (must not be a @Component member method).
 *
 * @param title        Page title string displayed centered in the nav bar.
 * @param previousItem Three-state control selector — None: no control (root/stack-bottom,
 *                      mirrors previousItem==nil => backButtonNode removed); Item: back arrow
 *                      (mirrors .item(prevScreen)); Close: close glyph (mirrors .close, modal roots).
 * @param style        NavBarStyle.Glass: pure icon, zero caption, circular glass background.
 *                      NavBarStyle.Legacy: icon + "Back" caption, no background container.
 * @param onBack        Invoked on tap of the back/close control (caller wires routerPop()).
 * @param rightButton   G-10 round: right-side control content (`NavBarRightButtonContent.NoButton`
 *                      preserves the prior zero-content trailing spacer exactly). Only rendered
 *                      under `NavBarStyle.Glass` — the source's right-button tray/pill material
 *                      (`rightButtonsBackgroundView`) is itself `.glass`-exclusive
 *                      (NavigationBarImpl.swift:655/672-675); `.legacy` callers may still pass a
 *                      non-`NoButton` value without effect, this parameter is simply inert there.
 * @param onRightButtonTap Invoked on tap of the right-side control; ignored when rightButton is
 *                      NoButton.
 */
@Builder
public func buildTelegramNavBar(title: String, previousItem: NavPreviousItem, style: NavBarStyle, onBack: () -> Unit, rightButton: NavBarRightButtonContent, onRightButtonTap: () -> Unit) {
    if (navPreviousItemIsNone(previousItem)) {
        // None: no control node at all (not even an invisible placeholder), regardless of style —
        // mirrors NavigationBarImpl backTitle==nil => backButtonNode never constructed.
        Row {
            Text(title)
                .fontSize(17)
                .fontColor(getAppThemeTextColor())
                .fontWeight(FontWeight.Bold)
        }
        .width(100.percent)
        .height(44)
        .backgroundColor(getAppThemeBackground())
        .padding(left: 16, right: 16)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
    } else if (navBarStyleIsGlass(style)) {
        // .glass: pure-icon control in a circular glass background, zero caption
        // (NavigationBarImpl.swift:459-462 unconditional `backTitle = ""` under .glass).
        Row {
            if (navPreviousItemIsClose(previousItem)) {
                Stack {
                    Image(navCloseIconRes())
                        .width(44)
                        .height(44)
                        .fillColor(getAppThemeAccentColor())
                }
                .width(44)
                .height(44)
                .borderRadius(22)
                .backgroundColor(getAppThemeNavBarColor())
                .alignContent(Alignment.Center)
                .onClick({ _ => onBack() })
            } else {
                // TC-0021-round2 F-1.1 fix: open-stroke Path (matches source template-tinted
                // stroke shape), not a filled Image — see file doc comment + navBackArrowGlassCommands().
                Stack {
                    Path()
                        .width(44)
                        .height(44)
                        .commands(navBackArrowGlassCommands())
                        .fill(Color.Transparent)
                        .stroke(getAppThemeAccentColor())
                        .strokeWidth(2)
                        .strokeLineCap(LineCapStyle.Round)
                        .strokeLineJoin(LineJoinStyle.Round)
                }
                .width(44)
                .height(44)
                .borderRadius(22)
                .backgroundColor(getAppThemeNavBarColor())
                .alignContent(Alignment.Center)
                .onClick({ _ => onBack() })
            }
            Blank()
            // No Text("<")/Text(trSource("Back")) sibling under .glass — caption is permanently empty here.
            Text(title)
                .fontSize(17)
                .fontColor(getAppThemeTextColor())
                .fontWeight(FontWeight.Bold)
            Blank()
            if (navBarRightButtonIsNone(rightButton)) {
                // Trailing balance spacer (same 44 width as the leading control) so the centered
                // Text(title) above is not skewed by the leading control's width — unchanged
                // behavior when no right button content is supplied.
                Row {}
                    .width(44)
                    .height(44)
            } else if (navBarRightButtonIsText(rightButton)) {
                // .generic text pill (e.g. "Edit") — pill sizing (44 height, 14 horizontal padding,
                // 22 corner radius = height*0.5) matches the already-reviewed precedent in
                // pages/DevicesPage.cj:609-641 editButtonContent(); foreground/tray colors follow
                // navBarButtonForegroundColor/navBarButtonTrayColor (file doc comment above has the
                // full derivation: `.glass`-branch panelControlColor is black — the same black
                // DevicesPage.cj:630 already uses — not accent blue; D-214 in dev_pattern.md).
                Stack {
                    Text(navBarRightButtonText(rightButton))
                        .fontSize(17)
                        .fontColor(navBarButtonForegroundColor(navBarRightButtonKind(rightButton)))
                        .fontWeight(FontWeight.Medium)
                }
                .height(44)
                .padding(left: 14, right: 14)
                .borderRadius(22)
                .backgroundColor(navBarButtonTrayColor(navBarRightButtonKind(rightButton)))
                .alignContent(Alignment.Center)
                .onClick({ _ => onRightButtonTap() })
            } else {
                // .accent (or a future .generic) icon tray (e.g. the edit-mode done checkmark).
                // Icon sized 20x20 to match the existing media_ic_check call sites in this project
                // (pages/DevicesPage.cj:621/660, pages/SelectivePrivacySettingsPage.cj:1179/1301/1321),
                // centered in the same 44x44/borderRadius(22) tray as the left-side back/close control.
                Stack {
                    Image(navBarRightButtonIcon(rightButton))
                        .width(20)
                        .height(20)
                        .fillColor(navBarButtonForegroundColor(navBarRightButtonKind(rightButton)))
                }
                .width(44)
                .height(44)
                .borderRadius(22)
                .backgroundColor(navBarButtonTrayColor(navBarRightButtonKind(rightButton)))
                .alignContent(Alignment.Center)
                .onClick({ _ => onRightButtonTap() })
            }
        }
        .width(100.percent)
        .height(44)
        .backgroundColor(getAppThemeBackground())
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
    } else {
        // .legacy: icon + real caption, no circular background container (source `.legacy` back
        // button is a plain UIBarButtonItem — no `leftButtonsBackgroundView`).
        Row {
            if (navPreviousItemIsClose(previousItem)) {
                Image(navCloseIconRes())
                    .width(18)
                    .height(18)
                    .fillColor(getAppThemeAccentColor())
                    .onClick({ _ => onBack() })
            } else {
                Row {
                    Image(navBackArrowLegacyRes())
                        .width(13)
                        .height(22)
                        .fillColor(getAppThemeAccentColor())
                    Text(trSource("Back"))
                        .fontSize(17)
                        .fontColor(getAppThemeAccentColor())
                        .margin(left: 6)
                }
                .onClick({ _ => onBack() })
            }
            Blank()
            Text(title)
                .fontSize(17)
                .fontColor(getAppThemeTextColor())
                .fontWeight(FontWeight.Bold)
            Blank()
        }
        .width(100.percent)
        .height(44)
        .backgroundColor(getAppThemeBackground())
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
    }
}

/**
 * Build a themed navigation bar title row without back button (root pages).
 * Equivalent to `buildTelegramNavBar(title, previousItem: NavPreviousItem.None, style: <any>,
 * onBack: { => }, rightButton: NavBarRightButtonContent.NoButton, onRightButtonTap: { => })`
 * (style/right-button are irrelevant when previousItem is None — the None branch above never
 * reads them); kept as a separate zero-arg-callback entry point for existing/root-page callers.
 * Top-level @Builder per D-001.
 *
 * @param title  Page title string displayed in nav bar
 */
@Builder
public func buildTelegramNavBarRoot(title: String) {
    Row {
        Text(title)
            .fontSize(17)
            .fontColor(getAppThemeTextColor())
            .fontWeight(FontWeight.Medium)
    }
    .width(100.percent)
    .height(44)
    .backgroundColor(getAppThemeBackground())
    .padding(left: 16, right: 16)
    .alignItems(VerticalAlign.Center)
}
