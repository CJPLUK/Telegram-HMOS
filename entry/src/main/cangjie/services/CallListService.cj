package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.CallRecord
import ohos_app_cangjie_entry.core.mtproto.{getMTProtoClient, MessagesGetDialogs, MessagesDialogsResponse, TLDeserializer}
import std.collection.{ArrayList, HashSet}

// CallService, TelegramVoipService, RealMessageService 通过同包可见性访问

/**
 * 通话记录列表服务 (CallListUI)
 *
 * 封装通话记录列表相关 TL 方法，聚焦列表展示逻辑。
 * 委托 CallService 处理 messages.search、messages.deleteMessages，
 * 委托 TelegramVoipService 处理 phone.getCallConfig，
 * 委托 RealMessageService 处理 messages.readHistory（标记已读）。
 *
 * 对应 iOS: CallListController, EngineCallList
 * TL 方法: messages.search, phone.getCallConfig, messages.readHistory
 */
private var _callListServiceInstance: Option<CallListService> = None

public func getCallListService(): CallListService {
    match (_callListServiceInstance) {
        case Some(s) => s
        case None =>
            let s = CallListService()
            _callListServiceInstance = Some(s)
            s
    }
}

public class CallListService {
    private let callService = getCallService()
    private let voipService = getTelegramVoipService()
    private let messageService = getRealMessageService()

    /**
     * 获取通话记录列表
     * 委托 CallService.loadRealCallHistory (messages.search + inputMessagesFilterPhoneCalls)
     */
    public func getCallList(filterMissedOnly: Bool): Unit {
        this.callService.loadRealCallHistory(filterMissedOnly)
    }

    /**
     * 获取当前缓存的通话记录
     */
    public func getCallList(): ArrayList<CallRecord> {
        return this.callService.getCallHistory()
    }

    /**
     * 加载更多通话记录（分页）
     */
    public func loadMoreCallList(offsetMsgId: Int32, offsetDate: Int32): Unit {
        this.callService.loadMoreCallHistory(offsetMsgId, offsetDate)
    }

    /**
     * 注册通话记录变化回调
     */
    public func setCallListChangedCallback(cb: (ArrayList<CallRecord>) -> Unit): Unit {
        this.callService.setCallHistoryChangedCallback(cb)
    }

    /**
     * 清除通话记录变化回调
     */
    public func clearCallListChangedCallback(): Unit {
        this.callService.clearCallHistoryChangedCallback()
    }

    /**
     * 删除通话记录
     * 委托 CallService.deleteCallRecords (messages.deleteMessages)
     */
    public func deleteCallRecords(msgIds: ArrayList<Int32>): Bool {
        return this.callService.deleteCallRecords(msgIds)
    }

    /** revoke=true: "Delete for me and <name>"；false: "Delete for me"（CallListControllerNode.swift:370/378） */
    public func deleteCallRecords(msgIds: ArrayList<Int32>, revoke: Bool): Bool {
        return this.callService.deleteCallRecords(msgIds, revoke)
    }

    /**
     * Calls tab "ACTIVE VOICE CHATS" rows (CallListControllerNode.swift:514-532):
     * iOS walks chatList(group: .root, count: 100) and keeps channels / legacy groups whose
     * flags contain .hasActiveVoiceChat (chat/channel flags.24 call_not_empty), sorted by
     * compactDisplayTitle then peer id. Same source here: messages.getDialogs(folder 0, limit 100).
     */
    public func loadActiveGroupCallPeers(): ArrayList<ActiveGroupCallPeer> {
        let result = ArrayList<ActiveGroupCallPeer>()
        try {
            let req = MessagesGetDialogs()
            req.limit = 100
            req.folderId = 0
            let data = getMTProtoClient().sendRequest(req.toBytes())
            if (data.size < 8) { return result }
            if (TLDeserializer(data).readUInt32() == 0x2144ca19) { return result }
            let response = MessagesDialogsResponse.deserialize(data)
            let dialogPeers = HashSet<Int64>()
            for (dlg in response.dialogs) {
                if (dlg.peer.type_ == "chat" || dlg.peer.type_ == "channel") { dialogPeers.add(dlg.peer.id) }
            }
            let photoService = getUserPhotoService()
            for (chat in response.chats) {
                if (!chat.hasActiveVoiceChat || chat.isLeft || !dialogPeers.contains(chat.id)) { continue }
                photoService.cacheChat(chat)
                if (chat.isChannel && chat.accessHash != 0) {
                    this.messageService.cacheChannelAccessHash(chat.id, chat.accessHash)
                }
                let peer = ActiveGroupCallPeer()
                peer.peerId = chat.id
                peer.peerType = if (chat.isChannel) { "channel" } else { "chat" }
                peer.accessHash = chat.accessHash
                peer.title = chat.title
                peer.canManageCall = chat.isCreator || (chat.adminRightsFlags & (1 << 11)) != 0
                result.add(peer)
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallListService] loadActiveGroupCallPeers failed: ${e}")
        }
        // Display order is the reverse of iOS's ascending sort (the call list is bottom-anchored, newest on top).
        let n = result.size
        var i: Int64 = 1
        while (i < n) {
            let cur = result[i]
            var j = i - 1
            while (j >= 0 && activeGroupCallPeerBefore(cur, result[j])) {
                result[j + 1] = result[j]
                j = j - 1
            }
            result[j + 1] = cur
            i = i + 1
        }
        return result
    }

    /**
     * 获取通话配置
     * 委托 TelegramVoipService.getCallConfig (phone.getCallConfig)
     */
    public func getCallConfig(): Option<String> {
        return this.voipService.getCallConfig()
    }

    /**
     * 标记通话消息已读
     * 委托 RealMessageService.markAsRead (messages.readHistory)
     * peerId: 对方用户 ID（1:1 通话）
     * maxMsgId: 已读到的最大消息 ID
     */
    public func markCallAsRead(peerId: Int64, maxMsgId: Int32): Unit {
        if (peerId <= 0) { return }
        this.messageService.markAsRead("user", peerId, maxMsgId)
        Hilog.info(0, "CjTelegram", "[CallListService] markCallAsRead done")
    }
}

/** One row of the Calls tab "ACTIVE VOICE CHATS" section (iOS CallListNodeEntry.groupCall). */
public class ActiveGroupCallPeer {
    public var peerId: Int64 = 0
    public var peerType: String = "chat"
    public var accessHash: Int64 = 0
    public var title: String = ""
    // iOS canManageCall: creator or admin with manage_call (chatAdminRights flags.11)
    public var canManageCall: Bool = false
}

// true when a is shown above b: descending (title, id), i.e. iOS ascending order read from the top of the reversed list
private func activeGroupCallPeerBefore(a: ActiveGroupCallPeer, b: ActiveGroupCallPeer): Bool {
    if (a.title != b.title) { return a.title > b.title }
    return a.peerId > b.peerId
}
