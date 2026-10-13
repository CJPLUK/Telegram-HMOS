package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog
import std.sync.*

// 原生 emoji 网格合成器（emoji_grid_compositor.cpp，libentry.so 直链符号）。
// 设计与用法见 cpp 头注释；本模块只做符号封装与字符串封送。
foreign func emojiGridCompositorSetSurface(surfaceId: UInt64): Unit
foreign func emojiGridCompositorSetItems(payload: CString): Unit
foreign func emojiGridCompositorSetViewport(
    x: Int32, y: Int32, w: Int32, h: Int32, bgColor: UInt32): Unit
foreign func emojiGridCompositorSetActive(active: Int32): Unit
foreign func emojiGridCompositorSetSurfaceSize(w: Int32, h: Int32): Unit

var emojiGridSurfaceReadyFlag: Bool = false

public func emojiGridSurfaceReady(): Bool { return emojiGridSurfaceReadyFlag }

public func emojiGridSurfaceSize(w: Int64, h: Int64): Unit {
    unsafe { emojiGridCompositorSetSurfaceSize(Int32(w), Int32(h)) }
}

public func emojiGridSurfaceBind(surfaceId: UInt64): Unit {
    unsafe { emojiGridCompositorSetSurface(surfaceId) }
    emojiGridSurfaceReadyFlag = surfaceId != 0
    Hilog.info(0, "CjTelegram", "[EmojiGridCompositor] surface=${surfaceId}")
}

/** items: "docId|path|x|y|sizePx|animated;..."（屏幕 px，整数）。 */
public func emojiGridPushItems(payload: String): Unit {
    unsafe {
        let raw = LibC.mallocCString(payload)
        emojiGridCompositorSetItems(raw)
        LibC.free(raw)
    }
}

public func emojiGridSetViewport(x: Int64, y: Int64, w: Int64, h: Int64, bg: UInt32): Unit {
    unsafe {
        emojiGridCompositorSetViewport(Int32(x), Int32(y), Int32(w), Int32(h), bg)
    }
}

public func emojiGridSetActive(active: Bool): Unit {
    unsafe { emojiGridCompositorSetActive(if (active) { 1 } else { 0 }) }
}
