package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import ohos_app_cangjie_entry.services.getNotificationsPresentationDataService

/**
 * NotificationsPresentationDataComponent — 通知预览组件
 *
 * 展示通知样式预览，调用 NotificationsPresentationDataService 获取/格式化数据
 * 用于通知设置页面的预览区域
 */
@Component
public class NotificationsPresentationDataComponent {
    @State var previewTitle: String = "Telegram"
    @State var previewBody: String = "New message"
    @State var isLoading: Bool = true

    public var peerName: String = "Alice"
    public var messageText: String = "Hello! How are you?"
    public var peerType: String = "users"

    public func aboutToAppear(): Unit {
        this.loadPreview()
    }

    private func loadPreview(): Unit {
        let _ = spawn {
            let svc = getNotificationsPresentationDataService()
            let settings = svc.getNotifySettings(this.peerType)
            let title = svc.formatNotificationTitle(this.peerName, "")
            let body = svc.formatNotificationBody(this.peerName, this.messageText, settings.showPreviews)
            launch {
                this.previewTitle = title
                this.previewBody = body
                this.isLoading = false
            }
        }
    }

    private func getPreviewTitle(): String {
        return this.previewTitle
    }

    private func getPreviewBody(): String {
        return this.previewBody
    }

    private func getIsLoading(): Bool {
        return this.isLoading
    }

    func build() {
        Column {
            if (this.getIsLoading()) {
                Text("Loading preview...")
                    .fontSize(14)
                    .fontColor(0x8E8E93)
            } else {
                Column {
                    Row {
                        Column {}
                            .width(40)
                            .height(40)
                            .borderRadius(20)
                            .backgroundColor(0x34C759)
                        Column {
                            Text(this.getPreviewTitle())
                                .fontSize(16)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0x000000)
                            Text(this.getPreviewBody())
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                                .margin(top: 4)
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)
                        .margin(left: 12)
                    }
                    .width(100.percent)
                    .padding(16)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                }
                .width(100.percent)
            }
        }
        .width(100.percent)
    }
}
