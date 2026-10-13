package ohos_app_cangjie_entry.services

/**
 * VideoThumbnailBridge — 视频首帧缩略图（ArkTS AVImageGenerator + ImagePacker，
 * ets/interop/impls/VideoThumbnailImpl.ets）。iOS 视频/圆形视频发送时都会带一张 JPEG
 * 缩略图（VideoMessageCameraScreen.swift:2007-2013 → previewRepresentations → thumb），
 * 否则对端在下载前看不到预览。仓颉层 ImagePacker 需要 ResourceManager 上下文，故放 ArkTS。
 */

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*

public class VideoProbe {
    public var jpeg: Array<Byte> = Array<Byte>(0, repeat: 0)
    /** 套旋转后的显示尺寸（0 = 未知） */
    public var width: Int32 = 0
    public var height: Int32 = 0
    public var durationMs: Int64 = 0
    public init() {}
}

public class VideoThumbnailBridge {
    /** 生成首帧 JPEG，返回字节；失败返回空数组。仅限非 UI 线程。 */
    public static func firstFrameJpeg(videoPath: String, maxSide: Int32): Array<Byte> {
        return probe(videoPath, maxSide).jpeg
    }

    /**
     * 首帧 JPEG + 容器元数据（AVMetadataExtractor：宽高套旋转、时长）。
     * 仓颉 extractMp4Metadata 只读 tkhd，竖拍视频会拿到 1920x1080 而非 1080x1920。仅限非 UI 线程。
     */
    public static func probe(videoPath: String, maxSide: Int32): VideoProbe {
        let vp = VideoProbe()
        let arg = "{\"path\":\"" + videoPath + "\",\"maxSide\":${maxSide}}"
        let res = arkCallSync("video.thumbnail", arg, 8000)
        if (res.size == 0) {
            Hilog.info(0, "CjTelegram", "[VideoThumb] timeout")
            return vp
        }
        try {
            let obj = JsonParser.parseObject(res)
            if (!obj.getBool("ok")) { return vp }
            vp.width = Int32(obj.getInt("vw"))
            vp.height = Int32(obj.getInt("vh"))
            vp.durationMs = obj.getInt("durMs")
            let path = obj.getString("path")
            if (path.size == 0) { return vp }
            let file = FileIo.open(path, mode: 0o0)
            let size = FileIo.stat(path).size
            let buf = Array<Byte>(size, repeat: 0)
            let _ = FileIo.read(file.fd, buf)
            FileIo.close(file)
            try { FileIo.unlink(path) } catch (_e: Exception) {}
            vp.jpeg = buf
            Hilog.info(0, "CjTelegram", "[VideoThumb] ${buf.size} bytes ${obj.getInt("w")}x${obj.getInt("h")} video=${vp.width}x${vp.height} ${vp.durationMs}ms")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[VideoThumb] failed: ${e}")
        }
        return vp
    }
}
