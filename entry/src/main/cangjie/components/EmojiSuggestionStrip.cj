package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import ohos.i18n.System as I18nSystem
import ohos_app_cangjie_entry.services.{getStickersService, EmojiKeywordEntry, StickerItem}
import std.collection.ArrayList
import std.time.*

/**
 * 输入 `:关键词` 时的 Emoji 候选条。
 *
 * iOS 对应 `EmojiSuggestionsComponent`：在输入框上方浮出一排候选，
 * 选中后把 `:关键词` 这一段替换成对应的 Emoji。
 *
 * 数据源就是 EmojiPicker 已经在用的那套 `messages.getEmojiKeywords` 索引
 * （先读磁盘缓存出首帧、再增量同步），所以不额外增加网络往返；
 * 自定义表情候选走 `messages.searchCustomEmoji`。
 */
@Component
public class EmojiSuggestionStrip {
    /** `:` 之后的关键词（不含冒号）。 */
    public var query: String = ""
    /** 选中静态 Emoji。 */
    public var onSelectEmoji: (String) -> Unit = { _e: String => }
    /** 选中自定义表情。 */
    public var onSelectCustomEmoji: (StickerItem) -> Unit = { _i: StickerItem => }

    @State var matches: Array<String> = Array<String>(0, repeat: "")
    @State var customMatches: Array<StickerItem> =
        Array<StickerItem>(0, repeat: StickerItem())
    /**
     * 自定义候选必须限量。searchCustomEmoji 对一串 emoticon 会返回上百条
     * （实测 `:smi` → 200 条），全铺出来会把静态候选挤到屏幕外几千像素，
     * 看起来就像"静态候选没渲染"。iOS 的建议条同样是短列表。
     */
    private let customLimit: Int64 = 12
    private var keywords: ArrayList<EmojiKeywordEntry> = ArrayList<EmojiKeywordEntry>()
    private var keywordsLoaded: Bool = false
    private var lastQuery: String = ""
    private var generation: Int64 = 0

    protected override func aboutToAppear(): Unit {
        this.loadKeywords()
        this.refresh()
    }

    protected override func aboutToDisappear(): Unit {
        this.generation = this.generation + 1
    }

    private func currentLanguage(): String {
        try {
            let value = I18nSystem.getAppPreferredLanguage().toAsciiLower()
            if (!value.isEmpty()) { return value }
        } catch (_e: Exception) {}
        return "en"
    }

    /** 与 EmojiPicker 一致：磁盘缓存先出，网络同步随后补齐，不阻塞首帧。 */
    private func loadKeywords(): Unit {
        if (this.keywordsLoaded) { return }
        this.keywordsLoaded = true
        let language = this.currentLanguage()
        let _ = spawn {
            let service = getStickersService()
            let combined = ArrayList<EmojiKeywordEntry>()
            let cached = service.getCachedEmojiKeywords(language)
            if (cached.success) {
                for (entry in cached.keywords) { combined.add(entry) }
            }
            if (!language.startsWith("en")) {
                let english = service.getCachedEmojiKeywords("en")
                if (english.success) {
                    for (entry in english.keywords) { combined.add(entry) }
                }
            }
            launch {
                this.keywords = combined
                this.lastQuery = ""
                this.refresh()
            }
        }
    }

    private func refresh(): Unit {
        if (this.query == this.lastQuery) { return }
        this.lastQuery = this.query
        this.generation = this.generation + 1
        let token = this.generation
        if (this.query.size < 2) {
            this.matches = Array<String>(0, repeat: "")
            this.customMatches = Array<StickerItem>(0, repeat: StickerItem())
            return
        }
        let staticHits = this.matchStatic(this.query)
        this.matches = staticHits
        let joined = this.joinedForCustomSearch(staticHits)
        Hilog.info(0, "CjTelegram",
            "[EmojiSuggest] q=${this.query} keywords=${this.keywords.size} static=${staticHits.size}")
        if (joined.isEmpty()) {
            this.customMatches = Array<StickerItem>(0, repeat: StickerItem())
            return
        }
        let _ = spawn {
            sleep(Duration.millisecond * 240)
            if (this.generation != token) { return }
            let raw = getStickersService().searchCustomEmoji(joined).documents
            let capped = ArrayList<StickerItem>()
            for (item in raw) {
                if (capped.size >= this.customLimit) { break }
                capped.add(item)
            }
            let items = capped.toArray()
            launch {
                if (this.generation == token) {
                    this.customMatches = items
                }
            }
        }
    }

    /** 关键词前缀匹配，最多 24 个；前缀命中排在包含命中之前。 */
    private func matchStatic(value: String): Array<String> {
        let normalized = value.toAsciiLower()
        let prefixHits = ArrayList<String>()
        let containsHits = ArrayList<String>()
        for (entry in this.keywords) {
            if (entry.isDeleted) { continue }
            let keyword = entry.keyword.toAsciiLower()
            if (keyword.startsWith(normalized)) {
                for (emoji in entry.emoticons) { addUnique(prefixHits, emoji, 24) }
            } else if (keyword.contains(normalized)) {
                for (emoji in entry.emoticons) { addUnique(containsHits, emoji, 24) }
            }
        }
        let result = ArrayList<String>()
        for (emoji in prefixHits) { addUnique(result, emoji, 24) }
        for (emoji in containsHits) { addUnique(result, emoji, 24) }
        return result.toArray()
    }

    /** searchCustomEmoji 接收的是 emoticon 串，不是自然语言（与 EmojiPicker 同一约束）。 */
    private func joinedForCustomSearch(values: Array<String>): String {
        var result = ""
        for (emoji in values) {
            if (result.size < 96) { result = result + emoji }
        }
        return result
    }

    public func build() {
        Column {
            if (!this.matches.isEmpty() || !this.customMatches.isEmpty()) {
                Scroll {
                    Row {
                        // 静态候选是直接命中关键词的结果，排在前面；
                        // 自定义表情是拿这些 emoticon 二次搜出来的，排在后面。
                        ForEach(this.matches, itemGenerator: { emoji: String, _idx: Int64 =>
                            this.buildCandidate(emoji)
                        })
                        ForEach(this.customMatches,
                            itemGenerator: { item: StickerItem, _idx: Int64 =>
                                this.buildCustomCandidate(item)
                            })
                    }
                    .padding(left: 10, right: 10)
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width(100.percent)
                .height(50)
                .backgroundColor(0xF2F2F7)
            }
        }
        .width(100.percent)
        .onAreaChange({ _: Area, _n: Area => this.refresh() })
    }

    @Builder
    func buildCandidate(emoji: String) {
        Text(emoji)
            .fontSize(26)
            .width(42)
            .height(42)
            .textAlign(TextAlign.Center)
            .onClick({ _evt => this.onSelectEmoji(emoji) })
    }

    @Builder
    func buildCustomCandidate(item: StickerItem) {
        Column {
            CustomEmojiImage(
                documentId: item.documentId,
                size: 30.0,
                placeholder: "",
                animationEpoch: -1
            )
        }
        .width(42)
        .height(42)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.onSelectCustomEmoji(item) })
    }
}

private func addUnique(list: ArrayList<String>, value: String, limit: Int64): Unit {
    if (value.isEmpty() || list.size >= limit) { return }
    for (existing in list) {
        if (existing == value) { return }
    }
    list.add(value)
}
