package ohos_app_cangjie_entry.services

import std.collection.ArrayList
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{
    TLObject,
    TLDeserializer,
    TLConstructors,
    getMTProtoClient,
    InputPeerEmpty,
    InputPeerChannel,
    PremiumGetBoostsStatus,
    PremiumGetBoostsList,
    PremiumApplyBoost
}

// ==================== P2-302: ApplyBoost 结果模型 ====================

/**
 * 单个 MyBoost 项（来自 premium.myBoosts 响应）
 * TL: myBoost#c448415c flags:# slot:int peer:flags.0?Peer
 *   date:int expires:int cooldown_until_date:flags.1?int
 * iOS ref: Api18.swift parse_myBoost
 */
public class MyBoostData {
    public var slot: Int32 = 0
    public var hasPeer: Bool = false
    public var peerId: Int64 = 0
    public var peerType: String = ""
    public var date: Int32 = 0
    public var expires: Int32 = 0
    public var cooldownUntilDate: Int32 = 0

    public init() {}
}

/**
 * premium.applyBoost 响应（premium.myBoosts#9ae228e2 boosts:Vector<MyBoost>）
 */
public class ApplyBoostResult {
    public var success: Bool = false
    public var boosts: Array<MyBoostData> = Array<MyBoostData>(0, { _ => MyBoostData() })
    public var errorMessage: String = ""

    public init() {}
}

// ==================== P2-367: Boost 统计数据模型 ====================

/**
 * Boost 状态汇总（对应 iOS premium.BoostsStatus / Cons_boostsStatus）
 * TL: boostsStatus#4959427a
 *   flags:# level:int current_level_boosts:int boosts:int
 *   gift_boosts:flags.4?int next_level_boosts:flags.0?int
 *   premium_audience:flags.1?StatsPercentValue boost_url:string
 *
 * iOS ref: Api40.swift parse_boostsStatus (Api40.swift:77-129)
 * 进度 = boosts / next_level_boosts（若 next_level_boosts==0 则已达顶级）
 */
public class BoostsStatusData {
    public var level: Int32 = 0
    public var currentLevelBoosts: Int32 = 0
    public var boosts: Int32 = 0
    public var giftBoosts: Int32 = 0
    public var nextLevelBoosts: Int32 = 0
    public var premiumAudiencePct: Float64 = 0.0
    public var boostUrl: String = ""
    public var isLoaded: Bool = false

    public init() {}

    // 进度值 (0.0-1.0) 用于进度条渲染
    public func progressToNextLevel(): Float64 {
        if (this.nextLevelBoosts <= 0) { return 1.0 }
        // boosts 中超过 currentLevelBoosts 的部分是本级进度
        let progressBoosts = this.boosts - this.currentLevelBoosts
        let totalNeeded = this.nextLevelBoosts - this.currentLevelBoosts
        if (totalNeeded <= 0) { return 1.0 }
        let pct = Float64(progressBoosts) / Float64(totalNeeded)
        if (pct < 0.0) { return 0.0 }
        if (pct > 1.0) { return 1.0 }
        return pct
    }

    // 本级已达 boosts 数（从 currentLevelBoosts 开始算）
    public func boostsThisLevel(): Int32 {
        let prog = this.boosts - this.currentLevelBoosts
        if (prog < 0) { return 0 }
        return prog
    }

    // 到下一级还需多少
    public func boostsNeeded(): Int32 {
        let needed = this.nextLevelBoosts - this.boosts
        if (needed < 0) { return 0 }
        return needed
    }
}

/**
 * 单个 Boost 项（对应 iOS Api.Boost / Cons_boost）
 * TL: boost#4b3e14d6
 *   flags:# id:string userId:flags.0?long giveaway_msg_id:flags.2?int
 *   date:int expires:int used_gift_slug:flags.4?string
 *   multiplier:flags.5?int stars:flags.6?long
 *
 * iOS ref: Api1.swift Cons_boost (Api1.swift:1461-1556)
 */
public class BoostItem {
    public var id: String = ""
    public var userId: Int64 = 0
    public var hasUserId: Bool = false
    public var giveawayMsgId: Int32 = 0
    public var hasGiveaway: Bool = false
    public var date: Int32 = 0
    public var expires: Int32 = 0
    public var usedGiftSlug: String = ""
    public var multiplier: Int32 = 1
    public var stars: Int64 = 0

    public init() {}
}

/**
 * Boost 列表（对应 iOS premium.BoostsList / Cons_boostsList）
 * TL: boostsList#86f8613c
 *   flags:# count:int boosts:Vector<Boost>
 *   next_offset:flags.0?string users:Vector<User>
 *
 * iOS ref: Api39.swift Cons_boostsList (Api39.swift:2062-2143)
 */
public class BoostsListData {
    public var count: Int32 = 0
    public var boosts: Array<BoostItem> = Array<BoostItem>(0, { _ => BoostItem() })
    public var nextOffset: String = ""
    public var isLoaded: Bool = false

    public init() {}
}

// ==================== BoostStatsService ====================

private var _boostStatsServiceInstance: Option<BoostStatsService> = None

public func getBoostStatsService(): BoostStatsService {
    match (_boostStatsServiceInstance) {
        case Some(s) => s
        case None =>
            let s = BoostStatsService()
            _boostStatsServiceInstance = Some(s)
            s
    }
}

/**
 * Boost 统计服务
 *
 * 封装 premium.getBoostsStatus / premium.getBoostsList 的 TL 调用和解析。
 *
 * 调用链（getBoostsStatus）：
 *   BoostStatsService.getBoostsStatus(peerType, peerId)
 *     → getRealMessageService().buildInputPeer(peerType, peerId)
 *     → PremiumGetBoostsStatus.toBytes()
 *     → getMTProtoClient().sendRequest()
 *     → 解析 boostsStatus#4959427a → BoostsStatusData
 *
 * 调用链（getBoostsList）：
 *   BoostStatsService.getBoostsList(peerType, peerId, gifts)
 *     → getRealMessageService().buildInputPeer(peerType, peerId)
 *     → PremiumGetBoostsList.toBytes()
 *     → getMTProtoClient().sendRequest()
 *     → 解析 boostsList#86f8613c → BoostsListData
 */
public class BoostStatsService {

    /**
     * 获取频道/群组 Boost 状态（等级、进度、boosts 数量）
     * TL 方法：premium.getBoostsStatus (0x042f1f61)
     * 响应：premium.boostsStatus#4959427a
     *
     * @param peerType  "channel" 或 "chat"
     * @param peerId    频道 / 群组 ID
     * @return BoostsStatusData
     */
    public func getBoostsStatus(peerType: String, peerId: Int64): BoostsStatusData {
        Hilog.info(0, "CjTelegram", "[BoostStatsService] getBoostsStatus peerId=${peerId}")
        let result = BoostsStatusData()

        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let req = PremiumGetBoostsStatus()
        req.peer = inputPeer

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[BoostStatsService] getBoostsStatus: empty response")
            return result
        }

        let deser = TLDeserializer(responseData)
        let ctor = deser.readUInt32()

        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errCode = deser.readInt32()
            let errMsg = deser.readString()
            Hilog.info(0, "CjTelegram", "[BoostStatsService] getBoostsStatus RPC error: ${errCode} - ${errMsg}")
            return result
        }

        // premium.boostsStatus#4959427a
        if (ctor == 0x4959427a) {
            this.parseBoostsStatus(deser, result)
            result.isLoaded = true
            Hilog.info(0, "CjTelegram", "[BoostStatsService] getBoostsStatus ok level=${result.level} boosts=${result.boosts} nextLevel=${result.nextLevelBoosts}")
        } else {
            Hilog.info(0, "CjTelegram", "[BoostStatsService] getBoostsStatus unknown ctor=0x${ctor}")
        }
        return result
    }

    /**
     * 获取频道/群组的 Boost 列表（谁 boost 了）
     * TL 方法：premium.getBoostsList (0x60f67660)
     * 响应：premium.boostsList#86f8613c
     *
     * @param peerType  "channel" 或 "chat"
     * @param peerId    频道 / 群组 ID
     * @param gifts     true → 请求 gift boosts（Gifts tab）；false → 普通 boosts（Boosts tab）
     * @return BoostsListData
     */
    public func getBoostsList(peerType: String, peerId: Int64, gifts: Bool): BoostsListData {
        Hilog.info(0, "CjTelegram", "[BoostStatsService] getBoostsList peerId=${peerId} gifts=${gifts}")
        let result = BoostsListData()

        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let req = PremiumGetBoostsList()
        req.gifts = gifts
        req.peer = inputPeer
        req.offset = ""
        req.limit = 50

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[BoostStatsService] getBoostsList: empty response")
            return result
        }

        let deser = TLDeserializer(responseData)
        let ctor = deser.readUInt32()

        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errCode = deser.readInt32()
            let errMsg = deser.readString()
            Hilog.info(0, "CjTelegram", "[BoostStatsService] getBoostsList RPC error: ${errCode} - ${errMsg}")
            return result
        }

        // premium.boostsList#86f8613c
        if (ctor == 0x86f8613c) {
            this.parseBoostsList(deser, result)
            result.isLoaded = true
            Hilog.info(0, "CjTelegram", "[BoostStatsService] getBoostsList ok count=${result.count} loaded=${result.boosts.size}")
        } else {
            Hilog.info(0, "CjTelegram", "[BoostStatsService] getBoostsList unknown ctor=0x${ctor}")
        }
        return result
    }

    /**
     * 对频道应用 Boost（或替换现有 Boost 槽）
     * TL 方法：premium.applyBoost#6b7da746
     * 响应：premium.myBoosts#9ae228e2 boosts:Vector<MyBoost>
     *
     * iOS ref: ChannelBoost.swift:125
     *   account.network.request(Api.functions.premium.applyBoost(flags: flags, slots: slots, peer: inputPeer))
     *
     * @param peerType  "channel" 或 "chat"
     * @param peerId    频道 / 群组 ID
     * @param slots     要替换的 boost 槽下标（空 = 新增 boost；有值 = 替换指定槽）
     * @return ApplyBoostResult
     */
    public func applyBoost(peerType: String, peerId: Int64, slots: ArrayList<Int32>): ApplyBoostResult {
        Hilog.info(0, "CjTelegram", "[BoostStatsService] applyBoost peerId=${peerId} slots=${slots.size}")
        let result = ApplyBoostResult()

        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let req = PremiumApplyBoost()
        req.peer = inputPeer
        for (s in slots) {
            req.slots.add(s)
        }

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            result.errorMessage = "empty response"
            return result
        }

        let deser = TLDeserializer(responseData)
        let ctor = deser.readUInt32()

        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errCode = deser.readInt32()
            let errMsg = deser.readString()
            result.errorMessage = "${errCode}: ${errMsg}"
            Hilog.info(0, "CjTelegram", "[BoostStatsService] applyBoost RPC error: ${result.errorMessage}")
            return result
        }

        // premium.myBoosts#9ae228e2 boosts:Vector<MyBoost>
        if (ctor == 0x9ae228e2) {
            result.boosts = this.parseMyBoosts(deser)
            result.success = true
            Hilog.info(0, "CjTelegram", "[BoostStatsService] applyBoost ok boosts=${result.boosts.size}")
        } else {
            result.errorMessage = "unexpected ctor=0x${ctor}"
            Hilog.info(0, "CjTelegram", "[BoostStatsService] applyBoost unknown ctor=0x${ctor}")
        }
        return result
    }

    /**
     * 解析 premium.myBoosts 响应内的 Vector<MyBoost>
     * myBoost#c448415c flags:# slot:int peer:flags.0?Peer
     *   date:int expires:int cooldown_until_date:flags.1?int
     * iOS ref: Api18.swift parse_myBoost (Api18.swift:1174-1181)
     */
    private func parseMyBoosts(deser: TLDeserializer): Array<MyBoostData> {
        var list = ArrayList<MyBoostData>()
        try {
            if (deser.remaining() < 8) { return Array<MyBoostData>(0, { _ => MyBoostData() }) }
            let vecCtor = deser.readUInt32() // 0x1cb5c415
            let _ = vecCtor
            let count = deser.readInt32()
            var i: Int32 = 0
            while (i < count && deser.remaining() >= 4) {
                let itemCtor = deser.readUInt32() // 0xc448415c
                let _ = itemCtor
                let item = MyBoostData()
                let flags = deser.readInt32()
                item.slot = deser.readInt32()
                // peer:flags.0?Peer
                if ((flags & 1) != 0) {
                    let peerCtor = deser.readUInt32()
                    if (peerCtor == 0x59511722) {
                        item.peerId = deser.readInt64()
                        item.peerType = "user"
                    } else if (peerCtor == 0x36c6019a) {
                        item.peerId = deser.readInt64()
                        item.peerType = "chat"
                    } else if (peerCtor == 0xa2a5371e) {
                        item.peerId = deser.readInt64()
                        item.peerType = "channel"
                    } else {
                        if (deser.remaining() >= 8) { let _ = deser.readInt64() }
                    }
                    item.hasPeer = true
                }
                // date:int (unconditional, iOS Api18.swift _4 = reader.readInt32())
                if (deser.remaining() >= 4) { item.date = deser.readInt32() }
                // expires:int (unconditional, iOS Api18.swift _5 = reader.readInt32())
                if (deser.remaining() >= 4) { item.expires = deser.readInt32() }
                // cooldown_until_date:flags.1?int (bit1, mask=2, iOS Api18.swift Int(_1) & Int(1<<1))
                if ((flags & 2) != 0 && deser.remaining() >= 4) {
                    item.cooldownUntilDate = deser.readInt32()
                }
                list.add(item)
                i += 1
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BoostStatsService] parseMyBoosts error: ${e}")
        }
        let frozenList = list
        return Array<MyBoostData>(frozenList.size, { idx: Int64 => frozenList[idx] })
    }

    // ==================== 内部解析方法 ====================

    /**
     * 解析 boostsStatus#4959427a（不含头部 ctor，已由调用者消费）
     * 字段序列化顺序（Api40.swift Cons_boostsStatus.serialize）：
     *   flags:int
     *   level:int
     *   current_level_boosts:int
     *   boosts:int
     *   gift_boosts:flags.4?int
     *   next_level_boosts:flags.0?int
     *   premium_audience:flags.1?StatsPercentValue(boxed)
     *   boost_url:string
     *   prepaid_giveaways:flags.3?Vector<PrepaidGiveaway>  (skip)
     *   my_boost_slots:flags.2?Vector<int>                 (skip)
     */
    private func parseBoostsStatus(deser: TLDeserializer, result: BoostsStatusData) {
        try {
            let flags = deser.readInt32()
            result.level = deser.readInt32()
            result.currentLevelBoosts = deser.readInt32()
            result.boosts = deser.readInt32()

            // gift_boosts:flags.4?int
            if ((flags & 16) != 0 && deser.remaining() >= 4) {
                result.giftBoosts = deser.readInt32()
            }
            // next_level_boosts:flags.0?int
            if ((flags & 1) != 0 && deser.remaining() >= 4) {
                result.nextLevelBoosts = deser.readInt32()
            }
            // premium_audience:flags.1?StatsPercentValue(boxed)
            // statsPercentValue#cbce2fe0 part:double total:double
            if ((flags & 2) != 0) {
                let paCtor = deser.readUInt32() // 0xcbce2fe0
                let _ = paCtor
                if (deser.remaining() >= 16) {
                    let part = deser.readDouble()
                    let total = deser.readDouble()
                    if (total > 0.0) {
                        result.premiumAudiencePct = part / total
                    }
                }
            }
            // boost_url:string (mandatory)
            result.boostUrl = deser.readString()

            // prepaid_giveaways:flags.3?Vector — skip
            if ((flags & 8) != 0) {
                this.skipPrepaidGiveawaysVector(deser)
            }
            // my_boost_slots:flags.2?Vector<int> — skip
            if ((flags & 4) != 0) {
                this.skipIntVector(deser)
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BoostStatsService] parseBoostsStatus error: ${e}")
        }
    }

    /**
     * 解析 boostsList#86f8613c（不含头部 ctor）
     * 字段序列化顺序（Api39.swift Cons_boostsList.serialize）：
     *   flags:int
     *   count:int
     *   boosts:Vector<Boost>
     *   next_offset:flags.0?string
     *   users:Vector<User>  (skip — display "User <id>" label)
     */
    private func parseBoostsList(deser: TLDeserializer, result: BoostsListData) {
        try {
            let flags = deser.readInt32()
            result.count = deser.readInt32()

            // boosts: Vector<Boost>
            // vector constructor 0x1cb5c415 + count + items
            if (deser.remaining() >= 8) {
                let vecCtor = deser.readUInt32() // 0x1cb5c415
                let _ = vecCtor
                let boostCount = deser.readInt32()
                Hilog.info(0, "CjTelegram", "[BoostStatsService] parseBoostsList boostCount=${boostCount}")
                result.boosts = this.parseBoostItems(deser, boostCount)
            }

            // next_offset:flags.0?string
            if ((flags & 1) != 0) {
                result.nextOffset = deser.readString()
            }
            // users: Vector<User> — skip (complex)
            // We don't parse users here; BoostItem.userId is set for future lookup
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BoostStatsService] parseBoostsList error: ${e}")
        }
    }

    /**
     * 解析 N 个 boost 项
     * boost#4b3e14d6 (boxed):
     *   flags:int id:string userId:flags.0?long giveaway_msg_id:flags.2?int
     *   date:int expires:int used_gift_slug:flags.4?string
     *   multiplier:flags.5?int stars:flags.6?long
     * iOS ref: Api1.swift parse_boost (Api1.swift:1525-1556)
     */
    private func parseBoostItems(deser: TLDeserializer, count: Int32): Array<BoostItem> {
        var list = ArrayList<BoostItem>()
        var i: Int32 = 0
        while (i < count && deser.remaining() >= 4) {
            let boostCtor = deser.readUInt32() // 0x4b3e14d6
            let _ = boostCtor
            let item = BoostItem()
            let boostFlags = deser.readInt32()
            item.id = deser.readString()
            // userId:flags.0?long
            if ((boostFlags & 1) != 0 && deser.remaining() >= 8) {
                item.userId = deser.readInt64()
                item.hasUserId = true
            }
            // giveaway_msg_id:flags.2?int
            if ((boostFlags & 4) != 0 && deser.remaining() >= 4) {
                item.giveawayMsgId = deser.readInt32()
                item.hasGiveaway = true
            }
            // date:int (mandatory)
            if (deser.remaining() >= 4) { item.date = deser.readInt32() }
            // expires:int (mandatory)
            if (deser.remaining() >= 4) { item.expires = deser.readInt32() }
            // used_gift_slug:flags.4?string
            if ((boostFlags & 16) != 0) {
                item.usedGiftSlug = deser.readString()
            }
            // multiplier:flags.5?int
            if ((boostFlags & 32) != 0 && deser.remaining() >= 4) {
                item.multiplier = deser.readInt32()
            }
            // stars:flags.6?long
            if ((boostFlags & 64) != 0 && deser.remaining() >= 8) {
                item.stars = deser.readInt64()
            }
            list.add(item)
            i += 1
        }
        let r = list
        return Array<BoostItem>(r.size, { idx: Int64 => r[idx] })
    }

    // 跳过 PrepaidGiveaway vector（结构复杂，直接 skip）
    private func skipPrepaidGiveawaysVector(deser: TLDeserializer) {
        if (deser.remaining() < 8) { return }
        let vecCtor = deser.readUInt32()
        let _ = vecCtor
        let count = deser.readInt32()
        // Each PrepaidGiveaway: ctor(uint32) + id(long) + months(int) + quantity(int) + date(int)
        // = 4+8+4+4+4 = 24 bytes (approximate; varies by ctor variant)
        // Safe approach: try to skip fixed portion per item
        var i: Int32 = 0
        while (i < count && deser.remaining() >= 24) {
            let itemCtor = deser.readUInt32()
            let _ = itemCtor
            // prepaidGiveaway#b2539c53: id:long months:int quantity:int date:int
            if (deser.remaining() >= 20) {
                let _ = deser.readInt64()   // id
                let _ = deser.readInt32()   // months
                let _ = deser.readInt32()   // quantity
                let _ = deser.readInt32()   // date
            }
            i += 1
        }
    }

    // 跳过 Vector<int>（普通整数向量）
    private func skipIntVector(deser: TLDeserializer) {
        if (deser.remaining() < 8) { return }
        let vecCtor = deser.readUInt32()
        let _ = vecCtor
        let count = deser.readInt32()
        var i: Int32 = 0
        while (i < count && deser.remaining() >= 4) {
            let _ = deser.readInt32()
            i += 1
        }
    }
}
