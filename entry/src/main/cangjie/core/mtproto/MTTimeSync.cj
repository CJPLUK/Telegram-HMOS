package ohos_app_cangjie_entry.core.mtproto

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.sync.*
import std.time.*

// ============================================================
// P2-245: 服务器时间同步 — 多样本中位 offset + get_future_salts
//          运行时请求与盐轮换 + 持续漂移校正
//
// 对应 iOS MtProtoKit:
//   - MTTimeSyncMessageService.m  (多样本采集 / 异常值剔除 / 中位数)
//   - MTDatacenterSaltInfo.m      (盐的 validSince / validUntil 判定)
//   - MTFutureSaltsMessage.m      (future_salts#ae500895 解析)
//   - MTContext timeDifference    (全局 timeOffset 持久化)
// ============================================================

/**
 * 单条未来盐条目（对应 iOS MTFutureSalt / MTDatacenterSaltInfo）。
 *
 * iOS 以 firstValidMessageId / lastValidMessageId（= validSince/Until * 2^32）表示窗口；
 * 我们直接保存 validSince / validUntil（服务端 Unix 秒），在判定时换算。
 *   validSince   → 该盐开始生效的服务端 Unix 秒（对应 iOS firstValidMessageId >> 32）
 *   validUntil   → 该盐失效的服务端 Unix 秒（对应 iOS lastValidMessageId >> 32）
 *   salt         → 64-bit 盐值
 */
public class FutureSaltInfo {
    public let validSince: Int64   // 服务端 Unix 秒
    public let validUntil: Int64   // 服务端 Unix 秒（exclusive）
    public let salt: Int64

    public init(validSince: Int64, validUntil: Int64, salt: Int64) {
        this.validSince = validSince
        this.validUntil = validUntil
        this.salt = salt
    }

    /**
     * 给定当前服务端时间（Unix 秒），判断本盐是否有效（对齐 iOS isValidFutureSaltForMessageId）。
     * iOS: _lastValidMessageId > messageId → 即 validUntil > serverNowSec。
     * 且需要 serverNowSec >= validSince（盐已生效）。
     */
    public func isValidAt(serverNowSec: Int64): Bool {
        return serverNowSec >= this.validSince && this.validUntil > serverNowSec
    }

    /**
     * 判断盐是否即将过期（在未来 thresholdSec 秒内到期）。
     * 用于提前触发 get_future_salts 刷新请求（不能等到完全过期才请求）。
     */
    public func expiresWithin(serverNowSec: Int64, thresholdSec: Int64): Bool {
        return (this.validUntil - serverNowSec) < thresholdSec
    }
}

/**
 * MTTimeSyncService — 持续时间同步与未来盐管理（P2-245）。
 *
 * 核心职责（对应 iOS MTTimeSyncMessageService）：
 *
 * 1. **多样本中位 offset**
 *    每条来自服务端的加密消息携带 msgId（高 32 bit = 服务端 Unix 秒）。
 *    调用 recordSample(serverMsgId) 记录一个样本 = serverUnixSec - localNowSec。
 *    样本满 SAMPLE_WINDOW_SIZE 后：剔除绝对值最大 / 最小各 1 条，取剩余均值（对齐 iOS
 *    MTTimeSyncMessageService 的 maxSampleIndex / minSampleIndex 剔除逻辑），
 *    用结果更新外部 timeOffset（通过 onOffsetUpdated 回调通知 MTProtoClient）。
 *
 * 2. **get_future_salts 运行时请求与盐存储**
 *    通过 requestFutureSalts(sendFn) 向服务端发送
 *      get_future_salts#b921bd04 { num: Int32 }（num=32，对齐 iOS）。
 *    收到 future_salts#ae500895 响应后由 handleFutureSalts 解析并存入 futureSalts 列表。
 *
 * 3. **盐轮换**
 *    getCurrentSalt(serverNowSec) 扫描 futureSalts 列表，返回当前时刻有效的盐值；
 *    若当前盐临近过期（< SALT_EXPIRY_THRESHOLD_SEC），触发 requestFutureSalts 刷新。
 *    轮换时从列表中选 validSince <= now < validUntil 的条目。
 *
 * 4. **持续重同步定时器**
 *    startDriftTimer / stopDriftTimer 用 Timer.repeat 每 DRIFT_INTERVAL_SEC 秒：
 *      - 重新触发 get_future_salts（盐快到期时）
 *      - 触发样本窗口复位（强制在下一批消息中重采，校正漂移）
 *
 * 线程安全：所有可变状态（samples / futureSalts / timeOffset / pendingRequest）
 *   受 syncMutex (ReentrantMutex) 保护；IO（sendFn 调用）在锁外执行。
 *
 * 时钟域（与 P2-243/244 一致）：
 *   - 服务端时间比对 / timeOffset 用 wall clock（DateTime.now().toUnixTimeStamp().toMilliseconds()）
 *   - 定时器 / 退避 monotonic 不引入（Timer.repeat 内部管理，不涉及 offset 计算）
 */
public class MTTimeSyncService {
    // ---- 采样参数 ----
    // 样本窗口：满 6 个样本后剔极值取均值（对齐 iOS _requiredSampleCount = 6）
    private static let SAMPLE_WINDOW_SIZE: Int64 = 6
    // 盐临近过期阈值：剩余有效期 < 300 秒时触发刷新（对齐 iOS 5 分钟预取裕量）
    private static let SALT_EXPIRY_THRESHOLD_SEC: Int64 = 300
    // 漂移校正周期（秒）：每 30 分钟重新触发一次样本采集轮次
    private static let DRIFT_INTERVAL_SEC: Int64 = 1800

    // ---- 受 syncMutex 保护的可变状态 ----
    private let syncMutex = ReentrantMutex()
    private var samples: ArrayList<Int64> = ArrayList<Int64>()   // 原始 offset 样本（秒）
    private var futureSalts: ArrayList<FutureSaltInfo> = ArrayList<FutureSaltInfo>()
    private var pendingSaltRequest: Bool = false   // 是否已有在途的 get_future_salts 请求

    // ---- 外部回调（锁外调用）----
    // 每次 timeOffset 更新后通知 MTProtoClient（由 MTProtoClient 在初始化时注入）
    private var onOffsetUpdated: Option<(Int64) -> Unit> = None
    // 发出 get_future_salts 请求的函数（由 MTProtoClient 注入，锁外调用）；接收 num 参数透传
    private var sendFutureSaltsRequest: Option<(Int32) -> Unit> = None

    // ---- 漂移校正定时器 ----
    private var driftTimer: Option<Timer> = None
    private let timerMutex = ReentrantMutex()

    public init() {}

    /**
     * 注入 offset 更新回调（由 MTProtoClient 初始化时调用）。
     */
    public func setOffsetCallback(cb: (Int64) -> Unit): Unit {
        syncMutex.lock()
        this.onOffsetUpdated = Some(cb)
        syncMutex.unlock()
    }

    /**
     * 注入 get_future_salts 发送函数（锁外、由 MTProtoClient 注入）。
     * cb 接收 num: Int32，透传给 sendGetFutureSalts(num)，保证请求数量真穿透。
     */
    public func setSendFutureSaltsCallback(cb: (Int32) -> Unit): Unit {
        syncMutex.lock()
        this.sendFutureSaltsRequest = Some(cb)
        syncMutex.unlock()
    }

    // =========================================================================
    // 能力一：多样本中位 offset 采集
    // =========================================================================

    /**
     * 记录一个时间同步样本。
     *
     * 从服务端消息的 msgId 高 32 位提取服务端 Unix 秒，计算与本地 wall clock 的差值。
     * 对应 iOS MTTimeSyncMessageService.m:
     *   NSTimeInterval timeDifference = message.messageId / 4294967296.0
     *                                   - [[NSDate date] timeIntervalSince1970]
     *
     * @param serverMsgId 服务端消息的 msgId（高 32 bit = 服务端 Unix 秒）
     */
    public func recordSample(serverMsgId: Int64): Unit {
        let serverUnixSec = (serverMsgId >> 32) & 0x7fffffff
        if (serverUnixSec <= 0) {
            return  // msgId 不合法（握手阶段产物或局部消息 ID），跳过
        }
        let localNowSec = DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000
        let sample = serverUnixSec - localNowSec

        var shouldCompute = false
        var samples: ArrayList<Int64> = ArrayList<Int64>()
        var offsetCb: Option<(Int64) -> Unit> = None

        syncMutex.lock()
        this.samples.add(sample)
        if (this.samples.size >= MTTimeSyncService.SAMPLE_WINDOW_SIZE) {
            shouldCompute = true
            // 浅拷贝样本集，在锁外执行排序/计算（不在锁内做 CPU 密集）
            for (s in this.samples) {
                samples.add(s)
            }
            this.samples = ArrayList<Int64>()  // 清空，开始下一轮采集
            offsetCb = this.onOffsetUpdated
        }
        syncMutex.unlock()

        if (shouldCompute) {
            let newOffset = MTTimeSyncService.computeMedianOffset(samples)
            Hilog.info(0, "CjTelegram",
                "[MTTimeSync] Sample window complete (${samples.size} samples), computed offset=${newOffset}s")
            // 通知 MTProtoClient 更新 timeOffset（锁外调用回调）
            match (offsetCb) {
                case Some(cb) => cb(newOffset)
                case None => ()
            }
        }
    }

    /**
     * 纯函数：从样本列表计算去极值后的均值 offset（对齐 iOS MTTimeSyncMessageService）。
     *
     * iOS 逻辑（MTTimeSyncMessageService.m L119-157）：
     *   1. 找绝对值最大的样本（maxSampleIndex）和绝对值最小的样本（minSampleIndex）。
     *   2. 从 _takenSamples 中移除这两个下标的元素。
     *   3. 对剩余元素取算术均值（timeDifferenceSum / count）。
     *   4. 若剩余为空（只有 1 个样本的退化情况），直接用原始 timeDifference。
     *
     * @param rawSamples 原始 offset 样本列表（来自 recordSample）
     * @return 去极值均值 offset（秒）
     */
    public static func computeMedianOffset(rawSamples: ArrayList<Int64>): Int64 {
        let count = rawSamples.size
        if (count == 0) {
            return 0
        }
        if (count <= 2) {
            // ≤ 2 个样本无法剔除后还有剩余，直接返回第一个
            return rawSamples[0]
        }

        // 找绝对值最大 / 最小的下标（对齐 iOS maxSampleIndex / minSampleIndex）
        var maxAbsVal: Int64 = -1
        var maxIdx: Int64 = 0
        var minAbsVal: Int64 = -1
        var minIdx: Int64 = 0

        var i: Int64 = 0
        while (i < count) {
            let absVal = if (rawSamples[i] < 0) { -rawSamples[i] } else { rawSamples[i] }
            if (maxAbsVal < 0 || absVal > maxAbsVal) {
                maxAbsVal = absVal
                maxIdx = i
            }
            if (minAbsVal < 0 || absVal < minAbsVal) {
                minAbsVal = absVal
                minIdx = i
            }
            i += 1
        }

        // 对剩余（排除 maxIdx / minIdx）求和后取均值
        var sum: Int64 = 0
        var remaining: Int64 = 0
        var j: Int64 = 0
        while (j < count) {
            if (j != maxIdx && j != minIdx) {
                sum += rawSamples[j]
                remaining += 1
            }
            j += 1
        }

        if (remaining == 0) {
            // maxIdx == minIdx（仅 3 个且极值重合），退化为第一个样本
            return rawSamples[0]
        }

        return sum / remaining
    }

    // =========================================================================
    // 能力二：get_future_salts 运行时请求与盐存储
    // =========================================================================

    /**
     * 发出 get_future_salts#b921bd04 请求（若当前无在途请求）。
     *
     * 请求体（对应 iOS MTTimeSyncMessageService.m L54-58）：
     *   0xb921bd04(4, LE) + num:Int32(4, LE)
     *   num = 1（已有盐列表时请求 1 个）或 32（首次无盐时一次性请求多个，对齐 iOS）。
     *
     * 此方法只序列化并调用 sendFutureSaltsRequest 回调（发送本身由 MTProtoClient 执行，
     * 保持 MTTimeSyncService 不直接持有 transport/session 引用）。
     *
     * 线程安全：在 syncMutex 内设置 pendingSaltRequest 标志（防重），在锁外调用 callback。
     *
     * @param num 请求的未来盐数量（1 or 32）
     */
    public func requestFutureSalts(num: Int32): Unit {
        var shouldSend = false
        var cb: Option<(Int32) -> Unit> = None
        syncMutex.lock()
        if (!this.pendingSaltRequest) {
            this.pendingSaltRequest = true
            shouldSend = true
            cb = this.sendFutureSaltsRequest
        }
        syncMutex.unlock()

        if (shouldSend) {
            Hilog.info(0, "CjTelegram", "[MTTimeSync] Requesting future salts (num=${num})")
            match (cb) {
                case Some(sendFn) => sendFn(num)
                case None =>
                    // 回调未注入（初始化顺序问题）：清除在途标志，不永久锁死
                    syncMutex.lock()
                    this.pendingSaltRequest = false
                    syncMutex.unlock()
                    Hilog.info(0, "CjTelegram", "[MTTimeSync] requestFutureSalts: sendFn not set, request deferred")
            }
        }
    }

    /**
     * 解析 future_salts#ae500895 响应体（P2-245）。
     *
     * TL schema:
     *   future_salts#ae500895 req_msg_id:long now:int salts:future_salt[] = FutureSalts
     *   future_salt#0949d9dc valid_since:int valid_until:int salt:long = FutureSalt
     *
     * 与 iOS MTFutureSaltsMessage initWithRequestMessageId:now:salts: 对齐。
     * iOS MTTimeSyncMessageService.m L87-92：将 futureSalt.validSince * 4294967296 = firstValidMessageId
     *   → 我们直接存 validSince / validUntil（Unix 秒），buildMessage 侧按需换算到盐字节。
     *
     * @param deserializer 已读过构造子 0xae500895 后的反序列化器
     * @return 解析的请求 msgId（req_msg_id，用于关联等待者）
     */
    public func handleFutureSalts(deserializer: TLDeserializer): Int64 {
        let reqMsgId = deserializer.readInt64()
        let now = deserializer.readInt32()  // 服务端当前 Unix 秒（不直接用于 offset，但可辅助）

        // salts 字段：future_salts#ae500895 的 salts 是 bare vector<future_salt>（无 0x1cb5c415 vector tag）：
        //   count:Int32 + [bare future_salt × count]
        //   每条 bare future_salt（无 per-entry constructor 前缀）：valid_since(4) + valid_until(4) + salt(8) = 16 字节
        //   对齐 iOS MTInternalMessageParser.m L637-653：直接读 validSince/validUntil/salt，
        //   无 0x0949d9dc per-entry constructor 读取。
        let count = deserializer.readInt32()

        let newSalts = ArrayList<FutureSaltInfo>()
        var i: Int32 = 0
        while (i < count) {
            // bare future_salt：valid_since(4) + valid_until(4) + salt(8)，无 constructor 前缀
            let validSince = Int64(deserializer.readInt32())
            let validUntil = Int64(deserializer.readInt32())
            let salt = deserializer.readInt64()
            newSalts.add(FutureSaltInfo(validSince, validUntil, salt))
            i += 1
        }

        Hilog.info(0, "CjTelegram",
            "[MTTimeSync] future_salts received: req_msg_id=${reqMsgId} now=${now} count=${newSalts.size}")

        // 存入盐列表，清除在途标志（在 syncMutex 内原子操作）
        syncMutex.lock()
        // 追加新盐（iOS 用 addObjectsFromArray，保留已有+新增共存）
        for (s in newSalts) {
            this.futureSalts.add(s)
        }
        this.pendingSaltRequest = false
        syncMutex.unlock()

        return reqMsgId
    }

    // =========================================================================
    // 能力三：盐轮换
    // =========================================================================

    /**
     * 获取当前有效的盐值（供 buildMessage 使用）。
     *
     * 对齐 iOS MTDatacenterSaltInfo.isValidFutureSaltForMessageId：
     *   _lastValidMessageId > messageId → validUntil > serverNowSec
     *
     * 若当前盐临近过期（< SALT_EXPIRY_THRESHOLD_SEC），触发 requestFutureSalts 预取。
     *
     * @param serverNowSec 当前服务端时间（= localNowSec + timeOffset）
     * @return Some(salt) 若找到有效盐；None 表示无有效盐（调用方回退 session.serverSalt）
     */
    public func getCurrentSalt(serverNowSec: Int64): Option<Int64> {
        var resultSalt: Option<Int64> = None
        var nearExpiry = false
        var hasSalts = false

        syncMutex.lock()
        hasSalts = this.futureSalts.size > 0
        for (info in this.futureSalts) {
            if (info.isValidAt(serverNowSec)) {
                resultSalt = Some(info.salt)
                if (info.expiresWithin(serverNowSec, MTTimeSyncService.SALT_EXPIRY_THRESHOLD_SEC)) {
                    nearExpiry = true
                }
                break
            }
        }
        syncMutex.unlock()

        if (hasSalts && nearExpiry && !pendingSaltRequestFlag()) {
            // 当前盐临近过期 → 触发预取（异步，不阻塞 buildMessage）
            Hilog.info(0, "CjTelegram",
                "[MTTimeSync] Current salt expiring soon (serverNow=${serverNowSec}), triggering refresh")
            requestFutureSalts(1)
        }

        return resultSalt
    }

    // pendingSaltRequest 标志无锁读（仅用于 getCurrentSalt 快速判断；精确度不要求原子性）
    private func pendingSaltRequestFlag(): Bool {
        syncMutex.lock()
        let v = this.pendingSaltRequest
        syncMutex.unlock()
        return v
    }

    /**
     * 清理已过期盐条目（可由漂移定时器周期调用，避免列表无限增长）。
     *
     * @param serverNowSec 当前服务端时间
     */
    public func pruneExpiredSalts(serverNowSec: Int64): Unit {
        syncMutex.lock()
        let fresh = ArrayList<FutureSaltInfo>()
        for (info in this.futureSalts) {
            if (info.validUntil > serverNowSec) {
                fresh.add(info)
            }
        }
        let pruned = this.futureSalts.size - fresh.size
        this.futureSalts = fresh
        syncMutex.unlock()
        if (pruned > 0) {
            Hilog.info(0, "CjTelegram",
                "[MTTimeSync] pruneExpiredSalts: removed ${pruned} expired salt(s), remaining=${fresh.size}")
        }
    }

    /**
     * HI-AUTH-0004 真机插桩实测根因修复：future_salts#ae500895 的 valid_since/valid_until 是
     * 服务端 Unix 秒窗口（不含 DC 标识），迁移到新 DC 后旧 DC 发的未来盐在挂钟时间上仍会
     * "看起来有效"，但盐值本身是旧 DC 的、新 DC 完全不识别 —— getCurrentSalt() 会一直
     * 优先返回这条旧盐，buildMessage 永久跳过 handleBadServerSalt 刚写入 session 的正确新盐，
     * 导致重发消息用错误盐加密、服务端连续拒绝直到 MAX_TRANSIENT_RETRIES 耗尽（"No response
     * from server"）。migrateToDC 必须在建立新 DC 连接前清空本 DC 局部状态（future_salts 列表
     * 与在途 pendingSaltRequest 标志），使 buildMessage 迁移后立即回退 session.serverSalt
     * （= handleBadServerSalt 写入的新盐），直至新 DC 自己的 get_future_salts 响应到达为止。
     * 对齐 iOS MTContext 在 datacenter 切换时按 datacenterId 隔离 MTDatacenterSaltInfo 集合的语义
     * （我们用单实例 + 显式 reset 达到等价隔离，而非按 dcId keyed 存储）。
     */
    public func resetForMigration(): Unit {
        syncMutex.lock()
        let dropped = this.futureSalts.size
        this.futureSalts = ArrayList<FutureSaltInfo>()
        this.pendingSaltRequest = false
        syncMutex.unlock()
        Hilog.info(0, "CjTelegram",
            "[MTTimeSync] resetForMigration: cleared ${dropped} stale future salt(s) from prior DC")
    }

    // =========================================================================
    // 能力四：持续重同步 / 漂移校正定时器
    // =========================================================================

    /**
     * 启动漂移校正定时器（每 DRIFT_INTERVAL_SEC 秒触发一次重同步）。
     *
     * 对应 iOS MTTimeSyncMessageService 在 _requiredSampleCount > 0 时持续请求 transaction
     * 的行为：周期性地重采样以校正长期漂移。
     *
     * 使用 Timer.repeat（std.sync）而非 spawn+sleep，避免线程泄漏（与 ACK timer 一致）。
     * 幂等：若已有 timer 先 cancel 再重建。
     *
     * @param serverNowSecFn 获取当前服务端时间的函数（注入而非直接持有 MTProtoClient）
     */
    public func startDriftTimer(serverNowSecFn: () -> Int64): Unit {
        let svcRef = this
        timerMutex.lock()
        match (this.driftTimer) {
            case Some(t) => t.cancel()
            case None => ()
        }
        let t = Timer.repeat(
            Duration.second * MTTimeSyncService.DRIFT_INTERVAL_SEC,
            Duration.second * MTTimeSyncService.DRIFT_INTERVAL_SEC,
            {=>
                let serverNow = serverNowSecFn()
                // 1. 清理过期盐
                svcRef.pruneExpiredSalts(serverNow)
                // 2. 若盐列表为空或临近过期，触发 get_future_salts 刷新
                let needsRefresh = svcRef.saltListNeedsRefresh(serverNow)
                if (needsRefresh) {
                    svcRef.requestFutureSalts(32)
                }
                // 3. 复位样本窗口（强制下一批消息重新采集，校正漂移）
                svcRef.syncMutex.lock()
                svcRef.samples = ArrayList<Int64>()
                svcRef.syncMutex.unlock()
                Hilog.info(0, "CjTelegram",
                    "[MTTimeSync] Drift timer fired: salt refresh=${needsRefresh}, sample window reset")
            }
        )
        this.driftTimer = Some(t)
        timerMutex.unlock()
        Hilog.info(0, "CjTelegram",
            "[MTTimeSync] Drift correction timer started (interval=${MTTimeSyncService.DRIFT_INTERVAL_SEC}s)")
    }

    /**
     * 停止漂移校正定时器（disconnect 时调用，与 ACK timer 对称）。
     */
    public func stopDriftTimer(): Unit {
        timerMutex.lock()
        match (this.driftTimer) {
            case Some(t) =>
                t.cancel()
                this.driftTimer = None
            case None => ()
        }
        timerMutex.unlock()
    }

    /**
     * 判断盐列表是否需要刷新（供漂移定时器和 getCurrentSalt 使用）。
     * 条件：列表为空 OR 所有盐均在 SALT_EXPIRY_THRESHOLD_SEC 内过期。
     */
    private func saltListNeedsRefresh(serverNowSec: Int64): Bool {
        syncMutex.lock()
        let sz = this.futureSalts.size
        if (sz == 0) {
            syncMutex.unlock()
            return true
        }
        var hasValidLong = false
        for (info in this.futureSalts) {
            if (info.isValidAt(serverNowSec) &&
                !info.expiresWithin(serverNowSec, MTTimeSyncService.SALT_EXPIRY_THRESHOLD_SEC)) {
                hasValidLong = true
                break
            }
        }
        syncMutex.unlock()
        return !hasValidLong
    }

    // =========================================================================
    // 测试辅助（仅供 selfCheck 使用，不对外导出语义）
    // =========================================================================

    /**
     * 直接注入 FutureSaltInfo 条目（仅用于 selfCheck 测试，不走网络解析路径）。
     */
    public func injectSalt(info: FutureSaltInfo): Unit {
        syncMutex.lock()
        this.futureSalts.add(info)
        syncMutex.unlock()
    }

    /**
     * 读取当前 futureSalts 列表大小（仅供 selfCheck 断言）。
     */
    public func saltCount(): Int64 {
        syncMutex.lock()
        let n = this.futureSalts.size
        syncMutex.unlock()
        return n
    }

    /**
     * 读取当前待处理样本数（仅供 selfCheck 断言）。
     * 样本列表在窗口满时清空（触发计算后重置），可通过此方法验证积累行为。
     */
    public func pendingSampleCount(): Int64 {
        syncMutex.lock()
        let n = this.samples.size
        syncMutex.unlock()
        return n
    }

    // =========================================================================
    // selfCheck — 真断言（无网络）
    // =========================================================================

    /**
     * P2-245 自检：
     *   1. computeMedianOffset 去极值均值逻辑
     *   2. FutureSaltInfo.isValidAt / expiresWithin 判定
     *   3. recordSample 样本积累 + 触发计算（用已知样本注入验证均值）
     *   4. pruneExpiredSalts 只清过期条目
     * 任何断言失败抛 Exception。
     */
    public static func selfCheck(): Unit {
        // ===== 1. computeMedianOffset 纯函数断言 =====
        // 样本集：[10, -2, 3, 5, -8, 4]
        //   绝对值：  10, 2, 3, 5, 8, 4
        //   maxAbs = 10 (idx=0), minAbs = 2 (idx=1)
        //   剩余: [3, 5, -8, 4] → sum = 4, count = 4 → 均值 = 1
        let s1 = ArrayList<Int64>()
        s1.add(10)
        s1.add(-2)
        s1.add(3)
        s1.add(5)
        s1.add(-8)
        s1.add(4)
        let r1 = MTTimeSyncService.computeMedianOffset(s1)
        if (r1 != 1) {
            throw Exception("selfCheck FAIL: computeMedianOffset([10,-2,3,5,-8,4]) expected 1, got ${r1}")
        }

        // 只有 1 个样本 → 直接返回
        let s2 = ArrayList<Int64>()
        s2.add(7)
        let r2 = MTTimeSyncService.computeMedianOffset(s2)
        if (r2 != 7) {
            throw Exception("selfCheck FAIL: computeMedianOffset([7]) expected 7, got ${r2}")
        }

        // 只有 2 个样本 → 返回第一个
        let s3 = ArrayList<Int64>()
        s3.add(3)
        s3.add(9)
        let r3 = MTTimeSyncService.computeMedianOffset(s3)
        if (r3 != 3) {
            throw Exception("selfCheck FAIL: computeMedianOffset([3,9]) expected 3 (first), got ${r3}")
        }

        // 所有样本相同 → 均值等于样本值
        let s4 = ArrayList<Int64>()
        s4.add(5)
        s4.add(5)
        s4.add(5)
        s4.add(5)
        s4.add(5)
        s4.add(5)
        let r4 = MTTimeSyncService.computeMedianOffset(s4)
        if (r4 != 5) {
            throw Exception("selfCheck FAIL: computeMedianOffset([5,5,5,5,5,5]) expected 5, got ${r4}")
        }

        // ===== 2. FutureSaltInfo 判定断言 =====
        // validSince=1000, validUntil=2000
        let saltInfo = FutureSaltInfo(1000, 2000, 0x1234567890ABCDE0)
        // 在有效区间内
        if (!saltInfo.isValidAt(1500)) {
            throw Exception("selfCheck FAIL: FutureSaltInfo.isValidAt(1500) must be true")
        }
        // 刚好在 validSince
        if (!saltInfo.isValidAt(1000)) {
            throw Exception("selfCheck FAIL: FutureSaltInfo.isValidAt(validSince) must be true")
        }
        // 超过 validUntil
        if (saltInfo.isValidAt(2000)) {
            throw Exception("selfCheck FAIL: FutureSaltInfo.isValidAt(validUntil) must be false (exclusive)")
        }
        // 未到 validSince
        if (saltInfo.isValidAt(999)) {
            throw Exception("selfCheck FAIL: FutureSaltInfo.isValidAt(before validSince) must be false")
        }
        // expiresWithin：validUntil - serverNow = 100 < threshold=300 → true
        if (!saltInfo.expiresWithin(1900, 300)) {
            throw Exception("selfCheck FAIL: FutureSaltInfo.expiresWithin(1900, 300) must be true")
        }
        // expiresWithin：validUntil - serverNow = 1000 >= threshold=300 → false
        if (saltInfo.expiresWithin(1000, 300)) {
            throw Exception("selfCheck FAIL: FutureSaltInfo.expiresWithin(1000, 300) must be false")
        }

        // ===== 3. recordSample 积累 + 样本窗口触发计算验证（用 pendingSampleCount 检查，无闭包捕获）=====
        // 策略：样本窗口满时，recordSample 内部清空 this.samples（重置为下一轮）。
        //   - 注入 5 个样本（WINDOW=6，未满）→ pendingSampleCount == 5
        //   - 注入第 6 个样本（窗口满，触发计算后清空）→ pendingSampleCount == 0
        let svc = MTTimeSyncService()
        let localNow = DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000
        var k: Int64 = 0
        while (k < 5) {
            let serverSec = localNow + 3
            let fakeMsgId = (serverSec << 32) | Int64(0x1234)
            svc.recordSample(fakeMsgId)
            k += 1
        }
        let countBefore = svc.pendingSampleCount()
        if (countBefore != 5) {
            throw Exception("selfCheck FAIL: pendingSampleCount before window full should be 5, got ${countBefore}")
        }
        // 第 6 个样本 → 触发计算 + 清空样本列表
        let serverSec6 = localNow + 3
        let fakeMsgId6 = (serverSec6 << 32) | Int64(0x5678)
        svc.recordSample(fakeMsgId6)
        let countAfter = svc.pendingSampleCount()
        if (countAfter != 0) {
            throw Exception("selfCheck FAIL: pendingSampleCount after window full should be 0 (reset after compute), got ${countAfter}")
        }

        // ===== 4. pruneExpiredSalts 只清过期条目 =====
        let svc2 = MTTimeSyncService()
        // 注入 3 条盐（通过 injectSalt 辅助，避免直接访问 private 字段）
        svc2.injectSalt(FutureSaltInfo(100, 200, 0xAAAA))    // validUntil=200，已过期（serverNow=700）
        svc2.injectSalt(FutureSaltInfo(300, 1000, 0xBBBB))   // validUntil=1000，未过期（serverNow=700）
        svc2.injectSalt(FutureSaltInfo(400, 600, 0xCCCC))    // validUntil=600，已过期（serverNow=700）

        svc2.pruneExpiredSalts(700)

        let remaining = svc2.saltCount()
        if (remaining != 1) {
            throw Exception("selfCheck FAIL: pruneExpiredSalts must keep 1 non-expired salt, found ${remaining}")
        }

        // ===== 5. handleFutureSalts bare struct 多条解析断言 =====
        // 构造 future_salts#ae500895 响应体（已略过外层 constructor 0xae500895，模拟 handleFutureSalts 入参）：
        //   req_msg_id(8) + now(4) + count(4) + [bare future_salt × count]
        //   bare future_salt = valid_since(4) + valid_until(4) + salt(8) = 16 字节（无 0x0949d9dc constructor）
        //
        // 编码 2 条 bare future_salt：
        //   entry0: validSince=1000(LE int32) validUntil=2000(LE int32) salt=0x0102030405060708(LE int64)
        //   entry1: validSince=2000(LE int32) validUntil=3000(LE int32) salt=0x090A0B0C0D0E0F10(LE int64)
        //
        // req_msg_id = 0x0102030405060708 (LE int64)
        // now = 500 (LE int32)
        // count = 2 (LE int32)
        let rawBytes = Array<Byte>(48, repeat: 0)
        // req_msg_id = 0x0102030405060708 (LE)
        rawBytes[0] = UInt8(0x08)
        rawBytes[1] = UInt8(0x07)
        rawBytes[2] = UInt8(0x06)
        rawBytes[3] = UInt8(0x05)
        rawBytes[4] = UInt8(0x04)
        rawBytes[5] = UInt8(0x03)
        rawBytes[6] = UInt8(0x02)
        rawBytes[7] = UInt8(0x01)
        // now = 500 = 0x000001F4 (LE)
        rawBytes[8] = UInt8(0xF4)
        rawBytes[9] = UInt8(0x01)
        rawBytes[10] = UInt8(0x00)
        rawBytes[11] = UInt8(0x00)
        // count = 2 (LE)
        rawBytes[12] = UInt8(0x02)
        rawBytes[13] = UInt8(0x00)
        rawBytes[14] = UInt8(0x00)
        rawBytes[15] = UInt8(0x00)
        // entry0: validSince=1000=0x000003E8 (LE)
        rawBytes[16] = UInt8(0xE8)
        rawBytes[17] = UInt8(0x03)
        rawBytes[18] = UInt8(0x00)
        rawBytes[19] = UInt8(0x00)
        // entry0: validUntil=2000=0x000007D0 (LE)
        rawBytes[20] = UInt8(0xD0)
        rawBytes[21] = UInt8(0x07)
        rawBytes[22] = UInt8(0x00)
        rawBytes[23] = UInt8(0x00)
        // entry0: salt=0x0102030405060708 (LE)
        rawBytes[24] = UInt8(0x08)
        rawBytes[25] = UInt8(0x07)
        rawBytes[26] = UInt8(0x06)
        rawBytes[27] = UInt8(0x05)
        rawBytes[28] = UInt8(0x04)
        rawBytes[29] = UInt8(0x03)
        rawBytes[30] = UInt8(0x02)
        rawBytes[31] = UInt8(0x01)
        // entry1: validSince=2000=0x000007D0 (LE)
        rawBytes[32] = UInt8(0xD0)
        rawBytes[33] = UInt8(0x07)
        rawBytes[34] = UInt8(0x00)
        rawBytes[35] = UInt8(0x00)
        // entry1: validUntil=3000=0x00000BB8 (LE)
        rawBytes[36] = UInt8(0xB8)
        rawBytes[37] = UInt8(0x0B)
        rawBytes[38] = UInt8(0x00)
        rawBytes[39] = UInt8(0x00)
        // entry1: salt=0x090A0B0C0D0E0F10 (LE)
        rawBytes[40] = UInt8(0x10)
        rawBytes[41] = UInt8(0x0F)
        rawBytes[42] = UInt8(0x0E)
        rawBytes[43] = UInt8(0x0D)
        rawBytes[44] = UInt8(0x0C)
        rawBytes[45] = UInt8(0x0B)
        rawBytes[46] = UInt8(0x0A)
        rawBytes[47] = UInt8(0x09)

        let svc3 = MTTimeSyncService()
        let deserializer = TLDeserializer(rawBytes)
        let parsedReqMsgId = svc3.handleFutureSalts(deserializer)

        // 验证 req_msg_id 返回正确
        let expectedReqMsgId: Int64 = 0x0102030405060708
        if (parsedReqMsgId != expectedReqMsgId) {
            throw Exception("selfCheck FAIL: handleFutureSalts reqMsgId expected 0x0102030405060708, got ${parsedReqMsgId}")
        }

        // 验证 2 条盐都已解析（bare struct，无 per-entry constructor 干扰）
        let parsedCount = svc3.saltCount()
        if (parsedCount != 2) {
            throw Exception("selfCheck FAIL: handleFutureSalts bare struct parse: expected 2 salts, got ${parsedCount} (per-entry constructor bug would yield 1)")
        }

        // 验证 entry0 在 serverNow=1500 时有效
        let salt0Opt = svc3.getCurrentSalt(1500)
        match (salt0Opt) {
            case None => throw Exception("selfCheck FAIL: handleFutureSalts entry0 must be valid at serverNow=1500")
            case Some(_) => ()
        }

        // 验证 entry1 在 serverNow=2500 时有效（需要清理 entry0 过期后能选到 entry1）
        // 先 prune serverNow=2100 后 entry0(validUntil=2000) 应已过期
        svc3.pruneExpiredSalts(2100)
        let afterPruneCount = svc3.saltCount()
        if (afterPruneCount != 1) {
            throw Exception("selfCheck FAIL: after pruneExpiredSalts(2100), expected 1 salt (entry1 still valid), got ${afterPruneCount}")
        }
        let salt1Opt = svc3.getCurrentSalt(2500)
        match (salt1Opt) {
            case None => throw Exception("selfCheck FAIL: handleFutureSalts entry1 must be valid at serverNow=2500")
            case Some(_) => ()
        }

        Hilog.info(0, "CjTelegram",
            "[MTTimeSync] selfCheck PASS: computeMedianOffset (trim max+min abs / avg remaining) / FutureSaltInfo validity / recordSample window accumulation / pruneExpiredSalts selective cleanup / handleFutureSalts bare struct multi-entry parse (2 entries, no per-entry constructor)")
    }
}
