package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.{getStripeBinding, setStripeDefaultPublishableKey, StripeCardParams, StripeTokenResultType}

/**
 * Stripe 支付工具接口
 *
 * 对应 Telegram-iOS Stripe 上层调用封装。
 * 提供：
 * - 卡号 Luhn 校验
 * - 卡品牌检测（Visa/MasterCard/Amex 等）
 * - 卡号格式化（分组显示）
 * - 创建 token 的便捷封装
 */

/**
 * 卡品牌枚举（对应 STPCardBrand）
 */
public enum StripeCardBrand {
    | Visa
    | MasterCard
    | Amex
    | Discover
    | JCB
    | DinersClub
    | Other
    | Unknown

    public func displayName(): String {
        match (this) {
            case Visa => "Visa"
            case MasterCard => "MasterCard"
            case Amex => "Amex"
            case Discover => "Discover"
            case JCB => "JCB"
            case DinersClub => "Diners Club"
            case Other => "Other"
            case Unknown => "Unknown"
        }
    }
}

/**
 * Luhn 算法校验卡号
 * @param cardNumber 纯数字卡号（无空格）
 * @return true 表示通过校验
 */
public func stripeLuhnCheck(cardNumber: String): Bool {
    let digits = extractDigitsOnly(cardNumber)
    if (digits.size < 13 || digits.size > 19) {
        return false
    }
    var sum: Int32 = 0
    let runes = digits.toRuneArray()
    var alternate = false
    var i = runes.size - 1
    while (i >= 0) {
        let code = UInt32(runes[i])
        if (code < 48 || code > 57) {
            return false
        }
        var n = Int32(code - 48)
        if (alternate) {
            n = n * 2
            if (n > 9) {
                n = n - 9
            }
        }
        sum = sum + n
        alternate = !alternate
        i = i - 1
    }
    return (sum % 10) == 0
}

/**
 * 检测卡品牌（根据卡号前缀）
 */
public func stripeDetectCardBrand(cardNumber: String): StripeCardBrand {
    let digits = extractDigitsOnly(cardNumber)
    if (digits.size < 4) {
        return StripeCardBrand.Unknown
    }
    let first2 = digits[0..2]
    if (digits.startsWith("4")) {
        return StripeCardBrand.Visa
    }
    if (digits.startsWith("5") && (first2 >= "51" && first2 <= "55")) {
        return StripeCardBrand.MasterCard
    }
    if (digits.startsWith("34") || digits.startsWith("37")) {
        return StripeCardBrand.Amex
    }
    if (digits.startsWith("6011") || digits.startsWith("65")) {
        return StripeCardBrand.Discover
    }
    if (digits.startsWith("35")) {
        return StripeCardBrand.JCB
    }
    if (digits.startsWith("36") || digits.startsWith("38") || digits.startsWith("39")) {
        return StripeCardBrand.DinersClub
    }
    return StripeCardBrand.Unknown
}

/**
 * 格式化卡号（按品牌分组，如 4242 4242 4242 4242）
 */
public func stripeFormatCardNumber(raw: String, brand: StripeCardBrand): String {
    let digits = extractDigitsOnly(raw)
    if (digits.size == 0) {
        return ""
    }
    match (brand) {
        case StripeCardBrand.Amex =>
            formatWithSpacesAmex(digits)
        case _ =>
            formatWithSpacesDefault(digits)
    }
}

/**
 * 校验卡参数是否完整有效
 */
public func stripeValidateCardParams(number: String, expMonth: Int32, expYear: Int32, cvc: String): String {
    let digits = extractDigitsOnly(number)
    if (digits.size < 13 || digits.size > 19) {
        return "Invalid card number length"
    }
    if (!stripeLuhnCheck(number)) {
        return "Invalid card number"
    }
    if (expMonth < 1 || expMonth > 12) {
        return "Invalid expiry month"
    }
    let currentYear: Int32 = 2026
    let currentMonth: Int32 = 3
    if (expYear < currentYear) {
        return "Card expired"
    }
    if (expYear == currentYear && expMonth < currentMonth) {
        return "Card expired"
    }
    let brand = stripeDetectCardBrand(number)
    let cvcLen = Int32(extractDigitsOnly(cvc).size)
    match (brand) {
        case StripeCardBrand.Amex =>
            if (cvcLen != 4) {
                return "Amex requires 4-digit CVC"
            }
        case _ =>
            if (cvcLen != 3) {
                return "CVC must be 3 digits"
            }
    }
    return ""
}

/**
 * 配置 Stripe 并创建 token
 * @param publishableKey Stripe publishable key (pk_xxx)
 * @param params 卡参数
 * @param completion 回调
 */
public func stripeCreateToken(publishableKey: String, params: StripeCardParams, completion: (StripeTokenResultType) -> Unit): Unit {
    setStripeDefaultPublishableKey(publishableKey)
    let binding = getStripeBinding()
    binding.createTokenWithCard(params, completion)
}

private func extractDigitsOnly(s: String): String {
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

private func formatWithSpacesDefault(digits: String): String {
    return formatWithGroupSize(digits, 4)
}

private func formatWithSpacesAmex(digits: String): String {
    let runes = digits.toRuneArray()
    if (runes.size <= 4) {
        return digits
    }
    if (runes.size <= 10) {
        return digits[0..4] + " " + digits[4..]
    }
    return digits[0..4] + " " + digits[4..10] + " " + digits[10..]
}

private func formatWithGroupSize(digits: String, groupSize: Int32): String {
    var result = ""
    let runes = digits.toRuneArray()
    var idx: Int64 = 0
    while (idx < Int64(runes.size)) {
        if (result.size > 0) {
            result = result + " "
        }
        let remaining = Int64(runes.size) - idx
        let count = if (remaining >= Int64(groupSize)) { Int64(groupSize) } else { remaining }
        for (j in 0..count) {
            result = result + runes[idx + j].toString()
        }
        idx = idx + count
    }
    return result
}
