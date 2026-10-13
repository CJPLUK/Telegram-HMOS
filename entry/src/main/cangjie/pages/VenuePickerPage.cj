package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

import ohos_app_cangjie_entry.services.{
    VenueItemData,
    getVenueSearchService,
    getSunriseSunsetService,
    sendLocationMessage,
    ensureLocationPermission,
    getCurrentDeviceLocation
}
import ohos_app_cangjie_entry.components.SearchBar
import ohos_app_cangjie_entry.router.*

/**
 * VenuePickerPage — 附近 Venue 搜索与选择页面 (P2-184)（混合工程迁移版）
 *
 * iOS 对应:
 *   LocationSearchContainerNode.swift — venue 搜索 + 列表
 *   ItemListVenueItem.swift — venue 行 (标题/地址/类别图标)
 *
 * 功能:
 *   - 搜索框输入关键词，防抖 debounce (500ms via 计数器)
 *   - 调用 VenueSearchService.searchVenues(lat, lng, query)
 *   - 点击 venue → 发送位置消息 (sendLocationMessage)
 *   - 日出日落判定 (SunriseSunsetService.isDaytime) 影响背景色
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑（定位 + 昼夜判定）→ ensureLoaded() + .onAppear
 */
@HybridComponentEntry
@Component
public class VenuePickerPage {
    // 当前 GPS 坐标（由来源页传入或从 LocationService 获取）
    @State var currentLat: Float64 = 0.0
    @State var currentLng: Float64 = 0.0

    // 目标对话
    @State var targetPeerType: String = "user"
    @State var targetPeerId: Int64 = 0

    // 搜索状态
    @State var searchQuery: String = ""
    @State var isSearching: Bool = false
    @State var venueList: ArrayList<VenueItemData> = ArrayList<VenueItemData>()
    @State var hasSearched: Bool = false
    @State var searchError: String = ""

    // 发送状态
    @State var isSending: Bool = false
    @State var sendResultText: String = ""
    @State var sendSuccess: Bool = false

    // 昼夜判定 (P2-193)
    @State var isDaytime: Bool = true

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.requestLocation()
        this.loadDayNightStatus()
    }

    // ==================== 定位 (从 GPS 获取当前坐标) ====================

    private func requestLocation(): Unit {
        ensureLocationPermission({ granted: Bool =>
            if (granted) {
                let _ = spawn {
                    let result = getCurrentDeviceLocation()
                    if (result.success) {
                        let lat = result.latitude
                        let lng = result.longitude
                        launch {
                            this.currentLat = lat
                            this.currentLng = lng
                        }
                        Hilog.info(0, "CjTelegram", "[VenuePickerPage] GPS lat=${lat} lng=${lng}")
                    } else {
                        Hilog.info(0, "CjTelegram", "[VenuePickerPage] GPS failed: ${result.errorMessage}")
                    }
                }
            } else {
                Hilog.info(0, "CjTelegram", "[VenuePickerPage] location permission denied")
            }
        })
    }

    // ==================== 昼夜判定 (P2-193) ====================

    private func loadDayNightStatus(): Unit {
        let lat = this.currentLat
        let lng = this.currentLng
        let _ = spawn {
            let svc = getSunriseSunsetService()
            let daytime = svc.isDaytime(lat, lng)
            launch {
                this.isDaytime = daytime
            }
            Hilog.info(0, "CjTelegram", "[VenuePickerPage] isDaytime=${daytime}")
        }
    }

    // ==================== 搜索 ====================

    private func onSearchChanged(query: String): Unit {
        let newQuery = query
        launch {
            this.searchQuery = newQuery
        }
        if (newQuery.size == 0) {
            launch {
                this.venueList = ArrayList<VenueItemData>()
                this.hasSearched = false
                this.searchError = ""
                this.isSearching = false
            }
            return
        }
        let lat = this.currentLat
        let lng = this.currentLng
        launch { this.isSearching = true }
        let _ = spawn {
            let svc = getVenueSearchService()
            let venues = svc.searchVenues(lat, lng, newQuery)
            launch {
                this.venueList = venues
                this.isSearching = false
                this.hasSearched = true
                this.searchError = if (venues.size == 0) { "未找到相关场所" } else { "" }
            }
            Hilog.info(0, "CjTelegram", "[VenuePickerPage] search done count=${venues.size}")
        }
    }

    private func searchNearby(): Unit {
        let lat = this.currentLat
        let lng = this.currentLng
        launch { this.isSearching = true }
        let _ = spawn {
            let svc = getVenueSearchService()
            let venues = svc.searchVenues(lat, lng, "")
            launch {
                this.venueList = venues
                this.isSearching = false
                this.hasSearched = true
                this.searchError = if (venues.size == 0) { "附近暂无场所" } else { "" }
            }
            Hilog.info(0, "CjTelegram", "[VenuePickerPage] nearby loaded count=${venues.size}")
        }
    }

    // ==================== 发送 ====================

    private func selectVenue(venue: VenueItemData): Unit {
        if (this.isSending) { return }
        let lat = venue.latitude
        let lng = venue.longitude
        let pType = this.targetPeerType
        let pId = this.targetPeerId
        launch { this.isSending = true }
        let _ = spawn {
            let ok = sendLocationMessage(pType, pId, lat, lng)
            launch {
                this.isSending = false
                this.sendSuccess = ok
                this.sendResultText = if (ok) {
                    venue.title + " 已发送"
                } else {
                    "发送失败，请重试"
                }
            }
            Hilog.info(0, "CjTelegram", "[VenuePickerPage] send venue ok=${ok}")
        }
    }

    // ==================== 辅助 ====================

    private func getVenueIconColor(type_: String): Int64 {
        let t = type_.toAsciiLower()
        if (t.contains("food") || t.contains("restaurant") || t.contains("cafe")) { return 0xE8744C }
        if (t.contains("shop") || t.contains("store") || t.contains("market")) { return 0x5AB1D6 }
        if (t.contains("hotel") || t.contains("lodging")) { return 0x7BC67E }
        if (t.contains("park") || t.contains("garden")) { return 0x50C878 }
        if (t.contains("art") || t.contains("museum")) { return 0x9B59B6 }
        if (t.contains("sport") || t.contains("gym")) { return 0xE74C3C }
        if (t.contains("transport") || t.contains("station") || t.contains("airport")) { return 0x3498DB }
        if (t.contains("health") || t.contains("hospital")) { return 0xE91E63 }
        return 0x317AFF
    }

    private func getVenueIconLabel(type_: String): String {
        let t = type_.toAsciiLower()
        if (t.contains("food") || t.contains("restaurant") || t.contains("cafe")) { return "F" }
        if (t.contains("shop") || t.contains("store")) { return "S" }
        if (t.contains("hotel") || t.contains("lodging")) { return "H" }
        if (t.contains("park") || t.contains("garden")) { return "P" }
        if (t.contains("art") || t.contains("museum")) { return "M" }
        if (t.contains("sport") || t.contains("gym")) { return "G" }
        if (t.contains("transport") || t.contains("station") || t.contains("airport")) { return "T" }
        if (t.contains("health") || t.contains("hospital")) { return "+" }
        return "L"
    }

    private func getBgColor(): Int64 {
        return if (this.isDaytime) { 0xF2F2F7 } else { 0x1C1C1E }
    }

    private func getTextColor(): Int64 {
        return if (this.isDaytime) { 0x000000 } else { 0xFFFFFF }
    }

    // ==================== UI ====================

    public func build() {
        Column {
            // 标题栏
            Row {
                Text("← 返回")
                    .fontSize(17)
                    .fontColor(0x0088CC)
                    .onClick({ _evt =>
                        routerPop()
                    })
                Blank()
                Text("选择场所")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.getTextColor())
                Blank()
                Row {}.width(60)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .backgroundColor(if (this.isDaytime) { 0xFFFFFF } else { 0x2C2C2E })
            .alignItems(VerticalAlign.Center)

            // 搜索框 — P2-RETRO-search-c: TextInput → SearchBar 原子
            // "附近" 按钮是 VenuePickerPage 特有功能 (searchNearby)，SearchBar 无法表达，
            // 保留在 Row 右侧；SearchBar 居左撑满剩余宽度。
            Row {
                Column {
                    SearchBar(
                        backArrow: false,
                        text: this.searchQuery,
                        hint: "搜索附近场所...",
                        onChange: { value: String =>
                            this.onSearchChanged(value)
                        },
                        loading: this.isSearching
                    )
                }
                .layoutWeight(1)

                Text("附近")
                    .fontSize(15)
                    .fontColor(0x0088CC)
                    .margin(left: 8)
                    .onClick({ _evt =>
                        this.searchNearby()
                    })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 8, bottom: 8)
            .backgroundColor(if (this.isDaytime) { 0xFFFFFF } else { 0x2C2C2E })
            .alignItems(VerticalAlign.Center)

            // 发送结果提示
            if (this.sendResultText.size > 0) {
                Row {
                    Text(this.sendResultText)
                        .fontSize(14)
                        .fontColor(if (this.sendSuccess) { 0x34C759 } else { 0xFF3B30 })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 8)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(if (this.isDaytime) { 0xF2F2F7 } else { 0x1C1C1E })
            }

            // Venue 列表
            if (!this.hasSearched && !this.isSearching) {
                Column {
                    Text("输入关键词搜索附近场所")
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .margin(top: 40)
                    Text("或点击[附近]查看推荐场所")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(top: 8)
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Center)
            } else if (this.searchError.size > 0 && !this.isSearching) {
                Text(this.searchError)
                    .fontSize(15)
                    .fontColor(0x8E8E93)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .margin(top: 40)
            } else {
                List {
                    ForEach(this.venueList, itemGenerator: { v: VenueItemData, _idx: Int64 =>
                        ListItem {
                            Row {
                                // 类别图标
                                Column {
                                    Text(this.getVenueIconLabel(v.type_))
                                        .fontSize(16)
                                        .fontWeight(FontWeight.Medium)
                                        .fontColor(0xFFFFFF)
                                }
                                .width(40)
                                .height(40)
                                .borderRadius(20)
                                .backgroundColor(this.getVenueIconColor(v.type_))
                                .justifyContent(FlexAlign.Center)
                                .alignItems(HorizontalAlign.Center)
                                .margin(right: 12)

                                // 标题 + 地址
                                Column {
                                    Text(v.title)
                                        .fontSize(16)
                                        .fontColor(this.getTextColor())
                                        .maxLines(1)
                                        .textOverflow(TextOverflow.Ellipsis)
                                        .width(100.percent)
                                    if (v.address.size > 0) {
                                        Text(v.address)
                                            .fontSize(13)
                                            .fontColor(0x8E8E93)
                                            .maxLines(1)
                                            .textOverflow(TextOverflow.Ellipsis)
                                            .margin(top: 2)
                                            .width(100.percent)
                                    }
                                }
                                .layoutWeight(1)
                                .alignItems(HorizontalAlign.Start)

                                if (this.isSending) {
                                    LoadingProgress()
                                        .width(18)
                                        .height(18)
                                        .color(0x0088CC)
                                }
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 10, bottom: 10)
                            .alignItems(VerticalAlign.Center)
                            .backgroundColor(if (this.isDaytime) { 0xFFFFFF } else { 0x2C2C2E })
                            .onClick({ _evt =>
                                this.selectVenue(v)
                            })
                        }
                    })
                }
                .width(100.percent)
                .layoutWeight(1)
                .divider(ListDividerOptions(strokeWidth: 1, color: if (this.isDaytime) { 0xE5E5EA } else { 0x3A3A3C }, startMargin: 68, endMargin: 0))
                .backgroundColor(if (this.isDaytime) { 0xFFFFFF } else { 0x2C2C2E })
                .borderRadius(12)
                .margin(left: 16, right: 16, top: 8, bottom: 16)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.getBgColor())
        .onAppear({ => this.ensureLoaded() })
    }
}
