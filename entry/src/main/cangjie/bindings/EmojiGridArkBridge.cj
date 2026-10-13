package ohos_app_cangjie_entry.bindings

// Phase1：ArkTS 表情网格(ImageAnimator)的数据/事件桥。
//
// 数据向（ArkTS 拉）：`import { getEmojiGridRows } from 'libohos_app_cangjie_entry.so'`
//   → 活跃 EmojiPicker 注册的 provider 输出行表 JSON（无面板时空串）。
// 事件向（ArkTS 推）：emojiGridEvent(json) → 活跃 EmojiPicker 注册的 sink。
// 几何/刷新（仓颉推 ArkTS）：走 interop callArk("emojiGrid.update", ...)，
// ArkTS 侧在 InteropRegistry 登记（见 EmojiGridBridge.ets）。

import ohos.ark_interop.JSModule
import ohos.ark_interop.JSContext
import ohos.ark_interop.JSCallInfo
import ohos.ark_interop.JSValue
import kit.PerformanceAnalysisKit.Hilog

var emojiGridRowsProvider: Option<() -> String> = None
var emojiGridEventSink: Option<(String) -> Unit> = None
var stickerGridRowsProvider: Option<() -> String> = None
var stickerGridEventSink: Option<(String) -> Unit> = None

/** 跨包对全局 var 直接赋值不可靠，统一走 setter。 */
public func setEmojiGridProviders(
    provider: Option<() -> String>, sink: Option<(String) -> Unit>): Unit {
    emojiGridRowsProvider = provider
    emojiGridEventSink = sink
}

/** 贴纸 Phase1：同一套桥的第二通道。 */
public func setStickerGridProviders(
    provider: Option<() -> String>, sink: Option<(String) -> Unit>): Unit {
    stickerGridRowsProvider = provider
    stickerGridEventSink = sink
}

func getEmojiGridRows(runtime: JSContext, _callInfo: JSCallInfo): JSValue {
    var payload = ""
    match (emojiGridRowsProvider) {
        case Some(provider) => payload = provider()
        case None => ()
    }
    return runtime.string(payload).toJSValue()
}

func emojiGridEvent(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    try {
        let json = callInfo[0].toString()
        match (emojiGridEventSink) {
            case Some(sink) => sink(json)
            case None => ()
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[EmojiGridArkBridge] event failed: ${e}")
    }
    return runtime.undefined().toJSValue()
}

func getStickerGridRows(runtime: JSContext, _callInfo: JSCallInfo): JSValue {
    var payload = ""
    match (stickerGridRowsProvider) {
        case Some(provider) => payload = provider()
        case None => ()
    }
    return runtime.string(payload).toJSValue()
}

func stickerGridEvent(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    try {
        let json = callInfo[0].toString()
        match (stickerGridEventSink) {
            case Some(sink) => sink(json)
            case None => ()
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[EmojiGridArkBridge] sticker event failed: ${e}")
    }
    return runtime.undefined().toJSValue()
}

let EMOJI_GRID_ARK_MODULE = JSModule.registerModule {
    runtime, exports =>
    exports["getEmojiGridRows"] = runtime.function(getEmojiGridRows).toJSValue()
    exports["emojiGridEvent"] = runtime.function(emojiGridEvent).toJSValue()
    exports["getStickerGridRows"] = runtime.function(getStickerGridRows).toJSValue()
    exports["stickerGridEvent"] = runtime.function(stickerGridEvent).toJSValue()
}
