package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import std.collection.HashMap
import std.time.DateTime

/**
 * PeerInfoService — 资料详情页 API 服务
 *
 * 对应 iOS PeerInfoUI 模块的核心数据请求层。
 * 封装以下 Telegram TL 方法：
 *
 *   users.getFullUser#b60f5918 id:InputUser = users.UserFull
 *     → 返回 userFull（bio、phone、blocked 状态、共同联系人数等）
 *
 *   channels.getFullChannel#8736a09 channel:InputChannel = messages.ChatFull
 *     → 返回 channelFull（about、members_count、online_count、username 等）
 *
 *   messages.getFullChat#3b831c66 chat_id:long = messages.ChatFull
 *     → 返回 chatFull（about、participants 等）
 *
 *   channels.getParticipants#77ced9d0 channel:InputChannel filter:ChannelParticipantsFilter
 *                                       offset:int limit:int hash:long
 *     → 返回成员列表（支持按搜索词过滤）
 *
 * 调用链：
 *   PeerInfoPage → getPeerInfoService() → PeerInfoService.getUserFullInfo / getGroupFullInfo
 *               → getMTProtoClient().sendRequest(req.toBytes()) → parse → PeerFullInfo
 *   ChannelMembersSearchPageNode → PeerInfoService.searchMembers
 *               → getMTProtoClient().sendRequest(ChannelsGetParticipants) → MemberSearchResult
 */

// ==================== 数据模型 ====================

/**
 * PeerFullInfo — 统一的 peer 详情数据结构
 *
 * 覆盖用户/群组/频道三种类型：
 * - 用户：bio、phone、blocked
 * - 群组/频道：about、membersCount、onlineCount
 */
public class PeerFullInfo {
    public var peerId: Int64 = 0
    public var peerType: String = ""   // "user" | "chat" | "channel"
    public var displayName: String = ""
    public var username: String = ""
    public var bio: String = ""        // 用户 bio（来自 userFull.about）
    public var about: String = ""      // 群组/频道描述
    public var phone: String = ""      // 用户电话
    public var membersCount: Int32 = 0
    public var onlineCount: Int32 = 0
    public var isBlocked: Bool = false
    public var canViewParticipants: Bool = true
    public var linkedChatId: Int64 = 0
    // Badge flags parsed from User.flags — iOS TelegramUser.swift verified bits:
    //   isVerified: flags.17  isScam: flags.24  isFake: flags.26  isBot: flags.14
    public var isVerified: Bool = false
    public var isScam: Bool = false
    public var isFake: Bool = false
    public var isBot: Bool = false
    // Channel toggle states parsed from Channel.flags (basic object, not channelFull):
    //   signaturesEnabled: channel.flags.11 (Sign Messages)
    //   noForwardsEnabled: channel.flags.27 (Restrict Saving Content)
    public var signaturesEnabled: Bool = false
    public var noForwardsEnabled: Bool = false
    // channelFull.flags2.0 can_delete_channel（iOS CachedChannelFlags.canDeleteHistory）
    public var canDeleteChannel: Bool = false
    public var activeCallId: Int64 = 0
    public var activeCallAccessHash: Int64 = 0
    public var canSetUsername: Bool = false
    public var hiddenPrehistory: Bool = false
    public var adminsCount: Int32 = 0
    public var kickedCount: Int32 = 0
    public var bannedCount: Int32 = 0
    public var ttlPeriod: Int32 = 0
    public var slowmodeSeconds: Int32 = 0
    // S6-15: userFull.birthday（flags2.5，birthday#6c8e1e06 day/month/year?）；day == 0 表示未设置
    public var birthdayDay: Int32 = 0
    public var birthdayMonth: Int32 = 0
    public var birthdayYear: Int32 = 0
    // userFull.common_chats_count
    public var commonChatsCount: Int32 = 0
    // S6-27: userFull.note（flags2.22, textWithEntities#751f3146 — iOS Api30 parse_userFull _39）
    public var note: String = ""
    // S6-30: userFull.personal_photo 是否存在（flags.21 — iOS Api30 parse_userFull _6）
    public var hasPersonalPhoto: Bool = false
    // 基础群（peerType "chat"）：messages.getFullChat → chatFull.participants 解析出的成员
    // （iOS CachedGroupData.participants，PeerInfoScreen 成员段直接读它，不走 channels.getParticipants）。
    public var participants: ArrayList<MemberInfo> = ArrayList<MemberInfo>()
    public var participantsForbidden: Bool = false
    public var error: String = ""      // 非空表示请求失败

    public init() {}
}

/**
 * MemberInfo — 频道/群组成员信息
 */
public class MemberInfo {
    public var userId: Int64 = 0
    public var accessHash: Int64 = 0
    public var firstName: String = ""
    public var lastName: String = ""
    public var username: String = ""
    public var isAdmin: Bool = false
    public var isCreator: Bool = false
    public var rank: String = ""
    // P2-134: detail fields — join date and inviter
    public var joinDate: Int32 = 0      // Unix timestamp of when the user joined
    public var inviterId: Int64 = 0     // userId of the person who invited this member (0 if unknown)
    public var isBanned: Bool = false   // true for channelParticipantBanned variant
    public var adminFlags: Int32 = 0    // ChatAdminRights flags（管理员/群主）

    public init() {}

    public func displayName(): String {
        if (this.lastName.size > 0) {
            return "${this.firstName} ${this.lastName}"
        }
        if (this.firstName.size > 0) { return this.firstName }
        return "User ${this.userId}"
    }
}

/**
 * MemberSearchResult — searchMembers 结果
 */
public class MemberSearchResult {
    public var members: ArrayList<MemberInfo> = ArrayList<MemberInfo>()
    public var totalCount: Int32 = 0
    public var error: String = ""

    public init() {}
}

// ==================== 服务单例 ====================

private var _peerInfoServiceInstance: Option<PeerInfoService> = None

public func getPeerInfoService(): PeerInfoService {
    match (_peerInfoServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PeerInfoService()
            _peerInfoServiceInstance = Some(inst)
            return inst
    }
}

// ==================== 服务实现 ====================

public class PeerInfoService {
    /** accessHash 缓存：用户 peerId → accessHash */
    private var userAccessHashes = HashMap<Int64, Int64>()
    /** accessHash 缓存：频道 peerId → accessHash */
    private var channelAccessHashes = HashMap<Int64, Int64>()
    // getFullChat 受服务端 flood 限制；资料页与编辑页相继打开时复用最近一次结果
    private var fullInfoCache = HashMap<Int64, PeerFullInfo>()
    private var fullInfoFetchedAtMs = HashMap<Int64, Int64>()

    private static func nowMs(): Int64 {
        DateTime.now().toUnixTimeStamp().toMilliseconds()
    }

    /** 最近一次拉到的完整信息（不判断新鲜度） */
    public func peekGroupFullInfo(peerId: Int64): Option<PeerFullInfo> {
        fullInfoCache.get(peerId)
    }

    /** 本地已知简介变化后直接更新缓存，页面刷新无需再次请求 */
    public func updateCachedAbout(peerId: Int64, about: String): Unit {
        match (fullInfoCache.get(peerId)) {
            case Some(info) =>
                info.about = about
                fullInfoFetchedAtMs[peerId] = PeerInfoService.nowMs()
            case None => ()
        }
    }

    public func invalidateGroupFullInfo(peerId: Int64): Unit {
        fullInfoFetchedAtMs.remove(peerId)
    }

    public init() {}

    // ==================== accessHash 注册 ====================

    /**
     * 注册用户 accessHash（由 ChatListViewModel 或 RealContactService 注入）
     */
    public func registerUserAccessHash(userId: Int64, accessHash: Int64): Unit {
        this.userAccessHashes[userId] = accessHash
    }

    public func getUserAccessHash(userId: Int64): Int64 {
        if (this.userAccessHashes.contains(userId)) {
            return this.userAccessHashes[userId]
        }
        return 0
    }

    /**
     * 注册频道 accessHash
     */
    public func registerChannelAccessHash(channelId: Int64, accessHash: Int64): Unit {
        this.channelAccessHashes[channelId] = accessHash
    }

    // ==================== users.getFullUser ====================

    /**
     * 获取用户完整信息
     *
     * 调用链：getUserFullInfo → sendRequest(UsersGetFullUser) → parseUserFull → PeerFullInfo
     *
     * TL: users.getFullUser#b60f5918 id:InputUser = users.UserFull
     * 响应: users.userFull#3b6d152e flags:# ... full_user:UserFull users:Vector<User> chats:Vector<Chat>
     * UserFull: id:long about:flags.1?string ... blocked:flags.0?true ...
     */
    public func getUserFullInfo(userId: Int64): PeerFullInfo {
        Hilog.info(0, "CjTelegram", "[PeerInfoService] getUserFullInfo: userId=${userId}")
        let result = PeerFullInfo()
        result.peerId = userId
        result.peerType = "user"

        let client = getMTProtoClient()
        let req = UsersGetFullUser()

        // 构建 InputUser（需要 accessHash）
        if (this.userAccessHashes.contains(userId)) {
            let inputUser = InputUser()
            inputUser.userId = userId
            inputUser.accessHash = this.userAccessHashes[userId]
            req.id = inputUser
        } else {
            // 无 accessHash 时用 inputUserSelf（仅对自己有效）
            // 对他人仍会尝试，服务端可能返回 PEER_ID_INVALID
            let inputUser = InputUser()
            inputUser.userId = userId
            inputUser.accessHash = 0
            req.id = inputUser
        }

        Hilog.info(0, "CjTelegram", "[PeerInfoService] sending users.getFullUser for userId=${userId}")
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 8) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] getUserFullInfo: empty response")
            result.error = "empty_response"
            return result
        }

        this.parseUserFullResponse(responseData, result)

        // P2-289b: 本地优先回填——userFull 响应不携带 displayName/username（只有 bio/blocked），
        // 离线 / 解析失败时网络字段为空。从本地 PeerTable 取该 peer 的名字 / 用户名兜底回填，
        // 让资料页在离线 / 未加载时仍能显示 peer 名字。命中本地不覆盖已从网络拿到的非空值。
        match (getPeerStore().getLocalPeer(userId)) {
            case Some(localPeer) =>
                if (result.displayName.isEmpty()) {
                    result.displayName = localPeer.name
                }
                if (result.username.isEmpty()) {
                    result.username = localPeer.username
                }
                if (result.phone.isEmpty()) {
                    result.phone = localPeer.phone
                }
            case None => ()
        }

        return result
    }

    /**
     * 解析 users.userFull 响应
     *
     * users.userFull#3b6d152e flags:# blocked:flags.0?true ... full_user:UserFull
     *   users:Vector<User> chats:Vector<Chat>
     *
     * UserFull#d173d540 flags:# id:long about:flags.1?string settings:PeerSettings
     *   personal_photo:flags.21?Photo profile_photo:flags.2?Photo ...
     */
    private func parseUserFullResponse(data: Array<Byte>, result: PeerFullInfo): Unit {
        try {
            let d = TLDeserializer(data)
            let outerCtor = d.readUInt32()

            // RPC error
            if (outerCtor == TLConstructors.RPC_ERROR || outerCtor == 0x2144ca19) {
                let code = d.readInt32()
                let msg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeerInfoService] getUserFull RPC error ${code}: ${msg}")
                result.error = "rpc_error_${code}"
                return
            }

            // users.userFull#3b6d152e
            if (outerCtor != 0x3b6d152e) {
                Hilog.info(0, "CjTelegram", "[PeerInfoService] getUserFull unexpected ctor: ${outerCtor}")
            }

            // full_user: UserFull (boxed constructor)
            let userFullCtor = d.readUInt32()
            // users.userFull has no outer flags. Blocking and call capability bits
            // belong to the nested Api.UserFull object.
            this.parseUserFull(d, userFullCtor, result, data)

        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] parseUserFullResponse error: ${e}")
        }
    }

    /**
     * 解析 UserFull 对象（boxed, ctor already consumed by caller）
     *
     * UserFull#d173d540 flags:# id:long about:flags.1?string settings:PeerSettings ...
     *   blocked:flags.0?true computed from outer flags
     */
    private func parseUserFull(d: TLDeserializer, ctor: UInt32, result: PeerFullInfo, data: Array<Byte>): Unit {
        try {
            let innerFlags = d.readInt32()
            let innerFlags2 = d.readInt32()
            result.isBlocked = (innerFlags & 1) != 0
            result.peerId = d.readInt64()  // id

            // about: flags.1?string
            if ((innerFlags & 2) != 0) {
                result.bio = d.readString()
            }

            // settings: PeerSettings (boxed, #a518110d) — always present
            let settingsCtor = d.readUInt32()  // PeerSettings constructor
            // PeerSettings#a518110d flags:#
            if (settingsCtor == 0xa518110d) {
                let _ = d.readInt32()  // flags
            }

            // S6-15: birthday:flags2.5?Birthday（iOS Api30.swift parse_userFull _26）。它前面还有
            // photo / notify_settings / bot_info / theme / wallpaper / stories / business_* 等变长对象，
            // 这里不逐个解析，而是在 about 之后的字节里定位 birthday#6c8e1e06 且字段值合理的位置
            // （只在 flags2.5 置位时扫描，避免误判）。
            if ((innerFlags2 & (1 << 5)) != 0) {
                match (scanUserFullBirthday(data, d.getOffset())) {
                    case Some((day, month, year)) =>
                        result.birthdayDay = day
                        result.birthdayMonth = month
                        result.birthdayYear = year
                    case None => ()
                }
            }
            // S6-30: personal_photo:flags.21?Photo（仅自己可见的联系人头像）
            result.hasPersonalPhoto = (innerFlags & (1 << 21)) != 0
            // S6-27: note:flags2.22?TextWithEntities —— 同 birthday 的做法，按构造器定位
            if ((innerFlags2 & (1 << 22)) != 0) {
                match (scanUserFullNote(data, d.getOffset())) {
                    case Some(noteText) => result.note = noteText
                    case None => ()
                }
            }

            Hilog.info(0, "CjTelegram", "[PeerInfoService] parsed userFull ctor=${ctor}, flags=${innerFlags}, flags2=${innerFlags2}, bio='${result.bio}', blocked=${result.isBlocked}, birthday=${result.birthdayDay}/${result.birthdayMonth}/${result.birthdayYear}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] parseUserFull error (partial parse): ${e}")
        }
    }

    // ==================== 联系人备注（S6-27） ====================

    /**
     * userFull.note（flags2.22）是 iOS 2026-01-16 API 更新（layer 222）才进入 UserFull 的字段；
     * 本端主会话声明 layer 214，服务端按该 layer 编码 users.getFullUser，永远不带 note。
     * 所以备注单独经 CallsService 的 layer-228 派生会话再取一次 users.getFullUser，只解析 note
     * （响应其余部分是 228 编码，不交给 214 解析器）。取不到时回退到本进程内最近一次保存的值。
     */
    private let contactNoteFallback = HashMap<Int64, String>()

    public func rememberContactNote(userId: Int64, note: String): Unit {
        this.contactNoteFallback[userId] = note
    }

    public func getContactNote(userId: Int64): String {
        match (this.fetchContactNoteHighLayer(userId)) {
            case Some(note) =>
                this.contactNoteFallback[userId] = note
                return note
            case None =>
                if (this.contactNoteFallback.contains(userId)) {
                    return this.contactNoteFallback[userId]
                }
                return ""
        }
    }

    /** Some(note)（可为空串 = 服务端无备注）；None = 请求失败。 */
    private func fetchContactNoteHighLayer(userId: Int64): Option<String> {
        try {
            let req = UsersGetFullUser()
            let inputUser = InputUser()
            inputUser.userId = userId
            inputUser.accessHash = this.getUserAccessHash(userId)
            if (inputUser.accessHash == 0) {
                inputUser.accessHash = getRealMessageService().getAccessHashForUser(userId)
            }
            req.id = inputUser
            let data = getCallsService().sendOnLayer228(req.toBytes())
            if (data.size < 16) {
                Hilog.info(0, "CjTelegram", "[PeerInfoService] contactNote: empty layer-228 response")
                return None
            }
            let d = TLDeserializer(data)
            let outer = d.readUInt32()
            if (outer == TLConstructors.RPC_ERROR || outer == 0x2144ca19) {
                let code = d.readInt32()
                let msg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeerInfoService] contactNote RPC error ${code}: ${msg}")
                return None
            }
            if (outer != 0x3b6d152e) {
                Hilog.info(0, "CjTelegram", "[PeerInfoService] contactNote unexpected ctor ${outer}")
                return None
            }
            let userFullCtor = d.readUInt32()   // layer 228: userFull#06cbe645（iOS Api30 appendInt32(114026053)）
            let flags = d.readInt32()
            let flags2 = d.readInt32()
            let _ = d.readInt64()               // id
            if ((flags & 2) != 0) { let _ = d.readString() }   // about
            if ((flags2 & (1 << 22)) == 0) {
                Hilog.info(0, "CjTelegram", "[PeerInfoService] contactNote: none (ctor=${userFullCtor}, flags2=${flags2})")
                return Some("")
            }
            match (scanUserFullNote(data, d.getOffset())) {
                case Some(note) =>
                    Hilog.info(0, "CjTelegram", "[PeerInfoService] contactNote: ${note.size} chars")
                    return Some(note)
                case None =>
                    Hilog.info(0, "CjTelegram", "[PeerInfoService] contactNote: flag set but textWithEntities not found")
                    return Some("")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] contactNote error: ${e}")
            return None
        }
    }

    // ==================== messages.getCommonChats（S6-24 共同群组） ====================

    /**
     * iOS PeerInfoScreen「Groups」pane → TelegramEngine.peers.commonGroups → messages.getCommonChats。
     * messages.getCommonChats#e40ca104 user_id:InputUser max_id:long limit:int = messages.Chats
     * （iOS Api42.swift:7075 appendInt32(-468934396)）。返回的 chat 同时写入会话缓存，便于随后打开。
     */
    public func getCommonChats(userId: Int64, limit!: Int32 = 100): ArrayList<ChatResponse> {
        let out = ArrayList<ChatResponse>()
        try {
            let req = MessagesGetCommonChatsRequest()
            req.userId = userId
            req.accessHash = this.getUserAccessHash(userId)
            if (req.accessHash == 0) {
                req.accessHash = getRealMessageService().getAccessHashForUser(userId)
            }
            req.limit = limit
            let data = getMTProtoClient().sendRequest(req.toBytes())
            if (data.size < 8) { return out }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let code = d.readInt32()
                let msg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeerInfoService] getCommonChats RPC error ${code}: ${msg}")
                return out
            }
            // messages.chats#64ff9fd5 chats:Vector<Chat> / messages.chatsSlice#9cd81144 count:int chats:Vector<Chat>
            if (ctor == 0x9cd81144) {
                let _ = d.readInt32()
            } else if (ctor != 0x64ff9fd5) {
                Hilog.info(0, "CjTelegram", "[PeerInfoService] getCommonChats unexpected ctor ${ctor}")
                return out
            }
            let vec = d.readUInt32()
            if (vec != TLConstructors.VECTOR) { return out }
            let n = d.readInt32()
            var i: Int32 = 0
            while (i < n) {
                let chat = ChatResponse.deserializeBoxed(d)
                if (chat.id != 0 && chat.title.size > 0) {
                    out.add(chat)
                    getRealChatListService().cacheChatResponse(chat)
                    if (chat.isChannel && chat.accessHash != 0) {
                        this.registerChannelAccessHash(chat.id, chat.accessHash)
                        getRealMessageService().cacheChannelAccessHash(chat.id, chat.accessHash)
                    }
                }
                i += 1
            }
            Hilog.info(0, "CjTelegram", "[PeerInfoService] getCommonChats userId=${userId} → ${out.size} chats")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] getCommonChats error: ${e}")
        }
        return out
    }

    // ==================== 通知设置（S4-05 Mute 菜单） ====================

    /**
     * 对位 iOS TelegramEngine.peers.updatePeerMuteSetting / updatePeerNotificationSoundInteractive：
     * account.updateNotifySettings#84be5b93 peer:inputNotifyPeer settings:InputPeerNotifySettings。
     * 只携带显式给出的字段（mute_until / sound），其余保持服务端现值。
     */
    public func updatePeerNotifySettings(peerType: String, peerId: Int64, muteUntil!: Option<Int32> = None,
                                         soundNone!: Option<Bool> = None, showPreviews!: Option<Bool> = None): Bool {
        try {
            let req = PeerNotifySettingsUpdateRequest()
            req.peer = getRealMessageService().buildInputPeer(peerType, peerId)
            req.muteUntil = muteUntil
            req.soundNone = soundNone
            req.showPreviews = showPreviews
            let data = getMTProtoClient().sendRequest(req.toBytes())
            if (data.size < 4) { return false }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let code = d.readInt32()
                let msg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeerInfoService] updatePeerNotifySettings RPC error ${code}: ${msg}")
                return false
            }
            let ok = ctor == TLConstructors.BOOL_TRUE
            Hilog.info(0, "CjTelegram", "[PeerInfoService] updatePeerNotifySettings ${peerType}:${peerId} ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] updatePeerNotifySettings error: ${e}")
            return false
        }
    }

    /**
     * account.getNotifySettings#12b3ad31 → peerNotifySettings#99622c0c；返回 (mute_until, ios_sound 是否为 none)。
     * flags: show_previews:0?Bool silent:1?Bool mute_until:2?int ios_sound:3?NotificationSound（iOS Api20.swift:1503）
     */
    public func getPeerNotifyState(peerType: String, peerId: Int64): (Int32, Bool) {
        try {
            let inputPeer = getRealMessageService().buildInputPeer(peerType, peerId)
            let serializer = TLSerializer()
            serializer.writeUInt32(0x12b3ad31)
            serializer.writeUInt32(0xb8bc5b0c)
            serializer.writeRawBytes(inputPeer.toBytes())
            let data = getMTProtoClient().sendRequest(serializer.getBytes())
            if (data.size < 8) { return (0, false) }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor != 0x99622c0c) { return (0, false) }
            let flags = d.readInt32()
            if ((flags & 1) != 0) { let _ = d.readUInt32() }
            if ((flags & 2) != 0) { let _ = d.readUInt32() }
            var muteUntil: Int32 = 0
            if ((flags & 4) != 0) { muteUntil = d.readInt32() }
            var soundNone = false
            if ((flags & 8) != 0) {
                let soundCtor = d.readUInt32()
                soundNone = soundCtor == 0x6f0c34df
            }
            return (muteUntil, soundNone)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] getPeerNotifyState error: ${e}")
            return (0, false)
        }
    }

    // ==================== 关联讨论群解析（S5-09 Discuss） ====================

    /**
     * channelFull.linked_chat_id 指向的讨论群只出现在 channels.getFullChannel 响应尾部的 chats 向量里
     * （ChatFullResponse 不保留该向量）。这里单独请求一次并在响应字节里定位 id 相同的 chat/channel
     * 对象（channel#fe685355 / channel#1c32b11c / chat#41cbf256），解析后写入会话缓存并登记 access_hash。
     */
    public func resolveLinkedChat(channelId: Int64, linkedChatId: Int64): Option<ChatResponse> {
        if (linkedChatId == 0) { return None }
        match (getRealChatListService().getCachedChat(linkedChatId)) {
            case Some(c) => if (c.title.size > 0) { return Some(c) }
            case None => ()
        }
        try {
            if (this.channelAccessHashes.contains(channelId)) {
                getRealMessageService().cacheChannelAccessHash(channelId, this.channelAccessHashes[channelId])
            }
            let req = ChannelsGetFullChannel()
            req.channel = getRealMessageService().buildInputChannel(channelId)
            let data = getMTProtoClient().sendRequest(req.toBytes())
            if (data.size < 8) { return None }
            match (findChatInResponseBytes(data, linkedChatId)) {
                case Some(chat) =>
                    getRealChatListService().cacheChatResponse(chat)
                    if (chat.isChannel && chat.accessHash != 0) {
                        this.registerChannelAccessHash(chat.id, chat.accessHash)
                        getRealMessageService().cacheChannelAccessHash(chat.id, chat.accessHash)
                    }
                    Hilog.info(0, "CjTelegram", "[PeerInfoService] resolveLinkedChat ${channelId} → ${chat.id} '${chat.title}'")
                    return Some(chat)
                case None =>
                    Hilog.info(0, "CjTelegram", "[PeerInfoService] resolveLinkedChat: chat ${linkedChatId} not in channelFull response")
                    return None
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] resolveLinkedChat error: ${e}")
            return None
        }
    }

    // ==================== channels.getFullChannel / messages.getFullChat ====================

    /**
     * 获取群组/频道完整信息（复用 RealMessageService 已有实现）
     *
     * 调用链：getGroupFullInfo → RealMessageService.getFullChatInfo
     *   → sendRequest(ChannelsGetFullChannel | MessagesGetFullChat) → ChatFullResponse
     *
     * 注意：RealMessageService 已完整实现此逻辑，PeerInfoService 作为代理层
     * 将结果转换为 PeerFullInfo 结构。
     */
    public func getGroupFullInfo(peerType: String, peerId: Int64, maxAgeMs!: Int64 = 0): PeerFullInfo {
        if (maxAgeMs > 0) {
            match ((fullInfoCache.get(peerId), fullInfoFetchedAtMs.get(peerId))) {
                case (Some(cached), Some(at)) =>
                    if (PeerInfoService.nowMs() - at <= maxAgeMs) { return cached }
                case _ => ()
            }
        }
        Hilog.info(0, "CjTelegram", "[PeerInfoService] getGroupFullInfo: peerType=${peerType}, peerId=${peerId}")
        let result = PeerFullInfo()
        result.peerId = peerId
        result.peerType = peerType

        // 注入 accessHash 到 RealMessageService（如有缓存）
        if (peerType == "channel" && this.channelAccessHashes.contains(peerId)) {
            getRealMessageService().cacheChannelAccessHash(peerId, this.channelAccessHashes[peerId])
        }

        let chatFull = getRealMessageService().getFullChatInfo(peerType, peerId)
        result.about = chatFull.about
        result.membersCount = chatFull.membersCount
        result.onlineCount = chatFull.onlineCount
        result.canViewParticipants = chatFull.canViewParticipants
        result.linkedChatId = chatFull.linkedChatId
        result.canDeleteChannel = chatFull.canDeleteChannel
        result.activeCallId = chatFull.activeCallId
        result.activeCallAccessHash = chatFull.activeCallAccessHash
        result.canSetUsername = chatFull.canSetUsername
        result.hiddenPrehistory = chatFull.hiddenPrehistory
        result.adminsCount = chatFull.adminsCount
        result.kickedCount = chatFull.kickedCount
        result.bannedCount = chatFull.bannedCount
        result.ttlPeriod = chatFull.ttlPeriod
        result.slowmodeSeconds = chatFull.slowmodeSeconds
        if (peerType == "chat") {
            // W6 S4-25：基础群成员直接取 chatFull.participants（iOS PeerInfoScreen 读
            // CachedGroupData.participants）；此前资料页另起 channels.getParticipants，
            // 一旦 chatsCache 没命中就被当频道发出去 → CHANNEL_INVALID，成员区整段空白。
            result.participantsForbidden = chatFull.participantsForbidden
            let collected = MemberSearchResult()
            this.collectBasicGroupMembers(chatFull, "", "recent", collected)
            for (m in collected.members) { result.participants.add(m) }
            Hilog.info(0, "CjTelegram",
                "[PeerInfoService] getGroupFullInfo basic group participants=${result.participants.size} (tl=${chatFull.participants.size} users=${chatFull.users.size} forbidden=${chatFull.participantsForbidden})")
        }

        // Populate channel toggle states from Channel basic object (channel.flags.11 / flags.27).
        // These flags live in the Channel basic object cached by RealChatListService, not in channelFull.
        // Source: TL schema channel#7482147e flags.11=signatures flags.27=noforwards (iOS Api4.swift:1018-1143)
        match (getRealChatListService().getCachedChat(peerId)) {
            case Some(chat) =>
                result.signaturesEnabled = chat.signaturesEnabled
                result.noForwardsEnabled = chat.noForwardsEnabled
                Hilog.info(0, "CjTelegram", "[PeerInfoService] getGroupFullInfo channel flags: signatures=${result.signaturesEnabled}, noforwards=${result.noForwardsEnabled}")
            case None => ()
        }

        Hilog.info(0, "CjTelegram", "[PeerInfoService] getGroupFullInfo done: about='${result.about}', members=${result.membersCount}")
        fullInfoCache[peerId] = result
        fullInfoFetchedAtMs[peerId] = PeerInfoService.nowMs()
        return result
    }

    // ==================== channels.getParticipants (成员搜索) ====================

    /**
     * 搜索频道/群组成员
     *
     * 调用链：
     *   searchMembers → sendRequest(ChannelsGetParticipants) → MemberSearchResult
     *
     * TL: channels.getParticipants#77ced9d0
     *   channel:InputChannel filter:ChannelParticipantsFilter
     *   offset:int limit:int hash:long = channels.ChannelParticipants
     *
     * filter = channelParticipantsSearch#0702a40e query:string (server-side search)
     *        | channelParticipantsRecent#de3f3c79 (recent members)
     */
    public func searchMembers(channelId: Int64, query: String, offset: Int32, limit: Int32): MemberSearchResult {
        Hilog.info(0, "CjTelegram", "[PeerInfoService] searchMembers: channelId=${channelId}, query='${query}', offset=${offset}, limit=${limit}")
        let result = MemberSearchResult()
        // 基础群（peerType "chat"）：channels.getParticipants 会回 CHANNEL_INVALID，
        // iOS 同样走 messages.getFullChat → chatFull.participants（PeerInfoScreen 成员列表）。
        if (this.isBasicGroup(channelId)) {
            this.loadBasicGroupMembers(channelId, query, "recent", result)
            return result
        }

        let client = getMTProtoClient()

        let req = ChannelsGetParticipants()
        let ch = InputChannel()
        ch.channelId = channelId
        if (this.channelAccessHashes.contains(channelId)) {
            ch.accessHash = this.channelAccessHashes[channelId]
        } else {
            // 资料页未注册时回落到会话层缓存 / 本地落库的 hash
            ch.accessHash = getRealMessageService().getAccessHashForChannel(channelId)
        }
        req.channel = ch
        req.offset = offset
        req.limit = limit

        // filter: channelParticipantsSearch (0x0702a40e) with query if provided,
        // else channelParticipantsRecent (0xde3f3c79)
        if (query.size > 0) {
            req.filter = 0x0702a40e       // channelParticipantsSearch
            req.filterQuery = query       // TL serialize appends q:string for this filter
        } else {
            req.filter = 0xde3f3c79      // channelParticipantsRecent
        }

        Hilog.info(0, "CjTelegram", "[PeerInfoService] sending channels.getParticipants for channelId=${channelId}")
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 8) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] searchMembers: empty response")
            result.error = "empty_response"
            return result
        }

        this.parseParticipantsResponse(responseData, query, result)
        // 缓存未命中导致误判为频道时的兜底：400（CHANNEL_INVALID）→ 按基础群重试
        if (result.error == "rpc_error_400" && result.members.size == 0) {
            let fallback = MemberSearchResult()
            this.loadBasicGroupMembers(channelId, query, "recent", fallback)
            if (fallback.error.size == 0) { return fallback }
        }
        return result
    }

    // ==================== 基础群成员（messages.getFullChat） ====================

    /** 缓存判定：ChatResponse.isChannel=false 即基础群（chat#41cbf256），否则频道/超级群 */
    private func isBasicGroup(chatId: Int64): Bool {
        // 先查 legacyChatsCache 再查 chatsCache；都没命中只能回 false（调用方应优先传 peerType）
        match (getRealChatListService().getCachedChat("chat", chatId)) {
            case Some(c) => !c.isChannel
            case None =>
                Hilog.info(0, "CjTelegram", "[PeerInfoService] isBasicGroup: chat ${chatId} not in cache, assuming channel")
                false
        }
    }

    /**
     * 基础群成员列表：messages.getFullChat#aeb00b34 → messages.chatFull → chatFull.participants
     * + 尾部 users 向量解析姓名/accessHash（对位 iOS PeerInfoScreen 基础群成员段）。
     * filterType: recent=全部 / admins=创建者+管理员 / bots=机器人 / 其他=空（基础群无封禁列表 API）
     * query: 本地按姓名/用户名子串过滤（服务端无基础群搜索接口）
     */
    private func loadBasicGroupMembers(chatId: Int64, query: String, filterType: String, result: MemberSearchResult): Unit {
        Hilog.info(0, "CjTelegram", "[PeerInfoService] loadBasicGroupMembers: chatId=${chatId} filter=${filterType} q='${query}'")
        let client = getMTProtoClient()
        let req = MessagesGetFullChat()
        req.chatId = chatId
        let data = client.sendRequest(req.toBytes())
        if (data.size < 8) {
            result.error = "empty_response"
            return
        }
        let d0 = TLDeserializer(data)
        let ctor0 = d0.readUInt32()
        if (ctor0 == TLConstructors.RPC_ERROR || ctor0 == 0x2144ca19) {
            let code = d0.readInt32()
            let msg = d0.readString()
            Hilog.info(0, "CjTelegram", "[PeerInfoService] getFullChat RPC error ${code}: ${msg}")
            result.error = "rpc_error_${code}"
            return
        }
        let full = ChatFullResponse.deserialize(data)
        if (full.participantsForbidden) {
            result.error = "participants_forbidden"
            return
        }
        this.collectBasicGroupMembers(full, query, filterType, result)
        Hilog.info(0, "CjTelegram", "[PeerInfoService] loadBasicGroupMembers done: ${result.members.size} members")
    }

    /**
     * chatFull.participants + 尾部 users → MemberInfo（与 iOS CachedGroupData.participants 同源）。
     * 供 getGroupFullInfo（资料页成员段）与 loadBasicGroupMembers（成员页 / 搜索）共用。
     */
    private func collectBasicGroupMembers(full: ChatFullResponse, query: String, filterType: String, result: MemberSearchResult): Unit {
        let q = query.toAsciiLower()
        for (p in full.participants) {
            let m = MemberInfo()
            m.userId = p.userId
            m.inviterId = p.inviterId
            m.joinDate = p.date
            m.isAdmin = p.isAdmin
            m.isCreator = p.isCreator
            var isBot = false
            for (u in full.users) {
                if (u.id == p.userId) {
                    m.firstName = u.firstName
                    m.lastName = u.lastName
                    m.username = u.username
                    m.accessHash = u.accessHash
                    isBot = u.isBot
                    break
                }
            }
            if (filterType == "admins" && !(m.isAdmin || m.isCreator)) { continue }
            if (filterType == "bots" && !isBot) { continue }
            if (filterType != "recent" && filterType != "admins" && filterType != "bots") { continue }
            if (q.size > 0) {
                let hay = "${m.firstName} ${m.lastName} ${m.username}".toAsciiLower()
                if (!hay.contains(q)) { continue }
            }
            result.members.add(m)
        }
        result.totalCount = Int32(result.members.size)
    }

    /**
     * 解析 channels.channelParticipants 响应
     *
     * channels.channelParticipants#9ab0feaf
     *   count:int participants:Vector<ChannelParticipant>
     *   chats:Vector<Chat> users:Vector<User>
     *
     * channels.channelParticipantsNotModified#f0173fe9 (hash 命中时)
     */
    private func parseParticipantsResponse(data: Array<Byte>, query: String, result: MemberSearchResult): Unit {
        try {
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()

            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let code = d.readInt32()
                let msg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeerInfoService] getParticipants RPC error ${code}: ${msg}")
                result.error = "rpc_error_${code}"
                return
            }

            if (ctor == 0xf0173fe9) {
                // channelParticipantsNotModified — return empty (no-cache update)
                Hilog.info(0, "CjTelegram", "[PeerInfoService] channelParticipantsNotModified")
                return
            }

            if (ctor != 0x9ab0feaf) {
                Hilog.info(0, "CjTelegram", "[PeerInfoService] unexpected ctor: ${ctor}")
                return
            }

            result.totalCount = d.readInt32()
            let _ = d.readUInt32()  // vector constructor
            let partCount = d.readInt32()

            Hilog.info(0, "CjTelegram", "[PeerInfoService] parsing ${partCount} participants (total=${result.totalCount})")

            var i: Int32 = 0
            while (i < partCount) {
                let member = this.parseChannelParticipant(d)
                if (member.userId > 0) {
                    result.members.add(member)
                }
                i += 1
            }

            // Resolve user names from trailing users vector
            try {
                // Skip chats vector
                let _ = d.readUInt32()  // vector ctor
                let chatsCount = d.readInt32()
                var ci: Int32 = 0
                while (ci < chatsCount) {
                    skipTLChat(d)
                    ci += 1
                }

                // Users vector
                let _ = d.readUInt32()  // vector ctor
                let usersCount = d.readInt32()
                var ui: Int32 = 0
                while (ui < usersCount) {
                    let user = UserResponse.deserializeBoxed(d)
                    for (member in result.members) {
                        if (member.userId == user.id) {
                            member.firstName = user.firstName
                            member.lastName = user.lastName
                            member.username = user.username
                            member.accessHash = user.accessHash
                        }
                    }
                    ui += 1
                }
            } catch (_: Exception) {
                // Name resolution is best-effort
            }

            Hilog.info(0, "CjTelegram", "[PeerInfoService] searchMembers done: ${result.members.size} members returned")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] parseParticipantsResponse error: ${e}")
            result.error = "parse_error"
        }
    }

    /**
     * 解析单个 ChannelParticipant
     *
     * channelParticipant#73fdd43f  user_id:long date:int
     * channelParticipantSelf#a3289a6d flags:# via_request:flags.0?true user_id:long inviter_id:long date:int
     * channelParticipantAdmin#34c3bb53  ...
     * channelParticipantCreator#2fe601d3  ...
     * channelParticipantBanned#6df8014e  ...
     * channelParticipantLeft#1b03f006  peer:Peer
     */
    private func parseChannelParticipant(d: TLDeserializer): MemberInfo {
        let member = MemberInfo()
        let ctor = d.readUInt32()

        if (ctor == 0x73fdd43f) {
            // channelParticipant
            member.userId = d.readInt64()
            let _ = d.readInt32()  // date
        } else if (ctor == 0xcb397619 || ctor == 0x1bd54456) {
            // channelParticipant#cb397619（layer 214）flags:# user_id:long date:int subscription_until_date:flags.0?int
            // channelParticipant#1bd54456（iOS Api4.swift）同上 + rank:flags.2?string
            let flags = d.readInt32()
            member.userId = d.readInt64()
            let _ = d.readInt32()  // date
            if ((flags & 1) != 0) { let _ = d.readInt32() }
            if (ctor == 0x1bd54456 && (flags & 4) != 0) { member.rank = d.readString() }
        } else if (ctor == 0x4f607bef || ctor == 0xa9478a1a) {
            // channelParticipantSelf#4f607bef（layer 214）flags:# via_request:flags.0?true user_id:long inviter_id:long
            //   date:int subscription_until_date:flags.1?int；#a9478a1a（iOS）另有 rank:flags.2?string
            let flags = d.readInt32()
            member.userId = d.readInt64()
            let _ = d.readInt64()  // inviter_id
            let _ = d.readInt32()  // date
            if ((flags & 2) != 0) { let _ = d.readInt32() }
            if (ctor == 0xa9478a1a && (flags & 4) != 0) { member.rank = d.readString() }
        } else if (ctor == 0xa3289a6d) {
            // channelParticipantSelf
            let _ = d.readInt32()  // flags
            member.userId = d.readInt64()
            let _ = d.readInt64()  // inviter_id
            let _ = d.readInt32()  // date
        } else if (ctor == 0x34c3bb53) {
            // channelParticipantAdmin
            let flags = d.readInt32()
            member.userId = d.readInt64()
            if ((flags & 2) != 0) { let _ = d.readInt64() }  // inviter_id
            let _ = d.readInt64()  // promoted_by
            let _ = d.readInt32()  // date
            let _ = d.readUInt32()  // ChatAdminRights ctor
            member.adminFlags = d.readInt32()
            if ((flags & 4) != 0) { member.rank = d.readString() }
            member.isAdmin = true
        } else if (ctor == 0x2fe601d3) {
            // channelParticipantCreator
            let flags = d.readInt32()
            member.userId = d.readInt64()
            let _ = d.readUInt32()  // ChatAdminRights ctor
            member.adminFlags = d.readInt32()
            if ((flags & 1) != 0) { member.rank = d.readString() }
            member.isCreator = true
            member.isAdmin = true
        } else if (ctor == 0x6df8014e) {
            // channelParticipantBanned
            let flags = d.readInt32()
            // peer: Peer (boxed)
            let peerCtor = d.readUInt32()
            if (peerCtor == 0x59511722) {
                // peerUser
                member.userId = d.readInt64()
            }
            let _ = d.readInt64()  // kicked_by
            let _ = d.readInt32()  // date
            let _ = d.readUInt32()  // ChatBannedRights ctor
            let _ = d.readInt32()  // banned_rights flags
            let _ = d.readInt32()  // banned_rights until_date
        } else if (ctor == 0x1b03f006) {
            // channelParticipantLeft
            let peerCtor = d.readUInt32()
            if (peerCtor == 0x59511722) {
                member.userId = d.readInt64()
            }
        }
        // Unknown type: return with userId=0 → filtered out by caller

        return member
    }

    // ==================== channels.getParticipants (filter 变体) ====================

    /**
     * 按 filterType 获取频道成员，支持 Recent/Admins/Bots/Kicked/Banned/Search 分类
     *
     * TL: channels.getParticipants#77ced9d0
     *   channel:InputChannel filter:ChannelParticipantsFilter
     *   offset:int limit:int hash:long = channels.ChannelParticipants
     *
     * filterType 取值：
     *   "recent"  → channelParticipantsRecent#de3f3c79   (无参数)
     *   "admins"  → channelParticipantsAdmins#b4608969   (无参数)
     *   "bots"    → channelParticipantsBots#b0d1865b     (无参数)
     *   "kicked"  → channelParticipantsKicked#a3b54985   q:string
     *   "banned"  → channelParticipantsBanned#1427a5e1   q:string
     *   "search"  → channelParticipantsSearch#656ac4b    q:string
     *
     * 以上 ctor 来自 iOS Api4.swift ChannelParticipantsFilter 序列化块
     * 及 telegram_api.tl schema 验证（0 手算）。
     *
     * 成员详情：joinDate/inviterId 从 channelParticipant 各变体字段提取。
     * UI (分 tab 展示) 不在本单元，defer → P2-134b。
     */
    public func getParticipantsByFilter(
        channelId: Int64,
        filterType: String,
        offset: Int32,
        limit: Int32,
        q: String,
        peerType!: String = ""
    ): MemberSearchResult {
        Hilog.info(0, "CjTelegram", "[PeerInfoService] getParticipantsByFilter: channelId=${channelId}, filter='${filterType}', q='${q}', offset=${offset}, limit=${limit}, peerType='${peerType}'")
        let result = MemberSearchResult()
        // 调用方知道 peerType 时以它为准（资料页 / 成员页都从会话 peerType 来），不再依赖
        // chatsCache 是否恰好命中；基础群对 channels.getParticipants 必回 CHANNEL_INVALID。
        if (peerType == "chat" || (peerType != "channel" && this.isBasicGroup(channelId))) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] getParticipantsByFilter: basic group ${channelId} -> messages.getFullChat participants")
            this.loadBasicGroupMembers(channelId, q, filterType, result)
            return result
        }

        let client = getMTProtoClient()

        let req = ChannelsGetParticipants()
        let ch = InputChannel()
        ch.channelId = channelId
        if (this.channelAccessHashes.contains(channelId)) {
            ch.accessHash = this.channelAccessHashes[channelId]
        } else {
            // 资料页未注册时回落到会话层缓存 / 本地落库的 hash
            ch.accessHash = getRealMessageService().getAccessHashForChannel(channelId)
        }
        req.channel = ch
        req.offset = offset
        req.limit = limit
        req.hash = 0

        // 按 filterType 设置 ChannelParticipantsFilter ctor（iOS Api4.swift 验证）
        if (filterType == "recent") {
            // channelParticipantsRecent#de3f3c79 — iOS signed=-566281095
            req.filter = 0xde3f3c79
            req.filterQuery = ""
        } else if (filterType == "admins") {
            // channelParticipantsAdmins#b4608969 — iOS signed=-1268741783
            req.filter = 0xb4608969
            req.filterQuery = ""
        } else if (filterType == "bots") {
            // channelParticipantsBots#b0d1865b — iOS signed=-1328445861
            req.filter = 0xb0d1865b
            req.filterQuery = ""
        } else if (filterType == "kicked") {
            // channelParticipantsKicked#a3b54985 — iOS signed=-1548400251
            req.filter = 0xa3b54985
            req.filterQuery = q
        } else if (filterType == "banned") {
            // channelParticipantsBanned#1427a5e1 — iOS signed=338142689
            req.filter = 0x1427a5e1
            req.filterQuery = q
        } else {
            // default: channelParticipantsSearch#656ac4b — iOS signed=106343499
            // (covers filterType == "search" and unknown values)
            req.filter = 0x0656ac4b
            req.filterQuery = q
        }

        // TLMethods.cj ChannelsGetParticipants.serialize 已更新（P2-134），
        // 覆盖 0x0656ac4b / 0xa3b54985 / 0x1427a5e1 等全部需要 q:string 的 filter。
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 8) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] getParticipantsByFilter: empty response")
            result.error = "empty_response"
            return result
        }

        this.parseParticipantsByFilterResponse(responseData, result)
        // 与 searchMembers 同样的兜底：缓存未命中把基础群当频道发出去 → 400 CHANNEL_INVALID，
        // 改走 messages.getFullChat participants。
        if (result.error == "rpc_error_400" && result.members.size == 0 && peerType != "channel") {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] getParticipantsByFilter: 400 on ${channelId}, retrying as basic group")
            let fallback = MemberSearchResult()
            this.loadBasicGroupMembers(channelId, q, filterType, fallback)
            if (fallback.error.size == 0) { return fallback }
        }
        return result
    }

    /**
     * 解析 channels.channelParticipants 响应（detail 版本）
     *
     * channels.channelParticipants#9ab0feaf
     *   count:int participants:Vector<ChannelParticipant>
     *   chats:Vector<Chat> users:Vector<User>
     */
    private func parseParticipantsByFilterResponse(data: Array<Byte>, result: MemberSearchResult): Unit {
        try {
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()

            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let code = d.readInt32()
                let msg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeerInfoService] getParticipantsByFilter RPC error ${code}: ${msg}")
                result.error = "rpc_error_${code}"
                return
            }

            if (ctor == 0xf0173fe9) {
                // channelParticipantsNotModified — server cache not modified
                Hilog.info(0, "CjTelegram", "[PeerInfoService] channelParticipantsNotModified (filter variant)")
                return
            }

            if (ctor != 0x9ab0feaf) {
                Hilog.info(0, "CjTelegram", "[PeerInfoService] getParticipantsByFilter unexpected ctor: ${ctor}")
                return
            }

            result.totalCount = d.readInt32()

            // participants: Vector<ChannelParticipant>
            // vector constructor 0x1cb5c415
            let vecCtor = d.readUInt32()
            if (vecCtor != 0x1cb5c415) {
                Hilog.info(0, "CjTelegram", "[PeerInfoService] participants vector ctor unexpected: ${vecCtor}")
                return
            }
            let partCount = d.readInt32()
            Hilog.info(0, "CjTelegram", "[PeerInfoService] filter variant: parsing ${partCount} participants (total=${result.totalCount})")

            var i: Int32 = 0
            while (i < partCount) {
                let member = this.parseChannelParticipantDetail(d)
                if (member.userId > 0) {
                    result.members.add(member)
                }
                i += 1
            }

            // Resolve user names from trailing vectors
            try {
                // chats: Vector<Chat> — skip
                let chatVecCtor = d.readUInt32()  // 0x1cb5c415
                let chatsCount = d.readInt32()
                var ci: Int32 = 0
                while (ci < chatsCount) {
                    skipTLChat(d)
                    ci += 1
                }

                // users: Vector<User>
                let userVecCtor = d.readUInt32()  // 0x1cb5c415
                let usersCount = d.readInt32()
                var ui: Int32 = 0
                while (ui < usersCount) {
                    let user = UserResponse.deserializeBoxed(d)
                    for (member in result.members) {
                        if (member.userId == user.id) {
                            member.firstName = user.firstName
                            member.lastName = user.lastName
                            member.username = user.username
                            member.accessHash = user.accessHash
                        }
                    }
                    ui += 1
                }
            } catch (_: Exception) {
                // Name resolution is best-effort
            }

            Hilog.info(0, "CjTelegram", "[PeerInfoService] getParticipantsByFilter done: ${result.members.size} members")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] parseParticipantsByFilterResponse error: ${e}")
            result.error = "parse_error"
        }
    }

    /**
     * 解析单个 ChannelParticipant（detail 版本，带 joinDate/inviterId/isBanned）
     *
     * iOS Api4.swift ChannelParticipant 序列化顺序（已验证，0 手算）：
     *
     * channelParticipant#1bd54456 (iOS signed=466961494)
     *   flags:# userId:long date:int
     *   subscriptionUntilDate:flags.0?int rank:flags.2?string
     *
     * channelParticipantSelf#a9478a1a (iOS signed=-1454929382)
     *   flags:# userId:long inviter_id:long date:int
     *   subscriptionUntilDate:flags.1?int rank:flags.2?string
     *
     * channelParticipantAdmin#34c3bb53 (iOS signed=885242707) — ctor correct
     *   flags:# userId:long inviter_id:flags.1?long promoted_by:long date:int
     *   admin_rights:ChatAdminRights rank:flags.2?string
     *
     * channelParticipantCreator#2fe601d3 (iOS signed=803602899) — ctor correct
     *   flags:# userId:long admin_rights:ChatAdminRights rank:flags.0?string
     *
     * channelParticipantBanned#d5f0ad91 (iOS signed=-705647215)
     *   flags:# peer:Peer kicked_by:long date:int
     *   banned_rights:ChatBannedRights rank:flags.2?string
     *
     * channelParticipantLeft#1b03f006 (iOS signed=453242886) — ctor correct
     *   peer:Peer
     *
     * Also keep legacy ctors for robustness:
     *   0x73fdd43f (old channelParticipant: user_id:long date:int)
     *   0xa3289a6d (old channelParticipantSelf: flags user_id inviter_id date)
     *   0x6df8014e (old channelParticipantBanned)
     */
    private func parseChannelParticipantDetail(d: TLDeserializer): MemberInfo {
        let member = MemberInfo()
        let ctor = d.readUInt32()

        if (ctor == 0x1bd54456 || ctor == 0x73fdd43f || ctor == 0xcb397619) {
            // channelParticipant (new layer: flags + userId + date + optional fields)
            // old layer: user_id:long date:int (no flags)
            // layer 214 (MTProtoConfig.LAYER)，服务器按请求层回这个：
            //   channelParticipant#cb397619 flags:# user_id:long date:int subscription_until_date:flags.0?int
            //   （td/generate/scheme/telegram_api.tl:744）
            if (ctor == 0xcb397619) {
                let flags = d.readInt32()
                member.userId = d.readInt64()
                member.joinDate = d.readInt32()
                if ((flags & 1) != 0) { let _ = d.readInt32() }  // subscription_until_date flags.0
            } else if (ctor == 0x1bd54456) {
                let flags = d.readInt32()
                member.userId = d.readInt64()
                member.joinDate = d.readInt32()
                if ((flags & 1) != 0) { let _ = d.readInt32() }  // subscriptionUntilDate flags.0
                if ((flags & 4) != 0) { member.rank = d.readString() }  // rank flags.2
            } else {
                // old ctor: user_id:long date:int (no flags)
                member.userId = d.readInt64()
                member.joinDate = d.readInt32()
            }
        } else if (ctor == 0xa9478a1a || ctor == 0xa3289a6d || ctor == 0x4f607bef) {
            // channelParticipantSelf
            // new: flags:# userId:long inviterId:long date:int subscriptionUntilDate:flags.1?int rank:flags.2?string
            // layer 214 #4f607bef: flags:# via_request:flags.0?true user_id:long inviter_id:long date:int
            //   subscription_until_date:flags.1?int（td/generate/scheme/telegram_api.tl:745）
            // old: flags:# user_id:long inviter_id:long date:int
            let flags = d.readInt32()
            member.userId = d.readInt64()
            member.inviterId = d.readInt64()
            member.joinDate = d.readInt32()
            if (ctor == 0xa9478a1a) {
                if ((flags & 2) != 0) { let _ = d.readInt32() }  // subscriptionUntilDate flags.1
                if ((flags & 4) != 0) { member.rank = d.readString() }  // rank flags.2
            } else if (ctor == 0x4f607bef) {
                if ((flags & 2) != 0) { let _ = d.readInt32() }  // subscription_until_date flags.1
            }
        } else if (ctor == 0x34c3bb53) {
            // channelParticipantAdmin#34c3bb53 (ctor same in both layers)
            // flags:# userId:long inviterId:flags.1?long promotedBy:long date:int
            //   adminRights:ChatAdminRights rank:flags.2?string
            let flags = d.readInt32()
            member.userId = d.readInt64()
            if ((flags & 2) != 0) { member.inviterId = d.readInt64() }
            let _ = d.readInt64()  // promoted_by
            member.joinDate = d.readInt32()
            let _ = d.readUInt32()  // ChatAdminRights ctor
            member.adminFlags = d.readInt32()
            if ((flags & 4) != 0) { member.rank = d.readString() }
            member.isAdmin = true
        } else if (ctor == 0x2fe601d3) {
            // channelParticipantCreator#2fe601d3 (ctor same)
            // flags:# userId:long adminRights:ChatAdminRights rank:flags.0?string
            let flags = d.readInt32()
            member.userId = d.readInt64()
            let _ = d.readUInt32()  // ChatAdminRights ctor
            member.adminFlags = d.readInt32()
            if ((flags & 1) != 0) { member.rank = d.readString() }
            member.isCreator = true
            member.isAdmin = true
        } else if (ctor == 0xd5f0ad91 || ctor == 0x6df8014e) {
            // channelParticipantBanned
            // new#d5f0ad91: flags:# peer:Peer kickedBy:long date:int bannedRights:ChatBannedRights rank:flags.2?string
            // old#6df8014e: flags:# peer:Peer kicked_by:long date:int bannedRights:ChatBannedRights
            let flags = d.readInt32()
            let peerCtor = d.readUInt32()
            if (peerCtor == 0x59511722) {
                // peerUser
                member.userId = d.readInt64()
            } else if (peerCtor == 0x36c6019a) {
                // peerChat
                let _ = d.readInt64()
            } else if (peerCtor == 0xa2a5371e) {
                // peerChannel
                let _ = d.readInt64()
            }
            let _ = d.readInt64()   // kicked_by
            member.joinDate = d.readInt32()  // date (when banned)
            let _ = d.readUInt32()  // ChatBannedRights ctor
            let _ = d.readInt32()   // banned_rights flags
            let _ = d.readInt32()   // until_date
            if (ctor == 0xd5f0ad91 && (flags & 4) != 0) { member.rank = d.readString() }
            member.isBanned = true
        } else if (ctor == 0x1b03f006) {
            // channelParticipantLeft#1b03f006 peer:Peer
            let peerCtor = d.readUInt32()
            if (peerCtor == 0x59511722) {
                member.userId = d.readInt64()
            } else {
                let _ = d.readInt64()
            }
        } else {
            Hilog.info(0, "CjTelegram", "[PeerInfoService] parseChannelParticipantDetail: unknown ctor 0x${ctor}")
        }

        return member
    }
}

// ==================== 辅助解析函数 ====================

/**
 * 跳过一个 Chat TL 对象（best-effort，用于越过 chats vector）
 */
private func skipTLChat(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x41cbf256 || ctor == 0x38af6782) {
        // chat basic: flags, id, title, photo, participants_count, date, version
        let flags = d.readInt32()
        let _ = d.readInt64()  // id
        let _ = d.readString()  // title
        skipTLChatPhoto(d)
        let _ = d.readInt32()  // participants_count
        let _ = d.readInt32()  // date
        let _ = d.readInt32()  // version
        if ((flags & 512) != 0) { let _ = d.readInt64() }  // migrated_to
        if ((flags & 16384) != 0) { let _ = d.readString() }  // admin_title
    }
    // channel or unknown: surrender (outer catch handles it)
}

private func skipTLChatPhoto(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x37c1011c) {
        // chatPhotoEmpty — no fields
    } else if (ctor == 0x1c6e1c11) {
        // chatPhoto: flags, photo_id, stripped_thumb?, dc_id
        let flags = d.readInt32()
        let _ = d.readInt64()  // photo_id
        if ((flags & 1) != 0) { let _ = d.readBytes() }  // stripped_thumb
        let _ = d.readInt32()  // dc_id
    }
}

// ==================== S6-15 / S6-24 / S4-05 / S5-09 辅助 ====================

/**
 * S6-27：在 users.userFull 响应里从 from 起定位 note（textWithEntities#751f3146 text:string
 * entities:Vector<MessageEntity>）。UserFull 中只有 note 一个 TextWithEntities 字段；要求紧随
 * 其后的 entities 向量构造器正确才采用。
 */
private func scanUserFullNote(data: Array<Byte>, from: Int64): Option<String> {
    var pos = if (from < 4) { 4 } else { from }
    while (pos + 12 <= data.size) {
        // 0x751f3146 小端：46 31 1f 75
        if (UInt8(data[pos]) == 0x46 && UInt8(data[pos + 1]) == 0x31 && UInt8(data[pos + 2]) == 0x1f && UInt8(data[pos + 3]) == 0x75) {
            try {
                let d = TLDeserializer(ByteUtils.slice(data, pos, data.size))
                let _ = d.readUInt32()
                let text = d.readString()
                let vec = d.readUInt32()
                if (vec == TLConstructors.VECTOR) {
                    return Some(text)
                }
            } catch (_e: Exception) {}
        }
        pos += 1
    }
    return None
}

/**
 * 在 users.userFull 响应里从 from 起定位 birthday#6c8e1e06 flags:# day:int month:int year:flags.0?int，
 * 要求 flags ∈ {0,1}、day 1..31、month 1..12、year（若有）1900..2100。
 */
private func scanUserFullBirthday(data: Array<Byte>, from: Int64): Option<(Int32, Int32, Int32)> {
    var pos = if (from < 4) { 4 } else { from }
    while (pos + 16 <= data.size) {
        // 0x6c8e1e06 小端：06 1e 8e 6c
        if (UInt8(data[pos]) == 0x06 && UInt8(data[pos + 1]) == 0x1e && UInt8(data[pos + 2]) == 0x8e && UInt8(data[pos + 3]) == 0x6c) {
            try {
                let d = TLDeserializer(ByteUtils.slice(data, pos, data.size))
                let _ = d.readUInt32()
                let flags = d.readInt32()
                let day = d.readInt32()
                let month = d.readInt32()
                if ((flags == 0 || flags == 1) && day >= 1 && day <= 31 && month >= 1 && month <= 12) {
                    var year: Int32 = 0
                    if ((flags & 1) != 0) {
                        year = d.readInt32()
                        if (year < 1900 || year > 2100) { year = -1 }
                    }
                    if (year >= 0) { return Some((day, month, year)) }
                }
            } catch (_e: Exception) {}
        }
        pos += 1
    }
    return None
}

/** 在响应字节里定位 id == chatId 的 chat/channel 对象（同 TLChatComposeExtras.findUserInResponse 的思路）。 */
private func findChatInResponseBytes(data: Array<Byte>, chatId: Int64): Option<ChatResponse> {
    var pos: Int64 = 4
    while (pos + 16 <= data.size) {
        let b0 = UInt8(data[pos])
        let b1 = UInt8(data[pos + 1])
        let b2 = UInt8(data[pos + 2])
        let b3 = UInt8(data[pos + 3])
        // channel#fe685355 → 55 53 68 fe；channel#1c32b11c → 1c b1 32 1c；chat#41cbf256 → 56 f2 cb 41
        let isChatCtor = (b0 == 0x55 && b1 == 0x53 && b2 == 0x68 && b3 == 0xfe) ||
            (b0 == 0x1c && b1 == 0xb1 && b2 == 0x32 && b3 == 0x1c) ||
            (b0 == 0x56 && b1 == 0xf2 && b2 == 0xcb && b3 == 0x41)
        if (isChatCtor) {
            try {
                let d = TLDeserializer(ByteUtils.slice(data, pos, data.size))
                let chat = ChatResponse.deserializeBoxed(d)
                if (chat.id == chatId && chat.title.size > 0) {
                    return Some(chat)
                }
            } catch (_e: Exception) {}
        }
        pos += 1
    }
    return None
}

/** messages.getCommonChats#e40ca104 user_id:InputUser max_id:long limit:int = messages.Chats */
private class MessagesGetCommonChatsRequest <: TLObject {
    public var userId: Int64 = 0
    public var accessHash: Int64 = 0
    public var maxId: Int64 = 0
    public var limit: Int32 = 100

    public func getConstructorId(): UInt32 { return 0xe40ca104 }

    public func serialize(serializer: TLSerializer) {
        let inputUser = InputUser()
        inputUser.userId = this.userId
        inputUser.accessHash = this.accessHash
        serializer.writeRawBytes(inputUser.toBytes())
        serializer.writeInt64(this.maxId)
        serializer.writeInt32(this.limit)
    }
}

/**
 * account.updateNotifySettings#84be5b93 peer:InputNotifyPeer settings:InputPeerNotifySettings = Bool
 * inputNotifyPeer#b8bc5b0c peer:InputPeer；inputPeerNotifySettings#cacb6ae2 flags:# show_previews:flags.0?Bool
 * silent:flags.1?Bool mute_until:flags.2?int sound:flags.3?NotificationSound …（只写 mute_until / sound）
 */
private class PeerNotifySettingsUpdateRequest <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var muteUntil: Option<Int32> = None
    public var soundNone: Option<Bool> = None
    public var showPreviews: Option<Bool> = None

    public func getConstructorId(): UInt32 { return 0x84be5b93 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(0xb8bc5b0c)
        serializer.writeRawBytes(this.peer.toBytes())
        var flags: Int32 = 0
        if (this.showPreviews.isSome()) { flags = flags | 1 }
        if (this.muteUntil.isSome()) { flags = flags | 4 }
        if (this.soundNone.isSome()) { flags = flags | 8 }
        serializer.writeUInt32(0xcacb6ae2)
        serializer.writeInt32(flags)
        match (this.showPreviews) {
            case Some(v) => serializer.writeUInt32(if (v) { TLConstructors.BOOL_TRUE } else { TLConstructors.BOOL_FALSE })
            case None => ()
        }
        match (this.muteUntil) {
            case Some(v) => serializer.writeInt32(v)
            case None => ()
        }
        match (this.soundNone) {
            case Some(none) =>
                if (none) {
                    serializer.writeUInt32(0x6f0c34df)  // notificationSoundNone
                } else {
                    serializer.writeUInt32(0x97e8bebe)  // notificationSoundDefault
                }
            case None => ()
        }
    }
}
