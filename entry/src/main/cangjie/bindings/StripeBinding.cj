package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{Base64, ByteUtils}
import std.collection.{ArrayList, HashMap}
import ohos_app_cangjie_entry.net.netHttpPostText
import std.convert.*

/**
 * StripeBinding — Stripe 支付 API 平台封装层
 *
 * 对应 Telegram-iOS Stripe submodule (STPAPIClient, STPToken 等)。
 * Stripe SDK 不直接在鸿蒙上可用，本层通过 HTTPS POST 到 Stripe API 实现：
 * - setDefaultPublishableKey: 配置 publishable key
 * - createTokenWithCard: 用卡号创建 token（POST api.stripe.com/v1/tokens）
 *
 * Token 创建后通过 Telegram Bot API / payments.sendPaymentForm 传给服务端。
 */

/**
 * 卡输入参数（对应 STPCardParams）
 */
public class StripeCardParams {
    public var number: String = ""
    public var expMonth: Int32 = 0
    public var expYear: Int32 = 0
    public var cvc: String = ""
    public var name: String = ""

    public init() {}

    public init(number: String, expMonth: Int32, expYear: Int32, cvc: String, name: String) {
        this.number = number
        this.expMonth = expMonth
        this.expYear = expYear
        this.cvc = cvc
        this.name = name
    }
}

/**
 * Token 结果（对应 STPToken）
 */
public class StripeTokenResult {
    public var tokenId: String = ""
    public var livemode: Bool = false
    public var last4: String = ""
    public var brand: String = ""
    public var expMonth: Int32 = 0
    public var expYear: Int32 = 0

    public init() {}
}

/**
 * Token 创建回调结果
 */
public enum StripeTokenResultType {
    | Success(StripeTokenResult)
    | Error(String)
}

private var _stripePublishableKey: String = ""

/**
 * 设置默认 publishable key（对应 Stripe.setDefaultPublishableKey）
 */
public func setStripeDefaultPublishableKey(key: String): Unit {
    _stripePublishableKey = key
}

/**
 * 获取当前 publishable key
 */
public func getStripeDefaultPublishableKey(): String {
    return _stripePublishableKey
}

private var _stripeBindingInstance: Option<StripeBinding> = None

/**
 * 获取 StripeBinding 单例
 */
public func getStripeBinding(): StripeBinding {
    match (_stripeBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = StripeBinding()
            _stripeBindingInstance = Some(inst)
            return inst
    }
}

/**
 * Stripe API 绑定
 */
public class StripeBinding {

    /**
     * 用卡信息创建 token（对应 STPAPIClient.createTokenWithCard）
     * 通过 HTTPS POST 到 api.stripe.com/v1/tokens
     *
     * @param params 卡参数
     * @param completion 回调，Success 时 tokenId 可发给后端
     */
    public func createTokenWithCard(params: StripeCardParams, completion: (StripeTokenResultType) -> Unit): Unit {
        if (_stripePublishableKey.size == 0) {
            completion(StripeTokenResultType.Error("Publishable key not set"))
            return
        }
        let body = buildFormBody(params)
        let headers = HashMap<String, String>()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Authorization"] = "Basic " + makeBasicAuth(_stripePublishableKey)
        let response = netHttpPostText("https://api.stripe.com/v1/tokens", body, headers: headers)
        if (!response.success) {
            completion(StripeTokenResultType.Error("HTTP request failed: ${response.statusCode}"))
            return
        }
        match (parseTokenResponse(response.text())) {
            case Some(token) => completion(StripeTokenResultType.Success(token))
            case None => completion(StripeTokenResultType.Error("Failed to parse token response"))
        }
    }

    private func buildFormBody(params: StripeCardParams): String {
        var parts = ArrayList<String>()
        parts.add("card[number]=" + formEncode(params.number))
        parts.add("card[exp_month]=" + formEncode(Int64(params.expMonth).toString()))
        parts.add("card[exp_year]=" + formEncode(Int64(params.expYear).toString()))
        parts.add("card[cvc]=" + formEncode(params.cvc))
        if (params.name.size > 0) {
            parts.add("card[name]=" + formEncode(params.name))
        }
        var result = ""
        for (i in 0..parts.size) {
            if (i > 0) { result = result + "&" }
            result = result + parts[i]
        }
        return result
    }

    private func formEncode(s: String): String {
        var out = ""
        let runes = s.toRuneArray()
        for (r in runes) {
            let code = UInt32(r)
            if ((code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 45 || code == 95 || code == 46 || code == 126) {
                out = out + r.toString()
            } else if (code == 32) {
                out = out + "+"
            } else {
                let hi = (code >> 4) & 15
                let lo = code & 15
                out = out + "%" + hexChar(hi) + hexChar(lo)
            }
        }
        return out
    }

    private func hexChar(n: UInt32): String {
        if (n < 10) { return Int64(n).toString() }
        return Rune(UInt32(65 + n - 10)).toString()
    }

    private func makeBasicAuth(key: String): String {
        let creds = key + ":"
        let bytes = ByteUtils.stringToBytes(creds)
        return Base64.encode(bytes)
    }

    private func parseTokenResponse(body: String): Option<StripeTokenResult> {
        if (!body.contains("\"id\"")) {
            if (body.contains("\"error\"")) {
                Hilog.info(0, "CjTelegram", "[StripeBinding] API error in response")
            }
            return None
        }
        let token = StripeTokenResult()
        token.tokenId = extractJsonString(body, "id")
        token.livemode = body.contains("\"livemode\":true")
        let cardStart = body.indexOf("\"card\":{")
        if (cardStart.isSome()) {
            let cardObj = body[cardStart.getOrThrow()..]
            token.last4 = extractJsonString(cardObj, "last4")
            token.brand = extractJsonString(cardObj, "brand")
            token.expMonth = Int32.parse(extractJsonString(cardObj, "exp_month"))
            token.expYear = Int32.parse(extractJsonString(cardObj, "exp_year"))
        }
        if (token.tokenId.size > 0) {
            return Some(token)
        }
        return None
    }

    private func extractJsonString(json: String, key: String): String {
        let quotedPattern = "\"" + key + "\":\""
        let idx = json.indexOf(quotedPattern)
        if (idx.isSome()) {
            let start = idx.getOrThrow() + quotedPattern.size
            var end = start
            let runes = json.toRuneArray()
            while (end < runes.size) {
                let ch = runes[end].toString()
                if (ch == "\\" && end + 1 < runes.size) {
                    end = end + 2
                } else if (ch == "\"") {
                    return json[start..end]
                } else {
                    end = end + 1
                }
            }
        }
        let numPattern = "\"" + key + "\":"
        let idx2 = json.indexOf(numPattern)
        if (idx2.isSome()) {
            let start = idx2.getOrThrow() + numPattern.size
            var end = start
            let runes = json.toRuneArray()
            while (end < runes.size) {
                let ch = runes[end].toString()
                if (ch == "," || ch == "}" || ch == "]") {
                    return json[start..end].trimAscii()
                }
                end = end + 1
            }
            return json[start..].trimAscii()
        }
        return ""
    }
}
