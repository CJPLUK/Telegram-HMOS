package ohos_app_cangjie_entry.bindings

import kit.ImageKit.{createImageSource, createImagePacker, PixelMap, ImageSource, SourceOptions, PackingOption}
import ohos.business_exception.BusinessException
import kit.PerformanceAnalysisKit.Hilog

/**
 * WebPBindingBinding — WebP 图片解码/编码平台封装层
 *
 * 对应 Telegram-iOS submodules/WebPBinding（WebP.convertFromWebP / WebP.convertToWebP）。
 * 鸿蒙侧通过 ImageKit createImageSource + createPixelMap 原生支持 WebP 解码，
 * 通过 ImagePacker packToData 原生支持 WebP 编码（lossless）。
 *
 * 提供：
 * - decodeWebP：将 WebP 字节流解码为 PixelMap（对应 iOS convertFromWebP）
 * - encodeWebP：将 PixelMap 编码为 WebP 字节流（对应 iOS convertToWebP）
 */

private var _webPBindingInstance: Option<WebPBindingBinding> = None

/**
 * 获取 WebPBindingBinding 单例
 */
public func getWebPBindingBinding(): WebPBindingBinding {
    match (_webPBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = WebPBindingBinding()
            _webPBindingInstance = Some(inst)
            return inst
    }
}

/**
 * WebP 图片解码/编码平台封装层
 */
public class WebPBindingBinding {

    /**
     * 将 WebP 格式字节流解码为 PixelMap
     *
     * 对应 iOS +[WebP convertFromWebP:]，使用 BGRA 解码。
     * 鸿蒙 ImageKit 原生支持 webp 格式（见 ImageSource.supportedFormats），
     * 通过 createImageSource(Array<UInt8>) → createPixelMap() 完成解码。
     *
     * @param data  WebP 格式的字节数据
     * @return 解码后的 PixelMap，数据无效时返回 None
     */
    public func decodeWebP(data: Array<UInt8>): Option<PixelMap> {
        if (data.size == 0) {
            return None
        }
        try {
            let imageSource: ImageSource = createImageSource(data, SourceOptions(0))
            let pixelMap: PixelMap = imageSource.createPixelMap()
            return Some(pixelMap)
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[WebPBindingBinding] decodeWebP failed")
            return None
        }
    }

    /**
     * 将 PixelMap 编码为 WebP 格式字节流
     *
     * 对应 iOS +[WebP convertToWebP:quality:error:]。
     * 鸿蒙 ImageKit ImagePacker 支持 "image/webp" 无损编码。
     * quality 参数与 iOS 兼容：范围 0-100，WebP 在 ImageKit 中为无损编码，
     * quality 值由 PackingOption 接受但对 WebP 格式不影响压缩质量（无损）。
     *
     * @param pixelMap  源 PixelMap
     * @param quality   质量参数（0-100），对应 iOS quality CGFloat，传入 UInt8
     * @return 编码后的 WebP 字节数据，失败时返回 None
     */
    public func encodeWebP(pixelMap: PixelMap, quality: UInt8): Option<Array<UInt8>> {
        try {
            let imagePacker = createImagePacker()
            let packingOption = PackingOption("image/webp", quality)
            let result: Array<UInt8> = imagePacker.packToData(pixelMap, packingOption)
            if (result.size == 0) {
                Hilog.info(0, "CjTelegram", "[WebPBindingBinding] encodeWebP produced empty output")
                return None
            }
            return Some(result)
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[WebPBindingBinding] encodeWebP failed")
            return None
        }
    }
}
