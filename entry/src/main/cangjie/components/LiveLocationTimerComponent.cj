package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import std.sync.*
import std.time.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{LiveLocationTimerService, LiveLocationTimerState}

/**
 * LiveLocationTimerComponent — 实时位置倒计时环
 *
 * 对应 iOS ChatMessageLiveLocationTimerNode:
 * - 外圈背景椭圆（backgroundColor 填充）
 * - 环形进度弧（foregroundColor 描边，clockwise，随剩余时长变化）
 * - 中心文案（剩余分钟数 / "∞" / "99+"）
 * - Timer.repeat 每 10 秒触发重绘（对应 iOS Timer interval = 10s）
 *
 * 使用方式：
 *   LiveLocationTimerComponent(...)  — 提供 service / size / bgColor / fgColor / textColor
 *
 * 调用链：
 *   aboutToAppear → startRefreshTimer → Timer.repeat(10s)
 *   → refreshState() → service.getTimerState() → @State timerState
 *   → build() → Canvas.onReady → drawTimerRing(ctx)
 *
 * arc() 签名: arc(x, y, radius, startAngle, endAngle, counterclockwise!: ?Bool = None)
 *   — counterclockwise 是命名参数，必须用 counterclockwise: 前缀传入
 */
@Component
public class LiveLocationTimerComponent {
    // 数据服务（调用方注入）
    public var service: LiveLocationTimerService = LiveLocationTimerService()

    // 尺寸（vp），对应 iOS bounds.size.width
    public var size: Float64 = 32.0

    // 颜色（Int64 ARGB，可作为 StrokeStyle / FillStyle 使用）
    public var bgColor: Int64 = 0xFF_E8E8E8
    public var fgColor: Int64 = 0xFF_2AABEE
    public var textColor: Int64 = 0xFF_2AABEE

    // 当前计时器状态（驱动 Canvas 重绘）
    @State var timerState: LiveLocationTimerState = LiveLocationTimerState()
    // 计数器，用于触发 Canvas onReady 刷新
    @State var redrawTick: Int64 = 0

    // 定时器句柄（非 @State，不触发 UI；private 避免被 @Component 宏纳入 init 参数）
    private var refreshTimer: Option<Timer> = None<Timer>

    // Canvas 绘制上下文
    let ctx: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))

    // ==================== 生命周期 ====================

    public override func aboutToAppear(): Unit {
        this.refreshState()
        this.startRefreshTimer()
    }

    public override func aboutToDisappear(): Unit {
        this.stopRefreshTimer()
    }

    // ==================== 定时刷新 ====================

    private func startRefreshTimer(): Unit {
        if (this.refreshTimer.isSome()) {
            return
        }
        this.refreshTimer = Some(Timer.repeat(
            Duration.second * 10,
            Duration.second * 10,
            { => this.refreshState() },
            style: CatchupStyle.Skip
        ))
    }

    private func stopRefreshTimer(): Unit {
        match (this.refreshTimer) {
            case Some(t) =>
                t.cancel()
                this.refreshTimer = None<Timer>
            case None => ()
        }
    }

    private func refreshState(): Unit {
        let newState = this.service.getTimerState()
        launch {
            this.timerState = newState
            this.redrawTick = this.redrawTick + 1
        }
    }

    // ==================== 绘制辅助方法（不在 build/@Builder 中使用 let）====================

    private func getProgress(): Float64 {
        this.timerState.progress
    }

    private func getLabel(): String {
        this.timerState.label
    }

    private func getFontSize(): Float64 {
        let lbl = this.timerState.label
        if (lbl == "∞") {
            if (this.size < 28.0) { 14.0 } else { 15.0 }
        } else if (lbl.size > 2) {
            if (this.size < 28.0) { 10.0 } else { 11.0 }
        } else {
            if (this.size < 28.0) { 12.0 } else { 13.0 }
        }
    }

    private func getFontString(): String {
        "bold " + "${this.getFontSize()}" + "px sans-serif"
    }

    /**
     * 在给定 CanvasRenderingContext2D 上绘制完整的倒计时环。
     * 三层：
     *   1. 背景实心圆（bgColor 填充）
     *   2. 进度弧（fgColor 描边，圆形线帽）counterclockwise = false（顺时针）
     *   3. 中心文字（textColor 填充文本）
     *
     * arc 参数说明：
     *   func arc(x, y, radius, startAngle, endAngle, counterclockwise!: ?Bool = None)
     *   - counterclockwise 是命名参数（!），调用时用 counterclockwise: 前缀
     */
    private func drawTimerRing(c2d: CanvasRenderingContext2D): Unit {
        let w = this.size
        let cx = w / 2.0
        let cy = w / 2.0
        let lineW = 1.5
        let pi = 3.14159265358979

        // 1. 背景圆
        c2d.fillStyle = this.bgColor
        c2d.beginPath()
        c2d.arc(cx, cy, cx, 0.0, 2.0 * pi, counterclockwise: false)
        c2d.fill()

        // 2. 进度弧（从顶部 -pi/2 起，顺时针，弧长 = remaining * 2pi）
        let remaining = 1.0 - this.getProgress()
        let startAngle = -pi / 2.0
        let endAngle = startAngle + remaining * 2.0 * pi
        let radius = (w - lineW) / 2.0

        c2d.strokeStyle = this.fgColor
        c2d.lineWidth = lineW
        c2d.lineCap = "round"
        c2d.beginPath()
        c2d.arc(cx, cy, radius, startAngle, endAngle, counterclockwise: false)
        c2d.stroke()

        // 3. 中心文字
        let label = this.getLabel()
        c2d.font = this.getFontString()
        c2d.fillStyle = this.textColor
        c2d.textAlign = "center"
        c2d.textBaseline = "middle"
        c2d.fillText(label, cx, cy)

        Hilog.info(0, "CjTelegram", "[LiveLocationTimerComponent] drawn label=" + label)
    }

    // ==================== UI ====================

    func build() {
        Stack() {
            Canvas(this.ctx)
                .width(this.size)
                .height(this.size)
                .onReady({ =>
                    this.drawTimerRing(this.ctx)
                })
        }
        .width(this.size)
        .height(this.size)
    }
}
