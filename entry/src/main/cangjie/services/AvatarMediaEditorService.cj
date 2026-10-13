package ohos_app_cangjie_entry.services

import kit.ImageKit.{PixelMap, InitializationOptions, Size, Region, createPixelMap, PixelMapFormat, AlphaType,
    createImagePacker, PackingOption, createImageSource, SourceOptions, DecodingOptions}
import ohos.business_exception.BusinessException
import kit.PerformanceAnalysisKit.Hilog
import std.math.*
import ohos_app_cangjie_entry.bindings.getImageBlurBinding

/** 与源端 MediaEditorValues 中头像编辑会使用的工具值一一对应。 */
public class AvatarMediaToolValues {
    public var enhance: Float64 = 0.0
    public var brightness: Float64 = 0.0
    public var contrast: Float64 = 0.0
    public var saturation: Float64 = 0.0
    public var warmth: Float64 = 0.0
    public var fade: Float64 = 0.0
    public var highlights: Float64 = 0.0
    public var shadows: Float64 = 0.0
    public var grain: Float64 = 0.0
    public var vignette: Float64 = 0.0
    public var shadowsTintIntensity: Float64 = 0.0
    public var highlightsTintIntensity: Float64 = 0.0
    public var shadowsTintColor: Int64 = 0
    public var highlightsTintColor: Int64 = 0
    public var blurMode: Int64 = 0
    public var blurIntensity: Float64 = 0.5
    public var blurPositionX: Float64 = 0.5
    public var blurPositionY: Float64 = 0.5
    public var blurSize: Float64 = 0.24
    public var blurFalloff: Float64 = 0.12
    public var blurRotation: Float64 = 0.0
    public var curves: Array<Float64> = Array<Float64>(20, { index: Int64 =>
        let field = index % 5
        if (field == 0) { 0.0 } else if (field == 1) { 0.25 } else if (field == 2) { 0.5 } else if (field == 3) { 0.75 } else { 1.0 }
    })
}

/** Remove ImageKit's aligned row padding while preserving the source pixel format. */
private func readAvatarPixels(source: PixelMap, width: Int64, height: Int64): Array<UInt8> {
    let info = source.getImageInfo()
    let raw = Array<UInt8>(Int64(source.getPixelBytesNumber()), repeat: 0)
    source.readPixelsToBuffer(raw)
    let rowBytes = width * 4
    if (raw.size == rowBytes * height) { return raw }
    var sourceStride = Int64(info.stride)
    if (sourceStride < rowBytes) { sourceStride = rowBytes }
    let pixels = Array<UInt8>(rowBytes * height, repeat: 0)
    var y: Int64 = 0
    while (y < height) {
        var byteIndex: Int64 = 0
        while (byteIndex < rowBytes) {
            pixels[y * rowBytes + byteIndex] = raw[y * sourceStride + byteIndex]
            byteIndex += 1
        }
        y += 1
    }
    return pixels
}

/** Convert gallery RGBA/BGRA PixelMaps to the editor's single tightly packed BGRA format. */
public func normalizeAvatarPixelMap(source: PixelMap): PixelMap {
    let packer = createImagePacker()
    let encoded = packer.packToData(source, PackingOption("image/png", UInt8(100)))
    packer.release()
    let imageSource = createImageSource(encoded, SourceOptions(0))
    let decoded = imageSource.createPixelMap(options: DecodingOptions(
        editable: true, desiredPixelFormat: PixelMapFormat.Bgra8888
    ))
    imageSource.release()
    return decoded
}

/** Apply the crop-state orientation to the complete source before a sub-editor consumes it. */
public func renderAvatarSourceOrientation(
    source: PixelMap,
    quarterTurns: Int64,
    mirrored: Bool
): Option<PixelMap> {
    try {
        let normalized = normalizeAvatarPixelMap(source)
        let info = normalized.getImageInfo()
        let width = Int64(info.size.width)
        let height = Int64(info.size.height)
        if (width <= 0 || height <= 0) { return None }
        let sourcePixels = readAvatarPixels(normalized, width, height)
        let turns = ((quarterTurns % 4) + 4) % 4
        let destinationWidth = if (turns % 2 == 0) { width } else { height }
        let destinationHeight = if (turns % 2 == 0) { height } else { width }
        let destinationPixels = Array<UInt8>(destinationWidth * destinationHeight * 4, repeat: 0)
        var sourceY: Int64 = 0
        while (sourceY < height) {
            var sourceX: Int64 = 0
            while (sourceX < width) {
                let mirroredX = if (mirrored) { width - 1 - sourceX } else { sourceX }
                var destinationX = mirroredX
                var destinationY = sourceY
                if (turns == 1) {
                    destinationX = sourceY
                    destinationY = width - 1 - mirroredX
                } else if (turns == 2) {
                    destinationX = width - 1 - mirroredX
                    destinationY = height - 1 - sourceY
                } else if (turns == 3) {
                    destinationX = height - 1 - sourceY
                    destinationY = mirroredX
                }
                let sourceOffset = (sourceY * width + sourceX) * 4
                let destinationOffset = (destinationY * destinationWidth + destinationX) * 4
                destinationPixels[destinationOffset] = sourcePixels[sourceOffset]
                destinationPixels[destinationOffset + 1] = sourcePixels[sourceOffset + 1]
                destinationPixels[destinationOffset + 2] = sourcePixels[sourceOffset + 2]
                destinationPixels[destinationOffset + 3] = sourcePixels[sourceOffset + 3]
                sourceX += 1
            }
            sourceY += 1
        }
        return Some(createPixelMap(destinationPixels, InitializationOptions(
            Size(Int32(destinationWidth), Int32(destinationHeight)), editable: true,
            srcPixelFormat: PixelMapFormat.Bgra8888, pixelFormat: PixelMapFormat.Bgra8888,
            alphaType: AlphaType.Premul
        )))
    } catch (e: BusinessException) {
        Hilog.info(0, "CjTelegram", "[AvatarMediaEditor] source orientation failed: ${e.message}")
    } catch (_: Exception) {
        Hilog.info(0, "CjTelegram", "[AvatarMediaEditor] source orientation failed")
    }
    return None
}

/**
 * CropScrollView.swift keeps the complete aspect-filled source and reports a centered offset plus
 * zoomScale. Convert that viewport state to the square PixelMap only at export time.
 */
public func renderAvatarViewportCrop(
    source: PixelMap,
    viewportScale: Float64,
    viewportOffsetX: Float64,
    viewportOffsetY: Float64,
    viewportWidth: Float64,
    quarterTurns: Int64,
    mirrored: Bool
): Option<PixelMap> {
    try {
        let info = source.getImageInfo()
        let width = Int64(info.size.width)
        let height = Int64(info.size.height)
        if (width <= 0 || height <= 0 || viewportWidth <= 0.0) { return None }
        let result = normalizeAvatarPixelMap(source)
        let scale = if (viewportScale < 1.0) { 1.0 } else if (viewportScale > 4.0) { 4.0 } else { viewportScale }
        let minimumDimension = if (width < height) { width } else { height }
        var side = Int64(Float64(minimumDimension) / scale)
        if (side < 1) { side = 1 }
        let factor = Float64(minimumDimension) / (viewportWidth * scale)
        let transformedX = -viewportOffsetX * factor
        let transformedY = -viewportOffsetY * factor
        let turns = ((quarterTurns % 4) + 4) % 4
        var sourceX = transformedX
        var sourceY = transformedY
        if (turns == 1) {
            sourceX = -transformedY
            sourceY = transformedX
        } else if (turns == 2) {
            sourceX = -transformedX
            sourceY = -transformedY
        } else if (turns == 3) {
            sourceX = transformedY
            sourceY = -transformedX
        }
        if (mirrored) { sourceX = -sourceX }
        var originX = Int64(Float64(width - side) * 0.5 + sourceX)
        var originY = Int64(Float64(height - side) * 0.5 + sourceY)
        if (originX < 0) { originX = 0 }
        if (originY < 0) { originY = 0 }
        if (originX + side > width) { originX = width - side }
        if (originY + side > height) { originY = height - side }
        result.crop(Region(Size(Int32(side), Int32(side)), Int32(originX), Int32(originY)))
        if (mirrored) { result.flip(true, false) }
        if (turns > 0) { result.rotate(Float32(-90.0 * Float64(turns))) }
        return Some(result)
    } catch (e: BusinessException) {
        Hilog.info(0, "CjTelegram", "[AvatarMediaEditor] viewport crop failed: ${e.message}")
    } catch (_: Exception) {
        Hilog.info(0, "CjTelegram", "[AvatarMediaEditor] viewport crop failed")
    }
    return None
}

private func editorClamp(value: Float64): Float64 {
    return if (value < 0.0) { 0.0 } else if (value > 1.0) { 1.0 } else { value }
}

private func editorSmoothStep(edge0: Float64, edge1: Float64, value: Float64): Float64 {
    if (edge0 == edge1) { return if (value < edge0) { 0.0 } else { 1.0 } }
    let t = editorClamp((value - edge0) / (edge1 - edge0))
    return t * t * (3.0 - 2.0 * t)
}

private func editorSigmoid(value: Float64, strength: Float64): Float64 {
    let powerValue = 1.0 / (1.0 - strength)
    if (value > 0.5) {
        return 1.0 - pow(2.0 - 2.0 * value, powerValue) * 0.5
    }
    return pow(2.0 * value, powerValue) * 0.5
}

private func tintColor(index: Int64, highlights: Bool): (Float64, Float64, Float64) {
    let color: UInt32 = if (highlights) {
        match (index) {
            case 1 => 0xFFEF9286
            case 2 => 0xFFEACEA2
            case 3 => 0xFFF2E17C
            case 4 => 0xFFA4EDAE
            case 5 => 0xFF89DCE5
            case 6 => 0xFF2E8BC8
            case 7 => 0xFFCD98E5
            case _ => 0x00000000
        }
    } else {
        match (index) {
            case 1 => 0xFFFF4D4D
            case 2 => 0xFFF48022
            case 3 => 0xFFFFCD00
            case 4 => 0xFF81D281
            case 5 => 0xFF71C5D6
            case 6 => 0xFF0072BC
            case 7 => 0xFF662D91
            case _ => 0x00000000
        }
    }
    return (Float64((color >> 16) & 0xFF) / 255.0,
        Float64((color >> 8) & 0xFF) / 255.0,
        Float64(color & 0xFF) / 255.0)
}

private func raisedShadow(value: Float64): Float64 {
    return -0.003671 * pow(value, 3.0) + 0.3842 * pow(value, 2.0) + 0.3764 * value + 0.2515
}

private func applyShadowTint(value: Float64, tint: Float64, amount: Float64): Float64 {
    let raised = raisedShadow(value)
    let tinted = value * (1.0 - tint) + raised * tint
    return editorClamp(value * (1.0 - amount) + tinted * amount)
}

private func applyHighlightTint(value: Float64, tint: Float64, amount: Float64): Float64 {
    let lowered = 1.0 - raisedShadow(1.0 - value)
    let tinted = value * tint + lowered * (1.0 - tint)
    return editorClamp(value * (1.0 - amount) + tinted * amount)
}

private func applyFade(value: Float64, amount: Float64): Float64 {
    let faded = (-0.9772 * pow(value, 3.0) + 1.708 * pow(value, 2.0) - 0.1603 * value + 0.2878)
    let target = value + (faded - value) * 0.9
    return value * (1.0 - amount) + target * amount
}

private func curveSample(curve: Array<Float64>, offset: Int64, input: Float64): Float64 {
    var index = Int64(editorClamp(input) * 200.0)
    if (index > 199) { index = 199 }
    let segment = index / 50
    let sample = index % 50
    let t = Float64(sample * 2 + 1) / 100.0
    let t2 = t * t
    let t3 = t2 * t
    let first = if (segment == 0) { curve[offset] } else { curve[offset + segment - 1] }
    let second = curve[offset + segment]
    let third = curve[offset + segment + 1]
    let fourth = if (segment >= 3) { curve[offset + 4] } else { curve[offset + segment + 2] }
    return editorClamp(0.5 * (2.0 * second + (third - first) * t +
        (2.0 * first - 5.0 * second + 4.0 * third - fourth) * t2 +
        (3.0 * second - first - 3.0 * third + fourth) * t3))
}

private func curveValuesAreInitial(values: Array<Float64>): Bool {
    var index: Int64 = 0
    while (index < 20) {
        let field = index % 5
        let expected = Float64(field) * 0.25
        if (abs(values[index] - expected) > 0.0001) { return false }
        index += 1
    }
    return true
}

private func rgbToHsl(r: Float64, g: Float64, b: Float64): (Float64, Float64, Float64) {
    let maximum = max(r, max(g, b))
    let minimum = min(r, min(g, b))
    let lightness = (maximum + minimum) * 0.5
    if (maximum == minimum) { return (0.0, 0.0, lightness) }
    let delta = maximum - minimum
    let saturation = if (lightness > 0.5) { delta / (2.0 - maximum - minimum) } else { delta / (maximum + minimum) }
    var hue: Float64
    if (maximum == r) {
        hue = (g - b) / delta + (if (g < b) { 6.0 } else { 0.0 })
    } else if (maximum == g) {
        hue = (b - r) / delta + 2.0
    } else {
        hue = (r - g) / delta + 4.0
    }
    return (hue / 6.0, saturation, lightness)
}

private func hueToRgb(p: Float64, q: Float64, sourceHue: Float64): Float64 {
    var hue = sourceHue
    if (hue < 0.0) { hue += 1.0 }
    if (hue > 1.0) { hue -= 1.0 }
    if (hue < 1.0 / 6.0) { return p + (q - p) * 6.0 * hue }
    if (hue < 0.5) { return q }
    if (hue < 2.0 / 3.0) { return p + (q - p) * (2.0 / 3.0 - hue) * 6.0 }
    return p
}

private func hslToRgb(h: Float64, s: Float64, l: Float64): (Float64, Float64, Float64) {
    if (s == 0.0) { return (l, l, l) }
    let q = if (l < 0.5) { l * (1.0 + s) } else { l + s - l * s }
    let p = 2.0 * l - q
    return (hueToRgb(p, q, h + 1.0 / 3.0), hueToRgb(p, q, h), hueToRgb(p, q, h - 1.0 / 3.0))
}

/**
 * 按源端 EditorEnhance / EditorBlur / EditorAdjustments 的执行次序生成最终像素。
 * 数值范围与 iOS MediaEditorValues 保持一致，避免 UI 百分比与渲染参数脱节。
 */
public func renderAvatarMediaTools(source: PixelMap, values: AvatarMediaToolValues): Option<PixelMap> {
    try {
        let info = source.getImageInfo()
        let width = Int64(info.size.width)
        let height = Int64(info.size.height)
        if (width <= 0 || height <= 0) { return None }
        let normalizedSource = normalizeAvatarPixelMap(source)
        let original = readAvatarPixels(normalizedSource, width, height)
        var pixels = original

        if (!curveValuesAreInitial(values.curves)) {
            var index: Int64 = 0
            while (index < width * height) {
                let offset = index * 4
                var b = Float64(pixels[offset]) / 255.0
                var g = Float64(pixels[offset + 1]) / 255.0
                var r = Float64(pixels[offset + 2]) / 255.0
                let (hue, saturation, lightness) = rgbToHsl(r, g, b)
                let grayscale = editorSmoothStep(0.0, 0.1, lightness) * (1.0 - editorSmoothStep(0.8, 1.0, lightness))
                let adjustedSaturation = saturation * grayscale
                let adjustedLightness = curveSample(values.curves, 0, lightness)
                let (adjustedRed, adjustedGreen, adjustedBlue) = hslToRgb(hue, adjustedSaturation, adjustedLightness)
                r = curveSample(values.curves, 5, adjustedRed)
                g = curveSample(values.curves, 10, adjustedGreen)
                b = curveSample(values.curves, 15, adjustedBlue)
                pixels[offset] = UInt8(editorClamp(b) * 255.0)
                pixels[offset + 1] = UInt8(editorClamp(g) * 255.0)
                pixels[offset + 2] = UInt8(editorClamp(r) * 255.0)
                index += 1
            }
        }

        if (values.enhance > 0.005) {
            let histogram = Array<Int64>(256, repeat: 0)
            var index: Int64 = 0
            while (index < width * height) {
                let offset = index * 4
                let light = (Int64(pixels[offset + 2]) * 299 + Int64(pixels[offset + 1]) * 587 + Int64(pixels[offset]) * 114) / 1000
                histogram[light] += 1
                index += 1
            }
            let cumulative = Array<Int64>(256, repeat: 0)
            var running: Int64 = 0
            var bucket: Int64 = 0
            while (bucket < 256) {
                running += histogram[bucket]
                cumulative[bucket] = running
                bucket += 1
            }
            index = 0
            while (index < width * height) {
                let offset = index * 4
                let b = Float64(pixels[offset]) / 255.0
                let g = Float64(pixels[offset + 1]) / 255.0
                let r = Float64(pixels[offset + 2]) / 255.0
                let lightIndex = (Int64(pixels[offset + 2]) * 299 + Int64(pixels[offset + 1]) * 587 + Int64(pixels[offset]) * 114) / 1000
                let mapped = Float64(cumulative[lightIndex]) / Float64(width * height)
                let oldLight = editorClamp(r * 0.299 + g * 0.587 + b * 0.114)
                let scale = if (oldLight > 0.001) { (oldLight * (1.0 - values.enhance) + mapped * 1.1 * values.enhance) / oldLight } else { 1.0 }
                pixels[offset] = UInt8(editorClamp(b * scale) * 255.0)
                pixels[offset + 1] = UInt8(editorClamp(g * scale) * 255.0)
                pixels[offset + 2] = UInt8(editorClamp(r * scale) * 255.0)
                index += 1
            }
        }

        if (values.blurMode != 0 && values.blurIntensity > 0.005) {
            let options = InitializationOptions(Size(Int32(width), Int32(height)), editable: true,
                srcPixelFormat: PixelMapFormat.Bgra8888, pixelFormat: PixelMapFormat.Bgra8888,
                alphaType: AlphaType.Premul)
            let blurInput = createPixelMap(pixels, options)
            let radius = Int32(3.0 + values.blurIntensity * 18.0)
            match (getImageBlurBinding().blurPixelMap(blurInput, radius, Int32(3))) {
                case Some(blurred) =>
                    let blurredPixels = readAvatarPixels(blurred, width, height)
                    var y: Int64 = 0
                    while (y < height) {
                        var x: Int64 = 0
                        while (x < width) {
                            let nx = (Float64(x) + 0.5) / Float64(width)
                            let ny = (Float64(y) + 0.5) / Float64(height)
                            let aspect = Float64(width) / Float64(height)
                            let correctedY = ny * aspect + 0.5 - 0.5 * aspect
                            let distance = if (values.blurMode == 1) {
                                let dx = nx - values.blurPositionX
                                let dy = correctedY - values.blurPositionY
                                sqrt(dx * dx + dy * dy)
                            } else {
                                abs((nx - values.blurPositionX) * sin(-values.blurRotation) +
                                    (correctedY - values.blurPositionY) * cos(-values.blurRotation))
                            }
                            let sourceMix = editorSmoothStep(1.0, values.blurFalloff,
                                editorClamp(distance / values.blurSize))
                            let offset = (y * width + x) * 4
                            var channel: Int64 = 0
                            while (channel < 3) {
                                let mixed = Float64(blurredPixels[offset + channel]) * (1.0 - sourceMix) + Float64(pixels[offset + channel]) * sourceMix
                                pixels[offset + channel] = UInt8(mixed)
                                channel += 1
                            }
                            x += 1
                        }
                        y += 1
                    }
                case None => ()
            }
        }

        let shadowTint = tintColor(values.shadowsTintColor, false)
        let highlightTint = tintColor(values.highlightsTintColor, true)
        var y: Int64 = 0
        while (y < height) {
            var x: Int64 = 0
            while (x < width) {
                let offset = (y * width + x) * 4
                var b = Float64(pixels[offset]) / 255.0
                var g = Float64(pixels[offset + 1]) / 255.0
                var r = Float64(pixels[offset + 2]) / 255.0

                if (abs(values.highlights) > 0.005 || abs(values.shadows) > 0.005) {
                    let luminance = r * 0.3 + g * 0.3 + b * 0.3
                    let mappedHighlights = values.highlights * 0.75 + 1.0
                    let mappedShadows = values.shadows * 0.55 + 1.0
                    let shadow = editorClamp((pow(luminance, 1.0 / mappedShadows) - 0.76 * pow(luminance, 2.0 / mappedShadows)) - luminance)
                    var highlight = (1.0 - (pow(1.0 - luminance, 1.0 / (2.0 - mappedHighlights)) - 0.8 * pow(1.0 - luminance, 2.0 / (2.0 - mappedHighlights)))) - luminance
                    if (highlight < -1.0) { highlight = -1.0 }
                    if (highlight > 0.0) { highlight = 0.0 }
                    let newLuminance = luminance + shadow + highlight
                    let scale = if (luminance > 0.0001) { newLuminance / luminance } else { 1.0 }
                    r *= scale; g *= scale; b *= scale
                }

                if (abs(values.contrast) > 0.005) {
                    let mapped = values.contrast * 0.3 + 1.0
                    r = editorClamp((r - 0.5) * mapped + 0.5)
                    g = editorClamp((g - 0.5) * mapped + 0.5)
                    b = editorClamp((b - 0.5) * mapped + 0.5)
                }
                if (values.fade > 0.005) {
                    r = applyFade(r, values.fade); g = applyFade(g, values.fade); b = applyFade(b, values.fade)
                }
                if (abs(values.saturation) > 0.005) {
                    var mapped = values.saturation
                    if (mapped > 0.0) { mapped *= 1.05 }
                    mapped += 1.0
                    let luminance = r * 0.2126 + g * 0.7152 + b * 0.0722
                    r = editorClamp(luminance + (r - luminance) * mapped)
                    g = editorClamp(luminance + (g - luminance) * mapped)
                    b = editorClamp(luminance + (b - luminance) * mapped)
                }
                if (values.shadowsTintColor != 0 && values.shadowsTintIntensity > 0.005) {
                    let amount = values.shadowsTintIntensity * 2.0
                    r = applyShadowTint(r, shadowTint[0], amount)
                    g = applyShadowTint(g, shadowTint[1], amount)
                    b = applyShadowTint(b, shadowTint[2], amount)
                }
                if (values.highlightsTintColor != 0 && values.highlightsTintIntensity > 0.005) {
                    let amount = values.highlightsTintIntensity * 2.0
                    r = applyHighlightTint(r, highlightTint[0], amount)
                    g = applyHighlightTint(g, highlightTint[1], amount)
                    b = applyHighlightTint(b, highlightTint[2], amount)
                }
                if (abs(values.brightness) > 0.005) {
                    let magnitude = values.brightness * 1.045
                    var powerValue = 1.0 + abs(magnitude)
                    if (magnitude < 0.0) { powerValue = 1.0 / powerValue }
                    r = 1.0 - pow(1.0 - r, powerValue)
                    g = 1.0 - pow(1.0 - g, powerValue)
                    b = 1.0 - pow(1.0 - b, powerValue)
                }
                if (abs(values.warmth) > 0.005) {
                    let luminance = r * 0.299 + g * 0.587 + b * 0.114
                    var u = (b - luminance) / 1.772
                    var v = (r - luminance) / 1.402
                    let curveScale = sin(luminance * 3.14159)
                    if (values.warmth > 0.0) {
                        u += 0.375 * values.warmth * curveScale * -0.1255
                        v += 0.375 * values.warmth * curveScale * 0.0902
                    } else {
                        u += 0.375 * values.warmth * curveScale * -0.1569
                        v += 0.375 * values.warmth * curveScale * 0.1255
                    }
                    r = editorClamp(1.402 * v + luminance)
                    g = editorClamp(luminance - (0.299 * 1.402 / 0.587) * v - (0.114 * 1.772 / 0.587) * u)
                    b = editorClamp(1.772 * u + luminance)
                }
                if (values.vignette > 0.005) {
                    let dx = (Float64(x) + 0.5) / Float64(width) - 0.5
                    let dy = (Float64(y) + 0.5) / Float64(height) - 0.5
                    let radial = sqrt(dx * dx + dy * dy) / sqrt(0.5)
                    let magnitude = editorSigmoid(radial * 0.7, 0.62) * values.vignette * 0.645
                    r = pow(editorClamp(r), 1.0 / (1.0 - magnitude)) * (1.0 - magnitude * magnitude)
                    g = pow(editorClamp(g), 1.0 / (1.0 - magnitude)) * (1.0 - magnitude * magnitude)
                    b = pow(editorClamp(b), 1.0 / (1.0 - magnitude)) * (1.0 - magnitude * magnitude)
                }
                if (values.grain > 0.005) {
                    let seed = sin(Float64(x) * 12.9898 + Float64(y) * 78.233) * 43758.5453
                    let noise = (seed - floor(seed)) * 2.0 - 1.0
                    let luminance = r * 0.299 + g * 0.587 + b * 0.114
                    let shadowMask = editorSmoothStep(0.2, 0.0, luminance) + luminance
                    let grain = noise * (1.0 - pow(editorClamp(shadowMask), 4.0)) * values.grain * 0.04
                    r = editorClamp(r + grain); g = editorClamp(g + grain); b = editorClamp(b + grain)
                }
                pixels[offset] = UInt8(editorClamp(b) * 255.0)
                pixels[offset + 1] = UInt8(editorClamp(g) * 255.0)
                pixels[offset + 2] = UInt8(editorClamp(r) * 255.0)
                x += 1
            }
            y += 1
        }
        return Some(createPixelMap(pixels, InitializationOptions(Size(Int32(width), Int32(height)),
            editable: true, srcPixelFormat: PixelMapFormat.Bgra8888,
            pixelFormat: PixelMapFormat.Bgra8888, alphaType: AlphaType.Premul)))
    } catch (e: BusinessException) {
        Hilog.info(0, "CjTelegram", "[AvatarMediaEditor] render failed: ${e.message}")
    } catch (_: Exception) {
        Hilog.info(0, "CjTelegram", "[AvatarMediaEditor] render failed")
    }
    return None
}
