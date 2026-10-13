package ohos_app_cangjie_entry.services

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import kit.ImageKit.{createImageSource, ImageSource, DecodingOptions, PixelMapFormat, PixelMap}
import ohos.business_exception.BusinessException
import std.collection.ArrayList
import std.sync.Timer

/**
 * MediaTrackFrameBuffer — 帧缓冲与水位调度
 *
 * P2-230：帧缓冲水位调度（低/高水位阈值驱动 frameSource.requestFramesUntil）
 * P2-233：AnimatedImageFrameSource（ImageSource.getFrameCount + getDelayTimeList，GIF/WebP 真实软解）
 *          Timer.once 回调驱动帧 pacing（非 sleep 忙等）
 * P2-234：MediaFrameSource 接口 + VideoFileFrameSource（WholeFile/Streamable 抽象）
 *
 * 对应 iOS MediaPlayer/Sources/MediaTrackFrameBuffer.swift：
 *   - stallDuration:       暂停时的最低缓冲深度（触发 stall 等待）
 *   - lowWaterDuration:    低水位阈值（低于此值时触发向 frameSource 请求更多帧）
 *   - highWaterDuration:   高水位阈值（到达此值时停止请求帧）
 *
 * 鸿蒙实现映射：
 *   iOS CMTime（秒）→ Double（秒）
 *   iOS [MediaTrackDecodableFrame] 队列 → ArrayList<BufferedVideoFrame>（本地 PixelMap 队列）
 *   iOS frameSource.generateFrames(until:types:) → AnimatedImageFrameSource/VideoFileFrameSource 的帧生成
 *
 * FFmpeg 说明（Deferred）：
 *   iOS SoftwareVideoSource 依赖 FFMpegBinding 解码 WebM/VP9/H.264 等。
 *   鸿蒙目前无 FFmpeg 绑定；Video 帧解码路径诚实 defer，接口抽象不 defer。
 *   AnimatedImageFrameSource（GIF/WebP）：使用 ImageSource.getFrameCount() + getDelayTimeList()，
 *   是鸿蒙平台真实可用的软解路径（非 defer）。
 */

// ─────────────────────────────────────────────────────────────────
// 帧状态枚举（对应 iOS MediaTrackFrameBufferStatus）
// ─────────────────────────────────────────────────────────────────

/**
 * 帧缓冲状态
 *
 * 对应 iOS MediaTrackFrameBufferStatus：
 *   .buffering(progress:) → FrameBufferStatus.Buffering(progress)
 *   .full(until:)         → FrameBufferStatus.Full(until)
 *   .finished(at:)        → FrameBufferStatus.Finished(at)
 */
public enum FrameBufferStatus {
    /** 正在填充缓冲，progress 为 [0.0, 1.0] 区间的填充进度 */
    | Buffering(Float64)
    /** 缓冲充足，until 为下一次需要检查的时间戳（秒） */
    | Full(Float64)
    /** 已到达流末尾（或文件末尾），at 为最后有效帧时间戳（秒） */
    | Finished(Float64)
}

/**
 * 取帧结果
 *
 * 对应 iOS MediaTrackFrameResult。
 * 鸿蒙无 CMSampleBuffer，使用 BufferedVideoFrame 封装已解码 PixelMap。
 */
public enum FrameTakeResult {
    /** 没有可用帧（缓冲为空且未完成） */
    | NoFrames
    /** 跳帧（decode 失败，应跳过此帧继续循环） */
    | SkipFrame
    /** 成功取到一帧 */
    | GotFrame(BufferedVideoFrame)
    /** 播放已完成（endOfStream + 无剩余帧） */
    | Finished
}

// ─────────────────────────────────────────────────────────────────
// 帧数据（已解码）
// ─────────────────────────────────────────────────────────────────

/**
 * 已缓冲的视频帧（已解码到 PixelMap）
 *
 * 对应 iOS MediaTrackFrame（携带 CMSampleBuffer + pts/duration）。
 * 鸿蒙使用 PixelMap（由 ImageSource 或 AVImageGenerator 解码）。
 */
public class BufferedVideoFrame {
    /** 帧呈现时间戳（秒，对应 iOS CMTime） */
    public var pts: Float64 = 0.0
    /** 帧持续时间（秒，对应 iOS CMTime duration） */
    public var duration: Float64 = 0.066
    /** 帧序号（用于索引多帧图像源的帧，如 GIF/WebP 的 frameIndex） */
    public var frameIndex: Int32 = 0
    /** 帧宽度（像素） */
    public var width: Int32 = 0
    /** 帧高度（像素） */
    public var height: Int32 = 0
    /** 帧是否有效（false 表示提取失败，应 SkipFrame） */
    public var isValid: Bool = false
    /**
     * 已解码帧 PixelMap（GIF/WebP 动图路径存储，由 AnimatedImageFrameSource 填入）。
     * 帧被 takeFrame 消费后写入 SoftwareVideoService.lastFrame 供渲染读取；
     * 帧被 _pruneExpiredFrames 丢弃时 release，避免泄漏。
     */
    public var pixelMap: Option<PixelMap> = None

    public init() {}
}

// ─────────────────────────────────────────────────────────────────
// MediaFrameSource 接口（P2-234 抽象）
// ─────────────────────────────────────────────────────────────────

/**
 * MediaFrameSource — 帧供给源抽象接口
 *
 * 对应 iOS MediaFrameSource protocol（MediaPlayer/Sources/MediaFrameSource.swift）：
 *   func addEventSink(_:)           → addFrameCallback(onFrame:onEnd:)
 *   func removeEventSink(_:)        → removeFrameCallback(index:)
 *   func generateFrames(until:types:) → requestFramesUntil(untilTimestamp:)
 *   func seek(timestamp:)           → seek(timestamp:)
 *
 * FFmpeg Deferred：
 *   iOS SoftwareVideoSource 实现了 MediaFrameSource 但依赖 FFMpegBinding。
 *   鸿蒙侧 VideoFileFrameSource 诚实标注 deferred（AVImageGenerator 路径为临时替代）。
 *   AnimatedImageFrameSource 使用 ImageSource API，真实可用。
 */
public interface MediaFrameSource {
    /**
     * 注册帧事件回调，返回 sink 索引（用于注销）。
     *
     * 对应 iOS addEventSink(_ f: @escaping (MediaTrackEvent) -> Void) -> Int。
     * 回调均通过 launch {} 在主线程调用（S-001 合规）。
     */
    func addFrameCallback(onFrame!: (BufferedVideoFrame) -> Unit, onEnd!: () -> Unit): Int32

    /**
     * 注销帧事件回调。
     *
     * 对应 iOS removeEventSink(_ index: Int)。
     */
    func removeFrameCallback(index: Int32): Unit

    /**
     * 请求生成到指定时间戳为止的帧（水位驱动）。
     *
     * 对应 iOS generateFrames(until timestamp: Double, types: [MediaTrackFrameType])。
     * 触发源将异步（spawn）解码并回调 addFrameCallback 注册的 onFrame（通过 launch {}）。
     *
     * @param untilTimestamp 请求生成到此时间戳（秒）
     */
    func requestFramesUntil(untilTimestamp!: Float64): Unit

    /**
     * 跳转到指定时间戳。
     *
     * 对应 iOS seek(timestamp:)。
     */
    func seek(timestamp!: Float64): Unit

    /**
     * 获取视频总时长（秒）。0 表示未知。
     */
    func duration(): Float64

    /**
     * 获取视频帧率（帧/秒）。0 表示未知。
     */
    func fps(): Float64
}

// ─────────────────────────────────────────────────────────────────
// AnimatedImageFrameSource（P2-233 GIF/WebP 软解，真实可用）
// ─────────────────────────────────────────────────────────────────

/**
 * AnimatedImageFrameSource — 基于 ImageSource 的动图帧供给源
 *
 * 对应 iOS SoftwareVideoLayerFrameManager 中管理的 3 个 softwareVideoWorkers 线程池，
 * 负责 GIF/WebP 动图逐帧解码（iOS 通过 FFMpegBinding 解码，鸿蒙通过 ImageSource）。
 *
 * 鸿蒙平台能力（真实 API，非 defer）：
 *   - ImageSource.getFrameCount()      → 获取 GIF/WebP 总帧数
 *   - ImageSource.getDelayTimeList()   → 获取每帧延迟时间（ms）
 *   - ImageSource.createPixelMap(options: DecodingOptions(index:))  → 按索引解码单帧
 *
 * iOS SoftwareVideoLayerFrameManager 的 3 线程设计对应鸿蒙的 spawn 异步解码。
 * 帧 pacing 由 MediaTrackFrameBuffer.scheduleNextFrame() 通过 Timer.once() 驱动（非 sleep 忙等）。
 */
public class AnimatedImageFrameSource <: MediaFrameSource {
    /** 文件路径（沙箱绝对路径） */
    private let _filePath: String
    /** 总帧数（getFrameCount 缓存） */
    private var _frameCount: Int32 = 0
    /** 每帧延迟列表（ms，getDelayTimeList 缓存）；空则用默认帧率计算 */
    private var _delayList: Array<Int32> = Array<Int32>()
    /** 累积时间戳映射（帧索引 → 开始时间戳，秒） */
    private var _framePts: Array<Float64> = Array<Float64>()
    /** 总时长（秒，由 delayList 累加得到） */
    private var _totalDuration: Float64 = 0.0
    /** 当前已请求到的最大时间戳（requestFramesUntil 水位） */
    private var _requestedUntil: Float64 = 0.0
    /** 已生成的最后帧索引（-1 表示未开始） */
    private var _lastGeneratedIndex: Int32 = -1
    /** 回调注册表 */
    private var _callbacks: ArrayList<FrameCallbackEntry> = ArrayList<FrameCallbackEntry>()
    private var _nextCallbackIdx: Int32 = 0

    public init(filePath: String) {
        _filePath = filePath
        _initMetadata()
    }

    /**
     * 初始化 ImageSource 并缓存帧元数据。
     *
     * 使用 ImageSource.getFrameCount() + getDelayTimeList() 建立时间戳映射表。
     * 这是真实 HarmonyOS API（非 defer），支持 GIF 和 WebP 动图。
     */
    private func _initMetadata(): Unit {
        if (_filePath.size == 0) {
            return
        }
        try {
            let src = createImageSource(_filePath)
            let count = src.getFrameCount()
            _frameCount = Int32(count)
            if (_frameCount <= 0) {
                _frameCount = 1
            }
            var delays: Array<Int32> = Array<Int32>()
            try {
                delays = src.getDelayTimeList()
            } catch (_: Exception) {
                delays = Array<Int32>()
            }
            _delayList = delays
            _framePts = Array<Float64>(Int64(_frameCount), repeat: 0.0)
            var accum: Float64 = 0.0
            var i: Int32 = 0
            while (i < _frameCount) {
                _framePts[Int64(i)] = accum
                let delayMs: Float64 = if (Int64(i) < _delayList.size && _delayList[Int64(i)] > 0) {
                    Float64(_delayList[Int64(i)])
                } else {
                    66.0
                }
                accum = accum + delayMs / 1000.0
                i = i + 1
            }
            _totalDuration = accum
            src.release()
            Hilog.info(0, "CjTelegram",
                "[AnimatedImageFrameSource] init frames=${_frameCount} dur=${_totalDuration}s")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[AnimatedImageFrameSource] init failed: ${e.message}")
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[AnimatedImageFrameSource] init failed (unknown)")
        }
    }

    public func addFrameCallback(onFrame!: (BufferedVideoFrame) -> Unit, onEnd!: () -> Unit): Int32 {
        let idx = _nextCallbackIdx
        _nextCallbackIdx = _nextCallbackIdx + 1
        let entry = FrameCallbackEntry(idx, onFrame, onEnd)
        let newList = ArrayList<FrameCallbackEntry>()
        var i: Int64 = 0
        while (i < _callbacks.size) {
            newList.add(_callbacks[i])
            i = i + 1
        }
        newList.add(entry)
        _callbacks = newList
        return idx
    }

    public func removeFrameCallback(index: Int32): Unit {
        let newList = ArrayList<FrameCallbackEntry>()
        var i: Int64 = 0
        while (i < _callbacks.size) {
            let e = _callbacks[i]
            if (e.idx != index) {
                newList.add(e)
            }
            i = i + 1
        }
        _callbacks = newList
    }

    /**
     * 请求生成到 untilTimestamp 为止的帧，并通过回调推送。
     *
     * 对应 iOS MediaFrameSource.generateFrames(until:types:)。
     * 在 spawn 线程中异步解码帧，通过 launch {} 推送回调（主线程安全，S-001 合规）。
     *
     * 水位控制：只生成 _requestedUntil < untilTimestamp 之间尚未生成的帧。
     */
    public func requestFramesUntil(untilTimestamp!: Float64): Unit {
        if (_frameCount <= 0) {
            return
        }
        if (untilTimestamp <= _requestedUntil) {
            return
        }
        let prevRequested = _requestedUntil
        _requestedUntil = untilTimestamp
        let capturedFilePath = _filePath
        let capturedFramePts = _framePts
        let capturedFrameCount = _frameCount
        let capturedCallbacks = _callbacks
        let capturedPrevReq = prevRequested
        let capturedUntil = untilTimestamp
        let startIdx: Int32 = if (_lastGeneratedIndex >= 0) { _lastGeneratedIndex + 1 } else { 0 }
        let capturedStartIdx = startIdx
        _lastGeneratedIndex = _frameCount - 1

        let _ = spawn {
            var src: Option<ImageSource> = None
            try {
                src = Some(createImageSource(capturedFilePath))
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[AnimatedImageFrameSource] spawn: createImageSource failed")
                return
            }
            match (src) {
                case None => return
                case Some(imageSource) =>
                    var frameIdx: Int32 = capturedStartIdx
                    while (frameIdx < capturedFrameCount) {
                        let ptsSec: Float64 = if (Int64(frameIdx) < capturedFramePts.size) {
                            capturedFramePts[Int64(frameIdx)]
                        } else {
                            Float64(frameIdx) * 0.066
                        }
                        if (ptsSec < capturedPrevReq) {
                            frameIdx = frameIdx + 1
                            continue
                        }
                        if (ptsSec > capturedUntil) {
                            break
                        }
                        let frame = BufferedVideoFrame()
                        frame.pts = ptsSec
                        frame.frameIndex = frameIdx
                        try {
                            let opts = DecodingOptions(
                                index: UInt32(frameIdx),
                                desiredPixelFormat: PixelMapFormat.Rgba8888
                            )
                            let pm = imageSource.createPixelMap(options: opts)
                            frame.isValid = true
                            let nextPts: Float64 = if (Int64(frameIdx) + 1 < capturedFramePts.size) {
                                capturedFramePts[Int64(frameIdx) + 1]
                            } else {
                                ptsSec + 0.066
                            }
                            frame.duration = nextPts - ptsSec
                            // 将已解码 PixelMap 存入 frame，由消费侧（takeFrame → _renderFrame）
                            // 写入 SoftwareVideoService.lastFrame 后渲染；帧被 prune 时 release。
                            frame.pixelMap = Some(pm)
                        } catch (_: Exception) {
                            frame.isValid = false
                        }

                        let capturedFrame = frame
                        var i: Int64 = 0
                        while (i < capturedCallbacks.size) {
                            let entry = capturedCallbacks[i]
                            let capturedOnFrame = entry.onFrame
                            let capturedFrameLocal = capturedFrame
                            launch {
                                capturedOnFrame(capturedFrameLocal)
                            }
                            i = i + 1
                        }
                        frameIdx = frameIdx + 1
                    }
                    imageSource.release()
            }
        }
    }

    public func seek(timestamp!: Float64): Unit {
        _requestedUntil = 0.0
        _lastGeneratedIndex = -1
        var targetIdx: Int32 = 0
        var i: Int32 = 0
        while (i < _frameCount) {
            let pts: Float64 = if (Int64(i) < _framePts.size) { _framePts[Int64(i)] } else { Float64(i) * 0.066 }
            if (pts <= timestamp) {
                targetIdx = i
            } else {
                break
            }
            i = i + 1
        }
        _lastGeneratedIndex = targetIdx - 1
        _requestedUntil = timestamp
        Hilog.info(0, "CjTelegram", "[AnimatedImageFrameSource] seek to ${timestamp}s → frame ${targetIdx}")
    }

    public func duration(): Float64 {
        return _totalDuration
    }

    public func fps(): Float64 {
        if (_totalDuration > 0.0 && _frameCount > 0) {
            return Float64(_frameCount) / _totalDuration
        }
        return 15.0
    }

    /** 总帧数 */
    public func frameCount(): Int32 {
        return _frameCount
    }
}

// ─────────────────────────────────────────────────────────────────
// 回调条目辅助类（避免元组操作复杂性）
// ─────────────────────────────────────────────────────────────────

/**
 * 帧回调注册条目
 */
public class FrameCallbackEntry {
    public let idx: Int32
    public let onFrame: (BufferedVideoFrame) -> Unit
    public let onEnd: () -> Unit

    public init(idx: Int32, onFrame: (BufferedVideoFrame) -> Unit, onEnd: () -> Unit) {
        this.idx = idx
        this.onFrame = onFrame
        this.onEnd = onEnd
    }
}

// ─────────────────────────────────────────────────────────────────
// VideoPlaybackMode（P2-234 streamable vs 整文件模式）
// ─────────────────────────────────────────────────────────────────

/**
 * 播放模式枚举（P2-234 chunk/streamable 抽象）
 *
 * 对应 iOS SoftwareVideoSource 的 streamable 变体：
 *   - WholeFile:   整文件已下载，可随机 seek（对应 iOS 普通模式）
 *   - Streamable:  分片流式，只能顺序读取当前已下载部分（对应 iOS streamable 变体）
 *
 * 鸿蒙 AVImageGenerator 仅支持整文件模式；Streamable 模式诚实 defer（需 FFmpeg）。
 */
public enum VideoPlaybackMode {
    /** 整文件模式：文件已完全下载，随机 seek 可用（AVImageGenerator 路径真实） */
    | WholeFile
    /**
     * 分片流式模式：仅支持顺序播放当前已缓冲部分。
     * DEFERRED：需要 FFmpeg 帧级读取能力，当前鸿蒙平台无法实现。
     * 占位保留接口，实际调用时退化为 WholeFile 行为。
     */
    | Streamable
}

// ─────────────────────────────────────────────────────────────────
// VideoFileFrameSource（P2-234 抽象，视频文件路径，FFmpeg defer）
// ─────────────────────────────────────────────────────────────────

/**
 * VideoFileFrameSource — 本地视频文件帧供给源（P2-234 抽象）
 *
 * 对应 iOS SoftwareVideoSource（FFMpegBinding 封装）的帧供给抽象。
 *
 * 实现说明：
 *   - WholeFile 模式：使用 AVImageGenerator.fetchFrameByTime（已在 SoftwareVideoService 中实现）
 *   - Streamable 模式：DEFERRED — 依赖 FFmpeg 分包读取，鸿蒙无绑定，退化为 WholeFile
 *
 * FFmpeg Deferred 说明：
 *   iOS SoftwareVideoSource 通过 FFMpegAVFormatContext.readFrame() 逐包解码，
 *   支持 WebM/VP9/H.264 等格式。鸿蒙暂无 FFmpeg 绑定，仅支持 AVImageGenerator。
 */
public class VideoFileFrameSource <: MediaFrameSource {
    /** 本地视频文件路径 */
    private let _filePath: String
    /** 播放模式（Streamable 退化为 WholeFile） */
    private let _mode: VideoPlaybackMode
    /** 视频总时长（秒），由上层 SoftwareVideoData 传入 */
    private let _durationSec: Float64
    /** 视频帧率 */
    private let _fpsSec: Float64
    /** 已请求到的水位时间戳 */
    private var _requestedUntil: Float64 = 0.0
    /** 回调列表 */
    private var _callbacks: ArrayList<FrameCallbackEntry> = ArrayList<FrameCallbackEntry>()
    private var _nextCbIdx: Int32 = 0

    public init(filePath: String, mode!: VideoPlaybackMode, durationSec!: Float64 = 0.0, fps!: Float64 = 15.0) {
        _filePath = filePath
        _mode = mode
        _durationSec = durationSec
        _fpsSec = fps
    }

    public func addFrameCallback(onFrame!: (BufferedVideoFrame) -> Unit, onEnd!: () -> Unit): Int32 {
        let idx = _nextCbIdx
        _nextCbIdx = _nextCbIdx + 1
        let entry = FrameCallbackEntry(idx, onFrame, onEnd)
        let newList = ArrayList<FrameCallbackEntry>()
        var i: Int64 = 0
        while (i < _callbacks.size) {
            newList.add(_callbacks[i])
            i = i + 1
        }
        newList.add(entry)
        _callbacks = newList
        return idx
    }

    public func removeFrameCallback(index: Int32): Unit {
        let newList = ArrayList<FrameCallbackEntry>()
        var i: Int64 = 0
        while (i < _callbacks.size) {
            let e = _callbacks[i]
            if (e.idx != index) {
                newList.add(e)
            }
            i = i + 1
        }
        _callbacks = newList
    }

    /**
     * 请求生成到 untilTimestamp 为止的帧。
     *
     * WholeFile 模式：通过 SoftwareVideoService.extractFrame 逐帧提取。
     * Streamable 模式：退化为 WholeFile（FFmpeg deferred）。
     *
     * 对应 iOS generateFrames(until:types:) → softwareVideoWorkers 线程池任务。
     */
    public func requestFramesUntil(untilTimestamp!: Float64): Unit {
        if (_filePath.size == 0) {
            return
        }
        if (untilTimestamp <= _requestedUntil) {
            return
        }
        let fromTime = _requestedUntil
        _requestedUntil = untilTimestamp
        let capturedFilePath = _filePath
        let capturedFps = _fpsSec
        let capturedDur = _durationSec
        let capturedFrom = fromTime
        let capturedUntil = untilTimestamp
        let capturedCallbacks = _callbacks
        let svc = getSoftwareVideoService()

        let _ = spawn {
            let frameDur: Float64 = if (capturedFps > 0.0) { 1.0 / capturedFps } else { 0.066 }
            var t: Float64 = capturedFrom
            while (t <= capturedUntil) {
                let timeUs = Int64(t * 1_000_000.0)
                let rawFrame = svc.extractFrame(capturedFilePath, timeUs)
                let frame = BufferedVideoFrame()
                frame.pts = t
                frame.duration = frameDur
                frame.frameIndex = Int32(t / frameDur)
                frame.isValid = rawFrame.isValid
                frame.width = rawFrame.width
                frame.height = rawFrame.height

                let capturedFrame = frame
                var i: Int64 = 0
                while (i < capturedCallbacks.size) {
                    let entry = capturedCallbacks[i]
                    let capturedOnFrame = entry.onFrame
                    let capturedFrameLocal = capturedFrame
                    launch {
                        capturedOnFrame(capturedFrameLocal)
                    }
                    i = i + 1
                }

                let isAtEnd = capturedDur > 0.0 && (t + frameDur) >= capturedDur
                if (isAtEnd) {
                    var j: Int64 = 0
                    while (j < capturedCallbacks.size) {
                        let entry = capturedCallbacks[j]
                        let capturedOnEnd = entry.onEnd
                        launch {
                            capturedOnEnd()
                        }
                        j = j + 1
                    }
                    break
                }
                t = t + frameDur
            }
        }
    }

    public func seek(timestamp!: Float64): Unit {
        _requestedUntil = timestamp
        Hilog.info(0, "CjTelegram", "[VideoFileFrameSource] seek to ${timestamp}s")
    }

    public func duration(): Float64 {
        return _durationSec
    }

    public func fps(): Float64 {
        return _fpsSec
    }

    /** 播放模式 */
    public func playbackMode(): VideoPlaybackMode {
        return _mode
    }
}

// ─────────────────────────────────────────────────────────────────
// MediaTrackFrameBuffer（P2-230 水位调度核心）
// ─────────────────────────────────────────────────────────────────

/**
 * MediaTrackFrameBuffer — 帧缓冲水位调度器
 *
 * 完整对应 iOS MediaPlayer/Sources/MediaTrackFrameBuffer.swift 的水位逻辑：
 *
 * 水位参数（秒）：
 *   - stallDuration:     1.0s —— 低于此值且缓冲已停，触发 buffering stall 等待
 *   - lowWaterDuration:  2.0s —— 低于此值时向 frameSource 请求更多帧
 *   - highWaterDuration: 3.0s —— 请求帧直到此值为止
 *
 * 调度逻辑（status(atTimestamp:) 等价于 iOS status(at:)）：
 *   1. 计算 bufferedDuration = bufferedUntilTime - currentTimestamp
 *   2. 若 bufferedDuration < lowWaterDuration →
 *        frameSource.requestFramesUntil(currentTimestamp + highWaterDuration)
 *        若 bufferedDuration > stallDuration → .Full
 *        否则 → .Buffering
 *   3. 若 bufferedDuration >= lowWaterDuration → .Full
 *   4. endOfStream → .Finished
 *
 * 帧 pacing（scheduleNextFrame）：
 *   使用 Timer.once(delay:task:) 在精确延迟后触发 onNextFrameTick 回调。
 *   非 sleep 忙等（对应 iOS softwareVideoApplyQueue 上的延迟帧提交）。
 */
public class MediaTrackFrameBuffer {
    /** stall 阈值（秒） */
    private let _stallDuration: Float64
    /** 低水位阈值（秒） */
    private let _lowWaterDuration: Float64
    /** 高水位阈值（秒） */
    private let _highWaterDuration: Float64

    /** 帧供给源（AnimatedImageFrameSource 或 VideoFileFrameSource） */
    private let _frameSource: MediaFrameSource

    /** 视频总时长（秒） */
    private let _totalDuration: Float64

    /** 帧缓冲队列（按 pts 顺序追加） */
    private var _bufferedFrames: ArrayList<BufferedVideoFrame> = ArrayList<BufferedVideoFrame>()

    /** 已缓冲到的最大时间戳（秒，对应 iOS bufferedUntilTime） */
    private var _bufferedUntilTime: Float64 = 0.0

    /** endOfStream 标志 */
    private var _endOfStream: Bool = false

    /** 是否处于低水位等待状态（iOS 的 isWaitingForLowWaterDuration） */
    private var _isWaitingForLowWater: Bool = false

    /** 已注册的 frameSource 回调 index（用于 detach 时注销） */
    private var _sinkIndex: Int32 = -1

    /**
     * 状态更新回调（对应 iOS statusUpdated: () -> Void）。
     * 由 SoftwareVideoComponent 设置，在主线程调用。
     */
    public var onStatusUpdated: () -> Unit = { => }

    /**
     * 帧节拍回调（由 scheduleNextFrame → Timer.once 触发）。
     * 由 SoftwareVideoComponent 设置，在主线程调用。
     */
    public var onNextFrameTick: () -> Unit = { => }

    /** 当前帧 pacing 定时器 */
    private var _pacingTimer: Option<Timer> = None

    public init(
        frameSource!: MediaFrameSource,
        totalDuration!: Float64 = 0.0,
        stallDuration!: Float64 = 1.0,
        lowWaterDuration!: Float64 = 2.0,
        highWaterDuration!: Float64 = 3.0
    ) {
        _frameSource = frameSource
        _totalDuration = totalDuration
        _stallDuration = stallDuration
        _lowWaterDuration = lowWaterDuration
        _highWaterDuration = highWaterDuration

        _sinkIndex = _frameSource.addFrameCallback(
            onFrame: { frame =>
                this._receiveFrame(frame)
            },
            onEnd: { =>
                this._receiveEndOfStream()
            }
        )
    }

    /**
     * 注销 frameSource 回调并取消 pacing timer（组件 aboutToDisappear 时调用）。
     */
    public func detach(): Unit {
        if (_sinkIndex >= 0) {
            _frameSource.removeFrameCallback(_sinkIndex)
            _sinkIndex = -1
        }
        _cancelPacing()
    }

    /**
     * 内部：接收帧（frameSource 的 onFrame 回调）。
     *
     * 对应 iOS addFrames(_:) private func。
     * 此方法在主线程调用（由 spawn 中 launch {} 分派）。
     * 追加帧到 _bufferedFrames，更新 _bufferedUntilTime，通知 onStatusUpdated。
     */
    private func _receiveFrame(frame: BufferedVideoFrame): Unit {
        let newList = ArrayList<BufferedVideoFrame>()
        var i: Int64 = 0
        while (i < _bufferedFrames.size) {
            newList.add(_bufferedFrames[i])
            i = i + 1
        }
        newList.add(frame)
        _bufferedFrames = newList

        let frameEnd = frame.pts + frame.duration
        if (frameEnd > _bufferedUntilTime) {
            _bufferedUntilTime = frameEnd
        }

        onStatusUpdated()
    }

    /**
     * 内部：接收 endOfStream（frameSource 的 onEnd 回调）。
     *
     * 对应 iOS endOfStreamReached() private func。
     * 此方法在主线程调用。
     */
    private func _receiveEndOfStream(): Unit {
        _endOfStream = true
        _isWaitingForLowWater = false
        onStatusUpdated()
    }

    /**
     * 查询当前缓冲状态（P2-230 水位调度核心）。
     *
     * 完整对应 iOS MediaTrackFrameBuffer.status(at timestamp: Double) -> MediaTrackFrameBufferStatus：
     *   1. 检查 endOfStream + 总时长完成
     *   2. 计算 bufferedDuration
     *   3. 清理过期帧（timestamp - 1.0 之前的帧）
     *   4. 若 bufferedDuration < lowWater → requestFramesUntil(currentTime + highWater)
     *   5. 返回 .Buffering / .Full / .Finished
     *
     * @param atTimestamp 当前播放时间戳（秒）
     * @return FrameBufferStatus
     */
    public func status(atTimestamp!: Float64): FrameBufferStatus {
        if (_endOfStream) {
            let finishedAt = if (_bufferedUntilTime > 0.0) { _bufferedUntilTime } else { _totalDuration }
            return FrameBufferStatus.Finished(finishedAt)
        }

        if (_totalDuration > 0.0 && _bufferedUntilTime >= _totalDuration) {
            return FrameBufferStatus.Finished(_bufferedUntilTime)
        }

        let bufferedDuration = if (_bufferedUntilTime > atTimestamp) {
            _bufferedUntilTime - atTimestamp
        } else {
            0.0
        }

        _pruneExpiredFrames(atTimestamp)

        if (bufferedDuration < _lowWaterDuration) {
            let generateUntil = atTimestamp + _highWaterDuration
            _frameSource.requestFramesUntil(untilTimestamp: generateUntil)

            if (bufferedDuration > _stallDuration && !_isWaitingForLowWater) {
                return FrameBufferStatus.Full(atTimestamp + _highWaterDuration)
            } else {
                _isWaitingForLowWater = true
                let p = if (_lowWaterDuration > 0.0) { bufferedDuration / _lowWaterDuration } else { 0.0 }
                let progress = if (p < 0.0) { 0.0 } else if (p > 1.0) { 1.0 } else { p }
                return FrameBufferStatus.Buffering(progress)
            }
        } else {
            _isWaitingForLowWater = false
            let waitUntil = atTimestamp + (bufferedDuration - _lowWaterDuration)
            return FrameBufferStatus.Full(waitUntil)
        }
    }

    /**
     * 取下一帧（渲染循环调用）。
     *
     * 对应 iOS MediaTrackFrameBuffer.takeFrame() -> MediaTrackFrameResult。
     * 从 _bufferedFrames 头部取帧（按 pts 追加顺序）。
     */
    public func takeFrame(): FrameTakeResult {
        if (_bufferedFrames.size == 0) {
            if (_endOfStream) {
                return FrameTakeResult.Finished
            }
            return FrameTakeResult.NoFrames
        }

        let frame = _bufferedFrames[0]
        let newList = ArrayList<BufferedVideoFrame>()
        var i: Int64 = 1
        while (i < _bufferedFrames.size) {
            newList.add(_bufferedFrames[i])
            i = i + 1
        }
        _bufferedFrames = newList

        if (!frame.isValid) {
            return FrameTakeResult.SkipFrame
        }
        return FrameTakeResult.GotFrame(frame)
    }

    /** 是否有可用帧（对应 iOS var hasFrames: Bool） */
    public func hasFrames(): Bool {
        return _bufferedFrames.size > 0
    }

    /**
     * 调度下一帧 pacing（P2-233 回调驱动，非 sleep 忙等）。
     *
     * 对应 iOS softwareVideoApplyQueue 上的帧提交时序。
     * 使用 std.sync.Timer.once(delay:task:) 在精确帧间隔后触发 onNextFrameTick 回调。
     * 通过 launch {} 将回调切回主线程（S-001 合规）。
     *
     * @param frameDurationMs 帧持续时间（毫秒）
     */
    public func scheduleNextFrame(frameDurationMs!: Int64): Unit {
        _cancelPacing()
        let capturedTick = onNextFrameTick
        let delayMs = if (frameDurationMs > 0) { frameDurationMs } else { 66 }
        let timer = Timer.once(delayMs * Duration.millisecond, { =>
            let capturedTickLocal = capturedTick
            launch {
                capturedTickLocal()
            }
        })
        _pacingTimer = Some(timer)
    }

    /** 取消当前帧 pacing 定时器 */
    private func _cancelPacing(): Unit {
        match (_pacingTimer) {
            case Some(timer) =>
                timer.cancel()
                _pacingTimer = None
            case None => ()
        }
    }

    /**
     * 清理早于 (atTimestamp - 1.0) 的过期帧。
     *
     * 对应 iOS status(at:) 中过期帧清理逻辑。
     */
    private func _pruneExpiredFrames(atTimestamp: Float64): Unit {
        let minPts = atTimestamp - 1.0
        let newList = ArrayList<BufferedVideoFrame>()
        var i: Int64 = 0
        while (i < _bufferedFrames.size) {
            let f = _bufferedFrames[i]
            if (f.pts >= minPts) {
                newList.add(f)
            } else {
                // 释放被丢弃帧持有的 PixelMap，避免内存泄漏
                match (f.pixelMap) {
                    case Some(pm) =>
                        pm.release()
                        f.pixelMap = None
                    case None => ()
                }
            }
            i = i + 1
        }
        _bufferedFrames = newList
    }

    /**
     * 请求帧供给源生成指定时间戳之前的帧（直接代理到 frameSource）。
     *
     * 供 SoftwareVideoComponent._renderFrame 调用，
     * 在消费一帧后主动预拉取下一批帧（高水位维持）。
     */
    public func requestFramesUntil(untilTimestamp!: Float64): Unit {
        _frameSource.requestFramesUntil(untilTimestamp: untilTimestamp)
    }

    /** 强制清空缓冲（seek 或 loop restart 时调用） */
    public func clearBuffer(): Unit {
        var i: Int64 = 0
        while (i < _bufferedFrames.size) {
            let f = _bufferedFrames[i]
            match (f.pixelMap) {
                case Some(pm) =>
                    pm.release()
                    f.pixelMap = None
                case None => ()
            }
            i = i + 1
        }
        _bufferedFrames = ArrayList<BufferedVideoFrame>()
        _bufferedUntilTime = 0.0
        _endOfStream = false
        _isWaitingForLowWater = false
        _cancelPacing()
        _frameSource.seek(timestamp: 0.0)
        Hilog.info(0, "CjTelegram", "[MediaTrackFrameBuffer] Buffer cleared")
    }

    /** 当前缓冲帧数量（用于诊断） */
    public func bufferedFrameCount(): Int64 {
        return _bufferedFrames.size
    }

    /** 当前已缓冲时长（秒，用于状态显示） */
    public func bufferedDuration(atTimestamp!: Float64): Float64 {
        if (_bufferedUntilTime > atTimestamp) {
            return _bufferedUntilTime - atTimestamp
        }
        return 0.0
    }
}
