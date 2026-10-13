package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.math.*
import ohos_app_cangjie_entry.services.getCallService
import ohos_app_cangjie_entry.services.callKeyEmojiSlot
import ohos_app_cangjie_entry.services.getAudioRouteService
import ohos_app_cangjie_entry.services.getAudioSessionManager
import ohos_app_cangjie_entry.services.AudioRoute
import ohos_app_cangjie_entry.services.getGlobalAbilityContext
import ohos_app_cangjie_entry.services.getAudioBlobService
import ohos_app_cangjie_entry.models.CallSession
import ohos_app_cangjie_entry.models.formatCallDuration
import ohos_app_cangjie_entry.models.getCallStateText
import ohos_app_cangjie_entry.components.getCallV2IconRes
import ohos_app_cangjie_entry.components.getCallV2Label
import ohos_app_cangjie_entry.components.getCallV2BgColor
import ohos_app_cangjie_entry.components.getCallV2CircleBg
import ohos_app_cangjie_entry.components.getCallV2IconColor
import ohos_app_cangjie_entry.components.getAvatarGradTop
import ohos_app_cangjie_entry.components.getAvatarGradBottom
import ohos_app_cangjie_entry.components.getAvatarColorIdxByName
import ohos_app_cangjie_entry.utils.getDeviceProximityUtils
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.safeAnimateTo

/**
 * CallScreen — 语音通话主界面（V2 重构，对齐 iOS PrivateCallScreen 2023-12 重设计）
 *
 * ============ iOS 规格源（PrivateCallScreen.swift + Components 各文件，精确值） ============
 * 背景: CallBackgroundLayer 4 色渐变（metal 动态噪声渐变 → 此处近似静态 4 stop 线性渐变）
 *   state0 blue-violet(等待/终止): 568FD6/626ED5/A667D5/7664DA
 *   state1 green(active 好信号):   ACBD65/459F8D/53A4D1/3E917A
 *   state2 orange(active 弱信号 quality<=0.2 即 bars<=1): C0508D/F09536/CE5081/FC7C4C
 * Back:   x = insets.left+10, y = insets.top+12; 白色箭头(13x22 官方 path, 0.9 scale)+8间距+"Back" 17pt 白
 * 头像:   136pt 圆, 水平居中, top = max(insets.top+8, floor(H*0.49)-39-136)
 * blob:   头像四周白色声浪, 尺寸 136+40=176, 随 audioLevel 脉动
 * 标题:   28pt Regular 白, 居中, top = 头像底+39
 * 状态:   16pt 白, 居中, top = 标题底+4
 *   waiting: "Requesting/Ringing/Connecting/Reconnecting" + 3 粒 5pt 跳动圆点(间距1, 距文字6)
 *   active:  信号条(4 条 3x12 阶梯高 3/6/9/12, 间距2, 暗条 50% 白) + 7 间距 + 时长 M:SS
 * emoji 密钥行: active 时 4 emoji 15pt 行居中, y = insets.top+14; 点击展开
 * 展开卡: y = insets.top+73, emoji 40pt + "This call is end-to-end encrypted" 说明 + OK
 * 按钮排: ButtonGroupView — 56pt 圆 × 4, 间距 36, buttonY = H - insets.bottom - 52 - 56
 *   语音序: [speaker, video, mute, end]（视频激活时 speaker→flip, 见 VideoCallScreen）
 *   label 13pt 白, 按钮下 +4; end 填充 0xFF3B30 + 白 ✕(icon 21pt*0.8)
 *   selected → 白底 + 图标镂空（近似: 白底+深色图标）; 未选 → 玻璃态半透明白
 *   video 按钮仅 active/reconnecting 可用（iOS isVideoButtonEnabled）, 禁用 50% 透明
 * notices(通话中提示): 玻璃胶囊(15pt 白, 边距12/6, 圆角=高/2), 按钮排上方 16, 多条间 8
 *   "Your microphone is turned off" / "%name%'s microphone is turned off" / battery low
 *
 * ============ 保留机制（勿动） ============
 * - claimUiDismiss 单发闸、评分 need_rating 门控、keepScreenOn、亮度恢复 double-shot
 * - 每秒状态轮询、audio blob 服务驱动、P2-056 路由 sheet、P2-069 proximity 门控(V1 关闭)
 */

// ==================== 全局常驻 call banner 状态 ====================
private var _callBannerVisible: Bool = false
private var _callBannerPeerName: String = ""

public func setCallBannerVisible(visible: Bool, peerName: String): Unit {
    _callBannerVisible = visible
    _callBannerPeerName = peerName
}
public func isCallBannerVisible(): Bool { _callBannerVisible }
public func callBannerPeerName(): String { _callBannerPeerName }

// proximity 贴脸灭屏门控:false = V1 阶段禁用（Mate60 平放误报问题，见旧注释）
let PROXIMITY_DIM_ENABLED: Bool = false

// ---- V2 布局常量（iOS PrivateCallScreen/ButtonGroupView 精确值） ----
let CALLUI_SAFE_TOP: Float64 = 39.0
let CALLUI_SAFE_BOTTOM: Float64 = 28.0
let CALLUI_AVATAR: Float64 = 136.0
let CALLUI_BLOB: Float64 = 176.0
let CALLUI_BTN: Float64 = 56.0
let CALLUI_BTN_HALF_GAP: Float64 = 18.0

// ---- emoji 槽字符辅助 ----
private func emojiSlot(emoji: String, idx: Int32): String {
    callKeyEmojiSlot(emoji, idx)
}

// ---- 信号条透明度（V2: 达标 1.0, 未达标 0.5） ----
private func sigBarOpacity(bars: Int32, level: Int32): Float64 {
    if (bars >= level) { 1.0 } else { 0.5 }
}

// ---- V2 时长格式（iOS stringForDuration: "%d:%02d" / "%d:%02d:%02d"，分钟无前导零） ----
func callV2DurationText(sec: Int64): String {
    let h = sec / 3600
    let m = (sec / 60) % 60
    let s = sec % 60
    let ss = if (s < 10) { "0${s}" } else { "${s}" }
    if (h > 0) {
        let mm = if (m < 10) { "0${m}" } else { "${m}" }
        return "${h}:${mm}:${ss}"
    }
    return "${m}:${ss}"
}

// ==================== 主界面 ====================

@HybridComponentEntry
@Component
public class CallScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ---- 通话基础状态 ----
    @State var callState: String = "requesting"
    // 主叫 requested 态下被叫已收到（iOS requesting(ringing: true)）
    @State var remoteRinging: Bool = false
    @State var callDuration: Int64 = 0
    @State var isMuted: Bool = false
    @State var isSpeaker: Bool = false
    @State var isVideoEnabled: Bool = false
    @State var peerName: String = ""
    @State var peerAvatarPath: String = ""
    @State var peerAvatarFailed: Bool = false
    @State var keyEmoji: String = ""
    @State var signalBars: Int32 = 4

    // ---- 屏幕实测尺寸（onAreaChange 回填; 默认 Mate60 竖屏 vp） ----
    @State var screenW: Float64 = 360.0
    @State var screenH: Float64 = 777.0

    // ---- waiting 状态 3 点动画 ----
    @State var dotTick: Int64 = 0

    // ---- P2-058: 密钥展开卡 ----
    @State var keyPreviewVisible: Bool = false
    @State var keySlot0Opacity: Float64 = 0.0
    @State var keySlot1Opacity: Float64 = 0.0
    @State var keySlot2Opacity: Float64 = 0.0
    @State var keySlot3Opacity: Float64 = 0.0

    // ---- P2-060: notice 标志位 bit0=远端摄像头关 bit1=远端麦克风关 bit2=本地静音 bit3=低电 ----
    @State var toastFlags: Int32 = 0
    @State var remoteCameraOff: Bool = false
    @State var remoteMicOff: Bool = false
    // 终止原因（busy/missed/disconnect/error/hangup）：驱动终止文案分支（对齐 iOS）
    @State var callEndReason: String = ""
    @State var lowBattery: Bool = false

    // ---- P2-056: 音频路由选择 ----
    @State var routeSheetVisible: Bool = false
    @State var currentRoute: AudioRoute = AudioRoute.Builtin
    @State var availableRoutes: Array<AudioRoute> = Array<AudioRoute>()

    // ---- P2-069: proximity 贴脸灭屏 ----
    @State var screenDimmed: Bool = false

    // ---- P2-067/P2-070: audio blob 动画 ----
    @State var audioLevel: Float32 = 0.0
    @State var blobFrameTick: Int64 = 0
    @State var blobCanvasReady: Bool = false
    private let blobCtx: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))
    private var blobCanvasSize: Float64 = 176.0

    private var _pollRunning: Bool = false
    private var _pollGen: Int64 = 0
    private var _proximityCallbackId: Int64 = -1
    private var _proximityActive: Bool = false

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        // 可复活：从 VideoCallScreen Back 返回时 onDisAppear 已跑过 cleanup（轮询停止、
        // 音频会话释放），此处允许整体重新初始化；_pollGen 使旧轮询代际失效防双跑。
        if (this.loaded && this._pollRunning) { return }
        this.loaded = true
        this._pollGen = this._pollGen + 1
        let service = getCallService()
        match (service.getCurrentCall()) {
            case Some(call) =>
                this.peerName = call.peerName
                this.peerAvatarPath = call.peerAvatarPath
                this.peerAvatarFailed = false
                this.callState = call.state
                this.remoteRinging = call.remoteRinging
                this.isVideoEnabled = call.isLocalVideoEnabled
                this.keyEmoji = call.keyEmoji
                this.signalBars = call.signalBars
                this.isMuted = call.isMuted
            case None =>
                this.peerName = "Unknown"
                this.callState = "terminated"
        }

        // 进入 CallScreen 时隐藏常驻 banner
        setCallBannerVisible(false, "")

        // 通话中保持亮屏（对齐 iOS isIdleTimerDisabled）
        match (getGlobalAbilityContext()) {
            case Some(kc) =>
                let _ = spawn {
                    try {
                        getLastWindow(kc).setWindowKeepScreenOn(true)
                        Hilog.info(0, "CjTelegram", "[CallScreen] keepScreenOn=true")
                    } catch (_: Exception) {
                        Hilog.info(0, "CjTelegram", "[CallScreen] keepScreenOn set failed (non-fatal)")
                    }
                }
            case None => ()
        }

        // ---- P2-068: 获取通话音频会话 ----
        getAudioSessionManager().acquireCallSession()

        // ---- P2-056: 初始化音频路由 ----
        let routeSvc = getAudioRouteService()
        routeSvc.onCallStarted()
        routeSvc.setDeviceChangeCallback({ newRoutes =>
            let arr = Array<AudioRoute>(newRoutes.size, { i => newRoutes[i] })
            launch {
                this.availableRoutes = arr
                this.currentRoute = routeSvc.getCurrentRoute()
            }
        })
        routeSvc.refreshDevices({ newRoutes =>
            let arr = Array<AudioRoute>(newRoutes.size, { i => newRoutes[i] })
            launch {
                this.availableRoutes = arr
                this.currentRoute = routeSvc.getCurrentRoute()
            }
        })

        // ---- P2-069: proximity（V1 门控关闭 → 恢复系统亮度并跳过监听） ----
        if (!PROXIMITY_DIM_ENABLED) {
            match (getGlobalAbilityContext()) {
                case Some(c) =>
                    let _ = spawn {
                        try {
                            getLastWindow(c).setWindowBrightness(Float32(-1.0))
                            Hilog.info(0, "CjTelegram", "[CallScreen] proximity dim disabled (V1); brightness=system default")
                        } catch (_: Exception) { () }
                    }
                case None => ()
            }
            // 注意：不能提前 return——后面的订阅/轮询启动仍需执行（P0 修复）
        } else {
        this._proximityActive = true
        let proxUtils = getDeviceProximityUtils()
        let cbId = proxUtils.addProximityCallback({ isNear =>
            let ctx = getGlobalAbilityContext()
            match (ctx) {
                case Some(c) =>
                    let _ = spawn {
                        try {
                            if (!this._proximityActive) {
                                Hilog.info(0, "CjTelegram", "[CallScreen] proximity write dropped (inactive)")
                            } else {
                                let win = getLastWindow(c)
                                let brightness = if (isNear) { Float32(0.0) } else { Float32(-1.0) }
                                win.setWindowBrightness(brightness)
                                Hilog.info(0, "CjTelegram", "[CallScreen] proximity isNear=${isNear} brightness=${brightness}")
                            }
                        } catch (_: Exception) {
                            Hilog.info(0, "CjTelegram", "[CallScreen] proximity setWindowBrightness failed (non-fatal)")
                        }
                    }
                case None => ()
            }
            launch { this.screenDimmed = isNear }
        })
        this._proximityCallbackId = cbId
        }

        // ---- P2-067/P2-070: 订阅音频电平 → 驱动 blob 动画 ----
        getCallService().setAudioLevelCallback({ level: Float32 =>
            let blobSvc = getAudioBlobService()
            blobSvc.setLevel(Float64(level))
            launch {
                this.audioLevel = level
                if (this.blobCanvasReady) {
                    this.blobFrameTick = this.blobFrameTick + 1
                    this.drawCallBlob()
                }
            }
        })
        let blobSvc = getAudioBlobService()
        blobSvc.setOnFrame({
            =>
            launch {
                this.blobFrameTick = this.blobFrameTick + 1
                if (this.blobCanvasReady) {
                    this.drawCallBlob()
                }
            }
        })
        blobSvc.startAnimation()

        this._pollRunning = true
        let gen = this._pollGen

        // ---- waiting 状态 3 点动画 ticker (V2 StatusView AnimatedDotsLayer 0.6s 周期近似) ----
        let _ = spawn {
            while (this._pollRunning && this._pollGen == gen) {
                sleep(Duration.millisecond * 300)
                if (this.isWaitingState()) {
                    launch { this.dotTick = this.dotTick + 1 }
                }
            }
        }

        // ---- 每秒状态同步轮询 ----
        let _ = spawn {
            while (this._pollRunning && this._pollGen == gen) {
                sleep(Duration.second * 1)
                let svc = getCallService()
                let callOpt = svc.getCurrentCall()

                let newState: String = match (callOpt) {
                    case Some(c) => c.state
                    case None => "terminated"
                }
                let newDur: Int64 = match (callOpt) {
                    case Some(c) => c.duration
                    case None => 0
                }
                let newRemoteRinging: Bool = match (callOpt) {
                    case Some(c) => c.remoteRinging
                    case None => false
                }
                let newMuted: Bool = match (callOpt) {
                    case Some(c) => c.isMuted
                    case None => false
                }
                let newSpeaker: Bool = match (callOpt) {
                    case Some(c) => c.isSpeaker
                    case None => false
                }
                let newVideo: Bool = match (callOpt) {
                    case Some(c) => c.isLocalVideoEnabled
                    case None => false
                }
                let newEmoji: String = match (callOpt) {
                    case Some(c) => c.keyEmoji
                    case None => ""
                }
                let newBars: Int32 = match (callOpt) {
                    case Some(c) => c.signalBars
                    case None => 0
                }
                let newRemoteCamOff: Bool = match (callOpt) {
                    case Some(c) => c.isRemoteCameraOff
                    case None => false
                }
                let newRemoteMicOff: Bool = match (callOpt) {
                    case Some(c) => c.isRemoteMicOff
                    case None => false
                }
                let newEndReason: String = match (callOpt) {
                    case Some(c) => c.endReason
                    case None => ""
                }

                // P2-060 notice 标志位
                let cf: Int32 = if (newRemoteCamOff) { 1 } else { 0 }
                let mf: Int32 = if (newRemoteMicOff) { 2 } else { 0 }
                let uf: Int32 = if (newMuted) { 4 } else { 0 }
                let bf: Int32 = if (this.lowBattery) { 8 } else { 0 }
                let newFlags = cf | mf | uf | bf

                let shouldStop = newState == "terminated"

                launch {
                    this.callState = newState
                    this.remoteRinging = newRemoteRinging
                    this.callDuration = newDur
                    this.isMuted = newMuted
                    this.isSpeaker = newSpeaker
                    this.isVideoEnabled = newVideo
                    this.keyEmoji = newEmoji
                    this.signalBars = newBars
                    this.remoteCameraOff = newRemoteCamOff
                    this.remoteMicOff = newRemoteMicOff
                    this.callEndReason = newEndReason
                    this.toastFlags = newFlags
                }

                if (shouldStop) {
                    this._pollRunning = false
                    // 远端挂断/超时结束：展示 1s → clearCurrentCall → pop（cId>0 且 need_rating 时进评分页）
                    // claimUiDismiss 单发闸防与 handleEndCall / VideoCallScreen 双重 pop。
                    if (getCallService().claimUiDismiss()) {
                        let cId: Int64 = match (callOpt) {
                            case Some(c) => c.callId
                            case None => 0
                        }
                        let cHash: Int64 = match (callOpt) {
                            case Some(c) => c.accessHash
                            case None => 0
                        }
                        let iv: Bool = match (callOpt) {
                            case Some(c) => c.isVideo
                            case None => false
                        }
                        sleep(Duration.second * 1)
                        // 评分页对齐 iOS：仅 服务器 need_rating 且通话真正接通过 才弹
                        let showRating: Bool = match (getCallService().getCurrentCall()) {
                            case Some(c) => c.needRating && c.startTime > 0
                            case None => false
                        }
                        getCallService().clearCurrentCall()
                        if (cId > 0 && showRating) {
                            launch {
                                routerPop()
                                let ratingParam = "${cId}:${cHash}:${iv}"
                                routerPush("CallRatingPage", ratingParam)
                            }
                        } else {
                            launch { routerPop() }
                        }
                    }
                }
            }
        }

        // ---- P2-060: 电量轮询每 30s ----
        let _ = spawn {
            while (this._pollRunning && this._pollGen == gen) {
                sleep(Duration.second * 30)
                let soc: Int32 = 0  // [ENGINE-BATTERY] BatteryInfo.batterySoc
                let isLow = soc > 0 && soc <= 15
                let curMuted = this.isMuted
                let curCamOff = this.remoteCameraOff
                let curMicOff = this.remoteMicOff
                let cf2: Int32 = if (curCamOff) { 1 } else { 0 }
                let mf2: Int32 = if (curMicOff) { 2 } else { 0 }
                let uf2: Int32 = if (curMuted) { 4 } else { 0 }
                let bf2: Int32 = if (isLow) { 8 } else { 0 }
                let flags2 = cf2 | mf2 | uf2 | bf2
                launch {
                    this.lowBattery = isLow
                    this.toastFlags = flags2
                }
            }
        }
    }

    private func cleanup(): Unit {
        this._pollRunning = false

        // 释放亮屏保持——仅通话已结束时。
        // 竞态修复（真机实锤）：push VideoCallScreen 时本页 onDisAppear cleanup 与
        // VideoCallScreen ensureLoaded 的 keepScreenOn(true) 并发，false 后落地会导致
        // 通话中熄屏锁屏（18:48 实测视频通话中黑屏）。通话仍活跃时不释放。
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

        // ---- P2-070: 停止 blob 动画 + 清除音频电平回调 ----
        let blobSvc = getAudioBlobService()
        blobSvc.clearOnFrame()
        blobSvc.stopAnimation()
        getCallService().clearAudioLevelCallback()

        // ---- P2-069: 停止 proximity 监听 + 恢复亮度（double-shot 兜底） ----
        this._proximityActive = false
        if (this._proximityCallbackId >= 0) {
            getDeviceProximityUtils().removeProximityCallback(this._proximityCallbackId)
            this._proximityCallbackId = -1
        }
        let ctxOpt = getGlobalAbilityContext()
        match (ctxOpt) {
            case Some(ctx) =>
                let _ = spawn {
                    try {
                        let win = getLastWindow(ctx)
                        win.setWindowBrightness(Float32(-1.0))
                        sleep(Duration.millisecond * 150)
                        win.setWindowBrightness(Float32(-1.0))
                        Hilog.info(0, "CjTelegram", "[CallScreen] brightness restored (double-shot)")
                    } catch (_: Exception) { () }
                }
            case None => ()
        }

        // ---- P2-068: 释放通话音频会话 ----
        getAudioSessionManager().releaseCallSession()

        // ---- P2-056: 重置路由 ----
        getAudioRouteService().onCallEnded()

        // P2-057: 若通话仍在进行, 展示常驻 call banner
        let svc = getCallService()
        match (svc.getCurrentCall()) {
            case Some(c) =>
                if (c.state == "active" || c.state == "reconnecting") {
                    setCallBannerVisible(true, c.peerName)
                }
            case None => ()
        }
    }

    // ---- 操作处理 ----
    private func handleEndCall(): Unit {
        this._pollRunning = false
        let uiClaimed = getCallService().claimUiDismiss()
        let svc = getCallService()
        svc.endCall()
        launch { this.callState = "terminated" }
        let callIdVal: Int64 = match (svc.getCurrentCall()) {
            case Some(c) => c.callId
            case None => 0
        }
        let callHashVal: Int64 = match (svc.getCurrentCall()) {
            case Some(c) => c.accessHash
            case None => 0
        }
        let isVideoVal: Bool = match (svc.getCurrentCall()) {
            case Some(c) => c.isVideo
            case None => false
        }
        let cId = callIdVal
        let cHash = callHashVal
        let iv = isVideoVal
        if (!uiClaimed) { return }
        let _ = spawn {
            sleep(Duration.second * 1)
            let showRating: Bool = match (getCallService().getCurrentCall()) {
                case Some(c) => c.needRating && c.startTime > 0
                case None => false
            }
            getCallService().clearCurrentCall()
            if (cId > 0 && showRating) {
                launch {
                    routerPop()
                    let ratingParam = "${cId}:${cHash}:${iv}"
                    routerPush("CallRatingPage", ratingParam)
                }
            } else {
                launch { routerPop() }
            }
        }
    }

    private func handleToggleMute(): Unit {
        getCallService().toggleMute()
        let newVal = !this.isMuted
        launch { this.isMuted = newVal }
    }

    private func handleToggleSpeaker(): Unit {
        getCallService().toggleSpeaker()
        let newVal = !this.isSpeaker
        launch { this.isSpeaker = newVal }
    }

    // iOS speakerAction：无蓝牙等第三路由 → 直接切换扬声器/听筒;
    // 有第三路由（hasAudioRouteMenu）→ 弹路由菜单（P2-056 sheet 保留）
    private func handleSpeakerTap(): Unit {
        if (this.callState == "terminated") { return }
        if (this.availableRoutes.size >= 3) {
            this.handleShowRouteSheet()
        } else {
            this.handleToggleSpeaker()
        }
    }

    // ---- P2-056: 音频路由选择 ----

    private func handleShowRouteSheet(): Unit {
        let routeSvc = getAudioRouteService()
        routeSvc.refreshDevices({ newRoutes =>
            let arr = Array<AudioRoute>(newRoutes.size, { i => newRoutes[i] })
            launch {
                this.availableRoutes = arr
                this.currentRoute = routeSvc.getCurrentRoute()
                this.routeSheetVisible = true
            }
        })
    }

    private func handleSelectRoute(route: AudioRoute): Unit {
        launch {
            this.routeSheetVisible = false
            this.currentRoute = route
        }
        getAudioRouteService().setRoute(route)
        let isSpeakerNow = route == AudioRoute.Speaker
        launch { this.isSpeaker = isSpeakerNow }
    }

    // iOS: video 按钮仅 active/reconnecting 可用
    private func handleVideoTap(): Unit {
        if (this.callState != "active" && this.callState != "reconnecting") { return }
        if (!this.isVideoEnabled) {
            // VideoCallScreen binds the local sink first, then enables capture. Enabling here
            // creates a capturer without a sink on physical devices and reproduces the double-tap.
            launch { this.isVideoEnabled = true }
            routerPush("VideoCallScreen", "fromVoice")
        } else {
            let actual = getCallService().setLocalVideoEnabled(false)
            launch { this.isVideoEnabled = actual }
        }
    }

    private func handleEndTap(): Unit {
        if (this.callState == "terminated") { return }
        this.handleEndCall()
    }

    private func handleMuteTap(): Unit {
        if (this.callState == "terminated") { return }
        this.handleToggleMute()
    }

    // 按钮统一分发（@Builder 参数化按钮用）
    private func handleControlTap(t: String): Unit {
        if (t == "mute") { this.handleMuteTap() }
        if (t == "speaker") { this.handleSpeakerTap() }
        if (t == "video") { this.handleVideoTap() }
        if (t == "end") { this.handleEndTap() }
    }

    // 返回：pop 回上一页；cleanup 会在通话仍活跃时自动挂常驻 banner
    private func handleBack(): Unit {
        routerPop()
    }

    // P2-058: 展开密钥卡 + 4 槽交错揭示动画
    private func handleShowKeyPreview(): Unit {
        launch { this.keyPreviewVisible = true }
        let _ = spawn {
            sleep(Duration.millisecond * 80)
            launch {
                safeAnimateTo({ => getUIContext() }, AnimateParam(duration: 300), { => this.keySlot0Opacity = 1.0 })
            }
            sleep(Duration.millisecond * 120)
            launch {
                safeAnimateTo({ => getUIContext() }, AnimateParam(duration: 300), { => this.keySlot1Opacity = 1.0 })
            }
            sleep(Duration.millisecond * 120)
            launch {
                safeAnimateTo({ => getUIContext() }, AnimateParam(duration: 300), { => this.keySlot2Opacity = 1.0 })
            }
            sleep(Duration.millisecond * 120)
            launch {
                safeAnimateTo({ => getUIContext() }, AnimateParam(duration: 300), { => this.keySlot3Opacity = 1.0 })
            }
        }
    }

    private func handleDismissKeyPreview(): Unit {
        launch {
            this.keyPreviewVisible = false
            this.keySlot0Opacity = 0.0
            this.keySlot1Opacity = 0.0
            this.keySlot2Opacity = 0.0
            this.keySlot3Opacity = 0.0
        }
    }

    // ==================== V2 状态/布局计算 ====================

    // 背景渐变状态: 0=blue(等待/终止) 1=green(active) 2=orange(active 弱信号 bars<=1)
    private func bgState(): Int32 {
        if (this.callState == "active") {
            if (this.signalBars <= 1) { return 2 } else { return 1 }
        }
        return 0
    }

    private func isWaitingState(): Bool {
        this.callState == "requesting" || this.callState == "requested" || this.callState == "waiting" || this.callState == "ringing" ||
            this.callState == "accepting" || this.callState == "confirming" || this.callState == "connecting" ||
            this.callState == "reconnecting"
    }

    // V2 StatusView waiting 文案（iOS Call_WaitingStatus*）
    private func statusMainText(): String {
        if (this.callState == "requesting" || this.callState == "waiting") { return "Requesting" }
        // 主叫等待：iOS CallControllerNodeV2.updateCallState requesting(ringing) → .ringing / .requesting
        if (this.callState == "requested") { return if (this.remoteRinging) { "Ringing" } else { "Requesting" } }
        if (this.callState == "ringing") { return "Ringing" }
        if (this.callState == "accepting" || this.callState == "confirming" || this.callState == "connecting") { return "Connecting" }
        if (this.callState == "reconnecting") { return "Reconnecting" }
        if (this.callState == "active") { return callV2DurationText(this.callDuration) }
        // terminated: 接通过显示时长，否则按 endReason 分文案（对齐 iOS 五态，
        // 此前恒 "Call ended"——忙线/未接/失败无区分）
        if (this.callDuration > 0) { return callV2DurationText(this.callDuration) }
        if (this.callEndReason == "busy") { return "Busy" }
        if (this.callEndReason == "missed") { return "Missed" }
        if (this.callEndReason == "disconnect") { return "Disconnected" }
        if (this.callEndReason == "error") { return "Failed" }
        return getCallStateText(this.callState)
    }

    // 3 点动画: 相位错开的透明度脉动（近似 iOS scale 0.3→1.0 交错）
    private func dotOpacity(idx: Int64): Float64 {
        let phase = (this.dotTick + idx) % 3
        if (phase == 0) { return 0.3 }
        if (phase == 1) { return 0.65 }
        return 1.0
    }

    // 头像块(含 blob 176) 顶部 y；头像 top = max(safeTop+8, floor(H*0.49)-39-136)
    private func avatarBlockTop(): Float64 {
        let ideal = floor(this.screenH * 0.49) - 39.0 - CALLUI_AVATAR
        let minTop = CALLUI_SAFE_TOP + 8.0
        if (ideal < minTop) { return minTop - 20.0 }
        return ideal - 20.0
    }

    // 按钮排顶部 y = H - insets.bottom - 52 - 56
    private func buttonsTop(): Float64 {
        this.screenH - CALLUI_SAFE_BOTTOM - 52.0 - CALLUI_BTN
    }

    private func activeNoticeCount(): Int64 {
        var n: Int64 = 0
        if ((this.toastFlags & 4) != 0) { n = n + 1 }
        if ((this.toastFlags & 2) != 0) { n = n + 1 }
        if ((this.toastFlags & 8) != 0) { n = n + 1 }
        return n
    }

    private func noticesBlockHeight(): Float64 {
        let n = this.activeNoticeCount()
        if (n == 0) { return 0.0 }
        return Float64(n) * 32.0 + Float64(n - 1) * 8.0
    }

    private func avatarInitial(): String {
        if (this.peerName.size > 0) {
            this.peerName.toRuneArray()[0].toString()
        } else { "?" }
    }

    private func avatarColorIdx(): Int64 {
        getAvatarColorIdxByName(this.peerName)
    }

    private func videoBtnEnabled(): Bool {
        this.callState == "active" || this.callState == "reconnecting"
    }

    // ---- blob 绘制（V2: 白色声浪两层, 围绕 136 头像, 画布 176） ----
    private func drawCallBlob(): Unit {
        let level = Float64(this.audioLevel)
        let w = this.blobCanvasSize
        let h = this.blobCanvasSize
        let cx = w / 2.0
        let cy = h / 2.0
        let baseR = (if (w < h) { w } else { h }) * 0.5

        this.blobCtx.clearRect(0.0, 0.0, w, h)

        // 外层 (alpha 0.15)
        let bigScale = 0.82 + 0.18 * level
        let bigR = baseR * bigScale
        this.blobCtx.globalAlpha = 0.15
        this.blobCtx.beginPath()
        this.blobCtx.arc(cx, cy, bigR, 0.0, Float64.GetPI() * 2.0)
        this.blobCtx.closePath()
        this.blobCtx.fillStyle = 0xFFFFFFFF
        this.blobCtx.fill()

        // 内层 (alpha 0.3)
        let midScale = 0.74 + 0.16 * level
        let midR = baseR * midScale
        this.blobCtx.globalAlpha = 0.3
        this.blobCtx.beginPath()
        this.blobCtx.arc(cx, cy, midR, 0.0, Float64.GetPI() * 2.0)
        this.blobCtx.closePath()
        this.blobCtx.fillStyle = 0xFFFFFFFF
        this.blobCtx.fill()

        this.blobCtx.globalAlpha = 1.0
    }

    // ==================== @Builder 子构建器 ====================

    @Builder
    func buildBlobCanvas() {
        Canvas(this.blobCtx)
            .width(this.blobCanvasSize)
            .height(this.blobCanvasSize)
            .onReady({
                =>
                this.blobCanvasReady = true
                this.drawCallBlob()
            })
    }

    // V2 圆形控制按钮（56pt 圆, label 13pt +4; 间距由调用方 Blank(36) 承担）
    // 响应性修复（真机实锤）：@Builder 按值参数不随 @State 刷新（mute 白底态不更新），
    // 每钮独立 builder，属性表达式内直接读 this.* 状态。
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
                    .fillColor(getCallV2IconColor("video", this.isVideoEnabled))
            }
            .width(56)
            .height(56)
            .borderRadius(28)
            .backgroundColor(getCallV2CircleBg("video", this.isVideoEnabled))
            .opacity(if (this.callState == "active" || this.callState == "reconnecting") { 1.0 } else { 0.5 })

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
                // End: 官方 CallCancelIcon 白 ✕ PNG（21pt 自然尺寸 * 0.8 ≈ 17）
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

    // V2 信号条（active 状态行内: 4 条 3pt 宽阶梯高 3/6/9/12, 间距 2）
    @Builder
    func buildSignalBars() {
        Row {
            Column {}
                .width(3)
                .height(3)
                .borderRadius(1)
                .backgroundColor(0xFFFFFF)
                .opacity(sigBarOpacity(this.signalBars, 1))
                .margin(right: 2)
            Column {}
                .width(3)
                .height(6)
                .borderRadius(1)
                .backgroundColor(0xFFFFFF)
                .opacity(sigBarOpacity(this.signalBars, 2))
                .margin(right: 2)
            Column {}
                .width(3)
                .height(9)
                .borderRadius(1)
                .backgroundColor(0xFFFFFF)
                .opacity(sigBarOpacity(this.signalBars, 3))
                .margin(right: 2)
            Column {}
                .width(3)
                .height(12)
                .borderRadius(1)
                .backgroundColor(0xFFFFFF)
                .opacity(sigBarOpacity(this.signalBars, 4))
        }
        .height(12)
        .alignItems(VerticalAlign.Bottom)
        .margin(right: 7)
    }

    // waiting 3 点动画（5pt 圆点, 间距 1, 距文字 6）
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

    // 状态行: waiting → 文字+点; active → 信号条+时长（标题底 +4 间距内置）
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

    // notice 玻璃胶囊
    @Builder
    func buildNoticePill(msg: String) {
        Row {
            Image(@r(app.media.callui_ic_toast_micoff))
                .width(16)
                .height(16)
                .fillColor(0xFFFFFF)
                .margin(right: 5)
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

    @Builder
    func buildBatteryNotice() {
        Row {
            Image(@r(app.media.callui_ic_toast_battery))
                .width(16)
                .height(16)
                .fillColor(0xFFFFFF)
                .margin(right: 5)
            Text("${this.peerName}'s battery is low")
                .fontSize(15)
                .fontColor(0xFFFFFF)
        }
        .padding(left: 12, right: 12, top: 6, bottom: 6)
        .backgroundColor(0x28FFFFFF)
        .borderRadius(16)
        .alignItems(VerticalAlign.Center)
    }

    // ---- P2-056: 路由选择 action sheet ----
    @Builder
    func buildRouteSheet() {
        Column {
            Row {
                Text("Audio Output")
                    .fontSize(18)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFFFFFF)
                    .layoutWeight(1)
                Image(@r(app.media.callui_ic_close))
                    .width(16)
                    .height(16)
                    .fillColor(0x8E8E93)
                    .onClick({ _evt => launch { this.routeSheetVisible = false } })
            }
            .width(100.percent)
            .padding(left: 20, right: 20, top: 16, bottom: 8)

            ForEach(this.availableRoutes, itemGenerator: { route: AudioRoute, _idx: Int64 =>
                this.buildRouteItem(route)
            })

            Column {}.height(34)
        }
        .width(100.percent)
        .backgroundColor(0xFF2C2C2E)
        .borderRadius(16)
    }

    @Builder
    func buildRouteItem(route: AudioRoute) {
        Row {
            Text(route.icon())
                .fontSize(22)
                .margin(right: 12)
            Text(route.displayName())
                .fontSize(17)
                .fontColor(0xFFFFFF)
                .layoutWeight(1)
            if (route == this.currentRoute) {
                Image(@r(app.media.callui_ic_check))
                    .width(18)
                    .height(18)
                    .fillColor(0x317AFF)
            }
        }
        .width(100.percent)
        .padding(left: 20, right: 20, top: 14, bottom: 14)
        .onClick({ _evt =>
            let selectedRoute = route
            this.handleSelectRoute(selectedRoute)
        })
    }

    // ==================== 主 build ====================
    public func build() {
        Stack(alignContent: Alignment.TopStart) {

                // ---- V2 背景: 4 色渐变（近似 CallBackgroundLayer） ----
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .linearGradient(
                        angle: 160.0,
                        colors: [
                            (Color(getCallV2BgColor(this.bgState(), 0)), 0.0),
                            (Color(getCallV2BgColor(this.bgState(), 1)), 0.35),
                            (Color(getCallV2BgColor(this.bgState(), 2)), 0.70),
                            (Color(getCallV2BgColor(this.bgState(), 3)), 1.0)
                        ]
                    )

                // ---- 头像块 + 标题 + 状态（居中信息列, 绝对定位对齐 iOS 0.49 规则） ----
                Column {
                    // blob(176) + 头像(136) 层叠
                    Stack(alignContent: Alignment.Center) {
                        this.buildBlobCanvas()

                        Stack(alignContent: Alignment.Center) {
                            if (this.peerAvatarPath.size > 0 && !this.peerAvatarFailed) {
                                Image(this.peerAvatarPath)
                                    .width(CALLUI_AVATAR)
                                    .height(CALLUI_AVATAR)
                                    .objectFit(ImageFit.Cover)
                                    .borderRadius(68)
                                    .onError({ _ => this.peerAvatarFailed = true })
                            } else {
                                Text(this.avatarInitial())
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
                    }
                    .width(CALLUI_BLOB)
                    .height(CALLUI_BLOB)

                    // 头像底 → 标题 39 间距（块内 blob 底已含 20） = 19
                    Text(this.peerName)
                        .fontSize(28)
                        .fontColor(0xFFFFFF)
                        .fontWeight(FontWeight.Regular)
                        .margin(top: 19)

                    // 标题底 → 状态 4（间距在 builder 内）
                    this.buildStatusRow()
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Center)
                .position(x: 0, y: this.avatarBlockTop())

                // ---- Back 按钮（左上, insets.left+10 / top+12） ----
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
                .onClick({ _evt => this.handleBack() })

                // ---- emoji 密钥行（active 时, 顶部居中 y=insets.top+14; 定宽避免遮 Back） ----
                if (this.callState == "active" && this.keyEmoji.size > 0 && !this.keyPreviewVisible) {
                    Row {
                        Text(emojiSlot(this.keyEmoji, 0)).fontSize(15)
                        Text(emojiSlot(this.keyEmoji, 1)).fontSize(15)
                        Text(emojiSlot(this.keyEmoji, 2)).fontSize(15)
                        Text(emojiSlot(this.keyEmoji, 3)).fontSize(15)
                    }
                    .justifyContent(FlexAlign.Center)
                    .width(120)
                    .position(x: this.screenW / 2.0 - 60.0, y: CALLUI_SAFE_TOP + 14.0)
                    .onClick({ _evt => this.handleShowKeyPreview() })
                }

                // ---- notices（按钮排上方 16, 自下而上排列） ----
                if (this.activeNoticeCount() > 0) {
                    Column {
                        if ((this.toastFlags & 4) != 0) {
                            this.buildNoticePill("Your microphone is turned off")
                        }
                        if ((this.toastFlags & 2) != 0) {
                            this.buildNoticePill("${this.peerName}'s microphone is turned off")
                        }
                        if ((this.toastFlags & 8) != 0) {
                            this.buildBatteryNotice()
                        }
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                    .position(x: 0, y: this.buttonsTop() - 16.0)
                    .markAnchor(x: 0, y: this.noticesBlockHeight())
                }

                // ---- V2 按钮排: [speaker, video, mute, end]（56pt, 间距36, 底部 52+insets） ----
                Row {
                    this.buildBtnSpeaker()
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

                // ==================== P2-069: proximity 贴脸灭屏 Overlay ====================
                if (this.screenDimmed) {
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0xFF000000)
                        .zIndex(200)
                }

                // ==================== P2-056: 音频路由选择 action sheet ====================
                if (this.routeSheetVisible) {
                    Column {
                        Column {}.layoutWeight(1)
                            .onClick({ _evt => launch { this.routeSheetVisible = false } })
                        this.buildRouteSheet()
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x66000000)
                    .zIndex(100)
                }

                // ==================== P2-058: 密钥展开卡（V2 EmojiExpandedInfoView 风格） ====================
                if (this.keyPreviewVisible) {
                    Column {
                        Column {
                            // 4 emoji 40pt 交错揭示
                            Row {
                                Text(emojiSlot(this.keyEmoji, 0))
                                    .fontSize(40)
                                    .opacity(this.keySlot0Opacity)
                                Text(emojiSlot(this.keyEmoji, 1))
                                    .fontSize(40)
                                    .opacity(this.keySlot1Opacity)
                                Text(emojiSlot(this.keyEmoji, 2))
                                    .fontSize(40)
                                    .opacity(this.keySlot2Opacity)
                                Text(emojiSlot(this.keyEmoji, 3))
                                    .fontSize(40)
                                    .opacity(this.keySlot3Opacity)
                            }
                            .justifyContent(FlexAlign.Center)
                            .margin(top: 20, bottom: 16)

                            Text(trSource("This call is end-to-end encrypted"))
                                .fontSize(16)
                                .fontColor(0xFFFFFF)
                                .fontWeight(FontWeight.Medium)
                                .textAlign(TextAlign.Center)
                                .margin(bottom: 8)

                            Text("If the emoji on ${this.peerName}'s screen are the same, this call is 100% secure.")
                                .fontSize(14)
                                .fontColor(0xE6FFFFFF)
                                .textAlign(TextAlign.Center)
                                .margin(left: 20, right: 20, bottom: 16)

                            Column {}
                                .width(100.percent)
                                .height(1)
                                .backgroundColor(0x33FFFFFF)

                            Text(trSource("OK"))
                                .fontSize(17)
                                .fontColor(0xFFFFFF)
                                .fontWeight(FontWeight.Medium)
                                .padding(top: 12, bottom: 12)
                                .onClick({ _evt => this.handleDismissKeyPreview() })
                        }
                        .width(300)
                        .backgroundColor(0x8FCAD8E0)
                        .borderRadius(20)
                        .alignItems(HorizontalAlign.Center)
                        .position(x: this.screenW / 2.0 - 150.0, y: CALLUI_SAFE_TOP + 73.0)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .onClick({ _evt => this.handleDismissKeyPreview() })
                    .zIndex(99)
                }
            }
            .width(100.percent)
            .height(100.percent)
            .onAreaChange({ _: Area, newArea: Area =>
                this.screenW = newArea.width.value
                this.screenH = newArea.height.value
            })
            .onAppear({ => this.ensureLoaded() })
            .onDisAppear({ => this.cleanup() })
    }
}
