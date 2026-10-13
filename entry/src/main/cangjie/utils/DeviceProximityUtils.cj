package ohos_app_cangjie_entry.utils

/**
 * DeviceProximityUtils — 距离传感器上层工具接口
 *
 * 对应 Telegram-iOS DeviceProximityManager 的上层调用封装。
 * 供 CallScreen、VideoCallScreen 等通话页面使用，实现：
 * - 通话时自动灭屏（靠近时 isNear=true）
 * - 远离时恢复亮屏
 *
 * 使用方式：
 *   let id = getDeviceProximityUtils().addProximityCallback({ isNear: Bool =>
 *       if (isNear) { 灭屏 } else { 亮屏 }
 *   })
 *   // 通话结束时
 *   getDeviceProximityUtils().removeProximityCallback(id)
 */

private var _deviceProximityUtilsInstance: Option<DeviceProximityUtils> = None

/**
 * 获取距离传感器工具单例
 */
public func getDeviceProximityUtils(): DeviceProximityUtils {
    match (_deviceProximityUtilsInstance) {
        case Some(utils) => return utils
        case None =>
            let utils = DeviceProximityUtils()
            _deviceProximityUtilsInstance = Some(utils)
            return utils
    }
}

/**
 * 距离传感器工具类
 */
public class DeviceProximityUtils {

    private var _binding: DeviceProximityBinding = DeviceProximityBinding()

    /**
     * 注册距离变化回调
     * @param callback (isNear: Bool) -> Unit，isNear=true 表示靠近（贴脸，应灭屏）
     * @return 订阅 ID，通话结束时用于 removeProximityCallback
     */
    public func addProximityCallback(callback: (Bool) -> Unit): Int64 {
        return this._binding.addCallback(callback)
    }

    /**
     * 注销距离变化回调
     */
    public func removeProximityCallback(subscriptionId: Int64): Unit {
        this._binding.removeCallback(subscriptionId)
    }

    /**
     * 开始监听（通常 addCallback 时自动启动，也可手动调用）
     */
    public func startMonitoring(): Bool {
        return this._binding.startMonitoring()
    }

    /**
     * 停止监听
     */
    public func stopMonitoring(): Unit {
        this._binding.stopMonitoring()
    }

    /**
     * 当前是否靠近
     */
    public func isNear(): Bool {
        return this._binding.getCurrentValue()
    }

    /**
     * 是否正在监听
     */
    public func isMonitoring(): Bool {
        return this._binding.isMonitoring()
    }

    /**
     * 获取当前传感器状态
     */
    public func getProximityState(): ProximityState {
        return this._binding.getProximityState()
    }
}
