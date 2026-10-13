package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.MediaLibraryKit.*
import ohos.callback_invoke.*
import ohos.business_exception.BusinessException
import ohos_app_cangjie_entry.services.getGlobalAbilityContext
import ohos_app_cangjie_entry.services.getSaveToCameraRollService

/**
 * VideoPlayer — 视频播放器组件（Phase H3 — 使用 ArkUI Video 组件）
 * 
 * 对应 TelegramHarmony VideoPlayer.ets (332 行)
 * 对应 Telegram-iOS UniversalVideoGalleryItem (视频全屏播放)
 * 
 * 功能:
 * - 全屏黑色背景播放视频
 * - 使用 ArkUI Video 组件进行真实视频播放
 * - 播放/暂停控制
 * - 进度滑块
 * - 当前时间 / 总时长显示
 * - 静音切换
 * - 自动隐藏控制栏（播放时 3s 后隐藏）
 * - 关闭按钮
 * - 预览图（缩略图）
 */

/**
 * 视频数据
 */
public class VideoData {
    public var url: String = ""              // 视频文件路径 (file:///...)
    public var width: Int32 = 0
    public var height: Int32 = 0
    public var duration: Int32 = 0           // 秒
    public var thumbnailUrl: String = ""     // 缩略图路径 (file:///...)
    public var caption: String = ""
    
    public init() {}
    
    public init(url!: String, duration!: Int32 = 0, thumbnailUrl!: String = "", caption!: String = "") {
        this.url = url
        this.duration = duration
        this.thumbnailUrl = thumbnailUrl
        this.caption = caption
    }
}

@Component
public class VideoPlayer {
    // 视频数据
    public var video: VideoData = VideoData()
    // 关闭回调
    public var onClose: () -> Unit = { => }
    
    // 播放状态
    @State var isPlaying: Bool = false
    // 当前播放时间（秒）
    @State var currentTime: Int32 = 0
    // 总时长（秒，从 onPrepared 获取或从 video.duration 取）
    @State var totalDuration: Int32 = 0
    // 是否显示控制栏
    @State var showControls: Bool = true
    // 是否已准备好
    @State var isPrepared: Bool = false
    // 是否静音
    @State var isMuted: Bool = false
    // 进度百分比（0-100）
    @State var progressPercent: Float64 = 0.0
    // 是否有错误
    @State var hasError: Bool = false
    // 错误信息
    @State var errorMsg: String = ""
    // 保存到相册状态
    @State var isSaving: Bool = false
    @State var saveResult: String = ""  // "success" / "error: xxx" / ""
    // 控制栏隐藏标志
    private var _controlsHideActive: Bool = false
    // Video 控制器
    private let videoController = VideoController()
    // P2-203 全屏状态（onFullscreenChange 真实回调驱动）
    @State var isFullscreen: Bool = false

    // ─── P2-202 播放速率 ─────────────────────────────────────────────────────────
    // 当前播放倍速（绑定到 Video.currentProgressRate）
    // HarmonyOS PlaybackSpeed: SpeedForward075X / 100X / 125X / 175X / 200X
    @State var playbackSpeed: PlaybackSpeed = PlaybackSpeed.SpeedForward100X
    // 是否显示倍速选择菜单
    @State var showSpeedMenu: Bool = false

    // ─── P2-231 scrubbing 状态 ───────────────────────────────────────────────
    // 是否正在拖动进度条（拖动期间暂停播放，防止 onUpdate 回调覆盖 scrub 位置）
    @State var isScrubbing: Bool = false
    // 拖动开始前是否正在播放（用于松手后恢复）
    private var _wasPlayingBeforeScrub: Bool = false

    // ─── P2-205 视频质量（HarmonyOS ArkUI Video 单 src，无多码率 / HLS 自适应 API）──
    // ArkUI Video 组件不支持多码率切换。质量固定为原始文件质量，仅显示 "Auto" 标签。
    // iOS 对应：UniversalVideoContentVideoQuality.auto / .quality(Int) — 依赖 HLS 后端。
    // 结论：P2-205 质量切换需服务端多版本文件，当前版本诚实 defer，质量显示 "Auto"。
    private let qualityLabel: String = "Auto"

    protected override func aboutToAppear(): Unit {
        this.totalDuration = this.video.duration
        Hilog.info(0, "CjTelegram", "[VideoPlayer] Opening: url=${this.video.url}, thumbnail=${this.video.thumbnailUrl}, duration=${this.video.duration}")
    }
    
    /**
     * 切换控制栏显示
     */
    private func toggleControls(): Unit {
        this.showControls = !this.showControls
        if (this.showControls && this.isPlaying) {
            this.startControlsTimer()
        }
    }
    
    /**
     * 自动隐藏控制栏
     */
    private func startControlsTimer(): Unit {
        this._controlsHideActive = true
        spawn {
            sleep(Duration.second * 3)
            if (this._controlsHideActive && this.isPlaying) {
                launch { this.showControls = false }
            }
        }
    }
    
    /**
     * 播放/暂停切换
     */
    private func togglePlayPause(): Unit {
        if (this.isPlaying) {
            this.videoController.pause()
            this.isPlaying = false
            this._controlsHideActive = false
        } else {
            this.videoController.start()
            this.isPlaying = true
            this.startControlsTimer()
        }
    }
    
    /**
     * 关闭播放器
     */
    // 子树销毁时停止播放（audit P1-3）：此前 stop() 只在 ✕ 触发的 handleClose，
    // 系统返回离开聊天不走 handleClose → 视频音频仍响 + 自动隐藏 worker 悬挂持引用。
    protected override func aboutToDisappear(): Unit {
        this.isPlaying = false
        this._controlsHideActive = false
        try { this.videoController.stop() } catch (_: Exception) {}
    }

    private func handleClose(): Unit {
        this.isPlaying = false
        this._controlsHideActive = false
        // P2-202: 关闭时重置速率
        this.playbackSpeed = PlaybackSpeed.SpeedForward100X
        this.showSpeedMenu = false
        this.videoController.stop()
        this.onClose()
    }
    
    // ─── P2-202 倍速辅助方法 ─────────────────────────────────────────────────────

    /**
     * 获取当前倍速的显示标签
     * HarmonyOS PlaybackSpeed 档位对应 iOS 倍速档位映射
     */
    private func getSpeedLabel(): String {
        if (this.playbackSpeed == PlaybackSpeed.SpeedForward075X) { return "0.75x" }
        if (this.playbackSpeed == PlaybackSpeed.SpeedForward100X) { return "1x" }
        if (this.playbackSpeed == PlaybackSpeed.SpeedForward125X) { return "1.25x" }
        if (this.playbackSpeed == PlaybackSpeed.SpeedForward175X) { return "1.75x" }
        if (this.playbackSpeed == PlaybackSpeed.SpeedForward200X) { return "2x" }
        return "1x"
    }

    /**
     * 判断某档位是否为当前选中档位（用于高亮显示）
     */
    private func isSpeedSelected(speed: PlaybackSpeed): Bool {
        return this.playbackSpeed == speed
    }

    /**
     * 格式化时间（秒 → M:SS）
     */
    private func formatTime(seconds: Int32): String {
        let mins = seconds / 60
        let secs = seconds % 60
        let sStr = if (secs < 10) { "0${secs}" } else { "${secs}" }
        return "${mins}:${sStr}"
    }
    
    /**
     * 获取显示用的总时长
     */
    private func getDisplayDuration(): Int32 {
        if (this.totalDuration > 0) { return this.totalDuration }
        return this.video.duration
    }
    
    /**
     * 获取视频的本地文件路径（去除 file:// 前缀）
     */
    private func getVideoLocalPath(): String {
        let url = this.video.url
        // Video component uses file:// URI, but filesystem APIs need raw path
        let prefix = "file://"
        if (url.startsWith(prefix)) {
            return url[prefix.size..]
        }
        return url
    }
    
    /**
     * 获取保存按钮文本（build 中不能用 let，所以提取为辅助方法）
     */
    private func getSaveButtonText(): String {
        if (this.isSaving) { return "⏳" }
        if (this.saveResult == "success") { return "✅" }
        if (this.saveResult.size > 0) { return "❌" }
        return "💾"
    }
    
    // ─── P2-231 scrubbing 方法 ───────────────────────────────────────────────

    /**
     * P2-231: 开始拖动进度条（Slider Begin）。
     * 暂停播放，记录拖前播放状态。
     * 对应 iOS MediaPlayerScrubbingNode beginScrubbing()。
     */
    private func onScrubbingBegin(): Unit {
        this._wasPlayingBeforeScrub = this.isPlaying
        this.isScrubbing = true
        if (this.isPlaying) {
            this.videoController.pause()
            this.isPlaying = false
            this._controlsHideActive = false
        }
        Hilog.info(0, "CjTelegram", "[VideoPlayer] scrubbing begin wasPlaying=${this._wasPlayingBeforeScrub}")
    }

    /**
     * P2-231: 拖动中（Slider Moving）。
     * 更新进度显示 + 关键帧 seek（ClosestKeyframe，快速跟手）。
     * 缩略图预览（Scrubbing Thumbnail）：
     *   iOS MediaPlayerFramePreview 通过 FFMpeg 实时取指定时间帧图像。
     *   HarmonyOS ArkUI Video 组件不暴露等效逐帧实时取帧接口（AVImageGenerator 为
     *   async batch，不适合高频 scrubbing）。此能力诚实 defer（平台受限）。
     */
    private func onScrubbingUpdate(fraction: Float64): Unit {
        let dur = this.getDisplayDuration()
        if (dur <= 0) {
            return
        }
        let targetTime = Int32(fraction / 100.0 * Float64(dur))
        this.currentTime = targetTime
        this.progressPercent = fraction
        this.videoController.setCurrentTime(targetTime, SeekMode.ClosestKeyframe)
        Hilog.info(0, "CjTelegram", "[VideoPlayer] scrubbing update target=${targetTime}s")
    }

    /**
     * P2-231: 结束拖动（Slider End / Click）。
     * 精确 seek（SeekMode.Accurate），按需恢复播放。
     * 对应 iOS MediaPlayerScrubbingNode endScrubbing()。
     */
    private func onScrubbingEnd(fraction: Float64): Unit {
        let dur = this.getDisplayDuration()
        this.isScrubbing = false
        if (dur <= 0) {
            return
        }
        let targetTime = Int32(fraction / 100.0 * Float64(dur))
        this.currentTime = targetTime
        this.progressPercent = fraction
        this.videoController.setCurrentTime(targetTime, SeekMode.Accurate)
        if (this._wasPlayingBeforeScrub) {
            this.videoController.start()
            this.isPlaying = true
            this.startControlsTimer()
        }
        Hilog.info(0, "CjTelegram",
            "[VideoPlayer] scrubbing end finalSec=${targetTime}s resume=${this._wasPlayingBeforeScrub}")
    }

    /**
     * 保存当前视频到系统相册（权限治理返修，gallery-nopermission 跨 feature 治理）
     *
     * 历史：使用 FileIo 读取全部字节 + MediaAssetChangeRequest.createAssetRequest +
     * addResource(VideoResource) + applyChanges，需要调用者持有
     * ohos.permission.WRITE_IMAGEVIDEO（availableLevel=system_basic，普通 apl:normal
     * 签名档位下 signed HAP 装不上）。
     *
     * 本轮对齐 ImageViewer.cj saveCurrentImage()（TC-0024 rework2）与
     * SaveToCameraRollService.cj 已验证先例，改为 photoAccessHelper.showAssetsCreationDialog
     * （cangjie-kb doc_id cjlang_ohos_..._cj-apis-file-photo_access_helper，起始版本 22）：
     * 直接对本地沙箱路径 uri 弹系统保存确认弹窗，免读字节、免 WRITE_IMAGEVIDEO 权限。
     */
    private func saveVideoToGallery(): Unit {
        if (this.isSaving) { return }

        let path = this.getVideoLocalPath()
        if (path.isEmpty()) {
            this.saveResult = "error: No video file"
            return
        }

        this.isSaving = true
        this.saveResult = ""

        Hilog.info(0, "CjTelegram", "[VideoPlayer] Saving to gallery via showAssetsCreationDialog: ${path}")

        match (getGlobalAbilityContext()) {
            case None =>
                this.saveResult = "error: No context"
                this.isSaving = false
                Hilog.info(0, "CjTelegram", "[VideoPlayer] Save failed: globalAbilityContext is None")
            case Some(ctx) =>
                // imgmenu 批次真机返修：srcFileUri 必须带 bundleName authority
                // （file://com.hmcangjie.telegram/<path>），空 authority 时媒体库进程
                // 读不到源文件，弹窗不出现且回调立即返回空列表
                // （详见 SaveToCameraRollService.normalizeFileUri 注释；真机 hilog 实证）。
                let uri = videoPlayerShareableUri(path)
                let ext = extractVideoFileExtension(path)
                let config = PhotoCreationConfig(ext, PhotoType.Video)
                let callback = VideoPlayerSaveDialogCallback(this, path)
                try {
                    let phAccessHelper = getPhotoAccessHelper(ctx)
                    phAccessHelper.showAssetsCreationDialog([uri], [config], callback)
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[VideoPlayer] showAssetsCreationDialog BusinessException: ${e.message}")
                    this.saveResult = "error: ${e.message}"
                    this.isSaving = false
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[VideoPlayer] showAssetsCreationDialog Exception: ${e}")
                    this.saveResult = "error: Save failed"
                    this.isSaving = false
                }
        }
    }

    /**
     * showAssetsCreationDialog 的结果回调入口（由 VideoPlayerSaveDialogCallback.invoke 调用）。
     * 非 UI 线程回调，@State 写入须用 launch{} 包裹（S-001）。
     * savedUris 非空 = 用户同意保存；空列表 = 用户拒绝（按取消保存语义处理，不算错误）。
     */
    /**
     * imgmenu 批次真机返修：用户同意后媒体库只创建空资产并返回已授权目标 uri，
     * 视频字节须由调用方写入（同 SaveToCameraRollService.writeFileToUri 注释）。
     */
    func onSaveDialogResult(savedUris: Array<String>, srcPath: String): Unit {
        if (savedUris.size > 0) {
            if (getSaveToCameraRollService().writeFileToUri(srcPath, savedUris[0])) {
                Hilog.info(0, "CjTelegram", "[VideoPlayer] Saved to system gallery: ${savedUris[0]}")
                launch {
                    this.saveResult = "success"
                    this.isSaving = false
                }
            } else {
                Hilog.info(0, "CjTelegram", "[VideoPlayer] save copy-to-uri failed: ${savedUris[0]}")
                launch {
                    this.saveResult = "error: Save failed"
                    this.isSaving = false
                }
            }
        } else {
            Hilog.info(0, "CjTelegram", "[VideoPlayer] showAssetsCreationDialog: user declined or empty result")
            launch {
                this.saveResult = ""
                this.isSaving = false
            }
        }
    }
    
    public func build() {
        Stack {
            // 黑色背景
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x000000)
            
            // ==================== 真实视频播放器 ====================
            if (this.video.url.size > 0) {
                // P2-202: currentProgressRate 绑定 @State playbackSpeed，更改倍速即生效
                Video(src: this.video.url, currentProgressRate: this.playbackSpeed, controller: this.videoController)
                    .width(100.percent)
                    .height(100.percent)
                    .objectFit(ImageFit.Contain)
                    .autoPlay(false)
                    .controls(false)
                    .muted(this.isMuted)
                    .onPrepared({ info: PreparedInfo =>
                        this.isPrepared = true
                        match (info.duration) {
                            case Some(d) =>
                                Hilog.info(0, "CjTelegram", "[VideoPlayer] Prepared, duration=${d}")
                                if (d > 0) { this.totalDuration = d }
                            case None =>
                                Hilog.info(0, "CjTelegram", "[VideoPlayer] Prepared, duration unknown")
                        }
                    })
                    .onFinish({ =>
                        Hilog.info(0, "CjTelegram", "[VideoPlayer] Finished")
                        this.isPlaying = false
                        this.currentTime = 0
                        this.progressPercent = 0.0
                        this.showControls = true
                        this._controlsHideActive = false
                    })
                    .onError({ =>
                        Hilog.info(0, "CjTelegram", "[VideoPlayer] Error playing video")
                        this.hasError = true
                        this.errorMsg = "Failed to play video"
                    })
                    .onFullscreenChange({ info: FullscreenInfo =>
                        // P2-203: 追踪系统全屏状态（onFullscreenChange 在 UI 线程）
                        match (info.fullscreen) {
                            case Some(fs) => this.isFullscreen = fs
                            case None => ()
                        }
                    })
                    // P2-231: scrubbing 期间跳过 onUpdate，防止服务进度回调覆盖 scrub 位置
                    .onUpdate({ info: PlaybackInfo =>
                        if (!this.isScrubbing) {
                            match (info.time) {
                                case Some(t) =>
                                    this.currentTime = t
                                    let dur = this.getDisplayDuration()
                                    if (dur > 0) {
                                        this.progressPercent = Float64(t) / Float64(dur) * 100.0
                                    }
                                case None => ()
                            }
                        }
                    })
                    .onClick({ evt =>
                        this.toggleControls()
                    })
            } else {
                // 无视频 URL — 显示缩略图占位
                if (this.video.thumbnailUrl.size > 0) {
                    Image(this.video.thumbnailUrl)
                        .width(100.percent)
                        .height(100.percent)
                        .objectFit(ImageFit.Contain)
                        .onClick({ evt =>
                            this.toggleControls()
                        })
                } else {
                    Column {
                        Text("🎬")
                            .fontSize(64)
                        Text("No video source")
                            .fontSize(16)
                            .fontColor(0xFFFFFF)
                            .margin(top: 8)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .onClick({ evt =>
                        this.toggleControls()
                    })
                }
            }
            
            // 错误提示
            if (this.hasError) {
                Column {
                    Text("⚠")
                        .fontSize(48)
                    Text(this.errorMsg)
                        .fontSize(14)
                        .fontColor(0xFFFFFF)
                        .margin(top: 8)
                    Text("Tap to close")
                        .fontSize(12)
                        .fontColor(0x999999)
                        .margin(top: 12)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0xCC000000)
                .onClick({ evt =>
                    this.handleClose()
                })
            }
            
            // ==================== 顶部控制栏 ====================
            if (this.showControls) {
                Row {
                    // 关闭按钮
                    Text("✕")
                        .fontSize(20)
                        .fontColor(0xFFFFFF)
                        .width(44)
                        .height(44)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(0x80000000)
                        .borderRadius(22)
                        .onClick({ evt =>
                            this.handleClose()
                        })
                    
                    Blank()
                    
                    // 保存到相册按钮（仅当有视频 URL 时显示）
                    if (this.video.url.size > 0) {
                        Text(this.getSaveButtonText())
                            .fontSize(20)
                            .width(44)
                            .height(44)
                            .textAlign(TextAlign.Center)
                            .backgroundColor(0x80000000)
                            .borderRadius(22)
                            .margin(right: 8)
                            .onClick({ evt =>
                                if (!this.isSaving && this.saveResult != "success") {
                                    this.saveVideoToGallery()
                                }
                            })
                    }
                    
                    // 静音按钮
                    Text(if (this.isMuted) { "🔇" } else { "🔊" })
                        .fontSize(20)
                        .width(44)
                        .height(44)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(0x80000000)
                        .borderRadius(22)
                        .onClick({ evt =>
                            this.isMuted = !this.isMuted
                        })

                    // P2-203 全屏切换按钮
                    Text(if (this.isFullscreen) { "⤡" } else { "⛶" })
                        .fontSize(18)
                        .fontColor(0xFFFFFF)
                        .width(44)
                        .height(44)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(0x80000000)
                        .borderRadius(22)
                        .margin(left: 4)
                        .onClick({ evt =>
                            if (this.isFullscreen) {
                                this.videoController.exitFullscreen()
                            } else {
                                this.videoController.requestFullscreen(true)
                            }
                        })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 52)
                .position(x: 0, y: 0)
            }
            
            // ==================== 中央播放/暂停按钮 ====================
            if (this.showControls && this.isPrepared && !this.hasError) {
                Text(if (this.isPlaying) { "⏸" } else { "▶" })
                    .fontSize(40)
                    .fontColor(0xFFFFFF)
                    .width(80)
                    .height(80)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(0x80000000)
                    .borderRadius(40)
                    .onClick({ evt =>
                        this.togglePlayPause()
                    })
            }
            
            // ==================== 保存结果提示 ====================
            if (this.saveResult == "success") {
                Text("Video saved to gallery")
                    .fontSize(14)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0xCC4CAF50)
                    .padding(left: 16, right: 16, top: 8, bottom: 8)
                    .borderRadius(20)
                    .position(x: 30.percent, y: 45.percent)
            }
            
            // ==================== 底部控制栏 ====================
            if (this.showControls && this.isPrepared && !this.hasError) {
                Column {
                    // 进度条行
                    Row {
                        // 当前时间
                        Text(this.formatTime(this.currentTime))
                            .fontSize(12)
                            .fontColor(0xFFFFFF)
                            .width(50)

                        // P2-231: 三阶段 scrubbing — Begin(暂停) / Moving(ClosestKF跟手) / End(Accurate+恢复)
                        Slider(value: this.progressPercent, min: 0.0, max: 100.0, style: SliderStyle.OutSet)
                            .layoutWeight(1)
                            .trackThickness(4)
                            .selectedColor(0x0088CC)
                            .trackColor(0x60FFFFFF)
                            .blockColor(0xFFFFFF)
                            .onChange({ value: Float64, mode: SliderChangeMode =>
                                if (mode == SliderChangeMode.Begin) {
                                    this.onScrubbingBegin()
                                } else if (mode == SliderChangeMode.Moving) {
                                    this.onScrubbingUpdate(value)
                                } else if (mode == SliderChangeMode.End) {
                                    this.onScrubbingEnd(value)
                                } else {
                                    this.onScrubbingEnd(value)
                                }
                            })

                        // 总时长
                        Text(this.formatTime(this.getDisplayDuration()))
                            .fontSize(12)
                            .fontColor(0xFFFFFF)
                            .width(50)
                            .textAlign(TextAlign.End)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16)

                    // P2-202/205 工具行：质量标签 + 倍速按钮
                    Row {
                        Blank()

                        // P2-205 质量标签（ArkUI Video 单文件，无多码率 API，固定 Auto）
                        Text(this.qualityLabel)
                            .fontSize(11)
                            .fontColor(0xBBFFFFFF)
                            .padding(left: 6, right: 6, top: 3, bottom: 3)
                            .backgroundColor(0x60000000)
                            .borderRadius(4)
                            .margin(right: 6)

                        // P2-202 倍速按钮（点击展开倍速菜单）
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
                    .padding(left: 16, right: 16, top: 4)
                    .alignItems(VerticalAlign.Center)

                    // P2-202 倍速菜单（HarmonyOS PlaybackSpeed 档位）
                    if (this.showSpeedMenu) {
                        Row {
                            Text("0.75x")
                                .fontSize(13)
                                .fontColor(if (this.isSpeedSelected(PlaybackSpeed.SpeedForward075X)) { 0x0088CC } else { 0xFFFFFF })
                                .padding(left: 10, right: 10, top: 6, bottom: 6)
                                .backgroundColor(0x80000000)
                                .borderRadius(4)
                                .margin(right: 4)
                                .onClick({ _ =>
                                    this.playbackSpeed = PlaybackSpeed.SpeedForward075X
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
                                    this.playbackSpeed = PlaybackSpeed.SpeedForward100X
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
                                    this.playbackSpeed = PlaybackSpeed.SpeedForward125X
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
                                    this.playbackSpeed = PlaybackSpeed.SpeedForward175X
                                    this.showSpeedMenu = false
                                })
                            Text("2x")
                                .fontSize(13)
                                .fontColor(if (this.isSpeedSelected(PlaybackSpeed.SpeedForward200X)) { 0x0088CC } else { 0xFFFFFF })
                                .padding(left: 10, right: 10, top: 6, bottom: 6)
                                .backgroundColor(0x80000000)
                                .borderRadius(4)
                                .onClick({ _ =>
                                    this.playbackSpeed = PlaybackSpeed.SpeedForward200X
                                    this.showSpeedMenu = false
                                })
                        }
                        .width(100.percent)
                        .justifyContent(FlexAlign.Center)
                        .padding(top: 4)
                    }

                    // 视频说明
                    if (this.video.caption.size > 0) {
                        Text(this.video.caption)
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                            .maxLines(2)
                            .margin(top: 12)
                            .padding(left: 16, right: 16)
                    }
                }
                .width(100.percent)
                .padding(bottom: 48)
                .position(x: 0, y: 82.percent)
            }
        }
        .width(100.percent)
        .height(100.percent)
    }
}

/**
 * 权限治理返修：showAssetsCreationDialog 结果回调实现。
 * KB Example 101（cj-apis-file-photo_access_helper）：
 *   class MyCallback1<T> <: Callback1Argument<T> { func invoke(err: ?BusinessException, arg: T): Unit }
 * 对齐 ImageViewer.cj ImageViewerSaveDialogCallback 同一惯例。
 */
class VideoPlayerSaveDialogCallback <: Callback1Argument<Array<String>> {
    private var _player: VideoPlayer
    // imgmenu 批次：携带源文件路径，同意后写入目标 uri（见 onSaveDialogResult 注释）
    private var _srcPath: String

    init(player: VideoPlayer, srcPath: String) {
        this._player = player
        this._srcPath = srcPath
    }

    public func invoke(err: ?BusinessException, arg: Array<String>): Unit {
        match (err) {
            case Some(e) =>
                Hilog.info(0, "CjTelegram", "[VideoPlayer] showAssetsCreationDialog callback error: ${e.message}")
                this._player.onSaveDialogResult([], this._srcPath)
            case None =>
                this._player.onSaveDialogResult(arg, this._srcPath)
        }
    }
}

/**
 * 从本地文件路径提取扩展名（不含 "."），供 PhotoCreationConfig.fileNameExtension 使用。
 * R-101: String 无 hasSuffix，用 split(".") 取最后一段代替。
 */
private func extractVideoFileExtension(path: String): String {
    let parts = path.split(".")
    if (parts.size > 1) {
        return parts[parts.size - 1]
    }
    return "mp4"
}

// showAssetsCreationDialog srcFileUri 的 bundleName authority（与 AppScope/app.json5 一致）
private let VIDEO_URI_BUNDLE: String = "com.hmcangjie.telegram"

/**
 * imgmenu：沙箱路径 → 带 bundleName authority 的分享型 file URI
 * （file://<bundle>/<abs-path>；空 authority 的 file:/// 形态一并升级）。
 */
private func videoPlayerShareableUri(path: String): String {
    if (path.startsWith("file://")) {
        let rest = path[7..path.size]
        if (rest.startsWith("/")) {
            return "file://" + VIDEO_URI_BUNDLE + rest
        }
        return path
    }
    if (path.startsWith("/")) {
        return "file://" + VIDEO_URI_BUNDLE + path
    }
    return "file://" + path
}
