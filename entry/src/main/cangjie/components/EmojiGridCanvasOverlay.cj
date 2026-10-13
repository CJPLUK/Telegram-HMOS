package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.sync.*
import std.time.*

/**
 * Emoji 网格 Canvas 合成器 —— iOS MultiAnimationRenderer 的 ArkUI 对位。
 *
 * 背景：逐格 @State 帧上屏在 80 格 × 30fps 下是每秒 2400 次组件 diff，UI
 * 线程打满；XComponent 原生 surface 两条产线在本环境均不可用（FromSurfaceId
 * 的 RequestBuffer 被遮挡剔除永久阻塞；libraryname 模块加载崩溃混合运行时，
 * 均真机实锤）。本组件用仓库已验证的 ConfettiView 模式（R-117/R-118）：
 * 一个 @State tick 驱动单个 Canvas 重绘，每拍把可见格子的当前帧
 * drawImage 上屏 —— 一次提交替代 N 次组件更新。
 *
 * 垫底形态：本组件放在网格 List **之下**（Stack 首子），List/格子转透明后
 * 帧从下面透出，触摸仍由上层格子接收，无命中问题。
 * 帧源：KeyboardDocPlayback 的 lastFrames（解码管线原样保留）。
 */
public class EmojiGridCanvasCell {
    public var docId: Int64 = 0
    public var x: Float64 = 0.0
    public var y: Float64 = 0.0
    public var size: Float64 = 0.0
    public init() {}
    public init(docId: Int64, x: Float64, y: Float64, size: Float64) {
        this.docId = docId
        this.x = x
        this.y = y
        this.size = size
    }
}

/** 宿主与覆盖件共享的模型（非 @State：绘制按 tick 拉取）。 */
public class EmojiGridCanvasModel {
    public var cells: ArrayList<EmojiGridCanvasCell> = ArrayList<EmojiGridCanvasCell>()
    public var active: Bool = false
    public init() {}
}

@Component
public class EmojiGridCanvasOverlay {
    public var model: EmojiGridCanvasModel = EmojiGridCanvasModel()

    @State var tickCount: Int64 = 0
    private let settings: RenderingContextSettings = RenderingContextSettings(antialias: true)
    private let context: CanvasRenderingContext2D = CanvasRenderingContext2D(this.settings)
    private var tickerGeneration: Int64 = 0

    protected override func aboutToAppear(): Unit {
        this.tickerGeneration = this.tickerGeneration + 1
        let generation = this.tickerGeneration
        let _ = spawn {
            while (true) {
                sleep(Duration.millisecond * 33)
                if (this.tickerGeneration != generation) { break }
                if (!this.model.active) { continue }
                launch {
                    if (this.tickerGeneration == generation && this.model.active) {
                        this.tickCount = this.tickCount + 1
                        // 直接重绘：不依赖「rebuild → onReady 重触发」（该假设
                        // 在本组件真机不成立，画面只出首帧）。Canvas ctx 挂载后
                        // 可随时在 UI 线程绘制。
                        this.drawFrames()
                    }
                }
            }
        }
    }

    protected override func aboutToDisappear(): Unit {
        this.tickerGeneration = this.tickerGeneration + 1
    }

    private var drawLogTick: Int64 = 0

    private func drawFrames(): Unit {
        let pool = getKeyboardDocPlayback()
        this.drawLogTick = this.drawLogTick + 1
        if (this.drawLogTick % 60 == 1) {
            var withFrame: Int64 = 0
            for (cell in this.model.cells) {
                if (pool.lastFrameFor(cell.docId).isSome()) { withFrame = withFrame + 1 }
            }
            var firstDesc = "-"
            if (this.model.cells.size > 0) {
                let c = this.model.cells[0]
                firstDesc = "(${Int64(c.x)},${Int64(c.y)},${Int64(c.size)})"
            }
            Hilog.info(0, "CjTelegram",
                "[EmojiGridCanvas] draw cells=${this.model.cells.size} withFrame=${withFrame} first=${firstDesc} active=${this.model.active}")
        }
        try {
            // Canvas 在本渲染管线是不透明层（DrawingScreen 同款实锤），
            // clearRect 后露黑 —— 每帧先铺面板同色底再画帧。
            this.context.fillStyle = 0xFFF1F3F5
            this.context.fillRect(0.0, 0.0, 4096.0, 4096.0)
            for (cell in this.model.cells) {
                match (pool.lastFrameFor(cell.docId)) {
                    case Some(frame) =>
                        this.context.drawImage(frame, cell.x, cell.y, cell.size, cell.size)
                    case None => ()
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[EmojiGridCanvas] draw failed: ${e}")
        }
    }

    /** R-118：tick 变化 → build 重跑 → onReady 重绘。 */
    private func tickDesc(): String {
        return "${this.tickCount}"
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Canvas(this.context)
                .width(100.percent)
                .height(100.percent)
                .onReady({
                    =>
                    this.drawFrames()
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
