package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getTelegramUpdateService}
import ohos_app_cangjie_entry.core.mtproto.HelpAppUpdateResponse

/**
 * UpdatePromptComponent — 应用更新提示横幅/对话框
 *
 * 当检测到应用有新版本时显示更新提示。
 * 对应 iOS TelegramUpdateUI/UpdateInfoController。
 *
 * TL: help.getAppUpdate
 *
 * Usage: 嵌入 Settings 等页面，onDismiss/onOpenStore 回调。
 */
@Component
public class UpdatePromptComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var onDismiss: () -> Unit = { => }
    public var onOpenStore: (String) -> Unit = { _: String => }

    @State var version: String = ""
    @State var text: String = ""
    @State var url: String = ""
    @State var blocking: Bool = false
    @State var isLoading: Bool = true
    @State var hasUpdate: Bool = false

    protected override func aboutToAppear(): Unit {
        this.loadUpdateInfo()
    }

    private func loadUpdateInfo(): Unit {
        this.isLoading = true
        this.hasUpdate = false
        this.version = ""
        this.text = ""
        this.url = ""
        this.blocking = false
        spawn {
            let service = getTelegramUpdateService()
            let result = service.checkForUpdate("settings")
            launch {
                this.isLoading = false
                this.hasUpdate = result.hasUpdate
                this.version = result.version
                this.text = result.text
                this.url = result.url
                this.blocking = result.blocking
                if (result.hasUpdate) {
                    Hilog.info(0, "CjTelegram", "[UpdatePrompt] Update available: ${result.version}")
                }
            }
        }
    }

    private func handleUpdate(): Unit {
        let storeUrl = if (this.url.size > 0) { this.url } else { "https://t.me/telegram" }
        this.onOpenStore(storeUrl)
    }

    private func handleSkip(): Unit {
        if (!this.blocking) {
            this.onDismiss()
        }
    }

    private func getVersionTitle(): String {
        if (this.version.size > 0) {
            return "Version " + this.version
        }
        return "Update Available"
    }

    public func build() {
        if (this.isLoading) {
            Column { }
        } else if (this.hasUpdate) {
            Column {
                Row {
                    Column {
                        Text("📦")
                            .fontSize(16)
                    }
                    .width(40)
                    .height(40)
                    .borderRadius(8)
                    .backgroundColor(0x34C759)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .margin(right: 12)

                    Column {
                        Text(this.getVersionTitle())
                            .fontSize(16)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                        if (this.text.size > 0) {
                            Text(this.text)
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .maxLines(2)
                                .textOverflow(TextOverflow.Ellipsis)
                                .margin(top: 2)
                        }
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Row {
                        if (!this.blocking) {
                            Text(trSource("Skip"))
                                .fontSize(15)
                                .fontColor(0x8E8E93)
                                .onClick({ evt => this.handleSkip() })
                            Text(trSource("Update"))
                                .fontSize(15)
                                .fontColor(0x317AFF)
                                .fontWeight(FontWeight.Medium)
                                .margin(left: 16)
                                .onClick({ evt => this.handleUpdate() })
                        } else {
                            Text(trSource("Update"))
                                .fontSize(15)
                                .fontColor(0x317AFF)
                                .fontWeight(FontWeight.Medium)
                                .onClick({ evt => this.handleUpdate() })
                        }
                    }
                }
                .width(100.percent)
                .padding(16)
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .alignItems(VerticalAlign.Center)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 8, bottom: 8)
        } else {
            Column { }
        }
    }
}
