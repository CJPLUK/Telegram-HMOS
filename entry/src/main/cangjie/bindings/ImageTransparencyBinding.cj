package ohos_app_cangjie_entry.bindings

import kit.ImageKit.PixelMap
import ohos.business_exception.BusinessException
import kit.PerformanceAnalysisKit.Hilog

/**
 * ImageTransparencyBinding — 图片透明度检测平台封装层
 *
 * 对应 Telegram-iOS ImageTransparency.swift（使用 vImageHistogramCalculation_ARGB8888 分析 alpha 通道）。
 * 鸿蒙侧通过 PixelMap.readPixelsToBuffer 读取原始像素字节（BGRA_8888 格式），
 * 直接扫描 alpha 通道（偏移 3）统计透明/不透明像素比例。
 *
 * 提供：
 * - pixelMapHasTransparency：是否有超过 5% 的像素是透明或半透明的（对应 iOS imageHasTransparency）
 * - pixelMapHasSubject：是否有超过 5% 的像素是完全不透明的（对应 iOS imageHasSubject）
 *
 * 像素格式：BGRA_8888，每像素 4 字节，字节顺序为 [B, G, R, A]。
 * Alpha 通道在偏移 3，0 = 完全透明，255 = 完全不透明。
 * 与 iOS side（ARGB，alpha 在偏移 0 或 3 取决于 alphaInfo）逻辑等价。
 */

private var _imageTransparencyBindingInstance: Option<ImageTransparencyBinding> = None

/**
 * 获取 ImageTransparencyBinding 单例
 */
public func getImageTransparencyBinding(): ImageTransparencyBinding {
    match (_imageTransparencyBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ImageTransparencyBinding()
            _imageTransparencyBindingInstance = Some(inst)
            return inst
    }
}

/**
 * 图片透明度检测平台封装层
 */
public class ImageTransparencyBinding {

    /**
     * 检测 PixelMap 是否含有透明像素（透明像素占比 > 5%）
     *
     * 对应 iOS imageHasTransparency：
     *   alpha < 255 的像素数 / 总像素数 > 0.05 则返回 true
     *
     * pixelMap: 要检测的 PixelMap（BGRA_8888 格式）
     * 返回 true 表示图片含有显著透明区域（适合保存为 PNG / 贴纸处理等）
     */
    public func pixelMapHasTransparency(pixelMap: PixelMap): Bool {
        try {
            let totalBytes = Int64(pixelMap.getPixelBytesNumber())
            if (totalBytes < 4) {
                return false
            }

            let buf = Array<UInt8>(totalBytes, repeat: 0)
            pixelMap.readPixelsToBuffer(buf)

            // BGRA_8888: alpha 在每像素的第 4 字节（偏移 3）
            let bytesPerPixel: Int64 = 4
            let pixelCount = totalBytes / bytesPerPixel
            if (pixelCount <= 0) {
                return false
            }

            var transparentCount: Int64 = 0
            var i: Int64 = 0
            while (i < pixelCount) {
                let alpha = Int64(buf[i * bytesPerPixel + 3])
                if (alpha < 255) {
                    transparentCount = transparentCount + 1
                }
                i = i + 1
            }

            // 透明像素占比 > 5% 认为含有透明
            // 使用整数运算避免浮点：transparentCount * 100 > pixelCount * 5
            return (transparentCount * 100) > (pixelCount * 5)
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[ImageTransparencyBinding] pixelMapHasTransparency failed")
            return false
        }
    }

    /**
     * 检测 PixelMap 是否含有主体（完全不透明像素占比 > 5%）
     *
     * 对应 iOS imageHasSubject：
     *   alpha == 255 的像素数 / 总像素数 > 0.05 则返回 true
     * 用于判断图片是否有实质内容（非纯透明图片）
     *
     * pixelMap: 要检测的 PixelMap（BGRA_8888 格式）
     * 返回 true 表示图片含有显著不透明区域
     */
    public func pixelMapHasSubject(pixelMap: PixelMap): Bool {
        try {
            let totalBytes = Int64(pixelMap.getPixelBytesNumber())
            if (totalBytes < 4) {
                return false
            }

            let buf = Array<UInt8>(totalBytes, repeat: 0)
            pixelMap.readPixelsToBuffer(buf)

            let bytesPerPixel: Int64 = 4
            let pixelCount = totalBytes / bytesPerPixel
            if (pixelCount <= 0) {
                return false
            }

            var opaqueCount: Int64 = 0
            var i: Int64 = 0
            while (i < pixelCount) {
                let alpha = Int64(buf[i * bytesPerPixel + 3])
                if (alpha == 255) {
                    opaqueCount = opaqueCount + 1
                }
                i = i + 1
            }

            // 不透明像素占比 > 5% 认为有主体内容
            return (opaqueCount * 100) > (pixelCount * 5)
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[ImageTransparencyBinding] pixelMapHasSubject failed")
            return false
        }
    }
}
