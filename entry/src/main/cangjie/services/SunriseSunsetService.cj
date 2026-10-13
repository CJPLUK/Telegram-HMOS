package ohos_app_cangjie_entry.services

import std.math.*
import std.time.*
import kit.PerformanceAnalysisKit.Hilog

/**
 * SunriseSunsetService — 日出日落天文算法 (P2-193)
 *
 * iOS 对应: submodules/Sunrise/Sources/EDSunriseSet.m
 *   实现 Paul Schlyter 的 sunriset.c 天文算法
 *   (c) Paul Schlyter, 1989-1992, 发布到公共领域
 *   http://stjarnhimlen.se/english.html
 *
 * 算法移植自 EDSunriseSet:
 *   1. GMST0(d) — 格林威治恒星时
 *   2. sunpos(d) — 日面赤经距和距离
 *   3. sun_RA_dec(d) — 日面赤经/赤纬/距离
 *   4. sunRiseSetHelper — 日出日落时刻 (UT 小时)
 *
 * 功能:
 *   - calculateSunriseSunset(lat, lng, year, month, day) → SunriseSunsetResult
 *   - isDaytime(lat, lng) → Bool (当前系统时间是否处于白昼)
 *   - formatHourMinute(hours: Float64) → String "HH:MM"
 *
 * 调用链:
 *   LocationPage.showDayNightStatus → getSunriseSunsetService().isDaytime(lat, lng)
 *   VenuePickerPage.mapNightMode → getSunriseSunsetService().isDaytime(lat, lng)
 */

// ─────────────────────────────────────────────────────────────────────────────
// 数学常量
// ─────────────────────────────────────────────────────────────────────────────

private let SS_PI: Float64 = 3.14159265358979323846
private let RADEG: Float64 = 180.0 / SS_PI
private let DEGRAD: Float64 = SS_PI / 180.0
private let INV360: Float64 = 1.0 / 360.0

// ─────────────────────────────────────────────────────────────────────────────
// Result
// ─────────────────────────────────────────────────────────────────────────────

public class SunriseSunsetResult {
    // 日出 UTC 小时 (例如 5.5 = 05:30 UT)
    public var sunriseHoursUT: Float64 = 0.0
    // 日落 UTC 小时
    public var sunsetHoursUT: Float64 = 0.0
    // 返回码: 0=正常, +1=极昼, -1=极夜
    public var returnCode: Int32 = 0

    public init() {}

    public init(rise: Float64, set: Float64, rc: Int32) {
        this.sunriseHoursUT = rise
        this.sunsetHoursUT = set
        this.returnCode = rc
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Singleton
// ─────────────────────────────────────────────────────────────────────────────

private var _sunriseSunsetServiceInstance: Option<SunriseSunsetService> = None

public func getSunriseSunsetService(): SunriseSunsetService {
    match (_sunriseSunsetServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = SunriseSunsetService()
            _sunriseSunsetServiceInstance = Some(svc)
            return svc
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SunriseSunsetService
// ─────────────────────────────────────────────────────────────────────────────

public class SunriseSunsetService {

    /**
     * 计算给定地点和日期的日出日落时刻 (UT 时间)
     *
     * @param lat   纬度 (北正南负, 度)
     * @param lng   经度 (东正西负, 度)
     * @param year  年 (1801-2099)
     * @param month 月 (1-12)
     * @param day   日 (1-31)
     * @return SunriseSunsetResult
     */
    public func calculateSunriseSunset(lat: Float64, lng: Float64, year: Int32, month: Int32, day: Int32): SunriseSunsetResult {
        let (rc, trise, tset) = sunRiseSetHelper(year, month, day, lng, lat, -35.0 / 60.0, 1)
        Hilog.info(0, "CjTelegram", "[SunriseSunsetService] lat=${lat} lng=${lng} rise=${trise} set=${tset} rc=${rc}")
        let res = SunriseSunsetResult()
        res.sunriseHoursUT = trise
        res.sunsetHoursUT = tset
        res.returnCode = rc
        return res
    }

    /**
     * 判断当前系统时间在给定地点是否处于白昼
     *
     * @param lat  纬度
     * @param lng  经度
     * @return true = 白天, false = 夜间 / 极夜
     *
     * 当前时间以 UTC 小时表示，与日出日落比较。
     * 使用系统时间戳(毫秒)计算 UTC 小时。
     */
    public func isDaytime(lat: Float64, lng: Float64): Bool {
        let nowMs = getCurrentTimestampMs()
        let utcHour = currentUtcHour(nowMs)
        let (year, month, day) = currentUtcDate(nowMs)
        let result = this.calculateSunriseSunset(lat, lng, year, month, day)
        if (result.returnCode > 0) {
            return true
        }
        if (result.returnCode < 0) {
            return false
        }
        let isDaytimeResult = utcHour >= result.sunriseHoursUT && utcHour < result.sunsetHoursUT
        Hilog.info(0, "CjTelegram", "[SunriseSunsetService] utcHour=${utcHour} daytime=${isDaytimeResult}")
        return isDaytimeResult
    }

    /**
     * 格式化 UT 小时为 "HH:MM" 字符串
     *
     * @param hours UT 小时 (例如 5.5 → "05:30")
     */
    public func formatHourMinute(hours: Float64): String {
        let h = Int32(hours)
        let mFrac = (hours - Float64(h)) * 60.0
        let m = Int32(mFrac + 0.5)
        let hh = if (h < 10) { "0${h}" } else { "${h}" }
        let mm = if (m < 10) { "0${m}" } else { "${m}" }
        return hh + ":" + mm
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Paul Schlyter 天文算法 (移植自 EDSunriseSet.m / sunriset.c)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 2000年1月0日0UT以来的天数
 * 等价于 EDSunriseSet days_since_2000_Jan_0(y,m,d) 宏:
 *   367L*(y)-((7*((y)+(((m)+9)/12)))/4)+((275*(m))/9)+(d)-730530L
 */
private func daysSince2000Jan0(year: Int32, month: Int32, day: Int32): Float64 {
    let y = Int64(year)
    let m = Int64(month)
    let d = Int64(day)
    let n = 367 * y - (7 * (y + ((m + 9) / 12))) / 4 + (275 * m) / 9 + d - 730530
    return Float64(n)
}

/**
 * 把角度规约到 0..360 范围
 */
private func revolution(x: Float64): Float64 {
    return x - 360.0 * floor(x * INV360)
}

/**
 * 把角度规约到 -180..+180 范围
 */
private func rev180(x: Float64): Float64 {
    return x - 360.0 * floor(x * INV360 + 0.5)
}

/**
 * GMST0(d) — 格林威治恒星时 (度)
 * sidtim0 = revolution(180.0 + 356.047 + 282.9404 + (0.9856002585 + 4.70935E-5)*d)
 */
private func GMST0(d: Float64): Float64 {
    return revolution((180.0 + 356.0470 + 282.9404) + (0.9856002585 + 4.70935E-5) * d)
}

/**
 * 计算日面黄经和日地距
 * 移植自 EDSunriseSet.sunposAtDay(d, lon, r)
 *
 * @param d   2000年1月0日以来天数
 * @return    (lon: Float64, r: Float64) 太阳黄经(度) + 日地距(AU)
 */
private func sunpos(d: Float64): (Float64, Float64) {
    let M = revolution(356.0470 + 0.9856002585 * d)  // 太阳平近点角
    let w = 282.9404 + 4.70935E-5 * d                 // 近日点黄经
    let e = 0.016709 - 1.151E-9 * d                   // 轨道离心率

    let sinM = sssin(M * DEGRAD)
    let cosM = sscos(M * DEGRAD)
    // 偏近点角 E (单次迭代)
    let E = M + e * RADEG * sinM * (1.0 + e * cosM)
    let x = sscos(E * DEGRAD) - e
    let y = sqrt(1.0 - e * e) * sssin(E * DEGRAD)
    let r = sqrt(x * x + y * y)  // 日地距 AU
    let v = ssatan2(y, x) * RADEG     // 真近点角 (度)
    var lon = v + w
    if (lon >= 360.0) { lon = lon - 360.0 }
    return (lon, r)
}

/**
 * 计算太阳赤经/赤纬
 * 移植自 EDSunriseSet.sun_RA_decAtDay(d, RA, dec, r)
 * @return (ra: Float64, dec: Float64, r: Float64)
 */
private func sunRADec(d: Float64): (Float64, Float64, Float64) {
    let (lon, r) = sunpos(d)

    let xs = r * sscos(lon * DEGRAD)
    let ys = r * sssin(lon * DEGRAD)
    // zs = 0 (太阳总在黄道面)

    let oblEcl = 23.4393 - 3.563E-7 * d  // 黄赤交角 (度)
    let xe = xs
    let ye = ys * sscos(oblEcl * DEGRAD)
    let ze = ys * sssin(oblEcl * DEGRAD)

    let ra = ssatan2(ye, xe) * RADEG
    let dec = ssatan2(ze, sqrt(xe * xe + ye * ye)) * RADEG
    return (ra, dec, r)
}

/**
 * 计算日出日落 (核心函数)
 * 移植自 EDSunriseSet.sunRiseSetHelperForYear:month:day:longitude:latitude:altitude:upper_limb:trise:tset:
 *
 * @param year       年
 * @param month      月
 * @param day        日
 * @param lon        经度 (东正, 度)
 * @param lat        纬度 (北正, 度)
 * @param altit      地平线高度角 (-35/60 度用于日出日落)
 * @param upperLimb  1=上缘, 0=圆心
 * @return (rc: Int32, trise: Float64, tset: Float64) rc=0正常/+1极昼/-1极夜
 */
private func sunRiseSetHelper(
    year: Int32, month: Int32, day: Int32,
    lon: Float64, lat: Float64,
    altit: Float64, upperLimb: Int32
): (Int32, Float64, Float64) {
    var rc: Int32 = 0

    // d = 12h 地方平太阳时的天数
    let d = daysSince2000Jan0(year, month, day) + 0.5 - lon / 360.0

    let sidtime = revolution(GMST0(d) + 180.0 + lon)

    let (sRA, sdec, sr) = sunRADec(d)

    // 太阳到达南中天的时刻 (UT 小时)
    let tsouth = 12.0 - rev180(sidtime - sRA) / 15.0

    // 太阳视半径 (度)
    let sradius = 0.2666 / sr

    // 修正上缘
    var altitAdj = altit
    if (upperLimb != 0) {
        altitAdj = altitAdj - sradius
    }

    // 日弧半角
    var t: Float64 = 0.0
    let sinAlt = sssin(altitAdj * DEGRAD)
    let sinLat = sssin(lat * DEGRAD)
    let cosLat = sscos(lat * DEGRAD)
    let sinDec = sssin(sdec * DEGRAD)
    let cosDec = sscos(sdec * DEGRAD)

    let cost = (sinAlt - sinLat * sinDec) / (cosLat * cosDec)
    if (cost >= 1.0) {
        rc = -1  // 极夜
        t = 0.0
    } else if (cost <= -1.0) {
        rc = 1   // 极昼
        t = 12.0
    } else {
        t = ssacos(cost) * RADEG / 15.0  // 日弧半角 (小时)
    }

    let trise = tsouth - t
    let tset = tsouth + t
    return (rc, trise, tset)
}

// ─────────────────────────────────────────────────────────────────────────────
// 三角函数封装 (命名避免与 LocationDistanceService 冲突)
// ─────────────────────────────────────────────────────────────────────────────

// std.math.* provides sin, cos, atan2, acos, sqrt, floor as top-level functions
private func sssin(x: Float64): Float64 { return sin(x) }
private func sscos(x: Float64): Float64 { return cos(x) }
private func ssatan2(y: Float64, x: Float64): Float64 { return atan2(y, x) }
private func ssacos(x: Float64): Float64 { return acos(x) }

// ─────────────────────────────────────────────────────────────────────────────
// 时间辅助 (系统时间戳 → UTC 日期/小时)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 获取当前 UTC 毫秒时间戳
 * 使用 std.time.DateTime.now().toUnixTimeStamp().toMilliseconds()
 */
private func getCurrentTimestampMs(): Int64 {
    return DateTime.now().toUnixTimeStamp().toMilliseconds()
}

/**
 * 毫秒时间戳 → UTC 小时 (Float64, 含分秒)
 */
private func currentUtcHour(ms: Int64): Float64 {
    let secondsInDay = Int64(86400)
    let secsSinceMidnight = (ms / 1000) % secondsInDay
    return Float64(secsSinceMidnight) / 3600.0
}

/**
 * 毫秒时间戳 → (year, month, day) UTC
 * 使用儒略日算法 (Richard Montenbruck 公式)
 */
private func currentUtcDate(ms: Int64): (Int32, Int32, Int32) {
    // 自1970-01-01以来的天数
    let daysSince1970 = Int64(ms / 1000) / 86400
    // 转为儒略日 (JD)
    // JD 2440588 = 1970-01-01
    let jd = daysSince1970 + 2440588

    // 算法: Meeus "Astronomical Algorithms" ch 7
    let z = jd
    let alpha = (Float64(z) - 1867216.25) / 36524.25
    let alphaInt = Int64(alpha)
    let A: Int64
    if (z < 2299161) {
        A = z
    } else {
        A = z + 1 + alphaInt - alphaInt / 4
    }
    let B = A + 1524
    let C = Int64((Float64(B) - 122.1) / 365.25)
    let D = Int64(365.25 * Float64(C))
    let E = Int64(Float64(B - D) / 30.6001)

    let day = Int32(B - D - Int64(30.6001 * Float64(E)))
    let month: Int32
    if (E < 14) {
        month = Int32(E - 1)
    } else {
        month = Int32(E - 13)
    }
    let year: Int32
    if (month > 2) {
        year = Int32(C - 4716)
    } else {
        year = Int32(C - 4715)
    }
    return (year, month, day)
}
