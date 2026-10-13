package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.setAccountUpdateCallback
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import std.collection.ArrayList
import std.sync.Monitor
import std.time.DateTime

/**
 * 账号级 raw updates 唯一入口。
 *
 * 对齐 iOS AccountStateManager 的入口所有权和串行队列：MTProtoClient 只注册这里
 * 一个 callback；收到的 batch 先排队，再由单个 drain 协程按到达顺序交给
 * UpdatesManager。业务模块只订阅 UpdatesManager 的 typed event，不再重复解析 raw
 * update。后续持久化层应接在 UpdatesManager 的 committed batch 出口。
 */

private class PendingAccountUpdate {
    public let batchId: Int64
    public let slot: Int32
    public let data: Array<Byte>

    public init(batchId: Int64, slot: Int32, data: Array<Byte>) {
        this.batchId = batchId
        this.slot = slot
        this.data = data
    }
}

private var _accountUpdateCoordinatorInstance: Option<AccountUpdateCoordinator> = None
private let _accountUpdateCoordinatorInstanceMonitor = Monitor()

public func getAccountUpdateCoordinator(): AccountUpdateCoordinator {
    return synchronized(_accountUpdateCoordinatorInstanceMonitor) {
        match (_accountUpdateCoordinatorInstance) {
            case Some(instance) => instance
            case None =>
                let instance = AccountUpdateCoordinator()
                _accountUpdateCoordinatorInstance = Some(instance)
                instance
        }
    }
}

public class AccountUpdateCoordinator {
    private let _monitor = Monitor()
    private var _initialized: Bool = false
    private var _draining: Bool = false
    private var _nextBatchId: Int64 = 1
    private var _pending = ArrayList<PendingAccountUpdate>()

    /** 注册 MTProtoClient 唯一 updates callback；幂等。 */
    public func initialize(): Unit {
        var shouldWire = false
        synchronized(this._monitor) {
            if (!this._initialized) {
                this._initialized = true
                shouldWire = true
            }
        }
        if (!shouldWire) { return }

        // AuthStorage 已由 AppStartup 初始化，此时加载最后提交的同步游标。
        getUpdatesManager().initialize()
        // 通过注册表安装（而非 getMTProtoClient().setUpdateCallback）：账号切换时
        // resetGlobalClient() 会丢弃旧 client 实例，只挂在实例上的 callback 随之消失，
        // 新账号的 client 便再也不推 updates。注册表对之后创建的每个账号 client 重新安装；
        // 非活跃 slot（切换过程中尚未 disconnect 完的旧 client）的残余 batch 直接丢弃，
        // 对位 iOS 每个 Account 各自持有 AccountStateManager、切换后旧 context 整体释放。
        setAccountUpdateCallback({ slot: Int32, data: Array<Byte> =>
            let activeSlot = getAuthStorage().getActiveSlot()
            if (slot != activeSlot) {
                Hilog.info(0, "CjTelegram",
                    "[AccountUpdateCoordinator] ignored ${data.size}-byte batch from inactive slot=${slot} (active=${activeSlot})")
                return
            }
            this.enqueue(slot, data)
        })
        Hilog.info(0, "CjTelegram", "[AccountUpdateCoordinator] installed as sole MTProto updates owner")
    }

    /** Drop the previous account's queued batches and reload account-scoped cursors. */
    public func accountDidSwitch(): Unit {
        synchronized(this._monitor) {
            this._pending = ArrayList<PendingAccountUpdate>()
            this._draining = false
        }
        getUpdatesManager().resetForAccountSwitch()
        Hilog.info(0, "CjTelegram", "[AccountUpdateCoordinator] reset active account update state")
    }

    private func enqueue(slot: Int32, data: Array<Byte>): Unit {
        var shouldStartDrain = false
        var batchId: Int64 = 0
        synchronized(this._monitor) {
            batchId = this._nextBatchId
            this._nextBatchId += 1
            this._pending.add(PendingAccountUpdate(batchId, slot, data))
            if (!this._draining) {
                this._draining = true
                shouldStartDrain = true
            }
        }
        Hilog.info(0, "CjTelegram",
            "[AccountUpdateCoordinator] enqueue batch=${batchId}, slot=${slot}, bytes=${data.size}")
        if (shouldStartDrain) {
            spawn { this.drain() }
        }
    }

    private func takeFirstPending(): Option<PendingAccountUpdate> {
        return synchronized(this._monitor) {
            if (this._pending.size == 0) {
                this._draining = false
                return None
            }
            let first = this._pending[0]
            this._pending.remove(0..1)
            Some(first)
        }
    }

    private func drain(): Unit {
        while (true) {
            // iOS 在 difference 期间把实时 updates 留在 pending queue，待新基线提交后
            // 重新校验。这里不从 FIFO 取下一项，避免 difference spawn 与实时 batch
            // 并发读写 UpdatesManager 的 pts/qts/seq。
            if (getUpdatesManager().isDifferenceSyncInFlight()) {
                sleep(Duration.millisecond * 20)
                continue
            }
            match (this.takeFirstPending()) {
                case None => return
                case Some(update) => this.process(update)
            }
        }
    }

    private func process(update: PendingAccountUpdate): Unit {
        // 入队时属于活跃账号、出队前账号已切换的 batch 属于上一账号上下文：不得再交给
        // 当前账号的状态机 / 投影（切换后由新账号 getDifference 重建基线）。
        let activeSlot = getAuthStorage().getActiveSlot()
        if (update.slot != activeSlot) {
            Hilog.info(0, "CjTelegram",
                "[AccountUpdateCoordinator] dropped batch=${update.batchId} slot=${update.slot}: account switched to slot=${activeSlot}")
            return
        }
        let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
        try {
            getUpdatesManager().handleRawUpdate(update.data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[AccountUpdateCoordinator] state handler failed batch=${update.batchId}: ${e}")
        }

        let elapsedMs = DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt
        Hilog.info(0, "CjTelegram",
            "[AccountUpdateCoordinator] committed batch=${update.batchId}, elapsedMs=${elapsedMs}")
    }
}
