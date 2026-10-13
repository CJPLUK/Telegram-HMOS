package ohos_app_cangjie_entry.services

import std.math.*
import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.{Want}

/**
 * LocationDistanceService — 路线/距离/open-in-maps 服务 (P2-191)
 *
 * iOS 对应:
 *   LocationViewControllerNode.swift — 距离计算 (distanceFromCoordinate:)
 *   LocationViewController.swift — Get Directions / ETA (requestDirections)
 *   OpenInExternalAppUI — open-in-maps intent
 *
 * 功能:
 *   1. haversineDistance(lat1, lng1, lat2, lng2): Float64 — 两点球面距离(米)
 *   2. bearing(lat1, lng1, lat2, lng2): Float64 — 方位角(度, 0=北, 顺时针)
 *   3. estimatedWalkTime(meters): Int32 — 步行估算分钟(5 km/h)
 *   4. estimatedDriveTime(meters): Int32 — 驾车估算分钟(城市均速 30 km/h)
 *   5. openInMaps(lat, lng, label) — 通过 geo: URI 拉起地图应用
 *   6. formatDistance(meters): String — 可读距离字符串
 *   7. formatBearing(degrees): String — 可读方位字符串(N/NE/E/SE/S/SW/W/NW)
 *
 * 调用链:
 *   LocationPage.openInMaps → getLocationDistanceService().openInMaps(lat, lng, label)
 *   LocationPage.showDistanceInfo → getLocationDistanceService().haversineDistance(...)
 *
 * 不依赖 Map Kit / MapKit，仅纯算法 + geo: URI intent
 */

// ─────────────────────────────────────────────────────────────────────────────
// 数学常量
// ─────────────────────────────────────────────────────────────────────────────

// 地球半径 (米)
private let EARTH_RADIUS_M: Float64 = 6371000.0
// PI
private let PI: Float64 = 3.14159265358979323846
// 步行速度 m/min (5 km/h)
private let WALK_SPEED_M_PER_MIN: Float64 = 83.33
// 驾车速度 m/min (30 km/h 城市)
private let DRIVE_SPEED_M_PER_MIN: Float64 = 500.0

// ─────────────────────────────────────────────────────────────────────────────
// Singleton
// ─────────────────────────────────────────────────────────────────────────────

private var _locationDistanceServiceInstance: Option<LocationDistanceService> = None

public func getLocationDistanceService(): LocationDistanceService {
    match (_locationDistanceServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = LocationDistanceService()
            _locationDistanceServiceInstance = Some(svc)
            return svc
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LocationDistanceService
// ─────────────────────────────────────────────────────────────────────────────

public class LocationDistanceService {

    /**
     * Haversine 公式计算两点球面距离
     *
     * iOS 对应 CLLocation.distance(from:) / distanceFromCoordinate()
     *
     * @param lat1 起点纬度 (度)
     * @param lng1 起点经度 (度)
     * @param lat2 终点纬度 (度)
     * @param lng2 终点经度 (度)
     * @return 球面距离 (米)
     *
     * 公式: a = sin²(Δlat/2) + cos(lat1)*cos(lat2)*sin²(Δlng/2)
     *        c = 2*atan2(√a, √(1−a))
     *        d = R * c
     */
    public func haversineDistance(lat1: Float64, lng1: Float64, lat2: Float64, lng2: Float64): Float64 {
        let dLat = degreesToRadians(lat2 - lat1)
        let dLng = degreesToRadians(lng2 - lng1)
        let lat1Rad = degreesToRadians(lat1)
        let lat2Rad = degreesToRadians(lat2)

        let sinDLat = sin(dLat / 2.0)
        let sinDLng = sin(dLng / 2.0)
        let a = sinDLat * sinDLat + cos(lat1Rad) * cos(lat2Rad) * sinDLng * sinDLng
        let c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a))
        let dist = EARTH_RADIUS_M * c
        Hilog.info(0, "CjTelegram", "[LocationDistanceService] haversine=${dist}m")
        return dist
    }

    /**
     * 计算方位角 (初始航向角)
     *
     * @param lat1 起点纬度
     * @param lng1 起点经度
     * @param lat2 终点纬度
     * @param lng2 终点经度
     * @return 方位角 (度, 0=正北, 顺时针, 范围 0..360)
     */
    public func bearing(lat1: Float64, lng1: Float64, lat2: Float64, lng2: Float64): Float64 {
        let lat1Rad = degreesToRadians(lat1)
        let lat2Rad = degreesToRadians(lat2)
        let dLng = degreesToRadians(lng2 - lng1)
        let y = sin(dLng) * cos(lat2Rad)
        let x = cos(lat1Rad) * sin(lat2Rad) - sin(lat1Rad) * cos(lat2Rad) * cos(dLng)
        let theta = atan2(y, x)
        let deg = radiansToDegrees(theta)
        // 归一化到 [0, 360): 用 floor 替代 % (仓颉 Float64 无 % 运算符)
        let normalized = deg + 360.0
        return normalized - 360.0 * floor(normalized / 360.0)
    }

    /**
     * 步行估算分钟数 (5 km/h)
     */
    public func estimatedWalkTime(meters: Float64): Int32 {
        if (meters <= 0.0) { return 0 }
        let minutes = meters / WALK_SPEED_M_PER_MIN
        let result = Int32(minutes + 0.5)  // 四舍五入
        if (result < 1) { return 1 }
        return result
    }

    /**
     * 驾车估算分钟数 (30 km/h 城市均速)
     */
    public func estimatedDriveTime(meters: Float64): Int32 {
        if (meters <= 0.0) { return 0 }
        let minutes = meters / DRIVE_SPEED_M_PER_MIN
        let result = Int32(minutes + 0.5)
        if (result < 1) { return 1 }
        return result
    }

    /**
     * 通过 geo: URI 拉起地图应用 (open-in-maps)
     *
     * iOS 对应 OpenInExternalAppUI / MKMapItem.openInMaps()
     *
     * HarmonyOS 侧使用 Want + uri = "geo:<lat>,<lng>?q=<label>" 拉起地图
     * 标准: RFC 5870 geo URI scheme
     * HarmonyOS Maps App 支持 geo: 协议
     *
     * @param lat   目标纬度
     * @param lng   目标经度
     * @param label 显示标签（可为空）
     */
    public func openInMaps(lat: Float64, lng: Float64, label: String): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                let latStr = formatCoord(lat)
                let lngStr = formatCoord(lng)
                let geoUri: String
                if (label.size > 0) {
                    // URL-encode label (basic: space→+)
                    let encodedLabel = label.replace(" ", "+")
                    geoUri = "geo:" + latStr + "," + lngStr + "?q=" + latStr + "," + lngStr + "(" + encodedLabel + ")"
                } else {
                    geoUri = "geo:" + latStr + "," + lngStr
                }
                Hilog.info(0, "CjTelegram", "[LocationDistanceService] openInMaps uri=${geoUri}")
                let want = Want(
                    action: "ohos.want.action.viewData",
                    uri: geoUri,
                    dataType: "geo/location"
                )
                try {
                    ctx.startAbility(want)
                    Hilog.info(0, "CjTelegram", "[LocationDistanceService] openInMaps started")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[LocationDistanceService] openInMaps error: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[LocationDistanceService] no context for openInMaps")
        }
    }

    /**
     * 格式化距离为可读字符串
     * < 1000m → "NNN m"
     * >= 1000m → "N.N km"
     */
    public func formatDistance(meters: Float64): String {
        if (meters < 0.0) { return "" }
        if (meters < 1000.0) {
            let m = Int32(meters + 0.5)
            return "${m} m"
        }
        let km = meters / 1000.0
        // 保留一位小数
        let kmInt = Int32(km)
        let kmFrac = Int32((km - Float64(kmInt)) * 10.0 + 0.5)
        if (kmFrac >= 10) {
            return "${kmInt + 1}.0 km"
        }
        return "${kmInt}.${kmFrac} km"
    }

    /**
     * 格式化方位角为 8 方向字符串
     */
    public func formatBearing(degrees: Float64): String {
        let dn = degrees + 360.0
        let d = dn - 360.0 * floor(dn / 360.0)
        if (d < 22.5 || d >= 337.5) { return "N" }
        if (d < 67.5) { return "NE" }
        if (d < 112.5) { return "E" }
        if (d < 157.5) { return "SE" }
        if (d < 202.5) { return "S" }
        if (d < 247.5) { return "SW" }
        if (d < 292.5) { return "W" }
        return "NW"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pure math helpers (file-private)
// ─────────────────────────────────────────────────────────────────────────────

private func degreesToRadians(deg: Float64): Float64 {
    return deg * PI / 180.0
}

private func radiansToDegrees(rad: Float64): Float64 {
    return rad * 180.0 / PI
}

// std.math.* imports: sin, cos, atan2, sqrt are top-level functions

/**
 * 格式化坐标 (6位小数)，供 geo: URI 使用
 * 例: 39.916527 → "39.916527"
 */
private func formatCoord(v: Float64): String {
    let neg = v < 0.0
    let abs_v = if (neg) { -v } else { v }
    let intPart = Int64(abs_v)
    let frac6Raw = Int64((abs_v - Float64(intPart)) * 1000000.0 + 0.5)
    // 确保 frac6 < 1000000 (避免进位溢出)
    let frac6 = if (frac6Raw >= 1000000) { frac6Raw - 1000000 } else { frac6Raw }
    let prefix = if (neg) { "-" } else { "" }
    // 手动补零到6位
    let f = frac6
    let d5 = f / 100000
    let d4 = (f / 10000) % 10
    let d3 = (f / 1000) % 10
    let d2 = (f / 100) % 10
    let d1 = (f / 10) % 10
    let d0 = f % 10
    return prefix + "${intPart}.${d5}${d4}${d3}${d2}${d1}${d0}"
}
