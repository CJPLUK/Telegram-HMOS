package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import std.collection.HashMap

/**
 * SearchPeerMembersService — 群成员搜索服务
 *
 * 实现 iOS SearchPeerMembers.swift 的仓颉对应逻辑：
 *   - 频道/超级群：通过 channels.getParticipants(filter=channelParticipantsSearch) 向服务器搜索
 *   - 普通群：通过 getChannelMembers("recent") + 本地名称过滤
 *
 * 调用链：searchPeerMembers() → getMTProtoClient().sendRequest(ChannelsGetParticipants) → 解析 channelParticipants
 */

private var _searchPeerMembersServiceInstance: Option<SearchPeerMembersService> = None

public func getSearchPeerMembersService(): SearchPeerMembersService {
    match (_searchPeerMembersServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = SearchPeerMembersService()
            _searchPeerMembersServiceInstance = Some(inst)
            return inst
    }
}

public class SearchPeerMembersService {
    // 频道 accessHash 本地缓存（从调用方传入后缓存，供后续搜索复用）
    private var channelAccessHashCache = HashMap<Int64, Int64>()

    /**
     * 缓存频道 accessHash，供组件在调用前设置
     */
    public func cacheChannelAccessHash(channelId: Int64, accessHash: Int64): Unit {
        this.channelAccessHashCache[channelId] = accessHash
    }

    /**
     * 搜索群/频道成员
     *
     * @param peerId    频道 / 群 ID
     * @param query     搜索关键词（空字符串 = 不过滤，返回 recent 列表）
     * @param peerType  "channel" | "supergroup" | "chat" | "user"
     * @param accessHash 频道 accessHash（对 channel/supergroup 有效）
     */
    public func searchPeerMembers(
        peerId: Int64,
        query: String,
        peerType: String,
        accessHash: Int64
    ): ArrayList<ContactDisplayData> {
        Hilog.info(0, "CjTelegram", "[SearchPeerMembersService] search peerId=${peerId} query='${query}' peerType=${peerType}")

        if (peerType == "channel" || peerType == "supergroup") {
            return this.searchChannelParticipants(peerId, query, accessHash)
        } else {
            return this.searchBasicGroupMembers(peerId, query)
        }
    }

    /**
     * 频道/超级群搜索：channels.getParticipants(filter=channelParticipantsSearch q:string)
     * TL 构造器 0x0702a40e channelParticipantsSearch query:string
     */
    private func searchChannelParticipants(
        peerId: Int64,
        query: String,
        accessHash: Int64
    ): ArrayList<ContactDisplayData> {
        // 更新 accessHash 缓存
        if (accessHash != 0) {
            this.channelAccessHashCache[peerId] = accessHash
        }
        let cachedHash: Int64 = if (this.channelAccessHashCache.contains(peerId)) {
            this.channelAccessHashCache[peerId]
        } else {
            accessHash
        }

        let client = getMTProtoClient()
        let req = ChannelsGetParticipants()
        let ch = InputChannel()
        ch.channelId = peerId
        ch.accessHash = cachedHash
        req.channel = ch
        req.filter = 0x0702a40e       // channelParticipantsSearch
        req.filterQuery = query
        req.offset = 0
        req.limit = 100
        req.hash = 0

        Hilog.info(0, "CjTelegram", "[SearchPeerMembersService] channels.getParticipants search filter, query='${query}'")
        let responseData = client.sendRequest(req.toBytes())

        let result = ArrayList<ContactDisplayData>()
        if (responseData.size < 8) {
            Hilog.info(0, "CjTelegram", "[SearchPeerMembersService] empty response")
            return result
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        // RPC error check
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[SearchPeerMembersService] RPC error ${errorCode}: ${errorMessage}")
            return result
        }

        // channels.channelParticipants#9ab0feaf
        if (constructor != 0x9ab0feaf) {
            Hilog.info(0, "CjTelegram", "[SearchPeerMembersService] unexpected ctor")
            return result
        }

        let count = d.readInt32()
        Hilog.info(0, "CjTelegram", "[SearchPeerMembersService] server count=${count}")

        // Parse participants to build userId→role map
        let roleMap = HashMap<Int64, String>()
        try {
            let _vecCtor = d.readUInt32()
            let partCount = d.readInt32()
            var pi: Int32 = 0
            while (pi < partCount) {
                let partCtor = d.readUInt32()
                if (partCtor == 0xc00c07c0) {
                    // channelParticipant#c00c07c0 user_id:long date:int
                    let uid = d.readInt64()
                    let _ = d.readInt32()
                    roleMap[uid] = ""
                } else if (partCtor == 0x34c3bb53) {
                    // channelParticipantAdmin#34c3bb53 flags:# can_edit:flags.0?true is_self:flags.1?true user_id:long inviter_id:flags.1?long promoted_by:long date:int admin_rights:ChatAdminRights rank:flags.2?string
                    let flags = d.readInt32()
                    let uid = d.readInt64()
                    if ((flags & 2) != 0) { let _ = d.readInt64() }
                    let _ = d.readInt64()
                    let _ = d.readInt32()
                    let _ = d.readUInt32()
                    let _ = d.readInt32()
                    if ((flags & 4) != 0) { let _ = d.readString() }
                    roleMap[uid] = "admin"
                } else if (partCtor == 0x2fe601d3) {
                    // channelParticipantCreator#2fe601d3 flags:# user_id:long admin_rights:ChatAdminRights rank:flags.0?string
                    let flags = d.readInt32()
                    let uid = d.readInt64()
                    let _ = d.readUInt32()
                    let _ = d.readInt32()
                    if ((flags & 1) != 0) { let _ = d.readString() }
                    roleMap[uid] = "creator"
                } else if (partCtor == 0x6df8014e) {
                    // channelParticipantBanned#6df8014e flags:# left:flags.0?true peer:Peer kicked_by:long date:int banned_rights:ChatBannedRights
                    let flags = d.readInt32()
                    let uid = d.readInt64()
                    let _ = d.readInt64()
                    let _ = d.readInt32()
                    let _ = d.readUInt32()
                    let _ = d.readInt32()
                    roleMap[uid] = "kicked"
                } else if (partCtor == 0x1b03f006) {
                    // channelParticipantSelf#1b03f006 flags:# via_request:flags.0?true user_id:long inviter_id:long date:int
                    let flags = d.readInt32()
                    let uid = d.readInt64()
                    let _ = d.readInt64()
                    let _ = d.readInt32()
                    roleMap[uid] = ""
                } else {
                    Hilog.info(0, "CjTelegram", "[SearchPeerMembersService] unknown participant ctor, stopping")
                    break
                }
                pi += 1
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SearchPeerMembersService] participant parse error: ${e}")
        }

        // Skip chats vector, then parse users vector
        try {
            let _chatsVecCtor = d.readUInt32()
            let chatsCount = d.readInt32()
            var ci: Int32 = 0
            while (ci < chatsCount) {
                let _ = ChatResponse.deserializeWithConstructor(d.readUInt32(), d)
                ci += 1
            }

            let _usersVecCtor = d.readUInt32()
            let usersCount = d.readInt32()
            var ui: Int32 = 0
            while (ui < usersCount) {
                try {
                    let user = UserResponse.deserializeBoxed(d)
                    let member = ContactDisplayData()
                    member.userId = user.id
                    member.accessHash = user.accessHash
                    member.firstName = user.firstName
                    member.lastName = user.lastName
                    member.username = user.username
                    member.phone = user.phone
                    member.isBot = user.isBot
                    member.isSelf = user.isSelf
                    member.isOnline = user.isOnline
                    member.statusType = user.statusType
                    if (roleMap.contains(user.id)) {
                        member.role = roleMap[user.id]
                    }
                    if (user.isBot) { member.role = "bot" }
                    result.add(member)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SearchPeerMembersService] user parse error: ${e}")
                    break
                }
                ui += 1
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SearchPeerMembersService] chats/users parse error: ${e}")
        }

        Hilog.info(0, "CjTelegram", "[SearchPeerMembersService] search result size=${result.size}")
        return result
    }

    /**
     * 普通群成员搜索：通过 RealMessageService.getChannelMembers("recent") 获取全部成员，本地过滤名称
     */
    private func searchBasicGroupMembers(peerId: Int64, query: String): ArrayList<ContactDisplayData> {
        let all = getRealMessageService().getChannelMembers(peerId, "recent")
        if (query.size == 0) { return all }

        let filtered = ArrayList<ContactDisplayData>()
        let lowerQuery = query.toAsciiLower()
        for (member in all) {
            let fullName = member.getDisplayName().toAsciiLower()
            let uname = member.username.toAsciiLower()
            if (fullName.contains(lowerQuery) || uname.contains(lowerQuery)) {
                filtered.add(member)
            }
        }
        Hilog.info(0, "CjTelegram", "[SearchPeerMembersService] local filter result=${filtered.size}")
        return filtered
    }
}
