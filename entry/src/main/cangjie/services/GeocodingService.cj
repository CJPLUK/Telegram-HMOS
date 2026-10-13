package ohos_app_cangjie_entry.services

/**
 * GeocodingService — 地理编码服务（P2-190）
 *
 * iOS 对应:
 *   submodules/Geocoding/Sources/Geocoding.swift
 *   - geocodeLocation(address:locale:)     → forwardGeocode(address:onResult:)
 *   - reverseGeocodeLocation(lat:lng:)     → reverseGeocode(lat:lng:onResult:)
 *   - ReverseGeocodedPlacemark (struct)    → GeocodedPlacemark (class)
 *
 * 平台互操作判断（P2-190 诚实 N-A / ArkTS 决策）:
 *   - C NDK: 查询三轮 KB（worker:P2-190）—— HarmonyOS Location NDK 无 geocoding C API，
 *            仅提供 GPS 定位 C API（OH_Location_GetCurrentLocation）。
 *   - Cangjie 原生绑定: GeoLocationManager 仅暴露 getCurrentLocation / isLocationEnabled，
 *            无 getAddressesFromLocation / getAddressesFromLocationName Cangjie 绑定。
 *   - ArkTS (Phase 3 反转模式, SSOT §5): 系统调用搬到 ArkTS 侧
 *            (ets/interop/impls/GeocodingImpl.ets) 调 @kit.LocationKit geoLocationManager
 *            .getAddressesFromLocation (反向) / .getAddressesFromLocationName (正向)，
 *            启动时 registerArkFunc 注册进仓颉；仓颉经 callArkAsync 调用并解析结果 JSON。
 *   → 选择 ArkTS 互操作（Policy A 正确策略），见 INTEROP_CAPABILITIES.md GeocodingService 条目。
 *
 * INTEROP 契约 (D3, 双侧签名一致):
 *   反向: method = GEOCODE_REVERSE ("geocode.reverse")
 *     argJson (CJ→ArkTS): {"lat": <lat>, "lng": <lng>}
 *     result (ArkTS→CJ):  {"ok": <bool>, "name","road","city","province","country","countryCode"}
 *   正向: method = GEOCODE_FORWARD ("geocode.forward")
 *     argJson (CJ→ArkTS): {"address": <addr>}
 *     result (ArkTS→CJ):  {"ok": <bool>, "lat","lng","name","city","country"}
 *   ok=false（离线 / 无服务 / 空结果）→ 仓颉侧返回 None。
 *
 * 限制:
 *   - getAddressesFromLocation 依赖设备联网 + 华为位置服务后端，离线时失败，返回 None。
 *   - OSM TrustAll 脆弱性仅影响 map snapshot（LocationResourcesService），与本文件无关。
 *
 * 调用链 (P2-190 完整):
 *   LocationService.getLocationWithAddress()
 *     → GeocodingService.reverseGeocode(lat, lng, callback)
 *       → callArkAsync(GEOCODE_REVERSE, {"lat","lng"}, {resJson => ...})
 *         → [ArkTS] GeocodingImpl → geoLocationManager.getAddressesFromLocation → resJson
 *           → 解析 → GeocodedPlacemark → callback
 *
 *   LocationPage.resolveAddress(address)
 *     → GeocodingService.forwardGeocode(address, callback)
 *       → callArkAsync(GEOCODE_FORWARD, {"address"}, {resJson => ...})
 *         → [ArkTS] GeocodingImpl → geoLocationManager.getAddressesFromLocationName → resJson
 *           → 解析 → (lat, lng) → callback
 */

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkUI.launch
import ohos_app_cangjie_entry.interop.*

// ─────────────────────────────────────────────────────────────────
// 数据模型
// ─────────────────────────────────────────────────────────────────

/**
 * 地理编码结果 placemark
 *
 * 对应 iOS ReverseGeocodedPlacemark:
 *   name, street, city, state, country, countryCode
 */
public class GeocodedPlacemark {
    public var name: String = ""
    public var street: String = ""
    public var city: String = ""
    public var state: String = ""
    public var country: String = ""
    public var countryCode: String = ""

    public init() {}

    /**
     * 紧凑显示地址（对应 iOS compactDisplayAddress）
     * street → city → country 优先级
     */
    public func compactDisplayAddress(): String {
        if (this.street.size > 0) { return this.street }
        if (this.city.size > 0) { return this.city }
        if (this.country.size > 0) { return this.country }
        return ""
    }

    /**
     * 完整地址（对应 iOS fullAddress）
     * street, city, country 以逗号拼接
     */
    public func fullAddress(): String {
        var parts = ""
        if (this.street.size > 0) {
            parts = this.street
        }
        if (this.city.size > 0) {
            parts = if (parts.size > 0) { parts + ", " + this.city } else { this.city }
        }
        if (this.country.size > 0) {
            parts = if (parts.size > 0) { parts + ", " + this.country } else { this.country }
        }
        return parts
    }
}

/**
 * 地理编码请求结果
 */
public class GeocodingResult {
    public var success: Bool = false
    public var placemark: GeocodedPlacemark = GeocodedPlacemark()
    public var latitude: Float64 = 0.0
    public var longitude: Float64 = 0.0
    public var errorMessage: String = ""

    public init() {}
}

// ─────────────────────────────────────────────────────────────────
// 服务单例
// ─────────────────────────────────────────────────────────────────

private var _geocodingServiceInstance: Option<GeocodingService> = None

/** 获取 GeocodingService 单例 */
public func getGeocodingService(): GeocodingService {
    match (_geocodingServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = GeocodingService()
            _geocodingServiceInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────────────────────────
// GeocodingService
// ─────────────────────────────────────────────────────────────────

/**
 * GeocodingService — 正向 + 反向地理编码
 *
 * 实现路径 (Phase 3 反转模式): ArkTS @kit.LocationKit geoLocationManager
 *   callArkAsync(GEOCODE_*, argJson, {resJson => 解析 → callback})
 *   真实系统调用与线程 hop 都在 ArkTS 侧 (GeocodingImpl.ets)。
 *
 * 互操作层级: ArkTS（No C NDK, No Cangjie native binding for geocoding）
 */
public class GeocodingService {

    /**
     * 反向地理编码（坐标 → 地址）
     *
     * 对应 iOS reverseGeocodeLocation(latitude:longitude:locale:)
     * 对应 ArkTS: geoLocationManager.getAddressesFromLocation(request)
     *
     * @param lat      纬度（WGS-84）
     * @param lng      经度（WGS-84）
     * @param onResult 结果回调（主线程外调用，调用方须 launch{} 更新 @State）
     *                 Some(placemark) = 成功; None = 失败/离线
     *
     * fire → callArkAsync(GEOCODE_REVERSE, {"lat","lng"})；结果 JSON 在此解析。
     * 公共签名保持不变，调用方无需改动。
     */
    public func reverseGeocode(lat: Float64, lng: Float64, onResult: (Option<GeocodedPlacemark>) -> Unit): Unit {
        Hilog.info(0, "CjTelegram", "[GeocodingService] reverseGeocode lat=${lat} lng=${lng}")
        // argJson schema 与 ArkTS GeocodingImpl 逐条对应 (D3): {"lat","lng"}
        let argJson = "{\"lat\":${lat},\"lng\":${lng}}"
        callArkAsync(GEOCODE_REVERSE, argJson) { resJson =>
            // D1: 结果解析/回调是重活，放 spawn{} 里跑，不阻塞 interop 回调线程
            spawn {
                let json = JsonParser.parseObject(resJson)
                if (json.getBool("ok")) {
                    let placemark = GeocodedPlacemark()
                    let pname = json.getString("name")
                    let road = json.getString("road")
                    placemark.name = pname
                    placemark.street = if (road.size > 0) { road } else { pname }
                    placemark.city = json.getString("city")
                    placemark.state = json.getString("province")
                    placemark.country = json.getString("country")
                    placemark.countryCode = json.getString("countryCode")
                    Hilog.info(0, "CjTelegram", "[GeocodingService] reverseGeocode success addr=${placemark.fullAddress()}")
                    onResult(Some(placemark))
                } else {
                    Hilog.info(0, "CjTelegram", "[GeocodingService] reverseGeocode: ok=false / empty")
                    onResult(None)
                }
            }
        }
    }

    /**
     * 正向地理编码（地址 → 坐标）
     *
     * 对应 iOS geocodeLocation(address:locale:)
     * 对应 ArkTS: geoLocationManager.getAddressesFromLocationName(request)
     *
     * @param address  地址字符串（如 "北京市朝阳区"）
     * @param onResult 结果回调（主线程外调用，调用方须 launch{} 更新 @State）
     *                 Some(result) = 成功，result.latitude/longitude 有效; None = 失败
     */
    public func forwardGeocode(address: String, onResult: (Option<GeocodingResult>) -> Unit): Unit {
        Hilog.info(0, "CjTelegram", "[GeocodingService] forwardGeocode address=${address}")
        // argJson schema 与 ArkTS GeocodingImpl 逐条对应 (D3): {"address"}
        let escapedAddr = escapeJsonString(address)
        let argJson = "{\"address\":\"${escapedAddr}\"}"
        callArkAsync(GEOCODE_FORWARD, argJson) { resJson =>
            // D1: 结果解析/回调是重活，放 spawn{} 里跑
            spawn {
                let json = JsonParser.parseObject(resJson)
                if (json.getBool("ok")) {
                    let result = GeocodingResult()
                    result.success = true
                    result.latitude = json.getFloat("lat")
                    result.longitude = json.getFloat("lng")
                    let pm = GeocodedPlacemark()
                    let pname = json.getString("name")
                    pm.name = if (pname.size > 0) { pname } else { address }
                    pm.street = pm.name
                    pm.city = json.getString("city")
                    pm.country = json.getString("country")
                    result.placemark = pm
                    Hilog.info(0, "CjTelegram", "[GeocodingService] forwardGeocode success: lat=${result.latitude} lng=${result.longitude}")
                    onResult(Some(result))
                } else {
                    Hilog.info(0, "CjTelegram", "[GeocodingService] forwardGeocode: ok=false / empty")
                    onResult(None)
                }
            }
        }
    }
}
