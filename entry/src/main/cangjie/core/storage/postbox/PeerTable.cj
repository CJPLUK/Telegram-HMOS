package ohos_app_cangjie_entry.core.storage.postbox

import std.collection.ArrayList
import ohos_app_cangjie_entry.models.User
import ohos_app_cangjie_entry.models.Chat

/**
 * PeerTable —— peer/用户表（离线 peer 信息的存储核心）。
 *
 * iOS 标尺：
 *   - Telegram-iOS/submodules/Postbox/Sources/PeerTable.swift
 *       `tableSpec(id) = ValueBoxTable(id: id, keyType: .int64)` —— 键是 int64 的 peerId
 *       （`key(id) = ValueBoxKey(length: 8).setInt64(0, id.toInt64())`）；
 *       值 = peer 对象的 PostboxEncoder 序列化字节。set/get 以 peerId 为键存取 Peer。
 *   - Telegram-iOS/submodules/Postbox/Sources/ContactTable.swift
 *       isContact(peerId) —— 联系人标记由独立 ContactTable 维护；本工程模型未拆独立联系人表，
 *       故把 isContact 作为 IntermediatePeer 的一个落盘标志位（最小面，避免再引一张表）。
 *
 * 键类型选择（与 iOS 严格对齐）：iOS PeerTable 用 `.int64` 键（INTEGER 主键，省存储、整型主键
 *   rowid 对齐），键由 `ValueBoxKey(length: 8).setInt64(0, peerId)` 构造。本类同样选 Int64Key 表
 *   （TableRegistry.PEER_TABLE_ID = 103）。底层 RdbValueBox 对 Int64Key 表的 bindKey 走
 *   `RelationalStoreValueType.Integer(key.getInt64(0))`、readKey 走 `getLong -> setInt64`，
 *   与本类 8 字节大端键 round-trip 对称（见 RdbValueBox.bindKey/readKey）。
 *
 * 本单元建在已合入 master 的 DB 底座之上：
 *   - ValueBox.cj / RdbValueBox.cj —— ValueBoxTable、get/set/remove/scan（KV 引擎）。
 *   - ValueBoxKey.cj               —— 8 字节大端键 setInt64/getInt64。
 *   - PostboxCoding.cj             —— PostboxEncoder / PostboxDecoder（字段级标量编解码）。
 *   - models/User.cj / models/Chat.cj —— 工程内 peer 模型（peer 既可能来自 User 也可能来自 Chat）。
 *
 * 表封装范式严格复用 ChatListTable.cj / MessageHistoryTable.cj：持有 ValueBoxTable(id) + ValueBox，
 *   encode value 落库、scan 收集进一个 `let` ArrayList（引用被闭包捕获、内容可变；KB「闭包不得
 *   捕获本地 var」约束下的标准范式）、selfCheck 往返验证。
 *
 * 范围说明：本单元只做 set/get/remove/getAll 四件核心存储操作（建在 ValueBox 上）+ User/Chat 双向
 *   转换。reverse-associated / peer-timeout / cache 层 / 联系人独立表等是后续单元职责，本文件不碰。
 *
 * MTProto 说明（N/A）：本地持久化 peer 表，不涉及 MTProto 协议。
 */

/**
 * 落盘 peer 模型 —— peer 信息的持久化核心字段子集。
 *
 * peer 既可能来自 User（私聊对端 / 联系人），也可能来自 Chat（群 / 频道 / 超级群）。
 * `peerType` 字段区分来源类型（"user" / "group" / "channel" / "megagroup"），
 * 决定 toUser() / toChat() 的回填语义。
 *
 * 用 class（与 models/User.cj、models/Chat.cj 的纯数据类风格一致；落盘项需可变字段聚合）。
 * encode(PostboxEncoder) / static decode(PostboxDecoder) 与底座编解码层对称；可空字段
 * 用空串语义，decode 时旧库无对应 key 回落空串/默认值（向后兼容）。
 */
public class IntermediatePeer {
    // 主键：peerId（既是 User.id 也是 Chat.id）。
    public var id: Int64
    // 展示名（User.displayName / Chat.name）。
    public var name: String
    // 用户名 / 频道名（User.username / Chat.username）。
    public var username: String
    // 头像占位文字（User.avatarText / Chat.avatarText）。
    public var avatarText: String
    // 真实头像本地路径（User.avatarUrl 落 user 路径；Chat.avatarLocalPath 落 chat 路径）。
    public var avatarLocalPath: String
    // 电话号（仅 User 有；Chat 无 -> 空串）。
    public var phone: String
    // 头像底色（User.avatarColor / Chat.avatarColor）。
    public var avatarColor: Int64
    // 联系人标记（对应 iOS ContactTable.isContact；Chat 无 -> false）。
    public var isContact: Bool
    // bot 标记（当前 User/Chat 模型均无显式 bot 字段 -> 默认 false，预留位，按需由上层置入）。
    public var isBot: Bool
    // 已验证标记（当前模型均无显式 verified 字段 -> 默认 false，预留位）。
    public var isVerified: Bool
    // peer 类型区分："user" / "group" / "channel" / "megagroup"。
    public var peerType: String
    // channel access_hash。iOS TelegramChannel 把 accessHash 随 peer 存进 Postbox（编码键 "ah"），
    // 冷启动后本地会话列表一点开就能拼出 inputPeerChannel；0 = 未知。
    public var accessHash: Int64 = 0

    // ---- peerType 取值常量 ----
    public static let TYPE_USER: String = "user"
    public static let TYPE_GROUP: String = "group"
    public static let TYPE_CHANNEL: String = "channel"
    public static let TYPE_MEGAGROUP: String = "megagroup"

    public init(
        id!: Int64,
        name!: String = "",
        username!: String = "",
        avatarText!: String = "",
        avatarLocalPath!: String = "",
        phone!: String = "",
        avatarColor!: Int64 = 0x317AFF,
        isContact!: Bool = false,
        isBot!: Bool = false,
        isVerified!: Bool = false,
        peerType!: String = IntermediatePeer.TYPE_USER
    ) {
        this.id = id
        this.name = name
        this.username = username
        this.avatarText = avatarText
        this.avatarLocalPath = avatarLocalPath
        this.phone = phone
        this.avatarColor = avatarColor
        this.isContact = isContact
        this.isBot = isBot
        this.isVerified = isVerified
        this.peerType = peerType
    }

    public func isUser(): Bool {
        return this.peerType == IntermediatePeer.TYPE_USER
    }

    /**
     * 编码到 PostboxEncoder（字段级标量编解码，对应 iOS peer encode）。
     * 字段 key 用短稳定串，与 decode 对称。
     */
    public func encode(encoder: PostboxEncoder): Unit {
        encoder.encodeInt64(this.id, key: "id")
        encoder.encodeString(this.name, key: "nm")
        encoder.encodeString(this.username, key: "un")
        encoder.encodeString(this.avatarText, key: "at")
        encoder.encodeString(this.avatarLocalPath, key: "ap")
        encoder.encodeString(this.phone, key: "ph")
        encoder.encodeInt64(this.avatarColor, key: "ac")
        encoder.encodeBool(this.isContact, key: "ct")
        encoder.encodeBool(this.isBot, key: "bt")
        encoder.encodeBool(this.isVerified, key: "vf")
        encoder.encodeString(this.peerType, key: "pt")
        encoder.encodeInt64(this.accessHash, key: "ah")
    }

    /**
     * 从 PostboxDecoder 还原（与 encode 严格对称）。
     * 可空字段 decode 回落 orElse（空串 / 默认值），向后兼容旧库。
     */
    public static func decode(decoder: PostboxDecoder): IntermediatePeer {
        let id = decoder.decodeInt64("id", orElse: 0)
        let name = decoder.decodeString("nm", orElse: "")
        let username = decoder.decodeString("un", orElse: "")
        let avatarText = decoder.decodeString("at", orElse: "")
        let avatarLocalPath = decoder.decodeString("ap", orElse: "")
        let phone = decoder.decodeString("ph", orElse: "")
        let avatarColor = decoder.decodeInt64("ac", orElse: 0x317AFF)
        let isContact = decoder.decodeBool("ct", orElse: false)
        let isBot = decoder.decodeBool("bt", orElse: false)
        let isVerified = decoder.decodeBool("vf", orElse: false)
        let peerType = decoder.decodeString("pt", orElse: IntermediatePeer.TYPE_USER)
        let peer = IntermediatePeer(
            id: id,
            name: name,
            username: username,
            avatarText: avatarText,
            avatarLocalPath: avatarLocalPath,
            phone: phone,
            avatarColor: avatarColor,
            isContact: isContact,
            isBot: isBot,
            isVerified: isVerified,
            peerType: peerType
        )
        peer.accessHash = decoder.decodeInt64("ah", orElse: 0)
        return peer
    }

    /**
     * 便捷 round-trip：通过临时 encoder/decoder 自编自解（自检与落盘路径复用）。
     */
    public func encodedBytes(): Array<Byte> {
        let encoder = PostboxEncoder()
        this.encode(encoder)
        return encoder.makeBytes()
    }

    public static func decodeFromBytes(data: Array<Byte>): IntermediatePeer {
        return IntermediatePeer.decode(PostboxDecoder(data))
    }

    // ---- User <-> IntermediatePeer 双向转换 ----

    /**
     * User -> IntermediatePeer。peerType 固定 "user"。
     *   - id              <- user.id
     *   - name            <- user.displayName
     *   - username        <- user.username
     *   - avatarText      <- user.avatarText
     *   - avatarLocalPath <- user.avatarUrl（User 模型用 avatarUrl 承载本地/远端头像路径）
     *   - phone           <- user.phoneNumber
     *   - avatarColor     <- user.avatarColor
     * User 模型无 isContact / isBot / isVerified 字段，故取默认（false）；上层若已知可在转换后置位。
     */
    public static func fromUser(u: User): IntermediatePeer {
        return IntermediatePeer(
            id: u.id,
            name: u.displayName,
            username: u.username,
            avatarText: u.avatarText,
            avatarLocalPath: u.avatarUrl,
            phone: u.phoneNumber,
            avatarColor: u.avatarColor,
            isContact: false,
            isBot: false,
            isVerified: false,
            peerType: IntermediatePeer.TYPE_USER
        )
    }

    /**
     * IntermediatePeer -> User（只回填本落盘项承载的核心字段；其余 User 字段保持默认）。
     */
    public func toUser(): User {
        let user = User()
        user.id = this.id
        user.displayName = this.name
        user.username = this.username
        user.avatarText = this.avatarText
        user.avatarUrl = this.avatarLocalPath
        user.phoneNumber = this.phone
        user.avatarColor = this.avatarColor
        return user
    }

    // ---- Chat <-> IntermediatePeer 双向转换 ----

    /**
     * Chat -> IntermediatePeer。peerType 由 Chat 的 isChannel/isMegagroup/isGroup 推导：
     *   isChannel && !isMegagroup -> "channel"；isMegagroup -> "megagroup"；isGroup -> "group"；
     *   否则 "user"（私聊）。
     *   - id              <- chat.id
     *   - name            <- chat.name
     *   - username        <- chat.username
     *   - avatarText      <- chat.avatarText
     *   - avatarLocalPath <- chat.avatarLocalPath
     *   - avatarColor     <- chat.avatarColor
     * Chat 模型无 phone / isContact / isBot / isVerified -> 取默认。
     */
    public static func fromChat(c: Chat): IntermediatePeer {
        let resolvedType = IntermediatePeer.peerTypeOfChat(c)
        return IntermediatePeer(
            id: c.id,
            name: c.name,
            username: c.username,
            avatarText: c.avatarText,
            avatarLocalPath: c.avatarLocalPath,
            phone: "",
            avatarColor: c.avatarColor,
            isContact: false,
            isBot: false,
            isVerified: false,
            peerType: resolvedType
        )
    }

    /**
     * 由 Chat 的频道/群标记推导 peerType（fromChat 复用）。
     */
    private static func peerTypeOfChat(c: Chat): String {
        if (c.isChannel && !c.isMegagroup) {
            return IntermediatePeer.TYPE_CHANNEL
        }
        if (c.isMegagroup) {
            return IntermediatePeer.TYPE_MEGAGROUP
        }
        if (c.isGroup) {
            return IntermediatePeer.TYPE_GROUP
        }
        return IntermediatePeer.TYPE_USER
    }

    /**
     * IntermediatePeer -> Chat（只回填本落盘项承载的核心字段 + 由 peerType 还原频道/群标记）。
     * 其余 Chat 字段保持默认。
     */
    public func toChat(): Chat {
        let chat = Chat()
        chat.id = this.id
        chat.name = this.name
        chat.username = this.username
        chat.avatarText = this.avatarText
        chat.avatarLocalPath = this.avatarLocalPath
        chat.avatarColor = this.avatarColor
        chat.peerType = this.peerType
        // 由 peerType 还原频道/群标记（与 fromChat.peerTypeOfChat 对称）。
        if (this.peerType == IntermediatePeer.TYPE_CHANNEL) {
            chat.isChannel = true
        } else if (this.peerType == IntermediatePeer.TYPE_MEGAGROUP) {
            chat.isChannel = true
            chat.isMegagroup = true
            chat.isGroup = true
        } else if (this.peerType == IntermediatePeer.TYPE_GROUP) {
            chat.isGroup = true
        }
        return chat
    }
}

/**
 * PeerTable —— peer 表（持有 ValueBoxTable(PEER_TABLE_ID, Int64Key) + ValueBox）。
 *
 * 键 = peerId 的 8 字节大端 ValueBoxKey（Int64Key 表，底层走 INTEGER 主键）。
 * 值 = IntermediatePeer 的 PostboxEncoder 编码字节。
 */
public class PeerTable {
    // 本表的逻辑描述符：int64 键（peerId），值是 BLOB。
    private let table: ValueBoxTable
    // 底层通用 KV 引擎（复用进程内单例，与 PostboxDatabase 同一 RDB 连接）。
    private let valueBox: ValueBox

    /**
     * 用进程内单例 ValueBox（RdbValueBox）构造（推荐路径）。
     * 表描述符固定为 (PEER_TABLE_ID, Int64Key)。
     */
    public init() {
        this.table = ValueBoxTable(
            id: TableRegistry.PEER_TABLE_ID,
            keyType: ValueBoxKeyType.Int64Key
        )
        this.valueBox = RdbValueBox.getInstance()
    }

    /**
     * 注入式构造（测试 / 自定义 ValueBox 实现时使用）。
     */
    public init(valueBox: ValueBox) {
        this.table = ValueBoxTable(
            id: TableRegistry.PEER_TABLE_ID,
            keyType: ValueBoxKeyType.Int64Key
        )
        this.valueBox = valueBox
    }

    /**
     * 把 peerId 编码成 8 字节大端键（对应 iOS PeerTable.key(_:)：
     *   `ValueBoxKey(length: 8).setInt64(0, peerId)`）。
     */
    private static func keyForPeer(peerId: Int64): ValueBoxKey {
        let k = ValueBoxKey(length: 8)
        k.setInt64(0, peerId)
        return k
    }

    /**
     * 把一条 IntermediatePeer 编码成落库值字节：
     *   new PostboxEncoder -> peer.encode(encoder) -> encoder.makeBytes()。
     */
    private static func encodeValue(peer: IntermediatePeer): Array<Byte> {
        let encoder = PostboxEncoder()
        peer.encode(encoder)
        return encoder.makeBytes()
    }

    /**
     * 把落库值字节解码回 IntermediatePeer。
     */
    private static func decodeValue(bytes: Array<Byte>): IntermediatePeer {
        return IntermediatePeer.decode(PostboxDecoder(bytes))
    }

    /**
     * 写入 / 覆盖一条 peer（对应 iOS PeerTable.set + beforeCommit 落库）。
     * 键 = keyForPeer(peer.id)；值 = encode(peer)。INSERT OR REPLACE 语义：同 peerId 覆盖。
     */
    public func setPeer(peer: IntermediatePeer): Unit {
        let key = PeerTable.keyForPeer(peer.id)
        let value = PeerTable.encodeValue(peer)
        this.valueBox.set(this.table, key, value)
    }

    /** 值保留协议原始 id，物理键可使用 PeerKey 编码后的 storageId。 */
    public func setPeerAtStorageId(storageId: Int64, peer: IntermediatePeer): Unit {
        let key = PeerTable.keyForPeer(storageId)
        let value = PeerTable.encodeValue(peer)
        this.valueBox.set(this.table, key, value)
    }

    /**
     * 按 peerId 取单条 peer（对应 iOS PeerTable.get）。
     * 命中：valueBox.get -> 字节 -> decode -> Some；未命中：None。
     */
    public func getPeer(peerId: Int64): Option<IntermediatePeer> {
        let key = PeerTable.keyForPeer(peerId)
        match (this.valueBox.get(this.table, key)) {
            case Some(bytes) => return Some(PeerTable.decodeValue(bytes))
            case None => return None
        }
    }

    public func getPeerAtStorageId(storageId: Int64): Option<IntermediatePeer> {
        let key = PeerTable.keyForPeer(storageId)
        match (this.valueBox.get(this.table, key)) {
            case Some(bytes) => return Some(PeerTable.decodeValue(bytes))
            case None => return None
        }
    }

    /**
     * 按 peerId 删除单条 peer（对应 iOS remove）。不存在的键 remove 无副作用。
     */
    public func removePeer(peerId: Int64): Unit {
        this.valueBox.remove(this.table, PeerTable.keyForPeer(peerId))
    }

    /**
     * 单条 peer 是否存在。
     */
    public func containsPeer(peerId: Int64): Bool {
        return this.valueBox.exists(this.table, PeerTable.keyForPeer(peerId))
    }

    /**
     * 取全部 peer（对应 iOS 遍历 PeerTable）。走 valueBox.scan（升序全表扫描，对 Int64Key 表
     * 按 INTEGER 主键升序）；limit > 0 时取前 limit 条后早停（回调返回 false），limit <= 0 不限。
     *
     * 收集范式：结果收进一个 `let` ArrayList（引用被闭包捕获、内容可变；KB「闭包不得捕获本地 var」
     * 约束下的标准范式，与 ChatListTable.listChats / MessageHistoryTable.messagesForPeer 一致）。
     * 早停计数同样用一个 `let` ArrayList<Int64> 承载可变计数（避免闭包捕获本地 var）。
     */
    public func getAllPeers(limit: Int64): Array<IntermediatePeer> {
        let collected = ArrayList<IntermediatePeer>()
        // 计数器载体：用一个单元素 ArrayList 承载已收集条数，闭包改其内容（引用不变）。
        let counter = ArrayList<Int64>()
        counter.add(0)
        this.valueBox.scan(this.table, { _, v =>
            collected.add(PeerTable.decodeValue(v))
            counter[0] = counter[0] + 1
            if (limit > 0 && counter[0] >= limit) {
                return false  // 达到 limit 早停
            }
            return true
        })
        return PeerTable.toArray(collected)
    }

    /**
     * 收集容器 ArrayList 物化成 Array（保持原顺序）。与 ChatListTable.toArray 同范式
     * （Array 固定长度构造需元素工厂，用一个占位项填充后逐位覆盖）。
     */
    private static func toArray(list: ArrayList<IntermediatePeer>): Array<IntermediatePeer> {
        let n = list.size
        let arr = Array<IntermediatePeer>(n, { _ => PeerTable.seedPeer() })
        for (i in 0..n) {
            arr[i] = list[i]
        }
        return arr
    }

    /**
     * Array 固定长度构造所需的种子元素（随即被逐位覆盖，不参与逻辑）。
     */
    private static func seedPeer(): IntermediatePeer {
        return IntermediatePeer(id: 0)
    }

    /**
     * 自检（验收项②③）：需要一个「已 open 的 PostboxDatabase（真实 RDB）」，
     * 因此只在设备 / 集成诊断时显式调用，不在 app 主流程自动运行
     * （与 ChatListTable.selfCheck / MessageHistoryTable.selfCheck 的定位一致）。
     *
     * 验证：
     *   ② setPeer -> getPeer 往返字段相等（user 路 + chat 路两种）；removePeer 后 getPeer 返 None；
     *   ③ getAllPeers 取回全部（且 limit 截断生效）。
     * 全部断言通过返回 true，任一不符返回 false。
     */
    public func selfCheck(): Bool {
        // ===== user 路：User -> fromUser -> setPeer -> getPeer -> toUser 字段相等 =====
        let user = User()
        user.id = 10001
        user.displayName = "Alice 世界"
        user.username = "alice"
        user.avatarText = "A"
        user.avatarUrl = "/data/av/alice.png"
        user.phoneNumber = "+1234567890"
        user.avatarColor = 0x112233
        let userPeer = IntermediatePeer.fromUser(user)

        // ===== chat 路：Chat(channel) -> fromChat -> setPeer -> getPeer -> toChat 字段相等 =====
        let chat = Chat()
        chat.id = 20002
        chat.name = "Cangjie Channel"
        chat.username = "cjchannel"
        chat.avatarText = "C"
        chat.avatarLocalPath = "/data/av/chan.png"
        chat.avatarColor = 0x445566
        chat.isChannel = true
        chat.isMegagroup = false
        let chatPeer = IntermediatePeer.fromChat(chat)

        // chat 路 2：megagroup
        let mega = Chat()
        mega.id = 30003
        mega.name = "Mega Group"
        mega.isMegagroup = true
        mega.isChannel = true
        mega.isGroup = true
        let megaPeer = IntermediatePeer.fromChat(mega)

        let allPeers = [userPeer, chatPeer, megaPeer]

        // 清场：先删全部（避免上一轮残留）
        for (p in allPeers) {
            this.removePeer(p.id)
        }

        // ② setPeer -> getPeer 往返（user 路）
        this.setPeer(userPeer)
        match (this.getPeer(10001)) {
            case Some(got) =>
                if (got.id != 10001) { return false }
                if (got.name != "Alice 世界") { return false }
                if (got.username != "alice") { return false }
                if (got.avatarText != "A") { return false }
                if (got.avatarLocalPath != "/data/av/alice.png") { return false }
                if (got.phone != "+1234567890") { return false }
                if (got.avatarColor != 0x112233) { return false }
                if (got.peerType != IntermediatePeer.TYPE_USER) { return false }
                // toUser 回填字段相等
                let backUser = got.toUser()
                if (backUser.id != user.id) { return false }
                if (backUser.displayName != user.displayName) { return false }
                if (backUser.username != user.username) { return false }
                if (backUser.avatarText != user.avatarText) { return false }
                if (backUser.avatarUrl != user.avatarUrl) { return false }
                if (backUser.phoneNumber != user.phoneNumber) { return false }
                if (backUser.avatarColor != user.avatarColor) { return false }
            case None => return false
        }

        // ② setPeer -> getPeer 往返（chat 路：channel）
        this.setPeer(chatPeer)
        match (this.getPeer(20002)) {
            case Some(got) =>
                if (got.id != 20002 || got.name != "Cangjie Channel") { return false }
                if (got.username != "cjchannel") { return false }
                if (got.peerType != IntermediatePeer.TYPE_CHANNEL) { return false }
                let backChat = got.toChat()
                if (backChat.id != chat.id) { return false }
                if (backChat.name != chat.name) { return false }
                if (backChat.username != chat.username) { return false }
                if (backChat.avatarText != chat.avatarText) { return false }
                if (backChat.avatarLocalPath != chat.avatarLocalPath) { return false }
                if (backChat.avatarColor != chat.avatarColor) { return false }
                if (!backChat.isChannel) { return false }
                if (backChat.isMegagroup) { return false }
            case None => return false
        }

        // ② setPeer -> getPeer 往返（chat 路：megagroup -> peerType 推导）
        this.setPeer(megaPeer)
        match (this.getPeer(30003)) {
            case Some(got) =>
                if (got.peerType != IntermediatePeer.TYPE_MEGAGROUP) { return false }
                let backMega = got.toChat()
                if (!backMega.isMegagroup) { return false }
                if (!backMega.isChannel) { return false }
                if (!backMega.isGroup) { return false }
            case None => return false
        }

        // 不存在的 peerId 返 None
        match (this.getPeer(999999)) {
            case Some(_) => return false
            case None => ()
        }

        // ③ getAllPeers 取回全部 3 条
        let all = this.getAllPeers(0)
        if (all.size != 3) { return false }
        // 必须包含 3 个 peerId（顺序由 INTEGER 主键升序：10001, 20002, 30003）
        if (all[0].id != 10001 || all[1].id != 20002 || all[2].id != 30003) { return false }

        // limit 截断：取前 2 条
        let top2 = this.getAllPeers(2)
        if (top2.size != 2) { return false }
        if (top2[0].id != 10001 || top2[1].id != 20002) { return false }

        // ② removePeer 后空：删全部，getAllPeers 应为空、contains 为 false
        for (p in allPeers) {
            this.removePeer(p.id)
        }
        if (this.getAllPeers(0).size != 0) { return false }
        if (this.containsPeer(10001)) { return false }
        match (this.getPeer(20002)) {
            case Some(_) => return false
            case None => ()
        }

        return true
    }
}
