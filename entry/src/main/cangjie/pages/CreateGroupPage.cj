package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.providers.getPeersDataProvider
import ohos_app_cangjie_entry.viewmodels.getChatListVM
import ohos_app_cangjie_entry.components.{SelectablePeerComponent, SelectedPeerChip, SearchBar, PhotoPicker, SelectedPhoto}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * New Group flow aligned with Telegram-iOS:
 * ContactMultiselectionController -> CreateGroupController ->
 * engine.peers.createGroup -> stateManager.addUpdates -> ChatController.
 */
@HybridComponentEntry
@Component
public class CreateGroupPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var stage: Int32 = 1
    @State var contacts: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    @State var selectedUserIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var groupName: String = ""
    @State var searchText: String = ""
    @State var isLoading: Bool = false
    @State var loaded: Bool = false
    @State var errorText: String = ""
    @State var avatarUri: String = ""
    @State var showPhotoPicker: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadContacts()
    }

    private func loadContacts(): Unit {
        this.isLoading = true
        spawn {
            try {
                let list = getRealContactService().getContacts()
                launch {
                    this.contacts = list
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[CreateGroupPage] load contacts failed: ${e}")
                launch {
                    this.isLoading = false
                    this.errorText = "Could not load contacts"
                }
            }
        }
    }

    private func isSelected(userId: Int64): Bool {
        for (id in this.selectedUserIds) {
            if (id == userId) { return true }
        }
        return false
    }

    private func toggleSelection(userId: Int64): Unit {
        let updated = ArrayList<Int64>()
        var found = false
        for (id in this.selectedUserIds) {
            if (id == userId) { found = true } else { updated.add(id) }
        }
        if (!found) { updated.add(userId) }
        this.selectedUserIds = updated
        this.errorText = ""
    }

    private func removeFromSelection(userId: Int64): Unit {
        let updated = ArrayList<Int64>()
        for (id in this.selectedUserIds) {
            if (id != userId) { updated.add(id) }
        }
        this.selectedUserIds = updated
    }

    private func findContactById(userId: Int64): Option<ContactDisplayData> {
        for (contact in this.contacts) {
            if (contact.userId == userId) { return Some(contact) }
        }
        return None
    }

    private func displayName(userId: Int64): String {
        match (this.findContactById(userId)) {
            case Some(contact) => contact.getDisplayName()
            case None => "User ${userId}"
        }
    }

    private func avatarColor(userId: Int64): Int64 {
        return Int64(getAvatarColorForPeer(userId))
    }

    private func selectedCountTitle(): String {
        if (this.selectedUserIds.isEmpty()) { return "New Group" }
        return "New Group  ${this.selectedUserIds.size}/200"
    }

    private func goBack(): Unit {
        if (this.stage == 2 && !this.isLoading) {
            this.stage = 1
            this.errorText = ""
        } else if (!this.isLoading) {
            routerPop()
        }
    }

    private func goNext(): Unit {
        this.stage = 2
        this.errorText = ""
    }

    private func findCreatedChatId(title: String): Int64 {
        let dialogs = getRealChatListService().getDialogs(limit: 100)
        for (chat in dialogs) {
            if (chat.peerType == "chat" && chat.name == title) { return chat.id }
        }
        return 0
    }

    private func uploadPendingAvatar(peerId: Int64, uri: String): Unit {
        if (peerId <= 0 || uri.isEmpty()) { return }
        var path = uri
        if (path.startsWith("file://")) { path = path[7..] }
        try {
            let bytes = getLegacyMediaPickerService().readFileBytes(path)
            if (!bytes.isEmpty()) {
                let _ = getRealMessageService().editBasicGroupPhoto(peerId, bytes)
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CreateGroupPage] avatar update skipped: ${e}")
        }
    }

    private func createGroup(): Unit {
        if (this.isLoading || this.groupName.isEmpty()) { return }
        if (this.selectedUserIds.isEmpty()) {
            this.errorText = "Choose at least one member"
            return
        }

        this.isLoading = true
        this.errorText = ""
        let title = this.groupName
        let avatar = this.avatarUri
        let members = ArrayList<(Int64, Int64)>()
        for (userId in this.selectedUserIds) {
            match (this.findContactById(userId)) {
                case Some(contact) =>
                    if (contact.accessHash == 0) {
                        this.isLoading = false
                        this.errorText = "One or more selected members could not be resolved"
                        return
                    }
                    members.add((userId, contact.accessHash))
                case None =>
                    this.isLoading = false
                    this.errorText = "One or more selected members could not be resolved"
                    return
            }
        }

        spawn {
            let result = getPeersDataProvider().createGroup(title, members)
            if (!result.success) {
                let error = result.errorMessage
                launch {
                    this.isLoading = false
                    this.errorText = error
                }
                return
            }

            var peerId = result.peerId
            if (peerId <= 0) { peerId = this.findCreatedChatId(title) }
            if (peerId <= 0) {
                launch {
                    this.isLoading = false
                    this.errorText = "Group was created, but it could not be opened. Return to Chats to find it."
                }
                return
            }

            this.uploadPendingAvatar(peerId, avatar)
            match (getChatListVM()) {
                case Some(vm) => launch { vm.refreshWithPullDown() }
                case None => ()
            }
            let createdPeerId = peerId
            launch {
                this.isLoading = false
                setSelectedChat(createdPeerId, title, "chat")
                setSelectedChatDraft("")
                setSelectedChatUsername("")
                routerReplaceTop("ChatRoomPage", "")
            }
        }
    }

    private func matchesSearch(contact: ContactDisplayData): Bool {
        if (this.searchText.isEmpty()) { return true }
        let query = this.searchText
        return containsIgnoreCase2(contact.getDisplayName(), query) ||
            containsIgnoreCase2(contact.username, query) || contact.phone.contains(query)
    }

    @Builder
    private func buildHeader() {
        Row {
            Text("‹")
                .fontSize(38)
                .fontColor(0x007AFF)
                .width(52)
                .height(52)
                .textAlign(TextAlign.Center)
                .onClick({ _ => this.goBack() })
            Text(if (this.stage == 1) { this.selectedCountTitle() } else { "New Group" })
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
            Stack(alignContent: Alignment.Center) {
                if (this.isLoading && this.stage == 2) {
                    LoadingProgress().width(20).height(20).color(0x007AFF)
                } else {
                    Text(if (this.stage == 1) { "Next" } else { "Create" })
                        .fontSize(17)
                        .fontWeight(if (this.stage == 2) { FontWeight.Bold } else { FontWeight.Medium })
                        .fontColor(if (this.stage == 2 && this.groupName.isEmpty()) { 0xC7C7CC } else { 0x007AFF })
                }
            }
            .width(68)
            .height(52)
            .onClick({ _ =>
                if (this.stage == 1) { this.goNext() } else { this.createGroup() }
            })
        }
        .width(100.percent)
        .height(52)
        .padding(right: 4)
        .backgroundColor(0xF9F9F9)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    private func buildSelectedChips() {
        if (!this.selectedUserIds.isEmpty()) {
            Scroll {
                Row {
                    ForEach(this.selectedUserIds, itemGenerator: { userId: Int64, _index: Int64 =>
                        Column {
                            SelectedPeerChip(
                                peerId: userId,
                                displayName: this.displayName(userId),
                                avatarUrl: getUserPhotoService().getUserPhotoPath(userId),
                                avatarColor: this.avatarColor(userId),
                                onRemove: { id: Int64 => this.removeFromSelection(id) }
                            )
                        }
                    })
                }.padding(left: 8, right: 8)
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width(100.percent)
            .height(88)
            Divider().strokeWidth(0.5).color(0xD9D9D9)
        }
    }

    @Builder
    private func buildMemberSelection() {
        Column {
            this.buildSelectedChips()
            Column {
                SearchBar(
                    loading: false,
                    backArrow: false,
                    text: this.searchText,
                    hint: "Add People",
                    onChange: { value: String => this.searchText = value }
                )
            }
            .width(100.percent)
            .padding(left: 10, right: 10, top: 8, bottom: 8)

            if (this.isLoading) {
                Column {
                    LoadingProgress().width(30).height(30).color(0x007AFF)
                }
                .layoutWeight(1)
                .width(100.percent)
                .justifyContent(FlexAlign.Center)
            } else {
                List {
                    ForEach(this.contacts, itemGenerator: { contact: ContactDisplayData, _index: Int64 =>
                        if (this.matchesSearch(contact)) {
                            ListItem {
                                SelectablePeerComponent(
                                    peerId: contact.userId,
                                    displayName: contact.getDisplayName(),
                                    avatarUrl: getUserPhotoService().getUserPhotoPath(contact.userId),
                                    avatarColor: Int64(getAvatarColorForPeer(contact.userId)),
                                    isOnline: contact.isOnline,
                                    isSelected: this.isSelected(contact.userId),
                                    compact: true,
                                    onToggleSelection: { id: Int64 => this.toggleSelection(id) }
                                )
                            }
                        }
                    })
                }
                .width(100.percent)
                .layoutWeight(1)
                .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xD9D9D9, startMargin: 76, endMargin: 0))
            }
        }
        .width(100.percent)
        .layoutWeight(1)
        .backgroundColor(0xFFFFFF)
    }

    @Builder
    private func buildGroupInfo() {
        Stack {
            Column {
                Row {
                    Stack(alignContent: Alignment.Center) {
                        if (!this.avatarUri.isEmpty()) {
                            Image(this.avatarUri)
                                .width(72).height(72)
                                .objectFit(ImageFit.Cover)
                                .borderRadius(36)
                        } else {
                            Column {
                                Text("📷").fontSize(27)
                            }
                            .width(72).height(72)
                            .borderRadius(36)
                            .backgroundColor(0x5AC8FA)
                            .justifyContent(FlexAlign.Center)
                        }
                    }
                    .width(72).height(72)
                    .margin(right: 14)
                    .onClick({ _ => this.showPhotoPicker = true })

                    TextInput(placeholder: trSource("Group Name"), text: this.groupName)
                        .layoutWeight(1)
                        .height(52)
                        .fontSize(17)
                        .backgroundColor(Color.Transparent)
                        .onChange({ value: String =>
                            this.groupName = value
                            this.errorText = ""
                        })
                }
                .width(100.percent)
                .height(104)
                .padding(left: 16, right: 16)
                .backgroundColor(0xFFFFFF)
                .alignItems(VerticalAlign.Center)

                if (!this.errorText.isEmpty()) {
                    Text(this.errorText)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .fontSize(13)
                        .fontColor(0xFF3B30)
                        .backgroundColor(0xFFFFFF)
                }

                Text("${this.selectedUserIds.size} MEMBERS")
                    .width(100.percent)
                    .padding(left: 16, top: 22, bottom: 7)
                    .fontSize(13)
                    .fontColor(0x6D6D72)

                List {
                    ForEach(this.selectedUserIds, itemGenerator: { userId: Int64, _index: Int64 =>
                        ListItem {
                            Row {
                                Stack(alignContent: Alignment.Center) {
                                    Text(this.memberInitial(userId))
                                        .fontSize(18).fontColor(0xFFFFFF)
                                }
                                .width(42).height(42).borderRadius(21)
                                .backgroundColor(UInt32(this.avatarColor(userId)))
                                .margin(right: 12)
                                Column {
                                    Text(this.displayName(userId)).fontSize(17).fontColor(0x000000)
                                    Text("member").fontSize(14).fontColor(0x8E8E93).margin(top: 2)
                                }.alignItems(HorizontalAlign.Start)
                            }
                            .width(100.percent).height(60)
                            .padding(left: 16, right: 16)
                            .backgroundColor(0xFFFFFF)
                        }
                    })
                }
                .width(100.percent)
                .layoutWeight(1)
                .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xD9D9D9, startMargin: 70, endMargin: 0))
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xF2F2F7)

            if (this.showPhotoPicker) {
                Column {}.width(100.percent).height(100.percent)
                    .backgroundColor(0x33000000)
                    .onClick({ _ => this.showPhotoPicker = false })
                Column {
                    PhotoPicker(
                        maxSelect: 1,
                        onSelect: { photos: ArrayList<SelectedPhoto> =>
                            this.showPhotoPicker = false
                            if (!photos.isEmpty()) { this.avatarUri = photos[0].uri }
                        },
                        onClose: { => this.showPhotoPicker = false }
                    )
                }
                .width(100.percent)
                .position(x: 0, y: 30.percent)
            }
        }
        .width(100.percent)
        .layoutWeight(1)
    }

    public func build() {
        Column {
            this.buildHeader()
            Divider().strokeWidth(0.5).color(0xD9D9D9)
            if (this.stage == 1) {
                this.buildMemberSelection()
            } else {
                this.buildGroupInfo()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }

    private func memberInitial(userId: Int64): String {
        match (this.findContactById(userId)) {
            case Some(contact) => contact.getInitial()
            case None => "?"
        }
    }
}

func containsIgnoreCase2(text: String, query: String): Bool {
    return query.isEmpty() || text.toAsciiLower().contains(query.toAsciiLower())
}
