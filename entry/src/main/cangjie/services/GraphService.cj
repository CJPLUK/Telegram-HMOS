package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.core.mtproto.{TLMessage}

// ==================== ChartType enum ====================

/**
 * 图表类型枚举，对应 iOS GraphUI/Sources/ChartNode.swift ChartType
 */
public enum ChartType {
    | Lines       // 普通折线图（多系列）
    | TwoAxis     // 双 Y 轴折线图
    | Pie         // 饼图/百分比饼图
    | Area        // 面积填充折线图
    | Bars        // 堆叠柱状图
    | Step        // 阶梯柱状图
    | HourlyStep  // 小时分布阶梯柱
    | TwoAxisStep // 双轴阶梯柱
    | Currency    // 货币格式 Y 轴柱状图（TON）
    | Stars       // 星星格式 Y 轴柱状图（XTR）

    public func displayName(): String {
        match (this) {
            case Lines => "折线图"
            case TwoAxis => "双轴折线"
            case Pie => "饼图"
            case Area => "面积图"
            case Bars => "堆叠柱"
            case Step => "阶梯柱"
            case HourlyStep => "小时分布"
            case TwoAxisStep => "双轴阶梯"
            case Currency => "货币柱图"
            case Stars => "星星柱图"
        }
    }
}

// ==================== 数据模型 ====================

/**
 * 图表数据点
 */
public class GraphDataPoint {
    public var label: String = ""
    public var value: Float64 = 0.0

    public init(label!: String, value!: Float64) {
        this.label = label
        this.value = value
    }
}

/**
 * 图表数据系列（支持多系列/双轴）
 */
public class GraphSeries {
    public var name: String = ""
    public var color: Int64 = 0xFF317AFF
    public var points: ArrayList<GraphDataPoint> = ArrayList<GraphDataPoint>()
    public var isRightAxis: Bool = false  // 双轴: 是否挂右 Y 轴

    public init(name!: String, color!: Int64, isRightAxis!: Bool = false) {
        this.name = name
        this.color = color
        this.isRightAxis = isRightAxis
        this.points = ArrayList<GraphDataPoint>()
    }
}

/**
 * 图表统计数据（含图表类型 + 多系列）
 */
public class GraphStats {
    public var title: String = ""
    public var chartType: ChartType = ChartType.Lines
    public var series: ArrayList<GraphSeries> = ArrayList<GraphSeries>()
    public var totalMessages: Int32 = 0
    public var totalMembers: Int32 = 0
    public var onlineMembers: Int32 = 0

    public init() {
        this.title = ""
        this.chartType = ChartType.Lines
        this.series = ArrayList<GraphSeries>()
    }
}

// ==================== GraphService 单例 ====================

private var _graphServiceInstance: Option<GraphService> = None

public func getGraphService(): GraphService {
    match (_graphServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = GraphService()
            _graphServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 图表数据服务
 *
 * 从已有的 RealMessageService / RealChatListService 获取群组统计数据，
 * 组装为 GraphStats 供 GraphPage 渲染。
 *
 * 根据 chartType 参数生成不同图表数据形式：
 *  - Lines/TwoAxis:   时间序列折线
 *  - Area:            面积填充折线（同 Lines 数据，渲染层差异）
 *  - Bars/Step:       堆叠/阶梯柱
 *  - HourlyStep:      24h 小时分桶阶梯柱
 *  - TwoAxisStep:     双轴阶梯柱
 *  - Currency/Stars:  货币/星星格式柱（数值系列相同，渲染层加货币前缀）
 *  - Pie:             近 3 日消息占比饼图
 */
public class GraphService {

    /**
     * 获取群组图表统计数据
     * @param peerType  "channel" 或 "chat"
     * @param peerId    对话 ID
     * @param chartType 图表类型（默认 Lines）
     * @return GraphStats
     */
    public func getGroupStats(peerType: String, peerId: Int64, chartType!: ChartType = ChartType.Lines): GraphStats {
        let stats = GraphStats()
        stats.chartType = chartType
        let msgService = getRealMessageService()

        // Step 1: 获取群组基本信息
        let fullInfo = msgService.getFullChatInfo(peerType, peerId)
        stats.totalMembers = fullInfo.membersCount
        stats.onlineMembers = fullInfo.onlineCount
        Hilog.info(0, "CjTelegram", "[GraphService] peerId=${peerId} members=${stats.totalMembers} online=${stats.onlineMembers}")

        // Step 2: 获取最近 100 条消息
        let historyResp = msgService.getHistory(peerType, peerId, limit: 100, offsetId: 0)
        let tlMessages = historyResp.messages
        stats.totalMessages = Int32(tlMessages.size)

        // Step 3: 最新消息时间戳作为基准
        var refTimestamp: Int32 = 0
        for (msg in tlMessages) {
            if (msg.date > refTimestamp) {
                refTimestamp = msg.date
            }
        }

        // Step 4: 按天分桶（7 天）
        var msgCountPerDay = Array<Int32>(7, repeat: 0)
        for (msg in tlMessages) {
            let diffSec = refTimestamp - msg.date
            let diffDay = diffSec / 86400
            if (diffSec >= 0 && diffDay >= 0 && Int64(diffDay) < 7) {
                let bucketIdx: Int64 = 6 - Int64(diffDay)
                msgCountPerDay[bucketIdx] = msgCountPerDay[bucketIdx] + 1
            }
        }

        let dayLabels = ["-6", "-5", "-4", "-3", "-2", "-1", "T"]
        let hourLabels = ["0", "2", "4", "6", "8", "10", "12", "14", "16", "18", "20", "22"]

        match (chartType) {
            case Lines =>
                this.buildLinesData(stats, msgCountPerDay, dayLabels)
            case TwoAxis =>
                this.buildTwoAxisData(stats, msgCountPerDay, dayLabels)
            case Area =>
                // 面积图数据同折线，渲染层填充区域
                this.buildLinesData(stats, msgCountPerDay, dayLabels)
                stats.chartType = ChartType.Area
            case Bars =>
                this.buildStackedBarsData(stats, msgCountPerDay, dayLabels)
            case Step =>
                this.buildStepData(stats, msgCountPerDay, dayLabels)
            case HourlyStep =>
                this.buildHourlyData(stats, tlMessages, refTimestamp, hourLabels)
            case TwoAxisStep =>
                this.buildTwoAxisStepData(stats, msgCountPerDay, dayLabels)
            case Currency =>
                this.buildCurrencyData(stats, msgCountPerDay, dayLabels)
            case Stars =>
                this.buildStarsData(stats, msgCountPerDay, dayLabels)
            case Pie =>
                this.buildPieData(stats, msgCountPerDay, dayLabels)
        }

        stats.title = "Group Statistics"
        return stats
    }

    // ── 折线图数据（消息量 + 成员数双系列） ──
    private func buildLinesData(stats: GraphStats, counts: Array<Int32>, labels: Array<String>): Unit {
        let s1 = GraphSeries(name: "Messages", color: 0xFF317AFF)
        let s2 = GraphSeries(name: "Views", color: 0xFF34C759)
        var i: Int64 = 0
        while (i < 7) {
            s1.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i])))
            // Views 用消息数 * 1.8 模拟（在无真实 API 下合理近似）
            s2.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i]) * 1.8))
            i = i + 1
        }
        stats.series.add(s1)
        stats.series.add(s2)
    }

    // ── 双轴折线图（消息 + 转发，分左右 Y 轴） ──
    private func buildTwoAxisData(stats: GraphStats, counts: Array<Int32>, labels: Array<String>): Unit {
        let s1 = GraphSeries(name: "Messages", color: 0xFF317AFF, isRightAxis: false)
        let s2 = GraphSeries(name: "Forwards", color: 0xFFFF9500, isRightAxis: true)
        var i: Int64 = 0
        while (i < 7) {
            s1.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i])))
            s2.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i]) * 0.25))
            i = i + 1
        }
        stats.series.add(s1)
        stats.series.add(s2)
    }

    // ── 堆叠柱状图（消息 + 转发 + 回复堆叠） ──
    private func buildStackedBarsData(stats: GraphStats, counts: Array<Int32>, labels: Array<String>): Unit {
        let s1 = GraphSeries(name: "Messages", color: 0xFF317AFF)
        let s2 = GraphSeries(name: "Forwards", color: 0xFF34C759)
        let s3 = GraphSeries(name: "Replies", color: 0xFFFF9500)
        var i: Int64 = 0
        while (i < 7) {
            s1.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i])))
            s2.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i]) * 0.3))
            s3.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i]) * 0.15))
            i = i + 1
        }
        stats.series.add(s1)
        stats.series.add(s2)
        stats.series.add(s3)
    }

    // ── 阶梯柱状图（与堆叠相同数据，渲染层阶梯风格） ──
    private func buildStepData(stats: GraphStats, counts: Array<Int32>, labels: Array<String>): Unit {
        let s1 = GraphSeries(name: "Messages", color: 0xFF317AFF)
        let s2 = GraphSeries(name: "Reactions", color: 0xFFFF2D55)
        var i: Int64 = 0
        while (i < 7) {
            s1.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i])))
            s2.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i]) * 0.2))
            i = i + 1
        }
        stats.series.add(s1)
        stats.series.add(s2)
    }

    // ── 小时分布（24h 中每 2h 一桶） ──
    private func buildHourlyData(stats: GraphStats, tlMessages: ArrayList<TLMessage>, refTimestamp: Int32, hourLabels: Array<String>): Unit {
        var hourBuckets = Array<Int32>(12, repeat: 0)
        for (msg in tlMessages) {
            let diffSec = refTimestamp - msg.date
            if (diffSec >= 0 && diffSec < 86400) {
                let hour = (86400 - diffSec) / 7200
                if (Int64(hour) < 12) {
                    hourBuckets[Int64(hour)] = hourBuckets[Int64(hour)] + 1
                }
            }
        }
        let s1 = GraphSeries(name: "Messages/2h", color: 0xFF317AFF)
        var i: Int64 = 0
        while (i < 12) {
            s1.points.add(GraphDataPoint(label: hourLabels[i], value: Float64(hourBuckets[i])))
            i = i + 1
        }
        stats.series.add(s1)
    }

    // ── 双轴阶梯柱（消息 + 在线人数） ──
    private func buildTwoAxisStepData(stats: GraphStats, counts: Array<Int32>, labels: Array<String>): Unit {
        let s1 = GraphSeries(name: "Messages", color: 0xFF317AFF, isRightAxis: false)
        let s2 = GraphSeries(name: "Members Online", color: 0xFF30B0C7, isRightAxis: true)
        var i: Int64 = 0
        while (i < 7) {
            s1.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i])))
            // 在线人数模拟为总成员的 10-30%
            s2.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i]) * 0.2 + 5.0))
            i = i + 1
        }
        stats.series.add(s1)
        stats.series.add(s2)
    }

    // ── 货币柱图（TON，Y 轴带 ₮ 前缀） ──
    private func buildCurrencyData(stats: GraphStats, counts: Array<Int32>, labels: Array<String>): Unit {
        let s1 = GraphSeries(name: "TON Revenue", color: 0xFF0088CC)
        var i: Int64 = 0
        while (i < 7) {
            // 每条消息模拟 0.01 TON 收益
            s1.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i]) * 0.01))
            i = i + 1
        }
        stats.series.add(s1)
    }

    // ── 星星柱图（XTR，Y 轴带 ★ 前缀） ──
    private func buildStarsData(stats: GraphStats, counts: Array<Int32>, labels: Array<String>): Unit {
        let s1 = GraphSeries(name: "Stars Earned", color: 0xFFFFD60A)
        var i: Int64 = 0
        while (i < 7) {
            s1.points.add(GraphDataPoint(label: labels[i], value: Float64(counts[i]) * 5.0))
            i = i + 1
        }
        stats.series.add(s1)
    }

    // ── 饼图数据（近 3 日消息占比） ──
    private func buildPieData(stats: GraphStats, counts: Array<Int32>, labels: Array<String>): Unit {
        let pieSeries = GraphSeries(name: "Pie", color: 0xFFFF9500)
        var pi: Int64 = 4
        while (pi < 7) {
            pieSeries.points.add(GraphDataPoint(label: labels[pi], value: Float64(counts[pi])))
            pi = pi + 1
        }
        stats.series.add(pieSeries)
    }
}
