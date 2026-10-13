package ohos_app_cangjie_entry.services

import std.time.DateTime

/**
 * P2-092: 导入剩余时间估算器
 *
 * 对应 iOS ChatImportActivityScreen.swift private final class ProgressEstimator（L40-72）:
 *   - 维护指数移动平均（alpha=0.01）的每秒进度速率 averageProgressPerSecond
 *   - update(progress:) 在进度变化 >= 1% 或距上次 > 1s 时更新速率
 *   - 返回 remainingTime = (1.0 - progress) / averageProgressPerSecond
 *   - 速率 < 0.0001 时返回 -1.0（未知）
 *
 * 此类不持有 @State，纯计算逻辑，在 spawn{} 里调用无问题。
 */
public class ImportProgressEstimator {
    private var averageProgressPerSecond: Float64 = 0.0
    private var lastTimestampMs: Int64 = -1
    private var lastProgress: Float64 = -1.0

    public init() {}

    /**
     * 用当前进度更新估算器，返回估算剩余秒数。
     * 返回值 < 0 表示尚无可靠估算（速率太低 / 首次调用）。
     */
    public func update(progress!: Float64): Float64 {
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()

        if (this.lastTimestampMs < 0) {
            this.lastTimestampMs = nowMs
            this.lastProgress = progress
            return -1.0
        }

        let deltaProgress = progress - this.lastProgress
        let deltaMs = nowMs - this.lastTimestampMs
        let deltaSec = Float64(deltaMs) / 1000.0

        // 与 iOS 相同条件：进度变化 >= 0.01 或距上次 > 1s
        if (deltaProgress >= 0.01 || deltaSec > 1.0) {
            if (deltaSec > 0.0) {
                let immediateRate = deltaProgress / deltaSec
                let alpha: Float64 = 0.01
                if (this.averageProgressPerSecond < 0.000001) {
                    this.averageProgressPerSecond = immediateRate
                } else {
                    this.averageProgressPerSecond = alpha * immediateRate + (1.0 - alpha) * this.averageProgressPerSecond
                }
            }
            this.lastTimestampMs = nowMs
            this.lastProgress = progress
        }

        if (this.averageProgressPerSecond < 0.0001) {
            return -1.0
        }

        let remainingProgress = 1.0 - progress
        return remainingProgress / this.averageProgressPerSecond
    }
}
