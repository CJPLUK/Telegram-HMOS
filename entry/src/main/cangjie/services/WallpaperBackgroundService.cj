package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.math.*
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import ohos_app_cangjie_entry.core.storage.{currentPresentation, recomputePresentation, CloudThemeColorSettings,
    THEME_KIND_DAY_CLASSIC, THEME_KIND_DAY, THEME_KIND_NIGHT, THEME_KIND_NIGHT_ACCENT}
import std.convert.*
import std.sync.*
import std.collection.{ArrayList, HashMap, HashSet}

/**
 * WallpaperBackgroundService — 壁纸背景数据层
 *
 * P2-386: 多点动态渐变动画 (4色控制点 + 8步phase位置移动算法 + animateEvent)
 * P2-388: 图案壁纸+着色 (pattern位图叠加 + patternColor tint + softlight混合)
 * P2-390: 暗化叠层 (intensity黑层opacity + 仅深色外观启用)
 * P2-387: 图片壁纸显示模式 (AspectFit/HalfAspectFill/Cover/Fill)
 * P2-392: 内置壁纸预设列表 (渐变+pattern+纯色)
 * P2-393: 自定义图片壁纸设置 (motion/blur/dimming 存储消费)
 */

// Preferences store name for wallpaper custom image settings
private let WALLPAPER_PREFS_NAME = "wallpaper_custom_prefs"
private let KEY_DISPLAY_MODE = "img_display_mode"
private let KEY_MOTION_ENABLED = "img_motion_enabled"
private let KEY_BLUR_ENABLED = "img_blur_enabled"
private let KEY_CUSTOM_DIMMING = "img_dimming_intensity"
// P2-389: blur wallpaper strength (0-100, maps to blur radius 0-20 for PixelMap or ArkUI .blur())
private let KEY_BLUR_STRENGTH = "img_blur_strength"

// P2-394: Per-chat wallpaper Preferences store
// 对应 iOS CachedUserData.withUpdatedWallpaper / CachedChannelData.withUpdatedWallpaper
// Key 格式: "chat_wp_type_<peerId>", "chat_wp_gc0_<peerId>", "chat_wp_gc1_<peerId>", ...
private let WALLPAPER_PER_CHAT_PREFS = "wallpaper_per_chat_prefs"
private let KEY_CHAT_WP_TYPE = "chat_wp_type_"
private let KEY_CHAT_WP_GC0 = "chat_wp_gc0_"
private let KEY_CHAT_WP_GC1 = "chat_wp_gc1_"
private let KEY_CHAT_WP_GC2 = "chat_wp_gc2_"
private let KEY_CHAT_WP_GC3 = "chat_wp_gc3_"
private let KEY_CHAT_WP_SOLID = "chat_wp_solid_"
private let KEY_CHAT_WP_IMG = "chat_wp_img_"
// F-1 (diag-suite_settings_appearance-TC-0411-round3.md)：图案四键，与上面四键同一份 codec、
// 同一命名与后缀写法。saveSelectedWallpaper()/loadSelectedWallpaper() 固定用后缀 "global"
// （见下方两函数），与任何 peerId（数字后缀）不冲突。
private let KEY_CHAT_WP_PATTERN_COLOR = "chat_wp_pc_"
private let KEY_CHAT_WP_PATTERN_INTENSITY = "chat_wp_pi_"
private let KEY_CHAT_WP_PATTERN_FILE = "chat_wp_pf_"
private let KEY_CHAT_WP_PATTERN_OVERLAY = "chat_wp_po_"
// S6-05：云端壁纸 id（0 = 本地预设/相册图），用于与 userFull.wallpaper 比对（iOS CachedUserData.wallpaper）
private let KEY_CHAT_WP_CLOUD_ID = "chat_wp_cid_"
private let KEY_CHAT_WP_IS_DARK = "chat_wp_dark_"
// F-1: saveSelectedWallpaper()/loadSelectedWallpaper()/clearSelectedWallpaper() 复用 per-chat
// codec 的固定 key 后缀——getCurrentWallpaperForChat() 只在 peerId > 0 时才查 per-chat
// （本文件 :863 一带），"global" 不是任何合法 peerId 的字符串形态，不冲突。
private let SELECTED_WALLPAPER_KEY = "global"
private let SELECTED_WALLPAPER_LIGHT_KEY = "global_light"
private let SELECTED_WALLPAPER_DARK_KEY = "global_dark"
private let ACTIVE_THEME_WALLPAPER_LIGHT_KEY = "active_theme_light"
private let ACTIVE_THEME_WALLPAPER_DARK_KEY = "active_theme_dark"

public func automaticNightThemePreset(): Int32 {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                let value = prefs.get("auto_night_preferred_theme", PreferencesValueType.Integer(0))
                match (value) {
                    // AutoNightSettingsPage stores 0 = Night, 1 = Tinted Night. Theme preset
                    // ordinals are 3 = Night and 1 = Tinted Night.
                    case PreferencesValueType.Integer(index) => return if (index == 1) { 1 } else { 3 }
                    case _ => return 3
                }
            } catch (_e: Exception) {
                return 3
            }
        case None => return 3
    }
}

/**
 * Persist the builtin reference used while automatic night mode is active.
 * AutoNightSettingsPage stores 0 = Night and 1 = Tinted Night, while the shared theme-card
 * identity is 3 = Night and 1 = Night Accent.  Keeping this conversion next to the inverse
 * reader prevents ThemePicker's Dark/Night row from accidentally overwriting the daytime theme.
 */
public func saveAutomaticNightThemePreset(preset: Int32): Unit {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                let stored: Int64 = if (preset == 1) { 1 } else { 0 }
                prefs.put("auto_night_preferred_theme", PreferencesValueType.Integer(stored))
                prefs.flush()
            } catch (_e: Exception) {}
        case None => ()
    }
    let _ = recomputePresentation()
}

private func selectedDayWallpaperKey(): String {
    let themeService = getThemesEngineService()
    let slug = themeService.getSelectedChatThemeSlug()
    let identity = if (slug.size > 0) { "cloud_" + slug } else { "builtin_" + themeService.getThemePreset().toString() }
    return identity + "_light"
}

/**
 * 当前生效主题对应的壁纸槽 key（iOS themeSpecificChatWallpapers 的索引）。
 * 自动夜间生效时是配置的夜间预设而非白天所选主题；云主题（ThemesEngineService 的
 * selectedChatTheme 或 S7-106 的 appliedCloudTheme）用 "cloud_<slug>"，内建主题用
 * "builtin_<preset>"，再带明暗后缀。
 */
private func selectedWallpaperKeyForCurrentTheme(): String {
    if (currentPresentation().autoNightModeTriggered) {
        return "builtin_" + automaticNightThemePreset().toString() + "_dark"
    }
    let themeService = getThemesEngineService()
    var slug = themeService.getSelectedChatThemeSlug()
    if (slug.size == 0) { slug = getAppliedCloudThemeSlug() }
    let identity = if (slug.size > 0) { "cloud_" + slug } else { "builtin_" + themeService.getThemePreset().toString() }
    return identity + if (currentPresentation().isDark) { "_dark" } else { "_light" }
}

/** S7-106 早期构建写入的不带明暗后缀的云主题槽（"cloud_<slug>"）；仅作读取回落。 */
private func legacyAppliedCloudWallpaperKey(): Option<String> {
    let slug = getAppliedCloudThemeSlug()
    if (slug.isEmpty()) { return None }
    return Some("cloud_${slug}")
}

// TC-0402 round12 修法1: 内建默认主题 pattern 文档常量，逐字对位源侧
// DefaultDayPresentationTheme.swift:1127-1135 BuiltinWallpaperData.default（浅/深两态共用同一份
// 文档，仅 colors/intensity 不同，见 :675-699 的 F-A3 注释）。
private let BUILTIN_WALLPAPER_SLUG = "fqv01SQemVIBAAAApND8LDRUhRU"
private let BUILTIN_WALLPAPER_ID: Int64 = 5951821522514477057
private let BUILTIN_WALLPAPER_ACCESS_HASH: Int64 = 542913527008942388
private let BUILTIN_WALLPAPER_BUNDLE_URI = "bundle://wallpaper_pattern_dots"

/**
 * P2-387: 图片壁纸显示模式
 * 对应 iOS WallpaperGalleryEntry.settings.displayMode:
 *   aspectFit  → ImageFit.Contain (letterbox, keeps full image)
 *   halfAspectFill → ImageFit.ScaleDown (shrink-only, no upscale)
 *   cover      → ImageFit.Cover (default: crop to fill)
 *   fill/tile  → ImageFit.Fill (stretch to fill)
 * motion parallax: needs device motion sensor (N-A on HarmonyOS without @ohos.sensor binding)
 */
public enum WallpaperImageDisplayMode {
    | AspectFit       // iOS: aspectFit — 保持宽高比居中，显示全图（黑边/letterbox）
    | HalfAspectFill  // iOS: halfAspectFill — 缩小但不放大
    | Cover           // iOS: cover (默认) — 裁剪填满
    | Fill            // iOS: fill/tile — 拉伸填满（无裁剪）

    public func ordinal(): Int32 {
        match (this) {
            case AspectFit => 0
            case HalfAspectFill => 1
            case Cover => 2
            case Fill => 3
        }
    }
    public operator func ==(right: WallpaperImageDisplayMode): Bool {
        return this.ordinal() == right.ordinal()
    }
    public operator func !=(right: WallpaperImageDisplayMode): Bool {
        return this.ordinal() != right.ordinal()
    }

    public func displayName(): String {
        match (this) {
            case AspectFit => "Aspect Fit"
            case HalfAspectFill => "Half Aspect Fill"
            case Cover => "Cover (Default)"
            case Fill => "Fill"
        }
    }
}

/** ordinal → WallpaperImageDisplayMode 反向映射 */
public func wallpaperDisplayModeFromOrdinal(ord: Int32): WallpaperImageDisplayMode {
    if (ord == 0) { return WallpaperImageDisplayMode.AspectFit }
    if (ord == 1) { return WallpaperImageDisplayMode.HalfAspectFill }
    if (ord == 3) { return WallpaperImageDisplayMode.Fill }
    return WallpaperImageDisplayMode.Cover
}

/**
 * P2-393: 自定义图片壁纸附加设置
 * 对应 iOS WallpaperGalleryEntry.settings: motion / blur / dimming
 */
public class WallpaperCustomImageSettings {
    /** 显示模式（默认 Cover）*/
    public var displayMode: WallpaperImageDisplayMode = WallpaperImageDisplayMode.Cover
    /**
     * motion 视差：iOS 利用 CMMotionManager 陀螺仪实现 parallax。
     * HarmonyOS 可通过 @ohos.sensor 访问陀螺仪，但需要 arkinterop 桥接。
     * 当前标注 N-A：存储字段保留，UI 展示为不可用。
     */
    public var motionEnabled: Bool = false
    /** 模糊效果（ImageFit + blur(radius) 叠层模拟，radius=10 时可见）*/
    public var blurEnabled: Bool = false
    /**
     * P2-389: 模糊强度 (0-100，映射到 ArkUI .blur(radius) 中 radius 范围 0-20)
     * iOS 对应: WallpaperGalleryEntry.settings.blur (0-100)
     * 50 对应 radius=10 (常用默认值)；0 不模糊；100 极度模糊(radius=20)
     */
    public var blurStrength: Int32 = 50
    /** 自定义暗化强度（0.0-1.0，覆盖 WallpaperInfo.dimmingIntensity）*/
    public var dimmingIntensity: Float64 = 0.0

    public init() {}
}

/**
 * 加载自定义图片壁纸设置（从 Preferences 读取）
 * S-012: 必须用 UIAbilityContext，从 getGlobalAbilityContext() 取
 */
public func loadWallpaperCustomImageSettings(): WallpaperCustomImageSettings {
    let s = WallpaperCustomImageSettings()
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, WALLPAPER_PREFS_NAME)
                let modeOrd: Int32 = match (prefs.get(KEY_DISPLAY_MODE, PreferencesValueType.Integer(Int64(2)))) {
                    case PreferencesValueType.Integer(v) => Int32(v)
                    case _ => Int32(2)
                }
                s.displayMode = wallpaperDisplayModeFromOrdinal(modeOrd)
                s.motionEnabled = match (prefs.get(KEY_MOTION_ENABLED, PreferencesValueType.BoolData(false))) {
                    case PreferencesValueType.BoolData(b) => b
                    case _ => false
                }
                s.blurEnabled = match (prefs.get(KEY_BLUR_ENABLED, PreferencesValueType.BoolData(false))) {
                    case PreferencesValueType.BoolData(b) => b
                    case _ => false
                }
                let blurStrengthV: Int64 = match (prefs.get(KEY_BLUR_STRENGTH, PreferencesValueType.Integer(Int64(50)))) {
                    case PreferencesValueType.Integer(v) => v
                    case _ => Int64(50)
                }
                s.blurStrength = Int32(blurStrengthV)
                let dimmingScaled: Int64 = match (prefs.get(KEY_CUSTOM_DIMMING, PreferencesValueType.Integer(Int64(0)))) {
                    case PreferencesValueType.Integer(v) => v
                    case _ => Int64(0)
                }
                s.dimmingIntensity = Float64(dimmingScaled) / 100.0
            } catch (_e: Exception) {
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] loadCustomImageSettings failed: ${_e}")
            }
        case None =>
            Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] loadCustomImageSettings: no context")
    }
    return s
}

/**
 * 保存自定义图片壁纸设置到 Preferences
 */
public func saveWallpaperCustomImageSettings(settings: WallpaperCustomImageSettings): Unit {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, WALLPAPER_PREFS_NAME)
                prefs.put(KEY_DISPLAY_MODE, PreferencesValueType.Integer(Int64(settings.displayMode.ordinal())))
                prefs.put(KEY_MOTION_ENABLED, PreferencesValueType.BoolData(settings.motionEnabled))
                prefs.put(KEY_BLUR_ENABLED, PreferencesValueType.BoolData(settings.blurEnabled))
                prefs.put(KEY_BLUR_STRENGTH, PreferencesValueType.Integer(Int64(settings.blurStrength)))
                prefs.put(KEY_CUSTOM_DIMMING, PreferencesValueType.Integer(Int64(settings.dimmingIntensity * 100.0)))
                prefs.flush()
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] saveCustomImageSettings: mode=${settings.displayMode.ordinal()} motion=${settings.motionEnabled} blur=${settings.blurEnabled} blurStrength=${settings.blurStrength} dimming=${settings.dimmingIntensity}")
            } catch (_e: Exception) {
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] saveCustomImageSettings failed: ${_e}")
            }
        case None =>
            Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] saveCustomImageSettings: no context")
    }
}

/** 壁纸类型枚举 */
public enum WallpaperType {
    /** 纯色壁纸，solidColor 字段有效 */
    | SolidColor
    /** 两色线性渐变（旧版兼容），gradientColorStart/End/Angle 字段有效 */
    | TwoColorGradient
    /** 自定义图片壁纸，imageUri 字段有效 */
    | CustomImage
    /** P2-386: 多点动态渐变 (4色+8步phase)，gradientColors 数组 + phase 字段有效 */
    | MultiColorGradient
    /** P2-388: 图案壁纸，gradientColors + patternColor + patternIntensity 有效 */
    | PatternWallpaper

    public func ordinal(): Int32 {
        match (this) {
            case SolidColor => 0
            case TwoColorGradient => 1
            case CustomImage => 2
            case MultiColorGradient => 3
            case PatternWallpaper => 4
        }
    }
    public operator func ==(right: WallpaperType): Bool { return this.ordinal() == right.ordinal() }
    public operator func !=(right: WallpaperType): Bool { return this.ordinal() != right.ordinal() }
}

/** 壁纸描述数据结构 */
public class WallpaperInfo {
    public var wallpaperType: WallpaperType = WallpaperType.SolidColor
    /** 纯色壁纸颜色（0xAARRGGBB） */
    public var solidColor: UInt32 = 0xFFE8E6DF
    /** 渐变起始色（旧版兼容） */
    public var gradientColorStart: UInt32 = 0xFF8CA0D8
    /** 渐变结束色（旧版兼容） */
    public var gradientColorEnd: UInt32 = 0xFF4A5F9E
    /** 渐变角度（度，0-360，旧版兼容） */
    public var gradientAngle: Float64 = 180.0
    /** 图片壁纸的 file:// URI */
    public var imageUri: String = ""
    /**
     * P2-386: 多点渐变颜色数组 (4色，0xAARRGGBB)
     * 对应 iOS GradientBackgroundNode.colors，默认TG经典4色
     */
    public var gradientColors: Array<UInt32> = [0xFF7FA381, 0xFFD3B48F, 0xFF336F55, 0xFFFBE37D]
    /**
     * P2-386: 当前phase (0-7，对应8步位置循环)
     * animateEvent 触发时递减 (iOS逻辑: phase=(phase-1+8)%8)
     */
    public var phase: Int32 = 0
    /**
     * P2-388: 图案颜色 (0xAARRGGBB，用于 tint pattern)
     */
    public var patternColor: UInt32 = 0xFF000000
    /**
     * P2-388: 图案强度 (0.0-1.0)
     */
    public var patternIntensity: Float64 = 0.5
    /**
     * P2-390: 暗化叠层强度 (0.0-1.0，来自 TL wallpaper.settings.intensity)
     */
    public var dimmingIntensity: Float64 = 0.0
    /**
     * P2-390: 是否深色外观（仅深色时启用暗化叠层）
     */
    public var isDarkMode: Bool = false
    /**
     * P2-387: 图片壁纸显示模式 (仅 CustomImage 类型有效)
     * 默认 Cover（对应 iOS 默认行为）
     */
    public var imageDisplayMode: WallpaperImageDisplayMode = WallpaperImageDisplayMode.Cover
    /**
     * P2-393: 自定义图片是否开启模糊效果
     */
    public var imageBlurEnabled: Bool = false
    /**
     * P2-389: 模糊强度 (0-100，映射到 ArkUI .blur(radius) 中 radius=strength/5.0)
     * 50 对应 radius=10 (常用默认); 0 不模糊; 100 极度模糊(radius=20)
     */
    public var imageBlurStrength: Int32 = 50
    /**
     * TC-0402 round12 修法1：默认主题档内建 pattern 文档的本地缓存路径（`file://` URI），
     * 对位 `components/WallpaperBackgroundComponent.cj:91 patternFile`。留空表示尚未下载/
     * 未命中缓存——渲染层据此保持渐变单层，不画任何自造图案（既有禁令继续有效）。
     */
    public var patternFile: String = ""
    /**
     * TC-0402 round12 修法1：与 patternFile 成对，指示是否在当前渐变底上叠加图案层。默认
     * false，保证所有既有消费方（未显式赋值的路径）行为不变。
     */
    public var patternOverlayEnabled: Bool = false

    /**
     * 渲染等价判定：两份 WallpaperInfo 喂给 WallpaperBackgroundComponent 会画出同样的像素时为 true。
     * 供会话页在重读 per-chat 壁纸时决定要不要翻转重挂载守卫——相同壁纸的重复重读（监听回调、
     * 页面重新可见、暗色切换探针）不再销毁重建壁纸层，避免整轮 80×80 fillRect 重绘风暴。
     * phase 不参与比较：相位推进走组件自己的 @Prop 通道，不需要重挂载。
     */
    public func sameRenderingAs(other: WallpaperInfo): Bool {
        if (this.wallpaperType.ordinal() != other.wallpaperType.ordinal()) { return false }
        if (this.solidColor != other.solidColor) { return false }
        if (this.gradientColorStart != other.gradientColorStart) { return false }
        if (this.gradientColorEnd != other.gradientColorEnd) { return false }
        if (this.gradientAngle != other.gradientAngle) { return false }
        if (this.imageUri != other.imageUri) { return false }
        if (this.gradientColors.size != other.gradientColors.size) { return false }
        var i = 0
        while (i < this.gradientColors.size) {
            if (this.gradientColors[i] != other.gradientColors[i]) { return false }
            i++
        }
        if (this.patternColor != other.patternColor) { return false }
        if (this.patternIntensity != other.patternIntensity) { return false }
        if (this.dimmingIntensity != other.dimmingIntensity) { return false }
        if (this.isDarkMode != other.isDarkMode) { return false }
        if (this.imageDisplayMode.ordinal() != other.imageDisplayMode.ordinal()) { return false }
        if (this.imageBlurEnabled != other.imageBlurEnabled) { return false }
        if (this.imageBlurStrength != other.imageBlurStrength) { return false }
        if (this.patternFile != other.patternFile) { return false }
        if (this.patternOverlayEnabled != other.patternOverlayEnabled) { return false }
        if (this.cloudWallpaperId != other.cloudWallpaperId) { return false }
        return true
    }
    /** S6-05：per-chat 槽记录的云端壁纸 id（0 = 本地预设/相册图），与 userFull.wallpaper.id 比对用 */
    public var cloudWallpaperId: Int64 = 0

    public init() {}
}

// ────────────────────────────────────────────────────────────────────────
// P2-386: 多点渐变算法 — 对应 iOS SoftwareGradientBackground.generateGradient
// ────────────────────────────────────────────────────────────────────────

/**
 * GradientPoint — 渐变控制点坐标 (x, y ∈ [0,1])
 * 对应 iOS CGPoint in basePositions
 * 使用 class 替代 tuple 以避免 Cangjie 不支持 array[i].0 访问
 */
public class GradientPoint {
    public var x: Float64
    public var y: Float64
    public init(px: Float64, py: Float64) {
        this.x = px
        this.y = py
    }
}

/**
 * iOS GradientBackgroundNode.basePositions 的 8 个控制点位置 (x, y ∈ [0,1])
 * 每步渐变取其中4个（偶数索引），通过 gatherPositions(shiftArray(offset=phase)) 选取
 */
public func makeBasePositions(): Array<GradientPoint> {
    return [
        GradientPoint(0.80, 0.10),
        GradientPoint(0.60, 0.20),
        GradientPoint(0.35, 0.25),
        GradientPoint(0.25, 0.60),
        GradientPoint(0.20, 0.90),
        GradientPoint(0.40, 0.80),
        GradientPoint(0.65, 0.75),
        GradientPoint(0.75, 0.40)
    ]
}

/**
 * shiftArray: 将数组循环左移 offset 步
 * 对应 iOS private func shiftArray(array: [CGPoint], offset: Int)
 */
public func gradientShiftPositions(offset: Int32): Array<GradientPoint> {
    let base = makeBasePositions()
    let n = base.size
    let off = Int64(((offset % 8) + 8) % 8)
    var result = Array<GradientPoint>(n, { _ => GradientPoint(0.0, 0.0) })
    for (i in 0..n) {
        result[i] = base[(i + off) % n]
    }
    return result
}

/**
 * gatherPositions: 取偶数索引（每隔一个），得到4个控制点
 * 对应 iOS private func gatherPositions(_ list: [CGPoint]) -> [CGPoint]
 */
public func gradientGatherPositions(shifted: Array<GradientPoint>): Array<GradientPoint> {
    let count = shifted.size / 2
    var result = Array<GradientPoint>(count, { _ => GradientPoint(0.0, 0.0) })
    for (i in 0..count) {
        result[i] = shifted[i * 2]
    }
    return result
}

/**
 * 获取 phase 对应的 4 个控制点
 */
public func gradientPositionsForPhase(phase: Int32): Array<GradientPoint> {
    return gradientGatherPositions(gradientShiftPositions(phase))
}

/**
 * GradientPixel: 对给定 (wx, wy) ∈ [0,1]² 按 iOS 算法计算 ARGB 混合颜色
 *
 * 算法还原自 SoftwareGradientBackground.swift generateGradient():
 *   swirlFactor = 0.35 * centerDist
 *   theta = swirlFactor² * 0.8 * 8.0
 *   pixelX = clamp(0.5 + dX*cos(θ) - dY*sin(θ), 0,1)
 *   pixelY = clamp(0.5 + dX*sin(θ) + dY*cos(θ), 0,1)
 *   dist_i = max(0, 0.92 - sqrt((px-cx_i)²+(py-cy_i)²))³
 *   blended = sum(dist_i * color_i) / sum(dist_i)
 *
 * colors: Array<UInt32> (4色, 0xAARRGGBB)
 * positions: Array<GradientPoint> (4控制点 x,y ∈ [0,1])
 * wx, wy: 像素归一化坐标
 * 返回 0xFFRRGGBB
 */
public func gradientComputePixel(
    wx: Float64,
    wy: Float64,
    colors: Array<UInt32>,
    positions: Array<GradientPoint>
): UInt32 {
    let centerDistX = wx - 0.5
    let centerDistY = wy - 0.5
    let centerDist = sqrt(centerDistX * centerDistX + centerDistY * centerDistY)
    let swirlFactor = 0.35 * centerDist
    let theta = swirlFactor * swirlFactor * 0.8 * 8.0
    let sinTheta = sin(theta)
    let cosTheta = cos(theta)
    let pixelX = max(0.0, min(1.0, 0.5 + centerDistX * cosTheta - centerDistY * sinTheta))
    let pixelY = max(0.0, min(1.0, 0.5 + centerDistX * sinTheta + centerDistY * cosTheta))

    var distSum: Float64 = 0.0
    var r: Float64 = 0.0
    var g: Float64 = 0.0
    var b: Float64 = 0.0

    let count = min(colors.size, positions.size)
    for (i in 0..count) {
        let pt = positions[i]
        let cx = pt.x
        let cy = 1.0 - pt.y
        let dx = pixelX - cx
        let dy = pixelY - cy
        var dist = max(0.0, 0.92 - sqrt(dx * dx + dy * dy))
        dist = dist * dist * dist
        distSum += dist
        let argb = colors[i]
        let cr = Float64((argb >> 16) & 0xFF)
        let cg = Float64((argb >> 8) & 0xFF)
        let cb = Float64(argb & 0xFF)
        r += dist * cr
        g += dist * cg
        b += dist * cb
    }

    if (distSum < 0.00001) {
        distSum = 0.00001
    }

    let pr = UInt32(min(255.0, r / distSum))
    let pg = UInt32(min(255.0, g / distSum))
    let pb = UInt32(min(255.0, b / distSum))
    return (0xFF000000 | (pr << 16) | (pg << 8) | pb)
}

// ────────────────────────────────────────────────────────────────────────
// P2-388: Pattern Tint 计算
// ────────────────────────────────────────────────────────────────────────

/**
 * 计算 pattern tint 混合颜色
 * 对应 iOS EffectImageLayer: patternContentImage + patternColor softlight/tint
 *
 * iOS softlight 混合公式 (W3C standard):
 *   if (src <= 0.5): result = dst - (1-2*src)*dst*(1-dst)
 *   else: result = dst + (2*src-1)*(D(dst)-dst)
 *     where D(x) = if x<=0.25: ((16x-12)x+4)x else sqrt(x)
 *
 * 简化方案：patternColor 作为 overlay tint，intensity 控制不透明度
 * 实际在 Canvas 中通过先绘制渐变底图再叠加 pattern（alpha混合）实现
 */
public func computePatternTintColor(patternColor: UInt32, intensity: Float64): UInt32 {
    let a = UInt32(min(255.0, Float64((patternColor >> 24) & 0xFF) * intensity))
    let r = (patternColor >> 16) & 0xFF
    let g = (patternColor >> 8) & 0xFF
    let b = patternColor & 0xFF
    return (a << 24) | (r << 16) | (g << 8) | b
}

// ────────────────────────────────────────────────────────────────────────
// P2-390: Dimming intensity → 黑层 opacity 计算
// ────────────────────────────────────────────────────────────────────────

/**
 * 根据 intensity 和 isDark 计算暗化叠层 opacity
 * 对应 iOS WallpaperBackgroundNode: dimming overlay alpha
 *
 * iOS 逻辑: 仅深色外观启用；opacity = intensity (0.0-1.0)
 * intensity 来自 TL WallPaperSettings.intensity (0-100 整数，归一到0-1)
 */
public func computeDimmingOpacity(intensity: Float64, isDarkMode: Bool): Float64 {
    if (!isDarkMode) {
        return 0.0
    }
    return max(0.0, min(1.0, intensity))
}

// ────────────────────────────────────────────────────────────────────────
// P2-394: Per-chat wallpaper — 对应 iOS messages.setChatWallPaper / CachedUserData.wallpaper
// 本地存储基于 Preferences（peerId 作为 key 后缀），并在设置时通知 ThemesEngineService
// ────────────────────────────────────────────────────────────────────────

/**
 * 将 WallpaperInfo 持久化到 per-chat Preferences（本地侧），key 后缀参数化。
 * 对应 iOS postbox.transaction { transaction.updatePeerCachedData(... withUpdatedWallpaper) }
 * F-1 (diag-suite_settings_appearance-TC-0411-round3.md)：从原先固定用 peerId 派生 idStr
 * 的 savePerChatWallpaper() 里抽出，供 saveSelectedWallpaper()（固定后缀 "global"）复用同一份
 * codec，不重复实现。追加图案四键（patternColor/patternIntensity/patternFile/
 * patternOverlayEnabled），旧记录缺这四键时读取侧走各自缺省值，per-chat 既有行为不受影响。
 */
private func savePerChatWallpaperByKey(idStr: String, info: WallpaperInfo): Unit {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, WALLPAPER_PER_CHAT_PREFS)
                prefs.put(KEY_CHAT_WP_TYPE + idStr, PreferencesValueType.Integer(Int64(info.wallpaperType.ordinal())))
                let gc = info.gradientColors
                prefs.put(KEY_CHAT_WP_GC0 + idStr, PreferencesValueType.Integer(if (gc.size > 0) { Int64(gc[0]) } else { Int64(0xFF7FA381) }))
                prefs.put(KEY_CHAT_WP_GC1 + idStr, PreferencesValueType.Integer(if (gc.size > 1) { Int64(gc[1]) } else { Int64(0xFFD3B48F) }))
                prefs.put(KEY_CHAT_WP_GC2 + idStr, PreferencesValueType.Integer(if (gc.size > 2) { Int64(gc[2]) } else { Int64(0xFF336F55) }))
                prefs.put(KEY_CHAT_WP_GC3 + idStr, PreferencesValueType.Integer(if (gc.size > 3) { Int64(gc[3]) } else { Int64(0xFFFBE37D) }))
                prefs.put(KEY_CHAT_WP_SOLID + idStr, PreferencesValueType.Integer(Int64(info.solidColor)))
                prefs.put(KEY_CHAT_WP_IMG + idStr, PreferencesValueType.StringData(info.imageUri))
                prefs.put(KEY_CHAT_WP_PATTERN_COLOR + idStr, PreferencesValueType.Integer(Int64(info.patternColor)))
                prefs.put(KEY_CHAT_WP_PATTERN_INTENSITY + idStr, PreferencesValueType.Integer(Int64(info.patternIntensity * 100.0)))
                prefs.put(KEY_CHAT_WP_PATTERN_FILE + idStr, PreferencesValueType.StringData(info.patternFile))
                prefs.put(KEY_CHAT_WP_PATTERN_OVERLAY + idStr, PreferencesValueType.BoolData(info.patternOverlayEnabled))
                prefs.put(KEY_CHAT_WP_CLOUD_ID + idStr, PreferencesValueType.Integer(info.cloudWallpaperId))
                prefs.put(KEY_CHAT_WP_IS_DARK + idStr, PreferencesValueType.BoolData(info.isDarkMode))
                prefs.flush()
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] savePerChatWallpaper key=${idStr} type=${info.wallpaperType.ordinal()}")
            } catch (_e: Exception) {
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] savePerChatWallpaper failed: ${_e}")
            }
        case None =>
            Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] savePerChatWallpaper: no context")
    }
}

public func savePerChatWallpaper(peerId: Int64, info: WallpaperInfo): Unit {
    savePerChatWallpaperByKey("${peerId}", info)
    notifyPerChatWallpaperChanged(peerId)
}

// S6-05：per-chat 壁纸变更监听（ChatRoomPage 注册；资料页 → 壁纸库 Apply 或 userFull.wallpaper
// 同步落盘后，当前会话页据此重读并重挂壁纸层，不依赖页面 onAppear 的触发时机）。
// 写法对位 services/UpdatesManager.cj setPeerSettingsListener。
private var _perChatWallpaperListener: Option<(Int64) -> Unit> = None

public func setPerChatWallpaperListener(cb: Option<(Int64) -> Unit>): Unit {
    _perChatWallpaperListener = cb
}

public func notifyPerChatWallpaperChanged(peerId: Int64): Unit {
    Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] perChatWallpaperChanged peerId=${peerId}")
    match (_perChatWallpaperListener) {
        case Some(cb) => cb(peerId)
        case None => ()
    }
}

/**
 * 从 Preferences 读取 per-chat 壁纸（本地侧），key 后缀参数化，供 loadPerChatWallpaper()/
 * loadSelectedWallpaper() 共用（同 savePerChatWallpaperByKey() 的抽取理由）。
 * 若未设置则返回 None（由调用方回落到全局壁纸）
 * 对应 iOS account.postbox.cachedUserData(peerId).wallpaper
 */
private func loadPerChatWallpaperByKey(idStr: String): Option<WallpaperInfo> {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, WALLPAPER_PER_CHAT_PREFS)
                let key = KEY_CHAT_WP_TYPE + idStr
                if (!prefs.has(key)) {
                    return None
                }
                let typeOrd: Int32 = match (prefs.get(key, PreferencesValueType.Integer(Int64(-1)))) {
                    case PreferencesValueType.Integer(v) => Int32(v)
                    case _ => -1
                }
                if (typeOrd < 0) { return None }
                let info = WallpaperInfo()
                if (typeOrd == 0) { info.wallpaperType = WallpaperType.SolidColor }
                else if (typeOrd == 1) { info.wallpaperType = WallpaperType.TwoColorGradient }
                else if (typeOrd == 2) { info.wallpaperType = WallpaperType.CustomImage }
                else if (typeOrd == 3) { info.wallpaperType = WallpaperType.MultiColorGradient }
                else { info.wallpaperType = WallpaperType.PatternWallpaper }
                let gc0: Int64 = match (prefs.get(KEY_CHAT_WP_GC0 + idStr, PreferencesValueType.Integer(Int64(0xFF7FA381)))) {
                    case PreferencesValueType.Integer(v) => v
                    case _ => Int64(0xFF7FA381)
                }
                let gc1: Int64 = match (prefs.get(KEY_CHAT_WP_GC1 + idStr, PreferencesValueType.Integer(Int64(0xFFD3B48F)))) {
                    case PreferencesValueType.Integer(v) => v
                    case _ => Int64(0xFFD3B48F)
                }
                let gc2: Int64 = match (prefs.get(KEY_CHAT_WP_GC2 + idStr, PreferencesValueType.Integer(Int64(0xFF336F55)))) {
                    case PreferencesValueType.Integer(v) => v
                    case _ => Int64(0xFF336F55)
                }
                let gc3: Int64 = match (prefs.get(KEY_CHAT_WP_GC3 + idStr, PreferencesValueType.Integer(Int64(0xFFFBE37D)))) {
                    case PreferencesValueType.Integer(v) => v
                    case _ => Int64(0xFFFBE37D)
                }
                info.gradientColors = [UInt32(gc0), UInt32(gc1), UInt32(gc2), UInt32(gc3)]
                let solidV: Int64 = match (prefs.get(KEY_CHAT_WP_SOLID + idStr, PreferencesValueType.Integer(Int64(0xFFE8E6DF)))) {
                    case PreferencesValueType.Integer(v) => v
                    case _ => Int64(0xFFE8E6DF)
                }
                info.solidColor = UInt32(solidV)
                info.imageUri = match (prefs.get(KEY_CHAT_WP_IMG + idStr, PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(s) => s
                    case _ => ""
                }
                let patternColorV: Int64 = match (prefs.get(KEY_CHAT_WP_PATTERN_COLOR + idStr, PreferencesValueType.Integer(Int64(0x80000000)))) {
                    case PreferencesValueType.Integer(v) => v
                    case _ => Int64(0x80000000)
                }
                info.patternColor = UInt32(patternColorV)
                let patternIntensityRaw: Int64 = match (prefs.get(KEY_CHAT_WP_PATTERN_INTENSITY + idStr, PreferencesValueType.Integer(Int64(50)))) {
                    case PreferencesValueType.Integer(v) => v
                    case _ => Int64(50)
                }
                info.patternIntensity = Float64(patternIntensityRaw) / 100.0
                info.patternFile = match (prefs.get(KEY_CHAT_WP_PATTERN_FILE + idStr, PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(s) => s
                    case _ => ""
                }
                info.patternOverlayEnabled = match (prefs.get(KEY_CHAT_WP_PATTERN_OVERLAY + idStr, PreferencesValueType.BoolData(false))) {
                    case PreferencesValueType.BoolData(b) => b
                    case _ => false
                }
                info.cloudWallpaperId = match (prefs.get(KEY_CHAT_WP_CLOUD_ID + idStr, PreferencesValueType.Integer(Int64(0)))) {
                    case PreferencesValueType.Integer(v) => v
                    case _ => Int64(0)
                }
                // Older records predate this key. A negative wallpaper intensity is Telegram's
                // persisted indication that the pattern uses the night/invert rendering path,
                // so use it as the migration default instead of silently restoring a night
                // wallpaper as a daytime one.
                info.isDarkMode = match (prefs.get(
                    KEY_CHAT_WP_IS_DARK + idStr,
                    PreferencesValueType.BoolData(info.patternIntensity < 0.0)
                )) {
                    case PreferencesValueType.BoolData(b) => b
                    case _ => info.patternIntensity < 0.0
                }
                info.phase = getSharedGradientPhase()
                return Some(info)
            } catch (_e: Exception) {
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] loadPerChatWallpaper failed: ${_e}")
            }
        case None =>
            Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] loadPerChatWallpaper: no context")
    }
    return None
}

public func loadPerChatWallpaper(peerId: Int64): Option<WallpaperInfo> {
    return loadPerChatWallpaperByKey("${peerId}")
}

/**
 * 清除 per-chat / 带类型全局槽壁纸，key 后缀参数化（同上两个 ByKey 版本的抽取理由）。
 * 对应 iOS revertChatWallpaper
 */
private func clearPerChatWallpaperByKey(idStr: String): Unit {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, WALLPAPER_PER_CHAT_PREFS)
                prefs.delete(KEY_CHAT_WP_TYPE + idStr)
                prefs.flush()
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] clearPerChatWallpaper key=${idStr}")
            } catch (_e: Exception) {
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] clearPerChatWallpaper failed: ${_e}")
            }
        case None => ()
    }
}

public func clearPerChatWallpaper(peerId: Int64): Unit {
    clearPerChatWallpaperByKey("${peerId}")
    notifyPerChatWallpaperChanged(peerId)
}

// ────────────────────────────────────────────────────────────────────────
// S6-05：资料页 more → Change Wallpaper 打开 WallpaperPickerPage 前写入的目标会话
// （对位 iOS PeerInfoScreenPerformButtonAction.swift UserInfo_ChangeWallpaper →
// ThemeGridController(mode: .peer)）。WallpaperPickerPage.ensureLoaded 一次性消费；
// peerId == 0 表示普通全局「Chat Background」模式。
// ────────────────────────────────────────────────────────────────────────
private var _pendingWallpaperPeerId: Int64 = 0
private var _pendingWallpaperPeerType: String = "user"
private var _pendingWallpaperPeerAccessHash: Int64 = 0
private var _pendingWallpaperPeerName: String = ""

public func setPendingWallpaperPeer(peerId: Int64, peerType: String, accessHash: Int64, displayName: String): Unit {
    _pendingWallpaperPeerId = peerId
    _pendingWallpaperPeerType = peerType
    _pendingWallpaperPeerAccessHash = accessHash
    _pendingWallpaperPeerName = displayName
}

/** 取出并清空待设置壁纸的会话：(peerId, peerType, accessHash, displayName)。 */
public func consumePendingWallpaperPeer(): (Int64, String, Int64, String) {
    let result = (_pendingWallpaperPeerId, _pendingWallpaperPeerType, _pendingWallpaperPeerAccessHash, _pendingWallpaperPeerName)
    _pendingWallpaperPeerId = 0
    _pendingWallpaperPeerType = "user"
    _pendingWallpaperPeerAccessHash = 0
    _pendingWallpaperPeerName = ""
    return result
}

// ────────────────────────────────────────────────────────────────────────
// F-1 (diag-suite_settings_appearance-TC-0411-round3.md)：给"用户选定的壁纸"一个带类型的
// 持久载体，对位源侧 themeSpecificChatWallpapers[themeReference.index]（单一带类型值，而不是
// 拆成字符串路径槽 + 预设下标两个弱类型槽）。复用上面三个 per-chat codec 函数，固定 key 后缀
// SELECTED_WALLPAPER_KEY = "global"。getCurrentWallpaper()（下方）第一档改读它。
// ────────────────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────────────────
// S7-106：已应用的云端聊天主题（iOS PresentationThemeSettings.theme = .cloud(...)）。
// 壁纸按主题分槽（iOS themeSpecificChatWallpapers[theme.index]）：内建主题共用原 "global"
// 槽，云主题用 "cloud_<slug>" 槽；某主题未选过壁纸时回落该主题自己的默认壁纸
// （PresentationData.swift:741-750 `themeSpecificWallpaper ?? theme.chat.defaultWallpaper`）。
// ────────────────────────────────────────────────────────────────────────

private let APPLIED_THEME_PREFS = "telegram_themes_cache"
private let KEY_APPLIED_CLOUD_SLUG = "applied_cloud_theme_slug"
private let KEY_APPLIED_CLOUD_WP_COLORS = "applied_cloud_theme_wp_colors"
private let KEY_APPLIED_CLOUD_WP_INTENSITY = "applied_cloud_theme_wp_intensity"
private let KEY_APPLIED_CLOUD_WP_SLUG = "applied_cloud_theme_wp_slug"
private let KEY_THEME_WALLPAPER_SLOTS = "theme_wallpaper_slots"
private let KEY_APPLIED_CLOUD_BASE_THEME = "applied_cloud_theme_base"
private let KEY_APPLIED_CLOUD_ACCENT = "applied_cloud_theme_accent"
private let KEY_APPLIED_CLOUD_OUT_ACCENT = "applied_cloud_theme_out_accent"
private let KEY_APPLIED_CLOUD_MSG_COLORS = "applied_cloud_theme_msg_colors"

/** 已应用云主题里壁纸相关的部分（TL theme.settings[0].wallpaper）。 */
public class AppliedCloudTheme {
    public var slug: String = ""
    public var wallpaperColors: Array<UInt32> = Array<UInt32>()
    /** wallPaperSettings.intensity（-100...100），深色基底主题为负值 */
    public var wallpaperIntensity: Int32 = 0
    public var wallpaperSlug: String = ""
    /** 应用时用于决定明暗（不持久化，明暗已落在 AuthStorage appearance theme 上） */
    public var baseIsDark: Bool = false
    // S7-106：配色部分（TelegramThemeSettings baseTheme / accentColor / outgoingAccentColor /
    // messageColors）。baseTheme 为空 = 旧版本持久化的记录，没有配色信息。
    public var baseTheme: String = ""
    public var accentColor: UInt32 = 0
    /** 0 = 未设置（TL outbox_accent_color 缺省） */
    public var outgoingAccentColor: UInt32 = 0
    public var messageColors: Array<UInt32> = Array<UInt32>()

    public init() {}

    /** 供 recomputePresentation 使用的配色设置；无配色信息时 None。 */
    public func colorSettings(): Option<CloudThemeColorSettings> {
        if (this.baseTheme.isEmpty()) { return None }
        let kind = if (this.baseTheme == "day" || this.baseTheme == "arctic") {
            THEME_KIND_DAY
        } else if (this.baseTheme == "night") {
            THEME_KIND_NIGHT
        } else if (this.baseTheme == "tinted") {
            THEME_KIND_NIGHT_ACCENT
        } else {
            THEME_KIND_DAY_CLASSIC
        }
        let outAccent: Option<UInt32> = if (this.outgoingAccentColor != 0) { Some(this.outgoingAccentColor) } else { None }
        return Some(CloudThemeColorSettings(kind, this.accentColor, outAccent, this.messageColors))
    }
}

private func uint32ListToCsv(values: Array<UInt32>): String {
    var csv = ""
    for (c in values) {
        if (csv.size > 0) { csv = csv + "," }
        csv = csv + "${Int64(c)}"
    }
    return csv
}

private func csvToUint32List(csv: String): Array<UInt32> {
    let colors = ArrayList<UInt32>()
    if (csv.size > 0) {
        for (part in csv.split(",")) {
            try {
                colors.add(UInt32(Int64.parse(part.trimAscii()) & 0xFFFFFFFF))
            } catch (_: Exception) {}
        }
    }
    return colors.toArray()
}

private var _appliedCloudTheme: Option<AppliedCloudTheme> = None
private var _appliedCloudThemeLoaded: Bool = false

private func loadAppliedCloudThemeFromPrefs(): Option<AppliedCloudTheme> {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, APPLIED_THEME_PREFS)
                let slug = match (prefs.get(KEY_APPLIED_CLOUD_SLUG, PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(v) => v
                    case _ => ""
                }
                if (slug.isEmpty()) { return None }
                let t = AppliedCloudTheme()
                t.slug = slug
                let csv = match (prefs.get(KEY_APPLIED_CLOUD_WP_COLORS, PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(v) => v
                    case _ => ""
                }
                let colors = ArrayList<UInt32>()
                if (csv.size > 0) {
                    for (part in csv.split(",")) {
                        try {
                            colors.add(UInt32(Int64.parse(part.trimAscii()) & 0xFFFFFFFF))
                        } catch (_: Exception) {}
                    }
                }
                t.wallpaperColors = colors.toArray()
                t.wallpaperIntensity = match (prefs.get(KEY_APPLIED_CLOUD_WP_INTENSITY, PreferencesValueType.Integer(0))) {
                    case PreferencesValueType.Integer(v) => Int32(v)
                    case _ => 0
                }
                t.wallpaperSlug = match (prefs.get(KEY_APPLIED_CLOUD_WP_SLUG, PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(v) => v
                    case _ => ""
                }
                t.baseTheme = match (prefs.get(KEY_APPLIED_CLOUD_BASE_THEME, PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(v) => v
                    case _ => ""
                }
                t.accentColor = match (prefs.get(KEY_APPLIED_CLOUD_ACCENT, PreferencesValueType.Integer(0))) {
                    case PreferencesValueType.Integer(v) => UInt32(v & 0xFFFFFFFF)
                    case _ => 0
                }
                t.outgoingAccentColor = match (prefs.get(KEY_APPLIED_CLOUD_OUT_ACCENT, PreferencesValueType.Integer(0))) {
                    case PreferencesValueType.Integer(v) => UInt32(v & 0xFFFFFFFF)
                    case _ => 0
                }
                t.messageColors = csvToUint32List(match (prefs.get(KEY_APPLIED_CLOUD_MSG_COLORS, PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(v) => v
                    case _ => ""
                })
                t.baseIsDark = t.baseTheme == "night" || t.baseTheme == "tinted"
                return Some(t)
            } catch (_e: Exception) {
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] loadAppliedCloudTheme failed: ${_e}")
            }
        case None => ()
    }
    return None
}

/** 当前已应用的云主题；None = 内建主题。 */
public func getAppliedCloudTheme(): Option<AppliedCloudTheme> {
    if (!_appliedCloudThemeLoaded) {
        _appliedCloudTheme = loadAppliedCloudThemeFromPrefs()
        _appliedCloudThemeLoaded = true
    }
    return _appliedCloudTheme
}

public func getAppliedCloudThemeSlug(): String {
    match (getAppliedCloudTheme()) {
        case Some(t) => return t.slug
        case None => return ""
    }
}

/** iOS applyTheme / withUpdatedTheme(.cloud)：持久化已应用的云主题。 */
public func saveAppliedCloudTheme(theme: AppliedCloudTheme): Unit {
    _appliedCloudTheme = Some(theme)
    _appliedCloudThemeLoaded = true
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                var csv = ""
                for (c in theme.wallpaperColors) {
                    if (csv.size > 0) { csv = csv + "," }
                    csv = csv + "${Int64(c)}"
                }
                let prefs = Preferences.getPreferences(ctx, APPLIED_THEME_PREFS)
                prefs.put(KEY_APPLIED_CLOUD_SLUG, PreferencesValueType.StringData(theme.slug))
                prefs.put(KEY_APPLIED_CLOUD_WP_COLORS, PreferencesValueType.StringData(csv))
                prefs.put(KEY_APPLIED_CLOUD_WP_INTENSITY, PreferencesValueType.Integer(Int64(theme.wallpaperIntensity)))
                prefs.put(KEY_APPLIED_CLOUD_WP_SLUG, PreferencesValueType.StringData(theme.wallpaperSlug))
                prefs.put(KEY_APPLIED_CLOUD_BASE_THEME, PreferencesValueType.StringData(theme.baseTheme))
                prefs.put(KEY_APPLIED_CLOUD_ACCENT, PreferencesValueType.Integer(Int64(theme.accentColor)))
                prefs.put(KEY_APPLIED_CLOUD_OUT_ACCENT, PreferencesValueType.Integer(Int64(theme.outgoingAccentColor)))
                prefs.put(KEY_APPLIED_CLOUD_MSG_COLORS, PreferencesValueType.StringData(uint32ListToCsv(theme.messageColors)))
                prefs.flush()
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] saveAppliedCloudTheme slug=${theme.slug} colors=${theme.wallpaperColors.size}")
            } catch (_e: Exception) {
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] saveAppliedCloudTheme failed: ${_e}")
            }
        case None => ()
    }
}

/** 切回内建主题：清除已应用的云主题。 */
public func clearAppliedCloudTheme(): Unit {
    _appliedCloudTheme = None
    _appliedCloudThemeLoaded = true
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, APPLIED_THEME_PREFS)
                if (prefs.has(KEY_APPLIED_CLOUD_SLUG)) {
                    prefs.delete(KEY_APPLIED_CLOUD_SLUG)
                    prefs.flush()
                }
            } catch (_e: Exception) {}
        case None => ()
    }
}

/** 当前主题对应的壁纸槽 key（iOS themeSpecificChatWallpapers 的索引），见 selectedWallpaperKeyForCurrentTheme()。 */
private func selectedWallpaperKey(): String {
    return selectedWallpaperKeyForCurrentTheme()
}

private func rememberThemeWallpaperSlot(key: String): Unit {
    if (key == SELECTED_WALLPAPER_KEY) { return }
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, APPLIED_THEME_PREFS)
                let csv = match (prefs.get(KEY_THEME_WALLPAPER_SLOTS, PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(v) => v
                    case _ => ""
                }
                for (part in csv.split(",")) {
                    if (part == key) { return }
                }
                let next = if (csv.isEmpty()) { key } else { csv + "," + key }
                prefs.put(KEY_THEME_WALLPAPER_SLOTS, PreferencesValueType.StringData(next))
                prefs.flush()
            } catch (_e: Exception) {}
        case None => ()
    }
}

/** 保存"当前主题下用户选定的壁纸"（带类型），getCurrentWallpaper() 第一档消费。 */
public func saveSelectedWallpaper(info: WallpaperInfo): Unit {
    // PresentationThemeSettings.themeSpecificChatWallpapers is indexed by the effective theme.
    // During auto-night this is the configured automatic theme, not the selected daytime theme.
    let key = selectedWallpaperKey()
    rememberThemeWallpaperSlot(key)
    savePerChatWallpaperByKey(key, info)
    // A keyed write supersedes the pre-theme migration slot. Leaving that old value around would
    // make an unrelated theme inherit this selection on its next fallback pass.
    clearPerChatWallpaperByKey(SELECTED_WALLPAPER_KEY)
    match (legacyAppliedCloudWallpaperKey()) {
        case Some(legacy) => clearPerChatWallpaperByKey(legacy)
        case None => ()
    }
}

/** 读取"当前主题下用户选定的壁纸"；None 表示该主题从未选过（回落第二/第三档）。 */
public func loadSelectedWallpaper(): Option<WallpaperInfo> {
    match (loadPerChatWallpaperByKey(selectedWallpaperKey())) {
        case Some(info) => return Some(info)
        case None => ()
    }
    match (legacyAppliedCloudWallpaperKey()) {
        case Some(legacy) =>
            match (loadPerChatWallpaperByKey(legacy)) {
                case Some(info) => return Some(info)
                case None => ()
            }
        case None => ()
    }
    let modeKey = if (currentPresentation().isDark) {
        SELECTED_WALLPAPER_DARK_KEY
    } else {
        SELECTED_WALLPAPER_LIGHT_KEY
    }
    match (loadPerChatWallpaperByKey(modeKey)) {
        case Some(info) => return Some(info)
        case None => return loadPerChatWallpaperByKey(SELECTED_WALLPAPER_KEY)
    }
}

/** 清除"当前主题下用户选定的壁纸"（iOS themeSpecificChatWallpapers[theme.index] = nil）。 */
public func clearSelectedWallpaper(): Unit {
    clearPerChatWallpaperByKey(selectedWallpaperKey())
    match (legacyAppliedCloudWallpaperKey()) {
        case Some(legacy) => clearPerChatWallpaperByKey(legacy)
        case None => ()
    }
    clearPerChatWallpaperByKey(SELECTED_WALLPAPER_KEY)
    if (currentPresentation().isDark) {
        clearPerChatWallpaperByKey(SELECTED_WALLPAPER_DARK_KEY)
    } else {
        clearPerChatWallpaperByKey(SELECTED_WALLPAPER_LIGHT_KEY)
    }
}

/** Reset Chat Wallpapers：清除所有主题的选定壁纸（iOS themeSpecificChatWallpapers = [:]）。 */
public func clearAllSelectedWallpapers(): Unit {
    clearPerChatWallpaperByKey(SELECTED_WALLPAPER_KEY)
    clearPerChatWallpaperByKey(SELECTED_WALLPAPER_LIGHT_KEY)
    clearPerChatWallpaperByKey(SELECTED_WALLPAPER_DARK_KEY)
    match (legacyAppliedCloudWallpaperKey()) {
        case Some(legacy) => clearPerChatWallpaperByKey(legacy)
        case None => ()
    }
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, APPLIED_THEME_PREFS)
                let csv = match (prefs.get(KEY_THEME_WALLPAPER_SLOTS, PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(v) => v
                    case _ => ""
                }
                if (csv.size > 0) {
                    for (part in csv.split(",")) {
                        if (part.size > 0) { clearPerChatWallpaperByKey(part) }
                    }
                    prefs.delete(KEY_THEME_WALLPAPER_SLOTS)
                    prefs.flush()
                }
            } catch (_e: Exception) {}
        case None => ()
    }
}

/** Persist the currently selected cloud theme's resolved wallpaper for both appearance variants. */
public func saveActiveThemeWallpaper(isDark: Bool, info: WallpaperInfo): Unit {
    savePerChatWallpaperByKey(
        if (isDark) { ACTIVE_THEME_WALLPAPER_DARK_KEY } else { ACTIVE_THEME_WALLPAPER_LIGHT_KEY },
        info
    )
}

public func loadActiveThemeWallpaper(): Option<WallpaperInfo> {
    if (getThemesEngineService().getSelectedChatThemeSlug().size == 0) {
        return None
    }
    return loadPerChatWallpaperByKey(
        if (currentPresentation().isDark) { ACTIVE_THEME_WALLPAPER_DARK_KEY } else { ACTIVE_THEME_WALLPAPER_LIGHT_KEY }
    )
}

public func clearActiveThemeWallpapers(): Unit {
    clearPerChatWallpaperByKey(ACTIVE_THEME_WALLPAPER_LIGHT_KEY)
    clearPerChatWallpaperByKey(ACTIVE_THEME_WALLPAPER_DARK_KEY)
}

private func themeVariantIndex(item: ThemeItem, dark: Bool): Int64 {
    var index: Int64 = 0
    while (index < item.settingsVariants.size) {
        let base = item.settingsVariants[index].baseTheme
        if ((dark && (base == "night" || base == "tinted")) ||
            (!dark && (base == "classic" || base == "day" || base == "arctic"))) { return index }
        index++
    }
    return if (item.settingsVariants.size > 0) { 0 } else { -1 }
}

private func opaqueThemeColors(values: Array<UInt32>): Array<UInt32> {
    let result = ArrayList<UInt32>()
    for (value in values) { result.add(value | 0xFF000000u32) }
    return result.toArray()
}

/** Pure ThemeSettings wallpaper resolution used by both preview and persistence. */
public func resolveCloudThemeWallpaper(item: ThemeItem, variantDark: Bool): WallpaperInfo {
        let info = WallpaperInfo()
        let index = themeVariantIndex(item, variantDark)
        var base = if (variantDark) { "night" } else { "classic" }
        var hasWallpaper = item.hasWallpaper
        var slug = item.wallpaperSlug
        var colors = item.wallpaperColors
        var intensity = item.wallpaperIntensity
        var hasIntensity = item.wallpaperHasIntensity
        if (index >= 0) {
            let variant = item.settingsVariants[index]
            base = variant.baseTheme
            hasWallpaper = variant.hasWallpaper
            slug = variant.wallpaperSlug
            colors = variant.wallpaperColors
            intensity = variant.wallpaperIntensity
            hasIntensity = variant.wallpaperHasIntensity
        }
        var opaque = opaqueThemeColors(colors)
        if (hasWallpaper) {
            if (opaque.size == 0) {
                opaque = if (variantDark) {
                    if (base == "tinted") { [0xFF1B2836, 0xFF121A22, 0xFF1B2836, 0xFF121A22] }
                    else { [0xFF598BF6, 0xFF7A5EEF, 0xFFD67CFF, 0xFFF38B58] }
                } else if (base == "day" || base == "arctic") { [0xFFFFFFFF] }
                else { [0xFFDBDDBB, 0xFF6BA587, 0xFFD5D88D, 0xFF88B884] }
            }
            if (opaque.size == 1) {
                info.wallpaperType = WallpaperType.SolidColor
                info.solidColor = opaque[0]
                info.gradientColors = opaque
            } else {
                info.wallpaperType = if (opaque.size == 2) { WallpaperType.TwoColorGradient } else { WallpaperType.MultiColorGradient }
                info.gradientColors = opaque
                if (opaque.size >= 2) { info.gradientColorStart = opaque[0]; info.gradientColorEnd = opaque[1] }
            }
            info.patternOverlayEnabled = slug.size > 0
            info.patternIntensity = Float64(if (hasIntensity) { intensity } else { Int32(50) }) / 100.0
        } else if (base == "day" || base == "arctic") {
            info.wallpaperType = WallpaperType.SolidColor
            info.solidColor = 0xFFFFFFFF
            info.gradientColors = [0xFFFFFFFF]
        } else {
            info.wallpaperType = WallpaperType.MultiColorGradient
            info.gradientColors = if (base == "tinted") { [0xFF1B2836, 0xFF121A22, 0xFF1B2836, 0xFF121A22] }
                else if (variantDark) { [0xFF598BF6, 0xFF7A5EEF, 0xFFD67CFF, 0xFFF38B58] }
                else { [0xFFDBDDBB, 0xFF6BA587, 0xFFD5D88D, 0xFF88B884] }
            info.patternFile = getWallpaperBackgroundService().getDefaultPatternFile()
            info.patternOverlayEnabled = true
            info.patternIntensity = if (variantDark) { -0.34 } else { 0.5 }
        }
        info.isDarkMode = variantDark
        return info
}

/** Apply the same local theme reference, two variant wallpapers and palette as iOS selectThemeImpl. */
public func applyCloudThemeLocally(item: ThemeItem, dark: Bool): Unit {
    let wallpaperService = getWallpaperBackgroundService()
    for (variantDark in [false, true]) {
        let info = resolveCloudThemeWallpaper(item, variantDark)
        saveActiveThemeWallpaper(variantDark, info)
        let variantIndex = themeVariantIndex(item, variantDark)
        var slug = item.wallpaperSlug
        if (variantIndex >= 0) { slug = item.settingsVariants[variantIndex].wallpaperSlug }
        if (info.patternOverlayEnabled && slug.size > 0) {
            let capturedInfo = info
            let capturedDark = variantDark
            wallpaperService.resolveThemePatternFile(slug, { uri: String =>
                if (uri.size > 0) { capturedInfo.patternFile = uri; saveActiveThemeWallpaper(capturedDark, capturedInfo) }
            })
        }
    }
    var accent = item.settingsAccentColor
    var bubble: UInt32 = 0
    let activeIndex = themeVariantIndex(item, dark)
    if (activeIndex >= 0) {
        let variant = item.settingsVariants[activeIndex]
        accent = variant.accentColor
        if (variant.messageColors.size > 0) { bubble = variant.messageColors[variant.messageColors.size / 2] & 0x00FFFFFFu32 }
    }
    var accentBits = Int64(accent)
    if (accentBits < 0) { accentBits = accentBits + 0x100000000 }
    let themes = getThemesEngineService()
    themes.saveSelectedChatThemeSlug(item.slug)
    themes.saveSelectedChatThemePalette(UInt32(accentBits) & 0x00FFFFFFu32, bubble)
}

// ────────────────────────────────────────────────────────────────────────
// 全局 Phase 共享状态 (P2-386: useSharedAnimationPhase 等价)
// ────────────────────────────────────────────────────────────────────────

/**
 * 模块级全局 phase — 对应 iOS GradientBackgroundNode.sharedPhase
 * animateEvent 触发时递减循环 (0-7)
 */
private var _sharedGradientPhase: Int32 = 0

public func getSharedGradientPhase(): Int32 {
    return _sharedGradientPhase
}

/**
 * P2-386: 推进全局 phase (animateEvent 调用)
 * iOS: phase = (phase - 1 + 8) % 8（发消息气泡出现时调用）
 */
public func advanceSharedGradientPhase(): Int32 {
    let newPhase: Int32 = if (_sharedGradientPhase == 0) { 7 } else { _sharedGradientPhase - 1 }
    _sharedGradientPhase = newPhase
    return newPhase
}

// ────────────────────────────────────────────────────────────────────────
// 模块级单例
// ────────────────────────────────────────────────────────────────────────

// F-3 (diag-suite_settings_appearance-TC-0401-round7.md, RC-D): -1 means "the user has never
// picked a builtin preset". Mirrors source PresentationData.swift:741-750, where
// themeSpecificChatWallpapers[themeIndex] is an Optional and nil falls through to that theme's
// own default wallpaper. The former default of 0 encoded "never picked" and "picked preset 0"
// as the same value, which made getCurrentWallpaper()'s preset tier match unconditionally and
// left the theme-aware tier below it unreachable. saveCurrentPreset() rejects negative input,
// so -1 can only ever originate from this initialiser, never from a caller.
private var _currentPresetIndex: Int32 = -1
// S7-106: theme wallpaper slot the preset above was picked under (see selectedWallpaperKey()).
private var _currentPresetSlot: String = SELECTED_WALLPAPER_KEY

private var _wallpaperBackgroundServiceInstance: Option<WallpaperBackgroundService> = None

public func getWallpaperBackgroundService(): WallpaperBackgroundService {
    match (_wallpaperBackgroundServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = WallpaperBackgroundService()
            _wallpaperBackgroundServiceInstance = Some(inst)
            return inst
    }
}

public class WallpaperBackgroundService {

    // TC-0402 round12 修法1: 去重守卫——resolveBuiltinPatternFile() 在 getCurrentWallpaper() 的
    // 每次 build() 路径上都会被调用；缓存命中时直接同步返回，缓存未命中时最多只允许一个
    // in-flight 的下载任务，不在每次调用里都无条件 spawn 一次网络请求。
    private var _builtinPatternFetchInFlight: Bool = false
    private var _builtinPatternReadyCallbacks: ArrayList<(String) -> Unit> = ArrayList<(String) -> Unit>()

    private func finishBuiltinPatternFetch(path: String): Unit {
        this._builtinPatternFetchInFlight = false
        let callbacks = this._builtinPatternReadyCallbacks
        this._builtinPatternReadyCallbacks = ArrayList<(String) -> Unit>()
        for (callback in callbacks) {
            try {
                callback(path)
            } catch (_: Exception) {}
        }
    }

    /**
     * 内建默认主题 pattern 文档的合成 WallpaperItem——只填充缓存查询所需的 id/accessHash/slug/
     * hasDocument，document 字段（fileId/fileReference 等）留空，因为磁盘缓存命中判定
     * （getCachedCloudWallpaperThumbUri）只消费 id+accessHash 派生的 cacheKey，不需要完整
     * document 元信息；真正下载时另调 WallpaperResourcesService.getWallPaper(slug) 取一份
     * 带新鲜 fileReference 的 item（见 resolveBuiltinPatternFile 的下载分支）。
     */
    private func syntheticBuiltinWallpaperItem(): WallpaperItem {
        let item = WallpaperItem()
        item.id = BUILTIN_WALLPAPER_ID
        item.accessHash = BUILTIN_WALLPAPER_ACCESS_HASH
        item.slug = BUILTIN_WALLPAPER_SLUG
        item.hasDocument = true
        return item
    }

    /**
     * TC-0402 round12 修法1（diag-suite_settings_appearance-TC-0402-round12.md §5 修法1）：
     * 解析内建默认主题 pattern 文档的本地缓存路径。
     *
     * 同步部分：只用 id/accessHash 常量查磁盘缓存（getCachedCloudWallpaperThumbUri 内部只消费
     * 这两个字段派生的 cacheKey），不发任何网络请求——`WallpaperResourcesService.getWallPaper()`
     * 本身是一次同步阻塞的 MTProto RPC（`sendRequest()` 直接阻塞等待响应，无元信息缓存），若在
     * 本函数的同步路径上调用它，会让每次 build() 都产生一次阻塞网络往返；因此严格只在下面的
     * 异步分支里调用它。
     *
     * 异步部分：缓存未命中时，用去重守卫触发最多一个 in-flight 任务，在后台线程里先
     * getWallPaper(slug) 取带新鲜 fileReference 的 WallpaperItem，再 downloadWallpaperThumb()
     * 落盘。本次调用仍返回空串——下一次 getCurrentWallpaper() 被调用时（下一次 build() 或下一次
     * 进入该页面）会重新走同步缓存命中分支拿到非空路径。不在 spawn 内触碰任何 @State：只写
     * 本类的普通私有字段，真正的 @State 写入发生在下一次同步调用链（refreshRightValueMirrors()）
     * 里，本身就在主线程的 build() 路径上完成。
     */
    /**
     * 云主题的默认壁纸：theme.settings.wallpaper 的颜色 + intensity（iOS
     * makePresentationTheme(cloud) → chat.defaultWallpaper）。图案文档按 wallpaper slug 解析，
     * 与内建 pattern 同一条缓存/下载通道；未下载完成前只画渐变底。
     */
    public func cloudThemeDefaultWallpaper(cloud: AppliedCloudTheme): WallpaperInfo {
        let info = WallpaperInfo()
        let colors = cloud.wallpaperColors
        if (colors.size == 1) {
            info.wallpaperType = WallpaperType.SolidColor
            info.solidColor = colors[0] | 0xFF000000
        } else {
            info.wallpaperType = WallpaperType.MultiColorGradient
            let full = Array<UInt32>(4, repeat: 0)
            var i: Int64 = 0
            while (i < 4) {
                full[i] = colors[if (i < colors.size) { i } else { colors.size - 1 }] | 0xFF000000
                i += 1
            }
            info.gradientColors = full
            info.gradientColorStart = full[0]
            info.gradientColorEnd = full[1]
        }
        let intensity: Int32 = if (cloud.wallpaperIntensity == 0) { 50 } else { cloud.wallpaperIntensity }
        info.patternIntensity = Float64(intensity) / 100.0
        info.isDarkMode = currentPresentation().isDark
        if (cloud.wallpaperSlug.size > 0) {
            info.patternFile = this.resolvePatternFileForSlug(cloud.wallpaperSlug)
            info.patternOverlayEnabled = info.patternFile.size > 0
        }
        info.phase = getSharedGradientPhase()
        return info
    }

    private let _slugPatternMonitor: Monitor = Monitor()
    private let _slugPatternItems: HashMap<String, WallpaperItem> = HashMap<String, WallpaperItem>()
    private let _slugPatternInFlight: HashSet<String> = HashSet<String>()

    private func resolvePatternFileForSlug(slug: String): String {
        if (slug == BUILTIN_WALLPAPER_SLUG) { return this.resolveBuiltinPatternFile() }
        var known: Option<WallpaperItem> = None
        var startFetch = false
        synchronized(this._slugPatternMonitor) {
            if (this._slugPatternItems.contains(slug)) {
                known = Some(this._slugPatternItems[slug])
            } else if (!this._slugPatternInFlight.contains(slug)) {
                this._slugPatternInFlight.add(slug)
                startFetch = true
            }
        }
        match (known) {
            case Some(item) => return this.getCachedCloudWallpaperThumbUri(item)
            case None => ()
        }
        if (startFetch) {
            let resSvc = getWallpaperResourcesService()
            let _ = spawn {
                let freshItem = resSvc.getWallPaper(slug)
                if (freshItem.hasDocument) {
                    let _ = resSvc.downloadWallpaperThumb(freshItem)
                }
                synchronized(this._slugPatternMonitor) {
                    if (freshItem.hasDocument) { this._slugPatternItems[slug] = freshItem }
                    this._slugPatternInFlight.remove(slug)
                }
            }
        }
        return ""
    }

    private func resolveBuiltinPatternFile(): String {
        // Telegram-iOS ships this exact default document in TelegramUI/Resources and renders it
        // locally. The converted target resource `wallpaper_pattern_dots.svg` is byte-for-byte the
        // decompressed fqv01...tgv source asset, so use it directly as well. A server "m" thumb is
        // only 155x320 and cannot reproduce the source's complete screen-sized vector layout.
        return BUILTIN_WALLPAPER_BUNDLE_URI
    }

    /** Synchronous cache lookup plus de-duplicated background fetch for the built-in pattern. */
    public func getDefaultPatternFile(): String {
        return this.resolveBuiltinPatternFile()
    }

    /**
     * Resolve the built-in day/night theme pattern and report the first downloaded cache path.
     * getCurrentWallpaper() must stay synchronous, but the first chat mounted after a clean
     * install also has to repaint when that document arrives; otherwise it remains a plain
     * gradient until the user leaves and re-enters the conversation.
     */
    public func resolveDefaultPatternFile(callback: (String) -> Unit): Unit {
        callback(BUILTIN_WALLPAPER_BUNDLE_URI)
    }

    /**
     * Resolve a ThemeSettings wallpaper document by slug and return its raster pattern layer.
     * Network and file IO stay off the UI thread; callers persist the returned URI into both the
     * preview and active-theme wallpaper records.
     */
    public func resolveThemePatternFile(slug: String, callback: (String) -> Unit): Unit {
        if (slug.size == 0) {
            callback("")
            return
        }
        let capturedSlug = slug
        let capturedCallback = callback
        let _ = spawn {
            let resources = getWallpaperResourcesService()
            let item = resources.getWallPaper(capturedSlug)
            if (!item.hasDocument) {
                capturedCallback("")
                return
            }
            let cached = this.getCachedCloudWallpaperThumbUri(item)
            if (cached.size > 0) {
                capturedCallback(cached)
                return
            }
            capturedCallback(resources.downloadWallpaperThumb(item))
        }
    }

    /**
     * 获取当前壁纸信息。
     * 优先使用用户自定义图片；否则根据主题返回多色渐变或纯色。
     * P2-387/393: 自定义图片时应用存储的 displayMode / blur / dimming 设置
     */
    public func getCurrentWallpaper(): WallpaperInfo {
        // F-1 (diag-suite_settings_appearance-TC-0411-round3.md)：第一档改读带类型的持久值
        // saveSelectedWallpaper()/loadSelectedWallpaper()（本文件 :580 一带，与 per-chat 壁纸
        // 共用同一份 codec，固定 key 后缀 "global"），不再靠 getVerifiedImageUri() 的字符串槽 +
        // FileIo 文件系统校验判定"用户是否选了自定义图片"——那条校验只认得出 CustomImage 一种
        // 类型，其唯一消费方 TelegramCoreSettingsService.getVerifiedChatBackgroundUri() 又不在
        // 本 feature allowlist 内，无法扩展到其它类型。getVerifiedImageUri()/isUsingCustomWallpaper()
        // 保留不动（public API，同文件 resolveCurrentWallpaper() 已有"纯转发/保留兼容"先例），
        // 只是不再被这一档消费。
        let isDark = currentPresentation().isDark
        let autoNightTriggered = currentPresentation().autoNightModeTriggered
        match (loadPerChatWallpaperByKey(selectedWallpaperKeyForCurrentTheme())) {
            case Some(info) =>
                // This is already the effective theme's own slot. Source reads the automatic
                // theme's themeSpecificChatWallpapers entry first, so every wallpaper type is
                // valid here (not just photos).
                info.phase = getSharedGradientPhase()
                if (info.wallpaperType == WallpaperType.CustomImage) {
                    let cs = loadWallpaperCustomImageSettings()
                    info.imageDisplayMode = cs.displayMode
                    info.imageBlurEnabled = cs.blurEnabled
                    info.imageBlurStrength = cs.blurStrength
                    info.dimmingIntensity = cs.dimmingIntensity
                }
                return info
            case None => ()
        }
        // S7-106 早期构建写入的 "cloud_<slug>" 槽（无明暗后缀）：仅在非自动夜间时作为同主题槽回落。
        if (!autoNightTriggered) {
            match (legacyAppliedCloudWallpaperKey()) {
                case Some(legacy) =>
                    match (loadPerChatWallpaperByKey(legacy)) {
                        case Some(info) =>
                            info.phase = getSharedGradientPhase()
                            if (info.wallpaperType == WallpaperType.CustomImage) {
                                let cs = loadWallpaperCustomImageSettings()
                                info.imageDisplayMode = cs.displayMode
                                info.imageBlurEnabled = cs.blurEnabled
                                info.imageBlurStrength = cs.blurStrength
                                info.dimmingIntensity = cs.dimmingIntensity
                            }
                            return info
                        case None => ()
                    }
                case None => ()
            }
        }
        // With no automatic-theme-specific wallpaper, source preserves an ordinary photo from
        // the daytime theme but replaces colour/gradient/pattern wallpapers with the automatic
        // theme default.
        if (autoNightTriggered) {
            match (loadPerChatWallpaperByKey(selectedDayWallpaperKey())) {
                case Some(info) =>
                    if (info.wallpaperType == WallpaperType.CustomImage) {
                        info.phase = getSharedGradientPhase()
                        let cs = loadWallpaperCustomImageSettings()
                        info.imageDisplayMode = cs.displayMode
                        info.imageBlurEnabled = cs.blurEnabled
                        info.imageBlurStrength = cs.blurStrength
                        info.dimmingIntensity = cs.dimmingIntensity
                        return info
                    }
                case None => ()
            }
        }
        // The selected cloud theme's own ThemeSettings wallpaper is the next tier. Keep this
        // ahead of legacy global slots: those slots belonged to whichever theme was selected by
        // an older build and have no identity with which they could validly override a new theme.
        if (!autoNightTriggered) {
            match (loadActiveThemeWallpaper()) {
                case Some(info) =>
                    info.phase = getSharedGradientPhase()
                    return info
                case None => ()
            }
        }
        let selectedModeKey = if (isDark) { SELECTED_WALLPAPER_DARK_KEY } else { SELECTED_WALLPAPER_LIGHT_KEY }
        match (loadPerChatWallpaperByKey(selectedModeKey)) {
            case Some(info) =>
                if (!autoNightTriggered || info.wallpaperType == WallpaperType.CustomImage) {
                    info.phase = getSharedGradientPhase()
                    if (info.wallpaperType == WallpaperType.CustomImage) {
                        let cs = loadWallpaperCustomImageSettings()
                        info.imageDisplayMode = cs.displayMode
                        info.imageBlurEnabled = cs.blurEnabled
                        info.imageBlurStrength = cs.blurStrength
                        info.dimmingIntensity = cs.dimmingIntensity
                    }
                    return info
                }
            case None => ()
        }
        // Migration for installs that predate per-appearance wallpaper storage. An ordinary photo
        // is intentionally retained in auto-night (PresentationData.swift .file/non-pattern
        // branch); legacy colour/gradient/pattern values have no theme identity and therefore may
        // only be treated as the light-theme value. The dark side falls through to its selected
        // cloud-theme wallpaper or theme default, matching source instead of pinning a day value.
        match (loadPerChatWallpaperByKey(SELECTED_WALLPAPER_KEY)) {
            case Some(info) =>
                if (!isDark || info.wallpaperType == WallpaperType.CustomImage) {
                    info.phase = getSharedGradientPhase()
                    if (info.wallpaperType == WallpaperType.CustomImage) {
                        let cs = loadWallpaperCustomImageSettings()
                        info.imageDisplayMode = cs.displayMode
                        info.imageBlurEnabled = cs.blurEnabled
                        info.imageBlurStrength = cs.blurStrength
                        info.dimmingIntensity = cs.dimmingIntensity
                    }
                    return info
                }
            case None => ()
        }
        let info = WallpaperInfo()
        // F-W2 (diag-suite_settings_appearance-TC-0411.md, RC-W2): the user-selected builtin
        // preset must win over the theme-default gradient below — mirrors source
        // PresentationData.swift:741-750 `themeSpecificWallpaper ?? theme.chat.defaultWallpaper`,
        // where the user's selection is checked before the theme default.
        // F-3 (diag-suite_settings_appearance-TC-0401-round7.md, RC-D): that tier used to match
        // for every possible index — _currentPresetIndex defaulted to 0, and the trailing
        // `else if (presets.size > 0)` re-entered preset 0 for anything out of range — so the
        // theme-default tier below was dead code and the wallpaper never followed the theme.
        // Two changes restore the source's three tiers (custom image -> user selection ->
        // theme default): the unset sentinel now falls through instead of being read as
        // "the user picked preset 0", and a real selection is overridden while the dark theme
        // is in effect, per PresentationData.swift:806-816.
        // S7-106：预设选择也按主题分槽——只有在当前主题下选的预设才生效。
        let presets = this.getBuiltinPresets()
        let idx = if (_currentPresetSlot == selectedWallpaperKey()) { Int64(_currentPresetIndex) } else { -1 }
        if (idx >= 0 && idx < presets.size) {
            let preset = presets[idx]
            if (isDark && !preset.isDarkMode) {
                // Source PresentationData.swift:806-816: under the night theme a .builtin/.color/
                // .gradient wallpaper — and a .file one when isPattern — is replaced by that
                // theme's default wallpaper. All eight builtin presets are gradients, solid
                // colours or patterns, so every one of them is subject to the override; a real
                // custom image is not, and already returned from the branch above this comment.
                // TC-0402 round13 F-3.4 (diag-suite_settings_appearance-TC-0402-round13.md §6):
                // this used to return `presets[DARK_DEFAULT_PRESET_INDEX]` — a preset-table entry
                // standing in for "the theme default" — instead of falling through to the actual
                // theme-default branch below. Source structure is
                // `effectiveChatWallpaper = themeValue.chat.defaultWallpaper`
                // (`PresentationData.swift:806-816`): the override always resolves to the theme's
                // own default wallpaper, never to a member of the preset list. Falls through
                // (empty branch) to the theme-default code further down in this function; the
                // preset-table entry (`getBuiltinPresets()` p3) is kept as-is for the wallpaper
                // picker's own listing, it is just no longer borrowed here.
            } else {
                preset.phase = getSharedGradientPhase()
                return preset
            }
        }
        // S7-106：已应用云主题且该主题下没有用户选定的壁纸 → 该主题自己的默认壁纸
        // （theme.settings.wallpaper；PresentationData.swift:741-750）。
        match (getAppliedCloudTheme()) {
            case Some(cloud) =>
                if (cloud.wallpaperColors.size > 0) {
                    return this.cloudThemeDefaultWallpaper(cloud)
                }
            case None => ()
        }
        // RC-4 (diag-suite_settings_appearance-TC-0401-round3.md, F-4): the dark/light split must
        // read the already-resolved presentation state (auto-night + System-follow included), not
        // the raw persisted theme selector — mirrors source PresentationData.swift:760-813 where
        // the wallpaper's effective theme comes from the same presentation pipeline that decides
        // every other colour. core/storage/AppTheme.cj:computeSnapshot() already folds
        // autoNightTriggered / theme==2 System-follow into `isDark`; consume that single source
        // instead of re-deriving from getAppearanceTheme() here.
        // F-A3 (diag-suite_settings_root-TC-0507-round4.md §七, 与 F-A1 同一条链的上下游): 源侧
        // 主题默认壁纸本身就是 pattern 壁纸而非纯渐变——DefaultDayPresentationTheme.swift:1007-
        // 1010/1338 `defaultPatternWallpaper = defaultBuiltinWallpaper(colors: ...)` /
        // DefaultDarkPresentationTheme.swift:730-733 同构，且 intensity 符号随主题相反
        // （day 默认 intensity=50 → +0.5；night 显式 intensity=-34 → -0.34，对应 F-A1 的反相
        // 路径）。ADV-3 (rework_round=1) 撤回了上一轮把 wallpaperType 一并改成 PatternWallpaper
        // 的改动：components/WallpaperBackgroundComponent.cj:120-125 的 gradCtx（antialias:
        // false）与 patternCtx（antialias:true）是两个独立 Canvas 上下文，isMultiColorGradient()/
        // isPatternWallpaper() 分支路由到不同实例——"逐像素相同"的主张不成立，类型切换是一次真实
        // 的渲染路径切换。因此这里保留原 wallpaperType=MultiColorGradient（路由回 gradCtx，未
        // 改变既有渲染路径），只保留带符号的 patternIntensity 修正（数据侧对位源侧 intensity
        // 符号，不改变渲染路由）；图案层改走 patternFile + patternOverlayEnabled 的独立叠加
        // 通道（见下），不需要切 wallpaperType。
        // TC-0402 round12 修法1（diag-suite_settings_appearance-TC-0402-round12.md §5 修法1）：
        // 上一段「patternFile 当前恒为空（图源不可得）」的前提已被推翻——`downloadCloudWallpaperThumb()`
        // /`getCachedCloudWallpaperThumbUri()`（本文件 :869/:880，TC-0408 round3 之后落地）与
        // `WallpaperResourcesService.getWallPaper(slug)`/`Inflate.cj:gunzip()` 都已就绪，取的是
        // 源侧同一份内建 pattern 文档的 sizeSpec:"m" 栅格 representation（不需要 .tgv 矢量解码），
        // 与用户自选 pattern 壁纸走同一条已验证通道。此处不改这两段注释所在的分支结构，只在写
        // gradientColors/patternIntensity 之后追加 patternFile 的解析。
        info.wallpaperType = WallpaperType.MultiColorGradient
        if (currentPresentation().isDark) {
            if (autoNightTriggered && automaticNightThemePreset() == 1) {
                info.gradientColors = [0xFF1B2836, 0xFF121A22, 0xFF1B2836, 0xFF121A22]
                info.patternIntensity = 0.5
                info.isDarkMode = true
                info.patternFile = this.resolveBuiltinPatternFile()
                info.patternOverlayEnabled = true
                info.phase = getSharedGradientPhase()
                return info
            }
            // TC-0402 round13 F-3.1 (diag-suite_settings_appearance-TC-0402-round13.md §6):
            // this was logged as aligned to source but was actually a self-invented
            // pre-darkened blue. The source dark default gradient
            // (`DefaultDarkPresentationTheme.swift:330-335 defaultDarkWallpaperGradientColors`)
            // is these four literal *bright* colours; the dark look at runtime comes from
            // `patternIntensity < 0` driving the invert path in
            // `components/WallpaperBackgroundComponent.cj` build() (black backdrop +
            // `abs(intensity)` content fade), not from the gradient colour values themselves.
            // Do not re-darken these to "look more like night mode" — that folds the darkening
            // into the input a second time and breaks the value/behaviour split the invert path
            // depends on.
            info.gradientColors = [0xFF598BF6, 0xFF7A5EEF, 0xFFD67CFF, 0xFFF38B58]
            info.patternIntensity = -0.34
            info.isDarkMode = true
        } else {
            info.gradientColors = [0xFF7FA381, 0xFFD3B48F, 0xFF336F55, 0xFFFBE37D]
            info.patternIntensity = 0.5
            info.isDarkMode = false
        }
        info.patternFile = this.resolveBuiltinPatternFile()
        info.patternOverlayEnabled = true
        info.phase = getSharedGradientPhase()
        return info
    }

    // F-W2 (diag-suite_settings_appearance-TC-0411.md, RC-W2): the theme-default fallback path
    // (getChatBgDisplayPath() -> AppTheme.defaultChatBgPath) must never be mistaken for a
    // user-set custom image — mirrors source PresentationData.swift:741-750, where the theme
    // default is the lowest-priority fallback, not a signal the user picked an image.
    // isUsingCustomWallpaper() (below) reads getChatBackground(), which holds only the
    // user-set value — the correct positive judge already present in this file. Do not touch
    // getChatBgDisplayPath() or TelegramCoreSettingsService.getVerifiedChatBackgroundUri(): the
    // former is the legitimate fallback source for the chat room's own bottom-layer image, the
    // latter is outside this feature's allowlist.
    public func getVerifiedImageUri(): String {
        if (!this.isUsingCustomWallpaper()) {
            return ""
        }
        return getTelegramCoreSettingsService().getVerifiedChatBackgroundUri()
    }

    public func getFallbackColor(): UInt32 {
        return 0xFFE8E6DF
    }

    public func isUsingCustomWallpaper(): Bool {
        return getTelegramCoreSettingsService().getChatBackground().size > 0
    }

    // ── P2-337: 预设选择持久化 ───────────────────────────────────

    public func saveCurrentPreset(index: Int32): Unit {
        if (index < 0 || index > 7) {
            Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] saveCurrentPreset: out of range ${index}")
            return
        }
        _currentPresetIndex = index
        _currentPresetSlot = selectedWallpaperKey()
        Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] saveCurrentPreset: ${index}")
    }

    /** 回到"未选预设"（主题默认壁纸），对位 themeSpecificChatWallpapers[theme.index] = nil。 */
    public func clearCurrentPreset(): Unit {
        _currentPresetIndex = -1
    }

    public func getCurrentPresetIndex(): Int32 {
        return _currentPresetIndex
    }

    // ── P2-387/393: 自定义图片显示模式 + 设置 ─────────────────────

    public func getCustomImageSettings(): WallpaperCustomImageSettings {
        return loadWallpaperCustomImageSettings()
    }

    public func saveCustomImageSettings(settings: WallpaperCustomImageSettings): Unit {
        saveWallpaperCustomImageSettings(settings)
    }

    // F-W2 (diag-suite_settings_appearance-TC-0411.md, RC-W2): the "user selection" tier this
    // function used to own (custom image -> preset lookup) is now folded into
    // getCurrentWallpaper() itself, so the single-engine priority (custom image -> preset ->
    // theme default) lives in one place instead of two divergent copies. This symbol is kept as
    // a pure forwarder so any existing caller keeps working unchanged.
    public func resolveCurrentWallpaper(): WallpaperInfo {
        return this.getCurrentWallpaper()
    }

    // ── P2-394: Per-chat 壁纸 get/set/clear ─────────────────────

    /**
     * 获取指定聊天的壁纸（per-chat 优先，回落全局）
     * 对应 iOS WallpaperBackgroundNode init with peer-specific wallpaper
     * ChatRoomPage.aboutToAppear 时调用
     *
     * @param peerId 目标对话 ID（0 表示用全局壁纸）
     */
    public func getCurrentWallpaperForChat(peerId: Int64): WallpaperInfo {
        if (peerId > 0) {
            match (loadPerChatWallpaper(peerId)) {
                case Some(info) =>
                    info.phase = getSharedGradientPhase()
                    return info
                case None => ()
            }
        }
        return this.getCurrentWallpaper()
    }

    /**
     * 设置 per-chat 壁纸（本地存储 + 异步通知服务端）
     * 对应 iOS setChatWallpaper(peerId, wallpaper, forBoth)
     *
     * @param peerId      目标对话 ID
     * @param peerType    "user" | "chat" | "channel"
     * @param accessHash  peer accessHash（channel/user 需要）
     * @param info        要设置的壁纸信息；None 表示清除 per-chat 壁纸（revert）
     * @param forBoth     是否双端同时设置（同 iOS forBoth 标志）
     */
    public func setPerChatWallpaperWithServer(
        peerId: Int64,
        peerType: String,
        accessHash: Int64,
        info: Option<WallpaperInfo>,
        forBoth: Bool
    ): Unit {
        // 1. 本地立即更新（先于网络，使 ChatRoomPage 即时刷新）
        match (info) {
            case Some(wp) =>
                savePerChatWallpaper(peerId, wp)
            case None =>
                clearPerChatWallpaper(peerId)
        }
        // 2. 异步通知服务端
        let capturedPeerId = peerId
        let capturedPeerType = peerType
        let capturedHash = accessHash
        let capturedForBoth = forBoth
        let capturedHasWp = match (info) { case Some(_) => true; case None => false }
        let _ = spawn {
            let themeSvc = getThemesEngineService()
            if (capturedHasWp) {
                // per-chat 壁纸改为本地自定义壁纸：通过 revert 先清除服务端壁纸，
                // 再存本地（服务端 wallpaper id 未知，本地-only 模式）
                // 真实服务端设置需上传壁纸 document 后获取 id/accessHash，
                // 这里通知 revert 以保持本地-only per-chat 壁纸不被服务端覆盖。
                let _ = themeSvc.revertChatWallPaper(capturedPeerId, capturedPeerType, capturedHash)
            } else {
                // 还原为默认（revert）
                let _ = themeSvc.revertChatWallPaper(capturedPeerId, capturedPeerType, capturedHash)
            }
            Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] setPerChatWallpaperWithServer: peerId=${capturedPeerId} hasWp=${capturedHasWp} forBoth=${capturedForBoth}")
        }
    }

    /**
     * S6-05：只给某一个会话设置壁纸（iOS messages.setChatWallPaper，forBoth=false）。
     * 本地立即落 per-chat 槽（ChatRoomPage 回到前台即生效）；云端壁纸（wallpaperId != 0）
     * 向服务端提交 inputWallPaper(id, access_hash)，本地预设/相册图没有服务端 id，走与
     * setPerChatWallpaperWithServer 相同的本地-only 路径（revert 服务端记录，防止被覆盖）。
     *
     * @param peerId              目标对话 ID
     * @param peerType            "user" | "chat" | "channel"
     * @param accessHash          peer accessHash
     * @param info                要设置的壁纸
     * @param wallpaperId         云端壁纸 id（0 = 非云端）
     * @param wallpaperAccessHash 云端壁纸 access_hash
     */
    public func setPerChatWallpaperForPeer(
        peerId: Int64,
        peerType: String,
        accessHash: Int64,
        info: WallpaperInfo,
        wallpaperId: Int64,
        wallpaperAccessHash: Int64
    ): Unit {
        info.cloudWallpaperId = wallpaperId
        savePerChatWallpaper(peerId, info)
        let capturedPeerId = peerId
        let capturedPeerType = peerType
        let capturedHash = accessHash
        let capturedWpId = wallpaperId
        let capturedWpHash = wallpaperAccessHash
        let _ = spawn {
            try {
                let themeSvc = getThemesEngineService()
                let ok = if (capturedWpId != 0) {
                    themeSvc.setChatWallPaper(capturedPeerId, capturedPeerType, capturedHash, capturedWpId, capturedWpHash, false)
                } else {
                    themeSvc.revertChatWallPaper(capturedPeerId, capturedPeerType, capturedHash)
                }
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] setPerChatWallpaperForPeer: peerId=${capturedPeerId} wpId=${capturedWpId} ok=${ok}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] setPerChatWallpaperForPeer error: ${e}")
            }
        }
    }

    /**
     * S6-05：把一条云端壁纸（account.getWallPapers / account.getWallPaper 条目）合成为可渲染的
     * WallpaperInfo。合成规则与 WallpaperPickerPage.applyCloudWallpaper 的全局路径同形：
     * 图案壁纸 → 按 settings 颜色数选底层（≥3 多点渐变 / 2 双色 / 1 纯色）+ patternFile（"m" 缩略图）
     * 叠加；照片壁纸 → CustomImage(imageUri = 全量文档 URI)。
     */
    public func cloudWallpaperInfo(item: WallpaperItem, thumbUri: String, fullUri: String): WallpaperInfo {
        let info = WallpaperInfo()
        info.cloudWallpaperId = item.id
        if (item.isPattern) {
            let colors = item.settings.colorsArray()
            if (colors.size >= 3) {
                info.wallpaperType = WallpaperType.MultiColorGradient
                info.gradientColors = colors
            } else if (colors.size == 2) {
                info.wallpaperType = WallpaperType.TwoColorGradient
                info.gradientColorStart = colors[0]
                info.gradientColorEnd = colors[1]
                info.gradientColors = [colors[0], colors[1]]
            } else if (colors.size == 1) {
                info.wallpaperType = WallpaperType.SolidColor
                info.solidColor = colors[0]
            } else {
                info.wallpaperType = WallpaperType.SolidColor
                info.solidColor = 0xFFFFFFFF
            }
            info.imageUri = ""
            info.patternFile = thumbUri
            info.patternOverlayEnabled = true
            if (item.settings.hasIntensity) {
                info.patternIntensity = Float64(item.settings.intensity) / 100.0
            } else {
                info.patternIntensity = 0.5
            }
        } else {
            info.wallpaperType = WallpaperType.CustomImage
            info.imageUri = fullUri
        }
        return info
    }

    /**
     * S6-05：会话打开时用 userFull.wallpaper（iOS CachedUserData.wallpaper，
     * fetchAndUpdateCachedPeerData）校准本地 per-chat 槽——服务端为准：
     *  - 服务端无专属壁纸而本地槽记着云端 id → 清掉（在别的端 revert 过）；
     *  - 服务端 id 与本地槽一致 → 不动；
     *  - 否则按 slug 取 account.getWallPaper → 下载缩略图/原图 → 合成 → 落盘（wallPaperNoFile 只有
     *    颜色，直接合成）。落盘走 savePerChatWallpaper → 通知当前会话页重读。
     * 本地-only 壁纸（cloudWallpaperId == 0，预设/相册图）在服务端无记录时保留。
     */
    public func syncServerChatWallpaper(
        peerId: Int64,
        hasWallpaper: Bool,
        wallpaperId: Int64,
        slug: String,
        colors: Array<UInt32>,
        intensity: Int32
    ): Unit {
        var localExists = false
        var localCloudId: Int64 = 0
        match (loadPerChatWallpaper(peerId)) {
            case Some(info) =>
                localExists = true
                localCloudId = info.cloudWallpaperId
            case None => ()
        }
        Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] syncServerChatWallpaper peerId=${peerId} server=${hasWallpaper}/${wallpaperId} local=${localExists}/${localCloudId}")
        if (!hasWallpaper) {
            if (localExists && localCloudId != 0) {
                clearPerChatWallpaper(peerId)
            }
            return
        }
        if (localExists && localCloudId == wallpaperId) { return }
        let capturedPeerId = peerId
        let capturedId = wallpaperId
        let capturedSlug = slug
        let capturedColors = colors
        let capturedIntensity = intensity
        let _ = spawn {
            try {
                var composed: Option<WallpaperInfo> = None
                if (capturedSlug.size > 0) {
                    let resSvc = getWallpaperResourcesService()
                    let item = resSvc.getWallPaper(capturedSlug)
                    if (item.hasDocument) {
                        let thumb = resSvc.downloadWallpaperThumb(item)
                        let full = if (item.isPattern) { "" } else { resSvc.downloadWallpaper(item) }
                        if (item.isPattern || full.size > 0) {
                            composed = Some(this.cloudWallpaperInfo(item, thumb, full))
                        }
                    }
                } else if (capturedColors.size > 0) {
                    let info = WallpaperInfo()
                    info.cloudWallpaperId = capturedId
                    if (capturedColors.size >= 3) {
                        info.wallpaperType = WallpaperType.MultiColorGradient
                        info.gradientColors = capturedColors
                    } else if (capturedColors.size == 2) {
                        info.wallpaperType = WallpaperType.TwoColorGradient
                        info.gradientColorStart = capturedColors[0]
                        info.gradientColorEnd = capturedColors[1]
                        info.gradientColors = [capturedColors[0], capturedColors[1]]
                    } else {
                        info.wallpaperType = WallpaperType.SolidColor
                        info.solidColor = capturedColors[0]
                    }
                    info.patternIntensity = Float64(capturedIntensity) / 100.0
                    composed = Some(info)
                }
                match (composed) {
                    case Some(info) =>
                        info.cloudWallpaperId = capturedId
                        savePerChatWallpaper(capturedPeerId, info)
                        Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] syncServerChatWallpaper applied peerId=${capturedPeerId} wpId=${capturedId} type=${info.wallpaperType.ordinal()}")
                    case None =>
                        Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] syncServerChatWallpaper: could not resolve wpId=${capturedId} slug=${capturedSlug}")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[WallpaperBgSvc] syncServerChatWallpaper error: ${e}")
            }
        }
    }

    // ── P2-337: 云端壁纸异步触发 ────────────────────────────────

    public func loadWallpapersFromCloud(hash: Int64, callback: (WallpaperListResult) -> Unit): Unit {
        let capturedHash = hash
        let capturedCallback = callback
        let _ = spawn {
            let resSvc = getWallpaperResourcesService()
            let result = resSvc.getWallPapers(hash: capturedHash)
            capturedCallback(result)
        }
    }

    public func getCachedCloudWallpaperUri(item: WallpaperItem): String {
        if (!item.hasDocument) { return "" }
        let resSvc = getWallpaperResourcesService()
        let key = resSvc.deriveWallpaperCacheKey(item.id, item.accessHash)
        return resSvc.getCachedLocalPath(key)
    }

    public func downloadCloudWallpaper(item: WallpaperItem, callback: (String) -> Unit): Unit {
        if (!item.hasDocument) {
            callback("")
            return
        }
        let capturedItem = item
        let capturedCallback = callback
        let _ = spawn {
            let resSvc = getWallpaperResourcesService()
            let uri = resSvc.downloadWallpaper(capturedItem)
            capturedCallback(uri)
        }
    }

    /**
     * TC-0408 round3 RC-B / F-3.5: 缩略图（图案层）版本的缓存查询桥接，供
     * shell_settings_wallpaper 网格格子读取——与 getCachedCloudWallpaperUri() 的全量文档路径独立，
     * 走 WallpaperResourcesService.getCachedLocalPathNonEmpty()（额外校验文件非空，避免中断写入
     * 留下的 0 字节文件被当成"已缓存"）。
     */
    public func getCachedCloudWallpaperThumbUri(item: WallpaperItem): String {
        if (!item.hasDocument) { return "" }
        let resSvc = getWallpaperResourcesService()
        let key = resSvc.deriveWallpaperThumbCacheKey(item.id, item.accessHash)
        return resSvc.getCachedLocalPathNonEmpty(key)
    }

    /**
     * TC-0408 round3 RC-B / F-3.5: 缩略图（图案层）版本的下载桥接，对位 downloadCloudWallpaper()，
     * 走 WallpaperResourcesService.downloadWallpaperThumb()（取 sizeSpec:"m" 栅格缩略图，不是
     * mime_type application/x-tgwallpattern 的文档原件）。
     */
    public func downloadCloudWallpaperThumb(item: WallpaperItem, callback: (String) -> Unit): Unit {
        if (!item.hasDocument) {
            callback("")
            return
        }
        let capturedItem = item
        let capturedCallback = callback
        let _ = spawn {
            let resSvc = getWallpaperResourcesService()
            let uri = resSvc.downloadWallpaperThumb(capturedItem)
            capturedCallback(uri)
        }
    }

    /**
     * P2-392: 内置壁纸预设列表（真实非空列表，对应 iOS 内置壁纸集合）
     * 覆盖三类: 多色渐变 / 纯色 / 图案壁纸 (PatternWallpaper)
     * 真实位图资产缺失时用渐变+pattern预设代替，诚实标注。
     * iOS 对应: WallpaperBackgroundNode defaultWallpapers / builtinPresets
     */
    public func getBuiltinPresets(): Array<WallpaperInfo> {
        // preset 0: TG经典绿金4色渐变（默认，对应 iOS Day 模式默认壁纸）
        let p0 = WallpaperInfo()
        p0.wallpaperType = WallpaperType.MultiColorGradient
        p0.gradientColors = [0xFF7FA381, 0xFFD3B48F, 0xFF336F55, 0xFFFBE37D]

        // preset 1: 蓝紫4色渐变（对应 iOS 蓝色预设）
        let p1 = WallpaperInfo()
        p1.wallpaperType = WallpaperType.MultiColorGradient
        p1.gradientColors = [0xFF8CA0D8, 0xFF4A5F9E, 0xFF6B84C8, 0xFF2E4A7A]

        // preset 2: 纯白（简洁，对应 iOS 极简白壁纸）
        let p2 = WallpaperInfo()
        p2.wallpaperType = WallpaperType.SolidColor
        p2.solidColor = 0xFFFFFFFF

        // preset 3: 暗夜蓝4色渐变（深色主题，对应 iOS Night 模式默认壁纸）
        let p3 = WallpaperInfo()
        p3.wallpaperType = WallpaperType.MultiColorGradient
        p3.gradientColors = [0xFF1C2840, 0xFF0D1A2E, 0xFF213257, 0xFF162035]
        p3.isDarkMode = true

        // preset 4: 海绿4色渐变（对应 iOS 绿色自然预设）
        let p4 = WallpaperInfo()
        p4.wallpaperType = WallpaperType.MultiColorGradient
        p4.gradientColors = [0xFF4CAF8A, 0xFF2E7D56, 0xFF5AB896, 0xFF1A6B44]

        // preset 5: 图案壁纸-金色（P2-388 PatternWallpaper，点阵几何）
        // 对应 iOS 内置 pattern 壁纸，真实位图缺失时用渐变底+dot pattern代替
        let p5 = WallpaperInfo()
        p5.wallpaperType = WallpaperType.PatternWallpaper
        p5.gradientColors = [0xFFD4A853, 0xFFE8C678, 0xFFC8903E, 0xFFD4B060]
        p5.patternColor = 0xCCAA7800
        p5.patternIntensity = 0.6

        // preset 6: 图案壁纸-蓝灰几何（P2-388 PatternWallpaper）
        let p6 = WallpaperInfo()
        p6.wallpaperType = WallpaperType.PatternWallpaper
        p6.gradientColors = [0xFF8BA3BF, 0xFF6B8BA8, 0xFF4A6A88, 0xFF7090B0]
        p6.patternColor = 0xCC2A4A6A
        p6.patternIntensity = 0.5

        // preset 7: 玫瑰渐变（对应 iOS 粉色预设）
        let p7 = WallpaperInfo()
        p7.wallpaperType = WallpaperType.MultiColorGradient
        p7.gradientColors = [0xFFE8A0B4, 0xFFD4607C, 0xFFE890A8, 0xFFC84870]

        return [p0, p1, p2, p3, p4, p5, p6, p7]
    }

    /**
     * P2-392: 内置预设显示名称
     */
    public func builtinPresetName(index: Int32): String {
        if (index == 0) { return "Classic Green" }
        if (index == 1) { return "Blue Gradient" }
        if (index == 2) { return "Pure White" }
        if (index == 3) { return "Night Blue" }
        if (index == 4) { return "Sea Green" }
        if (index == 5) { return "Gold Pattern" }
        if (index == 6) { return "Blue Pattern" }
        if (index == 7) { return "Rose Gradient" }
        return "Preset ${index}"
    }
}
