package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashMap, HashSet}
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.router.takePending
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.components.{
    StickerGridCell, SearchBar, getKeyboardMediaScheduler, getKeyboardDocPlayback}
import ohos_app_cangjie_entry.services.stickerLocalFilePeek

/**
 * FeaturedStickersScreen — 添加贴纸页（iOS StickerPaneSearchGlobalItem 对位重构）。
 *
 * iOS 布局（StickerPaneSearchGlobaltem.swift）：
 *   行内边距 left 14 / right 16，topOffset 12；
 *   标题 bold 16（y=2+12），副题 "N stickers" regular 15 灰（y=23+12）；
 *   安装按钮：高 28、宽=文本+32、semibold 13、圆角 14，右对齐（y=4+12）；
 *   预览：sideInset 2，itemSide = floor(行宽/5)，一行 5 个（y=48+12）。
 * 顶部搜索框（EntitySearch 的 "Search Stickers"）→ messages.searchStickerSets。
 *
 * 行虚拟化：List + LazyForEach（eager ForEach × 每行 5 个 StickerGridCell
 * 会一次性创建几百个媒体加载，KeyboardCellSource 注释里的同款教训）。
 */
@HybridComponentEntry
@Component
public class FeaturedStickersScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoading: Bool = true
    @State var loadError: Bool = false
    @State var loaded: Bool = false
    @State var searchText: String = ""
    @State var isSearching: Bool = false
    /** 安装状态本地覆盖（点 Add 后立即生效，不等快照）。 */
    @State var installedOverride: Array<Int64> = Array<Int64>(0, repeat: 0)
    @State var installBusyId: Int64 = 0
    @State var listWidthVp: Float64 = 360.0
    /** 数据纪元：网络新鲜结果落地时 +1，进全表 key 强制行重建 ——
     *  磁盘缓存的 file_reference 会过期（缩略图下载全吃 FILE_REFERENCE_EXPIRED
     *  → 整页空白的根因），重建让格子拿到新 ref 重试。 */
    @State var refreshEpoch: Int64 = 0

    private var featuredPacks: Array<StickerPackInfo> =
        Array<StickerPackInfo>(0, repeat: StickerPackInfo())
    private var searchPacks: Array<StickerPackInfo> =
        Array<StickerPackInfo>(0, repeat: StickerPackInfo())
    private let packSource: FeaturedPackSource = FeaturedPackSource()
    private let detailCache: HashMap<Int64, Array<StickerItem>> =
        HashMap<Int64, Array<StickerItem>>()
    private let detailRequested: HashSet<Int64> = HashSet<Int64>()
    private var searchGeneration: Int64 = 0
    private let listScroller: Scroller = Scroller()
    private var highlightPackId: Int64 = 0
    /** 可见行窗（onScrollIndex 维护），预览播放驱动用。 */
    private var visibleFirstRow: Int64 = 0
    private var visibleLastRow: Int64 = 8
    private var driveLifecycle: Int64 = 0

    private func parseHighlightParam(raw: String): Int64 {
        var result: Int64 = 0
        for (rune in raw.toRuneArray()) {
            let d = Int64(UInt32(rune)) - 48
            if (d < 0 || d > 9) { return 0 }
            result = result * 10 + d
        }
        return result
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("FeaturedStickersScreen")
        if (raw != "{}") { this.highlightPackId = this.parseHighlightParam(raw) }
        let _ = spawn { this.loadFeaturedPacks() }
        this.startPreviewDriveHeartbeat()
    }

    protected override func aboutToDisappear(): Unit {
        // 离页收流：本页与键盘共用 doc 播放池，退出时清空可见集。
        this.driveLifecycle = this.driveLifecycle + 1
        getKeyboardDocPlayback().driveVisibleItems(ArrayList<(StickerItem, Int32)>())
    }

    /**
     * 预览播放驱动（iOS trending 页的预览是动的）：每 1.2s 按可见行窗
     * 对账一次 doc 播放池。缓存流不占实时解码额度，成本可控。
     */
    private func startPreviewDriveHeartbeat(): Unit {
        this.driveLifecycle = this.driveLifecycle + 1
        let lifecycle = this.driveLifecycle
        let _ = spawn {
            while (true) {
                sleep(Duration.millisecond * 1200)
                if (this.driveLifecycle != lifecycle) { break }
                launch {
                    if (this.driveLifecycle == lifecycle) { this.drivePreviews() }
                }
            }
        }
    }

    private func drivePreviews(): Unit {
        let packs = this.currentPacks()
        let visible = ArrayList<(StickerItem, Int32)>()
        // 与键盘格子的缓存光栅（68vp×2=136）对齐：预览格 ~71vp 按自身尺寸
        // 取 142 会让同一 doc 的 .acv3 两套光栅并存、页面侧永远缓存 miss
        // 落回 live-8（遥测 run=8 实锤）。差 3vp 的欠采样不可见。
        let raster: Int32 = 136
        var index = this.visibleFirstRow
        var last = this.visibleLastRow + 1
        if (last >= Int64(packs.size)) { last = Int64(packs.size) - 1 }
        while (index <= last && index >= 0 && Int64(packs.size) > 0) {
            for (item in this.previewItems(packs[index])) {
                if (item.documentId != 0 &&
                    (item.mimeType.contains("tgs") || item.mimeType.contains("lottie") ||
                     item.mimeType.contains("webm")) &&
                    // 预览页只为**已下载**的 doc 起播（动画是锦上添花）：
                    // 驱动会触发整只文件下载，几十个一起挤占带宽，反而
                    // 拖慢 4KB 缩略图 —— iOS 预览页同样只播本地就绪的。
                    stickerLocalFilePeek(item).size > 0) {
                    visible.add((item, raster))
                }
            }
            index = index + 1
        }
        getKeyboardDocPlayback().driveVisibleItems(visible)
    }

    private func loadFeaturedPacks(): Unit {
        // 磁盘缓存先行秒开（键盘侧早已写过 featured 缓存）：网络 RPC 可能排在
        // 贴纸下载洪峰后面几十秒（真机 14:30 卡 Loading 实锤），页面不能陪等。
        let cached = getStickersService().getCachedFeaturedStickerPacks()
        if (cached.success && !cached.packs.isEmpty()) {
            for (pack in cached.packs) {
                for (uid in cached.unreadIds) {
                    if (uid == pack.id) { pack.isUnread = true }
                }
            }
            let cachedItems = cached.packs.toArray()
            launch {
                if (this.isLoading) {
                    this.featuredPacks = cachedItems
                    this.isLoading = false
                    this.refreshSource()
                    this.scrollToHighlight()
                }
            }
        }
        Hilog.info(0, "CjTelegram", "[FeaturedStickersScreen] cached=${cached.packs.size}, fetching fresh")
        let result = getStickersService().getFeaturedStickerPacks()
        Hilog.info(0, "CjTelegram", "[FeaturedStickersScreen] fresh packs=${result.packs.size} success=${result.success}")
        if (result.success) {
            // unread 标记落到 info 上（iOS：包封面小蓝点）
            for (pack in result.packs) {
                for (uid in result.unreadIds) {
                    if (uid == pack.id) { pack.isUnread = true }
                }
            }
            let items = result.packs.toArray()
            launch {
                this.featuredPacks = items
                this.isLoading = false
                // 新鲜 file_reference 到手：bump 纪元强制整表行重建一次，
                // 让缓存期下载失败（引用过期）的格子拿新 ref 重试。
                this.refreshEpoch = this.refreshEpoch + 1
                this.refreshSource()
                this.scrollToHighlight()
            }
        } else {
            launch {
                // 缓存已经上屏的话不降级为错误页
                if (this.isLoading) {
                    this.loadError = true
                    this.isLoading = false
                }
            }
        }
    }

    private func currentPacks(): Array<StickerPackInfo> {
        if (!this.searchText.isEmpty()) { return this.searchPacks }
        return this.featuredPacks
    }

    private func refreshSource(): Unit {
        this.packSource.setItems(this.currentPacks())
    }

    private func onSearchChanged(value: String): Unit {
        this.searchText = value
        this.searchGeneration = this.searchGeneration + 1
        let token = this.searchGeneration
        if (value.isEmpty()) {
            this.isSearching = false
            this.searchPacks = Array<StickerPackInfo>(0, repeat: StickerPackInfo())
            this.refreshSource()
            return
        }
        this.isSearching = true
        let query = value
        let _ = spawn {
            sleep(Duration.millisecond * 250)
            if (this.searchGeneration != token) { return }
            let result = getStickersService().searchStickerSets(query)
            let items = result.packs.toArray()
            launch {
                if (this.searchGeneration == token) {
                    this.searchPacks = items
                    this.isSearching = false
                    this.refreshSource()
                }
            }
        }
    }

    private func scrollToHighlight(): Unit {
        if (this.highlightPackId == 0) { return }
        var index: Int64 = -1
        var i: Int64 = 0
        while (i < Int64(this.featuredPacks.size)) {
            if (this.featuredPacks[i].id == this.highlightPackId) { index = i; break }
            i = i + 1
        }
        if (index <= 0) { return }
        let target = index
        let _ = spawn {
            sleep(Duration.millisecond * 120)
            launch {
                this.listScroller.scrollToIndex(Int32(target), smooth: false,
                    align: ScrollAlign.Start)
            }
        }
    }

    /** 行预览：明细缓存 → topItems → 封面；统一截前 5（iOS 同款）。 */
    private func previewItems(pack: StickerPackInfo): Array<StickerItem> {
        let result = ArrayList<StickerItem>()
        if (this.detailCache.contains(pack.id)) {
            for (item in this.detailCache[pack.id]) {
                if (result.size >= 5) { break }
                result.add(item)
            }
            return result.toArray()
        }
        for (item in pack.topItems) {
            if (result.size >= 5) { break }
            result.add(item)
        }
        if (result.isEmpty() && pack.cover.documentId != 0) { result.add(pack.cover) }
        return result.toArray()
    }

    /** 预览不足 5 个时后台补明细（有界调度器，绝不裸 spawn）。 */
    private func ensureRowDetail(pack: StickerPackInfo): Unit {
        if (pack.topItems.size >= 5) { return }
        if (this.detailCache.contains(pack.id)) { return }
        if (this.detailRequested.contains(pack.id)) { return }
        let _ = this.detailRequested.add(pack.id)
        let target = pack
        // 插队道：可见行的明细优先于预热/下载洪峰，否则「只有一个封面」
        // 的行迟迟补不齐（用户实锤）。
        let _ = getKeyboardMediaScheduler().submitUrgent {
            let detail = getStickersService().getStickerSet(target.id, target.accessHash)
            if (detail.success) {
                let items = detail.stickers.toArray()
                launch {
                    this.detailCache[target.id] = items
                    // 只有该行的 key 变化（见 keyGenerator），不再整表重建。
                    this.refreshSource()
                }
            }
        }
    }

    private func isPackInstalled(pack: StickerPackInfo): Bool {
        for (id in this.installedOverride) {
            if (id == pack.id) { return true }
        }
        return pack.isInstalled
    }

    private func installPack(pack: StickerPackInfo): Unit {
        if (this.installBusyId != 0 || this.isPackInstalled(pack)) { return }
        this.installBusyId = pack.id
        let target = pack
        let _ = spawn {
            let result = getStickersService().installStickerSet(target.id, target.accessHash)
            if (result.success) {
                // 让键盘侧同步：已装列表 + 明细都发布进 store
                let store = getEntityKeyboardStore()
                let accountToken = store.currentToken()
                let installed = getStickersService().getAllStickers().packs.toArray()
                store.publishInstalledPacks(accountToken, installed)
                let detail = getStickersService().getStickerSet(target.id, target.accessHash)
                if (detail.success) { store.publishStickerPackDetail(accountToken, detail) }
                launch {
                    let merged = ArrayList<Int64>()
                    for (id in this.installedOverride) { merged.add(id) }
                    merged.add(target.id)
                    this.installedOverride = merged.toArray()
                    this.installBusyId = 0
                }
            } else {
                launch { this.installBusyId = 0 }
            }
        }
    }

    /** itemSide = floor((行宽 − 2×2)/5)，iOS sideInset=2。 */
    private func previewItemSide(): Float64 {
        var w = this.listWidthVp - 4.0
        if (w < 100.0) { w = 356.0 }
        var side = w / 5.0
        if (side > 90.0) { side = 90.0 }
        return side
    }

    public func build() {
        Column {
            this.buildHeader()
            this.buildSearchRow()
            if (this.isLoading) {
                this.buildCenterHint("Loading...")
            } else if (this.loadError) {
                this.buildCenterHint("Failed to load sticker packs")
            } else if (this.packSource.totalCount() == 0 && !this.isSearching) {
                this.buildCenterHint(if (this.searchText.isEmpty()) {
                    "No featured sticker packs"
                } else { "No sticker sets found" })
            } else {
                this.buildPackList()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFFFF)
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder
    func buildHeader() {
        Row {
            Text("‹")
                .fontSize(30)
                .fontColor(0xFF317AFF)
                .width(44)
                .height(44)
                .textAlign(TextAlign.Center)
                .onClick({ _evt => routerPop() })
            Text(trSource("Trending Stickers"))
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
            Column {}.width(44).height(44)
        }
        .width(100.percent)
        .height(52)
        .padding(top: 8)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func buildSearchRow() {
        Column {
            SearchBar(
                text: this.searchText,
                hint: trSource("Search Stickers"),
                loading: this.isSearching,
                backArrow: false,
                onChange: { value: String => this.onSearchChanged(value) },
                onSubmit: { value: String => this.onSearchChanged(value) },
                onCancel: { => this.onSearchChanged("") }
            )
        }
        .width(100.percent)
        .padding(left: 8, right: 8, bottom: 6)
    }

    @Builder
    func buildCenterHint(text: String) {
        Column {
            Text(text)
                .fontSize(15)
                .fontColor(0xFF8E8E93)
                .textAlign(TextAlign.Center)
        }
        .width(100.percent)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func buildPackList() {
        List(space: 0, scroller: this.listScroller) {
            LazyForEach(this.packSource,
                itemGenerator: { pack: StickerPackInfo, _idx: Int64 =>
                    ListItem {
                        this.buildPackRow(pack)
                    }
                },
                keyGenerator: { pack: StickerPackInfo, _idx: Int64 =>
                    // 明细版本只进**本行**的 key：此前全局版本号进所有行的 key，
                    // 每个明细到达都触发整表重建 + 全部首帧重解 ——「很卡」主因。
                    "featured_${pack.id}_${if (this.detailCache.contains(pack.id)) { 1 } else { 0 }}_e${this.refreshEpoch}"
                })
        }
        .width(100.percent)
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .cachedCount(2)
        .divider(ListDividerOptions(strokeWidth: 0, color: Color.Transparent))
        .onScrollIndex({ first: Int32, last: Int32, _center: Int32 =>
            this.visibleFirstRow = Int64(first)
            this.visibleLastRow = Int64(last)
        })
        .onAreaChange({ _: Area, newArea: Area =>
            this.listWidthVp = newArea.width.value
        })
    }

    @Builder
    func buildPackRow(pack: StickerPackInfo) {
        Column {
            // 标题/副题/按钮区（iOS：title y2 / desc y23 / button y4，区高 48）
            Row {
                Column {
                    Row {
                        Text(pack.title)
                            .fontSize(16)
                            .fontWeight(FontWeight.Bold)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                        if (pack.isUnread) {
                            Column {}
                                .width(6)
                                .height(6)
                                .borderRadius(3)
                                .backgroundColor(0xFF317AFF)
                                .margin(left: 6)
                        }
                    }
                    .alignItems(VerticalAlign.Center)
                    Text("${pack.count} stickers")
                        .fontSize(15)
                        .fontColor(0xFF8E8E93)
                        .margin(top: 3)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                if (this.isPackInstalled(pack)) {
                    Text(trSource("Added"))
                        .fontSize(13)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0xFF317AFF)
                        .height(28)
                        .margin(top: 2)
                } else {
                    Text(if (this.installBusyId == pack.id) { "Adding…" } else { "Add" })
                        .fontSize(13)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0xFFFFFFFF)
                        .height(28)
                        .padding(left: 16, right: 16)
                        .borderRadius(14)
                        .backgroundColor(0xFF317AFF)
                        .textAlign(TextAlign.Center)
                        .margin(top: 2)
                        .onClick({ _evt => this.installPack(pack) })
                }
            }
            .width(100.percent)
            .height(46)
            .padding(left: 14, right: 16)
            .alignItems(VerticalAlign.Top)

            // 预览行：一行 5 个，itemSide = 行宽/5（iOS y=48 起）
            Row {
                ForEach(this.previewItems(pack),
                    itemGenerator: { item: StickerItem, _pidx: Int64 =>
                        StickerGridCell(
                            item: item,
                            size: this.previewItemSide(),
                            previewOnly: true,
                            onTap: { _s: StickerItem =>
                                routerPush("StickerPackPreviewPage", pack.id.toString())
                            }
                        )
                    })
            }
            .width(100.percent)
            .padding(left: 2, right: 2)
            .margin(top: 2)

            Divider()
                .color(0x14000000)
                .strokeWidth(0.5)
                .margin(left: 16, right: 16, top: 12)
        }
        .width(100.percent)
        .padding(top: 12)
        .alignItems(HorizontalAlign.Start)
        .onAppear({ => this.ensureRowDetail(pack) })
        .onClick({ _evt =>
            routerPush("StickerPackPreviewPage", pack.id.toString())
        })
    }
}

/** 精选包列表的虚拟化数据源（GifItemSource 同款）。 */
public class FeaturedPackSource <: IDataSource<StickerPackInfo> {
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
