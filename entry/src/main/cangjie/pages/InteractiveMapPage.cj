package ohos_app_cangjie_entry.pages

/**
 * InteractiveMapPage — 交互地图页面 (P2-182)（混合工程迁移版）
 *
 * iOS 对应:
 *   submodules/LocationUI/Sources/LocationMapNode.swift
 *   submodules/LocationUI/Sources/LocationMapHeaderNode.swift
 *   LocationPickerController 中的 MKMapView 交互部分
 *
 * Map Kit 可行性探针结论 (P2-182):
 *   结局 3 — OSM 静态快照平移缩放近似（OSM staticmap HTTP GET，无 arkinterop / C）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容 Column
 *  - pageStack.pop() → routerPop()
 *  - onReady 参数解析 → takePending("InteractiveMapPage") + ensureLoaded()/.onAppear
 */

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.convert.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.{
    getLocationResourcesService,
    getLocationDistanceService,
    getCurrentDeviceLocation,
    ensureLocationPermission,
    setMapPickResult,
    reverseGeocodeLocation
}
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

@HybridComponentEntry
@Component
public class InteractiveMapPage {
    // 地图中心坐标
    @State var centerLat: Float64 = 39.9042
    @State var centerLng: Float64 = 116.4074

    // 目标位置 pin（可选）
    @State var targetLat: Float64 = 0.0
    @State var targetLng: Float64 = 0.0
    @State var targetTitle: String = ""
    @State var hasTarget: Bool = false

    // 缩放级别 (14=城市 / 15=街道 / 16=街区 / 17=建筑 / 18=最大)
    @State var zoomLevel: Int32 = 15

    // 快照状态
    @State var snapshotPath: String = ""
    @State var isLoadingSnapshot: Bool = false
    @State var snapshotError: Bool = false

    // 跟踪模式（类似 iOS MKUserTrackingMode）
    @State var trackingMode: Bool = false
    @State var userLat: Float64 = 0.0
    @State var userLng: Float64 = 0.0
    @State var hasUserLocation: Bool = false

    // 距离信息（当有 target 且有 user location 时显示）
    @State var distanceText: String = ""
    @State var bearingText: String = ""

    // 页面标题
    @State var pageTitle: String = "地图"

    // P2-181: 拖选模式（"pick" = 选择地点后返回）
    @State var pickMode: Bool = false
    // P2-181: 选中地点的反向地理编码地址（pick mode 底部显示）
    @State var pickAddressText: String = ""

    // 首次加载守卫
    @State var loaded: Bool = false

    // 当前快照宽/高像素
    private let snapshotWidth: Int32 = 640
    private let snapshotHeight: Int32 = 480

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.parseRouteParam(takePending("InteractiveMapPage"))
        this.loadSnapshot()
        this.loadUserLocation()
    }

    public func build() {
        Column {
            // 导航栏
            Row {
                Text("← 返回")
                    .fontSize(17)
                    .fontColor(0x0088CC)
                    .onClick({ _evt =>
                        routerPop()
                    })
                Blank()
                Text(this.pageTitle)
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                Blank()
                // 跟踪模式切换按钮
                // 资源保真修复：真实矢量图标（Location/TrackIcon.imageset/ic_gps.pdf、
                // TrackActiveIcon.imageset/ic_gps_filled.pdf 转 SVG）替代 emoji/符号字形
                // D-133: @r() 不支持值级 if/else 分支，改用组件级 if/else
                if (this.trackingMode) {
                    Image(@r(app.media.loc_ic_trackactive))
                        .width(20)
                        .height(20)
                        .fillColor(0x317AFF)
                        .onClick({ _evt =>
                            this.toggleTrackingMode()
                        })
                } else {
                    Image(@r(app.media.loc_ic_track))
                        .width(20)
                        .height(20)
                        .fillColor(0x8E8E93)
                        .onClick({ _evt =>
                            this.toggleTrackingMode()
                        })
                }
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            // 地图快照区域
            Stack(alignContent: Alignment.Center) {
                if (this.snapshotPath.size > 0) {
                    Image(this.snapshotPath)
                        .width(100.percent)
                        .height(300)
                        .objectFit(ImageFit.Cover)
                } else if (this.isLoadingSnapshot) {
                    Column {
                        LoadingProgress()
                            .width(40)
                            .height(40)
                            .color(0x0088CC)
                        Text("加载地图...")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .margin(top: 8)
                    }
                    .width(100.percent)
                    .height(300)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0xC8D8E8)
                } else {
                    Column {
                        Text(if (this.snapshotError) { "地图加载失败" } else { "正在加载..." })
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .height(300)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0xC8D8E8)
                }

                // 用户位置 pin（蓝色圆点 + 脉冲效果用透明圆）
                if (this.hasUserLocation && this.trackingMode) {
                    Column {
                        Stack(alignContent: Alignment.Center) {
                            Column {}
                                .width(20)
                                .height(20)
                                .borderRadius(10)
                                .backgroundColor(0x33317AFF)
                            Column {}
                                .width(12)
                                .height(12)
                                .borderRadius(6)
                                .backgroundColor(0xFF317AFF)
                                .border(width: 2, color: 0xFFFFFFFF, style: BorderStyle.Solid)
                        }
                        .width(20)
                        .height(20)
                    }
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                }

                // 目标位置 pin（若有，非 pick 模式）
                // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
                if (this.hasTarget && !this.pickMode) {
                    Column {
                        Image(@r(app.media.loc_ic_maprow))
                            .width(32)
                            .height(32)
                            .fillColor(0xFF3B30)
                        Column {}
                            .width(6)
                            .height(3)
                            .backgroundColor(0x33000000)
                            .borderRadius(3)
                            .margin(top: 2)
                    }
                    .justifyContent(FlexAlign.End)
                    .alignItems(HorizontalAlign.Center)
                    .height(48)
                }

                // P2-181: pick 模式固定十字准星（始终居中，标记选中位置）
                // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
                if (this.pickMode) {
                    Column {
                        Image(@r(app.media.loc_ic_maprow))
                            .width(36)
                            .height(36)
                            .fillColor(0xFF3B30)
                    }
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                }

                // 缩放 + 平移控制面板（右下角）
                Column {
                    // 缩放按钮
                    Column {
                        Text("+")
                            .fontSize(20)
                            .fontColor(0x333333)
                            .fontWeight(FontWeight.Bold)
                            .textAlign(TextAlign.Center)
                            .width(36)
                            .height(36)
                            .backgroundColor(0xFFFFFFEE)
                            .borderRadius(6)
                            .onClick({ _evt =>
                                this.zoomIn()
                            })

                        Column {}
                            .width(36)
                            .height(1)
                            .backgroundColor(0xDDDDDD)

                        Text("-")
                            .fontSize(22)
                            .fontColor(0x333333)
                            .fontWeight(FontWeight.Bold)
                            .textAlign(TextAlign.Center)
                            .width(36)
                            .height(36)
                            .backgroundColor(0xFFFFFFEE)
                            .borderRadius(6)
                            .onClick({ _evt =>
                                this.zoomOut()
                            })
                    }
                    .borderRadius(8)
                    .margin(bottom: 8)

                    // 方向按钮（十字）
                    Column {
                        Row {
                            Column {}
                                .width(36)
                                .height(36)
                            Text("▲")
                                .fontSize(14)
                                .fontColor(0x333333)
                                .textAlign(TextAlign.Center)
                                .width(36)
                                .height(36)
                                .backgroundColor(0xFFFFFFEE)
                                .borderRadius(4)
                                .onClick({ _evt => this.panUp() })
                            Column {}
                                .width(36)
                                .height(36)
                        }
                        .justifyContent(FlexAlign.Center)
                        .alignItems(VerticalAlign.Center)

                        Row {
                            Text("◄")
                                .fontSize(14)
                                .fontColor(0x333333)
                                .textAlign(TextAlign.Center)
                                .width(36)
                                .height(36)
                                .backgroundColor(0xFFFFFFEE)
                                .borderRadius(4)
                                .onClick({ _evt => this.panLeft() })
                            Column {}
                                .width(36)
                                .height(36)
                            Text("►")
                                .fontSize(14)
                                .fontColor(0x333333)
                                .textAlign(TextAlign.Center)
                                .width(36)
                                .height(36)
                                .backgroundColor(0xFFFFFFEE)
                                .borderRadius(4)
                                .onClick({ _evt => this.panRight() })
                        }
                        .justifyContent(FlexAlign.Center)
                        .alignItems(VerticalAlign.Center)

                        Row {
                            Column {}
                                .width(36)
                                .height(36)
                            Text("▼")
                                .fontSize(14)
                                .fontColor(0x333333)
                                .textAlign(TextAlign.Center)
                                .width(36)
                                .height(36)
                                .backgroundColor(0xFFFFFFEE)
                                .borderRadius(4)
                                .onClick({ _evt => this.panDown() })
                            Column {}
                                .width(36)
                                .height(36)
                        }
                        .justifyContent(FlexAlign.Center)
                        .alignItems(VerticalAlign.Center)
                    }
                }
                .alignItems(HorizontalAlign.End)
                .justifyContent(FlexAlign.End)
                .width(100.percent)
                .height(300)
                .padding(right: 12, bottom: 12)
            }
            .width(100.percent)
            .height(300)
            .clip(true)

            // 坐标 + 缩放信息栏
            Row {
                Text(this.buildCoordText())
                    .fontSize(12)
                    .fontColor(0x8E8E93)
                Blank()
                Text("缩放 ${this.zoomLevel}")
                    .fontSize(12)
                    .fontColor(0x8E8E93)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 6, bottom: 6)
            .backgroundColor(0xF2F2F7)

            // 目标信息区域（若有 target）
            // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
            if (this.hasTarget) {
                Column {
                    Row {
                        Image(@r(app.media.loc_ic_maprow))
                            .width(20)
                            .height(20)
                            .fillColor(0xFF3B30)
                            .margin(right: 12)
                        Column {
                            if (this.targetTitle.size > 0) {
                                Text(this.targetTitle)
                                    .fontSize(16)
                                    .fontColor(0x000000)
                            }
                            Text(this.buildTargetCoordText())
                                .fontSize(12)
                                .fontColor(0x8E8E93)
                                .margin(top: 2)
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 14, bottom: 8)
                    .alignItems(VerticalAlign.Center)

                    // 距离信息（当有用户位置时显示）
                    if (this.distanceText.size > 0) {
                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)
                        Row {
                            Text("距离: ")
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                            Text(this.distanceText)
                                .fontSize(14)
                                .fontColor(0x000000)
                            if (this.bearingText.size > 0) {
                                Text("  " + this.bearingText)
                                    .fontSize(14)
                                    .fontColor(0x0088CC)
                            }
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 6, bottom: 10)
                    }

                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                    // 导航按钮
                    // 资源保真修复：真实矢量图标（Location/GoTo.imageset/goto.pdf 转 SVG）替代 emoji 字形
                    Row {
                        Image(@r(app.media.loc_ic_goto))
                            .width(20)
                            .height(20)
                            .fillColor(0x0088CC)
                            .margin(right: 12)
                        Text("导航到此处")
                            .fontSize(17)
                            .fontColor(0x0088CC)
                        Blank()
                        Text("›")
                            .fontSize(20)
                            .fontColor(0xC7C7CC)
                    }
                    .width(100.percent)
                    .height(50)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _evt =>
                        this.openNavigation()
                    })
                }
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, top: 12)
            }

            // P2-181: pick 模式确认按钮区（选择当前地图中心位置后确认）
            if (this.pickMode) {
                Column {
                    // 地址显示
                    if (this.pickAddressText.size > 0) {
                        // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
                        Row {
                            Image(@r(app.media.loc_ic_maprow))
                                .width(14)
                                .height(14)
                                .fillColor(0x555555)
                                .margin(right: 4)
                            Text(this.pickAddressText)
                                .fontSize(14)
                                .fontColor(0x333333)
                                .maxLines(2)
                                .textOverflow(TextOverflow.Ellipsis)
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 10, bottom: 6)
                        .alignItems(VerticalAlign.Center)
                        Divider().color(0xE5E5EA).strokeWidth(1)
                    }
                    // 确认按钮
                    Row {
                        Text("确认此位置")
                            .fontSize(17)
                            .fontColor(0xFFFFFF)
                            .textAlign(TextAlign.Center)
                            .fontWeight(FontWeight.Medium)
                    }
                    .width(100.percent)
                    .height(50)
                    .backgroundColor(0xFF317AFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16, top: 10, bottom: 10)
                    .justifyContent(FlexAlign.Center)
                    .onClick({ _evt =>
                        this.confirmPickLocation()
                    })
                }
                .backgroundColor(0xFFFFFF)
                .margin(top: 12)
            }

            // 跟踪模式提示（非 pick 模式）
            if (!this.hasUserLocation && !this.pickMode) {
                Row {
                    Text("获取您的位置中...")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 10, bottom: 10)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(0xF2F2F7)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }

    // ==================== 路由参数解析 ====================

    /**
     * 解析路由参数
     *
     * 格式 1 (view 模式): "lat|lng|title" 或 "lat|lng|title|zoom"
     * 格式 2 (pick 模式, P2-181): "pick:lat|lng" — 用户从地图选点后返回坐标给 LocationPage
     */
    private func parseRouteParam(paramStr: String): Unit {
        if (paramStr.size == 0) { return }

        // P2-181: 检查 pick 模式前缀
        if (paramStr.size >= 5 && paramStr[0..5] == "pick:") {
            let coordPart = paramStr[5..paramStr.size]
            let parts = coordPart.split("|")
            let lat = if (parts.size >= 1) { try { Float64.parse(parts[0]) } catch (_: Exception) { 39.9042 } } else { 39.9042 }
            let lng = if (parts.size >= 2) { try { Float64.parse(parts[1]) } catch (_: Exception) { 116.4074 } } else { 116.4074 }
            launch {
                this.centerLat = lat
                this.centerLng = lng
                this.pickMode = true
                this.pageTitle = "选择位置"
            }
            // 初始化地址显示
            this.updatePickAddress(lat, lng)
            Hilog.info(0, "CjTelegram", "[InteractiveMapPage] pick mode: center lat=${lat} lng=${lng}")
            return
        }

        // 普通 view 模式
        let parts = paramStr.split("|")
        if (parts.size >= 2) {
            let lat = try { Float64.parse(parts[0]) } catch (_: Exception) { 39.9042 }
            let lng = try { Float64.parse(parts[1]) } catch (_: Exception) { 116.4074 }
            let title = if (parts.size >= 3) { parts[2] } else { "" }
            let zoom: Int32 = if (parts.size >= 4) {
                try { Int32.parse(parts[3]) } catch (_: Exception) { 15 }
            } else { 15 }
            launch {
                this.centerLat = lat
                this.centerLng = lng
                this.targetLat = lat
                this.targetLng = lng
                this.targetTitle = title
                this.hasTarget = true
                this.zoomLevel = zoom
                this.pageTitle = if (title.size > 0) { title } else { "位置" }
            }
            Hilog.info(0, "CjTelegram", "[InteractiveMapPage] param: lat=${lat} lng=${lng} zoom=${zoom}")
        }
    }

    /**
     * P2-181: 确认 pick 模式选中的位置（当前地图中心）
     */
    private func confirmPickLocation(): Unit {
        let lat = this.centerLat
        let lng = this.centerLng
        setMapPickResult(lat, lng)
        routerPop()
        Hilog.info(0, "CjTelegram", "[InteractiveMapPage] confirmPickLocation: lat=${lat} lng=${lng}")
    }

    /**
     * P2-181: 触发当前地图中心的反向地理编码，更新 pick 模式底部地址显示
     */
    private func updatePickAddress(lat: Float64, lng: Float64): Unit {
        if (!this.pickMode) { return }
        let capturedLat = lat
        let capturedLng = lng
        let _ = spawn {
            reverseGeocodeLocation(capturedLat, capturedLng, { addrOpt: Option<String> =>
                match (addrOpt) {
                    case Some(addr) => launch { this.pickAddressText = addr }
                    case None =>
                        let latStr = "${capturedLat}"
                        let lngStr = "${capturedLng}"
                        let sLat = if (latStr.size > 8) { latStr[0..8] } else { latStr }
                        let sLng = if (lngStr.size > 8) { lngStr[0..8] } else { lngStr }
                        launch { this.pickAddressText = sLat + ", " + sLng }
                }
            })
        }
    }

    // ==================== 地图快照加载 ====================

    private func loadSnapshot(): Unit {
        let lat = this.centerLat
        let lng = this.centerLng
        let zoom = this.zoomLevel
        this.loadSnapshotAt(lat, lng, zoom)
    }

    private func loadSnapshotAt(lat: Float64, lng: Float64, zoom: Int32): Unit {
        let w = this.snapshotWidth
        let h = this.snapshotHeight
        launch { this.isLoadingSnapshot = true }
        let _ = spawn {
            let svc = getLocationResourcesService()
            let result = svc.fetchMapSnapshot(lat, lng, w, h, zoom: zoom)
            if (result.success) {
                let path = result.localPath
                launch {
                    this.snapshotPath = path
                    this.isLoadingSnapshot = false
                    this.snapshotError = false
                }
                Hilog.info(0, "CjTelegram", "[InteractiveMapPage] snapshot loaded zoom=${zoom}")
            } else {
                launch {
                    this.isLoadingSnapshot = false
                    this.snapshotError = true
                }
                Hilog.info(0, "CjTelegram", "[InteractiveMapPage] snapshot failed")
            }
        }
    }

    // ==================== 用户位置 ====================

    private func loadUserLocation(): Unit {
        ensureLocationPermission({ granted: Bool =>
            if (granted) {
                let _ = spawn {
                    let result = getCurrentDeviceLocation()
                    if (result.success) {
                        let lat = result.latitude
                        let lng = result.longitude
                        launch {
                            this.userLat = lat
                            this.userLng = lng
                            this.hasUserLocation = true
                        }
                        // 计算到目标的距离
                        if (this.hasTarget) {
                            let tLat = this.targetLat
                            let tLng = this.targetLng
                            let svc = getLocationDistanceService()
                            let dist = svc.haversineDistance(lat, lng, tLat, tLng)
                            let bear = svc.bearing(lat, lng, tLat, tLng)
                            let distStr = svc.formatDistance(dist)
                            let bearStr = svc.formatBearing(bear)
                            launch {
                                this.distanceText = distStr
                                this.bearingText = bearStr
                            }
                        }
                        Hilog.info(0, "CjTelegram", "[InteractiveMapPage] user location: ${lat},${lng}")
                    }
                }
            }
        })
    }

    // ==================== 交互控制 ====================

    private func zoomIn(): Unit {
        if (this.zoomLevel >= 18) { return }
        let newZoom = this.zoomLevel + 1
        let curLat = this.centerLat
        let curLng = this.centerLng
        launch { this.zoomLevel = newZoom }
        this.loadSnapshotAt(curLat, curLng, newZoom)
        Hilog.info(0, "CjTelegram", "[InteractiveMapPage] zoomIn → ${newZoom}")
    }

    private func zoomOut(): Unit {
        if (this.zoomLevel <= 10) { return }
        let newZoom = this.zoomLevel - 1
        let curLat = this.centerLat
        let curLng = this.centerLng
        launch { this.zoomLevel = newZoom }
        this.loadSnapshotAt(curLat, curLng, newZoom)
        Hilog.info(0, "CjTelegram", "[InteractiveMapPage] zoomOut → ${newZoom}")
    }

    private func panStep(): Float64 {
        let base = 0.004
        var step = base
        var z: Int32 = 15
        while (z < this.zoomLevel) {
            step = step / 2.0
            z = z + 1
        }
        while (z > this.zoomLevel) {
            step = step * 2.0
            z = z - 1
        }
        return step
    }

    private func panUp(): Unit {
        let step = this.panStep()
        let newLat = this.centerLat + step
        let curLng = this.centerLng
        let curZoom = this.zoomLevel
        launch {
            this.centerLat = newLat
            this.trackingMode = false
        }
        this.loadSnapshotAt(newLat, curLng, curZoom)
        this.updatePickAddress(newLat, curLng)
    }

    private func panDown(): Unit {
        let step = this.panStep()
        let newLat = this.centerLat - step
        let curLng = this.centerLng
        let curZoom = this.zoomLevel
        launch {
            this.centerLat = newLat
            this.trackingMode = false
        }
        this.loadSnapshotAt(newLat, curLng, curZoom)
        this.updatePickAddress(newLat, curLng)
    }

    private func panLeft(): Unit {
        let step = this.panStep()
        let newLng = this.centerLng - step
        let curLat = this.centerLat
        let curZoom = this.zoomLevel
        launch {
            this.centerLng = newLng
            this.trackingMode = false
        }
        this.loadSnapshotAt(curLat, newLng, curZoom)
        this.updatePickAddress(curLat, newLng)
    }

    private func panRight(): Unit {
        let step = this.panStep()
        let newLng = this.centerLng + step
        let curLat = this.centerLat
        let curZoom = this.zoomLevel
        launch {
            this.centerLng = newLng
            this.trackingMode = false
        }
        this.loadSnapshotAt(curLat, newLng, curZoom)
        this.updatePickAddress(curLat, newLng)
    }

    private func toggleTrackingMode(): Unit {
        if (!this.hasUserLocation) {
            this.loadUserLocation()
            return
        }
        let newMode = !this.trackingMode
        launch { this.trackingMode = newMode }
        if (newMode) {
            let uLat = this.userLat
            let uLng = this.userLng
            let curZoom = this.zoomLevel
            launch {
                this.centerLat = uLat
                this.centerLng = uLng
            }
            this.loadSnapshotAt(uLat, uLng, curZoom)
        }
        Hilog.info(0, "CjTelegram", "[InteractiveMapPage] trackingMode=${newMode}")
    }

    // ==================== 导航 ====================

    private func openNavigation(): Unit {
        let svc = getLocationDistanceService()
        let label = if (this.targetTitle.size > 0) { this.targetTitle } else { this.buildTargetCoordText() }
        svc.openInMaps(this.targetLat, this.targetLng, label)
        Hilog.info(0, "CjTelegram", "[InteractiveMapPage] openNavigation")
    }

    // ==================== 辅助文本 ====================

    private func buildCoordText(): String {
        let latStr = "${this.centerLat}"
        let lngStr = "${this.centerLng}"
        let shortLat = if (latStr.size > 8) { latStr[0..8] } else { latStr }
        let shortLng = if (lngStr.size > 8) { lngStr[0..8] } else { lngStr }
        return shortLat + ", " + shortLng
    }

    private func buildTargetCoordText(): String {
        let latStr = "${this.targetLat}"
        let lngStr = "${this.targetLng}"
        let shortLat = if (latStr.size > 8) { latStr[0..8] } else { latStr }
        let shortLng = if (lngStr.size > 8) { lngStr[0..8] } else { lngStr }
        return shortLat + ", " + shortLng
    }
}
