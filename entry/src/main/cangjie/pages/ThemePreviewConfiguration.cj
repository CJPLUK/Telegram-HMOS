package ohos_app_cangjie_entry.pages

import std.collection.ArrayList
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, ThemeIconColors,
    resolvePresentationSnapshot, themeIconColors, THEME_KIND_DAY_CLASSIC,
    THEME_KIND_DAY, THEME_KIND_NIGHT, THEME_KIND_NIGHT_ACCENT}
import ohos_app_cangjie_entry.services.{ThemeItem, WallpaperInfo, WallpaperType,
    resolveCloudThemeWallpaper, getWallpaperBackgroundService}

/**
 * 完整主题预览值。它对应 iOS `makePresentationTheme(...)` 的返回物：选择页先按当前
 * light/dark preview 精确选中 ThemeSettings，并把该设置派生出的 presentation、气泡、
 * wallpaper 一并交给 ThemePreviewPage。预览页不再根据 slug 重新请求或读取当前全局主题。
 */
public class ThemePreviewConfiguration {
    public var isBuiltin: Bool = true
    public var builtinRef: Int32 = THEME_KIND_DAY_CLASSIC
    public var cloudItem: Option<ThemeItem> = None
    public var title: String = "🏠"
    public var isDark: Bool = false
    public var accentColor: UInt32 = 0x0088FF
    public var colors: ThemeIconColors = themeIconColors(THEME_KIND_DAY_CLASSIC)
    public var presentation: PresentationSnapshot = resolvePresentationSnapshot(0, false)
    public var wallpaper: WallpaperInfo = WallpaperInfo()
    public var patternSlug: String = ""
}

private var pendingThemePreviewConfiguration: Option<ThemePreviewConfiguration> = None

func setPendingThemePreviewConfiguration(value: ThemePreviewConfiguration): Unit {
    pendingThemePreviewConfiguration = Some(value)
}

func takePendingThemePreviewConfiguration(): Option<ThemePreviewConfiguration> {
    let value = pendingThemePreviewConfiguration
    pendingThemePreviewConfiguration = None
    return value
}

private func previewOpaqueColors(values: Array<UInt32>): Array<UInt32> {
    let result = ArrayList<UInt32>()
    for (value in values) { result.add(value | 0xFF000000u32) }
    return result.toArray()
}

private func previewAccentBits(value: Int32): UInt32 {
    var bits = Int64(value)
    if (bits < 0) { bits += 0x100000000 }
    return UInt32(bits) & 0x00FFFFFFu32
}

private func previewCloudVariantIndex(item: ThemeItem, dark: Bool): Int64 {
    var index: Int64 = 0
    while (index < item.settingsVariants.size) {
        let base = item.settingsVariants[index].baseTheme
        // ThemePickerController.previewTheme passes `baseTheme: nightMode ? .night : .classic`
        // into makePresentationTheme. That overload uses equality, not a light/dark family match.
        if (base == if (dark) { "night" } else { "classic" }) {
            return index
        }
        index++
    }
    return if (item.settingsVariants.size > 0) { 0 } else { -1 }
}

func makeBuiltinThemePreviewConfiguration(reference: Int32): ThemePreviewConfiguration {
    let result = ThemePreviewConfiguration()
    result.isBuiltin = true
    result.builtinRef = reference
    result.title = if (reference == THEME_KIND_DAY_CLASSIC || reference == THEME_KIND_NIGHT) {
        "🏠"
    } else if (reference == THEME_KIND_NIGHT_ACCENT) { "Tinted Night" } else { "Day" }
    result.isDark = reference == THEME_KIND_NIGHT || reference == THEME_KIND_NIGHT_ACCENT
    result.accentColor = if (reference == THEME_KIND_NIGHT) { 0x3E88F7 }
        else if (reference == THEME_KIND_NIGHT_ACCENT) { 0x2EA6FF } else { 0x0088FF }
    result.colors = themeIconColors(reference)
    result.presentation = resolvePresentationSnapshot(if (result.isDark) { 1 } else { 0 }, result.isDark)
        .withUpdatedAccentColor(result.accentColor)

    let wallpaper = WallpaperInfo()
    let opaque = previewOpaqueColors(result.colors.wallpaperColors)
    if (opaque.size == 1) {
        wallpaper.wallpaperType = WallpaperType.SolidColor
        wallpaper.solidColor = opaque[0]
    } else {
        wallpaper.wallpaperType = WallpaperType.MultiColorGradient
        wallpaper.gradientColors = opaque
        if (opaque.size >= 2) {
            wallpaper.gradientColorStart = opaque[0]
            wallpaper.gradientColorEnd = opaque[1]
        }
    }
    if (reference != THEME_KIND_DAY) {
        wallpaper.patternFile = getWallpaperBackgroundService().getDefaultPatternFile()
        wallpaper.patternOverlayEnabled = true
        wallpaper.patternIntensity = if (reference == THEME_KIND_NIGHT) { -0.34 } else { 0.5 }
    }
    wallpaper.isDarkMode = result.isDark
    result.wallpaper = wallpaper
    return result
}

func makeCloudThemePreviewConfiguration(item: ThemeItem, dark: Bool,
    resolvedPatternFile: String): ThemePreviewConfiguration {
    let result = ThemePreviewConfiguration()
    result.isBuiltin = false
    result.cloudItem = Some(item)
    result.title = item.title
    result.isDark = dark

    let selected = ThemeItem()
    let index = previewCloudVariantIndex(item, dark)
    if (index >= 0) {
        let variant = item.settingsVariants[index]
        selected.hasSettings = true
        selected.settingsBaseTheme = variant.baseTheme
        selected.settingsAccentColor = variant.accentColor
        selected.settingsMessageColors = variant.messageColors
        selected.hasWallpaper = variant.hasWallpaper
        selected.wallpaperId = variant.wallpaperId
        selected.wallpaperSlug = variant.wallpaperSlug
        selected.wallpaperColors = variant.wallpaperColors
        selected.wallpaperIntensity = variant.wallpaperIntensity
        selected.wallpaperHasIntensity = variant.wallpaperHasIntensity
        result.accentColor = previewAccentBits(variant.accentColor)
        result.patternSlug = variant.wallpaperSlug
    } else {
        selected.hasSettings = item.hasSettings
        selected.settingsBaseTheme = item.settingsBaseTheme
        selected.settingsAccentColor = item.settingsAccentColor
        selected.settingsMessageColors = item.settingsMessageColors
        selected.hasWallpaper = item.hasWallpaper
        selected.wallpaperId = item.wallpaperId
        selected.wallpaperSlug = item.wallpaperSlug
        selected.wallpaperColors = item.wallpaperColors
        selected.wallpaperIntensity = item.wallpaperIntensity
        selected.wallpaperHasIntensity = item.wallpaperHasIntensity
        result.accentColor = previewAccentBits(item.settingsAccentColor)
        result.patternSlug = item.wallpaperSlug
    }
    result.colors = cloudCardColors(selected)
    result.presentation = resolvePresentationSnapshot(if (dark) { 1 } else { 0 }, dark)
        .withUpdatedAccentColor(result.accentColor)
    result.wallpaper = resolveCloudThemeWallpaper(selected, dark)
    if (resolvedPatternFile.size > 0) { result.wallpaper.patternFile = resolvedPatternFile }
    return result
}
