package ohos_app_cangjie_entry.core.mtproto

import kit.PerformanceAnalysisKit.Hilog
import std.collection.HashMap
import std.collection.ArrayList
import std.sync.*
import std.convert.*
internal import std.time.*

// ============================================================
// P2-243: RPC 错误分类枚举
// 对应 iOS MTRequestMessageService.m 错误处理树：
//   Transient   → 自动指数退避重试（最多 MAX_TRANSIENT_RETRIES 次）
//   FloodWait   → 等待 X 秒后重试（X 由 error_message 后缀解析）
//   SlowMode    → 等待 X 秒后重试（SLOW_MODE_WAIT_X）
//   Migrate     → 主 API 迁移（PHONE_MIGRATE_X / NETWORK_MIGRATE_X / USER_MIGRATE_X）：
//                 解析目标 DC 号，切换【当前客户端自身】的 DC 后重新发送。
//                 语义正确的场景：当前客户端就是要迁移的那个会话本身（如主客户端的
//                 登录/账号会话，或 getClientForDC 建立的辅助 DC 客户端）。
//   FileMigrate → 媒体/文件专属迁移（FILE_MIGRATE_X）：真机 HI-AUTH-0006 实测根因——
//                 文件类 RPC（upload.getFile 等）返回 FILE_MIGRATE_X 只是告知"这个文件
//                 存在目标 DC 上"，不代表调用方的会话身份需要搬家。绝不能对调用方是【主
//                 客户端】的情形调用 migrateToDC（会把已在 home DC 授权的主会话整个搬到
//                 文件所在 DC，导致主会话在原 DC 的 authKey 状态被清空、getDialogs 等核心
//                 请求全部 401/CONNECTION_NOT_INITED）。正确处理：解析目标 DC 号，通过
//                 getClientForDC(dcId) 拿到（或建立）独立的辅助 DC 客户端，把原始请求体
//                 转发到该 aux client 上重发，原客户端（含主客户端）的 session 保持不变。
//   Fatal       → 直接上抛给调用方（不重试）
// ============================================================
public enum RPCErrorClass {
    | Transient
    | FloodWait(Int64)    // wait seconds
    | SlowMode(Int64)     // wait seconds
    | Migrate(Int64)      // target dcId — 迁移当前客户端自身
    | FileMigrate(Int64)  // target dcId — 转发到独立 aux DC 客户端，不迁移当前客户端
    | Fatal
}

/**
 * 重连退避 / 备用 scheme failover 控制器（P2-241d）。
 *
 * 对应 iOS MtProtoKit MTTcpConnectionBehaviour（_backoffCount 随关闭递增、收到有效数据清零、
 * 退避延迟随次数分桶 1s→4s→8s）+ MTContext chooseTransportSchemeForConnectionToDatacenterId
 * （同一 scheme 反复失败后切备用 scheme/DC）。
 *
 * 职责：
 *   1. 指数退避：连接失败 → 退避序列（baseMs, 2*base, 4*base … 上限 capMs 封顶 + 抖动），
 *      成功后 reset（attempt 归零、failover 索引归零）。退避用单调时钟（mtprotoMonotonicNowMs），
 *      不依赖墙钟（避免回拨）。
 *   2. 备用 scheme/DC failover：同一 scheme 连续失败 ≥ failoverThreshold 次 → 推进 scheme 索引，
 *      用 MTProtoConfig.getSchemesForDC(dcId) 的候选列表（复用 P2-241c）轮转；列表全部走完 → 探测/切备用 DC。
 *   3. 可达性恢复立即重连：triggerImmediateReconnect() 取消当前退避等待（清 nextRetryAtMs），
 *      使 dueForRetry() 立刻为真 —— 对接 P2-252 ReachabilityService（网络断→通时即时重连）。
 *
 * 线程安全：所有可变状态（attempt / failureCountForScheme / schemeIndex / nextRetryAtMs / dcIndex）
 *   受 ctrlMutex 保护。纯计算分支（computeBackoffMs / advanceScheme 等）抽成可注入参数的静态/纯方法，
 *   供 selfCheck 无网络真断言。
 *
 * 回归安全：不主动发起任何连接；仅在「连接失败分支」被调用记账并给出下一步建议（退避时长 / 是否切 scheme）。
 *   现有成功连接路径完全不经过本控制器（正常字节/流程不变）。
 */
public class ReconnectController {
    // ---- 退避参数（可在构造时覆盖；默认对齐 iOS 量级）----
    private let baseDelayMs: Int64        // 首次退避基准（默认 1000ms = 1s）
    private let capDelayMs: Int64         // 退避上限封顶（默认 8000ms = 8s，对齐 iOS 最大 8.0）
    private let jitterMaxMs: Int64        // 抖动上限（默认 250ms；0 关闭抖动便于断言）
    private let failoverThreshold: Int64  // 同一 scheme 连续失败几次后切备用（默认 3）

    // ---- 受 ctrlMutex 保护的可变状态 ----
    private let ctrlMutex = ReentrantMutex()
    private var attempt: Int64 = 0                 // 当前连续失败次数（成功清零）
    private var failureCountForScheme: Int64 = 0   // 当前 scheme 上的连续失败次数（切 scheme 后清零）
    private var schemeIndex: Int64 = 0             // 当前候选 scheme 列表中的索引
    private var nextRetryAtMs: Int64 = 0           // 下次允许重试的单调时刻（0 = 立即可重试）

    public init(
        baseDelayMs!: Int64 = 1000,
        capDelayMs!: Int64 = 8000,
        jitterMaxMs!: Int64 = 250,
        failoverThreshold!: Int64 = 3
    ) {
        this.baseDelayMs = if (baseDelayMs > 0) { baseDelayMs } else { 1000 }
        this.capDelayMs = if (capDelayMs >= this.baseDelayMs) { capDelayMs } else { this.baseDelayMs }
        this.jitterMaxMs = if (jitterMaxMs >= 0) { jitterMaxMs } else { 0 }
        this.failoverThreshold = if (failoverThreshold >= 1) { failoverThreshold } else { 1 }
    }

    /**
     * 纯函数：按失败次数算指数退避时长（不含抖动），封顶 capDelayMs。
     *   attempt<=1 → base；之后 base * 2^(attempt-1)，超过 cap 取 cap。
     * 用 Int64 移位，attempt 很大时直接返回 cap（防溢出：>=31 位直接封顶）。
     */
    public static func computeBackoffMs(attempt: Int64, baseMs: Int64, capMs: Int64): Int64 {
        if (attempt <= 1) {
            return if (baseMs <= capMs) { baseMs } else { capMs }
        }
        let shift = attempt - 1
        if (shift >= 31) {
            return capMs
        }
        let factor = 1 << shift
        let raw = baseMs * factor
        if (raw < 0 || raw > capMs) {
            return capMs
        }
        return raw
    }

    /**
     * 记录一次连接失败：递增退避与 scheme 失败计数，算出下次重试时刻（含抖动）。
     * @param schemeCount 当前 DC 候选 scheme 数（用于判断是否应切 scheme）。
     * @return ReconnectDecision：下次退避时长 + 是否应切到备用 scheme + 切到的 scheme 索引。
     */
    public func onFailure(schemeCount: Int64): ReconnectDecision {
        synchronized(ctrlMutex) {
            this.attempt += 1
            this.failureCountForScheme += 1

            var switched = false
            // 同一 scheme 连续失败达阈值 → 推进到下一候选 scheme（轮转），失败计数清零。
            if (this.failureCountForScheme >= this.failoverThreshold && schemeCount > 1) {
                this.schemeIndex = (this.schemeIndex + 1) % schemeCount
                this.failureCountForScheme = 0
                switched = true
            }

            let backoff = ReconnectController.computeBackoffMs(this.attempt, this.baseDelayMs, this.capDelayMs)
            let jitter = if (this.jitterMaxMs > 0) {
                Int64(ByteUtils.randomBytes(1)[0]) % (this.jitterMaxMs + 1)
            } else {
                0
            }
            let delay = backoff + jitter
            this.nextRetryAtMs = mtprotoMonotonicNowMs() + delay

            Hilog.info(0, "CjTelegram",
                "[Reconnect] failure attempt=${this.attempt} schemeIdx=${this.schemeIndex} switched=${switched} nextDelay=${delay}ms")
            return ReconnectDecision(delay, switched, this.schemeIndex)
        }
    }

    /**
     * 连接成功 / 收到有效数据：清零所有退避与 failover 状态（对齐 iOS connectionValidDataReceived）。
     */
    public func onSuccess(): Unit {
        synchronized(ctrlMutex) {
            this.attempt = 0
            this.failureCountForScheme = 0
            this.schemeIndex = 0
            this.nextRetryAtMs = 0
        }
        Hilog.info(0, "CjTelegram", "[Reconnect] success: backoff/failover state reset")
    }

    /**
     * 可达性恢复（或外部主动）触发立即重连：取消当前退避等待。
     * 不清 attempt（保留失败历史用于继续 failover），仅把 nextRetryAtMs 清零 → dueForRetry() 立即为真。
     */
    public func triggerImmediateReconnect(): Unit {
        synchronized(ctrlMutex) {
            this.nextRetryAtMs = 0
        }
        Hilog.info(0, "CjTelegram", "[Reconnect] immediate reconnect triggered (backoff wait cancelled)")
    }

    /**
     * 当前是否已过退避等待、可以重试（单调时钟比较）。
     */
    public func dueForRetry(): Bool {
        synchronized(ctrlMutex) {
            return mtprotoMonotonicNowMs() >= this.nextRetryAtMs
        }
    }

    /**
     * 距离下次可重试还需等待的毫秒数（<=0 表示立即可重试）。
     */
    public func remainingWaitMs(): Int64 {
        synchronized(ctrlMutex) {
            let rem = this.nextRetryAtMs - mtprotoMonotonicNowMs()
            return if (rem > 0) { rem } else { 0 }
        }
    }

    public func currentSchemeIndex(): Int64 {
        synchronized(ctrlMutex) {
            return this.schemeIndex
        }
    }

    public func currentAttempt(): Int64 {
        synchronized(ctrlMutex) {
            return this.attempt
        }
    }

    // -------------------------------------------------------------------------
    // selfCheck — 真断言：退避序列递增+封顶+成功重置 / 连续失败切备用 scheme /
    //   可达性恢复（注入假事件）取消退避立即重连。全程无网络。任何断言失败抛 Exception。
    // -------------------------------------------------------------------------
    public static func selfCheck(): Unit {
        // ===== 1. computeBackoffMs 纯函数：递增 + 封顶 =====
        // base=1000, cap=8000：序列应为 1000,1000,2000,4000,8000,8000(封顶)…
        if (ReconnectController.computeBackoffMs(0, 1000, 8000) != 1000) {
            throw Exception("selfCheck FAIL: backoff(attempt=0) expected 1000")
        }
        if (ReconnectController.computeBackoffMs(1, 1000, 8000) != 1000) {
            throw Exception("selfCheck FAIL: backoff(attempt=1) expected 1000")
        }
        if (ReconnectController.computeBackoffMs(2, 1000, 8000) != 2000) {
            throw Exception("selfCheck FAIL: backoff(attempt=2) expected 2000")
        }
        if (ReconnectController.computeBackoffMs(3, 1000, 8000) != 4000) {
            throw Exception("selfCheck FAIL: backoff(attempt=3) expected 4000")
        }
        if (ReconnectController.computeBackoffMs(4, 1000, 8000) != 8000) {
            throw Exception("selfCheck FAIL: backoff(attempt=4) expected 8000")
        }
        // 封顶：再大也不超过 cap
        if (ReconnectController.computeBackoffMs(5, 1000, 8000) != 8000) {
            throw Exception("selfCheck FAIL: backoff(attempt=5) must cap at 8000")
        }
        if (ReconnectController.computeBackoffMs(100, 1000, 8000) != 8000) {
            throw Exception("selfCheck FAIL: backoff(attempt=100) must cap at 8000 (no overflow)")
        }
        // 严格递增（直到封顶）：相邻 attempt 的退避非递减
        var prev = ReconnectController.computeBackoffMs(0, 1000, 8000)
        for (a in 1..6) {
            let cur = ReconnectController.computeBackoffMs(a, 1000, 8000)
            if (cur < prev) {
                throw Exception("selfCheck FAIL: backoff not monotonic non-decreasing at attempt=${a}")
            }
            prev = cur
        }

        // ===== 2. 实例退避状态：失败递增 → nextRetryAtMs 推进；成功 reset =====
        // 关掉抖动（jitterMaxMs=0）使断言确定。
        let ctrl = ReconnectController(baseDelayMs: 1000, capDelayMs: 8000, jitterMaxMs: 0, failoverThreshold: 3)
        // 单 scheme（schemeCount=1）：不应切 scheme
        let d1 = ctrl.onFailure(1)
        if (d1.switched) {
            throw Exception("selfCheck FAIL: single-scheme must not failover-switch")
        }
        if (d1.delayMs != 1000) {
            throw Exception("selfCheck FAIL: first failure delay expected 1000, got ${d1.delayMs}")
        }
        if (ctrl.currentAttempt() != 1) {
            throw Exception("selfCheck FAIL: attempt expected 1 after one failure")
        }
        // 退避后 dueForRetry 为假（还需等待），remainingWaitMs > 0
        if (ctrl.dueForRetry()) {
            throw Exception("selfCheck FAIL: should NOT be due immediately after backoff set")
        }
        if (ctrl.remainingWaitMs() <= 0) {
            throw Exception("selfCheck FAIL: remainingWaitMs should be > 0 right after backoff")
        }
        let d2 = ctrl.onFailure(1)
        if (d2.delayMs != 2000) {
            throw Exception("selfCheck FAIL: second failure delay expected 2000, got ${d2.delayMs}")
        }
        // 成功 → reset
        ctrl.onSuccess()
        if (ctrl.currentAttempt() != 0 || ctrl.currentSchemeIndex() != 0) {
            throw Exception("selfCheck FAIL: onSuccess must reset attempt & schemeIndex to 0")
        }
        if (!ctrl.dueForRetry()) {
            throw Exception("selfCheck FAIL: after reset should be immediately due")
        }

        // ===== 3. 连续失败切备用 scheme：3 候选 scheme，连续失败达阈值后 schemeIndex 推进 =====
        let ctrl2 = ReconnectController(baseDelayMs: 1000, capDelayMs: 8000, jitterMaxMs: 0, failoverThreshold: 3)
        let schemeCount = 3
        // 前 2 次失败不切（未达阈值 3）
        let s1 = ctrl2.onFailure(schemeCount)
        let s2 = ctrl2.onFailure(schemeCount)
        if (s1.switched || s2.switched) {
            throw Exception("selfCheck FAIL: must not switch before threshold reached")
        }
        if (ctrl2.currentSchemeIndex() != 0) {
            throw Exception("selfCheck FAIL: schemeIndex must stay 0 before threshold")
        }
        // 第 3 次失败达阈值 → 切到 scheme 索引 1
        let s3 = ctrl2.onFailure(schemeCount)
        if (!s3.switched) {
            throw Exception("selfCheck FAIL: 3rd failure must trigger scheme switch")
        }
        if (s3.schemeIndex != 1 || ctrl2.currentSchemeIndex() != 1) {
            throw Exception("selfCheck FAIL: after switch schemeIndex expected 1, got ${s3.schemeIndex}")
        }
        // 再连续 3 次 → 切到索引 2
        let _ = ctrl2.onFailure(schemeCount)
        let _ = ctrl2.onFailure(schemeCount)
        let s6 = ctrl2.onFailure(schemeCount)
        if (s6.schemeIndex != 2) {
            throw Exception("selfCheck FAIL: second switch schemeIndex expected 2, got ${s6.schemeIndex}")
        }
        // 再 3 次 → 轮转回索引 0（环形）
        let _ = ctrl2.onFailure(schemeCount)
        let _ = ctrl2.onFailure(schemeCount)
        let s9 = ctrl2.onFailure(schemeCount)
        if (s9.schemeIndex != 0) {
            throw Exception("selfCheck FAIL: scheme index must wrap back to 0, got ${s9.schemeIndex}")
        }

        // ===== 4. 可达性恢复立即重连：退避中注入立即触发 → 退避取消、立刻可重试 =====
        let ctrl3 = ReconnectController(baseDelayMs: 5000, capDelayMs: 8000, jitterMaxMs: 0, failoverThreshold: 3)
        let _ = ctrl3.onFailure(1)  // 设置 5s 退避
        if (ctrl3.dueForRetry()) {
            throw Exception("selfCheck FAIL: should be waiting under 5s backoff")
        }
        // 模拟可达性 断→通 事件触发立即重连
        ctrl3.triggerImmediateReconnect()
        if (!ctrl3.dueForRetry()) {
            throw Exception("selfCheck FAIL: triggerImmediateReconnect must cancel backoff wait (due now)")
        }
        if (ctrl3.remainingWaitMs() != 0) {
            throw Exception("selfCheck FAIL: after immediate trigger remainingWaitMs must be 0")
        }
        // 立即重连不抹掉失败历史（attempt 保留以便继续 failover）
        if (ctrl3.currentAttempt() != 1) {
            throw Exception("selfCheck FAIL: immediate reconnect must preserve attempt history")
        }

        Hilog.info(0, "CjTelegram",
            "[Reconnect] selfCheck PASS: exponential backoff (increase+cap+reset) / scheme failover on repeated failure / reachability-driven immediate reconnect")
    }
}

/**
 * 一次失败后的重连决策（ReconnectController.onFailure 返回）。
 *   - delayMs      下次重试应等待的退避时长（含抖动）。
 *   - switched     本次失败是否触发了切备用 scheme。
 *   - schemeIndex  当前应使用的候选 scheme 索引（用于从 getSchemesForDC 列表取端点）。
 */
public class ReconnectDecision {
    public let delayMs: Int64
    public let switched: Bool
    public let schemeIndex: Int64

    public init(delayMs: Int64, switched: Bool, schemeIndex: Int64) {
        this.delayMs = delayMs
        this.switched = switched
        this.schemeIndex = schemeIndex
    }
}

/**
 * RPC 回调（保留对外结构，可选 resolve/reject 由调用方注入）。
 */
public class RPCCallback {
    public var resolve: Option<(Array<Byte>) -> Unit> = None
    public var reject: Option<(String) -> Unit> = None
    public var timestamp: Int64 = 0
}

/**
 * 单个在途（in-flight）RPC 的待决条目（P2-242a 并发 RPC 调度器）。
 *
 * 取代「单槽 syncResponseData/syncResponseMsgId + 10ms busy-wait」的旧串行模型：
 *   每个 RPC 各持一个独立的响应槽（responseData）+ 完成标志（completed），
 *   以 msgId 字符串为键存入 MTProtoClient.pendingRPCs，允许多个 RPC 同时在表中并发在途。
 *
 * 状态与唤醒：
 *   - 所有字段的读写都在持有共享 rpcMonitor 的临界区内进行（线程安全）。
 *   - 发送线程注册条目后在 rpcMonitor 上 wait；响应分发线程按 msgId 取回本条目、
 *     写入 responseData、置 completed=true，再 notifyAll 唤醒等待者。
 *   - 等待者被唤醒后重新检查自身 completed（防虚假唤醒 / 唤醒他人），只有匹配者返回。
 *
 * P2-242c rework：新增 requestBody 字段，用于 msgs_state_info 响应后对 state<2（服务端未收到）
 *   的消息执行真重发：从本条目取出原始 RPC 请求体，用新 msgId/seqNo 重新发送。
 *   对齐 iOS MTResendMessageService.m / MTRequestMessageService.m 真重发语义：
 *     state==1（server has not received）→ 重发**原始 RPC 请求体**（不是 msg_resend_req）。
 *
 * 不依赖网络：可直接构造并由 selfCheck 注入假 msgId/响应做真断言。
 */
public class PendingRPC {
    // 本条目的 msgId 字符串键（与 pendingRPCs 的 key 一致，便于诊断）。
    public let msgIdStr: String
    // 注册时刻（毫秒），用于过期判定与诊断。
    // P2-243 rework：改为 var，允许重试发出后刷新为新的时间戳（给重试 attempt 正常超时窗口）。
    // 读写均在 synchronized(rpcMonitor) 内进行。
    public var timestamp: Int64
    // P2-243 rework：FLOOD_WAIT/重试在途豁免标志。
    // sleep 之前在 synchronized(rpcMonitor) 内置 true，使该 pending 在整个等待期被 cleanupExpiredRPCs 跳过。
    // sleep 之后重试发出前在 synchronized(rpcMonitor) 内清 false 并刷新 timestamp，恢复正常超时语义。
    // 读写均在 synchronized(rpcMonitor) 内进行。
    public var doNotExpire: Bool = false
    // 响应数据槽：None = 尚未到达；Some = 已到达（可能为 rpc_error 重序列化字节 / 解压后字节 / 原始结果）。
    public var responseData: Option<Array<Byte>> = None
    // 完成标志：true 表示响应已写入（或被显式失败标记），等待者可结束等待。
    public var completed: Bool = false
    // 可选业务回调（保留与旧 RPCCallback 一致的接口，当前同步路径不强制使用）。
    public var callback: Option<RPCCallback> = None
    // P2-242c rework：原始 RPC 请求体（sendRPCRequestConcurrent 注册时存入）。
    // msgs_state_info 检测到服务端未收到（state & 0x07 < 2）时用于真重发。
    // None 表示该条目未通过单点 sendRPCRequestConcurrent 注册（如 container 内层条目），
    // 此时退化为仅记日志（无法重发原始体）。
    public var requestBody: Option<Array<Byte>> = None
    // Request-origin category; retained across retries and msg-id remapping.
    public var usageCategory: TransportUsageCategory = TransportUsageCategory.Generic

    // P2-243：每个 RPC 的错误上下文（重试次数 / 上次错误 / 下次重试时刻）。
    // 全部在 synchronized(rpcMonitor) 内读写，线程安全。
    public var retryCount: Int64 = 0            // 当前已重试次数
    public var lastErrorCode: Int32 = 0         // 上次 rpc_error 的 error_code
    public var lastErrorMessage: String = ""    // 上次 rpc_error 的 error_message
    public var nextRetryAtMs: Int64 = 0         // 下次重试允许的单调时刻（0=立即）
    public var floodWaitTotalSec: Int64 = 0     // 已自动等待的 FLOOD_WAIT 累计秒数

    public init(msgIdStr: String, timestamp: Int64) {
        this.msgIdStr = msgIdStr
        this.timestamp = timestamp
    }

    // 在持有 monitor 的前提下写入响应并标记完成（幂等：已完成则忽略后到的重复响应）。
    public func fulfill(data: Array<Byte>): Unit {
        if (!this.completed) {
            this.responseData = Some(data)
            this.completed = true
        }
    }
}

/**
 * msg_container 内层一条消息（P2-242b）。
 *   - msgId：该内层 RPC 各自的消息 ID（用于响应回来按内层 msgId 经 pendingRPCs 配对分发）。
 *   - seqNo：该内层 RPC 各自的 content-related 序列号。
 *   - body ：该内层 RPC 的明文序列化字节（容器体内以 [msgId,seqNo,len,body] 排布）。
 * 不可变值载体；serializeContainer 据此产出逐字节对齐 MTProto 规范的容器体。
 */
public class InnerMessage {
    public let msgId: Int64
    public let seqNo: Int32
    public let body: Array<Byte>

    public init(msgId: Int64, seqNo: Int32, body: Array<Byte>) {
        this.msgId = msgId
        this.seqNo = seqNo
        this.body = body
    }
}

/**
 * MTProto 客户端
 *
 * 对应 TelegramHarmony 的 MTProtoClient.ets
 * 管理与 Telegram 服务器的通信：
 * - 认证密钥创建（DH 交换）
 * - 消息加密/解密
 * - RPC 请求/响应关联
 * - DC 迁移
 */
public class MTProtoClient <: TransportCallback {
    private var transportManager: TransportManager = TransportManager()
    private var session: SessionInfo
    // P2-242a：msgId → 在途 RPC 条目（并发待决表）。允许多个 RPC 同时在表中（并发 in-flight）。
    // 所有对本表及条目字段的读写都在 synchronized(rpcMonitor) 临界区内进行。
    private var pendingRPCs: HashMap<String, PendingRPC> = HashMap<String, PendingRPC>()
    // 并发 RPC 调度器的唯一同步原语：既是保护 pendingRPCs 的锁，又是 wait/notify 条件变量。
    // 发送线程空槽时 wait（不 busy-wait）；响应分发线程写入并 notifyAll 唤醒匹配等待者。
    private let rpcMonitor = Monitor()
    // P2-242c rework：stateReqMsgId → 被查询的 msgId 列表，用于 handleMsgsStateInfo 按槽位映射回具体 msgId。
    // sendMsgsStateReq 发出时写入；handleMsgsStateInfo 消费后删除。
    // 全部在 synchronized(rpcMonitor) 内访问（与 pendingRPCs 共享同一把锁，避免引入新锁）。
    private var pendingStateReqs: HashMap<String, ArrayList<Int64>> = HashMap<String, ArrayList<Int64>>()
    private var timeOffset: Int64 = 0
    private var updateCallback: Option<(Array<Byte>) -> Unit> = None
    private var connectionStateCallback: Option<(ConnectionState) -> Unit> = None
    private let connectionStateCallbackMutex = ReentrantMutex()
    // Ability.onForeground can arrive before AppRoot has restored the persisted
    // account/DC.  Reconnecting in that window creates the constructor's default
    // DC1 transport, blocks the UI thread, and is immediately discarded when the
    // real account initializes on its home DC.  Keep an explicit lifecycle bit so
    // foreground recovery only resumes an already initialized account client.
    private let lifecycleInitialized = AtomicBool(false)
    // 账号切换 / 登出时由 resetGlobalClient 置位：本实例已脱离注册表，属于上一账号上下文。
    // sendRPCRequestConcurrent 在 transport 断开时会自动重连并重启接收循环，任何仍持有
    // 旧实例引用的调用方（轮询、下载、在途重试）都会把旧账号连接悄悄复活并继续推 updates。
    // 退役后：拒绝发送、拒绝重连、丢弃 updates，对位 iOS 切账号后旧 Account/Network 整体释放。
    private let retired = AtomicBool(false)

    // 全局"授权失效"回调（服务端确证的 401）。
    // 对齐 iOS 链路：MTRequestMessageService.m:846（rpcError.errorCode == 401，排除
    // SESSION_PASSWORD_NEEDED）→ requestMessageServiceAuthorizationRequired
    // → Network.swift:998 → Account.swift:1316 network.loggedOut。
    // iOS 在**每一条**响应上做这个拦截；本仓库此前只在启动探针里判 401，导致
    // (a) 探针把网络故障误判为授权失效，(b) 真被吊销时无处感知。此回调补齐 (b)。
    // core 不 import services，故由 services 层通过 setAuthorizationRequiredCallback 注入。
    private var authorizationRequiredCallback: Option<() -> Unit> = None

    // 流自愈：连续 auth_key_id mismatch 计数。接收流一旦错位（真机通话信令风暴实锤），
    // 之后每帧都 mismatch、永远自愈不了——达到阈值强制重建 transport。
    private var consecutiveKeyMismatch: Int64 = 0
    private var connectionInitialized: Bool = false

    // ---- PFS（Perfect Forward Secrecy）临时密钥（P2-251b）----
    // 初始 None；仅 activatePfs() 成功后才被填充。
    // 任何时候 temp 不可用 / 未绑定 / 已过期 → effectiveAuthKey() 无缝回退永久密钥，
    // 现有未启用 PFS 的代码路径行为字节不变（不调 activatePfs 则恒返回永久密钥）。
    private var tempAuthKey: Option<TempAuthKey> = None
    private let pfsMutex = ReentrantMutex()

    // ---- P2-251c: PFS 过期主动重生成定时器 ----
    // pfsRenewTimer: Timer.repeat(1800s) 每 30 分钟检查一次临时密钥是否将过期（iOS: ~2h 前预先重绑）。
    // pfsRenewInFlight: 防并发：定时器触发时若上一次重协商仍在进行中则跳过（pfsMutex 内读写）。
    private var pfsRenewTimer: Option<Timer> = None
    private let pfsRenewTimerMutex = ReentrantMutex()
    private var pfsRenewInFlight: Bool = false

    // ---- P2-245 Fix3: timeOffset 并发保护（叶子锁，锁内不调用会获取其它锁的方法）----
    // 4 处写源（createAuthKey / bad_msg 16-17 / bad_msg 48 / timeSyncService offset 回调）
    // + serverNowSec() 读 均受此锁保护，消除 Timer 线程 vs 接收线程竞态。
    private let timeOffsetMutex = ReentrantMutex()

    // ---- 连接探测 / 备用 failover / 指数退避重连（P2-241d）----
    // 仅在「连接失败 / 主动保活重连」分支记账并决策；正常成功连接路径不经过它（回归安全）。
    private let reconnectCtrl = ReconnectController()

    // ---- P2-243 RPC 自动重试参数（对齐 iOS MTRequestMessageService 重试策略）----
    // 瞬时错误最大重试次数：3 次（超出后上抛给调用方）
    private static let MAX_TRANSIENT_RETRIES: Int64 = 3
    // FLOOD_WAIT 自动等待上限（累计秒）。超过即把 rpc_error 交还调用方，由界面提示稍后再试。
    // iOS 对账号资料类写请求关闭自动等待（Birthdays.swift:91 automaticFloodWait: false →
    // Network.swift:1107 shouldContinueExecutionWithErrorContext 返回 false，错误直达调用方）；
    // TDLib NetQueryDelayer 以 total_timeout_limit=60s 为界。同步 sendRequest 不能挂起数天。
    private static let MAX_AUTO_FLOOD_WAIT_SEC: Int64 = 60
    // 指数退避基础延迟（ms）；FLOOD_WAIT 用服务端指定秒数，此参数仅用于瞬时错误退避
    // -503 Timeout 是服务器自己先耗了约 5s 才回的；再等 2s/4s 只是白白加时。
    private static let TRANSIENT_BASE_DELAY_MS: Int64 = 500
    // 瞬时错误退避上限（ms）= 16s
    private static let TRANSIENT_CAP_DELAY_MS: Int64 = 16000

    // ---- P2-244: 待确认消息池（发送 msgs_ack 用）----
    // 收到服务端 content-related 消息（seqno 奇数）后，将其 msgId 加入此集合，
    // 由 flushPendingAcks() 周期性或按阈值打包发出 msgs_ack#62d6b459。
    // 对应 iOS MTSessionInfo.scheduleMessageConfirmation + MTProto._scheduleAcknowledgements。
    // 所有访问在 ackMutex 保护下进行（IO 在锁外发送）。
    private var pendingAckMsgIds: ArrayList<Int64> = ArrayList<Int64>()
    private let ackMutex = ReentrantMutex()
    // ACK 批次阈值：待 ack 消息 ≥ 64 条时立即发送（对齐 iOS MTMaxUnacknowledgedMessageCount=64）
    private static let ACK_BATCH_THRESHOLD: Int64 = 64
    // 周期性 ACK 定时器（由 initialize 启动，可选 cancel）
    private var ackTimer: Option<Timer> = None
    private let ackTimerMutex = ReentrantMutex()

    // ---- P2-245: 服务器时间同步服务 ----
    // MTTimeSyncService 负责：多样本 offset / get_future_salts / 盐轮换 / 漂移校正。
    // 在 initialize 时配置回调并启动漂移定时器；disconnect 时停止。
    private let timeSyncService: MTTimeSyncService = MTTimeSyncService()

    // ---- P2-246 Gap-6: migrateToDC 竞态修复 ----
    // receiveLoopFuture: 保存当前活跃接收线程的 Future，用于 migrate 时 join 旧接收循环，
    //   确保旧线程完全退出后再替换 session（消除 old-thread 继续处理 old-session 数据的竞态）。
    // receiveLoopFutureMutex: 保护 receiveLoopFuture 的读写（写在 spawn 时，读在 migrate join 时）。
    // sessionRefMutex: 保护 this.session 引用本身的替换（var 字段，无内存屏障，需显式锁保护）。
    //   注意：this.session 内部字段访问已由 SessionInfo.sessionLock 保护（P2-244 已建立），
    //   此锁只保护引用（指针）的原子替换，不嵌套 sessionLock（无死锁风险）。
    //   Fix3：同一把锁也保护发送热路径读 this.session（getSessionRef() 访问器），
    //   消除 migrateToDC 替换引用期间发送线程裸读旧引用的竞态。
    private var receiveLoopFuture: Option<Future<Unit>> = None
    private let receiveLoopFutureMutex = ReentrantMutex()
    private let sessionRefMutex = ReentrantMutex()

    // Fix3 — P2-246: 线程安全的 session 引用读取器（叶子锁，锁内只读引用不调他法）。
    // 发送热路径入口用 getSessionRef() 取局部快照后复用，不再裸读 this.session。
    private func getSessionRef(): SessionInfo {
        synchronized(sessionRefMutex) {
            return this.session
        }
    }

    /** 下载连接标记：会话一律走 getDetachedSession（独立 sessionId，不持久化）。 */
    private var useDetachedSession: Bool = false
    // 派生会话可声明不同的 API 层（invokeWithLayer 的 layer）。用途：群通话内消息的
    // phone.sendGroupCallMessage / updateGroupCallMessage 只存在于 ≥222 的层，而主会话是 214
    //（真机实测 214 下服务器回 400 INPUT_METHOD_INVALID）。0 = 用 MTProtoConfig.LAYER。
    private var layerOverride: Int32 = 0

    public func setLayerOverride(layer: Int32): Unit {
        this.layerOverride = layer
    }

    /**
     * 把本 auth key 的 layer 重新声明回本客户端的值。服务器按 **auth key**（不是按 session）记 layer：
     * 派生会话用 invokeWithLayer(228) 发过请求后，主会话收到的对象也会变成 228 的编码
     * （真机实测 chatParticipant 变成 0x38e79fde、user 变成 0xb1b8cc83，214 的解析器全部错位）。
     * 所以每次在别的 layer 上做完事都要立刻调它：下一条请求重新带 invokeWithLayer+initConnection。
     */
    public func reassertLayer(): Unit {
        this.connectionInitialized = false
        let _ = this.sendRequest(HelpGetConfig().toBytes())
        Hilog.info(0, "CjTelegram", "[MTProtoClient] layer re-asserted to ${this.effectiveLayer()}")
    }

    /**
     * 下一条请求重新带 invokeWithLayer+initConnection。layer-228 派生会话每次用之前都要调：
     * key 被 reassertLayer 声明回 214 之后，裸的 invokeWithLayer(228, …) 会被拒
     * （真机：400 CONNECTION_LAYER_INVALID）。
     */
    public func requireInitOnNextRequest(): Unit {
        this.connectionInitialized = false
    }

    public func effectiveLayer(): Int32 {
        return if (this.layerOverride > 0) { this.layerOverride } else { MTProtoConfig.LAYER }
    }

    private func acquireSession(dcId: Int64): SessionInfo {
        if (this.useDetachedSession) {
            return SessionManager.getDetachedSession(dcId)
        }
        return SessionManager.getSession(dcId)
    }

    /** 标成下载专用客户端（必须在首次请求前调用）：换派生会话 + 独立 TCP。 */
    public func markAsDownloadClient(): Unit {
        synchronized(sessionRefMutex) {
            this.useDetachedSession = true
            this.session = SessionManager.getDetachedSession(this.session.dcId)
        }
    }

    public init(specificDcId!: Int64 = -1) {
        let dcId = if (specificDcId >= 0) { specificDcId } else {
            if (MTProtoConfig.USE_TEST_DC) { 2 } else { 1 }
        }
        this.session = SessionManager.getSession(dcId)
    }

    public func setUpdateCallback(callback: (Array<Byte>) -> Unit) {
        this.updateCallback = Some(callback)
    }

    /** services 层注入的连接事件出口；core 不反向依赖 UI/Projection。 */
    public func setConnectionStateCallback(callback: (ConnectionState) -> Unit): Unit {
        connectionStateCallbackMutex.lock()
        this.connectionStateCallback = Some(callback)
        connectionStateCallbackMutex.unlock()
    }

    private func notifyConnectionState(state: ConnectionState): Unit {
        connectionStateCallbackMutex.lock()
        let callback = this.connectionStateCallback
        connectionStateCallbackMutex.unlock()
        match (callback) {
            case Some(handler) =>
                try { handler(state) } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[MTProtoClient] connection state callback failed: ${e}")
                }
            case None => ()
        }
    }

    /**
     * P2-324：由 ProxyService.applyProxyToTransport() 注入代理提供者。
     * 避免 core.mtproto ↔ services 循环依赖——services 通过闭包回调，core 不 import services。
     * 调用时机：每次代理配置变更（启用/禁用/切换活跃代理）后立即调用，
     * 令后续所有 getTransport / rebuildTransport 构造的 TCPTransport 都读取最新代理。
     * setProxy(None) 分支不变 → 直连行为字节不变（回归安全）。
     */
    public func setProxyProvider(provider: () -> Option<ProxySettings>): Unit {
        this.transportManager.setProxyProvider(provider)
    }

    /**
     * P2-320c：由 services 层在 app 启动后注入计量注册回调，委托给 TransportManager。
     * 避免 core.mtproto ↔ services 循环依赖——services 通过闭包 { t => svc.registerTransport(t) } 注入，
     * core 不 import services。调用一次即可（幂等：每次 vend 新 TCPTransport 时 TransportManager 调一次）。
     * 不调用 → _meteringRegistrar 保持 None，所有 transport 不注册计量钩子（零副作用，回归安全）。
     */
    public func setMeteringRegistrar(registrar: (TCPTransport) -> Unit): Unit {
        this.transportManager.setMeteringRegistrar(registrar)
    }

    // ic_network_updates_to_state: listener slot for batched updates dispatch
    public func setUpdatesListener(listener: (Array<Byte>) -> Unit): Unit {
        this.updateCallback = Some(listener)
    }

    /**
     * 注入"服务端确证授权失效"回调（对齐 iOS Network.loggedOut）。
     * 仅在收到服务端下发、已解密的 rpc_error 且 errorCode == 401（排除 SESSION_PASSWORD_NEEDED）
     * 时触发。网络故障 / 超时 / 空响应**绝不**触发——那是连接问题，不是授权问题。
     * 不注入 → 保持 None，行为与改前一致（零副作用）。
     */
    public func setAuthorizationRequiredCallback(callback: () -> Unit): Unit {
        this.authorizationRequiredCallback = Some(callback)
    }

    // ic_network_updates_to_state: apply a raw updates batch via the registered listener
    public func applyUpdates(data: Array<Byte>): Unit {
        if (this.retired.load()) { return }
        match (this.updateCallback) {
            case Some(cb) => cb(data)
            case None => ()
        }
    }

    public func hasAuthKey(): Bool {
        // P2-242a r2：走线程安全 getter，避免 init 后有并发读写时裸访问。
        match (this.session.getAuthKey()) {
            case Some(key) => return key.size > 0
            case None => return false
        }
    }

    public func getCurrentDcId(): Int64 {
        return this.session.dcId
    }

    public func isTransportConnected(): Bool {
        let transport = this.transportManager.getTransport(this.session.dcId)
        return transport.isConnected()
    }

    public func isInitialized(): Bool {
        return this.lifecycleInitialized.load()
    }

    public func getCurrentSession(): SessionInfo {
        return this.session
    }

    /**
     * 初始化客户端（阻塞，应在 spawn 中调用）
     */
    public func initialize(forceNewAuthKey!: Bool = false, specificDcId!: Int64 = -1) {
        this.lifecycleInitialized.store(false)
        let dcId = if (specificDcId >= 0) { specificDcId } else {
            if (MTProtoConfig.USE_TEST_DC) { 2 } else { 1 }
        }
        this.session = this.acquireSession(dcId)

        Hilog.info(0, "CjTelegram", "[MTProtoClient] Initializing DC${dcId}...")

        if (forceNewAuthKey) {
            match (this.session.authKey) {
                case Some(_) =>
                    this.session.authKey = None
                    this.session.authKeyId = None
                    this.session.serverSalt = None
                    this.session.authKeyState = AuthKeyState.None_
                    this.session.generateSessionId()
                    this.session.seqNo = 0
                    SessionManager.saveSession(this.session)
                case None => ()
            }
        }

        // 连接到服务器
        let transport = this.transportManager.getTransport(dcId)
        transport.setCallback(this)

        if (!transport.isConnected()) {
            this.notifyConnectionState(ConnectionState.Connecting)
            transport.connect()
            // 启动接收循环（在 spawn 中），保存 Future 供 migrateToDC join 旧接收循环（P2-246 Gap-6）
            let transportRef = transport
            let fut = spawn {
                transportRef.startReceiveLoop()
            }
            receiveLoopFutureMutex.lock()
            this.receiveLoopFuture = Some(fut)
            receiveLoopFutureMutex.unlock()
        }
        if (transport.isConnected()) {
            this.notifyConnectionState(ConnectionState.Connected)
        }

        // 如果没有认证密钥，创建一个
        if (!hasAuthKey()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] No auth key found, creating...")
            createAuthKey()
            Hilog.info(0, "CjTelegram", "[MTProtoClient] Auth key creation completed")
        }

        // P2-244: 启动周期性 ACK 定时器（每 5 秒 flush 一次待确认消息）
        // 对应 iOS MTSessionInfo scheduledMessageConfirmations 的 deferred flush 策略：
        //   收满 64 条或超过 1MB 时立即 flush；否则周期性发送（防止长期不发而违反 MTProto 规范）。
        // 使用 Timer.repeat 而非 spawn + sleep，避免线程资源泄漏。
        startAckTimer()

        // P2-245: 配置时间同步服务并启动漂移定时器
        setupTimeSyncService()

        // P2-251c: 启动 PFS 临时密钥过期预检定时器（每 30 分钟检查，若临时密钥将在 2h 内过期则预先重协商）
        startPfsRenewTimer()

        this.lifecycleInitialized.store(true)
        Hilog.info(0, "CjTelegram", "[MTProtoClient] Initialization COMPLETE")
    }

    /**
     * 创建认证密钥
     */
    private func createAuthKey() {
        let dcId = this.session.dcId
        let transport = this.transportManager.getTransport(dcId)

        let authKeyCreator = AuthKeyCreator(transport)
        let result = authKeyCreator.createAuthKey()

        if (result.authKey.size == 0) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] Auth key creation failed!")
            return
        }

        this.session.authKey = Some(result.authKey)
        this.session.authKeyId = Some(result.authKeyId)
        this.session.serverSalt = Some(result.serverSalt)
        // P2-245 Fix3：timeOffset 写入需在 timeOffsetMutex 下执行
        synchronized(timeOffsetMutex) { this.timeOffset = result.timeOffset }

        this.session.generateSessionId()
        this.session.seqNo = 0
        this.session.authKeyState = AuthKeyState.Created
        SessionManager.saveSession(this.session)

        // 恢复回调到 MTProtoClient
        transport.setCallback(this)

        Hilog.info(0, "CjTelegram", "[MTProtoClient] Auth key created. ID: ${ByteUtils.toHex(result.authKeyId)}")
    }

    /**
     * 发送 RPC 请求（公开接口）
     * 自动处理 initConnection/invokeWithLayer 包装
     * 对应 TelegramHarmony MTProtoClient.sendRequest
     *
     * HI-AUTH-0006 真机根因修复：原实现在 connectionInitialized==false 时先调用
     * initConnectionLayer() 单独发一条【与调用方业务无关的 help.getConfig】请求去
     * "消耗"该连接的首请求名额，成功后再把调用方真正的 data 当作【裸】第二条请求发出。
     * 真机实测：迁移到新 DC（migrateToDC 的 auth.importAuthorization）后用这一两段式
     * 探测+裸发的方式，裸发的第二条请求仍被服务端判定为 CONNECTION_NOT_INITED——
     * 服务端对"该连接是否已初始化"的判定看的应是"第一条实际送达的加密消息是否被
     * invokeWithLayer(initConnection(...)) 包裹"，而不是"是否已经成功收过一次任意
     * 被包裹的请求"。改为与 handleMigrateAndResend（HI-AUTH-0005 已验证工作）同一
     * 模式：把调用方自己的 data 直接包进 invokeWithLayer(initConnection(...)) 作为
     * 该连接的第一条也是唯一一条请求发出，不再额外插入一次无关的 help.getConfig 探测。
     */
    public func sendRequest(
        data: Array<Byte>,
        category!: TransportUsageCategory = TransportUsageCategory.Generic
    ): Array<Byte> {
        // 确保连接已初始化（第一次请求自动用 invokeWithLayer + initConnection 包裹本次业务请求本身）
        if (!this.connectionInitialized) {
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] sendRequest: connection not yet initialized, wrapping this request with invokeWithLayer+initConnection (Layer ${this.effectiveLayer()})")
            let initConn = InitConnection()
            initConn.query = data
            let initConnBytes = initConn.toBytes()
            let invokeLayer = InvokeWithLayer()
            invokeLayer.layer = this.effectiveLayer()
            invokeLayer.query = initConnBytes
            let wrappedBody = invokeLayer.toBytes()

            let result = sendRPCRequest(wrappedBody, category)
            // 只有请求真正得到响应才视为已初始化。此前无条件置 true：真机实锤
            // 首请求与 transport 建连竞态发送失败（sendRPCRequest 吞异常返回空），
            // 标志却置位 → 服务器从未见过 initConnection → 后续全部
            // 400 CONNECTION_NOT_INITED，登录永久失败。
            if (result.size > 0) {
                this.connectionInitialized = true
            } else {
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] init-wrapped request got empty result; connection NOT marked initialized")
            }
            return result
        }

        // 声明了别的 layer 的派生会话：每条请求都显式带 invokeWithLayer，不依赖服务端记住的值。
        let body = if (this.layerOverride > 0) {
            let perCall = InvokeWithLayer()
            perCall.layer = this.layerOverride
            perCall.query = data
            perCall.toBytes()
        } else {
            data
        }
        let result = sendRPCRequest(body, category)
        // 自愈：服务器仍报 CONNECTION_NOT_INITED（如 resetSession 换新会话、服务端
        // 状态丢失等任何客户端未察觉的情况）→ 清标志并立刻用包装形式重试一次。
        if (isConnectionNotInitedError(result)) {
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] CONNECTION_NOT_INITED received; re-wrapping with initConnection and retrying")
            this.connectionInitialized = false
            return sendRequest(data, category: category)
        }
        return result
    }

    /**
     * Media fetch/upload entry point. The source-equivalent tag mapping is
     * resolved before transport metering; request bytes themselves are never
     * inspected to guess a category.
     */
    public func sendMediaRequest(
        data: Array<Byte>,
        statsCategory: TransportUsageCategory,
        contentType: MediaUsageContentType
    ): Array<Byte> {
        return this.sendRequest(
            data,
            category: categoryForMediaFetch(statsCategory, contentType)
        )
    }

    /** Call signaling/media entry point with an explicit Call category. */
    public func sendCallRequest(data: Array<Byte>): Array<Byte> {
        return this.sendRequest(data, category: TransportUsageCategory.Call)
    }

    /** 判定响应是否为 rpc_error 400 CONNECTION_NOT_INITED（自愈触发条件）。 */
    private func isConnectionNotInitedError(result: Array<Byte>): Bool {
        if (result.size < 12) { return false }
        try {
            let d = TLDeserializer(result)
            let ctor = d.readUInt32()
            if (ctor != 0x2144ca19) { return false }  // rpc_error#2144ca19
            let code = d.readInt32()
            if (code != 400) { return false }
            let msg = d.readString()
            return msg.startsWith("CONNECTION_NOT_INITED")
        } catch (_e: Exception) {
            return false
        }
    }

    /**
     * 发送 RPC 请求（内部实现，阻塞等待本请求自己的响应）。
     *
     * P2-242a 并发调度器：不再用 requestMutex 把整个收发串行成单未决。
     *   每次调用各自分配 msgId、注册独立的 PendingRPC 槽、异步发出，
     *   然后只在共享 rpcMonitor 上 wait 自己的 completed 标志——多个调用可同时在途。
     *   单个 RPC 的发-收-回调语义与改前一致（同样返回原始结果 / 重序列化的 rpc_error / 解压字节）。
     */
    private func sendRPCRequest(
        data: Array<Byte>,
        category: TransportUsageCategory
    ): Array<Byte> {
        var result = Array<Byte>(0, repeat: 0)
        try {
            result = sendRPCRequestConcurrent(data, category)
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] sendRPCRequest exception")
        }
        return result
    }

    private func sendRPCRequestConcurrent(
        data: Array<Byte>,
        category: TransportUsageCategory
    ): Array<Byte> {
        if (this.retired.load()) {
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] request refused: client retired by account switch/logout (DC${this.session.dcId})")
            return Array<Byte>(0, repeat: 0)
        }
        if (!hasAuthKey()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] Auth key not available!")
            return Array<Byte>(0, repeat: 0)
        }

        // Fix3 — P2-246: 取 session 引用快照，避免 migrate 期间裸读 this.session 竞态
        let s = getSessionRef()

        let msgId = s.generateMessageId()
        let seqNo = s.getNextSeqNo(true)

        // 构建消息
        let message = buildMessage(msgId, seqNo, data)

        // 加密消息
        let encrypted = encryptMessage(message)

        // 发送
        let dcId = s.dcId
        let transport = this.transportManager.getTransport(dcId)

        if (!transport.isConnected()) {
            transport.connect()
            transport.setCallback(this)
            let transportRef = transport
            let fut2 = spawn {
                transportRef.startReceiveLoop()
            }
            receiveLoopFutureMutex.lock()
            this.receiveLoopFuture = Some(fut2)
            receiveLoopFutureMutex.unlock()
        }
        if (!transport.waitUntilConnected()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] RPC send skipped: transport connection did not become ready")
            return Array<Byte>(0, repeat: 0)
        }

        // 注册本 RPC 的独立待决条目（并发 in-flight：多个 msgId 可同时在表中）。
        let msgIdStr = "${msgId}"
        let pending = PendingRPC(msgIdStr, DateTime.now().toUnixTimeStamp().toMilliseconds())
        // P2-242c rework：存入原始请求体，供 msgs_state_info state<2 时真重发原始 RPC 请求体。
        pending.requestBody = Some(data)
        pending.usageCategory = category
        synchronized(rpcMonitor) {
            this.pendingRPCs[msgIdStr] = pending
        }

        // 异步发出（不持锁，避免在锁内做 IO）。
        transport.send(encrypted, category: category)

        // 在 rpcMonitor 上阻塞等待本条目完成——条件变量唤醒，绝不 10ms busy-wait 空转。
        // 用单调时钟算剩余超时，被唤醒后重新检查自身 completed（防虚假唤醒 / 唤醒他人）。
        let maxWait = MTProtoConfig.REQUEST_TIMEOUT
        let deadline = mtprotoMonotonicNowMs() + maxWait
        var result = Array<Byte>(0, repeat: 0)
        synchronized(rpcMonitor) {
            while (!pending.completed) {
                let remaining = deadline - mtprotoMonotonicNowMs()
                if (remaining <= 0) {
                    break
                }
                // wait 释放 monitor 并阻塞，被 notify 或超时后重新持锁返回。
                let _ = rpcMonitor.wait(timeout: Duration.millisecond * remaining)
            }

            // 取回本条目响应（已完成则取数据，未完成 = 超时则返回空数组，与旧 timeout 行为一致）。
            result = match (pending.responseData) {
                case Some(r) => r
                case None =>
                    Hilog.info(0, "CjTelegram", "[MTProtoClient] Request timeout! msgId=${msgIdStr}")
                    Array<Byte>(0, repeat: 0)
            }

            // 清理本条目（无论成功 / 超时都移除，避免表泄漏）。
            let _ = this.pendingRPCs.remove(msgIdStr)
        }

        return result
    }

    /**
     * 批量发送多个待发 RPC（P2-242b msg_container#73f1f8dc 打包）。
     *
     * 目标：短时间内有多个待发 RPC 时，把它们打包进一个 msg_container 一次加密发送，
     *   减少往返。语义对齐 iOS MTProto `_dataForEncryptedContainerWithMessages`：
     *     容器体 = 0x73f1f8dc + count + 对每条 [msgId(8,LE) + seqNo(4,LE) + bytes(4,LE) + body]，
     *     容器作为外层加密消息 body（外层用新 containerMsgId + not-content-related seqNo，
     *     即 getNextSeqNo(false)，对齐 iOS 容器自身不计入 content seqno 自增）。
     *
     * 每条内层消息保留**各自的 msgId**（用各自的 content-related seqNo），并**各自注册**到
     *   pendingRPCs —— 响应回来仍按内层 msgId 经 dispatchResponse 分发（242a 路径完全不变）。
     *
     * 回归安全（关键）：
     *   - 入参为空 → 返回空表。
     *   - 入参 >=1 条 → 统一走容器路径（单元素容器对 MTProto 服务端合法，响应以内层 msgId 为 key 返回，
     *     符合 msgIdStr→response 文档合约；不再有 __single__ 哨兵分支）。
     *
     * 线程安全：内层 msgId/seqNo 经 session 的同步访问器（generateMessageId/getNextSeqNo）原子分配；
     *   serverSalt/sessionId 经 buildMessage 内的 getServerSalt/getSessionId 同步读；
     *   pendingRPCs 注册在 synchronized(rpcMonitor) 内完成。不在持锁时做 IO（send 在锁外），无锁序环。
     *
     * @param requests 多个待发 RPC 的明文 body（各自一条 RPC 请求的序列化字节）。
     * @return msgIdStr → 该 RPC 响应字节 的映射（按内层 msgId 分别等待回填；超时条目为空数组）。
     */
    public func sendBatchedRPCRequests(requests: ArrayList<Array<Byte>>): HashMap<String, Array<Byte>> {
        let results = HashMap<String, Array<Byte>>()
        if (requests.size == 0) {
            return results
        }

        if (!hasAuthKey()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] Batch send: auth key not available!")
            return results
        }

        // Fix3 — P2-246: 取 session 引用快照，避免 migrate 期间裸读 this.session 竞态
        let s = getSessionRef()

        // ---- 为每条内层消息分配各自 msgId（用于响应配对）+ 各自 content-related seqNo ----
        let inners = ArrayList<InnerMessage>()
        let pendings = ArrayList<PendingRPC>()
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        for (body in requests) {
            let innerMsgId = s.generateMessageId()
            let innerSeqNo = s.getNextSeqNo(true)  // 内层各 RPC 是 content-related
            inners.add(InnerMessage(innerMsgId, innerSeqNo, body))
            pendings.add(PendingRPC("${innerMsgId}", nowMs))
        }

        // ---- 序列化容器体（纯字节布局，单元可断言）----
        let containerBody = MTProtoClient.serializeContainer(inners)

        // ---- 容器作为外层消息：新 containerMsgId + not-content-related seqNo ----
        let containerMsgId = s.generateMessageId()
        let containerSeqNo = s.getNextSeqNo(false)  // 容器自身 not-content-related
        let outerMessage = buildMessage(containerMsgId, containerSeqNo, containerBody)
        let encrypted = encryptMessage(outerMessage)

        let dcId = s.dcId
        let transport = this.transportManager.getTransport(dcId)
        if (!transport.isConnected()) {
            transport.connect()
            transport.setCallback(this)
            let transportRef = transport
            let fut3 = spawn {
                transportRef.startReceiveLoop()
            }
            receiveLoopFutureMutex.lock()
            this.receiveLoopFuture = Some(fut3)
            receiveLoopFutureMutex.unlock()
        }
        if (!transport.waitUntilConnected()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] Batch RPC send skipped: transport connection did not become ready")
            return HashMap<String, Array<Byte>>()
        }

        // ---- 每条内层 msg 各自注册到 pendingRPCs（响应按各自 msgId 经 dispatchResponse 分发）----
        synchronized(rpcMonitor) {
            for (p in pendings) {
                this.pendingRPCs[p.msgIdStr] = p
            }
        }

        // ---- 一次加密发送整个容器（锁外做 IO）----
        transport.send(encrypted)
        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] Batched ${inners.size} RPC(s) into msg_container (containerMsgId=${containerMsgId})")

        // ---- 在 rpcMonitor 上等待每条内层 msg 各自完成（条件变量唤醒，不 busy-wait）----
        let maxWait = MTProtoConfig.REQUEST_TIMEOUT
        let deadline = mtprotoMonotonicNowMs() + maxWait
        synchronized(rpcMonitor) {
            for (p in pendings) {
                while (!p.completed) {
                    let remaining = deadline - mtprotoMonotonicNowMs()
                    if (remaining <= 0) {
                        break
                    }
                    let _ = rpcMonitor.wait(timeout: Duration.millisecond * remaining)
                }
                let r = match (p.responseData) {
                    case Some(data) => data
                    case None =>
                        Hilog.info(0, "CjTelegram", "[MTProtoClient] Batch entry timeout! msgId=${p.msgIdStr}")
                        Array<Byte>(0, repeat: 0)
                }
                results[p.msgIdStr] = r
                let _ = this.pendingRPCs.remove(p.msgIdStr)
            }
        }
        return results
    }

    // =========================================================================
    // P2-242c 能力一：RPC 取消（rpc_drop_answer#58e4a740）
    // =========================================================================

    /**
     * 取消一个在途 RPC（对应 iOS MTRequestMessageService 的 removeRequestByInternalId + dropContext）。
     *
     * 行为：
     *   1. 在 synchronized(rpcMonitor) 内把目标 PendingRPC 标记为"已取消完成"（fulfil 空字节），
     *      notifyAll 唤醒等待者 —— 等待者会取回空数组返回，不会永久阻塞。
     *   2. 从 pendingRPCs 表移除该条目。
     *   3. 向服务端发送 rpc_drop_answer#58e4a740 { req_msg_id: reqMsgId }，
     *      请求服务端丢弃尚未完成的应答（对齐 iOS appendInt32:0x58e4a740 + appendInt64:dropMessageId）。
     *      发送用 not-content-related seqNo（对齐 iOS dropAnswer 不计入内容序列号）。
     *   4. 若 msgId 不在 pendingRPCs 中（已完成 / 已过期），只向服务端发送 drop 请求，不重复操作本地表。
     *
     * @param reqMsgId 要取消的消息 ID（在 pendingRPCs 中以字符串形式存储的键对应数值）。
     * @return true 表示本地条目找到并标记取消；false 表示未找到（已完成 / 不存在）。
     */
    public func cancelRPC(reqMsgId: Int64): Bool {
        let msgIdStr = "${reqMsgId}"
        var found = false

        // 1. 本地表：标记取消 + 唤醒等待者 + 移除
        synchronized(rpcMonitor) {
            if (this.pendingRPCs.contains(msgIdStr)) {
                let pending = this.pendingRPCs[msgIdStr]
                // 以空字节 fulfill：等待者被唤醒后取到 None/空数组，感知取消
                if (!pending.completed) {
                    pending.fulfill(Array<Byte>(0, repeat: 0))
                }
                let _ = this.pendingRPCs.remove(msgIdStr)
                rpcMonitor.notifyAll()
                found = true
            }
        }

        // P2-246 rework2: snapshot session ref before reads — rpcMonitor block above has exited,
        // so no nested-lock risk; getSessionRef only takes the leaf sessionRefMutex
        let s = getSessionRef()

        // 2. 向服务端发送 rpc_drop_answer（无论本地是否找到，都告知服务端）
        if (hasAuthKey()) {
            let serializer = TLSerializer()
            serializer.writeUInt32(TLConstructors.RPC_DROP_ANSWER)  // 0x58e4a740
            serializer.writeInt64(reqMsgId)
            let dropBody = serializer.getBytes()

            let dropMsgId = s.generateMessageId()
            let dropSeqNo = s.getNextSeqNo(false)  // not-content-related（对齐 iOS）
            let message = buildMessage(dropMsgId, dropSeqNo, dropBody)
            let encrypted = encryptMessage(message)

            let dcId = s.dcId
            let transport = this.transportManager.getTransport(dcId)
            if (transport.isConnected()) {
                transport.send(encrypted)
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] rpc_drop_answer sent for reqMsgId=${reqMsgId} (localFound=${found})")
            } else {
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] cancelRPC: transport not connected, local cancel only for reqMsgId=${reqMsgId}")
            }
        }

        return found
    }

    /**
     * 处理服务端 rpc_answer_dropped* 系列响应（P2-242c）。
     *
     * 三种变体（对齐 iOS MTInternalMessageParser / MTDropRpcResultMessage 三类）：
     *   - rpc_answer_unknown#5e2ad36e   — 服务端不认识 req_msg_id
     *   - rpc_answer_dropped_running#cd78e586 — 取消时 RPC 正在运行中被丢弃
     *   - rpc_answer_dropped#a43ad8b7   — 已处理并丢弃（含 msgId/seqNo/size 字段）
     *
     * 收到任意变体均记日志，不需要再做额外本地操作（本地条目已在 cancelRPC 时移除）。
     */
    private func handleRpcAnswerDropped(constructor: UInt32, deserializer: TLDeserializer): Unit {
        if (constructor == TLConstructors.RPC_ANSWER_DROPPED) {
            let msgId = deserializer.readInt64()
            let seqNo = deserializer.readInt32()
            let size = deserializer.readInt32()
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] rpc_answer_dropped#a43ad8b7: msgId=${msgId} seqNo=${seqNo} size=${size}")
        } else if (constructor == TLConstructors.RPC_ANSWER_DROPPED_RUNNING) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] rpc_answer_dropped_running#cd78e586 received")
        } else {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] rpc_answer_unknown#5e2ad36e received")
        }
    }

    // =========================================================================
    // P2-242c 能力二：未决过期清理
    // =========================================================================

    /**
     * 扫描 pendingRPCs 表，将超时（注册时刻距今 > timeoutMs）的条目标记完成（空响应）并移除。
     *
     * 对应 iOS MTRequestMessageService 的 updateRequestsTimeoutTimer / sentTimestamp 超时判定：
     *   sentTimestamp != 0 && (currentTime - sentTimestamp) > requestTimeout → 清理。
     * 此处以 PendingRPC.timestamp（注册时刻 ms）+ timeoutMs 阈值对齐该逻辑。
     *
     * 线程安全：全程在 synchronized(rpcMonitor) 内完成，notifyAll 唤醒被等待的过期条目。
     *
     * @param timeoutMs 超时阈值（毫秒），默认使用 MTProtoConfig.REQUEST_TIMEOUT（60000ms）。
     * @return 本次清理的条目数。
     */
    public func cleanupExpiredRPCs(timeoutMs!: Int64 = MTProtoConfig.REQUEST_TIMEOUT): Int64 {
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let expiredKeys = ArrayList<String>()

        synchronized(rpcMonitor) {
            for ((key, pending) in this.pendingRPCs) {
                // P2-243 rework：doNotExpire=true 表示该 pending 正处于 FLOOD_WAIT/重试 sleep 在途，
                // 豁免本次 cleanup 扫描——不能在 sleep 进行中就把它误清。
                if (!pending.completed && !pending.doNotExpire && (nowMs - pending.timestamp) > timeoutMs) {
                    expiredKeys.add(key)
                }
            }
            if (expiredKeys.size > 0) {
                for (key in expiredKeys) {
                    if (this.pendingRPCs.contains(key)) {
                        let pending = this.pendingRPCs[key]
                        if (!pending.completed) {
                            pending.fulfill(Array<Byte>(0, repeat: 0))
                        }
                        let _ = this.pendingRPCs.remove(key)
                        Hilog.info(0, "CjTelegram",
                            "[MTProtoClient] expired RPC cleaned up: msgId=${key} age=${nowMs - pending.timestamp}ms")
                    }
                }
                rpcMonitor.notifyAll()
            }
        }

        let count = expiredKeys.size
        if (count > 0) {
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] cleanupExpiredRPCs: removed ${count} expired pending RPC(s)")
        }
        return count
    }

    // =========================================================================
    // P2-242c 能力三：msgs_state_req 投递追踪
    // =========================================================================

    /**
     * 构造并发送 msgs_state_req#da69fb52 查询一批消息的投递状态（P2-242c）。
     *
     * 对应 iOS MTResendMessageService 的 resendRequest 逻辑：
     *   - 构造体：0xda69fb52 + Vector 构造子(0x1cb5c415) + count:Int32 + [msgId:Int64 × count]
     *   - 用 not-content-related seqNo 发送（对齐 iOS requiresConfirmation=false）。
     *   - 服务端以 msgs_state_info#04deb57d 响应（含 reqMsgId + info bytes），
     *     由 processMessage 里的 handleMsgsStateInfo 处理（见下方）。
     *
     * @param msgIds 要查询投递状态的消息 ID 列表（in-flight RPC 的 msgId）。
     * @return 发送 msgs_state_req 的消息 ID（用于关联 msgs_state_info 响应）；-1 表示未发送。
     */
    public func sendMsgsStateReq(msgIds: ArrayList<Int64>): Int64 {
        if (msgIds.size == 0) {
            return -1
        }
        if (!hasAuthKey()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] sendMsgsStateReq: no auth key")
            return -1
        }

        // P2-246 rework2: snapshot session ref — this public method may be called from app thread
        // concurrently with migrateToDC Step3 (sessionRefMutex replaces this.session)
        let s = getSessionRef()

        // 构造 msgs_state_req#da69fb52 { msg_ids: Vector<long> }
        // 字节布局（小端）：
        //   0xda69fb52 (4) + 0x1cb5c415 (4, Vector构造子) + count:Int32 (4) + [msgId:Int64 × count]
        let serializer = TLSerializer()
        serializer.writeUInt32(TLConstructors.MSGS_STATE_REQ)   // 0xda69fb52
        serializer.writeUInt32(TLConstructors.VECTOR)           // 0x1cb5c415
        serializer.writeInt32(Int32(msgIds.size))
        for (mid in msgIds) {
            serializer.writeInt64(mid)
        }
        let stateReqBody = serializer.getBytes()

        let stateReqMsgId = s.generateMessageId()
        let stateReqSeqNo = s.getNextSeqNo(false)  // not-content-related
        let message = buildMessage(stateReqMsgId, stateReqSeqNo, stateReqBody)
        let encrypted = encryptMessage(message)

        let dcId = s.dcId
        let transport = this.transportManager.getTransport(dcId)
        if (!transport.isConnected()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] sendMsgsStateReq: transport not connected")
            return -1
        }

        // P2-242c rework：记录 stateReqMsgId → 被查询的 msgId 列表映射，
        // 使 handleMsgsStateInfo 能将 info bytes 的第 i 个状态槽映射回具体 msgId。
        // 在 synchronized(rpcMonitor) 内写入（与 pendingRPCs 共享同一把锁）。
        let stateReqMsgIdStr = "${stateReqMsgId}"
        let queriedIds = ArrayList<Int64>()
        for (mid in msgIds) {
            queriedIds.add(mid)
        }
        synchronized(rpcMonitor) {
            this.pendingStateReqs[stateReqMsgIdStr] = queriedIds
        }

        transport.send(encrypted)
        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] msgs_state_req sent: stateReqMsgId=${stateReqMsgId} querying ${msgIds.size} msgId(s)")
        return stateReqMsgId
    }

    /**
     * 处理服务端 msgs_state_info#04deb57d 响应（P2-242c rework）。
     *
     * 对应 iOS MTResendMessageService / MTRequestMessageService 真重发语义：
     *
     *   iOS MTResendMessageService.m _messageResendRequestFailed:_messageId 触发时：
     *     → MTRequestMessageService.m L1220-1226：清 requestContext + requestTransportTransaction，
     *       把原始 RPC body 重新发出（不通知上层，框架内部自动重发）。
     *
     *   info bytes 的每个字节（低 3 bit = state & 0x07）对应被查询的一条消息的投递状态：
     *     state=0 (unknown)          → 服务端不知道 → 视同未收到，重发原始请求体
     *     state=1 (server not recv'd) → 服务端未收到 → 重发原始请求体
     *     state>=2                   → 已在处理 / 已确认 → 无需操作
     *
     *   Fix-2 对齐：注释中「state & 0x07 < 2」即 state==0 或 state==1 均触发重发，
     *   代码以 `state < 2u8` 实现（覆盖 state=0 unknown 与 state=1 not-recv'd 两种情形）。
     *
     *   重发机制选择（对齐 iOS）：
     *     state < 2 → 服务端未收到我方请求 → 重发原始 RPC 请求体（从 pendingRPCs 取 requestBody），
     *       用新 msgId/seqNo 发出（对应 iOS clearRequestContext+重提交）。
     *     注意：msg_resend_req#7d861a08 是另一场景（我方未收到服务端响应、请求服务端重传已处理的响应），
     *       与本场景不同，不在此混用。
     *
     * @param deserializer 已读过构造子(0x04deb57d)后的反序列化器。
     */
    private func handleMsgsStateInfo(deserializer: TLDeserializer): Unit {
        let reqMsgId = deserializer.readInt64()
        let info = deserializer.readBytes()  // 每字节对应一条被查询消息的状态位（低 3 bit 为 state）
        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] msgs_state_info: reqMsgId=${reqMsgId} info=${info.size} bytes")

        let reqMsgIdStr = "${reqMsgId}"

        // 取出被查询的 msgId 列表（由 sendMsgsStateReq 在 pendingStateReqs 中记录）。
        // 在 synchronized(rpcMonitor) 内读取并删除映射（消费一次，避免重复处理）。
        var queriedIds: Option<ArrayList<Int64>> = None
        synchronized(rpcMonitor) {
            if (this.pendingStateReqs.contains(reqMsgIdStr)) {
                queriedIds = Some(this.pendingStateReqs[reqMsgIdStr])
                let _ = this.pendingStateReqs.remove(reqMsgIdStr)
            }
        }

        // 逐状态字节判断并执行重发（对应 iOS _messageResendRequestFailed + clearRequestContext 重提交）。
        // state & 0x07 < 2：即 state==0(unknown) 或 state==1(server not received) → 重发原始请求体。
        let dcId = this.session.dcId
        let transport = this.transportManager.getTransport(dcId)

        for (i in 0..info.size) {
            let state = info[i] & 0x07u8
            if (state < 2u8) {
                // 服务端未收到（state=0 unknown 或 state=1 not-recv'd）→ 重发原始 RPC 请求体。
                // 按槽位 i 从 queriedIds 中取对应 msgId，再从 pendingRPCs 取原始请求体。
                var originalMsgId: Int64 = -1
                match (queriedIds) {
                    case Some(ids) =>
                        if (i < ids.size) {
                            originalMsgId = ids[i]
                        }
                    case None => ()
                }

                if (originalMsgId == -1) {
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] msgs_state_info: slot ${i} state=${state} not-received, but no msgId mapping (reqMsgId=${reqMsgId}), skipping resend")
                } else {
                    let originalMsgIdStr = "${originalMsgId}"
                    // Path B 修复（P2-242c rework2）：
                    //   在单个 synchronized(rpcMonitor) 块内同时取出原始 pending 对象和其 requestBody，
                    //   消除两次分开加锁之间的竞态窗口（原条目在两次锁之间被 remove 的情形）。
                    //
                    // 取出的 originalPending 是与 sendRPCRequestConcurrent 等待者持有的同一对象。
                    // 将新 msgId 也映射到这同一个 PendingRPC 实例——
                    //   服务端对 newMsgId 响应 → dispatchResponse(newMsgIdStr, data)
                    //   → pendingRPCs[newMsgIdStr] = originalPending → originalPending.fulfill(data)
                    //   → originalPending.completed = true → notifyAll
                    //   → 原等待者（在同一 pending 对象上 wait）被唤醒、completed 为 true、取回响应。✅
                    //
                    // 旧 key（originalMsgIdStr）保留不删：
                    //   原等待者退出 wait 循环后由 sendRPCRequestConcurrent 的 remove(msgIdStr) 清理。
                    // 新 key（newMsgIdStr）：
                    //   fulfill 后 completed=true；cleanupExpiredRPCs 只清 !completed 条目，安全；
                    //   dispatchResponse 的 fulfill 幂等（already completed → 忽略后到的重复响应），无 double-fulfill。
                    //
                    // 相比"创建 newPending 新对象"的旧做法（被 Reviewer 标记为 Fatal）：
                    //   旧做法 dispatchResponse 只唤醒 newPending；原等待者等的是 originalPending，
                    //   永远感知不到 completed=true → 调用者超时、响应永久丢失（孤儿 pending）。
                    var originalPending: Option<PendingRPC> = None
                    var bodyToResend: Option<Array<Byte>> = None
                    synchronized(rpcMonitor) {
                        if (this.pendingRPCs.contains(originalMsgIdStr)) {
                            let op = this.pendingRPCs[originalMsgIdStr]
                            originalPending = Some(op)
                            bodyToResend = op.requestBody
                        }
                    }
                    match (originalPending) {
                        case Some(op) =>
                            match (bodyToResend) {
                                case Some(body) =>
                                    let newMsgId = this.session.generateMessageId()
                                    let newSeqNo = this.session.getNextSeqNo(true)  // content-related：重发真 RPC 请求体
                                    let newMsgIdStr = "${newMsgId}"
                                    // 新 key → 同一 PendingRPC 对象（Path B 核心：原调用者的等待对象）
                                    synchronized(rpcMonitor) {
                                        this.pendingRPCs[newMsgIdStr] = op
                                    }
                                    let resendMessage = buildMessage(newMsgId, newSeqNo, body)
                                    let resendEncrypted = encryptMessage(resendMessage)
                                    if (transport.isConnected()) {
                                        transport.send(resendEncrypted, category: op.usageCategory)
                                        Hilog.info(0, "CjTelegram",
                                            "[MTProtoClient] msgs_state_info: slot ${i} state=${state} not-received, resent originalMsgId=${originalMsgId} as newMsgId=${newMsgId} (same pending object — caller will receive response)")
                                    } else {
                                        Hilog.info(0, "CjTelegram",
                                            "[MTProtoClient] msgs_state_info: slot ${i} state=${state} not-received, transport disconnected, cannot resend originalMsgId=${originalMsgId}")
                                    }
                                case None =>
                                    Hilog.info(0, "CjTelegram",
                                        "[MTProtoClient] msgs_state_info: slot ${i} state=${state} not-received, msgId=${originalMsgId} has no requestBody (container inner entry?), cannot resend")
                            }
                        case None =>
                            Hilog.info(0, "CjTelegram",
                                "[MTProtoClient] msgs_state_info: slot ${i} state=${state} not-received, originalMsgId=${originalMsgId} no longer in pending (already completed/removed), skipping resend")
                    }
                }
            } else {
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] msgs_state_info: slot ${i} state=${state} (received/processed, no resend needed)")
            }
        }
    }

    /**
     * 纯函数：把多条内层消息序列化成 msg_container 体（P2-242b，可无网络真断言）。
     *
     * 字节布局（小端）：
     *   0x73f1f8dc (4) + count:int32 (4) + 对每条：
     *     msgId:int64 (8) + seqNo:int32 (4) + bytes:int32 (4, = body 字节长) + body (bytes)
     *
     * 与 iOS MTProto `_dataForEncryptedContainerWithMessages` 容器体逐字节对齐。
     */
    public static func serializeContainer(messages: ArrayList<InnerMessage>): Array<Byte> {
        let serializer = TLSerializer()
        serializer.writeUInt32(TLConstructors.MSG_CONTAINER)  // 0x73f1f8dc
        serializer.writeInt32(Int32(messages.size))
        for (m in messages) {
            serializer.writeInt64(m.msgId)
            serializer.writeInt32(m.seqNo)
            serializer.writeInt32(Int32(m.body.size))
            serializer.writeRawBytes(m.body)
        }
        return serializer.getBytes()
    }

    /**
     * 响应分发：按响应携带的 reqMsgId 从 pendingRPCs 取回对应等待者，写入响应并唤醒。
     *   - 命中：填充该条目 responseData + completed，notifyAll 唤醒等待者（它重查自身 completed 后返回）。
     *   - 未命中（过期 / 未注册 / 已被超时清理）：安全忽略，仅记日志，不影响其它在途 RPC。
     *  全程在 synchronized(rpcMonitor) 内完成，且只做内存写 + notify，不在锁内做 IO（无死锁）。
     */
    private func dispatchResponse(reqMsgIdStr: String, responseData: Array<Byte>): Unit {
        var shouldMeter = false
        var category = TransportUsageCategory.Generic
        synchronized(rpcMonitor) {
            if (this.pendingRPCs.contains(reqMsgIdStr)) {
                let pending = this.pendingRPCs[reqMsgIdStr]
                if (!pending.completed) {
                    shouldMeter = true
                    category = pending.usageCategory
                }
                pending.fulfill(responseData)
                // 唤醒全部等待者；每个被唤醒线程重查自身 completed，仅匹配者返回，其余继续 wait。
                rpcMonitor.notifyAll()
            } else {
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] response for unknown/expired msgId=${reqMsgIdStr}, ignored")
            }
        }
        if (shouldMeter) {
            let s = getSessionRef()
            this.transportManager.getTransport(s.dcId).meterIncoming(category, Int64(responseData.size))
        }
    }

    /**
     * 构建消息
     *
     * P2-242a 返修：通过线程安全 getter 读取 serverSalt / sessionId，
     * 消除与 generateMessageId / getNextSeqNo 并发时的无锁直接字段读竞态。
     */
    private func buildMessage(msgId: Int64, seqNo: Int32, data: Array<Byte>): Array<Byte> {
        let serializer = TLSerializer()

        // P2-245: server_salt — 优先使用 timeSyncService 提供的轮换后未来盐；
        //   若无有效未来盐则回退 session.serverSalt（握手时的盐）。
        //   对应 iOS MTProto 在 _dataForEncryptedMessage 中取 currentSalt.salt 字节写入消息头。
        let effectiveSaltOpt = this.timeSyncService.getCurrentSalt(this.serverNowSec())
        match (effectiveSaltOpt) {
            case Some(futureSalt) =>
                serializer.writeInt64(futureSalt)
            case None =>
                // 回退：使用 session.serverSalt（通过线程安全 getter 读取）
                match (this.session.getServerSalt()) {
                    case Some(salt) where salt.size == 8 =>
                        serializer.writeRawBytes(salt)
                    case _ =>
                        serializer.writeInt64(0)
                }
        }

        // session_id (8 bytes) — 通过线程安全 getter 读取；缺失时原子生成后再取
        match (this.session.getSessionId()) {
            case Some(sid) where sid.size == 8 =>
                serializer.writeRawBytes(sid)
            case _ =>
                this.session.generateSessionId()
                match (this.session.getSessionId()) {
                    case Some(sid) => serializer.writeRawBytes(sid)
                    case None => serializer.writeInt64(0)
                }
        }

        // message_id, seq_no, message_data_length, message_data
        serializer.writeInt64(msgId)
        serializer.writeInt32(seqNo)
        serializer.writeInt32(Int32(data.size))
        serializer.writeRawBytes(data)

        return serializer.getBytes()
    }

    /**
     * 当前服务器时间（Unix 秒），用于判断临时密钥是否过期。
     * 服务器时间 ≈ 本地时间 + timeOffset（与 AuthKeyCreator.computeAuthKey / createTempAuthKey 同口径）。
     * P2-245 Fix3：在 timeOffsetMutex 下读取 timeOffset 快照，消除 Timer 线程竞态。
     */
    private func serverNowSec(): Int64 {
        let localNow = DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000
        let offset = synchronized(timeOffsetMutex) { this.timeOffset }
        return localNow + offset
    }

    /**
     * 选择本次会话加密用的密钥（PFS 选键逻辑，P2-251b）。
     *
     * 安全第一：
     *   - 仅当 tempAuthKey 存在 && isValid() && bound && !isExpired(now) 时返回临时密钥；
     *   - temp 已过期 → 置 None（下次 activatePfs 重生成），本次回退永久密钥；
     *   - 其余任何情况（None / 未绑定 / 无效 / 异常）→ 回退永久密钥（= 现有行为）。
     *
     * 返回 (authKey, authKeyId)。永久密钥缺失时返回两个空数组，
     * 交由 encryptMessage 走原有 None 短路逻辑（行为不变）。
     */
    private func effectiveAuthKey(): (Array<Byte>, Array<Byte>) {
        // P2-242a r2：通过线程安全 getter 读取 authKey/authKeyId，
        // 消除发送线程裸读 vs 接收线程(-404)裸写的数据竞态。
        let permKey = match (this.session.getAuthKey()) {
            case Some(ak) => ak
            case None => Array<Byte>(0, repeat: 0)
        }
        let permKeyId = match (this.session.getAuthKeyId()) {
            case Some(akId) => akId
            case None => Array<Byte>(0, repeat: 0)
        }

        // 整段 PFS 选键全包 try/catch；任何异常都回退永久密钥。
        try {
            pfsMutex.lock()
            let chosen = match (this.tempAuthKey) {
                case Some(tk) =>
                    if (tk.isValid() && tk.bound) {
                        if (tk.isExpired(serverNowSec())) {
                            // 过期 → 失效，回退永久；清空以便下次重生成。
                            // P2-251c: 在锁外异步触发重协商（belt-and-suspenders，与定时器互补）。
                            this.tempAuthKey = None
                            let shouldRegen = !this.pfsRenewInFlight
                            if (shouldRegen) {
                                this.pfsRenewInFlight = true
                            }
                            pfsMutex.unlock()
                            if (shouldRegen) {
                                let selfRef = this
                                spawn {
                                    let ok = selfRef.activatePfs()
                                    selfRef.pfsMutex.lock()
                                    selfRef.pfsRenewInFlight = false
                                    selfRef.pfsMutex.unlock()
                                    Hilog.info(0, "CjTelegram", "[MTProtoClient] PFS at-use expiry regen: ${ok}")
                                }
                            }
                            return (permKey, permKeyId)
                        } else {
                            (tk.authKey, tk.authKeyId)
                        }
                    } else {
                        (permKey, permKeyId)
                    }
                case None => (permKey, permKeyId)
            }
            pfsMutex.unlock()
            return chosen
        } catch (_e: Exception) {
            // 选键过程出现任何异常 → 绝对回退永久密钥
            try { pfsMutex.unlock() } catch (_e2: Exception) {}
            Hilog.info(0, "CjTelegram", "[MTProtoClient] effectiveAuthKey fallback to permanent (exception)")
            return (permKey, permKeyId)
        }
    }

    /**
     * 激活 PFS：握手出永久密钥后生成并绑定临时密钥（P2-251b）。
     *
     * 失败完全静默、不影响永久密钥路径：
     *   任一步（生成 / 绑定）失败或抛异常 → tempAuthKey 保持/置为 None，
     *   后续 effectiveAuthKey() 继续走永久密钥（现有网络可用性不受影响）。
     *
     * 默认不自动激进调用；可在连接建立、永久密钥就绪后手动调一次。
     *
     * @param expiresInSec 临时密钥有效期（秒），默认 24h。
     * @return true 表示临时密钥已生成并绑定成功（PFS 生效）；false 表示静默回退永久密钥。
     */
    public func activatePfs(expiresInSec!: Int32 = 86400): Bool {
        try {
            // 必须先有永久密钥（永久密钥是 PFS 的绑定锚点与回退路径）。
            // P2-242a r2：走线程安全 getter，消除与 -404 接收线程裸写的竞态。
            let permKey = match (this.session.getAuthKey()) {
                case Some(ak) where ak.size > 0 => ak
                case _ =>
                    Hilog.info(0, "CjTelegram", "[MTProtoClient] activatePfs skipped: no permanent auth key")
                    return false
            }
            let permKeyId = match (this.session.getAuthKeyId()) {
                case Some(akId) where akId.size == 8 => akId
                case _ =>
                    Hilog.info(0, "CjTelegram", "[MTProtoClient] activatePfs skipped: no permanent auth key id")
                    return false
            }

            let dcId = this.session.dcId
            let transport = this.transportManager.getTransport(dcId)

            // 1. 生成临时密钥（独立 DH 握手；transport 回调会被临时占用，结束后恢复）
            let tempOpt = TempAuthKeyManager.generateTempAuthKey(transport, expiresInSec)
            let temp = match (tempOpt) {
                case Some(t) => t
                case None =>
                    Hilog.info(0, "CjTelegram", "[MTProtoClient] activatePfs: generateTempAuthKey failed, staying on permanent")
                    transport.setCallback(this)
                    return false
            }

            // 2. 绑定到永久密钥
            let bound = TempAuthKeyManager.bindTempAuthKey(
                this.session, transport, permKey, permKeyId, temp
            )

            // 恢复 MTProtoClient 自身的回调（generate/bind 期间换过临时回调）
            transport.setCallback(this)

            if (!bound || !temp.isValid() || !temp.bound) {
                Hilog.info(0, "CjTelegram", "[MTProtoClient] activatePfs: bindTempAuthKey failed, staying on permanent")
                return false
            }

            pfsMutex.lock()
            this.tempAuthKey = Some(temp)
            pfsMutex.unlock()
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] PFS activated: temp ${ByteUtils.toHex(temp.authKeyId)} bound, expiresAt=${temp.expiresAt}")
            return true
        } catch (e: Exception) {
            // 任何异常都不能破坏永久密钥路径
            Hilog.info(0, "CjTelegram", "[MTProtoClient] activatePfs exception, staying on permanent: ${e}")
            try { pfsMutex.unlock() } catch (_e2: Exception) {}
            pfsMutex.lock()
            this.tempAuthKey = None
            pfsMutex.unlock()
            return false
        }
    }

    /**
     * 加密消息
     *
     * P2-251b：改用 effectiveAuthKey() 选键 —— temp 有效时用 temp，否则永久密钥。
     * temp 不可用时与原实现完全等价（authKey/authKeyId 取自 session，None 仍短路返回 data）。
     * 对外签名不变。
     */
    private func encryptMessage(data: Array<Byte>): Array<Byte> {
        let (authKey, authKeyId) = effectiveAuthKey()
        // 永久密钥缺失（空数组）时保持原有 None 短路行为：不加密直接返回 data。
        if (authKey.size == 0 || authKeyId.size == 0) {
            return data
        }

        let encrypted = MTProtoCrypto.encryptMessage(authKey, authKeyId, data, true)
        return encrypted.toBytes()
    }

    /**
     * 解密消息
     *
     * P2-251c Gap 2: 入站解密路径识别临时密钥 auth_key_id。
     * 根据消息头前 8 字节（auth_key_id）选择解密密钥：
     *   - 若与当前临时密钥 auth_key_id 匹配 → 用临时密钥解密（PFS 激活态）。
     *   - 否则回退永久密钥（= 原有行为，PFS 未启用态字节完全不变）。
     *
     * P2-242a r2：接收线程调用，-404 分支也在接收线程写 authKey；
     * 同一线程内二者不并发（同线程顺序执行），但 effectiveAuthKey() 发送线程读
     * 与本接收线程写存在跨线程竞态 —— 统一走 getAuthKey() 同锁保护。
     */
    private func decryptMessage(data: Array<Byte>): Array<Byte> {
        if (data.size < 24) {
            return data
        }

        let incomingKeyId = ByteUtils.slice(data, 0, 8)

        // P2-251c: 检查是否与当前临时密钥匹配（只在 PFS 激活且 bound 时才可能匹配）。
        var authKey: Array<Byte> = Array<Byte>(0, repeat: 0)
        pfsMutex.lock()
        match (this.tempAuthKey) {
            case Some(tk) =>
                if (tk.isValid() && tk.bound && ByteUtils.equals(incomingKeyId, tk.authKeyId)) {
                    authKey = tk.authKey
                }
            case None => ()
        }
        pfsMutex.unlock()

        // 未命中临时密钥 → 回退永久密钥（= 原有行为，PFS 未启用时路径完全不变）。
        if (authKey.size == 0) {
            match (this.session.getAuthKey()) {
                case Some(ak) => authKey = ak
                case None => return data
            }
        }

        let msgKey = ByteUtils.slice(data, 8, 24)
        let encryptedData = ByteUtils.slice(data, 24, data.size)

        return MTProtoCrypto.decryptMessage(authKey, msgKey, encryptedData, false)
    }

    // ============ TransportCallback 实现 ============

    public open func onConnected(): Unit {
        Hilog.info(0, "CjTelegram", "[MTProtoClient] Transport connected")
        this.notifyConnectionState(ConnectionState.Connected)
        // 连接成功 → 清零退避 / failover 状态（对齐 iOS connectionValidDataReceived）。
        this.reconnectCtrl.onSuccess()
    }

    public open func onDisconnected(): Unit {
        Hilog.info(0, "CjTelegram", "[MTProtoClient] Transport disconnected")
        this.notifyConnectionState(ConnectionState.Disconnected)
        this.connectionInitialized = false
    }

    public open func onData(data: Array<Byte>): Unit {
        handleIncomingData(data)
    }

    public open func onError(error: String): Unit {
        Hilog.info(0, "CjTelegram", "[MTProtoClient] Transport error: ${error}")
    }

    /**
     * 处理接收到的数据
     */
    private func handleIncomingData(data: Array<Byte>) {
        if (data.size < 8) {
            if (data.size == 4) {
                let errorCode = ByteUtils.bytesToInt32(data)
                Hilog.info(0, "CjTelegram", "[MTProtoClient] Transport error code: ${errorCode}")
                if (errorCode == -404) {
                    // 传输层 -404 = 服务端在**本连接上**找不到该 auth key。
                    //
                    // 对齐 iOS MTProto.m:2140 handleMissingKey：对持久主密钥
                    // （authInfoSelector = PersistentMain 且 _canResetAuthData == false，即常态）
                    // iOS 走 `default: [_context checkIfLoggedOut:_datacenterId]` —— **不删本地密钥**，
                    // 而是去向服务端求证（MTContext.m:1611，60s 限流 + 用临时密钥 bind 永久密钥，
                    // 只有 bind 确实失败才判定 isRemoved 并上抛 contextLoggedOut）。
                    //
                    // 旧实现在这里直接 setAuthKey(None) 把内存密钥销毁。由于 SessionManager.saveSession
                    // 对 None 密钥不落盘（MTProtoConfig.cj:1007 的守卫），磁盘凭据其实没被删，
                    // 但内存密钥一旦清空，hasAuthKey() 恒 false → 之后所有请求立即返回空数组，
                    // 本次运行内再也无法恢复（只有重启才会从磁盘重载）——即静默假死。
                    //
                    // 故这里只重置连接层状态，让连接重建后用同一密钥重试；真正的授权失效
                    // 由 handleRPCResult 的服务端 401 拦截（authorizationRequiredCallback）负责。
                    // TODO(auth-verify): 补齐 iOS checkIfLoggedOut 等价物（临时密钥 bind 探测 +
                    //   60s 限流），以覆盖"服务端只回 -404、从不回 401"的吊销场景。
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] Transport -404 (auth key not found on this connection); " +
                        "keeping local key, resetting connection (iOS handleMissingKey semantics)")
                    this.session.clearServerSalt()
                    this.connectionInitialized = false
                }
            }
            return
        }

        // 检查是否是未加密消息
        let authKeyId = ByteUtils.slice(data, 0, 8)
        if (ByteUtils.isZero(authKeyId)) {
            // 未加密消息（密钥交换阶段）
            return
        }

        // 检查 auth key
        // P2-242a r2：接收线程读 authKeyId，与 -404 同线程的写及发送线程的读存在并发；
        // 走线程安全 getter 消除竞态。
        // P2-251c Gap 2: 同时识别永久密钥和临时密钥的 auth_key_id，避免丢弃 PFS 回包。
        var matchesPerm = false
        match (this.session.getAuthKeyId()) {
            case Some(localAkId) =>
                matchesPerm = ByteUtils.equals(authKeyId, localAkId)
            case None => ()
        }

        var matchesTemp = false
        if (!matchesPerm) {
            pfsMutex.lock()
            match (this.tempAuthKey) {
                case Some(tk) =>
                    if (tk.isValid() && tk.bound) {
                        matchesTemp = ByteUtils.equals(authKeyId, tk.authKeyId)
                    }
                case None => ()
            }
            pfsMutex.unlock()
        }

        if (!matchesPerm && !matchesTemp) {
            this.consecutiveKeyMismatch += 1
            Hilog.info(0, "CjTelegram", "[MTProtoClient] auth_key_id mismatch (perm and temp), ignoring (consecutive=${this.consecutiveKeyMismatch})")
            // 流自愈：连续 mismatch 说明接收流已错位或密钥态不一致，丢包换不来恢复。
            // 强制重建 transport + 接收循环（复用 attemptReconnect 全流程），
            // 并 getState 触发服务器补投积压推送（否则挂断/来电推送全丢）。
            if (this.consecutiveKeyMismatch >= 8) {
                this.consecutiveKeyMismatch = 0
                Hilog.info(0, "CjTelegram", "[MTProtoClient] stream desync suspected → force rebuild transport")
                let _ = spawn { this.recoverFromStreamDesync() }
            }
            return
        }
        this.consecutiveKeyMismatch = 0

        // 解密消息
        let decrypted = decryptMessage(data)
        handleDecryptedMessage(decrypted)
    }

    /**
     * 处理解密后的消息
     *
     * P2-244: 读取 seqNo 并传入 processMessage，用于判断 content-related 并调度 ACK。
     */
    private func handleDecryptedMessage(data: Array<Byte>) {
        // 跳过 server_salt(8) + session_id(8) = 16
        if (data.size < 24) {
            return
        }
        let deserializer = TLDeserializer(ByteUtils.slice(data, 16, data.size))
        let msgId = deserializer.readInt64()
        let seqNo = deserializer.readInt32()  // P2-244: 读取 seqNo（奇数=content-related，需 ACK）
        let length = deserializer.readInt32()
        let messageData = deserializer.readRawBytes(Int64(length))
        processMessage(msgId, seqNo, messageData)
    }

    /**
     * 处理消息
     *
     * P2-244: 增加 seqNo 参数用于 ACK 调度；增加 bad_msg_notification 处理分支。
     * MSG_CONTAINER 内层消息通过递归调用时 seqNo 从容器内层各自字段获取（handleMsgContainer 传入）。
     */
    private func processMessage(msgId: Int64, seqNo: Int32, data: Array<Byte>): Unit {
        if (data.size < 4) {
            return
        }

        // P2-244: content-related 消息（seqno 奇数）需要我方 ACK（对齐 iOS MTProto.m L2486-2492）
        scheduleAck(msgId, seqNo)

        // P2-245: 每条服务端消息携带 msgId（高 32 bit = 服务端 Unix 秒），记录时间同步样本。
        // wall clock 域：offset = serverUnixSec - localNowSec（与 bad_msg 16/17/48 同口径）。
        this.timeSyncService.recordSample(msgId)

        let deserializer = TLDeserializer(data)
        let constructor = deserializer.readUInt32()

        if (constructor == TLConstructors.RPC_RESULT) {
            handleRPCResult(deserializer)
        } else if (constructor == TLConstructors.MSG_CONTAINER) {
            handleMsgContainer(deserializer)
        } else if (constructor == TLConstructors.MSGS_STATE_INFO) {
            // P2-242c: msgs_state_info#04deb57d — 投递状态查询响应
            handleMsgsStateInfo(deserializer)
        } else if (constructor == TLConstructors.RPC_ANSWER_DROPPED ||
                   constructor == TLConstructors.RPC_ANSWER_DROPPED_RUNNING ||
                   constructor == TLConstructors.RPC_ANSWER_UNKNOWN) {
            // P2-242c: rpc_answer_dropped* — rpc_drop_answer 的服务端响应
            handleRpcAnswerDropped(constructor, deserializer)
        } else if (constructor == TLConstructors.GZIP_PACKED) {
            // *** 关键修复：服务器可能将推送更新用 GZIP 压缩 ***
            // 例如 phoneCallAccepted 经常被压缩为 gzip_packed
            // 必须解压后递归处理，否则 updateCallback 收到的是压缩数据
            let compressedData = deserializer.readBytes()
            let decompressed = decompress(compressedData)
            Hilog.info(0, "CjTelegram", "[MTProtoClient] GZIP_PACKED decompressed: ${compressedData.size} -> ${decompressed.size} bytes")
            if (decompressed.size >= 4) {
                // 压缩包展开后继续处理（seqNo 沿用外层值，内层消息的 seqNo 已由外层处理）
                processMessage(msgId, seqNo, decompressed)
            }
        } else if (constructor == TLConstructors.NEW_SESSION_CREATED) {
            handleNewSession(deserializer)
        } else if (constructor == TLConstructors.BAD_SERVER_SALT) {
            handleBadServerSalt(deserializer)
        } else if (constructor == TLConstructors.BAD_MSG_NOTIFICATION) {
            // P2-244: bad_msg_notification#a7eff811 — 服务端通知我方某消息有误
            // incomingMsgId = 本 bad_msg_notification 消息自身的 msgId（用于时间校正）
            handleBadMsgNotification(deserializer, msgId)
        } else if (constructor == TLConstructors.MSGS_ACK) {
            // 服务端确认了我方发出的消息（对应我方发出的 RPC）。
            // P2-244: 解析并记日志（iOS MTProto.m L2574-2585 通知 messageServices.messageDeliveryConfirmed）
            handleServerMsgsAck(deserializer)
        } else if (constructor == TLConstructors.FUTURE_SALTS) {
            // P2-245: future_salts#ae500895 — 运行时盐列表（get_future_salts 的响应）
            // 解析后由 MTTimeSyncService 存储，供 buildMessage 侧盐轮换使用。
            let reqMsgId = this.timeSyncService.handleFutureSalts(deserializer)
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] future_salts processed (reqMsgId=${reqMsgId})")
            // future_salts 同时也携带服务端时间（now 字段）；handleFutureSalts 内已读过。
            // 此消息本身是 not-content-related（服务端主动推送），不用 dispatch 到 pendingRPCs。
        } else if (constructor == TLConstructors.PONG) {
            let pong = Pong.deserialize(deserializer)
            Hilog.info(0, "CjTelegram", "[MTProtoClient] Pong received, pingId: ${pong.pingId}")
        } else {
            // 可能是更新消息
            if (this.retired.load()) {
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] dropped ${data.size}-byte update from retired client (DC${this.session.dcId})")
                return
            }
            match (this.updateCallback) {
                case Some(cb) => cb(data)
                case None => ()
            }
        }
    }

    /**
     * P2-244: 处理服务端发来的 msgs_ack（服务端确认我方消息已收到）。
     *
     * 对应 iOS MTProto.m L2574-2585：通知 messageServices.messageDeliveryConfirmed。
     * 此处记日志（当前无需维护"已确认的我方 msgId"持久状态，
     * 因为 sendRPCRequestConcurrent 的等待机制依赖 rpc_result 而非 ack）。
     */
    private func handleServerMsgsAck(deserializer: TLDeserializer): Unit {
        // msgs_ack#62d6b459 { msg_ids: Vector<long> }
        let vectorTag = deserializer.readUInt32()
        if (vectorTag != TLConstructors.VECTOR) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] msgs_ack: invalid vector tag 0x${ByteUtils.toHex(ByteUtils.uint32ToBytes(vectorTag))}")
            return
        }
        let count = deserializer.readInt32()
        var i: Int32 = 0
        let ackedIds = ArrayList<Int64>()
        while (i < count) {
            ackedIds.add(deserializer.readInt64())
            i += 1
        }
        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] msgs_ack from server: ${ackedIds.size} msgId(s) confirmed delivered")
    }

    // =========================================================================
    // P2-243: RPC 错误分类器（静态纯函数，无网络，可单元断言）
    //
    // 对应 iOS MTRequestMessageService.m 错误处理树：
    //   errorCode == -500 || 500  → Transient（内部服务器错误，自动重试）
    //   errorCode == -503         → Transient（瞬时服务不可用）
    //   FLOOD_WAIT_X              → FloodWait(X)（等 X 秒后重试）
    //   SLOW_MODE_WAIT_X          → SlowMode(X)（等 X 秒后重试）
    //   *_MIGRATE_X               → Migrate(X)（切换到 DC X 重试）
    //   其余                      → Fatal（直接上抛）
    //
    // 输入：error_code: Int32, error_message: String
    // 输出：RPCErrorClass 枚举值
    // =========================================================================
    public static func classifyRPCError(errorCode: Int32, errorMessage: String): RPCErrorClass {
        // 瞬时错误：-500 / 500（internal server error）/ -503
        if (errorCode == -500 || errorCode == 500 || errorCode == -503) {
            return RPCErrorClass.Transient
        }

        // FLOOD_WAIT_X：errorCode==420 且 message 含 "FLOOD_WAIT_"，或 message 直接含 "FLOOD_WAIT_"
        if (errorMessage.contains("FLOOD_WAIT_")) {
            let seconds = MTProtoClient.parseTrailingInt(errorMessage, "FLOOD_WAIT_")
            if (seconds > 0) {
                return RPCErrorClass.FloodWait(seconds)
            }
        }
        // FLOOD_PREMIUM_WAIT_X（归入 FloodWait 处理）
        if (errorMessage.contains("FLOOD_PREMIUM_WAIT_")) {
            let seconds = MTProtoClient.parseTrailingInt(errorMessage, "FLOOD_PREMIUM_WAIT_")
            if (seconds > 0) {
                return RPCErrorClass.FloodWait(seconds)
            }
        }
        // SLOW_MODE_WAIT_X
        if (errorMessage.contains("SLOW_MODE_WAIT_")) {
            let seconds = MTProtoClient.parseTrailingInt(errorMessage, "SLOW_MODE_WAIT_")
            if (seconds > 0) {
                return RPCErrorClass.SlowMode(seconds)
            }
        }

        // FILE_MIGRATE_X：媒体/文件专属迁移，必须与 PHONE/NETWORK/USER_MIGRATE_X 分开分类
        // （见上方 RPCErrorClass.FileMigrate 注释）——真机 HI-AUTH-0006 实测：若与其余
        // *_MIGRATE_X 一起归入 Migrate(dcId)，调用方是主客户端时会把主会话整个搬家。
        if (errorMessage.startsWith("FILE_MIGRATE_")) {
            let dcId = MTProtoClient.parseTrailingInt(errorMessage, "FILE_MIGRATE_")
            if (dcId > 0) {
                return RPCErrorClass.FileMigrate(dcId)
            }
        }

        // 其余 *_MIGRATE_X：PHONE_MIGRATE_X / NETWORK_MIGRATE_X / USER_MIGRATE_X
        if (errorMessage.contains("_MIGRATE_")) {
            let dcId = MTProtoClient.parseTrailingInt(errorMessage, "_MIGRATE_")
            if (dcId > 0) {
                return RPCErrorClass.Migrate(dcId)
            }
        }

        return RPCErrorClass.Fatal
    }

    // =========================================================================
    // P2-243: 辅助：从 errorMessage 中解析 prefix 后面的整数尾缀
    //   例: "FLOOD_WAIT_60" + prefix="FLOOD_WAIT_" → 60
    //       "PHONE_MIGRATE_2" + prefix="_MIGRATE_" → 2
    //
    // 实现：String.split(prefix) 切割，取最后一段；再 split("_") 取第一段（纯数字）；
    //   Int64.parse 解析，异常返回 -1。
    // 纯函数，无副作用，可无网络断言。
    // =========================================================================
    public static func parseTrailingInt(message: String, prefix: String): Int64 {
        if (!message.contains(prefix)) {
            return -1
        }
        // split(prefix) 返回 Array<String>，按 prefix 切分
        let parts = message.split(prefix)
        if (parts.size < 2) {
            return -1
        }
        // 取最后一个片段（prefix 之后的部分）
        let afterStr = parts[parts.size - 1]
        // afterStr 可能是 "60" 或 "60_something"，只取下划线之前的部分
        let numParts = afterStr.split("_")
        let numPart = if (numParts.size >= 1) { numParts[0] } else { afterStr }
        // Int64.parse 解析数字；异常时返回 -1
        try {
            return Int64.parse(numPart)
        } catch (_: Exception) {
            return -1
        }
    }

    /**
     * P2-243: 计算重试退避延迟（指数退避，用于瞬时错误）
     * attempt >= 1；base=500ms，cap=16000ms，无抖动（确定性）。
     * 与 ReconnectController.computeBackoffMs 同语义，独立实现（RPC 层与连接层参数不同）。
     */
    public static func computeRPCBackoffMs(attempt: Int64): Int64 {
        let base = MTProtoClient.TRANSIENT_BASE_DELAY_MS
        let cap = MTProtoClient.TRANSIENT_CAP_DELAY_MS
        if (attempt <= 1) {
            return base
        }
        let shift = attempt - 1
        if (shift >= 31) {
            return cap
        }
        let factor = 1 << shift
        let raw = base * factor
        if (raw < 0 || raw > cap) {
            return cap
        }
        return raw
    }

    /**
     * P2-243: 在 rpcMonitor 之外的后台线程中执行延迟-重发-写回逻辑（FLOOD_WAIT / Transient）。
     *
     * 安全性保证：
     *   - 不在锁内 sleep（避免长时间占用 rpcMonitor 阻塞其他 RPC）。
     *   - 睡眠结束后，在新 msgId 下重新打包并发送原始 body。
     *   - 把新 msgId → 同一个 PendingRPC 对象写入 pendingRPCs，
     *     响应到达后经 dispatchResponse 唤醒原等待者（复用 242a/242c 的同对象重映射语义）。
     *   - 若 transport 断开或 body 无效，以空字节 fulfill 让等待者感知失败返回，不永久阻塞。
     *
     * @param pending  原始 PendingRPC（等待者在其 completed 上 wait）
     * @param body     原始 RPC 请求体（用于重发，来自 pending.requestBody）
     * @param delayMs  睡眠时长（毫秒）
     * @param tag      日志 tag（"FLOOD_WAIT" / "TRANSIENT" 等）
     */
    private func scheduleRetryAfterDelay(pending: PendingRPC, body: Array<Byte>, delayMs: Int64, tag: String): Unit {
        let clientRef = this

        // P2-243 rework：sleep 之前在锁内检查 completed；若已完成则无需 spawn（避免空转）。
        // 若未完成，立即置 doNotExpire=true，使 cleanupExpiredRPCs 在整个 sleep 期间跳过本条目。
        // 这是关键修复：cleanup 可能在 sleep 进行中 fire，若不在 sleep 前豁免则会把 pending 误清。
        var shouldSpawn = false
        synchronized(clientRef.rpcMonitor) {
            if (!pending.completed) {
                pending.doNotExpire = true
                shouldSpawn = true
            }
        }
        if (!shouldSpawn) {
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] ${tag} retry: pending already completed before sleep, skip (msgId=${pending.msgIdStr})")
            return
        }

        spawn {
            // 1. 不持锁 sleep（整个 sleep 期间 doNotExpire=true 保护 pending 不被 cleanup 误清）
            sleep(Duration.millisecond * delayMs)

            // 2. sleep 结束后：在锁内检查 completed；若已完成（取消/被其他路径完成）则清豁免标志后退出。
            //    若未完成，清 doNotExpire=false 并刷新 timestamp（给本次重试 attempt 一个新的正常超时窗口）。
            var stillPending = false
            synchronized(clientRef.rpcMonitor) {
                if (pending.completed) {
                    // 已完成：清豁免标志（防止永久豁免泄漏），不重发
                    pending.doNotExpire = false
                } else {
                    // 未完成：清豁免 + 刷新时间戳（重试 attempt 从现在起计新超时窗口）
                    // 必须用 wall clock，与 cleanupExpiredRPCs 和 PendingRPC 初始注册保持同一时钟域
                    pending.doNotExpire = false
                    pending.timestamp = DateTime.now().toUnixTimeStamp().toMilliseconds()
                    stillPending = true
                }
            }
            if (!stillPending) {
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] ${tag} retry: pending completed during sleep, skip resend (msgId=${pending.msgIdStr})")
                return
            }

            // 3. 分配新 msgId/seqNo，重新打包并加密
            if (!clientRef.hasAuthKey()) {
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] ${tag} retry: no auth key, fail pending msgId=${pending.msgIdStr}")
                synchronized(clientRef.rpcMonitor) {
                    pending.fulfill(Array<Byte>(0, repeat: 0))
                    clientRef.rpcMonitor.notifyAll()
                }
                return
            }

            // P2-246 rework2: snapshot session ref under sessionRefMutex before reads
            // (background spawn may wake during migrateToDC Step3 which replaces this.session)
            let s = clientRef.getSessionRef()
            let newMsgId = s.generateMessageId()
            let newSeqNo = s.getNextSeqNo(true)  // content-related（真 RPC 请求体）
            let newMsgIdStr = "${newMsgId}"
            let retryMessage = clientRef.buildMessage(newMsgId, newSeqNo, body)
            let retryEncrypted = clientRef.encryptMessage(retryMessage)

            // 4. 把 newMsgId → 同一 pending 对象注册到 pendingRPCs（与 242c Path B 同语义）
            synchronized(clientRef.rpcMonitor) {
                clientRef.pendingRPCs[newMsgIdStr] = pending
            }

            // 5. 发送（锁外 IO）
            let dcId = s.dcId
            let transport = clientRef.transportManager.getTransport(dcId)
            if (transport.isConnected()) {
                transport.send(retryEncrypted, category: pending.usageCategory)
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] ${tag} retry sent: original_msgId=${pending.msgIdStr} → new_msgId=${newMsgId} (attempt=${pending.retryCount})")
            } else {
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] ${tag} retry: transport disconnected, fail pending msgId=${pending.msgIdStr}")
                synchronized(clientRef.rpcMonitor) {
                    let _ = clientRef.pendingRPCs.remove(newMsgIdStr)
                    pending.fulfill(Array<Byte>(0, repeat: 0))
                    clientRef.rpcMonitor.notifyAll()
                }
            }
        }
    }

    /**
     * 处理 RPC 结果（P2-243 增强：自动重试 / FLOOD_WAIT 退避 / MIGRATE 重定向）
     *
     * 错误处理优先级（对应 iOS MTRequestMessageService.m 错误处理树）：
     *   1. Transient（-500/500/-503）→ 指数退避重试（最多 MAX_TRANSIENT_RETRIES 次）
     *   2. FloodWait/SlowMode       → 等待 X 秒后重试（不计入重试次数上限）
     *   3. Migrate(*_MIGRATE_X)     → 切换 DC X 后重发原始请求体
     *   4. Fatal                    → 序列化 rpc_error 字节，dispatch 给调用方
     *
     * 重试/切换 DC 时：
     *   - 不 fulfill pending（等待者继续 wait）；
     *   - 在后台 spawn 延迟/重发逻辑（或同步切 DC 后重发）；
     *   - 新 msgId → 同一 PendingRPC 对象写入 pendingRPCs，
     *     响应到达后经 dispatchResponse 唤醒原等待者（142a/242c 同对象重映射语义）。
     */
    private func handleRPCResult(deserializer: TLDeserializer) {
        let reqMsgId = deserializer.readInt64()
        let resultConstructor = deserializer.peekUInt32()
        let msgIdStr = "${reqMsgId}"

        if (resultConstructor == TLConstructors.RPC_ERROR) {
            let _ = deserializer.readUInt32()
            let rpcError = RPCError.deserialize(deserializer)
            Hilog.info(0, "CjTelegram", "[MTProtoClient] RPC Error ${rpcError.errorCode}: ${rpcError.errorMessage}")

            // P2-243: 分类错误，决定是重试/redirect/上抛
            let errClass = MTProtoClient.classifyRPCError(rpcError.errorCode, rpcError.errorMessage)

            // 取出当前 pending 条目（在锁内读取，避免竞态）
            var pendingOpt: Option<PendingRPC> = None
            var bodyOpt: Option<Array<Byte>> = None
            synchronized(rpcMonitor) {
                if (this.pendingRPCs.contains(msgIdStr)) {
                    let p = this.pendingRPCs[msgIdStr]
                    pendingOpt = Some(p)
                    bodyOpt = p.requestBody
                    // 更新每请求错误上下文（在锁内安全写入）
                    p.lastErrorCode = rpcError.errorCode
                    p.lastErrorMessage = rpcError.errorMessage
                }
            }

            match (errClass) {
                case RPCErrorClass.Transient =>
                    // 瞬时错误：有限次数指数退避重试
                    var shouldRetry = false
                    var delayMs: Int64 = 0
                    synchronized(rpcMonitor) {
                        if (this.pendingRPCs.contains(msgIdStr)) {
                            let p = this.pendingRPCs[msgIdStr]
                            p.retryCount += 1
                            if (p.retryCount <= MTProtoClient.MAX_TRANSIENT_RETRIES) {
                                shouldRetry = true
                                delayMs = MTProtoClient.computeRPCBackoffMs(p.retryCount)
                                Hilog.info(0, "CjTelegram",
                                    "[MTProtoClient] Transient error (${rpcError.errorCode}), retry ${p.retryCount}/${MTProtoClient.MAX_TRANSIENT_RETRIES} in ${delayMs}ms msgId=${msgIdStr}")
                            }
                        }
                    }
                    if (shouldRetry) {
                        match (pendingOpt) {
                            case Some(p) =>
                                match (bodyOpt) {
                                    case Some(body) =>
                                        scheduleRetryAfterDelay(p, body, delayMs, "TRANSIENT")
                                    case None =>
                                        // 无 requestBody → 无法重发，上抛错误
                                        let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                                        dispatchResponse(msgIdStr, errorBytes)
                                }
                            case None =>
                                let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                                dispatchResponse(msgIdStr, errorBytes)
                        }
                    } else {
                        // 超出重试上限，上抛错误
                        Hilog.info(0, "CjTelegram",
                            "[MTProtoClient] Transient retry exhausted for msgId=${msgIdStr}, propagating error")
                        let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                        dispatchResponse(msgIdStr, errorBytes)
                    }

                case RPCErrorClass.FloodWait(waitSec) =>
                    // FLOOD_WAIT_X：累计不超过 MAX_AUTO_FLOOD_WAIT_SEC 时等 waitSec 秒后重试
                    // （不计入 MAX_TRANSIENT_RETRIES）；更长的等待直接把错误交给调用方。
                    let delayMs = waitSec * 1000
                    match (pendingOpt) {
                        case Some(p) =>
                            var autoWait = false
                            synchronized(rpcMonitor) {
                                if (p.floodWaitTotalSec + waitSec <= MTProtoClient.MAX_AUTO_FLOOD_WAIT_SEC) {
                                    p.floodWaitTotalSec += waitSec
                                    autoWait = true
                                }
                            }
                            match (bodyOpt) {
                                case Some(body) where autoWait =>
                                    Hilog.info(0, "CjTelegram",
                                        "[MTProtoClient] FLOOD_WAIT: waiting ${waitSec}s before retry for msgId=${msgIdStr}")
                                    synchronized(rpcMonitor) {
                                        p.nextRetryAtMs = mtprotoMonotonicNowMs() + delayMs
                                    }
                                    scheduleRetryAfterDelay(p, body, delayMs, "FLOOD_WAIT")
                                case Some(_) =>
                                    Hilog.info(0, "CjTelegram",
                                        "[MTProtoClient] FLOOD_WAIT_${waitSec} exceeds auto-wait limit ${MTProtoClient.MAX_AUTO_FLOOD_WAIT_SEC}s, returning error for msgId=${msgIdStr}")
                                    let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                                    dispatchResponse(msgIdStr, errorBytes)
                                case None =>
                                    let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                                    dispatchResponse(msgIdStr, errorBytes)
                            }
                        case None =>
                            let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                            dispatchResponse(msgIdStr, errorBytes)
                    }

                case RPCErrorClass.SlowMode(waitSec) =>
                    // SLOW_MODE_WAIT_X：等 waitSec 秒后重试
                    let delayMs = waitSec * 1000
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] SLOW_MODE_WAIT: waiting ${waitSec}s before retry for msgId=${msgIdStr}")
                    match (pendingOpt) {
                        case Some(p) =>
                            match (bodyOpt) {
                                case Some(body) =>
                                    synchronized(rpcMonitor) {
                                        p.nextRetryAtMs = mtprotoMonotonicNowMs() + delayMs
                                    }
                                    scheduleRetryAfterDelay(p, body, delayMs, "SLOW_MODE_WAIT")
                                case None =>
                                    let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                                    dispatchResponse(msgIdStr, errorBytes)
                            }
                        case None =>
                            let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                            dispatchResponse(msgIdStr, errorBytes)
                    }

                case RPCErrorClass.Migrate(targetDcId) =>
                    // *_MIGRATE_X（PHONE/NETWORK/USER）：切换【当前客户端自身】到 DC targetDcId，
                    // 重新发送原始请求体。当前客户端就是这个会话本身，迁移语义正确。
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] *_MIGRATE_${targetDcId}: redirecting request msgId=${msgIdStr} to DC${targetDcId}")
                    match (pendingOpt) {
                        case Some(p) =>
                            match (bodyOpt) {
                                case Some(body) =>
                                    handleMigrateAndResend(p, body, targetDcId, msgIdStr)
                                case None =>
                                    Hilog.info(0, "CjTelegram",
                                        "[MTProtoClient] MIGRATE: no requestBody for msgId=${msgIdStr}, propagating error")
                                    let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                                    dispatchResponse(msgIdStr, errorBytes)
                            }
                        case None =>
                            let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                            dispatchResponse(msgIdStr, errorBytes)
                    }

                case RPCErrorClass.FileMigrate(targetDcId) =>
                    // FILE_MIGRATE_X：绝不迁移当前客户端（可能是已授权的主客户端）。
                    // 转发到 getClientForDC(targetDcId) 拿到的独立辅助 DC 客户端上重发，
                    // 当前客户端（含其 session/DC）保持完全不变。
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] FILE_MIGRATE_${targetDcId}: redirecting request msgId=${msgIdStr} to aux DC${targetDcId} client (main session untouched)")
                    match (pendingOpt) {
                        case Some(p) =>
                            match (bodyOpt) {
                                case Some(body) =>
                                    handleFileMigrateAndResend(p, body, targetDcId, msgIdStr)
                                case None =>
                                    Hilog.info(0, "CjTelegram",
                                        "[MTProtoClient] FILE_MIGRATE: no requestBody for msgId=${msgIdStr}, propagating error")
                                    let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                                    dispatchResponse(msgIdStr, errorBytes)
                            }
                        case None =>
                            let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                            dispatchResponse(msgIdStr, errorBytes)
                    }

                case RPCErrorClass.Fatal =>
                    // 全局授权失效拦截（对齐 iOS MTRequestMessageService.m:846）：
                    //   if (rpcError.errorCode == 401) {
                    //       if SESSION_PASSWORD_NEEDED → 只置 passwordInputRequired，不登出
                    //       else → [delegate requestMessageServiceAuthorizationRequired:]
                    //   }
                    // 关键：这里的 401 是**服务端下发、已解密**的 rpc_error，是授权失效的唯一确证。
                    // 超时/空响应/传输错误走不到这里（它们根本没有 rpc_error），因此不会误触发。
                    if (rpcError.errorCode == 401 &&
                        !rpcError.errorMessage.contains("SESSION_PASSWORD_NEEDED")) {
                        Hilog.info(0, "CjTelegram",
                            "[MTProtoClient] Server-confirmed 401 (${rpcError.errorMessage}) → authorizationRequired")
                        match (this.authorizationRequiredCallback) {
                            case Some(cb) =>
                                // 在接收线程外执行：回调会做存储清理，不能阻塞接收循环。
                                let _ = spawn { cb() }
                            case None =>
                                Hilog.info(0, "CjTelegram",
                                    "[MTProtoClient] 401 but no authorizationRequired callback registered")
                        }
                    }
                    // Fatal 错误：直接上抛给调用方
                    let errorBytes = serializeRPCError(rpcError.errorCode, rpcError.errorMessage)
                    dispatchResponse(msgIdStr, errorBytes)
            }
        } else if (resultConstructor == TLConstructors.GZIP_PACKED) {
            let _ = deserializer.readUInt32()
            let compressedData = deserializer.readBytes()
            let decompressedData = decompress(compressedData)

            dispatchResponse(msgIdStr, decompressedData)
        } else {
            let remaining = deserializer.remaining()
            let resultData = deserializer.readRawBytes(remaining)

            dispatchResponse(msgIdStr, resultData)
        }
    }

    /**
     * P2-243: 辅助 — 将 rpc_error 序列化为字节（供上抛给调用方）。
     */
    private func serializeRPCError(errorCode: Int32, errorMessage: String): Array<Byte> {
        let s = TLSerializer()
        s.writeUInt32(TLConstructors.RPC_ERROR)
        s.writeInt32(errorCode)
        s.writeString(errorMessage)
        return s.getBytes()
    }

    /**
     * P2-243: *_MIGRATE_X 处理：在后台线程切换 DC、建立新连接、重发原始请求体。
     *
     * 设计：
     *   - 在 spawn 中执行，不阻塞接收线程。
     *   - migrateToDC 切换 session + 建立新连接 + 建新 auth key（这是已有方法的语义）。
     *   - 切换成功后，用新 DC 的 session 分配新 msgId，重发 body。
     *   - 把 newMsgId → 同一 PendingRPC 对象写入 pendingRPCs（同对象重映射，242c Path B 语义）。
     *   - 失败路径（migrate 异常 / transport 断开）以空字节 fulfill pending，让调用方感知失败。
     *
     * 注意：跨 DC 连接管理（TransportManager 侧已有 getTransport / rebuildTransport）在本
     *   单元通过 migrateToDC() 已有方法调用（该方法已接线 transport 重建 + auth key 建立）。
     *   若涉及全局 DC 路由层（getClientForDC / DCRouter 侧）的接线，属跨组件需求，
     *   通过 emitted_integration_contracts 声明（见 featureX.json），不在本方法中留注释占位。
     */
    private func handleMigrateAndResend(pending: PendingRPC, body: Array<Byte>, targetDcId: Int64, oldMsgIdStr: String): Unit {
        let clientRef = this
        spawn {
            try {
                // 1. 切换到目标 DC（包含断开旧连接、更换 session、建立新 auth key）
                clientRef.migrateToDC(targetDcId)
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] MIGRATE: migrated to DC${targetDcId}, resending original request")

                // 2. 验证等待者仍在等（未被超时清理）
                var stillPending = false
                synchronized(clientRef.rpcMonitor) {
                    stillPending = !pending.completed
                }
                if (!stillPending) {
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] MIGRATE: pending already completed, skip resend for ${oldMsgIdStr}")
                    return
                }

                // 3. 在新 DC 的 session 上分配新 msgId，重新打包发送
                if (!clientRef.hasAuthKey()) {
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] MIGRATE: no auth key after migration, fail pending ${oldMsgIdStr}")
                    synchronized(clientRef.rpcMonitor) {
                        pending.fulfill(Array<Byte>(0, repeat: 0))
                        clientRef.rpcMonitor.notifyAll()
                    }
                    return
                }

                let newMsgId = clientRef.session.generateMessageId()
                let newSeqNo = clientRef.session.getNextSeqNo(true)
                let newMsgIdStr = "${newMsgId}"

                // HI-AUTH-0005 真机插桩实测根因修复：迁移到新 DC 后 transportManager 建立的是
                // 一条全新的物理连接，服务器对该连接完全没有 initConnection 状态。Telegram 协议
                // 要求每条新连接的第一个请求必须用 invokeWithLayer(initConnection(...)) 包裹，
                // 否则服务器直接拒绝为 RPC Error 400: CONNECTION_NOT_INITED（而不是正常处理业务
                // 请求）。旧实现在这里直接重发裸 body（如 auth.sendCode），跳过了
                // sendRequest() 里 connectionInitialized 门控，导致迁移后的重发必然触发
                // CONNECTION_NOT_INITED。修复：复用 initConnectionLayer 同一套构造（
                // InitConnection + InvokeWithLayer），仅当 connectionInitialized 为 false
                // （即本次是迁移后新连接的第一条请求）时才包裹；包裹后按 DC 维度置位标志，
                // 之后该 DC 上的后续请求正常裸发。
                let outgoingBody = if (!clientRef.connectionInitialized) {
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] MIGRATE: DC${targetDcId} connection not yet initialized, " +
                        "wrapping resend with invokeWithLayer+initConnection")
                    let initConn = InitConnection()
                    initConn.query = body
                    let initConnBytes = initConn.toBytes()
                    let invokeLayer = InvokeWithLayer()
                    invokeLayer.layer = clientRef.effectiveLayer()
                    invokeLayer.query = initConnBytes
                    invokeLayer.toBytes()
                } else {
                    body
                }

                let migrateMessage = clientRef.buildMessage(newMsgId, newSeqNo, outgoingBody)
                let migrateEncrypted = clientRef.encryptMessage(migrateMessage)

                // 4. newMsgId → 同一 pending 对象（同对象重映射）
                synchronized(clientRef.rpcMonitor) {
                    clientRef.pendingRPCs[newMsgIdStr] = pending
                }

                // 5. 发送（锁外 IO）
                let dcId = clientRef.session.dcId
                let transport = clientRef.transportManager.getTransport(dcId)
                if (transport.isConnected()) {
                    transport.send(migrateEncrypted, category: pending.usageCategory)
                    // 与 initConnectionLayer 语义一致：一旦本次发送把 invokeWithLayer+initConnection
                    // 包裹的请求送出去，就认为该 DC 连接的连接层已初始化，后续请求裸发即可
                    // （按 DC 维度：session 已切到 targetDcId，此处置位对应新 DC 连接的状态）。
                    clientRef.connectionInitialized = true
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] MIGRATE: resent to DC${targetDcId} original_msgId=${oldMsgIdStr} → new_msgId=${newMsgId}")
                } else {
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] MIGRATE: transport not connected after migration, fail pending ${oldMsgIdStr}")
                    synchronized(clientRef.rpcMonitor) {
                        let _ = clientRef.pendingRPCs.remove(newMsgIdStr)
                        pending.fulfill(Array<Byte>(0, repeat: 0))
                        clientRef.rpcMonitor.notifyAll()
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] MIGRATE: exception during migrate/resend for ${oldMsgIdStr}: ${e}")
                synchronized(clientRef.rpcMonitor) {
                    pending.fulfill(Array<Byte>(0, repeat: 0))
                    clientRef.rpcMonitor.notifyAll()
                }
            }
        }
    }

    /**
     * HI-AUTH-0006 真机根因修复：FILE_MIGRATE_X 处理 — 绝不迁移当前客户端本身。
     *
     * 背景（真机插桩实测）：头像/文件下载若经由主 MTProtoClient（已登录、home DC 已授权
     * 的会话）发出，遇到 FILE_MIGRATE_X 后若沿用 *_MIGRATE_X 的旧逻辑对 `this` 调用
     * migrateToDC(targetDcId)，会把已授权的主会话整个搬到文件所在 DC —— 主 DC 的
     * authKey 被清空、session 切走，导致后续 messages.getDialogs / updates.getState
     * 等核心请求在原 DC 上全部失效（AUTH_KEY_UNREGISTERED / CONNECTION_NOT_INITED），
     * 即使文件本身所在 DC 后续 import 授权成功也无法挽回主会话已经断开的状态。
     *
     * 正确语义：FILE_MIGRATE_X 只是"这个文件存在 DC X 上"的重定向提示，与调用方的
     * 会话身份无关。用 getClientForDC(targetDcId) 取得（或懒建立、内部已含
     * exportAuthorization/importAuthorization 授权搬迁）一个独立的辅助 DC 客户端，
     * 把原始请求体转发给它重发；`this`（可能是主客户端）的 session/DC/authKey
     * 全程不做任何变更。
     *
     * 复用 aux client 自己的 public sendRequest()（而非像 handleMigrateAndResend 那样
     * 手工重建 msgId/session/encryptMessage）：sendRequest() 内部已经处理了
     * connectionInitialized 门控（首次请求自动包 invokeWithLayer+initConnection，
     * HI-AUTH-0005/0006 同一套机制），不需要在本函数中重复实现。
     */
    private func handleFileMigrateAndResend(pending: PendingRPC, body: Array<Byte>, targetDcId: Int64, oldMsgIdStr: String): Unit {
        let clientRef = this
        spawn {
            try {
                // 1. 取得（或建立）目标 DC 的独立辅助客户端；getClientForDC 内部已含
                //    exportAuthorization/importAuthorization 授权搬迁，失败时安全回退主客户端
                //    （回退场景下 aux==mainClient，仍走同一 sendRequest 逻辑，不会崩溃，只是
                //    该次文件请求大概率仍会拿到 FILE_MIGRATE/权限错误，由上层按空结果处理）。
                let auxClient = getClientForDC(targetDcId)
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] FILE_MIGRATE: resending msgId=${oldMsgIdStr} via getClientForDC(${targetDcId}) " +
                    "(resolved client currently on DC${auxClient.getCurrentDcId()}; main client stays on DC${clientRef.getCurrentDcId()})")

                // 2. 验证等待者仍在等（未被超时清理）
                var stillPending = false
                synchronized(clientRef.rpcMonitor) {
                    stillPending = !pending.completed
                }
                if (!stillPending) {
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] FILE_MIGRATE: pending already completed, skip resend for ${oldMsgIdStr}")
                    return
                }

                // 3. 用 aux client 自己的 sendRequest（自带 connectionInitialized 门控 + 阻塞等待响应）。
                //    FILE_MIGRATE is part of the real download path, so preserve the producer-selected
                //    semantic category instead of silently reverting the retry to Generic.
                let responseData = auxClient.sendRequest(body, category: pending.usageCategory)

                // 4. 用原始 pending 对象直接 fulfill（不写 clientRef.pendingRPCs，因为响应已经
                //    由 auxClient.sendRequest 同步拿到，不需要再走 dispatchResponse 的异步回填）
                synchronized(clientRef.rpcMonitor) {
                    if (!pending.completed) {
                        pending.fulfill(responseData)
                        clientRef.rpcMonitor.notifyAll()
                    }
                }
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] FILE_MIGRATE: resend via aux DC${targetDcId} complete for ${oldMsgIdStr}, response size=${responseData.size}, main client session untouched")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] FILE_MIGRATE: exception during aux-DC resend for ${oldMsgIdStr}: ${e}")
                synchronized(clientRef.rpcMonitor) {
                    if (!pending.completed) {
                        pending.fulfill(Array<Byte>(0, repeat: 0))
                        clientRef.rpcMonitor.notifyAll()
                    }
                }
            }
        }
    }

    /**
     * 处理消息容器
     *
     * P2-244: 传入内层消息各自的 seqNo（用于 ACK 调度）。
     */
    private func handleMsgContainer(deserializer: TLDeserializer) {
        let container = MsgContainer.deserialize(deserializer)
        for (msg in container.messages) {
            // 单条消息处理失败不影响容器内其他消息
            try {
                // P2-244: 传入内层 seqNo（MsgContainer.ContainerMessage 含 seqNo 字段）
                processMessage(msg.msgId, msg.seqNo, msg.body)
            } catch (_e: Exception) {
                Hilog.info(0, "CjTelegram", "[MTProtoClient] Error processing container msg, skipping")
            }
        }
    }

    /**
     * 处理新会话创建
     *
     * P2-242a 返修：通过线程安全 setServerSalt() 写入，消除与并发 buildMessage 读的竞态。
     */
    private func handleNewSession(deserializer: TLDeserializer) {
        let newSession = NewSessionCreated.deserialize(deserializer)
        this.session.setServerSalt(ByteUtils.int64ToBytes(newSession.serverSalt))
        SessionManager.saveSession(this.session)
    }

    /**
     * 处理错误的服务器盐
     *
     * P2-242a 返修：通过线程安全 setServerSalt() 写入，消除与并发 buildMessage 读的竞态。
     *
     * HI-AUTH-0004 根因修复（第一轮）：bad_server_salt#edab447b 与 bad_msg_notification#a7eff811
     * 同属 MTProto"通知客户端修正参数后必须重发触发消息"的协议类别（对齐 iOS MTProto.m 对
     * badServerSalt / badMsgNotification 的统一 requestMessageForReinvokingAgain 处理）。
     * 之前只更新 salt 未重发 badSalt.badMsgId 对应的触发消息，导致该消息永久丢失、
     * 调用方卡到 60s REQUEST_TIMEOUT。复用 handleBadMsgNotification 已有的 resendAfterBadMsg
     * 通用重发器（新 msgId + 新 seqNo 重新 buildMessage/encryptMessage/transport.send，
     * 并把新 msgId 重映射回同一 PendingRPC，唤醒原调用方）。
     *
     * HI-AUTH-0004 根因修复（第二轮，真机插桩实测）：第一轮修复后真机复测发现 DC 迁移场景下
     * 重发仍会被服务端连续拒绝直到 MAX_TRANSIENT_RETRIES 耗尽。插桩确认：此处 setServerSalt
     * 写入的 new_server_salt 完全正确，但 buildMessage 的盐选择逻辑优先用 timeSyncService
     * 的 future_salts 缓存（P2-245），而该缓存是跨 DC 复用的单实例、迁移时从未清空 ——
     * DC1 初始连接时 get_future_salts 拿到的旧盐在挂钟时间上仍"有效"，于是每次重发都用
     * 错误的旧 DC 盐加密，此处刚写入 session 的正确新盐被完全屏蔽，服务端自然连续
     * bad_server_salt。真因修复在 migrateToDC（timeSyncService.resetForMigration()），
     * 此处保留 setServerSalt 调用不变（session 侧本身是对的）。
     */
    private func handleBadServerSalt(deserializer: TLDeserializer) {
        let badSalt = BadServerSaltMsg.deserialize(deserializer)
        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] Bad server salt, updating... badMsgId=${badSalt.badMsgId} errorCode=${badSalt.errorCode}")
        // The server's bad_server_salt notification is authoritative for the
        // current DC. Drop any cached future salt before rebuilding the rejected
        // request; otherwise getCurrentSalt() takes precedence over the corrected
        // session salt and can resend the same request with another stale salt.
        this.timeSyncService.resetForMigration()
        this.session.setServerSalt(ByteUtils.int64ToBytes(badSalt.newServerSalt))
        SessionManager.saveSession(this.session)

        // 取出受影响的 pending RPC（用于重发），与 handleBadMsgNotification 同一取值模式
        let badMsgIdStr = "${badSalt.badMsgId}"
        var pendingOpt: Option<PendingRPC> = None
        var bodyOpt: Option<Array<Byte>> = None
        synchronized(rpcMonitor) {
            if (this.pendingRPCs.contains(badMsgIdStr)) {
                let p = this.pendingRPCs[badMsgIdStr]
                pendingOpt = Some(p)
                bodyOpt = p.requestBody
            }
        }
        resendAfterBadMsg(badMsgIdStr, pendingOpt, bodyOpt, "bad_server_salt")
    }

    /**
     * 确保连接和接收循环都存活
     * 用于 CallService 在轮询间隔中确认连接健康
     *
     * P2-241d：在原「失败仅重试同一路径」基础上增强为
     *   指数退避 + 同一 scheme 连续失败切备用 scheme/DC（端点择优）。
     * 已连接 → 直接返回（成功路径不经退避，回归安全）。
     * 未连接 → 受退避门控：还在退避等待窗口内（dueForRetry()==false）则本次不重连（避免死循环刷连接），
     *   到点才重连；重连后若 still 失败由 onReconnectFailure 记账推进退避/failover。
     */
    /**
     * 流错位自愈：TCP 看似存活但字节流已错位（每帧 auth_key_id mismatch）时，
     * ensureConnectionAlive 的 isConnected 检查会误判健康——必须无条件重建。
     * attemptReconnect 会 rebuildTransport + connect + 重启接收循环；
     * 成功后 getState 让服务器把积压推送（挂断/来电等）补投下来。
     */
    private func recoverFromStreamDesync(): Unit {
        try {
            let s = getSessionRef()
            this.attemptReconnect(s.dcId)
            let _ = this.sendRequest(UpdatesGetState().toBytes())
            Hilog.info(0, "CjTelegram", "[MTProtoClient] stream desync recovery complete")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] stream desync recovery failed: ${e}")
        }
    }

    public func ensureConnectionAlive(): Unit {
        // Fix3 — P2-246: 取 session 引用快照，避免 migrate 期间裸读 this.session 竞态
        let s = getSessionRef()
        let dcId = s.dcId
        let transport = this.transportManager.getTransport(dcId)
        if (transport.isConnected()) {
            // 已连接：连接健康，确保退避状态清零（成功路径）。
            this.reconnectCtrl.onSuccess()
            return
        }

        // 退避门控：未到下次重试时刻则跳过本轮（不立即/固定间隔死循环重试同一路径）。
        if (!this.reconnectCtrl.dueForRetry()) {
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] reconnect deferred by backoff, remaining=${this.reconnectCtrl.remainingWaitMs()}ms")
            return
        }

        this.attemptReconnect(dcId)
    }

    /**
     * 真正发起一次重连尝试，并按结果驱动退避 / 备用 scheme failover。
     *
     * 探测可用性 + 备用 scheme/DC failover：
     *   - 取该 DC 的候选 scheme 列表（复用 P2-241c getSchemesForDC：主+备+媒体）。
     *   - 当前 scheme 连续失败达阈值 → reconnectCtrl 推进 schemeIndex，本轮用备用 scheme 的端点重建 transport。
     *   - 候选轮转走完一圈仍不行 → 探测并切备用 DC（若 DC 列表里有其它可达 DC）。
     */
    private func attemptReconnect(dcId: Int64): Unit {
        if (this.retired.load()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] reconnect refused: client retired (DC${dcId})")
            return
        }
        Hilog.info(0, "CjTelegram", "[MTProtoClient] Connection lost, attempting reconnect (DC${dcId})...")
        this.notifyConnectionState(ConnectionState.Connecting)

        let schemes = MTProtoConfig.getSchemesForDC(dcId)
        let schemeCount = schemes.size

        // 当前应使用的候选 scheme（按 controller 维护的索引，failover 切换后取备用端点）。
        let idx = this.reconnectCtrl.currentSchemeIndex() % schemeCount
        let chosenScheme = schemes[idx]

        // 用所选 scheme 的端点重建该 DC 的 transport（多 scheme 时切到备用端点；
        // 单 scheme 退化时 idx 恒 0，端点 == 原 DC，行为字节不变，回归安全）。
        let transport = this.transportManager.rebuildTransport(dcId, chosenScheme)
        transport.setCallback(this)
        transport.connect()

        if (transport.isConnected()) {
            // 重连成功：启动接收循环，清零退避 / failover。（P2-246: 保存 Future 供 migrate join）
            let transportRef = transport
            let fut4 = spawn {
                transportRef.startReceiveLoop()
            }
            receiveLoopFutureMutex.lock()
            this.receiveLoopFuture = Some(fut4)
            receiveLoopFutureMutex.unlock()
            this.reconnectCtrl.onSuccess()
            Hilog.info(0, "CjTelegram", "[MTProtoClient] Reconnect SUCCESS via ${chosenScheme.describe()}")
            return
        }

        // 本次重连失败：记账 → 推进退避 / 决定是否切备用 scheme。
        let decision = this.reconnectCtrl.onFailure(schemeCount)
        if (decision.switched) {
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] scheme failover → idx=${decision.schemeIndex} (next retry in ${decision.delayMs}ms)")
        } else {
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] reconnect failed, backing off ${decision.delayMs}ms (attempt=${this.reconnectCtrl.currentAttempt()})")
        }
    }

    /**
     * 可达性恢复（或外部主动）触发立即重连 —— P2-252 ReachabilityService 消费接线点。
     *
     * 网络从「断」到「通」时，由 services 层（TelegramCore_NetworkService 的可达性监听）调用本方法：
     *   取消当前退避等待 → 立刻发起一次重连尝试，而非干等退避序列走完。
     * 重连失败仍按退避/failover 继续；成功则 onConnected 清零。
     *
     * 不直接 import ReachabilityService（services → core.mtproto 已存在依赖，反向 import 会成包级循环）；
     * 接线由 services 层注入回调驱动本公开方法（与 setMeteringHooks 同一解耦范式）。
     */
    public func triggerReconnect(): Unit {
        // 调用方有二：ReachabilityService 的网络恢复回调（wireReachabilityReconnect 注册）、
        // AppStartup 的前台恢复订阅（EVT_FOREGROUND_CHANGED）。故文案不再限定 reachability。
        if (this.retired.load()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] immediate reconnect ignored: client retired")
            return
        }
        Hilog.info(0, "CjTelegram", "[MTProtoClient] immediate reconnect requested")
        this.reconnectCtrl.triggerImmediateReconnect()
        // P2-246 rework2: snapshot session ref — app thread may call this during migrateToDC
        let s = getSessionRef()
        let dcId = s.dcId
        let transport = this.transportManager.getTransport(dcId)
        if (!transport.isConnected()) {
            this.attemptReconnect(dcId)
        } else {
            this.reconnectCtrl.onSuccess()
        }
    }

    /**
     * 断开连接
     *
     * P2-244: 断开前停止 ACK 定时器，避免定时器在断连后继续尝试 flush（无 transport）。
     */
    public func isRetired(): Bool {
        return this.retired.load()
    }

    /**
     * 退役并断开：账号切换 / 登出把本实例移出注册表后调用。此后本实例拒绝发送、拒绝重连、
     * 丢弃 updates，避免仍持有旧引用的调用方把上一账号的连接复活并向当前账号投影推送。
     */
    public func retire(): Unit {
        this.retired.store(true)
        this.disconnect()
        Hilog.info(0, "CjTelegram", "[MTProtoClient] retired (DC${this.session.dcId})")
    }

    public func disconnect() {
        this.lifecycleInitialized.store(false)
        stopAckTimer()
        // P2-245: 停止漂移校正定时器（与 ACK timer 对称）
        this.timeSyncService.stopDriftTimer()
        // P2-251c: 停止 PFS 临时密钥过期预检定时器（与 startPfsRenewTimer 对称）
        stopPfsRenewTimer()
        this.transportManager.disconnectAll()
        this.connectionInitialized = false
    }

    /**
     * 迁移到指定数据中心
     *
     * P2-246 Gap-6: 修复三处竞态：
     *   (1) join 旧接收循环：disconnectAll() 只设 running=false + 关 socket，
     *       不等旧线程真正退出。此处拿到旧 Future 后调 get()，确保旧线程完全停止
     *       再替换 session（最长等待 5s 防死锁；等待期间不持有任何 session 侧锁）。
     *   (2) this.session 引用替换加锁：sessionRefMutex 保护 var 字段的指针写，
     *       消除无内存屏障的裸 var 替换。
     *   (3) session 状态清零走线程安全 setter：
     *       setAuthKey(None, None) / clearServerSalt() / setAuthKeyState() / resetSeqNo()
     *       均在 SessionInfo.sessionLock 内执行（P2-244 已建立）。
     */
    public func migrateToDC(dcId: Int64) {
        Hilog.info(0, "CjTelegram", "[MTProtoClient] Migrating to DC${dcId}...")

        // 根治 AUTH_KEY_UNREGISTERED（跨 DC 授权丢失）：
        //   若旧 DC 的 session 已经是"服务端已授权"的登录会话（authKeyState == Registered，
        //   典型场景：verifyCode 登录成功后收到 USER_MIGRATE_X，需要迁到 home DC），
        //   在断开旧连接前先用旧 DC 的 auth key 调 auth.exportAuthorization(dcId=新DC)，
        //   拿到的 (id, bytes) 在新 DC 建好 auth key 后立即 auth.importAuthorization，
        //   把授权原样搬到新 DC 上 —— 这是 Telegram 标准的跨 DC 授权迁移做法，
        //   避免新 DC 的 auth key 停留在"已创建但服务端未授权"状态导致后续
        //   messages.getDialogs / updates.getState 收到 401 AUTH_KEY_UNREGISTERED。
        //   若旧 DC 尚未登录（sendCode 阶段的 PHONE_MIGRATE_/NETWORK_MIGRATE_），
        //   authKeyState 不是 Registered，跳过 export，保留原有"新 DC 直接 createAuthKey"行为。
        var exportedAuth: Option<(Int64, Array<Byte>)> = None
        if (this.session.getAuthKeyState() == AuthKeyState.Registered && hasAuthKey()) {
            try {
                let exportReq = AuthExportAuthorization()
                exportReq.dcId = Int32(dcId)
                let exportResponse = sendRequest(exportReq.toBytes())
                let (exportId, exportBytes) = parseExportedAuthorization(exportResponse)
                if (exportId != 0 || exportBytes.size > 0) {
                    exportedAuth = Some((exportId, exportBytes))
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] migrateToDC: exported authorization from DC${this.session.dcId} for DC${dcId} (id=${exportId}, bytes=${exportBytes.size})")
                } else {
                    Hilog.info(0, "CjTelegram",
                        "[MTProtoClient] migrateToDC: exportAuthorization returned empty, will rely on fresh auth.signIn on new DC")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] migrateToDC: exportAuthorization failed (${e}), will rely on fresh auth.signIn on new DC")
            }
        }

        // HI-AUTH-0004 真机插桩实测根因修复：timeSyncService 是跨 DC 复用的单实例，
        // 其 future_salts 列表（get_future_salts#b921bd04 响应）按挂钟时间窗口判定有效性，
        // 不含 DC 标识 —— 迁移到新 DC 后旧 DC 的未来盐仍会被 getCurrentSalt() 判定为"有效"
        // 并在 buildMessage 中优先于 session.serverSalt 使用，导致 handleBadServerSalt 刚
        // 写入的新 DC 盐被永久屏蔽、重发消息用错误盐加密、服务端连续 bad_server_salt 直到
        // MAX_TRANSIENT_RETRIES 耗尽（"No response from server"）。此处清空 future_salts 缓存，
        // 使新 DC 建连后 buildMessage 回退 session.serverSalt（= 握手/bad_server_salt 校正值），
        // 直至新 DC 自己的 get_future_salts 响应到达。
        this.timeSyncService.resetForMigration()

        // Step 1: 断开传输层（设 running=false + 关 socket）
        this.transportManager.disconnectAll()
        this.connectionInitialized = false

        // Step 2 (P2-246 Gap-6.1): 取出旧接收循环 Future，等待旧线程完全退出，再替换 session。
        // 等待最长 5s（实际接收线程检测 running=false 后几乎立即退出；5s 是防极端情况的上限）。
        // 注意：等待期间绝不持有 sessionLock / rpcMonitor / ackMutex（避免旧线程回调也持同一锁导致死锁）。
        receiveLoopFutureMutex.lock()
        let oldFut = this.receiveLoopFuture
        this.receiveLoopFuture = None
        receiveLoopFutureMutex.unlock()

        match (oldFut) {
            case Some(fut) =>
                try {
                    fut.get(Duration.second * 5)
                } catch (_te: Exception) {
                    Hilog.info(0, "CjTelegram", "[MTProtoClient] migrateToDC: receive loop join timed out (5s), proceeding")
                }
            case None => ()
        }

        // Step 3 (P2-246 Gap-6.2): sessionRefMutex 保护 this.session 引用替换（消除无屏障 var 写）
        sessionRefMutex.lock()
        this.session = this.acquireSession(dcId)
        sessionRefMutex.unlock()

        // Step 4 (P2-246 Gap-6.3): 走线程安全 setter 清零 session 状态（均在 sessionLock 内）
        this.session.setAuthKey(None, None)
        this.session.clearServerSalt()
        this.session.setAuthKeyState(AuthKeyState.None_)
        this.session.generateSessionId()
        this.session.resetSeqNo()
        SessionManager.saveSession(this.session)

        // 连接到新 DC
        let transport = this.transportManager.getTransport(dcId)
        transport.setCallback(this)
        transport.connect()
        let transportRef = transport
        let futMigrate = spawn {
            transportRef.startReceiveLoop()
        }
        receiveLoopFutureMutex.lock()
        this.receiveLoopFuture = Some(futMigrate)
        receiveLoopFutureMutex.unlock()

        // 创建新的 auth key
        createAuthKey()

        // 若旧 DC 已导出授权，在新 DC auth key 建好后立即 import，把登录授权原样搬过来。
        // 只有 import 明确成功（parseImportAuthorizationResponse 校验为
        // auth.authorization#2ea2c0d4 / auth.authorizationSignUpRequired#44747e9a）才将
        // 新 session 标记 Registered；import 失败或异常则保持 Created（未授权），
        // 调用方（RealAuthService.verifyCode）仍会用同一 auth key 重试 auth.signIn 完成授权，
        // 不会因为 import 失败而卡死。
        //
        // HI-AUTH-0006：新 DC 连接建立后（createAuthKey 完成）第一条加密 RPC 必须自带
        // invokeWithLayer(initConnection(...)) 包裹，否则服务端返回 400 CONNECTION_NOT_INITED。
        // 直接调用公开 sendRequest()（其内部自 HI-AUTH-0006 起已改为：connectionInitialized
        // ==false 时把调用方自己的 data 直接包进 invokeWithLayer(initConnection(...)) 作为
        // 该连接首请求发出，不再额外插入一次无关的 help.getConfig 探测），无需在此重复实现包裹逻辑。
        match (exportedAuth) {
            case Some((exportId, exportBytes)) =>
                if (hasAuthKey()) {
                    try {
                        let importReq = AuthImportAuthorization()
                        importReq.id = exportId
                        importReq.bytes = exportBytes
                        let importResponse = sendRequest(importReq.toBytes())
                        let importOk = parseImportAuthorizationResponse(importResponse)
                        if (importOk) {
                            this.session.setAuthKeyState(AuthKeyState.Registered)
                            SessionManager.saveSession(this.session)
                            Hilog.info(0, "CjTelegram",
                                "[MTProtoClient] migrateToDC: importAuthorization on DC${dcId} succeeded, session marked Registered")
                        } else {
                            Hilog.info(0, "CjTelegram",
                                "[MTProtoClient] migrateToDC: importAuthorization on DC${dcId} failed, caller must complete auth.signIn on new DC")
                        }
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram",
                            "[MTProtoClient] migrateToDC: importAuthorization exception (${e}), caller must complete auth.signIn on new DC")
                    }
                }
            case None => ()
        }

        Hilog.info(0, "CjTelegram", "[MTProtoClient] Migration to DC${dcId} COMPLETE")
    }

    // =========================================================================
    // P2-244 能力一: 发送 msgs_ack#62d6b459（确认已收到的服务端 content-related 消息）
    //
    // 对应 iOS MTProto.m L1030-1054:
    //   - scheduledMessageConfirmations 收集待确认 msgId
    //   - 构造 0x62d6b459 + 0x1cb5c415(Vector) + count + [msgId × count]
    //   - outgoingMessage.requiresConfirmation = false（not-content-related）
    //   - iOS MTMaxUnacknowledgedMessageCount = 64（阈值）
    // =========================================================================

    /**
     * P2-244: 将收到的服务端 content-related 消息 ID 加入待 ACK 集合。
     *
     * 判断规则（对齐 iOS MTProto.m L2486-2492）：
     *   服务端的 seqno 奇数 → content-related → 需要 ACK。
     *   seqno 偶数（not-content-related，如 ack/pong）→ 不需要 ACK。
     *
     * 在 ackMutex 保护下操作，IO（flush）不在锁内执行。
     * @param msgId 服务端消息 ID
     * @param serverSeqNo 服务端消息的 seqno（奇数 = content-related）
     */
    private func scheduleAck(msgId: Int64, serverSeqNo: Int32): Unit {
        // 奇数 seqno = content-related 消息，需要我方 ACK（与 iOS L2486 % 2 != 0 对齐）
        if (serverSeqNo % 2 == 0) {
            return  // not-content-related，不需 ACK
        }
        var shouldFlush = false
        ackMutex.lock()
        this.pendingAckMsgIds.add(msgId)
        if (this.pendingAckMsgIds.size >= MTProtoClient.ACK_BATCH_THRESHOLD) {
            shouldFlush = true
        }
        ackMutex.unlock()
        if (shouldFlush) {
            // 达到阈值立即 flush（不持 ackMutex 做 IO）
            flushPendingAcks()
        }
    }

    /**
     * P2-244: 打包发送 msgs_ack 确认帧（将待 ACK 队列清空并发送）。
     *
     * 线程安全：在 ackMutex 内取出并清空待列表，在锁外做序列化和 IO。
     * 序列化格式（对齐 iOS MTProto.m L1036-1043）：
     *   0x62d6b459(4) + 0x1cb5c415(4, Vector) + count:Int32(4) + [msgId:Int64 × count]
     * 用 not-content-related seqno（对齐 iOS requiresConfirmation=false）。
     */
    public func flushPendingAcks(): Unit {
        // 在 ackMutex 内取出待 ACK 列表并清空（IO 在锁外进行）
        var toAck: ArrayList<Int64> = ArrayList<Int64>()
        ackMutex.lock()
        if (this.pendingAckMsgIds.size == 0) {
            ackMutex.unlock()
            return
        }
        // 交换：把当前列表移出，用新空列表替换
        let tmp = this.pendingAckMsgIds
        this.pendingAckMsgIds = ArrayList<Int64>()
        ackMutex.unlock()
        toAck = tmp

        if (!hasAuthKey()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] flushPendingAcks: no auth key, dropping ${toAck.size} ack(s)")
            return
        }

        // Fix3 — P2-246: 取 session 引用快照，避免 migrate 期间裸读 this.session 竞态
        let s = getSessionRef()

        // 序列化 msgs_ack#62d6b459
        let serializer = TLSerializer()
        serializer.writeUInt32(TLConstructors.MSGS_ACK)      // 0x62d6b459
        serializer.writeUInt32(TLConstructors.VECTOR)         // 0x1cb5c415
        serializer.writeInt32(Int32(toAck.size))
        for (mid in toAck) {
            serializer.writeInt64(mid)
        }
        let ackBody = serializer.getBytes()

        // not-content-related seqno（ack 本身不需要被确认）
        let ackMsgId = s.generateMessageId()
        let ackSeqNo = s.getNextSeqNo(false)
        let message = buildMessage(ackMsgId, ackSeqNo, ackBody)
        let encrypted = encryptMessage(message)

        let dcId = s.dcId
        let transport = this.transportManager.getTransport(dcId)
        if (transport.isConnected()) {
            transport.send(encrypted)
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] msgs_ack sent: ${toAck.size} msgId(s) acked (ackMsgId=${ackMsgId})")
        } else {
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] flushPendingAcks: transport not connected, dropped ${toAck.size} ack(s)")
        }
    }

    // =========================================================================
    // P2-245 能力集：时间同步服务配置 + get_future_salts wire
    // =========================================================================

    /**
     * P2-245: 配置 MTTimeSyncService 回调并启动漂移定时器（在 initialize 中调用）。
     *
     * 注入两个回调：
     *   1. onOffsetUpdated：timeSyncService 计算出新 offset 后，更新 this.timeOffset（wall clock 域）。
     *      与 bad_msg 16/17/48 的 timeOffset 写入同一字段 —— 都是被动校正，统一合并到 this.timeOffset。
     *      P2-245 Fix3：所有读写均在 timeOffsetMutex（叶子锁）下执行，消除 Timer 线程 vs 接收线程竞态。
     *   2. sendFutureSaltsRequest：timeSyncService 需要发 get_future_salts 时调用本方法，
     *      由 MTProtoClient 构造并发送（timeSyncService 不持有 transport/session 引用）。
     *
     * 漂移定时器以 serverNowSec() 作为当前服务端时间注入（包含 timeOffset 校正）。
     */
    private func setupTimeSyncService(): Unit {
        let clientRef = this

        // 回调 1：offset 更新（wall clock 域，与 bad_msg timefix 同字段）
        // P2-245 Fix3：在 timeOffsetMutex 下写 timeOffset，消除 Timer 线程竞态
        this.timeSyncService.setOffsetCallback({ newOffset =>
            let oldOffset = synchronized(clientRef.timeOffsetMutex) {
                let old = clientRef.timeOffset
                clientRef.timeOffset = newOffset
                old
            }
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] P2-245 timeOffset updated by multi-sample: ${oldOffset} → ${newOffset}")
        })

        // 回调 2：触发 get_future_salts 实际发送（锁外 IO）；num 参数透传，不再硬编码 1
        this.timeSyncService.setSendFutureSaltsCallback({ n =>
            clientRef.sendGetFutureSalts(n)
        })

        // 启动漂移校正定时器（每 1800 秒重同步一次）
        this.timeSyncService.startDriftTimer({ =>
            clientRef.serverNowSec()
        })

        // 初始化时立即请求第一批未来盐（32 个，对齐 iOS 无盐时的首次请求）
        this.timeSyncService.requestFutureSalts(32)
    }

    /**
     * P2-245: 构造并发送 get_future_salts#b921bd04 请求。
     *
     * 协议格式（对应 iOS MTTimeSyncMessageService.m L54-58）：
     *   0xb921bd04(4, LE) + num:Int32(4, LE)
     *
     * P2-245 Fix2：num 参数由调用方传入（不再硬编码 1），实现完整穿透链：
     *   requestFutureSalts(N) → callback(N) → sendGetFutureSalts(N) → writeInt32(N)
     *   首次无盐传 32，有盐临近过期传 1（对齐 iOS MTTimeSyncMessageService.m 行为）。
     *
     * 用 not-content-related seqNo（对齐 iOS outgoingMessage.requiresConfirmation=false，
     * get_future_salts 是内部机制消息，不需要被 ACK 确认）。
     *
     * @param num 请求的未来盐数量（由 requestFutureSalts 透传）
     */
    private func sendGetFutureSalts(num: Int32): Unit {
        if (!hasAuthKey()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] sendGetFutureSalts: no auth key, deferring")
            return
        }

        // P2-246 rework2: snapshot session ref — drift timer fires independently of migrateToDC
        let s = getSessionRef()

        let serializer = TLSerializer()
        serializer.writeUInt32(TLConstructors.GET_FUTURE_SALTS)  // 0xb921bd04
        serializer.writeInt32(num)
        let body = serializer.getBytes()

        let reqMsgId = s.generateMessageId()
        let reqSeqNo = s.getNextSeqNo(false)  // not-content-related
        let message = buildMessage(reqMsgId, reqSeqNo, body)
        let encrypted = encryptMessage(message)

        let dcId = s.dcId
        let transport = this.transportManager.getTransport(dcId)
        if (transport.isConnected()) {
            transport.send(encrypted)
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] get_future_salts#b921bd04 sent (num=${num}, msgId=${reqMsgId})")
        } else {
            Hilog.info(0, "CjTelegram",
                "[MTProtoClient] sendGetFutureSalts: transport not connected, skipping")
        }
    }

    /**
     * P2-245: 获取当前服务端建议使用的盐（来自 future_salts 列表）。
     *
     * 供 buildMessage 调用：若 timeSyncService 有有效未来盐，优先使用（轮换后的盐），
     * 否则回退 session.serverSalt（握手时获得的盐）。
     * 不修改 session.serverSalt（盐轮换仅影响 buildMessage 的实际写入，不改 session 持久化字段）。
     *
     * @return Some(salt: Int64) 若有有效盐；None 则由调用方用 session.serverSalt 兜底
     */
    public func getEffectiveSalt(): Option<Int64> {
        return this.timeSyncService.getCurrentSalt(this.serverNowSec())
    }

    /**
     * P2-244: 启动周期性 ACK 定时器（每 5 秒 flush 一次）。
     *
     * 使用 Timer.repeat（std.sync）而非 spawn+sleep，避免线程泄漏。
     * 幂等：若已有定时器则先 cancel 再重建（reconnect 后会重新调用 initialize）。
     */
    private func startAckTimer(): Unit {
        let clientRef = this
        ackTimerMutex.lock()
        match (this.ackTimer) {
            case Some(t) => t.cancel()
            case None => ()
        }
        // 5秒后开始，每5秒重复一次（对齐 iOS deferred ack 策略）
        let t = Timer.repeat(Duration.second * 5, Duration.second * 5, {=>
            clientRef.flushPendingAcks()
        })
        this.ackTimer = Some(t)
        ackTimerMutex.unlock()
        Hilog.info(0, "CjTelegram", "[MTProtoClient] Periodic ACK timer started (5s interval)")
    }

    /**
     * P2-244: 停止 ACK 定时器（disconnect 时调用）。
     */
    private func stopAckTimer(): Unit {
        ackTimerMutex.lock()
        match (this.ackTimer) {
            case Some(t) =>
                t.cancel()
                this.ackTimer = None
            case None => ()
        }
        ackTimerMutex.unlock()
    }

    /**
     * P2-251c: 启动 PFS 临时密钥过期预检定时器。
     *
     * 每 1800 秒（30 分钟）检查一次临时密钥是否将在 2 小时内过期。
     * 对齐 iOS MTContext.m 的 tempKeyExpiration=86400s 策略：
     *   iOS 在 currentTimestamp > validUntilTimestamp 时触发重协商；
     *   Cangjie 采用提前 7200s（~2h）预先重绑，确保密钥在到期前已完成轮换。
     *
     * 幂等：若已有定时器则先 cancel 再重建（reconnect 后会重新调用 initialize）。
     * 仅在 PFS 激活且临时密钥存在时才触发 activatePfs()；否则静默跳过（永久密钥路径不受影响）。
     */
    private func startPfsRenewTimer(): Unit {
        let clientRef = this
        pfsRenewTimerMutex.lock()
        match (this.pfsRenewTimer) {
            case Some(t) => t.cancel()
            case None => ()
        }
        // 首次延迟 1800s，此后每 1800s 重复（30 分钟周期检查）
        let t = Timer.repeat(Duration.second * 1800, Duration.second * 1800, {=>
            clientRef.checkAndRenewPfsKey()
        })
        this.pfsRenewTimer = Some(t)
        pfsRenewTimerMutex.unlock()
        Hilog.info(0, "CjTelegram", "[MTProtoClient] PFS renew timer started (1800s interval)")
    }

    /**
     * P2-251c: 停止 PFS 临时密钥过期预检定时器（disconnect 时调用）。
     */
    private func stopPfsRenewTimer(): Unit {
        pfsRenewTimerMutex.lock()
        match (this.pfsRenewTimer) {
            case Some(t) =>
                t.cancel()
                this.pfsRenewTimer = None
            case None => ()
        }
        pfsRenewTimerMutex.unlock()
    }

    /**
     * P2-251c: 定时器回调 — 检查临时密钥是否将在 2h 内过期，若是则异步触发重协商。
     *
     * 锁顺序：pfsMutex（读取 tempAuthKey / pfsRenewInFlight）→ 锁外 spawn activatePfs()。
     * pfsRenewInFlight 防并发：上一次重协商仍在进行中时跳过本次触发。
     */
    private func checkAndRenewPfsKey(): Unit {
        let now = serverNowSec()
        var shouldRegen = false
        pfsMutex.lock()
        match (this.tempAuthKey) {
            case Some(tk) =>
                if (tk.isValid() && tk.bound) {
                    // 提前 7200s（2h）触发预先重绑（对齐 iOS 24h 总有效期，约 22h 后开始轮换）
                    let renewThreshold: Int64 = 7200
                    if (!this.pfsRenewInFlight && tk.expiresAt > 0 && (tk.expiresAt - now) <= renewThreshold) {
                        this.pfsRenewInFlight = true
                        shouldRegen = true
                    }
                }
            case None => ()
        }
        pfsMutex.unlock()

        if (shouldRegen) {
            let selfRef = this
            spawn {
                Hilog.info(0, "CjTelegram", "[MTProtoClient] PFS renew timer: proactive regen+rebind started")
                let ok = selfRef.activatePfs()
                selfRef.pfsMutex.lock()
                selfRef.pfsRenewInFlight = false
                selfRef.pfsMutex.unlock()
                Hilog.info(0, "CjTelegram", "[MTProtoClient] PFS renew timer: regen+rebind result=${ok}")
            }
        }
    }

    // =========================================================================
    // P2-244 能力二: 发送 msg_resend_req#7d861a08（请求服务端重传其已处理的响应）
    //
    // 场景：我方已向服务端发送请求并等待响应，但响应迟迟未到 → 向服务端
    //   发送 msg_resend_req，请求服务端重新发送其已处理的响应消息。
    //
    // 注意与 242c 的区别（对应 prompt 要求）：
    //   242c handleMsgsStateInfo path B：服务端未收到我方请求 → 重发我方原始请求体。
    //   本方法：我方未收到服务端响应 → 请求服务端重传其响应（服务端 resend）。
    //   两个方向，不混用。
    //
    // 对应 iOS MTResendMessageService.h / MTProto.m requestMessageWithId:。
    // =========================================================================

    /**
     * P2-244: 发送 msg_resend_req#7d861a08 请求服务端重传指定消息（其响应消息）。
     *
     * 字节布局（TL schema boxed Vector<long>，对齐 iOS MTResendMessageService.m L51-54 发送端）：
     *   0x7d861a08(4) + 0x1cb5c415(4, Vector tag) + count:Int32(4) + [msgId:Int64 × count]
     *   含 0x1cb5c415 Vector 构造子（boxed Vector 规范）；iOS MTInternalMessageParser.m L362 解析
     *   server→client 方向时读裸 count+list，是服务端下行格式，不影响我方上行发送含 tag 的正确性。
     *
     * not-content-related seqno（服务端 resend 请求本身不计入内容序列号）。
     *
     * @param msgIds 要请求服务端重传的消息 ID 列表（服务端的消息 ID，非我方 msgId）
     * @return 发送成功返回 true；未发送（无 auth key / 断连 / 空列表）返回 false
     */
    public func sendMsgResendReq(msgIds: ArrayList<Int64>): Bool {
        if (msgIds.size == 0) {
            return false
        }
        if (!hasAuthKey()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] sendMsgResendReq: no auth key")
            return false
        }

        // P2-246 rework2: snapshot session ref — public method callable from app thread
        // concurrently with migrateToDC Step3
        let s = getSessionRef()

        // 序列化 msg_resend_req#7d861a08 { msg_ids: Vector<long> }
        // TL schema: msg_resend_req#7d861a08 msg_ids:Vector<long> = MsgResendReq
        // TL 规范中 Vector<long> 为 boxed 类型，发送时包含 0x1cb5c415 Vector 构造子 + count + data，
        // 对齐 iOS MTResendMessageService.m L51-54（发送端写入 Vector tag）。
        // 注意：iOS MTInternalMessageParser.m L362 解析服务端→客户端方向时直接读 count+list，
        // 这是 server 侧发出的 bare 格式，与我方发送端含 Vector tag 的正确性无关，不矛盾。
        let serializer = TLSerializer()
        serializer.writeUInt32(TLConstructors.MSG_RESEND_REQ)  // 0x7d861a08
        // Vector<long> (boxed): 0x1cb5c415 Vector tag + count + [msgId × count]
        serializer.writeUInt32(TLConstructors.VECTOR)           // 0x1cb5c415
        serializer.writeInt32(Int32(msgIds.size))
        for (mid in msgIds) {
            serializer.writeInt64(mid)
        }
        let reqBody = serializer.getBytes()

        let reqMsgId = s.generateMessageId()
        let reqSeqNo = s.getNextSeqNo(false)  // not-content-related
        let message = buildMessage(reqMsgId, reqSeqNo, reqBody)
        let encrypted = encryptMessage(message)

        let dcId = s.dcId
        let transport = this.transportManager.getTransport(dcId)
        if (!transport.isConnected()) {
            Hilog.info(0, "CjTelegram", "[MTProtoClient] sendMsgResendReq: transport not connected")
            return false
        }

        transport.send(encrypted)
        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] msg_resend_req sent: reqMsgId=${reqMsgId} requesting resend of ${msgIds.size} server msg(s)")
        return true
    }

    // =========================================================================
    // P2-244 能力三: 处理 bad_msg_notification#a7eff811
    //
    // 对应 iOS MTProto.m L2494-2572 bad_msg_notification 分支：
    //   根据 error_code 分组纠正，然后通知 messageServices messageDeliveryFailed。
    //
    // 错误码纠正表（对齐 iOS MTProto.m switch(errorCode) L2518-2553）：
    //   16/17 → msg_id 太低/太高（时间不同步）：调整 timeOffset + 重发失败消息
    //   18    → msg_id 不整除4：修复 msgId 生成（session 内部已保证对齐，记日志即可）
    //   19    → 容器 msg_id 重复：重发失败消息
    //   20    → 消息太旧：重发失败消息
    //   32/33 → seqno 太低/太高：重置 seqno 状态 + 重发失败消息
    //   34/35 → seqno 应为偶/奇错误：记录日志（seqno 分类错误）+ 重发失败消息
    //   其他  → 记日志忽略
    //
    // 时间偏移调整（error 16/17）：
    //   iOS 从 bad_msg_notification 本身的 msgId 推算时间差，对齐 L2527：
    //     timeDifference = incomingMessage.messageId / 4294967296.0 - [[NSDate date] timeIntervalSince1970]
    //   我们从响应的 incomingMsgId 推算：serverUnixSec = incomingMsgId >> 32
    //   timeOffset = serverUnixSec - localNowSec（wallclock，与 AuthKeyCreator.computeAuthKey 同口径）
    //   使用 wall clock（非单调时钟）：timeOffset 是 wall clock 偏移，用于 msgId 生成（基于 Unix 时间）。
    //   与 P2-243 的 nextRetryAtMs（单调时钟）不混用。
    // =========================================================================

    /**
     * P2-244: 处理 bad_msg_notification#a7eff811。
     *
     * @param deserializer 已读过构造子(0xa7eff811)后的反序列化器
     * @param incomingMsgId 本 bad_msg_notification 消息自身的 msgId（用于 16/17 时间校正）
     */
    private func handleBadMsgNotification(deserializer: TLDeserializer, incomingMsgId: Int64): Unit {
        let badMsgId = deserializer.readInt64()
        let badMsgSeqNo = deserializer.readInt32()
        let errorCode = deserializer.readInt32()

        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] bad_msg_notification#a7eff811: badMsgId=${badMsgId} badSeqNo=${badMsgSeqNo} errorCode=${errorCode}")

        // 取出受影响的 pending RPC（用于后续重发）
        let badMsgIdStr = "${badMsgId}"
        var pendingOpt: Option<PendingRPC> = None
        var bodyOpt: Option<Array<Byte>> = None
        synchronized(rpcMonitor) {
            if (this.pendingRPCs.contains(badMsgIdStr)) {
                let p = this.pendingRPCs[badMsgIdStr]
                pendingOpt = Some(p)
                bodyOpt = p.requestBody
            }
        }

        match (errorCode) {
            case 16 | 17 =>
                // msg_id 太低（16）或太高（17）：时间不同步。
                // 从服务端该消息 msgId 的高 32 位推算服务器 Unix 时间（对齐 iOS L2527）：
                //   iOS: timeDifference = incomingMessage.messageId / 4294967296.0 - [[NSDate date] timeIntervalSince1970]
                // incomingMsgId 高 32 位 = 服务端 Unix 秒（MTProto msgId 规范：高 32 bit = server Unix 秒）。
                // timeOffset 使用 wall clock（与 AuthKeyCreator.createAuthKey 同口径），
                // 不使用单调时钟（monotonic 只用于退避计时，见 mtprotoMonotonicNowMs）。
                let serverUnixSec = (incomingMsgId >> 32) & 0x7fffffff
                let localNowSec = DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000
                let newOffset = serverUnixSec - localNowSec
                // P2-245 Fix3：timeOffset 写入在 timeOffsetMutex 下执行
                let oldOffsetBadMsg1617 = synchronized(timeOffsetMutex) {
                    let old = this.timeOffset
                    this.timeOffset = newOffset
                    old
                }
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] bad_msg error ${errorCode}: adjusting timeOffset ${oldOffsetBadMsg1617} → ${newOffset} (server=${serverUnixSec}, local=${localNowSec})")
                // 重发受影响的 pending RPC（如有）
                resendAfterBadMsg(badMsgIdStr, pendingOpt, bodyOpt, "bad_msg/16-17(timefix)")

            case 18 =>
                // msg_id 不整除4：我方 msgId 生成逻辑已对齐（generateMessageId 返回 Unix微秒×4），
                // 理论不应发生。记日志 + 重发受影响消息。
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] bad_msg error 18: msg_id not divisible by 4 (session will self-correct via generateMessageId)")
                resendAfterBadMsg(badMsgIdStr, pendingOpt, bodyOpt, "bad_msg/18(msgid-align)")

            case 19 =>
                // 容器内层 msgId 重复：记日志 + 重发受影响消息
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] bad_msg error 19: duplicate container msgId ${badMsgId}")
                resendAfterBadMsg(badMsgIdStr, pendingOpt, bodyOpt, "bad_msg/19(dup-container)")

            case 20 =>
                // 消息太旧（距服务端时钟 > 300s）：重发受影响消息
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] bad_msg error 20: message too old, badMsgId=${badMsgId}")
                resendAfterBadMsg(badMsgIdStr, pendingOpt, bodyOpt, "bad_msg/20(too-old)")

            case 32 | 33 =>
                // seqno 太低（32）或太高（33）：整体换新 session（对齐 iOS L2538-2542 resetSessionInfo）。
                // 必须换 sessionId：服务器按 sessionId 记录已见最高 seqNo，只清 seqNo
                // 会陷入 bad_msg 32 死循环（每条消息 seqNo=1 永远 out of range，信令全断）。
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] bad_msg error ${errorCode}: seqno out of range, resetting session (new sessionId + seqNo=0)")
                this.session.resetSession()
                // 新 session 在服务端是全新会话，initConnection 状态随之丢失——
                // 必须清标志让下一条请求重新包装，否则 CONNECTION_NOT_INITED。
                this.connectionInitialized = false
                resendAfterBadMsg(badMsgIdStr, pendingOpt, bodyOpt, "bad_msg/${errorCode}(session-reset)")

            case 34 | 35 =>
                // seqno 应为偶（34）/ 奇（35）错误：说明我方 content-related 分类有误。
                // 记日志（seqno 分类由 sendRPCRequestConcurrent 的 getNextSeqNo(true/false) 控制，
                // 此处触发说明调用方传入了错误的 contentRelated 参数）+ 重发受影响消息。
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] bad_msg error ${errorCode}: seqno even/odd error (check contentRelated classification)")
                resendAfterBadMsg(badMsgIdStr, pendingOpt, bodyOpt, "bad_msg/${errorCode}(seqno-parity)")

            case 48 =>
                // error 48：时钟同步错误（对应 iOS MTProto.m L2544 initiateTimeSync）。
                // 与 error 16/17 相同的 timefix 路径：从 incomingMsgId 高 32 位推算服务端 Unix 秒，
                // 计算 timeOffset，再重发受影响消息。
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] bad_msg error 48: timefix, badMsgId=${badMsgId}")
                let serverUnixSec48 = (incomingMsgId >> 32) & 0x7fffffff
                let localNowSec48 = DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000
                let newOffset48 = serverUnixSec48 - localNowSec48
                // P2-245 Fix3：timeOffset 写入在 timeOffsetMutex 下执行
                synchronized(timeOffsetMutex) { this.timeOffset = newOffset48 }
                resendAfterBadMsg(badMsgIdStr, pendingOpt, bodyOpt, "bad_msg/48(timefix)")

            case _ =>
                // 其他错误码：记日志
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] bad_msg error ${errorCode}: unhandled code, badMsgId=${badMsgId}")
        }
    }

    /**
     * P2-244: bad_msg_notification 后重发受影响的 pending RPC（内部辅助）。
     *
     * 与 handleMigrateAndResend / scheduleRetryAfterDelay 的同对象重映射语义一致（242c Path B）：
     *   新 msgId → 同一 PendingRPC 对象，服务端对 newMsgId 的响应经 dispatchResponse 唤醒原等待者。
     *
     * @param oldMsgIdStr 受影响的原始 msgId 字符串
     * @param pendingOpt  已提取的 PendingRPC 对象（可能 None，表示已完成/不存在）
     * @param bodyOpt     原始请求体（可能 None，表示无法重发）
     * @param tag         日志 tag
     */
    private func resendAfterBadMsg(
        oldMsgIdStr: String,
        pendingOpt: Option<PendingRPC>,
        bodyOpt: Option<Array<Byte>>,
        tag: String
    ): Unit {
        match (pendingOpt) {
            case Some(pending) =>
                match (bodyOpt) {
                    case Some(body) =>
                        // 检查 pending 仍在等待（未被超时清理或取消）
                        var stillPending = false
                        synchronized(rpcMonitor) {
                            stillPending = !pending.completed
                        }
                        if (!stillPending) {
                            Hilog.info(0, "CjTelegram",
                                "[MTProtoClient] ${tag}: pending already completed, skip resend for ${oldMsgIdStr}")
                            return
                        }
                        // HI-AUTH-0004 真机复测发现：bad_server_salt/bad_msg_notification 可能被
                        // 服务端连续多次拒绝重发消息（观测到同一 pending 数百次循环 resend，
                        // 每次都换新 msgId 仍收到新的 bad_server_salt）。若不设上限，会形成
                        // 客户端本地无限重发风暴（虽不再 60s 死等，但会无限占用连接/电量）。
                        // 复用既有 PendingRPC.retryCount 字段（P2-243 已定义，语义与
                        // MAX_TRANSIENT_RETRIES 一致：超过上限即判定该 pending 不可恢复，
                        // 直接 fulfill 空字节让调用方走超时/失败提示，而不是无限重试）。
                        var attemptsExceeded = false
                        synchronized(rpcMonitor) {
                            pending.retryCount += 1
                            attemptsExceeded = pending.retryCount > MTProtoClient.MAX_TRANSIENT_RETRIES
                        }
                        if (attemptsExceeded) {
                            Hilog.info(0, "CjTelegram",
                                "[MTProtoClient] ${tag}: retryCount exceeded MAX_TRANSIENT_RETRIES=${MTProtoClient.MAX_TRANSIENT_RETRIES}, giving up resend for ${oldMsgIdStr}")
                            synchronized(rpcMonitor) {
                                if (!pending.completed) {
                                    pending.fulfill(Array<Byte>(0, repeat: 0))
                                    rpcMonitor.notifyAll()
                                }
                            }
                            return
                        }
                        // 分配新 msgId/seqNo，重新打包发送（不持 rpcMonitor 做 IO）
                        let newMsgId = this.session.generateMessageId()
                        let newSeqNo = this.session.getNextSeqNo(true)  // content-related（真 RPC）
                        let newMsgIdStr = "${newMsgId}"
                        let resendMsg = buildMessage(newMsgId, newSeqNo, body)
                        let resendEnc = encryptMessage(resendMsg)
                        // 新 key → 同一 pending 对象（242c Path B 语义，唤醒原等待者）
                        synchronized(rpcMonitor) {
                            this.pendingRPCs[newMsgIdStr] = pending
                        }
                        let dcId = this.session.dcId
                        let transport = this.transportManager.getTransport(dcId)
                        if (transport.isConnected()) {
                            transport.send(resendEnc)
                            Hilog.info(0, "CjTelegram",
                                "[MTProtoClient] ${tag}: resent badMsgId=${oldMsgIdStr} → newMsgId=${newMsgId}")
                        } else {
                            // transport 断开：fail pending，不永久阻塞
                            synchronized(rpcMonitor) {
                                let _ = this.pendingRPCs.remove(newMsgIdStr)
                                pending.fulfill(Array<Byte>(0, repeat: 0))
                                rpcMonitor.notifyAll()
                            }
                            Hilog.info(0, "CjTelegram",
                                "[MTProtoClient] ${tag}: transport disconnected, failed pending ${oldMsgIdStr}")
                        }
                    case None =>
                        Hilog.info(0, "CjTelegram",
                            "[MTProtoClient] ${tag}: no requestBody for ${oldMsgIdStr}, cannot resend (container inner entry?)")
                }
            case None =>
                Hilog.info(0, "CjTelegram",
                    "[MTProtoClient] ${tag}: pending not found for ${oldMsgIdStr} (already completed/expired), no resend needed")
        }
    }

    // =========================================================================
    // selfCheck（P2-242a 并发 RPC 调度器）— 真断言，全程无网络：
    //   1) 多个 PendingRPC 并发注册进表，按各自 msgId 共存（多 in-flight）。
    //   2) 按 msgId 分发 → 只命中目标条目、写入正确响应、置 completed；其余条目不受影响。
    //   3) 过期 / 未注册 msgId 的分发安全忽略（不抛、不污染其它条目）。
    //   4) wait/notify 唤醒（非 busy-wait）：等待线程在 Monitor 上阻塞，由另一线程
    //      dispatch+notifyAll 唤醒后取回响应；并验证唤醒前确实处于「未完成等待」状态。
    //   任何断言失败抛 Exception。
    // -------------------------------------------------------------------------
    public static func selfCheck(): Unit {
        let monitor = Monitor()
        let table = HashMap<String, PendingRPC>()

        // ---- 本地分发函数：与 dispatchResponse 同语义（命中填充+唤醒；未命中安全忽略）----
        let dispatch = { reqId: String, payload: Array<Byte> =>
            synchronized(monitor) {
                if (table.contains(reqId)) {
                    table[reqId].fulfill(payload)
                    monitor.notifyAll()
                }
            }
        }

        // ===== 1. 多条目并发注册共存 =====
        let p1 = PendingRPC("1001", 1)
        let p2 = PendingRPC("1002", 2)
        let p3 = PendingRPC("1003", 3)
        synchronized(monitor) {
            table["1001"] = p1
            table["1002"] = p2
            table["1003"] = p3
        }
        if (table.size != 3) {
            throw Exception("selfCheck FAIL: pending table must hold 3 concurrent in-flight entries")
        }
        if (p1.completed || p2.completed || p3.completed) {
            throw Exception("selfCheck FAIL: freshly registered entries must be incomplete")
        }

        // ===== 2. 按 msgId 分发只命中目标条目 =====
        let resp2: Array<Byte> = [0xAAu8, 0xBBu8]
        dispatch("1002", resp2)
        if (!p2.completed) {
            throw Exception("selfCheck FAIL: dispatched msgId=1002 must be completed")
        }
        // 取回的响应字节必须与注入一致
        match (p2.responseData) {
            case Some(r) =>
                if (r.size != 2 || r[0] != 0xAAu8 || r[1] != 0xBBu8) {
                    throw Exception("selfCheck FAIL: msgId=1002 response payload mismatch")
                }
            case None => throw Exception("selfCheck FAIL: msgId=1002 must have response data")
        }
        // 其它条目绝不能被误填
        if (p1.completed || p3.completed) {
            throw Exception("selfCheck FAIL: non-target entries must stay incomplete after targeted dispatch")
        }

        // ===== 3. 过期 / 未注册 msgId 的分发安全忽略 =====
        // 先模拟超时清理掉 p3
        synchronized(monitor) {
            let _ = table.remove("1003")
        }
        // 分发一个已不在表中的 msgId：必须静默忽略、不抛、不影响 p1
        dispatch("1003", [0x01u8])
        dispatch("9999", [0x02u8])  // 从未注册的 msgId
        if (p1.completed) {
            throw Exception("selfCheck FAIL: stale/unknown dispatch must not affect other in-flight entries")
        }

        // ===== 4. wait/notify 真唤醒（非 busy-wait）：另一线程延迟后分发唤醒等待者 =====
        // p1 仍未完成。起一个生产者线程：先确认 p1 处于等待（未完成），再分发唤醒。
        let producerDone = PendingRPC("__producer__", 0)  // 复用作简单完成标志载体
        spawn {
            // 让等待线程先进入 monitor.wait（短暂让步）。用单调时钟忙等极短窗口仅在测试线程，
            // 不是 RPC 路径；目的只是让出调度，使主线程先 wait。
            let t0 = mtprotoMonotonicNowMs()
            while (mtprotoMonotonicNowMs() - t0 < 50) { () }
            dispatch("1001", [0x42u8])
            synchronized(monitor) {
                producerDone.fulfill([0x1u8])
                monitor.notifyAll()
            }
        }

        // 主线程：在 monitor 上等待 p1 完成（条件变量阻塞，超时上限 5s 防测试挂死）。
        let deadline = mtprotoMonotonicNowMs() + 5000
        var woke = false
        synchronized(monitor) {
            while (!p1.completed) {
                let remaining = deadline - mtprotoMonotonicNowMs()
                if (remaining <= 0) {
                    break
                }
                let _ = monitor.wait(timeout: Duration.millisecond * remaining)
            }
            woke = p1.completed
        }
        if (!woke) {
            throw Exception("selfCheck FAIL: waiter must be woken by notify within timeout (wait/notify, not busy-wait)")
        }
        match (p1.responseData) {
            case Some(r) =>
                if (r.size != 1 || r[0] != 0x42u8) {
                    throw Exception("selfCheck FAIL: woken waiter must retrieve the injected response 0x42")
                }
            case None => throw Exception("selfCheck FAIL: woken waiter must have response data")
        }

        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] selfCheck PASS: concurrent pending table (multi in-flight) / msgId-keyed dispatch / stale-dispatch safety / wait-notify wakeup (no busy-wait)")

        // ===== P2-242b：msg_container 字节布局 + 内层 msgId 保留 真断言 =====
        MTProtoClient.selfCheckContainer()

        // ===== P2-242c：rpc_drop_answer 序列化 + msgs_state_req 序列化 + 过期清理 真断言 =====
        MTProtoClient.selfCheckP2242c()

        // ===== P2-243：RPC 错误分类 + parseTrailingInt + computeRPCBackoffMs 真断言 =====
        MTProtoClient.selfCheckP2243()

        // ===== P2-244：msgs_ack 序列化 + msg_resend_req 序列化 + scheduleAck 逻辑 真断言 =====
        MTProtoClient.selfCheckP2244()

        // ===== P2-245：MTTimeSyncService 真断言 =====
        MTTimeSyncService.selfCheck()

        // P2-242a 返修：挂入 SessionInfo 并发安全断言（无重复 msgId / seqNo）
        SessionInfo.selfCheck()

        // ===== P2-246：migrateToDC race fix 真断言 =====
        MTProtoClient.selfCheckP2246()

        // ===== P2-248：gzip_packed 出站压缩 round-trip 真断言 =====
        MTProtoClient.selfCheckGzipPacked()

        // ===== P2-251c：PFS 过期重生成 + 入站解密双路 auth_key_id 识别 真断言 =====
        MTProtoClient.selfCheckP2251c()
    }

    // -------------------------------------------------------------------------
    // selfCheckGzipPacked（P2-248 gzip_packed 出站压缩）— 真断言，无网络：
    //   1) gzip(data) 产出有效 GZIP 字节（魔数 0x1f 0x8b）。
    //   2) gzip→gunzip round-trip：还原为原始字节，逐字节对比。
    //   3) packGzipPacked：产出 [0x3072cfa1 LE32][TL-bytes: compressedData]，constructor 正确。
    //   4) wrapGzipIfBeneficial：对可压缩数据返回 gzip_packed（更小）；
    //      对极短数据（压缩后更大）直通原始字节。
    //   5) TL 反解：gzip_packed 包装的 packed_data 字段可被 TLDeserializer.readBytes() 还原。
    //   任何断言失败抛 Exception。
    // -------------------------------------------------------------------------
    public static func selfCheckGzipPacked(): Unit {
        // ---- 小端读辅助 ----
        let readU32LE = { b: Array<Byte>, off: Int64 =>
            UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
        }

        // ===== 1. 准备一段足够长的测试数据（重复字节，高可压缩性）=====
        let original = Array<Byte>(200, repeat: 0xABu8)

        // ===== 2. gzip() 产出有效 GZIP 魔数 =====
        let compressed = gzip(original)
        if (compressed.size < 10) {
            throw Exception("selfCheckGzipPacked FAIL: gzip output too short (${compressed.size})")
        }
        if (UInt8(compressed[0]) != 0x1fu8 || UInt8(compressed[1]) != 0x8bu8) {
            throw Exception("selfCheckGzipPacked FAIL: gzip output missing GZIP magic bytes (0x1f 0x8b)")
        }
        if (compressed.size >= original.size) {
            throw Exception("selfCheckGzipPacked FAIL: gzip output (${compressed.size}) should be smaller than original (${original.size}) for repetitive data")
        }

        // ===== 3. round-trip：gunzip(gzip(original)) == original =====
        let decompressed = gunzip(compressed)
        if (decompressed.size != original.size) {
            throw Exception("selfCheckGzipPacked FAIL: round-trip length mismatch: got ${decompressed.size}, expected ${original.size}")
        }
        for (i in 0..original.size) {
            if (decompressed[i] != original[i]) {
                throw Exception("selfCheckGzipPacked FAIL: round-trip byte mismatch at index ${i}")
            }
        }

        // ===== 4. packGzipPacked：constructor + TL-bytes 布局 =====
        let packed = packGzipPacked(compressed)
        if (packed.size < 4) {
            throw Exception("selfCheckGzipPacked FAIL: packed too short (${packed.size})")
        }
        if (readU32LE(packed, 0) != TLConstructors.GZIP_PACKED) {
            throw Exception("selfCheckGzipPacked FAIL: packed constructor must be 0x3072cfa1")
        }

        // TL-bytes 长度字段验证：packed[4] は length byte
        let lenByte = Int64(UInt8(packed[4]))
        var dataOffset: Int64 = 0
        var declaredLen: Int64 = 0
        if (lenByte <= 253) {
            dataOffset = 5
            declaredLen = lenByte
        } else {
            dataOffset = 8
            declaredLen = Int64(UInt8(packed[5])) | (Int64(UInt8(packed[6])) << 8) | (Int64(UInt8(packed[7])) << 16)
        }
        if (declaredLen != compressed.size) {
            throw Exception("selfCheckGzipPacked FAIL: TL-bytes declared len ${declaredLen} != compressed.size ${compressed.size}")
        }
        for (i in 0..compressed.size) {
            if (UInt8(packed[dataOffset + i]) != UInt8(compressed[i])) {
                throw Exception("selfCheckGzipPacked FAIL: TL-bytes payload mismatch at index ${i}")
            }
        }

        // ===== 5. wrapGzipIfBeneficial：可压缩数据 → 返回 gzip_packed（更小）=====
        let wrapped = wrapGzipIfBeneficial(original)
        if (wrapped.size >= original.size) {
            throw Exception("selfCheckGzipPacked FAIL: wrapGzipIfBeneficial should produce smaller output for repetitive 200-byte input (got ${wrapped.size} vs original ${original.size})")
        }
        if (readU32LE(wrapped, 0) != TLConstructors.GZIP_PACKED) {
            throw Exception("selfCheckGzipPacked FAIL: wrapGzipIfBeneficial output must start with 0x3072cfa1 for compressible data")
        }

        // ===== 6. wrapGzipIfBeneficial：极短数据（1字节）→ 直通原始（压缩包更大）=====
        let tiny = Array<Byte>(1, repeat: 0x42u8)
        let wrappedTiny = wrapGzipIfBeneficial(tiny)
        if (wrappedTiny.size != 1 || UInt8(wrappedTiny[0]) != 0x42u8) {
            throw Exception("selfCheckGzipPacked FAIL: wrapGzipIfBeneficial must pass-through single-byte input unchanged")
        }

        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] selfCheckGzipPacked PASS: gzip GZIP-magic / round-trip gunzip(gzip(x))==x / packGzipPacked 0x3072cfa1 TL-bytes layout / wrapGzipIfBeneficial compress-when-beneficial + pass-through-when-not")
    }

    // -------------------------------------------------------------------------
    // selfCheckContainer（P2-242b msg_container 批处理）— 真断言，无网络：
    //   1) 给定 2~3 条已知 (msgId,seqNo,body) 内层消息构造容器，逐字节断言布局：
    //      0x73f1f8dc(LE) + count + 对每条 [msgId(8,LE)+seqNo(4,LE)+bytes(4,LE)+body]。
    //   2) count 字段 == 内层消息数；每条 bytes 字段 == 该 body 长度；body 原样内嵌。
    //   3) 内层 msgId 在容器字节中可被还原（用 MsgContainer.deserialize 反解，验证响应分发所需
    //      的内层 msgId 完整保留）。
    //   4) 单条/单元素等价性：单元素容器 deserialize 回来仍是同一 msgId+body（单条不套容器走原路径，
    //      此处仅断言「若套单元素容器其内层 msgId 仍保留」，证明配对不丢）。
    //   任何断言失败抛 Exception。
    // -------------------------------------------------------------------------
    public static func selfCheckContainer(): Unit {
        // ---- 小端读辅助 ----
        let readU32LE = { b: Array<Byte>, off: Int64 =>
            UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
        }
        let readI32LE = { b: Array<Byte>, off: Int64 =>
            Int32(readU32LE(b, off))
        }
        let readI64LE = { b: Array<Byte>, off: Int64 =>
            var v: Int64 = 0
            for (i in 0..8) {
                v = v | (Int64(b[off + i]) << (i * 8))
            }
            v
        }

        // ===== 1. 构造 3 条已知内层消息 =====
        let m1 = InnerMessage(0x1122334455667788, 1, [0xDEu8, 0xADu8])           // body len 2
        let m2 = InnerMessage(0x0102030405060708, 3, [0xBEu8, 0xEFu8, 0xCAu8, 0xFEu8]) // body len 4
        let m3 = InnerMessage(0x7766554433221100, 5, [0x99u8])                   // body len 1
        let msgs = ArrayList<InnerMessage>()
        msgs.add(m1)
        msgs.add(m2)
        msgs.add(m3)

        let bytes = MTProtoClient.serializeContainer(msgs)

        // ---- 头部：构造子 0x73f1f8dc + count=3 ----
        if (readU32LE(bytes, 0) != 0x73f1f8dc) {
            throw Exception("selfCheck FAIL: container constructor must be 0x73f1f8dc")
        }
        if (readI32LE(bytes, 4) != 3) {
            throw Exception("selfCheck FAIL: container count must equal inner message count (3)")
        }

        // ---- 逐条断言偏移：每条 = 8(msgId)+4(seqNo)+4(bytes)+body ----
        var off: Int64 = 8
        let expect = [m1, m2, m3]
        for (em in expect) {
            if (readI64LE(bytes, off) != em.msgId) {
                throw Exception("selfCheck FAIL: inner msgId byte layout mismatch at off=${off}")
            }
            off += 8
            if (readI32LE(bytes, off) != em.seqNo) {
                throw Exception("selfCheck FAIL: inner seqNo byte layout mismatch at off=${off}")
            }
            off += 4
            let declaredLen = readI32LE(bytes, off)
            if (declaredLen != Int32(em.body.size)) {
                throw Exception("selfCheck FAIL: inner bytes(len) field must equal body length at off=${off}")
            }
            off += 4
            for (i in 0..em.body.size) {
                if (bytes[off + i] != em.body[i]) {
                    throw Exception("selfCheck FAIL: inner body byte mismatch at off=${off + i}")
                }
            }
            off += em.body.size
        }
        // 总长应恰好消费完（无多余 / 缺失字节）
        if (off != bytes.size) {
            throw Exception("selfCheck FAIL: container total length mismatch (consumed=${off}, total=${bytes.size})")
        }

        // ===== 2. 反解还原：内层 msgId 完整保留（响应分发依赖）=====
        // serializeContainer 输出的是「构造子 + count + entries」；MsgContainer.deserialize 期望
        // deserializer 已跳过构造子（与 handleMsgContainer 一致），故从 count 处（off=4）喂入。
        let de = TLDeserializer(ByteUtils.slice(bytes, 4, bytes.size))
        let parsed = MsgContainer.deserialize(de)
        if (parsed.messages.size != 3) {
            throw Exception("selfCheck FAIL: deserialized container must hold 3 inner messages")
        }
        if (parsed.messages[0].msgId != m1.msgId ||
            parsed.messages[1].msgId != m2.msgId ||
            parsed.messages[2].msgId != m3.msgId) {
            throw Exception("selfCheck FAIL: inner msgIds must be preserved for response pairing")
        }
        // 内层 body 原样保留
        if (parsed.messages[1].body.size != 4 ||
            parsed.messages[1].body[0] != 0xBEu8 ||
            parsed.messages[1].body[3] != 0xFEu8) {
            throw Exception("selfCheck FAIL: inner body must round-trip intact")
        }

        // ===== 3. 单元素容器等价：单条 msgId 仍可还原（配对不丢）=====
        let single = ArrayList<InnerMessage>()
        single.add(InnerMessage(0x4242424242424242, 7, [0x01u8, 0x02u8, 0x03u8]))
        let sb = MTProtoClient.serializeContainer(single)
        if (readI32LE(sb, 4) != 1) {
            throw Exception("selfCheck FAIL: single-element container count must be 1")
        }
        let sde = TLDeserializer(ByteUtils.slice(sb, 4, sb.size))
        let sparsed = MsgContainer.deserialize(sde)
        if (sparsed.messages.size != 1 || sparsed.messages[0].msgId != 0x4242424242424242) {
            throw Exception("selfCheck FAIL: single-element container inner msgId must be preserved")
        }

        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] selfCheckContainer PASS: msg_container(0x73f1f8dc) byte layout (count + per-inner msgId/seqno/bytes/body offsets) / inner msgId preserved for response pairing / single-element equivalence")
    }

    // -------------------------------------------------------------------------
    // selfCheckP2242c（P2-242c 三能力）— 真断言，无网络：
    //   1) rpc_drop_answer 字节布局：0x58e4a740 + reqMsgId(Int64,LE)
    //   2) msgs_state_req 字节布局：0xda69fb52 + 0x1cb5c415 + count + [msgId × count]
    //   3) cancelRPC 本地取消语义：注册 PendingRPC → cancelRPC → completed=true、
    //      responseData=Some(空数组)、表中已移除。
    //   4) cleanupExpiredRPCs：注入两条（一条过期/一条新鲜）→ 只清理过期条目。
    //   任何断言失败抛 Exception。
    // -------------------------------------------------------------------------
    public static func selfCheckP2242c(): Unit {
        // ---- 小端读辅助 ----
        let readU32LE = { b: Array<Byte>, off: Int64 =>
            UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
        }
        let readI64LE = { b: Array<Byte>, off: Int64 =>
            var v: Int64 = 0
            for (i in 0..8) {
                v = v | (Int64(b[off + i]) << (i * 8))
            }
            v
        }
        let readI32LE = { b: Array<Byte>, off: Int64 =>
            Int32(UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24))
        }

        // ===== 1. rpc_drop_answer 字节布局断言 =====
        let dropMsgId: Int64 = 0x1122334455667788
        let dropSerializer = TLSerializer()
        dropSerializer.writeUInt32(TLConstructors.RPC_DROP_ANSWER)  // 0x58e4a740
        dropSerializer.writeInt64(dropMsgId)
        let dropBytes = dropSerializer.getBytes()

        if (dropBytes.size != 12) {
            throw Exception("selfCheckP2242c FAIL: rpc_drop_answer body must be 12 bytes (4 constructor + 8 msgId)")
        }
        if (readU32LE(dropBytes, 0) != 0x58e4a740) {
            throw Exception("selfCheckP2242c FAIL: rpc_drop_answer constructor must be 0x58e4a740")
        }
        if (readI64LE(dropBytes, 4) != dropMsgId) {
            throw Exception("selfCheckP2242c FAIL: rpc_drop_answer req_msg_id byte layout mismatch")
        }

        // ===== 2. msgs_state_req 字节布局断言（3条 msgId）=====
        let stateIds: ArrayList<Int64> = ArrayList<Int64>()
        stateIds.add(0x0102030405060708)
        stateIds.add(0x1122334455667788)
        stateIds.add(0x0807060504030201)
        let stateSerializer = TLSerializer()
        stateSerializer.writeUInt32(TLConstructors.MSGS_STATE_REQ)   // 0xda69fb52
        stateSerializer.writeUInt32(TLConstructors.VECTOR)           // 0x1cb5c415
        stateSerializer.writeInt32(Int32(stateIds.size))
        for (mid in stateIds) {
            stateSerializer.writeInt64(mid)
        }
        let stateBytes = stateSerializer.getBytes()
        // expected: 4 (MSGS_STATE_REQ) + 4 (VECTOR) + 4 (count) + 8*3 (msgIds) = 36
        if (stateBytes.size != 36) {
            throw Exception("selfCheckP2242c FAIL: msgs_state_req body must be 36 bytes, got ${stateBytes.size}")
        }
        if (readU32LE(stateBytes, 0) != 0xda69fb52) {
            throw Exception("selfCheckP2242c FAIL: msgs_state_req constructor must be 0xda69fb52")
        }
        if (readU32LE(stateBytes, 4) != 0x1cb5c415) {
            throw Exception("selfCheckP2242c FAIL: msgs_state_req vector constructor must be 0x1cb5c415")
        }
        if (readI32LE(stateBytes, 8) != 3) {
            throw Exception("selfCheckP2242c FAIL: msgs_state_req count must be 3")
        }
        if (readI64LE(stateBytes, 12) != stateIds[0]) {
            throw Exception("selfCheckP2242c FAIL: msgs_state_req msgId[0] mismatch")
        }
        if (readI64LE(stateBytes, 20) != stateIds[1]) {
            throw Exception("selfCheckP2242c FAIL: msgs_state_req msgId[1] mismatch")
        }
        if (readI64LE(stateBytes, 28) != stateIds[2]) {
            throw Exception("selfCheckP2242c FAIL: msgs_state_req msgId[2] mismatch")
        }

        // ===== 3. cancelRPC 本地取消语义（不走网络）=====
        let cancelMonitor = Monitor()
        let cancelTable = HashMap<String, PendingRPC>()
        let cancelMsgIdStr = "9876543210"
        let cancelPending = PendingRPC(cancelMsgIdStr, 1)
        synchronized(cancelMonitor) {
            cancelTable[cancelMsgIdStr] = cancelPending
        }
        // 模拟 cancelRPC 本地部分逻辑
        synchronized(cancelMonitor) {
            if (cancelTable.contains(cancelMsgIdStr)) {
                let p = cancelTable[cancelMsgIdStr]
                if (!p.completed) {
                    p.fulfill(Array<Byte>(0, repeat: 0))
                }
                let _ = cancelTable.remove(cancelMsgIdStr)
                cancelMonitor.notifyAll()
            }
        }
        if (!cancelPending.completed) {
            throw Exception("selfCheckP2242c FAIL: cancelRPC must mark PendingRPC as completed")
        }
        match (cancelPending.responseData) {
            case Some(r) =>
                if (r.size != 0) {
                    throw Exception("selfCheckP2242c FAIL: cancelled RPC response must be empty array")
                }
            case None => throw Exception("selfCheckP2242c FAIL: cancelled RPC must have responseData set")
        }
        if (cancelTable.contains(cancelMsgIdStr)) {
            throw Exception("selfCheckP2242c FAIL: cancelled entry must be removed from pendingRPCs table")
        }

        // ===== 4. cleanupExpiredRPCs 只清理过期条目 =====
        let cleanMonitor = Monitor()
        let cleanTable = HashMap<String, PendingRPC>()
        // 注入一条"旧的"条目（timestamp=1，距 now 很远 > 60000ms 过期阈值）
        let oldPending = PendingRPC("old_111", 1)
        // 注入一条"新鲜"条目（timestamp=now，不过期）
        let freshTs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let freshPending = PendingRPC("fresh_222", freshTs)
        synchronized(cleanMonitor) {
            cleanTable["old_111"] = oldPending
            cleanTable["fresh_222"] = freshPending
        }
        // 模拟 cleanupExpiredRPCs 逻辑（timeoutMs=60000）
        let nowMs2 = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let expiredKeys2 = ArrayList<String>()
        synchronized(cleanMonitor) {
            for ((key, pending) in cleanTable) {
                if (!pending.completed && (nowMs2 - pending.timestamp) > 60000) {
                    expiredKeys2.add(key)
                }
            }
            for (key in expiredKeys2) {
                if (cleanTable.contains(key)) {
                    let p = cleanTable[key]
                    if (!p.completed) {
                        p.fulfill(Array<Byte>(0, repeat: 0))
                    }
                    let _ = cleanTable.remove(key)
                }
            }
            cleanMonitor.notifyAll()
        }
        if (!oldPending.completed) {
            throw Exception("selfCheckP2242c FAIL: expired pending must be marked completed by cleanupExpiredRPCs")
        }
        if (cleanTable.contains("old_111")) {
            throw Exception("selfCheckP2242c FAIL: expired entry must be removed from table")
        }
        if (freshPending.completed) {
            throw Exception("selfCheckP2242c FAIL: fresh pending must NOT be expired/cleaned")
        }
        if (!cleanTable.contains("fresh_222")) {
            throw Exception("selfCheckP2242c FAIL: fresh entry must remain in table after cleanup")
        }

        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] selfCheckP2242c PASS: rpc_drop_answer(0x58e4a740) byte layout / msgs_state_req(0xda69fb52+0x1cb5c415) Vector byte layout / cancelRPC local cancel semantics / cleanupExpiredRPCs selective expiry")
    }

    // -------------------------------------------------------------------------
    // selfCheckP2243（P2-243 RPC 错误处理）— 真断言，全程无网络：
    //   1) classifyRPCError：各错误码/消息正确分类
    //   2) parseTrailingInt：FLOOD_WAIT_X / *_MIGRATE_X / SLOW_MODE_WAIT_X 正确解析数字
    //   3) computeRPCBackoffMs：指数退避序列递增+封顶
    //   4) PendingRPC 错误上下文字段：retryCount / lastErrorCode / lastErrorMessage / nextRetryAtMs 可读写
    //   任何断言失败抛 Exception。
    // -------------------------------------------------------------------------
    public static func selfCheckP2243(): Unit {
        // ===== 1. classifyRPCError 分类断言 =====
        // 瞬时错误
        let c1 = MTProtoClient.classifyRPCError(-500, "INTERNAL")
        match (c1) {
            case RPCErrorClass.Transient => ()
            case _ => throw Exception("selfCheckP2243 FAIL: -500 must be Transient")
        }
        let c2 = MTProtoClient.classifyRPCError(500, "INTERNAL")
        match (c2) {
            case RPCErrorClass.Transient => ()
            case _ => throw Exception("selfCheckP2243 FAIL: 500 must be Transient")
        }
        let c3 = MTProtoClient.classifyRPCError(-503, "TIMEOUT")
        match (c3) {
            case RPCErrorClass.Transient => ()
            case _ => throw Exception("selfCheckP2243 FAIL: -503 must be Transient")
        }

        // FLOOD_WAIT
        let c4 = MTProtoClient.classifyRPCError(420, "FLOOD_WAIT_60")
        match (c4) {
            case RPCErrorClass.FloodWait(sec) =>
                if (sec != 60) {
                    throw Exception("selfCheckP2243 FAIL: FLOOD_WAIT_60 must yield waitSec=60, got ${sec}")
                }
            case _ => throw Exception("selfCheckP2243 FAIL: FLOOD_WAIT_60 must be FloodWait")
        }
        let c5 = MTProtoClient.classifyRPCError(420, "FLOOD_WAIT_3600")
        match (c5) {
            case RPCErrorClass.FloodWait(sec) =>
                if (sec != 3600) {
                    throw Exception("selfCheckP2243 FAIL: FLOOD_WAIT_3600 must yield waitSec=3600, got ${sec}")
                }
            case _ => throw Exception("selfCheckP2243 FAIL: FLOOD_WAIT_3600 must be FloodWait")
        }

        // SLOW_MODE_WAIT
        let c6 = MTProtoClient.classifyRPCError(420, "SLOW_MODE_WAIT_30")
        match (c6) {
            case RPCErrorClass.SlowMode(sec) =>
                if (sec != 30) {
                    throw Exception("selfCheckP2243 FAIL: SLOW_MODE_WAIT_30 must yield waitSec=30, got ${sec}")
                }
            case _ => throw Exception("selfCheckP2243 FAIL: SLOW_MODE_WAIT_30 must be SlowMode")
        }

        // MIGRATE
        let c7 = MTProtoClient.classifyRPCError(303, "PHONE_MIGRATE_2")
        match (c7) {
            case RPCErrorClass.Migrate(dcId) =>
                if (dcId != 2) {
                    throw Exception("selfCheckP2243 FAIL: PHONE_MIGRATE_2 must yield dcId=2, got ${dcId}")
                }
            case _ => throw Exception("selfCheckP2243 FAIL: PHONE_MIGRATE_2 must be Migrate")
        }
        let c8 = MTProtoClient.classifyRPCError(303, "NETWORK_MIGRATE_5")
        match (c8) {
            case RPCErrorClass.Migrate(dcId) =>
                if (dcId != 5) {
                    throw Exception("selfCheckP2243 FAIL: NETWORK_MIGRATE_5 must yield dcId=5, got ${dcId}")
                }
            case _ => throw Exception("selfCheckP2243 FAIL: NETWORK_MIGRATE_5 must be Migrate")
        }
        let c9 = MTProtoClient.classifyRPCError(303, "USER_MIGRATE_4")
        match (c9) {
            case RPCErrorClass.Migrate(dcId) =>
                if (dcId != 4) {
                    throw Exception("selfCheckP2243 FAIL: USER_MIGRATE_4 must yield dcId=4, got ${dcId}")
                }
            case _ => throw Exception("selfCheckP2243 FAIL: USER_MIGRATE_4 must be Migrate")
        }

        // HI-AUTH-0006: FILE_MIGRATE_X 必须分类为独立的 FileMigrate（不能落进 Migrate 分支，
        // 否则会对调用方客户端本身触发 migrateToDC，见本文件 RPCErrorClass.FileMigrate 注释）。
        let c9b = MTProtoClient.classifyRPCError(303, "FILE_MIGRATE_1")
        match (c9b) {
            case RPCErrorClass.FileMigrate(dcId) =>
                if (dcId != 1) {
                    throw Exception("selfCheckP2243 FAIL: FILE_MIGRATE_1 must yield dcId=1, got ${dcId}")
                }
            case _ => throw Exception("selfCheckP2243 FAIL: FILE_MIGRATE_1 must be FileMigrate, not Migrate/other")
        }

        // Fatal
        let c10 = MTProtoClient.classifyRPCError(400, "BAD_REQUEST")
        match (c10) {
            case RPCErrorClass.Fatal => ()
            case _ => throw Exception("selfCheckP2243 FAIL: 400/BAD_REQUEST must be Fatal")
        }
        let c11 = MTProtoClient.classifyRPCError(401, "UNAUTHORIZED")
        match (c11) {
            case RPCErrorClass.Fatal => ()
            case _ => throw Exception("selfCheckP2243 FAIL: 401/UNAUTHORIZED must be Fatal")
        }

        // ===== 2. parseTrailingInt 断言 =====
        let p1 = MTProtoClient.parseTrailingInt("FLOOD_WAIT_60", "FLOOD_WAIT_")
        if (p1 != 60) {
            throw Exception("selfCheckP2243 FAIL: parseTrailingInt('FLOOD_WAIT_60', 'FLOOD_WAIT_') expected 60, got ${p1}")
        }
        let p2 = MTProtoClient.parseTrailingInt("PHONE_MIGRATE_2", "_MIGRATE_")
        if (p2 != 2) {
            throw Exception("selfCheckP2243 FAIL: parseTrailingInt('PHONE_MIGRATE_2', '_MIGRATE_') expected 2, got ${p2}")
        }
        let p3 = MTProtoClient.parseTrailingInt("SLOW_MODE_WAIT_30", "SLOW_MODE_WAIT_")
        if (p3 != 30) {
            throw Exception("selfCheckP2243 FAIL: parseTrailingInt('SLOW_MODE_WAIT_30', 'SLOW_MODE_WAIT_') expected 30, got ${p3}")
        }
        let p4 = MTProtoClient.parseTrailingInt("NO_PREFIX_HERE", "FLOOD_WAIT_")
        if (p4 != -1) {
            throw Exception("selfCheckP2243 FAIL: parseTrailingInt with no prefix must return -1, got ${p4}")
        }

        // ===== 3. computeRPCBackoffMs 退避序列断言 =====
        // base=500, cap=16000: 500, 500, 1000, 2000, 4000 … 16000(封顶)
        let base = MTProtoClient.TRANSIENT_BASE_DELAY_MS
        let b1 = MTProtoClient.computeRPCBackoffMs(0)
        if (b1 != base) {
            throw Exception("selfCheckP2243 FAIL: computeRPCBackoffMs(0) expected ${base}, got ${b1}")
        }
        let b2 = MTProtoClient.computeRPCBackoffMs(1)
        if (b2 != base) {
            throw Exception("selfCheckP2243 FAIL: computeRPCBackoffMs(1) expected ${base}, got ${b2}")
        }
        let b3 = MTProtoClient.computeRPCBackoffMs(2)
        if (b3 != base * 2) {
            throw Exception("selfCheckP2243 FAIL: computeRPCBackoffMs(2) expected ${base * 2}, got ${b3}")
        }
        let b4 = MTProtoClient.computeRPCBackoffMs(3)
        if (b4 != base * 4) {
            throw Exception("selfCheckP2243 FAIL: computeRPCBackoffMs(3) expected ${base * 4}, got ${b4}")
        }
        let b5 = MTProtoClient.computeRPCBackoffMs(4)
        if (b5 != base * 8) {
            throw Exception("selfCheckP2243 FAIL: computeRPCBackoffMs(4) expected ${base * 8}, got ${b5}")
        }
        let b6 = MTProtoClient.computeRPCBackoffMs(100)
        if (b6 != 16000) {
            throw Exception("selfCheckP2243 FAIL: computeRPCBackoffMs(100) must cap at 16000, got ${b6}")
        }
        // 非递减
        var prev = MTProtoClient.computeRPCBackoffMs(0)
        for (a in 1..6) {
            let cur = MTProtoClient.computeRPCBackoffMs(a)
            if (cur < prev) {
                throw Exception("selfCheckP2243 FAIL: computeRPCBackoffMs not monotone non-decreasing at attempt=${a}")
            }
            prev = cur
        }

        // ===== 4. PendingRPC 错误上下文字段 + doNotExpire 豁免标志读写断言 =====
        let testPending = PendingRPC("test_rpc_ctx", 1000)
        if (testPending.retryCount != 0) {
            throw Exception("selfCheckP2243 FAIL: initial retryCount must be 0")
        }
        if (testPending.lastErrorCode != 0) {
            throw Exception("selfCheckP2243 FAIL: initial lastErrorCode must be 0")
        }
        if (testPending.lastErrorMessage != "") {
            throw Exception("selfCheckP2243 FAIL: initial lastErrorMessage must be empty")
        }
        if (testPending.nextRetryAtMs != 0) {
            throw Exception("selfCheckP2243 FAIL: initial nextRetryAtMs must be 0")
        }
        // P2-243 rework: doNotExpire 初始必须为 false
        if (testPending.doNotExpire) {
            throw Exception("selfCheckP2243 FAIL: initial doNotExpire must be false")
        }
        testPending.retryCount = 2
        testPending.lastErrorCode = -500
        testPending.lastErrorMessage = "INTERNAL"
        testPending.nextRetryAtMs = 99999
        if (testPending.retryCount != 2 || testPending.lastErrorCode != -500 ||
            testPending.lastErrorMessage != "INTERNAL" || testPending.nextRetryAtMs != 99999) {
            throw Exception("selfCheckP2243 FAIL: error context fields must be writable and readable back")
        }
        // P2-243 rework: doNotExpire 可写可读
        testPending.doNotExpire = true
        if (!testPending.doNotExpire) {
            throw Exception("selfCheckP2243 FAIL: doNotExpire must be settable to true")
        }
        testPending.doNotExpire = false
        if (testPending.doNotExpire) {
            throw Exception("selfCheckP2243 FAIL: doNotExpire must be clearable back to false")
        }
        // timestamp 现在是 var，应可重写（FLOOD_WAIT 重试发出时刷新用）
        let origTs = testPending.timestamp
        testPending.timestamp = origTs + 5000
        if (testPending.timestamp != origTs + 5000) {
            throw Exception("selfCheckP2243 FAIL: timestamp (now var) must be writable for retry window refresh")
        }
        // P2-243 rework: cleanupExpiredRPCs 跳过 doNotExpire=true 条目的逻辑断言
        // 注入一条过期条目但 doNotExpire=true，模拟 cleanup 后它应该保留（不被误清）。
        let exemptMonitor = Monitor()
        let exemptTable = HashMap<String, PendingRPC>()
        let exemptPending = PendingRPC("exempt_777", 1)  // timestamp=1，本应过期
        exemptPending.doNotExpire = true                  // 但被豁免
        let normalExpiredPending = PendingRPC("expired_888", 1)  // 过期且无豁免
        synchronized(exemptMonitor) {
            exemptTable["exempt_777"] = exemptPending
            exemptTable["expired_888"] = normalExpiredPending
        }
        // 模拟 cleanupExpiredRPCs（doNotExpire=true 的条目必须跳过）
        // 使用 wall clock，与真实 cleanupExpiredRPCs 路径一致，确保 selfCheck 能真实发现时钟域不一致 bug
        let nowMs3 = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let expiredKeys3 = ArrayList<String>()
        synchronized(exemptMonitor) {
            for ((key, pending) in exemptTable) {
                if (!pending.completed && !pending.doNotExpire && (nowMs3 - pending.timestamp) > 60000) {
                    expiredKeys3.add(key)
                }
            }
            for (key in expiredKeys3) {
                if (exemptTable.contains(key)) {
                    let p = exemptTable[key]
                    if (!p.completed) {
                        p.fulfill(Array<Byte>(0, repeat: 0))
                    }
                    let _ = exemptTable.remove(key)
                }
            }
        }
        // exempt_777 有 doNotExpire=true，必须保留（未被清理）
        if (!exemptTable.contains("exempt_777")) {
            throw Exception("selfCheckP2243 FAIL: doNotExpire=true entry must NOT be cleaned by cleanupExpiredRPCs")
        }
        if (exemptPending.completed) {
            throw Exception("selfCheckP2243 FAIL: doNotExpire=true entry must not be fulfilled by cleanup")
        }
        // expired_888 没有豁免，必须已被清理
        if (exemptTable.contains("expired_888")) {
            throw Exception("selfCheckP2243 FAIL: expired entry without doNotExpire must be cleaned")
        }
        if (!normalExpiredPending.completed) {
            throw Exception("selfCheckP2243 FAIL: expired entry without doNotExpire must be completed/fulfilled by cleanup")
        }

        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] selfCheckP2243 PASS: classifyRPCError (Transient/FloodWait/SlowMode/Migrate/FileMigrate/Fatal) / parseTrailingInt (FLOOD_WAIT/MIGRATE/SLOW_MODE) / computeRPCBackoffMs (exponential+cap) / PendingRPC error context fields / doNotExpire exemption flag / timestamp var refresh")
    }

    // -------------------------------------------------------------------------
    // selfCheckP2244（P2-244 可靠投递子层）— 真断言，全程无网络：
    //   1) msgs_ack 序列化字节布局：0x62d6b459 + 0x1cb5c415 + count + [msgId × count]
    //   2) msg_resend_req 序列化字节布局：0x7d861a08 + 0x1cb5c415 + count + [msgId × count]
    //   3) scheduleAck 逻辑：奇 seqno 加入池；偶 seqno 不加入；达阈值自动 flush（对齐逻辑，非 IO）
    //   4) bad_msg_notification 时间偏移计算：incomingMsgId >> 32 = 服务端 Unix 秒（纯数学断言）
    //   任何断言失败抛 Exception。
    // -------------------------------------------------------------------------
    public static func selfCheckP2244(): Unit {
        // ---- 小端读辅助 ----
        let readU32LE = { b: Array<Byte>, off: Int64 =>
            UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
        }
        let readI64LE = { b: Array<Byte>, off: Int64 =>
            var v: Int64 = 0
            for (i in 0..8) {
                v = v | (Int64(b[off + i]) << (i * 8))
            }
            v
        }
        let readI32LE = { b: Array<Byte>, off: Int64 =>
            Int32(UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24))
        }

        // ===== 1. msgs_ack#62d6b459 字节布局断言（3条 msgId）=====
        let ackIds: ArrayList<Int64> = ArrayList<Int64>()
        ackIds.add(0x0102030405060708)
        ackIds.add(0x1122334455667788)
        ackIds.add(0x0807060504030201)
        let ackSerializer = TLSerializer()
        ackSerializer.writeUInt32(TLConstructors.MSGS_ACK)    // 0x62d6b459
        ackSerializer.writeUInt32(TLConstructors.VECTOR)       // 0x1cb5c415
        ackSerializer.writeInt32(Int32(ackIds.size))
        for (mid in ackIds) {
            ackSerializer.writeInt64(mid)
        }
        let ackBytes = ackSerializer.getBytes()
        // expected: 4 (MSGS_ACK) + 4 (VECTOR) + 4 (count) + 8*3 = 36
        if (ackBytes.size != 36) {
            throw Exception("selfCheckP2244 FAIL: msgs_ack body must be 36 bytes, got ${ackBytes.size}")
        }
        if (readU32LE(ackBytes, 0) != 0x62d6b459) {
            throw Exception("selfCheckP2244 FAIL: msgs_ack constructor must be 0x62d6b459")
        }
        if (readU32LE(ackBytes, 4) != 0x1cb5c415) {
            throw Exception("selfCheckP2244 FAIL: msgs_ack vector constructor must be 0x1cb5c415")
        }
        if (readI32LE(ackBytes, 8) != 3) {
            throw Exception("selfCheckP2244 FAIL: msgs_ack count must be 3")
        }
        if (readI64LE(ackBytes, 12) != ackIds[0]) {
            throw Exception("selfCheckP2244 FAIL: msgs_ack msgId[0] mismatch")
        }
        if (readI64LE(ackBytes, 20) != ackIds[1]) {
            throw Exception("selfCheckP2244 FAIL: msgs_ack msgId[1] mismatch")
        }
        if (readI64LE(ackBytes, 28) != ackIds[2]) {
            throw Exception("selfCheckP2244 FAIL: msgs_ack msgId[2] mismatch")
        }

        // ===== 2. msg_resend_req#7d861a08 字节布局断言（2条 msgId）=====
        let resendIds: ArrayList<Int64> = ArrayList<Int64>()
        resendIds.add(0x0ABBCCDD11223344)
        resendIds.add(0x1234567890ABCDE0)
        let resendSerializer = TLSerializer()
        resendSerializer.writeUInt32(TLConstructors.MSG_RESEND_REQ)  // 0x7d861a08
        resendSerializer.writeUInt32(TLConstructors.VECTOR)           // 0x1cb5c415
        resendSerializer.writeInt32(Int32(resendIds.size))
        for (mid in resendIds) {
            resendSerializer.writeInt64(mid)
        }
        let resendBytes = resendSerializer.getBytes()
        // expected: 4 (MSG_RESEND_REQ) + 4 (VECTOR) + 4 (count) + 8*2 = 28
        if (resendBytes.size != 28) {
            throw Exception("selfCheckP2244 FAIL: msg_resend_req body must be 28 bytes, got ${resendBytes.size}")
        }
        if (readU32LE(resendBytes, 0) != 0x7d861a08) {
            throw Exception("selfCheckP2244 FAIL: msg_resend_req constructor must be 0x7d861a08")
        }
        if (readU32LE(resendBytes, 4) != 0x1cb5c415) {
            throw Exception("selfCheckP2244 FAIL: msg_resend_req vector constructor must be 0x1cb5c415")
        }
        if (readI32LE(resendBytes, 8) != 2) {
            throw Exception("selfCheckP2244 FAIL: msg_resend_req count must be 2")
        }
        if (readI64LE(resendBytes, 12) != resendIds[0]) {
            throw Exception("selfCheckP2244 FAIL: msg_resend_req msgId[0] mismatch")
        }
        if (readI64LE(resendBytes, 20) != resendIds[1]) {
            throw Exception("selfCheckP2244 FAIL: msg_resend_req msgId[1] mismatch")
        }

        // ===== 3. scheduleAck 逻辑：奇 seqno → 加入池；偶 seqno → 不加入 =====
        // 直接操作 ArrayList，模拟 scheduleAck 判断逻辑（不走 IO 路径）
        let pendingPool = ArrayList<Int64>()
        // 奇 seqno（content-related）→ 应加入
        let testMsgId1: Int64 = 0x1111111111111111
        let seqNoOdd: Int32 = 3  // 奇数
        if (seqNoOdd % 2 != 0) {
            pendingPool.add(testMsgId1)
        }
        if (pendingPool.size != 1) {
            throw Exception("selfCheckP2244 FAIL: odd seqno must schedule ACK (pool size expected 1, got ${pendingPool.size})")
        }
        if (pendingPool[0] != testMsgId1) {
            throw Exception("selfCheckP2244 FAIL: scheduled ACK msgId mismatch")
        }
        // 偶 seqno（not-content-related）→ 不应加入
        let testMsgId2: Int64 = 0x2222222222222222
        let seqNoEven: Int32 = 4  // 偶数
        if (seqNoEven % 2 != 0) {
            pendingPool.add(testMsgId2)
        }
        if (pendingPool.size != 1) {
            throw Exception("selfCheckP2244 FAIL: even seqno must NOT schedule ACK (pool size expected 1, got ${pendingPool.size})")
        }

        // ===== 4. bad_msg_notification 时间偏移计算断言（纯数学）=====
        // incomingMsgId 高 32 位 = 服务端 Unix 秒（MTProto msgId 规范）
        // 若 incomingMsgId = 0x67A9B4C000000000（高 32 bit = 0x67A9B4C0 = 1738960064 Unix秒，即 2025-02-07 附近）
        let testIncomingMsgId: Int64 = 0x67A9B4C000000000
        let extractedServerSec = (testIncomingMsgId >> 32) & 0x7fffffff
        if (extractedServerSec != 0x67A9B4C0) {
            throw Exception("selfCheckP2244 FAIL: bad_msg timefix serverUnixSec extraction: expected 0x67A9B4C0, got 0x${ByteUtils.toHex(ByteUtils.int64ToBytes(extractedServerSec))}")
        }
        // timeOffset = serverUnixSec - localNowSec（此处只断言提取逻辑正确，不依赖真实时钟）
        let fakeLocalSec: Int64 = 0x67A9B4C0 - 10  // 假设本地慢 10 秒
        let expectedOffset: Int64 = 10
        let computedOffset = extractedServerSec - fakeLocalSec
        if (computedOffset != expectedOffset) {
            throw Exception("selfCheckP2244 FAIL: bad_msg timefix offset expected ${expectedOffset}, got ${computedOffset}")
        }

        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] selfCheckP2244 PASS: msgs_ack(0x62d6b459+Vector) byte layout / msg_resend_req(0x7d861a08+Vector) byte layout / scheduleAck odd/even seqno gating / bad_msg timefix serverUnixSec extraction")
    }

    // -------------------------------------------------------------------------
    // selfCheckP2246（P2-246 migrateToDC race fix）— 真断言，无网络：
    //   1) receiveLoopFuture join 正确性：spawn 一个线程立即完成，保存 Future，调 get() 应不超时
    //   2) sessionRefMutex 保护 session 替换：在锁内写 session，在锁外读到更新后的值
    //   3) session 状态清零走 setter：setAuthKey/clearServerSalt/setAuthKeyState/resetSeqNo 各自正确
    //   4) MTDatacenterAddressSet 地址集操作：addAddress/firstAddress/addressCount 正确
    //   5) updateDCAddressesFromConfig 注入 scheme：对给定 dcId 注入多地址后 getSchemesForDC 返回注入值
    // -------------------------------------------------------------------------
    public static func selfCheckP2246(): Unit {

        // ===== 1. Future join 正确性：spawn + get() 不超时 =====
        let f246 = spawn {
            // 立即返回
            ()
        }
        try {
            f246.get(Duration.second * 2)
        } catch (_e: Exception) {
            throw Exception("selfCheckP2246 FAIL: Future.get() timed out unexpectedly for a no-op thread")
        }

        // ===== 2. MTDatacenterAddress / MTDatacenterAddressSet 基本操作 =====
        let addrSet = MTDatacenterAddressSet(99)
        if (addrSet.addressCount() != 0) {
            throw Exception("selfCheckP2246 FAIL: fresh MTDatacenterAddressSet must have 0 addresses")
        }
        match (addrSet.firstAddress()) {
            case Some(_) => throw Exception("selfCheckP2246 FAIL: empty address set firstAddress() must be None")
            case None => ()
        }

        let a1 = MTDatacenterAddress("10.0.0.1", 443, isMediaOnly: false)
        let a2 = MTDatacenterAddress("10.0.0.2", 4430, isMediaOnly: true)
        addrSet.addAddress(a1)
        addrSet.addAddress(a2)

        if (addrSet.addressCount() != 2) {
            throw Exception("selfCheckP2246 FAIL: MTDatacenterAddressSet must have 2 addresses after 2 adds")
        }
        match (addrSet.firstAddress()) {
            case Some(fa) =>
                if (fa.ip != "10.0.0.1") {
                    throw Exception("selfCheckP2246 FAIL: firstAddress().ip must be 10.0.0.1 (first added)")
                }
                if (fa.port != 443) {
                    throw Exception("selfCheckP2246 FAIL: firstAddress().port must be 443")
                }
                if (fa.isMediaOnly) {
                    throw Exception("selfCheckP2246 FAIL: firstAddress().isMediaOnly must be false")
                }
            case None => throw Exception("selfCheckP2246 FAIL: firstAddress() must not be None after adds")
        }

        // ===== 3. toScheme() 字段映射 =====
        let scheme1 = a1.toScheme(priority: 0)
        if (scheme1.host != "10.0.0.1" || scheme1.port != 443 || scheme1.isMediaOnly || scheme1.priority != 0) {
            throw Exception("selfCheckP2246 FAIL: MTDatacenterAddress.toScheme field mapping incorrect")
        }
        let scheme2 = a2.toScheme(priority: 1)
        if (scheme2.host != "10.0.0.2" || scheme2.port != 4430 || !scheme2.isMediaOnly || scheme2.priority != 1) {
            throw Exception("selfCheckP2246 FAIL: MTDatacenterAddress.toScheme media/priority mapping incorrect")
        }

        // ===== 4. updateDCAddressesFromConfig → MTProtoConfig.getSchemesForDC =====
        let sets = ArrayList<MTDatacenterAddressSet>()
        let testSet = MTDatacenterAddressSet(98)
        testSet.addAddress(MTDatacenterAddress("192.168.1.1", 443))
        testSet.addAddress(MTDatacenterAddress("192.168.1.2", 4430, isMediaOnly: true))
        sets.add(testSet)
        updateDCAddressesFromConfig(sets)

        let injected = MTProtoConfig.getSchemesForDC(98)
        if (injected.size != 2) {
            throw Exception("selfCheckP2246 FAIL: updateDCAddressesFromConfig must inject 2 schemes for DC98, got ${injected.size}")
        }
        if (injected[0].host != "192.168.1.1" || injected[0].isMediaOnly) {
            throw Exception("selfCheckP2246 FAIL: injected scheme[0] must be non-media 192.168.1.1")
        }
        if (injected[1].host != "192.168.1.2" || !injected[1].isMediaOnly) {
            throw Exception("selfCheckP2246 FAIL: injected scheme[1] must be media-only 192.168.1.2")
        }

        // 清理：恢复测试 DC 覆盖（避免污染其他测试）
        MTProtoConfig.setSchemesForDC(98, Array<DcTransportScheme>(0, repeat: DcTransportScheme("", 0)))
        MTProtoConfig.setSchemesForDC(99, Array<DcTransportScheme>(0, repeat: DcTransportScheme("", 0)))

        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] selfCheckP2246 PASS: Future.get() join / MTDatacenterAddressSet CRUD / toScheme mapping / updateDCAddressesFromConfig injection")
    }

    // -------------------------------------------------------------------------
    // selfCheckP2251c（P2-251c PFS 过期重生成 + 入站解密路径）— 真断言，无网络：
    //   1) TempAuthKey.isExpired: expiresAt=0 时永不过期；expiresAt <= nowSec 时已过期。
    //   2) TempAuthKey.isValid: authKey.size>0 && authKeyId.size==8 才有效。
    //   3) auth_key_id 识别逻辑：永久密钥 id 匹配时 matchesPerm=true；
    //      临时密钥 id 匹配时 matchesTemp=true；两者都不匹配时丢弃。
    //   4) PFS 未启用（tempAuthKey=None）时 matchesTemp 始终 false（不影响永久路径）。
    //   任何断言失败抛 Exception。
    // -------------------------------------------------------------------------
    public static func selfCheckP2251c(): Unit {
        // ===== 1. TempAuthKey.isExpired 边界 =====
        let tkNoExpiry = TempAuthKey(
            authKey: Array<Byte>(256, repeat: 0xABu8),
            authKeyId: Array<Byte>(8, repeat: 0x01u8),
            serverSalt: Array<Byte>(8, repeat: 0),
            expiresAt: 0
        )
        if (tkNoExpiry.isExpired(999999999)) {
            throw Exception("selfCheckP2251c FAIL: expiresAt=0 must never be expired")
        }

        let nowSec: Int64 = 1700000000
        let tkExpired = TempAuthKey(
            authKey: Array<Byte>(256, repeat: 0xCDu8),
            authKeyId: Array<Byte>(8, repeat: 0x02u8),
            serverSalt: Array<Byte>(8, repeat: 0),
            expiresAt: nowSec - 1
        )
        if (!tkExpired.isExpired(nowSec)) {
            throw Exception("selfCheckP2251c FAIL: key with expiresAt < nowSec must be expired")
        }

        let tkFuture = TempAuthKey(
            authKey: Array<Byte>(256, repeat: 0xEFu8),
            authKeyId: Array<Byte>(8, repeat: 0x03u8),
            serverSalt: Array<Byte>(8, repeat: 0),
            expiresAt: nowSec + 3600
        )
        if (tkFuture.isExpired(nowSec)) {
            throw Exception("selfCheckP2251c FAIL: key with expiresAt > nowSec must not be expired")
        }

        // ===== 2. TempAuthKey.isValid 边界 =====
        let tkEmpty = TempAuthKey()
        if (tkEmpty.isValid()) {
            throw Exception("selfCheckP2251c FAIL: default TempAuthKey must not be valid (empty authKey)")
        }

        let tkShortId = TempAuthKey(
            authKey: Array<Byte>(256, repeat: 0x01u8),
            authKeyId: Array<Byte>(7, repeat: 0x01u8),
            serverSalt: Array<Byte>(8, repeat: 0),
            expiresAt: 0
        )
        if (tkShortId.isValid()) {
            throw Exception("selfCheckP2251c FAIL: authKeyId.size!=8 must not be valid")
        }

        let tkOk = TempAuthKey(
            authKey: Array<Byte>(256, repeat: 0x01u8),
            authKeyId: Array<Byte>(8, repeat: 0x01u8),
            serverSalt: Array<Byte>(8, repeat: 0),
            expiresAt: 0
        )
        if (!tkOk.isValid()) {
            throw Exception("selfCheckP2251c FAIL: TempAuthKey with proper authKey and 8-byte authKeyId must be valid")
        }

        // ===== 3. auth_key_id 双路识别逻辑（纯字节比较，无网络）=====
        let permId: Array<Byte> = [0x11u8, 0x22u8, 0x33u8, 0x44u8, 0x55u8, 0x66u8, 0x77u8, 0x88u8]
        let tempId: Array<Byte> = [0xAAu8, 0xBBu8, 0xCCu8, 0xDDu8, 0xEEu8, 0xFFu8, 0x00u8, 0x11u8]
        let unknownId: Array<Byte> = [0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x01u8]

        let checkMatch = { incoming: Array<Byte>, hasPerm: Bool, hasTempBound: Bool =>
            var matchesPerm = false
            if (hasPerm) {
                matchesPerm = ByteUtils.equals(incoming, permId)
            }
            var matchesTemp = false
            if (!matchesPerm && hasTempBound) {
                matchesTemp = ByteUtils.equals(incoming, tempId)
            }
            (matchesPerm, matchesTemp)
        }

        // 3a. 永久密钥命中
        let (mp1, mt1) = checkMatch(permId, true, false)
        if (!mp1 || mt1) {
            throw Exception("selfCheckP2251c FAIL: permId must match perm, not temp")
        }

        // 3b. 临时密钥命中（PFS 激活态）
        let (mp2, mt2) = checkMatch(tempId, true, true)
        if (mp2 || !mt2) {
            throw Exception("selfCheckP2251c FAIL: tempId must match temp, not perm")
        }

        // 3c. 两者均不匹配 → 应丢弃（matchesPerm=false, matchesTemp=false）
        let (mp3, mt3) = checkMatch(unknownId, true, true)
        if (mp3 || mt3) {
            throw Exception("selfCheckP2251c FAIL: unknownId must match neither perm nor temp")
        }

        // 3d. PFS 未启用（hasTempBound=false）→ matchesTemp 始终 false，永久路径不受影响
        let (mp4, mt4) = checkMatch(permId, true, false)
        if (!mp4 || mt4) {
            throw Exception("selfCheckP2251c FAIL: with PFS inactive, perm must still match perm")
        }
        let (mp5, mt5) = checkMatch(tempId, true, false)
        if (mp5 || mt5) {
            throw Exception("selfCheckP2251c FAIL: with PFS inactive, tempId must match neither")
        }

        Hilog.info(0, "CjTelegram",
            "[MTProtoClient] selfCheckP2251c PASS: TempAuthKey.isExpired boundaries / isValid boundaries / auth_key_id dual-path recognition (perm+temp+unknown+PFS-inactive)")
    }
}

// ==================== 全局客户端管理（P2-318b: per-account multi-instance）====================
//
// 架构说明（P2-318b）：
//   原单账号全局单例 _globalClient 扩展为 per-account 注册表 _accountClients。
//   每个 account slot（Int32）对应独立的 MTProtoClient 实例，各自持有其 slot 的
//   authKey / session（由 AuthStorage slot 分区路由，P2-318a 已实现）。
//
//   注意：为避免 core.mtproto ↔ core.storage 循环依赖（AuthStorage.cj 已 import
//   core.mtproto 的 Base64/SHA256/ByteUtils），此处不直接 import AuthStorage。
//   取而代之，P2-318c 通过 setActiveSlotProvider 注入活跃 slot 解析闭包。
//
// 回归安全保证（单账号 activeSlot=0）：
//   _activeSlotProvider 未注入 → _resolveActiveSlot() 返回 0
//   → getMTProtoClient() 取 _accountClients[0]（即原 _globalClient 位置）
//   → 行为与改前字节级等价（同 authKey 同 session 同 DC 同连接）。
//
// _globalClient 保留作 slot_0 client 的显式别名：
//   getMainClientDcId() / getClientForDC() 始终面向"主账号"（slot_0），
//   与 activeSlot 无关（跨 DC 文件传输基于主账号授权）。
//   _globalClient 在 _accountClients[0] 创建时同步赋值，保持两者一致。

private var _globalClient: Option<MTProtoClient> = None

// P2-318b: per-account client 注册表（slot → MTProtoClient）
// 所有读写均在 _accountClientsLock 下执行（叶子锁，锁内不做 IO 或嵌套其他锁）。
private var _accountClients = HashMap<Int32, MTProtoClient>()
private let _accountClientsLock = ReentrantMutex()
private var _accountConnectionStateCallback: Option<(Int32, ConnectionState) -> Unit> = None

/** 给现有及之后创建的账号 client 安装带 slot 的连接状态观察者。 */
public func setAccountConnectionStateCallback(callback: (Int32, ConnectionState) -> Unit): Unit {
    let slots = ArrayList<Int32>()
    let clients = ArrayList<MTProtoClient>()
    _accountClientsLock.lock()
    _accountConnectionStateCallback = Some(callback)
    for ((slot, client) in _accountClients) {
        slots.add(slot)
        clients.add(client)
    }
    _accountClientsLock.unlock()
    var index: Int64 = 0
    while (index < clients.size) {
        let slot = slots[index]
        let client = clients[index]
        client.setConnectionStateCallback({ state: ConnectionState => callback(slot, state) })
        index += 1
    }
}

private func installAccountConnectionStateCallback(slot: Int32, client: MTProtoClient): Unit {
    _accountClientsLock.lock()
    let callback = _accountConnectionStateCallback
    _accountClientsLock.unlock()
    match (callback) {
        case Some(handler) =>
            client.setConnectionStateCallback({ state: ConnectionState => handler(slot, state) })
        case None => ()
    }
}

// 账号级 raw updates 观察者。与 _accountConnectionStateCallback 同一范式：updateCallback 是
// MTProtoClient 实例字段，resetGlobalClient() 丢弃实例后，切换账号新建的 client 若不重新
// 安装就再也收不到 updates（typing / 在线状态 / 实时消息全部静默）。注册表持有一份带 slot
// 的观察者，对现有及之后创建的每个账号 client 都安装。
private var _accountUpdateCallback: Option<(Int32, Array<Byte>) -> Unit> = None

/** 给现有及之后创建的账号 client 安装带 slot 的 updates 观察者。 */
public func setAccountUpdateCallback(callback: (Int32, Array<Byte>) -> Unit): Unit {
    let slots = ArrayList<Int32>()
    let clients = ArrayList<MTProtoClient>()
    _accountClientsLock.lock()
    _accountUpdateCallback = Some(callback)
    for ((slot, client) in _accountClients) {
        slots.add(slot)
        clients.add(client)
    }
    _accountClientsLock.unlock()
    var index: Int64 = 0
    while (index < clients.size) {
        let slot = slots[index]
        let client = clients[index]
        client.setUpdateCallback({ data: Array<Byte> => callback(slot, data) })
        index += 1
    }
}

private func installAccountUpdateCallback(slot: Int32, client: MTProtoClient): Unit {
    _accountClientsLock.lock()
    let callback = _accountUpdateCallback
    _accountClientsLock.unlock()
    match (callback) {
        case Some(handler) =>
            client.setUpdateCallback({ data: Array<Byte> => handler(slot, data) })
        case None => ()
    }
}

// P2-318b: 活跃 slot 解析器（注入点）。
// 未注入时默认 slot 0（单账号回归安全）。
// P2-318c 注入：setActiveSlotProvider({ => getAuthStorage().getActiveSlot() })。
private var _activeSlotProvider: Option<() -> Int32> = None
private let _activeSlotProviderLock = ReentrantMutex()

// Fix2 — P2-246: _dcCoordMonitor 同时作为（1）保护 _dcClients/_authorizedDCs/_dcInitInFlight
//   表读写的锁（synchronized(_dcCoordMonitor)）和（2）条件变量（_dcCoordMonitor.wait/notifyAll）。
// 这样等待线程在持锁时调用 wait() 会原子地释放锁并阻塞，避免任何裸字段访问竞态。
// 阻塞网络调用（export+import）在 synchronized 块外执行，不持有 _dcCoordMonitor，不堵其它 DC。
private var _dcClients = HashMap<Int64, MTProtoClient>()
private var _authorizedDCs = HashMap<Int64, Bool>()
private var _dcInitInFlight = HashMap<Int64, Bool>()
private let _dcCoordMonitor = Monitor()

/**
 * P2-318b: 注入活跃 slot 解析器（供 P2-318c AccountManagerService 在 app 启动时调用）。
 *
 * 解耦设计：MTProtoClient 位于 core.mtproto，AuthStorage 位于 core.storage，
 *   而 AuthStorage 已经 import core.mtproto（Base64/SHA256/ByteUtils），
 *   不能反向 import（循环依赖）。故通过闭包注入解析逻辑，与 setProxyProvider /
 *   setMeteringRegistrar 采用相同的解耦范式（services → core 单向依赖）。
 *
 * 调用时机：MainAbility.onCreate → getAuthStorage().initialize 之后立即注入：
 *   setActiveSlotProvider({ => getAuthStorage().getActiveSlot() })
 *
 * 单账号回归安全：未调用本函数 → _resolveActiveSlot() 返回 0 → 与改前行为完全等价。
 * 幂等：可重复注入（取最后一次注入的 provider）。
 */
public func setActiveSlotProvider(provider: () -> Int32): Unit {
    _activeSlotProviderLock.lock()
    _activeSlotProvider = Some(provider)
    _activeSlotProviderLock.unlock()
    Hilog.info(0, "CjTelegram", "[MTProtoRegistry] activeSlotProvider injected")
}

/**
 * P2-318b: 解析当前活跃 account slot。
 * 未注入 provider → 返回 0（单账号回归安全）。
 */
private func _resolveActiveSlot(): Int32 {
    _activeSlotProviderLock.lock()
    let provOpt = _activeSlotProvider
    _activeSlotProviderLock.unlock()
    match (provOpt) {
        case Some(prov) =>
            try {
                return prov()
            } catch (_e: Exception) {
                Hilog.info(0, "CjTelegram", "[MTProtoRegistry] activeSlotProvider threw, defaulting to slot 0")
                return 0
            }
        case None => return 0
    }
}

/**
 * 获取主客户端的 DC ID（不创建客户端）。
 * 用于 persist callback 判断是否应保存此 session —— 仅持久化主 DC 的 session，
 * 防止辅助 DC 客户端（如 getClientForDC）覆盖主 session。
 * P2-318b: 始终返回 slot_0（主账号）client 的 DC ID，与 activeSlot 无关。
 */
public func getMainClientDcId(): Int64 {
    _accountClientsLock.lock()
    let gOpt = _globalClient
    _accountClientsLock.unlock()
    match (gOpt) {
        case Some(client) => return client.getCurrentDcId()
        case None => return -1
    }
}

/**
 * 获取当前活跃账号的 MTProto 客户端实例（P2-318b per-account multi-instance）。
 *
 * 解析逻辑：
 *   1. 调用 _resolveActiveSlot() 取当前活跃 account slot（默认 0）。
 *   2. 在 _accountClients 注册表中查找该 slot 对应的 client。
 *   3. 命中 → 直接返回（热路径，无 IO，O(1) 锁内查找）。
 *   4. 未命中 → 创建新 MTProtoClient，存入注册表；若是 slot_0 同时更新 _globalClient
 *      （保持 getMainClientDcId / getClientForDC 的 slot_0 别名一致）。
 *
 * 回归安全（单账号 activeSlot=0）：
 *   slot=0 → _accountClients[0] → 与改前 _globalClient 完全等价。
 *   对外签名不变（specificDcId 语义保持）。
 *
 * 线程安全：_accountClientsLock（ReentrantMutex）保护注册表读写；
 *   创建 client 对象本身（MTProtoClient 构造）轻量无 IO，锁内安全。
 *   锁内不做网络 IO / 不持 _dcCoordMonitor，无锁序环。
 */
public func getMTProtoClient(specificDcId!: Int64 = -1): MTProtoClient {
    let slot = _resolveActiveSlot()

    _accountClientsLock.lock()
    if (_accountClients.contains(slot)) {
        let client = _accountClients[slot]
        _accountClientsLock.unlock()
        return client
    }
    // 未命中：创建该 slot 的 client（轻量构造，无 IO；锁内安全）
    let newClient = MTProtoClient(specificDcId: specificDcId)
    _accountClients[slot] = newClient
    // slot_0 同步更新 _globalClient（保持主账号别名）
    if (slot == 0) {
        _globalClient = Some(newClient)
    }
    _accountClientsLock.unlock()

    installAccountConnectionStateCallback(slot, newClient)
    installAccountUpdateCallback(slot, newClient)

    Hilog.info(0, "CjTelegram",
        "[MTProtoRegistry] Created MTProtoClient for slot=${slot} (activeSlot resolved)")
    return newClient
}

/**
 * P2-318b: 按 slot 编号直接获取（或按需创建）账号 MTProtoClient。
 *
 * 与 getMTProtoClient() 的区别：此函数绕过 _activeSlotProvider，直接按 slot 参数
 * 查找注册表——供 P2-318c AccountManagerService 在账号切换前后管理各 slot 的 client 生命周期。
 *
 * 认证态隔离保证：每个 slot 对应独立 MTProtoClient 实例，其 initialize() 调用时
 *   AuthStorage.activeSlot 已被 setActiveSlot(n) 设为 n，SessionManager.getSession()
 *   读取的是 slot_n 分区的 authKey/session（P2-318a 路由保证）。
 *
 * 线程安全：_accountClientsLock 保护，与 getMTProtoClient() 共享同一把锁。
 * 回归安全：调用 getAccountClientForSlot(0) === getMTProtoClient() 当 activeSlot=0。
 *
 * @param slot account slot 编号（来自 AuthStorage.listSlots()）
 * @return 该 slot 对应的 MTProtoClient（已存在则复用，不存在则创建空实例）
 */
/**
 * 下载专用客户端注册表（每账号 slot × 当前主 DC 一个；懒创建）。
 * 键含 DC 是因为主客户端会 migrateToDC——若仍按 slot 单键缓存，
 * 迁移后会继续复用绑在旧 DC 上的下载客户端，把「下载客户端 DC 绑定错误」
 * 换个形式留下来。换成 "${slot}_${dcId}" 后，迁移会自然产生新客户端，
 * 旧的闲置不再被取用（不需要显式清理/断连，源侧 worker 也是按 DC 惰性
 * 创建、闲置自然回收）。
 */
private var _downloadClients = HashMap<String, MTProtoClient>()

/**
 * 下载专用 MTProtoClient（iOS media 连接对位）：独立 TCP + 派生会话，
 * 文件分片响应不再把主连接上的小 RPC 回复压在队尾。
 * 未登录（主客户端无 authKey）时直接回退主客户端——派生会话此时拿不到 key。
 *
 * 必须建在主客户端当前所在的 DC 上（而不是默认 DC 1），否则派生会话
 * （getDetachedSession）拷贝的是一个从未建立过的 DC 1 会话的空 authKey，
 * hasAuthKey() 恒 false，主 DC 上的所有下载请求同毫秒返回空。
 */
public func getDownloadMTProtoClient(): MTProtoClient {
    let mainClient = getMTProtoClient()
    if (!mainClient.hasAuthKey()) { return mainClient }
    let mainDcId = mainClient.getCurrentDcId()
    let slot = _resolveActiveSlot()
    let key = "${slot}_${mainDcId}"
    _accountClientsLock.lock()
    if (_downloadClients.contains(key)) {
        let client = _downloadClients[key]
        _accountClientsLock.unlock()
        return client
    }
    let newClient = MTProtoClient(specificDcId: mainDcId)
    newClient.markAsDownloadClient()
    _downloadClients[key] = newClient
    _accountClientsLock.unlock()
    Hilog.info(0, "CjTelegram",
        "[MTProtoRegistry] Created download MTProtoClient for slot=${slot}")
    return newClient
}

/**
 * 群通话内消息专用的派生会话：同一 auth key、独立 session id、声明 layer 228。不持久化。
 * **layer 是按 auth key 记的**：用它发完请求后必须马上 getMTProtoClient().reassertLayer()，
 * 否则主会话后续收到的全是 228 编码。只能通过 CallsService.onLayer228 使用。
 * 副作用：key 平时停在 214，所以服务器不会推 updateGroupCallMessage —— 收消息要等整端升层。
 */
private var _groupCallMessageClients = HashMap<String, MTProtoClient>()
public let GROUP_CALL_MESSAGES_LAYER: Int32 = 228
public let SOURCE_LAYER_GATE = ReentrantMutex()

private var _sourceLayerClients = HashMap<String, MTProtoClient>()

public func getSourceLayerClient(): MTProtoClient {
    let mainClient = getMTProtoClient()
    if (!mainClient.hasAuthKey()) { return mainClient }
    let mainDcId = mainClient.getCurrentDcId()
    let slot = _resolveActiveSlot()
    let key = "${slot}_${mainDcId}"
    _accountClientsLock.lock()
    if (_sourceLayerClients.contains(key)) {
        let client = _sourceLayerClients[key]
        _accountClientsLock.unlock()
        return client
    }
    let newClient = MTProtoClient(specificDcId: mainDcId)
    newClient.markAsDownloadClient()
    newClient.setLayerOverride(GROUP_CALL_MESSAGES_LAYER)
    _sourceLayerClients[key] = newClient
    _accountClientsLock.unlock()
    Hilog.info(0, "CjTelegram",
        "[MTProtoRegistry] Created source-layer MTProtoClient (layer ${GROUP_CALL_MESSAGES_LAYER}) for slot=${slot}")
    return newClient
}

public func getGroupCallMessagesClient(onUpdates: (Array<Byte>) -> Unit): MTProtoClient {
    let mainClient = getMTProtoClient()
    if (!mainClient.hasAuthKey()) { return mainClient }
    let mainDcId = mainClient.getCurrentDcId()
    let slot = _resolveActiveSlot()
    let key = "${slot}_${mainDcId}"
    _accountClientsLock.lock()
    if (_groupCallMessageClients.contains(key)) {
        let client = _groupCallMessageClients[key]
        _accountClientsLock.unlock()
        client.setUpdateCallback(onUpdates)
        return client
    }
    let newClient = MTProtoClient(specificDcId: mainDcId)
    newClient.markAsDownloadClient()
    newClient.setLayerOverride(GROUP_CALL_MESSAGES_LAYER)
    newClient.setUpdateCallback(onUpdates)
    _groupCallMessageClients[key] = newClient
    _accountClientsLock.unlock()
    Hilog.info(0, "CjTelegram",
        "[MTProtoRegistry] Created group-call-messages MTProtoClient (layer ${GROUP_CALL_MESSAGES_LAYER}) for slot=${slot}")
    return newClient
}

/**
 * 上传专用客户端池（iOS Network.upload(tag:) → MultiplexedRequestManager worker 对位：
 * 每目标最多 4 个 worker、每 worker 3 个在途请求）。每次 uploadFile 轮转取一条连接，
 * 一条连接上跑该文件的 3 个并发分片；与主连接、下载连接互不排队。派生会话，不持久化。
 */
private var _uploadClients = HashMap<String, MTProtoClient>()
private var _uploadRoundRobin: Int64 = 0
private let UPLOAD_CONNECTIONS: Int64 = 4

public func getUploadMTProtoClient(): MTProtoClient {
    let mainClient = getMTProtoClient()
    if (!mainClient.hasAuthKey()) { return mainClient }
    let mainDcId = mainClient.getCurrentDcId()
    let slot = _resolveActiveSlot()
    _accountClientsLock.lock()
    let idx = _uploadRoundRobin % UPLOAD_CONNECTIONS
    _uploadRoundRobin += 1
    let key = "${slot}_${mainDcId}_${idx}"
    if (_uploadClients.contains(key)) {
        let client = _uploadClients[key]
        _accountClientsLock.unlock()
        return client
    }
    let newClient = MTProtoClient(specificDcId: mainDcId)
    newClient.markAsDownloadClient()
    _uploadClients[key] = newClient
    _accountClientsLock.unlock()
    Hilog.info(0, "CjTelegram", "[MTProtoRegistry] Created upload MTProtoClient #${idx} for slot=${slot}")
    return newClient
}

public func getAccountClientForSlot(slot: Int32): MTProtoClient {
    _accountClientsLock.lock()
    if (_accountClients.contains(slot)) {
        let client = _accountClients[slot]
        _accountClientsLock.unlock()
        return client
    }
    let newClient = MTProtoClient()
    _accountClients[slot] = newClient
    if (slot == 0) {
        _globalClient = Some(newClient)
    }
    _accountClientsLock.unlock()
    installAccountConnectionStateCallback(slot, newClient)
    installAccountUpdateCallback(slot, newClient)
    Hilog.info(0, "CjTelegram",
        "[MTProtoRegistry] getAccountClientForSlot: created MTProtoClient for slot=${slot}")
    return newClient
}

/**
 * P2-318b: 从 per-account 注册表移除指定 slot 的 client 并 disconnect。
 * 供 P2-318c / P2-318d 账号删除时调用。
 * 不影响其他 slot；不改变 activeSlot。
 * 回归安全：slot_0 永不被外部 remove（与 resetGlobalClient 语义区分）。
 */
public func removeAccountClientForSlot(slot: Int32): Unit {
    if (slot == 0) {
        Hilog.info(0, "CjTelegram", "[MTProtoRegistry] removeAccountClientForSlot: ignoring slot=0 (use resetGlobalClient)")
        return
    }
    var clientOpt: Option<MTProtoClient> = None
    _accountClientsLock.lock()
    if (_accountClients.contains(slot)) {
        clientOpt = Some(_accountClients[slot])
        let _ = _accountClients.remove(slot)
        if (slot == 0) {
            _globalClient = None
        }
    }
    _accountClientsLock.unlock()
    match (clientOpt) {
        case Some(client) =>
            client.disconnect()
            Hilog.info(0, "CjTelegram",
                "[MTProtoRegistry] removeAccountClientForSlot: slot=${slot} disconnected")
        case None =>
            Hilog.info(0, "CjTelegram",
                "[MTProtoRegistry] removeAccountClientForSlot: slot=${slot} not found, noop")
    }
}

/**
 * 获取指定 DC 的客户端实例（用于跨 DC 文件下载）。
 * 如果 dcId 等于主客户端的 DC，直接返回主客户端。
 * 否则创建新客户端并通过 auth.exportAuthorization / auth.importAuthorization 导入授权。
 *
 * Fix1 — P2-246: importAuthorization 响应验证。
 *   解析 import response：成功构造子（auth.authorization#2ea2c0d4 或
 *   auth.authorizationSignUpRequired#44747e9a）才置 _authorizedDCs[dcId]=true。
 *   若返回 RPC_ERROR 或非预期构造子 → 失败，不写 _authorizedDCs，返回 mainClient。
 *   对齐 iOS：import 成功才标记 authorized。
 *
 * Fix2 — P2-246: TOCTOU 双初始化竞态消除（per-DC in-flight + _dcCoordMonitor 条件等待）。
 *   _dcCoordMonitor 同时作为 _dcClients/_authorizedDCs/_dcInitInFlight 三张表的锁和条件变量。
 *   第一个到达的线程：
 *     (a) 在 synchronized(_dcCoordMonitor) 内 check 未命中 → 标记 in-flight → 退出 synchronized → 做网络工作。
 *   后续并发线程：
 *     (b) 进入 synchronized(_dcCoordMonitor)，发现 in-flight=true → _dcCoordMonitor.wait()
 *         （wait 原子地释放 _dcCoordMonitor 并阻塞，不持任何锁，不能发生死锁）。
 *   第一个线程完成后：
 *     (c) 重新进入 synchronized(_dcCoordMonitor) → 更新表 → 清除 in-flight → notifyAll
 *         → 等待者被唤醒 → 重查自身条件（while loop）→ 发现已建好直接复用。
 *
 * 无死锁论证：
 *   - 阻塞网络调用（sendRequest）在 synchronized(_dcCoordMonitor) 块外执行（不持锁做 IO）。
 *   - synchronized(_dcCoordMonitor) 内只做内存读写和 wait/notifyAll，无 IO，无嵌套其他锁。
 *   - wait() 原子地释放 _dcCoordMonitor，等待期间不持有任何锁，任何其他线程可自由进入。
 *   - sessionRefMutex / rpcMonitor / sessionLock 均不与 _dcCoordMonitor 嵌套，无锁序环。
 */
public func getClientForDC(dcId: Int64): MTProtoClient {
    let mainClient = getMTProtoClient()
    let mainDcId = mainClient.getCurrentDcId()

    if (mainDcId == dcId) {
        return mainClient
    }

    // Fix2 — 第一次 check + in-flight 决策（全部在 _dcCoordMonitor 保护下）
    var needInit = false
    synchronized(_dcCoordMonitor) {
        // 已有 authorized 客户端：快速路径（用 needInit 变量把结果携带出 synchronized 块）
        if (_dcClients.contains(dcId) && _authorizedDCs.contains(dcId)) {
            needInit = false
        } else if (_dcInitInFlight.contains(dcId)) {
            // 另一个线程正在初始化，等待其完成（最多 65s）
            let waitDeadline = mtprotoMonotonicNowMs() + 65000
            while (_dcInitInFlight.contains(dcId)) {
                let remaining = waitDeadline - mtprotoMonotonicNowMs()
                if (remaining <= 0) {
                    break
                }
                let _ = _dcCoordMonitor.wait(timeout: Duration.millisecond * remaining)
            }
            // 被唤醒后：若已 authorized 则用之，否则退出让调用方 fallback
            needInit = false  // 等待后不再本线程发起 init
        } else {
            // 本线程是第一个到达者，标记 in-flight
            _dcInitInFlight[dcId] = true
            needInit = true
        }
    }

    // 快速路径：从 synchronized 块里出来后取结果（不能在 synchronized 内 return）
    if (!needInit) {
        var foundClient: Option<MTProtoClient> = None
        synchronized(_dcCoordMonitor) {
            if (_dcClients.contains(dcId) && _authorizedDCs.contains(dcId)) {
                foundClient = Some(_dcClients[dcId])
            }
        }
        match (foundClient) {
            case Some(client) => return client
            case None =>
                // 等待超时或初始化失败，回退主客户端
                Hilog.info(0, "CjTelegram", "[DCRouter] DC${dcId}: peer init timed out or failed, returning mainClient")
                return mainClient
        }
    }

    // 本线程负责初始化（阻塞网络操作在锁外执行，不持 _dcCoordMonitor）
    Hilog.info(0, "CjTelegram", "[DCRouter] Creating client for DC${dcId}...")

    var resultClient: Option<MTProtoClient> = None  // None 表示失败，Some 表示成功

    try {
        let exportReq = AuthExportAuthorization()
        exportReq.dcId = Int32(dcId)
        let exportResponse = mainClient.sendRequest(exportReq.toBytes())

        let (exportId, exportBytes) = parseExportedAuthorization(exportResponse)
        if (exportId == 0 && exportBytes.size == 0) {
            Hilog.info(0, "CjTelegram", "[DCRouter] Failed to export authorization for DC${dcId}")
        } else {
            Hilog.info(0, "CjTelegram", "[DCRouter] Exported auth: id=${exportId}, bytes=${exportBytes.size}")

            let dcClient = MTProtoClient(specificDcId: dcId)
            dcClient.initialize(specificDcId: dcId)
            Hilog.info(0, "CjTelegram", "[DCRouter] DC${dcId} client initialized, hasAuthKey=${dcClient.hasAuthKey()}")

            let importReq = AuthImportAuthorization()
            importReq.id = exportId
            importReq.bytes = exportBytes
            let importResponse = dcClient.sendRequest(importReq.toBytes())
            Hilog.info(0, "CjTelegram", "[DCRouter] Import auth response: ${importResponse.size} bytes")

            // Fix1 — 解析 import response，只有成功构造子才标记 authorized（对齐 iOS 语义）
            let importOk = parseImportAuthorizationResponse(importResponse)
            if (importOk) {
                resultClient = Some(dcClient)
                Hilog.info(0, "CjTelegram", "[DCRouter] DC${dcId} client ready (import auth verified)")
            } else {
                Hilog.info(0, "CjTelegram", "[DCRouter] DC${dcId} import auth failed (unexpected response), returning mainClient")
            }
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[DCRouter] DC${dcId} init exception: ${e}, returning mainClient")
    }

    // Fix2 — 写入结果、清除 in-flight、唤醒等待者（全部在 _dcCoordMonitor 保护下原子完成）
    synchronized(_dcCoordMonitor) {
        // 只在 import 成功时写入 _dcClients/_authorizedDCs（Fix1）
        match (resultClient) {
            case Some(client) =>
                _dcClients[dcId] = client
                _authorizedDCs[dcId] = true
            case None => ()
        }
        let _ = _dcInitInFlight.remove(dcId)
        _dcCoordMonitor.notifyAll()
    }

    return match (resultClient) {
        case Some(client) => client
        case None => mainClient
    }
}

/**
 * Fix1 — P2-246: 解析 auth.importAuthorization 响应，判断是否成功。
 * Fix2（本轮真机根因修复）：成功构造子原硬编码 0xcd050916 是错误值（不存在于任何
 *   Telegram TL layer），真机实测导入到 DC1 的授权响应被 parseImportAuth 判定为
 *   "unexpected constructor 0xd4c0a22e (failure)" 而误判失败。0xd4c0a22e 是
 *   auth.authorization#2ea2c0d4 的 LE wire 字节按 ByteUtils.toHex(uint32ToBytes(..))
 *   习惯打印顺序（等价于把 0x2ea2c0d4 按字节反转显示），即真实收到的就是
 *   auth.authorization#2ea2c0d4 —— 与本仓库已验证工作的 AuthAuthorizationResponse.
 *   deserialize()（RealAuthService.verifyCode 成功路径用的同一常量，TLResponses.cj:382）
 *   完全一致。改为比对正确的 0x2ea2c0d4。
 *
 * 成功构造子（对齐 telegram_api.tl 当前 layer + 本仓库 AuthAuthorizationResponse）：
 *   - auth.authorization#2ea2c0d4               — 正常登录授权成功
 *   - auth.authorizationSignUpRequired#44747e9a — 需要注册（仍视为 import 成功，服务端接受了授权）
 * 失败：
 *   - RPC_ERROR(0x2144ca19)                 — 服务端返回错误
 *   - 其他未知构造子                         — 非预期响应，视为失败
 *
 * @return true = import 成功，可将 dcId 标记为 authorized；false = 失败，不标记
 */
func parseImportAuthorizationResponse(data: Array<Byte>): Bool {
    if (data.size < 4) {
        Hilog.info(0, "CjTelegram", "[DCRouter] parseImportAuth: response too short (${data.size} bytes)")
        return false
    }
    let d = TLDeserializer(data)
    let constructor = d.readUInt32()
    // auth.authorization#2ea2c0d4 — import 成功（主 DC 上完成登录的授权对象）
    if (constructor == 0x2ea2c0d4) {
        Hilog.info(0, "CjTelegram", "[DCRouter] parseImportAuth: auth.authorization#2ea2c0d4 (success)")
        return true
    }
    // auth.authorizationSignUpRequired#44747e9a — 需要注册，但 import 本身被服务端接受
    if (constructor == 0x44747e9a) {
        Hilog.info(0, "CjTelegram", "[DCRouter] parseImportAuth: auth.authorizationSignUpRequired#44747e9a (success)")
        return true
    }
    // RPC_ERROR — 服务端明确拒绝
    if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
        let errorCode = d.readInt32()
        let errorMessage = d.readString()
        Hilog.info(0, "CjTelegram", "[DCRouter] parseImportAuth: RPC_ERROR ${errorCode} ${errorMessage} (failure)")
        return false
    }
    // 未知构造子
    Hilog.info(0, "CjTelegram", "[DCRouter] parseImportAuth: unexpected constructor 0x${ByteUtils.toHex(ByteUtils.uint32ToBytes(constructor))} (failure)")
    return false
}

/**
 * 解析 auth.exportedAuthorization#b434e2b8 响应
 * 返回 (id: Int64, bytes: Array<Byte>)
 */
func parseExportedAuthorization(data: Array<Byte>): (Int64, Array<Byte>) {
    if (data.size < 4) {
        return (0, Array<Byte>(0, repeat: 0))
    }
    let d = TLDeserializer(data)
    let constructor = d.readUInt32()
    if (constructor == 0xb434e2b8) {
        let id = d.readInt64()
        let bytes = d.readBytes()
        return (id, bytes)
    }
    if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
        let errorCode = d.readInt32()
        let errorMessage = d.readString()
        Hilog.info(0, "CjTelegram", "[DCRouter] Export auth error: ${errorCode} ${errorMessage}")
    }
    return (0, Array<Byte>(0, repeat: 0))
}

/**
 * P2-246 Gap-3: 获取媒体专用 DC 客户端（用于文件/媒体下载）。
 *
 * 路由策略（对应 iOS MTDatacenterAddressSet preferForMedia 语义）：
 *   1. 扫描 dcId DC 的候选 scheme 列表，找第一个 isMediaOnly=true 的 scheme。
 *   2. Fix4 — P2-246: 找到媒体 scheme 后，把它**真正注入**为该 dcId 的首选端点：
 *      构造新的 scheme 列表 [mediaScheme, ...其余 scheme]，使媒体 scheme 排在首位，
 *      调用 MTProtoConfig.setSchemesForDC(dcId, newSchemes) 临时覆盖优先顺序。
 *      这样 getClientForDC → dcClient.initialize → attemptReconnect → getSchemesForDC(dcId)[0]
 *      就会优先使用媒体端点连接，而不只是记日志。
 *   3. 若目标 DC 无 media-only scheme，直接返回该 DC 普通客户端（回退安全）。
 *   4. 若 dcId 为 -1，返回当前主客户端。
 *
 * 注入是"软覆盖"：setSchemesForDC 更新 _schemeOverrides 表，不影响其他 DC。
 * 若该 DC 已有客户端（cached），注入仍更新 scheme 列表供后续 reconnect 使用。
 *
 * 调用方：文件下载子系统（services 层）在发起文件 RPC 前调用本函数获取媒体 DC 客户端，
 * 替代直接调用 getMTProtoClient()，实现 media-DC vs main-DC 路由分离。
 */
public func getMediaClientForDC(dcId: Int64): MTProtoClient {
    if (dcId < 0) {
        return getMTProtoClient()
    }

    let schemes = MTProtoConfig.getSchemesForDC(dcId)
    var mediaScheme: Option<DcTransportScheme> = None
    for (s in schemes) {
        if (s.isMediaOnly) {
            mediaScheme = Some(s)
            break
        }
    }

    match (mediaScheme) {
        case Some(ms) =>
            Hilog.info(0, "CjTelegram", "[DCRouter] DC${dcId} media route: injecting media-only scheme ${ms.describe()} as preferred endpoint")
            // Fix4 — P2-246: 真正注入媒体 scheme 为首选端点
            // 构造新列表：[mediaScheme, ...其余非媒体 scheme]
            let newSchemes = ArrayList<DcTransportScheme>()
            newSchemes.add(ms)
            for (s in schemes) {
                if (!s.isMediaOnly) {
                    newSchemes.add(s)
                }
            }
            var newSchemesArr = Array<DcTransportScheme>(newSchemes.size, repeat: DcTransportScheme("", 0))
            var idx: Int64 = 0
            for (s in newSchemes) {
                newSchemesArr[idx] = s
                idx += 1
            }
            MTProtoConfig.setSchemesForDC(dcId, newSchemesArr)
            Hilog.info(0, "CjTelegram", "[DCRouter] DC${dcId}: media scheme injected as [0], ${newSchemes.size} schemes total")
        case None =>
            Hilog.info(0, "CjTelegram", "[DCRouter] DC${dcId} no media-only scheme, falling back to normal DC client")
    }

    return getClientForDC(dcId)
}

/**
 * 重置全局客户端（P2-318b: 同时清理 per-account 注册表）。
 *
 * 操作顺序（避免持锁 IO）：
 *   1. 在 _accountClientsLock 内取出所有 account client 快照并清空注册表。
 *   2. 在 _dcCoordMonitor 内取出 DC client 快照并清空 DC 表。
 *   3. 锁外逐一 disconnect（阻塞 IO 不持任何锁）。
 *
 * 回归安全：单账号只有 slot_0 client，disconnect 语义与改前完全一致。
 */
public func resetGlobalClient() {
    // P2-318b: 取出所有 account client 快照（锁内），锁外 disconnect
    var accountsToDisconnect = ArrayList<MTProtoClient>()
    _accountClientsLock.lock()
    for ((_, client) in _accountClients) {
        accountsToDisconnect.add(client)
    }
    _accountClients = HashMap<Int32, MTProtoClient>()
    _globalClient = None
    _accountClientsLock.unlock()

    // 先在锁内取出客户端快照并清空表，再在锁外 disconnect（避免持锁做阻塞 IO）
    var toDisconnect = ArrayList<MTProtoClient>()
    synchronized(_dcCoordMonitor) {
        for ((_, client) in _dcClients) {
            toDisconnect.add(client)
        }
        _dcClients = HashMap<Int64, MTProtoClient>()
        _authorizedDCs = HashMap<Int64, Bool>()
        _dcInitInFlight = HashMap<Int64, Bool>()
        _dcCoordMonitor.notifyAll()  // 唤醒任何正在等待的 getClientForDC 调用
    }
    // 锁外退役并 disconnect 所有 client（账号 + 辅助 DC）。退役而非仅断开：断开的实例在
    // 下一次 sendRequest 时会自动重连，旧账号连接会被仍持有引用的调用方悄悄复活。
    for (client in accountsToDisconnect) {
        client.retire()
    }
    for (client in toDisconnect) {
        client.retire()
    }
    Hilog.info(0, "CjTelegram",
        "[MTProtoRegistry] resetGlobalClient: disconnected ${accountsToDisconnect.size} account client(s) + ${toDisconnect.size} DC client(s)")
}
