package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.time.DateTime
import std.sync.ReentrantMutex

/**
 * 用户在线状态枚举
 * 对应 iOS EnginePeer.Presence.Status
 */
public enum UserPresenceStatus {
    | Online          // 当前在线（expires 未来）
    | Offline(Int32)  // 离线，携带 wasOnline Unix 时间戳
    | Recently        // 最近在线（lastActivity + 30s 以内 或 statusType=recently）
    | LastWeek        // 上周在线
    | LastMonth       // 上月在线
    | Empty           // 未知
}

/**
 * 格式化在线状态为本地化显示文案
 * 对应 iOS: EnginePeer.Presence → "online" / "last seen X minutes ago" / "last seen recently" 等
 */
public func formatPresenceText(status: UserPresenceStatus): String {
    match (status) {
        case UserPresenceStatus.Online =>
            return "online"
        case UserPresenceStatus.Recently =>
            return "last seen recently"
        case UserPresenceStatus.LastWeek =>
            return "last seen within a week"
        case UserPresenceStatus.LastMonth =>
            return "last seen within a month"
        case UserPresenceStatus.Empty =>
            return "last seen a long time ago"
        case UserPresenceStatus.Offline(wasOnline) =>
            return formatOfflineText(wasOnline)
    }
}

/**
 * 将 wasOnline Unix 时间戳格式化为 "last seen X ago" 文案
 */
func formatOfflineText(wasOnline: Int32): String {
    // 人工反馈 R2-3：对话框副标题与联系人列表行必须同一口径。
    // iOS PresenceStrings.stringForUserPresence 只有一套规则（just now / N minutes ago /
    // today at HH:MM / yesterday at HH:MM / dd/MM/yy），本函数原先的 "N hours ago / N days ago"
    // 是自造格式，改为直接复用 RealContactService.formatLastSeen（同包可见）。
    return formatLastSeen(wasOnline)
}

/**
 * 计算下次刷新文案的建议超时时间（秒）
 * 对应 iOS: suggestedUserPresenceStringRefreshTimeout
 *
 * 返回 -1.0 表示不需要定时刷新（Double.infinity 的等价物）
 */
public func suggestedRefreshTimeoutSeconds(status: UserPresenceStatus): Float64 {
    let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let nowSec = Int32(Int64(nowMs) / 1000)

    match (status) {
        case UserPresenceStatus.Online =>
            // 在线状态：1 秒后重检（对应 iOS 的 isOnline=true → 1.0）
            return 1.0
        case UserPresenceStatus.Recently =>
            // recently：lastActivity 语义已转为文案无需精确计时，30 秒后刷新一次
            return 30.0
        case UserPresenceStatus.Offline(wasOnline) =>
            let diff = nowSec - wasOnline
            if (diff < 0) {
                // wasOnline 还没到，等到那一刻
                return Float64(-diff + 1)
            }
            if (diff < 30) {
                // 30 秒内：等到满 30 秒再刷（从 "just now" → "X minutes ago"）
                return Float64((30 - diff) + 1)
            }
            if (diff < 3600) {
                // 1 小时内：等到下一整分钟
                return Float64((diff % 60) + 1)
            }
            // 超过 1 小时：无需自动刷新
            return -1.0
        case UserPresenceStatus.LastWeek =>
            return -1.0
        case UserPresenceStatus.LastMonth =>
            return -1.0
        case UserPresenceStatus.Empty =>
            return -1.0
    }
}

/**
 * 将 TLResponses.UserResponse 的 statusType / isOnline / wasOnline 字段
 * 映射为 UserPresenceStatus 枚举值
 */
public func presenceStatusFromFields(
    isOnline: Bool,
    wasOnline: Int32,
    statusType: String
): UserPresenceStatus {
    if (isOnline) {
        return UserPresenceStatus.Online
    }
    if (statusType == "recently") {
        return UserPresenceStatus.Recently
    }
    if (statusType == "lastWeek") {
        return UserPresenceStatus.LastWeek
    }
    if (statusType == "lastMonth") {
        return UserPresenceStatus.LastMonth
    }
    if (wasOnline > 0) {
        return UserPresenceStatus.Offline(wasOnline)
    }
    return UserPresenceStatus.Empty
}

// 单例
private var _ppsManagerServiceInstance: Option<PeerPresenceStatusManagerService> = None
private let _ppsManagerServiceMutex: ReentrantMutex = ReentrantMutex()

public func getPeerPresenceStatusManagerService(): PeerPresenceStatusManagerService {
    synchronized (_ppsManagerServiceMutex) {
        match (_ppsManagerServiceInstance) {
            case Some(inst) => return inst
            case None =>
                let inst = PeerPresenceStatusManagerService()
                _ppsManagerServiceInstance = Some(inst)
                return inst
        }
    }
}

/**
 * PeerPresenceStatusManager 核心服务
 *
 * 对应 iOS PeerPresenceStatusManager.swift：
 * - 持有一个 update 回调和一个定时器
 * - reset(presence:isOnline:) 取消旧定时器、根据 suggestedTimeout 启动新定时器
 * - 定时器到期后调用 update()，UI 层重新计算文案
 *
 * 仓颉实现：用 spawn + sleep 替代 Swift Timer；
 * cancelGeneration 机制确保旧 spawn 到期时若已被 reset 覆盖则不再触发回调。
 */
public class PeerPresenceStatusManagerService {
    private var _currentGeneration: Int64 = 0
    private let _mutex: ReentrantMutex = ReentrantMutex()

    /**
     * 为指定 peerId 重置定时器
     *
     * @param peerId        对方用户 ID（用于日志）
     * @param isOnline      是否当前在线（来自 API 实时推送，覆盖 statusType）
     * @param wasOnline     离线时间戳（0 表示无）
     * @param statusType    "online"/"offline"/"recently"/"lastWeek"/"lastMonth"/"empty"
     * @param onRefresh     到时回调（在新 spawn 里执行，调用方需自行处理线程安全）
     */
    public func reset(
        peerId: Int64,
        isOnline: Bool,
        wasOnline: Int32,
        statusType: String,
        onRefresh: () -> Unit
    ): Unit {
        let status = presenceStatusFromFields(isOnline, wasOnline, statusType)
        let timeoutSec = suggestedRefreshTimeoutSeconds(status)

        var myGenerationMut: Int64 = 0
        synchronized (_mutex) {
            _currentGeneration = _currentGeneration + 1
            myGenerationMut = _currentGeneration
        }
        let myGeneration = myGenerationMut

        if (timeoutSec < 0.0) {
            // 不需要定时刷新
            Hilog.info(0, "CjTelegram", "[PPSM] no refresh needed", [""])
            return
        }

        let sleepMs = Int64(timeoutSec * 1000.0)
        Hilog.info(0, "CjTelegram", "[PPSM] peer=%{public}s schedule refresh", [peerId.toString()])

        let _ = spawn {
            sleep(Duration.millisecond * sleepMs)
            // 检查当前 generation：若已被新 reset 覆盖则放弃
            var stillValid = false
            synchronized (_mutex) {
                stillValid = (_currentGeneration == myGeneration)
            }
            if (stillValid) {
                Hilog.info(0, "CjTelegram", "[PPSM] peer=%{public}s refresh triggered", [peerId.toString()])
                onRefresh()
            } else {
                Hilog.info(0, "CjTelegram", "[PPSM] peer=%{public}s refresh cancelled", [peerId.toString()])
            }
        }
    }

    /**
     * 取消当前定时器（不再触发任何回调）
     */
    public func cancel(): Unit {
        synchronized (_mutex) {
            _currentGeneration = _currentGeneration + 1
        }
        Hilog.info(0, "CjTelegram", "[PPSM] timer cancelled", [""])
    }

    /**
     * 计算并返回格式化文案（同步，无副作用）
     */
    public func formatText(
        isOnline: Bool,
        wasOnline: Int32,
        statusType: String
    ): String {
        let status = presenceStatusFromFields(isOnline, wasOnline, statusType)
        return formatPresenceText(status)
    }
}
