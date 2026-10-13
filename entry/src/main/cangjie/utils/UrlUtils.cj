package ohos_app_cangjie_entry.utils

import std.collection.ArrayList
import std.convert.*

/**
 * UrlUtils — URL 处理工具（精简保留版）
 *
 * 对应 Telegram-iOS 子模块：
 *   - UrlEscaping  → percentEncode / percentDecode（RFC 3986 百分号编码）
 *   - UrlWhitelist → isWhitelistedUrl（已知 scheme 安全粗判，供外链确认弹窗）
 *
 * 删除说明：
 *   - parseDeepLink / DeepLinkAction：本地 client-side 路由层，当前 app 无完整调用链；
 *     深链解析已由 ResolveDataProvider + ResolveService (MTProto help.getDeepLinkInfo) 覆盖。
 *   - websiteType：按 host 识别站点，无任何 UI 调用点，删除。
 *
 * 接线说明：
 *   - percentEncode：接入 GameService.buildShareUrl（gameName 含特殊字符时需编码）
 *   - isWhitelistedUrl：接入 ChatRoomPage.openWebUrl（外链安全门控）
 *
 * 口径：
 *   - percentEncode 按 RFC 3986 unreserved 集合（A-Z a-z 0-9 - _ . ~）保留，
 *     其余字节（含多字节 UTF-8）逐字节编码为 %XX（大写十六进制）。
 *   - percentDecode 逆向：%XX → 字节，非法 %XX 序列原样保留 '%'。
 */

// ===== 内部辅助 =====

private let UPPER_HEX: Array<Rune> = "0123456789ABCDEF".toRuneArray()

/**
 * 该字节是否属于 RFC 3986 unreserved 集合（无需编码）。
 * unreserved = ALPHA / DIGIT / "-" / "_" / "." / "~"
 */
private func isUnreservedByte(b: UInt8): Bool {
    return (b >= UInt8(UInt32(r'A')) && b <= UInt8(UInt32(r'Z')))
        || (b >= UInt8(UInt32(r'a')) && b <= UInt8(UInt32(r'z')))
        || (b >= UInt8(UInt32(r'0')) && b <= UInt8(UInt32(r'9')))
        || b == UInt8(UInt32(r'-'))
        || b == UInt8(UInt32(r'_'))
        || b == UInt8(UInt32(r'.'))
        || b == UInt8(UInt32(r'~'))
}

/**
 * 单个十六进制字符（Rune）→ nibble 值（0-15），非法返回 None。
 */
private func hexNibbleValue(r: Rune): Option<UInt8> {
    let c = UInt32(r)
    if (c >= UInt32(r'0') && c <= UInt32(r'9')) {
        return Some(UInt8(c - UInt32(r'0')))
    } else if (c >= UInt32(r'a') && c <= UInt32(r'f')) {
        return Some(UInt8(c - UInt32(r'a') + 10))
    } else if (c >= UInt32(r'A') && c <= UInt32(r'F')) {
        return Some(UInt8(c - UInt32(r'A') + 10))
    }
    return None
}

// ===== 百分号编码 / 解码（RFC 3986）=====

/**
 * RFC 3986 百分号编码：unreserved 字节原样，其余字节 → %XX（大写）。
 * 多字节 UTF-8（如中文）按字节逐个编码。
 *
 * 典型使用：GameService.buildShareUrl 对 gameName 编码；构造含用户输入的 query 参数。
 */
public func percentEncode(s: String): String {
    let bytes = s.toArray()
    let sb = StringBuilder()
    for (b in bytes) {
        if (isUnreservedByte(b)) {
            sb.append(Rune(UInt32(b)))
        } else {
            let hi = Int64((b >> 4) & 0x0Fu8)
            let lo = Int64(b & 0x0Fu8)
            sb.append(r'%')
            sb.append(UPPER_HEX[hi])
            sb.append(UPPER_HEX[lo])
        }
    }
    return sb.toString()
}

/**
 * RFC 3986 百分号解码：%XX → 字节，逐字节累积后按 UTF-8 还原。
 * 遇到非法 %XX（% 后非两个十六进制）时，'%' 原样保留。
 */
public func percentDecode(s: String): String {
    let runes = s.toRuneArray()
    let n = runes.size
    let out = ArrayList<UInt8>()
    var i = 0
    while (i < n) {
        let r = runes[i]
        if (UInt32(r) == UInt32(r'%') && i + 2 < n) {
            match (hexNibbleValue(runes[i + 1])) {
                case Some(hi) =>
                    match (hexNibbleValue(runes[i + 2])) {
                        case Some(lo) =>
                            out.add((hi << 4) | lo)
                            i += 3
                            continue
                        case None => ()
                    }
                case None => ()
            }
            // 非法序列：'%' 原样
            out.add(UInt8(UInt32(r'%')))
            i += 1
        } else {
            // 普通字符：按 UTF-8 写入字节
            let cap = Array<UInt8>(4, { _ => 0u8 })
            let len = Rune.intoUtf8Array(r, cap, 0)
            for (k in 0..len) {
                out.add(cap[k])
            }
            i += 1
        }
    }
    let sb = StringBuilder()
    sb.appendFromUtf8(out.toArray())
    return sb.toString()
}

// ===== 白名单判定 =====

/**
 * 粗粒度安全判定：已知 scheme（http/https/tg/ton/tonsite/tel/mailto 等）返 true，
 * 可疑 / 未知 scheme 返 false，供"是否允许直接打开外链"。
 * 无 scheme（裸 host，如 "example.com"）按 https 处理，返 true。
 *
 * 典型使用：ChatRoomPage.openWebUrl 在调用 startAbility 前过滤 javascript:/data: 等危险 URL。
 */
public func isWhitelistedUrl(url: String): Bool {
    let lower = url.toAsciiLower()
    let known: Array<String> = [
        "http://", "https://", "tg://", "ton://", "tonsite://",
        "tel:", "mailto:", "sms:", "ftp://"
    ]
    for (k in known) {
        if (lower.startsWith(k)) {
            return true
        }
    }
    // 含 scheme 分隔但不在已知集合 → 可疑
    match (lower.indexOf("://")) {
        case Some(_) => return false
        case None => ()
    }
    // 形如 "javascript:..." / "data:..." 这类无 // 的 scheme → 可疑
    match (lower.indexOf(":")) {
        case Some(i) =>
            // 若冒号前含 '.'（裸域名）则放行；否则可疑
            let pre = lower[..i]
            if (pre.contains(".")) {
                return true
            }
            return false
        case None => ()
    }
    // 裸 host
    return true
}

// ===== 自检 =====

/**
 * 自检：percentEncode/decode 往返、isWhitelistedUrl 关键 case。
 * 返回 true 表示全部通过。
 */
public func urlUtilsSelfCheck(): Bool {
    // --- percentEncode / decode 往返 ---
    let samples: Array<String> = [
        "hello world", "a&b=c", "你好", "foo bar 你好 & baz", "~unreserved-._"
    ]
    for (s in samples) {
        let enc = percentEncode(s)
        let dec = percentDecode(enc)
        if (dec != s) {
            return false
        }
    }
    // 空格必须编码为 %20
    if (percentEncode("a b") != "a%20b") {
        return false
    }
    // '&' 必须编码
    if (!percentEncode("a&b").contains("%26")) {
        return false
    }
    // unreserved 保持原样
    if (percentEncode("Abc-_.~9") != "Abc-_.~9") {
        return false
    }

    // --- isWhitelistedUrl ---
    if (!isWhitelistedUrl("https://example.com")) { return false }
    if (!isWhitelistedUrl("tg://resolve?domain=x")) { return false }
    if (isWhitelistedUrl("javascript:alert(1)")) { return false }
    if (isWhitelistedUrl("data:text/html,<h1>x</h1>")) { return false }

    return true
}
