package ohos_app_cangjie_entry.core.storage.postbox

/**
 * 消息历史复合键 —— MessageHistoryTable 的主键编码。
 *
 * iOS 标尺：Telegram-iOS/submodules/Postbox/Sources/MessageHistoryTable.swift
 *   - `key(_ index:)`   —— 把 MessageIndex 编成 20 字节大端键
 *   - `lowerBound/upperBound(peerId:namespace:)` —— 范围扫描边界
 *   - `extractKey(_ key:)` —— 从键反解回 MessageIndex
 * 以及 Message.swift 的 `struct MessageIndex`（字段 + `<` 比较语义）。
 *
 * 键字节布局（固定 20 字节，全大端 big-endian，字节字典序 == 逻辑数值序）：
 *
 *     offset  0..7   peerId    (Int64, 8 字节)
 *     offset  8..11  namespace (Int32, 4 字节)
 *     offset 12..15  timestamp (Int32, 4 字节)
 *     offset 16..19  id        (Int32, 4 字节)
 *
 * 对照 iOS `key(index)`：
 *     key.setInt64(0,        peerId)
 *     key.setInt32(8,        namespace)
 *     key.setInt32(8+4=12,   timestamp)
 *     key.setInt32(8+4+4=16, id)
 *
 * 即「字节序」的排序优先级为 peerId → namespace → timestamp → id：
 * 同一 (peerId, namespace) 下，键按 timestamp 升序、再按 id 升序 —— 这正是
 * 历史表「按时间顺序」遍历某会话某命名空间消息所需的物理顺序。
 *
 * 注意（无符号大端比较 vs 有符号字段）：
 *   - ValueBoxKey.setInt32 是大端写入，ValueBoxKey.compareTo 是逐字节「无符号」
 *     memcmp（Byte == UInt8）。因此对 Int32 字段，字节序 == 无符号数值序。
 *   - timestamp 是 Unix 秒（正数，Int32 高位 0），id 是正向自增消息号（正数），
 *     namespace 是小正数 —— 全部高位 0，故「无符号字节序 == 有符号逻辑序」成立。
 *     若某字段为负（高位 1），其无符号字节序会被排到所有正值之后，与逻辑序背离；
 *     这与 iOS 的物理键行为一致（iOS 同样直接 bigEndian memcmp），属同源约束。
 *
 * 逻辑比较 `compareTo` / `<` 等：对齐 iOS `MessageIndex.<`
 *   优先级 timestamp → namespace → id → peerId（注意与「键字节序」优先级不同：
 *   键的物理顺序是 peer 优先，而逻辑全序是 timestamp 优先 —— 二者用途不同，
 *   前者服务范围扫描、后者服务跨会话的全局时间序比较）。
 *
 * 值语义：用 struct（值类型），与 iOS `struct MessageIndex` 对齐。
 */
public struct MessageIndex <: Comparable<MessageIndex> & Equatable<MessageIndex> {
    public let peerId: Int64
    public let namespace: Int32
    public let timestamp: Int32
    public let id: Int32

    public init(peerId!: Int64, namespace!: Int32, timestamp!: Int32, id!: Int32) {
        this.peerId = peerId
        this.namespace = namespace
        this.timestamp = timestamp
        this.id = id
    }

    // ---- 键字节布局常量（与 iOS 8+4+4+4 对齐）----
    static let OFFSET_PEER_ID: Int64 = 0
    static let OFFSET_NAMESPACE: Int64 = 8
    static let OFFSET_TIMESTAMP: Int64 = 12
    static let OFFSET_ID: Int64 = 16
    static let KEY_LENGTH: Int64 = 20

    /**
     * 编码为 20 字节大端复合键（对应 iOS `key(_ index:)`）。
     * [peerId:8][namespace:4][timestamp:4][id:4]
     */
    public func key(): ValueBoxKey {
        let k = ValueBoxKey(length: MessageIndex.KEY_LENGTH)
        k.setInt64(MessageIndex.OFFSET_PEER_ID, this.peerId)
        k.setInt32(MessageIndex.OFFSET_NAMESPACE, this.namespace)
        k.setInt32(MessageIndex.OFFSET_TIMESTAMP, this.timestamp)
        k.setInt32(MessageIndex.OFFSET_ID, this.id)
        return k
    }

    /**
     * 从 20 字节键反解回 MessageIndex（对应 iOS `extractKey(_ key:)`）。
     * 与 key() 严格对称：getInt64(0)/getInt32(8)/getInt32(12)/getInt32(16)。
     */
    public static func extractKey(key: ValueBoxKey): MessageIndex {
        let peerId = key.getInt64(MessageIndex.OFFSET_PEER_ID)
        let namespace = key.getInt32(MessageIndex.OFFSET_NAMESPACE)
        let timestamp = key.getInt32(MessageIndex.OFFSET_TIMESTAMP)
        let id = key.getInt32(MessageIndex.OFFSET_ID)
        return MessageIndex(peerId: peerId, namespace: namespace, timestamp: timestamp, id: id)
    }

    // ---- 范围扫描边界 ----

    /**
     * 某 peerId 全部消息的下界键（仅填 peerId 段，长度 8）。
     * 对应 iOS 在 peer 维度的前缀键：后续 namespace/timestamp/id 全部留空，
     * 由 ValueBoxKey.compareTo「短者为小 + 前缀」语义夹住该 peer 的所有 20 字节键。
     */
    public static func lowerBound(peerId!: Int64): ValueBoxKey {
        let k = ValueBoxKey(length: 8)
        k.setInt64(MessageIndex.OFFSET_PEER_ID, peerId)
        return k
    }

    /**
     * 某 peerId 全部消息的上界键 = lowerBound(peerId).successor()。
     * [lowerBound, upperBound) 半开区间恰好覆盖该 peer 的全部键。
     */
    public static func upperBound(peerId!: Int64): ValueBoxKey {
        return MessageIndex.lowerBound(peerId: peerId).successor()
    }

    /**
     * 某 (peerId, namespace) 全部消息的下界键（填 peerId+namespace 段，长度 12）。
     * 对应 iOS `lowerBound(peerId:namespace:)` —— `ValueBoxKey(length: 8 + 4)`。
     */
    public static func lowerBound(peerId!: Int64, namespace!: Int32): ValueBoxKey {
        let k = ValueBoxKey(length: 12)
        k.setInt64(MessageIndex.OFFSET_PEER_ID, peerId)
        k.setInt32(MessageIndex.OFFSET_NAMESPACE, namespace)
        return k
    }

    /**
     * 某 (peerId, namespace) 全部消息的上界键 = lowerBound(peerId,namespace).successor()。
     * 对应 iOS `upperBound(peerId:namespace:)`。
     */
    public static func upperBound(peerId!: Int64, namespace!: Int32): ValueBoxKey {
        return MessageIndex.lowerBound(peerId: peerId, namespace: namespace).successor()
    }

    // ---- 逻辑全序比较（对齐 iOS `MessageIndex.<`：timestamp → namespace → id → peerId）----

    public func compareTo(other: MessageIndex): Int64 {
        if (this.timestamp != other.timestamp) {
            return if (this.timestamp < other.timestamp) { -1 } else { 1 }
        }
        if (this.namespace != other.namespace) {
            return if (this.namespace < other.namespace) { -1 } else { 1 }
        }
        if (this.id != other.id) {
            return if (this.id < other.id) { -1 } else { 1 }
        }
        if (this.peerId != other.peerId) {
            return if (this.peerId < other.peerId) { -1 } else { 1 }
        }
        return 0
    }

    public func compare(other: MessageIndex): Ordering {
        let c = compareTo(other)
        if (c < 0) {
            return Ordering.LT
        } else if (c > 0) {
            return Ordering.GT
        }
        return Ordering.EQ
    }

    public operator func ==(right: MessageIndex): Bool {
        return compareTo(right) == 0
    }

    public operator func !=(right: MessageIndex): Bool {
        return compareTo(right) != 0
    }

    public operator func <(right: MessageIndex): Bool {
        return compareTo(right) < 0
    }

    public operator func <=(right: MessageIndex): Bool {
        return compareTo(right) <= 0
    }

    public operator func >(right: MessageIndex): Bool {
        return compareTo(right) > 0
    }

    public operator func >=(right: MessageIndex): Bool {
        return compareTo(right) >= 0
    }

    public func description(): String {
        return "MessageIndex(peerId=${this.peerId}, namespace=${this.namespace}, timestamp=${this.timestamp}, id=${this.id})"
    }

    /**
     * 自检：验证 key↔extractKey 互逆、键字节序 == 时间序、upperBound/successor 区间夹住性。
     * 返回 true 表示全部断言通过。非常驻逻辑，供测试 / 启动诊断显式调用。
     */
    public static func selfCheck(): Bool {
        // ① key ↔ extractKey 互逆
        let idx = MessageIndex(peerId: 777, namespace: 5, timestamp: 1700000000, id: 42)
        let k = idx.key()
        if (k.length() != 20) { return false }
        let back = MessageIndex.extractKey(k)
        if (back != idx) { return false }
        if (back.peerId != 777 || back.namespace != 5 || back.timestamp != 1700000000 || back.id != 42) {
            return false
        }

        // 字节布局抽检：peerId 高字节在 offset 0；namespace 段从 offset 8 起。
        // namespace=5 -> 大端 [00 00 00 05]，故 byte[11] == 5、byte[8..10] == 0。
        if (k.getUInt8(8) != UInt8(0) || k.getUInt8(9) != UInt8(0) ||
            k.getUInt8(10) != UInt8(0) || k.getUInt8(11) != UInt8(5)) {
            return false
        }

        // ② 同 peer/namespace 不同 timestamp：键字节序 == 时间序
        let early = MessageIndex(peerId: 777, namespace: 5, timestamp: 1000, id: 9)
        let late = MessageIndex(peerId: 777, namespace: 5, timestamp: 2000, id: 1)
        // 字节比较：early.key < late.key（尽管 early.id > late.id，timestamp 段在 id 段之前）
        if (!(early.key() < late.key())) { return false }
        if (!(late.key() > early.key())) { return false }

        // ③ upperBound = lowerBound.successor() 夹住同 (peer,namespace) 的全部键
        let lo = MessageIndex.lowerBound(peerId: 777, namespace: 5)
        let hi = MessageIndex.upperBound(peerId: 777, namespace: 5)
        if (!(lo < hi)) { return false }
        // 同 (peer,namespace) 的任意键必落在 [lo, hi)
        let members = [
            MessageIndex(peerId: 777, namespace: 5, timestamp: 0, id: 0).key(),
            early.key(),
            late.key(),
            idx.key(),
            MessageIndex(peerId: 777, namespace: 5, timestamp: 0x7FFFFFFF, id: 0x7FFFFFFF).key()
        ]
        for (m in members) {
            if (!(lo <= m)) { return false }
            if (!(m < hi)) { return false }
        }
        // 边界否定：相邻 namespace（namespace=6）的键必 >= hi（落在区间外）
        let outNs = MessageIndex(peerId: 777, namespace: 6, timestamp: 0, id: 0).key()
        if (!(outNs >= hi)) { return false }
        // 边界否定：相邻 peer（peerId=778）的键必 >= hi
        let outPeer = MessageIndex(peerId: 778, namespace: 5, timestamp: 0, id: 0).key()
        if (!(outPeer >= hi)) { return false }

        // ④ peer 维度边界：lowerBound(peerId) / upperBound(peerId) 夹住该 peer 全部键
        let ploLen = MessageIndex.lowerBound(peerId: 777)
        let phi = MessageIndex.upperBound(peerId: 777)
        if (ploLen.length() != 8) { return false }
        if (!(ploLen < phi)) { return false }
        for (m in members) {
            if (!(ploLen <= m)) { return false }
            if (!(m < phi)) { return false }
        }
        // 相邻 peer 落在 peer 区间外
        if (!(outPeer >= phi)) { return false }

        // ⑤ 逻辑全序 compareTo（timestamp 优先）：early(ts=1000) < late(ts=2000)
        if (!(early < late)) { return false }
        // timestamp 相同则比 namespace，再 id，再 peerId
        let a = MessageIndex(peerId: 1, namespace: 0, timestamp: 500, id: 7)
        let b = MessageIndex(peerId: 1, namespace: 0, timestamp: 500, id: 8)
        if (!(a < b)) { return false }
        let c = MessageIndex(peerId: 2, namespace: 0, timestamp: 500, id: 8)
        if (!(b < c)) { return false }  // 同 ts/ns/id，peerId 1 < 2
        if (!(a == a)) { return false }

        return true
    }
}
