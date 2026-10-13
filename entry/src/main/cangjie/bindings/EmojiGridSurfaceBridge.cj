package ohos_app_cangjie_entry.bindings

// ArkTS → 仓颉桥：ChatRoomPage.ets 壳里的 XComponent 在 onLoad 时把 surfaceId
// （十进制字符串）交过来，绑定给原生 emoji 网格合成器；"0"/"" 表示解绑。
// 导出模式与 VideoSurfaceBridge 相同（JSModule.registerModule）。

import ohos.ark_interop.JSModule
import ohos.ark_interop.JSContext
import ohos.ark_interop.JSCallInfo
import ohos.ark_interop.JSValue
import std.convert.*
import kit.PerformanceAnalysisKit.Hilog

func setEmojiGridSurface(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    try {
        let sidStr = callInfo[0].toString()
        var sid: UInt64 = 0
        if (sidStr.size > 0 && sidStr != "0") {
            sid = UInt64.parse(sidStr)
        }
        emojiGridSurfaceBind(sid)
        // 第二/三参数（可选）：surface 像素尺寸，供 native 设 buffer geometry。
        if (callInfo.count > 2) {
            let w = Int64.parse(callInfo[1].toString())
            let h = Int64.parse(callInfo[2].toString())
            emojiGridSurfaceSize(w, h)
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[EmojiGridSurfaceBridge] bind failed: ${e}")
    }
    return runtime.undefined().toJSValue()
}

let EMOJI_GRID_SURFACE_MODULE = JSModule.registerModule {
    runtime, exports =>
    exports["setEmojiGridSurface"] = runtime.function(setEmojiGridSurface).toJSValue()
}
