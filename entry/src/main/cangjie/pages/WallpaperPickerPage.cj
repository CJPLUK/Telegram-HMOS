package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashMap}
import std.sync.Monitor
import std.time.DateTime
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import ohos_app_cangjie_entry.services.{
    getWallpaperBackgroundService,
    getTelegramCoreSettingsService,
    getSaveToCameraRollService,
    WallpaperType,
    WallpaperInfo,
    WallpaperItem,
    WallpaperListResult,
    WallpaperImageDisplayMode,
    wallpaperDisplayModeFromOrdinal,
    WallpaperCustomImageSettings,
    saveWallpaperCustomImageSettings,
    advanceSharedGradientPhase,
    saveSelectedWallpaper,
    clearSelectedWallpaper,
    clearAllSelectedWallpapers,
    consumePendingWallpaperPeer
}
import ohos_app_cangjie_entry.components.{WallpaperBackgroundComponent, PhotoPicker, SelectedPhoto}
import ohos_app_cangjie_entry.core.storage.{
    getChatBgCustomPath,
    getAppThemeTextColor,
    getAppThemeAccentColor,
    getAppThemeNavBarColor,
    getAppThemeBackground,
    getAppThemeCardColor,
    getAppThemeSecondaryTextColor,
    getAppThemeDividerColor,
    PresentationSnapshot,
    currentPresentation
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.interop.*
import std.math.*

/**
 * WallpaperPickerPage — 「Chat Background」壁纸库网格屏
 *
 * diag-suite_settings_appearance-TC-0408/TC-0409/TC-0410.md 返修：整页按源侧
 * `ThemeGridController` + `ThemeGridControllerNode` + `WallpaperGalleryController` 重构：
 *  - TC-0408：导航栏（Back / "Chat Background" / Edit）、顶部动作卡（Set a Color / Choose from
 *    Gallery + 说明）、三列纵向网格（真实云端壁纸缩略图，来自此前零消费方的
 *    WallpaperBackgroundService.loadWallpapersFromCloud/downloadCloudWallpaper 桥接层）、底部
 *    Reset Chat Backgrounds 卡；移除此前多出的 PREVIEW / IMAGE DISPLAY MODE / CUSTOM IMAGE
 *    SETTINGS 三段（源侧本屏不存在）。
 *  - TC-0409：宿主编辑态状态机（`editing` / `selectedIds`），Edit 按钮切换，编辑态下点击格子改为
 *    多选而非直接提交，底部选择工具条（删除/分享，无选中时置灰）。
 *  - TC-0410：非编辑态点击格子改为进入全屏预览覆盖层（不再直接提交），预览层含关闭钮 + 底部
 *    Apply For All Chats 提交钮。
 *
 * rework_round=1（review required_fixes ①⑤）：round-0 只把「点击即提交」的预览/确认闸门接到了
 * 云端照片网格一条入口，`applyColorPreset()`（Set a Color）与 `applyCustomPhoto()`（Choose from
 * Gallery）仍是点击/选中即落盘，原样保留了 TC-0410 要修的缺陷。本轮把三条入口统一改经
 * `openPreview()` / `openPresetPreview()` / `openCustomPhotoPreview()` 汇入同一个 `previewVisible`
 * 覆盖层，落盘只发生在 `applyPreviewedWallpaper()`（Apply For All Chats 的唯一调用点）：
 *  - 选项按钮按 `previewKind`（=`WallpaperType`）分叉：`CustomImage`（云端照片 / 相册自定义图）→
 *    Blur + Motion（Motion 无传感器桥接，诚实置灰不可点）；`SolidColor`/`MultiColorGradient`/
 *    `PatternWallpaper`（Set a Color 内置预设）→ Pattern（预览态叠加/收起点阵，不改动实际要提交
 *    的预设数据）+ Colors（展开/收起当前配色 swatch）+ 仅当颜色数 ≥2 且非纯色时的中央圆形钮（推进
 *    共享渐变 phase 并强制预览重挂载，源侧「play/rotate」二态里 colors≥2 恒为 play 变体，本工程
 *    预设色数恒为 4，rotate 分支不可达，不实现）。
 *  - 预览态 Blur/Motion/Pattern 开关只影响未提交预览渲染，退出预览即失效；落盘只读
 *    `previewKind`/`previewPresetIndex`/`previewUri`，不读这些开关。
 *
 * 混合工程迁移壳（hybrid-migration Phase 4，先于本轮返修落地，本轮未改）：
 *  - @Component → @HybridComponentEntry；build() 根不再包 NavDestination；
 *    routerPop() 经 interop 驱动 ArkTS 持有的 NavPathStack。
 *
 * diag-suite_settings_appearance-TC-0410.md（前一轮返修已落地 preview-then-confirm 后，同 case
 * 经替代入口复测发现的两条独立缺陷，均归本 feature，均与 `wallpaperresources` 空网格无关）：
 *  - Finding 1（中央播放钮图标间歇性不渲染）：round1 归因「onReady 触发时读回宽高竞态」、改字面量
 *    常量，round2 复测仍复现（3 次首开成功，同色卡连续 2 次重开完全空白）。round2 重新定位机制为
 *    页面级单例 `playIconCtx` 被反复重新绑定到每次预览打开都冷挂载的新 Canvas 节点，`onReady`
 *    对这种「陈旧 context + 新节点」组合不可靠触发；修法迁出为独立 `PlayTriangleIcon` @Component
 *    （文件底部），context 随组件实例一起构造/销毁，对齐同覆盖层内 `WallpaperBackgroundComponent`
 *    已验证正确的模式（见该组件头注释）。**待设备验证**：本轮无设备，静态改完无法自证；需反复
 *    进出预览页若干次观察是否仍复现空白。
 *  - Finding 2（预览层缺源侧 `messagesContainerNode` 聊天气泡模拟层）：round1 已落地并经 round2
 *    复测确认稳定复现两条气泡、无缺失，本轮不改动。
 *
 * diag-suite_settings_appearance-TC-0408/TC-0409-round3.md 返修（RC-A + RC-B，同轮落地）：
 *  - RC-A：`setWallpaperUri()`/`toggleSelection()`/`deleteSelected()` 三处把 `@State` 集合
 *    （HashMap/ArrayList，引用类型）取出、就地改、再把同一引用赋回，不构成变化、不触发通知，
 *    `build()` 永不重跑。改为构造新集合、拷贝旧内容、写入新值、整体赋新对象。
 *  - RC-B：网格格子此前把壁纸文档原件（`mime_type application/x-tgwallpattern`）直接喂给
 *    `Image()`，ArkUI 无该格式解码器，恒为空。改按源侧 `SettingsThemeWallpaperNode.swift:151-213`
 *    的「底色/渐变 + 图案缩略图叠加」两层结构合成：底层用 `WallpaperItem.settings.colorsArray()`
 *    （`wallpaperresources` 本轮同批供出）分三态（`>=3` 多点渐变 / `==2` 双色渐变 / `==1` 纯色，
 *    复用已验证稳定的 `WallpaperBackgroundComponent`），上层叠 `downloadWallpaperThumb()` 取的
 *    `sizeSpec:"m"` 缩略图（不是文档原件）。无 ArkUI `compositingFilter` 对位物，不模拟
 *    softLight 混合（按 D4.4 不得按表现拼近似），只影响图案与底色的融合观感。
 *  - **待设备验证**：本轮无设备，静态改完无法自证网格格子实际是否显示内容。
 *
 * diag-suite_settings_appearance-TC-0408-round7-g3.md 返修（G3 FAIL）：网格格子长宽比此前是
 * 五个互不相关的散点常量（`.height(148)` / `columnsGap(8)` / `rowsGap(8)` / `padding(8)` +
 * `gridHeight()` 里的 `148.0+8.0`）的副产物，源侧任何屏宽下都不存在这一组合。改为新增
 * `wallpaperGridGeometry()` 单一真值源，逐行对位源侧 `ThemeGridControllerNode.swift:753-785`
 * （390 断点 / reference size / sideInset / imageCount）+ `UIKitUtils.swift:512-515
 * aspectFilled`（等比缩放，格子长宽比恒等于 reference 比）+ `:60-62 floorToScreenPixels` +
 * `GridNode.swift:490-500 .fixed` 分支（itemsInRow/itemSpacing），全部量从
 * `getDefaultDisplaySync().width/height` 导出，六个消费点（`GridItem` 的 width/height、`Grid`
 * 的 columnsTemplate/columnsGap/rowsGap/padding、`gridHeight()`、`gridRowCount()`、外层
 * `Column` 的 padding）全部改为消费该函数，不再含设备相关字面常量。
 *
 * 已知限制（详见 <feature_id>.md「已知限制」节）：
 *  - 图案缩略图与底色层无 softLight 混合模拟（见上）。
 *  - 编辑态「删除」目前只影响本页会话内存列表（`hiddenSlugs`），未调用任何服务端 unsave
 *    能力（`WallpaperResourcesService` 现有实现只有 get/download，无 save/unsave），已 emit
 *    `emitted_integration_contracts[ic_wallpaper_unsave_and_settings_shell_settings_wallpaper]`
 *    给 `wallpaperresources`。
 */
@HybridComponentEntry
@Component
public class WallpaperPickerPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // D-180 返修：预览层气泡模拟（Finding 2）取色须走真实 presentation 快照字段
    // （bubbleOutColor/bubbleInColor），不得借用 accentColor 等按数值巧合相近的字段；
    // 写法对齐 pages/AppearanceSettingsPage.cj:47 既有先例。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    // ---- 云端壁纸列表 ----
    @State var wallpapers: ArrayList<WallpaperItem> = ArrayList<WallpaperItem>()
    /** 壁纸文档全量文件 URI（供全屏预览 openPreview()/applyCloudWallpaper() 使用，不用于网格格子渲染） */
    @State var wallpaperUris: HashMap<String, String> = HashMap<String, String>()
    /**
     * TC-0408 round3 RC-B: 壁纸文档缩略图（sizeSpec:"m"）URI——网格格子的图案叠加层用这份，
     * 不是 wallpaperUris 的全量文档（mime_type application/x-tgwallpattern，ArkUI 无解码器）。
     */
    @State var wallpaperThumbUris: HashMap<String, String> = HashMap<String, String>()
    // 下载/缓存回调逐条 spawn(UIThread) 改写上面两张 @State HashMap 时，每一条都触发整个网格
    // 重建、格子重挂载重画；冷启动后几十条回调在同一帧内连发，主线程被连续重建阻塞 >6s
    // （THREAD_BLOCK_6S，hilog 实锤）。改为回调线程只把 (slug, uri) 堆进待刷新表，并保证同一
    // 时刻至多一个 UIThread 刷新任务在排队；刷新任务一次性合并全部待刷新项、每张表只赋值一次。
    // 普通 var（非 @State）：只在 Monitor 内读写，不参与渲染表达式。
    private let uriBatchMonitor: Monitor = Monitor()
    private var pendingWallpaperUris: HashMap<String, String> = HashMap<String, String>()
    private var pendingThumbUris: HashMap<String, String> = HashMap<String, String>()
    private var uriFlushScheduled: Bool = false
    @State var hiddenSlugs: ArrayList<String> = ArrayList<String>()
    @State var wallpapersRequested: Bool = false

    // ---- 宿主编辑态（TC-0409）----
    @State var editing: Bool = false
    @State var selectedIds: HashMap<String, Bool> = HashMap<String, Bool>()

    // ---- 当前生效壁纸（用于网格选中标记）----
    @State var currentAppliedUri: String = ""
    // diag-suite_settings_appearance-TC-0408-round8.md F-1.2：当前生效预设的变更令牌。
    // getWallpaperBackgroundService().getCurrentWallpaper() 读的是服务层全局 _currentPresetIndex，
    // 不是 @State，不镜像一份则应用内置预设后网格头格（entry 0）不会触发重绘。
    @State var currentPresetIndex: Int32 = -1

    // ---- 全屏预览覆盖层（TC-0410，rework_round=1: 三条入口共用同一覆盖层） ----
    @State var previewVisible: Bool = false
    @State var previewSlug: String = ""
    @State var previewUri: String = ""
    @State var previewBlurEnabled: Bool = false
    // 回合前恢复 main 能力：main 的壁纸页有三个我方重建时去掉的控件——图片显示模式四选一、
    // Blur 强度、Dimming 强度（origin/main:WallpaperPickerPage.cj:48/54/55，落盘见 :90/93/94）。
    // 我方此前把它们写死为 Cover / 50 / 0.0（本文件 applyCloudWallpaper）。按「合入结果不得让
    // main 失去已有能力」补回为预览态可调 + 落盘。
    @State var previewDisplayMode: Int32 = 2  // 0=AspectFit 1=HalfAspectFill 2=Cover 3=Fill
    @State var previewBlurStrength: Int32 = 50
    @State var previewDimming: Float64 = 0.0
    /** 预览态壁纸类型：CustomImage=云端照片/相册自定义图；SolidColor/MultiColorGradient/PatternWallpaper=Set a Color 内置预设 */
    @State var previewKind: WallpaperType = WallpaperType.CustomImage
    // diag-suite_settings_appearance-TC-0411-round3.md F-2（缩小实现，见 previewDisplayUri()
    // 注释）：previewKind 仍为 CustomImage 时，此字段单独标记这一张是否为云端图案壁纸
    // （item.isPattern，WallpaperResourcesService.cj:119），与 previewPatternOn（Set a Color
    // 内置预设分支自己的图案叠加开关）语义不同、互不影响。
    @State var previewIsCloudPattern: Bool = false
    /** 非 -1 时表示本次预览来自 Set a Color 的第几个内置预设，Apply 时路由到 applyColorPreset(idx) */
    @State var previewPresetIndex: Int32 = -1
    /** 预览态渲染用的镜像信息（solidColor/gradientColors/patternColor/patternIntensity/isDarkMode） */
    @State var previewInfo: WallpaperInfo = WallpaperInfo()
    /** Pattern 按钮：仅影响预览态叠加渲染，不改变实际要提交的预设数据 */
    @State var previewPatternOn: Bool = false
    /** Colors 按钮：展开/收起当前配色 swatch 条 */
    @State var previewColorsVisible: Bool = false
    /** 中央圆形钮推进的共享渐变 phase，只用于预览重绘 */
    @State var previewGradientPhase: Int32 = 0

    // ---- Set a Color 覆盖层 ----
    @State var colorPickerVisible: Bool = false

    // ---- Choose from Gallery 覆盖层 ----
    @State var photoPickerVisible: Bool = false

    @State var loaded: Bool = false

    // ---- S6-05：单会话壁纸模式（资料页 more → Change Wallpaper，对位 iOS ThemeGridController
    // mode: .peer）。peerWallpaperId != 0 时 Apply 只落该会话的 per-chat 槽 + messages.setChatWallPaper，
    // 不碰全局壁纸；按钮文案对位 iOS Wallpaper_ApplyForMe ----
    @State var peerWallpaperId: Int64 = 0
    @State var peerWallpaperName: String = ""
    private var peerWallpaperType: String = "user"
    private var peerWallpaperAccessHash: Int64 = 0

    // 预览态中央圆形钮图标（白色三角 play，Canvas 矢量绘制，零 asset）：round2 返修改为独立
    // `PlayTriangleIcon` @Component（见文件底部），context 不再是本页面级单例字段——见该
    // 组件头注释。

    // ──────────────────────────────────────────────────────────
    // 数据加载
    // ──────────────────────────────────────────────────────────

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // diag-suite_settings_appearance-TC-0413-round3.md 补证节 F-B（与 F-A 同一次改动的另一半，
        // 非可选项）：F-A 落地后 getChatBgCustomPath() 读回的是裸路径，而 currentCloudSlug()（:363-369）
        // /:1074 用来判定网格「当前已应用」勾选态的另一侧 wallpaperUriFor(slug) 恒为带 file:// 的
        // URI——两侧不归一化会让字符串比较永远不相等，冷启动后云端网格的勾选态消失。在此读回后补
        // 前缀，空串保持空串（currentCloudSlug()/:1074 均以 size==0 短路，补成 "file://" 会误命中）。
        let rawChatBgPath = getChatBgCustomPath()
        this.currentAppliedUri = if (rawChatBgPath.size > 0 && !rawChatBgPath.startsWith("file://")) {
            "file://" + rawChatBgPath
        } else {
            rawChatBgPath
        }
        this.currentPresetIndex = getWallpaperBackgroundService().getCurrentPresetIndex()
        // S6-05：资料页 Change Wallpaper 入口写入的目标会话，一次性消费
        let (pendingPeerId, pendingPeerType, pendingPeerHash, pendingPeerName) = consumePendingWallpaperPeer()
        if (pendingPeerId != 0) {
            this.peerWallpaperId = pendingPeerId
            this.peerWallpaperType = pendingPeerType
            this.peerWallpaperAccessHash = pendingPeerHash
            this.peerWallpaperName = pendingPeerName
        }
        this.requestCloudWallpapers()
    }

    private func requestCloudWallpapers(): Unit {
        if (this.wallpapersRequested) { return }
        this.wallpapersRequested = true
        let svc = getWallpaperBackgroundService()
        svc.loadWallpapersFromCloud(0, { result: WallpaperListResult =>
            if (result.success && !result.notModified) {
                let capturedItems = result.items
                spawn(UIThread) {
                    =>
                    this.wallpapers = capturedItems
                }
                for (item in capturedItems) {
                    if (item.hasDocument) {
                        this.requestWallpaperImage(item)
                        this.requestWallpaperThumb(item)
                    }
                }
            }
        })
    }

    private func requestWallpaperImage(item: WallpaperItem): Unit {
        let svc = getWallpaperBackgroundService()
        let cached = svc.getCachedCloudWallpaperUri(item)
        if (cached.size > 0) {
            this.setWallpaperUri(item.slug, cached)
            return
        }
        let capturedSlug = item.slug
        svc.downloadCloudWallpaper(item, { uri: String =>
            if (uri.size > 0) {
                this.setWallpaperUri(capturedSlug, uri)
            }
        })
    }

    /**
     * TC-0408 round3 RC-B: 请求壁纸文档的缩略图变体（图案层），走独立的缩略图缓存/下载桥接，
     * 与 requestWallpaperImage() 的全量文档路径互不干扰（全量路径仍保留给全屏预览/落盘使用）。
     */
    private func requestWallpaperThumb(item: WallpaperItem): Unit {
        let svc = getWallpaperBackgroundService()
        let cached = svc.getCachedCloudWallpaperThumbUri(item)
        if (cached.size > 0) {
            this.setWallpaperThumbUri(item.slug, cached)
            return
        }
        let capturedSlug = item.slug
        svc.downloadCloudWallpaperThumb(item, { uri: String =>
            if (uri.size > 0) {
                this.setWallpaperThumbUri(capturedSlug, uri)
            }
        })
    }

    private func setWallpaperUri(slug: String, uri: String): Unit {
        synchronized(this.uriBatchMonitor) {
            this.pendingWallpaperUris[slug] = uri
        }
        this.scheduleUriFlush()
    }

    /** 若尚无排队中的 UIThread 刷新任务则投递一个；已有则直接返回，由那一个任务合并处理。 */
    private func scheduleUriFlush(): Unit {
        var shouldSpawn = false
        synchronized(this.uriBatchMonitor) {
            if (!this.uriFlushScheduled) {
                this.uriFlushScheduled = true
                shouldSpawn = true
            }
        }
        if (shouldSpawn) {
            spawn(UIThread) {
                =>
                this.flushPendingUris()
            }
        }
    }

    /**
     * UIThread：一次取走全部待刷新项，每张 @State 表至多赋值一次。
     * TC-0408 round3 RC-A: HashMap 是引用类型，就地改后再赋回同一引用不构成 @State 变化，
     * 不会触发通知。仍按原约束构造新 HashMap、拷贝旧内容、合并新值、整体赋新对象。
     */
    private func flushPendingUris(): Unit {
        var uris = HashMap<String, String>()
        var thumbs = HashMap<String, String>()
        synchronized(this.uriBatchMonitor) {
            uris = this.pendingWallpaperUris
            thumbs = this.pendingThumbUris
            this.pendingWallpaperUris = HashMap<String, String>()
            this.pendingThumbUris = HashMap<String, String>()
            this.uriFlushScheduled = false
        }
        let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
        if (uris.size > 0) {
            let next = HashMap<String, String>()
            for ((k, v) in this.wallpaperUris) { next[k] = v }
            for ((k, v) in uris) { next[k] = v }
            this.wallpaperUris = next
        }
        if (thumbs.size > 0) {
            let next = HashMap<String, String>()
            for ((k, v) in this.wallpaperThumbUris) { next[k] = v }
            for ((k, v) in thumbs) { next[k] = v }
            this.wallpaperThumbUris = next
        }
        let t1 = DateTime.now().toUnixTimeStamp().toMilliseconds()
        Hilog.info(0, "CjTelegram", "[WallpaperPicker] uri batch n=${uris.size + thumbs.size} uris=${uris.size} thumbs=${thumbs.size} ms=${t1 - t0}")
    }

    private func wallpaperUriFor(slug: String): String {
        if (this.wallpaperUris.contains(slug)) {
            return this.wallpaperUris[slug]
        }
        return ""
    }

    private func setWallpaperThumbUri(slug: String, uri: String): Unit {
        // 同 setWallpaperUri()：只入待刷新表，由 flushPendingUris() 合并后一次赋回。
        synchronized(this.uriBatchMonitor) {
            this.pendingThumbUris[slug] = uri
        }
        this.scheduleUriFlush()
    }

    private func wallpaperThumbUriFor(slug: String): String {
        if (this.wallpaperThumbUris.contains(slug)) {
            return this.wallpaperThumbUris[slug]
        }
        return ""
    }

    /**
     * TC-0408 round3 RC-B: 网格格子底色层——按 `WallPaperSettings.colorsArray()` 的颜色数分三态，
     * 对位 SettingsThemeWallpaperNode.swift:151-212（`>=3` 多点渐变 / `==2` 双色渐变 / `==1` 纯色）。
     * 颜色数为 0（服务端未给 settings）时调用方退回既有的 0xFFE5E5EA 占位块。
     */
    private func gridBaseColorCount(item: WallpaperItem): Int64 {
        return item.settings.colorsArray().size
    }

    /**
     * TC-0408-round5 F-4（Diff-6）：条目稳定身份，对位源侧
     * ThemeGridControllerNode.swift:66-83 ThemeGridControllerEntry.stableId 的 .file 分支——
     * `(file.id, file.settings.colors, file.settings.intensity ?? 0)` 三元复合。同一壁纸文档
     * 带不同配色在源侧壁纸列表里是常态，塌成单一 slug 键会被 ArkUI ForEach 去重丢弃。
     * 三个输入全部现成（WallpaperResourcesService.cj:103/87/73-74），不新增解析、不改该文件。
     */
    private func wallpaperStableId(item: WallpaperItem): String {
        let colors = item.settings.colorsArray()
        let parts = ArrayList<String>()
        for (c in colors) { parts.add(c.toString()) }
        let intensity = if (item.settings.hasIntensity) { item.settings.intensity } else { Int32(0) }
        var colorsPart = ""
        var first = true
        for (p in parts) {
            if (!first) { colorsPart = colorsPart + "," }
            colorsPart = colorsPart + p
            first = false
        }
        return "${item.id}|${colorsPart}|${intensity}"
    }

    private func gridBaseColorAt(item: WallpaperItem, idx: Int64): UInt32 {
        let colors = item.settings.colorsArray()
        if (idx < colors.size) { return colors[idx] }
        return 0xFFE5E5EA
    }

    /** 图案缩略图叠加层的不透明度，对位 SettingsThemeWallpaperNode.swift:157 的 intensity 语义；缺省按 50 取。 */
    private func gridPatternOpacity(item: WallpaperItem): Float64 {
        if (item.settings.hasIntensity) {
            return Float64(item.settings.intensity) / 100.0
        }
        return 0.5
    }

    private func cloudPatternInfo(item: WallpaperItem): WallpaperInfo {
        let info = WallpaperInfo()
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
        info.patternIntensity = if (item.settings.hasIntensity) {
            Float64(item.settings.intensity) / 100.0
        } else {
            0.5
        }
        info.isDarkMode = info.patternIntensity < 0.0
        info.patternFile = this.wallpaperThumbUriFor(item.slug)
        info.patternOverlayEnabled = info.patternFile.size > 0
        return info
    }

    private func isHidden(slug: String): Bool {
        for (s in this.hiddenSlugs) {
            if (s == slug) { return true }
        }
        return false
    }

    private func visibleWallpapers(): Array<WallpaperItem> {
        let out = ArrayList<WallpaperItem>()
        for (item in this.wallpapers) {
            if (!item.hasDocument) { continue }
            if (this.isHidden(item.slug)) { continue }
            out.add(item)
        }
        return out.toArray()
    }

    private func visibleWallpaperCount(): Int64 {
        return this.visibleWallpapers().size
    }

    /**
     * diag-suite_settings_appearance-TC-0408-round8.md F-1.3：当前落盘的自定义图片路径若落在
     * 云端列表里，返回该条目 slug；否则 ""。路径可当身份用：getCachedCloudWallpaperUri() 由
     * (item.id, item.accessHash) 确定性派生（services/WallpaperBackgroundService.cj:933-938），
     * requestWallpaperImage() 把该值原样写进 wallpaperUris[item.slug]（本文件 :213-222），
     * 故 wallpaperUriFor(slug) == currentAppliedUri 与该 slug 的云端身份一一对应。
     */
    private func currentCloudSlug(): String {
        let effective = getWallpaperBackgroundService().getCurrentWallpaper()
        for (item in this.visibleWallpapers()) {
            if (this.wallpaperUriFor(item.slug) == this.currentAppliedUri) { return item.slug }
            if (item.isPattern && effective.patternFile.size > 0 &&
                effective.patternFile == this.wallpaperThumbUriFor(item.slug)) {
                return item.slug
            }
            if (!item.isPattern && effective.wallpaperType == WallpaperType.CustomImage &&
                effective.imageUri.size > 0 && effective.imageUri == this.wallpaperUriFor(item.slug)) {
                return item.slug
            }
        }
        return ""
    }

    /**
     * diag-suite_settings_appearance-TC-0408-round8.md F-1.3：网格 entry 列表，对位源侧
     * ThemeGridControllerNode.swift:446（当前生效壁纸无条件插为 entry 0，isSelected=true）+
     * :493/:505（与当前壁纸同身份的条目在尾部去重，不重复入列）。选中态从此是 entry 上的字段，
     * 不是渲染时现算的字符串判据；且这一条不变式在自定义图片 / 内置预设 / 主题默认三种档位下
     * 都成立——currentCloudSlug() 为空时头格转入 else 分支，用 getCurrentWallpaper() 统一解析
     * 后两种档位（该函数内部已经把「用户选定预设」与「主题默认渐变」按优先级合并，参见该函数
     * 注释），不需要在本文件里再分叉一次。
     */
    private func gridEntries(): Array<WallpaperGridEntry> {
        let out = ArrayList<WallpaperGridEntry>()
        let curSlug = this.currentCloudSlug()
        let head = WallpaperGridEntry()
        head.isSelected = true // :446 isSelected: true，无条件
        if (curSlug.size > 0) {
            for (item in this.visibleWallpapers()) {
                if (item.slug == curSlug) {
                    head.item = item
                    break
                }
            }
            head.key = "wp_cur_${this.wallpaperStableId(head.item)}_${this.wallpaperThumbUriFor(head.item.slug).size > 0}"
        } else {
            head.isPresetEntry = true
            head.presetInfo = getWallpaperBackgroundService().getCurrentWallpaper()
            // 键必须随生效预设变化，否则 ArkUI 不重挂载、渐变不重绘（本文件 D-127 / round3 F-2.2
            // 已坐实）。wallpaperType 用 .ordinal() 而非直接字符串插值——WallpaperType 未见任何
            // 仓内先例把枚举直接放进 ${}（cangjie-kb 本轮不可达，按协议降级为 grep 仓内先例，
            // zero hits；.ordinal() 是本文件已大量使用的 Int32，语义等价，同样能在类型切换时
            // 让键变化）。
            head.key = "wp_cur_preset_${this.currentPresetIndex}_${head.presetInfo.wallpaperType.ordinal()}" +
                "_${head.presetInfo.solidColor}_${head.presetInfo.imageUri}"
        }
        out.add(head)
        for (item in this.visibleWallpapers()) {
            if (curSlug.size > 0 && item.slug == curSlug) { continue } // :505 !selected 才入列
            let e = WallpaperGridEntry()
            e.item = item
            e.isSelected = false
            e.key = "wp_${this.wallpaperStableId(item)}_${this.wallpaperThumbUriFor(item.slug).size > 0}"
            out.add(e)
        }
        return out.toArray()
    }

    /**
     * TC-0408-round5 F-4（Diff-6）：行数不再由未去重的 visibleWallpaperCount() 导出——那是
     * 第二个真值源，一旦跟 ForEach 实际挂载的（去重后的）条目数不一致，差额就变成卡尾空白。
     * TC-0408-round7-g3（G3 FAIL 返修）：列数不再写死 3，改用 wallpaperGridGeometry() 导出的
     * columns（对位源侧 ThemeGridControllerNode.swift:783 imageCount 的屏宽断点结果），
     * (n + columns - 1) / columns 是 (n+2)/3 在列数变量化后的等价写法。
     * diag-suite_settings_appearance-TC-0408-round8.md F-2.3：行数第二个真值源改为
     * gridEntries().size（去重逻辑已内建在 gridEntries()，与 ForEach 实际挂载的条目数同源），
     * 不再另用 HashSet 对 visibleWallpapers() 去重——避免两处去重实现分叉。
     */
    private func gridRowCount(): Int64 {
        let n = this.gridEntries().size
        if (n == 0) { return 0 }
        let (_iw, _ih, _isp, _ls, columns, _si) = this.wallpaperGridGeometry()
        return (n + columns - 1) / columns
    }

    /**
     * TC-0408-round7-g3（G3 FAIL 返修）：网格总高不再用字面常量 148.0/8.0，改用
     * wallpaperGridGeometry() 导出的 itemHeight/lineSpacing——同一真值源，行高与行距都随
     * 屏宽变化（源侧同屏宽下这就是应得高度，参见诊断报告「无净退化论证」）。
     */
    private func gridHeight(): Float64 {
        let rows = this.gridRowCount()
        if (rows == 0) { return 0.0 }
        let (_iw, itemHeight, _isp, lineSpacing, _cols, _si) = this.wallpaperGridGeometry()
        return Float64(rows) * itemHeight + Float64(rows - 1) * lineSpacing
    }

    /**
     * TC-0408-round7-g3（G3 FAIL 返修，diag-suite_settings_appearance-TC-0408-round7-g3.md）：
     * 网格几何单一真值源，逐行对位源侧
     * `ThemeGridControllerNode.containerLayoutUpdated`（Sources/ThemeGridControllerNode.swift:
     * 753-785，390 断点 / reference size / sideInset / imageCount）+ `CGSize.aspectFilled`
     * （submodules/Display/Source/UIKitUtils.swift:512-515，等比缩放，格子长宽比恒等于
     * reference 长宽比）+ `floorToScreenPixels`（同文件 :60-62）+ `GridNode.generateItemLayout`
     * 的 `.fixed` 分支（Sources/GridNode.swift:490-500，itemsInRow/itemSpacing）。
     *
     * 返回 (itemWidth, itemHeight, itemSpacing, lineSpacing, columns, sideInset)。返修单给的签名
     * 是 5 元组（不含 sideInset）；这里补上 sideInset 作第 6 个分量——它是本函数体内部已经算出的
     * 中间量（对位 :779），外层 Column 的水平留白（原调用点 6「.padding(left:16,right:16)」）
     * 同样必须消费它。若不返回、让调用方另写一份 sideInset 计算，会重新制造第二个真值源，
     * 违背本次返修的核心目的；5→6 元组是收窄改动、不是偏离处方精神。
     * 全部量从屏幕宽高导出；函数体内除源码原文常量
     * （12 / 6 / 390 / 110 / 150 / 90 / 16 / 674 / 3）外不含任何字面数值——换任何屏宽都会重新
     * 导出对应值，不是把某一台设备的比值固化成常量（诊断报告硬约束）。
     * density/vp2px 写法照抄本文件已有 backArrowCommands() 的 match 形状。
     *
     * 边界条件（与源侧行为等价的目标平台守卫，非源侧逻辑）：
     * - columns <= 1 时 lineSpacing 直接取 minSpacing，避免 /(columns-1) 除零
     *   （源侧 imageCount 在任何真实手机宽度下恒 >= 2，这条守卫在真机上不会触发）；
     * - itemsInRow 由源侧 GridNode.swift:495 自带 max(1, ...) 守卫；
     * - density <= 0 时回落 1.0，避免除零污染全部导出量。
     */
    private func wallpaperGridGeometry(): (Float64, Float64, Float64, Float64, Int64, Float64) {
        let rawDensity: Float64 = match (this.getUIContext().vp2px(1.0.vp)) {
            case Some(len) => len.value
            case None => Float64(getDefaultDisplaySync().densityPixels)
        }
        let density: Float64 = if (rawDensity <= 0.0) { 1.0 } else { rawDensity }
        let dispW = Float64(getDefaultDisplaySync().width)
        let dispH = Float64(getDefaultDisplaySync().height)
        // 对位 layout.size.width（vp）：:753
        let layoutWidth = dispW / density
        // 对位 min(layout.size.width, layout.size.height)：:770
        let screenWidth = min(dispW, dispH) / density
        // 对位 floorToScreenPixels(v) = floor(v*scale)/scale，UIKitUtils.swift:60-62
        let fsp = { v: Float64 => floor(v * density) / density }
        let padding = 12.0 // :768
        let minSpacing = 6.0 // :769
        // 390 断点选 reference size：:770-776
        let refW = if (screenWidth >= 390.0) { 110.0 } else { 90.0 }
        let refH = 150.0
        // :779
        let sideInset = max(16.0, floor((layoutWidth - 674.0) / 2.0))
        // :781
        let gridWidth = layoutWidth - sideInset * 2.0
        // :783（Swift Int() 截断取整；正值下与 Int64() 同义）
        let columns = Int64((gridWidth - padding * 2.0) / refW)
        // :784 内层尺寸
        let inner = fsp((gridWidth - padding * 2.0 - Float64(columns - 1) * minSpacing) / Float64(columns))
        // aspectFilled：UIKitUtils.swift:512-515，等比缩放，第二分量 refH/refH == 1.0 照写不省
        let scale = max(inner / refW, 1.0)
        let itemWidth = floor(refW * scale)
        let itemHeight = floor(refH * scale)
        // :785
        var lineSpacing = minSpacing
        if (columns > 1) {
            lineSpacing = fsp((gridWidth - padding * 2.0 - Float64(columns) * itemWidth) / Float64(columns - 1))
        }
        // listInsets.left/right += 3.0：ThemeGridControllerNode.swift:881-882
        let listInset = sideInset + 3.0
        // GridNode.swift:493
        let effective = layoutWidth - listInset * 2.0
        // GridNode.swift:495，源侧自带 max(1, ...) 守卫
        var itemsInRow = Int64(effective / itemWidth)
        if (itemsInRow < 1) { itemsInRow = 1 }
        // GridNode.swift:496-499
        let itemSpacing = fsp(max(0.0, effective - Float64(itemsInRow) * itemWidth) / Float64(itemsInRow + 1))
        return (itemWidth, itemHeight, itemSpacing, lineSpacing, columns, sideInset)
    }

    // S-005：build() 内不允许 let/var，六个调用点改经这些薄 accessor 消费
    // wallpaperGridGeometry() 的对应分量，函数体本身零字面常量。
    private func gridItemWidth(): Float64 {
        let (w, _h, _sp, _ls, _c, _si) = this.wallpaperGridGeometry()
        return w
    }

    private func gridItemHeight(): Float64 {
        let (_w, h, _sp, _ls, _c, _si) = this.wallpaperGridGeometry()
        return h
    }

    private func gridItemSpacing(): Float64 {
        let (_w, _h, sp, _ls, _c, _si) = this.wallpaperGridGeometry()
        return sp
    }

    private func gridLineSpacing(): Float64 {
        let (_w, _h, _sp, ls, _c, _si) = this.wallpaperGridGeometry()
        return ls
    }

    private func gridColumns(): Int64 {
        let (_w, _h, _sp, _ls, c, _si) = this.wallpaperGridGeometry()
        return c
    }

    private func gridSideInset(): Float64 {
        let (_w, _h, _sp, _ls, _c, si) = this.wallpaperGridGeometry()
        return si
    }

    /** 三列时是 "1fr 1fr 1fr"；columns 由 wallpaperGridGeometry() 导出，不写死列数。 */
    private func gridColumnsTemplate(): String {
        let columns = this.gridColumns()
        var out = ""
        var i: Int64 = 0
        while (i < columns) {
            if (i > 0) { out = out + " " }
            out = out + "1fr"
            i = i + 1
        }
        return out
    }

    // ──────────────────────────────────────────────────────────
    // 编辑态 / 选择（TC-0409）
    // ──────────────────────────────────────────────────────────

    private func isItemSelected(slug: String): Bool {
        if (this.selectedIds.contains(slug)) { return this.selectedIds[slug] }
        return false
    }

    private func toggleSelection(slug: String): Unit {
        // TC-0408/TC-0409 round3 RC-A: 同引用赋回不触发通知（同 setWallpaperUri()）。改为拷贝
        // 时决定是否跳过该 key（删除分支），而不是在旧引用上就地 remove 再赋回同一对象。
        let removing = this.selectedIds.contains(slug) && this.selectedIds[slug]
        let next = HashMap<String, Bool>()
        for ((k, v) in this.selectedIds) {
            if (removing && k == slug) { continue }
            next[k] = v
        }
        if (!removing) {
            next[slug] = true
        }
        this.selectedIds = next
    }

    private func selectedCount(): Int64 {
        var c: Int64 = 0
        for ((_k, v) in this.selectedIds) {
            if (v) { c = c + 1 }
        }
        return c
    }

    private func exitEditing(): Unit {
        this.editing = false
        this.selectedIds = HashMap<String, Bool>()
    }

    // TC-0409 round4 F-1：确认层换成 ActionSheet，复数串回到条目 title 槽。原 AlertDialog
    // 把源侧「单条目 destructive ActionSheet」映射成居中弹窗时，title 槽被迫塞进了本该当按钮
    // 文案的复数串、按钮文案退化成硬编码 "Delete"。对位 ThemeGridController.swift:278-330：
    // 第一组一个 destructive 条目（title = 复数串）+ 独立成组的 accent Cancel，无标题无正文。
    // ActionSheetOptions/SheetInfo/ActionSheetButtonOptions 已由 :3 import kit.ArkUI.* 带进
    // 作用域，getUIContext().showActionSheet(value:) 与本文件已在用的 showAlertDialog 同属一个
    // UIContext。调用仍在 onClick 的同步调用栈内直调（dev_pattern.md D-821：弹层类调用脱离用户
    // 手势的同步调用栈会被静默丢弃），不得包进 launch{}/Timer/任何异步回调。
    private func confirmDelete(): Unit {
        let n = this.selectedCount()
        if (n == 0) { return }
        let title = if (n == 1) { "Delete Background" } else { "Delete ${n} Backgrounds" }
        let uiCtx = getUIContext()
        let deleteSheet = SheetInfo(title: title, action: { => this.deleteSelected() })
        let cancelBtn = ActionSheetButtonOptions(value: "Cancel", action: { => () })
        uiCtx.showActionSheet(ActionSheetOptions(
            title: None,
            message: None,
            confirm: cancelBtn,
            sheets: [deleteSheet],
            autoCancel: true
        ))
    }

    private func deleteSelected(): Unit {
        // TC-0408/TC-0409 round3 RC-A: 同引用赋回不触发通知（同 setWallpaperUri()）。改为构造
        // 新 ArrayList、拷贝旧内容、追加选中项，再整体赋新对象。
        let next = ArrayList<String>()
        for (s in this.hiddenSlugs) { next.add(s) }
        for ((slug, v) in this.selectedIds) {
            if (v) { next.add(slug) }
        }
        this.hiddenSlugs = next
        this.exitEditing()
    }

    private func shareSelected(): Unit {
        if (this.selectedCount() == 0) { return }
        var targetSlug = ""
        for ((slug, v) in this.selectedIds) {
            if (v) {
                targetSlug = slug
                break
            }
        }
        if (targetSlug.size == 0) { return }
        let uri = this.wallpaperUriFor(targetSlug)
        if (uri.size == 0) { return }
        let rawPath = if (uri.startsWith("file://")) { uri[7..uri.size] } else { uri }
        let argJson = "{\"filePath\":\"" + jsonEscapeWallpaperPicker(rawPath) + "\",\"title\":\"Wallpaper\",\"isVideo\":false}"
        Hilog.info(0, "CjTelegram", "[WallpaperPicker] Share wallpaper: ${rawPath}")
        callArkAsync(SHARE_LINK, argJson, { res: String =>
            if (res.contains("\"ok\":true")) {
                Hilog.info(0, "CjTelegram", "[WallpaperPicker] systemShare presented ok")
            } else {
                Hilog.info(0, "CjTelegram", "[WallpaperPicker] systemShare unavailable, fallback to clipboard: ${res}")
                let _ = getSaveToCameraRollService().copyMediaFileUri(uri)
            }
        })
    }

    private func sharePreview(): Unit {
        if (this.previewUri.size == 0) { return }
        let rawPath = if (this.previewUri.startsWith("file://")) {
            this.previewUri[7..this.previewUri.size]
        } else {
            this.previewUri
        }
        let argJson = "{\"filePath\":\"" + jsonEscapeWallpaperPicker(rawPath) +
            "\",\"title\":\"Wallpaper\",\"isVideo\":false}"
        callArkAsync(SHARE_LINK, argJson, { _res: String => () })
    }

    // ──────────────────────────────────────────────────────────
    // 点击分发 / 预览（TC-0409 分流 + TC-0410）
    // ──────────────────────────────────────────────────────────

    private func onWallpaperTap(item: WallpaperItem): Unit {
        if (this.editing) {
            this.toggleSelection(item.slug)
            return
        }
        this.openPreview(item)
    }

    private func openPreview(item: WallpaperItem): Unit {
        let uri = this.wallpaperUriFor(item.slug)
        if (uri.size == 0) { return }
        this.previewKind = WallpaperType.CustomImage
        this.previewPresetIndex = -1
        this.previewSlug = item.slug
        this.previewUri = uri
        // diag-suite_settings_appearance-TC-0411-round3.md F-2（缩小实现）：previewUri 对图案
        // 壁纸而言是 mime_type=application/x-tgwallpattern 的全量文档（本文件 :131 附近注释已写明
        // ArkUI 无该格式解码器）；标记这一档，预览层改用真实位图（previewDisplayUri()），不改变
        // previewUri/落盘身份（保持与 wallpaperUriFor(slug) 同形，currentCloudSlug() 的勾选态比较
        // 不受影响，F-B 的归一化前提不变）。
        this.previewIsCloudPattern = item.isPattern
        if (item.isPattern) {
            this.previewInfo = this.cloudPatternInfo(item)
            this.previewPatternOn = true
            this.previewGradientPhase = 0
        }
        this.previewBlurEnabled = false
        if (!item.isPattern) { this.previewPatternOn = false }
        this.previewColorsVisible = false
        this.previewVisible = true
    }

    /** TC-0410 required_fix ①: Choose from Gallery 选中的图片也先进预览，不直接落盘。 */
    private func openCustomPhotoPreview(uri: String): Unit {
        if (uri.size == 0) { return }
        this.previewKind = WallpaperType.CustomImage
        this.previewPresetIndex = -1
        this.previewSlug = ""
        this.previewUri = uri
        this.previewIsCloudPattern = false
        this.previewBlurEnabled = false
        this.previewPatternOn = false
        this.previewColorsVisible = false
        this.photoPickerVisible = false
        this.previewVisible = true
    }

    /** TC-0410 required_fix ①⑤: Set a Color 内置预设也先进预览，按 wallpaperType 分叉选项按钮。 */
    private func openPresetPreview(idx: Int32): Unit {
        this.applyPresetPreviewInfo(this.colorPresetAt(idx), idx)
    }

    /**
     * round9 返修（review.required_fixes N/A，:1213 死点击）：openPresetPreview()/openHeadPresetPreview()
     * 共用的预览状态写入体，从 openPresetPreview() 抽出，行为逐字不变——colorPresetAt(idx) 查表得到的
     * WallpaperInfo 与 gridEntries() 合成头格已经解析好的 entry.presetInfo 走同一份写入逻辑，不重复。
     */
    private func applyPresetPreviewInfo(info: WallpaperInfo, idx: Int32): Unit {
        let mirrored = WallpaperInfo()
        mirrored.wallpaperType = info.wallpaperType
        mirrored.solidColor = info.solidColor
        mirrored.gradientColors = info.gradientColors
        mirrored.patternColor = info.patternColor
        mirrored.patternIntensity = info.patternIntensity
        // round2 required_fix: patternFile 此前漏拷贝，导致 openHeadPresetPreview() 经
        // getCurrentWallpaper() 主题默认档拿到的真实 patternFile（WallpaperBackgroundService.cj:868）
        // 在这里被静默丢弃，:1576 消费点因此恒为 ""。此处补齐，其余消费点（:931/933/1566/1572/
        // 1574/1575/1577）已覆盖的字段不受影响。
        mirrored.patternFile = info.patternFile
        mirrored.patternOverlayEnabled = info.patternOverlayEnabled
        mirrored.isDarkMode = info.isDarkMode
        this.previewInfo = mirrored
        this.previewKind = info.wallpaperType
        this.previewPresetIndex = idx
        this.previewGradientPhase = info.phase
        this.previewPatternOn = info.patternOverlayEnabled || (info.wallpaperType == WallpaperType.PatternWallpaper)
        // F-2：这一路走内置预设/主题默认，不是云端图案文档，防止上一次 openPreview() 留下的标记残留。
        this.previewIsCloudPattern = false
        this.previewColorsVisible = false
        this.previewSlug = ""
        this.previewUri = ""
        this.colorPickerVisible = false
        this.previewVisible = true
    }

    /**
     * round9 返修：合成 entry 0（内置预设 / 主题默认 / 未走云端 slug 的自定义图三档，gridEntries()
     * F-1.3 统一解析进 entry.presetInfo）的非编辑态点击预览。此前 :1213 统一走
     * onWallpaperTap(entry.item)，该 entry 的 item 是默认空 WallpaperItem（slug=""），
     * openPreview("") 在 wallpaperUriFor("") 未命中后静默 no-op（:673-675）——这一档因此点不开预览，
     * 是本轮唯一必修项。
     *
     * 不直接复用 openPresetPreview(idx) 按下标重查表：entry.presetInfo 已经是 gridEntries() 用
     * getCurrentWallpaper() 解析出的、当前真正生效的那份信息——深色主题覆盖内置预设
     * （getCurrentWallpaper() 里 `isDark && !preset.isDarkMode` 落回主题默认分支，见该函数注释）时，
     * this.currentPresetIndex 仍指向用户之前选的预设下标，colorPresetAt(currentPresetIndex) 查到的
     * 会是那个被覆盖掉、当前并未生效的预设，与格子实际渲染内容不一致；直接用 entry.presetInfo 才能
     * 保证「预览显示的就是这一格正在显示的东西」。
     *
     * wallpaperType==CustomImage 单独分流到 openCustomPhotoPreview()：这一档的 presetInfo.imageUri
     * 才是可渲染的真实 uri，applyPresetPreviewInfo() 恒把 previewUri 置空（预设分支从不需要 uri），
     * 若误走预设分支，预览遮罩会显示空白且 Apply 落到 applyCloudWallpaper() 的 `previewUri.size==0`
     * 早退（:731），点了等于没点。
     */
    private func openHeadPresetPreview(entry: WallpaperGridEntry): Unit {
        let info = entry.presetInfo
        if (info.wallpaperType == WallpaperType.CustomImage) {
            this.openCustomPhotoPreview(info.imageUri)
            return
        }
        this.applyPresetPreviewInfo(info, this.currentPresetIndex)
    }

    /**
     * round9 返修：网格格子统一点击入口。非编辑态下把合成头格（entry.isPresetEntry）分流到
     * openHeadPresetPreview()；其余三种组合（编辑态头格 / 编辑态普通格 / 非编辑态普通格）行为
     * 不变，原样交给 onWallpaperTap(entry.item)——编辑态头格 toggleSelection("") 仍是已知、
     * 已披露的空 slug no-op（:1048 编辑态分支本轮未改一行），不受本次分流影响。
     */
    private func onGridEntryTap(entry: WallpaperGridEntry): Unit {
        if (!this.editing && entry.isPresetEntry) {
            this.openHeadPresetPreview(entry)
            return
        }
        this.onWallpaperTap(entry.item)
    }

    /**
     * diag-suite_settings_appearance-TC-0411-round3.md F-2（缩小实现）：previewKind==CustomImage
     * 且 previewIsCloudPattern 时，previewUri 指向的全量 `.tgv` 文档 ArkUI 解不出来（预览覆盖层
     * 会露出自己的 0xFF000000 黑底）。同一个 slug 在网格格子上已经用 wallpaperThumbUriFor(slug)
     * （downloadWallpaperThumb() 的 "m" 栅格）画出真实图案（:1243/:1251 一带同款调用），预览层改
     * 用同一份缩略图。缩略图尚未下载完（size==0）时保持原 previewUri，不新增阻塞、不新增判断
     * 之外的分支。previewUri 本身不变，落盘（applyCloudWallpaper）与勾选态比较
     * （currentCloudSlug()/:1074）继续用 wallpaperUriFor(slug) 同形值，不受此项影响——图案壁纸
     * 应用到聊天页背景（会话页渲染 + 图案叠加层接线）超出本轮简化处方范围，见 featureX.md 已知限制。
     */
    private func previewDisplayUri(): String {
        if (this.previewIsCloudPattern && this.previewSlug.size > 0) {
            let thumb = this.wallpaperThumbUriFor(this.previewSlug)
            if (thumb.size > 0) { return thumb }
        }
        return this.previewUri
    }

    /**
     * diag-suite_settings_appearance-TC-0413-round4.md RC-b（round3 F-2 缩小实现未达成的部分）：
     * previewDisplayUri() 在 previewIsCloudPattern 时已经换成缩略图（"m" 栅格），但缩略图是带
     * alpha 的深色线稿——网格格子（:1198 一带 entry.item.isPattern 分支）能看见同一份缩略图，
     * 是因为格子在它下面垫了一层 `WallpaperItem.settings.colorsArray()` 合成的底色/渐变；
     * 预览覆盖层此前没有这一层，线稿画在覆盖层自己的 0xFF000000 黑底上 = 全黑不可见。
     * 这里为覆盖层补同一份底色查找：previewSlug 在 openPreview() 里已置为该条目的 slug（:693），
     * 从当前已加载的云端列表按 slug 反查同一个 WallpaperItem；取不到时返回默认空 WallpaperItem()
     * （settings.colorsArray() 为空数组，下游 gridBaseColorCount() 走既有的 0 色占位块分支，不会
     * 因查不到条目而崩溃或画出脏数据）。
     */
    private func previewCloudPatternItem(): WallpaperItem {
        for (item in this.wallpapers) {
            if (item.slug == this.previewSlug) { return item }
        }
        return WallpaperItem()
    }

    // 回合前恢复 main 能力：显示模式名（对位 origin/main:WallpaperPickerPage.cj:99 displayModeName）。
    private func previewDisplayModeName(): String {
        if (this.previewDisplayMode == 0) { return "Fit" }
        if (this.previewDisplayMode == 1) { return "Half" }
        if (this.previewDisplayMode == 3) { return "Fill" }
        return "Cover"
    }

    private func applyCloudWallpaper(): Unit {
        if (this.previewUri.size == 0) { return }
        // diag-suite_settings_appearance-TC-0411.md S08：云端图案 Apply 必须按源侧
        // WallpaperBackgroundNode.update :1266–1341 落类型化槽（颜色个数决定底层，图案走
        // patternFile + patternOverlayEnabled 正交叠加）。禁止再把 .tgv 写成 CustomImage。
        if (this.previewIsCloudPattern) {
            getTelegramCoreSettingsService().saveChatBackground("")
            let item = this.previewCloudPatternItem()
            let selInfo = this.cloudPatternInfo(item)
            saveSelectedWallpaper(selInfo)
            this.currentAppliedUri = this.previewUri
            this.previewVisible = false
            Hilog.info(0, "CjTelegram", "[WallpaperPicker] applyCloudWallpaper pattern: ${this.previewSlug}")
            return
        }
        // 云端照片 / 相册自定义图：整段保持 TC-0411 S09 已 PASS 的 CustomImage 落盘，禁止改这条。
        // diag-suite_settings_appearance-TC-0413-round3.md 补证节 F-A：chatBackgroundPath 的
        // 存储契约是裸文件系统路径（core/storage/AppTheme.cj:434 字段注释），而 previewUri 是喂给
        // ArkUI Image() 的 file:// URI（两个生产者：PhotoPicker.cj / WallpaperResourcesService.cj
        // 都产 file:// 形态）。原样落盘会让唯一校验者 getVerifiedChatBackgroundUri() 的
        // FileIo.access() 按裸路径语义收到带 scheme 的字符串，恒失败。落盘前在此归一化为裸路径，
        // 写法逐字同形本文件 shareSelected():648 已有的剥前缀先例。
        var chatBgPath = this.previewUri
        if (chatBgPath.startsWith("file://")) { chatBgPath = chatBgPath[7..] }
        getTelegramCoreSettingsService().saveChatBackground(chatBgPath)
        let cs = WallpaperCustomImageSettings()
        cs.displayMode = wallpaperDisplayModeFromOrdinal(this.previewDisplayMode)
        cs.blurEnabled = this.previewBlurEnabled
        cs.blurStrength = this.previewBlurStrength
        cs.motionEnabled = false
        cs.dimmingIntensity = this.previewDimming
        saveWallpaperCustomImageSettings(cs)
        // F-1a：把"用户选定的壁纸"额外写进带类型的持久槽
        // （services/WallpaperBackgroundService.cj saveSelectedWallpaper()），
        // getCurrentWallpaper() 第一档改读它。previewUri 保留 file:// 形态——该字段直接喂给
        // 组件 Image()，不经任何文件系统调用，与上面落 chatBgPath 裸路径的兼容镜像用途不同。
        let selInfo = WallpaperInfo()
        selInfo.wallpaperType = WallpaperType.CustomImage
        selInfo.imageUri = this.previewUri
        saveSelectedWallpaper(selInfo)
        this.currentAppliedUri = this.previewUri
        this.previewVisible = false
        Hilog.info(0, "CjTelegram", "[WallpaperPicker] applyCloudWallpaper: ${this.previewSlug}")
    }

    /**
     * TC-0410 required_fix ①: Apply For All Chats 是三条入口（云端网格 / Set a Color / Choose from
     * Gallery）落盘的唯一调用点，按 previewKind 分发到既有的落盘函数。
     */
    private func applyPreviewedWallpaper(): Unit {
        if (this.peerWallpaperId != 0) {
            this.applyPreviewedWallpaperForPeer()
            return
        }
        if (this.previewKind == WallpaperType.CustomImage) {
            this.applyCloudWallpaper()
        } else {
            this.applyColorPreset(this.previewPresetIndex)
        }
    }

    /**
     * S6-05：单会话模式的 Apply（iOS WallpaperGalleryToolbarNode .setPeer → Wallpaper_ApplyForMe →
     * messages.setChatWallPaper，forBoth=false）。壁纸信息的合成逻辑与全局路径逐字同形
     * （云端图案 → 底色 + patternFile；云端照片 / 相册图 → CustomImage；Set a Color 预设 → previewInfo），
     * 只是落盘目标换成 per-chat 槽，不动 saveChatBackground / saveSelectedWallpaper / 预设下标等全局状态。
     * 应用后返回上一页（iOS 该流程 Apply 后 dismiss 回会话）。
     */
    private func applyPreviewedWallpaperForPeer(): Unit {
        var info = WallpaperInfo()
        var cloudId: Int64 = 0
        var cloudHash: Int64 = 0
        if (this.previewKind == WallpaperType.CustomImage) {
            if (this.previewUri.size == 0) { return }
            let item = this.previewCloudPatternItem()
            if (item.hasDocument) {
                // 云端条目（图案 / 照片）：与 syncServerChatWallpaper 共用同一份合成规则
                cloudId = item.id
                cloudHash = item.accessHash
                info = getWallpaperBackgroundService().cloudWallpaperInfo(
                    item, this.wallpaperThumbUriFor(this.previewSlug), this.previewUri)
            } else {
                // 相册自定义图：没有服务端 id，本地-only
                info.wallpaperType = WallpaperType.CustomImage
                info.imageUri = this.previewUri
            }
        } else {
            info.wallpaperType = this.previewInfo.wallpaperType
            info.solidColor = this.previewInfo.solidColor
            info.gradientColors = this.previewInfo.gradientColors
            if (this.previewInfo.gradientColors.size >= 2) {
                info.gradientColorStart = this.previewInfo.gradientColors[0]
                info.gradientColorEnd = this.previewInfo.gradientColors[1]
            }
            info.patternColor = this.previewInfo.patternColor
            info.patternIntensity = this.previewInfo.patternIntensity
            info.patternFile = this.previewInfo.patternFile
            info.patternOverlayEnabled = false
            info.isDarkMode = this.previewInfo.isDarkMode
        }
        getWallpaperBackgroundService().setPerChatWallpaperForPeer(
            this.peerWallpaperId, this.peerWallpaperType, this.peerWallpaperAccessHash,
            info, cloudId, cloudHash)
        this.previewVisible = false
        Hilog.info(0, "CjTelegram", "[WallpaperPicker] applyForPeer: peer=${this.peerWallpaperId} type=${info.wallpaperType.ordinal()} cloudId=${cloudId}")
        routerPop()
    }

    // ──────────────────────────────────────────────────────────
    // Set a Color（复用既有 8 项内置渐变/图案/纯色预设）
    // ──────────────────────────────────────────────────────────

    private func colorPresetIndices(): Array<Int32> {
        return [0, 1, 2, 3, 4, 5, 6, 7]
    }

    private func colorPresetAt(idx: Int32): WallpaperInfo {
        let presets = getWallpaperBackgroundService().getBuiltinPresets()
        let i = Int64(idx)
        if (i >= 0 && i < presets.size) { return presets[i] }
        return presets[0]
    }

    private func applyColorPreset(idx: Int32): Unit {
        getTelegramCoreSettingsService().saveChatBackground("")
        getWallpaperBackgroundService().saveCurrentPreset(idx)
        // Source commits every selection to themeSpecificChatWallpapers for the effective
        // themeReference (automatic theme while auto-night is active). Preserve the complete
        // typed value in that keyed slot; a process-global preset index cannot represent this.
        saveSelectedWallpaper(this.colorPresetAt(idx))
        this.currentAppliedUri = ""
        this.currentPresetIndex = idx
        this.previewVisible = false
        Hilog.info(0, "CjTelegram", "[WallpaperPicker] applyColorPreset: ${idx}")
    }

    /** Colors 按钮展开态的 swatch 数据源：纯色只有一枚色块，渐变/图案用 4 色数组。 */
    private func previewSwatchColors(): Array<UInt32> {
        if (this.previewKind == WallpaperType.SolidColor) {
            return [this.previewInfo.solidColor]
        }
        return this.previewInfo.gradientColors
    }

    /** ForEach 单元素占位数组：借 D-127 已验证的"key 变则强制重挂载"机制驱动预览重绘。 */
    private func singlePreviewSlot(): Array<Int64> {
        return [0]
    }

    /**
     * Pattern 按钮必须对全部三种预设类型都有真实、可见的效果，否则退化成死回调：
     * - SolidColor / MultiColorGradient: 基础渲染分支不变，靠 patternOverlayEnabled 叠加/收起点阵层。
     * - PatternWallpaper: 基础渲染分支自带点阵，叠加层会重复画点（见 patternOverlayEnabled 判断），
     *   所以改走"关闭时降级为 MultiColorGradient（同一份 gradientColors，去掉点阵）、开启时用回
     *   PatternWallpaper（原生点阵）"，两态都是真实、互斥、可观察的渲染差异。
     */
    private func previewEffectiveType(): WallpaperType {
        if (this.previewKind == WallpaperType.PatternWallpaper && !this.previewPatternOn) {
            return WallpaperType.MultiColorGradient
        }
        return this.previewKind
    }

    // 中央圆形钮图标绘制：round2 返修迁出为独立 `PlayTriangleIcon` @Component（文件底部），
    // 不再是本页面的方法 + 页面级单例 context 字段——见该组件头注释「归因重新定位」。

    // ──────────────────────────────────────────────────────────
    // Reset Chat Backgrounds
    // ──────────────────────────────────────────────────────────

    private func confirmReset(): Unit {
        let uiCtx = getUIContext()
        let cancelBtn = AlertDialogButtonOptions(value: "Cancel", action: { => () })
        let resetBtn = AlertDialogButtonOptions(
            value: "Reset",
            fontColor: 0xFFFF3B30,
            action: { => this.resetChatBackgrounds() }
        )
        uiCtx.showAlertDialog(AlertDialogParamWithOptions(
            title: "Reset Chat Backgrounds",
            message: "Remove all uploaded chat backgrounds and restore pre-installed backgrounds for all themes.",
            autoCancel: true,
            buttons: [cancelBtn, resetBtn]
        ))
    }

    private func resetChatBackgrounds(): Unit {
        getTelegramCoreSettingsService().saveChatBackground("")
        getWallpaperBackgroundService().saveCurrentPreset(0)
        // F-1a：与 saveChatBackground("") 同批，让复位真正回到"未选择"——不留一条带类型的旧
        // 记录压住 getCurrentWallpaper() 第一档。iOS resetWallpapers 清空整个
        // themeSpecificChatWallpapers，所以每个主题的壁纸槽都清掉。
        clearAllSelectedWallpapers()
        this.currentAppliedUri = ""
        this.currentPresetIndex = 0
        this.hiddenSlugs = ArrayList<String>()
        Hilog.info(0, "CjTelegram", "[WallpaperPicker] resetChatBackgrounds")
    }

    // ──────────────────────────────────────────────────────────
    // 图标资源（no-arg 包裹，避免 @r() 在部分宏上下文里不展开）
    // ──────────────────────────────────────────────────────────

    private func doneIconRes(): AppResource { return @r(app.media.username_nav_ic_done) }
    private func checkIconRes(): AppResource { return @r(app.media.media_ic_check) }
    private func closeIconRes(): AppResource { return @r(app.media.nav_ic_close) }
    private func trashIconRes(): AppResource { return @r(app.media.set2_ic_trash) }
    private func forwardIconRes(): AppResource { return @r(app.media.chatroom_ic_forward) }

    /**
     * TC-0408-round5 F-1.2：`.glass` 导航栏返回箭头，逐字照抄 `DevicesPage.cj:728-739
     * backArrowCommands()`（TC-0134-round5 §6.1 已坐实的 vp→px 密度换算写法）。ArkUI Path
     * 的 commands 按 px 消费，而 .width/.height/.strokeWidth 是 Length（默认单位 vp），
     * 这一次换算必须由调用方自己补。坐标对位源侧 glassBackArrowImage
     * （NavigationButtonNode.swift:8-23）：44x44 画布，topRightPoint (24.6,14)，
     * centerPoint (17,22)，bottomRightPoint (24.6,30)。
     */
    private func backArrowCommands(): String {
        let scale: Float64 = match (this.getUIContext().vp2px(1.0.vp)) {
            case Some(len) => len.value
            case None => Float64(getDefaultDisplaySync().densityPixels)
        }
        let xRight: Float64 = 24.6 * scale
        let xApex: Float64 = 17.0 * scale
        let yTop: Float64 = 14.0 * scale
        let yMid: Float64 = 22.0 * scale
        let yBottom: Float64 = 30.0 * scale
        return "M${xRight} ${yTop} L${xApex} ${yMid} L${xRight} ${yBottom}"
    }

    /**
     * diag-suite_settings_appearance-TC-0408-round8.md F-1.7：网格选中标记的对勾折线，对位
     * RadialCheckContentNode.draw（RadialCheckContentNode.swift:110-153）：
     * diameter = 50 ⇒ factor = max(0.3, 50/50) = 1.0，center = (25,25)；
     * s  = (center.x - 10*factor, center.y + 1*factor) = (15,26)
     * p1 = (7,7)   ⇒ (22,33)
     * p2 = (13,-15) ⇒ (35,18)
     * lineWidth = max(1.7, 2.5*factor) = 2.5（由调用点的 .strokeWidth(2.5) 承担，vp 单位不换算，
     * 与 backArrowCommands() 调用点 :831 .strokeWidth(2) 同口径：commands 走 px、strokeWidth 走
     * vp）。密度换算写法逐字照抄本文件 backArrowCommands() 的 match 形状。
     */
    private func selectedCheckCommands(): String {
        let scale: Float64 = match (this.getUIContext().vp2px(1.0.vp)) {
            case Some(len) => len.value
            case None => Float64(getDefaultDisplaySync().densityPixels)
        }
        let x0: Float64 = 15.0 * scale
        let y0: Float64 = 26.0 * scale
        let x1: Float64 = 22.0 * scale
        let y1: Float64 = 33.0 * scale
        let x2: Float64 = 35.0 * scale
        let y2: Float64 = 18.0 * scale
        return "M${x0} ${y0} L${x1} ${y1} L${x2} ${y2}"
    }

    // ──────────────────────────────────────────────────────────
    // UI
    // ──────────────────────────────────────────────────────────

    func build() {
        Stack {
            Column {
                // ===== 导航栏：Back / "Chat Background" / Edit /Done =====
                // TC-0408-round5 F-1（Diff-1/2/3 同根因，按 DevicesPage.cj:756-800 先例整体重做）：
                // 源侧 `ItemListController.swift:286 style:.glass` 一次决定导航区无自身底色
                // （NavigationBarImpl.swift:655-677 不挂 backgroundNode）+ 返回控件/Edit 各自套
                // 一个圆角=高*0.5 的白底容器，前景色为 `.glass` 下改派的 panelControlColor（纯黑），
                // 不是 `.legacy` 的 accent 蓝。
                Row {
                    // F-1.2：返回控件——圆形玻璃底 + Path 描边 chevron（不用 Image().fillColor()，
                    // 该 SVG 是 fill="none" 开口折线，fillColor 会填成实心三角，TC-0134-round4 §6.2
                    // 已坐实）。
                    Stack {
                        Path()
                            .width(44)
                            .height(44)
                            .commands(this.backArrowCommands())
                            .fill(Color.Transparent)
                            .stroke(0x000000)
                            .strokeWidth(2)
                            .strokeLineCap(LineCapStyle.Round)
                            .strokeLineJoin(LineJoinStyle.Round)
                    }
                    .width(44)
                    .height(44)
                    .borderRadius(22)
                    .backgroundColor(0xFFFFFF)
                    .alignContent(Alignment.Center)
                    .onClick({ _ => routerPop() })

                    Blank().layoutWeight(1)

                    // F-1.4：标题字重 Bold → Medium（对位源侧 .semibold）。字号 17 一字不改
                    // （§Diff-8 已否决把 fontSize 收到 15.7 的处方——两套字体墨迹度量差，非代码偏差）。
                    Text(trSource("Chat Background"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(getAppThemeTextColor())

                    Blank().layoutWeight(1)

                    if (this.editing) {
                        // 编辑态 Done 分支：TC-0409 判据面，本轮不动。
                        Stack {
                            Image(this.doneIconRes())
                                .width(20)
                                .height(20)
                                .fillColor(getAppThemeAccentColor())
                        }
                        .width(44)
                        .height(44)
                        .onClick({ _ => this.exitEditing() })
                    } else {
                        // F-1.3：非编辑态 Edit——白色胶囊，形状照抄
                        // DevicesPage.cj:612-641 editButtonContent() 的 Edit 分支。
                        Row {
                            Text(trSource("Edit"))
                                .fontSize(17)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0x000000)
                                .onClick({ _ => this.editing = true })
                        }
                        .height(44)
                        .padding(left: 14, right: 14)
                        .borderRadius(22)
                        .backgroundColor(0xFFFFFF)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(VerticalAlign.Center)
                    }
                }
                .width(100.percent)
                .height(44)
                .padding(left: 16, right: 16)
                .backgroundColor(getAppThemeBackground())
                .alignItems(VerticalAlign.Center)

                Scroll {
                    Column {
                        // ===== 顶部动作卡：Set a Color / Choose from Gallery =====
                        // round4 F-1/F-2（D-1/D-2，dev_pattern.md D-165）：卡本体 .width(100.percent)
                        // 后不能再叠水平 .margin(left/right)，那会在父宽之外摞出溢出盒，右侧被裁掉
                        // （右内缩归零）。水平留白改由外包一层 Column 的 .padding 承载，纵向分量
                        // （top: 16）留在卡本体的 .margin 上，两者可在同一节点并存。形状照抄本仓
                        // 已落地先例 pages/DevicesPage.cj:1194-1195。脚注文字按源侧 ItemList 分区
                        // 模型（ThemeGridControllerNode.swift:702 ItemListTextItem）移出白卡，成为
                        // 页面灰底上的兄弟节点。
                        Column {
                            Column {
                                Row {
                                    Text(trSource("Set a Color"))
                                        .fontSize(17)
                                        .fontColor(getAppThemeAccentColor())
                                        .layoutWeight(1)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 15, bottom: 15)
                                .alignItems(VerticalAlign.Center)
                                .onClick({ _ => this.colorPickerVisible = true })

                                // TC-0408-round5 F-2（Diff-4）：补右端内缩，对位源侧
                                // ItemListActionItem.swift:184 separatorRightInset（本屏 action item
                                // 均 systemStyle:.glass ⇒ 16.0）。验收数：右端应落在 1264-56=1208px。
                                Divider().color(getAppThemeDividerColor()).strokeWidth(1).margin(left: 16, right: 16)

                                Row {
                                    Text(trSource("Choose from Gallery"))
                                        .fontSize(17)
                                        .fontColor(getAppThemeAccentColor())
                                        .layoutWeight(1)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 15, bottom: 15)
                                .alignItems(VerticalAlign.Center)
                                .onClick({ _ => this.photoPickerVisible = true })
                            }
                            .width(100.percent)
                            .backgroundColor(getAppThemeCardColor())
                            .borderRadius(12)
                            .margin(top: 16)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16)

                        // TC-0408-round5 F-3（Diff-5）：水平内缩改为 31vp，对位源侧
                        // ItemListTextItem.swift:162 leftInset=15.0 + :243 titleOrigin =
                        // leftInset + params.leftInset（params.leftInset=sideInset=16.0）⇒ 31。
                        // 写 31 不是 32——源侧是 15+16 两段叠加，32 是行文字的 16+16
                        // （ItemListActionItem.swift:237），两者本就差 1pt，不为凑整改成 32。
                        Row {
                            Text(trSource("You can set a custom background image and share it with your friends."))
                                .fontSize(13)
                                .fontColor(getAppThemeSecondaryTextColor())
                        }
                        .width(100.percent)
                        .padding(left: 31, right: 31, top: 8, bottom: 8)

                        // ===== 中段：三列纵向网格（真实云端壁纸） =====
                        // round4 F-2（D-2）：网格加白卡容器，对位源侧 :302 itemBlocksBackgroundColor
                        // + :323 cornersImage(top:true,bottom:true,glass:true)。外层按 F-1 的形状
                        // 套 padding 承载水平留白；Grid 自身的 padding 下调为卡内内边距，避免
                        // 16+16=32 vp 双重内缩。.clip(true)（D-124）防止首/末行按压高亮露方角。
                        Column {
                            Column {
                                Grid {
                                ForEach(this.gridEntries(), itemGenerator: { entry: WallpaperGridEntry, _idx: Int64 =>
                                GridItem {
                                    // diag-suite_settings_appearance-TC-0408-round8.md F-1.4: 迭代对象从
                                    // visibleWallpapers() 换成 gridEntries()——选中态与「当前生效壁纸」
                                    // 现在是 entry 的字段（WallpaperGridEntry，文件底部），不再靠下标/
                                    // 字符串判据现算；entry.key 已在 gridEntries() 里按内容算好，见下方
                                    // keyGeneratorFunc。原 D-127（下标当 key 会在删除后错配旧节点）与
                                    // round3 F-2.2（缩略图到位需强制重挂载）两条约束继续由 entry.key
                                    // 覆盖，未回退。
                                    Stack {
                                        // TC-0408 round3 RC-B: 格子唯一图像源此前直接喂壁纸文档原件
                                        // （mime_type application/x-tgwallpattern，ArkUI 无解码器，恒
                                        // 为空）。源侧 SettingsThemeWallpaperNode.swift:151-213 是「底
                                        // 色/渐变 + 图案缩略图叠加」两层结构，改为对位实现：
                                        // 底层——按 WallPaperSettings.colorsArray() 的颜色数分三态
                                        // （复用已验证稳定的 WallpaperBackgroundComponent 渐变实现，
                                        // 不在本页另写一份），颜色数为 0（服务端未给 settings）时保留
                                        // 原占位块。
                                        // round4 F-3（D-3）：round3 F-2 的「底色 + intensity 透明度叠加」
                                        // 只是 isPattern 图案壁纸的合成模型（对位 SettingsThemeWallpaperNode
                                        // .swift:265-277），此前无条件套给了全部条目，把非 pattern 的照片
                                        // 壁纸也叠上了 0.5 不透明度 + 0xFFE5E5EA 底色 ⇒ 整体发白、对比度
                                        // 腰斩。现按 item.isPattern（WallpaperResourcesService.cj:670 已
                                        // 解析）分两支：isPattern 分支保持两层合成不变；非 isPattern 分支
                                        // 只画一层缩略图、.opacity 不设（等价 1.0），对位 :312-318 的
                                        // self.imageNode.alpha = 1.0。缩略图 URI 未到位时两支都退回既有
                                        // 占位块。
                                        // diag-suite_settings_appearance-TC-0408-round8.md F-1.5: 头格
                                        // （entry.isPresetEntry）是新增的前置分支——当前生效壁纸不在云端
                                        // 列表里（内置预设 / 主题默认档）时，用同一个
                                        // WallpaperBackgroundComponent 渲染 entry.presetInfo，对位源侧用
                                        // 同一节点渲染 entry 0（ThemeGridControllerItem.swift:218），不为
                                        // 它另开一套渲染。其余分支只把 item 换成 entry.item。
                                        if (entry.isPresetEntry) {
                                            WallpaperBackgroundComponent(
                                                wallpaperType: entry.presetInfo.wallpaperType,
                                                solidColor: entry.presetInfo.solidColor,
                                                gradientColorStart: entry.presetInfo.gradientColorStart,
                                                gradientColorEnd: entry.presetInfo.gradientColorEnd,
                                                gradientAngle: entry.presetInfo.gradientAngle,
                                                imageUri: entry.presetInfo.imageUri,
                                                fallbackColor: entry.presetInfo.solidColor,
                                                gradientColors: entry.presetInfo.gradientColors,
                                                phase: entry.presetInfo.phase,
                                                isDarkMode: entry.presetInfo.isDarkMode,
                                                patternIntensity: entry.presetInfo.patternIntensity,
                                                patternFile: entry.presetInfo.patternFile,
                                                patternOverlayEnabled: entry.presetInfo.patternOverlayEnabled
                                            )
                                        } else if (entry.item.isPattern) {
                                            // A pattern is one wallpaper value, not an Image laid over an
                                            // unrelated light gradient. Feeding the signed intensity and raster
                                            // mask through the shared renderer preserves source's negative-
                                            // intensity black-background branch in both thumbnails and previews.
                                            WallpaperBackgroundComponent(
                                                wallpaperType: this.cloudPatternInfo(entry.item).wallpaperType,
                                                solidColor: this.cloudPatternInfo(entry.item).solidColor,
                                                gradientColorStart: this.cloudPatternInfo(entry.item).gradientColorStart,
                                                gradientColorEnd: this.cloudPatternInfo(entry.item).gradientColorEnd,
                                                gradientAngle: 180.0,
                                                imageUri: "",
                                                fallbackColor: this.cloudPatternInfo(entry.item).solidColor,
                                                gradientColors: this.cloudPatternInfo(entry.item).gradientColors,
                                                phase: 0,
                                                isDarkMode: this.cloudPatternInfo(entry.item).isDarkMode,
                                                patternIntensity: this.cloudPatternInfo(entry.item).patternIntensity,
                                                patternFile: this.cloudPatternInfo(entry.item).patternFile,
                                                patternOverlayEnabled: this.cloudPatternInfo(entry.item).patternOverlayEnabled
                                            )
                                        } else if (this.wallpaperThumbUriFor(entry.item.slug).size > 0) {
                                            // 非 pattern（照片壁纸）：只画一层缩略图，不设 opacity、
                                            // 不画底色层，对位 :312-318 self.imageNode.alpha = 1.0。
                                            Image(this.wallpaperThumbUriFor(entry.item.slug))
                                                .width(100.percent)
                                                .height(100.percent)
                                                .objectFit(ImageFit.Cover)
                                        } else {
                                            // 唯一保留占位块的场合：既非 pattern（拿不到 settings.colors
                                            // 底色）、缩略图又未就绪——对位源侧 :216-219 只在「这一格没有
                                            // 可画内容」（isEmpty）时才用 mediaPlaceholderColor 填底。
                                            Column {}
                                                .width(100.percent)
                                                .height(100.percent)
                                                .backgroundColor(0xFFE5E5EA)
                                        }

                                        if (this.editing) {
                                            if (this.isItemSelected(entry.item.slug)) {
                                                Stack {
                                                    Image(this.checkIconRes())
                                                        .width(14)
                                                        .height(14)
                                                        .fillColor(0xFFFFFF)
                                                }
                                                .width(22)
                                                .height(22)
                                                .backgroundColor(getAppThemeAccentColor())
                                                .borderRadius(11)
                                                .position(x: 6, y: 6)
                                            } else {
                                                // D-144 返修：0x00000000 在本 SDK 下的 alphaAdapt 会强制
                                                // 补 alpha=FF，渲染成不透明黑而非"空心圈"要求的透明底；
                                                // 唯一真正生效的透明写法是 Color.Transparent。
                                                Column {}
                                                    .width(22)
                                                    .height(22)
                                                    .backgroundColor(Color.Transparent)
                                                    .borderRadius(11)
                                                    .borderWidth(2)
                                                    .borderColor(0xFFFFFF)
                                                    .position(x: 6, y: 6)
                                            }
                                        } else if (entry.isSelected) {
                                            // diag-suite_settings_appearance-TC-0408-round8.md F-1.6:
                                            // 选中态判据从「字符串路径相等」改为 entry 字段本身——见
                                            // gridEntries()「entry 0 无条件 isSelected=true」。标记形态
                                            // 对位 SettingsThemeWallpaperNode.swift:224-225/:76/:141：
                                            // 50pt、居中、20% 黑 + 模糊底、运行时描线白色对勾（不是编辑态
                                            // 22vp 角标/位图，两者判据面互斥、互不影响）。
                                            Stack {
                                                Path()
                                                    .width(50)
                                                    .height(50)
                                                    .commands(this.selectedCheckCommands())
                                                    .fill(Color.Transparent)
                                                    .stroke(0xFFFFFF)
                                                    .strokeWidth(2.5)
                                                    .strokeLineCap(LineCapStyle.Round)
                                                    .strokeLineJoin(LineJoinStyle.Round)
                                            }
                                            .width(50)
                                            .height(50)
                                            .borderRadius(25)
                                            .backgroundColor(0x33000000)
                                            .backdropBlur(18.0)
                                            .alignContent(Alignment.Center)
                                        }
                                    }
                                    .width(this.gridItemWidth())
                                    .height(this.gridItemHeight())
                                    .borderRadius(8)
                                    .clip(true)
                                    .onClick({ _ => this.onGridEntryTap(entry) })
                                }
                            }, keyGeneratorFunc: { entry: WallpaperGridEntry, _idx: Int64 =>
                                // diag-suite_settings_appearance-TC-0408-round8.md F-1.4: 键已经在
                                // gridEntries() 里按内容算好（entry.key），不在这里现算——原先这里的
                                // wallpaperStableId + thumb-ready 拼接已经搬进 gridEntries() F-1.3。
                                entry.key
                            })
                        }
                        .columnsTemplate(this.gridColumnsTemplate())
                        .columnsGap(this.gridItemSpacing())
                        .rowsGap(this.gridLineSpacing())
                        .width(100.percent)
                        .height(this.gridHeight())
                        // diag-suite_settings_appearance-TC-0408-round8.md F-2.2: 关掉 Grid 自身的
                        // 手势轴——SDK nestedScroll 默认 SelfOnly（ohos.arkui.component.scroll.cj.d:1066），
                        // Grid 一旦可滚就会吞掉手势、不交给外层 Scroll。
                        .enableScrollInteraction(false)
                        // diag-suite_settings_appearance-TC-0408-round8.md F-2.1: 只保留水平分量——
                        // top/bottom 内边距原样搬到下方承托白卡的外层 Column，消除 .height(gridHeight())
                        // 与本节点自身纵向 padding 的双计（gridHeight() 契约是纯内容高，此前把 padding
                        // 折进同一节点的边框盒，恒定溢出 2×lineSpacing，产生了一个独立可滚的第二轴）。
                        .padding(left: this.gridItemSpacing(), right: this.gridItemSpacing())
                        }
                        .width(100.percent)
                        .backgroundColor(getAppThemeCardColor())
                        .borderRadius(12)
                        .clip(true)
                        .margin(top: 16)
                        // diag-suite_settings_appearance-TC-0408-round8.md F-2.1: 承接从 Grid 节点移出的
                        // 纵向内边距，卡内视觉留白不变，只是挂载节点换了——网格本身不再含 padding。
                        .padding(top: this.gridLineSpacing(), bottom: this.gridLineSpacing())
                        }
                        .width(100.percent)
                        .padding(left: this.gridSideInset(), right: this.gridSideInset())

                        // ===== 底部动作卡：Reset Chat Backgrounds =====
                        // round4 F-1（D-1）：水平留白改由外包 Column 的 padding 承载，纵向分量
                        // （top: 24, bottom: 32）留在卡本体 .margin 上。F-2（D-2）：脚注移出白卡。
                        // S6-05：单会话模式（iOS ThemeGridController mode .peer）不显示全局重置卡。
                        if (this.peerWallpaperId == 0) {
                        Column {
                            Column {
                                Row {
                                    Text(trSource("Reset Chat Backgrounds"))
                                        .fontSize(17)
                                        .fontColor(getAppThemeAccentColor())
                                        .layoutWeight(1)
                                }
                                .width(100.percent)
                                .height(48)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .onClick({ _ => this.confirmReset() })
                            }
                            .width(100.percent)
                            .backgroundColor(getAppThemeCardColor())
                            .borderRadius(12)
                            .margin(top: 24, bottom: 32)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16)

                        // TC-0408-round5 F-3（Diff-5）：同上，31vp。
                        Row {
                            Text(trSource("Remove all uploaded chat backgrounds and restore pre-installed backgrounds for all themes."))
                                .fontSize(13)
                                .fontColor(getAppThemeSecondaryTextColor())
                        }
                        .width(100.percent)
                        .padding(left: 31, right: 31, top: 8, bottom: 8)
                        }
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Start)
                }
                .layoutWeight(1)

                // ===== 编辑态底部选择工具条（TC-0409） =====
                if (this.editing) {
                    Row {
                        Stack {
                            Image(this.trashIconRes())
                                .width(22)
                                .height(22)
                                .fillColor(if (this.selectedCount() > 0) { 0xFFFF3B30 } else { 0xFFCCCCCC })
                        }
                        .width(44)
                        .height(44)
                        .onClick({ _ => this.confirmDelete() })

                        Blank().layoutWeight(1)

                        Text("${this.selectedCount()} selected")
                            .fontSize(13)
                            .fontColor(getAppThemeSecondaryTextColor())

                        Blank().layoutWeight(1)

                        Stack {
                            Image(this.forwardIconRes())
                                .width(22)
                                .height(22)
                                .fillColor(if (this.selectedCount() > 0) { getAppThemeAccentColor() } else { 0xFFCCCCCC })
                        }
                        .width(44)
                        .height(44)
                        .onClick({ _ => this.shareSelected() })
                    }
                    .width(100.percent)
                    .height(56)
                    .padding(left: 20, right: 20)
                    .backgroundColor(getAppThemeCardColor())
                    .alignItems(VerticalAlign.Center)
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(getAppThemeBackground())
            .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())

            // ===== 全屏预览覆盖层（TC-0410，rework_round=1: 三条入口共用） =====
            if (this.previewVisible) {
                Stack {
                    if (this.previewKind == WallpaperType.CustomImage) {
                        if (this.previewIsCloudPattern) {
                            // Canvas keeps its last pixels when a conditional sibling disappears.
                            // Source replaces the wallpaper node for this option change, so make
                            // Pattern/phase part of identity and mount a fresh renderer as well.
                            ForEach(this.singlePreviewSlot(), itemGenerator: { _slot: Int64, _idx: Int64 =>
                                WallpaperBackgroundComponent(
                                    wallpaperType: this.cloudPatternInfo(this.previewCloudPatternItem()).wallpaperType,
                                    solidColor: this.cloudPatternInfo(this.previewCloudPatternItem()).solidColor,
                                    gradientColorStart: this.cloudPatternInfo(this.previewCloudPatternItem()).gradientColorStart,
                                    gradientColorEnd: this.cloudPatternInfo(this.previewCloudPatternItem()).gradientColorEnd,
                                    gradientAngle: 180.0,
                                    imageUri: "",
                                    fallbackColor: this.cloudPatternInfo(this.previewCloudPatternItem()).solidColor,
                                    gradientColors: this.cloudPatternInfo(this.previewCloudPatternItem()).gradientColors,
                                    phase: this.previewGradientPhase,
                                    isDarkMode: this.cloudPatternInfo(this.previewCloudPatternItem()).isDarkMode,
                                    patternIntensity: this.cloudPatternInfo(this.previewCloudPatternItem()).patternIntensity,
                                    patternFile: this.cloudPatternInfo(this.previewCloudPatternItem()).patternFile,
                                    patternOverlayEnabled: this.previewPatternOn && this.cloudPatternInfo(this.previewCloudPatternItem()).patternOverlayEnabled
                                )
                            }, keyGeneratorFunc: { _slot: Int64, _idx: Int64 =>
                                "cloud_pattern_preview_${this.previewGradientPhase}_${this.previewPatternOn}"
                            })
                        } else if (this.previewBlurEnabled) {
                            Image(this.previewDisplayUri())
                                .width(100.percent)
                                .height(100.percent)
                                .objectFit(ImageFit.Cover)
                                .blur(10.0)
                        } else {
                            Image(this.previewDisplayUri())
                                .width(100.percent)
                                .height(100.percent)
                                .objectFit(ImageFit.Cover)
                        }
                    } else {
                        // Set a Color 内置预设预览：ForEach 单元素 + key 携带
                        // previewGradientPhase/previewPatternOn，二者任一变化都产生新 key，强制
                        // WallpaperBackgroundComponent 重新挂载（重新执行 aboutToAppear 读取新
                        // phase）——同一机制见本文件 D-127 返修 fast_fail 注释、ChatQrCodeSharePage.cj:392-401。
                        ForEach(this.singlePreviewSlot(), itemGenerator: { _slot: Int64, _idx: Int64 =>
                            WallpaperBackgroundComponent(
                                wallpaperType: this.previewEffectiveType(),
                                solidColor: this.previewInfo.solidColor,
                                gradientColorStart: 0xFFFCF6E9,
                                gradientColorEnd: 0xFFE8DBC8,
                                gradientAngle: 180.0,
                                imageUri: "",
                                fallbackColor: 0xFFE8E6DF,
                                gradientColors: this.previewInfo.gradientColors,
                                phase: this.previewGradientPhase,
                                patternColor: this.previewInfo.patternColor,
                                patternIntensity: this.previewInfo.patternIntensity,
                                patternFile: this.previewInfo.patternFile,
                                isDarkMode: this.previewInfo.isDarkMode,
                                patternOverlayEnabled: this.previewPatternOn && this.previewKind != WallpaperType.PatternWallpaper
                            )
                        }, keyGeneratorFunc: { _slot: Int64, _idx: Int64 =>
                            "preset_preview_${this.previewGradientPhase}_${this.previewPatternOn}"
                        })
                    }

                    // diag-suite_settings_appearance-TC-0410.md Finding 2 返修：源侧
                    // `WallpaperGalleryItemNode.messagesContainerNode`
                    // （WallpaperGalleryItem.swift:132-134/187-189/263/341-345/1595）在预览层的
                    // 壁纸底上叠 2 条示例聊天气泡，供用户判断壁纸下的文字可读性；目标侧此前完全
                    // 缺失该层。写法对齐本工程既有的"壁纸 + 气泡预览"先例
                    // （pages/TextSizeSelectionPage.cj:157-289 buildBubblePreviewPage()、
                    // pages/BubbleSettingsPage.cj:144-179 实时预览块）：Stack 内壁纸之上叠一个纯
                    // 装饰 Column，一条收到（左对齐）+ 一条发出（右对齐），纯字面样例文案（源侧
                    // 本身也是样例内容，无真实消息数据，不接 viewmodel/滚动/交互）。声明在本层
                    // （早于下方 chrome Column），按 D-149 记录的 Stack 兄弟节点命中测试优先级
                    // （后声明者优先接收点击）天然不拦截关闭钮/底部按钮/壁纸本身的点击——本文件
                    // 当前 SDK 绑定不暴露 hitTestBehavior/HitTestMode（D-149），不使用该 API。
                    //
                    // D-180 返修（review required_fix）：两条气泡的底色都必须走
                    // `this.presentation.{bubbleOutColor,bubbleInColor}`（core/storage/AppTheme.cj:34-35，
                    // computeSnapshot() 独立算出，与 accentColor 无派生关系），不得借用 accentColor 之类
                    // "数值上看着近"的字段——这正是本层存在的目的：让用户判断*真实气泡颜色*在该壁纸下
                    // 的可读性，取错色等于该层白加。取色写法对齐既有真实气泡消费方
                    // components/MessageBubble.cj:2718、pages/ChatRoomPage.cj:1633-1634、
                    // pages/AppearanceSettingsPage.cj:894-905。
                    //
                    // 文字色同一并改为 `this.presentation.textColor`（收到/发出共用同一快照文字色，
                    // 与 AppearanceSettingsPage.cj:896-897/903-904 的既有配对一致——快照未暴露独立的
                    // 气泡内/外文字色维度）。发出气泡原先写死白字是配原先错误的 accentColor（深蓝）
                    // 底色；换成 bubbleOutColor 后若仍留白字，在浅色主题下 bubbleOutColor=0xE8F5E9
                    // （浅薄荷绿）会导致白底白字般不可读——与 presentation.textColor 配对（浅色态黑字
                    // /深色态白字）才能保持对比度，这是本次修复必然牵连的改动，非独立臆改。
                    Column {
                        Row {
                            Column {
                                Text("Sure, sounds good!")
                                    .fontSize(15)
                                    .fontColor(this.presentation.textColor)
                                    .padding(left: 10, right: 10, top: 6, bottom: 6)
                            }
                            .backgroundColor(this.presentation.bubbleInColor)
                            .borderRadius(14)
                        }
                        .width(100.percent)
                        .justifyContent(FlexAlign.Start)
                        .margin(bottom: 8)

                        Row {
                            Column {
                                Text("See you there \u{1F44D}")
                                    .fontSize(15)
                                    .fontColor(this.presentation.textColor)
                                    .padding(left: 10, right: 10, top: 6, bottom: 6)
                            }
                            .backgroundColor(this.presentation.bubbleOutColor)
                            .borderRadius(14)
                        }
                        .width(100.percent)
                        .justifyContent(FlexAlign.End)
                    }
                    // D-181：非对称 top/bottom padding 只有在同一节点已带显式全尺寸声明时才会
                    // 把内容从物理边推开对应量；本节点补 .height(100.percent) 与父 Stack 满尺寸
                    // 对齐，使 padding 成为"定尺盒子内扣"（D-162 分支 a），而不是让 Stack 默认居中
                    // 把一个未定尺子容器整体对称撑大、内容仍停在原处。
                    .width(100.percent)
                    .height(100.percent)
                    .padding(left: 20, right: 20, top: 100.0 + getSafeAreaTop(), bottom: 160.0 + getSafeAreaBottom())
                    .justifyContent(FlexAlign.Center)

                    Column {
                        Row {
                            Stack(alignContent: Alignment.Center) {
                                Image(this.closeIconRes())
                                    .width(20)
                                    .height(20)
                                    .fillColor(0xFFFFFFFF)
                            }
                            .width(40)
                            .height(40)
                            .backgroundColor(0x4D000000)
                            .borderRadius(20)
                            .onClick({ _ => this.previewVisible = false })

                            Blank().layoutWeight(1)

                            if (this.previewUri.size > 0) {
                                Stack(alignContent: Alignment.Center) {
                                    Image(this.forwardIconRes())
                                        .width(20)
                                        .height(20)
                                        .fillColor(0xFFFFFFFF)
                                }
                                .width(40)
                                .height(40)
                                .backgroundColor(0x4D000000)
                                .borderRadius(20)
                                .onClick({ _ => this.sharePreview() })
                            }
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 12.0 + getSafeAreaTop())

                        Blank().layoutWeight(1)

                        if (this.previewKind == WallpaperType.CustomImage && !this.previewIsCloudPattern) {
                            Row {
                                Column {
                                    Text(trSource("Blur"))
                                        .fontSize(11)
                                        .fontColor(0xFFFFFFFF)
                                }
                                .width(56)
                                .height(56)
                                .backgroundColor(if (this.previewBlurEnabled) { 0x66FFFFFF } else { 0x33000000 })
                                .borderRadius(28)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(HorizontalAlign.Center)
                                .onClick({ _ => this.previewBlurEnabled = !this.previewBlurEnabled })

                                // 回合前恢复 main 能力：图片显示模式四选一（对位
                                // origin/main:WallpaperPickerPage.cj:492-586 的 IMAGE DISPLAY MODE 段，
                                // 此处收进预览浮层以匹配我方布局）。
                                Column {
                                    Text(this.previewDisplayModeName())
                                        .fontSize(11)
                                        .fontColor(0xFFFFFFFF)
                                }
                                .width(56)
                                .height(56)
                                .backgroundColor(0x33000000)
                                .borderRadius(28)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(HorizontalAlign.Center)
                                .onClick({ _ =>
                                    var next = this.previewDisplayMode + 1
                                    if (next > 3) { next = 0 }
                                    this.previewDisplayMode = next
                                })

                                // Motion: 无传感器桥接的诚实降级——可见但不可点、40% 不透明，不把实现说明
                                // 写进用户可见文案（diag-...-TC-0410.md「修法方向」5）。
                                Column {
                                    Text(trSource("Motion"))
                                        .fontSize(11)
                                        .fontColor(0xFFFFFFFF)
                                }
                                .width(56)
                                .height(56)
                                .backgroundColor(0x33000000)
                                .borderRadius(28)
                                .opacity(0.4)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(HorizontalAlign.Center)
                                .margin(left: 16)
                            }
                            .width(100.percent)
                            .justifyContent(FlexAlign.Center)
                            .padding(bottom: 16)

                            // 回合前恢复 main 能力：Blur 强度 / Dimming 强度两个连续滑杆。
                            // 对位 origin/main:WallpaperPickerPage.cj:641-668 与 :671-694
                            // （0..100、step 5 与 main 一致）。我方此前把两值写死为 50 / 0.0，
                            // 用户没有调节入口 —— 属能力丢失，按「合入结果不得让 main 失去已有
                            // 能力」补回。挂在预览浮层的按钮行之后（我方无 main 的设置卡布局），
                            // 落盘走本文件 applyCloudWallpaper() 已改为读真实值的那三行。
                            if (this.previewBlurEnabled) {
                                Row {
                                    Text("Blur Strength")
                                        .fontSize(13).fontColor(0xFFFFFFFF).layoutWeight(1)
                                    Text("${this.previewBlurStrength}%")
                                        .fontSize(13).fontColor(0xCCFFFFFF)
                                }
                                .width(100.percent)
                                .padding(left: 24, right: 24)

                                Slider(value: Float64(this.previewBlurStrength), min: 0.0, max: 100.0, step: 5.0)
                                    .width(100.percent)
                                    .padding(left: 24, right: 24, bottom: 8)
                                    .blockColor(0xFFFFFFFF)
                                    .trackColor(0x55FFFFFF)
                                    .selectedColor(0xFFFFFFFF)
                                    .onChange({ value: Float64, _: SliderChangeMode =>
                                        this.previewBlurStrength = Int32(value)
                                    })
                            }

                            Row {
                                Text("Dimming")
                                    .fontSize(13).fontColor(0xFFFFFFFF).layoutWeight(1)
                                Text("${Int32(this.previewDimming * 100.0)}%")
                                    .fontSize(13).fontColor(0xCCFFFFFF)
                            }
                            .width(100.percent)
                            .padding(left: 24, right: 24)

                            Slider(value: this.previewDimming * 100.0, min: 0.0, max: 100.0, step: 5.0)
                                .width(100.percent)
                                .padding(left: 24, right: 24, bottom: 16)
                                .blockColor(0xFFFFFFFF)
                                .trackColor(0x55FFFFFF)
                                .selectedColor(0xFFFFFFFF)
                                .onChange({ value: Float64, _: SliderChangeMode =>
                                    this.previewDimming = value / 100.0
                                })
                        } else {
                            // required_fix ⑤: 渐变/图案/纯色内置预设经 Set a Color 可达，选项按钮
                            // 按 diag-...-TC-0410.md 修法方向 2 分叉——Pattern+Colors 恒出现；中央
                            // 圆形钮仅当非纯色且颜色数≥2 时出现（本工程预设色数恒为 4）。
                            Row {
                                Row {
                                    Stack(alignContent: Alignment.Center) {
                                        if (this.previewPatternOn) {
                                            Image(this.checkIconRes())
                                                .width(18)
                                                .height(18)
                                                .fillColor(0xFF000000)
                                                .backgroundColor(0xFFFFFFFF)
                                                .borderRadius(9)
                                        } else {
                                            Column {}
                                                .width(18)
                                                .height(18)
                                                .borderRadius(9)
                                                .borderWidth(1.5)
                                                .borderColor(0xFFFFFFFF)
                                        }
                                    }
                                    .width(18)
                                    .height(18)

                                    Text(trSource("Pattern"))
                                        .fontSize(13)
                                        .fontWeight(FontWeight.Medium)
                                        .fontColor(0xFFFFFFFF)
                                        .margin(left: 9)
                                }
                                .width(96)
                                .height(30)
                                .backgroundColor(0x59000000)
                                .borderRadius(15)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(VerticalAlign.Center)
                                .onClick({ _ => this.previewPatternOn = !this.previewPatternOn })

                                if (this.previewKind != WallpaperType.SolidColor && this.previewInfo.gradientColors.size >= 2) {
                                    // round2 返修：`PlayTriangleIcon()` 每次这个 if 分支冷挂载都是
                                    // 全新组件实例，其内部 ctx 字段随之全新构造，与 Canvas 节点保持
                                    // 原生配对（见该组件头注释 + diag-...-TC-0410-round2.md 归因）。
                                    Stack(alignContent: Alignment.Center) {
                                        PlayTriangleIcon()
                                    }
                                    .width(48)
                                    .height(48)
                                    .backgroundColor(0x59000000)
                                    .borderRadius(24)
                                    .margin(left: 18)
                                    .onClick({ _ => this.previewGradientPhase = advanceSharedGradientPhase() })
                                }

                                Row {
                                    WallpaperColorsIcon(colors: this.previewSwatchColors())

                                    Text(trSource("Colors"))
                                        .fontSize(13)
                                        .fontWeight(FontWeight.Medium)
                                        .fontColor(0xFFFFFFFF)
                                        .margin(left: 9)
                                }
                                .width(92)
                                .height(30)
                                .backgroundColor(0x59000000)
                                .borderRadius(15)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(VerticalAlign.Center)
                                .margin(left: 18)
                                .onClick({ _ => this.previewColorsVisible = !this.previewColorsVisible })
                            }
                            .width(100.percent)
                            .justifyContent(FlexAlign.Center)
                            .padding(bottom: if (this.previewColorsVisible) { 12 } else { 16 })

                            if (this.previewColorsVisible) {
                                Row {
                                    ForEach(this.previewSwatchColors(), itemGenerator: { c: UInt32, _idx: Int64 =>
                                        Column {}
                                            .width(28)
                                            .height(28)
                                            .borderRadius(14)
                                            .backgroundColor(c)
                                            .borderWidth(1)
                                            .borderColor(0xFFFFFFFF)
                                            .margin(right: 8)
                                    }, keyGeneratorFunc: { c: UInt32, idx: Int64 =>
                                        "swatch_${idx}_${c}"
                                    })
                                }
                                .width(100.percent)
                                .justifyContent(FlexAlign.Center)
                                .padding(bottom: 16)
                            }
                        }

                        Row {
                            Button(if (this.peerWallpaperId != 0) { "Apply for Me" } else { trSource("Apply For All Chats") })
                                .width(100.percent)
                                .height(50)
                                .fontSize(17)
                                .fontColor(0xFFFFFFFF)
                                .backgroundColor(getAppThemeAccentColor())
                                .borderRadius(12)
                                .onClick({ _ => this.applyPreviewedWallpaper() })
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, bottom: 16.0 + getSafeAreaBottom())
                    }
                    .width(100.percent)
                    .height(100.percent)
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0xFF000000)
            }

            // ===== Set a Color 覆盖层 =====
            if (this.colorPickerVisible) {
                Column {
                    Row {
                        Text(trSource("Colors"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(getAppThemeTextColor())
                        Blank().layoutWeight(1)
                        Text(trSource("Done"))
                            .fontSize(16)
                            .fontColor(getAppThemeAccentColor())
                            .onClick({ _ => this.colorPickerVisible = false })
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 12.0 + getSafeAreaTop(), bottom: 12)
                    .backgroundColor(getAppThemeNavBarColor())
                    .alignItems(VerticalAlign.Center)

                    Grid {
                        ForEach(this.colorPresetIndices(), itemGenerator: { idx: Int32, _gi: Int64 =>
                            GridItem {
                                Stack {
                                    WallpaperBackgroundComponent(
                                        wallpaperType: this.colorPresetAt(idx).wallpaperType,
                                        solidColor: this.colorPresetAt(idx).solidColor,
                                        gradientColorStart: 0xFFFCF6E9,
                                        gradientColorEnd: 0xFFE8DBC8,
                                        gradientAngle: 180.0,
                                        imageUri: "",
                                        fallbackColor: 0xFFE8E6DF,
                                        gradientColors: this.colorPresetAt(idx).gradientColors,
                                        phase: 0,
                                        patternColor: this.colorPresetAt(idx).patternColor,
                                        patternIntensity: this.colorPresetAt(idx).patternIntensity,
                                        patternFile: this.colorPresetAt(idx).patternFile,
                                        isDarkMode: this.colorPresetAt(idx).isDarkMode
                                    )
                                }
                                .width(100.percent)
                                .height(84)
                                .borderRadius(8)
                                .clip(true)
                                .onClick({ _ => this.openPresetPreview(idx) })
                            }
                        })
                    }
                    .columnsTemplate("1fr 1fr 1fr 1fr")
                    .columnsGap(8)
                    .rowsGap(8)
                    .width(100.percent)
                    .height(176)
                    .padding(16)
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(getAppThemeBackground())
            }

            // ===== Choose from Gallery 覆盖层 =====
            if (this.photoPickerVisible) {
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x33000000)
                    .onClick({ _ => this.photoPickerVisible = false })

                Column {
                    PhotoPicker(
                        maxSelect: 1,
                        onSelect: { photos: ArrayList<SelectedPhoto> =>
                            if (!photos.isEmpty()) {
                                this.openCustomPhotoPreview(photos[0].uri)
                            } else {
                                this.photoPickerVisible = false
                            }
                        },
                        onClose: { => this.photoPickerVisible = false }
                    )
                }
                .width(100.percent)
                .position(x: 0, y: 40.percent)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }
}

/**
 * WallpaperGridEntry — 网格 entry 数据结构，对位源侧 ThemeGridControllerEntry
 * （ThemeGridControllerNode.swift:43-60）。
 *
 * diag-suite_settings_appearance-TC-0408-round8.md F-1.1：选中态（`isSelected`）与「当前生效
 * 壁纸如何进入网格」（`isPresetEntry` / `presetInfo`）此前都是渲染时对字符串路径现算的判据，
 * 只覆盖「自定义图片」一层，内置预设 / 主题默认档恒不命中。改为随 entry 一起构造的字段——
 * `WallpaperPickerPage.gridEntries()` 无条件把当前生效壁纸插为 entry 0 并设 `isSelected=true`
 * （对位 :446），与其同身份的云端条目在尾部去重（对位 :493/:505），三种档位（自定义图片走
 * `item` + 云端身份比较；内置预设 / 主题默认档走 `presetInfo`，来自
 * `WallpaperBackgroundService.getCurrentWallpaper()` 的统一解析）都能落到这一个结构上。
 */
public class WallpaperGridEntry {
    /** 云端条目；isPresetEntry 为 true 时本字段不参与渲染（保持默认空值）。 */
    public var item: WallpaperItem = WallpaperItem()
    /** 当前生效壁纸不是云端条目（内置预设 / 主题默认档）时，用它渲染 entry 0。 */
    public var presetInfo: WallpaperInfo = WallpaperInfo()
    public var isPresetEntry: Bool = false
    public var isSelected: Bool = false
    /** ForEach 键，构造时算好，渲染期不再计算。 */
    public var key: String = ""
    public init() {}
}

/**
 * PlayTriangleIcon — 预览态中央圆形钮的白色三角图标（round2 返修）。
 *
 * diag-suite_settings_appearance-TC-0410-round2.md 归因重新定位：round1 把中央图标间歇性
 * 空白归因为「`onReady` 触发时 `this.playIconCtx.width`/`.height` 读回宽高竞态」，改用字面量
 * 常量 `20.0`/`20.0` 绕开该子问题——这个修法本身无害（与 Canvas 声明尺寸 `.width(20).height(20)`
 * 一致），但没有解决更上游的问题：round2 复测仍有 2/5 次空白（3 次首开全部成功，同一色卡连续
 * 2 次重开全部空白），机制是 `WallpaperPickerPage` 页面级单例 `CanvasRenderingContext2D`
 * （原 `playIconCtx` 字段）被反复重新绑定到每次预览打开都冷挂载的全新 `Canvas` 节点——
 * 首次挂载时 context 与 Canvas 节点是同批构造的原生配对，`onReady` 可靠触发；此后每次重开，
 * Canvas 节点是新的，但 context 对象是上一次挂载遗留的旧对象，这次「旧 context 配新节点」的
 * `onReady` 不总会重新触发，不触发则这次挂载压根没有调用过绘制、画布是空白像素。
 *
 * 修法：把图标拆成这个独立 `@Component`，context 变成组件自己的实例字段——组件所在的
 * `if (colors.size >= 2)` 分支本来就每次预览打开都整体冷挂载，只是缺了「context 对象本身
 * 也要跟着换新」这一步；拆成独立组件后，每次冷挂载都是全新组件实例、全新 `ctx` 字段，与
 * Canvas 节点天然保持原生配对——对齐同覆盖层内 `components/WallpaperBackgroundComponent.cj`
 * （`gradCtx`/`patternCtx`/`overlayCtx` 均为该组件自己的实例字段，本轮全部截图未见一次背景
 * 空白）已验证正确的模式。
 *
 * 绘制几何与颜色逐字沿用 round1 已确认无误的实现（同形同比例，字面量常量与 Canvas 声明尺寸
 * 一致），只改变 context 对象的生命周期归属（页面单例 → 组件实例）。
 *
 * 待设备验证：本 feature 无设备可用，间歇性缺陷（round2 复测 5 次 2 次复现）静态改完无法
 * 自证已修复——需反复进出预览页若干次观察中央图标是否仍出现空白。
 */
@Component
public class PlayTriangleIcon {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    private let ctx: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    private func draw(): Unit {
        let w = 20.0
        let h = 20.0
        this.ctx.clearRect(0.0, 0.0, w, h)
        this.ctx.fillStyle = 0xFFFFFFFF
        this.ctx.beginPath()
        this.ctx.moveTo(w * 0.28, h * 0.18)
        this.ctx.lineTo(w * 0.28, h * 0.82)
        this.ctx.lineTo(w * 0.78, h * 0.5)
        this.ctx.closePath()
        this.ctx.fill()
    }

    func build() {
        Canvas(this.ctx)
            .width(20)
            .height(20)
            .onReady({ => this.draw() })
    }
}

/** Source WallpaperOptionButtonNode `.colors` value: an 18 vp circular, equally split swatch. */
@Component
public class WallpaperColorsIcon {
    @Prop var colors: Array<UInt32>
    private let ctx: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    private func draw(): Unit {
        let size = 18.0
        let center = size / 2.0
        let count = this.colors.size
        this.ctx.clearRect(0.0, 0.0, size, size)
        if (count == 0) { return }
        let full = 6.283185307179586
        let step = full / Float64(count)
        var i: Int64 = 0
        while (i < count) {
            let start = -1.5707963267948966 + Float64(i) * step
            let finish = start + step
            this.ctx.fillStyle = this.colors[i]
            this.ctx.beginPath()
            this.ctx.moveTo(center, center)
            this.ctx.arc(center, center, center, start, finish, counterclockwise: false)
            this.ctx.closePath()
            this.ctx.fill()
            i++
        }
    }

    func build() {
        Canvas(this.ctx)
            .width(18)
            .height(18)
            .onReady({ => this.draw() })
    }
}

/**
 * JSON 字符串转义（仅 " 与 \，沙箱路径无其他特殊字符），
 * 同 components/ImageViewer.cj imageViewerJsonEscape 先例。
 */
private func jsonEscapeWallpaperPicker(s: String): String {
    var result = ""
    for (ch in s.runes()) {
        if (ch == r'"') {
            result += "\\\""
        } else if (ch == r'\\') {
            result += "\\\\"
        } else {
            result += ch.toString()
        }
    }
    return result
}
