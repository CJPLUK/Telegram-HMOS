package ohos_app_cangjie_entry.utils

import std.collection.HashMap

/**
 * CLDR 复数形式选择（对应 iOS Telegram 的
 *   submodules/NumberPluralizationForm/Sources/NumberPluralizationForm.m
 *   submodules/StringPluralization/Sources/StringPluralization.swift）。
 *
 * 作用：按「数量 + 语言码」选 CLDR 复数类别（zero/one/two/few/many/other），
 * 让 "X messages" / "N members" 等在多复数形式语言（俄语、阿拉伯语等）下正确单复数。
 *
 * iOS 侧 numberPluralizationForm(lc, n) 以 4 字节 ASCII 打包语言码做 switch，
 * 这里改为直接用语言码字符串（小写、取主子标签，如 "ru-RU" → "ru"）。
 * 规则一律照搬 iOS 源里的 mod10 / mod100 判断（即 CLDR plural rules），
 * 每个规则族在注释里标明对应 iOS setN。
 *
 * 与 TimeFormatUtils.formatCount 的关系：
 *   - formatCount(n, singular, plural) 保留 n==1 的弱化逻辑（向后兼容，无外部调用方受影响）。
 *   - 新增 formatCountLocalized(...) 走本模块的 CLDR 选择，供需要语言感知的计数串使用。
 */

// CLDR 六种复数类别。常量名避免撞仓颉保留字（Two/Few/Many 均非保留字，安全）。
// 构造子名带 Plural 前缀，避免与同包其他枚举（如 StripeUtils 的 CardBrand.Other）
// 在包级未限定命名空间里冲突。
public enum PluralForm {
    | PluralZero
    | PluralOne
    | PluralTwo
    | PluralFew
    | PluralMany
    | PluralOther
}

/** 复数类别的 CLDR 标准名（"zero"/"one"/.../"other"），用于按 langpack 档名取串。 */
public func pluralFormName(form: PluralForm): String {
    match (form) {
        case PluralZero => "zero"
        case PluralOne => "one"
        case PluralTwo => "two"
        case PluralFew => "few"
        case PluralMany => "many"
        case PluralOther => "other"
    }
}

/**
 * 把传入语言码归一化为 CLDR 主标签（小写、截到第一个分隔符前）。
 * 例："ru-RU" → "ru"，"zh_Hans_CN" → "zh"，"EN" → "en"。
 */
func normalizeLangCode(langCode: String): String {
    var lc = langCode.toAsciiLower()
    // 截断到第一个 '-' 或 '_'
    var cut = lc.size
    var i = 0
    while (i < lc.size) {
        let ch = UInt8(lc[i])
        // '-' = 0x2D = 45, '_' = 0x5F = 95
        if (ch == 45u8 || ch == 95u8) {
            cut = i
            break
        }
        i++
    }
    if (cut < lc.size) {
        return lc[0..cut]
    }
    return lc
}

// 取非负余数（仓颉 % 对负数返回负值；复数规则按 CLDR 用非负 n，这里统一取绝对值口径）。
func nmod(n: Int64, m: Int64): Int64 {
    let r = n % m
    if (r < 0) {
        return r + m
    }
    return r
}

/**
 * 核心：按 count + 语言码选 CLDR 复数类别。
 * 覆盖 Telegram 常见语言族（非全 200 语言），其余走 fallback。
 *
 * 规则严格照搬 iOS NumberPluralizationForm.m（注释标 setN）。
 * n 取绝对值参与 mod 计算（计数语义下 count 应非负，负数容错）。
 */
public func pluralForm(count: Int64, langCode: String): PluralForm {
    let lc = normalizeLangCode(langCode)
    let n = if (count < 0) { -count } else { count }
    let m10 = nmod(n, 10)
    let m100 = nmod(n, 100)

    match (lc) {
        // ── 恒 PluralOther：中日韩泰越等无复数变化语言（iOS 落到 default → PluralOther）──
        case "zh" | "ja" | "ko" | "th" | "vi" | "id" | "ms" | "lo" | "km" | "my" =>
            PluralOther

        // ── set23：英语 / germanic 等绝大多数：n==1 → one，else other ──
        case "en" | "de" | "nl" | "sv" | "da" | "nb" | "nn" | "no" | "af" | "fo" |
             "fy" | "et" | "fi" | "el" | "es" | "it" | "pt" | "ca" | "gl" | "eu" |
             "bg" | "bn" | "eo" | "gu" | "ha" | "is" | "kk" | "ky" | "ml" | "mn" |
             "mr" | "ne" | "or" | "pa" | "ps" | "sw" | "ta" | "te" | "tk" | "ur" |
             "sq" | "ka" | "hy" | "lb" | "uz" =>
            // 注：sl 已移出此列表，交由下方专用 set10 分支处理（n%100 四路：one/two/few/other）。
            if (n == 1) { PluralOne } else { PluralOther }

        // ── set19：法语族 0,1 → one，else other ──
        case "fr" | "ff" | "kab" =>
            if (n == 0 || n == 1) { PluralOne } else { PluralOther }

        // ── set4：东斯拉夫族（ru/uk/be）──
        // one : n%10==1 且 n%100!=11
        // few : n%10 in 2..4 且 n%100 not in 12..14
        // many: n%10==0 或 n%10 in 5..9 或 n%100 in 11..14
        case "ru" | "uk" | "be" =>
            if (m10 == 1 && m100 != 11) {
                PluralOne
            } else if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) {
                PluralFew
            } else {
                PluralMany
            }

        // ── set4-bugfix：南斯拉夫族（bs/hr/sh/sr），尾档用 PluralOther 而非 PluralMany ──
        case "bs" | "hr" | "sh" | "sr" =>
            if (m10 == 1 && m100 != 11) {
                PluralOne
            } else if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) {
                PluralFew
            } else {
                PluralOther
            }

        // ── set12：波兰语 one/few/many ──
        // one : n==1
        // few : n%10 in 2..4 且 n%100 not in 12..14
        // many: 其余
        case "pl" =>
            if (n == 1) {
                PluralOne
            } else if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) {
                PluralFew
            } else {
                PluralMany
            }

        // ── set8：捷克 / 斯洛伐克（cs/sk）one/few/other ──
        case "cs" | "sk" =>
            if (n == 1) {
                PluralOne
            } else if (n >= 2 && n <= 4) {
                PluralFew
            } else {
                PluralOther
            }

        // ── set1：立陶宛（lt）──
        case "lt" =>
            if (m10 == 1 && (m100 < 11 || m100 > 19)) {
                PluralOne
            } else if (m10 >= 2 && m10 <= 9 && (m100 < 11 || m100 > 19)) {
                PluralFew
            } else {
                PluralOther
            }

        // ── set2：拉脱维亚（lv）zero/one/other ──
        case "lv" =>
            if (n == 0) {
                PluralZero
            } else if (m10 == 1 && m100 != 11) {
                PluralOne
            } else {
                PluralOther
            }

        // ── set10：斯洛文尼亚（sl）one/two/few/other（按 n%100）──
        case "sl" =>
            if (m100 == 1) {
                PluralOne
            } else if (m100 == 2) {
                PluralTwo
            } else if (m100 >= 3 && m100 <= 4) {
                PluralFew
            } else {
                PluralOther
            }

        // ── set17：罗马尼亚 / 摩尔多瓦（ro/mo）one/few/other ──
        case "ro" | "mo" =>
            if (n == 1) {
                PluralOne
            } else if (n == 0 || (n != 1 && m100 >= 1 && m100 <= 19)) {
                PluralFew
            } else {
                PluralOther
            }

        // ── set7：希伯来（he）one/two/many/other ──
        case "he" | "iw" =>
            if (n == 1) {
                PluralOne
            } else if (n == 2) {
                PluralTwo
            } else if (n != 0 && m10 == 0) {
                PluralMany
            } else {
                PluralOther
            }

        // ── set21：n in 0..1 → one（hi/am/fil 等）──
        case "hi" | "am" | "ak" | "bh" | "ln" | "mg" | "ti" | "tl" | "wa" |
             "fil" | "guw" | "nso" =>
            if (n >= 0 && n <= 1) { PluralOne } else { PluralOther }

        // ── set24：阿拉伯语（ar）六类全覆盖 ──
        // zero: n==0 ; one: n==1 ; two: n==2
        // few : n%100 in 3..10 ; many: n%100 in 11..99 ; else other
        case "ar" =>
            if (n == 0) {
                PluralZero
            } else if (n == 1) {
                PluralOne
            } else if (n == 2) {
                PluralTwo
            } else if (m100 >= 3 && m100 <= 10) {
                PluralFew
            } else if (m100 >= 11 && m100 <= 99) {
                PluralMany
            } else {
                PluralOther
            }

        // ── 默认 fallback：n==1 → one，else other（CLDR "other"-only 语言安全降级）──
        case _ =>
            if (n == 1) { PluralOne } else { PluralOther }
    }
}

/**
 * 按 count + langCode 从档位串里选对应复数串。
 * forms 的键应是 CLDR 类别名（"zero"/"one"/"two"/"few"/"many"/"other"）。
 * 选中的档若缺失，回退到 "other"；"other" 也缺则回退空串。
 */
public func selectPlural(count: Int64, langCode: String, forms: HashMap<String, String>): String {
    let name = pluralFormName(pluralForm(count, langCode))
    if (forms.contains(name)) {
        return forms[name]
    }
    if (forms.contains("other")) {
        return forms["other"]
    }
    return ""
}

/**
 * 显式六档参数版 selectPlural，免去调方建 HashMap。
 * 缺档传空串即可，内部按选中档回退 other。
 */
public func selectPluralForms(
    count: Int64,
    langCode: String,
    zero: String,
    one: String,
    two: String,
    few: String,
    many: String,
    other: String
): String {
    let chosen = match (pluralForm(count, langCode)) {
        case PluralZero => zero
        case PluralOne => one
        case PluralTwo => two
        case PluralFew => few
        case PluralMany => many
        case PluralOther => other
    }
    if (chosen.size > 0) {
        return chosen
    }
    return other
}

/**
 * 把模板里的数字占位符替换成实际 count。
 * 同时支持 "%d"（iOS/printf 风格）与 "{count}"（langpack 风格）。
 */
public func applyCountTemplate(template: String, count: Int64): String {
    let num = "${count}"
    return template.replace("%d", num).replace("{count}", num)
}

/**
 * 便捷：双档（one / other）模板，自动按语言选档并替换数字占位。
 * 例：formatPlural(5, "ru", "%d message", "%d messages")
 *     → 俄语 5 命中 many，但只给了 one/other 两档时，many 缺档回退 other。
 */
public func formatPlural(count: Int64, langCode: String, oneTemplate: String, otherTemplate: String): String {
    let tpl = selectPluralForms(count, langCode, "", oneTemplate, "", "", "", otherTemplate)
    return applyCountTemplate(tpl, count)
}

/**
 * 便捷：全六档模板版，缺档传空串。
 */
public func formatPluralForms(
    count: Int64,
    langCode: String,
    zero: String,
    one: String,
    two: String,
    few: String,
    many: String,
    other: String
): String {
    let tpl = selectPluralForms(count, langCode, zero, one, two, few, many, other)
    return applyCountTemplate(tpl, count)
}

/**
 * 语言感知版计数串，作为 TimeFormatUtils.formatCount 的升级入口：
 *   - 给定 singular / plural 两档（不带占位也可），按语言选 one/other。
 *   - 这是 formatCount(n, singular, plural) 的语言感知超集；
 *     旧 formatCount 仍保留（n==1 简化逻辑），无外部调用方受影响。
 */
public func formatCountLocalized(count: Int64, langCode: String, singular: String, plural: String): String {
    return selectPluralForms(count, langCode, "", singular, "", "", "", plural)
}

/**
 * selfCheck：覆盖验收要求的关键 CLDR case。
 * 返回 true 表示全部通过。
 */
public func pluralizationUtilsSelfCheck(): Bool {
    var ok = true

    func expect(form: PluralForm, count: Int64, lang: String) {
        if (pluralFormName(pluralForm(count, lang)) != pluralFormName(form)) {
            ok = false
        }
    }

    // ① 英语：1→one，2→other
    expect(PluralOne, 1, "en")
    expect(PluralOther, 2, "en")
    expect(PluralOther, 0, "en")
    expect(PluralOne, 1, "en-US") // 归一化子标签

    // ② 俄语：1→one，2→few，5→many，11→many，21→one，22→few，25→many，100→many
    expect(PluralOne, 1, "ru")
    expect(PluralFew, 2, "ru")
    expect(PluralFew, 3, "ru")
    expect(PluralFew, 4, "ru")
    expect(PluralMany, 5, "ru")
    expect(PluralMany, 11, "ru")
    expect(PluralMany, 12, "ru")
    expect(PluralMany, 14, "ru")
    expect(PluralOne, 21, "ru")
    expect(PluralFew, 22, "ru")
    expect(PluralMany, 25, "ru")
    expect(PluralMany, 100, "ru") // 100%10==0 → many

    // ③ 阿拉伯语：0→zero，1→one，2→two，3→few，11→many，100→other
    expect(PluralZero, 0, "ar")
    expect(PluralOne, 1, "ar")
    expect(PluralTwo, 2, "ar")
    expect(PluralFew, 3, "ar")
    expect(PluralFew, 10, "ar")
    expect(PluralMany, 11, "ar")
    expect(PluralMany, 99, "ar")
    expect(PluralOther, 100, "ar") // 100%100==0 → 不在 3..10 / 11..99 → other
    expect(PluralOther, 102, "ar") // 102%100==2 → other（two 仅 n==2）

    // ④ 中文：任意 → other
    expect(PluralOther, 0, "zh")
    expect(PluralOther, 1, "zh")
    expect(PluralOther, 5, "zh")
    expect(PluralOther, 100, "zh-Hans-CN")

    // ⑤ 法语：0,1→one，else other
    expect(PluralOne, 0, "fr")
    expect(PluralOne, 1, "fr")
    expect(PluralOther, 2, "fr")

    // ⑥ 波兰语：1→one，2→few，5→many，22→few，25→many
    expect(PluralOne, 1, "pl")
    expect(PluralFew, 2, "pl")
    expect(PluralMany, 5, "pl")
    expect(PluralFew, 22, "pl")
    expect(PluralMany, 25, "pl")
    expect(PluralMany, 12, "pl") // 12%100 in 12..14 → many

    // ⑦ 未知语言走 fallback：1→one，else other
    expect(PluralOne, 1, "xx")
    expect(PluralOther, 3, "xx")

    // ⑧ selectPlural 缺档回退 other
    let forms = HashMap<String, String>()
    forms["one"] = "one-str"
    forms["other"] = "other-str"
    // 俄语 5 → many，但只有 one/other → 回退 other
    if (selectPlural(5, "ru", forms) != "other-str") {
        ok = false
    }
    // 英语 1 → one → 命中
    if (selectPlural(1, "en", forms) != "one-str") {
        ok = false
    }
    // 完全无 other 档 → 回退空串
    let emptyForms = HashMap<String, String>()
    emptyForms["one"] = "x"
    if (selectPlural(5, "ru", emptyForms) != "") {
        ok = false
    }

    // ⑨ selectPluralForms 缺档回退 other
    // 俄语 2 → few，但 few 档为空串 → 回退 other
    if (selectPluralForms(2, "ru", "", "1m", "", "", "5m", "Nm") != "Nm") {
        ok = false
    }
    // 俄语 1 → one
    if (selectPluralForms(1, "ru", "", "1m", "", "", "5m", "Nm") != "1m") {
        ok = false
    }

    // ⑩ 模板替换 %d / {count}
    if (applyCountTemplate("%d messages", 5) != "5 messages") {
        ok = false
    }
    if (applyCountTemplate("{count} members", 3) != "3 members") {
        ok = false
    }

    // ⑪ formatPlural 双档
    if (formatPlural(1, "en", "%d message", "%d messages") != "1 message") {
        ok = false
    }
    if (formatPlural(2, "en", "%d message", "%d messages") != "2 messages") {
        ok = false
    }

    // ⑫ formatCountLocalized 语言感知（俄语 21 → one）
    if (formatCountLocalized(21, "ru", "сообщение", "сообщений") != "сообщение") {
        ok = false
    }
    if (formatCountLocalized(5, "ru", "сообщение", "сообщений") != "сообщений") {
        ok = false
    }

    // ⑬ 斯洛文尼亚语 set10（CLDR：n%100==1→one, n%100==2→two, n%100∈{3,4}→few, 其余→other）
    // P2-424 返修：sl 曾被 set23 arm 遮蔽，导致 two/few 类别永远返回 other。
    expect(PluralOne,  1,   "sl") // 1%100==1 → one
    expect(PluralTwo,  2,   "sl") // 2%100==2 → two
    expect(PluralFew,  3,   "sl") // 3%100==3 → few
    expect(PluralFew,  4,   "sl") // 4%100==4 → few
    expect(PluralOther, 5,  "sl") // 5%100==5 → other
    expect(PluralOne,  101, "sl") // 101%100==1 → one
    expect(PluralTwo,  102, "sl") // 102%100==2 → two
    expect(PluralFew,  103, "sl") // 103%100==3 → few
    expect(PluralOther, 105, "sl") // 105%100==5 → other

    return ok
}
