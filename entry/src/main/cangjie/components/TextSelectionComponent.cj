package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{TextSelectionService, getTextSelectionService}
import std.collection.ArrayList
import std.time.*
import std.sync.*

/**
 * 单个选区高亮矩形的布局信息
 * 对应 iOS TextRangeRectEdge / [CGRect] 矩形数组
 */
public class SelectionRect <: ToString {
    public var x: Float64 = 0.0
    public var y: Float64 = 0.0
    public var width: Float64 = 0.0
    public var height: Float64 = 0.0
    public var rectIndex: Int64 = 0

    public init() {}
    public init(x: Float64, y: Float64, width: Float64, height: Float64, idx: Int64) {
        this.x = x
        this.y = y
        this.width = width
        this.height = height
        this.rectIndex = idx
    }

    public func toString(): String {
        "rect_${this.rectIndex}"
    }
}

/**
 * TextSelectionComponent — 消息文字选区高亮 + 拖拽手柄 + 操作菜单
 *
 * 使用方式（在 ChatRoomPage 或 MessageBubble 中）：
 *
 *   TextSelectionComponent(
 *       messageText: msg.content,
 *       onCopy: { text: String => ... },
 *       onQuote: { text: String, start: Int64, end: Int64 => ... },
 *       onDismiss: { => ... }
 *   )
 *
 * 功能：
 *   - 长按触发词选并弹出操作菜单
 *   - 左右手柄可拖拽扩展选区
 *   - Copy：调用 TextSelectionService.copySelectedText()（→ onCopyCallback）
 *   - Quote：调用 TextSelectionService.quoteSelectedText()（→ onQuoteCallback）
 *   - Select All：调用 TextSelectionService.selectAll()
 *   - 点击空白区域或 Dismiss 关闭选区
 *
 * 与 iOS TextSelectionNode 的对应关系：
 *   iOS beginSelection (longTap) → onTouch LongPress → selectWordAt + showMenu
 *   iOS moveKnob (.left/.right) → drag handle → setSelection
 *   iOS performAction(.copy) → copySelectedText()
 *   iOS performAction(.quote) → quoteSelectedText()
 */
@Component
public class TextSelectionComponent {
    // 绑定的消息文本（外部传入，只读）
    public var messageText: String = ""

    // 操作回调（由 ChatRoomPage 绑定实际逻辑）
    public var onCopy: (String) -> Unit = { _text: String => }
    public var onQuote: (String, Int64, Int64) -> Unit = { _text: String, _s: Int64, _e: Int64 => }
    public var onDismiss: () -> Unit = { => }

    // 内部 UI 状态
    @State var isSelectionActive: Bool = false
    @State var showMenu: Bool = false
    @State var selectionStart: Int64 = 0
    @State var selectionEnd: Int64 = 0

    // 触摸/手柄拖拽状态
    @State var draggingLeft: Bool = false
    @State var draggingRight: Bool = false
    @State var longPressActive: Bool = false
    @State var touchStartX: Float64 = 0.0
    @State var touchStartY: Float64 = 0.0

    // 估算的字符宽度（基于组件渲染宽度，用于命中测试）
    // 假设每字符约 9px（fontSize 15 等宽估算）
    private let charWidthEstimate: Float64 = 9.0
    // 行高估算（单行选区高度）
    private let lineHeightEstimate: Float64 = 20.0
    // 手柄触摸区半径（px）
    private let knobHitRadius: Float64 = 18.0

    // ==================== 生命周期 ====================

    public override func aboutToAppear(): Unit {
        let svc = getTextSelectionService()
        svc.setSourceText(this.messageText)
        svc.onCopyCallback = { text: String =>
            this.onCopy(text)
        }
        svc.onQuoteCallback = { text: String, start: Int64, end: Int64 =>
            this.onQuote(text, start, end)
        }
    }

    public override func aboutToDisappear(): Unit {
        let svc = getTextSelectionService()
        svc.clearSelection()
        this.isSelectionActive = false
        this.showMenu = false
    }

    // ==================== 辅助方法（提取，避免 build 中 let）====================

    /**
     * 将触摸 X 坐标转换为字符索引（行内偏移估算）
     * 多行文本需行高估算，这里只做单行简化
     */
    private func touchToCharIndex(touchX: Float64, touchY: Float64): Int64 {
        let col = Int64(touchX / this.charWidthEstimate)
        let row = Int64(touchY / this.lineHeightEstimate)
        let charsPerRow = Int64(360.0 / this.charWidthEstimate)
        let idx = row * charsPerRow + col
        let textLen = Int64(this.messageText.toRuneArray().size)
        if (idx < 0) { return Int64(0) }
        if (idx >= textLen) { return textLen }
        return idx
    }

    /**
     * 左手柄中心 X（对应 selectionStart 字符的估算像素位置）
     */
    private func leftKnobX(): Float64 {
        let charsPerRow = Int64(360.0 / this.charWidthEstimate)
        if (charsPerRow <= 0) { return 0.0 }
        let col = this.selectionStart % charsPerRow
        return Float64(col) * this.charWidthEstimate
    }

    /**
     * 右手柄中心 X（对应 selectionEnd 字符的估算像素位置）
     */
    private func rightKnobX(): Float64 {
        let charsPerRow = Int64(360.0 / this.charWidthEstimate)
        if (charsPerRow <= 0) { return 0.0 }
        let col = this.selectionEnd % charsPerRow
        return Float64(col) * this.charWidthEstimate
    }

    /**
     * 左手柄顶部 Y
     */
    private func leftKnobY(): Float64 {
        let charsPerRow = Int64(360.0 / this.charWidthEstimate)
        if (charsPerRow <= 0) { return 0.0 }
        let row = this.selectionStart / charsPerRow
        return Float64(row) * this.lineHeightEstimate
    }

    /**
     * 右手柄底部 Y
     */
    private func rightKnobY(): Float64 {
        let charsPerRow = Int64(360.0 / this.charWidthEstimate)
        if (charsPerRow <= 0) { return 0.0 }
        let row = this.selectionEnd / charsPerRow
        return Float64(row + 1) * this.lineHeightEstimate
    }

    /**
     * 根据 selectionStart/End 生成选区高亮矩形列表
     * 多行时每行一个矩形
     */
    private func buildSelectionRects(): Array<SelectionRect> {
        if (this.selectionStart >= this.selectionEnd) {
            return Array<SelectionRect>(0, { _i: Int64 => SelectionRect() })
        }
        let charsPerRow = Int64(360.0 / this.charWidthEstimate)
        if (charsPerRow <= 0) {
            return Array<SelectionRect>(0, { _i: Int64 => SelectionRect() })
        }
        let startRow = this.selectionStart / charsPerRow
        let endRow = (this.selectionEnd - 1) / charsPerRow
        let rowCount = endRow - startRow + 1
        let rects = ArrayList<SelectionRect>()
        var i: Int64 = 0
        while (i < rowCount) {
            let row = startRow + i
            let rowStartChar = row * charsPerRow
            let rectLeft = if (row == startRow) {
                Float64(this.selectionStart - rowStartChar) * this.charWidthEstimate
            } else {
                0.0
            }
            let rectRight = if (row == endRow) {
                Float64(this.selectionEnd - rowStartChar) * this.charWidthEstimate
            } else {
                360.0
            }
            let rect = SelectionRect(
                rectLeft,
                Float64(row) * this.lineHeightEstimate,
                rectRight - rectLeft,
                this.lineHeightEstimate,
                i
            )
            rects.add(rect)
            i = i + 1
        }
        let immutableRects = rects
        return Array<SelectionRect>(immutableRects.size, { idx: Int64 => immutableRects[idx] })
    }

    /**
     * 判断触摸点是否命中左手柄区域
     */
    private func hitsLeftKnob(tx: Float64, ty: Float64): Bool {
        let kx = this.leftKnobX()
        let ky = this.leftKnobY()
        let dx = tx - kx
        let dy = ty - ky
        return (dx * dx + dy * dy) < (this.knobHitRadius * this.knobHitRadius)
    }

    /**
     * 判断触摸点是否命中右手柄区域
     */
    private func hitsRightKnob(tx: Float64, ty: Float64): Bool {
        let kx = this.rightKnobX()
        let ky = this.rightKnobY()
        let dx = tx - kx
        let dy = ty - ky
        return (dx * dx + dy * dy) < (this.knobHitRadius * this.knobHitRadius)
    }

    /**
     * 触发长按词选
     */
    private func triggerWordSelection(tx: Float64, ty: Float64): Unit {
        let idx = this.touchToCharIndex(tx, ty)
        let svc = getTextSelectionService()
        svc.setSourceText(this.messageText)
        svc.selectWordAt(idx)
        let r = svc.getRange()
        this.selectionStart = r.start
        this.selectionEnd = r.end
        this.isSelectionActive = true
        this.showMenu = true
    }

    /**
     * 更新选区并同步 Service
     */
    private func updateSelectionEnd(newEnd: Int64): Unit {
        let svc = getTextSelectionService()
        svc.setSelection(this.selectionStart, newEnd)
        let r = svc.getRange()
        this.selectionStart = r.start
        this.selectionEnd = r.end
    }

    private func updateSelectionStart(newStart: Int64): Unit {
        let svc = getTextSelectionService()
        svc.setSelection(newStart, this.selectionEnd)
        let r = svc.getRange()
        this.selectionStart = r.start
        this.selectionEnd = r.end
    }

    /**
     * 执行复制
     */
    private func doCopy(): Unit {
        let svc = getTextSelectionService()
        svc.copySelectedText()
        this.showMenu = false
        this.isSelectionActive = false
        this.onDismiss()
    }

    /**
     * 执行引用
     */
    private func doQuote(): Unit {
        let svc = getTextSelectionService()
        svc.quoteSelectedText()
        this.showMenu = false
        this.isSelectionActive = false
        this.onDismiss()
    }

    /**
     * 全选
     */
    private func doSelectAll(): Unit {
        let svc = getTextSelectionService()
        svc.selectAll()
        let r = svc.getRange()
        this.selectionStart = r.start
        this.selectionEnd = r.end
        this.showMenu = true
    }

    /**
     * 关闭选区
     */
    private func doDismiss(): Unit {
        let svc = getTextSelectionService()
        svc.clearSelection()
        this.isSelectionActive = false
        this.showMenu = false
        this.draggingLeft = false
        this.draggingRight = false
        this.onDismiss()
    }

    // ==================== 高亮矩形 Builder ====================

    @Builder
    func highlightRects() {
        ForEach(this.buildSelectionRects(), itemGenerator: { rect: SelectionRect, _idx: Int64 =>
            Row {}
                .width(rect.width)
                .height(rect.height)
                .backgroundColor(0x33187EFF)
                .borderRadius(2)
                .position(x: rect.x, y: rect.y)
        })
    }

    // ==================== 手柄 Builder ====================

    @Builder
    func leftHandleKnob() {
        Column {
            // 手柄圆点
            Row {}
                .width(12)
                .height(12)
                .borderRadius(6)
                .backgroundColor(0xFF187EFF)
            // 手柄竖线
            Row {}
                .width(2)
                .height(this.lineHeightEstimate)
                .backgroundColor(0xFF187EFF)
        }
        .width(12)
        .position(x: this.leftKnobX() - 6.0, y: this.leftKnobY() - 12.0)
    }

    @Builder
    func rightHandleKnob() {
        Column {
            // 手柄竖线
            Row {}
                .width(2)
                .height(this.lineHeightEstimate)
                .backgroundColor(0xFF187EFF)
            // 手柄圆点
            Row {}
                .width(12)
                .height(12)
                .borderRadius(6)
                .backgroundColor(0xFF187EFF)
        }
        .width(12)
        .position(x: this.rightKnobX() - 4.0, y: this.rightKnobY() - this.lineHeightEstimate)
    }

    // ==================== 操作菜单 Builder ====================

    @Builder
    func selectionMenu() {
        Row {
            // 复制
            Text("复制")
                .fontSize(14)
                .fontColor(Color.White)
                .padding(left: 12, right: 12, top: 6, bottom: 6)
                .onClick({ _evt =>
                    this.doCopy()
                })
            // 分隔线
            Row {}
                .width(1)
                .height(20)
                .backgroundColor(0x88FFFFFF)
            // 引用
            Text("引用")
                .fontSize(14)
                .fontColor(Color.White)
                .padding(left: 12, right: 12, top: 6, bottom: 6)
                .onClick({ _evt =>
                    this.doQuote()
                })
            // 分隔线
            Row {}
                .width(1)
                .height(20)
                .backgroundColor(0x88FFFFFF)
            // 全选
            Text("全选")
                .fontSize(14)
                .fontColor(Color.White)
                .padding(left: 12, right: 12, top: 6, bottom: 6)
                .onClick({ _evt =>
                    this.doSelectAll()
                })
        }
        .backgroundColor(0xDD222222)
        .borderRadius(6)
        .height(34)
        .position(x: this.leftKnobX(), y: if (this.leftKnobY() > 40.0) { this.leftKnobY() - 40.0 } else { this.rightKnobY() + 8.0 })
    }

    // ==================== 主 build ====================

    func build() {
        Stack(alignContent: Alignment.TopStart) {
            // 文本层（只读显示）
            Text(this.messageText)
                .fontSize(15)
                .fontColor(0xFF000000)
                .lineHeight(this.lineHeightEstimate)
                .width(100.percent)
                .onTouch({ evt =>
                    match (evt.eventType) {
                        case TouchType.Down =>
                            if (evt.touches.size > 0) {
                                this.touchStartX = evt.touches[0].x
                                this.touchStartY = evt.touches[0].y
                            }
                            // 检查是否命中手柄（选区已激活时）
                            if (this.isSelectionActive) {
                                if (this.hitsLeftKnob(this.touchStartX, this.touchStartY)) {
                                    this.draggingLeft = true
                                    this.draggingRight = false
                                } else if (this.hitsRightKnob(this.touchStartX, this.touchStartY)) {
                                    this.draggingRight = true
                                    this.draggingLeft = false
                                } else {
                                    this.longPressActive = true
                                    let capturedX = this.touchStartX
                                    let capturedY = this.touchStartY
                                    let _ = spawn {
                                        sleep(300 * Duration.millisecond)
                                        if (this.longPressActive) {
                                            launch {
                                                this.longPressActive = false
                                                this.triggerWordSelection(capturedX, capturedY)
                                            }
                                        }
                                    }
                                }
                            } else {
                                this.longPressActive = true
                                let capturedX = this.touchStartX
                                let capturedY = this.touchStartY
                                let _ = spawn {
                                    sleep(300 * Duration.millisecond)
                                    if (this.longPressActive) {
                                        launch {
                                            this.longPressActive = false
                                            this.triggerWordSelection(capturedX, capturedY)
                                        }
                                    }
                                }
                            }
                        case TouchType.Move =>
                            if (evt.touches.size > 0) {
                                let tx = evt.touches[0].x
                                let ty = evt.touches[0].y
                                let dxMove = tx - this.touchStartX
                                let dyMove = ty - this.touchStartY
                                if (dxMove * dxMove + dyMove * dyMove > 100.0) {
                                    this.longPressActive = false
                                }
                                if (this.draggingLeft) {
                                    let newStart = this.touchToCharIndex(tx, ty)
                                    this.updateSelectionStart(newStart)
                                    this.showMenu = false
                                } else if (this.draggingRight) {
                                    let newEnd = this.touchToCharIndex(tx, ty)
                                    this.updateSelectionEnd(newEnd)
                                    this.showMenu = false
                                }
                            }
                        case TouchType.Up =>
                            this.longPressActive = false
                            if (this.draggingLeft || this.draggingRight) {
                                this.draggingLeft = false
                                this.draggingRight = false
                                this.showMenu = true
                            }
                        case TouchType.Cancel =>
                            this.longPressActive = false
                            this.draggingLeft = false
                            this.draggingRight = false
                        case _ => ()
                    }
                })

            // 选区高亮层
            if (this.isSelectionActive) {
                Stack(alignContent: Alignment.TopStart) {
                    this.highlightRects()
                    this.leftHandleKnob()
                    this.rightHandleKnob()
                    if (this.showMenu) {
                        this.selectionMenu()
                    }
                }
                .width(100.percent)
                .height(100.percent)
                // 点击高亮层空白区域关闭选区
                .onClick({ _evt =>
                    this.doDismiss()
                })
            }
        }
        .width(100.percent)
    }
}
