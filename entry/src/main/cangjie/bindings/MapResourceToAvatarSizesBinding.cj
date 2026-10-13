package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog
import std.collection.HashMap

/**
 * MapResourceToAvatarSizesBinding — 场所图标资源→头像尺寸映射平台封装层
 *
 * 对应 Telegram-iOS MapResourceToAvatarSizes.swift (mapResourceToAvatarSizes)。
 *
 * iOS 原始逻辑：
 *   给定媒体资源 + 表示层列表，对每个表示层 i 计算目标 CGSize：
 *   - 若 representations[i].dimensions.width == 80 → 强制目标尺寸 160×160
 *   - 否则 → 目标尺寸 = 表示层原始 dimensions
 *   返回 [Int: Data]（index → JPEG 数据）。
 *
 * 仓颉实现：
 *   纯逻辑映射层，不涉及实际图像缩放 / 网络 I/O。
 *   提供 computeTargetSize() 和 buildSizeMap() 两个核心能力：
 *   - computeTargetSize：单个表示层的目标尺寸计算（包含 80→160 特殊规则）
 *   - buildSizeMap：批量映射，返回 index → (width, height) 的 HashMap
 */

/**
 * 单个图像表示层的尺寸描述
 *
 * 对应 iOS TelegramMediaImageRepresentation.dimensions (CGSize)
 */
public class ImageRepresentationDimensions {
    public var width: Int64
    public var height: Int64

    public init(width: Int64, height: Int64) {
        this.width = width
        this.height = height
    }
}

/**
 * 目标头像渲染尺寸
 *
 * 对应 iOS CGSize (width, height)
 */
public class AvatarTargetSize {
    public var width: Int64
    public var height: Int64

    public init(width: Int64, height: Int64) {
        this.width = width
        this.height = height
    }
}

/**
 * 单例访问入口
 */
private var _mapResourceToAvatarSizesBindingInstance: Option<MapResourceToAvatarSizesBinding> = None

public func getMapResourceToAvatarSizesBinding(): MapResourceToAvatarSizesBinding {
    match (_mapResourceToAvatarSizesBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = MapResourceToAvatarSizesBinding()
            _mapResourceToAvatarSizesBindingInstance = Some(inst)
            return inst
    }
}

/**
 * 场所图标资源→头像尺寸映射封装层
 *
 * 对应 Telegram-iOS MapResourceToAvatarSizes.swift 的核心逻辑部分。
 * 提供平台无关的表示层尺寸→目标渲染尺寸映射能力。
 */
public class MapResourceToAvatarSizesBinding {

    /**
     * 计算单个图像表示层的目标渲染尺寸
     *
     * iOS 规则：若表示层宽度为 80pt，则强制使用 160×160 高分辨率目标；
     * 其他情况直接使用表示层自身的 dimensions。
     *
     * @param dimensions  图像表示层的原始尺寸
     * @return            目标渲染尺寸（用于图像缩放）
     */
    public func computeTargetSize(dimensions: ImageRepresentationDimensions): AvatarTargetSize {
        if (dimensions.width == 80) {
            Hilog.info(0, "CjTelegram", "[MRAS] width==80 -> upscale to 160x160")
            let up = AvatarTargetSize(Int64(160), Int64(160))
            return up
        }
        Hilog.info(0, "CjTelegram", "[MRAS] passthrough")
        let pass = AvatarTargetSize(dimensions.width, dimensions.height)
        return pass
    }

    /**
     * 批量计算多个图像表示层的目标渲染尺寸映射表
     *
     * 对应 iOS mapResourceToAvatarSizes 中遍历 representations 的 for 循环。
     * 返回 index → AvatarTargetSize 的 HashMap，key 为表示层索引（Int64）。
     *
     * @param representations  图像表示层尺寸列表（按 index 顺序）
     * @return                 index → 目标渲染尺寸 的映射表
     */
    public func buildSizeMap(representations: Array<ImageRepresentationDimensions>): HashMap<Int64, AvatarTargetSize> {
        let result = HashMap<Int64, AvatarTargetSize>()
        var i: Int64 = 0
        while (i < Int64(representations.size)) {
            let targetSize = this.computeTargetSize(representations[i])
            result[i] = targetSize
            i += 1
        }
        Hilog.info(0, "CjTelegram", "[MRAS] buildSizeMap: ${Int64(representations.size)} entries")
        return result
    }
}
