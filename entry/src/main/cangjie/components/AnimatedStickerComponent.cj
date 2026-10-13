package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.ImageKit.PixelMap
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.sync.*
import std.time.*

/**
 * AnimatedStickerComponent — 聊天动画贴纸（TGS / WebM）播放节点
 *
 * 对应 iOS ChatMessageAnimatedStickerItemNode + AnimatedStickerNode。
 *
 * 2026-08 重构：不再自带 Timer / 解码循环。此前每张在播贴纸各持一只
 * Timer.repeat(16ms = 60fps)，每帧一个 spawn(UIThread) + 一个 prepare 协程 ——
 * 三张贴纸同屏就是每秒 ~180 个 UI 任务 + ~180 次全尺寸 rlottie 解码，
 * 聊天页「动态贴纸很卡」的主要来源。现在全部挂到 KeyboardFrameClock
 *（30fps 共享帧钟、整拍单 UI 任务、专用解码 worker、按源帧率跳帧保真速，
 * 见 EntityKeyboardMedia.cj）+ 聊天贴纸独立配额 CHAT_STICKER_PLAYBACK_SLOTS=6。
 * iOS 的对应物是 MultiAnimationRenderer：所有贴纸层共用一个 displaylink，
 * 帧在后台备好、主线程整批换 contents。
 *
 * 可见性门禁：进入可视区后 260ms 稳定期才起播（GifGridCell 实测同值）——
 * 快速滚动划过的贴纸从不打开解码会话；滚出可视区立即 stop（关会话、还槽），
 * 画面停在最后一帧（iOS 的暂停语义，不闪回占位图）。
 */
@Component
public class AnimatedStickerComponent {
    // 贴纸文档 id（解码会话 key）
    public var documentId: Int64 = 0
    // 已下载的 .tgs / .webm 本地路径（可为 file:// URI）
    public var localPath: String = ""
    public var displaySize: Float64 = 160.0
    public var isVideoSticker: Bool = false
    // 兼容旧调用点保留；流式解码不再需要时长提示。
    public var videoDuration: Int32 = 0
    // Exact Telegram document thumbnail shown until the renderer starts.
    public var placeholderPath: String = ""
    // TC-0134-round6 B1: 起播前的延时（ms）。<=0 保持既有行为（稳定期后立即起播）。
    // 对位源侧 Queue.mainQueue().after(0.3){ play() }。
    public var startDelayMs: Int64 = 0

    @State var ready: Bool = false
    @State var displayedFrame: PixelMap = getEmptyAnimatedEmojiPixelMap()
    private let animation: KeyboardAnimationStream = KeyboardAnimationStream()
    private var lifecycleGeneration: Int64 = 0
    private var visible: Bool = false
    private var visibilityGeneration: Int64 = 0
    private var firstFrameLogged: Bool = false

    public override func aboutToAppear(): Unit {
        this.lifecycleGeneration = this.lifecycleGeneration + 1
    }

    public override func aboutToDisappear(): Unit {
        this.releaseStream()
    }

    private func handleVisibility(isVisible: Bool, ratio: Float64): Unit {
        let shouldPlay = isVisible && ratio > 0.01
        if (this.visible == shouldPlay) { return }
        this.visible = shouldPlay
        this.visibilityGeneration = this.visibilityGeneration + 1
        if (shouldPlay) {
            let visibilityToken = this.visibilityGeneration
            let lifecycleToken = this.lifecycleGeneration
            let _ = spawn {
                // 260ms 稳定期：快速滚动划过的贴纸不打开解码会话。
                // 旧值 32ms 挡不住惯性滚动 —— 贴纸从屏底滑到屏顶要 300ms+，
                // 一路上每张都够 32ms 的「稳定」，照样全体开会话。
                sleep(Duration.millisecond * 260)
                // TC-0134-round6 B1: 稳定期之后再叠加调用点要求的起播延时。
                if (this.startDelayMs > 0) { sleep(Duration.millisecond * this.startDelayMs) }
                launch {
                    if (this.visible &&
                        this.visibilityGeneration == visibilityToken &&
                        this.lifecycleGeneration == lifecycleToken) {
                        this.startAnimation()
                    }
                }
            }
        } else {
            // 停播但保留 displayedFrame：iOS 滚出可视区是「暂停在当前帧」。
            this.animation.stop()
        }
    }

    private func startAnimation(): Unit {
        if (this.localPath.size == 0 || this.documentId == 0) { return }
        if (this.animation.isRunning()) { return }
        let docId = this.documentId
        let path = this.localPath
        let video = this.isVideoSticker
        let generation = this.lifecycleGeneration
        this.animation.useChatSlots = true
        // start() 内含 openAnimatedStickerFileStream（阻塞的原生解码初始化）
        // 和首帧 prepare，不能占 UI 线程。
        let _ = spawn {
            let started = this.animation.start(docId, path, video,
                { pixelMap: PixelMap =>
                    // 共享帧钟在 UI 线程整批回调，直接写 @State。
                    if (this.lifecycleGeneration == generation && this.documentId == docId) {
                        this.displayedFrame = pixelMap
                        if (!this.ready) { this.ready = true }
                        if (!this.firstFrameLogged) {
                            this.firstFrameLogged = true
                            Hilog.info(0, "CjTelegram",
                                "[AnimatedStickerComponent] first motion id=${docId}")
                        }
                    }
                })
            if (!started) {
                Hilog.info(0, "CjTelegram",
                    "[AnimatedStickerComponent] start deferred id=${docId}（配额满时释放后自动重试）")
            }
        }
    }

    private func releaseStream(): Unit {
        this.lifecycleGeneration = this.lifecycleGeneration + 1
        this.visibilityGeneration = this.visibilityGeneration + 1
        this.visible = false
        this.animation.stop()
        this.ready = false
        this.firstFrameLogged = false
        this.displayedFrame = getEmptyAnimatedEmojiPixelMap()
    }

    private func pingOpacity(): Float64 {
        this.animation.pingAlive()
        return 1.0
    }

    public func build() {
        Stack(alignContent: Alignment.Center) {
            if (this.placeholderPath.size > 0) {
                Image(this.placeholderPath)
                    .width(this.displaySize)
                    .height(this.displaySize)
                    .objectFit(ImageFit.Contain)
                    .opacity(if (this.ready) { 0.0 } else { 1.0 })
            }
            // Keep one stable animation surface mounted for the component's
            // whole lifetime. Switching Column -> Image at ready time caused
            // an extra layout/texture handoff and a transparent flash.
            Image(this.displayedFrame)
                .width(this.displaySize)
                .height(this.displaySize)
                .objectFit(ImageFit.Contain)
                .opacity(if (this.ready) { 1.0 } else { 0.0 })
        }
        .width(this.displaySize)
        .height(this.displaySize)
        .onVisibleAreaChange([0.01], { isVisible: Bool, ratio: Float64 =>
            this.handleVisibility(isVisible, ratio)
        })
        .onDisAppear({ => this.releaseStream() })
    }
}
