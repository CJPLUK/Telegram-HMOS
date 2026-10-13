package ohos_app_cangjie_entry.services

import std.collection.ArrayList
import std.random.Random
import ohos_app_cangjie_entry.models.{Chat, ChatFolder, ChatFolderPeer, ExportedChatFolderLink}

private var _chatFolderDraftService: Option<ChatFolderDraftService> = None

public func getChatFolderDraftService(): ChatFolderDraftService {
    match (_chatFolderDraftService) {
        case Some(value) => value
        case None =>
            let value = ChatFolderDraftService()
            _chatFolderDraftService = Some(value)
            return value
    }
}

public class ChatFolderDraftService {
    private var _draft: Option<ChatFolder> = None
    private var _isNew: Bool = false
    private var _updatedInvite: Option<ExportedChatFolderLink> = None
    private var _selectedInvite: Option<ExportedChatFolderLink> = None
    private var _inviteUpdateListener: (ExportedChatFolderLink) -> Unit = { _: ExportedChatFolderLink => }

    public func beginNew(): ChatFolder {
        this._updatedInvite = None
        this._selectedInvite = None
        let folder = ChatFolder()
        folder.id = this.allocateId()
        folder.filterType = "custom"
        this._draft = Some(folder)
        this._isNew = true
        return folder.copy()
    }

    public func beginExisting(id: Int32): Option<ChatFolder> {
        this._updatedInvite = None
        this._selectedInvite = None
        for (folder in getRealChatListService().getDialogFilters()) {
            if (folder.id == id) {
                let resolved = folder.copy()
                this.resolvePeerPresentation(resolved)
                this._draft = Some(resolved.copy())
                this._isNew = false
                return Some(resolved)
            }
        }
        return None
    }

    private func resolvePeerPresentation(folder: ChatFolder): Unit {
        let chats = getChatListStore().loadLocalChats(0)
        for (peer in folder.includePeerRefs) { this.resolvePeer(peer, chats) }
        for (peer in folder.excludePeerRefs) { this.resolvePeer(peer, chats) }
    }

    private func resolvePeer(peer: ChatFolderPeer, chats: ArrayList<Chat>): Unit {
        for (chat in chats) {
            if (chat.id == peer.id && chat.peerType == peer.peerType) {
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
                return
            }
        }
    }

    public func current(): Option<ChatFolder> {
        match (this._draft) {
            case Some(folder) => Some(folder.copy())
            case None => None
        }
    }

    public func update(folder: ChatFolder): Unit { this._draft = Some(folder.copy()) }
    public func isNew(): Bool { return this._isNew }
    public func clear(): Unit {
        this._draft = None
        this._updatedInvite = None
        this._selectedInvite = None
        this._inviteUpdateListener = { _: ExportedChatFolderLink => }
    }

    public func setUpdatedInvite(link: ExportedChatFolderLink): Unit {
        this._updatedInvite = Some(link)
        this._inviteUpdateListener(link)
    }
    public func updatedInvite(): Option<ExportedChatFolderLink> { return this._updatedInvite }
    public func setInviteUpdateListener(listener: (ExportedChatFolderLink) -> Unit): Unit {
        this._inviteUpdateListener = listener
    }
    public func selectInvite(link: ExportedChatFolderLink): Unit { this._selectedInvite = Some(link) }
    public func clearSelectedInvite(): Unit { this._selectedInvite = None }
    public func selectedInvite(): Option<ExportedChatFolderLink> { return this._selectedInvite }

    public func commitLocal(folder: ChatFolder): Unit {
        let service = getRealChatListService()
        if (this._isNew) {
            service.addDialogFilter(folder.copy())
        } else {
            service.updateDialogFilter(folder.id, folder.copy())
        }
        this._draft = Some(folder.copy())
    }

    private func allocateId(): Int32 {
        let existing = getRealChatListService().getDialogFilters()
        let random = Random()
        var attempts: Int64 = 0
        while (attempts < 254) {
            let candidate = 2 + random.nextInt32(254)
            var used = false
            for (folder in existing) {
                if (folder.id == candidate) { used = true }
            }
            if (!used) { return candidate }
            attempts = attempts + 1
        }
        var candidate: Int32 = 2
        while (candidate < 256) {
            var used = false
            for (folder in existing) {
                if (folder.id == candidate) { used = true }
            }
            if (!used) { return candidate }
            candidate = candidate + 1
        }
        return 255
    }

    public func replaceSelection(kind: String, categories: ArrayList<String>, peers: ArrayList<ChatFolderPeer>): Unit {
        match (this._draft) {
            case Some(folder) =>
                if (kind == "include") {
                    folder.includeContacts = categories.contains("contacts")
                    folder.includeNonContacts = categories.contains("nonContacts")
                    folder.includeGroups = categories.contains("groups")
                    folder.includeChannels = categories.contains("channels")
                    folder.includeBots = categories.contains("bots")
                    folder.includePeers = ArrayList<Int64>()
                    folder.includePeerRefs = ArrayList<ChatFolderPeer>()
                    for (peer in peers) {
                        folder.includePeers.add(peer.id)
                        folder.includePeerRefs.add(peer.copy())
                    }
                    let filtered = ArrayList<ChatFolderPeer>()
                    let filteredIds = ArrayList<Int64>()
                    for (peer in folder.excludePeerRefs) {
                        if (!folder.includePeers.contains(peer.id)) {
                            filtered.add(peer)
                            filteredIds.add(peer.id)
                        }
                    }
                    folder.excludePeerRefs = filtered
                    folder.excludePeers = filteredIds
                } else {
                    folder.excludeMuted = categories.contains("muted")
                    folder.excludeRead = categories.contains("read")
                    folder.excludeArchived = categories.contains("archived")
                    folder.excludePeers = ArrayList<Int64>()
                    folder.excludePeerRefs = ArrayList<ChatFolderPeer>()
                    for (peer in peers) {
                        folder.excludePeers.add(peer.id)
                        folder.excludePeerRefs.add(peer.copy())
                    }
                    let filtered = ArrayList<ChatFolderPeer>()
                    let filteredIds = ArrayList<Int64>()
                    for (peer in folder.includePeerRefs) {
                        if (!folder.excludePeers.contains(peer.id)) {
                            filtered.add(peer)
                            filteredIds.add(peer.id)
                        }
                    }
                    folder.includePeerRefs = filtered
                    folder.includePeers = filteredIds
                }
                this._draft = Some(folder)
            case None => ()
        }
    }
}
