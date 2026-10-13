package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.{getWebPBindingBinding}
import kit.ImageKit.PixelMap

/**
 * WebPBindingUtils — WebP 图片处理高层工具接口
 *
 * 对应 Telegram-iOS submodules/WebPBinding 公开接口
 * （WebP.convertFromWebP / WebP.convertToWebP）。
 *
 * 提供：
 * - decodeWebPData：将 WebP 字节流解码为 PixelMap（对应 iOS convertFromWebP:）
 * - encodeWebPData：将 PixelMap 编码为 WebP 字节流（对应 iOS convertToWebP:quality:error:）
 * - encodeWebPDataDefault：使用默认质量 80 编码（便捷方法）
 */

/**
 * 将 WebP 格式字节流解码为 PixelMap
 *
 * data: WebP 编码的字节数据
 * 返回 解码后的 PixelMap，数据无效或格式不支持时返回 None
 */
public func decodeWebPData(data: Array<UInt8>): Option<PixelMap> {
    return getWebPBindingBinding().decodeWebP(data)
}

/**
 * 将 PixelMap 编码为 WebP 格式字节流
 *
 * pixelMap: 源 PixelMap
 * quality: 质量参数（0-100），对应 iOS CGFloat quality（转为 UInt8 传入）
 * 返回 WebP 编码后的字节数据，失败时返回 None
 */
public func encodeWebPData(pixelMap: PixelMap, quality: UInt8): Option<Array<UInt8>> {
    return getWebPBindingBinding().encodeWebP(pixelMap, quality)
}

/**
 * 使用默认质量（80）将 PixelMap 编码为 WebP 字节流
 *
 * pixelMap: 源 PixelMap
 * 返回 WebP 编码后的字节数据，失败时返回 None
 */
public func encodeWebPDataDefault(pixelMap: PixelMap): Option<Array<UInt8>> {
    return getWebPBindingBinding().encodeWebP(pixelMap, 80)
}
