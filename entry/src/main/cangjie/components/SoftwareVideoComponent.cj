package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getSoftwareVideoService,
    SoftwareVideoFrame,
    BufferedVideoFrame,
    MediaTrackFrameBuffer,
    FrameBufferStatus,
    FrameTakeResult,
    AnimatedImageFrameSource,
    VideoFileFrameSource,
    VideoPlaybackMode
}

/**
 * SoftwareVideoComponent — 软件视频渲染组件
 *
 * 对应 iOS SoftwareVideoLayerFrameManager（基于 softwareVideoWorkers + softwareVideoApplyQueue）
 * 在鸿蒙上以 ArkUI @Component + MediaTrackFrameBuffer 水位调度 + Timer.once 帧 pacing 实现等价功能。
 *
 * P2-230 新增：MediaTrackFrameBuffer 水位调度（低/高水位阈值驱动帧请求）
 * P2-233 新增：AnimatedImageFrameSource（ImageSource.getFrameCount/getDelayTimeList，真实软解）
 *              Timer.once 回调驱动帧 pacing（非 sleep 忙等）
 * P2-234 新增：VideoFileFrameSource + VideoPlaybackMode（WholeFile/Streamable 抽象）
 *
 * 功能：
 * - 接收本地视频文件路径 + 播放参数
 * - 通过 AnimatedImageFrameSource（GIF/WebP）或 VideoFileFrameSource（视频文件）供帧
 * - 帧缓冲水位调度（stallDuration/lowWaterDuration/highWaterDuration）
 * - Timer.once 回调驱动帧节奏（替代旧 sleep 忙等）
 * - 在 Image 组件中逐帧渲染，实现动画播放
 *
 * 鸿蒙平台降级说明（deferred — 平台缺口）：
 *   Streamable 播放模式（分片流式）需要 FFmpeg 帧级读取，当前鸿蒙无 FFmpeg 绑定，
 *   退化为 WholeFile（AVImageGenerator）路径。
 *   AnimatedGIF/WebP（P2-233）真实可用（ImageSource.getFrameCount + getDelayTimeList）。
 *
 * 规则合规：
 *   S-001：@State 更新均在 launch {} 中（主线程）
 *   S-013：无 @Builder private func
 *   R-107：无 @Builder/build() 内 let/var 声明
 *   D-010：一页一文件
 */

/**
 * 软件视频元数据
 *
 * 对应 iOS SoftwareVideoLayerFrameManager 构建时需要的视频参数。
 */
public class SoftwareVideoData {
    /** 本地视频文件绝对路径（沙箱路径，不含 file:// 前缀） */
    public var localFilePath: String = ""
    /** 视频宽度（像素） */
    public var width: Int32 = 0
    /** 视频高度（像素） */
    public var height: Int32 = 0
    /** 视频总时长（微秒），0 表示未知 */
    public var durationUs: Int64 = 0
    /** 视频帧率（帧/秒），0 表示使用默认 15fps */
    public var fps: Float64 = 0.0
    /** 是否自动循环播放（对应 iOS SoftwareVideo.loop） */
    public var loop: Bool = true
    /**
     * 是否为动图模式（GIF/WebP）。
     * true → 使用 AnimatedImageFrameSource（P2-233，真实软解）
     * false → 使用 VideoFileFrameSource（P2-234，AVImageGenerator 路径）
     */
    public var isAnimatedImage: Bool = false
    /**
     * 播放模式（P2-234 frame-source/chunk 抽象）。
     * WholeFile：文件已完全下载（默认）
     * Streamable：分片流式（FFmpeg deferred，当前退化为 WholeFile）
     */
    public var playbackMode: VideoPlaybackMode = VideoPlaybackMode.WholeFile

    public init() {}

    public init(
        localFilePath!: String,
        width!: Int32 = 0,
        height!: Int32 = 0,
        durationUs!: Int64 = 0,
        fps!: Float64 = 15.0,
        loop!: Bool = true,
        isAnimatedImage!: Bool = false,
        playbackMode!: VideoPlaybackMode = VideoPlaybackMode.WholeFile
    ) {
        this.localFilePath = localFilePath
        this.width = width
        this.height = height
        this.durationUs = durationUs
        this.fps = fps
        this.loop = loop
        this.isAnimatedImage = isAnimatedImage
        this.playbackMode = playbackMode
    }
}

// ─────────────────────────────────────────────────────────────────
// 组件
// ─────────────────────────────────────────────────────────────────

@Component
public class SoftwareVideoComponent {
    /** 视频元数据（外部传入） */
    public var videoData: SoftwareVideoData = SoftwareVideoData()
    /** 播放开始回调 */
    public var onPlaybackStarted: () -> Unit = { => }
    /** 播放结束（一轮完成）回调 */
    public var onPlaybackFinished: () -> Unit = { => }

    /** 帧版本计数器：每次新帧到达自增，驱动 Image 组件刷新 */
    @State var frameVersion: Int64 = 0
    /** 是否有可用的当前帧 */
    @State var frameReady: Bool = false
    /** 是否正在播放 */
    @State var isPlaying: Bool = false
    /** 当前帧时间戳（秒） */
    @State var currentTimeSec: Float64 = 0.0
    /** 是否显示加载指示 */
    @State var isLoading: Bool = false
    /** 帧提取错误信息（空字符串 = 无错误） */
    @State var errorMsg: String = ""
    /** 播放是否被外部停止（不可恢复） */
    private var _stopped: Bool = false
    /** 是否已触发过 onPlaybackStarted */
    private var _playbackStarted: Bool = false
    /** MediaTrackFrameBuffer 实例（核心水位调度器） */
    private var _frameBuffer: Option<MediaTrackFrameBuffer> = None
    /** 当前帧间隔（毫秒） */
    private var _frameDurationMs: Int64 = 67

    // ── 辅助方法（不在 build 中使用 let，提取为 func）───────────────

    private func effectiveFps(): Float64 {
        if (this.videoData.fps > 0.0) {
            return this.videoData.fps
        }
        return 15.0
    }

    private func effectiveDurationSec(): Float64 {
        if (this.videoData.durationUs > 0) {
            return Float64(this.videoData.durationUs) / 1_000_000.0
        }
        return 0.0
    }

    // ── 生命周期 ───────────────────────────────────────────────────

    /**
     * 组件显示时初始化帧源并启动播放。
     *
     * 对应 iOS SoftwareVideoLayerFrameManager 在 softwareVideoApplyQueue 上启动帧提交。
     *
     * S-001 合规：@State 更新均在 launch {} 中
     */
    public func aboutToAppear(): Unit {
        _stopped = false
        _playbackStarted = false
        _frameDurationMs = Int64(1000.0 / effectiveFps())

        if (this.videoData.localFilePath.size == 0) {
            Hilog.info(0, "CjTelegram", "[SoftwareVideoComponent] No file path, skip playback")
            return
        }

        launch {
            this.isLoading = true
            this.isPlaying = false
            this.errorMsg = ""
        }

        _initFrameBufferAndStart()
    }

    /**
     * 组件消失时停止播放并释放资源。
     *
     * 对应 iOS clearSampleBufferLayerPoll() 在 Queue.mainQueue 上的清理逻辑。
     */
    public func aboutToDisappear(): Unit {
        _stopped = true
        match (_frameBuffer) {
            case Some(buf) =>
                buf.detach()
                _frameBuffer = None
            case None => ()
        }
        getSoftwareVideoService().clearFramePool()
        launch {
            this.isPlaying = false
            this.frameReady = false
        }
        Hilog.info(0, "CjTelegram", "[SoftwareVideoComponent] Disappeared, playback stopped")
    }

    // ── 播放控制 ───────────────────────────────────────────────────

    /**
     * 开始播放（从头或从当前位置）。
     *
     * 对应 iOS softwareVideoWorkers 工作线程启动帧解码。
     */
    public func startPlayback(): Unit {
        if (this.isPlaying || _stopped) {
            return
        }
        _stopped = false
        _initFrameBufferAndStart()
    }

    /**
     * 暂停播放（保留当前帧）。
     *
     * 对应 iOS AVSampleBufferDisplayLayer.requestMediaDataWhenReady 停止请求。
     */
    public func pausePlayback(): Unit {
        match (_frameBuffer) {
            case Some(buf) => buf.detach()
            case None => ()
        }
        _frameBuffer = None
        launch {
            this.isPlaying = false
        }
        Hilog.info(0, "CjTelegram", "[SoftwareVideoComponent] Paused")
    }

    /**
     * 停止播放并清空帧池。
     *
     * 对应 iOS clearSampleBufferLayerPoll()。
     */
    public func stopPlayback(): Unit {
        _stopped = true
        match (_frameBuffer) {
            case Some(buf) =>
                buf.detach()
                _frameBuffer = None
            case None => ()
        }
        getSoftwareVideoService().clearFramePool()
        launch {
            this.isPlaying = false
            this.frameReady = false
            this.currentTimeSec = 0.0
        }
        Hilog.info(0, "CjTelegram", "[SoftwareVideoComponent] Stopped")
    }

    // ── 帧缓冲初始化（P2-233/P2-234 frame source 选择）───────────

    /**
     * 根据 videoData 选择合适的 MediaFrameSource，创建 MediaTrackFrameBuffer，
     * 并启动首次帧请求与 Timer pacing 循环。
     *
     * P2-233：isAnimatedImage → AnimatedImageFrameSource（GIF/WebP，ImageSource 真实 API）
     * P2-234：!isAnimatedImage → VideoFileFrameSource（WholeFile/Streamable 模式）
     *
     * 对应 iOS SoftwareVideoLayerFrameManager 中 softwareVideoWorkers 初始化。
     */
    private func _initFrameBufferAndStart(): Unit {
        let filePath = this.videoData.localFilePath
        let durationSec = effectiveDurationSec()
        let fps = effectiveFps()

        let frameBuffer: MediaTrackFrameBuffer
        if (this.videoData.isAnimatedImage) {
            let animSrc = AnimatedImageFrameSource(filePath)
            frameBuffer = MediaTrackFrameBuffer(
                frameSource: animSrc,
                totalDuration: durationSec,
                stallDuration: 1.0,
                lowWaterDuration: 2.0,
                highWaterDuration: 3.0
            )
            Hilog.info(0, "CjTelegram", "[SoftwareVideoComponent] Using AnimatedImageFrameSource")
        } else {
            let videoSrc = VideoFileFrameSource(
                filePath,
                mode: this.videoData.playbackMode,
                durationSec: durationSec,
                fps: fps
            )
            frameBuffer = MediaTrackFrameBuffer(
                frameSource: videoSrc,
                totalDuration: durationSec,
                stallDuration: 1.0,
                lowWaterDuration: 2.0,
                highWaterDuration: 3.0
            )
            Hilog.info(0, "CjTelegram", "[SoftwareVideoComponent] Using VideoFileFrameSource")
        }

        frameBuffer.onStatusUpdated = { =>
            this._onBufferStatusUpdated()
        }
        frameBuffer.onNextFrameTick = { =>
            this._onFrameTick()
        }

        _frameBuffer = Some(frameBuffer)

        frameBuffer.requestFramesUntil(untilTimestamp: 3.0)

        let status = frameBuffer.status(atTimestamp: 0.0)
        _handleBufferStatus(status, atTimestamp: 0.0)
    }

    // ── 帧 pacing 回调（P2-233 Timer.once 驱动，非 sleep 忙等）────

    /**
     * 帧节拍回调（由 MediaTrackFrameBuffer.scheduleNextFrame → Timer.once 触发）。
     *
     * 对应 iOS softwareVideoApplyQueue 上的帧提交时序。
     * 此方法在 launch {} 中调用，运行在主线程（S-001 合规）。
     *
     * 流程：
     *   1. 查询 frameBuffer 水位状态
     *   2. 若 Buffering → 等待，重新调度 scheduleNextFrame
     *   3. 若 Full → takeFrame() 取帧并渲染，调度下一帧
     *   4. 若 Finished → 检查循环/触发结束回调
     */
    private func _onFrameTick(): Unit {
        if (_stopped) {
            return
        }
        match (_frameBuffer) {
            case None => return
            case Some(buf) =>
                let currentTs = this.currentTimeSec
                let status = buf.status(atTimestamp: currentTs)
                _handleBufferStatus(status, atTimestamp: currentTs)
        }
    }

    /**
     * 帧缓冲状态变化通知（由 frameSource 回调驱动）。
     *
     * 对应 iOS statusUpdated 回调：帧到达时通知调度器重新评估。
     */
    private func _onBufferStatusUpdated(): Unit {
        if (_stopped) {
            return
        }
        match (_frameBuffer) {
            case None => return
            case Some(buf) =>
                let currentTs = this.currentTimeSec
                let status = buf.status(atTimestamp: currentTs)
                match (status) {
                    case FrameBufferStatus.Buffering(_) =>
                        ()
                    case FrameBufferStatus.Full(_) =>
                        if (!this.isPlaying) {
                            _handleBufferStatus(status, atTimestamp: currentTs)
                        }
                    case FrameBufferStatus.Finished(_) =>
                        _handleBufferStatus(status, atTimestamp: currentTs)
                }
        }
    }

    /**
     * 处理水位状态并决策下一步行动（P2-230 核心）。
     *
     * 对应 iOS MediaTrackFrameBuffer.status(at:) 返回值分派：
     *   .buffering → 等待缓冲，重新调度（500ms 后重查）
     *   .full      → 取帧 + 渲染 + 调度下一帧
     *   .finished  → 循环或终止
     */
    private func _handleBufferStatus(status: FrameBufferStatus, atTimestamp!: Float64): Unit {
        match (status) {
            case FrameBufferStatus.Buffering(_) =>
                launch {
                    this.isLoading = true
                }
                match (_frameBuffer) {
                    case Some(buf) => buf.scheduleNextFrame(frameDurationMs: 200)
                    case None => ()
                }

            case FrameBufferStatus.Full(_) =>
                match (_frameBuffer) {
                    case None => ()
                    case Some(buf) =>
                        let result = buf.takeFrame()
                        match (result) {
                            case FrameTakeResult.NoFrames =>
                                buf.scheduleNextFrame(frameDurationMs: _frameDurationMs)
                            case FrameTakeResult.SkipFrame =>
                                buf.scheduleNextFrame(frameDurationMs: 0)
                            case FrameTakeResult.GotFrame(frame) =>
                                _renderFrame(frame, buf: buf)
                            case FrameTakeResult.Finished =>
                                _handlePlaybackFinished()
                        }
                }

            case FrameBufferStatus.Finished(_) =>
                _handlePlaybackFinished()
        }
    }

    /**
     * 渲染一帧（更新 currentTimeSec 并请求水位补充）。
     *
     * @param frame 已解码的帧
     * @param buf   当前 MediaTrackFrameBuffer（用于调度下一帧）
     */
    private func _renderFrame(frame: BufferedVideoFrame, buf!: MediaTrackFrameBuffer): Unit {
        let newTs = frame.pts
        let capturedVersion = this.frameVersion + 1

        // GIF/WebP 路径：frame.pixelMap 已由 AnimatedImageFrameSource 填入已解码 PixelMap。
        // 将其写入 SoftwareVideoService.lastFrame，使 getSoftwareVideoCurrentPixelMap()
        // 在 build() 中返回真实帧而非 1x1 dummy。
        // 此处在主线程（launch{} 内由 Timer.once 触发），符合 S-001。
        match (frame.pixelMap) {
            case Some(pm) =>
                let svc = getSoftwareVideoService()
                // 释放上一帧 PixelMap（视频路径 lastFrame 由 extractFrame 管理；
                // 动图路径则由此处接管生命周期）
                match (svc.lastFrame.pixelMap) {
                    case Some(oldPm) =>
                        oldPm.release()
                        svc.lastFrame.pixelMap = None
                    case None => ()
                }
                svc.lastFrame.pixelMap = Some(pm)
                svc.lastFrame.isValid = true
                frame.pixelMap = None
            case None => ()
        }

        launch {
            this.currentTimeSec = newTs
            this.frameVersion = capturedVersion
            this.frameReady = true
            this.isLoading = false
            this.isPlaying = true
            this.errorMsg = ""
        }

        if (!_playbackStarted) {
            _playbackStarted = true
            let capturedCb = this.onPlaybackStarted
            launch {
                capturedCb()
            }
        }

        let nextTs = newTs + Float64(_frameDurationMs) / 1000.0
        let highWaterReq = nextTs + 3.0
        buf.requestFramesUntil(untilTimestamp: highWaterReq)

        buf.scheduleNextFrame(frameDurationMs: _frameDurationMs)

        Hilog.info(0, "CjTelegram", "[SoftwareVideoComponent] Rendered frame pts=${newTs}s buffered=${buf.bufferedFrameCount()}")
    }

    /**
     * 处理播放完成（循环或终止）。
     *
     * 对应 iOS softwareVideoApplyQueue 上检测到 endOfStream 后的循环/停止逻辑。
     */
    private func _handlePlaybackFinished(): Unit {
        let capturedFinishCb = this.onPlaybackFinished
        launch {
            capturedFinishCb()
        }

        if (this.videoData.loop && !_stopped) {
            Hilog.info(0, "CjTelegram", "[SoftwareVideoComponent] Loop: restarting")
            match (_frameBuffer) {
                case Some(buf) =>
                    buf.clearBuffer()
                    buf.requestFramesUntil(untilTimestamp: 3.0)
                    launch {
                        this.currentTimeSec = 0.0
                    }
                    let status = buf.status(atTimestamp: 0.0)
                    _handleBufferStatus(status, atTimestamp: 0.0)
                case None =>
                    _initFrameBufferAndStart()
            }
        } else {
            launch {
                this.isPlaying = false
            }
            Hilog.info(0, "CjTelegram", "[SoftwareVideoComponent] Playback finished (no loop)")
        }
    }

    // ── UI 构建 ────────────────────────────────────────────────────

    func build() {
        Stack() {
            if (this.frameReady) {
                Image(getSoftwareVideoCurrentPixelMap())
                    .width(100.percent)
                    .height(100.percent)
                    .objectFit(ImageFit.Contain)
            } else {
                if (this.isLoading) {
                    LoadingProgress()
                        .width(48)
                        .height(48)
                        .color(0xFFFFFF)
                } else {
                    if (this.errorMsg.size > 0) {
                        Text(this.errorMsg)
                            .fontSize(12)
                            .fontColor(0xFF6666)
                    } else {
                        Column {}
                            .width(100.percent)
                            .height(100.percent)
                    }
                }
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x000000)
    }
}
