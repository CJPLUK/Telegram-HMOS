package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.sync.Monitor

/** 从 ChatListProjection 的已提交快照派生应用角标。 */
private var _badgeAggregatorInstance: Option<BadgeAggregator> = None
private let _badgeAggregatorInstanceMonitor = Monitor()

public func getBadgeAggregator(): BadgeAggregator {
    return synchronized(_badgeAggregatorInstanceMonitor) {
        match (_badgeAggregatorInstance) {
            case Some(instance) => instance
            case None =>
                let instance = BadgeAggregator()
                _badgeAggregatorInstance = Some(instance)
                instance
        }
    }
}

public class BadgeAggregator {
    private let _monitor = Monitor()
    private var _subscriptionToken: Int64 = -1
    private var _lastBadge: Int32 = -1

    public func initialize(): Unit {
        var shouldSubscribe = false
        synchronized(this._monitor) {
            if (this._subscriptionToken == -1) {
                this._subscriptionToken = -2
                shouldSubscribe = true
            }
        }
        if (!shouldSubscribe) { return }
        let token = getChatListProjection().addSubscriber({ snapshot: ChatListProjectionSnapshot =>
            this.apply(snapshot)
        })
        synchronized(this._monitor) { this._subscriptionToken = token }
    }

    // diag-suite_settings_notifications-TC-0439-round3.md FIX-B + TC-0441-round4.md
    // F-3：静音过滤与 tag 过滤是两条独立规则，逐条对位源侧。
    // 静音：源侧角标恒走 .filtered 口径（RenderedTotalUnreadCount.swift:12-16 只有
    // .filtered 一个 case；ChatListIndexTable.swift:763-765 只对未被静音移出总计数的
    // peer 累加），静音会话恒不计入，本屏无 UI 可切——按此改为无条件跳过（不是删掉这
    // 条判断，是把它从「可关闭的开关」改成「恒定规则」，与「不要保留旧的 muted 过滤」
    // 这句处方的本意一致；若按字面把该行整体删除，会等价于旧 includeMuted=true 的效
    // 果，静音会话反而开始计入角标，与源侧结果相反，故不采用逐字删除）。
    // tag 过滤：对位 SyncCore_StandaloneAccountTransaction.swift:52-74 peer→tag 分类，
    // 超级群同时置 isChannel 与 isGroup（core/storage/postbox/PeerTable.cj:279-286），
    // 频道判定须先测 isMegagroup。models/Chat.cj 无联系人标记，.contact/.nonContact 两
    // 位在源侧恒同进同出且 regular 位本屏不可切，故非 bot 会话统一按 BADGE_TAG_NON_CONTACT
    // 判定，与取 .contact 在本屏任何可达状态下结果相同。
    private func apply(snapshot: ChatListProjectionSnapshot): Unit {
        if (snapshot.generation == 0) { return }
        let settings = getTelegramCoreSettingsService()
        let includeTags = settings.getBadgeIncludeTags()
        let countMessages = settings.getBadgeCountMessages()
        var total: Int64 = 0
        for (chat in snapshot.chats) {
            if (chat.unreadCount <= 0) { continue }
            if (chat.isMuted) { continue }
            let tag: Int32 = if (chat.isChannel && !chat.isMegagroup) {
                BADGE_TAG_CHANNEL
            } else if (chat.isChannel || chat.isGroup) {
                BADGE_TAG_GROUP
            } else if (chat.isBot) {
                BADGE_TAG_BOT
            } else {
                BADGE_TAG_NON_CONTACT
            }
            if ((includeTags & tag) == 0) { continue }
            if (countMessages) {
                total += chat.unreadCount
            } else {
                total += 1
            }
        }
        let next = if (total > 9999) { Int32(9999) } else { Int32(total) }
        var changed = false
        synchronized(this._monitor) {
            if (next != this._lastBadge) {
                this._lastBadge = next
                changed = true
            }
        }
        if (changed) {
            getBadgeService().setBadgeNumber(next)
            Hilog.info(0, "CjTelegram",
                "[BadgeAggregator] generation=${snapshot.generation}, badge=${next}, includeTags=${includeTags}, byMessages=${countMessages}")
        }
    }
}
