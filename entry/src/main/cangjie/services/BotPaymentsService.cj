package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList

/**
 * BotPaymentsService — Bot 支付 TL API 封装
 *
 * 对应 TelegramCore payments 模块 (fetchBotPaymentForm / validateBotPaymentForm /
 *   sendBotPaymentForm / requestBotPaymentReceipt)
 *
 * 调用链:
 *   BotPaymentsService → getMTProtoClient().sendRequest(req.toBytes()) → MTProtoTransport → Telegram DC
 *
 * TL 方法实现:
 *   payments.getPaymentForm#37148dbb — 获取支付表单（Invoice + 支付提供商 + Stripe key）
 *     iOS: Api.functions.payments.getPaymentForm  buffer.appendInt32(924093883) → 0x37148dbb
 *   payments.validateRequestedInfo#b6c8f12b — 验证用户填写的收货/联系信息（→ shippingOptions）
 *     iOS: Api.functions.payments.validateRequestedInfo  buffer.appendInt32(-1228345045) → 0xb6c8f12b
 *   payments.sendPaymentForm#2d03522f — 提交支付（card token → provider_data）
 *     iOS: Api.functions.payments.sendPaymentForm  buffer.appendInt32(755192367) → 0x2d03522f
 *   payments.getPaymentReceipt#2478d1cc — 获取已支付收据
 *     iOS: Api.functions.payments.getPaymentReceipt  buffer.appendInt32(611897804) → 0x2478d1cc
 */

// ==================== 数据模型 ====================

/**
 * 价格条目（labeledPrice 对应 TL: LabeledPrice#cb296bf8）
 */
public class BotPaymentPrice {
    public var label: String = ""
    public var amount: Int64 = 0

    public init() {}
    public init(lbl: String, amt: Int64) {
        this.label = lbl
        this.amount = amt
    }
}

/**
 * 运输方式（对应 ShippingOption#b6213cdf）
 * iOS: BotPaymentShippingOption — id + title + prices
 */
public class BotPaymentShippingOption {
    public var id: String = ""
    public var title: String = ""
    public var prices: ArrayList<BotPaymentPrice> = ArrayList<BotPaymentPrice>()

    public init() {}
}

/**
 * 已验证收货信息结果（对应 payments.validatedRequestedInfo#d1451883）
 * iOS: BotPaymentValidatedFormInfo — id + shippingOptions
 */
public class BotPaymentValidatedFormInfo {
    public var id: String = ""
    public var shippingOptions: ArrayList<BotPaymentShippingOption> = ArrayList<BotPaymentShippingOption>()

    public init() {}
}

/**
 * 已保存的支付凭证（对应 paymentSavedCredentialsCard#cdc27a1f）
 * iOS ref: BotPaymentSavedCredentials .card(id:String, title:String)
 * TL: paymentSavedCredentialsCard#cdc27a1f id:string title:string
 * Constructor verified: iOS Api20.swift buffer.appendInt32(-842892769) → 0xcdc27a1f
 *
 * title 格式通常是 "Visa *1234" — iOS splitSavedCardTitle 按最后一个 "*" 分割
 */
public class BotPaymentSavedCredential {
    public var id: String = ""
    public var title: String = ""

    public init() {}
    public init(id: String, title: String) {
        this.id = id
        this.title = title
    }

    public func maskedTitle(): String {
        let runes = this.title.toRuneArray()
        var lastStar = -1
        for (i in 0..runes.size) {
            if (runes[i].toString() == "*") {
                lastStar = i
            }
        }
        if (lastStar < 0) {
            return this.title
        }
        var name = ""
        for (i in 0..lastStar) {
            name = name + runes[i].toString()
        }
        var suffix = ""
        for (i in (lastStar + 1)..runes.size) {
            suffix = suffix + runes[i].toString()
        }
        let nameTrimmed = trimTrailing(name)
        let suffixTrimmed = trimLeading(suffix)
        if (nameTrimmed.size == 0 || suffixTrimmed.size == 0) {
            return this.title
        }
        return nameTrimmed + " •••• " + suffixTrimmed
    }
}

private func trimTrailing(s: String): String {
    let runes = s.toRuneArray()
    var end = runes.size
    while (end > 0 && runes[end - 1].toString() == " ") {
        end = end - 1
    }
    var result = ""
    for (i in 0..end) {
        result = result + runes[i].toString()
    }
    return result
}

private func trimLeading(s: String): String {
    let runes = s.toRuneArray()
    var start = 0
    while (start < runes.size && runes[start].toString() == " ") {
        start = start + 1
    }
    var result = ""
    for (i in start..runes.size) {
        result = result + runes[i].toString()
    }
    return result
}

/**
 * 支付表单（对应 payments.paymentForm#a2334659）
 * iOS: BotPaymentForm — id + canSaveCredentials + passwordMissing + invoice + nativeProvider + ...
 */
public class BotPaymentForm {
    public var formId: Int64 = 0
    public var botId: Int64 = 0
    public var title: String = ""
    public var description: String = ""
    public var currency: String = ""
    public var prices: ArrayList<BotPaymentPrice> = ArrayList<BotPaymentPrice>()
    // tip support (invoice flags.8? max_tip_amount + flags.9? suggested_tip_amounts)
    public var maxTipAmount: Int64 = 0
    public var suggestedTipAmounts: ArrayList<Int64> = ArrayList<Int64>()
    // saved_info from server (paymentRequestedInfo flags in invoice)
    public var savedInfoName: String = ""
    public var savedInfoPhone: String = ""
    public var savedInfoEmail: String = ""
    public var savedInfoStreet1: String = ""
    public var savedInfoStreet2: String = ""
    public var savedInfoCity: String = ""
    public var savedInfoState: String = ""
    public var savedInfoCountry: String = ""
    public var savedInfoPostCode: String = ""
    // invoice flags
    public var nameRequested: Bool = false
    public var phoneRequested: Bool = false
    public var emailRequested: Bool = false
    public var shippingAddressRequested: Bool = false
    // provider
    public var nativeProvider: String = ""
    public var nativeParams: String = ""
    public var canSaveCredentials: Bool = false
    public var pwdProtected: Bool = false
    // P2-025: saved credentials list (paymentSavedCredentialsCard#cdc27a1f)
    public var savedCredentials: ArrayList<BotPaymentSavedCredential> = ArrayList<BotPaymentSavedCredential>()

    public init() {}
}

/**
 * 支付结果（对应 payments.paymentResult#4e5f810d /
 *                  payments.paymentVerificationNeeded#d8411139）
 */
public class BotPaymentResult {
    public var success: Bool = false
    public var verificationUrl: String = ""
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""

    public init() {}
}

/**
 * 支付收据（对应 payments.paymentReceipt#70c4fe03）
 * P2-028 gaps: 收件人信息行 + 运输地址行 + 可读日期
 */
public class BotPaymentReceipt {
    public var date: Int32 = 0
    public var botId: Int64 = 0
    public var title: String = ""
    public var description: String = ""
    public var currency: String = ""
    public var totalAmount: Int64 = 0
    public var credentialsTitle: String = ""
    public var prices: ArrayList<BotPaymentPrice> = ArrayList<BotPaymentPrice>()
    public var tipAmount: Int64 = 0
    public var shippingTitle: String = ""
    // P2-028: recipient info from paymentRequestedInfo (flags.0 in receipt)
    public var recipientName: String = ""
    public var recipientPhone: String = ""
    public var recipientEmail: String = ""
    public var recipientStreet1: String = ""
    public var recipientStreet2: String = ""
    public var recipientCity: String = ""
    public var recipientState: String = ""
    public var recipientCountry: String = ""
    public var recipientPostCode: String = ""

    public init() {}
}

/**
 * 收货信息（对应 paymentRequestedInfo#909c3f94）
 */
public class BotPaymentRequestedInfo {
    public var name: String = ""
    public var phone: String = ""
    public var email: String = ""
    // address (PostAddress#1e8caaeb)
    public var streetLine1: String = ""
    public var streetLine2: String = ""
    public var city: String = ""
    public var state: String = ""
    public var countryIso2: String = ""
    public var postCode: String = ""

    public init() {}
    public init(n: String, p: String, e: String) {
        this.name = n
        this.phone = p
        this.email = e
    }
}

// ==================== 服务实例 ====================

private var _botPaymentsServiceInstance: Option<BotPaymentsService> = None

/**
 * 获取 BotPaymentsService 单例
 */
public func getBotPaymentsService(): BotPaymentsService {
    match (_botPaymentsServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = BotPaymentsService()
            _botPaymentsServiceInstance = Some(inst)
            return inst
    }
}

// ==================== 货币格式化工具 ====================

/**
 * 货币格式化 — 对应 iOS formatCurrencyAmount(_:currency:)
 *
 * Telegram 货币金额使用 Int64 minor units（例如 USD 用美分，JPY 直接用整数）
 * 常见货币小数位数:
 *   2位: USD/EUR/GBP/CNY/RUB/...
 *   0位: JPY/KRW/VND/...
 *   3位: BHD/KWD/...
 *
 * 简化实现：根据货币代码决定小数位数
 * iOS ref: TelegramStringFormatting.swift formatCurrencyAmount
 */
public func formatCurrencyAmount(amount: Int64, currency: String): String {
    let decimals = getCurrencyDecimals(currency)
    let absAmount: Int64 = if (amount < 0) { -amount } else { amount }
    let prefix: String = if (amount < 0) { "-" } else { "" }
    if (decimals == 0) {
        return prefix + absAmount.toString() + " " + currency
    }
    var divisor: Int64 = 1
    var i: Int64 = 0
    while (i < Int64(decimals)) {
        divisor = divisor * 10
        i = i + 1
    }
    let major = absAmount / divisor
    let minor = absAmount % divisor
    let minorStr = padLeft(minor.toString(), decimals)
    return prefix + major.toString() + "." + minorStr + " " + currency
}

private func padLeft(s: String, width: Int32): String {
    var result = s
    while (result.size < Int64(width)) {
        result = "0" + result
    }
    return result
}

/**
 * 货币小数位数（minor unit exponent）
 * iOS ref: BotPaymentsUI/Sources/Formatter/Currency.swift
 */
public func getCurrencyDecimals(currency: String): Int32 {
    // 0-decimal currencies
    if (currency == "JPY" || currency == "KRW" || currency == "VND" || currency == "CLP" ||
        currency == "GNF" || currency == "ISK" || currency == "KMF" || currency == "MGA" ||
        currency == "PYG" || currency == "RWF" || currency == "UGX" || currency == "UYI" ||
        currency == "VUV" || currency == "XAF" || currency == "XOF" || currency == "XPF") {
        return 0
    }
    // 3-decimal currencies
    if (currency == "BHD" || currency == "IQD" || currency == "JOD" || currency == "KWD" ||
        currency == "LYD" || currency == "OMR" || currency == "TND") {
        return 3
    }
    // default: 2 decimals
    return 2
}

// ==================== 服务实现 ====================

/**
 * Bot 支付服务
 *
 * 封装 Telegram payments.* TL 方法，调用链完整:
 *   BotPaymentsService.getPaymentForm()
 *     → getMTProtoClient().sendRequest(PaymentsGetPaymentForm.toBytes())
 *     → MTProtoTransport → Telegram DC
 */
public class BotPaymentsService {

    /**
     * payments.getPaymentForm — 获取支付表单
     *
     * Constructor verified: iOS Api42.swift buffer.appendInt32(924093883) → 0x37148dbb
     *
     * @param peerId   消息发送者 peer ID
     * @param peerAccessHash  accessHash
     * @param msgId    包含 Invoice 的消息 ID
     * @param isChannel  是否是 channel 消息
     * @return BotPaymentForm 或 None（网络错误）
     */
    public func getPaymentForm(
        peerId: Int64,
        peerAccessHash: Int64,
        msgId: Int32,
        isChannel: Bool
    ): Option<BotPaymentForm> {
        Hilog.info(0, "CjTelegram", "[BotPaymentsService] getPaymentForm msgId=${msgId}")
        let client = getMTProtoClient()
        let req = PaymentsGetPaymentForm()
        req.invoiceType = "message"
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.msgId = msgId
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            Hilog.info(0, "CjTelegram", "[BotPaymentsService] getPaymentForm empty response")
            return None
        }
        return parsePaymentForm(data)
    }

    /**
     * payments.validateRequestedInfo — 验证收货/联系信息，返回运输选项
     *
     * Constructor verified: iOS Api42.swift buffer.appendInt32(-1228345045) → 0xb6c8f12b
     *
     * iOS ref: _internal_validateBotPaymentForm → account.network.request(
     *   Api.functions.payments.validateRequestedInfo(flags, invoice, info))
     * 返回 payments.ValidatedRequestedInfo#d1451883 { id:flags.0?string shipping_options:flags.1?Vector<ShippingOption> }
     *
     * @param peerId        peer ID
     * @param peerAccessHash  accessHash
     * @param msgId         Invoice 消息 ID
     * @param isChannel     是否 channel
     * @param info          用户填写的收货/联系信息
     * @param save          是否保存信息到服务器
     * @return BotPaymentValidatedFormInfo 或 None
     */
    public func validateRequestedInfo(
        peerId: Int64,
        peerAccessHash: Int64,
        msgId: Int32,
        isChannel: Bool,
        info: BotPaymentRequestedInfo,
        save: Bool
    ): Option<BotPaymentValidatedFormInfo> {
        Hilog.info(0, "CjTelegram", "[BotPaymentsService] validateRequestedInfo msgId=${msgId} save=${save}")
        let client = getMTProtoClient()
        let req = PaymentsValidateRequestedInfo()
        req.save = save
        req.invoiceType = "message"
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.msgId = msgId
        req.name = info.name
        req.phone = info.phone
        req.email = info.email
        req.hasAddress = info.streetLine1.size > 0
        if (req.hasAddress) {
            req.streetLine1 = info.streetLine1
            req.streetLine2 = info.streetLine2
            req.city = info.city
            req.state = info.state
            req.countryIso2 = info.countryIso2
            req.postCode = info.postCode
        }
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            Hilog.info(0, "CjTelegram", "[BotPaymentsService] validateRequestedInfo empty response")
            return None
        }
        return parseValidatedRequestedInfo(data)
    }

    /**
     * payments.sendPaymentForm — 提交支付
     *
     * Constructor verified: iOS Api42.swift buffer.appendInt32(755192367) → 0x2d03522f
     *
     * iOS ref: _internal_sendBotPaymentForm → account.network.request(
     *   Api.functions.payments.sendPaymentForm(flags, formId, invoice,
     *     requestedInfoId, shippingOptionId, credentials, tipAmount))
     *
     * @param formId            从 getPaymentForm 返回的 form_id
     * @param peerId            peer ID
     * @param peerAccessHash    accessHash
     * @param msgId             Invoice 消息 ID
     * @param isChannel         是否 channel
     * @param credentialsJson   支付凭证 JSON（Stripe token 或其他提供商 token）
     * @param requestedInfoId   从 validateRequestedInfo 返回的 id（可为空）
     * @param shippingOptionId  用户选中的运输方式 id（可为空）
     * @param tipAmount         小费金额 minor units（0 = 无小费）
     * @return BotPaymentResult
     */
    public func sendPaymentForm(
        formId: Int64,
        peerId: Int64,
        peerAccessHash: Int64,
        msgId: Int32,
        isChannel: Bool,
        credentialsJson: String,
        requestedInfoId: String,
        shippingOptionId: String,
        tipAmount: Int64
    ): BotPaymentResult {
        Hilog.info(0, "CjTelegram", "[BotPaymentsService] sendPaymentForm formId=${formId} tip=${tipAmount}")
        let client = getMTProtoClient()
        let req = PaymentsSendPaymentForm()
        req.invoiceType = "message"
        req.formId = formId
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.msgId = msgId
        req.credentialsData = credentialsJson
        req.requestedInfoId = requestedInfoId
        req.shippingOptionId = shippingOptionId
        req.tipAmount = tipAmount
        req.hasTipAmount = tipAmount > 0
        let data = client.sendRequest(req.toBytes())
        return parsePaymentResult(data)
    }

    /**
     * payments.sendPaymentForm — 提交支付（已存凭证路径）
     *
     * P2-025 + P2-027: 使用 saved credential (credentialsType="saved")
     * 需要 tmpPassword token (from account.getTmpPassword)
     * credentials: inputPaymentCredentialsSaved#c10eb2cf id:string tmp_password:bytes
     *
     * Constructor verified: iOS Api12.swift buffer.appendInt32(inputPaymentCredentialsSaved) → 0xc10eb2cf
     */
    public func sendPaymentFormSaved(
        formId: Int64,
        peerId: Int64,
        peerAccessHash: Int64,
        msgId: Int32,
        isChannel: Bool,
        savedCredentialId: String,
        tmpPasswordToken: Array<Byte>,
        requestedInfoId: String,
        shippingOptionId: String,
        tipAmount: Int64
    ): BotPaymentResult {
        Hilog.info(0, "CjTelegram", "[BotPaymentsService] sendPaymentFormSaved credId=${savedCredentialId} tip=${tipAmount}")
        let client = getMTProtoClient()
        let req = PaymentsSendPaymentForm()
        req.invoiceType = "message"
        req.formId = formId
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.msgId = msgId
        req.credentialsType = "saved"
        req.savedCredentialsId = savedCredentialId
        req.savedCredentialsTmpPassword = tmpPasswordToken
        req.requestedInfoId = requestedInfoId
        req.shippingOptionId = shippingOptionId
        req.tipAmount = tipAmount
        req.hasTipAmount = tipAmount > 0
        let data = client.sendRequest(req.toBytes())
        return parsePaymentResult(data)
    }

    /**
     * payments.getPaymentReceipt — 获取已支付收据
     *
     * Constructor verified: iOS Api42.swift buffer.appendInt32(611897804) → 0x2478d1cc
     *
     * @param peerId            peer ID
     * @param peerAccessHash    accessHash
     * @param msgId             已支付消息 ID
     * @param isChannel         是否 channel
     * @return BotPaymentReceipt 或 None
     */
    public func getPaymentReceipt(
        peerId: Int64,
        peerAccessHash: Int64,
        msgId: Int32,
        isChannel: Bool
    ): Option<BotPaymentReceipt> {
        Hilog.info(0, "CjTelegram", "[BotPaymentsService] getPaymentReceipt msgId=${msgId}")
        let client = getMTProtoClient()
        let req = PaymentsGetPaymentReceipt()
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.msgId = msgId
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            Hilog.info(0, "CjTelegram", "[BotPaymentsService] getPaymentReceipt empty response")
            return None
        }
        return parsePaymentReceipt(data)
    }

    // ==================== 响应解析 ====================

    /**
     * 解析 payments.paymentForm#a2334659
     * payments.paymentFormStars#d1451883 (Stars 版本，跳过)
     *
     * iOS ref: _internal_fetchBotPaymentForm → postbox.transaction { case .paymentForm: ... }
     * TL schema: paymentForm#a2334659 flags:# can_save_credentials:flags.2?true password_missing:flags.3?true
     *   form_id:long bot_id:long title:string description:string photo:flags.5?WebDocument
     *   invoice:Invoice provider_id:long url:string native_provider:flags.6?string
     *   native_params:flags.7?DataJSON additional_methods:flags.8?Vector<PaymentFormMethod>
     *   saved_info:flags.0?PaymentRequestedInfo saved_credentials:flags.1?Vector<PaymentSavedCredentials>
     *   users:Vector<User>
     */
    private func parsePaymentForm(data: Array<Byte>): Option<BotPaymentForm> {
        if (data.size < 4) { return None }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        // RPC error → 跳过
        if (ctor == TLConstructors.RPC_ERROR) {
            let _ = d.readInt32()
            let _ = d.readString()
            Hilog.info(0, "CjTelegram", "[BotPaymentsService] getPaymentForm RPC error")
            return None
        }
        // payments.paymentForm#a0058751 (iOS current / negotiated Layer 214)
        // Keep the older constructor for persisted sessions that were created
        // against an earlier schema.
        if (ctor != 0xa0058751 && ctor != 0xa2334659) {
            Hilog.info(0, "CjTelegram", "[BotPaymentsService] getPaymentForm unknown ctor 0x${ctorHex(ctor)}")
            return None
        }
        let isCurrentForm = ctor == 0xa0058751
        let form = BotPaymentForm()
        let flags = d.readInt32()
        form.canSaveCredentials = (flags & 4) != 0     // flags.2
        form.pwdProtected = (flags & 8) != 0           // flags.3
        form.formId = d.readInt64()
        form.botId = d.readInt64()
        form.title = d.readString()
        form.description = d.readString()
        // photo: flags.5?WebDocument
        if ((flags & 32) != 0) {
            skipWebDocument(d)
        }
        // invoice#049ee584 (current) / #5db95a15 (legacy)
        let invCtor = d.readUInt32()
        if (invCtor == 0x049ee584 || invCtor == 0x5db95a15) {
            let invFlags = d.readInt32()
            form.nameRequested = (invFlags & 2) != 0
            form.phoneRequested = (invFlags & 4) != 0
            form.emailRequested = (invFlags & 8) != 0
            form.shippingAddressRequested = (invFlags & 16) != 0
            form.currency = d.readString()
            let pricesVecCtor = d.readUInt32()
            if (pricesVecCtor == TLConstructors.VECTOR) {
                let priceCount = d.readInt32()
                var pi: Int64 = 0
                while (pi < Int64(priceCount)) {
                    let priceCtor = d.readUInt32()
                    if (priceCtor == 0xcb296bf8) {
                        let price = BotPaymentPrice()
                        price.label = d.readString()
                        price.amount = d.readInt64()
                        form.prices.add(price)
                    }
                    pi = pi + 1
                }
            }
            if ((invFlags & 256) != 0) {
                form.maxTipAmount = d.readInt64()
                let vecCtor = d.readUInt32()
                if (vecCtor == TLConstructors.VECTOR) {
                    let tipCount = d.readInt32()
                    var ti: Int64 = 0
                    while (ti < Int64(tipCount)) {
                        form.suggestedTipAmounts.add(d.readInt64())
                        ti = ti + 1
                    }
                }
            }
            if ((invFlags & 1024) != 0) {
                let _ = d.readString()
            }
            if ((invFlags & 2048) != 0) {
                let _ = d.readInt32()
            }
        }
        // provider_id: long (always present)
        let _ = d.readInt64()
        // url: string (always present in paymentForm)
        let _ = d.readString()
        let nativeProviderFlag: Int32 = if (isCurrentForm) { 16 } else { 64 }
        let nativeParamsFlag: Int32 = if (isCurrentForm) { 16 } else { 128 }
        let additionalMethodsFlag: Int32 = if (isCurrentForm) { 64 } else { 256 }
        if ((flags & nativeProviderFlag) != 0) {
            form.nativeProvider = d.readString()
        }
        if ((flags & nativeParamsFlag) != 0) {
            let jsonCtor = d.readUInt32()
            if (jsonCtor == 0x7d748d04) {
                form.nativeParams = d.readString()
            }
        }
        if ((flags & additionalMethodsFlag) != 0) {
            skipVector(d)
        }
        // saved_info: flags.0?PaymentRequestedInfo
        if ((flags & 1) != 0) {
            parseSavedInfo(d, form)
        }
        // saved_credentials: flags.1?Vector<PaymentSavedCredentials>
        // P2-025: parse saved cards list (paymentSavedCredentialsCard#cdc27a1f id:string title:string)
        // Constructor verified: iOS Api20.swift buffer.appendInt32(-842892769) → 0xcdc27a1f
        if ((flags & 2) != 0) {
            let vecCtor = d.readUInt32()
            if (vecCtor == TLConstructors.VECTOR) {
                let credCount = d.readInt32()
                var ci: Int64 = 0
                while (ci < Int64(credCount)) {
                    let credCtor = d.readUInt32()
                    if (credCtor == 0xcdc27a1f) {
                        // paymentSavedCredentialsCard#cdc27a1f id:string title:string
                        let cred = BotPaymentSavedCredential()
                        cred.id = d.readString()
                        cred.title = d.readString()
                        form.savedCredentials.add(cred)
                    }
                    ci = ci + 1
                }
            }
        }
        // users: Vector<User> — skip
        skipVector(d)
        Hilog.info(0, "CjTelegram", "[BotPaymentsService] Parsed form title=${form.title} currency=${form.currency} maxTip=${form.maxTipAmount}")
        return Some(form)
    }

    /**
     * 解析 payments.validatedRequestedInfo#d1451883
     * flags:# id:flags.0?string shipping_options:flags.1?Vector<ShippingOption>
     *
     * iOS ref: BotPaymentForm.swift _internal_validateBotPaymentForm → case .validatedRequestedInfo(id, shippingOptions)
     * shippingOption#b6213cdf id:string title:string prices:Vector<LabeledPrice>
     */
    private func parseValidatedRequestedInfo(data: Array<Byte>): Option<BotPaymentValidatedFormInfo> {
        if (data.size < 4) { return None }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR) {
            let _ = d.readInt32()
            let _ = d.readString()
            Hilog.info(0, "CjTelegram", "[BotPaymentsService] validateRequestedInfo RPC error")
            return None
        }
        // payments.validatedRequestedInfo#d1451883
        if (ctor != 0xd1451883) {
            Hilog.info(0, "CjTelegram", "[BotPaymentsService] validateRequestedInfo unknown ctor 0x${ctorHex(ctor)}")
            return None
        }
        let result = BotPaymentValidatedFormInfo()
        let flags = d.readInt32()
        // id: flags.0?string
        if ((flags & 1) != 0) {
            result.id = d.readString()
        }
        // shipping_options: flags.1?Vector<ShippingOption>
        if ((flags & 2) != 0) {
            let vecCtor = d.readUInt32()
            if (vecCtor == TLConstructors.VECTOR) {
                let count = d.readInt32()
                var i: Int64 = 0
                while (i < Int64(count)) {
                    let optCtor = d.readUInt32()
                    if (optCtor == 0xb6213cdf) {
                        // shippingOption#b6213cdf id:string title:string prices:Vector<LabeledPrice>
                        let opt = BotPaymentShippingOption()
                        opt.id = d.readString()
                        opt.title = d.readString()
                        // prices vector
                        let pvCtor = d.readUInt32()
                        if (pvCtor == TLConstructors.VECTOR) {
                            let priceCount = d.readInt32()
                            var pi: Int64 = 0
                            while (pi < Int64(priceCount)) {
                                let price = BotPaymentPrice()
                                price.label = d.readString()
                                price.amount = d.readInt64()
                                opt.prices.add(price)
                                pi = pi + 1
                            }
                        }
                        result.shippingOptions.add(opt)
                    }
                    i = i + 1
                }
            }
        }
        Hilog.info(0, "CjTelegram", "[BotPaymentsService] Validated info id=${result.id} shippingOptions=${result.shippingOptions.size}")
        return Some(result)
    }

    /**
     * 解析 payments.paymentResult#4e5f810d
     * 或 payments.paymentVerificationNeeded#d8411139
     */
    private func parsePaymentResult(data: Array<Byte>): BotPaymentResult {
        let result = BotPaymentResult()
        if (data.size < 4) {
            result.errorMessage = "Empty response"
            return result
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR) {
            result.errorCode = d.readInt32()
            result.errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[BotPaymentsService] sendPaymentForm RPC error ${result.errorMessage}")
            return result
        }
        if (ctor == 0x4e5f810d) {
            // payments.paymentResult — success, contains updates
            result.success = true
            Hilog.info(0, "CjTelegram", "[BotPaymentsService] Payment succeeded")
            return result
        }
        if (ctor == 0xd8411139) {
            // payments.paymentVerificationNeeded — 3DS or web verification
            result.success = false
            result.verificationUrl = d.readString()
            Hilog.info(0, "CjTelegram", "[BotPaymentsService] Verification needed url=${result.verificationUrl}")
            return result
        }
        result.errorMessage = "Unknown response ctor"
        return result
    }

    /**
     * 解析 payments.paymentReceipt#70c4fe03
     */
    private func parsePaymentReceipt(data: Array<Byte>): Option<BotPaymentReceipt> {
        if (data.size < 4) { return None }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR) {
            let _ = d.readInt32()
            let _ = d.readString()
            Hilog.info(0, "CjTelegram", "[BotPaymentsService] getPaymentReceipt RPC error")
            return None
        }
        if (ctor != 0x70c4fe03) {
            Hilog.info(0, "CjTelegram", "[BotPaymentsService] getPaymentReceipt unknown ctor 0x${ctorHex(ctor)}")
            return None
        }
        let receipt = BotPaymentReceipt()
        let flags = d.readInt32()
        receipt.date = d.readInt32()
        receipt.botId = d.readInt64()
        // provider_id: int64
        let _ = d.readInt64()
        receipt.title = d.readString()
        receipt.description = d.readString()
        // photo: flags.2?WebDocument
        if ((flags & 4) != 0) {
            skipWebDocument(d)
        }
        // invoice#5db95a15
        let invCtor = d.readUInt32()
        if (invCtor == 0x5db95a15) {
            let invFlags = d.readInt32()
            receipt.currency = d.readString()
            let priceCount = d.readInt32()
            var pi: Int64 = 0
            while (pi < Int64(priceCount)) {
                let price = BotPaymentPrice()
                price.label = d.readString()
                price.amount = d.readInt64()
                receipt.prices.add(price)
                pi = pi + 1
            }
            if ((invFlags & 256) != 0) {
                let _ = d.readInt64()
            }
            if ((invFlags & 512) != 0) {
                skipLongVector(d)
            }
            if ((invFlags & 1024) != 0) {
                let _ = d.readString()
            }
        }
        // info: flags.0?PaymentRequestedInfo
        // P2-028: parse recipient info to display on receipt screen
        if ((flags & 1) != 0) {
            parseReceiptRequestedInfo(d, receipt)
        }
        // shipping: flags.1?ShippingOption
        if ((flags & 2) != 0) {
            let optC = d.readUInt32()
            if (optC == 0xb6213cdf) {
                let _ = d.readString()
                receipt.shippingTitle = d.readString()
                skipLabeledPriceVector(d)
            }
        }
        // tip_amount: flags.3?long
        if ((flags & 8) != 0) {
            receipt.tipAmount = d.readInt64()
        }
        // currency: string (already in invoice but also top-level)
        let _ = d.readString()
        receipt.totalAmount = d.readInt64()
        receipt.credentialsTitle = d.readString()
        Hilog.info(0, "CjTelegram", "[BotPaymentsService] Parsed receipt title=${receipt.title} amount=${receipt.totalAmount}")
        return Some(receipt)
    }

    // ==================== P2-028: 解析收据收件人信息 ====================

    /**
     * 解析 paymentRequestedInfo#909c3f94 into BotPaymentReceipt recipient fields
     * flags:# name:flags.0?string phone:flags.1?string email:flags.2?string
     *         shipping_address:flags.3?PostAddress
     * PostAddress#1e8caaeb street_line1 street_line2 city state country_iso2 post_code
     */
    private func parseReceiptRequestedInfo(d: TLDeserializer, receipt: BotPaymentReceipt): Unit {
        let infoC = d.readUInt32()
        if (infoC != 0x909c3f94) { return }
        let infoFlags = d.readInt32()
        if ((infoFlags & 1) != 0) { receipt.recipientName = d.readString() }
        if ((infoFlags & 2) != 0) { receipt.recipientPhone = d.readString() }
        if ((infoFlags & 4) != 0) { receipt.recipientEmail = d.readString() }
        if ((infoFlags & 8) != 0) {
            // PostAddress#1e8caaeb street_line1:string street_line2:string city:string
            //   state:string country_iso2:string post_code:string
            let addrC = d.readUInt32()
            if (addrC == 0x1e8caaeb) {
                receipt.recipientStreet1 = d.readString()
                receipt.recipientStreet2 = d.readString()
                receipt.recipientCity = d.readString()
                receipt.recipientState = d.readString()
                receipt.recipientCountry = d.readString()
                receipt.recipientPostCode = d.readString()
            }
        }
    }

    // ==================== 跳过/解析辅助方法 ====================

    private func parseSavedInfo(d: TLDeserializer, form: BotPaymentForm): Unit {
        let infoC = d.readUInt32()
        if (infoC == 0x909c3f94) {
            // paymentRequestedInfo#909c3f94 flags:# name:flags.0?string phone:flags.1?string email:flags.2?string shipping_address:flags.3?PostAddress
            let infoFlags = d.readInt32()
            if ((infoFlags & 1) != 0) { form.savedInfoName = d.readString() }
            if ((infoFlags & 2) != 0) { form.savedInfoPhone = d.readString() }
            if ((infoFlags & 4) != 0) { form.savedInfoEmail = d.readString() }
            if ((infoFlags & 8) != 0) {
                // PostAddress#1e8caaeb
                let addrC = d.readUInt32()
                if (addrC == 0x1e8caaeb) {
                    form.savedInfoStreet1 = d.readString()
                    form.savedInfoStreet2 = d.readString()
                    form.savedInfoCity = d.readString()
                    form.savedInfoState = d.readString()
                    form.savedInfoCountry = d.readString()
                    form.savedInfoPostCode = d.readString()
                }
            }
        }
    }

    private func skipWebDocument(d: TLDeserializer): Unit {
        let wdCtor = d.readUInt32()
        if (wdCtor == 0x1c570ed1) {
            // webDocument#1c570ed1 url:string access_hash:long size:int mime_type:string attributes:Vector<DocumentAttribute>
            let _ = d.readString()
            let _ = d.readInt64()
            let _ = d.readInt32()
            let _ = d.readString()
            let vecCtor = d.readUInt32()
            if (vecCtor == TLConstructors.VECTOR) {
                let count = d.readInt32()
                for (_i in 0..Int64(count)) {
                    skipDocumentAttribute(d)
                }
            }
        } else if (wdCtor == 0xf9c8bcc6) {
            // webDocumentNoProxy#f9c8bcc6 url:string size:int mime_type:string attributes:Vector<DocumentAttribute>
            let _ = d.readString()
            let _ = d.readInt32()
            let _ = d.readString()
            let vecCtor = d.readUInt32()
            if (vecCtor == TLConstructors.VECTOR) {
                let count = d.readInt32()
                for (_i in 0..Int64(count)) {
                    skipDocumentAttribute(d)
                }
            }
        }
    }

    private func skipVector(d: TLDeserializer): Unit {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            var i: Int64 = 0
            while (i < Int64(count)) {
                let _ = d.readUInt32()
                i = i + 1
            }
        }
    }

    private func skipLongVector(d: TLDeserializer): Unit {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            var i: Int64 = 0
            while (i < Int64(count)) {
                let _ = d.readInt64()
                i = i + 1
            }
        }
    }

    private func skipLabeledPriceVector(d: TLDeserializer): Unit {
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            var i: Int64 = 0
            while (i < Int64(count)) {
                let _ = d.readString()
                let _ = d.readInt64()
                i = i + 1
            }
        }
    }

    private func skipPaymentRequestedInfo(d: TLDeserializer): Unit {
        let infoC = d.readUInt32()
        if (infoC == 0x909c3f94) {
            let infoFlags = d.readInt32()
            if ((infoFlags & 1) != 0) { let _ = d.readString() }
            if ((infoFlags & 2) != 0) { let _ = d.readString() }
            if ((infoFlags & 4) != 0) { let _ = d.readString() }
            if ((infoFlags & 8) != 0) {
                let addrC = d.readUInt32()
                if (addrC == 0x1e8caaeb) {
                    let _ = d.readString()
                    let _ = d.readString()
                    let _ = d.readString()
                    let _ = d.readString()
                    let _ = d.readString()
                    let _ = d.readString()
                }
            }
        }
    }

    private func ctorHex(v: UInt32): String {
        let hexChars = "0123456789abcdef"
        let runes = hexChars.toRuneArray()
        var result = ""
        var i: Int32 = 28
        while (i >= 0) {
            let nibble = UInt32((v >> UInt32(i)) & 0xF)
            result = result + runes[Int64(nibble)].toString()
            i = i - 4
        }
        return result
    }
}
