package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.ImageKit.PixelMap
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.{
    StickerItem, ensureStickerLocalFile, loadStickerStaticFrame,
    getFileDownloadService, getAppFilesDir, triggerHaptic}
import ohos_app_cangjie_entry.utils.decodeTinyThumbnailToDataUrl
import kit.CoreFileKit.FileIo
import std.sync.*
import std.time.*

/**
 * 贴纸键盘里的单个格子。
 *
 * iOS 的 StickerPaneNode 每格是一个 ASImageNode，静态贴纸走 AJpeg 解码、
 * 动画贴纸取首帧当预览。加载期间保持透明占位，不显示 altEmoji fallback；
 * 否则真实资源出现前会闪一帧系统 Emoji，和 iOS 的 MediaBox 占位行为不一致。
 *
 * 三类贴纸的取图方式：
 *   静态 WEBP/PNG —— 下到本地后交给 Image 直接解；
 *   TGS / WEBM   —— 取第 0 帧的位图（loadStickerStaticFrame，渲完即关会话）。
 * 键盘一屏几十格，绝不能每格挂一条常驻播放流。
 */
@Component
public class StickerGridCell {
    public var item: StickerItem = StickerItem()
    public var size: Float64 = 68.0
    public var onTap: (StickerItem) -> Unit = { _s: StickerItem => }
    public var onLongPress: (StickerItem) -> Unit = { _s: StickerItem => }

    @State var localPath: String = ""
    @State var frame: PixelMap = getEmptyAnimatedEmojiPixelMap()
    @State var hasFrame: Bool = false
    /** 响应内嵌微缩图的 data URL（iOS immediateThumbnailData 对位）：
     *  真帧未到前即时占位，零网络往返 —— trending 页「预览很慢」的解法。 */
    @State var thumbUrl: String = ""
    private var loadStarted: Bool = false
    private var boundDocumentId: Int64 = 0
    // 有界调度器发的取消凭据；格子离屏后尚未开工的加载会被丢弃。
    private var loadToken: Int64 = 0
    /** doc 播放池订阅号（0 = 未订阅）。播放归 KeyboardDocPlayback（doc 键控，
     *  与 emoji 网格同池）；本格只订阅帧 —— 实例身份在本版本 ArkUI 不可依赖
     *（复用零回调，emoji 网格真机实锤），所以格子绝不自持播放流。 */
    private var subscriptionId: Int64 = 0
    /** 顶部包导航条上的封面：走独立配额，否则会被主网格的格子抢光。 */
    public var navigationSlot: Bool = false
    /** 预览模式（trending/添加页）：只下载 ~4KB 的 "m" 缩略图直出（iOS 预览
     *  同款），不拉整只 .tgs/.webm、不做首帧解码；动画仍可经播放池升格。 */
    public var previewOnly: Bool = false

    protected override func aboutToAppear(): Unit {
        if (this.subscriptionId == 0 && this.item.documentId != 0 && this.isAnimated()) {
            let subscribedDoc = this.item.documentId
            this.subscriptionId = getKeyboardDocPlayback().subscribe(subscribedDoc,
                { pixelMap: PixelMap =>
                    if (this.item.documentId == subscribedDoc) {
                        this.frame = pixelMap
                        this.hasFrame = true
                    }
                })
        }
    }

    protected override func aboutToDisappear(): Unit {
        // 已经开工的任务照旧跑完并进缓存（iOS MediaBox 同样会完成离屏预取）；
        // 这里只撤销还排在队列里、尚未开工的那一份。
        if (this.loadToken > 0) {
            getKeyboardMediaScheduler().cancel(this.loadToken)
            this.loadToken = 0
        }
        if (this.subscriptionId != 0) {
            getKeyboardDocPlayback().unsubscribe(this.subscriptionId)
            this.subscriptionId = 0
        }
    }

    private func isAnimated(): Bool {
        return this.item.mimeType.contains("tgs") || this.item.mimeType.contains("lottie") ||
            this.item.mimeType.contains("webm")
    }

    private func isVideo(): Bool {
        return this.item.mimeType.contains("webm")
    }

    /** 首帧光栅按格子的物理像素取，夹在 64~384（384 = 动画贴纸的原生光栅尺寸） */
    private func rasterSize(): Int32 {
        var px = this.size * 3.0
        if (px < 64.0) { px = 64.0 }
        if (px > 384.0) { px = 384.0 }
        return Int32(px)
    }

    private func load(): Unit {
        if (this.loadStarted || this.item.documentId == 0) { return }
        this.loadStarted = true
        if (this.previewOnly) {
            this.loadPreviewThumb()
            return
        }
        let sticker = this.item
        let animated = this.isAnimated()
        let video = this.isVideo()
        let raster = this.rasterSize()
        // 之前这里是裸 spawn：快速滚动时一秒内能投放上百条阻塞 I/O 协程，
        // 把运行时线程占满，UI 线程随后拿不到调度机会。改走有界调度器。
        this.loadToken = getKeyboardMediaScheduler().submit {
            let path = ensureStickerLocalFile(sticker)
            if (path.size == 0) {
                Hilog.info(0, "CjTelegram", "[StickerGridCell] resource unavailable id=${sticker.documentId}")
                launch { this.loadStarted = false }
                return
            }
            if (animated) {
                let decoded = loadStickerStaticFrame(sticker.documentId, path, video, raster)
                launch {
                    // ForEach 复用组件时只接受当前文档的结果；离屏本身不取消预取。
                    if (this.item.documentId != sticker.documentId) {
                        this.loadStarted = false
                        return
                    }
                    match (decoded) {
                        case Some(pixelMap) =>
                            this.frame = pixelMap
                            this.hasFrame = true
                        case None =>
                            Hilog.info(0, "CjTelegram",
                                "[StickerGridCell] preview decode failed id=${sticker.documentId} raster=${raster}")
                    }
                    this.loadStarted = false
                }
            } else {
                launch {
                    if (this.item.documentId != sticker.documentId) {
                        this.loadStarted = false
                        return
                    }
                    this.localPath = path
                    this.loadStarted = false
                }
            }
        }
    }

    /** 预览缩略图（"m" photoSize，~4KB webp）：内存缓存 + 落盘复用，
     *  Image(path) 原生解 webp。整只文件与首帧解码全部跳过。 */
    private func loadPreviewThumb(): Unit {
        let sticker = this.item
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) {
            this.loadStarted = false
            return
        }
        let dir = filesDir + "/thumbs"
        let path = dir + "/stkthumb_${sticker.documentId}_m.webp"
        var exists = false
        try { exists = FileIo.access(path) } catch (_: Exception) {}
        if (exists) {
            this.localPath = "file://" + path
            this.loadStarted = false
            return
        }
        this.loadToken = getKeyboardMediaScheduler().submitUrgent {
            let bytes = getFileDownloadService().downloadDocumentThumb(
                sticker.documentId, sticker.accessHash, sticker.fileReference,
                thumbSize: "m")
            if (bytes.size > 0) {
                try {
                    try { FileIo.mkdir(dir) } catch (_: Exception) {}
                    let f = FileIo.open(path, mode: 0o1101)
                    FileIo.write(f.fd, bytes)
                    FileIo.close(f)
                } catch (_: Exception) {}
            }
            launch {
                this.loadStarted = false
                if (this.item.documentId == sticker.documentId && bytes.size > 0) {
                    this.localPath = "file://" + path
                }
            }
        }
    }

    /**
     * Scroll/Flex 会提前创建离屏格子，aboutToAppear 不等于进入可视区域。
     * 与 iOS StickerPane 的 visible-item 管线一致，只在真正可见时启动媒体下载和首帧解码；
     * 已启动任务离屏后仍允许完成并进入缓存，快速回划不会重复请求。
     */
    private func loadWhenVisible(): Unit {
        // 复用可能重置 @State（hasFrame/localPath 归零）但普通字段存活 ——
        // 只认 boundDocumentId 会拒绝重载，同 doc 复用的格子就永久空白
        //（emoji 网格同款洞的贴纸版）。状态为空时强制走重载分支。
        if (this.boundDocumentId == this.item.documentId &&
            !this.hasFrame && this.localPath.size == 0 && !this.loadStarted) {
            this.boundDocumentId = 0
        }
        if (this.boundDocumentId != this.item.documentId) {
            // LazyForEach 复用同一个组件承载另一张贴纸：换订阅（播放流归池，与实例无关）。
            if (this.subscriptionId != 0) {
                getKeyboardDocPlayback().unsubscribe(this.subscriptionId)
                this.subscriptionId = 0
            }
            this.boundDocumentId = this.item.documentId
            this.localPath = ""
            this.hasFrame = false
            this.loadStarted = false
            this.thumbUrl = ""
            if (this.item.documentId != 0 && this.isAnimated()) {
                let subscribedDoc = this.item.documentId
                this.subscriptionId = getKeyboardDocPlayback().subscribe(subscribedDoc,
                    { pixelMap: PixelMap =>
                        if (this.item.documentId == subscribedDoc) {
                            this.frame = pixelMap
                            this.hasFrame = true
                        }
                    })
            }
        }
        // 微缩图即时占位（~300B inflate，UI 线程一次性开销 <1ms）
        if (this.thumbUrl.isEmpty() && !this.hasFrame && this.item.thumbStripped.size > 0) {
            this.thumbUrl = decodeTinyThumbnailToDataUrl(this.item.thumbStripped)
        }
        this.load()
    }

    private var pressActive: Bool = false
    private var pressGeneration: Int64 = 0
    private var pressStartX: Float64 = 0.0
    private var pressStartY: Float64 = 0.0
    private var longPressFired: Bool = false

    private func handleTouch(evt: TouchEvent): Unit {
        match (evt.eventType) {
            case TouchType.Down =>
                if (evt.touches.size > 0) {
                    this.pressStartX = evt.touches[0].x
                    this.pressStartY = evt.touches[0].y
                }
                this.pressActive = true
                this.longPressFired = false
                this.pressGeneration += 1
                let generation = this.pressGeneration
                spawn {
                    sleep(Duration.millisecond * 300)
                    launch {
                        if (this.pressActive && generation == this.pressGeneration) {
                            this.pressActive = false
                            this.longPressFired = true
                            triggerHaptic("impact", "light")
                            Hilog.info(0, "CjTelegram", "[StickerGridCell] long press doc=${this.item.documentId}")
                            this.onLongPress(this.item)
                        }
                    }
                }
            case TouchType.Move =>
                if (this.pressActive && evt.touches.size > 0) {
                    let dx = evt.touches[0].x - this.pressStartX
                    let dy = evt.touches[0].y - this.pressStartY
                    if (dx * dx + dy * dy > 64.0) {
                        this.pressActive = false
                        this.pressGeneration += 1
                    }
                }
            case TouchType.Up =>
                let wasPending = this.pressActive
                this.pressActive = false
                this.pressGeneration += 1
                if (wasPending && !this.longPressFired) {
                    this.onTap(this.item)
                }
                this.longPressFired = false
            case TouchType.Cancel =>
                this.pressActive = false
                this.pressGeneration += 1
                this.longPressFired = false
            case _ => ()
        }
    }

    public func build() {
        Column {
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
            } else if (!this.thumbUrl.isEmpty()) {
                // iOS immediateThumbnailData 对位：内嵌微缩图即时占位
                Image(this.thumbUrl)
                    .width(this.size)
                    .height(this.size)
                    .objectFit(ImageFit.Contain)
            } else {
                // 与 iOS 一致：资源未就绪时只保留布局，不闪系统 Emoji fallback。
                Column {}
                    .width(this.size)
                    .height(this.size)
            }
        }
        .width(this.size)
        .height(this.size)
        .borderRadius(8)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        // S2-37: iOS ChatMediaInputStickerGridItemNode — a press held for
        // ~300 ms opens the sticker preview (Send / Add to Favorites …);
        // moving the finger (grid scroll) cancels it; a short press is a tap.
        .onTouch({ evt => this.handleTouch(evt) })
        .onAppear({ => this.loadWhenVisible() })
    }
}
