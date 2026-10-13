package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.InviteLinkData
import std.collection.ArrayList

/**
 * 入群请求入队列成员数据（P2-138）
 * 对应 ChatInviteImporterData from TLResponses
 */
public class JoinRequestEntry {
    public var userId: Int64 = 0
    public var date: Int32 = 0
    public var requested: Bool = false
    public var about: String = ""
    public var approvedBy: Int64 = 0
    public var hasApprovedBy: Bool = false
}

/**
 * 邀请链接服务（Invite Links Service）
 *
 * 封装邀请链接相关的 TL 方法：
 * - messages.exportChatInvite
 * - messages.getExportedChatInvites
 * - messages.editExportedChatInvite
 * - messages.deleteExportedChatInvite
 * - messages.getChatInviteImporters
 *
 * 复用 RealMessageService 的 buildInputPeer 和解析逻辑。
 */
private var _inviteLinksServiceInstance: Option<InviteLinksService> = None
private var _pendingInviteLinkEdit: String = ""
private var _selectedInviteLinkUrl: String = ""

public func setPendingInviteLinkEdit(link: String): Unit {
    _pendingInviteLinkEdit = link
}

public func getPendingInviteLinkEdit(): String {
    let link = _pendingInviteLinkEdit
    _pendingInviteLinkEdit = ""
    return link
}

public func setSelectedInviteLinkUrl(link: String): Unit {
    _selectedInviteLinkUrl = link
}

public func getSelectedInviteLinkUrl(): String {
    return _selectedInviteLinkUrl
}

public func getInviteLinksService(): InviteLinksService {
    match (_inviteLinksServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = InviteLinksService()
            _inviteLinksServiceInstance = Some(inst)
            return inst
    }
}

public class InviteLinksService {

    /**
     * 创建新的邀请链接（messages.exportChatInvite）
     * @param expireDate Unix 时间戳，0 = 永久
     * @param usageLimit 使用次数限制，0 = 无限
     * @param requestNeeded 是否需要审批
     */
    public func exportChatInvite(
        peerType: String,
        peerId: Int64,
        title!: String = "",
        expireDate!: Int32 = 0,
        usageLimit!: Int32 = 0,
        requestNeeded!: Bool = false
    ): String {
        let msgSvc = getRealMessageService()
        let client = getMTProtoClient()

        let req = MessagesExportChatInvite()
        req.peer = msgSvc.buildInputPeer(peerType, peerId)
        req.title = title
        req.expireDate = expireDate
        req.usageLimit = usageLimit
        req.requestNeeded = requestNeeded

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return ""
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[InviteLinksService] exportChatInvite error: ${errMsg}")
            return ""
        }

        // chatInviteExported: iOS Api0.swift:294 dict[-1574126186] -> 0xa22cbd96
        if (constructor == 0xa22cbd96) {
            return parseExportedChatInviteLink(d)
        }
        return ""
    }

    /**
     * 获取邀请链接列表（messages.getExportedChatInvites）
     */
    public func getExportedChatInvites(
        peerType: String,
        peerId: Int64,
        revoked!: Bool = false
    ): ArrayList<InviteLinkData> {
        return getRealMessageService().getExportedChatInvites(peerType, peerId, revoked: revoked)
    }

    /**
     * 编辑邀请链接（messages.editExportedChatInvite）
     * revoked=true 时撤销链接
     *
     * P2-167 gap fix: requestNeeded is flags.3?Bool (boxed Bool), must set
     * hasRequestNeeded=true to actually include the Bool payload in bitstream.
     * iOS ref: Api42.swift:6275 requestNeeded!.serialize(buffer, true)
     */
    public func editExportedChatInvite(
        peerType: String,
        peerId: Int64,
        link: String,
        title!: String = "",
        expireDate!: Int32 = 0,
        usageLimit!: Int32 = 0,
        requestNeeded!: Bool = false,
        setRequestNeeded!: Bool = false,
        revoked!: Bool = false
    ): Bool {
        let msgSvc = getRealMessageService()
        let client = getMTProtoClient()

        let req = MessagesEditExportedChatInvite()
        req.peer = msgSvc.buildInputPeer(peerType, peerId)
        req.link = link
        req.title = title
        req.expireDate = expireDate
        req.usageLimit = usageLimit
        req.requestNeeded = requestNeeded
        req.hasRequestNeeded = setRequestNeeded
        req.revoked = revoked

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[InviteLinksService] editExportedChatInvite error: ${errMsg}")
            return false
        }
        return true
    }

    /**
     * 批量删除全部已撤销邀请链接（messages.deleteRevokedExportedChatInvites）
     * P2-170 gap fill: 批量删全部撤销链接
     *
     * Constructor: 0x56987bd5
     * iOS ref: Api42.swift:6054 buffer.appendInt32(1452833749) -> 0x56987bd5
     *
     * @return true = 成功
     */
    public func deleteRevokedExportedChatInvites(peerType: String, peerId: Int64): Bool {
        let msgSvc = getRealMessageService()
        let client = getMTProtoClient()

        let req = MessagesDeleteRevokedExportedChatInvites()
        req.peer = msgSvc.buildInputPeer(peerType, peerId)
        req.adminId = InputUserSelf()

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[InviteLinksService] deleteRevokedExportedChatInvites error: ${errMsg}")
            return false
        }
        return constructor == 0x997275b5
    }

    /**
     * 删除邀请链接（messages.deleteExportedChatInvite）
     */
    public func deleteExportedChatInvite(peerType: String, peerId: Int64, link: String): Bool {
        let msgSvc = getRealMessageService()
        let client = getMTProtoClient()

        let req = MessagesDeleteExportedChatInvite()
        req.peer = msgSvc.buildInputPeer(peerType, peerId)
        req.link = link

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[InviteLinksService] deleteExportedChatInvite error: %{public}s", [errMsg])
            return false
        }

        if (constructor == 0x997275b5) {
            return true
        }
        return false
    }

    /**
     * 获取通过邀请链接加入的用户（messages.getChatInviteImporters）
     * @return 加入者数量
     */
    public func getChatInviteImporters(
        peerType: String,
        peerId: Int64,
        link!: String = "",
        requested!: Bool = false,
        offsetDate!: Int32 = 0,
        limit!: Int32 = 50
    ): Int32 {
        let msgSvc = getRealMessageService()
        let client = getMTProtoClient()

        let req = MessagesGetChatInviteImporters()
        req.peer = msgSvc.buildInputPeer(peerType, peerId)
        req.link = link
        req.requested = requested
        req.offsetDate = offsetDate
        req.offsetUser = InputPeerEmpty()
        req.limit = limit

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 8) { return 0 }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let _ = d.readString()
            return 0
        }

        if (constructor == 0x81b6b00a) {
            return d.readInt32()
        }
        return 0
    }

    /**
     * 获取待审批入群请求列表（P2-138）
     * 封装 messages.getChatInviteImporters 的 requested=true 路径
     * 返回 ChatInviteImportersResponse（含 count + importers + users）
     */
    public func getChatInviteImportersWithData(
        peerType: String,
        peerId: Int64,
        link!: String = "",
        requested!: Bool = false,
        searchQuery!: String = "",
        offsetDate!: Int32 = 0,
        limit!: Int32 = 50
    ): ChatInviteImportersResponse {
        let msgSvc = getRealMessageService()
        let client = getMTProtoClient()

        let req = MessagesGetChatInviteImporters()
        req.peer = msgSvc.buildInputPeer(peerType, peerId)
        req.link = link
        req.requested = requested
        req.q = searchQuery
        req.offsetDate = offsetDate
        req.offsetUser = InputPeerEmpty()
        req.limit = limit

        let responseData = client.sendRequest(req.toBytes())
        return ChatInviteImportersResponse.deserialize(responseData)
    }

    /**
     * 批准或拒绝单个入群请求（P2-138）
     * messages.hideChatJoinRequest#7fe7e815
     * iOS ref: Api42.swift:8268, InvitationLinks.swift:14
     *
     * @param approved true = 批准，false = 拒绝
     * @param userPeerType 用户 peer 类型（通常 "user"）
     * @param userId 用户 ID
     * @param userAccessHash 用户 access hash
     */
    public func hideChatJoinRequest(
        peerType: String,
        peerId: Int64,
        userId: Int64,
        userAccessHash: Int64,
        approved!: Bool = true
    ): Bool {
        let msgSvc = getRealMessageService()
        let client = getMTProtoClient()

        let req = MessagesHideChatJoinRequest()
        req.peer = msgSvc.buildInputPeer(peerType, peerId)
        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = userAccessHash
        req.userId = inputUser
        req.approved = approved

        let responseData = client.sendRequest(req.toBytes())
        let resp = JoinRequestUpdatesResponse.deserialize(responseData)
        if (!resp.success && resp.errorMessage.size > 0) {
            Hilog.info(0, "CjTelegram", "[InviteLinksService] hideChatJoinRequest error: ${resp.errorCode} ${resp.errorMessage}")
        }
        return resp.success
    }

    /**
     * 批量批准或拒绝全部入群请求（P2-138）
     * messages.hideAllChatJoinRequests#e085f4ea
     * iOS ref: Api42.swift:8249, InvitationLinks.swift:33
     *
     * @param approved true = 全部批准，false = 全部拒绝
     * @param link 如果非空，只处理该邀请链接下的请求
     */
    public func hideAllChatJoinRequests(
        peerType: String,
        peerId: Int64,
        approved!: Bool = true,
        link!: String = ""
    ): Bool {
        let msgSvc = getRealMessageService()
        let client = getMTProtoClient()

        let req = MessagesHideAllChatJoinRequests()
        req.peer = msgSvc.buildInputPeer(peerType, peerId)
        req.approved = approved
        req.link = link

        let responseData = client.sendRequest(req.toBytes())
        let resp = JoinRequestUpdatesResponse.deserialize(responseData)
        if (!resp.success && resp.errorMessage.size > 0) {
            Hilog.info(0, "CjTelegram", "[InviteLinksService] hideAllChatJoinRequests error: ${resp.errorCode} ${resp.errorMessage}")
        }
        return resp.success
    }

    private func parseExportedChatInviteLink(d: TLDeserializer): String {
        let flags = d.readInt32()
        let link = d.readString()
        let _ = d.readInt64()  // admin_id
        let _ = d.readInt32()  // date
        if ((flags & 16) != 0) { let _ = d.readInt32() }    // bit 4: start_date
        if ((flags & 2) != 0) { let _ = d.readInt32() }     // bit 1: expire_date
        if ((flags & 4) != 0) { let _ = d.readInt32() }     // bit 2: usage_limit
        if ((flags & 8) != 0) { let _ = d.readInt32() }     // bit 3: usage count
        if ((flags & 128) != 0) { let _ = d.readInt32() }   // bit 7: requested count
        if ((flags & 1024) != 0) { let _ = d.readInt32() }  // bit 10: subscriptionExpired
        if ((flags & 256) != 0) { let _ = d.readString() }  // bit 8: title
        return link
    }
}
