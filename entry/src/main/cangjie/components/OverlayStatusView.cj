package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.services.getOverlayStatusService

/**
 * OverlayStatusView — 全屏模态状态遮罩组件（full-screen status overlay）
 *
 * 对应 iOS Telegram-iOS submodules/OverlayStatusController
 * （OverlayStatusController.swift）：
 *   居中卡片 + 半透明黑底，按状态显示：
 *     loading → 转圈（LoadingProgress）+ 可选文案
 *     success → 对勾（✓，绿色）+ 文案
 *     fail    → 叉（✕，红色）+ 文案
 *   半透明背景挡住下层交互；success / fail 自动消失，loading 需手动 dismiss。
 *
 * 渲染分离范式参考 UndoToast / UndoToastService:
 *   本组件不持有业务状态, 纯渲染; 状态由 OverlayStatusService 单例维护.
 *   非受控模式在 aboutToAppear 注册单一 UI 监听, show/dismiss 的 notify
 *   在当前调用栈写入 State (showLoading 已在 onClick UI 线程), 对齐源侧
 *   present 同步挂窗. Timer.repeat 只检查 isAutoDismissDue (success/fail
 *   默认 1500 ms), 不用作 .loading 入场.
 *
 * 两种用法：
 *   1) 直接挂在 root 容器（自己读服务、自己显示/隐藏）：
 *        OverlayStatusView()
 *      —— status 为空时整体由服务的 isShowing() 决定可见性。
 *   2) 作为受控展示（父组件已用 if 控制可见性，仅渲染一帧）：
 *        OverlayStatusView(status: "loading", text: "Connecting...")
 *      —— 传入非空 status 即视为受控模式，不读服务、不自动消失。
 *
 * S-64: aboutToAppear/aboutToDisappear 必须 public override func ... : Unit
 *
 * Component 基本类型参数用普通 var (非 Prop) -- 见 UndoToast 约定.
 */
@Component
public class OverlayStatusView {
    // ==================== 受控模式参数（传非空 status 即受控，不读服务）====================

    // 状态："loading" / "success" / "fail"；空字符串=非受控，改读 OverlayStatusService。
    public var status: String = ""

    // 文案（可选）
    public var text: String = ""

    // ==================== 渲染状态 (State 驱动重绘) ====================

    // 当前是否可见
    @State var visible: Bool = false

    // 当前渲染用的状态 / 文案（受控来自参数，非受控来自服务）
    @State var curStatus: String = ""
    @State var curText: String = ""

    // 非受控模式：记录上次见到的服务 epoch（换一次遮罩时重置）
    private var lastSeenEpoch: Int64 = -1

    // success/fail 自动消失检查定时器（不做 .loading 入场）
    var tickTimer: Option<Timer> = None<Timer>

    // ==================== 生命周期 ====================

    public override func aboutToAppear(): Unit {
        if (this.isControlled()) {
            // 受控模式：进场即按参数渲染一帧，不自动消失
            this.curStatus = this.status
            this.curText = this.text
            this.visible = true
        } else {
            getOverlayStatusService().setOnChange(Some({ => this.applyFromService() }))
            this.applyFromService()
        }
        Hilog.info(0, "CjTelegram",
            "[OverlayStatusView] aboutToAppear controlled=" + this.isControlled().toString())
    }

    public override func aboutToDisappear(): Unit {
        if (!this.isControlled()) {
            let noneCb: Option<() -> Unit> = None
            getOverlayStatusService().setOnChange(noneCb)
        }
        this.stopTick()
    }

    // ==================== 模式判定 ====================

    private func isControlled(): Bool {
        return this.status.size > 0
    }

    /**
     * 非受控: 把服务状态写到本组件 State. 必须在当前调用栈完成
     * (showLoading 已在 UI 线程), 禁止把首次出现延后到 Timer 或 launch.
     */
    private func applyFromService(): Unit {
        let svc = getOverlayStatusService()
        let showing = svc.isShowing()
        if (!showing) {
            this.curStatus = ""
            this.curText = ""
            this.visible = false
            this.lastSeenEpoch = svc.getEpoch()
            this.stopTick()
            return
        }
        this.lastSeenEpoch = svc.getEpoch()
        this.curStatus = svc.getStatus()
        this.curText = svc.getText()
        this.visible = true
        if (this.curStatus == "success" || this.curStatus == "fail") {
            this.startAutoDismissTick()
        } else {
            this.stopTick()
        }
    }

    // ==================== tick：仅 success/fail 自动消失 ====================

    private func startAutoDismissTick(): Unit {
        if (this.isControlled()) {
            return
        }
        if (this.tickTimer.isSome()) {
            return
        }
        this.tickTimer = Some(Timer.repeat(
            Duration.millisecond * 200,
            Duration.millisecond * 200,
            { => this.onAutoDismissTick() },
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

    /**
     * 只检查 isAutoDismissDue(). Timer 线程上不写 State; 到期后 launch
     * 回 UI 再 dismiss, 使 notify -> applyFromService 仍落在 UI 调用栈.
     */
    private func onAutoDismissTick(): Unit {
        let svc = getOverlayStatusService()
        if (svc.isAutoDismissDue()) {
            launch {
                getOverlayStatusService().dismiss()
            }
        }
    }

    // ==================== UI ====================

    func build() {
        if (this.visible) {
            this.buildOverlay()
        }
    }

    // 半透明黑底（挡交互）+ 居中卡片
    @Builder
    private func buildOverlay() {
        Stack {
            this.buildCard()
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .alignContent(Alignment.Center)
    }

    @Builder
    private func buildCard() {
        Column(space: 12) {
            // 状态图标 / 转圈
            if (this.curStatus == "loading") {
                LoadingProgress()
                    .width(48)
                    .height(48)
                    .color(0xFFFFFF)
            } else if (this.curStatus == "success") {
                Text("\u{2713}")
                    .fontSize(44)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x4CD964)
                    .textAlign(TextAlign.Center)
            } else if (this.curStatus == "fail") {
                Text("\u{2715}")
                    .fontSize(44)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF3B30)
                    .textAlign(TextAlign.Center)
            }

            // 可选文案
            if (this.curText.size > 0) {
                Text(this.curText)
                    .fontSize(15)
                    .fontColor(0xFFFFFF)
                    .textAlign(TextAlign.Center)
                    .maxLines(3)
                    .textOverflow(TextOverflow.Ellipsis)
            }
        }
        .width(140)
        .constraintSize(minHeight: 120)
        .padding(top: 20, bottom: 20, left: 16, right: 16)
        .borderRadius(14)
        .backgroundColor(0xE6202020)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }
}
