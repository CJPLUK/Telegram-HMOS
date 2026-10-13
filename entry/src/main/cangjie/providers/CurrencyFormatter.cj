package ohos_app_cangjie_entry.providers

import std.math.abs

/**
 * CurrencyFormatterEntry — 单个币种的格式化参数
 *
 * 移植自 iOS TelegramStringFormatting/CurrencyFormat.swift
 * 及 TelegramUI/Resources/currencies.json（ground truth）
 *
 * 字段顺序: symbol, thousandsSeparator, decimalSeparator,
 *            symbolOnLeft, spaceBetweenAmountAndSymbol, decimalDigits
 */
public struct CurrencyFormatterEntry {
    public let symbol: String
    public let thousandsSeparator: String
    public let decimalSeparator: String
    public let symbolOnLeft: Bool
    public let spaceBetweenAmountAndSymbol: Bool
    public let decimalDigits: Int64

    public init(
        symbol: String,
        thousandsSeparator: String,
        decimalSeparator: String,
        symbolOnLeft: Bool,
        spaceBetweenAmountAndSymbol: Bool,
        decimalDigits: Int64
    ) {
        this.symbol = symbol
        this.thousandsSeparator = thousandsSeparator
        this.decimalSeparator = decimalSeparator
        this.symbolOnLeft = symbolOnLeft
        this.spaceBetweenAmountAndSymbol = spaceBetweenAmountAndSymbol
        this.decimalDigits = decimalDigits
    }
}

/**
 * 按币种代码查找 CurrencyFormatterEntry
 * 未命中则返回 USD 的条目（保持与 iOS 相同的 fallback 行为）
 */
func getCurrencyEntry(currency: String): CurrencyFormatterEntry {
    let upper = currency.toAsciiUpper()
    return lookupCurrencyEntry(upper)
}

/**
 * 格式化整数部分为千分位分隔字符串
 * 例: formatIntegerWithSeparator(1234567, ",") → "1,234,567"
 * 例: formatIntegerWithSeparator(0, ",")       → "0"
 */
func formatIntegerWithSeparator(number: Int64, separator: String): String {
    if (number == 0) {
        return "0"
    }
    let numStr = "${number}"
    let totalLen = numStr.size
    var result = ""
    var idx = 0
    while (idx < totalLen) {
        let remaining = totalLen - idx
        if (remaining % 3 == 0 && idx > 0 && separator.size > 0) {
            result = result + separator
        }
        result = result + numStr[idx..idx + 1]
        idx = idx + 1
    }
    return result
}

/**
 * 将 Telegram 金额整数（最小单位，如分）格式化为带币种符号的字符串
 *
 * 对应 iOS formatCurrencyAmount(_:currency:) in CurrencyFormat.swift
 *
 * 规则（与 iOS 完全一致）：
 * - 负号前置
 * - 按 symbolOnLeft 决定符号在左/右
 * - spaceBetweenAmountAndSymbol 控制是否在符号和数字间插入空格
 * - decimalDigits 决定小数位数（0 = 整数; 2 = 分; 3 = 千分之一等）
 * - 整数部分按 thousandsSeparator 千分位分组
 * - 小数部分按 decimalSeparator 分隔
 *
 * 特例：
 * - XTR（Telegram Stars）: 无小数，直接返回数字字符串
 * - TON: decimalDigits=9，由币种表内置处理
 * - 未知币种：fallback 到 USD 格式
 *
 * @param currency 三字母 ISO 4217 货币代码（不区分大小写）
 * @param amount   Telegram 最小单位金额（Int64）
 * @return         格式化后的字符串
 */
public func formatCurrencyAmount(currency: String, amount: Int64): String {
    if (currency == "XTR") {
        return "${amount}"
    }
    let entry = getCurrencyEntry(currency)
    var result = ""
    if (amount < 0) {
        result = result + "-"
    }
    let absAmount = abs(amount)
    var integerPart: Int64 = absAmount
    var fractionalDigits: Array<String> = Array<String>(entry.decimalDigits, { _: Int64 => "0" })
    var fi: Int64 = entry.decimalDigits - 1
    while (fi >= 0) {
        let digit = integerPart % 10
        integerPart = integerPart / 10
        fractionalDigits[fi] = "${digit}"
        fi = fi - 1
    }
    let intStr = formatIntegerWithSeparator(integerPart, entry.thousandsSeparator)
    if (entry.symbolOnLeft) {
        result = result + entry.symbol
        if (entry.spaceBetweenAmountAndSymbol) {
            result = result + " "
        }
    }
    result = result + intStr
    if (entry.decimalDigits > 0) {
        result = result + entry.decimalSeparator
        var di: Int64 = 0
        while (di < entry.decimalDigits) {
            result = result + fractionalDigits[di]
            di = di + 1
        }
    }
    if (!entry.symbolOnLeft) {
        if (entry.spaceBetweenAmountAndSymbol) {
            result = result + " "
        }
        result = result + entry.symbol
    }
    return result
}

/**
 * 静态币种表 — 移植自 iOS currencies.json + getCurrencyExp()
 *
 * 覆盖范围: 全 currencies.json 列出的 ~150 种货币 + TON + XTR
 * 小数位 ground truth: iOS getCurrencyExp() 函数（覆盖 JSON decimalDigits 字段）
 * thousandsSeparator ground truth: iOS currencies.json（NBSP=U+00A0 vs ASCII 空格区分）
 *
 * decimalDigits 精要（来源: getCurrencyExp()，非 JSON decimalDigits）:
 *   0 位: BIF BYR CLP CVE DJF GNF ISK JPY KMF KRW MGA PYG RWF UGX VND VUV XAF XOF XPF
 *   1 位: MRO
 *   2 位: 绝大多数货币（USD EUR GBP CNY RUB BDT BND BTN KHR KPW LAK LKR MVR MZN TMT 等）
 *   3 位: BHD IQD JOD KWD LYD OMR TND
 *   4 位: CLF
 *   9 位: TON
 *
 * 构造参数顺序: (symbol, thousandsSeparator, decimalSeparator,
 *                symbolOnLeft, spaceBetweenAmountAndSymbol, decimalDigits)
 */
func lookupCurrencyEntry(code: String): CurrencyFormatterEntry {
    if (code == "AED") { return CurrencyFormatterEntry("د.إ.‏", ",", ".", true, true, 2) }
    if (code == "AFN") { return CurrencyFormatterEntry("؋", ",", ".", true, false, 2) }
    if (code == "ALL") { return CurrencyFormatterEntry("Lek", ".", ",", false, false, 2) }
    if (code == "AMD") { return CurrencyFormatterEntry("֏", ",", ".", false, true, 2) }
    if (code == "ANG") { return CurrencyFormatterEntry("ƒ", ",", ".", true, false, 2) }
    if (code == "AOA") { return CurrencyFormatterEntry("Kz", ",", ".", true, false, 2) }
    if (code == "ARS") { return CurrencyFormatterEntry("$", ".", ",", true, true, 2) }
    if (code == "AUD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "AWG") { return CurrencyFormatterEntry("ƒ", ",", ".", true, false, 2) }
    if (code == "AZN") { return CurrencyFormatterEntry("₼", " ", ",", false, true, 2) }
    if (code == "BAM") { return CurrencyFormatterEntry("КМ", ".", ",", false, true, 2) }
    if (code == "BBD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "BDT") { return CurrencyFormatterEntry("৳", ",", ".", true, true, 2) }
    if (code == "BGN") { return CurrencyFormatterEntry("лв.", " ", ",", false, true, 2) }
    if (code == "BHD") { return CurrencyFormatterEntry("د.ب.‏", ",", ".", true, true, 3) }
    if (code == "BIF") { return CurrencyFormatterEntry("FBu", ",", ".", false, false, 0) }
    if (code == "BMD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "BND") { return CurrencyFormatterEntry("$", ".", ",", true, false, 2) }
    if (code == "BOB") { return CurrencyFormatterEntry("Bs", ".", ",", true, true, 2) }
    if (code == "BRL") { return CurrencyFormatterEntry("R$", ".", ",", true, true, 2) }
    if (code == "BSD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "BTC") { return CurrencyFormatterEntry("Ƀ", ",", ".", false, false, 2) }
    if (code == "BTN") { return CurrencyFormatterEntry("Nu.", ",", ".", true, true, 2) }
    if (code == "BWP") { return CurrencyFormatterEntry("P", ",", ".", true, false, 2) }
    if (code == "BYN") { return CurrencyFormatterEntry("BYN", " ", ",", false, true, 2) }
    if (code == "BYR") { return CurrencyFormatterEntry("р.", " ", ",", false, true, 0) }
    if (code == "BZD") { return CurrencyFormatterEntry("BZ$", ",", ".", true, false, 2) }
    if (code == "CAD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "CDF") { return CurrencyFormatterEntry("FC", ",", ".", false, false, 2) }
    if (code == "CHF") { return CurrencyFormatterEntry("CHF", "'", ".", false, true, 2) }
    if (code == "CLF") { return CurrencyFormatterEntry("UF", ".", ",", true, true, 4) }
    if (code == "CLP") { return CurrencyFormatterEntry("$", ".", ",", true, true, 0) }
    if (code == "CNY") { return CurrencyFormatterEntry("¥", ",", ".", true, false, 2) }
    if (code == "COP") { return CurrencyFormatterEntry("$", ".", ",", true, true, 2) }
    if (code == "CRC") { return CurrencyFormatterEntry("₡", ".", ",", true, false, 2) }
    if (code == "CUC") { return CurrencyFormatterEntry("CUC", ",", ".", true, false, 2) }
    if (code == "CUP") { return CurrencyFormatterEntry("$MN", ",", ".", true, false, 2) }
    if (code == "CVE") { return CurrencyFormatterEntry("$", ",", ".", true, false, 0) }
    if (code == "CZK") { return CurrencyFormatterEntry("Kč", " ", ",", false, true, 2) }
    if (code == "DJF") { return CurrencyFormatterEntry("Fdj", ",", ".", false, false, 0) }
    if (code == "DKK") { return CurrencyFormatterEntry("kr.", "", ",", false, true, 2) }
    if (code == "DOP") { return CurrencyFormatterEntry("RD$", ",", ".", true, false, 2) }
    if (code == "DZD") { return CurrencyFormatterEntry("د.ج.‏", ",", ".", true, true, 2) }
    if (code == "EGP") { return CurrencyFormatterEntry("ج.م.‏", ",", ".", true, true, 2) }
    if (code == "ERN") { return CurrencyFormatterEntry("Nfk", ",", ".", false, false, 2) }
    if (code == "ETB") { return CurrencyFormatterEntry("ETB", ",", ".", true, false, 2) }
    if (code == "EUR") { return CurrencyFormatterEntry("€", " ", ",", false, true, 2) }
    if (code == "FJD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "FKP") { return CurrencyFormatterEntry("£", ",", ".", true, false, 2) }
    if (code == "GBP") { return CurrencyFormatterEntry("£", ",", ".", true, false, 2) }
    if (code == "GEL") { return CurrencyFormatterEntry("Lari", " ", ",", false, true, 2) }
    if (code == "GHS") { return CurrencyFormatterEntry("₵", ",", ".", true, false, 2) }
    if (code == "GIP") { return CurrencyFormatterEntry("£", ",", ".", true, false, 2) }
    if (code == "GMD") { return CurrencyFormatterEntry("D", ",", ".", false, false, 2) }
    if (code == "GNF") { return CurrencyFormatterEntry("FG", ",", ".", false, false, 0) }
    if (code == "GTQ") { return CurrencyFormatterEntry("Q", ",", ".", true, false, 2) }
    if (code == "GYD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "HKD") { return CurrencyFormatterEntry("HK$", ",", ".", true, false, 2) }
    if (code == "HNL") { return CurrencyFormatterEntry("L.", ",", ".", true, true, 2) }
    if (code == "HRK") { return CurrencyFormatterEntry("kn", ".", ",", false, true, 2) }
    if (code == "HTG") { return CurrencyFormatterEntry("G", ",", ".", true, false, 2) }
    if (code == "HUF") { return CurrencyFormatterEntry("Ft", " ", ",", false, true, 2) }
    if (code == "IDR") { return CurrencyFormatterEntry("Rp", ".", ",", true, false, 2) }
    if (code == "ILS") { return CurrencyFormatterEntry("₪", ",", ".", true, true, 2) }
    if (code == "INR") { return CurrencyFormatterEntry("₹", ",", ".", true, false, 2) }
    if (code == "IQD") { return CurrencyFormatterEntry("د.ع.‏", ",", ".", true, true, 3) }
    if (code == "IRR") { return CurrencyFormatterEntry("﷼", ",", "/", true, true, 2) }
    if (code == "ISK") { return CurrencyFormatterEntry("kr.", ".", ",", false, true, 0) }
    if (code == "JMD") { return CurrencyFormatterEntry("J$", ",", ".", true, false, 2) }
    if (code == "JOD") { return CurrencyFormatterEntry("د.ا.‏", ",", ".", true, true, 3) }
    if (code == "JPY") { return CurrencyFormatterEntry("¥", ",", ".", true, false, 0) }
    if (code == "KES") { return CurrencyFormatterEntry("S", ",", ".", true, false, 2) }
    if (code == "KGS") { return CurrencyFormatterEntry("сом", " ", "-", false, true, 2) }
    if (code == "KHR") { return CurrencyFormatterEntry("៛", ",", ".", false, false, 2) }
    if (code == "KMF") { return CurrencyFormatterEntry("CF", ",", ".", false, false, 0) }
    if (code == "KPW") { return CurrencyFormatterEntry("₩", ",", ".", true, false, 2) }
    if (code == "KRW") { return CurrencyFormatterEntry("₩", ",", ".", true, false, 0) }
    if (code == "KWD") { return CurrencyFormatterEntry("د.ك.‏", ",", ".", true, true, 3) }
    if (code == "KYD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "KZT") { return CurrencyFormatterEntry("₸", " ", "-", true, false, 2) }
    if (code == "LAK") { return CurrencyFormatterEntry("₭", ",", ".", false, false, 2) }
    if (code == "LBP") { return CurrencyFormatterEntry("ل.ل.‏", ",", ".", true, true, 2) }
    if (code == "LKR") { return CurrencyFormatterEntry("₨", ",", ".", true, true, 2) }
    if (code == "LRD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "LSL") { return CurrencyFormatterEntry("M", ",", ".", false, false, 2) }
    if (code == "LYD") { return CurrencyFormatterEntry("د.ل.‏", ",", ".", true, false, 3) }
    if (code == "MAD") { return CurrencyFormatterEntry("د.م.‏", ",", ".", true, true, 2) }
    if (code == "MDL") { return CurrencyFormatterEntry("lei", ",", ".", false, true, 2) }
    if (code == "MGA") { return CurrencyFormatterEntry("Ar", ",", ".", true, false, 0) }
    if (code == "MKD") { return CurrencyFormatterEntry("ден.", ".", ",", false, true, 2) }
    if (code == "MMK") { return CurrencyFormatterEntry("K", ",", ".", true, false, 2) }
    if (code == "MNT") { return CurrencyFormatterEntry("₮", " ", ",", true, false, 2) }
    if (code == "MOP") { return CurrencyFormatterEntry("MOP$", ",", ".", true, false, 2) }
    if (code == "MRO") { return CurrencyFormatterEntry("UM", ",", ".", false, false, 1) }
    if (code == "MTL") { return CurrencyFormatterEntry("₤", ",", ".", true, false, 2) }
    if (code == "MUR") { return CurrencyFormatterEntry("₨", ",", ".", true, false, 2) }
    if (code == "MVR") { return CurrencyFormatterEntry("MVR", ",", ".", false, true, 2) }
    if (code == "MWK") { return CurrencyFormatterEntry("MK", ",", ".", true, false, 2) }
    if (code == "MXN") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "MYR") { return CurrencyFormatterEntry("RM", ",", ".", true, false, 2) }
    if (code == "MZN") { return CurrencyFormatterEntry("MT", ",", ".", true, false, 2) }
    if (code == "NAD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "NGN") { return CurrencyFormatterEntry("₦", ",", ".", true, false, 2) }
    if (code == "NIO") { return CurrencyFormatterEntry("C$", ",", ".", true, true, 2) }
    if (code == "NOK") { return CurrencyFormatterEntry("kr", " ", ",", true, true, 2) }
    if (code == "NPR") { return CurrencyFormatterEntry("₨", ",", ".", true, false, 2) }
    if (code == "NZD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "OMR") { return CurrencyFormatterEntry("﷼", ",", ".", true, true, 3) }
    if (code == "PAB") { return CurrencyFormatterEntry("B/.", ",", ".", true, true, 2) }
    if (code == "PEN") { return CurrencyFormatterEntry("S/.", ",", ".", true, true, 2) }
    if (code == "PGK") { return CurrencyFormatterEntry("K", ",", ".", true, false, 2) }
    if (code == "PHP") { return CurrencyFormatterEntry("₱", ",", ".", true, false, 2) }
    if (code == "PKR") { return CurrencyFormatterEntry("₨", ",", ".", true, false, 2) }
    if (code == "PLN") { return CurrencyFormatterEntry("zł", " ", ",", false, true, 2) }
    if (code == "PYG") { return CurrencyFormatterEntry("₲", ".", ",", true, true, 0) }
    if (code == "QAR") { return CurrencyFormatterEntry("﷼", ",", ".", true, true, 2) }
    if (code == "RON") { return CurrencyFormatterEntry("lei", ".", ",", false, true, 2) }
    if (code == "RSD") { return CurrencyFormatterEntry("Дин.", ".", ",", false, true, 2) }
    if (code == "RUB") { return CurrencyFormatterEntry("₽", " ", ",", false, true, 2) }
    if (code == "RWF") { return CurrencyFormatterEntry("RWF", " ", ",", true, true, 0) }
    if (code == "SAR") { return CurrencyFormatterEntry("﷼", ",", ".", true, true, 2) }
    if (code == "SBD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "SCR") { return CurrencyFormatterEntry("₨", ",", ".", true, false, 2) }
    if (code == "SDD") { return CurrencyFormatterEntry("LSd", ",", ".", false, false, 2) }
    if (code == "SDG") { return CurrencyFormatterEntry("£‏", ",", ".", true, false, 2) }
    if (code == "SEK") { return CurrencyFormatterEntry("kr", ".", ",", false, true, 2) }
    if (code == "SGD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "SHP") { return CurrencyFormatterEntry("£", ",", ".", true, false, 2) }
    if (code == "SLL") { return CurrencyFormatterEntry("Le", ",", ".", true, false, 2) }
    if (code == "SOS") { return CurrencyFormatterEntry("S", ",", ".", true, false, 2) }
    if (code == "SRD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "STD") { return CurrencyFormatterEntry("Db", ",", ".", true, false, 2) }
    if (code == "SVC") { return CurrencyFormatterEntry("₡", ",", ".", true, false, 2) }
    if (code == "SYP") { return CurrencyFormatterEntry("£", ",", ".", true, true, 2) }
    if (code == "SZL") { return CurrencyFormatterEntry("E", ",", ".", true, false, 2) }
    if (code == "THB") { return CurrencyFormatterEntry("฿", ",", ".", true, false, 2) }
    if (code == "TJS") { return CurrencyFormatterEntry("TJS", " ", ";", false, true, 2) }
    if (code == "TMT") { return CurrencyFormatterEntry("m", " ", ",", false, false, 2) }
    if (code == "TND") { return CurrencyFormatterEntry("د.ت.‏", ",", ".", true, true, 3) }
    if (code == "TON") { return CurrencyFormatterEntry("TON", ".", ",", true, false, 9) }
    if (code == "TOP") { return CurrencyFormatterEntry("T$", ",", ".", true, false, 2) }
    if (code == "TRY") { return CurrencyFormatterEntry("TL", ".", ",", false, true, 2) }
    if (code == "TTD") { return CurrencyFormatterEntry("TT$", ",", ".", true, false, 2) }
    if (code == "TVD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "TWD") { return CurrencyFormatterEntry("NT$", ",", ".", true, false, 2) }
    if (code == "TZS") { return CurrencyFormatterEntry("TSh", ",", ".", true, false, 2) }
    if (code == "UAH") { return CurrencyFormatterEntry("₴", " ", ",", false, false, 2) }
    if (code == "UGX") { return CurrencyFormatterEntry("USh", ",", ".", true, false, 0) }
    if (code == "USD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "UYU") { return CurrencyFormatterEntry("$U", ".", ",", true, true, 2) }
    if (code == "UZS") { return CurrencyFormatterEntry("сўм", " ", ",", false, true, 2) }
    if (code == "VEB") { return CurrencyFormatterEntry("Bs.", ",", ".", true, false, 2) }
    if (code == "VEF") { return CurrencyFormatterEntry("Bs. F.", ".", ",", true, true, 2) }
    if (code == "VND") { return CurrencyFormatterEntry("₫", ".", ",", false, true, 0) }
    if (code == "VUV") { return CurrencyFormatterEntry("VT", ",", ".", false, false, 0) }
    if (code == "WON") { return CurrencyFormatterEntry("₩", ",", ".", true, false, 2) }
    if (code == "WST") { return CurrencyFormatterEntry("WS$", ",", ".", true, false, 2) }
    if (code == "XAF") { return CurrencyFormatterEntry("F", ",", ".", false, false, 0) }
    if (code == "XCD") { return CurrencyFormatterEntry("$", ",", ".", true, false, 2) }
    if (code == "XOF") { return CurrencyFormatterEntry("F", " ", ",", false, false, 0) }
    if (code == "XPF") { return CurrencyFormatterEntry("F", ",", ".", false, false, 0) }
    if (code == "YER") { return CurrencyFormatterEntry("﷼", ",", ".", true, true, 2) }
    if (code == "ZAR") { return CurrencyFormatterEntry("R", ",", ".", true, true, 2) }
    if (code == "ZMW") { return CurrencyFormatterEntry("ZK", ",", ".", true, false, 2) }
    return CurrencyFormatterEntry("$", ",", ".", true, false, 2)
}
