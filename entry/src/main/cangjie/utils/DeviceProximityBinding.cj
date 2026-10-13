package ohos_app_cangjie_entry.utils

import std.collection.ArrayList
import kit.PerformanceAnalysisKit.Hilog
import kit.SensorServiceKit.*
import ohos.business_exception.BusinessException
import ohos.callback_invoke.*

/**
 * DeviceProximityBinding — 距离传感器平台封装层
 *
 * 对应 Telegram-iOS DeviceProximityManager，提供平台无关的接口：
 * - startMonitoring / stopMonitoring：启停传感器监听
 * - addCallback / removeCallback：注册/注销回调
 * - getCurrentValue：当前是否靠近（true=靠近，用于通话自动灭屏）
 *
 * 鸿蒙平台通过 kit.SensorServiceKit 的 SensorId.Proximity 访问。
 * 当 SensorServiceKit 不可用时回退降级（始终返回 false）。
 *
 * 注：逻辑上为 bindings 层，为避免 cjpm combined 构建时 linker 顺序问题，
 * 与 DeviceProximityUtils 同置于 utils 包。
 */

// 鸿蒙 ProximityResponse 典型阈值：distance < 3.0 cm 视为靠近
let PROXIMITY_NEAR_THRESHOLD_CM: Float64 = 3.0

/**
 * 距离传感器状态 — 对应 iOS DeviceProximityManager 的 value 语义
 */
public enum ProximityState {
    | Far   // 远离（> 阈值）
    | Near  // 靠近（< 3cm，贴脸灭屏）
}

/**
 * 平台无关的距离传感器绑定接口
 *
 * iOS 对照: DeviceProximityManager (PresentationCall proximityManagerIndex)
 * - startMonitoring / stopMonitoring ✓
 * - addCallback / removeCallback ✓
 * - getCurrentValue (isNear) ✓
 */
public class DeviceProximityBinding {

    private var _isMonitoring: Bool = false
    private var _currentValue: Bool = false
    private var _callbackIdCounter: Int64 = 0
    private var _callbacks: ArrayList<(Bool) -> Unit> = ArrayList<(Bool) -> Unit>()
    private var _callbackIds: ArrayList<Int64> = ArrayList<Int64>()
    // 持有传感器回调引用，防止被 GC（P2-069 SensorServiceKit）
    private var _sensorCallback: Option<Callback1Argument<ProximityResponse>> = None

    /**
     * 开始监听距离传感器
     * @return true 表示成功启动，false 表示传感器不可用或已失败
     */
    public func startMonitoring(): Bool {
        if (this._isMonitoring) {
            return true
        }
        let ok = this.startPlatformMonitoring()
        if (ok) {
            this._isMonitoring = true
            Hilog.info(0, "CjTelegram", "[DeviceProximity] Monitoring started")
        }
        return ok
    }

    /**
     * 停止监听距离传感器
     */
    public func stopMonitoring(): Unit {
        if (!this._isMonitoring) {
            return
        }
        this.stopPlatformMonitoring()
        this._isMonitoring = false
        this._currentValue = false
        Hilog.info(0, "CjTelegram", "[DeviceProximity] Monitoring stopped")
    }

    /**
     * 注册回调，距离变化时触发
     * @param callback (isNear: Bool) -> Unit，isNear=true 表示靠近（如贴脸）
     * @return 订阅 ID，用于 removeCallback
     */
    public func addCallback(callback: (Bool) -> Unit): Int64 {
        let id = this._callbackIdCounter
        this._callbackIdCounter = this._callbackIdCounter + 1
        this._callbacks.add(callback)
        this._callbackIds.add(id)
        callback(this._currentValue)
        if (this._callbacks.size == 1 && !this._isMonitoring) {
            let _ = this.startMonitoring()
        }
        return id
    }

    /**
     * 注销回调
     */
    public func removeCallback(id: Int64): Unit {
        var idx: Int64 = -1
        for (i in 0..this._callbackIds.size) {
            if (this._callbackIds[i] == id) {
                idx = i
                break
            }
        }
        if (idx >= 0) {
            this._callbacks.remove(at: idx)
            this._callbackIds.remove(at: idx)
            if (this._callbacks.isEmpty() && this._isMonitoring) {
                this.stopMonitoring()
            }
        }
    }

    /**
     * 是否正在监听
     */
    public func isMonitoring(): Bool {
        return this._isMonitoring
    }

    /**
     * 当前是否靠近（true=靠近，用于通话自动灭屏）
     */
    public func getCurrentValue(): Bool {
        return this._currentValue
    }

    /**
     * 获取当前传感器状态枚举
     */
    public func getProximityState(): ProximityState {
        return if (this._currentValue) { ProximityState.Near } else { ProximityState.Far }
    }

    /**
     * 通知所有回调（平台层调用）
     */
    private func notifyCallbacks(isNear: Bool): Unit {
        if (this._currentValue == isNear) {
            return
        }
        this._currentValue = isNear
        let copy = ArrayList<(Bool) -> Unit>()
        for (cb in this._callbacks) {
            copy.add(cb)
        }
        for (cb in copy) {
            cb(isNear)
        }
    }

    /**
     * 平台实现：启动接近光传感器（P2-069 真做）
     *
     * 使用 kit.SensorServiceKit.on(SensorId.Proximity, callback, option:)
     * KB Example 149 (score 0.032): ProximityResponse.distance: Float32
     *   0 = 靠近（Near），> 0 = 远离（Far）
     *
     * 对应 iOS: UIDevice.isProximityMonitoringEnabled = true
     *          UIDevice.proximityState (true = close to face)
     */
    private func startPlatformMonitoring(): Bool {
        Hilog.info(0, "CjTelegram", "[DeviceProximity] startPlatformMonitoring via kit.SensorServiceKit")
        try {
            let callback = DeviceProximitySensorCallback(binding: this)
            this._sensorCallback = Some(callback)
            let options = Options(interval: IntervalOption.SensorNumber(100000000))
            on(SensorId.Proximity, callback, option: options)
            Hilog.info(0, "CjTelegram", "[DeviceProximity] SensorId.Proximity listener registered")
            return true
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[DeviceProximity] SensorServiceKit failed code=${e.code}: ${e.message}")
            this._sensorCallback = None
            return false
        }
    }

    /**
     * 平台实现：停止接近光传感器
     */
    private func stopPlatformMonitoring(): Unit {
        try {
            off(SensorId.Proximity)
            this._sensorCallback = None
            Hilog.info(0, "CjTelegram", "[DeviceProximity] SensorId.Proximity listener removed")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[DeviceProximity] off Proximity failed: ${e.message}")
        }
    }

    /**
     * 供 DeviceProximitySensorCallback 回调使用的内部通知入口
     * (public-visible within package)
     */
    public func handleSensorData(distance: Float32): Unit {
        let isNear = distance == Float32(0.0)
        this.notifyCallbacks(isNear)
    }
}

// ==================== SensorServiceKit callback 实现 ====================

/**
 * 接近光传感器回调（P2-069）
 *
 * KB Example 149:
 *   class ProximityCallback <: Callback1Argument<ProximityResponse>
 *   func invoke(err: ?BusinessException, arg: ProximityResponse): Unit
 *   ProximityResponse.distance: Float32 — 0=靠近，>0=远离
 */
class DeviceProximitySensorCallback <: Callback1Argument<ProximityResponse> {

    private var _binding: DeviceProximityBinding

    init(binding!: DeviceProximityBinding) {
        this._binding = binding
    }

    public func invoke(err: ?BusinessException, arg: ProximityResponse): Unit {
        match (err) {
            case Some(e) =>
                Hilog.info(0, "CjTelegram", "[DeviceProximity] sensor error code=${e.code}: ${e.message}")
                return
            case None => ()
        }
        let dist = arg.distance
        Hilog.info(0, "CjTelegram", "[DeviceProximity] distance=${dist} isNear=${dist == Float32(0.0)}")
        this._binding.handleSensorData(dist)
    }
}
