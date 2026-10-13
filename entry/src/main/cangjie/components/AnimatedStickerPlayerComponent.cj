package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.arkui.ui_context.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getLottieService,
    LottieAnimationState,
    LottiePlayState,
    AnimatedStickerPlaybackMode
}

/**
 * AnimatedStickerPlayerComponent — 动画贴纸播放节点（P2-382）
 *
 * 对应 iOS AnimatedStickerNode (AnimatedStickerNode/Sources/AnimatedStickerNode.swift):
 *   - 支持 play / pause / stop / seek 播放控制
 *   - 可见性驱动自动播停：onVisibleAreaChange → visible=true → play；visible=false → pause
 *   - PlaybackMode: loop / once / count(n) / still
 *   - 复用 LottieAnimationState（lottie-iosService.cj）+ ArkUI AnimatorResult 驱动帧
 *
 * 平台能力说明（P2-382 fidelity-gap 诚实标注）：
 *   - Lottie JSON 元数据解析：完整实现（LottieCppBinding + lottie-iosService）
 *   - 渲染层：opacity/transform 插值驱动（platform_gap：liblottiecpp.so 未集成）
 *   - onVisibleAreaChange：ArkUI 原生 API，完整实现
 *   - play/pause/seek/loop 状态机：完整实现
 *   - tgs（gzip Lottie JSON）解压：platform_gap（需 zlib FFI；当前传入 jsonStr 已解压）
 *
 * 调用链：
 *   aboutToAppear → setupAnimation → setupAnimator
 *   onVisibleAreaChange → { isVisible → play() / pause() }
 *   play/pause/stop → animState.play/pause/stop → animator.play/pause/cancel
 *   animator.onFrame { progress } → animState.onAnimatorProgress → @State currentProgress 更新
 */
@Component
public class AnimatedStickerPlayerComponent {
    // Lottie JSON 字符串（调用方传入；tgs 需调用方先解压）
    public var lottieJson: String = ""
    // 动画 key（用于 LottieService 缓存）
    public var animKey: String = "sticker"
    // 播放模式（P2-382 gap: loop/once/count/still）
    // 对应 iOS AnimatedStickerPlaybackMode
    public var playbackMode: AnimatedStickerPlaybackMode = AnimatedStickerPlaybackMode.PlayLoop
    // 自动播放（component 出现后立即播放）
    public var autoplay: Bool = true
    // 可见性驱动自动播停（P2-382 gap）
    // 对应 iOS AnimatedStickerNode.visibility: Bool { didSet { ... } }
    public var visibilityDriven: Bool = true
    // 显示尺寸
    public var displayWidth: Float64 = 160.0
    public var displayHeight: Float64 = 160.0
    // 播放完成回调（PlayOnce / PlayCount 结束时触发）
    public var onPlaybackFinished: () -> Unit = { => }

    // @State 字段
    @State var currentProgress: Float64 = 0.0
    @State var isPlaying: Bool = false
    @State var isLoaded: Bool = false

    private var animState: ?LottieAnimationState = None
    private var animator: ?AnimatorResult = None
    private var hasFinishedCallback: Bool = false

    // ── 生命周期 ──────────────────────────────────────────────────────────────

    public override func aboutToAppear(): Unit {
        this.setupAnimation()
        this.setupAnimator()
        if (this.autoplay) {
            this.play()
        }
    }

    public override func aboutToDisappear(): Unit {
        match (this.animator) {
            case Some(anim) =>
                anim.cancel()
                this.animator = None
            case None => ()
        }
        match (this.animState) {
            case Some(state) => state.stop()
            case None => ()
        }
    }

    // ── 播放控制 API（P2-382 gap: play/pause/stop/seek）──────────────────────

    /**
     * 开始播放
     * 对应 iOS AnimatedStickerNode.play(firstFrame:fromIndex:)
     */
    public func play(): Unit {
        match (this.animState) {
            case Some(state) =>
                state.play()
                match (this.animator) {
                    case Some(anim) =>
                        anim.play()
                        this.isPlaying = true
                        Hilog.info(0, "CjTelegram", "[AnimatedStickerPlayer] play")
                    case None => ()
                }
            case None => ()
        }
    }

    /**
     * 暂停
     * 对应 iOS AnimatedStickerNode.pause()
     */
    public func pause(): Unit {
        match (this.animState) {
            case Some(state) =>
                state.pause()
                match (this.animator) {
                    case Some(anim) =>
                        anim.pause()
                        this.isPlaying = false
                        Hilog.info(0, "CjTelegram", "[AnimatedStickerPlayer] pause")
                    case None => ()
                }
            case None => ()
        }
    }

    /**
     * 停止并重置到起始帧
     * 对应 iOS AnimatedStickerNode.stop()
     */
    public func stop(): Unit {
        match (this.animState) {
            case Some(state) => state.stop()
            case None => ()
        }
        match (this.animator) {
            case Some(anim) =>
                anim.cancel()
                this.isPlaying = false
                this.currentProgress = 0.0
                Hilog.info(0, "CjTelegram", "[AnimatedStickerPlayer] stop")
            case None => ()
        }
    }

    /**
     * Seek 到指定进度（0.0..1.0）
     * 对应 iOS AnimatedStickerNode.seekTo(_ position: AnimatedStickerPlaybackPosition)
     */
    public func seekToProgress(p: Float64): Unit {
        match (this.animState) {
            case Some(state) =>
                state.seekToProgress(p)
                this.currentProgress = p
                Hilog.info(0, "CjTelegram", "[AnimatedStickerPlayer] seekToProgress p=${p}")
            case None => ()
        }
    }

    // ── 内部初始化 ────────────────────────────────────────────────────────────

    private func setupAnimation(): Unit {
        let json = if (this.lottieJson.size > 0) {
            this.lottieJson
        } else {
            minimalDemoJson()
        }
        let svc = getLottieService()
        let state = svc.createAnimationState(this.animKey, json)
        state.setPlaybackMode(this.playbackMode)
        this.animState = state
        this.isLoaded = true
        Hilog.info(0, "CjTelegram", "[AnimatedStickerPlayer] animation loaded key=${this.animKey}")
    }

    private func setupAnimator(): Unit {
        let durMs = match (this.animState) {
            case Some(state) =>
                let d = state.getDurationMs()
                if (d <= 0) { Int32(1000) } else { d }
            case None => Int32(1000)
        }
        let iters: Int32 = match (this.playbackMode) {
            case AnimatedStickerPlaybackMode.PlayLoop => -1
            case AnimatedStickerPlaybackMode.PlayOnce => 1
            case AnimatedStickerPlaybackMode.PlayCount(n) => n
            case AnimatedStickerPlaybackMode.PlayStill => 1
        }
        let uiCtx = this.getUIContext()
        let opts = AnimatorOptions(
            duration: durMs,
            easing: "linear",
            delay: 0,
            fill: AnimatorFill.Forwards,
            direction: AnimatorDirection.Normal,
            iterations: iters,
            begin: 0.0,
            end: 1.0
        )
        let anim = uiCtx.createAnimator(opts)
        anim.onFrame = { progress: Float64 =>
            match (this.animState) {
                case Some(state) =>
                    state.onAnimatorProgress(progress)
                    this.currentProgress = state.getProgress()
                    // 检查播放状态是否变为 STOPPED（PlayOnce / PlayCount 结束）
                    let stopped = match (state.getPlayState()) {
                        case LottiePlayState.STOPPED => true
                        case _ => false
                    }
                    if (stopped && this.isPlaying && !this.hasFinishedCallback) {
                        this.isPlaying = false
                        this.hasFinishedCallback = true
                        this.onPlaybackFinished()
                        Hilog.info(0, "CjTelegram", "[AnimatedStickerPlayer] playback finished")
                    }
                case None => ()
            }
        }
        anim.onFinish = { =>
            this.isPlaying = false
            Hilog.info(0, "CjTelegram", "[AnimatedStickerPlayer] animator onFinish")
        }
        anim.onCancel = { =>
            this.isPlaying = false
        }
        this.animator = anim
    }

    // ── 辅助方法 ──────────────────────────────────────────────────────────────

    private func getLayerOpacity(layerIdx: Int64): Float64 {
        match (this.animState) {
            case Some(state) =>
                let layers = state.getLayers()
                if (layerIdx >= 0 && layerIdx < layers.size) {
                    let layer = layers[layerIdx]
                    let frame = state.getCurrentFrame()
                    if (layer.isVisibleAt(frame)) {
                        return layer.getOpacityAt(frame)
                    }
                }
                0.0
            case None => 0.0
        }
    }

    private func getDurationMs(): Int32 {
        match (this.animState) {
            case Some(s) => s.getDurationMs()
            case None => 1000
        }
    }

    private func minimalDemoJson(): String {
        return "{\"v\":\"5.9.0\",\"fr\":30,\"ip\":0,\"op\":60,\"w\":512,\"h\":512,\"nm\":\"Sticker\",\"layers\":[{\"ddd\":0,\"ind\":0,\"ty\":4,\"nm\":\"L\",\"ip\":0,\"op\":60,\"ks\":{\"o\":{\"k\":100}}}]}"
    }

    // ── Build ─────────────────────────────────────────────────────────────────

    public func build() {
        Stack(alignContent: Alignment.Center) {
            if (this.isLoaded) {
                // Lottie 动画显示区域
                // platform_gap 说明: 完整 Lottie 矢量渲染需 liblottiecpp.so (OHOS) 集成
                // 当前以 opacity 插值 + layer 可见性驱动实现近似效果
                Column {}
                    .width(this.displayWidth)
                    .height(this.displayHeight)
                    .borderRadius(8)
                    .backgroundColor(0xFF1A1A2E)
                    .opacity(0.2 + this.currentProgress * 0.8)
            } else {
                Column {
                    Text("...")
                        .fontSize(14)
                        .fontColor(0xFF8E8E93)
                }
                .width(this.displayWidth)
                .height(this.displayHeight)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
        }
        .width(this.displayWidth)
        .height(this.displayHeight)
        .onVisibleAreaChange(
            // ratios: [0.0] — 任何可见性变化都触发
            [0.0, 1.0],
            { isVisibleNow: Bool, _ratio: Float64 =>
                if (this.visibilityDriven) {
                    if (isVisibleNow && !this.isPlaying && this.isLoaded) {
                        this.hasFinishedCallback = false
                        this.play()
                        Hilog.info(0, "CjTelegram", "[AnimatedStickerPlayer] onVisible → play")
                    } else if (!isVisibleNow && this.isPlaying) {
                        this.pause()
                        Hilog.info(0, "CjTelegram", "[AnimatedStickerPlayer] onHidden → pause")
                    }
                }
            }
        )
    }
}
