package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.{
    getGifService, getStickersService, fetchCustomEmojiDocuments,
    GifItem, GifSearchResult, EmojiGroupInfo
}
import std.collection.ArrayList
import std.time.*

/** iOS GifPagerContentComponent exposes recent and trending subjects. */
public enum GifTab {
    | Trending | Recent
    public func ordinal(): Int32 {
        match (this) { case Trending => 0; case Recent => 1 }
    }
    public operator func ==(right: GifTab): Bool { return this.ordinal() == right.ordinal() }
    public operator func !=(right: GifTab): Bool { return this.ordinal() != right.ordinal() }
}

/**
 * Chat GIF keyboard backed by Telegram's configured @gif inline bot.
 *
 * Every item retains its own queryId/resultId pair for sending, pagination is
 * requested before the last row appears, and Recent remains backed by the
 * account-scoped messages.getSavedGifs list.
 */
@Component
public class GifPanel {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    /** 内容区高度（vp）：由宿主按真实 IME 高度注入（总高 - 页签行 - 手势带）。 */
    var contentHeightVp: Float64 = 287.0
    var onSelectGif: (GifItem) -> Unit = { _g: GifItem => }
    /** iOS openGifContextMenu 的「不响铃发送」。 */
    var onSendGifSilently: (GifItem) -> Unit = { _g: GifItem => }
    /** iOS openGifContextMenu 的「定时发送」——由页面弹时间选择器。 */
    var onScheduleGif: (GifItem) -> Unit = { _g: GifItem => }
    var onClose: () -> Unit = { => }
    /** 搜索框聚焦态回报宿主：宿主据此切换 IME 共存的紧凑面板（iOS 复刻）。 */
    var onSearchActiveChanged: (Bool) -> Unit = { _active: Bool => }
    var initialTabOrdinal: Int32 = 0
    var onTabChanged: (Int32) -> Unit = { _value: Int32 => }
    var initialContentOffset: Float64 = 0.0
    var onContentOffsetChanged: (Float64) -> Unit = { _value: Float64 => }

    @State var selectedTab: GifTab = GifTab.Trending
    @State var searchText: String = ""
    @State var isLoading: Bool = false
    @State var isLoadingMore: Bool = false
    @State var displayGifs: Array<GifItem> = Array<GifItem>(0, repeat: GifItem())
    // 虚拟化数据源。displayGifs 仍然是真相（loadMore/mergeUnique 都操作它），
    // 这里只是把它同步给 LazyForEach，避免 Video 节点随下拉无限增长。
    private let gifSource: GifItemSource = GifItemSource()
    @State var searchActive: Bool = false
    /** 搜索图标的「返回箭头」态，裸 @State（同 EmojiPicker.searchShowsBack）。 */
    @State var searchShowsBack: Bool = false
    @State var nextOffset: String = ""
    @State var searchCategories: Array<EmojiGroupInfo> =
        Array<EmojiGroupInfo>(0, repeat: EmojiGroupInfo())
    @State var selectedCategoryId: Int64 = 0
    @State var activeCategoryQuery: String = ""
    private var requestGeneration: Int64 = 0
    private var categoryGeneration: Int64 = 0
    private let gridScroller: Scroller = Scroller()
    private var didRestoreContentOffset: Bool = false

    protected override func aboutToAppear(): Unit {
        this.selectedTab = if (this.initialTabOrdinal == 1) { GifTab.Recent } else { GifTab.Trending }
        this.didRestoreContentOffset = false
        this.categoryGeneration = this.categoryGeneration + 1
        this.loadCategories(this.categoryGeneration)
        this.loadRoot()
    }

    private func restoreContentOffsetIfNeeded(): Unit {
        if (this.didRestoreContentOffset || this.initialContentOffset <= 0.0) { return }
        this.didRestoreContentOffset = true
        let value = this.initialContentOffset
        let _ = spawn {
            sleep(Duration.millisecond * 16)
            launch {
                this.gridScroller.scrollTo(xOffset: 0.0, yOffset: value, animation: false)
            }
        }
    }

    protected override func aboutToDisappear(): Unit {
        this.requestGeneration = this.requestGeneration + 1
        this.categoryGeneration = this.categoryGeneration + 1
    }

    private func categoryDocumentIds(groups: ArrayList<EmojiGroupInfo>): ArrayList<Int64> {
        let result = ArrayList<Int64>()
        for (group in groups) {
            if (group.iconEmojiId != 0) { result.add(group.iconEmojiId) }
        }
        return result
    }

    /** iOS resolves and prefetches every category icon after synchronizing groups. */
    private func loadCategories(generation: Int64): Unit {
        let _ = spawn {
            let service = getStickersService()
            let cached = service.getCachedEmojiGroups()
            if (cached.success && !cached.groups.isEmpty()) {
                let _ = fetchCustomEmojiDocuments(this.categoryDocumentIds(cached.groups))
                let cachedItems = cached.groups.toArray()
                launch {
                    if (this.categoryGeneration == generation) {
                        this.searchCategories = cachedItems
                    }
                }
            }
            let actual = service.getEmojiGroups()
            if (actual.success && !actual.groups.isEmpty()) {
                let _ = fetchCustomEmojiDocuments(this.categoryDocumentIds(actual.groups))
                let actualItems = actual.groups.toArray()
                launch {
                    if (this.categoryGeneration == generation) {
                        this.searchCategories = actualItems
                    }
                }
            }
        }
    }

    private func joinedIdentifiers(group: EmojiGroupInfo): String {
        var result = ""
        for (identifier in group.emoticons) { result = result + identifier }
        return result
    }

    private func loadRoot(): Unit {
        this.requestGeneration = this.requestGeneration + 1
        let generation = this.requestGeneration
        let tab = this.selectedTab
        let query = if (this.selectedCategoryId != 0) {
            this.activeCategoryQuery
        } else {
            this.searchText
        }
        let searching = this.searchActive
        launch {
            this.isLoading = true
            this.isLoadingMore = false
            this.nextOffset = ""
        }
        let _ = spawn {
            let service = getGifService()
            if (!searching && tab == GifTab.Recent) {
                let cachedItems = service.getCachedSavedGifsAsSearch().gifs.toArray()
                if (!cachedItems.isEmpty()) {
                    launch {
                        if (this.requestGeneration == generation) {
                            this.displayGifs = cachedItems
                            this.gifSource.setItems(this.displayGifs)
                        }
                    }
                }
            }
            let result: GifSearchResult = if (searching) {
                service.searchGifs(query)
            } else {
                match (tab) {
                    case GifTab.Trending => service.getTrendingGifs()
                    case GifTab.Recent => service.getSavedGifsAsSearch()
                }
            }
            let items = result.gifs.toArray()
            let offset = result.nextOffset
            launch {
                if (this.requestGeneration == generation) {
                    this.displayGifs = items
                    this.gifSource.setItems(this.displayGifs)
                    this.nextOffset = offset
                    this.isLoading = false
                    this.restoreContentOffsetIfNeeded()
                }
            }
        }
    }

    private func handleSearchChanged(value: String): Unit {
        this.searchText = value
        this.selectedCategoryId = 0
        this.activeCategoryQuery = ""
        this.searchActive = !value.isEmpty()
        // 防抖窗口内还没发请求，此时既不是转圈也不该是箭头——保持放大镜。
        this.searchShowsBack = false
        this.requestGeneration = this.requestGeneration + 1
        let debounceGeneration = this.requestGeneration
        if (value.isEmpty()) {
            this.loadRoot()
            return
        }
        let _ = spawn {
            sleep(Duration.millisecond * 220)
            launch {
                if (this.requestGeneration == debounceGeneration && this.searchText == value) {
                    this.loadRoot()
                    this.searchShowsBack = true
                }
            }
        }
    }

    private func selectCategory(group: EmojiGroupInfo): Unit {
        if (this.selectedCategoryId == group.iconEmojiId) {
            // iOS clears a preset category back to Recent.
            this.selectedCategoryId = 0
            this.activeCategoryQuery = ""
            this.searchActive = false
            this.selectedTab = GifTab.Recent
            this.onTabChanged(this.selectedTab.ordinal())
        } else {
            this.selectedCategoryId = group.iconEmojiId
            this.activeCategoryQuery = this.joinedIdentifiers(group)
            this.searchActive = true
        }
        this.loadRoot()
    }

    private func sameIdentity(left: GifItem, right: GifItem): Bool {
        if (!left.resultId.isEmpty() || !right.resultId.isEmpty()) {
            return left.queryId == right.queryId && left.resultId == right.resultId
        }
        return left.documentId != 0 && left.documentId == right.documentId
    }

    private func mergeUnique(existing: Array<GifItem>, incoming: Array<GifItem>): Array<GifItem> {
        let merged = ArrayList<GifItem>()
        for (item in existing) { merged.add(item) }
        for (candidate in incoming) {
            var duplicate = false
            for (item in existing) {
                if (this.sameIdentity(item, candidate)) { duplicate = true; break }
            }
            if (!duplicate) { merged.add(candidate) }
        }
        return merged.toArray()
    }

    private func loadMore(): Unit {
        if (this.isLoading || this.isLoadingMore || this.nextOffset.isEmpty()) { return }
        if (!this.searchActive && this.selectedTab == GifTab.Recent) { return }
        let offset = this.nextOffset
        let query = if (this.selectedCategoryId != 0) {
            this.activeCategoryQuery
        } else if (this.searchActive) {
            this.searchText
        } else {
            ""
        }
        let generation = this.requestGeneration
        launch { this.isLoadingMore = true }
        let _ = spawn {
            let result = getGifService().searchGifs(query, offset: offset)
            let incoming = result.gifs.toArray()
            let next = result.nextOffset
            launch {
                if (this.requestGeneration == generation) {
                    this.displayGifs = this.mergeUnique(this.displayGifs, incoming)
                    this.gifSource.setItems(this.displayGifs)
                    this.nextOffset = next
                    this.isLoadingMore = false
                }
            }
        }
    }

    private func preloadIfNeeded(lastVisible: Int32): Unit {
        if (lastVisible >= Int32(this.displayGifs.size) - 9) { this.loadMore() }
    }

    /**
     * iOS ChatEntityKeyboardInputNode.openGifContextMenu：长按 GIF 出上下文菜单。
     * 当前实现「保存 / 移出收藏」这一对与「发送」，静默/定时发送要等发送链路
     * 打通那两个参数后再补（对应差距表 C-6）。
     */
    private func openGifActions(gif: GifItem): Unit {
        let saved = this.selectedTab == GifTab.Recent
        // AlertDialogParamWithOptions 支持多按钮，正好装得下 iOS 那套：
        // 发送 / 不响铃发送 / 定时发送 / 保存或移出收藏。
        let actions = ArrayList<AlertDialogButtonOptions>()
        actions.add(AlertDialogButtonOptions(
            value: "Send", action: { => this.onSelectGif(gif) }))
        actions.add(AlertDialogButtonOptions(
            value: "Send without sound", action: { => this.onSendGifSilently(gif) }))
        actions.add(AlertDialogButtonOptions(
            value: "Schedule", action: { => this.onScheduleGif(gif) }))
        actions.add(AlertDialogButtonOptions(
            value: if (saved) { "Remove from Saved" } else { "Save GIF" },
            fontColor: if (saved) { 0xFFFF3B30 } else { 0xFF317AFF },
            action: { => this.toggleSavedGif(gif, saved) }))
        getUIContext().showAlertDialog(AlertDialogParamWithOptions(
            message: "GIF",
            autoCancel: true,
            buttons: actions.toArray(),
            buttonDirection: DialogButtonDirection.Vertical
        ))
    }

    private func toggleSavedGif(gif: GifItem, remove: Bool): Unit {
        let target = gif
        let unsave = remove
        let _ = spawn {
            let ok = getGifService().saveGif(target, unsave: unsave)
            if (ok) {
                launch { this.loadRoot() }
            }
        }
    }

    private func tabLabel(tab: GifTab): String {
        match (tab) { case GifTab.Trending => "Trending"; case GifTab.Recent => "Recent" }
    }

    public func build() {
        Column {
            Column {
                SearchBar(
                    text: this.searchText,
                    hint: trSource("Search GIFs"),
                    onChange: { value: String => this.handleSearchChanged(value) },
                    onFocus: { => this.onSearchActiveChanged(true) },
                    onCancel: { => this.onSearchActiveChanged(false) },
                    loading: this.isLoading && this.searchActive,
                    // 与 Emoji / 贴纸两侧同一条：出结果后左侧变返回箭头，点它退出搜索
                    // （iOS EmojiSearchStatusComponent.swift:522）。
                    backArrow: this.searchShowsBack,
                    onBackArrow: { =>
                        this.onSearchActiveChanged(false)
                        this.handleSearchChanged("")
                    }
                )
            }
            .width(100.percent)
            .padding(bottom: 4)

            if (this.searchText.isEmpty() && !this.searchCategories.isEmpty()) {
                Scroll() {
                    Row(space: 11) {
                        ForEach(this.searchCategories, itemGenerator: {
                            group: EmojiGroupInfo, _index: Int64 =>
                            this.buildCategoryButton(group)
                        })
                    }
                    .padding(left: 12, right: 12)
                }
                .width(100.percent)
                .height(36)
                .scrollable(ScrollDirection.Horizontal)
            }

            if (!this.searchActive) {
                Row {
                    this.buildTabButton(GifTab.Trending)
                    this.buildTabButton(GifTab.Recent)
                }
                .width(100.percent)
                .height(36)
                .padding(left: 8, right: 8)
            }

            if (this.isLoading && this.displayGifs.isEmpty()) {
                Column { LoadingProgress().width(28).height(28).color(0x8E8E93) }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
            } else if (this.displayGifs.isEmpty()) {
                Column {
                    Text(if (this.searchActive) { "No GIFs found" } else { "No recent GIFs" })
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                Grid(scroller: this.gridScroller) {
                    LazyForEach(this.gifSource,
                        itemGenerator: { item: GifItem, idx: Int64 =>
                            GridItem {
                                GifGridCell(item: item, onTap: this.onSelectGif,
                                    onLongPress: { picked: GifItem => this.openGifActions(picked) },
                                    onVisible: { => this.preloadIfNeeded(Int32(idx)) })
                            }
                                .aspectRatio(1.0)
                        },
                        keyGenerator: { item: GifItem, idx: Int64 =>
                            "gif_${item.documentId}_${idx}"
                        })
                }
                .cachedCount(1)
                .columnsTemplate("1fr 1fr 1fr")
                .columnsGap(1)
                .rowsGap(1)
                .width(100.percent)
                .layoutWeight(1)
                .onReachEnd({ => this.loadMore() })
                .onDidScroll({ _delta: Float64, _state: ScrollState =>
                    let current = this.gridScroller.currentOffset()
                    if (current.isSome()) {
                        this.onContentOffsetChanged(current.getOrThrow().yOffset)
                    }
                })
            }
        }
        .width(100.percent)
        .height(this.contentHeightVp)
        .backgroundColor(0xF5FFFFFF)
    }

    @Builder
    func buildTabButton(tab: GifTab) {
        Text(this.tabLabel(tab))
            .fontSize(13)
            .fontColor(if (this.selectedTab == tab) { 0x317AFF } else { 0x8E8E93 })
            .fontWeight(if (this.selectedTab == tab) { FontWeight.Medium } else { FontWeight.Normal })
            .layoutWeight(1)
            .height(32)
            .textAlign(TextAlign.Center)
            .onClick({ _evt =>
                if (this.selectedTab != tab) {
                    this.selectedTab = tab
                    this.onTabChanged(tab.ordinal())
                    this.loadRoot()
                }
            })
    }

    @Builder
    func buildCategoryButton(group: EmojiGroupInfo) {
        Stack(alignContent: Alignment.Center) {
            CustomEmojiImage(
                documentId: group.iconEmojiId,
                size: 24.0,
                placeholder: ""
            )
        }
        .width(30)
        .height(30)
        .borderRadius(15)
        .backgroundColor(if (this.selectedCategoryId == group.iconEmojiId) {
            0x1A317AFF
        } else {
            0x00FFFFFF
        })
        .onClick({ _evt => this.selectCategory(group) })
    }
}
