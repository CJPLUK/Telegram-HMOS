package ohos_app_cangjie_entry.providers

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getPaymentsService
import ohos_app_cangjie_entry.core.mtproto.{
    BankCardDataResponse,
    PaymentFormResponse,
    ValidatedRequestedInfoResponse,
    PaymentResultResponse,
    PaymentReceiptResponse,
    BankCardUrlInfo,
    PaymentPriceEntry,
    ShippingOptionInfo,
    StarsStatusResponse,
    StarsTopupOptionsResponse,
    StarsGiftOptionsResponse,
    StarsTransactionEntry,
    StarsTransactionPeerData,
    StarsTopupOptionEntry,
    StarsGiftOptionEntry,
    StarGiftsResponse,
    SavedStarGiftsResponse,
    StarGiftWithdrawalUrlResponse,
    ResaleStarGiftsResponse,
    StarGiftUpdatesResponse,
    StarGiftBoolResponse,
    StarGiftEntry,
    SavedStarGiftEntry,
    StarGiftAttributeEntry,
    StarGiftUpgradePriceEntry,
    StarGiftUpgradePreviewResponse,
    StarGiftAttributeIdEntry,
    CheckedGiftCodeResponse,
    GiveawayInfoResponse,
    PremiumGiftCodeOptionsResponse,
    PremiumGiftCodeOptionEntry,
    StarsSubscriptionsResponse,
    StarsSubscriptionEntry,
    StarsRevenueStatsResponse,
    StarsRevenueWithdrawalUrlResponse,
    TLBoolResponse
}
import std.collection.ArrayList

/**
 * PaymentsDataProvider — 支付数据接口层（telegram_engine_payments TEPAY-IF-1）
 *
 * 对应 iOS TelegramEngine.Payments 的 UI 适配层
 * 将 PaymentsService 返回的 TL 响应转换为 UI 可直接绑定的 ViewModel 结构。
 *
 * 职责：
 * - 委托 PaymentsService 执行 TL 调用
 * - 将 TL 响应数据映射为 ViewModel（PaymentFormViewModel / ReceiptViewModel 等）
 * - 维护当前操作状态（lastError / isLoading 等）供 UI 轮询
 *
 * 调用链：UI → PaymentsDataProvider → PaymentsService → MTProtoClient → Server
 */

// ==================== ViewModel 类型 ====================

/**
 * 支付价格条目（UI 可显示）
 */
public class PaymentPriceViewModel {
    public var label: String = ""
    public var amount: Int64 = 0
    public var formattedAmount: String = ""
}

/**
 * 运费选项 ViewModel
 */
public class ShippingOptionViewModel {
    public var id: String = ""
    public var title: String = ""
    public var prices: ArrayList<PaymentPriceViewModel> = ArrayList<PaymentPriceViewModel>()
}

/**
 * 银行卡 URL ViewModel
 */
public class BankCardUrlViewModel {
    public var title: String = ""
    public var url: String = ""
}

/**
 * 银行卡信息 ViewModel（对应 iOS BankCardInfo）
 */
public class BankCardInfoViewModel {
    public var title: String = ""
    public var openUrls: ArrayList<BankCardUrlViewModel> = ArrayList<BankCardUrlViewModel>()
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * 支付表单 ViewModel（对应 iOS BotPaymentForm）
 */
public class PaymentFormViewModel {
    public var formId: Int64 = 0
    public var botId: Int64 = 0
    public var title: String = ""
    public var description: String = ""
    public var currency: String = ""
    public var prices: ArrayList<PaymentPriceViewModel> = ArrayList<PaymentPriceViewModel>()
    public var totalAmount: Int64 = 0
    public var canSaveCredentials: Bool = false
    public var passwordMissing: Bool = false
    public var paymentUrl: String = ""
    public var nativeProvider: String = ""
    public var nativeParamsJson: String = ""
    public var isTest: Bool = false
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * 支付验证 ViewModel（对应 iOS BotPaymentValidatedFormInfo）
 */
public class ValidatedInfoViewModel {
    public var validatedInfoId: String = ""
    public var shippingOptions: ArrayList<ShippingOptionViewModel> = ArrayList<ShippingOptionViewModel>()
    public var validated: Bool = false
    public var errorMessage: String = ""
}

/**
 * 支付结果 ViewModel（对应 iOS SendBotPaymentResult）
 */
public class PaymentResultViewModel {
    public var success: Bool = false
    public var verificationRequired: Bool = false
    public var verificationUrl: String = ""
    public var errorMessage: String = ""
}

/**
 * 支付收据 ViewModel（对应 iOS BotPaymentReceipt）
 */
public class PaymentReceiptViewModel {
    public var date: Int32 = 0
    public var botId: Int64 = 0
    public var title: String = ""
    public var description: String = ""
    public var currency: String = ""
    public var totalAmount: Int64 = 0
    public var formattedTotal: String = ""
    public var credentialsTitle: String = ""
    public var prices: ArrayList<PaymentPriceViewModel> = ArrayList<PaymentPriceViewModel>()
    public var transactionId: String = ""
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

// ==================== Helper functions ====================

// formatCurrencyAmount is defined in CurrencyFormatter.cj (same package)
// It implements per-currency decimal digits, symbol position, and locale separators
// based on the iOS currencies.json + CurrencyFormat.swift ground truth.

func priceEntryToViewModel(entry: PaymentPriceEntry): PaymentPriceViewModel {
    let vm = PaymentPriceViewModel()
    vm.label = entry.label
    vm.amount = entry.amount
    vm.formattedAmount = formatCurrencyAmount("", entry.amount)
    return vm
}

func shippingOptionToViewModel(opt: ShippingOptionInfo): ShippingOptionViewModel {
    let vm = ShippingOptionViewModel()
    vm.id = opt.id
    vm.title = opt.title
    for (p in opt.prices) {
        vm.prices.add(priceEntryToViewModel(p))
    }
    return vm
}

// ==================== PaymentsDataProvider ====================

public class PaymentsDataProvider {
    private let service = getPaymentsService()

    /**
     * 获取支付表单并转换为 ViewModel
     *
     * 对应 iOS engine.payments.fetchBotPaymentForm(source: .message(msgId))
     * @param peerId     发送 invoice 的 peer userId
     * @param accessHash peer access_hash
     * @param msgId      invoice 消息 ID
     * @return PaymentFormViewModel
     */
    public func getPaymentForm(peerId: Int64, accessHash: Int64, msgId: Int32): PaymentFormViewModel {
        let vm = PaymentFormViewModel()
        let resp = this.service.getPaymentForm(peerId, accessHash, msgId)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getPaymentForm failed")
            return vm
        }
        vm.formId = resp.formId
        vm.botId = resp.botId
        vm.title = resp.title
        vm.description = resp.description
        vm.currency = resp.currency
        vm.canSaveCredentials = resp.canSaveCredentials
        vm.passwordMissing = resp.passwordMissing
        vm.paymentUrl = resp.url
        vm.nativeProvider = resp.nativeProvider
        vm.nativeParamsJson = resp.nativeParamsJson
        vm.isTest = resp.isTest
        var total: Int64 = 0
        for (p in resp.prices) {
            let pvm = PaymentPriceViewModel()
            pvm.label = p.label
            pvm.amount = p.amount
            pvm.formattedAmount = formatCurrencyAmount(resp.currency, p.amount)
            vm.prices.add(pvm)
            total = total + p.amount
        }
        vm.totalAmount = total
        vm.loaded = true
        return vm
    }

    /**
     * 通过 slug 获取支付表单
     *
     * 对应 iOS BotPaymentInvoiceSource.slug
     * @param slug invoice slug
     * @return PaymentFormViewModel
     */
    public func getPaymentFormBySlug(slug: String): PaymentFormViewModel {
        let vm = PaymentFormViewModel()
        let resp = this.service.getPaymentFormBySlug(slug)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getPaymentFormBySlug failed")
            return vm
        }
        vm.formId = resp.formId
        vm.botId = resp.botId
        vm.title = resp.title
        vm.description = resp.description
        vm.currency = resp.currency
        vm.canSaveCredentials = resp.canSaveCredentials
        vm.passwordMissing = resp.passwordMissing
        vm.paymentUrl = resp.url
        vm.nativeProvider = resp.nativeProvider
        vm.nativeParamsJson = resp.nativeParamsJson
        vm.isTest = resp.isTest
        var total2: Int64 = 0
        for (p2 in resp.prices) {
            let pvm2 = PaymentPriceViewModel()
            pvm2.label = p2.label
            pvm2.amount = p2.amount
            pvm2.formattedAmount = formatCurrencyAmount(resp.currency, p2.amount)
            vm.prices.add(pvm2)
            total2 = total2 + p2.amount
        }
        vm.totalAmount = total2
        vm.loaded = true
        return vm
    }

    /**
     * 验证支付请求信息
     *
     * 对应 iOS engine.payments.validateBotPaymentForm
     * @param peerId      peer userId
     * @param accessHash  peer access_hash
     * @param msgId       invoice 消息 ID
     * @param save        是否保存信息
     * @param name        姓名
     * @param phone       电话
     * @param email       邮箱
     * @param hasAddress  是否包含地址
     * @param streetLine1 地址行 1
     * @param streetLine2 地址行 2
     * @param city        城市
     * @param state       省州
     * @param countryIso2 国家代码
     * @param postCode    邮编
     * @return ValidatedInfoViewModel
     */
    public func validateRequestedInfo(
        peerId: Int64,
        accessHash: Int64,
        msgId: Int32,
        save: Bool,
        name: String,
        phone: String,
        email: String,
        hasAddress: Bool,
        streetLine1: String,
        streetLine2: String,
        city: String,
        state: String,
        countryIso2: String,
        postCode: String
    ): ValidatedInfoViewModel {
        let vm = ValidatedInfoViewModel()
        let resp = this.service.validateRequestedInfo(
            peerId, accessHash, msgId, save,
            name, phone, email,
            hasAddress, streetLine1, streetLine2, city, state, countryIso2, postCode
        )
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] validateRequestedInfo failed")
            return vm
        }
        vm.validatedInfoId = resp.validatedInfoId
        for (opt in resp.shippingOptions) {
            vm.shippingOptions.add(shippingOptionToViewModel(opt))
        }
        vm.validated = true
        return vm
    }

    /**
     * 执行支付（凭证 JSON 模式）
     *
     * 对应 iOS engine.payments.sendBotPaymentForm(credentials: .generic)
     * @param formId            支付表单 ID
     * @param peerId            peer userId
     * @param accessHash        peer access_hash
     * @param msgId             invoice 消息 ID
     * @param requestedInfoId   校验 ID（可为空字符串）
     * @param shippingOptionId  运费选项 ID（可为空字符串）
     * @param credentialsJson   Provider SDK 返回的支付 token JSON
     * @param saveCredentials   是否保存凭证
     * @return PaymentResultViewModel
     */
    public func sendPayment(
        formId: Int64,
        peerId: Int64,
        accessHash: Int64,
        msgId: Int32,
        requestedInfoId: String,
        shippingOptionId: String,
        credentialsJson: String,
        saveCredentials: Bool
    ): PaymentResultViewModel {
        let vm = PaymentResultViewModel()
        let resp = this.service.sendPaymentForm(
            formId, peerId, accessHash, msgId,
            requestedInfoId, shippingOptionId,
            credentialsJson, saveCredentials
        )
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] sendPayment failed")
            return vm
        }
        vm.success = true
        vm.verificationRequired = resp.verificationRequired
        vm.verificationUrl = resp.verificationUrl
        return vm
    }

    /**
     * 执行支付（已保存凭证模式）
     *
     * 对应 iOS engine.payments.sendBotPaymentForm(credentials: .saved)
     * @param formId           支付表单 ID
     * @param peerId           peer userId
     * @param accessHash       peer access_hash
     * @param msgId            invoice 消息 ID
     * @param requestedInfoId  校验 ID（可为空字符串）
     * @param shippingOptionId 运费选项 ID（可为空字符串）
     * @param savedId          已保存凭证 ID
     * @param tmpPassword      2FA 临时密码字节
     * @return PaymentResultViewModel
     */
    public func sendPaymentWithSavedCredentials(
        formId: Int64,
        peerId: Int64,
        accessHash: Int64,
        msgId: Int32,
        requestedInfoId: String,
        shippingOptionId: String,
        savedId: String,
        tmpPassword: Array<Byte>
    ): PaymentResultViewModel {
        let vm = PaymentResultViewModel()
        let resp = this.service.sendPaymentFormWithSavedCredentials(
            formId, peerId, accessHash, msgId,
            requestedInfoId, shippingOptionId,
            savedId, tmpPassword
        )
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] sendPaymentSaved failed")
            return vm
        }
        vm.success = true
        vm.verificationRequired = resp.verificationRequired
        vm.verificationUrl = resp.verificationUrl
        return vm
    }

    /**
     * 获取支付收据
     *
     * 对应 iOS engine.payments.requestBotPaymentReceipt(messageId:)
     * @param peerId     peer userId
     * @param accessHash peer access_hash
     * @param msgId      收据消息 ID
     * @return PaymentReceiptViewModel
     */
    public func getPaymentReceipt(peerId: Int64, accessHash: Int64, msgId: Int32): PaymentReceiptViewModel {
        let vm = PaymentReceiptViewModel()
        let resp = this.service.getPaymentReceipt(peerId, accessHash, msgId)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getPaymentReceipt failed")
            return vm
        }
        vm.date = resp.date
        vm.botId = resp.botId
        vm.title = resp.title
        vm.description = resp.description
        vm.currency = resp.currency
        vm.totalAmount = resp.totalAmount
        vm.formattedTotal = formatCurrencyAmount(resp.currency, resp.totalAmount)
        vm.credentialsTitle = resp.credentialsTitle
        vm.transactionId = resp.transactionId
        for (p3 in resp.prices) {
            let pvm3 = PaymentPriceViewModel()
            pvm3.label = p3.label
            pvm3.amount = p3.amount
            pvm3.formattedAmount = formatCurrencyAmount(resp.currency, p3.amount)
            vm.prices.add(pvm3)
        }
        vm.loaded = true
        return vm
    }

    /**
     * 获取银行卡信息
     *
     * 对应 iOS engine.payments.getBankCardInfo(cardNumber:)
     * @param cardNumber 银行卡号或卡 BIN
     * @return BankCardInfoViewModel（银行名称 + 相关链接）
     */
    public func getBankCardInfo(cardNumber: String): BankCardInfoViewModel {
        let vm = BankCardInfoViewModel()
        let resp = this.service.getBankCardData(cardNumber)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getBankCardInfo failed")
            return vm
        }
        vm.title = resp.title
        for (u in resp.openUrls) {
            let uvm = BankCardUrlViewModel()
            uvm.title = u.title
            uvm.url = u.url
            vm.openUrls.add(uvm)
        }
        vm.loaded = true
        return vm
    }

    // ==================== P2-155: Stars 生态读核心 ViewModel/Provider ====================

    /**
     * 获取 Stars 余额状态
     *
     * 对应 iOS: StarsContext.State (balance + transactions)
     * @return StarsBalanceViewModel（balanceStars/nanos + 首批 transactions）
     */
    public func getStarsStatus(): StarsBalanceViewModel {
        let vm = StarsBalanceViewModel()
        let resp = this.service.getStarsStatus()
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getStarsStatus failed")
            return vm
        }
        vm.balanceStars = resp.balanceAmount
        vm.balanceNanos = resp.balanceNanos
        vm.nextOffset = resp.nextOffset
        for (tx in resp.transactions) {
            vm.transactions.add(starsTransactionEntryToViewModel(tx))
        }
        vm.loaded = true
        return vm
    }

    public func getTonStatus(): StarsBalanceViewModel {
        let vm = StarsBalanceViewModel()
        let resp = this.service.getTonStatus()
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            return vm
        }
        vm.balanceStars = resp.balanceAmount
        vm.balanceNanos = resp.balanceNanos
        vm.nextOffset = resp.nextOffset
        for (tx in resp.transactions) { vm.transactions.add(starsTransactionEntryToViewModel(tx)) }
        vm.loaded = true
        return vm
    }

    /**
     * 获取 Stars 交易历史（分页）
     *
     * 对应 iOS: StarsTransactionsContext.loadMore (Stars.swift)
     * @param offset   分页 offset（首次传空字符串）
     * @param limit    每页条目数
     * @param inbound  仅收入
     * @param outbound 仅支出
     * @return StarsTransactionsViewModel
     */
    public func getStarsTransactions(
        offset: String,
        limit: Int32,
        inbound: Bool,
        outbound: Bool
    ): StarsTransactionsViewModel {
        let vm = StarsTransactionsViewModel()
        let resp = this.service.getStarsTransactions(offset, limit, inbound, outbound)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getStarsTransactions failed")
            return vm
        }
        vm.nextOffset = resp.nextOffset
        for (tx in resp.transactions) {
            vm.transactions.add(starsTransactionEntryToViewModel(tx))
        }
        vm.loaded = true
        return vm
    }

    /**
     * 按 ID 查询 Stars 交易
     *
     * 对应 iOS: getStarsTransactionsByID (TelegramEnginePayments.swift)
     * @param transactionIds 交易 ID 列表
     * @return StarsTransactionsViewModel
     */
    public func getStarsTransactionsByID(transactionIds: ArrayList<String>): StarsTransactionsViewModel {
        let vm = StarsTransactionsViewModel()
        let resp = this.service.getStarsTransactionsByID(transactionIds)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getStarsTransactionsByID failed")
            return vm
        }
        vm.nextOffset = resp.nextOffset
        for (tx in resp.transactions) {
            vm.transactions.add(starsTransactionEntryToViewModel(tx))
        }
        vm.loaded = true
        return vm
    }

    /**
     * 获取 Stars 充值选项
     *
     * 对应 iOS: _internal_starsTopUpOptions (Stars.swift:61-126)
     * @return StarsTopupOptionsViewModel
     */
    public func getStarsTopupOptions(): StarsTopupOptionsViewModel {
        let vm = StarsTopupOptionsViewModel()
        let resp = this.service.getStarsTopupOptions()
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getStarsTopupOptions failed")
            return vm
        }
        for (opt in resp.options) {
            let ovm = StarsTopupOptionViewModel()
            ovm.stars = opt.stars
            ovm.storeProduct = opt.storeProduct
            ovm.currency = opt.currency
            ovm.amount = opt.amount
            ovm.isExtended = opt.isExtended
            vm.options.add(ovm)
        }
        vm.loaded = true
        return vm
    }

    /**
     * 获取 Stars 赠礼选项
     *
     * 对应 iOS: _internal_starsGiftOptions (Stars.swift:128-175)
     * @return StarsGiftOptionsViewModel
     */
    public func getStarsGiftOptions(): StarsGiftOptionsViewModel {
        let vm = StarsGiftOptionsViewModel()
        let resp = this.service.getStarsGiftOptions()
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getStarsGiftOptions failed")
            return vm
        }
        for (opt in resp.options) {
            let ovm = StarsGiftOptionViewModel()
            ovm.stars = opt.stars
            ovm.storeProduct = opt.storeProduct
            ovm.currency = opt.currency
            ovm.amount = opt.amount
            ovm.isExtended = opt.isExtended
            vm.options.add(ovm)
        }
        vm.loaded = true
        return vm
    }

    // ==================== P2-155b: Star Gifts Provider 方法 ====================

    /**
     * 获取礼物商品目录
     *
     * 对应 iOS: getStarGifts in StarGifts.swift
     * @param hash 0 表示首次加载
     * @return StarGiftsCatalogViewModel
     */
    public func getStarGiftsCatalog(hash: Int32): StarGiftsCatalogViewModel {
        let vm = StarGiftsCatalogViewModel()
        let resp = this.service.getStarGifts(hash)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getStarGiftsCatalog failed")
            return vm
        }
        if (resp.notModified) {
            vm.notModified = true
            vm.loaded = true
            return vm
        }
        for (g in resp.gifts) {
            vm.gifts.add(starGiftEntryToViewModel(g))
        }
        vm.loaded = true
        return vm
    }

    /**
     * 将礼物转换为 Stars（msg_id 变体）
     *
     * 对应 iOS: convertStarGift (StarGifts.swift:1406)
     * @param msgId 礼物消息 ID
     * @return StarGiftBoolResultViewModel
     */
    public func convertStarGift(msgId: Int32): StarGiftBoolResultViewModel {
        let vm = StarGiftBoolResultViewModel()
        let resp = this.service.convertStarGiftByMsgId(msgId)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] convertStarGift failed")
            return vm
        }
        vm.success = true
        vm.result = resp.result
        return vm
    }

    /**
     * 将 Unique Gift 转换为 Stars（slug 变体）
     *
     * @param slug Unique Gift slug
     * @return StarGiftBoolResultViewModel
     */
    public func convertStarGiftBySlug(slug: String): StarGiftBoolResultViewModel {
        let vm = StarGiftBoolResultViewModel()
        let resp = this.service.convertStarGiftBySlug(slug)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] convertStarGiftBySlug failed")
            return vm
        }
        vm.success = true
        vm.result = resp.result
        return vm
    }

    /**
     * 保存/取消保存礼物到个人主页
     *
     * 对应 iOS: _internal_updateStarGiftAddedToProfile (StarGifts.swift:1431)
     * @param msgId  礼物消息 ID
     * @param unsave true=移除, false=添加到主页
     * @return StarGiftBoolResultViewModel
     */
    public func saveStarGift(msgId: Int32, unsave: Bool): StarGiftBoolResultViewModel {
        let vm = StarGiftBoolResultViewModel()
        let resp = this.service.saveStarGift(msgId, unsave)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] saveStarGift failed")
            return vm
        }
        vm.success = true
        vm.result = resp.result
        return vm
    }

    /**
     * 升级礼物为 Unique Gift
     *
     * 对应 iOS: _internal_upgradeStarGift (StarGifts.swift:1643)
     * @param msgId             礼物消息 ID
     * @param keepOriginalDetails 保留原始发送人信息
     * @return StarGiftActionResultViewModel
     */
    public func upgradeStarGift(msgId: Int32, keepOriginalDetails: Bool): StarGiftActionResultViewModel {
        let vm = StarGiftActionResultViewModel()
        let resp = this.service.upgradeStarGift(msgId, keepOriginalDetails)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] upgradeStarGift failed")
            return vm
        }
        vm.success = true
        return vm
    }

    /**
     * 转赠礼物给他人（prepaid 路径）
     *
     * 对应 iOS: _internal_transferStarGift prepaid=true (StarGifts.swift:1603)
     * @param msgId        礼物消息 ID
     * @param toUserId     目标用户 ID
     * @param toAccessHash 目标用户 access_hash
     * @return StarGiftActionResultViewModel
     */
    public func transferStarGift(msgId: Int32, toUserId: Int64, toAccessHash: Int64): StarGiftActionResultViewModel {
        let vm = StarGiftActionResultViewModel()
        let resp = this.service.transferStarGift(msgId, toUserId, toAccessHash)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] transferStarGift failed")
            return vm
        }
        vm.success = true
        return vm
    }

    /**
     * 获取 Unique Gift 提现 URL
     *
     * 对应 iOS: getStarGiftWithdrawalUrl (TelegramEnginePayments.swift)
     * 需要 2FA 验证参数（SRP）
     * @param slug   Gift slug
     * @param srpId  SRP 会话 ID
     * @param srpA   SRP 参数 A
     * @param srpM1  SRP 验证值 M1
     * @return StarGiftWithdrawalViewModel
     */
    public func getStarGiftWithdrawalUrl(
        slug: String,
        srpId: Int64,
        srpA: Array<Byte>,
        srpM1: Array<Byte>
    ): StarGiftWithdrawalViewModel {
        let vm = StarGiftWithdrawalViewModel()
        let resp = this.service.getStarGiftWithdrawalUrl(slug, srpId, srpA, srpM1)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getStarGiftWithdrawalUrl failed")
            return vm
        }
        vm.url = resp.url
        vm.loaded = true
        return vm
    }

    /**
     * 设置或取消礼物的二次销售价格
     *
     * 对应 iOS: updateStarGiftPrice (TelegramEnginePayments.swift)
     * resellStars=0 → 下架; resellStars>0 → 上架并设定价格
     * @param slug        Gift slug
     * @param resellStars 转售价格（Stars 数），0 表示下架
     * @return StarGiftActionResultViewModel
     */
    public func updateStarGiftPrice(slug: String, resellStars: Int64): StarGiftActionResultViewModel {
        let vm = StarGiftActionResultViewModel()
        let resp = this.service.updateStarGiftPrice(slug, resellStars)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] updateStarGiftPrice failed")
            return vm
        }
        vm.success = true
        return vm
    }

    /**
     * 获取用户已保存礼物列表
     *
     * 对应 iOS: ProfileGiftsContext (StarGifts.swift)
     * @param peerId      目标用户 ID（0=自己）
     * @param accessHash  用户 access_hash（peerId=0 时忽略）
     * @param offset      分页 offset（首次传空字符串）
     * @param limit       每页条目数
     * @param sortByValue 按价值排序
     * @return SavedStarGiftsViewModel
     */
    public func getSavedStarGifts(
        peerId: Int64,
        accessHash: Int64,
        offset: String,
        limit: Int32,
        sortByValue: Bool
    ): SavedStarGiftsViewModel {
        let vm = SavedStarGiftsViewModel()
        let resp = this.service.getSavedStarGifts(peerId, accessHash, offset, limit, sortByValue)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getSavedStarGifts failed")
            return vm
        }
        vm.count = resp.count
        vm.nextOffset = resp.nextOffset
        for (g in resp.gifts) {
            vm.gifts.add(savedStarGiftEntryToViewModel(g))
        }
        vm.loaded = true
        return vm
    }

    /**
     * 获取二次销售市场上的 Unique Gifts 列表
     *
     * 对应 iOS: getResaleStarGifts (TelegramEnginePayments.swift)
     * @param giftId     原始 StarGift id
     * @param offset     分页 offset
     * @param limit      每页条目数
     * @param sortByPrice 按价格排序（false=按编号）
     * @return ResaleStarGiftsViewModel
     */
    public func getResaleStarGifts(
        giftId: Int64,
        offset: String,
        limit: Int32,
        sortByPrice: Bool,
        sortByNum: Bool,
        starsOnly: Bool,
        attributes: ArrayList<StarGiftAttributeIdEntry>
    ): ResaleStarGiftsViewModel {
        let vm = ResaleStarGiftsViewModel()
        let resp = this.service.getResaleStarGifts(giftId, offset, limit, sortByPrice, sortByNum, starsOnly, attributes)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getResaleStarGifts failed")
            return vm
        }
        vm.count = resp.count
        vm.nextOffset = resp.nextOffset
        for (g in resp.gifts) {
            vm.gifts.add(starGiftEntryToViewModel(g))
        }
        for (attribute in resp.attributes) {
            vm.attributes.add(starGiftAttributeEntryToViewModel(attribute))
        }
        vm.loaded = true
        return vm
    }

    /**
     * 获取 StarGift 升级预览（upgrade preview 属性样本 + 价格区间）
     *
     * 对应 iOS: getStarGiftUpgradePreview (TelegramEnginePayments.swift)
     * 返回升级所需属性样本（model/pattern/backdrop 各若干）及价格区间。
     * @param giftId 原始 StarGift id
     * @return StarGiftUpgradePreviewViewModel
     */
    public func getStarGiftUpgradePreview(giftId: Int64): StarGiftUpgradePreviewViewModel {
        let vm = StarGiftUpgradePreviewViewModel()
        let resp = this.service.getStarGiftUpgradePreview(giftId)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getStarGiftUpgradePreview failed")
            return vm
        }
        for (attr in resp.sampleAttributes) {
            vm.sampleAttributes.add(starGiftAttributeEntryToViewModel(attr))
        }
        for (price in resp.prices) {
            vm.prices.add(starGiftUpgradePriceEntryToViewModel(price))
        }
        for (price in resp.nextPrices) {
            vm.nextPrices.add(starGiftUpgradePriceEntryToViewModel(price))
        }
        vm.loaded = true
        return vm
    }

    // ==================== P2-155c: Premium Gift Codes + Giveaways Provider ====================

    /**
     * 校验 Premium 礼品码
     *
     * 对应 iOS: engine.payments.checkGiftCode (GiftCodes.swift:267)
     * @param slug 礼品码 slug
     * @return CheckedGiftCodeViewModel
     */
    public func checkGiftCode(slug: String): CheckedGiftCodeViewModel {
        let vm = CheckedGiftCodeViewModel()
        let resp = this.service.checkGiftCode(slug)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] checkGiftCode failed")
            return vm
        }
        vm.viaGiveaway = resp.viaGiveaway
        vm.fromPeerId = resp.fromPeerId
        vm.fromPeerType = resp.fromPeerType
        vm.giveawayMsgId = resp.giveawayMsgId
        vm.toPeerId = resp.toPeerId
        vm.date = resp.date
        vm.months = resp.months
        vm.usedDate = resp.usedDate
        vm.isUsed = resp.isUsed
        vm.loaded = true
        return vm
    }

    /**
     * 兑换 Premium 礼品码
     *
     * 对应 iOS: engine.payments.applyGiftCode (GiftCodes.swift:295)
     * @param slug 礼品码 slug
     * @return GiftCodeApplyResultViewModel
     */
    public func applyGiftCode(slug: String): GiftCodeApplyResultViewModel {
        let vm = GiftCodeApplyResultViewModel()
        let resp = this.service.applyGiftCode(slug)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] applyGiftCode failed")
            return vm
        }
        vm.success = true
        return vm
    }

    /**
     * 获取 Premium 礼品码套餐选项
     *
     * 对应 iOS: engine.payments.getPremiumGiftCodeOptions (GiftCodes.swift:199)
     * boostPeerId=0 → 获取全局通用选项；>0 → 获取指定频道的 boosting 选项
     * @param boostPeerId    可选 boost 频道 channelId（0=全局）
     * @param boostAccessHash 对应 access_hash
     * @return PremiumGiftCodeOptionsViewModel
     */
    public func getPremiumGiftCodeOptions(boostPeerId: Int64, boostAccessHash: Int64): PremiumGiftCodeOptionsViewModel {
        let vm = PremiumGiftCodeOptionsViewModel()
        let resp = this.service.getPremiumGiftCodeOptions(boostPeerId, boostAccessHash)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getPremiumGiftCodeOptions failed")
            return vm
        }
        for (opt in resp.options) {
            vm.options.add(premiumGiftCodeOptionEntryToViewModel(opt))
        }
        vm.loaded = true
        return vm
    }

    /**
     * 查询抽奖信息
     *
     * 对应 iOS: engine.payments.getGiveawayInfo (GiftCodes.swift:109)
     * @param peerId    抽奖频道 channelId
     * @param accessHash 频道 access_hash
     * @param msgId     包含抽奖的消息 ID
     * @return GiveawayInfoViewModel
     */
    public func getGiveawayInfo(peerId: Int64, accessHash: Int64, msgId: Int32): GiveawayInfoViewModel {
        let vm = GiveawayInfoViewModel()
        let resp = this.service.getGiveawayInfo(peerId, accessHash, msgId)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getGiveawayInfo failed")
            return vm
        }
        vm.infoType = resp.infoType
        vm.startDate = resp.startDate
        vm.ongoingStatus = resp.ongoingStatus
        vm.joinedTooEarlyDate = resp.joinedTooEarlyDate
        vm.adminDisallowedChatId = resp.adminDisallowedChatId
        vm.disallowedCountry = resp.disallowedCountry
        vm.resultStatus = resp.resultStatus
        vm.giftCodeSlug = resp.giftCodeSlug
        vm.starsPrize = resp.starsPrize
        vm.finishDate = resp.finishDate
        vm.winnersCount = resp.winnersCount
        vm.activatedCount = resp.activatedCount
        vm.loaded = true
        return vm
    }

    /**
     * 启动预付费 Premium 抽奖
     *
     * 对应 iOS: engine.payments.launchPrepaidGiveaway premium 路径 (GiftCodes.swift:320)
     * @param peerId             抽奖频道 channelId
     * @param accessHash         access_hash
     * @param giveawayId         PrepaidGiveaway.id
     * @param onlyNewSubscribers 仅限新订阅者
     * @param winnersAreVisible  公示获奖者
     * @param additionalPeerIds  额外频道 channelIds
     * @param additionalHashes   对应 access_hash 列表
     * @param countriesIso2      国家/地区限制
     * @param prizeDescription   奖品描述（空字符串表示无）
     * @param randomId           去重随机数
     * @param untilDate          截止时间（Unix 时间戳）
     * @param currency           货币代码
     * @param amount             金额（分为单位）
     * @return GiveawayLaunchResultViewModel
     */
    public func launchPrepaidGiveaway(
        peerId: Int64,
        accessHash: Int64,
        giveawayId: Int64,
        onlyNewSubscribers: Bool,
        winnersAreVisible: Bool,
        additionalPeerIds: ArrayList<Int64>,
        additionalHashes: ArrayList<Int64>,
        countriesIso2: ArrayList<String>,
        prizeDescription: String,
        randomId: Int64,
        untilDate: Int32,
        currency: String,
        amount: Int64
    ): GiveawayLaunchResultViewModel {
        let vm = GiveawayLaunchResultViewModel()
        let resp = this.service.launchPrepaidGiveaway(
            peerId, accessHash, giveawayId,
            onlyNewSubscribers, winnersAreVisible,
            additionalPeerIds, additionalHashes, countriesIso2,
            prizeDescription, randomId, untilDate, currency, amount
        )
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] launchPrepaidGiveaway failed")
            return vm
        }
        vm.success = true
        return vm
    }

    // ==================== P2-155d: Stars Subscriptions + Revenue Provider ====================

    /**
     * 获取 Stars 订阅列表
     *
     * 对应 iOS: _internal_requestStarsSubscriptions (Stars.swift:505)
     * @param offset         分页 offset（首次传空字符串）
     * @param missingBalance 优先返回余额不足的订阅
     * @return StarsSubscriptionsViewModel（订阅列表 + 余额 + nextOffset）
     */
    public func getStarsSubscriptions(offset: String, missingBalance: Bool): StarsSubscriptionsViewModel {
        let vm = StarsSubscriptionsViewModel()
        let resp = this.service.getStarsSubscriptions(offset, missingBalance)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getStarsSubscriptions failed")
            return vm
        }
        vm.balanceStars = resp.balanceAmount
        vm.balanceNanos = resp.balanceNanos
        vm.nextOffset = resp.subscriptionsNextOffset
        vm.subscriptionsMissingBalance = resp.subscriptionsMissingBalance
        for (sub in resp.subscriptions) {
            vm.subscriptions.add(starsSubscriptionEntryToViewModel(sub))
        }
        vm.loaded = true
        return vm
    }

    /**
     * 取消或恢复 Stars 订阅
     *
     * 对应 iOS: StarsSubscriptionsContext.updateSubscription (Stars.swift:1506)
     * @param peerId         订阅所在 peer userId（0=当前用户）
     * @param accessHash     peer access_hash
     * @param subscriptionId 订阅 ID
     * @param cancel         true=取消, false=恢复
     * @return StarsSubscriptionActionViewModel（result=true 表示成功）
     */
    public func changeStarsSubscription(
        peerId: Int64,
        accessHash: Int64,
        subscriptionId: String,
        cancel: Bool
    ): StarsSubscriptionActionViewModel {
        let vm = StarsSubscriptionActionViewModel()
        let resp = this.service.changeStarsSubscription(peerId, accessHash, subscriptionId, cancel)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] changeStarsSubscription failed")
            return vm
        }
        vm.success = true
        vm.result = resp.result
        return vm
    }

    /**
     * 履行余额不足的 Stars 订阅
     *
     * 对应 iOS: _internal_fulfillStarsSubscription (Stars.swift:1866)
     * @param peerId         订阅所在 peer userId（0=当前用户）
     * @param accessHash     peer access_hash
     * @param subscriptionId 订阅 ID
     * @return StarsSubscriptionActionViewModel（result=true 表示成功）
     */
    public func fulfillStarsSubscription(
        peerId: Int64,
        accessHash: Int64,
        subscriptionId: String
    ): StarsSubscriptionActionViewModel {
        let vm = StarsSubscriptionActionViewModel()
        let resp = this.service.fulfillStarsSubscription(peerId, accessHash, subscriptionId)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] fulfillStarsSubscription failed")
            return vm
        }
        vm.success = true
        vm.result = resp.result
        return vm
    }

    /**
     * 获取频道/用户 Stars 收益统计
     *
     * 对应 iOS: 在 StatisticsUI.ChannelStatsController 中使用
     * @param peerId     目标频道 channelId（0=当前用户）
     * @param accessHash peer access_hash
     * @param dark       true=请求暗色主题图表数据
     * @return StarsRevenueStatsViewModel（余额/收益/USD汇率）
     */
    public func getStarsRevenueStats(peerId: Int64, accessHash: Int64, dark: Bool): StarsRevenueStatsViewModel {
        let vm = StarsRevenueStatsViewModel()
        let resp = this.service.getStarsRevenueStats(peerId, accessHash, dark)
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getStarsRevenueStats failed")
            return vm
        }
        vm.withdrawalEnabled = resp.withdrawalEnabled
        vm.currentBalanceStars = resp.currentBalanceAmount
        vm.currentBalanceNanos = resp.currentBalanceNanos
        vm.availableBalanceStars = resp.availableBalanceAmount
        vm.availableBalanceNanos = resp.availableBalanceNanos
        vm.overallRevenueStars = resp.overallRevenueAmount
        vm.overallRevenueNanos = resp.overallRevenueNanos
        vm.nextWithdrawalAt = resp.nextWithdrawalAt
        vm.hasNextWithdrawalAt = resp.hasNextWithdrawalAt
        vm.usdRate = resp.usdRate
        vm.revenueGraphJson = resp.revenueGraphJson
        vm.revenueGraphToken = resp.revenueGraphToken
        vm.loaded = true
        return vm
    }

    /**
     * 获取 Stars 收益提现 URL
     *
     * 对应 iOS: RevenueWithdrawalController (StatisticsUI)
     * 需要 2FA SRP 验证参数。
     * @param peerId     目标频道 channelId（0=当前用户）
     * @param accessHash peer access_hash
     * @param hasAmount  是否指定提现金额（false=提现全部可用余额）
     * @param amount     提现金额（Stars 数）
     * @param srpId      SRP 会话 ID
     * @param srpA       SRP 参数 A
     * @param srpM1      SRP 验证值 M1
     * @return StarsRevenueWithdrawalViewModel（url 字段含 Fragment 提现页面 URL）
     */
    public func getStarsRevenueWithdrawalUrl(
        peerId: Int64,
        accessHash: Int64,
        hasAmount: Bool,
        amount: Int64,
        srpId: Int64,
        srpA: Array<Byte>,
        srpM1: Array<Byte>
    ): StarsRevenueWithdrawalViewModel {
        let vm = StarsRevenueWithdrawalViewModel()
        let resp = this.service.getStarsRevenueWithdrawalUrl(
            peerId, accessHash, hasAmount, amount, srpId, srpA, srpM1
        )
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] getStarsRevenueWithdrawalUrl failed")
            return vm
        }
        vm.url = resp.url
        vm.loaded = true
        return vm
    }

    /**
     * 启动预付费 Stars 抽奖
     *
     * 对应 iOS: engine.payments.launchPrepaidGiveaway stars 路径 (GiftCodes.swift:355)
     * @param peerId             抽奖频道 channelId
     * @param accessHash         access_hash
     * @param giveawayId         PrepaidGiveaway.id
     * @param stars              Stars 奖品总量
     * @param users              中奖人数
     * @param onlyNewSubscribers 仅限新订阅者
     * @param winnersAreVisible  公示获奖者
     * @param additionalPeerIds  额外频道 channelIds
     * @param additionalHashes   对应 access_hash 列表
     * @param countriesIso2      国家/地区限制
     * @param prizeDescription   奖品描述
     * @param randomId           去重随机数
     * @param untilDate          截止时间
     * @param currency           货币代码
     * @param amount             金额
     * @return GiveawayLaunchResultViewModel
     */
    public func launchPrepaidStarsGiveaway(
        peerId: Int64,
        accessHash: Int64,
        giveawayId: Int64,
        stars: Int64,
        users: Int32,
        onlyNewSubscribers: Bool,
        winnersAreVisible: Bool,
        additionalPeerIds: ArrayList<Int64>,
        additionalHashes: ArrayList<Int64>,
        countriesIso2: ArrayList<String>,
        prizeDescription: String,
        randomId: Int64,
        untilDate: Int32,
        currency: String,
        amount: Int64
    ): GiveawayLaunchResultViewModel {
        let vm = GiveawayLaunchResultViewModel()
        let resp = this.service.launchPrepaidStarsGiveaway(
            peerId, accessHash, giveawayId,
            stars, users,
            onlyNewSubscribers, winnersAreVisible,
            additionalPeerIds, additionalHashes, countriesIso2,
            prizeDescription, randomId, untilDate, currency, amount
        )
        if (!resp.success) {
            vm.errorMessage = resp.errorMessage
            Hilog.info(0, "CjTelegram", "[PaymentsDataProvider] launchPrepaidStarsGiveaway failed")
            return vm
        }
        vm.success = true
        return vm
    }
}

// ==================== P2-155: Stars ViewModel 类型 ====================

/**
 * Stars 余额状态 ViewModel（对应 iOS StarsContext.State）
 */
public class StarsBalanceViewModel {
    public var balanceStars: Int64 = 0
    public var balanceNanos: Int32 = 0
    public var nextOffset: String = ""
    public var transactions: ArrayList<StarsTransactionViewModel> = ArrayList<StarsTransactionViewModel>()
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * Stars 交易列表 ViewModel（对应 iOS StarsTransactionsContext.State.transactions）
 */
public class StarsTransactionsViewModel {
    public var transactions: ArrayList<StarsTransactionViewModel> = ArrayList<StarsTransactionViewModel>()
    public var nextOffset: String = ""
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * 单条 Stars 交易 ViewModel（对应 iOS StarsContext.State.Transaction）
 */
public class StarsTransactionViewModel {
    public var id: String = ""
    public var starsAmount: Int64 = 0
    public var starsNanos: Int32 = 0
    public var date: Int32 = 0
    public var peerType: String = ""
    public var peerId: Int64 = 0
    public var title: String = ""
    public var description: String = ""
    public var transactionUrl: String = ""
    public var isRefund: Bool = false
    public var isPending: Bool = false
    public var isFailed: Bool = false
}

/**
 * Stars 充值选项 ViewModel（对应 iOS StarsTopUpOption）
 */
public class StarsTopupOptionViewModel {
    public var stars: Int64 = 0
    public var storeProduct: String = ""
    public var currency: String = ""
    public var amount: Int64 = 0
    public var isExtended: Bool = false
}

/**
 * Stars 充值选项列表 ViewModel
 */
public class StarsTopupOptionsViewModel {
    public var options: ArrayList<StarsTopupOptionViewModel> = ArrayList<StarsTopupOptionViewModel>()
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * Stars 赠礼选项 ViewModel（对应 iOS StarsGiftOption）
 */
public class StarsGiftOptionViewModel {
    public var stars: Int64 = 0
    public var storeProduct: String = ""
    public var currency: String = ""
    public var amount: Int64 = 0
    public var isExtended: Bool = false
}

/**
 * Stars 赠礼选项列表 ViewModel
 */
public class StarsGiftOptionsViewModel {
    public var options: ArrayList<StarsGiftOptionViewModel> = ArrayList<StarsGiftOptionViewModel>()
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

func starsTransactionEntryToViewModel(tx: StarsTransactionEntry): StarsTransactionViewModel {
    let vm = StarsTransactionViewModel()
    vm.id = tx.id
    vm.starsAmount = tx.starsAmount
    vm.starsNanos = tx.starsNanos
    vm.date = tx.date
    vm.peerType = tx.peer.peerType
    vm.peerId = tx.peer.peerId
    vm.title = tx.title
    vm.description = tx.description
    vm.transactionUrl = tx.transactionUrl
    vm.isRefund = tx.isRefund
    vm.isPending = tx.isPending
    vm.isFailed = tx.isFailed
    return vm
}

// ==================== P2-155b: Star Gifts ViewModel 类型 ====================

/**
 * StarGift 商品 ViewModel（对应 iOS StarGift enum）
 * 覆盖普通礼物（starGift#c62aca28）和独特礼物（starGiftUnique#6411db89）
 */
public class StarGiftViewModel {
    public var isUnique: Bool = false
    public var id: Int64 = 0
    public var stars: Int64 = 0
    public var convertStars: Int64 = 0
    public var upgradeStars: Int64 = 0
    public var resellMinStars: Int64 = 0
    public var resellStars: Int64 = 0
    public var resellTon: Int64 = 0
    public var isLimited: Bool = false
    public var isSoldOut: Bool = false
    public var isBirthday: Bool = false
    public var requiresPremium: Bool = false
    public var isAuction: Bool = false
    public var availabilityRemains: Int32 = 0
    public var availabilityTotal: Int32 = 0
    public var availabilityResale: Int64 = 0
    public var perUserTotal: Int32 = 0
    public var perUserRemains: Int32 = 0
    public var lockedUntilDate: Int32 = 0
    public var auctionSlug: String = ""
    public var auctionGiftsPerRound: Int32 = 0
    public var auctionStartDate: Int32 = 0
    public var upgradeVariantsCount: Int32 = 0
    public var title: String = ""
    public var slug: String = ""
    public var num: Int32 = 0
    public var ownerId: Int64 = 0
    public var ownerName: String = ""
    public var ownerAddress: String = ""
    public var availabilityIssued: Int32 = 0
    public var availabilityUniqueTotal: Int32 = 0
    public var valueAmount: Int64 = 0
    public var valueCurrency: String = ""
    public var valueUsdAmount: Int64 = 0
    public var collectibleColorId: Int64 = 0
    public var peerColorAvailable: Bool = false
    public var documentId: Int64 = 0
    public var documentAccessHash: Int64 = 0
    public var documentFileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var documentDcId: Int32 = 0
    public var documentMimeType: String = ""
    public var documentSize: Int64 = 0
    public var modelName: String = ""
    public var backdropName: String = ""
    public var patternName: String = ""
    public var backdropId: Int32 = 0
    public var centerColor: Int32 = 0
    public var edgeColor: Int32 = 0
    public var patternColor: Int32 = 0
    public var textColor: Int32 = 0
}

/**
 * StarGift 目录 ViewModel（payments.getStarGifts 响应）
 */
public class StarGiftsCatalogViewModel {
    public var gifts: ArrayList<StarGiftViewModel> = ArrayList<StarGiftViewModel>()
    public var notModified: Bool = false
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * 已保存的礼物 ViewModel（savedStarGift，对应 iOS ProfileGiftsContext.State.StarGift）
 */
public class SavedStarGiftViewModel {
    public var isNameHidden: Bool = false
    public var isUnsaved: Bool = false
    public var isRefunded: Bool = false
    public var canUpgrade: Bool = false
    public var isPinnedToTop: Bool = false
    public var fromPeerId: Int64 = 0
    public var date: Int32 = 0
    public var gift: StarGiftViewModel = StarGiftViewModel()
    public var msgId: Int32 = 0
    public var savedId: Int64 = 0
    public var convertStars: Int64 = 0
    public var upgradeStars: Int64 = 0
    public var transferStars: Int64 = 0
    public var canExportAt: Int32 = 0
    public var canTransferAt: Int32 = 0
    public var canResellAt: Int32 = 0
}

/**
 * 已保存礼物列表 ViewModel（分页）
 */
public class SavedStarGiftsViewModel {
    public var count: Int32 = 0
    public var gifts: ArrayList<SavedStarGiftViewModel> = ArrayList<SavedStarGiftViewModel>()
    public var nextOffset: String = ""
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * 操作结果 ViewModel（Bool 返回型操作）
 */
public class StarGiftBoolResultViewModel {
    public var success: Bool = false
    public var result: Bool = false
    public var errorMessage: String = ""
}

/**
 * 操作结果 ViewModel（Updates 返回型操作）
 */
public class StarGiftActionResultViewModel {
    public var success: Bool = false
    public var errorMessage: String = ""
}

/**
 * 提现 URL ViewModel
 */
public class StarGiftWithdrawalViewModel {
    public var url: String = ""
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * 二次销售市场 ViewModel
 */
public class ResaleStarGiftsViewModel {
    public var count: Int32 = 0
    public var gifts: ArrayList<StarGiftViewModel> = ArrayList<StarGiftViewModel>()
    public var nextOffset: String = ""
    public var attributes: ArrayList<StarGiftAttributeViewModel> = ArrayList<StarGiftAttributeViewModel>()
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

// ==================== P2-155g: StarGiftAttribute ViewModel 类型 ====================

/**
 * 单条 StarGiftAttribute 的 ViewModel 表示
 * 对应 iOS StarGiftAttribute (Api26.swift:1493-1735)
 * kind: "backdrop" | "model" | "pattern" | "originalDetails"
 */
public class StarGiftAttributeViewModel {
    public var kind: String = ""
    public var name: String = ""
    public var rarityPermille: Int32 = 0
    public var centerColor: Int32 = 0
    public var edgeColor: Int32 = 0
    public var patternColor: Int32 = 0
    public var textColor: Int32 = 0
    public var backdropId: Int32 = 0
    public var documentId: Int64 = 0
    public var count: Int32 = 0
}

/**
 * StarGiftUpgradePrice ViewModel（单条升级价格快照）
 * 对应 iOS StarGiftUpgradePrice (Api27.swift:883-930)
 */
public class StarGiftUpgradePriceViewModel {
    public var date: Int32 = 0
    public var upgradeStars: Int64 = 0
}

/**
 * StarGiftUpgradePreview ViewModel（升级预览完整结果）
 * 对应 iOS payments.StarGiftUpgradePreview (Api39.swift:472-543)
 */
public class StarGiftUpgradePreviewViewModel {
    public var sampleAttributes: ArrayList<StarGiftAttributeViewModel> = ArrayList<StarGiftAttributeViewModel>()
    public var prices: ArrayList<StarGiftUpgradePriceViewModel> = ArrayList<StarGiftUpgradePriceViewModel>()
    public var nextPrices: ArrayList<StarGiftUpgradePriceViewModel> = ArrayList<StarGiftUpgradePriceViewModel>()
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

func starGiftAttributeEntryToViewModel(entry: StarGiftAttributeEntry): StarGiftAttributeViewModel {
    let vm = StarGiftAttributeViewModel()
    vm.kind = entry.kind
    vm.name = entry.name
    vm.rarityPermille = entry.rarityPermille
    vm.centerColor = entry.centerColor
    vm.edgeColor = entry.edgeColor
    vm.patternColor = entry.patternColor
    vm.textColor = entry.textColor
    vm.backdropId = entry.backdropId
    vm.documentId = entry.documentId
    vm.count = entry.count
    return vm
}

func starGiftUpgradePriceEntryToViewModel(entry: StarGiftUpgradePriceEntry): StarGiftUpgradePriceViewModel {
    let vm = StarGiftUpgradePriceViewModel()
    vm.date = entry.date
    vm.upgradeStars = entry.upgradeStars
    return vm
}

func starGiftEntryToViewModel(entry: StarGiftEntry): StarGiftViewModel {
    let vm = StarGiftViewModel()
    vm.isUnique = entry.isUnique
    vm.id = entry.id
    vm.stars = entry.stars
    vm.convertStars = entry.convertStars
    vm.upgradeStars = entry.upgradeStars
    vm.resellMinStars = entry.resellMinStars
    vm.resellStars = entry.resellStars
    vm.resellTon = entry.resellTon
    vm.isLimited = entry.isLimited
    vm.isSoldOut = entry.isSoldOut
    vm.isBirthday = entry.isBirthday
    vm.requiresPremium = entry.requiresPremium
    vm.isAuction = entry.isAuction
    vm.availabilityRemains = entry.availabilityRemains
    vm.availabilityTotal = entry.availabilityTotal
    vm.availabilityResale = entry.availabilityResale
    vm.perUserTotal = entry.perUserTotal
    vm.perUserRemains = entry.perUserRemains
    vm.lockedUntilDate = entry.lockedUntilDate
    vm.auctionSlug = entry.auctionSlug
    vm.auctionGiftsPerRound = entry.auctionGiftsPerRound
    vm.auctionStartDate = entry.auctionStartDate
    vm.upgradeVariantsCount = entry.upgradeVariantsCount
    vm.title = entry.title
    vm.slug = entry.slug
    vm.num = entry.num
    vm.ownerId = entry.ownerId
    vm.ownerName = entry.ownerName
    vm.ownerAddress = entry.ownerAddress
    vm.availabilityIssued = entry.availabilityIssued
    vm.availabilityUniqueTotal = entry.availabilityUniqueTotal
    vm.valueAmount = entry.valueAmount
    vm.valueCurrency = entry.valueCurrency
    vm.valueUsdAmount = entry.valueUsdAmount
    vm.collectibleColorId = entry.collectibleColorId
    vm.peerColorAvailable = entry.peerColorAvailable
    vm.documentId = entry.documentId
    vm.documentAccessHash = entry.documentAccessHash
    vm.documentFileReference = entry.documentFileReference
    vm.documentDcId = entry.documentDcId
    vm.documentMimeType = entry.documentMimeType
    vm.documentSize = entry.documentSize
    vm.modelName = entry.modelName
    vm.backdropName = entry.backdropName
    vm.patternName = entry.patternName
    vm.backdropId = entry.backdropId
    vm.centerColor = entry.centerColor
    vm.edgeColor = entry.edgeColor
    vm.patternColor = entry.patternColor
    vm.textColor = entry.textColor
    return vm
}

func savedStarGiftEntryToViewModel(entry: SavedStarGiftEntry): SavedStarGiftViewModel {
    let vm = SavedStarGiftViewModel()
    vm.isNameHidden = entry.isNameHidden
    vm.isUnsaved = entry.isUnsaved
    vm.isRefunded = entry.isRefunded
    vm.canUpgrade = entry.canUpgrade
    vm.isPinnedToTop = entry.isPinnedToTop
    vm.fromPeerId = entry.fromPeerId
    vm.date = entry.date
    vm.gift = starGiftEntryToViewModel(entry.gift)
    vm.msgId = entry.msgId
    vm.savedId = entry.savedId
    vm.convertStars = entry.convertStars
    vm.upgradeStars = entry.upgradeStars
    vm.transferStars = entry.transferStars
    vm.canExportAt = entry.canExportAt
    vm.canTransferAt = entry.canTransferAt
    vm.canResellAt = entry.canResellAt
    return vm
}

// ==================== P2-155c: Gift Codes + Giveaways ViewModel 类型 ====================

/**
 * 礼品码校验信息 ViewModel（对应 iOS PremiumGiftCodeInfo）
 */
public class CheckedGiftCodeViewModel {
    public var viaGiveaway: Bool = false
    public var fromPeerId: Int64 = 0
    public var fromPeerType: String = ""
    public var giveawayMsgId: Int32 = 0
    public var toPeerId: Int64 = 0
    public var date: Int32 = 0
    public var months: Int32 = 0
    public var usedDate: Int32 = 0
    public var isUsed: Bool = false
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * 礼品码兑换结果 ViewModel
 */
public class GiftCodeApplyResultViewModel {
    public var success: Bool = false
    public var errorMessage: String = ""
}

/**
 * 单条 Premium 礼品码套餐选项 ViewModel（对应 iOS PremiumGiftCodeOption）
 */
public class PremiumGiftCodeOptionViewModel {
    public var users: Int32 = 0
    public var months: Int32 = 0
    public var storeProduct: String = ""
    public var storeQuantity: Int32 = 1
    public var currency: String = ""
    public var amount: Int64 = 0
    public var formattedAmount: String = ""
}

/**
 * Premium 礼品码套餐列表 ViewModel
 */
public class PremiumGiftCodeOptionsViewModel {
    public var options: ArrayList<PremiumGiftCodeOptionViewModel> = ArrayList<PremiumGiftCodeOptionViewModel>()
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * 抽奖信息 ViewModel（对应 iOS PremiumGiveawayInfo）
 * infoType: "ongoing" | "results"
 * ongoingStatus: "notQualified" | "notAllowed_tooEarly" | "notAllowed_admin" | "notAllowed_country" | "participating" | "almostOver"
 * resultStatus: "notWon" | "wonPremium" | "wonStars" | "refunded"
 */
public class GiveawayInfoViewModel {
    public var infoType: String = ""
    public var startDate: Int32 = 0
    public var ongoingStatus: String = ""
    public var joinedTooEarlyDate: Int32 = 0
    public var adminDisallowedChatId: Int64 = 0
    public var disallowedCountry: String = ""
    public var resultStatus: String = ""
    public var giftCodeSlug: String = ""
    public var starsPrize: Int64 = 0
    public var finishDate: Int32 = 0
    public var winnersCount: Int32 = 0
    public var activatedCount: Int32 = 0
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * 抽奖启动结果 ViewModel
 */
public class GiveawayLaunchResultViewModel {
    public var success: Bool = false
    public var errorMessage: String = ""
}

func premiumGiftCodeOptionEntryToViewModel(entry: PremiumGiftCodeOptionEntry): PremiumGiftCodeOptionViewModel {
    let vm = PremiumGiftCodeOptionViewModel()
    vm.users = entry.users
    vm.months = entry.months
    vm.storeProduct = entry.storeProduct
    vm.storeQuantity = entry.storeQuantity
    vm.currency = entry.currency
    vm.amount = entry.amount
    vm.formattedAmount = formatCurrencyAmount(entry.currency, entry.amount)
    return vm
}

func starsSubscriptionEntryToViewModel(entry: StarsSubscriptionEntry): StarsSubscriptionViewModel {
    let vm = StarsSubscriptionViewModel()
    vm.id = entry.id
    vm.canceled = entry.canceled
    vm.canRefulfill = entry.canRefulfill
    vm.missingBalance = entry.missingBalance
    vm.botCanceled = entry.botCanceled
    vm.peerType = entry.peerType
    vm.peerId = entry.peerId
    vm.untilDate = entry.untilDate
    vm.pricingPeriod = entry.pricingPeriod
    vm.pricingAmount = entry.pricingAmount
    vm.chatInviteHash = entry.chatInviteHash
    vm.title = entry.title
    vm.invoiceSlug = entry.invoiceSlug
    return vm
}

// ==================== P2-155d: Stars Subscriptions + Revenue ViewModel 类型 ====================

/**
 * 单条 Stars 订阅 ViewModel（对应 iOS StarsSubscription）
 * 对应 starsSubscription#2e6eab1a
 */
public class StarsSubscriptionViewModel {
    public var id: String = ""
    public var canceled: Bool = false
    public var canRefulfill: Bool = false
    public var missingBalance: Bool = false
    public var botCanceled: Bool = false
    public var peerType: String = ""
    public var peerId: Int64 = 0
    public var untilDate: Int32 = 0
    public var pricingPeriod: Int32 = 0
    public var pricingAmount: Int64 = 0
    public var chatInviteHash: String = ""
    public var title: String = ""
    public var invoiceSlug: String = ""
}

/**
 * Stars 订阅列表 ViewModel（对应 iOS StarsSubscriptionsContext.State）
 */
public class StarsSubscriptionsViewModel {
    public var balanceStars: Int64 = 0
    public var balanceNanos: Int32 = 0
    public var subscriptions: ArrayList<StarsSubscriptionViewModel> = ArrayList<StarsSubscriptionViewModel>()
    public var nextOffset: String = ""
    public var subscriptionsMissingBalance: Int64 = 0
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * 订阅操作结果 ViewModel（changeStarsSubscription / fulfillStarsSubscription）
 */
public class StarsSubscriptionActionViewModel {
    public var success: Bool = false
    public var result: Bool = false
    public var errorMessage: String = ""
}

/**
 * Stars 收益统计 ViewModel（对应 iOS MonetizationBalanceItem / StarsRevenueStatus）
 */
public class StarsRevenueStatsViewModel {
    public var withdrawalEnabled: Bool = false
    public var currentBalanceStars: Int64 = 0
    public var currentBalanceNanos: Int32 = 0
    public var availableBalanceStars: Int64 = 0
    public var availableBalanceNanos: Int32 = 0
    public var overallRevenueStars: Int64 = 0
    public var overallRevenueNanos: Int32 = 0
    public var nextWithdrawalAt: Int32 = 0
    public var hasNextWithdrawalAt: Bool = false
    public var usdRate: Float64 = 0.0
    public var revenueGraphJson: String = ""
    public var revenueGraphToken: String = ""
    public var loaded: Bool = false
    public var errorMessage: String = ""
}

/**
 * Stars 收益提现 URL ViewModel
 */
public class StarsRevenueWithdrawalViewModel {
    public var url: String = ""
    public var loaded: Bool = false
    public var errorMessage: String = ""
}
