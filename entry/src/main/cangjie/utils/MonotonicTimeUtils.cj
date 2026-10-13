package ohos_app_cangjie_entry.utils

import kit.BasicServicesKit.*
import ohos.business_exception.BusinessException

/**
 * 单调时钟工具（不受用户回拨系统墙钟影响）。
 *
 * 对应 iOS Telegram submodules/MonotonicTime（DeviceUptime.m：基于 KERN_BOOTTIME / 设备开机时长）：
 *   iOS 取"自开机以来的秒数"作单调来源，用于测量时间间隔而不被用户改时间干扰。
 *
 * HarmonyOS 等效 API（实证可编译，来自 cangjie-kb / ohos.systemdatetime）：
 *   `SystemDateTime.getUptime(timeType: TimeType, isNanoseconds!: Bool = false): Int64`
 *     - TimeType.Startup：自系统启动以来经过的毫秒数，**包含深度睡眠时间**（最贴近 iOS 开机时长口径）。
 *     - TimeType.Active ：自系统启动以来的活跃毫秒数，不含深度睡眠。
 *   import kit.BasicServicesKit.*；可能抛 BusinessException。
 *
 * 设计要点：
 *   - 使用 TimeType.Startup（含睡眠），对齐 iOS "uptime since boot" 语义，适合跨时段的单调测量。
 *   - getUptime 抛 BusinessException 时回退到 0（极端环境保护），但正常设备恒返回非负单调值。
 */

/**
 * 单调时钟当前值（毫秒）。连续调用非递减；不受墙钟回拨影响。
 */
public func monotonicNowMs(): Int64 {
    try {
        return SystemDateTime.getUptime(TimeType.Startup)
    } catch (e: BusinessException) {
        return 0
    }
}

/**
 * 自检：连续两次调用单调非递减。
 */
public func monotonicTimeSelfCheck(): Bool {
    let t0 = monotonicNowMs()
    let t1 = monotonicNowMs()
    // 单调：后一次不小于前一次。
    if (t1 < t0) { return false }
    // 非负。
    if (t0 < 0) { return false }
    return true
}
