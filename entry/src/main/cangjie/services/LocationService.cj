package ohos_app_cangjie_entry.services

import kit.AbilityKit.*
import kit.LocationKit.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.business_exception.BusinessException
import ohos_app_cangjie_entry.core.mtproto.{PeersNearbyResult}

/**
 * LocationService — 位置服务 (Phase LOC)
 * 
 * LOC-1: 位置权限检查与动态申请
 * LOC-2: GPS 定位 + 反向地理编码（待 LocationKit 集成）
 * 
 * 权限要求:
 * - ohos.permission.APPROXIMATELY_LOCATION（模糊位置）
 * - ohos.permission.LOCATION（精确位置）
 */

// 权限状态枚举
public enum LocationPermissionStatus {
    | Granted
    | Denied
    | NotRequested
    | Error
}

// 定位结果数据类
public class LocationResult {
    public var success: Bool = false
    public var latitude: Float64 = 0.0
    public var longitude: Float64 = 0.0
    public var altitude: Float64 = 0.0
    public var accuracy: Float64 = 0.0
    public var addressName: String = ""
    public var errorMessage: String = ""
    // P2-180: 设备航向方向（度，0-360）; -1.0 = 无有效方向
    // 对应 iOS CLLocation.course (equivalent: HarmonyOS Location.direction)
    public var directionDegrees: Float64 = -1.0

    public init() {}

    public init(lat: Float64, lng: Float64) {
        this.success = true
        this.latitude = lat
        this.longitude = lng
    }
}

// ==================== 权限管理 (LOC-1) ====================

/**
 * 检查位置权限是否已授权
 */
public func checkLocationPermission(): LocationPermissionStatus {
    try {
        let atManager = AbilityAccessCtrl.createAtManager()
        let bundleInfo = BundleManager.getBundleInfoForSelf(BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
        let tokenID = bundleInfo.appInfo.accessTokenId

        let approxGranted = atManager.checkAccessToken(tokenID, "ohos.permission.APPROXIMATELY_LOCATION")
        if (approxGranted == GrantStatus.PermissionGranted) {
            Hilog.info(0, "CjTelegram", "[LocationService] APPROXIMATELY_LOCATION granted")
            let preciseGranted = atManager.checkAccessToken(tokenID, "ohos.permission.LOCATION")
            if (preciseGranted == GrantStatus.PermissionGranted) {
                Hilog.info(0, "CjTelegram", "[LocationService] LOCATION (precise) granted")
            }
            return LocationPermissionStatus.Granted
        } else {
            Hilog.info(0, "CjTelegram", "[LocationService] APPROXIMATELY_LOCATION not granted")
            return LocationPermissionStatus.Denied
        }
    } catch (e: BusinessException) {
        Hilog.info(0, "CjTelegram", "[LocationService] checkPermission BusinessException: ${e.message}")
        return LocationPermissionStatus.Error
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[LocationService] checkPermission Exception: ${e}")
        return LocationPermissionStatus.Error
    }
}

/**
 * 动态申请位置权限
 * @param onResult 授权结果回调: true=已授权, false=用户拒绝
 */
public func requestLocationPermission(onResult: (Bool) -> Unit): Unit {
    match (getGlobalAbilityContext()) {
        case Some(context) =>
            Hilog.info(0, "CjTelegram", "[LocationService] Requesting location permissions...")
            let atManager = AbilityAccessCtrl.createAtManager()
            let permissions: Array<String> = [
                "ohos.permission.APPROXIMATELY_LOCATION",
                "ohos.permission.LOCATION"
            ]
            try {
                atManager.requestPermissionsFromUser(
                    context,
                    permissions,
                    { errorCode: Option<BusinessException>, data: Option<PermissionRequestResult> =>
                        match (errorCode) {
                            case Some(e) =>
                                Hilog.info(0, "CjTelegram", "[LocationService] requestPermission error: ${e.message}")
                                onResult(false)
                            case _ =>
                                match (data) {
                                    case Some(result) =>
                                        var approxGranted = false
                                        for (i in 0..result.authResults.size) {
                                            if (result.authResults[i] == 0) {
                                                Hilog.info(0, "CjTelegram", "[LocationService] Granted: ${result.permissions[i]}")
                                                if (result.permissions[i] == "ohos.permission.APPROXIMATELY_LOCATION") {
                                                    approxGranted = true
                                                }
                                            } else {
                                                Hilog.info(0, "CjTelegram", "[LocationService] Denied: ${result.permissions[i]}")
                                            }
                                        }
                                        onResult(approxGranted)
                                    case _ =>
                                        Hilog.info(0, "CjTelegram", "[LocationService] requestPermission: no result")
                                        onResult(false)
                                }
                        }
                    }
                )
            } catch (e: BusinessException) {
                Hilog.info(0, "CjTelegram", "[LocationService] requestPermission BusinessException: ${e.message}")
                onResult(false)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[LocationService] requestPermission Exception: ${e}")
                onResult(false)
            }
        case _ =>
            Hilog.info(0, "CjTelegram", "[LocationService] No UIAbilityContext, cannot request permission")
            onResult(false)
    }
}

/**
 * 检查权限并在需要时自动申请（一步完成）
 * @param onReady true=可以定位, false=无权限
 */
public func ensureLocationPermission(onReady: (Bool) -> Unit): Unit {
    let status = checkLocationPermission()
    match (status) {
        case LocationPermissionStatus.Granted =>
            onReady(true)
        case _ =>
            requestLocationPermission(onReady)
    }
}

// ==================== GPS 定位 (LOC-2) ====================

/**
 * 获取当前位置（一次性定位）
 * 需要先确保有位置权限（调用 ensureLocationPermission）
 * 
 * @return LocationResult 包含 GPS 坐标和精度
 */
public func getCurrentDeviceLocation(): LocationResult {
    let result = LocationResult()
    try {
        let location = GeoLocationManager.getCurrentLocation()
        result.success = true
        result.latitude = location.latitude
        result.longitude = location.longitude
        result.altitude = location.altitude
        result.accuracy = Float64(location.accuracy)
        // P2-180: capture device direction (heading) from Location.direction (0-360°, <0=invalid)
        let dir = location.direction
        result.directionDegrees = if (dir >= 0.0 && dir <= 360.0) { dir } else { -1.0 }
        let latStr = "${result.latitude}"
        let lngStr = "${result.longitude}"
        let accStr = "${result.accuracy}"
        Hilog.info(0, "CjTelegram", "[LocationService] GPS: lat=" + latStr + ", lng=" + lngStr + ", acc=" + accStr + "m, dir=${dir}")
    } catch (e: BusinessException) {
        result.errorMessage = "定位失败: " + e.message
        Hilog.info(0, "CjTelegram", "[LocationService] getCurrentLocation BusinessException: " + e.message)
    } catch (e: Exception) {
        result.errorMessage = "定位异常"
        Hilog.info(0, "CjTelegram", "[LocationService] getCurrentLocation Exception")
    }
    return result
}

/**
 * 坐标格式化为可读字符串
 * 
 * @param lat 纬度
 * @param lng 经度
 * @return "lat, lng" 格式字符串（截取前8字符）
 */
public func formatCoordinates(lat: Float64, lng: Float64): String {
    let latStr = "${lat}"
    let lngStr = "${lng}"
    let shortLat = if (latStr.size > 8) { latStr[0..8] } else { latStr }
    let shortLng = if (lngStr.size > 8) { lngStr[0..8] } else { lngStr }
    return shortLat + ", " + shortLng
}

/**
 * 完整定位流程：获取坐标 + 格式化地名
 *
 * @return LocationResult 包含坐标和格式化地名
 */
public func getLocationWithAddress(): LocationResult {
    let result = getCurrentDeviceLocation()
    if (result.success) {
        result.addressName = formatCoordinates(result.latitude, result.longitude)
    }
    return result
}

// ==================== TL 方法封装 (LOC-3) ====================

/**
 * 发送位置消息 (调用链: LocationService → RealMessageService → MTProtoClient.sendRequest)
 *
 * @param peerType 对话类型 (user/chat/channel)
 * @param peerId 对话 ID
 * @param lat 纬度
 * @param lng 经度
 * @return true=发送成功
 */
public func sendLocationMessage(peerType: String, peerId: Int64, lat: Float64, lng: Float64): Bool {
    try {
        let msgService = getRealMessageService()
        let result = msgService.sendLocation(peerType, peerId, lat, lng)
        Hilog.info(0, "CjTelegram", "[LocationService] sendLocationMessage result: " + if (result.success) { "ok" } else { result.errorMessage })
        return result.success
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[LocationService] sendLocationMessage exception")
        return false
    }
}

/**
 * 发送实时位置消息 (调用链: LocationService → RealMessageService → MTProtoClient.sendRequest)
 *
 * @param peerType 对话类型
 * @param peerId 对话 ID
 * @param lat 纬度
 * @param lng 经度
 * @param period 分享持续秒数（900/3600/28800）
 * @return true=发送成功
 */
public func sendLiveLocationMessage(peerType: String, peerId: Int64, lat: Float64, lng: Float64, period: Int32): Bool {
    try {
        let msgService = getRealMessageService()
        let result = msgService.sendLiveLocation(peerType, peerId, lat, lng, period: period)
        Hilog.info(0, "CjTelegram", "[LocationService] sendLiveLocationMessage result: " + if (result.success) { "ok" } else { result.errorMessage })
        return result.success
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[LocationService] sendLiveLocationMessage exception")
        return false
    }
}

/**
 * 获取附近用户/群组 (调用链: LocationService → PeersNearbyService → MTProtoClient.sendRequest)
 *
 * @param lat 纬度
 * @param lng 经度
 * @return PeersNearbyResult
 */
public func getNearbyPeers(lat: Float64, lng: Float64): PeersNearbyResult {
    try {
        let svc = getPeersNearbyService()
        return svc.getLocated(lat, lng)
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[LocationService] getNearbyPeers exception")
        return PeersNearbyResult()
    }
}

// ==================== 地理编码集成 (P2-190) ====================

/**
 * 异步反向地理编码（坐标 → 地址字符串）
 *
 * 对应 iOS reverseGeocodeLocation(latitude:longitude:)
 * 通过 GeocodingService (ArkTS arkinterop @ohos.geoLocationManager) 实现。
 *
 * @param lat      纬度
 * @param lng      经度
 * @param onResult 结果回调（非 UI 线程，调用方须 launch{} 写 @State）
 *                 Some(addr) = 成功（紧凑地址字符串）; None = 失败/离线
 */
public func reverseGeocodeLocation(lat: Float64, lng: Float64, onResult: (Option<String>) -> Unit): Unit {
    Hilog.info(0, "CjTelegram", "[LocationService] reverseGeocodeLocation lat=${lat} lng=${lng}")
    getGeocodingService().reverseGeocode(lat, lng, { placemarkOpt: Option<GeocodedPlacemark> =>
        match (placemarkOpt) {
            case Some(pm) =>
                let addr = pm.compactDisplayAddress()
                let result = if (addr.size > 0) { addr } else { pm.fullAddress() }
                Hilog.info(0, "CjTelegram", "[LocationService] reverseGeocode result: ${result}")
                onResult(Some(result))
            case None =>
                Hilog.info(0, "CjTelegram", "[LocationService] reverseGeocode: no result (offline?)")
                onResult(None)
        }
    })
}

/**
 * 异步正向地理编码（地址 → 坐标）
 *
 * 对应 iOS geocodeLocation(address:locale:)
 * 通过 GeocodingService (ArkTS arkinterop @ohos.geoLocationManager) 实现。
 *
 * @param address  地址字符串
 * @param onResult 结果回调（非 UI 线程，调用方须 launch{} 写 @State）
 *                 Some((lat,lng)) = 成功; None = 失败/地址未找到
 */
public func forwardGeocodeLocation(address: String, onResult: (Option<(Float64, Float64)>) -> Unit): Unit {
    Hilog.info(0, "CjTelegram", "[LocationService] forwardGeocodeLocation address=${address}")
    getGeocodingService().forwardGeocode(address, { resultOpt =>
        match (resultOpt) {
            case Some(r) =>
                Hilog.info(0, "CjTelegram", "[LocationService] forwardGeocode result: lat=${r.latitude} lng=${r.longitude}")
                onResult(Some((r.latitude, r.longitude)))
            case None =>
                Hilog.info(0, "CjTelegram", "[LocationService] forwardGeocode: no result")
                onResult(None)
        }
    })
}

// ==================== P2-181: 地图拖选结果全局状态 ====================
// 对应 iOS LocationPickerController → LocationPickerController.completion callback
// HarmonyOS 无法跨页面传参（NavPathStack param 只在 onReady 触发一次），
// 故用全局状态中转：InteractiveMapPage 写，LocationPage 读。

private var _mapPickLat: Float64 = 0.0
private var _mapPickLng: Float64 = 0.0
private var _mapPickReady: Bool = false

/**
 * P2-181: 写入地图拖选坐标（由 InteractiveMapPage 在 pick 模式下确认时调用）
 */
public func setMapPickResult(lat: Float64, lng: Float64): Unit {
    _mapPickLat = lat
    _mapPickLng = lng
    _mapPickReady = true
    Hilog.info(0, "CjTelegram", "[LocationService] setMapPickResult lat=${lat} lng=${lng}")
}

/**
 * P2-181: 读取并清除地图拖选结果
 * @return Some((lat, lng)) 若有待处理的选择，None 若无
 */
public func consumeMapPickResult(): Option<(Float64, Float64)> {
    if (!_mapPickReady) { return None }
    let lat = _mapPickLat
    let lng = _mapPickLng
    _mapPickReady = false
    _mapPickLat = 0.0
    _mapPickLng = 0.0
    Hilog.info(0, "CjTelegram", "[LocationService] consumeMapPickResult: lat=${lat} lng=${lng}")
    return Some((lat, lng))
}
