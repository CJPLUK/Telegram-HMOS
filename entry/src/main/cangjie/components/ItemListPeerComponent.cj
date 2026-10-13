package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import std.sync.*

/**
 * 用户列表项组件 (ItemListPeerItem)
 *
 * 通用 peer 行组件，用于联系人列表、群成员、搜索结果等场景。
 * 调用 ItemListPeerService 获取/解析 peer 数据，非 mock/stub。
 *
 * 布局:
 * ┌───────────────────────────────────────────────────────┐
 * │ [头像]  显示名称                           [状态]     │
 * │         状态文本 (online / last seen...)              │
 * └───────────────────────────────────────────────────────┘
 */
@Component
public class ItemListPeerComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    var peerData: PeerDisplayData = PeerDisplayData()

    var usernameToResolve: String = ""

    @State var displayName: String = ""
    @State var displayAvatarUrl: String = ""
    @State var displayStatusText: String = ""
    @State var displayIsOnline: Bool = false
    @State var displayPeerType: String = "user"
    @State var hasData: Bool = false
    @State var isLoading: Bool = false
    @State var loadFailed: Bool = false

    @State var touchDownTime: Int64 = 0

    public var onClick: () -> Unit = { => }
    public var onLongPress: () -> Unit = { => }

    public override func aboutToAppear(): Unit {
        if (this.peerData.peerId != 0 || this.peerData.displayName.size > 0) {
            this.syncDisplayFromData(this.peerData)
        } else if (this.usernameToResolve.size > 0) {
            this.loadPeerByUsername()
        }
    }

    private func syncDisplayFromData(data: PeerDisplayData): Unit {
        this.displayName = data.displayName
        this.displayAvatarUrl = data.avatarLocalPath
        this.displayStatusText = data.statusText
        this.displayIsOnline = data.isOnline
        this.displayPeerType = data.peerType
        this.hasData = true
    }

    private func loadPeerByUsername(): Unit {
        if (this.usernameToResolve.isEmpty()) {
            return
        }
        this.isLoading = true
        this.loadFailed = false
        let usernameCopy = this.usernameToResolve
        let _ = spawn {
            let service = getItemListPeerService()
            let result = service.resolvePeerByUsername(usernameCopy)
            launch {
                this.isLoading = false
                match (result) {
                    case Some(d) =>
                        this.syncDisplayFromData(d)
                    case None =>
                        this.loadFailed = true
                }
            }
        }
    }

    public func build() {
        Column {
            if (this.hasData) {
                Row {
                    Avatar(
                        avatarUrl: this.displayAvatarUrl,
                        displayName: this.displayName,
                        avatarSize: 48,
                        avatarColor: 0x317AFF,
                        isOnline: this.displayIsOnline && this.displayPeerType == "user",
                        showOnlineIndicator: this.displayPeerType == "user"
                    )

                    Column {
                        Row {
                            Text(this.displayName)
                                .fontSize(16)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0x000000)
                                .maxLines(1)
                                .textOverflow(TextOverflow.Ellipsis)
                                .layoutWeight(1)
                        }
                        .width(100.percent)

                        if (this.displayStatusText.size > 0 && this.displayPeerType == "user") {
                            Text(this.displayStatusText)
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(top: 2)
                                .maxLines(1)
                                .textOverflow(TextOverflow.Ellipsis)
                                .width(100.percent)
                        }
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    .margin(left: 12)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 10, bottom: 10)
                .backgroundColor(0xFFFFFF)
                .onClick({ _evt =>
                    this.onClick()
                })
                .onTouch({ evt =>
                    match (evt.eventType) {
                        case TouchType.Down =>
                            this.touchDownTime = evt.timestamp
                        case TouchType.Up =>
                            let duration = evt.timestamp - this.touchDownTime
                            if (duration > 500_000_000) {
                                this.onLongPress()
                            }
                            this.touchDownTime = 0
                        case _ => ()
                    }
                })
            } else if (this.isLoading) {
                        Row {
                            Column {}
                                .width(48)
                                .height(48)
                                .borderRadius(24)
                                .backgroundColor(0xE5E5EA)
                            Text(trSource("Loading..."))
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                                .margin(left: 12)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 10, bottom: 10)
                    } else if (this.loadFailed) {
                        Row {
                            Column {}
                                .width(48)
                                .height(48)
                                .borderRadius(24)
                                .backgroundColor(0xE5E5EA)
                            Text("Not found")
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                                .margin(left: 12)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 10, bottom: 10)
                    } else if (this.usernameToResolve.size > 0) {
                        Row {
                            Text("Resolving...")
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .padding(16)
                    } else {
                        Row {
                            Text("No peer data")
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .padding(16)
                    }
        }
        .width(100.percent)
    }
}
