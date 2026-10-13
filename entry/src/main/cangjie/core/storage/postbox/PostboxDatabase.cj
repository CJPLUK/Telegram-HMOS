package ohos_app_cangjie_entry.core.storage.postbox

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import ohos.business_exception.BusinessException

/**
 * PostboxDatabase —— Postbox 持久化层的 RDB 连接/生命周期底座。
 *
 * iOS 标尺：
 *   - Telegram-iOS/submodules/Postbox/Sources/Database.swift
 *       SQLite 句柄 open/close/exec 薄封装（sqlite3_open_v2 / sqlite3_exec / sqlite3_close）。
 *   - Telegram-iOS/submodules/Postbox/Sources/SqliteValueBox.swift
 *       建库、PRAGMA user_version 版本管理（"PRAGMA user_version=123" 写 / 查询读）。
 *
 * 鸿蒙等价实现：
 *   iOS 直接持有 SQLite 裸句柄（OpaquePointer）；鸿蒙没有暴露裸 SQLite 句柄，
 *   官方关系型数据库走 @ohos.data.relationalStore（kit.ArkData）：
 *     - getRdbStore(context, StoreConfig) 创建/打开 RdbStore（句柄）
 *     - RdbStore.executeSql(sql)  执行无返回 SQL（建表 / PRAGMA 写）
 *     - RdbStore.querySql(sql) -> ResultSet  执行查询（PRAGMA 读 / SELECT）
 *   API 写法严格对齐工程内既有实证：bindings/ContactsHelperBinding.cj
 *   （唯一的 relationalStore 用法）以及 KB 官方示例。
 *
 * 与 iOS 的语义映射：
 *   Database.init(location, readOnly) <-> open(context)（StoreConfig.name = "postbox.db"）
 *   Database.execute(SQL)            <-> execute(sql)（成功 true / 失败 false）
 *   sqlite3_exec(查询)               <-> querySql(sql) -> ResultSet
 *   PRAGMA user_version 读写         <-> userVersion() / setUserVersion(v)
 *   deinit { sqlite3_close }         <-> close()（释放 store 句柄引用）
 *
 * 上下文（Context）说明：
 *   RdbStore 需要 UIAbilityContext。本类沿用工程惯例——context 由调用方
 *   （MainAbility.onWindowStageCreate 期间拿到的 globalAbilityContext）显式传入 open()，
 *   避免与 ability 层产生循环依赖（与 AuthStorage.initialize(context) / ContactsHelperBinding 一致）。
 *
 * MTProto 说明（N/A）：本地持久化 DB 底座，不涉及 MTProto 协议。
 */

// Postbox 主数据库文件名（应用沙箱内，对应 iOS 的 postbox/db_sqlite）
let POSTBOX_DB_NAME = "postbox.db"

/**
 * PostboxDatabase 相关错误。
 * 与本包惯例一致（BufferReadException / PostboxCodingException / ValueBoxKeyException）：
 * 逻辑错误用 Exception 子类显式抛出，便于调用方捕获。
 */
public class PostboxDatabaseException <: Exception {
    public init(message: String) {
        super(message)
    }
}

private var _postboxDatabaseInstance: Option<PostboxDatabase> = None

/**
 * 获取 PostboxDatabase 单例（对应 iOS 进程内单一 Postbox SQLite 连接）。
 */
public func getPostboxDatabase(): PostboxDatabase {
    match (_postboxDatabaseInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PostboxDatabase()
            _postboxDatabaseInstance = Some(inst)
            return inst
    }
}

/**
 * Postbox RDB 连接/生命周期底座。
 *
 * 持有一个打开着的 RdbStore 句柄，提供建表/PRAGMA 的 execute、查询的 querySql、
 * 以及 user_version 读写。未 open（句柄缺失）时所有数据操作抛 PostboxDatabaseException。
 */
public class PostboxDatabase {
    // 已打开的 RDB 句柄；None 表示尚未 open 或已 close。
    private var store: Option<RdbStore> = None

    public init() {}

    /**
     * 获取单例（与本包/工程其它存储类的 getInstance() 命名惯例对齐）。
     */
    public static func getInstance(): PostboxDatabase {
        return getPostboxDatabase()
    }

    /**
     * 打开/建库（对应 iOS Database.init(location, readOnly:false)）。
     *
     * 用 getRdbStore(context, StoreConfig(RelationalStoreSecurityLevel.S1, name: "postbox.db"))
     * 在应用沙箱内创建或打开 postbox.db，持有返回的 RdbStore 句柄。
     * 重复调用 open 是幂等的：底层 getRdbStore 对已存在文件即"打开已有"。
     *
     * @param context UIAbilityContext（由调用方传入，见类注释）
     * @throws PostboxDatabaseException 打开失败（底层 BusinessException 转译）
     */
    public func open(context: UIAbilityContext): Unit {
        try {
            let config = StoreConfig(
                RelationalStoreSecurityLevel.S1,
                name: POSTBOX_DB_NAME
            )
            let db: RdbStore = getRdbStore(context, config)
            this.store = Some(db)
            Hilog.info(0, "CjTelegram", "[PostboxDatabase] opened postbox.db")
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[PostboxDatabase] open failed code=${e.code} ${e.message}")
            throw PostboxDatabaseException("PostboxDatabase.open failed: ${e.message}")
        }
    }

    /**
     * 是否已打开（持有有效句柄）。
     */
    public func isOpen(): Bool {
        match (this.store) {
            case Some(_) => return true
            case None => return false
        }
    }

    /**
     * 取回已打开的 store 句柄；未 open 则抛异常。
     * 供需要直接操作 RdbStore（insert/update/delete/predicates 等）的上层使用。
     */
    public func getStore(): RdbStore {
        match (this.store) {
            case Some(db) => return db
            case None => throw PostboxDatabaseException("PostboxDatabase not open: call open(context) first")
        }
    }

    /**
     * 执行无返回 SQL（建表 / PRAGMA 写 / DDL）。
     * 对应 iOS Database.execute(SQL) -> Bool。
     *
     * 底层走 RdbStore.executeSql(sql)（不支持查询/附加库/事务/分号多语句，见 KB）。
     * 成功返回 true；底层抛 BusinessException 时返回 false（与 iOS 失败返回 false 对齐）。
     *
     * @param sql 要执行的单条 SQL 语句
     * @return true 成功 / false 失败
     * @throws PostboxDatabaseException 当未 open 时
     */
    public func execute(sql: String): Bool {
        let db = this.getStore()
        try {
            db.executeSql(sql)
            return true
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[PostboxDatabase] execute failed code=${e.code} ${e.message}")
            return false
        }
    }

    /**
     * 执行查询并返回 ResultSet（对应 iOS 中基于 sqlite3 的 SELECT/PRAGMA 读）。
     * 调用方负责对返回的 ResultSet 调用 goToFirstRow/goToNextRow 遍历并 close()。
     *
     * @param sql 查询 SQL
     * @return ResultSet（结果集句柄）
     * @throws PostboxDatabaseException 当未 open 时
     */
    public func querySql(sql: String): ResultSet {
        let db = this.getStore()
        return db.querySql(sql)
    }

    /**
     * 读取 PRAGMA user_version（对应 iOS SqliteValueBox 的版本读取）。
     *
     * 执行 querySql("PRAGMA user_version")，取第一行第一列。SQLite 的 user_version
     * 默认 0（新库未设置时）。读取失败/空结果时返回 0。
     *
     * @return 当前 user_version
     */
    public func userVersion(): Int32 {
        var version: Int32 = 0
        let cursor = this.querySql("PRAGMA user_version")
        try {
            // 空结果集在鸿蒙 RDB 上会抛 14800012 而非返回 false，故走 safeGoToFirstRow
            // （详见 RdbValueBox.safeGoToFirstRow 的说明）。此处本就以 0 作兜底，
            // 修正后不再误打 error 日志。
            if (RdbValueBox.safeGoToFirstRow(cursor)) {
                // PRAGMA user_version 结果列名即 "user_version"
                let idx = cursor.getColumnIndex("user_version")
                let v = cursor.getLong(idx)
                version = Int32(v)
            }
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[PostboxDatabase] userVersion read failed code=${e.code} ${e.message}")
        } finally {
            cursor.close()
        }
        return version
    }

    /**
     * 写 PRAGMA user_version（对应 iOS "PRAGMA user_version=123"）。
     *
     * PRAGMA 的赋值语法不接受占位符绑定，因此把整数值直接拼进语句
     * （v 为 Int32，无 SQL 注入面）。
     *
     * @param v 目标版本号
     * @return true 成功 / false 失败
     * @throws PostboxDatabaseException 当未 open 时
     */
    public func setUserVersion(v: Int32): Bool {
        return this.execute("PRAGMA user_version=" + v.toString())
    }

    /**
     * 关闭/释放句柄（对应 iOS deinit { sqlite3_close(handle) }）。
     *
     * 鸿蒙 RdbStore 句柄的实际资源由运行时按引用管理；这里释放本类对句柄的引用，
     * 使后续数据操作回到"未 open"语义（再次使用前需重新 open）。
     */
    public func close(): Unit {
        match (this.store) {
            case Some(_) =>
                this.store = None
                Hilog.info(0, "CjTelegram", "[PostboxDatabase] closed postbox.db")
            case None => ()
        }
    }
}
