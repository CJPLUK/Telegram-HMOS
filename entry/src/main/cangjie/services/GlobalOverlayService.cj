package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.time.DateTime

/**
 * GlobalOverlayService — 应用级通用 overlay 栈管理器（单例）
 *
 * 对应 iOS Telegram 根容器 present 机制：
 *   iOS RootController.present(viewController, animated) 可从任意代码层
 *   全局 present 一个覆盖层（alert / tooltip / banner / sheet 等），
 *   本服务是 HarmonyOS 侧的等价抽象。
 *
 * 用途：提供统一的应用级 overlay 宿主，替代各页面各自 bindSheet/Dialog 的做法。
 *   调用方把需要全局显示的 overlay 入栈，GlobalOverlayHost 组件
 *   轮询服务状态、渲染栈顶 overlay；dismiss 后弹出栈顶。
 *
 * 使用示例：
 *   getGlobalOverlayService().push(id: "tip_tooltip", label: "链接已复制")
 *   getGlobalOverlayService().dismiss(id: "tip_tooltip")
 *   getGlobalOverlayService().dismissAll()
 *
 * 注意：本服务只持有**状态**，不含 UI；UI 由 GlobalOverlayHost 组件消费。
 */

public class GlobalOverlayEntry {
    public var id: String
    public var label: String
    public var pushedAtMs: Int64

    public init(eid: String, elabel: String, atMs: Int64) {
        this.id = eid
        this.label = elabel
        this.pushedAtMs = atMs
    }
}

private var _globalOverlayServiceInstance: Option<GlobalOverlayService> = None<GlobalOverlayService>

public func getGlobalOverlayService(): GlobalOverlayService {
    match (_globalOverlayServiceInstance) {
        case Some(s) => s
        case None =>
            let s = GlobalOverlayService()
            _globalOverlayServiceInstance = Some(s)
            s
    }
}

public class GlobalOverlayService {
    private var _stack: Array<GlobalOverlayEntry> = Array<GlobalOverlayEntry>()
    private var _epoch: Int64 = 0

    /**
     * 把一个 overlay 条目压入栈顶。
     * @param id    唯一标识（用于 dismiss(id:)）
     * @param label 可选的描述文案（GlobalOverlayHost 可用于渲染通用内容）
     */
    public func push(id: String, label!: String = ""): Unit {
        let nowMs = this.nowMs()
        let entry = GlobalOverlayEntry(id, label, nowMs)
        let newStack = Array<GlobalOverlayEntry>(this._stack.size + 1, { i: Int64 =>
            if (i < this._stack.size) { this._stack[i] } else { entry }
        })
        this._stack = newStack
        this._epoch = this._epoch + 1
        Hilog.info(0, "CjTelegram", "[GlobalOverlayService] push id=${id} depth=${this._stack.size}")
    }

    /**
     * 按 id 弹出特定 overlay 条目（可在栈任意位置）。
     */
    public func dismiss(id: String): Unit {
        var newSize: Int64 = 0
        for (entry in this._stack) {
            if (entry.id != id) {
                newSize = newSize + 1
            }
        }
        if (newSize == this._stack.size) { return }
        let newStack = Array<GlobalOverlayEntry>(newSize, { _ => GlobalOverlayEntry("", "", 0) })
        var idx: Int64 = 0
        for (entry in this._stack) {
            if (entry.id != id) {
                newStack[idx] = entry
                idx = idx + 1
            }
        }
        this._stack = newStack
        this._epoch = this._epoch + 1
        Hilog.info(0, "CjTelegram", "[GlobalOverlayService] dismiss id=${id} depth=${this._stack.size}")
    }

    /**
     * 弹出栈顶 overlay。
     */
    public func dismissTop(): Unit {
        if (this._stack.size == 0) { return }
        let newStack = Array<GlobalOverlayEntry>(this._stack.size - 1, { i: Int64 => this._stack[i] })
        this._stack = newStack
        this._epoch = this._epoch + 1
        Hilog.info(0, "CjTelegram", "[GlobalOverlayService] dismissTop depth=${this._stack.size}")
    }

    /**
     * 清空所有 overlay。
     */
    public func dismissAll(): Unit {
        if (this._stack.size == 0) { return }
        this._stack = Array<GlobalOverlayEntry>()
        this._epoch = this._epoch + 1
        Hilog.info(0, "CjTelegram", "[GlobalOverlayService] dismissAll")
    }

    // ========= 状态查询（供 GlobalOverlayHost tick 轮询）=========

    public func getEpoch(): Int64 {
        return this._epoch
    }

    public func isAnyVisible(): Bool {
        return this._stack.size > 0
    }

    public func getDepth(): Int64 {
        return this._stack.size
    }

    /**
     * 获取栈顶条目（若有）。
     */
    public func getTop(): Option<GlobalOverlayEntry> {
        if (this._stack.size == 0) {
            return None<GlobalOverlayEntry>
        }
        return Some(this._stack[this._stack.size - 1])
    }

    private func nowMs(): Int64 {
        return DateTime.now().toUnixTimeStamp().toMilliseconds()
    }
}
