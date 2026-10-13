package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.ImageKit.{
    createPixelMap, PixelMap, InitializationOptions, Size as ImageKitSize,
    PixelMapFormat, AlphaType
}
import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import std.time.*
import ohos.business_exception.BusinessException
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.{
    StickerItem, resolveCustomEmojiDocument, ensureStickerLocalFile,
    loadStickerStaticFrameCached, loadStickerStaticFrame, storeStickerStaticFrame
}

/**
 * 按 document_id 渲染一个自定义表情（premium custom emoji）。
 * 对应 iOS 的 InlineStickerItemLayer。
 *
 * 2026-08-24 重写为单一状态机 —— 此前多轮修补堆出的守卫栈
 *（playbackAllowed / 退避 / 掉队自愈 / 滚动闸 / settle+watchdog 残骸）相互作用
 * 已不可证伪，按「不打补丁、直接重构」原则整体重来。
 *
 * 职责分两条完全独立的路径：
 *   画帧路径：挂载即执行一次（kickPaint），只求把一帧画上屏
 *            （内存/磁盘帧缓存直出；未命中才开一次解码会话取代表帧）。
 *   播放路径：**唯一入口 setPlaying(Bool)**，由 EmojiPicker 的拉模式中央驱动
 *            （KeyboardCellRegistry.drive，iOS 可见性驱动的对位）调用。
 *            状态：Idle(0) → Preparing(1) → Ready(2) → Playing(3)。
 *
 * 本组件自己不做任何可见性/滚动/播放决策：播放按**文档**键控归
 * KeyboardDocPlayback（iOS MultiAnimationRenderer 真形），本组件只订阅帧。
 */
@Component
public class CustomEmojiImage {
    @Prop @Watch[onDocumentIdChanged] var documentId: Int64
    public var size: Float64 = 18.0
    /** 素材取不到时的兜底文字（反应气泡上留白很难看） */
    public var placeholder: String = "🙂"
    /** >= 0 表示处于键盘播放语境（注册进拉模式驱动）；-1 纯静态。 */
    public var animationEpoch: Int64 = -1
    /** 强制模板染色（EntityKeyboard 图标）。 */
    public var templateMode: Bool = false
    /** 顶部导航条封面：走导航条独立播放配额。 */
    public var navigationSlot: Bool = false
    /** Profile/avatar surfaces loop without relying on EmojiPicker visibility. */
    public var autoplay: Bool = false
    /** AvatarEditor 的预览按源码只播一次并停在末帧。 */
    public var autoplayLoop: Bool = true

    @State var autoTemplate: Bool = false
    @State var frame: PixelMap = getEmptyAnimatedEmojiPixelMap()
    @State var hasFrame: Bool = false
    @State var localPath: String = ""

    /** 画帧路径是否已为当前 documentId 执行过。 */
    private var paintedDocId: Int64 = 0
    /** doc 播放池的订阅号（0 = 未订阅）。 */
    private var subscriptionId: Int64 = 0

    /** 已订阅的 doc（0 = 未订阅）。复用换档时据此判断需要换订阅。 */
    private var subscribedDocId: Int64 = 0
    private let avatarPlayback: AvatarEmojiPlayback = AvatarEmojiPlayback()

    private func onDocumentIdChanged(): Unit {
        Hilog.info(0, "CjTelegram", "[EmojiCell] document changed to ${this.documentId}")
        let previousDocId = this.subscribedDocId
        if (this.subscriptionId != 0) {
            getKeyboardDocPlayback().unsubscribe(this.subscriptionId)
            this.subscriptionId = 0
        }
        if (this.autoplay && previousDocId != 0) { this.avatarPlayback.stop() }
        this.subscribedDocId = 0
        this.paintedDocId = 0
        this.hasFrame = false
        this.localPath = ""
        this.frame = getEmptyAnimatedEmojiPixelMap()
        this.ensureSubscribedAndPainted()
    }

    /**
     * 可重入：aboutToAppear（新实例）与 build 根节点 onAppear（复用实例的
     * 唯一可靠回调 —— R-146：复用不来 aboutToAppear，且 @State 可能被重置成
     * 初始值，真机实锤整组三行空白）都会进来。
     */
    private func ensureSubscribedAndPainted(): Unit {
        if (this.animationEpoch >= 0 && this.documentId != 0 &&
            (this.subscriptionId == 0 || this.subscribedDocId != this.documentId)) {
            if (this.subscriptionId != 0) {
                getKeyboardDocPlayback().unsubscribe(this.subscriptionId)
                this.subscriptionId = 0
            }
            Hilog.info(0, "CjTelegram",
                "[EmojiCell] subscribe doc=${this.documentId} epoch=${this.animationEpoch}")
            let subscribedDoc = this.documentId
            this.subscribedDocId = subscribedDoc
            this.subscriptionId = getKeyboardDocPlayback().subscribe(subscribedDoc,
                { pixelMap: PixelMap =>
                    if (this.documentId == subscribedDoc) {
                        this.frame = if (this.usesTemplate()) {
                            this.tintedTemplateFrame(pixelMap)
                        } else {
                            pixelMap
                        }
                        this.hasFrame = true
                    }
                })
        }
        if (this.autoplay && this.documentId != 0 && this.subscribedDocId != this.documentId) {
            let autoplayDoc = this.documentId
            this.subscribedDocId = autoplayDoc
            this.avatarPlayback.start(autoplayDoc, this.rasterSize(), this.autoplayLoop,
                { pixelMap: PixelMap =>
                    if (this.documentId == autoplayDoc) {
                        this.frame = if (this.usesTemplate()) {
                            this.tintedTemplateFrame(pixelMap)
                        } else {
                            pixelMap
                        }
                        this.hasFrame = true
                    }
                })
        }
        // 复用重置过 @State（hasFrame 归 false）但 paintedDocId 是普通字段
        // 会存活 —— 只认 paintedDocId 会拒绝重画，这里以 hasFrame 为准。
        if (!this.hasFrame && this.localPath.size == 0) {
            this.paintedDocId = 0
        }
        this.kickPaint()
    }

    protected override func aboutToAppear(): Unit {
        if (this.animationEpoch >= 0 && this.documentId == 0) {
            Hilog.info(0, "CjTelegram", "[EmojiCell] appear with doc=0 (param not ready)")
        }
        this.ensureSubscribedAndPainted()
    }

    protected override func aboutToDisappear(): Unit {
        let disappearingDocId = this.subscribedDocId
        if (this.subscriptionId != 0) {
            getKeyboardDocPlayback().unsubscribe(this.subscriptionId)
            this.subscriptionId = 0
            this.subscribedDocId = 0
        }
        if (this.autoplay && disappearingDocId != 0) { this.avatarPlayback.stop() }
    }

    // 播放路径已迁往 KeyboardDocPlayback（doc 键控池，见 EntityKeyboardMedia）。

    // ==================== 画帧路径 ====================

    /** 挂载时执行一次：只求把一帧画上屏，不碰播放资源。 */
    private func kickPaint(): Unit {
        if (this.documentId == 0 || this.paintedDocId == this.documentId) { return }
        this.paintedDocId = this.documentId
        let docId = this.documentId
        let raster = this.rasterSize()
        let _ = getKeyboardMediaScheduler().submit {
            match (loadStickerStaticFrameCached(docId, raster, representative: true)) {
                case Some(cached) =>
                    // 缓存命中也要先定模板性：否则 template 包（如 Love Icons）
                    // 走此早退路径时 autoTemplate 恒 false，漏染灰（存的是未染原帧）。
                    var cachedTextColor = false
                    match (resolveCustomEmojiDocument(docId)) {
                        case Some(doc) => cachedTextColor = doc.supportsTextColor
                        case None => ()
                    }
                    let textColorHit = cachedTextColor
                    launch {
                        if (this.documentId == docId && !this.hasFrame) {
                            this.autoTemplate = textColorHit
                            this.frame = this.tintedTemplateFrame(cached)
                            this.hasFrame = true
                        }
                    }
                    return
                case None => ()
            }
            match (resolveCustomEmojiDocument(docId)) {
                case Some(doc) =>
                    let textColor = doc.supportsTextColor
                    launch { if (this.documentId == docId) { this.autoTemplate = textColor } }
                    let path = ensureStickerLocalFile(doc)
                    if (path.size == 0) { return }
                    let animated = doc.mimeType.contains("tgs") ||
                        doc.mimeType.contains("lottie") || doc.mimeType.contains("webm")
                    if (!animated) {
                        launch {
                            if (this.documentId == docId) { this.localPath = path }
                        }
                        return
                    }
                    let decoded = loadStickerStaticFrame(
                        docId, path, doc.mimeType.contains("webm"), raster,
                        representative: true)
                    launch {
                        if (this.documentId != docId) { return }
                        match (decoded) {
                            case Some(pixelMap) =>
                                if (!this.hasFrame) {
                                    this.frame = this.tintedTemplateFrame(pixelMap)
                                    this.hasFrame = true
                                }
                            case None => ()
                        }
                    }
                case None =>
                    Hilog.info(0, "CjTelegram", "[EmojiCell] unresolved doc=${docId}")
            }
        }
    }

    // ==================== 工具 ====================

    private func rasterSize(): Int32 {
        // 键盘一律 84（行间 itemSize 不同，分档会与预取端错配——真机两轮实锤）。
        if (this.size <= 40.0) { return 84 }
        var px = this.size * 3.0
        if (px > 256.0) { px = 256.0 }
        return Int32(px)
    }

    private func usesTemplate(): Bool {
        return this.templateMode || this.autoTemplate
    }

    /** supportsTextColor 素材染成 iOS 次级文字色（不改共享帧，返回新图）。 */
    private func tintedTemplateFrame(source: PixelMap): PixelMap {
        if (!this.usesTemplate()) { return source }
        try {
            let info = source.getImageInfo()
            let width = Int64(info.size.width)
            let height = Int64(info.size.height)
            if (width <= 0 || height <= 0) { return source }
            let buffer = Array<UInt8>(width * height * 4, repeat: 0)
            source.readPixelsToBuffer(buffer)
            var index: Int64 = 0
            while (index + 3 < Int64(buffer.size)) {
                let alpha = UInt16(buffer[index + 3])
                // #8E8E93, BGRA + premultiplied alpha.
                buffer[index] = UInt8((UInt16(0x93) * alpha) / 255)
                buffer[index + 1] = UInt8((UInt16(0x8E) * alpha) / 255)
                buffer[index + 2] = UInt8((UInt16(0x8E) * alpha) / 255)
                index = index + 4
            }
            return createPixelMap(buffer, InitializationOptions(
                ImageKitSize(Int32(width), Int32(height)),
                srcPixelFormat: PixelMapFormat.Bgra8888,
                pixelFormat: PixelMapFormat.Bgra8888,
                alphaType: AlphaType.Premul
            ))
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[EmojiCell] tint failed doc=${this.documentId}")
            return source
        }
    }

    public func build() {
        Stack(alignContent: Alignment.Center) {
            if (this.hasFrame) {
                Image(this.frame)
                    .width(this.size)
                    .height(this.size)
                    .objectFit(ImageFit.Contain)
            } else if (this.localPath.size > 0) {
                Image(this.localPath)
                    .width(this.size)
                    .height(this.size)
                    .objectFit(ImageFit.Contain)
            } else {
                Text(this.placeholder)
                    .fontSize(this.size * 0.9)
            }
        }
        .width(this.size)
        .height(this.size)
        .onAppear({ => this.ensureSubscribedAndPainted() })
    }
}
