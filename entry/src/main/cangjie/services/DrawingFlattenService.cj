package ohos_app_cangjie_entry.services

import kit.ArkUI.*
import kit.ImageKit.{PixelMap, InitializationOptions, createPixelMap, PixelMapFormat, AlphaType}
import kit.ImageKit.Size as DrawingImageSize
import kit.PerformanceAnalysisKit.Hilog
import ohos.business_exception.BusinessException
import std.collection.ArrayList
import std.math.*

// DrawingFlattenService — P2-088: 绘图涂鸦结果烧录 (flatten) 服务
//
// iOS 对应：DrawingUI/Sources/DrawingScreen.swift completionAction — 把 entities + strokes
//           烧录回底图（UIImage → CGContext.draw → UIGraphicsGetImageFromCurrentImageContext）
//
// HarmonyOS 方案：
//   1. 获取已经在 DrawingScreenComponent Canvas 上绘制好的内容（getPixelMap）
//   2. 若有底图（base PixelMap），用离屏 CanvasRenderingContext2D 先 drawImage 底图，
//      再 drawImage 涂鸦层（作为叠加），最终 getPixelMap 产出合成图
//   3. 结果存入 DrawingService.lastFlattenedPixelMap 供发送侧读取
//
// 关键 API（KB 验证）：
//   - CanvasRenderingContext2D.drawImage(image: PixelMap, dx, dy, dw, dh)
//   - CanvasRenderingContext2D.getPixelMap(sx, sy, sw, sh): PixelMap
//   - 以上均在 kit.ArkUI.*（CanvasRenderingContext2D 绑定）

private var _drawingFlattenServiceInstance: Option<DrawingFlattenService> = None

public func getDrawingFlattenService(): DrawingFlattenService {
    match (_drawingFlattenServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = DrawingFlattenService()
            _drawingFlattenServiceInstance = Some(inst)
            return inst
    }
}

/** Copy tightly packed BGRA rows into ImageKit storage using the source stride explicitly. */
private func createDrawingPixelMap(pixels: Array<UInt8>, width: Int64, height: Int64): PixelMap {
    let pixelMap = createPixelMap(Array<UInt8>(width * height * 4, repeat: 0), InitializationOptions(
        DrawingImageSize(Int32(width), Int32(height)), editable: true,
        srcPixelFormat: PixelMapFormat.Bgra8888, pixelFormat: PixelMapFormat.Bgra8888,
        alphaType: AlphaType.Premul
    ))
    let rowBytes = width * 4
    var destinationStride = Int64(pixelMap.getImageInfo().stride)
    if (destinationStride < rowBytes) { destinationStride = rowBytes }
    let padded = Array<UInt8>(destinationStride * height, repeat: 0)
    var y: Int64 = 0
    while (y < height) {
        var byteIndex: Int64 = 0
        while (byteIndex < rowBytes) {
            padded[y * destinationStride + byteIndex] = pixels[y * rowBytes + byteIndex]
            byteIndex += 1
        }
        y += 1
    }
    pixelMap.writeBufferToPixels(padded)
    return pixelMap
}

private func drawingPointToBase(
    point: DrawingPoint, bw: Int64, bh: Int64, scale: Float64,
    offsetX: Float64, offsetY: Float64, turns: Int64, mirrored: Bool
): Array<Float64> {
    let rotatedX = (point.x - offsetX) / scale
    let rotatedY = (point.y - offsetY) / scale
    var mappedX = rotatedX
    var mappedY = rotatedY
    if (turns == 1) {
        mappedX = Float64(bw - 1) - rotatedY; mappedY = rotatedX
    } else if (turns == 2) {
        mappedX = Float64(bw - 1) - rotatedX; mappedY = Float64(bh - 1) - rotatedY
    } else if (turns == 3) {
        mappedX = rotatedY; mappedY = Float64(bh - 1) - rotatedX
    }
    if (mirrored) { mappedX = Float64(bw - 1) - mappedX }
    return [mappedX, mappedY]
}

private func drawDrawingSegment(
    pixels: Array<UInt8>, bw: Int64, bh: Int64,
    x0: Float64, y0: Float64, x1: Float64, y1: Float64,
    radius: Int64, blue: Int64, green: Int64, red: Int64, alpha: Int64
): Unit {
    let dx = x1 - x0
    let dy = y1 - y0
    let absDx = if (dx < 0.0) { -dx } else { dx }
    let absDy = if (dy < 0.0) { -dy } else { dy }
    let length = if (absDx > absDy) { absDx } else { absDy }
    let steps = if (length < 1.0) { Int64(1) } else { Int64(length) }
    var step: Int64 = 0
    while (step <= steps) {
        let t = Float64(step) / Float64(steps)
        let cx = Int64(x0 + dx * t)
        let cy = Int64(y0 + dy * t)
        var py = cy - radius
        while (py <= cy + radius) {
            var px = cx - radius
            while (px <= cx + radius) {
                let rx = px - cx
                let ry = py - cy
                if (px >= 0 && px < bw && py >= 0 && py < bh && rx * rx + ry * ry <= radius * radius) {
                    let offset = (py * bw + px) * 4
                    let inverse = 255 - alpha
                    pixels[offset] = UInt8((blue * alpha + Int64(pixels[offset]) * inverse) / 255)
                    pixels[offset + 1] = UInt8((green * alpha + Int64(pixels[offset + 1]) * inverse) / 255)
                    pixels[offset + 2] = UInt8((red * alpha + Int64(pixels[offset + 2]) * inverse) / 255)
                }
                px += 1
            }
            py += 1
        }
        step += 1
    }
}

public class DrawingFlattenService {

    // 上一次离屏合成结果（可选）
    private var lastResult: Option<PixelMap> = None
    private var lastResultPath: String = ""

    // P2-088: registered flatten callback (set by DrawingScreenComponent.aboutToAppear)
    // Called by DrawingScreen Done button to trigger flatten before pop
    private var flattenCallback: Option<() -> Unit> = None

    public init() {}

    // Register the flatten callback from DrawingScreenComponent
    public func registerFlattenCallback(cb: () -> Unit): Unit {
        this.flattenCallback = Some(cb)
    }

    // Unregister when component disappears
    public func unregisterFlattenCallback(): Unit {
        this.flattenCallback = None
    }

    // Invoke the registered callback (called from DrawingScreen Done button)
    public func invokeFlattenCallback(): Unit {
        match (this.flattenCallback) {
            case Some(cb) => cb()
            case None => Hilog.info(0, "CjTelegram", "[DrawingFlattenService] no flatten callback registered")
        }
    }

    // MARK: - 存储/读取合成结果

    public func setLastResult(pm: PixelMap): Unit {
        this.lastResult = Some(pm)
    }

    public func getLastResult(): Option<PixelMap> {
        return this.lastResult
    }

    public func clearLastResult(): Unit {
        this.lastResult = None
        this.lastResultPath = ""
    }

    public func setLastResultPath(path: String): Unit {
        this.lastResultPath = path
    }

    public func getLastResultPath(): String {
        return this.lastResultPath
    }

    /** 按编辑预览的 ImageFit.Contain 坐标，把 DrawingService 的向量笔迹栅格化到底图。 */
    public func renderStrokesOntoBase(
        base: PixelMap,
        strokes: ArrayList<DrawingStroke>,
        canvasW: Float64,
        canvasH: Float64,
        aspectFill!: Bool = false,
        quarterTurns!: Int64 = 0,
        mirrored!: Bool = false
    ): Option<PixelMap> {
        try {
            let baseInfo = base.getImageInfo()
            let bw = Int64(baseInfo.size.width)
            let bh = Int64(baseInfo.size.height)
            if (bw <= 0 || bh <= 0 || canvasW <= 0.0 || canvasH <= 0.0) { return None }

            let raw = Array<UInt8>(Int64(base.getPixelBytesNumber()), repeat: 0)
            base.readPixelsToBuffer(raw)
            let rowBytes = bw * 4
            var sourceStride = if (raw.size == rowBytes * bh) { rowBytes } else { Int64(baseInfo.stride) }
            if (sourceStride < rowBytes || sourceStride * bh > raw.size) { sourceStride = rowBytes }
            let baseBuf = Array<UInt8>(rowBytes * bh, repeat: 0)
            var copyY: Int64 = 0
            while (copyY < bh) {
                var copyByte: Int64 = 0
                while (copyByte < rowBytes) {
                    baseBuf[copyY * rowBytes + copyByte] = raw[copyY * sourceStride + copyByte]
                    copyByte += 1
                }
                copyY += 1
            }

            let turns = ((quarterTurns % 4) + 4) % 4
            let effectiveW = if (turns % 2 == 0) { Float64(bw) } else { Float64(bh) }
            let effectiveH = if (turns % 2 == 0) { Float64(bh) } else { Float64(bw) }
            let scaleX = canvasW / effectiveW
            let scaleY = canvasH / effectiveH
            let scale = if (aspectFill) {
                if (scaleX > scaleY) { scaleX } else { scaleY }
            } else {
                if (scaleX < scaleY) { scaleX } else { scaleY }
            }
            let offsetX = (canvasW - effectiveW * scale) / 2.0
            let offsetY = (canvasH - effectiveH * scale) / 2.0

            for (stroke in strokes) {
                if (stroke.points.isEmpty() || stroke.tool == DrawingTool.Blur || stroke.tool == DrawingTool.Eraser) {
                    continue
                }
                let radius = if (stroke.size / scale < 1.0) { Int64(1) } else { Int64(stroke.size / scale / 2.0) }
                let blue = Int64(stroke.color.b * 255.0)
                let green = Int64(stroke.color.g * 255.0)
                let red = Int64(stroke.color.r * 255.0)
                var alpha = Int64(stroke.color.a * 255.0)
                if (stroke.tool == DrawingTool.Marker) { alpha = alpha * 65 / 100 }

                var pointIndex: Int64 = 0
                while (pointIndex < stroke.points.size) {
                    let current = stroke.points[pointIndex]
                    let previous = if (pointIndex == 0) { current } else { stroke.points[pointIndex - 1] }
                    let rotatedX0 = (previous.x - offsetX) / scale
                    let rotatedY0 = (previous.y - offsetY) / scale
                    let rotatedX1 = (current.x - offsetX) / scale
                    let rotatedY1 = (current.y - offsetY) / scale
                    var mirroredX0 = rotatedX0
                    var y0 = rotatedY0
                    var mirroredX1 = rotatedX1
                    var y1 = rotatedY1
                    if (turns == 1) {
                        mirroredX0 = Float64(bw - 1) - rotatedY0; y0 = rotatedX0
                        mirroredX1 = Float64(bw - 1) - rotatedY1; y1 = rotatedX1
                    } else if (turns == 2) {
                        mirroredX0 = Float64(bw - 1) - rotatedX0; y0 = Float64(bh - 1) - rotatedY0
                        mirroredX1 = Float64(bw - 1) - rotatedX1; y1 = Float64(bh - 1) - rotatedY1
                    } else if (turns == 3) {
                        mirroredX0 = rotatedY0; y0 = Float64(bh - 1) - rotatedX0
                        mirroredX1 = rotatedY1; y1 = Float64(bh - 1) - rotatedX1
                    }
                    let x0 = if (mirrored) { Float64(bw - 1) - mirroredX0 } else { mirroredX0 }
                    let x1 = if (mirrored) { Float64(bw - 1) - mirroredX1 } else { mirroredX1 }
                    let dx = x1 - x0
                    let dy = y1 - y0
                    let absDx = if (dx < 0.0) { -dx } else { dx }
                    let absDy = if (dy < 0.0) { -dy } else { dy }
                    let length = if (absDx > absDy) { absDx } else { absDy }
                    let steps = if (length < 1.0) { Int64(1) } else { Int64(length) }
                    var step: Int64 = 0
                    while (step <= steps) {
                        let t = Float64(step) / Float64(steps)
                        let cx = Int64(x0 + dx * t)
                        let cy = Int64(y0 + dy * t)
                        var py = cy - radius
                        while (py <= cy + radius) {
                            var px = cx - radius
                            while (px <= cx + radius) {
                                let rx = px - cx
                                let ry = py - cy
                                if (px >= 0 && px < bw && py >= 0 && py < bh && rx * rx + ry * ry <= radius * radius) {
                                    let offset = (py * bw + px) * 4
                                    let inverse = 255 - alpha
                                    baseBuf[offset] = UInt8((blue * alpha + Int64(baseBuf[offset]) * inverse) / 255)
                                    baseBuf[offset + 1] = UInt8((green * alpha + Int64(baseBuf[offset + 1]) * inverse) / 255)
                                    baseBuf[offset + 2] = UInt8((red * alpha + Int64(baseBuf[offset + 2]) * inverse) / 255)
                                }
                                px = px + 1
                            }
                            py = py + 1
                        }
                        step = step + 1
                    }
                    if (stroke.tool == DrawingTool.Arrow && stroke.points.size >= 2 &&
                        pointIndex == stroke.points.size - 1) {
                        let tipPoint = stroke.points[stroke.points.size - 1]
                        var previousIndex = stroke.points.size - 2
                        while (previousIndex > 0) {
                            let candidate = stroke.points[previousIndex]
                            let screenDx = tipPoint.x - candidate.x
                            let screenDy = tipPoint.y - candidate.y
                            if (sqrt(screenDx * screenDx + screenDy * screenDy) > stroke.size * 2.0) { break }
                            previousIndex -= 1
                        }
                        let tip = drawingPointToBase(tipPoint, bw, bh, scale, offsetX, offsetY, turns, mirrored)
                        let previous = drawingPointToBase(stroke.points[previousIndex], bw, bh, scale,
                            offsetX, offsetY, turns, mirrored)
                        let angle = atan2(tip[1] - previous[1], tip[0] - previous[0])
                        let headLength = stroke.size / scale * 4.5
                        var side: Int64 = 0
                        while (side < 2) {
                            let headAngle = if (side == 0) { angle - 0.45 } else { angle + 0.45 }
                            let endX = tip[0] - headLength * cos(headAngle)
                            let endY = tip[1] - headLength * sin(headAngle)
                            drawDrawingSegment(baseBuf, bw, bh, tip[0], tip[1], endX, endY,
                                radius, blue, green, red, alpha)
                            side += 1
                        }
                    }
                    pointIndex = pointIndex + 1
                }
            }
            return Some(createDrawingPixelMap(baseBuf, bw, bh))
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[DrawingFlattenService] vector render failed: ${e.message}")
            return None
        }
    }

    /** Map the drawing screen's circular raster preview back into the complete aspect-filled source. */
    public func renderCanvasOntoBase(
        base: PixelMap,
        canvas: PixelMap,
        canvasW: Float64,
        canvasH: Float64,
        quarterTurns!: Int64 = 0,
        mirrored!: Bool = false
    ): Option<PixelMap> {
        try {
            let baseInfo = base.getImageInfo()
            let canvasInfo = canvas.getImageInfo()
            let bw = Int64(baseInfo.size.width)
            let bh = Int64(baseInfo.size.height)
            let cw = Int64(canvasInfo.size.width)
            let ch = Int64(canvasInfo.size.height)
            Hilog.info(0, "CjTelegram", "[DrawingFlattenService] canvas mapping base=${bw}x${bh} canvas=${cw}x${ch} logical=${canvasW}x${canvasH} turns=${quarterTurns} mirrored=${mirrored}")
            if (bw <= 0 || bh <= 0 || cw <= 0 || ch <= 0 || canvasW <= 0.0 || canvasH <= 0.0) {
                return None
            }

            let baseRaw = Array<UInt8>(Int64(base.getPixelBytesNumber()), repeat: 0)
            base.readPixelsToBuffer(baseRaw)
            let baseRowBytes = bw * 4
            var baseStride = if (baseRaw.size == baseRowBytes * bh) { baseRowBytes } else { Int64(baseInfo.stride) }
            if (baseStride < baseRowBytes || baseStride * bh > baseRaw.size) { baseStride = baseRowBytes }
            let output = Array<UInt8>(baseRowBytes * bh, repeat: 0)
            var y: Int64 = 0
            while (y < bh) {
                var byteIndex: Int64 = 0
                while (byteIndex < baseRowBytes) {
                    output[y * baseRowBytes + byteIndex] = baseRaw[y * baseStride + byteIndex]
                    byteIndex += 1
                }
                y += 1
            }

            let canvasRaw = Array<UInt8>(Int64(canvas.getPixelBytesNumber()), repeat: 0)
            canvas.readPixelsToBuffer(canvasRaw)
            let canvasRowBytes = cw * 4
            var canvasStride = if (canvasRaw.size == canvasRowBytes * ch) { canvasRowBytes } else { Int64(canvasInfo.stride) }
            if (canvasStride < canvasRowBytes || canvasStride * ch > canvasRaw.size) { canvasStride = canvasRowBytes }

            let turns = ((quarterTurns % 4) + 4) % 4
            let effectiveW = if (turns % 2 == 0) { Float64(bw) } else { Float64(bh) }
            let effectiveH = if (turns % 2 == 0) { Float64(bh) } else { Float64(bw) }
            let scaleX = canvasW / effectiveW
            let scaleY = canvasH / effectiveH
            let scale = if (scaleX > scaleY) { scaleX } else { scaleY }
            let offsetX = (canvasW - effectiveW * scale) / 2.0
            let offsetY = (canvasH - effectiveH * scale) / 2.0
            let centerX = canvasW * 0.5
            let centerY = canvasH * 0.5
            let radius = min(canvasW, canvasH) * 0.5
            let radiusSquared = radius * radius
            y = 0
            while (y < bh) {
                var x: Int64 = 0
                while (x < bw) {
                    let sourceX = if (mirrored) { Float64(bw) - Float64(x) - 0.5 } else { Float64(x) + 0.5 }
                    let sourceY = Float64(y) + 0.5
                    var rotatedX = sourceX
                    var rotatedY = sourceY
                    if (turns == 1) {
                        rotatedX = sourceY; rotatedY = Float64(bw) - sourceX
                    } else if (turns == 2) {
                        rotatedX = Float64(bw) - sourceX; rotatedY = Float64(bh) - sourceY
                    } else if (turns == 3) {
                        rotatedX = Float64(bh) - sourceY; rotatedY = sourceX
                    }
                    let logicalX = rotatedX * scale + offsetX
                    let logicalY = rotatedY * scale + offsetY
                    let dx = logicalX - centerX
                    let dy = logicalY - centerY
                    if (logicalX >= 0.0 && logicalX < canvasW && logicalY >= 0.0 && logicalY < canvasH &&
                        dx * dx + dy * dy <= radiusSquared) {
                        var sampleX = Int64(logicalX * Float64(cw) / canvasW)
                        var sampleY = Int64(logicalY * Float64(ch) / canvasH)
                        if (sampleX < 0) { sampleX = 0 }
                        if (sampleY < 0) { sampleY = 0 }
                        if (sampleX >= cw) { sampleX = cw - 1 }
                        if (sampleY >= ch) { sampleY = ch - 1 }
                        let sourceOffset = sampleY * canvasStride + sampleX * 4
                        let destinationOffset = (y * bw + x) * 4
                        output[destinationOffset] = canvasRaw[sourceOffset]
                        output[destinationOffset + 1] = canvasRaw[sourceOffset + 1]
                        output[destinationOffset + 2] = canvasRaw[sourceOffset + 2]
                        output[destinationOffset + 3] = canvasRaw[sourceOffset + 3]
                    }
                    x += 1
                }
                y += 1
            }
            return Some(createDrawingPixelMap(output, bw, bh))
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[DrawingFlattenService] canvas mapping failed: ${e.message}")
            return None
        }
    }

    // MARK: - 离屏合成：底图 + 涂鸦层 → PixelMap
    //
    // 调用方：DrawingScreenComponent.flattenAndExport()（在 Canvas.onReady 后触发）
    // 参数：
    //   ctx    — 持有已绘制涂鸦笔触的 CanvasRenderingContext2D（画布已完成绘制）
    //   canvasW — Canvas 宽度（vp，Float64）
    //   canvasH — Canvas 高度（vp，Float64）
    //   basePixelMap — 可选底图（来自 MediaPickerScreen 选中资产）
    // 返回：合成后的 PixelMap（底图 + 涂鸦叠加），失败时返回 None
    //
    // 内部逻辑：
    //   A. 若无底图：直接 ctx.getPixelMap(0, 0, canvasW, canvasH) → 返回纯涂鸦 PixelMap
    //   B. 若有底图：
    //      1. 创建离屏 CanvasRenderingContext2D（RenderingContextSettings with antialias=true）
    //      2. 在离屏画布上 drawImage(basePixelMap, 0, 0, canvasW, canvasH)  ← 底图
    //      3. 再 drawImage(strokesPixelMap, 0, 0, canvasW, canvasH)         ← 涂鸦叠加
    //      4. 离屏 getPixelMap(0, 0, canvasW, canvasH) → 合成结果
    //
    // 注意：getPixelMap 是同步 API，需要在 Canvas onReady 完成后调用（绑定阶段已完成渲染）。
    public func flattenCanvas(
        ctx: CanvasRenderingContext2D,
        canvasW: Float64,
        canvasH: Float64,
        basePixelMap: Option<PixelMap>
    ): Option<PixelMap> {
        if (canvasW <= 0.0 || canvasH <= 0.0) {
            Hilog.info(0, "CjTelegram", "[DrawingFlattenService] invalid canvas size")
            return None
        }

        try {
            // A. 获取涂鸦层 PixelMap（仅涂鸦，无底图）
            let strokesPixelMap = ctx.getPixelMap(0.0, 0.0, canvasW, canvasH)

            match (basePixelMap) {
                case None =>
                    // 无底图：直接返回纯涂鸦内容
                    Hilog.info(0, "CjTelegram", "[DrawingFlattenService] flatten strokes-only ${canvasW}x${canvasH}")
                    return Some(strokesPixelMap)

                case Some(base) =>
                    // B. 有底图：离屏合成
                    let offscreenCtx = CanvasRenderingContext2D(
                        RenderingContextSettings(antialias: true)
                    )
                    // 与编辑页 ImageFit.Contain 使用同一缩放和居中规则，避免导出时
                    // 把底图强行拉伸到整张画布，随后再裁剪造成二次变形。
                    let info = base.getImageInfo()
                    let sourceW = Float64(info.size.width)
                    let sourceH = Float64(info.size.height)
                    if (sourceW <= 0.0 || sourceH <= 0.0) {
                        Hilog.info(0, "CjTelegram", "[DrawingFlattenService] invalid base image size")
                        return None
                    }
                    let scaleX = canvasW / sourceW
                    let scaleY = canvasH / sourceH
                    let scale = if (scaleX < scaleY) { scaleX } else { scaleY }
                    let drawW = sourceW * scale
                    let drawH = sourceH * scale
                    offscreenCtx.drawImage(
                        base,
                        (canvasW - drawW) / 2.0,
                        (canvasH - drawH) / 2.0,
                        drawW,
                        drawH
                    )
                    // 叠加涂鸦
                    offscreenCtx.drawImage(strokesPixelMap, 0.0, 0.0, canvasW, canvasH)
                    // 导出合成结果
                    let composed = offscreenCtx.getPixelMap(0.0, 0.0, canvasW, canvasH)
                    Hilog.info(0, "CjTelegram", "[DrawingFlattenService] flatten base+strokes ${canvasW}x${canvasH}")
                    return Some(composed)
            }
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[DrawingFlattenService] flattenCanvas error: ${e.message}")
            return None
        }
    }
}
