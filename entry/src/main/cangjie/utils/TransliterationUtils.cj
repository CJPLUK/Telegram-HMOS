package ohos_app_cangjie_entry.utils

import std.collection.HashMap

/**
 * 字符串音译 / 拼音首字母工具。
 *
 * 对应 iOS Telegram 的
 *   submodules/StringTransliteration/Sources/
 * 的音译语义（把任意字符串归一到「拉丁首字母」用于排序 / 分组索引）。
 *
 * 用途：联系人 / 会话列表按拼音首字母 A-Z 分组索引（contact section index），
 * 以及拼音首字母搜索（中文用户重要）。本工具只提供「拼音首字母能力」，
 * 由 services/RealContactService.cj 的 buildContactsGroupedBySection 接入分组。
 *
 * 平台 API 调研结论（cangjie-kb 实证，2026-06-22）：
 *   - 多轮查询 `ohos.i18n Transliterator getInstance Han-Latin 拼音` / `PinyinUtils`
 *     / mapping / component 等：仓颉侧的 ohos.i18n 绑定仅暴露 Calendar /
 *     System.getAppPreferredLanguage 等，**不含** ArkTS 那个 `i18n.Transliterator`
 *     类，也没有任何 pinyin / Han-Latin API；std.unicode 只提供 isLetter /
 *     大小写转换，无音译。故采用 **fallback：常用汉字 → 拼音首字母 显式查表**。
 *
 * fallback 实现说明：
 *   不采用「GB2312 码点边界」近似法——该法只在 GBK 编码字节序下单调，
 *   而仓颉 String 是 UTF-8（Unicode 码点序），段首码点散布、不单调，
 *   「最近边界」会严重误判（实测 张→M、王→R 全错）。
 *   因此改为 **每个常用汉字逐字 → 拼音首字母 的显式映射表**（约 360 个常用字 /
 *   百家姓 + 常见名字用字），精确无歧义。多音字按最常见读音取一个；
 *   表外汉字（生僻字 / 非常用字）回退 "#"（不影响常用联系人分组）。
 */

/**
 * 常用汉字（Unicode 码点）→ 拼音首字母（大写）映射条目表。
 * 覆盖百家姓 + 常见名字用字（约 360 字）。多音字取最常见读音。
 * 表外汉字 → "#"。
 */
let kHanInitialEntries: Array<(UInt32, String)> = [
    (0x4E09, "S"), (0x4E8C, "E"), (0x4E00, "Y"), // 三 / 二 / 一（常见名字数字）
    (0x4E01, "D"), (0x4E07, "W"), (0x4E19, "B"), (0x4E25, "Y"), (0x4E30, "F"),
    (0x4E43, "N"), (0x4E50, "L"), (0x4E54, "Q"), (0x4E60, "X"), (0x4E8E, "Y"),
    (0x4E91, "Y"), (0x4ECE, "C"), (0x4EFB, "R"), (0x4F0A, "Y"), (0x4F0D, "W"),
    (0x4F0F, "F"), (0x4F2F, "B"), (0x4F55, "H"), (0x4F58, "S"), (0x4F59, "Y"),
    (0x4F5F, "T"), (0x4FAF, "H"), (0x4FDD, "B"), (0x4FDE, "Y"), (0x502A, "N"),
    (0x5076, "O"), (0x5085, "F"), (0x515A, "D"), (0x5168, "Q"), (0x5170, "L"),
    (0x5175, "B"), (0x5189, "R"), (0x519C, "N"), (0x51AF, "F"), (0x51B5, "K"),
    (0x51B7, "L"), (0x51BC, "X"), (0x51CC, "L"), (0x51E4, "F"), (0x5200, "D"),
    (0x5201, "D"), (0x5218, "L"), (0x522B, "B"), (0x52AA, "N"), (0x52B3, "L"),
    (0x5305, "B"), (0x5317, "B"), (0x5321, "K"), (0x533A, "O"), (0x534E, "H"),
    (0x5353, "Z"), (0x5355, "D"), (0x535C, "B"), (0x535E, "B"), (0x5361, "K"),
    (0x5362, "L"), (0x536B, "W"), (0x5371, "W"), (0x53CC, "S"), (0x53E4, "G"),
    (0x53F2, "S"), (0x53F6, "Y"), (0x53F8, "S"), (0x5415, "L"), (0x5434, "W"),
    (0x5468, "Z"), (0x54C8, "H"), (0x5510, "T"), (0x5546, "S"), (0x554A, "A"),
    (0x55BB, "Y"), (0x56DE, "H"), (0x56FD, "G"), (0x57C3, "A"), (0x590F, "X"),
    (0x595A, "X"), (0x59DA, "Y"), (0x59DC, "J"), (0x59EC, "J"), (0x5A04, "L"),
    (0x5A1C, "N"), (0x5A25, "E"), (0x5B54, "K"), (0x5B59, "S"), (0x5B5F, "M"),
    (0x5B63, "J"), (0x5B81, "N"), (0x5B89, "A"), (0x5B8B, "S"), (0x5B8C, "W"),
    (0x5B97, "Z"), (0x5B9D, "B"), (0x5BA3, "X"), (0x5BAB, "G"), (0x5BB9, "R"),
    (0x5BBE, "B"), (0x5BBF, "S"), (0x5BC7, "K"), (0x5BCC, "F"), (0x5BFB, "X"),
    (0x5BFF, "S"), (0x5C01, "F"), (0x5C14, "E"), (0x5C24, "Y"), (0x5C39, "Y"),
    (0x5C48, "Q"), (0x5C60, "T"), (0x5CB3, "Y"), (0x5CE8, "E"), (0x5D14, "C"),
    (0x5DE6, "Z"), (0x5DE8, "J"), (0x5DE9, "G"), (0x5DEB, "W"), (0x5DF4, "B"),
    (0x5E05, "S"), (0x5E38, "C"), (0x5E73, "P"), (0x5E78, "X"), (0x5E84, "Z"),
    (0x5E94, "Y"), (0x5E9E, "P"), (0x5EB7, "K"), (0x5EC9, "L"), (0x5ED6, "L"),
    (0x5F00, "K"), (0x5F13, "G"), (0x5F20, "Z"), (0x5F3A, "Q"), (0x5F6D, "P"),
    (0x5F8B, "L"), (0x5F90, "X"), (0x6069, "E"), (0x60E0, "H"), (0x6155, "M"),
    (0x6208, "G"), (0x620E, "R"), (0x6210, "C"), (0x621A, "Q"), (0x6234, "D"),
    (0x623F, "F"), (0x6276, "F"), (0x62C9, "L"), (0x62D3, "T"), (0x652F, "Z"),
    (0x6587, "W"), (0x65B9, "F"), (0x65BD, "S"), (0x660C, "C"), (0x660E, "M"),
    (0x6613, "Y"), (0x661D, "Z"), (0x6625, "C"), (0x6668, "C"), (0x666F, "J"),
    (0x6696, "N"), (0x66B4, "B"), (0x66F9, "C"), (0x66FE, "Z"), (0x672C, "B"),
    (0x6731, "Z"), (0x6743, "Q"), (0x674E, "L"), (0x675C, "D"), (0x6765, "L"),
    (0x6768, "Y"), (0x676D, "H"), (0x6797, "L"), (0x67E5, "C"), (0x67EF, "K"),
    (0x67F3, "L"), (0x67F4, "C"), (0x6851, "S"), (0x6881, "L"), (0x6885, "M"),
    (0x6A0A, "F"), (0x6B27, "O"), (0x6B65, "B"), (0x6B66, "W"), (0x6BB5, "D"),
    (0x6BB7, "Y"), (0x6BD5, "B"), (0x6BDB, "M"), (0x6C34, "S"), (0x6C5F, "J"),
    (0x6C60, "C"), (0x6C64, "T"), (0x6C6A, "W"), (0x6C88, "S"), (0x6C99, "S"),
    (0x6CE2, "B"), (0x6D17, "X"), (0x6D2A, "H"), (0x6D66, "P"), (0x6D82, "T"),
    (0x6DF3, "C"), (0x6E29, "W"), (0x6EA5, "P"), (0x6ED1, "H"), (0x6ED5, "T"),
    (0x6EE1, "M"), (0x6F58, "P"), (0x7126, "J"), (0x718A, "X"), (0x71D5, "Y"),
    (0x7231, "A"), (0x725B, "N"), (0x72C4, "D"), (0x738B, "W"), (0x73ED, "B"),
    (0x74E6, "W"), (0x7504, "Z"), (0x7518, "G"), (0x7530, "T"), (0x7533, "S"),
    (0x767D, "B"), (0x767E, "B"), (0x76AE, "P"), (0x76DB, "S"), (0x77BF, "J"),
    (0x77F3, "S"), (0x7941, "Q"), (0x7956, "Z"), (0x795D, "Z"), (0x79B9, "Y"),
    (0x79E6, "Q"), (0x7A0B, "C"), (0x7A3D, "J"), (0x7A46, "M"), (0x7AA6, "D"),
    (0x7AE0, "Z"), (0x7AE5, "T"), (0x7AEF, "D"), (0x7B26, "F"), (0x7B2A, "D"),
    (0x7B80, "J"), (0x7BA1, "G"), (0x7C73, "M"), (0x7CDC, "M"), (0x7EAA, "J"),
    (0x7F2A, "M"), (0x7F57, "L"), (0x7FC1, "W"), (0x7FDF, "D"), (0x803F, "G"),
    (0x8042, "N"), (0x8096, "X"), (0x80E1, "H"), (0x81E7, "Z"), (0x8212, "S"),
    (0x826F, "L"), (0x827E, "A"), (0x82A6, "L"), (0x82AE, "R"), (0x82B1, "H"),
    (0x82CF, "S"), (0x82D1, "Y"), (0x82D7, "M"), (0x82DF, "G"), (0x82F1, "Y"),
    (0x8303, "F"), (0x8305, "M"), (0x8340, "X"), (0x8363, "R"), (0x83AB, "M"),
    (0x8427, "X"), (0x8428, "S"), (0x8463, "D"), (0x848B, "J"), (0x84AF, "K"),
    (0x84B2, "P"), (0x84EC, "P"), (0x8521, "C"), (0x853A, "L"), (0x8584, "B"),
    (0x859B, "X"), (0x865E, "Y"), (0x8861, "H"), (0x8863, "Y"), (0x8881, "Y"),
    (0x88D8, "Q"), (0x88F4, "P"), (0x891A, "C"), (0x89E3, "J"), (0x8A79, "Z"),
    (0x8BB8, "X"), (0x8BF8, "Z"), (0x8C08, "T"), (0x8C22, "X"), (0x8C2D, "T"),
    (0x8C37, "G"), (0x8D1D, "B"), (0x8D39, "F"), (0x8D3A, "H"), (0x8D3E, "J"),
    (0x8D5B, "S"), (0x8D6B, "H"), (0x8D75, "Z"), (0x8DEF, "L"), (0x8F66, "C"),
    (0x8F9B, "X"), (0x8F9C, "G"), (0x8FB9, "B"), (0x8FBE, "D"), (0x8FDE, "L"),
    (0x8FDF, "C"), (0x9093, "D"), (0x909D, "K"), (0x90A2, "X"), (0x90A3, "N"),
    (0x90AC, "W"), (0x90B0, "T"), (0x90B1, "Q"), (0x90B5, "S"), (0x90B9, "Z"),
    (0x90C1, "Y"), (0x90CE, "L"), (0x90D1, "Z"), (0x90D7, "X"), (0x90DD, "H"),
    (0x90ED, "G"), (0x9102, "E"), (0x91D1, "J"), (0x949F, "Z"), (0x94AE, "N"),
    (0x94B1, "Q"), (0x957F, "C"), (0x95EB, "Y"), (0x95F5, "M"), (0x960E, "Y"),
    (0x961A, "K"), (0x962E, "R"), (0x9633, "O"), (0x963F, "A"), (0x9646, "L"),
    (0x9648, "C"), (0x9676, "T"), (0x968B, "S"), (0x96F7, "L"), (0x970D, "H"),
    (0x9756, "J"), (0x97A0, "J"), (0x97E6, "W"), (0x97E9, "H"), (0x9879, "X"),
    (0x987B, "X"), (0x987E, "G"), (0x989C, "Y"), (0x9976, "R"), (0x9A6C, "M"),
    (0x9A86, "L"), (0x9AD8, "G"), (0x9B4F, "W"), (0x9C81, "L"), (0x9C8D, "B"),
    (0x9E2D, "Y"), (0x9EBB, "M"), (0x9EC4, "H"), (0x9ECE, "L"), (0x9ED1, "H"),
    (0x9F50, "Q"), (0x9F99, "L"), (0x9F9A, "G")
]

/**
 * 由 kHanInitialEntries 构建的查表 HashMap（惰性单次构建）。
 */
func buildHanToInitial(): HashMap<UInt32, String> {
    let m = HashMap<UInt32, String>()
    for (entry in kHanInitialEntries) {
        m[entry[0]] = entry[1]
    }
    return m
}

let kHanToInitial: HashMap<UInt32, String> = buildHanToInitial()

/**
 * 判断码点是否落在 CJK 统一表意文字基本区。
 */
func isCjkHanRune(code: UInt32): Bool {
    return code >= 0x4E00 && code <= 0x9FFF
}

/**
 * 取单个汉字码点的拼音首字母（大写 A-Z）；表外汉字 → "#"。
 */
func pinyinLetterForHanRune(code: UInt32): String {
    return kHanToInitial.get(code) ?? "#"
}

/**
 * 取字符串首字符的拼音首字母（大写 A-Z）。
 *   - 英文字母 → 该字母大写
 *   - 中文常用汉字 → 拼音首字母（显式表）
 *   - 数字 / 符号 / 其它 / 空串 → "#"
 *
 * 供 contact section index（A-Z 分组）。
 */
public func firstLetterForSorting(s: String): String {
    if (s.size == 0) {
        return "#"
    }
    let runes = s.toRuneArray()
    if (runes.size == 0) {
        return "#"
    }
    let code = UInt32(runes[0])
    // 英文大写 A-Z
    if (code >= 65 && code <= 90) {
        return runes[0].toString()
    }
    // 英文小写 a-z → 大写
    if (code >= 97 && code <= 122) {
        return runes[0].toString().toAsciiUpper()
    }
    // 中文常用汉字 → 拼音首字母
    if (isCjkHanRune(code)) {
        return pinyinLetterForHanRune(code)
    }
    // 数字 / 符号 / 其它
    return "#"
}

/**
 * 把整串里每个常用汉字的拼音首字母拼起来（小写），供拼音首字母搜索匹配。
 * 例："张三" → "zs"；英文字母原样小写保留，跳过数字 / 空白 / 符号 / 表外汉字。
 *
 * 用途：搜索框输入 "zs" 命中 "张三"（中文用户常用的首字母快搜）。
 */
public func pinyinInitials(s: String): String {
    if (s.size == 0) {
        return ""
    }
    let sb = StringBuilder()
    for (r in s.toRuneArray()) {
        let code = UInt32(r)
        if (code >= 65 && code <= 90) {
            // A-Z → 小写
            sb.append(r.toString().toAsciiLower())
        } else if (code >= 97 && code <= 122) {
            // a-z 原样
            sb.append(r.toString())
        } else if (isCjkHanRune(code)) {
            let letter = pinyinLetterForHanRune(code)
            if (letter != "#") {
                sb.append(letter.toAsciiLower())
            }
        }
        // 数字 / 空白 / 符号：跳过（首字母搜索不计入）
    }
    return sb.toString()
}

/**
 * 整串「音译到拉丁」实现。
 *
 * 平台无 Transliterator（见文件头调研结论），无法做完整音节级音译；
 * 退化为「每个常用汉字 → 其拼音首字母大写，英文/数字/符号原样保留」，
 * 保证返回纯拉丁可排序串。（若后续平台补齐 i18n.Transliterator，可在此替换为真音译。）
 */
public func transliterateToLatin(s: String): String {
    if (s.size == 0) {
        return ""
    }
    let sb = StringBuilder()
    for (r in s.toRuneArray()) {
        let code = UInt32(r)
        if (isCjkHanRune(code)) {
            sb.append(pinyinLetterForHanRune(code))
        } else {
            sb.append(r.toString())
        }
    }
    return sb.toString()
}

/**
 * 自检：验证常用字分类正确。返回 true 表示全部通过。
 * 命名加 transliteration 前缀，避免与同包其它 utils 的全局 selfCheck 重名冲突。
 */
public func transliterationSelfCheck(): Bool {
    var ok = true
    // 中文常用字：张 → Z，王 → W，李 → L，陈 → C
    if (firstLetterForSorting("张三") != "Z") { ok = false }
    if (firstLetterForSorting("王") != "W") { ok = false }
    if (firstLetterForSorting("李") != "L") { ok = false }
    if (firstLetterForSorting("陈") != "C") { ok = false }
    // 英文：Apple → A（大写），apple → A（小写转大写）
    if (firstLetterForSorting("Apple") != "A") { ok = false }
    if (firstLetterForSorting("apple") != "A") { ok = false }
    // 数字 / 符号 / 空串 → "#"
    if (firstLetterForSorting("123") != "#") { ok = false }
    if (firstLetterForSorting("@!") != "#") { ok = false }
    if (firstLetterForSorting("") != "#") { ok = false }
    // 拼音首字母搜索：张三 → "zs"
    if (pinyinInitials("张三") != "zs") { ok = false }
    return ok
}
