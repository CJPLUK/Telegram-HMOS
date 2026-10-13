package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.getImageTransparencyBinding
import kit.ImageKit.PixelMap

/**
 * ImageTransparencyUtils — 图片透明度检测高层工具接口
 *
 * 对应 Telegram-iOS ImageTransparency.swift 公开函数：
 *   - imageHasTransparency(_:)  →  hasTransparency(pixelMap:)
 *   - imageHasSubject(_:)       →  hasSubject(pixelMap:)
 *
 * 使用场景：
 * - 判断图片是否含透明像素，决定保存为 PNG（保留透明）还是 JPEG（不透明更小）
 * - 贴纸处理：含透明的图片作为贴纸叠层
 * - 消息气泡中的图片预览透明区域判断
 */

/**
 * 检测 PixelMap 是否含有透明像素（alpha < 255 的像素占比 > 5%）
 *
 * pixelMap: 要检测的 PixelMap，BGRA_8888 格式
 * 返回 true 表示图片含有显著透明区域
 */
public func hasTransparency(pixelMap: PixelMap): Bool {
    return getImageTransparencyBinding().pixelMapHasTransparency(pixelMap)
}

/**
 * 检测 PixelMap 是否含有主体（完全不透明像素占比 > 5%）
 *
 * pixelMap: 要检测的 PixelMap，BGRA_8888 格式
 * 返回 true 表示图片含有显著不透明区域（有实际内容）
 */
public func hasSubject(pixelMap: PixelMap): Bool {
    return getImageTransparencyBinding().pixelMapHasSubject(pixelMap)
}

/**
 * 根据透明度检测推断首选图片格式
 *
 * 含透明像素 → 推荐 PNG（保留 alpha 通道）
 * 无透明像素 → 推荐 JPEG（体积更小）
 *
 * pixelMap: 要检测的 PixelMap
 * 返回 "png" 或 "jpeg"
 */
public func preferredImageFormat(pixelMap: PixelMap): String {
    if (getImageTransparencyBinding().pixelMapHasTransparency(pixelMap)) {
        return "png"
    }
    return "jpeg"
}
