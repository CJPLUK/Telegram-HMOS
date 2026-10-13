/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import kit.ImageKit.{createImageSource, createPixelMap, PixelMap, InitializationOptions, PixelMapFormat, AlphaType}
// kit.ArkUI.* 与 kit.ImageKit.Size 同名冲突（同 pages/WebBrowserSettingsPage.cj:24-25 先例），改名导入。
import kit.ImageKit.Size as IKSize
import kit.CoreFileKit.*
import std.math.*
import std.collection.ArrayList
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.storage.resolvePresentationSnapshot
import ohos_app_cangjie_entry.components.{WallpaperBackgroundComponent, AnimatedEmojiComponent, getEmptyAnimatedEmojiPixelMap, drawQrCodeMatrix}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.readRawFileBytes
import ohos_app_cangjie_entry.bindings.getTelegramLottieNative

/**
 * ChatQrCodeSharePage — QR 分享屏 (diag-suite_settings_root-TC-0074-qrsharescreen.md)
 *
 * 对应 iOS ChatQrCodeScreen（submodules/TelegramUI/Components/Chat/ChatQrCodeScreen/Sources/ChatQrCodeScreen.swift）：
 * 全屏模态 = 壁纸内容层（壁纸 + 二维码卡 + 头像）+ 底部主题条 sheet（关闭 X / 标题 /
 * 夜间切换 / 主题条 / Share QR Code / Scan QR Code）。此前该页从未在目标工程落地，
 * 入口一直被 `SettingsPage.cj` 的一个本地 300vp 覆盖层顶替（diag 报告 §4 M5）；本文件
 * 是该屏第一次真实建页，尺寸/颜色/文案/分支逐条引自诊断报告 §5/§7 读到的源码行。
 *
 * 混合迁移形态（与 `pages/QrScannerPage.cj` 逐字同构）：
 *  - @Component → @HybridComponentEntry，build() 根不套 NavDestination（D-148：本工程
 *    路由 SSOT 是 route_map.json + 每路由一个 .ets NavDestination 壳，NavDestination 包裹
 *    在 ArkTS 侧 `ets/pages/ChatQrCodeSharePage.ets`）。
 *  - 关闭动作用 routerPop()（对位源 `cancelButtonPressed` :1226-1228，`isModalRoute` 使
 *    本页语义为 Close 而非 Item，见 router/router.cj）。
 *  - 无入参：本页恒为「本人」主体（对位源 `subject: .peer`），不走 param_store。
 *
 * TC-0507 round5 整页重构（diag-suite_settings_root-TC-0507-round5.md，verdict=reconstruct，
 * 处方见该报告 §七 F-C；走 `.agent/skills/ui-page-reconstruct/SKILL.md`）：
 * round1/round2/round4 归因过同一 verdict，但实际派下去的是元素级返修单（margin/borderRadius/
 * Lottie 图标），本轮是第一次真正按"整页结构与源不同构"处理——7 条 FAIL 的共同根因是「源侧一条
 * 遮罩着色链 + 一套按主题求色的引擎」在目标侧被拆成了互不相干的字面量，逐元素补属性不可能收敛。
 * 本轮的两个前置依赖（`qrcode` 自绘矩阵 f2f8149bd、`core_presentation_data` 字段直通+
 * `resolvePresentationSnapshot` a057f145a）已随基线落地，是本轮能做整页重建的前提。改动摘要：
 *  - **RC-1 遮罩着色链**（F-C1/F-C2，A4a/A4b/A4c/A5-圆底）：码点/文案/logo 圆底不再各自取
 *    字面量色，改为「一份按主题压暗的壁纸内容 + 一份 alpha 遮罩」合成——遮罩内容＝QR 矩阵
 *    （挖空）＋文案＋logo 圆底，三者同源。ArkUI 这一层没有可用的"跨组件树栅格遮罩"能力
 *    （D-141 已核验 `maskShape` 只接受矢量路径），改用离屏 `CanvasRenderingContext2D`
 *    （不挂载到任何 `Canvas()` 节点，仅程序化调用——同 `services/DrawingFlattenService.cj`
 *    的 `flattenCanvas()` 先例）：先在一张画布上用 `WallpaperBackgroundComponent` 同款的
 *    `gradientPositionsForPhase`/`gradientComputePixel` 引擎画出压暗后的壁纸内容，再对另一张
 *    画布画出矩阵+文案+logo 圆底的"遮罩形状"（全部不透明黑，只取 alpha），取
 *    `getPixelMap()` 后以 `globalCompositeOperation="destination-in"` 合成——只保留内容画布
 *    落在遮罩形状范围内的像素，其余变透明，露出卡片白底。二者一次性合成为一张
 *    `PixelMap`（`qrMaskedContent`/`qrTextMaskedContent`），用 `Image(...)` 渲染，而不是
 *    继续挂 `WallpaperDimmedNodeComponent` 的实时组件树（该组件的像素在离屏合成阶段读不到，
 *    见其类头 F-A2 文档"内嵌真实渲染树"——只适用于"作为可见组件挂载"的场景，不适用于本页
 *    这种需要跨两张画布做像素级合成的场景；两者复用的是同一套 dim-alpha 公式 0.3/0.5，
 *    对位 `ChatQrCodeScreen.swift:1997`，不是另起一套颜色表）。
 *  - **RC-2 壁纸图案层**（F-C3，A1）：`buildWallpaperInstance()` 新增 `patternFile:` 实参，
 *    取值链逐字照抄 `pages/AppearanceSettingsPage.cj:579+:1070` 先例——
 *    `getWallpaperBackgroundService().getCurrentWallpaper().patternFile` 镜像进 `@State`，
 *    每个 `build()` pass 刷新（对位 D-125，镜像变化时顺带翻转 `wallpaperMountToggle` 强制
 *    `WallpaperBackgroundComponent` 重建，因为它是裸 `var` 字段、非挂载时刷新不生效）。
 *  - **RC-3 主题格三层**（F-C4/F-C5，B5a/A4b/B5c）：`themeCellCount()` 改为「1(内置) +
 *    有 `emoticon` 的云主题数」，对位源 `:1005-1011` 的 `guard let emoticon else continue`
 *    过滤（round5 之前 `ThemeItem` 无此字段，round5 F-B1/F-B2 已直通，见类头引用的
 *    `core_presentation_data` 交付）。每格三层结构（渐变缩略图 / QR 挖空标记 / emoji 贴纸）
 *    从"仅默认格"推广到"所有格"。TC-0507 A4b_theme_recolor 进一步把缩略图与全屏的色源
 *    统一为 `ThemeItem.settingsVariants/wallpaperColors`：按当前外观选择主题自带的 settings
 *    色板，不再按 slug 向壁纸文档发起第二次请求。
 *  - **RC-4 sheet/按钮联动**（F-C6，previewSheetColors 两形参从摆设变真用）：改为调用
 *    `core_presentation_data` 交付的纯函数 `resolvePresentationSnapshot(theme, isDark)` 取色，
 *    不再是恒定浅色档字面量。
 * 详见交付报告的 7 条 FAIL 逐条处理结果、结构对位说明、QR 编码正确性验证结论。
 *
 * 后续返修（diag-suite_settings_root-TC-0507.md，round5 整页重构落地后的首次复测，取代该
 * round5 报告作为派工依据；verdict=modify）：round5 的 RC-1 遮罩合成把两个 `CanvasRenderingContext2D`
 * 声明为裸对象、从未挂载到任何 `Canvas()` 节点——SDK 声明（`ohos.arkui.component.canvas.cj.d:212`）
 * 明写该类型的绘制面尺寸绑定其 `Canvas` 节点、未绑定时恒为 0，`getPixelMap()` 因此静默取回空
 * 内容（矩阵/文案两处全空，logo 圆底同源缺失；同文件已挂载的 `QrThemeCellIcon.holeCtx` 未受
 * 影响——这条"挂载的全活、未挂载的全灭"的分界线是本轮最强判别证据）。本轮四条改动：
 *  - **F-1（RC-1）**：把遮罩合成搬到真正挂载的画布——拆成 `QrMaskedMatrixCanvas` /
 *    `QrMaskedCaptionCanvas`（文件尾）两个独立 `@Component`，ctx 随组件实例构造、与其
 *    `build()` 内唯一的 `Canvas()` 节点原生配对（D-190 修法②，同型先例 `QrThemeCellIcon.holeCtx`）。
 *    合成次序改为「遮罩层（矩阵挖空+logo圆底/文案，不透明黑，`source-over`）先画，切
 *    `globalCompositeOperation="source-in"` 后单次 `drawImage` 压暗壁纸内容」——单次绘制是
 *    因为合成模式按绘制调用生效，遮罩天然是多次 `fill()` 调用，只能让内容以单次调用落在
 *    `source-in` 侧（原 `destination-in` 方向对、只是从未真正跑起来验证过）。内容改为手工按
 *    BGRA 构造 `PixelMap`（同 `renderNightIconFrames()` 先例），坐标改用屏幕全局像素原点
 *    （`onAreaChange` 回填的 `qrMaskOriginX/Y`），使卡内压暗壁纸与屏上同一位置对齐（round5
 *    的实现把渐变重新归一化进卡片自身盒子，对不上）。`buildQrCardArea()` 调用点随
 *    `buildWallpaperInstance()` 一并纳入既有的 `wallpaperMountToggle` 双分支挂载守卫（D-156/
 *    D-190），使裸 `var` 入参在主题/外观切换后能送到新构造的实例。
 *  - **F-4（RC-3）**：`previewSheetColors()` 选中云主题且该主题带 `settings` 时，强调色改取
 *    `ThemeItem.settingsAccentColor`（TL 层已解出、服务层已直通，不依赖 F-2）；默认格/无
 *    settings 的主题保留 `snapshot.accentColor`。
 *  - **F-5（RC-4）**：码卡底色改不透明白常量，不再跟 sheet 联动取色（对位
 *    `ChatQrCodeScreen.swift:1692-1693` 的无条件 `.white`）。
 *  - **F-6（RC-5）**：`activeNightIconFrames()` 的 `nightIconActiveReverse` 与两组已解码帧
 *    的对应关系互换，使浅色态渲染弯月+星芒、夜间态渲染太阳（round5 F-C7 记录的疑点，本轮
 *    双侧帧证据坐实映射接反）。
 * F-3（RC-2 页面侧）所依赖的 `core_presentation_data` 字段直通现已落地；TC-0507
 * A4b_theme_recolor 本轮直接消费这些字段，并移除旧的 slug 二次取数旁路。
 * QR 编码器（`components/QrCodeView.cj` 的 `drawQrCodeMatrix()`）本轮已被独立执行验证（离体
 * 编译、单独解码通过），不是本轮任何缺陷的成因。
 *
 * round3 返修（本轮唯一 required_fix，D-197 ERROR）：F-1 拆出的 `QrMaskedMatrixCanvas`/
 * `QrMaskedCaptionCanvas` 声明了 8 个裸 `var` 入参，但 `wallpaperMountToggle` 双分支挂载
 * 守卫此前只在 `selectThemeCell()`/`toggleNightMode()`（覆盖 `gradientColors`/`dimAlpha`）
 * 翻转，`link`（`loadUserInfo()` 里随 `userUsername`/`userPhone` 变化，经 `.onAppear` 严格晚于
 * 首次 `build()` 构造）与 `tileOriginX/Y`/`tileFieldW/H`（分别由内外两层 `Stack` 的
 * `onAreaChange` 回填）均未配套翻转，导致无 pattern 文件壁纸的用户首次进页看到码卡矩阵/文案
 * 一直空白直到第一次切主题或夜间模式。本轮在这三处赋值点都补上"值真变化才翻"的守卫翻转
 * （同 `refreshDerivedState()` F-C3 与 `pages/SettingsPage.cj:159-165` 的去重写法），4 类
 * 驱动源全部纳入同一把挂载守卫，详见 `build()` 内 F-1.6 注释与本轮交付报告。
 *
 * 历史 round 记录（round1 结构骨架 / round2 defaultWallpaperColors 校正 / round4 F-B1-B4
 * margin·borderRadius·Lottie 迁移）：三轮修法均未解决过 7 条 FAIL（round5 报告 §4.7 已述
 * 复发原因是处方粒度，不是归因精度），故不再复述其逐条 diff，历史事实见 git log 与
 * round4/round-2 diag 报告；round4 落地的 Lottie 夜间图标/logo 播放机制（RC-5，
 * `ensureNightIconLoaded`/`ensureQrLogoLoaded` 等）与本轮无关，原样保留。
 *
 * 已知限制（详见交付报告）：
 *  1. 主题格缩略图渐变引擎为轻量 `.linearGradient()`（2-4 档站点），不是全屏背景那套
 *     80×80 像素级多点漩涡混合——缩略图 64×88 很小，视觉上足够，且与 round-2 已定的默认格
 *     实现同构，不是新增简化。
 *  2. 遮罩合成后的文案改为离屏 Canvas `fillText` 绘制（`"bold {size}px sans-serif"`），
 *     不是源侧 `.rounded` 字重设计，也不再是可选中的原生文本节点（无障碍属性丢失）。
 *  3. QR 挖空区域圆盘底直径按 `components/QrCodeView.cj` 文档化的挖空占比公式
 *     （模块数 × 0.297）在像素空间复算——该常量本身是私有实现细节，未导出精确像素矩形，
 *     此处是同公式的忠实复算，非独立发明。
 *  4. `Share QR Code`/次按钮扫码图标 (`Settings/ScanQr` → `scanqr_24.pdf`) 未迁移，资源
 *     清单当前只有能力覆盖 `settings_ic_qr`（挖空标记用）/`devices_ic_qr_button`，新增独立
 *     图形资源不在本 feature `target_files` 白名单（仅含 3 个 rawfile 动画 + route_map），
 *     不属于本轮 scope。
 */
private let QR_CENTER_LOGO_ANIM_DOC_ID: Int64 = -9004001

// TC-0507 round5：遮罩合成画布尺寸常量（F-C1/F-C2）。QR 区维持既有 220vp；文案区独立一张
// 较矮画布，二者共享同一条纵向渐变场（见 paintQrSquareMask/paintQrTextMask 的 wholeHeight
// 参数化），避免拼接处色带断层。
private let QR_MASK_SIZE: Float64 = 220.0
private let QR_TEXT_MASK_HEIGHT: Float64 = 42.0

@HybridComponentEntry
@Component
public class ChatQrCodeSharePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ── 用户数据（与 SettingsPage.loadUserInfo 同源，同一批服务单例）──
    @State var userId: Int64 = 0
    @State var userUsername: String = ""
    @State var userPhone: String = ""
    @State var userDisplayName: String = ""
    @State var avatarText: String = "U"
    @State var avatarImageFailed: Bool = false
    @State var loaded: Bool = false

    // ── 屏幕实测宽高（onAreaChange 回填；默认 Mate60 竖屏 vp，同 CallScreen.cj 惯例）──
    @State var screenW: Float64 = 360.0
    @State var screenH: Float64 = 780.0

    // diag-suite_settings_root-TC-0507.md F-1.5：码卡内矩阵 Canvas 相对屏幕的全局像素原点
    // （由包裹它的 Stack 的 onAreaChange 回填），用于把卡内的压暗壁纸内容与屏上同一位置的
    // 真实壁纸对齐取样。首帧回调尚未到达时取 0.0（渐变引擎对该坐标不敏感到会露馅的程度）。
    // D-197 返修更正：此前注释称"onAreaChange 到达后经去重键触发一次重绘即收敛"——不成立。
    // QrMaskedMatrixCanvas.repaintIfChanged() 的去重比较跑在子组件内部、比较的是子组件自己
    // 的（已冻结）字段，永远看不到父组件这里新写的值，除非父组件先把已挂载的子实例整体
    // 销毁重建。真正的收敛通道是 buildQrCardArea() 内 onAreaChange 回调里对
    // wallpaperMountToggle 的翻转（见该回调）。
    @State var qrMaskOriginX: Float64 = 0.0
    @State var qrMaskOriginY: Float64 = 0.0

    // ── 外观（夜间切换 + 主题条选中态）──
    @State var isDarkAppearance: Bool = false
    @State var themeItems: Array<ThemeItem> = Array<ThemeItem>()
    @State var selectedThemeIndex: Int32 = 0

    // D-156 返修（diag round-1 required_fixes）：WallpaperBackgroundComponent 的
    // gradientColors/patternColor/isDarkMode/dimmingIntensity 均为裸 public var（不在本
    // feature allowlist、不可编辑，components/WallpaperBackgroundComponent.cj:44-60），无响应式
    // 装饰器，父组件重新 build() 不会回灌新值到已挂载子组件实例。selectThemeCell()/
    // toggleNightMode() 每次翻转本字段，配合 build() 内的 if/else 挂载守卫（两分支内容相同，
    // 但按 if.cj 框架源 branchId 语义在源码位置上是两个不同分支）强制该组件销毁重建，
    // 使其在每次主题选中/夜间切换后都用最新实参重新构造。TC-0507 round5 F-C3 起，
    // qrDefaultPatternFile 异步刷新时也复用这同一把开关（见 refreshDerivedState()）。
    @State var wallpaperMountToggle: Bool = false

    // TC-0507 round5 F-C3：壁纸图案层输入口，取值链逐字照抄
    // pages/AppearanceSettingsPage.cj:579+:1070 先例（getCurrentWallpaper().patternFile 镜像）。
    @State var qrDefaultPatternFile: String = ""

    // TC-0507 round5 F-C1/F-C2 的离屏合成（qrMaskedContent/qrTextMaskedContent 两个 PixelMap +
    // paintQrSquareMask()/paintQrTextMask()）已按 diag-suite_settings_root-TC-0507.md F-1 移除：
    // 两个 ctx 从未挂载到任何 Canvas() 节点，getPixelMap() 静默取回空内容（RC-1，本轮 4 条 FAIL
    // 枚举的唯一根因）。改为 QrMaskedMatrixCanvas / QrMaskedCaptionCanvas 两个独立 @Component
    // （文件尾），各自的 ctx 与其 build() 内唯一的 Canvas() 节点同一次构造产出（D-190），去重状态
    // 也随之下沉到各自组件内部，见 buildQrCardArea()。

    // TC-0507 round4 F-B3/B4a：夜间切换图标改字形为 Lottie（anim_sun.json / anim_sun_reverse.json），
    // 形状照抄 services/ProfileMuteAnimationService.cj（该文件不在本 feature allowlist，故等价逻辑
    // 就地实现于本页）。两条动画各自的已解码帧数组、当前应展示的帧序号（随夜间切换播放到末帧后
    // 停住，对位源侧 AnimationNode 播放一次到位）。
    @State var nightIconReady: Bool = false
    @State var nightIconFrameIndex: Int64 = 0
    @State var nightIconActiveReverse: Bool = false
    private var nightIconLoadStarted: Bool = false
    private var nightIconFramesSun: ArrayList<PixelMap> = ArrayList<PixelMap>()
    private var nightIconFramesSunReverse: ArrayList<PixelMap> = ArrayList<PixelMap>()
    private var nightIconDurationMs: Int32 = 17
    private var nightIconTimer: Option<Timer> = None<Timer>
    private let NIGHT_ICON_TINT_COLOR: UInt32 = 0x000000
    private let NIGHT_ICON_SIZE: Int32 = 20

    // TC-0507 round4 F-B3/A5：QR 中心 logo（PlaneLogoPlain.tgs）——rawfile → 沙箱 → 解码播放，
    // 形状照抄 pages/ArchiveInfoPage.cj:100-135 的 Got-it 动画（同一套已在编 rlottie 流式播放桥，
    // 播一次停末帧，同 components/ProfileMuteIcon.cj:50-69 startPlayback() 语义）。round5 F-C2
    // 起，圆底改为在遮罩合成阶段随码点/文案同源着色（见 paintQrSquareMask()），本 Lottie 播放的
    // 白色纸飞机图形本身叠在圆底之上、在遮罩之外（不参与合成），维持不变。
    @State var qrLogoReady: Bool = false
    @State var qrLogoFrameIndex: Int64 = 0
    private var qrLogoStream: Option<StreamingLottiePlayer> = None<StreamingLottiePlayer>
    private var qrLogoTimer: Option<Timer> = None<Timer>
    private var qrLogoLocalPath: String = ""
    private var qrLogoExtractStarted: Bool = false
    private let QR_CENTER_LOGO_SIZE: Int32 = 48

    // ══════════════════════════ 生命周期 ══════════════════════════

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadUserInfo()
        this.loadChatThemes()
        this.ensureNightIconLoaded()
        this.ensureQrLogoLoaded()
    }

    private func cleanup(): Unit {
        // UserPhotoService 无 removePhotoReadyCallback（见 UserPhotoService.cj），本页
        // 未订阅其头像就绪回调，避免每次 routerPush 进出累积无法释放的监听（见类注释
        // 已知偏差之外的实现取舍）；因此这里没有需要释放的资源。
        this.stopNightIconPlayback()
        this.stopQrLogoPlayback()
    }

    private func loadUserInfo(): Unit {
        // D-197 返修（diag-suite_settings_root-TC-0507.md 本轮 required_fix，D-197 ERROR）：
        // QrMaskedMatrixCanvas/QrMaskedCaptionCanvas 的 `link` 是裸 var 入参，本函数经
        // .onAppear -> ensureLoaded() 调用，严格晚于第一次 build() 已用 codeLink()（此时通常
        // 为空串）构造这两个组件——已挂载实例的裸 var 字段不会被本函数下面的赋值回灌
        // （同 D-156/D-197 机制）。先记下变化前的 link，赋值后若变了才翻转
        // wallpaperMountToggle，让 buildQrCardArea() 的双分支挂载守卫强制重建，拿到新
        // link。去重写法同本文件 refreshDerivedState() F-C3 与
        // pages/SettingsPage.cj:159-165 refreshNotificationsWarning()。
        let previousLink = this.codeLink()
        match (getRealAuthService().getCurrentUser()) {
            case Some(user) =>
                this.userId = user.id
                this.userUsername = user.username
                this.userPhone = user.phone
                this.userDisplayName = qrPageDisplayName(user.firstName, user.lastName)
                this.avatarText = qrPageAvatarText(user.firstName, user.lastName)
                let photoService = getUserPhotoService()
                match (photoService.getCachedUser(user.id)) {
                    case Some(cachedUser) =>
                        if (!cachedUser.hasPhoto) {
                            photoService.cacheUser(user)
                        }
                    case None => photoService.cacheUser(user)
                }
                photoService.requestFullPhotoDownload(user.id)
            case None =>
                Hilog.info(0, "CjTelegram", "[ChatQrCodeSharePage] loadUserInfo: no current user")
        }
        if (this.codeLink() != previousLink) {
            this.wallpaperMountToggle = !this.wallpaperMountToggle
        }
    }

    private func loadChatThemes(): Unit {
        spawn {
            let result = getThemesEngineService().getChatThemes(0)
            let items = result.themes.toArray()
            launch {
                this.themeItems = items
            }
        }
    }

    // ══════════════════════════ 链接/文案（对位 C5，三分支照搬，无门控）══════════════════════════

    private func codeLink(): String {
        if (this.userUsername.size > 0) {
            return "https://t.me/" + this.userUsername
        }
        if (this.userPhone.size > 0) {
            return "https://t.me/+" + this.userPhone
        }
        return ""
    }

    private func codeText(): String {
        if (this.userUsername.size > 0) {
            return ("@" + this.userUsername).toAsciiUpper()
        }
        return this.userDisplayName.toAsciiUpper()
    }

    private func codeTextFontSize(): Int64 {
        let len = this.codeText().toRuneArray().size
        if (len > 18) { return 16 }
        if (len > 12) { return 22 }
        return 24
    }

    // ══════════════════════════ 卡片几何（对位 C4 :2028-2099）══════════════════════════

    private func cardWidthF(): Float64 {
        let raw = this.screenW - 90.0
        if (raw < 300.0) { return raw }
        return 300.0
    }

    private func cardHeightF(): Float64 {
        return floor(this.cardWidthF() * 1.1)
    }

    private func qrTopMarginF(): Float64 {
        return floor((this.cardWidthF() - 220.0) / 2.0)
    }

    // ══════════════════════════ 主题条数据（对位 C6；TC-0507 round5 F-C4/F-C5 重建）══════════════════════════

    // 对位源 ChatQrCodeScreen.swift:1006-1008 `guard let emoticon = theme.emoticon else { continue }`：
    // 只有携带 emoticon 的云主题才进入构格——round5 之前 ThemeItem 无此字段，全体被迫用 title
    // 首字符近似；core_presentation_data F-B1/F-B2 已把 emoticon 直通上来，这里改为真实过滤。
    // 边界（写进交付报告）：这一改动之后格数可能不再恒为 9，是源侧忠实行为，不是回归。
    private func filteredThemeItems(): Array<ThemeItem> {
        let list = ArrayList<ThemeItem>()
        for (item in this.themeItems) {
            if (item.emoticon.size > 0) { list.add(item) }
        }
        return list.toArray()
    }

    private func themeCellCount(): Int64 {
        return Int64(this.filteredThemeItems().size) + 1
    }

    // 把 0-4 个真实壁纸色规整成 4 档渐变站点：不足 4 个时按取模重复补齐（不是编造新色，只是
    // 让既有的 2-3 色真实数据填满 4 站位的渐变语法），恰好 4 个直接用，0 个（未解析/无壁纸）
    // 回落 defaultWallpaperColors()。
    private func normalizedGradientColors(raw: Array<UInt32>): Array<UInt32> {
        if (raw.size == 0) { return this.defaultWallpaperColors() }
        if (raw.size >= 4) { return [raw[0], raw[1], raw[2], raw[3]] }
        return Array<UInt32>(4, { i => raw[i % raw.size] })
    }

    // TC-0507 A4b_theme_recolor：ThemeItem 已携带 ThemeSettings 的全部日/夜变体。页面按当前
    // 外观选 classic/day 或 night/tinted，匹配不到时退首项；不再按 wallpaperSlug 二次请求
    // WallPaper 文档（该端点不承载主题定制色板）。
    private func selectedThemeVariantIndex(item: ThemeItem): Int64 {
        if (item.settingsVariants.size == 0) { return -1 }
        var i: Int64 = 0
        while (i < item.settingsVariants.size) {
            let baseTheme = item.settingsVariants[i].baseTheme
            if (this.isDarkAppearance) {
                if (baseTheme == "night" || baseTheme == "tinted") { return i }
            } else {
                if (baseTheme == "classic" || baseTheme == "day") { return i }
            }
            i++
        }
        return 0
    }

    private func themeWallpaperColors(item: ThemeItem): Array<UInt32> {
        let variantIndex = this.selectedThemeVariantIndex(item)
        if (variantIndex >= 0) {
            let variant = item.settingsVariants[variantIndex]
            if (variant.hasWallpaper && variant.wallpaperColors.size > 0) {
                return variant.wallpaperColors
            }
            return Array<UInt32>()
        }
        return item.wallpaperColors
    }

    private func themeWallpaperIntensity(item: ThemeItem): Float64 {
        let variantIndex = this.selectedThemeVariantIndex(item)
        if (variantIndex >= 0) {
            return Float64(item.settingsVariants[variantIndex].wallpaperIntensity) / 100.0
        }
        return Float64(item.wallpaperIntensity) / 100.0
    }

    // 主题格与全屏预览共用上面的单一变体/色板选择路径；有效主题缺壁纸色时回落默认壁纸，
    // 不把空色板扩大成纯黑。
    private func themeCellGradientColors(idx: Int64): Array<UInt32> {
        if (idx == 0) { return this.defaultWallpaperColors() }
        let items = this.filteredThemeItems()
        let arrIdx = idx - 1
        if (arrIdx < 0 || arrIdx >= items.size) { return this.defaultWallpaperColors() }
        let item = items[arrIdx]
        if (!item.hasSettings) { return this.defaultWallpaperColors() }
        return this.normalizedGradientColors(this.themeWallpaperColors(item))
    }

    private func themeCellBackgroundColor(idx: Int64): UInt32 {
        return this.themeCellGradientColors(idx)[0]
    }

    // 对位源 defaultEmoticon = "🏠"（ChatQrCodeScreen.swift:750，内置格恒用该 emoji）；
    // 云主题格改用 core_presentation_data 直通上来的真实 emoticon 字段，不再从 title 抠字符。
    private func themeCellEmoji(idx: Int64): String {
        if (idx == 0) { return "\u{1F3E0}" }
        let items = this.filteredThemeItems()
        let arrIdx = idx - 1
        if (arrIdx < 0 || arrIdx >= items.size) { return "" }
        return items[arrIdx].emoticon
    }

    private func selectThemeCell(idx: Int64): Unit {
        this.selectedThemeIndex = Int32(idx)
        // D-156：翻转挂载守卫，强制 WallpaperBackgroundComponent 重建以拿到新选中态的渐变色。
        this.wallpaperMountToggle = !this.wallpaperMountToggle
    }

    // TC-0507 round-2 返修（diag-suite_settings_root-TC-0507.md RC-2）：默认格（选中态 ==
    // 0）的壁纸色须按 isDarkAppearance 重算为两组真实不同色系，对位源
    // ChatQrCodeScreen.swift:999-1004——夜间态 = dayTheme.chat.defaultWallpaper.withUpdatedSettings(
    // WallpaperSettings(colors:[0x00b3dd,0x3b59f2,0x358be2,0xa434cf], intensity:-55))（该组色本身
    // 已经是"套用 intensity:-55 之后"的最终值，不需要再叠加不透明度）；浅色态 = :1020
    // presentationTheme.chat.defaultWallpaper（dayClassic 默认壁纸）。
    //
    // round-2 二次返修（review required_fixes #2）：浅色态四色数值对位
    // DefaultDayPresentationTheme.swift:1109-1114 defaultBuiltinWallpaperGradientColors。
    private func defaultWallpaperColors(): Array<UInt32> {
        if (this.isDarkAppearance) {
            return [0xFF00B3DD, 0xFF3B59F2, 0xFF358BE2, 0xFFA434CF]
        }
        return [0xFFDBDDBB, 0xFF6BA587, 0xFFD5D88D, 0xFF88B884]
    }

    // TC-0507 A4b_theme_recolor：只有索引无效、主题不存在或无 settings 才保留源侧黑色失败
    // 分支；有效主题的选定档缺 wallpaper/colors 时回落默认壁纸色，禁止空色板静默变纯黑。
    private func gradientColorsForSelection(): Array<UInt32> {
        if (this.selectedThemeIndex == 0) {
            return this.defaultWallpaperColors()
        }
        let blackFallback: Array<UInt32> = [0xFF000000, 0xFF000000, 0xFF000000, 0xFF000000]
        let items = this.filteredThemeItems()
        let arrIdx = Int64(this.selectedThemeIndex) - 1
        if (arrIdx < 0 || arrIdx >= items.size) { return blackFallback }
        let item = items[arrIdx]
        if (!item.hasSettings) { return blackFallback }
        return this.normalizedGradientColors(this.themeWallpaperColors(item))
    }

    private func patternIntensityForSelection(): Float64 {
        if (this.selectedThemeIndex == 0) { return 0.5 }
        let items = this.filteredThemeItems()
        let arrIdx = Int64(this.selectedThemeIndex) - 1
        if (arrIdx < 0 || arrIdx >= items.size) { return 0.5 }
        let item = items[arrIdx]
        if (!item.hasSettings) { return 0.5 }
        return this.themeWallpaperIntensity(item)
    }

    private func patternColorForSelection(): UInt32 {
        let colors = this.gradientColorsForSelection()
        let base = colors[0]
        return 0x80000000 | (base & 0x00FFFFFF)
    }

    // TC-0507 round-2 返修：RC-2 修复后，夜间/浅色两态已经是两组真实不同的壁纸色（见
    // defaultWallpaperColors()），不再需要"同色 + 黑色叠层"这种只压暗不换色的信号
    // （diag §6.2 明确禁止的旧机制）；WallpaperBackgroundService.computeDimmingOpacity 在
    // intensity=0 时任何外观下都返回 0，故此处固定 0.0 即为「不再叠加暗化层」。这与
    // paintQrSquareMask()/paintQrTextMask() 内部的 0.3/0.5 dim alpha 是两件独立的事——
    // 后者只作用于遮罩合成出来的码点/文案/logo 圆底内容，不影响本函数控制的可见背景层。
    private func dimmingIntensityF(): Float64 {
        return 0.0
    }

    private func toggleNightMode(): Unit {
        this.isDarkAppearance = !this.isDarkAppearance
        // D-156：同上，夜间切换同样要强制 WallpaperBackgroundComponent 重建。
        this.wallpaperMountToggle = !this.wallpaperMountToggle
        this.startNightIconPlayback()
    }

    // TC-0507 round4 F-B3/B4a：夜间切换图标改用 Lottie 播放，取代此前的 Unicode 字形
    // （原 `nightToggleGlyph()`，本 suite 对「字形替代图形」已多次判负，已废弃）。形状照抄
    // services/ProfileMuteAnimationService.cj:19-33/36-66（`tintProfileMuteFrame` + 逐帧解码
    // 缓存），该文件不在本 feature allowlist，等价逻辑就地实现于本页。
    //
    // 着色：源侧 `iconColors(theme:)`（ChatQrCodeScreen.swift:722-736）把 11 条命名路径统一
    // 着成 `theme.chat.inputPanel.panelControlColor` 一个色 ⇒ 目标侧整帧统一染色即等价，不需要
    // 按路径名分别着色。取值与本页其余 sheet 图标色一致（黑，对位 `nav_ic_close` fillColor）；
    // 该值不属于 F-B4/F-C6 需要收敛的 sheet 字面量点位清单，故不经 previewSheetColors()。
    //
    // round5 复核（F-C7 附带项）：本函数与下方 startNightIconPlayback() 里
    // `nightIconActiveReverse = isDarkAppearance` 的映射逐字对位本文件既有注释引用的源
    // `AnimationNode(animation: isDarkAppearance ? "anim_sun_reverse" : "anim_sun", ...)`——
    // diag round5 报告 §七 F-C7 提到"当前两态接反"，但未给出与此矛盾的新 file:line；本轮
    // 无设备验证，保留这条已有源码引用的映射不变，把该疑点原样写进交付报告供下一轮设备复核，
    // 不在没有更强证据时翻转一个已核实的映射。
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
                Hilog.info(0, "CjTelegram", "[ChatQrCodeSharePage] nightToggle missing ${resourceName}")
                return frames
            case Some(bytes) =>
                let native = getTelegramLottieNative().renderTgs(
                    bytes, "chatqr_night_${cacheKey}", this.NIGHT_ICON_SIZE, maxFrames: 30
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
                    this.nightIconActiveReverse = this.isDarkAppearance
                    let active = this.activeNightIconFrames()
                    this.nightIconFrameIndex = if (active.size > 0) { Int64(active.size) - 1 } else { 0 }
                    this.nightIconReady = true
                }
            }
        }
    }

    // diag-suite_settings_root-TC-0507.md F-6（RC-5）：nightIconActiveReverse 与两组已解码帧
    // 的对应关系互换——双侧帧证据显示当前映射接反（目标浅色态渲染太阳、源侧浅色态渲染弯月+
    // 星芒）。着色与播放触发逻辑（startNightIconPlayback()/nightIconActiveReverse 赋值处）不动，
    // 只交换这里返回哪组帧。
    private func activeNightIconFrames(): ArrayList<PixelMap> {
        if (this.nightIconActiveReverse) { return this.nightIconFramesSun }
        return this.nightIconFramesSunReverse
    }

    // 对位源 `AnimationNode(animation: isDarkAppearance ? "anim_sun_reverse" : "anim_sun", ...)`：
    // 每次夜间切换后选中的动画由新状态决定，从头播到末帧后停住（同
    // components/ProfileMuteIcon.cj:50-69 startPlayback() 语义）。0.3s 颜色插值
    // （ChatQrCodeScreen.swift:1196-1207）本轮不做，见交付报告已知限制。
    private func startNightIconPlayback(): Unit {
        this.stopNightIconPlayback()
        if (!this.nightIconReady) { return }
        this.nightIconActiveReverse = this.isDarkAppearance
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

    // ══════════════════════════ 遮罩合成（diag-suite_settings_root-TC-0507.md F-1）══════════════════════════
    //
    // 源侧机制（ChatQrCodeScreen.swift:1700-1707/:1783-1790/:1853/:1997-2002）：码点/文案/
    // logo 圆底不是各自取色，而是一份 alpha 遮罩（三者的形状，全部画 .black）盖在一份"压暗后
    // 的当前壁纸内容"之上，UIView.mask 原生做栅格合成。ArkUI 这一层没有等价的"跨组件树运行时
    // 栅格遮罩"能力（D-141 已核验），改用 Canvas 2D 合成——但 round5 落地时把 ctx 声明成两个
    // 从未挂载到任何 Canvas() 节点的裸对象（RC-1：getPixelMap() 静默取回空内容，本轮 4 条 FAIL
    // 枚举的唯一根因）。本轮改为 QrMaskedMatrixCanvas / QrMaskedCaptionCanvas 两个独立
    // @Component（定义于文件尾），各自的 ctx 与其 build() 内唯一的 Canvas() 节点同一次构造产出
    // （D-190 修法②：ctx 下沉为组件自己的实例字段，与 QrThemeCellIcon.holeCtx 同构）。
    //   ① 遮罩层：矩阵+挖空 / logo 圆底 / 文案，全部不透明黑，只取 alpha（画在最前面，因为
    //      drawQrCodeMatrix() 第一句是 clearRect，排在内容之后会把内容整片抹掉）。
    //   ② 内容：用与全屏壁纸同一套 gradientComputePixel 引擎逐像素求出压暗后的壁纸色，按
    //      BGRA 手工构造一张 PixelMap（同 renderNightIconFrames() 先例），再用
    //      globalCompositeOperation="source-in" 单次 drawImage 合成——只保留遮罩形状范围内的
    //      像素（合成模式按单次绘制调用生效，遮罩天然是多次 fill()/fillText() 调用，故只能让
    //      内容以单次 drawImage 落在 source-in 侧）。
    // 卡内透出的壁纸内容与屏上同一位置的真实壁纸对齐取样：tileOriginX/Y 由包裹矩阵 Canvas 的
    // Stack 的 onAreaChange 回填（见 buildQrCardArea()），tileFieldW/H 用整屏尺寸。

    // 挖空区域的像素宽度：对位 components/QrCodeView.cj qrCutoutModuleRange() 的模块占比公式
    // （cutoutSize ≈ size*0.297，size 为版本对应模块数）。该函数是私有实现细节、未导出精确
    // 像素矩形，此处按同一比例在像素空间复算——本页二维码内容是短链接，版本不大，不会触及
    // 该函数 cutoutSize>23 的封顶分支，近似成立。
    private func qrCutoutPixelSize(): Float64 {
        return QR_MASK_SIZE * 0.297
    }

    // 遮罩内容的压暗强度：浅色 0.3 / 夜间 0.5，对位 ChatQrCodeScreen.swift:1997。
    private func qrDimAlphaF(): Float64 {
        if (this.isDarkAppearance) { return 0.5 }
        return 0.3
    }

    // D-125 统一刷新探针：本页"计算值必须镜像进裸 @State 字段才能生效"的场景（子组件裸 var
    // 入参重建）都在这一个函数里刷新，每次 build() 调用一次，避免同一文件挂多个零高度探针
    // （同 pages/AppearanceSettingsPage.cj:546 附近注释的约定）。
    private func refreshDerivedState(): String {
        // F-C3：壁纸图案层输入口镜像，变化时顺带强制 WallpaperBackgroundComponent 重建
        // （它的 patternFile 是裸 var，非挂载时刷新不生效，同 D-156 机制）。
        let wp = getWallpaperBackgroundService().getCurrentWallpaper()
        if (wp.patternFile != this.qrDefaultPatternFile) {
            this.qrDefaultPatternFile = wp.patternFile
            this.wallpaperMountToggle = !this.wallpaperMountToggle
        }
        return ""
    }

    // ══════════════════════════ 动作（对位 C9/C10）══════════════════════════

    private func shareEnabled(): Bool {
        return this.codeLink().size > 0
    }

    // TC-0507 round5 F-C6：启用态底色改从 previewSheetColors() 取值（现为
    // resolvePresentationSnapshot() 驱动的真实主题色，非字面量）；禁用态灰 0xC7C7CC 是交互态
    // 字面量（非主题相关），不属于 F-C6 需收敛的点位清单，不经该函数。
    private func shareButtonBackgroundColor(): UInt32 {
        if (this.shareEnabled()) {
            return this.previewSheetColors(this.selectedThemeIndex, this.isDarkAppearance).primaryButtonBackground
        }
        return 0xC7C7CC
    }

    private func onShareTapped(): Unit {
        let link = this.codeLink()
        if (link.size == 0) { return }
        let _ = getShareControllerService().shareInviteLinkViaSystem(link)
    }

    private func onScanTapped(): Unit {
        routerPush("QrScannerPage", "peer")
    }

    // TC-0507 round-2 返修（diag-suite_settings_root-TC-0507.md RC-6 按钮不内缩）：源
    // ChatQrCodeScreen.swift 两枚动作按钮几何为 (36, y, 330, 52)，两侧各留 36pt 定宽内缩
    // （非按屏宽百分比缩放）；改为显式计算宽度（屏宽 - 72vp，两侧各 36vp，pt→vp 1:1），
    // 不再对同一容器同时使用 width(100%) 与左右 margin。
    private func actionButtonWidthF(): Float64 {
        let inset = 72.0
        if (this.screenW <= inset) { return this.screenW }
        return this.screenW - inset
    }

    // TC-0507 round4 F-B3/A5：QR 中心 logo（PlaneLogoPlain.tgs）——把 rawfile 提取到沙箱、
    // 再交给持久流播放器解码，形状照抄 pages/ArchiveInfoPage.cj:100-135
    // extractGotItAnimation()/loadGotItAnimation()（rawfile → 沙箱 → openAnimatedStickerFileStream，
    // 同一套已在编 rlottie 流式播放桥）。播一次到位停末帧，语义同
    // components/ProfileMuteIcon.cj:50-69 startPlayback()。
    private func extractQrLogoAnimation(): Unit {
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let filesDir = ctx.filesDir
                let animDir = filesDir + "/chat_qr_center_logo_anim"
                try { FileIo.mkdir(animDir) } catch (_e: Exception) {}
                let name = "PlaneLogoPlain.tgs"
                let targetPath = animDir + "/" + name
                match (readRawFileBytes(name)) {
                    case None =>
                        Hilog.info(0, "CjTelegram",
                            "[ChatQrCodeSharePage] extractQrLogoAnimation: readRawFileBytes returned None for ${name}")
                    case Some(data) =>
                        if (data.size > 0) {
                            try {
                                let file = FileIo.open(targetPath, mode: 0o1101)
                                let _ = FileIo.write(file.fd, data)
                                FileIo.close(file)
                                this.qrLogoLocalPath = "file://" + targetPath
                                this.loadQrLogoAnimation()
                            } catch (_e: Exception) {
                                Hilog.info(0, "CjTelegram",
                                    "[ChatQrCodeSharePage] extractQrLogoAnimation: write failed for ${name}")
                            }
                        }
                }
        }
    }

    private func loadQrLogoAnimation(): Unit {
        let path = this.qrLogoLocalPath
        if (path.size == 0) { return }
        let docId = QR_CENTER_LOGO_ANIM_DOC_ID
        spawn {
            match (openAnimatedStickerFileStream(docId, path, rasterSize: this.QR_CENTER_LOGO_SIZE)) {
                case Some(player) =>
                    if (player.getFrameCount() > 1) { let _ = player.prepareNextFrame(1) }
                    launch {
                        this.qrLogoStream = Some(player)
                        this.qrLogoReady = true
                        this.qrLogoFrameIndex = 0
                        this.startQrLogoPlayback()
                    }
                case None => ()
            }
        }
    }

    private func ensureQrLogoLoaded(): Unit {
        if (this.qrLogoExtractStarted) { return }
        this.qrLogoExtractStarted = true
        this.extractQrLogoAnimation()
    }

    private func currentQrLogoFrame(): PixelMap {
        match (this.qrLogoStream) {
            case Some(player) =>
                match (player.getCurrentFrame()) {
                    case Some(frame) => return frame
                    case None => return getEmptyAnimatedEmojiPixelMap()
                }
            case None => return getEmptyAnimatedEmojiPixelMap()
        }
    }

    // 播放语义照抄 pages/ArchiveInfoPage.cj:172-203 startGotItAnimPlayback()：播到末帧即停
    // （不循环），对位源侧贴纸 AnimatedStickerNodeLocalFileSource 首次挂载播一次的语义。
    private func startQrLogoPlayback(): Unit {
        this.stopQrLogoPlayback()
        var frameCount: Int64 = 0
        var frameInterval: Int32 = 0
        match (this.qrLogoStream) {
            case Some(player) =>
                frameCount = player.getFrameCount()
                frameInterval = player.getFrameDurationMs()
            case None => return
        }
        let count = frameCount
        var interval = frameInterval
        if (count <= 1) { return }
        if (interval < 16) { interval = 16 }
        this.qrLogoTimer = Some(Timer.repeat(
            Duration.millisecond * Int64(interval), Duration.millisecond * Int64(interval),
            { =>
                launch {
                    if (this.qrLogoFrameIndex + 1 >= count) {
                        this.qrLogoFrameIndex = count - 1
                        this.stopQrLogoPlayback()
                    } else {
                        this.qrLogoFrameIndex = this.qrLogoFrameIndex + 1
                        match (this.qrLogoStream) {
                            case Some(player) => let _ = player.advanceTo(this.qrLogoFrameIndex)
                            case None => ()
                        }
                    }
                }
            }, style: CatchupStyle.Skip
        ))
    }

    private func stopQrLogoPlayback(): Unit {
        match (this.qrLogoTimer) {
            case Some(timer) =>
                timer.cancel()
                this.qrLogoTimer = None<Timer>
            case None => ()
        }
    }

    // TC-0507 round5 F-C6：sheet/按钮联动配色，改为调用 core_presentation_data 交付的纯函数
    // resolvePresentationSnapshot(theme, isDark)（不读取任何全局状态，给定 (theme,isDark) 恒
    // 返回同一份色表），不再是恒定浅色档字面量——isDarkAppearance 形参现在真正驱动输出。
    // token 对位（诊断报告 §七 F-C6）：
    //  sheetBackground                  → snapshot.cardColor（actionSheet.opaqueItemBackgroundColor 近义档）
    //  primaryButtonBackground          → 见下方 F-4（诊断报告 §六 F-4，跟随选中云主题）
    //  primaryButtonForeground          → 不透明白（.foregroundColor 恒为白，源侧同）
    //  secondaryButtonIcon/Text         → 同 primaryButtonBackground（本页此前已将两枚按钮
    //                                     统一到同一色，保留该既有统一，只是让它变成真实主题色）
    //  secondaryButtonBackground        → 同上，alpha 降到 0.1（:1570）
    //  cellBorderSelected               → 同上（本 app 无纯白主题分支，不触发 0x999999 退化）
    //  cellBorderUnselected             → snapshot.disclosureArrowColor，alpha 覆盖为 40%（:260-266）
    // 码卡底色（cardBackground）已按诊断报告 F-5 改为不透明白常量，见 buildQrCardArea()，
    // 不再是本函数的输出面。
    //
    // diag-suite_settings_root-TC-0507.md F-4（RC-3，强调色不跟随所选主题）：选中云主题格
    // （_selectedThemeIndex > 0）且该主题带 settings 时，accent 改取该主题自己的
    // settingsAccentColor（TL 层已解出、ThemesEngineService.getChatThemes() 已直通，不依赖
    // core_presentation_data 的 F-2）；默认格或该主题无 settings 时保留 snapshot.accentColor
    // 不变（对位 MakePresentationTheme.swift:54 把 settings.accentColor 喂给
    // customizePresentationTheme 派生 sheet 强调色的机制）。
    private func previewSheetColors(_selectedThemeIndex: Int32, isDarkAppearance: Bool): PreviewSheetColors {
        let theme: Int32 = if (isDarkAppearance) { 1 } else { 0 }
        let snapshot = resolvePresentationSnapshot(theme, isDarkAppearance)
        var accent = snapshot.accentColor
        if (_selectedThemeIndex > 0) {
            let items = this.filteredThemeItems()
            let arrIdx = Int64(_selectedThemeIndex) - 1
            if (arrIdx >= 0 && arrIdx < items.size && items[arrIdx].hasSettings) {
                // settingsAccentColor 的 TL 线格式是 int（有符号），下游语义是 RGB 位模式
                // （D-191 同型问题）：按位模式转回 UInt32，不能直接 UInt32(负值) 强转。
                let raw = items[arrIdx].settingsAccentColor
                let rawU64: Int64 = if (raw < 0) { Int64(raw) + 0x100000000 } else { Int64(raw) }
                accent = 0xFF000000 | (UInt32(rawU64) & 0x00FFFFFF)
            }
        }
        let secondaryBg = (accent & 0x00FFFFFF) | 0x1A000000
        let borderUnselected = (snapshot.disclosureArrowColor & 0x00FFFFFF) | 0x66000000
        return PreviewSheetColors(
            sheetBackground: snapshot.cardColor,
            primaryButtonBackground: accent,
            primaryButtonForeground: 0xFFFFFFFF,
            secondaryButtonIcon: accent,
            secondaryButtonText: accent,
            secondaryButtonBackground: secondaryBg,
            cellBorderSelected: accent,
            cellBorderUnselected: borderUnselected
        )
    }

    // ══════════════════════════ UI ══════════════════════════

    @Builder
    func buildAvatarCircle() {
        if (this.userId > 0 && getUserPhotoService().getUserPhotoPath(this.userId).size > 0 && !this.avatarImageFailed) {
            Image(getUserPhotoService().getUserPhotoPath(this.userId))
                .width(100)
                .height(100)
                .borderRadius(50)
                .objectFit(ImageFit.Cover)
                .onError({ _ => this.avatarImageFailed = true })
        } else {
            Text(this.avatarText)
                .fontSize(36)
                .fontColor(0xFFFFFF)
                .width(100)
                .height(100)
                .borderRadius(50)
                .backgroundColor(0xFA790F)
                .textAlign(TextAlign.Center)
        }
    }

    // TC-0507 round4 F-B3/A5：QR 中心 logo（PlaneLogoPlain.tgs 播放帧），叠在遮罩合成结果之上
    // 居中——round5 起圆底本身已随码点同源着色（见 paintQrSquareMask()），本 Builder 只负责
    // 纸飞机图形本体（在遮罩之外，源侧 codeAnimatedIconNode 不在 codeMaskNode 里）。加载未就绪
    // 时不渲染任何占位。
    @Builder
    func buildQrCenterLogo() {
        if (this.qrLogoReady) {
            Image(this.currentQrLogoFrame())
                .width(Float64(this.QR_CENTER_LOGO_SIZE))
                .height(Float64(this.QR_CENTER_LOGO_SIZE))
        }
    }

    @Builder
    func buildQrCardArea() {
        Stack(alignContent: Alignment.Top) {
            this.buildAvatarCircle()
            Column {
                // diag-suite_settings_root-TC-0507.md F-1.7：两个遮罩画布无条件挂载（不再用
                // `if (codeLink().size>0)` 包一层）——ctx 是各自组件的实例字段，与其 Canvas
                // 节点原生配对；link 为空时组件内部 paint() 在 clearRect 之后直接 return，
                // 画布透明，视觉与此前的空分支一致。
                Stack(alignContent: Alignment.Center) {
                    QrMaskedMatrixCanvas(
                        link: this.codeLink(),
                        gradientColors: this.gradientColorsForSelection(),
                        dimAlpha: this.qrDimAlphaF(),
                        cutoutPx: this.qrCutoutPixelSize(),
                        tileOriginX: this.qrMaskOriginX,
                        tileOriginY: this.qrMaskOriginY,
                        tileFieldW: this.screenW,
                        tileFieldH: this.screenH
                    )
                    this.buildQrCenterLogo()
                }
                .width(QR_MASK_SIZE)
                .height(QR_MASK_SIZE)
                .margin(top: this.qrTopMarginF())
                // F-1.5：矩阵 Canvas 相对屏幕的全局像素原点——文案 Canvas 复用同一个 X，
                // Y 加 220+4（对位下面 Column 的 margin(top: 4)），使两张画布取样同一条
                // 纵向壁纸切片，与屏上真实壁纸位置对齐。
                // D-197 返修：tileOriginX/Y 是 QrMaskedMatrixCanvas/QrMaskedCaptionCanvas 的裸
                // var 入参，仅靠这里回填 qrMaskOriginX/Y（父组件 @State）不会送达已挂载子实例
                // ——必须同时翻转 wallpaperMountToggle 触发 buildQrCardArea() 的双分支挂载守卫
                // 强制重建。值真变化才翻，去重写法合并自 pages/SettingsPage.cj:159-165
                // refreshNotificationsWarning()（"值变了才翻 toggle"）与
                // pages/AppearanceSettingsPage.cj:1134-1139（onAreaChange 内先比较新旧值再写
                // state，避免每次量测都无谓触发）。
                .onAreaChange({ _: Area, newArea: Area =>
                    let newX = optLenVp(newArea.globalPosition.x)
                    let newY = optLenVp(newArea.globalPosition.y)
                    if (newX != this.qrMaskOriginX || newY != this.qrMaskOriginY) {
                        this.qrMaskOriginX = newX
                        this.qrMaskOriginY = newY
                        this.wallpaperMountToggle = !this.wallpaperMountToggle
                    }
                })
                // 自定义 @Component 不能被直接链式通用属性（Phase 0 既有约定），外层套 Column
                // 承载 margin，同 QrThemeCellIcon 调用点先例。
                Column {
                    QrMaskedCaptionCanvas(
                        text: this.codeText(),
                        fontSize: this.codeTextFontSize(),
                        gradientColors: this.gradientColorsForSelection(),
                        dimAlpha: this.qrDimAlphaF(),
                        tileOriginX: this.qrMaskOriginX,
                        tileOriginY: this.qrMaskOriginY + QR_MASK_SIZE + 4.0,
                        tileFieldW: this.screenW,
                        tileFieldH: this.screenH
                    )
                }
                .margin(top: 4)
            }
            .width(this.cardWidthF())
            .height(this.cardHeightF())
            // diag-suite_settings_root-TC-0507.md F-5（RC-4）：码卡底色无条件不透明白，对位
            // ChatQrCodeScreen.swift:1692-1693 `codeBackgroundNode.backgroundColor = .white`
            // （无外观/主题分支，不再跟随 previewSheetColors() 的 sheet 联动配色）。
            .backgroundColor(0xFFFFFF)
            .borderRadius(42)
            .alignItems(HorizontalAlign.Center)
            // TC-0507 round4 F-B1（新发现②，头像不压边）：对位源 :2099
            // `codeBackgroundFrame.minY - floor(avatarSize.height * 0.7)`，头像固定 100vp
            // （buildAvatarCircle() 两分支同尺寸）⇒ Stack 顶对齐下卡顶应落在 0.7*100=70，
            // 头像下 30vp 压在卡上。
            .margin(top: 70)
        }
        .width(this.cardWidthF())
    }

    @Builder
    func buildThemeStrip() {
        Scroll() {
            Row {
                ForEach(Array<Int64>(this.themeCellCount(), { i: Int64 => i }), itemGenerator: { idx: Int64, _gi: Int64 =>
                    // TC-0507 round5 F-C4：三层结构（渐变缩略图/QR挖空标记/emoji贴纸）从"仅默认格"
                    // 推广到所有格，拆成独立 @Component（QrThemeCellIcon，见文件尾）——每格需要
                    // 自己独立的 Canvas 上下文做挖空绘制，本工程约定"自定义 @Component 不能被直接
                    // 链式通用属性"（Phase 0），故外层套 Column 承载 width/border/onClick 等。
                    Column {
                        QrThemeCellIcon(
                            gradientColors: this.themeCellGradientColors(idx),
                            emoji: this.themeCellEmoji(idx)
                        )
                    }
                    .width(64)
                    .height(88)
                    .clip(true)
                    .backgroundColor(this.themeCellBackgroundColor(idx))
                    .border(
                        width: if (this.selectedThemeIndex == Int32(idx)) { 3 } else { 1 },
                        color: if (this.selectedThemeIndex == Int32(idx)) {
                            this.previewSheetColors(this.selectedThemeIndex, this.isDarkAppearance).cellBorderSelected
                        } else {
                            this.previewSheetColors(this.selectedThemeIndex, this.isDarkAppearance).cellBorderUnselected
                        }
                    )
                    // TC-0507 round4 F-B2（新发现④，格与描边直角）：.borderRadius() 必须写在
                    // .border() 之后——wrapper common_component.cj:1080-1088 borderInner 会用缺省
                    // radius=0 覆盖先写的圆角。半径 16 对位源 ChatQrCodeScreen.swift:491
                    // ImageCorners(radius: 16.0)。
                    .borderRadius(16)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .margin(right: 8)
                    .onClick({ _ => this.selectThemeCell(idx) })
                }, keyGeneratorFunc: { idx: Int64, _gi: Int64 =>
                    // D-127/D-197 round4：idx 是稳定身份；选中态与明暗外观是当前两项真实内容维度。
                    // 外观段变化会让每格 key 变化，强制重建 QrThemeCellIcon，使它的裸 var
                    // gradientColors 在明暗切换后重新取得 themeCellGradientColors(idx) 的当前色板。
                    // 已删除的 slug 异步预取不再拥有就绪状态，因此 key 不再保留失效的 ready 段。
                    idx.toString() + "_" + (if (this.selectedThemeIndex == Int32(idx)) { "1" } else { "0" }) +
                        "_" + (if (this.isDarkAppearance) { "dark" } else { "light" })
                })
            }
            .padding(left: 12, right: 12)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width(100.percent)
        .height(120)
    }

    @Builder
    func buildBottomSheet() {
        Column {
            Row {
                Column {
                    Image(@r(app.media.nav_ic_close))
                        .width(20)
                        .height(20)
                        .fillColor(0x000000)
                }
                .width(44)
                .height(44)
                .borderRadius(22)
                .backgroundColor(0xFFF2F2F7)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .onClick({ _ => routerPop() })

                Blank()

                Text(trSource("QR Code"))
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x000000)

                Blank()

                Column {
                    // TC-0507 round4 F-B3/B4a：Lottie 播放取代 Unicode 字形，见
                    // ensureNightIconLoaded()/startNightIconPlayback() 就近注释。加载未就绪时
                    // 不渲染任何占位（既不留 Unicode 字形兜底分支，也不画自造图形）。
                    if (this.nightIconReady) {
                        Image(this.currentNightIconFrame())
                            .width(Float64(this.NIGHT_ICON_SIZE))
                            .height(Float64(this.NIGHT_ICON_SIZE))
                    }
                }
                .width(44)
                .height(44)
                .borderRadius(22)
                .backgroundColor(0xFFF2F2F7)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .onClick({ _ => this.toggleNightMode() })
            }
            .width(100.percent)
            .height(54)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)

            this.buildThemeStrip()

            Column {
                Text(trSource("Share QR Code"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.previewSheetColors(this.selectedThemeIndex, this.isDarkAppearance).primaryButtonForeground)
            }
            .width(this.actionButtonWidthF())
            .height(52)
            .borderRadius(26)
            .backgroundColor(this.shareButtonBackgroundColor())
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(top: 4)
            .onClick({ _ => this.onShareTapped() })

            Column {
                Row {
                    Image(@r(app.media.settings_ic_qr))
                        .width(18)
                        .height(18)
                        .fillColor(this.previewSheetColors(this.selectedThemeIndex, this.isDarkAppearance).secondaryButtonIcon)
                        .margin(right: 6)
                    Text(trSource("Scan QR Code"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.previewSheetColors(this.selectedThemeIndex, this.isDarkAppearance).secondaryButtonText)
                }
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
            }
            .width(this.actionButtonWidthF())
            .height(52)
            .borderRadius(26)
            .backgroundColor(this.previewSheetColors(this.selectedThemeIndex, this.isDarkAppearance).secondaryButtonBackground)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(top: 8, bottom: 20)
            .onClick({ _ => this.onScanTapped() })
        }
        .width(100.percent)
        .backgroundColor(this.previewSheetColors(this.selectedThemeIndex, this.isDarkAppearance).sheetBackground)
        .borderRadius(38)
    }

    // D-156 返修：把 WallpaperBackgroundComponent 的实例化抽到独立 @Builder，供 build() 内
    // 两个挂载守卫分支各调用一次——两分支内容相同，但按 if.cj 框架源的 branchId 语义（按
    // if/else 源码位置递增分配，非按内容判定）在同一相对位置切换分支会强制销毁旧子树、按当次
    // 构造参数重建新子树，从而让子组件的裸 var 字段拿到最新值。
    @Builder
    func buildWallpaperInstance() {
        WallpaperBackgroundComponent(
            wallpaperType: WallpaperType.PatternWallpaper,
            solidColor: 0xFFE8E6DF,
            gradientColorStart: 0xFFFCF6E9,
            gradientColorEnd: 0xFFE8DBC8,
            gradientAngle: 180.0,
            imageUri: "",
            fallbackColor: 0xFFE8E6DF,
            gradientColors: this.gradientColorsForSelection(),
            phase: 0,
            patternColor: this.patternColorForSelection(),
            patternIntensity: this.patternIntensityForSelection(),
            // TC-0507 round5 F-C3：壁纸图案层输入口，见 refreshDerivedState() 的镜像刷新。
            patternFile: this.qrDefaultPatternFile,
            isDarkMode: this.isDarkAppearance,
            dimmingIntensity: this.dimmingIntensityF()
        )
    }

    func build() {
        Stack {
            // D-125 统一探针：刷新壁纸图案镜像 + 遮罩合成，见 refreshDerivedState() 注释。
            Text(this.refreshDerivedState()).height(0).fontSize(0)
            Stack {
                if (this.wallpaperMountToggle) {
                    this.buildWallpaperInstance()
                } else {
                    this.buildWallpaperInstance()
                }
            }
            .width(100.percent)
            .height(100.percent)

            Column {
                Column {
                    // diag-suite_settings_root-TC-0507.md F-1.6：与 buildWallpaperInstance()
                    // 用同一把 wallpaperMountToggle 双分支挂载守卫——buildQrCardArea() 内新增
                    // 的两个遮罩画布组件（QrMaskedMatrixCanvas/QrMaskedCaptionCanvas）的 8 个
                    // 入参全是裸 var，非挂载时刷新不生效（D-156/D-197）。round3 D-197 返修补全
                    // 全部 4 类驱动源的翻转配套：gradientColors/dimAlpha 随主题选中
                    // （selectThemeCell()）/夜间切换（toggleNightMode()）/patternFile 就绪
                    // （refreshDerivedState() F-C3）；link 随 loadUserInfo() 里 userUsername/
                    // userPhone 变化；tileOriginX/Y 随本 Builder 内层 Stack 的 onAreaChange；
                    // tileFieldW/H 随 build() 根 Stack 的 onAreaChange——四类均已在各自赋值点
                    // 翻转本字段。
                    if (this.wallpaperMountToggle) {
                        this.buildQrCardArea()
                    } else {
                        this.buildQrCardArea()
                    }
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)

                this.buildBottomSheet()
            }
            .width(100.percent)
            .height(100.percent)
        }
        .width(100.percent)
        .height(100.percent)
        // D-197 返修：tileFieldW/H 是 QrMaskedMatrixCanvas/QrMaskedCaptionCanvas 的裸 var
        // 入参，同上一处 onAreaChange 的机制——回填 screenW/H 这一父 @State 不会送达已挂载
        // 子实例，值真变化时必须同时翻转 wallpaperMountToggle 才能触发重建。
        .onAreaChange({ _: Area, newArea: Area =>
            let newW = newArea.width.value
            let newH = newArea.height.value
            if (newW != this.screenW || newH != this.screenH) {
                this.screenW = newW
                this.screenH = newH
                this.wallpaperMountToggle = !this.wallpaperMountToggle
            }
        })
        .onAppear({ => this.ensureLoaded() })
        .onDisAppear({ => this.cleanup() })
    }
}

// TC-0507 round4 F-B4，结构收敛：sheet 层预览配色，见 previewSheetColors()（round5 F-C6 起
// 由 resolvePresentationSnapshot() 驱动）。
private struct PreviewSheetColors {
    public let sheetBackground: UInt32
    public let primaryButtonBackground: UInt32
    public let primaryButtonForeground: UInt32
    public let secondaryButtonIcon: UInt32
    public let secondaryButtonText: UInt32
    public let secondaryButtonBackground: UInt32
    public let cellBorderSelected: UInt32
    public let cellBorderUnselected: UInt32

    public init(
        sheetBackground!: UInt32,
        primaryButtonBackground!: UInt32, primaryButtonForeground!: UInt32,
        secondaryButtonIcon!: UInt32, secondaryButtonText!: UInt32, secondaryButtonBackground!: UInt32,
        cellBorderSelected!: UInt32, cellBorderUnselected!: UInt32
    ) {
        this.sheetBackground = sheetBackground
        this.primaryButtonBackground = primaryButtonBackground
        this.primaryButtonForeground = primaryButtonForeground
        this.secondaryButtonIcon = secondaryButtonIcon
        this.secondaryButtonText = secondaryButtonText
        this.secondaryButtonBackground = secondaryButtonBackground
        this.cellBorderSelected = cellBorderSelected
        this.cellBorderUnselected = cellBorderUnselected
    }
}

/**
 * QrThemeCellIcon — 主题条单格三层图标（TC-0507 round5 F-C4）
 *
 * 对位 ThemeSettingsThemeItemIconNode.asyncLayout（ChatQrCodeScreen.swift 约 :410-536）：
 * 渐变缩略图 + 36×36 白色圆角 QR 挖空标记（本工程按格子比例缩放为 28×28/半径7）+ 34×34
 * emoji 贴纸，自底向上合成于同一 Stack。round5 之前只有默认格（idx==0）落地这三层，
 * 其余格只有单色块+首字母 Text；本轮推广到所有格，拆成独立 @Component 是因为每格需要
 * 自己独立的 Canvas 上下文做挖空绘制（ForEach 生成的多个格子不能共享同一个
 * CanvasRenderingContext2D 实例）——同型先例：
 * pages/WallpaperPickerPage.cj:1840-1865 PlayTriangleIcon（"页面级单例 ctx 反复重新绑定到冷
 * 挂载的新 Canvas 节点，onReady 不总触发"的同一类缺陷，那里的修法就是拆成独立组件，让 ctx
 * 变成组件自己的实例字段）。
 */
@Component
class QrThemeCellIcon {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    var gradientColors: Array<UInt32> = [0xFFDBDDBB, 0xFF6BA587, 0xFFD5D88D, 0xFF88B884]
    var emoji: String = ""

    private let holeCtx: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    // round-2 二次返修（D-141）沿用的真实透明挖空绘制：白底 fill → 用图标自身 alpha 做
    // clip mask（globalCompositeOperation="destination-out"）→ 留下图标形状的透明孔。
    // API 核验记录见原 pages/ChatQrCodeSharePage.cj:519-548（round-2 二次返修就近注释，
    // 逻辑原样迁移到本组件，未改变绘制方式）。
    private func drawHole(): Unit {
        this.holeCtx.fillStyle = Int64(0xFFFFFF)
        this.holeCtx.beginPath()
        this.holeCtx.moveTo(7.0, 0.0)
        this.holeCtx.arcTo(28.0, 0.0, 28.0, 28.0, 7.0)
        this.holeCtx.arcTo(28.0, 28.0, 0.0, 28.0, 7.0)
        this.holeCtx.arcTo(0.0, 28.0, 0.0, 0.0, 7.0)
        this.holeCtx.arcTo(0.0, 0.0, 28.0, 0.0, 7.0)
        this.holeCtx.closePath()
        this.holeCtx.fill()
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                let _ = spawn {
                    try {
                        let bytes = ctx.resourceManager.getMediaByName("settings_ic_qr")
                        let src = createImageSource(bytes)
                        let pm = src.createPixelMap()
                        launch {
                            this.holeCtx.globalCompositeOperation = "destination-out"
                            this.holeCtx.drawImage(pm, 6.0, 6.0, 16.0, 16.0)
                            this.holeCtx.globalCompositeOperation = "source-over"
                        }
                    } catch (_: Exception) {
                        Hilog.warn(0, "CjTelegram", "[QrThemeCellIcon] qr hole icon decode failed, keeping solid white square")
                    }
                }
            case None =>
                Hilog.warn(0, "CjTelegram", "[QrThemeCellIcon] no ability context for qr hole icon")
        }
    }

    func build() {
        Stack(alignContent: Alignment.Center) {
            // ① 缩略图层：铺满格子的多色渐变，取该格自己的壁纸色（见调用方 themeCellGradientColors()）。
            Column {}
                .width(64)
                .height(88)
                .linearGradient(
                    angle: 180.0,
                    colors: [
                        (Color(this.gradientColors[0]), 0.0),
                        (Color(this.gradientColors[1]), 0.33),
                        (Color(this.gradientColors[2]), 0.66),
                        (Color(this.gradientColors[3]), 1.0)
                    ]
                )
            // ② QR 挖空标记层：真实透明挖空（非近似）。
            Canvas(this.holeCtx)
                .width(28)
                .height(28)
                .onReady({ => this.drawHole() })
            // ③ emoji 贴纸层：复用已完工的通用组件。menuEnabled: false——本格已有 onClick
            // 承接主题选中，嵌套原生菜单会与外层点选竞争。
            Column {
                AnimatedEmojiComponent(emoji: this.emoji, displaySize: 22.0, menuEnabled: false)
            }
            .margin(top: 54)
        }
        .width(64)
        .height(88)
    }
}

// Position.x/.y 是 ?Length（同 ohos.arkui.component.common.cj.d:132/143），读法逐字照抄
// components/EmojiPicker.cj:75/1922-1923 optLenVp() 的 unwrap 形状——该函数在 components 包
// 内非 public，跨包不可见，本文件按 D-195 同型情形就地建私有镜像（纯计算、无业务状态、无副作用）。
private func optLenVp(v: ?Length): Float64 {
    match (v) {
        case Some(l) => l.value
        case None => 0.0
    }
}

/**
 * QrMaskedMatrixCanvas / QrMaskedCaptionCanvas —— 码卡遮罩合成的两张画布
 * （diag-suite_settings_root-TC-0507.md F-1，RC-1 修复）
 *
 * round5 的 paintQrSquareMask()/paintQrTextMask() 把 ctx 声明成裸对象、从未挂载到任何
 * Canvas() 节点——SDK 声明 ohos.arkui.component.canvas.cj.d:212 明写 CanvasRenderingContext2D
 * 的 width/height 只读且绑定所属 Canvas（默认 0），未挂载的 ctx 上所有绘制调用因此无处落
 * 栅格，getPixelMap() 静默取回空内容。本轮拆成两个独立 @Component：ctx 声明为组件自己的
 * 实例字段，与 build() 内唯一的 Canvas() 节点由同一次构造产出（D-190 修法②，同型先例
 * QrThemeCellIcon.holeCtx / components/QrCodeView.cj:841 qrCtx）。
 *
 * 去重/重绘范式逐字对照 components/QrCodeView.cj:854-892
 * paintQr()/repaintIfChanged()/onReady 三件套：零高度探针排在 Canvas 之前（同一 build() 内
 * 按出现顺序求值，使"值变了就重画"与 onReady 成为两条互不依赖的通道）。
 *
 * 合成次序（硬约束，理由随附，不得重排）：
 *  1. clearRect
 *  2. 遮罩层：矩阵挖空 + logo 圆底（或文案），全部不透明黑，globalCompositeOperation 保持
 *     默认 "source-over"——drawQrCodeMatrix() 的第一句是 clearRect
 *     （components/QrCodeView.cj:782 qrRenderToCanvas()），排在内容之后会把内容整片抹掉，
 *     所以遮罩必须先画。
 *  3. globalCompositeOperation = "source-in"
 *  4. drawImage(<压暗壁纸内容 PixelMap>, ...)——必须且只能是这一次绘制调用：合成模式按
 *     单次绘制调用生效，遮罩天然是 drawQrCodeMatrix() 内部的多次 fill() 调用，因此不能让
 *     遮罩作为合成的那一侧，只能让内容以单次 drawImage 落在 source-in 侧。
 *  5. globalCompositeOperation = "source-over"（恢复默认，避免影响下一帧其它绘制假设）。
 *
 * 内容 PixelMap 按 BGRA 手工构造，逐字同构 pages/ChatQrCodeSharePage.cj:485-508
 * renderNightIconFrames()（InitializationOptions(..., srcPixelFormat: Bgra8888,
 * pixelFormat: Bgra8888, alphaType: Premul)）与 components/CustomEmojiImage.cj:200-216
 * （手工按 index=B/index+1=G/index+2=R/index+3=A 顺序写 Array<UInt8> 再 createPixelMap()）。
 * 逐像素颜色用与全屏壁纸同一套引擎 gradientComputePixel()（services/WallpaperBackgroundService.cj），
 * 取样坐标用屏幕全局像素原点（tileOriginX/Y，由调用方 buildQrCardArea() 的 onAreaChange 回填）
 * 而不是卡片自身盒子内归一化——这样卡内透出的内容与屏上同一位置的真实壁纸逐像素对齐（对位
 * ChatQrCodeScreen.swift:1999-2003 makeDimmedNode() 的 frame 取全屏尺寸并偏移
 * -codeForegroundNode.frame.minX/minY 的语义）。
 */
@Component
class QrMaskedMatrixCanvas {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    var link: String = ""
    var gradientColors: Array<UInt32> = [0xFFDBDDBB, 0xFF6BA587, 0xFFD5D88D, 0xFF88B884]
    var dimAlpha: Float64 = 0.3
    var cutoutPx: Float64 = 0.0
    var tileOriginX: Float64 = 0.0
    var tileOriginY: Float64 = 0.0
    var tileFieldW: Float64 = 360.0
    var tileFieldH: Float64 = 780.0

    // D-190：ctx 必须与它的 Canvas 节点同生命周期，声明在这里与下面 build() 里的 Canvas
    // 节点由同一次构造产出（同 QrThemeCellIcon.holeCtx / components/QrCodeView.cj qrCtx 先例）。
    private let ctx: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    private var paintedLink: String = ""
    private var paintedGradientColors: Array<UInt32> = Array<UInt32>(0, repeat: 0)
    private var paintedDimAlpha: Float64 = -1.0
    private var paintedCutoutPx: Float64 = -1.0
    private var paintedTileOriginX: Float64 = -1.0
    private var paintedTileOriginY: Float64 = -1.0
    private var paintedTileFieldW: Float64 = -1.0
    private var paintedTileFieldH: Float64 = -1.0

    // 逐像素求压暗壁纸内容，按 BGRA 手工构造 PixelMap（见类头引用的两个先例）。
    private func buildDimmedWallpaperTile(w: Int64, h: Int64): PixelMap {
        let colors = this.gradientColors
        let positions = gradientPositionsForPhase(getSharedGradientPhase())
        let bytes = Array<UInt8>(w * h * 4, repeat: 0)
        var py: Int64 = 0
        while (py < h) {
            var px: Int64 = 0
            while (px < w) {
                let wx = (this.tileOriginX + Float64(px)) / this.tileFieldW
                let wy = (this.tileOriginY + Float64(py)) / this.tileFieldH
                let argb = gradientComputePixel(wx, wy, colors, positions)
                let r = UInt32(min(255.0, Float64((argb >> 16) & 0xFF) * (1.0 - this.dimAlpha)))
                let g = UInt32(min(255.0, Float64((argb >> 8) & 0xFF) * (1.0 - this.dimAlpha)))
                let b = UInt32(min(255.0, Float64(argb & 0xFF) * (1.0 - this.dimAlpha)))
                let idx = (py * w + px) * 4
                bytes[idx] = UInt8(b)
                bytes[idx + 1] = UInt8(g)
                bytes[idx + 2] = UInt8(r)
                bytes[idx + 3] = 255
                px++
            }
            py++
        }
        let options = InitializationOptions(
            IKSize(Int32(w), Int32(h)),
            srcPixelFormat: PixelMapFormat.Bgra8888,
            pixelFormat: PixelMapFormat.Bgra8888,
            alphaType: AlphaType.Premul
        )
        return createPixelMap(bytes, options)
    }

    private func paint(): Unit {
        this.paintedLink = this.link
        this.paintedGradientColors = this.gradientColors
        this.paintedDimAlpha = this.dimAlpha
        this.paintedCutoutPx = this.cutoutPx
        this.paintedTileOriginX = this.tileOriginX
        this.paintedTileOriginY = this.tileOriginY
        this.paintedTileFieldW = this.tileFieldW
        this.paintedTileFieldH = this.tileFieldH
        try {
            this.ctx.clearRect(0.0, 0.0, QR_MASK_SIZE, QR_MASK_SIZE)
            // F-1.7：link 为空时清空后直接返回，画布透明（组件本身无条件挂载，这里内部兜底
            // "还没有内容可画"这一态，而不是靠外层条件挂载延迟构造）。
            if (this.link.size == 0) { return }
            let _ = drawQrCodeMatrix(this.ctx, this.link, QR_MASK_SIZE, 0xFF000000, None, "Q", true, 1.0)
            let cx = QR_MASK_SIZE / 2.0
            let cy = QR_MASK_SIZE / 2.0
            this.ctx.fillStyle = Int64(0xFF000000)
            this.ctx.beginPath()
            this.ctx.arc(cx, cy, (this.cutoutPx - 8.0) / 2.0, 0.0, 6.283185307179586, counterclockwise: false)
            this.ctx.fill()
            let content = this.buildDimmedWallpaperTile(Int64(QR_MASK_SIZE), Int64(QR_MASK_SIZE))
            this.ctx.globalCompositeOperation = "source-in"
            this.ctx.drawImage(content, 0.0, 0.0, QR_MASK_SIZE, QR_MASK_SIZE)
            this.ctx.globalCompositeOperation = "source-over"
        } catch (e: Exception) {
            Hilog.warn(0, "CjTelegram", "[QrMaskedMatrixCanvas] paint failed: ${e}")
        }
    }

    private func repaintIfChanged(): String {
        var colorsChanged = this.gradientColors.size != this.paintedGradientColors.size
        if (!colorsChanged) {
            var i = 0
            while (i < this.gradientColors.size) {
                if (this.gradientColors[i] != this.paintedGradientColors[i]) {
                    colorsChanged = true
                    break
                }
                i++
            }
        }
        if (this.link != this.paintedLink || colorsChanged || this.dimAlpha != this.paintedDimAlpha ||
            this.cutoutPx != this.paintedCutoutPx || this.tileOriginX != this.paintedTileOriginX ||
            this.tileOriginY != this.paintedTileOriginY || this.tileFieldW != this.paintedTileFieldW ||
            this.tileFieldH != this.paintedTileFieldH) {
            this.paint()
        }
        return ""
    }

    func build() {
        Stack(alignContent: Alignment.Center) {
            Text(this.repaintIfChanged()).height(0).fontSize(0)
            Canvas(this.ctx)
                .width(QR_MASK_SIZE)
                .height(QR_MASK_SIZE)
                .onReady({ => this.paint() })
        }
        .width(QR_MASK_SIZE)
        .height(QR_MASK_SIZE)
    }
}

@Component
class QrMaskedCaptionCanvas {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    var text: String = ""
    var fontSize: Int64 = 24
    var gradientColors: Array<UInt32> = [0xFFDBDDBB, 0xFF6BA587, 0xFFD5D88D, 0xFF88B884]
    var dimAlpha: Float64 = 0.3
    var tileOriginX: Float64 = 0.0
    var tileOriginY: Float64 = 0.0
    var tileFieldW: Float64 = 360.0
    var tileFieldH: Float64 = 780.0

    private let ctx: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    private var paintedText: String = ""
    private var paintedFontSize: Int64 = -1
    private var paintedGradientColors: Array<UInt32> = Array<UInt32>(0, repeat: 0)
    private var paintedDimAlpha: Float64 = -1.0
    private var paintedTileOriginX: Float64 = -1.0
    private var paintedTileOriginY: Float64 = -1.0
    private var paintedTileFieldW: Float64 = -1.0
    private var paintedTileFieldH: Float64 = -1.0

    // 与 QrMaskedMatrixCanvas 逐字同构，见其类头引用的两个先例；此处画布尺寸换成
    // 220×42（QR_MASK_SIZE × QR_TEXT_MASK_HEIGHT）。
    private func buildDimmedWallpaperTile(w: Int64, h: Int64): PixelMap {
        let colors = this.gradientColors
        let positions = gradientPositionsForPhase(getSharedGradientPhase())
        let bytes = Array<UInt8>(w * h * 4, repeat: 0)
        var py: Int64 = 0
        while (py < h) {
            var px: Int64 = 0
            while (px < w) {
                let wx = (this.tileOriginX + Float64(px)) / this.tileFieldW
                let wy = (this.tileOriginY + Float64(py)) / this.tileFieldH
                let argb = gradientComputePixel(wx, wy, colors, positions)
                let r = UInt32(min(255.0, Float64((argb >> 16) & 0xFF) * (1.0 - this.dimAlpha)))
                let g = UInt32(min(255.0, Float64((argb >> 8) & 0xFF) * (1.0 - this.dimAlpha)))
                let b = UInt32(min(255.0, Float64(argb & 0xFF) * (1.0 - this.dimAlpha)))
                let idx = (py * w + px) * 4
                bytes[idx] = UInt8(b)
                bytes[idx + 1] = UInt8(g)
                bytes[idx + 2] = UInt8(r)
                bytes[idx + 3] = 255
                px++
            }
            py++
        }
        let options = InitializationOptions(
            IKSize(Int32(w), Int32(h)),
            srcPixelFormat: PixelMapFormat.Bgra8888,
            pixelFormat: PixelMapFormat.Bgra8888,
            alphaType: AlphaType.Premul
        )
        return createPixelMap(bytes, options)
    }

    private func paint(): Unit {
        this.paintedText = this.text
        this.paintedFontSize = this.fontSize
        this.paintedGradientColors = this.gradientColors
        this.paintedDimAlpha = this.dimAlpha
        this.paintedTileOriginX = this.tileOriginX
        this.paintedTileOriginY = this.tileOriginY
        this.paintedTileFieldW = this.tileFieldW
        this.paintedTileFieldH = this.tileFieldH
        try {
            this.ctx.clearRect(0.0, 0.0, QR_MASK_SIZE, QR_TEXT_MASK_HEIGHT)
            if (this.text.size > 0) {
                this.ctx.font = "bold ${this.fontSize}px sans-serif"
                this.ctx.fillStyle = Int64(0xFF000000)
                this.ctx.textAlign = "center"
                this.ctx.textBaseline = "middle"
                this.ctx.fillText(this.text, QR_MASK_SIZE / 2.0, QR_TEXT_MASK_HEIGHT / 2.0)
            }
            let content = this.buildDimmedWallpaperTile(Int64(QR_MASK_SIZE), Int64(QR_TEXT_MASK_HEIGHT))
            this.ctx.globalCompositeOperation = "source-in"
            this.ctx.drawImage(content, 0.0, 0.0, QR_MASK_SIZE, QR_TEXT_MASK_HEIGHT)
            this.ctx.globalCompositeOperation = "source-over"
        } catch (e: Exception) {
            Hilog.warn(0, "CjTelegram", "[QrMaskedCaptionCanvas] paint failed: ${e}")
        }
    }

    private func repaintIfChanged(): String {
        var colorsChanged = this.gradientColors.size != this.paintedGradientColors.size
        if (!colorsChanged) {
            var i = 0
            while (i < this.gradientColors.size) {
                if (this.gradientColors[i] != this.paintedGradientColors[i]) {
                    colorsChanged = true
                    break
                }
                i++
            }
        }
        if (this.text != this.paintedText || this.fontSize != this.paintedFontSize || colorsChanged ||
            this.dimAlpha != this.paintedDimAlpha || this.tileOriginX != this.paintedTileOriginX ||
            this.tileOriginY != this.paintedTileOriginY || this.tileFieldW != this.paintedTileFieldW ||
            this.tileFieldH != this.paintedTileFieldH) {
            this.paint()
        }
        return ""
    }

    func build() {
        Stack(alignContent: Alignment.Center) {
            Text(this.repaintIfChanged()).height(0).fontSize(0)
            Canvas(this.ctx)
                .width(QR_MASK_SIZE)
                .height(QR_TEXT_MASK_HEIGHT)
                .onReady({ => this.paint() })
        }
        .width(QR_MASK_SIZE)
        .height(QR_TEXT_MASK_HEIGHT)
    }
}

// ── 文件私有 helper（非 @Component 成员，纯计算，与 SettingsPage.buildDisplayName 同逻辑）──

private func qrPageDisplayName(firstName: String, lastName: String): String {
    if (lastName.size > 0) {
        return "${firstName} ${lastName}"
    }
    return firstName
}

private func qrPageAvatarText(firstName: String, lastName: String): String {
    if (firstName.size > 0) {
        let firstRunes = firstName.toRuneArray()
        if (lastName.size > 0) {
            let lastRunes = lastName.toRuneArray()
            return "${firstRunes[0].toString()}${lastRunes[0].toString()}"
        }
        return firstRunes[0].toString()
    }
    return "U"
}
