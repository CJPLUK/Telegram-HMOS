package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashMap}
import std.convert.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.Message

/**
 * Saved Messages grouped by source chat ("View as Chats").
 *
 * iOS keeps saved-message topics in Postbox, filled by messages.getSavedDialogs
 * (TelegramCore SavedMessagesTopics / Api42.swift:8148) and opens a topic with
 * messages.getSavedHistory (Api42.swift:8209). Each dialog is keyed by the
 * saved_peer_id of its messages: the original chat for forwards, the account
 * itself ("My Notes") for notes, and 2666000 for hidden authors
 * (PeerUtils.swift:4 anonymousSavedMessagesId).
 */
public let ANONYMOUS_SAVED_MESSAGES_ID: Int64 = 2666000

public class SavedDialogEntry {
    public var peerType: String = "user"
    public var peerId: Int64 = 0
    public var title: String = ""
    public var isBroadcast: Bool = false
    public var isPinned: Bool = false
    public var topMessageId: Int32 = 0
    public var topText: String = ""
    public var topDate: Int64 = 0
    public init() {}

    public func isMyNotes(): Bool {
        return this.peerType == "user" && this.peerId == getCurrentUserId()
    }

    public func isHiddenAuthor(): Bool {
        return this.peerType == "user" && this.peerId == ANONYMOUS_SAVED_MESSAGES_ID
    }

    /** ChatListItem title for saved topics: My Notes / Author Hidden / peer name. */
    public func displayTitle(): String {
        if (this.isMyNotes()) { return "My Notes" }
        if (this.isHiddenAuthor()) { return "Author Hidden" }
        return this.title
    }

    /** ChatChannelSubscriberInputPanelNode actionForPeer (CSP:56-78). */
    public func openActionTitle(): String {
        if (this.peerType == "channel") {
            return if (this.isBroadcast) { "Open Channel" } else { "Open Group" }
        }
        if (this.peerType == "chat") { return "Open Group" }
        return "Open Chat"
    }

    /** CISP:201-221: no subscriber panel for My Notes; hidden authors get a restricted panel. */
    public func hasOpenPanel(): Bool {
        return !this.isMyNotes() && !this.isHiddenAuthor()
    }

    public func encode(): String {
        return "chat|${this.peerType}|${this.peerId}|${if (this.isBroadcast) { 1 } else { 0 }}|${this.title}"
    }

    public static func decode(raw: String): Option<SavedDialogEntry> {
        if (!raw.startsWith("chat|")) { return None<SavedDialogEntry> }
        let parts = raw.split("|")
        if (parts.size < 5) { return None<SavedDialogEntry> }
        let e = SavedDialogEntry()
        e.peerType = parts[1]
        e.peerId = try { Int64.parse(parts[2]) } catch (_: Exception) { 0 }
        e.isBroadcast = parts[3] == "1"
        var title = parts[4]
        var k = 5
        while (k < parts.size) {
            title = title + "|" + parts[k]
            k += 1
        }
        e.title = title
        if (e.peerId == 0) { return None<SavedDialogEntry> }
        return Some(e)
    }
}

private func userDisplayName(user: UserResponse): String {
    var name = user.firstName
    if (user.lastName.size > 0) { name = if (name.size > 0) { name + " " + user.lastName } else { user.lastName } }
    return name
}

private func readTLVectorHeader(d: TLDeserializer): Int32 {
    let ctor = d.readUInt32()
    if (ctor != TLConstructors.VECTOR) {
        throw IllegalArgumentException("[SavedDialogs] expected vector, got ${ctor}")
    }
    return d.readInt32()
}

/**
 * messages.getSavedDialogs → dialogs with titles and top-message previews.
 * savedDialogs#f83ae221 / savedDialogsSlice#44ba9dd9 / savedDialogsNotModified#c01f6fe8
 * (Api0.swift:1579-1581); savedDialog#bd87cb6c flags peer top_message (Api25.swift:179).
 * Blocking; call from spawn.
 */
public func fetchSavedDialogs(): ArrayList<SavedDialogEntry> {
    let result = ArrayList<SavedDialogEntry>()
    try {
        let req = MessagesGetSavedDialogs()
        req.limit = 100
        let data = getMTProtoClient().sendRequest(req.toBytes())
        if (data.size < 8) { return result }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let code = d.readInt32()
            let text = d.readString()
            Hilog.info(0, "CjTelegram", "[SavedDialogs] getSavedDialogs error ${code} ${text}")
            return result
        }
        if (ctor == 0x44ba9dd9) {
            let _ = d.readInt32() // count
        } else if (ctor != 0xf83ae221) {
            Hilog.info(0, "CjTelegram", "[SavedDialogs] unexpected ctor ${ctor}")
            return result
        }
        let dialogCount = readTLVectorHeader(d)
        var i: Int32 = 0
        while (i < dialogCount) {
            let itemCtor = d.readUInt32()
            if (itemCtor == 0xbd87cb6c) {
                let flags = d.readInt32()
                let peer = PeerResponse.deserializeBoxed(d)
                let top = d.readInt32()
                let e = SavedDialogEntry()
                e.peerType = peer.type_
                e.peerId = peer.id
                e.topMessageId = top
                e.isPinned = (flags & (1 << 2)) != 0
                result.add(e)
            } else {
                // monoForumDialog belongs to channel direct messages, never to
                // the account's own Saved Messages; its layout is not skippable
                // without a full DraftMessage parser, so stop here.
                Hilog.info(0, "CjTelegram", "[SavedDialogs] unsupported dialog ctor ${itemCtor}")
                return result
            }
            i += 1
        }
        let topMessages = HashMap<Int32, TLMessage>()
        let msgCount = readTLVectorHeader(d)
        i = 0
        while (i < msgCount) {
            let m = TLMessage.deserializeBoxed(d)
            topMessages[m.id] = m
            i += 1
        }
        let chats = HashMap<Int64, ChatResponse>()
        let chatCount = readTLVectorHeader(d)
        i = 0
        let svc = getRealMessageService()
        while (i < chatCount) {
            let c = ChatResponse.deserializeBoxed(d)
            chats[c.id] = c
            if (c.isChannel && c.accessHash != 0) { svc.cacheChannelAccessHash(c.id, c.accessHash) }
            getUserPhotoService().cacheChat(c)
            i += 1
        }
        let users = HashMap<Int64, UserResponse>()
        let userCount = readTLVectorHeader(d)
        i = 0
        while (i < userCount) {
            let u = UserResponse.deserializeBoxed(d)
            users[u.id] = u
            if (u.accessHash != 0) { svc.cacheUserAccessHash(u.id, u.accessHash) }
            getUserPhotoService().cacheUser(u)
            i += 1
        }
        for (e in result) {
            if (e.peerType == "user") {
                if (users.contains(e.peerId)) { e.title = userDisplayName(users[e.peerId]) }
            } else if (chats.contains(e.peerId)) {
                let c = chats[e.peerId]
                e.title = c.title
                e.isBroadcast = c.isChannel && !c.isMegagroup
            }
            if (topMessages.contains(e.topMessageId)) {
                let m = topMessages[e.topMessageId]
                e.topText = if (m.message.size > 0) { m.message } else { m.mediaDescription }
                e.topDate = Int64(m.date)
            }
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[SavedDialogs] parse failed: ${e}")
    }
    return result
}

/**
 * iOS savedMessagesHasPeersOtherThanSaved (PeerInfoData.swift:585-587):
 * true when any saved topic is keyed by a peer other than the account.
 */
public func savedMessagesHasPeersOtherThanSaved(dialogs: ArrayList<SavedDialogEntry>): Bool {
    for (e in dialogs) {
        if (!e.isMyNotes()) { return true }
    }
    return false
}

/** messages.getSavedHistory for one saved topic, newest first → returned oldest first. Blocking. */
public func fetchSavedHistory(peerType: String, peerId: Int64): ArrayList<Message> {
    let result = ArrayList<Message>()
    try {
        let svc = getRealMessageService()
        let req = MessagesGetSavedHistory()
        req.peer = if (peerType == "user" && peerId == getCurrentUserId()) {
            InputPeerSelf()
        } else {
            svc.buildInputPeer(peerType, peerId)
        }
        req.limit = 50
        let data = getMTProtoClient().sendRequest(req.toBytes())
        if (data.size < 8) { return result }
        let check = TLDeserializer(data)
        let ctor = check.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let code = check.readInt32()
            let text = check.readString()
            Hilog.info(0, "CjTelegram", "[SavedDialogs] getSavedHistory error ${code} ${text}")
            return result
        }
        let resp = MessagesHistoryResponse.deserialize(data)
        let names = HashMap<Int64, String>()
        for (u in resp.users) {
            names[u.id] = userDisplayName(u)
            if (u.accessHash != 0) { svc.cacheUserAccessHash(u.id, u.accessHash) }
            getUserPhotoService().cacheUser(u)
        }
        for (c in resp.chats) {
            if (c.isChannel && c.accessHash != 0) { svc.cacheChannelAccessHash(c.id, c.accessHash) }
            getUserPhotoService().cacheChat(c)
        }
        let me = getCurrentUserId()
        var idx = resp.messages.size - 1
        while (idx >= 0) {
            let tl = resp.messages[idx]
            if (!tl.isEmpty) {
                result.add(svc.parseMessage(tl, me, names, conversationPeerType: "user", conversationPeerId: me))
            }
            idx -= 1
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[SavedDialogs] getSavedHistory failed: ${e}")
    }
    return result
}
