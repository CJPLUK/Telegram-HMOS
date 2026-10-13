package ohos_app_cangjie_entry.core.storage.postbox

import ohos_app_cangjie_entry.models.{Chat, PeerKey}

/**
 * 会话列表落盘模型 + 复合键 —— 离线会话列表的数据底座。
 *
 * iOS 标尺：
 *   - Telegram-iOS/submodules/Postbox/Sources/ChatListIndexTable.swift
 *       `ChatListIndex(pinningIndex:, messageIndex:)` —— 排序键由「置顶序」+「顶部消息 MessageIndex」组成。
 *   - Telegram-iOS/submodules/Postbox/Sources/ChatListTable.swift
 *       会话列表物理键：置顶项在前，未置顶项按 top message 时间倒序（最新在前）。
 *
 * 本单元建在已合入 master 的 DB 底座上：
 *   - ValueBoxKey.cj   —— 固定长度大端键（setInt32/setInt64/getInt32/getInt64/successor/compareTo）
 *   - PostboxCoding.cj —— PostboxEncoder / PostboxDecoder（字段级标量编解码）
 *   - MessageIndex.cj  —— 复合键范式参考（[peerId:8][namespace:4][timestamp:4][id:4]）
 *   - models/Chat.cj   —— 工程内会话模型（id=peerId、lastMessageTimestamp、unreadCount、isPinned、isMuted…）
 *
 * Chat 模型字段映射（来自 models/Chat.cj，真实字段，未臆造）：
 *   Chat.id                  -> peerId            (Int64)
 *   Chat.lastMessageTimestamp-> topMessageTimestamp (Int64，转 Int32 落盘，Unix 秒)
 *   Chat.unreadCount         -> unreadCount       (Int64，转 Int32 落盘)
 *   Chat.isPinned            -> pinningRank (置顶=0；未置顶=PINNING_RANK_UNPINNED 哨兵)
 *   Chat.isMuted             -> flags 的 FLAG_MUTED 位
 * Chat 模型当前没有独立的 topMessageId / archived 字段：
 *   - topMessageId 用 0 占位（Chat 不暴露顶部消息 id；非破坏性，可后续扩展）。
 *   - archived（归档）在 Chat 模型中暂无对应字段，故 flags 的 FLAG_ARCHIVED 位
 *     默认 0；归档分区为本单元 out-of-scope（待 Chat 模型补 archived 字段后再接）。
 *   - group / tags / draft 等复杂字段：out-of-scope，本落盘项不承载。
 */

/**
 * 落盘会话项 —— 会话列表条目的持久化核心字段子集。
 *
 * 用 class（与 models/Chat.cj 的纯数据类风格一致；落盘项需可变字段聚合）。
 * encode(PostboxEncoder) / static decode(PostboxDecoder) 与底座编解码层对称。
 */
public class IntermediateChatListItem {
    public var peerId: Int64
    public var peerType: String
    public var topMessageId: Int32
    public var topMessageTimestamp: Int32
    // 置顶序：置顶项 0,1,2…（越小越靠前）；未置顶项 = PINNING_RANK_UNPINNED 哨兵（排在所有置顶之后）。
    public var pinningRank: Int32
    public var unreadCount: Int32
    // 位标志聚合：archived / muted 等（archived 位当前恒 0，见文件头说明）。
    public var flags: Int32

    // ---- 显示字段（P2-288d：离线会话列表条目展示所需，缺失时离线列表无名字/无预览）----
    // 这些字段不参与物理排序键，仅持久化以便离线 toChat() 出来的 Chat 可直接显示。
    // 全部可空语义用空串表示；decode 时旧库无对应 key 回落空串（向后兼容）。
    public var name: String              // 会话名（Chat.name）
    public var lastMessagePreview: String // 最后一条消息预览（Chat.lastMessage）
    public var avatarText: String        // 头像占位文字（Chat.avatarText）
    public var draftText: String         // 草稿文本（Chat.draftText）
    public var username: String          // 用户名/频道名（Chat.username）
    public var isGroup: Bool             // 是否群组（Chat.isGroup）
    public var isChannel: Bool           // 是否频道（Chat.isChannel）
    public var isMegagroup: Bool         // 是否超级群（Chat.isMegagroup）

    // ---- flags 位定义 ----
    public static let FLAG_ARCHIVED: Int32 = 1     // 1 << 0
    public static let FLAG_MUTED: Int32 = 2        // 1 << 1

    // 未置顶哨兵：用 Int32.max（0x7FFFFFFF）。键里 pinningRank 段大端写入此值后，
    // 字节序大于任何真实置顶 rank（0,1,2…），从而未置顶项物理排在所有置顶项之后。
    public static let PINNING_RANK_UNPINNED: Int32 = 0x7FFFFFFF

    public init(
        peerId!: Int64,
        peerType!: String = "user",
        topMessageId!: Int32,
        topMessageTimestamp!: Int32,
        pinningRank!: Int32,
        unreadCount!: Int32,
        flags!: Int32,
        name!: String = "",
        lastMessagePreview!: String = "",
        avatarText!: String = "",
        draftText!: String = "",
        username!: String = "",
        isGroup!: Bool = false,
        isChannel!: Bool = false,
        isMegagroup!: Bool = false
    ) {
        this.peerId = peerId
        this.peerType = PeerKey.normalizeNamespace(peerType)
        this.topMessageId = topMessageId
        this.topMessageTimestamp = topMessageTimestamp
        this.pinningRank = pinningRank
        this.unreadCount = unreadCount
        this.flags = flags
        this.name = name
        this.lastMessagePreview = lastMessagePreview
        this.avatarText = avatarText
        this.draftText = draftText
        this.username = username
        this.isGroup = isGroup
        this.isChannel = isChannel
        this.isMegagroup = isMegagroup
    }

    public func isPinned(): Bool {
        return this.pinningRank != IntermediateChatListItem.PINNING_RANK_UNPINNED
    }

    public func isArchived(): Bool {
        return (this.flags & IntermediateChatListItem.FLAG_ARCHIVED) != 0
    }

    public func isMuted(): Bool {
        return (this.flags & IntermediateChatListItem.FLAG_MUTED) != 0
    }

    /**
     * 编码到 PostboxEncoder（字段级标量编解码，对应 iOS 落盘项 encode）。
     * 字段 key 用短稳定串，与 decode 对称。
     */
    public func encode(encoder: PostboxEncoder): Unit {
        encoder.encodeInt64(this.peerId, key: "p")
        encoder.encodeString(this.peerType, key: "pt")
        encoder.encodeInt32(this.topMessageId, key: "mid")
        encoder.encodeInt32(this.topMessageTimestamp, key: "ts")
        encoder.encodeInt32(this.pinningRank, key: "pr")
        encoder.encodeInt32(this.unreadCount, key: "uc")
        encoder.encodeInt32(this.flags, key: "fl")
        // ---- 显示字段（P2-288d）----
        encoder.encodeString(this.name, key: "nm")
        encoder.encodeString(this.lastMessagePreview, key: "lm")
        encoder.encodeString(this.avatarText, key: "at")
        encoder.encodeString(this.draftText, key: "dr")
        encoder.encodeString(this.username, key: "un")
        encoder.encodeBool(this.isGroup, key: "ig")
        encoder.encodeBool(this.isChannel, key: "ic")
        encoder.encodeBool(this.isMegagroup, key: "im")
    }

    /**
     * 从 PostboxDecoder 还原（与 encode 严格对称）。
     */
    public static func decode(decoder: PostboxDecoder): IntermediateChatListItem {
        let peerId = decoder.decodeInt64("p", orElse: 0)
        let topMessageId = decoder.decodeInt32("mid", orElse: 0)
        let topMessageTimestamp = decoder.decodeInt32("ts", orElse: 0)
        let pinningRank = decoder.decodeInt32("pr", orElse: IntermediateChatListItem.PINNING_RANK_UNPINNED)
        let unreadCount = decoder.decodeInt32("uc", orElse: 0)
        let flags = decoder.decodeInt32("fl", orElse: 0)
        // ---- 显示字段（P2-288d）：向后兼容 —— 旧库无这些 key 时 positionOnKey 返回 false，
        //      decodeString/decodeBool 回落 orElse（空串 / false），不崩。----
        let name = decoder.decodeString("nm", orElse: "")
        let lastMessagePreview = decoder.decodeString("lm", orElse: "")
        let avatarText = decoder.decodeString("at", orElse: "")
        let draftText = decoder.decodeString("dr", orElse: "")
        let username = decoder.decodeString("un", orElse: "")
        let isGroup = decoder.decodeBool("ig", orElse: false)
        let isChannel = decoder.decodeBool("ic", orElse: false)
        let isMegagroup = decoder.decodeBool("im", orElse: false)
        let storedPeerType = decoder.decodeString("pt", orElse: "")
        let peerType = if (!storedPeerType.isEmpty()) {
            storedPeerType
        } else if (isChannel) {
            PeerKey.CHANNEL
        } else if (isGroup || isMegagroup) {
            PeerKey.BASIC_GROUP
        } else {
            PeerKey.USER
        }
        return IntermediateChatListItem(
            peerId: peerId,
            peerType: peerType,
            topMessageId: topMessageId,
            topMessageTimestamp: topMessageTimestamp,
            pinningRank: pinningRank,
            unreadCount: unreadCount,
            flags: flags,
            name: name,
            lastMessagePreview: lastMessagePreview,
            avatarText: avatarText,
            draftText: draftText,
            username: username,
            isGroup: isGroup,
            isChannel: isChannel,
            isMegagroup: isMegagroup
        )
    }

    /**
     * 便捷 round-trip：通过临时 encoder/decoder 自编自解（自检与落盘路径复用）。
     */
    public func encodedBytes(): Array<Byte> {
        let encoder = PostboxEncoder()
        this.encode(encoder)
        return encoder.makeBytes()
    }

    public static func decodeFromBytes(data: Array<Byte>): IntermediateChatListItem {
        return IntermediateChatListItem.decode(PostboxDecoder(data))
    }

    // ---- Chat <-> IntermediateChatListItem 双向转换 ----

    /**
     * Chat -> IntermediateChatListItem。
     *   - peerId             <- chat.id
     *   - topMessageTimestamp<- chat.lastMessageTimestamp（Int64 截到 Int32 Unix 秒）
     *   - pinningRank        <- chat.isPinned ? pinningRank : UNPINNED 哨兵
     *   - unreadCount        <- chat.unreadCount（Int64 截到 Int32）
     *   - flags              <- chat.isMuted -> FLAG_MUTED（archived 暂无源字段 -> 0）
     *
     * pinningRank!：当 chat 置顶时，调用方应传入该会话在置顶序里的位次（0 起）；
     * 未置顶时该参数被忽略（统一写哨兵）。默认 0 表示「置顶序首位」。
     */
    public static func fromChat(chat: Chat, pinningRank!: Int32 = 0): IntermediateChatListItem {
        let resolvedRank = if (chat.isPinned) {
            pinningRank
        } else {
            IntermediateChatListItem.PINNING_RANK_UNPINNED
        }
        var flags: Int32 = 0
        if (chat.isMuted) {
            flags |= IntermediateChatListItem.FLAG_MUTED
        }
        return IntermediateChatListItem(
            peerId: chat.id,
            peerType: chat.peerType,
            topMessageId: 0,
            topMessageTimestamp: Int32(chat.lastMessageTimestamp),
            pinningRank: resolvedRank,
            unreadCount: Int32(chat.unreadCount),
            flags: flags,
            name: chat.name,
            lastMessagePreview: chat.lastMessage,
            avatarText: chat.avatarText,
            draftText: chat.draftText,
            username: chat.username,
            isGroup: chat.isGroup,
            isChannel: chat.isChannel,
            isMegagroup: chat.isMegagroup
        )
    }

    /**
     * IntermediateChatListItem -> Chat（只回填本落盘项承载的核心字段；
     * 其余 Chat 字段保持默认，因落盘项有意只持久化核心子集）。
     */
    public func toChat(): Chat {
        let chat = Chat()
        chat.id = this.peerId
        chat.peerType = PeerKey.fromPeerType(this.peerType, this.peerId).toPeerType()
        chat.lastMessageTimestamp = Int64(this.topMessageTimestamp)
        chat.unreadCount = Int64(this.unreadCount)
        chat.isPinned = this.isPinned()
        chat.isMuted = this.isMuted()
        // ---- 显示字段（P2-288d）：回填使离线 Chat 直接可显示名字 / 预览 / 头像 ----
        chat.name = this.name
        chat.lastMessage = this.lastMessagePreview
        chat.avatarText = this.avatarText
        chat.draftText = this.draftText
        chat.username = this.username
        chat.isGroup = this.isGroup
        chat.isChannel = this.isChannel
        chat.isMegagroup = this.isMegagroup
        return chat
    }

    /**
     * 取本项对应的 ChatListIndex（用于生成物理排序键）。
     */
    public func chatListIndex(): ChatListIndex {
        return ChatListIndex(
            pinningRank: this.pinningRank,
            timestamp: this.topMessageTimestamp,
            peerId: PeerKey.fromPeerType(this.peerType, this.peerId).storageId()
        )
    }

    /** 6.1 以前缓存的物理键未编码 namespace；仅用于一次性兼容清理。 */
    public func legacyChatListIndex(): ChatListIndex {
        return ChatListIndex(
            pinningRank: this.pinningRank,
            timestamp: this.topMessageTimestamp,
            peerId: this.peerId
        )
    }
}

/**
 * ChatListIndex —— 会话列表的物理排序键（值类型，对应 iOS struct ChatListIndex）。
 *
 * 复合大端键布局（固定 16 字节，字节字典序 == 物理排序序）：
 *
 *     offset  0..3   pinningRank          (Int32, 4 字节)  —— 置顶序，置顶在前
 *     offset  4..7   invertedTimestamp    (Int32, 4 字节)  —— (TIMESTAMP_MAX - timestamp)，实现时间倒序
 *     offset  8..15  peerId               (Int64, 8 字节)  —— 同档去重 / 稳定排序
 *
 * 排序语义（升序扫描键即得正确列表序）：
 *   1) pinningRank 升序 —— 置顶项 rank 小（0,1,2…）排前；未置顶项 rank = 哨兵 Int32.max，排所有置顶之后。
 *   2) 同 rank 档内：「最新在前」。键里存 invertedTimestamp = TIMESTAMP_MAX - timestamp，
 *      timestamp 越大 -> invertedTimestamp 越小 -> 键越小 -> 升序扫描时越靠前，
 *      于是物理升序扫描天然得到「时间倒序（最新在前）」。这样无需依赖底层 range 的降序能力，
 *      仅用既有的升序 [lowerBound, upperBound) 扫描即可，可编译且语义正确。
 *   3) 时间相同：按 peerId 升序稳定排序。
 *
 * 所有键段（pinningRank / invertedTimestamp / peerId）取值均非负（rank ≥ 0，
 * invertedTimestamp = max - ts ≥ 0 当 0 ≤ ts ≤ max），故「无符号字节序 == 逻辑序」成立，
 * 与 MessageIndex.cj 的同源约束一致。
 */
public struct ChatListIndex <: Comparable<ChatListIndex> & Equatable<ChatListIndex> {
    public let pinningRank: Int32
    // 真实顶部消息时间戳（Unix 秒）。键里落的是 (TIMESTAMP_MAX - timestamp)，本字段保持真实值。
    public let timestamp: Int32
    public let peerId: Int64

    public init(pinningRank!: Int32, timestamp!: Int32, peerId!: Int64) {
        this.pinningRank = pinningRank
        this.timestamp = timestamp
        this.peerId = peerId
    }

    // ---- 键布局常量 ----
    static let OFFSET_PINNING_RANK: Int64 = 0
    static let OFFSET_TIMESTAMP: Int64 = 4
    static let OFFSET_PEER_ID: Int64 = 8
    static let KEY_LENGTH: Int64 = 16

    // 时间倒序基准：Int32.max。invertedTimestamp = TIMESTAMP_MAX - timestamp。
    public static let TIMESTAMP_MAX: Int32 = 0x7FFFFFFF
    // 未置顶哨兵（与 IntermediateChatListItem 对齐）。
    public static let PINNING_RANK_UNPINNED: Int32 = 0x7FFFFFFF

    /**
     * 编码为 16 字节大端复合键 [pinningRank:4][invertedTimestamp:4][peerId:8]。
     */
    public func key(): ValueBoxKey {
        let k = ValueBoxKey(length: ChatListIndex.KEY_LENGTH)
        k.setInt32(ChatListIndex.OFFSET_PINNING_RANK, this.pinningRank)
        k.setInt32(ChatListIndex.OFFSET_TIMESTAMP, ChatListIndex.invertTimestamp(this.timestamp))
        k.setInt64(ChatListIndex.OFFSET_PEER_ID, this.peerId)
        return k
    }

    /**
     * 从 16 字节键反解回 ChatListIndex（与 key() 严格对称：还原真实 timestamp）。
     */
    public static func extractKey(key: ValueBoxKey): ChatListIndex {
        let pinningRank = key.getInt32(ChatListIndex.OFFSET_PINNING_RANK)
        let inverted = key.getInt32(ChatListIndex.OFFSET_TIMESTAMP)
        let peerId = key.getInt64(ChatListIndex.OFFSET_PEER_ID)
        return ChatListIndex(
            pinningRank: pinningRank,
            timestamp: ChatListIndex.invertTimestamp(inverted),
            peerId: peerId
        )
    }

    /**
     * 时间倒序变换：TIMESTAMP_MAX - ts。自反（invert(invert(x)) == x，当 0 ≤ x ≤ MAX）。
     */
    static func invertTimestamp(ts: Int32): Int32 {
        return ChatListIndex.TIMESTAMP_MAX - ts
    }

    // ---- 范围扫描边界（全表区间） ----
    //
    // Chat 模型暂无 archived 字段（见文件头），故按归档 namespace 分区为 out-of-scope；
    // 这里提供「全表」上下界。
    //   lowerBound：长度 0 的空键 —— 按 ValueBoxKey「短者为小 + 前缀」语义，它是任意键之前的下界。
    //   upperBound：单字节 [0xFF] 键 —— 所有真实键的 pinningRank 段高字节 ≤ 0x7F（rank ∈
    //     [0, Int32.max]，最高位 0），故首字节 0xFF 的键严格大于任意 16 字节会话键。
    //   （注意：长度 0 键的 successor() 仍是长度 0 键、与自身相等，不能当上界，故这里显式用 [0xFF]。）
    // 升序扫描 [lowerBound, upperBound) 即按上面排序语义遍历整张会话列表（置顶在前、同档最新在前）。

    public static func lowerBound(): ValueBoxKey {
        return ValueBoxKey(length: 0)
    }

    public static func upperBound(): ValueBoxKey {
        let k = ValueBoxKey(length: 1)
        k.setUInt8(0, UInt8(0xFF))
        return k
    }

    // ---- 逻辑全序（与物理键序一致：pinningRank 升序 -> 时间倒序 -> peerId 升序）----

    public func compareTo(other: ChatListIndex): Int64 {
        if (this.pinningRank != other.pinningRank) {
            return if (this.pinningRank < other.pinningRank) { -1 } else { 1 }
        }
        // 时间倒序：timestamp 大者排前（更小）
        if (this.timestamp != other.timestamp) {
            return if (this.timestamp > other.timestamp) { -1 } else { 1 }
        }
        if (this.peerId != other.peerId) {
            return if (this.peerId < other.peerId) { -1 } else { 1 }
        }
        return 0
    }

    public func compare(other: ChatListIndex): Ordering {
        let c = compareTo(other)
        if (c < 0) {
            return Ordering.LT
        } else if (c > 0) {
            return Ordering.GT
        }
        return Ordering.EQ
    }

    public operator func ==(right: ChatListIndex): Bool {
        return compareTo(right) == 0
    }

    public operator func !=(right: ChatListIndex): Bool {
        return compareTo(right) != 0
    }

    public operator func <(right: ChatListIndex): Bool {
        return compareTo(right) < 0
    }

    public operator func <=(right: ChatListIndex): Bool {
        return compareTo(right) <= 0
    }

    public operator func >(right: ChatListIndex): Bool {
        return compareTo(right) > 0
    }

    public operator func >=(right: ChatListIndex): Bool {
        return compareTo(right) >= 0
    }

    public func description(): String {
        return "ChatListIndex(pinningRank=${this.pinningRank}, timestamp=${this.timestamp}, peerId=${this.peerId})"
    }
}

/**
 * 自检：① IntermediateChatListItem round-trip（含经 Chat 双向转换）；
 *       ② ChatListIndex 键 round-trip（key ↔ extractKey 还原真实 timestamp）；
 *       ③ 键排序：置顶在未置顶前；同档「最新在前」（时间倒序）；时间同按 peerId。
 * 返回 true 表示全部断言通过。非常驻逻辑，供测试 / 启动诊断显式调用。
 */
public func chatListEntrySelfCheck(): Bool {
    // ===== ① IntermediateChatListItem encode/decode round-trip =====
    let item = IntermediateChatListItem(
        peerId: 123456789,
        topMessageId: 42,
        topMessageTimestamp: 1700000000,
        pinningRank: 3,
        unreadCount: 7,
        flags: IntermediateChatListItem.FLAG_MUTED
    )
    let back = IntermediateChatListItem.decodeFromBytes(item.encodedBytes())
    if (back.peerId != 123456789) { return false }
    if (back.topMessageId != 42) { return false }
    if (back.topMessageTimestamp != 1700000000) { return false }
    if (back.pinningRank != 3) { return false }
    if (back.unreadCount != 7) { return false }
    if (!back.isMuted()) { return false }
    if (!back.isPinned()) { return false }

    // ===== ② Chat -> fromChat -> encode -> decode -> toChat 关键字段相等 =====
    let chat = Chat()
    chat.id = 987654321
    chat.lastMessageTimestamp = 1699999000
    chat.unreadCount = 5
    chat.isPinned = true
    chat.isMuted = true
    // 显示字段（P2-288d）
    chat.name = "Alice 世界"
    chat.lastMessage = "see you tomorrow"
    chat.avatarText = "A"
    chat.draftText = "draft..."
    chat.username = "alice"
    chat.isGroup = true
    chat.isChannel = false
    chat.isMegagroup = true
    let fromChat = IntermediateChatListItem.fromChat(chat, pinningRank: 1)
    let decoded = IntermediateChatListItem.decodeFromBytes(fromChat.encodedBytes())
    let chat2 = decoded.toChat()
    if (chat2.id != chat.id) { return false }
    if (chat2.lastMessageTimestamp != chat.lastMessageTimestamp) { return false }
    if (chat2.unreadCount != chat.unreadCount) { return false }
    if (chat2.isPinned != chat.isPinned) { return false }
    if (chat2.isMuted != chat.isMuted) { return false }
    // 显示字段 round-trip 相等
    if (chat2.name != chat.name) { return false }
    if (chat2.lastMessage != chat.lastMessage) { return false }
    if (chat2.avatarText != chat.avatarText) { return false }
    if (chat2.draftText != chat.draftText) { return false }
    if (chat2.username != chat.username) { return false }
    if (chat2.isGroup != chat.isGroup) { return false }
    if (chat2.isChannel != chat.isChannel) { return false }
    if (chat2.isMegagroup != chat.isMegagroup) { return false }

    // ===== ② a. 向后兼容：旧格式（只含核心 key、无显示字段）decode 不崩，显示字段回落空串/false =====
    let legacyEncoder = PostboxEncoder()
    legacyEncoder.encodeInt64(555000, key: "p")
    legacyEncoder.encodeInt32(0, key: "mid")
    legacyEncoder.encodeInt32(1700000123, key: "ts")
    legacyEncoder.encodeInt32(IntermediateChatListItem.PINNING_RANK_UNPINNED, key: "pr")
    legacyEncoder.encodeInt32(2, key: "uc")
    legacyEncoder.encodeInt32(0, key: "fl")
    let legacy = IntermediateChatListItem.decodeFromBytes(legacyEncoder.makeBytes())
    if (legacy.peerId != 555000) { return false }
    if (legacy.topMessageTimestamp != 1700000123) { return false }
    if (legacy.unreadCount != 2) { return false }
    if (legacy.name != "") { return false }
    if (legacy.lastMessagePreview != "") { return false }
    if (legacy.avatarText != "") { return false }
    if (legacy.draftText != "") { return false }
    if (legacy.username != "") { return false }
    if (legacy.isGroup) { return false }
    if (legacy.isChannel) { return false }
    if (legacy.isMegagroup) { return false }
    // 旧格式 toChat 也不崩，显示字段为默认空
    let legacyChat = legacy.toChat()
    if (legacyChat.name != "") { return false }
    if (legacyChat.lastMessage != "") { return false }

    // 未置顶会话：fromChat 应写哨兵 rank，toChat 回来 isPinned == false
    let chatUnpinned = Chat()
    chatUnpinned.id = 111
    chatUnpinned.isPinned = false
    let upItem = IntermediateChatListItem.fromChat(chatUnpinned)
    if (upItem.pinningRank != IntermediateChatListItem.PINNING_RANK_UNPINNED) { return false }
    if (upItem.isPinned()) { return false }
    if (upItem.toChat().isPinned) { return false }

    // ===== ② b. ChatListIndex 键 round-trip（还原真实 timestamp）=====
    let idx = ChatListIndex(pinningRank: 2, timestamp: 1700000000, peerId: 555)
    let key = idx.key()
    if (key.length() != 16) { return false }
    let idxBack = ChatListIndex.extractKey(key)
    if (idxBack.pinningRank != 2) { return false }
    if (idxBack.timestamp != 1700000000) { return false }
    if (idxBack.peerId != 555) { return false }
    if (idxBack != idx) { return false }

    // ===== ③ 键排序断言 =====
    // 置顶（rank=0）排在未置顶（哨兵 rank）之前
    let pinned = ChatListIndex(pinningRank: 0, timestamp: 1000, peerId: 1)
    let unpinnedNew = ChatListIndex(
        pinningRank: ChatListIndex.PINNING_RANK_UNPINNED,
        timestamp: 2000000000,  // 比 pinned 更新，但因未置顶仍排在后
        peerId: 2
    )
    if (!(pinned.key() < unpinnedNew.key())) { return false }
    if (!(pinned < unpinnedNew)) { return false }

    // 同档（都未置顶）「最新在前」：timestamp 大者键更小（排前）
    let older = ChatListIndex(
        pinningRank: ChatListIndex.PINNING_RANK_UNPINNED, timestamp: 1000, peerId: 10)
    let newer = ChatListIndex(
        pinningRank: ChatListIndex.PINNING_RANK_UNPINNED, timestamp: 2000, peerId: 10)
    // newer（时间晚）应排在 older 前 -> 键更小
    if (!(newer.key() < older.key())) { return false }
    if (!(newer < older)) { return false }

    // 同档同时间：按 peerId 升序
    let pA = ChatListIndex(
        pinningRank: ChatListIndex.PINNING_RANK_UNPINNED, timestamp: 1500, peerId: 100)
    let pB = ChatListIndex(
        pinningRank: ChatListIndex.PINNING_RANK_UNPINNED, timestamp: 1500, peerId: 200)
    if (!(pA.key() < pB.key())) { return false }
    if (!(pA < pB)) { return false }

    // 置顶档内同样「最新在前」：rank 同 0，timestamp 大者排前
    let pin0Old = ChatListIndex(pinningRank: 0, timestamp: 500, peerId: 7)
    let pin0New = ChatListIndex(pinningRank: 0, timestamp: 900, peerId: 7)
    if (!(pin0New.key() < pin0Old.key())) { return false }

    // 多档置顶有序：rank 0 < rank 1 < 未置顶哨兵
    let r0 = ChatListIndex(pinningRank: 0, timestamp: 100, peerId: 1)
    let r1 = ChatListIndex(pinningRank: 1, timestamp: 999999, peerId: 1)
    if (!(r0.key() < r1.key())) { return false }
    if (!(r1.key() < unpinnedNew.key())) { return false }

    // 全表区间夹住所有键
    let lo = ChatListIndex.lowerBound()
    let hi = ChatListIndex.upperBound()
    if (!(lo < hi)) { return false }
    let members = [pinned.key(), unpinnedNew.key(), older.key(), newer.key(), r0.key(), r1.key()]
    for (m in members) {
        if (!(lo <= m)) { return false }
        if (!(m < hi)) { return false }
    }

    return true
}
