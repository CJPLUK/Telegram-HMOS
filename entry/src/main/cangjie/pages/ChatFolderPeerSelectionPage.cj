package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import std.collection.ArrayList
import ohos_app_cangjie_entry.models.{Chat, ChatFolderPeer}
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.components.Avatar
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.viewmodels.getChatListVM

@HybridComponentEntry
@Component
public class ChatFolderPeerSelectionPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false
    @State var kind: String = "include"
    @State var query: String = ""
    @State var chats: ArrayList<Chat> = ArrayList<Chat>()
    @State var selectedCategories: ArrayList<String> = ArrayList<String>()
    @State var selectedPeers: ArrayList<ChatFolderPeer> = ArrayList<ChatFolderPeer>()
    @State var selectionRevision: Int64 = 0
    @State var contactsSelected: Bool = false
    @State var nonContactsSelected: Bool = false
    @State var groupsSelected: Bool = false
    @State var channelsSelected: Bool = false
    @State var botsSelected: Bool = false
    @State var mutedSelected: Bool = false
    @State var readSelected: Bool = false
    @State var archivedSelected: Bool = false
    @State var isSharedFolder: Bool = false
    // 文件夹 tab 长按 → Add Chats：iOS chatListFilterAddChatsController（applyAutomatically: true，
    // ChatListFilterPresetController.swift:728-730）—— 同一个 Include Chats 选择器，确认即保存到服务端。
    @State var applyAutomatically: Bool = false
    @State var applying: Bool = false
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    private func load(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("ChatFolderPeerSelectionPage")
        this.applyAutomatically = raw == "addChats"
        this.kind = if (raw == "addChats") { "include" } else { raw }
        this.contactsSelected = false
        this.nonContactsSelected = false
        this.groupsSelected = false
        this.channelsSelected = false
        this.botsSelected = false
        this.mutedSelected = false
        this.readSelected = false
        this.archivedSelected = false
        this.selectedCategories = ArrayList<String>()
        this.selectedPeers = ArrayList<ChatFolderPeer>()
        match (getChatFolderDraftService().current()) {
            case Some(folder) =>
                this.isSharedFolder = folder.isShared
                let categories = ArrayList<String>()
                if (this.kind == "include") {
                    this.contactsSelected = folder.includeContacts
                    this.nonContactsSelected = folder.includeNonContacts
                    this.groupsSelected = folder.includeGroups
                    this.channelsSelected = folder.includeChannels
                    this.botsSelected = folder.includeBots
                    if (this.contactsSelected) { categories.add("contacts") }
                    if (this.nonContactsSelected) { categories.add("nonContacts") }
                    if (this.groupsSelected) { categories.add("groups") }
                    if (this.channelsSelected) { categories.add("channels") }
                    if (this.botsSelected) { categories.add("bots") }
                    for (peer in folder.includePeerRefs) { this.selectedPeers.add(peer.copy()) }
                } else {
                    this.mutedSelected = folder.excludeMuted
                    this.readSelected = folder.excludeRead
                    this.archivedSelected = folder.excludeArchived
                    if (this.mutedSelected) { categories.add("muted") }
                    if (this.readSelected) { categories.add("read") }
                    if (this.archivedSelected) { categories.add("archived") }
                    for (peer in folder.excludePeerRefs) { this.selectedPeers.add(peer.copy()) }
                }
                this.selectedCategories = categories
                this.selectionRevision = this.selectionRevision + 1
            case None => ()
        }
        spawn {
            =>
            let values = getRealChatListService().getDialogsLocalFirst(limit: 100)
            spawn(UIThread) { => this.chats = values }
        }
    }

    private func toggleCategory(value: String): Unit {
        if (value == "contacts") { this.contactsSelected = !this.contactsSelected }
        else if (value == "nonContacts") { this.nonContactsSelected = !this.nonContactsSelected }
        else if (value == "groups") { this.groupsSelected = !this.groupsSelected }
        else if (value == "channels") { this.channelsSelected = !this.channelsSelected }
        else if (value == "bots") { this.botsSelected = !this.botsSelected }
        else if (value == "muted") { this.mutedSelected = !this.mutedSelected }
        else if (value == "read") { this.readSelected = !this.readSelected }
        else if (value == "archived") { this.archivedSelected = !this.archivedSelected }
        let updated = ArrayList<String>()
        if (this.contactsSelected) { updated.add("contacts") }
        if (this.nonContactsSelected) { updated.add("nonContacts") }
        if (this.groupsSelected) { updated.add("groups") }
        if (this.channelsSelected) { updated.add("channels") }
        if (this.botsSelected) { updated.add("bots") }
        if (this.mutedSelected) { updated.add("muted") }
        if (this.readSelected) { updated.add("read") }
        if (this.archivedSelected) { updated.add("archived") }
        this.selectedCategories = updated
        this.selectionRevision = this.selectionRevision + 1
    }

    private func peerSelected(chat: Chat): Bool {
        for (peer in this.selectedPeers) {
            if (peer.id == chat.id && peer.peerType == chat.peerType) { return true }
        }
        return false
    }

    private func togglePeer(chat: Chat): Unit {
        let updated = ArrayList<ChatFolderPeer>()
        var found = false
        for (peer in this.selectedPeers) {
            if (peer.id == chat.id && peer.peerType == chat.peerType) { found = true } else { updated.add(peer) }
        }
        if (!found) {
            let peer = ChatFolderPeer()
            peer.id = chat.id
            peer.peerType = chat.peerType
            peer.name = chat.name
            peer.avatarPath = chat.avatarLocalPath
            peer.avatarColor = chat.avatarColor
            peer.isVerified = chat.isVerified
            match (getRealChatListService().getCachedChat(chat.peerType, chat.id)) {
                case Some(value) =>
                    peer.isMigrated = value.isMigrated
                    peer.canShareLink = !value.isMigrated && (value.isCreator || value.canInviteUsers ||
                        (value.isChannel && !value.username.isEmpty() && !value.requestToJoin))
                case None => peer.canShareLink = false
            }
            if (chat.peerType == "channel") { peer.accessHash = getRealMessageService().getAccessHashForChannel(chat.id) }
            if (chat.peerType == "user") { peer.accessHash = getRealMessageService().getAccessHashForUser(chat.id) }
            updated.add(peer)
        }
        this.selectedPeers = updated
        this.selectionRevision = this.selectionRevision + 1
    }

    private func apply(): Unit {
        getChatFolderDraftService().replaceSelection(this.kind, this.selectedCategories, this.selectedPeers)
        if (this.applyAutomatically) {
            this.saveFolderAutomatically()
            return
        }
        this.loaded = false
        routerPop()
    }

    /** Add Chats 模式：把改过的文件夹经 messages.updateDialogFilter 提交，成功后刷新会话列表的文件夹 tab。 */
    private func saveFolderAutomatically(): Unit {
        if (this.applying) { return }
        let draftService = getChatFolderDraftService()
        let folder = match (draftService.current()) {
            case Some(value) => value
            case None =>
                this.loaded = false
                routerPop()
                return
        }
        this.applying = true
        draftService.commitLocal(folder)
        spawn {
            =>
            let ok = getChatFolderLinksService().updateDialogFilter(folder)
            spawn(UIThread) {
                =>
                this.applying = false
                if (ok) {
                    draftService.clear()
                    match (getChatListVM()) {
                        case Some(vm) => vm.loadFilters()
                        case None => ()
                    }
                    this.loaded = false
                    routerPop()
                } else {
                    showToast("Could not save folder. Please try again.")
                }
            }
        }
    }

    private func cancel(): Unit {
        this.loaded = false
        routerPop()
    }

    private func matches(chat: Chat): Bool {
        if (this.query.isEmpty()) { return true }
        return chat.name.toAsciiLower().contains(this.query.toAsciiLower())
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

    private func visibleCategoryKeys(): ArrayList<String> {
        let result = ArrayList<String>()
        if (this.kind == "include" && !this.isSharedFolder) {
            result.add("contacts")
            result.add("nonContacts")
            result.add("groups")
            result.add("channels")
            result.add("bots")
        } else if (this.kind == "exclude") {
            result.add("muted")
            result.add("read")
            result.add("archived")
        }
        return result
    }

    private func categoryTitle(value: String): String {
        if (value == "contacts") { return "Contacts" }
        if (value == "nonContacts") { return "Non-Contacts" }
        if (value == "groups") { return "Groups" }
        if (value == "channels") { return "Channels" }
        if (value == "bots") { return "Bots" }
        if (value == "muted") { return "Muted" }
        if (value == "read") { return "Read" }
        return "Archived"
    }

    private func categoryState(value: String): Bool {
        if (value == "contacts") { return this.contactsSelected }
        if (value == "nonContacts") { return this.nonContactsSelected }
        if (value == "groups") { return this.groupsSelected }
        if (value == "channels") { return this.channelsSelected }
        if (value == "bots") { return this.botsSelected }
        if (value == "muted") { return this.mutedSelected }
        if (value == "read") { return this.readSelected }
        return this.archivedSelected
    }

    @Builder
    func checkMark(selected: Bool, revision: Int64) {
        Stack(alignContent: Alignment.Center) {
            Circle().width(24).height(24).fill(if (selected && revision >= 0) { this.presentation.accentColor } else { Color.Transparent })
                .stroke(if (selected && revision >= 0) { this.presentation.accentColor } else { 0xFFC7C7CC }).strokeWidth(1.5)
            if (selected && revision >= 0) { Text("✓").fontSize(15).fontColor(0xFFFFFFFF).fontWeight(FontWeight.Bold) }
        }.width(34).height(34)
    }

    @Builder
    func categoryIcon(value: String) {
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
        }.width(52).height(48)
    }

    @Builder
    func categoryRow(value: String, title: String, selected: Bool) {
        Row {
            this.categoryIcon(value)
            Text(title).fontSize(17).fontColor(this.presentation.textColor).layoutWeight(1)
            this.checkMark(selected, this.selectionRevision)
        }.width(100.percent).height(50).padding(left: 16, right: 14)
            .backgroundColor(this.presentation.backgroundColor)
    }

    @Builder
    func chatRow(chat: Chat) {
        Row {
            Row {
                Avatar(avatarUrl: chat.avatarLocalPath, displayName: chat.name, avatarSize: 40,
                    avatarColor: chat.avatarColor, peerId: chat.id, letters: chat.avatarText)
            }.width(52).height(48)
            Row {
                Text(chat.name).fontSize(17).fontColor(this.presentation.textColor).maxLines(1).flexShrink(1)
                if (chat.isVerified) { Image(@r(app.media.clist_ic_verified)).width(17).height(17).margin(left: 4) }
            }.layoutWeight(1)
            this.checkMark(this.peerSelected(chat), this.selectionRevision)
        }.width(100.percent).height(50).padding(left: 16, right: 14)
            .backgroundColor(this.presentation.backgroundColor)
    }

    public func build() {
        Column {
            Row {
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.nav_ic_close)).width(22).height(22).fillColor(this.presentation.textColor)
                }.width(44).height(44).borderRadius(22).backgroundColor(this.presentation.cardColor)
                    .onClick({ _ => this.cancel() })
                Blank().layoutWeight(1)
                Text(if (this.kind == "include") { "Include Chats" } else { "Exclude Chats" })
                    .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.username_nav_ic_done)).width(22).height(22).fillColor(this.presentation.accentColor)
                }.width(44).height(44).borderRadius(22).backgroundColor(this.presentation.cardColor)
                    .onClick({ _ => this.apply() })
            }.width(100.percent).height(60.0 + getSafeAreaTop()).padding(left: 16, right: 16, top: getSafeAreaTop())
                .backgroundColor(this.presentation.navBarColor).alignItems(VerticalAlign.Center)

            TextInput(text: this.query, placeholder: trSource("Search Chats"))
                .onChange({ value: String => this.query = value }).height(44).fontSize(16)
                .backgroundColor(0xFFF2F2F7).borderRadius(12).padding(left: 14, right: 14)
                .margin(left: 16, right: 16, top: 8, bottom: 10)

            List {
                if (!(this.kind == "include" && this.isSharedFolder)) {
                    ListItem { Text(trSource("CHAT TYPES")).fontSize(13).fontColor(this.presentation.secondaryTextColor).padding(left: 16, top: 8, bottom: 5) }
                }
                ForEach(this.visibleCategoryKeys(), itemGenerator: { value: String, _: Int64 =>
                    ListItem { this.categoryRow(value, this.categoryTitle(value), this.categoryState(value)) }
                        .onClick({ _ => this.toggleCategory(value) })
                }, keyGenerator: { value: String, _: Int64 => "${value}-${this.selectionRevision}" })
                ListItem { Text(trSource("CHATS")).fontSize(13).fontColor(this.presentation.secondaryTextColor).padding(left: 16, top: 12, bottom: 5) }
                ForEach(this.chats, itemGenerator: { chat: Chat, _: Int64 =>
                    if (this.matches(chat)) {
                        ListItem { this.chatRow(chat) }.onClick({ _ => this.togglePeer(chat) })
                    }
                }, keyGenerator: { chat: Chat, _: Int64 => "${chat.peerType}-${chat.id}-${this.peerSelected(chat)}-${this.selectionRevision}" })
            }.width(100.percent).layoutWeight(1).divider(ListDividerOptions(strokeWidth: 1, color: this.presentation.dividerColor, startMargin: 76, endMargin: 0))
        }.width(100.percent).height(100.percent).backgroundColor(this.presentation.backgroundColor)
            .padding(bottom: getSafeAreaBottom()).onAppear({ => this.load() })
    }
}
