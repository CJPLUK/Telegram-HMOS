package ohos_app_cangjie_entry.core.storage.postbox

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import ohos.business_exception.BusinessException
import std.collection.HashMap
import std.collection.HashSet
import std.collection.ArrayList

/**
 * RdbValueBox —— 基于 PostboxDatabase（鸿蒙 RDB）实现的通用 KV 引擎。
 *
 * iOS 标尺：Telegram-iOS/submodules/Postbox/Sources/SqliteValueBox.swift。
 *   iOS 用裸 SQLite 句柄 + sqlite3_prepare/bind/step 实现 get/set/remove/exists/count/range/scan；
 *   每张逻辑表对应物理表 `t<id>`，惰性建表。
 *
 * 鸿蒙等价（API 全部经 cangjie-kb relationalstore 官方文档实证，并对齐工程内
 * bindings/ContactsHelperBinding.cj 的既有 RDB 用法）：
 *   - 建表 / 删除（无返回 SQL）：RdbStore.executeSql(sql, bindArgs!)（KB Example 96/97/99）
 *   - 写入（INSERT OR REPLACE）：RdbStore.insert(table, ValuesBucket,
 *         conflict: ConflictResolution.OnConflictReplace)（KB Example 98/99）
 *   - 查询：RdbStore.querySql(sql, bindArgs!): ResultSet（KB Example 106/107）
 *   - 值类型：RelationalStoreValueType.Uint8Array(Array<UInt8>) 承载 BLOB，
 *         .Integer(Int64) 承载 int64 键（KB Example 221/228）
 *   - 读结果：ResultSet.getBlob(idx): Array<UInt8>（KB Example 130）、
 *         getLong(idx): Int64（KB Example 133）、getColumnIndex(name): Int32（KB Example 132）、
 *         goToFirstRow()/goToNextRow(): Bool —— **但仅在有行时**。二者在越界
 *         （空结果集 / 已过最后一行）时都抛 BusinessException 14800012，而非返回 false，
 *         这与 SQLite 的 sqlite3_step() 语义不同。故本类一律经
 *         safeGoToFirstRow / safeGoToNextRow 调用，切勿裸调。
 *         （原注释"见 ContactsHelperBinding 实证"取样自非空结果集，漏掉了越界分支，
 *           曾致本地会话缓存永久死锁 —— 详见两个 safe* 方法的说明。）
 *
 * 大端键 ↔ BLOB 字节序的 range 正确性（核心）：
 *   ValueBoxKey 以「固定长度大端字节」存键，字节字典序 == 逻辑数值序。键以
 *   Uint8Array(BLOB) 原样绑定/读取，SQLite 对 BLOB 列用 memcmp 比较，故
 *   `WHERE key > ? AND key < ? ORDER BY key ASC` 返回的就是正确的逻辑升序区间。
 *   实现里键全程走 BLOB，绝不转 TEXT/INTEGER（int64 表除外，其键本身是整型主键）。
 *
 * 单例：与 PostboxDatabase/PostboxTransaction 一致（进程内单 DB 连接），
 *   共享「已建表集合」缓存以惰性建表去重。
 *
 * MTProto 说明（N/A）：本地持久化 KV 引擎，不涉及 MTProto 协议。
 */

/**
 * RdbValueBox 相关错误（与本包惯例一致：PostboxDatabaseException /
 * ValueBoxKeyException 等均为 Exception 子类，便于调用方捕获）。
 */
public class ValueBoxException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/**
 * 鸿蒙 RDB 错误码：ResultSet 游标越界。
 * 在**空结果集**上调用 goToFirstRow() 即抛此码（而非返回 false）——
 * 这是与 SQLite（iOS 侧）最关键的行为差异，详见 RdbValueBox.safeGoToFirstRow。
 */
private let ERR_ROW_OUT_OF_BOUNDS: Int32 = 14800012

private var _rdbValueBoxInstance: Option<RdbValueBox> = None

/**
 * 获取 RdbValueBox 单例。
 */
public func getRdbValueBox(): RdbValueBox {
    match (_rdbValueBoxInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = RdbValueBox()
            _rdbValueBoxInstance = Some(inst)
            return inst
    }
}

public class RdbValueBox <: ValueBox {
    // 已建表的表 id 集合（惰性建表去重，对应 iOS tables 缓存）。
    private let createdTables: HashSet<Int32> = HashSet<Int32>()

    public init() {}

    /**
     * 获取单例（与本包 getInstance() 命名惯例对齐）。
     */
    public static func getInstance(): RdbValueBox {
        return getRdbValueBox()
    }

    /**
     * 取回已打开的 RdbStore 句柄（复用 PostboxDatabase 单例）。
     * 未 open 时由 PostboxDatabase 抛 PostboxDatabaseException。
     */
    private func store(): RdbStore {
        return PostboxDatabase.getInstance().getStore()
    }

    /**
     * 物理表名 `t<id>`（与 iOS 完全一致）。
     */
    private func tableName(table: ValueBoxTable): String {
        return "t" + table.id.toString()
    }

    /**
     * 键 -> RDB 绑定值。
     *   - Binary 键：Uint8Array(BLOB)，保留大端字节序。
     *   - Int64  键：Integer，取键前 8 字节大端组装的 Int64（对齐 iOS bind number）。
     */
    private func bindKey(table: ValueBoxTable, key: ValueBoxKey): RelationalStoreValueType {
        match (table.keyType) {
            case BinaryKey => return RelationalStoreValueType.Uint8Array(key.toBytes())
            case Int64Key => return RelationalStoreValueType.Integer(key.getInt64(0))
        }
    }

    /**
     * ResultSet 当前行的 "key" 列 -> ValueBoxKey。
     *   - Binary 表：getBlob 取回大端字节，原样构键。
     *   - Int64  表：getLong 取回 Int64，大端写入 8 字节键（与 bindKey 对称）。
     */
    private func readKey(table: ValueBoxTable, cursor: ResultSet): ValueBoxKey {
        let idx = cursor.getColumnIndex("key")
        match (table.keyType) {
            case BinaryKey =>
                let bytes = cursor.getBlob(idx)
                return ValueBoxKey(bytes: bytes)
            case Int64Key =>
                let v = cursor.getLong(idx)
                let k = ValueBoxKey(length: 8)
                k.setInt64(0, v)
                return k
        }
    }

    /**
     * 惰性建表（对应 iOS checkTable）。
     * binary 键：key BLOB PRIMARY KEY；int64 键：key INTEGER PRIMARY KEY。value BLOB。
     * 已建过则跳过 DDL。
     */
    public func checkTable(table: ValueBoxTable): Unit {
        if (this.createdTables.contains(table.id)) {
            return
        }
        let name = this.tableName(table)
        let keyDecl = match (table.keyType) {
            case BinaryKey => "key BLOB PRIMARY KEY"
            case Int64Key => "key INTEGER PRIMARY KEY"
        }
        let sql = "CREATE TABLE IF NOT EXISTS " + name + " (" + keyDecl + ", value BLOB)"
        try {
            this.store().executeSql(sql)
            this.createdTables.add(table.id)
            Hilog.info(0, "CjTelegram", "[RdbValueBox] checkTable ${name} ready")
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[RdbValueBox] checkTable ${name} failed code=${e.code} ${e.message}")
            throw ValueBoxException("RdbValueBox.checkTable(${name}) failed: ${e.message}")
        }
    }

    /**
     * 安全地把游标移到首行；结果集为空时返回 false 而非抛异常。
     *
     * 【为什么需要它】鸿蒙 RDB 与 SQLite 的**空结果集契约不同**：
     *   - SQLite（iOS 侧）：sqlite3_step() 无行时返回 SQLITE_DONE，即 Bool false。
     *     故 SqliteValueBox.swift:1651 可以直接写 `while statement.step() { ... }`，
     *     空集天然走"循环体一次都不进"，是正常控制流。
     *   - 鸿蒙 RDB：ResultSet.goToFirstRow() 在无行时**抛 BusinessException
     *     code=14800012「Row out of bounds」**。
     *
     * 本类照搬 iOS 结构写成 `if (cursor.goToFirstRow()) { ... }`，本意正是"空集就跳过"，
     * 但在鸿蒙上这个 if 的条件求值本身就先抛了，if 根本没机会取到 false。
     * 结果：任何针对空表的 get/exists/count/range/scan 都会抛异常。
     *
     * 【实际后果】ChatListStore.storeChats 是"先扫描清旧键(Step 1)、再写新批次(Step 2)"，
     * Step 1 在空表上抛 → Step 2 永远执行不到 → 表永远是空的 → 下次仍然抛。
     * 形成永久死锁，本地会话缓存从未成功写入过一条。
     *
     * 空集是正常语义、不是错误，故这里把 14800012 归一化为 false；其余错误码照常上抛，
     * 不掩盖真实的 DB 故障。
     */
    public static func safeGoToFirstRow(cursor: ResultSet): Bool {
        try {
            return cursor.goToFirstRow()
        } catch (e: BusinessException) {
            if (e.code == ERR_ROW_OUT_OF_BOUNDS) {
                // 空结果集 —— 等价于 SQLite 的 SQLITE_DONE
                return false
            }
            throw e
        }
    }

    /**
     * 安全地把游标移到下一行；已到末尾时返回 false 而非抛异常。
     *
     * 与 safeGoToFirstRow 同源的契约差异：鸿蒙 RDB 的 goToNextRow() 在**遍历越过最后一行**时
     * 同样抛 BusinessException 14800012，而 SQLite 的 sqlite3_step() 只是返回 SQLITE_DONE。
     *
     * 【为什么这一处极易被误判为"无需保护"】ContactsHelperBinding.enumerateContacts 表面上
     * 工作正常（真机可加载 13 个联系人），据此曾推断 goToNextRow 在末尾返回 false。
     * 实则不然：异常发生在 13 行**全部回调完毕之后**，被该函数外层的 try/catch 吞掉、
     * 只是让返回值变成 -1，而 onContact 回调早已把 13 条数据交给了 UI。
     * 于是"看起来成功"，实际每次枚举都以异常收尾。这类假阳性正是本保护存在的理由。
     */
    public static func safeGoToNextRow(cursor: ResultSet): Bool {
        try {
            return cursor.goToNextRow()
        } catch (e: BusinessException) {
            if (e.code == ERR_ROW_OUT_OF_BOUNDS) {
                // 已遍历完最后一行 —— 等价于 SQLite 的 SQLITE_DONE
                return false
            }
            throw e
        }
    }

    /**
     * 读取单键的值（对应 iOS get）。命中 Some(字节) / 未命中 None。
     * 走参数化 querySql("SELECT value FROM t<id> WHERE key=?")，键以 BLOB/Integer 绑定。
     */
    public func get(table: ValueBoxTable, key: ValueBoxKey): Option<Array<Byte>> {
        this.checkTable(table)
        let sql = "SELECT value FROM " + this.tableName(table) + " WHERE key = ?"
        let cursor = this.store().querySql(sql, bindArgs: [this.bindKey(table, key)])
        try {
            if (RdbValueBox.safeGoToFirstRow(cursor)) {
                let vIdx = cursor.getColumnIndex("value")
                let bytes = cursor.getBlob(vIdx)
                return Some(bytes)
            }
            return None
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[RdbValueBox] get failed code=${e.code} ${e.message}")
            throw ValueBoxException("RdbValueBox.get failed: ${e.message}")
        } finally {
            cursor.close()
        }
    }

    /**
     * 写入单键（INSERT OR REPLACE 语义，对应 iOS set）。
     * 走 insert(table, ValuesBucket, conflict: OnConflictReplace)：主键冲突时整行覆盖，
     * 等价 iOS 的 "INSERT ... ON CONFLICT(key) DO UPDATE SET value=excluded.value"。
     */
    public func set(table: ValueBoxTable, key: ValueBoxKey, value: Array<Byte>): Unit {
        this.checkTable(table)
        let row = HashMap<String, RelationalStoreValueType>()
        row.add("key", this.bindKey(table, key))
        row.add("value", RelationalStoreValueType.Uint8Array(value))
        try {
            let _ = this.store().insert(this.tableName(table), row, conflict: ConflictResolution.OnConflictReplace)
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[RdbValueBox] set failed code=${e.code} ${e.message}")
            throw ValueBoxException("RdbValueBox.set failed: ${e.message}")
        }
    }

    /**
     * 删除单键（对应 iOS remove）。走参数化 executeSql("DELETE ... WHERE key=?")。
     */
    public func remove(table: ValueBoxTable, key: ValueBoxKey): Unit {
        this.checkTable(table)
        let sql = "DELETE FROM " + this.tableName(table) + " WHERE key = ?"
        try {
            this.store().executeSql(sql, bindArgs: [this.bindKey(table, key)])
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[RdbValueBox] remove failed code=${e.code} ${e.message}")
            throw ValueBoxException("RdbValueBox.remove failed: ${e.message}")
        }
    }

    /**
     * 单键是否存在（对应 iOS exists）。SELECT 1 ... LIMIT 1，命中即存在。
     */
    public func exists(table: ValueBoxTable, key: ValueBoxKey): Bool {
        this.checkTable(table)
        let sql = "SELECT 1 FROM " + this.tableName(table) + " WHERE key = ? LIMIT 1"
        let cursor = this.store().querySql(sql, bindArgs: [this.bindKey(table, key)])
        try {
            return RdbValueBox.safeGoToFirstRow(cursor)
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[RdbValueBox] exists failed code=${e.code} ${e.message}")
            throw ValueBoxException("RdbValueBox.exists failed: ${e.message}")
        } finally {
            cursor.close()
        }
    }

    /**
     * 全表行数（对应 iOS count(table)）。SELECT COUNT(*)，取第一行第一列。
     */
    public func count(table: ValueBoxTable): Int64 {
        this.checkTable(table)
        let sql = "SELECT COUNT(*) AS c FROM " + this.tableName(table)
        let cursor = this.store().querySql(sql)
        try {
            if (RdbValueBox.safeGoToFirstRow(cursor)) {
                let idx = cursor.getColumnIndex("c")
                return cursor.getLong(idx)
            }
            return 0
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[RdbValueBox] count failed code=${e.code} ${e.message}")
            throw ValueBoxException("RdbValueBox.count failed: ${e.message}")
        } finally {
            cursor.close()
        }
    }

    /**
     * 有界范围扫描（仅键，对应 iOS range(keys:limit:)）。
     *
     * 区间「开-开」(key > start AND key < end)。方向：
     *   - start < end：ORDER BY key ASC，边界 (start, end)；
     *   - start > end：ORDER BY key DESC，边界交换为 (end, start)（等价 iOS else 分支）；
     *   - start == end：空区间，直接返回。
     * limit > 0 时附加 LIMIT；<=0 不限。回调返回 false 时提前停止。
     */
    public func range(table: ValueBoxTable, start: ValueBoxKey, end: ValueBoxKey, limit: Int64,
        keys: (ValueBoxKey) -> Bool): Unit {
        this.scanRangeImpl(table, start, end, limit, false, { k, _ => keys(k) })
    }

    /**
     * 有界范围扫描（键 + 值，对应 iOS range(values:limit:)）。
     */
    public func rangeValues(table: ValueBoxTable, start: ValueBoxKey, end: ValueBoxKey, limit: Int64,
        values: (ValueBoxKey, Array<Byte>) -> Bool): Unit {
        this.scanRangeImpl(table, start, end, limit, true, values)
    }

    /**
     * 全表扫描（升序，键 + 值，对应 iOS scan(values:)）。
     * SELECT key, value ... ORDER BY key ASC，无区间约束；回调 false 早停。
     */
    public func scan(table: ValueBoxTable, values: (ValueBoxKey, Array<Byte>) -> Bool): Unit {
        this.checkTable(table)
        let sql = "SELECT key, value FROM " + this.tableName(table) + " ORDER BY key ASC"
        let cursor = this.store().querySql(sql)
        try {
            if (RdbValueBox.safeGoToFirstRow(cursor)) {
                var hasMore = true
                while (hasMore) {
                    let k = this.readKey(table, cursor)
                    let vIdx = cursor.getColumnIndex("value")
                    let v = cursor.getBlob(vIdx)
                    if (!values(k, v)) {
                        break
                    }
                    hasMore = RdbValueBox.safeGoToNextRow(cursor)
                }
            }
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[RdbValueBox] scan failed code=${e.code} ${e.message}")
            throw ValueBoxException("RdbValueBox.scan failed: ${e.message}")
        } finally {
            cursor.close()
        }
    }

    /**
     * range / rangeValues 的共享实现。
     *
     * 拼参数化 SQL：SELECT key[, value] FROM t<id> WHERE key > ? AND key < ? ORDER BY key ASC|DESC [LIMIT ?]
     * 低界 lo / 高界 hi 始终满足 lo <= hi（按需交换 start/end），ASC/DESC 由原始方向决定。
     * 回调 cb 返回 false 时提前停止。
     *
     * 方向判定（对齐 iOS SqliteValueBox.swift:1663 / 1798）：
     *   - BinaryKey 表：字节字典序比较（start < end），与 iOS .binary 分支 start < end 一致。
     *   - Int64Key  表：有符号整数比较（start.getInt64(0) < end.getInt64(0)），对齐 iOS .int64
     *     分支的 start.reversed < end.reversed 语义——iOS 的 reversed 是大端字节反转，反转后
     *     字节比较等价于 UInt64 比较，而 Int64 有符号序与 UInt64 无符号序对负数不同；但 Postbox
     *     所有 int64 表的实际调用方（MessageHistoryTable 等）传入的 MessageId.id 均为非负值，
     *     getInt64 直接有符号比较在非负域与 iOS reversed 语义完全一致，且 SQLite INTEGER 列
     *     以有符号整数排序，故此处用 getInt64 直接比较给出与 iOS 等价的方向判定。
     */
    private func scanRangeImpl(table: ValueBoxTable, start: ValueBoxKey, end: ValueBoxKey, limit: Int64,
        withValues: Bool, cb: (ValueBoxKey, Array<Byte>) -> Bool): Unit {
        this.checkTable(table)
        // start == end：开-开空区间，无可能命中。
        if (start == end) {
            return
        }
        // 方向判定：Int64Key 用有符号整数比较（对齐 iOS .int64 分支 start.reversed < end.reversed）；
        // BinaryKey 用字节字典序比较（对齐 iOS .binary 分支 start < end）。
        let ascending = match (table.keyType) {
            case Int64Key => start.getInt64(0) < end.getInt64(0)
            case BinaryKey => start < end
        }
        // 物理 SQL 的下界/上界始终是逻辑较小/较大者（开区间 key > lo AND key < hi）。
        let lo: ValueBoxKey
        let hi: ValueBoxKey
        if (ascending) {
            lo = start
            hi = end
        } else {
            lo = end
            hi = start
        }
        let order = if (ascending) { "ASC" } else { "DESC" }

        let cols = if (withValues) { "key, value" } else { "key" }
        var sql = "SELECT " + cols + " FROM " + this.tableName(table) +
            " WHERE key > ? AND key < ? ORDER BY key " + order
        let args: Array<RelationalStoreValueType>
        if (limit > 0) {
            sql += " LIMIT ?"
            args = [this.bindKey(table, lo), this.bindKey(table, hi),
                RelationalStoreValueType.Integer(limit)]
        } else {
            args = [this.bindKey(table, lo), this.bindKey(table, hi)]
        }

        let cursor = this.store().querySql(sql, bindArgs: args)
        try {
            if (RdbValueBox.safeGoToFirstRow(cursor)) {
                var hasMore = true
                while (hasMore) {
                    let k = this.readKey(table, cursor)
                    let v: Array<Byte>
                    if (withValues) {
                        let vIdx = cursor.getColumnIndex("value")
                        v = cursor.getBlob(vIdx)
                    } else {
                        v = Array<Byte>(0, repeat: 0)
                    }
                    if (!cb(k, v)) {
                        break
                    }
                    hasMore = RdbValueBox.safeGoToNextRow(cursor)
                }
            }
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[RdbValueBox] range failed code=${e.code} ${e.message}")
            throw ValueBoxException("RdbValueBox.range failed: ${e.message}")
        } finally {
            cursor.close()
        }
    }

    /**
     * 自检：在内存中验证「键序 / 上下界 / get-set-remove 往返」的逻辑正确性。
     *
     * 注意：本函数需要一个已 open 的 PostboxDatabase（真实 RDB），因此只在设备/集成
     * 诊断时显式调用，不在 app 主流程自动运行（与 ValueBoxKey.selfCheck 的定位一致）。
     * 用一张临时 binary 表，插入若干大端键，验证：
     *   ① set→get 往返一致；② remove 后 get 为空、exists=false；
     *   ③ count 正确；④ range 升序按键序、上下界为开区间。
     * 全部断言通过返回 true，任一不符返回 false。
     */
    public func selfCheck(): Bool {
        // 用一个不太可能与业务冲突的临时表 id。
        let table = ValueBoxTable(id: Int32(0x7FFF), keyType: ValueBoxKeyType.BinaryKey)
        try {
            this.checkTable(table)
            // 清场：删掉可能残留的 4 个键
            for (n in 1..5) {
                let k = ValueBoxKey(length: 8)
                k.setInt64(0, Int64(n))
                this.remove(table, k)
            }

            // 插入键 1,2,3,4（大端 8 字节），值为 [n]
            for (n in 1..5) {
                let k = ValueBoxKey(length: 8)
                k.setInt64(0, Int64(n))
                this.set(table, k, [UInt8(n)])
            }

            // ① set→get 往返
            let k2 = ValueBoxKey(length: 8)
            k2.setInt64(0, 2)
            match (this.get(table, k2)) {
                case Some(v) => if (v.size != 1 || v[0] != UInt8(2)) { return false }
                case None => return false
            }

            // ③ count == 4
            if (this.count(table) != 4) { return false }

            // ② remove(2) 后 get 为空、exists=false
            this.remove(table, k2)
            match (this.get(table, k2)) {
                case Some(_) => return false
                case None => ()
            }
            if (this.exists(table, k2)) { return false }
            if (this.count(table) != 3) { return false }

            // ④ range 升序：开区间 (1, 4) 应只返回键 3（2 已删，1/4 为开边界被排除）。
            let lo = ValueBoxKey(length: 8); lo.setInt64(0, 1)
            let hi = ValueBoxKey(length: 8); hi.setInt64(0, 4)
            let collected = ArrayList<Int64>()
            this.range(table, lo, hi, 0, { k =>
                collected.add(k.getInt64(0))
                true
            })
            if (collected.size != 1) { return false }
            if (collected[0] != 3) { return false }

            // 降序：range(4 -> 1) 开区间应返回 3,2... 但 2 已删，故 [3]，且方向为降序。
            let collectedDesc = ArrayList<Int64>()
            this.range(table, hi, lo, 0, { k =>
                collectedDesc.add(k.getInt64(0))
                true
            })
            if (collectedDesc.size != 1 || collectedDesc[0] != 3) { return false }

            // 清场
            for (n in 1..5) {
                let k = ValueBoxKey(length: 8)
                k.setInt64(0, Int64(n))
                this.remove(table, k)
            }
            return true
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[RdbValueBox] selfCheck failed: ${e.message}")
            return false
        }
    }
}
