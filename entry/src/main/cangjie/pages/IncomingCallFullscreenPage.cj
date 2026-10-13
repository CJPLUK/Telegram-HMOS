package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getCallService
import ohos_app_cangjie_entry.components.{
    getIncomingCallTypeText,
    getCallerInitial,
    getCallV2IconRes,
    getCallV2BgColor,
    getAvatarGradTop,
    getAvatarGradBottom,
    getAvatarColorIdxByName
}
import std.convert.*
import ohos_app_cangjie_entry.router.*

/**
 * IncomingCallFullscreenPage — 来电全屏界面 (P2-071 in-app 替代)
 *
 * iOS 对照:
 *   CallKit CXProvider.reportIncomingCall() → 系统级锁屏来电 UI
 *   CallKitIntegration.swift CXAnswerCallAction / CXEndCallAction
 *
 * HarmonyOS 平台差异 (诚实 N-A 记录):
 *   [已实现] 系统级来电 UI（后台）:
 *     Call Service Kit voipCall.reportIncomingCall（ArkTS impls/VoipCallImpl.ets）≙ CallKit
 *     reportNewIncomingCall。系统横幅上点接听 → CallService.handleVoipUiEvent 接听，
 *     本页 watcher 经 takeAnsweredFromSystemUi 换成通话页；系统不接受时退回来电通知。
 *   [N-A] 来电 intent / 全局来电覆盖:
 *     Android 风格的 INCOMING_CALL intent / HUD 覆盖层在 HarmonyOS 均不适用。
 *   [N-A] 硬件键接听 (耳机按钮 / 音量接听):
 *     需要系统通话权限，第三方应用不可达。
 *   [已实现] 应用内来电替代:
 *     • MainTabPage 内联来电 overlay（P2 K8 阶段已有 IncomingCallOverlay 辅助函数）
 *     • LocalNotificationDisplayService.publishIncomingCallNotification（通知横幅，P2-258）
 *     • 本页: 进入应用后可导航到此页展示全屏来电 UI → 接/拒 → 进入 CallScreen
 *
 * 路由参数格式: "{callId}"。姓名、头像与媒体类型始终从匹配的当前 CallSession 读取，
 * 避免异步导航期间展示过期或被替换的会话。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（.hideTitleBar/.onReady 一并去掉），只留内部 Column
 *  - onReady param 接收 → ensureLoaded()（.onAppear 触发）内 takePending("IncomingCallFullscreenPage")
 *  - pushPathByName → routerPush；pop → routerPop
 */

// ==================== 辅助函数 ====================

private func parseIncomingCallId(raw: String): Int64 {
    if (raw.size == 0) { return 0 }
    // Compatibility with the pre-hybrid "name:isVideo:callId" route format.
    let parts = raw.split(":")
    var callId: Int64 = 0
    if (parts.size >= 3) {
        try { callId = Int64.parse(parts[2]) } catch (_: Exception) {}
    } else {
        try { callId = Int64.parse(raw) } catch (_: Exception) {}
    }
    return callId
}

private func buildAvatarBgColor(name: String): Int64 {
    if (name.size == 0) { return 0xFF555555 }
    let code = UInt32(name.toRuneArray()[0])
    let idx = Int64(code) % 6
    let colors: Array<Int64> = [0xFF0088CC, 0xFF00CC88, 0xFFCC4400, 0xFF8844FF, 0xFFFF4488, 0xFF44AAFF]
    return colors[idx]
}

// ==================== IncomingCallFullscreenPage ====================

@HybridComponentEntry
@Component
public class IncomingCallFullscreenPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var callerName: String = "Unknown"
    @State var callerAvatarPath: String = ""
    @State var callerAvatarFailed: Bool = false
    @State var isVideo: Bool = false
    @State var callId: Int64 = 0

    // 呼叫状态
    @State var callAction: String = "ringing"
    // "ringing" | "accepting" | "declining" | "done"

    // 按钮防抖
    @State var actionLocked: Bool = false

    @State var loaded: Bool = false
    private var _watching: Bool = false
    private var _watchGeneration: Int64 = 0

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("IncomingCallFullscreenPage")
        let param = if (raw == "{}") { "" } else { raw }
        let expectedCallId = parseIncomingCallId(param)
        if (expectedCallId <= 0) {
            Hilog.info(0, "CjTelegram", "[IncomingCallFullscreenPage] invalid route callId=${expectedCallId}")
            launch { routerPop() }
            return
        }
        // The call session is the SSOT. phoneCallRequested only carries adminId, and CallService
        // resolves that id through the cached/local peer store before opening this page. The old
        // route push sent an empty string, causing this page to overwrite the real peer with
        // "Unknown". Bind the page to the callId to reject delayed/stale navigation.
        match (getCallService().getCurrentCall()) {
            case Some(call) =>
                if (call.state != "ringing" || call.callId != expectedCallId) {
                    Hilog.info(0, "CjTelegram", "[IncomingCallFullscreenPage] stale route expected=${expectedCallId} current=${call.callId}/${call.state}")
                    launch { routerPop() }
                    return
                }
                this.callerName = if (call.peerName.size > 0) { call.peerName } else { "User ${call.peerId}" }
                this.callerAvatarPath = call.peerAvatarPath
                this.callerAvatarFailed = false
                this.isVideo = call.isVideo
                this.callId = call.callId
            case None =>
                Hilog.info(0, "CjTelegram", "[IncomingCallFullscreenPage] stale route without active call expected=${expectedCallId}")
                launch { routerPop() }
                return
        }
        Hilog.info(0, "CjTelegram", "[IncomingCallFullscreenPage] loaded caller=${this.callerName} avatar=${!this.callerAvatarPath.isEmpty()} video=${this.isVideo}")
        this.startBoundCallWatcher()
    }

    private func startBoundCallWatcher(): Unit {
        if (this._watching) { return }
        this._watching = true
        this._watchGeneration += 1
        let generation = this._watchGeneration
        // 主叫取消/超时未接修复：ringing 中 session 终止时自动关闭铃声页
        // （此前只有接听/拒绝两条路径会 pop，主叫取消则铃声页滞留）。
        // actionLocked=true（已接/已拒）后交由对应路径收尾，本监听退出。
        let _ = spawn {
            while (this._watching && this._watchGeneration == generation) {
                sleep(Duration.millisecond * 500)
                if (!this._watching || this._watchGeneration != generation) {
                    break
                }
                if (this.actionLocked) {
                    this.stopBoundCallWatcher()
                } else {
                    match (getCallService().getCurrentCall()) {
                        case Some(c) =>
                            if (c.callId == this.callId && c.state != "ringing" && c.state != "terminated"
                                && getCallService().takeAnsweredFromSystemUi(c.callId)) {
                                // 在系统通话界面（voipCall 来电横幅）上点了接听：与 doAccept 同样换成通话页
                                this.stopBoundCallWatcher()
                                let video = this.isVideo
                                Hilog.info(0, "CjTelegram", "[IncomingCallFullscreenPage] answered from system call UI callId=${c.callId}")
                                launch {
                                    this.actionLocked = true
                                    this.callAction = "done"
                                    routerPop()
                                    if (video) {
                                        routerPush("VideoCallScreen", "")
                                    } else {
                                        routerPush("CallScreen", "")
                                    }
                                }
                            } else if (c.callId != this.callId || c.state != "ringing") {
                                this.stopBoundCallWatcher()
                                Hilog.info(0, "CjTelegram", "[IncomingCallFullscreenPage] bound call changed current=${c.callId}/${c.state} expected=${this.callId} → auto dismiss")
                                launch { routerPop() }
                            }
                        case None =>
                            this.stopBoundCallWatcher()
                            launch { routerPop() }
                    }
                }
            }
        }
    }

    private func stopBoundCallWatcher(): Unit {
        this._watching = false
        this._watchGeneration += 1
    }

    private func handleAppear(): Unit {
        if (!this.loaded) {
            this.ensureLoaded()
            return
        }
        if (this.isBoundRingingCall() && !this.actionLocked) {
            this.startBoundCallWatcher()
        } else {
            Hilog.info(0, "CjTelegram", "[IncomingCallFullscreenPage] reappear without bound ringing call=${this.callId}")
            launch { routerPop() }
        }
    }

    private func isBoundRingingCall(): Bool {
        match (getCallService().getCurrentCall()) {
            case Some(call) => return call.callId == this.callId && call.state == "ringing"
            case None => return false
        }
    }

    // ==================== 接听 ====================

    private func doAccept(): Unit {
        if (this.actionLocked) { return }
        if (!this.isBoundRingingCall()) {
            this.actionLocked = true
            this.stopBoundCallWatcher()
            routerPop()
            return
        }
        this.actionLocked = true
        this.stopBoundCallWatcher()
        this.callAction = "accepting"
        Hilog.info(0, "CjTelegram", "[IncomingCallFullscreenPage] doAccept callId=${this.callId}")
        let boundCallId = this.callId
        let boundIsVideo = this.isVideo
        let _ = spawn {
            let svc = getCallService()
            let accepted = svc.acceptCallIfCurrent(boundCallId)
            launch {
                if (!accepted) {
                    routerPop()
                    return
                }
                this.callAction = "done"
                // 替换栈顶 = pop 本页 + push 通话页。
                // ⚠️ 不能用 routerReplace：AppRouter.replace 是 clear()+push 的
                // 「换根」语义（登录切根专用），会把 MainTabPage 等整栈清掉——
                // 挂断后一 pop 即空栈白屏（UI 树实锤 Navigation 无任何 NavDestination）。
                // 也不能只 push：本页残留栈中，挂断后露出（此前实测）。
                routerPop()
                if (boundIsVideo) {
                    routerPush("VideoCallScreen", "")
                } else {
                    routerPush("CallScreen", "")
                }
            }
        }
    }

    // ==================== 拒绝 ====================

    private func doDecline(): Unit {
        if (this.actionLocked) { return }
        if (!this.isBoundRingingCall()) {
            this.actionLocked = true
            this.stopBoundCallWatcher()
            routerPop()
            return
        }
        this.actionLocked = true
        this.stopBoundCallWatcher()
        this.callAction = "declining"
        Hilog.info(0, "CjTelegram", "[IncomingCallFullscreenPage] doDecline callId=${this.callId}")
        let boundCallId = this.callId
        let _ = spawn {
            let svc = getCallService()
            let rejected = svc.rejectCallIfCurrent(boundCallId)
            launch {
                if (!rejected) {
                    routerPop()
                    return
                }
                this.callAction = "done"
                routerPop()
            }
        }
    }

    // ==================== 头像构建器（V2: 136pt 渐变圆 + 首字母 48pt） ====================

    @Builder
    func buildAvatar() {
        Stack(alignContent: Alignment.Center) {
            if (this.callerAvatarPath.size > 0 && !this.callerAvatarFailed) {
                Image(this.callerAvatarPath)
                    .width(136)
                    .height(136)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(68)
                    .onError({ _ => this.callerAvatarFailed = true })
            } else {
                Text(getCallerInitial(this.callerName))
                    .fontSize(48)
                    .fontColor(0xFFFFFF)
                    .fontWeight(FontWeight.Medium)
            }
        }
        .width(136)
        .height(136)
        .borderRadius(68)
        .linearGradient(
            angle: 180.0,
            colors: [
                (Color(getAvatarGradTop(getAvatarColorIdxByName(this.callerName))), 0.0),
                (Color(getAvatarGradBottom(getAvatarColorIdxByName(this.callerName))), 1.0)
            ]
        )
    }

    // ==================== 操作按钮构建器（V1 incoming 几何: 72pt, 间距 115） ====================

    @Builder
    func buildActionButtons() {
        Row {
            // 拒绝（红 0xd92326, 官方 Call/CallDeclineButton PDF）
            Column {
                Stack(alignContent: Alignment.Center) {
                    Image(getCallV2IconRes("decline"))
                        .width(72)
                        .height(72)
                        .fillColor(0xFFFFFF)
                }
                .width(72)
                .height(72)
                .borderRadius(36)
                .backgroundColor(0xD92326)
                .onClick({ _evt => this.doDecline() })

                Text(trSource("Decline"))
                    .fontSize(13)
                    .fontColor(0xFFFFFF)
                    .margin(top: 8)
            }
            .alignItems(HorizontalAlign.Center)

            Blank()
                .width(115)

            // 接听（绿 0x74db58, 官方 Call/CallAcceptButton PDF）
            Column {
                Stack(alignContent: Alignment.Center) {
                    Image(getCallV2IconRes("accept"))
                        .width(72)
                        .height(72)
                        .fillColor(0xFFFFFF)
                }
                .width(72)
                .height(72)
                .borderRadius(36)
                .backgroundColor(0x74DB58)
                .onClick({ _evt => this.doAccept() })

                Text(trSource("Accept"))
                    .fontSize(13)
                    .fontColor(0xFFFFFF)
                    .margin(top: 8)
            }
            .alignItems(HorizontalAlign.Center)
        }
        .justifyContent(FlexAlign.Center)
    }

    // ==================== build ====================
    //
    // V2 风格来电页（对齐 iOS 官方来电布局；平台差异说明保留为注释）：
    // [N-A] HarmonyOS 无 CallKit 级系统/锁屏来电 UI，第三方应用不可达；
    //       应用内全屏来电页为本平台最佳替代（原 UI 上的 INTEROP NOTE 卡片移除，
    //       该说明不属于 iOS 官方来电界面元素）。
    // 布局: 渐变(等待态 blue-violet) + 头像 136(≈0.49H 规则, 上下权重 1:1) +
    //       名字 28 + "Telegram Audio/Video Call" 16 + 底部 Decline/Accept 72pt 排

    public func build() {
        Column {
            Blank()
                .layoutWeight(1)

            // 头像
            this.buildAvatar()

            // 来电方名称（头像底 +39）
            Text(this.callerName)
                .fontSize(28)
                .fontColor(0xFFFFFF)
                .fontWeight(FontWeight.Regular)
                .margin(top: 39)

            // 状态行（名字底 +4）: 来电类型 / 接听中 / 拒接中
            Text(if (this.callAction == "ringing") { getIncomingCallTypeText(this.isVideo) }
                 else if (this.callAction == "accepting") { "Connecting..." }
                 else if (this.callAction == "declining") { "Ending..." }
                 else { "" })
                .fontSize(16)
                .fontColor(0xFFFFFF)
                .margin(top: 4)

            Blank()
                .layoutWeight(1)

            // 操作按钮
            this.buildActionButtons()

            Blank()
                .height(36)
        }
        .width(100.percent)
        .height(100.percent)
        .linearGradient(
            angle: 160.0,
            colors: [
                (Color(getCallV2BgColor(0, 0)), 0.0),
                (Color(getCallV2BgColor(0, 1)), 0.35),
                (Color(getCallV2BgColor(0, 2)), 0.70),
                (Color(getCallV2BgColor(0, 3)), 1.0)
            ]
        )
        .alignItems(HorizontalAlign.Center)
        .onAppear({ => this.handleAppear() })
        .onDisAppear({ => this.stopBoundCallWatcher() })
    }
}
