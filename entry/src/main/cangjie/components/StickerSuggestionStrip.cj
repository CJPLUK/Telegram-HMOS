package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.{getStickersService, StickerItem}
import std.collection.ArrayList
import std.time.*

/**
 * 「按 Emoji 建议贴纸」——输入框里只打了一个 emoji 时，输入栏上方浮出匹配的贴纸条。
 *
 * iOS 对应 ChatTextInputPanelNode 的 stickersNode：设置里那条
 * `Suggest Stickers by Emoji`（我们已有开关且已持久化，但此前没有任何消费方）
 * 打开时，输入内容是单个 emoji 就用 `messages.getStickers(emoticon)` 拉建议。
 *
 * 触发条件与 iOS 一致：**整个输入框只有一个 emoji**（不是「以 emoji 结尾」），
 * 否则正常打字时会不断弹条打断输入。
 */
@Component
public class StickerSuggestionStrip {
    /** 当前输入框内容，由父级传入；变化时重新查询。 */
    public var query: String = ""
    public var onSelectSticker: (StickerItem) -> Unit = { _s: StickerItem => }

    @State var suggestionCount: Int64 = 0
    // 虚拟化数据源；条数由它持有，@State 只留一个计数用于触发重建。
    private let source: StickerItemSource = StickerItemSource()
    private var requestGeneration: Int64 = 0
    private var lastQuery: String = ""

    protected override func aboutToAppear(): Unit {
        this.refresh()
    }

    protected override func aboutToDisappear(): Unit {
        this.requestGeneration = this.requestGeneration + 1
    }

    /**
     * 父级每帧都可能重建本组件（输入框是 @State），所以要自己去重：
     * query 没变就不再发请求，否则每敲一下键盘就是一次 RPC。
     */
    private func refresh(): Unit {
        if (this.query == this.lastQuery) { return }
        this.lastQuery = this.query
        this.requestGeneration = this.requestGeneration + 1
        let token = this.requestGeneration
        let emoticon = this.query
        if (emoticon.isEmpty()) {
            this.source.setItems(Array<StickerItem>(0, repeat: StickerItem()))
            this.suggestionCount = 0
            return
        }
        let _ = spawn {
            // 与 iOS 一样先给输入一点安定时间，别在连续敲击时发请求
            sleep(Duration.millisecond * 220)
            if (this.requestGeneration != token) { return }
            let items = getStickersService().getStickers(emoticon).stickers.toArray()
            launch {
                if (this.requestGeneration == token) {
                    this.source.setItems(items)
                    this.suggestionCount = Int64(items.size)
                }
            }
        }
    }

    public func build() {
        Column {
            if (this.suggestionCount > 0) {
                List {
                    LazyForEach(
                        this.source,
                        itemGenerator: { item: StickerItem, _idx: Int64 =>
                            ListItem {
                                this.buildSuggestion(item)
                            }
                        },
                        keyGenerator: { item: StickerItem, idx: Int64 =>
                            "sugg_${item.documentId}_${idx}"
                        }
                    )
                }
                .listDirection(Axis.Horizontal)
                // iOS GridNode 的 preloadSize 是 100pt，约 1.5 个 66pt 格子
                .cachedCount(2)
                .scrollBar(BarState.Off)
                .padding(left: 10, right: 10)
                .width(100.percent)
                .height(84)
                .backgroundColor(0xF2F2F7)
            }
        }
        .width(100.percent)
        .onAreaChange({ _: Area, _n: Area => this.refresh() })
    }

    @Builder
    func buildSuggestion(item: StickerItem) {
        Column {
            StickerGridCell(
                item: item,
                size: 68.0,
                onTap: { picked: StickerItem => this.onSelectSticker(picked) }
            )
        }
        .width(76)
        .height(76)
        .margin(right: 4)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }
}
