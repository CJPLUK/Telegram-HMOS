package ohos_app_cangjie_entry.services

/**
 * Owns the action callbacks for the currently presented message context menu.
 *
 * Rendering and dismissal animation remain page-local. Keeping callbacks in a
 * small service lets the extracted overlay invoke chat-page actions without
 * retaining component references in reusable message bubbles.
 */
private var _reactionOverlayServiceInstance: Option<ReactionOverlayService> = None<ReactionOverlayService>

public func getReactionOverlayService(): ReactionOverlayService {
    match (_reactionOverlayServiceInstance) {
        case Some(s) => s
        case None =>
            let s = ReactionOverlayService()
            _reactionOverlayServiceInstance = Some(s)
            s
    }
}

public class ReactionOverlayService {
    private var _showing: Bool = false
    private var _onSelectReaction: (String) -> Unit = { _emoji: String => }
    private var _onSelectCustomReaction: (Int64) -> Unit = { _documentId: Int64 => }
    private var _onReply: () -> Unit = { => }
    private var _onEdit: () -> Unit = { => }
    private var _onPinToggle: () -> Unit = { => }
    private var _onPinForMe: () -> Unit = { => }
    private var _onForward: () -> Unit = { => }
    private var _onSelectMode: () -> Unit = { => }
    private var _onSeenBy: () -> Unit = { => }
    private var _onCopy: () -> Unit = { => }
    private var _onSpeak: () -> Unit = { => }
    private var _onTranslate: () -> Unit = { => }
    private var _onCopyLink: () -> Unit = { => }
    private var _onReportOpen: () -> Unit = { => }
    private var _onSave: () -> Unit = { => }
    private var _onCopyMedia: () -> Unit = { => }
    private var _onDelete: () -> Unit = { => }
    private var _onSaveTone: () -> Unit = { => }
    private var _onViewReplies: () -> Unit = { => }
    private var _onDismiss: () -> Unit = { => }
    /** Replace the callbacks atomically before the page mounts its overlay. */
    public func showReactionOverlay(
        onSelectReaction!: (String) -> Unit = { _emoji: String => },
        onSelectCustomReaction!: (Int64) -> Unit = { _documentId: Int64 => },
        onReply!: () -> Unit = { => },
        onEdit!: () -> Unit = { => },
        onPinToggle!: () -> Unit = { => },
        onPinForMe!: () -> Unit = { => },
        onForward!: () -> Unit = { => },
        onSelectMode!: () -> Unit = { => },
        onSeenBy!: () -> Unit = { => },
        onCopy!: () -> Unit = { => },
        onSpeak!: () -> Unit = { => },
        onTranslate!: () -> Unit = { => },
        onCopyLink!: () -> Unit = { => },
        onReportOpen!: () -> Unit = { => },
        onSave!: () -> Unit = { => },
        onCopyMedia!: () -> Unit = { => },
        onDelete!: () -> Unit = { => },
        onSaveTone!: () -> Unit = { => },
        onViewReplies!: () -> Unit = { => },
        onDismiss!: () -> Unit = { => }
    ): Unit {
        this._onViewReplies = onViewReplies
        this._onSelectReaction = onSelectReaction
        this._onSelectCustomReaction = onSelectCustomReaction
        this._onReply = onReply
        this._onEdit = onEdit
        this._onPinToggle = onPinToggle
        this._onPinForMe = onPinForMe
        this._onForward = onForward
        this._onSelectMode = onSelectMode
        this._onSeenBy = onSeenBy
        this._onCopy = onCopy
        this._onSpeak = onSpeak
        this._onTranslate = onTranslate
        this._onCopyLink = onCopyLink
        this._onReportOpen = onReportOpen
        this._onSave = onSave
        this._onCopyMedia = onCopyMedia
        this._onDelete = onDelete
        this._onSaveTone = onSaveTone
        this._onDismiss = onDismiss
        this._showing = true
    }

    /** Dismiss once and notify the page; repeated calls are no-ops. */
    public func dismiss(): Unit {
        if (!this._showing) {
            return
        }
        this._showing = false
        let dismissCb = this._onDismiss
        dismissCb()
    }

    public func triggerSelectReaction(emoji: String): Unit {
        let cb = this._onSelectReaction
        // Restore/dismiss the extracted presentation before the reaction
        // changes the message and causes a reusable bubble update.
        this.dismiss()
        cb(emoji)
    }

    public func triggerSelectCustomReaction(documentId: Int64): Unit {
        let cb = this._onSelectCustomReaction
        this.dismiss()
        cb(documentId)
    }

    public func triggerReply(): Unit {
        let cb = this._onReply
        this.dismiss()
        cb()
    }

    public func triggerEdit(): Unit {
        let cb = this._onEdit
        this.dismiss()
        cb()
    }

    public func triggerPinToggle(): Unit {
        let cb = this._onPinToggle
        this.dismiss()
        cb()
    }

    public func triggerPinForMe(): Unit {
        let cb = this._onPinForMe
        this.dismiss()
        cb()
    }

    public func triggerForward(): Unit {
        let cb = this._onForward
        this.dismiss()
        cb()
    }

    public func triggerSelectMode(): Unit {
        let cb = this._onSelectMode
        this.dismiss()
        cb()
    }

    public func triggerSeenBy(): Unit {
        let cb = this._onSeenBy
        this.dismiss()
        cb()
    }

    public func triggerCopy(): Unit {
        let cb = this._onCopy
        this.dismiss()
        cb()
    }

    public func triggerSpeak(): Unit {
        let cb = this._onSpeak
        this.dismiss()
        cb()
    }

    public func triggerTranslate(): Unit {
        let cb = this._onTranslate
        this.dismiss()
        cb()
    }

    public func triggerCopyLink(): Unit {
        let cb = this._onCopyLink
        this.dismiss()
        cb()
    }

    /**
     * 举报入口点击：dismiss 原生长按菜单（原生 MenuItem.onClick 后菜单本就会整体收起，
     * 见 pages/ChatRoomPage.cj presentReactionOverlay onReportOpen 注释），随后触发
     * onReportOpen 业务回调发起 fetchReportOptions，拿到选项后由 ChatRoomPage 用独立
     * AlertDialog 呈现（showReportOptionsDialog/submitReportOption），不再需要本服务持有
     * 举报两阶段中间状态。
     */
    public func triggerReportOpen(): Unit {
        let cb = this._onReportOpen
        this.dismiss()
        cb()
    }

    public func triggerSave(): Unit {
        let cb = this._onSave
        this.dismiss()
        cb()
    }

    /**
     * imgmenu 批次：长按菜单 "Copy Photo"（对应 iOS 照片消息 context menu 的 Copy —
     * iOS 复制图片字节到 UIPasteboard；本平台 D-tier 复制 file:// URI 纯文本，见
     * SaveToCameraRollService.copyMediaFileUri 文档注释的 fidelity gap 说明）。
     */
    public func triggerCopyMedia(): Unit {
        let cb = this._onCopyMedia
        this.dismiss()
        cb()
    }

    /** iOS CSM:1114 "Save for Notifications". */
    public func triggerSaveTone(): Unit {
        let cb = this._onSaveTone
        this.dismiss()
        cb()
    }

    public func triggerDelete(): Unit {
        let cb = this._onDelete
        this.dismiss()
        cb()
    }

    /** S5-04: iOS Conversation.ContextViewReplies → open the comment / reply thread. */
    public func triggerViewReplies(): Unit {
        let cb = this._onViewReplies
        this.dismiss()
        cb()
    }
}
