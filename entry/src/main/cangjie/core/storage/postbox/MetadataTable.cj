package ohos_app_cangjie_entry.core.storage.postbox

/**
 * MetadataTable —— Postbox 元数据表：按固定 int64 枚举键存 Postbox 顶层运行时状态。
 *
 * iOS 标尺：Telegram-iOS/submodules/Postbox/Sources/MetadataTable.swift。
 *   一张固定 id 的 int64 键表，按 MetadataKey 枚举（UserVersion=1 / State=2 /
 *   TransactionStateVersion=3 / MasterClientId=4 / RemoteContactCount=6）存值；
 *   值为裸字节（Int32/Int64 原生写入）或经 PostboxCoding 序列化（state）。
 *
 * 鸿蒙等价实现：
 *   - 表建在 int64 键的 ValueBoxTable 上（RdbValueBox 落地为物理表 t<id>，
 *     key INTEGER PRIMARY KEY / value BLOB）。
 *   - 键：用 8 字节大端 ValueBoxKey 承载 MetadataKey 的 int64 编号（与 iOS
 *     `ValueBoxKey(length:8).setInt64(0, key.rawValue)` 一致）。
 *   - 标量值（Int32/Int64）：以 ValueBoxKey 的大端字节缓冲承载后取字节（复用
 *     已验证的大端读写），保证读回写入一致。
 *   - state：顶层同步状态 blob，经 PostboxEncoder 序列化存、PostboxDecoder 取回
 *     （对应 iOS encodeRootObject / decodeRootObject 的字节往返）。
 *
 * userVersion 一致性说明（与 iOS 对齐）：
 *   iOS 的 SqliteValueBox 把 user_version 走 SQLite PRAGMA user_version（不是 t<id>
 *   表内的某个 key）。本实现同样把 userVersion 委托给 PostboxDatabase 的 PRAGMA
 *   读写（PostboxDatabase.userVersion()/setUserVersion()），保持与 iOS 完全一致；
 *   不在元数据表里另存一份 version，避免双源不一致。
 *
 * MTProto 说明（N/A）：本地持久化元数据表，不涉及 MTProto 协议。
 */

/**
 * 元数据键枚举编号（对应 iOS MetadataKey: Int32）。
 *
 * 仓颉的 `Int64` 是类型名（保留），不能用作枚举值名；这里用一组 const Int64
 * 常量表达「固定编号键」，数值与 iOS MetadataKey.rawValue 完全一致，保证迁移后
 * 历史数据可互读。键编号 5 在 iOS 中未使用（保留空洞），这里同样跳过。
 */
public class MetadataKey {
    public static let USER_VERSION: Int64 = 1
    public static let STATE: Int64 = 2
    public static let TRANSACTION_STATE_VERSION: Int64 = 3
    public static let MASTER_CLIENT_ID: Int64 = 4
    public static let REMOTE_CONTACT_COUNT: Int64 = 6
}

// state blob 在 PostboxEncoder 中承载的字段 key（仅本表内部使用，与 iOS 的
// encodeRootObject 字节往返语义对齐：把 blob 当作单字段编码再取回）。
let METADATA_STATE_FIELD = "s"

/**
 * 元数据表。
 *
 * 建在固定 id（TableRegistry.METADATA_TABLE_ID）的 int64 键表上，提供 userVersion /
 * state / masterClientId / transactionStateVersion / remoteContactCount 的读写。
 *
 * 依赖一个已 open 的 PostboxDatabase（RdbValueBox 复用其句柄）；未 open 时底层
 * 数据操作会抛 PostboxDatabaseException。
 */
public class MetadataTable {
    private let valueBox: ValueBox
    private let database: PostboxDatabase
    private let table: ValueBoxTable

    // state 内存缓存（对应 iOS cachedState）：避免重复反序列化；setState 时刷新。
    private var cachedState: Option<Array<Byte>> = None
    // remoteContactCount 内存缓存（对应 iOS cachedRemoteContactCount）。
    private var cachedRemoteContactCount: Option<Int32> = None

    /**
     * 用默认单例（RdbValueBox + PostboxDatabase）构造。
     */
    public init() {
        this(RdbValueBox.getInstance(), PostboxDatabase.getInstance())
    }

    /**
     * 显式注入 valueBox / database（便于诊断或自检时替换）。
     */
    public init(valueBox: ValueBox, database: PostboxDatabase) {
        this.valueBox = valueBox
        this.database = database
        this.table = ValueBoxTable(id: TableRegistry.METADATA_TABLE_ID, keyType: ValueBoxKeyType.Int64Key)
    }

    /**
     * 由 MetadataKey 编号构造 8 字节大端键（对应 iOS key(_:)）。
     */
    private func makeKey(keyId: Int64): ValueBoxKey {
        let k = ValueBoxKey(length: 8)
        k.setInt64(0, keyId)
        return k
    }

    // ---- userVersion（委托 PRAGMA，与 iOS 一致） ----

    /**
     * 读取库版本（对应 iOS userVersion()）。委托 PostboxDatabase 的 PRAGMA user_version。
     */
    public func userVersion(): Int32 {
        return this.database.userVersion()
    }

    /**
     * 写入库版本（对应 iOS setUserVersion(_:)）。委托 PostboxDatabase 的 PRAGMA。
     * @return true 成功 / false 失败（与底层 execute 对齐）。
     */
    public func setUserVersion(version: Int32): Bool {
        return this.database.setUserVersion(version)
    }

    // ---- state（经 PostboxEncoder 序列化往返） ----

    /**
     * 读取顶层同步状态 blob（对应 iOS state()）。
     *
     * 命中时把表里存的字节经 PostboxDecoder 取回原始 blob；未命中返回 None。
     * 带内存缓存（对应 iOS cachedState）。
     */
    public func state(): Option<Array<Byte>> {
        match (this.cachedState) {
            case Some(cached) => return Some(cached)
            case None => ()
        }
        match (this.valueBox.get(this.table, this.makeKey(MetadataKey.STATE))) {
            case Some(stored) =>
                let decoder = PostboxDecoder(stored)
                match (decoder.decodeOptionalBytes(METADATA_STATE_FIELD)) {
                    case Some(blob) =>
                        this.cachedState = Some(blob)
                        return Some(blob)
                    case None => return None
                }
            case None => return None
        }
    }

    /**
     * 写入顶层同步状态 blob（对应 iOS setState(_:)）。
     *
     * blob 经 PostboxEncoder 序列化后存入表（对应 iOS encodeRootObject 的字节往返），
     * 并刷新内存缓存。
     */
    public func setState(state: Array<Byte>): Unit {
        this.cachedState = Some(state)
        let encoder = PostboxEncoder()
        encoder.encodeBytes(state, key: METADATA_STATE_FIELD)
        this.valueBox.set(this.table, this.makeKey(MetadataKey.STATE), encoder.makeBytes())
    }

    // ---- masterClientId（Int64 大端字节存取） ----

    /**
     * 读取 masterClientId（对应 iOS masterClientId()）。未设置时返回 0。
     */
    public func masterClientId(): Int64 {
        match (this.valueBox.get(this.table, this.makeKey(MetadataKey.MASTER_CLIENT_ID))) {
            case Some(bytes) => return this.bytesToInt64(bytes)
            case None => return 0
        }
    }

    /**
     * 写入 masterClientId（对应 iOS setMasterClientId(_:)）。
     */
    public func setMasterClientId(id: Int64): Unit {
        this.valueBox.set(this.table, this.makeKey(MetadataKey.MASTER_CLIENT_ID), this.int64ToBytes(id))
    }

    // ---- transactionStateVersion（自增计数，Int64 大端字节存取） ----

    /**
     * 读取事务状态版本（对应 iOS transactionStateVersion()）。未设置时返回 0。
     * 供后续视图层判脏（每次状态变更自增）。
     */
    public func transactionStateVersion(): Int64 {
        match (this.valueBox.get(this.table, this.makeKey(MetadataKey.TRANSACTION_STATE_VERSION))) {
            case Some(bytes) => return this.bytesToInt64(bytes)
            case None => return 0
        }
    }

    /**
     * 自增事务状态版本并返回新值（对应 iOS incrementTransactionStateVersion()）。
     */
    public func incrementTransactionStateVersion(): Int64 {
        let next = this.transactionStateVersion() + 1
        this.valueBox.set(this.table, this.makeKey(MetadataKey.TRANSACTION_STATE_VERSION), this.int64ToBytes(next))
        return next
    }

    // ---- remoteContactCount（Int32 大端字节存取，对应 iOS）----

    /**
     * 读取远端联系人计数（对应 iOS getRemoteContactCount()）。未设置时返回 0。带缓存。
     */
    public func getRemoteContactCount(): Int32 {
        match (this.cachedRemoteContactCount) {
            case Some(cached) => return cached
            case None => ()
        }
        let result: Int32 = match (this.valueBox.get(this.table, this.makeKey(MetadataKey.REMOTE_CONTACT_COUNT))) {
            case Some(bytes) => this.bytesToInt32(bytes)
            case None => 0
        }
        this.cachedRemoteContactCount = Some(result)
        return result
    }

    /**
     * 写入远端联系人计数（对应 iOS setRemoteContactCount(_:)）。刷新缓存。
     */
    public func setRemoteContactCount(count: Int32): Unit {
        this.cachedRemoteContactCount = Some(count)
        this.valueBox.set(this.table, this.makeKey(MetadataKey.REMOTE_CONTACT_COUNT), this.int32ToBytes(count))
    }

    /**
     * 清内存缓存（对应 iOS clearMemoryCache()）。
     */
    public func clearMemoryCache(): Unit {
        this.cachedState = None
        this.cachedRemoteContactCount = None
    }

    // ---- 标量 <-> 字节（大端，复用 ValueBoxKey 已验证的大端读写） ----

    private func int64ToBytes(value: Int64): Array<Byte> {
        let k = ValueBoxKey(length: 8)
        k.setInt64(0, value)
        return k.toBytes()
    }

    private func bytesToInt64(bytes: Array<Byte>): Int64 {
        let k = ValueBoxKey(bytes: bytes)
        return k.getInt64(0)
    }

    private func int32ToBytes(value: Int32): Array<Byte> {
        let k = ValueBoxKey(length: 4)
        k.setInt32(0, value)
        return k.toBytes()
    }

    private func bytesToInt32(bytes: Array<Byte>): Int32 {
        let k = ValueBoxKey(bytes: bytes)
        return k.getInt32(0)
    }

    /**
     * 往返一致性自检（验收项②）：userVersion / state / masterClientId /
     * transactionStateVersion 读回写入一致，state 经 Encoder 往返。
     *
     * 需要一个已 open 的 PostboxDatabase（真实 RDB），因此只在设备/集成诊断时
     * 显式调用，不在 app 主流程自动运行（与 RdbValueBox.selfCheck 的定位一致）。
     * 全部断言通过返回 true，任一不符返回 false。
     */
    public func selfCheck(): Bool {
        try {
            // userVersion 往返（PRAGMA）
            if (!this.setUserVersion(42)) { return false }
            if (this.userVersion() != 42) { return false }

            // masterClientId 往返
            this.setMasterClientId(0x0102030405060708)
            if (this.masterClientId() != 0x0102030405060708) { return false }

            // transactionStateVersion 自增
            let base = this.transactionStateVersion()
            let next = this.incrementTransactionStateVersion()
            if (next != base + 1) { return false }
            if (this.transactionStateVersion() != base + 1) { return false }

            // state 经 Encoder 往返（含清缓存后从 DB 重读）
            let blob: Array<Byte> = [0u8, 255u8, 7u8, 128u8, 1u8]
            this.setState(blob)
            this.clearMemoryCache()
            match (this.state()) {
                case Some(got) =>
                    if (got.size != blob.size) { return false }
                    for (i in 0..blob.size) {
                        if (got[i] != blob[i]) { return false }
                    }
                case None => return false
            }

            // remoteContactCount 往返
            this.setRemoteContactCount(123)
            this.clearMemoryCache()
            if (this.getRemoteContactCount() != 123) { return false }

            return true
        } catch (e: Exception) {
            return false
        }
    }
}
