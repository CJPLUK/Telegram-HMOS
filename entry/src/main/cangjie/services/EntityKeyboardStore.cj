package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import std.collection.{ArrayList, HashMap}
import std.time.DateTime
import ohos_app_cangjie_entry.core.storage.getAuthStorage

/**
 * 一次 Entity Keyboard 数据访问所属的账号快照。
 *
 * slot 用于兼容现有多账号模型，userId 防止账号退出后 slot 被复用时读到旧数据；
 * generation 用于拒绝切号前发起、切号后才返回的异步请求写入缓存。
 */
public class EntityKeyboardAccountToken {
    public let slot: Int32
    public let userId: Int64
    public let generation: Int64

    public init(slot: Int32, userId: Int64, generation: Int64) {
        this.slot = slot
        this.userId = userId
        this.generation = generation
    }
}

/**
 * Sticker 面板的一次完整、只读状态快照。
 *
 * 数组引用发布后不再由 Store 原地修改；后续变化创建新快照，保证 UI 一次只观察到
 * 同一 version 的组合状态，避免 recent/installed/featured 分别回包造成中间空状态。
 */
public class StickerKeyboardSnapshot {
    public let accountGeneration: Int64
    public let version: Int64
    public let isLoading: Bool
    public let recent: Array<StickerItem>
    public let faved: Array<StickerItem>
    public let installedPacks: Array<StickerPackInfo>
    public let installedDetails: Array<StickerPackDetail>
    public let featuredPacks: Array<StickerPackInfo>
    public let stickerSearchCategories: Array<EmojiGroupInfo>

    public init(
        accountGeneration: Int64,
        version: Int64,
        isLoading: Bool,
        recent: Array<StickerItem>,
        faved: Array<StickerItem>,
        installedPacks: Array<StickerPackInfo>,
        installedDetails: Array<StickerPackDetail>,
        featuredPacks: Array<StickerPackInfo>,
        stickerSearchCategories: Array<EmojiGroupInfo>
    ) {
        this.accountGeneration = accountGeneration
        this.version = version
        this.isLoading = isLoading
        this.recent = recent
        this.faved = faved
        this.installedPacks = installedPacks
        this.installedDetails = installedDetails
        this.featuredPacks = featuredPacks
        this.stickerSearchCategories = stickerSearchCategories
    }
}

/**
 * iOS `CloudEmojiPacks` + Featured Emoji + Emoji Search Categories 的账号快照。
 * 与 Sticker 快照分离，防止把 messages.getAllStickers 误当成自定义 Emoji 包索引。
 */
public class EmojiKeyboardSnapshot {
    public let accountGeneration: Int64
    public let version: Int64
    public let isLoading: Bool
    public let installedPacks: Array<StickerPackInfo>
    public let installedDetails: Array<StickerPackDetail>
    public let featuredPacks: Array<StickerPackInfo>
    public let searchCategories: Array<EmojiGroupInfo>

    public init(
        accountGeneration: Int64,
        version: Int64,
        isLoading: Bool,
        installedPacks: Array<StickerPackInfo>,
        installedDetails: Array<StickerPackDetail>,
        featuredPacks: Array<StickerPackInfo>,
        searchCategories: Array<EmojiGroupInfo>
    ) {
        this.accountGeneration = accountGeneration
        this.version = version
        this.isLoading = isLoading
        this.installedPacks = installedPacks
        this.installedDetails = installedDetails
        this.featuredPacks = featuredPacks
        this.searchCategories = searchCategories
    }
}

private func emptyStickerSnapshot(generation: Int64, version: Int64, isLoading: Bool): StickerKeyboardSnapshot {
    return StickerKeyboardSnapshot(
        generation,
        version,
        isLoading,
        Array<StickerItem>(0, repeat: StickerItem()),
        Array<StickerItem>(0, repeat: StickerItem()),
        Array<StickerPackInfo>(0, repeat: StickerPackInfo()),
        Array<StickerPackDetail>(0, repeat: StickerPackDetail()),
        Array<StickerPackInfo>(0, repeat: StickerPackInfo()),
        Array<EmojiGroupInfo>(0, repeat: EmojiGroupInfo())
    )
}

private func emptyEmojiSnapshot(
    generation: Int64, version: Int64, isLoading: Bool
): EmojiKeyboardSnapshot {
    return EmojiKeyboardSnapshot(
        generation,
        version,
        isLoading,
        Array<StickerPackInfo>(0, repeat: StickerPackInfo()),
        Array<StickerPackDetail>(0, repeat: StickerPackDetail()),
        Array<StickerPackInfo>(0, repeat: StickerPackInfo()),
        Array<EmojiGroupInfo>(0, repeat: EmojiGroupInfo())
    )
}

/**
 * messages.getAllStickers returns StickerSet objects without documents, so a
 * republished installed-pack index would drop the covers that
 * publishStickerPackDetail derived from each set's first sticker (the nav bar
 * then shows a spinner per pack). Keep a known cover: from the loaded detail
 * first (iOS falls back to the set's first item when there is no thumbnail),
 * else from the previous index entry.
 */
private func installedPacksKeepingCovers(
    packs: Array<StickerPackInfo>,
    previous: Array<StickerPackInfo>,
    details: Array<StickerPackDetail>
): Array<StickerPackInfo> {
    let result = ArrayList<StickerPackInfo>()
    for (pack in packs) {
        if (pack.cover.documentId != 0) {
            result.add(pack)
            continue
        }
        var cover = StickerItem()
        for (detail in details) {
            if (detail.info.id == pack.id && !detail.stickers.isEmpty()) {
                cover = detail.stickers[0]
                break
            }
        }
        if (cover.documentId == 0) {
            for (old in previous) {
                if (old.id == pack.id && old.cover.documentId != 0) {
                    cover = old.cover
                    break
                }
            }
        }
        result.add(if (cover.documentId != 0) { copyStickerPackWithCover(pack, cover) } else { pack })
    }
    return result.toArray()
}

private func copyStickerPackWithCover(
    source: StickerPackInfo, cover: StickerItem
): StickerPackInfo {
    let result = StickerPackInfo()
    result.id = source.id
    result.accessHash = source.accessHash
    result.title = source.title
    result.shortName = source.shortName
    result.count = source.count
    result.hash = source.hash
    result.isAnimated = source.isAnimated
    result.isVideo = source.isVideo
    result.isEmoji = source.isEmoji
    result.isInstalled = source.isInstalled
    result.isArchived = source.isArchived
    result.thumbDocumentId = source.thumbDocumentId
    result.isUnread = source.isUnread
    result.featuredIsPremium = source.featuredIsPremium
    result.cover = cover
    result.topItems = source.topItems
    return result
}

/** 复制贴纸包并显式覆盖安装状态，避免乐观更新原地修改服务层共享对象。 */
private func copyStickerPackWithInstalledState(
    source: StickerPackInfo, installed: Bool, archived: Bool
): StickerPackInfo {
    let result = copyStickerPackWithCover(source, source.cover)
    result.isInstalled = installed
    result.isArchived = archived
    return result
}

/**
 * iOS 的聊天贴纸分类保持服务端顺序，但会把 Premium 分类移到末尾。
 * 在 Store 发布边界统一排序，避免磁盘快照与网络快照呈现不同顺序。
 */
private func orderedStickerSearchCategories(
    groups: Array<EmojiGroupInfo>
): Array<EmojiGroupInfo> {
    let result = ArrayList<EmojiGroupInfo>()
    for (group in groups) {
        if (!group.isPremium) { result.add(group) }
    }
    for (group in groups) {
        if (group.isPremium) { result.add(group) }
    }
    return result.toArray()
}

private let entityKeyboardStoreInstanceMonitor = Monitor()
private var entityKeyboardStoreInstance: Option<EntityKeyboardStore> = None

public func getEntityKeyboardStore(): EntityKeyboardStore {
    return synchronized(entityKeyboardStoreInstanceMonitor) {
        match (entityKeyboardStoreInstance) {
            case Some(instance) => instance
            case None =>
                let instance = EntityKeyboardStore()
                entityKeyboardStoreInstance = Some(instance)
                instance
        }
    }
}

/**
 * Entity Keyboard 的账号所有权中心。
 *
 * 不缓存 AuthStorage 对象，也不依赖 UI 生命周期。每次进入网络/磁盘边界时重新核对
 * active slot 与 userId；二者任一变化都会推进 generation。这样即使账号切换通知与
 * 后台任务存在时序差，旧任务也无法把结果写到新账号的缓存空间。
 */
public class EntityKeyboardStore {
    private let monitor = Monitor()
    private var initialized: Bool = false
    private var activeSlot: Int32 = -1
    private var activeUserId: Int64 = 0
    private var generation: Int64 = 0
    private var stickerSnapshot: StickerKeyboardSnapshot = emptyStickerSnapshot(0, 0, false)
    private var stickerSnapshotVersion: Int64 = 0
    private var stickerActualizingGeneration: Int64 = -1
    private var stickerActualizePending: Int32 = 0
    private var stickerLastActualizedGeneration: Int64 = -1
    private var stickerLastActualizedAtMs: Int64 = 0
    private var stickerRemoteInvalidationPending: Bool = false
    private var nextStickerListenerId: Int64 = 0
    private var stickerListeners: HashMap<Int64, (StickerKeyboardSnapshot) -> Unit> =
        HashMap<Int64, (StickerKeyboardSnapshot) -> Unit>()
    private var peerStickerPacks: HashMap<String, StickerPackDetail> =
        HashMap<String, StickerPackDetail>()
    private var peerEmojiPacks: HashMap<String, StickerPackDetail> =
        HashMap<String, StickerPackDetail>()
    private var emojiSnapshot: EmojiKeyboardSnapshot = emptyEmojiSnapshot(0, 0, false)
    private var emojiSnapshotVersion: Int64 = 0
    private var emojiActualizingGeneration: Int64 = -1
    private var emojiActualizePending: Int32 = 0
    private var emojiLastActualizedGeneration: Int64 = -1
    private var emojiLastActualizedAtMs: Int64 = 0
    private var emojiRemoteInvalidationPending: Bool = false
    private var nextEmojiListenerId: Int64 = 0
    private var emojiListeners: HashMap<Int64, (EmojiKeyboardSnapshot) -> Unit> =
        HashMap<Int64, (EmojiKeyboardSnapshot) -> Unit>()

    public init() {}

    /** 获取当前账号不可变快照；账号身份变化时推进 generation。 */
    public func currentToken(): EntityKeyboardAccountToken {
        let storage = getAuthStorage()
        let slot = storage.getActiveSlot()
        let userId = match (storage.getUserData()) {
            case Some(user) => user.id
            case None => 0
        }
        var accountChanged = false
        let token = synchronized(this.monitor) {
            if (!this.initialized || this.activeSlot != slot || this.activeUserId != userId) {
                this.initialized = true
                this.activeSlot = slot
                this.activeUserId = userId
                this.generation = this.generation + 1
                this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
                this.stickerSnapshot = emptyStickerSnapshot(
                    this.generation, this.stickerSnapshotVersion, false)
                this.stickerActualizingGeneration = -1
                this.stickerActualizePending = 0
                this.stickerLastActualizedGeneration = -1
                this.stickerLastActualizedAtMs = 0
                this.stickerRemoteInvalidationPending = false
                this.peerStickerPacks = HashMap<String, StickerPackDetail>()
                this.peerEmojiPacks = HashMap<String, StickerPackDetail>()
                this.emojiSnapshotVersion = this.emojiSnapshotVersion + 1
                this.emojiSnapshot = emptyEmojiSnapshot(
                    this.generation, this.emojiSnapshotVersion, false)
                this.emojiActualizingGeneration = -1
                this.emojiActualizePending = 0
                this.emojiLastActualizedGeneration = -1
                this.emojiLastActualizedAtMs = 0
                this.emojiRemoteInvalidationPending = false
                accountChanged = true
                Hilog.info(0, "CjTelegram",
                    "[EntityKeyboardStore] account generation=${this.generation} slot=${slot} authorized=${userId != 0}")
            }
            EntityKeyboardAccountToken(slot, userId, this.generation)
        }
        if (accountChanged) {
            this.notifyStickerListeners(this.stickerSnapshot)
            this.notifyEmojiListeners(this.emojiSnapshot)
        }
        return token
    }

    /** 请求回包或异步写盘前调用；false 表示任务已经属于旧账号。 */
    public func isCurrent(token: EntityKeyboardAccountToken): Bool {
        let current = this.currentToken()
        return current.slot == token.slot &&
            current.userId == token.userId &&
            current.generation == token.generation
    }

    /** Preferences 使用的账号作用域 key。 */
    public func preferencesKey(baseKey: String, token: EntityKeyboardAccountToken): String {
        return "entity_keyboard_v2_slot_${token.slot}_user_${token.userId}_${baseKey}"
    }

    /** 文件缓存使用的稳定、安全后缀。 */
    public func cacheFileSuffix(token: EntityKeyboardAccountToken): String {
        return "slot_${token.slot}_user_${token.userId}"
    }

    /**
     * 旧版本只有一个全局缓存。为保持单账号升级体验，仅 slot 0 可接收旧缓存；
     * 其他账号必须等待自己的服务端数据，避免同一份旧数据被复制到多个账号。
     */
    public func canMigrateLegacy(token: EntityKeyboardAccountToken): Bool {
        return token.slot == 0 && token.userId != 0
    }

    /** AccountManager 在 active slot 提交后主动调用，确保 UI 通知前已推进 generation。 */
    public func accountDidSwitch(expectedSlot: Int32): Unit {
        let token = this.currentToken()
        if (token.slot != expectedSlot) {
            Hilog.info(0, "CjTelegram",
                "[EntityKeyboardStore] account switch slot mismatch expected=${expectedSlot} actual=${token.slot}")
        }
    }

    /** 当前 Sticker 快照；首次访问会同步核对账号身份。 */
    public func currentStickerSnapshot(): StickerKeyboardSnapshot {
        let token = this.currentToken()
        return synchronized(this.monitor) {
            if (this.stickerSnapshot.accountGeneration != token.generation) {
                this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
                this.stickerSnapshot = emptyStickerSnapshot(
                    token.generation, this.stickerSnapshotVersion, false)
            }
            this.stickerSnapshot
        }
    }

    /** 订阅 Sticker 快照；注册后立即回放当前值。 */
    public func subscribeStickerSnapshot(
        listener: (StickerKeyboardSnapshot) -> Unit
    ): Int64 {
        let snapshot = this.currentStickerSnapshot()
        let id = synchronized(this.monitor) {
            let next = this.nextStickerListenerId
            this.nextStickerListenerId = this.nextStickerListenerId + 1
            this.stickerListeners[next] = listener
            next
        }
        listener(snapshot)
        return id
    }

    public func unsubscribeStickerSnapshot(id: Int64): Unit {
        synchronized(this.monitor) { let _ = this.stickerListeners.remove(id) }
    }

    /** ChannelFull.stickerset is chat-scoped and must not pollute installed packs. */
    public func publishPeerStickerPack(
        token: EntityKeyboardAccountToken,
        peerType: String,
        peerId: Int64,
        detail: StickerPackDetail
    ): Unit {
        if (!detail.success || detail.stickers.isEmpty() || !this.isCurrent(token)) { return }
        let key = "${peerType}:${peerId}"
        synchronized(this.monitor) { this.peerStickerPacks[key] = detail }
        this.notifyStickerListeners(this.currentStickerSnapshot())
    }

    public func currentPeerStickerPack(peerType: String, peerId: Int64): Option<StickerPackDetail> {
        let _ = this.currentToken()
        let key = "${peerType}:${peerId}"
        return synchronized(this.monitor) {
            if (this.peerStickerPacks.contains(key)) {
                Some(this.peerStickerPacks[key])
            } else {
                None<StickerPackDetail>
            }
        }
    }

    /** ChannelFull.emojiset is a peer group, not an installed CloudEmojiPack. */
    public func publishPeerEmojiPack(
        token: EntityKeyboardAccountToken,
        peerType: String,
        peerId: Int64,
        detail: StickerPackDetail
    ): Unit {
        if (!detail.success || detail.stickers.isEmpty() || !this.isCurrent(token)) { return }
        let key = "${peerType}:${peerId}"
        synchronized(this.monitor) { this.peerEmojiPacks[key] = detail }
        this.notifyEmojiListeners(this.currentEmojiSnapshot())
    }

    public func currentPeerEmojiPack(peerType: String, peerId: Int64): Option<StickerPackDetail> {
        let _ = this.currentToken()
        let key = "${peerType}:${peerId}"
        return synchronized(this.monitor) {
            if (this.peerEmojiPacks.contains(key)) {
                Some(this.peerEmojiPacks[key])
            } else {
                None<StickerPackDetail>
            }
        }
    }

    private func notifyStickerListeners(snapshot: StickerKeyboardSnapshot): Unit {
        let callbacks = synchronized(this.monitor) {
            let result = ArrayList<(StickerKeyboardSnapshot) -> Unit>()
            for ((_, callback) in this.stickerListeners) { result.add(callback) }
            result
        }
        for (callback in callbacks) {
            try { callback(snapshot) } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[EntityKeyboardStore] sticker listener failed: ${e}")
            }
        }
    }

    private func replaceStickerSnapshot(
        token: EntityKeyboardAccountToken,
        isLoading: Bool,
        recent: Array<StickerItem>,
        faved: Array<StickerItem>,
        installedPacks: Array<StickerPackInfo>,
        installedDetails: Array<StickerPackDetail>,
        featuredPacks: Array<StickerPackInfo>,
        stickerSearchCategories: Array<EmojiGroupInfo>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let orderedCategories = orderedStickerSearchCategories(stickerSearchCategories)
        let next = synchronized(this.monitor) {
            this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
            let value = StickerKeyboardSnapshot(
                token.generation,
                this.stickerSnapshotVersion,
                isLoading,
                recent,
                faved,
                installedPacks,
                installedDetails,
                featuredPacks,
                orderedCategories
            )
            this.stickerSnapshot = value
            value
        }
        this.notifyStickerListeners(next)
    }

    public func publishStickerIndex(
        token: EntityKeyboardAccountToken,
        recent: Array<StickerItem>,
        faved: Array<StickerItem>,
        installedPacks: Array<StickerPackInfo>,
        featuredPacks: Array<StickerPackInfo>,
        stickerSearchCategories: Array<EmojiGroupInfo>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let orderedCategories = orderedStickerSearchCategories(stickerSearchCategories)
        let next = synchronized(this.monitor) {
            let current = this.stickerSnapshot
            this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
            let value = StickerKeyboardSnapshot(token.generation, this.stickerSnapshotVersion,
                current.isLoading, recent, faved,
                installedPacksKeepingCovers(installedPacks, current.installedPacks, current.installedDetails),
                current.installedDetails, featuredPacks, orderedCategories)
            this.stickerSnapshot = value
            value
        }
        this.notifyStickerListeners(next)
    }

    public func publishRecentStickers(
        token: EntityKeyboardAccountToken, items: Array<StickerItem>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let next = synchronized(this.monitor) {
            let current = this.stickerSnapshot
            this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
            let value = StickerKeyboardSnapshot(token.generation, this.stickerSnapshotVersion,
                current.isLoading, items, current.faved, current.installedPacks,
                current.installedDetails, current.featuredPacks, current.stickerSearchCategories)
            this.stickerSnapshot = value
            value
        }
        this.notifyStickerListeners(next)
    }

    /** 与 iOS addRecentlyUsedSticker 一致：本地立即移到首位，云端同步由调用方异步完成。 */
    public func recordRecentlyUsedSticker(
        token: EntityKeyboardAccountToken, item: StickerItem
    ): Unit {
        if (item.documentId == 0 || !this.isCurrent(token)) { return }
        let items = ArrayList<StickerItem>()
        items.add(item)
        let current = this.currentStickerSnapshot()
        for (existing in current.recent) {
            if (existing.documentId != item.documentId && items.size < 20) { items.add(existing) }
        }
        this.publishRecentStickers(token, items.toArray())
    }

    public func publishFavedStickers(
        token: EntityKeyboardAccountToken, items: Array<StickerItem>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let next = synchronized(this.monitor) {
            let current = this.stickerSnapshot
            this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
            let value = StickerKeyboardSnapshot(token.generation, this.stickerSnapshotVersion,
                current.isLoading, current.recent, items, current.installedPacks,
                current.installedDetails, current.featuredPacks, current.stickerSearchCategories)
            this.stickerSnapshot = value
            value
        }
        this.notifyStickerListeners(next)
    }

    public func publishInstalledPacks(
        token: EntityKeyboardAccountToken, packs: Array<StickerPackInfo>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let next = synchronized(this.monitor) {
            let current = this.stickerSnapshot
            this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
            let value = StickerKeyboardSnapshot(token.generation, this.stickerSnapshotVersion,
                current.isLoading, current.recent, current.faved,
                installedPacksKeepingCovers(packs, current.installedPacks, current.installedDetails),
                current.installedDetails, current.featuredPacks, current.stickerSearchCategories)
            this.stickerSnapshot = value
            value
        }
        this.notifyStickerListeners(next)
    }

    /**
     * 与 iOS installedStickerPacks 的 transaction 行为一致：先在本地快照插入贴纸包，
     * RPC 在后台提交。返回发布后的 version，调用方可据此执行不覆盖后续状态的回滚。
     */
    public func optimisticallyInstallStickerPack(
        token: EntityKeyboardAccountToken,
        pack: StickerPackInfo,
        stickers: Array<StickerItem>
    ): Int64 {
        if (pack.id == 0 || !this.isCurrent(token)) { return -1 }
        var published: Option<StickerKeyboardSnapshot> = None
        let version = synchronized(this.monitor) {
            let current = this.stickerSnapshot
            let packs = ArrayList<StickerPackInfo>()
            let installed = copyStickerPackWithInstalledState(pack, true, false)
            if (!stickers.isEmpty()) { installed.cover = stickers[0] }
            packs.add(installed)
            for (existing in current.installedPacks) {
                if (existing.id != pack.id) { packs.add(existing) }
            }

            let details = ArrayList<StickerPackDetail>()
            if (!stickers.isEmpty()) {
                let detail = StickerPackDetail()
                detail.info = installed
                for (item in stickers) { detail.stickers.add(item) }
                detail.success = true
                details.add(detail)
            }
            for (existing in current.installedDetails) {
                if (existing.info.id != pack.id) { details.add(existing) }
            }

            this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
            let value = StickerKeyboardSnapshot(token.generation, this.stickerSnapshotVersion,
                current.isLoading, current.recent, current.faved, packs.toArray(),
                details.toArray(), current.featuredPacks, current.stickerSearchCategories)
            this.stickerSnapshot = value
            published = Some(value)
            value.version
        }
        match (published) {
            case Some(value) => this.notifyStickerListeners(value)
            case None => ()
        }
        return version
    }

    /** 乐观卸载/归档：同时移除索引与详情，避免导航仍指向已经移除的分组。 */
    public func optimisticallyRemoveStickerPack(
        token: EntityKeyboardAccountToken, packId: Int64
    ): Int64 {
        if (packId == 0 || !this.isCurrent(token)) { return -1 }
        var published: Option<StickerKeyboardSnapshot> = None
        let version = synchronized(this.monitor) {
            let current = this.stickerSnapshot
            let packs = ArrayList<StickerPackInfo>()
            for (pack in current.installedPacks) {
                if (pack.id != packId) { packs.add(pack) }
            }
            let details = ArrayList<StickerPackDetail>()
            for (detail in current.installedDetails) {
                if (detail.info.id != packId) { details.add(detail) }
            }
            this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
            let value = StickerKeyboardSnapshot(token.generation, this.stickerSnapshotVersion,
                current.isLoading, current.recent, current.faved, packs.toArray(),
                details.toArray(), current.featuredPacks, current.stickerSearchCategories)
            this.stickerSnapshot = value
            published = Some(value)
            value.version
        }
        match (published) {
            case Some(value) => this.notifyStickerListeners(value)
            case None => ()
        }
        return version
    }

    /** 保持服务端 order 的稳定分组顺序，并让详情顺序与顶部导航同步。 */
    public func optimisticallyReorderStickerPacks(
        token: EntityKeyboardAccountToken, order: Array<Int64>
    ): Int64 {
        if (!this.isCurrent(token)) { return -1 }
        var published: Option<StickerKeyboardSnapshot> = None
        let version = synchronized(this.monitor) {
            let current = this.stickerSnapshot
            let packs = ArrayList<StickerPackInfo>()
            let details = ArrayList<StickerPackDetail>()
            for (id in order) {
                for (pack in current.installedPacks) {
                    if (pack.id == id) { packs.add(pack) }
                }
                for (detail in current.installedDetails) {
                    if (detail.info.id == id) { details.add(detail) }
                }
            }
            // 未参与这次类型内重排的包（例如 Emoji 包）保持原相对顺序并放在尾部。
            for (pack in current.installedPacks) {
                var found = false
                for (id in order) { if (pack.id == id) { found = true } }
                if (!found) { packs.add(pack) }
            }
            for (detail in current.installedDetails) {
                var found = false
                for (id in order) { if (detail.info.id == id) { found = true } }
                if (!found) { details.add(detail) }
            }
            this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
            let value = StickerKeyboardSnapshot(token.generation, this.stickerSnapshotVersion,
                current.isLoading, current.recent, current.faved, packs.toArray(),
                details.toArray(), current.featuredPacks, current.stickerSearchCategories)
            this.stickerSnapshot = value
            published = Some(value)
            value.version
        }
        match (published) {
            case Some(value) => this.notifyStickerListeners(value)
            case None => ()
        }
        return version
    }

    /**
     * 仅当乐观结果仍是当前版本时回滚。若期间收到 updateStickerSets 或用户又做了
     * 下一次操作，旧 RPC 的失败不能覆盖更新后的快照。
     */
    public func restoreStickerSnapshotIfVersion(
        token: EntityKeyboardAccountToken,
        previous: StickerKeyboardSnapshot,
        expectedVersion: Int64
    ): Bool {
        if (!this.isCurrent(token)) { return false }
        var restored: Option<StickerKeyboardSnapshot> = None
        let didRestore = synchronized(this.monitor) {
            if (this.stickerSnapshot.version != expectedVersion ||
                previous.accountGeneration != token.generation) {
                false
            } else {
                this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
                let value = StickerKeyboardSnapshot(token.generation, this.stickerSnapshotVersion,
                    previous.isLoading, previous.recent, previous.faved, previous.installedPacks,
                    previous.installedDetails, previous.featuredPacks,
                    previous.stickerSearchCategories)
                this.stickerSnapshot = value
                restored = Some(value)
                true
            }
        }
        match (restored) {
            case Some(value) => this.notifyStickerListeners(value)
            case None => ()
        }
        return didRestore
    }

    public func publishFeaturedPacks(
        token: EntityKeyboardAccountToken, packs: Array<StickerPackInfo>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let next = synchronized(this.monitor) {
            let current = this.stickerSnapshot
            this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
            let value = StickerKeyboardSnapshot(token.generation, this.stickerSnapshotVersion,
                current.isLoading, current.recent, current.faved, current.installedPacks,
                current.installedDetails, packs, current.stickerSearchCategories)
            this.stickerSnapshot = value
            value
        }
        this.notifyStickerListeners(next)
    }

    public func publishStickerSearchCategories(
        token: EntityKeyboardAccountToken, groups: Array<EmojiGroupInfo>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let orderedCategories = orderedStickerSearchCategories(groups)
        let next = synchronized(this.monitor) {
            let current = this.stickerSnapshot
            this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
            let value = StickerKeyboardSnapshot(token.generation, this.stickerSnapshotVersion,
                current.isLoading, current.recent, current.faved, current.installedPacks,
                current.installedDetails, current.featuredPacks, orderedCategories)
            this.stickerSnapshot = value
            value
        }
        this.notifyStickerListeners(next)
    }

    public func publishStickerPackDetail(
        token: EntityKeyboardAccountToken, detail: StickerPackDetail
    ): Unit {
        if (!detail.success || detail.stickers.isEmpty()) { return }
        if (!this.isCurrent(token)) { return }
        let next = synchronized(this.monitor) {
            let current = this.stickerSnapshot
            let details = ArrayList<StickerPackDetail>()
            var replaced = false
            for (existing in current.installedDetails) {
                if (existing.info.id == detail.info.id) {
                    details.add(detail)
                    replaced = true
                } else {
                    details.add(existing)
                }
            }
            if (!replaced) { details.add(detail) }
            let packs = ArrayList<StickerPackInfo>()
            for (pack in current.installedPacks) {
                if (pack.id == detail.info.id && !detail.stickers.isEmpty()) {
                    packs.add(copyStickerPackWithCover(pack, detail.stickers[0]))
                } else {
                    packs.add(pack)
                }
            }
            this.stickerSnapshotVersion = this.stickerSnapshotVersion + 1
            let value = StickerKeyboardSnapshot(token.generation, this.stickerSnapshotVersion,
                current.isLoading, current.recent, current.faved, packs.toArray(),
                details.toArray(), current.featuredPacks, current.stickerSearchCategories)
            this.stickerSnapshot = value
            value
        }
        this.notifyStickerListeners(next)
    }

    /**
     * 只允许同一账号 generation 存在一轮 actualize。先发布完整磁盘快照，再并行刷新
     * 四类服务端索引；面板重复打开只订阅同一状态，不会再次制造请求风暴。
     */
    public func actualizeStickerKeyboard(): Unit {
        let token = this.currentToken()
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let shouldStart = synchronized(this.monitor) {
            if (this.stickerActualizingGeneration == token.generation) {
                false
            } else if (this.stickerLastActualizedGeneration == token.generation &&
                nowMs - this.stickerLastActualizedAtMs < 30000) {
                false
            } else {
                this.stickerActualizingGeneration = token.generation
                this.stickerActualizePending = 5
                true
            }
        }
        if (!shouldStart) {
            Hilog.info(0, "CjTelegram",
                "[EntityKeyboardStore] reuse sticker snapshot generation=${token.generation}")
            return
        }
        Hilog.info(0, "CjTelegram",
            "[EntityKeyboardStore] sticker actualize start generation=${token.generation}")
        let current = this.currentStickerSnapshot()
        this.replaceStickerSnapshot(token, true, current.recent, current.faved,
            current.installedPacks, current.installedDetails, current.featuredPacks,
            current.stickerSearchCategories)

        let _ = spawn {
            let service = getStickersService()
            let recentResult = service.getCachedRecentStickers()
            let favedResult = service.getCachedFavedStickers()
            let installedResult = service.getCachedAllStickers()
            let featuredResult = service.getCachedFeaturedStickerPacks()
            let categoryResult = service.getCachedEmojiStickerGroups()
            this.publishStickerIndex(
                token,
                recentResult.stickers.toArray(),
                favedResult.stickers.toArray(),
                installedResult.packs.toArray(),
                featuredResult.packs.toArray(),
                this.currentStickerSnapshot().stickerSearchCategories
            )
            Hilog.info(0, "CjTelegram",
                "[EntityKeyboardStore] sticker disk snapshot recent=${recentResult.stickers.size} faved=${favedResult.stickers.size} packs=${installedResult.packs.size} featured=${featuredResult.packs.size} categories=${categoryResult.groups.size}")
            this.hydrateStickerPackDetails(token, installedResult.packs.toArray())
            if (categoryResult.success && !categoryResult.groups.isEmpty()) {
                let cachedGroups = categoryResult.groups.toArray()
                let _ = spawn {
                    this.prepareAndPublishStickerSearchCategories(token, cachedGroups)
                }
            }
            this.startStickerNetworkActualize(token)
        }
    }

    private func startStickerNetworkActualize(token: EntityKeyboardAccountToken): Unit {
        let _ = spawn {
            let result = getStickersService().getRecentStickers()
            if (result.success) { this.publishRecentStickers(token, result.stickers.toArray()) }
            this.completeStickerActualizePart(token)
        }
        let _ = spawn {
            let result = getStickersService().getFavedStickers()
            if (result.success) { this.publishFavedStickers(token, result.stickers.toArray()) }
            this.completeStickerActualizePart(token)
        }
        let _ = spawn {
            let result = getStickersService().getAllStickers()
            if (result.success) {
                let packs = result.packs.toArray()
                this.publishInstalledPacks(token, packs)
                this.hydrateStickerPackDetails(token, packs)
            }
            this.completeStickerActualizePart(token)
        }
        let _ = spawn {
            let result = getStickersService().getFeaturedStickerPacks()
            if (result.success) { this.publishFeaturedPacks(token, result.packs.toArray()) }
            this.completeStickerActualizePart(token)
        }
        let _ = spawn {
            let result = getStickersService().getEmojiStickerGroups()
            if (result.success) {
                this.prepareAndPublishStickerSearchCategories(token, result.groups.toArray())
            }
            this.completeStickerActualizePart(token)
        }
    }

    /** 先解析分类 icon 文档，再发布可点击分类，避免透明 cell 与逐格 RPC 风暴。 */
    private func prepareAndPublishStickerSearchCategories(
        token: EntityKeyboardAccountToken, groups: Array<EmojiGroupInfo>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let ids = ArrayList<Int64>()
        for (group in groups) {
            if (group.iconEmojiId != 0) { ids.add(group.iconEmojiId) }
        }
        let _ = fetchCustomEmojiDocuments(ids)
        this.publishStickerSearchCategories(token, groups)
    }

    private func hydrateStickerPackDetails(
        token: EntityKeyboardAccountToken,
        packs: Array<StickerPackInfo>
    ): Unit {
        let service = getStickersService()
        var index: Int64 = 0
        while (index < Int64(packs.size)) {
            if (!this.isCurrent(token)) { return }
            let pack = packs[index]
            let cached = service.getCachedStickerSet(pack.id)
            if (cached.success && !cached.stickers.isEmpty()) {
                this.publishStickerPackDetail(token, cached)
            }
            // 网络详情由面板导航/可见包按需触发。索引完整不等于同时请求全部包。
            index = index + 1
        }
    }

    private func completeStickerActualizePart(token: EntityKeyboardAccountToken): Unit {
        if (!this.isCurrent(token)) { return }
        var finished = false
        var restart = false
        synchronized(this.monitor) {
            if (this.stickerActualizingGeneration == token.generation && this.stickerActualizePending > 0) {
                this.stickerActualizePending = this.stickerActualizePending - 1
                if (this.stickerActualizePending == 0) {
                    this.stickerActualizingGeneration = -1
                    this.stickerLastActualizedGeneration = token.generation
                    this.stickerLastActualizedAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                    if (this.stickerRemoteInvalidationPending) {
                        this.stickerRemoteInvalidationPending = false
                        this.stickerLastActualizedGeneration = -1
                        restart = true
                    }
                    finished = true
                }
            }
        }
        if (finished) {
            let current = this.currentStickerSnapshot()
            this.replaceStickerSnapshot(token, false, current.recent, current.faved,
                current.installedPacks, current.installedDetails, current.featuredPacks,
                current.stickerSearchCategories)
            Hilog.info(0, "CjTelegram", "[EntityKeyboardStore] sticker actualize complete generation=${token.generation}")
            if (restart) { this.actualizeStickerKeyboard() }
        }
    }

    /** Push update 到达时绕过 30 秒暖态；若正同步则只合并为一次后续 actualize。 */
    public func invalidateStickerKeyboard(): Unit {
        let shouldStart = synchronized(this.monitor) {
            if (this.stickerActualizingGeneration >= 0) {
                this.stickerRemoteInvalidationPending = true
                false
            } else {
                this.stickerLastActualizedGeneration = -1
                true
            }
        }
        if (shouldStart) { this.actualizeStickerKeyboard() }
    }

    // ==================== Custom Emoji account snapshot ====================

    public func currentEmojiSnapshot(): EmojiKeyboardSnapshot {
        let token = this.currentToken()
        return synchronized(this.monitor) {
            if (this.emojiSnapshot.accountGeneration != token.generation) {
                this.emojiSnapshotVersion = this.emojiSnapshotVersion + 1
                this.emojiSnapshot = emptyEmojiSnapshot(
                    token.generation, this.emojiSnapshotVersion, false)
            }
            this.emojiSnapshot
        }
    }

    public func subscribeEmojiSnapshot(
        listener: (EmojiKeyboardSnapshot) -> Unit
    ): Int64 {
        let snapshot = this.currentEmojiSnapshot()
        let id = synchronized(this.monitor) {
            let next = this.nextEmojiListenerId
            this.nextEmojiListenerId = this.nextEmojiListenerId + 1
            this.emojiListeners[next] = listener
            next
        }
        listener(snapshot)
        return id
    }

    public func unsubscribeEmojiSnapshot(id: Int64): Unit {
        synchronized(this.monitor) { let _ = this.emojiListeners.remove(id) }
    }

    private func notifyEmojiListeners(snapshot: EmojiKeyboardSnapshot): Unit {
        let callbacks = synchronized(this.monitor) {
            let result = ArrayList<(EmojiKeyboardSnapshot) -> Unit>()
            for ((_, callback) in this.emojiListeners) { result.add(callback) }
            result
        }
        for (callback in callbacks) {
            try { callback(snapshot) } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[EntityKeyboardStore] emoji listener failed: ${e}")
            }
        }
    }

    private func replaceEmojiSnapshot(
        token: EntityKeyboardAccountToken,
        isLoading: Bool,
        installedPacks: Array<StickerPackInfo>,
        installedDetails: Array<StickerPackDetail>,
        featuredPacks: Array<StickerPackInfo>,
        searchCategories: Array<EmojiGroupInfo>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let next = synchronized(this.monitor) {
            this.emojiSnapshotVersion = this.emojiSnapshotVersion + 1
            let value = EmojiKeyboardSnapshot(
                token.generation, this.emojiSnapshotVersion, isLoading,
                installedPacks, installedDetails, featuredPacks, searchCategories)
            this.emojiSnapshot = value
            value
        }
        this.notifyEmojiListeners(next)
    }

    public func publishEmojiPackIndex(
        token: EntityKeyboardAccountToken,
        installedPacks: Array<StickerPackInfo>,
        featuredPacks: Array<StickerPackInfo>,
        searchCategories: Array<EmojiGroupInfo>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let next = synchronized(this.monitor) {
            let current = this.emojiSnapshot
            this.emojiSnapshotVersion = this.emojiSnapshotVersion + 1
            let value = EmojiKeyboardSnapshot(
                token.generation, this.emojiSnapshotVersion, current.isLoading,
                installedPacks, current.installedDetails, featuredPacks, searchCategories)
            this.emojiSnapshot = value
            value
        }
        this.notifyEmojiListeners(next)
    }

    public func publishEmojiInstalledPacks(
        token: EntityKeyboardAccountToken, packs: Array<StickerPackInfo>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let current = this.currentEmojiSnapshot()
        this.replaceEmojiSnapshot(token, current.isLoading, packs, current.installedDetails,
            current.featuredPacks, current.searchCategories)
    }

    public func publishFeaturedEmojiPacks(
        token: EntityKeyboardAccountToken, packs: Array<StickerPackInfo>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let current = this.currentEmojiSnapshot()
        this.replaceEmojiSnapshot(token, current.isLoading, current.installedPacks,
            current.installedDetails, packs, current.searchCategories)
    }

    public func publishEmojiSearchCategories(
        token: EntityKeyboardAccountToken, groups: Array<EmojiGroupInfo>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let current = this.currentEmojiSnapshot()
        this.replaceEmojiSnapshot(token, current.isLoading, current.installedPacks,
            current.installedDetails, current.featuredPacks, groups)
    }

    /**
     * 批量发布若干包明细，**只换一次快照、只通知一次**。
     * 预取链一包一发时（~90 包 × 每次都触发订阅方 rebuildRows），面板静止状态
     * 也要吃几分钟的每 1-2 秒重建风暴 —— 静止卡顿的主源，同时把导航条格子
     * 反复拆毁（settle 永远来不及完成），表现为导航整条冻死。
     */
    public func publishEmojiPackDetails(
        token: EntityKeyboardAccountToken, newDetails: ArrayList<StickerPackDetail>
    ): Unit {
        if (newDetails.isEmpty() || !this.isCurrent(token)) { return }
        let next = synchronized(this.monitor) {
            let current = this.emojiSnapshot
            let details = ArrayList<StickerPackDetail>()
            for (existing in current.installedDetails) { details.add(existing) }
            for (detail in newDetails) {
                if (!detail.success || detail.stickers.isEmpty()) { continue }
                var replaced = false
                var i = 0
                while (i < details.size) {
                    if (details[i].info.id == detail.info.id) {
                        details[i] = detail
                        replaced = true
                        break
                    }
                    i = i + 1
                }
                if (!replaced) { details.add(detail) }
            }
            this.emojiSnapshotVersion = this.emojiSnapshotVersion + 1
            let value = EmojiKeyboardSnapshot(
                token.generation, this.emojiSnapshotVersion, current.isLoading,
                current.installedPacks, details.toArray(), current.featuredPacks,
                current.searchCategories)
            this.emojiSnapshot = value
            value
        }
        this.notifyEmojiListeners(next)
    }

    public func publishEmojiPackDetail(
        token: EntityKeyboardAccountToken, detail: StickerPackDetail
    ): Unit {
        if (!detail.success || detail.stickers.isEmpty() || !this.isCurrent(token)) { return }
        let next = synchronized(this.monitor) {
            let current = this.emojiSnapshot
            let details = ArrayList<StickerPackDetail>()
            var replaced = false
            for (existing in current.installedDetails) {
                if (existing.info.id == detail.info.id) {
                    details.add(detail)
                    replaced = true
                } else {
                    details.add(existing)
                }
            }
            if (!replaced) { details.add(detail) }
            let packs = ArrayList<StickerPackInfo>()
            for (pack in current.installedPacks) {
                if (pack.id == detail.info.id) {
                    packs.add(copyStickerPackWithCover(pack, detail.stickers[0]))
                } else {
                    packs.add(pack)
                }
            }
            this.emojiSnapshotVersion = this.emojiSnapshotVersion + 1
            let value = EmojiKeyboardSnapshot(
                token.generation, this.emojiSnapshotVersion, current.isLoading,
                packs.toArray(), details.toArray(), current.featuredPacks,
                current.searchCategories)
            this.emojiSnapshot = value
            value
        }
        this.notifyEmojiListeners(next)
    }

    /**
     * 与 iOS CloudEmojiPacks transaction 一致：用户点击 Add 后先发布本地安装态，
     * RPC 只负责确认。这样包导航和 Add 按钮不会等待一次 getEmojiStickers 往返。
     */
    public func optimisticallyInstallEmojiPack(
        token: EntityKeyboardAccountToken,
        pack: StickerPackInfo,
        items: Array<StickerItem>
    ): Int64 {
        if (pack.id == 0 || !this.isCurrent(token)) { return -1 }
        var published: Option<EmojiKeyboardSnapshot> = None
        let version = synchronized(this.monitor) {
            let current = this.emojiSnapshot
            let installed = copyStickerPackWithInstalledState(pack, true, false)
            if (!items.isEmpty()) { installed.cover = items[0] }

            let packs = ArrayList<StickerPackInfo>()
            packs.add(installed)
            for (existing in current.installedPacks) {
                if (existing.id != installed.id) { packs.add(existing) }
            }

            let details = ArrayList<StickerPackDetail>()
            if (!items.isEmpty()) {
                let detail = StickerPackDetail()
                detail.info = installed
                for (item in items) { detail.stickers.add(item) }
                detail.success = true
                details.add(detail)
            }
            for (existing in current.installedDetails) {
                if (existing.info.id != installed.id) { details.add(existing) }
            }

            this.emojiSnapshotVersion = this.emojiSnapshotVersion + 1
            let value = EmojiKeyboardSnapshot(
                token.generation, this.emojiSnapshotVersion, current.isLoading,
                packs.toArray(), details.toArray(), current.featuredPacks,
                current.searchCategories)
            this.emojiSnapshot = value
            published = Some(value)
            value.version
        }
        match (published) {
            case Some(value) => this.notifyEmojiListeners(value)
            case None => ()
        }
        return version
    }

    /** 仅在没有较新 push/用户操作时回滚失败的 Emoji pack 乐观事务。 */
    public func restoreEmojiSnapshotIfVersion(
        token: EntityKeyboardAccountToken,
        previous: EmojiKeyboardSnapshot,
        expectedVersion: Int64
    ): Bool {
        if (!this.isCurrent(token)) { return false }
        var restored: Option<EmojiKeyboardSnapshot> = None
        let didRestore = synchronized(this.monitor) {
            if (this.emojiSnapshot.version != expectedVersion ||
                previous.accountGeneration != token.generation) {
                false
            } else {
                this.emojiSnapshotVersion = this.emojiSnapshotVersion + 1
                let value = EmojiKeyboardSnapshot(
                    token.generation, this.emojiSnapshotVersion, previous.isLoading,
                    previous.installedPacks, previous.installedDetails,
                    previous.featuredPacks, previous.searchCategories)
                this.emojiSnapshot = value
                restored = Some(value)
                true
            }
        }
        match (restored) {
            case Some(value) => this.notifyEmojiListeners(value)
            case None => ()
        }
        return didRestore
    }

    /** updateStickerSetsOrder(flags.1=emoji) 的本地稳定重排。 */
    public func applyRemoteEmojiPackOrder(order: Array<Int64>): Unit {
        let token = this.currentToken()
        let current = this.currentEmojiSnapshot()
        let packs = ArrayList<StickerPackInfo>()
        let details = ArrayList<StickerPackDetail>()
        for (id in order) {
            for (pack in current.installedPacks) {
                if (pack.id == id) { packs.add(pack) }
            }
            for (detail in current.installedDetails) {
                if (detail.info.id == id) { details.add(detail) }
            }
        }
        for (pack in current.installedPacks) {
            var found = false
            for (id in order) { if (pack.id == id) { found = true } }
            if (!found) { packs.add(pack) }
        }
        for (detail in current.installedDetails) {
            var found = false
            for (id in order) { if (detail.info.id == id) { found = true } }
            if (!found) { details.add(detail) }
        }
        this.replaceEmojiSnapshot(token, current.isLoading, packs.toArray(),
            details.toArray(), current.featuredPacks, current.searchCategories)
    }

    /** updateNewStickerSet carries the complete pack, so publish it immediately. */
    public func applyRemoteNewStickerPack(detail: StickerPackDetail): Unit {
        if (!detail.success || detail.info.id == 0 || detail.stickers.isEmpty()) { return }
        let token = this.currentToken()
        if (detail.info.isEmoji) {
            let current = this.currentEmojiSnapshot()
            let packs = ArrayList<StickerPackInfo>()
            let installed = copyStickerPackWithInstalledState(detail.info, true, false)
            installed.cover = detail.stickers[0]
            packs.add(installed)
            for (pack in current.installedPacks) {
                if (pack.id != installed.id) { packs.add(pack) }
            }
            let details = ArrayList<StickerPackDetail>()
            details.add(detail)
            for (existing in current.installedDetails) {
                if (existing.info.id != installed.id) { details.add(existing) }
            }
            this.replaceEmojiSnapshot(token, current.isLoading, packs.toArray(),
                details.toArray(), current.featuredPacks, current.searchCategories)
        } else {
            let _ = this.optimisticallyInstallStickerPack(
                token, detail.info, detail.stickers.toArray())
            this.publishStickerPackDetail(token, detail)
        }
    }

    /** 本地快照首发、3 路网络 actualize；面板重复开关复用同一账号暖态。 */
    public func actualizeEmojiKeyboard(): Unit {
        let token = this.currentToken()
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let shouldStart = synchronized(this.monitor) {
            if (this.emojiActualizingGeneration == token.generation) {
                false
            } else if (this.emojiLastActualizedGeneration == token.generation &&
                nowMs - this.emojiLastActualizedAtMs < 30000) {
                false
            } else {
                this.emojiActualizingGeneration = token.generation
                this.emojiActualizePending = 3
                true
            }
        }
        if (!shouldStart) {
            Hilog.info(0, "CjTelegram",
                "[EntityKeyboardStore] reuse emoji snapshot generation=${token.generation}")
            return
        }
        let current = this.currentEmojiSnapshot()
        this.replaceEmojiSnapshot(token, true, current.installedPacks,
            current.installedDetails, current.featuredPacks, current.searchCategories)

        let _ = spawn {
            let service = getStickersService()
            let installed = service.getCachedEmojiStickers()
            let featured = service.getCachedFeaturedEmojiPacks()
            let categories = service.getCachedEmojiGroups()
            this.publishEmojiPackIndex(token, installed.packs.toArray(),
                featured.packs.toArray(), categories.groups.toArray())
            this.hydrateEmojiPackDetails(token, installed.packs.toArray())
            if (categories.success) {
                this.prepareAndPublishEmojiCategories(token, categories.groups.toArray())
            }
            this.startEmojiNetworkActualize(token)
        }
    }

    private func startEmojiNetworkActualize(token: EntityKeyboardAccountToken): Unit {
        let _ = spawn {
            let result = getStickersService().getEmojiStickers()
            if (result.success) {
                let packs = result.packs.toArray()
                this.publishEmojiInstalledPacks(token, packs)
                this.hydrateEmojiPackDetails(token, packs)
            }
            this.completeEmojiActualizePart(token)
        }
        let _ = spawn {
            let result = getStickersService().getFeaturedEmojiPacks()
            if (result.success) {
                this.publishFeaturedEmojiPacks(token, result.packs.toArray())
            }
            this.completeEmojiActualizePart(token)
        }
        let _ = spawn {
            let result = getStickersService().getEmojiGroups()
            if (result.success) {
                this.prepareAndPublishEmojiCategories(token, result.groups.toArray())
            }
            this.completeEmojiActualizePart(token)
        }
    }

    private func prepareAndPublishEmojiCategories(
        token: EntityKeyboardAccountToken, groups: Array<EmojiGroupInfo>
    ): Unit {
        if (!this.isCurrent(token)) { return }
        let ids = ArrayList<Int64>()
        for (group in groups) {
            if (group.iconEmojiId != 0) { ids.add(group.iconEmojiId) }
        }
        let _ = fetchCustomEmojiDocuments(ids)
        this.publishEmojiSearchCategories(token, groups)
    }

    private func hydrateEmojiPackDetails(
        token: EntityKeyboardAccountToken, packs: Array<StickerPackInfo>
    ): Unit {
        let service = getStickersService()
        for (pack in packs) {
            if (!this.isCurrent(token)) { return }
            let cached = service.getCachedStickerSet(pack.id)
            if (cached.success && !cached.stickers.isEmpty()) {
                this.publishEmojiPackDetail(token, cached)
            }
        }
    }

    private func completeEmojiActualizePart(token: EntityKeyboardAccountToken): Unit {
        if (!this.isCurrent(token)) { return }
        var finished = false
        var restart = false
        synchronized(this.monitor) {
            if (this.emojiActualizingGeneration == token.generation &&
                this.emojiActualizePending > 0) {
                this.emojiActualizePending = this.emojiActualizePending - 1
                if (this.emojiActualizePending == 0) {
                    this.emojiActualizingGeneration = -1
                    this.emojiLastActualizedGeneration = token.generation
                    this.emojiLastActualizedAtMs =
                        DateTime.now().toUnixTimeStamp().toMilliseconds()
                    if (this.emojiRemoteInvalidationPending) {
                        this.emojiRemoteInvalidationPending = false
                        this.emojiLastActualizedGeneration = -1
                        restart = true
                    }
                    finished = true
                }
            }
        }
        if (finished) {
            let current = this.currentEmojiSnapshot()
            this.replaceEmojiSnapshot(token, false, current.installedPacks,
                current.installedDetails, current.featuredPacks, current.searchCategories)
            Hilog.info(0, "CjTelegram",
                "[EntityKeyboardStore] emoji actualize complete generation=${token.generation}")
            if (restart) { this.actualizeEmojiKeyboard() }
        }
    }

    public func invalidateEmojiKeyboard(): Unit {
        let shouldStart = synchronized(this.monitor) {
            if (this.emojiActualizingGeneration >= 0) {
                this.emojiRemoteInvalidationPending = true
                false
            } else {
                this.emojiLastActualizedGeneration = -1
                true
            }
        }
        if (shouldStart) { this.actualizeEmojiKeyboard() }
    }
}
