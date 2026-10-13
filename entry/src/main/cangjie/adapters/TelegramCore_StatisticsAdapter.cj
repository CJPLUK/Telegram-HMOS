package ohos_app_cangjie_entry.adapters

import ohos_app_cangjie_entry.services.{
    getTelegramCore_StatisticsService,
    MessageStatsData,
    StoryStatsData,
    BroadcastStatsData,
    MegagroupStatsData,
    StarsTransactionData
}
import ohos_app_cangjie_entry.services.GraphStats

/**
 * TelegramCore Statistics 对外接口适配层 (TCSTAT-IF-1)
 *
 * 对应 iOS TelegramCore/Statistics 对外 API。
 * 为上层业务提供统一的统计数据访问接口，委托 TelegramCore_StatisticsService 实现。
 *
 * 覆盖方法：
 *   - getBroadcastStats     → stats.getBroadcastStats  (0xab42441a)
 *   - getMegagroupStats     → stats.getMegagroupStats  (0xdcdf8607)
 *   - getMessageStats       → stats.getMessageStats    (0xb6e0a3f5)
 *   - getStoryStats         → stats.getStoryStats      (0x374fef40)
 *   - loadAsyncGraph        → stats.loadAsyncGraph     (0x621d5f84)
 *   - getStarsTransactions  → payments.getStarsTransactions (0x69da4557)
 *
 * 使用方式：
 *   let adapter = getTelegramCore_StatisticsAdapter()
 *   let broadcastStats = adapter.getBroadcastStats("channel", channelId)
 *   let msgStats = adapter.getMessageStats("channel", channelId, messageId)
 *   let storyStats = adapter.getStoryStats("channel", channelId, storyId)
 */
private var _adapterInstance: Option<TelegramCore_StatisticsAdapter> = None

public func getTelegramCore_StatisticsAdapter(): TelegramCore_StatisticsAdapter {
    match (_adapterInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCore_StatisticsAdapter()
            _adapterInstance = Some(inst)
            return inst
    }
}

public class TelegramCore_StatisticsAdapter {

    public init() {}

    // ==================== 频道 / 群组统计 ====================

    /**
     * 获取频道广播统计数据
     * TL 调用链：stats.getBroadcastStats (0xab42441a)
     *   → StatisticsService.getBroadcastStats → getMTProtoClient().sendRequest()
     *
     * @param peerType 对话类型（"channel"）
     * @param peerId   频道 ID
     * @return BroadcastStatsData
     */
    public func getBroadcastStats(peerType: String, peerId: Int64): BroadcastStatsData {
        return getTelegramCore_StatisticsService().getBroadcastStats(peerType, peerId)
    }

    /**
     * 获取超级群组统计数据
     * TL 调用链：stats.getMegagroupStats (0xdcdf8607)
     *   → StatisticsService.getMegagroupStats → getMTProtoClient().sendRequest()
     *
     * @param peerType 对话类型（"channel"/"chat"）
     * @param peerId   超级群组频道 ID
     * @return MegagroupStatsData
     */
    public func getMegagroupStats(peerType: String, peerId: Int64): MegagroupStatsData {
        return getTelegramCore_StatisticsService().getMegagroupStats(peerType, peerId)
    }

    // ==================== 消息 / Story 统计 ====================

    /**
     * 获取消息统计数据
     * TL 调用链：stats.getMessageStats (0xb6e0a3f5)
     *   → TelegramCore_StatisticsService.getMessageStats
     *   → getRealMessageService().buildInputPeer(peerType, peerId)
     *   → getMTProtoClient().sendRequest()
     *   → 解析 stats.messageStats#7fe91c14 → MessageStatsData
     *
     * @param peerType 对话类型（"channel"）
     * @param peerId   频道 ID
     * @param msgId    消息 ID
     * @return MessageStatsData（含 viewsGraphToken / reactionsGraphToken）
     */
    public func getMessageStats(peerType: String, peerId: Int64, msgId: Int32): MessageStatsData {
        return getTelegramCore_StatisticsService().getMessageStats(peerType, peerId, msgId)
    }

    /**
     * 获取 Story 统计数据
     * TL 调用链：stats.getStoryStats (0x374fef40)
     *   → TelegramCore_StatisticsService.getStoryStats
     *   → getRealMessageService().buildInputPeer(peerType, peerId)
     *   → getMTProtoClient().sendRequest()
     *   → 解析 stats.storyStats#50cd067c → StoryStatsData
     *
     * @param peerType 对话类型（"channel"）
     * @param peerId   频道 ID
     * @param storyId  Story ID
     * @return StoryStatsData（含 viewsGraphToken / reactionsGraphToken）
     */
    public func getStoryStats(peerType: String, peerId: Int64, storyId: Int32): StoryStatsData {
        return getTelegramCore_StatisticsService().getStoryStats(peerType, peerId, storyId)
    }

    // ==================== 图表 / Stars ====================

    /**
     * 加载异步图表数据
     * TL 调用链：stats.loadAsyncGraph (0x621d5f84)
     *   → StatisticsService.loadAsyncGraph → getMTProtoClient().sendRequest()
     *
     * @param token 图表 token（从统计响应字段获得）
     * @param x     可选 x 坐标值（loadDetailedGraph 时使用）
     * @return GraphStats
     */
    public func loadAsyncGraph(token: String, x!: Int64 = -1): GraphStats {
        return getTelegramCore_StatisticsService().loadAsyncGraph(token, x: x)
    }

    /**
     * 获取 Stars 星币交易列表
     * TL 调用链：payments.getStarsTransactions (0x69da4557)
     *   → StatisticsService.getStarsTransactions → getMTProtoClient().sendRequest()
     *
     * @param peerType 对话类型（"channel"）
     * @param peerId   频道 / 群组 ID
     * @return Array<StarsTransactionData>（最多 20 条）
     */
    public func getStarsTransactions(peerType: String, peerId: Int64): Array<StarsTransactionData> {
        return getTelegramCore_StatisticsService().getStarsTransactions(peerType, peerId)
    }
}
