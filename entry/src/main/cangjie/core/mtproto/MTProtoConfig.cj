package ohos_app_cangjie_entry.core.mtproto

import kit.PerformanceAnalysisKit.Hilog
import kit.BasicServicesKit.DeviceInfo
import std.collection.ArrayList
import std.collection.HashMap
import std.collection.HashSet
import std.random.Random
import std.sync.ReentrantMutex

/**
 * 数据中心信息
 * 
 * 对应 TelegramHarmony 的 MTProtoConfig.ets DataCenter
 */
public class DataCenter {
    public let id: Int64
    public let host: String
    public let port: UInt16
    public let isTest: Bool

    public init(id: Int64, host: String, port: UInt16, isTest!: Bool = false) {
        this.id = id
        this.host = host
        this.port = port
        this.isTest = isTest
    }
}

/**
 * 单个 DC 的传输端点 scheme（P2-241c）。
 *
 * 对应 iOS MtProtoKit MTTransportScheme：每个 DC 可配多个连接 scheme
 * （主端点 + 备用端点 + 媒体专用端点），各自带不同 host/port/混淆开关/媒体标记/优先级，
 * 客户端并发探测 RTT 后择优作为该 DC 的活动连接。
 *
 * 字段：
 *   - host / port       连接目标地址（与 DataCenter.host/port 同类；多 scheme 时可指向不同接入点）
 *   - isObfuscated      是否对该 scheme 启用 obfuscated2 混淆层（对接 P2-241b enableObfuscation）
 *   - isMediaOnly       是否仅用于媒体（大文件下载）请求；普通 RPC 选择时跳过 media-only scheme
 *   - priority          优先级（数值小 = 优先；RTT 相同/不可测时按此排序，对齐 iOS isOptimal 语义）
 *
 * 回归安全：DC 只有一个 scheme（由 DataCenter 派生的默认 scheme）时，
 * 选择逻辑退化为直接返回它，host/port/混淆全部与现状一致（字节/流程不变）。
 */
public class DcTransportScheme {
    public let host: String
    public let port: UInt16
    public let isObfuscated: Bool
    public let isMediaOnly: Bool
    public let priority: Int64

    public init(
        host: String,
        port: UInt16,
        isObfuscated!: Bool = false,
        isMediaOnly!: Bool = false,
        priority!: Int64 = 0
    ) {
        this.host = host
        this.port = port
        this.isObfuscated = isObfuscated
        this.isMediaOnly = isMediaOnly
        this.priority = priority
    }

    /**
     * 由现有 DataCenter 派生默认 scheme（单 scheme 退化路径）。
     * host/port 直接取自 DC，混淆关闭、非媒体专用、优先级 0 —— 与改动前单连行为完全一致。
     */
    public static func fromDataCenter(dc: DataCenter): DcTransportScheme {
        return DcTransportScheme(dc.host, dc.port, isObfuscated: false, isMediaOnly: false, priority: 0)
    }

    public func describe(): String {
        return "${host}:${port} (obf=${isObfuscated}, media=${isMediaOnly}, prio=${priority})"
    }
}

/**
 * 认证密钥状态
 */
public enum AuthKeyState {
    | None_
    | Creating
    | Created
    | Registered

    public func ordinal(): Int32 {
        match (this) {
            case None_ => 0
            case Creating => 1
            case Created => 2
            case Registered => 3
        }
    }

    public operator func ==(right: AuthKeyState): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: AuthKeyState): Bool {
        return this.ordinal() != right.ordinal()
    }
}

/**
 * 连接状态
 */
public enum ConnectionState {
    | Disconnected
    | Connecting
    | Connected
    | Updating
}

/**
 * MTProto 配置
 * 
 * 对应 TelegramHarmony 的 MTProtoConfig.ets MTProtoConfig
 */
public class MTProtoConfig {
    // Telegram API 凭证
    public static var USE_TEST_DC: Bool = false
    
    // 生产环境凭证
    // 请在 https://my.telegram.org/apps 申请你自己的 api_id / api_hash 并填入这里
    // Obtain your own api_id / api_hash at https://core.telegram.org/api/obtaining_api_id
    public static let PROD_API_ID: Int64 = 0
    public static let PROD_API_HASH: String = ""
    
    // 测试环境凭证（使用相同的）
    public static let TEST_API_ID: Int64 = 0
    public static let TEST_API_HASH: String = ""

    public static func getApiId(): Int64 {
        return if (USE_TEST_DC) { TEST_API_ID } else { PROD_API_ID }
    }

    public static func getApiHash(): String {
        return if (USE_TEST_DC) { TEST_API_HASH } else { PROD_API_HASH }
    }

    // 应用信息
    public static let APP_VERSION: String = "1.0.0"
    public static let DEVICE_MODEL: String = "Desktop"
    public static let SYSTEM_VERSION: String = "Other"
    public static let LANG_CODE: String = "en"
    public static let SYSTEM_LANG_CODE: String = "en"
    // Telegram-iOS passes languagesCategory="ios" into MTApiEnvironment and
    // serializes it as initConnection.lang_pack. Individual langpack methods
    // intentionally keep langPack="" so the server resolves this category.
    public static let LANG_PACK: String = "ios"

    // MTProto 协议层号
    public static let LAYER: Int32 = 214

    // 生产环境数据中心
    public static let PRODUCTION_DCS: Array<DataCenter> = [
        DataCenter(1, "149.154.175.53", 443),
        DataCenter(2, "149.154.167.50", 443),
        DataCenter(3, "149.154.175.100", 443),
        DataCenter(4, "149.154.167.91", 443),
        DataCenter(5, "91.108.56.130", 443)
    ]

    // 测试环境数据中心
    public static let TEST_DCS: Array<DataCenter> = [
        DataCenter(1, "149.154.175.10", 443, isTest: true),
        DataCenter(2, "149.154.167.40", 443, isTest: true),
        DataCenter(3, "149.154.175.117", 443, isTest: true)
    ]

    public static func getDataCenters(): Array<DataCenter> {
        return if (USE_TEST_DC) { TEST_DCS } else { PRODUCTION_DCS }
    }

    public static func getDefaultDC(): DataCenter {
        return getDataCenters()[0]
    }

    public static func getDCById(id: Int64): Option<DataCenter> {
        let dcs = getDataCenters()
        for (dc in dcs) {
            if (dc.id == id) {
                return Some(dc)
            }
        }
        return None
    }

    // ---- P2-241c：每 DC 多 transport scheme ----
    // 可选 scheme 覆盖表（dcId → 候选 scheme 列表）。
    // 默认空 —— 此时每个 DC 退化为「由 DataCenter 派生的单一默认 scheme」，
    // 行为与改动前完全一致（回归安全）。仅当显式 setSchemesForDC 注入多 scheme 时才生效。
    private static var _schemeOverrides: HashMap<Int64, Array<DcTransportScheme>> = HashMap<Int64, Array<DcTransportScheme>>()

    /**
     * 为某个 DC 注入候选 scheme 列表（主 + 备 + 媒体专用）。
     * 传入空数组等同于清除覆盖（回退单默认 scheme）。
     */
    public static func setSchemesForDC(dcId: Int64, schemes: Array<DcTransportScheme>): Unit {
        if (schemes.size == 0) {
            if (_schemeOverrides.contains(dcId)) {
                let _ = _schemeOverrides.remove(dcId)
            }
            return
        }
        _schemeOverrides[dcId] = schemes
    }

    /**
     * 取某 DC 的候选 scheme 列表。
     *   - 有覆盖 → 返回覆盖列表（多 scheme）。
     *   - 无覆盖 → 返回由该 DC 派生的单一默认 scheme（单 scheme 退化，字节/流程不变）。
     * 找不到 DC 时回退默认 DC 的单 scheme。
     */
    public static func getSchemesForDC(dcId: Int64): Array<DcTransportScheme> {
        if (_schemeOverrides.contains(dcId)) {
            let over = _schemeOverrides[dcId]
            if (over.size > 0) {
                return over
            }
        }
        let dc = match (getDCById(dcId)) {
            case Some(d) => d
            case None => getDefaultDC()
        }
        return [DcTransportScheme.fromDataCenter(dc)]
    }

    /**
     * 清除所有 scheme 覆盖（全部 DC 回退单默认 scheme）。
     */
    public static func clearSchemeOverrides(): Unit {
        _schemeOverrides = HashMap<Int64, Array<DcTransportScheme>>()
    }

    // 超时配置（毫秒）
    public static let CONNECTION_TIMEOUT: Int64 = 30000
    public static let REQUEST_TIMEOUT: Int64 = 60000
    public static let RECONNECT_INTERVAL: Int64 = 5000
    public static let MAX_RETRIES: Int64 = 5
}

// ============================================================
// P2-246 Gap-1: 每 DC 多地址集（address-set failover）
//
// 对应 iOS MtProtoKit MTDatacenterAddress / MTDatacenterAddressSet：
//   - MTDatacenterAddress   单个 DC 接入点描述（ip/port/ipv6/mediaOnly）
//   - MTDatacenterAddressSet  按 DC 组织的多地址集合，含 firstAddress()
//   - updateDCAddressesFromConfig  将地址集转换为 DcTransportScheme 并注入 MTProtoConfig
// ============================================================

/**
 * 单个 DC 接入地址描述（对应 iOS MTDatacenterAddress）。
 *
 * 字段：
 *   ip          IPv4 / IPv6 字符串形式
 *   port        端口号
 *   isIpv6      是否 IPv6（IPv6 地址连接时可能需要方括号封装，由 TCPTransport 处理）
 *   isMediaOnly 是否仅媒体流量专用（映射到 DcTransportScheme.isMediaOnly）
 *   cdn         是否 CDN DC（文件分发节点，auth 机制不同）
 */
public class MTDatacenterAddress {
    public let ip: String
    public let port: UInt16
    public let isIpv6: Bool
    public let isMediaOnly: Bool
    public let cdn: Bool

    public init(
        ip: String,
        port: UInt16,
        isIpv6!: Bool = false,
        isMediaOnly!: Bool = false,
        cdn!: Bool = false
    ) {
        this.ip = ip
        this.port = port
        this.isIpv6 = isIpv6
        this.isMediaOnly = isMediaOnly
        this.cdn = cdn
    }

    /**
     * 转换为 DcTransportScheme（priority 按地址顺序由外部赋值）。
     */
    public func toScheme(priority!: Int64 = 0): DcTransportScheme {
        return DcTransportScheme(ip, port, isObfuscated: false, isMediaOnly: isMediaOnly, priority: priority)
    }
}

/**
 * 某 DC 的全部接入地址集合（对应 iOS MTDatacenterAddressSet）。
 *
 * 维护一个有序 ArrayList，firstAddress() 返回优先级最高的地址（index 0）。
 * 供 failover 路径：主地址连接失败时，取第二、第三地址重试，依此类推。
 */
public class MTDatacenterAddressSet {
    public let dcId: Int64
    private var _addresses: ArrayList<MTDatacenterAddress> = ArrayList<MTDatacenterAddress>()

    public init(dcId: Int64) {
        this.dcId = dcId
    }

    /**
     * 追加一个地址（按优先级顺序追加；index 0 = 最高优先）。
     */
    public func addAddress(addr: MTDatacenterAddress): Unit {
        this._addresses.add(addr)
    }

    /**
     * 返回优先级最高的地址（index 0）；若无地址返回 None。
     */
    public func firstAddress(): Option<MTDatacenterAddress> {
        if (this._addresses.size == 0) {
            return None
        }
        return Some(this._addresses[0])
    }

    /**
     * 所有地址数量。
     */
    public func addressCount(): Int64 {
        return this._addresses.size
    }

    /**
     * 返回全部地址 ArrayList（只读引用，供外部遍历）。
     */
    public func allAddresses(): ArrayList<MTDatacenterAddress> {
        return this._addresses
    }
}

/**
 * P2-246 Gap-1: 将 MTDatacenterAddressSet 列表转换为 DcTransportScheme 并注入 MTProtoConfig，
 * 启用每 DC 多地址 failover（对接 P2-241c/d ReconnectController scheme failover）。
 *
 * 调用场景：
 *   - 收到 help.getConfig 响应后，将服务端下发的 DC 地址列表通过本函数注入
 *   - 应用启动时若有持久化的 DC 地址列表，通过本函数恢复
 *
 * 实现：
 *   对每个 MTDatacenterAddressSet，将其 allAddresses() 转换为 DcTransportScheme 数组
 *   并调用 MTProtoConfig.setSchemesForDC 注入（已有 scheme 覆盖直接替换）。
 *   媒体专用地址映射到 isMediaOnly=true 的 scheme（buildTransportWithBestScheme 会在普通连接中跳过）。
 *
 * 回归安全：不注入时等同于未调用本函数，退化到单默认 scheme，行为不变。
 */
public func updateDCAddressesFromConfig(addressSets: ArrayList<MTDatacenterAddressSet>): Unit {
    for (addrSet in addressSets) {
        let addrs = addrSet.allAddresses()
        if (addrs.size == 0) {
            continue
        }
        var schemes: ArrayList<DcTransportScheme> = ArrayList<DcTransportScheme>()
        var priority: Int64 = 0
        for (addr in addrs) {
            schemes.add(addr.toScheme(priority: priority))
            priority += 1
        }
        var schemesArr: Array<DcTransportScheme> = Array<DcTransportScheme>(schemes.size, repeat: DcTransportScheme("", 0))
        var i: Int64 = 0
        for (s in schemes) {
            schemesArr[i] = s
            i += 1
        }
        MTProtoConfig.setSchemesForDC(addrSet.dcId, schemesArr)
        Hilog.info(0, "CjTelegram", "[P2-246] DC${addrSet.dcId}: registered ${schemes.size} address scheme(s) for failover")
    }
}

/**
 * 会话信息
 *
 * 对应 TelegramHarmony 的 MTProtoConfig.ets SessionInfo
 *
 * 线程安全（P2-242a r1 + r2 返修）：
 *   sessionLock 保护所有可变状态字段的临界区。
 *   每个访问器持短临界区，只包内存 RMW，不包 IO，不嵌套其它锁（叶子锁）。
 *
 *   r2 sweep 结论：
 *   - authKey / authKeyId：init 阶段单线程写（createAuthKey/migrateToDC）可接受；
 *     但 handleIncomingData -404 在接收线程也会清除这两个字段，而发送线程
 *     effectiveAuthKey()/activatePfs() 并发读 → 真实竞态。
 *     统一走 getAuthKey()/getAuthKeyId()/setAuthKey() 消除。
 *   - serverSalt：handleNewSession/handleBadServerSalt 已走 setServerSalt()；
 *     -404 裸清除已改为 clearServerSalt()。
 *   - seqNo / sessionId：generateMessageId/getNextSeqNo/generateSessionId/
 *     getSessionId/getServerSalt 均已 synchronized；exportSessionData 改用
 *     snapshotForPersist() 原子快照，消除读撕裂。
 *   - authKeyState：-404 清除已走 setAuthKeyState()；init 路径直接赋值可接受
 *     （单线程，未启动接收循环）。
 *   - isAuthenticated() 读 authKeyState：仅在 init 前检查或调试路径调用，
 *     尚无并发写者，暂不加锁；如后续在并发路径调用须走 synchronized getter。
 *   锁序：sessionLock 是叶子锁，内部不调用任何持锁方法，无死锁环。
 */
public class SessionInfo {
    public var dcId: Int64 = 1
    public var authKey: Option<Array<Byte>> = None
    public var authKeyId: Option<Array<Byte>> = None
    public var serverSalt: Option<Array<Byte>> = None
    public var sessionId: Option<Array<Byte>> = None
    public var seqNo: Int32 = 0
    public var lastMessageId: Int64 = 0
    public var authKeyState: AuthKeyState = AuthKeyState.None_
    public var isInitialized: Bool = false
    /** 派生会话（下载连接用）：不入注册表、绝不持久化。 */
    public var ephemeral: Bool = false

    // 保护所有 session 状态 RMW 的内部锁（短临界区，不含 IO，不与其它锁嵌套）
    private let sessionLock = ReentrantMutex()

    private static let _rand = Random()

    public init(dcId!: Int64 = 1) {
        this.dcId = dcId
    }

    /**
     * 原子生成新 sessionId（8 字节随机数组）。
     * sessionLock 保护写入，防并发重复覆盖。
     */
    public func generateSessionId() {
        let sid = Array<Byte>(8, repeat: 0)
        for (i in 0..8) {
            sid[i] = UInt8(_rand.nextUInt32() % 256)
        }
        synchronized(sessionLock) {
            this.sessionId = Some(sid)
        }
    }

    /**
     * 原子分配下一个消息 ID（lastMessageId 严格递增 RMW）。
     * synchronized(sessionLock) 保护整个 read-modify-write，消除并发重复 msgId 竞态。
     */
    public func generateMessageId(): Int64 {
        synchronized(sessionLock) {
            let now = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let seconds = now / 1000
            let nanoseconds = (now % 1000) * 1000000
            var msgId: Int64 = seconds * 4294967296 + nanoseconds

            if (msgId <= this.lastMessageId) {
                this.lastMessageId = this.lastMessageId + 4
            } else {
                this.lastMessageId = msgId
            }

            return this.lastMessageId
        }
    }

    /**
     * 原子获取下一个序列号（seqNo RMW）。
     * synchronized(sessionLock) 保护整个 read-modify-write，消除并发重复/错乱 seqNo 竞态。
     */
    public func getNextSeqNo(contentRelated: Bool): Int32 {
        synchronized(sessionLock) {
            var result = this.seqNo * 2
            if (contentRelated) {
                result += 1
                this.seqNo += 1
            }
            return result
        }
    }

    /**
     * 线程安全读取当前 sessionId（供 buildMessage 并发读）。
     */
    public func getSessionId(): Option<Array<Byte>> {
        synchronized(sessionLock) {
            return this.sessionId
        }
    }

    /**
     * 线程安全读取当前 serverSalt（供 buildMessage 并发读）。
     */
    public func getServerSalt(): Option<Array<Byte>> {
        synchronized(sessionLock) {
            return this.serverSalt
        }
    }

    /**
     * 线程安全写入 serverSalt（handleNewSession / handleBadServerSalt 并发写）。
     */
    public func setServerSalt(salt: Array<Byte>): Unit {
        synchronized(sessionLock) {
            this.serverSalt = Some(salt)
        }
    }

    /**
     * 线程安全清除 serverSalt（handleIncomingData -404 分支，接收线程写）。
     * 与 getServerSalt()/setServerSalt() 同锁，消除裸写 vs 加锁读竞态。
     */
    public func clearServerSalt(): Unit {
        synchronized(sessionLock) {
            this.serverSalt = None
        }
    }

    /**
     * 线程安全读取当前 seqNo（供 exportSessionData 并发持久化读）。
     */
    public func getSeqNo(): Int32 {
        synchronized(sessionLock) {
            return this.seqNo
        }
    }

    /**
     * 线程安全重置 seqNo 为 0（bad_msg error 32/33 seqno 越界时调用）。
     * 与 getNextSeqNo 持同一把 sessionLock，消除两把不同锁保护同一字段的数据竞争。
     */
    public func resetSeqNo(): Unit {
        synchronized(sessionLock) {
            this.seqNo = 0
        }
    }

    /**
     * bad_msg 32/33 自愈：整体换新 session（新 sessionId + seqNo 清零，
     * 对齐 iOS MTProto resetSessionInfo）。只重置 seqNo 不换 sessionId 会死循环——
     * 服务器按 sessionId 记录已见最高 seqNo，旧 session 里从 1 重来永远
     * "seqno out of range"（真机实锤：11:33 连环 bad_msg 32 致信令全断、呼叫对端不响铃）。
     */
    public func resetSession(): Unit {
        synchronized(sessionLock) {
            let sid = Array<Byte>(8, repeat: 0)
            for (i in 0..8) {
                sid[i] = UInt8(_rand.nextUInt32() % 256)
            }
            this.sessionId = Some(sid)
            this.seqNo = 0
        }
    }

    /**
     * 线程安全读取 authKey（供 decryptMessage 接收线程并发读）。
     */
    public func getAuthKey(): Option<Array<Byte>> {
        synchronized(sessionLock) {
            return this.authKey
        }
    }

    /**
     * 线程安全读取 authKeyId（供 effectiveAuthKey/encryptMessage 并发读）。
     */
    public func getAuthKeyId(): Option<Array<Byte>> {
        synchronized(sessionLock) {
            return this.authKeyId
        }
    }

    /**
     * 线程安全写入 authKey + authKeyId（init 单线程路径调用，无需加锁；
     * 但 -404 接收线程清除路径须走此方法，与并发读同锁）。
     */
    public func setAuthKey(key: Option<Array<Byte>>, keyId: Option<Array<Byte>>): Unit {
        synchronized(sessionLock) {
            this.authKey = key
            this.authKeyId = keyId
        }
    }

    /**
     * 线程安全写入 authKeyState（-404 接收线程写，与并发 isAuthenticated() 同锁）。
     */
    public func setAuthKeyState(state: AuthKeyState): Unit {
        synchronized(sessionLock) {
            this.authKeyState = state
        }
    }

    /**
     * 线程安全读取 authKeyState（供 exportSessionData 持久化路径）。
     */
    public func getAuthKeyState(): AuthKeyState {
        synchronized(sessionLock) {
            return this.authKeyState
        }
    }

    /**
     * 一致性快照：在单次 synchronized 内原子读取 serverSalt + sessionId + seqNo，
     * 供 exportSessionData 持久化路径使用，消除多次裸读之间的撕裂。
     *
     * 返回 (serverSalt, sessionId, seqNo)。
     */
    public func snapshotForPersist(): (Option<Array<Byte>>, Option<Array<Byte>>, Int32) {
        synchronized(sessionLock) {
            return (this.serverSalt, this.sessionId, this.seqNo)
        }
    }

    public func isAuthenticated(): Bool {
        return this.authKeyState == AuthKeyState.Created ||
               this.authKeyState == AuthKeyState.Registered
    }

    // -------------------------------------------------------------------------
    // selfCheck — 并发真断言：多线程并发调用 generateMessageId / getNextSeqNo，
    //   断言无重复 msgId、seqNo 严格递增无重复/无跳号。全程无网络。
    //   任何断言失败抛 Exception。
    //
    //   注意：仓颉 spawn 闭包不能捕获可变 var，因此用 class 对象持有可变状态
    //   （闭包捕获的是不可变的对象引用，通过对象字段间接持有可变数据）。
    // -------------------------------------------------------------------------
    public static func selfCheck(): Unit {
        // ===== 1. generateMessageId 并发唯一性 =====
        // 16 个线程各自调用 1000 次，共 16000 个 msgId，收集后断言无重复。
        let session = SessionInfo(dcId: 1)
        let N = 16
        let M = 1000

        // Box 对象持有可变状态，spawn 闭包捕获的是 let 绑定的对象引用
        let msgIdBox = SessionCheckBox_Int64Array(N * M)
        let doneMsgBox = SessionCheckBox_Counter()
        let msgMutex = ReentrantMutex()
        let doneMsgMutex = ReentrantMutex()

        for (t in 0..N) {
            let tIdx = t
            spawn {
                for (i in 0..M) {
                    let id = session.generateMessageId()
                    synchronized(msgMutex) {
                        msgIdBox.data[tIdx * M + i] = id
                    }
                }
                synchronized(doneMsgMutex) {
                    doneMsgBox.count += 1
                }
            }
        }

        // 轮询等待所有线程完成（最多 10s）
        let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
        var waited = false
        while (true) {
            var done = false
            synchronized(doneMsgMutex) {
                done = doneMsgBox.count == N
            }
            if (done) {
                waited = true
                break
            }
            let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - t0
            if (elapsed > 10000) {
                break
            }
        }
        if (!waited) {
            throw Exception("SessionInfo.selfCheck FAIL: concurrent generateMessageId threads did not finish in time")
        }

        // 断言无重复：放入 HashSet，size 必须等于 N*M
        var idSet = HashSet<Int64>()
        for (id in msgIdBox.data) {
            idSet.add(id)
        }
        if (idSet.size != N * M) {
            throw Exception("SessionInfo.selfCheck FAIL: generateMessageId produced duplicate msgIds under concurrency (unique=${idSet.size}, expected=${N * M})")
        }

        // ===== 2. getNextSeqNo 并发唯一性（contentRelated=true 路径）=====
        // 16 个线程各调 500 次，共 8000 次 contentRelated 调用，断言无重复且全为奇数。
        let session2 = SessionInfo(dcId: 1)
        let S = 8000
        let K = S / N

        let seqBox = SessionCheckBox_Int32Array(S)
        let doneSeqBox = SessionCheckBox_Counter()
        let seqMutex = ReentrantMutex()
        let doneSeqMutex = ReentrantMutex()

        for (t in 0..N) {
            let tIdx = t
            spawn {
                for (i in 0..K) {
                    let sn = session2.getNextSeqNo(true)
                    synchronized(seqMutex) {
                        seqBox.data[tIdx * K + i] = sn
                    }
                }
                synchronized(doneSeqMutex) {
                    doneSeqBox.count += 1
                }
            }
        }

        let t1 = DateTime.now().toUnixTimeStamp().toMilliseconds()
        var waited2 = false
        while (true) {
            var done2 = false
            synchronized(doneSeqMutex) {
                done2 = doneSeqBox.count == N
            }
            if (done2) {
                waited2 = true
                break
            }
            let elapsed2 = DateTime.now().toUnixTimeStamp().toMilliseconds() - t1
            if (elapsed2 > 10000) {
                break
            }
        }
        if (!waited2) {
            throw Exception("SessionInfo.selfCheck FAIL: concurrent getNextSeqNo threads did not finish in time")
        }

        // 断言无重复 seqNo
        var seqSet = HashSet<Int32>()
        for (sn in seqBox.data) {
            seqSet.add(sn)
        }
        if (seqSet.size != S) {
            throw Exception("SessionInfo.selfCheck FAIL: getNextSeqNo produced duplicate seqNo under concurrency (unique=${seqSet.size}, expected=${S})")
        }

        // 断言全部是奇数（contentRelated=true 时 result = 2k+1）
        for (sn in seqBox.data) {
            if (sn % 2 == 0) {
                throw Exception("SessionInfo.selfCheck FAIL: contentRelated getNextSeqNo must always return odd value, got ${sn}")
            }
        }

        // ===== 3. 单线程回归：generateMessageId 严格单调递增 =====
        let session3 = SessionInfo(dcId: 1)
        var prev: Int64 = 0
        for (_i in 0..100) {
            let id = session3.generateMessageId()
            if (id <= prev) {
                throw Exception("SessionInfo.selfCheck FAIL: generateMessageId not strictly increasing in single-thread: prev=${prev} cur=${id}")
            }
            prev = id
        }

        // ===== 4. 单线程回归：getNextSeqNo 语义验证 =====
        let session4 = SessionInfo(dcId: 1)
        let sn0 = session4.getNextSeqNo(false)
        let sn1 = session4.getNextSeqNo(false)
        if (sn0 != 0 || sn1 != 0) {
            throw Exception("SessionInfo.selfCheck FAIL: getNextSeqNo(false) must return 0 repeatedly when seqNo=0, got ${sn0}, ${sn1}")
        }
        let sn2 = session4.getNextSeqNo(true)
        if (sn2 != 1) {
            throw Exception("SessionInfo.selfCheck FAIL: first contentRelated getNextSeqNo must return 1, got ${sn2}")
        }
        let sn3 = session4.getNextSeqNo(true)
        if (sn3 != 3) {
            throw Exception("SessionInfo.selfCheck FAIL: second contentRelated getNextSeqNo must return 3, got ${sn3}")
        }

        // ===== 5. r2 新增：serverSalt 并发写/读无崩溃/无撕裂 =====
        // 模拟接收线程反复 setServerSalt/clearServerSalt，同时发送线程反复 getServerSalt/getSeqNo。
        // 断言：不崩溃，getServerSalt 读到的值始终是 None 或 8字节数组（无撕裂中间态）。
        let session5 = SessionInfo(dcId: 1)
        let RWROUNDS = 2000
        let saltError5Box = SessionCheckBox_Counter()
        let doneWrite5Box = SessionCheckBox_Counter()
        let doneRead5Box = SessionCheckBox_Counter()
        let errMutex5 = ReentrantMutex()
        let doneW5Mutex = ReentrantMutex()
        let doneR5Mutex = ReentrantMutex()

        // 写线程：交替 set/clear
        spawn {
            let fakeSalt = Array<Byte>(8, repeat: 0xAB)
            for (_i in 0..RWROUNDS) {
                session5.setServerSalt(fakeSalt)
                session5.clearServerSalt()
            }
            synchronized(doneW5Mutex) {
                doneWrite5Box.count += 1
            }
        }

        // 读线程：并发读，断言拿到的不是奇异长度
        spawn {
            for (_i in 0..RWROUNDS) {
                match (session5.getServerSalt()) {
                    case Some(s) =>
                        if (s.size != 8) {
                            synchronized(errMutex5) {
                                saltError5Box.count += 1
                            }
                        }
                    case None => ()
                }
            }
            synchronized(doneR5Mutex) {
                doneRead5Box.count += 1
            }
        }

        let t5 = DateTime.now().toUnixTimeStamp().toMilliseconds()
        var waited5w = false
        var waited5r = false
        while (true) {
            var dw = false
            synchronized(doneW5Mutex) { dw = doneWrite5Box.count == 1 }
            if (dw) { waited5w = true; break }
            if (DateTime.now().toUnixTimeStamp().toMilliseconds() - t5 > 10000) { break }
        }
        while (true) {
            var dr = false
            synchronized(doneR5Mutex) { dr = doneRead5Box.count == 1 }
            if (dr) { waited5r = true; break }
            if (DateTime.now().toUnixTimeStamp().toMilliseconds() - t5 > 15000) { break }
        }
        if (!waited5w || !waited5r) {
            throw Exception("SessionInfo.selfCheck FAIL: serverSalt concurrent rw threads did not finish in time")
        }
        var errCount5 = 0
        synchronized(errMutex5) { errCount5 = saltError5Box.count }
        if (errCount5 > 0) {
            throw Exception("SessionInfo.selfCheck FAIL: getServerSalt returned torn value (size != 8) under concurrency, count=${errCount5}")
        }

        // ===== 6. r2 新增：setAuthKey/getAuthKey 并发写/读无崩溃 =====
        let session6 = SessionInfo(dcId: 1)
        let AKREADS = 2000
        let akErrBox = SessionCheckBox_Counter()
        let doneAkW6Box = SessionCheckBox_Counter()
        let doneAkR6Box = SessionCheckBox_Counter()
        let akErrMutex = ReentrantMutex()
        let doneAkW6Mutex = ReentrantMutex()
        let doneAkR6Mutex = ReentrantMutex()

        // 写线程：交替 setAuthKey(Some(...), Some(...)) / setAuthKey(None, None)（模拟 -404）
        spawn {
            let fakeKey = Array<Byte>(256, repeat: 0x11)
            let fakeKeyId = Array<Byte>(8, repeat: 0x22)
            for (_i in 0..AKREADS) {
                session6.setAuthKey(Some(fakeKey), Some(fakeKeyId))
                session6.setAuthKey(None, None)
            }
            synchronized(doneAkW6Mutex) {
                doneAkW6Box.count += 1
            }
        }

        // 读线程：getAuthKey，断言拿到的是 None 或非空数组（无撕裂）
        spawn {
            for (_i in 0..AKREADS) {
                match (session6.getAuthKey()) {
                    case Some(ak) =>
                        if (ak.size == 0) {
                            synchronized(akErrMutex) { akErrBox.count += 1 }
                        }
                    case None => ()
                }
            }
            synchronized(doneAkR6Mutex) {
                doneAkR6Box.count += 1
            }
        }

        let t6 = DateTime.now().toUnixTimeStamp().toMilliseconds()
        var waited6w = false
        var waited6r = false
        while (true) {
            var dw6 = false
            synchronized(doneAkW6Mutex) { dw6 = doneAkW6Box.count == 1 }
            if (dw6) { waited6w = true; break }
            if (DateTime.now().toUnixTimeStamp().toMilliseconds() - t6 > 10000) { break }
        }
        while (true) {
            var dr6 = false
            synchronized(doneAkR6Mutex) { dr6 = doneAkR6Box.count == 1 }
            if (dr6) { waited6r = true; break }
            if (DateTime.now().toUnixTimeStamp().toMilliseconds() - t6 > 15000) { break }
        }
        if (!waited6w || !waited6r) {
            throw Exception("SessionInfo.selfCheck FAIL: authKey concurrent rw threads did not finish in time")
        }
        var akErrCount = 0
        synchronized(akErrMutex) { akErrCount = akErrBox.count }
        if (akErrCount > 0) {
            throw Exception("SessionInfo.selfCheck FAIL: getAuthKey returned torn empty array under concurrency, count=${akErrCount}")
        }

        Hilog.info(0, "CjTelegram",
            "[SessionInfo] selfCheck PASS: generateMessageId/getNextSeqNo thread-safe (no dup msgId/seqNo under concurrency, single-thread monotonic regression); serverSalt/authKey concurrent rw safe (r2)")
    }
}

// ---- selfCheck 辅助 Box 类型（仓颉 spawn 闭包不能捕获 var，用 class 对象包装可变状态）----

class SessionCheckBox_Int64Array {
    public var data: Array<Int64>
    public init(size: Int64) {
        this.data = Array<Int64>(size, repeat: 0)
    }
}

class SessionCheckBox_Int32Array {
    public var data: Array<Int32>
    public init(size: Int64) {
        this.data = Array<Int32>(size, repeat: 0)
    }
}

class SessionCheckBox_Counter {
    public var count: Int64 = 0
}

/**
 * 会话数据（用于持久化）
 */
public class SessionData {
    public var dcId: Int64 = 0
    public var authKey: Option<String> = None     // Base64 encoded
    public var authKeyId: Option<String> = None    // Base64 encoded
    public var serverSalt: Option<String> = None   // Base64 encoded
    public var sessionId: Option<String> = None    // Base64 encoded
    public var seqNo: Int32 = 0
    public var authKeyState: Int32 = 0
}

/**
 * 会话管理器
 * 
 * 对应 TelegramHarmony 的 MTProtoConfig.ets SessionManager
 */
public class SessionManager {
    private static var sessions = HashMap<Int64, SessionInfo>()
    private static var sessionLoaded: Bool = false
    private static var persistCallback: Option<(SessionInfo) -> Unit> = None
    private static var loadCallback: Option<() -> Option<SessionData>> = None

    public static func setPersistCallback(callback: (SessionInfo) -> Unit) {
        persistCallback = Some(callback)
    }

    public static func setLoadCallback(callback: () -> Option<SessionData>) {
        loadCallback = Some(callback)
    }

    public static func getSession(dcId: Int64): SessionInfo {
        if (sessions.contains(dcId)) {
            return sessions[dcId]
        }
        let session = SessionInfo(dcId: dcId)
        session.generateSessionId()
        sessions[dcId] = session
        return session
    }

    /**
     * 派生会话（下载连接专用）：共享主会话的 authKey/salt，但持有**独立的
     * sessionId / seqNo / msgId 计数**——MTProto 允许同一 authKey 多会话并行。
     * 动机：单 TCP 上 6×512KB 的 getFile 分片响应会把小 RPC 回复压在队尾
     *（接收侧队头阻塞），下载走独立连接后 RPC 不再排队（iOS media 连接对位）。
     * 不入 sessions 注册表、ephemeral 标记保证绝不持久化。
     */
    public static func getDetachedSession(dcId: Int64): SessionInfo {
        let base = getSession(dcId)
        let s = SessionInfo(dcId: dcId)
        s.authKey = base.getAuthKey()
        s.authKeyId = base.authKeyId
        s.serverSalt = base.serverSalt
        s.authKeyState = base.authKeyState
        s.ephemeral = true
        s.generateSessionId()
        return s
    }

    public static func restoreSession(dcId: Int64): Option<SessionInfo> {
        // 如果已经在内存中有有效会话
        if (sessions.contains(dcId)) {
            let existing = sessions[dcId]
            match (existing.authKey) {
                case Some(key) where key.size > 0 =>
                    return Some(existing)
                case _ => ()
            }
        }

        // 尝试从持久化存储加载
        if (!sessionLoaded) {
            match (loadCallback) {
                case Some(loader) =>
                    match (loader()) {
                        case Some(data) where data.dcId == dcId =>
                            match (data.authKey) {
                                case Some(authKeyB64) =>
                                    let session = SessionInfo(dcId: dcId)
                                    session.authKey = Some(Base64.decode(authKeyB64))
                                    match (data.authKeyId) {
                                        case Some(akId) => session.authKeyId = Some(Base64.decode(akId))
                                        case None => ()
                                    }
                                    match (data.serverSalt) {
                                        case Some(ss) => session.serverSalt = Some(Base64.decode(ss))
                                        case None => ()
                                    }
                                    session.authKeyState = authKeyStateFromInt(data.authKeyState)
                                    session.seqNo = 0
                                    session.generateSessionId()
                                    sessions[dcId] = session
                                    sessionLoaded = true
                                    return Some(session)
                                case None => ()
                            }
                        case _ => ()
                    }
                case None => ()
            }
        }

        sessionLoaded = true
        return None
    }

    public static func saveSession(session: SessionInfo) {
        // 派生会话绝不落注册表/磁盘：会顶掉主会话的 salt/sessionId。
        if (session.ephemeral) { return }
        sessions[session.dcId] = session
        match (persistCallback) {
            case Some(callback) =>
                // P2-242a r2：走线程安全 getter 读 authKey（与 -404 setAuthKey 同锁保护）
                match (session.getAuthKey()) {
                    case Some(_) => callback(session)
                    case None => ()
                }
            case None => ()
        }
    }

    public static func clearAllSessions() {
        sessions = HashMap<Int64, SessionInfo>()
        sessionLoaded = false
    }

    /**
     * 导出持久化数据（P2-242a r2 返修）。
     *
     * serverSalt / sessionId / seqNo 三个可变字段通过 snapshotForPersist() 在单次
     * synchronized 内原子读取，消除多次裸读之间的撕裂（并发 setServerSalt/getNextSeqNo 与
     * 本方法读路径的竞态）。
     *
     * authKey / authKeyId 同样走线程安全 getter 读取，消除 -404 接收线程裸写 vs 本路径裸读竞态。
     */
    public static func exportSessionData(session: SessionInfo): SessionData {
        let data = SessionData()
        data.dcId = session.dcId

        // authKey / authKeyId：走线程安全 getter，消除 -404 裸写 vs 本读并发竞态
        match (session.getAuthKey()) {
            case Some(ak) => data.authKey = Some(Base64.encode(ak))
            case None => ()
        }
        match (session.getAuthKeyId()) {
            case Some(akId) => data.authKeyId = Some(Base64.encode(akId))
            case None => ()
        }

        // serverSalt / sessionId / seqNo：单次 synchronized 内原子快照，消除撕裂
        let (saltOpt, sidOpt, seqNoVal) = session.snapshotForPersist()
        match (saltOpt) {
            case Some(ss) => data.serverSalt = Some(Base64.encode(ss))
            case None => ()
        }
        match (sidOpt) {
            case Some(sid) => data.sessionId = Some(Base64.encode(sid))
            case None => ()
        }
        data.seqNo = seqNoVal

        // authKeyState：走线程安全 getter，消除 -404 setAuthKeyState 与本读路径的竞态（彻底sweep）
        data.authKeyState = authKeyStateToInt(session.getAuthKeyState())
        return data
    }
}

func authKeyStateToInt(state: AuthKeyState): Int32 {
    match (state) {
        case AuthKeyState.None_ => 0
        case AuthKeyState.Creating => 1
        case AuthKeyState.Created => 2
        case AuthKeyState.Registered => 3
    }
}

func authKeyStateFromInt(value: Int32): AuthKeyState {
    match (value) {
        case 0 => AuthKeyState.None_
        case 1 => AuthKeyState.Creating
        case 2 => AuthKeyState.Created
        case 3 => AuthKeyState.Registered
        case _ => AuthKeyState.None_
    }
}

/**
 * Base64 编解码工具
 */
public class Base64 {
    private static let CHARS: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    public static func encode(data: Array<Byte>): String {
        let chars = CHARS.toRuneArray()
        var result = ""
        let len = data.size
        var i: Int64 = 0
        while (i < len) {
            let a = UInt32(UInt8(data[i]))
            let b: UInt32 = if (i + 1 < len) { UInt32(UInt8(data[i + 1])) } else { 0 }
            let c: UInt32 = if (i + 2 < len) { UInt32(UInt8(data[i + 2])) } else { 0 }

            let bitmap = (a << 16) | (b << 8) | c

            result += String(chars[Int64((bitmap >> 18) & 63)])
            result += String(chars[Int64((bitmap >> 12) & 63)])
            result += if (i + 1 < len) { String(chars[Int64((bitmap >> 6) & 63)]) } else { "=" }
            result += if (i + 2 < len) { String(chars[Int64(bitmap & 63)]) } else { "=" }

            i += 3
        }
        return result
    }

    /**
     * Base64URL 编码（用于 tg://login?token=xxx，无填充，- 和 _ 替代 + 和 /）
     */
    public static func encodeBase64Url(data: Array<Byte>): String {
        let standard = encode(data)
        var result = ""
        for (ch in standard.toRuneArray()) {
            let s = String(ch)
            if (s == "+") {
                result += "-"
            } else if (s == "/") {
                result += "_"
            } else if (s != "=") {
                result += s
            }
        }
        return result
    }

    /**
     * Base64URL 解码（- 和 _ 转回 + 和 / 后解码）
     */
    public static func decodeBase64Url(input: String): Array<Byte> {
        var normalized = ""
        for (ch in input.toRuneArray()) {
            let s = String(ch)
            if (s == "-") {
                normalized += "+"
            } else if (s == "_") {
                normalized += "/"
            } else {
                normalized += s
            }
        }
        let padLen = 4 - (normalized.size % 4)
        if (padLen < 4) {
            for (_i in 0..padLen) {
                normalized += "="
            }
        }
        return decode(normalized)
    }

    public static func decode(base64: String): Array<Byte> {
        let chars = CHARS.toRuneArray()
        var padding: Int64 = 0
        if (base64.endsWith("==")) {
            padding = 2
        } else if (base64.endsWith("=")) {
            padding = 1
        }

        let rawLen = base64.size
        let outLen = (rawLen * 3 / 4) - padding
        let result = Array<Byte>(outLen, repeat: 0)
        let inputChars = base64.toRuneArray()

        var j: Int64 = 0
        var i: Int64 = 0
        while (i < rawLen && j < outLen) {
            let c0 = inputChars[i]
            let c1 = inputChars[i + 1]
            let c2 = inputChars[i + 2]
            let c3 = inputChars[i + 3]

            let a = charIndex(chars, c0)
            let b = charIndex(chars, c1)
            let c = if (String(c2) == "=") { 0 } else { charIndex(chars, c2) }
            let d = if (String(c3) == "=") { 0 } else { charIndex(chars, c3) }

            let bitmap = (a << 18) | (b << 12) | (c << 6) | d

            if (j < outLen) {
                result[j] = UInt8((bitmap >> 16) & 0xFF)
                j++
            }
            if (j < outLen && String(c2) != "=") {
                result[j] = UInt8((bitmap >> 8) & 0xFF)
                j++
            }
            if (j < outLen && String(c3) != "=") {
                result[j] = UInt8(bitmap & 0xFF)
                j++
            }

            i += 4
        }
        return result
    }

    private static func charIndex(chars: Array<Rune>, ch: Rune): Int64 {
        for (i in 0..chars.size) {
            if (chars[i] == ch) {
                return i
            }
        }
        return 0
    }
}

// ==================== S7-131: initConnection device_model / system_version ====================
// iOS MTApiEnvironment.m:372-381 sends the hardware model name (e.g. "iPhone 17 Pro") and the OS
// version, which the server echoes back in account.getAuthorizations (Devices → session rows).
// HarmonyOS equivalent: deviceInfo.marketName (fallback productModel) and the distribution OS
// name + version. Falls back to the static values when the system properties are unavailable.
private var _initConnectionDeviceModel: String = ""
private var _initConnectionSystemVersion: String = ""

public func initConnectionDeviceModel(): String {
    if (_initConnectionDeviceModel.size > 0) { return _initConnectionDeviceModel }
    var model = ""
    try {
        model = DeviceInfo.marketName.trimAscii()
        if (model.size == 0) { model = DeviceInfo.productModel.trimAscii() }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[MTProtoConfig] deviceInfo model unavailable: ${e}")
    }
    _initConnectionDeviceModel = if (model.size > 0) { model } else { MTProtoConfig.DEVICE_MODEL }
    return _initConnectionDeviceModel
}

public func initConnectionSystemVersion(): String {
    if (_initConnectionSystemVersion.size > 0) { return _initConnectionSystemVersion }
    var version = ""
    try {
        let name = DeviceInfo.distributionOSName.trimAscii()
        let ver = DeviceInfo.distributionOSVersion.trimAscii()
        if (name.size > 0 && ver.size > 0) {
            version = if (ver.startsWith(name)) { ver } else { name + " " + ver }
        } else {
            version = DeviceInfo.osFullName.trimAscii()
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[MTProtoConfig] deviceInfo version unavailable: ${e}")
    }
    _initConnectionSystemVersion = if (version.size > 0) { version } else { MTProtoConfig.SYSTEM_VERSION }
    return _initConnectionSystemVersion
}
