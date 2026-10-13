package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getWebSearchService,
    InlineBotResult,
    InlineBotResultSet
}
import ohos_app_cangjie_entry.components.SearchBar
import ohos_app_cangjie_entry.router.*

/**
 * WebSearchPage — 图片 / GIF 网络搜索主页面（混合工程迁移版）
 *
 * 对应 iOS WebSearchUI/Sources/WebSearchController.swift。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（含 .hideTitleBar/.onReady），只留内容 + 末尾 .onAppear
 *  - pageStack.pop(animated) → routerPop()
 *  - 路由参数原经 onReady context.pathInfo.param 读取 → 改为 takePending("WebSearchPage")（ensureLoaded 首帧解析）
 *
 * 路由参数格式（"<peerId>:<peerAccessHash>"，当前聊天上下文，用于发送选中结果）。
 */
@HybridComponentEntry
@Component
public class WebSearchPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ==================== 搜索状态 ====================

    @State var searchText: String = ""
    @State var searchMode: String = "images"   // "images" or "gifs"
    @State var isSearching: Bool = false
    @State var searchError: String = ""

    // ==================== 结果状态 ====================

    @State var results: Array<InlineBotResult> = Array<InlineBotResult>(0, repeat: InlineBotResult())
    @State var nextOffset: String = ""
    @State var queryId: Int64 = 0
    @State var hasMore: Bool = false
    @State var isLoadingMore: Bool = false
    @State var isSending: Bool = false
    @State var sendStatus: String = ""

    // ==================== 聊天上下文（路由参数传入） ====================

    private var peerId: Int64 = 0
    private var peerAccessHash: Int64 = 0

    @State var loaded: Bool = false

    // ==================== 生命周期 ====================

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let param = takePending("WebSearchPage")
        Hilog.info(0, "CjTelegram", "[WebSearchPage] ensureLoaded param=${param}")
        this.parseRouteParam(param)
    }

    // ==================== 辅助方法 ====================

    private func parseRouteParam(param: String): Unit {
        let parts = param.split(":")
        if (parts.size >= 2) {
            this.peerId = parseWebSearchI64(parts[0])
            this.peerAccessHash = parseWebSearchI64(parts[1])
        }
    }

    private func getSearchHint(): String {
        if (this.searchMode == "gifs") {
            return "Search GIFs..."
        }
        return "Search Images..."
    }

    private func getResultCount(): Int64 {
        return Int64(this.results.size)
    }

    private func getResultThumb(index: Int64): String {
        if (index < 0 || index >= Int64(this.results.size)) { return "" }
        return this.results[index].thumbUrl
    }

    private func getResultId(index: Int64): String {
        if (index < 0 || index >= Int64(this.results.size)) { return "" }
        return this.results[index].id
    }

    // ==================== 业务逻辑 ====================

    /**
     * 执行搜索（通过 spawn 线程调用 WebSearchService）。
     * R-69: 网络调用在 spawn { ...; launch{ @State 写 } }
     */
    private func doSearch(query: String): Unit {
        if (query.size == 0) { return }
        let mode = this.searchMode
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[WebSearchPage] Searching: mode=${mode} query=${query}")
            let svc = getWebSearchService()
            let resultSet: InlineBotResultSet = if (mode == "gifs") {
                svc.searchGif(query)
            } else {
                svc.searchImage(query)
            }
            let items = resultSet.results
            let qId = resultSet.queryId
            let nextOff = resultSet.nextOffset
            let count = items.size
            // Build Array<InlineBotResult> from ArrayList
            let arr = Array<InlineBotResult>(count, { i: Int64 => items[i] })
            launch {
                this.results = arr
                this.queryId = qId
                this.nextOffset = nextOff
                this.hasMore = nextOff.size > 0
                this.isSearching = false
                this.searchError = if (arr.size == 0) { "No results found" } else { "" }
                Hilog.info(0, "CjTelegram", "[WebSearchPage] Search done, ${arr.size} results nextOff=${nextOff}")
            }
        }
    }

    /**
     * 加载下一页结果（分页无限滚动）。
     * S-001: @State 写在 launch{} 内。
     */
    private func doLoadMore(): Unit {
        if (this.isLoadingMore) { return }
        if (!this.hasMore) { return }
        if (this.nextOffset.size == 0) { return }
        let mode = this.searchMode
        let query = this.searchText
        let offset = this.nextOffset
        if (query.size == 0) { return }
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[WebSearchPage] LoadMore: mode=${mode} q=${query} offset=${offset}")
            let svc = getWebSearchService()
            let resultSet: InlineBotResultSet = if (mode == "gifs") {
                svc.searchGif(query, offset: offset)
            } else {
                svc.searchImage(query, offset: offset)
            }
            let newItems = resultSet.results
            let qId = resultSet.queryId
            let nextOff = resultSet.nextOffset
            let newCount = newItems.size
            let newArr = Array<InlineBotResult>(newCount, { i: Int64 => newItems[i] })
            launch {
                // Append new results to existing — temp-var + reassign per S-001 @State rule
                let oldCount = this.results.size
                let total = oldCount + newArr.size
                let merged = Array<InlineBotResult>(total, { i: Int64 =>
                    if (i < oldCount) { this.results[i] } else { newArr[i - oldCount] }
                })
                this.results = merged
                this.queryId = qId
                this.nextOffset = nextOff
                this.hasMore = nextOff.size > 0
                this.isLoadingMore = false
                Hilog.info(0, "CjTelegram", "[WebSearchPage] LoadMore done, total=${total} hasMore=${nextOff.size > 0}")
            }
        }
        launch {
            this.isLoadingMore = true
        }
    }

    /**
     * 用户选中某个结果，发送到当前聊天。
     * R-69: 网络调用在 spawn { ...; launch{ @State 写 } }
     */
    private func onSelectResult(resultId: String): Unit {
        if (resultId.size == 0) { return }
        if (this.isSending) { return }
        let qId = this.queryId
        let pid = this.peerId
        let pah = this.peerAccessHash
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[WebSearchPage] Sending result: queryId=${qId} resultId=${resultId}")
            let svc = getWebSearchService()
            let ok = svc.sendSelectedResult(qId, resultId, pid, pah)
            launch {
                this.isSending = false
                this.sendStatus = if (ok) { "Sent!" } else { "Send failed" }
                if (ok) {
                    routerPop()
                }
            }
        }
        launch {
            this.isSending = true
            this.sendStatus = "Sending..."
        }
    }

    /**
     * 切换搜索模式（Images ↔ GIFs）并重新搜索。
     */
    private func switchMode(mode: String): Unit {
        if (this.searchMode == mode) { return }
        this.searchMode = mode
        this.results = Array<InlineBotResult>(0, repeat: InlineBotResult())
        this.nextOffset = ""
        this.queryId = 0
        this.hasMore = false
        this.isLoadingMore = false
        this.searchError = ""
        if (this.searchText.size > 0) {
            this.isSearching = true
            this.doSearch(this.searchText)
        }
    }

    private func onSearchTextChanged(text: String): Unit {
        this.searchText = text
        this.searchError = ""
        if (text.size > 0) {
            this.isSearching = true
            this.doSearch(text)
        } else {
            this.results = Array<InlineBotResult>(0, repeat: InlineBotResult())
            this.queryId = 0
            this.nextOffset = ""
            this.hasMore = false
            this.isLoadingMore = false
        }
    }

    // ==================== Build ====================

    public func build() {
        Column {
            // ─── 顶部标题栏 ───────────────────────────────────────────
            Row {
                Button(trSource("Cancel"))
                    .fontSize(16)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .onClick({ _evt: ClickEvent =>
                        routerPop()
                    })
                Blank().layoutWeight(1)
                Text("Search Media")
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x000000)
                    .layoutWeight(2)
                    .textAlign(TextAlign.Center)
                Blank().layoutWeight(1)
            }
            .width(100.percent)
            .height(44)
            .padding(left: 8, right: 8)
            .backgroundColor(0xF7F7F7)

            // ─── 搜索输入栏（SearchBar 原子，P2-RETRO-search-a） ────
            Column {
                SearchBar(
                    backArrow: false,
                    text: this.searchText,
                    hint: this.getSearchHint(),
                    onChange: { value: String =>
                        this.onSearchTextChanged(value)
                    },
                    loading: this.isSearching
                )
            }
            .width(100.percent)

            // ─── 模式切换（Images / GIFs）─────────────────────────────
            Row {
                Button(trSource("Images"))
                    .fontSize(14)
                    .fontColor(if (this.searchMode == "images") { 0xFFFFFF } else { 0x007AFF })
                    .backgroundColor(if (this.searchMode == "images") { 0x007AFF } else { 0xE5E5EA })
                    .borderRadius(16)
                    .height(32)
                    .padding(left: 16, right: 16)
                    .onClick({ _evt: ClickEvent =>
                        this.switchMode("images")
                    })
                Button(trSource("GIFs"))
                    .fontSize(14)
                    .fontColor(if (this.searchMode == "gifs") { 0xFFFFFF } else { 0x007AFF })
                    .backgroundColor(if (this.searchMode == "gifs") { 0x007AFF } else { 0xE5E5EA })
                    .borderRadius(16)
                    .height(32)
                    .padding(left: 16, right: 16)
                    .margin(left: 8)
                    .onClick({ _evt: ClickEvent =>
                        this.switchMode("gifs")
                    })
                Blank().layoutWeight(1)
            }
            .width(100.percent)
            .height(44)
            .padding(left: 8, right: 8, top: 6, bottom: 6)

            // ─── 发送状态提示 ────────────────────────────────────────
            if (this.sendStatus.size > 0) {
                Text(this.sendStatus)
                    .fontSize(13)
                    .fontColor(if (this.sendStatus == "Sent!") { 0x34C759 } else { 0xFF3B30 })
                    .width(100.percent)
                    .padding(left: 12)
                    .height(24)
            }

            // ─── 主内容区：加载中 / 错误 / 结果网格 ──────────────────
            if (this.isSearching) {
                Column {
                    LoadingProgress()
                        .width(40)
                        .height(40)
                        .color(0x007AFF)
                    Text(trSource("Searching..."))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 8)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.searchError.size > 0) {
                Column {
                    Text(this.searchError)
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .textAlign(TextAlign.Center)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.results.size == 0 && this.searchText.size == 0) {
                Column {
                    Text("Search for images and GIFs")
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .textAlign(TextAlign.Center)
                    Text("Type a keyword to get started")
                        .fontSize(13)
                        .fontColor(0xAAAAAA)
                        .margin(top: 4)
                        .textAlign(TextAlign.Center)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                // ─── 结果网格 + 分页无限滚动 ──────────────────────────
                Column {
                    Grid() {
                        ForEach(this.results,
                            itemGenerator: { item: InlineBotResult, _idx: Int64 =>
                                GridItem() {
                                    this.buildResultCell(item)
                                }
                            })
                    }
                    .columnsTemplate("1fr 1fr 1fr")
                    .rowsGap(2)
                    .columnsGap(2)
                    .width(100.percent)
                    .layoutWeight(1)
                    .padding(2)
                    .onReachEnd({ =>
                        Hilog.info(0, "CjTelegram", "[WebSearchPage] onReachEnd hasMore=${this.hasMore}")
                        this.doLoadMore()
                    })

                    // 分页加载指示器（滚动到底部时可见）
                    if (this.isLoadingMore) {
                        Row {
                            LoadingProgress()
                                .width(20)
                                .height(20)
                                .color(0x007AFF)
                            Text("Loading more...")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(left: 8)
                        }
                        .width(100.percent)
                        .height(36)
                        .justifyContent(FlexAlign.Center)
                    }
                }
                .width(100.percent)
                .layoutWeight(1)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder
    func buildResultCell(item: InlineBotResult) {
        Stack {
            if (item.thumbUrl.size > 0) {
                Image(item.thumbUrl)
                    .width(100.percent)
                    .height(100.percent)
                    .objectFit(ImageFit.Cover)
            } else {
                Column {
                    Text(if (item.resultType == "gif") { "GIF" } else { "IMG" })
                        .fontSize(12)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0xE5E5EA)
            }
        }
        .width(100.percent)
        .height(120)
        .onClick({ _evt: ClickEvent =>
            this.onSelectResult(item.id)
        })
    }
}

/**
 * parseInt64 helper — parse Int64 from string, returns 0 on failure.
 */
private func parseWebSearchI64(s: String): Int64 {
    var result: Int64 = 0
    var negative = false
    let runes = s.toRuneArray()
    var start: Int64 = 0
    if (runes.size > 0 && runes[0] == r'-') {
        negative = true
        start = 1
    }
    var i: Int64 = start
    while (i < runes.size) {
        let c = UInt32(runes[i])
        if (c >= 48u32 && c <= 57u32) {
            result = result * 10 + Int64(c - 48u32)
        }
        i += 1
    }
    return if (negative) { -result } else { result }
}
