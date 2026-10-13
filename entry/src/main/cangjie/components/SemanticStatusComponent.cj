package ohos_app_cangjie_entry.components
import ohos_app_cangjie_entry.utils.safeAnimateTo

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.services.{
    getSemanticStatusService,
    SEMANTIC_STATUS_NONE,
    SEMANTIC_STATUS_DOWNLOAD,
    SEMANTIC_STATUS_PLAY,
    SEMANTIC_STATUS_PAUSE,
    SEMANTIC_STATUS_DOWNLOADING,
    SEMANTIC_STATUS_UPLOADING
}

/**
 * SemanticStatusComponent — 语义状态图标组件
 *
 * 对应 iOS SemanticStatusNode (SemanticStatusNode.swift)：
 *   - 纯渲染组件，通过 SemanticStatusService 获取当前状态并渲染
 *   - 支持状态：download（箭头）/ play（三角）/ pause（双竖条）/
 *               downloading（下载进度环+取消X）/ uploading（上传进度环）/ none（不显示）
 *   - 带平滑进度过渡动画（animateTo 150ms）
 *
 * 渲染方式：
 *   - 进度环：Progress(value:, total:, progressType: ProgressType.Ring) + animateTo 平滑过渡
 *   - 图标：Canvas CanvasRenderingContext2D（arc / lineTo / stroke / fill）
 *   - 背景圆：Column.borderRadius 实现
 *   - 状态过渡：200ms 定时器轮询 SemanticStatusService，检测到状态变化时触发重绘
 *
 * 用法：
 *   SemanticStatusComponent(msgId: message.id, size: 40.0)
 *
 * 与外层集成（如 MessageBubble 文件消息下载按钮）：
 *   getSemanticStatusService().setSemanticStatus(msgId: msg.id, state: SEMANTIC_STATUS_DOWNLOADING, progress: 0.0)
 *   ...（下载中）...
 *   getSemanticStatusService().setProgress(msgId: msg.id, progress: 0.6)
 *   ...（完成）...
 *   getSemanticStatusService().setSemanticStatus(msgId: msg.id, state: SEMANTIC_STATUS_PLAY)
 *
 * S-64: aboutToAppear/aboutToDisappear 必须 public override func ... : Unit
 * R-69: Timer 回调内 @State 写必须包 launch{}
 */
@Component
public class SemanticStatusComponent {
    // 绑定的消息 ID（从 SemanticStatusService 查询状态）
    public var msgId: Int64 = 0

    // 组件尺寸（vp），默认 40
    public var size: Float64 = 40.0

    // 前景颜色（进度环 / 图标颜色），默认白色
    public var foregroundColor: Int64 = 0xFFFFFFFF

    // 背景圆颜色，默认半透明黑色
    public var backgroundColor: Int64 = 0x88000000

    // 点击回调（如文件下载取消 / 播放暂停切换）
    public var onTap: () -> Unit = { => }

    // 当前状态 key（驱动重绘，格式：state_progressInt）
    @State var statusKey: String = "none_0"

    // 当前状态类型字符串
    @State var stateType: String = SEMANTIC_STATUS_NONE

    // 进度动画目标值（animateTo 平滑插值）
    @State var animProgressVal: Float64 = 0.0

    // 定时刷新器句柄
    var refreshTimer: Option<Timer> = None<Timer>

    // Canvas 绘制上下文（各子 Builder 共享）
    let ctx: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))

    // ==================== 生命周期 ====================

    public override func aboutToAppear(): Unit {
        this.refreshStatus()
        this.startRefreshTimer()
        Hilog.info(0, "CjTelegram", "[SemanticStatusComponent] aboutToAppear msgId=" + this.msgId.toString(), [])
    }

    public override func aboutToDisappear(): Unit {
        this.stopRefreshTimer()
        Hilog.info(0, "CjTelegram", "[SemanticStatusComponent] aboutToDisappear msgId=" + this.msgId.toString(), [])
    }

    // ==================== 定时刷新（进度更新 + 状态变化检测）====================

    private func startRefreshTimer(): Unit {
        if (this.refreshTimer.isSome()) {
            return
        }
        this.refreshTimer = Some(Timer.repeat(
            Duration.millisecond * 200,
            Duration.millisecond * 200,
            { => this.refreshStatus() },
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

    /**
     * 从 SemanticStatusService 读取最新状态并更新 @State
     * R-69: Timer 内 @State 写必须包 launch{}
     */
    private func refreshStatus(): Unit {
        let svc = getSemanticStatusService()
        let newKey = svc.getStatusKey(this.msgId)
        let newState = svc.getState(this.msgId)
        let newProg = svc.getProgress(this.msgId)
        launch {
            if (newKey != this.statusKey) {
                this.statusKey = newKey
                this.stateType = newState
            }
            if (newProg >= 0.0 && newProg != this.animProgressVal) {
                safeAnimateTo({ => getUIContext() }, 
                    AnimateParam(duration: 150, curve: Curve.Linear),
                    { => this.animProgressVal = newProg }
                )
            }
        }
    }

    // ==================== 辅助判断方法（不能在 build/@Builder 中 let）====================

    private func isVisible(): Bool {
        this.stateType != SEMANTIC_STATUS_NONE
    }

    private func isProgressType(): Bool {
        this.stateType == SEMANTIC_STATUS_DOWNLOADING ||
        this.stateType == SEMANTIC_STATUS_UPLOADING
    }

    private func isDownloadingType(): Bool {
        this.stateType == SEMANTIC_STATUS_DOWNLOADING
    }

    private func isDownloadType(): Bool {
        this.stateType == SEMANTIC_STATUS_DOWNLOAD
    }

    private func isPlayType(): Bool {
        this.stateType == SEMANTIC_STATUS_PLAY
    }

    private func isPauseType(): Bool {
        this.stateType == SEMANTIC_STATUS_PAUSE
    }

    private func getHalfSize(): Float64 {
        this.size / 2.0
    }

    private func getRadius(): Float64 {
        this.getHalfSize() - 3.0
    }

    private func getIconScale(): Float64 {
        this.size / 40.0
    }

    // ==================== Canvas 绘制方法 ====================

    /**
     * 绘制下载箭头图标（↓）
     * iOS: SemanticStatusNodeIconContext(.download) — 向下箭头
     */
    private func drawDownloadIcon(c2d: CanvasRenderingContext2D): Unit {
        let cx = this.getHalfSize()
        let cy = this.getHalfSize()
        let s = this.getIconScale()
        let lw = 2.0 * s

        c2d.strokeStyle = this.foregroundColor
        c2d.lineWidth = lw
        c2d.lineCap = "round"

        let topY = cy - 9.0 * s
        let botY = cy + 5.0 * s
        let arrowW = 6.0 * s
        let arrowH = 5.0 * s

        c2d.beginPath()
        c2d.moveTo(cx, topY)
        c2d.lineTo(cx, botY)
        c2d.stroke()

        c2d.beginPath()
        c2d.moveTo(cx - arrowW, botY - arrowH)
        c2d.lineTo(cx, botY)
        c2d.lineTo(cx + arrowW, botY - arrowH)
        c2d.stroke()
    }

    /**
     * 绘制播放三角图标（▶）
     * iOS: SemanticStatusNodeIconContext(.play)
     */
    private func drawPlayIcon(c2d: CanvasRenderingContext2D): Unit {
        let cx = this.getHalfSize()
        let cy = this.getHalfSize()
        let s = this.getIconScale()
        let h = 10.0 * s
        let w = 9.0 * s

        c2d.fillStyle = this.foregroundColor
        c2d.beginPath()
        c2d.moveTo(cx - w / 2.0 + 1.0 * s, cy - h / 2.0)
        c2d.lineTo(cx + w / 2.0 + 1.0 * s, cy)
        c2d.lineTo(cx - w / 2.0 + 1.0 * s, cy + h / 2.0)
        c2d.fill()
    }

    /**
     * 绘制暂停图标（⏸）
     * iOS: SemanticStatusNodeIconContext(.pause) — 两个竖条
     */
    private func drawPauseIcon(c2d: CanvasRenderingContext2D): Unit {
        let cx = this.getHalfSize()
        let cy = this.getHalfSize()
        let s = this.getIconScale()
        let barW = 3.0 * s
        let barH = 10.0 * s
        let gap = 3.0 * s

        c2d.fillStyle = this.foregroundColor
        c2d.beginPath()
        c2d.rect(cx - gap / 2.0 - barW, cy - barH / 2.0, barW, barH)
        c2d.fill()
        c2d.beginPath()
        c2d.rect(cx + gap / 2.0, cy - barH / 2.0, barW, barH)
        c2d.fill()
    }

    /**
     * 绘制取消（X）图标（下载进度时居中显示）
     * iOS: SemanticStatusNodeProgressContext — cancelEnabled=true 时显示 X
     */
    private func drawCancelIcon(c2d: CanvasRenderingContext2D): Unit {
        let cx = this.getHalfSize()
        let cy = this.getHalfSize()
        let s = this.getIconScale()
        let crossSize = 7.0 * s
        let lw = 2.0 * s

        c2d.strokeStyle = this.foregroundColor
        c2d.lineWidth = lw
        c2d.lineCap = "round"

        c2d.beginPath()
        c2d.moveTo(cx - crossSize, cy - crossSize)
        c2d.lineTo(cx + crossSize, cy + crossSize)
        c2d.stroke()
        c2d.beginPath()
        c2d.moveTo(cx + crossSize, cy - crossSize)
        c2d.lineTo(cx - crossSize, cy + crossSize)
        c2d.stroke()
    }

    // ==================== UI 构建 ====================

    func build() {
        if (this.isVisible()) {
            this.buildSemanticButton()
        }
    }

    @Builder
    private func buildSemanticButton() {
        Stack(alignContent: Alignment.Center) {
            this.buildBackground()
            this.buildContent()
        }
        .width(this.size)
        .height(this.size)
        .onClick({ _ => this.onTap() })
    }

    @Builder
    private func buildBackground() {
        Column {}
            .width(this.size)
            .height(this.size)
            .borderRadius(this.getHalfSize())
            .backgroundColor(this.backgroundColor)
    }

    @Builder
    private func buildContent() {
        if (this.isProgressType()) {
            this.buildProgressContent()
        } else {
            this.buildIconContent()
        }
    }

    /**
     * 进度类内容：环形进度条 + 可选取消 X
     * iOS: SemanticStatusNodeProgressContext — downloading / uploading 进度环
     */
    @Builder
    private func buildProgressContent() {
        Stack(alignContent: Alignment.Center) {
            Progress(value: this.animProgressVal * 100.0, total: 100.0, progressType: ProgressType.Ring)
                .width(this.size - 4.0)
                .height(this.size - 4.0)
                .color(this.foregroundColor)
                .style(RingStyleOptions(strokeWidth: 2.5.vp))
            if (this.isDownloadingType()) {
                Canvas(this.ctx)
                    .width(this.size)
                    .height(this.size)
                    .onReady({ =>
                        this.ctx.clearRect(0.0, 0.0, this.size, this.size)
                        this.drawCancelIcon(this.ctx)
                    })
            }
        }
    }

    /**
     * 图标类内容：下载箭头 / 播放三角 / 暂停双竖条（无进度环）
     * iOS: SemanticStatusNodeIconContext — .download / .play / .pause
     */
    @Builder
    private func buildIconContent() {
        Canvas(this.ctx)
            .width(this.size)
            .height(this.size)
            .onReady({ =>
                this.ctx.clearRect(0.0, 0.0, this.size, this.size)
                if (this.isDownloadType()) {
                    this.drawDownloadIcon(this.ctx)
                } else if (this.isPlayType()) {
                    this.drawPlayIcon(this.ctx)
                } else if (this.isPauseType()) {
                    this.drawPauseIcon(this.ctx)
                }
            })
    }
}
