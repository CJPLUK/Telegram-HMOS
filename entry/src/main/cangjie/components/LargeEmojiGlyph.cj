package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.ImageKit.PixelMap
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.loadAnimatedEmojiStaticFrame

/**
 * 大表情消息里的单个表情。
 *
 * iOS 对「只有 emoji」的消息（2 个及以上）不走动画节点：
 * ChatMessageAnimatedStickerItemNode.swift:503-523 把 emojiFile 置空、只留 emojiString，
 * :1073 用 fontSizeForEmojiString 算出的字号画一行**不动**的大号文字。那行文字在 iOS 上
 * 是 Apple 的表情字形，鸿蒙的系统字形跟它相差很远，而系统里没有、也不能内置 Apple 的
 * 表情字体，所以改用 Telegram 自带动画表情包的素材（美术风格本就对齐 Apple），
 * 停在第 0 帧以保持 iOS 的静态观感。
 *
 * 与 AnimatedEmojiComponent 分开的原因：那个组件持有一条常驻 Lottie 流、定时器、
 * 点击重播与长按菜单，而这里一条消息可能有几十个表情，只需要一张静态位图。
 * 位图按 (emoji, 光栅尺寸) 全局缓存，重复表情不会重复渲染。
 */
@Component
public class LargeEmojiGlyph {
    public var emoji: String = ""
    /** 素材边长（vp），由 fontSizeForEmojiString 的字号换算而来 */
    public var displaySize: Float64 = 78.0
    /**
     * 排版步进（vp）—— 一个字形在行内占的宽度，比素材本身窄。
     *
     * 表情包素材的画布四周留了透明边（实测本体只占画布的 75%），若直接按素材边长排，
     * 相邻两个之间就会多出一截空白。iOS 上 Apple 字形的步进约为字号的 1.08 倍、
     * 本体约 0.91 倍（78pt 实测步进 84pt / 本体 71pt），这里让素材按原尺寸居中溢出到
     * 步进宽度之外，本体大小和行内密度就同时对上了。
     */
    public var advanceWidth: Float64 = 78.0
    /** 表情包里没有这个 emoji 时，回退系统字形用的字号 */
    public var fallbackFontSize: Float64 = 78.0

    @State var frame: PixelMap = getEmptyAnimatedEmojiPixelMap()
    @State var resolved: Bool = false
    @State var failed: Bool = false
    private var loadStarted: Bool = false
    private var generation: Int64 = 0

    public override func aboutToAppear(): Unit {
        this.generation = this.generation + 1
        this.load()
    }

    public override func aboutToDisappear(): Unit {
        this.generation = this.generation + 1
    }

    /**
     * 光栅尺寸取显示边长的 3 倍（设备像素比），夹在 64~384 之间：
     * 上限即动画表情的原生光栅尺寸，下限保证小字号下边缘不糊。
     */
    private func rasterSize(): Int32 {
        var px = this.displaySize * 3.0
        if (px < 64.0) { px = 64.0 }
        if (px > 384.0) { px = 384.0 }
        return Int32(px)
    }

    private func load(): Unit {
        if (this.resolved || this.loadStarted) { return }
        this.loadStarted = true
        let emojiCopy = this.emoji
        let raster = this.rasterSize()
        let token = this.generation
        let _ = spawn {
            let loaded = loadAnimatedEmojiStaticFrame(emojiCopy, raster)
            launch {
                if (this.generation != token) { return }
                this.loadStarted = false
                match (loaded) {
                    case Some(pixelMap) =>
                        this.frame = pixelMap
                        this.resolved = true
                    case None => this.failed = true
                }
            }
        }
    }

    public func build() {
        Stack(alignContent: Alignment.Center) {
            if (this.failed) {
                // 表情包里没有这个 emoji：退回系统字形，总比留一块空白强
                Text(this.emoji)
                    .fontSize(this.fallbackFontSize)
            } else {
                // 素材就绪前是透明占位，避免先闪一下系统字形再换成素材
                Image(this.frame)
                    .width(this.displaySize)
                    .height(this.displaySize)
                    .objectFit(ImageFit.Contain)
            }
        }
        // 方框按步进取，素材居中溢出：画布四周那圈透明边不该占版面，
        // 否则横向缝隙和到时间胶囊的距离都会偏大。
        .width(this.advanceWidth)
        .height(this.advanceWidth)
        .clip(false)
    }
}
