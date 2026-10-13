package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.core.storage.postbox.*
import std.collection.ArrayList

/**
 * PeerStore —— peer 提供方（联系人 / full-user 等）与本地 Postbox PeerTable 之间的桥接层。
 *
 * 单元 P2-289b：让网络拿到的 User/Chat（peer）落本地 PeerTable，并提供"本地优先" getLocalPeer /
 * getLocalUser —— 离线 / 未加载时，UI 仍能从本地拿到 peer 的名字 / 头像文字 / 用户名。
 *
 * 对照 iOS local-first 语义（Telegram-iOS Postbox：peer 先入库、视图优先从 Postbox 读、
 * 网络回源再回填），与本工程 ChatListStore.cj / MessageHistoryStore.cj 同一范式（强约束照搬）：
 *   - ensureDbOpen()：globalAbilityContext 懒开 + 降级（不破坏既有可运行性）；
 *   - cache* 写库 / getLocal* 本地优先读；
 *   - try/catch 兜底，闭包只捕获 let；
 *   - DB 不可用 → cache no-op、getLocal 返 None / 空，绝不崩。
 *
 * DB open 容错（最高优先）：
 *   工程当前未在启动期 open PostboxDatabase（main_ability 不 open postbox.db），
 *   故本类首次用到时 lazy open（用 getGlobalAbilityContext() 拿 UIAbilityContext）。
 *   拿不到 context 或 open 抛异常时，所有本地操作安全降级——调用方按原网络路径继续，绝不崩。
 *
 * MTProto 说明（N/A）：本地持久化桥接，不直接发起 MTProto 请求；输入是上游已 parse 的
 *   User/Chat/UserResponse 模型对象。
 */
public class PeerStore {
    private let peerTable: PeerTable

    public init() {
        this.peerTable = PeerTable()
    }

    /**
     * 确保 PostboxDatabase 已 open。
     *
     * 已 open → true。未 open → 尝试用 getGlobalAbilityContext() 拿到的 UIAbilityContext
     * lazy open；context 不可用或 open 抛异常 → false（安全降级）。
     *
     * 与 ChatListStore.ensureDbOpen / MessageHistoryStore.ensureDbOpen 完全同范式
     * （同一 globalAbilityContext + 同一单例 DB）。
     */
    private func ensureDbOpen(): Bool {
        let db = PostboxDatabase.getInstance()
        if (db.isOpen()) {
            return true
        }
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    db.open(ctx)
                    return db.isOpen()
                } catch (e: Exception) {
                    Hilog.error(0, "CjTelegram", "[PeerStore] lazy open failed: ${e}")
                    return false
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[PeerStore] no ability context, degrade to network")
                return false
        }
    }

    // ==================== 写入：peer 落本地表 ====================

    /**
     * 把一个 models.User 落本地 PeerTable（INSERT OR REPLACE 语义，同 peerId 覆盖）。
     * DB 不可用时静默 no-op（不抛、不崩）。
     */
    public func cacheUser(user: User): Unit {
        if (user.id == 0) {
            return
        }
        if (!this.ensureDbOpen()) {
            return
        }
        try {
            this.peerTable.setPeer(IntermediatePeer.fromUser(user))
            Hilog.info(0, "CjTelegram", "[PeerStore] cached user peer id=${user.id}")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[PeerStore] cacheUser failed: ${e}")
        }
    }

    /**
     * 把一个 models.Chat（群 / 频道 / 超级群）落本地 PeerTable。
     * DB 不可用时静默 no-op。
     */
    public func cacheChat(chat: Chat): Unit {
        if (chat.id == 0) {
            return
        }
        if (!this.ensureDbOpen()) {
            return
        }
        try {
            let peerType = if (chat.isChannel) {
                PeerKey.CHANNEL
            } else if (chat.isGroup || chat.isMegagroup) {
                PeerKey.BASIC_GROUP
            } else {
                chat.peerType
            }
            let storageId = PeerKey.fromPeerType(peerType, chat.id).storageId()
            let peer = IntermediatePeer.fromChat(chat)
            // models.Chat 不带 access_hash：覆盖写时保留已落库的那份（见 cacheChannelAccessHash）。
            match (this.peerTable.getPeerAtStorageId(storageId)) {
                case Some(existing) => peer.accessHash = existing.accessHash
                case None => ()
            }
            this.peerTable.setPeerAtStorageId(storageId, peer)
            Hilog.info(0, "CjTelegram", "[PeerStore] cached chat peer id=${chat.id}")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[PeerStore] cacheChat failed: ${e}")
        }
    }

    /**
     * 批量把 models.User 列表落库（一次 ensureDbOpen，循环 setPeer）。
     * DB 不可用时整批 no-op。空入参直接返回。
     */
    public func cachePeers(users: Array<User>): Unit {
        if (users.size == 0) {
            return
        }
        if (!this.ensureDbOpen()) {
            return
        }
        try {
            var n: Int64 = 0
            for (u in users) {
                if (u.id == 0) {
                    continue
                }
                this.peerTable.setPeer(IntermediatePeer.fromUser(u))
                n += 1
            }
            Hilog.info(0, "CjTelegram", "[PeerStore] cached ${n} user peers (batch)")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[PeerStore] cachePeers failed: ${e}")
        }
    }

    /**
     * 便捷写入：网络层（RealContactService / PeerInfoService 等）拿到的是 mtproto 的
     * UserResponse，而非 models.User。本方法把 UserResponse 归一成 IntermediatePeer 后落库，
     * 让 peer 提供方无需自己手搓 models.User 即可接入本地表。
     *
     * displayName / avatarText 取值与 RealContactService / RealChatListService 的既有约定一致
     * （displayName = firstName[ +" "+ lastName ]，回退 @username / "User id"；
     *  avatarText 取 firstName 首字符，回退 "U"）。
     *
     * DB 不可用时静默 no-op。空 / userEmpty / id==0 跳过。
     */
    public func cacheUserResponse(u: UserResponse): Unit {
        if (u.id == 0 || u.isEmpty) {
            return
        }
        if (!this.ensureDbOpen()) {
            return
        }
        try {
            this.peerTable.setPeer(PeerStore.peerFromUserResponse(u))
            Hilog.info(0, "CjTelegram", "[PeerStore] cached UserResponse peer id=${u.id}")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[PeerStore] cacheUserResponse failed: ${e}")
        }
    }

    /**
     * 批量落库 UserResponse 列表（一次 ensureDbOpen，循环 setPeer）。
     * DB 不可用 / 空入参时整批 no-op。
     */
    public func cacheUserResponses(users: ArrayList<UserResponse>): Unit {
        if (users.isEmpty()) {
            return
        }
        if (!this.ensureDbOpen()) {
            return
        }
        try {
            var n: Int64 = 0
            for (u in users) {
                if (u.id == 0 || u.isEmpty) {
                    continue
                }
                this.peerTable.setPeer(PeerStore.peerFromUserResponse(u))
                n += 1
            }
            Hilog.info(0, "CjTelegram", "[PeerStore] cached ${n} UserResponse peers (batch)")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[PeerStore] cacheUserResponses failed: ${e}")
        }
    }

    /**
     * UserResponse -> IntermediatePeer。
     * 把 mtproto 层字段归一成本地 peer 落盘项；显示字段约定与服务层既有逻辑对齐。
     */
    private static func peerFromUserResponse(u: UserResponse): IntermediatePeer {
        let name = PeerStore.displayNameOf(u)
        let avatarText = if (u.firstName.size > 0) {
            u.firstName.toRuneArray()[0].toString()
        } else if (name.size > 0) {
            name.toRuneArray()[0].toString()
        } else {
            "U"
        }
        return IntermediatePeer(
            id: u.id,
            name: name,
            username: u.username,
            avatarText: avatarText,
            avatarLocalPath: "",
            phone: u.phone,
            isContact: u.isContact,
            isBot: u.isBot,
            peerType: IntermediatePeer.TYPE_USER
        )
    }

    /**
     * 由 UserResponse 计算展示名（与 ContactDisplayData.getDisplayName / ItemListPeerService 对齐）。
     */
    private static func displayNameOf(u: UserResponse): String {
        var name = u.firstName
        if (u.lastName.size > 0) {
            if (name.size > 0) {
                name = name + " " + u.lastName
            } else {
                name = u.lastName
            }
        }
        if (name.isEmpty()) {
            if (u.username.size > 0) {
                return "@" + u.username
            }
            return "User ${u.id}"
        }
        return name
    }

    /**
     * channel access_hash 落本地 peer（iOS TelegramChannel.accessHash 随 peer 存 Postbox）。
     * 进程重启后内存缓存为空、会话列表先由本地秒开，此时发消息 / 取成员要靠这份才能拼出
     * inputPeerChannel / inputChannel，否则服务端回 CHANNEL_INVALID。值未变时不写库。
     */
    public func cacheChannelAccessHash(channelId: Int64, accessHash: Int64): Unit {
        if (channelId == 0 || accessHash == 0) {
            return
        }
        if (!this.ensureDbOpen()) {
            return
        }
        try {
            let storageId = PeerKey.fromPeerType(PeerKey.CHANNEL, channelId).storageId()
            let peer = match (this.peerTable.getPeerAtStorageId(storageId)) {
                case Some(existing) =>
                    if (existing.accessHash == accessHash) { return }
                    existing
                case None => IntermediatePeer(id: channelId, peerType: IntermediatePeer.TYPE_CHANNEL)
            }
            peer.accessHash = accessHash
            this.peerTable.setPeerAtStorageId(storageId, peer)
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[PeerStore] cacheChannelAccessHash failed: ${e}")
        }
    }

    /** 本地落库的 channel access_hash；DB 不可用 / 未命中 → 0。 */
    public func getChannelAccessHash(channelId: Int64): Int64 {
        match (this.getLocalPeer(channelId, peerType: PeerKey.CHANNEL)) {
            case Some(peer) => return peer.accessHash
            case None => return 0
        }
    }

    // ==================== 本地优先读 ====================

    /**
     * 本地优先读：按 peerId 取本地 peer（命中即可离线返回）。
     * DB 不可用 / 异常 / 未命中 → None（调用方回退网络）。
     */
    public func getLocalPeer(peerId: Int64, peerType!: String = "user"): Option<IntermediatePeer> {
        if (!this.ensureDbOpen()) {
            return None
        }
        try {
            let storageId = PeerKey.fromPeerType(peerType, peerId).storageId()
            return this.peerTable.getPeerAtStorageId(storageId)
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[PeerStore] getLocalPeer failed: ${e}")
            return None
        }
    }

    /**
     * 本地优先读：按 peerId 取本地 peer 并回填成 models.User（供 UI 在离线 / 未加载时拿到
     * peer 名字 / 头像文字 / 用户名）。
     * DB 不可用 / 异常 / 未命中 → None（调用方回退网络）。
     */
    public func getLocalUser(peerId: Int64): Option<User> {
        match (this.getLocalPeer(peerId)) {
            case Some(peer) => return Some(peer.toUser())
            case None => return None
        }
    }
}

// ==================== 单例访问器 ====================

private var _peerStoreInstance: Option<PeerStore> = None

public func getPeerStore(): PeerStore {
    match (_peerStoreInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PeerStore()
            _peerStoreInstance = Some(inst)
            return inst
    }
}
