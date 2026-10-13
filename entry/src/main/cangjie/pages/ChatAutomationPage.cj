package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.routerPop
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

@HybridComponentEntry
@Component
public class ChatAutomationPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var username: String = ""
    @State var resolving: Bool = false
    @State var connected: Bool = false
    @State var connectedName: String = ""
    @State var status: String = ""
    @State var replyMessages: Bool = true
    @State var readMessages: Bool = true
    @State var accessMode: Int32 = 0

    private func connectBot(): Unit {
        if (this.resolving || this.username.size == 0) { return }
        this.resolving = true
        this.status = "Searching..."
        let cleanName = this.username.replace("@", "")
        let _ = spawn {
            match (getRealContactService().resolveUsername(cleanName)) {
                case Some(peer) =>
                    let config = ConnectedBotData()
                    config.botUserId = peer.userId
                    config.botAccessHash = peer.accessHash
                    var flags: Int32 = 0
                    if (this.replyMessages) { flags = flags | 1 }
                    if (this.readMessages) { flags = flags | 2 }
                    config.rightFlags = flags
                    let allowAll = this.accessMode == 0
                    config.recipients.existingChats = allowAll
                    config.recipients.newChats = allowAll
                    config.recipients.contacts = allowAll
                    config.recipients.nonContacts = allowAll
                    let ok = getSettingsService().updateConnectedBot(Some(config))
                    launch {
                        this.resolving = false
                        if (ok) {
                            this.connected = true
                            this.connectedName = peer.getDisplayName()
                            this.status = "Connected"
                        } else {
                            this.status = "Could not connect this bot."
                        }
                    }
                case None =>
                    launch { this.resolving = false; this.status = "Bot not found." }
            }
        }
    }

    private func disconnectBot(): Unit {
        if (this.resolving) { return }
        this.resolving = true
        let _ = spawn {
            let ok = getSettingsService().updateConnectedBot(Option<ConnectedBotData>.None)
            launch {
                this.resolving = false
                if (ok) { this.connected = false; this.connectedName = ""; this.status = "Disconnected" }
                else { this.status = "Could not disconnect the bot." }
            }
        }
    }

    public func build() {
        Column {
            Row {
                Text("‹").fontSize(36).fontColor(0x000000).width(52).height(52)
                    .borderRadius(26).backgroundColor(0xFFFFFF).textAlign(TextAlign.Center)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
            }.width(100.percent).height(56.0 + getSafeAreaTop()).padding(left: 12, right: 12, top: getSafeAreaTop()).backgroundColor(0xF2F2F7)
                .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    Image(@r(app.media.chat_automation_illustration))
                        .width(140).height(140).margin(top: -50)
                    Text(trSource("Chat Automation"))
                        .fontSize(28).fontWeight(FontWeight.Bold).margin(top: 8)
                    Text("Add a bot to reply to\nmessages on your behalf.")
                        .fontSize(19).fontColor(0x000000).textAlign(TextAlign.Center)
                        .margin(left: 28, right: 28, top: 10, bottom: 24)
                    if (this.connected) {
                        Column {
                            Text("✓").fontSize(34).fontColor(0x34C759)
                            Text(this.connectedName).fontSize(18).fontWeight(FontWeight.Medium).margin(top: 8)
                            Text("This bot can manage the chats selected below.")
                                .fontSize(13).fontColor(0x8E8E93).margin(top: 5)
                        }.width(100.percent).padding(top: 18, bottom: 18).backgroundColor(0xFFFFFF)
                            .alignItems(HorizontalAlign.Center)
                    } else {
                        Column {
                            TextInput(text: this.username, placeholder: "Bot Username or Link")
                                .height(52).backgroundColor(Color.Transparent).fontSize(18)
                                .padding(left: 16, right: 16)
                                .onChange({ value: String => this.username = value; this.status = "" })
                                .enterKeyType(EnterKeyType.Go)
                                .onSubmit({ _key: EnterKeyType => this.connectBot() })
                        }.backgroundColor(0xFFFFFF).borderRadius(26).margin(left: 16, right: 16)
                    }

                    Text("Choose a bot to manage your chats automatically.")
                        .fontSize(14).fontColor(0x77777C).width(100.percent)
                        .margin(left: 32, right: 24, top: 9)
                    Text("CHATS THE BOT CAN ACCESS").fontSize(14).fontColor(0x77777C)
                        .width(100.percent).margin(left: 32, top: 28, bottom: 8)
                    Column {
                        Row {
                            Text(if (this.accessMode == 0) { "✓" } else { "" })
                                .fontSize(22).fontColor(0x0A84FF).width(40).textAlign(TextAlign.Center)
                            Text("All Private Chats Except...").fontSize(18).layoutWeight(1)
                        }.height(52).padding(right: 16).alignItems(VerticalAlign.Center)
                            .onClick({ _ => this.accessMode = 0 })
                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                        Row {
                            Text(if (this.accessMode == 1) { "✓" } else { "" })
                                .fontSize(22).fontColor(0x0A84FF).width(40).textAlign(TextAlign.Center)
                            Text(trSource("Only Selected Chats")).fontSize(18).layoutWeight(1)
                        }.height(52).padding(right: 16).alignItems(VerticalAlign.Center)
                            .onClick({ _ => this.accessMode = 1 })
                    }.backgroundColor(0xFFFFFF).borderRadius(18).clip(true).margin(left: 16, right: 16)

                    Row {
                        Text(if (this.accessMode == 0) { "Excluded Chats" } else { "Included Chats" })
                            .fontSize(18).layoutWeight(1)
                        Text(trSource("Add")).fontSize(18).fontColor(0x9A9A9F)
                        Text("›").fontSize(30).fontColor(0xB8B8BD).margin(left: 8)
                    }.width(100.percent).height(52).padding(left: 16, right: 14)
                        .alignItems(VerticalAlign.Center).backgroundColor(0xFFFFFF).borderRadius(26)
                        .margin(left: 16, right: 16, top: 34)
                    Text(if (this.accessMode == 0) {
                        "Select chats or entire chat categories which the bot WILL NOT have access to."
                    } else {
                        "Select chats or entire chat categories which the bot WILL have access to."
                    }).fontSize(14).fontColor(0x77777C).width(100.percent)
                        .margin(left: 32, right: 24, top: 9)

                    if (this.status.size > 0) {
                        Text(this.status).fontSize(13)
                            .fontColor(if (this.connected) { 0x34C759 } else { 0x8E8E93 })
                            .margin(left: 32, right: 24, top: 8).width(100.percent)
                    }
                    if (this.resolving) {
                        LoadingProgress().width(24).height(24).color(0x317AFF).margin(top: 22)
                    } else if (this.connected) {
                        Text("Disconnect Bot").fontSize(17).fontColor(0xFF3B30)
                            .width(100.percent).height(48).textAlign(TextAlign.Center)
                            .backgroundColor(0xFFFFFF).borderRadius(10)
                            .margin(left: 16, right: 16, top: 24)
                            .onClick({ _ => this.disconnectBot() })
                    } else if (this.username.size > 0) {
                        Text("Connect Bot").fontSize(17).fontWeight(FontWeight.Medium).fontColor(0xFFFFFF)
                            .width(100.percent).height(48).textAlign(TextAlign.Center)
                            .backgroundColor(0x317AFF).borderRadius(10)
                            .margin(left: 16, right: 16, top: 24)
                            .onClick({ _ => this.connectBot() })
                    }
                }.width(100.percent)
            }.layoutWeight(1).backgroundColor(0xF2F2F7)
        }.width(100.percent).height(100.percent).backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
    }
}
