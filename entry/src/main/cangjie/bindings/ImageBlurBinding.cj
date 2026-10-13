package ohos_app_cangjie_entry.bindings

import kit.ImageKit.{PixelMap, InitializationOptions, Size, createPixelMap, PixelMapFormat, AlphaType}
import ohos.business_exception.BusinessException
import kit.PerformanceAnalysisKit.Hilog

/**
 * ImageBlurBinding — 图片模糊平台封装层
 *
 * 对应 Telegram-iOS ImageBlur.swift（使用 vImageBoxConvolve_ARGB8888 实现 box blur）。
 * 鸿蒙侧通过 PixelMap readPixelsToBuffer / writeBufferToPixels 访问像素，
 * 在纯 Cangjie 中实现等效的 box blur 算法。
 *
 * 提供：
 * - blurPixelMap：等宽等高盒状模糊（对应 iOS blurredImage）
 * - verticalBlurPixelMap：仅垂直方向模糊（对应 iOS verticalBlurredImage）
 */

private var _imageBlurBindingInstance: Option<ImageBlurBinding> = None

/**
 * 获取 ImageBlurBinding 单例
 */
public func getImageBlurBinding(): ImageBlurBinding {
    match (_imageBlurBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ImageBlurBinding()
            _imageBlurBindingInstance = Some(inst)
            return inst
    }
}

/**
 * 图片模糊平台封装层
 */
public class ImageBlurBinding {

    /**
     * 对 PixelMap 进行等宽等高盒状模糊（多次迭代）
     * @param source  源 PixelMap（BGRA_8888 格式，可编辑）
     * @param radius  模糊半径（像素），对应 iOS boxSize
     * @param iterations  迭代次数，默认 3（与 iOS 默认一致）
     * @return 模糊后的新 PixelMap，失败返回 None
     */
    public func blurPixelMap(source: PixelMap, radius: Int32, iterations: Int32): Option<PixelMap> {
        if (radius <= 0) {
            return Some(source)
        }
        return applyBoxBlur(source, Int64(radius), Int64(radius), iterations)
    }

    /**
     * 对 PixelMap 进行仅垂直方向盒状模糊（多次迭代）
     * @param source  源 PixelMap（BGRA_8888 格式，可编辑）
     * @param radius  垂直模糊半径（像素）
     * @param iterations  迭代次数，默认 3
     * @return 模糊后的新 PixelMap，失败返回 None
     */
    public func verticalBlurPixelMap(source: PixelMap, radius: Int32, iterations: Int32): Option<PixelMap> {
        if (radius <= 0) {
            return Some(source)
        }
        return applyBoxBlur(source, 0, Int64(radius), iterations)
    }

    /**
     * 核心 box blur 实现
     * 对应 iOS vImageBoxConvolve_ARGB8888 多次迭代逻辑。
     * 像素格式为 BGRA_8888：每像素 4 字节，顺序 B / G / R / A。
     * radiusX: 水平模糊半径（0 表示不做水平模糊）
     * radiusY: 垂直模糊半径（0 表示不做垂直模糊）
     */
    private func applyBoxBlur(source: PixelMap, radiusX: Int64, radiusY: Int64, iterations: Int32): Option<PixelMap> {
        try {
            let info = source.getImageInfo()
            let width = Int64(info.size.width)
            let height = Int64(info.size.height)

            if (width <= 0 || height <= 0) {
                return None
            }

            let bytesPerPixel: Int64 = 4
            let totalBytes = Int64(source.getPixelBytesNumber())

            // 读出像素数据到缓冲区（BGRA_8888 格式）
            let inBuffer = Array<UInt8>(totalBytes, repeat: 0)
            source.readPixelsToBuffer(inBuffer)

            // outBuffer 用于存放单次 box blur 结果
            var srcBuf = inBuffer
            var dstBuf = Array<UInt8>(totalBytes, repeat: 0)

            var iter: Int32 = 0
            while (iter < iterations) {
                // 对 srcBuf 应用一次盒状卷积，结果写入 dstBuf
                boxBlurPass(srcBuf, dstBuf, width, height, bytesPerPixel, radiusX, radiusY)
                // swap：iOS 中 inBuffer.data 与 outBuffer.data 互换指针
                let tmp = srcBuf
                srcBuf = dstBuf
                dstBuf = tmp
                iter = iter + 1
            }

            // 迭代结束后 srcBuf 保存最终结果，创建新 PixelMap 写入
            let opts = InitializationOptions(
                Size(Int32(width), Int32(height)),
                editable: true,
                srcPixelFormat: PixelMapFormat.Bgra8888,
                pixelFormat: PixelMapFormat.Bgra8888
            )
            let resultPixelMap = createPixelMap(srcBuf, opts)
            return Some(resultPixelMap)
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[ImageBlurBinding] applyBoxBlur failed")
            return None
        }
    }

    /**
     * 单次盒状卷积（水平 + 垂直）
     * 若 radiusX == 0 仅做垂直；若 radiusY == 0 仅做水平。
     * 边界像素采用 edge-extend（与 iOS kvImageEdgeExtend 一致）。
     */
    private func boxBlurPass(
        src: Array<UInt8>,
        dst: Array<UInt8>,
        width: Int64,
        height: Int64,
        bytesPerPixel: Int64,
        radiusX: Int64,
        radiusY: Int64
    ): Unit {
        let rowBytes = width * bytesPerPixel

        // 水平 pass 结果写入临时缓冲，再做垂直 pass
        let hBuf: Array<UInt8>
        if (radiusX > 0) {
            hBuf = Array<UInt8>(Int64(src.size), repeat: 0)
            blurHorizontal(src, hBuf, width, height, rowBytes, bytesPerPixel, radiusX)
        } else {
            hBuf = src
        }

        if (radiusY > 0) {
            blurVertical(hBuf, dst, width, height, rowBytes, bytesPerPixel, radiusY)
        } else {
            // 没有垂直模糊，把 hBuf 复制到 dst
            var i: Int64 = 0
            while (i < Int64(dst.size)) {
                dst[i] = hBuf[i]
                i = i + 1
            }
        }
    }

    /**
     * 水平方向盒状模糊（每行独立处理）
     * 对每个像素，在 [x-radius, x+radius] 范围内取平均值，边界 edge-extend。
     */
    private func blurHorizontal(
        src: Array<UInt8>,
        dst: Array<UInt8>,
        width: Int64,
        height: Int64,
        rowBytes: Int64,
        bytesPerPixel: Int64,
        radius: Int64
    ): Unit {
        let kernelSize = radius * 2 + 1
        var y: Int64 = 0
        while (y < height) {
            let rowOffset = y * rowBytes
            var x: Int64 = 0
            while (x < width) {
                var sumB: Int64 = 0
                var sumG: Int64 = 0
                var sumR: Int64 = 0
                var sumA: Int64 = 0
                var k: Int64 = -radius
                while (k <= radius) {
                    var sx = x + k
                    // edge-extend
                    if (sx < 0) { sx = 0 }
                    if (sx >= width) { sx = width - 1 }
                    let pixelOffset = rowOffset + sx * bytesPerPixel
                    sumB = sumB + Int64(src[pixelOffset])
                    sumG = sumG + Int64(src[pixelOffset + 1])
                    sumR = sumR + Int64(src[pixelOffset + 2])
                    sumA = sumA + Int64(src[pixelOffset + 3])
                    k = k + 1
                }
                let dstOffset = rowOffset + x * bytesPerPixel
                dst[dstOffset] = UInt8(sumB / kernelSize)
                dst[dstOffset + 1] = UInt8(sumG / kernelSize)
                dst[dstOffset + 2] = UInt8(sumR / kernelSize)
                dst[dstOffset + 3] = UInt8(sumA / kernelSize)
                x = x + 1
            }
            y = y + 1
        }
    }

    /**
     * 垂直方向盒状模糊（每列独立处理）
     * 对每个像素，在 [y-radius, y+radius] 范围内取平均值，边界 edge-extend。
     */
    private func blurVertical(
        src: Array<UInt8>,
        dst: Array<UInt8>,
        width: Int64,
        height: Int64,
        rowBytes: Int64,
        bytesPerPixel: Int64,
        radius: Int64
    ): Unit {
        let kernelSize = radius * 2 + 1
        var x: Int64 = 0
        while (x < width) {
            var y: Int64 = 0
            while (y < height) {
                var sumB: Int64 = 0
                var sumG: Int64 = 0
                var sumR: Int64 = 0
                var sumA: Int64 = 0
                var k: Int64 = -radius
                while (k <= radius) {
                    var sy = y + k
                    // edge-extend
                    if (sy < 0) { sy = 0 }
                    if (sy >= height) { sy = height - 1 }
                    let pixelOffset = sy * rowBytes + x * bytesPerPixel
                    sumB = sumB + Int64(src[pixelOffset])
                    sumG = sumG + Int64(src[pixelOffset + 1])
                    sumR = sumR + Int64(src[pixelOffset + 2])
                    sumA = sumA + Int64(src[pixelOffset + 3])
                    k = k + 1
                }
                let dstOffset = y * rowBytes + x * bytesPerPixel
                dst[dstOffset] = UInt8(sumB / kernelSize)
                dst[dstOffset + 1] = UInt8(sumG / kernelSize)
                dst[dstOffset + 2] = UInt8(sumR / kernelSize)
                dst[dstOffset + 3] = UInt8(sumA / kernelSize)
                y = y + 1
            }
            x = x + 1
        }
    }
}
