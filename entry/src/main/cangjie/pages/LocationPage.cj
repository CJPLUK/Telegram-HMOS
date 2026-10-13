package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import std.time.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

import ohos_app_cangjie_entry.services.{
    ensureLocationPermission,
    getCurrentDeviceLocation,
    formatCoordinates,
    sendLocationMessage,
    getNearbyPeers,
    reverseGeocodeLocation,
    setSelectedChat,
    LocationResult,
    getLocationDistanceService,
    getSunriseSunsetService,
    getVenueSearchService,
    LIVE_LOCATION_INDEFINITE_PERIOD,
    consumeMapPickResult
}
import ohos_app_cangjie_entry.core.mtproto.{PeerNearbyEntry, PeersNearbyResult}
import ohos_app_cangjie_entry.viewmodels.LiveLocationManagerViewModel
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * LocationPage — 位置分享主页面 (Phase LOC-UI-1)
 *
 * 对应 iOS LocationPickerController / LocationViewController
 *
 * 功能:
 * - 获取真实 GPS 坐标（GeoLocationManager）
 * - 发送当前位置（静态位置消息，via RealMessageService.sendLocation）
 * - 发送实时位置（live location，15 分钟 / 1 小时 / 8 小时）
 * - 显示附近用户/群组（contacts.getLocated）
 * - 点击附近用户跳转至聊天
 *
 * 调用链:
 *   LocationPage.sendCurrentLocation → sendLocationMessage → RealMessageService.sendLocation → MTProtoClient.sendRequest
 *   LocationPage.loadNearby → getNearbyPeers → PeersNearbyService.getLocated → MTProtoClient.sendRequest
 *
 * D-002: 根容器为 NavDestination
 * S-64:  aboutToAppear 为 public，spawn 返回赋给 let _
 */
@HybridComponentEntry
@Component
public class LocationPage {
    @State var pageLoaded: Bool = false

    // 当前 GPS 状态
    @State var currentLat: Float64 = 0.0
    @State var currentLng: Float64 = 0.0
    @State var locationName: String = ""
    @State var isLoadingLocation: Bool = true
    @State var hasPermission: Bool = true
    @State var locationReady: Bool = false
    @State var locationError: String = ""

    // 目标对话（由来源页写入全局，或通过 pageStack param 传入）
    @State var targetPeerType: String = "user"
    @State var targetPeerId: Int64 = 0

    // 发送状态
    @State var isSending: Bool = false
    @State var sendResult: String = ""

    // 实时位置选项
    @State var showLiveDurationPicker: Bool = false
    // P2-185: 选中的时长（用于自定义/无限期）；-1=未选
    @State var selectedLivePeriod: Int32 = 900
    // P2-185: 是否显示自定义时长输入
    @State var showCustomDurationInput: Bool = false
    // P2-185: 自定义时长输入（分钟字符串）
    @State var customDurationMinutes: String = ""
    // P2-185: proximity 半径 UI（米）；0=不设置
    @State var proximityRadius: Int32 = 0
    @State var showProximityPicker: Bool = false

    // P2-185/186: Live location ViewModel（启动后台广播循环）
    var liveLocationVM: LiveLocationManagerViewModel = LiveLocationManagerViewModel()

    // P2-181: 地图拖选位置（用户从 InteractiveMapPage pick 模式返回后填入）
    @State var pickedLat: Float64 = 0.0
    @State var pickedLng: Float64 = 0.0
    @State var pickedAddress: String = ""
    // true = 发送 picked 坐标；false = 发送当前 GPS
    @State var usePickedLocation: Bool = false

    // 附近的人
    @State var nearbyUsers: ArrayList<PeerNearbyEntry> = ArrayList<PeerNearbyEntry>()
    @State var nearbyGroups: ArrayList<PeerNearbyEntry> = ArrayList<PeerNearbyEntry>()
    @State var isLoadingNearby: Bool = false

    // P2-191: 距离/方位/ETA (目标坐标，由选中的 venue 或接收的消息位置设置)
    @State var targetLat: Float64 = 0.0
    @State var targetLng: Float64 = 0.0
    @State var showDistanceInfo: Bool = false
    @State var distanceText: String = ""
    @State var bearingText: String = ""
    @State var walkTimeMin: Int32 = 0
    @State var driveTimeMin: Int32 = 0

    // P2-193: 昼夜判定
    @State var isDaytime: Bool = true
    @State var sunriseText: String = ""
    @State var sunsetText: String = ""

    private func ensureLoaded(): Unit {
        if (this.pageLoaded) { return }
        this.pageLoaded = true
        this.loadGPSLocation()
        this.loadSunriseSunset()
    }

    // ==================== 定位逻辑 ====================

    private func loadGPSLocation(): Unit {
        this.isLoadingLocation = true
        this.locationError = ""
        ensureLocationPermission({ granted: Bool =>
            if (granted) {
                launch { this.hasPermission = true }
                let _ = spawn {
                    let result = getCurrentDeviceLocation()
                    if (result.success) {
                        let lat = result.latitude
                        let lng = result.longitude
                        let coordName = formatCoordinates(lat, lng)
                        launch {
                            this.currentLat = lat
                            this.currentLng = lng
                            this.locationName = coordName
                            this.locationReady = true
                            this.isLoadingLocation = false
                        }
                        Hilog.info(0, "CjTelegram", "[LocationPage] GPS ready")
                        // P2-190: 反向地理编码坐标 → 地址
                        reverseGeocodeLocation(lat, lng, { addrOpt: Option<String> =>
                            match (addrOpt) {
                                case Some(addr) =>
                                    launch { this.locationName = addr }
                                    Hilog.info(0, "CjTelegram", "[LocationPage] reverseGeocode done: ${addr}")
                                case None =>
                                    Hilog.info(0, "CjTelegram", "[LocationPage] reverseGeocode: no result, keeping coords")
                            }
                        })
                    } else {
                        let errMsg = result.errorMessage
                        launch {
                            this.locationError = errMsg
                            this.isLoadingLocation = false
                        }
                        Hilog.info(0, "CjTelegram", "[LocationPage] GPS failed")
                    }
                }
            } else {
                launch {
                    this.hasPermission = false
                    this.isLoadingLocation = false
                }
                Hilog.info(0, "CjTelegram", "[LocationPage] Permission denied")
            }
        })
    }

    // ==================== 发送位置 ====================

    /**
     * P2-181 gap fix: 发送位置
     *
     * 位置优先级：
     *   1. usePickedLocation=true → 发送用户从地图拖选的坐标（pickedLat/pickedLng）
     *   2. 否则 → 发送当前 GPS 坐标（currentLat/currentLng）
     *
     * 对应 iOS LocationPickerController.sendLocation(coordinate:address:)
     */
    private func sendCurrentLocation(): Unit {
        if (this.isSending) { return }
        // P2-181: 选择发送坐标（优先使用地图拖选）
        let lat: Float64
        let lng: Float64
        if (this.usePickedLocation && (this.pickedLat != 0.0 || this.pickedLng != 0.0)) {
            lat = this.pickedLat
            lng = this.pickedLng
        } else if (this.locationReady) {
            lat = this.currentLat
            lng = this.currentLng
        } else {
            return
        }
        let pType = this.targetPeerType
        let pId = this.targetPeerId
        launch { this.isSending = true }
        let _ = spawn {
            let ok = sendLocationMessage(pType, pId, lat, lng)
            launch {
                this.isSending = false
                this.sendResult = if (ok) { "位置已发送" } else { "发送失败" }
            }
            Hilog.info(0, "CjTelegram", "[LocationPage] sendCurrentLocation done, ok=" + if (ok) { "true" } else { "false" })
        }
    }

    /**
     * P2-181: 打开 InteractiveMapPage 的 pick 模式
     * 导航到 InteractiveMapPage，传入 pick 模式路由参数
     */
    private func openMapPicker(): Unit {
        let startLat = if (this.locationReady) { this.currentLat } else { 39.9042 }
        let startLng = if (this.locationReady) { this.currentLng } else { 116.4074 }
        routerPush("InteractiveMapPage", "pick:${startLat}|${startLng}")
        Hilog.info(0, "CjTelegram", "[LocationPage] openMapPicker: start lat=${startLat} lng=${startLng}")
    }

    /**
     * P2-181: 检查地图拖选结果（从 InteractiveMapPage pop 返回后触发）
     * 对应 iOS LocationPickerController.completion callback
     */
    private func checkPickResult(): Unit {
        let resultOpt = consumeMapPickResult()
        match (resultOpt) {
            case Some(pair) =>
                let (lat, lng) = pair
                launch {
                    this.pickedLat = lat
                    this.pickedLng = lng
                    this.usePickedLocation = true
                    this.pickedAddress = "正在获取地址..."
                }
                Hilog.info(0, "CjTelegram", "[LocationPage] map pick result: lat=${lat} lng=${lng}")
                // 反向地理编码选中坐标
                reverseGeocodeLocation(lat, lng, { addrOpt: Option<String> =>
                    match (addrOpt) {
                        case Some(addr) => launch { this.pickedAddress = addr }
                        case None =>
                            let latStr = "${lat}"
                            let lngStr = "${lng}"
                            let sLat = if (latStr.size > 8) { latStr[0..8] } else { latStr }
                            let sLng = if (lngStr.size > 8) { lngStr[0..8] } else { lngStr }
                            launch { this.pickedAddress = sLat + ", " + sLng }
                    }
                })
            case None => ()
        }
    }

    /**
     * P2-185 fix: 发送实时位置并启动后台广播循环
     *
     * 调用链:
     *   sendLiveLocation(period)
     *     → LiveLocationManagerViewModel.startSharing(peerType, peerId, period:)
     *       → Step 1: DeviceLocationManagerService.requestLocation → 获取初始坐标
     *       → Step 2: RealMessageService.sendLiveLocation → messages.sendMedia(inputMediaGeoLive) → 获取 msgId
     *       → Step 3: LiveLocationManagerService.startLiveLocationBroadcast → 启动后台广播循环
     *                  broadcastLoop: 每 4 秒 GeoLocationManager.getCurrentLocation() → editMessage+heading
     *
     * gap 修复: 原来只调 sendLiveLocationMessage() 发消息后直接返回，广播循环从未启动。
     * 现在通过 LiveLocationManagerViewModel.startSharing() 完整执行三步流程。
     */
    private func sendLiveLocation(period: Int32): Unit {
        if (!this.locationReady || this.isSending) { return }
        let pType = this.targetPeerType
        let pId = this.targetPeerId
        let capturedPeriod = period
        launch {
            this.isSending = true
            this.showLiveDurationPicker = false
            this.showCustomDurationInput = false
            this.showProximityPicker = false
        }
        // P2-185: Use LiveLocationManagerViewModel.startSharing() which:
        // 1. Gets location → 2. Sends sendMedia(inputMediaGeoLive) → 3. Starts broadcast loop
        this.liveLocationVM.startSharing(pType, pId, period: capturedPeriod)
        launch {
            this.isSending = false
            this.sendResult = "实时位置分享中"
        }
        Hilog.info(0, "CjTelegram", "[LocationPage] sendLiveLocation started: peer=${pType}/${pId} period=${capturedPeriod}")
    }

    /**
     * P2-185: 解析自定义时长输入 → Int32 秒
     * 用户输入分钟数，转换为秒；无效输入默认 900s
     */
    private func parseCustomDurationSeconds(): Int32 {
        if (this.customDurationMinutes.size == 0) { return 900 }
        var result: Int32 = 0
        var valid = true
        for (ch in this.customDurationMinutes.toRuneArray()) {
            if (ch.isAsciiNumber()) {
                let cp = Int32(UInt32(ch))
                result = result * 10 + cp - 48
            } else {
                valid = false
                break
            }
        }
        if (!valid || result <= 0) { return 900 }
        return result * 60
    }

    // ==================== 附近的人 ====================

    private func loadNearbyPeers(): Unit {
        if (!this.locationReady) { return }
        let lat = this.currentLat
        let lng = this.currentLng
        launch { this.isLoadingNearby = true }
        let _ = spawn {
            let result = getNearbyPeers(lat, lng)
            let users = result.nearbyUsers
            let groups = result.nearbyGroups
            launch {
                this.nearbyUsers = users
                this.nearbyGroups = groups
                this.isLoadingNearby = false
            }
            Hilog.info(0, "CjTelegram", "[LocationPage] nearby loaded")
        }
    }

    private func openNearbyChat(entry: PeerNearbyEntry): Unit {
        setSelectedChat(entry.peerId, entry.displayName, entry.peerType)
        routerPush("ChatRoomPage", entry.displayName)
    }

    /**
     * 设置目标坐标 (P2-191 供外部或测试调用)
     * 写入 targetLat / targetLng 后触发距离计算
     */
    public func setTarget(lat: Float64, lng: Float64): Unit {
        launch {
            this.targetLat = lat
            this.targetLng = lng
            this.showDistanceInfo = false
        }
        this.calcDistanceToTarget()
    }

    // ==================== P2-191: 距离/方位/ETA ====================

    /**
     * 计算当前位置到目标位置的距离/方位/ETA
     * 调用链: calcDistanceToTarget → getLocationDistanceService().haversineDistance / bearing
     */
    func calcDistanceToTarget(): Unit {
        if (!this.locationReady || (this.targetLat == 0.0 && this.targetLng == 0.0)) { return }
        let lat1 = this.currentLat
        let lng1 = this.currentLng
        let lat2 = this.targetLat
        let lng2 = this.targetLng
        let _ = spawn {
            let svc = getLocationDistanceService()
            let dist = svc.haversineDistance(lat1, lng1, lat2, lng2)
            let bear = svc.bearing(lat1, lng1, lat2, lng2)
            let walkMin = svc.estimatedWalkTime(dist)
            let driveMin = svc.estimatedDriveTime(dist)
            let distStr = svc.formatDistance(dist)
            let bearStr = svc.formatBearing(bear)
            launch {
                this.distanceText = distStr
                this.bearingText = bearStr
                this.walkTimeMin = walkMin
                this.driveTimeMin = driveMin
                this.showDistanceInfo = true
            }
            Hilog.info(0, "CjTelegram", "[LocationPage] dist=${dist}m bear=${bear}°")
        }
    }

    /**
     * 打开地图应用（geo: intent）
     * 调用链: openInMaps → getLocationDistanceService().openInMaps
     */
    func openInMapsForTarget(): Unit {
        let lat = if (this.targetLat != 0.0) { this.targetLat } else { this.currentLat }
        let lng = if (this.targetLng != 0.0) { this.targetLng } else { this.currentLng }
        let svc = getLocationDistanceService()
        svc.openInMaps(lat, lng, "目的地")
        Hilog.info(0, "CjTelegram", "[LocationPage] openInMaps lat=${lat} lng=${lng}")
    }

    /**
     * 跳转到 venue 选择页 (P2-184)
     */
    func openVenuePicker(): Unit {
        routerPush("VenuePickerPage", "venue")
    }

    // ==================== P2-193: 日出日落 ====================

    /**
     * 加载日出日落信息（当前 GPS 坐标）
     * 调用链: loadSunriseSunset → getSunriseSunsetService().calculateSunriseSunset / isDaytime
     */
    private func loadSunriseSunset(): Unit {
        let lat = this.currentLat
        let lng = this.currentLng
        let _ = spawn {
            let svc = getSunriseSunsetService()
            let daytime = svc.isDaytime(lat, lng)
            // 今日日出日落文本 (UTC)
            let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let (year, month, day) = extractDateFromMs(nowMs)
            let result = svc.calculateSunriseSunset(lat, lng, year, month, day)
            let riseStr: String
            let setStr: String
            if (result.returnCode > 0) {
                riseStr = "极昼"
                setStr = "极昼"
            } else if (result.returnCode < 0) {
                riseStr = "极夜"
                setStr = "极夜"
            } else {
                riseStr = svc.formatHourMinute(result.sunriseHoursUT) + " UTC"
                setStr = svc.formatHourMinute(result.sunsetHoursUT) + " UTC"
            }
            launch {
                this.isDaytime = daytime
                this.sunriseText = riseStr
                this.sunsetText = setStr
            }
            Hilog.info(0, "CjTelegram", "[LocationPage] sunrise=${riseStr} sunset=${setStr} daytime=${daytime}")
        }
    }

    // ==================== 辅助方法 ====================

    private func getLocationStatusText(): String {
        if (this.isLoadingLocation) { return "正在获取位置..." }
        if (!this.hasPermission) { return "未授权位置权限" }
        if (this.locationError.size > 0) { return this.locationError }
        if (this.locationReady) { return this.locationName }
        return "等待 GPS"
    }

    private func getLiveDurationLabel(seconds: Int32): String {
        if (seconds == 900) { return "15 分钟" }
        if (seconds == 3600) { return "1 小时" }
        if (seconds == 28800) { return "8 小时" }
        if (seconds == LIVE_LOCATION_INDEFINITE_PERIOD) { return "无限期" }
        if (seconds >= 3600) {
            let h = seconds / 3600
            return "${h} 小时"
        }
        let mins = seconds / 60
        if (mins > 0) { return "${mins} 分钟" }
        return "${seconds} 秒"
    }

    private func getProximityLabel(meters: Int32): String {
        if (meters == 0) { return "不通知" }
        if (meters >= 1000) {
            let km = meters / 1000
            return "${km} km"
        }
        return "${meters} m"
    }

    private func formatDistanceText(meters: Int32): String {
        if (meters <= 0) { return "" }
        if (meters < 1000) { return "${meters} m" }
        let km = Float64(meters) / 1000.0
        return "${km} km"
    }

    // ==================== UI ====================

    public func build() {
        Column {
                // 导航栏
                Row {
                    Text("← 返回")
                        .fontSize(17)
                        .fontColor(0x0088CC)
                        .onClick({ evt =>
                            routerPop()
                        })

                    Blank()

                    Text("位置")
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)

                    Blank()
                    Row {}.width(60)
                }
                .width(100.percent)
                .height(56.0 + getSafeAreaTop())
                .padding(left: 16, right: 16, top: getSafeAreaTop())
                .backgroundColor(0xFFFFFF)
                .alignItems(VerticalAlign.Center)

                // GPS 状态区域
                Column {
                    if (this.isLoadingLocation) {
                        LoadingProgress()
                            .width(40)
                            .height(40)
                            .color(0x0088CC)
                        Text("正在获取位置...")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .margin(top: 8)
                    } else {
                        if (!this.hasPermission) {
                            // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
                            Image(@r(app.media.loc_ic_maprow))
                                .width(36)
                                .height(36)
                                .fillColor(0xFF3B30)
                            Text("需要位置权限")
                                .fontSize(16)
                                .fontColor(0xFF3B30)
                                .margin(top: 8)
                            Text("重新请求权限")
                                .fontSize(15)
                                .fontColor(0x0088CC)
                                .margin(top: 12)
                                .onClick({ evt =>
                                    this.loadGPSLocation()
                                })
                        } else {
                            // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
                            Image(@r(app.media.loc_ic_maprow))
                                .width(40)
                                .height(40)
                                .fillColor(0x0088CC)
                            Text(this.getLocationStatusText())
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                                .margin(top: 8)
                            if (this.locationReady) {
                                Text("Lat: " + this.currentLat.toString() + "  Lng: " + this.currentLng.toString())
                                    .fontSize(12)
                                    .fontColor(0xC7C7CC)
                                    .margin(top: 4)
                            }
                        }
                    }
                }
                .width(100.percent)
                .height(160)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0xE8E8E8)

                // 发送结果提示
                if (this.sendResult.size > 0) {
                    Text(this.sendResult)
                        .fontSize(13)
                        .fontColor(if (this.sendResult == "位置已发送" || this.sendResult == "实时位置已发送") { 0x34C759 } else { 0xFF3B30 })
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .width(100.percent)
                        .backgroundColor(0xF2F2F7)
                }

                // 操作按钮
                Column {
                    // 发送当前位置
                    Row {
                        // 资源保真修复：真实矢量图标（Location/SendLocationIcon.imageset/ic_mappin.pdf 转 SVG）替代 emoji 字形
                        Image(@r(app.media.loc_ic_sendlocation))
                            .width(20)
                            .height(20)
                            .fillColor(if (this.locationReady && !this.isSending) { 0x0088CC } else { 0xC7C7CC })
                            .margin(right: 12)
                        Column {
                            Text("发送当前位置")
                                .fontSize(17)
                                .fontColor(if (this.locationReady && !this.isSending) { 0x000000 } else { 0xC7C7CC })
                            Text(this.getLocationStatusText())
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(top: 2)
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)

                        if (this.isSending) {
                            LoadingProgress()
                                .width(20)
                                .height(20)
                                .color(0x0088CC)
                        }
                    }
                    .width(100.percent)
                    .height(64)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ evt =>
                        this.sendCurrentLocation()
                    })

                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                    // P2-181 gap fix: 从地图选择位置（交互地图拖选）
                    // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
                    Row {
                        Image(@r(app.media.loc_ic_maprow))
                            .width(20)
                            .height(20)
                            .fillColor(0x0088CC)
                            .margin(right: 12)
                        Column {
                            Text("从地图选择位置")
                                .fontSize(17)
                                .fontColor(0x000000)
                            // 显示已选地址（从 InteractiveMapPage pick 模式返回后）
                            if (this.usePickedLocation && this.pickedAddress.size > 0) {
                                Text(this.pickedAddress)
                                    .fontSize(13)
                                    .fontColor(0x34C759)
                                    .margin(top: 2)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                            } else {
                                Text("在地图上拖拽选择精确位置")
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 2)
                            }
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)
                        Text("›")
                            .fontSize(20)
                            .fontColor(0xC7C7CC)
                    }
                    .width(100.percent)
                    .height(64)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _evt =>
                        this.openMapPicker()
                    })

                    // P2-181: 若已选地图坐标，显示"发送选中位置"快捷按钮
                    if (this.usePickedLocation && (this.pickedLat != 0.0 || this.pickedLng != 0.0)) {
                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)
                        // 资源保真修复：真实矢量图标（Location/SendLocationIcon.imageset/ic_mappin.pdf 转 SVG）替代 emoji 字形
                        Row {
                            Image(@r(app.media.loc_ic_sendlocation))
                                .width(20)
                                .height(20)
                                .fillColor(if (!this.isSending) { 0x317AFF } else { 0xC7C7CC })
                                .margin(right: 12)
                            Column {
                                Text("发送选中位置")
                                    .fontSize(17)
                                    .fontColor(if (!this.isSending) { 0x317AFF } else { 0xC7C7CC })
                                Text(this.pickedAddress)
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 2)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                            }
                            .alignItems(HorizontalAlign.Start)
                            .layoutWeight(1)
                            if (this.isSending) {
                                LoadingProgress()
                                    .width(20)
                                    .height(20)
                                    .color(0x317AFF)
                            }
                        }
                        .width(100.percent)
                        .height(64)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _evt =>
                            if (!this.isSending) {
                                this.sendCurrentLocation()
                            }
                        })
                    }

                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                    // 实时位置
                    // 资源保真修复：真实矢量图标（Location/SendLiveLocationIcon.imageset/ic_mappinlive.pdf 转 SVG）替代 emoji 字形
                    Row {
                        Image(@r(app.media.loc_ic_sendlive))
                            .width(20)
                            .height(20)
                            .fillColor(if (this.locationReady && !this.isSending) { 0x34C759 } else { 0xC7C7CC })
                            .margin(right: 12)
                        Column {
                            Text("分享实时位置")
                                .fontSize(17)
                                .fontColor(if (this.locationReady && !this.isSending) { 0x000000 } else { 0xC7C7CC })
                            Text("对方可实时看到您的位置")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(top: 2)
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)

                        Text(if (this.showLiveDurationPicker) { "▲" } else { "▼" })
                            .fontSize(12)
                            .fontColor(0xC7C7CC)
                    }
                    .width(100.percent)
                    .height(64)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ evt =>
                        if (this.locationReady) {
                            this.showLiveDurationPicker = !this.showLiveDurationPicker
                        }
                    })

                    // P2-185: 实时位置持续时间选项（15m / 1h / 8h / 自定义 / 无限期）
                    if (this.showLiveDurationPicker) {
                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                        // 资源保真修复：真实矢量图标（Item List/Icons/Clock.imageset/clock.pdf 转 SVG）替代 emoji 字形
                        Row {
                            Image(@r(app.media.loc_ic_clock))
                                .width(16)
                                .height(16)
                                .fillColor(0x0088CC)
                                .margin(left: 8, right: 12)
                            Text(this.getLiveDurationLabel(900))
                                .fontSize(16)
                                .fontColor(if (this.selectedLivePeriod == 900) { 0x317AFF } else { 0x0088CC })
                                .fontWeight(if (this.selectedLivePeriod == 900) { FontWeight.Bold } else { FontWeight.Normal })
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 48, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(0xF8F8F8)
                        .onClick({ _evt =>
                            this.selectedLivePeriod = 900
                            this.sendLiveLocation(900)
                        })

                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                        // 资源保真修复：真实矢量图标（Item List/Icons/Clock.imageset/clock.pdf 转 SVG）替代 emoji 字形
                        Row {
                            Image(@r(app.media.loc_ic_clock))
                                .width(16)
                                .height(16)
                                .fillColor(0x0088CC)
                                .margin(left: 8, right: 12)
                            Text(this.getLiveDurationLabel(3600))
                                .fontSize(16)
                                .fontColor(if (this.selectedLivePeriod == 3600) { 0x317AFF } else { 0x0088CC })
                                .fontWeight(if (this.selectedLivePeriod == 3600) { FontWeight.Bold } else { FontWeight.Normal })
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 48, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(0xF8F8F8)
                        .onClick({ _evt =>
                            this.selectedLivePeriod = 3600
                            this.sendLiveLocation(3600)
                        })

                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                        // 资源保真修复：真实矢量图标（Item List/Icons/Clock.imageset/clock.pdf 转 SVG）替代 emoji 字形
                        Row {
                            Image(@r(app.media.loc_ic_clock))
                                .width(16)
                                .height(16)
                                .fillColor(0x0088CC)
                                .margin(left: 8, right: 12)
                            Text(this.getLiveDurationLabel(28800))
                                .fontSize(16)
                                .fontColor(if (this.selectedLivePeriod == 28800) { 0x317AFF } else { 0x0088CC })
                                .fontWeight(if (this.selectedLivePeriod == 28800) { FontWeight.Bold } else { FontWeight.Normal })
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 48, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(0xF8F8F8)
                        .onClick({ _evt =>
                            this.selectedLivePeriod = 28800
                            this.sendLiveLocation(28800)
                        })

                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                        // P2-185: 自定义时长选项
                        // 资源保真修复：真实矢量图标（Item List/Icons/Clock.imageset/clock.pdf 转 SVG）替代 emoji 字形
                        Row {
                            Image(@r(app.media.loc_ic_clock))
                                .width(16)
                                .height(16)
                                .fillColor(0x0088CC)
                                .margin(left: 8, right: 12)
                            Text("自定义时长")
                                .fontSize(16)
                                .fontColor(0x0088CC)
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 48, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(0xF8F8F8)
                        .onClick({ _evt =>
                            this.showCustomDurationInput = !this.showCustomDurationInput
                        })

                        if (this.showCustomDurationInput) {
                            Row {
                                TextInput(placeholder: "分钟数")
                                    .width(120)
                                    .height(36)
                                    .margin(left: 48, right: 12)
                                    .onChange({ val: String =>
                                        this.customDurationMinutes = val
                                    })
                                Text("分钟")
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                                    .margin(right: 12)
                                Text("确定")
                                    .fontSize(15)
                                    .fontColor(0x0088CC)
                                    .onClick({ _evt =>
                                        let secs = this.parseCustomDurationSeconds()
                                        this.selectedLivePeriod = secs
                                        this.sendLiveLocation(secs)
                                    })
                            }
                            .width(100.percent)
                            .height(52)
                            .padding(right: 16)
                            .alignItems(VerticalAlign.Center)
                            .backgroundColor(0xF0F0F0)
                        }

                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                        // P2-185: 无限期分享选项 (liveLocationIndefinitePeriod = 0x7fffffff)
                        Row {
                            Text("∞")
                                .fontSize(18)
                                .fontColor(0x0088CC)
                                .margin(left: 8, right: 12)
                            Text("无限期分享")
                                .fontSize(16)
                                .fontColor(if (this.selectedLivePeriod == LIVE_LOCATION_INDEFINITE_PERIOD) { 0x317AFF } else { 0x0088CC })
                                .fontWeight(if (this.selectedLivePeriod == LIVE_LOCATION_INDEFINITE_PERIOD) { FontWeight.Bold } else { FontWeight.Normal })
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 48, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(0xF8F8F8)
                        .onClick({ _evt =>
                            this.selectedLivePeriod = LIVE_LOCATION_INDEFINITE_PERIOD
                            this.sendLiveLocation(LIVE_LOCATION_INDEFINITE_PERIOD)
                        })

                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                        // P2-185: proximity 半径 UI
                        // 资源保真修复：真实矢量图标（Location/ProximityIcon.imageset/ic_mapnotify.pdf 转 SVG）替代 emoji 字形
                        Row {
                            Image(@r(app.media.loc_ic_proximity))
                                .width(16)
                                .height(16)
                                .fillColor(0x333333)
                                .margin(left: 8, right: 12)
                            Text("接近通知半径: " + this.getProximityLabel(this.proximityRadius))
                                .fontSize(15)
                                .fontColor(0x333333)
                            Blank()
                            Text(if (this.showProximityPicker) { "▲" } else { "▼" })
                                .fontSize(12)
                                .fontColor(0xC7C7CC)
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 48, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(0xF8F8F8)
                        .onClick({ _evt =>
                            this.showProximityPicker = !this.showProximityPicker
                        })

                        if (this.showProximityPicker) {
                            Column {
                                ForEach([Int32(0), Int32(100), Int32(500), Int32(1000), Int32(3000)], itemGenerator: { dist: Int32, _idx: Int64 =>
                                    Row {
                                        Text(this.getProximityLabel(dist))
                                            .fontSize(15)
                                            .fontColor(if (this.proximityRadius == dist) { 0x317AFF } else { 0x333333 })
                                            .fontWeight(if (this.proximityRadius == dist) { FontWeight.Bold } else { FontWeight.Normal })
                                    }
                                    .width(100.percent)
                                    .height(44)
                                    .padding(left: 64, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .backgroundColor(if (this.proximityRadius == dist) { 0xE8F0FE } else { 0xF0F0F0 })
                                    .onClick({ _evt2 =>
                                        this.proximityRadius = dist
                                        this.showProximityPicker = false
                                    })
                                })
                            }
                            .width(100.percent)
                        }
                    }
                }
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, top: 16)

                // P2-191: 距离/方位/路线/open-in-maps 区域
                Column {
                    // 场所搜索入口
                    // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
                    // （无专用店铺/场所类 iOS 图标资产；场所搜索本质是位置搜索，复用 location pin 语义最贴近）
                    Row {
                        Image(@r(app.media.loc_ic_maprow))
                            .width(20)
                            .height(20)
                            .fillColor(if (this.locationReady) { 0x000000 } else { 0xC7C7CC })
                            .margin(right: 12)
                        Text("搜索附近场所")
                            .fontSize(17)
                            .fontColor(if (this.locationReady) { 0x000000 } else { 0xC7C7CC })
                        Blank()
                        Text("›")
                            .fontSize(20)
                            .fontColor(0xC7C7CC)
                    }
                    .width(100.percent)
                    .height(56)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _evt =>
                        if (this.locationReady) {
                            this.openVenuePicker()
                        }
                    })

                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                    // Get Directions / open-in-maps
                    // 资源保真修复：真实矢量图标（Location/GoTo.imageset/goto.pdf 转 SVG）替代 emoji 字形
                    Row {
                        Image(@r(app.media.loc_ic_goto))
                            .width(20)
                            .height(20)
                            .fillColor(if (this.locationReady) { 0x000000 } else { 0xC7C7CC })
                            .margin(right: 12)
                        Text("在地图中打开")
                            .fontSize(17)
                            .fontColor(if (this.locationReady) { 0x000000 } else { 0xC7C7CC })
                        Blank()
                        Text("›")
                            .fontSize(20)
                            .fontColor(0xC7C7CC)
                    }
                    .width(100.percent)
                    .height(56)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _evt =>
                        if (this.locationReady) {
                            this.openInMapsForTarget()
                        }
                    })

                    // 距离/方位/ETA 展示（有目标坐标时显示）
                    if (this.showDistanceInfo) {
                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                        Column {
                            Row {
                                Text("距离:")
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                                    .margin(right: 6)
                                Text(this.distanceText)
                                    .fontSize(14)
                                    .fontColor(0x000000)
                                Text("  " + this.bearingText)
                                    .fontSize(14)
                                    .fontColor(0x0088CC)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 6)

                            Row {
                                Text("步行约 " + "${this.walkTimeMin}" + " 分钟")
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(right: 16)
                                Text("驾车约 " + "${this.driveTimeMin}" + " 分钟")
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 2, bottom: 8)
                        }
                    }
                }
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, top: 12)

                // P2-193: 日出日落信息区域
                if (this.sunriseText.size > 0) {
                    Column {
                        Row {
                            Text(if (this.isDaytime) { "☀️" } else { "🌙" })
                                .fontSize(18)
                                .margin(right: 8)
                            Text(if (this.isDaytime) { "白天" } else { "夜间" })
                                .fontSize(15)
                                .fontColor(if (this.isDaytime) { 0xF59E0B } else { 0x6366F1 })
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 4)

                        Row {
                            Text("日出")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(right: 4)
                            Text(this.sunriseText)
                                .fontSize(13)
                                .fontColor(0x000000)
                            Text("  日落")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(right: 4)
                            Text(this.sunsetText)
                                .fontSize(13)
                                .fontColor(0x000000)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, bottom: 8)
                    }
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16, top: 12)
                }

                // 附近的人区域
                Column {
                    Row {
                        Text("附近的人")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                        Blank()
                        if (this.isLoadingNearby) {
                            LoadingProgress()
                                .width(16)
                                .height(16)
                                .color(0x8E8E93)
                        } else {
                            Text("刷新")
                                .fontSize(13)
                                .fontColor(0x0088CC)
                                .onClick({ evt =>
                                    this.loadNearbyPeers()
                                })
                        }
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 8, bottom: 4)

                    if (this.nearbyUsers.size == 0 && this.nearbyGroups.size == 0 && !this.isLoadingNearby) {
                        if (!this.locationReady) {
                            Text("等待 GPS 定位后可查看附近的人")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .padding(left: 16, right: 16, top: 8, bottom: 8)
                        } else {
                            Text("附近暂无用户")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .padding(left: 16, right: 16, top: 8, bottom: 8)
                        }
                    } else {
                        List {
                            ForEach(this.nearbyUsers, itemGenerator: { entry: PeerNearbyEntry, idx: Int64 =>
                                ListItem {
                                    Row {
                                        Text("👤")
                                            .fontSize(20)
                                            .margin(right: 12)
                                        Column {
                                            Text(entry.displayName)
                                                .fontSize(16)
                                                .fontColor(0x000000)
                                            Text(this.formatDistanceText(entry.distance))
                                                .fontSize(13)
                                                .fontColor(0x8E8E93)
                                                .margin(top: 2)
                                        }
                                        .alignItems(HorizontalAlign.Start)
                                        .layoutWeight(1)
                                    }
                                    .width(100.percent)
                                    .height(56)
                                    .padding(left: 16, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ evt =>
                                        this.openNearbyChat(entry)
                                    })
                                }
                            })

                            ForEach(this.nearbyGroups, itemGenerator: { entry: PeerNearbyEntry, idx: Int64 =>
                                ListItem {
                                    Row {
                                        Text("👥")
                                            .fontSize(20)
                                            .margin(right: 12)
                                        Column {
                                            Text(entry.displayName)
                                                .fontSize(16)
                                                .fontColor(0x000000)
                                            Text(this.formatDistanceText(entry.distance))
                                                .fontSize(13)
                                                .fontColor(0x8E8E93)
                                                .margin(top: 2)
                                        }
                                        .alignItems(HorizontalAlign.Start)
                                        .layoutWeight(1)
                                    }
                                    .width(100.percent)
                                    .height(56)
                                    .padding(left: 16, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ evt =>
                                        this.openNearbyChat(entry)
                                    })
                                }
                            })
                        }
                        .width(100.percent)
                        .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 48, endMargin: 0))
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 0, right: 0)
                    }
                }
                .margin(left: 16, right: 16, top: 20, bottom: 16)
            }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        // P2-181 gap fix: 当从 InteractiveMapPage pick 模式返回时，检查拖选结果
        // onVisibleAreaChange(ratioThreshold, handler): fires when visibility changes
        // ratio=1.0 means fully visible (page came back into focus)
        .onVisibleAreaChange([0.0, 1.0], { isVisible: Bool, ratio: Float64 =>
            if (isVisible && ratio > 0.9) {
                this.checkPickResult()
            }
        })
        .onAppear({ => this.ensureLoaded() })
    }
}

/**
 * 毫秒时间戳 → (year, month, day) UTC
 * 供 LocationPage.loadSunriseSunset 使用 (复用 SunriseSunsetService 内部算法)
 */
func extractDateFromMs(ms: Int64): (Int32, Int32, Int32) {
    let daysSince1970 = ms / 1000 / 86400
    let jd = daysSince1970 + 2440588
    let z = jd
    let alpha = (Float64(z) - 1867216.25) / 36524.25
    let alphaInt = Int64(alpha)
    let a: Int64
    if (z < 2299161) {
        a = z
    } else {
        a = z + 1 + alphaInt - alphaInt / 4
    }
    let b = a + 1524
    let c = Int64((Float64(b) - 122.1) / 365.25)
    let d = Int64(365.25 * Float64(c))
    let e = Int64(Float64(b - d) / 30.6001)
    let day = Int32(b - d - Int64(30.6001 * Float64(e)))
    let month: Int32 = if (e < 14) { Int32(e - 1) } else { Int32(e - 13) }
    let year: Int32 = if (month > 2) { Int32(c - 4716) } else { Int32(c - 4715) }
    return (year, month, day)
}
