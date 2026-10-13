package ohos_app_cangjie_entry.utils

import std.collection.ArrayList
import ohos_app_cangjie_entry.models.*

/**
 * TextFormatUtils — Markdown → 富文本实体解析 + 实体感知字符串操作
 *
 * 对应 iOS: submodules/TextFormat/Sources/
 *   - parseMarkdownIntoTextEntities（markdown 文本 → (纯文本, 实体列表)）
 *   - stringWithAppliedEntities / 实体感知子串（截断时裁剪实体）
 *
 * 工程对齐口径（必须严格遵守，否则解析出的实体 MessageBubble 渲染不了）：
 *
 *   1. 实体类型表示：裸字符串 entityType。与 TelegramCore_ApiUtilsService.parseTextEntitiesToData
 *      / TextInputMenuService.buildBold/Italic/...Entity / ChatTextLinkEditService 完全一致：
 *        "bold" / "italic" / "underline" / "strike" / "code" / "pre" / "spoiler" / "textUrl"
 *      （MessageBubble.buildTextSegments 消费的同一套裸字符串）。
 *
 *   2. offset / length 单位：**Rune（Unicode 码点）**，不是 UTF-16 code unit。
 *      理由：消费侧 MessageBubble.buildTextSegments 用 content.toRuneArray() 再
 *      contentRunes[ri] 按码点索引切段（见 MessageBubble.cj L135-L208）。Telegram TL 协议
 *      原生 offset 是 UTF-16，但本工程的实体消费已统一到码点口径，这里**对齐工程现有口径**
 *      （码点），保证 parseMarkdown 产物能被 MessageBubble 直接渲染。
 *
 *   3. 实体字段：models/Message.cj 的 TextEntityData { entityType: String, offset: Int32,
 *      length: Int32, url: String }。
 *
 * 支持的 markdown 标记（Telegram markdown 约定）：
 *   **bold**      → bold
 *   __italic__    → italic
 *   ~~strike~~    → strike
 *   ||spoiler||   → spoiler
 *   ```pre```     → pre   （三反引号，块级等宽）
 *   `code`        → code  （单反引号，行内等宽）
 *   [text](url)   → textUrl（url 写入 entity.url）
 *
 * 说明：
 *   - 采用单遍 Rune 扫描，offset/length 直接按已输出纯文本的码点计数累加。
 *   - 三反引号优先于单反引号匹配（先试 ``` 再试 `）。
 *   - 闭合标记找不到时，该标记按普通文本原样输出（不产生实体），与 Telegram 容错一致。
 *   - 嵌套不展开（与现有 TextInputMenuService 单层实体构建一致）；标记内文本按普通字符收集，
 *     不再二次解析其内部标记。
 */

// ===== 内部辅助：Rune 比较 =====

private func runeEq(r: Rune, c: Rune): Bool {
    return UInt32(r) == UInt32(c)
}

/**
 * 从 runes[i] 起是否匹配长度为 markLen 的标记串 mark（mark 全部为同一字符 ch 重复，
 * 或由 matchRun 调用方保证）。返回是否匹配。
 */
private func matchRun(runes: Array<Rune>, i: Int64, ch: Rune, count: Int64): Bool {
    if (i + count > runes.size) { return false }
    for (k in 0..count) {
        if (!runeEq(runes[i + k], ch)) { return false }
    }
    return true
}

/**
 * 从 runes[start] 起，寻找与长度为 count 的重复字符标记 ch 的闭合位置。
 * 返回闭合标记的起始索引（即标记第一个字符的位置）；找不到返回 -1。
 */
private func findClosingRun(runes: Array<Rune>, start: Int64, ch: Rune, count: Int64): Int64 {
    var i = start
    while (i + count <= runes.size) {
        if (matchRun(runes, i, ch, count)) {
            return i
        }
        i = i + 1
    }
    return -1
}

/**
 * 构造一个实体。
 */
private func makeEntity(entityType: String, offset: Int32, length: Int32, url: String): TextEntityData {
    let e = TextEntityData()
    e.entityType = entityType
    e.offset = offset
    e.length = length
    e.url = url
    return e
}

// ===== 公共 API =====

/**
 * 解析 markdown 文本。
 *
 * @param text 含 markdown 标记的原始文本
 * @return (plain, entities)
 *   - plain: 去掉标记的纯文本
 *   - entities: 实体列表，offset/length 按 plain 的 **Rune（码点）** 计
 *
 * selfCheck 行为示例：
 *   parseMarkdown("**hi** x") → ("hi x", [bold offset=0 len=2])
 *   parseMarkdown("`code`")   → ("code", [code offset=0 len=4])
 *   parseMarkdown("[a](http://x)") → ("a", [textUrl offset=0 len=1 url="http://x"])
 */
public func parseMarkdown(text: String): (String, Array<TextEntityData>) {
    let runes = text.toRuneArray()
    let n = runes.size
    let out = StringBuilder()
    var outLen: Int32 = 0   // 已输出纯文本的码点数（== 下一个输出字符的 offset）
    let entities = ArrayList<TextEntityData>()

    // 标记常量
    let star = r'*'
    let underscore = r'_'
    let tilde = r'~'
    let pipe = r'|'
    let backtick = r'`'
    let lbracket = r'['
    let rbracket = r']'
    let lparen = r'('
    let rparen = r')'

    var i: Int64 = 0
    while (i < n) {
        let c = runes[i]

        // ---- 三反引号 ```pre``` （必须先于单反引号判断）----
        if (runeEq(c, backtick) && matchRun(runes, i, backtick, 3)) {
            let contentStart = i + 3
            let close = findClosingRun(runes, contentStart, backtick, 3)
            if (close >= 0) {
                let startOffset = outLen
                for (k in contentStart..close) {
                    out.append(runes[k].toString())
                    outLen = outLen + 1
                }
                let len = outLen - startOffset
                entities.add(makeEntity("pre", startOffset, len, ""))
                i = close + 3
                continue
            }
        }

        // ---- 单反引号 `code` ----
        if (runeEq(c, backtick)) {
            let contentStart = i + 1
            let close = findClosingRun(runes, contentStart, backtick, 1)
            if (close >= 0) {
                let startOffset = outLen
                for (k in contentStart..close) {
                    out.append(runes[k].toString())
                    outLen = outLen + 1
                }
                let len = outLen - startOffset
                entities.add(makeEntity("code", startOffset, len, ""))
                i = close + 1
                continue
            }
        }

        // ---- **bold** ----
        if (runeEq(c, star) && matchRun(runes, i, star, 2)) {
            let contentStart = i + 2
            let close = findClosingRun(runes, contentStart, star, 2)
            if (close >= 0) {
                let startOffset = outLen
                for (k in contentStart..close) {
                    out.append(runes[k].toString())
                    outLen = outLen + 1
                }
                let len = outLen - startOffset
                entities.add(makeEntity("bold", startOffset, len, ""))
                i = close + 2
                continue
            }
        }

        // ---- __italic__ ----
        if (runeEq(c, underscore) && matchRun(runes, i, underscore, 2)) {
            let contentStart = i + 2
            let close = findClosingRun(runes, contentStart, underscore, 2)
            if (close >= 0) {
                let startOffset = outLen
                for (k in contentStart..close) {
                    out.append(runes[k].toString())
                    outLen = outLen + 1
                }
                let len = outLen - startOffset
                entities.add(makeEntity("italic", startOffset, len, ""))
                i = close + 2
                continue
            }
        }

        // ---- ~~strike~~ ----
        if (runeEq(c, tilde) && matchRun(runes, i, tilde, 2)) {
            let contentStart = i + 2
            let close = findClosingRun(runes, contentStart, tilde, 2)
            if (close >= 0) {
                let startOffset = outLen
                for (k in contentStart..close) {
                    out.append(runes[k].toString())
                    outLen = outLen + 1
                }
                let len = outLen - startOffset
                entities.add(makeEntity("strike", startOffset, len, ""))
                i = close + 2
                continue
            }
        }

        // ---- ||spoiler|| ----
        if (runeEq(c, pipe) && matchRun(runes, i, pipe, 2)) {
            let contentStart = i + 2
            let close = findClosingRun(runes, contentStart, pipe, 2)
            if (close >= 0) {
                let startOffset = outLen
                for (k in contentStart..close) {
                    out.append(runes[k].toString())
                    outLen = outLen + 1
                }
                let len = outLen - startOffset
                entities.add(makeEntity("spoiler", startOffset, len, ""))
                i = close + 2
                continue
            }
        }

        // ---- [text](url) → textUrl ----
        if (runeEq(c, lbracket)) {
            // 找匹配的 ']'，要求紧跟 '('，再找 ')'
            let textStart = i + 1
            var j = textStart
            var closeBracket = -1
            while (j < n) {
                if (runeEq(runes[j], rbracket)) { closeBracket = j; break }
                j = j + 1
            }
            if (closeBracket >= 0 && closeBracket + 1 < n && runeEq(runes[closeBracket + 1], lparen)) {
                let urlStart = closeBracket + 2
                var k = urlStart
                var closeParen = -1
                while (k < n) {
                    if (runeEq(runes[k], rparen)) { closeParen = k; break }
                    k = k + 1
                }
                if (closeParen >= 0) {
                    // 收集链接文本（textStart..closeBracket）
                    let startOffset = outLen
                    for (t in textStart..closeBracket) {
                        out.append(runes[t].toString())
                        outLen = outLen + 1
                    }
                    let len = outLen - startOffset
                    // 收集 url（urlStart..closeParen），url 不进纯文本
                    let urlSb = StringBuilder()
                    for (u in urlStart..closeParen) {
                        urlSb.append(runes[u].toString())
                    }
                    entities.add(makeEntity("textUrl", startOffset, len, urlSb.toString()))
                    i = closeParen + 1
                    continue
                }
            }
        }

        // ---- 普通字符 ----
        out.append(c.toString())
        outLen = outLen + 1
        i = i + 1
    }

    return (out.toString(), entities.toArray())
}

/**
 * 实体感知截断：把 text 截断到 maxLen 个码点，并裁剪实体。
 *
 * 裁剪规则：
 *   - maxLen <= 0：返回空文本 + 空实体
 *   - 纯文本码点数 <= maxLen：原样返回（实体不变）
 *   - 实体 offset >= maxLen：整体丢弃
 *   - 实体跨界（offset < maxLen 但 offset+length > maxLen）：length 截到 maxLen - offset
 *   - offset/length 单位同 parseMarkdown：Rune（码点）
 *
 * @return (truncatedText, truncatedEntities)
 */
public func truncateWithEntities(text: String, entities: Array<TextEntityData>, maxLen: Int32): (String, Array<TextEntityData>) {
    if (maxLen <= 0) {
        return ("", Array<TextEntityData>())
    }
    let runes = text.toRuneArray()
    let total = Int32(runes.size)
    if (total <= maxLen) {
        // 不需要截断，原样返回（实体也无需裁剪）
        return (text, entities)
    }

    // 截断文本
    let sb = StringBuilder()
    for (k in 0..Int64(maxLen)) {
        sb.append(runes[k].toString())
    }
    let truncated = sb.toString()

    // 裁剪实体
    let result = ArrayList<TextEntityData>()
    for (e in entities) {
        if (e.offset >= maxLen) {
            // 完全落在截断点之后，丢弃
            continue
        }
        var newLen = e.length
        if (e.offset + e.length > maxLen) {
            // 跨界，length 截到 maxLen - offset
            newLen = maxLen - e.offset
        }
        if (newLen <= 0) {
            continue
        }
        result.add(makeEntity(e.entityType, e.offset, newLen, e.url))
    }

    return (truncated, result.toArray())
}

/**
 * 转义 markdown：在会被 parseMarkdown 识别的标记字符前加反斜杠占位，
 * 防止用户原文中的 * _ ~ | ` [ ] ( ) 被误解析。
 *
 * 注意：parseMarkdown 当前不消费反斜杠转义（与现有 TextInputMenuService 行为对齐，
 * 工程暂无反斜杠语义），此函数是给"安全展示原文"场景准备的辅助；它独立可用，
 * 把上述特殊字符各自前置一个 '\'。
 */
public func escapeMarkdown(text: String): String {
    let runes = text.toRuneArray()
    let sb = StringBuilder()
    let specials = [r'*', r'_', r'~', r'|', r'`', r'[', r']', r'(', r')', r'\\']
    for (r in runes) {
        var isSpecial = false
        for (s in specials) {
            if (UInt32(r) == UInt32(s)) { isSpecial = true; break }
        }
        if (isSpecial) {
            sb.append("\\")
        }
        sb.append(r.toString())
    }
    return sb.toString()
}

// ===== 自检 =====

/**
 * textFormatSelfCheck：覆盖 parseMarkdown 各标记 + 边界 + truncateWithEntities 裁剪。
 * 返回 true 表示全部断言通过。
 * （命名加 textFormat 前缀以避开 utils 包内 EmojiDetectUtils.selfCheck 同名冲突。）
 */
public func textFormatSelfCheck(): Bool {
    // 1. **bold** + 尾随文本
    let (p1, e1) = parseMarkdown("**hi** x")
    if (p1 != "hi x") { return false }
    if (e1.size != 1) { return false }
    if (e1[0].entityType != "bold" || e1[0].offset != 0 || e1[0].length != 2) { return false }

    // 2. `code`
    let (p2, e2) = parseMarkdown("`code`")
    if (p2 != "code") { return false }
    if (e2.size != 1 || e2[0].entityType != "code" || e2[0].offset != 0 || e2[0].length != 4) { return false }

    // 3. [a](http://x) → textUrl
    let (p3, e3) = parseMarkdown("[a](http://x)")
    if (p3 != "a") { return false }
    if (e3.size != 1 || e3[0].entityType != "textUrl" || e3[0].offset != 0 || e3[0].length != 1) { return false }
    if (e3[0].url != "http://x") { return false }

    // 4. __italic__ 在文本中间（offset 非 0）
    let (p4, e4) = parseMarkdown("ab __it__ cd")
    if (p4 != "ab it cd") { return false }
    if (e4.size != 1 || e4[0].entityType != "italic" || e4[0].offset != 3 || e4[0].length != 2) { return false }

    // 5. ~~strike~~ 与 ||spoiler||
    let (p5, e5) = parseMarkdown("~~s~~||p||")
    if (p5 != "sp") { return false }
    if (e5.size != 2) { return false }
    if (e5[0].entityType != "strike" || e5[0].offset != 0 || e5[0].length != 1) { return false }
    if (e5[1].entityType != "spoiler" || e5[1].offset != 1 || e5[1].length != 1) { return false }

    // 6. ```pre``` 优先于单反引号
    let (p6, e6) = parseMarkdown("```blk```")
    if (p6 != "blk") { return false }
    if (e6.size != 1 || e6[0].entityType != "pre" || e6[0].offset != 0 || e6[0].length != 3) { return false }

    // 7. 未闭合标记按普通文本原样输出，不产生实体
    let (p7, e7) = parseMarkdown("**oops")
    if (p7 != "**oops") { return false }
    if (e7.size != 0) { return false }

    // 8. 多字节码点 offset 按码点计（不是 UTF-16 / 字节）
    //    "你**好**" → 纯文本 "你好"，bold offset=1 len=1（码点口径）
    let (p8, e8) = parseMarkdown("你**好**")
    if (p8 != "你好") { return false }
    if (e8.size != 1 || e8[0].entityType != "bold" || e8[0].offset != 1 || e8[0].length != 1) { return false }

    // 9. truncateWithEntities：丢弃越界 + 裁剪跨界
    //    文本 "abcdef"，实体：bold[0,2]、italic[4,2]，截到 maxLen=5
    //    → bold 保留 [0,2]；italic 跨界 offset=4 len=2 → len 截到 1
    let ents = ArrayList<TextEntityData>()
    ents.add(makeEntity("bold", 0, 2, ""))
    ents.add(makeEntity("italic", 4, 2, ""))
    let (t9, te9) = truncateWithEntities("abcdef", ents.toArray(), 5)
    if (t9 != "abcde") { return false }
    if (te9.size != 2) { return false }
    if (te9[0].entityType != "bold" || te9[0].offset != 0 || te9[0].length != 2) { return false }
    if (te9[1].entityType != "italic" || te9[1].offset != 4 || te9[1].length != 1) { return false }

    // 10. truncateWithEntities：实体 offset >= maxLen 整体丢弃
    let ents2 = ArrayList<TextEntityData>()
    ents2.add(makeEntity("bold", 0, 2, ""))
    ents2.add(makeEntity("code", 5, 2, ""))
    let (t10, te10) = truncateWithEntities("abcdefg", ents2.toArray(), 4)
    if (t10 != "abcd") { return false }
    if (te10.size != 1 || te10[0].entityType != "bold") { return false }

    // 11. 不需要截断时原样返回
    let ents3 = ArrayList<TextEntityData>()
    ents3.add(makeEntity("bold", 0, 1, ""))
    let (t11, te11) = truncateWithEntities("ab", ents3.toArray(), 5)
    if (t11 != "ab" || te11.size != 1) { return false }

    return true
}
