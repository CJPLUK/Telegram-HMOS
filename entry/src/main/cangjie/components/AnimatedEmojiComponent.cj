package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.ImageKit.PixelMap
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.app.getAppState
import ohos_app_cangjie_entry.services.{
    openAnimatedEmojiStream,
    StreamingLottiePlayer,
    preloadAnimatedEmojiEffect
}

@Builder
func emptyAnimatedEmojiMenuBuilder(): Unit {}

@Component
public class AnimatedEmojiComponent {
    public var emoji: String = ""
    public var displaySize: Float64 = 112.0
    public var menuEnabled: Bool = true
    public var onTap: (String) -> Unit = { _emoji: String => }
    public var onMenuAboutToAppear: () -> Unit = { => }
    public var onMenuAboutToDisappear: () -> Unit = { => }

    @BuilderParam
    var contextMenuBuilder: () -> Unit = emptyAnimatedEmojiMenuBuilder

    @BuilderParam
    var contextMenuPreviewBuilder: () -> Unit = emptyAnimatedEmojiMenuBuilder

    @State var ready: Bool = false
    @State var frameIndex: Int64 = 0
    @State var displayedFrame: PixelMap = getEmptyAnimatedEmojiPixelMap()
    @State var menuVisible: Bool = false
    private var loadStarted: Bool = false
    /**
     * 帧推进挂共享帧钟（KeyboardFrameClock，领养模式 + 一次性播放 +
     * targetTickMs=16 全速车道）。此前是 Timer.once 逐帧自链：每帧要付
     * 「定时器到点 → 解码线程 → spawn(UIThread) → 重挂下一只 Timer」整趟延迟，
     * 60fps 素材实际只跑出 ~20fps 且抖 —— 用户看到的就是「点 emoji 动画帧率低」。
     * 播放器仍由本组件按 emoji 打开并持有，tap 重播 seekTo(0) 复用，
     * 不重付 gunzip + lottie 解析。
     */
    private let animation: KeyboardAnimationStream = KeyboardAnimationStream()
    private var stream: Option<StreamingLottiePlayer> = None<StreamingLottiePlayer>
    private var lifecycleGeneration: Int64 = 0
    private var motionLogged: Bool = false
    private var cadenceLogged: Bool = false
    private var visible: Bool = false
    private var visibilityGeneration: Int64 = 0
    private var pressGeneration: Int64 = 0
    private var pressActive: Bool = false
    private var suppressNextTap: Bool = false
    private var pendingTap: Bool = false
    private var touchStartX: Float64 = 0.0
    private var touchStartY: Float64 = 0.0

    public override func aboutToAppear(): Unit {
        this.lifecycleGeneration = this.lifecycleGeneration + 1
    }

    private func handleVisibility(isVisible: Bool, ratio: Float64): Unit {
        let shouldPlay = isVisible && ratio > 0.01
        if (this.visible == shouldPlay) { return }
        this.visible = shouldPlay
        this.visibilityGeneration = this.visibilityGeneration + 1
        if (shouldPlay) {
            if (this.ready) {
                this.startPlayback()
            } else {
                this.scheduleLoadForStableVisibility(
                    this.visibilityGeneration,
                    this.lifecycleGeneration)
            }
        } else {
            this.stopPlayback()
        }
    }

    /**
     * ArkUI first mounts the List at its default range, then applies the chat's
     * initial upper-bound scroll. During those two layout frames old nodes can
     * report visible=true before immediately becoming invisible. iOS only
     * initializes DirectAnimatedStickerNode after ListView's final visibility
     * status is true. Give ArkUI the same stable-visibility boundary so those
     * transient nodes do not parse and rasterize animations ahead of the real
     * viewport.
     */
    private func scheduleLoadForStableVisibility(
        visibilityToken: Int64,
        lifecycleToken: Int64
    ): Unit {
        let _ = spawn {
            sleep(Duration.millisecond * 32)
            launch {
                if (this.visible &&
                    this.visibilityGeneration == visibilityToken &&
                    this.lifecycleGeneration == lifecycleToken) {
                    this.loadIfNeeded()
                }
            }
        }
    }

    /**
     * Start loading from both the component lifecycle and the rendered node.
     *
     * A MessageBubble inserted into an already visible ForEach does not always
     * receive the component-level aboutToAppear callback. The root onAppear
     * below is the reliable mount signal for a newly sent emoji.
     */
    private func loadIfNeeded(): Unit {
        if (this.ready || this.loadStarted) { return }
        this.loadStarted = true
        this.motionLogged = false
        this.cadenceLogged = false
        let emojiCopy = this.emoji
        let generation = this.lifecycleGeneration
        let _ = spawn {
            match (openAnimatedEmojiStream(emojiCopy)) {
                case Some(player) =>
                    // Do not race the first presentation deadline against the
                    // first successor render. On a busy chat the timer used to
                    // win this race and the one-shot playback chain stopped at
                    // frame zero until a scroll restarted visibility handling.
                    if (player.getFrameCount() > 1) {
                        let _ = player.prepareNextFrame(1)
                    }
                    launch {
                        if (this.lifecycleGeneration == generation) {
                            this.stream = Some(player)
                            match (player.getCurrentFrame()) {
                                case Some(frame) => this.displayedFrame = frame
                                case None => ()
                            }
                            this.loadStarted = false
                            this.ready = true
                            this.frameIndex = 0
                            if (this.pendingTap) {
                                this.pendingTap = false
                                this.commitTap()
                            } else if (this.visible) {
                                this.startPlayback()
                            }
                        } else {
                            player.close()
                        }
                    }
                    let _ = spawn { preloadAnimatedEmojiEffect(emojiCopy) }
                case None =>
                    Hilog.info(0, "CjTelegram",
                        "[AnimatedEmojiComponent] stream open failed emoji=${emojiCopy}")
                    launch { this.loadStarted = false }
            }
        }
    }

    public override func aboutToDisappear(): Unit {
        this.releaseStream()
    }

    private func releaseStream(): Unit {
        this.lifecycleGeneration = this.lifecycleGeneration + 1
        this.visibilityGeneration = this.visibilityGeneration + 1
        this.visible = false
        this.stopPlayback()
        this.ready = false
        this.displayedFrame = getEmptyAnimatedEmojiPixelMap()
        this.loadStarted = false
        let oldStream = this.stream
        this.stream = None<StreamingLottiePlayer>
        match (oldStream) {
            case Some(player) =>
                Hilog.info(0, "CjTelegram", "[AnimatedEmojiComponent] release emoji=${this.emoji}")
                let _ = spawn { player.close() }
            case None => ()
        }
    }

    private func currentPixelMap(): PixelMap {
        match (this.stream) {
            case Some(player) =>
                match (player.getCurrentFrame()) {
                    case Some(pixelMap) => return pixelMap
                    case None => return getEmptyAnimatedEmojiPixelMap()
                }
            case None => return getEmptyAnimatedEmojiPixelMap()
        }
    }

    private func startPlayback(): Unit {
        match (this.stream) {
            case Some(player) =>
                if (this.animation.isRunning()) { return }
                let generation = this.lifecycleGeneration
                this.animation.targetTickMs = 16
                // startAdoptedOneShot 里有一次同步 prepare（真解码），不占 UI 线程。
                let _ = spawn {
                    let started = this.animation.startAdoptedOneShot(player,
                        { pixelMap: PixelMap =>
                            // 共享帧钟在 UI 线程整批回调，直接写 @State。
                            if (this.lifecycleGeneration == generation) {
                                this.displayedFrame = pixelMap
                                if (!this.motionLogged) {
                                    this.motionLogged = true
                                    Hilog.info(0, "CjTelegram",
                                        "[AnimatedEmojiComponent] first motion emoji=${this.emoji}")
                                }
                            }
                        })
                    if (started) {
                        Hilog.info(0, "CjTelegram",
                            "[AnimatedEmojiComponent] clock playback emoji=${this.emoji} frames=${player.getFrameCount()}")
                    }
                }
            case None => ()
        }
    }

    private func stopPlayback(): Unit {
        // 领养模式：只从钟上摘下，播放器留在本组件手里（tap 重播还要用）。
        this.animation.stop()
    }

    /**
     * iOS routes the single-tap branch of
     * TapLongTapOrDoubleTapGestureRecognizer back to the animated sticker node.
     * Restart from frame zero only after ArkUI has resolved the press as a tap;
     * bindContextMenu on this same node owns the long-press branch.
     */
    private func replay(): Unit {
        if (this.suppressNextTap) {
            this.suppressNextTap = false
            return
        }
        if (!this.ready) {
            // Preserve the user's first tap while metadata/TGS loading is still
            // finishing. Previously it was silently discarded, so users had to
            // tap repeatedly before an interaction was emitted.
            this.pendingTap = true
            this.loadIfNeeded()
            return
        }
        this.commitTap()
    }

    private func commitTap(): Unit {
        Hilog.info(0, "CjTelegram", "[EmojiInteraction] tap emoji=${this.emoji}")
        // Receiving the tap proves the node is onscreen even if ArkUI's last
        // visibility callback belongs to an earlier List layout pass.
        this.visible = true
        this.onTap(this.emoji)
        let generation = this.lifecycleGeneration
        match (this.stream) {
            case Some(player) =>
                // 先从钟上摘下（可能正在播），seek 回 0 再重挂。
                this.animation.stop()
                let _ = spawn {
                    if (player.seekTo(0)) {
                        spawn(UIThread) {
                            =>
                            if (this.lifecycleGeneration == generation) {
                                match (player.getCurrentFrame()) {
                                    case Some(frame) => this.displayedFrame = frame
                                    case None => ()
                                }
                                this.frameIndex = 0
                                this.startPlayback()
                            }
                        }
                    }
                }
            case None => ()
        }
    }

    /**
     * ArkUI's bindContextMenu+preview path is implemented as a drag preview on
     * this SDK and can cancel before aboutToAppear. Mirror iOS' single
     * recognizer explicitly: a 300ms hold opens the controlled popup; releasing
     * sooner falls through to onClick/replay.
     */
    private func handleTouch(evt: TouchEvent): Unit {
        match (evt.eventType) {
            case TouchType.Down =>
                if (!this.menuEnabled) { return }
                if (evt.touches.size > 0) {
                    this.touchStartX = evt.touches[0].x
                    this.touchStartY = evt.touches[0].y
                }
                this.pressActive = true
                this.pressGeneration = this.pressGeneration + 1
                let generation = this.pressGeneration
                spawn {
                    sleep(300 * Duration.millisecond)
                    launch {
                        if (this.pressActive && this.pressGeneration == generation) {
                            this.pressActive = false
                            this.suppressNextTap = true
                            this.onMenuAboutToAppear()
                            this.menuVisible = true
                        }
                    }
                }
            case TouchType.Move =>
                if (this.pressActive && evt.touches.size > 0) {
                    let dx = evt.touches[0].x - this.touchStartX
                    let dy = evt.touches[0].y - this.touchStartY
                    if (dx * dx + dy * dy > 100.0) {
                        this.pressActive = false
                        this.pressGeneration = this.pressGeneration + 1
                    }
                }
            case TouchType.Up =>
                this.pressActive = false
                this.pressGeneration = this.pressGeneration + 1
            case TouchType.Cancel =>
                this.pressActive = false
                this.pressGeneration = this.pressGeneration + 1
            case _ => ()
        }
    }

    private func handlePopupStateChange(evt: PopupStateChangeParam): Unit {
        if (!evt.isVisible && this.menuVisible) {
            this.menuVisible = false
            this.suppressNextTap = false
            this.onMenuAboutToDisappear()
        }
    }

    @Builder
    func controlledMenuBuilder() {
        Column {
            this.contextMenuPreviewBuilder()
            this.contextMenuBuilder()
        }
    }

    public func build() {
        Stack(alignContent: Alignment.Center) {
            // Keep the Image node mounted from the first List layout. Replacing
            // an empty Column with Image while the chat navigation transition
            // is committing can defer the branch update until the next scroll
            // or unrelated page refresh. The initial PixelMap is transparent,
            // so this preserves the no-fallback behavior while letting the
            // first Lottie frame update the stable source directly.
            Image(this.displayedFrame)
                .id("animatedEmojiSurface_${this.emoji}")
                .width(this.displaySize)
                .height(this.displaySize)
                .objectFit(ImageFit.Contain)
        }
        .width(this.displaySize)
        .height(this.displaySize)
        .padding(left: 6, right: 6, top: 2)
            .onVisibleAreaChange([0.01], { isVisible: Bool, ratio: Float64 =>
                this.handleVisibility(isVisible, ratio)
            })
        .onDisAppear({ => this.releaseStream() })
        // Keep tap and long press on the same stable Stack while Image updates
        // its PixelMap source for each Lottie frame.
        .onClick({ _evt => this.replay() })
        .onTouch({ evt => this.handleTouch(evt) })
        .bindPopup(
            this.menuVisible,
            CustomPopupOptions(
                builder: bind(this.controlledMenuBuilder, this),
                placement: Placement.Top,
                popupColor: Color.Transparent,
                enableArrow: false,
                autoCancel: true,
                radius: 18.vp,
                onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                    this.handlePopupStateChange(evt)
                })
            )
        )
    }
}
