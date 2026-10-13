package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import kit.ImageKit.PixelMap
import std.math.*
import std.time.DateTime
import ohos_app_cangjie_entry.services.getCallService
import ohos_app_cangjie_entry.services.callKeyEmojiSlot
import ohos_app_cangjie_entry.services.getGlobalAbilityContext
import ohos_app_cangjie_entry.models.formatCallDuration
import ohos_app_cangjie_entry.components.getCallV2IconRes
import ohos_app_cangjie_entry.components.getCallV2Label
import ohos_app_cangjie_entry.components.getCallV2BgColor
import ohos_app_cangjie_entry.components.getCallV2CircleBg
import ohos_app_cangjie_entry.components.getCallV2IconColor
import ohos_app_cangjie_entry.components.getAvatarGradTop
import ohos_app_cangjie_entry.components.getAvatarGradBottom
import ohos_app_cangjie_entry.components.getAvatarColorIdxByName
import ohos_app_cangjie_entry.components.createPixelMapFromBgra
import ohos_app_cangjie_entry.components.createDummyPixelMap
import ohos_app_cangjie_entry.core.voip.TgCallsLib
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.safeAnimateTo

/**
 * VideoCallScreen — 视频通话界面（V2 重构，对齐 iOS PrivateCallScreen video mode）
 *
 * ============ iOS 规格源（PrivateCallScreen.swift + VideoContainerView.swift） ============
 * 主视频:  远端(activeVideoSources[0])全屏; 无远端时本地全屏; 长边适配 +
 *          周边以模糊视频铺底（此处: 同帧 Cover+blur(40) 垫底 + Contain 前景）
 * PiP:     次视频（本地）右下角, aspectFit 进 240pt 方界(控件隐藏时 140), 圆角 18,
 *          右边距 insets.right+12, 底边距 = contentBottomInset(按钮区)+12
 * 顶部:    Back(左上 top+12), 标题 28pt Regular 白 y=top+2+54, 状态 16pt 白 +4,
 *          emoji 密钥行 top+14（active）
 * 按钮排:  56pt 圆×4 间距 36, y = H - insets.bottom - 52 - 56
 *          本地视频开: [flip, video, mute, end]（iOS: activeLocalVideoSource!=nil → speaker→flip）
 *          本地视频关: [speaker, video, mute, end]
 * 控件自动隐藏: 有视频后延时隐藏; 点击切换（iOS hideControlsTimer）
 * notices: "Your microphone is turned off" / "Your camera is turned off" 玻璃胶囊
 * 背景:    无视频时 V2 渐变 + 136 头像 + 名字/状态（同语音页 0.49 规则）
 *
 * ============ 保留机制（勿动） ============
 * - remote/local 双 PixelMap 缓冲(N-2 释放)、帧回调注册/注销、节流
 * - isRemoteVideoActive "只升不降"、claimUiDismiss 单发闸、双 routerPop 收尾
 * - keepScreenOn；进入强制扬声器
 * （移除: PiP F:NNN 调试角标、PiP 拖动（iOS 为角落吸附，V1 拖动实现有 px/vp bug））
 */
@HybridComponentEntry
@Component
public class VideoCallScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var callState: String = "active"
    // 主叫 requested 态下被叫已收到（iOS requesting(ringing: true)）
    @State var remoteRinging: Bool = false
    @State var callDuration: Int64 = 0
    @State var isMuted: Bool = false
    @State var isSpeaker: Bool = true
    @State var isFrontCamera: Bool = true
    @State var showControls: Bool = true
    // iOS toggles controls with transition.spring(duration: 0.4). Keep controls rendered and
    // animate this shared progress so top/bottom/PiP move as one coherent transition.
    @State var controlsProgress: Float64 = 1.0
    @State var peerName: String = ""
    @State var peerAvatarPath: String = ""
    @State var peerAvatarFailed: Bool = false
    @State var isLocalVideoEnabled: Bool = true
    @State var isRemoteVideoActive: Bool = false
    @State var voipConnected: Bool = false
    @State var avatarText: String = "V"
    @State var keyEmoji: String = ""
    @State var signalBars: Int32 = 4
    @State var dotTick: Int64 = 0

    // 屏幕实测尺寸
    @State var screenW: Float64 = 360.0
    @State var screenH: Float64 = 777.0

    // VCALL-7: 远端视频帧渲染
    @State var remoteFrameVersion: Int64 = 0
    // surface 直渲是否激活。每帧从 native 查询（进程级事实源）刷新——不能读
    // TgCallsLib.surfaceActive 静态: napi 桥与页面可能在不同 Cangjie runtime,
    // 静态不共享(实锤: 桥设 true 页面读 false, 渐变盖住 XComponent)。
    @State var surfaceOn: Bool = false
    @State var remoteFrameW: Int32 = 0
    @State var remoteFrameH: Int32 = 0
    private var remotePixelMap: Option<PixelMap> = None
    private var prevRemotePixelMap: Option<PixelMap> = None
    private var lastFrameTime: Int64 = 0

    // VCALL-8: 本地视频帧渲染 (PiP)
    @State var localFrameVersion: Int64 = 0
    @State var localFrameW: Int32 = 0
    @State var localFrameH: Int32 = 0
    private var localPixelMap: Option<PixelMap> = None
    private var prevLocalPixelMap: Option<PixelMap> = None
    private var lastLocalFrameTime: Int64 = 0

    private var remoteFrameCount: Int64 = 0
    private var localFrameCount: Int64 = 0
    private var _hideScheduled: Bool = false
    private var _controlsGeneration: Int64 = 0
    private var _pollAlive: Bool = false
    private var _pollGen: Int64 = 0
    // 入口是否为语音页升级(决定收尾 pop 一次还是两次)
    private var fromVoice: Bool = false

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded && this._pollAlive) { return }
        this.loaded = true
        this._pollGen = this._pollGen + 1
        // 语音页升级视频时(CallScreen push, param="fromVoice")栈里有两个通话页,
        // 收尾需双 pop; 其余入口(直拨/来电 replace)只有本页, 双 pop 会吃掉下面的
        // 页面(实测: 挂断后白屏/主页被弹掉)。
        let entryParam = takePending("VideoCallScreen")
        this.fromVoice = (entryParam == "fromVoice")
        Hilog.info(0, "CjTelegram", "[VideoCallScreen] >>> ensureLoaded() ENTERED <<< fromVoice=${this.fromVoice}")
        let service = getCallService()
        match (service.getCurrentCall()) {
            case Some(call) =>
                this.peerName = call.peerName
                this.peerAvatarPath = call.peerAvatarPath
                this.peerAvatarFailed = false
                this.callState = call.state
                this.remoteRinging = call.remoteRinging
                this.isMuted = call.isMuted
                this.isSpeaker = call.isSpeaker
                // fromVoice is an explicit user request to upgrade; enable only after this page
                // registers its local sink below. Normal re-entry preserves the session state.
                this.isLocalVideoEnabled = if (this.fromVoice) { true } else { call.isLocalVideoEnabled }
                this.isFrontCamera = call.isFrontCamera
                this.isRemoteVideoActive = call.isRemoteVideoEnabled
                this.keyEmoji = call.keyEmoji
                this.signalBars = call.signalBars
                this.avatarText = if (call.peerName.size > 0) { call.peerName.toRuneArray()[0].toString() } else { "V" }
                if (!call.isSpeaker) {
                    service.setSpeakerMode(true)
                    this.isSpeaker = true
                }
            case None =>
                this.peerName = "Unknown"
                this.callState = "terminated"
        }

        // 视频通话保持亮屏（对齐 iOS isIdleTimerDisabled）
        match (getGlobalAbilityContext()) {
            case Some(kc) =>
                let _ = spawn {
                    try {
                        getLastWindow(kc).setWindowKeepScreenOn(true)
                        Hilog.info(0, "CjTelegram", "[VideoCallScreen] keepScreenOn=true")
                    } catch (_: Exception) {
                        Hilog.info(0, "CjTelegram", "[VideoCallScreen] keepScreenOn set failed (non-fatal)")
                    }
                }
            case None => ()
        }

        // VCALL-7: 注册远端视频帧回调
        Hilog.info(0, "CjTelegram", "[VideoCallScreen] Registering remote video output callback")
        service.setVideoOutput({ frameData: Array<Byte>, width: Int32, height: Int32 =>
            this.handleVideoFrame(frameData, width, height)
        })

        // VCALL-8: 注册本地视频帧回调（PiP 预览）
        Hilog.info(0, "CjTelegram", "[VideoCallScreen] Registering local video output callback")
        service.setLocalVideoOutput({ frameData: Array<Byte>, width: Int32, height: Int32 =>
            this.handleLocalVideoFrame(frameData, width, height)
        })
        if (this.isLocalVideoEnabled) {
            let _ = service.setLocalVideoEnabled(true)
        }

        this._pollAlive = true
        let gen = this._pollGen

        // waiting 3 点动画 ticker
        let _ = spawn {
            while (this._pollAlive && this._pollGen == gen) {
                sleep(Duration.millisecond * 300)
                if (this.callState != "active") {
                    launch { this.dotTick = this.dotTick + 1 }
                }
            }
        }

        // 状态同步轮询 + 视频诊断
        Hilog.info(0, "CjTelegram", "[VideoCallScreen] Starting status polling (isVideo=${this.isLocalVideoEnabled})")
        let _ = spawn {
            var running = true
            while (running && this._pollAlive && this._pollGen == gen) {
                sleep(Duration.millisecond * 500)
                let svc = getCallService()
                let callOpt = svc.getCurrentCall()
                launch {
                    match (callOpt) {
                        case Some(c) =>
                            this.callState = c.state
                            this.remoteRinging = c.remoteRinging
                            this.callDuration = c.duration
                            this.isMuted = c.isMuted
                            this.isSpeaker = c.isSpeaker
                            this.isLocalVideoEnabled = c.isLocalVideoEnabled
                            this.isFrontCamera = c.isFrontCamera
                            this.keyEmoji = c.keyEmoji
                            this.signalBars = c.signalBars
                            // 只升不降：帧回调（真帧到达）才是 remote 活跃的第一事实
                            if (c.isRemoteVideoEnabled && !this.isRemoteVideoActive) {
                                this.isRemoteVideoActive = true
                            }
                            if (c.state == "active" && c.duration > 0) {
                                this.voipConnected = true
                            }
                        case None =>
                            this.callState = "terminated"
                    }
                }
                // 有视频后调度一次 5s 自动隐藏控件（iOS hideControlsTimer）
                if (this.remoteFrameVersion > 0 || this.localFrameVersion > 0) {
                    launch { this.scheduleInitialControlsAutoHide(gen) }
                }
                var ended = false
                match (callOpt) {
                    case Some(c) =>
                        if (c.state == "terminated") {
                            running = false
                            ended = true
                        }
                    case None =>
                        running = false
                        ended = true
                }
                // 远端挂断/超时结束：claimUiDismiss 单发闸防双重 pop
                // （仅页面仍活跃时收尾；Back 离开后本轮询代际失效，不再 pop）
                if (ended && this._pollAlive && this._pollGen == gen) {
                    this._pollAlive = false
                    if (getCallService().claimUiDismiss()) {
                        sleep(Duration.second * 1)
                        getCallService().clearCurrentCall()
                        launch {
                            routerPop()
                            if (this.fromVoice) { routerPop() }
                        }
                    }
                }
            }
        }
    }

    private func cleanup(): Unit {
        this._pollAlive = false
        this._controlsGeneration += 1
        this._hideScheduled = false
        // 释放亮屏保持——仅通话已结束时（同 CallScreen 竞态修复：Back 回语音页时
        // 本页 cleanup 不得压掉 CallScreen 的 keepScreenOn）
        let callStillLive: Bool = match (getCallService().getCurrentCall()) {
            case Some(c) => c.state != "terminated"
            case None => false
        }
        if (!callStillLive) {
            match (getGlobalAbilityContext()) {
                case Some(kc) =>
                    let _ = spawn {
                        try { getLastWindow(kc).setWindowKeepScreenOn(false) } catch (_: Exception) { () }
                    }
                case None => ()
            }
        }
        getCallService().clearVideoOutput()
        getCallService().clearLocalVideoOutput()
        this.releaseRemotePixelMap()
        this.releaseLocalPixelMap()
        match (this.prevRemotePixelMap) {
            case Some(old) => try { old.release() } catch (_: Exception) { }
            case None => ()
        }
        this.prevRemotePixelMap = None
        match (this.prevLocalPixelMap) {
            case Some(old) => try { old.release() } catch (_: Exception) { }
            case None => ()
        }
        this.prevLocalPixelMap = None
        Hilog.info(0, "CjTelegram", "[VideoCallScreen] cleanup: cleaned up PixelMaps")

        // Back 离开而通话仍活跃 → 挂常驻 call banner（与 CallScreen.cleanup 对齐）
        match (getCallService().getCurrentCall()) {
            case Some(c) =>
                if (c.state == "active" || c.state == "reconnecting") {
                    setCallBannerVisible(true, c.peerName)
                }
            case None => ()
        }
    }

    /**
     * VCALL-7: 处理远端视频帧（C++ 已转 BGRA; 节流 ~15fps; N-2 缓冲释放）
     */
    private func handleVideoFrame(bgraData: Array<Byte>, width: Int32, height: Int32): Unit {
        this.remoteFrameCount = this.remoteFrameCount + 1
        let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
        if (now - this.lastFrameTime < 66) { return }
        this.lastFrameTime = now
        // 每帧刷新 surface 直渲状态（native 查询, 廉价 FFI）
        let surfNow = TgCallsLib.isRemoteSurfaceActiveNative()
        if (surfNow != this.surfaceOn) {
            launch {
                this.surfaceOn = surfNow
                Hilog.info(0, "CjTelegram", "[VideoCallScreen] surfaceOn -> ${surfNow} (native query)")
            }
        }

        try {
            let pixelMap = createPixelMapFromBgra(bgraData, width, height)
            let w = width
            let h = height
            launch {
                match (this.prevRemotePixelMap) {
                    case Some(old) => try { old.release() } catch (_: Exception) { }
                    case None => ()
                }
                this.prevRemotePixelMap = this.remotePixelMap
                this.remotePixelMap = Some(pixelMap)
                this.remoteFrameVersion = this.remoteFrameVersion + 1
                this.remoteFrameW = w
                this.remoteFrameH = h
                if (!this.isRemoteVideoActive) {
                    this.isRemoteVideoActive = true
                    Hilog.info(0, "CjTelegram", "[VideoCallScreen] Remote video now ACTIVE (first pixelMap created)")
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[VideoCallScreen] Frame conversion error: ${e}")
        }
    }

    private func releaseRemotePixelMap(): Unit {
        match (this.remotePixelMap) {
            case Some(old) =>
                try { old.release() } catch (_: Exception) { }
            case None => ()
        }
        this.remotePixelMap = None
    }

    /**
     * VCALL-8: 处理本地摄像头帧（PiP 预览; 节流 ~10fps）
     */
    private func handleLocalVideoFrame(bgraData: Array<Byte>, width: Int32, height: Int32): Unit {
        this.localFrameCount = this.localFrameCount + 1
        let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
        if (now - this.lastLocalFrameTime < 100) { return }
        this.lastLocalFrameTime = now

        try {
            let pixelMap = createPixelMapFromBgra(bgraData, width, height)
            let w = width
            let h = height
            launch {
                if (!this.isLocalVideoEnabled) {
                    this.isLocalVideoEnabled = true
                }
                match (this.prevLocalPixelMap) {
                    case Some(old) => try { old.release() } catch (_: Exception) { }
                    case None => ()
                }
                this.prevLocalPixelMap = this.localPixelMap
                this.localPixelMap = Some(pixelMap)
                this.localFrameVersion = this.localFrameVersion + 1
                this.localFrameW = w
                this.localFrameH = h
            }
        } catch (e: Exception) {
        }
    }

    private func releaseLocalPixelMap(): Unit {
        match (this.localPixelMap) {
            case Some(old) =>
                try { old.release() } catch (_: Exception) { }
            case None => ()
        }
        this.localPixelMap = None
    }

    private func hasLocalPixelMap(): Bool {
        match (this.localPixelMap) {
            case Some(_) => true
            case None => false
        }
    }

    private func getLocalPixelMap(): PixelMap {
        match (this.localPixelMap) {
            case Some(pm) => pm
            case None => createDummyPixelMap()
        }
    }

    private func hasRemotePixelMap(): Bool {
        match (this.remotePixelMap) {
            case Some(_) => true
            case None => false
        }
    }

    private func getRemotePixelMap(): PixelMap {
        match (this.remotePixelMap) {
            case Some(pm) => pm
            case None => createDummyPixelMap()
        }
    }

    // ---- 操作处理 ----

    private func handleEndCall(): Unit {
        let uiClaimed = getCallService().claimUiDismiss()
        getCallService().endCall()
        this.callState = "terminated"
        if (!uiClaimed) { return }
        let _ = spawn {
            sleep(Duration.second * 1)
            getCallService().clearCurrentCall()
            launch {
                routerPop()
                if (this.fromVoice) { routerPop() }
            }
        }
    }

    private func handleToggleMute(): Unit {
        getCallService().toggleMute()
        this.isMuted = !this.isMuted
    }

    private func handleToggleSpeaker(): Unit {
        getCallService().toggleSpeaker()
        this.isSpeaker = !this.isSpeaker
    }

    private func handleFlipCamera(): Unit {
        getCallService().flipCamera()
        this.isFrontCamera = !this.isFrontCamera
    }

    private func handleToggleVideo(): Unit {
        let desired = !this.isLocalVideoEnabled
        this.isLocalVideoEnabled = getCallService().setLocalVideoEnabled(desired)
    }

    private func handleControlTap(t: String): Unit {
        if (this.callState == "terminated") { return }
        if (t == "mute") { this.handleToggleMute() }
        if (t == "speaker") { this.handleToggleSpeaker() }
        if (t == "flip") { this.handleFlipCamera() }
        if (t == "video") { this.handleToggleVideo() }
        if (t == "end") { this.handleEndCall() }
    }

    private func handleToggleControls(): Unit {
        let nextVisible = !this.showControls
        this.setControlsVisible(nextVisible)
        if (nextVisible) {
            let controlsGeneration = this._controlsGeneration
            let _ = spawn {
                sleep(Duration.second * 5)
                launch {
                    if (this._controlsGeneration == controlsGeneration && this.showControls) {
                        this.setControlsVisible(false)
                    }
                }
            }
        }
    }

    private func scheduleInitialControlsAutoHide(pollGeneration: Int64): Unit {
        // Runs on UI thread: lifecycle check and _hideScheduled mutation are atomic with cleanup.
        if (!this._pollAlive || this._pollGen != pollGeneration || this._hideScheduled) {
            return
        }
        this._hideScheduled = true
        let controlsGeneration = this._controlsGeneration
        let _ = spawn {
            sleep(Duration.second * 5)
            launch {
                if (this._pollAlive && this._pollGen == pollGeneration &&
                    this._controlsGeneration == controlsGeneration && this.showControls) {
                    this.setControlsVisible(false)
                }
            }
        }
    }

    private func setControlsVisible(visible: Bool): Unit {
        this._controlsGeneration += 1
        this.showControls = visible
        let target = if (visible) { 1.0 } else { 0.0 }
        safeAnimateTo(
            { => this.getUIContext() },
            AnimateParam(duration: 400, curve: Curve.EaseOut),
            { => this.controlsProgress = target }
        )
    }

    private func topControlsShift(): Float64 {
        (1.0 - this.controlsProgress) * -96.0
    }

    private func bottomControlsShift(): Float64 {
        (1.0 - this.controlsProgress) * 120.0
    }

    private func handleBack(): Unit {
        routerPop()
    }

    // ==================== V2 布局/状态计算 ====================

    private func primaryIsRemote(): Bool {
        this.isRemoteVideoActive && this.remoteFrameVersion > 0 && this.hasRemotePixelMap()
    }

    private func primaryIsLocal(): Bool {
        !this.primaryIsRemote() && this.isLocalVideoEnabled && this.localFrameVersion > 0 && this.hasLocalPixelMap()
    }

    private func hasAnyVideo(): Bool {
        this.primaryIsRemote() || this.primaryIsLocal()
    }

    // PiP 显示条件: 远端为主画面且本地视频开启且有本地帧
    private func pipVisible(): Bool {
        this.primaryIsRemote() && this.isLocalVideoEnabled && this.localFrameVersion > 0 && this.hasLocalPixelMap()
    }

    // PiP 方界: 控件显示 240 / 隐藏 140（iOS minimizedBoundingSize）
    private func pipBound(): Float64 {
        140.0 + 100.0 * this.controlsProgress
    }

    private func pipW(): Float64 {
        var fw = 3.0
        var fh = 4.0
        if (this.localFrameW > 0 && this.localFrameH > 0) {
            fw = Float64(this.localFrameW)
            fh = Float64(this.localFrameH)
        }
        let b = this.pipBound()
        if (fw >= fh) { return b }
        return floor(b * fw / fh)
    }

    private func pipH(): Float64 {
        var fw = 3.0
        var fh = 4.0
        if (this.localFrameW > 0 && this.localFrameH > 0) {
            fw = Float64(this.localFrameW)
            fh = Float64(this.localFrameH)
        }
        let b = this.pipBound()
        if (fh >= fw) { return b }
        return floor(b * fh / fw)
    }

    private func pipX(): Float64 {
        this.screenW - 12.0 - this.pipW()
    }

    private func pipY(): Float64 {
        // iOS: hidden bottom inset = safe+4+12, visible = safe+52+56+12.
        // Interpolate the 104vp difference with the same controls progress as PiP size.
        let animatedBottomInset = 16.0 + 104.0 * this.controlsProgress
        return this.screenH - (CALLUI_SAFE_BOTTOM + animatedBottomInset) - this.pipH()
    }

    private func buttonsTop(): Float64 {
        this.screenH - CALLUI_SAFE_BOTTOM - 52.0 - CALLUI_BTN
    }

    private func avatarBlockTop(): Float64 {
        let ideal = floor(this.screenH * 0.49) - 39.0 - CALLUI_AVATAR
        let minTop = CALLUI_SAFE_TOP + 8.0
        if (ideal < minTop) { return minTop }
        return ideal
    }

    private func avatarColorIdx(): Int64 {
        getAvatarColorIdxByName(this.peerName)
    }

    private func statusMainText(): String {
        if (this.callState == "requesting" || this.callState == "waiting") { return "Requesting" }
        // 主叫等待（CallService 的 "requested"）：此前未映射，落到末尾 "Call Ended"。
        // iOS CallControllerNodeV2.updateCallState：requesting(ringing) → .ringing / .requesting
        if (this.callState == "requested") { return if (this.remoteRinging) { "Ringing" } else { "Requesting" } }
        if (this.callState == "ringing") { return "Ringing" }
        if (this.callState == "accepting" || this.callState == "confirming" || this.callState == "connecting") { return "Connecting" }
        if (this.callState == "reconnecting") { return "Reconnecting" }
        if (this.callState == "active") { return callV2DurationText(this.callDuration) }
        if (this.callDuration > 0) { return callV2DurationText(this.callDuration) }
        return "Call Ended"
    }

    private func isWaitingState(): Bool {
        this.callState != "active" && this.callState != "terminated"
    }

    private func dotOpacity(idx: Int64): Float64 {
        let phase = (this.dotTick + idx) % 3
        if (phase == 0) { return 0.3 }
        if (phase == 1) { return 0.65 }
        return 1.0
    }

    private func activeNoticeCount(): Int64 {
        var n: Int64 = 0
        if (this.isMuted) { n = n + 1 }
        if (this.primaryIsRemote() && !this.isLocalVideoEnabled) { n = n + 1 }
        return n
    }

    private func noticesBlockHeight(): Float64 {
        let n = this.activeNoticeCount()
        if (n == 0) { return 0.0 }
        return Float64(n) * 32.0 + Float64(n - 1) * 8.0
    }

    // ==================== @Builder ====================

    // V2 圆形控制按钮（同 CallScreen 规格；间距由调用方 Blank(36) 承担）
    // 响应性修复：@Builder 按值参数不随 @State 刷新 → 每钮独立 builder 直读 this.*
    @Builder
    func buildBtnFlip() {
        Column {
            Stack(alignContent: Alignment.Center) {
                Image(getCallV2IconRes("flip"))
                    .width(56)
                    .height(56)
                    .fillColor(0xFFFFFF)
            }
            .width(56)
            .height(56)
            .borderRadius(28)
            .backgroundColor(0x33FFFFFF)

            Text(getCallV2Label("flip"))
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .textAlign(TextAlign.Center)
                .width(84)
                .margin(top: 4)
        }
        .width(CALLUI_BTN)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.handleControlTap("flip") })
    }

    @Builder
    func buildBtnSpeaker() {
        Column {
            Stack(alignContent: Alignment.Center) {
                Image(getCallV2IconRes("speaker"))
                    .width(56)
                    .height(56)
                    .fillColor(getCallV2IconColor("speaker", this.isSpeaker))
            }
            .width(56)
            .height(56)
            .borderRadius(28)
            .backgroundColor(getCallV2CircleBg("speaker", this.isSpeaker))

            Text(getCallV2Label("speaker"))
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .textAlign(TextAlign.Center)
                .width(84)
                .margin(top: 4)
        }
        .width(CALLUI_BTN)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.handleControlTap("speaker") })
    }

    @Builder
    func buildBtnVideo() {
        Column {
            Stack(alignContent: Alignment.Center) {
                Image(getCallV2IconRes("video"))
                    .width(56)
                    .height(56)
                    .fillColor(getCallV2IconColor("video", this.isLocalVideoEnabled))
            }
            .width(56)
            .height(56)
            .borderRadius(28)
            .backgroundColor(getCallV2CircleBg("video", this.isLocalVideoEnabled))

            Text(getCallV2Label("video"))
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .textAlign(TextAlign.Center)
                .width(84)
                .margin(top: 4)
        }
        .width(CALLUI_BTN)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.handleControlTap("video") })
    }

    @Builder
    func buildBtnMute() {
        Column {
            Stack(alignContent: Alignment.Center) {
                Image(getCallV2IconRes("mute"))
                    .width(56)
                    .height(56)
                    .fillColor(getCallV2IconColor("mute", this.isMuted))
            }
            .width(56)
            .height(56)
            .borderRadius(28)
            .backgroundColor(getCallV2CircleBg("mute", this.isMuted))

            Text(getCallV2Label("mute"))
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .textAlign(TextAlign.Center)
                .width(84)
                .margin(top: 4)
        }
        .width(CALLUI_BTN)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.handleControlTap("mute") })
    }

    @Builder
    func buildBtnEnd() {
        Column {
            Stack(alignContent: Alignment.Center) {
                Image(@r(app.media.callui_v2_end))
                    .width(17)
                    .height(17)
            }
            .width(56)
            .height(56)
            .borderRadius(28)
            .backgroundColor(0xFF3B30)

            Text(getCallV2Label("end"))
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .textAlign(TextAlign.Center)
                .width(84)
                .margin(top: 4)
        }
        .width(CALLUI_BTN)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.handleControlTap("end") })
    }

    @Builder
    func buildSignalBars() {
        Row {
            Column {}
                .width(3)
                .height(3)
                .borderRadius(1)
                .backgroundColor(0xFFFFFF)
                .opacity(sigBarOpacityV(this.signalBars, 1))
                .margin(right: 2)
            Column {}
                .width(3)
                .height(6)
                .borderRadius(1)
                .backgroundColor(0xFFFFFF)
                .opacity(sigBarOpacityV(this.signalBars, 2))
                .margin(right: 2)
            Column {}
                .width(3)
                .height(9)
                .borderRadius(1)
                .backgroundColor(0xFFFFFF)
                .opacity(sigBarOpacityV(this.signalBars, 3))
                .margin(right: 2)
            Column {}
                .width(3)
                .height(12)
                .borderRadius(1)
                .backgroundColor(0xFFFFFF)
                .opacity(sigBarOpacityV(this.signalBars, 4))
        }
        .height(12)
        .alignItems(VerticalAlign.Bottom)
        .margin(right: 7)
    }

    @Builder
    func buildWaitingDots() {
        Row {
            Column {}
                .width(5)
                .height(5)
                .borderRadius(3)
                .backgroundColor(0xFFFFFF)
                .opacity(this.dotOpacity(0))
                .margin(right: 1)
            Column {}
                .width(5)
                .height(5)
                .borderRadius(3)
                .backgroundColor(0xFFFFFF)
                .opacity(this.dotOpacity(1))
                .margin(right: 1)
            Column {}
                .width(5)
                .height(5)
                .borderRadius(3)
                .backgroundColor(0xFFFFFF)
                .opacity(this.dotOpacity(2))
        }
        .margin(left: 6, top: 5)
    }

    @Builder
    func buildStatusRow() {
        Row {
            if (this.callState == "active") {
                this.buildSignalBars()
            }
            Text(this.statusMainText())
                .fontSize(16)
                .fontColor(0xFFFFFF)
            if (this.isWaitingState()) {
                this.buildWaitingDots()
            }
        }
        .alignItems(VerticalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .margin(top: 4)
    }

    @Builder
    func buildNoticePill(msg: String, isCam: Bool) {
        Row {
            if (isCam) {
                Image(@r(app.media.callui_ic_toast_cameraoff))
                    .width(16)
                    .height(16)
                    .fillColor(0xFFFFFF)
                    .margin(right: 5)
            } else {
                Image(@r(app.media.callui_ic_toast_micoff))
                    .width(16)
                    .height(16)
                    .fillColor(0xFFFFFF)
                    .margin(right: 5)
            }
            Text(msg)
                .fontSize(15)
                .fontColor(0xFFFFFF)
        }
        .padding(left: 12, right: 12, top: 6, bottom: 6)
        .backgroundColor(0x28FFFFFF)
        .borderRadius(16)
        .margin(bottom: 8)
        .alignItems(VerticalAlign.Center)
    }

    // ==================== build ====================

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            // ---- 底层背景 ----
            // surface 直渲时：底层透明，让 ArkTS 侧 XComponent(远端视频) 透过整个
            // 仓颉页(NodeContainer/FrameNode 支持 alpha 合成)显示。否则走原渐变。
            if (this.surfaceOn) {
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .onClick({ _evt => this.handleToggleControls() })
            } else {
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .linearGradient(
                        angle: 160.0,
                        colors: [
                            (Color(getCallV2BgColor(if (this.callState == "active") { Int32(1) } else { Int32(0) }, 0)), 0.0),
                            (Color(getCallV2BgColor(if (this.callState == "active") { Int32(1) } else { Int32(0) }, 1)), 0.35),
                            (Color(getCallV2BgColor(if (this.callState == "active") { Int32(1) } else { Int32(0) }, 2)), 0.70),
                            (Color(getCallV2BgColor(if (this.callState == "active") { Int32(1) } else { Int32(0) }, 3)), 1.0)
                        ]
                    )
                    .onClick({ _evt => this.handleToggleControls() })
            }

            // ---- 主画面: 远端优先, 否则本地全屏（模糊铺底 + Contain 前景, 近似 iOS 长边适配+边缘模糊） ----
            if (this.primaryIsRemote() && this.surfaceOn) {
                // GPU 直渲：远端帧由底层 ArkTS XComponent surface 显示，此处画透明
                // 占位让其透出（不再走 CPU PixelMap，省 schd-worker GC）。
                Column()
                    .width(100.percent)
                    .height(100.percent)
                    .onClick({ _evt => this.handleToggleControls() })
            } else if (this.primaryIsRemote()) {
                Stack(alignContent: Alignment.Center) {
                    Image(this.getRemotePixelMap())
                        .id("remoteVideoBg_${this.remoteFrameVersion}")
                        .width(100.percent)
                        .height(100.percent)
                        .objectFit(ImageFit.Cover)
                        .blur(40.0)
                        .opacity(0.85)
                    Image(this.getRemotePixelMap())
                        .id("remoteVideo_${this.remoteFrameVersion}")
                        .width(100.percent)
                        .height(100.percent)
                        .objectFit(ImageFit.Contain)
                }
                .width(100.percent)
                .height(100.percent)
                .clip(true)
                .onClick({ _evt => this.handleToggleControls() })
            } else if (this.primaryIsLocal()) {
                Stack(alignContent: Alignment.Center) {
                    Image(this.getLocalPixelMap())
                        .id("localVideoBg_${this.localFrameVersion}")
                        .width(100.percent)
                        .height(100.percent)
                        .objectFit(ImageFit.Cover)
                        .blur(40.0)
                        .opacity(0.85)
                    Image(this.getLocalPixelMap())
                        .id("localVideoMain_${this.localFrameVersion}")
                        .width(100.percent)
                        .height(100.percent)
                        .objectFit(ImageFit.Contain)
                }
                .width(100.percent)
                .height(100.percent)
                .clip(true)
                .onClick({ _evt => this.handleToggleControls() })
            } else {
                // 无视频: V2 头像块（同语音页 0.49 规则）
                Column {
                    Stack(alignContent: Alignment.Center) {
                        if (this.peerAvatarPath.size > 0 && !this.peerAvatarFailed) {
                            Image(this.peerAvatarPath)
                                .width(CALLUI_AVATAR)
                                .height(CALLUI_AVATAR)
                                .objectFit(ImageFit.Cover)
                                .borderRadius(68)
                                .onError({ _ => this.peerAvatarFailed = true })
                        } else {
                            Text(this.avatarText)
                                .fontSize(48)
                                .fontColor(0xFFFFFF)
                                .fontWeight(FontWeight.Medium)
                        }
                    }
                    .width(CALLUI_AVATAR)
                    .height(CALLUI_AVATAR)
                    .borderRadius(68)
                    .linearGradient(
                        angle: 180.0,
                        colors: [
                            (Color(getAvatarGradTop(this.avatarColorIdx())), 0.0),
                            (Color(getAvatarGradBottom(this.avatarColorIdx())), 1.0)
                        ]
                    )

                    Text(this.peerName)
                        .fontSize(28)
                        .fontColor(0xFFFFFF)
                        .fontWeight(FontWeight.Regular)
                        .margin(top: 39)

                    this.buildStatusRow()
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Center)
                .position(x: 0, y: this.avatarBlockTop())
                .onClick({ _evt => this.handleToggleControls() })
            }

            // ---- 本地 PiP（右下, aspectFit 240/140 方界, 圆角 18） ----
            if (this.pipVisible()) {
                Stack(alignContent: Alignment.Center) {
                    Image(this.getLocalPixelMap())
                        .id("localVideo_${this.localFrameVersion}")
                        .width(100.percent)
                        .height(100.percent)
                        .objectFit(ImageFit.Cover)
                }
                .width(this.pipW())
                .height(this.pipH())
                .borderRadius(18)
                .clip(true)
                .backgroundColor(0xFF1C1C1E)
                .shadow(radius: 12.0, color: 0x40000000, offsetX: 0.0, offsetY: 4.0)
                .position(x: this.pipX(), y: this.pipY())
            }

            // ---- 上下 controls 衬底（iOS 关键帧: 轻量渐隐，不是实色黑栏） ----
            // iOS 顶部暗化约在 100vp 内完成，底部按钮后方有对称的向上渐隐。
            if (this.hasAnyVideo()) {
                Column {}
                    .width(100.percent)
                    .height(112)
                    .linearGradient(
                        angle: 180.0,
                        colors: [
                            (Color(0x24000000), 0.0),
                            (Color(0x10000000), 0.48),
                            (Color.Transparent, 1.0)
                        ]
                    )
                    .opacity(this.controlsProgress)

                Column {}
                    .width(100.percent)
                    .height(220)
                    .position(x: 0, y: this.screenH - 220.0)
                    .linearGradient(
                        angle: 180.0,
                        colors: [
                            (Color.Transparent, 0.0),
                            (Color(0x10000000), 0.52),
                            (Color(0x2A000000), 1.0)
                        ]
                    )
                    .opacity(this.controlsProgress)
            }

            if (this.hasAnyVideo()) {
                // 标题 y = top+2+54, 状态 +4（iOS video mode active）
                Column {
                    Text(this.peerName)
                        .fontSize(28)
                        .fontColor(0xFFFFFF)
                        .fontWeight(FontWeight.Regular)
                    this.buildStatusRow()
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Center)
                .position(x: 0, y: CALLUI_SAFE_TOP + 2.0 + 54.0)
                .translate(y: this.topControlsShift())
                .opacity(this.controlsProgress)
            }

            // ---- Back（iOS: hidden 时移出顶部并淡出，spring 0.4s） ----
            Row {
                Image(@r(app.media.callui_v2_back))
                    .width(12)
                    .height(20)
                    .fillColor(0xFFFFFF)
                    .margin(right: 8)
                Text(trSource("Back"))
                    .fontSize(17)
                    .fontColor(0xFFFFFF)
            }
            .alignItems(VerticalAlign.Center)
            .padding(left: 8, right: 8, top: 4, bottom: 4)
            .position(x: 10, y: CALLUI_SAFE_TOP + 8.0)
            .translate(y: this.topControlsShift())
            .opacity(this.controlsProgress)
            .enabled(this.showControls)
            .onClick({ _evt => this.handleBack() })

            // ---- emoji 密钥行（active; top+14; 定宽居中） ----
            if (this.callState == "active" && this.keyEmoji.size > 0) {
                Row {
                    Text(emojiSlotV(this.keyEmoji, 0)).fontSize(15)
                    Text(emojiSlotV(this.keyEmoji, 1)).fontSize(15)
                    Text(emojiSlotV(this.keyEmoji, 2)).fontSize(15)
                    Text(emojiSlotV(this.keyEmoji, 3)).fontSize(15)
                }
                .justifyContent(FlexAlign.Center)
                .width(120)
                .position(x: this.screenW / 2.0 - 60.0, y: CALLUI_SAFE_TOP + 14.0)
                .translate(y: this.topControlsShift())
                .opacity(this.controlsProgress)
            }

            // ---- notices（按钮上方 16） ----
            if (this.activeNoticeCount() > 0) {
                Column {
                    if (this.isMuted) {
                        this.buildNoticePill("Your microphone is turned off", false)
                    }
                    if (this.primaryIsRemote() && !this.isLocalVideoEnabled) {
                        this.buildNoticePill("Your camera is turned off", true)
                    }
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Center)
                .position(x: 0, y: this.buttonsTop() - 16.0)
                .markAnchor(x: 0, y: this.noticesBlockHeight())
                .translate(y: this.bottomControlsShift())
                .opacity(this.controlsProgress)
            }

            // ---- V2 按钮排: 本地视频开 [flip, video, mute, end] / 关 [speaker, video, mute, end] ----
            Row {
                if (this.isLocalVideoEnabled) {
                    this.buildBtnFlip()
                } else {
                    this.buildBtnSpeaker()
                }
                Blank().width(36)
                this.buildBtnVideo()
                Blank().width(36)
                this.buildBtnMute()
                Blank().width(36)
                this.buildBtnEnd()
            }
            .width(100.percent)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Top)
            .position(x: 0, y: this.buttonsTop())
            .translate(y: this.bottomControlsShift())
            .opacity(this.controlsProgress)
            .enabled(this.showControls)
        }
        .width(100.percent)
        .height(100.percent)
        // surface 直渲时页根必须全透明——不透明像素会把 XComponent 的合成洞封死
        // (RS 层 30fps 在跑但屏幕全黑的根因)。非 surface 模式保持原黑底。
        // 注意: 不能写 UInt32(0x00000000)——ArkUI 对无 alpha 位的数值强制补 FF
        // (RSTree 实锤仍是 #FF000000)，必须用 Color.Transparent。
        .backgroundColor(if (this.surfaceOn) { Color.Transparent } else { Color(0xFF000000) })
        .onAreaChange({ _: Area, newArea: Area =>
            this.screenW = newArea.width.value
            this.screenH = newArea.height.value
        })
        .onAppear({ => this.ensureLoaded() })
        .onDisAppear({ => this.cleanup() })
    }
}

// ---- 顶层辅助（build 内禁 let） ----
private func emojiSlotV(emoji: String, idx: Int32): String {
    callKeyEmojiSlot(emoji, idx)
}

private func sigBarOpacityV(bars: Int32, level: Int32): Float64 {
    if (bars >= level) { 1.0 } else { 0.5 }
}
