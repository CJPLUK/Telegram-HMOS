package ohos_app_cangjie_entry.services

/**
 * RoundVideoBridge — 圆形视频消息离线转码（ArkTS 反转 video.square → cpp/round_video_transcoder.cpp）。
 * 对位 iOS VideoMessageCameraScreen 的 400×400 方形输出：OHOS 相机没有 1:1 VideoProfile，
 * 录完后中心裁方 + 缩放 + H.264 重编码，音频 AAC 直通。仅限非 UI 线程。
 */

import kit.PerformanceAnalysisKit.Hilog

public class RoundVideoResult {
    public var ok: Bool = false
    public var width: Int32 = 0
    public var height: Int32 = 0
    public var durationMs: Int64 = 0
    public var error: String = ""
    public init() {}
}

public class RoundVideoBridge {
    /** rotation 仅在容器无旋转元数据时生效（AVRecorder 已按相机方向写入时被忽略） */
    public static func squareVideo(inPath: String, outPath: String, side: Int32, rotation: Int32): RoundVideoResult {
        return run("{\"inPath\":\"" + inPath + "\",\"outPath\":\"" + outPath +
            "\",\"side\":${side},\"rotation\":${rotation},\"mode\":\"square\"}")
    }

    /** 等比缩放到长边 ≤ maxSide 并按旋转矩阵摆正（普通视频发送，对位 iOS 默认转码），音频直通 */
    public static func fitVideo(inPath: String, outPath: String, maxSide: Int32, bitrate: Int64): RoundVideoResult {
        return run("{\"inPath\":\"" + inPath + "\",\"outPath\":\"" + outPath +
            "\",\"side\":${maxSide},\"rotation\":0,\"mode\":\"fit\",\"bitrate\":${bitrate}}")
    }

    private static func run(arg: String): RoundVideoResult {
        let r = RoundVideoResult()
        let res = arkCallSync("video.square", arg, 300000)
        if (res.size == 0) {
            r.error = "timeout"
            Hilog.info(0, "CjTelegram", "[RoundVideo] timeout")
            return r
        }
        try {
            let obj = JsonParser.parseObject(res)
            r.ok = obj.getBool("ok")
            r.width = Int32(obj.getInt("width"))
            r.height = Int32(obj.getInt("height"))
            r.durationMs = obj.getInt("durationMs")
            r.error = obj.getString("error")
        } catch (e: Exception) {
            r.ok = false
            r.error = "parse: ${e}"
        }
        if (!r.ok) {
            Hilog.info(0, "CjTelegram", "[RoundVideo] failed: ${r.error}")
        }
        return r
    }
}
