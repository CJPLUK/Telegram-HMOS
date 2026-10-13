package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.components.SearchBar
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * HashtagSearchPage — 话题标签搜索页 (hashtag_search)
 *
 * 对应 iOS HashtagSearchController：点击 #tag 后显示含该标签的消息列表页面。
 *
 * 功能:
 * - NavDestination 根容器（D-002）
 * - 从路由参数（onReady）提取 hashtag 查询词，自动触发搜索
 * - 顶部搜索栏可修改查询词（支持重新搜索）
 * - 通过 @Provide hashtagQuery 向内嵌的 HashtagSearchPageNode 传递查询词
 *
 * TL 调用链（由 HashtagSearchPageNode 发起）：
 *   hashtagQuery 变化 →
 *   HashtagSearchService.searchHashtag(query) →
 *   getMTProtoClient().sendRequest(MessagesSearchGlobal.toBytes()) →
 *   MessagesHistoryResponse.deserialize() → 消息列表渲染
 */
@HybridComponentEntry
@Component
public class HashtagSearchPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @Provide var hashtagQuery: String = ""
    @State var inputText: String = ""
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // 混合迁移：原 onReady 经 NavDestination param 取查询词，改为 takePending。
        let raw = takePending("HashtagSearchPage")
        if (raw.size > 0 && raw != "{}") {
            this.inputText = raw
            this.hashtagQuery = raw
            Hilog.info(0, "CjTelegram", "[HashtagSearchPage] ensureLoaded param='${raw}'")
        }
    }

    private func applySearch(): Unit {
        let q = this.inputText
        this.hashtagQuery = q
        Hilog.info(0, "CjTelegram", "[HashtagSearchPage] applySearch q='${q}'")
    }

    public func build() {
        Column {
                // 顶部导航栏
                Row {
                    Text("< Back")
                        .fontSize(17)
                        .fontColor(0x0088CC)
                        .padding(right: 8)
                        .onClick({ evt =>
                            routerPop()
                        })

                    Blank()

                    Text(if (this.hashtagQuery.size > 0) { this.hashtagQuery } else { "Hashtag Search" })
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)

                    Blank()

                    Text(trSource(""))
                        .width(60)
                }
                .width(100.percent)
                .height(56.0 + getSafeAreaTop())
                .padding(left: 12, right: 12, top: getSafeAreaTop())
                .backgroundColor(0xFFFFFF)
                .alignItems(VerticalAlign.Center)

                // 搜索输入框（SearchBar 原子，P2-RETRO-search-a）
                // SearchBar 是 @Component，不能直接链内置属性，外包 Column 容器。
                Column {
                    SearchBar(
                        loading: false,
                        backArrow: false,
                        text: this.inputText,
                        hint: "Search hashtag...",
                        onChange: { value: String =>
                            this.inputText = value
                        },
                        onSubmit: { _kw: String =>
                            this.applySearch()
                        },
                        showCancel: false
                    )
                }
                .width(100.percent)
                .margin(bottom: 2)

                // 搜索结果节点
                HashtagSearchPageNode()
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
