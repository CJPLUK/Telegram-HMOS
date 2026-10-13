package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.{
    getStickersService, getEntityKeyboardStore, StickerKeyboardSnapshot,
    StickerItem, StickerPackInfo, StickerPackDetail, EmojiGroupInfo
,
    setKeyboardGridScrolling, isKeyboardGridScrolling,
    requestAnimationCacheBuild, CHAIN_TRACE_LOGS,
    getAppFilesDir, ensureStickerLocalFile, loadStickerStaticFrame,
    maintainStickerAnimCacheBudget, maintainEmojiAnimCacheBudget, firstRuneString,
    getFileDownloadService, showToast, getCurrentUserId, triggerHaptic}
import std.collection.{ArrayList, HashMap, HashSet}
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.bindings.setStickerGridProviders
import ohos_app_cangjie_entry.interop.callArk
import ohos_app_cangjie_entry.router.routerPush
import std.time.*
import std.convert.*

import kit.PerformanceAnalysisKit.Hilog
/** ArkTS 贴纸网格占位块 id（OverlayGeometry 主动重量用） */
let STICKER_GRID_SLOT_ID = "cj_sticker_grid_slot"

/** 贴纸 Phase1 总开关：网格交给 ArkTS ImageAnimator 覆盖层渲染；
 *  false = 回退仓颉逐格播放池管线。 */
let USE_ARKTS_STICKER_GRID: Bool = true

/** Longest a snapshot-driven row rebuild may be deferred by the debounce. */
private let STICKER_ROWS_REBUILD_MAX_WAIT_MS: Int64 = 1200

/**
 * iOS EntityKeyboard 的贴纸页。
 *
 * 可观察结构与 EmojiPagerContentComponent.stickerInputData 一致：顶部是一条包导航，
 * 下方内容按“精选 → 收藏 → 最近 → 已安装包”连续排列。点击导航只滚动内容，不会
 * 换掉整张页面；数据先发布本地快照，再由网络 actualize。
 */
@Component
public class StickerKeyboardPanel {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    /** 内容区高度（vp）：由宿主按真实 IME 高度注入（总高 - 页签行 - 手势带）。 */
    var contentHeightVp: Float64 = 287.0
    public var peerType: String = ""
    public var peerId: Int64 = 0
    public var initialContentOffset: Float64 = 0.0
    public var onContentOffsetChanged: (Float64) -> Unit = { _value: Float64 => }
    public var onSelectSticker: (StickerItem) -> Unit = { _item: StickerItem => }
    /** iOS peek 菜单的「不响铃发送」。 */
    public var onSendStickerSilently: (StickerItem) -> Unit = { _item: StickerItem => }
    /** iOS peek 菜单的「定时发送」——由页面弹出时间选择器。 */
    public var onScheduleSticker: (StickerItem) -> Unit = { _item: StickerItem => }
    public var onCreateSticker: () -> Unit = { => }
    public var onOpenSettings: () -> Unit = { => }
    public var onClose: () -> Unit = { => }
    /**
     * S2-37：长按预览由宿主页面在根叠加层呈现（iOS PeekController 由 ChatController
     * 全屏 present，盖住键盘页签条与输入栏，菜单完整落在安全区内）。面板自己的 Stack 只有
     * 内容区那么高，预览画在里面会被页签条/屏底压掉下半截菜单（R7V 实锤：Add to
     * Favorites 中心 y≈2301/2406px，点下去落到屏底）。hostsStickerPreview=false 的宿主
     *（DrawingScreen 贴纸选择器）仍在面板内渲染。
     */
    public var hostsStickerPreview: Bool = false
    public var onPresentStickerPreview: (StickerPreviewRequest) -> Unit = { _req: StickerPreviewRequest => }
    public var onDismissStickerPreview: () -> Unit = { => }

    @State var isLoading: Bool = false
    @State var isSearching: Bool = false
    /** 搜索图标的「返回箭头」态，裸 @State（同 EmojiPicker.searchShowsBack）。 */
    @State var searchShowsBack: Bool = false
    @State var searchText: String = ""
    @State var recentStickers: Array<StickerItem> = Array<StickerItem>(0, repeat: StickerItem())
    @State var favedStickers: Array<StickerItem> = Array<StickerItem>(0, repeat: StickerItem())
    @State var installedPacks: Array<StickerPackInfo> = Array<StickerPackInfo>(0, repeat: StickerPackInfo())
    @State var installedDetails: Array<StickerPackDetail> = Array<StickerPackDetail>(0, repeat: StickerPackDetail())
    @State var featuredPacks: Array<StickerPackInfo> = Array<StickerPackInfo>(0, repeat: StickerPackInfo())
    @State var stickerSearchCategories: Array<EmojiGroupInfo> =
        Array<EmojiGroupInfo>(0, repeat: EmojiGroupInfo())
    @State var selectedSearchCategoryId: Int64 = 0
    @State var searchStickers: Array<StickerItem> = Array<StickerItem>(0, repeat: StickerItem())
    @State var searchPacks: Array<StickerPackInfo> = Array<StickerPackInfo>(0, repeat: StickerPackInfo())
    @State var searchPackTitle: String = ""
    @State var searchPackStickers: Array<StickerItem> = Array<StickerItem>(0, repeat: StickerItem())
    @State var browsingPack: Bool = false
    @State var browsingPackInfo: StickerPackInfo = StickerPackInfo()
    @State var isPackLoading: Bool = false
    @State var packInstallBusy: Bool = false
    @State var selectedNavigationId: Int64 = -2
    /**
     * iOS EntityKeyboardTopPanelComponent 的 isExpanded：**横向拖动导航条时整条展开**
     * ——封面放大（ItemLayout: 26 → 42）并在下方显示包名，停手 0.8s 后收回
     *（updateIsDraggingOrReordering + draggingStoppedTimer，同文件 1750 行起）。
     *
     * 实测 iOS：拖一下导航条，图标变大且每个下面出现 "Chilled Cat" / "Cubigator"
     * 这样的包名——这才让这条导航真正可用于找特定的包，而不只是一排认不出的图标。
     * 我们此前是固定 36vp、永不展开。
     */
    @State var navExpanded: Bool = false
    private var navCollapseGeneration: Int64 = 0
    @State var showTrending: Bool = true
    @State var installingPackId: Int64 = 0
    @State var showStickerPreview: Bool = false
    @State var previewSticker: StickerItem = StickerItem()
    @State var previewIsRecent: Bool = false
    @State var previewIsFavorite: Bool = false
    @State var hasPeerSpecificPack: Bool = false
    @State var peerSpecificPack: StickerPackDetail = StickerPackDetail()

    private let contentScroller: Scroller = Scroller()
    /**
     * 包导航自己的 Scroller。iOS 在 activeContentItemId 变化时把高亮项滚进可视区
     * （EntityKeyboardTopPanelComponent.swift:2156）。缺了它，内容滚到远处的包，
     * 导航高亮就停在屏幕外。
     */
    private let navScroller: Scroller = Scroller()
    /**
     * 程序化滚动导航条时置位。导航条的 onDidScroll 挂着 expandNavigation()，
     * 那是给「用户拖动导航条」用的；不隔离的话每次滚内容都会把导航条撑开一次。
     */
    private var navScrollProgrammatic: Bool = false
    // 唯一布局真相：分组按 metrics 摊平成行表，绘制与 scrollToIndex 都只认它。
    // 见 EntityKeyboardLayout.cj（iOS EmojiPagerContentComponent.ItemLayout 移植）。
    private let rowSource: KeyboardRowSource = KeyboardRowSource()
    // isEmbedded 行（trending）的独立数据源——那一行必须虚拟化，见 KeyboardCellSource。
    private let embeddedSource: KeyboardCellSource = KeyboardCellSource()
    // 首帧布局尚未发生时先用常见机型宽度建表，onAreaChange 再按真实宽度重建。
    private var contentWidth: Float64 = 360.0
    private var searchGeneration: Int64 = 0
    private var packRequestGeneration: Int64 = 0
    /** 本面板实例的键盘流代际（挂载时领取）。 */
    private var panelStreamEpoch: Int64 = 0
    /** 已发起过明细请求的已装包，防止 snapshot 回流时重复拉取。 */
    private let requestedInstalledDetails: HashSet<Int64> = HashSet<Int64>()
    private var snapshotLifecycleGeneration: Int64 = 0
    private var stickerSnapshotListenerId: Int64 = -1
    // ---- doc 池拉驱动（与 EmojiPicker 同型：事件加速，心跳兜底）----
    private var visibleFirstRow: Int64 = 0
    private var visibleLastRow: Int64 = 6
    private var cellDriveGeneration: Int64 = 0

    protected override func aboutToAppear(): Unit {
        this.panelAlive = true
        if (USE_ARKTS_STICKER_GRID) {
            registerOverlayRemeasure("stickerGrid", { => this.remeasureGridSlot() })
        }
        this.panelStreamEpoch = getKeyboardFrameClock().bumpKeyboardEpoch()
        this.snapshotLifecycleGeneration = this.snapshotLifecycleGeneration + 1
        let lifecycle = this.snapshotLifecycleGeneration
        this.startCellDriveHeartbeat(lifecycle)
        if (USE_ARKTS_STICKER_GRID) {
            setStickerGridProviders(
                Some({ => this.cachedStickerRowsJson }),
                Some({ payload: String =>
                    launch {
                        if (this.snapshotLifecycleGeneration == lifecycle) {
                            this.handleStkGridEvent(payload)
                        }
                    }
                }))
        }
        let store = getEntityKeyboardStore()
        if (this.stickerSnapshotListenerId >= 0) {
            store.unsubscribeStickerSnapshot(this.stickerSnapshotListenerId)
            this.stickerSnapshotListenerId = -1
        }
        // 先把 Store 切到 loading/缓存恢复态，再订阅首个快照，避免首次构建短暂收到
        // “非 loading 的空数组”而闪出一帧空面板。
        store.actualizeStickerKeyboard()
        // 条件渲染第二次创建面板时，subscribe 的即时回放闭包会被 ArkUI 延后到
        // 下一帧；同一帧的旧节点 disappear 又会推进 lifecycle，导致该回放被拒绝。
        // iOS 的 Postbox Signal 会同步交付当前值，因此这里先在 UI 线程同步恢复
        // Store 快照，再让订阅只负责后续网络更新。
        this.applyStickerSnapshot(store.currentStickerSnapshot())
        this.stickerSnapshotListenerId = store.subscribeStickerSnapshot({ snapshot: StickerKeyboardSnapshot =>
            launch {
                if (this.snapshotLifecycleGeneration == lifecycle) {
                    this.applyStickerSnapshot(snapshot)
                }
            }
        })
        let restoreOffset = this.initialContentOffset
        if (restoreOffset > 0.0) {
            let _ = spawn {
                sleep(Duration.millisecond * 16)
                launch {
                    this.contentScroller.scrollTo(
                        xOffset: 0.0, yOffset: restoreOffset, animation: false)
                }
            }
        }
    }

    protected override func aboutToDisappear(): Unit {
        this.panelAlive = false
        if (USE_ARKTS_STICKER_GRID) {
            unregisterOverlayRemeasure("stickerGrid")
            this.pushStkGridUpdate(false)
            setStickerGridProviders(None, None)
        }
        getKeyboardFrameClock().stopKeyboardStreams(this.panelStreamEpoch)
        // 面板关闭后，它排下的贴纸文件 / 动画文档预取（ensureStickerLocalFile 60、
        // 动画文档 40/45）降到聊天历史后台预取之下：iOS 节点离屏即释放 FetchManager
        // 引用，这些条目不会再挡在随后上屏的聊天媒体前面（R3 D9）。已在跑的不打断。
        let _ = getFileDownloadService().demoteQueuedPrefetch(40, 60, 5)
        this.searchGeneration = this.searchGeneration + 1
        this.packRequestGeneration = this.packRequestGeneration + 1
        this.snapshotLifecycleGeneration = this.snapshotLifecycleGeneration + 1
        if (this.stickerSnapshotListenerId >= 0) {
            getEntityKeyboardStore().unsubscribeStickerSnapshot(this.stickerSnapshotListenerId)
            this.stickerSnapshotListenerId = -1
        }
    }

    /** 给缺明细的已装包后台补全量（iOS 由 Postbox 直接给全，无此阶段）。 */
    private func ensureInstalledDetails(): Unit {
        let missingPacks = ArrayList<StickerPackInfo>()
        for (pack in this.installedPacks) {
            if (this.detailStickersFor(pack.id).size > 0) { continue }
            if (this.requestedInstalledDetails.contains(pack.id)) { continue }
            let _ = this.requestedInstalledDetails.add(pack.id)
            missingPacks.add(pack)
        }
        if (missingPacks.size == 0) { return }
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let _ = spawn {
            for (pack in missingPacks) {
                let detail = getStickersService().getStickerSet(pack.id, pack.accessHash)
                // publish 会触发快照订阅 → applyStickerSnapshot → 行表重建，
                // topItems 垫的组被全量内容替换。
                if (detail.success) { store.publishStickerPackDetail(accountToken, detail) }
            }
        }
    }

    private func applyStickerSnapshot(snapshot: StickerKeyboardSnapshot): Unit {
        this.isLoading = snapshot.isLoading
        this.recentStickers = snapshot.recent
        this.favedStickers = snapshot.faved
        this.installedPacks = snapshot.installedPacks
        this.installedDetails = snapshot.installedDetails
        this.featuredPacks = snapshot.featuredPacks
        this.stickerSearchCategories = snapshot.stickerSearchCategories
        match (getEntityKeyboardStore().currentPeerStickerPack(this.peerType, this.peerId)) {
            case Some(detail) =>
                this.peerSpecificPack = detail
                this.hasPeerSpecificPack = true
            case None =>
                this.hasPeerSpecificPack = false
        }
        // 快照到达走去抖聚合（明细串行到达曾造成每 1-2s 一次全量重建的
        // 风暴，真机 trace: 主线程 90ms 任务 ×11 + GC 3.7s/20s）；
        // 首次（行表还空）立即建，避免面板空窗。
        if (this.rowSource.currentRows().isEmpty()) {
            this.rebuildRows()
        } else {
            this.scheduleRowsRebuild()
        }
        this.refreshNavSource()
        this.ensureInstalledDetails()
        this.ensureFeaturedPreviewDetails()
        this.maintainAnimCacheDiskOnce()
    }

    /** 导航条虚拟化数据源：已装包在前、精选包在后（与 navigationPackIds 同序）。 */
    private let navPackSource: StickerPackNavSource = StickerPackNavSource()
    /** 上次喂给导航源的 id 序列指纹：不变不 reload（快照风暴期免 churn）。 */
    private var navSourceFingerprint: String = ""

    private func refreshNavSource(): Unit {
        let combined = ArrayList<StickerPackInfo>()
        for (pack in this.installedPacks) { combined.add(pack) }
        for (pack in this.featuredNavigationPacks()) { combined.add(pack) }
        let fp = StringBuilder()
        // The cover is part of the identity: installed packs arrive cover-less from
        // messages.getAllStickers and only gain a cover once their detail is known.
        // Without it the LazyForEach kept the cover-less objects and the nav bar
        // showed loading spinners forever.
        for (pack in combined) { fp.append("${pack.id}#${pack.isUnread}#${pack.cover.documentId}|") }
        let fingerprint = fp.toString()
        if (fingerprint == this.navSourceFingerprint) { return }
        this.navSourceFingerprint = fingerprint
        this.navPackSource.setItems(combined.toArray())
    }

    /**
     * 动画缓存磁盘治理（每会话一次，后台线程；见 AnimatedEmojiService 内的
     * 预算/去重实现）。保留集 = 当前行表全部 doc（已装/精选/最近），
     * 预算超限时优先淘汰保留集之外的文件。
     *
     * 历史：本函数曾同时为离屏格子非紧急排队全量构建（iOS AnimationCache
     * 预取的对位）。快照风暴期它被反复调用，冷队列堆到 437 深/等待 208s、
     * 2 个冷 worker 持续烧核，把可见格子的快段拖到 3s+（真机 ChainTrace
     * 实锤）——动画构建现在一律由可见格子的 need| 事件驱动（iOS
     * AnimationCache 只为上屏 item 构建，同语义），预取排队已整体移除。
     */
    private func maintainAnimCacheDiskOnce(): Unit {
        let keepDocs = HashSet<Int64>()
        for (row in this.rowSource.currentRows()) {
            for (cell in row.cells) {
                if (cell.item.documentId != 0) { let _ = keepDocs.add(cell.item.documentId) }
            }
        }
        let _ = spawn {
            maintainStickerAnimCacheBudget(keepDocs)
            maintainEmojiAnimCacheBudget()
        }
    }


    /**
     * cover-only 的精选包（stickerSetNoCovered：featured 响应里没有 topItems）
     * 后台串行补明细，让键盘里的精选组从「只有 1 个封面」升到 iOS 同款的
     * 前 5 个预览。每会话每包只请求一次。
     */
    private func ensureFeaturedPreviewDetails(): Unit {
        let missing = ArrayList<StickerPackInfo>()
        for (pack in this.featuredPacks) {
            if (this.isInstalledFeaturedPack(pack)) { continue }
            if (pack.topItems.size >= 5) { continue }
            if (this.detailStickersFor(pack.id).size > 0) { continue }
            if (this.requestedInstalledDetails.contains(pack.id)) { continue }
            let _ = this.requestedInstalledDetails.add(pack.id)
            missing.add(pack)
        }
        if (missing.size == 0) { return }
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let _ = spawn {
            for (pack in missing) {
                let detail = getStickersService().getStickerSet(pack.id, pack.accessHash)
                if (detail.success) { store.publishStickerPackDetail(accountToken, detail) }
            }
        }
    }

    private func isInstalledFeaturedPack(pack: StickerPackInfo): Bool {
        if (pack.isInstalled) { return true }
        for (installed in this.installedPacks) {
            if (installed.id == pack.id) { return true }
        }
        return false
    }

    private func featuredNavigationPacks(): Array<StickerPackInfo> {
        let result = ArrayList<StickerPackInfo>()
        var i: Int64 = 0
        // 不截断：iOS 导航条走横滚看完全部（此前只放 8 个 —— 「导航栏
        // 显示不全」的用户实锤）。驱动侧仍有 12 个动画封面的配额上限。
        while (i < Int64(this.featuredPacks.size)) {
            let pack = this.featuredPacks[i]
            if (!this.isInstalledFeaturedPack(pack) && pack.cover.documentId != 0) { result.add(pack) }
            i = i + 1
        }
        return result.toArray()
    }

    private func featuredCoverStickers(): Array<StickerItem> {
        let result = ArrayList<StickerItem>()
        var i: Int64 = 0
        // 不截断：iOS 遍历全部 featuredPacks，靠 isEmbedded 的横滚看完
        //（此前这里写「最多 8 个」，是对 iOS 的误读）。
        while (i < Int64(this.featuredPacks.size)) {
            let pack = this.featuredPacks[i]
            if (!this.isInstalledFeaturedPack(pack) && pack.cover.documentId != 0) { result.add(pack.cover) }
            i = i + 1
        }
        return result.toArray()
    }

    private func makeGroup(
        key: Int64,
        title: String,
        items: Array<StickerItem>,
        clearAction: String,
        includesCreate: Bool,
        compact: Bool
    ): KeyboardGroup {
        let group = KeyboardGroup()
        group.key = key
        group.title = title
        group.clearAction = clearAction
        group.compact = compact
        let cells = ArrayList<KeyboardCell>()
        // iOS 把「新建贴纸」作为 .icon(.add) 插到 recent 组 items[0]。
        if (includesCreate) {
            cells.add(createActionCell())
        }
        for (item in items) {
            cells.add(documentCell(item))
        }
        group.cells = cells.toArray()
        return group
    }

    /** iOS：featuredStickersConfiguration.isPremium 决定写 Trending Premium 还是 Featured。 */
    private func trendingTitle(): String {
        for (pack in this.featuredPacks) {
            if (pack.featuredIsPremium) { return "TRENDING PREMIUM STICKERS" }
        }
        return "FEATURED STICKERS"
    }

    private func isStickerPackInstalled(packId: Int64): Bool {
        for (pack in this.installedPacks) {
            if (pack.id == packId) { return true }
        }
        return false
    }

    /** 已落库的包明细（含尚未安装的精选包 —— publishStickerPackDetail 会一并存入）。 */
    private func detailStickersFor(packId: Int64): Array<StickerItem> {
        for (detail in this.installedDetails) {
            if (detail.info.id == packId) { return detail.stickers.toArray() }
        }
        return Array<StickerItem>(0, repeat: StickerItem())
    }

    /**
     * iOS 把精选包作为**内容流里的完整分组**排在最后，分组头是 60pt 的高版式，
     * 带副标题 "N stickers" 与右侧 Add 按钮。此前本仓是点一下换成一整页详情，
     * 交互模型完全不同。
     */
    private func featuredGroups(): ArrayList<KeyboardGroup> {
        let groups = ArrayList<KeyboardGroup>()
        for (pack in this.featuredPacks) {
            if (this.isInstalledFeaturedPack(pack)) { continue }
            let cells = ArrayList<KeyboardCell>()
            // iOS 键盘里的精选组是「一行 5 个预览 + Add」（StickerPaneSearch-
            // GlobalItem 同款），不是全量网格 —— 明细/ topItems 都截前 5。
            let known = this.detailStickersFor(pack.id)
            if (known.size > 0) {
                for (item in known) {
                    if (cells.size >= 5) { break }
                    cells.add(documentCell(item))
                }
            } else if (!pack.topItems.isEmpty()) {
                for (item in pack.topItems) {
                    if (cells.size >= 5) { break }
                    cells.add(documentCell(item))
                }
            } else if (pack.cover.documentId != 0) {
                cells.add(documentCell(pack.cover))
            }
            if (cells.isEmpty()) { continue }
            let group = KeyboardGroup()
            group.key = pack.id
            group.title = pack.title
            group.subtitle = "${pack.count} stickers"
            group.actionTitle = "Add"
            group.isFeatured = true
            group.cells = cells.toArray()
            groups.add(group)
        }
        return groups
    }

    /** 与 iOS stickerInputData 的分组顺序一致：featuredTop → saved → recent → peerSpecific → 已装包 → 精选包。 */
    private func currentGroups(): ArrayList<KeyboardGroup> {
        let groups = ArrayList<KeyboardGroup>()
        if (this.showTrending && !this.featuredCoverStickers().isEmpty()) {
            let trending = this.makeGroup(-2, this.trendingTitle(),
                this.featuredCoverStickers(), "trending", false, true)
            // iOS EmojiPagerContentSignals.swift:2139 —— 贴纸面板的 featuredTop
            // 同样是 isEmbedded，一条横滚行装下全部封面。
            trending.isEmbedded = true
            groups.add(trending)
        }
        if (!this.favedStickers.isEmpty()) {
            groups.add(this.makeGroup(0, "FAVORITES", this.favedStickers, "", false, false))
        }
        groups.add(this.makeGroup(-1, "RECENTLY USED", this.recentStickers, "recent", true, false))
        if (this.peerSpecificPackVisible()) {
            groups.add(this.makeGroup(-3, this.peerSpecificPack.info.title,
                this.peerSpecificPack.stickers.toArray(), "", false, false))
        }
        // 按 installedPacks（服务端顺序）遍历，而不是按 installedDetails：
        // detail 是懒拉的，此前没拉过明细的已装包**整组不渲染** —— 「贴纸没有
        // 像 iOS 一样全部显示」的根源。iOS 的 ItemCollectionsView 从 Postbox
        // 一次性给出全部已装包的全部内容。这里 detail 未到先用 featured 响应
        // 同款的 topItems 垫着，ensureInstalledDetails 在后台补全量。
        for (pack in this.installedPacks) {
            let known = this.detailStickersFor(pack.id)
            if (known.size > 0) {
                groups.add(this.makeGroup(pack.id, pack.title, known, "", false, false))
            } else if (!pack.topItems.isEmpty()) {
                groups.add(this.makeGroup(pack.id, pack.title,
                    pack.topItems.toArray(), "", false, false))
            } else if (pack.cover.documentId != 0) {
                let coverOnly = ArrayList<StickerItem>()
                coverOnly.add(pack.cover)
                groups.add(this.makeGroup(pack.id, pack.title,
                    coverOnly.toArray(), "", false, false))
            }
        }
        for (group in this.featuredGroups()) { groups.add(group) }
        return groups
    }

    /** 滚动/重建后 600ms 稳定期集中驱动一次（新事件重置计时）。 */
    private func scheduleCellDrive(): Unit {
        this.cellDriveGeneration = this.cellDriveGeneration + 1
        let token = this.cellDriveGeneration
        let _ = spawn {
            sleep(Duration.millisecond * 300)
            launch {
                if (this.cellDriveGeneration == token) { this.driveVisibleCells() }
            }
        }
    }

    /** 驱动心跳：事件回调（onScrollIndex 等）在本版本 ArkUI 不可靠，心跳才是
     *  正确性来源（EmojiPicker 真机实锤二遍滚动 onScrollIndex 全程静默）。 */
    private func startCellDriveHeartbeat(lifecycle: Int64): Unit {
        let _ = spawn {
            while (true) {
                sleep(Duration.millisecond * 1200)
                launch {
                    if (this.snapshotLifecycleGeneration == lifecycle) {
                        this.driveVisibleCells()
                    }
                }
                if (this.snapshotLifecycleGeneration != lifecycle) { break }
            }
        }
    }

    /** 光栅与 StickerGridCell.rasterSize 同式，保证池写的代表帧与格子读的键一致。 */
    private func cellRaster(size: Float64): Int32 {
        // 2× 而非 3×：204px 缓存单 doc 7.9MB/280帧、构建 ~20s（真机 13:40 实测），
        // 队列 346 深要数小时才暖完 —— 68vp 格子用 136px 纹理在观感上无感，
        // 构建/文件/播放解码全部便宜 2.25×。Telegram Android 网格同样 2×。
        var px = size * 2.0
        if (px < 64.0) { px = 64.0 }
        if (px > 272.0) { px = 272.0 }
        return Int32(px)
    }

    private func isAnimatedItem(item: StickerItem): Bool {
        return item.mimeType.contains("tgs") || item.mimeType.contains("lottie") ||
            item.mimeType.contains("webm")
    }

    /**
     * 由 Scroller 实测偏移反算首个可见行 —— onScrollIndex 在本版本 ArkUI
     * 不可靠（真机实锤有整段滚动全程静默），事件值只当缓存，驱动时以
     * currentOffset 为准重算。行表自带每行高度，前缀和即得。
     */
    private func firstRowAtOffset(rows: Array<KeyboardRow>): Int64 {
        let current = this.contentScroller.currentOffset()
        if (current.isNone()) { return this.visibleFirstRow }
        let target = current.getOrThrow().yOffset
        if (target <= 0.0) { return 0 }
        var acc = 0.0
        var index: Int64 = 0
        while (index < Int64(rows.size)) {
            acc = acc + rows[index].height
            if (acc > target) { return index }
            index = index + 1
        }
        return Int64(rows.size) - 1
    }

    /** 收集可见行 + trending 内嵌行 + 导航封面，交给 doc 池对账。 */
    private func driveVisibleCells(): Unit {
        // 滚动闸（缘由见 EmojiPicker.driveVisibleCells）。
        if (isKeyboardGridScrolling()) { return }
        let visible = ArrayList<(StickerItem, Int32)>()
        let rows = this.rowSource.currentRows()
        // 事件窗与偏移窗各驱各的（缘由见 EmojiPicker.driveVisibleCells）。
        // 只用偏移窗（缘由见 EmojiPicker.driveVisibleCells）。
        let offsetRow = this.firstRowAtOffset(rows)
        let starts = ArrayList<Int64>()
        starts.add(offsetRow)
        // 取证：窗口内被跳过的非动画格与空 doc 格（「duck 不动」排查）。
        var scanned: Int64 = 0
        var skippedStatic: Int64 = 0
        var skippedEmpty: Int64 = 0
        var skippedMimeSample = ""
        // ArkTS 网格接管后帧动画归 ImageAnimator，仓颉播放池只供导航条封面
        //（emoji Phase1 同款：双管线齐跑就是「非常卡」）。
        if (!USE_ARKTS_STICKER_GRID) {
        for (startRow in starts) {
            var index = startRow
            var lastRow = startRow + 5
            if (lastRow >= Int64(rows.size)) { lastRow = Int64(rows.size) - 1 }
            while (index <= lastRow && index >= 0) {
                // embedded（trending）行的 row.cells 仍持整组几百项，绘制侧走
                // embeddedSource 虚拟化 —— 收集侧只认 embeddedSource 前 10
                //（见下），这里必须跳过，否则一次驱动 245 项打爆全部播放配额。
                if (!rows[index].embedded) {
                    let raster = this.cellRaster(rows[index].itemSize)
                    for (cell in rows[index].cells) {
                        scanned = scanned + 1
                        if (cell.item.documentId == 0) {
                            skippedEmpty = skippedEmpty + 1
                        } else if (!this.isAnimatedItem(cell.item)) {
                            skippedStatic = skippedStatic + 1
                            if (skippedMimeSample.isEmpty()) {
                                skippedMimeSample = "${cell.item.documentId}:${cell.item.mimeType}"
                            }
                        } else {
                            visible.add((cell.item, raster))
                        }
                    }
                }
                index = index + 1
            }
        }
        // trending 内嵌行独立数据源，不在 row.cells 里；顶部可见时带上前 10 个。
        if (offsetRow <= 2 || this.visibleFirstRow <= 2) {
            var ei: Int64 = 0
            let cap = if (this.embeddedSource.totalCount() < 10) { this.embeddedSource.totalCount() } else { 10 }
            while (ei < cap) {
                let cell = this.embeddedSource.getData(ei)
                if (cell.item.documentId != 0 && this.isAnimatedItem(cell.item)) {
                    // 204 是 legacy 光栅（磁盘 GC 无条件清除）—— 写死它等于永远
                    // cache-miss 落 live 解码 + 重建又被删的死循环。探测已有文件，
                    // 全 miss 回落 136 与网格共用一份缓存。
                    visible.add((cell.item,
                        StickerKeyboardPanel.probeAnimRasterFor(
                            getAppFilesDir(), cell.item.documentId, 136)))
                }
                ei = ei + 1
            }
        }
        }
        let gridCount = visible.size
        // 导航条封面：横向条一屏 ~8 个，封顶 12 —— 全量收会把上百个精选包
        // cover 全部起流（首版实测 232 项直接打爆播放槽）。
        // 封面光栅探测：@126 文件几乎不存在（实测 2 个），写死 126 = 12 个
        // 封面全部 cache-miss 落 live 解码 —— 面板驻留 ~3 核的直接来源
        //（真机归因：面板关 4%、emoji 页 65%、贴纸页 313%）。探测命中已有
        // .acv3（网格早建过 @136）走缓存回放，每帧 delta 应用 ~0.2ms。
        let navFilesDir = getAppFilesDir()
        var navCount: Int64 = 0
        for (pack in this.installedPacks) {
            if (navCount >= 12) { break }
            if (pack.cover.documentId != 0 && this.isAnimatedItem(pack.cover)) {
                visible.add((pack.cover, StickerKeyboardPanel.probeAnimRasterFor(
                    navFilesDir, pack.cover.documentId, 136)))
                navCount = navCount + 1
            }
        }
        for (pack in this.featuredNavigationPacks()) {
            if (navCount >= 12) { break }
            if (pack.cover.documentId != 0 && this.isAnimatedItem(pack.cover)) {
                visible.add((pack.cover, StickerKeyboardPanel.probeAnimRasterFor(
                    navFilesDir, pack.cover.documentId, 136)))
                navCount = navCount + 1
            }
        }
        Hilog.info(0, "CjTelegram",
            "[StickerDrive] off=${offsetRow} ev=${this.visibleFirstRow} rows=${rows.size} grid=${gridCount} nav=${navCount}" +
            " scan=${scanned} skipStatic=${skippedStatic} skipEmpty=${skippedEmpty} mime=${skippedMimeSample}")
        getKeyboardDocPlayback().driveVisibleItems(visible)
    }

    // ==================== ArkTS 贴纸网格桥（贴纸 Phase1） ====================
    // 结构与 EmojiPicker 的 emoji Phase1 完全同构：占位符供几何、行表 JSON
    // 后台构建、事件管道回传、跳转 sr/ss 捎带。帧动画走 ImageAnimator
    //（系统驱动、GPU 合成），替代仓颉帧钟每秒上千次 @State 写。

    /** JS 线程 provider 只读这份不可变快照（S-001）。 */
    private var cachedStickerRowsJson: String = ""
    private var arkStkGeneration: Int64 = 0
    private var arkStkScrollRow: Int64 = -1
    private var arkStkScrollSeq: Int64 = 0
    private var arkStkPushInFlight: Bool = false
    /** need 补建限频（doc → 上次受理 ms）：永久去重会让首次构建失败
     *  （下载瞬断等）的 doc 本会话再无补建机会（真机「个别贴纸不加载」）。 */
    private let arkStkNeedRequested: HashMap<Int64, Int64> = HashMap<Int64, Int64>()

    // S2-37：ArkTS 网格格子的长按计时（iOS PeekControllerGestureRecognizer longTapTimer 0.4s）。
    // ArkTS 只上报 press / unpress 触摸相位，计时在这里用 spawn+sleep（StickerGridCell /
    // MessageBubble 同一套真机已验证的实现）：按住期间行表 gen 变化把 ArkTS 格子整表重建
    // 也不会丢掉计时。长按成功后记下 doc，抬手带来的 cell（发送）事件按 doc 吞掉一次。
    private var arkStkPressDoc: Int64 = 0
    private var arkStkPressGroup: Int64 = 0
    private var arkStkPressGeneration: Int64 = 0
    private var arkStkLongPressFiredDoc: Int64 = 0

    /** 按 doc（优先被按的分区）在当前行表里找贴纸并打开预览；找不到只记日志。 */
    private func openArkStkPreviewFor(docId: Int64, pressedGroup: Int64): Unit {
        // W5 S2-37：ArkTS 侧 LongPressGesture（long 事件）与本侧 400ms 计时都会到这里，
        // 同一贴纸的预览只开一次（第二路到达时已在预览中）。
        if (this.showStickerPreview && this.previewSticker.documentId == docId) {
            Hilog.info(0, "CjTelegram", "[ArkStk] long press doc=${docId} already previewing")
            return
        }
        var found = StickerItem()
        var fromRecent = false
        for (row in this.rowSource.currentRows()) {
            // 同一贴纸可同时出现在 Recently Used 和它的包里：优先取被按的那个分区
            if (found.documentId != 0 && row.groupKey != pressedGroup) { continue }
            for (cell in row.cells) {
                if (cell.item.documentId == docId) {
                    found = cell.item
                    fromRecent = row.groupKey == -1
                }
            }
        }
        if (found.documentId != 0) {
            Hilog.info(0, "CjTelegram", "[ArkStk] long press doc=${docId} recent=${fromRecent}")
            this.arkStkLongPressFiredDoc = docId
            triggerHaptic("impact", "light")
            this.openStickerPreview(found, fromRecent: fromRecent)
        } else {
            Hilog.info(0, "CjTelegram", "[ArkStk] long press doc=${docId} not in current rows")
        }
    }

    private func handleArkStkPress(docId: Int64, pressedGroup: Int64, source!: String = "cell"): Unit {
        if (docId == 0) {
            Hilog.info(0, "CjTelegram", "[ArkStk] press ignored: doc=0 source=${source}")
            return
        }
        // R6V：格子级与 List 级两路都可能上报同一次按下，已在计时的同一贴纸不重启计时。
        if (this.arkStkPressDoc == docId) {
            Hilog.info(0, "CjTelegram", "[ArkStk] press dup doc=${docId} source=${source} (timer already running)")
            return
        }
        this.arkStkPressDoc = docId
        this.arkStkPressGroup = pressedGroup
        this.arkStkPressGeneration = this.arkStkPressGeneration + 1
        let generation = this.arkStkPressGeneration
        // W5 S2-37 诊断：真机上「最近使用」长按无任何反应且日志里抓不到 [ArkStk] 行。
        // 从按下到开预览的每一步都打 CjTelegram 日志（release 可见），下一轮上机按
        // "[ArkStk] press" → "timer fired" → "long press doc=" → "push {visible:false" 顺序核对。
        Hilog.info(0, "CjTelegram", "[ArkStk] press doc=${docId} group=${pressedGroup} gen=${generation} source=${source} timer=400ms")
        let _ = spawn {
            sleep(Duration.millisecond * 400)
            launch {
                if (this.panelAlive && this.arkStkPressDoc == docId && generation == this.arkStkPressGeneration) {
                    Hilog.info(0, "CjTelegram", "[ArkStk] timer fired doc=${docId} gen=${generation}")
                    this.arkStkPressDoc = 0
                    this.openArkStkPreviewFor(docId, this.arkStkPressGroup)
                } else {
                    Hilog.info(0, "CjTelegram", "[ArkStk] timer skipped doc=${docId} gen=${generation} alive=${this.panelAlive} pressDoc=${this.arkStkPressDoc} curGen=${this.arkStkPressGeneration}")
                }
            }
        }
    }

    private func handleArkStkUnpress(docId: Int64, reason: String): Unit {
        // cancel 也会在被按格子随行表重建销毁时到来，此时手指仍按着：保留计时，
        // 真正的滚动已由 ArkTS 侧的移动阈值以 unpress|move 提前取消。
        if (reason == "cancel") {
            Hilog.info(0, "CjTelegram", "[ArkStk] press cancel doc=${docId} (timer kept)")
            return
        }
        Hilog.info(0, "CjTelegram", "[ArkStk] unpress doc=${docId} reason=${reason} pressDoc=${this.arkStkPressDoc}")
        if (this.arkStkPressDoc == docId) {
            this.arkStkPressDoc = 0
            this.arkStkPressGeneration = this.arkStkPressGeneration + 1
        }
    }
    private var stkGridXPx: Float64 = 0.0
    private var stkGridYPx: Float64 = 0.0
    private var stkGridWPx: Float64 = 0.0
    private var stkGridHPx: Float64 = 0.0

    private func vp2pxF(v: Float64): Float64 {
        match (this.getUIContext().vp2px(v.vp)) {
            case Some(l) => l.value
            case None => v * 3.0
        }
    }

    /** 覆盖层只在连续网格态可见：搜索/包浏览态仍由仓颉自绘。 */
    private func stkGridShouldShow(): Bool {
        return !this.browsingPack && this.searchText.isEmpty() && !this.showStickerPreview
    }

    /** S2-37：预览开合都要同步 ArkTS 网格覆盖层的显隐（覆盖层否则会盖住预览菜单）。 */
    private func setStickerPreviewShown(shown: Bool): Unit {
        if (this.showStickerPreview == shown) { return }
        this.showStickerPreview = shown
        // 预览关闭后，同一贴纸的下一次点按又是正常发送（S2-37 收藏分组里点按发送）。
        if (!shown) { this.arkStkLongPressFiredDoc = 0 }
        this.pushStkGridUpdate(true)
        if (this.hostsStickerPreview) {
            if (shown) {
                Hilog.info(0, "CjTelegram",
                    "[StickerKeyboard] present preview at host doc=${this.previewSticker.documentId}" +
                    " favorite=${this.previewIsFavorite} recent=${this.previewIsRecent}")
                this.onPresentStickerPreview(this.makePreviewRequest())
            } else {
                Hilog.info(0, "CjTelegram", "[StickerKeyboard] dismiss preview at host")
                this.onDismissStickerPreview()
            }
        }
    }

    /** 根叠加层呈现用的请求包：菜单项与回调和面板内渲染（build 内的 StickerPreviewOverlay）完全一致。 */
    private func makePreviewRequest(): StickerPreviewRequest {
        let req = StickerPreviewRequest()
        req.sticker = this.previewSticker
        req.isFavorite = this.previewIsFavorite
        req.isRecent = this.previewIsRecent
        req.canSendSilently = this.peerId != getCurrentUserId()
        req.onRemoveFromRecents = { item: StickerItem => this.removePreviewFromRecents(item) }
        req.onSend = { item: StickerItem =>
            this.setStickerPreviewShown(false)
            this.onSelectSticker(item)
        }
        req.onSendSilently = { item: StickerItem =>
            this.setStickerPreviewShown(false)
            this.onSendStickerSilently(item)
        }
        req.onSchedule = { item: StickerItem =>
            this.setStickerPreviewShown(false)
            this.onScheduleSticker(item)
        }
        req.onFavorite = { item: StickerItem, remove: Bool => this.updatePreviewFavorite(item, remove) }
        req.onViewPack = { item: StickerItem => this.viewPreviewStickerPack(item) }
        req.onClose = { => this.setStickerPreviewShown(false) }
        return req
    }

    /** 组件是否在场：面板关闭后仍会有异步重建完成回调（去抖 rebuild /
     *  snapshot 订阅）迟到执行，它们携带 visible:true 会把已隐藏的 ArkTS
     *  覆盖层"复活"成一块无内容白块（provider 已注销、行表拉不到 ——
     *  真机 17:07:52 close 后 :54.785 复活实锤）。押着它：不在场时任何
     *  推送一律降级为隐藏。 */
    private var panelAlive: Bool = false

    /** 主动重量占位块并推送（OverlayGeometry 通道，见 EmojiPicker.remeasureGridSlot） */
    private func remeasureGridSlot(): Unit {
        if (!USE_ARKTS_STICKER_GRID || !this.panelAlive) { return }
        match (measureOverlaySlot(STICKER_GRID_SLOT_ID)) {
            case Some(r) =>
                let changed = r.x != this.stkGridXPx || r.y != this.stkGridYPx ||
                    r.w != this.stkGridWPx || r.h != this.stkGridHPx
                this.stkGridXPx = r.x
                this.stkGridYPx = r.y
                this.stkGridWPx = r.w
                this.stkGridHPx = r.h
                if (changed) { this.pushStkGridUpdate(true) }
            case None => ()
        }
    }

    private func pushStkGridUpdate(visible: Bool): Unit {
        if (!USE_ARKTS_STICKER_GRID) { return }
        let show = visible && this.panelAlive && this.stkGridShouldShow()
        let payload = "{\"visible\":${show},\"x\":${Int64(this.stkGridXPx)}," +
            "\"y\":${Int64(this.stkGridYPx)},\"w\":${Int64(this.stkGridWPx)}," +
            "\"h\":${Int64(this.stkGridHPx)},\"gen\":${this.arkStkGeneration}," +
            "\"sr\":${this.arkStkScrollRow},\"ss\":${this.arkStkScrollSeq}}"
        Hilog.info(0, "CjTelegram", "[ArkStk] push ${payload}")
        callArk("stickerGrid.update", payload)
    }

    private func forwardStkJump(row: Int64): Unit {
        this.arkStkScrollRow = row
        this.arkStkScrollSeq = this.arkStkScrollSeq + 1
        if (!this.arkStkPushInFlight) { this.pushStkGridUpdate(true) }
    }

    /** 同 probeAnimCache，但返回命中的光栅（用于播放池 cacheRasterSize）；
     *  全 miss 返回 fallback —— 后续补建/openCached 都按它收敛。 */
    private static func probeAnimRasterFor(
        filesDir: String, doc: Int64, fallback: Int32): Int32 {
        if (doc == 0 || filesDir.isEmpty()) { return fallback }
        let rasters: Array<Int64> = [136, 142, 126, 116, 174, 84]
        for (r in rasters) {
            let p = filesDir + "/anim_cache/doc${doc}@${r}.acv3"
            var ok = false
            try { ok = FileIo.access(p) } catch (_: Exception) { ok = false }
            if (ok) { return Int32(r) }
        }
        return fallback
    }

    /** 探测 doc 已有的 .acv3：优先 @136，miss 时回退旧驱动管线按格子尺寸
     *  建过的光栅（@116/@126/@142 等存量占大头）——RN 会话按文件头光栅自适应、
     *  drawImageRect 负责缩放，直接复用可免掉整包重建（真机实锤：硬编码 @136
     *  时 565 个 @116 存量全 miss，整页贴纸冻死在静帧兜底上）。
     *  全 miss 才返回 @136 让 ETS 发 need 补建。 */
    private static func probeAnimCache(filesDir: String, doc: Int64): String {
        let rasters: Array<Int64> = [136, 142, 126, 116, 174, 84]
        for (r in rasters) {
            let p = filesDir + "/anim_cache/doc${doc}@${r}.acv3"
            var ok = false
            try { ok = FileIo.access(p) } catch (_: Exception) { ok = false }
            if (ok) { return p }
        }
        return filesDir + "/anim_cache/doc${doc}@136.acv3"
    }

    /** 行表 → JSON（ArkTS 拉取）。光栅 136 的 .acv3/静帧路径 + featured 头行
     *  的 act 字段；贴纸无 premium 锁、无 tint。 */
    private static func buildStickerRowsJson(
        rows: Array<KeyboardRow>, filesDir: String): String {
        let sb = StringBuilder()
        sb.append("{\"rows\":[")
        var ri: Int64 = 0
        while (ri < Int64(rows.size)) {
            let row = rows[ri]
            if (ri > 0) { sb.append(",") }
            sb.append("{\"kind\":${row.kind},\"key\":\"${jsonEscape(row.key)}\",")
            sb.append("\"group\":\"${row.groupKey}\",\"title\":\"${jsonEscape(row.title)}\",")
            sb.append("\"sub\":\"${jsonEscape(row.subtitle)}\",\"badge\":\"${jsonEscape(row.badge)}\",")
            sb.append("\"clear\":\"${jsonEscape(row.clearAction)}\",")
            sb.append("\"act\":\"${jsonEscape(row.actionTitle)}\",")
            sb.append("\"locked\":false,\"embedded\":${row.embedded},")
            sb.append("\"h\":${row.height},\"item\":${row.itemSize},\"hsp\":${row.horizontalSpacing},")
            sb.append("\"inset\":${row.sideInset},\"cells\":[")
            var ci: Int64 = 0
            for (cell in row.cells) {
                if (ci > 0) { sb.append(",") }
                let doc = cell.item.documentId
                var cache = ""
                var stat = ""
                if (doc != 0 && !filesDir.isEmpty()) {
                    cache = probeAnimCache(filesDir, doc)
                    stat = filesDir + "/static_frames/doc${doc}@136#representative.bgra"
                }
                // isCreate =「新建贴纸」action 格(iOS 在 recent 组头部插入的
                // .icon(.add) 对位)。Phase1 迁移时此标记未进 JSON,ArkTS 格子
                // 渲染成空白 —— 「recently used 第一格空白」的根因。
                if (cell.isCreate) { sb.append("{\"cr\":true,") } else { sb.append("{") }
                sb.append("\"doc\":\"${doc}\",\"tint\":false,\"e\":\"${jsonEscape(cell.emoji)}\",")
                sb.append("\"x\":\"${jsonEscape(cell.expandLabel)}\",")
                sb.append("\"lock\":false,")
                sb.append("\"cache\":\"${jsonEscape(cache)}\",\"static\":\"${jsonEscape(stat)}\"}")
                ci = ci + 1
            }
            sb.append("]}")
            ri = ri + 1
        }
        sb.append("]}")
        return sb.toString()
    }

    /** ArkTS 事件（管道分隔）："cell|docId|" / "button|group" / "top|group" /
     *  "clear|action" / "need|doc"。sink 已 launch 回 UI 线程。 */
    private func handleStkGridEvent(payload: String): Unit {
        let parts = payload.split("|")
        if (parts.size == 0) { return }
        let kind = parts[0]
        if (kind == "cell" && parts.size >= 2) {
            let docId = (try { Int64.parse(parts[1]) } catch (_: Exception) { 0 })
            // S2-37：长按已弹出预览，这次抬手的 click 不是发送（iOS 长按抬手不发送）。
            if (docId != 0 && (this.showStickerPreview || this.arkStkLongPressFiredDoc == docId)) {
                this.arkStkLongPressFiredDoc = 0
                Hilog.info(0, "CjTelegram", "[ArkStk] click after long press doc=${docId} ignored")
                return
            }
            if (docId != 0) {
                var found = StickerItem()
                for (row in this.rowSource.currentRows()) {
                    for (cell in row.cells) {
                        if (cell.item.documentId == docId) { found = cell.item }
                    }
                }
                if (found.documentId != 0) { this.onSelectSticker(found) }
            }
        } else if (kind == "press" && parts.size >= 2) {
            // S2-37：ArkTS 网格格子按下 → 本侧 400ms 计时 → 预览菜单（handleArkStkPress）。
            // R6V：第 4 段是来源（cell = 格子 onTouch，list = List 级几何兜底），同一贴纸只计一次。
            let docId = (try { Int64.parse(parts[1]) } catch (_: Exception) { 0 })
            let pressedGroup = if (parts.size >= 3) { (try { Int64.parse(parts[2]) } catch (_: Exception) { 0 }) } else { 0 }
            let source = if (parts.size >= 4) { parts[3] } else { "cell" }
            this.handleArkStkPress(docId, pressedGroup, source: source)
        } else if (kind == "log") {
            // R6V S2-37：ArkTS 侧诊断经事件管道转发（真机只有仓颉侧 Hilog 被稳定抓到）。
            var text = ""
            var pi: Int64 = 1
            while (pi < Int64(parts.size)) {
                if (text.size > 0) { text = text + "|" }
                text = text + parts[pi]
                pi = pi + 1
            }
            Hilog.info(0, "CjTelegram", "[ArkStk] ets> ${text}")
        } else if (kind == "unpress" && parts.size >= 2) {
            let docId = (try { Int64.parse(parts[1]) } catch (_: Exception) { 0 })
            this.handleArkStkUnpress(docId, if (parts.size >= 3) { parts[2] } else { "up" })
        } else if (kind == "long" && parts.size >= 2) {
            // ArkTS 内置 Column 上的 LongPressGesture(400ms) 上报（W5 S2-37 第二路；
            // 与本侧 press 计时互为兜底，openArkStkPreviewFor 内去重）。
            let docId = (try { Int64.parse(parts[1]) } catch (_: Exception) { 0 })
            let pressedGroup = if (parts.size >= 3) { (try { Int64.parse(parts[2]) } catch (_: Exception) { 0 }) } else { 0 }
            Hilog.info(0, "CjTelegram", "[ArkStk] long(gesture) doc=${docId} group=${pressedGroup}")
            if (docId != 0) {
                this.arkStkPressDoc = 0
                this.arkStkPressGeneration = this.arkStkPressGeneration + 1
                this.openArkStkPreviewFor(docId, pressedGroup)
            }
        } else if (kind == "button" && parts.size >= 2) {
            let group = (try { Int64.parse(parts[1]) } catch (_: Exception) { 0 })
            if (group != 0) { this.installFeaturedPack(group) }
        } else if (kind == "create") {
            // ArkTS 网格的「新建贴纸」格(与旧仓颉网格 buildCreateTile 同路)
            this.onCreateSticker()
        } else if (kind == "clear" && parts.size >= 2) {
            this.handleHeaderClear(parts[1])
        } else if (kind == "top" && parts.size >= 2) {
            let group = (try { Int64.parse(parts[1]) } catch (_: Exception) { 0 })
            if (this.selectedNavigationId != group) {
                this.selectedNavigationId = group
                this.revealPackInNavigation(group)
            }
        } else if (kind == "need" && parts.size >= 2) {
            let docId = (try { Int64.parse(parts[1]) } catch (_: Exception) { 0 })
            let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let lastMs = this.arkStkNeedRequested.get(docId) ?? 0
            if (docId != 0 && nowMs - lastMs > 20_000) {
                this.arkStkNeedRequested[docId] = nowMs
                var found = StickerItem()
                for (row in this.rowSource.currentRows()) {
                    for (cell in row.cells) {
                        if (cell.item.documentId == docId) { found = cell.item }
                    }
                }
                if (CHAIN_TRACE_LOGS) {
                    Hilog.info(0, "CjTelegram",
                        "[ChainTrace] need-recv sticker doc=${docId} found=${found.documentId != 0}")
                }
                if (found.documentId != 0) {
                    let item = found
                    let recvMs = nowMs
                    let _ = getKeyboardMediaScheduler().submitUrgent {
                        let startMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                        let path = ensureStickerLocalFile(item)
                        let localMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                        if (CHAIN_TRACE_LOGS) {
                            Hilog.info(0, "CjTelegram",
                                "[ChainTrace] local doc=${item.documentId} ok=${path.size > 0} queuedMs=${startMs - recvMs} dlMs=${localMs - startMs}")
                        }
                        if (path.size > 0) {
                            let video = item.mimeType.contains("webm")
                            requestAnimationCacheBuild(
                                item.documentId, path, video, 136, urgent: true)
                            // 静帧渲染彻底移出 urgent 道：它走渲染闸、会被 live 流
                            // 卡住数秒 —— 曾把 6 条 urgent 道全堵死，后续 need 连
                            // 本地文件都拿不到（真机：30 个 need-recv 只 4 个 local）。
                            let _ = getKeyboardMediaScheduler().submit {
                                let _ = loadStickerStaticFrame(
                                    item.documentId, path, video, 136, representative: true)
                                if (CHAIN_TRACE_LOGS) {
                                    let statMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                                    Hilog.info(0, "CjTelegram",
                                        "[ChainTrace] static-built doc=${item.documentId} ms=${statMs - localMs}")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func rebuildRows(): Unit {
        if (this.contentWidth <= 0.0) { return }
        this.rowsRebuildPendingSinceMs = 0
        this.rowsRebuildGeneration = this.rowsRebuildGeneration + 1
        let rows = buildKeyboardRows(
            this.currentGroups(),
            stickerKeyboardMetrics(this.contentWidth),
            stickerFeaturedMetrics(this.contentWidth))
        this.rowSource.setRows(rows)
        this.embeddedSource.setCells(embeddedRowCells(rows))
        if (USE_ARKTS_STICKER_GRID) {
            let snapshot = rows
            let filesDir = getAppFilesDir()
            this.arkStkPushInFlight = true
            let _ = spawn {
                let json = buildStickerRowsJson(snapshot, filesDir)
                launch {
                    // hash 门控：内容没变绝不 bump gen —— gen 变化会让 ArkTS
                    // 整表 JSON.parse + reload（真机 trace：主线程 90ms 级任务
                    // ×11、20s 内 gen 走 188 代的重建风暴主源）。push 本身照发
                    //（廉价，且捎带可能在飞的跳转 sr/ss；gen 不变则 ETS 不 reload）。
                    if (json != this.cachedStickerRowsJson) {
                        this.cachedStickerRowsJson = json
                        this.arkStkGeneration = this.arkStkGeneration + 1
                    }
                    this.arkStkPushInFlight = false
                    this.pushStkGridUpdate(true)
                }
            }
        }
        this.scheduleCellDrive()
    }

    /** 快照驱动的重建去抖：明细串行到达时 400ms 聚合一次（尾沿触发）。
     *  用户直接动作（搜索/浏览包）仍走同步 rebuildRows —— 那些路径依赖
     *  重建后立即查行表。 */
    private var rowsRebuildGeneration: Int64 = 0
    /** First still-unserved rebuild request (ms); 0 = none pending. */
    private var rowsRebuildPendingSinceMs: Int64 = 0

    /**
     * Trailing debounce with a max wait. A pure trailing debounce starved while
     * pack details streamed in faster than 400ms apart (≈230 featured sets after
     * opening the panel): the grid stayed at trending + recent for ~25s with no
     * installed packs, and nav jumps found no row. iOS recomputes ItemLayout on
     * every inputData update; the max wait bounds the lag to ~1.2s.
     */
    private func scheduleRowsRebuild(): Unit {
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        if (this.rowsRebuildPendingSinceMs == 0) {
            this.rowsRebuildPendingSinceMs = nowMs
        } else if (nowMs - this.rowsRebuildPendingSinceMs >= STICKER_ROWS_REBUILD_MAX_WAIT_MS) {
            this.rebuildRows()
            return
        }
        this.rowsRebuildGeneration = this.rowsRebuildGeneration + 1
        let token = this.rowsRebuildGeneration
        let _ = spawn {
            sleep(Duration.millisecond * 400)
            launch {
                if (this.rowsRebuildGeneration == token) { this.rebuildRows() }
            }
        }
    }

    /** onAreaChange 在布局阶段回调，推迟一帧再重建，避免布局中途改数据源。 */
    private func updateContentWidth(width: Float64): Unit {
        if (width <= 0.0 || this.contentWidth == width) { return }
        this.contentWidth = width
        let _ = spawn {
            sleep(Duration.millisecond * 16)
            launch { this.rebuildRows() }
        }
    }

    /** 顶部导航高亮跟随首个可见行所属的分组，取代原来按像素反推分类的做法。 */
    private func updateNavigationForRow(index: Int64): Unit {
        let rows = this.rowSource.currentRows()
        if (index < 0 || index >= Int64(rows.size)) { return }
        if (this.selectedNavigationId != rows[index].groupKey) {
            this.selectedNavigationId = rows[index].groupKey
            this.revealPackInNavigation(this.selectedNavigationId)
        }
    }

    private func scrollToGroup(key: Int64): Unit {
        this.selectedNavigationId = key
        let index = keyboardRowIndexForGroup(this.rowSource.currentRows(), key)
        if (index >= 0) {
            if (USE_ARKTS_STICKER_GRID) {
                // 真正显示的是 ArkTS List：跳转经 sr/ss 转发（emoji 版同款）。
                this.forwardStkJump(index)
            } else {
                this.contentScroller.scrollToIndex(
                    Int32(index), smooth: false, align: ScrollAlign.Start)
            }
        }
    }

    private func handleHeaderClear(action: String): Unit {
        if (action == "trending") {
            this.showTrending = false
            this.rebuildRows()
            return
        }
        this.confirmClearRecent()
    }

    private func peerSpecificPackVisible(): Bool {
        if (!this.hasPeerSpecificPack || this.peerSpecificPack.stickers.isEmpty()) { return false }
        for (pack in this.installedPacks) {
            if (pack.id == this.peerSpecificPack.info.id) { return false }
        }
        return true
    }

    private func scrollToPeerSpecificPack(): Unit {
        this.scrollToGroup(-3)
    }

    private func scrollToFeatured(): Unit {
        this.scrollToGroup(-2)
    }

    private func scrollToRecent(): Unit {
        this.scrollToGroup(-1)
    }

    private func scrollToFaved(): Unit {
        this.scrollToGroup(0)
    }

    private func scrollToInstalledPack(pack: StickerPackInfo): Unit {
        var found = false
        for (detail in this.installedDetails) {
            if (detail.info.id == pack.id) { found = true }
        }
        if (found) {
            this.scrollToGroup(pack.id)
            return
        }
        this.selectedNavigationId = pack.id
        let requested = pack
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let _ = spawn {
            let detail = getStickersService().getStickerSet(requested.id, requested.accessHash)
            if (detail.success) { store.publishStickerPackDetail(accountToken, detail) }
            launch {
                if (detail.success) {
                    // applyStickerSnapshot only schedules a debounced rebuild once
                    // rows exist; rebuild now so the pack has a row index to jump to.
                    this.applyStickerSnapshot(store.currentStickerSnapshot())
                    this.rebuildRows()
                    this.scrollToGroup(requested.id)
                }
            }
        }
    }

    private func joinedCategoryIdentifiers(group: EmojiGroupInfo): String {
        var result = ""
        for (identifier in group.emoticons) { result = result + identifier }
        return result
    }

    private func addUniqueSticker(items: ArrayList<StickerItem>, candidate: StickerItem): Unit {
        if (!candidate.isPremium) { return }
        for (item in items) {
            if (item.documentId == candidate.documentId) { return }
        }
        items.add(candidate)
    }

    /** iOS premium category is local-only: Saved + Recent + installed collection premium files. */
    private func premiumCategoryStickers(): Array<StickerItem> {
        let result = ArrayList<StickerItem>()
        for (item in this.favedStickers) { this.addUniqueSticker(result, item) }
        for (item in this.recentStickers) { this.addUniqueSticker(result, item) }
        for (detail in this.installedDetails) {
            for (item in detail.stickers) { this.addUniqueSticker(result, item) }
        }
        return result.toArray()
    }

    private func startSearch(displayText: String, query: String, premium: Bool): Unit {
        this.searchText = displayText
        // 搜索态覆盖层让位（shouldShow 内部判定），退出搜索时恢复。
        this.pushStkGridUpdate(true)
        this.searchGeneration = this.searchGeneration + 1
        let token = this.searchGeneration
        if (displayText.isEmpty()) {
            this.isSearching = false
            this.searchShowsBack = false
            this.searchStickers = Array<StickerItem>(0, repeat: StickerItem())
            this.searchPacks = Array<StickerPackInfo>(0, repeat: StickerPackInfo())
            this.searchPackStickers = Array<StickerItem>(0, repeat: StickerItem())
            this.searchPackTitle = ""
            return
        }
        if (premium) {
            this.isSearching = false
            this.searchShowsBack = true
            this.searchStickers = this.premiumCategoryStickers()
            this.searchPacks = Array<StickerPackInfo>(0, repeat: StickerPackInfo())
            this.searchPackStickers = Array<StickerItem>(0, repeat: StickerItem())
            return
        }
        this.isSearching = true
        this.searchShowsBack = false
        let searchQuery = query
        let _ = spawn {
            sleep(Duration.millisecond * 250)
            if (this.searchGeneration != token) { return }
            let svc = getStickersService()
            let stickers = svc.getStickers(searchQuery).stickers.toArray()
            let packs = svc.searchStickerSets(searchQuery).packs.toArray()
            launch {
                if (this.searchGeneration == token) {
                    this.searchStickers = stickers
                    this.searchPacks = packs
                    this.isSearching = false
                    this.searchShowsBack = true
                }
            }
        }
    }

    private func onSearchChanged(value: String): Unit {
        this.selectedSearchCategoryId = 0
        this.startSearch(value, value, false)
    }

    private func selectSearchCategory(group: EmojiGroupInfo): Unit {
        if (this.selectedSearchCategoryId == group.iconEmojiId) {
            this.selectedSearchCategoryId = 0
            this.startSearch("", "", false)
            return
        }
        this.selectedSearchCategoryId = group.iconEmojiId
        this.startSearch(
            group.title,
            this.joinedCategoryIdentifiers(group),
            group.isPremium
        )
    }

    private func openSearchPack(pack: StickerPackInfo): Unit {
        this.packRequestGeneration = this.packRequestGeneration + 1
        let token = this.packRequestGeneration
        this.browsingPack = true
        this.browsingPackInfo = pack
        this.isPackLoading = true
        this.pushStkGridUpdate(true)
        this.searchPackTitle = pack.title
        this.searchPackStickers = Array<StickerItem>(0, repeat: StickerItem())
        let _ = spawn {
            let detail = getStickersService().getStickerSet(pack.id, pack.accessHash)
            let items = detail.stickers.toArray()
            launch {
                if (this.packRequestGeneration == token) {
                    this.searchPackStickers = items
                    this.isPackLoading = false
                }
            }
        }
    }

    private func browsingPackInstalled(): Bool {
        for (pack in this.installedPacks) {
            if (pack.id == this.browsingPackInfo.id) { return true }
        }
        return false
    }

    private func installBrowsingPack(): Unit {
        if (this.packInstallBusy || this.browsingPackInstalled()) { return }
        this.packInstallBusy = true
        let pack = this.browsingPackInfo
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let previous = store.currentStickerSnapshot()
        // iOS 在 Postbox transaction 中先把包加入 collection；按钮和导航立即响应。
        let optimisticVersion = store.optimisticallyInstallStickerPack(
            accountToken, pack, this.searchPackStickers)
        let _ = spawn {
            let result = getStickersService().installStickerSet(pack.id, pack.accessHash)
            if (result.success) {
                let installed = getStickersService().getAllStickers().packs.toArray()
                store.publishInstalledPacks(accountToken, installed)
                let detail = getStickersService().getStickerSet(pack.id, pack.accessHash)
                if (detail.success) { store.publishStickerPackDetail(accountToken, detail) }
                launch {
                    this.packInstallBusy = false
                }
            } else {
                let _ = store.restoreStickerSnapshotIfVersion(
                    accountToken, previous, optimisticVersion)
                launch { this.packInstallBusy = false }
            }
        }
    }

    /** iOS：featuredTop 点击 → FeaturedStickersScreen(highlightedPackId)。 */
    private func openFeaturedFromTrending(item: StickerItem): Unit {
        var packId: Int64 = 0
        for (pack in this.featuredPacks) {
            if (pack.cover.documentId == item.documentId) { packId = pack.id; break }
            for (top in pack.topItems) {
                if (top.documentId == item.documentId) { packId = pack.id; break }
            }
            if (packId != 0) { break }
        }
        routerPush("FeaturedStickersScreen", "${packId}")
    }

    private func openStickerPreview(sticker: StickerItem, fromRecent!: Bool = false): Unit {
        var favorite = false
        for (saved in this.favedStickers) {
            if (saved.documentId == sticker.documentId) { favorite = true }
        }
        this.previewIsRecent = fromRecent
        this.previewSticker = sticker
        this.previewIsFavorite = favorite
        this.setStickerPreviewShown(true)
    }

    private func updatePreviewFavorite(sticker: StickerItem, remove: Bool): Unit {
        this.setStickerPreviewShown(false)
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let verb = if (remove) { "unfave" } else { "fave" }
        Hilog.info(0, "CjTelegram",
            "[StickerKeyboard] ${verb} doc=${sticker.documentId} -> messages.faveSticker")
        let _ = spawn {
            let svc = getStickersService()
            let ok = svc.faveSticker(sticker, unfave: remove)
            if (ok) {
                let result = svc.getFavedStickers()
                Hilog.info(0, "CjTelegram",
                    "[StickerKeyboard] faveSticker ok doc=${sticker.documentId} unfave=${remove}" +
                    " refetch success=${result.success} count=${result.stickers.size}")
                if (result.success) {
                    store.publishFavedStickers(accountToken, result.stickers.toArray())
                }
            } else {
                Hilog.info(0, "CjTelegram",
                    "[StickerKeyboard] faveSticker FAILED doc=${sticker.documentId} unfave=${remove}")
            }
        }
    }

    private func viewPreviewStickerPack(sticker: StickerItem): Unit {
        this.setStickerPreviewShown(false)
        if (sticker.packId == 0) { return }
        let pack = StickerPackInfo()
        pack.id = sticker.packId
        pack.accessHash = sticker.packAccessHash
        pack.shortName = sticker.packShortName
        this.scrollToInstalledPack(pack)
    }

    /**
     * iOS Stickers.RemoveFromRecent（ChatEntityKeyboardInputNode.swift:3127-3140）：
     * removeRecentlyUsedSticker → messages.saveRecentSticker(unsave: true)，
     * 并提示 "Sticker was removed from Recents."。本地先摘掉，服务端失败不回滚列表外观。
     */
    private func removePreviewFromRecents(sticker: StickerItem): Unit {
        this.setStickerPreviewShown(false)
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let remaining = ArrayList<StickerItem>()
        for (item in this.recentStickers) {
            if (item.documentId != sticker.documentId) { remaining.add(item) }
        }
        let next = remaining.toArray()
        this.recentStickers = next
        store.publishRecentStickers(accountToken, next)
        showToast("Sticker was removed from Recents.")
        let _ = spawn {
            let ok = getStickersService().saveRecentSticker(sticker, unsave: true)
            Hilog.info(0, "CjTelegram", "[StickerKeyboard] removeFromRecents ${sticker.documentId} ok=${ok}")
        }
    }

    /** iOS 先弹 destructive action sheet；确认后才调用 clearRecentlyUsedStickers。 */
    private func confirmClearRecent(): Unit {
        let cancelButton = AlertDialogButtonOptions(value: "Cancel", action: { => () })
        let clearButton = AlertDialogButtonOptions(
            value: "Clear",
            fontColor: 0xFFFF3B30,
            action: { =>
                let store = getEntityKeyboardStore()
                let accountToken = store.currentToken()
                let _ = spawn {
                    if (getStickersService().clearRecentStickers()) {
                        store.publishRecentStickers(
                            accountToken, Array<StickerItem>(0, repeat: StickerItem()))
                    }
                }
            }
        )
        getUIContext().showAlertDialog(AlertDialogParamWithButtons(
            title: "Clear Recent Stickers",
            message: "Remove all recently used stickers?",
            autoCancel: true,
            primaryButton: cancelButton,
            secondaryButton: clearButton
        ))
    }

    public func build() {
        Stack(alignContent: Alignment.Center) {
            Column {
                this.buildPackNavigation()

                Row {
                    // iOS：贴纸搜索不在面板内聚焦（stickerInputData 的
                    // searchIsPlaceholderOnly=true → canFocus=false），点占位
                    // 直接 openSearch() 进全屏搜索/添加页（EntityKeyboard.swift:921）。
                    Row {
                        Text("🔍")
                            .fontSize(13)
                            .opacity(0.65)
                            .margin(left: 10, right: 5)
                        Text(trSource("Search"))
                            .fontSize(15)
                            .fontColor(0xFF8E8E93)
                    }
                    .height(36)
                    .borderRadius(18)
                    .backgroundColor(0x0F767680)
                    .alignItems(VerticalAlign.Center)
                    .layoutWeight(1)
                    .onClick({ _evt =>
                        this.onClose()
                        routerPush("FeaturedStickersScreen", "0")
                    })
                    Scroll {
                        Row {
                            ForEach(this.stickerSearchCategories,
                                itemGenerator: { group: EmojiGroupInfo, _idx: Int64 =>
                                    this.buildSearchCategory(group)
                                })
                        }
                    }
                    .scrollable(ScrollDirection.Horizontal)
                    .width(142)
                }
                .height(44)
                .padding(left: 8, right: 6)

                Divider().color(0x19000000).strokeWidth(0.5)

                if (this.browsingPack) {
                    this.buildPackDetailContent()
                } else if (this.searchText.isEmpty()) {
                    this.buildContinuousContent()
                } else {
                    this.buildSearchContent()
                }
            }
            .width(100.percent)
            .height(this.contentHeightVp)
            .backgroundColor(0xF5FFFFFF)
            // 布局宽度是 metrics 的唯一输入（iOS 用 availableSize.width）。
            .onAreaChange({ _: Area, newArea: Area =>
                this.updateContentWidth(newArea.width.value)
            })

            // S2-37：宿主接管呈现时（ChatRoomPage 根叠加层）这里不再画；否则按内容区高度自适应。
            if (this.showStickerPreview && !this.hostsStickerPreview) {
                StickerPreviewOverlay(
                    sticker: this.previewSticker,
                    isFavorite: this.previewIsFavorite,
                    isRecent: this.previewIsRecent,
                    canSendSilently: this.peerId != getCurrentUserId(),
                    screenHeightVp: this.contentHeightVp,
                    onRemoveFromRecents: { item: StickerItem => this.removePreviewFromRecents(item) },
                    onSend: { item: StickerItem =>
                        this.setStickerPreviewShown(false)
                        this.onSelectSticker(item)
                    },
                    onSendSilently: { item: StickerItem =>
                        this.setStickerPreviewShown(false)
                        this.onSendStickerSilently(item)
                    },
                    onSchedule: { item: StickerItem =>
                        this.setStickerPreviewShown(false)
                        this.onScheduleSticker(item)
                    },
                    onFavorite: { item: StickerItem, remove: Bool =>
                        this.updatePreviewFavorite(item, remove)
                    },
                    onViewPack: { item: StickerItem => this.viewPreviewStickerPack(item) },
                    onClose: { => this.setStickerPreviewShown(false) }
                )
            }
        }
        .width(100.percent)
        .height(this.contentHeightVp)
    }

    @Builder
    func buildSearchCategory(group: EmojiGroupInfo) {
        Column {
            CustomEmojiImage(documentId: group.iconEmojiId, size: 28.0, placeholder: "")
        }
        .width(38)
        .height(38)
        .borderRadius(10)
        .backgroundColor(if (this.selectedSearchCategoryId == group.iconEmojiId) {
            0x26317AFF
        } else { Color.Transparent })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.selectSearchCategory(group) })
    }

    @Builder
    func buildPackNavigation() {
        // 包封面区改 List+LazyForEach 虚拟化：放开「全部显示」后 eager
        // ForEach 会一次性创建上百个封面格，灌爆媒体调度队列（cap 160
        // drop-oldest），右滑出来的封面全空白 —— KeyboardCellSource 注释里
        // 「eager 容器套无界集合」的同款事故。固定按钮留在 List 外。
        Row {
                Text("⊞")
                    .fontSize(25)
                    .fontColor(0x646B72)
                    .width(44)
                    .height(42)
                    .textAlign(TextAlign.Center)
                    .onClick({ _evt => this.onOpenSettings() })
                if (!this.favedStickers.isEmpty()) {
                    Text("★")
                        .fontSize(21)
                        .fontColor(0x646B72)
                        .width(44)
                        .height(42)
                        .textAlign(TextAlign.Center)
                        .borderRadius(12)
                        .backgroundColor(if (this.selectedNavigationId == 0) { 0x26317AFF } else { Color.Transparent })
                        .onClick({ _evt => this.scrollToFaved() })
                }
                Text("◷")
                    .fontSize(23)
                    .fontColor(0x646B72)
                    .width(44)
                    .height(42)
                    .textAlign(TextAlign.Center)
                    .borderRadius(12)
                    .backgroundColor(if (this.selectedNavigationId == -1) { 0x26317AFF } else { Color.Transparent })
                    .onClick({ _evt => this.scrollToRecent() })
                if (this.peerSpecificPackVisible()) {
                    Column {
                        StickerGridCell(item: this.peerSpecificPack.stickers[0], size: 36.0,
                            onTap: { _item: StickerItem => this.scrollToPeerSpecificPack() })
                    }
                    .width(44)
                    .height(42)
                    .borderRadius(12)
                    .backgroundColor(if (this.selectedNavigationId == -3) { 0x26317AFF } else { Color.Transparent })
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .onClick({ _evt => this.scrollToPeerSpecificPack() })
                }
                List(space: 0, scroller: this.navScroller) {
                    LazyForEach(this.navPackSource,
                        itemGenerator: { pack: StickerPackInfo, _idx: Int64 =>
                            ListItem {
                                this.buildNavPackEntry(pack)
                            }
                        },
                        keyGenerator: { pack: StickerPackInfo, _idx: Int64 =>
                            "nav_${pack.id}"
                        })
                }
                .listDirection(Axis.Horizontal)
                .scrollBar(BarState.Off)
                .cachedCount(4)
                .layoutWeight(1)
                .height(if (this.navExpanded) { 68 } else { 44 })
                .onDidScroll({ _dx: Float64, _state: ScrollState =>
                    if (!this.navScrollProgrammatic) { this.expandNavigation() }
                })
        }
        .padding(left: 4, right: 4)
        .height(if (this.navExpanded) { 68 } else { 44 })
        .width(100.percent)
        .backgroundColor(0xE8FFFFFF)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func buildNavPackEntry(pack: StickerPackInfo) {
        if (this.isInstalledFeaturedPack(pack)) {
            this.buildInstalledNavigation(pack)
        } else {
            this.buildFeaturedNavigation(pack)
        }
    }

    /** 导航条里所有包封面的排列顺序，与 buildPackNavigation 的 ForEach 顺序一致。 */
    private func navigationPackIds(): Array<Int64> {
        let ids = ArrayList<Int64>()
        for (pack in this.installedPacks) { ids.add(pack.id) }
        for (pack in this.featuredNavigationPacks()) { ids.add(pack.id) }
        return ids.toArray()
    }

    /** 把 packId 对应的封面滚到导航条中间（List 虚拟化后直接按下标居中）。 */
    private func revealPackInNavigation(packId: Int64): Unit {
        if (packId <= 0) { return }
        let ids = this.navigationPackIds()
        var index: Int64 = -1
        var i: Int64 = 0
        while (i < Int64(ids.size)) {
            if (ids[i] == packId) { index = i; break }
            i = i + 1
        }
        if (index < 0) { return }
        this.navScrollProgrammatic = true
        this.navScroller.scrollToIndex(Int32(index), smooth: true, align: ScrollAlign.Center)
        let _ = spawn {
            sleep(Duration.millisecond * 400)
            launch { this.navScrollProgrammatic = false }
        }
    }

    /** 拖动即展开；停手 0.8s 后收回（iOS draggingStoppedTimer 同值）。 */
    private func expandNavigation(): Unit {
        this.navExpanded = true
        this.navCollapseGeneration = this.navCollapseGeneration + 1
        let token = this.navCollapseGeneration
        let _ = spawn {
            sleep(Duration.millisecond * 800)
            launch {
                if (this.navCollapseGeneration == token) { this.navExpanded = false }
            }
        }
    }

    @Builder
    func buildInstalledNavigation(pack: StickerPackInfo) {
        Column {
            if (pack.cover.documentId != 0) {
                StickerGridCell(
                    item: pack.cover,
                    size: if (this.navExpanded) { 42.0 } else { 36.0 },
                    navigationSlot: true,
                    onTap: { _item: StickerItem => this.scrollToInstalledPack(pack) })
            } else {
                LoadingProgress().width(18).height(18).color(0xB0B5BA)
            }
            // 展开态在封面下方显示包名——iOS 拖动导航条时就是这个样子
            if (this.navExpanded) {
                Text(pack.title)
                    .fontSize(10)
                    .fontColor(0x6D7278)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                    .width(52)
                    .textAlign(TextAlign.Center)
            }
        }
        .width(if (this.navExpanded) { 56 } else { 44 })
        .height(if (this.navExpanded) { 64 } else { 42 })
        .borderRadius(12)
        .backgroundColor(if (this.selectedNavigationId == pack.id) { 0x26317AFF } else { Color.Transparent })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.scrollToInstalledPack(pack) })
    }

    @Builder
    func buildFeaturedNavigation(pack: StickerPackInfo) {
        Column {
        Stack(alignContent: Alignment.BottomEnd) {
            StickerGridCell(
                item: pack.cover,
                size: if (this.navExpanded) { 42.0 } else { 36.0 },
                navigationSlot: true,
                onTap: { _item: StickerItem => this.scrollToFeaturedPack(pack) })
            if (pack.isUnread) {
                // iOS 对未读精选包画一个小红点，读过之后消失
                Text(trSource(""))
                    .width(9)
                    .height(9)
                    .borderRadius(5)
                    .backgroundColor(0xFFFF3B30)
            } else {
                Text("+")
                    .fontSize(14)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFFFFFF)
                    .width(16)
                    .height(16)
                    .textAlign(TextAlign.Center)
                    .borderRadius(8)
                    .backgroundColor(0x72B8F4)
            }
        }
        .width(if (this.navExpanded) { 52 } else { 44 })
        .height(if (this.navExpanded) { 46 } else { 42 })
        // 展开态显示包名——精选包和已装包一视同仁，
        // 上一版只给已装包加了名字，而这个账号的导航条**全是精选包**，
        // 于是屏幕上一个名字都没有，看起来像没生效。
        if (this.navExpanded) {
            Text(pack.title)
                .fontSize(10)
                .fontColor(0x6D7278)
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
                .width(52)
                .textAlign(TextAlign.Center)
        }
        }
        .width(if (this.navExpanded) { 56 } else { 44 })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.scrollToFeaturedPack(pack) })
    }

    /** iOS：点精选包只是滚到它在同一条列表里的分组，不换页。 */
    private func scrollToFeaturedPack(pack: StickerPackInfo): Unit {
        this.scrollToGroup(pack.id)
        if (this.detailStickersFor(pack.id).size > 0) { return }
        let requested = pack
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let _ = spawn {
            let detail = getStickersService().getStickerSet(requested.id, requested.accessHash)
            if (detail.success) {
                store.publishStickerPackDetail(accountToken, detail)
                launch {
                    this.applyStickerSnapshot(store.currentStickerSnapshot())
                    this.rebuildRows()
                    this.scrollToGroup(requested.id)
                }
            }
        }
    }

    /**
     * iOS 只为可见窗口内的 item 建 layer（ItemLayout.visibleItems(for:)）。
     * 这里等价物是 List + LazyForEach：itemGenerator 只对可见行调用，
     * 一屏之外的格子既不建组件，也不会触发 StickerGridCell 的媒体下载/解码。
     */
    @Builder
    func buildContinuousContent() {
        if (this.isLoading && this.recentStickers.isEmpty() && this.installedDetails.isEmpty()) {
            Column { LoadingProgress().width(28).height(28).color(0x8E8E93) }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
        } else if (USE_ARKTS_STICKER_GRID) {
            // 网格由 ArkTS 覆盖层渲染（壳层 Stack，见 ChatRoomPage.ets）；
            // 等高占位供几何。layoutWeight 而非定高（emoji 版页签行被盖的教训）。
            Column {}
                .width(100.percent)
                .layoutWeight(1)
                .id(STICKER_GRID_SLOT_ID)
                .onAreaChange({ _: Area, newArea: Area =>
                    this.stkGridXPx = this.vp2pxF(optLenVp(newArea.globalPosition.x))
                    this.stkGridYPx = this.vp2pxF(optLenVp(newArea.globalPosition.y))
                    this.stkGridWPx = this.vp2pxF(newArea.width.value)
                    this.stkGridHPx = this.vp2pxF(newArea.height.value)
                    this.pushStkGridUpdate(true)
                })
        } else {
            List(space: 0, scroller: this.contentScroller) {
                LazyForEach(this.rowSource,
                    itemGenerator: { row: KeyboardRow, _index: Int64 =>
                        ListItem {
                            this.buildKeyboardRow(row)
                        }
                    },
                    keyGenerator: { row: KeyboardRow, _index: Int64 => row.key })
            }
            .layoutWeight(1)
            .width(100.percent)
            .cachedCount(2)
            .scrollBar(BarState.Off)
            .onDidScroll({ _offset: Float64, _state: ScrollState =>
                setKeyboardGridScrolling(true)
            })
            .onScrollIndex({ first: Int32, last: Int32, _center: Int32 =>
                this.updateNavigationForRow(Int64(first))
                this.visibleFirstRow = Int64(first)
                this.visibleLastRow = Int64(last)
                this.scheduleCellDrive()
            })
            .onScrollStop({ =>
                setKeyboardGridScrolling(false)
                this.publishContentOffset()
            })
        }
    }

    private func publishContentOffset(): Unit {
        let current = this.contentScroller.currentOffset()
        if (current.isSome()) {
            this.onContentOffsetChanged(current.getOrThrow().yOffset)
        }
    }

    @Builder
    func buildKeyboardRow(row: KeyboardRow) {
        if (row.kind == KEYBOARD_ROW_HEADER) {
            this.buildRowHeader(row)
        } else {
            this.buildRowItems(row)
        }
    }

    /**
     * 分组头高度里已经含了 iOS 的 verticalGroupSpacing（首组除外），
     * 文字底对齐即可让留白落在标题上方，与 iOS 的 groupSpacing 语义一致。
     */
    @Builder
    func buildRowHeader(row: KeyboardRow) {
        if (row.actionTitle.size > 0) {
            this.buildFeaturedHeader(row)
        } else {
            this.buildPlainHeader(row)
        }
    }

    /** iOS itemFeaturedHeaderHeight = 60：左标题 + 副标题，右侧 Add。 */
    @Builder
    func buildFeaturedHeader(row: KeyboardRow) {
        Row {
            Column {
                Text(row.title)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x1C1C1E)
                    .maxLines(1)
                Text(row.subtitle)
                    .fontSize(12)
                    .fontColor(0x8E8E93)
                    .margin(top: 2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Button(this.featuredActionLabel(row.groupKey))
                .height(28)
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .backgroundColor(0x317AFF)
                .borderRadius(14)
                .padding(left: 14, right: 14)
                .onClick({ _evt => this.installFeaturedPack(row.groupKey) })
        }
        .width(100.percent)
        .height(row.height)
        .padding(left: KEYBOARD_HEADER_INSET, right: KEYBOARD_HEADER_INSET, bottom: 6)
        .alignItems(VerticalAlign.Bottom)
    }

    private func featuredActionLabel(packId: Int64): String {
        if (this.installingPackId == packId) { return "Adding…" }
        return "Add"
    }

    private func installFeaturedPack(packId: Int64): Unit {
        if (this.installingPackId == packId) { return }
        var target = StickerPackInfo()
        for (pack in this.featuredPacks) {
            if (pack.id == packId) { target = pack }
        }
        if (target.id == 0) { return }
        this.installingPackId = packId
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let previous = store.currentStickerSnapshot()
        let optimisticVersion = store.optimisticallyInstallStickerPack(
            accountToken, target, this.detailStickersFor(packId))
        let requested = target
        let _ = spawn {
            let result = getStickersService().installStickerSet(requested.id, requested.accessHash)
            if (result.success) {
                let installed = getStickersService().getAllStickers().packs.toArray()
                store.publishInstalledPacks(accountToken, installed)
                let detail = getStickersService().getStickerSet(requested.id, requested.accessHash)
                if (detail.success) { store.publishStickerPackDetail(accountToken, detail) }
            } else {
                let _ = store.restoreStickerSnapshotIfVersion(
                    accountToken, previous, optimisticVersion)
            }
            launch { this.installingPackId = 0 }
        }
    }

    @Builder
    func buildPlainHeader(row: KeyboardRow) {
        Row {
            Blank().width(36)
            Blank()
            Text(row.title)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(0x7C838A)
            Blank()
            if (row.clearAction.size > 0) {
                Text("×")
                    .fontSize(24)
                    .fontColor(0xA1A7AD)
                    .width(36)
                    .height(24)
                    .textAlign(TextAlign.Center)
                    .onClick({ _evt => this.handleHeaderClear(row.clearAction) })
            } else {
                Blank().width(36)
            }
        }
        .width(100.percent)
        .height(row.height)
        .padding(left: 12, right: 12)
        .alignItems(VerticalAlign.Bottom)
    }

    @Builder
    func buildRowItems(row: KeyboardRow) {
        if (row.embedded) {
            // iOS ItemGroup.isEmbedded → GroupEmbeddedView（一条横向 UIScrollView）。
            // trending 组不截断条数，靠横滚看完全部封面。
            List {
                LazyForEach(this.embeddedSource,
                    itemGenerator: { cell: KeyboardCell, index: Int64 =>
                        ListItem {
                            this.buildRowCell(row, cell, index)
                        }
                    },
                    keyGenerator: { cell: KeyboardCell, index: Int64 =>
                        "emb_${cell.item.documentId}_${index}"
                    })
            }
            .listDirection(Axis.Horizontal)
            .cachedCount(2)
            .scrollBar(BarState.Off)
            .width(100.percent)
            .height(row.height)
            .padding(left: row.sideInset, right: row.sideInset)
        } else {
        Row {
            ForEach(row.cells, itemGenerator: { cell: KeyboardCell, index: Int64 =>
                this.buildRowCell(row, cell, index)
            }, keyGenerator: { cell: KeyboardCell, index: Int64 =>
                // 稳定键：行表重建（明细到达 / 宽度变化）时，键没变的格子**原地复用**，
                // 不被拆毁重建 —— 拆重建会 stop 播放流，而重建出的实例收不到
                // 可靠的挂载回调，整片格子就此冻住（实测：滚动停止 1s 后明细 RPC
                // 返回触发 rebuildRows，7 条流被批量 stop，无一重启）。
                "${row.key}#${cell.item.documentId}#${cell.emoji}#${index}"
            })
        }
        .width(100.percent)
        .height(row.height)
        .padding(left: row.sideInset, right: row.sideInset)
        .alignItems(VerticalAlign.Top)
        }
    }

    @Builder
    func buildRowCell(row: KeyboardRow, cell: KeyboardCell, index: Int64) {
        if (cell.isCreate) {
            this.buildCreateTile(row, index)
        } else {
            this.buildStickerTile(row, cell.item, index)
        }
    }

    /** 行内首格不留左间距，其余每格左侧补一个 horizontalSpacing。 */
    private func tileLeftSpacing(row: KeyboardRow, index: Int64): Float64 {
        if (index == 0) { return 0.0 }
        return row.horizontalSpacing
    }

    @Builder
    func buildSearchContent() {
        Scroll {
            Column {
                if (!this.searchPacks.isEmpty()) {
                    Scroll {
                        Row {
                            ForEach(this.searchPacks, itemGenerator: { pack: StickerPackInfo, _idx: Int64 =>
                                this.buildSearchPack(pack)
                            })
                        }
                        .padding(left: 8, right: 8)
                    }
                    .scrollable(ScrollDirection.Horizontal)
                    .height(48)
                }
                if (!this.searchStickers.isEmpty()) {
                    this.buildStickerSection("STICKERS", this.searchStickers)
                }
                if (!this.searchPackStickers.isEmpty()) {
                    this.buildStickerSection(this.searchPackTitle, this.searchPackStickers)
                }
                if (!this.isSearching && this.searchStickers.isEmpty() &&
                    this.searchPacks.isEmpty() && this.searchPackStickers.isEmpty()) {
                    Text("No stickers found")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 36)
                }
            }
            .width(100.percent)
        }
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
    }

    @Builder
    func buildPackDetailContent() {
        Column {
            Row {
                Text("‹")
                    .fontSize(30)
                    .fontColor(0x317AFF)
                    .width(42)
                    .height(38)
                    .textAlign(TextAlign.Center)
                    .onClick({ _evt =>
                        this.browsingPack = false
                        this.searchPackStickers = Array<StickerItem>(0, repeat: StickerItem())
                        this.pushStkGridUpdate(true)
                    })
                Text(this.searchPackTitle)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .layoutWeight(1)
                if (this.packInstallBusy) {
                    LoadingProgress().width(20).height(20).color(0x317AFF).margin(right: 14)
                } else {
                    Button(if (this.browsingPackInstalled()) { "Installed" } else { "Add" })
                        .height(30)
                        .fontSize(13)
                        .fontColor(if (this.browsingPackInstalled()) { 0x8E8E93 } else { 0xFFFFFF })
                        .backgroundColor(if (this.browsingPackInstalled()) { 0xFFE9E9ED } else { 0x317AFF })
                        .borderRadius(15)
                        .margin(right: 10)
                        .onClick({ _evt => this.installBrowsingPack() })
                }
            }
            .width(100.percent)
            .height(40)
            .alignItems(VerticalAlign.Center)

            if (this.isPackLoading) {
                Column { LoadingProgress().width(28).height(28).color(0x8E8E93) }
                    .layoutWeight(1)
                    .width(100.percent)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
            } else {
                Scroll {
                    Flex(wrap: FlexWrap.Wrap) {
                        ForEach(this.searchPackStickers, itemGenerator: { sticker: StickerItem, _idx: Int64 =>
                            this.buildFixedTile(sticker)
                        })
                    }
                    .width(100.percent)
                }
                .layoutWeight(1)
                .scrollable(ScrollDirection.Vertical)
            }
        }
        .layoutWeight(1)
        .width(100.percent)
    }

    @Builder
    func buildSearchPack(pack: StickerPackInfo) {
        Column {
            if (pack.cover.documentId != 0) {
                StickerGridCell(item: pack.cover, size: 38.0,
                    onTap: { _item: StickerItem => this.openSearchPack(pack) })
            } else {
                Text(firstRuneString(pack.title))
                    .fontSize(15)
                    .fontColor(0x646B72)
            }
        }
        .width(44)
        .height(44)
        .borderRadius(10)
        .backgroundColor(0xF2F2F7)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.openSearchPack(pack) })
    }

    @Builder
    func buildStickerSection(title: String, stickers: Array<StickerItem>) {
        Column {
            Row {
                Blank().width(36)
                Blank()
                Text(title)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x7C838A)
                Blank()
                Blank().width(36)
            }
            .width(100.percent)
            .height(30)
            .padding(left: 12, right: 12)

            Flex(wrap: FlexWrap.Wrap) {
                ForEach(stickers, itemGenerator: { sticker: StickerItem, _idx: Int64 =>
                    this.buildFixedTile(sticker)
                })
            }
            .width(100.percent)
        }
        .width(100.percent)
    }

    @Builder
    func buildCreateTile(row: KeyboardRow, index: Int64) {
        Column {
            Text("+").fontSize(28).fontColor(0x8E8E93)
            Text(trSource("Create\nSticker"))
                .fontSize(10)
                .fontColor(0x8E8E93)
                .textAlign(TextAlign.Center)
        }
        .width(row.itemSize)
        .height(row.itemSize)
        .margin(left: this.tileLeftSpacing(row, index))
        .borderRadius(12)
        .backgroundColor(0x12000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.onCreateSticker() })
    }

    @Builder
    func buildStickerTile(row: KeyboardRow, sticker: StickerItem, index: Int64) {
        Column {
            StickerGridCell(
                item: sticker,
                size: row.itemSize,
                // trending（featuredTop，groupKey=-2）的点击**不是发送**：
                // iOS ChatEntityKeyboardInputNode.swift:1248 按 fileId 找到所属
                // 精选包，push FeaturedStickersScreen 并定位到该包。
                // 其余分组照旧发送（iOS 同文件 else 分支的 sendSticker）。
                onTap: { item: StickerItem =>
                    if (row.groupKey == -2) {
                        this.openFeaturedFromTrending(item)
                    } else {
                        this.onSelectSticker(item)
                    }
                },
                onLongPress: { item: StickerItem => this.openStickerPreview(item, fromRecent: row.groupKey == -1) }
            )
        }
        .width(row.itemSize)
        .height(row.itemSize)
        .margin(left: this.tileLeftSpacing(row, index))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    /**
     * 搜索结果与包详情是一次一页的有限结果，仍走原来的定宽网格；
     * 连续内容区（trending/faved/recent/已装包）才是行表 + LazyForEach。
     */
    @Builder
    func buildFixedTile(sticker: StickerItem) {
        Column {
            StickerGridCell(
                item: sticker,
                size: 64.0,
                onTap: { item: StickerItem => this.onSelectSticker(item) },
                onLongPress: { item: StickerItem => this.openStickerPreview(item) }
            )
        }
        .width(20.percent)
        .height(70)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }
}

/** 导航条包封面的虚拟化数据源（GifItemSource 同款）。 */
public class StickerPackNavSource <: IDataSource<StickerPackInfo> {
    private var items: Array<StickerPackInfo> = Array<StickerPackInfo>(0, repeat: StickerPackInfo())
    private var listeners: ArrayList<DataChangeListener> = ArrayList<DataChangeListener>()

    public init() {}

    public func totalCount(): Int64 {
        return Int64(this.items.size)
    }

    public func getData(index: Int64): StickerPackInfo {
        if (index < 0 || index >= Int64(this.items.size)) {
            return StickerPackInfo()
        }
        return this.items[index]
    }

    public func registerDataChangeListener(listener: DataChangeListener): Unit {
        for (existing in this.listeners) {
            if (refEq(existing, listener)) { return }
        }
        this.listeners.add(listener)
    }

    public func unregisterDataChangeListener(listener: DataChangeListener): Unit {
        let kept = ArrayList<DataChangeListener>()
        for (existing in this.listeners) {
            if (!refEq(existing, listener)) { kept.add(existing) }
        }
        this.listeners = kept
    }

    public func setItems(values: Array<StickerPackInfo>): Unit {
        this.items = values
        for (listener in this.listeners) {
            listener.onDataReloaded()
        }
    }
}
