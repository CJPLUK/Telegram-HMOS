package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog

/**
 * P2-306: Confetti 彩带粒子动画视图（pages 包内联版）
 *
 * iOS 对照: ConfettiEffect/Sources/ConfettiView.swift
 *
 * 为避免跨包 @Component @State 实例化问题（S-015），将 ConfettiComponent 内联到 pages 包。
 *
 * 实现细节:
 *   - ~150 粒子（70 顶部降落 + 80 两侧爆发）
 *   - 多色: 绿/紫/蓝/橙（对应 iOS 0x56CE6B / 0xCD89D0 / 0x1E9AFF / 0xFF8724）
 *   - 多形状: 圆形(type=0) + 长条(type=1)，通过 CanvasRenderingContext2D 绘制
 *   - 物理: 重力加速度 g=9.8、阻尼 0.93、湍流（横向随机扰动）
 *   - 动画: spawn 后台循环每 16ms tick，launch{} 写 @State tickCount 驱动 Canvas 重绘
 *   - 离屏清理: 所有粒子 y > canvasH + 30 时 running=false，停止 spawn 循环
 *
 * 约束遵守:
 *   R-117: Canvas onReady 闭包不 let/var（数据来自 @State / private let）
 *   R-118: Canvas 重绘通过 @State 驱动（tickCount 变化 → build 重新执行 → Canvas onReady 重绘）
 *   S-001: @State 写在 launch{} 内（spawn 后台线程中）
 *   S-005: build() 内无 let/var（调用辅助 func）
 *   D-002: 本组件非独立 NavDestination 页面，作为 overlay 嵌入 PremiumSubscriptionFlowPage
 */
@Component
public class ConfettiView {
    // @State 驱动 Canvas 重绘（每 tick 递增）
    @State var tickCount: Int64 = 0
    @State var isRunning: Bool = false

    // Canvas 上下文
    private let settings: RenderingContextSettings = RenderingContextSettings(antialias: true)
    private let context: CanvasRenderingContext2D = CanvasRenderingContext2D(this.settings)

    // 粒子数组（静态结构，物理更新后通过 tickCount 触发重绘）
    private var particles: Array<ConfettiViewParticle> = Array<ConfettiViewParticle>(0, repeat: ConfettiViewParticle())
    private var canvasWidth: Float64 = 390.0
    private var canvasHeight: Float64 = 844.0

    protected override func aboutToAppear(): Unit {
        this.startAnimation()
    }

    private func startAnimation(): Unit {
        if (this.isRunning) { return }
        this.particles = this.createParticles()
        this.isRunning = true
        let _ = spawn {
            this.runPhysicsLoop()
        }
        Hilog.info(0, "CjTelegram", "[ConfettiView] animation started with ${this.particles.size} particles")
    }

    private func createParticles(): Array<ConfettiViewParticle> {
        let list: Array<ConfettiViewParticle> = Array<ConfettiViewParticle>(150, { _i: Int64 => ConfettiViewParticle() })
        let colors: Array<UInt32> = [0xFF56CE6B, 0xFFCD89D0, 0xFF1E9AFF, 0xFFFF8724]
        let cw = this.canvasWidth
        let ch = this.canvasHeight

        // 70 顶部降落粒子（从屏幕顶上方落下）
        var i: Int64 = 0
        while (i < 70) {
            let p = ConfettiViewParticle()
            p.x = Float64(i * 6 % Int64(cw))
            p.y = Float64(-Int64(ch) + i * 12 % Int64(ch))
            p.vx = Float64((i % 7) - 3) * 0.3
            p.vy = 3.0 + Float64(i % 5) * 0.4
            p.mass = 40.0 + Float64(i % 10) * 1.0
            p.angularVelocity = 1.0 + Float64(i % 6) * 0.8
            p.colorIndex = i % 4
            p.shapeType = i % 2
            p.sizeScale = 0.8 + Float64(i % 8) * 0.1
            p.colors = colors
            list[i] = p
            i += 1
        }

        // 80 侧面爆发粒子（从两侧底部 9/10 处发射，弧线向上）
        let sideY = ch * 0.9
        let scaleFactor = 2400.0 * ch / 896.0
        i = 0
        while (i < 80) {
            let p = ConfettiViewParticle()
            let sideIndex: Int64 = i % 2
            let sideSign: Float64 = if (sideIndex == 0) { 1.0 } else { -1.0 }
            let baseX: Float64 = if (sideIndex == 0) { -20.0 } else { cw + 20.0 }
            let originAngle = Float64(i % 63) * 0.1
            let originAmplitude = Float64(i % 115)
            p.x = baseX + cvSinF64(originAngle) * originAmplitude
            p.y = sideY + cvCosF64(originAngle) * originAmplitude
            let speedBase = Float64(110 + i % 10)
            let velScale = (1.1 + Float64(i % 3) * 0.1) * scaleFactor / speedBase
            let vAngle = 1.5707963 + cvAtanF64(sideY / (cw * 0.8))
            let variation = Float64(i % 9) * 0.02 - 0.09
            let finalAngle = vAngle + variation
            p.vx = sideSign * velScale * cvSinF64(finalAngle)
            p.vy = velScale * cvCosF64(finalAngle)
            p.mass = speedBase
            p.angularVelocity = 1.0 + Float64(i % 5) * 0.7
            p.colorIndex = (i + 2) % 4
            p.shapeType = (i + 1) % 2
            p.sizeScale = 0.8 + Float64(i % 8) * 0.1
            p.colors = colors
            list[70 + i] = p
            i += 1
        }
        return list
    }

    private func runPhysicsLoop(): Unit {
        let g: Float64 = 9.8
        let damping: Float64 = 0.93
        let maxY: Float64 = this.canvasHeight + 30.0
        var localTime: Int64 = 0

        while (this.isRunning) {
            sleep(Duration.millisecond * 16)
            localTime += 1
            let turbIndex = localTime % 20

            var allBelowGround = true
            var k: Int64 = 0
            while (k < this.particles.size) {
                let p = this.particles[k]
                if (p.y < maxY) {
                    allBelowGround = false
                }
                let dt: Float64 = 0.016
                p.x = p.x + p.vx * dt
                p.y = p.y + p.vy * dt
                p.rotationAngle = p.rotationAngle + p.angularVelocity * dt
                p.vy = p.vy + g * p.mass * dt
                if (p.vy < 0.0) {
                    p.vx = p.vx * damping
                    p.vy = p.vy * damping
                } else {
                    let turbulence = Float64((turbIndex + k) % 32) * 2.0 - 32.0
                    p.vx = p.vx + turbulence * dt
                }
                this.particles[k] = p
                k += 1
            }

            let tc = localTime
            launch {
                this.tickCount = tc
            }

            if (allBelowGround && localTime > 60) {
                launch {
                    this.isRunning = false
                    Hilog.info(0, "CjTelegram", "[ConfettiView] animation finished")
                }
                return
            }
        }
    }

    private func drawParticles(): Unit {
        let ctx = this.context
        ctx.clearRect(0.0, 0.0, this.canvasWidth, this.canvasHeight)

        var i: Int64 = 0
        while (i < this.particles.size) {
            let p = this.particles[i]
            if (p.y > this.canvasHeight + 30.0 || p.y < -200.0) {
                i += 1
                continue
            }

            let colorIdx = p.colorIndex % 4
            let colorVal: UInt32 = p.colors[colorIdx]
            ctx.fillStyle = Int64(colorVal)

            ctx.save()
            ctx.translate(p.x, p.y)
            ctx.rotate(p.rotationAngle)

            let baseSize: Float64 = 8.0 * p.sizeScale
            if (p.shapeType == 0) {
                ctx.beginPath()
                ctx.arc(0.0, 0.0, baseSize * 0.5, 0.0, 6.28318, counterclockwise: false)
                ctx.fill()
            } else {
                let hw = baseSize * 0.125
                let hh = baseSize * 0.375
                ctx.fillRect(-hw, -hh, hw * 2.0, hh * 2.0)
            }

            ctx.restore()
            i += 1
        }
    }

    private func tickDesc(): String {
        return "tick_${this.tickCount}"
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Canvas(this.context)
                .width(100.percent)
                .height(100.percent)
                .onReady({
                    =>
                    this.drawParticles()
                })
            Text(this.tickDesc())
                .width(0)
                .height(0)
                .opacity(0.0)
        }
        .width(100.percent)
        .height(100.percent)
    }
}

/**
 * 粒子数据结构（非 @State，物理更新后通过 tickCount 触发重绘）
 */
public class ConfettiViewParticle {
    public var x: Float64 = 0.0
    public var y: Float64 = 0.0
    public var vx: Float64 = 0.0
    public var vy: Float64 = 0.0
    public var mass: Float64 = 1.0
    public var angularVelocity: Float64 = 1.0
    public var rotationAngle: Float64 = 0.0
    public var colorIndex: Int64 = 0
    public var shapeType: Int64 = 0
    public var sizeScale: Float64 = 1.0
    public var colors: Array<UInt32> = Array<UInt32>(4, repeat: 0xFF56CE6B)

    public init() {}
}

// Math helpers (inline approximations, prefixed cv to avoid collision)
func cvSinF64(x: Float64): Float64 {
    var v = x
    while (v > 3.14159265) { v = v - 6.28318530 }
    while (v < -3.14159265) { v = v + 6.28318530 }
    let v2 = v * v
    return v * (1.0 - v2 / 6.0 * (1.0 - v2 / 20.0 * (1.0 - v2 / 42.0)))
}

func cvCosF64(x: Float64): Float64 {
    return cvSinF64(x + 1.5707963268)
}

func cvAtanF64(x: Float64): Float64 {
    if (x > 1.0) {
        return 1.5707963268 - cvAtanF64(1.0 / x)
    }
    if (x < -1.0) {
        return -1.5707963268 - cvAtanF64(1.0 / x)
    }
    let x2 = x * x
    return x * (1.0 - x2 / 3.0 * (1.0 - x2 / 5.0 * (1.0 - x2 / 7.0)))
}
