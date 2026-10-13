package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.services.{getReactionOverlayService, loadMessageReadStats, formatPrivateReadDate, formatGroupReadCount, MessageReadStatsSnapshot}
import std.collection.{ArrayList, HashMap}
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.utils.safeAnimateTo
import std.sync.*
import std.time.*

/** Page-local presentation of Telegram's extracted message context controller. */
@Component
public class MessageContextOverlay {
    public var message: Message = Message()
    public var sourceY: Float64 = 0.0
    public var targetY: Float64 = 0.0
    public var sourceHeight: Float64 = 1.0
    public var screenHeight: Float64 = 800.0
    public var screenWidth: Float64 = 390.0
    public var isSent: Bool = false
    public var hasText: Bool = false
    public var hasMedia: Bool = false
    public var showTranslate: Bool = false
    public var peerType: String = "user"
    public var peerId: Int64 = 0
    public var isPinned: Bool = false
    /** iOS canViewReadStats (decided by the page) → read report row at the top. */
    public var readStatsEnabled: Bool = false
    /** Sender names already known to the chat, used to label group readers. */
    public var readStatsSenderNames: HashMap<Int64, String> = HashMap<Int64, String>()
    /** iOS CSM:1102-1112 "Save for Notifications". */
    public var saveToneEnabled: Bool = false
    /** iOS CISCM:1497 Gallery_SaveImage / Gallery_SaveVideo / Conversation_SaveToFiles. */
    public var saveTitle: String = "Save Image"
    /** iOS CISCM:2055-2060: Cancel Sending (isSending) / Remove (Saved Messages, incoming) / Delete. */
    public var deleteTitle: String = "Delete"
    /** S5-04: iOS Conversation.ContextViewReplies "View N Replies"; empty = no row. */
    public var repliesTitle: String = ""
    public var withWallpaper: Bool = false
    public var wallpaperGradientColors: Array<UInt32> = []
    /** Visible band of this overlay in its own coordinates (status bar,
     *  gesture bar and a raised IME already excluded by the host). */
    public var visibleTop: Float64 = 0.0
    public var visibleBottom: Float64 = 800.0
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var dismissing: Bool = false

    @State var presented: Bool = false
    @State var backdropPresented: Bool = false
    @State var previewY: Float64 = 0.0
    @State var reactionExpanded: Bool = false
    @State var reactionContentWidth: Float64 = 356.0
    // Read report row (ChatReadReportContextItem): " " until stats arrive,
    // like iOS; hidden again when the server data rules it out.
    @State var readStatsVisible: Bool = false
    @State var readStatsText: String = " "
    @State var readStatsTappable: Bool = false
    // Resolved per presentation in resolveLayout().
    private var contentY: Float64 = 0.0
    private var reactionAnchorY: Float64 = 0.0
    @State var actionsHeight: Float64 = 92.0
    // The overlay mounts while the long-press finger is still down. Its lift
    // can land on whichever row now sits under it; like iOS, an action (or
    // dismissal) needs a touch that began after presentation.
    private var freshTouchSeen: Bool = false

    public override func aboutToAppear(): Unit {
        this.readStatsVisible = this.readStatsEnabled
        if (this.readStatsEnabled) { this.loadReadStats() }
        this.resolveLayout()
        this.previewY = this.sourceY
        let uiContext = this.getUIContext()
        spawn {
            sleep(Duration.millisecond * 16)
            launch {
                safeAnimateTo(
                    { => uiContext },
                    AnimateParam(duration: 420, curve: Curve.Friction),
                    { =>
                        this.presented = true
                        this.previewY = this.contentY
                    }
                )
            }
        }
        // BackdropBlur creates an off-screen surface. Animating its radius from
        // zero makes RenderService expose that surface before its source
        // texture is ready, producing a one-frame black flash. Keep the radius
        // constant, let the invisible surface warm for two frames, then fade
        // only its opacity.
        spawn {
            sleep(Duration.millisecond * 50)
            launch { this.backdropPresented = true }
        }
    }

    /** Rows emitted by build(); each is a 46vp row plus a 0.5vp divider. */
    private func actionRowCount(): Int64 {
        var count: Int64 = 5 // reply, pin, forward, delete, select
        if (this.isSent) { count += 1 } else { count += 1 } // edit / report
        if (this.hasText) { count += 1 }
        if (this.showTranslate) { count += 1 }
        if (this.peerType != "user") { count += 1 }
        if (this.hasMedia) { count += 1 }
        if (this.saveToneEnabled) { count += 1 }
        if (this.repliesTitle.size > 0) { count += 1 }
        return count
    }

    /** Height of the whole action list including iOS thick separators (8pt). */
    private func actionsContentHeight(): Float64 {
        var height = Float64(this.actionRowCount()) * 46.5
        if (this.saveToneEnabled) { height += 8.0 }
        if (this.readStatsVisible) { height += this.readStatsRowHeight() + 8.0 }
        return height
    }

    /** CSM:3561-3570: private rows use verticalInset 7 and a 0.8x font. */
    private func readStatsRowHeight(): Float64 {
        return if (this.peerType == "user") { 38.0 } else { 46.0 }
    }

    private func loadReadStats(): Unit {
        let message = this.message
        let peerType = this.peerType
        let peerId = this.peerId
        let names = this.readStatsSenderNames
        spawn {
            let result = loadMessageReadStats(message, peerType, peerId, names)
            launch {
                match (result) {
                    case Some(stats) => this.applyReadStats(stats)
                    case None =>
                        this.readStatsVisible = false
                        this.relayout()
                }
            }
        }
    }

    private func applyReadStats(stats: MessageReadStatsSnapshot): Unit {
        if (stats.isPrivate) {
            // CSM:3550-3560 / 3579-3596.
            this.readStatsText = if (stats.readDate > 0) { formatPrivateReadDate(stats.readDate) } else { "read" }
            this.readStatsTappable = false
        } else {
            this.readStatsText = formatGroupReadCount(stats.peers.size, this.message)
            this.readStatsTappable = !stats.peers.isEmpty()
        }
    }

    private func relayout(): Unit {
        this.resolveLayout()
        let uiContext = this.getUIContext()
        safeAnimateTo(
            { => uiContext },
            AnimateParam(duration: 200, curve: Curve.EaseInOut),
            { => this.previewY = this.contentY }
        )
    }

    /**
     * iOS ContextControllerExtractedPresentationNode.update (extracted source,
     * keepInPlace == false): topInset = statusBar + 8, contentTopInset adds the
     * reaction bar, bottomInset = 10 + bottom insets. The content is clamped
     * below contentTopInset, then content + spacing + actions is pushed up
     * until it ends above the bottom inset, then clamped to contentTopInset
     * again. Actions always sit under the content. When the pair is still
     * taller than the screen, iOS scrolls its container to
     * contentHeight - layout.height (defaultScrollY), i.e. content and actions
     * move up together while the reaction bar keeps its unscrolled anchor.
     */
    private func resolveLayout(): Unit {
        let spacing = 8.0
        let topInset = this.visibleTop + 8.0
        let contentTopInset = topInset + 68.0
        let bottomLimit = this.visibleBottom - 10.0
        var actions = this.actionsContentHeight()
        let maxActions = bottomLimit - topInset
        if (actions > maxActions) { actions = maxActions }
        if (actions < 92.0) { actions = 92.0 }
        this.actionsHeight = actions

        var y = this.sourceY
        if (y < contentTopInset) { y = contentTopInset }
        let combined = this.sourceHeight + spacing + actions
        if (y + combined > bottomLimit) { y = bottomLimit - combined }
        if (y < contentTopInset) { y = contentTopInset }
        this.reactionAnchorY = y
        let overflow = y + combined - bottomLimit
        this.contentY = if (overflow > 0.0) { y - overflow } else { y }
    }

    private func menuTop(): Float64 {
        return this.contentY + this.sourceHeight + 8.0
    }

    private func menuHeight(): Float64 {
        return this.actionsHeight
    }

    private func reactionTop(): Float64 {
        if (!this.reactionExpanded) { return this.reactionAnchorY - 68.0 }
        let preferred = this.reactionAnchorY - 334.0
        let bottomLimit = this.screenHeight - 340.0
        if (preferred < 58.0) { return 58.0 }
        if (preferred > bottomLimit && bottomLimit > 58.0) { return bottomLimit }
        return preferred
    }

    private func reactionLeft(): Float64 {
        let width = if (this.reactionExpanded) { 330.0 } else { this.reactionContentWidth }
        if (this.isSent) { return this.screenWidth - width - 8.0 }
        return 8.0
    }

    private func reactionWidth(): Float64 {
        return if (this.reactionExpanded) { 330.0 } else { this.reactionContentWidth }
    }

    private func close(): Unit {
        if (!this.freshTouchSeen) { return }
        getReactionOverlayService().dismiss()
    }

    private func dispatch(action: String): Unit {
        if (!this.freshTouchSeen) { return }
        let service = getReactionOverlayService()
        if (action == "reply") { service.triggerReply() }
        else if (action == "edit") { service.triggerEdit() }
        else if (action == "pin") { service.triggerPinToggle() }
        else if (action == "forward") { service.triggerForward() }
        else if (action == "seen") { service.triggerSeenBy() }
        else if (action == "copy") { service.triggerCopy() }
        else if (action == "translate") { service.triggerTranslate() }
        else if (action == "link") { service.triggerCopyLink() }
        else if (action == "report") { service.triggerReportOpen() }
        else if (action == "save") { service.triggerSave() }
        else if (action == "delete") { service.triggerDelete() }
        else if (action == "tone") { service.triggerSaveTone() }
        else if (action == "select") { service.triggerSelectMode() }
        else if (action == "replies") { service.triggerViewReplies() }
    }

    @Builder
    private func actionIcon(action: String) {
        if (action == "reply") {
            Image(@r(app.media.chatroom_ic_reply)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
        else if (action == "edit") {
            Image(@r(app.media.chatroom_ic_edit)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
        else if (action == "pin") {
            Image(if (this.isPinned) { @r(app.media.chatroom_ic_unpin) } else { @r(app.media.chatroom_ic_pin) })
                .width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
        else if (action == "forward") {
            Image(@r(app.media.chatroom_ic_forward)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
        else if (action == "seen") {
            Image(@r(app.media.chatroom_ic_read)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
        else if (action == "copy") {
            Image(@r(app.media.chatroom_ic_copy)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
        else if (action == "translate") {
            Image(@r(app.media.chatroom_ic_translate)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
        else if (action == "link") {
            Image(@r(app.media.chatroom_ic_link)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
        else if (action == "report") {
            Image(@r(app.media.chatroom_ic_report)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
        else if (action == "save") {
            Image(@r(app.media.chatroom_ic_save)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
        else if (action == "delete") {
            Image(@r(app.media.chatroom_ic_delete)).width(20).height(20)
                .fillColor(this.presentation.contextMenuDestructiveColor)
        }
        else if (action == "tone") {
            Image(@r(app.media.chatroom_ic_download_tone)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
        else if (action == "replies") {
            Image(@r(app.media.chatroom_ic_reply)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
        else {
            Image(@r(app.media.chatroom_ic_select)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
        }
    }

    @Builder
    private func actionRow(action: String, title: String, destructive: Bool) {
        Column {
            Row(space: 13.vp) {
                this.actionIcon(action)
                Text(title)
                    .fontSize(16)
                    .fontColor(if (destructive) {
                        this.presentation.contextMenuDestructiveColor
                    } else {
                        this.presentation.contextMenuPrimaryColor
                    })
                    .layoutWeight(1)
            }
            .width(100.percent)
            .height(46)
            .padding(left: 14, right: 14)

            Divider()
                .strokeWidth(0.5)
                .color(this.presentation.contextMenuSeparatorColor)
                .margin(left: 47)
        }
        .width(100.percent)
        .onClick({ _evt => this.dispatch(action) })
    }

    /** iOS ContextControllerActionsStackNode separator item: an 8pt gap band. */
    @Builder
    private func thickSeparator() {
        Column {}
            .width(100.percent)
            .height(8)
            .backgroundColor(this.presentation.contextMenuSeparatorColor)
            .opacity(0.5)
    }

    /** ChatReadReportContextItem: read icon + text; groups open the reader list. */
    @Builder
    private func readStatsRow() {
        Row(space: 13.vp) {
            Image(@r(app.media.chatroom_ic_read)).width(20).height(20)
                .fillColor(this.presentation.contextMenuPrimaryColor)
            Text(this.readStatsText)
                .fontSize(if (this.peerType == "user") { 13.6 } else { 17.0 })
                .fontColor(this.presentation.contextMenuPrimaryColor)
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
                .layoutWeight(1)
        }
        .width(100.percent)
        .height(this.readStatsRowHeight())
        .padding(left: 14, right: 14)
        .onClick({ _evt =>
            if (this.readStatsTappable) { this.dispatch("seen") }
        })
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backdropBlur(22.0)
                .backgroundColor(this.presentation.contextMenuDimColor)
                .opacity(if (this.backdropPresented && !this.dismissing) { 1.0 } else { 0.0 })
                .animation(AnimateParam(duration: 160, curve: Curve.EaseOut))
                // Match iOS dismissNode: use the platform tap recognizer. The
                // long-press tail began on the source message, so it cannot
                // form a tap on this newly mounted node; the first new tap
                // dismisses immediately.
                .onClick({ _evt => this.close() })

            Stack(alignContent: Alignment.TopStart) {
                if (!this.reactionExpanded) {
                    Column {}
                        .width(16)
                        .height(16)
                        .borderRadius(8)
                        .backgroundColor(this.presentation.contextMenuBackgroundColor)
                        .backdropBlur(24.0)
                        .position(
                            x: if (this.isSent) { this.reactionContentWidth - 33.0 } else { 18.0 },
                            y: 45.0
                        )
                    Column {}
                        .width(8)
                        .height(8)
                        .borderRadius(4)
                        .backgroundColor(this.presentation.contextMenuBackgroundColor)
                        .backdropBlur(24.0)
                        .position(
                            x: if (this.isSent) { this.reactionContentWidth - 13.0 } else { 4.0 },
                            y: 59.0
                        )
                }
                QuickReactionBar(
                    onSelectReaction: { emoji: String =>
                        getReactionOverlayService().triggerSelectReaction(emoji)
                    },
                    onSelectCustomReaction: { documentId: Int64 =>
                        getReactionOverlayService().triggerSelectCustomReaction(documentId)
                    },
                    onClose: { => this.close() },
                    onExpanded: { => this.reactionExpanded = true },
                    onContentWidthChanged: { width: Float64 =>
                        this.reactionContentWidth = width
                    },
                    animateFromRight: this.isSent,
                    closeNativeContextMenu: false
                )
            }
            // iOS ReactionContextNode is full-screen for layout, but its
            // hitTest only returns contentContainer. Since Cangjie ArkUI has
            // no custom hitTest override, make this host exactly match the
            // visualBackgroundFrame instead of leaving an invisible hit box.
            .width(this.reactionWidth())
            .height(if (this.reactionExpanded) { 326 } else { 68 })
            .position(x: this.reactionLeft(), y: this.reactionTop())
            // iOS adds ReactionContextNode above the scrolled content node:
            // when a tall message is shifted up it passes under the bar.
            .zIndex(1)
            .scale(
                x: if (this.presented && !this.dismissing) { Float32(1.0) } else { Float32(0.75) },
                y: if (this.presented && !this.dismissing) { Float32(1.0) } else { Float32(0.75) },
                z: Float32(1.0)
            )
            .opacity(if (this.presented && !this.dismissing) { 1.0 } else { 0.0 })
            .animation(AnimateParam(duration: 400, curve: Curve.Friction))

            Stack(alignContent: Alignment.TopStart) {
                // The Cangjie 6.1 runtime does not ship the advertised
                // component_snapshot package, and reverse ArkTS calls made by
                // gestures have no JS scope. Reuse the exact renderer instead.
                MessageBubble(
                    message: this.message,
                    voicePlaybackEpoch: 0,
                    isMultiSelectMode: true,
                    withWallpaper: this.withWallpaper,
                    wallpaperGradientColors: this.wallpaperGradientColors
                )
            }
                .width(this.screenWidth)
                .height(this.sourceHeight)
                .clip(true)
                .position(x: 0.0, y: if (this.dismissing) { this.sourceY } else { this.previewY })
                .shadow(radius: if (this.presented && !this.dismissing) { 4.0 } else { 0.0 }, color: 0x22000000)
                .animation(AnimateParam(duration: 200, curve: Curve.EaseInOut))
                // The extracted renderer needs the full row for pixel-perfect
                // alignment. It is not an action surface; a fresh tap on it
                // follows iOS cancellation semantics.
                .onClick({ _evt => this.close() })

            Scroll() {
                Column {
                    // CSM:2208 inserts the read report item (and a separator)
                    // at index 0; CSM:1114 puts "Save for Notifications" and
                    // its separator before Reply.
                    if (this.readStatsVisible) {
                        this.readStatsRow()
                        this.thickSeparator()
                    }
                    if (this.saveToneEnabled) {
                        this.actionRow("tone", "Save for Notifications", false)
                        this.thickSeparator()
                    }
                    this.actionRow("reply", "Reply", false)
                    // iOS CISCM: View N Replies / View Thread sits right after Reply.
                    if (this.repliesTitle.size > 0) { this.actionRow("replies", this.repliesTitle, false) }
                    if (this.isSent) { this.actionRow("edit", "Edit", false) }
                    this.actionRow("pin", if (this.isPinned) { "Unpin" } else { "Pin" }, false)
                    this.actionRow("forward", "Forward", false)
                    if (this.hasText) { this.actionRow("copy", "Copy", false) }
                    if (this.showTranslate) {
                        this.actionRow("translate", "Translate", false)
                    }
                    if (this.peerType != "user") { this.actionRow("link", "Copy Link", false) }
                    if (!this.isSent) { this.actionRow("report", "Report", false) }
                    if (this.hasMedia) { this.actionRow("save", this.saveTitle, false) }
                    this.actionRow("delete", this.deleteTitle, true)
                    this.actionRow("select", "Select", false)
                }
                .width(100.percent)
            }
            .width(210)
            .height(this.menuHeight())
            .position(x: if (this.isSent) { this.screenWidth - 222.0 } else { 12.0 }, y: this.menuTop())
            .zIndex(2)
            .backgroundColor(this.presentation.contextMenuBackgroundColor)
            .backdropBlur(28.0)
            .borderRadius(14)
            .shadow(radius: 18.0, color: 0x30000000, offsetY: 6.0)
            .scale(
                x: if (this.presented && !this.dismissing) { Float32(1.0) } else { Float32(0.01) },
                y: if (this.presented && !this.dismissing) { Float32(1.0) } else { Float32(0.01) },
                z: Float32(1.0),
                centerX: if (this.isSent) { 100.percent } else { 0.percent },
                centerY: 0.percent
            )
            .opacity(if (this.presented && !this.dismissing) { 1.0 } else { 0.0 })
            .animation(AnimateParam(duration: 420, curve: Curve.Friction))
        }
        .width(100.percent)
        .height(100.percent)
        .onTouch({ evt =>
            if (evt.eventType == TouchType.Down) { this.freshTouchSeen = true }
        })
    }
}
