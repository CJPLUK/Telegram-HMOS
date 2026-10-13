package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import std.collection.ArrayList
import std.sync.*
import std.time.*
import std.random.Random
import ohos_app_cangjie_entry.app.getAppState

/**
 * 剧透遮罩粒子动画组件
 *
 * 对应 iOS InvisibleInkDustNode.swift — ArkUI Canvas 实现版本
 *
 * 功能：
 * - 在文字区域上覆盖随机闪烁的白色粒子点（遮罩效果）
 * - 点击后触发揭示动画：粒子渐隐消散，文字渐显
 * - 揭示态后透明度归零；未揭示态保持粒子动画
 * - 通过 InvisibleInkDustService 管理揭示状态（msgId 键控）
 *
 * 使用示例（在 MessageBubble 中嵌套）：
 *   InvisibleInkDustComponent(
 *       msgId: 123,
 *       compWidth: 200.0,
 *       compHeight: 40.0
 *   )
 */
@Component
public class InvisibleInkDustComponent {
    // 消息 ID（用于状态持久化）
    public var msgId: Int64 = 0
    // 组件尺寸
    public var compWidth: Float64 = 200.0
    public var compHeight: Float64 = 40.0
    // 粒子颜色（Int64 十六进制，默认白色，实现 FillStyle 接口）
    public var dustColor: Int64 = 0xFFFFFF
    // 文字矩形区域（粒子散布范围）
    public var rects: Array<SpoilerRect> = Array<SpoilerRect>(0, { _i: Int64 =>
        SpoilerRect(0.0, 0.0, 1.0, 1.0)
    })
    // 揭示后回调（通知父组件显示文字）
    public var onRevealed: () -> Unit = { => }

    // -------- 内部状态 --------
    @State var isRevealed: Bool = false
    @State var overlayOpacity: Float64 = 1.0

    // Canvas 渲染上下文
    private let canvasCtx: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))

    // 粒子数组（动画帧驱动）
    private var particles: Array<DustParticle> = Array<DustParticle>(0, { _i: Int64 =>
        DustParticle(0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0)
    })
    private var animRng: Random = Random()
    private var animRunning: Bool = false
    private var animMutex: ReentrantMutex = ReentrantMutex()

    // -------- 辅助方法（不能在 build/@Builder 中声明 let）--------

    private func getService(): InvisibleInkDustService {
        InvisibleInkDustService.shared()
    }

    private func checkRevealedState(): Bool {
        this.getService().isRevealed(this.msgId)
    }

    private func initParticles(): Unit {
        let absId: Int64 = if (this.msgId < 0) { -this.msgId } else { this.msgId }
        let seed: Int64 = absId + 12345
        let seedU = UInt64(seed)
        this.particles = this.getService().generateParticles(this.rects, 300, seed)
        this.animRng = Random(seedU + UInt64(1))
    }

    private func startAnimLoop(): Unit {
        synchronized (this.animMutex) {
            if (this.animRunning) { return }
            this.animRunning = true
        }
        let _ = spawn {
            let svc = InvisibleInkDustService.shared()
            let dt: Float64 = 0.033
            while (true) {
                var shouldStop = false
                synchronized (this.animMutex) {
                    if (!this.animRunning) { shouldStop = true }
                }
                if (shouldStop) { break }
                if (!getAppState().isInForeground()) {
                    sleep(Duration.millisecond * 100)
                    continue
                }
                svc.tickParticles(this.particles, dt, this.rects, this.animRng)
                launch {
                    this.renderFrame()
                }
                sleep(Duration.millisecond * 33)
            }
        }
    }

    private func stopAnimLoop(): Unit {
        synchronized (this.animMutex) {
            this.animRunning = false
        }
    }

    private func renderFrame(): Unit {
        let ctx = this.canvasCtx
        ctx.clearRect(0.0, 0.0, this.compWidth, this.compHeight)

        if (this.isRevealed && this.overlayOpacity <= 0.01) { return }

        let colorVal = this.dustColor
        for (p in this.particles) {
            let alpha = p.alpha * this.overlayOpacity
            if (alpha <= 0.01) { continue }
            ctx.globalAlpha = Some(alpha)
            ctx.fillStyle = Some(colorVal)
            ctx.beginPath()
            ctx.arc(p.x, p.y, p.radius, 0.0, 6.28318)
            ctx.fill()
        }
        ctx.globalAlpha = Some(1.0)
    }

    private func doReveal(tapXPos: Float64, tapYPos: Float64): Unit {
        if (this.isRevealed) { return }
        this.getService().reveal(this.msgId)
        this.isRevealed = true
        Hilog.info(0, "CjTelegram", "[InvisibleInk] spoiler revealed")

        let _ = spawn {
            let steps: Int64 = 20
            for (i in 1..steps + 1) {
                let progress = Float64(i) / Float64(steps)
                launch {
                    this.overlayOpacity = 1.0 - progress
                    this.renderFrame()
                }
                sleep(Duration.millisecond * 15)
            }
            launch {
                this.overlayOpacity = 0.0
                this.stopAnimLoop()
                this.onRevealed()
            }
        }
    }

    // -------- 生命周期 --------

    public override func aboutToAppear(): Unit {
        this.isRevealed = this.checkRevealedState()
        this.overlayOpacity = if (this.isRevealed) { 0.0 } else { 1.0 }
        if (!this.isRevealed) {
            this.initParticles()
            this.startAnimLoop()
        }
    }

    public override func aboutToDisappear(): Unit {
        this.stopAnimLoop()
    }

    // -------- 构建 --------

    func build() {
        Stack {
            Canvas(this.canvasCtx)
                .width(this.compWidth)
                .height(this.compHeight)
                .opacity(this.overlayOpacity)
                .onReady({ =>
                    this.renderFrame()
                })
        }
        .width(this.compWidth)
        .height(this.compHeight)
        .onClick({ _evt: ClickEvent =>
            if (!this.isRevealed) {
                this.doReveal(0.0, 0.0)
            }
        })
    }
}
