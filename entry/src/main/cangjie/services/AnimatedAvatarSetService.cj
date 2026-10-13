package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.collection.HashMap
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * AvatarItem — 单个头像的数据模型
 *
 * 对应 iOS AnimatedAvatarSetContext.Content.Item
 */
public class AvatarItem {
    public var userId: Int64
    public var displayName: String
    public var photoUrl: String
    public var avatarColor: Int64

    public init(userId: Int64, displayName: String, photoUrl: String, avatarColor: Int64) {
        this.userId = userId
        this.displayName = displayName
        this.photoUrl = photoUrl
        this.avatarColor = avatarColor
    }
}

/**
 * AnimatedAvatarSetService — 头像堆叠数据服务
 *
 * 对应 iOS AnimatedAvatarSetContext（AnimatedAvatarSetNode.swift）
 *
 * 功能:
 * - 从 UserPhotoService 组装多个用户头像数据
 * - 跟踪当前显示的用户列表（已读/反应等场景）
 * - 提供 AvatarItem 数组供 AnimatedAvatarSetComponent 渲染
 * - 支持增量更新（新增/移除用户时通知 UI 变更）
 */
private var _animatedAvatarSetServiceInstance: Option<AnimatedAvatarSetService> = None

public func getAnimatedAvatarSetService(): AnimatedAvatarSetService {
    match (_animatedAvatarSetServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = AnimatedAvatarSetService()
            _animatedAvatarSetServiceInstance = Some(inst)
            return inst
    }
}

public class AnimatedAvatarSetService {
    // Current set of user IDs being displayed
    private var currentUserIds: ArrayList<Int64> = ArrayList<Int64>()
    // Per-context avatar item lists, keyed by context ID (e.g. message ID)
    private var contextItems: HashMap<Int64, ArrayList<AvatarItem>> = HashMap<Int64, ArrayList<AvatarItem>>()
    // Change callbacks: (contextId, items) -> Unit
    private var changeCallbacks: ArrayList<(Int64, ArrayList<AvatarItem>) -> Unit> = ArrayList<(Int64, ArrayList<AvatarItem>) -> Unit>()

    // Predefined avatar colors for fallback initials display
    private let avatarColors: Array<Int64> = [
        0xFF5733,
        0x337AFF,
        0x33B5FF,
        0xFF3399,
        0x33CC99,
        0xFFB533,
        0x9933FF,
        0xFF6633
    ]

    /**
     * Update the avatar set for a given context (e.g. message readers/reactions).
     *
     * Corresponds to iOS AnimatedAvatarSetContext.update(peers:animated:)
     *
     * Returns the assembled AvatarItem list for immediate rendering.
     */
    public func update(contextId: Int64, userIds: ArrayList<Int64>): ArrayList<AvatarItem> {
        let photoService = getUserPhotoService()
        let items = ArrayList<AvatarItem>()

        for (i in 0..userIds.size) {
            let userId = userIds[i]
            let photoUrl = photoService.getUserPhotoPath(userId)
            let user = photoService.getCachedUser(userId)
            let displayName: String = match (user) {
                case Some(u) =>
                    let full = u.firstName + (if (u.lastName.size > 0) { " " + u.lastName } else { "" })
                    full
                case None => ""
            }
            let colorIndex = Int64(userId % Int64(this.avatarColors.size))
            let safeIndex = if (colorIndex < 0) { -colorIndex } else { colorIndex }
            let color = this.avatarColors[safeIndex]
            items.add(AvatarItem(userId, displayName, photoUrl, color))
        }

        this.contextItems[contextId] = items
        Hilog.info(0, "CjTelegram", "[AvatarSetSvc] update ctx=${contextId} count=${items.size}")

        for (cb in this.changeCallbacks) {
            try {
                cb(contextId, items)
            } catch (_e: Exception) {}
        }

        return items
    }

    /**
     * Get the current avatar items for a context.
     * Returns an empty list if the context has not been initialized.
     */
    public func getItems(contextId: Int64): ArrayList<AvatarItem> {
        if (this.contextItems.contains(contextId)) {
            return this.contextItems[contextId]
        }
        return ArrayList<AvatarItem>()
    }

    /**
     * Register a change callback fired when update() is called for a context.
     */
    public func addChangeCallback(callback: (Int64, ArrayList<AvatarItem>) -> Unit): Unit {
        this.changeCallbacks.add(callback)
    }

    /**
     * Trigger full photo download for all users in the given context.
     * When a full photo arrives, the UI should call update() again to refresh.
     */
    public func requestFullPhotos(contextId: Int64): Unit {
        if (this.contextItems.contains(contextId)) {
            let items = this.contextItems[contextId]
            let photoService = getUserPhotoService()
            let userIds = ArrayList<Int64>()
            for (item in items) {
                userIds.add(item.userId)
            }
            photoService.requestFullPhotosForUsers(userIds)
        }
    }

    /**
     * Clear all context state (e.g. when chat is closed).
     */
    public func clearContext(contextId: Int64): Unit {
        if (this.contextItems.contains(contextId)) {
            this.contextItems.remove(contextId)
        }
        Hilog.info(0, "CjTelegram", "[AvatarSetSvc] clearContext ctx=${contextId}")
    }

    /**
     * Build avatar items for a snapshot of user IDs without persisting them.
     * Useful for one-shot rendering (e.g. in message bubble reuse).
     */
    public func buildItems(userIds: ArrayList<Int64>): ArrayList<AvatarItem> {
        let photoService = getUserPhotoService()
        let items = ArrayList<AvatarItem>()
        for (i in 0..userIds.size) {
            let userId = userIds[i]
            let photoUrl = photoService.getUserPhotoPath(userId)
            let user = photoService.getCachedUser(userId)
            let displayName: String = match (user) {
                case Some(u) =>
                    let full = u.firstName + (if (u.lastName.size > 0) { " " + u.lastName } else { "" })
                    full
                case None => ""
            }
            let colorIndex = Int64(userId % Int64(this.avatarColors.size))
            let safeIndex = if (colorIndex < 0) { -colorIndex } else { colorIndex }
            let color = this.avatarColors[safeIndex]
            items.add(AvatarItem(userId, displayName, photoUrl, color))
        }
        return items
    }
}
