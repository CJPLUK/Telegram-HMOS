package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, PresentationSnapshot, currentPresentationStrings,
    currentPresentation, themeIconColors, recomputePresentation}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.ArkData.*
import kit.PerformanceAnalysisKit.Hilog
import std.time.*
import std.math.*
import ohos_app_cangjie_entry.services.{
    getThemesEngineService,
    getGlobalAbilityContext,
    ensureLocationPermission,
    getCurrentDeviceLocation,
    formatCoordinates
}
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * AutoNightSettingsPage — 对位 submodules/SettingsUI/Sources/Themes/ThemeAutoNightSettingsController.swift
 * (diag-suite_settings_appearance-TC-0403.md 「修法方向」A 部分 F1-F5)。
 *
 * 源侧四条互斥触发模式（TriggerMode，:20-25）：system / none / timeBased / brightness。目标侧
 * 持久化域沿用 core_presentation_data 已建立的 ThemesEngineService.getAutoNightMode/saveAutoNightMode
 * canonical 值域：0=Disabled(explicitNone)、1=Scheduled(timeBased)、3=System、5=Automatic(brightness)。
 * 4(explicitForce) 本屏不产出——源侧 TriggerMode 私有枚举本身也没有 explicitForce 分支，force 是与
 * trigger 正交的独立顶层标志（AutomaticThemeSwitchSetting.force），不在本屏选择范围内。
 *
 * 遗留值 2（此前坏 UI 的 "Sunset to Sunrise" 循环档位）在 F2 边界条件下不再是顶层模式——
 * loadSettings() 一次性把它迁移为 Scheduled(1) + 位置子选项开（见该函数注释），不丢用户既有设置。
 *
 * 已知限制（详见 featureX.md「已知限制」，此处只记代码级根因）：
 *   - `services/ThemesEngineService.cj` 不在本 feature 这次派发的 target_files 内（归
 *     core_presentation_data 所有），因此位置子选项开关 / From-To 时间 / 偏好夜间主题
 *     的持久化在本文件内直接用 Preferences 读写自己的 key（同 AppearanceSettingsPage.cj
 *     showNextMediaOnTap 的既有先例：见该文件 231-236 行注释），不新增跨 feature 的
 *     service 方法。
 *   - From/To 强制取整到整点小时（round1 曾按分钟粒度存取并只把同步值截断到小时，导致显示
 *     值与求值器实际生效边界最多相差 59 分钟、且两端截断方向相反——已改为在源头取整消除该偏差）：
 *     setFromSeconds/setToSeconds 与 loadFromSeconds/loadToSeconds 一律调用 floorToHour()
 *     把秒数下取整到整点小时再写入 this.fromSeconds/this.toSeconds，因此本屏确认后回显的
 *     From/To 永远是 HH:00（分钟位恒为 0）。DateTimePicker（components/DateTimePicker.cj，
 *     不在本 feature target_files 内，仍按 review round1 核准的方式复用、未改动其实现）本身的
 *     分钟滚轮列无法从调用方关闭，用户在面板内仍能滚到任意分钟，但一旦点确认，取整立即生效、
 *     行文字立刻回显 HH:00——用户当场就能看到"选了的分钟没有被采纳"，不是一个隐藏的偏差。取整后
 *     Int32(seconds / 3600) 传给既有 saveAutoNightFromHour/ToHour 的值与显示值逐位相同，
 *     即本屏显示与 ThemesEngineService 现有小时粒度求值器（autoNightShouldSwitchNow()，
 *     services/ThemesEngineService.cj:1287-1293，未改动）实际生效时刻的偏差为 0 分钟。
 *     真正把求值器升级到分钟精度、从而可以去掉这里的取整、让面板真实生效到所选分钟，需要
 *     core_presentation_data 一侧配合（见本 feature emitted_integration_contracts 里的
 *     ic_auto_night_evaluator_minute_precision）。
 *   - 位置子选项开启时不本地计算真实日出日落时刻（无经纬度→时刻的天文算法可复用/可验证），
 *     只展示真实 GPS 坐标（ohos_app_cangjie_entry.services.getCurrentDeviceLocation 真实定位，
 *     非反向地理编码城市名——本仓当前没有暴露反向地理编码服务）。不编造具体时刻。
 *   - `ThemesEngineService.currentSystemBrightness()` 是包内私有（无 `public`），本文件跨包
 *     不可调用，因此亮度阈值区块只提供可编辑的阈值滑杆，不展示"当前实时亮度读数"。
 *   - PREFERRED THEME 只提供源侧 `defaultThemes` 字面量集合（.night / .nightAccent，源侧
 *     PresentationThemeCodable.swift:2024-2027 对应显示名 "Night" / "Night Tinted"），不拉取
 *     云端自定义主题列表（那需要网络往返 + 完整的 ThemeSettingsThemeItem 卡片渲染，超出本屏
 *     UI 结构任务范围）。
 */
@HybridComponentEntry
@Component
public class AutoNightSettingsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    // ---- MODE ----
    @State var mode: Int32 = 3

    // ---- SCHEDULE (mode == 1) ----
    @State var useLocation: Bool = false
    @State var locationName: String = ""
    @State var sunsetValue: String = ""
    @State var sunriseValue: String = ""
    @State var isFetchingLocation: Bool = false
    @State var fromSeconds: Int64 = 79200 // 22:00，对齐 ThemesEngineService 既有小时默认值
    @State var toSeconds: Int64 = 28800   // 08:00
    // D-125 镜像字段：ItemListDisclosureRow.value 是普通 var（非 @Prop），必须经裸 @State
    // 字段镜像才能在 this.fromSeconds/toSeconds 变化后驱动该子组件重新 build()
    // （AppearanceSettingsPage.cj:57-67 autoNightThemeRightValueMirror 同型先例）。
    @State var fromValueMirror: String = ""
    @State var toValueMirror: String = ""
    @State var showFromPicker: Bool = false
    @State var showToPicker: Bool = false

    // ---- BRIGHTNESS THRESHOLD (mode == 5) ----
    @State var brightnessThreshold: Float64 = 0.2

    // ---- PREFERRED THEME (mode != 0) ----
    // 0 = Night, 1 = Night Tinted（源侧 defaultThemes 字面量集合，见类注释）
    @State var preferredThemeIndex: Int32 = 0

    @State var loaded: Bool = false

    // ==================== 生命周期 ====================

    private func ensureLoaded(): Unit {
        if (this.loaded) {
            return
        }
        this.loaded = true
        this.loadSettings()
    }

    /**
     * 从真实持久化源回填全部 @State。
     *
     * 遗留值 2 迁移（F2 边界条件）：现有已存值 1/2/3 的语义不得漂移；2("Sunset to Sunrise"，
     * 此前坏 UI 的第三个循环档位)不再是顶层模式，一次性重写为 Scheduled(1) + 位置子选项开——
     * 迁移只发生一次(写回 canonical 1 后，下次 load 已经是 1，不会重复触发)。
     */
    private func loadSettings(): Unit {
        let svc = getThemesEngineService()
        var rawMode = svc.getAutoNightMode()
        if (rawMode == 2) {
            svc.saveAutoNightMode(1)
            rawMode = 1
            this.persistUseLocation(true)
            Hilog.info(0, "CjTelegram", "[AutoNightSettings] Migrated legacy mode=2 -> Scheduled+location")
        }
        this.mode = rawMode
        this.useLocation = this.loadUseLocation()
        this.fromSeconds = this.loadFromSeconds()
        this.toSeconds = this.loadToSeconds()
        this.brightnessThreshold = svc.getAutoNightBrightnessThreshold()
        this.preferredThemeIndex = this.loadPreferredTheme()
        this.loadStoredLocation()
        Hilog.info(0, "CjTelegram", "[AutoNightSettings] Loaded: mode=${this.mode} useLocation=${this.useLocation}")
    }

    // ==================== 本地持久化（telegram_themes_cache，与 ThemesEngineService 同 store） ====================

    private func loadUseLocation(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("auto_night_use_location", PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return false
                    }
                } catch (_e: Exception) {
                    return false
                }
            case None => return false
        }
    }

    private func persistUseLocation(v: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let n: Int64 = if (v) { 1 } else { 0 }
                    prefs.put("auto_night_use_location", PreferencesValueType.Integer(n))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    private func loadStoredLocation(): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let latValue = prefs.get("auto_night_latitude", PreferencesValueType.Double(1000.0))
                    let lonValue = prefs.get("auto_night_longitude", PreferencesValueType.Double(1000.0))
                    match ((latValue, lonValue)) {
                        case (PreferencesValueType.Double(lat), PreferencesValueType.Double(lon)) =>
                            if (lat >= -90.0 && lat <= 90.0 && lon >= -180.0 && lon <= 180.0) {
                                this.locationName = formatCoordinates(lat, lon)
                                this.updateSunTimes(lat, lon)
                            }
                        case _ => ()
                    }
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    private func persistLocation(latitude: Float64, longitude: Float64): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("auto_night_latitude", PreferencesValueType.Double(latitude))
                    prefs.put("auto_night_longitude", PreferencesValueType.Double(longitude))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    private func loadPreferredTheme(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("auto_night_preferred_theme", PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 0
                    }
                } catch (_e: Exception) {
                    return 0
                }
            case None => return 0
        }
    }

    private func persistPreferredTheme(index: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("auto_night_preferred_theme", PreferencesValueType.Integer(Int64(index)))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    // 下取整到整点小时（丢弃分钟位）。求值器仍只有小时粒度（见类头「已知限制」），本文件
    // 在这里把显示值本身也取整，让回显永远等于实际生效边界，不再是"显示分钟、生效整点"的偏差。
    private func normalizeSecondsOfDay(seconds: Int64): Int64 {
        var value = seconds % 86400
        if (value < 0) {
            value = value + 86400
        }
        return value
    }

    // own 整点小时 key；缺失时退化读取 ThemesEngineService 既有小时粒度值（不丢用户已存设置）。
    // floorToHour() 同时兜底修正 round1 遗留的、可能带非整点分钟的旧存值。
    private func loadFromSeconds(): Int64 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("auto_night_from_seconds", PreferencesValueType.Integer(-1))
                    match (val) {
                        case PreferencesValueType.Integer(n) =>
                            if (n >= 0) {
                                return this.normalizeSecondsOfDay(n)
                            }
                        case _ => ()
                    }
                } catch (_e: Exception) {}
            case None => ()
        }
        return Int64(getThemesEngineService().getAutoNightFromMinutes()) * 60
    }

    private func loadToSeconds(): Int64 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("auto_night_to_seconds", PreferencesValueType.Integer(-1))
                    match (val) {
                        case PreferencesValueType.Integer(n) =>
                            if (n >= 0) {
                                return this.normalizeSecondsOfDay(n)
                            }
                        case _ => ()
                    }
                } catch (_e: Exception) {}
            case None => ()
        }
        return Int64(getThemesEngineService().getAutoNightToMinutes()) * 60
    }

    private func persistFromSeconds(seconds: Int64): Unit {
        let normalized = this.normalizeSecondsOfDay(seconds)
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("auto_night_from_seconds", PreferencesValueType.Integer(normalized))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
        getThemesEngineService().saveAutoNightFromMinutes(Int32(normalized / 60))
    }

    private func persistToSeconds(seconds: Int64): Unit {
        let normalized = this.normalizeSecondsOfDay(seconds)
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("auto_night_to_seconds", PreferencesValueType.Integer(normalized))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
        getThemesEngineService().saveAutoNightToMinutes(Int32(normalized / 60))
    }

    // ==================== 状态变更 ====================

    /**
     * 对位源侧 updateMode 闭包（:416-441）。切到 Scheduled 且此前不是 Scheduled 时，源侧默认把
     * 子设置置为 .automatic(位置) 并立即 forceUpdateLocation()；这里镜像同一"fresh entry"语义。
     */
    private func setMode(newMode: Int32): Unit {
        let previousMode = this.mode
        this.mode = newMode
        getThemesEngineService().saveAutoNightMode(newMode)
        if (newMode == 1 && previousMode != 1) {
            this.useLocation = true
            this.persistUseLocation(true)
            this.updateLocation()
        }
        let _ = recomputePresentation()
        Hilog.info(0, "CjTelegram", "[AutoNightSettings] mode=${newMode}")
    }

    private func pageCardColor(): UInt32 {
        return this.presentation.cardColor
    }

    private func pageBackgroundColor(): UInt32 {
        return this.presentation.backgroundColor
    }

    private func pageNavColor(): UInt32 {
        return this.presentation.navBarColor
    }

    private func pageTextColor(): UInt32 {
        return this.presentation.textColor
    }

    private func pageSecondaryTextColor(): UInt32 {
        return if (this.presentation.isDark) { 0xFF8E8E93 } else { ITEM_LIST_TEXT_SECONDARY }
    }

    private func pageSeparatorColor(): UInt32 {
        return if (this.presentation.isDark) { 0xFF38383A } else { ITEM_LIST_SEPARATOR }
    }

    private func setUseLocation(v: Bool): Unit {
        this.useLocation = v
        this.persistUseLocation(v)
        if (v) {
            this.updateLocation()
        }
    }

    private func setFromSeconds(seconds: Int64): Unit {
        // 取整到整点小时后立刻反映在 this.fromSeconds 上——DateTimePicker 面板确认后，
        // From 行文字回显的必然是 HH:00，用户当场就能看到分钟选择未被采纳（见类头「已知限制」）。
        let normalized = this.normalizeSecondsOfDay(seconds)
        this.fromSeconds = normalized
        this.persistFromSeconds(normalized)
    }

    private func setToSeconds(seconds: Int64): Unit {
        let normalized = this.normalizeSecondsOfDay(seconds)
        this.toSeconds = normalized
        this.persistToSeconds(normalized)
    }

    private func setBrightnessThreshold(v: Float64): Unit {
        var clamped = v
        if (clamped < 0.0) {
            clamped = 0.0
        }
        if (clamped > 1.0) {
            clamped = 1.0
        }
        this.brightnessThreshold = clamped
        getThemesEngineService().saveAutoNightBrightnessThreshold(clamped)
    }

    private func setPreferredTheme(index: Int32): Unit {
        this.preferredThemeIndex = index
        this.persistPreferredTheme(index)
        let _ = recomputePresentation()
    }

    /**
     * 对位源侧 forceUpdateLocation()（:387-414）：真实 GPS 定位，非编造坐标。实现沿用
     * components/LocationPicker.cj#requestGPSLocation 的既有已验证写法（权限检查 → spawn 取
     * 位置 → launch 回写 @State）。
     */
    private func updateLocation(): Unit {
        this.isFetchingLocation = true
        ensureLocationPermission({ granted: Bool =>
            if (granted) {
                spawn {
                    let result = getCurrentDeviceLocation()
                    if (result.success) {
                        let name = formatCoordinates(result.latitude, result.longitude)
                        let latitude = result.latitude
                        let longitude = result.longitude
                        launch {
                            this.locationName = name
                            this.persistLocation(latitude, longitude)
                            this.updateSunTimes(latitude, longitude)
                            this.isFetchingLocation = false
                        }
                    } else {
                        let err = result.errorMessage
                        launch {
                            this.locationName = err
                            this.isFetchingLocation = false
                        }
                    }
                }
            } else {
                launch {
                    this.locationName = "Location permission denied"
                    this.isFetchingLocation = false
                }
            }
        })
    }

    // ==================== 格式化 / 换算 ====================

    private func padTime(v: Int64): String {
        if (v < 10) {
            return "0${v}"
        }
        return "${v}"
    }

    private func normalizeDegrees(value: Float64): Float64 {
        var result = value - floor(value / 360.0) * 360.0
        if (result < 0.0) { result = result + 360.0 }
        return result
    }

    private func normalizeHours(value: Float64): Float64 {
        var result = value - floor(value / 24.0) * 24.0
        if (result < 0.0) { result = result + 24.0 }
        return result
    }

    private func degreesToRadians(value: Float64): Float64 {
        return value * 3.14159265358979323846 / 180.0
    }

    private func radiansToDegrees(value: Float64): Float64 {
        return value * 180.0 / 3.14159265358979323846
    }

    private func isLeapYear(year: Int64): Bool {
        return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private func dayOfYear(year: Int64, month: Int64, day: Int64): Int64 {
        let monthLengths: Array<Int64> = if (this.isLeapYear(year)) {
            [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        } else {
            [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        }
        var result = day
        var index: Int64 = 0
        while (index < month - 1) {
            result = result + monthLengths[index]
            index = index + 1
        }
        return result
    }

    private func calculateSunHour(latitude: Float64, longitude: Float64, sunrise: Bool): Option<Float64> {
        let now = DateTime.now().inLocal()
        let n = Float64(this.dayOfYear(Int64(now.year), Int64(now.month.toInteger()), Int64(now.dayOfMonth)))
        let longitudeHour = longitude / 15.0
        let approximate = n + ((if (sunrise) { 6.0 } else { 18.0 }) - longitudeHour) / 24.0
        let meanAnomaly = 0.9856 * approximate - 3.289
        let trueLongitude = this.normalizeDegrees(
            meanAnomaly + 1.916 * sin(this.degreesToRadians(meanAnomaly)) +
            0.020 * sin(this.degreesToRadians(2.0 * meanAnomaly)) + 282.634)
        var rightAscension = this.normalizeDegrees(this.radiansToDegrees(atan(0.91764 * tan(this.degreesToRadians(trueLongitude)))))
        rightAscension = rightAscension + (floor(trueLongitude / 90.0) * 90.0 - floor(rightAscension / 90.0) * 90.0)
        rightAscension = rightAscension / 15.0
        let sinDeclination = 0.39782 * sin(this.degreesToRadians(trueLongitude))
        let cosDeclination = sqrt(max(0.0, 1.0 - sinDeclination * sinDeclination))
        let cosHour = (cos(this.degreesToRadians(90.833)) - sinDeclination * sin(this.degreesToRadians(latitude))) /
            (cosDeclination * cos(this.degreesToRadians(latitude)))
        if (cosHour < -1.0 || cosHour > 1.0) {
            return None
        }
        var localHourAngle = this.radiansToDegrees(acos(cosHour))
        if (sunrise) {
            localHourAngle = 360.0 - localHourAngle
        }
        localHourAngle = localHourAngle / 15.0
        let localMeanTime = localHourAngle + rightAscension - 0.06571 * approximate - 6.622
        let utcHour = this.normalizeHours(localMeanTime - longitudeHour)
        let offsetHours = Float64(now.zoneOffset.toSeconds()) / 3600.0
        return Some(this.normalizeHours(utcHour + offsetHours))
    }

    private func formatSunHour(hour: Float64): String {
        var totalMinutes = Int64(round(hour * 60.0)) % 1440
        if (totalMinutes < 0) { totalMinutes = totalMinutes + 1440 }
        return this.padTime(totalMinutes / 60) + ":" + this.padTime(totalMinutes % 60)
    }

    private func updateSunTimes(latitude: Float64, longitude: Float64): Unit {
        match (this.calculateSunHour(latitude, longitude, false)) {
            case Some(hour) => this.sunsetValue = this.formatSunHour(hour)
            case None => this.sunsetValue = ""
        }
        match (this.calculateSunHour(latitude, longitude, true)) {
            case Some(hour) => this.sunriseValue = this.formatSunHour(hour)
            case None => this.sunriseValue = ""
        }
    }

    private func formatTimeOfDay(seconds: Int64): String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return "${this.padTime(h)}:${this.padTime(m)}"
    }

    // 秒数(一天内) → 供 DateTimePicker 用的 unix 秒(以"今天"的日期部分组装，picker 只消费时分)。
    private func secondsToInitialUnix(seconds: Int64): Int64 {
        let now = DateTime.now().inLocal()
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let combined = DateTime.of(year: now.year, month: now.monthValue, dayOfMonth: now.dayOfMonth, hour: h, minute: m, second: 0)
        return combined.toUnixTimeStamp().toSeconds()
    }

    // DateTimePicker 回传的 unix 秒 → 本地时区的"一天内秒数"（丢弃日期部分，只取 时:分）。
    private func unixToSecondsOfDay(unixSec: Int64): Int64 {
        let dt = DateTime.ofEpoch(second: unixSec, nanosecond: 0).inLocal()
        return dt.hour * 3600 + dt.minute * 60
    }

    // D-116：build() 不能含裸赋值语句，只能是 UI 组件表达式；用零高度探针在每次 build() 开头
    // 跑一次镜像刷新（AppearanceSettingsPage.cj:213-221 refreshRightValueMirrors 同型写法）。
    private func refreshMirrors(): String {
        this.fromValueMirror = this.formatTimeOfDay(this.fromSeconds)
        this.toValueMirror = this.formatTimeOfDay(this.toSeconds)
        return ""
    }

    // ==================== 行构建 ====================

    // D-115/D-125：@Builder 参数经宏包成 ObservedProperty，其依赖追踪只识别调用点是裸
    // @State 字段引用；计算表达式实参（this.mode == X）首帧求值后即冻结，不随字段变化重同步。
    // 六个互斥选中行改为各自内联读裸 @State 的无参 @Builder（对位 buildUpdateLocationRow
    // 已验证正常的写法），单选唯一性由"四个互斥比较共用一个字段"结构性保证，不引入额外状态。
    @Builder
    func buildModeRowSystem() {
        Row {
            if (this.mode == 3) {
                Text("✓")
                    .fontSize(18)
                    .fontColor(0x2EB67D)
                    .width(36)
            } else {
                Row {}.width(36)
            }
            Text(trSource("System"))
                .fontSize(17)
                .fontColor(this.pageTextColor())
                .layoutWeight(1)
        }
        .width(100.percent)
        .constraintSize(minHeight: 44)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.setMode(3) })
    }

    @Builder
    func buildModeRowDisabled() {
        Row {
            if (this.mode == 0) {
                Text("✓")
                    .fontSize(18)
                    .fontColor(0x2EB67D)
                    .width(36)
            } else {
                Row {}.width(36)
            }
            Text(trSource("Disabled"))
                .fontSize(17)
                .fontColor(this.pageTextColor())
                .layoutWeight(1)
        }
        .width(100.percent)
        .constraintSize(minHeight: 44)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.setMode(0) })
    }

    @Builder
    func buildModeRowScheduled() {
        Row {
            if (this.mode == 1) {
                Text("✓")
                    .fontSize(18)
                    .fontColor(0x2EB67D)
                    .width(36)
            } else {
                Row {}.width(36)
            }
            Text(trSource("Scheduled"))
                .fontSize(17)
                .fontColor(this.pageTextColor())
                .layoutWeight(1)
        }
        .width(100.percent)
        .constraintSize(minHeight: 44)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.setMode(1) })
    }

    @Builder
    func buildModeRowAutomatic() {
        Row {
            if (this.mode == 5) {
                Text("✓")
                    .fontSize(18)
                    .fontColor(0x2EB67D)
                    .width(36)
            } else {
                Row {}.width(36)
            }
            Text(trSource("Automatic"))
                .fontSize(17)
                .fontColor(this.pageTextColor())
                .layoutWeight(1)
        }
        .width(100.percent)
        .constraintSize(minHeight: 44)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.setMode(5) })
    }

    @Builder
    func buildPreferredThemeCard(index: Int32, themeKind: Int32, title: String) {
        Column {
            Stack {
                ThemeCarouselCardCanvas(
                    wallpaperColors: themeIconColors(themeKind).wallpaperColors,
                    incomingColor: themeIconColors(themeKind).incomingBubbleColor,
                    outgoingColor: themeIconColors(themeKind).outgoingBubbleColor,
                    fallbackColor: themeIconColors(themeKind).backgroundColor,
                    canvasW: 96.0,
                    canvasH: 62.0,
                    drawBackground: true
                )
            }
            .width(96)
            .height(62)
            .borderRadius(10)
            .clip(true)
            .border(width: if (this.preferredThemeIndex == index) { 2 } else { 0 }, color: ITEM_LIST_ACCENT, radius: 10)

            Text(title)
                .fontSize(13)
                .fontColor(this.pageTextColor())
                .margin(top: 8)
        }
        .width(112)
        .onClick({ _ => this.setPreferredTheme(index) })
    }

    // 对位源侧 timeBasedAutomaticLocationValue（disclosureStyle: .none，titleColor: .accent）——
    // 整行可点、无 chevron，故不走 ItemListDisclosureRow（其固定渲染 chevron/黑色标题）。
    @Builder
    func buildUpdateLocationRow() {
        Row {
            Text(if (this.isFetchingLocation) { "Updating Location…" } else { "Update Location" })
                .fontSize(17)
                .fontColor(ITEM_LIST_ACCENT)
                .layoutWeight(1)
            if (this.locationName.size > 0) {
                Text(this.locationName)
                    .fontSize(15)
                    .fontColor(this.pageSecondaryTextColor())
            }
        }
        .width(100.percent)
        .constraintSize(minHeight: 44)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.updateLocation() })
    }

    @Builder
    func buildUseLocationRow() {
        Row {
            Text("Use Local Sunset & Sunrise")
                .fontSize(17)
                .fontColor(this.pageTextColor())
                .layoutWeight(1)
            Toggle(ToggleType.Switch, isOn: this.useLocation)
                .selectedColor(ITEM_LIST_TOGGLE_ON)
                .onChange({ value: Bool => this.setUseLocation(value) })
        }
        .width(100.percent)
        .constraintSize(minHeight: 52)
        .padding(left: 16, right: 16, top: 8, bottom: 8)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func buildFromPickerSheet() {
        DateTimePicker(
            initialUnixSec: this.secondsToInitialUnix(this.fromSeconds),
            mode: "time",
            onConfirm: { picked: Int64 =>
                this.setFromSeconds(this.unixToSecondsOfDay(picked))
                this.showFromPicker = false
            },
            onCancel: { => this.showFromPicker = false }
        )
    }

    @Builder
    func buildToPickerSheet() {
        DateTimePicker(
            initialUnixSec: this.secondsToInitialUnix(this.toSeconds),
            mode: "time",
            onConfirm: { picked: Int64 =>
                this.setToSeconds(this.unixToSecondsOfDay(picked))
                this.showToPicker = false
            },
            onCancel: { => this.showToPicker = false }
        )
    }

    // ==================== build ====================

    public func build() {
        Column {
            Text(this.refreshMirrors()).height(0).fontSize(0)

            // 导航栏：标题 "Auto-Night Theme"，返回按钮文案 "Back"，左右按钮槽均为空
            // （对位源侧 ItemListControllerState(title:.text(AutoNightTheme_Title),
            // leftNavigationButton: nil, rightNavigationButton: nil,
            // backNavigationButton: ItemListBackButton(title: Common_Back))）。
            Row {
                Row {
                    Image(@r(app.media.callui_v2_back))
                        .width(10)
                        .height(18)
                        .fillColor(ITEM_LIST_ACCENT)
                }
                .width(44)
                .height(44)
                .borderRadius(22)
                .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(trSource("Auto-Night Mode"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.pageTextColor())
                Blank().layoutWeight(1)
                Row {}.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(top: getSafeAreaTop())
            .padding(left: 16, right: 16)
            .backgroundColor(this.pageNavColor())
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    // ========= F2: MODE — 四条互斥行 =========
                    Column {
                        this.buildModeRowSystem()
                        ItemListSeparator()
                        this.buildModeRowDisabled()
                        ItemListSeparator()
                        this.buildModeRowScheduled()
                        ItemListSeparator()
                        this.buildModeRowAutomatic()
                    }
                    .backgroundColor(this.pageCardColor())
                    .borderRadius(12)
                    .margin(left: 16, right: 16, top: 16)

                    // ========= F3: SCHEDULE 二分支（mode == Scheduled） =========
                    if (this.mode == 1) {
                        ItemListSectionHeader(title: "SCHEDULE", topPad: 20)
                        Column {
                            this.buildUseLocationRow()
                            if (this.useLocation) {
                                ItemListSeparator()
                                this.buildUpdateLocationRow()
                            } else {
                                ItemListSeparator()
                                ItemListDisclosureRow(
                                    title: "From",
                                    value: this.fromValueMirror,
                                    onClick: { => this.showFromPicker = true }
                                )
                                ItemListSeparator()
                                ItemListDisclosureRow(
                                    title: "To",
                                    value: this.toValueMirror,
                                    onClick: { => this.showToPicker = true }
                                )
                            }
                        }
                        .backgroundColor(this.pageCardColor())
                        .borderRadius(12)
                        .margin(left: 16, right: 16)

                        if (this.useLocation) {
                            // D-165：.width(100.percent) 子节点在默认居中的 Column 下，水平方向
                            // 必须用 .padding 不能用 .margin（对称 margin 会算出可见左右缘 = 0，
                            // 贴边渲染）；纵向 top 留在 .margin 上。同 buildModeRowSystem 等选中行的写法。
                            Text("Calculating sunset & sunrise times requires a one-time check of your approximate location. Note that this location is stored locally on your device only.")
                                .fontSize(13)
                                .fontColor(this.pageSecondaryTextColor())
                                .width(100.percent)
                                .padding(left: 16, right: 16)
                                .margin(top: 8)
                            if (this.sunsetValue.size > 0 && this.sunriseValue.size > 0) {
                                Text("Sunset: ${this.sunsetValue}\nSunrise: ${this.sunriseValue}")
                                    .fontSize(13)
                                    .fontColor(this.pageSecondaryTextColor())
                                    .width(100.percent)
                                    .padding(left: 16, right: 16)
                                    .margin(top: 12)
                            }
                        }
                    }

                    // ========= F4: BRIGHTNESS THRESHOLD（mode == Automatic） =========
                    if (this.mode == 5) {
                        ItemListSectionHeader(title: "BRIGHTNESS THRESHOLD", topPad: 20)
                        Column {
                            Row {
                                Text("Dark").fontSize(13).fontColor(this.pageSecondaryTextColor())
                                Blank().layoutWeight(1)
                                Text("Bright").fontSize(13).fontColor(this.pageSecondaryTextColor())
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 4)

                            Slider(
                                value: this.brightnessThreshold * 100.0,
                                min: 0.0,
                                max: 100.0,
                                step: 1.0,
                                style: SliderStyle.OutSet
                            )
                            .selectedColor(ITEM_LIST_ACCENT)
                            .trackColor(this.pageSeparatorColor())
                            .width(100.percent)
                            .padding(left: 16, right: 16, bottom: 12)
                            .onChange({ value: Float64, changeMode: SliderChangeMode =>
                                this.setBrightnessThreshold(value / 100.0)
                            })
                        }
                        .backgroundColor(this.pageCardColor())
                        .borderRadius(12)
                        .margin(left: 16, right: 16)

                        // D-165：同上，水平留白用 .padding，纵向 top 留在 .margin。
                        Text("Automatically switch to the night theme when your screen brightness drops to or below ${Int64(this.brightnessThreshold * 100.0)}%.")
                            .fontSize(13)
                            .fontColor(this.pageSecondaryTextColor())
                            .width(100.percent)
                            .padding(left: 16, right: 16)
                            .margin(top: 8)
                    }

                    // ========= F5: PREFERRED THEME（mode != Disabled） =========
                    if (this.mode != 0) {
                        ItemListSectionHeader(title: "PREFERRED NIGHT THEME", topPad: 20)
                        Row {
                            this.buildPreferredThemeCard(0, 3, trSource("Night"))
                            this.buildPreferredThemeCard(1, 1, trSource("Dark"))
                        }
                        .padding(left: 16, right: 16, top: 14, bottom: 14)
                        .alignItems(VerticalAlign.Top)
                        .backgroundColor(this.pageCardColor())
                        .borderRadius(12)
                        .margin(left: 16, right: 16, bottom: 24)
                    }
                }
                .width(100.percent)
            }
            .align(Alignment.Top)
            .layoutWeight(1)
            .backgroundColor(this.pageBackgroundColor())
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.pageBackgroundColor())
        .padding(bottom: getSafeAreaBottom())
        .bindSheet(this.showFromPicker, this.buildFromPickerSheet, options: SheetOptions(onDisappear: { => launch { this.showFromPicker = false } }))
        .bindSheet(this.showToPicker, this.buildToPickerSheet, options: SheetOptions(onDisappear: { => launch { this.showToPicker = false } }))
        .onAppear({ => this.ensureLoaded() })
    }
}
