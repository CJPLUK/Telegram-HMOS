package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.ImageKit.PixelMap
import ohos.arkui.state_macro_manage.*
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.app.getAppState
import ohos_app_cangjie_entry.services.{
    openAnimatedEmojiEffectStream,
    StreamingLottiePlayer
}

/** One-shot interaction effect backed by an iOS-style two-frame stream. */
@Component
public class AnimatedEmojiEffectComponent {
    @Prop var documentId: Int64
    @Prop var displaySize: Float64
    public var onComplete: () -> Unit = { => }

    @State var ready: Bool = false
    @State var frameIndex: Int64 = 0
    @State var displayedFrame: PixelMap = getEmptyAnimatedEmojiPixelMap()
    /**
     * 帧推进挂共享帧钟（领养 + 一次性 + 16ms 全速车道），与大表情本体同一套。
     * 此前是 Timer.once 逐帧自链：每帧付「到点 → 解码 → spawn(UIThread) →
     * 重挂 Timer」整趟延迟，且漏拍不跳帧 —— 特效素材帧大、解码超预算是常态，
     * 一支 3 秒的特效被拖到明显更长，这正是「点 emoji 的动画比 iOS 慢」的主体。
     */
    private let animation: KeyboardAnimationStream = KeyboardAnimationStream()
    private var stream: Option<StreamingLottiePlayer> = None<StreamingLottiePlayer>
    private var loadStarted: Bool = false
    private var lifecycleGeneration: Int64 = 0

    public override func aboutToAppear(): Unit {
        this.lifecycleGeneration = this.lifecycleGeneration + 1
        this.startIfNeeded()
    }

    public override func aboutToDisappear(): Unit {
        this.releaseStream()
    }

    private func releaseStream(): Unit {
        this.lifecycleGeneration = this.lifecycleGeneration + 1
        this.stopPlayback()
        this.ready = false
        this.displayedFrame = getEmptyAnimatedEmojiPixelMap()
        this.loadStarted = false
        let oldStream = this.stream
        this.stream = None<StreamingLottiePlayer>
        match (oldStream) {
            case Some(player) => let _ = spawn { player.close() }
            case None => ()
        }
    }

    private func startIfNeeded(): Unit {
        if (this.ready || this.loadStarted) { return }
        this.loadStarted = true
        let document = this.documentId
        let generation = this.lifecycleGeneration
        let _ = spawn {
            match (openAnimatedEmojiEffectStream(document)) {
                case Some(player) =>
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
                            this.startPlayback(player)
                        } else {
                            player.close()
                        }
                    }
                case None =>
                    launch {
                        this.loadStarted = false
                        if (this.lifecycleGeneration == generation) { this.onComplete() }
                    }
            }
        }
    }

    private func startPlayback(player: StreamingLottiePlayer): Unit {
        let frameCount = player.getFrameCount()
        if (frameCount <= 1) {
            this.onComplete()
            return
        }
        if (this.animation.isRunning()) { return }
        let generation = this.lifecycleGeneration
        this.animation.targetTickMs = 16
        this.animation.onOneShotDone = { =>
            if (this.lifecycleGeneration == generation) { this.onComplete() }
        }
        // startAdoptedOneShot 内含一次同步 prepare（真解码），不占 UI 线程。
        let _ = spawn {
            let _ = this.animation.startAdoptedOneShot(player,
                { pixelMap: PixelMap =>
                    // 共享帧钟在 UI 线程整批回调，直接写 @State。
                    if (this.lifecycleGeneration == generation) {
                        this.displayedFrame = pixelMap
                    }
                })
        }
    }

    private func stopPlayback(): Unit {
        this.animation.stop()
    }

    private func currentPixelMap(): PixelMap {
        match (this.stream) {
            case Some(player) =>
                match (player.getCurrentFrame()) {
                    case Some(frame) => return frame
                    case None => return getEmptyAnimatedEmojiPixelMap()
                }
            case None => return getEmptyAnimatedEmojiPixelMap()
        }
    }

    public func build() {
        Stack(alignContent: Alignment.Center) {
            Image(this.displayedFrame)
                .width(this.displaySize)
                .height(this.displaySize)
                .objectFit(ImageFit.Contain)
        }
        .id("animatedEmojiEffectHost_${this.documentId}")
        .width(this.displaySize)
        .height(this.displaySize)
        .onAppear({ => this.startIfNeeded() })
        .onDisAppear({ => this.releaseStream() })
    }
}
