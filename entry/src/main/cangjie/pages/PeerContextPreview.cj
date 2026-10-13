package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.components.{MessageBubble, Avatar, ContextMenuItem}
import ohos_app_cangjie_entry.core.storage.getChatBgDisplayPath
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.utils.safeAnimateTo

/**
 * PeerContextPreview — 长按某个 peer 弹出的上下文浮层（对位 iOS ContextController 的
 * 预览形态）：模糊遮罩 + 只读的会话预览卡 + 锚在卡片下方的动作面板，从被按行处弹簧展开。
 * 与 Chats 页长按会话的效果一致，供通讯录等列表页复用；动作项由调用方传入。
 */
private let PREVIEW_ACTION_ROW_HEIGHT: Float64 = 44.0
private let PREVIEW_ACTION_PANEL_WIDTH: Float64 = 240.0
private let PREVIEW_BOTTOM_INSET: Float64 = 34.0

private func previewRowKey(msg: Message): String {
    return "${msg.identityKey()}_${msg.content}_${msg.status}_${msg.photoLocalPath}_${msg.documentLocalPath}_${msg.documentThumbnailPath}"
}

@Component
public class PeerContextPreview {
    public var chatId: Int64 = 0
    public var chatName: String = ""
    public var peerType: String = "user"
    public var avatarUrl: String = ""
    public var subtitle: String = ""
    public var sourceY: Float64 = 0.0
    public var sourceHeight: Float64 = 0.0
    public var items: Array<ContextMenuItem> = Array<ContextMenuItem>()
    public var onDismiss: () -> Unit = { => }
    public var onOpen: () -> Unit = { => }

    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var messages: ArrayList<Message> = ArrayList<Message>()
    @State var panelScale: Float32 = 0.01
    @State var presented: Bool = false
    @State var offsetY: Float64 = 0.0
    @State var highlightIndex: Int64 = -1
    @State var overlayWidth: Float64 = 0.0
    @State var overlayHeight: Float64 = 0.0

    private let previewVM = ChatRoomViewModel()
    private let scroller = Scroller()
    private var renderKey: String = ""

    public override func aboutToAppear(): Unit {
        this.previewVM.setMessagesChangedHandler({ => this.publishMessages() })
        this.previewVM.initPreview(this.chatId, this.chatName, this.peerType)
        this.tintSystemBars(true)
        let chatIdAtOpen = this.chatId
        let _ = spawn {
            sleep(Duration.millisecond * 120)
            launch {
                if (this.chatId == chatIdAtOpen) {
                    try { this.scroller.scrollEdge(Edge.Bottom) } catch (_e: Exception) {}
                }
            }
        }
    }

    public override func aboutToDisappear(): Unit {
        this.previewVM.cleanupPreview()
        this.tintSystemBars(false)
    }

    private func publishMessages(): Unit {
        let list = this.previewVM.messageList
        computeMessageGroupPositions(list)
        var key = ""
        for (m in list) { key = key + previewRowKey(m) + "|" }
        if (key == this.renderKey) { return }
        this.renderKey = key
        launch {
            this.messages = list
            let _ = spawn {
                sleep(Duration.millisecond * 60)
                launch { try { this.scroller.scrollEdge(Edge.Bottom) } catch (_e: Exception) {} }
            }
        }
    }

    /** 状态栏 / 导航栏在浮层期间染成遮罩同色（窗口布局模式保持不变） */
    private func tintSystemBars(active: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                let color = if (active) { "#FFCCCED3" } else { "#FFFFFFFF" }
                let _ = spawn {
                    try {
                        let win = getLastWindow(ctx)
                        win.setWindowSystemBarProperties(
                            SystemBarProperties(
                                statusBarColor: color,
                                statusBarContentColor: "#FF000000",
                                navigationBarColor: color,
                                navigationBarContentColor: "#FF000000"
                            )
                        )
                    } catch (_: Exception) {
                        Hilog.warn(0, "CjTelegram", "[PeerContextPreview] system bar tint failed (non-fatal)")
                    }
                }
            case None => ()
        }
    }

    // ---- 几何：卡片宽 = 浮层宽 - 24；卡片 + 面板整体在浮层内垂直居中 ----
    private func panelHeight(): Float64 {
        var h = 0.0
        for (it in this.items) { h += if (it.isSeparator) { 8.0 } else { PREVIEW_ACTION_ROW_HEIGHT + 1.0 } }
        return h
    }

    private func previewWidth(): Float64 {
        if (this.overlayWidth <= 24.0) { return 320.0 }
        return this.overlayWidth - 24.0
    }

    private func previewHeight(): Float64 {
        if (this.overlayHeight <= 0.0) { return 360.0 }
        let available = (this.overlayHeight - PREVIEW_BOTTOM_INSET) - 48.0 - this.panelHeight() - 10.0
        if (available < 160.0) { return 160.0 }
        if (available > 460.0) { return 460.0 }
        return available
    }

    private func previewY(): Float64 {
        let total = this.previewHeight() + 10.0 + this.panelHeight()
        let usableBottom = this.overlayHeight - PREVIEW_BOTTOM_INSET
        var top = (usableBottom - total) / 2.0
        let maxTop = usableBottom - 24.0 - total
        if (top > maxTop) { top = maxTop }
        if (top < 24.0) { return 24.0 }
        return top
    }

    private func panelX(): Float64 {
        let x = 12.0 + this.previewWidth() - PREVIEW_ACTION_PANEL_WIDTH
        if (x < 12.0) { return 12.0 }
        return x
    }

    private func panelY(): Float64 {
        return this.previewY() + this.previewHeight() + 10.0
    }

    private func present(): Unit {
        this.offsetY = (this.sourceY + this.sourceHeight / 2.0) - (this.previewY() + this.previewHeight() / 2.0)
        safeAnimateTo(
            { => this.getUIContext() },
            AnimateParam(duration: 420, curve: Curve.Friction),
            { =>
                this.panelScale = 1.0
                this.presented = true
                this.offsetY = 0.0
            }
        )
    }

    private func wallpaperUri(): String {
        let path = getChatBgDisplayPath()
        if (path.startsWith("file://")) { return path }
        if (path.size > 0) { return "file://${path}" }
        return ""
    }

    private func itemColor(item: ContextMenuItem): UInt32 {
        if (!item.enabled) { return 0xFFC7C7CC }
        if (item.destructive) { return 0xFFFF3B30 }
        return this.presentation.textColor
    }

    private func runItem(index: Int64): Unit {
        if (index < 0 || index >= this.items.size) { return }
        let item = this.items[index]
        if (item.isSeparator || !item.enabled) { return }
        item.onClick()
    }

    @Builder
    func previewCard() {
        Stack(alignContent: Alignment.TopStart) {
            Image(this.wallpaperUri())
                .width(100.percent)
                .height(100.percent)
                .objectFit(ImageFit.Cover)
            Column {
                Row {
                    Column {
                        Text(this.chatName)
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(this.presentation.textColor)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                        if (this.subtitle.size > 0) {
                            Text(this.subtitle)
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .maxLines(1)
                                .margin(top: 1)
                        }
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Center)
                    Avatar(avatarUrl: this.avatarUrl, displayName: this.chatName, avatarSize: 32, peerId: this.chatId)
                }
                .width(100.percent)
                .height(52)
                .padding(left: 12, right: 12)
                .alignItems(VerticalAlign.Center)
                .backgroundColor(this.presentation.backgroundColor)

                List(scroller: this.scroller) {
                    ForEach(this.messages.toArray(), itemGenerator: { msg: Message, _i: Int64 =>
                        ListItem {
                            MessageBubble(message: msg, voicePlaybackEpoch: 0, peerType: this.peerType, isMultiSelectMode: true)
                        }
                    }, keyGenerator: { msg: Message, _idx: Int64 => previewRowKey(msg) })
                }
                .width(100.percent)
                .layoutWeight(1)
                .scrollBar(BarState.Off)
                .edgeEffect(EdgeEffect.Spring)
            }
            .width(100.percent)
            .height(100.percent)
        }
        .width(this.previewWidth())
        .height(this.previewHeight())
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(30)
        .clip(true)
        .position(x: 12.0, y: this.previewY())
        .translate(y: this.offsetY)
        .scale(x: this.panelScale, y: this.panelScale)
        .opacity(if (this.presented) { 1.0 } else { 0.0 })
        .onClick({ _evt => this.onOpen() })
    }

    @Builder
    func actionPanel() {
        Column {
            ForEach(this.items, itemGenerator: { item: ContextMenuItem, index: Int64 =>
                Column {
                    if (item.isSeparator) {
                        Row {}
                            .width(100.percent)
                            .height(8)
                            .backgroundColor(this.presentation.dividerColor)
                    } else {
                        Row {
                            if (item.iconRes.isSome()) {
                                Image(item.iconRes.getOrThrow())
                                    .width(20)
                                    .height(20)
                                    .fillColor(this.itemColor(item))
                                    .margin(left: 16)
                            }
                            Text(item.title)
                                .fontSize(17)
                                .fontColor(this.itemColor(item))
                                .margin(left: if (item.iconRes.isSome()) { 12 } else { 16 })
                            Blank().layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(PREVIEW_ACTION_ROW_HEIGHT)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(if (this.highlightIndex == index) { this.presentation.itemHighlightedBackgroundColor } else { this.presentation.cardColor })
                        .onTouch({ evt =>
                            match (evt.eventType) {
                                case TouchType.Down => this.highlightIndex = index
                                case TouchType.Up =>
                                    this.highlightIndex = -1
                                    this.runItem(index)
                                case _ => this.highlightIndex = -1
                            }
                        })
                        if (index < this.items.size - 1 && !this.items[index + 1].isSeparator) {
                            Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 48)
                        }
                    }
                }
            })
        }
        .width(PREVIEW_ACTION_PANEL_WIDTH)
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(14)
        .clip(true)
        .position(x: this.panelX(), y: this.panelY())
        .scale(x: this.panelScale, y: this.panelScale)
        .opacity(if (this.presented) { 1.0 } else { 0.0 })
    }

    func build() {
        Stack(alignContent: Alignment.TopStart) {
            // iOS contextMenu.dimColor #000a26 @20% + 模糊
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backdropBlur(22.0)
                .backgroundColor(0x33000A26)
                .onClick({ _evt => this.onDismiss() })
            this.previewCard()
            this.actionPanel()
        }
        .width(100.percent)
        .height(100.percent)
        .position(x: 0, y: 0)
        .onAreaChange({ _: Area, newArea: Area =>
            let first = this.overlayHeight <= 0.0
            this.overlayWidth = newArea.width.value
            this.overlayHeight = newArea.height.value
            if (first) { this.present() }
        })
    }
}
