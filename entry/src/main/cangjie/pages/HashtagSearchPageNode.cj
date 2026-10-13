package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.services.*

/**
 * HashtagSearchPageNode — 话题标签搜索结果列表节点
 *
 * 对应 iOS HashtagSearchControllerNode：渲染 hashtag 搜索结果消息列表。
 * 由 HashtagSearchPage 持有，自行持有 @State 数据，通过 @Consume hashtagQuery
 * 获取来自父组件 @Provide 的查询词。
 *
 * 调用链：
 *   aboutToAppear() / triggerSearchIfNeeded() →
 *   HashtagSearchService.searchHashtag(query) →
 *   getMTProtoClient().sendRequest(MessagesSearchGlobal.toBytes()) →
 *   MessagesHistoryResponse.deserialize() → messages 列表渲染
 */
@Component
public class HashtagSearchPageNode {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @Consume var hashtagQuery: String
    @State var messages: ArrayList<Message> = ArrayList<Message>()
    @State var isLoading: Bool = false
    @State var activeQuery: String = ""
    // S050: 作用域 tab。0 = 我的消息（searchGlobal 不带 broadcasts_only），
    // 1 = 公开帖子（broadcasts_only），对位 iOS HashtagSearchControllerNode 的
    // myChatContents(publicPosts:false) 与 globalChatContents(publicPosts:true)。
    //
    // iOS 的第三个作用域「本会话」只在 controller 持有 peer 时出现（即从聊天内
    // 点 #tag 进入）。本工程 HashtagSearchPage 目前只由 ChatListPage 全局搜索
    // 推入、不带 peer，且聊天气泡尚未做 hashtag 链接化，该入口不存在，故不渲染
    // 一个点不出结果的死 tab。补齐气泡 hashtag 点击后再加此 tab。
    @State var scopeIndex: Int64 = 0

    public override func aboutToAppear(): Unit {
        let q = this.hashtagQuery
        if (q.size > 0 && q != this.activeQuery) {
            this.activeQuery = q
            this.performSearch(q)
        }
    }

    /**
     * S050: 切换作用域后按当前查询词重搜。同一查询词换 scope 也要重搜，
     * 因此不走 activeQuery 去重。
     */
    private func switchScope(idx: Int64): Unit {
        if (this.scopeIndex == idx) { return }
        this.scopeIndex = idx
        let q = this.activeQuery
        if (q.size > 0) {
            this.performSearch(q)
        }
    }

    private func performSearch(q: String): Unit {
        if (q.isEmpty()) {
            launch {
                this.messages = ArrayList<Message>()
                this.isLoading = false
            }
            return
        }
        let qCopy = q
        // S050: 捕获发起时的 scope，避免请求在途时用户再切 tab 导致结果错配
        let scopeCopy = this.scopeIndex
        launch {
            this.isLoading = true
        }
        let _ = spawn {
            var msgs: ArrayList<Message> = ArrayList<Message>()
            try {
                let svc = getHashtagSearchService()
                let result = svc.searchHashtag(qCopy, limit: 20, publicPosts: scopeCopy == 1)
                msgs = result.messages
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[HashtagSearchPageNode] search error")
            }
            let finalMsgs = msgs
            launch {
                this.messages = finalMsgs
                this.isLoading = false
            }
        }
    }

    public func build() {
        Column {
            // ==================== S050: 作用域 tab ====================
            Row {
                this.scopeTab("My Messages", 0)
                this.scopeTab("Public Posts", 1)
            }
            .width(100.percent)
            .height(40)
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(40)
                        .height(40)
                        .color(0x0088CC)
                    Text(trSource("Searching..."))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 8)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.messages.isEmpty()) {
                if (this.activeQuery.size > 0) {
                    Column {
                        Text("No results for \"${this.activeQuery}\"")
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .padding(left: 32, right: 32)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    Column {
                        Text("Enter a hashtag to search")
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                }
            } else {
                List {
                    ForEach(this.messages.toArray(), itemGenerator: { msg: Message, _idx: Int64 =>
                        ListItem {
                            this.messageRow(msg)
                        }
                    })
                }
                .layoutWeight(1)
                .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 72, endMargin: 0))
            }
        }
        .width(100.percent)
        .height(100.percent)
    }

    @Builder
    private func scopeTab(title: String, idx: Int64) {
        Column {
            Text(title)
                .fontSize(15)
                .fontColor(if (this.scopeIndex == idx) { 0x0088CC } else { 0x8E8E93 })
                .fontWeight(if (this.scopeIndex == idx) { FontWeight.Medium } else { FontWeight.Normal })
                .layoutWeight(1)
                .textAlign(TextAlign.Center)

            Divider()
                .strokeWidth(2)
                .color(if (this.scopeIndex == idx) { 0x0088CC } else { Color.Transparent })
        }
        .layoutWeight(1)
        .height(40)
        .onClick({ evt =>
            this.switchScope(idx)
        })
    }

    @Builder
    private func messageRow(msg: Message) {
        Row {
            Text(this.getAvatarText(msg.senderName))
                .width(48)
                .height(48)
                .borderRadius(24)
                .backgroundColor(0x317AFF)
                .fontColor(0xFFFFFF)
                .fontSize(18)
                .textAlign(TextAlign.Center)
                .margin(left: 12, right: 12)

            Column {
                Row {
                    Text(msg.senderName)
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0x000000)
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)

                    Text(msg.time)
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 8)
                }
                .width(100.percent)
                .margin(bottom: 4)

                Text(this.getMessagePreview(msg))
                    .fontSize(14)
                    .fontColor(0x3C3C43)
                    .maxLines(2)
                    .textOverflow(TextOverflow.Ellipsis)
            }
            .layoutWeight(1)
            .padding(right: 12)
            .alignItems(HorizontalAlign.Start)
        }
        .width(100.percent)
        .height(72)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(0xFFFFFF)
    }

    private func getAvatarText(name: String): String {
        if (name.isEmpty()) {
            return "?"
        }
        let runes = name.toRuneArray()
        return runes[0].toString()
    }

    private func getMessagePreview(msg: Message): String {
        if (msg.content.size > 0) {
            return msg.content
        }
        if (msg.mediaDescription.size > 0) {
            return msg.mediaDescription
        }
        if (msg.messageType == "photo") { return "[Photo]" }
        if (msg.messageType == "video") { return "[Video]" }
        if (msg.messageType == "voice") { return "[Voice]" }
        if (msg.messageType == "document") { return "[File]" }
        return "[Message]"
    }
}
