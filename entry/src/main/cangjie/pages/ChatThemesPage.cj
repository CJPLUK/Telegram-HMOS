package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import kit.ImageKit.{createPixelMap, PixelMap, InitializationOptions, PixelMapFormat, AlphaType}
import kit.ImageKit.Size as IKSize
import std.collection.{ArrayList, HashMap}
import std.math.*
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.services.{getThemesEngineService, getWallpaperBackgroundService,
    getWallpaperResourcesService, WallpaperInfo,
    WallpaperType, ThemeItem, automaticNightThemePreset, saveAutomaticNightThemePreset,
    clearActiveThemeWallpapers}
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.subscribe
import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.utils.{formatMessageTimestampAt, readRawFileBytes}
import ohos_app_cangjie_entry.bindings.getTelegramLottieNative
import ohos_app_cangjie_entry.services.{setPendingExternalContent, ExternalContentItem}
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation, themeIconColors,
    ThemeIconColors, THEME_KIND_DAY_CLASSIC, THEME_KIND_DAY, THEME_KIND_NIGHT, THEME_KIND_NIGHT_ACCENT,
    resolvePresentationSnapshot, resolveThemeColorTable, getAuthStorage, recomputePresentation}

/**
 * ThemeCardData — 主题网格(F2)/基础主题横排(F3)卡片的最小承载。builtin 用 builtinIndex
 * (对位 AppearanceSettingsPage.presetName 的既有编号：0=dayClassic/1=nightAccent/2=day/3=night，
 * 与 getThemePreset() 的返回值同一套编号，本文件复用不新造第二套)；云主题用 cloudId/cloudSlug。
 */
public class ThemeCardData {
    public var isBuiltin: Bool = false
    public var builtinIndex: Int32 = 0
    public var cloudId: Int64 = 0
    public var cloudSlug: String = ""
    public var displayName: String = ""
    // TC-0400 round12 F-C / TC-0415 round2 M-1a (diag-suite_settings_appearance-TC-0400-
    // round12.md §6 F-C 第 3 条)：云主题卡求色函数 cloudCardColors() 需要完整 ThemeItem
    // （settingsBaseTheme/settingsAccentColor/settingsMessageColors/wallpaperColors/
    // hasSettings），而不是本类原有的四个精简字段——保留原始引用而不是逐字段搬运，避免这张卡片类
    // 与 ThemeItem 出现两份易漂移的拷贝。builtin 卡不设置，保持默认空 ThemeItem()。
    public var sourceItem: ThemeItem = ThemeItem()
}

// ==================== M-1a：云主题卡求色 ====================
// diag-suite_settings_appearance-TC-0415-round2.md「修法方向」M-1a + diag-...-TC-0400-round12.md
// §6 F-C 第 3 条：该函数只能有一份实现，落地于本文件、声明为包内可见（非 public，仅
// ohos_app_cangjie_entry.pages 包内消费）——本文件自己的网格卡（buildThemeCardContent 云主题支）
// 与 pages/AppearanceSettingsPage.cj 的轮播云主题卡（同包，直接调用，不需要 import）共用同一份实现。

/**
 * settingsBaseTheme 字符串 -> THEME_KIND_*，逐条对位 round2 报告 M-1a 取值表：classic->dayClassic、
 * day->day、arctic->day（ApiUtils/Theme.swift:18-31 的 arctic 并入 day 分支）、night->night、
 * tinted->nightAccent（PresentationThemeSettings.swift:18-28 的 tinted 并入 nightAccent 分支）；
 * 空串/未识别的构造子（themeBaseThemeName() 的穷尽 fallback，core/mtproto/TLResponses.cj:3897-
 * 3903）一律落到 dayClassic。
 */
func cloudCardBaseKind(baseTheme: String): Int32 {
    if (baseTheme == "classic") {
        return THEME_KIND_DAY_CLASSIC
    } else if (baseTheme == "day") {
        return THEME_KIND_DAY
    } else if (baseTheme == "arctic") {
        return THEME_KIND_DAY
    } else if (baseTheme == "night") {
        return THEME_KIND_NIGHT
    } else if (baseTheme == "tinted") {
        return THEME_KIND_NIGHT_ACCENT
    } else {
        return THEME_KIND_DAY_CLASSIC
    }
}

// D-195 镜像：core/storage/AppTheme.cj:1215-1226 multipliedColorRgb() 与其依赖的
// clamp01/rgbToHsv/hsvToRgb（:493-524）均为非 public（默认 internal，仅 core.storage 包内可见）
// 纯工具函数，该文件不在本 feature allowlist 内。本文件下方 centerBubbleColors 一节已有一套同构
// 镜像（clamp01Local/rgbToHsvLocal/hsvToRgbLocal），但那一套是 ChatThemesPage 类的实例私有方法，
// 无法被 cloudCardColors()（包级函数，需要被 AppearanceSettingsPage.cj 跨文件直接调用，不能挂在
// 某个类实例上）调用——这里逐字节镜像出第二份包级版本，原因是可见性形状不同（实例方法 vs 包级
// 函数），不是重复实现求色逻辑本身。
func cloudColorClamp01(x: Float64): Float64 {
    return max(0.0, min(1.0, x))
}

func cloudColorRgbToHsv(r: Float64, g: Float64, b: Float64): (Float64, Float64, Float64) {
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

func cloudColorHsvToRgb(h: Float64, s: Float64, v: Float64): (Float64, Float64, Float64) {
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

func cloudColorMultipliedRgb(baseRgb: UInt32, hueMult: Float64, satMult: Float64, valMult: Float64): UInt32 {
    let r = Float64((baseRgb >> 16) & 0xFFu32) / 255.0
    let g = Float64((baseRgb >> 8) & 0xFFu32) / 255.0
    let b = Float64(baseRgb & 0xFFu32) / 255.0
    let (h, s, v) = cloudColorRgbToHsv(r, g, b)
    let h2 = cloudColorClamp01(h * hueMult)
    let s2 = cloudColorClamp01(s * satMult)
    let v2 = cloudColorClamp01(v * valMult)
    let (r2, g2, b2) = cloudColorHsvToRgb(h2, s2, v2)
    let ri = UInt32(cloudColorClamp01(r2) * 255.0)
    let gi = UInt32(cloudColorClamp01(g2) * 255.0)
    let bi = UInt32(cloudColorClamp01(b2) * 255.0)
    return (ri << 16) | (gi << 8) | bi
}

// Int32 的原始位模式转 UInt32，不做符号数值转换（settingsAccentColor 是 TL 的 int，其值是 ARGB
// 位模式，不是可比较大小的有符号数——同一陷阱的反方向说明见 core/mtproto/TLResponses.cj:1098-
// 1103 D-191）。经 Int64 中间值绕开 UInt32(负数) 直接构造会抛的 OverflowException（
// core/mtproto/ByteUtils.cj:186-188 bytesToInt32 同一手法的镜像用法）。
func cloudColorInt32Bits(v: Int32): UInt32 {
    var iv = Int64(v)
    if (iv < 0) {
        iv = iv + 0x100000000
    }
    return UInt32(iv)
}

/**
 * 云主题卡四色求值，逐条对位 diag-suite_settings_appearance-TC-0415-round2.md「修法方向」M-1a
 * 取值表。调用方：本文件 buildThemeCardContent() 的云主题支、pages/AppearanceSettingsPage.cj 的
 * 轮播云主题卡（TC-0400 round12 F-C 第 3 条）。参数用 ThemeItem（而不是 ThemeCardData）——
 * ThemeItem 已经是 M-1b 落地的规范 DTO，AppearanceSettingsPage.cj 的 chatThemeItems 直接是
 * Array<ThemeItem>，两个调用点都不需要再包一层专用 wrapper 类型；本文件自己的网格卡通过
 * ThemeCardData.sourceItem 取得同一个 ThemeItem 引用。
 */
func cloudCardColors(item: ThemeItem): ThemeIconColors {
    // 边界条件 3：hasSettings==false（TL 里 settings flag 未置位）时四个入参全部回落 dayClassic
    // ——源侧在无 settings 且无 file resource 时 themeSignal = .never()，卡面保持 imageNode 的空态
    // （WallpaperResources.swift:1440-1450）；目标侧没有"空态占位图"这个承载物，回落 dayClassic 是
    // 唯一不引入新空白块的选择，属目标侧特有兜底，不是源侧逻辑。
    if (!item.hasSettings) {
        return themeIconColors(THEME_KIND_DAY_CLASSIC)
    }

    let baseKind = cloudCardBaseKind(item.settingsBaseTheme)
    let fallback = themeIconColors(baseKind)

    // wallpaperColors：item.wallpaperColors 非空直接用（已是 background->second->third->fourth
    // 同序，core/mtproto/TLResponses.cj 已完成该排序），空则回落 themeIconColors(baseKind).wallpaperColors。
    var wallpaperColors = fallback.wallpaperColors
    if (item.wallpaperColors.size > 0) {
        wallpaperColors = item.wallpaperColors
    }

    // outgoingColor：settingsMessageColors 非空取 floor(size/2) 代表色（本仓已确立的
    // core/storage/AppTheme.cj THEME_KIND_DAY/THEME_KIND_NIGHT 分支同一惯例）；边界条件 2：
    // 元素同样要 & 0x00FFFFFF 去掉可能非零的顶字节（气泡色不得带非零顶字节，D-175）。
    var outgoingColor = fallback.outgoingBubbleColor
    if (item.settingsMessageColors.size > 0) {
        let midIdx = item.settingsMessageColors.size / 2
        outgoingColor = item.settingsMessageColors[midIdx] & 0x00FFFFFFu32
    }

    // incomingColor：baseKind != nightAccent 时是基础主题常量（与强调色无关）；nightAccent 分支
    // 用本云主题自己的 settingsAccentColor 重算（对位 MakePresentationTheme.swift:22-33 +
    // DefaultDarkTintedPresentationTheme.swift:521/:729-738，与 core/storage/AppTheme.cj:1196-
    // 1199 的 THEME_KIND_NIGHT_ACCENT 分支同一公式）。边界条件 1：settingsAccentColor 先转
    // UInt32 位模式再 & 0x00FFFFFF 去 alpha。
    var incomingColor = fallback.incomingBubbleColor
    if (baseKind == THEME_KIND_NIGHT_ACCENT) {
        let accentRgb = cloudColorInt32Bits(item.settingsAccentColor) & 0x00FFFFFFu32
        let incomingRgb = cloudColorMultipliedRgb(accentRgb, 1.024, 0.585, 0.25)
        // 0.9 * 255 = 229.5，按 AppTheme.cj:1197-1201 同一惯例截断（非四舍五入）到 229 = 0xE5。
        incomingColor = (0xE5u32 << 24) | incomingRgb
    }

    // fallbackColor：wallpaperColors 非空取 colors[0]，空则回落 themeIconColors(baseKind).backgroundColor。
    var fallbackColor = fallback.backgroundColor
    if (wallpaperColors.size > 0) {
        fallbackColor = wallpaperColors[0]
    }

    return ThemeIconColors(fallbackColor, incomingColor, outgoingColor, wallpaperColors)
}

/**
 * ChatThemesPage — 对位 submodules/SettingsUI/Sources/ThemePickerController.swift。
 *
 * TC-0404 回归修复（round1 F3）：ACCENT COLOR 选择器（applyAccentColor/saveAccentColor）
 * 恢复在这里，写入即时生效，ThemesEngineService.saveAccentColor 内部已带 recomputePresentation()。
 *
 * TC-0415/TC-0417 返修（diag-suite_settings_appearance-TC-0415.md 附 -round2.md「修法方向」
 * F1-F4；diag-suite_settings_appearance-TC-0417-round2.md「修法方向」F1）：round1 当时显式
 * 允许分期的"主题预设网格/云端主题列表"本轮补齐，屏体改为对位源侧 themePickerControllerEntries
 * 的固定顺序：SELECT THEME 分节头 → chat-theme 网格(F2) → BUILD YOUR OWN THEME 分节头 →
 * 聊天预览(F5，round1 按诊断报告显式允许分期只落地壁纸底；round3 F-1 接上真实气泡)
 * → 基础主题横排(F3) → 强调色横排
 * (F4，改造为首项自定义取色器 + 四层圆形构造) → Edit Current Theme / Create a New Theme 两个
 * 动作行。原「ACCENT COLOR」分节头与「Selected: ...」文本是本页此前自造物，源侧没有对位
 * 物，本轮删除（F4.5）。
 *
 * round3 返修（diag-suite_settings_appearance-TC-0415-round3.md「修法方向」F-1/F-2/F-3；
 * F-4/F-5 需扩权，见下方「已知限制」）：
 *   - F-1（B3）：聊天预览块接上真实气泡渲染器 components/MessageBubble.cj（调用形态照
 *     AppearanceSettingsPage.cj:909/:944；fixture 照 :260-289），块高度改由内容撑开。
 *   - F-2（C4 分支 2/3）：强调色横排中心渐变小圆改按源侧 ThemeSettingsAccentColorItem.swift
 *     :380-403 的分支求色（dayClassic/nightAccent），不再用通用明暗公式；colorLighten/
 *     colorDarken 因此无调用点，一并删除。
 *   - F-3（D1）：色块选中态形变改为源侧 :324-339 量化表的三层联动（填充圆缩放 + 中心小圆
 *     选中态隐藏），不再是只有三个白点这一层响应选中态。
 *
 * TC-0400 round10 返修（diag-suite_settings_appearance-TC-0400-round10.md 派单扩权 TC-0415 E3a
 * + TC-0417 round3「修法方向」F-2）：
 *   - E3a：网格卡/基础主题卡的美术层接上真实缩略图渲染器
 *     `pages/AppearanceSettingsPage.cj:ThemeCarouselCardCanvas`（同包直接复用，不新写第二套绘制
 *     逻辑）——`buildThemeCardContent()` 的 builtin 分支不再是占位色块，云主题分支（`ThemeItem`
 *     无壁纸/气泡色字段）仍是占位底，本轮未开处方，如实保留。
 *   - TC-0417 F1-F3：`bindContextMenu(LongPress)` 换成 `onTouch`(300ms 长按识别) + `bindPopup`
 *     （本工程 `components/AnimatedEmojiComponent.cj` 已验证形状；理由见该组件 :280-284 的成文
 *     结论）；`themeCardMenuSlot()` 项集合按源侧 `ThemePickerController.swift:551-693` 重写：
 *     builtin 分支恰好一项 `Change Colors`（原「Apply Theme」单项在源侧此菜单里不存在，已删除，
 *     含其 `installTheme+saveThemePreset+saveAppearanceTheme+recomputePresentation` 调用序列——
 *     旧序列已随该项删除，网格卡应用主题的路径改为单击进入 `ThemePreviewPage`：
 *     该页已建出并注册进 route_map.json，`onThemeCardTap()` 会 push 到它，其
 *     `onApplyClick()` 调 `getAppTheme().applyTheme()` 落地应用，见下方「已知限制」）；云主题分支
 *     （`ThemeItem` 无 `isCreator` 字段，源侧 `Edit Theme` 分叉恒不可判定）固定三项 `Change
 *     Colors`/`Share`/`Remove`，动作本体本轮不实现（无落点承载物）。
 *   - round8 修复（本轮 required_fixes 甲）：菜单弹出位置改为逐卡片锚定——挂在 `ForEach` 内每个
 *     `GridItem` 自己的 `bindPopup` 上，第一实参改用索引型共享 `@State var menuVisibleIdx: Int64`
 *     （先例 `pages/StorageUsagePage.cj:133` 的 `showMenuFor: Int64`，同一份共享状态在 4 个
 *     call site 逐行比较；本文件同一个 `ForEach` 的 `isSelected` 早已证明按内容/索引区分同一份
 *     共享状态可行），逐项比较 `this.menuVisibleIdx == idx`，不再用单一容器锚点。
 *
 * 已知限制（详见 featureX.md「已知限制」，此处只记代码级根因）：
 *   - centerBubbleColors() 的分支 1（源侧 item.color?.plainBubbleColors 非空时直接取该强调色
 *     配套的气泡色）同样依赖上面这个求色入口的接入（入口本体已存在，接入仍未做），本轮只落地
 *     分支 2/3（dayClassic/nightAccent 的 HSB 公式分支），分支 1 与"无强调色"两个兜底常量分支
 *     按 round3 §6.2 写出但保持不可达（本屏 7 个色块全部来自 accentPalette()，不存在色值缺失的
 *     状态）。
 *   - 网格卡的 onClick 路由到 "ThemePreviewPage"（对位源侧 previewTheme）：该页面已建出
 *     （`pages/ThemePreviewPage.cj`），已注册进
 *     route_map.json（pageSourceFile src/main/ets/pages/ThemePreviewPage.ets），其
 *     `onApplyClick()` 调 `getAppTheme().applyTheme(targetTheme)` 挂在真实的 "Apply For All
 *     Chats" 按钮上——单击网格卡 → `ThemePreviewPage` → "Apply For All Chats" →
 *     `applyTheme()` 是当前真实可用的内置主题应用路径，长按菜单删除「Apply Theme」项不等于本屏
 *     失去应用主题的入口。网格卡长按上下文入口路由到 "ThemeAccentColorPickerPage"（对位源侧
 *     ThemeAccentColorController，diag-suite_settings_appearance-TC-0415.md §七 F4.1）：目标侧
 *     无该屏，归 shell_settings_wallpaper，该路由名未注册进 route_map.json——实测本工程既有条目
 *     的 pageSourceFile 无一缺失（`hvigor full` 会解析该字段生成路由代码），注册指向不存在页面
 *     的条目会让 `build.sh full` 失败，故本轮只在调用点预留路由名字符串，不写 route_map.json
 *     占位条目；该页面建出后其 Worker 需同步在 route_map.json 补注册。
 *   - 长按上下文菜单（对位 themeContextAction 三分叉，round10 重写见上方「TC-0400 round10
 *     返修」条目）：builtin 分支的 "Change Colors" 只做路由跳转，云主题分支三项动作本体本轮不
 *     实现——目标侧无对应的分享面板/云主题删除确认 ActionSheet 承载这些动作的结果，属另一议题。
 *     旧版（round1-round9）在 builtin 分支挂的 `installTheme + saveThemePreset +
 *     saveAppearanceTheme + recomputePresentation` 应用序列已随「Apply Theme」项一并删除（该
 *     动作在源侧此菜单里不存在）——网格卡应用内置主题改走单击进入 `ThemePreviewPage`（已建出，
 *     见上一条）的路径，不是失去应用入口；基础主题横排则按源端直接应用并重建页内预览。云主题分支同理没有等价的
 *     "当前应用云主题"本地缓存机制（ThemesDataProvider/ThemesEngineService 均未提供写入口）。
 */
@HybridComponentEntry
@Component
public class ChatThemesPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var selectedAccentIndex: Int32 = 0
    @State var loaded: Bool = false
    @State var currentThemePreset: Int32 = 0
    @State var selectedCloudThemeSlug: String = ""
    @State var chatThemeItems: Array<ThemeItem> = Array<ThemeItem>()
    @State var gridCards: Array<ThemeCardData> = Array<ThemeCardData>()
    @State var baseThemeCards: Array<ThemeCardData> = Array<ThemeCardData>()
    @State var contextMenuCard: ThemeCardData = ThemeCardData()
    @State var screenWidthVp: Float64 = 377.0
    // TC-0417 F1-F3 round3 (diag-suite_settings_appearance-TC-0417-round3.md F-2): this SDK's
    // bindContextMenu is a drag-preview implementation that can cancel before aboutToAppear
    // (components/AnimatedEmojiComponent.cj:280-284 documents the same finding) — mirrored here is
    // that file's own validated replacement, a manual 300ms-hold TouchEvent recognizer +
    // bindPopup.
    // round8 fix (required_fixes 甲): index-typed shared @State, per-card comparison — precedent
    // pages/StorageUsagePage.cj:133 (`showMenuFor: Int64`, compared per-row at 4 bindPopup call
    // sites from one shared field). -1 means no card's menu is open; each GridItem's own
    // bindPopup compares `this.menuVisibleIdx == idx`, so only the pressed card's popup opens,
    // anchored to that card.
    @State var menuVisibleIdx: Int64 = -1
    private var pressActive: Bool = false
    private var pressGeneration: Int64 = 0
    private var touchStartX: Float64 = 0.0
    private var touchStartY: Float64 = 0.0
    // Consumed by the grid's .onClick to swallow the synthetic tap ArkUI still fires after a
    // long-press-released touch sequence (same guard AnimatedEmojiComponent.cj:234-237 uses).
    private var suppressNextTap: Bool = false
    // F-1（round3）：聊天预览块改为内容驱动高度，对位源侧 ThemeSettingsChatPreviewItem.swift
    // :206-211 contentSize.height = 4 + 4 + Σ node.height（AppearanceSettingsPage.cj:1195-1200
    // 同型先例）。
    //
    // round7 修复（diag-suite_settings_appearance-TC-0415-round4.md F-B3）：这个回路只能收缩、
    // 不能增长——buildChatPreview() 的 Stack.height(previewContentHeight) 是内层消息 Column 的
    // 布局上限（maxSize），onAreaChange 报回的 h 永远 ≤ 当前 previewContentHeight；一旦初值低于
    // 真实内容高，h 就被夹在这个偏低的上限之下、和当前值的差值进不了 0.5vp 的更新阈值，回路停在
    // 一个错误的稳定不动点上（旧初值 1.0 → 实测收敛在 ≈1.14vp，整块塌成细线）。初值必须是真实
    // 内容高的上界，回路第一步会把它从上界收缩到真值再稳定——同 AppearanceSettingsPage.cj:207-209
    // 的写法与理由。取 260.0：本页预览块套在分组卡内（左右各 margin 16vp），可用宽度只有
    // screenWidthVp-32（narrower than AppearanceSettingsPage 的 377.1vp 整屏宽度），同一对
    // fixture 在更窄的宽度下换行更多、内容更高，AppearanceSettingsPage 202.0 的初值不够；260.0
    // 相对该页面实测的可用宽度留出足够余量，仍然是安全上界（过大只是首帧多留白，一步收缩到位；
    // 过小才是致命的——见上）。
    @State var previewContentHeight: Float64 = 260.0
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    // TC-0415 F2：页内夜间预览（对位 ThemePickerController.swift:943-998 nightModePreviewPromise）。
    // 只重映射本屏绘制，不写 Appearance Night Mode / setAutoNightEnabled。
    @State var nightModePreview: Bool = false
    @State var previewMountToggle: Bool = false
    @State var previewBubbleMountToggle: Bool = false
    @State var nightIconReady: Bool = false
    @State var nightIconFrameIndex: Int64 = 0
    @State var nightIconActiveReverse: Bool = false
    @State var themePatternUris: HashMap<String, String> = HashMap<String, String>()
    private var nightIconLoadStarted: Bool = false
    private var nightIconFramesSun: ArrayList<PixelMap> = ArrayList<PixelMap>()
    private var nightIconFramesSunReverse: ArrayList<PixelMap> = ArrayList<PixelMap>()
    private var nightIconDurationMs: Int32 = 17
    private var nightIconTimer: Option<Timer> = None<Timer>
    private let NIGHT_ICON_TINT_COLOR: UInt32 = 0x000000
    private let NIGHT_ICON_SIZE: Int32 = 26
    private let themeSelectionChangedEvent: String = "settings.chatThemes.selectionChanged"

    // 与改前 pre:101-113 accentPalette() 逐值一致（Telegram iOS 预设 accent 顺序），
    // 未改动调色板本身，只是把它从已删除的 Appearance 根屏挪回这个真正的目的地。
    private func accentPalette(): Array<UInt32> {
        return [
            0x317AFF, // 0: Blue (default)
            0x52C45C, // 1: Green
            0xFF8A00, // 2: Orange
            0xFF3B30, // 3: Red
            0xAF52DE, // 4: Purple
            0xFF2D55, // 5: Pink
            0x5AC8FA  // 6: Cyan
        ]
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        subscribe(this.themeSelectionChangedEvent, { slug: String =>
            launch { this.selectedCloudThemeSlug = slug }
        })
        this.loadSettings()
        this.baseThemeCards = this.buildBaseThemeCards()
        this.gridCards = this.buildGridCards()
        this.loadChatThemes()
        this.ensureNightIconLoaded()
    }

    private func loadSettings(): Unit {
        let svc = getThemesEngineService()
        let savedAccent = svc.getAccentColor()
        let palette = this.accentPalette()
        var foundIdx: Int32 = 0
        var i: Int64 = 0
        while (i < palette.size) {
            if (palette[i] == savedAccent) {
                foundIdx = Int32(i)
            }
            i = i + 1
        }
        let savedPreset = svc.getThemePreset()
        let savedSlug = svc.getSelectedChatThemeSlug()
        let previewInputsChanged = foundIdx != this.selectedAccentIndex ||
            savedPreset != this.currentThemePreset || savedSlug != this.selectedCloudThemeSlug
        this.selectedAccentIndex = foundIdx
        this.currentThemePreset = savedPreset
        this.selectedCloudThemeSlug = savedSlug
        // MessageBubble keeps its theme inputs as instance state.  The page's first build happens
        // before onAppear loads persisted settings, so a changed accent/base reference must
        // destroy and recreate the preview bubbles.  The equality gate prevents ensureLoaded()
        // and the same onAppear refresh from toggling twice and cancelling each other.
        if (previewInputsChanged) {
            this.previewMountToggle = !this.previewMountToggle
            this.previewBubbleMountToggle = !this.previewBubbleMountToggle
        }
        Hilog.info(0, "CjTelegram", "[ChatThemes] Loaded: accentIndex=${this.selectedAccentIndex} preset=${this.currentThemePreset}")
    }

    // F2：网格数据源已就绪，直接接 ThemesDataProvider 同型先例
    // pages/ChatQrCodeSharePage.cj:151-159 loadChatThemes() 的 spawn+launch 范式。
    private func loadChatThemes(): Unit {
        spawn {
            let result = getThemesEngineService().getChatThemes(0)
            let items = result.themes.toArray()
            launch {
                this.chatThemeItems = items
                this.gridCards = this.buildGridCards()
                this.resolveChatThemePatterns(items)
            }
        }
    }

    private func cloudVariantIndexForMode(item: ThemeItem, dark: Bool): Int64 {
        var i: Int64 = 0
        while (i < item.settingsVariants.size) {
            let base = item.settingsVariants[i].baseTheme
            if (dark) {
                if (base == "night" || base == "tinted") { return i }
            } else if (base == "classic" || base == "day" || base == "arctic") {
                return i
            }
            i++
        }
        return if (item.settingsVariants.size > 0) { 0 } else { -1 }
    }

    private func cloudCardColorsForMode(item: ThemeItem, dark: Bool): ThemeIconColors {
        let index = this.cloudVariantIndexForMode(item, dark)
        if (index < 0) { return cloudCardColors(item) }
        let variant = item.settingsVariants[index]
        let selected = ThemeItem()
        selected.hasSettings = true
        selected.settingsBaseTheme = variant.baseTheme
        selected.settingsAccentColor = variant.accentColor
        selected.settingsMessageColors = variant.messageColors
        selected.wallpaperColors = variant.wallpaperColors
        return cloudCardColors(selected)
    }

    private func cloudPatternSlugForMode(item: ThemeItem, dark: Bool): String {
        let index = this.cloudVariantIndexForMode(item, dark)
        if (index >= 0) { return item.settingsVariants[index].wallpaperSlug }
        return item.wallpaperSlug
    }

    private func cloudPatternIntensityForMode(item: ThemeItem, dark: Bool): Float64 {
        let index = this.cloudVariantIndexForMode(item, dark)
        if (index >= 0) {
            let variant = item.settingsVariants[index]
            return Float64(if (variant.wallpaperHasIntensity) { variant.wallpaperIntensity } else { Int32(50) }) / 100.0
        }
        return Float64(if (item.wallpaperHasIntensity) { item.wallpaperIntensity } else { Int32(50) }) / 100.0
    }

    private func patternMapKey(themeSlug: String, dark: Bool): String {
        return themeSlug + if (dark) { "_dark" } else { "_light" }
    }

    private func resolveChatThemePatterns(items: Array<ThemeItem>): Unit {
        // The source pipeline fetches each cloud wallpaper as a MediaBox resource and emits the
        // completed map back to the UI.  Our MTProtoClient has one synchronous request channel, so
        // firing one coroutine per card makes the replies race for that channel and leaves most
        // requests waiting forever.  Resolve them in one worker, de-duplicate the identical
        // light/dark slugs, then publish one immutable state update just like the source signal.
        let capturedItems = items
        let _ = spawn {
            let resources = getWallpaperResourcesService()
            let uriBySlug = HashMap<String, String>()
            let resolved = HashMap<String, String>()
            for (item in capturedItems) {
                for (dark in [false, true]) {
                    let wallpaperSlug = this.cloudPatternSlugForMode(item, dark)
                    if (wallpaperSlug.size == 0) { continue }
                    var uri = ""
                    if (uriBySlug.contains(wallpaperSlug)) {
                        uri = uriBySlug[wallpaperSlug]
                    } else {
                        let wallpaper = resources.getWallPaper(wallpaperSlug)
                        if (wallpaper.hasDocument) {
                            uri = resources.downloadWallpaperThumb(wallpaper)
                        }
                        uriBySlug[wallpaperSlug] = uri
                    }
                    if (uri.size > 0) {
                        resolved[this.patternMapKey(item.slug, dark)] = uri
                    }
                }
            }
            spawn(UIThread) {
                =>
                let next = HashMap<String, String>()
                for ((key, value) in resolved) { next[key] = value }
                this.themePatternUris = next
            }
        }
    }

    private func cardUsesDarkMode(): Bool {
        return this.nightModePreview || this.presentation.autoNightModeTriggered
    }

    private func cardPatternFile(card: ThemeCardData): String {
        if (card.isBuiltin) {
            return getWallpaperBackgroundService().getDefaultPatternFile()
        }
        let key = this.patternMapKey(card.cloudSlug, this.cardUsesDarkMode())
        if (this.themePatternUris.contains(key)) { return this.themePatternUris[key] }
        return ""
    }

    private func cardPatternIntensity(card: ThemeCardData): Float64 {
        if (card.isBuiltin) { return if (this.cardUsesDarkMode()) { -0.34 } else { 0.5 } }
        return this.cloudPatternIntensityForMode(card.sourceItem, this.cardUsesDarkMode())
    }

    private func cardColors(card: ThemeCardData): ThemeIconColors {
        if (card.isBuiltin) {
            return themeIconColors(this.builtinKindForCard(card, true))
        }
        return this.cloudCardColorsForMode(card.sourceItem, this.cardUsesDarkMode())
    }

    // F2 集合构造：对位 ThemePickerController.swift:1023-1024 —— 先按 emoticon 非空过滤云主题，
    // 再在头部插入内置 dayClassic。贴纸走 card.sourceItem.emoticon，不再用 title 当卡下 caption。
    private func buildGridCards(): Array<ThemeCardData> {
        let result = ArrayList<ThemeCardData>()
        let builtin = ThemeCardData()
        builtin.isBuiltin = true
        builtin.builtinIndex = 0
        builtin.displayName = "Classic"
        result.add(builtin)
        for (item in this.chatThemeItems) {
            if (item.emoticon.size > 0) {
                let card = ThemeCardData()
                card.isBuiltin = false
                card.cloudId = item.id
                card.cloudSlug = item.slug
                card.displayName = item.title
                card.sourceItem = item
                result.add(card)
            }
        }
        return result.toArray()
    }

    // F3 集合：defaultThemes 非触发态四档（dayClassic/nightAccent/day/night），对位源侧
    // ThemeSettingsController.swift:1003-1015（auto-night 收窄分支未接线，见类头「已知限制」）。
    private func buildBaseThemeCards(): Array<ThemeCardData> {
        let c0 = ThemeCardData()
        c0.isBuiltin = true
        c0.builtinIndex = 0
        c0.displayName = "Classic"
        let c1 = ThemeCardData()
        c1.isBuiltin = true
        c1.builtinIndex = 1
        // The source runtime language pack presents nightAccent as "Dark" in this picker. Keep it
        // localizable instead of exposing the target's stale built-in "Tinted Night" fallback.
        c1.displayName = trSource("Dark")
        let c2 = ThemeCardData()
        c2.isBuiltin = true
        c2.builtinIndex = 2
        c2.displayName = "Day"
        let c3 = ThemeCardData()
        c3.isBuiltin = true
        c3.builtinIndex = 3
        c3.displayName = this.sourceLocalizationPresentation.getOr(
            "Appearance_ThemeCarouselNewNight", "Night")
        return [c0, c1, c2, c3]
    }

    private func visibleBaseThemeCards(): Array<ThemeCardData> {
        if (!this.presentation.autoNightModeTriggered) {
            return this.baseThemeCards
        }
        let result = ArrayList<ThemeCardData>()
        for (card in this.baseThemeCards) {
            if (card.builtinIndex == THEME_KIND_NIGHT_ACCENT || card.builtinIndex == THEME_KIND_NIGHT) {
                result.add(card)
            }
        }
        return result.toArray()
    }

    private func effectiveThemePreset(): Int32 {
        if (this.presentation.autoNightModeTriggered) {
            return automaticNightThemePreset()
        }
        return this.currentThemePreset
    }

    private func applyAccentColor(index: Int32): Unit {
        this.selectedAccentIndex = index
        let hex = this.accentPalette()[Int64(index)]
        let svc = getThemesEngineService()
        svc.saveAccentColor(hex)
        // ThemePickerController.selectAccentColorImpl writes a complete
        // PresentationThemeAccentColor, whose bubble colours participate in the rebuilt
        // PresentationData.  Keep the target's existing split persistence in sync: the accent
        // drives controls while the derived bubble colour drives both this preview and chats.
        svc.saveCustomBubbleColor(this.centerBottomColor(index))
        this.previewMountToggle = !this.previewMountToggle
        this.previewBubbleMountToggle = !this.previewBubbleMountToggle
        Hilog.info(0, "CjTelegram", "[ChatThemes] Applied accent[${index}]: 0x${hex.toString()}")
    }

    // The BUILD YOUR OWN base-theme row is ThemeSettingsThemeItem, not ThemeGridThemeItem.
    // Source calls selectTheme immediately from this row and its presentation-data signal then
    // rebuilds the embedded preview.  It never opens ThemePreviewController from this action.
    private func applyBaseTheme(card: ThemeCardData): Unit {
        if (!card.isBuiltin) { return }
        this.discardNightPreview()
        this.currentThemePreset = card.builtinIndex
        this.selectedCloudThemeSlug = ""

        let svc = getThemesEngineService()
        clearActiveThemeWallpapers()
        svc.saveSelectedChatThemeSlug("")
        let dark = card.builtinIndex == THEME_KIND_NIGHT_ACCENT || card.builtinIndex == THEME_KIND_NIGHT
        if (this.presentation.autoNightModeTriggered) {
            // ThemePickerController.selectThemeImpl updates automaticThemeSwitchSetting.theme in
            // this branch and leaves the daytime settings.theme intact.
            saveAutomaticNightThemePreset(card.builtinIndex)
        } else {
            svc.saveThemePreset(card.builtinIndex)
            getAuthStorage().saveAppearanceTheme(if (dark) { 1 } else { 0 })
        }
        svc.saveCustomBubbleColor(this.centerBottomColor(this.selectedAccentIndex))
        let _ = recomputePresentation()
        this.previewMountToggle = !this.previewMountToggle
        this.previewBubbleMountToggle = !this.previewBubbleMountToggle

        spawn {
            let baseId: Int32 = if (card.builtinIndex == THEME_KIND_DAY_CLASSIC) { 0 }
                else if (card.builtinIndex == THEME_KIND_NIGHT_ACCENT) { 3 }
                else if (card.builtinIndex == THEME_KIND_DAY) { 1 }
                else { 2 }
            let _ = svc.installTheme(dark, None, None, Some(baseId))
        }
        Hilog.info(0, "CjTelegram", "[ChatThemes] Applied build-own base theme: ${card.builtinIndex}")
    }

    private func selectedCloudThemeIsCreator(): Bool {
        let selected = getThemesEngineService().getSelectedChatThemeSlug()
        if (selected.size == 0) { return false }
        for (item in this.chatThemeItems) {
            if (item.slug == selected) { return item.isCreator }
        }
        return false
    }

    // F4.4：点已选中项的分叉（对位源侧 ThemeSettingsAccentColorItem.swift:902-925）——
    // 已选中 ⇒ 打开自定义取色器（路由名预留，见类头「已知限制」）；未选中 ⇒ 应用该颜色。
    private func onSwatchClick(index: Int32): Unit {
        if (index == this.selectedAccentIndex) {
            routerPush("ThemeAccentColorPickerPage", "accent=" + this.accentPalette()[Int64(index)].toString())
        } else {
            this.applyAccentColor(index)
        }
    }

    // SELECT A THEME 网格点击边（对位源侧 previewTheme，ThemePickerController.swift:397-420）。
    // BUILD YOUR OWN 的基础主题横排使用 applyBaseTheme()，不能复用这条预览路由。
    private func onThemeCardTap(card: ThemeCardData): Unit {
        let previewDark = this.cardUsesDarkMode()
        if (card.isBuiltin) {
            let previewRef = if (previewDark && card.builtinIndex == THEME_KIND_DAY_CLASSIC) {
                THEME_KIND_NIGHT
            } else {
                card.builtinIndex
            }
            setPendingThemePreviewConfiguration(makeBuiltinThemePreviewConfiguration(previewRef))
            this.discardNightPreview()
            routerPush("ThemePreviewPage", "{\"builtin\":true,\"ref\":${previewRef}}")
        } else {
            setPendingThemePreviewConfiguration(makeCloudThemePreviewConfiguration(
                card.sourceItem, previewDark, this.cardPatternFile(card)))
            this.discardNightPreview()
            routerPush("ThemePreviewPage", "{\"builtin\":false,\"slug\":\"${card.cloudSlug}\",\"dark\":${previewDark}}")
        }
    }

    private func shareCloudTheme(): Unit {
        let slug = this.contextMenuCard.cloudSlug
        if (slug.size == 0) {
            return
        }
        this.menuVisibleIdx = -1
        let item = ExternalContentItem()
        item.kind = "text"
        item.textValue = "https://t.me/addtheme/" + slug
        let items = ArrayList<ExternalContentItem>()
        items.add(item)
        setPendingExternalContent(items)
        routerPush("ShareControllerPage", "")
    }

    private func confirmRemoveCloudTheme(): Unit {
        let slug = this.contextMenuCard.cloudSlug
        if (slug.size == 0) {
            return
        }
        this.menuVisibleIdx = -1
        let cancelButton = AlertDialogButtonOptions(value: trSource("Cancel"), action: { => () })
        let removeButton = AlertDialogButtonOptions(
            value: trSource("Remove"),
            fontColor: 0xFFFF3B30,
            action: { => this.removeCloudTheme(slug) }
        )
        this.getUIContext().showAlertDialog(AlertDialogParamWithOptions(
            title: trSource("Remove Theme"),
            message: trSource("Are you sure you want to remove this theme?"),
            autoCancel: true,
            buttons: [cancelButton, removeButton]
        ))
    }

    private func removeCloudTheme(slug: String): Unit {
        spawn {
            let removed = getThemesEngineService().saveTheme(slug, true)
            if (removed) {
                launch {
                    let updated = ArrayList<ThemeCardData>()
                    for (card in this.gridCards) {
                        if (card.isBuiltin || card.cloudSlug != slug) {
                            updated.add(card)
                        }
                    }
                    this.gridCards = updated.toArray()
                }
            }
        }
    }

    // ==================== F-2（round3 §6.2）中心小圆求色 ====================
    // D-195 镜像：全仓唯一的 HSB<->RGB 转换实现是 core/storage/AppTheme.cj:435-504 的
    // clamp01/rgbToHsv/hsvToRgb，三者都非 public（默认 internal）且该文件不在本 feature
    // allowlist 内——逐字节镜像到本文件，语义不改，来源见各函数注释。

    // 镜像：core/storage/AppTheme.cj:435-437 clamp01。
    private func clamp01Local(x: Float64): Float64 {
        return max(0.0, min(1.0, x))
    }

    // 镜像：core/storage/AppTheme.cj:441-464 rgbToHsv。r/g/b 各 in [0,1]，返回 (hue, sat, val)，
    // hue 归一化到 [0,1]（对位 UIColor(hue:saturation:brightness:) 的约定）。
    private func rgbToHsvLocal(r: Float64, g: Float64, b: Float64): (Float64, Float64, Float64) {
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

    // 镜像：core/storage/AppTheme.cj:467-504 hsvToRgb（rgbToHsvLocal 的逆运算）。
    private func hsvToRgbLocal(h: Float64, s: Float64, v: Float64): (Float64, Float64, Float64) {
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

    private func hexToHsv(hex: UInt32): (Float64, Float64, Float64) {
        let r = Float64((hex >> 16) & 0xFF) / 255.0
        let g = Float64((hex >> 8) & 0xFF) / 255.0
        let b = Float64(hex & 0xFF) / 255.0
        return this.rgbToHsvLocal(r, g, b)
    }

    private func hsvToHex(h: Float64, s: Float64, v: Float64): UInt32 {
        let (r, g, b) = this.hsvToRgbLocal(h, s, v)
        let ri = UInt32(this.clamp01Local(r) * 255.0)
        let gi = UInt32(this.clamp01Local(g) * 255.0)
        let bi = UInt32(this.clamp01Local(b) * 255.0)
        return (ri << 16) | (gi << 8) | bi
    }

    // F-2（C4 分支 2/3）：中心小圆求色，对位源侧 ThemeSettingsAccentColorItem.swift:380-403。
    // 分支选择复用本文件已有的 F-5 明暗身份约定（:currentThemePreset==1|3 为深色档，见
    // themeCardMenuSlot 内同一判断），不新造第二套判据。分支 1（plainBubbleColors）与
    // 「无强调色」两个兜底常量分支依赖上面「已知限制」里那个求色入口的接入（入口本体
    // `themeIconColors()` 已存在，接入仍未做）/在本屏结构上不可达，round3 §6.2 明确
    // "写出但不可达时不得因此省略"——本条不适用（没有可挂载无强调色分支的调用点），故如实只
    // 落地可达的分支 2/3。
    private func centerBubbleColors(index: Int32): (UInt32, UInt32) {
        let accent = this.swatchColor(index)
        let (h, s, v) = this.hexToHsv(accent)
        if (this.currentThemePreset == 1 || this.currentThemePreset == 3) {
            // nightAccent 基准（源码 :395-396）：bottom = accent.withMultiplied(1.019, 0.731, 0.59)；
            // top = bottom.withMultiplied(0.966, 0.61, 0.98)。
            let bottomH = this.clamp01Local(h * 1.019)
            let bottomS = this.clamp01Local(s * 0.731)
            let bottomV = this.clamp01Local(v * 0.59)
            let bottom = this.hsvToHex(bottomH, bottomS, bottomV)
            let topH = this.clamp01Local(bottomH * 0.966)
            let topS = this.clamp01Local(bottomS * 0.61)
            let topV = this.clamp01Local(bottomV * 0.98)
            let top = this.hsvToHex(topH, topS, topV)
            return (top, bottom)
        } else {
            // dayClassic 基准（源码 :386，本屏当前默认基准）：s' = 0.14（有色相且非全暗时）或
            // 0（否则），v' = 0.79 + v*0.21，h' 不变；top = bottom（源码同一个 bubbleColor）。
            var sPrime = 0.0
            if (s > 0.0 && v > 0.0) {
                sPrime = 0.14
            }
            let vPrime = this.clamp01Local(0.79 + v * 0.21)
            let bubbleColor = this.hsvToHex(h, sPrime, vPrime)
            return (bubbleColor, bubbleColor)
        }
    }

    // @Builder 函数体内不能写 let（S-005），centerBubbleColors() 的元组结果需要两个独立、
    // 无 let 的调用点分别取值——对位本文件已有的 previewWallpaper() 多处内联调用同型先例。
    private func centerTopColor(index: Int32): UInt32 {
        let (top, _bottom) = this.centerBubbleColors(index)
        return top
    }

    private func centerBottomColor(index: Int32): UInt32 {
        let (_top, bottom) = this.centerBubbleColors(index)
        return bottom
    }

    // F2 几何（对位 ThemePickerGridItem.swift:409-433）：屏宽 >=390vp 走 110vp 参考卡，
    // 否则 90vp；padding=12vp（两侧共 24vp）、minSpacing=6vp，列数按公式算而非写死。
    private func gridColumns(): Int64 {
        let refW = if (this.screenWidthVp >= 390.0) { 110.0 } else { 90.0 }
        let minSpacing = 6.0
        let available = this.screenWidthVp - 24.0
        let cols = Int64((available - minSpacing) / (refW + minSpacing))
        if (cols < 1) {
            return 1
        }
        return cols
    }

    private func gridColumnsTemplate(): String {
        let cols = this.gridColumns()
        var s = ""
        var i: Int64 = 0
        while (i < cols) {
            s = s + "1fr "
            i = i + 1
        }
        return s
    }

    private func gridRows(): Int64 {
        let cols = this.gridColumns()
        let n = Int64(this.gridCards.size)
        if (n == 0) {
            return 0
        }
        var rows = n / cols
        if (n % cols != 0) {
            rows = rows + 1
        }
        return rows
    }

    private func gridHeight(): Float64 {
        let rows = this.gridRows()
        if (rows == 0) {
            return 0.0
        }
        return Float64(rows) * 116.0 + Float64(rows - 1) * 6.0
    }

    // TC-0415 F2：页内 preview 色表。不写 @StorageLink presentation，离开本屏即丢弃。
    private func pagePresentation(): PresentationSnapshot {
        if (this.nightModePreview) {
            return resolvePresentationSnapshot(this.presentation.theme, true)
        }
        return this.presentation
    }

    private func chromeCard(): UInt32 {
        if (this.nightModePreview) {
            return resolveThemeColorTable(this.presentation.theme, true).cardColor
        }
        return this.presentation.cardColor
    }

    private func chromeGrouped(): UInt32 {
        if (this.nightModePreview) {
            return resolveThemeColorTable(this.presentation.theme, true).backgroundColor
        }
        return this.presentation.backgroundColor
    }

    private func chromeText(): UInt32 {
        if (this.nightModePreview) {
            return resolveThemeColorTable(this.presentation.theme, true).textColor
        }
        return this.presentation.textColor
    }

    private func chromeNav(): UInt32 {
        if (this.nightModePreview) {
            return resolveThemeColorTable(this.presentation.theme, true).navBarColor
        }
        return this.presentation.navBarColor
    }

    private func colorWithOpaqueAlpha(c: UInt32): UInt32 {
        if (((c >> 24) & 0xFF) == 0) {
            return c | 0xFF000000
        }
        return c
    }

    private func nightPreviewGradientColors(night: ThemeIconColors): Array<UInt32> {
        let out = ArrayList<UInt32>()
        for (c in night.wallpaperColors) {
            out.add(this.colorWithOpaqueAlpha(c))
        }
        return out.toArray()
    }

    private func previewWallpaper(): WallpaperInfo {
        let previewKind = if (this.nightModePreview) { THEME_KIND_NIGHT } else { this.effectiveThemePreset() }
        let night = themeIconColors(previewKind)
        let info = WallpaperInfo()
        info.wallpaperType = if (night.wallpaperColors.size > 1) {
            WallpaperType.MultiColorGradient
        } else {
            WallpaperType.SolidColor
        }
        info.gradientColors = this.nightPreviewGradientColors(night)
        if (night.wallpaperColors.size > 0) {
            info.gradientColorStart = this.colorWithOpaqueAlpha(night.wallpaperColors[0])
            info.gradientColorEnd = this.colorWithOpaqueAlpha(night.wallpaperColors[night.wallpaperColors.size - 1])
            info.solidColor = this.colorWithOpaqueAlpha(night.wallpaperColors[0])
        }
        // DefaultDayPresentationTheme uses a plain wallpaper only for Day. Classic, Night and
        // Night Accent all use Telegram's bundled pattern document; Night's negative intensity
        // selects the source renderer's inverted/dark branch.
        if (previewKind != THEME_KIND_DAY) {
            info.patternFile = getWallpaperBackgroundService().getDefaultPatternFile()
            info.patternOverlayEnabled = true
            info.patternIntensity = if (previewKind == THEME_KIND_NIGHT) { -0.34 } else { 0.5 }
        }
        info.isDarkMode = this.previewThemeIsDark()
        return info
    }

    private func previewThemeIsDark(): Bool {
        if (this.nightModePreview) { return true }
        let preset = this.effectiveThemePreset()
        return preset == THEME_KIND_NIGHT_ACCENT || preset == THEME_KIND_NIGHT
    }

    private func previewIncomingBubbleColor(): UInt32 {
        return themeIconColors(this.effectiveThemePreset()).incomingBubbleColor
    }

    private func previewOutgoingBubbleColor(): UInt32 {
        return this.centerBottomColor(this.selectedAccentIndex)
    }

    private func previewTextColor(): UInt32 {
        return if (this.previewThemeIsDark()) { 0xFFFFFF } else { 0x000000 }
    }

    private func themeCardCanvasH(showUnderCardCaption: Bool): Float64 {
        if (showUnderCardCaption) {
            return 120.0
        }
        return 116.0
    }

    private func builtinKindForCard(card: ThemeCardData, forGrid: Bool): Int32 {
        if (forGrid && (this.nightModePreview || this.presentation.autoNightModeTriggered)) {
            return THEME_KIND_NIGHT
        }
        return card.builtinIndex
    }

    // 网格卡面贴纸：云主题用 emoticon；builtin Classic 无 emoticon 时叠源参照帧的 🏠。
    private func gridCardSticker(card: ThemeCardData): String {
        if (card.sourceItem.emoticon.size > 0) {
            return card.sourceItem.emoticon
        }
        return "🏠"
    }

    private func nightPreviewKeySuffix(): String {
        if (this.nightModePreview) {
            return "night"
        }
        return "day"
    }

    private func discardNightPreview(): Unit {
        if (this.nightModePreview) {
            this.nightModePreview = false
            this.previewMountToggle = !this.previewMountToggle
            this.previewBubbleMountToggle = !this.previewBubbleMountToggle
        }
        this.stopNightIconPlayback()
        this.nightIconActiveReverse = false
        let frames = this.activeNightIconFrames()
        if (frames.size > 0) {
            this.nightIconFrameIndex = Int64(frames.size) - 1
        } else {
            this.nightIconFrameIndex = 0
        }
    }

    private func leaveChatThemes(): Unit {
        this.discardNightPreview()
        routerPop()
    }

    private func toggleNightModePreview(): Unit {
        this.nightModePreview = !this.nightModePreview
        this.previewMountToggle = !this.previewMountToggle
        this.previewBubbleMountToggle = !this.previewBubbleMountToggle
        this.startNightIconPlayback()
    }

    private func tintNightIconFrame(source: Array<UInt8>): Array<UInt8> {
        let result = source.clone()
        let red: UInt16 = UInt16((this.NIGHT_ICON_TINT_COLOR >> 16) & 0xFF)
        let green: UInt16 = UInt16((this.NIGHT_ICON_TINT_COLOR >> 8) & 0xFF)
        let blue: UInt16 = UInt16(this.NIGHT_ICON_TINT_COLOR & 0xFF)
        var index: Int64 = 0
        while (index + 3 < Int64(result.size)) {
            let alpha = UInt16(result[index + 3])
            result[index] = UInt8((blue * alpha) / 255)
            result[index + 1] = UInt8((green * alpha) / 255)
            result[index + 2] = UInt8((red * alpha) / 255)
            index = index + 4
        }
        return result
    }

    private func renderNightIconFrames(resourceName: String, cacheKey: String): ArrayList<PixelMap> {
        let frames = ArrayList<PixelMap>()
        match (readRawFileBytes(resourceName)) {
            case None =>
                Hilog.info(0, "CjTelegram", "[ChatThemes] nightToggle missing ${resourceName}")
                return frames
            case Some(bytes) =>
                let native = getTelegramLottieNative().renderTgs(
                    bytes, "chatthemes_night_${cacheKey}", this.NIGHT_ICON_SIZE, maxFrames: 30
                )
                if (!native.success) { return frames }
                let options = InitializationOptions(
                    IKSize(this.NIGHT_ICON_SIZE, this.NIGHT_ICON_SIZE),
                    srcPixelFormat: PixelMapFormat.Bgra8888,
                    pixelFormat: PixelMapFormat.Bgra8888,
                    alphaType: AlphaType.Premul
                )
                for (frame in native.frames) {
                    frames.add(createPixelMap(this.tintNightIconFrame(frame), options))
                }
                if (frames.size > 0) { this.nightIconDurationMs = native.frameDurationMs }
                return frames
        }
    }

    private func ensureNightIconLoaded(): Unit {
        if (this.nightIconLoadStarted) { return }
        this.nightIconLoadStarted = true
        spawn {
            let sunFrames = this.renderNightIconFrames("anim_sun.json", "sun")
            let reverseFrames = this.renderNightIconFrames("anim_sun_reverse.json", "sun_reverse")
            launch {
                this.nightIconFramesSun = sunFrames
                this.nightIconFramesSunReverse = reverseFrames
                if (sunFrames.size > 0 || reverseFrames.size > 0) {
                    this.nightIconActiveReverse = this.nightModePreview
                    let active = this.activeNightIconFrames()
                    this.nightIconFrameIndex = if (active.size > 0) { Int64(active.size) - 1 } else { 0 }
                    this.nightIconReady = true
                }
            }
        }
    }

    // 浅色态用 sun_reverse（弯月+星芒），夜间 preview 用 sun（太阳）。对位 ChatQrCodeSharePage F-6。
    private func activeNightIconFrames(): ArrayList<PixelMap> {
        if (this.nightIconActiveReverse) { return this.nightIconFramesSun }
        return this.nightIconFramesSunReverse
    }

    private func startNightIconPlayback(): Unit {
        this.stopNightIconPlayback()
        if (!this.nightIconReady) { return }
        this.nightIconActiveReverse = this.nightModePreview
        let frames = this.activeNightIconFrames()
        let count = Int64(frames.size)
        if (count <= 1) {
            this.nightIconFrameIndex = 0
            return
        }
        this.nightIconFrameIndex = 0
        var interval = this.nightIconDurationMs
        if (interval < 16) { interval = 16 }
        this.nightIconTimer = Some(Timer.repeat(
            Duration.millisecond * Int64(interval), Duration.millisecond * Int64(interval),
            { =>
                launch {
                    if (this.nightIconFrameIndex + 1 >= count) {
                        this.nightIconFrameIndex = count - 1
                        this.stopNightIconPlayback()
                    } else {
                        this.nightIconFrameIndex = this.nightIconFrameIndex + 1
                    }
                }
            }, style: CatchupStyle.Skip
        ))
    }

    private func stopNightIconPlayback(): Unit {
        match (this.nightIconTimer) {
            case Some(timer) =>
                timer.cancel()
                this.nightIconTimer = None<Timer>
            case None => ()
        }
    }

    private func currentNightIconFrame(): PixelMap {
        let frames = this.activeNightIconFrames()
        if (this.nightIconFrameIndex >= 0 && this.nightIconFrameIndex < Int64(frames.size)) {
            return frames.get(this.nightIconFrameIndex).getOrThrow()
        }
        return getEmptyAnimatedEmojiPixelMap()
    }

    // F2/F3 共用卡面（diag-suite_settings_appearance-TC-0400-round10.md 派单扩权 TC-0415 E3a：
    // 与 AppearanceSettingsPage.cj buildCarouselCard() 同根因，同样缺 Canvas 缩略图渲染器）。
    // builtin 卡与云主题卡都用 pages/AppearanceSettingsPage.cj:ThemeCarouselCardCanvas（同包直接
    // 复用，不新写第二套绘制逻辑）；云主题卡的四色改用 cloudCardColors(card.sourceItem)（TC-0400
    // round12 F-C 第 3 条 + TC-0415 round2 M-1a，替换此前的 ITEM_LIST_SEPARATOR 占位底——该占位是
    // ThemeItem 尚无壁纸/气泡色字段时的临时状态，M-1b/M-1c 已把这些字段补齐，见本文件上方
    // cloudCardColors()）。
    @Builder
    func buildThemeCardContent(card: ThemeCardData, isSelected: Bool, showUnderCardCaption: Bool) {
        Column {
            Stack {
                WallpaperBackgroundComponent(
                    wallpaperType: WallpaperType.MultiColorGradient,
                    solidColor: this.cardColors(card).backgroundColor,
                    gradientColorStart: this.cardColors(card).backgroundColor,
                    gradientColorEnd: this.cardColors(card).backgroundColor,
                    gradientAngle: 180.0,
                    imageUri: "",
                    fallbackColor: this.cardColors(card).backgroundColor,
                    gradientColors: this.cardColors(card).wallpaperColors,
                    phase: 0,
                    isDarkMode: this.cardUsesDarkMode(),
                    patternIntensity: this.cardPatternIntensity(card),
                    patternFile: this.cardPatternFile(card),
                    patternOverlayEnabled: this.cardPatternFile(card).size > 0
                )
                ThemeCarouselCardCanvas(
                    wallpaperColors: this.cardColors(card).wallpaperColors,
                    incomingColor: this.cardColors(card).incomingBubbleColor,
                    outgoingColor: this.cardColors(card).outgoingBubbleColor,
                    fallbackColor: this.cardColors(card).backgroundColor,
                    canvasW: 90.0,
                    canvasH: this.themeCardCanvasH(showUnderCardCaption),
                    drawBackground: false
                )
                if (!showUnderCardCaption) {
                    Text(this.gridCardSticker(card))
                        .fontSize(34)
                        .align(Alignment.Bottom)
                        .margin(bottom: 6)
                }
            }
            .width(100.percent)
            .layoutWeight(1)

            if (showUnderCardCaption) {
                Text(card.displayName)
                    .fontSize(13)
                    .fontColor(this.chromeText())
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .padding(top: 4, bottom: 4)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.chromeCard())
        // ThemePickerGridItem.swift gives every imageNode a 16 pt corner radius.
        .borderRadius(16)
        .clip(true)
        .border(width: if (isSelected) { 3 } else { 0 }, color: ITEM_LIST_ACCENT, radius: 16)
    }

    // TC-0417 F1-F3 round3 (diag-suite_settings_appearance-TC-0417-round3.md F-2 item1):
    // components/AnimatedEmojiComponent.cj:280-284 documents this SDK's bindContextMenu as a
    // drag-preview implementation that can cancel before aboutToAppear — this file's own long
    // press never reliably surfaced a menu. Mirrors that same file's own onTouch(300ms hold) +
    // bindPopup replacement (:286-325/:368-381), the only in-repo shape with a device-passed
    // record (also used verbatim by pages/DevicesPage.cj:1253-1266).
    private func handleCardTouch(evt: TouchEvent, card: ThemeCardData, idx: Int64): Unit {
        match (evt.eventType) {
            case TouchType.Down =>
                if (evt.touches.size > 0) {
                    this.touchStartX = evt.touches[0].x
                    this.touchStartY = evt.touches[0].y
                }
                this.pressActive = true
                this.pressGeneration = this.pressGeneration + 1
                let generation = this.pressGeneration
                spawn {
                    sleep(300 * Duration.millisecond)
                    launch {
                        if (this.pressActive && this.pressGeneration == generation) {
                            this.pressActive = false
                            this.suppressNextTap = true
                            this.contextMenuCard = card
                            this.menuVisibleIdx = idx
                        }
                    }
                }
            case TouchType.Move =>
                if (this.pressActive && evt.touches.size > 0) {
                    let dx = evt.touches[0].x - this.touchStartX
                    let dy = evt.touches[0].y - this.touchStartY
                    if (dx * dx + dy * dy > 100.0) {
                        this.pressActive = false
                        this.pressGeneration = this.pressGeneration + 1
                    }
                }
            case TouchType.Up =>
                this.pressActive = false
                this.pressGeneration = this.pressGeneration + 1
            case TouchType.Cancel =>
                this.pressActive = false
                this.pressGeneration = this.pressGeneration + 1
            case _ => ()
        }
    }

    // F2：chat-theme 网格（对位 .themes / ThemeGridThemeItem）。长按挂上下文入口
    // （TC-0417 round3 F-2，对位源侧 :163-165 contextAction）。
    // round3 boundary condition (F-2 item6): keyGeneratorFunc / GridItem.height(150) /
    // columnsTemplate/columnsGap/rowsGap/padding below and onThemeCardTap are untouched — the
    // grid geometry already passed and onThemeCardTap is the F-3 contract source (ThemePreviewPage
    // round), unrelated to this menu-surfacing fix.
    // popup anchor note (round8 fix, required_fixes 甲): bindPopup is now declared per GridItem
    // inside the ForEach, anchored to that item — precedent pages/StorageUsagePage.cj:133
    // (`showMenuFor: Int64`, one shared field compared per-row at 4 call sites). The visibility
    // condition is `this.menuVisibleIdx == idx`, so only the pressed card's own bindPopup opens
    // and it anchors to that card, matching source's per-card `.reference(sourceView:)` anchor.
    @Builder
    func buildChatThemeGrid() {
        Grid() {
            // RF-2 返修（round5）：ThemeCardData 未实现 ToString，默认 keyGenerator 退化为纯
            // index 键（D-127）——isSelected 靠外部字段 this.currentThemePreset 驱动而非卡片
            // 自身内容，key 不变就不会重新执行 itemGenerator，Apply Theme 后选中描边刷不出来。
            // 显式提供覆盖 currentThemePreset 的内容指纹键（isBuiltin+builtinIndex+cloudId 保证
            // 身份唯一，不含 idx）。
            ForEach(this.gridCards, itemGenerator: { card: ThemeCardData, idx: Int64 =>
                GridItem() {
                    this.buildThemeCardContent(
                        card,
                        if (card.isBuiltin) {
                            this.selectedCloudThemeSlug.size == 0 && card.builtinIndex == this.currentThemePreset
                        } else {
                            card.cloudSlug == this.selectedCloudThemeSlug
                        },
                        false
                    )
                }
                .height(116)
                .onClick({ _ =>
                    if (this.suppressNextTap) {
                        this.suppressNextTap = false
                    } else {
                        this.onThemeCardTap(card)
                    }
                })
                .onTouch({ evt => this.handleCardTouch(evt, card, idx) })
                .bindPopup(
                    this.menuVisibleIdx == idx,
                    CustomPopupOptions(
                        builder: bind(this.themeCardMenuSlot, this),
                        placement: Placement.Bottom,
                        popupColor: Color.Transparent,
                        enableArrow: false,
                        autoCancel: true,
                        radius: 14.vp,
                        onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                            if (!evt.isVisible && this.menuVisibleIdx == idx) {
                                this.menuVisibleIdx = -1
                                this.suppressNextTap = false
                            }
                        })
                    )
                )
            }, keyGeneratorFunc: { card: ThemeCardData, _idx: Int64 =>
                var prefix = "cloud"
                if (card.isBuiltin) {
                    prefix = "builtin"
                }
                // WallpaperBackgroundComponent draws into Canvas during aboutToAppear.  Its
                // pattern file arrives asynchronously, so include that resource identity in the
                // item key and remount the card once the source MediaBox equivalent is ready.
                "${prefix}_${card.builtinIndex}_${card.cloudId}_${this.currentThemePreset}_${this.selectedCloudThemeSlug}_${this.nightPreviewKeySuffix()}_${this.cardPatternFile(card)}"
            })
        }
        .columnsTemplate(this.gridColumnsTemplate())
        .columnsGap(6)
        .rowsGap(6)
        .width(100.percent)
        .height(this.gridHeight())
        .padding(left: 12, right: 12, top: 4, bottom: 4)
        // ThemeGridThemeItemNode inserts itemBlocksBackgroundColor behind the complete grid and
        // masks the section as one rounded block.  Keep the gaps and perimeter on that block,
        // rather than exposing the page background between otherwise-correct theme images.
        .backgroundColor(this.chromeCard())
        .borderRadius(16)
        .clip(true)
    }

    // 长按上下文菜单容器 —— TC-0417 round3 F-2 item3，按源侧 ThemePickerController.swift:551-693
    // 的三分叉重写（原「Apply Theme」单项是源侧此菜单里根本不存在的动作：源侧「应用主题」是卡片单击
    // previewTheme → 预览屏 Apply For All Chats 的路径，不是长按菜单项，见类头「已知限制」）。
    // TC-0417 round13 返修（diag-suite_settings_appearance-TC-0417-round5.md OF-4，
    // 处方取 round4.md §F-2）：四个 MenuItem.startIcon 此前全部误写成同一个
    // @r(app.media.chatroom_ic_check)（消息已读回执勾，语义不相干），round3 F-2 第 5 点把
    // 「ApplyTheme 缺资产」越界推广成了「四项全占位」，本轮按 F-2 纠正：ApplyTheme 两处
    // （builtin/cloud 的 Change Colors）换成新转换的 @r(app.media.chatroom_ic_applytheme)
    // （对位 Chat/Context Menu/ApplyTheme.imageset，仓内此前无对位资产，本轮新增）；Share
    // 换成已在仓的 @r(app.media.media_ic_share)（同一源资产 Chat/Context Menu/Share 的既有
    // 转换件，逐字符核验对齐，直接复用不新建）；Remove 换成新转换的
    // @r(app.media.chatroom_ic_removetheme)（clist_ic_delete.svg 的同形复制件，只把
    // fill="#000000" 改成 fill="#ff3b30"，对位源侧 theme.contextMenu.destructiveColor——
    // MenuItem.startIcon 只收 ResourceStr、无运行时 tint 入口，颜色只能烘进资源本体；
    // clist_ic_delete.svg 本身不改，它有其它在用调用点）。
    @Builder
    func themeCardMenuSlot() {
        Menu {
            if (this.contextMenuCard.isBuiltin) {
                // 源侧 builtin 分支（:680-688）恰好一项：Change Colors → push
                // ThemeAccentColorController(mode: .colors(...))。目标侧对位路由
                // ThemeAccentColorPickerPage 与本文件 :224/:681 已在用的预留名一致——该屏归另一
                // feature 的在册缺口（TC-0415 §七 F4.1），本轮不建、不注册 route_map.json。
                MenuItem(
                    startIcon: @r(app.media.chatroom_ic_applytheme),
                    content: "Change Colors",
                    endIcon: "",
                    labelInfo: "",
                    builder: None<() -> Unit>
                )
                    .onClick({ _ => routerPush("ThemeAccentColorPickerPage", "") })
            } else {
                // 云主题分支：目标侧 ThemeItem 无 isCreator 字段，源侧的 isCreator 分支
                // （Edit Theme）恒不可判定 ⇒ 恒走源侧 else 分支的三项固定顺序。三项动作本体本轮不
                // 实现（Change Colors 需要先解析云壁纸再进 ThemeAccentColorController.edit
                // 模式；Share/Remove 的落点——分享面板、云主题删除确认 ActionSheet——目标侧无承载
                // 物），已在 featureX.md「已知限制」如实披露。
                MenuItem(
                    startIcon: @r(app.media.chatroom_ic_applytheme),
                    content: "Change Colors",
                    endIcon: "",
                    labelInfo: "",
                    builder: None<() -> Unit>
                )
                    .onClick({ _ =>
                        this.menuVisibleIdx = -1
                        routerPush("ThemeAccentColorPickerPage", "slug=" + this.contextMenuCard.cloudSlug)
                    })
                MenuItem(
                    startIcon: @r(app.media.media_ic_share),
                    content: "Share",
                    endIcon: "",
                    labelInfo: "",
                    builder: None<() -> Unit>
                )
                    .onClick({ _ => this.shareCloudTheme() })
                MenuItem(
                    startIcon: @r(app.media.chatroom_ic_removetheme),
                    content: "Remove",
                    endIcon: "",
                    labelInfo: "",
                    builder: None<() -> Unit>
                )
                    .contentFontColor(0xFFFF3B30)
                    .onClick({ _ => this.confirmRemoveCloudTheme() })
            }
        }
    }

    // F-1（round3 §6.1）聊天预览 fixture——函数体逐字照抄 AppearanceSettingsPage.cj:260-289
    // （ThemeSettingsChatPreviewItem.swift:163-172 的两条 ChatPreviewMessageItem）。不得在
    // incoming 上设 senderName（源侧 incoming author 恒为 nil，TC-0400 F-3r 已立案）。
    private func previewIncomingMessage(): Message {
        let msg = Message()
        msg.rawTimestamp = 66000
        msg.time = formatMessageTimestampAt(66000, 66000, true)
        msg.isLastInGroup = true
        msg.isSingleMessage = true
        msg.isSent = false
        msg.content = "Ah you kids today with techno music! Enjoy the classics, like Hasselhoff!"
        msg.replyToMsgId = 3
        msg.replyToSenderName = "Lucio"
        msg.replyToText = "Reinhardt, we need to find you some..."
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
        msg.content = "I can't take you seriously right now. Sorry.."
        return msg
    }

    // 调用形态逐字照抄 AppearanceSettingsPage.cj:909-918/:944-953。components/MessageBubble.cj
    // 不在本轮改动面，只允许调用、不得修改。颜色取 pagePresentation()（night preview 重映射）。
    // MessageBubble 六个主题色是 @State，已挂载实例不吃新入参（D-197）；必须由
    // previewBubbleMountToggle 的 D-160 双分支销毁重建，不能只改传参。
    @Builder
    func buildPreviewIncomingBubble() {
        MessageBubble(
            message: this.previewIncomingMessage(),
            voicePlaybackEpoch: 0,
            bubbleOutColor: this.previewOutgoingBubbleColor(),
            bubbleInColor: this.previewIncomingBubbleColor(),
            bubbleOutTextColor: this.previewTextColor(),
            bubbleInTextColor: this.previewTextColor(),
            replyAuthorAccentColor: this.swatchColor(this.selectedAccentIndex),
            bubbleOutAccentTextColor: 0x00A700
        )
    }

    @Builder
    func buildPreviewOutgoingBubble() {
        MessageBubble(
            message: this.previewOutgoingMessage(),
            voicePlaybackEpoch: 0,
            bubbleOutColor: this.previewOutgoingBubbleColor(),
            bubbleInColor: this.previewIncomingBubbleColor(),
            bubbleOutTextColor: this.previewTextColor(),
            bubbleInTextColor: this.previewTextColor(),
            replyAuthorAccentColor: this.swatchColor(this.selectedAccentIndex),
            bubbleOutAccentTextColor: 0x00A700
        )
    }

    // F5/F-1：聊天预览（round1 只落地壁纸底；round3 F-1 接上真实气泡渲染器，不再手搓
    // Column/Text 假气泡）。高度改由内容撑开，对位源侧 :206-211 contentSize.height =
    // 4 + 4 + Σ node.height（AppearanceSettingsPage.cj:1195-1219 同型先例）。
    @Builder
    func buildChatPreview() {
        Stack {
            if (this.previewMountToggle) {
                WallpaperBackgroundComponent(
                    wallpaperType: this.previewWallpaper().wallpaperType,
                    solidColor: this.previewWallpaper().solidColor,
                    gradientColorStart: this.previewWallpaper().gradientColorStart,
                    gradientColorEnd: this.previewWallpaper().gradientColorEnd,
                    gradientAngle: this.previewWallpaper().gradientAngle,
                    imageUri: this.previewWallpaper().imageUri,
                    fallbackColor: getWallpaperBackgroundService().getFallbackColor(),
                    gradientColors: this.previewWallpaper().gradientColors,
                    phase: this.previewWallpaper().phase,
                    isDarkMode: this.previewThemeIsDark(),
                    patternIntensity: this.previewWallpaper().patternIntensity,
                    patternFile: this.previewWallpaper().patternFile,
                    patternOverlayEnabled: this.previewWallpaper().patternOverlayEnabled
                )
            } else {
                WallpaperBackgroundComponent(
                    wallpaperType: this.previewWallpaper().wallpaperType,
                    solidColor: this.previewWallpaper().solidColor,
                    gradientColorStart: this.previewWallpaper().gradientColorStart,
                    gradientColorEnd: this.previewWallpaper().gradientColorEnd,
                    gradientAngle: this.previewWallpaper().gradientAngle,
                    imageUri: this.previewWallpaper().imageUri,
                    fallbackColor: getWallpaperBackgroundService().getFallbackColor(),
                    gradientColors: this.previewWallpaper().gradientColors,
                    phase: this.previewWallpaper().phase,
                    isDarkMode: this.previewThemeIsDark(),
                    patternIntensity: this.previewWallpaper().patternIntensity,
                    patternFile: this.previewWallpaper().patternFile,
                    patternOverlayEnabled: this.previewWallpaper().patternOverlayEnabled
                )
            }
            Column {
                // D-160/D-197：对照 AppearanceSettingsPage.cj:1168-1172。两分支逐字相同，
                // 宏按源码位置分配不同 branchId；previewBubbleMountToggle 随 night 翻转后
                // 销毁重建两颗 MessageBubble，新实例 @State init 吃到 pagePresentation() 夜色。
                // 禁止改 MessageBubble.cj；禁止把钮接到 setAutoNightEnabled。
                if (this.previewBubbleMountToggle) {
                    this.buildPreviewIncomingBubble()
                    this.buildPreviewOutgoingBubble()
                } else {
                    this.buildPreviewIncomingBubble()
                    this.buildPreviewOutgoingBubble()
                }
            }
            .width(100.percent)
            .padding(top: 4, bottom: 4)
            .onAreaChange({ _: Area, newArea: Area =>
                let h = newArea.height.value
                if (h > this.previewContentHeight + 0.5 || h < this.previewContentHeight - 0.5) {
                    this.previewContentHeight = h
                }
            })
        }
        .width(100.percent)
        .height(this.previewContentHeight)
        .borderRadius(topLeft: 12, topRight: 12)
        .clip(true)
    }

    // F3：基础主题横排（对位 .theme / ThemeSettingsThemeItem）。
    @Builder
    func buildBaseThemeRow() {
        Row {
            // RF-2 返修（round5）：同 buildChatThemeGrid 理由（D-127），显式覆盖
            // currentThemePreset，否则 Apply Theme 后本行选中描边不刷新。builtinIndex
            // 在本数组内本就唯一，直接作身份前缀。
            ForEach(this.visibleBaseThemeCards(), itemGenerator: { card: ThemeCardData, _idx: Int64 =>
                Stack {
                    this.buildThemeCardContent(card, card.builtinIndex == this.effectiveThemePreset(), true)
                    // WallpaperBackgroundComponent/Canvas consume pointer hit-testing in their
                    // painted area on this SDK.  Source exposes the complete 116pt item as one
                    // button, so keep a dedicated full-card activation layer above the artwork.
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        // A fully transparent empty node is optimized out of hit-testing by this
                        // ArkUI runtime.  Alpha 1/255 keeps a real activation surface while being
                        // visually indistinguishable from transparent.
                        .backgroundColor(0x01000000)
                        .onClick({ _ => this.applyBaseTheme(card) })
                }
                .width(90)
                .height(150)
                .margin(right: 12)
            }, keyGeneratorFunc: { card: ThemeCardData, _idx: Int64 =>
                "${card.builtinIndex}_${this.effectiveThemePreset()}_${this.nightPreviewKeySuffix()}"
            })
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 12)
    }

    // F4.1：首项自定义取色器（对位 generateCustomSwatchImage，:499-527）——42x42vp 画布内
    // 七个 10x10vp 圆点，色值与坐标逐个照抄。
    @Builder
    func buildAccentPickerSwatch() {
        Column {
            Stack {
                Circle().width(10).height(10).fill(0xd33213).position(x: 14, y: 16)
                Circle().width(10).height(10).fill(0xf08200).position(x: 14, y: 0)
                Circle().width(10).height(10).fill(0xedb400).position(x: 28, y: 8)
                Circle().width(10).height(10).fill(0x70bb23).position(x: 28, y: 24)
                Circle().width(10).height(10).fill(0x5396fa).position(x: 14, y: 32)
                Circle().width(10).height(10).fill(0x9472ee).position(x: 0, y: 24)
                Circle().width(10).height(10).fill(0xeb6ca4).position(x: 0, y: 8)
            }
            .width(42)
            .height(42)
        }
        .width(60)
        .height(60)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .margin(right: 10)
        .onClick({ _ => routerPush("ThemeAccentColorPickerPage", "") })
    }

    // F4.2：色块四层圆形构造（对位 generateFillImage/generateRingImage/generateCenterImage/
    // generateDotsImage）。F4.3：不再用 border() 表示选中——圆角/描边被 wrapper 清零的机制
    // （common_component.cj:1080-1088 borderInner）本轮已随该写法整体移除而回避。
    // S-005：@Builder 函数体内不能写 let——本函数把「取该 index 的强调色」抽成普通函数，
    // buildSwatch 内改为逐处直接调用 this.swatchColor(index)。
    private func swatchColor(index: Int32): UInt32 {
        return this.accentPalette()[Int64(index)]
    }

    @Builder
    func buildSwatch(index: Int32) {
        Column {
            Stack {
                // F-3（round3 §6.3/D1）：填充圆随选中态缩放，量化值取自源侧 setSelected
                // (:324-339)——选中 scale 1.0（32vp）、未选中 scale 1.2（38.4vp）。案文 §6 D 组
                // 那句白话描述把大小写反了（round3 §五「转 Specwriter」已订正），这里严格按
                // 量化表落地，不按那句白话。
                if (this.selectedAccentIndex == index) {
                    Column {}
                        .width(32)
                        .height(32)
                        .borderRadius(16)
                        .backgroundColor(this.swatchColor(index))
                } else {
                    Column {}
                        .width(38.4)
                        .height(38.4)
                        .borderRadius(19.2)
                        .backgroundColor(this.swatchColor(index))
                }

                // RF-1 返修（round5）：0x00000000 会被 ohos/base/color.cj alphaAdapt() 强制补
                // alpha=0xFF 渲染成不透明黑色实心圆（D-144/D-175），改用 Color.Transparent
                // （ohos.base.cj.d 定义为 Color(0,0,0,alpha:0.0)，VideoCallScreen.cj:1125 已验证）。
                // 描边圆环两态都渲染，不随选中态变化（量化表：环恒定 38 直径）。
                Circle()
                    .width(38)
                    .height(38)
                    .fill(Color.Transparent)
                    .stroke(this.swatchColor(index))
                    .strokeWidth(2)

                // F-3：中心气泡色渐变小圆——选中态隐藏（对位源侧 scale 0.16 + alpha 0 的
                // 视觉等效呈现），未选中态渲染。F-2（centerTopColor/centerBottomColor）求色。
                if (this.selectedAccentIndex != index) {
                    Column {}
                        .width(20)
                        .height(20)
                        .borderRadius(10)
                        .linearGradient(angle: 180.0, colors: [
                            (Color(this.centerTopColor(index)), 0.0),
                            (Color(this.centerBottomColor(index)), 1.0)
                        ])
                }

                if (this.selectedAccentIndex == index) {
                    Column {}.width(4).height(4).borderRadius(2).backgroundColor(0xFFFFFF).position(x: 11, y: 18)
                    Column {}.width(4).height(4).borderRadius(2).backgroundColor(0xFFFFFF).position(x: 18, y: 18)
                    Column {}.width(4).height(4).borderRadius(2).backgroundColor(0xFFFFFF).position(x: 25, y: 18)
                }
            }
            .width(40)
            .height(40)
        }
        .width(60)
        .height(58)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .margin(right: 10)
        .onClick({ _ => this.onSwatchClick(index) })
    }

    // F4：强调色横排（无分节头，源侧是 BUILD YOUR OWN THEME 分节内部的一行，F4.5 删除本页
    // 此前自造的 ACCENT COLOR 分节头与 Selected: 文本）。
    @Builder
    func buildAccentColorRow() {
        Row {
            this.buildAccentPickerSwatch()
            this.buildSwatch(0)
            this.buildSwatch(1)
            this.buildSwatch(2)
            this.buildSwatch(3)
            this.buildSwatch(4)
            this.buildSwatch(5)
            this.buildSwatch(6)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 12)
        .justifyContent(FlexAlign.Start)
    }

    // F1 动作行 7：Edit Current Theme（对位 ItemListPeerActionItem，:337）。源侧分叉
    // （云主题且 settings 为空 ⇒ 表单；否则 ⇒ 取色器）目标侧无云主题模型也无取色器屏，
    // 本行按「进 Edit 表单」单支落地（对位 EditThemePage.cj 类头注释里记的同一约定）。
    @Builder
    func buildEditCurrentThemeRow() {
        Row {
            Image(@r(app.media.chatroom_ic_applytheme))
                .width(20)
                .height(20)
                .fillColor(ITEM_LIST_ACCENT)
                .margin(right: 12)

            Text(trSource("Edit Current Theme"))
                .fontSize(16)
                .fontColor(ITEM_LIST_ACCENT)
                .layoutWeight(1)
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .backgroundColor(this.chromeCard())
        .alignItems(VerticalAlign.Center)
        .onClick({ _ =>
            this.discardNightPreview()
            if (this.selectedCloudThemeIsCreator()) {
                routerPush("EditThemePage", "edit")
            } else {
                routerPush("ThemeAccentColorPickerPage", "createTheme")
            }
        })
    }

    // F1 动作行 8：Create a New Theme（对位 ItemListPeerActionItem，:338）。图标用矢量绘制的
    // "+"（两条细条），不用 emoji/文本字形替代（本 suite 已多次判负该形态）。
    @Builder
    func buildCreateNewThemeRow() {
        Row {
            Stack {
                Column {}.width(16).height(2).backgroundColor(ITEM_LIST_ACCENT)
                Column {}.width(2).height(16).backgroundColor(ITEM_LIST_ACCENT)
            }
            .width(20)
            .height(20)
            .margin(right: 12)

            Text(trSource("Create a New Theme"))
                .fontSize(16)
                .fontColor(ITEM_LIST_ACCENT)
                .layoutWeight(1)
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .backgroundColor(this.chromeCard())
        .alignItems(VerticalAlign.Center)
        .onClick({ _ =>
            this.discardNightPreview()
            routerPush("ThemeAccentColorPickerPage", "createTheme")
        })
    }

    @Builder
    func buildNightPreviewButton() {
        Column {
            if (this.nightIconReady) {
                Image(this.currentNightIconFrame())
                    .width(26)
                    .height(26)
            }
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor(0xB3F2F2F7)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.toggleNightModePreview() })
    }

    public func build() {
        Column {
            // 导航栏：真实返回 chevron，沿用 AutoNightSettingsPage.cj 三件套模板的既有约定。
            Row {
                Row {
                    Image(@r(app.media.callui_v2_back))
                        .width(10)
                        .height(18)
                        .fillColor(ITEM_LIST_ACCENT)
                }
                .width(44)
                .height(44)
                .borderRadius(22)
                .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ => this.leaveChatThemes() })
                Blank().layoutWeight(1)
                Text(trSource("Chat Themes"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.chromeText())
                Blank().layoutWeight(1)
                if (this.presentation.autoNightModeTriggered) {
                    Row {}.width(60)
                } else {
                    this.buildNightPreviewButton()
                }
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .backgroundColor(this.chromeNav())
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    // F1 段 1：SELECT THEME 分节头（字面量取 Localizable.strings:7206 的
                    // Select Theme 大写形态）。
                    ItemListSectionHeader(title: "SELECT A THEME", topPad: 16)
                    // F1 段 2：chat-theme 网格。
                    this.buildChatThemeGrid()

                    // F1 段 3：BUILD YOUR OWN THEME 分节头（:7207 大写形态）。
                    ItemListSectionHeader(title: "BUILD YOUR OWN THEME", topPad: 24)
                    Column {
                        // F1 段 4：聊天预览（F5，允许分期）。
                        this.buildChatPreview()
                        ItemListSeparator()
                        // F1 段 5：基础主题横排（F3）。
                        this.buildBaseThemeRow()
                        ItemListSeparator()
                        // F1 段 6：强调色横排（F4）。
                        this.buildAccentColorRow()
                    }
                    .backgroundColor(this.chromeCard())
                    .borderRadius(12)
                    .margin(left: 16, right: 16, top: 12)

                    // F1 段 7/8：Edit Current Theme / Create a New Theme 两个动作行。
                    Column {
                        this.buildEditCurrentThemeRow()
                        ItemListSeparator()
                        this.buildCreateNewThemeRow()
                    }
                    .backgroundColor(this.chromeCard())
                    .borderRadius(12)
                    .margin(left: 16, right: 16, top: 16, bottom: 32)
                }
                .padding(bottom: 32)
            }
            .layoutWeight(1)
            .backgroundColor(this.chromeGrouped())
        }
        .width(100.percent)
        .height(100.percent)
        // D-194:本页自绘顶部 chrome,必须成对预留 getSafeAreaTop()(这里)与 .ets 壳的
        // .expandSafeArea(...)(ets/pages/ChatThemesPage.ets),否则导航栏内容会画进系统
        // 状态栏窗口而不可点击。
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .backgroundColor(this.chromeGrouped())
        .onAreaChange({ _: Area, newArea: Area => this.screenWidthVp = newArea.width.value })
        .onAppear({ =>
            this.ensureLoaded()
            // ThemePreviewPage is pushed over this page.  Refresh the persisted reference every
            // time it becomes visible again so the selection ring follows the theme that was
            // actually applied, matching ThemePickerController's live presentation-data signal.
            this.loadSettings()
        })
        .onDisAppear({ => this.discardNightPreview() })
    }
}
