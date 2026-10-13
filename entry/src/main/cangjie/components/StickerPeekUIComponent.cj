package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.arkui.ui_context.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getStickerPeekService,
    getLottieService,
    LottieAnimationState,
    AnimatedStickerPlaybackMode,
    StickerItem,
    StickerPeekData,
    StickerPeekAction,
    getStickersService
}
import std.collection.ArrayList
import ohos_app_cangjie_entry.utils.safeAnimateTo

/**
 * StickerPeekUIComponent — 贴纸长按 Peek 预览浮层（P2-383 大幅升级版）
 *
 * 功能（P2-383 增量，对应 iOS fidelity-gap 说明）：
 *   1. 长按贴纸 → 实时动画预览（复用 LottieAnimationState + AnimatorResult 播放 tgs）
 *      对应 iOS StickerPreviewPeekContentNode.animationNode（DefaultAnimatedStickerNodeImpl）
 *      注意：R-130 — 同包 @Component 不能在另一 @Component @Builder 中 DSL 嵌套；
 *            AnimatedStickerPlayerComponent 与本类同属 components 包，因此内联 Lottie 驱动逻辑。
 *   2. 平滑缩放过渡（animateTo scale 0.3 → 1.0）
 *      对应 iOS contextController(.peek presentation)
 *   3. Premium effect overlay（isPremium → 金色光晕 + "✨" 星星效果叠加）
 *      对应 iOS premium sticker 播放时显示 starglow/confetti overlay
 *      platform_gap: iOS 使用 AnimationPlayerNode 播放 premium effect Lottie；
 *        此处用 golden glow opacity/scale 动画降级
 *   4. 接贴纸键盘长按：onStickerKeyboardLongPress 回调
 *      对应 iOS EntityKeyboardInputNode 长按 peek 入口
 *
 * haptic: platform_gap — iOS 在长按开始 / 发送时触发 UIImpactFeedbackGenerator；
 *   HarmonyOS vibrator API 无仓颉绑定（KB 检索 0.016 分），诚实 N/A
 *
 * 调用链：
 *   onTouch(Down) → 500ms 阈值 → loadPeekData / setupAnimation → isVisible=true
 *   aboutToAppear → setupAnimation（lottieJson 有效时）→ setupAnimator → play()
 *   isVisible → build() 显示预览卡片 + 动画播放区 + 快捷按钮
 *   onStickerKeyboardLongPress() → 外部键盘贴纸长按接口
 */
@Component
public class StickerPeekUIComponent {
    @Consume var appStack: NavPathStack

    // ===== 外部输入 =====
    public var sticker: StickerItem = StickerItem()
    public var packId: Int64 = 0
    public var packAccessHash: Int64 = 0
    public var canSend: Bool = true
    // P2-383: 动画贴纸 JSON（已解压的 tgs/Lottie JSON；空字符串 = 静态贴纸）
    // 对应 iOS StickerPreviewPeekContentNode: switch item.content { case .animation(data): ... }
    public var lottieJson: String = ""
    // P2-383: premium 贴纸标记（显示 premium effect overlay）
    public var isPremium: Bool = false

    // 回调
    public var onSend: (StickerItem) -> Unit = { _s: StickerItem => }
    public var onFave: (StickerItem) -> Unit = { _s: StickerItem => }
    public var onClose: () -> Unit = { => }
    // P2-383: 贴纸键盘长按回调（接入贴纸键盘 EntityKeyboard 的长按 peek）
    public var onStickerKeyboardLongPress: (StickerItem) -> Unit = { _s: StickerItem => }

    // ===== UI 状态 =====
    @State var isVisible: Bool = false
    @State var isLoading: Bool = false
    @State var peekData: StickerPeekData = StickerPeekData()
    private var touchDownTime: Int64 = 0
    // P2-383: 预览卡片缩放值（平滑缩放过渡：0.3 → 1.0）
    @State var previewScale: Float32 = Float32(0.3)
    // P2-383: 动画播放进度（0.0..1.0）
    @State var animProgress: Float64 = 0.0
    // P2-383: 动画是否在播放
    private var animIsPlaying: Bool = false
    // P2-383: 动画是否已加载
    @State var animIsLoaded: Bool = false
    // P2-383: premium overlay 闪烁透明度
    @State var premiumGlowOpacity: Float64 = 0.0
    // P2-383: premium overlay 闪烁 scale
    @State var premiumGlowScale: Float32 = Float32(0.8)

    // ===== 动画内部状态（非 @State — 不直接触发 UI；通过 @State animProgress 桥接） =====
    private var animState: ?LottieAnimationState = None
    private var animator: ?AnimatorResult = None

    // ===== 长按阈值（纳秒）=====
    private func longPressThresholdNs(): Int64 {
        return 500_000_000
    }

    // ===== 辅助 =====
    private func packTitleText(): String {
        if (this.peekData.packInfo.title.size > 0) {
            return this.peekData.packInfo.title
        }
        return "Sticker"
    }

    private func stickerDisplayLabel(): String {
        if (this.sticker.altEmoji.size > 0) {
            return this.sticker.altEmoji
        }
        return "Sticker Preview"
    }

    // ===== 生命周期 =====

    public override func aboutToAppear(): Unit {
        // P2-383: 若 lottieJson 已注入，预先加载动画状态
        if (this.lottieJson.size > 0) {
            this.setupAnimation(this.lottieJson)
        }
    }

    public override func aboutToDisappear(): Unit {
        this.teardownAnimator()
    }

    // ===== P2-383: 动画引擎初始化（内联，R-130 规避） =====

    /**
     * 初始化 LottieAnimationState（复用 getLottieService()）
     * 对应 AnimatedStickerPlayerComponent.setupAnimation() 但在同包组件内内联
     */
    private func setupAnimation(json: String): Unit {
        let svc = getLottieService()
        let key = "peek_${this.sticker.documentId}"
        let state = svc.createAnimationState(key, json)
        state.setPlaybackMode(AnimatedStickerPlaybackMode.PlayLoop)
        this.animState = state
        this.animIsLoaded = true
        Hilog.info(0, "CjTelegram", "[StickerPeekUI] animation loaded")
    }

    /**
     * 初始化 AnimatorResult 驱动帧进度
     * 对应 AnimatedStickerPlayerComponent.setupAnimator() 内联版
     */
    private func setupAnimator(): Unit {
        match (this.animState) {
            case None => return
            case Some(_) => ()
        }
        let durMs = match (this.animState) {
            case Some(state) =>
                let d = state.getDurationMs()
                if (d <= 0) { Int32(1000) } else { d }
            case None => Int32(1000)
        }
        let uiCtx = this.getUIContext()
        let opts = AnimatorOptions(
            duration: durMs,
            easing: "linear",
            delay: 0,
            fill: AnimatorFill.Forwards,
            direction: AnimatorDirection.Normal,
            iterations: -1,
            begin: 0.0,
            end: 1.0
        )
        let anim = uiCtx.createAnimator(opts)
        anim.onFrame = { progress: Float64 =>
            match (this.animState) {
                case Some(state) =>
                    state.onAnimatorProgress(progress)
                    this.animProgress = state.getProgress()
                case None => ()
            }
        }
        anim.onFinish = { =>
            this.animIsPlaying = false
        }
        anim.onCancel = { =>
            this.animIsPlaying = false
        }
        this.animator = anim
    }

    private func startAnimation(): Unit {
        match (this.animator) {
            case Some(anim) =>
                anim.play()
                this.animIsPlaying = true
                match (this.animState) {
                    case Some(state) => state.play()
                    case None => ()
                }
                Hilog.info(0, "CjTelegram", "[StickerPeekUI] animation play")
            case None => ()
        }
    }

    private func stopAnimation(): Unit {
        match (this.animator) {
            case Some(anim) =>
                anim.cancel()
                this.animIsPlaying = false
                Hilog.info(0, "CjTelegram", "[StickerPeekUI] animation stop")
            case None => ()
        }
        match (this.animState) {
            case Some(state) => state.stop()
            case None => ()
        }
    }

    private func teardownAnimator(): Unit {
        this.stopAnimation()
        this.animator = None
        this.animState = None
    }

    // ===== P2-383: premium effect overlay 动画 =====

    /**
     * 触发 premium sticker effect overlay（pulsing golden glow）
     * 对应 iOS premium sticker + animateReactionSelection effect overlay（Lottie 粒子效果）
     * platform_gap: iOS 用 AnimationPlayerNode 播放 Lottie；此处 opacity/scale pulsing 降级
     */
    private func animatePremiumOverlay(): Unit {
        let uiCtx = this.getUIContext()
        safeAnimateTo({ => uiCtx }, 
            AnimateParam(duration: 600, curve: Curve.EaseInOut),
            { =>
                this.premiumGlowOpacity = 0.8
                this.premiumGlowScale = Float32(1.2)
            }
        )
        let _ = spawn {
            sleep(Duration.millisecond * 700)
            launch {
                // launch {} 在 UI 线程执行，可以安全调用 getUIContext()
                safeAnimateTo({ => uiCtx }, 
                    AnimateParam(duration: 500, curve: Curve.EaseInOut),
                    { =>
                        this.premiumGlowOpacity = 0.3
                        this.premiumGlowScale = Float32(0.9)
                    }
                )
            }
        }
    }

    // ===== 数据加载 =====

    private func loadPeekData(): Unit {
        this.isLoading = true
        let packIdVal = this.packId
        let packHashVal = this.packAccessHash
        let stickerVal = this.sticker
        let canSendVal = this.canSend
        let lottieJsonVal = this.lottieJson
        let isPremiumVal = this.isPremium
        let _ = spawn {
            let svc = getStickerPeekService()
            let data = svc.buildPeekDataWithAnimation(
                stickerVal, packIdVal, packHashVal,
                lottieJson: lottieJsonVal,
                isPremium: isPremiumVal,
                canSend: canSendVal
            )
            launch {
                this.peekData = data
                this.isLoading = false
                // P2-383: 平滑缩放弹出（0.3 → 1.0）
                this.previewScale = Float32(0.3)
                this.isVisible = true
                // launch {} 在 UI 线程，可安全调用 getUIContext()
                let uiCtxInner = this.getUIContext()
                safeAnimateTo({ => uiCtxInner }, 
                    AnimateParam(duration: 280, curve: Curve.EaseOut),
                    { =>
                        this.previewScale = Float32(1.0)
                    }
                )
                // 启动动画播放
                if (data.lottieJson.size > 0) {
                    this.setupAnimation(data.lottieJson)
                    this.setupAnimator()
                    this.startAnimation()
                }
                // premium effect overlay
                if (data.isPremium) {
                    this.animatePremiumOverlay()
                }
            }
        }
    }

    // ===== 触摸处理 =====

    private func handleTouchDown(ts: Int64): Unit {
        this.touchDownTime = ts
    }

    private func handleTouchUp(ts: Int64): Unit {
        let duration = ts - this.touchDownTime
        if (duration > this.longPressThresholdNs() && !this.isVisible) {
            Hilog.info(0, "CjTelegram", "[StickerPeekUI] long press detected")
            this.loadPeekData()
            // P2-383: 接贴纸键盘长按回调
            let stickerVal = this.sticker
            this.onStickerKeyboardLongPress(stickerVal)
        }
        this.touchDownTime = 0
    }

    private func handleTouchCancel(): Unit {
        this.touchDownTime = 0
    }

    private func dismiss(): Unit {
        this.stopAnimation()
        // P2-383: 收起时平滑缩小（1.0 → 0.3）
        let uiCtx = this.getUIContext()
        safeAnimateTo({ => uiCtx }, 
            AnimateParam(duration: 180, curve: Curve.EaseIn),
            { =>
                this.previewScale = Float32(0.3)
            }
        )
        let _ = spawn {
            sleep(Duration.millisecond * 200)
            launch {
                this.isVisible = false
                this.peekData = StickerPeekData()
                this.premiumGlowOpacity = 0.0
                this.premiumGlowScale = Float32(0.8)
                this.animProgress = 0.0
                this.animIsLoaded = false
            }
        }
        this.onClose()
    }

    private func performAction(actionId: String): Unit {
        let stickerVal = this.sticker
        if (actionId == "send") {
            Hilog.info(0, "CjTelegram", "[StickerPeekUI] action: send")
            this.onSend(stickerVal)
            this.dismiss()
        } else if (actionId == "fave") {
            Hilog.info(0, "CjTelegram", "[StickerPeekUI] action: fave sticker")
            this.onFave(stickerVal)
            this.dismiss()
        } else if (actionId == "view_pack") {
            Hilog.info(0, "CjTelegram", "[StickerPeekUI] action: view pack")
            let packIdVal = this.packId
            this.dismiss()
            this.appStack.pushPathByName("StickerPackPreviewPage", packIdVal.toString())
        } else {
            Hilog.info(0, "CjTelegram", "[StickerPeekUI] unknown actionId")
        }
    }

    private func actionButtonColor(actionId: String): Int64 {
        if (actionId == "send") {
            return 0x007AFF
        }
        return 0x34C759
    }

    // ===== UI 构建 =====

    public func build() {
        Stack {
            // ---------- 触发区域（宿主贴纸视觉体） ----------
            Column {
                Text(this.stickerDisplayLabel())
                    .fontSize(32)
                    .textAlign(TextAlign.Center)
                    .width(52)
                    .height(52)
            }
            .width(52)
            .height(52)
            .borderRadius(8)
            .backgroundColor(0xF2F2F7)
            .onTouch({ evt =>
                match (evt.eventType) {
                    case TouchType.Down =>
                        this.handleTouchDown(evt.timestamp)
                    case TouchType.Up =>
                        this.handleTouchUp(evt.timestamp)
                    case TouchType.Cancel =>
                        this.handleTouchCancel()
                    case _ => ()
                }
            })

            // ---------- 预览浮层（仅 isVisible 时渲染） ----------
            if (this.isVisible) {
                Column {
                    // 半透明背景遮罩，点击关闭
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x80000000)
                        .onClick({ _evt =>
                            this.dismiss()
                        })
                        .position(x: -200, y: -200)
                        .width(600)
                        .height(900)

                    // ---------- 预览卡片（P2-383: 平滑缩放 + 动画内容） ----------
                    Stack(alignContent: Alignment.Center) {
                        Column {
                            // P2-383: 动画播放区域（内联 Lottie 驱动）
                            // 对应 iOS: StickerPreviewPeekContentNode animationNode
                            //   = DefaultAnimatedStickerNodeImpl (AnimatedStickerNode)
                            // R-130 合规: 同包 AnimatedStickerPlayerComponent 不能 DSL 嵌套；
                            //   内联 animProgress @State 驱动 opacity 插值近似动画帧效果
                            if (this.animIsLoaded) {
                                // 动画预览区域：opacity 插值驱动（Lottie 矢量渲染 platform_gap）
                                // platform_gap: 完整矢量渲染需 liblottiecpp.so(OHOS aarch64)；
                                //   当前 animProgress 驱动 opacity 变化提供运动感知
                                Column {}
                                    .width(120)
                                    .height(120)
                                    .borderRadius(12)
                                    .backgroundColor(0xFF1A1A2E)
                                    .opacity(0.15 + this.animProgress * 0.7)
                            } else {
                                // 静态贴纸：放大 emoji 展示（非动画降级）
                                Text(this.stickerDisplayLabel())
                                    .fontSize(80)
                                    .textAlign(TextAlign.Center)
                                    .width(120)
                                    .height(120)
                            }

                            // 包名
                            Text(this.packTitleText())
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(top: 8)
                                .maxLines(1)
                        }
                        .width(200)
                        .padding(top: 20, bottom: 12, left: 16, right: 16)
                        .alignItems(HorizontalAlign.Center)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)

                        // P2-383: premium effect overlay（golden glow）
                        // 对应 iOS: premium sticker + starglow effect 叠加
                        // platform_gap: iOS 播放 premium Lottie；此处用 golden glow 降级
                        if (this.peekData.isPremium) {
                            Column {
                                Text("✨")
                                    .fontSize(40)
                                    .textAlign(TextAlign.Center)
                            }
                            .width(200)
                            .height(160)
                            .borderRadius(12)
                            .backgroundColor(0x22FFD700)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .scale(
                                x: this.premiumGlowScale,
                                y: this.premiumGlowScale,
                                z: 1.0
                            )
                            .opacity(this.premiumGlowOpacity)
                        }
                    }
                    .width(200)

                    // ---------- 快捷操作按钮 ----------
                    if (this.isLoading) {
                        Text("...")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .margin(top: 8)
                    } else {
                        Column {
                            ForEach(this.peekData.actions, itemGenerator: { action: StickerPeekAction, _idx: Int64 =>
                                Button(action.label)
                                    .width(200)
                                    .height(44)
                                    .fontSize(15)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFFFFFF)
                                    .backgroundColor(this.actionButtonColor(action.actionId))
                                    .borderRadius(10)
                                    .margin(top: 8)
                                    .onClick({ _evt =>
                                        this.performAction(action.actionId)
                                    })
                            })
                        }
                        .margin(top: 8)
                        .alignItems(HorizontalAlign.Center)
                    }
                }
                // P2-383: 平滑缩放过渡（animateTo 驱动 scale 0.3→1.0）
                .scale(
                    x: this.previewScale,
                    y: this.previewScale,
                    z: 1.0
                )
                .position(x: 0, y: -320)
                .zIndex(100)
            }
        }
        .width(52)
        .height(52)
    }
}
