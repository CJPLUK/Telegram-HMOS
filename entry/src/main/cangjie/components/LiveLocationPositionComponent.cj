package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import std.sync.*
import std.time.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    LiveLocationPositionService,
    LiveLocationPositionData,
    getLiveLocationPositionService
}
import ohos_app_cangjie_entry.models.Message

/**
 * LiveLocationPositionComponent — 实时位置头像 pin 组件
 *
 * 对应 iOS ChatMessageLiveLocationPositionNode:
 * - 外层尺寸: 62×74 vp（含顶部 pin 图钉区 + 底部尖端）
 * - 圆形头像 (42×42，左偏 10，上偏 9) — 发送者头像或首字母占位
 * - 脉冲圈 (120 直径，缩放 0.0→1.0，透明度 1.0→0.0，周期 3s 循环)
 * - 方向箭头 (70×70，顺时针旋转对应航向)
 *
 * 使用方式（在 MessageBubble locationContent 中嵌入）:
 *   LiveLocationPositionComponent(
 *       message: this.message,
 *       prevLat: 0.0,
 *       prevLng: 0.0
 *   )
 *
 * 调用链：
 *   aboutToAppear → startPulseAnimation → Timer.repeat(60ms)
 *   → animateStep() → launch { @State pulseScale / pulseAlpha / animTick }
 *   → build() → Stack { pulseRing / arrowLayer / pinBackground / avatarLayer }
 *
 * S-64 合规: aboutToAppear / aboutToDisappear 均为 public override func ... (): Unit
 * R-69 合规: Timer 回调内所有 @State 写操作均包裹在 launch{} 内
 */
@Component
public class LiveLocationPositionComponent {

    // ==================== 输入属性 ====================

    // 被渲染的消息（含 isLiveLocation / locationLat / locationLng / senderId / senderName）
    public var message: Message = Message()

    // 上一次已知坐标（用于从位移推算方向角）
    public var prevLat: Float64 = 0.0
    public var prevLng: Float64 = 0.0

    // ==================== 内部状态 ====================

    // 渲染数据快照
    @State var posData: LiveLocationPositionData = LiveLocationPositionData()

    // 脉冲动画参数（scale: 0.0→1.0 Float32；alpha: 1.0→0.0，周期 3s）
    @State var pulseScale: Float32 = Float32(0.0)
    @State var pulseAlpha: Float64 = 1.0

    // 触发 Canvas 方向箭头重绘的计数器
    @State var animTick: Int64 = 0

    // 动画进度（0.0..1.0，每帧递增 1/50 ≈ 60ms×50=3s 一轮）
    var animProgress: Float64 = 0.0

    // 动画定时器句柄（非 @State）
    var pulseTimer: Option<Timer> = None<Timer>

    // 数据服务
    var service: LiveLocationPositionService = getLiveLocationPositionService()

    // Canvas 上下文（方向箭头）
    let arrowCtx: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))

    // ==================== 生命周期（S-64: public override func ...(): Unit）====================

    public override func aboutToAppear(): Unit {
        this.refreshPositionData()
        if (this.posData.active) {
            this.startPulseAnimation()
        }
    }

    public override func aboutToDisappear(): Unit {
        this.stopPulseAnimation()
    }

    // ==================== 数据刷新 ====================

    private func refreshPositionData(): Unit {
        let data = this.service.extractPositionData(
            this.message,
            this.prevLat,
            this.prevLng
        )
        launch {
            this.posData = data
        }
    }

    // ==================== 脉冲动画（R-69: launch{} 包裹 @State 写）====================

    private func startPulseAnimation(): Unit {
        if (this.pulseTimer.isSome()) {
            return
        }
        // 60ms 一帧，3s 周期（50 帧）
        this.pulseTimer = Some(Timer.repeat(
            Duration.millisecond * 60,
            Duration.millisecond * 60,
            { => this.animateStep() },
            style: CatchupStyle.Skip
        ))
    }

    private func stopPulseAnimation(): Unit {
        match (this.pulseTimer) {
            case Some(t) =>
                t.cancel()
                this.pulseTimer = None<Timer>
            case None => ()
        }
    }

    private func animateStep(): Unit {
        this.animProgress = this.animProgress + 0.02
        if (this.animProgress > 1.0) {
            this.animProgress = 0.0
        }
        let p = this.animProgress
        // iOS 对应 keyTimes: scale 0→0.49→0.88→1.0 values: 0→0.72→1.0→1.0
        // alpha 0→0.4→0.62→1.0 values: 1.0→0.2→0.0→0.0
        let scaleF64: Float64
        let alpha: Float64
        if (p < 0.49) {
            scaleF64 = p / 0.49 * 0.72
            alpha = 1.0 - (p / 0.49) * 0.8
        } else if (p < 0.88) {
            let t2 = (p - 0.49) / 0.39
            scaleF64 = 0.72 + t2 * 0.28
            alpha = 0.2 - t2 * 0.2
        } else {
            scaleF64 = 1.0
            alpha = 0.0
        }
        let scaleF32 = Float32(scaleF64)
        // R-69: @State 写操作包裹在 launch{}
        launch {
            this.pulseScale = scaleF32
            this.pulseAlpha = alpha
            this.animTick = this.animTick + 1
        }
    }

    // ==================== 辅助计算（不在 build/@Builder 中用 let）====================

    private func getAvatarPath(): String {
        this.posData.avatarPath
    }

    private func getPlaceholder(): String {
        this.service.getAvatarPlaceholder(this.posData.senderName)
    }

    private func hasAvatar(): Bool {
        this.posData.avatarPath.size > 0
    }

    private func isActive(): Bool {
        this.posData.active
    }

    private func hasHeading(): Bool {
        match (this.posData.headingRadians) {
            case Some(_) => true
            case None => false
        }
    }

    private func getHeadingDeg(): Float32 {
        match (this.posData.headingRadians) {
            case Some(rad) => Float32(rad * 180.0 / 3.14159265358979323846)
            case None => Float32(0.0)
        }
    }

    private func getAvatarAlpha(): Float64 {
        if (this.posData.active) { 1.0 } else { 0.6 }
    }

    // ==================== 方向箭头绘制 ====================

    private func drawArrow(c2d: CanvasRenderingContext2D): Unit {
        let w = 70.0
        let cx = w / 2.0
        let cy = w / 2.0
        let r = w / 2.0
        let innerR = 5.0
        let pi = 3.14159265358979323846
        // 扇形渐变弧（对应 iOS radial gradient: 0.5 alpha→0.3→0.0，angle span pi/4）
        let startAngle = pi / 2.0 + pi / 8.0
        let endAngle = pi / 2.0 - pi / 8.0
        c2d.beginPath()
        c2d.moveTo(cx, cy)
        // arc(x, y, radius, startAngle, endAngle, counterclockwise:)
        c2d.arc(cx, cy, r, startAngle, endAngle, counterclockwise: true)
        c2d.closePath()
        c2d.fillStyle = 0x7F0088FF
        c2d.fill()
        // 内圆孔（clear 等效：覆盖背景色）
        c2d.beginPath()
        c2d.arc(cx, cy, innerR, 0.0, 2.0 * pi, counterclockwise: false)
        c2d.fillStyle = 0xFF000000
        c2d.globalAlpha = 0.0
        c2d.fill()
        c2d.globalAlpha = 1.0
        Hilog.info(0, "CjTelegram", "[LiveLocationPositionComponent] drawArrow called")
    }

    // ==================== UI ====================

    func build() {
        Stack() {
            // 层 1: 脉冲圈（仅 active 时显示）
            if (this.isActive()) {
                Column {}
                    .width(60)
                    .height(60)
                    .borderRadius(30)
                    .backgroundColor(0x450088FF)
                    .scale(x: this.pulseScale, y: this.pulseScale)
                    .opacity(this.pulseAlpha)
                    .position(x: 1, y: 34)
            }

            // 层 2: 方向箭头（active 且有方向时）
            if (this.isActive() && this.hasHeading()) {
                Canvas(this.arrowCtx)
                    .width(70)
                    .height(70)
                    .rotate(angle: this.getHeadingDeg())
                    .position(x: -4, y: 29)
                    .onReady({ =>
                        this.drawArrow(this.arrowCtx)
                    })
            }

            // 层 3: pin 背景（62×74 蓝色圆头 + 三角尖端）
            Stack() {
                // pin 头部：蓝色圆形背景
                Column {}
                    .width(62)
                    .height(62)
                    .borderRadius(31)
                    .backgroundColor(0xFF2196F3)
                    .position(x: 0, y: 0)

                // pin 尖端三角
                Column {}
                    .width(14)
                    .height(14)
                    .backgroundColor(0xFF2196F3)
                    .rotate(angle: 45.0)
                    .position(x: 24, y: 56)
            }
            .width(62)
            .height(74)

            // 层 4: 头像（圆形，42×42，偏移 10,9）
            Stack() {
                if (this.hasAvatar()) {
                    Image(this.getAvatarPath())
                        .width(42)
                        .height(42)
                        .borderRadius(21)
                        .clip(true)
                        .objectFit(ImageFit.Cover)
                        .opacity(this.getAvatarAlpha())
                } else {
                    // 首字母占位
                    Column {
                        Text(this.getPlaceholder())
                            .fontSize(18)
                            .fontColor(0xFFFFFFFF)
                            .fontWeight(FontWeight.Medium)
                    }
                    .width(42)
                    .height(42)
                    .borderRadius(21)
                    .backgroundColor(0xFF5C6BC0)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .opacity(this.getAvatarAlpha())
                }
            }
            .position(x: 10, y: 9)
        }
        .width(62)
        .height(74)
    }
}
