package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getTelegramVoipService, getCallService}
import ohos_app_cangjie_entry.router.*

/**
 * TelegramVoipPage — VoIP 配置/诊断页面 (telegram_voip)（混合工程迁移版）
 *
 * 非通话页面（通话页面已有 CallScreen.cj / VideoCallScreen.cj）。
 * 用于展示 VoIP 引擎状态、获取通话配置、诊断信息。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - pageStack.pop() → routerPop()
 *  - 源无 NavDestination 包裹，根为 Column
 *  - aboutToAppear 有实逻辑 → ensureLoaded()+.onAppear
 */
@HybridComponentEntry
@Component
public class TelegramVoipPage {
    @State var webrtcStatus: String = "Checking..."
    @State var versionsText: String = ""
    @State var callConfigJson: String = ""
    @State var isLoadingConfig: Bool = false
    @State var statusMessage: String = ""
    @State var canSaveDebug: Bool = false
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.refreshStatus()
    }

    private func refreshStatus(): Unit {
        let svc = getTelegramVoipService()
        let supported = svc.getWebrtcStatus()
        this.webrtcStatus = if (supported) { "Available" } else { "Not available" }
        let vers = svc.fetchRecommendedVersions()
        this.versionsText = this.joinVersions(vers)
        this.updateCanSaveDebug()
    }

    private func joinVersions(vers: Array<String>): String {
        if (vers.size == 0) { return "—" }
        var out: String = ""
        var i: Int64 = 0
        while (i < vers.size) {
            if (i > 0) { out = out + ", " }
            out = out + vers[i]
            i = i + 1
        }
        return out
    }

    private func updateCanSaveDebug(): Unit {
        let callSvc = getCallService()
        match (callSvc.getCurrentCall()) {
            case Some(call) =>
                this.canSaveDebug = call.state == "active" && call.callId > 0 && call.accessHash != 0
            case None =>
                this.canSaveDebug = false
        }
    }

    private func doFetchConfig(): Unit {
        if (this.isLoadingConfig) { return }
        this.isLoadingConfig = true
        this.statusMessage = ""
        let _ = spawn {
            let svc = getTelegramVoipService()
            match (svc.getCallConfig()) {
                case Some(json) =>
                    launch {
                        this.callConfigJson = json
                        this.statusMessage = "Config loaded"
                        this.isLoadingConfig = false
                    }
                case None =>
                    launch {
                        this.callConfigJson = ""
                        this.statusMessage = "Failed to load config"
                        this.isLoadingConfig = false
                    }
            }
        }
    }

    private func doSaveDebug(): Unit {
        let callSvc = getCallService()
        match (callSvc.getCurrentCall()) {
            case Some(call) =>
                if (call.state != "active" || call.callId <= 0 || call.accessHash == 0) {
                    this.statusMessage = "No active call"
                    return
                }
                let voipSvc = getTelegramVoipService()
                let debugJson = "{\"signal_bars\":${call.signalBars},\"state\":\"${call.state}\"}"
                let _ = spawn {
                    let ok = voipSvc.saveCallDebug(call.callId, call.accessHash, debugJson)
                    launch {
                        this.statusMessage = if (ok) { "Debug saved" } else { "Save failed" }
                        this.updateCanSaveDebug()
                    }
                }
            case None =>
                this.statusMessage = "No active call"
        }
    }

    func build() {
        Column {
            // 标题栏
            Row {
                Text("‹")
                    .fontSize(24)
                    .fontColor(0x007AFF)
                    .onClick({ _ =>
                        routerPop()
                    })
                Text("Telegram VoIP")
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                Blank()
                    .width(24)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)

            Scroll() {
                Column {
                    // WebRTC 状态
                    Column {
                        Text("WebRTC Engine")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .margin(bottom: 4)
                        Text(this.webrtcStatus)
                            .fontSize(17)
                            .fontColor(0x000000)
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Start)
                    .padding(16)

                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16, right: 16)

                    // 推荐版本
                    Column {
                        Text("Recommended Versions")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .margin(bottom: 4)
                        Text(this.versionsText)
                            .fontSize(17)
                            .fontColor(0x000000)
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Start)
                    .padding(16)

                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16, right: 16)

                    // 获取配置按钮
                    Row {
                        Text("Get Call Config")
                            .fontSize(17)
                            .fontColor(0x007AFF)
                            .layoutWeight(1)
                        if (this.isLoadingConfig) {
                            Text("...")
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                        }
                    }
                    .width(100.percent)
                    .height(44)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ =>
                        this.doFetchConfig()
                    })

                    if (this.callConfigJson.size > 0) {
                        Column {
                            Text(this.callConfigJson)
                                .fontSize(12)
                                .fontColor(0x666666)
                                .maxLines(10)
                        }
                        .width(100.percent)
                        .alignItems(HorizontalAlign.Start)
                        .padding(16)
                    }

                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16, right: 16)

                    // 保存调试按钮
                    Row {
                        Text("Save Call Debug")
                            .fontSize(17)
                            .fontColor(if (this.canSaveDebug) { 0x007AFF } else { 0xC7C7CC })
                            .layoutWeight(1)
                    }
                    .width(100.percent)
                    .height(44)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ =>
                        this.doSaveDebug()
                    })

                    if (this.statusMessage.size > 0) {
                        Text(this.statusMessage)
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .margin(top: 12)
                    }
                }
                .width(100.percent)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }
}
