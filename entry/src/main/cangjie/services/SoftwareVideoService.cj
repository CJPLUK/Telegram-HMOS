package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.MediaKit.*
import kit.ImageKit.PixelMap
import kit.CoreFileKit.*
import ohos.business_exception.BusinessException
import std.collection.ArrayList

/**
 * SoftwareVideoService — 软件视频解码/帧供给服务
 *
 * 对应 iOS submodules/SoftwareVideo/Sources/SampleBufferPool.swift 和
 *         SoftwareVideoLayerFrameManager.swift
 *
 * iOS 实现说明：
 *   - SampleBufferPool 管理 AVSampleBufferDisplayLayer 对象池（take/release/clear）
 *   - SoftwareVideoLayerFrameManager 持有 softwareVideoApplyQueue + softwareVideoWorkers(3 threads)
 *   - 帧通过 AVSampleBufferDisplayLayer 直接渲染（依赖 Metal/VideoToolbox 硬件路径）
 *
 * P2-230 新增：MediaTrackFrameBuffer 水位调度（低/高水位阈值驱动帧请求），见 MediaTrackFrameBuffer.cj
 * P2-233 新增：AnimatedImageFrameSource（ImageSource.getFrameCount/getDelayTimeList），见 MediaTrackFrameBuffer.cj
 * P2-234 新增：MediaFrameSource 接口 + VideoFileFrameSource（WholeFile/Streamable），见 MediaTrackFrameBuffer.cj
 *
 * 鸿蒙平台降级说明（deferred — 平台缺口）：
 *   HarmonyOS/Cangjie 无 FFmpeg 软解 API 及 AVSampleBufferDisplayLayer 等价物。
 *   平台提供的软解能力为 AVCodec 仅限 MPEG2/MPEG4/H.263/H.264（参见 AVCodec支持的格式）。
 *   对于 Telegram 贴纸/动图场景（GIF/WebP），使用 ImageSource.getFrameCount + getDelayTimeList
 *   提取动图各帧（真实 API，非 defer），等价于 iOS SampleBufferPool 的帧缓冲池概念。
 *   对于视频文件场景（MP4/MOV），使用 AVImageGenerator.fetchFrameByTime 提取指定时间帧。
 *
 *   具体降级策略：
 *   1. SoftwareVideoFrame 代替 iOS AVSampleBufferDisplayLayer 帧封装
 *   2. SoftwareVideoFramePool 代替 iOS Atomic<[AVSampleBufferDisplayLayer]> 对象池
 *   3. AVImageGenerator.fetchFrameByTime 代替 iOS AVSampleBufferDisplayLayer 渲染路径（视频）
 *   4. ImageSource.createPixelMap(index:) 代替 iOS AVSampleBufferDisplayLayer 渲染路径（动图）
 *
 * FFmpeg Deferred 说明：
 *   iOS SoftwareVideoSource 通过 FFMpegAVFormatContext.readFrame() 逐包解码，
 *   支持 WebM/VP9/H.264 等格式（FFMpegBinding 绑定）。
 *   鸿蒙暂无 FFmpeg 绑定，仅支持 AVImageGenerator 支持的格式（MP4/MOV/AVI）及
 *   ImageSource 支持的静/动图格式（JPG/PNG/GIF/WebP）。
 *   WebM/VP9 等格式在当前路径下无法解码，待 FFmpeg 移植完成后补充。
 *
 * MTProto 说明（N/A）：
 *   软件视频解码为本地能力，不涉及任何 TL 方法或网络请求。
 *   数据来源为已下载到本地的视频文件路径，由上层（FileDownloadService）负责下载。
 */

// ─────────────────────────────────────────────────────────────────
// 帧数据模型
// ─────────────────────────────────────────────────────────────────

/**
 * 单帧数据
 *
 * 对应 iOS AVSampleBufferDisplayLayer 持有的 CMSampleBuffer 帧数据。
 * 鸿蒙用 PixelMap 替代 CMSampleBuffer 作为帧表示。
 */
public class SoftwareVideoFrame {
    /** 帧的 PixelMap 数据（可直接传给 ArkUI Image 组件） */
    public var pixelMap: Option<PixelMap> = None
    /** 帧时间戳（微秒，对应 iOS CMTime） */
    public var timestampUs: Int64 = 0
    /** 帧宽度（像素） */
    public var width: Int32 = 0
    /** 帧高度（像素） */
    public var height: Int32 = 0
    /** 帧是否有效（提取成功） */
    public var isValid: Bool = false

    public init() {}
}

// ─────────────────────────────────────────────────────────────────
// 帧池（对应 iOS SampleBufferPool 的 Atomic pool）
// ─────────────────────────────────────────────────────────────────

/**
 * SoftwareVideoFramePool — 帧对象池
 *
 * 对应 iOS SampleBufferPool.swift 中的 pool 变量（Atomic<[AVSampleBufferDisplayLayer]>）：
 *   - takeSampleBufferLayer() → acquireFrame()
 *   - 归还层时 enqueue 回 pool → releaseFrame()
 *   - clearSampleBufferLayerPoll() → clear()
 *
 * 鸿蒙实现用 ArrayList<SoftwareVideoFrame> 复用帧对象，避免频繁分配。
 * 最大池容量对应 iOS 典型使用时的 3 个 softwareVideoWorkers 线程数量
 * （iOS SoftwareVideoLayerFrameManager.swift: ThreadPool(threadCount: 3, threadPriority: 0.2)）。
 *
 * P2-230：池容量上限与水位参数的关系：
 *   池容量 maxSize=3 对应 iOS 3 个 worker 线程各持有一帧的最大并行量。
 *   更多并行帧通过 MediaTrackFrameBuffer 的 lowWaterDuration/highWaterDuration 水位参数控制。
 */
public class SoftwareVideoFramePool {
    private var _pool: ArrayList<SoftwareVideoFrame> = ArrayList<SoftwareVideoFrame>()
    /** 最大池容量（对应 iOS softwareVideoWorkers threadCount: 3） */
    private let _maxSize: Int32 = 3

    public init() {}

    /**
     * 从池中取出一帧（或新建）。
     *
     * 对应 iOS takeSampleBufferLayer()：从 pool.modify 中 removeLast，
     * 若 pool 为空则创建新 SampleBufferLayerImpl。
     */
    public func acquireFrame(): SoftwareVideoFrame {
        if (_pool.size > 0) {
            let lastIdx = _pool.size - 1
            let frame = _pool[lastIdx]
            let newPool = ArrayList<SoftwareVideoFrame>()
            var i: Int64 = 0
            while (i < lastIdx) {
                newPool.add(_pool[i])
                i = i + 1
            }
            _pool = newPool
            return frame
        }
        return SoftwareVideoFrame()
    }

    /**
     * 将使用完的帧归还到池中。
     *
     * 对应 iOS SampleBufferLayer.deinit 调用的 enqueue 闭包：
     * flushAndRemoveImage, setAffineTransform(.identity), 然后 pool.modify append。
     * 非模拟器（#if targetEnvironment(simulator) #else）才真正归还。
     */
    public func releaseFrame(frame: SoftwareVideoFrame): Unit {
        if (_pool.size < Int64(_maxSize)) {
            frame.pixelMap = None
            frame.timestampUs = 0
            frame.isValid = false
            _pool.add(frame)
        }
    }

    /**
     * 清空帧池。
     *
     * 对应 iOS clearSampleBufferLayerPoll()：pool.modify { _ in return [] }
     */
    public func clear(): Unit {
        _pool = ArrayList<SoftwareVideoFrame>()
        Hilog.info(0, "CjTelegram", "[SoftwareVideo] Frame pool cleared")
    }

    /** 当前池中可用帧数量 */
    public func poolSize(): Int64 {
        return _pool.size
    }
}

// ─────────────────────────────────────────────────────────────────
// 服务单例
// ─────────────────────────────────────────────────────────────────

private var _softwareVideoServiceInstance: Option<SoftwareVideoService> = None

/**
 * 获取 SoftwareVideoService 单例
 */
public func getSoftwareVideoService(): SoftwareVideoService {
    match (_softwareVideoServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = SoftwareVideoService()
            _softwareVideoServiceInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────────────────────────
// SoftwareVideoService
// ─────────────────────────────────────────────────────────────────

/**
 * SoftwareVideoService — 软件视频帧提取服务
 *
 * 职责：
 * 1. 维护 SoftwareVideoFramePool（帧对象池，对应 iOS SampleBufferPool 的 pool）
 * 2. 通过 AVImageGenerator 从本地视频文件提取指定时间点的帧
 *    （对应 iOS softwareVideoWorkers 线程池在 softwareVideoApplyQueue 上异步渲染帧）
 * 3. 提供帧时间戳步进（计算下一帧时间，驱动动画播放）
 * 4. （P2-230）水位感知帧预取：prefetchFramesForWatermark 方法
 *
 * 调用链（完整）：
 *   SoftwareVideoComponent._initFrameBufferAndStart()
 *     → MediaTrackFrameBuffer.requestFramesUntil()
 *       → VideoFileFrameSource.requestFramesUntil()
 *         → SoftwareVideoService.extractFrame(localPath, timeUs)
 *           → AVImageGenerator.fetchFrameByTime(timeUs, queryOption, param)
 *             → PixelMap 存入 SoftwareVideoFrame 返回
 *
 * AnimatedImage 调用链：
 *   SoftwareVideoComponent._initFrameBufferAndStart()
 *     → MediaTrackFrameBuffer.requestFramesUntil()
 *       → AnimatedImageFrameSource.requestFramesUntil()
 *         → ImageSource.createPixelMap(options: DecodingOptions(index: frameIdx))
 *           → BufferedVideoFrame 回调到 MediaTrackFrameBuffer._receiveFrame()
 *
 * MTProto 说明（N/A）：本服务不含任何 TL 方法，无需 MTProtoClient.send()。
 */
public class SoftwareVideoService {
    /** 帧对象池（对应 iOS SampleBufferPool 的 Atomic pool） */
    public var framePool: SoftwareVideoFramePool = SoftwareVideoFramePool()
    /**
     * 最近提取的有效帧（供组件 build() 中通过非@State私有方法读取渲染）。
     * 存储在 service 而非 @Component @State 中，避免 Option<PixelMap> 触发宏展开歧义。
     */
    public var lastFrame: SoftwareVideoFrame = SoftwareVideoFrame()

    public init() {}

    /**
     * 从本地视频文件提取指定时间点的帧（AVImageGenerator 路径）。
     *
     * 对应 iOS softwareVideoApplyQueue 上异步将解码帧送入 AVSampleBufferDisplayLayer。
     * 鸿蒙使用 AVImageGenerator.fetchFrameByTime 完成帧提取（同步调用）。
     *
     * 调用方应在 spawn {} 中调用此方法（VideoFileFrameSource.requestFramesUntil 内部），
     * 避免阻塞主线程。
     *
     * @param localFilePath 本地视频文件路径（沙箱绝对路径，不含 file:// 前缀）
     * @param timeUs        提取时间点（微秒，对应 iOS CMTime）
     * @param targetWidth   目标帧宽度（-1 表示原始尺寸），对应 iOS CGSize
     * @param targetHeight  目标帧高度（-1 表示原始尺寸）
     * @return 包含 PixelMap 的帧对象；isValid=false 表示提取失败
     */
    public func extractFrame(
        localFilePath: String,
        timeUs: Int64,
        targetWidth!: Int32 = -1,
        targetHeight!: Int32 = -1
    ): SoftwareVideoFrame {
        let frame = framePool.acquireFrame()
        frame.timestampUs = timeUs
        frame.isValid = false

        if (localFilePath.size == 0) {
            Hilog.info(0, "CjTelegram", "[SoftwareVideo] Empty file path")
            return frame
        }

        try {
            let generator = createAVImageGenerator()
            let fileFs = FileIo.open(localFilePath, mode: 0o0)
            generator.fdSrc = AVFileDescriptor(fileFs.fd)
            FileIo.close(fileFs)

            let param = PixelMapParams(width: targetWidth, height: targetHeight)
            let queryOption = AVImageQueryOptions.AvImageQueryClosestSync
            let pixelMap = generator.fetchFrameByTime(timeUs, queryOption, param)
            generator.release()

            frame.pixelMap = Some(pixelMap)
            frame.width = targetWidth
            frame.height = targetHeight
            frame.isValid = true
            lastFrame = frame

            Hilog.info(0, "CjTelegram", "[SoftwareVideo] Frame extracted at timeUs=${timeUs}")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[SoftwareVideo] Extract failed: ${e.message}")
            frame.isValid = false
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[SoftwareVideo] Extract failed (unknown error)")
            frame.isValid = false
        }

        return frame
    }

    /**
     * 计算下一帧时间戳（微秒）。
     *
     * 对应 iOS softwareVideoApplyQueue 上帧序列推进逻辑。
     *
     * @param currentTimeUs 当前帧时间（微秒）
     * @param fps           视频帧率（帧/秒）
     * @param durationUs    视频总时长（微秒），用于循环播放边界
     * @return 下一帧时间戳（微秒）；到达末尾时返回 0（循环）
     */
    public func nextFrameTimeUs(currentTimeUs: Int64, fps: Float64, durationUs: Int64): Int64 {
        let frameDurationUs: Int64 = if (fps > 0.0) {
            Int64(1_000_000.0 / fps)
        } else {
            33_333  // 30fps 默认
        }
        let next = currentTimeUs + frameDurationUs
        if (durationUs > 0 && next >= durationUs) {
            return 0
        }
        return next
    }

    /**
     * 清空帧池并释放所有缓存帧。
     *
     * 对应 iOS clearSampleBufferLayerPoll()。
     * 在组件销毁（aboutToDisappear）或内存压力时调用。
     */
    public func clearFramePool(): Unit {
        framePool.clear()
        match (lastFrame.pixelMap) {
            case Some(pm) =>
                pm.release()
                lastFrame.pixelMap = None
            case None => ()
        }
        lastFrame = SoftwareVideoFrame()
        Hilog.info(0, "CjTelegram", "[SoftwareVideo] Service frame pool cleared")
    }
}
