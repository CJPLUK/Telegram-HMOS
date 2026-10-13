package ohos_app_cangjie_entry.core.storage.postbox

/**
 * ValueBox —— 通用 (table, key BLOB) -> value BLOB 键值引擎抽象。
 *
 * iOS 标尺：
 *   - Telegram-iOS/submodules/Postbox/Sources/ValueBox.swift
 *       ValueBoxKeyType { binary, int64 } 枚举、ValueBoxTable(id/keyType) 描述符、
 *       ValueBox 协议（get/set/remove/exists/count/range/scan）。
 *   - Telegram-iOS/submodules/Postbox/Sources/SqliteValueBox.swift
 *       每张逻辑表对应一张 SQLite 表 `t<id>`：
 *         binary 键：CREATE TABLE IF NOT EXISTS t<id>(key BLOB PRIMARY KEY, value BLOB)
 *         int64  键：CREATE TABLE IF NOT EXISTS t<id>(key INTEGER PRIMARY KEY, value BLOB)
 *       惰性建表（首次访问某表时 checkTable）。get/set/remove/exists/count/range/scan
 *       全部以表 id 为单位、以 BLOB 字节键参数化绑定。
 *
 * 鸿蒙等价实现：
 *   iOS 直接持有裸 SQLite 句柄 + sqlite3_prepare/bind/step；鸿蒙没有暴露裸句柄，
 *   官方关系型数据库 @ohos.data.relationalStore（kit.ArkData）的 RdbStore 提供
 *   等价能力：executeSql(sql, bindArgs) / querySql(sql, bindArgs) -> ResultSet /
 *   insert(table, ValuesBucket, conflict)。BLOB 经 RelationalStoreValueType.Uint8Array
 *   绑定、ResultSet.getBlob(idx) 读取。具体实现见 RdbValueBox.cj。
 *
 * 大端键 ↔ BLOB 排序的正确性（range 的根基）：
 *   ValueBoxKey 以「固定长度大端字节」存键（见 ValueBoxKey.cj），因此「字节字典序」
 *   == 「逻辑数值序」。把键以 BLOB（Uint8Array）原样存取后，SQLite 对 BLOB 列用
 *   memcmp 比较，`WHERE key > ? AND key < ? ORDER BY key ASC` 得到的就是正确的逻辑区间。
 *   绝不能把键转成 TEXT/INTEGER 存（会破坏字节序），必须走 BLOB。
 *
 * 本文件只定义「描述符 + 抽象接口」；RDB 落地在 RdbValueBox.cj。
 *
 * MTProto 说明（N/A）：本地持久化 KV 引擎，不涉及 MTProto 协议。
 */

/**
 * 键类型（对应 iOS ValueBoxKeyType）。
 *   - Binary：变长大端字节键，建表列为 `key BLOB PRIMARY KEY`。
 *   - Int64 ：8 字节 int64 键，建表列为 `key INTEGER PRIMARY KEY`
 *             （iOS 对 int64 表用 INTEGER 主键，省存储且整型主键 rowid 对齐）。
 *
 * 仓颉枚举语法：无参构造子，match 时用 `case BinaryKey`/`case Int64Key`。
 * 命名加 `Key` 后缀以避开仓颉保留关键字 `Int64`（裸 `Int64` 作枚举值名会与类型名冲突）。
 */
public enum ValueBoxKeyType {
    | BinaryKey
    | Int64Key
}

/**
 * 逻辑表描述符（对应 iOS ValueBoxTable）。
 *
 * - id：表 id，物理表名 `t<id>`（与 iOS 完全一致，保证迁移后表名兼容）。
 * - keyType：键类型，决定建表 DDL 与键的存取方式。
 *
 * iOS 的 compactValuesOnCreation 是 SQLite VACUUM/重建优化标志，与「逻辑 KV 语义」
 * 无关（仅影响首次建表是否压缩历史值），本底座暂不需要，省略以保持最小面。
 */
public class ValueBoxTable {
    public let id: Int32
    public let keyType: ValueBoxKeyType

    public init(id!: Int32, keyType!: ValueBoxKeyType) {
        this.id = id
        this.keyType = keyType
    }
}

/**
 * 通用 KV 引擎抽象接口（对应 iOS `protocol ValueBox` 的核心子集）。
 *
 * 只暴露「业务表（消息表/会话表/peer 表）实际依赖」的最小操作集：
 *   惰性建表 + 单键 get/set/remove/exists + 全表 count + 有界 range 扫描 + 全表 scan。
 * 全文检索 / 加密导出 / 跨表 copy / removeRange 等 iOS 高级能力不在本底座范围，
 * 后续按业务需要单独扩展（避免一次性铺开未被调用的面）。
 *
 * 仓颉用 `interface` 表达协议；range/scan 用闭包回调（与工程内既有闭包范式一致，
 * 见 PostboxTransaction.withTransaction 的 () -> T、Utils.collectionMap 的 (T) -> U）。
 */
public interface ValueBox {
    /**
     * 惰性建表（对应 iOS checkTable）：首次访问某表时 CREATE TABLE IF NOT EXISTS。
     * 已建过的表跳过 DDL（实现侧缓存表 id）。
     */
    func checkTable(table: ValueBoxTable): Unit

    /**
     * 读取单键的值（对应 iOS get）。命中返回 Some(字节)，未命中返回 None。
     */
    func get(table: ValueBoxTable, key: ValueBoxKey): Option<Array<Byte>>

    /**
     * 写入单键（INSERT OR REPLACE 语义，对应 iOS set）。已存在则覆盖。
     */
    func set(table: ValueBoxTable, key: ValueBoxKey, value: Array<Byte>): Unit

    /**
     * 删除单键（对应 iOS remove）。不存在则无副作用。
     */
    func remove(table: ValueBoxTable, key: ValueBoxKey): Unit

    /**
     * 单键是否存在（对应 iOS exists）。
     */
    func exists(table: ValueBoxTable, key: ValueBoxKey): Bool

    /**
     * 全表行数（对应 iOS count(table)）。
     */
    func count(table: ValueBoxTable): Int64

    /**
     * 有界范围扫描（对应 iOS range(keys:limit:)）。
     *
     * 语义严格对齐 iOS：区间「开-开」(`key > start AND key < end`)；
     *   - start < end：按 key 升序遍历；
     *   - start > end：按 key 降序遍历（内部交换边界，等价 iOS 的 if start < end 分支）；
     *   - start == end：空区间，不回调。
     * limit <= 0 表示不限条数（对应 iOS limit==0 走 NoLimit 语句）。
     * 回调返回 false 时提前停止扫描（对应 iOS keys 闭包返回 Bool 的早停）。
     *
     * @param keys 每个命中键的回调；返回 true 继续、false 停止。
     */
    func range(table: ValueBoxTable, start: ValueBoxKey, end: ValueBoxKey, limit: Int64,
        keys: (ValueBoxKey) -> Bool): Unit

    /**
     * 有界范围扫描（带值，对应 iOS range(values:limit:)）。
     * 区间/方向/limit/早停语义同上；回调附带该键的 value 字节。
     */
    func rangeValues(table: ValueBoxTable, start: ValueBoxKey, end: ValueBoxKey, limit: Int64,
        values: (ValueBoxKey, Array<Byte>) -> Bool): Unit

    /**
     * 全表扫描（升序，带值，对应 iOS scan(values:)）。
     * 回调返回 false 提前停止。
     */
    func scan(table: ValueBoxTable, values: (ValueBoxKey, Array<Byte>) -> Bool): Unit
}
