package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog

import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.interop.{callArk, subscribe, ATTACH_LOCATION_UPDATE, EVT_ATTACH_LOCATION_ACTION}
import std.collection.ArrayList

// ArkTS 覆盖层动作回传：dispatchEvent 的订阅只能增不能删，这里只订阅一次，
// 转发给当前存活的嵌入实例（面板关闭后 sink 置空即断开）。
var _attachLocationActionSink: Option<(String) -> Unit> = None
var _attachLocationSubscribed: Bool = false

/** 地图 header 全高（vp），对位 iOS 位置选择器顶部地图区。 */
let LOCATION_MAP_HEIGHT: Float64 = 200.0

/**
 * LocationPicker — 位置选择器组件 (Phase LOC-3)
 * 
 * 对应 Telegram-iOS LocationPickerController
 * 
 * 功能:
 * - 打开时自动请求 GPS 权限 + 获取当前位置
 * - 显示加载状态 → 真实 GPS 坐标
 * - 发送当前位置（静态）
 * - 分享实时位置（15 分钟 / 1 小时 / 8 小时）
 * - 权限拒绝时显示引导提示
 */
@Component
public class LocationPicker {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var currentLat: Float64 = 0.0
    @State var currentLong: Float64 = 0.0
    @State var locationName: String = ""
    @State var isLoadingLocation: Bool = true
    @State var hasPermission: Bool = true
    @State var errorMessage: String = ""
    @State var showDurationPicker: Bool = false
    @State var locationReady: Bool = false

    public var onSendLocation: (Float64, Float64, String) -> Unit = { _lat: Float64, _lng: Float64, _name: String => }
    public var onSendLiveLocation: (Float64, Float64, Int64) -> Unit = { _lat: Float64, _lng: Float64, _duration: Int64 => }
    public var onClose: () -> Unit = { => }
    // 嵌入附件 sheet：不画自己的标题栏，内容改为可滚动，高度由宿主容器决定
    public var embedded: Bool = false
    // iOS「OR CHOOSE A PLACE」：选中附近场馆发送
    public var onSendVenue: (VenueItemData) -> Unit = { _v: VenueItemData => }
    // 地图区全局几何（px）+ 当前坐标：宿主据此叠放系统地图（HMS Map Kit，ArkTS 覆盖层）；
    // 覆盖层初始化失败时不绘制，下面的 OSM 快照即兜底。
    public var onMapGeometry: (Float64, Float64, Float64, Float64, Float64, Float64) -> Unit =
        { _x: Float64, _y: Float64, _w: Float64, _h: Float64, _lat: Float64, _lng: Float64 => }

    private func vp2pxF(v: Float64): Float64 {
        match (this.getUIContext().vp2px(v.vp)) {
            case Some(l) => l.value
            case None => v * 3.0
        }
    }

    private func reportMapArea(newArea: Area): Unit {
        if (this.embedded) {
            let x = match (newArea.globalPosition.x) { case Some(l) => l.value  case None => 0.0 }
            let y = match (newArea.globalPosition.y) { case Some(l) => l.value  case None => 0.0 }
            this.slotXPx = this.vp2pxF(x)
            this.slotYPx = this.vp2pxF(y)
            this.slotWPx = this.vp2pxF(newArea.width.value)
            this.slotHPx = this.vp2pxF(newArea.height.value)
            this.pushAttachLocationState()
            return
        }
        if (!this.locationReady) { return }
        let x = match (newArea.globalPosition.x) { case Some(l) => l.value  case None => 0.0 }
        let y = match (newArea.globalPosition.y) { case Some(l) => l.value  case None => 0.0 }
        this.onMapGeometry(this.vp2pxF(x), this.vp2pxF(y),
            this.vp2pxF(newArea.width.value), this.vp2pxF(newArea.height.value),
            this.currentLat, this.currentLong)
    }
    // 地图快照（OSM 瓦片拼合，LocationResourcesService.fetchMapSnapshot）
    @State var snapshotPath: String = ""
    @State var venues: ArrayList<VenueItemData> = ArrayList<VenueItemData>()
    @State var venuesLoading: Bool = false
    @State var venueQuery: String = ""
    @State var showVenueSearch: Bool = false
    // GPS 精度（米），iOS 副标题「Accurate to N m」
    @State var accuracyMeters: Float64 = 0.0

    // 嵌入模式：整块页签由 ArkTS AttachLocationView 渲染，这里只报几何 + 推状态。
    private var tabAlive: Bool = false
    private var slotXPx: Float64 = 0.0
    private var slotYPx: Float64 = 0.0
    private var slotWPx: Float64 = 0.0
    private var slotHPx: Float64 = 0.0

    protected func aboutToAppear() {
        if (this.embedded) {
            this.tabAlive = true
            if (!_attachLocationSubscribed) {
                _attachLocationSubscribed = true
                subscribe(EVT_ATTACH_LOCATION_ACTION, { json: String =>
                    match (_attachLocationActionSink) {
                        case Some(sink) => sink(json)
                        case None => ()
                    }
                })
            }
            _attachLocationActionSink = Some({ json: String => this.handleArkAction(json) })
        }
        this.requestGPSLocation()
    }

    protected func aboutToDisappear() {
        if (this.embedded) {
            this.tabAlive = false
            _attachLocationActionSink = None
            this.pushAttachLocationState()
        }
    }

    /** ArkTS 覆盖层里的用户动作（UI 线程投递）。 */
    private func handleArkAction(json: String): Unit {
        let obj = JsonParser.parseObject(json)
        let action = obj.getString("action")
        Hilog.info(0, "CjTelegram", "[LocationPicker] ark action=${action}")
        if (action == "sendCurrent") {
            if (this.locationReady) { this.onSendLocation(this.currentLat, this.currentLong, this.locationName) }
        } else if (action == "sendLive") {
            let seconds = obj.getInt("seconds")
            if (this.locationReady && seconds > 0) { this.onSendLiveLocation(this.currentLat, this.currentLong, seconds) }
        } else if (action == "sendVenue") {
            let id = obj.getString("id")
            for (v in this.venues) {
                if (v.venueId == id) { this.onSendVenue(v); break }
            }
        } else if (action == "search") {
            let q = obj.getString("query")
            this.venueQuery = q
            this.loadVenues(this.currentLat, this.currentLong, q)
        } else if (action == "retry") {
            this.requestGPSLocation()
        }
    }

    /** 几何 + 定位/地点状态整包推给 ArkTS；只在数据变化时调用，不随滚动逐帧推。 */
    private func pushAttachLocationState(): Unit {
        if (!this.embedded) { return }
        let obj = JsonObject()
        obj.setBool("visible", this.tabAlive && this.slotWPx > 0.0 && this.slotHPx > 0.0)
        obj.setInt("x", Int64(this.slotXPx))
        obj.setInt("y", Int64(this.slotYPx))
        obj.setInt("w", Int64(this.slotWPx))
        obj.setInt("h", Int64(this.slotHPx))
        obj.setBool("ready", this.locationReady)
        obj.setBool("loading", this.isLoadingLocation)
        obj.setBool("permission", this.hasPermission)
        obj.setString("error", this.errorMessage)
        obj.setString("name", this.locationName)
        obj.setInt("accuracy", if (this.accuracyMeters > 0.0) { Int64(this.accuracyMeters + 0.5) } else { 0 })
        obj.setString("lat", this.currentLat.toString())
        obj.setString("lng", this.currentLong.toString())
        obj.setBool("venuesLoading", this.venuesLoading)
        obj.setString("query", this.venueQuery)
        let arr = JsonArray()
        let venueSvc = getItemListVenueService()
        for (v in this.venues) {
            let vo = JsonObject()
            vo.setString("id", v.venueId)
            vo.setString("title", v.title)
            vo.setString("address", v.address)
            vo.setString("label", venueSvc.venueIconLabel(v.type_))
            vo.setInt("color", venueSvc.venueIconColor(v.type_))
            arr.addObject(vo)
        }
        obj.setArray("venues", arr)
        callArk(ATTACH_LOCATION_UPDATE, obj.toJsonString())
    }

    private func requestGPSLocation(): Unit {
        this.isLoadingLocation = true
        this.errorMessage = ""
        ensureLocationPermission({ granted: Bool =>
            if (granted) {
                launch { this.hasPermission = true }
                spawn {
                    let result = getCurrentDeviceLocation()
                    if (result.success) {
                        let lat = result.latitude
                        let lng = result.longitude
                        let name = formatCoordinates(lat, lng)
                        let acc = result.accuracy
                        launch {
                            this.accuracyMeters = acc
                            this.currentLat = lat
                            this.currentLong = lng
                            this.locationName = name
                            this.locationReady = true
                            this.isLoadingLocation = false
                            this.pushAttachLocationState()
                        }
                        Hilog.info(0, "CjTelegram", "[LocationPicker] GPS ready")
                        this.loadSnapshot(lat, lng)
                        this.loadVenues(lat, lng, "")
                    } else {
                        let errMsg = result.errorMessage
                        launch {
                            this.errorMessage = errMsg
                            this.isLoadingLocation = false
                            this.pushAttachLocationState()
                        }
                        Hilog.info(0, "CjTelegram", "[LocationPicker] GPS failed")
                    }
                }
            } else {
                launch {
                    this.hasPermission = false
                    this.isLoadingLocation = false
                    this.pushAttachLocationState()
                }
                Hilog.info(0, "CjTelegram", "[LocationPicker] Permission denied")
            }
        })
    }

    /** 地图快照：iOS LocationPicker 顶部是真实地图；这里用仓里既有的 OSM 瓦片拼合（InteractiveMapPage 同源） */
    private func loadSnapshot(lat: Float64, lng: Float64): Unit {
        spawn {
            let svc = getLocationResourcesService()
            let result = svc.fetchMapSnapshot(lat, lng, 640, 360, zoom: 15)
            if (result.success) {
                let path = result.localPath
                launch { this.snapshotPath = path }
            } else {
                Hilog.info(0, "CjTelegram", "[LocationPicker] snapshot failed")
            }
        }
    }

    /** 附近场馆（foursquare inline bot，VenueSearchService 同源）；query 非空为搜索 */
    private func loadVenues(lat: Float64, lng: Float64, query: String): Unit {
        launch {
            this.venuesLoading = true
            this.pushAttachLocationState()
        }
        spawn {
            var list = ArrayList<VenueItemData>()
            // 系统地图 POI（HMS Map Kit site.nearbySearch）优先，失败退回 foursquare inline bot
            try {
                list = getMapKitBridgeService().nearbySearch(lat, lng, query, 1000)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[LocationPicker] mapkit nearbySearch failed: ${e}")
            }
            if (list.size == 0) {
                try {
                    list = getVenueSearchService().searchVenues(lat, lng, query)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[LocationPicker] searchVenues failed: ${e}")
                }
            }
            let loaded = list
            launch {
                this.venues = loaded
                this.venuesLoading = false
                this.pushAttachLocationState()
            }
        }
    }

    @Builder
    func venueRow(v: VenueItemData) {
        Row {
            Text(getItemListVenueService().venueIconLabel(v.type_))
                .fontSize(16)
                .fontColor(0xFFFFFFFF)
                .width(40)
                .height(40)
                .borderRadius(20)
                .backgroundColor(getItemListVenueService().venueIconColor(v.type_))
                .textAlign(TextAlign.Center)
            Column {
                Text(v.title)
                    .fontSize(16)
                    .fontColor(0xFF000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Text(v.address)
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
                    .margin(top: 2)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)
        }
        .width(100.percent)
        .height(60)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _evt => this.onSendVenue(v) })
    }

    @Builder
    func venuesSection() {
        Column {
            Row {
                Text("OR CHOOSE A PLACE")
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
                    .layoutWeight(1)
                Text("⌕")
                    .fontSize(18)
                    .fontColor(0xFF007AFF)
                    .onClick({ _evt =>
                        this.showVenueSearch = !this.showVenueSearch
                        if (!this.showVenueSearch && this.venueQuery.size > 0) {
                            this.venueQuery = ""
                            this.loadVenues(this.currentLat, this.currentLong, "")
                        }
                    })
            }
            .width(100.percent)
            .padding(left: 32, right: 32, top: 18, bottom: 6)
            if (this.showVenueSearch) {
                TextInput(text: this.venueQuery, placeholder: "Search places")
                    .width(100.percent)
                    .height(36)
                    .fontSize(15)
                    .backgroundColor(0xFFE3E3E8)
                    .borderRadius(10)
                    .padding(left: 12, right: 12)
                    .margin(left: 16, right: 16, bottom: 8)
                    .onChange({ v: String => this.venueQuery = v })
                    .onSubmit({ _k =>
                        this.loadVenues(this.currentLat, this.currentLong, this.venueQuery)
                    })
            }
            if (this.venuesLoading) {
                Column {
                    LoadingProgress().width(24).height(24).color(0xFF007AFF)
                }
                .width(100.percent)
                .padding(top: 16, bottom: 16)
                .alignItems(HorizontalAlign.Center)
            } else if (this.venues.size > 0) {
                Column {
                    ForEach(this.venues, itemGeneratorFunc: { v: VenueItemData, _idx: Int64 =>
                        this.venueRow(v)
                    }, keyGeneratorFunc: { v: VenueItemData, idx: Int64 => "v_" + idx.toString() + "_" + v.venueId })
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16)
                .clip(true)
            } else {
                Text("No places found nearby")
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .padding(top: 12, bottom: 12)
            }
        }
        .width(100.percent)
    }

    private func getMapAreaText(): String {
        if (this.isLoadingLocation) {
            return "正在获取位置..."
        }
        if (!this.hasPermission) {
            return "未授权位置权限"
        }
        if (this.errorMessage.size > 0) {
            return this.errorMessage
        }
        return this.locationName
    }

    /** iOS Map_AccurateTo：副标题只给精度，不露具体坐标 */
    private func getSubtitleText(): String {
        if (this.locationReady) {
            let m = if (this.accuracyMeters > 0.0) { Int64(this.accuracyMeters + 0.5) } else { 0 }
            if (m <= 0) { return "Accurate to 5 m" }
            return "Accurate to ${m} m"
        }
        return "Waiting for GPS..."
    }

    private func getLiveDurationText(seconds: Int64): String {
        if (seconds == 900) { return "15 分钟" }
        if (seconds == 3600) { return "1 小时" }
        if (seconds == 28800) { return "8 小时" }
        return "${seconds} 秒"
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            if (this.embedded) {
                // 整块页签由 ArkTS AttachLocationView 渲染（地图 + 列表同层，滚动不过 interop）；
                // 这里只是等大的透明占位，报几何给覆盖层。
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .onAreaChange({ _: Area, newArea: Area => this.reportMapArea(newArea) })
            } else {
                this.standaloneBody()
            }
        }
        .width(100.percent)
        .height(100.percent)
    }

    /** 独立页（非嵌入）沿用仓颉原生布局。 */
    @Builder
    func standaloneBody() {
        Column {
            // 标题栏（嵌入附件 sheet 时由 sheet 头部承担）
            if (!this.embedded) {
            Row {
                Text("取消")
                    .fontSize(17)
                    .fontColor(0x0088CC)
                    .onClick({ evt =>
                        this.onClose()
                    })

                Blank()

                Text("位置")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)

                Blank()
                Row {}.width(50)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)
            }
            // 对位 iOS LocationPickerControllerNode：地图 header 固定在顶部，列表上滑时
            // header 高度 = max(0, listOffset) 逐渐收缩、地图在其中居中，列表内容从地图下方
            // 开始并盖过地图。此前地图占位块放在 Scroll 里随内容一起滚走，ArkTS 系统地图
            // 覆盖层按占位块几何跟着平移（真机实锤「上划时地图跟着往上划」）。
            Stack(alignContent: Alignment.TopStart) {
                // 地图：有快照画快照（iOS 顶部真实地图），否则退回 GPS 状态占位
                if (this.snapshotPath.size > 0 && this.locationReady) {
                    Stack(alignContent: Alignment.Center) {
                        Image(this.snapshotPath)
                            .width(100.percent)
                            .height(200)
                            .objectFit(ImageFit.Cover)
                        Image(@r(app.media.loc_ic_sendlocation))
                            .width(28)
                            .height(28)
                            .fillColor(0xFF007AFF)
                    }
                    .width(100.percent)
                    .height(this.mapVisibleHeight())
                    .clip(true)
                    .onAreaChange({ _: Area, newArea: Area => this.reportMapArea(newArea) })
                } else {
                Column {
                    if (this.isLoadingLocation) {
                        LoadingProgress()
                            .width(48)
                            .height(48)
                            .color(0x0088CC)
                        Text("正在获取位置...")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .margin(top: 12)
                    } else {
                        if (!this.hasPermission) {
                            // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
                            Image(@r(app.media.loc_ic_maprow))
                                .width(40)
                                .height(40)
                                .fillColor(0xFF3B30)
                            Text("需要位置权限")
                                .fontSize(16)
                                .fontColor(0xFF3B30)
                                .margin(top: 8)
                            Text("请在系统设置中授权位置权限")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(top: 4)
                            Text("重新请求权限")
                                .fontSize(15)
                                .fontColor(0x0088CC)
                                .margin(top: 12)
                                .onClick({ evt =>
                                    this.requestGPSLocation()
                                })
                        } else {
                            // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
                            Image(@r(app.media.loc_ic_maprow))
                                .width(48)
                                .height(48)
                                .fillColor(0x0088CC)
                            Text(this.getMapAreaText())
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                                .margin(top: 8)
                            if (this.locationReady) {
                                Text("Lat: " + this.currentLat.toString() + "  Lng: " + this.currentLong.toString())
                                    .fontSize(12)
                                    .fontColor(0xC7C7CC)
                                    .margin(top: 4)
                            }
                        }
                    }
                }
                .width(100.percent)
                .height(this.mapVisibleHeight())
                .clip(true)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0xE8E8E8)
                .onAreaChange({ _: Area, newArea: Area => this.reportMapArea(newArea) })
                }
                Scroll(this.scroller) {
                    Column {
                        Blank().height(LOCATION_MAP_HEIGHT)
                        Column {
                    // 操作按钮列表
                    Column {
                        // 发送当前位置
                        // 资源保真修复：真实矢量图标（Location/SendLocationIcon.imageset/ic_mappin.pdf 转 SVG）替代 emoji 字形
                        Row {
                            Image(@r(app.media.loc_ic_sendlocation))
                                .width(20)
                                .height(20)
                                .fillColor(if (this.locationReady) { 0x0088CC } else { 0xC7C7CC })
                                .margin(right: 12)
                            Column {
                                Text(trSource("Send My Current Location"))
                                    .fontSize(17)
                                    .fontColor(if (this.locationReady) { 0x000000 } else { 0xC7C7CC })
                                Text(this.getSubtitleText())
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 2)
                            }
                            .alignItems(HorizontalAlign.Start)
                            .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(60)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ evt =>
                            if (this.locationReady) {
                                this.onSendLocation(this.currentLat, this.currentLong, this.locationName)
                            }
                        })

                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                        // 分享实时位置（展开/收起持续时间选项）
                        // 资源保真修复：真实矢量图标（Location/SendLiveLocationIcon.imageset/ic_mappinlive.pdf 转 SVG）替代 emoji 字形
                        Row {
                            Image(@r(app.media.loc_ic_sendlive))
                                .width(20)
                                .height(20)
                                .fillColor(if (this.locationReady) { 0x34C759 } else { 0xC7C7CC })
                                .margin(right: 12)
                            Column {
                                Text(trSource("Share My Live Location for..."))
                                    .fontSize(17)
                                    .fontColor(if (this.locationReady) { 0x000000 } else { 0xC7C7CC })
                                Text(trSource("Updated in real time as you move"))
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 2)
                            }
                            .alignItems(HorizontalAlign.Start)
                            .layoutWeight(1)
                            Text(if (this.showDurationPicker) { "▲" } else { "▼" })
                                .fontSize(12)
                                .fontColor(0xC7C7CC)
                        }
                        .width(100.percent)
                        .height(60)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ evt =>
                            if (this.locationReady) {
                                this.showDurationPicker = !this.showDurationPicker
                            }
                        })

                        // 持续时间选项（展开时显示）
                        if (this.showDurationPicker) {
                            Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                            // 15 分钟
                            // 资源保真修复：真实矢量图标（Item List/Icons/Clock.imageset/clock.pdf 转 SVG）替代 emoji 字形
                            Row {
                                Image(@r(app.media.loc_ic_clock))
                                    .width(16)
                                    .height(16)
                                    .fillColor(0x0088CC)
                                    .margin(left: 8, right: 12)
                                Text("15 minutes")
                                    .fontSize(16)
                                    .fontColor(0x0088CC)
                            }
                            .width(100.percent)
                            .height(48)
                            .padding(left: 48, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .backgroundColor(0xF8F8F8)
                            .onClick({ evt =>
                                this.onSendLiveLocation(this.currentLat, this.currentLong, 900)
                            })

                            Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                            // 1 小时
                            // 资源保真修复：真实矢量图标（Item List/Icons/Clock.imageset/clock.pdf 转 SVG）替代 emoji 字形
                            Row {
                                Image(@r(app.media.loc_ic_clock))
                                    .width(16)
                                    .height(16)
                                    .fillColor(0x0088CC)
                                    .margin(left: 8, right: 12)
                                Text(trSource("1 hour"))
                                    .fontSize(16)
                                    .fontColor(0x0088CC)
                            }
                            .width(100.percent)
                            .height(48)
                            .padding(left: 48, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .backgroundColor(0xF8F8F8)
                            .onClick({ evt =>
                                this.onSendLiveLocation(this.currentLat, this.currentLong, 3600)
                            })

                            Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                            // 8 小时
                            // 资源保真修复：真实矢量图标（Item List/Icons/Clock.imageset/clock.pdf 转 SVG）替代 emoji 字形
                            Row {
                                Image(@r(app.media.loc_ic_clock))
                                    .width(16)
                                    .height(16)
                                    .fillColor(0x0088CC)
                                    .margin(left: 8, right: 12)
                                Text("8 hours")
                                    .fontSize(16)
                                    .fontColor(0x0088CC)
                            }
                            .width(100.percent)
                            .height(48)
                            .padding(left: 48, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .backgroundColor(0xF8F8F8)
                            .onClick({ evt =>
                                this.onSendLiveLocation(this.currentLat, this.currentLong, 28800)
                            })
                        }
                    }
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16, top: 16)

                    if (this.locationReady) {
                        this.venuesSection()
                    }
                    Blank().height(24)
                        }
                        .width(100.percent)
                        .backgroundColor(0xF2F2F7)
                    }
                    .width(100.percent)
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(Color.Transparent)
                .scrollBar(BarState.Off)
                .onDidScroll({ _x: Float64, _y: Float64, _s: ScrollState => this.syncMapHeaderHeight() })
                .onScrollStop({ => this.syncMapHeaderHeight() })
            }
            .width(100.percent)
            .layoutWeight(1)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
    }

    // ==================== 地图 header 收缩（iOS updateFloatingHeaderOffset）====================

    private let scroller: Scroller = Scroller()
    @State var mapScrollY: Float64 = 0.0

    private func mapVisibleHeight(): Float64 {
        let h = LOCATION_MAP_HEIGHT - this.mapScrollY
        return if (h > 0.0) { h } else { 0.0 }
    }

    /** 滚动回调在 UI 线程；变化 <1vp 不写状态，避免每帧重建并刷覆盖层几何。 */
    private func syncMapHeaderHeight(): Unit {
        match (this.scroller.currentOffset()) {
            case Some(o) =>
                let y = if (o.yOffset > 0.0) { o.yOffset } else { 0.0 }
                let delta = y - this.mapScrollY
                if (delta > 1.0 || delta < -1.0) { this.mapScrollY = y }
            case None => ()
        }
    }
}
