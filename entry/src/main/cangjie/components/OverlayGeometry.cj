package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashMap}

/**
 * ArkTS 覆盖层（表情网格 / 贴纸网格 / 附件图库网格）几何统一通道。
 *
 * 背景（2026-09-15 真机实锤的错位根因）：覆盖层几何原本只靠仓颉占位块的
 * onAreaChange 报出。ArkUI 的 onAreaChange 只在组件自身尺寸或相对父容器位置
 * 变化时触发；系统键盘收起后页面根整体展开、面板整体下移，占位块自身没变，
 * 回调不再来，覆盖层就停在键盘还在时量到的位置（表情面板 y=899 而不是 1623）。
 *
 * 方案：占位块设 id，几何一律可以主动用 ComponentUtils.getRectangleById 重量；
 * 各面板在存活期把自己的重量函数注册进来，宿主在键盘高度变化、面板开合等
 * “会整体位移”的时刻调 remeasureAllOverlays()，布局稳定后再推一次真实几何。
 */
public class OverlayRectPx {
    public var x: Float64
    public var y: Float64
    public var w: Float64
    public var h: Float64
    public init(x: Float64, y: Float64, w: Float64, h: Float64) {
        this.x = x
        this.y = y
        this.w = w
        this.h = h
    }
}

/** 按组件 id 量窗口坐标系下的矩形（px）；组件不在树上或尚未布局时返回 None。 */
public func measureOverlaySlot(id: String): Option<OverlayRectPx> {
    try {
        let r = ComponentUtils.getRectangleById(id)
        let rect = OverlayRectPx(r.windowOffset.x, r.windowOffset.y, r.size.width, r.size.height)
        if (rect.w <= 0.0 || rect.h <= 0.0) { return None }
        return Some(rect)
    } catch (e: Exception) {
        return None
    }
}

let _overlayRemeasureHandlers = HashMap<String, () -> Unit>()

public func registerOverlayRemeasure(name: String, handler: () -> Unit): Unit {
    _overlayRemeasureHandlers[name] = handler
}

public func unregisterOverlayRemeasure(name: String): Unit {
    _overlayRemeasureHandlers.remove(name)
}

/** 让所有存活的覆盖层按当前布局重量并推送；须在 UI 线程调用。 */
public func remeasureAllOverlays(reason: String): Unit {
    let handlers = ArrayList<() -> Unit>()
    for ((_, h) in _overlayRemeasureHandlers) { handlers.add(h) }
    if (handlers.size == 0) { return }
    Hilog.info(0, "CjTelegram", "[OverlayGeometry] remeasure ${handlers.size} overlays (${reason})")
    for (h in handlers) {
        try { h() } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[OverlayGeometry] remeasure failed: ${e}")
        }
    }
}
