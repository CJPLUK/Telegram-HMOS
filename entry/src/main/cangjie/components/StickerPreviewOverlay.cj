package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{StickerItem, ensureStickerLocalFile}

/**
 * S2-37：贴纸面板把长按预览交给页面根叠加层呈现时的请求包（iOS PeekController 是
 * 由 ChatController 以全屏覆盖层 present 的，而不是贴纸键盘的子节点）。面板只负责
 * 决定"预览什么、菜单有哪些项、各项做什么"，呈现位置由宿主决定。
 */
public class StickerPreviewRequest {
    public var sticker: StickerItem = StickerItem()
    public var isFavorite: Bool = false
    public var isRecent: Bool = false
    public var canSendSilently: Bool = true
    public var onSend: (StickerItem) -> Unit = { _item: StickerItem => }
    public var onSendSilently: (StickerItem) -> Unit = { _item: StickerItem => }
    public var onSchedule: (StickerItem) -> Unit = { _item: StickerItem => }
    public var onFavorite: (StickerItem, Bool) -> Unit = { _item: StickerItem, _remove: Bool => }
    public var onViewPack: (StickerItem) -> Unit = { _item: StickerItem => }
    public var onRemoveFromRecents: (StickerItem) -> Unit = { _item: StickerItem => }
    public var onClose: () -> Unit = { => }

    public init() {}
}

/** 贴纸与菜单的间距（iOS 64，本侧屏矮按 16）与覆盖层上下留白（vp）。 */
let STICKER_PREVIEW_MENU_SPACING_VP: Float64 = 16.0
let STICKER_PREVIEW_VERTICAL_MARGIN_VP: Float64 = 12.0

/**
 * iOS StickerPreviewPeekContent 的轻量同构层：真实静态/动画资源预览，以及发送、
 * 收藏、查看包操作。遮罩覆盖宿主给的整个区域，单击空白区关闭。
 *
 * S2-37 布局对位 iOS PeekControllerNode.containerLayoutUpdated（ContextControllerImpl/
 * Sources/PeekControllerNode.swift:203-262）：内容区按
 * `size.height - insets.top - insets.bottom - 90` 约束、放大贴纸居上、菜单在其下方，
 * 整体都在安全区内；可用高度不够时先压缩贴纸，菜单始终完整可见可点。
 * screenHeightVp=0 时回退为旧的固定尺寸（宿主未提供几何）。
 */
@Component
public class StickerPreviewOverlay {
    public var sticker: StickerItem = StickerItem()
    public var isFavorite: Bool = false
    /** 宿主给的可布局总高（vp）；0 = 未知，用固定尺寸。 */
    public var screenHeightVp: Float64 = 0.0
    /** 宿主顶部安全区（状态栏）与底部安全区（手势导航条）高度（vp）。 */
    public var topInsetVp: Float64 = 0.0
    public var bottomInsetVp: Float64 = 0.0
    public var onSend: (StickerItem) -> Unit = { _item: StickerItem => }
    /** iOS peek 菜单的 sendSticker(silentPosting: true)。 */
    public var onSendSilently: (StickerItem) -> Unit = { _item: StickerItem => }
    /** iOS peek 菜单的 sendSticker(schedule: true) —— 打开时间选择器。 */
    public var onSchedule: (StickerItem) -> Unit = { _item: StickerItem => }
    public var onFavorite: (StickerItem, Bool) -> Unit = { _item: StickerItem, _remove: Bool => }
    public var onViewPack: (StickerItem) -> Unit = { _item: StickerItem => }
    /** 长按的是 Recent 分区里的贴纸（iOS groupId == "recent"）。 */
    public var isRecent: Bool = false
    /** iOS 在收藏夹（自己）会话里不给 Send Without Sound。 */
    public var canSendSilently: Bool = true
    /** iOS Stickers.RemoveFromRecent → messages.saveRecentSticker(unsave: true)。 */
    public var onRemoveFromRecents: (StickerItem) -> Unit = { _item: StickerItem => }
    public var onClose: () -> Unit = { => }

    @State var localPath: String = ""

    /** 放大贴纸的容器边长（vp），随可用高度自适应；见 stickerBoxVp()。 */
    @State var stickerBoxVp: Float64 = 205.0

    protected override func aboutToAppear(): Unit {
        this.stickerBoxVp = this.computeStickerBoxVp()
        Hilog.info(0, "CjTelegram",
            "[StickerPreview] appear doc=${this.sticker.documentId} screen=${this.screenHeightVp}" +
            " top=${this.topInsetVp} bottom=${this.bottomInsetVp} rows=${this.menuRowCount()}" +
            " box=${this.stickerBoxVp} favorite=${this.isFavorite} recent=${this.isRecent}")
        let item = this.sticker
        let _ = spawn {
            let path = ensureStickerLocalFile(item)
            launch { this.localPath = path }
        }
    }

    private func isAnimated(): Bool {
        return this.sticker.mimeType.contains("tgs") ||
            this.sticker.mimeType.contains("lottie") ||
            this.sticker.mimeType.contains("webm")
    }

    private func isVideo(): Bool { return this.sticker.mimeType.contains("webm") }

    private func hasPackAction(): Bool {
        return this.sticker.packId != 0 || !this.sticker.packShortName.isEmpty()
    }

    /** 菜单行数（每行 44 + 0.5 分隔线），用于算贴纸可占的高度。 */
    private func menuRowCount(): Int64 {
        var rows: Int64 = 2 // Schedule Message + Add/Remove Favorites
        if (this.canSendSilently) { rows = rows + 1 }
        if (this.hasPackAction()) { rows = rows + 1 }
        if (this.isRecent) { rows = rows + 1 }
        return rows
    }

    private func menuHeightVp(): Float64 { return Float64(this.menuRowCount()) * 44.5 }

    /**
     * iOS PeekControllerNode：maxContainerSize.height = size.height - insets.top -
     * insets.bottom - 90，内容按 180 fitted 进去。这里把 90 换算成"菜单实高 + 间距 +
     * 留白"，贴纸容器 = 可用高 - 菜单 - 间距 - 留白，钳在 [90, 205]。
     */
    private func computeStickerBoxVp(): Float64 {
        if (this.screenHeightVp <= 0.0) { return 205.0 }
        let avail = this.screenHeightVp - this.topInsetVp - this.bottomInsetVp
        var box = avail - this.menuHeightVp() - STICKER_PREVIEW_MENU_SPACING_VP -
            STICKER_PREVIEW_VERTICAL_MARGIN_VP * 2.0
        if (box > 205.0) { box = 205.0 }
        if (box < 90.0) { box = 90.0 }
        return box
    }

    /** 贴纸绘制边长：容器留 15vp 边（原 190/205 比例）。 */
    private func stickerDisplayVp(): Float64 {
        let v = this.stickerBoxVp - 15.0
        if (v < 60.0) { return 60.0 }
        return v
    }

    public func build() {
        // 根节点既是遮罩也是点击关闭区；放大贴纸与菜单作为子节点浮在其上。
        // 两个 Blank 以 1:2 权重分配剩余空间 —— iOS freeform 内容位于可用高的上三分之一
        //（containerFrame.y = (H - h) * 1/3），菜单紧随其下；空间不够时 Blank 归零、
        // 贴纸按 computeStickerBoxVp() 缩小，菜单底边永不越过底部安全区。
        Column {
            Blank().layoutWeight(1)

            Column {
                if (!this.localPath.isEmpty()) {
                    if (this.isAnimated()) {
                        AnimatedStickerComponent(
                            documentId: this.sticker.documentId,
                            localPath: this.localPath,
                            displaySize: this.stickerDisplayVp(),
                            isVideoSticker: this.isVideo()
                        )
                    } else {
                        Image(this.localPath)
                            .width(this.stickerDisplayVp())
                            .height(this.stickerDisplayVp())
                            .objectFit(ImageFit.Contain)
                    }
                } else {
                    LoadingProgress().width(30).height(30).color(0x8E8E93)
                }
            }
            .width(220)
            .height(this.stickerBoxVp)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)

            // iOS ChatEntityKeyboardInputNode.swift:3000-3140 peek 菜单：
            // Send Without Sound（非收藏夹）· Schedule Message · Add to / Remove from Favorites ·
            // View Sticker Set · Remove from Recents（仅 recent 组，destructive）
            Column {
                if (this.canSendSilently) {
                    this.buildAction("Send Without Sound", "silent")
                }
                this.buildAction("Schedule Message", "schedule")
                this.buildAction(if (this.isFavorite) { "Remove from Favorites" } else { "Add to Favorites" }, "favorite")
                if (this.hasPackAction()) {
                    this.buildAction("View Sticker Set", "pack")
                }
                if (this.isRecent) {
                    this.buildAction("Remove from Recents", "removeRecent")
                }
            }
            .width(250)
            .borderRadius(14)
            .backgroundColor(0xF2FFFFFF)
            .clip(true)
            .margin(top: STICKER_PREVIEW_MENU_SPACING_VP)
            .onClick({ _evt => })

            Blank().layoutWeight(2)
        }
        .width(100.percent)
        .height(100.percent)
        .padding(
            top: this.topInsetVp + STICKER_PREVIEW_VERTICAL_MARGIN_VP,
            bottom: this.bottomInsetVp + STICKER_PREVIEW_VERTICAL_MARGIN_VP
        )
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(0x52000000)
        .backdropBlur(18.0)
        .onClick({ _evt => this.onClose() })
    }

    @Builder
    func buildAction(title: String, action: String) {
        Column {
            Text(title)
                .fontSize(17)
                .fontColor(if (action == "removeRecent") { 0xFFFF3B30 } else { 0xFF000000 })
                .width(100.percent)
                .height(44)
                .padding(left: 16, right: 16)
                .textAlign(TextAlign.Start)
            Divider().color(0x1F000000).strokeWidth(0.5)
        }
        .width(100.percent)
        .onClick({ _evt =>
            if (action == "send") {
                this.onSend(this.sticker)
            } else if (action == "silent") {
                this.onSendSilently(this.sticker)
            } else if (action == "schedule") {
                this.onSchedule(this.sticker)
            } else if (action == "favorite") {
                this.onFavorite(this.sticker, this.isFavorite)
            } else if (action == "pack") {
                this.onViewPack(this.sticker)
            } else if (action == "removeRecent") {
                this.onRemoveFromRecents(this.sticker)
            }
        })
    }
}
