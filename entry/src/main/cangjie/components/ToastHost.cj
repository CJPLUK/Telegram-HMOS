package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.services.getToastService
import ohos_app_cangjie_entry.services.getUndoToastService

/**
 * ToastHost — 统一轻提示的根部宿主组件
 *
 * 对应 iOS 轻提示语义：短文案、底部弹出、自动消失（源侧这类提示统一由
 * UndoOverlayController 以页内底部浮条呈现，见 submodules/UndoUI）。
 *
 * 为什么需要宿主组件：services/ToastService.cj 的 showToast 只把「toast 请求」
 * 推进 ToastService（单例），真正呈现由本组件 tick 轮询 epoch 变化后执行，
 * 调用方无需持有任何 UI 上下文。
 *
 * 用法：在 root 容器挂一次即可（全局共用），与 DialogHost() 同一处挂载：
 *     ToastHost()
 * 本组件自身不渲染任何可见 UI，只挂一个 0 尺寸占位。
 *
 * S-64: aboutToAppear/aboutToDisappear 必须 public override func ... : Unit
 *
 * ── 呈现载体（core-acceptance W3 返修）──────────────────────────────────
 * 此前本组件用 getUIContext().getPromptAction().showToast(ShowToastOptions(
 * showMode: ToastShowMode.TopMost)) 弹系统原生 toast。W3 真机整轮实测：hilog
 * 有 presentToast 记录，但录屏抽帧与 uitest dumpLayout 都看不到任何 toast 节点
 * （S1-37 / S8-08，见 output/WORKFLOW_FEEDBACK.md）；同一轮 UndoToast 浮条
 * （UndoToastService.showUndo → components/UndoToast.cj）在同一台设备上可见
 * （S1-37 已改走该载体并拿到 `wait ok 'Undo'` 证据）。
 *
 * 因此本组件统一改为把请求转交 UndoToastService.showUndo(showProgress:false,
 * showAction:false)：与 iOS UndoOverlayController 对无 Undo 的 .succeed/.info
 * 内容的呈现一致（底部深色浮条、无按钮、无倒计时条、到点自动退场）。所有
 * showToast() 调用点签名、文案均不变，只在这一处换载体。
 *
 * 触摸不遮挡：UndoToast 在 MainTabPage 可见时走内联浮条，responseRegion 只覆盖
 * 浮条本身；只有在被 routerPush 页面盖住时才退回 bindContentCover（UndoToast
 * 既有行为，本组件不新增任何全屏层）。
 *
 * 时长对齐 iOS：UndoOverlayControllerNode.swift 对无交互提示的 originalRemainingSeconds
 * 取 `timeout ?? 3`（.succeed）/ 3（.mediaSaved 等）/ 5（.info 无 timeout 时
 * max(5, min(8, count/14))），即最短 3 秒；本组件对请求时长取 max(durationMs, 3000)。
 */
// iOS UndoOverlayControllerNode 无交互提示的最短停留时长（timeout ?? 3 秒）。
let TOAST_MIN_DURATION_MS: Int64 = 3000

@Component
public class ToastHost {
    // 记录上次已处理的服务 epoch（避免同一请求重复弹 toast）。
    private var lastSeenEpoch: Int64 = -1

    // tick 定时器
    var tickTimer: Option<Timer> = None<Timer>

    // ==================== 生命周期 ====================

    public override func aboutToAppear(): Unit {
        // 进场时把基线对齐到当前 epoch，避免把历史请求当成新请求。
        this.lastSeenEpoch = getToastService().getEpoch()
        this.startTick()
        Hilog.info(0, "CjTelegram", "[ToastHost] aboutToAppear")
    }

    public override func aboutToDisappear(): Unit {
        this.stopTick()
    }

    // ==================== tick：轮询 toast 请求 ====================

    private func startTick(): Unit {
        if (this.tickTimer.isSome()) {
            return
        }
        this.tickTimer = Some(Timer.repeat(
            Duration.millisecond * 100,
            Duration.millisecond * 100,
            { => this.onTick() },
            style: CatchupStyle.Skip
        ))
    }

    private func stopTick(): Unit {
        match (this.tickTimer) {
            case Some(t) =>
                t.cancel()
                this.tickTimer = None<Timer>
            case None => ()
        }
    }

    private func onTick(): Unit {
        let svc = getToastService()
        let epoch = svc.getEpoch()
        if (epoch == this.lastSeenEpoch) {
            return
        }
        this.lastSeenEpoch = epoch
        // 取出请求快照并交给页内浮条载体呈现。
        this.presentToast(svc.getMessage(), svc.getDurationMs())
    }

    // ==================== 呈现：转交 UndoToast 页内浮条 ====================

    private func presentToast(message: String, durationMs: Int64): Unit {
        let effectiveMs: Int64 = if (durationMs < TOAST_MIN_DURATION_MS) {
            TOAST_MIN_DURATION_MS
        } else {
            durationMs
        }
        // 本函数在 Timer tick 线程；showUndo 会同步直呼 UndoToast 的 presenter，
        // 与 S1-37 调用点一致统一切回 UI 线程（R-69）。
        launch {
            try {
                getUndoToastService().showUndo(
                    message,
                    durationMs: effectiveMs,
                    showProgress: false,
                    showAction: false
                )
                Hilog.info(0, "CjTelegram",
                    "[ToastHost] presentToast message=" + message + " durationMs=" + effectiveMs.toString())
            } catch (e: Exception) {
                // 失败静默，不崩溃。
                Hilog.error(0, "CjTelegram", "[ToastHost] presentToast failed: " + e.message)
            }
        }
    }

    // ==================== UI（无可见内容，仅 0 尺寸占位）====================

    func build() {
        Stack {}
            .width(0)
            .height(0)
    }
}
