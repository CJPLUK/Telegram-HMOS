package ohos_app_cangjie_entry.utils

import std.collection.ArrayList
import std.convert.*

/**
 * 解析后的电话号码结构
 */
public class ParsedPhoneNumber {
    public var countryCode: String = ""
    public var nationalNumber: String = ""
    public var type_: String = "unknown"

    public init() {}

    public init(countryCode!: String, nationalNumber!: String, type_!: String = "unknown") {
        this.countryCode = countryCode
        this.nationalNumber = nationalNumber
        this.type_ = type_
    }
}

/**
 * 电话号码格式化工具（纯工具库，非 Service）
 *
 * test_failed 返修（diag-suite_auth_login-TC-0007.md 第 4 轮，D4.4 结构性移植 M2）：
 * 原 `getFormatPattern`（67 国手写掩码表，其中 32 条与源侧 `PhoneCountries.txt` 第 3 列不一致、
 * 另缺 166 国）、`applyPattern`、`getExampleForDialCode`，以及 `extractCountryCodeAndNational`
 * 内 68 条 `knownCodes` 硬编码表——全部已删除。它们是「按上层表现反推的近似件」，不是源侧真实
 * 算法的移植（D4.4 bullet 1/3）。
 *
 * `interactiveFormat` 本轮**不删**（Supervisor 批次排程决定，见下方函数处注释）：符号保留、旧实现
 * （依赖已删除的 `getFormatPattern`/`applyPattern`）已替换为委托本文件新增的正确路径的两行转发，
 * 仅为让 M3（`components/PhoneInputComponent.cj`，feature `auth_phone_input_node`，另案并行开发）
 * 落地前保持可编译；M3 轮删除其调用点后连同本函数一并移除。
 *
 * 替代实现：
 * - `formatPhoneNumberToMask` / `cleanPhoneNumber` / `removeDuplicatedPlus` / `removePlus` /
 *   `cleanPrefix` / `cleanSuffix`：逐字对照
 *   `submodules/PhoneNumberFormat/Sources/PhoneNumbers.swift`（全文）与
 *   `submodules/PhoneInputNode/Sources/PhoneInputNode.swift:7-77` 移植，纯字符串算法、无外部
 *   依赖，可 1:1 对照。
 * - 国家识别 / 拨号代码 / 分组 pattern 查表统一委托给 `utils/CountryData.cj`（feature
 *   `auth_country_selection_screen` 的 M1，已合入 `fix-zxc` @ `35a7e30a`）新增的
 *   `lookupCountryIdByNumber` / `lookupPatternByNumber`——它们是源侧 `PhoneCountries.txt`
 *   （236 行 / 233 个拨号代码）的忠实转录 + 逐字对照
 *   `AuthorizationSequenceCountrySelectionController.swift:229-306` 的查表算法。**注意**：
 *   `lookupPatternByNumber` 返回的是**国内号码部分的原始 pattern**（如 GB 的 `"XXXX XXXXXX"`），
 *   **不含**拨号代码等宽的 `X` 前缀（那是 `PhoneNumbers.swift` 里另一个同名私有函数的行为，
 *   M1 未采用，本文件调用方也一律按「国内号码专用、无 dialCode 前缀」处理）。本文件不再自建
 *   任何国家表、最长前缀匹配或长度阈值近似（同一批 D4.4 硬约束：严禁再造一张同类近似表）。
 *
 * 未复刻的残余（严禁声称与源侧等价，见 diag 报告 M2 第 4 点；同时登记于本 feature
 * `unresolved_api_decisions[]` 与交付报告「已知限制」）：
 * 1. `InteractivePhoneFormatter.updateText` 的兜底路径——源侧用 `NBAsYouTypeFormatter`
 *    （libphonenumber）在 `PhoneCountries.txt` 查不到时仍可能识别出 region；本工程未移植
 *    libphonenumber（feature `libphonenumber` 当前 `target_files=[]`，零代码，见 diag 报告
 *    「输入证据 E」），因此该兜底路径恒定返回 `(None, text)`——这与源侧 `NBAsYouTypeFormatter`
 *    同样判不出前缀时 else 分支的结果一致（`PhoneInputNode.swift:294-300`），但**不等价**于
 *    源侧在 libphonenumber 元数据命中而 `PhoneCountries.txt` 未命中时仍可切出 region 的能力。
 * 2. `formatPhoneNumber(countryCode, nationalNumber)` 在 `lookupPatternByNumber` 查不到 pattern
 *    时，源侧 `PhoneNumbers.swift:31-42` 会退回 `NBPhoneNumberUtil` 的 `INTERNATIONAL` 格式化；
 *    本文件同样因缺 libphonenumber 移植而退化为「不分组，仅按 dialCode 前缀原样拼接」。
 * 3. `isValidPhoneNumber` 在查不到 pattern 时不做强校验（返回 `true`）——避免重新引入原先那种
 *    按国家手写 `(minLen, maxLen)` 的近似表；该函数当前未被任何其他 feature 调用（已核实）。
 *
 * 与 `utils/CountryData.cj` 配合使用；`components/PhoneInputComponent.cj`
 * （feature `auth_phone_input_node`，D4.4 M3，另案返修中）负责把 `updateNumberFromTextFields` /
 * `updateNumber` 等引擎逻辑接到本文件的新增函数上。
 */

// --- M2 核心：分组格式化 + 输入清理（逐字对照源侧） ---

/**
 * 逐字对照 `PhoneNumbers.swift:100-112 formatPhoneNumberToMask`。
 * 先把 mask 里的数字字符统一替换成 `X` 占位符（对齐源侧
 * `mask.replacingOccurrences(of: "[0-9]", with: "X")`，防御性归一化）；
 * 把入参 `s` 剥成纯数字；然后按 mask 下标遍历，遇到非 `X` 字符就把它插入到当前下标位置
 * （分隔符），遇到 `X` 则跳过（该位置对应一位已存在的数字）。
 *
 * 边界：数字多于 mask 中 `X` 位数时，一旦下标越过当前纯数字长度立即返回——
 * 剩余部分原样追加、不再分组（案例文档 A1 判据）。
 */
public func formatPhoneNumberToMask(s: String, mask: String): String {
    let maskRunes = mask.toRuneArray()
    let pattern = ArrayList<Rune>()
    for (r in maskRunes) {
        let code = UInt32(r)
        if (code >= 48 && code <= 57) {
            pattern.add(r'X')
        } else {
            pattern.add(r)
        }
    }
    let pureNumber = ArrayList<Rune>()
    for (r in extractDigits(s).toRuneArray()) {
        pureNumber.add(r)
    }
    var index: Int64 = 0
    while (index < pattern.size) {
        if (index >= pureNumber.size) {
            return runesToString(pureNumber)
        }
        let patternChar = pattern[index]
        if (patternChar != r'X') {
            pureNumber.add(patternChar, at: index)
        }
        index = index + 1
    }
    return runesToString(pureNumber)
}

/**
 * 逐字对照 `PhoneNumbers.swift:8-20 cleanPhoneNumber`（`PhoneInputNode.swift:35-49` 的私有同名
 * 函数是其 `removePlus=false` 特化，语义完全一致，本文件合并为一份，签名以 `PhoneNumbers.swift`
 * 为准）。
 *
 * `removePlus=false`（默认）：`+` 仅在当前结果为空时保留（即只保留最靠前的一个 `+`，其余出现
 * 一律丢弃）；其余非数字字符一律丢弃。`removePlus=true`：`+` 也一律丢弃。
 */
public func cleanPhoneNumber(text: String, removePlus!: Bool = false): String {
    var result = ""
    let runes = text.toRuneArray()
    for (r in runes) {
        if (r == r'+' && !removePlus) {
            if (result.size == 0) {
                result = result + "+"
            }
        } else {
            let code = UInt32(r)
            if (code >= 48 && code <= 57) {
                result = result + r.toString()
            }
        }
    }
    return result
}

/**
 * 逐字对照 `PhoneInputNode.swift:7-21 removeDuplicatedPlus`。
 * 与 `cleanPhoneNumber` 不同：非数字、非 `+` 的字符原样保留，只去重复的 `+`
 * （只保留最靠前的一个）。
 */
public func removeDuplicatedPlus(text: String): String {
    var result = ""
    let runes = text.toRuneArray()
    for (r in runes) {
        if (r == r'+') {
            if (result.size == 0) {
                result = result + "+"
            }
        } else {
            result = result + r.toString()
        }
    }
    return result
}

/**
 * 逐字对照 `PhoneInputNode.swift:23-33` / `PhoneNumbers.swift:44-54`（两处私有 `removePlus`
 * 完全同构）：丢弃所有 `+`，其余字符原样保留。
 */
public func removePlus(text: String): String {
    var result = ""
    let runes = text.toRuneArray()
    for (r in runes) {
        if (r != r'+') {
            result = result + r.toString()
        }
    }
    return result
}

/**
 * 逐字对照 `PhoneInputNode.swift:51-63 cleanPrefix`：只裁剪首部的空格（一旦遇到非空格字符，
 * 之后的字符——包括空格——全部保留）。
 */
public func cleanPrefix(text: String): String {
    var result = ""
    var checked = false
    let runes = text.toRuneArray()
    for (r in runes) {
        if (r != r' ') {
            checked = true
        }
        if (checked) {
            result = result + r.toString()
        }
    }
    return result
}

/**
 * 逐字对照 `PhoneInputNode.swift:65-77 cleanSuffix`：只裁剪尾部的空格，与 `cleanPrefix` 对称
 * （从末尾往前扫）。
 */
public func cleanSuffix(text: String): String {
    let runes = text.toRuneArray()
    var result = ""
    var checked = false
    var i = runes.size - 1
    while (i >= 0) {
        let r = runes[i]
        if (r != r' ') {
            checked = true
        }
        if (checked) {
            result = r.toString() + result
        }
        i = i - 1
    }
    return result
}

/**
 * 逐字对照 `InteractivePhoneFormatter.swift`。源侧用 `NBAsYouTypeFormatter`（libphonenumber）
 * 做 region 兜底识别；本工程未移植 libphonenumber（见文件头「未复刻的残余」1），因此该兜底路径
 * 按 D4.4 bullet 2「允许自实现，但必须显式声明未复刻」处理：`updateText` 恒返回 `(None, text)`，
 * 即「无 region 可判、整串留在区号框」——与源侧在 `NBAsYouTypeFormatter` 同样判不出前缀时 else
 * 分支的结果一致（`PhoneInputNode.swift:294-300`）。**不得**用任何自造的最长前缀匹配 / 长度
 * 阈值 / 字符特征去猜 region prefix 顶替这条路径。
 */
public class InteractivePhoneFormatter {
    public init() {}

    public func updateText(text: String): (?String, String) {
        return (None, text)
    }
}

/**
 * 过渡符号（Supervisor 批次排程决定，本轮不删）：仅为让 `components/PhoneInputComponent.cj`
 * （feature `auth_phone_input_node`，M3，另案并行开发，当前仍有 4 处调用点 `:81`/`:248`/`:281`/
 * `:299`）在其批次落地前保持可编译；M3 轮删除这些调用点后连同本函数一并移除。
 *
 * 实现体不是桩——是本轮移植的正确路径本身：`CountryData.lookupPatternByNumber` 取该国内号码
 * pattern（无 dialCode 前缀，见文件头说明）+ `formatPhoneNumberToMask` 排版，与 `formatPhoneNumber`
 * / `getExampleNumber` 同源。不含任何自造掩码表、最长前缀匹配、长度阈值或字符特征判断。
 */
public func interactiveFormat(countryCode: String, rawInput: String): String {
    let digits = extractDigits(rawInput)
    if (digits.size == 0) {
        return ""
    }
    let dialCode = normalizeCountryCode(countryCode)
    match (lookupPatternByNumber(dialCode)) {
        case Some(pattern) => formatPhoneNumberToMask(digits, pattern)
        case None => digits
    }
}

// --- 遗留通用 API（非 PhoneNumberFormat 模块移植目标，供 auth/PhoneInputPage.cj、
//     pages/SettingsPage.cj、components/PhoneInputComponent.cj 等跨 feature 调用；内部实现随本
//     轮 M2 改为委托 CountryData.cj 的 M1 查表，不再依赖已删除的手写掩码表） ---

/**
 * 格式化完整号码为 "+<dialCode> <分组后的国内号码>"。
 * 对照源侧 `PhoneNumbers.swift:31-42 formatPhoneNumber(context:number:)`：用 `dialCode+国内号码`
 * 整串去 `lookupPatternByNumber` 定位国家与国内号码 pattern（该 pattern 只覆盖国内号码部分、不含
 * dialCode 前缀，见文件头说明），再用 `formatPhoneNumberToMask` 只对国内号码分组，前面手动拼上
 * `"+<dialCode> "`；查不到时源侧回退 libphonenumber `INTERNATIONAL` 格式化——本文件无该移植，
 * 退化为「不分组，仅拼接」（见文件头「未复刻的残余」2）。
 */
public func formatPhoneNumber(countryCode: String, nationalNumber: String): String {
    let dialCode = normalizeCountryCode(countryCode)
    let digits = extractDigits(nationalNumber)
    if (digits.size == 0) {
        return "+" + dialCode
    }
    match (lookupPatternByNumber(dialCode + digits)) {
        case Some(pattern) => return "+" + dialCode + " " + formatPhoneNumberToMask(digits, pattern)
        case None => return "+" + dialCode + " " + digits
    }
}

/**
 * 去除所有非数字字符，保留前导 `+`（只留一个）。与新增的 `cleanPhoneNumber(text)`（默认
 * `removePlus=false`）语义完全相同，委托实现以避免重复维护两份同构逻辑。
 */
public func normalizePhoneNumber(input: String): String {
    return cleanPhoneNumber(input)
}

/**
 * 基本校验：数字位数是否与 `CountryData.lookupPatternByNumber` 给出的国内号码 pattern 位数一致
 * （该 pattern 不含 dialCode 前缀，见文件头说明，故直接与国内号码位数比较，无需再减去
 * dialCode 长度）。查不到 pattern 时不做强校验（见文件头「未复刻的残余」3——不重新引入按国家
 * 手写的 `(minLen, maxLen)` 近似表）。
 */
public func isValidPhoneNumber(countryCode: String, nationalNumber: String): Bool {
    let digits = extractDigits(nationalNumber)
    if (digits.size == 0) {
        return false
    }
    let dialCode = normalizeCountryCode(countryCode)
    match (lookupPatternByNumber(dialCode + digits)) {
        case Some(pattern) => digits.size == countMaskDigits(pattern)
        case None => true
    }
}

/**
 * 解析任意格式输入为结构化数据（国家码、国内号码、类型）
 * 支持 "+15551234567"、"86 138 1234 5678" 等格式
 */
public func parsePhoneNumber(input: String): ParsedPhoneNumber {
    let normalized = normalizePhoneNumber(input)
    if (normalized.size == 0) {
        return ParsedPhoneNumber()
    }
    let digitsOnly = extractDigits(normalized)
    if (digitsOnly.size == 0) {
        return ParsedPhoneNumber()
    }
    let (cc, national) = extractCountryCodeAndNational(digitsOnly)
    let numType = getNumberType(cc, national)
    return ParsedPhoneNumber(countryCode: cc, nationalNumber: national, type_: numType)
}

/**
 * 获取指定国家的示例国内号码骨架（用于占位/提示）。对照源侧
 * `PhoneInputNode.swift:178-195 updatePlaceholder` 的 `mask.string.replacingOccurrences(of: "X",
 * with: "0")` 骨架生成技巧：取 `CountryData.lookupPatternByNumber` 返回的国内号码 pattern
 * （不含 dialCode 前缀，见文件头说明）直接把 `X` 换成 `0`。查不到 pattern（源侧此时
 * `mask == nil`）⇒ 返回空串——不再像旧实现那样为未知国家硬造一个 "5" + "0"*n 的骨架。
 */
public func getExampleNumber(countryCode: String): String {
    let dialCode = normalizeCountryCode(countryCode)
    match (lookupPatternByNumber(dialCode)) {
        case Some(pattern) =>
            var out = ""
            for (r in pattern.toRuneArray()) {
                if (r == r'X') {
                    out = out + "0"
                } else {
                    out = out + r.toString()
                }
            }
            return out
        case None => return ""
    }
}

/**
 * 获取号码类型：mobile、fixed_line、unknown
 * （与 PhoneNumberFormat 模块移植目标无关的既有启发式，未在本轮 M2 范围内改动）
 */
public func getNumberType(countryCode: String, nationalNumber: String): String {
    let digits = extractDigits(nationalNumber)
    if (digits.size == 0) { return "unknown" }
    let dialCode = normalizeCountryCode(countryCode)
    match (dialCode) {
        case "86" => if (digits.size >= 3 && (digits.startsWith("13") || digits.startsWith("15") || digits.startsWith("18") || digits.startsWith("19"))) { "mobile" } else { "unknown" }
        case "1" => if (digits.size >= 3 && digits.startsWith("555")) { "fixed_line" } else { "unknown" }
        case "44" => if (digits.size >= 4 && (digits.startsWith("7") || digits.startsWith("74") || digits.startsWith("75") || digits.startsWith("76") || digits.startsWith("77") || digits.startsWith("78") || digits.startsWith("79"))) { "mobile" } else { "unknown" }
        case "49" => if (digits.size >= 4 && (digits.startsWith("15") || digits.startsWith("16") || digits.startsWith("17"))) { "mobile" } else { "unknown" }
        case "81" => if (digits.size >= 2 && (digits.startsWith("90") || digits.startsWith("80") || digits.startsWith("70") || digits.startsWith("60") || digits.startsWith("50"))) { "mobile" } else { "unknown" }
        case _ => "unknown"
    }
}

/**
 * 校验号码对指定地区是否有效
 * regionCode 如 "US"、"CN"、"GB"，映射到国家拨号码
 */
public func isValidForRegion(phoneNumber: String, regionCode: String): Bool {
    let dialCode = regionToDialCode(regionCode)
    let normalized = normalizePhoneNumber(phoneNumber)
    if (normalized.size == 0) { return false }
    let digitsOnly = extractDigits(normalized)
    if (!normalized.startsWith("+")) {
        return isValidPhoneNumber(dialCode, digitsOnly)
    }
    let (cc, national) = extractCountryCodeAndNational(digitsOnly)
    if (cc != dialCode) { return false }
    return isValidPhoneNumber(cc, national)
}

// --- 私有辅助 ---

private func regionToDialCode(region: String): String {
    let r = region.toAsciiLower()
    match (r) {
        case "us" | "ca" => "1"
        case "gb" | "uk" => "44"
        case "cn" | "china" => "86"
        case "jp" | "japan" => "81"
        case "kr" | "korea" => "82"
        case "de" | "germany" => "49"
        case "fr" | "france" => "33"
        case "in" | "india" => "91"
        case "ru" | "russia" => "7"
        case "br" | "brazil" => "55"
        case "au" | "australia" => "61"
        case "mx" | "mexico" => "52"
        case "it" | "italy" => "39"
        case "es" | "spain" => "34"
        case "nl" | "netherlands" => "31"
        case "pl" | "poland" => "48"
        case "tr" | "turkey" => "90"
        case "vn" | "vietnam" => "84"
        case "hk" | "hong kong" => "852"
        case "tw" | "taiwan" => "886"
        case _ => region
    }
}

/**
 * 逐字对照 `AuthorizationSequenceCountrySelectionController.swift:229-268
 * lookupCountryIdByNumber` 的调用点语义：把「digits → (国家码, 国内号码)」的查表工作委托给
 * `CountryData.lookupCountryIdByNumber`（M1，源侧 `PhoneCountries.txt` 的忠实转录 + 最长前缀
 * 查表），本函数只做拆分，不再自建 `knownCodes` 近似表。
 */
private func extractCountryCodeAndNational(digitsOnly: String): (String, String) {
    match (lookupCountryIdByNumber(digitsOnly)) {
        case Some((code, _iso2, _pattern, _name)) => (code, digitsOnly[code.size..digitsOnly.size])
        case None => ("", digitsOnly)
    }
}

private func normalizeCountryCode(code: String): String {
    if (code.startsWith("+")) {
        return code[1..code.size]
    }
    return code
}

private func extractDigits(s: String): String {
    var out = ""
    let runes = s.toRuneArray()
    for (r in runes) {
        let code = UInt32(r)
        if (code >= 48 && code <= 57) {
            out = out + r.toString()
        }
    }
    return out
}

/** 国内号码 pattern 中 `X` 占位符的总数（不含 dialCode，见文件头说明），用于
 *  isValidPhoneNumber 的位数校验。 */
private func countMaskDigits(mask: String): Int64 {
    var count: Int64 = 0
    for (r in mask.toRuneArray()) {
        if (r == r'X') {
            count = count + 1
        }
    }
    return count
}

private func runesToString(runes: ArrayList<Rune>): String {
    var out = ""
    for (r in runes) {
        out = out + r.toString()
    }
    return out
}
