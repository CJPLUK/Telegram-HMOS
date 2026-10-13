package ohos_app_cangjie_entry.components

/**
 * AudioBlobComponent — 动态声波 "blob" 动画可视化组件
 *
 * 对应 iOS 端 BlobView.swift (VoiceBlobView / BlobNode)。
 * 用 CanvasRenderingContext2D 实现三层同心 blob（small/medium/big）的有机形状动画。
 * 由 AudioBlobService 提供平滑电平数据驱动缩放与形变。
 *
 * 架构：
 *   - 三个 BlobState 描述各层参数
 *   - 动画循环由 AudioBlobService.setOnFrame 触发 this.draw()
 *   - draw() 基于贝塞尔平滑曲线绘制有机形状
 *   - 无 MTProtoClient 调用（纯本地动画）
 */

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.math.*
import ohos_app_cangjie_entry.services.AudioBlobService
import ohos_app_cangjie_entry.services.getAudioBlobService

// ---------------------------------------------------------------------------
// BlobPointsConfig — 单层 blob 配置参数
// ---------------------------------------------------------------------------

public class BlobPointsConfig {
    public var pointsCount: Int64
    public var minRandomness: Float64
    public var maxRandomness: Float64
    public var minSpeed: Float64
    public var maxSpeed: Float64
    public var minScale: Float64
    public var maxScale: Float64
    public var scaleSpeed: Float64
    public var isCircle: Bool

    public init(
        pointsCount!: Int64 = 8,
        minRandomness!: Float64 = 0.1,
        maxRandomness!: Float64 = 0.5,
        minSpeed!: Float64 = 0.2,
        maxSpeed!: Float64 = 0.6,
        minScale!: Float64 = 0.5,
        maxScale!: Float64 = 1.0,
        scaleSpeed!: Float64 = 0.2,
        isCircle!: Bool = false
    ) {
        this.pointsCount = pointsCount
        this.minRandomness = minRandomness
        this.maxRandomness = maxRandomness
        this.minSpeed = minSpeed
        this.maxSpeed = maxSpeed
        this.minScale = minScale
        this.maxScale = maxScale
        this.scaleSpeed = scaleSpeed
        this.isCircle = isCircle
    }
}

// ---------------------------------------------------------------------------
// BlobState — 运行时单层 blob 动画状态
// ---------------------------------------------------------------------------

public class BlobState {
    public var config: BlobPointsConfig
    public var speedLevel: Float64 = 0.0

    public init(config!: BlobPointsConfig) {
        this.config = config
    }

    public func updateSpeedLevel(newLevel: Float64): Unit {
        if (newLevel > this.speedLevel) {
            this.speedLevel = newLevel
        }
    }

    public func consumeSpeedLevel(): Unit {
        this.speedLevel = 0.0
    }
}

// ---------------------------------------------------------------------------
// 辅助：LCG 伪随机数（不使用 lambda 捕获可变变量）
// ---------------------------------------------------------------------------

var g_blobRngSeed: Int64 = 98765

private func blobNextRng(): Float64 {
    g_blobRngSeed = (g_blobRngSeed * 6364136223846793005 + 1442695040888963407) & 9223372036854775807
    if (g_blobRngSeed < 0) { g_blobRngSeed = -g_blobRngSeed }
    return Float64(g_blobRngSeed % 10000) / 10000.0
}

/**
 * 生成 blob 点集（对应 iOS BlobNode.blob(pointsCount:randomness:)）。
 * 返回 pointsCount * 2 个 Float64，交替 x/y，坐标中心 (0.5, 0.5)，归一化 [0,1]。
 */
private func generateBlobPoints(pointsCount: Int64, randomness: Float64): Array<Float64> {
    let angle = Float64.GetPI() * 2.0 / Float64(pointsCount)
    let rangeStart: Float64 = 1.0 / (1.0 + randomness / 10.0)
    let startAngle = angle * blobNextRng()
    let result = Array<Float64>(pointsCount * 2, repeat: 0.0)
    var i: Int64 = 0
    while (i < pointsCount) {
        let randPointOffset = (rangeStart + blobNextRng() * (1.0 - rangeStart)) / 2.0
        let angleRandomness = angle * 0.1
        let randAngle = angle + angle * (angleRandomness * blobNextRng() - angleRandomness * 0.5)
        let pointX = sin(startAngle + Float64(i) * randAngle)
        let pointY = cos(startAngle + Float64(i) * randAngle)
        result[i * 2]     = pointX * randPointOffset + 0.5
        result[i * 2 + 1] = pointY * randPointOffset + 0.5
        i = i + 1
    }
    return result
}

/**
 * 计算平滑系数（对应 iOS smoothness 公式）。
 */
private func computeSmoothness(count: Int64): Float64 {
    let angle = Float64.GetPI() * 2.0 / Float64(count)
    return ((4.0 / 3.0) * tan(angle / 4.0)) / sin(angle / 2.0) / 2.0
}

// ---------------------------------------------------------------------------
// AudioBlobComponent — 主组件
// ---------------------------------------------------------------------------

@Component
public class AudioBlobComponent {
    /** 组件尺寸（vp） */
    public var size: Float64 = 120.0
    /** 主色调（0xRRGGBB，默认 Telegram 蓝） */
    public var blobColor: Int64 = 0x2CA5E0
    /** 最大电平（对应 iOS maxLevel） */
    public var maxLevel: Float64 = 1.0

    @State var isAnimating: Bool = false
    @State var frameCount: Int64 = 0

    private let ctx: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))
    private var canvasReady: Bool = false
    private var canvasWidth: Float64 = 120.0
    private var canvasHeight: Float64 = 120.0

    private var smallBlob: BlobState = BlobState(config: BlobPointsConfig(
        pointsCount: 8,
        minRandomness: 0.1, maxRandomness: 0.5,
        minSpeed: 0.2, maxSpeed: 0.6,
        minScale: 0.45, maxScale: 0.55,
        scaleSpeed: 0.2, isCircle: true
    ))
    private var mediumBlob: BlobState = BlobState(config: BlobPointsConfig(
        pointsCount: 8,
        minRandomness: 1.0, maxRandomness: 1.0,
        minSpeed: 0.9, maxSpeed: 4.0,
        minScale: 0.52, maxScale: 0.87,
        scaleSpeed: 0.2, isCircle: false
    ))
    private var bigBlob: BlobState = BlobState(config: BlobPointsConfig(
        pointsCount: 8,
        minRandomness: 1.0, maxRandomness: 1.0,
        minSpeed: 0.9, maxSpeed: 4.0,
        minScale: 0.57, maxScale: 0.87,
        scaleSpeed: 0.2, isCircle: false
    ))

    // --------------- 公开控制 API ---------------

    /**
     * 启动 blob 动画。
     * 注册帧回调到 AudioBlobService，每帧触发 Canvas 重绘。
     */
    public func startAnimating(): Unit {
        if (this.isAnimating) { return }
        this.isAnimating = true
        let svc = getAudioBlobService()
        svc.setOnFrame({ =>
            this.frameCount = this.frameCount + 1
            if (this.canvasReady) {
                this.draw()
            }
        })
        svc.startAnimation()
        Hilog.info(0, "CjTelegram", "[AudioBlobComponent] startAnimating")
    }

    /**
     * 停止 blob 动画，清空画布。
     */
    public func stopAnimating(): Unit {
        if (!this.isAnimating) { return }
        this.isAnimating = false
        let svc = getAudioBlobService()
        svc.clearOnFrame()
        svc.stopAnimation()
        if (this.canvasReady) {
            this.ctx.clearRect(0.0, 0.0, this.canvasWidth, this.canvasHeight)
        }
        Hilog.info(0, "CjTelegram", "[AudioBlobComponent] stopAnimating")
    }

    /**
     * 更新音频电平（由外部录音/播放控制器调用）。
     * level: 原始电平值，范围 [0, maxLevel]。
     */
    public func updateLevel(level: Float64): Unit {
        let normalized = if (this.maxLevel > 0.0) {
            let v = level / this.maxLevel
            if (v > 1.0) { 1.0 } else if (v < 0.0) { 0.0 } else { v }
        } else {
            0.0
        }
        let svc = getAudioBlobService()
        svc.setLevel(normalized)
        this.smallBlob.updateSpeedLevel(normalized)
        this.mediumBlob.updateSpeedLevel(normalized)
        this.bigBlob.updateSpeedLevel(normalized)
    }

    // --------------- 内部绘制逻辑 ---------------

    private func draw(): Unit {
        let svc = getAudioBlobService()
        let level = svc.getPresentationLevel()
        let w = this.canvasWidth
        let h = this.canvasHeight
        let cx = w / 2.0
        let cy = h / 2.0
        let baseRadius = (if (w < h) { w } else { h }) * 0.5

        this.ctx.clearRect(0.0, 0.0, w, h)

        // 大球（最底层，alpha 0.15）
        this.ctx.globalAlpha = 0.15
        this.drawBlobLayer(this.bigBlob, cx, cy, baseRadius, level)

        // 中球（alpha 0.3）
        this.ctx.globalAlpha = 0.3
        this.drawBlobLayer(this.mediumBlob, cx, cy, baseRadius, level)

        // 小球（最顶层，isCircle，alpha 1.0）
        this.ctx.globalAlpha = 1.0
        this.drawCircleLayer(cx, cy, baseRadius, level,
            this.smallBlob.config.minScale,
            this.smallBlob.config.maxScale)

        this.ctx.globalAlpha = 1.0
    }

    /**
     * 绘制有机 blob 层（贝塞尔平滑曲线，对应 iOS BlobNode + smoothCurve）。
     */
    private func drawBlobLayer(
        blob: BlobState,
        cx: Float64, cy: Float64,
        radius: Float64, level: Float64
    ): Unit {
        let cfg = blob.config
        let scale = cfg.minScale + (cfg.maxScale - cfg.minScale) * level
        let scaledR = radius * scale

        let randomness = cfg.minRandomness + (cfg.maxRandomness - cfg.minRandomness) * blob.speedLevel
        let pts = generateBlobPoints(cfg.pointsCount, randomness)
        blob.consumeSpeedLevel()

        let count = cfg.pointsCount
        let smoothness = computeSmoothness(count)
        this.ctx.beginPath()
        var i: Int64 = 0
        while (i < count) {
            let px = (pts[i * 2]     - 0.5) * 2.0 * scaledR + cx
            let py = (pts[i * 2 + 1] - 0.5) * 2.0 * scaledR + cy
            let nextIdx = (i + 1) % count
            let nx = (pts[nextIdx * 2]     - 0.5) * 2.0 * scaledR + cx
            let ny = (pts[nextIdx * 2 + 1] - 0.5) * 2.0 * scaledR + cy
            let prevIdx = if (i == 0) { count - 1 } else { i - 1 }
            let ppx = (pts[prevIdx * 2]     - 0.5) * 2.0 * scaledR + cx
            let ppy = (pts[prevIdx * 2 + 1] - 0.5) * 2.0 * scaledR + cy
            let nnIdx = (nextIdx + 1) % count
            let nnx = (pts[nnIdx * 2]     - 0.5) * 2.0 * scaledR + cx
            let nny = (pts[nnIdx * 2 + 1] - 0.5) * 2.0 * scaledR + cy
            let cp1x = px + smoothness * (nx - ppx) * 0.5
            let cp1y = py + smoothness * (ny - ppy) * 0.5
            let cp2x = nx - smoothness * (nnx - px) * 0.5
            let cp2y = ny - smoothness * (nny - py) * 0.5
            if (i == 0) {
                this.ctx.moveTo(px, py)
            }
            this.ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, nx, ny)
            i = i + 1
        }
        this.ctx.closePath()
        this.ctx.fillStyle = this.blobColor
        this.ctx.fill()
    }

    /**
     * 绘制圆形 blob 层（对应 iOS isCircle 的小球）。
     */
    private func drawCircleLayer(
        cx: Float64, cy: Float64,
        radius: Float64, level: Float64,
        minScale: Float64, maxScale: Float64
    ): Unit {
        let scale = minScale + (maxScale - minScale) * level
        let scaledR = radius * scale
        this.ctx.beginPath()
        this.ctx.arc(cx, cy, scaledR, 0.0, Float64.GetPI() * 2.0)
        this.ctx.closePath()
        this.ctx.fillStyle = this.blobColor
        this.ctx.fill()
    }

    // --------------- 生命周期 ---------------

    public func aboutToAppear(): Unit {
        Hilog.info(0, "CjTelegram", "[AudioBlobComponent] aboutToAppear")
    }

    public func aboutToDisappear(): Unit {
        this.stopAnimating()
        Hilog.info(0, "CjTelegram", "[AudioBlobComponent] aboutToDisappear")
    }

    // --------------- UI 构建 ---------------

    func build() {
        Canvas(this.ctx)
            .width(this.size)
            .height(this.size)
            .onReady({
                =>
                this.canvasWidth = this.size
                this.canvasHeight = this.size
                this.canvasReady = true
                this.ctx.clearRect(0.0, 0.0, this.canvasWidth, this.canvasHeight)
                Hilog.info(0, "CjTelegram", "[AudioBlobComponent] Canvas ready")
            })
    }
}
