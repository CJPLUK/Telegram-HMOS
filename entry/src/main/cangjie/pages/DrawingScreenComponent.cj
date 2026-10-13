package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.math.*
import ohos_app_cangjie_entry.services.*
import kit.ImageKit.{PixelMap, Region}
import kit.ImageKit.Size as IKSize
import ohos.business_exception.BusinessException
import ohos.resource.__GenerateResource__
import kit.CoreFileKit.*
import std.time.DateTime
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.components.StickerKeyboardPanel

// DrawingScreenComponent — Canvas-based freehand drawing surface
// P2-081: pen/marker/neon(multi-layer glow)/arrow/eraser/blur tools
// P2-082: size/opacity Slider UI wired to DrawingService, eyedropper tap mode
// P2-087: undo + redo (redoStack) via DrawingService stroke-delta stack

@Component
public class DrawingScreenComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var baseQuarterTurns: Int64 = 0
    public var baseMirrored: Bool = false
    public var persistResult: Bool = true
    public var onClose: () -> Unit = { => routerPop() }
    public var onDone: () -> Unit = { => routerPop() }
    // UI state driving refresh
    @State var strokeCount: Int64 = 0
    @State var canUndo: Bool = false
    @State var canRedo: Bool = false
    @State var currentToolIdx: Int32 = 0
    @State var colorPreview: UInt32 = 0xFF000000
    // P2-082: size and opacity state (0..100 / 0..100 for display as percentage)
    @State var sizeSlider: Float64 = 10.0
    @State var opacitySlider: Float64 = 100.0
    // P2-082: eyedropper mode — when active, next canvas tap reads pixel color
    @State var eyedropperActive: Bool = false
    @State var currentMode: String = "draw"
    @State var textValue: String = ""
    @State var showStickerPicker: Bool = false
    @State var showShapePicker: Bool = false
    @State var entityRevision: Int64 = 0

    // Active stroke being drawn (not yet committed to service)
    private var activeStroke: Option<DrawingStroke> = None
    private var canvasContext: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    // P2-088: canvas actual dimensions (set in onReady) — used for flatten export
    private var canvasActualW: Float64 = 0.0
    private var canvasActualH: Float64 = 0.0

    private func svc(): DrawingService {
        return getDrawingService()
    }

    public override func aboutToAppear(): Unit {
        let service = this.svc()
        let color = service.getCurrentColor()
        this.colorPreview = color.toUInt32ARGB()
        this.canUndo = service.canUndo()
        this.canRedo = service.canRedo()
        this.updateToolIdx()
        this.sizeSlider = service.getCurrentSize()
        this.opacitySlider = service.getOpacity() * 100.0
        // P2-088: register flatten callback with DrawingFlattenService
        getDrawingFlattenService().registerFlattenCallback({ => let _ = this.flattenAndExport() })
    }

    public override func aboutToDisappear(): Unit {
        // P2-088: unregister flatten callback
        getDrawingFlattenService().unregisterFlattenCallback()
    }

    private func updateToolIdx(): Unit {
        let tool = this.svc().getCurrentTool()
        this.currentToolIdx = tool.ordinal()
    }

    private func selectTool(tool: DrawingTool): Unit {
        this.svc().setCurrentTool(tool)
        this.updateToolIdx()
    }

    // MARK: - Canvas rendering

    private func redrawCanvas(): Unit {
        let ctx = this.canvasContext
        ctx.clearRect(0.0, 0.0, 10000.0, 10000.0)
        // Canvas 在当前 HarmonyOS 渲染管线中会形成独立不透明层，放在其下方的
        // ArkUI Image 无法透出。像 iOS DrawingView 一样先把底图画入同一画布，
        // 再重放笔触，既能正确预览，也保证导出内容与屏幕一致。
        match (this.svc().getBasePixelMap()) {
            case Some(base) =>
                let width = if (this.canvasActualW > 0.0) { this.canvasActualW } else { 375.0 }
                let height = if (this.canvasActualH > 0.0) { this.canvasActualH } else { 500.0 }
                let info = base.getImageInfo()
                let sourceW = Float64(info.size.width)
                let sourceH = Float64(info.size.height)
                if (sourceW > 0.0 && sourceH > 0.0) {
                    let turns = ((this.baseQuarterTurns % 4) + 4) % 4
                    let effectiveW = if (turns % 2 == 0) { sourceW } else { sourceH }
                    let effectiveH = if (turns % 2 == 0) { sourceH } else { sourceW }
                    let scaleX = width / effectiveW
                    let scaleY = height / effectiveH
                    let scale = if (scaleX > scaleY) { scaleX } else { scaleY }
                    let drawW = sourceW * scale
                    let drawH = sourceH * scale
                    ctx.save()
                    ctx.translate(width / 2.0, height / 2.0)
                    ctx.rotate(-Float64(turns) * 1.5707963267948966)
                    if (this.baseMirrored) { ctx.scale(-1.0, 1.0) }
                    ctx.drawImage(base, -drawW / 2.0, -drawH / 2.0, drawW, drawH)
                    ctx.restore()
                }
            case None => ()
        }
        let strokes = this.svc().getStrokes()
        for (stroke in strokes) {
            this.drawStroke(ctx, stroke)
        }
        match (this.activeStroke) {
            case Some(active) => this.drawStroke(ctx, active)
            case None => ()
        }
        for (shape in this.svc().getShapeOverlays()) {
            this.drawShape(ctx, shape)
        }
        for (sticker in this.svc().getStickerOverlays()) {
            ctx.drawImage(sticker.image, sticker.x, sticker.y, sticker.size, sticker.size)
        }
        for (textEntity in this.svc().getTextOverlays()) {
            if (!textEntity.text.isEmpty()) {
                ctx.fillStyle = Int64(textEntity.color.toUInt32ARGB())
                ctx.font = "${textEntity.fontSize}px sans-serif"
                ctx.textAlign = "center"
                ctx.textBaseline = "middle"
                ctx.fillText(textEntity.text, textEntity.x, textEntity.y)
            }
        }
    }

    private func drawShape(ctx: CanvasRenderingContext2D, shape: DrawingShapeOverlay): Unit {
        let half = shape.size / 2.0
        let left = shape.x - half
        let top = shape.y - half
        ctx.strokeStyle = Int64(shape.color.toUInt32ARGB())
        ctx.lineWidth = 5.0
        ctx.lineCap = "round"
        ctx.lineJoin = "round"
        ctx.beginPath()
        if (shape.shapeType == 0) {
            ctx.strokeRect(left, top, shape.size, shape.size)
            return
        }
        if (shape.shapeType == 1) {
            ctx.ellipse(shape.x, shape.y, half, half * 0.72, 0.0, 0.0, 6.283185307179586, counterclockwise: false)
            ctx.stroke()
            return
        }
        if (shape.shapeType == 2) {
            ctx.moveTo(left + shape.size * 0.18, top)
            ctx.lineTo(left + shape.size * 0.82, top)
            ctx.lineTo(left + shape.size, top + shape.size * 0.18)
            ctx.lineTo(left + shape.size, top + shape.size * 0.70)
            ctx.lineTo(left + shape.size * 0.58, top + shape.size * 0.70)
            ctx.lineTo(left + shape.size * 0.36, top + shape.size)
            ctx.lineTo(left + shape.size * 0.34, top + shape.size * 0.70)
            ctx.lineTo(left, top + shape.size * 0.70)
            ctx.lineTo(left, top + shape.size * 0.18)
            ctx.closePath(); ctx.stroke(); return
        }
        if (shape.shapeType == 3) {
            var point: Int64 = 0
            while (point < 10) {
                let angle = -1.5707963267948966 + Float64(point) * 0.6283185307179586
                let radius = if (point % 2 == 0) { half } else { half * 0.43 }
                let px = shape.x + cos(angle) * radius
                let py = shape.y + sin(angle) * radius
                if (point == 0) { ctx.moveTo(px, py) } else { ctx.lineTo(px, py) }
                point += 1
            }
            ctx.closePath(); ctx.stroke(); return
        }
        ctx.moveTo(left, shape.y)
        ctx.lineTo(left + shape.size * 0.78, shape.y)
        ctx.moveTo(left + shape.size * 0.58, top + shape.size * 0.30)
        ctx.lineTo(left + shape.size * 0.82, shape.y)
        ctx.lineTo(left + shape.size * 0.58, top + shape.size * 0.70)
        ctx.stroke()
    }

    // P2-081: compute neon glow color — for very dark strokes use purple shadow
    private func neonGlowColorInt(stroke: DrawingStroke): Int64 {
        let r = stroke.color.r
        let g = stroke.color.g
        let b = stroke.color.b
        let lum = r * 0.299 + g * 0.587 + b * 0.114
        if (lum < 0.04) {
            return 0xFF440881
        }
        return Int64(stroke.color.toUInt32ARGB())
    }

    // P2-081: arrow rendering helpers — compute direction from last 2 significant points
    private func arrowHeadAngle(stroke: DrawingStroke): Float64 {
        let pts = stroke.points
        if (pts.size < 2) {
            return 0.0
        }
        let tip = pts[pts.size - 1]
        var i: Int64 = pts.size - 2
        while (i >= 0) {
            let pt = pts[i]
            let dx = tip.x - pt.x
            let dy = tip.y - pt.y
            let dist = sqrt(dx * dx + dy * dy)
            if (dist > stroke.size * 2.0) {
                return atan2(dy, dx)
            }
            i -= 1
        }
        let pt0 = pts[0]
        return atan2(tip.y - pt0.y, tip.x - pt0.x)
    }

    // P2-081: draw blur stroke as a series of semi-transparent dark rectangles (pixelation effect)
    // Canvas does not expose blur filter in current ArkUI binding, so we simulate it by
    // drawing filled rounded rectangles with high opacity dark gray along the path.
    // This is an honest approximation: noted in known limitations.
    private func drawBlurStroke(ctx: CanvasRenderingContext2D, stroke: DrawingStroke): Unit {
        if (stroke.points.size < 1) {
            return
        }
        let halfSize = stroke.size * 1.5
        ctx.globalAlpha = 0.18
        ctx.fillStyle = 0xFF222222
        var i: Int64 = 0
        while (i < stroke.points.size) {
            let pt = stroke.points[i]
            ctx.fillRect(pt.x - halfSize, pt.y - halfSize, halfSize * 2.0, halfSize * 2.0)
            i += 2
        }
        ctx.globalAlpha = 1.0
    }

    // P2-081: draw neon stroke with multi-layer glow effect
    // Layer 1: wide semi-transparent glow halo
    // Layer 2: medium stroke with high opacity (the beam)
    // Layer 3: thin bright white core
    private func drawNeonStroke(ctx: CanvasRenderingContext2D, stroke: DrawingStroke): Unit {
        if (stroke.points.size < 1) {
            return
        }
        let glowColor = this.neonGlowColorInt(stroke)
        let baseColorInt = Int64(stroke.color.toUInt32ARGB())

        ctx.beginPath()
        let fp = stroke.points[0]
        ctx.moveTo(fp.x, fp.y)
        var i: Int64 = 1
        while (i < stroke.points.size) {
            let pt = stroke.points[i]
            ctx.lineTo(pt.x, pt.y)
            i += 1
        }
        ctx.lineCap = "round"
        ctx.lineJoin = "round"

        // Glow halo layer (widest, most transparent)
        ctx.strokeStyle = glowColor
        ctx.lineWidth = stroke.size * 3.5
        ctx.globalAlpha = 0.28
        ctx.stroke()

        // Secondary glow
        ctx.strokeStyle = glowColor
        ctx.lineWidth = stroke.size * 2.2
        ctx.globalAlpha = 0.45
        ctx.stroke()

        // Main beam with original color
        ctx.strokeStyle = baseColorInt
        ctx.lineWidth = stroke.size
        ctx.globalAlpha = 0.85
        ctx.stroke()

        // White core for bright shine
        ctx.strokeStyle = 0xFFFFFFFF
        ctx.lineWidth = stroke.size * 0.35
        ctx.globalAlpha = 0.55
        ctx.stroke()

        ctx.globalAlpha = 1.0
    }

    // P2-081: draw arrow stroke — line body + arrowhead at tip
    private func drawArrowStroke(ctx: CanvasRenderingContext2D, stroke: DrawingStroke): Unit {
        if (stroke.points.size < 1) {
            return
        }
        let colorInt = Int64(stroke.color.toUInt32ARGB())
        ctx.strokeStyle = colorInt
        ctx.fillStyle = colorInt
        ctx.lineWidth = stroke.size
        ctx.lineCap = "round"
        ctx.lineJoin = "round"
        ctx.globalAlpha = stroke.color.a

        // Draw the line body
        ctx.beginPath()
        let fp = stroke.points[0]
        ctx.moveTo(fp.x, fp.y)
        var i: Int64 = 1
        while (i < stroke.points.size) {
            let pt = stroke.points[i]
            ctx.lineTo(pt.x, pt.y)
            i += 1
        }
        ctx.stroke()

        // Draw arrowhead at the tip (filled triangle)
        let tip = stroke.points[stroke.points.size - 1]
        let angle = this.arrowHeadAngle(stroke)
        let headLen = stroke.size * 4.5
        let headAngle = 0.45

        let lx = tip.x - headLen * cos(angle - headAngle)
        let ly = tip.y - headLen * sin(angle - headAngle)
        let rx = tip.x - headLen * cos(angle + headAngle)
        let ry = tip.y - headLen * sin(angle + headAngle)

        ctx.beginPath()
        ctx.moveTo(tip.x, tip.y)
        ctx.lineTo(lx, ly)
        ctx.lineTo(rx, ry)
        ctx.closePath()
        ctx.fill()

        ctx.globalAlpha = 1.0
    }

    // Main dispatch for drawing a stroke based on tool type
    private func drawStroke(ctx: CanvasRenderingContext2D, stroke: DrawingStroke): Unit {
        if (stroke.points.size < 1) {
            return
        }
        let isNeon = stroke.tool == DrawingTool.Neon
        let isArrow = stroke.tool == DrawingTool.Arrow
        let isBlur = stroke.tool == DrawingTool.Blur
        let isEraser = stroke.tool == DrawingTool.Eraser
        let isMarker = stroke.tool == DrawingTool.Marker

        if (isNeon) {
            this.drawNeonStroke(ctx, stroke)
            return
        }
        if (isArrow) {
            this.drawArrowStroke(ctx, stroke)
            return
        }
        if (isBlur) {
            this.drawBlurStroke(ctx, stroke)
            return
        }

        ctx.beginPath()
        let firstPt = stroke.points[0]
        ctx.moveTo(firstPt.x, firstPt.y)
        var i: Int64 = 1
        while (i < stroke.points.size) {
            let pt = stroke.points[i]
            ctx.lineTo(pt.x, pt.y)
            i += 1
        }
        let colorInt = Int64(stroke.color.toUInt32ARGB())
        if (isEraser) {
            ctx.strokeStyle = 0xFF000000
            ctx.globalAlpha = 0.0
            ctx.lineWidth = stroke.size
        } else if (isMarker) {
            ctx.strokeStyle = colorInt
            ctx.lineWidth = stroke.size * 3.0
            ctx.globalAlpha = stroke.color.a * 0.65
        } else {
            ctx.strokeStyle = colorInt
            ctx.lineWidth = stroke.size
            ctx.globalAlpha = stroke.color.a
        }
        ctx.lineCap = "round"
        ctx.lineJoin = "round"
        ctx.stroke()
        ctx.globalAlpha = 1.0
    }

    // MARK: - Touch handling

    private func handleTouchDown(x: Float64, y: Float64): Unit {
        if (this.eyedropperActive) {
            this.sampleColorAt(x, y)
            return
        }
        let service = this.svc()
        let stroke = service.beginStroke(x, y)
        this.activeStroke = Some(stroke)
        this.redrawCanvas()
    }

    private func handleTouchMove(x: Float64, y: Float64): Unit {
        if (this.eyedropperActive) {
            return
        }
        match (this.activeStroke) {
            case Some(stroke) =>
                stroke.addPoint(x, y)
                this.redrawCanvas()
            case None => ()
        }
    }

    private func handleTouchUp(x: Float64, y: Float64): Unit {
        if (this.eyedropperActive) {
            this.eyedropperActive = false
            return
        }
        match (this.activeStroke) {
            case Some(stroke) =>
                stroke.addPoint(x, y)
                let service = this.svc()
                service.commitStroke(stroke)
                this.activeStroke = None
                let count = service.getStrokes().size
                this.strokeCount = count
                this.canUndo = service.canUndo()
                this.canRedo = service.canRedo()
                this.redrawCanvas()
            case None => ()
        }
    }

    // P2-082: eyedropper — use getImageData to read 1x1 pixel at touch position
    // getImageData(sx, sy, sw, sh): ImageData with data: Array<UInt8> [R,G,B,A, ...]
    private func sampleColorAt(x: Float64, y: Float64): Unit {
        let imgData = this.canvasContext.getImageData(x, y, 1.0, 1.0)
        let pixels = imgData.data
        if (pixels.size >= 4) {
            let r = Float64(pixels[0]) / 255.0
            let g = Float64(pixels[1]) / 255.0
            let b = Float64(pixels[2]) / 255.0
            let a = Float64(pixels[3]) / 255.0
            let pickedColor = DrawingColor(r, g, b, if (a < 0.05) { 1.0 } else { a })
            let service = this.svc()
            service.setCurrentColor(pickedColor)
            let newARGB = pickedColor.toUInt32ARGB()
            this.colorPreview = newARGB
        }
    }

    // MARK: - Undo / redo

    private func performUndo(): Unit {
        let service = this.svc()
        let _ = service.undo()
        let count = service.getStrokes().size
        this.strokeCount = count
        this.canUndo = service.canUndo()
        this.canRedo = service.canRedo()
        this.redrawCanvas()
    }

    private func performRedo(): Unit {
        let service = this.svc()
        let _ = service.redo()
        let count = service.getStrokes().size
        this.strokeCount = count
        this.canUndo = service.canUndo()
        this.canRedo = service.canRedo()
        this.redrawCanvas()
    }

    private func performClear(): Unit {
        let service = this.svc()
        service.clearAll()
        this.strokeCount = 0
        this.canUndo = service.canUndo()
        this.canRedo = service.canRedo()
        this.entityRevision += 1
        this.redrawCanvas()
    }

    private func hasAnyDrawingContent(): Bool {
        let _ = this.entityRevision
        return this.svc().hasContent()
    }

    // P2-088: flattenAndExport — export canvas strokes (+ optional base image) as PixelMap
    //
    // Calls DrawingFlattenService.flattenCanvas() with:
    //   - the live CanvasRenderingContext2D (fully drawn strokes)
    //   - actual canvas dimensions (set in onReady)
    //   - optional base PixelMap from DrawingService.getBasePixelMap()
    //
    // Result stored in DrawingFlattenService.lastResult for callers (DrawingScreen.onDone).
    // Returns Option<PixelMap> so callers can inspect success.
    public func flattenAndExport(storeResult!: Bool = true): Option<PixelMap> {
        let svc = this.svc()
        let flattenSvc = getDrawingFlattenService()
        let w = if (this.canvasActualW > 0.0) { this.canvasActualW } else { 375.0 }
        let h = if (this.canvasActualH > 0.0) { this.canvasActualH } else { 500.0 }
        svc.setCanvasDimensions(w, h)
        // 先导出透明笔迹层；底图合成由 DrawingScreen 在 Canvas 仍存活时按 BGRA
        // 像素完成。未挂载的离屏 Canvas 在部分设备上会返回整张黑图。
        let result = flattenSvc.flattenCanvas(this.canvasContext, w, h, None<PixelMap>)
        match (result) {
            case Some(pixelMap) =>
                if (storeResult) { flattenSvc.setLastResult(pixelMap) }
                Hilog.info(0, "CjTelegram", "[DrawingScreenComponent] flattenAndExport SUCCESS ${w}x${h}")
            case None =>
                Hilog.info(0, "CjTelegram", "[DrawingScreenComponent] flattenAndExport FAILED")
        }
        return result
    }

    // MARK: - Tool button highlight helper

    private func toolIsActive(ordinal: Int32): Bool {
        return this.currentToolIdx == ordinal
    }

    private func toolColor(ordinal: Int32): Int64 {
        return if (this.toolIsActive(ordinal)) { 0x007AFF } else { 0x8E8E93 }
    }

    // MARK: - Slider helpers (called from build context via private func, NOT let)

    private func sizeLabelText(): String {
        return "Size: ${Int64(this.sizeSlider)}"
    }

    private func opacityLabelText(): String {
        return "Opacity: ${Int64(this.opacitySlider)}%"
    }

    private func colorPreviewColor(): Int64 {
        return Int64(this.colorPreview & 0x00FFFFFF)
    }

    private func selectColor(argb: UInt32): Unit {
        this.svc().setCurrentColor(DrawingColor.fromARGB(argb))
        this.colorPreview = argb
    }

    private func finishDrawing(): Unit {
        if (!this.persistResult) {
            this.onDone()
            return
        }
        let flatten = getDrawingFlattenService()
        let service = this.svc()
        Hilog.info(0, "CjTelegram", "[DrawingScreenComponent] finish turns=${this.baseQuarterTurns} mirrored=${this.baseMirrored}")
        let w = if (this.canvasActualW > 0.0) { this.canvasActualW } else { 375.0 }
        let h = if (this.canvasActualH > 0.0) { this.canvasActualH } else { 500.0 }
        var requiresRasterMapping = !service.getTextOverlays().isEmpty() ||
            !service.getStickerOverlays().isEmpty() || !service.getShapeOverlays().isEmpty()
        if (!requiresRasterMapping) {
            for (stroke in service.getStrokes()) {
                if (stroke.tool != DrawingTool.Pen && stroke.tool != DrawingTool.Marker &&
                    stroke.tool != DrawingTool.Arrow) {
                    requiresRasterMapping = true
                }
            }
        }
        let canvasResult = if (requiresRasterMapping) { this.flattenAndExport(storeResult: false) } else { None<PixelMap> }
        let composed = match (service.getBasePixelMap()) {
            case Some(base) =>
                if (requiresRasterMapping) {
                    match (canvasResult) {
                        case Some(canvas) => flatten.renderCanvasOntoBase(base, canvas, w, h,
                            quarterTurns: this.baseQuarterTurns, mirrored: this.baseMirrored)
                        case None => None<PixelMap>
                    }
                } else {
                    flatten.renderStrokesOntoBase(base, service.getStrokes(), w, h, aspectFill: true,
                        quarterTurns: this.baseQuarterTurns, mirrored: this.baseMirrored)
                }
            case None => if (requiresRasterMapping) { canvasResult } else { this.flattenAndExport() }
        }
        match (composed) {
            case Some(pixelMap) =>
                flatten.setLastResult(pixelMap)
                let bytes = getImageCompressionService().compressPixelMapToJpeg(pixelMap, UInt8(94))
                let filesDir = getAppFilesDir()
                if (!bytes.isEmpty() && !filesDir.isEmpty()) {
                    let editDir = filesDir + "/avatar_edits"
                    try { FileIo.mkdir(editDir) } catch (_e: Exception) {}
                    let stamp = DateTime.now().toUnixTimeStamp().toSeconds()
                    let path = editDir + "/avatar_draw_${stamp}.jpg"
                    try {
                        let outFile = FileIo.open(path, mode: 0o1101)
                        FileIo.write(outFile.fd, bytes)
                        FileIo.close(outFile)
                        flatten.setLastResultPath("file://" + path)
                    } catch (_e: Exception) {}
                }
            case None => ()
        }
        this.onDone()
    }

    private func beginTextEntity(): Unit {
        let w = if (this.canvasActualW > 0.0) { this.canvasActualW } else { 375.0 }
        let h = if (this.canvasActualH > 0.0) { this.canvasActualH } else { 375.0 }
        this.textValue = ""
        this.svc().addTextOverlay(DrawingTextOverlay("", w / 2.0, h / 2.0, 34.0, DrawingColor.white))
        this.currentMode = "text"
        this.entityRevision += 1
    }

    private func updateTextEntity(value: String): Unit {
        this.textValue = value
        this.svc().updateLastText(value)
        this.entityRevision += 1
        this.redrawCanvas()
    }

    private func selectSticker(item: StickerItem): Unit {
        this.showStickerPicker = false
        let selected = item
        let _ = spawn {
            let path = ensureStickerLocalFile(selected)
            if (path.isEmpty()) { return }
            let isVideo = selected.mimeType.contains("webm")
            match (loadStickerStaticFrame(selected.documentId, path, isVideo, Int32(384), representative: true)) {
                case Some(frame) =>
                    launch {
                        let w = if (this.canvasActualW > 0.0) { this.canvasActualW } else { 375.0 }
                        let h = if (this.canvasActualH > 0.0) { this.canvasActualH } else { 375.0 }
                        let size = w * 0.42
                        this.svc().addStickerOverlay(DrawingStickerOverlay(frame, (w - size) / 2.0, (h - size) / 2.0, size))
                        this.currentMode = "sticker"
                        this.entityRevision += 1
                        this.redrawCanvas()
                    }
                case None => ()
            }
        }
    }

    private func selectShape(shapeType: Int64): Unit {
        let w = if (this.canvasActualW > 0.0) { this.canvasActualW } else { 375.0 }
        let h = if (this.canvasActualH > 0.0) { this.canvasActualH } else { 375.0 }
        this.svc().addShapeOverlay(DrawingShapeOverlay(shapeType, w / 2.0, h / 2.0, w * 0.42, this.svc().getCurrentColor()))
        this.showShapePicker = false
        this.currentMode = "draw"
        this.entityRevision += 1
        this.redrawCanvas()
    }

    @Builder
    func colorDot(argb: UInt32) {
        Circle()
            .width(26).height(26)
            .fill(Int64(argb & 0x00FFFFFF))
            .stroke(if (this.colorPreview == argb) { 0xFFFF3B30 } else { Color.Transparent })
            .strokeWidth(if (this.colorPreview == argb) { 3 } else { 0 })
            .onClick({ _ => this.selectColor(argb) })
    }

    func build() {
        Stack(alignContent: Alignment.Bottom) {
        Column {
            Row {
                Column {
                    Image(@r(app.media.avatar_draw_undo)).width(30).height(30)
                        .fillColor(if (this.canUndo) { 0xFFFFFFFF } else { 0xFF6A6A6E })
                }
                .width(48).height(48).borderRadius(24).backgroundColor(0xFF1C1C1E)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .enabled(this.canUndo).onClick({ _ => this.performUndo() })
                Blank()
                Button(trSource("Clear All"))
                    .fontSize(15).fontColor(if (this.hasAnyDrawingContent()) { 0xFFFFFFFF } else { 0xFF6A6A6E })
                    .height(44).borderRadius(22).backgroundColor(0xFF1C1C1E)
                    .enabled(this.hasAnyDrawingContent()).onClick({ _ => this.performClear() })
            }
            .width(100.percent).height(101).padding(left: 16, right: 16, top: 33)

            // DrawingScreen keeps its actions below the status bar and leaves a distinct
            // presentation gap before the circular canvas.
            Blank().height(39)

            Stack(alignContent: Alignment.Center) {
                Canvas(this.canvasContext)
                    .width(100.percent).height(100.percent).backgroundColor(Color.Transparent)
                    .borderRadius(1000).clip(true)
                    .onReady({ => this.redrawCanvas() })
                    .onAreaChange({ _: Area, newArea: Area =>
                        this.canvasActualW = newArea.width.value
                        this.canvasActualH = newArea.height.value
                        this.redrawCanvas()
                    })
                    .onTouch({ event: TouchEvent =>
                        if (event.touches.size > 0) {
                            let touch = event.touches[0]
                            match (event.eventType) {
                                case TouchType.Down => this.handleTouchDown(touch.x, touch.y)
                                case TouchType.Move => this.handleTouchMove(touch.x, touch.y)
                                case TouchType.Up => this.handleTouchUp(touch.x, touch.y)
                                case _ => ()
                            }
                        }
                    })

                // Only the slider itself may intercept canvas gestures.  A full-size Row with a
                // transparent Blank here prevents DrawingView from receiving most drag events.
                Slider(value: this.sizeSlider, min: 1.0, max: 60.0,
                    style: SliderStyle.OutSet, direction: Axis.Vertical, reverse: true)
                    .width(30).height(240)
                    .trackThickness(8)
                    .trackColor(0x663A3A3C)
                    .selectedColor(0x663A3A3C)
                    .blockColor(0xFFFFFFFF)
                    .position(x: 0, y: 100)
                    .onChange({ value: Float64, _: SliderChangeMode =>
                        this.sizeSlider = value
                        this.svc().setCurrentSize(value)
                    })

                if (this.currentMode == "text") {
                    TextInput(text: this.textValue, placeholder: "")
                        .id("avatar_drawing_text")
                        .width(76.percent).height(64)
                        .fontSize(28).fontColor(0xFFFFFFFF)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(Color.Transparent)
                        .onChange({ value: String => this.updateTextEntity(value) })
                        .onAppear({ => FocusControl.requestFocus("avatar_drawing_text") })
                }
            }
            .width(100.percent).aspectRatio(1.0)

            Blank()

            Row {
                Image(@r(app.media.avatar_tool_spectrum)).width(28).height(28)
                    .onClick({ _ => this.eyedropperActive = !this.eyedropperActive })
                Blank()
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.avatar_tool_pen)).width(40).height(132).objectFit(ImageFit.Fill)
                    Image(@r(app.media.avatar_tool_pen_tip_red)).width(40).height(132).objectFit(ImageFit.Fill)
                }.width(50).height(142).onClick({ _ => this.selectTool(DrawingTool.Pen) })
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.avatar_tool_arrow)).width(40).height(132).objectFit(ImageFit.Fill)
                    Image(@r(app.media.avatar_tool_arrow_tip_orange)).width(40).height(132).objectFit(ImageFit.Fill)
                }.width(50).height(142).onClick({ _ => this.selectTool(DrawingTool.Arrow) })
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.avatar_tool_marker)).width(40).height(132).objectFit(ImageFit.Fill)
                    Image(@r(app.media.avatar_tool_marker_tip_yellow)).width(40).height(132).objectFit(ImageFit.Fill)
                }.width(50).height(142).onClick({ _ => this.selectTool(DrawingTool.Marker) })
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.avatar_tool_neon)).width(40).height(132).objectFit(ImageFit.Fill)
                    Image(@r(app.media.avatar_tool_neon_tip_green)).width(40).height(132).objectFit(ImageFit.Fill)
                }.width(50).height(142).onClick({ _ => this.selectTool(DrawingTool.Neon) })
                Image(@r(app.media.avatar_tool_eraser)).width(40).height(132).objectFit(ImageFit.Fill)
                    .onClick({ _ => this.selectTool(DrawingTool.Eraser) })
                Blank()
                Image(@r(app.media.avatar_draw_add)).width(30).height(30)
                    .onClick({ _ =>
                        if (this.currentMode == "draw") {
                            this.showShapePicker = true
                        } else if (this.currentMode == "sticker") {
                            this.showStickerPicker = true
                        } else {
                            this.beginTextEntity()
                        }
                    })
            }
            .width(100.percent).height(144).padding(left: 16, right: 16).alignItems(VerticalAlign.Bottom)

            Row {
                this.colorDot(0xFFFF453A)
                this.colorDot(0xFFFF8A00)
                this.colorDot(0xFFFFD60A)
                this.colorDot(0xFF34C759)
                this.colorDot(0xFF5AC8FA)
                this.colorDot(0xFF0A84FF)
                this.colorDot(0xFFAF52DE)
                this.colorDot(0xFFFFFFFF)
            }
            .width(100.percent).height(38).justifyContent(FlexAlign.SpaceAround).padding(left: 14, right: 14)

            Row {
                Column {
                    Image(@r(app.media.avatar_draw_close)).width(30).height(30).fillColor(0xFFFFFFFF)
                }
                .width(44).height(44).borderRadius(22).backgroundColor(0xFF1C1C1E)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .onClick({ _ =>
                    this.svc().resetState()
                    this.onClose()
                })

                Blank()

                Row {
                    Text(trSource("Draw")).fontSize(15).fontColor(0xFFFFFFFF).fontWeight(FontWeight.Medium)
                        .width(78).height(44).textAlign(TextAlign.Center)
                        .backgroundColor(if (this.currentMode == "draw") { 0xFF48484A } else { Color.Transparent }).borderRadius(22)
                        .onClick({ _ => this.currentMode = "draw" })
                    Text(trSource("Sticker")).fontSize(15).fontColor(0xFFFFFFFF).fontWeight(FontWeight.Medium)
                        .width(78).height(44).textAlign(TextAlign.Center)
                        .backgroundColor(if (this.currentMode == "sticker") { 0xFF48484A } else { Color.Transparent }).borderRadius(22)
                        .onClick({ _ => this.showStickerPicker = true })
                    Text(trSource("Text")).fontSize(15).fontColor(0xFFFFFFFF).fontWeight(FontWeight.Medium)
                        .width(72).height(44).textAlign(TextAlign.Center)
                        .backgroundColor(if (this.currentMode == "text") { 0xFF48484A } else { Color.Transparent }).borderRadius(22)
                        .onClick({ _ => this.beginTextEntity() })
                }
                .height(44).borderRadius(22).backgroundColor(0xFF1C1C1E)

                Blank()

                Column {
                    Image(@r(app.media.avatar_editor_done)).width(30).height(30).fillColor(0xFFFFFFFF)
                }
                .width(44).height(44).borderRadius(22).backgroundColor(0xFF0A84FF)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .onClick({ _ => this.finishDrawing() })
            }
            .width(100.percent).height(60).padding(left: 14, right: 14, bottom: 8)
            .alignItems(VerticalAlign.Center)
        }
        .width(100.percent).height(100.percent).backgroundColor(0xFF000000)

        if (this.showStickerPicker) {
            Column {
                Column {}
                    .width(100.percent).layoutWeight(1).backgroundColor(0x99000000)
                    .onClick({ _ =>
                        this.showStickerPicker = false
                        this.currentMode = "draw"
                    })
                Column {
                    StickerKeyboardPanel(
                        contentHeightVp: 482.0,
                        onSelectSticker: { item: StickerItem => this.selectSticker(item) },
                        onClose: { =>
                            this.showStickerPicker = false
                            this.currentMode = "draw"
                        }
                    )
                }
                .width(100.percent).height(520).padding(top: 10).backgroundColor(0xFF1C1C1E)
                .borderRadius(topLeft: 16, topRight: 16)
            }.width(100.percent).height(100.percent)
        }

        if (this.showShapePicker) {
            Row {
                Blank()
                Column {
                    this.shapePickerRow(0, "Rectangle", @r(app.media.avatar_shape_rectangle_white))
                    this.shapePickerRow(1, "Ellipse", @r(app.media.avatar_shape_ellipse_white))
                    this.shapePickerRow(2, "Bubble", @r(app.media.avatar_shape_bubble_white))
                    this.shapePickerRow(3, "Star", @r(app.media.avatar_shape_star_white))
                    this.shapePickerRow(4, "Arrow", @r(app.media.avatar_shape_arrow_white))
                }
                .width(224).backgroundColor(0xF22C2C2E).borderRadius(14)
            }
            .width(100.percent).padding(right: 14, bottom: 112)
        }
        }
        .width(100.percent).height(100.percent)
    }

    @Builder
    func shapePickerRow(shapeType: Int64, label: String, icon: ResourceStr) {
        Row {
            Image(icon).width(28).height(28)
            Text(label).fontSize(16).fontColor(0xFFFFFFFF).margin(left: 12)
        }
        .width(100.percent).height(50).padding(left: 14, right: 14)
        .onClick({ _ => this.selectShape(shapeType) })
    }
}
