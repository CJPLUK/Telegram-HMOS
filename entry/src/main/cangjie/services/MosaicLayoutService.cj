package ohos_app_cangjie_entry.services

import std.math.*

/**
 * 马赛克布局位置标记（复刻 iOS MosaicItemPosition OptionSet）
 *
 * 使用 Int32 位集合模拟 OptionSet 语义：
 *   top    = 1
 *   bottom = 2
 *   left   = 4
 *   right  = 8
 *   inside = 16
 *   unknown = 65536
 */
public class MosaicItemPosition {
    public var rawValue: Int32

    public init(rawValue!: Int32) {
        this.rawValue = rawValue
    }

    public static let top: MosaicItemPosition = MosaicItemPosition(rawValue: 1)
    public static let bottom: MosaicItemPosition = MosaicItemPosition(rawValue: 2)
    public static let left: MosaicItemPosition = MosaicItemPosition(rawValue: 4)
    public static let right: MosaicItemPosition = MosaicItemPosition(rawValue: 8)
    public static let inside: MosaicItemPosition = MosaicItemPosition(rawValue: 16)
    public static let unknown: MosaicItemPosition = MosaicItemPosition(rawValue: 65536)
    public static let none: MosaicItemPosition = MosaicItemPosition(rawValue: 0)

    public func contains(flag!: MosaicItemPosition): Bool {
        (this.rawValue & flag.rawValue) != 0
    }

    public func union(flag!: MosaicItemPosition): MosaicItemPosition {
        MosaicItemPosition(rawValue: this.rawValue | flag.rawValue)
    }

    public func isWide(): Bool {
        this.contains(flag: MosaicItemPosition.left) &&
        this.contains(flag: MosaicItemPosition.right) &&
        (this.contains(flag: MosaicItemPosition.top) || this.contains(flag: MosaicItemPosition.bottom))
    }
}

/**
 * 单张图片的马赛克布局结果：在拼贴区域内的矩形位置和边缘位置标记
 */
public class MosaicItemResult {
    public var x: Float64        // 左上角 x（vp，相对拼贴容器左上角）
    public var y: Float64        // 左上角 y（vp）
    public var width: Float64    // 图片宽度（vp）
    public var height: Float64   // 图片高度（vp）
    public var position: MosaicItemPosition  // 边缘标记

    public init(x!: Float64, y!: Float64, width!: Float64, height!: Float64, position!: MosaicItemPosition) {
        this.x = x
        this.y = y
        this.width = width
        this.height = height
        this.position = position
    }
}

/**
 * 马赛克布局计算结果
 */
public class MosaicLayoutResult {
    public var items: Array<MosaicItemResult>
    public var totalWidth: Float64
    public var totalHeight: Float64

    public init(items!: Array<MosaicItemResult>, totalWidth!: Float64, totalHeight!: Float64) {
        this.items = items
        this.totalWidth = totalWidth
        this.totalHeight = totalHeight
    }
}

/**
 * 输入图片尺寸
 */
public class MosaicImageSize {
    public var width: Float64
    public var height: Float64

    public init(width!: Float64, height!: Float64) {
        this.width = width
        this.height = height
    }
}

// ====== 内部工作数据结构 ======

private class ItemInfo {
    var index: Int64
    var imageWidth: Float64
    var imageHeight: Float64
    var aspectRatio: Float64

    var frameX: Float64 = 0.0
    var frameY: Float64 = 0.0
    var frameW: Float64 = 0.0
    var frameH: Float64 = 0.0
    var position: MosaicItemPosition = MosaicItemPosition.none

    init(index!: Int64, imageWidth!: Float64, imageHeight!: Float64, aspectRatio!: Float64) {
        this.index = index
        this.imageWidth = imageWidth
        this.imageHeight = imageHeight
        this.aspectRatio = aspectRatio
    }
}

private class LayoutAttempt {
    var lineCounts: Array<Int64>
    var heights: Array<Float64>

    init(lineCounts!: Array<Int64>, heights!: Array<Float64>) {
        this.lineCounts = lineCounts
        this.heights = heights
    }
}

// ====== 算法辅助函数 ======

private func flr(v: Float64): Float64 {
    Float64(Int64(v))
}

private func rnd(v: Float64): Float64 {
    Float64(Int64(v + 0.5))
}

private func cl(v: Float64): Float64 {
    let i = Int64(v)
    if (Float64(i) < v) { Float64(i + 1) } else { Float64(i) }
}

private func mn(a: Float64, b: Float64): Float64 {
    if (a < b) { a } else { b }
}

private func mx(a: Float64, b: Float64): Float64 {
    if (a > b) { a } else { b }
}

private func abs64(v!: Float64): Float64 {
    if (v < 0.0) { -v } else { v }
}

/**
 * 多图行高公式：行内所有图按 croppedRatio 排开，总宽 = maxWidth；计算统一行高
 */
private func multiHeight(ratios!: Array<Float64>, ratioCount!: Int64, maxWidth!: Float64, spacing!: Float64): Float64 {
    var ratioSum: Float64 = 0.0
    var i: Int64 = 0
    while (i < ratioCount) {
        ratioSum += ratios[i]
        i += 1
    }
    (maxWidth - Float64(ratioCount - 1) * spacing) / ratioSum
}

/**
 * 计算马赛克拼贴布局（真实复刻 iOS chatMessageBubbleMosaicLayout）
 *
 * 参数：
 *   maxWidth / maxHeight  — 可用区域尺寸（vp）
 *   itemSizes             — 各图原始尺寸
 *   spacing               — 图片间距（默认 1.0 vp）
 *
 * 返回：MosaicLayoutResult，含每张图的 (x, y, w, h, position) 及总尺寸。
 *
 * 此函数是纯布局算法，无网络/TL 依赖（iOS 原版同样无 MTProto，仅做几何计算）。
 */
public func computeMosaicLayout(
    maxWidth!: Float64,
    maxHeight!: Float64,
    itemSizes!: Array<MosaicImageSize>,
    spacing!: Float64
): MosaicLayoutResult {
    let count = itemSizes.size
    if (count == 0) {
        return MosaicLayoutResult(
            items: Array<MosaicItemResult>(0, { _i: Int64 => MosaicItemResult(x: 0.0, y: 0.0, width: 0.0, height: 0.0, position: MosaicItemPosition.none) }),
            totalWidth: 0.0,
            totalHeight: 0.0
        )
    }

    // ---- 预处理：计算宽高比和比例字符串 ----
    var proportions: String = ""
    var averageAspectRatio: Float64 = 0.0
    var forceCalc: Bool = false

    let items = Array<ItemInfo>(count, { i: Int64 =>
        let sz = itemSizes[i]
        let ar = if (sz.height == 0.0) { 1.0 } else { sz.width / sz.height }
        ItemInfo(index: i, imageWidth: sz.width, imageHeight: sz.height, aspectRatio: ar)
    })

    var pi: Int64 = 0
    while (pi < count) {
        let ar = items[pi].aspectRatio
        if (ar > 1.2) {
            proportions = proportions + "w"
        } else if (ar < 0.8) {
            proportions = proportions + "n"
        } else {
            proportions = proportions + "q"
        }
        if (ar > 2.0) { forceCalc = true }
        averageAspectRatio += ar
        pi += 1
    }
    averageAspectRatio = averageAspectRatio / Float64(count)

    let minWidth: Float64 = 68.0
    let minHeight: Float64 = 81.0
    let maxAspectRatio: Float64 = if (maxHeight == 0.0) { 1.0 } else { maxWidth / maxHeight }

    // ---- 特殊情况处理（1-4 张图）----
    if (!forceCalc) {
        if (count == 1) {
            let sz = itemSizes[0]
            let ar = items[0].aspectRatio
            let h = mn(maxHeight, flr(maxWidth / ar))
            let w = maxWidth
            items[0].frameX = 0.0
            items[0].frameY = 0.0
            items[0].frameW = w
            items[0].frameH = h
            items[0].position = MosaicItemPosition.top.union(flag: MosaicItemPosition.bottom).union(flag: MosaicItemPosition.left).union(flag: MosaicItemPosition.right)
        } else if (count == 2) {
            if (proportions == "ww" && averageAspectRatio > 1.4 * maxAspectRatio &&
                items[1].aspectRatio - items[0].aspectRatio < 0.2) {
                // 横向两图竖排
                let w = maxWidth
                let h = flr(mn(w / items[0].aspectRatio, mn(w / items[1].aspectRatio, (maxHeight - spacing) / 2.0)))
                items[0].frameX = 0.0; items[0].frameY = 0.0; items[0].frameW = w; items[0].frameH = h
                items[0].position = MosaicItemPosition.top.union(flag: MosaicItemPosition.left).union(flag: MosaicItemPosition.right)
                items[1].frameX = 0.0; items[1].frameY = h + spacing; items[1].frameW = w; items[1].frameH = h
                items[1].position = MosaicItemPosition.bottom.union(flag: MosaicItemPosition.left).union(flag: MosaicItemPosition.right)
            } else if (proportions == "ww" || proportions == "qq") {
                // 同类两图横排
                let w = (maxWidth - spacing) / 2.0
                let h = flr(mn(w / items[0].aspectRatio, mn(w / items[1].aspectRatio, maxHeight)))
                items[0].frameX = 0.0; items[0].frameY = 0.0; items[0].frameW = w; items[0].frameH = h
                items[0].position = MosaicItemPosition.top.union(flag: MosaicItemPosition.left).union(flag: MosaicItemPosition.bottom)
                items[1].frameX = w + spacing; items[1].frameY = 0.0; items[1].frameW = w; items[1].frameH = h
                items[1].position = MosaicItemPosition.top.union(flag: MosaicItemPosition.right).union(flag: MosaicItemPosition.bottom)
            } else {
                // 宽高不同，按宽高比划分宽度
                let secondWidth = flr(mn(0.5 * (maxWidth - spacing),
                    rnd((maxWidth - spacing) / items[0].aspectRatio /
                        (1.0 / items[0].aspectRatio + 1.0 / items[1].aspectRatio))))
                let firstWidth = maxWidth - secondWidth - spacing
                let h = flr(mn(maxHeight, rnd(mn(firstWidth / items[0].aspectRatio, secondWidth / items[1].aspectRatio))))
                items[0].frameX = 0.0; items[0].frameY = 0.0; items[0].frameW = firstWidth; items[0].frameH = h
                items[0].position = MosaicItemPosition.top.union(flag: MosaicItemPosition.left).union(flag: MosaicItemPosition.bottom)
                items[1].frameX = firstWidth + spacing; items[1].frameY = 0.0; items[1].frameW = secondWidth; items[1].frameH = h
                items[1].position = MosaicItemPosition.top.union(flag: MosaicItemPosition.right).union(flag: MosaicItemPosition.bottom)
            }
        } else if (count == 3) {
            // 判断第一张是否为竖向
            let firstRune = proportions.toRuneArray()
            let firstChar = if (firstRune.size > 0) { firstRune[0].toString() } else { "" }
            if (firstChar == "n") {
                // 第一张竖向：左边占全高，右边两张上下排
                let firstHeight = maxHeight
                let thirdHeight = mn((maxHeight - spacing) * 0.5,
                    rnd(items[1].aspectRatio * (maxWidth - spacing) /
                        (items[2].aspectRatio + items[1].aspectRatio)))
                let secondHeight = maxHeight - thirdHeight - spacing
                var rightWidth = mx(minWidth, mn((maxWidth - spacing) * 0.5,
                    rnd(mn(thirdHeight * items[2].aspectRatio, secondHeight * items[1].aspectRatio))))
                let leftWidth = rnd(mn(firstHeight * items[0].aspectRatio, maxWidth - spacing - rightWidth))
                items[0].frameX = 0.0; items[0].frameY = 0.0; items[0].frameW = leftWidth; items[0].frameH = firstHeight
                items[0].position = MosaicItemPosition.top.union(flag: MosaicItemPosition.left).union(flag: MosaicItemPosition.bottom)
                items[1].frameX = leftWidth + spacing; items[1].frameY = 0.0; items[1].frameW = rightWidth; items[1].frameH = secondHeight
                items[1].position = MosaicItemPosition.right.union(flag: MosaicItemPosition.top)
                items[2].frameX = leftWidth + spacing; items[2].frameY = secondHeight + spacing; items[2].frameW = rightWidth; items[2].frameH = thirdHeight
                items[2].position = MosaicItemPosition.right.union(flag: MosaicItemPosition.bottom)
            } else {
                // 第一张宽/方：上占全宽，下两张横排
                let w = maxWidth
                let firstHeight = flr(mn(w / items[0].aspectRatio, (maxHeight - spacing) * 0.66))
                items[0].frameX = 0.0; items[0].frameY = 0.0; items[0].frameW = w; items[0].frameH = firstHeight
                items[0].position = MosaicItemPosition.top.union(flag: MosaicItemPosition.left).union(flag: MosaicItemPosition.right)
                let halfW = (maxWidth - spacing) / 2.0
                let secondHeight = mn(maxHeight - firstHeight - spacing,
                    rnd(mn(halfW / items[1].aspectRatio, halfW / items[2].aspectRatio)))
                items[1].frameX = 0.0; items[1].frameY = firstHeight + spacing; items[1].frameW = halfW; items[1].frameH = secondHeight
                items[1].position = MosaicItemPosition.left.union(flag: MosaicItemPosition.bottom)
                items[2].frameX = halfW + spacing; items[2].frameY = firstHeight + spacing; items[2].frameW = halfW; items[2].frameH = secondHeight
                items[2].position = MosaicItemPosition.right.union(flag: MosaicItemPosition.bottom)
            }
        } else if (count == 4) {
            let firstRune = proportions.toRuneArray()
            let firstChar = if (firstRune.size > 0) { firstRune[0].toString() } else { "" }
            let isAllW: Bool = (proportions == "wwww" || firstChar == "w")
            if (isAllW) {
                // 横向为主：第一张全宽，下三张横排
                let w = maxWidth
                let h0 = rnd(mn(w / items[0].aspectRatio, (maxHeight - spacing) * 0.66))
                items[0].frameX = 0.0; items[0].frameY = 0.0; items[0].frameW = w; items[0].frameH = h0
                items[0].position = MosaicItemPosition.top.union(flag: MosaicItemPosition.left).union(flag: MosaicItemPosition.right)
                var h = rnd((maxWidth - 2.0 * spacing) / (items[1].aspectRatio + items[2].aspectRatio + items[3].aspectRatio))
                let w0 = mx(minWidth, mn((maxWidth - 2.0 * spacing) * 0.4, h * items[1].aspectRatio))
                let w2 = mx(mx(minWidth, (maxWidth - 2.0 * spacing) * 0.33), h * items[3].aspectRatio)
                let w1 = w - w0 - w2 - 2.0 * spacing
                h = mx(minHeight, mn(maxHeight - h0 - spacing, h))
                items[1].frameX = 0.0; items[1].frameY = h0 + spacing; items[1].frameW = w0; items[1].frameH = h
                items[1].position = MosaicItemPosition.left.union(flag: MosaicItemPosition.bottom)
                items[2].frameX = w0 + spacing; items[2].frameY = h0 + spacing; items[2].frameW = w1; items[2].frameH = h
                items[2].position = MosaicItemPosition.bottom
                items[3].frameX = w0 + w1 + 2.0 * spacing; items[3].frameY = h0 + spacing; items[3].frameW = w2; items[3].frameH = h
                items[3].position = MosaicItemPosition.right.union(flag: MosaicItemPosition.bottom)
            } else {
                // 竖向为主：第一张全高，右边三张竖排
                let h = maxHeight
                let w0 = rnd(mn(h * items[0].aspectRatio, (maxWidth - spacing) * 0.6))
                items[0].frameX = 0.0; items[0].frameY = 0.0; items[0].frameW = w0; items[0].frameH = h
                items[0].position = MosaicItemPosition.top.union(flag: MosaicItemPosition.left).union(flag: MosaicItemPosition.bottom)
                var w = rnd((maxHeight - 2.0 * spacing) /
                    (1.0 / items[1].aspectRatio + 1.0 / items[2].aspectRatio + 1.0 / items[3].aspectRatio))
                let rh0 = flr(w / items[1].aspectRatio)
                let rh1 = flr(w / items[2].aspectRatio)
                let rh2 = h - rh0 - rh1 - 2.0 * spacing
                w = mx(minWidth, mn(maxWidth - w0 - spacing, w))
                items[1].frameX = w0 + spacing; items[1].frameY = 0.0; items[1].frameW = w; items[1].frameH = rh0
                items[1].position = MosaicItemPosition.right.union(flag: MosaicItemPosition.top)
                items[2].frameX = w0 + spacing; items[2].frameY = rh0 + spacing; items[2].frameW = w; items[2].frameH = rh1
                items[2].position = MosaicItemPosition.right
                items[3].frameX = w0 + spacing; items[3].frameY = rh0 + rh1 + 2.0 * spacing; items[3].frameW = w; items[3].frameH = rh2
                items[3].position = MosaicItemPosition.right.union(flag: MosaicItemPosition.bottom)
            }
        }
    }

    // ---- 通用计算路径（5+ 张图，或 forceCalc）----
    if (forceCalc || count >= 5) {
        // 快照 var 变量为 immutable，供 lambda 安全捕获
        let avgAR = averageAspectRatio
        let itemsRef = items
        // 裁剪宽高比到合理范围
        let croppedRatios = Array<Float64>(count, { i: Int64 =>
            let ar = itemsRef[i].aspectRatio
            var cr = if (avgAR > 1.1) { mx(1.0, ar) } else { mn(1.0, ar) }
            cr = mx(0.66667, mn(1.7, cr))
            cr
        })

        // 枚举 2-4 行的所有分割方案
        let maxAttempts: Int64 = 128
        let attemptBuf = Array<LayoutAttempt>(maxAttempts, { _i: Int64 =>
            LayoutAttempt(lineCounts: Array<Int64>(0, { _j: Int64 => Int64(0) }), heights: Array<Float64>(0, { _j: Int64 => 0.0 }))
        })
        var attemptCount: Int64 = 0

        // 2 行分割
        var f1: Int64 = 1
        while (f1 < count) {
            let s1 = count - f1
            if (f1 <= 3 && s1 <= 3 && attemptCount < maxAttempts) {
                // 快照 mutable 循环变量为 immutable，供 lambda 捕获
                let cf1 = f1
                let cs1 = s1
                let lc = Array<Int64>(2, { i: Int64 => if (i == 0) { cf1 } else { cs1 } })
                let cref = croppedRatios
                let hr0 = Array<Float64>(cf1, { i: Int64 => cref[i] })
                let hr1Arr = Array<Float64>(cs1, { i: Int64 => cref[cf1 + i] })
                let h0 = multiHeight(ratios: hr0, ratioCount: cf1, maxWidth: maxWidth, spacing: spacing)
                let h1 = multiHeight(ratios: hr1Arr, ratioCount: cs1, maxWidth: maxWidth, spacing: spacing)
                let hs = Array<Float64>(2, { i: Int64 => if (i == 0) { h0 } else { h1 } })
                attemptBuf[attemptCount] = LayoutAttempt(lineCounts: lc, heights: hs)
                attemptCount += 1
            }
            f1 += 1
        }

        // 3 行分割
        f1 = 1
        while (f1 < count - 1) {
            var f2: Int64 = 1
            while (f2 < count - f1) {
                let f3 = count - f1 - f2
                let maxF2 = if (averageAspectRatio < 0.85) { Int64(4) } else { Int64(3) }
                if (f1 <= 3 && f2 <= maxF2 && f3 <= 3 && attemptCount < maxAttempts) {
                    let cf1 = f1; let cf2 = f2; let cf3 = f3
                    let cref = croppedRatios
                    let lc = Array<Int64>(3, { i: Int64 => if (i == 0) { cf1 } else if (i == 1) { cf2 } else { cf3 } })
                    let hr0 = Array<Float64>(cf1, { i: Int64 => cref[i] })
                    let hr1Arr = Array<Float64>(cf2, { i: Int64 => cref[cf1 + i] })
                    let hr2Arr = Array<Float64>(cf3, { i: Int64 => cref[cf1 + cf2 + i] })
                    let h0 = multiHeight(ratios: hr0, ratioCount: cf1, maxWidth: maxWidth, spacing: spacing)
                    let h1 = multiHeight(ratios: hr1Arr, ratioCount: cf2, maxWidth: maxWidth, spacing: spacing)
                    let h2 = multiHeight(ratios: hr2Arr, ratioCount: cf3, maxWidth: maxWidth, spacing: spacing)
                    let hs = Array<Float64>(3, { i: Int64 => if (i == 0) { h0 } else if (i == 1) { h1 } else { h2 } })
                    attemptBuf[attemptCount] = LayoutAttempt(lineCounts: lc, heights: hs)
                    attemptCount += 1
                }
                f2 += 1
            }
            f1 += 1
        }

        // 4 行分割
        if (count >= 4) {
            f1 = 1
            while (f1 < count - 2) {
                var f2: Int64 = 1
                while (f2 < count - f1) {
                    var f3: Int64 = 1
                    while (f3 < count - f1 - f2) {
                        let f4 = count - f1 - f2 - f3
                        if (f1 <= 3 && f2 <= 3 && f3 <= 3 && f4 <= 3 && f4 >= 1 && attemptCount < maxAttempts) {
                            let cf1 = f1; let cf2 = f2; let cf3 = f3; let cf4 = f4
                            let cref = croppedRatios
                            let lc = Array<Int64>(4, { i: Int64 =>
                                if (i == 0) { cf1 } else if (i == 1) { cf2 } else if (i == 2) { cf3 } else { cf4 }
                            })
                            let hr0 = Array<Float64>(cf1, { i: Int64 => cref[i] })
                            let hr1Arr = Array<Float64>(cf2, { i: Int64 => cref[cf1 + i] })
                            let hr2Arr = Array<Float64>(cf3, { i: Int64 => cref[cf1 + cf2 + i] })
                            let hr3Arr = Array<Float64>(cf4, { i: Int64 => cref[cf1 + cf2 + cf3 + i] })
                            let h0 = multiHeight(ratios: hr0, ratioCount: cf1, maxWidth: maxWidth, spacing: spacing)
                            let h1 = multiHeight(ratios: hr1Arr, ratioCount: cf2, maxWidth: maxWidth, spacing: spacing)
                            let h2 = multiHeight(ratios: hr2Arr, ratioCount: cf3, maxWidth: maxWidth, spacing: spacing)
                            let h3 = multiHeight(ratios: hr3Arr, ratioCount: cf4, maxWidth: maxWidth, spacing: spacing)
                            let hs = Array<Float64>(4, { i: Int64 =>
                                if (i == 0) { h0 } else if (i == 1) { h1 } else if (i == 2) { h2 } else { h3 }
                            })
                            attemptBuf[attemptCount] = LayoutAttempt(lineCounts: lc, heights: hs)
                            attemptCount += 1
                        }
                        f3 += 1
                    }
                    f2 += 1
                }
                f1 += 1
            }
        }

        // 选出最优方案（总高度最接近 maxWidth * 4/3，行数递增惩罚，行高太小惩罚）
        let targetHeight: Float64 = flr(maxWidth / 3.0 * 4.0)
        var optimalIdx: Int64 = -1
        var optimalDiff: Float64 = 0.0

        var ai: Int64 = 0
        while (ai < attemptCount) {
            let attempt = attemptBuf[ai]
            let lineCount = attempt.lineCounts.size
            var totalH: Float64 = spacing * Float64(lineCount - 1)
            var minLineH: Float64 = 999999.0
            var li: Int64 = 0
            while (li < lineCount) {
                let fh = flr(attempt.heights[li])
                totalH += fh
                if (fh < minLineH) { minLineH = fh }
                li += 1
            }
            var diff = abs64(v: totalH - targetHeight)
            // 惩罚：行数递减（后行多于前行）
            if (lineCount > 1) {
                var lii: Int64 = 0
                while (lii < lineCount - 1) {
                    if (attempt.lineCounts[lii] > attempt.lineCounts[lii + 1]) {
                        diff *= 1.5
                    }
                    lii += 1
                }
            }
            if (minLineH < minWidth) { diff *= 1.5 }
            if (optimalIdx < 0 || diff < optimalDiff) {
                optimalIdx = ai
                optimalDiff = diff
            }
            ai += 1
        }

        // 按最优方案填充各图 frame
        if (optimalIdx >= 0) {
            let opt = attemptBuf[optimalIdx]
            let lineCount = opt.lineCounts.size
            var idx: Int64 = 0
            var y: Float64 = 0.0

            var li: Int64 = 0
            while (li < lineCount) {
                let lineItems = opt.lineCounts[li]
                let lineH = cl(opt.heights[li])
                var x: Float64 = 0.0
                var posFlags = MosaicItemPosition.none
                if (li == 0) { posFlags = posFlags.union(flag: MosaicItemPosition.top) }
                if (li == lineCount - 1) { posFlags = posFlags.union(flag: MosaicItemPosition.bottom) }

                var ki: Int64 = 0
                while (ki < lineItems) {
                    var innerFlags = posFlags
                    if (ki == 0) { innerFlags = innerFlags.union(flag: MosaicItemPosition.left) }
                    if (ki == lineItems - 1) { innerFlags = innerFlags.union(flag: MosaicItemPosition.right) }
                    if (posFlags.rawValue == 0) { innerFlags = MosaicItemPosition.inside }

                    let ratio = croppedRatios[idx]
                    let tileW = cl(ratio * lineH)
                    items[idx].frameX = x
                    items[idx].frameY = y
                    items[idx].frameW = tileW
                    items[idx].frameH = lineH
                    items[idx].position = innerFlags

                    x += tileW + spacing
                    idx += 1
                    ki += 1
                }
                y += lineH + spacing
                li += 1
            }

            // 对齐每行最后一个图块到最大宽度（修正浮点误差）
            idx = 0
            var maxW: Float64 = 0.0
            li = 0
            while (li < lineCount) {
                let lineItems = opt.lineCounts[li]
                var ki: Int64 = 0
                while (ki < lineItems) {
                    if (ki == lineItems - 1) {
                        let right = items[idx].frameX + items[idx].frameW
                        if (right > maxW) { maxW = right }
                    }
                    idx += 1
                    ki += 1
                }
                li += 1
            }
            idx = 0
            li = 0
            while (li < lineCount) {
                let lineItems = opt.lineCounts[li]
                var ki: Int64 = 0
                while (ki < lineItems) {
                    if (ki == lineItems - 1) {
                        let right = items[idx].frameX + items[idx].frameW
                        if (maxW > right) { items[idx].frameW += maxW - right }
                    }
                    idx += 1
                    ki += 1
                }
                li += 1
            }
        }
    }

    // ---- 计算总尺寸 ----
    var dimW: Float64 = 0.0
    var dimH: Float64 = 0.0
    var qi: Int64 = 0
    while (qi < count) {
        let r = items[qi].frameX + items[qi].frameW
        let b = items[qi].frameY + items[qi].frameH
        if (r > dimW) { dimW = r }
        if (b > dimH) { dimH = b }
        qi += 1
    }

    let resultItems = Array<MosaicItemResult>(count, { i: Int64 =>
        MosaicItemResult(
            x: items[i].frameX,
            y: items[i].frameY,
            width: items[i].frameW,
            height: items[i].frameH,
            position: items[i].position
        )
    })

    MosaicLayoutResult(items: resultItems, totalWidth: rnd(dimW), totalHeight: rnd(dimH))
}
