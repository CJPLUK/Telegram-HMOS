package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{
    TLObject,
    TLDeserializer,
    TLConstructors,
    getMTProtoClient,
    PaymentsGetStarsRevenueStats
}

// ==================== P2-369: Stars 收入统计数据模型 ====================

/**
 * Stars 余额与收入状态（对应 iOS Api.StarsRevenueStatus / Cons_starsRevenueStatus）
 * TL: starsRevenueStatus#febe5491
 *   flags:# current_balance:StarsAmount available_balance:StarsAmount
 *   overall_revenue:StarsAmount next_withdrawal_at:flags.1?int
 *
 * iOS ref: Api27.swift parse_starsRevenueStatus (Api27.swift:1434-1464)
 *
 * StarsAmount:
 *   starsAmount#bbb6b4a3 amount:long nanos:int
 *   starsTonAmount (amount:long)
 */
public class StarsRevenueStatusData {
    public var currentBalance: Int64 = 0
    public var availableBalance: Int64 = 0
    public var overallRevenue: Int64 = 0
    public var nextWithdrawalAt: Int32 = 0
    public var hasNextWithdrawal: Bool = false

    public init() {}
}

/**
 * Stars 收入统计（对应 iOS payments.StarsRevenueStats / Cons_starsRevenueStats）
 * TL: starsRevenueStats#6c207376
 *   flags:# top_hours_graph:flags.0?StatsGraph revenue_graph:StatsGraph
 *   status:StarsRevenueStatus usd_rate:double
 *
 * iOS ref: Api39.swift Cons_starsRevenueStats (Api39.swift:725-800)
 */
public class StarsRevenueStatsData {
    public var status: StarsRevenueStatusData = StarsRevenueStatusData()
    public var usdRate: Float64 = 0.0
    public var isLoaded: Bool = false

    public init() {}
}

// ==================== StarsRevenueService ====================

private var _starsRevenueServiceInstance: Option<StarsRevenueService> = None

public func getStarsRevenueService(): StarsRevenueService {
    match (_starsRevenueServiceInstance) {
        case Some(s) => s
        case None =>
            let s = StarsRevenueService()
            _starsRevenueServiceInstance = Some(s)
            s
    }
}

/**
 * Stars 收入统计服务
 *
 * 封装 payments.getStarsRevenueStats 的 TL 调用和解析。
 * 对应 iOS Engine StarsRevenue 相关逻辑。
 *
 * 调用链：
 *   StarsRevenueService.getStarsRevenueStats(peerType, peerId)
 *     → getRealMessageService().buildInputPeer(peerType, peerId)
 *     → PaymentsGetStarsRevenueStats.toBytes()  [0xd91ffad6]
 *     → getMTProtoClient().sendRequest()
 *     → 解析 starsRevenueStats#6c207376
 *     → 提取 starsRevenueStatus#febe5491 (balance / available / overall)
 *     → StarsRevenueStatsData
 */
public class StarsRevenueService {

    /**
     * 获取 Stars 收入统计数据（余额 + 收入图表状态）
     * TL 方法：payments.getStarsRevenueStats (0xd91ffad6)
     * 响应：payments.starsRevenueStats#6c207376
     *
     * @param peerType  "channel"
     * @param peerId    频道 ID
     * @return StarsRevenueStatsData
     */
    public func getStarsRevenueStats(peerType: String, peerId: Int64): StarsRevenueStatsData {
        Hilog.info(0, "CjTelegram", "[StarsRevenueService] getStarsRevenueStats peerId=${peerId}")
        let result = StarsRevenueStatsData()

        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let req = PaymentsGetStarsRevenueStats()
        req.dark = false
        req.peer = inputPeer

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[StarsRevenueService] getStarsRevenueStats: empty response")
            return result
        }

        let deser = TLDeserializer(responseData)
        let ctor = deser.readUInt32()

        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errCode = deser.readInt32()
            let errMsg = deser.readString()
            Hilog.info(0, "CjTelegram", "[StarsRevenueService] getStarsRevenueStats RPC error: ${errCode} - ${errMsg}")
            return result
        }

        // payments.starsRevenueStats#6c207376
        if (ctor == 0x6c207376) {
            this.parseStarsRevenueStats(deser, result)
            result.isLoaded = true
            Hilog.info(0, "CjTelegram", "[StarsRevenueService] getStarsRevenueStats ok current=${result.status.currentBalance} available=${result.status.availableBalance} overall=${result.status.overallRevenue}")
        } else {
            Hilog.info(0, "CjTelegram", "[StarsRevenueService] getStarsRevenueStats unknown ctor=0x${ctor}")
        }
        return result
    }

    // ==================== 内部解析方法 ====================

    /**
     * 解析 starsRevenueStats#6c207376（不含头部 ctor）
     * 字段序列化顺序（Api39.swift Cons_starsRevenueStats.serialize）：
     *   flags:int
     *   top_hours_graph:flags.0?StatsGraph(boxed)  (skip)
     *   revenue_graph:StatsGraph(boxed)             (skip)
     *   status:StarsRevenueStatus(boxed)            (parse)
     *   usd_rate:double                             (read)
     */
    private func parseStarsRevenueStats(deser: TLDeserializer, result: StarsRevenueStatsData) {
        try {
            let flags = deser.readInt32()

            // top_hours_graph:flags.0?StatsGraph — skip if present
            if ((flags & 1) != 0) {
                this.skipStatsGraph(deser)
            }
            // revenue_graph:StatsGraph (mandatory) — skip (chart data not used in UI)
            this.skipStatsGraph(deser)

            // status:StarsRevenueStatus(boxed) — parse
            let statusCtor = deser.readUInt32()
            if (statusCtor == 0xfebe5491) {
                this.parseStarsRevenueStatus(deser, result.status)
            } else {
                Hilog.info(0, "CjTelegram", "[StarsRevenueService] unexpected status ctor=0x${statusCtor}")
            }

            // usd_rate:double
            if (deser.remaining() >= 8) {
                result.usdRate = deser.readDouble()
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[StarsRevenueService] parseStarsRevenueStats error: ${e}")
        }
    }

    /**
     * 解析 starsRevenueStatus#febe5491（不含头部 ctor，已由调用者消费）
     * 字段序列化顺序（Api27.swift Cons_starsRevenueStatus.serialize）：
     *   flags:int
     *   current_balance:StarsAmount(boxed)
     *   available_balance:StarsAmount(boxed)
     *   overall_revenue:StarsAmount(boxed)
     *   next_withdrawal_at:flags.1?int
     */
    private func parseStarsRevenueStatus(deser: TLDeserializer, status: StarsRevenueStatusData) {
        let flags = deser.readInt32()
        status.currentBalance = this.readStarsAmount(deser)
        status.availableBalance = this.readStarsAmount(deser)
        status.overallRevenue = this.readStarsAmount(deser)
        // next_withdrawal_at:flags.1?int
        if ((flags & 2) != 0 && deser.remaining() >= 4) {
            status.nextWithdrawalAt = deser.readInt32()
            status.hasNextWithdrawal = true
        }
    }

    /**
     * 读取 StarsAmount (boxed) → Int64 金额
     * starsAmount#bbb6b4a3: amount:long nanos:int  → 返回 amount
     * 其他变体（如 starsTonAmount）：amount:long → 返回 amount
     */
    private func readStarsAmount(deser: TLDeserializer): Int64 {
        if (deser.remaining() < 4) { return 0 }
        let amtCtor = deser.readUInt32()
        if (amtCtor == 0xbbb6b4a3) {
            // starsAmount#bbb6b4a3: amount:long nanos:int
            let amt = if (deser.remaining() >= 8) { deser.readInt64() } else { 0 }
            if (deser.remaining() >= 4) { let _ = deser.readInt32() }  // nanos
            return amt
        } else {
            // starsTonAmount or unknown: amount:long
            return if (deser.remaining() >= 8) { deser.readInt64() } else { 0 }
        }
    }

    /**
     * 跳过 StatsGraph (boxed)
     * statsGraphAsync#4a27eb2d token:string
     * statsGraphError#bedc9822 error:string
     * statsGraph#8ea464b6 flags:int json:DataJSON zoom_token:flags.0?string
     * DataJSON#7d748d04 data:string
     */
    private func skipStatsGraph(deser: TLDeserializer) {
        if (deser.remaining() < 4) { return }
        let c = deser.readUInt32()
        if (c == 0x4a27eb2d) {
            // statsGraphAsync: token:string
            if (deser.remaining() >= 4) { let _ = deser.readString() }
        } else if (c == 0xbedc9822) {
            // statsGraphError: error:string
            if (deser.remaining() >= 4) { let _ = deser.readString() }
        } else {
            // statsGraph#8ea464b6: flags:int json:DataJSON zoom_token:flags.0?string
            if (deser.remaining() < 4) { return }
            let graphFlags = deser.readInt32()
            // json: DataJSON#7d748d04 data:string
            if (deser.remaining() >= 4) {
                let jsonCtor = deser.readUInt32()
                let _ = jsonCtor
                if (deser.remaining() >= 4) { let _ = deser.readString() }
            }
            if ((graphFlags & 1) != 0 && deser.remaining() >= 4) {
                let _ = deser.readString()  // zoom_token
            }
        }
    }
}
