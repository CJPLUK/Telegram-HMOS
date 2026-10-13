package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashMap, HashSet}
import std.sync.*
import std.time.DateTime
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.utils.{formatClockHHMM, localDayIndexOf, formatShortDateSlashed}

/**
 * Data behind two iOS message context-menu entries that need server state:
 *
 * - The read report row (ChatReadReportContextItem, iOS
 *   ChatInterfaceStateContextMenus.swift:195-285 canViewReadStats and
 *   :3500-3620 layout). Private chats show "read today at HH:MM"
 *   (messages.getOutboxReadDate, TelegramCore MessageReadStats.swift:29-43);
 *   groups show "N Seen" / "N Listened" (messages.getMessageReadParticipants).
 * - "Save for Notifications" (ChatInterfaceStateContextMenus.swift:1102-1140):
 *   account.saveRingtone with the message document.
 */
public class MessageReadStatsSnapshot {
    public var isPrivate: Bool = false
    /** Private chat: outbox read date; 0 when the server refused (read time hidden). */
    public var readDate: Int32 = 0
    /** Group readers with resolved display names. */
    public var peers: ArrayList<ReadParticipantRecord> = ArrayList<ReadParticipantRecord>()
    /** Private voice/round message: server-confirmed listened state. */
    public var consumed: Bool = true
    public init() {}
}

private let _extrasLock = ReentrantMutex()
private var _readMarkSizeThreshold: Int64 = 50
private var _pmReadDateExpire: Int64 = 7 * 86400
private var _chatReadMarkExpire: Int64 = 7 * 86400
private var _appConfigLoaded: Bool = false
private var _appConfigLoading: Bool = false
private var _savedToneIds: Option<HashSet<Int64>> = None<HashSet<Int64>>
private var _savedTonesLoading: Bool = false

private func readConfigInt(configJson: String, key: String, fallback: Int64): Int64 {
    if (configJson.size == 0) { return fallback }
    try {
        let obj = JsonParser.parseObject(configJson)
        if (!obj.has(key)) { return fallback }
        let v = obj.getInt(key)
        if (v <= 0) { return fallback }
        return v
    } catch (_: Exception) {
        return fallback
    }
}

/**
 * iOS reads chat_read_mark_size_threshold / pm_read_date_expire_period /
 * chat_read_mark_expire_period from AppConfiguration (defaults 50, 7 days).
 * Loaded once in the background; until then the iOS defaults apply.
 */
public func prefetchMessageContextConfig(): Unit {
    synchronized(_extrasLock) {
        if (_appConfigLoaded || _appConfigLoading) { return }
        _appConfigLoading = true
    }
    spawn {
        var json = ""
        try {
            match (getTelegramEngineDataService().getAppConfig()) {
                case Some(cfg) => json = cfg.configJson
                case None => ()
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[MsgCtxExtras] appConfig failed: ${e}")
        }
        let size = readConfigInt(json, "chat_read_mark_size_threshold", 50)
        let pm = readConfigInt(json, "pm_read_date_expire_period", 7 * 86400)
        let chat = readConfigInt(json, "chat_read_mark_expire_period", 7 * 86400)
        synchronized(_extrasLock) {
            _readMarkSizeThreshold = size
            _pmReadDateExpire = pm
            _chatReadMarkExpire = chat
            _appConfigLoaded = json.size > 0
            _appConfigLoading = false
        }
    }
}

/**
 * Synchronous part of iOS canViewReadStats (CSM:195-285) that can be decided
 * from the message and cached peer data. The participant-count limit of
 * groups needs a fetch and is checked again in loadMessageReadStats.
 */
public func canShowMessageReadStats(message: Message, peerType: String, peerId: Int64, isBroadcast: Bool): Bool {
    if (!message.isSent || message.id <= 0) { return false }
    if (message.status != "read") { return false }
    if (message.messageType == "service" || message.isCallMessage) { return false }
    let currentUserId = getCurrentUserId()
    var expire: Int64 = 0
    synchronized(_extrasLock) {
        expire = if (peerType == "user") { _pmReadDateExpire } else { _chatReadMarkExpire }
    }
    if (peerType == "user") {
        if (peerId == currentUserId) { return false }
        match (getUserPhotoService().getCachedUser(peerId)) {
            case Some(user) =>
                if (user.isBot || user.isSupport) { return false }
            case None => ()
        }
    } else if (peerType == "channel") {
        if (isBroadcast) { return false }
    } else if (peerType != "chat") {
        return false
    }
    let now = DateTime.now().toUnixTimeStamp().toSeconds()
    if (message.rawTimestamp + expire < now) { return false }
    return true
}

private func isConsumableMedia(message: Message): Bool {
    return message.messageType == "voice" || message.messageType == "video_note"
}

private func resolveUserName(userId: Int64, fallbackNames: HashMap<Int64, String>): String {
    match (getUserPhotoService().getCachedUser(userId)) {
        case Some(user) =>
            var name = user.firstName
            if (user.lastName.size > 0) { name = if (name.size > 0) { name + " " + user.lastName } else { user.lastName } }
            if (name.size > 0) { return name }
        case None => ()
    }
    if (fallbackNames.contains(userId)) { return fallbackNames[userId] }
    return ""
}

/** users.getUsers for readers that are not in any local cache. */
private func fetchUserNames(ids: ArrayList<Int64>): HashMap<Int64, String> {
    let result = HashMap<Int64, String>()
    if (ids.isEmpty()) { return result }
    try {
        let svc = getRealMessageService()
        let request = UsersGetUsers()
        for (id in ids) {
            let input = InputUser()
            input.userId = id
            input.accessHash = svc.getAccessHashForUser(id)
            request.ids.add(input)
        }
        let data = getMTProtoClient().sendRequest(request.toBytes())
        let d = TLDeserializer(data)
        if (d.readUInt32() != 0x1cb5c415) { return result }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            let user = UserResponse.deserializeBoxed(d)
            getUserPhotoService().cacheUser(user)
            var name = user.firstName
            if (user.lastName.size > 0) { name = if (name.size > 0) { name + " " + user.lastName } else { user.lastName } }
            result[user.id] = name
            i += 1
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[MsgCtxExtras] users.getUsers failed: ${e}")
    }
    return result
}

private func participantCountFor(peerType: String, peerId: Int64): Int64 {
    match (getRealChatListService().getCachedChat(peerType, peerId)) {
        case Some(chat) =>
            if (chat.participantsCount > 0) { return Int64(chat.participantsCount) }
        case None => ()
    }
    try {
        let full = getRealMessageService().getFullChatInfo(peerType, peerId)
        if (full.membersCount > 0) { return Int64(full.membersCount) }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[MsgCtxExtras] full chat failed: ${e}")
    }
    return -1
}

/** Re-reads media_unread for one message (iOS keeps it current via updateReadMessagesContents). */
private func refetchMediaUnread(peerType: String, peerId: Int64, msgId: Int64): Option<Bool> {
    try {
        let ids = ArrayList<Int32>()
        ids.add(Int32(msgId))
        let svc = getRealMessageService()
        let data = if (peerType == "channel") {
            svc.getChannelMessages(peerId, svc.getAccessHashForChannel(peerId), ids)
        } else {
            svc.getMessagesByIds(ids)
        }
        if (data.size < 8) { return None<Bool> }
        let resp = MessagesHistoryResponse.deserialize(data)
        for (m in resp.messages) {
            if (Int64(m.id) == msgId) { return Some(m.mediaUnread) }
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[MsgCtxExtras] refetch message failed: ${e}")
    }
    return None<Bool>
}

/**
 * Blocking; call from spawn. Returns None when iOS would not show the row
 * (voice not yet listened, group over the size threshold, request failure
 * for groups).
 */
public func loadMessageReadStats(
    message: Message,
    peerType: String,
    peerId: Int64,
    senderNames: HashMap<Int64, String>
): Option<MessageReadStatsSnapshot> {
    let snapshot = MessageReadStatsSnapshot()
    let svc = getRealMessageService()
    if (isConsumableMedia(message)) {
        // CSM:209-223: voice / round messages need the consumed attribute.
        let unread = match (refetchMediaUnread(peerType, peerId, message.id)) {
            case Some(v) => v
            case None => message.mediaUnread
        }
        if (unread) { return None<MessageReadStatsSnapshot> }
    }
    if (peerType == "user") {
        snapshot.isPrivate = true
        try {
            let req = MessagesGetOutboxReadDate()
            req.peer = svc.buildInputPeer(peerType, peerId)
            req.msgId = Int32(message.id)
            let data = getMTProtoClient().sendRequest(req.toBytes())
            if (data.size >= 8) {
                let d = TLDeserializer(data)
                let ctor = d.readUInt32()
                if (ctor == 0x3bb842ac) {
                    snapshot.readDate = d.readInt32()
                } else if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let code = d.readInt32()
                    let text = d.readString()
                    Hilog.info(0, "CjTelegram", "[MsgCtxExtras] getOutboxReadDate error ${code} ${text}")
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[MsgCtxExtras] getOutboxReadDate failed: ${e}")
        }
        return Some(snapshot)
    }
    var threshold: Int64 = 50
    synchronized(_extrasLock) { threshold = _readMarkSizeThreshold }
    let count = participantCountFor(peerType, peerId)
    // CSM:247-262: unknown or larger than chat_read_mark_size_threshold → no row.
    if (count < 0 || count > threshold) { return None<MessageReadStatsSnapshot> }
    let list = svc.getReadParticipants(peerType, peerId, Int32(message.id))
    fillReadParticipantNames(list, senderNames)
    for (rec in list) { snapshot.peers.add(rec) }
    return Some(snapshot)
}

/** Resolves reader names from caches, known chat senders, then users.getUsers. Blocking. */
public func fillReadParticipantNames(list: ArrayList<ReadParticipantRecord>, senderNames: HashMap<Int64, String>): Unit {
    let missing = ArrayList<Int64>()
    for (rec in list) {
        if (rec.displayName.size == 0) { rec.displayName = resolveUserName(rec.userId, senderNames) }
        if (rec.displayName.size == 0) { missing.add(rec.userId) }
    }
    if (!missing.isEmpty()) {
        let fetched = fetchUserNames(missing)
        for (rec in list) {
            if (rec.displayName.size == 0 && fetched.contains(rec.userId)) {
                rec.displayName = fetched[rec.userId]
            }
        }
    }
}

/**
 * iOS humanReadableStringForTimestamp with Chat.PrivateMessageSeenTimestamp.*:
 * "read today at %@", "read yesterday at %@", "read %@".
 */
public func formatPrivateReadDate(timestamp: Int32): String {
    let ts = Int64(timestamp)
    let now = DateTime.now().toUnixTimeStamp().toSeconds()
    let day = localDayIndexOf(ts)
    let today = localDayIndexOf(now)
    let clock = formatClockHHMM(ts)
    if (day == today) { return "read today at ${clock}" }
    if (day == today - 1) { return "read yesterday at ${clock}" }
    return "read ${formatShortDateSlashed(ts)} at ${clock}"
}

/** Conversation.ContextMenuSeen / Listened / Watched (Localizable.strings:6985-6993). */
public func formatGroupReadCount(count: Int64, message: Message): String {
    if (count == 0) {
        if (message.messageType == "voice") { return "Nobody Listened" }
        return "Nobody Viewed"
    }
    if (message.messageType == "voice") { return "${count} Listened" }
    if (message.messageType == "video_note") { return "${count} Watched" }
    return "${count} Seen"
}

// ==================== Save for Notifications ====================

/**
 * CSM:1102-1112: the entry is shown for a file < 1 MB, < 60 s, with an
 * mpeg/mp3/ogg MIME type, no auto-delete timer, not already a saved tone.
 */
public func canSaveMessageAsNotificationSound(message: Message): Bool {
    if (message.documentId == 0 || message.ttlPeriod > 0) { return false }
    if (message.documentSize <= 0 || message.documentSize >= 1024 * 1024) { return false }
    if (message.audioDuration <= 0 || message.audioDuration >= 60) { return false }
    let mime = message.documentMimeType.toAsciiLower()
    if (mime != "audio/mpeg" && mime != "audio/mp3" && mime != "audio/mpeg3" && mime != "audio/ogg") {
        return false
    }
    var alreadyAdded = false
    synchronized(_extrasLock) {
        match (_savedToneIds) {
            case Some(ids) => alreadyAdded = ids.contains(message.documentId)
            case None => ()
        }
    }
    return !alreadyAdded
}

/** Mirrors iOS's cached NotificationSoundList used by the menu. */
public func prefetchSavedNotificationSounds(): Unit {
    synchronized(_extrasLock) {
        if (_savedTonesLoading) { return }
        _savedTonesLoading = true
    }
    spawn {
        try {
            let (list, _hash) = getNotificationSoundSelectionService().getSavedRingtones(0)
            let ids = HashSet<Int64>()
            for (entry in list) { ids.add(entry.id) }
            synchronized(_extrasLock) { _savedToneIds = Some(ids) }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[MsgCtxExtras] saved tones failed: ${e}")
        }
        synchronized(_extrasLock) { _savedTonesLoading = false }
    }
}

private func refreshedDocumentReference(peerType: String, peerId: Int64, msgId: Int64): Option<(Int64, Int64, Array<Byte>)> {
    try {
        let ids = ArrayList<Int32>()
        ids.add(Int32(msgId))
        let svc = getRealMessageService()
        let data = if (peerType == "channel") {
            svc.getChannelMessages(peerId, svc.getAccessHashForChannel(peerId), ids)
        } else {
            svc.getMessagesByIds(ids)
        }
        if (data.size < 8) { return None<(Int64, Int64, Array<Byte>)> }
        let resp = MessagesHistoryResponse.deserialize(data)
        for (m in resp.messages) {
            if (Int64(m.id) == msgId && m.documentId != 0) {
                return Some((m.documentId, m.documentAccessHash, m.documentFileReference))
            }
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[MsgCtxExtras] refresh file reference failed: ${e}")
    }
    return None<(Int64, Int64, Array<Byte>)>
}

/**
 * CSM:1117-1136 action: size / duration limits from NotificationSoundSettings
 * (ringtone_size_max / ringtone_duration_max), then saveNotificationSound
 * (account.saveRingtone, retried with a refreshed file reference like
 * NotificationSoundList.swift:275-289) and an undo toast. Blocking.
 */
public func saveMessageAsNotificationSound(message: Message, peerType: String, peerId: Int64): Unit {
    let soundSvc = getNotificationSoundSelectionService()
    let (maxSize, maxDuration) = soundSvc.getRingtoneLimits()
    let fileName = if (message.documentFileName.size > 0) { message.documentFileName } else { "Tone" }
    if (message.documentSize > maxSize) {
        showToast("File Too Large. The file is over ${maxSize / 1024} KB.", durationMs: 3000)
        return
    }
    if (Int64(message.audioDuration) > maxDuration) {
        let mins = maxDuration / 60
        let secs = maxDuration % 60
        let secText = if (secs < 10) { "0${secs}" } else { "${secs}" }
        showToast("${fileName} is too long. The duration is longer than ${mins}:${secText}.", durationMs: 3000)
        return
    }
    var ok = soundSvc.saveRingtone(message.documentId, message.documentAccessHash, message.documentFileReference)
    if (!ok) {
        match (refreshedDocumentReference(peerType, peerId, message.id)) {
            case Some((id, hash, ref)) => ok = soundSvc.saveRingtone(id, hash, ref)
            case None => ()
        }
    }
    if (ok) {
        synchronized(_extrasLock) {
            match (_savedToneIds) {
                case Some(ids) => ids.add(message.documentId)
                case None => ()
            }
        }
        showToast("Sound Added. You can now use this sound as a notification tone in your custom notification settings.", durationMs: 3500)
    } else {
        showToast("An error occurred.", durationMs: 2000)
    }
}
