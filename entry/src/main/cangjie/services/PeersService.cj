package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import std.collection.ArrayList
import std.collection.HashMap
import std.convert.*

/**
 * Peers 操作引擎服务
 *
 * 对应 TelegramEngine.Peers 的核心功能：
 * - 添加/移除群组成员 (messages.addChatUser / messages.deleteChatUser)
 * - 邀请/踢出频道成员 (channels.inviteToChannel / channels.editBanned)
 * - 创建群组 (messages.createChat)
 * - 创建频道/超级群 (channels.createChannel)
 * - 设置/撤销管理员权限 (channels.editAdmin)
 * - 封禁/解封成员 (channels.editBanned)
 *
 * 复用 RealMessageService 的 buildInputPeer / accessHash 缓存。
 */
private var _peersServiceInstance: Option<PeersService> = None

public func getPeersService(): PeersService {
    match (_peersServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PeersService()
            _peersServiceInstance = Some(inst)
            return inst
    }
}

// ==================== ViewModel: Peers 操作结果 ====================

/**
 * Peer 操作通用结果
 */
public class PeerOperationResult {
    public var success: Bool = false
    public var errorCode: String = ""  // "USERS_TOO_MUCH", "USER_PRIVACY_RESTRICTED", etc.

    public init(success: Bool, errorCode!: String = "") {
        this.success = success
        this.errorCode = errorCode
    }
}

/**
 * 新建群组/频道的结果
 */
public class CreatePeerResult {
    public var success: Bool = false
    public var peerId: Int64 = 0       // 新 peer 的 ID
    public var accessHash: Int64 = 0   // 新 peer 的 accessHash（频道时有效）
    public var peerType: String = ""   // "chat" 或 "channel"
    public var errorCode: String = ""
}

/**
 * P2-151: 解析 peer 的结果（resolveByUsername / resolveByPhone / resolveById）
 */
public class PeerResolveResult {
    public var success: Bool = false
    public var peerId: Int64 = 0
    public var peerType: String = ""   // "user" | "chat" | "channel"
    public var accessHash: Int64 = 0
    public var displayName: String = ""
    public var username: String = ""
    public var errorCode: String = ""

    public init() {}
}

/**
 * P2-151: 邀请链接结果（createInviteLink / editInviteLink / revokeInviteLink）
 */
public class InviteLinkResult {
    public var success: Bool = false
    public var link: String = ""
    public var revoked: Bool = false
    public var expireDate: Int32 = 0
    public var usageLimit: Int32 = 0
    public var errorCode: String = ""

    public init() {}
}

/**
 * P2-151: 邀请链接列表结果（getInviteLinks）
 */
public class InviteLinksResult {
    public var links: ArrayList<InviteLinkResult> = ArrayList<InviteLinkResult>()
    public var totalCount: Int32 = 0
    public var errorCode: String = ""

    public init() {}
}

// ==================== P2-137: 封禁/受限成员 ViewModel ====================

/**
 * 封禁/受限频道成员数据（channelParticipantBanned 解析结果）
 *
 * iOS 对应: RenderedChannelParticipant / ChannelParticipant.member(banInfo)
 *
 * channelParticipantBanned#d5f0ad91 (iOS Api4.swift appendInt32(-705647215)):
 *   flags:int peer:Peer kickedBy:long date:int bannedRights:ChatBannedRights rank?:string
 *
 * ChatBannedRights#9f120418 (iOS Api4.swift appendInt32(-1626209256)):
 *   flags:int untilDate:int
 *
 * ChatBannedRights.flags 位（禁止对应操作）：
 *   bit 0: view_messages (0x1)  — "kicked" 语义（无法看消息）
 *   bit 2: send_media    (0x4)
 *   bit 3: send_stickers (0x8)
 *   bit 4: send_gifs     (0x10)
 *   bit 5: send_games    (0x20)
 *   bit 6: send_inline   (0x40)
 *   bit 7: embed_links   (0x80)
 *   bit 8: send_polls    (0x100)
 *   bit 10: change_info  (0x400)
 *   bit 15: invite_users (0x8000)
 *   bit 17: pin_messages (0x20000)
 *   bit 18: manage_topics(0x40000)
 *   bit 19: send_photos  (0x80000)
 *   bit 20: send_videos  (0x100000)
 *   bit 21: send_roundvideos(0x200000)
 *   bit 22: send_audios  (0x400000)
 *   bit 23: send_voices  (0x800000)
 *   bit 24: send_docs    (0x1000000)
 *   bit 25: send_plain   (0x2000000)
 *
 * flags = 0x1 (bit0) means fully kicked (view_messages禁止 = 已踢出)
 * flags > 0x1 means restricted but not fully kicked
 */
public class BannedParticipantEntry <: ToString {
    public var userId: Int64 = 0
    public var accessHash: Int64 = 0
    public var peerType: String = "user"  // "user" | "chat" | "channel"
    public var displayName: String = ""
    public var kickedById: Int64 = 0
    public var kickedByName: String = ""
    public var date: Int32 = 0
    public var bannedFlags: Int32 = 0
    public var untilDate: Int32 = 0

    public func isKicked(): Bool {
        return (this.bannedFlags & 1) != 0
    }

    public func getInitial(): String {
        if (this.displayName.size == 0) { return "?" }
        return firstRuneString(this.displayName)
    }

    public func getBanDescription(): String {
        if (this.kickedByName.size > 0) {
            return "By ${this.kickedByName}"
        }
        return "Banned"
    }

    public func getUntilText(): String {
        if (this.untilDate == 0) {
            return "Forever"
        }
        return "Until ${this.untilDate}"
    }

    public func toString(): String {
        return "${this.displayName}(${this.userId})"
    }

    public init() {}
}

/**
 * 封禁成员列表结果
 */
public class BannedParticipantsResult {
    public var participants: ArrayList<BannedParticipantEntry> = ArrayList<BannedParticipantEntry>()
    public var totalCount: Int32 = 0
    public var errorCode: String = ""

    public init() {}
}

// ==================== P2-151: Username format validation (TC-0082 R3 修法 F1-a) ====================

/**
 * 用户名格式校验错误——逐一对应 iOS AddressNames.swift:8-14 的
 * `AddressNameFormatError` 枚举语义。
 */
public enum AddressNameFormatError {
    | StartsWithUnderscore
    | EndsWithUnderscore
    | StartsWithDigit
    | TooShort
    | InvalidCharacters
}

/**
 * checkAddressNameFormat —— 纯函数，逐行照抄 iOS AddressNames.swift:30-53 的算法与顺序
 * (diag-suite_settings_root-TC-0082.md round2 F1-a，不得重排)：
 *   - 单趟遍历 rune，维护 index、length
 *   - ch == '_'：index == 0 → StartsWithUnderscore；index == length-1 →
 *     length < 4 ? TooShort : EndsWithUnderscore
 *   - index == 0 且 ch 为数字 → StartsWithDigit
 *   - ch 不在 [a-zA-Z0-9_] → InvalidCharacters
 *   - 循环结束后：length < 4 && (!canEmpty || length != 0) → TooShort
 *   - 否则 None
 *
 * 边界：阈值常量为 4(源侧值，不是目标侧此前误写的 5)；不加最大长度检查；不加连续下划线
 * 检查；大写字母合法——均按诊断报告明文排除，不得追加目标侧此前自造的额外规则。
 */
public func checkAddressNameFormat(value: String, canEmpty!: Bool = false): Option<AddressNameFormatError> {
    let runes = value.toRuneArray()
    let length = runes.size
    var index: Int64 = 0
    while (index < length) {
        let ch = runes[index]
        if (ch == r'_') {
            if (index == 0) {
                return Some(AddressNameFormatError.StartsWithUnderscore)
            }
            if (index == length - 1) {
                if (length < 4) {
                    return Some(AddressNameFormatError.TooShort)
                }
                return Some(AddressNameFormatError.EndsWithUnderscore)
            }
        }
        if (index == 0 && ch >= r'0' && ch <= r'9') {
            return Some(AddressNameFormatError.StartsWithDigit)
        }
        let isLetter = (ch >= r'a' && ch <= r'z') || (ch >= r'A' && ch <= r'Z')
        let isDigit = (ch >= r'0' && ch <= r'9')
        if (!isLetter && !isDigit && ch != r'_') {
            return Some(AddressNameFormatError.InvalidCharacters)
        }
        index += 1
    }
    if (length < 4 && (!canEmpty || length != 0)) {
        return Some(AddressNameFormatError.TooShort)
    }
    return None
}

/**
 * 账号级用户名可用性四态——对齐 iOS AddressNames.swift:60-75 的
 * `AddressNameAvailability` 语义(diag-suite_settings_root-TC-0082.md round2 F1-a)。
 */
public enum AddressNameAvailability {
    | Available
    | Invalid
    | Taken
    | PurchaseAvailable
}

// ==================== PeersService ====================

public class PeersService {

    // ==================== 添加/移除基础群组成员 ====================

    /**
     * 添加成员到基础群组（messages.addChatUser）
     *
     * iOS 对应: _internal_addGroupMember — messages.addChatUser
     *
     * @param chatId 群组 ID（basic chat，不是 supergroup）
     * @param userId 要添加的用户 ID
     * @param userAccessHash 用户的 accessHash
     * @param fwdLimit 转发最近消息数量（默认 100）
     */
    public func addGroupMember(
        chatId: Int64,
        userId: Int64,
        userAccessHash: Int64,
        fwdLimit!: Int32 = 100
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] addGroupMember chatId=${chatId} userId=${userId}")
        let client = getMTProtoClient()

        let req = MessagesAddChatUser()
        req.chatId = chatId
        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = userAccessHash
        req.userId = inputUser
        req.fwdLimit = fwdLimit

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] addGroupMember error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }
        return PeerOperationResult(true)
    }

    /**
     * 从基础群组移除成员（messages.deleteChatUser）
     *
     * iOS 对应: _internal_removeGroupMember
     *
     * @param chatId 群组 ID
     * @param userId 要移除的用户 ID
     * @param userAccessHash 用户的 accessHash
     */
    public func removeGroupMember(
        chatId: Int64,
        userId: Int64,
        userAccessHash: Int64
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] removeGroupMember chatId=${chatId} userId=${userId}")
        let client = getMTProtoClient()

        let req = MessagesDeleteChatUser()
        req.chatId = chatId
        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = userAccessHash
        req.userId = inputUser

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] removeGroupMember error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }
        return PeerOperationResult(true)
    }

    // ==================== 频道/超级群成员管理 ====================

    /**
     * 邀请用户加入频道/超级群（channels.inviteToChannel）
     *
     * iOS 对应: _internal_addChannelMember / _internal_addChannelMembers
     *
     * @param channelId 频道 ID
     * @param channelAccessHash 频道 accessHash
     * @param userId 要邀请的用户 ID
     * @param userAccessHash 用户 accessHash
     */
    public func inviteToChannel(
        channelId: Int64,
        channelAccessHash: Int64,
        userId: Int64,
        userAccessHash: Int64
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] inviteToChannel channelId=${channelId} userId=${userId}")
        let client = getMTProtoClient()

        let req = ChannelsInviteToChannel()
        let ch = InputChannel()
        ch.channelId = channelId
        ch.accessHash = channelAccessHash
        req.channel = ch

        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = userAccessHash
        req.users.add(inputUser)

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] inviteToChannel error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }
        return PeerOperationResult(true)
    }

    /**
     * 踢出频道/超级群成员（channels.editBanned，设置 view_messages=true）
     *
     * iOS 对应: _internal_removePeerMember (channels)
     *
     * @param channelId 频道 ID
     * @param channelAccessHash 频道 accessHash
     * @param userId 要踢出的用户 ID
     * @param userAccessHash 用户 accessHash
     */
    public func kickChannelMember(
        channelId: Int64,
        channelAccessHash: Int64,
        userId: Int64,
        userAccessHash: Int64
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] kickChannelMember channelId=${channelId} userId=${userId}")

        let bannedRights = ChatBannedRights()
        bannedRights.flags = 1  // bit 0: view_messages = kicked
        bannedRights.untilDate = 0  // 永久

        return this.editBanned(channelId, channelAccessHash, userId, userAccessHash, bannedRights)
    }

    // ==================== 创建群组/频道 ====================

    /**
     * 创建基础群组（messages.createChat）
     *
     * iOS 对应: _internal_createGroup
     *
     * @param title 群组名称
     * @param userIds 初始成员列表 (userId, accessHash) 对
     */
    public func createGroup(title: String, userIds: ArrayList<(Int64, Int64)>): CreatePeerResult {
        let client = getMTProtoClient()
        let result = CreatePeerResult()

        var authUserId: Int64 = 0
        match (getAuthStorage().getUserData()) {
            case Some(user) => authUserId = user.id
            case None => ()
        }
        Hilog.info(0, "CjTelegram",
            "[GroupCreateDiag] begin dc=${client.getCurrentDcId()} " +
            "apiId=${MTProtoConfig.getApiId()} layer=${MTProtoConfig.LAYER} titleChars=${title.size} members=${userIds.size}")

        let req = MessagesCreateChat()
        req.title = title
        // Telegram-iOS CreateGroup.swift normalizes a missing global auto-remove
        // timeout to zero and sends ttl_period with flags.0 set.
        req.ttlPeriod = Some(0)
        var selfSelectionCount: Int64 = 0
        for ((uid, hash) in userIds) {
            // Telegram-iOS only appends apiInputUser(peer) when Postbox can
            // resolve a complete InputUser. Never turn a missing peer/access
            // hash into inputUser(id, 0) and send a misleading RPC.
            if (uid <= 0 || hash == 0) {
                result.errorCode = "INPUT_USER_INVALID"
                Hilog.info(0, "CjTelegram",
                    "[PeersService] createGroup rejected unresolved input user id=${uid}")
                return result
            }
            if (uid == authUserId) { selfSelectionCount += 1 }
            let inputUser = InputUser()
            inputUser.userId = uid
            inputUser.accessHash = hash
            req.users.add(inputUser)
        }

        let requestData = req.toBytes()
        // Safe wire-shape diagnostics: no title/member names and no access-hash bytes.
        // 4 ctor + 4 flags + 4 vector ctor + 4 count + N*(4 ctor+8 id+8 hash)
        // + TL-string title + optional ttl_period. This is enough to compare the
        // generated request to Telegram-iOS Api42.swift without exposing secrets.
        Hilog.info(0, "CjTelegram",
            "[GroupCreateDiag] wire ctor=0x92ceddd4 flags=1 vectorCount=${req.users.size} " +
            "selfSelections=${selfSelectionCount} ttl=0 bytes=${requestData.size} connected=${client.isTransportConnected()}")
        let responseData = client.sendRequest(requestData)
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[GroupCreateDiag] empty response bytes=${responseData.size}")
            result.errorCode = "NETWORK_ERROR"
            return result
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram",
                "[GroupCreateDiag] rpcError code=${errorCode} message=${errMsg} " +
                "dc=${client.getCurrentDcId()} apiId=${MTProtoConfig.getApiId()} layer=${MTProtoConfig.LAYER}")
            result.errorCode = errMsg
            return result
        }

        // Current schema: messages.invitedUsers#7f5defa6 updates:Updates
        // missing_invitees:Vector<MissingInvitee>. Treating every non-empty
        // response as success left the creation screen with neither a peer id
        // nor an applied update container.
        if (constructor != 0x7f5defa6) {
            Hilog.info(0, "CjTelegram", "[PeersService] createGroup unexpected response ctor=${constructor}")
            result.errorCode = "UNEXPECTED_RESPONSE"
            return result
        }

        match (this.extractCreatedBasicGroup(responseData, title)) {
            case Some(created) =>
                result.peerId = created.id
                // iOS stateManager.addUpdates 会把 Updates.chats 写入 Postbox（updatePeers）。
                // 这里的 Updates 向量含 updateChatParticipants 等未解析项，UpdatesManager 会在
                // 该处停止并转 getDifference，chats 向量不会被消费；不先落实体，群创建服务
                // 消息投影出的会话行只能拿到 "Chat <id>" 占位名并持久化到冷启动列表。
                getRealChatListService().cacheChatEntity(created)
            case None => ()
        }
        // The inner Updates object begins immediately after invitedUsers' ctor.
        // UpdatesManager consumes exactly that object and safely ignores the
        // trailing missing_invitees vector, matching iOS stateManager.addUpdates.
        let innerUpdates = ByteUtils.slice(responseData, 4, responseData.size)
        getUpdatesManager().handleRawUpdate(innerUpdates)
        result.success = true
        result.peerType = "chat"
        Hilog.info(0, "CjTelegram", "[PeersService] createGroup success peerId=${result.peerId}")
        return result
    }

    /**
     * Locate and fully parse the basic Chat object embedded in invitedUsers.updates.
     * Matching the title after ChatResponse parsing prevents a coincidental byte
     * sequence elsewhere in the response from being accepted as a peer id.
     */
    private func extractCreatedBasicGroup(data: Array<Byte>, title: String): Option<ChatResponse> {
        var pos: Int64 = 4
        while (pos + 16 <= data.size) {
            if (UInt8(data[pos]) == 0x56 && UInt8(data[pos + 1]) == 0xF2 &&
                UInt8(data[pos + 2]) == 0xCB && UInt8(data[pos + 3]) == 0x41) {
                try {
                    let candidateData = ByteUtils.slice(data, pos, data.size)
                    let candidate = ChatResponse.deserializeBoxed(TLDeserializer(candidateData))
                    if (candidate.id > 0 && !candidate.isChannel && candidate.title == title) {
                        return Some(candidate)
                    }
                } catch (_e: Exception) {}
            }
            pos += 1
        }
        return None
    }

    /**
     * 创建频道或超级群（channels.createChannel）
     *
     * iOS 对应: _internal_createChannel (broadcast=true) / createSupergroup (megagroup=true)
     *
     * @param title 频道/超级群名称
     * @param about 简介描述
     * @param broadcast 是否为广播频道（false = 超级群）
     */
    public func createChannel(title: String, about: String, broadcast!: Bool = true): CreatePeerResult {
        Hilog.info(0, "CjTelegram", "[PeersService] createChannel title=${title} broadcast=${broadcast}")
        let client = getMTProtoClient()
        let result = CreatePeerResult()

        let req = ChannelsCreateChannel()
        req.title = title
        req.about = about
        req.broadcast = broadcast
        req.megagroup = !broadcast

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] createChannel error: ${errMsg}")
            result.errorCode = errMsg
            return result
        }

        // Updates 响应成功，服务器将在 getDifference 推送新建频道信息
        result.success = true
        result.peerType = "channel"
        return result
    }

    // ==================== 管理员权限管理 ====================

    /**
     * 设置/修改/撤销管理员权限（channels.editAdmin）
     *
     * iOS 对应: _internal_updateChannelAdminRights
     * TL: channels.editAdmin#d33c8902 channel:InputChannel user_id:InputUser
     *     admin_rights:ChatAdminRights rank:string = Updates
     *
     * @param adminFlags 权限位标志（0 = 撤销管理员）
     * @param rank 管理员头衔（""=默认）
     */
    public func editAdmin(
        channelId: Int64,
        channelAccessHash: Int64,
        userId: Int64,
        userAccessHash: Int64,
        adminFlags: Int32,
        rank!: String = ""
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] editAdmin channelId=${channelId} userId=${userId} flags=${adminFlags}")
        let client = getMTProtoClient()

        let req = ChannelsEditAdmin()
        let ch = InputChannel()
        ch.channelId = channelId
        ch.accessHash = channelAccessHash
        req.channel = ch

        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = userAccessHash
        req.userId = inputUser

        req.adminRights.flags = adminFlags
        req.rank = rank

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] editAdmin error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }
        return PeerOperationResult(true)
    }

    // ==================== P2-135: 所有权转移 ====================

    /**
     * 转让频道所有权（channels.editCreator）
     *
     * iOS 对应: _internal_updateChannelCreator (Telegram-iOS/TelegramApi)
     * TL: channels.editCreator#8f38cd1f channel:InputChannel user_id:InputUser
     *     password:InputCheckPasswordSRP = Updates
     * ctor verified (python): struct.unpack('>i', struct.pack('>I', 0x8f38cd1f))[0] = -1892102881
     *
     * SRP 密码验证由调用方（上层）完成后传入已构造的 InputCheckPasswordSRP；
     * 本层只做序列化与网络发送，不计算 SRP 参数。
     * 响应 Updates 四变体，任意一种均视为成功（不裸读内层）。
     *
     * @param channelId          频道 ID
     * @param channelAccessHash  频道 accessHash
     * @param userId             新所有者的用户 ID
     * @param userAccessHash     新所有者的 accessHash
     * @param password           已构造的 SRP 密码验证对象（srpId/A/M1 均由上层填充）
     */
    public func editCreator(
        channelId: Int64,
        channelAccessHash: Int64,
        userId: Int64,
        userAccessHash: Int64,
        password: InputCheckPasswordSRP
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] editCreator channelId=${channelId} newOwnerId=${userId}")
        let client = getMTProtoClient()

        let req = ChannelsEditCreator()
        let ch = InputChannel()
        ch.channelId = channelId
        ch.accessHash = channelAccessHash
        req.channel = ch

        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = userAccessHash
        req.userId = inputUser

        req.password = password

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] editCreator error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }

        if (constructor == 0x74ae4240 || constructor == 0x725b04c3 || constructor == 0x78d4dec1 || constructor == 0xe317af7e) {
            Hilog.info(0, "CjTelegram", "[PeersService] editCreator success: channelId=${channelId} newOwnerId=${userId}")
            return PeerOperationResult(true)
        }

        Hilog.info(0, "CjTelegram", "[PeersService] editCreator unexpected ctor: ${constructor}")
        return PeerOperationResult(false, errorCode: "UNEXPECTED_RESPONSE")
    }

    // ==================== 封禁/解封管理 ====================

    /**
     * 封禁/解封频道成员（channels.editBanned）
     *
     * iOS 对应: _internal_updateChannelMemberBannedRights
     * TL: channels.editBanned#96e6cd81 channel:InputChannel
     *     participant:InputPeer banned_rights:ChatBannedRights = Updates
     *
     * @param bannedRights 封禁权限对象（flags=0 且 untilDate=0 = 解封）
     */
    public func editBanned(
        channelId: Int64,
        channelAccessHash: Int64,
        userId: Int64,
        userAccessHash: Int64,
        bannedRights: ChatBannedRights
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] editBanned channelId=${channelId} userId=${userId} bannedFlags=${bannedRights.flags}")
        let client = getMTProtoClient()

        let req = ChannelsEditBanned()
        let ch = InputChannel()
        ch.channelId = channelId
        ch.accessHash = channelAccessHash
        req.channel = ch

        let participant = InputPeerUser()
        participant.userId = userId
        participant.accessHash = userAccessHash
        req.participant = participant

        req.bannedRights = bannedRights

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] editBanned error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }
        return PeerOperationResult(true)
    }

    /**
     * 解封频道成员（channels.editBanned，flags=0）
     */
    public func unbanChannelMember(
        channelId: Int64,
        channelAccessHash: Int64,
        userId: Int64,
        userAccessHash: Int64
    ): PeerOperationResult {
        let rights = ChatBannedRights()
        rights.flags = 0
        rights.untilDate = 0
        return this.editBanned(channelId, channelAccessHash, userId, userAccessHash, rights)
    }

    // ==================== P2-151: Resolve peer ====================

    /**
     * 通过用户名查找 peer（contacts.resolveUsername#725afbbc）
     *
     * iOS 对应: _internal_resolvePeerByName
     * 响应: contacts.resolvedPeer#7f077ad9 peer:Peer chats:Vector<Chat> users:Vector<User>
     *
     * @param username 要查找的用户名（不含 @）
     * @return PeerResolveResult
     */
    public func resolveByUsername(username: String): PeerResolveResult {
        Hilog.info(0, "CjTelegram", "[PeersService] resolveByUsername: ${username}")
        let result = PeerResolveResult()
        let client = getMTProtoClient()

        let req = ContactsResolveUsername()
        req.username = username

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }

        this.parseResolvedPeer(responseData, result)
        return result
    }

    /**
     * 通过手机号查找 peer（contacts.resolvePhone#8af94344）
     *
     * iOS 对应: _internal_resolvePeerByPhone (ResolvePeerByName.swift)
     * 响应: contacts.resolvedPeer#7f077ad9 peer:Peer chats:Vector<Chat> users:Vector<User>
     *
     * @param phone 手机号（e.164 格式，如 "+79161234567"）
     * @return PeerResolveResult
     */
    public func resolveByPhone(phone: String): PeerResolveResult {
        Hilog.info(0, "CjTelegram", "[PeersService] resolveByPhone: ${phone}")
        let result = PeerResolveResult()
        let client = getMTProtoClient()

        let req = ContactsResolvePhone()
        req.phone = phone

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }

        this.parseResolvedPeer(responseData, result)
        return result
    }

    /**
     * 通过已知的 peerId 构造 PeerResolveResult（本地缓存 accessHash 时直接返回）
     *
     * iOS 对应: TelegramEngine.Peers.resolve(ByID:) — 依赖 postbox 缓存
     * 平台差异：我们用 PeerStore 缓存替代 Postbox。
     *
     * @param peerId  peer 的 ID
     * @param peerType "user" | "chat" | "channel"
     * @param accessHash  (0 for basic chats)
     */
    public func resolveById(peerId: Int64, peerType: String, accessHash!: Int64 = 0): PeerResolveResult {
        Hilog.info(0, "CjTelegram", "[PeersService] resolveById: peerId=${peerId} type=${peerType}")
        let result = PeerResolveResult()

        // Check local PeerStore first (IntermediatePeer has id/name/username/peerType but no accessHash)
        match (getPeerStore().getLocalPeer(peerId)) {
            case Some(localPeer) =>
                result.success = true
                result.peerId = localPeer.id
                result.peerType = localPeer.peerType
                result.accessHash = accessHash  // use caller-provided accessHash
                result.displayName = localPeer.name
                result.username = localPeer.username
                return result
            case None => ()
        }

        // Fall back to provided values
        result.success = peerId > 0
        result.peerId = peerId
        result.peerType = peerType
        result.accessHash = accessHash
        return result
    }

    /**
     * 解析 contacts.resolvedPeer 响应
     *
     * contacts.resolvedPeer#7f077ad9 peer:Peer chats:Vector<Chat> users:Vector<User> (TL schema verified)
     *
     * peer: peerUser#59511722 user_id:long
     *     | peerChat#36c6019a chat_id:long
     *     | peerChannel#a2a5371e channel_id:long
     */
    private func parseResolvedPeer(data: Array<Byte>, result: PeerResolveResult): Unit {
        try {
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()

            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let _ = d.readInt32()
                let msg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeersService] resolveUsername error: ${msg}")
                result.errorCode = msg
                return
            }

            // contacts.resolvedPeer#7f077ad9 (TL schema verified)
            if (ctor != 0x7f077ad9) {
                Hilog.info(0, "CjTelegram", "[PeersService] resolveUsername unexpected ctor: ${ctor}")
                result.errorCode = "UNEXPECTED_RESPONSE"
                return
            }

            // peer: Peer (boxed)
            let peerCtor = d.readUInt32()
            if (peerCtor == 0x59511722) {
                result.peerType = "user"
                result.peerId = d.readInt64()
            } else if (peerCtor == 0x36c6019a) {
                result.peerType = "chat"
                result.peerId = d.readInt64()
            } else if (peerCtor == 0xa2a5371e) {
                result.peerType = "channel"
                result.peerId = d.readInt64()
            } else {
                result.errorCode = "UNKNOWN_PEER_TYPE"
                return
            }

            // chats: Vector<Chat> — parse first channel to get accessHash
            // channel#7482147e flags:# flags2:# id:long access_hash:flags.13?long title:string ...
            // channelForbidden#17d493d5 flags:# id:long access_hash:long title:string until_date:flags.16?int
            try {
                let _ = d.readUInt32()  // vector ctor (0x1cb5c415)
                let chatCount = d.readInt32()
                if (chatCount > 0) {
                    let chatCtor = d.readUInt32()
                    if (chatCtor == 0x7482147e) {
                        // channel#7482147e: flags(int32) + flags2(int32) + id(int64) + access_hash:flags.13?long + ...
                        let flags = d.readInt32()
                        let _ = d.readInt32()  // flags2
                        result.peerId = d.readInt64()  // id
                        // access_hash present if flags bit 13 set
                        if ((flags & 8192) != 0) {
                            result.accessHash = d.readInt64()
                        }
                        // do not read further; remaining fields not needed and vector not iterated beyond first
                    } else if (chatCtor == 0x17d493d5) {
                        // channelForbidden#17d493d5: flags(int32) + id(long) + access_hash(long) [mandatory] + title + until_date?
                        let _ = d.readInt32()  // flags
                        result.peerId = d.readInt64()  // id
                        result.accessHash = d.readInt64()  // access_hash (always present)
                    }
                }
            } catch (_: Exception) {}

            // users: Vector<User> — parse first user to get accessHash + name
            try {
                let _ = d.readUInt32()  // vector ctor
                let userCount = d.readInt32()
                if (userCount > 0) {
                    let user = UserResponse.deserializeBoxed(d)
                    if (result.peerType == "user") {
                        result.peerId = user.id
                        result.accessHash = user.accessHash
                        result.displayName = if (user.lastName.size > 0) {
                            "${user.firstName} ${user.lastName}"
                        } else {
                            user.firstName
                        }
                        result.username = user.username
                    }
                }
            } catch (_: Exception) {}

            result.success = result.peerId > 0
            Hilog.info(0, "CjTelegram", "[PeersService] resolveUsername done: peerId=${result.peerId} type=${result.peerType}")

        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeersService] parseResolvedPeer error: ${e}")
            result.errorCode = "PARSE_ERROR"
        }
    }

    // ==================== P2-151: Username / addressName management ====================

    /**
     * 检查用户名可用性 - 账号级（account.checkUsername#2714d86c）
     *
     * iOS 对应: _internal_addressNameAvailability (AddressNames.swift)
     *
     * @param username 要检查的用户名
     * @return true = 可用, false = 已占用或无效
     */
    public func checkUsernameAvailability(username: String): Bool {
        Hilog.info(0, "CjTelegram", "[PeersService] checkUsernameAvailability: ${username}")
        let client = getMTProtoClient()

        let req = AccountCheckUsername()
        req.username = username

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return false
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        return ctor == TLConstructors.BOOL_TRUE
    }

    /**
     * 检查用户名可用性 - 账号级四态（TC-0082 R3 修法 F1-a，新增方法，不改动上面
     * checkUsernameAvailability 的既有签名——providers/PeersDataProvider.cj 消费该布尔方法，
     * 不在本次返修 allowlist 内，不能改其调用约定）。
     *
     * iOS 对应: _internal_addressNameAvailability (AddressNames.swift:60-75)：
     *   boolTrue → available；boolFalse → taken；
     *   RPC error "USERNAME_PURCHASE_AVAILABLE" → purchaseAvailable；
     *   RPC error "USERNAME_OCCUPIED" → taken；其余任何 error → invalid。
     */
    public func checkUsernameAvailabilityDetailed(username: String): AddressNameAvailability {
        Hilog.info(0, "CjTelegram", "[PeersService] checkUsernameAvailabilityDetailed: ${username}")
        let client = getMTProtoClient()

        let req = AccountCheckUsername()
        req.username = username

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return AddressNameAvailability.Invalid
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.BOOL_TRUE) {
            return AddressNameAvailability.Available
        }
        if (ctor == TLConstructors.BOOL_FALSE) {
            return AddressNameAvailability.Taken
        }
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] checkUsernameAvailabilityDetailed error: ${errMsg}")
            if (errMsg.contains("USERNAME_PURCHASE_AVAILABLE")) {
                return AddressNameAvailability.PurchaseAvailable
            }
            if (errMsg.contains("USERNAME_OCCUPIED")) {
                return AddressNameAvailability.Taken
            }
            return AddressNameAvailability.Invalid
        }
        return AddressNameAvailability.Invalid
    }

    /**
     * 更新当前账号的用户名（account.updateUsername#3e0bdd7c）
     *
     * iOS 对应: _internal_updateAddressName (account branch, AddressNames.swift:166)
     *
     * @param username 新用户名（""= 清除用户名）
     */
    public func updateAccountUsername(username: String): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] updateAccountUsername: '${username}'")
        let client = getMTProtoClient()

        let req = AccountUpdateUsername()
        req.username = username

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] updateAccountUsername error: ${msg}")
            return PeerOperationResult(false, errorCode: msg)
        }
        // Response is a User object — any non-error response is success
        return PeerOperationResult(true)
    }

    /**
     * 更新频道/超级群的用户名（channels.updateUsername#3514b3de）
     *
     * iOS 对应: _internal_updateAddressName (channel branch, AddressNames.swift:177)
     *
     * @param channelId 频道 ID
     * @param channelAccessHash 频道 accessHash
     * @param username 新用户名（""= 清除）
     */
    public func updateChannelUsername(
        channelId: Int64,
        channelAccessHash: Int64,
        username: String
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] updateChannelUsername: channelId=${channelId} '${username}'")
        let client = getMTProtoClient()

        let req = ChannelsUpdateUsername()
        let ch = InputChannel()
        ch.channelId = channelId
        ch.accessHash = channelAccessHash
        req.channel = ch
        req.username = username

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] updateChannelUsername error: ${msg}")
            return PeerOperationResult(false, errorCode: msg)
        }
        return PeerOperationResult(true)
    }

    /**
     * 切换账号某个用户名的激活状态（account.toggleUsername#58d6b376）
     *
     * iOS 对应: _internal_toggleAddressNameActive (account branch, AddressNames.swift:263)
     *
     * @param username 要切换的用户名
     * @param active   是否激活
     */
    public func toggleAccountUsername(username: String, active: Bool): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] toggleAccountUsername: '${username}' active=${active}")
        let client = getMTProtoClient()

        let req = AccountToggleUsername()
        req.username = username
        req.active = active

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] toggleAccountUsername error: ${msg}")
            return PeerOperationResult(false, errorCode: msg)
        }
        return PeerOperationResult(ctor == TLConstructors.BOOL_TRUE)
    }

    /**
     * 切换频道某个用户名的激活状态（channels.toggleUsername#50f24105）
     *
     * iOS 对应: _internal_toggleAddressNameActive (channel branch, AddressNames.swift:321)
     *
     * @param channelId          频道 ID
     * @param channelAccessHash  频道 accessHash
     * @param username           要切换的用户名
     * @param active             是否激活
     */
    public func toggleChannelUsername(
        channelId: Int64,
        channelAccessHash: Int64,
        username: String,
        active: Bool
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] toggleChannelUsername: channelId=${channelId} '${username}' active=${active}")
        let client = getMTProtoClient()

        let req = ChannelsToggleUsername()
        let ch = InputChannel()
        ch.channelId = channelId
        ch.accessHash = channelAccessHash
        req.channel = ch
        req.username = username
        req.active = active

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] toggleChannelUsername error: ${msg}")
            return PeerOperationResult(false, errorCode: msg)
        }
        return PeerOperationResult(ctor == TLConstructors.BOOL_TRUE)
    }

    /**
     * 重新排序账号的用户名（account.reorderUsernames#ef500eab）
     *
     * iOS 对应: _internal_reorderAddressNames (account branch, AddressNames.swift:455)
     *
     * @param order 用户名列表（激活的用户名按优先级排序）
     */
    public func reorderAccountUsernames(order: ArrayList<String>): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] reorderAccountUsernames: ${order.size} names")
        let client = getMTProtoClient()

        let req = AccountReorderUsernames()
        for (name in order) {
            req.order.add(name)
        }

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] reorderAccountUsernames error: ${msg}")
            return PeerOperationResult(false, errorCode: msg)
        }
        return PeerOperationResult(ctor == TLConstructors.BOOL_TRUE)
    }

    /**
     * 重新排序频道的用户名（channels.reorderUsernames#b45ced1d）
     *
     * iOS 对应: _internal_reorderAddressNames (channel branch, AddressNames.swift:471)
     *
     * @param channelId          频道 ID
     * @param channelAccessHash  频道 accessHash
     * @param order              用户名列表
     */
    public func reorderChannelUsernames(
        channelId: Int64,
        channelAccessHash: Int64,
        order: ArrayList<String>
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] reorderChannelUsernames: channelId=${channelId} ${order.size} names")
        let client = getMTProtoClient()

        let req = ChannelsReorderUsernames()
        let ch = InputChannel()
        ch.channelId = channelId
        ch.accessHash = channelAccessHash
        req.channel = ch
        for (name in order) {
            req.order.add(name)
        }

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] reorderChannelUsernames error: ${msg}")
            return PeerOperationResult(false, errorCode: msg)
        }
        return PeerOperationResult(ctor == TLConstructors.BOOL_TRUE)
    }

    // ==================== P2-151: Title / Description ====================

    /**
     * 修改频道/超级群标题（channels.editTitle#566decd0）
     *
     * iOS 对应: _internal_updatePeerTitle (channel branch, UpdatePeerInfo.swift:17)
     *
     * @param channelId          频道 ID
     * @param channelAccessHash  频道 accessHash
     * @param title              新标题
     */
    public func editChannelTitle(
        channelId: Int64,
        channelAccessHash: Int64,
        title: String
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] editChannelTitle: channelId=${channelId} '${title}'")
        let client = getMTProtoClient()

        let req = ChannelsEditTitle()
        let ch = InputChannel()
        ch.channelId = channelId
        ch.accessHash = channelAccessHash
        req.channel = ch
        req.title = title

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] editChannelTitle error: ${msg}")
            return PeerOperationResult(false, errorCode: msg)
        }
        return PeerOperationResult(true)
    }

    /**
     * 修改基础群组标题（messages.editChatTitle#73783ffd）
     *
     * iOS 对应: _internal_updatePeerTitle (chat branch, UpdatePeerInfo.swift:32)
     *
     * @param chatId  基础群组 ID
     * @param title   新标题
     */
    public func editChatTitle(chatId: Int64, title: String): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] editChatTitle: chatId=${chatId} '${title}'")
        let client = getMTProtoClient()

        let req = MessagesEditChatTitle()
        req.chatId = chatId
        req.title = title

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] editChatTitle error: ${msg}")
            return PeerOperationResult(false, errorCode: msg)
        }
        return PeerOperationResult(true)
    }

    /**
     * 修改群组/频道简介（messages.editChatAbout#def60797）
     *
     * iOS 对应: _internal_updatePeerDescription (UpdatePeerInfo.swift:63)
     * 适用于 chat 和 channel（通过 InputPeer 区分）
     *
     * @param peerType   "chat" | "channel" | "user"
     * @param peerId     peer ID
     * @param accessHash peer accessHash（chat 时传 0）
     * @param about      新简介（""= 清除）
     */
    public func editDescription(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        about: String
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] editDescription: peerId=${peerId} '${about}'")
        let client = getMTProtoClient()

        let req = MessagesEditChatAbout()
        if (peerType == "channel") {
            let inputPeer = InputPeerChannel()
            inputPeer.channelId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        } else if (peerType == "chat") {
            let inputPeer = InputPeerChat()
            inputPeer.chatId = peerId
            req.peer = inputPeer
        } else {
            let inputPeer = InputPeerUser()
            inputPeer.userId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        }
        req.about = about

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] editDescription error: ${msg}")
            return PeerOperationResult(false, errorCode: msg)
        }
        return PeerOperationResult(ctor == TLConstructors.BOOL_TRUE)
    }

    /**
     * 更新当前用户的自我介绍（account.updateProfile#78515775 about 字段）
     *
     * iOS 对应: account.updateProfile about 分支
     *
     * @param about 新的自我介绍（""= 清除）
     */
    public func updateProfileAbout(about: String): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] updateProfileAbout: '${about}'")
        let client = getMTProtoClient()

        let req = AccountUpdateProfile()
        req.about = Some(about)

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] updateProfileAbout error: ${msg}")
            return PeerOperationResult(false, errorCode: msg)
        }
        // Response is User object on success
        return PeerOperationResult(true)
    }

    // ==================== P2-151: Mute / Notify settings ====================

    /**
     * 设置指定 peer 的静音状态（account.updateNotifySettings#84be5b93）
     *
     * iOS 对应: _internal_updatePeerMuteSetting (ChangePeerNotificationSettings.swift:132)
     *
     * 持久化策略：
     * - 服务端通过 TL 更新
     * - 本地通过内存缓存跟踪，Key 格式 "peer_mute_{peerId}" 存入 AuthStorage
     *
     * @param peerType    "user" | "chat" | "channel"
     * @param peerId      peer ID
     * @param accessHash  peer accessHash
     * @param muteUntil   静音到期时间戳：0=取消静音, 2147483647=永久静音
     */
    public func updatePeerMuteSettings(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        muteUntil: Int32
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] updatePeerMuteSettings: peerId=${peerId} muteUntil=${muteUntil}")
        let client = getMTProtoClient()

        let req = AccountUpdatePeerNotifySettings()
        if (peerType == "channel") {
            let inputPeer = InputPeerChannel()
            inputPeer.channelId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        } else if (peerType == "chat") {
            let inputPeer = InputPeerChat()
            inputPeer.chatId = peerId
            req.peer = inputPeer
        } else {
            let inputPeer = InputPeerUser()
            inputPeer.userId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        }
        req.muteUntil = muteUntil

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] updatePeerMuteSettings error: ${msg}")
            return PeerOperationResult(false, errorCode: msg)
        }

        // Persist mute state locally via AuthStorage key-value
        this.savePeerMuteLocal(peerId, muteUntil)

        Hilog.info(0, "CjTelegram", "[PeersService] updatePeerMuteSettings success: peerId=${peerId}")
        return PeerOperationResult(true)
    }

    /**
     * 读取已缓存的 peer 静音状态（本地持久化，不需要网络）
     *
     * @param peerId peer ID
     * @return muteUntil（0 = 未静音, 2147483647 = 永久）
     */
    public func getPeerMuteLocal(peerId: Int64): Int32 {
        let storage = getAuthStorage()
        let key = "peer_mute_${peerId}"
        let val = storage.getIntValue(key, default_: 0)
        return Int32(val)
    }

    /**
     * 持久化 peer 静音状态到 AuthStorage
     */
    private func savePeerMuteLocal(peerId: Int64, muteUntil: Int32): Unit {
        try {
            let storage = getAuthStorage()
            let key = "peer_mute_${peerId}"
            storage.setIntValue(key, Int64(muteUntil))
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeersService] savePeerMuteLocal error: ${e}")
        }
    }

    // ==================== P2-136: 默认成员权限 / 慢速模式 ====================

    /**
     * 设置群/频道的默认成员权限（messages.editChatDefaultBannedRights#a5866b41）
     *
     * iOS 对应: TelegramEngine.Peers._internal_updateDefaultRestrictionSettings
     *   (ChannelBlacklist.swift:156)
     * TL: messages.editChatDefaultBannedRights#a5866b41
     *     peer:InputPeer banned_rights:ChatBannedRights = Updates
     * ctor: 0xa5866b41 (verified: iOS appendInt32(-1517917375))
     *
     * ChatBannedRights 权限位（逐位设置 = 禁止该操作）：
     *   bit 0: view_messages   bit 1: send_messages    bit 2: send_media
     *   bit 3: send_stickers   bit 4: send_gifs        bit 5: send_games
     *   bit 6: send_inline     bit 7: embed_links      bit 8: send_polls
     *   bit 10: change_info    bit 15: invite_users    bit 17: pin_messages
     *   bit 18: manage_topics  bit 19: send_photos     bit 20: send_videos
     *   bit 21: send_roundvideos bit 22: send_audios   bit 23: send_voices
     *   bit 24: send_docs      bit 25: send_plain
     *
     * 复用既有 ChatBannedRights 序列化（同 editBanned 用的类）
     *
     * @param peerType    "chat" | "channel"
     * @param peerId      peer ID
     * @param accessHash  peer accessHash（basic chat 传 0）
     * @param bannedRights 默认权限位对象（flags 为权限位组合，untilDate=0 表示永久）
     */
    public func editDefaultBannedRights(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        bannedRights: ChatBannedRights
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] editDefaultBannedRights: peerId=${peerId} peerType=${peerType} flags=${bannedRights.flags}")
        let client = getMTProtoClient()

        let req = MessagesEditChatDefaultBannedRights()
        if (peerType == "channel") {
            let inputPeer = InputPeerChannel()
            inputPeer.channelId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        } else if (peerType == "chat") {
            let inputPeer = InputPeerChat()
            inputPeer.chatId = peerId
            req.peer = inputPeer
        } else {
            let inputPeer = InputPeerUser()
            inputPeer.userId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        }
        req.bannedRights = bannedRights

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] editDefaultBannedRights error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }

        if (ctor == 0x74ae4240 || ctor == 0x725b04c3 || ctor == 0x78d4dec1 || ctor == 0xe317af7e) {
            Hilog.info(0, "CjTelegram", "[PeersService] editDefaultBannedRights success: peerId=${peerId}")
            return PeerOperationResult(true)
        }

        Hilog.info(0, "CjTelegram", "[PeersService] editDefaultBannedRights unexpected ctor: ${ctor}")
        return PeerOperationResult(false, errorCode: "UNEXPECTED_RESPONSE")
    }

    /**
     * 设置超级群的慢速模式间隔（channels.toggleSlowMode#edd49ef0）
     *
     * iOS 对应: TelegramEngine.Peers._internal_updateChannelSlowModeIntermediate
     *   (SlowMode.swift:21)
     * TL: channels.toggleSlowMode#edd49ef0 channel:InputChannel seconds:int = Updates
     * ctor: 0xedd49ef0 (verified: iOS appendInt32(-304832784))
     *
     * @param channelId         超级群/频道的 ID
     * @param channelAccessHash 超级群/频道的 accessHash
     * @param seconds           慢速模式间隔（秒）；0=关闭；合法值: 0/10/30/60/300/900/3600
     */
    public func toggleSlowMode(
        channelId: Int64,
        channelAccessHash: Int64,
        seconds: Int32
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] toggleSlowMode: channelId=${channelId} seconds=${seconds}")
        let client = getMTProtoClient()

        let req = ChannelsToggleSlowMode()
        let ch = InputChannel()
        ch.channelId = channelId
        ch.accessHash = channelAccessHash
        req.channel = ch
        req.seconds = seconds

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] toggleSlowMode error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }

        if (ctor == 0x74ae4240 || ctor == 0x725b04c3 || ctor == 0x78d4dec1 || ctor == 0xe317af7e) {
            Hilog.info(0, "CjTelegram", "[PeersService] toggleSlowMode success: channelId=${channelId} seconds=${seconds}")
            return PeerOperationResult(true)
        }

        Hilog.info(0, "CjTelegram", "[PeersService] toggleSlowMode unexpected ctor: ${ctor}")
        return PeerOperationResult(false, errorCode: "UNEXPECTED_RESPONSE")
    }

    // ==================== P2-146: 聊天历史自动删除定时 ====================

    /**
     * 设置指定 peer 的聊天历史自动删除定时（messages.setHistoryTTL#b80e5fe4）
     *
     * iOS 对应: TelegramEngine.Peers._internal_setChatHistoryTTL
     * TL: messages.setHistoryTTL#b80e5fe4 peer:InputPeer period:int = Updates
     * ctor 来源: iOS Api42.swift:9929 buffer.appendInt32(-1207017500) = 0xb80e5fe4
     *
     * period 预设常量:
     *   0       = 关闭自动删除
     *   86400   = 24 小时
     *   604800  = 7 天
     *   2678400 = 31 天
     *   其他正整数 = 自定义秒数
     *
     * 响应: Updates 四变体之一（不裸读内层；任意 Updates ctor 均视为成功）
     *
     * @param peerType   "user" | "chat" | "channel"
     * @param peerId     peer ID
     * @param accessHash peer accessHash（chat 传 0）
     * @param period     自动删除间隔（秒），0 = 关闭
     */
    public func setHistoryTTL(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        period: Int32
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] setHistoryTTL: peerId=${peerId} peerType=${peerType} period=${period}")
        let client = getMTProtoClient()

        let req = MessagesSetHistoryTTL()
        if (peerType == "channel") {
            let inputPeer = InputPeerChannel()
            inputPeer.channelId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        } else if (peerType == "chat") {
            let inputPeer = InputPeerChat()
            inputPeer.chatId = peerId
            req.peer = inputPeer
        } else {
            let inputPeer = InputPeerUser()
            inputPeer.userId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        }
        req.period = period

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] setHistoryTTL error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }

        if (ctor == 0x74ae4240 || ctor == 0x725b04c3 || ctor == 0x78d4dec1 || ctor == 0xe317af7e) {
            Hilog.info(0, "CjTelegram", "[PeersService] setHistoryTTL success: peerId=${peerId} period=${period}")
            return PeerOperationResult(true)
        }

        Hilog.info(0, "CjTelegram", "[PeersService] setHistoryTTL unexpected ctor: ${ctor}")
        return PeerOperationResult(false, errorCode: "UNEXPECTED_RESPONSE")
    }

    // ==================== P2-151: Invite Links ====================

    /**
     * 创建新邀请链接（messages.exportChatInvite#a455de90）
     *
     * iOS 对应: _internal_createPeerExportedInvitation (InvitationLinks.swift:47)
     *
     * @param peerType    "chat" | "channel"
     * @param peerId      peer ID
     * @param accessHash  peer accessHash（chat 时传 0）
     * @param expireDate  过期时间戳（0 = 不过期）
     * @param usageLimit  使用次数上限（0 = 不限）
     * @param requestNeeded 是否需要管理员批准
     * @param title       链接标题（可选）
     */
    public func createInviteLink(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        expireDate!: Int32 = 0,
        usageLimit!: Int32 = 0,
        requestNeeded!: Bool = false,
        title!: String = ""
    ): InviteLinkResult {
        Hilog.info(0, "CjTelegram", "[PeersService] createInviteLink: peerId=${peerId}")
        let result = InviteLinkResult()
        let client = getMTProtoClient()

        let req = MessagesExportChatInvite()
        if (peerType == "channel") {
            let inputPeer = InputPeerChannel()
            inputPeer.channelId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        } else {
            let inputPeer = InputPeerChat()
            inputPeer.chatId = peerId
            req.peer = inputPeer
        }
        req.expireDate = expireDate
        req.usageLimit = usageLimit
        req.requestNeeded = requestNeeded
        req.title = title

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }

        this.parseChatInviteExported(responseData, result)
        return result
    }

    /**
     * 撤销邀请链接（messages.editExportedChatInvite，flags.2=revoked）
     *
     * iOS 对应: _internal_revokePeerExportedInvitation (InvitationLinks.swift:181)
     *
     * @param peerType   "chat" | "channel"
     * @param peerId     peer ID
     * @param accessHash peer accessHash
     * @param link       要撤销的链接
     */
    public func revokeInviteLink(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        link: String
    ): InviteLinkResult {
        Hilog.info(0, "CjTelegram", "[PeersService] revokeInviteLink: peerId=${peerId}")
        let result = InviteLinkResult()
        let client = getMTProtoClient()

        let req = MessagesEditExportedChatInvite()
        if (peerType == "channel") {
            let inputPeer = InputPeerChannel()
            inputPeer.channelId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        } else {
            let inputPeer = InputPeerChat()
            inputPeer.chatId = peerId
            req.peer = inputPeer
        }
        req.link = link
        req.revoked = true

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }

        this.parseChatInviteExported(responseData, result)
        return result
    }

    /**
     * 编辑邀请链接（messages.editExportedChatInvite#bdca2f75）
     *
     * iOS 对应: _internal_editPeerExportedInvitation (InvitationLinks.swift:146)
     *
     * @param peerType      "chat" | "channel"
     * @param peerId        peer ID
     * @param accessHash    peer accessHash
     * @param link          要编辑的链接
     * @param expireDate    新过期时间（0 = 不改）
     * @param usageLimit    新使用次数上限（0 = 不改）
     * @param requestNeeded 是否需要管理员批准
     * @param title         新标题
     */
    public func editInviteLink(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        link: String,
        expireDate!: Int32 = 0,
        usageLimit!: Int32 = 0,
        requestNeeded!: Bool = false,
        title!: String = ""
    ): InviteLinkResult {
        Hilog.info(0, "CjTelegram", "[PeersService] editInviteLink: peerId=${peerId}")
        let result = InviteLinkResult()
        let client = getMTProtoClient()

        let req = MessagesEditExportedChatInvite()
        if (peerType == "channel") {
            let inputPeer = InputPeerChannel()
            inputPeer.channelId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        } else {
            let inputPeer = InputPeerChat()
            inputPeer.chatId = peerId
            req.peer = inputPeer
        }
        req.link = link
        req.expireDate = expireDate
        req.usageLimit = usageLimit
        req.requestNeeded = requestNeeded
        req.title = title

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }

        this.parseChatInviteExported(responseData, result)
        return result
    }

    /**
     * 获取邀请链接列表（messages.getExportedChatInvites#a2b5a3f6）
     *
     * iOS 对应: _internal_peerExportedInvitations (InvitationLinks.swift:242)
     *
     * @param peerType    "chat" | "channel"
     * @param peerId      peer ID
     * @param accessHash  peer accessHash
     * @param adminUserId 管理员的用户 ID（0 = 当前用户）
     * @param adminAccessHash  管理员 accessHash
     * @param revoked     true = 获取已撤销链接
     * @param limit       返回条数
     */
    public func getInviteLinks(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        adminUserId!: Int64 = 0,
        adminAccessHash!: Int64 = 0,
        revoked!: Bool = false,
        limit!: Int32 = 50
    ): InviteLinksResult {
        Hilog.info(0, "CjTelegram", "[PeersService] getInviteLinks: peerId=${peerId} revoked=${revoked}")
        let result = InviteLinksResult()
        let client = getMTProtoClient()

        let req = MessagesGetExportedChatInvites()
        if (peerType == "channel") {
            let inputPeer = InputPeerChannel()
            inputPeer.channelId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        } else {
            let inputPeer = InputPeerChat()
            inputPeer.chatId = peerId
            req.peer = inputPeer
        }

        // adminId: InputUser (self if adminUserId == 0)
        if (adminUserId > 0) {
            let adminUser = InputUser()
            adminUser.userId = adminUserId
            adminUser.accessHash = adminAccessHash
            req.adminId = adminUser
        } else {
            req.adminId = InputUserSelf()
        }

        req.revoked = revoked
        req.limit = limit

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }

        this.parseExportedChatInvites(responseData, result)
        return result
    }

    /**
     * 解析单个 chatInviteExported 响应
     *
     * chatInviteExported#a22cbd96 (TL schema verified)
     * messages.exportedChatInvite#1871be50 wraps chatInviteExported + users
     * messages.exportedChatInviteReplaced#222600ef wraps invite + new_invite + users
     */
    private func parseChatInviteExported(data: Array<Byte>, result: InviteLinkResult): Unit {
        try {
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()

            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let _ = d.readInt32()
                let msg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeersService] chatInviteExported error: ${msg}")
                result.errorCode = msg
                return
            }

            // messages.exportedChatInvite#1871be50 invite:ExportedChatInvite users:Vector<User>
            // messages.exportedChatInviteReplaced#222600ef invite:ExportedChatInvite new_invite:... users:...
            if (ctor == 0x1871be50 || ctor == 0x222600ef) {
                let inviteCtor = d.readUInt32()
                this.parseSingleChatInvite(d, inviteCtor, result)
            } else {
                // direct chatInviteExported
                this.parseSingleChatInvite(d, ctor, result)
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeersService] parseChatInviteExported error: ${e}")
            result.errorCode = "PARSE_ERROR"
        }
    }

    /**
     * 解析 chatInviteExported 对象
     *
     * chatInviteExported#a22cbd96 flags:# revoked:flags.0?true permanent:flags.5?true
     *   request_needed:flags.6?true link:string admin_id:long date:int
     *   start_date:flags.4?int expire_date:flags.1?int usage_limit:flags.2?int usage:flags.3?int
     *   requested:flags.7?int subscription_expired:flags.10?int title:flags.8?string
     *   subscription_pricing:flags.9?StarsSubscriptionPricing(#5416d58: period:int amount:long)
     *
     * TL schema verified: 0xa22cbd96
     */
    private func parseSingleChatInvite(d: TLDeserializer, ctor: UInt32, result: InviteLinkResult): Unit {
        try {
            if (ctor != 0xa22cbd96) {
                Hilog.info(0, "CjTelegram", "[PeersService] parseSingleChatInvite unknown ctor: 0x${ctor}")
                return
            }
            let flags = d.readInt32()
            result.revoked = (flags & 1) != 0
            // link: string (mandatory)
            result.link = d.readString()
            // admin_id: long (mandatory)
            let _ = d.readInt64()
            // date: int (mandatory)
            let _ = d.readInt32()
            // start_date: flags.4?int
            if ((flags & 16) != 0) { let _ = d.readInt32() }
            // expire_date: flags.1?int
            if ((flags & 2) != 0) { result.expireDate = d.readInt32() }
            // usage_limit: flags.2?int
            if ((flags & 4) != 0) { result.usageLimit = d.readInt32() }
            // usage: flags.3?int
            if ((flags & 8) != 0) { let _ = d.readInt32() }
            // requested: flags.7?int
            if ((flags & 128) != 0) { let _ = d.readInt32() }
            // subscription_expired: flags.10?int
            if ((flags & 1024) != 0) { let _ = d.readInt32() }
            // title: flags.8?string
            if ((flags & 256) != 0) { let _ = d.readString() }
            // subscription_pricing: flags.9?StarsSubscriptionPricing
            // starsSubscriptionPricing#5416d58 period:int amount:long
            if ((flags & 512) != 0) {
                let _ = d.readUInt32()  // starsSubscriptionPricing ctor (0x5416d58)
                let _ = d.readInt32()   // period: int
                let _ = d.readInt64()   // amount: long
            }
            result.success = true
            Hilog.info(0, "CjTelegram", "[PeersService] parseSingleChatInvite: link='${result.link}'")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeersService] parseSingleChatInvite error: ${e}")
        }
    }

    // ==================== P2-147: 设置 Chat 可用 Reactions ====================

    /**
     * 设置群/频道允许的 reaction 集合（messages.setChatAvailableReactions#864b2581）
     *
     * iOS 对应: TelegramEngine.Peers._internal_updatePeerAllowedReactions
     *   (MessageReactions.swift:1024-1046)
     * TL: messages.setChatAvailableReactions#864b2581 flags:# peer:InputPeer
     *     available_reactions:ChatReactions reactions_limit:flags.0?int
     *     paid_enabled:flags.1?Bool = Updates
     * ctor verified (python): -2041895551 & 0xFFFFFFFF = 0x864b2581
     *
     * mode 含义:
     *   "all"  => ChatReactionsAll (flags=0, allow_custom=false by default)
     *   "some" => ChatReactionsSome (reactions 列表中逐项序列化 Reaction variant)
     *   "none" => ChatReactionsNone
     *
     * 响应: Updates 四变体 (0x74ae4240 / 0x725b04c3 / 0x78d4dec1 / 0xe317af7e)
     *
     * @param peerType       "user" | "chat" | "channel"
     * @param peerId         peer ID
     * @param accessHash     peer accessHash（chat 传 0）
     * @param mode           "all" | "some" | "none"
     * @param reactions      allowSome 时逐项 emoji/customEmoji 列表（mode="some" 必填）
     *                       每项为 ("emoji", emoticon) 或 ("custom", documentId_str)
     * @param reactionsLimit 可选的 reactions per message 上限（flags.0）
     * @param paidEnabled    可选：是否允许付费 reactions（flags.1）
     */
    public func setChatAvailableReactions(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        mode: String,
        reactions!: ArrayList<(String, String)> = ArrayList<(String, String)>(),
        reactionsLimit!: Option<Int32> = None,
        paidEnabled!: Option<Bool> = None
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] setChatAvailableReactions: peerId=${peerId} mode=${mode}")
        let client = getMTProtoClient()

        let req = MessagesSetChatAvailableReactions()

        if (peerType == "channel") {
            let inputPeer = InputPeerChannel()
            inputPeer.channelId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        } else if (peerType == "chat") {
            let inputPeer = InputPeerChat()
            inputPeer.chatId = peerId
            req.peer = inputPeer
        } else {
            let inputPeer = InputPeerUser()
            inputPeer.userId = peerId
            inputPeer.accessHash = accessHash
            req.peer = inputPeer
        }

        if (mode == "all") {
            req.availableReactions = ChatReactionsAll()
        } else if (mode == "some") {
            let someReactions = ChatReactionsSome()
            for ((kind, value) in reactions) {
                if (kind == "custom") {
                    try {
                        let r = ReactionCustomEmoji()
                        r.documentId = Int64.parse(value)
                        someReactions.reactions.add(r)
                    } catch (_: Exception) {
                        Hilog.info(0, "CjTelegram", "[PeersService] setChatAvailableReactions: invalid customEmoji documentId, skipping")
                    }
                } else {
                    let r = ReactionEmoji()
                    r.emoticon = value
                    someReactions.reactions.add(r)
                }
            }
            req.availableReactions = someReactions
        } else {
            req.availableReactions = ChatReactionsNone()
        }

        req.reactionsLimit = reactionsLimit
        req.paidEnabled = paidEnabled

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] setChatAvailableReactions error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }

        if (ctor == 0x74ae4240 || ctor == 0x725b04c3 || ctor == 0x78d4dec1 || ctor == 0xe317af7e) {
            Hilog.info(0, "CjTelegram", "[PeersService] setChatAvailableReactions success: peerId=${peerId} mode=${mode}")
            return PeerOperationResult(true)
        }

        Hilog.info(0, "CjTelegram", "[PeersService] setChatAvailableReactions unexpected ctor: ${ctor}")
        return PeerOperationResult(false, errorCode: "UNEXPECTED_RESPONSE")
    }

    // ==================== P2-149: 讨论组链接 / pre-history / 基础群转超级群 ====================

    /**
     * 绑定或解绑频道的讨论组（channels.setDiscussionGroup#40582bb2）
     *
     * iOS 对应: _internal_updateChannelDiscussionGroup
     *   (ManageChannelDiscussionGroup.swift:54)
     * TL: channels.setDiscussionGroup#40582bb2 broadcast:InputChannel group:InputChannel = Bool
     * ctor verified (python): 1079520178 & 0xFFFFFFFF = 0x40582bb2
     *
     * 解绑时 groupChannelId=0、groupChannelAccessHash=0，
     * 此时构造 InputChannelEmpty (inputChannelEmpty#ee8c1e86) 作为 group 参数。
     *
     * 响应: Bool — boolTrue#997275b5 = 成功，boolFalse#bc799737 = 失败
     *
     * @param broadcastChannelId         广播频道 ID
     * @param broadcastChannelAccessHash 广播频道 accessHash
     * @param groupChannelId             讨论组频道 ID（0 = 解绑）
     * @param groupChannelAccessHash     讨论组频道 accessHash（0 = 解绑）
     */
    public func setDiscussionGroup(
        broadcastChannelId: Int64,
        broadcastChannelAccessHash: Int64,
        groupChannelId: Int64,
        groupChannelAccessHash: Int64
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] setDiscussionGroup broadcast=${broadcastChannelId} group=${groupChannelId}")
        let client = getMTProtoClient()

        let req = ChannelsSetDiscussionGroup()

        let broadcastCh = InputChannel()
        broadcastCh.channelId = broadcastChannelId
        broadcastCh.accessHash = broadcastChannelAccessHash
        req.broadcast = broadcastCh

        if (groupChannelId > 0) {
            let groupCh = InputChannel()
            groupCh.channelId = groupChannelId
            groupCh.accessHash = groupChannelAccessHash
            req.group = groupCh
        } else {
            req.group = InputChannelEmpty()
        }

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] setDiscussionGroup error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }
        let ok = ctor == TLConstructors.BOOL_TRUE
        Hilog.info(0, "CjTelegram", "[PeersService] setDiscussionGroup result: ${ok}")
        return PeerOperationResult(ok)
    }

    /**
     * 切换频道/超级群对新成员的历史可见性（channels.togglePreHistoryHidden#eabbb94c）
     *
     * iOS 对应: _internal_updateChannelHistoryAvailabilitySettings
     *   (ChannelHistoryAvailabilitySettings.swift:22)
     * TL: channels.togglePreHistoryHidden#eabbb94c channel:InputChannel enabled:Bool = Updates
     * ctor verified (python): -356796084 & 0xFFFFFFFF = 0xeabbb94c
     *
     * iOS 传参逻辑:
     *   historyAvailableForNewMembers=true  → enabled=boolFalse（不隐藏）
     *   historyAvailableForNewMembers=false → enabled=boolTrue（隐藏）
     * 本方法直接接受 enabled(Bool)，调用方负责语义对应。
     *
     * 响应: Updates 四变体（0x74ae4240/0x725b04c3/0x78d4dec1/0xe317af7e）
     *
     * @param channelId         频道/超级群 ID
     * @param channelAccessHash 频道/超级群 accessHash
     * @param enabled           true = 隐藏历史（新成员看不到旧消息）
     */
    public func togglePreHistoryHidden(
        channelId: Int64,
        channelAccessHash: Int64,
        enabled: Bool
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] togglePreHistoryHidden channelId=${channelId} enabled=${enabled}")
        let client = getMTProtoClient()

        let req = ChannelsTogglePreHistoryHidden()
        let ch = InputChannel()
        ch.channelId = channelId
        ch.accessHash = channelAccessHash
        req.channel = ch
        req.enabled = enabled

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] togglePreHistoryHidden error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }

        if (ctor == 0x74ae4240 || ctor == 0x725b04c3 || ctor == 0x78d4dec1 || ctor == 0xe317af7e) {
            Hilog.info(0, "CjTelegram", "[PeersService] togglePreHistoryHidden success: channelId=${channelId} enabled=${enabled}")
            return PeerOperationResult(true)
        }

        Hilog.info(0, "CjTelegram", "[PeersService] togglePreHistoryHidden unexpected ctor: ${ctor}")
        return PeerOperationResult(false, errorCode: "UNEXPECTED_RESPONSE")
    }

    // ==================== P2-133: 频道签名 / 限制转发保存开关 ====================

    /**
     * 切换频道消息署名开关（channels.toggleSignatures#418d549c）
     *
     * iOS 对应: _internal_toggleChannelSignatures (ChannelSignMessages.swift)
     * TL: channels.toggleSignatures#418d549c flags:# channel:InputChannel = Updates
     * ctor verified (python): 1099781276 & 0xFFFFFFFF = 0x418d549c
     *
     * flags 含义（当前 iOS layer 使用 flags 版，取代旧版 enabled:Bool）：
     *   bit 0 (flags & 1): signatures_enabled — 在频道消息末尾显示发送者署名
     *   bit 1 (flags & 2): profiles_enabled  — 署名中展示发送者个人资料链接
     *
     * 调用方通过 signaturesEnabled / profilesEnabled 两个 Bool 控制，
     * 方法内合并为 flags Int32 写入 TL 流。
     *
     * 响应: Updates 四变体（0x74ae4240/0x725b04c3/0x78d4dec1/0xe317af7e）
     *
     * @param channelId           频道 ID
     * @param channelAccessHash   频道 accessHash
     * @param signaturesEnabled   是否显示消息署名
     * @param profilesEnabled     是否在署名中显示个人资料链接（需 signaturesEnabled=true 才有意义）
     */
    public func toggleSignatures(
        channelId: Int64,
        channelAccessHash: Int64,
        signaturesEnabled: Bool,
        profilesEnabled!: Bool = false
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] toggleSignatures channelId=${channelId} signatures=${signaturesEnabled} profiles=${profilesEnabled}")
        let client = getMTProtoClient()

        let req = ChannelsToggleSignatures()
        let ch = InputChannel()
        ch.channelId = channelId
        ch.accessHash = channelAccessHash
        req.channel = ch

        var flags: Int32 = 0
        if (signaturesEnabled) { flags = flags | 1 }
        if (profilesEnabled) { flags = flags | 2 }
        req.flags = flags

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] toggleSignatures error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }

        if (ctor == 0x74ae4240 || ctor == 0x725b04c3 || ctor == 0x78d4dec1 || ctor == 0xe317af7e) {
            Hilog.info(0, "CjTelegram", "[PeersService] toggleSignatures success: channelId=${channelId} flags=${flags}")
            return PeerOperationResult(true)
        }

        Hilog.info(0, "CjTelegram", "[PeersService] toggleSignatures unexpected ctor: ${ctor}")
        return PeerOperationResult(false, errorCode: "UNEXPECTED_RESPONSE")
    }

    /**
     * 切换"限制转发与保存内容"开关（messages.toggleNoForwards#b2081a35）
     *
     * iOS 对应: _internal_toggleChannelNoForwards (ChannelNoForwards.swift)
     * TL: messages.toggleNoForwards#b2081a35 flags:# peer:InputPeer enabled:Bool
     *     requestMsgId:flags.0?int = Updates
     * ctor verified (python): -1308091851 & 0xFFFFFFFF = 0xb2081a35
     *
     * 注意：iOS 无 channels.toggleNoForwards，channel 和 chat 均使用
     *   messages.toggleNoForwards（通过 InputPeer 变体区分对象类型）。
     *
     * flags=0 表示 requestMsgId 不存在（普通场景）。
     * enabled=true = 开启限制（禁止转发/保存），enabled=false = 关闭限制。
     *
     * 响应: Updates 四变体（0x74ae4240/0x725b04c3/0x78d4dec1/0xe317af7e）
     *
     * @param channelId         频道 ID
     * @param channelAccessHash 频道 accessHash
     * @param enabled           true = 限制转发/保存，false = 允许转发/保存
     */
    public func toggleNoForwards(
        channelId: Int64,
        channelAccessHash: Int64,
        enabled: Bool
    ): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] toggleNoForwards channelId=${channelId} enabled=${enabled}")
        let client = getMTProtoClient()

        let req = MessagesToggleNoForwards()
        req.flags = 0

        let inputPeer = InputPeerChannel()
        inputPeer.channelId = channelId
        inputPeer.accessHash = channelAccessHash
        req.peer = inputPeer

        req.enabled = enabled

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] toggleNoForwards error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }

        if (ctor == 0x74ae4240 || ctor == 0x725b04c3 || ctor == 0x78d4dec1 || ctor == 0xe317af7e) {
            Hilog.info(0, "CjTelegram", "[PeersService] toggleNoForwards success: channelId=${channelId} enabled=${enabled}")
            return PeerOperationResult(true)
        }

        Hilog.info(0, "CjTelegram", "[PeersService] toggleNoForwards unexpected ctor: ${ctor}")
        return PeerOperationResult(false, errorCode: "UNEXPECTED_RESPONSE")
    }

    /**
     * 切换普通 chat 的"限制转发与保存内容"（messages.toggleNoForwards，chat 变体）
     *
     * iOS 对应: _internal_setChatNoForwards (chat branch, uses InputPeerChat)
     * 本方法适用于基础群组（basic chat），使用 InputPeerChat 作为 peer。
     * channel/supergroup 请使用 toggleNoForwards()（InputPeerChannel 变体）。
     *
     * @param chatId    基础群组 ID
     * @param enabled   true = 限制转发/保存，false = 允许
     */
    public func toggleChatNoForwards(chatId: Int64, enabled: Bool): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] toggleChatNoForwards chatId=${chatId} enabled=${enabled}")
        let client = getMTProtoClient()

        let req = MessagesToggleNoForwards()
        req.flags = 0

        let inputPeer = InputPeerChat()
        inputPeer.chatId = chatId
        req.peer = inputPeer

        req.enabled = enabled

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] toggleChatNoForwards error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }

        if (ctor == 0x74ae4240 || ctor == 0x725b04c3 || ctor == 0x78d4dec1 || ctor == 0xe317af7e) {
            Hilog.info(0, "CjTelegram", "[PeersService] toggleChatNoForwards success: chatId=${chatId} enabled=${enabled}")
            return PeerOperationResult(true)
        }

        Hilog.info(0, "CjTelegram", "[PeersService] toggleChatNoForwards unexpected ctor: ${ctor}")
        return PeerOperationResult(false, errorCode: "UNEXPECTED_RESPONSE")
    }

    /**
     * 将基础群组升级迁移为超级群（messages.migrateChat#a2875319）
     *
     * iOS 对应: _internal_convertGroupToSupergroup
     *   (ConvertGroupToSupergroup.swift:13)
     * TL: messages.migrateChat#a2875319 chat_id:long = Updates
     * ctor verified (python): -1568189671 & 0xFFFFFFFF = 0xa2875319
     *
     * chat_id 传 long（unboxed），即基础群组的数字 ID。
     * 响应: Updates 四变体（0x74ae4240/0x725b04c3/0x78d4dec1/0xe317af7e）
     * 成功后服务端会在 getDifference 推送迁移事件（updateChannel）。
     *
     * @param chatId 基础群组（chat）的 ID
     */
    public func migrateChat(chatId: Int64): PeerOperationResult {
        Hilog.info(0, "CjTelegram", "[PeersService] migrateChat chatId=${chatId}")
        let client = getMTProtoClient()

        let req = MessagesMigrateChat()
        req.chatId = chatId

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return PeerOperationResult(false, errorCode: "NETWORK_ERROR")
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[PeersService] migrateChat error: ${errMsg}")
            return PeerOperationResult(false, errorCode: errMsg)
        }

        if (ctor == 0x74ae4240 || ctor == 0x725b04c3 || ctor == 0x78d4dec1 || ctor == 0xe317af7e) {
            Hilog.info(0, "CjTelegram", "[PeersService] migrateChat success: chatId=${chatId}")
            return PeerOperationResult(true)
        }

        Hilog.info(0, "CjTelegram", "[PeersService] migrateChat unexpected ctor: ${ctor}")
        return PeerOperationResult(false, errorCode: "UNEXPECTED_RESPONSE")
    }

    // ==================== P2-137: 封禁/受限成员列表 ====================

    /**
     * 获取频道封禁/受限成员列表（channels.getParticipants）
     *
     * iOS 对应: ChannelBlacklistController — loadMoreEntries() calling channelMembers()
     *   with ChannelMembersCategory.restricted / ChannelMembersCategory.banned
     *
     * TL: channels.getParticipants#77ced9d0 (iOS Api42.swift:3794 appendInt32(2010044880))
     *   channel:InputChannel filter:ChannelParticipantsFilter offset:int limit:int hash:long = channels.ChannelParticipants
     *
     * filter variants used here:
     *   channelParticipantsBanned#1427a5e1 q:string  (iOS signed=338142689, "restricted" category)
     *   channelParticipantsKicked#a3b54985 q:string  (iOS signed=-1548400251, "kicked/banned" category)
     *
     * Response: channels.channelParticipants#9ab0feaf (iOS signed=-1699676497)
     *   count:int participants:Vector<ChannelParticipant> chats:Vector<Chat> users:Vector<User>
     *
     * channelParticipantBanned#d5f0ad91 (iOS signed=-705647215):
     *   flags:int peer:Peer kickedBy:long date:int bannedRights:ChatBannedRights rank?:string
     *   ChatBannedRights#9f120418 (iOS signed=-1626209256) flags:int untilDate:int
     *
     * @param channelId         频道/超级群 ID
     * @param channelAccessHash 频道/超级群 accessHash
     * @param kicked            true = channelParticipantsKicked (完全踢出); false = channelParticipantsBanned (受限)
     * @param offset            分页偏移
     * @param limit             每页条数
     */
    public func getBannedChannelParticipants(
        channelId: Int64,
        channelAccessHash: Int64,
        kicked!: Bool = false,
        offset!: Int32 = 0,
        limit!: Int32 = 100
    ): BannedParticipantsResult {
        Hilog.info(0, "CjTelegram", "[PeersService] getBannedChannelParticipants channelId=${channelId} kicked=${kicked} offset=${offset}")
        let result = BannedParticipantsResult()
        let client = getMTProtoClient()

        let req = ChannelsGetParticipants()
        let ch = InputChannel()
        ch.channelId = channelId
        ch.accessHash = channelAccessHash
        req.channel = ch

        if (kicked) {
            req.filter = 0xa3b54985  // channelParticipantsKicked (iOS signed=-1548400251)
        } else {
            req.filter = 0x1427a5e1  // channelParticipantsBanned (iOS signed=338142689)
        }
        req.filterQuery = ""
        req.offset = offset
        req.limit = limit
        req.hash = 0

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }

        this.parseChannelParticipantsResponse(responseData, result)
        return result
    }

    /**
     * 解析 channels.ChannelParticipants 响应
     *
     * channels.channelParticipants#9ab0feaf (iOS signed=-1699676497):
     *   count:int participants:Vector<ChannelParticipant> chats:Vector<Chat> users:Vector<User>
     *
     * channels.channelParticipantsNotModified#f0173fe9 (iOS signed=-266911767)
     *
     * 仅解析 channelParticipantBanned#d5f0ad91 变体（filtered by getParticipants filter）
     * 其他变体（admin, creator, self, member）在踢出/封禁过滤器下不应出现
     */
    private func parseChannelParticipantsResponse(data: Array<Byte>, result: BannedParticipantsResult): Unit {
        try {
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()

            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let _ = d.readInt32()
                let msg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeersService] getBannedChannelParticipants error: ${msg}")
                result.errorCode = msg
                return
            }

            if (ctor == 0xf0173fe9) {
                Hilog.info(0, "CjTelegram", "[PeersService] getBannedChannelParticipants: notModified")
                return
            }

            if (ctor != 0x9ab0feaf) {
                Hilog.info(0, "CjTelegram", "[PeersService] getBannedChannelParticipants unexpected ctor: 0x${ctor}")
                result.errorCode = "UNEXPECTED_RESPONSE"
                return
            }

            result.totalCount = d.readInt32()

            let participantsCtor = d.readUInt32()  // vector ctor 0x1cb5c415
            let _ = participantsCtor
            let participantCount = d.readInt32()

            var userIdByPeer: ArrayList<Int64> = ArrayList<Int64>()

            var pi: Int32 = 0
            while (pi < participantCount) {
                let partCtor = d.readUInt32()
                if (partCtor == 0xd5f0ad91) {
                    // channelParticipantBanned#d5f0ad91 (iOS signed=-705647215)
                    //   flags:int peer:Peer kickedBy:long date:int
                    //   bannedRights:ChatBannedRights rank?:string[flags.2]
                    let flags = d.readInt32()
                    let peerCtor = d.readUInt32()
                    var peerId: Int64 = 0
                    var peerType: String = "user"
                    if (peerCtor == 0x59511722) {
                        peerType = "user"
                        peerId = d.readInt64()
                    } else if (peerCtor == 0x36c6019a) {
                        peerType = "chat"
                        peerId = d.readInt64()
                    } else if (peerCtor == 0xa2a5371e) {
                        peerType = "channel"
                        peerId = d.readInt64()
                    } else {
                        Hilog.info(0, "CjTelegram", "[PeersService] Unknown peer ctor in banned: 0x${peerCtor}")
                        peerId = d.readInt64()
                    }

                    let kickedById = d.readInt64()
                    let date = d.readInt32()

                    let bannedRightsCtor = d.readUInt32()
                    let _ = bannedRightsCtor  // 0x9f120418 chatBannedRights
                    let bannedFlags = d.readInt32()
                    let untilDate = d.readInt32()

                    if ((flags & 4) != 0) {
                        let _ = d.readString()  // rank (flags.2)
                    }

                    let entry = BannedParticipantEntry()
                    entry.userId = peerId
                    entry.peerType = peerType
                    entry.kickedById = kickedById
                    entry.date = date
                    entry.bannedFlags = bannedFlags
                    entry.untilDate = untilDate
                    result.participants.add(entry)
                    userIdByPeer.add(peerId)
                } else {
                    Hilog.info(0, "CjTelegram", "[PeersService] Skipping non-banned participant ctor: 0x${partCtor}")
                }
                pi += 1
            }

            let chatsCtor = d.readUInt32()  // vector ctor 0x1cb5c415
            let _ = chatsCtor
            let chatCount = d.readInt32()
            var ci: Int32 = 0
            while (ci < chatCount) {
                try { let _ = ChatResponse.deserializeBoxed(d) } catch (_: Exception) { break }
                ci += 1
            }

            let usersCtor = d.readUInt32()  // vector ctor 0x1cb5c415
            let _ = usersCtor
            let userCount = d.readInt32()
            var userNames: HashMap<Int64, String> = HashMap<Int64, String>()
            var userAccessHashes: HashMap<Int64, Int64> = HashMap<Int64, Int64>()
            var ui: Int32 = 0
            while (ui < userCount) {
                try {
                    let user = UserResponse.deserializeBoxed(d)
                    let nameStr = if (user.lastName.size > 0) {
                        "${user.firstName} ${user.lastName}"
                    } else {
                        user.firstName
                    }
                    userNames[user.id] = nameStr
                    userAccessHashes[user.id] = user.accessHash
                } catch (_: Exception) { break }
                ui += 1
            }

            for (entry in result.participants) {
                if (userNames.contains(entry.userId)) {
                    entry.displayName = userNames[entry.userId]
                }
                if (userAccessHashes.contains(entry.userId) && entry.peerType == "user") {
                    entry.accessHash = userAccessHashes[entry.userId]
                }
                if (userNames.contains(entry.kickedById)) {
                    entry.kickedByName = userNames[entry.kickedById]
                }
            }

            Hilog.info(0, "CjTelegram", "[PeersService] getBannedChannelParticipants done: ${result.participants.size}/${result.totalCount}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeersService] parseChannelParticipantsResponse error: ${e}")
            result.errorCode = "PARSE_ERROR"
        }
    }

    /**
     * 解析 messages.exportedChatInvites 列表响应
     *
     * messages.exportedChatInvites#bdc62dcc count:int invites:Vector<ExportedChatInvite>
     *   users:Vector<User>
     */
    private func parseExportedChatInvites(data: Array<Byte>, result: InviteLinksResult): Unit {
        try {
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()

            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let _ = d.readInt32()
                let msg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeersService] getInviteLinks error: ${msg}")
                result.errorCode = msg
                return
            }

            // messages.exportedChatInvites#bdc62dcc count:int invites:Vector<ExportedChatInvite>
            if (ctor != 0xbdc62dcc) {
                Hilog.info(0, "CjTelegram", "[PeersService] getInviteLinks unexpected ctor: ${ctor}")
                return
            }

            result.totalCount = d.readInt32()
            let _ = d.readUInt32()  // vector ctor
            let inviteCount = d.readInt32()

            var i: Int32 = 0
            while (i < inviteCount && i < 100) {
                let inviteLink = InviteLinkResult()
                let inviteCtor = d.readUInt32()
                this.parseSingleChatInvite(d, inviteCtor, inviteLink)
                if (inviteLink.success) {
                    result.links.add(inviteLink)
                }
                i += 1
            }

            Hilog.info(0, "CjTelegram", "[PeersService] getInviteLinks done: ${result.links.size}/${result.totalCount}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeersService] parseExportedChatInvites error: ${e}")
            result.errorCode = "PARSE_ERROR"
        }
    }

}
