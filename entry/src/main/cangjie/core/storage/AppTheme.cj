package ohos_app_cangjie_entry.core.storage

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkUI.*
import std.sync.Mutex
import std.math.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.interop.callArkOnJSTask

/**
 * Presentation snapshot — immutable, one recompute entry point, one published key.
 *
 * Architectural counterpart of iOS submodules/TelegramPresentationData/Sources/PresentationData.swift:88-121
 * `PresentationData`. Every colour / font size a render surface needs comes from a field on this
 * class; there are no in-place setters — callers derive a new instance via `withUpdated<X>(...)`.
 *
 * The single authoritative instance lives in `_currentPresentation` (module-private) and is
 * rebuilt exclusively by `recomputePresentation()`. Consumers read it through `currentPresentation()`
 * or (for source-compat) through the legacy `getAppTheme*()` free functions, which now forward into
 * this snapshot instead of a mutable singleton field.
 */
public class PresentationSnapshot {
    // Raw persisted theme selector: 0 = Light, 1 = Dark, 2 = System.
    public let theme: Int32
    // Resolved effective dark/light flag actually driving the colour table below
    // (folds in System-follows-OS and auto-night override — see recomputePresentation()).
    public let isDark: Bool

    // Derived colours (对位 PresentationData.swift 的 PresentationThemeColors 派生集合)
    public let backgroundColor: UInt32
    public let cardColor: UInt32
    public let textColor: UInt32
    public let secondaryTextColor: UInt32
    public let accentColor: UInt32
    public let dividerColor: UInt32
    public let bubbleOutColor: UInt32
    public let bubbleInColor: UInt32
    public let navBarColor: UInt32

    // Font sizes (对位 PresentationData.swift:88 chatFontSize / listsFontSize)
    public let chatFontSize: Int32
    public let listsFontSize: Int32
    public let useSystemFont: Bool

    public let chatBackgroundPath: String
    // 对位 PresentationData.swift:837 autoNightModeTriggered
    public let autoNightModeTriggered: Bool
    public let animationEnabled: Bool
    // Raw ConfigurationConstant.ColorMode ordinal last observed from the system
    // (COLOR_MODE_NOT_SET = -1, COLOR_MODE_DARK = 0, COLOR_MODE_LIGHT = 1). See setSystemColorMode().
    public let systemColorMode: Int32

    // ic_clist_theme_row_state_colors (clist_presentation_data round1 required_fix #2): per-theme
    // chat-row state backgrounds, 对位 DefaultDayPresentationTheme.swift:539-546 /
    // DefaultDarkPresentationTheme.swift:479-486. Distinct from dividerColor — the light value of
    // itemHighlightedBackgroundColor (0xE5E5EA) numerically coincides with dividerColor's light
    // value, but they diverge in dark mode (0x121212 vs dividerColor's 0x38383A) and map to
    // different source tokens (itemHighlightedBackgroundColor vs itemSeparatorColor); do not fold
    // this into dividerColor.
    public let itemHighlightedBackgroundColor: UInt32
    public let itemSelectedBackgroundColor: UInt32
    public let pinnedItemBackgroundColor: UInt32
    // ic_message_bubble_stroke_color_theme_values (shell_chat_message_items, TC-0407 round3):
    // bubble outline stroke colour consumed by components/MessageBubble.cj#drawBubbleCanvas() —
    // top byte 0x00 means "skip the whole outline pass" (that guard is the file's own
    // `hasStroke = ((strokeColor >> 24) & 0xFF) != 0`, not this codebase's generic D-175
    // alphaAdapt path, so a literal 0x00 top byte here is safe and intentional, not the "0x00
    // gets force-opaqued" trap). This field used to be derived from `backgroundColor` via
    // deriveBubbleStrokeColor()'s hue/sat/brightness-multiply formula in both themes; that is
    // wrong for both of this codebase's two reachable themes, independently re-derived from
    // source: this app's only light theme is `.dayClassic` (PresentationThemeSettings.swift:655
    // `theme: .builtin(.dayClassic)`), and `.dayClassic` is built with `day: false`
    // (DefaultDayPresentationTheme.swift:55 `defaultPresentationTheme = makeDefaultDayPresentationTheme(
    // ..., day: false, ...)`), under which `serviceBackgroundColor` — the very quantity the
    // hue/sat/brightness formula multiplies — is unconditionally overridden to
    // `UIColor(white: 0, alpha: 0.2)` before the formula ever runs (DefaultDayPresentationTheme.swift:
    // 391-396) and the theme's `bubbleStrokeColor` local is separately hardcoded to that exact same
    // literal, bypassing the formula outright, whenever `day == false`
    // (DefaultDayPresentationTheme.swift:580-585 `if day { ...withMultiplied... } else {
    // UIColor(white: 0.0, alpha: 0.2) }`) — i.e. light is the flat constant `0x33000000`, never a
    // backgroundColor-derived tint. This app's dark theme is always the built-in `.night`
    // (PresentationThemeSettings.swift:655 `automaticThemeSwitchSetting.theme = .builtin(.night)`),
    // whose bubble stroke is `.clear` on every incoming/outgoing x wallpaper combination, with no
    // hue-multiply involved at all (DefaultDarkPresentationTheme.swift:528/544/566/582) — i.e. dark
    // is `0x00000000` (no stroke drawn). Both branches below are therefore fixed per-theme literals,
    // set directly (not via deriveBubbleStrokeColor()). deriveBubbleStrokeColor()/rgbToHsv()/
    // hsvToRgb() are kept in place (harmless, and the formula would matter again if a future
    // `day: true` "Day" theme variant were added) but neither reachable theme calls them anymore.
    public let bubbleStrokeColor: UInt32
    // TC-0401 round8 F-2 (供给侧, consumed by shell_chat_message_items's date-separator header):
    // 对位源侧 chat.message.freeform.with{With,Without}Wallpaper.fill — the "free / service message"
    // background token, distinct from bubbleOutColor/bubbleInColor (those are the chat-bubble fill,
    // this is the free-floating date-separator / service-message pill fill). Source truth:
    // dayClassic (light) = 0xE5E5EA (DefaultDayPresentationTheme.swift:868-870); night (dark) =
    // 0x1F1F1F (DefaultDarkPresentationTheme.swift:597-599). Only new field, no existing field
    // reused: the light value numerically coincides with dividerColor's light value by coincidence
    // only — the dark values diverge (0x1F1F1F vs dividerColor's 0x38383A) and they map to different
    // source tokens.
    public let freeformBubbleColor: UInt32
    // TC-0127 RC-10 (供给侧, consumed by components/ItemListComponents.cj's disclosure/chevron glyph):
    // 对位源侧 PresentationThemeList.disclosureArrowColor (PresentationTheme.swift:461). Source truth:
    // day (light) = UIColor(rgb: 0xbab9be) opaque (DefaultDayPresentationTheme.swift:489); night
    // (dark) = UIColor(rgb: 0xffffff, alpha: 0.28) (DefaultDarkPresentationTheme.swift:429) ->
    // 0.28 * 255 = 71.4 -> 71 = 0x47 alpha byte, stored as 0x47FFFFFF (this codebase's existing
    // 0xAARRGGBB convention for translucent UInt32 colours, e.g. bubbleStrokeColor's 0x33 prefix —
    // see D-175: any UInt32 colour whose top byte is 0x00 gets force-adapted to opaque by the SDK's
    // alphaAdapt, so the alpha byte must be written explicitly non-zero here).
    public let disclosureArrowColor: UInt32
    // TC-0542 O3 (uif_contextui): 对位源侧 PresentationThemeContextMenu
    // (DefaultDayPresentationTheme.swift:1043-1052 / DefaultDarkPresentationTheme.swift:766-775).
    // Distinct from cardColor/textColor (those align actionSheet opaque tokens used by O1/O2).
    // Top bytes are non-zero (D-175 alphaAdapt).
    public let contextMenuBackgroundColor: UInt32
    public let contextMenuPrimaryColor: UInt32
    public let contextMenuDestructiveColor: UInt32
    public let contextMenuSeparatorColor: UInt32
    public let contextMenuDimColor: UInt32

    public init(
        theme: Int32,
        isDark: Bool,
        backgroundColor: UInt32,
        cardColor: UInt32,
        textColor: UInt32,
        secondaryTextColor: UInt32,
        accentColor: UInt32,
        dividerColor: UInt32,
        bubbleOutColor: UInt32,
        bubbleInColor: UInt32,
        navBarColor: UInt32,
        chatFontSize: Int32,
        listsFontSize: Int32,
        useSystemFont: Bool,
        chatBackgroundPath: String,
        autoNightModeTriggered: Bool,
        animationEnabled: Bool,
        systemColorMode: Int32,
        itemHighlightedBackgroundColor: UInt32,
        itemSelectedBackgroundColor: UInt32,
        pinnedItemBackgroundColor: UInt32,
        bubbleStrokeColor: UInt32,
        freeformBubbleColor: UInt32,
        disclosureArrowColor: UInt32,
        contextMenuBackgroundColor: UInt32,
        contextMenuPrimaryColor: UInt32,
        contextMenuDestructiveColor: UInt32,
        contextMenuSeparatorColor: UInt32,
        contextMenuDimColor: UInt32
    ) {
        this.theme = theme
        this.isDark = isDark
        this.backgroundColor = backgroundColor
        this.cardColor = cardColor
        this.textColor = textColor
        this.secondaryTextColor = secondaryTextColor
        this.accentColor = accentColor
        this.dividerColor = dividerColor
        this.bubbleOutColor = bubbleOutColor
        this.bubbleInColor = bubbleInColor
        this.navBarColor = navBarColor
        this.chatFontSize = chatFontSize
        this.listsFontSize = listsFontSize
        this.useSystemFont = useSystemFont
        this.chatBackgroundPath = chatBackgroundPath
        this.autoNightModeTriggered = autoNightModeTriggered
        this.animationEnabled = animationEnabled
        this.systemColorMode = systemColorMode
        this.itemHighlightedBackgroundColor = itemHighlightedBackgroundColor
        this.itemSelectedBackgroundColor = itemSelectedBackgroundColor
        this.pinnedItemBackgroundColor = pinnedItemBackgroundColor
        this.bubbleStrokeColor = bubbleStrokeColor
        this.freeformBubbleColor = freeformBubbleColor
        this.disclosureArrowColor = disclosureArrowColor
        this.contextMenuBackgroundColor = contextMenuBackgroundColor
        this.contextMenuPrimaryColor = contextMenuPrimaryColor
        this.contextMenuDestructiveColor = contextMenuDestructiveColor
        this.contextMenuSeparatorColor = contextMenuSeparatorColor
        this.contextMenuDimColor = contextMenuDimColor
    }

    // ==================== withUpdated<X> — the only mutation surface ====================
    // No in-place setters: every one of these returns a *new* PresentationSnapshot.

    // F-B3 (diag-suite_settings_root-TC-0507-round5.md §7 F-B3): this used to just relabel the
    // `theme` tag field and keep every colour verbatim from `this` — a real theme switch never
    // recomputed anything, which is the documented root cause of
    // pages/ChatQrCodeSharePage.cj:746 previewSheetColors()'s two parameters going unused (its
    // caller passes a theme index that this method used to silently ignore). Now recomputes
    // `isDark` and the whole colour table for the *new* theme via the same pure entry points
    // computeSnapshot() itself uses (resolveIsDark()/resolveThemeColorTable()) — using only
    // `this`'s own already-captured fields (`autoNightModeTriggered`, `systemColorMode`), so this
    // stays a pure method with no global-state read, consistent with the rest of this
    // withUpdated<X> family.
    public func withUpdatedTheme(theme: Int32): PresentationSnapshot {
        let newIsDark = resolveIsDark(theme, this.autoNightModeTriggered, this.systemColorMode)
        let colors = resolveThemeColorTable(theme, newIsDark)
        return PresentationSnapshot(theme, newIsDark,
            colors.backgroundColor, colors.cardColor, colors.textColor, colors.secondaryTextColor,
            this.accentColor, colors.dividerColor, colors.bubbleOutColor, colors.bubbleInColor,
            colors.navBarColor, this.chatFontSize,
            this.listsFontSize, this.useSystemFont, this.chatBackgroundPath,
            this.autoNightModeTriggered, this.animationEnabled, this.systemColorMode,
            colors.itemHighlightedBackgroundColor, colors.itemSelectedBackgroundColor,
            colors.pinnedItemBackgroundColor, colors.bubbleStrokeColor,
            colors.freeformBubbleColor, colors.disclosureArrowColor,
            colors.contextMenuBackgroundColor, colors.contextMenuPrimaryColor,
            colors.contextMenuDestructiveColor, colors.contextMenuSeparatorColor,
            colors.contextMenuDimColor)
    }

    public func withUpdatedAccentColor(accentColor: UInt32): PresentationSnapshot {
        return PresentationSnapshot(this.theme, this.isDark, this.backgroundColor, this.cardColor,
            this.textColor, this.secondaryTextColor, accentColor, this.dividerColor,
            this.bubbleOutColor, this.bubbleInColor, this.navBarColor, this.chatFontSize,
            this.listsFontSize, this.useSystemFont, this.chatBackgroundPath,
            this.autoNightModeTriggered, this.animationEnabled, this.systemColorMode,
            this.itemHighlightedBackgroundColor, this.itemSelectedBackgroundColor,
            this.pinnedItemBackgroundColor, this.bubbleStrokeColor,
            this.freeformBubbleColor, this.disclosureArrowColor,
            this.contextMenuBackgroundColor, this.contextMenuPrimaryColor,
            this.contextMenuDestructiveColor, this.contextMenuSeparatorColor,
            this.contextMenuDimColor)
    }

    public func withUpdatedChatFontSize(chatFontSize: Int32): PresentationSnapshot {
        return PresentationSnapshot(this.theme, this.isDark, this.backgroundColor, this.cardColor,
            this.textColor, this.secondaryTextColor, this.accentColor, this.dividerColor,
            this.bubbleOutColor, this.bubbleInColor, this.navBarColor, chatFontSize,
            this.listsFontSize, this.useSystemFont, this.chatBackgroundPath,
            this.autoNightModeTriggered, this.animationEnabled, this.systemColorMode,
            this.itemHighlightedBackgroundColor, this.itemSelectedBackgroundColor,
            this.pinnedItemBackgroundColor, this.bubbleStrokeColor,
            this.freeformBubbleColor, this.disclosureArrowColor,
            this.contextMenuBackgroundColor, this.contextMenuPrimaryColor,
            this.contextMenuDestructiveColor, this.contextMenuSeparatorColor,
            this.contextMenuDimColor)
    }

    public func withUpdatedListsFontSize(listsFontSize: Int32): PresentationSnapshot {
        return PresentationSnapshot(this.theme, this.isDark, this.backgroundColor, this.cardColor,
            this.textColor, this.secondaryTextColor, this.accentColor, this.dividerColor,
            this.bubbleOutColor, this.bubbleInColor, this.navBarColor, this.chatFontSize,
            listsFontSize, this.useSystemFont, this.chatBackgroundPath,
            this.autoNightModeTriggered, this.animationEnabled, this.systemColorMode,
            this.itemHighlightedBackgroundColor, this.itemSelectedBackgroundColor,
            this.pinnedItemBackgroundColor, this.bubbleStrokeColor,
            this.freeformBubbleColor, this.disclosureArrowColor,
            this.contextMenuBackgroundColor, this.contextMenuPrimaryColor,
            this.contextMenuDestructiveColor, this.contextMenuSeparatorColor,
            this.contextMenuDimColor)
    }

    public func withUpdatedUseSystemFont(useSystemFont: Bool): PresentationSnapshot {
        return PresentationSnapshot(this.theme, this.isDark, this.backgroundColor, this.cardColor,
            this.textColor, this.secondaryTextColor, this.accentColor, this.dividerColor,
            this.bubbleOutColor, this.bubbleInColor, this.navBarColor, this.chatFontSize,
            this.listsFontSize, useSystemFont, this.chatBackgroundPath,
            this.autoNightModeTriggered, this.animationEnabled, this.systemColorMode,
            this.itemHighlightedBackgroundColor, this.itemSelectedBackgroundColor,
            this.pinnedItemBackgroundColor, this.bubbleStrokeColor,
            this.freeformBubbleColor, this.disclosureArrowColor,
            this.contextMenuBackgroundColor, this.contextMenuPrimaryColor,
            this.contextMenuDestructiveColor, this.contextMenuSeparatorColor,
            this.contextMenuDimColor)
    }

    public func withUpdatedChatBackgroundPath(chatBackgroundPath: String): PresentationSnapshot {
        return PresentationSnapshot(this.theme, this.isDark, this.backgroundColor, this.cardColor,
            this.textColor, this.secondaryTextColor, this.accentColor, this.dividerColor,
            this.bubbleOutColor, this.bubbleInColor, this.navBarColor, this.chatFontSize,
            this.listsFontSize, this.useSystemFont, chatBackgroundPath,
            this.autoNightModeTriggered, this.animationEnabled, this.systemColorMode,
            this.itemHighlightedBackgroundColor, this.itemSelectedBackgroundColor,
            this.pinnedItemBackgroundColor, this.bubbleStrokeColor,
            this.freeformBubbleColor, this.disclosureArrowColor,
            this.contextMenuBackgroundColor, this.contextMenuPrimaryColor,
            this.contextMenuDestructiveColor, this.contextMenuSeparatorColor,
            this.contextMenuDimColor)
    }

    public func withUpdatedAutoNightModeTriggered(autoNightModeTriggered: Bool): PresentationSnapshot {
        return PresentationSnapshot(this.theme, this.isDark, this.backgroundColor, this.cardColor,
            this.textColor, this.secondaryTextColor, this.accentColor, this.dividerColor,
            this.bubbleOutColor, this.bubbleInColor, this.navBarColor, this.chatFontSize,
            this.listsFontSize, this.useSystemFont, this.chatBackgroundPath,
            autoNightModeTriggered, this.animationEnabled, this.systemColorMode,
            this.itemHighlightedBackgroundColor, this.itemSelectedBackgroundColor,
            this.pinnedItemBackgroundColor, this.bubbleStrokeColor,
            this.freeformBubbleColor, this.disclosureArrowColor,
            this.contextMenuBackgroundColor, this.contextMenuPrimaryColor,
            this.contextMenuDestructiveColor, this.contextMenuSeparatorColor,
            this.contextMenuDimColor)
    }

    public func withUpdatedAnimationEnabled(animationEnabled: Bool): PresentationSnapshot {
        return PresentationSnapshot(this.theme, this.isDark, this.backgroundColor, this.cardColor,
            this.textColor, this.secondaryTextColor, this.accentColor, this.dividerColor,
            this.bubbleOutColor, this.bubbleInColor, this.navBarColor, this.chatFontSize,
            this.listsFontSize, this.useSystemFont, this.chatBackgroundPath,
            this.autoNightModeTriggered, animationEnabled, this.systemColorMode,
            this.itemHighlightedBackgroundColor, this.itemSelectedBackgroundColor,
            this.pinnedItemBackgroundColor, this.bubbleStrokeColor,
            this.freeformBubbleColor, this.disclosureArrowColor,
            this.contextMenuBackgroundColor, this.contextMenuPrimaryColor,
            this.contextMenuDestructiveColor, this.contextMenuSeparatorColor,
            this.contextMenuDimColor)
    }

    public func withUpdatedSystemColorMode(systemColorMode: Int32): PresentationSnapshot {
        return PresentationSnapshot(this.theme, this.isDark, this.backgroundColor, this.cardColor,
            this.textColor, this.secondaryTextColor, this.accentColor, this.dividerColor,
            this.bubbleOutColor, this.bubbleInColor, this.navBarColor, this.chatFontSize,
            this.listsFontSize, this.useSystemFont, this.chatBackgroundPath,
            this.autoNightModeTriggered, this.animationEnabled, systemColorMode,
            this.itemHighlightedBackgroundColor, this.itemSelectedBackgroundColor,
            this.pinnedItemBackgroundColor, this.bubbleStrokeColor,
            this.freeformBubbleColor, this.disclosureArrowColor,
            this.contextMenuBackgroundColor, this.contextMenuPrimaryColor,
            this.contextMenuDestructiveColor, this.contextMenuSeparatorColor,
            this.contextMenuDimColor)
    }

    /**
     * Structural (value) equality used by recomputePresentation()'s distinctUntilChanged gate —
     * 对位源侧 Signal 管线上的 `|> distinctUntilChanged`. A recompute that lands on an
     * identical snapshot must NOT bump the broadcast version.
     */
    public func equalsTo(other: PresentationSnapshot): Bool {
        return this.theme == other.theme &&
            this.isDark == other.isDark &&
            this.backgroundColor == other.backgroundColor &&
            this.cardColor == other.cardColor &&
            this.textColor == other.textColor &&
            this.secondaryTextColor == other.secondaryTextColor &&
            this.accentColor == other.accentColor &&
            this.dividerColor == other.dividerColor &&
            this.bubbleOutColor == other.bubbleOutColor &&
            this.bubbleInColor == other.bubbleInColor &&
            this.navBarColor == other.navBarColor &&
            this.chatFontSize == other.chatFontSize &&
            this.listsFontSize == other.listsFontSize &&
            this.useSystemFont == other.useSystemFont &&
            this.chatBackgroundPath == other.chatBackgroundPath &&
            this.autoNightModeTriggered == other.autoNightModeTriggered &&
            this.animationEnabled == other.animationEnabled &&
            this.systemColorMode == other.systemColorMode &&
            this.itemHighlightedBackgroundColor == other.itemHighlightedBackgroundColor &&
            this.itemSelectedBackgroundColor == other.itemSelectedBackgroundColor &&
            this.pinnedItemBackgroundColor == other.pinnedItemBackgroundColor &&
            this.bubbleStrokeColor == other.bubbleStrokeColor &&
            this.freeformBubbleColor == other.freeformBubbleColor &&
            this.disclosureArrowColor == other.disclosureArrowColor &&
            this.contextMenuBackgroundColor == other.contextMenuBackgroundColor &&
            this.contextMenuPrimaryColor == other.contextMenuPrimaryColor &&
            this.contextMenuDestructiveColor == other.contextMenuDestructiveColor &&
            this.contextMenuSeparatorColor == other.contextMenuSeparatorColor &&
            this.contextMenuDimColor == other.contextMenuDimColor
    }
}

// ==================== System colour mode input (TC-0402 F1) ====================
// Mirrors @ohos.app.ability.ConfigurationConstant.ColorMode ordinals exactly, so the eventual
// Ability-layer caller (see F5 contract's Ability sub-item) can pass config.colorMode straight
// through with no translation:
//   COLOR_MODE_NOT_SET = -1, COLOR_MODE_DARK = 0, COLOR_MODE_LIGHT = 1.
public let COLOR_MODE_NOT_SET: Int32 = -1
public let COLOR_MODE_DARK: Int32 = 0
public let COLOR_MODE_LIGHT: Int32 = 1

// ==================== P2-009: Theme broadcast key ====================
// Any component subscribing via @StorageLink["themeVersion"] receives UI refresh when
// recomputePresentation() bumps this. Declared here (top of file) because Cangjie top-level
// `let` constants must be defined before any use, and publishPresentation()/initThemeBroadcast()
// below both reference it.
public let THEME_VERSION_KEY: String = "themeVersion"

// COLOR_MODE_NOT_SET is treated as light (spec requirement) — default starts at NOT_SET, which
// already resolves to light via resolveIsDark()'s `systemColorMode == COLOR_MODE_DARK` comparison
// (F-B3 extraction; formerly a local isSystemColorModeDark() helper), so no separate "unknown"
// branch is needed at the call sites.
var _systemColorMode: Int32 = COLOR_MODE_NOT_SET

// Mirrors @ohos.app.ability.Configuration.fontSizeScale (1.0 = no scaling). Same cold-start /
// callback-channel shape as _systemColorMode; see setSystemFontScale().
var _systemFontScale: Float64 = 1.0

/**
 * Ability-layer input hook: call once at cold start (reading `context.config.colorMode`) and again
 * from `onConfigurationUpdate`. Not called from anywhere in this feature's allowlist today — the
 * Ability file is owned by another feature; see this feature's `ic_presentation_snapshot_consumption`
 * contract's Ability sub-item for the wiring recipe. Safe to call before initAppTheme(): it just
 * records the mode and (re)computes; whichever of the two runs last wins, so ordering is not load-bearing.
 */
public func setSystemColorMode(mode: Int32): Unit {
    _systemColorMode = mode
    let _ = recomputePresentation()
    Hilog.info(0, "CjTelegram", "[AppTheme] setSystemColorMode(${mode})")
}

/**
 * Ability-layer input hook for the system font-size scale (对位 iOS 系统字号，TC-0404 F4
 * resolveFontSize() 的 useSystemFont 分支). Same wiring status as setSystemColorMode().
 */
public func setSystemFontScale(scale: Float64): Unit {
    _systemFontScale = scale
    let _ = recomputePresentation()
    Hilog.info(0, "CjTelegram", "[AppTheme] setSystemFontScale(${scale})")
}

// Base chat font size used to scale the "system font" branch of resolveFontSize() — matches the
// existing default persisted textSize (16, see AuthStorage.getAppearanceTextSize()).
let BASE_FONT_SIZE: Int32 = 16

/**
 * 对位 PresentationData.swift:846-858 resolveFontSize(settings:). useSystemFont 为真时两个量
 * 相等且由系统字号缩放解出；为假时分别取用户设定值。
 */
func resolveFontSize(useSystemFont: Bool, userChatFontSize: Int32, userListsFontSize: Int32): (Int32, Int32) {
    if (useSystemFont) {
        let scaled = Int32(Float64(BASE_FONT_SIZE) * _systemFontScale)
        return (scaled, scaled)
    }
    return (userChatFontSize, userListsFontSize)
}

/**
 * The size resolveFontSize() yields for useSystemFont == true. The Text Size screen previews at
 * this size while its "Use System Text Size" switch is on (TextSizeSelectionController.swift:547-557
 * builds PresentationFontSize(systemFontSize:) instead of the stored fontSize in that case).
 */
public func systemResolvedFontSize(): Int32 {
    let (chat, _) = resolveFontSize(true, BASE_FONT_SIZE, BASE_FONT_SIZE)
    return chat
}

// ==================== Cross-package input gathering (no import cycle) ====================
// recomputePresentation() needs a few inputs that are only available in the services layer
// (account-scoped accent colour, useSystemFont, listsFontSize, the auto-night trigger
// evaluation) — but services/ThemesEngineService.cj already imports this package (for
// getAppTheme), so a direct `import ohos_app_cangjie_entry.services.*` here would create a
// cyclic package dependency that cjpm build rejects outright ("cyclic dependency:
// ohos_app_cangjie_entry.core.storage -> ohos_app_cangjie_entry.services /
// ohos_app_cangjie_entry.services -> ohos_app_cangjie_entry.core.storage").
// Fix: dependency inversion via a registered provider callback. services/ThemesEngineService.cj
// registers itself once (see getThemesEngineService()'s first-construction branch); this package
// never references the services package by name.

public class PresentationExtras {
    public let accentColor: UInt32
    public let customBubbleColor: UInt32
    public let useSystemFont: Bool
    public let listsFontSize: Int32
    public let autoNightModeTriggered: Bool
    public let autoNightThemePreset: Int32
    /** S7-106：已应用云主题的配色设置（None = 内建主题）。 */
    public let cloudTheme: Option<CloudThemeColorSettings>

    public init(accentColor: UInt32, customBubbleColor: UInt32, useSystemFont: Bool, listsFontSize: Int32,
        autoNightModeTriggered: Bool, autoNightThemePreset!: Int32 = 3,
        cloudTheme!: Option<CloudThemeColorSettings> = None) {
        this.accentColor = accentColor
        this.customBubbleColor = customBubbleColor
        this.useSystemFont = useSystemFont
        this.listsFontSize = listsFontSize
        this.autoNightModeTriggered = autoNightModeTriggered
        this.autoNightThemePreset = autoNightThemePreset
        this.cloudTheme = cloudTheme
    }
}

// Provider takes the current system colour mode as input (needed for the auto-night "system"
// trigger, TC-0402 F3) — passed explicitly rather than exposing _systemColorMode as a public
// getter, keeping the cross-package surface to exactly one function type.
var _extrasProvider: Option<(Int32) -> PresentationExtras> = None

/**
 * Called once by services/ThemesEngineService.cj when its singleton is first constructed.
 * Until that first call happens, recomputePresentation() falls back to defaults (0x0088FF
 * accent, useSystemFont=false, listsFontSize=16, autoNightModeTriggered=false) — and the
 * auto-night 1s evaluator (started inside that same construction branch) never starts either.
 *
 * This is NOT momentarily stale — round-1 review (behavioral_repro #5) traced every cold-start
 * call path and found none of MainTabPage/ChatListPage or anything MainTabPage.build() mounts
 * calls getThemesEngineService(); providers/ThemesDataProvider.cj (the one file in this
 * feature's own allowlist that could force construction) has zero instantiation sites anywhere
 * (dead code). So for a user who only ever browses the default tabs — never opening
 * AppearanceSettingsPage, a ChatRoomPage, EditProfilePage, ProfileColorPage,
 * ChatQrCodeSharePage, or WallpaperPickerPage — this provider stays unregistered, and the
 * fallback defaults above serve for the app's *entire session*, silently wrong for any user
 * with a non-default accent/font-size/auto-night setting. core/storage cannot fix this itself:
 * calling getThemesEngineService() from anywhere in this package would create the cyclic
 * package dependency described in the "Cross-package input gathering" section above. See this
 * feature's emitted `ic_themes_engine_cold_start_bootstrap` contract (routed to uif_tabbarui,
 * the owner of pages/MainTabPage.cj) for the required fix outside this feature's allowlist.
 */
public func registerPresentationExtrasProvider(provider: (Int32) -> PresentationExtras): Unit {
    _extrasProvider = provider
}

func gatherPresentationExtras(systemColorMode: Int32): PresentationExtras {
    match (_extrasProvider) {
        case Some(provider) => return provider(systemColorMode)
        case None => return PresentationExtras(0x0088FF, 0, false, BASE_FONT_SIZE, false)
    }
}

/**
 * Global AppTheme singleton — legacy mutable shell kept only so call sites outside this feature's
 * allowlist (pages/AppearanceSettingsPage.cj, services/TelegramCoreSettingsService.cj,
 * pages/GraphPage.cj) keep compiling unchanged. It no longer holds derived colours or font size as
 * authoritative state: those live exclusively on PresentationSnapshot (see recomputePresentation()
 * below). Fields that remain here are either read directly by those external call sites
 * (`theme`) or written directly by them as a legacy side effect that this feature's Worker cannot
 * remove without editing files outside its allowlist (`textSize`, `animationEnabled`,
 * `chatBackgroundPath`, `accentColor`) — those writes are now harmless no-ops from the snapshot's
 * point of view, since the snapshot is rebuilt from persisted storage on every recompute, not from
 * these fields. `accentColor` in particular used to be part of the old "applyTheme then patch
 * accentColor back on" two-step (pages/AppearanceSettingsPage.cj:256-257); the patch's write
 * target still has to exist for that file to compile, but nothing reads it anymore — the snapshot's
 * accentColor is solved from persisted state inside recomputePresentation() itself (see F1's doc
 * on that class), which is exactly the single-pass replacement for what this write used to
 * approximate.
 */
public class AppTheme {
    public var theme: Int32 = 0
    public var textSize: Int32 = 16
    public var animationEnabled: Bool = true
    public var powerSavingEnabled: Bool = false
    // "" = default, non-empty = custom file path
    public var chatBackgroundPath: String = ""
    // Filesystem path of the extracted default rawfile background
    public var defaultChatBgPath: String = ""
    // Legacy write-only field — see class doc. Not read anywhere; kept only so
    // pages/AppearanceSettingsPage.cj:257's field write keeps compiling.
    public var accentColor: UInt32 = 0x0088FF

    /**
     * Legacy in-place API kept only for source compatibility with external callers
     * (pages/AppearanceSettingsPage.cj:255, services/TelegramCoreSettingsService.cj:92) that this
     * feature's Worker cannot edit (outside allowlist). The colour-table if/else that used to live
     * here has been deleted — that whole computation now happens once, inside
     * recomputePresentation()'s single pass. This method only updates the legacy `theme` field
     * (still read directly by pages/GraphPage.cj:400) and triggers a recompute.
     */
    public func applyTheme(t: Int32): Unit {
        this.theme = t
        let _ = recomputePresentation()
    }
}

// ==================== Global singleton (legacy shell) ====================

var _appTheme: AppTheme = AppTheme()

public func getAppTheme(): AppTheme {
    return _appTheme
}

// ==================== Colour derivation helpers ====================
// Supports bubbleStrokeColor's derivation (see PresentationSnapshot's field doc and
// ic_message_bubble_stroke_color_snapshot). Plain HSB math, no ArkUI Color dependency — mirrors
// UIKitUtils.swift's withMultiplied(hue:saturation:brightness:) (getHue/UIColor(hue:...) round
// trip) closely enough for this single call site; not a general-purpose colour utility.

func clamp01(x: Float64): Float64 {
    return max(0.0, min(1.0, x))
}

// Standard RGB -> HSB. r/g/b each in [0,1]. Returns (hue, saturation, brightness), hue in [0,1]
// (i.e. already divided by 360, matching UIColor(hue:saturation:brightness:alpha:)'s convention).
func rgbToHsv(r: Float64, g: Float64, b: Float64): (Float64, Float64, Float64) {
    let maxC = max(r, max(g, b))
    let minC = min(r, min(g, b))
    let delta = maxC - minC
    var hueDeg: Float64 = 0.0
    if (delta > 0.0) {
        if (maxC == r) {
            var t = (g - b) / delta
            if (t < 0.0) {
                t = t + 6.0
            }
            hueDeg = 60.0 * t
        } else if (maxC == g) {
            hueDeg = 60.0 * ((b - r) / delta + 2.0)
        } else {
            hueDeg = 60.0 * ((r - g) / delta + 4.0)
        }
    }
    var sat = 0.0
    if (maxC > 0.0) {
        sat = delta / maxC
    }
    return (hueDeg / 360.0, sat, maxC)
}

// Inverse of rgbToHsv. h/s/v each in [0,1]. Returns (r, g, b), each in [0,1].
func hsvToRgb(h: Float64, s: Float64, v: Float64): (Float64, Float64, Float64) {
    let hh = h * 6.0
    let c = v * s
    let regionFloat = floor(hh)
    let frac = hh - regionFloat
    var region = Int64(regionFloat) % 6
    if (region < 0) {
        region = region + 6
    }
    var x = c * frac
    if (region % 2 == 1) {
        x = c * (1.0 - frac)
    }
    var r1 = 0.0
    var g1 = 0.0
    var b1 = 0.0
    if (region == 0) {
        r1 = c
        g1 = x
    } else if (region == 1) {
        r1 = x
        g1 = c
    } else if (region == 2) {
        g1 = c
        b1 = x
    } else if (region == 3) {
        g1 = x
        b1 = c
    } else if (region == 4) {
        r1 = x
        b1 = c
    } else {
        r1 = c
        b1 = x
    }
    let m = v - c
    return (r1 + m, g1 + m, b1 + m)
}

// 对位源侧 UIColor.withMultiplied(hue: 0.999, saturation: 1.667, brightness: 1.1)
// .withAlphaComponent(0.2)（DefaultDayPresentationTheme.swift:161-163, the `customizeDefaultDayTheme`
// custom-accent-colour path — NOT the plain `.dayClassic`/`.night` defaults this codebase's two
// reachable themes use; see PresentationSnapshot's bubbleStrokeColor field doc). `baseRgb` is a
// 24-bit (no alpha byte, or alpha byte ignored) 0xRRGGBB colour. Returns a 0xAARRGGBB value with
// alpha fixed at 0.2 (0x33/255), matching this codebase's existing ARGB convention for translucent
// UInt32 colours (e.g. components/MessageBubble.cj's 0x60000000/0x80000000 literals) — never
// 0x00xxxxxx, which alphaAdapt would force opaque (D-175). Not called by computeSnapshot() /
// defaultPresentationSnapshot() as of ic_message_bubble_stroke_color_theme_values (both of this
// codebase's reachable themes use a fixed literal instead, see PresentationSnapshot's
// bubbleStrokeColor field doc) — kept for a possible future `day: true` "Day" theme variant.
func deriveBubbleStrokeColor(baseRgb: UInt32): UInt32 {
    let r = Float64((baseRgb >> 16) & 0xFFu32) / 255.0
    let g = Float64((baseRgb >> 8) & 0xFFu32) / 255.0
    let b = Float64(baseRgb & 0xFFu32) / 255.0
    let (h, s, v) = rgbToHsv(r, g, b)
    let h2 = clamp01(h * 0.999)
    let s2 = clamp01(s * 1.667)
    let v2 = clamp01(v * 1.1)
    let (r2, g2, b2) = hsvToRgb(h2, s2, v2)
    let ri = UInt32(clamp01(r2) * 255.0)
    let gi = UInt32(clamp01(g2) * 255.0)
    let bi = UInt32(clamp01(b2) * 255.0)
    return (0x33u32 << 24) | (ri << 16) | (gi << 8) | bi
}

// ==================== Presentation snapshot state ====================

let PRESENTATION_KEY: String = "presentation"

// ==================== F-B3 (diag-suite_settings_root-TC-0507-round5.md §4.5 RC-5 / §7 F-B3):
// pure (theme, isDark) -> colour-table entry point ====================
// 对位源侧 makeDefaultPresentationTheme(reference:serviceBackgroundColor:) —— 一个纯函数，给定
// 主题标识 + 已解析的明暗，求出一份完整配色，不读取任何全局/持久化状态。此前 computeSnapshot()
// 把这份色表内联写在自己的函数体里（一段 var + `if (isDark) {...}`），没有独立可调用的入口；
// withUpdatedTheme() 因此也没法在不重复整段逻辑的前提下换一个主题重算色表，只能原样保留旧色——
// diag TC-0507-round5 §4.5 点名这是 ChatQrCodeSharePage.cj:746 previewSheetColors() 两个形参被
// 弃用、夜间态 sheet 恒白的直接原因；pages/ThemePreviewPage.cj 类头文档也独立记录了同一缺口
// （"全仓无『给定 (theme,isDark) 纯函数求色』的入口"）。
//
// 这里只是把已有色表的取值路径参数化，不新增第二套色表：下面 defaultPresentationSnapshot() 与
// computeSnapshot() 均改为调用这一个入口，不再各自内联/重复一份字面量（round5 之前两处字面量恰好
// 逐值相等，这不是巧合——它们本就是同一张浅色默认表，现在只有一份代码）。
//
// `theme` 形参沿用 PresentationSnapshot.theme 的既有取值域（0=Light/1=Dark/2=System 的持久化
// 选择器），与 THEME_KIND_*（themeIconColors() 用的四个内置主题身份：dayClassic/nightAccent/
// day/night）是不同的域，调用方不要混用。该表当前只按 isDark 分支（本仓库两个可达主题——
// .dayClassic 与 .night——的关系已在 PresentationSnapshot.bubbleStrokeColor 字段文档详述），
// `theme` 形参当前不改变输出：保留在签名里是让调用方显式声明"这份色表是给哪个持久化主题选择器
// 算的"，并为未来真正按 theme 分支的色表变化留出参数位；不得据此在 dark 分支按明度反转拟合出
// 第二套数值（深色档取值须以 DefaultDarkPresentationTheme.swift 为准，该退化本仓已有过一次记录）。
public class ThemeColorTable {
    public let backgroundColor: UInt32
    public let cardColor: UInt32
    public let textColor: UInt32
    public let secondaryTextColor: UInt32
    public let dividerColor: UInt32
    public let bubbleOutColor: UInt32
    public let bubbleInColor: UInt32
    public let navBarColor: UInt32
    public let itemHighlightedBackgroundColor: UInt32
    public let itemSelectedBackgroundColor: UInt32
    public let pinnedItemBackgroundColor: UInt32
    public let bubbleStrokeColor: UInt32
    public let freeformBubbleColor: UInt32
    public let disclosureArrowColor: UInt32
    public let contextMenuBackgroundColor: UInt32
    public let contextMenuPrimaryColor: UInt32
    public let contextMenuDestructiveColor: UInt32
    public let contextMenuSeparatorColor: UInt32
    public let contextMenuDimColor: UInt32

    public init(
        backgroundColor: UInt32,
        cardColor: UInt32,
        textColor: UInt32,
        secondaryTextColor: UInt32,
        dividerColor: UInt32,
        bubbleOutColor: UInt32,
        bubbleInColor: UInt32,
        navBarColor: UInt32,
        itemHighlightedBackgroundColor: UInt32,
        itemSelectedBackgroundColor: UInt32,
        pinnedItemBackgroundColor: UInt32,
        bubbleStrokeColor: UInt32,
        freeformBubbleColor: UInt32,
        disclosureArrowColor: UInt32,
        contextMenuBackgroundColor: UInt32,
        contextMenuPrimaryColor: UInt32,
        contextMenuDestructiveColor: UInt32,
        contextMenuSeparatorColor: UInt32,
        contextMenuDimColor: UInt32
    ) {
        this.backgroundColor = backgroundColor
        this.cardColor = cardColor
        this.textColor = textColor
        this.secondaryTextColor = secondaryTextColor
        this.dividerColor = dividerColor
        this.bubbleOutColor = bubbleOutColor
        this.bubbleInColor = bubbleInColor
        this.navBarColor = navBarColor
        this.itemHighlightedBackgroundColor = itemHighlightedBackgroundColor
        this.itemSelectedBackgroundColor = itemSelectedBackgroundColor
        this.pinnedItemBackgroundColor = pinnedItemBackgroundColor
        this.bubbleStrokeColor = bubbleStrokeColor
        this.freeformBubbleColor = freeformBubbleColor
        this.disclosureArrowColor = disclosureArrowColor
        this.contextMenuBackgroundColor = contextMenuBackgroundColor
        this.contextMenuPrimaryColor = contextMenuPrimaryColor
        this.contextMenuDestructiveColor = contextMenuDestructiveColor
        this.contextMenuSeparatorColor = contextMenuSeparatorColor
        this.contextMenuDimColor = contextMenuDimColor
    }
}

/**
 * 纯函数：给定持久化主题选择器 `theme` + 已解析的明暗标志 `isDark`，求出一份完整配色表。不读取
 * `_currentPresentation` / Preferences / AppStorage 等任何全局或持久化状态——两次相同实参调用恒
 * 返回相等结果。数值逐字保留自 round5 之前 computeSnapshot() 内联的取值（浅色默认值 + isDark
 * 分支覆盖，各字段来源见该分支原有的逐行 source-truth 注释，未随本次抽取改变），只是把它抽成一个
 * 可独立调用的入口。
 */
public func resolveThemeColorTable(theme: Int32, isDark: Bool): ThemeColorTable {
    var backgroundColor: UInt32 = 0xF2F2F7
    var cardColor: UInt32 = 0xFFFFFF
    var textColor: UInt32 = 0x000000
    var secondaryTextColor: UInt32 = 0x8E8E93
    var dividerColor: UInt32 = 0xE5E5EA
    var bubbleOutColor: UInt32 = 0xE8F5E9
    var bubbleInColor: UInt32 = 0xF0F0F0
    var navBarColor: UInt32 = 0xFFFFFF
    var itemHighlightedBackgroundColor: UInt32 = 0xE5E5EA
    var itemSelectedBackgroundColor: UInt32 = 0xE9F0FA
    var pinnedItemBackgroundColor: UInt32 = 0xF7F7F7
    var freeformBubbleColor: UInt32 = 0xE5E5EA
    var disclosureArrowColor: UInt32 = 0xBAB9BE
    var contextMenuBackgroundColor: UInt32 = 0xC7F9F9F9
    var contextMenuPrimaryColor: UInt32 = 0xFF000000
    var contextMenuDestructiveColor: UInt32 = 0xFFFF3B30
    var contextMenuSeparatorColor: UInt32 = 0x333C3C43
    var contextMenuDimColor: UInt32 = 0x33000A26
    // .dayClassic fixed literal, see PresentationSnapshot.bubbleStrokeColor field doc.
    var bubbleStrokeColor: UInt32 = 0x33000000
    if (isDark) {
        // list.blocksBackgroundColor / list.itemBlocksBackgroundColor (non-modal tokens) — see
        // PresentationSnapshot's original inline comment (now here) for the modal-token mixup
        // this replaced (diag-suite_settings_appearance-TC-0402-round13.md F-2).
        backgroundColor = 0x000000
        cardColor = 0x1C1C1D
        // .night's bubble stroke is `.clear` on every incoming/outgoing x wallpaper combination —
        // top byte 0x00 tells drawBubbleCanvas() to skip the outline pass entirely (deliberate
        // sentinel, not the D-175 alphaAdapt trap; see PresentationSnapshot field doc).
        bubbleStrokeColor = 0x00000000
        textColor = 0xFFFFFF
        secondaryTextColor = 0xAEAEB2
        dividerColor = 0x38383A
        // Dark outgoing/incoming bubble fill from source's `.night` theme (not a lightness-inverted
        // copy of the light bubble colours — see PresentationSnapshot field doc, TC-0402 round9 RC-4).
        bubbleOutColor = 0x0088FF
        bubbleInColor = 0x1D1D1D
        navBarColor = 0x1C1C1E
        itemHighlightedBackgroundColor = 0x121212
        itemSelectedBackgroundColor = 0x191919
        pinnedItemBackgroundColor = 0x1C1C1D
        freeformBubbleColor = 0x1F1F1F
        disclosureArrowColor = 0x47FFFFFF
        contextMenuBackgroundColor = 0xC7252525
        contextMenuPrimaryColor = 0xFFFFFFFF
        contextMenuDestructiveColor = 0xFFEB5545
        contextMenuSeparatorColor = 0x26FFFFFF
        contextMenuDimColor = 0x99000000
    }
    return ThemeColorTable(backgroundColor, cardColor, textColor, secondaryTextColor,
        dividerColor, bubbleOutColor, bubbleInColor, navBarColor,
        itemHighlightedBackgroundColor, itemSelectedBackgroundColor,
        pinnedItemBackgroundColor, bubbleStrokeColor, freeformBubbleColor, disclosureArrowColor,
        contextMenuBackgroundColor, contextMenuPrimaryColor, contextMenuDestructiveColor,
        contextMenuSeparatorColor, contextMenuDimColor)
}

/**
 * 纯函数：给定持久化主题选择器、自动夜间是否已触发、系统深浅色模式，求出生效的 `isDark` 标志。
 * 逐字对位 round5 之前 computeSnapshot() 内联的同一段 if/else（数值/分支未改变，只是抽成可从
 * `PresentationSnapshot.withUpdatedTheme()`（该方法只有 `this` 上已有的字段可用，没有全局状态）
 * 复用的独立入口）。
 */
func resolveIsDark(theme: Int32, autoNightTriggered: Bool, systemColorMode: Int32): Bool {
    if (autoNightTriggered) {
        return true
    }
    if (theme == 1) {
        return true
    }
    if (theme == 2) {
        return systemColorMode == COLOR_MODE_DARK
    }
    return false
}

/**
 * 公开纯函数入口：给定持久化主题选择器 + 已解析的明暗标志，直接求出一份完整
 * `PresentationSnapshot`——对位源侧 `makeDefaultPresentationTheme(reference:serviceBackgroundColor:)`
 * / `makePresentationTheme(cloudTheme:dark:)`，不读取 `_currentPresentation` / Preferences /
 * AppStorage / `_extrasProvider` 等任何全局或持久化状态，适合"预览某个主题在给定明暗下长什么样"
 * 这类不应该、也不需要触碰当前生效主题的调用方（如 pages/ThemePreviewPage.cj 类头文档记录的缺口——
 * 该文件不在本 feature allowlist，接线留给其 owner）。
 *
 * 配色部分来自 `resolveThemeColorTable()`；`accentColor`/字号/`chatBackgroundPath`/
 * `animationEnabled`/`systemColorMode` 等与"当前账号持久化设置/系统状态"绑定的量此处取与
 * round5 之前 `defaultPresentationSnapshot()` 完全相同的编译期默认值，逐字不改（那些量不是
 * "给定 (theme,isDark) 能推出"的纯函数输入，读取真实状态会让这个入口不再是纯函数；`systemColorMode`
 * 尤其不能按 `isDark` 折算——`isDark` 在这里是调用方显式传入的已解析结果，可能来自
 * autoNightModeTriggered 而非系统深浅色模式本身，两者不是同一件事，折算会污染
 * `PresentationSnapshot.equalsTo()` 的比较基线）。`defaultPresentationSnapshot()` 改为直接调用
 * 本函数传 `(0, false)`，返回值与 round5 之前逐字段相等（已按原字面量逐一核对）。
 */
public func resolvePresentationSnapshot(theme: Int32, isDark: Bool): PresentationSnapshot {
    let colors = resolveThemeColorTable(theme, isDark)
    return PresentationSnapshot(
        theme, isDark,
        colors.backgroundColor, colors.cardColor, colors.textColor, colors.secondaryTextColor,
        /* accentColor */ 0x0088FF, colors.dividerColor, colors.bubbleOutColor, colors.bubbleInColor,
        colors.navBarColor,
        /* chatFontSize */ BASE_FONT_SIZE, /* listsFontSize */ BASE_FONT_SIZE, /* useSystemFont */ true,
        /* chatBackgroundPath */ "", /* autoNightModeTriggered */ false, /* animationEnabled */ true,
        /* systemColorMode */ COLOR_MODE_NOT_SET,
        colors.itemHighlightedBackgroundColor, colors.itemSelectedBackgroundColor,
        colors.pinnedItemBackgroundColor, colors.bubbleStrokeColor,
        colors.freeformBubbleColor, colors.disclosureArrowColor,
        colors.contextMenuBackgroundColor, colors.contextMenuPrimaryColor,
        colors.contextMenuDestructiveColor, colors.contextMenuSeparatorColor,
        colors.contextMenuDimColor
    )
}

func defaultPresentationSnapshot(): PresentationSnapshot {
    return resolvePresentationSnapshot(/* theme */ 0, /* isDark */ false)
}

var _currentPresentation: PresentationSnapshot = defaultPresentationSnapshot()

/**
 * Read-only access to the current, already-computed snapshot. This is what the legacy
 * `getAppTheme*()` forwarders below read from; it is also what any consumer added later
 * (per this feature's `ic_presentation_snapshot_consumption` contract) should read via
 * `@StorageLink[PRESENTATION_KEY]` instead of calling this function from build().
 */
public func currentPresentation(): PresentationSnapshot {
    return _currentPresentation
}

/**
 * Pure derivation, no shared-state read/write of `_currentPresentation` (对位
 * PresentationData.swift:725-844 updatedPresentationData's derivation half). Gathers every input
 * in one pass — persisted appearance settings, the system colour mode (§TC-0402 F1), and the
 * auto-night trigger evaluation (§TC-0402 F3) — and produces exactly one new PresentationSnapshot.
 * accentColor is solved here, from theme + the user's persisted accent selection, in this single
 * pass: the old two-step "applyTheme then patch accentColor back on" (formerly
 * pages/AppearanceSettingsPage.cj:256-257) has no equivalent here by construction.
 *
 * Split out of recomputePresentation() (round-2 review D-163/D-168) so resetPresentation() can
 * obtain a freshly-derived snapshot without going through recomputePresentation()'s
 * distinctUntilChanged gate below — an explicit invalidation entry point's job is "publish
 * unconditionally", which is a different contract from "publish only on real change", so the two
 * must not share one gate. See resetPresentation()'s doc for the bug this closes.
 */
// F-B3: this is now a thin shell — "read global state -> call the pure (theme,isDark) colour-
// table entry point -> assemble" — per diag-suite_settings_root-TC-0507-round5.md §7 F-B3. The
// colour-table computation itself moved to resolveThemeColorTable() (values unchanged, only the
// call site moved); this function's own job is now exactly gathering the inputs that function
// cannot see (persisted storage, the services-layer extras, the module-level system colour mode)
// and resolving `isDark` from them via resolveIsDark() (same extraction, same reason).
func computeSnapshot(): PresentationSnapshot {
    let storage = getAuthStorage()
    let themeVal = storage.getAppearanceTheme()
    let userChatFontSize = storage.getAppearanceTextSize()
    let anim = storage.getAnimationEnabled()
    let chatBg = storage.getChatBackground()

    let extras = gatherPresentationExtras(_systemColorMode)
    let userAccent = extras.accentColor
    let customBubbleColor = extras.customBubbleColor
    let useSystemFont = extras.useSystemFont
    let userListsFontSize = extras.listsFontSize
    let autoNightTriggered = extras.autoNightModeTriggered
    let autoNightPreset = extras.autoNightThemePreset

    let isDark = resolveIsDark(themeVal, autoNightTriggered, _systemColorMode)
    let colors = resolveThemeColorTable(themeVal, isDark)
    let (resolvedChatFontSize, resolvedListsFontSize) = resolveFontSize(useSystemFont, userChatFontSize, userListsFontSize)

    // 自动夜间触发时强调色/气泡色取自夜间预设（对位 automaticThemeSwitchSetting.theme）；
    // 否则取用户强调色 + 自定义气泡色（customBubbleColor == 0 表示跟随主题）。
    var effectiveAccent = if (autoNightTriggered) {
        if (autoNightPreset == 1) { 0x2EA6FFu32 } else { 0x3E88F7u32 }
    } else { userAccent }
    let automaticThemeColors = themeIconColors(autoNightPreset)
    var effectiveBubbleOut = if (autoNightTriggered) {
        automaticThemeColors.outgoingBubbleColor
    } else if (customBubbleColor == 0) { colors.bubbleOutColor } else { 0xFF000000 | customBubbleColor }
    var effectiveBubbleIn = if (autoNightTriggered) { automaticThemeColors.incomingBubbleColor } else { colors.bubbleInColor }
    // S7-106：已应用云主题且未被自动夜间预设接管时，强调色与气泡色取自该主题 settings
    // （明暗与生效外观一致时；iOS PresentationThemeSettings.theme = .cloud → makePresentationTheme）。
    if (!autoNightTriggered) {
        match (extras.cloudTheme) {
            case Some(cloud) =>
                if (cloud.isDarkBase() == isDark) {
                    let (a, o, i) = resolveCloudThemeChatColors(cloud, effectiveBubbleOut, effectiveBubbleIn)
                    effectiveAccent = a
                    effectiveBubbleOut = o
                    effectiveBubbleIn = i
                }
            case None => ()
        }
    }

    return PresentationSnapshot(
        themeVal, isDark,
        colors.backgroundColor, colors.cardColor, colors.textColor, colors.secondaryTextColor,
        effectiveAccent, colors.dividerColor,
        effectiveBubbleOut, effectiveBubbleIn, colors.navBarColor,
        resolvedChatFontSize, resolvedListsFontSize, useSystemFont,
        chatBg, autoNightTriggered, anim, _systemColorMode,
        colors.itemHighlightedBackgroundColor, colors.itemSelectedBackgroundColor,
        colors.pinnedItemBackgroundColor, colors.bubbleStrokeColor,
        colors.freeformBubbleColor, colors.disclosureArrowColor,
        colors.contextMenuBackgroundColor, colors.contextMenuPrimaryColor,
        colors.contextMenuDestructiveColor, colors.contextMenuSeparatorColor,
        colors.contextMenuDimColor
    )
}

/**
 * Serializes every read-compare-write of the module-level `_currentPresentation` var (D-157,
 * round-2 review). `launch{}` inside publishPresentation() below only dispatches the eventual
 * AppStorage write to the UI thread — it does nothing for the compare-and-assign one hop earlier,
 * which still runs synchronously on whichever thread calls recomputePresentation()/
 * resetPresentation(). Those are concurrently reachable from the auto-night 1s Timer's
 * background-thread callback (services/ThemesEngineService.cj's startAutoNightTimer()) and from
 * pre-existing bare `spawn{}` call sites outside this feature's allowlist to fix at the call-site
 * end (pages/ChatQrCodeSharePage.cj:118, services/WallpaperBackgroundService.cj:731-746) — two
 * racing recomputes could otherwise interleave on the unsynchronized compare-then-assign and lose
 * an update. This Mutex closes that window.
 */
let _presentationMutex: Mutex = Mutex()

/**
 * Recomputes and, if the result actually differs from the last published snapshot
 * (distinctUntilChanged, 对位源侧 Signal 管线), publishes it — value-equal recomputes never bump
 * the broadcast version. Every caller that wants "make sure the snapshot reflects current
 * storage, but don't force a broadcast if nothing changed" (setSystemColorMode,
 * setSystemFontScale, applyTheme, initAppTheme, notifyThemeChanged, ThemesEngineService's various
 * save-/install- functions) should call this. resetPresentation() below is the one caller that
 * deliberately does not — see its doc for why.
 */
public func recomputePresentation(): PresentationSnapshot {
    // 合并回归修复（S7-105）：computeSnapshot() 也放进互斥区。此前只有 compare-and-assign 被串行化，
    // 自动夜间 1s Timer 线程在设置写入前算出的旧快照可以在 UI 线程发布新快照之后才拿到锁，
    // 把 _currentPresentation/AppStorage 回写成旧值（气泡色停在上一个主题）。
    _presentationMutex.lock()
    let snapshot = computeSnapshot()
    if (!snapshot.equalsTo(_currentPresentation)) {
        _currentPresentation = snapshot
        publishPresentation(snapshot)
    }
    let result = _currentPresentation
    _presentationMutex.unlock()
    return result
}

/**
 * Writes AppStorage[PRESENTATION_KEY] and bumps AppStorage[THEME_VERSION_KEY]. Called from two
 * places, both of which have already decided a publish should happen before calling this:
 * recomputePresentation()'s distinctUntilChanged gate (real changes only) and
 * resetPresentation()'s unconditional invalidation path (D-163/D-168, round-2 review — an
 * explicit invalidation entry point must publish regardless of whether the result differs from
 * whatever was current before, so it does not route through the gate). This function itself does
 * not decide whether to publish; it only performs the write.
 *
 * S-001 (round-1 review reject): this AppStorage write must run on the UI thread, but
 * recomputePresentation() itself — and every function that calls it (setSystemColorMode,
 * setSystemFontScale, applyTheme, initAppTheme, notifyThemeChanged, ThemesEngineService's
 * saveAccentColor / installTheme / getThemesEngineService()'s first-construction branch) — is
 * reachable from pre-existing bare `spawn{}` call sites elsewhere in the codebase
 * (pages/ChatQrCodeSharePage.cj:118, services/WallpaperBackgroundService.cj:731-746) that
 * predate this feature and are outside its allowlist to fix at the call-site end. Rather than
 * requiring every current and future caller to remember to wrap its own call in `launch{}`
 * (D-167: exactly the mistake this file made in round 1 — one call path wrapped, its sibling two
 * lines away was not), the dispatch is centralized here, the single place the actual AppStorage
 * write happens. `launch()` (ohos.base, re-exported by kit.ArkUI — see the `startAutoNightTimer`
 * precedent this was generalized from) posts the task to the UI thread; the rest of
 * recomputePresentation() (Preferences reads, snapshot construction) has no UI-thread
 * requirement and keeps running synchronously on the caller's own thread, same as before. This
 * launch{} only covers the write below; it does not serialize `_currentPresentation` itself —
 * that is `_presentationMutex`'s job (D-157), a separate concern from this function's.
 */
func publishPresentation(snapshot: PresentationSnapshot): Unit {
    launch {
        let _ = AppStorage.setOrCreate<PresentationSnapshot>(PRESENTATION_KEY, snapshot)
        let systemBarPayload = if (snapshot.isDark) { "{\"dark\":true}" } else { "{\"dark\":false}" }
        callArkOnJSTask("appearance.systemBars", systemBarPayload, { _ => () })
        match (AppStorage.get<Int64>(THEME_VERSION_KEY)) {
            case Some(v) =>
                let _ = AppStorage.set<Int64>(THEME_VERSION_KEY, v + 1)
                Hilog.info(0, "CjTelegram", "[AppTheme] Theme broadcast: version -> ${v + 1}")
            case None =>
                let _ = AppStorage.setOrCreate<Int64>(THEME_VERSION_KEY, 1)
                Hilog.info(0, "CjTelegram", "[AppTheme] Theme broadcast: key created at version 1")
        }
    }
}

/**
 * Called once at app startup (from MainTabPage.aboutToAppear) to restore persisted settings and
 * compute the first real snapshot. Cold start reads the system colour mode's current state exactly
 * once too (see setSystemColorMode's doc) — but until the Ability-layer caller from this feature's
 * F5 contract is wired, `_systemColorMode` stays at COLOR_MODE_NOT_SET here, which resolves to
 * light per spec.
 *
 * Does not itself start the auto-night 1s evaluation timer or register the services-layer extras
 * provider — this package cannot reference the services package (see the "Cross-package input
 * gathering" section above for why). Both happen only as a side effect of
 * services/ThemesEngineService.cj's singleton first being constructed (getThemesEngineService()).
 * That is NOT guaranteed to happen "very early during startup" — see
 * registerPresentationExtrasProvider()'s doc comment above for the traced counter-example and
 * this feature's emitted `ic_themes_engine_cold_start_bootstrap` contract for the fix.
 */
public func initAppTheme(): Unit {
    let storage = getAuthStorage()
    let theme = storage.getAppearanceTheme()
    let textSize = storage.getAppearanceTextSize()
    let anim = storage.getAnimationEnabled()

    _appTheme.theme = theme
    _appTheme.textSize = textSize
    _appTheme.animationEnabled = anim
    _appTheme.powerSavingEnabled = storage.getPowerSaving()
    _appTheme.chatBackgroundPath = storage.getChatBackground()

    let _ = recomputePresentation()

    Hilog.info(0, "CjTelegram", "[AppTheme] Initialized: theme=${theme}, textSize=${textSize}, anim=${anim}")
}

/**
 * D-163 (round-1 review reject): explicit invalidation entry point for account-boundary events
 * (logout, server-revoked-auth re-login, account deletion). `_currentPresentation` mirrors
 * AuthStorage's per-slot appearance keys and the "telegram_themes_cache" Preferences store;
 * AuthStorage.clearAll() clears both of those on the storage side, but nothing was reachable from
 * that path to tell this module-level cache its snapshot is now stale for whatever account comes
 * next — so a returning/new session could otherwise keep rendering the previous account's colours
 * / font sizes / accent / auto-night state until some unrelated code path happened to trigger a
 * recompute. AuthStorage.clearAll()'s three call sites (services/RealAuthService.cj:272/596/1555)
 * are outside this feature's allowlist, so this function is the required call target for this
 * feature's emitted `ic_presentation_reset_on_logout` contract rather than something this Worker
 * can wire in directly.
 *
 * D-168 (round-2 review, dev_pattern.md): round-1's version assigned defaultPresentationSnapshot()
 * as the comparison baseline and then called recomputePresentation(), relying on its
 * distinctUntilChanged gate to publish. That reproduced the exact bug this function exists to
 * prevent: for any account with zero appearance customisation (the common case immediately after
 * logout, before any setting is touched), every field AuthStorage/ThemesEngineService return for
 * cleared storage matches defaultPresentationSnapshot()'s hardcoded fields exactly, so the gate
 * saw "no change" against the sentinel it had just been set to and silently skipped the publish —
 * AppStorage kept holding the previous account's (possibly customised) snapshot. An explicit
 * invalidation entry point's contract is "publish, unconditionally"; that is a different job from
 * recomputePresentation()'s "publish only on real change", so the two must not share one gate.
 * This version computes a fresh snapshot via computeSnapshot() (bypassing the gate entirely, not
 * just changing what the sentinel compares against) and assigns + publishes it directly, every
 * time this is called, regardless of what `_currentPresentation` held before — including the case
 * where the freshly-derived value happens to equal the compiled-in default. `_currentPresentation`
 * is never observably set to defaultPresentationSnapshot() as an intermediate step here: doing so
 * would reintroduce the same sentinel-collision risk against any concurrent recompute racing this
 * call (see `_presentationMutex`'s doc, D-157) instead of just against this function's own gate.
 */
public func resetPresentation(): Unit {
    _presentationMutex.lock()
    let snapshot = computeSnapshot()
    _currentPresentation = snapshot
    publishPresentation(snapshot)
    _presentationMutex.unlock()
    Hilog.info(0, "CjTelegram", "[AppTheme] resetPresentation(): presentation snapshot invalidated (account boundary), unconditional publish")
}

// ==================== Convenience accessors ====================
// P2-009 architectural rebuild: these all forward into currentPresentation() now. None of them
// return a singleton field anymore — the underlying colour/font-size state lives exclusively on
// PresentationSnapshot.

public func getAppThemeBackground(): UInt32 {
    return _currentPresentation.backgroundColor
}

public func getAppThemeCardColor(): UInt32 {
    return _currentPresentation.cardColor
}

public func getAppThemeTextColor(): UInt32 {
    return _currentPresentation.textColor
}

public func getAppThemeSecondaryTextColor(): UInt32 {
    return _currentPresentation.secondaryTextColor
}

public func getAppThemeAccentColor(): UInt32 {
    return _currentPresentation.accentColor
}

public func getAppThemeDividerColor(): UInt32 {
    return _currentPresentation.dividerColor
}

public func getAppThemeFontSize(): Int32 {
    return _currentPresentation.chatFontSize
}

public func getListsFontSize(): Int32 {
    return _currentPresentation.listsFontSize
}

public func isAppAnimationEnabled(): Bool {
    return _currentPresentation.animationEnabled
}

public func getChatBgCustomPath(): String {
    return _currentPresentation.chatBackgroundPath
}

public func isDefaultChatBg(): Bool {
    return _currentPresentation.chatBackgroundPath.size == 0
}

public func getChatBgDisplayPath(): String {
    if (_currentPresentation.chatBackgroundPath.size > 0) {
        return _currentPresentation.chatBackgroundPath
    }
    return _appTheme.defaultChatBgPath
}

public func setDefaultChatBgPath(path: String): Unit {
    _appTheme.defaultChatBgPath = path
}

public func getAppThemeNavBarColor(): UInt32 {
    return _currentPresentation.navBarColor
}

// ==================== P2-009: Theme broadcast via AppStorage ====================
// Key used for global theme change notification.
// Any component subscribing via @StorageLink["themeVersion"] receives UI refresh when theme changes.
// (Declaration moved above publishPresentation()/recomputePresentation() — Cangjie top-level
// `let` constants must be defined before use, unlike functions.)

/**
 * Initialize the theme broadcast key in AppStorage.
 * Idempotent: setOrCreate only creates if key does not yet exist.
 *
 * Round-2 review (delivery_report_check FAIL): this was the one AppStorage.set* site in this file
 * not wrapped in launch{}, which made this feature's round-1 delivery report's claim that
 * publishPresentation() is the sole AppStorage.setOrCreate/.set write site false — its only
 * caller (pages/MainTabPage.cj:212) happens to already run from a UI-thread-guaranteed lifecycle
 * callback, so it was harmless in practice, but the claim as stated was not accurate. Wrapping it
 * here (same `launch()` used by publishPresentation()) makes the claim true again and removes the
 * need to keep re-verifying that call site stays UI-thread-guaranteed forever — consistent with
 * D-167's "centralize the dispatch inside the function that does the write, don't require every
 * caller to remember" fix strategy.
 */
public func initThemeBroadcast(): Unit {
    launch {
        let _ = AppStorage.setOrCreate<Int64>(THEME_VERSION_KEY, 0)
        Hilog.info(0, "CjTelegram", "[AppTheme] Theme broadcast key initialized")
    }
}

/**
 * P2-009: Notify all @StorageLink["themeVersion"] subscribers that theme has changed.
 * Must be called on UI thread.
 *
 * Kept as a public zero-arg entry point for source compatibility with external callers
 * (pages/AppearanceSettingsPage.cj:259) outside this feature's allowlist. It no longer bumps the
 * version unconditionally: it now just triggers a recompute, and recomputePresentation() is the
 * only place that decides — via distinctUntilChanged — whether a broadcast actually happens.
 */
public func notifyThemeChanged(): Unit {
    let _ = recomputePresentation()
}

// ==================== F-4: theme carousel icon colours ====================
// 对位 WallpaperResources.swift:1410 themeIconImage(...)（调用点 ThemeCarouselItem.swift:408
// strongSelf.imageNode.setSignal(themeIconImage(...))）的色值求解半部分：给定一个内置主题身份，
// 求出该主题缩略卡需要的背景色 + 两条气泡色。不覆盖 themeIconImage 的壁纸图案/贴纸渲染部分
// （那部分需要网络取图与图像合成管线，这里只产出三个平面色，供调用方画一张纯色卡片近似）；
// 贴纸层（ThemeCarouselItem.swift:449/:876）不产生任何输出，调用方按 diag-suite_settings_appearance
// -TC-0400-round9.md F-4 的边界条件留空，不得用字形/色块顶替。
//
// 这四个身份、顺序取自 ThemeSettingsController.swift:1129-1139 defaultThemes（非本文件发明）：
// dayClassic / nightAccent / day / night——与 pages/AppearanceSettingsPage.cj 现有
// presetName()/presetBgColor() 的 0..3 顺序（该文件注释里的 F-5 记录）逐一对应，调用方可以直接把
// 现有的 index 传进来，不需要改自己的身份枚举。
public let THEME_KIND_DAY_CLASSIC: Int32 = 0
public let THEME_KIND_NIGHT_ACCENT: Int32 = 1
public let THEME_KIND_DAY: Int32 = 2
public let THEME_KIND_NIGHT: Int32 = 3

/**
 * 对位 themeIconImage() 内部拼出的 `(backgroundColor, incomingColors, outgoingColors, ...)` 元组里
 * 卡片真正用到的那三个平面色（忽略图案/多档渐变，只取该元组自己定义的"降到一个代表色"规则，见
 * themeIconColors() 每条分支的引用行）。三个字段全部沿用本文件既有的 UInt32 颜色惯例：无 alpha
 * 前缀（顶字节 0x00）＝不透明，SDK 的 alphaAdapt 会补成不透明；有非零顶字节＝显式半透明（D-175）。
 *
 * wallpaperColors 对位 themeIconImage() 内 `backgroundColor: (UIColor, UIColor?, [UInt32])` 三元组
 * 的第三项（WallpaperResources.swift:1462-1470 的 `.gradient`/`.file` 分支所填的完整色数组）——即
 * 该主题 `chat.defaultWallpaper` 的完整壁纸色数组，未降维。图案层/贴纸层仍不在本类产出范围内（见
 * themeIconColors() 函数文档）；backgroundColor 字段与其现有取值规则（colors[0]）不受影响，仍是
 * wallpaperColors 为空时的兜底。
 */
public class ThemeIconColors {
    public let backgroundColor: UInt32
    public let incomingBubbleColor: UInt32
    public let outgoingBubbleColor: UInt32
    public let wallpaperColors: Array<UInt32>

    public init(backgroundColor: UInt32, incomingBubbleColor: UInt32, outgoingBubbleColor: UInt32,
        wallpaperColors: Array<UInt32>) {
        this.backgroundColor = backgroundColor
        this.incomingBubbleColor = incomingBubbleColor
        this.outgoingBubbleColor = outgoingBubbleColor
        this.wallpaperColors = wallpaperColors
    }
}

/**
 * 求出 `kind`（THEME_KIND_* 之一）这一个内置主题身份的卡片三色。逐分支均从该主题在源码里的真实
 * 定义值算出，不是按位置排的表——同一 `kind` 无论被第几张卡片展示，结果恒定；新增第五张卡片只需要
 * 传入对应的 THEME_KIND_*，不需要在这里加一行新的按位置分支。
 *
 * 已知的、本轮明确不做的简化（见本函数各分支内联引用）：themeIconImage() 的 `color:` 形参（账号为
 * 某个内置身份单独保存的自定义强调色，themeSpecificAccentColors[themeReference.index]）恒按 None
 * 处理——这是新装账号/未曾在该主题上自定义过强调色时的实际路径，也是本仓库目前对"每主题自定义强调
 * 色"这个存储维度尚无对应字段的必然结果。图案层/贴纸层仍不在本函数产出范围内（壁纸**色数组**已通过
 * wallpaperColors 纳入，见上方 ThemeIconColors 类文档）。
 */
public func themeIconColors(kind: Int32): ThemeIconColors {
    if (kind == THEME_KIND_DAY_CLASSIC) {
        // DefaultDayPresentationTheme.swift(day:false): defaultWallpaper = defaultPatternWallpaper
        // = defaultBuiltinWallpaperGradientColors（:1109-1114），代表色取第一项（同文件既有
        // deriveBubbleStrokeColor 周边、以及 F-1/F-2 两条 known_issue 注释共享的"多档渐变取
        // colors[0]"惯例）；incoming/outgoing 单档 fill 取自同一 `message`（非 `messageDay`）区块
        // ":591 fill:[0xffffff]" / ":646 fill:[0xe1ffc7]"。wallpaperColors 是
        // defaultBuiltinWallpaperGradientColors 的完整四项，逐值照抄，未降维。
        return ThemeIconColors(0xDBDDBB, 0xFFFFFF, 0xE1FFC7, [0xDBDDBB, 0x6BA587, 0xD5D88D, 0x88B884])
    } else if (kind == THEME_KIND_DAY) {
        // DefaultDayPresentationTheme.swift(day:true): defaultWallpaper = .color(0xffffff)（:1010）；
        // incoming 单档 fill = 0xffffff（`messageDay` 区块 :755-758）；outgoing fill 是两档
        // [0x57b2e0, defaultDayAccentColor]（:813，defaultDayAccentColor=0x0088ff 为
        // DefaultDayPresentationTheme.swift:56 的固定常量，与账号可调的强调色无关），按本文件
        // deriveBubbleStrokeColor 周边已确立的 floor(count/2) 代表色规则取第二档 = 0x0088ff。
        // wallpaperColors 是单元素 [0xffffff]（`.color(0xffffff)`，不是渐变，不得填成多项）。
        return ThemeIconColors(0xFFFFFF, 0xFFFFFF, 0x0088FF, [0xFFFFFF])
    } else if (kind == THEME_KIND_NIGHT) {
        // 与前两支不同：themeIconImage()（WallpaperResources.swift:1429-1431）对 `.night` 且
        // color==nil 的路径会强制走 customizeDefaultDarkPresentationTheme(accentColor: 0x3e88f7)
        // 而不是用 makeDefaultDarkPresentationTheme 的原始值——即当前实测轮播卡显示的其实是这条
        // customize 分支的结果，不是 DefaultDarkPresentationTheme.swift 自身的裸值。
        // customize 分支（DefaultDarkPresentationTheme.swift:59-64）对 accentColor==0x3e88f7 有
        // 专门的 3 档硬编码表 [0x0771ff,0x9047ff,0xa256bf].reversed() = [0xa256bf,0x9047ff,0x0771ff]，
        // 写入 outgoing.withoutWallpaper.fill（:245），代表色取中间档（floor(3/2)=1）= 0x9047ff。
        // incoming.withoutWallpaper.fill 在同一 customize 函数里未被这条 withUpdated 传
        // fill 参数（:196-219 只更新 reaction 相关字段），所以保留基础 night 主题的裸值 0x1d1d1d
        // （DefaultDarkPresentationTheme.swift:526）。defaultWallpaper 同理未被 customize 覆盖
        // （:123-132 三个条件均不成立，withUpdated(defaultWallpaper: nil, ...) 落到
        // PresentationTheme.swift:1408 的 `?? self.defaultWallpaper`），保留基础 night 主题的
        // defaultPatternWallpaper = defaultDarkWallpaperGradientColors，代表色取 colors[0] = 0x598bf6
        // （DefaultDarkPresentationTheme.swift:330-335，与本文件 computeSnapshot() 里已有的
        // dark bubbleOut/bubbleIn "count=2→floor(2/2)=1 取 0x0088ff" 是同一代表色规则的另一处应用，
        // 但这里的输入数组是 3 档、中间档是索引 1 的 0x9047ff，两处结果不同不是矛盾）。
        // wallpaperColors 是 defaultDarkWallpaperGradientColors 的完整四项（同一
        // defaultPatternWallpaper，未被 customize 覆盖，见上），逐值照抄，未降维。
        return ThemeIconColors(0x598BF6, 0x1D1D1D, 0x9047FF, [0x598BF6, 0x7A5EEF, 0xD67CFF, 0xF38B58])
    } else {
        // THEME_KIND_NIGHT_ACCENT（以及任何未识别的 kind——仿照源侧 Swift enum 穷尽匹配没有隐式
        // 崩溃分支的精神，未识别值落到最后一支而不是让调用方拿到未初始化状态）。
        // DefaultDarkTintedPresentationTheme.swift: accentColor 固定为 defaultDarkTintedAccentColor
        // = 0x2ea6ff（:6，与账号可调强调色无关，同 day 分支的 defaultDayAccentColor 是同一类"主题自
        // 带的固定强调色"常量）。
        //   defaultWallpaper = defaultBuiltinWallpaper(colors:[0x1b2836,0x121a22,0x1b2836,0x121a22])
        //   （:939），代表色取 colors[0] = 0x1b2836。
        //   incomingFillColor = mainBackgroundColor.withMultipliedAlpha(0.9)，随后
        //   .withAlphaComponent(incomingBubbleAlpha=0.9) 覆盖同一个 0.9（:729-738），
        //   mainBackgroundColor = accentColor.withMultiplied(hue:1.024,saturation:0.585,brightness:0.25)
        //   （:521）——用本文件已有的 rgbToHsv/hsvToRgb（deriveBubbleStrokeColor 同款算法，仅乘数不同）
        //   在此处实算，不写死结果，这样以后 defaultDarkTintedAccentColor 若变化不需要重新手算。
        //   outgoing fill 两档 [outgoingBubbleFillGradientColor.withMultiplied(hue:0.966,
        //   saturation:0.61,brightness:0.98), outgoingBubbleFillGradientColor]（:531-532），代表色
        //   floor(2/2)=1 取第二档 = outgoingBubbleFillGradientColor 本身 =
        //   accentColor.withMultiplied(hue:1.019,saturation:0.731,brightness:0.59)（:530）。
        let accent = 0x2EA6FFu32
        let incomingRgb = multipliedColorRgb(accent, 1.024, 0.585, 0.25)
        let outgoingRgb = multipliedColorRgb(accent, 1.019, 0.731, 0.59)
        // 0.9 * 255 = 229.5，按本文件既有的截断（非四舍五入）惯例截到 229 = 0xE5（与
        // deriveBubbleStrokeColor 的 0.2*255=51=0x33、disclosureArrowColor 的 0.28*255=71.4→71=0x47
        // 同一惯例），顶字节非零满足 D-175。
        let incomingAlpha: UInt32 = 0xE5u32 << 24
        // wallpaperColors 是 defaultBuiltinWallpaper(colors:) 的完整四项（:939），逐值照抄，未降维。
        return ThemeIconColors(0x1B2836, incomingAlpha | incomingRgb, outgoingRgb,
            [0x1B2836, 0x121A22, 0x1B2836, 0x121A22])
    }
}

// General-purpose sibling of deriveBubbleStrokeColor() above: same rgbToHsv/hsvToRgb round trip,
// but with the three multipliers as parameters instead of deriveBubbleStrokeColor's fixed
// (0.999, 1.667, 1.1) — themeIconColors()'s THEME_KIND_NIGHT_ACCENT branch needs two different
// multiplier triples on the same base colour. Returns a bare 0xRRGGBB (no alpha byte); callers
// that need a translucent result OR it in themselves, same division of labour
// deriveBubbleStrokeColor already has with its own caller.
func multipliedColorRgb(baseRgb: UInt32, hueMult: Float64, satMult: Float64, valMult: Float64): UInt32 {
    let r = Float64((baseRgb >> 16) & 0xFFu32) / 255.0
    let g = Float64((baseRgb >> 8) & 0xFFu32) / 255.0
    let b = Float64(baseRgb & 0xFFu32) / 255.0
    let (h, s, v) = rgbToHsv(r, g, b)
    let h2 = clamp01(h * hueMult)
    let s2 = clamp01(s * satMult)
    let v2 = clamp01(v * valMult)
    let (r2, g2, b2) = hsvToRgb(h2, s2, v2)
    let ri = UInt32(clamp01(r2) * 255.0)
    let gi = UInt32(clamp01(g2) * 255.0)
    let bi = UInt32(clamp01(b2) * 255.0)
    return (ri << 16) | (gi << 8) | bi
}

// ==================== Outgoing bubble foreground palette ====================
// 对位源侧 PresentationThemePartedColors（chat.message.outgoing）里气泡内前景色那一组字段：
// primaryTextColor / secondaryTextColor / accentControlColor / mediaActiveControlColor /
// mediaInactiveControlColor / mediaControlInnerBackgroundColor / pendingActivityColor /
// fileTitleColor / fileDescriptionColor / fileDurationColor，外加 chat.message.outgoingCheckColor。
//
// 选表规则对位 DefaultDayPresentationTheme.swift:184-247（customizeDefaultDayTheme）：按气泡填充色的
// `lightness`（Display/Source/UIKitUtils.swift:168-179，0.2126r+0.7152g+0.0722b，gamma 编码分量）
// 与阈值 0.705 比较——浅色填充走深色前景，深色填充走白色前景。浅色表逐值取 dayClassic 的
// `message.outgoing`（DefaultDayPresentationTheme.swift:643-700，本仓唯一浅色主题 = .dayClassic，
// 见 PresentationSnapshot.bubbleStrokeColor 字段文档）；深色表逐值取 .night 的 outgoing
// （DefaultDarkPresentationTheme.swift:595，outgoingCheckColor :633）。
//
// 浅色表额外做一次可读性下限：源侧这组绿在本仓浅绿填充上的对比度只有 1.5–3.0:1（例如
// fileTitleColor 0x3faa3c ≈2.7:1），不满足验收要求的文本 ≥4.5:1 / 图形 ≥3:1。这里保持源侧色相与
// 饱和度，只沿 HSB 明度轴二分压暗到刚好达标（与源侧 withMultiplied(brightness:) 同一调色轴），
// 源侧取值本身已达标的（primaryTextColor 0x000000）原样输出。带 alpha 的源侧值先按填充色合成为
// 不透明色再判定，输出一律 0xFFRRGGBB（顶字节非零，D-175）。
public class BubbleForegroundColors {
    public let primaryTextColor: UInt32
    public let secondaryTextColor: UInt32
    public let accentControlColor: UInt32
    public let mediaActiveControlColor: UInt32
    public let mediaInactiveControlColor: UInt32
    public let mediaControlInnerBackgroundColor: UInt32
    public let pendingActivityColor: UInt32
    public let fileTitleColor: UInt32
    public let fileDescriptionColor: UInt32
    public let fileDurationColor: UInt32
    public let checkColor: UInt32

    public init(
        primaryTextColor: UInt32,
        secondaryTextColor: UInt32,
        accentControlColor: UInt32,
        mediaActiveControlColor: UInt32,
        mediaInactiveControlColor: UInt32,
        mediaControlInnerBackgroundColor: UInt32,
        pendingActivityColor: UInt32,
        fileTitleColor: UInt32,
        fileDescriptionColor: UInt32,
        fileDurationColor: UInt32,
        checkColor: UInt32
    ) {
        this.primaryTextColor = primaryTextColor
        this.secondaryTextColor = secondaryTextColor
        this.accentControlColor = accentControlColor
        this.mediaActiveControlColor = mediaActiveControlColor
        this.mediaInactiveControlColor = mediaInactiveControlColor
        this.mediaControlInnerBackgroundColor = mediaControlInnerBackgroundColor
        this.pendingActivityColor = pendingActivityColor
        this.fileTitleColor = fileTitleColor
        this.fileDescriptionColor = fileDescriptionColor
        this.fileDurationColor = fileDurationColor
        this.checkColor = checkColor
    }
}

// 文本 / 图形的最低对比度（WCAG 2.x 1.4.3 正文 4.5:1、1.4.11 非文本 3:1），各留 0.1 余量抵消
// 渲染抗锯齿与截断取整。
let BUBBLE_TEXT_MIN_CONTRAST: Float64 = 4.6
let BUBBLE_GRAPHIC_MIN_CONTRAST: Float64 = 3.1

func colorComponent01(c: UInt32, shift: UInt32): Float64 {
    return Float64((c >> shift) & 0xFFu32) / 255.0
}

func srgbToLinear(v: Float64): Float64 {
    if (v <= 0.04045) {
        return v / 12.92
    }
    return pow((v + 0.055) / 1.055, 2.4)
}

// WCAG relative luminance（线性化分量）。
func relativeLuminance(c: UInt32): Float64 {
    return 0.2126 * srgbToLinear(colorComponent01(c, 16)) +
        0.7152 * srgbToLinear(colorComponent01(c, 8)) +
        0.0722 * srgbToLinear(colorComponent01(c, 0))
}

public func colorContrastRatio(a: UInt32, b: UInt32): Float64 {
    let la = relativeLuminance(a)
    let lb = relativeLuminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

// 源侧 UIColor.lightness（UIKitUtils.swift:168-179）：gamma 编码分量直接加权，不线性化。
func sourceLightness(c: UInt32): Float64 {
    return 0.2126 * colorComponent01(c, 16) + 0.7152 * colorComponent01(c, 8) +
        0.0722 * colorComponent01(c, 0)
}

// 把 alpha 为 `alpha` 的 `fgRgb` 合成到不透明 `bgRgb` 上，返回 0xFFRRGGBB。
func compositeOverOpaque(fgRgb: UInt32, alpha: Float64, bgRgb: UInt32): UInt32 {
    let r = colorComponent01(fgRgb, 16) * alpha + colorComponent01(bgRgb, 16) * (1.0 - alpha)
    let g = colorComponent01(fgRgb, 8) * alpha + colorComponent01(bgRgb, 8) * (1.0 - alpha)
    let b = colorComponent01(fgRgb, 0) * alpha + colorComponent01(bgRgb, 0) * (1.0 - alpha)
    let ri = UInt32(clamp01(r) * 255.0 + 0.5)
    let gi = UInt32(clamp01(g) * 255.0 + 0.5)
    let bi = UInt32(clamp01(b) * 255.0 + 0.5)
    return 0xFF000000u32 | (ri << 16) | (gi << 8) | bi
}

// 在保持色相/饱和度的前提下沿 HSB 明度轴二分，求离 `fg` 最近、且与 `bg` 对比度 ≥ minRatio 的颜色。
// 浅底压暗、深底提亮；已达标直接返回 `fg`。输入输出均为 0xFFRRGGBB。
func ensureMinContrast(fg: UInt32, bg: UInt32, minRatio: Float64): UInt32 {
    if (colorContrastRatio(fg, bg) >= minRatio) {
        return fg
    }
    let (h, s, v) = rgbToHsv(colorComponent01(fg, 16), colorComponent01(fg, 8), colorComponent01(fg, 0))
    let darken = relativeLuminance(bg) > 0.179
    var lo = if (darken) { 0.0 } else { v }
    var hi = if (darken) { v } else { 1.0 }
    var best: UInt32 = if (darken) { 0xFF000000u32 } else { 0xFFFFFFFFu32 }
    for (_ in 0..24) {
        let mid = (lo + hi) / 2.0
        let (r2, g2, b2) = hsvToRgb(h, s, mid)
        let candidate = 0xFF000000u32 | (UInt32(clamp01(r2) * 255.0) << 16) |
            (UInt32(clamp01(g2) * 255.0) << 8) | UInt32(clamp01(b2) * 255.0)
        let passes = colorContrastRatio(candidate, bg) >= minRatio
        if (passes) {
            best = candidate
        }
        if (passes == darken) {
            lo = mid
        } else {
            hi = mid
        }
    }
    return best
}

var _outgoingForegroundCacheFill: UInt32 = 0
var _outgoingForegroundCache: Option<BubbleForegroundColors> = None

/**
 * 发出气泡内前景色表（见上方 BubbleForegroundColors 文档）。`fill` 是气泡实际填充色
 * （MessageBubble 的 bubbleOutColor，0xRRGGBB 或 0xAARRGGBB，alpha 忽略）。
 */
public func outgoingBubbleForegroundColors(fill: UInt32): BubbleForegroundColors {
    let opaqueFill = 0xFF000000u32 | (fill & 0x00FFFFFFu32)
    match (_outgoingForegroundCache) {
        case Some(cached) where _outgoingForegroundCacheFill == opaqueFill => return cached
        case _ => ()
    }
    let result = if (sourceLightness(opaqueFill) > 0.705) {
        // dayClassic message.outgoing（DefaultDayPresentationTheme.swift:678-693）。
        let text = BUBBLE_TEXT_MIN_CONTRAST
        let graphic = BUBBLE_GRAPHIC_MIN_CONTRAST
        // secondaryTextColor / fileDurationColor = 0x008c09 @0.8
        let secondary = ensureMinContrast(compositeOverOpaque(0x008C09, 0.8, opaqueFill), opaqueFill, text)
        BubbleForegroundColors(
            ensureMinContrast(0xFF000000u32, opaqueFill, text),
            secondary,
            // accentControlColor = 0x3fc33b
            ensureMinContrast(0xFF3FC33Bu32, opaqueFill, graphic),
            // mediaActiveControlColor = 0x3fc33b：它同时是播放键/文件图标实底，其上镂空字形取气泡色
            // （mediaControlInnerBackgroundColor），且要与 mediaInactiveControlColor 的未播放波形拉开
            // 层次，故按文本档下限求解。
            ensureMinContrast(0xFF3FC33Bu32, opaqueFill, text),
            // mediaInactiveControlColor = 0x93d987
            ensureMinContrast(0xFF93D987u32, opaqueFill, graphic),
            // mediaControlInnerBackgroundColor = 0xe1ffc7，即 dayClassic 的气泡填充本身；源侧发出方向
            // statusNode 前景为 .clear（ChatMessageInteractiveFileNode.swift:1790-1796，镂空见底），
            // 本仓气泡填充由调用方供给，取实际填充色以保持"镂空"语义。
            opaqueFill,
            // pendingActivityColor = 0x42b649
            ensureMinContrast(0xFF42B649u32, opaqueFill, graphic),
            // fileTitleColor = 0x3faa3c
            ensureMinContrast(0xFF3FAA3Cu32, opaqueFill, text),
            // fileDescriptionColor = 0x6fb26a
            ensureMinContrast(0xFF6FB26Au32, opaqueFill, text),
            secondary,
            // outgoingCheckColor = 0x19c700（:737）
            ensureMinContrast(0xFF19C700u32, opaqueFill, graphic)
        )
    } else {
        // .night outgoing（DefaultDarkPresentationTheme.swift:595）：白色前景，次要项 alpha 0.5。
        let halfWhite = compositeOverOpaque(0xFFFFFF, 0.5, opaqueFill)
        BubbleForegroundColors(
            0xFFFFFFFFu32, halfWhite, 0xFFFFFFFFu32, 0xFFFFFFFFu32, halfWhite,
            // 播放键/文件图标实底上的字形：源侧发出方向 statusNode 前景为 .clear（镂空见底，
            // ChatMessageInteractiveFileNode.swift:1790-1796），取实际气泡填充，与浅色支同一语义。
            opaqueFill,
            halfWhite, 0xFFFFFFFFu32, halfWhite, halfWhite,
            // outgoingCheckColor = 0xffffff（DefaultDarkPresentationTheme.swift:633）
            0xFFFFFFFFu32
        )
    }
    _outgoingForegroundCacheFill = opaqueFill
    _outgoingForegroundCache = result
    return result
}

/**
 * S7-106：已应用云主题 TL theme.settings 里决定配色的部分（TelegramThemeSettings：baseTheme /
 * accentColor / outgoingAccentColor / messageColors）。颜色均为 0xAARRGGBB 位模式（TL int32）。
 */
public class CloudThemeColorSettings {
    public let baseKind: Int32
    public let accentColor: UInt32
    public let outgoingAccentColor: Option<UInt32>
    public let messageColors: Array<UInt32>

    public init(baseKind: Int32, accentColor: UInt32, outgoingAccentColor: Option<UInt32>, messageColors: Array<UInt32>) {
        this.baseKind = baseKind
        this.accentColor = accentColor
        this.outgoingAccentColor = outgoingAccentColor
        this.messageColors = messageColors
    }

    public func isDarkBase(): Bool {
        return this.baseKind == THEME_KIND_NIGHT || this.baseKind == THEME_KIND_NIGHT_ACCENT
    }
}

/** 由 HSB 求 0xRRGGBB（UIColor(hue:saturation:brightness:alpha:1) 的等价物）。 */
func hsbColorRgb(h: Float64, s: Float64, v: Float64): UInt32 {
    let (r, g, b) = hsvToRgb(clamp01(h), clamp01(s), clamp01(v))
    return (UInt32(clamp01(r) * 255.0) << 16) | (UInt32(clamp01(g) * 255.0) << 8) | UInt32(clamp01(b) * 255.0)
}

func colorHsb(rgb: UInt32): (Float64, Float64, Float64) {
    return rgbToHsv(colorComponent01(rgb, 16), colorComponent01(rgb, 8), colorComponent01(rgb, 0))
}

/**
 * S7-106：把云主题配色套到基础主题配色上，返回 (accent, outgoingFill, incomingFill)。
 * 对位 MakePresentationTheme.swift makePresentationTheme(themeReference: .cloud) →
 * customizePresentationTheme(editing: true, accentColor: settings.accentColor,
 * bubbleColors: settings.messageColors)：
 *   - day/dayClassic：customizeDefaultDayTheme（DefaultDayPresentationTheme.swift:58-130）
 *   - night：customizeDefaultDarkPresentationTheme（DefaultDarkPresentationTheme.swift:40-100）
 *   - nightAccent：customizeDefaultDarkTintedPresentationTheme（DefaultDarkTintedPresentationTheme.swift）
 * 多色气泡渐变按本工程单色气泡惯例取中间色（floor((count-1)/2)，同文件 outgoingBubbleHighlightedFill 的取法）。
 */
public func resolveCloudThemeChatColors(cloud: CloudThemeColorSettings, baseOut: UInt32, baseIn: UInt32): (UInt32, UInt32, UInt32) {
    let accentRgb = cloud.accentColor & 0x00FFFFFFu32
    let (ah, asat, ab) = colorHsb(accentRgb)
    var bubbleColors = ArrayList<UInt32>()
    for (c in cloud.messageColors) { bubbleColors.add(c & 0x00FFFFFFu32) }
    var accent = accentRgb
    var incoming = baseIn
    if (cloud.baseKind == THEME_KIND_DAY_CLASSIC || cloud.baseKind == THEME_KIND_DAY) {
        if (bubbleColors.size == 0) {
            if (cloud.baseKind == THEME_KIND_DAY) {
                bubbleColors.add(multipliedColorRgb(accentRgb, 0.966, 0.61, 0.98))
                bubbleColors.add(accentRgb)
            } else {
                let sat = if (asat > 0.0 && ab > 0.0) { 0.14 } else { 0.0 }
                bubbleColors.add(hsbColorRgb(ah, sat, 0.79 + ab * 0.21))
            }
        }
        if (sourceLightness(accentRgb) > 0.705) {
            accent = hsbColorRgb(ah, min(1.0, asat * 1.1), min(ab, 0.6))
        }
    } else if (cloud.baseKind == THEME_KIND_NIGHT) {
        if (bubbleColors.size == 0) {
            if (accentRgb == 0xFFFFFFu32) {
                bubbleColors.add(0x313131u32)
            } else {
                bubbleColors.add(multipliedColorRgb(accentRgb, 0.966, 0.61, 0.98))
                bubbleColors.add(accentRgb)
            }
        }
        if (accentRgb != 0xFFFFFFu32 && sourceLightness(accentRgb) <= 0.735) {
            accent = hsbColorRgb(ah, asat, max(ab, 0.55))
        }
    } else {
        if (bubbleColors.size == 0) {
            let bottom = multipliedColorRgb(accentRgb, 1.019, 0.731, 0.59)
            bubbleColors.add(multipliedColorRgb(bottom, 0.966, 0.61, 0.98))
            bubbleColors.add(bottom)
        }
        accent = hsbColorRgb(ah, asat, max(ab, 0.18))
        // 入站气泡 = mainBackgroundColor = accent × (1.024, 0.585, 0.25)，alpha 0.9（与
        // themeIconColors 的 THEME_KIND_NIGHT_ACCENT 分支同一公式）。
        incoming = (0xE5u32 << 24) | multipliedColorRgb(accent, 1.024, 0.585, 0.25)
    }
    let outgoing = if (bubbleColors.size > 0) { bubbleColors[(bubbleColors.size - 1) / 2] } else { baseOut }
    return (accent, outgoing, incoming)
}
