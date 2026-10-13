package ohos_app_cangjie_entry.services

import std.collection.ArrayList
import kit.PerformanceAnalysisKit.Hilog
import kit.ImageKit.PixelMap

// MARK: - Color model

public struct DrawingColor {
    public var r: Float64
    public var g: Float64
    public var b: Float64
    public var a: Float64

    public init(r: Float64, g: Float64, b: Float64, a: Float64) {
        this.r = r
        this.g = g
        this.b = b
        this.a = a
    }

    public static func fromARGB(argb: UInt32): DrawingColor {
        let a = Float64((argb >> 24) & 0xFF) / 255.0
        let r = Float64((argb >> 16) & 0xFF) / 255.0
        let g = Float64((argb >> 8) & 0xFF) / 255.0
        let b = Float64(argb & 0xFF) / 255.0
        return DrawingColor(r, g, b, a)
    }

    public static func fromRGB(rgb: UInt32): DrawingColor {
        let r = Float64((rgb >> 16) & 0xFF) / 255.0
        let g = Float64((rgb >> 8) & 0xFF) / 255.0
        let b = Float64(rgb & 0xFF) / 255.0
        return DrawingColor(r, g, b, 1.0)
    }

    public func toCSSString(): String {
        let ri = Int64(this.r * 255.0)
        let gi = Int64(this.g * 255.0)
        let bi = Int64(this.b * 255.0)
        return "rgba(${ri},${gi},${bi},${this.a})"
    }

    public func toUInt32ARGB(): UInt32 {
        let a8 = UInt32(this.a * 255.0) & 0xFF
        let r8 = UInt32(this.r * 255.0) & 0xFF
        let g8 = UInt32(this.g * 255.0) & 0xFF
        let b8 = UInt32(this.b * 255.0) & 0xFF
        return (a8 << 24) | (r8 << 16) | (g8 << 8) | b8
    }

    public static let white: DrawingColor = DrawingColor(1.0, 1.0, 1.0, 1.0)
    public static let black: DrawingColor = DrawingColor(0.0, 0.0, 0.0, 1.0)
}

// MARK: - Drawing tool enum
// R-112: enum used in @State comparison must be public and have operator==

public enum DrawingTool {
    | Pen
    | Marker
    | Neon
    | Eraser
    | Arrow
    | Blur

    public func ordinal(): Int32 {
        match (this) {
            case Pen => 0
            case Marker => 1
            case Neon => 2
            case Eraser => 3
            case Arrow => 4
            case Blur => 5
        }
    }

    public operator func ==(right: DrawingTool): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: DrawingTool): Bool {
        return this.ordinal() != right.ordinal()
    }
}

// MARK: - A single point on a stroke

public struct DrawingPoint {
    public var x: Float64
    public var y: Float64

    public init(x: Float64, y: Float64) {
        this.x = x
        this.y = y
    }
}

// MARK: - A complete stroke (sequence of points with style)

public class DrawingStroke {
    public var points: ArrayList<DrawingPoint>
    public var color: DrawingColor
    public var size: Float64
    public var tool: DrawingTool

    public init(color: DrawingColor, size: Float64, tool: DrawingTool) {
        this.points = ArrayList<DrawingPoint>()
        this.color = color
        this.size = size
        this.tool = tool
    }

    public func addPoint(x: Float64, y: Float64): Unit {
        this.points.add(DrawingPoint(x, y))
    }
}

/** Source DrawingTextEntity / DrawingStickerEntity 的目标侧可序列化等价物。 */
public class DrawingTextOverlay {
    public var text: String
    public var x: Float64
    public var y: Float64
    public var fontSize: Float64
    public var color: DrawingColor

    public init(text: String, x: Float64, y: Float64, fontSize: Float64, color: DrawingColor) {
        this.text = text
        this.x = x
        this.y = y
        this.fontSize = fontSize
        this.color = color
    }
}

public class DrawingStickerOverlay {
    public var image: PixelMap
    public var x: Float64
    public var y: Float64
    public var size: Float64

    public init(image: PixelMap, x: Float64, y: Float64, size: Float64) {
        this.image = image
        this.x = x
        this.y = y
        this.size = size
    }
}

public class DrawingShapeOverlay {
    public let shapeType: Int64
    public let x: Float64
    public let y: Float64
    public let size: Float64
    public let color: DrawingColor

    public init(shapeType: Int64, x: Float64, y: Float64, size: Float64, color: DrawingColor) {
        this.shapeType = shapeType
        this.x = x
        this.y = y
        this.size = size
        this.color = color
    }
}

// MARK: - DrawingState (owned by DrawingService, mutable)

public class DrawingState {
    public var strokes: ArrayList<DrawingStroke>
    public var textOverlays: ArrayList<DrawingTextOverlay>
    public var stickerOverlays: ArrayList<DrawingStickerOverlay>
    public var shapeOverlays: ArrayList<DrawingShapeOverlay>
    public var currentColor: DrawingColor
    public var currentSize: Float64
    public var currentTool: DrawingTool
    public var opacity: Float64

    public init() {
        this.strokes = ArrayList<DrawingStroke>()
        this.textOverlays = ArrayList<DrawingTextOverlay>()
        this.stickerOverlays = ArrayList<DrawingStickerOverlay>()
        this.shapeOverlays = ArrayList<DrawingShapeOverlay>()
        this.currentColor = DrawingColor(0.0, 0.0, 0.0, 1.0)
        this.currentSize = 6.0
        this.currentTool = DrawingTool.Pen
        this.opacity = 1.0
    }
}

// MARK: - Palette colors (migrated from iOS palleteColors array)

public let drawingPaletteColors: Array<UInt32> = [
    0xffffff, 0xebebeb, 0xd6d6d6, 0xc2c2c2, 0xadadad, 0x999999, 0x858585, 0x707070, 0x5c5c5c, 0x474747, 0x333333, 0x000000,
    0x00374a, 0x011d57, 0x11053b, 0x2e063d, 0x3c071b, 0x5c0701, 0x5a1c00, 0x583300, 0x563d00, 0x666100, 0x4f5504, 0x263e0f,
    0x004d65, 0x012f7b, 0x1a0a52, 0x450d59, 0x551029, 0x831100, 0x7b2900, 0x7a4a00, 0x785800, 0x8d8602, 0x6f760a, 0x38571a,
    0x016e8f, 0x0042a9, 0x2c0977, 0x61187c, 0x791a3d, 0xb51a00, 0xad3e00, 0xa96800, 0xa67b01, 0xc4bc00, 0x9ba50e, 0x4e7a27,
    0x008cb4, 0x0056d6, 0x371a94, 0x7a219e, 0x99244f, 0xe22400, 0xda5100, 0xd38301, 0xd19d01, 0xf5ec00, 0xc3d117, 0x669d34,
    0x00a1d8, 0x0061fe, 0x4d22b2, 0x982abc, 0xb92d5d, 0xff4015, 0xff6a00, 0xffab01, 0xfdc700, 0xfefb41, 0xd9ec37, 0x76bb40,
    0x01c7fc, 0x3a87fe, 0x5e30eb, 0xbe38f3, 0xe63b7a, 0xff6250, 0xff8648, 0xfeb43f, 0xfecb3e, 0xfff76b, 0xe4ef65, 0x96d35f,
    0x52d6fc, 0x74a7ff, 0x864ffe, 0xd357fe, 0xee719e, 0xff8c82, 0xffa57d, 0xffc777, 0xffd977, 0xfff994, 0xeaf28f, 0xb1dd8b,
    0x93e3fd, 0xa7c6ff, 0xb18cfe, 0xe292fe, 0xf4a4c0, 0xffb5af, 0xffc5ab, 0xffd9a8, 0xfee4a8, 0xfffbb9, 0xf2f7b7, 0xcde8b5,
    0xcbf0ff, 0xd3e2ff, 0xd9c9fe, 0xefcaff, 0xf9d3e0, 0xffdbd8, 0xffe2d6, 0xffecd4, 0xfff2d5, 0xfefcdd, 0xf7fadb, 0xdfeed4
]

// MARK: - DrawingService (local-state service, no MTProto)

private var _drawingServiceInstance: Option<DrawingService> = None

public func getDrawingService(): DrawingService {
    match (_drawingServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = DrawingService()
            _drawingServiceInstance = Some(inst)
            return inst
    }
}

public class DrawingService {
    private var state: DrawingState
    // P2-087: undo stack stores snapshots of the strokes list before each change
    // (snapshot-based to match existing test expectations for clearAll undo)
    private var undoStack: ArrayList<ArrayList<DrawingStroke>>
    // P2-087: redo stack — snapshots popped from undoStack by undo()
    private var redoStack: ArrayList<ArrayList<DrawingStroke>>
    // P2-088: base PixelMap (source image from MediaPicker) to flatten with strokes
    private var basePixelMap: Option<PixelMap> = None
    // P2-088: canvas dimensions for flatten export (set when drawing canvas is ready)
    private var canvasWidth: Float64 = 0.0
    private var canvasHeight: Float64 = 0.0

    public init() {
        this.state = DrawingState()
        this.undoStack = ArrayList<ArrayList<DrawingStroke>>()
        this.redoStack = ArrayList<ArrayList<DrawingStroke>>()
    }

    // MARK: - Internal snapshot helper

    private func snapshotStrokes(): ArrayList<DrawingStroke> {
        let snap = ArrayList<DrawingStroke>()
        for (s in this.state.strokes) {
            snap.add(s)
        }
        return snap
    }

    private func pushUndo(): Unit {
        let snap = this.snapshotStrokes()
        this.undoStack.add(snap)
        // Bound undo stack to 50 entries
        if (this.undoStack.size > 50) {
            let newStack = ArrayList<ArrayList<DrawingStroke>>()
            var i: Int64 = this.undoStack.size - 50
            while (i < this.undoStack.size) {
                newStack.add(this.undoStack[i])
                i += 1
            }
            this.undoStack = newStack
        }
    }

    // MARK: - State accessors

    public func getCurrentColor(): DrawingColor {
        return this.state.currentColor
    }

    public func setCurrentColor(color: DrawingColor): Unit {
        this.state.currentColor = color
    }

    public func getCurrentSize(): Float64 {
        return this.state.currentSize
    }

    public func setCurrentSize(size: Float64): Unit {
        this.state.currentSize = if (size < 1.0) { 1.0 } else if (size > 60.0) { 60.0 } else { size }
    }

    public func getCurrentTool(): DrawingTool {
        return this.state.currentTool
    }

    public func setCurrentTool(tool: DrawingTool): Unit {
        this.state.currentTool = tool
    }

    public func getOpacity(): Float64 {
        return this.state.opacity
    }

    public func setOpacity(opacity: Float64): Unit {
        this.state.opacity = if (opacity < 0.0) { 0.0 } else if (opacity > 1.0) { 1.0 } else { opacity }
    }

    public func getStrokes(): ArrayList<DrawingStroke> {
        return this.state.strokes
    }

    public func getTextOverlays(): ArrayList<DrawingTextOverlay> {
        return this.state.textOverlays
    }

    public func getStickerOverlays(): ArrayList<DrawingStickerOverlay> {
        return this.state.stickerOverlays
    }

    public func getShapeOverlays(): ArrayList<DrawingShapeOverlay> {
        return this.state.shapeOverlays
    }

    public func addTextOverlay(entity: DrawingTextOverlay): Unit {
        this.state.textOverlays.add(entity)
    }

    public func updateLastText(text: String): Unit {
        if (this.state.textOverlays.size > 0) {
            this.state.textOverlays[this.state.textOverlays.size - 1].text = text
        }
    }

    public func addStickerOverlay(entity: DrawingStickerOverlay): Unit {
        this.state.stickerOverlays.add(entity)
    }

    public func addShapeOverlay(entity: DrawingShapeOverlay): Unit {
        this.state.shapeOverlays.add(entity)
    }

    public func hasContent(): Bool {
        return this.state.strokes.size > 0 || this.state.textOverlays.size > 0 ||
            this.state.stickerOverlays.size > 0 || this.state.shapeOverlays.size > 0
    }

    // MARK: - Stroke management

    public func beginStroke(x: Float64, y: Float64): DrawingStroke {
        let stroke = DrawingStroke(
            this.state.currentColor,
            this.state.currentSize,
            this.state.currentTool
        )
        stroke.addPoint(x, y)
        return stroke
    }

    public func commitStroke(stroke: DrawingStroke): Unit {
        if (stroke.points.size == 0) {
            return
        }
        // Save snapshot before mutation; committing new stroke clears redo
        this.pushUndo()
        this.redoStack = ArrayList<ArrayList<DrawingStroke>>()
        this.state.strokes.add(stroke)
    }

    // P2-087: undo — restore previous snapshot, save current state to redoStack
    public func undo(): Bool {
        if (this.undoStack.size == 0) {
            return false
        }
        let lastIdx = this.undoStack.size - 1
        let snapshot = this.undoStack[lastIdx]
        // Save current state to redoStack
        this.redoStack.add(this.snapshotStrokes())
        // Remove last entry from undoStack
        let newStack = ArrayList<ArrayList<DrawingStroke>>()
        var i: Int64 = 0
        while (i < lastIdx) {
            newStack.add(this.undoStack[i])
            i += 1
        }
        this.undoStack = newStack
        // Restore snapshot
        this.state.strokes = snapshot
        return true
    }

    // P2-087: redo — reapply a state that was undone
    public func redo(): Bool {
        if (this.redoStack.size == 0) {
            return false
        }
        let lastIdx = this.redoStack.size - 1
        let snapshot = this.redoStack[lastIdx]
        // Save current state to undoStack
        this.undoStack.add(this.snapshotStrokes())
        // Remove last entry from redoStack
        let newRedo = ArrayList<ArrayList<DrawingStroke>>()
        var i: Int64 = 0
        while (i < lastIdx) {
            newRedo.add(this.redoStack[i])
            i += 1
        }
        this.redoStack = newRedo
        // Restore snapshot
        this.state.strokes = snapshot
        return true
    }

    public func canUndo(): Bool {
        return this.undoStack.size > 0
    }

    // P2-087: canRedo for UI button enable state
    public func canRedo(): Bool {
        return this.redoStack.size > 0
    }

    public func clearAll(): Unit {
        this.pushUndo()
        this.redoStack = ArrayList<ArrayList<DrawingStroke>>()
        this.state.strokes = ArrayList<DrawingStroke>()
        this.state.textOverlays = ArrayList<DrawingTextOverlay>()
        this.state.stickerOverlays = ArrayList<DrawingStickerOverlay>()
        this.state.shapeOverlays = ArrayList<DrawingShapeOverlay>()
    }

    // MARK: - Color picker helpers

    public func selectPaletteColor(index: Int64): Unit {
        if (index < 0 || index >= Int64(drawingPaletteColors.size)) {
            return
        }
        let rgb = drawingPaletteColors[index]
        let color = DrawingColor.fromRGB(rgb)
        let withAlpha = DrawingColor(
            color.r,
            color.g,
            color.b,
            this.state.opacity
        )
        this.state.currentColor = withAlpha
    }

    public func resetState(): Unit {
        this.state = DrawingState()
        this.undoStack = ArrayList<ArrayList<DrawingStroke>>()
        this.redoStack = ArrayList<ArrayList<DrawingStroke>>()
        this.basePixelMap = None
        this.canvasWidth = 0.0
        this.canvasHeight = 0.0
    }

    // P2-088: base PixelMap accessors (source image to merge with strokes)
    public func setBasePixelMap(pm: PixelMap): Unit {
        this.basePixelMap = Some(pm)
    }

    public func getBasePixelMap(): Option<PixelMap> {
        return this.basePixelMap
    }

    public func clearBasePixelMap(): Unit {
        this.basePixelMap = None
    }

    // P2-088: canvas dimensions for flatten export
    public func setCanvasDimensions(w: Float64, h: Float64): Unit {
        this.canvasWidth = w
        this.canvasHeight = h
    }

    public func getCanvasWidth(): Float64 {
        return this.canvasWidth
    }

    public func getCanvasHeight(): Float64 {
        return this.canvasHeight
    }
}
