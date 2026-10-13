package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.sync.*

foreign func tg_lottie_create(data: CPointer<UInt8>, size: UInt64, cacheKey: CString): CPointer<Unit>
foreign func tg_lottie_frame_count(handle: CPointer<Unit>): UInt32
foreign func tg_lottie_frame_rate(handle: CPointer<Unit>): Float64
foreign func tg_lottie_render(
    handle: CPointer<Unit>, frame: UInt32, width: UInt32, height: UInt32,
    output: CPointer<UInt8>, outputSize: UInt64
): Int32
foreign func tg_lottie_destroy(handle: CPointer<Unit>): Unit

public class TelegramLottieFrames {
    public var frames: ArrayList<Array<UInt8>> = ArrayList<Array<UInt8>>()
    public var frameDurationMs: Int32 = 33
    public var sourceFrameCount: UInt32 = 0
    public var sourceFrameRate: Float64 = 0.0
    public var success: Bool = false

    public init() {}
}

/**
 * A persistent rlottie animation, matching iOS' LottieInstance lifetime.
 *
 * The old renderTgs() helper creates an animation, rasterizes every frame and
 * destroys it in one blocking call. Chat playback uses this session instead:
 * callers request one frame at a time and keep only a rolling two-frame
 * window. The per-session monitor makes close() safe while a background frame
 * render is in flight.
 */
public class TelegramLottieSession {
    private let monitor = Monitor()
    private var animation: CPointer<Unit> = CPointer<Unit>()
    private let rasterSize: Int32
    private let key: String
    public let frameCount: Int64
    public let frameRate: Float64
    public let frameDurationMs: Int32

    public init(
        animation: CPointer<Unit>, rasterSize: Int32, key: String,
        frameCount: Int64, frameRate: Float64
    ) {
        this.animation = animation
        this.rasterSize = rasterSize
        this.key = key
        this.frameCount = frameCount
        this.frameRate = frameRate
        let effectiveRate = if (frameRate > 0.0) { frameRate } else { 30.0 }
        let duration = Int32(1000.0 / effectiveRate)
        this.frameDurationMs = if (duration < 16) { 16 } else { duration }
    }

    public func renderFrame(index: Int64): Option<Array<UInt8>> {
        synchronized(this.monitor) {
            if (this.animation.isNull() || this.frameCount <= 0 || this.rasterSize <= 0) {
                return None<Array<UInt8>>
            }
            var normalized = index % this.frameCount
            if (normalized < 0) { normalized = normalized + this.frameCount }
            let outputSize = Int64(this.rasterSize) * Int64(this.rasterSize) * 4
            let pixels = Array<UInt8>(outputSize, repeat: 0)
            var rendered: Int32 = 0
            unsafe {
                let pixelsHandle = acquireArrayRawData(pixels)
                rendered = tg_lottie_render(
                    this.animation, UInt32(normalized), UInt32(this.rasterSize), UInt32(this.rasterSize),
                    CPointer<UInt8>(pixelsHandle.pointer), UInt64(outputSize)
                )
                releaseArrayRawData(pixelsHandle)
            }
            return if (rendered != 0) { Some(pixels) } else { None<Array<UInt8>> }
        }
    }

    public func close(): Unit {
        synchronized(this.monitor) {
            if (!this.animation.isNull()) {
                unsafe { tg_lottie_destroy(this.animation) }
                this.animation = CPointer<Unit>()
                Hilog.info(0, "CjTelegram", "[TelegramLottieSession] closed key=${this.key}")
            }
        }
    }
}

private var _telegramLottieNative: Option<TelegramLottieNative> = None

public func getTelegramLottieNative(): TelegramLottieNative {
    match (_telegramLottieNative) {
        case Some(value) => return value
        case None =>
            let value = TelegramLottieNative()
            _telegramLottieNative = Some(value)
            return value
    }
}

public class TelegramLottieNative {
    public init() {}

    public func openTgs(
        data: Array<UInt8>, cacheKey: String, size: Int32
    ): Option<TelegramLottieSession> {
        if (data.size == 0 || size <= 0) { return None<TelegramLottieSession> }

        let cKey = unsafe { LibC.mallocCString(cacheKey) }
        var animation = CPointer<Unit>()
        unsafe {
            let dataHandle = acquireArrayRawData(data)
            animation = tg_lottie_create(CPointer<UInt8>(dataHandle.pointer), UInt64(data.size), cKey)
            releaseArrayRawData(dataHandle)
            LibC.free(cKey)
        }
        if (animation.isNull()) {
            Hilog.info(0, "CjTelegram", "[TelegramLottieNative] stream parse failed key=${cacheKey}")
            return None<TelegramLottieSession>
        }

        var frameCount: UInt32 = 0
        var frameRate: Float64 = 0.0
        unsafe {
            frameCount = tg_lottie_frame_count(animation)
            frameRate = tg_lottie_frame_rate(animation)
        }
        if (frameCount == 0) {
            unsafe { tg_lottie_destroy(animation) }
            return None<TelegramLottieSession>
        }
        Hilog.info(0, "CjTelegram",
            "[TelegramLottieNative] stream opened frames=${frameCount} fps=${frameRate} key=${cacheKey}")
        return Some(TelegramLottieSession(
            animation, size, cacheKey, Int64(frameCount), frameRate))
    }

    public func renderTgs(data: Array<UInt8>, cacheKey: String, size: Int32, maxFrames!: Int32 = 60): TelegramLottieFrames {
        let result = TelegramLottieFrames()
        if (data.size == 0 || size <= 0) { return result }

        let cKey = unsafe { LibC.mallocCString(cacheKey) }
        var animation = CPointer<Unit>()
        unsafe {
            let dataHandle = acquireArrayRawData(data)
            animation = tg_lottie_create(CPointer<UInt8>(dataHandle.pointer), UInt64(data.size), cKey)
            releaseArrayRawData(dataHandle)
            LibC.free(cKey)
        }
        if (animation.isNull()) {
            Hilog.info(0, "CjTelegram", "[TelegramLottieNative] TGS parse failed key=${cacheKey}")
            return result
        }

        unsafe {
            let nativeCount = tg_lottie_frame_count(animation)
            let frameRate = tg_lottie_frame_rate(animation)
            result.sourceFrameCount = nativeCount
            result.sourceFrameRate = frameRate
            let cappedCount = if (nativeCount > UInt32(maxFrames)) { UInt32(maxFrames) } else { nativeCount }
            let step = if (cappedCount > 0 && nativeCount > cappedCount) {
                Float64(nativeCount) / Float64(cappedCount)
            } else { 1.0 }
            let outputSize = Int64(size) * Int64(size) * 4
            var index: UInt32 = 0
            while (index < cappedCount) {
                let pixels = Array<UInt8>(outputSize, repeat: 0)
                let pixelsHandle = acquireArrayRawData(pixels)
                let sourceFrame = UInt32(Float64(index) * step)
                let rendered = tg_lottie_render(
                    animation, sourceFrame, UInt32(size), UInt32(size),
                    CPointer<UInt8>(pixelsHandle.pointer), UInt64(outputSize)
                )
                releaseArrayRawData(pixelsHandle)
                if (rendered == 0) { break }
                result.frames.add(pixels)
                index = index + 1
            }
            tg_lottie_destroy(animation)
            let effectiveRate = if (frameRate > 0.0) { frameRate / step } else { 30.0 }
            result.frameDurationMs = Int32(1000.0 / effectiveRate)
        }
        result.success = result.frames.size > 0
        Hilog.info(0, "CjTelegram",
            "[TelegramLottieNative] rendered=${result.frames.size} sourceFrames=${result.sourceFrameCount} sourceFps=${result.sourceFrameRate} frameMs=${result.frameDurationMs} key=${cacheKey}")
        return result
    }
}

foreign func tg_delta_encode_runs(
    prev: CPointer<UInt8>, cur: CPointer<UInt8>, len: UInt64,
    out: CPointer<UInt8>, outCap: UInt64
): Int64

/**
 * delta+RLE 编码下沉 native：输出与 encodeRunsInto 字节级一致。
 * out 容量按最坏情况给（len + 8×段数上界；调用方给 len + 4096 即可，
 * 实际最坏是整帧全字面 = 8 + len）。返回写入字节数，-1 = 容量不足。
 */
public func nativeEncodeDeltaRuns(
    prev: Array<UInt8>, cur: Array<UInt8>, out: Array<UInt8>
): Int64 {
    var written: Int64 = -1
    unsafe {
        let prevHandle = acquireArrayRawData(prev)
        let curHandle = acquireArrayRawData(cur)
        let outHandle = acquireArrayRawData(out)
        written = tg_delta_encode_runs(
            CPointer<UInt8>(prevHandle.pointer), CPointer<UInt8>(curHandle.pointer),
            UInt64(cur.size),
            CPointer<UInt8>(outHandle.pointer), UInt64(out.size))
        releaseArrayRawData(outHandle)
        releaseArrayRawData(curHandle)
        releaseArrayRawData(prevHandle)
    }
    return written
}
