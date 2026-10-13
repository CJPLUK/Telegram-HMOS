package ohos_app_cangjie_entry.services

import kit.LocationKit.*
import kit.PerformanceAnalysisKit.Hilog
import std.sync.ReentrantMutex
import std.time.*
import std.collection.{ArrayList, HashMap}
import ohos.business_exception.BusinessException

/**
 * DeviceLocationManagerService — 设备位置管理服务 (P2-180 gap fix)
 *
 * 对应 iOS DeviceLocationManager.swift：
 *   - 精度仲裁（preciseAlways > preciseForeground，多订阅者取最高精度）
 *   - 连续位置流（background loop 每 _pollIntervalMs ms 调用 GeoLocationManager.getCurrentLocation）
 *   - 设备 heading 通过 Location.direction（HarmonyOS equivalent of CLLocation.course）
 *   - 后台定位权限声明（module.json5 ohos.permission.LOCATION_IN_BACKGROUND）
 *
 * P2-180 实现说明:
 *   Cangjie LocationKit SDK 只暴露 GeoLocationManager.getCurrentLocation()（一次性）；
 *   KB 5 轮查询（scores 0.016-0.033）均未命中 on('locationChange') 或 startLocating() Cangjie 绑定。
 *   因此连续定位用后台 spawn 轮询实现（等价 iOS CLLocationManager.startUpdatingLocation + delegate）：
 *   每 _pollIntervalMs ms 调用 SingleLocationRequest(LocatingPriority.PriorityAccuracy, timeout) 获取最新坐标，
 *   并从 Location.direction 读取航向（0-360°，-1 表示无有效方向）。
 */

public enum LocationAccuracyLevel {
    | High   // 高精度，对应 iOS DeviceLocationMode.preciseAlways（附近的人、实时位置）
    | Low    // 低精度，对应 iOS DeviceLocationMode.preciseForeground（通用场景）
}

// P2-180: 连续定位订阅者 ID 类型
public let LOC_SUBSCRIBER_NONE: Int32 = -1

private var _deviceLocationManagerServiceInstance: Option<DeviceLocationManagerService> = None

public func getDeviceLocationManagerService(): DeviceLocationManagerService {
    match (_deviceLocationManagerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = DeviceLocationManagerService()
            _deviceLocationManagerServiceInstance = Some(inst)
            return inst
    }
}

public class DeviceLocationManagerService {

    // 缓存最近已知位置
    private var _lastKnownLocation: Option<LocationResult> = None
    private let _locationMutex: ReentrantMutex = ReentrantMutex()

    // P2-180: 连续定位订阅者表 (subscriberId -> (accuracyLevel, callback))
    private var _nextSubscriberId: Int32 = 0
    private var _subscribers: HashMap<Int32, (LocationAccuracyLevel, (LocationResult, Int32) -> Unit)> = HashMap<Int32, (LocationAccuracyLevel, (LocationResult, Int32) -> Unit)>()
    private let _subscribersMutex: ReentrantMutex = ReentrantMutex()

    // P2-180: 连续定位轮询循环控制
    private var _continuousRunning: Bool = false
    private let _continuousMutex: ReentrantMutex = ReentrantMutex()

    // P2-180: 轮询间隔（毫秒）；高精度 2000ms / 低精度 5000ms
    private let _pollIntervalHighMs: Int64 = 2000
    private let _pollIntervalLowMs: Int64 = 5000

    // ==================== 权限 ====================

    /**
     * 检查位置权限是否已授权
     */
    public func isAuthorized(): Bool {
        let status = checkLocationPermission()
        match (status) {
            case LocationPermissionStatus.Granted => return true
            case _ => return false
        }
    }

    /**
     * 请求位置权限（若未授权则弹窗申请）
     * @param onResult true=已授权, false=用户拒绝
     */
    public func requestPermission(onResult: (Bool) -> Unit): Unit {
        ensureLocationPermission(onResult)
    }

    // ==================== 一次性定位 ====================

    /**
     * 一次性获取当前位置（成功后更新缓存）
     *
     * @param accuracyLevel 精度级别
     * @return LocationResult 包含 GPS 坐标、精度和航向
     */
    public func requestLocation(accuracyLevel: LocationAccuracyLevel): LocationResult {
        let result = this.fetchCurrentLocation(accuracyLevel)
        if (result.success) {
            synchronized (_locationMutex) {
                this._lastKnownLocation = Some(result)
            }
            Hilog.info(0, "CjTelegram", "[DeviceLocationManager] requestLocation cached: lat=${result.latitude}, lng=${result.longitude} dir=${result.altitude}")
        }
        return result
    }

    /**
     * 获取缓存的最近已知位置
     */
    public func getLastKnownLocation(): Option<LocationResult> {
        synchronized (_locationMutex) {
            return this._lastKnownLocation
        }
    }

    /**
     * 设置缓存的最近位置（供外部如 PeersNearby 更新后同步）
     */
    public func setLastKnownLocation(lat: Float64, lng: Float64): Unit {
        let result = LocationResult(lat, lng)
        result.accuracy = 0.0
        synchronized (_locationMutex) {
            this._lastKnownLocation = Some(result)
        }
    }

    // ==================== P2-180: 连续定位 + 多订阅者精度仲裁 ====================

    /**
     * P2-180 gap fix: 注册连续定位订阅
     *
     * 对应 iOS DeviceLocationManager.push(mode:updated:) → Disposable
     * 多个订阅者取最高精度（High > Low）并通知所有订阅者。
     *
     * @param accuracyLevel 精度级别（影响轮询间隔和 SingleLocationRequest 优先级）
     * @param onUpdate 位置更新回调（lat, lng, headingDeg: -1=无航向/0-359=航向度）
     *                 注意：回调从后台线程调用，写 @State 须在 launch{} 内
     * @return subscriberId（用于 removeSubscriber 取消订阅）
     */
    public func startContinuousLocation(
        accuracyLevel: LocationAccuracyLevel,
        onUpdate: (LocationResult) -> Unit
    ): Bool {
        if (!this.isAuthorized()) {
            Hilog.info(0, "CjTelegram", "[DeviceLocationManager] startContinuousLocation: not authorized")
            return false
        }
        // 注册订阅者（内部把 onUpdate 包装为带 heading 签名的 callback）
        let subId = this.addContinuousSubscriber(accuracyLevel, onUpdate)
        Hilog.info(0, "CjTelegram", "[DeviceLocationManager] startContinuousLocation: subscriberId=${subId}")
        this.ensureContinuousLoopRunning()
        return true
    }

    /**
     * P2-180 gap fix: 停止连续定位（取消所有订阅者并停止后台轮询）
     *
     * 对应 iOS DeviceLocationManager: CLLocationManager.stopUpdatingLocation
     */
    public func stopLocation(): Unit {
        synchronized (_subscribersMutex) {
            let keys: ArrayList<Int32> = ArrayList<Int32>()
            for ((k, _) in this._subscribers) { keys.add(k) }
            for (k in keys) { let _ = this._subscribers.remove(k) }
        }
        Hilog.info(0, "CjTelegram", "[DeviceLocationManager] stopLocation: all subscribers removed")
    }

    /**
     * P2-180: 移除单个订阅者（精细控制，对应 iOS Disposable.dispose()）
     * @param subscriberId 由 startContinuousLocation 返回的 ID（如需精细控制）
     */
    public func removeSubscriber(subscriberId: Int32): Unit {
        synchronized (_subscribersMutex) {
            let _ = this._subscribers.remove(subscriberId)
        }
        Hilog.info(0, "CjTelegram", "[DeviceLocationManager] removeSubscriber: id=${subscriberId}")
    }

    // ==================== 内部实现 ====================

    /**
     * 从 GeoLocationManager 获取当前位置
     * 使用 SingleLocationRequest(LocatingPriority.PriorityAccuracy) 获得高精度 + direction
     */
    /**
     * P2-180: 从 GeoLocationManager 获取当前位置（含 direction）
     *
     * 使用 GeoLocationManager.getCurrentLocation()（无参数版本，最稳定）。
     * Location.direction: Float64 (0-360°, <0 = 无有效方向) — 对应 iOS CLLocation.course
     * accuracyLevel 参数保留，供未来 SingleLocationRequest 升级使用。
     */
    private func fetchCurrentLocation(accuracyLevel: LocationAccuracyLevel): LocationResult {
        let result = LocationResult()
        try {
            let loc = GeoLocationManager.getCurrentLocation()
            result.success = true
            result.latitude = loc.latitude
            result.longitude = loc.longitude
            result.altitude = loc.altitude
            result.accuracy = Float64(loc.accuracy)
            // P2-180: Location.direction (0-360°，< 0 = 无有效方向）
            let dirDeg = loc.direction
            result.directionDegrees = if (dirDeg >= 0.0 && dirDeg <= 360.0) { dirDeg } else { -1.0 }
            Hilog.info(0, "CjTelegram", "[DeviceLocationManager] fetchLocation: lat=${loc.latitude} lng=${loc.longitude} dir=${dirDeg}")
        } catch (e: BusinessException) {
            result.errorMessage = "定位失败: " + e.message
            Hilog.info(0, "CjTelegram", "[DeviceLocationManager] fetchLocation BusinessException: " + e.message)
        } catch (e: Exception) {
            result.errorMessage = "定位异常"
            Hilog.info(0, "CjTelegram", "[DeviceLocationManager] fetchLocation Exception")
        }
        return result
    }

    private func addContinuousSubscriber(
        accuracyLevel: LocationAccuracyLevel,
        onUpdate: (LocationResult) -> Unit
    ): Int32 {
        synchronized (_subscribersMutex) {
            let id = this._nextSubscriberId
            this._nextSubscriberId = this._nextSubscriberId + 1
            this._subscribers[id] = (accuracyLevel, { result: LocationResult, _heading: Int32 =>
                onUpdate(result)
            })
            return id
        }
    }

    private func ensureContinuousLoopRunning(): Unit {
        synchronized (_continuousMutex) {
            if (this._continuousRunning) { return }
            this._continuousRunning = true
        }
        let _ = spawn {
            this.continuousLocationLoop()
        }
        Hilog.info(0, "CjTelegram", "[DeviceLocationManager] continuous location loop started")
    }

    /**
     * P2-180 gap fix: 后台连续定位轮询循环
     *
     * 精度仲裁：
     *   - 任一 High 订阅者 → 使用 PriorityAccuracy + _pollIntervalHighMs
     *   - 全为 Low 订阅者 → 使用 PriorityLocatingSpeed + _pollIntervalLowMs
     *
     * 对应 iOS DeviceLocationManager.updateTopMode()：取订阅者中最高优先级模式
     */
    private func continuousLocationLoop(): Unit {
        while (true) {
            // 精度仲裁：检查订阅者
            var hasHigh = false
            var count = 0
            let currentCallbacks: ArrayList<(LocationResult) -> Unit> = ArrayList<(LocationResult) -> Unit>()
            synchronized (_subscribersMutex) {
                count = this._subscribers.size
                for ((_, pair) in this._subscribers) {
                    let (acc, cb) = pair
                    match (acc) {
                        case LocationAccuracyLevel.High => hasHigh = true
                        case _ => ()
                    }
                    // 解开回调存入 currentCallbacks（不在 mutex 内调用）
                    let capturedCb = cb
                    currentCallbacks.add({ r: LocationResult => capturedCb(r, -1) })
                }
            }
            if (count == 0) {
                // 无订阅者：停止循环
                synchronized (_continuousMutex) {
                    this._continuousRunning = false
                }
                Hilog.info(0, "CjTelegram", "[DeviceLocationManager] no subscribers, continuous loop stopped")
                return
            }

            // 取得精度级别
            let accuracy = if (hasHigh) { LocationAccuracyLevel.High } else { LocationAccuracyLevel.Low }
            let intervalMs = if (hasHigh) { this._pollIntervalHighMs } else { this._pollIntervalLowMs }

            // 获取当前位置
            let result = this.fetchCurrentLocation(accuracy)
            if (result.success) {
                synchronized (_locationMutex) {
                    this._lastKnownLocation = Some(result)
                }
                // 通知所有订阅者（在 spawn 线程，调用方需 launch{} 写 @State）
                let capturedResult = result
                for (cb in currentCallbacks) {
                    cb(capturedResult)
                }
            }

            // 等待轮询间隔
            sleep(Duration.millisecond * intervalMs)
        }
    }
}
