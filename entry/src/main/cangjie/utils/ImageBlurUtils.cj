package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.{getImageBlurBinding}
import kit.ImageKit.PixelMap

/**
 * ImageBlurUtils — 图片模糊高层工具接口
 *
 * 对应 Telegram-iOS ImageBlur.swift 公开函数（blurredImage / verticalBlurredImage）。
 * 供缩略图占位模糊、blurhash 类效果等场景调用。
 *
 * 提供：
 * - blurredPixelMap：等宽等高盒状模糊（对应 iOS blurredImage，默认 3 次迭代）
 * - verticalBlurredPixelMap：仅垂直方向盒状模糊（对应 iOS verticalBlurredImage，默认 3 次迭代）
 * - thumbnailPlaceholderBlur：缩略图占位模糊便捷方法（固定 radius=8，3 次迭代）
 */

/**
 * 对 PixelMap 应用等宽等高盒状模糊
 * pixelMap: 源 PixelMap（需为 BGRA_8888 格式且可编辑）
 * radius: 模糊半径（像素），radius <= 0 时原样返回
 * iterations: 迭代次数（默认 3，与 iOS 默认值一致）
 * 返回 模糊后的新 PixelMap，失败时返回 None
 */
public func blurredPixelMap(pixelMap: PixelMap, radius: Int32, iterations!: Int32 = 3): Option<PixelMap> {
    return getImageBlurBinding().blurPixelMap(pixelMap, radius, iterations)
}

/**
 * 对 PixelMap 应用仅垂直方向盒状模糊
 * pixelMap: 源 PixelMap（需为 BGRA_8888 格式且可编辑）
 * radius: 垂直模糊半径（像素），radius <= 0 时原样返回
 * iterations: 迭代次数（默认 3，与 iOS 默认值一致）
 * 返回 模糊后的新 PixelMap，失败时返回 None
 */
public func verticalBlurredPixelMap(pixelMap: PixelMap, radius: Int32, iterations!: Int32 = 3): Option<PixelMap> {
    return getImageBlurBinding().verticalBlurPixelMap(pixelMap, radius, iterations)
}

/**
 * 缩略图占位模糊便捷方法
 * 使用固定的 radius=8、3 次迭代，模拟 blurhash / 低清占位效果。
 * pixelMap: 源 PixelMap
 * 返回 模糊后的新 PixelMap，失败时返回 None
 */
public func thumbnailPlaceholderBlur(pixelMap: PixelMap): Option<PixelMap> {
    return getImageBlurBinding().blurPixelMap(pixelMap, 8, 3)
}
