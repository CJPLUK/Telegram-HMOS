package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import std.collection.ArrayList
import std.sync.*
import std.time.DateTime
import std.convert.*
import ohos_app_cangjie_entry.models.Message

/**
 * Recent downloads list behind the global search "Downloads" tab.
 *
 * iOS: FetchManagerImpl records a RecentDownloadItem when a user-initiated
 * fetch of a message file actually goes to the network
 * (FetchManagerImpl.swift:265-266, filterDownloadStatsEntry :655-687 excludes
 * GIFs, round videos, stickers and voice notes). Items live in the
 * RecentDownloads ordered list, newest first, capped at 200
 * (SyncCore_RecentDownloadItem.swift:183-189). The search tab is offered only
 * while that list (or an active download) is non-empty
 * (ChatListController.swift:596-623, ChatListSearchPaneContainerNode.swift:102-123).
 */
public class RecentDownloadEntry {
    public var peerType: String = "user"
    public var peerId: Int64 = 0
    public var messageId: Int64 = 0
    public var documentId: Int64 = 0
    public var fileName: String = ""
    public var mimeType: String = ""
    public var size: Int64 = 0
    public var localPath: String = ""
    /** When the download was recorded (iOS RecentDownloadItem.timestamp). */
    public var timestamp: Int64 = 0
    /** Message date, shown like ListMessageFileItemNode rows. */
    public var messageDate: Int64 = 0
    public var authorName: String = ""
    public var chatTitle: String = ""
    public init() {}

    func serialize(): String {
        let fields = [
            this.peerType, this.peerId.toString(), this.messageId.toString(), this.documentId.toString(),
            clean(this.fileName), clean(this.mimeType), this.size.toString(), clean(this.localPath),
            this.timestamp.toString(), this.messageDate.toString(), clean(this.authorName), clean(this.chatTitle)
        ]
        var out = ""
        var first = true
        for (f in fields) {
            if (!first) { out = out + "\t" }
            out = out + f
            first = false
        }
        return out
    }

    static func parse(line: String): Option<RecentDownloadEntry> {
        let p = line.split("\t")
        if (p.size < 12) { return None<RecentDownloadEntry> }
        try {
            let e = RecentDownloadEntry()
            e.peerType = p[0]
            e.peerId = Int64.parse(p[1])
            e.messageId = Int64.parse(p[2])
            e.documentId = Int64.parse(p[3])
            e.fileName = p[4]
            e.mimeType = p[5]
            e.size = Int64.parse(p[6])
            e.localPath = p[7]
            e.timestamp = Int64.parse(p[8])
            e.messageDate = Int64.parse(p[9])
            e.authorName = p[10]
            e.chatTitle = p[11]
            return Some(e)
        } catch (_: Exception) {
            return None<RecentDownloadEntry>
        }
    }

    public func sameItem(other: RecentDownloadEntry): Bool {
        return this.peerId == other.peerId && this.messageId == other.messageId && this.documentId == other.documentId
    }
}

private func clean(s: String): String {
    return s.replace("\t", " ").replace("\n", " ").replace("\r", " ")
}

private let RECENT_DOWNLOADS_LIMIT: Int64 = 200
private let _recentDownloadsLock = ReentrantMutex()
private var _recentDownloads: ArrayList<RecentDownloadEntry> = ArrayList<RecentDownloadEntry>()
private var _activeDownloads: ArrayList<RecentDownloadEntry> = ArrayList<RecentDownloadEntry>()
private var _recentDownloadsLoaded: Bool = false

private func recentDownloadsPath(): String {
    let dir = getAppFilesDir()
    if (dir.isEmpty()) { return "" }
    return dir + "/recent_downloads.tsv"
}

private func ensureRecentDownloadsLoaded(): Unit {
    if (_recentDownloadsLoaded) { return }
    _recentDownloadsLoaded = true
    let path = recentDownloadsPath()
    if (path.isEmpty()) { return }
    try {
        if (!FileIo.access(path)) { return }
        let st = FileIo.stat(path)
        if (st.size <= 0) { return }
        let file = FileIo.open(path, mode: 0o0)
        let buf = Array<Byte>(Int64(st.size), repeat: 0)
        let n = FileIo.read(file.fd, buf)
        FileIo.close(file)
        if (n <= 0) { return }
        let text = String.fromUtf8(Array<Byte>(n, { i: Int64 => buf[i] }))
        for (line in text.split("\n")) {
            if (line.isEmpty()) { continue }
            match (RecentDownloadEntry.parse(line)) {
                case Some(e) => _recentDownloads.add(e)
                case None => ()
            }
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[RecentDownloads] load failed: ${e}")
    }
}

private func persistRecentDownloads(): Unit {
    let path = recentDownloadsPath()
    if (path.isEmpty()) { return }
    var text = ""
    for (e in _recentDownloads) { text = text + e.serialize() + "\n" }
    try {
        let file = FileIo.open(path, mode: 0o1101)
        FileIo.write(file.fd, text.toArray())
        FileIo.close(file)
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[RecentDownloads] save failed: ${e}")
    }
}

/** filterDownloadStatsEntry: files except GIFs, round videos, stickers, voice notes. */
public func isRecentDownloadCandidate(message: Message): Bool {
    if (message.documentId == 0) { return false }
    let t = message.messageType
    return t != "gif" && t != "video_note" && t != "sticker" && t != "voice"
}

public func makeRecentDownloadEntry(message: Message, peerType: String, peerId: Int64, chatTitle: String): RecentDownloadEntry {
    let e = RecentDownloadEntry()
    e.peerType = peerType
    e.peerId = peerId
    e.messageId = message.id
    e.documentId = message.documentId
    e.fileName = if (message.documentFileName.size > 0) {
        message.documentFileName
    } else if (message.messageType == "video") {
        "Video"
    } else {
        "File"
    }
    e.mimeType = message.documentMimeType
    e.size = message.documentSize
    e.messageDate = message.rawTimestamp
    e.authorName = if (message.isSent) { "You" } else if (message.senderName.size > 0) { message.senderName } else { chatTitle }
    e.chatTitle = chatTitle
    return e
}

/** A user-initiated network fetch started ("Downloading" section). */
public func beginRecentDownload(entry: RecentDownloadEntry): Unit {
    synchronized(_recentDownloadsLock) {
        for (a in _activeDownloads) {
            if (a.sameItem(entry)) { return }
        }
        _activeDownloads.add(entry)
    }
}

/**
 * The fetch finished: drop it from the active list and, when it produced a
 * local file, add or move it to the head of the recent list (addOrMoveToFirst).
 */
public func finishRecentDownload(entry: RecentDownloadEntry, localPath: String): Unit {
    synchronized(_recentDownloadsLock) {
        var i = 0
        while (i < _activeDownloads.size) {
            if (_activeDownloads[i].sameItem(entry)) {
                let _ = _activeDownloads.remove(at: i)
            } else {
                i += 1
            }
        }
        if (localPath.isEmpty()) { return }
        ensureRecentDownloadsLoaded()
        entry.localPath = localPath
        entry.timestamp = DateTime.now().toUnixTimeStamp().toSeconds()
        var j = 0
        while (j < _recentDownloads.size) {
            if (_recentDownloads[j].sameItem(entry)) {
                let _ = _recentDownloads.remove(at: j)
            } else {
                j += 1
            }
        }
        _recentDownloads.add(entry, at: 0)
        while (_recentDownloads.size > RECENT_DOWNLOADS_LIMIT) {
            let _ = _recentDownloads.remove(at: _recentDownloads.size - 1)
        }
        persistRecentDownloads()
    }
}

public func hasRecentDownloads(): Bool {
    synchronized(_recentDownloadsLock) {
        ensureRecentDownloadsLoaded()
        return !_recentDownloads.isEmpty() || !_activeDownloads.isEmpty()
    }
}

public func getRecentDownloads(): ArrayList<RecentDownloadEntry> {
    synchronized(_recentDownloadsLock) {
        ensureRecentDownloadsLoaded()
        let copy = ArrayList<RecentDownloadEntry>()
        for (e in _recentDownloads) { copy.add(e) }
        return copy
    }
}

public func getActiveDownloads(): ArrayList<RecentDownloadEntry> {
    synchronized(_recentDownloadsLock) {
        let copy = ArrayList<RecentDownloadEntry>()
        for (e in _activeDownloads) { copy.add(e) }
        return copy
    }
}

/** clearRecentDownloadList (SyncCore_RecentDownloadItem.swift:193-198); files stay on disk. */
public func clearRecentDownloads(): Unit {
    synchronized(_recentDownloadsLock) {
        ensureRecentDownloadsLoaded()
        _recentDownloads.clear()
        persistRecentDownloads()
    }
}
