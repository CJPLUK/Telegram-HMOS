package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.AdminMemberData
import std.collection.ArrayList
import std.collection.HashMap
import std.time.DateTime

/**
 * 临时缓存 Peer 数据管理服务
 *
 * 对应 iOS TemporaryCachedPeerDataManager 模块：
 * - CachedChannelAdmins.swift — 频道管理员内存缓存与刷新
 * - PeerChannelMemberCategoriesContextsManager.swift — 按 peerId 管理缓存上下文
 *
 * 职责：
 * - 提供频道管理员列表的内存缓存层（TTL 默认 120 秒，对应 iOS defaultEmptyTimeout）
 * - 仅在缓存失效或强制刷新时向 MTProto 发起 channels.getParticipants 请求
 * - 调用链：getOrFetchAdmins → getMTProtoClient().sendRequest(ChannelsGetParticipants) → parse → cache → return
 */

/** 缓存条目：保存管理员列表及其缓存时间戳（毫秒） */
private class AdminCacheEntry {
    public var admins: ArrayList<AdminMemberData> = ArrayList<AdminMemberData>()
    public var cachedAtMs: Int64 = 0
}

/** 缓存 TTL：120 秒（对应 iOS defaultEmptyTimeout = 2 * 60） */
private let CACHE_TTL_MS: Int64 = 120_000

private var _tcpdmServiceInstance: Option<TemporaryCachedPeerDataManagerService> = None

public func getTemporaryCachedPeerDataManagerService(): TemporaryCachedPeerDataManagerService {
    match (_tcpdmServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TemporaryCachedPeerDataManagerService()
            _tcpdmServiceInstance = Some(inst)
            return inst
    }
}

public class TemporaryCachedPeerDataManagerService {
    /** 按 peerId 存储的管理员缓存 */
    private var adminCache = HashMap<Int64, AdminCacheEntry>()
    /** 按 peerId 存储的 channel accessHash（从历史请求/对话列表注入） */
    private var channelAccessHashes = HashMap<Int64, Int64>()

    /**
     * 注册 channel 的 accessHash（由 RealMessageService 或 ChatListViewModel 调用）
     */
    public func registerChannelAccessHash(peerId: Int64, accessHash: Int64): Unit {
        this.channelAccessHashes[peerId] = accessHash
    }

    /**
     * 获取缓存的管理员列表（命中时直接返回，过期或首次则向 MTProto 请求并缓存）
     *
     * @param peerId 频道 ID
     * @param forceRefresh 强制刷新（忽略 TTL）
     * @return 管理员列表（不含用户名时仅有 userId/adminFlags/rank/isCreator）
     */
    public func getOrFetchAdmins(peerId: Int64, forceRefresh!: Bool = false): ArrayList<AdminMemberData> {
        let nowMs = getNowMs()
        if (!forceRefresh && this.adminCache.contains(peerId)) {
            let entry = this.adminCache[peerId]
            if (nowMs - entry.cachedAtMs < CACHE_TTL_MS) {
                Hilog.info(0, "CjTelegram", "[TCPDM] cache hit for peerId=${peerId}, age=${nowMs - entry.cachedAtMs}ms")
                return entry.admins
            }
            Hilog.info(0, "CjTelegram", "[TCPDM] cache expired for peerId=${peerId}, fetching...")
        } else if (!forceRefresh) {
            Hilog.info(0, "CjTelegram", "[TCPDM] no cache for peerId=${peerId}, fetching...")
        } else {
            Hilog.info(0, "CjTelegram", "[TCPDM] force refresh for peerId=${peerId}")
        }

        let admins = this.fetchAdminsFromNetwork(peerId)
        let entry = AdminCacheEntry()
        entry.admins = admins
        entry.cachedAtMs = getNowMs()
        this.adminCache[peerId] = entry
        return admins
    }

    /**
     * 使缓存失效（用于管理员变更后主动清除）
     */
    public func invalidateCache(peerId: Int64): Unit {
        if (this.adminCache.contains(peerId)) {
            let _ = this.adminCache.remove(peerId)
            Hilog.info(0, "CjTelegram", "[TCPDM] invalidated cache for peerId=${peerId}")
        }
    }

    /**
     * 清除所有缓存
     */
    public func clearAllCache(): Unit {
        this.adminCache.clear()
        Hilog.info(0, "CjTelegram", "[TCPDM] all caches cleared")
    }

    /**
     * 向 MTProto 网络请求频道管理员列表
     * 调用链：fetchAdminsFromNetwork → getMTProtoClient().sendRequest(ChannelsGetParticipants) → TLDeserializer → [AdminMemberData]
     */
    private func fetchAdminsFromNetwork(peerId: Int64): ArrayList<AdminMemberData> {
        let client = getMTProtoClient()

        let req = ChannelsGetParticipants()
        let ch = InputChannel()
        ch.channelId = peerId
        if (this.channelAccessHashes.contains(peerId)) {
            ch.accessHash = this.channelAccessHashes[peerId]
        }
        req.channel = ch
        req.filter = 0xb4608969  // channelParticipantsAdmins
        req.limit = 200
        req.offset = 0

        Hilog.info(0, "CjTelegram", "[TCPDM] sending channels.getParticipants(admins) for peerId=${peerId}")
        let responseData = client.sendRequest(req.toBytes())

        let result = ArrayList<AdminMemberData>()
        if (responseData.size < 8) {
            Hilog.info(0, "CjTelegram", "[TCPDM] empty/short response, size=${responseData.size}")
            return result
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[TCPDM] RPC error ${errorCode}: ${errorMessage}")
            return result
        }

        // channels.channelParticipants#9ab0feaf
        if (constructor == 0x9ab0feaf) {
            let _ = d.readInt32()  // count
            // participants vector header
            let _ = d.readUInt32()  // vector constructor 0x1cb5c415
            let partCount = d.readInt32()
            var i: Int32 = 0
            while (i < partCount) {
                let admin = parseParticipant(d)
                if (admin.userId > 0) {
                    result.add(admin)
                }
                i += 1
            }
            // best-effort: resolve display names from users vector
            try {
                // skip chats vector
                let _ = d.readUInt32()  // vector ctor
                let chatsCount = d.readInt32()
                // chats are complex — skip by reading each (best-effort)
                var ci: Int32 = 0
                while (ci < chatsCount) {
                    skipChatObject(d)
                    ci += 1
                }
                // users vector
                let _ = d.readUInt32()
                let usersCount = d.readInt32()
                var ui: Int32 = 0
                while (ui < usersCount) {
                    let userResp = UserResponse.deserializeBoxed(d)
                    for (admin in result) {
                        if (admin.userId == userResp.id) {
                            admin.firstName = userResp.firstName
                            admin.lastName = userResp.lastName
                            admin.userAccessHash = userResp.accessHash
                        }
                    }
                    ui += 1
                }
            } catch (_: Exception) {
                // user name resolution is best-effort; continue with partial data
            }
            Hilog.info(0, "CjTelegram", "[TCPDM] fetched ${result.size} admins for peerId=${peerId}")
        } else {
            Hilog.info(0, "CjTelegram", "[TCPDM] unexpected constructor for peerId=${peerId}")
        }

        return result
    }

    /**
     * 解析单个 ChannelParticipant（admin 或 creator）
     */
    private func parseParticipant(d: TLDeserializer): AdminMemberData {
        let admin = AdminMemberData()
        let ctor = d.readUInt32()

        // channelParticipantAdmin#34c3bb53
        if (ctor == 0x34c3bb53) {
            let flags = d.readInt32()
            admin.canEdit = (flags & 1) != 0
            admin.userId = d.readInt64()
            if ((flags & 2) != 0) { let _ = d.readInt64() }  // inviter_id optional
            admin.promotedBy = d.readInt64()
            admin.date = d.readInt32()
            let _ = d.readUInt32()  // ChatAdminRights constructor
            admin.adminFlags = d.readInt32()
            if ((flags & 4) != 0) { admin.rank = d.readString() }
            return admin
        }

        // channelParticipantCreator#2fe601d3
        if (ctor == 0x2fe601d3) {
            let flags = d.readInt32()
            admin.userId = d.readInt64()
            let _ = d.readUInt32()  // ChatAdminRights constructor
            admin.adminFlags = d.readInt32()
            if ((flags & 1) != 0) { admin.rank = d.readString() }
            admin.isCreator = true
            admin.canEdit = false
            return admin
        }

        // Unknown type: return empty entry (userId=0 → will be filtered out)
        return admin
    }

    /**
     * 跳过一个 Chat 对象（best-effort，用于解析 users 之前越过 chats vector）
     */
    private func skipChatObject(d: TLDeserializer): Unit {
        let chatCtor = d.readUInt32()
        // chat#41cbf256 or chat#38af6782 or channel#83259464 etc — structure varies
        // safe approach: we just try to read minimal fields; if it fails, exception is caught upstream
        if (chatCtor == 0x41cbf256 || chatCtor == 0x38af6782) {
            // chat: flags, id, title, photo(boxed), participants_count, date, version, ...
            let flags = d.readInt32()
            let _ = d.readInt64()  // id
            let _ = d.readString()  // title
            skipChatPhoto(d)
            let _ = d.readInt32()  // participants_count
            let _ = d.readInt32()  // date
            let _ = d.readInt32()  // version
            if ((flags & 512) != 0) { let _ = d.readInt64() }  // migrated_to optional
            if ((flags & 16384) != 0) { let _ = d.readString() }  // admin_title
        } else {
            // channel or other: skip by aborting best-effort (throw to caller's catch)
            // We cannot safely skip unknown structures; surrender gracefully
        }
    }

    /** Skip a ChatPhoto (boxed: chatPhotoEmpty or chatPhoto) */
    private func skipChatPhoto(d: TLDeserializer): Unit {
        let ctor = d.readUInt32()
        if (ctor == 0x37c1011c) {
            // chatPhotoEmpty — no fields
        } else if (ctor == 0x1c6e1c11) {
            // chatPhoto: flags, photo_id, stripped_thumb?, dc_id
            let flags = d.readInt32()
            let _ = d.readInt64()  // photo_id
            if ((flags & 1) != 0) { skipBytes(d) }  // stripped_thumb optional
            let _ = d.readInt32()  // dc_id
        }
        // other variants: silently drop, caller's catch handles it
    }

    /** Skip a length-prefixed bytes field */
    private func skipBytes(d: TLDeserializer): Unit {
        let _ = d.readBytes()
    }

    /** Current time in milliseconds */
    private func getNowMs(): Int64 {
        return DateTime.now().toUnixTimeStamp().toMilliseconds()
    }
}
