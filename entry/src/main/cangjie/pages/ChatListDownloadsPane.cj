package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.{Want, Flags}
import std.collection.ArrayList
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.components.ChatListSearchItemHeaderComponent
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation, trOr}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.formatRelativeTimestamp

private let DOWNLOADS_FILE_URI_BUNDLE: String = "com.hmcangjie.telegram"

/**
 * Global search "Downloads" pane (iOS ChatListSearchListPaneNode with
 * key == .downloads): a "Downloading" section for active fetches and a
 * "Recently Downloaded" section with a Clear action, each row a
 * ListMessageFileItemNode in isDownloadList mode (extension badge, file name,
 * "size • author" and the message date).
 */
@Component
public class ChatListDownloadsPane {
    public var query: String = ""
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var active: ArrayList<RecentDownloadEntry> = ArrayList<RecentDownloadEntry>()
    @State var recent: ArrayList<RecentDownloadEntry> = ArrayList<RecentDownloadEntry>()
    private var refreshTimer: Option<Timer> = None<Timer>

    public override func aboutToAppear(): Unit {
        this.reload()
        // Active fetches finish in the background; refresh like the iOS
        // entriesSummary signal while the pane is visible.
        this.refreshTimer = Some(Timer.repeat(
            Duration.second, Duration.second, { => launch { this.reload() } }, style: CatchupStyle.Skip
        ))
    }

    public override func aboutToDisappear(): Unit {
        match (this.refreshTimer) {
            case Some(t) => t.cancel()
            case None => ()
        }
        this.refreshTimer = None<Timer>
    }

    private func matches(e: RecentDownloadEntry): Bool {
        if (this.query.isEmpty()) { return true }
        let q = this.query.toAsciiLower()
        return e.fileName.toAsciiLower().contains(q) || e.chatTitle.toAsciiLower().contains(q)
    }

    private func reload(): Unit {
        let a = ArrayList<RecentDownloadEntry>()
        for (e in getActiveDownloads()) { if (this.matches(e)) { a.add(e) } }
        let r = ArrayList<RecentDownloadEntry>()
        for (e in getRecentDownloads()) { if (this.matches(e)) { r.add(e) } }
        if (a.size != this.active.size) { this.active = a }
        if (r.size != this.recent.size || !this.sameOrder(r, this.recent)) { this.recent = r }
    }

    private func sameOrder(x: ArrayList<RecentDownloadEntry>, y: ArrayList<RecentDownloadEntry>): Bool {
        if (x.size != y.size) { return false }
        var i = 0
        while (i < x.size) {
            if (!x[i].sameItem(y[i])) { return false }
            i += 1
        }
        return true
    }

    private func extensionOf(name: String): String {
        match (name.lastIndexOf(".")) {
            case Some(idx) =>
                if (idx + 1 < name.size) { return name[(idx + 1)..].toAsciiLower() }
                return ""
            case None => return ""
        }
    }

    private func sizeString(bytes: Int64): String {
        if (bytes < 1024) { return "${bytes} B" }
        if (bytes < 1024 * 1024) {
            let tenths = bytes * 10 / 1024
            return "${tenths / 10}.${tenths % 10} KB"
        }
        let tenths = bytes * 10 / (1024 * 1024)
        return "${tenths / 10}.${tenths % 10} MB"
    }

    /** ListMessageFileItemNode isDownloadList description: "size • author". */
    private func descriptionOf(e: RecentDownloadEntry): String {
        let size = if (e.size > 0) { this.sizeString(e.size) } else { "" }
        let author = if (e.authorName.size > 0) { e.authorName } else { e.chatTitle }
        if (size.isEmpty()) { return author }
        if (author.isEmpty()) { return size }
        return "${size} • ${author}"
    }

    /** Opens the fetched file (iOS opens the gallery / document preview). */
    private func openEntry(e: RecentDownloadEntry): Unit {
        if (e.localPath.isEmpty()) { return }
        let path = if (e.localPath.startsWith("file://")) { e.localPath[7..] } else { e.localPath }
        let uri = if (path.startsWith("/")) { "file://" + DOWNLOADS_FILE_URI_BUNDLE + path } else { e.localPath }
        let mime = e.mimeType
        let utd = if (mime.contains("pdf")) { "general.pdf" }
            else if (mime.contains("image")) { "general.image" }
            else if (mime.contains("video")) { "general.video" }
            else if (mime.contains("audio")) { "general.audio" }
            else if (mime.contains("text")) { "general.plain-text" }
            else if (mime.contains("zip") || mime.contains("rar") || mime.contains("7z")) { "general.archive" }
            else { "general.object" }
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    ctx.startAbility(Want(
                        flags: Flags.FLAG_AUTH_READ_URI_PERMISSION,
                        uri: uri,
                        action: "ohos.want.action.viewData",
                        dataType: utd
                    ))
                } catch (ex: Exception) {
                    Hilog.info(0, "CjTelegram", "[Downloads] open failed: ${ex}")
                }
            case None => ()
        }
    }

    /** ChatListSearchListPaneNode openClearRecentlyDownloaded action sheet. */
    private func presentClear(): Unit {
        let uiCtx = this.getUIContext()
        let manage = AlertDialogButtonOptions(
            value: trOr("DownloadList.OptionManageDeviceStorage", "Manage Device Storage"),
            action: { => routerPush("StorageUsagePage", "") }
        )
        let clear = AlertDialogButtonOptions(
            value: trOr("DownloadList.ClearDownloadList", "Clear Download List"),
            fontColor: 0xFFFF3B30,
            action: { =>
                clearRecentDownloads()
                this.reload()
            }
        )
        let cancel = AlertDialogButtonOptions(value: trOr("Common.Cancel", "Cancel"), action: { => () })
        uiCtx.showAlertDialog(AlertDialogParamWithOptions(
            title: trOr("DownloadList.ClearAlertTitle", "Downloaded Files"),
            message: trOr("DownloadList.ClearAlertText", "Telegram allows to store all received and sent documents in the cloud and save storage space on your device."),
            autoCancel: true,
            buttons: [manage, clear, cancel]
        ))
    }

    @Builder
    func row(e: RecentDownloadEntry, downloading: Bool) {
        Row(space: 12) {
            Stack {
                Text(this.extensionOf(e.fileName))
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFFFFFFFF)
                    .maxLines(1)
            }
            .width(40)
            .height(40)
            .borderRadius(6)
            .backgroundColor(Color(UInt32(getListMessageService().extensionColor(this.extensionOf(e.fileName)))))
            Column(space: 2) {
                Row {
                    Text(e.fileName)
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.presentation.textColor)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                        .layoutWeight(1)
                    if (e.messageDate > 0) {
                        Text(formatRelativeTimestamp(e.messageDate))
                            .fontSize(14)
                            .fontColor(this.presentation.secondaryTextColor)
                    }
                }
                .width(100.percent)
                Text(if (downloading) { trOr("DownloadList.DownloadingHeader", "Downloading") } else { this.descriptionOf(e) })
                    .fontSize(14)
                    .fontColor(this.presentation.secondaryTextColor)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                    .width(100.percent)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
        .width(100.percent)
        .height(60)
        .padding(left: 16, right: 16)
        .backgroundColor(this.presentation.cardColor)
        .onClick({ _evt => if (!downloading) { this.openEntry(e) } })
    }

    public func build() {
        List {
            if (!this.active.isEmpty()) {
                ListItem {
                    ChatListSearchItemHeaderComponent(
                        headerType: ChatListSearchHeaderType.Text,
                        customTitle: trOr("DownloadList.DownloadingHeader", "Downloading")
                    )
                }
                ForEach(this.active.toArray(), itemGenerator: { e: RecentDownloadEntry, _i: Int64 =>
                    ListItem { this.row(e, true) }
                }, keyGenerator: { e: RecentDownloadEntry, _i: Int64 => "a_${e.peerId}_${e.messageId}_${e.documentId}" })
            }
            if (!this.recent.isEmpty()) {
                ListItem {
                    ChatListSearchItemHeaderComponent(
                        headerType: ChatListSearchHeaderType.Text,
                        customTitle: trOr("DownloadList.DownloadedHeader", "Recently Downloaded"),
                        actionTitle: trOr("DownloadList.Clear", "Clear"),
                        onActionClick: { => this.presentClear() }
                    )
                }
                ForEach(this.recent.toArray(), itemGenerator: { e: RecentDownloadEntry, _i: Int64 =>
                    ListItem { this.row(e, false) }
                }, keyGenerator: { e: RecentDownloadEntry, _i: Int64 => "r_${e.peerId}_${e.messageId}_${e.documentId}" })
            }
        }
        .width(100.percent)
        .height(100.percent)
        .divider(ListDividerOptions(strokeWidth: 0.5, color: Color(this.presentation.dividerColor), startMargin: 68, endMargin: 0))
        .scrollBar(BarState.Off)
    }
}
