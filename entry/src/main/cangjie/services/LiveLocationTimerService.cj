package ohos_app_cangjie_entry.services

import std.time.*
import kit.PerformanceAnalysisKit.Hilog

/**
 * LiveLocationTimerService — 实时位置计时器数据层
 *
 * 对应 iOS ChatMessageLiveLocationTimerNode 的时间计算逻辑。
 * 提供基于 beginTimestamp + timeout 的剩余时长计算，
 * 供 LiveLocationTimerComponent 消费。
 *
 * 调用链: LiveLocationTimerComponent → LiveLocationTimerService.getTimerState()
 *        LiveLocationTimerService → DateTime.now().toUnixTimeStamp().toSeconds()
 */

// 计时器状态快照
public class LiveLocationTimerState {
    // 进度值 [0.0, 1.0]：0.0 = 刚开始，1.0 = 已过期
    public var progress: Float64 = 0.0
    // 显示文案：剩余分钟数字符串，或 "∞"，或 "99+"
    public var label: String = ""
    // 是否为无限期共享（timeout < 0）
    public var isInfinite: Bool = false
    // 是否已过期
    public var isExpired: Bool = false

    public init() {}

    // 位置参数构造（仓颉构造器不支持命名参数调用方式，用位置参数）
    public init(p: Float64, lbl: String, inf: Bool, exp: Bool) {
        this.progress = p
        this.label = lbl
        this.isInfinite = inf
        this.isExpired = exp
    }
}

/**
 * LiveLocationTimerService — 计时数据计算服务
 *
 * beginTimestamp: Unix 时间戳（秒）— 共享开始时刻
 * timeout:        共享持续秒数；< 0 表示无限期
 */
public class LiveLocationTimerService {
    private var beginTimestamp: Float64 = 0.0
    private var timeout: Float64 = 0.0

    public init() {}

    /**
     * 设置计时参数
     * @param beginTimestamp Unix 时间戳（秒），共享开始时刻
     * @param timeout        共享持续秒数；< 0 = 无限期
     */
    public func update(beginTimestamp: Float64, timeout: Float64): Unit {
        this.beginTimestamp = beginTimestamp
        this.timeout = timeout
        Hilog.info(0, "CjTelegram", "[LiveLocationTimerService] update: begin=" + "${beginTimestamp}" + " timeout=" + "${timeout}")
    }

    /**
     * 返回当前计时器状态快照
     * 基于当前系统时间实时计算，每次调用都返回最新值。
     */
    public func getTimerState(): LiveLocationTimerState {
        if (this.timeout < 0.0) {
            // 无限期共享
            let s = LiveLocationTimerState()
            s.progress = 0.0
            s.label = "∞"
            s.isInfinite = true
            s.isExpired = false
            return s
        }

        let nowSecs = this.getCurrentUnixSeconds()
        let remaining = this.beginTimestamp + this.timeout - nowSecs

        if (remaining <= 0.0) {
            let s = LiveLocationTimerState()
            s.progress = 1.0
            s.label = "0"
            s.isInfinite = false
            s.isExpired = true
            return s
        }

        // progress: 已消耗比例 [0, 1]
        let rawProgress = if (this.timeout > 0.0) {
            1.0 - remaining / this.timeout
        } else {
            0.0
        }
        let progress = if (rawProgress < 0.0) {
            0.0
        } else if (rawProgress > 1.0) {
            1.0
        } else {
            rawProgress
        }

        let label: String
        let intRemaining = Int64(remaining)
        if (intRemaining > 60 * 60) {
            let hours = Int64(remaining / 3600.0 + 0.5)
            if (hours > 99) {
                label = "99+"
            } else {
                label = "${hours}h"
            }
        } else {
            let minutes = Int64(remaining / 60.0 + 0.5)
            label = "${minutes}"
        }

        Hilog.info(0, "CjTelegram", "[LiveLocationTimerService] state: label=" + label)

        let s = LiveLocationTimerState()
        s.progress = progress
        s.label = label
        s.isInfinite = false
        s.isExpired = false
        return s
    }

    /**
     * 获取当前 Unix 时间戳（秒，Float64）
     * 使用 DateTime.now().toUnixTimeStamp().toSeconds()
     */
    public func getCurrentUnixSeconds(): Float64 {
        let secs = DateTime.now().toUnixTimeStamp().toSeconds()
        return Float64(secs)
    }
}

// ==================== 模块级单例 / getter ====================

var _liveLocationTimerService: Option<LiveLocationTimerService> = None<LiveLocationTimerService>

/**
 * 获取 LiveLocationTimerService 单例
 */
public func getLiveLocationTimerService(): LiveLocationTimerService {
    match (_liveLocationTimerService) {
        case Some(svc) => svc
        case None =>
            let svc = LiveLocationTimerService()
            _liveLocationTimerService = Some(svc)
            svc
    }
}
