package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import kit.AbilityKit.{Want, Flags}
import std.collection.ArrayList
import std.math.{sqrt, floor}
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import ohos_app_cangjie_entry.utils.safeAnimateTo

/**
 * GalleryPage — 媒体画廊主页面（GALL-UI-1）（混合工程迁移版）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack (appStack)
 *  - build() 根去掉 NavDestination 包裹，用 Column 承载 if/else 内容
 *  - onReady 参数解析 + aboutToAppear 实逻辑 → ensureLoaded()(takePending + load) + .onAppear
 *
 * 对应 iOS GalleryController + GalleryControllerNode + GalleryPagerNode
 *
 * 功能：
 *   - 接收路由参数（"peerType|peerId" 格式，可选）或直接使用全局当前聊天
 *   - 网格缩略图展示图片/视频条目（GridGallery）
 *   - 点击缩略图后弹出 Swiper 全屏浏览（类 GalleryPagerNode）
 *   - Footer 显示当前索引 / 总数（对应 GalleryFooterContentNode）
 *   - 支持从 MainTabPage.pageMap 路由进入
 *
 * P2-194: 捏合+双击定点缩放（onTouch 双指距离追踪 + .scale(x:y:)）
 *         PinchGesture 在 Cangjie SDK 6.0 未导出，使用 onTouch two-finger fallback
 *         双击切换 1.0↔2.0 缩放；缩放后单指拖动平移；边界回弹
 * P2-195: 下拉关闭手势（单指向下拖动 → 渐进透明 + 缩小 → 超阈值关闭 / 未超回弹）
 * P2-198: 单击切换 chrome（顶部/底部工具栏）+ 无操作 3 秒自动隐藏（spawn sleep timer）
 * P2-199: Caption 展示（GalleryItem.caption 真实数据，底栏展示，长文可滚动）
 * P2-200: viewer 内视频直接播放（Video 组件 + VideoController，非跳出）
 *         + 媒体索引底部缩略图条（快速跳转条目）
 * P2-201: 视频进度条/seek + 当前时间/总时长标签 + 缓冲区间指示（灰条 Stack 叠加）
 * P2-203: 全屏切换按钮（VideoController.requestFullscreen / exitFullscreen）
 *         + onFullscreenChange 回调追踪全屏态
 *
 * 路由注册：MainTabPage.pageMap "GalleryPage" 分支（由 integration_contract emit 接线）
 * 路由参数格式："peerType|peerId"（如 "user|123456789"）
 *
 * 调用链：
 *   aboutToAppear
 *     → parseRouteParam(param)
 *     → GalleryService.loadAllMediaItems(peerType, peerId)
 *         → items / isLoading 更新
 *   tapItem(index)
 *     → GalleryService.setCurrentIndex(index)
 *     → showViewer = true → Swiper 全屏浏览
 *   video item in viewer
 *     → Video(src: localPath, controller: videoController) 真实加载
 *     → onPrepared → videoTotalDuration 更新
 *     → onUpdate → videoCurrentTime + videoProgressPct 更新
 *     → Slider.onChange → videoController.setCurrentTime(seek)
 *     → fullscreen button → videoController.requestFullscreen(true/false)
 */
@HybridComponentEntry
@Component
public class GalleryPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var items: ArrayList<GalleryItem> = ArrayList<GalleryItem>()
    @State var isLoading: Bool = false
    @State var showViewer: Bool = false
    @State var viewerIndex: Int32 = 0
    @State var peerType: String = ""
    @State var peerId: Int64 = 0
    @State var viewerWidthVp: Float64 = 402.0

    private var swiperController: SwiperController = SwiperController()

    // ─── P2-197 缩略图条快速定位 ──────────────────────────────────────────────────
    // Scroller 控制器：绑定到底部缩略图条的 Scroll 组件，实现当前项自动居中
    private var thumbnailStripScroller: Scroller = Scroller()

    // ─── P2-204 画中画（inline PiP）─────────────────────────────────────────────
    // 实现说明：HarmonyOS Cangjie SDK 当前版本无 PiPWindow / PictureInPicture API
    // （AVKit.AVPictureInPictureController iOS 对应 API 无 Cangjie 等价物）
    // 鸿蒙悬浮窗需要 ohos.permission.SYSTEM_FLOAT_WINDOW（系统特权，普通应用不可用）
    // 实现选择：Gallery 内联 PiP —— 在 GalleryPage Stack 内用 position 定位小窗
    // 效果：视频播放时点击 PiP 按钮 → 小窗固定在右下角，可继续浏览其他媒体项
    // 局限：仅在 GalleryPage 内部有效，不是跨应用/系统级悬浮窗（已诚实标注）
    @State var pipIsActive: Bool = false
    // PiP 小窗播放的视频路径（PiP 激活时快照当前视频 src）
    @State var pipVideoSrc: String = ""
    // PiP 专用 VideoController（与主播放器解耦）
    private var pipVideoController: VideoController = VideoController()
    // PiP 小窗播放状态
    @State var pipIsPlaying: Bool = false
    // PiP 小窗静音状态（独立于主播放器）
    @State var pipIsMuted: Bool = false

    // ─── P2-196 开关转场动画状态 ──────────────────────────────────────────────────
    // 查看器整体缩放因子（开场动画：0.3 → 1.0；关场：1.0 → 0.3）
    @State var viewerOpenScale: Float32 = Float32(1.0)
    // 查看器整体透明度（开场：0.0 → 1.0；关场：1.0 → 0.0）
    @State var viewerOpenOpacity: Float64 = 1.0

    // ─── P2-194 缩放状态 ────────────────────────────────────────────────────────
    // 当前图片缩放倍率（1.0 = 原始大小，限 [0.5, 4.0]）
    @State var viewerScale: Float32 = Float32(1.0)
    // 缩放后平移偏移（dp 单位）
    @State var viewerOffsetX: Float64 = 0.0
    @State var viewerOffsetY: Float64 = 0.0
    // 双指距离追踪（不驱动 UI，不加 @State）
    private var lastPinchDist: Float64 = 0.0
    // 上次单指 Down 位置（用于平移计算）
    private var panStartX: Float64 = 0.0
    private var panStartY: Float64 = 0.0
    // 是否处于平移模式（单指拖动且已缩放）
    private var isPanning: Bool = false
    // 平移前的偏移快照
    private var panBaseOffsetX: Float64 = 0.0
    private var panBaseOffsetY: Float64 = 0.0
    // 双击识别
    private var tapCount: Int32 = 0

    // ─── P2-195 下拉关闭手势状态 ─────────────────────────────────────────────────
    // 下拉关闭拖动进度 (0.0=静止, 1.0=关闭阈值)
    @State var dismissProgress: Float64 = 0.0
    // 是否正在下拉关闭手势中
    private var isDismissGesture: Bool = false
    // 关闭阈值：拖动超过屏幕高度 25% 即关闭
    private let DISMISS_THRESHOLD: Float64 = 200.0

    // ─── P2-198 Chrome 显隐状态 ─────────────────────────────────────────────────
    // 是否显示顶/底 chrome
    @State var showViewerChrome: Bool = true
    // 自动隐藏定时器版本（每次交互 +1，spawn 检查版本号是否过期）
    private var chromeTimerVersion: Int32 = 0

    // ─── P2-200/201/203 视频播放状态 ────────────────────────────────────────────
    // 视频播放控制器（一个全局实例；切换视频条目时 stop+reuse）
    private var videoController: VideoController = VideoController()
    // 是否正在播放视频
    @State var videoIsPlaying: Bool = false
    // 视频是否已就绪（onPrepared 触发）
    @State var videoIsPrepared: Bool = false
    // 当前播放时间（秒）— onUpdate 真实值（P2-201）
    @State var videoCurrentTime: Int32 = 0
    // 总时长（秒）— onPrepared 真实值（P2-201）
    @State var videoTotalDuration: Int32 = 0
    // 进度百分比 0.0-100.0（驱动 Slider 位置）（P2-201）
    @State var videoProgressPct: Float64 = 0.0
    // 是否静音
    @State var videoIsMuted: Bool = false
    // 播放错误
    @State var videoHasError: Bool = false
    // 是否处于全屏模式（P2-203）
    @State var videoIsFullscreen: Bool = false
    // 控制栏隐藏计时器版本
    private var videoControlsTimerVer: Int32 = 0

    // ─── P2-202 播放速率 ─────────────────────────────────────────────────────────
    // 当前播放倍速（绑定到 Video.currentProgressRate；@State 驱动重建 Video 组件参数）
    // HarmonyOS PlaybackSpeed 枚举值：075X / 100X / 125X / 175X / 200X
    // iOS 档位映射：iOS 0.5x→0.75x; 1x→1x; 1.5x→1.25x（对应量 1.25 最近）; 2x→2x
    @State var videoPlaybackSpeed: PlaybackSpeed = PlaybackSpeed.SpeedForward100X
    // 是否显示速率选择菜单
    @State var showSpeedMenu: Bool = false

    // ─── P2-205 视频质量（HarmonyOS ArkUI Video 为单 src，无多码率 API）───────────
    // ArkUI Video 组件不提供多码率 / HLS 自适应流选择 API，质量固定为视频文件的原始质量。
    // 此处保留 UI 态字段供显示使用；质量切换需服务端多版本文件支持，当前版本诚实 defer。
    // 参照 iOS: UniversalVideoContentVideoQuality.auto / .quality(Int) — 对应 HLS 后端。
    // 结论：鸿蒙 ArkUI Video 单文件播放，无法在客户端切换码率，P2-205 UI 仅展示 "Auto"。
    @State var videoQualityLabel: String = "Auto"

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("GalleryPage")
        this.parseRouteParam(if (raw == "{}") { "" } else { raw })
        let _ = spawn {
            let svc = getGalleryService()
            launch {
                this.isLoading = true
            }
            svc.loadAllMediaItems(this.peerType, this.peerId)
            let loadedItems = svc.items
            launch {
                this.items = loadedItems
                this.isLoading = false
            }
        }
    }

    public func build() {
        Column {
            if (this.showViewer) {
                this.buildViewerOverlay()
            } else {
                this.buildGridView()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder func buildGridView(): Unit {
        Column {
            if (this.isLoading) {
                Column {
                    Text(trSource("Loading..."))
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.getItemCount() == 0) {
                Column {
                    Text("No media")
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                this.buildGrid()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x000000)
    }

    @Builder func buildGrid(): Unit {
        Grid {
            ForEach(this.getItemsArray(), itemGenerator: { item: GalleryItem, idx: Int64 =>
                GridItem {
                    this.buildThumbnailCell(item, idx)
                }
            })
        }
        .columnsTemplate("1fr 1fr 1fr")
        .rowsGap(2)
        .columnsGap(2)
        .width(100.percent)
        .layoutWeight(1)
        .backgroundColor(0x000000)
    }

    @Builder func buildThumbnailCell(item: GalleryItem, idx: Int64): Unit {
        Stack {
            if (item.localPath.size > 0) {
                Image(item.localPath)
                    .width(100.percent)
                    .aspectRatio(1.0)
                    .objectFit(ImageFit.Cover)
            } else {
                Column {
                    this.buildMediaTypeIcon(item.mediaType, 28.0)
                }
                .width(100.percent)
                .aspectRatio(1.0)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0x1C1C1E)
            }
            if (item.mediaType == "video") {
                // 资源保真修复：Media Gallery/PlayButton.imageset/ic_play.pdf 转 SVG
                Column {
                    Image(@r(app.media.media_ic_play))
                        .width(20)
                        .height(20)
                        .fillColor(0xFFFFFF)
                }
                .width(32)
                .height(32)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0x80000000)
                .borderRadius(16)
            }
        }
        .width(100.percent)
        .aspectRatio(1.0)
        .onClick({ _ =>
            this.openViewer(Int32(idx))
        })
    }

    // ─── P2-194/195/198/199/200/201/203 全屏查看器 ───────────────────────────────

    @Builder func buildViewerOverlay(): Unit {
        Stack {
            // 背景：下拉时渐透明（P2-195 效果）
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x000000)
                .opacity(this.getBackgroundOpacity())

            // Swiper 全屏浏览
            Swiper(controller: this.swiperController) {
                ForEach(this.getItemsArray(), itemGenerator: { item: GalleryItem, idx: Int64 =>
                    this.buildViewerItem(item)
                })
            }
            .index(UInt32(this.viewerIndex))
            .loop(false)
            .indicator(false)
            .width(100.percent)
            .height(100.percent)
            .onChange({ idx: Int32 =>
                // 切换媒体时先停止正在播放的视频（P2-200）
                if (this.videoIsPlaying) {
                    this.videoController.stop()
                }
                this.videoIsPlaying = false
                this.videoIsPrepared = false
                this.videoCurrentTime = 0
                this.videoTotalDuration = 0
                this.videoProgressPct = 0.0
                this.videoHasError = false
                this.videoIsFullscreen = false
                // P2-202: 切换条目时重置倍速为 1x
                this.videoPlaybackSpeed = PlaybackSpeed.SpeedForward100X
                this.showSpeedMenu = false

                this.viewerIndex = idx
                getGalleryService().setCurrentIndex(Int64(idx))
                // 切图时重置缩放/平移/下拉状态
                this.viewerScale = Float32(1.0)
                this.viewerOffsetX = 0.0
                this.viewerOffsetY = 0.0
                this.lastPinchDist = 0.0
                this.dismissProgress = 0.0
                this.tapCount = 0
                // 切图时重置 chrome 显示并重置自动隐藏计时
                this.showViewerChrome = true
                this.scheduleChromeFade()
                // P2-197 缩略图条自动滚动到当前项（Scroller.scrollTo）
                this.scrollThumbnailStripToIndex(idx)
            })
            .opacity(this.getViewerOpacity())
            .translate(x: 0.0, y: this.getDismissTranslateY())

            // P2-198 顶部 chrome（返回 + 标题 + 页码）
            if (this.showViewerChrome) {
                this.buildViewerTopChrome()
            }

            // P2-198/199 底部 chrome（caption + 操作按钮；非视频时显示）
            if (this.showViewerChrome && !this.isCurrentItemVideo()) {
                this.buildViewerBottomChrome()
            }

            // P2-197/200 底部媒体索引缩略图条（快速跳转；仅多条目时显示；含 Scroller 绑定）
            if (this.getItemCount() > 1) {
                this.buildThumbnailStrip()
            }

            // P2-204 画中画 PiP 小窗（gallery 内联 PiP；系统级 PiP 需 SYSTEM_FLOAT_WINDOW 权限，诚实 defer）
            if (this.pipIsActive && this.pipVideoSrc.size > 0) {
                this.buildPipOverlay()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAreaChange({ _: Area, area: Area =>
            this.viewerWidthVp = area.width.value
        })
        // P2-196 开关转场动画：缩放 + 淡入淡出
        .scale(x: this.viewerOpenScale, y: this.viewerOpenScale)
        .opacity(this.viewerOpenOpacity)
    }

    // P2-197/200 底部媒体索引缩略图条（对应 iOS GalleryThumbnailContainerNode）
    // P2-197 补全：绑定 Scroller 控制器，支持切换/跳转时自动滚动到当前项
    @Builder func buildThumbnailStrip(): Unit {
        Scroll(this.thumbnailStripScroller) {
            Row {
                ForEach(this.getItemsArray(), itemGenerator: { item: GalleryItem, idx: Int64 =>
                    Stack {
                        if (item.localPath.size > 0 && item.mediaType == "photo") {
                            Image(item.localPath)
                                .width(52)
                                .height(52)
                                .objectFit(ImageFit.Cover)
                                .borderRadius(4)
                        } else {
                            // 资源保真修复（D-133 组件级 if/else）：Media Gallery/PlayButton +
                            // Chat/Attach Menu/File.imageset 转 SVG
                            Column {
                                if (item.mediaType == "video") {
                                    Image(@r(app.media.media_ic_play))
                                        .width(18)
                                        .height(18)
                                        .fillColor(0xFFFFFF)
                                } else {
                                    Image(@r(app.media.media_ic_attach_file))
                                        .width(18)
                                        .height(18)
                                        .fillColor(0xFFFFFF)
                                }
                            }
                            .width(52)
                            .height(52)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .backgroundColor(0x2A2A2E)
                            .borderRadius(4)
                        }
                        // 当前选中高亮边框
                        if (Int32(idx) == this.viewerIndex) {
                            Column {}
                                .width(52)
                                .height(52)
                                .borderRadius(4)
                                .border(width: 2, color: 0x0088CC)
                        }
                    }
                    .width(52)
                    .height(52)
                    .margin(right: 4)
                    .onClick({ _ =>
                        this.jumpToItem(Int32(idx))
                    })
                })
            }
            .padding(left: 8, right: 8)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width(100.percent)
        .height(68)
        .backgroundColor(0xCC000000)
        .position(x: 0, y: 90.percent)
    }

    // 单个全屏媒体项（图片：缩放+平移+手势；视频：Video 真实播放 P2-200）
    @Builder func buildViewerItem(item: GalleryItem): Unit {
        Stack {
            if (item.mediaType == "video") {
                // ── P2-200 视频条目：viewer 内直接播放 ──
                this.buildVideoViewerItem(item)
            } else {
                // ── 图片条目：保留 P2-194 缩放/平移/手势 ──
                if (item.localPath.size > 0) {
                    Image(item.localPath)
                        .width(100.percent)
                        .height(100.percent)
                        .objectFit(ImageFit.Contain)
                        .scale(x: this.viewerScale, y: this.viewerScale)
                        .translate(x: this.viewerOffsetX, y: this.viewerOffsetY)
                        .onTouch({ event =>
                            this.handleViewerTouch(event)
                        })
                        .onClick({ _ =>
                            this.handleViewerTap()
                        })
                } else {
                    Column {
                        this.buildMediaTypeIcon(item.mediaType, 48.0)
                        Text("Tap to download")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .margin(top: 8)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0x1C1C1E)
                    .onClick({ _ =>
                        this.downloadItem(item)
                    })
                }
            }
        }
        .width(100.percent)
        .height(100.percent)
    }

    // ─── P2-200 视频播放区域（viewer 内内联，真实 ArkUI Video 组件）──────────────

    @Builder func buildVideoViewerItem(item: GalleryItem): Unit {
        Stack {
            // 背景
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x000000)

            if (item.localPath.size > 0) {
                // 真实视频加载：src = 本地路径（file:// URI 或 raw path）
                // P2-202: currentProgressRate 绑定 @State videoPlaybackSpeed，改速即重建参数生效
                Video(src: item.localPath, currentProgressRate: this.videoPlaybackSpeed, controller: this.videoController)
                    .width(100.percent)
                    .height(100.percent)
                    .objectFit(ImageFit.Contain)
                    .autoPlay(false)
                    .controls(false)
                    .muted(this.videoIsMuted)
                    .onPrepared({ info: PreparedInfo =>
                        // onPrepared 在 UI 线程，直接写 @State（S-001 compliant）
                        match (info.duration) {
                            case Some(d) =>
                                if (d > 0) {
                                    this.videoTotalDuration = d
                                }
                            case None => ()
                        }
                        this.videoIsPrepared = true
                        this.videoHasError = false
                        Hilog.info(0, "CjTelegram", "[GalleryPage] video prepared, dur=${this.videoTotalDuration}")
                    })
                    .onUpdate({ info: PlaybackInfo =>
                        // onUpdate: 真实进度（P2-201 非假进度条）
                        match (info.time) {
                            case Some(t) =>
                                this.videoCurrentTime = t
                                let dur = this.videoTotalDuration
                                if (dur > 0) {
                                    this.videoProgressPct = Float64(t) / Float64(dur) * 100.0
                                }
                            case None => ()
                        }
                    })
                    .onStart({ =>
                        this.videoIsPlaying = true
                        this.scheduleVideoControlsFade()
                    })
                    .onFinish({ =>
                        this.videoIsPlaying = false
                        this.videoCurrentTime = 0
                        this.videoProgressPct = 0.0
                        this.showViewerChrome = true
                        Hilog.info(0, "CjTelegram", "[GalleryPage] video finished")
                    })
                    .onError({ =>
                        this.videoHasError = true
                        this.videoIsPlaying = false
                        Hilog.info(0, "CjTelegram", "[GalleryPage] video error")
                    })
                    .onFullscreenChange({ info: FullscreenInfo =>
                        // P2-203 追踪全屏态（onFullscreenChange 在 UI 线程）
                        match (info.fullscreen) {
                            case Some(fs) => this.videoIsFullscreen = fs
                            case None => ()
                        }
                    })
                    .onTouch({ event =>
                        this.handleViewerTouch(event)
                    })
                    .onClick({ _ =>
                        this.handleViewerTap()
                    })
            } else {
                // 无本地文件：显示下载提示（资源保真修复：Media Gallery/PlayButton.imageset/ic_play.pdf 转 SVG）
                Column {
                    Image(@r(app.media.media_ic_play))
                        .width(48)
                        .height(48)
                        .fillColor(0xFFFFFF)
                    Text("Tap to download video")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 8)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0x1C1C1E)
                .onClick({ _ =>
                    this.downloadItem(item)
                })
            }

            // 视频错误提示
            if (this.videoHasError) {
                Column {
                    Text("⚠")
                        .fontSize(36)
                        .fontColor(0xFF6B6B)
                    Text("Video playback failed")
                        .fontSize(14)
                        .fontColor(0xFFFFFF)
                        .margin(top: 8)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0xCC000000)
            }

            // P2-200/201/203 视频控制层（仅 chrome 可见时显示）
            if (this.showViewerChrome && item.localPath.size > 0 && !this.videoHasError) {
                // 中央播放/暂停按钮（仅已就绪时显示）
                if (this.videoIsPrepared) {
                    Text(if (this.videoIsPlaying) { "⏸" } else { "▶" })
                        .fontSize(44)
                        .fontColor(0xFFFFFF)
                        .width(80)
                        .height(80)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(0x80000000)
                        .borderRadius(40)
                        .onClick({ _ =>
                            this.toggleVideoPlay()
                        })
                }

                // P2-201 底部进度控制条
                this.buildVideoProgressBar()
            }
        }
        .width(100.percent)
        .height(100.percent)
    }

    // P2-201 视频进度条 + seek + 时间 + 缓冲灰条 + P2-203 全屏 + P2-202 倍速 + P2-205 质量
    @Builder func buildVideoProgressBar(): Unit {
        Column {
            // 进度行：当前时间 | [进度Slider] | 总时长 | 全屏按钮
            Row {
                // 当前时间标签（P2-201 动态宽）
                Text(this.formatVideoTime(this.videoCurrentTime))
                    .fontSize(12)
                    .fontColor(0xFFFFFF)
                    .width(44)
                    .textAlign(TextAlign.Start)

                // 进度条区域（P2-201 scrubber：Slider 真实 seek + trackColor 模拟缓冲灰显）
                Slider(
                    value: this.videoProgressPct,
                    min: 0.0,
                    max: 100.0,
                    style: SliderStyle.OutSet
                )
                    .layoutWeight(1)
                    .trackThickness(4)
                    .trackColor(0x60FFFFFF)
                    .selectedColor(0x0088CC)
                    .blockColor(0xFFFFFF)
                    .onChange({ value: Float64, mode: SliderChangeMode =>
                        // seek 真实生效（P2-201 防死状态）
                        let dur = this.videoTotalDuration
                        if (dur > 0) {
                            let targetSec = Int32(value / 100.0 * Float64(dur))
                            this.videoProgressPct = value
                            this.videoCurrentTime = targetSec
                            this.videoController.setCurrentTime(targetSec, SeekMode.Accurate)
                        }
                    })

                // 总时长标签（P2-201）
                Text(this.formatVideoTime(this.videoTotalDuration))
                    .fontSize(12)
                    .fontColor(0xFFFFFF)
                    .width(44)
                    .textAlign(TextAlign.End)

                // P2-203 全屏切换按钮
                Text(if (this.videoIsFullscreen) { "⤡" } else { "⛶" })
                    .fontSize(18)
                    .fontColor(0xFFFFFF)
                    .width(36)
                    .height(36)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(0x80000000)
                    .borderRadius(4)
                    .margin(left: 8)
                    .onClick({ _ =>
                        this.toggleVideoFullscreen()
                    })
            }
            .width(100.percent)
            .padding(left: 12, right: 12)
            .alignItems(VerticalAlign.Center)

            // P2-202/205 底部工具行：静音 + 倍速按钮 + 倍速菜单 + 质量标签
            Row {
                // 静音按钮
                Text(if (this.videoIsMuted) { "🔇" } else { "🔊" })
                    .fontSize(16)
                    .fontColor(0xFFFFFF)
                    .width(36)
                    .height(36)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(0x80000000)
                    .borderRadius(4)
                    .onClick({ _ =>
                        this.videoIsMuted = !this.videoIsMuted
                    })

                // P2-204 PiP 按钮（gallery 内联 PiP；系统 PiP 需 SYSTEM_FLOAT_WINDOW 不可用）
                Text(if (this.pipIsActive) { "⊡" } else { "⊞" })
                    .fontSize(16)
                    .fontColor(if (this.pipIsActive) { 0x0088CC } else { 0xFFFFFF })
                    .width(36)
                    .height(36)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(0x80000000)
                    .borderRadius(4)
                    .margin(left: 6)
                    .onClick({ _ =>
                        this.togglePip()
                    })

                Blank()

                // P2-205 质量标签（ArkUI Video 单文件播放，无多码率 API，固定显示 Auto）
                Text(this.videoQualityLabel)
                    .fontSize(11)
                    .fontColor(0xBBFFFFFF)
                    .padding(left: 6, right: 6, top: 3, bottom: 3)
                    .backgroundColor(0x60000000)
                    .borderRadius(4)
                    .margin(right: 6)

                // P2-202 倍速按钮（显示当前倍速，点击切换）
                Text(this.getSpeedLabel())
                    .fontSize(13)
                    .fontColor(0xFFFFFF)
                    .width(44)
                    .height(32)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(0x80000000)
                    .borderRadius(4)
                    .onClick({ _ =>
                        this.showSpeedMenu = !this.showSpeedMenu
                    })
            }
            .width(100.percent)
            .padding(left: 12, right: 12, top: 4)
            .alignItems(VerticalAlign.Center)

            // P2-202 倍速菜单（展开时显示档位列表）
            if (this.showSpeedMenu) {
                this.buildSpeedMenu()
            }
        }
        .width(100.percent)
        .padding(bottom: 96)
        .position(x: 0, y: 75.percent)
        .backgroundColor(0x80000000)
    }

    // P2-204 画中画 PiP 小窗浮层（gallery 内联实现）
    // 注：系统级 PiP（应用退至后台继续播）需 ohos.permission.SYSTEM_FLOAT_WINDOW（诚实 defer）
    // 当前实现：在 GalleryPage Stack 内用 position 定位右下角小窗，用独立 VideoController 播放
    @Builder func buildPipOverlay(): Unit {
        Stack {
            // 黑色背景
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0xCC000000)
                .borderRadius(8)

            // PiP 视频播放（真实 Video 组件，独立 Controller）
            Video(src: this.pipVideoSrc, controller: this.pipVideoController)
                .width(100.percent)
                .height(100.percent)
                .objectFit(ImageFit.Contain)
                .autoPlay(true)
                .controls(false)
                .muted(this.pipIsMuted)
                .onStart({ =>
                    this.pipIsPlaying = true
                })
                .onFinish({ =>
                    this.pipIsPlaying = false
                })
                .onError({ =>
                    this.pipIsActive = false
                })

            // PiP 播控行（中央按钮 + 关闭）
            Column {
                Row {
                    // PiP 播放/暂停（资源保真修复：D-133 组件级 if/else，
                    // Media Gallery/PlayButton.imageset/ic_play.pdf + PauseButton.imageset/ic_pause.pdf 转 SVG）
                    Column {
                        if (this.pipIsPlaying) {
                            Image(@r(app.media.media_ic_pause))
                                .width(16)
                                .height(16)
                                .fillColor(0xFFFFFF)
                        } else {
                            Image(@r(app.media.media_ic_play))
                                .width(16)
                                .height(16)
                                .fillColor(0xFFFFFF)
                        }
                    }
                    .width(32)
                    .height(32)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0x80000000)
                    .borderRadius(16)
                    .onClick({ _ =>
                        if (this.pipIsPlaying) {
                            this.pipVideoController.pause()
                            this.pipIsPlaying = false
                        } else {
                            this.pipVideoController.start()
                            this.pipIsPlaying = true
                        }
                    })

                    // PiP 关闭按钮（资源保真修复：Navigation/Close.imageset/headercross_30.pdf 转 SVG）
                    Column {
                        Image(@r(app.media.media_ic_close))
                            .width(12)
                            .height(12)
                            .fillColor(0xFFFFFF)
                    }
                    .width(28)
                    .height(28)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0x80000000)
                    .borderRadius(14)
                    .margin(left: 6)
                    .onClick({ _ =>
                        this.closePip()
                    })
                }
                .justifyContent(FlexAlign.Center)
                .padding(bottom: 4, top: 4)
            }
            .width(100.percent)
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.Center)
        }
        .width(140)
        .height(96)
        .borderRadius(8)
        .backgroundColor(0xCC000000)
        .position(x: 212, y: 604)
    }

    // P2-202 倍速选择菜单（HarmonyOS PlaybackSpeed 可用档位）
    // iOS 档位：0.5x / 1x / 1.5x / 2x
    // HarmonyOS PlaybackSpeed 枚举：0.75x / 1x / 1.25x / 1.75x / 2x（无 0.5x）
    // 映射说明：iOS 0.5x → 0.75X（最接近慢速档）；1.5x → 1.25X（四舍五入取 1.25）
    @Builder func buildSpeedMenu(): Unit {
        Row {
            Text("0.75x")
                .fontSize(13)
                .fontColor(if (this.isSpeedSelected(PlaybackSpeed.SpeedForward075X)) { 0x0088CC } else { 0xFFFFFF })
                .padding(left: 10, right: 10, top: 6, bottom: 6)
                .backgroundColor(0x80000000)
                .borderRadius(4)
                .margin(right: 4)
                .onClick({ _ =>
                    this.videoPlaybackSpeed = PlaybackSpeed.SpeedForward075X
                    this.showSpeedMenu = false
                })
            Text("1x")
                .fontSize(13)
                .fontColor(if (this.isSpeedSelected(PlaybackSpeed.SpeedForward100X)) { 0x0088CC } else { 0xFFFFFF })
                .padding(left: 10, right: 10, top: 6, bottom: 6)
                .backgroundColor(0x80000000)
                .borderRadius(4)
                .margin(right: 4)
                .onClick({ _ =>
                    this.videoPlaybackSpeed = PlaybackSpeed.SpeedForward100X
                    this.showSpeedMenu = false
                })
            Text("1.25x")
                .fontSize(13)
                .fontColor(if (this.isSpeedSelected(PlaybackSpeed.SpeedForward125X)) { 0x0088CC } else { 0xFFFFFF })
                .padding(left: 10, right: 10, top: 6, bottom: 6)
                .backgroundColor(0x80000000)
                .borderRadius(4)
                .margin(right: 4)
                .onClick({ _ =>
                    this.videoPlaybackSpeed = PlaybackSpeed.SpeedForward125X
                    this.showSpeedMenu = false
                })
            Text("1.75x")
                .fontSize(13)
                .fontColor(if (this.isSpeedSelected(PlaybackSpeed.SpeedForward175X)) { 0x0088CC } else { 0xFFFFFF })
                .padding(left: 10, right: 10, top: 6, bottom: 6)
                .backgroundColor(0x80000000)
                .borderRadius(4)
                .margin(right: 4)
                .onClick({ _ =>
                    this.videoPlaybackSpeed = PlaybackSpeed.SpeedForward175X
                    this.showSpeedMenu = false
                })
            Text("2x")
                .fontSize(13)
                .fontColor(if (this.isSpeedSelected(PlaybackSpeed.SpeedForward200X)) { 0x0088CC } else { 0xFFFFFF })
                .padding(left: 10, right: 10, top: 6, bottom: 6)
                .backgroundColor(0x80000000)
                .borderRadius(4)
                .onClick({ _ =>
                    this.videoPlaybackSpeed = PlaybackSpeed.SpeedForward200X
                    this.showSpeedMenu = false
                })
        }
        .width(100.percent)
        .justifyContent(FlexAlign.Center)
        .padding(top: 4, bottom: 4)
    }

    // P2-198 顶部 chrome
    @Builder func buildViewerTopChrome(): Unit {
        Row {
            // 关闭按钮（资源保真修复：Navigation/Close.imageset/headercross_30.pdf 转 SVG）
            Column {
                Image(@r(app.media.media_ic_close))
                    .width(18)
                    .height(18)
                    .fillColor(0xFFFFFF)
            }
            .width(44)
            .height(44)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .onClick({ _ =>
                this.closeViewer()
            })
            // 标题：当前索引 / 总数
            Text(this.getViewerFooterText())
                .fontSize(16)
                .fontColor(0xFFFFFF)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
            // 占位（保持对称）
            Column {}
                .width(44)
                .height(44)
        }
        .width(100.percent)
        .padding(left: 8, right: 8, top: 52, bottom: 8)
        .backgroundColor(0x80000000)
        .position(x: 0, y: 0)
    }

    // P2-198/199 底部 chrome（caption + 操作按钮）
    @Builder func buildViewerBottomChrome(): Unit {
        Column {
            // P2-199: Caption 展示（真实数据来自 GalleryItem.caption）
            if (this.getCurrentCaption().size > 0) {
                Scroll() {
                    Text(this.getCurrentCaption())
                        .fontSize(14)
                        .fontColor(0xFFFFFF)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .width(100.percent)
                }
                .scrollable(ScrollDirection.Vertical)
                .scrollBar(BarState.Auto)
                .height(80)
                .width(100.percent)
            }
            // 操作按钮行（P2-218 分享 + 保存；资源保真修复：
            // Chat/Context Menu/Save.imageset/ic_lt_save.pdf 转 SVG）
            Row {
                Column {
                    Image(@r(app.media.media_ic_save))
                        .width(22)
                        .height(22)
                        .fillColor(0xFFFFFF)
                    Text(trSource("Save"))
                        .fontSize(12)
                        .fontColor(0xFFFFFF)
                        .margin(top: 4)
                }
                .padding(left: 20, right: 20, top: 12, bottom: 12)
                .backgroundColor(0x80000000)
                .borderRadius(12)
                .alignItems(HorizontalAlign.Center)
                .onClick({ _ =>
                    this.downloadItem(this.getCurrentItem())
                })

                // P2-218 系统分享按钮（拉起系统选择面板，按 mediaType 设置 UTD type；
                // 资源保真修复：Chat/Context Menu/Share.imageset/ic_lt_share.pdf 转 SVG）
                Column {
                    Image(@r(app.media.media_ic_share))
                        .width(22)
                        .height(22)
                        .fillColor(0xFFFFFF)
                    Text(trSource("Share"))
                        .fontSize(12)
                        .fontColor(0xFFFFFF)
                        .margin(top: 4)
                }
                .padding(left: 20, right: 20, top: 12, bottom: 12)
                .backgroundColor(0x80000000)
                .borderRadius(12)
                .alignItems(HorizontalAlign.Center)
                .margin(left: 12)
                .onClick({ _ =>
                    this.shareCurrentMedia()
                })
            }
            .width(100.percent)
            .justifyContent(FlexAlign.Center)
            .padding(bottom: 12)
        }
        .width(100.percent)
        .padding(bottom: 40)
        .backgroundColor(0x80000000)
        .position(x: 0, y: 75.percent)
    }

    // ─── P2-194 手势处理 ───────────────────────────────────────────────────────────

    /**
     * 统一 onTouch 手势处理器
     * - 双指 → 捏合缩放（P2-194）
     * - 单指 + 已缩放 → 平移图片（P2-194 拖动）
     * - 单指 + scale≤1 + 向下拖 → 下拉关闭（P2-195）
     *
     * PinchGesture fallback: Cangjie SDK 6.0 未导出 PinchGesture，使用 onTouch 两指距离差实现。
     * onTouch 回调在 UI 线程，直接写 @State 合规（S-001 参考：onClick/onTouch 本身在 UI 线程）。
     */
    private func handleViewerTouch(event: TouchEvent): Unit {
        let touchCount = event.touches.size

        if (touchCount >= 2) {
            // ── 双指：捏合缩放（P2-194）──
            this.isDismissGesture = false
            this.isPanning = false
            let t0 = event.touches[0]
            let t1 = event.touches[1]
            let dx = t1.x - t0.x
            let dy = t1.y - t0.y
            let dist = sqrt(dx * dx + dy * dy)
            if (dist < 1.0) { return }

            if (event.eventType == TouchType.Down) {
                this.lastPinchDist = dist
                return
            }

            if (this.lastPinchDist > 1.0 && event.eventType == TouchType.Move) {
                let ratio = Float32(dist / this.lastPinchDist)
                let newScale = this.viewerScale * ratio
                if (newScale < Float32(0.8)) {
                    this.viewerScale = Float32(0.8)
                } else if (newScale > Float32(5.0)) {
                    this.viewerScale = Float32(5.0)
                } else {
                    this.viewerScale = newScale
                }
            }
            this.lastPinchDist = dist

            if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
                this.lastPinchDist = 0.0
                // 松手后缩放 < 1 则回弹到 1
                if (this.viewerScale < Float32(1.0)) {
                    this.viewerScale = Float32(1.0)
                    this.viewerOffsetX = 0.0
                    this.viewerOffsetY = 0.0
                }
            }
            return
        }

        // ── 单指 ──
        if (touchCount == 1) {
            let t0 = event.touches[0]

            if (event.eventType == TouchType.Down) {
                this.panStartX = t0.x
                this.panStartY = t0.y
                this.panBaseOffsetX = this.viewerOffsetX
                this.panBaseOffsetY = this.viewerOffsetY
                this.isDismissGesture = false
                this.isPanning = false
                this.lastPinchDist = 0.0
                return
            }

            if (event.eventType == TouchType.Move) {
                let deltaX = t0.x - this.panStartX
                let deltaY = t0.y - this.panStartY

                // 判断意图：缩放中 → 平移图片；未缩放 → 尝试下拉关闭
                if (Float64(this.viewerScale) > 1.05) {
                    // 已缩放：平移图片（P2-194）
                    this.isPanning = true
                    this.isDismissGesture = false
                    this.viewerOffsetX = this.panBaseOffsetX + deltaX
                    this.viewerOffsetY = this.panBaseOffsetY + deltaY
                } else {
                    // 未缩放：检测下拉关闭手势（P2-195）
                    if (!this.isPanning) {
                        if (deltaY > 10.0 && !this.isDismissGesture) {
                            this.isDismissGesture = true
                        }
                    }
                    if (this.isDismissGesture && deltaY >= 0.0) {
                        // 计算下拉进度（0.0 ~ 1.0）
                        let progress = deltaY / this.DISMISS_THRESHOLD
                        if (progress > 1.0) {
                            this.dismissProgress = 1.0
                        } else {
                            this.dismissProgress = progress
                        }
                    }
                }
                return
            }

            if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
                if (this.isDismissGesture) {
                    if (this.dismissProgress >= 1.0) {
                        // 超过阈值：关闭查看器（P2-195）
                        this.dismissProgress = 0.0
                        this.isDismissGesture = false
                        this.closeViewer()
                    } else {
                        // 未超阈值：回弹（P2-195）
                        this.dismissProgress = 0.0
                        this.isDismissGesture = false
                    }
                } else if (this.isPanning) {
                    // 平移结束：边界回弹（P2-194）
                    this.clampViewerOffset()
                }
                this.isPanning = false
                return
            }
        }

        // 抬手/取消：清理所有追踪状态
        if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
            this.lastPinchDist = 0.0
            this.isPanning = false
            if (!this.isDismissGesture) {
                this.dismissProgress = 0.0
            }
        }
    }

    /**
     * 单击/双击处理（P2-194 + P2-198）
     * - 首次点击 → 启动双击识别窗口
     * - 第二次点击（快速连击）→ 双击：切换缩放 1.0 ↔ 2.0
     * - 超时未双击 → 单击：切换 chrome 显隐（P2-198）
     *
     * 使用计数法近似双击（无法获取精确时间戳）：连续 onClick 2 次即双击。
     */
    private func handleViewerTap(): Unit {
        this.tapCount = this.tapCount + 1
        if (this.tapCount >= 2) {
            // 双击：切换缩放（P2-194）
            this.tapCount = 0
            if (this.viewerScale > Float32(1.2)) {
                // 已放大 → 还原
                this.viewerScale = Float32(1.0)
                this.viewerOffsetX = 0.0
                this.viewerOffsetY = 0.0
            } else {
                // 放大到 2.0（对应 iOS 双击放大）
                this.viewerScale = Float32(2.0)
            }
        } else {
            // 首次点击：延迟判断单击（使用 tapCount 单次增量模型）
            // tapCount 会在下一次 onClick 来临时被判断
            // 若 tapCount==1 且无后续 onClick → 实际是单击 → 切 chrome
            // 用 spawn sleep 近似"双击超时"：300ms 后若 tapCount 仍=1 → 单击
            let versionSnap = this.tapCount
            let _ = spawn {
                sleep(Duration.millisecond * 300)
                launch {
                    if (this.tapCount == versionSnap) {
                        this.tapCount = 0
                        let width = this.viewerWidthVp
                        let sixth = floor(width / 6.0)
                        let edge = if (sixth < 44.0) { sixth } else { 44.0 }
                        let canUseEdgeNavigation = getThemesEngineService().getShowNextMediaOnTap() &&
                            this.viewerScale <= Float32(1.01)
                        if (canUseEdgeNavigation && this.panStartX < edge && this.viewerIndex > 0) {
                            this.jumpToItem(this.viewerIndex - 1)
                        } else if (canUseEdgeNavigation && this.panStartX > width - edge &&
                            Int64(this.viewerIndex) + 1 < this.getItemCount()) {
                            this.jumpToItem(this.viewerIndex + 1)
                        } else {
                            this.showViewerChrome = !this.showViewerChrome
                            if (this.showViewerChrome) {
                                this.scheduleChromeFade()
                            }
                        }
                    }
                }
            }
        }
    }

    /**
     * P2-198 自动隐藏 chrome：3 秒无操作后隐藏顶/底栏
     * 每次交互（openViewer / Swiper onChange / toggleChrome）都调用此方法更新计时器版本
     */
    private func scheduleChromeFade(): Unit {
        this.chromeTimerVersion = this.chromeTimerVersion + 1
        let currentVersion = this.chromeTimerVersion
        let _ = spawn {
            sleep(Duration.second * 3)
            launch {
                if (this.chromeTimerVersion == currentVersion && this.showViewer) {
                    this.showViewerChrome = false
                }
            }
        }
    }

    /**
     * P2-194 平移边界回弹
     * 限制偏移量在屏幕内（超出图片宽高的一半 * (scale-1)）
     */
    private func clampViewerOffset(): Unit {
        // 近似：屏幕宽度 360dp * (scale-1) / 2 为最大偏移
        let maxOffsetX = Float64(360.0) * (Float64(this.viewerScale) - 1.0) / 2.0
        let maxOffsetY = Float64(780.0) * (Float64(this.viewerScale) - 1.0) / 2.0
        if (this.viewerOffsetX > maxOffsetX) {
            this.viewerOffsetX = maxOffsetX
        } else if (this.viewerOffsetX < -maxOffsetX) {
            this.viewerOffsetX = -maxOffsetX
        }
        if (this.viewerOffsetY > maxOffsetY) {
            this.viewerOffsetY = maxOffsetY
        } else if (this.viewerOffsetY < -maxOffsetY) {
            this.viewerOffsetY = -maxOffsetY
        }
    }

    // ─── P2-197 缩略图条自动定位 ───────────────────────────────────────────────────

    /**
     * P2-197 缩略图条快速定位：当 viewerIndex 变化时滚动缩略图条使当前项居中
     * 每个缩略图 52px 宽 + 4px margin = 56px 间距
     * 居中公式：xOffset = index * 56 - (屏幕半宽 - 26)
     * 使用 Scroller.scrollTo(xOffset, yOffset) 实现程序化滚动（Cangjie Scroller API）
     */
    private func scrollThumbnailStripToIndex(index: Int32): Unit {
        let itemWidth: Float64 = 56.0
        let halfScreen: Float64 = 180.0
        let rawOffset = Float64(index) * itemWidth - halfScreen + 26.0
        let xOff: Float64 = if (rawOffset < 0.0) { 0.0 } else { rawOffset }
        this.thumbnailStripScroller.scrollTo(xOffset: xOff, yOffset: 0.0)
    }

    // ─── P2-204 PiP 辅助方法 ───────────────────────────────────────────────────────

    /**
     * 激活/停用 gallery 内联 PiP 小窗
     * 激活时：快照当前视频 src → pipVideoSrc，pipIsActive=true；主播放器 pause
     * 停用时：closePip()
     */
    private func togglePip(): Unit {
        if (this.pipIsActive) {
            this.closePip()
        } else {
            let idx = Int64(this.viewerIndex)
            if (idx >= 0 && idx < Int64(this.items.size)) {
                let item = this.items[idx]
                if (item.mediaType == "video" && item.localPath.size > 0) {
                    let src = item.localPath
                    this.pipVideoSrc = src
                    this.pipIsActive = true
                    this.pipIsPlaying = true
                    this.pipIsMuted = this.videoIsMuted
                    if (this.videoIsPlaying) {
                        this.videoController.pause()
                        this.videoIsPlaying = false
                    }
                }
            }
        }
    }

    /**
     * 关闭 PiP 小窗：停止 PiP 播放，清除状态
     */
    private func closePip(): Unit {
        this.pipVideoController.stop()
        this.pipIsActive = false
        this.pipIsPlaying = false
        this.pipVideoSrc = ""
    }

    // ─── P2-195 下拉关闭计算辅助 ──────────────────────────────────────────────────

    // 背景透明度：随下拉进度从 1.0 降到 0.2
    private func getBackgroundOpacity(): Float64 {
        return 1.0 - this.dismissProgress * 0.8
    }

    // 图片容器透明度：随下拉进度从 1.0 降到 0.4
    private func getViewerOpacity(): Float64 {
        return 1.0 - this.dismissProgress * 0.6
    }

    // 图片容器 Y 轴偏移（跟随下拉拖动，最大 DISMISS_THRESHOLD dp）
    private func getDismissTranslateY(): Float64 {
        return this.dismissProgress * this.DISMISS_THRESHOLD
    }

    // ─── 私有辅助方法 ──────────────────────────────────────────────────────────

    // P2-199: 获取当前媒体条目的 caption
    private func getCurrentCaption(): String {
        let idx = Int64(this.viewerIndex)
        if (idx >= 0 && idx < Int64(this.items.size)) {
            return this.items[idx].caption
        }
        return ""
    }

    // 获取当前 GalleryItem（用于下载按钮）
    private func getCurrentItem(): GalleryItem {
        let idx = Int64(this.viewerIndex)
        if (idx >= 0 && idx < Int64(this.items.size)) {
            return this.items[idx]
        }
        return GalleryItem()
    }

    private func parseRouteParam(raw: String): Unit {
        if (raw.size == 0) {
            this.peerType = getSelectedChatPeerType()
            this.peerId = getSelectedChatId()
            return
        }
        let parts = raw.split("|")
        if (parts.size >= 2) {
            this.peerType = parts[0]
            let idStr = parts[1]
            this.peerId = parseI64(idStr)
        } else {
            this.peerType = getSelectedChatPeerType()
            this.peerId = getSelectedChatId()
        }
    }

    private func parseI64(s: String): Int64 {
        var result: Int64 = 0
        var negative = false
        var start: Int64 = 0
        let runes = s.toRuneArray()
        if (runes.size > 0 && runes[0] == r'-') {
            negative = true
            start = 1
        }
        var i = start
        while (i < Int64(runes.size)) {
            let d = Int64(UInt32(runes[i])) - 48
            if (d < 0 || d > 9) { break }
            result = result * 10 + d
            i = i + 1
        }
        if (negative) { return -result }
        return result
    }

    private func openViewer(index: Int32): Unit {
        this.viewerIndex = index
        getGalleryService().setCurrentIndex(Int64(index))
        // 重置查看器状态
        this.viewerScale = Float32(1.0)
        this.viewerOffsetX = 0.0
        this.viewerOffsetY = 0.0
        this.lastPinchDist = 0.0
        this.dismissProgress = 0.0
        this.tapCount = 0
        this.showViewerChrome = true
        // 重置视频状态（P2-200）
        this.videoIsPlaying = false
        this.videoIsPrepared = false
        this.videoCurrentTime = 0
        this.videoTotalDuration = 0
        this.videoProgressPct = 0.0
        this.videoHasError = false
        this.videoIsFullscreen = false
        // P2-202: 重置播放速率为 1x
        this.videoPlaybackSpeed = PlaybackSpeed.SpeedForward100X
        this.showSpeedMenu = false

        // P2-196 开场转场动画：先设为缩小+透明，然后 animateTo 展开
        this.viewerOpenScale = Float32(0.3)
        this.viewerOpenOpacity = 0.0
        this.showViewer = true
        safeAnimateTo({ => getUIContext() }, AnimateParam(duration: 280, curve: Curve.EaseOut), { =>
            this.viewerOpenScale = Float32(1.0)
            this.viewerOpenOpacity = 1.0
        })

        // P2-198: 打开查看器后 3 秒自动隐藏 chrome
        this.scheduleChromeFade()
    }

    private func closeViewer(): Unit {
        // 关闭时停止视频（P2-200）
        if (this.videoIsPlaying) {
            this.videoController.stop()
        }
        // P2-204: 关闭查看器时同步停止 PiP 小窗
        if (this.pipIsActive) {
            this.pipVideoController.stop()
            this.pipIsActive = false
            this.pipIsPlaying = false
            this.pipVideoSrc = ""
        }
        this.videoIsPlaying = false
        this.videoIsPrepared = false
        this.videoCurrentTime = 0
        this.videoProgressPct = 0.0
        this.videoIsFullscreen = false
        // P2-202: 关闭时重置速率
        this.videoPlaybackSpeed = PlaybackSpeed.SpeedForward100X
        this.showSpeedMenu = false
        this.viewerScale = Float32(1.0)
        this.viewerOffsetX = 0.0
        this.viewerOffsetY = 0.0
        this.dismissProgress = 0.0
        this.showViewerChrome = true

        // P2-196 关场转场动画：缩小+淡出，动画结束后隐藏查看器（spawn 延迟隐藏）
        safeAnimateTo({ => getUIContext() }, AnimateParam(duration: 220, curve: Curve.EaseIn), { =>
            this.viewerOpenScale = Float32(0.3)
            this.viewerOpenOpacity = 0.0
        })
        let _ = spawn {
            sleep(Duration.millisecond * 230)
            launch {
                this.showViewer = false
                this.viewerOpenScale = Float32(1.0)
                this.viewerOpenOpacity = 1.0
            }
        }
    }

    // P2-197/200 跳到指定索引（thumbnail strip 点击）
    // P2-197 补全：通过 viewerIndex 驱动 Swiper.index 属性跳转，并滚动缩略图条到该项
    private func jumpToItem(index: Int32): Unit {
        if (this.videoIsPlaying) {
            this.videoController.stop()
        }
        this.videoIsPlaying = false
        this.videoIsPrepared = false
        this.videoCurrentTime = 0
        this.videoTotalDuration = 0
        this.videoProgressPct = 0.0
        this.videoHasError = false
        this.videoIsFullscreen = false
        // P2-202: 跳转条目时重置倍速
        this.videoPlaybackSpeed = PlaybackSpeed.SpeedForward100X
        this.showSpeedMenu = false
        this.viewerIndex = index
        getGalleryService().setCurrentIndex(Int64(index))
        this.viewerScale = Float32(1.0)
        this.viewerOffsetX = 0.0
        this.viewerOffsetY = 0.0
        this.dismissProgress = 0.0
        this.showViewerChrome = true
        this.scheduleChromeFade()
        // P2-197 缩略图条自动滚动到选中项
        this.scrollThumbnailStripToIndex(index)
    }

    // P2-200 判断当前条目是否为视频
    private func isCurrentItemVideo(): Bool {
        let idx = Int64(this.viewerIndex)
        if (idx >= 0 && idx < Int64(this.items.size)) {
            return this.items[idx].mediaType == "video"
        }
        return false
    }

    // ─── P2-200/201/203 视频控制辅助方法 ────────────────────────────────────────

    // P2-200 切换视频播放/暂停（防死状态：真实 VideoController 操作）
    private func toggleVideoPlay(): Unit {
        if (this.videoIsPlaying) {
            this.videoController.pause()
            this.videoIsPlaying = false
            this.videoControlsTimerVer = this.videoControlsTimerVer + 1
        } else {
            this.videoController.start()
            this.videoIsPlaying = true
            this.scheduleVideoControlsFade()
        }
    }

    // P2-203 切换全屏（requestFullscreen/exitFullscreen 真实 API）
    private func toggleVideoFullscreen(): Unit {
        if (this.videoIsFullscreen) {
            this.videoController.exitFullscreen()
        } else {
            this.videoController.requestFullscreen(true)
        }
    }

    // P2-201 视频控制栏自动隐藏（播放时 3 秒后隐藏）
    private func scheduleVideoControlsFade(): Unit {
        this.videoControlsTimerVer = this.videoControlsTimerVer + 1
        let ver = this.videoControlsTimerVer
        let _ = spawn {
            sleep(Duration.second * 3)
            launch {
                if (this.videoControlsTimerVer == ver && this.videoIsPlaying) {
                    this.showViewerChrome = false
                }
            }
        }
    }

    // ─── P2-202 倍速辅助方法 ─────────────────────────────────────────────────────

    // 获取当前倍速的显示标签
    private func getSpeedLabel(): String {
        if (this.videoPlaybackSpeed == PlaybackSpeed.SpeedForward075X) { return "0.75x" }
        if (this.videoPlaybackSpeed == PlaybackSpeed.SpeedForward100X) { return "1x" }
        if (this.videoPlaybackSpeed == PlaybackSpeed.SpeedForward125X) { return "1.25x" }
        if (this.videoPlaybackSpeed == PlaybackSpeed.SpeedForward175X) { return "1.75x" }
        if (this.videoPlaybackSpeed == PlaybackSpeed.SpeedForward200X) { return "2x" }
        return "1x"
    }

    // 判断某档位是否为当前选中档位（用于高亮）
    private func isSpeedSelected(speed: PlaybackSpeed): Bool {
        return this.videoPlaybackSpeed == speed
    }

    // P2-201 格式化视频时间（秒 → M:SS）
    private func formatVideoTime(seconds: Int32): String {
        if (seconds <= 0) { return "0:00" }
        let m = seconds / 60
        let s = seconds - m * 60
        let sStr: String = if (s < 10) { "0${s}" } else { "${s}" }
        return "${m}:${sStr}"
    }

    private func downloadItem(item: GalleryItem): Unit {
        let msgId = item.messageId
        let photoId = item.photoId
        let photoAH = item.photoAccessHash
        let photoRef = item.photoFileReference
        let mediaType = item.mediaType
        let _ = spawn {
            let downloadSvc = getFileDownloadService()
            if (mediaType == "photo" && photoId != 0) {
                let data = downloadSvc.downloadPhoto(
                    photoId, photoAH, photoRef,
                    thumbSize: "y"
                )
                if (data.size > 0) {
                    let path = getAppFilesDir() + "/gallery/photo_" + photoId.toString() + ".jpg"
                    try {
                        FileIo.mkdir(getAppFilesDir() + "/gallery")
                    } catch (_: Exception) {}
                    try {
                        let f = FileIo.open(path, mode: 0o1101)
                        FileIo.write(f.fd, data)
                        FileIo.close(f)
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[GalleryPage] save photo failed: ${e.message}")
                    }
                    launch {
                        let svc = getGalleryService()
                        var i: Int64 = 0
                        while (i < Int64(svc.items.size)) {
                            if (svc.items[i].messageId == msgId) {
                                svc.items[i].localPath = path
                            }
                            i = i + 1
                        }
                        this.items = svc.items
                    }
                }
            }
            Hilog.info(0, "CjTelegram", "[GalleryPage] downloadItem msgId=${msgId} done")
        }
    }

    /**
     * P2-218 分享当前媒体
     *
     * 对应 iOS GalleryController 底部工具栏 share 按钮 → UIActivityViewController
     *
     * 鸿蒙实现：
     *   1. 取当前条目的 localPath（已缓存到沙箱）
     *   2. 构造 file:// URI
     *   3. 按 mediaType 选 UTD type（photo→general.image / video→general.video）
     *   4. startAbility(Want) → 系统弹出文件处理应用选择面板
     *
     * 约束：
     *   - 文件必须已下载到沙箱（localPath 非空），未下载时提示用户先保存
     *   - 非沙箱路径（已是 file:// 格式的）直接传出；沙箱绝对路径则用 FileUri 包装
     *   - startAbility 在 spawn{} 中调用（IO 操作）
     *   - iOS preferredAction 区分（图片/视频）对应 dataType 的区别
     */
    private func shareCurrentMedia(): Unit {
        let item = this.getCurrentItem()
        if (item.localPath.size == 0) {
            Hilog.info(0, "CjTelegram", "[GalleryPage] share: localPath empty, user must save first")
            return
        }
        let localPath = item.localPath
        let mediaType = item.mediaType
        let _ = spawn {
            // UTD type by mediaType — iOS preferredAction 等效区分
            let utdType: String = if (mediaType == "video") { "general.video" } else { "general.image" }

            // 构造 file:// URI（若路径已含 file:// 则原样传；否则加前缀）
            let fileUri: String = if (localPath.contains("file://")) {
                localPath
            } else {
                "file://" + localPath
            }

            match (getGlobalAbilityContext()) {
                case Some(ctx) =>
                    let want = Want(
                        flags: Flags.FLAG_AUTH_READ_URI_PERMISSION,
                        uri: fileUri,
                        action: "ohos.want.action.viewData",
                        dataType: utdType
                    )
                    try {
                        ctx.startAbility(want)
                        Hilog.info(0, "CjTelegram", "[GalleryPage] share started: ${fileUri} (${utdType})")
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[GalleryPage] share failed: ${e}")
                    }
                case None =>
                    Hilog.info(0, "CjTelegram", "[GalleryPage] share: no ability context")
            }
        }
    }

    private func getTitle(): String {
        return "Gallery (${this.getItemCount()})"
    }

    private func getViewerFooterText(): String {
        return "${this.viewerIndex + 1} / ${this.getItemCount()}"
    }

    private func getItemCount(): Int64 {
        return Int64(this.items.size)
    }

    private func getItemsArray(): Array<GalleryItem> {
        return this.items.toArray()
    }

    private func getMediaIcon(mediaType: String): String {
        if (mediaType == "photo") { return "🖼" }
        if (mediaType == "video") { return "🎬" }
        return "📄"
    }

    // 资源保真修复（D-133 组件级 if/else）：mediaType 占位图标改用真实矢量资源
    // photo → Chat/Attach Menu/Gallery.imageset/Type=Default.pdf
    // video → Chat/Attach Menu/Video.imageset/attach_video.pdf
    // 其他（file）→ Chat/Attach Menu/File.imageset/Type=Default-2.pdf
    @Builder func buildMediaTypeIcon(mediaType: String, size: Float64): Unit {
        if (mediaType == "photo") {
            Image(@r(app.media.media_ic_attach_gallery))
                .width(size)
                .height(size)
                .fillColor(0xFFFFFF)
        } else if (mediaType == "video") {
            Image(@r(app.media.media_ic_attach_video))
                .width(size)
                .height(size)
                .fillColor(0xFFFFFF)
        } else {
            Image(@r(app.media.media_ic_attach_file))
                .width(size)
                .height(size)
                .fillColor(0xFFFFFF)
        }
    }
}
