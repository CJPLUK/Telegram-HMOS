package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import std.collection.ArrayList
import std.sync.*
import std.convert.*
import ohos_app_cangjie_entry.models.Chat

/**
 * 最近联系人搜索节点数据层
 *
 * 对应 iOS ChatListSearchRecentPeersNode
 * 提供搜索界面顶部显示的最近联系人列表数据
 *
 * - addRecentPeer(): 将用户刚搜索点击的 peer 加到最近列表首位
 *   （iOS _internal_addRecentlySearchedPeer：Postbox 有序表 RecentlySearchedPeerIds，
 *    addOrMoveToFirstPosition + removeTailIfCountExceeds: 20，RecentlySearchedPeerIds.swift:6-10）。
 *   iOS 该表落盘，重启后仍在；这里按账号写到应用 files 目录的 TSV，冷启动懒加载。
 * - clearRecentPeers(): iOS clearRecentlySearchedPeers，清空并落盘。
 * - getRecentPeers(): 优先返回最近列表，列表为空时回退到 getDialogs()
 */
private var _chatListSearchRecentPeersServiceInstance: Option<ChatListSearchRecentPeersService> = None

public func getChatListSearchRecentPeersService(): ChatListSearchRecentPeersService {
    match (_chatListSearchRecentPeersServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ChatListSearchRecentPeersService()
            _chatListSearchRecentPeersServiceInstance = Some(inst)
            return inst
    }
}

private func recentPeerClean(s: String): String {
    return s.replace("\t", " ").replace("\n", " ").replace("\r", " ")
}

private func recentPeerBool(b: Bool): String {
    return if (b) { "1" } else { "0" }
}

private func serializeRecentPeer(c: Chat): String {
    let fields = [
        c.peerType, c.id.toString(), recentPeerClean(c.name), recentPeerClean(c.username),
        recentPeerClean(c.avatarLocalPath), c.avatarColor.toString(), recentPeerClean(c.avatarText),
        recentPeerBool(c.isGroup), recentPeerBool(c.isChannel), recentPeerBool(c.isMegagroup),
        recentPeerBool(c.isBot), recentPeerBool(c.isVerified), recentPeerBool(c.isSavedMessages),
        c.participantsCount.toString()
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

private func parseRecentPeer(line: String): Option<Chat> {
    let p = line.split("\t")
    if (p.size < 14) { return None<Chat> }
    try {
        let c = Chat()
        c.peerType = p[0]
        c.id = Int64.parse(p[1])
        c.name = p[2]
        c.username = p[3]
        c.avatarLocalPath = p[4]
        c.avatarColor = Int64.parse(p[5])
        c.avatarText = p[6]
        c.isGroup = p[7] == "1"
        c.isChannel = p[8] == "1"
        c.isMegagroup = p[9] == "1"
        c.isBot = p[10] == "1"
        c.isVerified = p[11] == "1"
        c.isSavedMessages = p[12] == "1"
        c.participantsCount = Int64.parse(p[13])
        return Some(c)
    } catch (_: Exception) {
        return None<Chat>
    }
}

public class ChatListSearchRecentPeersService {

    // Recently searched peers, most recent first (iOS RecentlySearchedPeerIds, cap 20).
    private var _recentPeers: ArrayList<Chat> = ArrayList<Chat>()
    private let MAX_RECENT: Int64 = 20
    private let _lock = ReentrantMutex()
    // 已加载的账号（-1 = 未加载）；切换账号后按新账号重新读盘。
    private var _loadedUserId: Int64 = -1

    private func storagePath(userId: Int64): String {
        let dir = getAppFilesDir()
        if (dir.isEmpty()) { return "" }
        return dir + "/recent_searched_peers_${userId}.tsv"
    }

    private func ensureLoaded(): Unit {
        let uid = getCurrentUserId()
        if (uid == this._loadedUserId) { return }
        this._loadedUserId = uid
        this._recentPeers = ArrayList<Chat>()
        let path = this.storagePath(uid)
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
                match (parseRecentPeer(line)) {
                    case Some(c) => this._recentPeers.add(c)
                    case None => ()
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatListSearchRecentPeersService] load failed: ${e}")
        }
    }

    private func persist(): Unit {
        let path = this.storagePath(this._loadedUserId)
        if (path.isEmpty()) { return }
        var text = ""
        for (c in this._recentPeers) { text = text + serializeRecentPeer(c) + "\n" }
        try {
            let file = FileIo.open(path, mode: 0o1101)
            FileIo.write(file.fd, text.toArray())
            FileIo.close(file)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatListSearchRecentPeersService] save failed: ${e}")
        }
    }

    /**
     * 记录用户刚刚从搜索结果打开的 peer（iOS addRecentlySearchedPeer，SLP:3574）。
     * 已在列表中则移到首位，否则插入首位并按 MAX_RECENT 截断。
     */
    public func addRecentPeer(chat: Chat): Unit {
        if (chat.id == 0) { return }
        synchronized(this._lock) {
            this.ensureLoaded()
            let newList = ArrayList<Chat>()
            let entry = chat.copy()
            entry.searchMessageId = 0
            newList.add(entry)
            for (p in this._recentPeers) {
                if (newList.size >= this.MAX_RECENT) { break }
                if (!(p.id == chat.id && p.peerType == chat.peerType)) { newList.add(p) }
            }
            this._recentPeers = newList
            this.persist()
            Hilog.info(0, "CjTelegram", "[ChatListSearchRecentPeersService] addRecentPeer id=${chat.id} total=${this._recentPeers.size}")
        }
    }

    /** 仅「最近搜索过」的 peer（iOS recentlySearchedPeers，不回退到会话列表），供 RECENT 段使用。 */
    public func getRecentlySearchedPeers(): ArrayList<Chat> {
        synchronized(this._lock) {
            this.ensureLoaded()
            let result = ArrayList<Chat>()
            for (p in this._recentPeers) { result.add(p) }
            return result
        }
    }

    /**
     * 清空最近搜索记录（iOS clearRecentlySearchedPeers，ChatListSearchContainerNode.swift:278）
     */
    public func clearRecentPeers(): Unit {
        synchronized(this._lock) {
            this.ensureLoaded()
            this._recentPeers = ArrayList<Chat>()
            this.persist()
        }
        Hilog.info(0, "CjTelegram", "[ChatListSearchRecentPeersService] clearRecentPeers")
    }

    /**
     * 获取最近联系人列表
     * 优先使用 in-memory 最近搜索列表；
     * 若为空则从 RealChatListService 获取主列表前 N 个对话作为回退。
     *
     * @param limit 最多返回数量，默认 10
     * @return 最近联系人 Chat 列表（按最近访问时间排序）
     */
    public func getRecentPeers(limit!: Int32 = 10): ArrayList<Chat> {
        let recent = this.getRecentlySearchedPeers()
        if (!recent.isEmpty()) {
            // 返回最近搜索列表（最多 limit 条）
            let result = ArrayList<Chat>()
            var count: Int32 = 0
            for (p in recent) {
                if (count >= limit) { break }
                result.add(p)
                count++
            }
            Hilog.info(0, "CjTelegram", "[ChatListSearchRecentPeersService] getRecentPeers (memory): ${result.size} peers")
            return result
        }
        // 回退：从对话列表获取最近对话
        let chatListService = getRealChatListService()
        let dialogs = chatListService.getDialogs(limit: limit, offsetDate: 0, folderId: 0)
        Hilog.info(0, "CjTelegram", "%{public}s", ["[ChatListSearchRecentPeersService] getRecentPeers (dialogs): " + dialogs.size.toString() + " peers"])
        return dialogs
    }
}
