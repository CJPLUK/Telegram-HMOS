package ohos_app_cangjie_entry.services

import std.collection.ArrayList
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
 * stats.getMessageStats — 获取消息统计数据
 * Constructor: 0xb6e0a3f5
 * flags:# dark:flags.0?true channel:InputChannel msgId:int = stats.MessageStats
 *
 * 注：channel 使用 buildInputPeer 返回的 InputPeerChannel，与 InputChannel 字段布局相同。
 */
private class StatsGetMessageStats <: TLObject {
    public var dark: Bool = false
    public var channel: TLObject = InputPeerEmpty()
    public var msgId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xb6e0a3f5 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.dark) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeInt32(this.msgId)
    }
}

/**
 * stats.getMessagePublicForwards — 获取转发此消息的公开频道列表
 * Constructor: 0x5f150144  (int32: 1595212100)
 * channel:InputChannel msg_id:int offset:string limit:int = stats.PublicForwards
 *
 * iOS 来源：Api42.swift buffer.appendInt32(1595212100) + channel + msgId + offset + limit
 */
private class StatsGetMessagePublicForwards <: TLObject {
    public var channel: TLObject = InputPeerEmpty()
    public var msgId: Int32 = 0
    public var offset: String = ""
    public var limit: Int32 = 20

    public func getConstructorId(): UInt32 { return 0x5f150144 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.channel.toBytes())
        serializer.writeInt32(this.msgId)
        serializer.writeString(this.offset)
        serializer.writeInt32(this.limit)
    }
}

/**
 * stats.getStoryStats — 获取 Story 统计数据
 * Constructor: 0x374fef40
 * flags:# dark:flags.0?true peer:InputPeer id:int = stats.StoryStats
 */
private class StatsGetStoryStats <: TLObject {
    public var dark: Bool = false
    public var peer: TLObject = InputPeerEmpty()
    public var storyId: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x374fef40 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.dark) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.storyId)
    }
}

// ==================== 数据模型 ====================

/**
 * 消息统计数据（对应 iOS MessageStats）
 * stats.messageStats#7fe91c14 viewsGraph:StatsGraph reactionsByEmotionGraph:StatsGraph
 */
public class MessageStatsData {
    public var views: Int64 = 0
    public var forwards: Int64 = 0
    public var reactions: Int64 = 0
    public var viewsGraphToken: String = ""
    public var reactionsGraphToken: String = ""
    public var isLoaded: Bool = false

    public init() {}
}

/**
 * Story 统计数据（对应 iOS StoryStats）
 * stats.storyStats#50cd067c viewsGraph:StatsGraph reactionsByEmotionGraph:StatsGraph
 */
public class StoryStatsData {
    public var viewsGraphToken: String = ""
    public var reactionsGraphToken: String = ""
    public var isLoaded: Bool = false

    public init() {}
}

/**
 * Public Forward 条目 —— 表示某个公开频道转发了此消息。
 * 来自 stats.getMessagePublicForwards 响应中的 publicForwardMessage(0x01f2bf4a)。
 * channelTitle 从 Message.peer_id 字段（Peer boxed）提取频道 ID 构造显示文本。
 */
public class PublicForwardItem {
    public var channelTitle: String = ""
    public var msgId: Int32 = 0
    public var views: Int32 = 0

    public init() {}
}

// ==================== 服务单例工厂 ====================

private var _tcStatisticsServiceInstance: Option<TelegramCore_StatisticsService> = None

public func getTelegramCore_StatisticsService(): TelegramCore_StatisticsService {
    match (_tcStatisticsServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCore_StatisticsService()
            _tcStatisticsServiceInstance = Some(inst)
            return inst
    }
}

// ==================== TelegramCore_StatisticsService ====================

/**
 * TelegramCore 统计数据引擎服务
 *
 * 封装所有统计相关的 TL 方法调用，供 TelegramCore_StatisticsAdapter 使用。
 * 复用 StatisticsService 中的 getBroadcastStats / getMegagroupStats / loadAsyncGraph /
 * getStarsTransactions 能力；新增 getMessageStats / getStoryStats。
 *
 * 调用链（消息统计）：
 *   TelegramCore_StatisticsService.getMessageStats(peerType, peerId, msgId)
 *     → getRealMessageService().buildInputPeer(peerType, peerId)
 *     → StatsGetMessageStats.toBytes()
 *     → getMTProtoClient().sendRequest()
 *     → 解析响应 stats.messageStats#7fe91c14 → MessageStatsData
 *
 * 调用链（Story 统计）：
 *   TelegramCore_StatisticsService.getStoryStats(peerType, peerId, storyId)
 *     → getRealMessageService().buildInputPeer(peerType, peerId)
 *     → StatsGetStoryStats.toBytes()
 *     → getMTProtoClient().sendRequest()
 *     → 解析响应 stats.storyStats#50cd067c → StoryStatsData
 */
public class TelegramCore_StatisticsService {

    public init() {}

    // ==================== 委托 StatisticsService 能力 ====================

    /**
     * 获取频道广播统计数据
     * TL 方法：stats.getBroadcastStats (0xab42441a)
     * 调用链：→ StatisticsService.getBroadcastStats → getMTProtoClient().sendRequest()
     */
    public func getBroadcastStats(peerType: String, peerId: Int64): BroadcastStatsData {
        return getStatisticsService().getBroadcastStats(peerType, peerId)
    }

    /**
     * 获取超级群组统计数据
     * TL 方法：stats.getMegagroupStats (0xdcdf8607)
     * 调用链：→ StatisticsService.getMegagroupStats → getMTProtoClient().sendRequest()
     */
    public func getMegagroupStats(peerType: String, peerId: Int64): MegagroupStatsData {
        return getStatisticsService().getMegagroupStats(peerType, peerId)
    }

    /**
     * 加载异步图表数据
     * TL 方法：stats.loadAsyncGraph (0x621d5f84)
     * 调用链：→ StatisticsService.loadAsyncGraph → getMTProtoClient().sendRequest()
     */
    public func loadAsyncGraph(token: String, x!: Int64 = -1): GraphStats {
        return getStatisticsService().loadAsyncGraph(token, x: x)
    }

    /**
     * 获取 Stars 星币交易列表
     * TL 方法：payments.getStarsTransactions (0x69da4557)
     * 调用链：→ StatisticsService.getStarsTransactions → getMTProtoClient().sendRequest()
     */
    public func getStarsTransactions(peerType: String, peerId: Int64): Array<StarsTransactionData> {
        return getStatisticsService().getStarsTransactions(peerType, peerId)
    }

    // ==================== 新增 TL 方法 ====================

    /**
     * 获取消息统计数据
     * TL 方法：stats.getMessageStats (0xb6e0a3f5)
     *   flags:# dark:flags.0?true channel:InputChannel msgId:int = stats.MessageStats
     * 响应：stats.messageStats#7fe91c14
     *   viewsGraph:StatsGraph reactionsByEmotionGraph:StatsGraph
     *
     * 调用链：
     *   TelegramCore_StatisticsService.getMessageStats(peerType, peerId, msgId)
     *     → getRealMessageService().buildInputPeer(peerType, peerId)
     *     → StatsGetMessageStats.toBytes()
     *     → getMTProtoClient().sendRequest()
     *     → 解析 stats.messageStats#7fe91c14 → MessageStatsData
     *
     * @param peerType 对话类型（"channel"）
     * @param peerId   频道 ID
     * @param msgId    消息 ID
     * @return MessageStatsData（viewsGraphToken / reactionsGraphToken 供 loadAsyncGraph 使用）
     */
    public func getMessageStats(peerType: String, peerId: Int64, msgId: Int32): MessageStatsData {
        Hilog.info(0, "CjTelegram", "[TCStatisticsService] getMessageStats peerId=${peerId} msgId=${msgId}")
        let result = MessageStatsData()

        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let req = StatsGetMessageStats()
        req.dark = false
        req.channel = inputPeer
        req.msgId = msgId

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] getMessageStats: empty response")
            return result
        }

        let deser = TLDeserializer(responseData)
        let constructor = deser.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errCode = deser.readInt32()
            let errMsg = deser.readString()
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] getMessageStats RPC Error: ${errCode} - ${errMsg}")
            return result
        }

        // stats.messageStats#7fe91c14
        // viewsGraph:StatsGraph reactionsByEmotionGraph:StatsGraph
        if (constructor == 0x7fe91c14) {
            result.viewsGraphToken = this.extractStatsGraphToken(deser)
            result.reactionsGraphToken = this.extractStatsGraphToken(deser)
            result.isLoaded = true
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] getMessageStats loaded viewsGraphToken=${result.viewsGraphToken}")
        } else {
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] getMessageStats: unknown constructor")
        }
        return result
    }

    /**
     * 获取转发此消息的公开频道/群组列表
     * TL 方法：stats.getMessagePublicForwards (0x5f150144)
     *   channel:InputChannel msg_id:int offset:string limit:int = stats.PublicForwards
     * 响应：stats.publicForwards#93037e20 (uint: -1828487648)
     *   flags:# count:int forwards:Vector<PublicForward> next_offset:flags.0?string
     *   chats:Vector<Chat> users:Vector<User>
     *
     * PublicForward 变体：
     *   publicForwardMessage#01f2bf4a message:Message
     *   publicForwardStory#edf3add0 peer:Peer story:StoryItem
     *
     * @param peerType 对话类型（"channel"）
     * @param peerId   频道 ID
     * @param msgId    消息 ID
     * @return Array<PublicForwardItem>（channelTitle = 转发目标频道名称占位）
     */
    public func getMessagePublicForwards(peerType: String, peerId: Int64, msgId: Int32): Array<PublicForwardItem> {
        Hilog.info(0, "CjTelegram", "[TCStatisticsService] getMessagePublicForwards peerId=${peerId} msgId=${msgId}")

        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let req = StatsGetMessagePublicForwards()
        req.channel = inputPeer
        req.msgId = msgId
        req.offset = ""
        req.limit = 20

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] getMessagePublicForwards: empty response")
            return Array<PublicForwardItem>(0, { _ => PublicForwardItem() })
        }

        let deser = TLDeserializer(responseData)
        let constructor = deser.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errCode = deser.readInt32()
            let errMsg = deser.readString()
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] getMessagePublicForwards RPC Error: ${errCode} - ${errMsg}")
            return Array<PublicForwardItem>(0, { _ => PublicForwardItem() })
        }

        // stats.publicForwards#93037e20: flags:int count:int forwards:Vector<PublicForward>
        //   next_offset:flags.0?string chats:Vector<Chat> users:Vector<User>
        if (constructor != 0x93037e20) {
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] getMessagePublicForwards: unexpected ctor 0x${constructor}")
            return Array<PublicForwardItem>(0, { _ => PublicForwardItem() })
        }
        return this.parsePublicForwards(deser)
    }

    /**
     * 获取 Story 统计数据
     * TL 方法：stats.getStoryStats (0x374fef40)
     *   flags:# dark:flags.0?true peer:InputPeer id:int = stats.StoryStats
     * 响应：stats.storyStats#50cd067c
     *   viewsGraph:StatsGraph reactionsByEmotionGraph:StatsGraph
     *
     * 调用链：
     *   TelegramCore_StatisticsService.getStoryStats(peerType, peerId, storyId)
     *     → getRealMessageService().buildInputPeer(peerType, peerId)
     *     → StatsGetStoryStats.toBytes()
     *     → getMTProtoClient().sendRequest()
     *     → 解析 stats.storyStats#50cd067c → StoryStatsData
     *
     * @param peerType 对话类型（"channel"）
     * @param peerId   频道 ID
     * @param storyId  Story ID
     * @return StoryStatsData（viewsGraphToken / reactionsGraphToken 供 loadAsyncGraph 使用）
     */
    public func getStoryStats(peerType: String, peerId: Int64, storyId: Int32): StoryStatsData {
        Hilog.info(0, "CjTelegram", "[TCStatisticsService] getStoryStats peerId=${peerId} storyId=${storyId}")
        let result = StoryStatsData()

        let msgSvc = getRealMessageService()
        let inputPeer = msgSvc.buildInputPeer(peerType, peerId)

        let req = StatsGetStoryStats()
        req.dark = false
        req.peer = inputPeer
        req.storyId = storyId

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] getStoryStats: empty response")
            return result
        }

        let deser = TLDeserializer(responseData)
        let constructor = deser.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errCode = deser.readInt32()
            let errMsg = deser.readString()
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] getStoryStats RPC Error: ${errCode} - ${errMsg}")
            return result
        }

        // stats.storyStats#50cd067c
        // viewsGraph:StatsGraph reactionsByEmotionGraph:StatsGraph
        if (constructor == 0x50cd067c) {
            result.viewsGraphToken = this.extractStatsGraphToken(deser)
            result.reactionsGraphToken = this.extractStatsGraphToken(deser)
            result.isLoaded = true
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] getStoryStats loaded viewsGraphToken=${result.viewsGraphToken}")
        } else {
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] getStoryStats: unknown constructor")
        }
        return result
    }

    // ==================== 内部解析辅助 ====================

    /**
     * 从 TLDeserializer 中提取 StatsGraph 的 token 字符串。
     *
     * StatsGraph variants (boxed):
     *   statsGraph#8ea464b6       flags:# json:DataJSON zoom_token:flags.0?string
     *   statsGraphAsync#4a44d3ca  token:string
     *   statsGraphError#bedc9822  error:string
     *
     * 对于 OnDemand (Async) 返回 token；
     * 对于 Loaded (statsGraph) 返回 zoom_token 或空字符串；
     * 对于 Error 返回空字符串。
     */
    private func extractStatsGraphToken(deser: TLDeserializer): String {
        if (deser.remaining() < 4) { return "" }
        let graphConstructor = deser.readUInt32()

        if (graphConstructor == 0x4a44d3ca) {
            // statsGraphAsync: token:string — on-demand graph
            if (deser.remaining() >= 1) {
                return deser.readString()
            }
            return ""
        } else if (graphConstructor == 0xbedc9822) {
            // statsGraphError: error:string — skip and return empty
            if (deser.remaining() >= 1) {
                let _ = deser.readString()
            }
            return ""
        } else if (graphConstructor == 0x8ea464b6) {
            // statsGraph#8ea464b6: flags:# json:DataJSON zoom_token:flags.0?string
            if (deser.remaining() < 4) { return "" }
            let graphFlags = deser.readInt32()
            // json: DataJSON#7d748d04 data:string
            if (deser.remaining() >= 4) {
                let _ = deser.readUInt32() // DataJSON constructor
            }
            if (deser.remaining() >= 1) {
                let _ = deser.readString() // json data
            }
            // zoom_token: flags.0?string
            if ((graphFlags & 1) != 0 && deser.remaining() >= 1) {
                return deser.readString()
            }
            return ""
        }
        // Unknown StatsGraph variant — return empty to avoid corrupt offset downstream
        return ""
    }

    /**
     * 解析 stats.publicForwards 响应体（constructor 已消费）。
     * flags:int count:int forwards:Vector<PublicForward>
     * next_offset:flags.0?string chats:Vector<Chat> users:Vector<User>
     */
    private func parsePublicForwards(deser: TLDeserializer): Array<PublicForwardItem> {
        var list = ArrayList<PublicForwardItem>()
        try {
            let flags = deser.readInt32()
            let count = deser.readInt32()
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] parsePublicForwards count=${count}")

            // forwards: Vector<PublicForward> — 先读 0x1cb5c415 vector constructor
            let vecCtor = deser.readUInt32()
            let _ = vecCtor
            let vecCount = deser.readInt32()

            var i: Int32 = 0
            while (i < vecCount && i < 20) {
                if (deser.remaining() < 4) { break }
                let fwdCtor = deser.readUInt32()
                if (fwdCtor == 0x01f2bf4a) {
                    // publicForwardMessage: message:Message(boxed)
                    let item = this.parsePublicForwardMessage(deser)
                    list.add(item)
                } else if (fwdCtor == 0xedf3add0) {
                    // publicForwardStory: peer:Peer(boxed) story:StoryItem(boxed) — skip
                    this.skipPeer(deser)
                    this.skipStoryItem(deser)
                } else {
                    Hilog.info(0, "CjTelegram", "[TCStatisticsService] parsePublicForwards: unknown fwd ctor 0x${fwdCtor}, stopping")
                    i = vecCount
                }
                i += 1
            }

            // next_offset:flags.0?string
            if ((flags & 1) != 0 && deser.remaining() >= 1) {
                let _ = deser.readString()
            }
            // chats / users vectors — not needed for display
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] parsePublicForwards error: ${e}")
        }
        let r = list
        return Array<PublicForwardItem>(r.size, { idx: Int64 => r[idx] })
    }

    /**
     * 最小解析 publicForwardMessage 内的 Message(boxed)。
     * Message#76bec211: flags:int id:int from_id?:Peer peer_id:Peer ...
     * 只读 constructor + flags + id + 可选from_id + peer_id，停止解析。
     * peer_id 给出转发目标频道 ID，用于构造 channelTitle 显示文本。
     */
    private func parsePublicForwardMessage(deser: TLDeserializer): PublicForwardItem {
        let item = PublicForwardItem()
        try {
            // Message constructor (boxed)
            let _ = deser.readUInt32()
            // flags: int
            let msgFlags = deser.readInt32()
            // id: int
            item.msgId = deser.readInt32()
            // from_id:flags.8?Peer(boxed) — skip if present
            if ((msgFlags & 256) != 0) {
                this.skipPeer(deser)
            }
            // peer_id: Peer(boxed) — channel this message belongs to
            let peerCtor = deser.readUInt32()
            if (peerCtor == 0xa2a5371e) {
                // peerChannel: channel_id:long
                let channelId = deser.readInt64()
                item.channelTitle = "Channel ${channelId}"
            } else if (peerCtor == 0x59511722) {
                // peerUser: user_id:long
                let userId = deser.readInt64()
                item.channelTitle = "User ${userId}"
            } else if (peerCtor == 0x36c6019a) {
                // peerChat: chat_id:long
                let chatId = deser.readInt64()
                item.channelTitle = "Group ${chatId}"
            } else {
                item.channelTitle = "Channel"
            }
            item.views = 0  // views from message.attributes — full parse out of scope
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TCStatisticsService] parsePublicForwardMessage error: ${e}")
            if (item.channelTitle.size == 0) { item.channelTitle = "Channel" }
        }
        return item
    }

    /**
     * Skip a Peer(boxed) to keep deserialization offset correct.
     * peerUser#59511722 / peerChat#36c6019a / peerChannel#a2a5371e — each has one long field.
     */
    private func skipPeer(deser: TLDeserializer) {
        if (deser.remaining() < 4) { return }
        let _ = deser.readUInt32()   // peer constructor
        if (deser.remaining() >= 8) { let _ = deser.readInt64() }  // id:long
    }

    /**
     * Best-effort skip of StoryItem(boxed).
     * storyItem#af6a4ccf has many optional fields; we read constructor + id + date and stop.
     * The outer try/catch in parsePublicForwards handles any downstream misalignment.
     */
    private func skipStoryItem(deser: TLDeserializer) {
        if (deser.remaining() < 4) { return }
        let _ = deser.readUInt32()   // story constructor
        if (deser.remaining() >= 4) { let _ = deser.readInt32() }  // id:int
        if (deser.remaining() >= 4) { let _ = deser.readInt32() }  // date:int
        // remaining fields ignored — outer catch handles any misalignment
    }
}
