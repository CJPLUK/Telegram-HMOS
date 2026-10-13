package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import std.collection.ArrayList
import ohos_app_cangjie_entry.models.{ChatFolder, FolderShareablePeer, ExportedChatFolderLink}
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.components.{itemListPageBackgroundColor, itemListCardColor, QrCodeView}
import ohos_app_cangjie_entry.components.Avatar
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.utils.copyText

@HybridComponentEntry
@Component
public class ChatFolderInviteLinkPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false
    @State var folder: ChatFolder = ChatFolder()
    @State var peers: ArrayList<FolderShareablePeer> = ArrayList<FolderShareablePeer>()
    @State var link: ExportedChatFolderLink = ExportedChatFolderLink()
    @State var hasLink: Bool = false
    @State var generating: Bool = false
    @State var saving: Bool = false
    @State var selectedTotal: Int64 = 0
    @State var dirty: Bool = false
    @State var linkTitle: String = ""
    @State var originalTitle: String = ""
    @State var showLinkMenu: Bool = false
    @State var showRenamePrompt: Bool = false
    @State var renameValue: String = ""
    @State var showQrCode: Bool = false
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    private func buildPeers(folder: ChatFolder): ArrayList<FolderShareablePeer> {
        let result = ArrayList<FolderShareablePeer>()
        for (ref in folder.includePeerRefs) {
            let peer = FolderShareablePeer()
            peer.peerId = ref.id
            peer.peerType = ref.peerType
            peer.accessHash = ref.accessHash
            peer.title = if (ref.name.isEmpty()) { "Chat ${ref.id}" } else { ref.name }
            peer.isAvailable = ref.canShareLink && !ref.isMigrated
            peer.isSelected = peer.isAvailable
            result.add(peer)
        }
        return result
    }

    private func selectedCount(): Int64 {
        return this.selectedTotal
    }

    private func selectableCount(): Int64 {
        var count: Int64 = 0
        for (peer in this.peers) { if (peer.isAvailable) { count = count + 1 } }
        return count
    }

    private func selectionDiffers(): Bool {
        if (!this.hasLink || this.selectedCount() != this.link.peerIds.size) { return true }
        for (peer in this.peers) {
            if (peer.isSelected) {
                var found = false
                for (peerId in this.link.peerIds) { if (peerId == peer.peerId) { found = true } }
                if (!found) { return true }
            }
        }
        return false
    }

    private func refreshDirty(): Unit {
        this.dirty = this.linkTitle != this.originalTitle || this.selectionDiffers()
    }

    private func applyLinkSelection(link: ExportedChatFolderLink): Unit {
        let updated = ArrayList<FolderShareablePeer>()
        var count: Int64 = 0
        for (value in this.peers) {
            let peer = FolderShareablePeer()
            peer.peerId = value.peerId
            peer.peerType = value.peerType
            peer.accessHash = value.accessHash
            peer.title = value.title
            peer.isAvailable = value.isAvailable
            var included = false
            for (peerId in link.peerIds) {
                if (peerId == value.peerId) { included = true }
            }
            peer.isSelected = value.isAvailable && included
            if (peer.isSelected) { count = count + 1 }
            updated.add(peer)
        }
        this.peers = updated
        this.selectedTotal = count
    }

    private func load(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        match (getChatFolderDraftService().current()) {
            case Some(value) =>
                this.folder = value
                this.peers = this.buildPeers(value)
                this.selectedTotal = this.selectableCount()
            case None => routerPop(); return
        }
        match (getChatFolderDraftService().selectedInvite()) {
            case Some(resolved) =>
                this.link = resolved
                this.hasLink = !resolved.url.isEmpty()
                this.linkTitle = resolved.title
                this.originalTitle = resolved.title
                this.applyLinkSelection(resolved)
                let sharedFolder = this.folder.copy()
                sharedFolder.isShared = true
                this.folder = sharedFolder
                getChatFolderDraftService().update(sharedFolder)
            case None => ()
        }
    }

    private func togglePeer(index: Int64): Unit {
        if (index < 0 || index >= this.peers.size || !this.peers[index].isAvailable) { return }
        let updated = ArrayList<FolderShareablePeer>()
        var i: Int64 = 0
        for (value in this.peers) {
            let peer = FolderShareablePeer()
            peer.peerId = value.peerId; peer.peerType = value.peerType; peer.accessHash = value.accessHash
            peer.title = value.title; peer.isAvailable = value.isAvailable
            peer.isSelected = if (i == index) { !value.isSelected } else { value.isSelected }
            updated.add(peer)
            i = i + 1
        }
        this.peers = updated
        this.selectedTotal = this.selectedTotal + (if (updated[index].isSelected) { 1 } else { -1 })
        this.refreshDirty()
    }

    private func toggleAll(): Unit {
        let select = this.selectedCount() != this.selectableCount()
        let updated = ArrayList<FolderShareablePeer>()
        for (value in this.peers) {
            let peer = FolderShareablePeer()
            peer.peerId = value.peerId; peer.peerType = value.peerType; peer.accessHash = value.accessHash
            peer.title = value.title; peer.isAvailable = value.isAvailable
            peer.isSelected = value.isAvailable && select
            updated.add(peer)
        }
        this.peers = updated
        this.selectedTotal = if (select) { this.selectableCount() } else { 0 }
        this.refreshDirty()
    }

    private func save(): Unit {
        if (this.saving || this.selectedCount() == 0 || !this.dirty) { return }
        if (!this.hasLink) { routerPop(); return }
        this.saving = true
        let folderId = this.folder.id
        let slug = this.link.slug()
        let selected = this.peers
        let title = this.linkTitle
        spawn {
            =>
            let updated = getChatFolderLinksService().editExportedInvite(folderId, slug, newTitle: title, hasTitle: true, peers: selected, hasPeers: true)
            spawn(UIThread) {
                =>
                this.saving = false
                if (!updated.url.isEmpty()) {
                    getChatFolderDraftService().setUpdatedInvite(updated)
                    routerPop()
                }
                else { showToast("Could not update invite link.") }
            }
        }
    }

    private func attemptClose(): Unit {
        if (!this.hasLink || !this.dirty) {
            routerPop()
            return
        }
        let actionTitle = if (this.selectedCount() == 0) { "Apply" } else { "Continue" }
        getUIContext().showAlertDialog(AlertDialogParamWithButtons(
            title: "Unsaved Changes",
            message: "You have changed the settings of this folder. Apply changes?",
            primaryButton: AlertDialogButtonOptions(value: "Discard", action: { => routerPop() }),
            secondaryButton: AlertDialogButtonOptions(value: actionTitle, action: { => this.save() })
        ))
    }

    private func copyLink(): Unit {
        if (this.hasLink && copyText(this.link.url)) { showToast("Invite link copied") }
    }

    private func shareLink(): Unit {
        if (this.hasLink) { let _ = getShareControllerService().shareInviteLinkViaSystem(this.link.url) }
    }

    private func revokeLink(): Unit {
        this.showLinkMenu = false
        let id = this.folder.id
        let slug = this.link.slug()
        spawn {
            =>
            let service = getChatFolderLinksService()
            let revoked = service.editExportedInvite(id, slug, revoke: true)
            let ok = !revoked.url.isEmpty() && service.deleteExportedInvite(id, slug)
            spawn(UIThread) {
                =>
                if (ok) {
                    revoked.isRevoked = true
                    getChatFolderDraftService().setUpdatedInvite(revoked)
                    routerPop()
                } else { showToast("Could not revoke invite link.") }
            }
        }
    }

    private func displayLink(): String {
        let prefix = "https://"
        if (this.link.url.startsWith(prefix)) { return this.link.url[prefix.size..this.link.url.size] }
        return this.link.url
    }

    private func applyLinkName(value: String): Unit {
        this.renameValue = value
        this.linkTitle = value
        this.refreshDirty()
    }

    private func presentRenamePrompt(): Unit {
        this.showLinkMenu = false
        this.renameValue = this.linkTitle
        this.showRenamePrompt = true
    }

    private func confirmRename(): Unit {
        this.showRenamePrompt = false
        this.applyLinkName(this.renameValue)
    }

    @Builder
    func checkMark(selected: Bool) {
        Stack(alignContent: Alignment.Center) {
            Circle().width(24).height(24).fill(if (selected) { this.presentation.accentColor } else { Color.Transparent })
                .stroke(if (selected) { this.presentation.accentColor } else { 0xFFC7C7CC }).strokeWidth(1.5)
            if (selected) { Text("✓").fontSize(15).fontColor(0xFFFFFFFF).fontWeight(FontWeight.Bold) }
        }.width(34).height(34)
    }

    @Builder
    func linkMenu() {
        Column {
            Row {
                Image(@r(app.media.chatroom_ic_edit)).width(20).height(20).fillColor(this.presentation.textColor)
                Text(trSource("Name Link")).fontSize(16).fontColor(this.presentation.textColor).margin(left: 14)
            }.width(100.percent).height(52).padding(left: 16, right: 16).onClick({ _ =>
                this.presentRenamePrompt()
            })
            Divider().margin(left: 50)
            Row {
                Image(@r(app.media.chatroom_ic_copy)).width(20).height(20).fillColor(this.presentation.textColor)
                Text(trSource("Copy")).fontSize(16).fontColor(this.presentation.textColor).margin(left: 14)
            }.width(100.percent).height(52).padding(left: 16, right: 16).onClick({ _ => this.showLinkMenu = false; this.copyLink() })
            Divider().margin(left: 50)
            Row {
                Image(@r(app.media.devices_ic_qr_button)).width(20).height(20).fillColor(this.presentation.textColor)
                Text(trSource("Get QR Code")).fontSize(16).fontColor(this.presentation.textColor).margin(left: 14)
            }.width(100.percent).height(52).padding(left: 16, right: 16).onClick({ _ => this.showLinkMenu = false; this.showQrCode = true })
            Divider().margin(left: 50)
            Row {
                Image(@r(app.media.set2_ic_trash)).width(20).height(20).fillColor(0xFFFF3B30)
                Text(trSource("Revoke")).fontSize(16).fontColor(0xFFFF3B30).margin(left: 14)
            }.width(100.percent).height(52).padding(left: 16, right: 16).onClick({ _ => this.revokeLink() })
        }.width(258).backgroundColor(this.presentation.cardColor).borderRadius(18).clip(true)
    }

    @Builder
    func qrCodeOverlay() {
        Stack(alignContent: Alignment.Bottom) {
            Stack {}.width(100.percent).height(100.percent).backgroundColor(0x50000000)
                .onClick({ _ => this.showQrCode = false })
            Column {
                Row {
                    Stack(alignContent: Alignment.Center) {
                        Image(@r(app.media.nav_ic_close)).width(22).height(22).fillColor(this.presentation.textColor)
                    }.width(44).height(44).borderRadius(22).backgroundColor(itemListPageBackgroundColor())
                        .onClick({ _ => this.showQrCode = false })
                    Blank().layoutWeight(1)
                    Text(trSource("Invite by QR Code")).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.presentation.textColor)
                    Blank().layoutWeight(1)
                    Blank().width(44).height(44)
                }.width(100.percent).height(68).padding(left: 16, right: 16, top: 12).alignItems(VerticalAlign.Center)
                Stack(alignContent: Alignment.Center) {
                    QrCodeView(content: this.link.url, size: 240, showCenterLogo: true)
                }.width(256).height(256).backgroundColor(0xFFFFFFFF).borderRadius(24)
                Text(trSource("Everyone on Telegram can scan this code to add this folder and join the chats included in this invite link."))
                    .fontSize(15).fontColor(this.presentation.textColor).textAlign(TextAlign.Center)
                    .padding(left: 24, right: 24).margin(top: 17)
                Button(trSource("Share QR Code")).width(100.percent).height(52).fontSize(17).fontWeight(FontWeight.Bold)
                    .fontColor(0xFFFFFFFF).backgroundColor(this.presentation.accentColor).borderRadius(26)
                    .margin(left: 30, right: 30, top: 23, bottom: 16.0 + getSafeAreaBottom())
                    .onClick({ _ => this.shareLink() })
            }.width(100.percent).backgroundColor(this.presentation.cardColor)
                .borderRadius(topLeft: 28, topRight: 28).alignItems(HorizontalAlign.Center)
        }.width(100.percent).height(100.percent)
    }

    @Builder
    func renamePromptOverlay() {
        Stack(alignContent: Alignment.Center) {
            Stack {}.width(100.percent).height(100.percent).backgroundColor(0x80000000)
                .onClick({ _ => this.showRenamePrompt = false })
            Column {
                Text(trSource("Name Link")).fontSize(18).fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor).margin(bottom: 16)
                TextInput(text: this.renameValue, placeholder: trSource("Link Name"))
                    .id("chat_folder_link_name_input")
                    .maxLength(32)
                    .fontSize(16).width(100.percent).height(44).margin(bottom: 20)
                    .onChange({ value: String => this.renameValue = value })
                    .onAppear({ => FocusControl.requestFocus("chat_folder_link_name_input") })
                Row {
                    Text(trSource("Cancel")).fontSize(16).fontColor(this.presentation.accentColor)
                        .layoutWeight(1).textAlign(TextAlign.Center)
                        .onClick({ _ => this.showRenamePrompt = false })
                    Text(trSource("Done")).fontSize(16).fontWeight(FontWeight.Bold)
                        .fontColor(this.presentation.accentColor).layoutWeight(1)
                        .textAlign(TextAlign.Center).onClick({ _ => this.confirmRename() })
                }.width(100.percent)
            }.width(80.percent).padding(top: 24, bottom: 20, left: 20, right: 20)
                .borderRadius(14).backgroundColor(this.presentation.cardColor)
                .onClick({ _ => () })
        }.width(100.percent).height(100.percent).zIndex(300)
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Column {
                Row {
                    Stack(alignContent: Alignment.Center) {
                        Image(@r(app.media.nav_ic_close)).width(22).height(22).fillColor(this.presentation.textColor)
                    }.width(44).height(44).borderRadius(22).backgroundColor(this.presentation.cardColor)
                        .onClick({ _ => this.attemptClose() })
                    Blank().layoutWeight(1)
                    Text(if (this.linkTitle.isEmpty()) { "Share Folder" } else { this.linkTitle })
                        .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.presentation.textColor)
                        .maxLines(1)
                    Blank().layoutWeight(1)
                    if (this.selectableCount() > 0) {
                        Stack(alignContent: Alignment.Center) {
                            if (this.saving) {
                                LoadingProgress().width(22).height(22).color(this.presentation.accentColor)
                            } else {
                                Image(@r(app.media.username_nav_ic_done)).width(22).height(22)
                                    .fillColor(if (this.dirty && this.selectedCount() > 0) { this.presentation.accentColor } else { 0xFFB8BEC6 })
                            }
                        }.width(44).height(44).borderRadius(22).backgroundColor(this.presentation.cardColor)
                            .onClick({ _ => this.save() })
                    } else { Blank().width(44).height(44) }
                }.width(100.percent).height(60.0 + getSafeAreaTop()).padding(left: 16, right: 16, top: getSafeAreaTop())
                    .backgroundColor(this.presentation.navBarColor).alignItems(VerticalAlign.Center)

                List {
                    ListItem {
                        Column {
                            Image(@r(app.media.chat_folder_link)).width(112).height(112).objectFit(ImageFit.Contain).margin(top: 14)
                            Text(if (this.selectableCount() == 0) {
                                "There are no chats in this folder that you can share with others."
                            } else if (this.selectedCount() == 0) {
                                "Select chats to share from ${this.folder.name} folder."
                            } else if (this.selectedCount() == 1) {
                                "Anyone with this link can add ${this.folder.name} folder and the chat selected below."
                            } else {
                                "Anyone with this link can add ${this.folder.name} folder and the ${this.selectedCount()} chats selected below."
                            }).fontSize(15).fontColor(this.presentation.secondaryTextColor).textAlign(TextAlign.Center)
                                .padding(left: 28, right: 28).margin(bottom: 18)
                        }.width(100.percent).alignItems(HorizontalAlign.Center)
                    }
                    if (this.selectableCount() > 0) {
                        ListItem {
                            Text(trSource("INVITE LINK")).fontSize(13).fontColor(this.presentation.secondaryTextColor)
                                .padding(left: 16, top: 12, bottom: 7)
                        }
                        ListItem {
                            Row {
                                Column {
                                    if (this.generating) {
                                        Row { LoadingProgress().width(24).height(24).color(this.presentation.accentColor) }
                                            .width(100.percent).height(132).justifyContent(FlexAlign.Center)
                                    } else if (this.hasLink) {
                                        Row {
                                            // iOS ItemListFolderInviteLinkItem：单行 + truncationType .middle。
                                            // 默认断词会在 "addlist/" 后换行，单行时整段 slug 落到被裁掉的第二行，
                                            // 只剩 "t.me/addlist/"；本 SDK 的 Text 不公开 wordBreak/ellipsisMode，
                                            // 放宽到两行，保证 slug 可见。
                                            Text(this.displayLink()).fontSize(16).fontColor(this.presentation.textColor)
                                                .maxLines(2).textOverflow(TextOverflow.Ellipsis)
                                                .layoutWeight(1)
                                            Stack(alignContent: Alignment.Center) {
                                                Row(space: 3) {
                                                    Circle().width(5).height(5).fill(0xFFFFFFFF)
                                                    Circle().width(5).height(5).fill(0xFFFFFFFF)
                                                    Circle().width(5).height(5).fill(0xFFFFFFFF)
                                                }
                                            }.width(32).height(32).borderRadius(16).backgroundColor(0xFFB8BEC6)
                                                .onClick({ _ => this.showLinkMenu = true })
                                        }.width(100.percent).height(54).padding(left: 14, right: 10)
                                            .backgroundColor(itemListPageBackgroundColor()).borderRadius(27)
                                        Row(space: 10) {
                                            Button(trSource("Copy")).fontSize(17).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                                                .backgroundColor(this.presentation.accentColor).borderRadius(24)
                                                .layoutWeight(1).height(48).onClick({ _ => this.copyLink() })
                                            Button(trSource("Share")).fontSize(17).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                                                .backgroundColor(this.presentation.accentColor).borderRadius(24)
                                                .layoutWeight(1).height(48).onClick({ _ => this.shareLink() })
                                        }.width(100.percent).margin(top: 10)
                                    } else {
                                        Text("Could not create an invite link.").fontSize(15)
                                            .fontColor(this.presentation.secondaryTextColor).padding(16)
                                    }
                                }.width(100.percent).padding(12).backgroundColor(itemListCardColor()).borderRadius(14)
                            }.width(100.percent).padding(left: 16, right: 16)
                        }
                    }

                    if (this.selectableCount() == 0) {
                        ListItem {
                            Text(trSource("THESE CHATS CANNOT BE SHARED")).fontSize(13).fontColor(this.presentation.secondaryTextColor)
                                .width(100.percent).padding(left: 16, right: 16, top: 18, bottom: 7)
                        }
                        ListItem {
                            Text(trSource("You can only share groups and channels in which you are allowed to create invite links."))
                                .fontSize(15).fontColor(this.presentation.secondaryTextColor).width(100.percent)
                                .padding(left: 16, right: 16, bottom: 18)
                        }
                    } else {
                        ListItem {
                            Row {
                                Text(if (this.selectedCount() == 0) { "CHATS" } else if (this.selectedCount() == 1) { "1 CHAT SELECTED" } else { "${this.selectedCount()} CHATS SELECTED" })
                                    .fontSize(13).fontColor(this.presentation.secondaryTextColor).layoutWeight(1)
                                if (this.selectableCount() > 1) {
                                    Text(if (this.selectedCount() == this.selectableCount()) { "Deselect All" } else { "Select All" })
                                        .fontSize(13).fontColor(this.presentation.accentColor).onClick({ _ => this.toggleAll() })
                                }
                            }.width(100.percent).padding(left: 16, right: 16, top: 18, bottom: 7)
                        }
                        ForEach(this.peers, itemGenerator: { peer: FolderShareablePeer, index: Int64 =>
                            ListItem {
                                Row {
                                    this.checkMark(peer.isSelected)
                                    Avatar(displayName: peer.title, avatarSize: 40, peerId: peer.peerId)
                                    Column {
                                        Text(peer.title).fontSize(17).fontColor(if (peer.isAvailable) { this.presentation.textColor } else { this.presentation.secondaryTextColor })
                                        Text(if (peer.isAvailable) { "you can invite users here" } else if (peer.peerType == "user") { "users can't be shared" } else { "unavailable" })
                                            .fontSize(13).fontColor(this.presentation.secondaryTextColor).margin(top: 2)
                                    }.layoutWeight(1).margin(left: 12).alignItems(HorizontalAlign.Start)
                                }.width(100.percent).height(58).padding(left: 8, right: 14)
                                    .backgroundColor(itemListCardColor()).opacity(if (peer.isAvailable) { 1.0 } else { 0.55 })
                                    .onClick({ _ => this.togglePeer(index) })
                            }
                        }, keyGenerator: { peer: FolderShareablePeer, _: Int64 =>
                            "${peer.peerId}-${peer.isSelected}"
                        })
                    }
                }.width(100.percent).layoutWeight(1).backgroundColor(itemListPageBackgroundColor())
            }.width(100.percent).height(100.percent).backgroundColor(this.presentation.backgroundColor)
                .padding(bottom: getSafeAreaBottom()).onAppear({ => this.load() })

            if (this.showLinkMenu) {
                Stack(alignContent: Alignment.TopEnd) {
                    Stack {}.width(100.percent).height(100.percent).backgroundColor(0x10000000)
                        .onClick({ _ => this.showLinkMenu = false })
                    Row { this.linkMenu() }.margin(top: 292.0 + getSafeAreaTop(), right: 24)
                }.width(100.percent).height(100.percent)
            }
            if (this.showQrCode) { this.qrCodeOverlay() }
            if (this.showRenamePrompt) { this.renamePromptOverlay() }
        }.width(100.percent).height(100.percent)
    }
}
