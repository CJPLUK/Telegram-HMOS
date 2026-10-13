package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog
import std.sync.*

foreign func tg_video_sticker_create(path: CString): CPointer<Unit>
foreign func tg_video_sticker_frame_count(handle: CPointer<Unit>): UInt32
foreign func tg_video_sticker_frame_rate(handle: CPointer<Unit>): Float64
foreign func tg_video_sticker_render_frame(
    handle: CPointer<Unit>, frame: UInt32, width: UInt32, height: UInt32,
    output: CPointer<UInt8>, outputSize: UInt64
): Int32
foreign func tg_video_sticker_destroy(handle: CPointer<Unit>): Unit

/** Persistent VP9 decoder used by the chat's rolling two-frame window. */
public class TelegramVideoStickerSession {
    private let monitor = Monitor()
    private var video: CPointer<Unit>
    private let rasterSize: Int32
    public let frameCount: Int64
    public let frameRate: Float64
    public let frameDurationMs: Int32

    public init(
        video: CPointer<Unit>, rasterSize: Int32,
        frameCount: Int64, frameRate: Float64
    ) {
        this.video = video
        this.rasterSize = rasterSize
        this.frameCount = frameCount
        this.frameRate = frameRate
        let effectiveRate = if (frameRate > 0.0) { frameRate } else { 30.0 }
        let duration = Int32(1000.0 / effectiveRate)
        this.frameDurationMs = if (duration < 16) { 16 } else { duration }
    }

    public func renderFrame(index: Int64): Option<Array<UInt8>> {
        synchronized(this.monitor) {
            if (this.video.isNull() || this.frameCount <= 0 || this.rasterSize <= 0) {
                return None<Array<UInt8>>
            }
            var normalized = index % this.frameCount
            if (normalized < 0) { normalized = normalized + this.frameCount }
            let outputSize = Int64(this.rasterSize) * Int64(this.rasterSize) * 4
            let pixels = Array<UInt8>(outputSize, repeat: 0)
            var rendered: Int32 = 0
            unsafe {
                let pixelsHandle = acquireArrayRawData(pixels)
                rendered = tg_video_sticker_render_frame(
                    this.video, UInt32(normalized), UInt32(this.rasterSize), UInt32(this.rasterSize),
                    CPointer<UInt8>(pixelsHandle.pointer), UInt64(outputSize)
                )
                releaseArrayRawData(pixelsHandle)
            }
            return if (rendered != 0) { Some(pixels) } else { None<Array<UInt8>> }
        }
    }

    public func close(): Unit {
        synchronized(this.monitor) {
            if (!this.video.isNull()) {
                unsafe { tg_video_sticker_destroy(this.video) }
                this.video = CPointer<Unit>()
            }
        }
    }
}

public func openTelegramVideoSticker(
    path: String, rasterSize: Int32
): Option<TelegramVideoStickerSession> {
    if (path.isEmpty() || rasterSize <= 0) { return None<TelegramVideoStickerSession> }
    let realPath = if (path.startsWith("file://")) { path[7..] } else { path }
    let cPath = unsafe { LibC.mallocCString(realPath) }
    var video = CPointer<Unit>()
    unsafe {
        video = tg_video_sticker_create(cPath)
        LibC.free(cPath)
    }
    if (video.isNull()) { return None<TelegramVideoStickerSession> }
    var frameCount: UInt32 = 0
    var frameRate: Float64 = 0.0
    unsafe {
        frameCount = tg_video_sticker_frame_count(video)
        frameRate = tg_video_sticker_frame_rate(video)
    }
    if (frameCount == 0) {
        unsafe { tg_video_sticker_destroy(video) }
        return None<TelegramVideoStickerSession>
    }
    Hilog.info(0, "CjTelegram",
        "[VideoStickerPerf] stream opened frames=${frameCount} fps=${frameRate} raster=${rasterSize}")
    return Some(TelegramVideoStickerSession(
        video, rasterSize, Int64(frameCount), frameRate))
}
