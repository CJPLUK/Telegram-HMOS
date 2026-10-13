package ohos_app_cangjie_entry.utils

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog

/**
 * HistoryAnchorKeeper — 头插历史时的可视锚点保持器。
 *
 * 对应 iOS 列表事务里的 stationaryItemRange：向上翻页把更早的消息插到头部时，
 * 旧的可见消息必须停在原来的像素位置，而不是被新插入的一批推下去。
 * iOS 由 PreparedChatHistoryViewTransition 一并处理；ArkUI 没有向 Cangjie 暴露
 * maintainVisibleContentPosition，只能自己抓锚点、自己钉回去。
 *
 * 为什么要独立成类：这套逻辑此前只存在于 ChatRoomPage，会话预览另写了一份朴素分页，
 * 结果就是头插后可见内容整体下移 → onScrollIndex 的 first 又落回小值 → 再次预取，
 * 表现为「往上划不动、往下无限循环」。机制收敛到一处，调用方就不可能再漏。
 *
 * 用法（两个调用点严格配对）：
 *   1. 触发加载前：capture(scroller, firstVisibleIndex, stableId)
 *   2. 新快照落地的**同一轮 UI 更新**里：restore(scroller, indexOfStableId)
 *      —— 不能 spawn/sleep 到下一帧，否则会先看到新的列表头再跳回锚点。
 */
public class HistoryAnchorKeeper {
    private var pending: Bool = false
    private var anchorStableId: Int64 = -1
    private var anchorVisualY: Float64 = 0.0

    public init() {}

    public prop hasPending: Bool {
        get() { return this.pending }
    }

    public prop stableId: Int64 {
        get() { return this.anchorStableId }
    }

    /**
     * 记录「当前第一个可见项」的身份与像素偏移。
     *
     * @param scroller 列表的滚动控制器
     * @param index    第一个可见项的下标
     * @param stableId 该项的稳定身份（Message.identityKey()）——用 id 会在本地消息
     *                 换服务端号时失配
     */
    public func capture(scroller: Scroller, index: Int64, stableId: Int64): Unit {
        if (index < 0 || stableId < 0) {
            this.pending = false
            return
        }
        var visualY: Float64 = 0.0
        try {
            let rect = scroller.getItemRect(Int32(index))
            if (rect.y.isSome()) {
                visualY = rect.y.getOrThrow()
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[HistoryAnchor] capture rect failed idx=${index}: ${e}")
        }
        this.anchorStableId = stableId
        this.anchorVisualY = visualY
        this.pending = true
    }

    /**
     * 把锚点钉回原像素位置。调用方负责先算出锚点在新列表中的下标。
     *
     * @param index 锚点在新快照中的下标；< 0 表示没找到（放弃恢复）
     * @return 是否真的执行了恢复
     */
    public func restore(scroller: Scroller, index: Int64): Bool {
        if (!this.pending) { return false }
        this.pending = false
        if (index < 0) { return false }
        try {
            scroller.scrollToIndex(
                Int32(index),
                smooth: false,
                align: ScrollAlign.Start,
                options: ScrollToIndexOptions(extraOffset: (-this.anchorVisualY).vp)
            )
            Hilog.info(0, "CjTelegram",
                "[HistoryAnchor] restored idx=${index} stableId=${this.anchorStableId} visualY=${this.anchorVisualY}")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[HistoryAnchor] restore failed idx=${index}: ${e}")
            return false
        }
    }

    public func reset(): Unit {
        this.pending = false
        this.anchorStableId = -1
        this.anchorVisualY = 0.0
    }
}
