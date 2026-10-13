package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import ohos_app_cangjie_entry.interop.*

/**
 * BadgeService — App 图标角标（未读数）服务 (P2-262)
 *
 * 对应 iOS 链路:
 *   AppDelegate.resetBadge() → context.applicationBadge → UIApplication.shared.applicationIconBadgeNumber = Int(count)
 *
 * HarmonyOS 等价链路（Phase 3 反转模式, SSOT §5）:
 *   BadgeService.setBadgeNumber(count) →
 *     Hilog(真) + Preferences 持久化(真) + 内存缓存(真) +
 *     callArk(BADGE_SET, {"count": n}) → [ArkTS] BadgeImpl.registerBadge → badgeManager.setBadgeNumber(n)
 *
 * INTEROP 契约 (D3, 双侧签名一致):
 *   method = BADGE_SET ("badge.set")
 *   argJson (CJ→ArkTS): {"count": <n>}   角标数在仓颉侧算好
 *   result (ArkTS→CJ):  {"ok": <bool>}   best-effort, 仅可选日志
 *
 * badgeManager.setBadgeNumber() 的真实系统调用搬到 ArkTS 侧 (ets/interop/impls/BadgeImpl.ets)，
 * 启动时 registerArkFunc 注册进仓颉；仓颉侧薄透传, fire-and-forget。
 *
 * 总未读数计算:
 *   遍历 ChatList 中所有非静音会话的 unreadCount 求和（对应 iOS context.applicationBadge）。
 *   当前无内存级 ChatList 快照 → calculateTotalUnreadCount() 返回持久化缓存值（可由外部写入）。
 *   外部（RealChatListService / UpdatesManager）在收到 updates 后调用 updateBadgeFromChats(chats)
 *   传入最新 Chat 列表，完成真实计算。
 */

private let BADGE_PREFS_NAME: String = "badge_service"
private let BADGE_KEY_COUNT: String = "badge_count"
private var _currentBadgeCount: Int32 = 0

public func getBadgeService(): BadgeService {
    return BadgeService()
}

public class BadgeService {

    /**
     * 设置应用图标角标（P2-262 主入口）
     *
     * 真实行为:
     *   1. 更新内存缓存 _currentBadgeCount
     *   2. 持久化到 Preferences（冷重启可恢复）
     *   3. Hilog 记录（真调用）
     *   4. [defer] ArkTS 桥接层应调用 badgeManager.setBadgeNumber(count)
     *
     * 对应 iOS: UIApplication.shared.applicationIconBadgeNumber = Int(count)
     */
    public func setBadgeNumber(count: Int32): Unit {
        _currentBadgeCount = count
        Hilog.info(0, "CjTelegram", "[Badge] setBadgeNumber: ${count}")
        this.persistBadgeCount(count)
        this.doSetBadgeViaArkInterop(count)
    }

    /**
     * 获取当前角标数（优先从 Preferences 恢复）
     */
    public func getBadgeNumber(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, BADGE_PREFS_NAME)
                    let val = prefs.get(BADGE_KEY_COUNT, PreferencesValueType.Integer(Int64(_currentBadgeCount)))
                    match (val) {
                        case PreferencesValueType.Integer(n) =>
                            _currentBadgeCount = Int32(n)
                        case _ => ()
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[Badge] getBadgeNumber prefs error: ${e}")
                }
            case None => ()
        }
        return _currentBadgeCount
    }

    /**
     * 从总未读数更新角标（caller 自行汇总非静音会话 unreadCount 后传入）
     *
     * 对应 iOS: context.applicationBadge（会话未读数聚合值）
     *   AppDelegate.resetBadge() → UIApplication.shared.applicationIconBadgeNumber = Int(count)
     *
     * @param totalUnread 所有非静音会话 unreadCount 之和
     */
    public func updateBadgeFromUnreadCounts(totalUnread: Int64): Unit {
        let clampedTotal: Int32 = if (totalUnread > 9999) { 9999 } else { Int32(totalUnread) }
        Hilog.info(0, "CjTelegram", "[Badge] updateBadgeFromUnreadCounts: total=${totalUnread} clamped=${clampedTotal}")
        this.setBadgeNumber(clampedTotal)
    }

    /**
     * 清除角标（对应 iOS applicationIconBadgeNumber = 0）
     */
    public func clearBadge(): Unit {
        this.setBadgeNumber(0)
        Hilog.info(0, "CjTelegram", "[Badge] clearBadge")
    }

    /**
     * 经 interop 反转调 ArkTS badgeManager.setBadgeNumber(count)
     *
     * 对应 HarmonyOS @kit.NotificationKit badgeManager.setBadgeNumber API（ArkTS-only）。
     * 真实系统调用与线程 hop 都在 ArkTS 侧 (ets/interop/impls/BadgeImpl.ets)，此处仅薄透传。
     * fire-and-forget：仓颉侧算好 count → callArk(BADGE_SET, {"count":...}) → ArkTS 异步设置。
     */
    private func doSetBadgeViaArkInterop(count: Int32): Unit {
        // argJson schema 与 ArkTS BadgeImpl 逐条对应 (D3): {"count": <n>}
        let argJson = "{\"count\":${count}}"
        callArk(BADGE_SET, argJson)
    }

    /**
     * 持久化角标数到 Preferences
     */
    private func persistBadgeCount(count: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, BADGE_PREFS_NAME)
                    prefs.put(BADGE_KEY_COUNT, PreferencesValueType.Integer(Int64(count)))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[Badge] persistBadgeCount error: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[Badge] persistBadgeCount: no context, in-memory only")
        }
    }
}
