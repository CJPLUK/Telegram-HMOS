package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import std.collection.ArrayList
import std.convert.*
import ohos_app_cangjie_entry.models.{ChatFolder, ChatFolderPeer, FolderShareablePeer, ExportedChatFolderLink}
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.components.{itemListPageBackgroundColor, itemListCardColor}
import ohos_app_cangjie_entry.components.Avatar
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation, getAuthStorage}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.viewmodels.getChatListVM

@HybridComponentEntry
@Component
public class ChatFolderEditorPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false
    @State var folder: ChatFolder = ChatFolder()
    @State var isNew: Bool = true
    @State var saving: Bool = false
    @State var linksLoading: Bool = false
    @State var nameChangedByUser: Bool = false
    @State var inviteLinks: ArrayList<ExportedChatFolderLink> = ArrayList<ExportedChatFolderLink>()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    private func load(): Unit {
        let draftService = getChatFolderDraftService()
        if (!this.loaded) {
            let raw = takePending("ChatFolderEditorPage")
            if (raw == "new") {
                this.folder = draftService.beginNew()
                this.isNew = true
                this.nameChangedByUser = false
            } else {
                try {
                    let id = Int32(Int64.parse(raw))
                    match (draftService.beginExisting(id)) {
                        case Some(value) => this.folder = value
                        case None => this.folder = draftService.beginNew()
                    }
                    this.isNew = draftService.isNew()
                    this.nameChangedByUser = !this.isNew
                } catch (_: Exception) {
                    this.folder = draftService.beginNew()
                    this.isNew = true
                }
            }
            this.loaded = true
            draftService.setInviteUpdateListener({ updated: ExportedChatFolderLink =>
                this.mergeUpdatedInvite(updated)
            })
            if (!this.isNew) { this.fetchLinks() }
        } else {
            match (draftService.current()) {
                case Some(value) =>
                    this.folder = value
                    this.applyAutomaticName()
                case None => ()
            }
            let appliedInviteUpdate = this.applyUpdatedInvite()
            if (!this.isNew && !appliedInviteUpdate) { this.fetchLinks() }
        }
    }

    private func storeDraft(): Unit {
        let snapshot = this.folder.copy()
        this.folder = snapshot
        getChatFolderDraftService().update(snapshot)
    }

    private func inclusionCount(): Int64 {
        var count = this.folder.includePeers.size
        if (this.folder.includeContacts) { count = count + 1 }
        if (this.folder.includeNonContacts) { count = count + 1 }
        if (this.folder.includeGroups) { count = count + 1 }
        if (this.folder.includeChannels) { count = count + 1 }
        if (this.folder.includeBots) { count = count + 1 }
        return count
    }

    private func isComplete(): Bool {
        if (this.folder.name.isEmpty()) { return false }
        if (!this.isNew) { return true }
        if (this.folder.includeContacts && this.folder.includeNonContacts &&
            this.folder.includeGroups && this.folder.includeChannels && this.folder.includeBots &&
            this.folder.excludeArchived && !this.folder.excludeMuted && !this.folder.excludeRead &&
            this.folder.includePeers.isEmpty()) {
            return false
        }
        return this.inclusionCount() > 0
    }

    private func applyAutomaticName(): Unit {
        if (this.nameChangedByUser) { return }
        var count: Int64 = 0
        var value = ""
        if (this.folder.includeContacts) { count = count + 1; value= "Contacts" }
        if (this.folder.includeNonContacts) { count = count + 1; value= "Non-Contacts" }
        if (this.folder.includeGroups) { count = count + 1; value= "Groups" }
        if (this.folder.includeChannels) { count = count + 1; value= "Channels" }
        if (this.folder.includeBots) { count = count + 1; value= "Bots" }
        if (count == 5 && this.folder.excludeRead) { value= "Unread" }
        else if (count == 5 && this.folder.excludeMuted) { value = "Non-Muted" }
        else if (count != 1) { value = "" }
        this.folder.name = value
        this.storeDraft()
    }

    private func openSelection(kind: String): Unit {
        this.storeDraft()
        routerPush("ChatFolderPeerSelectionPage", kind)
    }

    private func save(): Unit {
        if (!this.isComplete() || this.saving) { return }
        this.saving = true
        let saved = this.folder.copy()
        getChatFolderDraftService().commitLocal(saved)
        spawn {
            =>
            let ok = getChatFolderLinksService().updateDialogFilter(saved)
            spawn(UIThread) {
                =>
                this.saving = false
                if (ok) {
                    getChatFolderDraftService().clear()
                    // 会话列表的文件夹 tab 随之刷新（tab 名称 / 包含的会话）
                    match (getChatListVM()) {
                        case Some(vm) => vm.loadFilters()
                        case None => ()
                    }
                    this.loaded = false
                    routerPop()
                } else {
                    if (this.isNew) { getRealChatListService().removeDialogFilter(saved.id) }
                    showToast("Could not save folder. Please try again.")
                }
            }
        }
    }

    private func cancel(): Unit {
        getChatFolderDraftService().clear()
        this.loaded = false
        routerPop()
    }

    private func showMessage(message: String): Unit {
        getUIContext().showAlertDialog(AlertDialogParamWithConfirm(
            message: message,
            confirm: AlertDialogButtonOptions(value: "OK", action: { => () })
        ))
    }

    private func fetchLinks(): Unit {
        this.linksLoading = true
        let id = this.folder.id
        spawn {
            =>
            let links = getChatFolderLinksService().getExportedInvites(id)
            spawn(UIThread) {
                =>
                this.inviteLinks = links
                this.applyUpdatedInvite()
                this.linksLoading = false
            }
        }
    }

    private func applyUpdatedInvite(): Bool {
        match (getChatFolderDraftService().updatedInvite()) {
            case Some(updated) =>
                this.mergeUpdatedInvite(updated)
                return true
            case None => return false
        }
    }

    private func mergeUpdatedInvite(updated: ExportedChatFolderLink): Unit {
        let merged = ArrayList<ExportedChatFolderLink>()
        var replaced = false
        for (value in this.inviteLinks) {
            if (value.url == updated.url) {
                replaced = true
                if (!updated.isRevoked) { merged.add(updated) }
            } else { merged.add(value) }
        }
        if (!replaced && !updated.isRevoked && !updated.url.isEmpty()) { merged.add(updated) }
        this.inviteLinks = merged
    }

    private func shareablePeers(): ArrayList<FolderShareablePeer> {
        let result = ArrayList<FolderShareablePeer>()
        for (ref in this.folder.includePeerRefs) {
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

    private func openInviteLink(link: ExportedChatFolderLink): Unit {
        this.storeDraft()
        getChatFolderDraftService().selectInvite(link)
        routerPush("ChatFolderInviteLinkPage", "")
    }

    private func createInviteLink(): Unit {
        if (this.isNew) {
            this.showMessage("Create this folder before sharing it with others.")
            return
        }
        if (this.inclusionCount() != this.folder.includePeers.size || this.folder.excludeMuted ||
            this.folder.excludeRead || this.folder.excludeArchived || !this.folder.excludePeers.isEmpty()) {
            this.showMessage("You can't share folders which include or exclude specific chat types like 'Groups', 'Contacts', etc.")
            return
        }
        if (this.folder.includePeerRefs.isEmpty()) {
            this.showMessage("You can't share folders which include or exclude specific chat types like 'Groups', 'Contacts', etc.")
            return
        }
        this.storeDraft()
        this.saving = true
        let saved = this.folder.copy()
        let availablePeers = this.shareablePeers()
        spawn {
            =>
            let ok = getChatFolderLinksService().updateDialogFilter(saved)
            var exported = ExportedChatFolderLink()
            var hasAvailablePeer = false
            if (ok) {
                for (peer in availablePeers) {
                    if (peer.isAvailable && peer.isSelected) { hasAvailablePeer = true }
                }
                if (hasAvailablePeer) {
                    exported = getChatFolderLinksService().exportChatlistInvite(saved.id, "", availablePeers)
                }
            }
            let finalExported = exported
            let finalHasAvailablePeer = hasAvailablePeer
            spawn(UIThread) {
                =>
                this.saving = false
                if (!ok) { showToast("Could not save folder. Please try again.") }
                else if (!finalHasAvailablePeer) {
                    getChatFolderDraftService().clearSelectedInvite()
                    routerPush("ChatFolderInviteLinkPage", "")
                } else if (!finalExported.url.isEmpty()) {
                    getChatFolderDraftService().selectInvite(finalExported)
                    getChatFolderDraftService().setUpdatedInvite(finalExported)
                    let sharedFolder = saved.copy()
                    sharedFolder.isShared = true
                    this.folder = sharedFolder
                    getChatFolderDraftService().update(sharedFolder)
                    routerPush("ChatFolderInviteLinkPage", "")
                } else { showToast("Could not create an invite link.") }
            }
        }
    }

    private func chooseColor(value: Int32): Unit {
        match (getAuthStorage().getUserData()) {
            case Some(user) =>
                if (user.isPremium) {
                    this.folder.color = value
                    this.folder.hasColor = value >= 0
                    this.storeDraft()
                } else { routerPush("PremiumPage", "folders") }
            case None => routerPush("PremiumPage", "folders")
        }
    }

    private func isPremiumUser(): Bool {
        match (getAuthStorage().getUserData()) {
            case Some(user) => user.isPremium
            case None => false
        }
    }

    private func hasIncludeSelection(): Bool {
        return this.folder.includeContacts || this.folder.includeNonContacts ||
            this.folder.includeGroups || this.folder.includeChannels || this.folder.includeBots ||
            !this.folder.includePeerRefs.isEmpty()
    }

    private func hasExcludeSelection(): Bool {
        return this.folder.excludeMuted || this.folder.excludeRead || this.folder.excludeArchived ||
            !this.folder.excludePeerRefs.isEmpty()
    }

    private func isLastIncludeCategory(value: String): Bool {
        if (!this.folder.includePeerRefs.isEmpty()) { return false }
        if (value == "contacts") {
            return !this.folder.includeNonContacts && !this.folder.includeGroups && !this.folder.includeChannels && !this.folder.includeBots
        }
        if (value == "nonContacts") { return !this.folder.includeGroups && !this.folder.includeChannels && !this.folder.includeBots }
        if (value == "groups") { return !this.folder.includeChannels && !this.folder.includeBots }
        if (value == "channels") { return !this.folder.includeBots }
        return true
    }

    private func isLastExcludeCategory(value: String): Bool {
        if (!this.folder.excludePeerRefs.isEmpty()) { return false }
        if (value == "muted") { return !this.folder.excludeRead && !this.folder.excludeArchived }
        if (value == "read") { return !this.folder.excludeArchived }
        return true
    }

    @Builder
    func sectionHeader(title: String) {
        Text(title).fontSize(13).fontColor(this.presentation.secondaryTextColor)
            .width(100.percent).padding(left: 16, top: 18, bottom: 7)
    }

    @Builder
    func actionRow(title: String, action: () -> Unit) {
        Row {
            Text("+").fontSize(28).fontColor(this.presentation.accentColor).width(40)
            Text(title).fontSize(17).fontColor(this.presentation.accentColor).layoutWeight(1)
        }
        .width(100.percent).height(52).padding(left: 12, right: 16)
        .backgroundColor(itemListCardColor()).onClick({ _ => action() })
    }

    @Builder
    func selectedPeerRow(peer: ChatFolderPeer, remove: () -> Unit) {
        Row {
            Avatar(avatarUrl: peer.avatarPath, displayName: peer.name, avatarSize: 40,
                avatarColor: peer.avatarColor, peerId: peer.id)
            Row {
                Text(if (peer.name.isEmpty()) { "Chat ${peer.id}" } else { peer.name })
                    .fontSize(17).fontColor(this.presentation.textColor).maxLines(1).flexShrink(1)
                if (peer.isVerified) { Image(@r(app.media.clist_ic_verified)).width(17).height(17).margin(left: 4) }
            }.layoutWeight(1).margin(left: 12)
        }.width(100.percent).height(58).padding(left: 16, right: 16)
    }

    @Builder
    func selectedCategoryRow(value: String, title: String, remove: () -> Unit) {
        Row {
            Stack(alignContent: Alignment.Center) {
                Stack {}.width(40).height(40).borderRadius(12)
                    .linearGradient(angle: 180.0, colors: [(Color(this.categoryLightColor(value)), 0.0), (Color(this.categoryColor(value)), 1.0)])
                if (value == "contacts") { Image(@r(app.media.folder_contacts)).width(40).height(40).fillColor(0xFFFFFFFF) }
                else if (value == "nonContacts") { Image(@r(app.media.folder_noncontacts)).width(40).height(40).fillColor(0xFFFFFFFF) }
                else if (value == "groups") { Image(@r(app.media.folder_groups)).width(40).height(40).fillColor(0xFFFFFFFF) }
                else if (value == "channels") { Image(@r(app.media.folder_channels)).width(40).height(40).fillColor(0xFFFFFFFF) }
                else if (value == "bots") { Image(@r(app.media.folder_bots)).width(40).height(40).fillColor(0xFFFFFFFF) }
                else if (value == "muted") { Image(@r(app.media.folder_muted)).width(40).height(40).fillColor(0xFFFFFFFF) }
                else if (value == "read") { Image(@r(app.media.folder_read)).width(40).height(40).fillColor(0xFFFFFFFF) }
                else { Image(@r(app.media.folder_archived)).width(40).height(40).fillColor(0xFFFFFFFF) }
            }.width(40).height(40)
            Text(title).fontSize(17).fontColor(this.presentation.textColor).layoutWeight(1).margin(left: 12)
        }
        .width(100.percent).height(58).padding(left: 16, right: 16)
    }

    @Builder
    func actionCard(title: String, hasRows: Bool, action: () -> Unit) {
        Row { this.actionRow(title, action) }
            .width(100.percent).padding(left: 16, right: 16)
            .borderRadius(topLeft: 14, topRight: 14,
                bottomLeft: if (hasRows) { 0 } else { 14 }, bottomRight: if (hasRows) { 0 } else { 14 })
            .clip(true)
    }

    @Builder
    func removableCategoryItem(value: String, title: String, isLast: Bool, remove: () -> Unit) {
        ListItem {
            Row {
                Column {
                    Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 16)
                    this.selectedCategoryRow(value, title, remove)
                }.width(100.percent).backgroundColor(itemListCardColor())
                    .borderRadius(bottomLeft: if (isLast) { 14 } else { 0 }, bottomRight: if (isLast) { 14 } else { 0 })
                    .clip(true)
            }.width(100.percent).padding(left: 16, right: 16)
        }
        .swipeAction(end: { =>
            Button(trSource("Remove")).fontSize(14).fontColor(0xFFFFFFFF).backgroundColor(0xFFFF3B30)
                .borderRadius(0).width(84).height(100.percent).onClick({ _ => remove() })
        })
    }

    @Builder
    func removablePeerItem(peer: ChatFolderPeer, isLast: Bool, remove: () -> Unit) {
        ListItem {
            Row {
                Column {
                    Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 16)
                    this.selectedPeerRow(peer, remove)
                }.width(100.percent).backgroundColor(itemListCardColor())
                    .borderRadius(bottomLeft: if (isLast) { 14 } else { 0 }, bottomRight: if (isLast) { 14 } else { 0 })
                    .clip(true)
            }.width(100.percent).padding(left: 16, right: 16)
        }
        .swipeAction(end: { =>
            Button(trSource("Remove")).fontSize(14).fontColor(0xFFFFFFFF).backgroundColor(0xFFFF3B30)
                .borderRadius(0).width(84).height(100.percent).onClick({ _ => remove() })
        })
    }

    private func categoryColor(value: String): UInt32 {
        if (value == "contacts" || value == "read") { return 0xFF2A9EF1 }
        if (value == "nonContacts" || value == "archived") { return 0xFFFFA85C }
        if (value == "groups") { return 0xFF54CB68 }
        if (value == "channels" || value == "muted") { return 0xFFFF516A }
        return 0xFFD669ED
    }

    private func categoryLightColor(value: String): UInt32 {
        if (value == "contacts" || value == "read") { return 0xFF72D5FD }
        if (value == "nonContacts" || value == "archived") { return 0xFFFFCD6A }
        if (value == "groups") { return 0xFFA0DE7E }
        if (value == "channels" || value == "muted") { return 0xFFFF885E }
        return 0xFFE0A2F3
    }

    private func removeIncludeCategory(name: String): Unit {
        if (name == "contacts") { this.folder.includeContacts = false }
        if (name == "nonContacts") { this.folder.includeNonContacts = false }
        if (name == "groups") { this.folder.includeGroups = false }
        if (name == "channels") { this.folder.includeChannels = false }
        if (name == "bots") { this.folder.includeBots = false }
        this.storeDraft()
    }

    private func removeExcludeCategory(name: String): Unit {
        if (name == "muted") { this.folder.excludeMuted = false }
        if (name == "read") { this.folder.excludeRead = false }
        if (name == "archived") { this.folder.excludeArchived = false }
        this.storeDraft()
    }

    private func removePeer(kind: String, id: Int64): Unit {
        let refs = ArrayList<ChatFolderPeer>()
        let ids = ArrayList<Int64>()
        let source = if (kind == "include") { this.folder.includePeerRefs } else { this.folder.excludePeerRefs }
        for (peer in source) {
            if (peer.id != id) { refs.add(peer); ids.add(peer.id) }
        }
        if (kind == "include") { this.folder.includePeerRefs = refs; this.folder.includePeers = ids }
        else { this.folder.excludePeerRefs = refs; this.folder.excludePeers = ids }
        this.storeDraft()
    }

    @Builder
    func colorDot(value: Int32, color: UInt32) {
        Stack(alignContent: Alignment.Center) {
            Circle().width(32).height(32).fill(color)
            if (this.isPremiumUser() && this.folder.color == value) {
                Circle().width(40).height(40).fill(itemListCardColor()).stroke(color).strokeWidth(2)
                Circle().width(24).height(24).fill(color)
            }
        }.width(42).height(48).onClick({ _ => this.chooseColor(value) })
    }

    @Builder
    func emptyColorDot() {
        Stack(alignContent: Alignment.Center) {
            Circle().width(32).height(32).fill(0xFF798896)
            if (!this.isPremiumUser() || this.folder.color < 0) {
                Circle().width(40).height(40).fill(itemListCardColor()).stroke(0xFF798896).strokeWidth(2)
                Circle().width(24).height(24).fill(0xFF798896)
            }
            if (!this.isPremiumUser()) {
                Image(@r(app.media.misc_ic_premiumlock)).width(18).height(18).fillColor(itemListCardColor())
            } else {
                Image(@r(app.media.media_ic_close)).width(14).height(14).fillColor(itemListCardColor())
            }
        }.width(42).height(48).onClick({ _ => this.chooseColor(-1) })
    }

    public func build() {
        Column {
            Row {
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.nav_ic_close)).width(22).height(22).fillColor(this.presentation.textColor)
                }.width(44).height(44).borderRadius(22).backgroundColor(this.presentation.cardColor)
                    .onClick({ _ => this.cancel() })
                Blank().layoutWeight(1)
                Text(if (this.isNew) { "New Folder" } else { "Edit Folder" })
                    .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.username_nav_ic_done)).width(22).height(22)
                        .fillColor(if (this.isComplete()) { this.presentation.accentColor } else { 0xFFB8BEC6 })
                }.width(44).height(44).borderRadius(22).backgroundColor(this.presentation.cardColor)
                    .onClick({ _ => this.save() })
            }.width(100.percent).height(60.0 + getSafeAreaTop()).padding(left: 16, right: 16, top: getSafeAreaTop())
                .backgroundColor(this.presentation.navBarColor).alignItems(VerticalAlign.Center)

            List {
                if (this.isNew) {
                    ListItem {
                        Row {
                            Image(@r(app.media.chat_folder_new)).width(96).height(96).objectFit(ImageFit.Contain)
                        }.width(100.percent).justifyContent(FlexAlign.Center).margin(top: 8, bottom: 2)
                    }
                }
                ListItem { this.sectionHeader("FOLDER NAME") }
                ListItem {
                    Row {
                        Row {
                            TextInput(text: this.folder.name, placeholder: trSource("Folder Name"))
                                .onChange({ value: String => this.folder.name = value; this.nameChangedByUser = true; this.storeDraft() })
                                .maxLength(12)
                                .fontSize(17).fontColor(this.presentation.textColor).height(52).layoutWeight(1)
                                .padding(left: 16)
                            Image(@r(app.media.chatroom_ic_emoji)).width(24).height(24)
                                .fillColor(this.presentation.secondaryTextColor).margin(right: 16)
                        }.height(52).width(100.percent).backgroundColor(itemListCardColor()).borderRadius(14)
                    }.width(100.percent).padding(left: 16, right: 16)
                }

                ListItem { this.sectionHeader("INCLUDED CHATS") }
                ListItem {
                    this.actionCard("Add Chats", this.hasIncludeSelection(), { => this.openSelection("include") })
                }
                if (this.folder.includeContacts) { this.removableCategoryItem("contacts", "Contacts", this.isLastIncludeCategory("contacts"), { => this.removeIncludeCategory("contacts") }) }
                if (this.folder.includeNonContacts) { this.removableCategoryItem("nonContacts", "Non-Contacts", this.isLastIncludeCategory("nonContacts"), { => this.removeIncludeCategory("nonContacts") }) }
                if (this.folder.includeGroups) { this.removableCategoryItem("groups", "Groups", this.isLastIncludeCategory("groups"), { => this.removeIncludeCategory("groups") }) }
                if (this.folder.includeChannels) { this.removableCategoryItem("channels", "Channels", this.isLastIncludeCategory("channels"), { => this.removeIncludeCategory("channels") }) }
                if (this.folder.includeBots) { this.removableCategoryItem("bots", "Bots", this.isLastIncludeCategory("bots"), { => this.removeIncludeCategory("bots") }) }
                ForEach(this.folder.includePeerRefs, itemGenerator: { peer: ChatFolderPeer, idx: Int64 =>
                    this.removablePeerItem(peer, idx == this.folder.includePeerRefs.size - 1, { => this.removePeer("include", peer.id) })
                })
                ListItem { Text("Choose chats or types of chats that will appear in this folder.").fontSize(13).fontColor(this.presentation.secondaryTextColor).padding(left: 16, right: 16, top: 8) }

                if (!this.folder.isShared) {
                    ListItem { this.sectionHeader("EXCLUDED CHATS") }
                    ListItem {
                        this.actionCard("Add Chats to Exclude", this.hasExcludeSelection(), { => this.openSelection("exclude") })
                    }
                    if (this.folder.excludeMuted) { this.removableCategoryItem("muted", "Muted", this.isLastExcludeCategory("muted"), { => this.removeExcludeCategory("muted") }) }
                    if (this.folder.excludeRead) { this.removableCategoryItem("read", "Read", this.isLastExcludeCategory("read"), { => this.removeExcludeCategory("read") }) }
                    if (this.folder.excludeArchived) { this.removableCategoryItem("archived", "Archived", this.isLastExcludeCategory("archived"), { => this.removeExcludeCategory("archived") }) }
                    ForEach(this.folder.excludePeerRefs, itemGenerator: { peer: ChatFolderPeer, idx: Int64 =>
                        this.removablePeerItem(peer, idx == this.folder.excludePeerRefs.size - 1, { => this.removePeer("exclude", peer.id) })
                    })
                    ListItem { Text("Choose chats or types of chats that will not appear in this folder.").fontSize(13).fontColor(this.presentation.secondaryTextColor).padding(left: 16, right: 16, top: 8) }
                }

                ListItem {
                    Row {
                        Text(trSource("FOLDER COLOR")).fontSize(13).fontColor(this.presentation.secondaryTextColor).layoutWeight(1)
                        if (!this.isPremiumUser() && this.folder.color >= 0) {
                            Text(trSource("PREMIUM EXPIRED")).fontSize(13).fontColor(this.presentation.secondaryTextColor)
                        }
                    }.width(100.percent).padding(left: 16, right: 16, top: 18, bottom: 7)
                }
                ListItem {
                    Row {
                        Row {
                            this.colorDot(0, 0xFF3B91D6); this.colorDot(1, 0xFF36AE24); this.colorDot(2, 0xFFE47E15)
                            this.colorDot(3, 0xFFD65048); this.colorDot(4, 0xFF9257DD); this.colorDot(5, 0xFF36A4BD); this.colorDot(6, 0xFFC94B86)
                            this.emptyColorDot()
                        }.width(100.percent).height(52).padding(left: 8, right: 8).backgroundColor(itemListCardColor())
                            .justifyContent(FlexAlign.SpaceBetween).borderRadius(14)
                    }.width(100.percent).padding(left: 16, right: 16)
                }
                ListItem { Text("This color will be used for the folder's tag in the chat list.").fontSize(13).fontColor(this.presentation.secondaryTextColor).padding(left: 16, right: 16, top: 8) }

                ListItem { this.sectionHeader("SHARE FOLDER") }
                ListItem {
                    Row {
                        Column {
                            Row {
                                Image(@r(app.media.chatroom_ic_link)).width(24).height(24).fillColor(this.presentation.accentColor).width(40)
                                Text(if (this.inviteLinks.isEmpty()) { "Create an Invite Link" } else { "Create a new Link" })
                                    .fontSize(17).fontColor(this.presentation.accentColor).layoutWeight(1)
                            }.width(100.percent).height(52).padding(left: 12, right: 16)
                                .backgroundColor(itemListCardColor()).onClick({ _ => this.createInviteLink() })
                        ForEach(this.inviteLinks, itemGenerator: { link: ExportedChatFolderLink, _: Int64 =>
                            Divider().margin(left: 16)
                            Column {
                                Text(if (link.title.isEmpty()) {
                                    if (link.url.startsWith("https://")) { link.url[8..link.url.size] } else { link.url }
                                } else { link.title }).fontSize(16).fontColor(this.presentation.textColor).maxLines(1)
                                Text("includes ${link.peerIds.size} ${if (link.peerIds.size == 1) { "chat" } else { "chats" }}")
                                    .fontSize(13).fontColor(this.presentation.secondaryTextColor).maxLines(1)
                            }.width(100.percent).padding(left: 16, right: 16, top: 8, bottom: 8).alignItems(HorizontalAlign.Start)
                                .onClick({ _ => this.openInviteLink(link) })
                        })
                        }.width(100.percent).borderRadius(14).clip(true)
                    }.width(100.percent).padding(left: 16, right: 16)
                }
                ListItem { Text(if (this.inviteLinks.isEmpty()) { "Share access to some of this folder's groups and channels with others." } else { "Create more links to set up different access levels for different people." }).fontSize(13).fontColor(this.presentation.secondaryTextColor).padding(left: 16, right: 16, top: 8, bottom: 28) }
            }.width(100.percent).layoutWeight(1).backgroundColor(itemListPageBackgroundColor())
        }.width(100.percent).height(100.percent).backgroundColor(this.presentation.backgroundColor)
            .padding(bottom: getSafeAreaBottom())
            .onVisibleAreaChange([0.0, 1.0], { visible: Bool, ratio: Float64 =>
                if (visible && ratio > 0.9) { this.load() }
            })
            .onAppear({ => this.load() })
    }
}
