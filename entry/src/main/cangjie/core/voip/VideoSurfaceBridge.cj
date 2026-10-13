package ohos_app_cangjie_entry.core.voip

// ArkTS → Cangjie → native napi 桥：视频通话页的 ArkTS XComponent 在 onLoad 时把
// 自己的 surfaceId（十进制字符串）交过来，本模块解析后绑定到原生解码器，让 HW
// 解码器把帧 GPU 直渲到该 surface（零 CPU 拷贝，绕过 BGRA/PixelMap）。sid="0"/""
// 表示清除（页面销毁时调）。
//
// 导出方式沿用 index.cj / AppStartup.cj 的 JSModule.registerModule 模式，ArkTS 侧
// `import { setVideoCallSurface } from 'libohos_app_cangjie_entry.so'` 调用。

import ohos.ark_interop.JSModule
import ohos.ark_interop.JSContext
import ohos.ark_interop.JSCallInfo
import ohos.ark_interop.JSValue
import std.convert.*
import kit.PerformanceAnalysisKit.Hilog

func setVideoCallSurface(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    try {
        let sidStr = callInfo[0].toString()
        var sid: UInt64 = 0
        if (sidStr.size > 0 && sidStr != "0") {
            sid = UInt64.parse(sidStr)
        }
        TgCallsLib.setRemoteVideoSurface(sid)
        Hilog.info(0, "CjTelegram", "[VideoSurfaceBridge] setVideoCallSurface sid=${sid}")
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[VideoSurfaceBridge] setVideoCallSurface failed: ${e}")
    }
    return runtime.undefined().toJSValue()
}

// sid 匹配清除：每个 shell 销毁时带上自己的 sid，只有仍是当前绑定时才真正清。
// 防双 push VideoCallScreen 时旧 shell 迟到的 onDisAppear 误清存活页的 surface。
func clearVideoCallSurface(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    try {
        let sidStr = callInfo[0].toString()
        var sid: UInt64 = 0
        if (sidStr.size > 0 && sidStr != "0") {
            sid = UInt64.parse(sidStr)
        }
        TgCallsLib.clearRemoteVideoSurfaceIf(sid)
        Hilog.info(0, "CjTelegram", "[VideoSurfaceBridge] clearVideoCallSurface sid=${sid}")
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[VideoSurfaceBridge] clearVideoCallSurface failed: ${e}")
    }
    return runtime.undefined().toJSValue()
}

let VIDEO_SURFACE_MODULE = JSModule.registerModule {
    runtime, exports =>
    exports["setVideoCallSurface"] = runtime.function(setVideoCallSurface).toJSValue()
    exports["clearVideoCallSurface"] = runtime.function(clearVideoCallSurface).toJSValue()
}
