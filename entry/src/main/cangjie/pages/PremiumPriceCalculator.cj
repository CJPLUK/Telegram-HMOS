package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.services.PremiumPeriodOption
import std.collection.ArrayList

/**
 * P2-300 Premium 价格/周期计算工具
 *
 * 对应 iOS PremiumUI prettyPrice / 月单价 / 折扣%
 * 纯计算模块，不接 IAP。数据从 PremiumPeriodOption 读取。
 *
 * 计算规则:
 *   - amount 单位是分（最小货币单位），如 EUR 的分 = 欧分
 *   - monthlyAmount = amount / months
 *   - prettyPrice: 整元部分 + 小数部分（2位），如 "4.99"
 *   - currencyFormat: 货币符号前缀 + prettyPrice
 *   - discountPercent: 相对最贵单月方案的省钱比例（iOS 逻辑: 最高单月价格作基准）
 */
public class PremiumPriceInfo {
    public var months: Int32 = 0
    public var totalAmount: Int64 = 0
    public var currency: String = ""
    public var monthlyAmount: Int64 = 0
    public var prettyMonthlyPrice: String = ""
    public var prettyTotalPrice: String = ""
    public var currencySymbol: String = ""
    public var formattedMonthlyPrice: String = ""
    public var formattedTotalPrice: String = ""
    public var discountPercent: Int32 = 0
    public var isBestValue: Bool = false
    public var savingsBadge: String = ""
}

public class PremiumPriceCalculator {

    /**
     * 货币代码 -> 货币符号映射
     */
    public static func currencySymbol(currency!: String): String {
        if (currency == "USD") { return "$" }
        if (currency == "EUR") { return "€" }
        if (currency == "GBP") { return "£" }
        if (currency == "CNY") { return "¥" }
        if (currency == "JPY") { return "¥" }
        if (currency == "RUB") { return "₽" }
        if (currency == "KRW") { return "₩" }
        if (currency == "INR") { return "₹" }
        if (currency == "TRY") { return "₺" }
        if (currency == "BRL") { return "R$" }
        if (currency == "AED") { return "AED" }
        return currency
    }

    /**
     * prettyPrice: amount（分）→ "整数.小数" 字符串
     * 对于 JPY/KRW 等无小数点货币：amount 直接是整数
     */
    public static func prettyPrice(amount!: Int64, currency!: String): String {
        if (currency == "JPY" || currency == "KRW") {
            return "${amount}"
        }
        let major = amount / 100
        let minor = amount % 100
        if (minor < 10) {
            return "${major}.0${minor}"
        }
        return "${major}.${minor}"
    }

    /**
     * 格式化价格 = 货币符号 + prettyPrice
     */
    public static func formatPrice(amount!: Int64, currency!: String): String {
        let sym = PremiumPriceCalculator.currencySymbol(currency: currency)
        let price = PremiumPriceCalculator.prettyPrice(amount: amount, currency: currency)
        return "${sym}${price}"
    }

    /**
     * 计算折扣百分比 (vs 最贵月价格方案)
     * discountPercent = round((1 - monthly/maxMonthly) * 100)
     * 使用四舍五入避免整数截断误差，与 getDefaultPriceInfoList fallback 值保持一致
     */
    public static func discountPercent(monthlyAmount!: Int64, maxMonthlyAmount!: Int64): Int32 {
        if (maxMonthlyAmount <= 0) { return 0 }
        if (monthlyAmount >= maxMonthlyAmount) { return 0 }
        let diff = maxMonthlyAmount - monthlyAmount
        let pct = Int32((diff * 100 + maxMonthlyAmount / 2) / maxMonthlyAmount)
        return pct
    }

    /**
     * 将 PremiumPeriodOption 列表转换为带价格信息的完整列表
     * 最高月单价方案 discountPercent=0（基准），其他方案计算折扣
     * 月单价最低方案标记 isBestValue=true
     */
    public static func buildPriceInfoList(options!: ArrayList<PremiumPeriodOption>): Array<PremiumPriceInfo> {
        if (options.size == 0) {
            return Array<PremiumPriceInfo>(0, repeat: PremiumPriceInfo())
        }

        let results = ArrayList<PremiumPriceInfo>()

        for (opt in options) {
            let info = PremiumPriceInfo()
            info.months = opt.months
            info.totalAmount = opt.amount
            info.currency = opt.currency
            info.currencySymbol = PremiumPriceCalculator.currencySymbol(currency: opt.currency)
            let mths = if (opt.months > 0) { Int64(opt.months) } else { 1 }
            info.monthlyAmount = opt.amount / mths
            info.prettyMonthlyPrice = PremiumPriceCalculator.prettyPrice(amount: info.monthlyAmount, currency: opt.currency)
            info.prettyTotalPrice = PremiumPriceCalculator.prettyPrice(amount: opt.amount, currency: opt.currency)
            info.formattedMonthlyPrice = PremiumPriceCalculator.formatPrice(amount: info.monthlyAmount, currency: opt.currency)
            info.formattedTotalPrice = PremiumPriceCalculator.formatPrice(amount: opt.amount, currency: opt.currency)
            results.add(info)
        }

        // 找最贵月单价（1-month plan 通常最贵）作为折扣基准
        var maxMonthly: Int64 = 0
        for (info in results) {
            if (info.monthlyAmount > maxMonthly) {
                maxMonthly = info.monthlyAmount
            }
        }

        // 找最便宜月单价（通常是年付），标记 isBestValue
        var minMonthly: Int64 = 9223372036854775807
        for (info in results) {
            if (info.monthlyAmount < minMonthly) {
                minMonthly = info.monthlyAmount
            }
        }

        // 填写折扣 & 省钱徽章
        for (info in results) {
            let pct = PremiumPriceCalculator.discountPercent(monthlyAmount: info.monthlyAmount, maxMonthlyAmount: maxMonthly)
            info.discountPercent = pct
            if (info.monthlyAmount == minMonthly && info.months > 1) {
                info.isBestValue = true
                if (pct > 0) {
                    info.savingsBadge = "Save ${pct}%"
                } else {
                    info.savingsBadge = "Best Value"
                }
            } else if (pct > 0) {
                info.savingsBadge = "Save ${pct}%"
            }
        }

        return Array<PremiumPriceInfo>(results.size, { i: Int64 => results[i] })
    }

    /**
     * 格式化订阅周期选项展示文本（用于 PremiumPage 订阅面板）
     * 格式: "12 Months — $X.XX/mo"
     */
    public static func periodLabel(info!: PremiumPriceInfo): String {
        let months = info.months
        let periodStr = if (months == 1) {
            "1 Month"
        } else if (months == 6) {
            "6 Months"
        } else if (months == 12) {
            "12 Months"
        } else {
            "${months} Months"
        }
        return "${periodStr} — ${info.formattedMonthlyPrice}/mo"
    }
}
