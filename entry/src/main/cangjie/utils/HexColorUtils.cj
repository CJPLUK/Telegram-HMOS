package ohos_app_cangjie_entry.utils

/**
 * 十六进制颜色字符串 ↔ ARGB 整数互转工具。
 *
 * 对应 iOS Telegram submodules/HexColor（UIColor.hexString / UIColor(hex:)）：
 *   - iOS 侧 `hexString` 输出 6 位 RRGGBB；解析侧（TextFormat 等）接受 #RGB / #RRGGBB / #AARRGGBB。
 *   - 本工具统一以 **ARGB** 口径（高字节 alpha）对外，缺省 alpha 视为 0xFF（不透明）。
 *
 * 设计要点：
 *   - parseHexColor 接受带或不带前导 '#'；长度仅支持 3 / 6 / 8 个十六进制位，其余一律 None。
 *   - 任意非法字符 → None（不做"尽力解析"，保证缓存键稳定）。
 *   - hexStringFromColor 输出小写、无 '#' 前缀（与 iOS hexString 一致）；includeAlpha=true 时输出 8 位 AARRGGBB，否则 6 位 RRGGBB。
 */

private let HEX_OUT_DIGITS: Array<Rune> = "0123456789abcdef".toRuneArray()

/**
 * 解析单个十六进制字符为 0..15；非法返回 None。
 */
private func hexNibble(ch: Rune): Option<UInt32> {
    if (ch >= r'0' && ch <= r'9') {
        return Some(UInt32(ch) - UInt32(r'0'))
    } else if (ch >= r'a' && ch <= r'f') {
        return Some(UInt32(ch) - UInt32(r'a') + 10)
    } else if (ch >= r'A' && ch <= r'F') {
        return Some(UInt32(ch) - UInt32(r'A') + 10)
    }
    return None
}

/**
 * 解析十六进制颜色串为 ARGB（0xAARRGGBB）。
 *
 * 支持形式（带不带前导 '#' 均可）：
 *   - "#RGB"      → 每位扩展为两位（R→RR），alpha = 0xFF
 *   - "#RRGGBB"   → alpha = 0xFF
 *   - "#AARRGGBB" → 含 alpha
 *
 * 无效输入（长度不符 / 含非十六进制字符）返回 None。
 */
public func parseHexColor(hex: String): Option<UInt32> {
    var s = hex
    if (s.size > 0 && s[0] == UInt8(UInt32(r'#'))) {
        s = s[1..]
    }
    let runes = s.toRuneArray()
    let n = runes.size

    // 先把每个字符解析成 nibble，任一非法即整体失败。
    let nibbles = Array<UInt32>(n, { _ => 0u32 })
    for (i in 0..n) {
        match (hexNibble(runes[i])) {
            case Some(v) => nibbles[i] = v
            case None => return None
        }
    }

    if (n == 3) {
        // RGB → 每位复制成两位（如 R → RR）
        let r = nibbles[0] | (nibbles[0] << 4)
        let g = nibbles[1] | (nibbles[1] << 4)
        let b = nibbles[2] | (nibbles[2] << 4)
        return Some((0xFFu32 << 24) | (r << 16) | (g << 8) | b)
    } else if (n == 6) {
        var v: UInt32 = 0
        for (i in 0..6) {
            v = (v << 4) | nibbles[i]
        }
        return Some(0xFF000000u32 | v)
    } else if (n == 8) {
        var v: UInt32 = 0
        for (i in 0..8) {
            v = (v << 4) | nibbles[i]
        }
        return Some(v)
    }
    return None
}

/**
 * ARGB 整数 → 十六进制字符串（小写、无 '#'）。
 *   - includeAlpha=true  → 8 位 "AARRGGBB"
 *   - includeAlpha=false → 6 位 "RRGGBB"（丢弃 alpha）
 */
public func hexStringFromColor(argb: UInt32, includeAlpha: Bool): String {
    var result = ""
    let startNibble = if (includeAlpha) { 7 } else { 5 }
    var i = startNibble
    while (i >= 0) {
        let nibble = Int64((argb >> UInt32(i * 4)) & 0xFu32)
        result = result + HEX_OUT_DIGITS[nibble].toString()
        i -= 1
    }
    return result
}

/**
 * 自检：解析往返 + 已知样例。返回 true 表示全部通过。
 */
public func hexColorSelfCheck(): Bool {
    // #FF0000 → 不透明红 0xFFFF0000
    match (parseHexColor("#FF0000")) {
        case Some(v) => if (v != 0xFFFF0000u32) { return false }
        case None => return false
    }
    // 不带 '#' 同样解析
    match (parseHexColor("FF0000")) {
        case Some(v) => if (v != 0xFFFF0000u32) { return false }
        case None => return false
    }
    // #80FFFFFF → 半透明白（alpha=0x80）
    match (parseHexColor("#80FFFFFF")) {
        case Some(v) => if (v != 0x80FFFFFFu32) { return false }
        case None => return false
    }
    // #RGB 短形式：#F00 → 红
    match (parseHexColor("#F00")) {
        case Some(v) => if (v != 0xFFFF0000u32) { return false }
        case None => return false
    }
    // 非法：长度不符
    match (parseHexColor("#FF00")) {
        case Some(_) => return false
        case None => ()
    }
    // 非法：含非十六进制字符
    match (parseHexColor("#GG0000")) {
        case Some(_) => return false
        case None => ()
    }
    // 反向：红 → "ff0000"（6 位）
    if (hexStringFromColor(0xFFFF0000u32, false) != "ff0000") { return false }
    // 反向带 alpha：半透明白 → "80ffffff"
    if (hexStringFromColor(0x80FFFFFFu32, true) != "80ffffff") { return false }
    // 往返：parse → hex → parse 一致
    match (parseHexColor(hexStringFromColor(0x80FFFFFFu32, true))) {
        case Some(v) => if (v != 0x80FFFFFFu32) { return false }
        case None => return false
    }
    return true
}
