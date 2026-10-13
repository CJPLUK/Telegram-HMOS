package ohos_app_cangjie_entry.services

/**
 * CameraPreviewBridge — 相机取景 XComponent surface（ets/interop/impls/CameraPreviewImpl.ets）。
 * CameraPage.ets 壳把 XComponent 垫在仓颉页下方，onLoad 后发布 surfaceId；仓颉 initCamera
 * 前轮询拿到它，作为 PreviewOutput 的 surface（替代 ImageReceiver JPEG 轮询预览）。
 */

import std.sync.*
import std.time.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.interop.callArk

public class CameraPreviewBridge {
    /** 等 XComponent surface 就绪（仅限非 UI 线程）；超时返回空串 → 调用方退回 ImageReceiver 预览 */
    public static func waitSurfaceId(timeoutMs: Int64): String {
        var waited: Int64 = 0
        while (waited <= timeoutMs) {
            let res = arkCallSync("cameraPreview.surfaceId", "{}", 500)
            if (res.size > 0) {
                try {
                    let sid = JsonParser.parseObject(res).getString("surfaceId")
                    if (sid.size > 0) { return sid }
                } catch (_e: Exception) {}
            }
            sleep(Duration.millisecond * 100)
            waited += 100
        }
        Hilog.info(0, "CjTelegram", "[CameraPreview] surfaceId not ready after ${timeoutMs}ms")
        return ""
    }

    public static func pushLayout(round: Bool, square: Bool): Unit {
        callArk("cameraPreview.layout", "{\"round\":${round},\"square\":${square}}")
    }
}
