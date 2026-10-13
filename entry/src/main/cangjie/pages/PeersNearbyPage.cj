package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.{getCurrentDeviceLocation, setSelectedChat}
import ohos_app_cangjie_entry.providers.getPeersNearbyDataProvider
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * 附近的人主页面 (PNEAR-UI-3)（混合工程迁移版）
 *
 * 对应 iOS PeersNearbyController
 * 功能:
 * - 三个 section: Users Nearby / Groups Nearby / Channels Nearby
 * - 距离显示 (meters/km)
 * - "Make Myself Visible" 开关
 * - "Create Group" 按钮
 * - 自动刷新位置
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()；pushPathByName → routerPush
 *  - aboutToAppear 有实逻辑（loadLocationAndRefresh）→ ensureLoaded()+.onAppear
 */
@HybridComponentEntry
@Component
public class PeersNearbyPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var nearbyUsers: ArrayList<PeerNearbyEntry> = ArrayList<PeerNearbyEntry>()
    @State var nearbyGroups: ArrayList<PeerNearbyEntry> = ArrayList<PeerNearbyEntry>()
    @State var nearbyChannels: ArrayList<PeerNearbyEntry> = ArrayList<PeerNearbyEntry>()
    @State var selfExpires: Int32 = 0
    @State var isLoading: Bool = false
    @State var lat: Float64 = 0.0
    @State var lng: Float64 = 0.0
    @State var isVisible: Bool = false
    @State var errorText: String = ""
    @State var loaded: Bool = false

    private let provider = getPeersNearbyDataProvider()

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadLocationAndRefresh()
    }

    private func loadLocationAndRefresh(): Unit {
        this.isLoading = true
        this.errorText = ""
        let _ = spawn {
            let locResult = getCurrentDeviceLocation()
            launch {
                if (locResult.success) {
                    this.lat = locResult.latitude
                    this.lng = locResult.longitude
                    this.doRefresh()
                } else {
                    this.errorText = if (locResult.errorMessage.size > 0) { locResult.errorMessage } else { "Location unavailable" }
                    this.isLoading = false
                }
            }
        }
    }

    private func doRefresh(): Unit {
        let _ = spawn {
            let result = this.provider.loadNearby(this.lat, this.lng)
            launch {
                this.nearbyUsers = result.nearbyUsers
                this.nearbyGroups = result.nearbyGroups
                this.nearbyChannels = result.nearbyChannels
                this.selfExpires = result.selfExpires
                this.isVisible = result.selfExpires > 0
                this.isLoading = false
            }
        }
    }

    private func formatDistance(meters: Int32): String {
        if (meters < 1000) {
            return "${meters} m"
        }
        let km = Float64(meters) / 1000.0
        return "${km} km"
    }

    private func applyVisibility(visible: Bool): Unit {
        if (visible) {
            this.doRefresh()
        } else {
            Hilog.info(0, "CjTelegram", "[PeersNearbyPage] Make invisible (deferred: needs contacts.updateLocated)")
        }
    }

    private func openChat(entry: PeerNearbyEntry): Unit {
        setSelectedChat(entry.peerId, entry.displayName, entry.peerType)
        routerPush("ChatRoomPage", entry.displayName)
    }

    private func openProfile(entry: PeerNearbyEntry): Unit {
        setSelectedChat(entry.peerId, entry.displayName, entry.peerType)
        routerPush("UserProfilePage", "")
    }

    private func openCreateGroup(): Unit {
        routerPush("CreateGroupPage", "")
    }

    @Builder
    private func buildPeerRow(entry: PeerNearbyEntry, isUser: Bool) {
        ListItem {
            Row {
                Column {
                    Text(entry.displayName)
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0x000000)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                    Text(this.formatDistance(entry.distance))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt =>
                if (isUser) {
                    this.openProfile(entry)
                } else {
                    this.openChat(entry)
                }
            })
        }
    }

    public func build() {
        Column {
            Row {
                Text("← Back")
                    .fontSize(17)
                    .fontColor(0x317AFF)
                    .onClick({ _evt => routerPop() })
                Blank().layoutWeight(1)
                Text(trSource("People Nearby"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                Blank().layoutWeight(1)
                Text("↻")
                    .fontSize(20)
                    .fontColor(0x317AFF)
                    .onClick({ _evt => this.loadLocationAndRefresh() })
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xF7F7F7)
            .alignItems(VerticalAlign.Center)

            Divider().color(0xE5E5EA).strokeWidth(0.5)

            if (this.isLoading) {
                Column {
                    LoadingProgress().width(32).height(32).color(0x317AFF)
                    Text(trSource("Loading...")).fontSize(14).fontColor(0x999999).margin(top: 8)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.errorText.size > 0) {
                Column {
                    Text(this.errorText).fontSize(16).fontColor(0xFF3B30)
                    Text("Tap to retry").fontSize(14).fontColor(0x317AFF).margin(top: 8)
                        .onClick({ _evt => this.loadLocationAndRefresh() })
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                List {
                    ListItem {
                        Text("Discover people and groups near you.")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(16)
                    }

                    ListItem {
                        Row {
                            Text(if (this.isVisible) { "Make Invisible" } else { "Make Myself Visible" })
                                .fontSize(17)
                                .fontColor(if (this.isVisible) { 0xFF3B30 } else { 0x317AFF })
                            Blank().layoutWeight(1)
                            Toggle(ToggleType.Switch, isOn: this.isVisible)
                                .onChange({ value: Bool =>
                                    this.isVisible = value
                                    this.applyVisibility(value)
                                })
                        }
                        .width(100.percent)
                        .height(52)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                    }

                    ListItem {
                        Text("USERS NEARBY")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .fontWeight(FontWeight.Medium)
                            .width(100.percent)
                            .padding(left: 16, top: 12, bottom: 4)
                            .backgroundColor(0xF2F2F7)
                    }
                    ForEach(this.nearbyUsers, itemGenerator: { entry: PeerNearbyEntry, _idx: Int64 =>
                        this.buildPeerRow(entry, true)
                    })

                    ListItem {
                        Text("GROUPS NEARBY")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .fontWeight(FontWeight.Medium)
                            .width(100.percent)
                            .padding(left: 16, top: 12, bottom: 4)
                            .backgroundColor(0xF2F2F7)
                    }
                    ListItem {
                        Row {
                            Text("Create Group")
                                .fontSize(17)
                                .fontColor(0x317AFF)
                        }
                        .width(100.percent)
                        .height(52)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _evt => this.openCreateGroup() })
                    }
                    ForEach(this.nearbyGroups, itemGenerator: { entry: PeerNearbyEntry, _idx: Int64 =>
                        this.buildPeerRow(entry, false)
                    })

                    ListItem {
                        Text("CHANNELS NEARBY")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .fontWeight(FontWeight.Medium)
                            .width(100.percent)
                            .padding(left: 16, top: 12, bottom: 4)
                            .backgroundColor(0xF2F2F7)
                    }
                    ForEach(this.nearbyChannels, itemGenerator: { entry: PeerNearbyEntry, _idx: Int64 =>
                        this.buildPeerRow(entry, false)
                    })
                }
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(0xFFFFFF)
                .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xE5E5EA, startMargin: 16, endMargin: 0))
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
