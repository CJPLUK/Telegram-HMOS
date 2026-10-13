package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*

/**
 * InlineBotResultPanelComponent — 内联 Bot 结果面板
 *
 * P2-038: 对应 iOS HorizontalListContextResultsChatInputContextPanelNode /
 *         VerticalListContextResultsChatInputContextPanelNode
 *
 * 功能：
 *   - 横向媒体网格（photo/gif/sticker）：List + listDirection(Axis.Horizontal)
 *   - 纵向结果列表（article/contact/location/venue/audio/voice/document/game）
 *   - switch-PM 按钮（来自 BotResults flags.2?InlineBotSwitchPM）
 *   - webview 按钮接线点（P2-029 负责实现，此处仅标注）
 *   - 选中结果后通过 onSelectResult 回调传出 (queryId, resultId, peerId, peerAccessHash)
 *
 * 调用链:
 *   用户点击候选项
 *     → onSelectResult(queryId, resultId, peerId, peerAccessHash)
 *         → 调用方在 ChatRoomPage.onInlineBotResultSelected()
 *             → spawn { WebSearchService.sendSelectedResult(queryId, resultId, peerId, peerAccessHash) }
 *                 → getMTProtoClient().sendRequest(MessagesSendInlineBotResult#c0cf7646)
 *
 * 布局规则（对应 iOS 面板行为）:
 *   - isGallery=true（photo/gif）→ 横向 List，高度 80-100dp，方形缩略图
 *   - isGallery=false（article 等）→ 纵向 List，高度 ≤200dp，每项含 title+description
 *   - switch-PM 按钮置于顶部（与 iOS 一致）
 *
 * 路由名: 无（内嵌组件，非独立页面）
 *
 * S-001 compliance: 状态写在 onSelectResult 回调（由 ChatRoomPage 自己的 @State 处理），此组件无 @State 写
 */
@Component
public class InlineBotResultPanelComponent {
    @Consume var pageStack: NavPathStack

    // 注入数据 — 由 ChatRoomPage 持有 ChatContextQueryViewModel 后传入
    // 遵循 S-015: 跨包组件 @State 不能跨包 init，因此用 var 字段而非 @State
    var queryResults: ArrayList<ContextQueryResultItem> = ArrayList<ContextQueryResultItem>()
    var isGallery: Bool = false
    var switchPmText: String = ""
    var switchPmStartParam: String = ""
    var switchWebviewText: String = ""
    var switchWebviewUrl: String = ""
    var queryId: Int64 = 0
    var peerId: Int64 = 0
    var peerAccessHash: Int64 = 0

    // 回调 — 用户选中一条结果时触发
    var onSelectResult: (Int64, String, Int64, Int64) -> Unit = { _, _, _, _ => }
    // switch-PM 按钮点击回调：(botUsername, startParam)
    var onSwitchPm: (String, String) -> Unit = { _, _ => }
    // switch-webview 按钮回调（P2-029 接线点），仅记录点击
    var onSwitchWebview: (String, String) -> Unit = { _, _ => }

    public func build() {
        Column {
            // switch-PM 按钮（若有）：置顶，用户点击后跳转到 bot DM
            if (this.switchPmText.size > 0) {
                Row {
                    Text(this.switchPmText)
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .layoutWeight(1)
                        .maxLines(1)
                    Text(">")
                        .fontSize(14)
                        .fontColor(0x317AFF)
                }
                .width(100.percent)
                .height(44)
                .padding(left: 16, right: 12)
                .backgroundColor(0xF7F7F7)
                .alignItems(VerticalAlign.Center)
                .onClick({ _evt =>
                    this.onSwitchPm(this.switchPmText, this.switchPmStartParam)
                })

                Divider().color(0xE5E5EA).strokeWidth(0.5)
            }

            // switch-webview 按钮（P2-029 接线点，只有 switchWebviewText 非空时显示）
            if (this.switchWebviewText.size > 0) {
                Row {
                    Text(this.switchWebviewText)
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .layoutWeight(1)
                        .maxLines(1)
                    Text("[webview:P2-029]")
                        .fontSize(11)
                        .fontColor(0xAAAAAA)
                }
                .width(100.percent)
                .height(44)
                .padding(left: 16, right: 12)
                .backgroundColor(0xF7F7F7)
                .alignItems(VerticalAlign.Center)
                .onClick({ _evt =>
                    this.onSwitchWebview(this.switchWebviewText, this.switchWebviewUrl)
                })

                Divider().color(0xE5E5EA).strokeWidth(0.5)
            }

            // 结果列表
            if (this.isGallery) {
                // 横向媒体网格（photo/gif/sticker）
                // iOS: HorizontalListContextResultsChatInputContextPanelNode
                // 使用 List + listDirection(Axis.Horizontal) 实现水平滚动媒体网格
                List(space: 4) {
                    ForEach(
                        this.queryResults,
                        itemGenerator: { item: ContextQueryResultItem, _idx: Int64 =>
                            ListItem {
                                Column {
                                    if (item.inlineThumbnailUrl.size > 0) {
                                        // 缩略图占位区（无网络图片加载，显示类型标签）
                                        Column {
                                            Text(this.resultTypeLabel(item.inlineResultType))
                                                .fontSize(11)
                                                .fontColor(0x8E8E93)
                                        }
                                        .width(80)
                                        .height(80)
                                        .backgroundColor(0xE5E5EA)
                                        .borderRadius(6)
                                        .justifyContent(FlexAlign.Center)
                                        .alignItems(HorizontalAlign.Center)
                                    } else {
                                        Column {
                                            Text(this.resultTypeLabel(item.inlineResultType))
                                                .fontSize(11)
                                                .fontColor(0x8E8E93)
                                        }
                                        .width(80)
                                        .height(80)
                                        .backgroundColor(0xE5E5EA)
                                        .borderRadius(6)
                                        .justifyContent(FlexAlign.Center)
                                        .alignItems(HorizontalAlign.Center)
                                    }
                                    if (item.inlineTitle.size > 0) {
                                        Text(item.inlineTitle)
                                            .fontSize(10)
                                            .fontColor(0x555555)
                                            .maxLines(1)
                                            .width(80)
                                            .margin(top: 2)
                                    }
                                }
                                .alignItems(HorizontalAlign.Center)
                                .onClick({ _evt =>
                                    let capturedQueryId = this.queryId
                                    let capturedResultId = item.resultId
                                    let capturedPeerId = this.peerId
                                    let capturedPeerHash = this.peerAccessHash
                                    this.onSelectResult(capturedQueryId, capturedResultId, capturedPeerId, capturedPeerHash)
                                })
                            }
                        }
                    )
                }
                .listDirection(Axis.Horizontal)
                .height(104)
                .width(100.percent)
                .padding(left: 8, right: 8, top: 8, bottom: 8)
                .scrollBar(BarState.Off)
            } else {
                // 纵向结果列表（article/contact/location/venue/game/document）
                // iOS: VerticalListContextResultsChatInputContextPanelNode
                List {
                    ForEach(
                        this.queryResults,
                        itemGenerator: { item: ContextQueryResultItem, _idx: Int64 =>
                            ListItem {
                                Row {
                                    // 类型图标占位（纯色方块 + type 首字母）
                                    Column {
                                        Text(this.resultTypeIcon(item.inlineResultType))
                                            .fontSize(16)
                                    }
                                    .width(40)
                                    .height(40)
                                    .backgroundColor(0xE8F4FF)
                                    .borderRadius(8)
                                    .justifyContent(FlexAlign.Center)
                                    .alignItems(HorizontalAlign.Center)
                                    .margin(right: 12)

                                    Column {
                                        Text(if (item.inlineTitle.size > 0) { item.inlineTitle } else { item.inlineSendText })
                                            .fontSize(15)
                                            .fontColor(0x000000)
                                            .maxLines(1)
                                        if (item.inlineDescription.size > 0) {
                                            Text(item.inlineDescription)
                                                .fontSize(12)
                                                .fontColor(0x8E8E93)
                                                .maxLines(2)
                                                .margin(top: 2)
                                        }
                                    }
                                    .alignItems(HorizontalAlign.Start)
                                    .layoutWeight(1)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 8, bottom: 8)
                                .alignItems(VerticalAlign.Center)
                                .onClick({ _evt =>
                                    let capturedQueryId = this.queryId
                                    let capturedResultId = item.resultId
                                    let capturedPeerId = this.peerId
                                    let capturedPeerHash = this.peerAccessHash
                                    this.onSelectResult(capturedQueryId, capturedResultId, capturedPeerId, capturedPeerHash)
                                })
                            }
                        }
                    )
                }
                .width(100.percent)
                .height(200)
                .scrollBar(BarState.Off)
                .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xE5E5EA))
            }
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFF)
        .borderWidth(1)
        .borderColor(0xE5E5EA)
    }

    /**
     * 返回结果类型的简短标签（用于缩略图占位显示）
     * type 字段对应 TL BotInlineResult.type (string)
     */
    private func resultTypeLabel(t: String): String {
        if (t == "photo") { return "Photo" }
        if (t == "gif") { return "GIF" }
        if (t == "video") { return "Video" }
        if (t == "audio") { return "Audio" }
        if (t == "voice") { return "Voice" }
        if (t == "document") { return "File" }
        if (t == "sticker") { return "Sticker" }
        if (t == "location") { return "Map" }
        if (t == "venue") { return "Venue" }
        if (t == "contact") { return "Contact" }
        if (t == "game") { return "Game" }
        if (t == "article") { return "Article" }
        return "Media"
    }

    /**
     * 返回结果类型的 emoji 图标（纵向列表使用）
     */
    private func resultTypeIcon(t: String): String {
        if (t == "photo") { return "P" }
        if (t == "gif") { return "G" }
        if (t == "video") { return "V" }
        if (t == "audio") { return "A" }
        if (t == "voice") { return "V" }
        if (t == "document") { return "F" }
        if (t == "sticker") { return "S" }
        if (t == "location") { return "M" }
        if (t == "venue") { return "V" }
        if (t == "contact") { return "C" }
        if (t == "game") { return "G" }
        if (t == "article") { return "A" }
        return "?"
    }
}
