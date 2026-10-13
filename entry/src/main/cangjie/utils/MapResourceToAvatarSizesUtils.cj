package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.getMapResourceToAvatarSizesBinding
import ohos_app_cangjie_entry.bindings.ImageRepresentationDimensions
import ohos_app_cangjie_entry.bindings.AvatarTargetSize
import std.collection.HashMap
import std.collection.ArrayList

/**
 * MapResourceToAvatarSizesUtils — 场所图标资源→头像尺寸映射上层工具接口
 *
 * 对应 Telegram-iOS MapResourceToAvatarSizes.swift 公开函数
 * mapResourceToAvatarSizes(engine:resource:representations:)。
 *
 * 提供：
 * - computeAvatarTargetSize：单个表示层尺寸 → 目标渲染尺寸（含 80→160 规则）
 * - buildAvatarSizeMap：批量映射，返回 index → AvatarTargetSize 的 HashMap
 * - buildAvatarSizeMapFromWidthsHeights：以并行宽/高数组作为输入的便捷重载
 */

/**
 * 计算单个图像表示层的目标渲染尺寸
 *
 * iOS 规则：若表示层宽度为 80，则强制目标尺寸为 160×160；
 * 其他情况目标尺寸等于表示层自身的 dimensions。
 *
 * @param width   图像表示层原始宽度（单位 pt）
 * @param height  图像表示层原始高度（单位 pt）
 * @return        目标渲染尺寸
 */
public func computeAvatarTargetSize(width: Int64, height: Int64): AvatarTargetSize {
    let dims = ImageRepresentationDimensions(width, height)
    return getMapResourceToAvatarSizesBinding().computeTargetSize(dims)
}

/**
 * 批量计算多个图像表示层的目标渲染尺寸映射表
 *
 * @param representations  图像表示层尺寸列表（按 index 顺序）
 * @return                 index → AvatarTargetSize 的 HashMap
 */
public func buildAvatarSizeMap(representations: Array<ImageRepresentationDimensions>): HashMap<Int64, AvatarTargetSize> {
    return getMapResourceToAvatarSizesBinding().buildSizeMap(representations)
}

/**
 * 批量计算多个图像表示层的目标渲染尺寸映射表（并行宽/高数组输入）
 *
 * 便捷重载，供调用方仅持有宽度/高度列表而非 ImageRepresentationDimensions 时使用。
 * widths 与 heights 长度必须相同，否则以两者中较短的长度截断。
 *
 * @param widths   各表示层宽度列表（单位 pt）
 * @param heights  各表示层高度列表（单位 pt）
 * @return         index → AvatarTargetSize 的 HashMap
 */
public func buildAvatarSizeMapFromWidthsHeights(widths: Array<Int64>, heights: Array<Int64>): HashMap<Int64, AvatarTargetSize> {
    let count: Int64 = if (Int64(widths.size) <= Int64(heights.size)) {
        Int64(widths.size)
    } else {
        Int64(heights.size)
    }
    let dimList = ArrayList<ImageRepresentationDimensions>()
    var i: Int64 = 0
    while (i < count) {
        dimList.add(ImageRepresentationDimensions(widths[i], heights[i]))
        i += 1
    }
    let immutable = dimList
    let dims = Array<ImageRepresentationDimensions>(immutable.size, { idx: Int64 => immutable[idx] })
    return getMapResourceToAvatarSizesBinding().buildSizeMap(dims)
}
