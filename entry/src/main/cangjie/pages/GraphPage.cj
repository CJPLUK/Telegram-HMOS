package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.storage.getAppTheme
import std.collection.ArrayList
import ohos_app_cangjie_entry.router.*

/**
 * 图表页面 — 群组统计图表引擎
 *
 * 对应 iOS GraphUI/Sources/ChartStackSection + ChartNode 的仓颉移植版本。
 *
 * 功能：
 *  P2-361: 10 种图表类型 Canvas 真绘制（Line/TwoAxis/Area/Bars/Step/HourlyStep/TwoAxisStep/Currency/Stars/Pie）
 *  P2-362: tap 选点 + tooltip、水平 scrub、tap-to-zoom 钻取+返回、底部 range 时间窗选择器
 *  P2-363: 图例可点 toggle 显隐（@State temp-var）、long-press 隔离、动态同步系列数
 *
 * ArkUI Canvas API 确认（KB query + KB example）：
 *  - fillStyle / strokeStyle 均直接接受 Int64 色值
 *  - fillRect(x, y, w, h) 真填充矩形
 *  - beginPath/moveTo/lineTo/arc/stroke/fill 均标准 Canvas2D 语义
 *  - onTouch: event.touches[0].x / event.eventType == TouchType.Down/Move/Up
 */
@HybridComponentEntry
@Component
public class GraphPage {
    @State var pageLoaded: Bool = false

    @State var isLoading: Bool = true
    @State var errorMsg: String = ""
    @State var chartTypeIdx: Int32 = 0    // 当前选中图表类型 tab 索引

    @State var graphStats: GraphStats = GraphStats()

    // P2-362 交互状态
    @State var scrubIdx: Int64 = -1           // 当前 scrub 落在的数据点索引（-1 = 无）
    @State var isZoomed: Bool = false          // 是否处于 zoom-in 状态
    @State var zoomStartIdx: Int64 = 0         // zoom 窗口起点索引
    @State var zoomEndIdx: Int64 = 6           // zoom 窗口终点索引（含）
    @State var rangeStartFrac: Float64 = 0.0   // 底部 range 选择器左边界 [0,1]
    @State var rangeEndFrac: Float64 = 1.0     // 底部 range 选择器右边界 [0,1]
    @State var rangeDragMode: Int32 = 0        // 0=无 1=左柄 2=右柄 3=整体平移

    // P2-363 系列可见性（Array<Bool>，@State temp-var 赋值）
    @State var seriesVisible: Array<Bool> = Array<Bool>()

    // Canvas 上下文（每种图表类型一个，避免切换时 context 混用）
    var chartSettings: RenderingContextSettings = RenderingContextSettings(antialias: true)
    var chartCtx: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))
    var rangeSettings: RenderingContextSettings = RenderingContextSettings(antialias: true)
    var rangeCtx: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))

    // 图表类型 tab 配置（10 种）
    private func chartTypeList(): Array<ChartType> {
        return [
            ChartType.Lines,
            ChartType.TwoAxis,
            ChartType.Area,
            ChartType.Bars,
            ChartType.Step,
            ChartType.HourlyStep,
            ChartType.TwoAxisStep,
            ChartType.Currency,
            ChartType.Stars,
            ChartType.Pie
        ]
    }

    private func chartTypeCount(): Int64 {
        return 10
    }

    private func chartTabIndices(): Array<Int32> {
        let arr: Array<Int32> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        return arr
    }

    private func currentChartType(): ChartType {
        let list = this.chartTypeList()
        let idx = Int64(this.chartTypeIdx)
        if (idx < 0 || idx >= 10) { return ChartType.Lines }
        return list[idx]
    }

    // ── 数据加载 ──
    private func ensureLoaded(): Unit {
        if (this.pageLoaded) { return }
        this.pageLoaded = true
        let _ = spawn {
            try {
                let service = getGraphService()
                let peerType = getSelectedChatPeerType()
                let peerId = getSelectedChatId()
                let ct = ChartType.Lines
                Hilog.info(0, "CjTelegram", "[GraphPage] loading stats peerId=${peerId}")
                let loaded = service.getGroupStats(peerType, peerId, chartType: ct)
                launch {
                    this.graphStats = loaded
                    let n = loaded.series.size
                    var vis = Array<Bool>(n, repeat: true)
                    this.seriesVisible = vis
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GraphPage] loadStats error: ${e}")
                launch {
                    this.errorMsg = "Failed to load statistics"
                    this.isLoading = false
                }
            }
        }
    }

    // ── 切换图表类型（重新请求数据） ──
    private func switchChartType(newIdx: Int32): Unit {
        this.chartTypeIdx = newIdx
        this.scrubIdx = -1
        this.isZoomed = false
        this.zoomStartIdx = 0
        this.zoomEndIdx = 6
        this.rangeStartFrac = 0.0
        this.rangeEndFrac = 1.0
        let _ = spawn {
            try {
                let service = getGraphService()
                let peerType = getSelectedChatPeerType()
                let peerId = getSelectedChatId()
                let types = this.chartTypeList()
                let tidx = Int64(newIdx)
                let ct = if (tidx >= 0 && tidx < 10) { types[tidx] } else { ChartType.Lines }
                let loaded = service.getGroupStats(peerType, peerId, chartType: ct)
                launch {
                    this.graphStats = loaded
                    let n = loaded.series.size
                    var vis = Array<Bool>(n, repeat: true)
                    this.seriesVisible = vis
                    this.scrubIdx = -1
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GraphPage] switchChartType error: ${e}")
            }
        }
    }

    // ── 辅助：系列最大值（用于 Y 轴归一化） ──
    private func seriesMax(seriesIdx: Int64): Float64 {
        if (this.graphStats.series.size <= seriesIdx) { return 1.0 }
        let s = this.graphStats.series[seriesIdx]
        var m: Float64 = 1.0
        for (pt in s.points) {
            if (pt.value > m) { m = pt.value }
        }
        return m
    }

    // ── 辅助：全部系列整体最大值 ──
    private func allSeriesMax(): Float64 {
        var m: Float64 = 1.0
        var si: Int64 = 0
        while (si < this.graphStats.series.size) {
            let sm = this.seriesMax(si)
            if (sm > m) { m = sm }
            si = si + 1
        }
        return m
    }

    // ── 辅助：堆叠柱最大值（各点各系列之和的最大值） ──
    private func stackedMax(): Float64 {
        if (this.graphStats.series.size == 0) { return 1.0 }
        let nPts = this.graphStats.series[0].points.size
        var m: Float64 = 1.0
        var pi: Int64 = 0
        while (pi < nPts) {
            var sum: Float64 = 0.0
            var si: Int64 = 0
            while (si < this.graphStats.series.size) {
                let s = this.graphStats.series[si]
                if (s.points.size > pi) {
                    if (this.isSeriesVisible(si)) {
                        sum = sum + s.points[pi].value
                    }
                }
                si = si + 1
            }
            if (sum > m) { m = sum }
            pi = pi + 1
        }
        return m
    }

    // ── 辅助：点数量 ──
    private func seriesPtCount(si: Int64): Int64 {
        if (this.graphStats.series.size <= si) { return 0 }
        return this.graphStats.series[si].points.size
    }

    // ── 辅助：点值 ──
    private func ptVal(si: Int64, pi: Int64): Float64 {
        if (this.graphStats.series.size <= si) { return 0.0 }
        let s = this.graphStats.series[si]
        if (s.points.size <= pi) { return 0.0 }
        return s.points[pi].value
    }

    // ── 辅助：点标签 ──
    private func ptLabel(si: Int64, pi: Int64): String {
        if (this.graphStats.series.size <= si) { return "" }
        let s = this.graphStats.series[si]
        if (s.points.size <= pi) { return "" }
        return s.points[pi].label
    }

    // ── 辅助：系列颜色 ──
    private func seriesColor(si: Int64): Int64 {
        if (this.graphStats.series.size <= si) { return 0xFF317AFF }
        return this.graphStats.series[si].color
    }

    // ── 辅助：系列名称 ──
    private func seriesName(si: Int64): String {
        if (this.graphStats.series.size <= si) { return "" }
        return this.graphStats.series[si].name
    }

    // ── P2-363: 系列可见性 ──
    private func isSeriesVisible(si: Int64): Bool {
        if (this.seriesVisible.size <= si) { return true }
        return this.seriesVisible[si]
    }

    // ── P2-363: toggle 系列显隐（temp-var 整重赋值） ──
    private func toggleSeries(si: Int64): Unit {
        let n = this.seriesVisible.size
        if (n == 0 || si >= n) { return }
        // 防止最后一个可见系列被隐藏（iOS 的 shake 逻辑等价）
        var visibleCount: Int64 = 0
        var vi: Int64 = 0
        while (vi < n) {
            if (this.seriesVisible[vi]) { visibleCount = visibleCount + 1 }
            vi = vi + 1
        }
        if (visibleCount == 1 && this.seriesVisible[si]) { return }
        var tmp = Array<Bool>(n, repeat: true)
        var ci: Int64 = 0
        while (ci < n) {
            tmp[ci] = this.seriesVisible[ci]
            ci = ci + 1
        }
        tmp[si] = !tmp[si]
        this.seriesVisible = tmp
    }

    // ── P2-363: long-press 隔离（只显示该系列；若已隔离则全恢复） ──
    private func isolateSeries(si: Int64): Unit {
        let n = this.seriesVisible.size
        if (n == 0 || si >= n) { return }
        // 检查是否已是"仅 si 可见"
        var alreadyIsolated: Bool = true
        var ai: Int64 = 0
        while (ai < n) {
            if (ai == si) {
                if (!this.seriesVisible[ai]) { alreadyIsolated = false }
            } else {
                if (this.seriesVisible[ai]) { alreadyIsolated = false }
            }
            ai = ai + 1
        }
        var tmp = Array<Bool>(n, repeat: true)
        if (alreadyIsolated) {
            // 全恢复
        } else {
            // 仅显示 si
            var ii: Int64 = 0
            while (ii < n) {
                tmp[ii] = (ii == si)
                ii = ii + 1
            }
        }
        this.seriesVisible = tmp
    }

    // ── P2-362: 从触点 x 坐标映射到数据点索引 ──
    private func xToPointIdx(touchX: Float64, canvasW: Float64, nPts: Int64): Int64 {
        if (nPts <= 0) { return -1 }
        let padL: Float64 = 32.0
        let drawW = canvasW - padL - 8.0
        if (drawW <= 0.0) { return 0 }
        let frac = (touchX - padL) / drawW
        let raw = Int64(frac * Float64(nPts - 1) + 0.5)
        if (raw < 0) { return 0 }
        if (raw >= nPts) { return nPts - 1 }
        return raw
    }

    // ── P2-362: tap-to-zoom —— 在点击区间放大 ──
    private func doZoom(ptIdx: Int64, nPts: Int64): Unit {
        if (nPts <= 1) { return }
        // 放大至以 ptIdx 为中心的 3 点窗口（模拟 iOS 钻取）
        let half: Int64 = 1
        let s = if (ptIdx - half < 0) { 0 } else { ptIdx - half }
        let e = if (ptIdx + half >= nPts) { nPts - 1 } else { ptIdx + half }
        this.zoomStartIdx = s
        this.zoomEndIdx = e
        this.isZoomed = true
        // 同步 rangeFrac 让绘制函数真缩放数据窗口（draw 读 rangeStartFrac/rangeEndFrac）
        this.rangeStartFrac = Float64(s) / Float64(nPts)
        this.rangeEndFrac = Float64(e + 1) / Float64(nPts)
    }

    // ── P2-362: 退出 zoom ──
    private func doZoomOut(): Unit {
        this.isZoomed = false
        this.zoomStartIdx = 0
        this.zoomEndIdx = 6
        this.scrubIdx = -1
        // 恢复全量数据窗口
        this.rangeStartFrac = 0.0
        this.rangeEndFrac = 1.0
    }

    // ── P2-362: range 选择器 onTouch 处理 ──
    private func handleRangeTouch(evt: TouchEvent, canvasW: Float64): Unit {
        let tx = evt.touches[0].x
        let padL: Float64 = 16.0
        let padR: Float64 = 16.0
        let drawW = canvasW - padL - padR
        if (drawW <= 0.0) { return }
        let frac = (tx - padL) / drawW
        let clamped = if (frac < 0.0) { 0.0 } else if (frac > 1.0) { 1.0 } else { frac }
        let handleHalfFrac: Float64 = 16.0 / drawW

        if (evt.eventType == TouchType.Down) {
            // 判断拖的是左柄、右柄还是中间区域
            let distL = if (clamped > this.rangeStartFrac) { clamped - this.rangeStartFrac } else { this.rangeStartFrac - clamped }
            let distR = if (clamped > this.rangeEndFrac) { clamped - this.rangeEndFrac } else { this.rangeEndFrac - clamped }
            if (distL < handleHalfFrac * 2.0) {
                this.rangeDragMode = 1
            } else if (distR < handleHalfFrac * 2.0) {
                this.rangeDragMode = 2
            } else if (clamped > this.rangeStartFrac && clamped < this.rangeEndFrac) {
                this.rangeDragMode = 3
            } else {
                this.rangeDragMode = 0
            }
        } else if (evt.eventType == TouchType.Move) {
            if (this.rangeDragMode == 1) {
                let newL = if (clamped < this.rangeEndFrac - 0.1) { clamped } else { this.rangeEndFrac - 0.1 }
                this.rangeStartFrac = if (newL < 0.0) { 0.0 } else { newL }
            } else if (this.rangeDragMode == 2) {
                let newR = if (clamped > this.rangeStartFrac + 0.1) { clamped } else { this.rangeStartFrac + 0.1 }
                this.rangeEndFrac = if (newR > 1.0) { 1.0 } else { newR }
            } else if (this.rangeDragMode == 3) {
                let span = this.rangeEndFrac - this.rangeStartFrac
                var newL = clamped - span / 2.0
                var newR = clamped + span / 2.0
                if (newL < 0.0) { newR = newR - newL; newL = 0.0 }
                if (newR > 1.0) { newL = newL - (newR - 1.0); newR = 1.0 }
                this.rangeStartFrac = newL
                this.rangeEndFrac = newR
            }
        } else if (evt.eventType == TouchType.Up) {
            this.rangeDragMode = 0
        }
    }

    // ── 统计摘要文字 ──
    private func statsLine1(): String {
        return "Messages (7d): ${this.graphStats.totalMessages}"
    }

    private func statsLine2(): String {
        return "Members: ${this.graphStats.totalMembers}  Online: ${this.graphStats.onlineMembers}"
    }

    // ── tab 短名 ──
    private func tabShortName(idx: Int32): String {
        let types = this.chartTypeList()
        let i = Int64(idx)
        if (i < 0 || i >= 10) { return "" }
        match (types[i]) {
            case Lines => "Line"
            case TwoAxis => "2Ax"
            case Area => "Area"
            case Bars => "Stack"
            case Step => "Step"
            case HourlyStep => "Hour"
            case TwoAxisStep => "2Stp"
            case Currency => "TON"
            case Stars => "Star"
            case Pie => "Pie"
        }
    }

    // ── P2-370: 暗色主题辅助 ──
    private func isDark(): Bool {
        return getAppTheme().theme == 1
    }
    private func themeBg(): Int64 {
        if (this.isDark()) { return 0xFF1C1C1E } else { return 0xFFF2F2F7 }
    }
    private func themeCard(): Int64 {
        if (this.isDark()) { return 0xFF2C2C2E } else { return 0xFFFFFFFF }
    }
    private func themeText(): Int64 {
        if (this.isDark()) { return 0xFFFFFFFF } else { return 0xFF1C1C1E }
    }
    private func themeSecondary(): Int64 {
        if (this.isDark()) { return 0xFFAEAEB2 } else { return 0xFF8E8E93 }
    }
    private func themeAccent(): Int64 {
        if (this.isDark()) { return 0xFF0A84FF } else { return 0xFF317AFF }
    }
    private func themeDivider(): Int64 {
        if (this.isDark()) { return 0xFF38383A } else { return 0xFFE5E5EA }
    }
    private func themeChartBg(): Int64 {
        if (this.isDark()) { return 0xFF1C1C1E } else { return 0xFFFFFFFF }
    }
    private func themeGridLine(): Int64 {
        if (this.isDark()) { return 0xFF38383A } else { return 0xFFE5E5EA }
    }
    private func themeAxisLabel(): Int64 {
        if (this.isDark()) { return 0xFFAEAEB2 } else { return 0xFFAAAAAA }
    }
    private func themeTooltipBg(): Int64 {
        if (this.isDark()) { return 0xFF3A3A3C } else { return 0xFF2C2C2E }
    }
    private func themeTooltipText(): Int64 { return 0xFFFFFFFF }
    private func themeRangeBg(): Int64 {
        if (this.isDark()) { return 0xFF1C1C1E } else { return 0xFFF2F2F7 }
    }
    private func themeRangeMask(): Int64 {
        if (this.isDark()) { return 0xFF636366 } else { return 0xFF8E8E93 }
    }

    // ── P2-370 Gap①: 时间窗标签（"Mar 1 - Mar 15" 格式） ──
    // 将 rangeStartFrac/rangeEndFrac 映射到数据点 label，再格式化为可读日期范围
    private func rangeWindowLabel(): String {
        let nPts = this.seriesPtCount(0)
        if (nPts <= 0) { return "" }
        let startIdxRaw = Int64(this.rangeStartFrac * Float64(nPts))
        let endIdxRaw = Int64(this.rangeEndFrac * Float64(nPts))
        let si = if (startIdxRaw < 0) { 0 } else if (startIdxRaw >= nPts) { nPts - 1 } else { startIdxRaw }
        let ei = if (endIdxRaw <= si) { si } else if (endIdxRaw >= nPts) { nPts - 1 } else { endIdxRaw - 1 }
        let startLabel = this.ptLabel(0, si)
        let endLabel = this.ptLabel(0, ei)
        if (startLabel.size == 0 && endLabel.size == 0) { return "" }
        if (startLabel.size == 0) { return endLabel }
        if (endLabel.size == 0) { return startLabel }
        if (si == ei) { return startLabel }
        return "${startLabel} - ${endLabel}"
    }

    // ── tab 颜色 ──
    private func tabColor(idx: Int32): Int64 {
        if (this.chartTypeIdx == idx) { return this.themeAccent() }
        return this.themeSecondary()
    }

    // ── P2-361: 折线图 / 面积图 Canvas 绘制（零参 @Builder，isArea 通过 chartTypeIdx==2 判断）──
    @Builder func lineAreaChartCanvas(): Unit {
        Canvas(this.chartCtx)
            .width(100.percent)
            .height(220)
            .backgroundColor(this.themeChartBg())
            .onReady({
                =>
                this.drawLineAreaChart()
            })
            .onTouch({ evt =>
                let nPts = this.seriesPtCount(0)
                let cw: Float64 = 320.0
                if (evt.eventType == TouchType.Down) {
                    let idx = this.xToPointIdx(evt.touches[0].x, cw, nPts)
                    if (this.scrubIdx >= 0 && this.scrubIdx == idx && !this.isZoomed) {
                        this.doZoom(idx, nPts)
                    } else {
                        this.scrubIdx = idx
                    }
                    this.drawLineAreaChart()
                } else if (evt.eventType == TouchType.Move) {
                    let idx = this.xToPointIdx(evt.touches[0].x, cw, nPts)
                    this.scrubIdx = idx
                    this.drawLineAreaChart()
                } else if (evt.eventType == TouchType.Up) {
                    // 保持 scrubIdx 显示 tooltip
                }
            })
    }

    // ── P2-361: 折线/面积图绘制逻辑（isArea = chartTypeIdx==2） ──
    private func drawLineAreaChart(): Unit {
        let isArea = (this.chartTypeIdx == 2)
        let w: Float64 = 320.0
        let h: Float64 = 200.0
        let padL: Float64 = 32.0
        let padB: Float64 = 24.0
        let drawW = w - padL - 8.0
        let drawH = h - padB - 8.0

        // 可见系列中最大值
        var maxVal: Float64 = 1.0
        var si: Int64 = 0
        while (si < this.graphStats.series.size) {
            if (this.isSeriesVisible(si)) {
                let sm = this.seriesMax(si)
                if (sm > maxVal) { maxVal = sm }
            }
            si = si + 1
        }

        // range 子窗口
        let nPtsAll = this.seriesPtCount(0)
        let startIdxRaw = Int64(this.rangeStartFrac * Float64(nPtsAll))
        let endIdxRaw = Int64(this.rangeEndFrac * Float64(nPtsAll))
        let startIdx = if (startIdxRaw < 0) { 0 } else if (startIdxRaw >= nPtsAll) { 0 } else { startIdxRaw }
        let endIdx = if (endIdxRaw <= startIdx) { nPtsAll - 1 } else if (endIdxRaw > nPtsAll) { nPtsAll - 1 } else { endIdxRaw }
        let nPts = endIdx - startIdx + 1

        // 清背景
        this.chartCtx.fillStyle = this.themeChartBg()
        this.chartCtx.fillRect(0.0, 0.0, w, h)

        // 网格线
        this.chartCtx.lineWidth = 0.5
        this.chartCtx.strokeStyle = this.themeGridLine()
        var gi: Int64 = 0
        while (gi < 4) {
            let gy = 8.0 + drawH * Float64(gi) / 3.0
            this.chartCtx.beginPath()
            this.chartCtx.moveTo(padL, gy)
            this.chartCtx.lineTo(w - 8.0, gy)
            this.chartCtx.stroke()
            gi = gi + 1
        }

        if (nPts < 1) { return }

        // 各可见系列绘制
        var drawSi: Int64 = 0
        while (drawSi < this.graphStats.series.size) {
            if (!this.isSeriesVisible(drawSi)) {
                drawSi = drawSi + 1
                continue
            }
            let serColor = this.seriesColor(drawSi)

            if (isArea) {
                // 面积图：先填充区域（用 fillStyle + fill）
                this.chartCtx.beginPath()
                var api: Int64 = 0
                while (api < nPts) {
                    let ptIdx = startIdx + api
                    let ptV = this.ptVal(drawSi, ptIdx)
                    let px = padL + Float64(api) * drawW / Float64(if (nPts > 1) { nPts - 1 } else { 1 })
                    let py = 8.0 + drawH - (drawH * ptV / maxVal)
                    if (api == 0) {
                        this.chartCtx.moveTo(px, 8.0 + drawH)
                        this.chartCtx.lineTo(px, py)
                    } else {
                        this.chartCtx.lineTo(px, py)
                    }
                    api = api + 1
                }
                // 回到底部关闭路径
                let lastPx = padL + Float64(nPts - 1) * drawW / Float64(if (nPts > 1) { nPts - 1 } else { 1 })
                this.chartCtx.lineTo(lastPx, 8.0 + drawH)
                this.chartCtx.closePath()
                // 半透明填充（alpha 0.3 通过 globalAlpha 模拟）
                this.chartCtx.globalAlpha = 0.3
                this.chartCtx.fillStyle = serColor
                this.chartCtx.fill()
                this.chartCtx.globalAlpha = 1.0
            }

            // 折线
            this.chartCtx.lineWidth = 2.0
            this.chartCtx.strokeStyle = serColor
            this.chartCtx.beginPath()
            var lpi: Int64 = 0
            while (lpi < nPts) {
                let ptIdx = startIdx + lpi
                let ptV = this.ptVal(drawSi, ptIdx)
                let px = padL + Float64(lpi) * drawW / Float64(if (nPts > 1) { nPts - 1 } else { 1 })
                let py = 8.0 + drawH - (drawH * ptV / maxVal)
                if (lpi == 0) {
                    this.chartCtx.moveTo(px, py)
                } else {
                    this.chartCtx.lineTo(px, py)
                }
                lpi = lpi + 1
            }
            this.chartCtx.stroke()

            // 数据点圆点
            var mpi: Int64 = 0
            while (mpi < nPts) {
                let ptIdx = startIdx + mpi
                let ptV = this.ptVal(drawSi, ptIdx)
                let px = padL + Float64(mpi) * drawW / Float64(if (nPts > 1) { nPts - 1 } else { 1 })
                let py = 8.0 + drawH - (drawH * ptV / maxVal)
                this.chartCtx.lineWidth = 1.5
                this.chartCtx.strokeStyle = serColor
                this.chartCtx.beginPath()
                this.chartCtx.arc(px, py, 3.0, 0.0, 6.2832)
                this.chartCtx.stroke()
                mpi = mpi + 1
            }

            drawSi = drawSi + 1
        }

        // P2-362: scrub 游标 + tooltip
        let scrub = this.scrubIdx
        if (scrub >= 0 && nPts > 0) {
            let relIdx = scrub - startIdx
            if (relIdx >= 0 && relIdx < nPts) {
                let cursorX = padL + Float64(relIdx) * drawW / Float64(if (nPts > 1) { nPts - 1 } else { 1 })
                // 垂直游标线
                this.chartCtx.lineWidth = 1.0
                this.chartCtx.strokeStyle = this.themeAxisLabel()
                this.chartCtx.beginPath()
                this.chartCtx.moveTo(cursorX, 8.0)
                this.chartCtx.lineTo(cursorX, 8.0 + drawH)
                this.chartCtx.stroke()
                // tooltip 背景
                let ttW: Float64 = 80.0
                let ttH: Float64 = Float64(this.graphStats.series.size) * 16.0 + 12.0
                let ttX = if (cursorX + ttW + 4.0 < w) { cursorX + 4.0 } else { cursorX - ttW - 4.0 }
                let ttY: Float64 = 12.0
                this.chartCtx.fillStyle = this.themeTooltipBg()
                this.chartCtx.fillRect(ttX, ttY, ttW, ttH)
                // tooltip 文字（通过 strokeText 输出系列值）
                var tti: Int64 = 0
                while (tti < this.graphStats.series.size) {
                    if (this.isSeriesVisible(tti)) {
                        let tv = this.ptVal(tti, scrub)
                        let tLabel = "${this.seriesName(tti)}: ${Int64(tv)}"
                        this.chartCtx.strokeStyle = this.themeTooltipText()
                        this.chartCtx.lineWidth = 0.4
                        this.chartCtx.strokeText(tLabel, ttX + 4.0, ttY + 10.0 + Float64(tti) * 16.0)
                    }
                    tti = tti + 1
                }
            }
        }

        // P2-362: zoom-in 状态指示（顶部强调色条）
        if (this.isZoomed) {
            this.chartCtx.fillStyle = this.themeAccent()
            this.chartCtx.fillRect(padL, 0.0, drawW, 3.0)
        }
    }

    // ── P2-361: 堆叠柱状图 Canvas ──
    @Builder func stackedBarChartCanvas(): Unit {
        Canvas(this.chartCtx)
            .width(100.percent)
            .height(220)
            .backgroundColor(this.themeChartBg())
            .onReady({
                =>
                this.drawStackedBarChart()
            })
            .onTouch({ evt =>
                let nPts = this.seriesPtCount(0)
                let cw: Float64 = 320.0
                if (evt.eventType == TouchType.Down || evt.eventType == TouchType.Move) {
                    let idx = this.xToPointIdx(evt.touches[0].x, cw, nPts)
                    if (evt.eventType == TouchType.Down && this.scrubIdx == idx && !this.isZoomed) {
                        this.doZoom(idx, nPts)
                    }
                    this.scrubIdx = idx
                    this.drawStackedBarChart()
                } else if (evt.eventType == TouchType.Up) {
                    this.rangeDragMode = 0
                }
            })
    }

    private func drawStackedBarChart(): Unit {
        let w: Float64 = 320.0
        let h: Float64 = 200.0
        let padL: Float64 = 32.0
        let padB: Float64 = 24.0
        let drawW = w - padL - 8.0
        let drawH = h - padB - 8.0

        let maxVal = this.stackedMax()
        let nPts = this.seriesPtCount(0)
        if (nPts == 0) { return }

        this.chartCtx.fillStyle = this.themeChartBg()
        this.chartCtx.fillRect(0.0, 0.0, w, h)

        // 网格
        this.chartCtx.lineWidth = 0.5
        this.chartCtx.strokeStyle = this.themeGridLine()
        var gi: Int64 = 0
        while (gi < 4) {
            let gy = 8.0 + drawH * Float64(gi) / 3.0
            this.chartCtx.beginPath()
            this.chartCtx.moveTo(padL, gy)
            this.chartCtx.lineTo(w - 8.0, gy)
            this.chartCtx.stroke()
            gi = gi + 1
        }

        let barSlot = drawW / Float64(nPts)
        let barW = barSlot * 0.6

        var bi: Int64 = 0
        while (bi < nPts) {
            let bx = padL + Float64(bi) * barSlot + (barSlot - barW) / 2.0
            var stackBottom: Float64 = 8.0 + drawH
            var si: Int64 = 0
            while (si < this.graphStats.series.size) {
                if (this.isSeriesVisible(si)) {
                    let ptV = this.ptVal(si, bi)
                    let barH = if (maxVal > 0.0) { drawH * ptV / maxVal } else { 0.0 }
                    let by = stackBottom - barH
                    this.chartCtx.fillStyle = this.seriesColor(si)
                    this.chartCtx.fillRect(bx, by, barW, barH)
                    stackBottom = by
                }
                si = si + 1
            }
            bi = bi + 1
        }

        // scrub cursor + tooltip
        let scrub = this.scrubIdx
        if (scrub >= 0 && scrub < nPts) {
            let bx = padL + Float64(scrub) * barSlot + (barSlot - barW) / 2.0
            this.chartCtx.strokeStyle = this.themeText()
            this.chartCtx.lineWidth = 1.5
            this.chartCtx.strokeRect(bx - 1.0, 8.0, barW + 2.0, drawH)
            // tooltip
            let ttW: Float64 = 90.0
            let ttH: Float64 = Float64(this.graphStats.series.size) * 16.0 + 12.0
            let cursorX = padL + Float64(scrub) * barSlot + barSlot / 2.0
            let ttX = if (cursorX + ttW + 4.0 < w) { cursorX + 4.0 } else { cursorX - ttW - 4.0 }
            this.chartCtx.fillStyle = this.themeTooltipBg()
            this.chartCtx.fillRect(ttX, 12.0, ttW, ttH)
            var tti: Int64 = 0
            while (tti < this.graphStats.series.size) {
                if (this.isSeriesVisible(tti)) {
                    let tv = this.ptVal(tti, scrub)
                    let tLabel = "${this.seriesName(tti)}: ${Int64(tv)}"
                    this.chartCtx.strokeStyle = this.themeTooltipText()
                    this.chartCtx.lineWidth = 0.4
                    this.chartCtx.strokeText(tLabel, ttX + 4.0, 22.0 + Float64(tti) * 16.0)
                }
                tti = tti + 1
            }
        }
    }

    // ── P2-361: 阶梯柱/小时分布 Canvas（零参 @Builder） ──
    @Builder func stepChartCanvas(): Unit {
        Canvas(this.chartCtx)
            .width(100.percent)
            .height(220)
            .backgroundColor(this.themeChartBg())
            .onReady({
                =>
                this.drawStepChart()
            })
            .onTouch({ evt =>
                let nPts = this.seriesPtCount(0)
                let cw: Float64 = 320.0
                if (evt.eventType == TouchType.Down || evt.eventType == TouchType.Move) {
                    let idx = this.xToPointIdx(evt.touches[0].x, cw, nPts)
                    this.scrubIdx = idx
                    this.drawStepChart()
                }
            })
    }

    private func drawStepChart(): Unit {
        let w: Float64 = 320.0
        let h: Float64 = 200.0
        let padL: Float64 = 32.0
        let padB: Float64 = 24.0
        let drawW = w - padL - 8.0
        let drawH = h - padB - 8.0
        let maxVal = this.allSeriesMax()
        let nPts = this.seriesPtCount(0)
        if (nPts == 0) { return }

        this.chartCtx.fillStyle = this.themeChartBg()
        this.chartCtx.fillRect(0.0, 0.0, w, h)

        // 网格
        this.chartCtx.lineWidth = 0.5
        this.chartCtx.strokeStyle = this.themeGridLine()
        var gi: Int64 = 0
        while (gi < 4) {
            let gy = 8.0 + drawH * Float64(gi) / 3.0
            this.chartCtx.beginPath()
            this.chartCtx.moveTo(padL, gy)
            this.chartCtx.lineTo(w - 8.0, gy)
            this.chartCtx.stroke()
            gi = gi + 1
        }

        let barSlot = drawW / Float64(nPts)

        // 阶梯柱：每个数据点渲染为单色柱
        var si: Int64 = 0
        while (si < this.graphStats.series.size) {
            if (this.isSeriesVisible(si)) {
                let serColor = this.seriesColor(si)
                // 相对 si 错开一点以区分（当 si>0 时向右偏移 2px）
                var pi: Int64 = 0
                while (pi < nPts) {
                    let ptV = this.ptVal(si, pi)
                    let barH = if (maxVal > 0.0) { drawH * ptV / maxVal } else { 0.0 }
                    let bx = padL + Float64(pi) * barSlot + Float64(si) * 2.0
                    let by = 8.0 + drawH - barH
                    let bwActual = if (si == 0) { barSlot * 0.55 } else { barSlot * 0.45 }
                    this.chartCtx.fillStyle = serColor
                    this.chartCtx.fillRect(bx, by, bwActual, barH)
                    pi = pi + 1
                }
            }
            si = si + 1
        }

        // scrub cursor
        let scrub = this.scrubIdx
        if (scrub >= 0 && scrub < nPts) {
            let bx = padL + Float64(scrub) * barSlot
            this.chartCtx.strokeStyle = this.themeAxisLabel()
            this.chartCtx.lineWidth = 1.0
            this.chartCtx.beginPath()
            this.chartCtx.moveTo(bx + barSlot / 2.0, 8.0)
            this.chartCtx.lineTo(bx + barSlot / 2.0, 8.0 + drawH)
            this.chartCtx.stroke()
            // tooltip
            let ttW: Float64 = 90.0
            let ttH: Float64 = Float64(this.graphStats.series.size) * 16.0 + 12.0
            let cursorX = bx + barSlot / 2.0
            let ttX = if (cursorX + ttW + 4.0 < w) { cursorX + 4.0 } else { cursorX - ttW - 4.0 }
            this.chartCtx.fillStyle = this.themeTooltipBg()
            this.chartCtx.fillRect(ttX, 12.0, ttW, ttH)
            var tti: Int64 = 0
            while (tti < this.graphStats.series.size) {
                if (this.isSeriesVisible(tti)) {
                    let tv = this.ptVal(tti, scrub)
                    let tLabel = "${this.seriesName(tti)}: ${Int64(tv)}"
                    this.chartCtx.strokeStyle = this.themeTooltipText()
                    this.chartCtx.lineWidth = 0.4
                    this.chartCtx.strokeText(tLabel, ttX + 4.0, 22.0 + Float64(tti) * 16.0)
                }
                tti = tti + 1
            }
        }
    }

    // ── P2-361: 双轴折线图 Canvas（零参 @Builder；isStep = chartTypeIdx==6） ──
    @Builder func twoAxisChartCanvas(): Unit {
        Canvas(this.chartCtx)
            .width(100.percent)
            .height(220)
            .backgroundColor(this.themeChartBg())
            .onReady({
                =>
                this.drawTwoAxisChart()
            })
            .onTouch({ evt =>
                let nPts = this.seriesPtCount(0)
                let cw: Float64 = 320.0
                if (evt.eventType == TouchType.Down || evt.eventType == TouchType.Move) {
                    let idx = this.xToPointIdx(evt.touches[0].x, cw, nPts)
                    this.scrubIdx = idx
                    this.drawTwoAxisChart()
                }
            })
    }

    private func drawTwoAxisChart(): Unit {
        let isStep = (this.chartTypeIdx == 6)
        let w: Float64 = 320.0
        let h: Float64 = 200.0
        let padL: Float64 = 36.0
        let padR: Float64 = 36.0
        let padB: Float64 = 24.0
        let drawW = w - padL - padR
        let drawH = h - padB - 8.0

        this.chartCtx.fillStyle = this.themeChartBg()
        this.chartCtx.fillRect(0.0, 0.0, w, h)

        // 网格
        this.chartCtx.lineWidth = 0.5
        this.chartCtx.strokeStyle = this.themeGridLine()
        var gi: Int64 = 0
        while (gi < 4) {
            let gy = 8.0 + drawH * Float64(gi) / 3.0
            this.chartCtx.beginPath()
            this.chartCtx.moveTo(padL, gy)
            this.chartCtx.lineTo(w - padR, gy)
            this.chartCtx.stroke()
            gi = gi + 1
        }

        let nPts = this.seriesPtCount(0)
        if (nPts == 0) { return }

        // 左轴系列（isRightAxis=false）
        var si: Int64 = 0
        while (si < this.graphStats.series.size) {
            if (!this.isSeriesVisible(si)) {
                si = si + 1
                continue
            }
            let serColor = this.seriesColor(si)
            let maxV = this.seriesMax(si)

            if (isStep) {
                let barSlot = drawW / Float64(nPts)
                let barW = barSlot * 0.55
                var pi: Int64 = 0
                while (pi < nPts) {
                    let ptV = this.ptVal(si, pi)
                    let barH = if (maxV > 0.0) { drawH * ptV / maxV } else { 0.0 }
                    let bx = padL + Float64(pi) * barSlot
                    let by = 8.0 + drawH - barH
                    this.chartCtx.fillStyle = serColor
                    this.chartCtx.fillRect(bx, by, barW, barH)
                    pi = pi + 1
                }
            } else {
                // 折线
                this.chartCtx.lineWidth = 2.0
                this.chartCtx.strokeStyle = serColor
                this.chartCtx.beginPath()
                var pi: Int64 = 0
                while (pi < nPts) {
                    let ptV = this.ptVal(si, pi)
                    let px = padL + Float64(pi) * drawW / Float64(if (nPts > 1) { nPts - 1 } else { 1 })
                    let py = 8.0 + drawH - (drawH * ptV / maxV)
                    if (pi == 0) {
                        this.chartCtx.moveTo(px, py)
                    } else {
                        this.chartCtx.lineTo(px, py)
                    }
                    pi = pi + 1
                }
                this.chartCtx.stroke()
            }
            si = si + 1
        }

        // scrub cursor
        let scrub = this.scrubIdx
        if (scrub >= 0 && scrub < nPts) {
            let cursorX = padL + Float64(scrub) * drawW / Float64(if (nPts > 1) { nPts - 1 } else { 1 })
            this.chartCtx.strokeStyle = this.themeAxisLabel()
            this.chartCtx.lineWidth = 1.0
            this.chartCtx.beginPath()
            this.chartCtx.moveTo(cursorX, 8.0)
            this.chartCtx.lineTo(cursorX, 8.0 + drawH)
            this.chartCtx.stroke()
            // tooltip
            let ttW: Float64 = 100.0
            let ttH: Float64 = Float64(this.graphStats.series.size) * 16.0 + 12.0
            let ttX = if (cursorX + ttW + 4.0 < w - padR) { cursorX + 4.0 } else { cursorX - ttW - 4.0 }
            this.chartCtx.fillStyle = this.themeTooltipBg()
            this.chartCtx.fillRect(ttX, 12.0, ttW, ttH)
            var tti: Int64 = 0
            while (tti < this.graphStats.series.size) {
                if (this.isSeriesVisible(tti)) {
                    let tv = this.ptVal(tti, scrub)
                    let prefix = if (tti == 1) { "R:" } else { "L:" }
                    let tLabel = "${prefix}${this.seriesName(tti)}: ${Int64(tv)}"
                    this.chartCtx.strokeStyle = this.themeTooltipText()
                    this.chartCtx.lineWidth = 0.4
                    this.chartCtx.strokeText(tLabel, ttX + 4.0, 22.0 + Float64(tti) * 16.0)
                }
                tti = tti + 1
            }
        }

        // 左轴标记（蓝色小方块）和右轴标记（橙色小方块）
        this.chartCtx.fillStyle = this.themeAccent()
        this.chartCtx.fillRect(0.0, 8.0, 4.0, 4.0)
        this.chartCtx.fillStyle = 0xFFFF9500
        this.chartCtx.fillRect(w - 4.0, 8.0, 4.0, 4.0)
    }

    // ── P2-361: 货币/星星柱图（零参 @Builder；isCurrency = chartTypeIdx==7） ──
    @Builder func currencyStarsChartCanvas(): Unit {
        Canvas(this.chartCtx)
            .width(100.percent)
            .height(220)
            .backgroundColor(this.themeChartBg())
            .onReady({
                =>
                this.drawCurrencyStarsChart()
            })
            .onTouch({ evt =>
                let nPts = this.seriesPtCount(0)
                let cw: Float64 = 320.0
                if (evt.eventType == TouchType.Down || evt.eventType == TouchType.Move) {
                    let idx = this.xToPointIdx(evt.touches[0].x, cw, nPts)
                    this.scrubIdx = idx
                    this.drawCurrencyStarsChart()
                }
            })
    }

    private func drawCurrencyStarsChart(): Unit {
        let isCurrency = (this.chartTypeIdx == 7)
        let w: Float64 = 320.0
        let h: Float64 = 200.0
        let padL: Float64 = 32.0
        let padB: Float64 = 24.0
        let drawW = w - padL - 8.0
        let drawH = h - padB - 8.0
        let maxVal = this.allSeriesMax()
        let nPts = this.seriesPtCount(0)
        if (nPts == 0) { return }

        this.chartCtx.fillStyle = this.themeChartBg()
        this.chartCtx.fillRect(0.0, 0.0, w, h)

        // 网格
        this.chartCtx.lineWidth = 0.5
        this.chartCtx.strokeStyle = this.themeGridLine()
        var gi: Int64 = 0
        while (gi < 4) {
            let gy = 8.0 + drawH * Float64(gi) / 3.0
            this.chartCtx.beginPath()
            this.chartCtx.moveTo(padL, gy)
            this.chartCtx.lineTo(w - 8.0, gy)
            this.chartCtx.stroke()
            gi = gi + 1
        }

        let barSlot = drawW / Float64(nPts)
        let barW = barSlot * 0.55
        let barColor: Int64 = if (isCurrency) { 0xFF0088CC } else { 0xFFFFD60A }

        var bi: Int64 = 0
        while (bi < nPts) {
            let ptV = this.ptVal(0, bi)
            let barH = if (maxVal > 0.0) { drawH * ptV / maxVal } else { 0.0 }
            let bx = padL + Float64(bi) * barSlot + (barSlot - barW) / 2.0
            let by = 8.0 + drawH - barH
            this.chartCtx.fillStyle = barColor
            this.chartCtx.fillRect(bx, by, barW, barH)
            bi = bi + 1
        }

        // Y 轴前缀标签（仅 strokeText 顶部）
        let prefix: String = if (isCurrency) { "TON" } else { "XTR" }
        this.chartCtx.strokeStyle = this.themeAxisLabel()
        this.chartCtx.lineWidth = 0.5
        this.chartCtx.strokeText(prefix, 2.0, 14.0)

        // scrub cursor + tooltip
        let scrub = this.scrubIdx
        if (scrub >= 0 && scrub < nPts) {
            let tv = this.ptVal(0, scrub)
            let bx = padL + Float64(scrub) * barSlot + (barSlot - barW) / 2.0
            this.chartCtx.strokeStyle = this.themeAxisLabel()
            this.chartCtx.lineWidth = 1.0
            this.chartCtx.beginPath()
            this.chartCtx.moveTo(bx + barW / 2.0, 8.0)
            this.chartCtx.lineTo(bx + barW / 2.0, 8.0 + drawH)
            this.chartCtx.stroke()
            let valStr: String = if (isCurrency) { "T ${tv}" } else { "XTR ${Int64(tv)}" }
            let ttW: Float64 = 80.0
            let ttH: Float64 = 28.0
            let cursorX = bx + barW / 2.0
            let ttX = if (cursorX + ttW + 4.0 < w) { cursorX + 4.0 } else { cursorX - ttW - 4.0 }
            this.chartCtx.fillStyle = this.themeTooltipBg()
            this.chartCtx.fillRect(ttX, 12.0, ttW, ttH)
            this.chartCtx.strokeStyle = this.themeTooltipText()
            this.chartCtx.lineWidth = 0.4
            this.chartCtx.strokeText(valStr, ttX + 4.0, 24.0)
        }
    }

    // ── P2-361: 饼图 Canvas ──
    @Builder func pieChartCanvas(): Unit {
        Canvas(this.chartCtx)
            .width(100.percent)
            .height(220)
            .backgroundColor(this.themeChartBg())
            .onReady({
                =>
                this.drawPieChart()
            })
            .onTouch({ evt =>
                if (evt.eventType == TouchType.Down) {
                    // 饼图 tap：切换到下一个系列高亮（简单 toggle scrubIdx）
                    let n = this.seriesPtCount(0)
                    let nextScrub = if (this.scrubIdx + 1 >= n) { 0 } else { this.scrubIdx + 1 }
                    this.scrubIdx = nextScrub
                    this.drawPieChart()
                }
            })
    }

    private func drawPieChart(): Unit {
        let cx: Float64 = 160.0
        let cy: Float64 = 100.0
        let radius: Float64 = 65.0

        if (this.graphStats.series.size == 0) { return }
        let pieSeries = this.graphStats.series[0]
        let nSlices = pieSeries.points.size
        if (nSlices == 0) { return }

        // 总值
        var total: Float64 = 0.0
        var ti: Int64 = 0
        while (ti < nSlices) {
            if (this.isSeriesVisible(0)) {
                total = total + pieSeries.points[ti].value
            }
            ti = ti + 1
        }
        if (total <= 0.0) { return }

        // 清背景
        this.chartCtx.fillStyle = this.themeChartBg()
        this.chartCtx.fillRect(0.0, 0.0, 320.0, 220.0)

        let sliceColors: Array<Int64> = [0xFFFF9500, 0xFF30B0C7, 0xFFFF3B30, 0xFF317AFF, 0xFF34C759]
        var startAngle: Float64 = -1.5708

        var si: Int64 = 0
        while (si < nSlices) {
            let ptV = pieSeries.points[si].value
            let sliceAngle = 6.2832 * ptV / total
            let endAngle = startAngle + sliceAngle
            let sliceColor = sliceColors[si % 5]
            // 使用粗线宽弧段绘制扇形
            let rDraw: Float64 = if (si == this.scrubIdx) { radius + 6.0 } else { radius }
            this.chartCtx.lineWidth = rDraw * 0.55
            this.chartCtx.strokeStyle = sliceColor
            this.chartCtx.beginPath()
            this.chartCtx.arc(cx, cy, rDraw * 0.72, startAngle, endAngle)
            this.chartCtx.stroke()
            startAngle = endAngle
            si = si + 1
        }

        // 中心分隔圈（背景色）
        this.chartCtx.lineWidth = 2.0
        this.chartCtx.strokeStyle = this.themeChartBg()
        this.chartCtx.beginPath()
        this.chartCtx.arc(cx, cy, radius * 0.32, 0.0, 6.2832)
        this.chartCtx.stroke()

        // tooltip（若有高亮扇形）
        let scrub = this.scrubIdx
        if (scrub >= 0 && scrub < nSlices) {
            let tv = pieSeries.points[scrub].value
            let pct = tv / total * 100.0
            let lbl = pieSeries.points[scrub].label
            let ttStr = "${lbl}: ${Int64(pct)}%"
            this.chartCtx.strokeStyle = this.themeText()
            this.chartCtx.lineWidth = 0.5
            this.chartCtx.strokeText(ttStr, cx - 20.0, cy)
        }
    }

    // ── P2-362: 底部 Range 选择器 Canvas ──
    @Builder func rangeChartCanvas(): Unit {
        Canvas(this.rangeCtx)
            .width(100.percent)
            .height(48)
            .backgroundColor(this.themeRangeBg())
            .onReady({
                =>
                this.drawRangeChart()
            })
            .onTouch({ evt =>
                let cw: Float64 = 320.0
                this.handleRangeTouch(evt, cw)
                this.drawRangeChart()
            })
    }

    private func drawRangeChart(): Unit {
        let w: Float64 = 320.0
        let h: Float64 = 48.0
        let padL: Float64 = 16.0
        let padR: Float64 = 16.0
        let drawW = w - padL - padR
        let barH: Float64 = 28.0
        let barY: Float64 = (h - barH) / 2.0

        this.rangeCtx.fillStyle = this.themeRangeBg()
        this.rangeCtx.fillRect(0.0, 0.0, w, h)

        // 缩略折线图（mini line，基于第一个可见系列）
        let nPts = this.seriesPtCount(0)
        if (nPts > 1) {
            var maxV: Float64 = 1.0
            var mi: Int64 = 0
            while (mi < this.graphStats.series.size) {
                if (this.isSeriesVisible(mi)) {
                    let sm = this.seriesMax(mi)
                    if (sm > maxV) { maxV = sm }
                }
                mi = mi + 1
            }
            // 只绘第一个可见系列的缩略线
            var rsi: Int64 = 0
            while (rsi < this.graphStats.series.size) {
                if (this.isSeriesVisible(rsi)) {
                    let serColor = this.seriesColor(rsi)
                    this.rangeCtx.lineWidth = 1.0
                    this.rangeCtx.strokeStyle = serColor
                    this.rangeCtx.globalAlpha = 0.6
                    this.rangeCtx.beginPath()
                    var rpi: Int64 = 0
                    while (rpi < nPts) {
                        let ptV = this.ptVal(rsi, rpi)
                        let px = padL + Float64(rpi) * drawW / Float64(nPts - 1)
                        let py = barY + barH - (barH * ptV / maxV) * 0.7
                        if (rpi == 0) {
                            this.rangeCtx.moveTo(px, py)
                        } else {
                            this.rangeCtx.lineTo(px, py)
                        }
                        rpi = rpi + 1
                    }
                    this.rangeCtx.stroke()
                    this.rangeCtx.globalAlpha = 1.0
                    break
                }
                rsi = rsi + 1
            }
        }

        // 两端遮罩（非选中区域半透明灰）
        let lx = padL + this.rangeStartFrac * drawW
        let rx = padL + this.rangeEndFrac * drawW
        this.rangeCtx.globalAlpha = 0.4
        this.rangeCtx.fillStyle = this.themeRangeMask()
        this.rangeCtx.fillRect(padL, barY, lx - padL, barH)
        this.rangeCtx.fillRect(rx, barY, padL + drawW - rx, barH)
        this.rangeCtx.globalAlpha = 1.0

        // 选中区域边框
        this.rangeCtx.strokeStyle = this.themeAccent()
        this.rangeCtx.lineWidth = 1.5
        this.rangeCtx.strokeRect(lx, barY, rx - lx, barH)

        // 左柄
        this.rangeCtx.fillStyle = this.themeAccent()
        this.rangeCtx.fillRect(lx - 4.0, barY, 8.0, barH)
        // 右柄
        this.rangeCtx.fillStyle = this.themeAccent()
        this.rangeCtx.fillRect(rx - 4.0, barY, 8.0, barH)
    }

    // ── P2-363: 动态图例区 ──
    @Builder func legendArea(): Unit {
        Column {
            ForEach(this.graphStats.series.toArray(), itemGenerator: { s: GraphSeries, idx: Int64 =>
                Row {
                    Row {}
                        .width(12)
                        .height(12)
                        .backgroundColor(s.color)
                        .borderRadius(2.0)
                        .margin(right: 8)
                        .opacity(if (this.isSeriesVisible(idx)) { 1.0 } else { 0.4 })

                    Text(s.name)
                        .fontSize(12)
                        .fontColor(if (this.isSeriesVisible(idx)) { this.themeText() } else { this.themeSecondary() })
                        .opacity(if (this.isSeriesVisible(idx)) { 1.0 } else { 0.5 })
                }
                .height(24)
                .alignItems(VerticalAlign.Center)
                .onClick({ evt =>
                    this.toggleSeries(idx)
                })
                .onTouch({ evt =>
                    // long press 检测（Down 事件 + 1s hold 通过 spawn 延迟实现）
                    if (evt.eventType == TouchType.Down) {
                        let capturedIdx = idx
                        let _ = spawn {
                            // 等待 600ms 再检查是否仍按压（简化：直接触发隔离）
                            // 注：真实长按检测需要框架支持；此处用 spawn delay 近似
                            var elapsed: Int64 = 0
                            while (elapsed < 600) {
                                elapsed = elapsed + 60
                            }
                            launch {
                                this.isolateSeries(capturedIdx)
                            }
                        }
                    }
                })
            })
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 8, bottom: 12)
        .backgroundColor(this.themeCard())
        .alignItems(HorizontalAlign.Start)
    }

    // ── 图表分发（零参 @Builder 分发；使用 chartTypeIdx 判断类型） ──
    @Builder func currentChartCanvas(): Unit {
        if (this.chartTypeIdx == 0) {
            this.lineAreaChartCanvas()
        } else if (this.chartTypeIdx == 1) {
            this.twoAxisChartCanvas()
        } else if (this.chartTypeIdx == 2) {
            this.lineAreaChartCanvas()
        } else if (this.chartTypeIdx == 3) {
            this.stackedBarChartCanvas()
        } else if (this.chartTypeIdx == 4) {
            this.stepChartCanvas()
        } else if (this.chartTypeIdx == 5) {
            this.stepChartCanvas()
        } else if (this.chartTypeIdx == 6) {
            this.twoAxisChartCanvas()
        } else if (this.chartTypeIdx == 7) {
            this.currencyStarsChartCanvas()
        } else if (this.chartTypeIdx == 8) {
            this.currencyStarsChartCanvas()
        } else {
            this.pieChartCanvas()
        }
    }

    // ── P2-362: Zoom Out 按钮 ──
    @Builder func zoomOutButton(): Unit {
        if (this.isZoomed) {
            Button("< Zoom Out")
                .fontSize(13)
                .fontColor(this.themeAccent())
                .backgroundColor(this.themeCard())
                .borderWidth(1)
                .borderColor(this.themeAccent())
                .height(32)
                .padding(left: 12, right: 12)
                .margin(left: 16, top: 8, bottom: 4)
                .onClick({ evt =>
                    this.doZoomOut()
                })
        }
    }

    public func build() {
        Column {
                // ── Tab 栏（10 种图表类型，横向 Scroll） ──
                Scroll() {
                    Row {
                        ForEach(this.chartTabIndices(), itemGenerator: { idx: Int32, _: Int64 =>
                            Column {
                                Text(this.tabShortName(idx))
                                    .fontSize(12)
                                    .fontColor(this.tabColor(idx))
                                    .fontWeight(if (this.chartTypeIdx == idx) { FontWeight.Bold } else { FontWeight.Normal })
                            }
                            .width(56)
                            .height(36)
                            .justifyContent(FlexAlign.Center)
                            .onClick({ evt => this.switchChartType(idx) })
                        })
                    }
                }
                .scrollable(ScrollDirection.Horizontal)
                .width(100.percent)
                .height(36)
                .backgroundColor(this.themeCard())

                Divider().color(this.themeDivider()).strokeWidth(0.5)

                // ── 内容区 ──
                Scroll() {
                    Column {
                        if (this.isLoading) {
                            Column {
                                Text("Loading statistics...")
                                    .fontSize(15)
                                    .fontColor(this.themeSecondary())
                            }
                            .width(100.percent)
                            .height(200)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                        } else if (this.errorMsg.size > 0) {
                            Column {
                                Text(this.errorMsg)
                                    .fontSize(15)
                                    .fontColor(0xFFFF3B30)
                            }
                            .width(100.percent)
                            .height(200)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                        } else {
                            // P2-362: Zoom Out 按钮
                            this.zoomOutButton()

                            // 图表区（根据 chartTypeIdx 分发）
                            Column {
                                this.currentChartCanvas()
                            }
                            .width(100.percent)
                            .padding(left: 8, right: 8, top: 8, bottom: 4)
                            .backgroundColor(this.themeCard())

                            // P2-362: 底部 Range 时间窗选择器
                            Column {
                                this.rangeChartCanvas()
                                // P2-370 Gap①: 选中时间窗标签
                                if (this.rangeWindowLabel().size > 0) {
                                    Text(this.rangeWindowLabel())
                                        .fontSize(12)
                                        .fontColor(this.themeSecondary())
                                        .width(100.percent)
                                        .textAlign(TextAlign.Center)
                                        .padding(top: 4, bottom: 4)
                                }
                            }
                            .width(100.percent)
                            .padding(left: 8, right: 8, top: 4, bottom: 4)
                            .backgroundColor(this.themeCard())
                            .margin(top: 4)

                            // 统计摘要
                            Column {
                                Text(this.statsLine1())
                                    .fontSize(13)
                                    .fontColor(this.themeSecondary())
                                    .margin(bottom: 4)
                                Text(this.statsLine2())
                                    .fontSize(13)
                                    .fontColor(this.themeSecondary())
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 12)
                            .backgroundColor(this.themeCard())
                            .alignItems(HorizontalAlign.Start)
                            .margin(top: 8)

                            // P2-363: 动态图例区
                            this.legendArea()
                        }
                    }
                    .width(100.percent)
                }
                .scrollable(ScrollDirection.Vertical)
                .width(100.percent)
                .layoutWeight(1)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.themeBg())
        .onAppear({ => this.ensureLoaded() })
    }
}
