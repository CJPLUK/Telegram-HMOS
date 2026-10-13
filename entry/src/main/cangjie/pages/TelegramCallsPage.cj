package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getTelegramCallsService, GroupCallInfo}
import ohos_app_cangjie_entry.router.*

/**
 * TelegramCallsPage — 群组语音/视频聊天加入界面 (TelegramCallsUI)（混合工程迁移版）
 *
 * 对应 iOS VoiceChatJoinScreen.swift
 * 用于展示群组通话信息并加入群组语音聊天。
 * 非 1:1 通话页面（那是 CallScreen.cj / VideoCallScreen.cj）。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - pushPathByName → routerPush；pop() → routerPop()
 *  - 源无 NavDestination 包裹，根为 Column，无 aboutToAppear，直接保留
 */
@HybridComponentEntry
@Component
public class TelegramCallsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var callIdInput: String = ""
    @State var accessHashInput: String = ""
    @State var isLoading: Bool = false
    @State var groupCallInfo: Option<GroupCallInfo> = None<GroupCallInfo>
    @State var groupCallLoaded: Bool = false
    @State var errorMessage: String = ""
    @State var participantCount: Int32 = 0

    private func doLoadGroupCall(): Unit {
        let callIdStr = this.callIdInput
        let accessHashStr = this.accessHashInput
        if (callIdStr.size == 0 || accessHashStr.size == 0) {
            this.errorMessage = "Enter call ID and access hash"
            return
        }
        this.isLoading = true
        this.errorMessage = ""
        this.groupCallInfo = None
        this.groupCallLoaded = false
        let _ = spawn {
            let svc = getTelegramCallsService()
            let callId = this.parseCallId(callIdStr)
            let accessHash = this.parseAccessHash(accessHashStr)
            match (svc.getGroupCallForJoinScreen(callId, accessHash)) {
                case Some(info) =>
                    launch {
                        this.groupCallInfo = Some(info)
                        this.groupCallLoaded = true
                        this.participantCount = info.participantCount
                        this.isLoading = false
                        this.errorMessage = ""
                    }
                case None =>
                    launch {
                        this.groupCallInfo = None
                        this.groupCallLoaded = false
                        this.isLoading = false
                        this.errorMessage = "Failed to load group call"
                    }
            }
        }
    }

    private func parseCallId(s: String): Int64 {
        if (s.size == 0) { return 0 }
        var result: Int64 = 0
        let runes = s.toRuneArray()
        var i: Int64 = 0
        while (i < Int64(runes.size)) {
            let code = UInt32(runes[i])
            if (code >= 48 && code <= 57) {
                result = result * 10 + (Int64(code) - 48)
            }
            i = i + 1
        }
        return result
    }

    private func parseAccessHash(s: String): Int64 {
        if (s.size == 0) { return 0 }
        var result: Int64 = 0
        let runes = s.toRuneArray()
        var i: Int64 = 0
        let neg = runes.size > 0 && UInt32(runes[0]) == 45
        if (neg) { i = 1 }
        while (i < Int64(runes.size)) {
            let code = UInt32(runes[i])
            if (code >= 48 && code <= 57) {
                result = result * 10 + (Int64(code) - 48)
            }
            i = i + 1
        }
        return if (neg) { -result } else { result }
    }

    private func doJoinGroupCall(): Unit {
        match (this.groupCallInfo) {
            case Some(info) =>
                Hilog.info(0, "CjTelegram", "[TelegramCallsPage] Join group call id=${info.callId} — navigate GroupCallScreen")
                // P2-061: 导航到真实的群通话界面 (GroupCallScreen)
                // 参数格式: "{callId}:{accessHash}:{title}"
                let param = "${info.callId}:${info.accessHash}:"
                routerPush("GroupCallScreen", param)
            case None =>
                this.errorMessage = "Load group call first"
        }
    }

    private func doCancel(): Unit {
        routerPop()
    }

    func build() {
        Column {
            Row {
                Text("‹")
                    .fontSize(24)
                    .fontColor(0x007AFF)
                    .onClick({ _ =>
                        routerPop()
                    })
                Text("Group Voice Chat")
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

            Scroll {
                Column {
                    Text("Join a group call from a chat, or enter call details:")
                        .fontSize(14)
                        .fontColor(0x666666)
                        .margin(bottom: 16)

                    Row {
                        Text("Call ID:")
                            .fontSize(14)
                            .width(80)
                        TextInput(text: this.callIdInput, placeholder: "e.g. 12345")
                            .fontSize(14)
                            .layoutWeight(1)
                            .onChange({ value: String => this.callIdInput = value })
                    }
                    .width(100.percent)
                    .margin(bottom: 12)

                    Row {
                        Text("Access Hash:")
                            .fontSize(14)
                            .width(80)
                        TextInput(text: this.accessHashInput, placeholder: "e.g. 67890")
                            .fontSize(14)
                            .layoutWeight(1)
                            .onChange({ value: String => this.accessHashInput = value })
                    }
                    .width(100.percent)
                    .margin(bottom: 20)

                    Row {
                        Button("Load")
                            .fontSize(16)
                            .backgroundColor(0x317AFF)
                            .fontColor(0xFFFFFF)
                            .onClick({ _ =>
                                this.doLoadGroupCall()
                            })
                        Blank()
                            .width(16)
                        Button(trSource("Cancel"))
                            .fontSize(16)
                            .backgroundColor(0xE5E5EA)
                            .fontColor(0x000000)
                            .onClick({ _ =>
                                this.doCancel()
                            })
                    }
                    .width(100.percent)
                    .margin(bottom: 16)

                    if (this.isLoading) {
                        Text(trSource("Loading..."))
                            .fontSize(14)
                            .fontColor(0x999999)
                            .margin(bottom: 12)
                    }

                    if (this.errorMessage.size > 0) {
                        Text(this.errorMessage)
                            .fontSize(14)
                            .fontColor(0xFF3B30)
                            .margin(bottom: 12)
                    }

                    if (this.groupCallLoaded) {
                        Column {
                            Text("Participants: ${this.participantCount}")
                                .fontSize(16)
                                .margin(bottom: 12)
                            Button(trSource("Join"))
                                .fontSize(16)
                                .backgroundColor(0x34C759)
                                .fontColor(0xFFFFFF)
                                .onClick({ _ =>
                                    this.doJoinGroupCall()
                                })
                        }
                        .width(100.percent)
                    }
                }
                .width(100.percent)
                .padding(24)
                .alignItems(HorizontalAlign.Start)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
    }
}
