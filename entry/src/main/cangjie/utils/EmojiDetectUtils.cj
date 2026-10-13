package ohos_app_cangjie_entry.utils

import std.collection.ArrayList

/**
 * Emoji 检测工具。
 *
 * 对应 iOS Telegram `submodules/Emoji/Sources/EmojiUtils.swift`：
 *   - `String.isSingleEmoji` / `String.containsEmoji` / `Character.isEmoji`（基 emoji + 组合）。
 *   - iOS 侧依赖 `UnicodeScalar.properties.isEmoji` + 一组手写码点区间；本工具在仓颉里
 *     无系统级 emoji 属性表，故完全基于 **Unicode emoji 码点区间** 判定（覆盖常见形态）。
 *
 * 实现思路：
 *   - 仓颉 `String.toRuneArray(): Array<Rune>` 把字符串按 Unicode 标量（码点）拆分；
 *     `UInt32(rune)` 取该标量的码点数值（不是字节！emoji 通常是 4 字节 UTF-8）。
 *   - `isEmojiScalar` 用区间判断单个码点是否落在主要 emoji 块内。
 *   - emoji 簇（grapheme cluster）边界靠手写状态机识别：基 emoji + 后续
 *     FE0F(变体选择器) / 1F3FB-1F3FF(肤色修饰) / 200D(ZWJ)+下一 emoji / regional-indicator 配对 /
 *     keycap(数字/符号 + FE0F? + 20E3) 都并入同一簇。
 *
 * 覆盖范围（非完美 grapheme cluster，覆盖常见 emoji 即可）：
 *   Emoticons 1F600-1F64F、Misc Symbols&Pictographs 1F300-1F5FF、Transport 1F680-1F6FF、
 *   Supplemental 1F900-1F9FF、Symbols&Pictographs Ext-A 1FA70-1FAFF、Misc Symbols 2600-26FF、
 *   Dingbats 2700-27BF、Regional Indicators 1F1E6-1F1FF、Enclosed Alphanumeric Suppl 1F100-1F1FF、
 *   Misc Symbols&Arrows 2B00-2BFF（含 2B50 ⭐ 等）、几个零散符号（2122 ™、2139 ℹ、2194-21AA 箭头、
 *   231A-231B ⌚⏳、24C2 Ⓜ、25AA-25FE 几何、2934-2935、3030 〰、3297/3299、203C/2049、2328、2702-27B0）、
 *   变体选择器 FE0F、ZWJ 200D、肤色修饰 1F3FB-1F3FF、keycap 组合标记 20E3。
 *   keycap 基（# * 0-9）和裸 regional indicator 自身不算 emoji（需配对/keycap 标记），
 *   与 iOS 一致避免把普通数字误判为 emoji。
 */

// ===== 单码点判定 =====

/**
 * 判断单个 Unicode 码点是否属于 emoji（覆盖主要 Unicode emoji 块）。
 * 注意：变体选择器 FE0F、ZWJ 200D、肤色修饰、keycap 标记 20E3 本身不算独立 emoji，
 * 它们只是修饰/连接符（见 isEmojiModifierScalar / isVariationSelector 等）。
 */
public func isEmojiScalar(codePoint: UInt32): Bool {
    let c = codePoint
    // 主要补充平面 emoji 块
    if (c >= 0x1F600 && c <= 0x1F64F) { return true } // Emoticons
    if (c >= 0x1F300 && c <= 0x1F5FF) { return true } // Misc Symbols & Pictographs
    if (c >= 0x1F680 && c <= 0x1F6FF) { return true } // Transport & Map
    if (c >= 0x1F900 && c <= 0x1F9FF) { return true } // Supplemental Symbols & Pictographs
    if (c >= 0x1FA70 && c <= 0x1FAFF) { return true } // Symbols & Pictographs Extended-A
    if (c >= 0x1F1E6 && c <= 0x1F1FF) { return true } // Regional Indicators（成对组国旗，单个也按 emoji 计）
    if (c >= 0x1F100 && c <= 0x1F1FF) { return true } // Enclosed Alphanumeric Supplement（🅰 等）
    // BMP emoji 块
    if (c >= 0x2600 && c <= 0x26FF) { return true } // Misc Symbols
    if (c >= 0x2700 && c <= 0x27BF) { return true } // Dingbats
    if (c >= 0x2B00 && c <= 0x2BFF) { return true } // Misc Symbols & Arrows（⭐2B50 等）
    // 零散 BMP emoji 码点
    if (c == 0x203C || c == 0x2049) { return true } // ‼ ⁉
    if (c == 0x2122 || c == 0x2139) { return true } // ™ ℹ
    if (c >= 0x2194 && c <= 0x2199) { return true } // 箭头组
    if (c == 0x21A9 || c == 0x21AA) { return true } // ↩ ↪
    if (c == 0x231A || c == 0x231B) { return true } // ⌚ ⏳
    if (c == 0x2328 || c == 0x23CF) { return true } // ⌨ ⏏
    if (c >= 0x23E9 && c <= 0x23FA) { return true } // 媒体控制符
    if (c == 0x24C2) { return true } // Ⓜ
    if (c >= 0x25AA && c <= 0x25AB) { return true } // ▪ ▫
    if (c == 0x25B6 || c == 0x25C0) { return true } // ▶ ◀
    if (c >= 0x25FB && c <= 0x25FE) { return true } // 几何
    if (c == 0x2934 || c == 0x2935) { return true } // ⤴ ⤵
    if (c == 0x3030 || c == 0x303D) { return true } // 〰 〽
    if (c == 0x3297 || c == 0x3299) { return true } // ㊗ ㊙
    return false
}

/** 变体选择器 FE0F（emoji 呈现）。 */
public func isVariationSelector(codePoint: UInt32): Bool {
    return codePoint == 0xFE0F || codePoint == 0xFE0E
}

/** 零宽连接符 ZWJ 200D。 */
public func isZWJ(codePoint: UInt32): Bool {
    return codePoint == 0x200D
}

/** 肤色修饰 1F3FB-1F3FF。 */
public func isEmojiModifierScalar(codePoint: UInt32): Bool {
    return codePoint >= 0x1F3FB && codePoint <= 0x1F3FF
}

/** keycap 组合标记 20E3（前接 # * 0-9 + 可选 FE0F 构成 keycap emoji）。 */
public func isKeycapMark(codePoint: UInt32): Bool {
    return codePoint == 0x20E3
}

/** Regional Indicator 单字母 1F1E6-1F1FF（两个配对组国旗）。 */
public func isRegionalIndicator(codePoint: UInt32): Bool {
    return codePoint >= 0x1F1E6 && codePoint <= 0x1F1FF
}

/** keycap 基字符：# * 0-9。 */
private func isKeycapBase(codePoint: UInt32): Bool {
    if (codePoint == 0x23 || codePoint == 0x2A) { return true } // # *
    return codePoint >= 0x30 && codePoint <= 0x39           // 0-9
}

// ===== emoji 簇遍历 =====

/**
 * 从 runes[start] 起，若该位置能构成一个 emoji 簇，返回簇结束后的下一个索引；
 * 否则返回 -1（说明 runes[start] 不是 emoji 簇起点）。
 *
 * 识别的簇形态：
 *   1. keycap：keycap基(# * 0-9) + 可选 FE0F + 20E3
 *   2. 国旗：regional-indicator 对（两个连续 RI）
 *   3. 基 emoji + 任意串后续修饰：FE0F / 肤色 / (ZWJ + 下一 emoji 段)，循环吞并
 */
private func scanEmojiCluster(runes: Array<Rune>, start: Int64): Int64 {
    let n = runes.size
    if (start >= n) { return -1 }
    let c0 = UInt32(runes[start])

    // 1. keycap 序列：基 + 可选 FE0F + 20E3
    if (isKeycapBase(c0)) {
        var j = start + 1
        if (j < n && isVariationSelector(UInt32(runes[j]))) { j = j + 1 }
        if (j < n && isKeycapMark(UInt32(runes[j]))) {
            return j + 1
        }
        return -1 // 裸数字/# /* 不算 emoji
    }

    // 2. 国旗：两个连续 regional indicator
    if (isRegionalIndicator(c0)) {
        if (start + 1 < n && isRegionalIndicator(UInt32(runes[start + 1]))) {
            return start + 2
        }
        // 单个 RI：按一个 emoji 簇计（容错），吞并自身
        return start + 1
    }

    // 3. 基 emoji（必须先是一个真正的 emoji 码点）
    if (!isEmojiScalar(c0)) {
        return -1
    }
    var i = start + 1
    // 吞并紧跟的修饰：FE0F / 肤色
    while (i < n) {
        let c = UInt32(runes[i])
        if (isVariationSelector(c) || isEmojiModifierScalar(c)) {
            i = i + 1
            continue
        }
        // ZWJ 续接：ZWJ + 下一个 emoji（及其后续修饰）
        if (isZWJ(c) && i + 1 < n && isEmojiScalar(UInt32(runes[i + 1]))) {
            i = i + 2
            // 续段后可再跟修饰
            while (i < n) {
                let c2 = UInt32(runes[i])
                if (isVariationSelector(c2) || isEmojiModifierScalar(c2)) {
                    i = i + 1
                } else {
                    break
                }
            }
            continue
        }
        break
    }
    return i
}

// ===== 公共 API =====

/**
 * 整个字符串是否**恰好一个 emoji 簇**（含 ZWJ 家庭、肤色、国旗、keycap）。
 * 对应 iOS `String.isSingleEmoji`（count == 1 && containsEmoji）。
 */
public func isSingleEmoji(s: String): Bool {
    let runes = s.toRuneArray()
    if (runes.size == 0) { return false }
    let next = scanEmojiCluster(runes, 0)
    // 起点必须是 emoji 簇，且簇覆盖到字符串末尾（恰好一个簇）
    return next == runes.size
}

/**
 * 字符串是否含有至少一个 emoji 码点。
 * 对应 iOS `String.containsEmoji`。
 */
public func stringContainsEmoji(s: String): Bool {
    let runes = s.toRuneArray()
    for (r in runes) {
        let c = UInt32(r)
        if (isEmojiScalar(c) || isRegionalIndicator(c)) {
            return true
        }
        // keycap 组合也算（出现 20E3 必然是 keycap）
        if (isKeycapMark(c)) {
            return true
        }
    }
    return false
}

/**
 * 粗略计 emoji 簇数量（ZWJ 序列 / 国旗对 / keycap 各算 1，非 emoji 字符跳过、不计）。
 */
public func emojiCount(s: String): Int64 {
    let runes = s.toRuneArray()
    let n = runes.size
    var i: Int64 = 0
    var count: Int64 = 0
    while (i < n) {
        let next = scanEmojiCluster(runes, i)
        if (next > i) {
            count = count + 1
            i = next
        } else {
            i = i + 1
        }
    }
    return count
}

/**
 * 按 emoji 簇切分字符串（非 emoji 字符原样单独成段）。
 * 大表情消息要逐个簇取动画表情素材，不能按码点切 —— ZWJ 家庭、肤色、国旗都会被切碎。
 */
public func splitEmojiClusters(s: String): Array<String> {
    let runes = s.toRuneArray()
    let n = runes.size
    let result = ArrayList<String>()
    var i: Int64 = 0
    while (i < n) {
        let next = scanEmojiCluster(runes, i)
        let end = if (next > i) { next } else { i + 1 }
        var piece = ""
        var k = i
        while (k < end) {
            piece = piece + runes[k].toString()
            k = k + 1
        }
        result.add(piece)
        i = end
    }
    return result.toArray()
}

/**
 * 整串是否**全部由 emoji 簇构成**，不限个数。
 *
 * 对齐 iOS `String.containsOnlyEmoji`（EmojiUtils.swift:103-105）——
 * `messageIsEligibleForLargeEmoji`（ChatMessageItemCommon.swift:242-251）只要求
 * 非空、全 emoji、无 text entity，**没有数量上限**，个数只影响字号。
 */
public func containsOnlyEmoji(s: String): Bool {
    let runes = s.toRuneArray()
    let n = runes.size
    if (n == 0) { return false }
    var i: Int64 = 0
    while (i < n) {
        let next = scanEmojiCluster(runes, i)
        if (next <= i) { return false }
        i = next
    }
    return true
}

/**
 * 整串是否**全部由 emoji 簇构成**（无任何非 emoji 字符）且簇数 ≤ maxCount。
 * 用于聊天"仅 emoji 消息大表情渲染"判定（默认 1-3 个 emoji 放大）。
 * 对应 iOS `String.containsOnlyEmoji` + 大表情数量门控。
 */
public func isAllEmoji(s: String, maxCount!: Int64 = 3): Bool {
    let runes = s.toRuneArray()
    let n = runes.size
    if (n == 0) { return false }
    var i: Int64 = 0
    var count: Int64 = 0
    while (i < n) {
        let next = scanEmojiCluster(runes, i)
        if (next > i) {
            count = count + 1
            if (count > maxCount) { return false }
            i = next
        } else {
            // 出现非 emoji 字符 → 不是纯 emoji
            return false
        }
    }
    return count >= 1 && count <= maxCount
}

// ===== 自检 =====

/**
 * 关键 case 自检；返回 true 表示全部通过。
 */
public func selfCheck(): Bool {
    var ok = true

    // isSingleEmoji
    ok = ok && isSingleEmoji("😀")                 // 单 emoji
    ok = ok && isSingleEmoji("👨‍👩‍👧")              // ZWJ 家庭
    ok = ok && isSingleEmoji("🇨🇳")                // 国旗（RI 对）
    ok = ok && !isSingleEmoji("😀😀")               // 两个 → 非单
    ok = ok && !isSingleEmoji("hi")                // 纯文本
    ok = ok && !isSingleEmoji("😀hi")              // emoji + 文本

    // isAllEmoji
    ok = ok && isAllEmoji("😀😀😀", maxCount: 3)     // 3 个 → true
    ok = ok && !isAllEmoji("😀😀😀😀", maxCount: 3)   // 4 个 → false
    ok = ok && !isAllEmoji("a😀")                  // 含文本 → false

    // stringContainsEmoji
    ok = ok && stringContainsEmoji("hi😀")          // 混合含 emoji

    return ok
}
