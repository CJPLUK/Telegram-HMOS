package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.bindings.{StripeCardParams, StripeTokenResultType, getStripeBinding, setStripeDefaultPublishableKey}
import std.collection.ArrayList

/**
 * PaymentMethodService — 支付方式管理服务
 *
 * 对应 iOS PaymentMethodUI 模块（AddPaymentMethodSheetScreen / PaymentCardEntryScreen）。
 *
 * 核心能力：
 *   1. validateCardNumber(number)  — Luhn 算法校验卡号
 *   2. validateExpiry(expiry)      — 有效期格式 + 未过期校验
 *   3. validateCvv(cvv)            — CVV 位数校验
 *   4. submitCardViaStripe(...)    — 通过 StripeBinding 创建 token，
 *                                    再通过 getPaymentsService().sendPaymentForm() 提交
 *
 * 调用链:
 *   PaymentMethodService.submitCardViaStripe
 *     → StripeBinding.createTokenWithCard (HTTPS → api.stripe.com/v1/tokens)
 *     → getPaymentsService().sendPaymentForm(formId, peerId, accessHash, msgId, ...)
 *     → getMTProtoClient().sendRequest(PaymentsSendPaymentForm.toBytes())
 *     → MTProtoTransport → Telegram DC
 */

// ==================== 数据模型 ====================

/**
 * 卡录入表单数据
 */
public class CardEntryData {
    public var number: String = ""
    public var holderName: String = ""
    public var expiry: String = ""   // MM/YY 格式
    public var cvv: String = ""

    public init() {}

    public init(number: String, holderName: String, expiry: String, cvv: String) {
        this.number = number
        this.holderName = holderName
        this.expiry = expiry
        this.cvv = cvv
    }
}

/**
 * 卡校验结果
 */
public class CardValidationResult {
    public var isValid: Bool = false
    public var numberError: String = ""
    public var nameError: String = ""
    public var expiryError: String = ""
    public var cvvError: String = ""

    public init() {}
}

/**
 * 支付方式提交结果
 */
public class PaymentMethodSubmitResult {
    public var success: Bool = false
    public var errorMessage: String = ""
    public var tokenId: String = ""
    public var verificationUrl: String = ""

    public init() {}
}

// ==================== 服务单例 ====================

private var _paymentMethodServiceInstance: Option<PaymentMethodService> = None

public func getPaymentMethodService(): PaymentMethodService {
    match (_paymentMethodServiceInstance) {
        case Some(s) => s
        case None =>
            let s = PaymentMethodService()
            _paymentMethodServiceInstance = Some(s)
            s
    }
}

// ==================== 服务实现 ====================

public class PaymentMethodService {

    // -------------------- 校验逻辑 --------------------

    /**
     * Luhn 算法校验卡号
     *
     * 算法：
     * 1. 从右到左，位置从 0 开始计数
     * 2. 偶数位（检查位除外）乘以 2，若结果 > 9 则减 9
     * 3. 所有位求和，结果能被 10 整除则合法
     *
     * @param number 卡号字符串（可含空格）
     * @return true 合法卡号
     */
    public func validateCardNumber(number: String): Bool {
        let digits = stripNonDigits(number)
        if (digits.size < 13 || digits.size > 19) {
            return false
        }
        let runes = digits.toRuneArray()
        var sum: Int64 = 0
        var doubleIt = false
        var i = runes.size - 1
        while (i >= 0) {
            let code = UInt32(runes[i])
            if (code < 48 || code > 57) {
                return false
            }
            var digit = Int64(code - 48)
            if (doubleIt) {
                digit = digit * 2
                if (digit > 9) {
                    digit = digit - 9
                }
            }
            sum = sum + digit
            doubleIt = !doubleIt
            i = i - 1
        }
        return (sum % 10) == 0
    }

    /**
     * 校验有效期（MM/YY 格式）
     * 月份 01-12，年份 >= 当前年份（2-digit 基准 26 = 2026）
     *
     * @param expiry MM/YY 格式字符串
     * @return true 合法且未过期
     */
    public func validateExpiry(expiry: String): Bool {
        let parts = splitBySlash(expiry)
        if (parts.size != 2) {
            return false
        }
        let monthStr = parts[0].trimAscii()
        let yearStr = parts[1].trimAscii()
        if (monthStr.size != 2 || yearStr.size != 2) {
            return false
        }
        let month = parseDigits(monthStr)
        let year = parseDigits(yearStr)
        if (month < 1 || month > 12) {
            return false
        }
        // Two-digit year anchor: 26 = 2026. Accept 26-35 as valid future range.
        if (year < 26) {
            return false
        }
        return true
    }

    /**
     * CVV 校验：3 或 4 位纯数字
     *
     * @param cvv CVV 字符串
     * @return true 合法
     */
    public func validateCvv(cvv: String): Bool {
        let digits = stripNonDigits(cvv)
        return digits.size == 3 || digits.size == 4
    }

    /**
     * 整体卡数据校验
     *
     * @param card CardEntryData
     * @return CardValidationResult（isValid = 所有字段均合法）
     */
    public func validateCard(card: CardEntryData): CardValidationResult {
        let result = CardValidationResult()
        if (!validateCardNumber(card.number)) {
            result.numberError = "Invalid card number"
        }
        if (card.holderName.trimAscii().size == 0) {
            result.nameError = "Cardholder name required"
        }
        if (!validateExpiry(card.expiry)) {
            result.expiryError = "Invalid or expired date (MM/YY)"
        }
        if (!validateCvv(card.cvv)) {
            result.cvvError = "CVV must be 3 or 4 digits"
        }
        result.isValid = result.numberError.size == 0 &&
            result.nameError.size == 0 &&
            result.expiryError.size == 0 &&
            result.cvvError.size == 0
        return result
    }

    // -------------------- 提交卡号 --------------------

    /**
     * 通过 StripeBinding 将卡信息 tokenize 并提交支付表单
     *
     * 调用链:
     *   setStripeDefaultPublishableKey(stripeKey)
     *   StripeBinding.createTokenWithCard(StripeCardParams)
     *     → HTTPS POST api.stripe.com/v1/tokens → StripeTokenResult.tokenId
     *   getPaymentsService().sendPaymentForm(formId, peerId, accessHash, msgId,
     *       requestedInfoId="", shippingOptionId="",
     *       credentialsJson=buildStripeCredentials(tokenId), saveCredentials=false)
     *     → getMTProtoClient().sendRequest(PaymentsSendPaymentForm.toBytes())
     *
     * @param card          已通过 validateCard 校验的卡数据
     * @param stripeKey     从 payment form nativeParams 解析出的 Stripe publishable key
     * @param formId        来自 getPaymentForm 的 form_id
     * @param peerId        invoice 消息来源 peer ID
     * @param accessHash    peer access_hash
     * @param msgId         invoice 消息 ID
     * @param completion    回调，在调用方 spawn 上下文内执行
     */
    public func submitCardViaStripe(
        card: CardEntryData,
        stripeKey: String,
        formId: Int64,
        peerId: Int64,
        accessHash: Int64,
        msgId: Int32,
        completion: (PaymentMethodSubmitResult) -> Unit
    ): Unit {
        Hilog.info(0, "CjTelegram", "[PaymentMethodService] submitCardViaStripe formId=${formId} peer=${peerId}")
        let expParts = splitBySlash(card.expiry)
        let expMonth = if (expParts.size == 2) {
            Int32(parseDigits(expParts[0].trimAscii()))
        } else {
            Int32(0)
        }
        let expYear = if (expParts.size == 2) {
            // 2-digit year → 4-digit: YY → 20YY
            Int32(2000) + Int32(parseDigits(expParts[1].trimAscii()))
        } else {
            Int32(0)
        }
        let stripeParams = StripeCardParams(
            stripNonDigits(card.number),
            expMonth,
            expYear,
            card.cvv,
            card.holderName
        )
        setStripeDefaultPublishableKey(stripeKey)
        getStripeBinding().createTokenWithCard(stripeParams, { tokenResult: StripeTokenResultType =>
            let result = PaymentMethodSubmitResult()
            match (tokenResult) {
                case StripeTokenResultType.Success(token) =>
                    Hilog.info(0, "CjTelegram", "[PaymentMethodService] Stripe token created")
                    result.tokenId = token.tokenId
                    let credJson = buildStripeCredentials(token.tokenId)
                    let svc = getPaymentsService()
                    let payResult = svc.sendPaymentForm(
                        formId,
                        peerId,
                        accessHash,
                        msgId,
                        "",
                        "",
                        credJson,
                        false
                    )
                    result.success = payResult.success
                    result.verificationUrl = payResult.verificationUrl
                    if (!payResult.success && payResult.errorMessage.size > 0) {
                        result.errorMessage = payResult.errorMessage
                    }
                    completion(result)
                case StripeTokenResultType.Error(msg) =>
                    Hilog.info(0, "CjTelegram", "[PaymentMethodService] Stripe token error")
                    result.errorMessage = "Card tokenization failed: " + msg
                    completion(result)
            }
        })
    }

    /**
     * 构建 Stripe provider_data credentials JSON
     * 对应 Telegram Bot API payment_credential type=card
     */
    private func buildStripeCredentials(tokenId: String): String {
        return "{\"type\":\"card\",\"id\":\"" + jsonEscape(tokenId) + "\"}"
    }

    // -------------------- 字符串工具 --------------------

    /**
     * 去除非数字字符（用于卡号 / CVV 预处理）
     */
    public func stripNonDigits(s: String): String {
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

    /**
     * 格式化卡号显示：每 4 位插入空格
     * 例: "4111111111111111" → "4111 1111 1111 1111"
     */
    public func formatCardNumber(number: String): String {
        let digits = stripNonDigits(number)
        var out = ""
        let runes = digits.toRuneArray()
        for (i in 0..runes.size) {
            if (i > 0 && (i % 4) == 0) {
                out = out + " "
            }
            out = out + runes[i].toString()
        }
        return out
    }

    /**
     * 按斜杠拆分字符串（用于有效期解析）
     */
    private func splitBySlash(s: String): ArrayList<String> {
        let result = ArrayList<String>()
        var current = ""
        let runes = s.toRuneArray()
        for (r in runes) {
            if (r.toString() == "/") {
                result.add(current)
                current = ""
            } else {
                current = current + r.toString()
            }
        }
        result.add(current)
        return result
    }

    /**
     * 解析纯数字字符串为 Int64
     */
    private func parseDigits(s: String): Int64 {
        var val: Int64 = 0
        let runes = s.toRuneArray()
        for (r in runes) {
            let code = UInt32(r)
            if (code >= 48 && code <= 57) {
                val = val * 10 + Int64(code - 48)
            }
        }
        return val
    }

    /**
     * JSON 字符串转义（用于构造 credentials JSON）
     */
    private func jsonEscape(s: String): String {
        var out = ""
        let runes = s.toRuneArray()
        for (r in runes) {
            let code = UInt32(r)
            if (code == 34) {
                out = out + "\\\""
            } else if (code == 92) {
                out = out + "\\\\"
            } else {
                out = out + r.toString()
            }
        }
        return out
    }
}
