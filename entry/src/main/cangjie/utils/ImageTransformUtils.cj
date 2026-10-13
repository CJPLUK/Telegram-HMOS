package ohos_app_cangjie_entry.utils

import kit.PerformanceAnalysisKit.Hilog
import kit.ImageKit.{PixelMap, Region, Size}
import ohos.business_exception.BusinessException
import ohos_app_cangjie_entry.bindings.{ImageBlurBinding, getImageBlurBinding}

/**
 * ImageTransformUtils — 图片缩放/裁剪/fit 几何工具
 *
 * 对应 iOS TransformImageArguments.swift + DirectMediaImageCache 中的 aspectFilled 几何演算。
 * 实现 P2-225：aspect-fit/fill 矩形数学演算 + 圆角参数结构 + 饱和度调整。
 *
 * iOS 对照：
 * - TransformImageArguments: corners / imageSize / boundingSize / resizeMode
 * - generateBlurredThumbnail: 32x32 aspect-fill + saturation boost
 * - adjustSaturationInContext: vImage 色彩矩阵乘法 (我方用纯整数近似)
 *
 * 平台限制说明：
 * - vImage GPU 加速不可用 (鸿蒙无等价 API)；用纯 Cangjie 整数 ARGB 矩阵替代 —— 结果精度与 iOS 一致，性能略低
 * - PixelMap.crop(Region) 和 PixelMap.scale(Float32, Float32) 真实可用（KB 验证）
 */

// ─────────────────────────────────────────────────────────────────
// ImageCornerRadius — 圆角参数 (对应 iOS ImageCorners)
// ─────────────────────────────────────────────────────────────────

/**
 * 四角圆角半径（像素）
 * 0 表示直角。
 */
public struct ImageCornerRadius {
    public var topLeft: Float64
    public var topRight: Float64
    public var bottomLeft: Float64
    public var bottomRight: Float64

    public init(
        topLeft!: Float64 = 0.0,
        topRight!: Float64 = 0.0,
        bottomLeft!: Float64 = 0.0,
        bottomRight!: Float64 = 0.0
    ) {
        this.topLeft = topLeft
        this.topRight = topRight
        this.bottomLeft = bottomLeft
        this.bottomRight = bottomRight
    }

    /** 全圆角快捷构造 */
    public static func uniform(radius: Float64): ImageCornerRadius {
        return ImageCornerRadius(topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius)
    }

    /** 圆形快捷构造（radius = size/2，用于头像） */
    public static func circle(diameter: Float64): ImageCornerRadius {
        let r = diameter / 2.0
        return ImageCornerRadius(topLeft: r, topRight: r, bottomLeft: r, bottomRight: r)
    }

    public func isZero(): Bool {
        return this.topLeft == 0.0 && this.topRight == 0.0 && this.bottomLeft == 0.0 && this.bottomRight == 0.0
    }
}

// ─────────────────────────────────────────────────────────────────
// FitRect — aspect-fit/fill 几何演算结果
// ─────────────────────────────────────────────────────────────────

/**
 * 在目标矩形（boundingW x boundingH）内对源图（srcW x srcH）
 * 做 aspect-fit 或 aspect-fill 的几何演算结果。
 *
 * 对应 iOS:
 *   CGSize.aspectFilled(CGSize) — 等同 aspectFill
 *   TransformImageArguments.drawingRect — 含 insets 的绘制区
 */
public struct FitRect {
    /** 目标矩形内绘制区域的左上角 X 偏移（像素，aspect-fit 时用于居中） */
    public var x: Float64
    /** 目标矩形内绘制区域的左上角 Y 偏移（像素） */
    public var y: Float64
    /** 绘制宽度（像素） */
    public var width: Float64
    /** 绘制高度（像素） */
    public var height: Float64

    public init(x!: Float64, y!: Float64, width!: Float64, height!: Float64) {
        this.x = x
        this.y = y
        this.width = width
        this.height = height
    }
}

// ─────────────────────────────────────────────────────────────────
// Aspect-Fit 几何演算（纯数学，不依赖平台 API）
// ─────────────────────────────────────────────────────────────────

/**
 * 计算 aspect-fit 目标矩形（保持宽高比，图片完整显示，可能有留白）。
 *
 * 对应 iOS CGSize.aspectFitted(CGSize)。
 *
 * @param srcWidth      源图宽度（像素）
 * @param srcHeight     源图高度（像素）
 * @param boundingWidth 目标容器宽度（像素）
 * @param boundingHeight 目标容器高度（像素）
 * @return 居中的 FitRect，满足宽高比且不超出 bounding
 */
public func aspectFitRect(srcWidth: Float64, srcHeight: Float64, boundingWidth: Float64, boundingHeight: Float64): FitRect {
    if (srcWidth <= 0.0 || srcHeight <= 0.0 || boundingWidth <= 0.0 || boundingHeight <= 0.0) {
        return FitRect(x: 0.0, y: 0.0, width: boundingWidth, height: boundingHeight)
    }
    let scaleX = boundingWidth / srcWidth
    let scaleY = boundingHeight / srcHeight
    let scale = if (scaleX < scaleY) { scaleX } else { scaleY }
    let fitW = srcWidth * scale
    let fitH = srcHeight * scale
    let offsetX = (boundingWidth - fitW) / 2.0
    let offsetY = (boundingHeight - fitH) / 2.0
    return FitRect(x: offsetX, y: offsetY, width: fitW, height: fitH)
}

/**
 * 计算 aspect-fill 绘制矩形（保持宽高比，充满目标区域，源图可能裁剪）。
 *
 * 对应 iOS CGSize.aspectFilled(CGSize)，DirectMediaImageCache 中用于 32x32 缩略图生成：
 *   let filledSize = image.size.aspectFilled(thumbnailContextSize)
 *   let imageRect = CGRect(origin: CGPoint(x: (thumbnailContextSize.width - filledSize.width) / 2.0, ...))
 *
 * @return 以目标中心为原点居中的 FitRect（x/y 可能为负数，表示源图超出边界）
 */
public func aspectFillRect(srcWidth: Float64, srcHeight: Float64, boundingWidth: Float64, boundingHeight: Float64): FitRect {
    if (srcWidth <= 0.0 || srcHeight <= 0.0 || boundingWidth <= 0.0 || boundingHeight <= 0.0) {
        return FitRect(x: 0.0, y: 0.0, width: boundingWidth, height: boundingHeight)
    }
    let scaleX = boundingWidth / srcWidth
    let scaleY = boundingHeight / srcHeight
    let scale = if (scaleX > scaleY) { scaleX } else { scaleY }
    let fillW = srcWidth * scale
    let fillH = srcHeight * scale
    let offsetX = (boundingWidth - fillW) / 2.0
    let offsetY = (boundingHeight - fillH) / 2.0
    return FitRect(x: offsetX, y: offsetY, width: fillW, height: fillH)
}

/**
 * 为 aspect-fill 场景计算源图裁剪区域（Region），使结果直接 fit 到目标尺寸。
 *
 * 适用于将 srcPixelMap 裁剪后缩放到 (targetW x targetH) 的 fill 效果。
 * 返回的 Region 可直接传给 PixelMap.crop(region)。
 *
 * @param srcWidth    源图宽
 * @param srcHeight   源图高
 * @param targetWidth 目标宽
 * @param targetHeight 目标高
 * @return 源图裁剪区 (Region with x/y offset)
 */
public func cropRegionForAspectFill(srcWidth: Int64, srcHeight: Int64, targetWidth: Int64, targetHeight: Int64): Region {
    if (srcWidth <= 0 || srcHeight <= 0 || targetWidth <= 0 || targetHeight <= 0) {
        return Region(Size(Int32(srcWidth), Int32(srcHeight)), 0, 0)
    }
    let sw = Float64(srcWidth)
    let sh = Float64(srcHeight)
    let tw = Float64(targetWidth)
    let th = Float64(targetHeight)
    let scaleX = tw / sw
    let scaleY = th / sh
    let scale = if (scaleX > scaleY) { scaleX } else { scaleY }

    // 裁剪后的尺寸（在源图坐标系）
    let cropW = tw / scale
    let cropH = th / scale
    let cropX = (sw - cropW) / 2.0
    let cropY = (sh - cropH) / 2.0

    let ix = Int64(cropX)
    let iy = Int64(cropY)
    let iw = Int64(cropW)
    let ih = Int64(cropH)

    // Clamp to source bounds
    let clampedW = if (ix + iw > srcWidth) { srcWidth - ix } else { iw }
    let clampedH = if (iy + ih > srcHeight) { srcHeight - iy } else { ih }

    return Region(Size(Int32(clampedW), Int32(clampedH)), Int32(ix), Int32(iy))
}

// ─────────────────────────────────────────────────────────────────
// 饱和度调整（纯整数 BGRA，对应 iOS adjustSaturationInContext）
// ─────────────────────────────────────────────────────────────────

/**
 * 对 PixelMap 的像素 buffer 应用饱和度调整。
 *
 * 对应 iOS adjustSaturationInContext(context:saturation:)，使用 vImageMatrixMultiply_ARGB8888。
 * 鸿蒙侧用纯 Cangjie 整数矩阵乘法替代（不依赖 vImage）。
 *
 * iOS 使用的色彩矩阵（亮度权重 r=0.3086 g=0.6094 b=0.0820）与本实现完全一致。
 * 默认 saturation=1.7，与 iOS generateBlurredThumbnail(adjustSaturation:true) 一致。
 *
 * @param pixelMap   要处理的 PixelMap（BGRA_8888 格式，可编辑）
 * @param saturation 饱和度系数（1.0=无变化，>1.0=增强，<1.0=减弱）
 * @return 调整后的 PixelMap（在原 PixelMap 上原地修改并返回），失败返回 None
 */
public func adjustSaturation(pixelMap: PixelMap, saturation: Float64): Option<PixelMap> {
    try {
        let totalBytes = Int64(pixelMap.getPixelBytesNumber())
        if (totalBytes < 4) {
            return Some(pixelMap)
        }

        let buf = Array<UInt8>(totalBytes, repeat: 0)
        pixelMap.readPixelsToBuffer(buf)

        // iOS 亮度权重
        let rwgt: Float64 = 0.3086
        let gwgt: Float64 = 0.6094
        let bwgt: Float64 = 0.0820

        let s = saturation
        let one_s = 1.0 - s

        // 色彩矩阵系数（BGRA 顺序：B=0, G=1, R=2, A=3）
        // 输出 R = a*R + d*G + g*B
        // 输出 G = b*R + e*G + h*B
        // 输出 B = c*R + f*G + i*B
        let mRR = one_s * rwgt + s     // R -> R
        let mRG = one_s * gwgt         // G -> R
        let mRB = one_s * bwgt         // B -> R
        let mGR = one_s * rwgt         // R -> G
        let mGG = one_s * gwgt + s     // G -> G
        let mGB = one_s * bwgt         // B -> G
        let mBR = one_s * rwgt         // R -> B
        let mBG = one_s * gwgt         // G -> B
        let mBB = one_s * bwgt + s     // B -> B

        // 整数精度因子（匹配 iOS 的 divisor = 0x1000 = 4096）
        let divisor: Int64 = 4096
        let imRR = Int64(mRR * Float64(divisor))
        let imRG = Int64(mRG * Float64(divisor))
        let imRB = Int64(mRB * Float64(divisor))
        let imGR = Int64(mGR * Float64(divisor))
        let imGG = Int64(mGG * Float64(divisor))
        let imGB = Int64(mGB * Float64(divisor))
        let imBR = Int64(mBR * Float64(divisor))
        let imBG = Int64(mBG * Float64(divisor))
        let imBB = Int64(mBB * Float64(divisor))

        let pixelCount = totalBytes / 4
        var i: Int64 = 0
        while (i < pixelCount) {
            let offset = i * 4
            let b = Int64(buf[offset])
            let g = Int64(buf[offset + 1])
            let r = Int64(buf[offset + 2])

            // 矩阵乘法 (BGRA 顺序)
            let newR = (imRR * r + imRG * g + imRB * b) / divisor
            let newG = (imGR * r + imGG * g + imGB * b) / divisor
            let newB = (imBR * r + imBG * g + imBB * b) / divisor

            // Clamp to [0, 255]
            buf[offset] = UInt8(if (newB < 0) { 0 } else if (newB > 255) { 255 } else { newB })
            buf[offset + 1] = UInt8(if (newG < 0) { 0 } else if (newG > 255) { 255 } else { newG })
            buf[offset + 2] = UInt8(if (newR < 0) { 0 } else if (newR > 255) { 255 } else { newR })

            i = i + 1
        }

        // 写回到同一 PixelMap
        pixelMap.writeBufferToPixels(buf)
        return Some(pixelMap)

    } catch (e: BusinessException) {
        Hilog.info(0, "CjTelegram", "[ImageTransformUtils] adjustSaturation failed")
        return None
    }
}

/**
 * 将 PixelMap 缩放到目标尺寸（aspect-fill，中心裁剪）。
 *
 * 对应 iOS DirectMediaImageCache.generateBlurredThumbnail 中的：
 *   let thumbnailContextSize = CGSize(width: 32.0, height: 32.0)
 *   let filledSize = image.size.aspectFilled(thumbnailContextSize)
 *
 * 实现：先 crop 到 aspect-fill 区域，再用 scale() 缩放到目标尺寸。
 *
 * @param pixelMap     源 PixelMap（可编辑）
 * @param targetWidth  目标宽度（像素）
 * @param targetHeight 目标高度（像素）
 * @return 缩放后的 PixelMap；失败返回 None
 */
public func pixelMapAspectFillScale(pixelMap: PixelMap, targetWidth: Int64, targetHeight: Int64): Option<PixelMap> {
    try {
        let info = pixelMap.getImageInfo()
        let srcW = Int64(info.size.width)
        let srcH = Int64(info.size.height)

        if (srcW <= 0 || srcH <= 0 || targetWidth <= 0 || targetHeight <= 0) {
            return None
        }

        // 1. 裁剪到 aspect-fill 区域
        let cropRegion = cropRegionForAspectFill(srcW, srcH, targetWidth, targetHeight)
        pixelMap.crop(cropRegion)

        // 2. 缩放到目标尺寸（PixelMap.scale 接受 Float32 比例因子）
        let afterInfo = pixelMap.getImageInfo()
        let croppedW = Int64(afterInfo.size.width)
        let croppedH = Int64(afterInfo.size.height)

        if (croppedW <= 0 || croppedH <= 0) {
            return None
        }

        let scaleX = Float32(targetWidth) / Float32(croppedW)
        let scaleY = Float32(targetHeight) / Float32(croppedH)
        pixelMap.scale(scaleX, scaleY)

        return Some(pixelMap)
    } catch (e: BusinessException) {
        Hilog.info(0, "CjTelegram", "[ImageTransformUtils] pixelMapAspectFillScale failed")
        return None
    }
}

/**
 * 生成模糊缩略图（32x32，aspect-fill，可选饱和度增强）。
 *
 * 完整对应 iOS DirectMediaImageCache.generateBlurredThumbnail：
 *   1. 生成 32x32 aspect-fill DrawingContext
 *   2. telegramFastBlurMore（本侧用 ImageBlurBinding box blur radius=4 3次迭代）
 *   3. 若 adjustSaturation=true，saturation=1.7
 *
 * 渐进 JPEG 解码不可用（鸿蒙 ImageSource 无流式帧解码 API），用同一接口做普通 JPEG 缩略图。
 *
 * @param pixelMap         源 PixelMap
 * @param withSaturation   是否增强饱和度（默认 true，与 iOS includeBlurred=true 路径一致）
 * @return 32x32 模糊缩略图 PixelMap；失败返回 None
 */
public func generateBlurredThumbnail32(pixelMap: PixelMap, withSaturation!: Bool = true): Option<PixelMap> {
    // 1. aspect-fill 缩放到 32x32
    let scaled = pixelMapAspectFillScale(pixelMap, 32, 32)
    match (scaled) {
        case None => return None
        case Some(pm) =>
            // 2. box blur（半径=4，3次迭代，对应 iOS telegramFastBlurMore）
            let blurBinding = getImageBlurBindingForTransform()
            let blurred = blurBinding.blurPixelMap(pm, 4, 3)
            match (blurred) {
                case None => return None
                case Some(bpm) =>
                    // 3. 饱和度调整（saturation=1.7）
                    if (withSaturation) {
                        return adjustSaturation(bpm, 1.7)
                    }
                    return Some(bpm)
            }
    }
}

// ─────────────────────────────────────────────────────────────────
// 辅助：获取 ImageBlurBinding 实例（通过已引入的 import）
// ─────────────────────────────────────────────────────────────────

private func getImageBlurBindingForTransform(): ImageBlurBinding {
    return getImageBlurBinding()
}
