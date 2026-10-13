package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.*
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

/**
 * MessageSearch — 消息搜索组件 (Phase I1)
 * 
 * 对应 TelegramHarmony MessageSearch (基于 messages.search API)
 * 
 * 功能:
 * - 搜索栏 (TextInput)
 * - 匹配消息列表
 * - 上下导航按钮 (prev/next)
 * - 搜索结果高亮
 */
@Component
public class MessageSearch {
    // CG-02: user-visible text follows the app language (iOS PresentationStrings),
    // not hard-coded literals.
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()
    @State var searchText: String = ""
    @State var searchResults: ArrayList<SearchResultItem> = ArrayList<SearchResultItem>()
    @State var isSearching: Bool = false
    @State var currentIndex: Int64 = 0
    @State var totalResults: Int64 = 0
    @State var searchVersion: Int64 = 0
    @State var hasSearched: Bool = false
    // S354: 结果列表展开态。搜索出结果后自动展开；点某条跳转后收起；
    // 点计数区可再次展开。对位 iOS ChatSearchResultsController 的模态结果列表。
    @State var showResultsList: Bool = false

    // 回调
    var onClose: () -> Unit = { => }
    var onJumpToMessage: (Int64) -> Unit = { _msgId: Int64 => }
    // S024 日历入口（iOS ChatSearch 底栏日历按钮 → ChatMediaCalendar）
    var onOpenCalendar: () -> Unit = { => }
    // S4-12: iOS ChatController.updateItemNodesSearchTextHighlightStates — (query, result ids);
    // the page paints the query inside those bubbles. Empty ids = clear the highlight.
    var onHighlightChange: (String, ArrayList<Int64>) -> Unit = { _q: String, _ids: ArrayList<Int64> => }

    /**
     * Phase P0-2: 真实搜索 — 调用 RealMessageService.searchMessages() → messages.search TL
     * 结果通过 parseMessages() 完整解析，提取 messageId/text/senderName/date
     */
    func doSearch() {
        if (this.searchText.size == 0) {
            this.searchResults = ArrayList<SearchResultItem>()
            this.totalResults = 0
            this.currentIndex = 0
            this.hasSearched = false
            this.showResultsList = false
            this.onHighlightChange("", ArrayList<Int64>())
            return
        }

        this.isSearching = true
        let queryCopy = this.searchText

        spawn {
            try {
                let peerId = getSelectedChatId()
                let peerType = getSelectedChatPeerType()
                let svc = getRealMessageService()
                let response = svc.searchMessages(peerType, peerId, queryCopy, limit: 50)
                let currentUserId = getCurrentUserId()
                let emptyCache = HashMap<Int64, String>()
                let messages = svc.parseMessages(response, currentUserId, emptyCache)
                // 由基础群升级来的超级群：iOS 同时搜旧基础群（SearchMessages.swift:372 migrationReference →
                // additionalPeer，:460 对它再发一次 messages.search），结果接在超级群结果之后。
                // 旧群消息在本会话视图里的 id 已映射到负数区间（migratedHistoryViewId），跳转按同一映射。
                if (normalizeDialogPeerType(peerType) == "channel") {
                    let migratedFrom = svc.getFullChatInfo("channel", peerId).migratedFromChatId
                    if (migratedFrom != 0) {
                        let oldResponse = svc.searchMessages("chat", migratedFrom, queryCopy, limit: 50)
                        let oldMessages = svc.parseMessages(oldResponse, currentUserId, emptyCache,
                            conversationPeerType: "chat", conversationPeerId: migratedFrom)
                        for (m in oldMessages) {
                            if (m.id > 0) {
                                m.id = migratedHistoryViewId(m.id)
                                messages.add(m)
                            }
                        }
                        Hilog.info(0, "CjTelegram",
                            "[MessageSearch] migrated basic group ${migratedFrom}: ${oldMessages.size} matches")
                    }
                }
                
                let results = ArrayList<SearchResultItem>()
                for (msg in messages) {
                    let item = SearchResultItem(
                        messageId: msg.id,
                        text: truncateRunes(msg.content, 80),
                        senderName: msg.senderName,
                        date: msg.time
                    )
                    results.add(item)
                }
                
                let firstMsgId = if (results.size > 0) { results[0].messageId } else { Int64(0) }
                let totalCount = Int64(results.size)
                let resultIds = ArrayList<Int64>()
                for (r in results) { resultIds.add(r.messageId) }
                let curIdx = if (results.size > 0) { Int64(1) } else { Int64(0) }
                
                Hilog.info(0, "CjTelegram", "[MessageSearch] Search complete")
                
                launch {
                    this.searchResults = results
                    this.totalResults = totalCount
                    this.currentIndex = curIdx
                    this.hasSearched = true
                    this.isSearching = false
                    // S354: 有结果即展开列表，让用户能直接挑，而不是只能上一条/下一条翻
                    this.showResultsList = totalCount > 0
                    // S4-12: paint the query inside every result bubble before jumping to the first.
                    this.onHighlightChange(queryCopy, resultIds)
                    if (firstMsgId > 0) {
                        this.onJumpToMessage(firstMsgId)
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[MessageSearch] Search error")
                launch {
                    this.hasSearched = true
                    this.isSearching = false
                }
            }
        }
    }

    func goToNext() {
        if (this.totalResults == 0) { return }
        if (this.currentIndex < this.totalResults) {
            this.currentIndex += 1
            let idx = this.currentIndex - 1
            if (idx < Int64(this.searchResults.size)) {
                this.onJumpToMessage(this.searchResults[idx].messageId)
            }
        }
    }

    func goToPrev() {
        if (this.totalResults == 0) { return }
        if (this.currentIndex > 1) {
            this.currentIndex -= 1
            let idx = this.currentIndex - 1
            if (idx >= 0 && idx < Int64(this.searchResults.size)) {
                this.onJumpToMessage(this.searchResults[idx].messageId)
            }
        }
    }

    /**
     * S354: 从结果列表直接跳到第 idx 条（0 基）。
     * 同步 currentIndex（1 基，与计数区展示一致）并收起列表，
     * 让用户看清跳转后的消息；随后仍可用 ▲▼ 或点计数区继续浏览。
     */
    func jumpToResult(idx: Int64) {
        if (idx < 0 || idx >= Int64(this.searchResults.size)) { return }
        this.currentIndex = idx + 1
        this.showResultsList = false
        this.onJumpToMessage(this.searchResults[idx].messageId)
    }

    /**
     * Phase P0-2: 300ms 防抖调度
     * 记录 version，spawn 后 sleep 300ms，如果 version 未变则触发搜索
     */
    func scheduleSearch(version: Int64) {
        spawn {
            sleep(300 * Duration.millisecond)
            // S4-12: doSearch writes @State (isSearching …) and must run on the UI
            // thread; calling it from this background task threw and was swallowed,
            // so messages.search was never sent.
            launch {
                if (this.searchVersion == version) {
                    Hilog.info(0, "CjTelegram", "[MessageSearch] debounce fired version=${version} query='${this.searchText}'")
                    this.doSearch()
                }
            }
        }
    }

    private func str(key: String, fallback: String): String {
        return this.presentationStrings.getOr(key, fallback)
    }

    public func build() {
        Column {
        Row {
            // 搜索输入框（iOS ChatSearchNavigationContentNode: strings.Conversation_SearchPlaceholder）
            TextInput(placeholder: this.str("Conversation.SearchPlaceholder", "Search this chat"))
                .layoutWeight(1)
                .height(36)
                .fontSize(15)
                .backgroundColor(0xF2F2F7)
                .borderRadius(10)
                .padding(left: 8, right: 8)
                .onChange({ value: String =>
                    this.searchText = value
                    this.searchVersion += 1
                    if (value.size == 0) {
                        this.searchResults = ArrayList<SearchResultItem>()
                        this.totalResults = 0
                        this.currentIndex = 0
                        this.hasSearched = false
                        this.showResultsList = false
                        this.onHighlightChange("", ArrayList<Int64>())
                        return
                    }
                    if (value.size >= 2) {
                        this.scheduleSearch(this.searchVersion)
                    }
                })
                .onSubmit({ _enterKey =>
                    this.doSearch()
                })

            // 搜索结果计数 + 导航
            if (this.totalResults > 0) {
                Text("${this.currentIndex}/${this.totalResults}")
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(left: 8)
                    .onClick({ evt =>
                        // S354: 点计数区展开/收起结果列表
                        this.showResultsList = !this.showResultsList
                    })

                // 上一个
                Text("▲")
                    .fontSize(16)
                    .fontColor(if (this.currentIndex > 1) { 0x317AFF } else { 0xC7C7CC })
                    .margin(left: 4)
                    .onClick({ evt =>
                        this.goToPrev()
                    })

                // 下一个
                Text("▼")
                    .fontSize(16)
                    .fontColor(if (this.currentIndex < this.totalResults) { 0x317AFF } else { 0xC7C7CC })
                    .margin(left: 4)
                    .onClick({ evt =>
                        this.goToNext()
                    })
            } else if (this.isSearching) {
                LoadingProgress()
                    .width(20)
                    .height(20)
                    .color(0x317AFF)
                    .margin(left: 8)
            } else if (this.hasSearched && this.totalResults == 0) {
                // iOS ChatSearchResultsController: strings.Conversation_SearchNoResults
                Text(this.str("Conversation.SearchNoResults", "No Results"))
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(left: 8)
            }

            // 日历跳转（iOS: 搜索态底栏日历图标 → 按日期定位消息）
            Text("📅")
                .fontSize(18)
                .margin(left: 8)
                .onClick({ evt =>
                    this.onOpenCalendar()
                })

            // 关闭按钮（iOS SearchBarNode cancelButton: strings.Common_Cancel）
            Text(this.str("Common.Cancel", "Cancel"))
                .fontSize(15)
                .fontColor(0x317AFF)
                .margin(left: 8)
                .onClick({ evt =>
                    this.onClose()
                })
        }
        .width(100.percent)
        .height(44)
        .padding(left: 12, right: 12)
        .backgroundColor(0xFFFFFF)
        .alignItems(VerticalAlign.Center)

        // ==================== S354: 搜索结果列表 ====================
        // 对位 iOS ChatSearchResultsController：列出匹配消息，点击跳转。
        // 此前只有计数与 ▲▼ 逐条翻，搜到的 searchResults 从未渲染。
        // 列表限高并可滚动，避免长结果把消息区挤没。
        if (this.showResultsList && this.searchResults.size > 0) {
            Scroll {
                Column {
                    ForEach(this.searchResults, itemGenerator: { item: SearchResultItem, idx: Int64 =>
                        Column {
                            Row {
                                Text(item.senderName)
                                    .fontSize(14)
                                    .fontColor(0x000000)
                                    .layoutWeight(1)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                Text(item.date)
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                            }
                            .width(100.percent)

                            Text(item.text)
                                .fontSize(13)
                                .fontColor(0x3C3C43)
                                .width(100.percent)
                                .maxLines(2)
                                .textOverflow(TextOverflow.Ellipsis)
                                .margin(top: 2)
                        }
                        .width(100.percent)
                        .padding(left: 12, right: 12, top: 8, bottom: 8)
                        .backgroundColor(if (this.currentIndex == idx + 1) { 0xEAF2FF } else { 0xFFFFFF })
                        .onClick({ evt =>
                            this.jumpToResult(idx)
                        })
                    })
                }
                .width(100.percent)
            }
            .width(100.percent)
            .constraintSize(maxHeight: 320)
            .backgroundColor(0xFFFFFF)
        }
        }
        .width(100.percent)
    }
}

/**
 * 搜索结果项
 */
public class SearchResultItem {
    public var messageId: Int64 = 0
    public var text: String = ""
    public var senderName: String = ""
    public var date: String = ""

    public init(messageId!: Int64 = 0, text!: String = "", senderName!: String = "", date!: String = "") {
        this.messageId = messageId
        this.text = text
        this.senderName = senderName
        this.date = date
    }

    // S354: ForEach 的 item 需要 ToString（与 FileBrowser.FileEntryWrapper 同惯例）
    public func toString(): String {
        return "sr_${this.messageId}"
    }
}

// parseSearchResults 已被 RealMessageService.parseMessages() 替代 (Phase P0-2)
