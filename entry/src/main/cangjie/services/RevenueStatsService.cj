package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{
    TLObject,
    TLDeserializer,
    TLConstructors,
    getMTProtoClient,
    PaymentsGetStarsRevenueStats,
    PaymentsGetStarsRevenueWithdrawalUrl,
    PaymentsGetStarsRevenueAdsAccountUrl,
    InputCheckPasswordSRP,
    parseStarsRevenueStats,
    parseStarsRevenueWithdrawalUrl,
    parseStarsRevenueAdsAccountUrl
}

// ==================== P2-368: TON 广告收入数据模型 ====================

/**
 * TON 广告收入余额信息
 *
 * 对应 iOS StarsRevenueStats.Balances (ton=true 模式):
 *   currentBalance   → 已赚取但未提现的 TON 余额（整数，单位 nanoTON）
 *   availableBalance → 当前可提现的 TON 余额
 *   overallRevenue   → 历史累计收入
 *   withdrawEnabled  → starsRevenueStatus#febe5491 flags.0 — 提现是否开启
 *   nextWithdrawalAt → flags.1?int — 冷却锁到期时间戳（0 = 无冷却）
 *
 * TL: starsRevenueStatus#febe5491
 *   flags:#
 *   withdrawal_enabled:flags.0?true
 *   current_balance:StarsAmount  available_balance:StarsAmount  overall_revenue:StarsAmount
 *   next_withdrawal_at:flags.1?int
 *
 * iOS ref: StarsRevenueStatistics.swift Balances struct (L22-88);
 *          Api27.swift Cons_starsRevenueStatus (L1395-1422)
 */
public class TonRevenueBalances {
    public var currentBalance: Int64 = 0
    public var availableBalance: Int64 = 0
    public var overallRevenue: Int64 = 0
    public var withdrawEnabled: Bool = false
    public var nextWithdrawalAt: Int32 = 0
    public var hasNextWithdrawalAt: Bool = false

    public init() {}
}

/**
 * TON 广告收入统计全量数据
 *
 * TL: payments.starsRevenueStats#6c207376
 *   flags:# top_hours_graph:flags.0?StatsGraph revenue_graph:StatsGraph
 *   status:StarsRevenueStatus usd_rate:double
 *
 * iOS ref: StarsRevenueStats struct (StarsRevenueStatistics.swift L7-133)
 */
public class TonRevenueStats {
    public var balances: TonRevenueBalances = TonRevenueBalances()
    public var usdRate: Float64 = 0.0
    public var isLoaded: Bool = false

    public init() {}
}

/**
 * TON 提现请求结果
 */
public class TonWithdrawalResult {
    public var success: Bool = false
    public var url: String = ""
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""
    public var errorKind: TonWithdrawalErrorKind = TonWithdrawalErrorKind.Generic

    public init() {}
}

/**
 * 提现错误类型
 * 对应 iOS RequestStarsRevenueWithdrawalError (StarsRevenueStatistics.swift L360-369)
 */
public enum TonWithdrawalErrorKind {
    | Generic
    | PasswordMissing
    | PasswordInvalid
    | TwoFARequired
    | CooldownActive
    | Flood
}

// ==================== RevenueStatsService 单例 ====================

private var _revenueStatsServiceInstance: Option<RevenueStatsService> = None

public func getRevenueStatsService(): RevenueStatsService {
    match (_revenueStatsServiceInstance) {
        case Some(s) => s
        case None =>
            let s = RevenueStatsService()
            _revenueStatsServiceInstance = Some(s)
            s
    }
}

/**
 * TON 广告收入统计服务 (P2-368)
 *
 * 封装三个 TL 调用：
 *   1. payments.getStarsRevenueStats (ton=true, flags bit 1) → TON 余额卡
 *   2. payments.getStarsRevenueWithdrawalUrl (ton=true, flags bit 0 + SRP) → 提现 URL
 *   3. payments.getStarsRevenueAdsAccountUrl → Buy Ads 入口 URL
 *
 * 对应 iOS：
 *   - StarsRevenueStatsContext(ton: true) in StarsRevenueStatistics.swift
 *   - _internal_requestStarsRevenueWithdrawalUrl(ton: true, ...) ibid
 *   - _internal_requestStarsRevenueAdsAccountlUrl ibid
 *
 * 调用链（ChannelRevenueStatsPage → RevenueStatsService → getMTProtoClient）：
 *   aboutToAppear()
 *     → getTonRevenueStats(peerType, peerId)
 *       → PaymentsGetStarsRevenueStats(ton=true) [0xd91ffad6 flags|=2]
 *       → parseStarsRevenueStats(responseData)
 *       → TonRevenueStats {balances, usdRate}
 *
 *   onWithdrawTap(srpId, A, M1, amount)
 *     → requestWithdrawalUrl(peerType, peerId, srpId, A, M1, amount)
 *       → PaymentsGetStarsRevenueWithdrawalUrl(ton=true) [0x2433dc92 flags bit 0]
 *       → parseStarsRevenueWithdrawalUrl(responseData)
 *       → TonWithdrawalResult {success, url}
 *
 *   onBuyAdsTap()
 *     → getAdsAccountUrl(peerType, peerId)
 *       → PaymentsGetStarsRevenueAdsAccountUrl [0xd1d7efc5]
 *       → parseStarsRevenueAdsAccountUrl(responseData)
 *       → url: String
 */
public class RevenueStatsService {

    // ── getTonRevenueStats ───────────────────────────────────────────────────

    /**
     * 获取 TON 广告收入统计（余额卡数据）
     *
     * TL: payments.getStarsRevenueStats#d91ffad6 flags:# peer:InputPeer
     *   flags bit 1 set → ton=true
     *   iOS ref: StarsRevenueStatistics.swift L186 flags |= (1 << 1)
     *
     * @param peerType  "channel"
     * @param peerId    频道 ID
     * @return TonRevenueStats（isLoaded=false 表示请求失败）
     */
    public func getTonRevenueStats(peerType: String, peerId: Int64): TonRevenueStats {
        Hilog.info(0, "CjTelegram", "[RevenueStatsService] getTonRevenueStats peerId=${peerId}")
        let result = TonRevenueStats()

        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let req = PaymentsGetStarsRevenueStats()
        req.ton = true
        req.dark = false
        req.peer = inputPeer

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[RevenueStatsService] getTonRevenueStats: empty response")
            return result
        }

        let parsed = parseStarsRevenueStats(responseData)
        if (!parsed.success) {
            Hilog.info(0, "CjTelegram", "[RevenueStatsService] getTonRevenueStats RPC error: ${parsed.errorCode} - ${parsed.errorMessage}")
            return result
        }

        result.balances.currentBalance = parsed.currentBalanceAmount
        result.balances.availableBalance = parsed.availableBalanceAmount
        result.balances.overallRevenue = parsed.overallRevenueAmount
        result.balances.withdrawEnabled = parsed.withdrawalEnabled
        result.balances.nextWithdrawalAt = parsed.nextWithdrawalAt
        result.balances.hasNextWithdrawalAt = parsed.hasNextWithdrawalAt
        result.usdRate = parsed.usdRate
        result.isLoaded = true

        Hilog.info(0, "CjTelegram", "[RevenueStatsService] getTonRevenueStats ok current=${result.balances.currentBalance} available=${result.balances.availableBalance} withdrawEnabled=${result.balances.withdrawEnabled}")
        return result
    }

    // ── requestWithdrawalUrl ─────────────────────────────────────────────────

    /**
     * 请求 TON 提现 URL（需要 SRP 密码验证）
     *
     * TL: payments.getStarsRevenueWithdrawalUrl#2433dc92
     *   flags:# peer:InputPeer amount:flags.1?long password:InputCheckPasswordSRP
     *   flags bit 0 = ton=true
     *   iOS ref: StarsRevenueStatistics.swift L424 flags |= 1 << 0 when ton=true
     *
     * SRP 说明: 调用方（UI 层）负责：
     *   1. account.getPassword → 拿到 SRP session 参数
     *   2. 本地执行 passwordKDF(password, derivation, srpSessionData) → kdfResult(id, A, M1)
     *   3. 调用本方法传入 (srpId=kdfResult.id, srpA=kdfResult.A, srpM1=kdfResult.M1)
     *   → 不在 service 层重造 SRP 密码学，复用已有的 auth/2FA 路径
     *   iOS ref: _internal_requestStarsRevenueWithdrawalUrl (StarsRevenueStatistics.swift L394-465)
     *
     * @param peerType  "channel"
     * @param peerId    频道 ID
     * @param srpId     SRP session id（来自 account.getPassword response）
     * @param srpA      SRP A 参数（本地 passwordKDF 计算结果）
     * @param srpM1     SRP M1 验证值
     * @param amount    提现金额（0 = 全部可用余额）
     * @return TonWithdrawalResult
     */
    public func requestWithdrawalUrl(
        peerType: String, peerId: Int64,
        srpId: Int64, srpA: Array<Byte>, srpM1: Array<Byte>,
        amount: Int64
    ): TonWithdrawalResult {
        Hilog.info(0, "CjTelegram", "[RevenueStatsService] requestWithdrawalUrl peerId=${peerId} amount=${amount}")
        let result = TonWithdrawalResult()

        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let srp = InputCheckPasswordSRP()
        srp.srpId = srpId
        srp.srpA = srpA
        srp.srpM1 = srpM1

        let req = PaymentsGetStarsRevenueWithdrawalUrl()
        req.ton = true
        req.peer = inputPeer
        req.hasAmount = amount > 0
        req.amount = amount
        req.password = srp

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[RevenueStatsService] requestWithdrawalUrl: empty response")
            return result
        }

        let parsed = parseStarsRevenueWithdrawalUrl(responseData)
        if (!parsed.success) {
            Hilog.info(0, "CjTelegram", "[RevenueStatsService] requestWithdrawalUrl error: ${parsed.errorCode} - ${parsed.errorMessage}")
            result.errorCode = parsed.errorCode
            result.errorMessage = parsed.errorMessage
            result.errorKind = this.mapWithdrawalError(parsed.errorMessage)
            return result
        }

        result.success = true
        result.url = parsed.url
        Hilog.info(0, "CjTelegram", "[RevenueStatsService] requestWithdrawalUrl ok")
        return result
    }

    /**
     * 映射服务器错误消息为 TonWithdrawalErrorKind
     * iOS ref: StarsRevenueStatistics.swift L432-455 error handling
     */
    private func mapWithdrawalError(msg: String): TonWithdrawalErrorKind {
        if (msg == "PASSWORD_MISSING") { return TonWithdrawalErrorKind.PasswordMissing }
        if (msg == "PASSWORD_HASH_INVALID") { return TonWithdrawalErrorKind.PasswordInvalid }
        if (msg.contains("PASSWORD_TOO_FRESH")) { return TonWithdrawalErrorKind.TwoFARequired }
        if (msg.contains("SESSION_TOO_FRESH")) { return TonWithdrawalErrorKind.TwoFARequired }
        if (msg.contains("FLOOD_WAIT")) { return TonWithdrawalErrorKind.Flood }
        return TonWithdrawalErrorKind.Generic
    }

    // ── getAdsAccountUrl ─────────────────────────────────────────────────────

    /**
     * 获取频道 TON 广告账户管理 URL（"Buy Ads" 入口）
     *
     * TL: payments.getStarsRevenueAdsAccountUrl#d1d7efc5 peer:InputPeer
     * 响应: payments.starsRevenueAdsAccountUrl#394e7f21 url:string
     * iOS ref: _internal_requestStarsRevenueAdsAccountlUrl (StarsRevenueStatistics.swift L467-489)
     *
     * @param peerType  "channel"
     * @param peerId    频道 ID
     * @return url String（空字符串表示失败）
     */
    public func getAdsAccountUrl(peerType: String, peerId: Int64): String {
        Hilog.info(0, "CjTelegram", "[RevenueStatsService] getAdsAccountUrl peerId=${peerId}")

        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let req = PaymentsGetStarsRevenueAdsAccountUrl()
        req.peer = inputPeer

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[RevenueStatsService] getAdsAccountUrl: empty response")
            return ""
        }

        let parsed = parseStarsRevenueAdsAccountUrl(responseData)
        if (!parsed.success) {
            Hilog.info(0, "CjTelegram", "[RevenueStatsService] getAdsAccountUrl error: ${parsed.errorCode} - ${parsed.errorMessage}")
            return ""
        }

        Hilog.info(0, "CjTelegram", "[RevenueStatsService] getAdsAccountUrl ok")
        return parsed.url
    }
}
