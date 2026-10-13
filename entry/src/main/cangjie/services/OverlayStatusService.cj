package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.time.DateTime

/**
 * OverlayStatusService — 全屏模态状态遮罩管理器（单例）
 *
 * 对应 iOS Telegram-iOS submodules/OverlayStatusController
 * （OverlayStatusController.swift）：
 *   阻塞式全局状态反馈 —— 居中卡片显示 转圈(loading)/对勾(success)/
 *   叉(fail) + 可选文案，半透明背景挡住交互；success / fail 自动消失，
 *   loading 不自动消失（需手动 dismiss 或转 success/fail）。
 *
 * 与 UndoToastService / DialogService 同范式（状态 + 同步通知）：
 *   本服务只持有**状态**，不含任何 UI；UI 由 OverlayStatusView 组件
 *   （components/OverlayStatusView.cj）以根叠加层方式消费。show* / dismiss
 *   在写完状态并 hilog 之后立刻 notify 已注册的单一 UI 监听，使可见性
 *   落在同一次 UI 调用栈（对齐源侧 present(..., in: .window(.root))）。
 *
 * 调用方（任意需要全局阻塞反馈的 feature）：
 *   getOverlayStatusService().showLoading(text: "Connecting...")
 *   getOverlayStatusService().showSuccess(text: "Done")          // 1500ms 后自动消失
 *   getOverlayStatusService().showFail(text: "Failed")           // 1500ms 后自动消失
 *   getOverlayStatusService().dismiss()
 *
 * 状态字符串：
 *   "loading" / "success" / "fail" / ""（空 = 不显示）
 *
 * 生命周期（一次遮罩）：
 *   showLoading  → status="loading"，无自动消失（autoDismissAtMs=0），notify
 *   showSuccess  → status="success"，autoDismissAtMs=now+autoDismissMs，notify
 *   showFail     → status="fail"，autoDismissAtMs=now+autoDismissMs，notify
 *   组件对 success/fail 用 Timer 检查 isAutoDismissDue() → 到点调 dismiss()
 *   dismiss      → status=""，isShowing()=false，notify（空状态 early-return 不 notify）
 */
private var _overlayStatusServiceInstance: Option<OverlayStatusService> = None<OverlayStatusService>

public func getOverlayStatusService(): OverlayStatusService {
    match (_overlayStatusServiceInstance) {
        case Some(s) => s
        case None =>
            let s = OverlayStatusService()
            _overlayStatusServiceInstance = Some(s)
            s
    }
}

public class OverlayStatusService {
    // 当前状态："loading" / "success" / "fail" / ""（空=不显示）
    private var _status: String = ""

    // 当前文案（可空）
    private var _text: String = ""

    // 单调递增"轮次"标记 —— 每次 show* 自增，供组件感知"换了一次遮罩"
    private var _epoch: Int64 = 0

    // 自动消失的目标时刻（毫秒墙钟）；0 = 不自动消失（loading）
    private var _autoDismissAtMs: Int64 = 0

    // 单一 UI 监听：OverlayStatusView 在 aboutToAppear 注册，aboutToDisappear 清空
    private var _onChange: Option<() -> Unit> = None

    private func nowMs(): Int64 {
        return DateTime.now().toUnixTimeStamp().toMilliseconds()
    }

    public func setOnChange(cb: Option<() -> Unit>): Unit {
        this._onChange = cb
    }

    private func notify(): Unit {
        match (this._onChange) {
            case Some(cb) => cb()
            case None => ()
        }
    }

    private func beginShow(status: String, text: String, autoDismissMs: Int64): Unit {
        this._status = status
        this._text = text
        this._epoch = this._epoch + 1
        if (autoDismissMs > 0) {
            this._autoDismissAtMs = this.nowMs() + autoDismissMs
        } else {
            this._autoDismissAtMs = 0
        }
        Hilog.info(0, "CjTelegram",
            "[OverlayStatusService] show status=" + status + " text=" + text +
            " autoDismissMs=" + autoDismissMs.toString())
        this.notify()
    }

    /**
     * 显示 loading 遮罩（转圈）。不自动消失，需手动 dismiss 或转 success/fail。
     * @param text 可选文案，默认空。
     */
    public func showLoading(text!: String = ""): Unit {
        this.beginShow("loading", text, 0)
    }

    /**
     * 显示 success 遮罩（对勾）。autoDismissMs 后自动消失，默认 1500ms。
     * @param text          可选文案，默认空。
     * @param autoDismissMs 自动消失延时（毫秒），默认 1500。<=0 视为 1500。
     */
    public func showSuccess(text!: String = "", autoDismissMs!: Int64 = 1500): Unit {
        let dur = if (autoDismissMs > 0) { autoDismissMs } else { 1500 }
        this.beginShow("success", text, dur)
    }

    /**
     * 显示 fail 遮罩（叉）。autoDismissMs 后自动消失，默认 1500ms。
     * @param text          可选文案，默认空。
     * @param autoDismissMs 自动消失延时（毫秒），默认 1500。<=0 视为 1500。
     */
    public func showFail(text!: String = "", autoDismissMs!: Int64 = 1500): Unit {
        let dur = if (autoDismissMs > 0) { autoDismissMs } else { 1500 }
        this.beginShow("fail", text, dur)
    }

    /**
     * 主动消失：清状态，遮罩退场。空状态 early-return 不 notify。
     */
    public func dismiss(): Unit {
        if (this._status.size == 0) {
            return
        }
        this._status = ""
        this._text = ""
        this._autoDismissAtMs = 0
        Hilog.info(0, "CjTelegram", "[OverlayStatusService] dismiss")
        this.notify()
    }

    // ==================== 状态查询（供 OverlayStatusView 同栈 apply）====================

    public func isShowing(): Bool {
        return this._status.size > 0
    }

    public func getStatus(): String {
        return this._status
    }

    public func getText(): String {
        return this._text
    }

    public func getEpoch(): Int64 {
        return this._epoch
    }

    /**
     * 是否到了自动消失时刻（仅 success/fail 设置过 autoDismissAtMs）。
     * loading（autoDismissAtMs=0）永不到点。
     */
    public func isAutoDismissDue(): Bool {
        if (this._status.size == 0) {
            return false
        }
        if (this._autoDismissAtMs <= 0) {
            return false
        }
        return this.nowMs() >= this._autoDismissAtMs
    }
}
