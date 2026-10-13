package ohos_app_cangjie_entry.components
import ohos_app_cangjie_entry.utils.safeAnimateTo

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.services.{
    getRadialStatusService,
    RADIAL_STATUS_NONE,
    RADIAL_STATUS_DOWNLOAD,
    RADIAL_STATUS_PLAY,
    RADIAL_STATUS_PAUSE,
    RADIAL_STATUS_CHECK,
    RADIAL_STATUS_DOWNLOADING,
    RADIAL_STATUS_UPLOADING,
    RADIAL_STATUS_CLOUD_PROGRESS
}

/**
 * RadialStatusComponent — 环形状态指示组件
 *
 * 对应 iOS RadialStatusNode（RadialStatusNode.swift + 各 ContentNode）：
 *   - 纯渲染组件，通过 RadialStatusService 获取当前状态并渲染
 *   - 支持：下载箭头、上传进度环、下载进度环（+取消 X）、播放三角、暂停双竖条、勾选√、云端进度环
 *
 * 渲染方式：
 *   - 进度环：Progress(value:, total:, progressType: ProgressType.Ring) + animateTo 平滑过渡
 *   - 图标：Canvas CanvasRenderingContext2D（arc / lineTo / stroke / fill）
 *   - 背景圆：Column.borderRadius 实现
 *
 * 用法：
 *   RadialStatusComponent(msgId: message.id, size: 40.0)
 *
 * 与外层集成（如 MessageBubble 文件消息下载按钮）：
 *   getRadialStatusService().setStatus(msgId: msg.id, status: RADIAL_STATUS_DOWNLOADING,
 *       progress: 0.0, cancelEnabled: true)
 *   ...（下载中更新 progress）...
 *   getRadialStatusService().clearStatus(msgId: msg.id)
 *
 * 调用链：
 *   aboutToAppear → startRefreshTimer → Timer.repeat(200ms)
 *   → refreshStatus() → getRadialStatusService().getStatusKey(msgId)
 *   → @State statusKey / progressVal → build() → buildContent()
 *
 * S-64: aboutToAppear/aboutToDisappear 必须 public override func ... : Unit
 * R-69: Timer 回调内 @State 写必须包 launch{}
 */
@Component
public class RadialStatusComponent {
    // 绑定的消息 ID（用于从 RadialStatusService 查询状态）
    public var msgId: Int64 = 0

    // 组件尺寸（vp），默认 40
    public var size: Float64 = 40.0

    // 前景颜色（进度环 / 图标颜色），默认白色
    public var foregroundColor: Int64 = 0xFFFFFFFF

    // 背景圆颜色，默认半透明黑色
    public var backgroundColor: Int64 = 0x88000000

    // 点击回调（如文件下载取消 / 暂停播放切换）
    public var onTap: () -> Unit = { => }

    // 当前状态 key（驱动重绘，格式：statusType_progressInt）
    @State var statusKey: String = "none_0"

    // 当前状态类型字符串
    @State var statusType: String = RADIAL_STATUS_NONE

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
        Hilog.info(0, "CjTelegram", "[RadialStatusComponent] aboutToAppear msgId=" + this.msgId.toString(), [])
    }

    public override func aboutToDisappear(): Unit {
        this.stopRefreshTimer()
        Hilog.info(0, "CjTelegram", "[RadialStatusComponent] aboutToDisappear msgId=" + this.msgId.toString(), [])
    }

    // ==================== 定时刷新（用于进度更新）====================

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
     * 从 RadialStatusService 读取最新状态并更新 @State
     * R-69: Timer 内 @State 写必须包 launch{}
     */
    private func refreshStatus(): Unit {
        let svc = getRadialStatusService()
        let newKey = svc.getStatusKey(this.msgId)
        let newType = svc.getStatusType(this.msgId)
        let newProg = svc.getProgress(this.msgId)
        launch {
            if (newKey != this.statusKey) {
                this.statusKey = newKey
                this.statusType = newType
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
        this.statusType != RADIAL_STATUS_NONE
    }

    private func isProgressType(): Bool {
        this.statusType == RADIAL_STATUS_DOWNLOADING ||
        this.statusType == RADIAL_STATUS_UPLOADING ||
        this.statusType == RADIAL_STATUS_CLOUD_PROGRESS
    }

    private func isCloudProgressType(): Bool {
        this.statusType == RADIAL_STATUS_CLOUD_PROGRESS
    }

    private func isDownloadingType(): Bool {
        this.statusType == RADIAL_STATUS_DOWNLOADING
    }

    private func isDownloadType(): Bool {
        this.statusType == RADIAL_STATUS_DOWNLOAD
    }

    private func isPlayType(): Bool {
        this.statusType == RADIAL_STATUS_PLAY
    }

    private func isPauseType(): Bool {
        this.statusType == RADIAL_STATUS_PAUSE
    }

    private func isCheckType(): Bool {
        this.statusType == RADIAL_STATUS_CHECK
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
     * iOS: RadialDownloadContentNode — 向下箭头线
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
     * iOS: RadialStatusIconContentNode .play
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
     * iOS: RadialStatusIconContentNode .pause — 两个竖条
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
     * 绘制勾选图标（✓）
     * iOS: RadialCheckContentNode
     */
    private func drawCheckIcon(c2d: CanvasRenderingContext2D): Unit {
        let cx = this.getHalfSize()
        let cy = this.getHalfSize()
        let s = this.getIconScale()
        let lw = 2.0 * s

        c2d.strokeStyle = this.foregroundColor
        c2d.lineWidth = lw
        c2d.lineCap = "round"
        c2d.lineJoin = "round"

        c2d.beginPath()
        c2d.moveTo(cx - 7.0 * s, cy)
        c2d.lineTo(cx - 2.0 * s, cy + 5.0 * s)
        c2d.lineTo(cx + 7.0 * s, cy - 6.0 * s)
        c2d.stroke()
    }

    /**
     * 绘制取消（X）图标（下载进度时居中显示）
     * iOS: RadialProgressContentCancelNode
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

    /**
     * 绘制云端进度环背景轨道（半透明灰白底弧，仅 cloudProgress 使用）
     * iOS: RadialCloudProgressContentNode — backgroundStrokeColor 半透明轨道
     */
    private func drawCloudProgressTrack(c2d: CanvasRenderingContext2D): Unit {
        let cx = this.getHalfSize()
        let cy = this.getHalfSize()
        let r = this.getRadius()
        let lw = 2.0 * this.getIconScale()
        let pi = 3.14159265358979

        c2d.strokeStyle = 0x4DFFFFFF
        c2d.lineWidth = lw
        c2d.lineCap = "round"
        c2d.beginPath()
        c2d.arc(cx, cy, r, 0.0, 2.0 * pi, counterclockwise: false)
        c2d.stroke()
    }

    // ==================== UI 构建 ====================

    func build() {
        if (this.isVisible()) {
            this.buildRadialButton()
        }
    }

    @Builder
    private func buildRadialButton() {
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
     * iOS: RadialProgressContentNode / RadialCloudProgressContentNode
     */
    @Builder
    private func buildProgressContent() {
        Stack(alignContent: Alignment.Center) {
            if (this.isCloudProgressType()) {
                Canvas(this.ctx)
                    .width(this.size)
                    .height(this.size)
                    .onReady({ =>
                        this.ctx.clearRect(0.0, 0.0, this.size, this.size)
                        this.drawCloudProgressTrack(this.ctx)
                    })
            }
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
                        if (getRadialStatusService().getCancelEnabled(this.msgId)) {
                            this.drawCancelIcon(this.ctx)
                        }
                    })
            }
        }
    }

    /**
     * 图标类内容：下载箭头 / 播放 / 暂停 / 勾选（无进度环）
     * iOS: RadialDownloadContentNode / RadialStatusIconContentNode / RadialCheckContentNode
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
                } else if (this.isCheckType()) {
                    this.drawCheckIcon(this.ctx)
                }
            })
    }
}
