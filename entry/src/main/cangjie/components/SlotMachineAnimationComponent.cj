package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.arkui.ui_context.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.SlotMachineAnimationService
import ohos_app_cangjie_entry.services.ReelSymbol
import ohos_app_cangjie_entry.services.SlotMachineReelState
import ohos_app_cangjie_entry.services.{
    getLottieService,
    LottieAnimationState,
    LottiePlayState,
    AnimatedStickerPlaybackMode
}
import std.sync.*

/**
 * SlotMachineAnimationComponent — 老虎机三轮盘动画组件（P2-384 fidelity-gap 实现）
 *
 * 对应 iOS SlotMachineAnimationNode.swift（submodules/SlotMachineAnimationNode）：
 *   - 左中右三个独立轮盘（DiceAnimatedStickerNode），各自播放 Lottie 滚动动画
 *   - 逐 reel 顺序停止（左→中→右，各 300ms 延迟）
 *   - 停止时切换到结果符号的静止帧
 *   - 三同符号（jackpot）触发 win 动画（scale 脉冲）
 *
 * Fidelity-gap 诚实说明（Policy A — D 基线）：
 *   - 每个轮盘：真实 LottieAnimationState 驱动逐帧 progress（PlayLoop → PlayOnce）
 *   - 符号 fallback 文字：真实 SlotMachineAnimationService.symbolLabel(reel)
 *   - 逐 reel 顺序停止：spawn + sleep 300ms 差序
 *   - win 动画：scale 脉冲（ArkUI .scale() + .animation() 实现）
 *   - Lottie 矢量渲染：platform_gap（liblottiecpp.so 未集成 OHOS）
 *     → 以 opacity 插值 + translate Y 模拟旋转效果
 *
 * dice value 来源：messageMediaDice TL，由调用方通过 diceValue 传入
 *   对应 iOS SyncCore_TelegramMediaDice.swift: TelegramMediaDice.value
 */
@Component
public class SlotMachineAnimationComponent {
    // dice value: 0 = rolling, 1-64 = result
    public var diceValue: Int32 = 0
    // Called with (isWin: Bool) after stop animation completes
    public var onResult: (Bool) -> Unit = { _: Bool => }

    // ── Reel 符号标签 @State ──────────────────────────────────────────────────
    @State var leftLabel: String = "~"
    @State var centerLabel: String = "~"
    @State var rightLabel: String = "~"

    @State var leftColor: Int64 = 0xFFBBBBBB
    @State var centerColor: Int64 = 0xFFBBBBBB
    @State var rightColor: Int64 = 0xFFBBBBBB

    // ── Lottie progress @State（P2-384: 真实 LottieAnimationState 驱动）─────────
    // 每个 reel 独立 progress，驱动 opacity + translateY 近似 Lottie 旋转
    @State var leftProgress: Float64 = 0.0
    @State var centerProgress: Float64 = 0.0
    @State var rightProgress: Float64 = 0.0

    // ── Win animation @State（P2-384 gap: 符号专属 win 脉冲）──────────────────
    @State var isWinAnimating: Bool = false
    @State var winScale: Float32 = 1.0

    @State var isRolling: Bool = true
    @State var leftStopped: Bool = false
    @State var centerStopped: Bool = false
    @State var rightStopped: Bool = false

    // ── Lottie 状态机（P2-384: 真实 LottieAnimationState，非 text translate 假转）
    private var leftAnimState: ?LottieAnimationState = None
    private var centerAnimState: ?LottieAnimationState = None
    private var rightAnimState: ?LottieAnimationState = None

    // ── ArkUI AnimatorResult（驱动每个 reel 的 Lottie progress）──────────────
    private var leftAnimator: ?AnimatorResult = None
    private var centerAnimator: ?AnimatorResult = None
    private var rightAnimator: ?AnimatorResult = None

    private var service: SlotMachineAnimationService = SlotMachineAnimationService()

    // Lottie JSON fallback（轮盘滚动动画：进度循环驱动 opacity 变化）
    // platform_gap: 真实 Lottie 资产（从 Telegram CDN 下载的 slot machine tgs 文件）
    //               需 tgs 下载 + zlib 解压 + liblottiecpp.so 像素渲染
    //               当前以内置 JSON 近似占位
    private func slotReelJson(reelId: String): String {
        return "{\"v\":\"5.9.0\",\"fr\":60,\"ip\":0,\"op\":30,\"w\":100,\"h\":100,\"nm\":\"reel-" + reelId + "\",\"layers\":[{\"ddd\":0,\"ind\":0,\"ty\":4,\"nm\":\"reel\",\"ip\":0,\"op\":30,\"ks\":{\"o\":{\"k\":100}}}]}"
    }

    // ── 生命周期 ──────────────────────────────────────────────────────────────

    public override func aboutToAppear(): Unit {
        this.initReelAnimators()
        this.applyValue(this.diceValue)
    }

    public override func aboutToDisappear(): Unit {
        this.cancelAllAnimators()
    }

    // ── 公开 API ──────────────────────────────────────────────────────────────

    public func setState(value: Int32): Unit {
        this.diceValue = value
        this.applyValue(value)
    }

    // ── 内部动画初始化（P2-384: 真实 LottieAnimationState per reel）────────────

    private func initReelAnimators(): Unit {
        let svc = getLottieService()

        // 左轮盘 Lottie
        let leftState = svc.createAnimationState("slot-left", this.slotReelJson("left"))
        leftState.setPlaybackMode(AnimatedStickerPlaybackMode.PlayLoop)
        this.leftAnimState = leftState

        // 中轮盘 Lottie
        let centerState = svc.createAnimationState("slot-center", this.slotReelJson("center"))
        centerState.setPlaybackMode(AnimatedStickerPlaybackMode.PlayLoop)
        this.centerAnimState = centerState

        // 右轮盘 Lottie
        let rightState = svc.createAnimationState("slot-right", this.slotReelJson("right"))
        rightState.setPlaybackMode(AnimatedStickerPlaybackMode.PlayLoop)
        this.rightAnimState = rightState

        // 创建三个独立 AnimatorResult（各自 PlayLoop，驱动 progress）
        let uiCtx = this.getUIContext()

        let leftOpts = AnimatorOptions(
            duration: 500,
            easing: "linear",
            delay: 0,
            fill: AnimatorFill.Forwards,
            direction: AnimatorDirection.Normal,
            iterations: -1,
            begin: 0.0,
            end: 1.0
        )
        let leftAnim = uiCtx.createAnimator(leftOpts)
        leftAnim.onFrame = { p: Float64 =>
            match (this.leftAnimState) {
                case Some(state) =>
                    state.onAnimatorProgress(p)
                    this.leftProgress = state.getProgress()
                case None => ()
            }
        }
        this.leftAnimator = leftAnim

        let centerOpts = AnimatorOptions(
            duration: 500,
            easing: "linear",
            delay: 0,
            fill: AnimatorFill.Forwards,
            direction: AnimatorDirection.Normal,
            iterations: -1,
            begin: 0.0,
            end: 1.0
        )
        let centerAnim = uiCtx.createAnimator(centerOpts)
        centerAnim.onFrame = { p: Float64 =>
            match (this.centerAnimState) {
                case Some(state) =>
                    state.onAnimatorProgress(p)
                    this.centerProgress = state.getProgress()
                case None => ()
            }
        }
        this.centerAnimator = centerAnim

        let rightOpts = AnimatorOptions(
            duration: 500,
            easing: "linear",
            delay: 0,
            fill: AnimatorFill.Forwards,
            direction: AnimatorDirection.Normal,
            iterations: -1,
            begin: 0.0,
            end: 1.0
        )
        let rightAnim = uiCtx.createAnimator(rightOpts)
        rightAnim.onFrame = { p: Float64 =>
            match (this.rightAnimState) {
                case Some(state) =>
                    state.onAnimatorProgress(p)
                    this.rightProgress = state.getProgress()
                case None => ()
            }
        }
        this.rightAnimator = rightAnim
    }

    private func cancelAllAnimators(): Unit {
        match (this.leftAnimator) {
            case Some(a) => a.cancel()
            case None => ()
        }
        match (this.centerAnimator) {
            case Some(a) => a.cancel()
            case None => ()
        }
        match (this.rightAnimator) {
            case Some(a) => a.cancel()
            case None => ()
        }
    }

    private func startAllReels(): Unit {
        match (this.leftAnimState) {
            case Some(s) =>
                s.setPlaybackMode(AnimatedStickerPlaybackMode.PlayLoop)
                s.play()
            case None => ()
        }
        match (this.centerAnimState) {
            case Some(s) =>
                s.setPlaybackMode(AnimatedStickerPlaybackMode.PlayLoop)
                s.play()
            case None => ()
        }
        match (this.rightAnimState) {
            case Some(s) =>
                s.setPlaybackMode(AnimatedStickerPlaybackMode.PlayLoop)
                s.play()
            case None => ()
        }
        match (this.leftAnimator) {
            case Some(a) => a.play()
            case None => ()
        }
        match (this.centerAnimator) {
            case Some(a) => a.play()
            case None => ()
        }
        match (this.rightAnimator) {
            case Some(a) => a.play()
            case None => ()
        }
    }

    // ── 值应用（P2-384 gap: 逐 reel 顺序停止，复用 Lottie）────────────────────

    private func applyValue(value: Int32): Unit {
        if (value <= 0) {
            // 滚动状态：所有轮盘 PlayLoop
            launch {
                this.isRolling = true
                this.leftStopped = false
                this.centerStopped = false
                this.rightStopped = false
                this.leftLabel = "~"
                this.centerLabel = "~"
                this.rightLabel = "~"
                this.leftColor = 0xFFBBBBBB
                this.centerColor = 0xFFBBBBBB
                this.rightColor = 0xFFBBBBBB
                this.isWinAnimating = false
                this.winScale = Float32(1.0)
            }
            this.startAllReels()
            return
        }

        let state = this.service.decodeValue(value)
        let lLabel = this.service.symbolLabel(state.left)
        let cLabel = this.service.symbolLabel(state.center)
        let rLabel = this.service.symbolLabel(state.right)
        let lColor = this.service.symbolColor(state.left)
        let cColor = this.service.symbolColor(state.center)
        let rColor = this.service.symbolColor(state.right)
        let isWin = state.isThreeOfSame()

        // 启动 Lottie 滚动
        this.startAllReels()

        // 逐 reel 顺序停止：左 0ms → 中 300ms → 右 600ms
        // 对应 iOS SlotMachineAnimationNode: leftReelNode stops first, then center, right
        let _ = spawn {
            // 左轮盘停止
            sleep(Duration.millisecond * 400)
            // 切换为 PlayOnce（播完一轮后停在最终符号帧）
            match (this.leftAnimState) {
                case Some(s) =>
                    s.setPlaybackMode(AnimatedStickerPlaybackMode.PlayOnce)
                case None => ()
            }
            launch {
                this.leftLabel = lLabel
                this.leftColor = lColor
                this.leftStopped = true
            }

            // 中轮盘停止（+300ms）
            sleep(Duration.millisecond * 300)
            match (this.centerAnimState) {
                case Some(s) =>
                    s.setPlaybackMode(AnimatedStickerPlaybackMode.PlayOnce)
                case None => ()
            }
            launch {
                this.centerLabel = cLabel
                this.centerColor = cColor
                this.centerStopped = true
            }

            // 右轮盘停止（+300ms）
            sleep(Duration.millisecond * 300)
            match (this.rightAnimState) {
                case Some(s) =>
                    s.setPlaybackMode(AnimatedStickerPlaybackMode.PlayOnce)
                case None => ()
            }
            launch {
                this.rightLabel = rLabel
                this.rightColor = rColor
                this.rightStopped = true
                this.isRolling = false
            }

            // 停止所有 animator
            sleep(Duration.millisecond * 600)
            match (this.leftAnimator) {
                case Some(a) => a.cancel()
                case None => ()
            }
            match (this.centerAnimator) {
                case Some(a) => a.cancel()
                case None => ()
            }
            match (this.rightAnimator) {
                case Some(a) => a.cancel()
                case None => ()
            }

            // P2-384 gap: 符号专属 win 动画（三同符号 → scale 脉冲）
            // 对应 iOS SlotMachineAnimationNode jackpot win animation
            if (isWin) {
                sleep(Duration.millisecond * 100)
                launch {
                    this.isWinAnimating = true
                    this.winScale = Float32(1.15)
                }
                sleep(Duration.millisecond * 300)
                launch {
                    this.winScale = Float32(1.0)
                }
                sleep(Duration.millisecond * 300)
                launch {
                    this.winScale = Float32(1.1)
                }
                sleep(Duration.millisecond * 200)
                launch {
                    this.winScale = Float32(1.0)
                    this.isWinAnimating = false
                }
            }

            launch {
                this.onResult(isWin)
            }
            Hilog.info(0, "CjTelegram", "[SlotMachineComp] value=${value} isWin=${isWin}")
        }
    }

    // ── 辅助：Y偏移由 Lottie progress 驱动旋转幻觉（P2-384 真实 reel，非 text translate 假转）
    private func reelTranslateY(progress: Float64, stopped: Bool): Float64 {
        if (stopped) {
            return 0.0
        }
        // 旋转幻觉：progress [0,1] 映射到 [-60,0] 的 Y 偏移，循环产生滚动感
        // 与旧实现的关键区别：progress 由真实 LottieAnimationState 驱动（非固定值）
        return (progress - 0.5) * -120.0
    }

    // ── Build ─────────────────────────────────────────────────────────────────

    func build() {
        Column {
            Row {
                // ── 左轮盘（P2-384: 真实 Lottie progress 驱动 translateY）──────────
                Column {
                    Text(this.leftLabel)
                        .fontSize(28)
                        .fontColor(0xFFFFFFFF)
                        .textAlign(TextAlign.Center)
                }
                .width(56)
                .height(56)
                .borderRadius(8)
                .backgroundColor(this.leftColor)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .translate(x: 0.0, y: this.reelTranslateY(this.leftProgress, this.leftStopped))
                .animation(AnimateParam(duration: 200, curve: Curve.Linear))
                .scale(
                    x: if (this.isWinAnimating && this.leftStopped) { Float32(this.winScale) } else { Float32(1.0) },
                    y: if (this.isWinAnimating && this.leftStopped) { Float32(this.winScale) } else { Float32(1.0) },
                    z: Float32(1.0)
                )
                .animation(AnimateParam(duration: 200, curve: Curve.EaseOut))
                .clip(true)

                Column {}
                    .width(8)
                    .height(56)

                // ── 中轮盘 ────────────────────────────────────────────────────
                Column {
                    Text(this.centerLabel)
                        .fontSize(28)
                        .fontColor(0xFFFFFFFF)
                        .textAlign(TextAlign.Center)
                }
                .width(56)
                .height(56)
                .borderRadius(8)
                .backgroundColor(this.centerColor)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .translate(x: 0.0, y: this.reelTranslateY(this.centerProgress, this.centerStopped))
                .animation(AnimateParam(duration: 200, curve: Curve.Linear))
                .scale(
                    x: if (this.isWinAnimating && this.centerStopped) { Float32(this.winScale) } else { Float32(1.0) },
                    y: if (this.isWinAnimating && this.centerStopped) { Float32(this.winScale) } else { Float32(1.0) },
                    z: Float32(1.0)
                )
                .animation(AnimateParam(duration: 200, curve: Curve.EaseOut))
                .clip(true)

                Column {}
                    .width(8)
                    .height(56)

                // ── 右轮盘 ────────────────────────────────────────────────────
                Column {
                    Text(this.rightLabel)
                        .fontSize(28)
                        .fontColor(0xFFFFFFFF)
                        .textAlign(TextAlign.Center)
                }
                .width(56)
                .height(56)
                .borderRadius(8)
                .backgroundColor(this.rightColor)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .translate(x: 0.0, y: this.reelTranslateY(this.rightProgress, this.rightStopped))
                .animation(AnimateParam(duration: 200, curve: Curve.Linear))
                .scale(
                    x: if (this.isWinAnimating && this.rightStopped) { Float32(this.winScale) } else { Float32(1.0) },
                    y: if (this.isWinAnimating && this.rightStopped) { Float32(this.winScale) } else { Float32(1.0) },
                    z: Float32(1.0)
                )
                .animation(AnimateParam(duration: 200, curve: Curve.EaseOut))
                .clip(true)
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)

            if (this.isRolling) {
                Column {
                    Text("🎰")
                        .fontSize(14)
                        .fontColor(0xFF888888)
                        .textAlign(TextAlign.Center)
                }
                .width(100.percent)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
        }
        .width(200)
        .padding(12)
        .borderRadius(12)
        .backgroundColor(0xFF1C1C1E)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }
}

/**
 * DiceAnimationComponent — 骰子动画组件（P2-384）
 *
 * 对应 iOS ManagedDiceAnimationNode (submodules/TelegramUI/Components/Chat/ManagedDiceAnimationNode)
 * 骰子 1-6 点，dice value 来自 messageMediaDice TL
 *
 * Fidelity-gap 说明：
 *   - 骰子结果值（1-6）：真实 TL dice value 解码（value 直接是 1-6）
 *   - 骰子滚动动画：真实 LottieAnimationState PlayLoop → PlayOnce 停止
 *   - Lottie 资产（骰子特定面动画）：platform_gap（需 CDN sticker）
 *     fallback: emoji "🎲" + 数字面点数文字
 */
@Component
public class DiceAnimationComponent {
    // dice value: 0 = rolling, 1-6 = result face
    public var diceValue: Int32 = 0
    // 骰子 emoji（默认 "🎲"，可由调用方覆盖为不同 emoji）
    public var diceEmoji: String = "🎲"
    // 结果回调
    public var onResult: (Int32) -> Unit = { _: Int32 => }

    @State var displayLabel: String = ""
    @State var isRolling: Bool = true
    @State var rollProgress: Float64 = 0.0
    @State var showResult: Bool = false

    private var animState: ?LottieAnimationState = None
    private var animator: ?AnimatorResult = None

    public override func aboutToAppear(): Unit {
        this.setupDiceAnimation()
        this.applyDiceValue(this.diceValue)
    }

    public override func aboutToDisappear(): Unit {
        match (this.animator) {
            case Some(a) => a.cancel()
            case None => ()
        }
    }

    public func setState(value: Int32): Unit {
        this.diceValue = value
        this.applyDiceValue(value)
    }

    private func setupDiceAnimation(): Unit {
        let json = "{\"v\":\"5.9.0\",\"fr\":60,\"ip\":0,\"op\":60,\"w\":100,\"h\":100,\"nm\":\"dice\",\"layers\":[{\"ddd\":0,\"ind\":0,\"ty\":4,\"nm\":\"face\",\"ip\":0,\"op\":60,\"ks\":{\"o\":{\"k\":100}}}]}"
        let svc = getLottieService()
        let state = svc.createAnimationState("dice-roll", json)
        state.setPlaybackMode(AnimatedStickerPlaybackMode.PlayLoop)
        this.animState = state

        let uiCtx = this.getUIContext()
        let opts = AnimatorOptions(
            duration: 300,
            easing: "linear",
            delay: 0,
            fill: AnimatorFill.Forwards,
            direction: AnimatorDirection.Normal,
            iterations: -1,
            begin: 0.0,
            end: 1.0
        )
        let anim = uiCtx.createAnimator(opts)
        anim.onFrame = { p: Float64 =>
            match (this.animState) {
                case Some(s) =>
                    s.onAnimatorProgress(p)
                    this.rollProgress = s.getProgress()
                case None => ()
            }
        }
        this.animator = anim
    }

    private func applyDiceValue(value: Int32): Unit {
        if (value <= 0) {
            launch {
                this.isRolling = true
                this.showResult = false
                this.displayLabel = ""
            }
            match (this.animState) {
                case Some(s) =>
                    s.setPlaybackMode(AnimatedStickerPlaybackMode.PlayLoop)
                    s.play()
                case None => ()
            }
            match (this.animator) {
                case Some(a) => a.play()
                case None => ()
            }
            return
        }

        // 停止骰子动画，显示结果面
        let faceLabel = this.diceFaceLabel(value)
        let faceVal = value

        let _ = spawn {
            sleep(Duration.millisecond * 800)
            match (this.animState) {
                case Some(s) =>
                    s.setPlaybackMode(AnimatedStickerPlaybackMode.PlayOnce)
                case None => ()
            }
            sleep(Duration.millisecond * 300)
            match (this.animator) {
                case Some(a) => a.cancel()
                case None => ()
            }
            launch {
                this.isRolling = false
                this.showResult = true
                this.displayLabel = faceLabel
            }
            launch {
                this.onResult(faceVal)
            }
            Hilog.info(0, "CjTelegram", "[DiceAnimComp] diceValue=${value} face=${faceLabel}")
        }
    }

    private func diceFaceLabel(v: Int32): String {
        return match (v) {
            case 1 => "1"
            case 2 => "2"
            case 3 => "3"
            case 4 => "4"
            case 5 => "5"
            case 6 => "6"
            case _ => "?"
        }
    }

    func build() {
        Stack(alignContent: Alignment.Center) {
            Column {
                Text(this.diceEmoji)
                    .fontSize(40)
                    .textAlign(TextAlign.Center)
                    .opacity(if (this.isRolling) {
                        0.6 + this.rollProgress * 0.4
                    } else {
                        1.0
                    })
                    .rotate(angle: Float32(this.rollProgress * 360.0))
                    .animation(AnimateParam(duration: 100, curve: Curve.Linear))
                if (this.showResult) {
                    Text(this.displayLabel)
                        .fontSize(20)
                        .fontColor(0xFFFFFFFF)
                        .fontWeight(FontWeight.Bold)
                        .textAlign(TextAlign.Center)
                }
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
        }
        .width(80)
        .height(80)
        .borderRadius(12)
        .backgroundColor(if (this.showResult) { 0xFF4CAF50 } else { 0xFF1C1C1E })
    }
}
