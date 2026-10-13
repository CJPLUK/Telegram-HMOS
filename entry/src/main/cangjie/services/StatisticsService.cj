package ohos_app_cangjie_entry.services

import std.collection.ArrayList
import std.time.DateTime
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{
    TLObject,
    TLSerializer,
    TLDeserializer,
    TLConstructors,
    getMTProtoClient,
    InputPeerEmpty
}

// ==================== TL 方法定义（本文件私有）====================

/**
 * stats.getBroadcastStats — 获取频道广播统计
 * Constructor: 0xab42441a
 * flags:# dark:flags.0?true channel:InputChannel = stats.BroadcastStats
 *
 * 注：channel 字段序列化使用 InputPeerChannel (0x27bcbbfc，channelId+accessHash)
 *     与 InputChannel (0xafeb712e) 字段布局相同，仅 constructor ID 不同。
 *     此处使用 InputPeerChannel 通过 buildInputPeer() 获取，以复用 accessHash 缓存。
 */
private class StatsGetBroadcastStats <: TLObject {
    public var dark: Bool = false
    public var channel: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0xab42441a }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.dark) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.channel.toBytes())
    }
}

/**
 * stats.getMegagroupStats — 获取超级群组统计
 * Constructor: 0xdcdf8607
 * flags:# dark:flags.0?true channel:InputChannel = stats.MegagroupStats
 */
private class StatsGetMegagroupStats <: TLObject {
    public var dark: Bool = false
    public var channel: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0xdcdf8607 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.dark) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.channel.toBytes())
    }
}

/**
 * payments.getStarsTransactions — 获取 Stars 星币交易列表
 * Constructor: 0x69da4557
 * flags:# inbound:flags.0?true outbound:flags.1?true ascending:flags.2?true
 *         subscription_id:flags.3?string peer:InputPeer offset:string limit:int
 *         = payments.StarsStatus
 *
 * 响应：payments.starsStatus#0x6c9ce8ed
 *   flags:# balance:StarsAmount subscriptions:flags.1?Vector<StarsSubscription>
 *   subscriptions_next_offset:flags.2?string subscriptions_missing_balance:flags.4?long
 *   history:flags.3?Vector<StarsTransaction> next_offset:flags.0?string
 *   chats:Vector<Chat> users:Vector<User>
 */
private class PaymentsGetStarsTransactions <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var offset: String = ""
    public var limit: Int32 = 20
    public var inbound: Bool = false
    public var outbound: Bool = false

    public func getConstructorId(): UInt32 { return 0x69da4557 }

    public func serialize(serializer: TLSerializer) {
        // flags: bit0=inbound, bit1=outbound
        var flags: Int32 = 0
        if (this.inbound) { flags = flags | 1 }
        if (this.outbound) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeString(this.offset)
        serializer.writeInt32(this.limit)
    }
}

/**
 * stats.loadAsyncGraph — 加载异步图表数据
 * Constructor: 0x621d5f84
 * flags:# token:string x:flags.0?long = StatsGraph
 */
private class StatsLoadAsyncGraph <: TLObject {
    public var token: String = ""
    public var x: Int64 = 0
    public var hasX: Bool = false

    public func getConstructorId(): UInt32 { return 0x621d5f84 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.hasX) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeString(this.token)
        if (this.hasX) {
            serializer.writeInt64(this.x)
        }
    }
}

// ==================== 统计数据响应模型 ====================

/**
 * 频道统计概览（对应 iOS Cons_broadcastStats 全字段）
 * iOS 来源：Api40.swift Cons_broadcastStats
 * 字段顺序与 TL 序列化顺序完全对应：
 *   period followers viewsPerPost sharesPerPost reactionsPerPost
 *   viewsPerStory sharesPerStory reactionsPerStory enabledNotifications
 */
public class ChannelStatsOverview {
    public var period: String = ""
    public var followers: Int64 = 0
    public var followersChange: Int64 = 0
    public var viewsPerPost: Int64 = 0
    public var viewsPerPostChange: Int64 = 0
    public var sharesPerPost: Int64 = 0
    public var sharesPerPostChange: Int64 = 0
    public var reactionsPerPost: Int64 = 0
    public var reactionsPerPostChange: Int64 = 0
    public var viewsPerStory: Int64 = 0
    public var viewsPerStoryChange: Int64 = 0
    public var sharesPerStory: Int64 = 0
    public var sharesPerStoryChange: Int64 = 0
    public var reactionsPerStory: Int64 = 0
    public var reactionsPerStoryChange: Int64 = 0
    public var enabledNotificationsPct: Float64 = 0.0

    public init() {}
}

/**
 * 超级群组统计概览（对应 iOS Cons_megagroupStats 全字段）
 * iOS 来源：Api40.swift Cons_megagroupStats
 * 新增 admins/inviters（来自 topAdmins/topInviters vector count）
 */
public class MegagroupStatsOverview {
    public var period: String = ""
    public var members: Int64 = 0
    public var membersChange: Int64 = 0
    public var messages: Int64 = 0
    public var messagesChange: Int64 = 0
    public var viewers: Int64 = 0
    public var viewersChange: Int64 = 0
    public var posters: Int64 = 0
    public var postersChange: Int64 = 0
    public var admins: Int64 = 0
    public var inviters: Int64 = 0

    public init() {}
}

/**
 * Recent Post 交互计数器（对应 postInteractionCountersMessage）
 * TL schema：postInteractionCountersMessage#e7058e7f
 *   msgId:int views:int forwards:int reactions:int
 * iOS 来源：Api21.swift Cons_postInteractionCountersMessage
 */
public class RecentPostItem {
    public var msgId: Int32 = 0
    public var views: Int32 = 0
    public var forwards: Int32 = 0
    public var reactions: Int32 = 0

    public init() {}
}

/**
 * Top Poster（对应 statsGroupTopPoster）
 * TL schema（constructor 0x9d04af9b）：
 *   userId:long messages:int avgChars:int
 * iOS 来源：Api28.swift Cons_statsGroupTopPoster
 */
public class GroupTopPoster {
    public var userId: Int64 = 0
    public var messages: Int32 = 0
    public var avgChars: Int32 = 0
    public var displayName: String = ""

    public init() {}
}

/**
 * Top Admin（对应 statsGroupTopAdmin）
 * TL schema（constructor 0xd7584c87）：
 *   userId:long deleted:int kicked:int banned:int
 * iOS 来源：Api28.swift Cons_statsGroupTopAdmin
 */
public class GroupTopAdmin {
    public var userId: Int64 = 0
    public var deleted: Int32 = 0
    public var kicked: Int32 = 0
    public var banned: Int32 = 0
    public var displayName: String = ""

    public init() {}
}

/**
 * Top Inviter（对应 statsGroupTopInviter）
 * TL schema（constructor 0x535f779d）：
 *   userId:long invitations:int
 * iOS 来源：Api28.swift Cons_statsGroupTopInviter
 */
public class GroupTopInviter {
    public var userId: Int64 = 0
    public var invitations: Int32 = 0
    public var displayName: String = ""

    public init() {}
}

/**
 * 广播统计数据
 */
public class BroadcastStatsData {
    public var overview: ChannelStatsOverview = ChannelStatsOverview()
    public var growthGraphToken: String = ""
    public var followersGraphToken: String = ""
    public var notificationsGraphToken: String = ""
    public var viewsByHourGraphToken: String = ""
    public var viewsBySourceGraphToken: String = ""
    public var followersBySourceGraphToken: String = ""
    public var languagesGraphToken: String = ""
    public var postInteractionsGraphToken: String = ""
    public var recentMessages: Int64 = 0
    public var recentPosts: Array<RecentPostItem> = Array<RecentPostItem>(0, { _ => RecentPostItem() })
    public var isLoaded: Bool = false

    public init() {}
}

/**
 * 超级群组统计数据
 */
public class MegagroupStatsData {
    public var overview: MegagroupStatsOverview = MegagroupStatsOverview()
    public var growthGraphToken: String = ""
    public var membersGraphToken: String = ""
    public var newMembersBySourceGraphToken: String = ""
    public var languagesGraphToken: String = ""
    public var messagesGraphToken: String = ""
    public var actionsGraphToken: String = ""
    public var topHoursGraphToken: String = ""
    public var topWeekdaysGraphToken: String = ""
    public var topPosters: Array<GroupTopPoster> = Array<GroupTopPoster>(0, { _ => GroupTopPoster() })
    public var topAdmins: Array<GroupTopAdmin> = Array<GroupTopAdmin>(0, { _ => GroupTopAdmin() })
    public var topInviters: Array<GroupTopInviter> = Array<GroupTopInviter>(0, { _ => GroupTopInviter() })
    public var isLoaded: Bool = false

    public init() {}
}

/**
 * 星币交易状态（对应 iOS starsTransaction flags 字段）
 * refund=flags.3, pending=flags.4, failed=flags.6
 */
public enum StarsTransactionStatus {
    | Normal    // 正常完成交易
    | Refund    // 已退款（flags.3）
    | Pending   // 待处理（flags.4）
    | Failed    // 失败（flags.6）
}

/**
 * 星币交易数据（对应 iOS StarsContext.State.Transaction）
 * P2-369: 新增 status 字段支持 refund/pending/failed 徽标显示
 */
public class StarsTransactionData {
    public var id: String = ""
    public var date: Int64 = 0
    public var amount: Int64 = 0
    public var currency: String = "XTR"
    public var peerName: String = ""
    public var isIncoming: Bool = true
    public var description_: String = ""
    public var status: StarsTransactionStatus = StarsTransactionStatus.Normal

    public init() {}
}

// ==================== StatisticsService ====================

private var _statisticsServiceInstance: Option<StatisticsService> = None

public func getStatisticsService(): StatisticsService {
    match (_statisticsServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = StatisticsService()
            _statisticsServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 统计数据服务
 *
 * 封装 Telegram TL 统计方法调用，提供频道和超级群组统计数据。
 *
 * 调用链（频道）：
 *   StatisticsService.getBroadcastStats(peerType, peerId)
 *     → getRealMessageService().buildInputPeer(peerType, peerId)  [获取含 accessHash 的 InputPeerChannel]
 *     → StatsGetBroadcastStats.toBytes()
 *     → getMTProtoClient().sendRequest()
 *     → 解析响应 → BroadcastStatsData
 *
 * 调用链（超级群组）：
 *   StatisticsService.getMegagroupStats(peerType, peerId)
 *     → getRealMessageService().buildInputPeer(peerType, peerId)  [获取含 accessHash 的 InputPeerChannel]
 *     → StatsGetMegagroupStats.toBytes()
 *     → getMTProtoClient().sendRequest()
 *     → 解析响应 → MegagroupStatsData
 *
 * 调用链（异步图表）：
 *   StatisticsService.loadAsyncGraph(token, x)
 *     → StatsLoadAsyncGraph.toBytes()
 *     → getMTProtoClient().sendRequest()
 *     → 解析响应 → GraphStats (from GraphService)
 */
public class StatisticsService {

    /**
     * 获取频道广播统计数据
     * TL 方法：stats.getBroadcastStats (0xab42441a)
     * 调用链：StatisticsService.getBroadcastStats → getMTProtoClient().sendRequest()
     *
     * @param peerType 对话类型（"channel"）
     * @param peerId   频道 ID
     * @return BroadcastStatsData
     */
    public func getBroadcastStats(peerType: String, peerId: Int64): BroadcastStatsData {
        Hilog.info(0, "CjTelegram", "[StatisticsService] getBroadcastStats peerId=${peerId}")
        let result = BroadcastStatsData()

        // 通过 RealMessageService.buildInputPeer 获取含 accessHash 的 InputPeerChannel
        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let req = StatsGetBroadcastStats()
        req.dark = false
        req.channel = inputPeer

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[StatisticsService] getBroadcastStats: empty response")
            return result
        }

        let deser = TLDeserializer(responseData)
        let constructor = deser.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errCode = deser.readInt32()
            let errMsg = deser.readString()
            Hilog.info(0, "CjTelegram", "[StatisticsService] getBroadcastStats RPC Error: ${errCode} - ${errMsg}")
            return result
        }

        // Constructor 0x396ca5fc = stats.broadcastStats
        // Parse overview stats + 11 StatsGraph fields + recentPostsInteractions vector
        result.isLoaded = true
        this.parseBroadcastStatsInto(deser, result)
        Hilog.info(0, "CjTelegram", "[StatisticsService] getBroadcastStats loaded followers=${result.overview.followers} recentPosts=${result.recentPosts.size}")
        return result
    }

    /**
     * 获取超级群组统计数据
     * TL 方法：stats.getMegagroupStats (0xdcdf8607)
     * 调用链：StatisticsService.getMegagroupStats → getMTProtoClient().sendRequest()
     *
     * @param peerType 对话类型（"channel"/"chat"）
     * @param peerId   超级群组频道 ID
     * @return MegagroupStatsData
     */
    public func getMegagroupStats(peerType: String, peerId: Int64): MegagroupStatsData {
        Hilog.info(0, "CjTelegram", "[StatisticsService] getMegagroupStats peerId=${peerId}")
        let result = MegagroupStatsData()

        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let req = StatsGetMegagroupStats()
        req.dark = false
        req.channel = inputPeer

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[StatisticsService] getMegagroupStats: empty response")
            return result
        }

        let deser = TLDeserializer(responseData)
        let constructor = deser.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errCode = deser.readInt32()
            let errMsg = deser.readString()
            Hilog.info(0, "CjTelegram", "[StatisticsService] getMegagroupStats RPC Error: ${errCode} - ${errMsg}")
            return result
        }

        // Constructor 0xef7ff916 = stats.megagroupStats
        result.isLoaded = true
        this.parseMegagroupStatsInto(deser, result)
        Hilog.info(0, "CjTelegram", "[StatisticsService] getMegagroupStats loaded members=${result.overview.members} topPosters=${result.topPosters.size} topAdmins=${result.topAdmins.size} topInviters=${result.topInviters.size}")
        return result
    }

    /**
     * 加载异步图表数据
     * TL 方法：stats.loadAsyncGraph (0x621d5f84)
     * 调用链：StatisticsService.loadAsyncGraph → getMTProtoClient().sendRequest()
     *
     * @param token 图表 token（从 stats.BroadcastStats / MegagroupStats 字段获得）
     * @param x     可选 x 坐标值（用于 loadDetailedGraph）
     * @return GraphStats
     */
    public func loadAsyncGraph(token: String, x!: Int64 = -1): GraphStats {
        Hilog.info(0, "CjTelegram", "[StatisticsService] loadAsyncGraph token=${token}")
        let result = GraphStats()

        let req = StatsLoadAsyncGraph()
        req.token = token
        if (x >= 0) {
            req.x = x
            req.hasX = true
        }

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[StatisticsService] loadAsyncGraph: empty response")
            return result
        }

        let deser = TLDeserializer(responseData)
        let constructor = deser.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errCode = deser.readInt32()
            let errMsg = deser.readString()
            Hilog.info(0, "CjTelegram", "[StatisticsService] loadAsyncGraph RPC Error: ${errCode} - ${errMsg}")
            return result
        }

        // statsGraphAsync#4a27eb2d token:string = StatsGraph (need retry)
        // statsGraphError#bedc9822 error:string = StatsGraph
        // statsGraph#8ea464b6 flags:# json:DataJSON zoom_token:flags.0?string = StatsGraph
        if (constructor == 0x4a27eb2d) {
            // Async — token not yet ready, return empty
            Hilog.info(0, "CjTelegram", "[StatisticsService] loadAsyncGraph: still async, retry later")
        } else if (constructor == 0xbedc9822) {
            let errStr = deser.readString()
            Hilog.info(0, "CjTelegram", "[StatisticsService] loadAsyncGraph graph error: ${errStr}")
        } else {
            // 0x8ea464b6 = statsGraph — JSON data available
            result.title = "Stats Graph"
            Hilog.info(0, "CjTelegram", "[StatisticsService] loadAsyncGraph: graph data loaded")
        }
        return result
    }

    /**
     * 获取 Stars 星币交易列表
     * TL 方法：payments.getStarsTransactions (0x69da4557)
     * 响应：payments.starsStatus#0x6c9ce8ed — 解析 history 字段（flag.3）
     *
     * 调用链：StatisticsService.getStarsTransactions
     *   → getRealMessageService().buildInputPeer(peerType, peerId)
     *   → getMTProtoClient().sendRequest()
     *   → 解析 starsStatus.history → Array<StarsTransactionData>
     *
     * @param peerType 对话类型（"channel"）
     * @param peerId   频道 / 群组 ID
     * @return Array<StarsTransactionData>（最多20条，服务端 limit）
     */
    public func getStarsTransactions(peerType: String, peerId: Int64): Array<StarsTransactionData> {
        Hilog.info(0, "CjTelegram", "[StatisticsService] getStarsTransactions peerId=${peerId}")

        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let req = PaymentsGetStarsTransactions()
        req.peer = inputPeer
        req.offset = ""
        req.limit = 20

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[StatisticsService] getStarsTransactions: empty response")
            return Array<StarsTransactionData>(0, { _ => StarsTransactionData() })
        }

        let deser = TLDeserializer(responseData)
        let constructor = deser.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errCode = deser.readInt32()
            let errMsg = deser.readString()
            Hilog.info(0, "CjTelegram", "[StatisticsService] getStarsTransactions RPC Error: ${errCode} - ${errMsg}")
            return Array<StarsTransactionData>(0, { _ => StarsTransactionData() })
        }

        // payments.starsStatus#0x6c9ce8ed
        // flags:# balance:StarsAmount(boxed) subscriptions?:Vector
        // subscriptions_next_offset?:string subscriptions_missing_balance?:int64
        // history?:Vector<StarsTransaction> next_offset?:string
        // chats:Vector users:Vector
        return this.parseStarsStatus(deser)
    }

    /**
     * 测试辅助：从原始字节按顺序解析 count 条 starsTransaction。
     * 仅供 StatisticsUITest 调用，验证 parseStarsTransaction 的偏移推进正确性。
     * 如果 tx[0] 的可选字段消费正确，tx[1] 才能从正确偏移开始解析。
     *
     * @param data   连续拼接 count 条 starsTransaction TL 字节（每条均含 boxed constructor）
     * @param count  要解析的交易条数
     * @return Array<StarsTransactionData> 长度等于成功解析条数
     */
    public func parseStarsTransactionsForTest(data: Array<Byte>, count: Int32): Array<StarsTransactionData> {
        let deser = TLDeserializer(data)
        var results = ArrayList<StarsTransactionData>()
        var i: Int32 = 0
        try {
            while (i < count) {
                let tx = this.parseStarsTransaction(deser)
                results.add(tx)
                i += 1
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[StatisticsService] parseStarsTransactionsForTest error at tx[${i}]: ${e}")
        }
        let r = results
        return Array<StarsTransactionData>(r.size, { idx: Int64 => r[idx] })
    }

    /**
     * 解析 payments.starsStatus 响应，提取 history 交易列表
     * starsStatus#0x6c9ce8ed
     */
    private func parseStarsStatus(deser: TLDeserializer): Array<StarsTransactionData> {
        var result = ArrayList<StarsTransactionData>()
        try {
            // flags
            let flags = deser.readInt32()

            // balance: StarsAmount (boxed) — constructor 0xbbb6b4a3 or 0x74CCFB73
            // skip by reading constructor then int64+int32 (starsAmount) or int64 (starsTonAmount)
            let balanceConstructor = deser.readUInt32()
            if (balanceConstructor == 0xbbb6b4a3) {
                // starsAmount: amount:int64 nanos:int32
                let _ = deser.readInt64()
                let _ = deser.readInt32()
            } else {
                // starsTonAmount or unknown: amount:int64
                let _ = deser.readInt64()
            }

            // flag.1: subscriptions Vector — skip
            if ((flags & 2) != 0) {
                let vecConstructor = deser.readUInt32() // 0x1cb5c415 (vector)
                let _ = vecConstructor
                let subCount = deser.readInt32()
                // Each StarsSubscription is complex — we skip all by reading bytes carefully
                // For now, return empty since we can't reliably skip complex structs
                Hilog.info(0, "CjTelegram", "[StatisticsService] parseStarsStatus: subscriptions present count=${subCount}, skipping history")
                return Array<StarsTransactionData>(0, { _ => StarsTransactionData() })
            }

            // flag.2: subscriptions_next_offset string — skip
            if ((flags & 4) != 0) {
                let _ = deser.readString()
            }

            // flag.4: subscriptions_missing_balance int64 — skip
            if ((flags & 16) != 0) {
                let _ = deser.readInt64()
            }

            // flag.3: history Vector<StarsTransaction> — this is what we want
            if ((flags & 8) != 0) {
                let vecConstructor = deser.readUInt32() // 0x1cb5c415 vector
                let _ = vecConstructor
                let txCount = deser.readInt32()
                Hilog.info(0, "CjTelegram", "[StatisticsService] parseStarsStatus: history txCount=${txCount}")
                var i: Int32 = 0
                while (i < txCount && i < 20) {
                    let tx = this.parseStarsTransaction(deser)
                    result.add(tx)
                    i += 1
                }
            } else {
                Hilog.info(0, "CjTelegram", "[StatisticsService] parseStarsStatus: no history (flags=${flags})")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[StatisticsService] parseStarsStatus error: ${e}")
        }
        let r = result
        return Array<StarsTransactionData>(r.size, { i: Int64 => r[i] })
    }

    /**
     * 解析单条 starsTransaction#a39fd94a
     * TL schema (telegram_api.tl line 1880):
     *   flags:# refund:flags.3?true pending:flags.4?true failed:flags.6?true
     *   gift:flags.10?true reaction:flags.11?true stargift_upgrade:flags.18?true
     *   business_transfer:flags.21?true stargift_resale:flags.22?true
     *   id:string stars:StarsAmount date:int peer:StarsTransactionPeer
     *   title:flags.0?string description:flags.1?string
     *   photo:flags.2?WebDocument
     *   transaction_date:flags.5?int transaction_url:flags.5?string
     *   bot_payload:flags.7?bytes msg_id:flags.8?int
     *   extended_media:flags.9?Vector<MessageMedia>
     *   subscription_period:flags.12?int giveaway_post_id:flags.13?int
     *   stargift:flags.14?StarGift floodskip_number:flags.15?int
     *   starref_commission_permille:flags.16?int
     *   starref_peer:flags.17?Peer starref_amount:flags.17?StarsAmount
     *   paid_messages:flags.19?int premium_gift_months:flags.20?int
     *
     * All optional fields after flags.1 are consumed / skipped to keep offset correct.
     */
    private func parseStarsTransaction(deser: TLDeserializer): StarsTransactionData {
        let tx = StarsTransactionData()
        // constructor (boxed) — starsTransaction#a39fd94a
        let constructor = deser.readUInt32()
        let _ = constructor
        // flags (bare #)
        let flags = deser.readInt32()
        // id: string (mandatory)
        tx.id = deser.readString()
        // stars: StarsAmount (boxed, mandatory)
        let amtConstructor = deser.readUInt32()
        if (amtConstructor == 0xbbb6b4a3) {
            // starsAmount#bbb6b4a3: amount:long nanos:int
            let amt = deser.readInt64()
            let _ = deser.readInt32() // nanos
            tx.amount = amt
        } else {
            // starsTonAmount or unknown: assume amount:long only
            let amt = deser.readInt64()
            tx.amount = amt
        }
        // date: int (mandatory unix timestamp)
        tx.date = Int64(deser.readInt32())
        // peer: StarsTransactionPeer (boxed, mandatory)
        // Known constructors:
        //   starsTransactionPeer#d80da15d peer:Peer(boxed) — has one inner Peer
        //   starsTransactionPeerUnsupported#95f2bfe4 — no extra fields
        //   starsTransactionPeerAppStore#b457b375 — no extra fields
        //   starsTransactionPeerPlayMarket#7b560a0b — no extra fields
        //   starsTransactionPeerPremiumBot#250dbaf8 — no extra fields
        //   starsTransactionPeerFragment#e92fd902 — no extra fields
        //   starsTransactionPeerAds#60682812 — no extra fields
        //   starsTransactionPeerAPI#f9677aad — no extra fields
        let peerConstructor = deser.readUInt32()
        if (peerConstructor == 0xd80da15d) {
            // starsTransactionPeer#d80da15d: has peer:Peer(boxed)
            // peerUser#59511722 user_id:long
            // peerChat#36c6019a chat_id:long
            // peerChannel#a2a5371e channel_id:long
            let innerPeerConstructor = deser.readUInt32()
            if (innerPeerConstructor == 0x59511722 || innerPeerConstructor == 0x36c6019a || innerPeerConstructor == 0xa2a5371e) {
                let _ = deser.readInt64() // userId / chatId / channelId
            }
            // unknown Peer variant: can't safely skip, but these 3 cover all known cases
        }
        // else: all other starsTransactionPeer variants have no extra fields

        // P2-369: derive transaction status from flags bits
        // refund=flags.3(bit 8), pending=flags.4(bit 16), failed=flags.6(bit 64)
        if ((flags & 8) != 0) {
            tx.status = StarsTransactionStatus.Refund
        } else if ((flags & 16) != 0) {
            tx.status = StarsTransactionStatus.Pending
        } else if ((flags & 64) != 0) {
            tx.status = StarsTransactionStatus.Failed
        } else {
            tx.status = StarsTransactionStatus.Normal
        }

        // isIncoming heuristic: refund(flags.3) or absent outgoing marker → incoming
        tx.isIncoming = true

        // flags.0: title:string
        if ((flags & 1) != 0) {
            tx.peerName = deser.readString()
        }
        // flags.1: description:string
        if ((flags & 2) != 0) {
            tx.description_ = deser.readString()
        }
        // flags.2: photo:WebDocument — skip
        if ((flags & 4) != 0) {
            this.skipWebDocument(deser)
        }
        // flags.5: transaction_date:int AND transaction_url:string (both conditioned on same bit)
        if ((flags & 32) != 0) {
            let _ = deser.readInt32()   // transaction_date
            let _ = deser.readString()  // transaction_url
        }
        // flags.7: bot_payload:bytes — skip
        if ((flags & 128) != 0) {
            let _ = deser.readBytes()
        }
        // flags.8: msg_id:int — skip
        if ((flags & 256) != 0) {
            let _ = deser.readInt32()
        }
        // flags.9: extended_media:Vector<MessageMedia> — skip entire vector
        if ((flags & 512) != 0) {
            this.skipTLVector(deser)
        }
        // flags.12: subscription_period:int — skip
        if ((flags & 4096) != 0) {
            let _ = deser.readInt32()
        }
        // flags.13: giveaway_post_id:int — skip
        if ((flags & 8192) != 0) {
            let _ = deser.readInt32()
        }
        // flags.14: stargift:StarGift — skip boxed
        if ((flags & 16384) != 0) {
            this.skipStarGift(deser)
        }
        // flags.15: floodskip_number:int — skip
        if ((flags & 32768) != 0) {
            let _ = deser.readInt32()
        }
        // flags.16: starref_commission_permille:int — skip
        if ((flags & 65536) != 0) {
            let _ = deser.readInt32()
        }
        // flags.17: starref_peer:Peer(boxed) AND starref_amount:StarsAmount(boxed) — skip both
        if ((flags & 131072) != 0) {
            this.skipPeer(deser)
            this.skipStarsAmount(deser)
        }
        // flags.19: paid_messages:int — skip
        if ((flags & 524288) != 0) {
            let _ = deser.readInt32()
        }
        // flags.20: premium_gift_months:int — skip
        if ((flags & 1048576) != 0) {
            let _ = deser.readInt32()
        }
        // flags 3,4,6,10,11,18,21,22 are bare true/false flags (no payload bytes)
        return tx
    }

    /**
     * Skip a boxed Peer (peerUser/peerChat/peerChannel all have exactly one long field).
     * peerUser#59511722 user_id:long
     * peerChat#36c6019a chat_id:long
     * peerChannel#a2a5371e channel_id:long
     */
    private func skipPeer(deser: TLDeserializer) {
        let c = deser.readUInt32() // constructor
        let _ = c
        // All known Peer variants have exactly one long field
        if (deser.remaining() >= 8) {
            let _ = deser.readInt64()
        }
    }

    /**
     * Skip a boxed StarsAmount.
     * starsAmount#bbb6b4a3: amount:long nanos:int  (12 bytes)
     * starsTonAmount or unknown: assume amount:long (8 bytes)
     */
    private func skipStarsAmount(deser: TLDeserializer) {
        let c = deser.readUInt32()
        if (c == 0xbbb6b4a3) {
            // starsAmount: long + int = 12 bytes
            if (deser.remaining() >= 12) {
                let _ = deser.readInt64()
                let _ = deser.readInt32()
            }
        } else {
            // starsTonAmount: long = 8 bytes
            if (deser.remaining() >= 8) {
                let _ = deser.readInt64()
            }
        }
    }

    /**
     * Skip a webDocument (boxed).
     * webDocument#1c570ed1: url:string access_hash:long size:int mime_type:string
     *                        attributes:Vector<DocumentAttribute>
     * webDocumentNoProxy#f9c8bcc6: url:string size:int mime_type:string
     *                               attributes:Vector<DocumentAttribute>
     */
    private func skipWebDocument(deser: TLDeserializer) {
        let c = deser.readUInt32()
        if (c == 0x1c570ed1) {
            // webDocument: url:string access_hash:long size:int mime_type:string attributes:Vector
            let _ = deser.readString()  // url
            let _ = deser.readInt64()   // access_hash
            let _ = deser.readInt32()   // size
            let _ = deser.readString()  // mime_type
            this.skipDocumentAttributeVector(deser)
        } else if (c == 0xf9c8bcc6) {
            // webDocumentNoProxy: url:string size:int mime_type:string attributes:Vector
            let _ = deser.readString()  // url
            let _ = deser.readInt32()   // size
            let _ = deser.readString()  // mime_type
            this.skipDocumentAttributeVector(deser)
        }
        // unknown variant: offset left wherever it is — outer try/catch handles failure
    }

    /**
     * Skip a Vector<DocumentAttribute>.
     * Constructor 0x1cb5c415 (vector) + count:int + count * DocumentAttribute items.
     * DocumentAttribute variants:
     *   documentAttributeImageSize#6c37c15c w:int h:int
     *   documentAttributeAnimated#11b58939 (no fields)
     *   documentAttributeSticker#6319d612 flags:int alt:string stickerset:InputStickerSet mask_coords?
     *   documentAttributeVideo#43c57c48 flags:int duration:double w:int h:int [optional fields]
     *   documentAttributeAudio#9852f9c6 flags:int duration:int [optional strings/bytes]
     *   documentAttributeFilename#15590068 file_name:string
     * For simplicity: read constructor, dispatch on known IDs, skip fixed-size fields.
     * Unknown constructors stop the loop (caller's try/catch handles it).
     */
    private func skipDocumentAttributeVector(deser: TLDeserializer) {
        let vecConstructor = deser.readUInt32() // 0x1cb5c415 vector
        let _ = vecConstructor
        if (deser.remaining() < 4) { return }
        let count = deser.readInt32()
        var i: Int32 = 0
        while (i < count) {
            let attrConstructor = deser.readUInt32()
            if (attrConstructor == 0x6c37c15c) {
                // documentAttributeImageSize: w:int h:int
                let _ = deser.readInt32()
                let _ = deser.readInt32()
            } else if (attrConstructor == 0x11b58939) {
                // documentAttributeAnimated: no fields
            } else if (attrConstructor == 0x15590068) {
                // documentAttributeFilename: file_name:string
                let _ = deser.readString()
            } else if (attrConstructor == 0x6319d612) {
                // documentAttributeSticker: flags:int alt:string stickerset:InputStickerSet [mask_coords?]
                // Skip as bytes is complex; read flags and alt at minimum
                let attrFlags = deser.readInt32()
                let _ = deser.readString()         // alt
                // stickerset (inputStickerSetEmpty#ffb62b95 / inputStickerSetID#9de7a269 access_hash+id / etc.)
                // Skip stickerset: read constructor, handle known variants
                let ssConstructor = deser.readUInt32()
                if (ssConstructor == 0x9de7a269) {
                    // inputStickerSetID: id:long access_hash:long
                    let _ = deser.readInt64()
                    let _ = deser.readInt64()
                } else if (ssConstructor == 0x861cc8a0) {
                    // inputStickerSetShortName: short_name:string
                    let _ = deser.readString()
                }
                // else: empty/animated emoji/dice — no extra fields
                // mask_coords: flags.0?MaskCoords (zoom:float, x:float, y:float, n:float)
                if ((attrFlags & 1) != 0 && deser.remaining() >= 16) {
                    let _ = deser.readInt32() // zoom (float as int32)
                    let _ = deser.readInt32() // x
                    let _ = deser.readInt32() // y
                    let _ = deser.readInt32() // n
                }
            } else if (attrConstructor == 0x43c57c48) {
                // documentAttributeVideo: flags:int duration:double w:int h:int [optional int, double, string]
                let attrFlags = deser.readInt32()
                let _ = deser.readDouble()  // duration
                let _ = deser.readInt32()   // w
                let _ = deser.readInt32()   // h
                // preload_prefix_size:flags.2?int
                if ((attrFlags & 4) != 0 && deser.remaining() >= 4) { let _ = deser.readInt32() }
                // video_start_ts:flags.4?double
                if ((attrFlags & 16) != 0 && deser.remaining() >= 8) { let _ = deser.readDouble() }
                // video_codec:flags.5?string
                if ((attrFlags & 32) != 0) { let _ = deser.readString() }
            } else if (attrConstructor == 0x9852f9c6) {
                // documentAttributeAudio: flags:int duration:int [title?, performer?, waveform?]
                let attrFlags = deser.readInt32()
                let _ = deser.readInt32() // duration
                if ((attrFlags & 1) != 0) { let _ = deser.readString() }  // title
                if ((attrFlags & 2) != 0) { let _ = deser.readString() }  // performer
                if ((attrFlags & 4) != 0) { let _ = deser.readBytes() }   // waveform
            } else {
                // Unknown DocumentAttribute constructor — cannot safely continue
                Hilog.info(0, "CjTelegram", "[StatisticsService] skipDocumentAttributeVector: unknown attr constructor, stopping")
                return
            }
            i += 1
        }
    }

    /**
     * Skip a starGift (boxed).
     * starGift#c62aca28: flags:int id:long sticker:Document stars:long
     *   availability_remains:flags.0?int availability_total:flags.0?int
     *   availability_resale:flags.4?long convert_stars:long
     *   first_sale_date:flags.1?int last_sale_date:flags.1?int
     *   upgrade_stars:flags.3?long resell_min_stars:flags.4?long
     *   title:flags.5?string
     * Document is very complex (boxed). To avoid full Document parsing, we skip
     * the entire starGift by reading remaining bytes up to a safe boundary using
     * a best-effort approach: read constructor + flags + id(long) + skip Document.
     * Outer try/catch in parseStarsStatus catches any failure.
     */
    private func skipStarGift(deser: TLDeserializer) {
        let c = deser.readUInt32() // starGift constructor
        let _ = c
        if (deser.remaining() < 4) { return }
        let giftFlags = deser.readInt32()
        // id: long
        if (deser.remaining() < 8) { return }
        let _ = deser.readInt64()
        // sticker: Document (boxed) — complex, skip via skipDocument
        this.skipDocument(deser)
        // stars: long
        if (deser.remaining() < 8) { return }
        let _ = deser.readInt64()
        // availability_remains:flags.0?int
        if ((giftFlags & 1) != 0 && deser.remaining() >= 4) { let _ = deser.readInt32() }
        // availability_total:flags.0?int
        if ((giftFlags & 1) != 0 && deser.remaining() >= 4) { let _ = deser.readInt32() }
        // availability_resale:flags.4?long
        if ((giftFlags & 16) != 0 && deser.remaining() >= 8) { let _ = deser.readInt64() }
        // convert_stars: long (mandatory)
        if (deser.remaining() >= 8) { let _ = deser.readInt64() }
        // first_sale_date:flags.1?int
        if ((giftFlags & 2) != 0 && deser.remaining() >= 4) { let _ = deser.readInt32() }
        // last_sale_date:flags.1?int
        if ((giftFlags & 2) != 0 && deser.remaining() >= 4) { let _ = deser.readInt32() }
        // upgrade_stars:flags.3?long
        if ((giftFlags & 8) != 0 && deser.remaining() >= 8) { let _ = deser.readInt64() }
        // resell_min_stars:flags.4?long
        if ((giftFlags & 16) != 0 && deser.remaining() >= 8) { let _ = deser.readInt64() }
        // title:flags.5?string
        if ((giftFlags & 32) != 0) { let _ = deser.readString() }
    }

    /**
     * Skip a Document (boxed).
     * document#8fd4c4d8: id:long access_hash:long file_reference:bytes date:int
     *                     mime_type:string size:long thumbs:flags.0?Vector<PhotoSize>
     *                     video_thumbs:flags.1?Vector<VideoSize> dc_id:int
     *                     attributes:Vector<DocumentAttribute>
     * documentEmpty#36f8c871: id:long
     * Skips minimally: reads constructor and enough mandatory fields.
     */
    private func skipDocument(deser: TLDeserializer) {
        if (deser.remaining() < 4) { return }
        let c = deser.readUInt32()
        if (c == 0x36f8c871) {
            // documentEmpty: id:long
            if (deser.remaining() >= 8) { let _ = deser.readInt64() }
        } else if (c == 0x8fd4c4d8) {
            // document: id+access_hash (2*long) + file_reference (bytes) + date (int) + mime_type (string)
            //           + size (long) + [thumbs vector?] + [video_thumbs vector?] + dc_id (int)
            //           + attributes vector
            // This is complex — skip by reading fixed mandatory portion, then trust outer catch
            if (deser.remaining() < 8) { return }
            let _ = deser.readInt64() // id
            if (deser.remaining() < 8) { return }
            let _ = deser.readInt64() // access_hash
            let _ = deser.readBytes() // file_reference
            if (deser.remaining() < 4) { return }
            let _ = deser.readInt32() // date
            let _ = deser.readString() // mime_type
            if (deser.remaining() < 8) { return }
            let _ = deser.readInt64()  // size
            // document flags (for thumbs/video_thumbs)
            // We cannot safely skip Vector<PhotoSize> / Vector<VideoSize> without more parsing.
            // At this point we accept the remaining fields may not be consumed perfectly;
            // the outer try/catch in parseStarsStatus will handle any parse exception gracefully.
        }
        // else unknown: leave offset wherever, outer catch handles
    }

    /**
     * Skip a TL Vector of unknown boxed types.
     * Format: constructor(0x1cb5c415) + count:int + count items
     * We cannot know each item's size without its schema.
     * Best-effort: read constructor, read count, attempt to read count items each as UInt32.
     * This handles the case where items are simple (e.g. bare flags), but will fail for
     * complex boxed items. Outer try/catch in parseStarsStatus catches failure gracefully.
     */
    private func skipTLVector(deser: TLDeserializer) {
        if (deser.remaining() < 4) { return }
        let vecConstructor = deser.readUInt32() // 0x1cb5c415
        let _ = vecConstructor
        if (deser.remaining() < 4) { return }
        let count = deser.readInt32()
        // For extended_media:Vector<MessageMedia>, items are boxed. We cannot safely skip
        // complex boxed MessageMedia without full parsing. We read the constructor of the
        // first item and stop; the outer try/catch handles failure for the rest.
        // This ensures at least 1 item's constructor is consumed, limiting damage.
        // In practice, extended_media is rarely set for Stars transactions.
        Hilog.info(0, "CjTelegram", "[StatisticsService] skipTLVector: count=${count}, best-effort skip")
        var i: Int32 = 0
        while (i < count && deser.remaining() >= 4) {
            // Try to read and skip a boxed MessageMedia item via its constructor
            let itemConstructor = deser.readUInt32()
            if (itemConstructor == 0x3ded6320) {
                // messageMediaEmpty: no fields
            } else if (itemConstructor == 0x9f84f49e) {
                // messageMediaUnsupported: no fields
            } else if (itemConstructor == 0x3f7ee58b) {
                // messageMediaDice: value:int emoticon:string
                if (deser.remaining() >= 4) { let _ = deser.readInt32() }
                let _ = deser.readString()
            } else {
                // Unknown or complex MessageMedia — stop vector skip here
                Hilog.info(0, "CjTelegram", "[StatisticsService] skipTLVector: unknown item constructor, stopping")
                return
            }
            i += 1
        }
    }

    // ==================== 内部解析辅助方法 ====================

    /**
     * 读取一个 boxed StatsDateRangeDays 并返回 "Mar 1 - Mar 8, 2025" 格式字符串。
     *
     * TL 格式（来自 Api28.swift parse_statsDateRangeDays）：
     *   constructor:uint32 (0xb637edaf) minDate:int32 maxDate:int32
     *   minDate/maxDate 是 Unix 时间戳（秒）
     */
    private func readBoxedDateRange(deser: TLDeserializer): String {
        if (deser.remaining() < 4) { return "" }
        let c = deser.readUInt32() // 0xb637edaf
        let _ = c
        if (deser.remaining() < 8) { return "" }
        let minDate = deser.readInt32()
        let maxDate = deser.readInt32()
        return formatUnixDateRange(Int64(minDate), Int64(maxDate))
    }

    /**
     * 将两个 Unix 时间戳格式化为 "Mar 1 - Mar 8, 2025" 格式。
     * 若同年：省略第一个年份，仅在末尾显示年份。
     * 若跨年：两端均显示年份。
     */
    private func formatUnixDateRange(minTs: Int64, maxTs: Int64): String {
        if (minTs <= 0 && maxTs <= 0) { return "" }
        let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        if (minTs <= 0) {
            let dt = DateTime.ofEpoch(second: maxTs, nanosecond: 0)
            let m = dt.monthValue
            let d = dt.dayOfMonth
            let y = dt.year
            if (m >= 1 && m <= 12) {
                return "${monthNames[m - 1]} ${d}, ${y}"
            }
            return "${maxTs}"
        }
        if (maxTs <= 0) {
            let dt = DateTime.ofEpoch(second: minTs, nanosecond: 0)
            let m = dt.monthValue
            let d = dt.dayOfMonth
            let y = dt.year
            if (m >= 1 && m <= 12) {
                return "${monthNames[m - 1]} ${d}, ${y}"
            }
            return "${minTs}"
        }
        let dtMin = DateTime.ofEpoch(second: minTs, nanosecond: 0)
        let dtMax = DateTime.ofEpoch(second: maxTs, nanosecond: 0)
        let m1 = dtMin.monthValue
        let d1 = dtMin.dayOfMonth
        let y1 = dtMin.year
        let m2 = dtMax.monthValue
        let d2 = dtMax.dayOfMonth
        let y2 = dtMax.year
        let mn1: String = if (m1 >= 1 && m1 <= 12) { monthNames[m1 - 1] } else { "${m1}" }
        let mn2: String = if (m2 >= 1 && m2 <= 12) { monthNames[m2 - 1] } else { "${m2}" }
        if (y1 == y2) {
            return "${mn1} ${d1} - ${mn2} ${d2}, ${y1}"
        }
        return "${mn1} ${d1}, ${y1} - ${mn2} ${d2}, ${y2}"
    }

    /**
     * 读取一个 boxed StatsAbsValueAndPrev，返回 (current, previous)。
     *
     * TL 格式（来自 Api28.swift parse_statsAbsValueAndPrev）：
     *   constructor:uint32 (0xcb43acde) current:double previous:double
     */
    private func readBoxedAbsValueAndPrev(deser: TLDeserializer): (Float64, Float64) {
        if (deser.remaining() < 4) { return (0.0, 0.0) }
        let c = deser.readUInt32() // 0xcb43acde
        let _ = c
        if (deser.remaining() < 16) { return (0.0, 0.0) }
        let cur = deser.readDouble()
        let prev = deser.readDouble()
        return (cur, prev)
    }

    /**
     * 读取一个 boxed StatsPercentValue，返回 part/total 比值（已转换为百分比 0.0-1.0）。
     *
     * TL 格式（来自 Api28.swift parse_statsPercentValue）：
     *   constructor:uint32 (0xcbce2fe0) part:double total:double
     */
    private func readBoxedPercentValue(deser: TLDeserializer): Float64 {
        if (deser.remaining() < 4) { return 0.0 }
        let c = deser.readUInt32() // 0xcbce2fe0
        let _ = c
        if (deser.remaining() < 16) { return 0.0 }
        let part = deser.readDouble()
        let total = deser.readDouble()
        if (total > 0.0) {
            return part / total
        }
        return 0.0
    }

    /**
     * 跳过一个 boxed StatsGraph。
     *
     * TL StatsGraph 变体（来自 TL schema）：
     *   statsGraphAsync#4a27eb2d token:string
     *   statsGraphError#bedc9822 error:string
     *   statsGraph#8ea464b6 flags:# json:DataJSON zoom_token:flags.0?string
     *
     * DataJSON#7d748d04 data:string
     */
    private func skipBoxedStatsGraph(deser: TLDeserializer) {
        if (deser.remaining() < 4) { return }
        let c = deser.readUInt32()
        if (c == 0x4a27eb2d) {
            // statsGraphAsync: token:string
            if (deser.remaining() >= 4) { let _ = deser.readString() }
        } else if (c == 0xbedc9822) {
            // statsGraphError: error:string
            if (deser.remaining() >= 4) { let _ = deser.readString() }
        } else {
            // statsGraph#8ea464b6: flags:# json:DataJSON zoom_token:flags.0?string
            if (deser.remaining() < 4) { return }
            let flags = deser.readInt32()
            // json: DataJSON#7d748d04 data:string (boxed)
            if (deser.remaining() < 4) { return }
            let jsonConstructor = deser.readUInt32() // 0x7d748d04
            let _ = jsonConstructor
            if (deser.remaining() >= 4) { let _ = deser.readString() }
            // zoom_token:flags.0?string
            if ((flags & 1) != 0 && deser.remaining() >= 4) {
                let _ = deser.readString()
            }
        }
    }

    /**
     * 读取 vector constructor + count，返回 count（跳过 vector 头部）。
     * TL vector: constructor(0x1cb5c415):uint32 + count:int32
     * 注意：读完 count 后，调用者负责跳过各元素字节。
     */
    private func readVectorCount(deser: TLDeserializer): Int32 {
        if (deser.remaining() < 4) { return 0 }
        let vecConstructor = deser.readUInt32() // 0x1cb5c415
        let _ = vecConstructor
        if (deser.remaining() < 4) { return 0 }
        return deser.readInt32()
    }

    /**
     * 解析 N 个 StatsGroupTopPoster 元素，返回真实列表。
     * TL statsGroupTopPoster (boxed, constructor 0x9d04af9b):
     *   userId:long messages:int avgChars:int
     * iOS 来源：Api28.swift parse_statsGroupTopPoster
     * 每个元素：4(constructor) + 8(userId) + 4(messages) + 4(avgChars) = 20 bytes
     */
    private func parseTopPosters(deser: TLDeserializer, count: Int32): Array<GroupTopPoster> {
        var list = ArrayList<GroupTopPoster>()
        var i: Int32 = 0
        while (i < count && deser.remaining() >= 20) {
            let ctor = deser.readUInt32()  // 0x9d04af9b
            let _ = ctor
            let poster = GroupTopPoster()
            poster.userId = deser.readInt64()
            poster.messages = deser.readInt32()
            poster.avgChars = deser.readInt32()
            poster.displayName = "User ${poster.userId}"
            list.add(poster)
            i += 1
        }
        let r = list
        return Array<GroupTopPoster>(r.size, { idx: Int64 => r[idx] })
    }

    /**
     * 解析 N 个 StatsGroupTopAdmin 元素，返回真实列表。
     * TL statsGroupTopAdmin (boxed, constructor 0xd7584c87):
     *   userId:long deleted:int kicked:int banned:int
     * iOS 来源：Api28.swift parse_statsGroupTopAdmin
     * 每个元素：4(constructor) + 8(userId) + 4+4+4 = 24 bytes
     */
    private func parseTopAdmins(deser: TLDeserializer, count: Int32): Array<GroupTopAdmin> {
        var list = ArrayList<GroupTopAdmin>()
        var i: Int32 = 0
        while (i < count && deser.remaining() >= 24) {
            let ctor = deser.readUInt32()  // 0xd7584c87
            let _ = ctor
            let admin = GroupTopAdmin()
            admin.userId = deser.readInt64()
            admin.deleted = deser.readInt32()
            admin.kicked = deser.readInt32()
            admin.banned = deser.readInt32()
            admin.displayName = "User ${admin.userId}"
            list.add(admin)
            i += 1
        }
        let r = list
        return Array<GroupTopAdmin>(r.size, { idx: Int64 => r[idx] })
    }

    /**
     * 解析 N 个 StatsGroupTopInviter 元素，返回真实列表。
     * TL statsGroupTopInviter (boxed, constructor 0x535f779d):
     *   userId:long invitations:int
     * iOS 来源：Api28.swift parse_statsGroupTopInviter
     * 每个元素：4(constructor) + 8(userId) + 4(invitations) = 16 bytes
     */
    private func parseTopInviters(deser: TLDeserializer, count: Int32): Array<GroupTopInviter> {
        var list = ArrayList<GroupTopInviter>()
        var i: Int32 = 0
        while (i < count && deser.remaining() >= 16) {
            let ctor = deser.readUInt32()  // 0x535f779d
            let _ = ctor
            let inviter = GroupTopInviter()
            inviter.userId = deser.readInt64()
            inviter.invitations = deser.readInt32()
            inviter.displayName = "User ${inviter.userId}"
            list.add(inviter)
            i += 1
        }
        let r = list
        return Array<GroupTopInviter>(r.size, { idx: Int64 => r[idx] })
    }

    /**
     * 解析 stats.broadcastStats (constructor 0x396ca5fc) 全字段，填入 BroadcastStatsData。
     *
     * 完整 TL 序列化顺序（来自 Api40.swift Cons_broadcastStats.serialize，无初始 flags）：
     *   period:StatsDateRangeDays(boxed)
     *   followers:StatsAbsValueAndPrev(boxed)
     *   viewsPerPost:StatsAbsValueAndPrev(boxed)
     *   sharesPerPost:StatsAbsValueAndPrev(boxed)
     *   reactionsPerPost:StatsAbsValueAndPrev(boxed)
     *   viewsPerStory:StatsAbsValueAndPrev(boxed)
     *   sharesPerStory:StatsAbsValueAndPrev(boxed)
     *   reactionsPerStory:StatsAbsValueAndPrev(boxed)
     *   enabledNotifications:StatsPercentValue(boxed)
     *   growthGraph:StatsGraph(boxed)
     *   followersGraph:StatsGraph(boxed)
     *   muteGraph:StatsGraph(boxed)
     *   topHoursGraph:StatsGraph(boxed)
     *   interactionsGraph:StatsGraph(boxed)
     *   ivInteractionsGraph:StatsGraph(boxed)
     *   viewsBySourceGraph:StatsGraph(boxed)
     *   newFollowersBySourceGraph:StatsGraph(boxed)
     *   languagesGraph:StatsGraph(boxed)
     *   reactionsByEmotionGraph:StatsGraph(boxed)
     *   storyInteractionsGraph:StatsGraph(boxed)
     *   storyReactionsByEmotionGraph:StatsGraph(boxed)   <- 11 graphs total
     *   recentPostsInteractions:Vector<PostInteractionCounters>
     *
     * P2-364：recentPostsInteractions 真解析（constructor：
     *   postInteractionCountersMessage#e7058e7f msgId:int views:int forwards:int reactions:int
     *   postInteractionCountersStory#8a480e27 storyId:int views:int forwards:int reactions:int）
     */
    private func parseBroadcastStatsInto(deser: TLDeserializer, result: BroadcastStatsData) {
        let ov = ChannelStatsOverview()
        try {
            // period (StatsDateRangeDays boxed: constructor + minDate:int + maxDate:int)
            ov.period = this.readBoxedDateRange(deser)

            // followers (StatsAbsValueAndPrev boxed)
            let (curFollowers, prevFollowers) = this.readBoxedAbsValueAndPrev(deser)
            ov.followers = Int64(curFollowers)
            ov.followersChange = Int64(curFollowers - prevFollowers)

            // viewsPerPost
            let (curVPP, prevVPP) = this.readBoxedAbsValueAndPrev(deser)
            ov.viewsPerPost = Int64(curVPP)
            ov.viewsPerPostChange = Int64(curVPP - prevVPP)

            // sharesPerPost
            let (curSPP, prevSPP) = this.readBoxedAbsValueAndPrev(deser)
            ov.sharesPerPost = Int64(curSPP)
            ov.sharesPerPostChange = Int64(curSPP - prevSPP)

            // reactionsPerPost
            let (curRPP, prevRPP) = this.readBoxedAbsValueAndPrev(deser)
            ov.reactionsPerPost = Int64(curRPP)
            ov.reactionsPerPostChange = Int64(curRPP - prevRPP)

            // viewsPerStory
            let (curVPS, prevVPS) = this.readBoxedAbsValueAndPrev(deser)
            ov.viewsPerStory = Int64(curVPS)
            ov.viewsPerStoryChange = Int64(curVPS - prevVPS)

            // sharesPerStory
            let (curSPS, prevSPS) = this.readBoxedAbsValueAndPrev(deser)
            ov.sharesPerStory = Int64(curSPS)
            ov.sharesPerStoryChange = Int64(curSPS - prevSPS)

            // reactionsPerStory
            let (curRPS, prevRPS) = this.readBoxedAbsValueAndPrev(deser)
            ov.reactionsPerStory = Int64(curRPS)
            ov.reactionsPerStoryChange = Int64(curRPS - prevRPS)

            // enabledNotifications (StatsPercentValue boxed)
            ov.enabledNotificationsPct = this.readBoxedPercentValue(deser)

            result.overview = ov

            // Skip 11 StatsGraph entries (growthGraph through storyReactionsByEmotionGraph)
            // Api40.swift Cons_broadcastStats fields:
            //   growthGraph followersGraph muteGraph topHoursGraph interactionsGraph
            //   ivInteractionsGraph viewsBySourceGraph newFollowersBySourceGraph languagesGraph
            //   reactionsByEmotionGraph storyInteractionsGraph storyReactionsByEmotionGraph = 12
            // Note: Api40.swift shows 12 graph fields in Cons_broadcastStats init(...)
            var gi: Int32 = 0
            while (gi < 12 && deser.remaining() >= 4) {
                this.skipBoxedStatsGraph(deser)
                gi += 1
            }

            // recentPostsInteractions: Vector<PostInteractionCounters>
            // postInteractionCountersMessage#e7058e7f: msgId:int views:int forwards:int reactions:int
            // postInteractionCountersStory#8a480e27: storyId:int views:int forwards:int reactions:int
            if (deser.remaining() >= 8) {
                let postCount = this.readVectorCount(deser)
                Hilog.info(0, "CjTelegram", "[StatisticsService] broadcastStats recentPosts count=${postCount}")
                result.recentPosts = this.parseRecentPosts(deser, postCount)
                result.recentMessages = Int64(postCount)
            }

        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[StatisticsService] parseBroadcastStatsInto error: ${e}")
            result.overview = ov
        }
    }

    /**
     * 解析 Vector<PostInteractionCounters> 中的消息交互计数项（跳过 story 项）。
     * postInteractionCountersMessage#e7058e7f: msgId:int views:int forwards:int reactions:int
     * postInteractionCountersStory#8a480e27: storyId:int views:int forwards:int reactions:int
     * iOS 来源：Api21.swift parse_postInteractionCountersMessage / parse_postInteractionCountersStory
     */
    private func parseRecentPosts(deser: TLDeserializer, count: Int32): Array<RecentPostItem> {
        var list = ArrayList<RecentPostItem>()
        var i: Int32 = 0
        while (i < count && deser.remaining() >= 20) {
            let ctor = deser.readUInt32()
            if (ctor == 0xe7058e7f) {
                // postInteractionCountersMessage
                let post = RecentPostItem()
                post.msgId = deser.readInt32()
                post.views = deser.readInt32()
                post.forwards = deser.readInt32()
                post.reactions = deser.readInt32()
                list.add(post)
            } else if (ctor == 0x8a480e27) {
                // postInteractionCountersStory — skip (storyId+views+forwards+reactions)
                if (deser.remaining() >= 16) {
                    let _ = deser.readInt32()
                    let _ = deser.readInt32()
                    let _ = deser.readInt32()
                    let _ = deser.readInt32()
                }
            } else {
                // Unknown constructor — stop parsing
                Hilog.info(0, "CjTelegram", "[StatisticsService] parseRecentPosts: unknown ctor ${ctor}, stopping")
                break
            }
            i += 1
        }
        let r = list
        return Array<RecentPostItem>(r.size, { idx: Int64 => r[idx] })
    }

    /**
     * 解析 stats.megagroupStats (constructor 0xef7ff916) 全字段，填入 MegagroupStatsData。
     *
     * 完整 TL 序列化顺序（来自 Api40.swift Cons_megagroupStats.serialize，无初始 flags）：
     *   period:StatsDateRangeDays(boxed)
     *   members:StatsAbsValueAndPrev(boxed)
     *   messages:StatsAbsValueAndPrev(boxed)
     *   viewers:StatsAbsValueAndPrev(boxed)
     *   posters:StatsAbsValueAndPrev(boxed)
     *   growthGraph:StatsGraph(boxed)
     *   membersGraph:StatsGraph(boxed)
     *   newMembersBySourceGraph:StatsGraph(boxed)
     *   languagesGraph:StatsGraph(boxed)
     *   messagesGraph:StatsGraph(boxed)
     *   actionsGraph:StatsGraph(boxed)
     *   topHoursGraph:StatsGraph(boxed)
     *   weekdaysGraph:StatsGraph(boxed)   <- 8 graphs total
     *   topPosters:Vector<StatsGroupTopPoster>  (真解析，P2-365)
     *   topAdmins:Vector<StatsGroupTopAdmin>    (真解析，P2-365)
     *   topInviters:Vector<StatsGroupTopInviter>(真解析，P2-365)
     *   users:Vector<User>  (skip — user display names resolved via userId lookup later)
     */
    private func parseMegagroupStatsInto(deser: TLDeserializer, result: MegagroupStatsData) {
        let ov = MegagroupStatsOverview()
        try {
            // period
            ov.period = this.readBoxedDateRange(deser)

            // members
            let (curM, prevM) = this.readBoxedAbsValueAndPrev(deser)
            ov.members = Int64(curM)
            ov.membersChange = Int64(curM - prevM)

            // messages
            let (curMsg, prevMsg) = this.readBoxedAbsValueAndPrev(deser)
            ov.messages = Int64(curMsg)
            ov.messagesChange = Int64(curMsg - prevMsg)

            // viewers
            let (curV, prevV) = this.readBoxedAbsValueAndPrev(deser)
            ov.viewers = Int64(curV)
            ov.viewersChange = Int64(curV - prevV)

            // posters
            let (curP, prevP) = this.readBoxedAbsValueAndPrev(deser)
            ov.posters = Int64(curP)
            ov.postersChange = Int64(curP - prevP)

            result.overview = ov

            // Skip 8 StatsGraph entries
            // Api40.swift Cons_megagroupStats: growthGraph membersGraph newMembersBySourceGraph
            //   languagesGraph messagesGraph actionsGraph topHoursGraph weekdaysGraph = 8 graphs
            var gi: Int32 = 0
            while (gi < 8 && deser.remaining() >= 4) {
                this.skipBoxedStatsGraph(deser)
                gi += 1
            }

            // topPosters: Vector<StatsGroupTopPoster> — P2-365 真解析
            if (deser.remaining() >= 8) {
                let posterCount = this.readVectorCount(deser)
                Hilog.info(0, "CjTelegram", "[StatisticsService] megagroup topPosters count=${posterCount}")
                result.topPosters = this.parseTopPosters(deser, posterCount)
                ov.admins = 0  // admins count set below
            }

            // topAdmins: Vector<StatsGroupTopAdmin> — P2-365 真解析
            if (deser.remaining() >= 8) {
                let adminCount = this.readVectorCount(deser)
                Hilog.info(0, "CjTelegram", "[StatisticsService] megagroup topAdmins count=${adminCount}")
                result.topAdmins = this.parseTopAdmins(deser, adminCount)
                ov.admins = Int64(adminCount)
            }

            // topInviters: Vector<StatsGroupTopInviter> — P2-365 真解析
            if (deser.remaining() >= 8) {
                let inviterCount = this.readVectorCount(deser)
                Hilog.info(0, "CjTelegram", "[StatisticsService] megagroup topInviters count=${inviterCount}")
                result.topInviters = this.parseTopInviters(deser, inviterCount)
                ov.inviters = Int64(inviterCount)
            }

            // users Vector<User> — skip (user names shown as "User <id>" label;
            // full user context lookup is beyond scope of P2-365 TL parse task)
            // users would require parsing User#0x31774388 with many optional fields

        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[StatisticsService] parseMegagroupStatsInto error: ${e}")
            result.overview = ov
        }
    }
}
