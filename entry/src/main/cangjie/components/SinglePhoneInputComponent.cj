package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.utils.*

/**
 * 单行电话输入组件 — 紧凑版
 *
 * 对应 iOS SinglePhoneInputNode — 单个输入框输入完整国际号码（含国家代码），
 * 自动检测国家、显示国旗、格式化显示。
 *
 * 与 PhoneInputComponent 区别：无独立国家选择器，用户直接输入 "+86 138 0000 0000"
 * 数据源来自 utils/CountryData.cj，无独立 Service
 *
 * - Props: phoneNumber 初始值
 * - onPhoneChanged: 返回标准化号码（仅数字+前缀+）
 * - onCountryDetected: (dialCode, countryName) 检测到国家时回调
 */
@Component
public class SinglePhoneInputComponent {
    var phoneNumber: String = ""

    public var onPhoneChanged: (String) -> Unit = { _: String => }
    public var onCountryDetected: (String, String) -> Unit = { _: String, _: String => }

    @State var displayText: String = ""

    public func aboutToAppear(): Unit {
        if (this.phoneNumber.size > 0) {
            let norm = SinglePhoneInputComponent.normalizePhoneNumber(this.phoneNumber)
            this.displayText = this.formatForDisplay(norm)
        }
    }

    func build() {
        Row {
            Text(this.getDisplayFlag())
                .fontSize(20)
                .margin(right: 8)
            TextInput(text: this.displayText, placeholder: "+86 138 0000 0000")
                .fontSize(18)
                .layoutWeight(1)
                .onChange({ value: String =>
                    this.handleInputChange(value)
                })
        }
        .width(100.percent)
        .padding(left: 16, right: 16)
    }

    /**
     * 处理用户输入：标准化、格式化、检测国家、回调
     */
    private func handleInputChange(raw: String): Unit {
        let normalized = SinglePhoneInputComponent.normalizePhoneNumber(raw)
        let formatted = this.formatForDisplay(normalized)
        let (dialCode, countryName) = this.detectCountry(normalized)
        this.displayText = formatted
        this.onPhoneChanged(normalized)
        if (dialCode.size > 0 && countryName.size > 0) {
            this.onCountryDetected(dialCode, countryName)
        }
    }

    /**
     * 标准化号码：仅保留 + 和数字
     */
    public static func normalizePhoneNumber(raw: String): String {
        let runes = raw.toRuneArray()
        let sb = StringBuilder()
        var seenPlus = false
        for (r in runes) {
            let code = Int64(UInt32(r))
            if (code == 43) {
                if (!seenPlus) {
                    sb.append(r)
                    seenPlus = true
                }
            } else if (code >= 48 && code <= 57) {
                sb.append(r)
            }
        }
        return sb.toString()
    }

    /**
     * 根据标准化号码格式化显示（插入空格）
     */
    private func formatForDisplay(normalized: String): String {
        if (normalized.size == 0) {
            return ""
        }
        let (dialCode, rest) = this.splitDialCodeAndRest(normalized)
        if (rest.size == 0) {
            return dialCode
        }
        let formattedRest = this.formatRestDigits(rest)
        return dialCode + " " + formattedRest
    }

    private func splitDialCodeAndRest(normalized: String): (String, String) {
        if (normalized.size == 0) {
            return ("", "")
        }
        let hasPlus = normalized.startsWith("+")
        let digits = if (hasPlus) { normalized[1..Int64(normalized.size)] } else { normalized }
        let (code, rest) = this.matchLongestDialCode(digits)
        let prefix = if (hasPlus) { "+" + code } else { code }
        return (prefix, rest)
    }

    private func matchLongestDialCode(digits: String): (String, String) {
        let countries = getCountryList()
        var bestLen: Int64 = 0
        var bestCode: String = ""
        for (i in 0..countries.size) {
            let dialCode = countries[i][1]
            let codeDigits = if (dialCode.startsWith("+")) { dialCode[1..Int64(dialCode.size)] } else { dialCode }
            if (codeDigits.size > 0 && digits.startsWith(codeDigits) && Int64(codeDigits.size) > bestLen) {
                bestLen = Int64(codeDigits.size)
                bestCode = dialCode
            }
        }
        if (bestCode.size > 0) {
            let codeDigits = if (bestCode.startsWith("+")) { bestCode[1..Int64(bestCode.size)] } else { bestCode }
            let rest = if (Int64(digits.size) > Int64(codeDigits.size)) { digits[Int64(codeDigits.size)..Int64(digits.size)] } else { "" }
            return (bestCode, rest)
        }
        return ("", digits)
    }

    private func formatRestDigits(rest: String): String {
        if (rest.size <= 3) {
            return rest
        }
        if (rest.size <= 7) {
            return rest[0..3] + " " + rest[3..Int64(rest.size)]
        }
        if (rest.size <= 11) {
            return rest[0..3] + " " + rest[3..7] + " " + rest[7..Int64(rest.size)]
        }
        var result = rest[0..3] + " " + rest[3..7] + " " + rest[7..11]
        var idx: Int64 = 11
        while (idx < Int64(rest.size)) {
            let end = if (idx + 4 <= Int64(rest.size)) { idx + 4 } else { Int64(rest.size) }
            result = result + " " + rest[idx..end]
            idx = end
        }
        return result
    }

    /**
     * 从标准化号码检测国家，返回 (dialCode, countryName)
     */
    private func detectCountry(normalized: String): (String, String) {
        if (normalized.size == 0) {
            return ("", "")
        }
        let digits = if (normalized.startsWith("+")) { normalized[1..Int64(normalized.size)] } else { normalized }
        let countries = getCountryList()
        var bestLen: Int64 = 0
        var bestCode: String = ""
        var bestName: String = ""
        for (i in 0..countries.size) {
            let dialCode = countries[i][1]
            let codeDigits = if (dialCode.startsWith("+")) { dialCode[1..Int64(dialCode.size)] } else { dialCode }
            if (codeDigits.size > 0 && digits.startsWith(codeDigits) && Int64(codeDigits.size) > bestLen) {
                bestLen = Int64(codeDigits.size)
                bestCode = dialCode
                bestName = countries[i][0]
            }
        }
        return (bestCode, bestName)
    }

    /**
     * 获取当前显示用的国旗 emoji
     *
     * D1 同根因对齐：detectCountry 已按同一行返回 (dialCode, countryName)，但原实现
     * 丢弃 countryName、仅用 dialCode 反查（getEmojiByCode 按区号首匹配，+1/+7 等
     * 二义区号会恒定命中表中排序更靠前的国家）。改为按 (countryName, dialCode) 二元组
     * 精确匹配同一行取旗，保持未命中时原有的 "🌐" 降级不变。
     */
    private func getDisplayFlag(): String {
        let normalized = SinglePhoneInputComponent.normalizePhoneNumber(this.displayText)
        let (dialCode, name) = this.detectCountry(normalized)
        if (dialCode.size == 0 || name.size == 0) {
            return "🌐"
        }
        let countries = getCountryList()
        for (i in 0..countries.size) {
            if (countries[i][0] == name && countries[i][1] == dialCode) {
                return countries[i][2]
            }
        }
        return "🌐"
    }
}
