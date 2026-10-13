package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog

/**
 * ToastService — 统一轻提示工具（unified toast helper）
 *
 * 对应 iOS 轻提示语义：短文案、底部弹出、自动消失（"已复制" / "已发送" 等）。
 * 收口工程里各 page 手搓 @State 浮层 toast（DebugSettingsPage / PeerInfoPage /
 * InviteContactsPage 等自绘 showToast / showCopiedToast）的零散写法，统一为单一
 * 调用入口 showToast(message, durationMs)。
 *
 * ── 关键约束（实证踩坑，与 P2-405 DialogService 同源）────────────────────
 *   鸿蒙 ArkUI 的原生 Toast 入口是
 *       getUIContext().getPromptAction().showToast(ShowToastOptions(...))
 *   （cangjie-kb 检索 promptAction / showToast / ShowToastOptions 确认：showToast
 *   是 UIContext 关联的 PromptAction 方法，**不是全局函数**）。而 getUIContext()
 *   只能在 @Component 的 UI 上下文里解析；放到 services 包的普通顶层函数里直接调
 *   会编译报 `undeclared identifier 'getUIContext'`。
 *
 *   因此本入口不能直接弹 toast，而是把「toast 请求」推进单例状态服务，真正弹窗
 *   动作交给根部挂载的 components/ToastHost.cj —— 它在 @Component 上下文里 tick
 *   轮询本服务的 epoch 变化，取出请求并调
 *       getUIContext().getPromptAction().showToast(ShowToastOptions(...))
 *   这与工程既有 DialogService/DialogHost、OverlayStatusService/OverlayStatusView、
 *   UndoToastService/UndoToast 的「单例状态服务 + 根叠加层组件」范式一致。
 *
 * ── 宿主前置条件 ────────────────────────────────────────────────────
 *   宿主需在 root 容器挂一次：ToastHost()
 *   （与 DialogHost()/UndoToast()/OverlayStatusView() 同样的根叠加层约定）。
 *
 * 顶层函数名 showToast；命名参数用 `!`。
 */

// ==================== 单例 toast 状态服务 ====================

private var _toastServiceInstance: Option<ToastService> = None<ToastService>

public func getToastService(): ToastService {
    match (_toastServiceInstance) {
        case Some(s) => s
        case None =>
            let s = ToastService()
            _toastServiceInstance = Some(s)
            s
    }
}

/**
 * 持有「待弹原生 Toast」请求的单例。ToastHost 组件 tick 轮询 epoch 变化，
 * 取出最近一条请求并在 UI 上下文里弹 toast。
 */
public class ToastService {
    private var _message: String = ""
    private var _durationMs: Int64 = 2000

    // 单调递增「轮次」标记 —— 每次 request 自增，供 ToastHost 感知「有新 toast 请求」。
    private var _epoch: Int64 = 0

    public func request(message: String, durationMs: Int64): Unit {
        this._message = message
        this._durationMs = durationMs
        this._epoch = this._epoch + 1
        Hilog.info(0, "CjTelegram",
            "[ToastService] request message=" + message + " durationMs=" + durationMs.toString())
    }

    // ==================== 供 ToastHost tick 轮询 ====================

    public func getEpoch(): Int64 {
        return this._epoch
    }

    public func getMessage(): String {
        return this._message
    }

    public func getDurationMs(): Int64 {
        return this._durationMs
    }
}

// ==================== 调用入口 ====================

/**
 * 弹一条轻提示（由根部挂载的 ToastHost 转交 UndoToast 页内浮条呈现；
 * 系统原生 toast 在真机上不可见，见 components/ToastHost.cj 文件头）。
 *
 * @param message    提示文案（短文案，如 "已复制" / "已发送"）
 * @param durationMs 显示时长（毫秒），默认 3000——对齐 iOS
 *                   UndoOverlayControllerNode 无交互提示的 `timeout ?? 3`；
 *                   ToastHost 侧再对小于 3000 的显式值取下限 3000
 */
public func showToast(message: String, durationMs!: Int64 = 3000): Unit {
    getToastService().request(message, durationMs)
}
