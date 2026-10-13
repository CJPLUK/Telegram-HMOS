package ohos_app_cangjie_entry.core.storage.postbox

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import ohos.business_exception.BusinessException

/**
 * PostboxTransaction —— Postbox 持久化层的 RDB 级原子事务壳（begin/commit/rollback）。
 *
 * iOS 标尺：
 *   Telegram-iOS/submodules/Postbox/Sources/SqliteValueBox.swift
 *     - begin()  -> database.execute("BEGIN IMMEDIATE")（读写）/ "BEGIN DEFERRED"（只读）
 *     - commit() -> database.execute("COMMIT")
 *     - rollback 路径 -> database.execute("ROLLBACK")
 *   iOS 用裸 SQLite，事务即向句柄发 BEGIN/COMMIT/ROLLBACK 三条 SQL，并以
 *   inImmediateTransaction 状态防止重复 begin。
 *
 * 鸿蒙等价实现（以实证可编译为准）：
 *   鸿蒙官方关系型数据库 @ohos.data.relationalStore（kit.ArkData）的 RdbStore 句柄
 *   暴露原生事务三件套（已由 cangjie-kb 官方 relationalstore 文档与示例实证）：
 *     - public func beginTransaction(): Unit
 *     - public func commit(): Unit
 *     - public func rollBack(): Unit
 *   官方示例典型用法（KB Example 88/90/110/111）：
 *     rdbStore.beginTransaction()
 *     rdbStore.insert(...); rdbStore.insert(...)
 *     rdbStore.commit()
 *     // catch 分支：rdbStore.rollBack()
 *   因此本壳直接走 RDB 原生事务 API，而不是手发 "BEGIN IMMEDIATE"/"COMMIT" SQL——
 *   原生 API 是 RDB 推荐方式且与 store 内部状态一致；execute(SQL) 路径仅作语义注释保留。
 *
 * 与 iOS 的语义映射：
 *   SqliteValueBox.begin()    <-> begin()    （store.beginTransaction()）
 *   SqliteValueBox.commit()   <-> commit()   （store.commit()）
 *   "ROLLBACK"                <-> rollback() （store.rollBack()）
 *   inImmediateTransaction    <-> _inTransaction（Bool 标志，嵌套保护）
 *   "一组写要么全成要么全滚"     <-> withTransaction { ... }
 *
 * 范围说明：本单元只做 RDB 级原子壳。完整 Transaction + operations 收集
 *   （供 ViewTracker 推送）是后续 epic（P2-288），本文件不碰 operations/视图。
 *
 * MTProto 说明（N/A）：本地持久化事务，不涉及 MTProto 协议。
 */

/**
 * PostboxTransaction 相关错误（与本包惯例一致：
 * PostboxDatabaseException / BufferReadException / ValueBoxKeyException
 * 均为 Exception 子类，便于调用方捕获）。
 */
public class PostboxTransactionException <: Exception {
    public init(message: String) {
        super(message)
    }
}

private var _postboxTransactionInstance: Option<PostboxTransaction> = None

/**
 * 获取 PostboxTransaction 单例。
 * 事务状态（是否已在事务中）是进程内单 DB 连接的全局状态，因此与
 * PostboxDatabase 单例一一对应，单例化以共享 _inTransaction 标志。
 */
public func getPostboxTransaction(): PostboxTransaction {
    match (_postboxTransactionInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PostboxTransaction()
            _postboxTransactionInstance = Some(inst)
            return inst
    }
}

/**
 * Postbox RDB 级原子事务壳。
 *
 * 薄封装 PostboxDatabase 持有的 RdbStore 句柄的原生事务三件套，
 * 给上层提供 begin/commit/rollback 以及 withTransaction 闭包入口
 * （"一组写要么全成要么全滚"）。带嵌套保护，避免重复 begin。
 */
public class PostboxTransaction {
    // 是否已处于事务中（对应 iOS inImmediateTransaction）。
    // RDB 不支持真正的嵌套事务，重复 begin 会出错，故用此标志拦截。
    private var _inTransaction: Bool = false

    public init() {}

    /**
     * 获取单例（与本包 getInstance() 命名惯例对齐）。
     */
    public static func getInstance(): PostboxTransaction {
        return getPostboxTransaction()
    }

    /**
     * 是否已在事务中。
     */
    public func isInTransaction(): Bool {
        return this._inTransaction
    }

    /**
     * 取回当前已打开的 RdbStore 句柄。
     * 复用已合入 master 的 PostboxDatabase：getInstance().getStore()，
     * 未 open 时由 PostboxDatabase 抛 PostboxDatabaseException。
     */
    private func store(): RdbStore {
        return PostboxDatabase.getInstance().getStore()
    }

    /**
     * 开启事务（对应 iOS begin() -> "BEGIN IMMEDIATE"）。
     *
     * 走 RDB 原生 store.beginTransaction()。若当前已在事务中（嵌套保护），
     * 直接抛 PostboxTransactionException，避免对 store 重复 beginTransaction。
     *
     * @throws PostboxTransactionException 已在事务中，或底层 RDB 失败
     */
    public func begin(): Unit {
        if (this._inTransaction) {
            throw PostboxTransactionException("PostboxTransaction.begin: already in a transaction (nested begin not allowed)")
        }
        let db = this.store()
        try {
            db.beginTransaction()
            this._inTransaction = true
            Hilog.info(0, "CjTelegram", "[PostboxTransaction] begin")
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[PostboxTransaction] begin failed code=${e.code} ${e.message}")
            throw PostboxTransactionException("PostboxTransaction.begin failed: ${e.message}")
        }
    }

    /**
     * 提交事务（对应 iOS commit() -> "COMMIT"）。
     *
     * 走 RDB 原生 store.commit()。未在事务中则抛异常（无事务可提交）。
     * 无论成功/失败，提交后都清除 _inTransaction（事务边界已结束）。
     *
     * @throws PostboxTransactionException 不在事务中，或底层 RDB 失败
     */
    public func commit(): Unit {
        if (!this._inTransaction) {
            throw PostboxTransactionException("PostboxTransaction.commit: not in a transaction")
        }
        let db = this.store()
        try {
            db.commit()
            Hilog.info(0, "CjTelegram", "[PostboxTransaction] commit")
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[PostboxTransaction] commit failed code=${e.code} ${e.message}")
            throw PostboxTransactionException("PostboxTransaction.commit failed: ${e.message}")
        } finally {
            this._inTransaction = false
        }
    }

    /**
     * 回滚事务（对应 iOS "ROLLBACK"）。
     *
     * 走 RDB 原生 store.rollBack()。未在事务中则抛异常（无事务可回滚）。
     * 无论成功/失败，回滚后都清除 _inTransaction（事务边界已结束）。
     *
     * @throws PostboxTransactionException 不在事务中，或底层 RDB 失败
     */
    public func rollback(): Unit {
        if (!this._inTransaction) {
            throw PostboxTransactionException("PostboxTransaction.rollback: not in a transaction")
        }
        let db = this.store()
        try {
            db.rollBack()
            Hilog.info(0, "CjTelegram", "[PostboxTransaction] rollback")
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram", "[PostboxTransaction] rollback failed code=${e.code} ${e.message}")
            throw PostboxTransactionException("PostboxTransaction.rollback failed: ${e.message}")
        } finally {
            this._inTransaction = false
        }
    }

    /**
     * 原子事务入口（"一组写要么全成要么全滚"）。
     *
     * 包裹闭包 body：begin -> body() -> commit；body 抛任何异常则 rollback 并重抛。
     * 这是给上层批量写的主入口（对应 iOS 把一组写包在 begin/commit 之间）。
     *
     * 泛型 + 闭包参数写法与工程内既有实证一致（core/utils/Utils.cj
     * collectionMap<T, U>(arr, transform: (T) -> U)）：func 名后 <T>，
     * body 形参类型 () -> T，返回 T。
     *
     * rollback 自身失败时只记日志、不掩盖原始异常——优先把 body 的原始异常抛给上层。
     *
     * @param body 在事务内执行的闭包，其返回值原样回传
     * @return body() 的返回值
     * @throws PostboxTransactionException begin/commit 失败
     * @throws Exception body 抛出的原始异常（rollback 后重抛）
     */
    public func withTransaction<T>(body: () -> T): T {
        this.begin()
        try {
            let result = body()
            this.commit()
            return result
        } catch (e: Exception) {
            // body（或 commit）抛异常：回滚。rollback 自身异常不得掩盖原始异常。
            try {
                if (this._inTransaction) {
                    this.rollback()
                }
            } catch (re: Exception) {
                Hilog.error(0, "CjTelegram",
                    "[PostboxTransaction] rollback during exception handling failed: ${re.message}")
            }
            throw e
        }
    }
}
