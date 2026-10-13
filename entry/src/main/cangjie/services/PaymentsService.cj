package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    getSourceLayerClient,
    SOURCE_LAYER_GATE,
    TLDeserializer,
    TLConstructors,
    PaymentsGetPaymentForm,
    PaymentsGetPremiumGiftStarsForm,
    PaymentsSendPremiumGiftStarsForm,
    PaymentsGetStarGiftForm,
    PaymentsSendStarGiftForm,
    PaymentsGetResaleStarGiftForm,
    PaymentsSendResaleStarGiftForm,
    PaymentsGetStarGiftTransferForm,
    PaymentsSendStarGiftTransferForm,
    TLObject,
    PaymentsClearSavedInfo,
    PaymentsValidateRequestedInfo,
    PaymentsSendPaymentForm,
    PaymentsGetPaymentReceipt,
    PaymentsGetBankCardData,
    BankCardDataResponse,
    PaymentFormResponse,
    ValidatedRequestedInfoResponse,
    PaymentResultResponse,
    PaymentReceiptResponse,
    parseValidatedRequestedInfo,
    parsePaymentResult,
    PaymentsGetStarsStatus,
    PaymentsGetStarsTransactions,
    PaymentsGetStarsTransactionsByID,
    PaymentsGetStarsTopupOptions,
    PaymentsGetStarsGiftOptions,
    InputStarsTransaction,
    InputPeerSelf,
    InputPeerUser,
    InputPeerChannel,
    StarsStatusResponse,
    StarsTopupOptionsResponse,
    StarsGiftOptionsResponse,
    parseStarsStatus,
    parseStarsTopupOptions,
    parseStarsGiftOptions,
    InputSavedStarGiftUser,
    InputSavedStarGiftChat,
    InputSavedStarGiftSlug,
    InputCheckPasswordSRP,
    PaymentsGetStarGifts,
    PaymentsSaveStarGift,
    PaymentsConvertStarGift,
    PaymentsUpgradeStarGift,
    PaymentsTransferStarGift,
    PaymentsGetStarGiftWithdrawalUrl,
    PaymentsUpdateStarGiftPrice,
    StarsAmount,
    PaymentsGetSavedStarGifts,
    PaymentsGetResaleStarGifts,
    PaymentsGetStarGiftUpgradePreview,
    StarGiftAttributeIdEntry,
    StarGiftAttributeEntry,
    StarGiftUpgradePriceEntry,
    StarGiftUpgradePreviewResponse,
    StarGiftsResponse,
    SavedStarGiftsResponse,
    StarGiftWithdrawalUrlResponse,
    ResaleStarGiftsResponse,
    StarGiftUpdatesResponse,
    StarGiftBoolResponse,
    parseStarGifts,
    parseSavedStarGifts,
    parseStarGiftWithdrawalUrl,
    parseResaleStarGifts,
    parseStarGiftUpgradePreview,
    parseStarGiftUpdates,
    parseStarGiftBool,
    PaymentsCheckGiftCode,
    PaymentsApplyGiftCode,
    PaymentsGetPremiumGiftCodeOptions,
    PaymentsGetGiveawayInfo,
    PaymentsLaunchPrepaidGiveaway,
    InputStorePaymentPremiumGiveaway,
    InputStorePaymentStarsGiveaway,
    CheckedGiftCodeResponse,
    GiveawayInfoResponse,
    PremiumGiftCodeOptionsResponse,
    parseCheckedGiftCode,
    parseGiveawayInfo,
    parsePremiumGiftCodeOptions,
    PaymentsGetStarsSubscriptions,
    PaymentsChangeStarsSubscription,
    PaymentsFulfillStarsSubscription,
    PaymentsGetStarsRevenueStats,
    PaymentsGetStarsRevenueWithdrawalUrl,
    StarsSubscriptionsResponse,
    StarsRevenueStatsResponse,
    StarsRevenueWithdrawalUrlResponse,
    TLBoolResponse,
    parseStarsSubscriptions,
    parseStarsRevenueStats,
    parseStarsRevenueWithdrawalUrl,
    parseTLBool
}
import std.collection.ArrayList

/**
 * PaymentsService — 支付引擎层（telegram_engine_payments TEPAY-API-1）
 *
 * 对应 iOS TelegramEngine.Payments（TelegramEnginePayments.swift）
 * 封装以下 TL 方法调用，直接通过 MTProtoClient 与 Telegram 服务器通信：
 *
 *   payments.getPaymentForm     → 获取支付表单（发票/Provider/银行卡表单）
 *   payments.validateRequestedInfo → 验证用户填写的联系/地址信息
 *   payments.sendPaymentForm    → 发送支付（完成付款）
 *   payments.getPaymentReceipt  → 获取支付收据
 *   payments.getBankCardData    → 获取银行卡信息
 *
 * 调用链：PaymentsService → getMTProtoClient().sendRequest(TLMethod.toBytes())
 *          → MTProtoClient → MTProtoTransport → Telegram Server
 */

private var _paymentsServiceInstance: Option<PaymentsService> = None

public func getPaymentsService(): PaymentsService {
    match (_paymentsServiceInstance) {
        case Some(s) => s
        case None =>
            let s = PaymentsService()
            _paymentsServiceInstance = Some(s)
            s
    }
}

public class PaymentsService {

    private func onSourceLayer(request: Array<Byte>): Array<Byte> {
        synchronized(SOURCE_LAYER_GATE) {
            var data = Array<Byte>()
            try {
                let client = getSourceLayerClient()
                client.requireInitOnNextRequest()
                data = client.sendRequest(request)
            } finally {
                try {
                    getMTProtoClient().reassertLayer()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[PaymentsService] source layer re-assert failed: ${e}")
                }
            }
            return data
        }
    }

    /** Source-equivalent Premium gift payment path for the XTR option. */
    public func sendPremiumGiftWithStars(user: TLObject, months: Int32, message: String): PaymentResultResponse {
        let formReq = PaymentsGetPremiumGiftStarsForm()
        formReq.user = user
        formReq.months = months
        formReq.message = message
        try {
            let form = PaymentFormResponse.deserialize(this.onSourceLayer(formReq.toBytes()))
            if (!form.success) {
                let failed = PaymentResultResponse()
                failed.errorCode = form.errorCode
                failed.errorMessage = form.errorMessage
                return failed
            }
            let sendReq = PaymentsSendPremiumGiftStarsForm()
            sendReq.formId = form.formId
            sendReq.user = user
            sendReq.months = months
            sendReq.message = message
            return parsePaymentResult(this.onSourceLayer(sendReq.toBytes()))
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] sendPremiumGiftWithStars exception")
            let failed = PaymentResultResponse()
            failed.errorMessage = e.toString()
            return failed
        }
    }

    public func sendStarGift(peer: TLObject, giftId: Int64, message: String, hideName: Bool, includeUpgrade: Bool): PaymentResultResponse {
        let formReq = PaymentsGetStarGiftForm()
        formReq.peer = peer
        formReq.giftId = giftId
        formReq.message = message
        formReq.hideName = hideName
        formReq.includeUpgrade = includeUpgrade
        try {
            let form = PaymentFormResponse.deserialize(this.onSourceLayer(formReq.toBytes()))
            if (!form.success) {
                let failed = PaymentResultResponse()
                failed.errorCode = form.errorCode
                failed.errorMessage = form.errorMessage
                return failed
            }
            let sendReq = PaymentsSendStarGiftForm()
            sendReq.formId = form.formId
            sendReq.peer = peer
            sendReq.giftId = giftId
            sendReq.message = message
            sendReq.hideName = hideName
            sendReq.includeUpgrade = includeUpgrade
            return parsePaymentResult(this.onSourceLayer(sendReq.toBytes()))
        } catch (e: Exception) {
            let failed = PaymentResultResponse()
            failed.errorMessage = e.toString()
            return failed
        }
    }

    public func buyResaleStarGift(peer: TLObject, slug: String, ton: Bool, acceptedPrice: Int64): PaymentResultResponse {
        let formReq = PaymentsGetResaleStarGiftForm()
        formReq.peer = peer
        formReq.slug = slug
        formReq.ton = ton
        try {
            let form = PaymentFormResponse.deserialize(this.onSourceLayer(formReq.toBytes()))
            if (!form.success) {
                let failed = PaymentResultResponse()
                failed.errorCode = form.errorCode
                failed.errorMessage = form.errorMessage
                return failed
            }
            if (form.prices.size > 0 && form.prices[0].amount > acceptedPrice) {
                let changed = PaymentResultResponse()
                changed.priceChanged = true
                changed.updatedPrice = form.prices[0].amount
                changed.updatedCurrency = form.currency
                return changed
            }
            let sendReq = PaymentsSendResaleStarGiftForm()
            sendReq.formId = form.formId
            sendReq.peer = peer
            sendReq.slug = slug
            sendReq.ton = ton
            return parsePaymentResult(this.onSourceLayer(sendReq.toBytes()))
        } catch (e: Exception) {
            let failed = PaymentResultResponse()
            failed.errorMessage = e.toString()
            return failed
        }
    }

    /**
     * 获取支付表单（payments.getPaymentForm）
     *
     * 对应 iOS: TelegramEngine.Payments.fetchBotPaymentForm
     * 通过 TL 调用获取 invoice / provider / 已保存 credentials 等完整表单数据。
     *
     * @param peerId    发送 invoice 消息的 peer userId（InputPeerUser）
     * @param accessHash peer 的 access_hash
     * @param msgId     包含 invoice 的消息 ID
     * @return PaymentFormResponse（解析后的支付表单数据）
     */
    public func getPaymentForm(peerId: Int64, accessHash: Int64, msgId: Int32): PaymentFormResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getPaymentForm peer=${peerId} msg=${msgId}")
        let req = PaymentsGetPaymentForm()
        req.invoiceType = "message"
        req.peerId = peerId
        req.peerAccessHash = accessHash
        req.msgId = msgId
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return PaymentFormResponse.deserialize(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getPaymentForm exception")
            let r = PaymentFormResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 通过 slug 获取支付表单（inputInvoiceSlug）
     *
     * 对应 iOS BotPaymentInvoiceSource.slug
     * @param slug invoice 的 slug 字符串
     * @return PaymentFormResponse
     */
    public func getPaymentFormBySlug(slug: String): PaymentFormResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getPaymentFormBySlug slug=${slug}")
        let req = PaymentsGetPaymentForm()
        req.invoiceType = "slug"
        req.slug = slug
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return PaymentFormResponse.deserialize(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getPaymentFormBySlug exception")
            let r = PaymentFormResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 验证支付信息（payments.validateRequestedInfo）
     *
     * 对应 iOS: TelegramEngine.Payments.validateBotPaymentForm
     * 提交用户填写的姓名/手机/邮件/地址到服务端验证，并获取运费选项。
     *
     * @param peerId      peer userId
     * @param accessHash  peer access_hash
     * @param msgId       invoice 消息 ID
     * @param save        是否保存此信息以备下次使用
     * @param name        收货人姓名（可为空字符串）
     * @param phone       电话（可为空字符串）
     * @param email       邮件（可为空字符串）
     * @param hasAddress  是否填写了地址
     * @param streetLine1 地址第 1 行
     * @param streetLine2 地址第 2 行
     * @param city        城市
     * @param state       省/州
     * @param countryIso2 国家代码（ISO 3166-1 alpha-2）
     * @param postCode    邮编
     * @return ValidatedRequestedInfoResponse
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
    ): ValidatedRequestedInfoResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] validateRequestedInfo peer=${peerId} msg=${msgId}")
        let req = PaymentsValidateRequestedInfo()
        req.invoiceType = "message"
        req.peerId = peerId
        req.peerAccessHash = accessHash
        req.msgId = msgId
        req.save = save
        req.name = name
        req.phone = phone
        req.email = email
        req.hasAddress = hasAddress
        req.streetLine1 = streetLine1
        req.streetLine2 = streetLine2
        req.city = city
        req.state = state
        req.countryIso2 = countryIso2
        req.postCode = postCode
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseValidatedRequestedInfo(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] validateRequestedInfo exception")
            let r = ValidatedRequestedInfoResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 发送支付表单（payments.sendPaymentForm）
     *
     * 对应 iOS: TelegramEngine.Payments.sendBotPaymentForm
     * 携带 credentials (JSON 或已保存) 完成实际付款动作。
     *
     * @param formId            支付表单 ID（来自 getPaymentForm 响应）
     * @param peerId            peer userId
     * @param accessHash        peer access_hash
     * @param msgId             invoice 消息 ID
     * @param requestedInfoId   validateRequestedInfo 返回的 id（可为空字符串）
     * @param shippingOptionId  选择的运费选项 ID（可为空字符串）
     * @param credentialsJson   支付凭证 JSON 字符串（来自支付 Provider SDK）
     * @param saveCredentials   是否保存凭证到服务端
     * @return PaymentResultResponse（成功/需外部验证/错误）
     */
    public func sendPaymentForm(
        formId: Int64,
        peerId: Int64,
        accessHash: Int64,
        msgId: Int32,
        requestedInfoId: String,
        shippingOptionId: String,
        credentialsJson: String,
        saveCredentials: Bool
    ): PaymentResultResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] sendPaymentForm formId=${formId} peer=${peerId} msg=${msgId}")
        let req = PaymentsSendPaymentForm()
        req.formId = formId
        req.invoiceType = "message"
        req.peerId = peerId
        req.peerAccessHash = accessHash
        req.msgId = msgId
        req.requestedInfoId = requestedInfoId
        req.shippingOptionId = shippingOptionId
        req.credentialsType = "data"
        req.credentialsData = credentialsJson
        req.credentialsSaveOnServer = saveCredentials
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parsePaymentResult(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] sendPaymentForm exception")
            let r = PaymentResultResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 使用已保存凭证发送支付（payments.sendPaymentForm with saved credentials）
     *
     * 对应 iOS BotPaymentCredentials.saved
     * @param formId           支付表单 ID
     * @param peerId           peer userId
     * @param accessHash       peer access_hash
     * @param msgId            invoice 消息 ID
     * @param requestedInfoId  校验信息 ID（可为空字符串）
     * @param shippingOptionId 运费选项 ID（可为空字符串）
     * @param savedId          已保存凭证 ID
     * @param tmpPassword      临时密码（2FA 验证后得到）
     * @return PaymentResultResponse
     */
    public func sendPaymentFormWithSavedCredentials(
        formId: Int64,
        peerId: Int64,
        accessHash: Int64,
        msgId: Int32,
        requestedInfoId: String,
        shippingOptionId: String,
        savedId: String,
        tmpPassword: Array<Byte>
    ): PaymentResultResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] sendPaymentFormSaved formId=${formId} peer=${peerId}")
        let req = PaymentsSendPaymentForm()
        req.formId = formId
        req.invoiceType = "message"
        req.peerId = peerId
        req.peerAccessHash = accessHash
        req.msgId = msgId
        req.requestedInfoId = requestedInfoId
        req.shippingOptionId = shippingOptionId
        req.credentialsType = "saved"
        req.savedCredentialsId = savedId
        req.savedCredentialsTmpPassword = tmpPassword
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parsePaymentResult(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] sendPaymentFormSaved exception")
            let r = PaymentResultResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 获取支付收据（payments.getPaymentReceipt）
     *
     * 对应 iOS: TelegramEngine.Payments.requestBotPaymentReceipt
     * @param peerId     peer userId（发送收据消息的 peer）
     * @param accessHash peer access_hash
     * @param msgId      收据消息 ID
     * @return PaymentReceiptResponse
     */
    public func getPaymentReceipt(peerId: Int64, accessHash: Int64, msgId: Int32): PaymentReceiptResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getPaymentReceipt peer=${peerId} msg=${msgId}")
        let req = PaymentsGetPaymentReceipt()
        req.peerId = peerId
        req.peerAccessHash = accessHash
        req.msgId = msgId
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return PaymentReceiptResponse.deserialize(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getPaymentReceipt exception")
            let r = PaymentReceiptResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 获取银行卡信息（payments.getBankCardData）
     *
     * 对应 iOS: TelegramEngine.Payments.getBankCardInfo
     * 根据银行卡号查询银行名称及相关网页链接（支持卡 BIN 查询）。
     *
     * @param cardNumber 银行卡号（或卡 BIN 前缀）
     * @return BankCardDataResponse（银行名称 + URL 列表）
     */
    public func getBankCardData(cardNumber: String): BankCardDataResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getBankCardData")
        let req = PaymentsGetBankCardData()
        req.number = cardNumber
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return BankCardDataResponse.deserialize(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getBankCardData exception")
            let r = BankCardDataResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    // ==================== P2-155: Stars 生态读核心方法 ====================

    /**
     * 获取 Stars 余额和状态（payments.getStarsStatus）
     *
     * 对应 iOS: _internal_requestStarsState → Api.functions.payments.getStarsStatus (Stars.swift:464)
     * 返回 payments.starsStatus#6c9ce8ed: balance(StarsAmount) + history(Vector<StarsTransaction>)
     * + subscriptions + next_offset + chats + users
     *
     * 注意: balance 字段是 starsAmount#bbb6b4a3 {amount:long nanos:int}，非裸 long
     * (TL schema telegram_api.tl:1944 + 1882 验证)
     *
     * @return StarsStatusResponse（balanceAmount/balanceNanos + transactions + nextOffset）
     */
    public func getStarsStatus(): StarsStatusResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsStatus")
        let req = PaymentsGetStarsStatus()
        req.peer = InputPeerSelf()
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarsStatus(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsStatus exception")
            let r = StarsStatusResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    public func getTonStatus(): StarsStatusResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getTonStatus")
        let req = PaymentsGetStarsStatus()
        req.flags = 1
        req.peer = InputPeerSelf()
        try {
            return parseStarsStatus(this.onSourceLayer(req.toBytes()))
        } catch (e: Exception) {
            let r = StarsStatusResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 获取 Stars 交易历史（payments.getStarsTransactions）
     *
     * 对应 iOS: _internal_requestStarsState → Api.functions.payments.getStarsTransactions (Stars.swift:458)
     * 支持分页 (offset/limit) 和方向过滤 (inbound/outbound)。
     * 响应为 payments.starsStatus#6c9ce8ed，其中 history 字段包含交易列表。
     *
     * @param offset     分页 offset 字符串（首次调用传空字符串）
     * @param limit      每页条目数
     * @param inbound    仅返回收入
     * @param outbound   仅返回支出
     * @return StarsStatusResponse（transactions + nextOffset）
     */
    public func getStarsTransactions(
        offset: String,
        limit: Int32,
        inbound: Bool,
        outbound: Bool
    ): StarsStatusResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsTransactions offset='${offset}' limit=${limit}")
        let req = PaymentsGetStarsTransactions()
        req.peer = InputPeerSelf()
        req.offset = offset
        req.limit = limit
        req.inbound = inbound
        req.outbound = outbound
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarsStatus(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsTransactions exception")
            let r = StarsStatusResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 按 ID 查询 Stars 交易（payments.getStarsTransactionsByID）
     *
     * 对应 iOS: getStarsTransactionsByID (TelegramEnginePayments.swift)
     * 响应为 payments.starsStatus，history 只含请求的交易条目。
     *
     * @param transactionIds 交易 ID 字符串列表
     * @return StarsStatusResponse
     */
    public func getStarsTransactionsByID(transactionIds: ArrayList<String>): StarsStatusResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsTransactionsByID count=${transactionIds.size}")
        let req = PaymentsGetStarsTransactionsByID()
        req.peer = InputPeerSelf()
        for (txId in transactionIds) {
            let inp = InputStarsTransaction()
            inp.id = txId
            req.ids.add(inp)
        }
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarsStatus(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsTransactionsByID exception")
            let r = StarsStatusResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 获取 Stars 充值选项（payments.getStarsTopupOptions）
     *
     * 对应 iOS: _internal_starsTopUpOptions → Api.functions.payments.getStarsTopupOptions (Stars.swift:62)
     * 返回 Vector<StarsTopupOption>，每条包含 stars 数量 + 货币/金额 (供 IAP 购买)。
     *
     * @return StarsTopupOptionsResponse（options 列表）
     */
    public func getStarsTopupOptions(): StarsTopupOptionsResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsTopupOptions")
        let req = PaymentsGetStarsTopupOptions()
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarsTopupOptions(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsTopupOptions exception")
            let r = StarsTopupOptionsResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 获取 Stars 赠礼选项（payments.getStarsGiftOptions）
     *
     * 对应 iOS: _internal_starsGiftOptions → Api.functions.payments.getStarsGiftOptions (Stars.swift:137)
     * 返回 Vector<StarsGiftOption>，每条包含 stars 数量 + 货币/金额。
     * user_id 为可选参数；传 None 获取通用选项。
     *
     * @return StarsGiftOptionsResponse（options 列表）
     */
    public func getStarsGiftOptions(): StarsGiftOptionsResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsGiftOptions")
        let req = PaymentsGetStarsGiftOptions()
        req.hasUserId = false
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarsGiftOptions(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsGiftOptions exception")
            let r = StarsGiftOptionsResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    // ==================== P2-155b: Star Gifts 操作方法 ====================

    /**
     * 获取 Star Gifts 商品目录（payments.getStarGifts）
     *
     * 对应 iOS: getStarGifts in StarGifts.swift
     * 返回 payments.starGifts#901689ea hash:int gifts:Vector<StarGift>
     *   或 payments.starGiftsNotModified (hash 未变化时)
     *
     * @param hash 上次响应的 hash，0 表示首次加载
     * @return StarGiftsResponse（gifts 列表 + notModified 标志）
     */
    public func getStarGifts(hash: Int32): StarGiftsResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getStarGifts hash=${hash}")
        let req = PaymentsGetStarGifts()
        req.hash = hash
        try {
            let responseData = this.onSourceLayer(req.toBytes())
            return parseStarGifts(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getStarGifts exception")
            let r = StarGiftsResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 将收到的礼物转换为 Stars（payments.convertStarGift）
     *
     * 对应 iOS: _internal_convertStarGift (StarGifts.swift:1398)
     * 礼物的 convert_stars 字段表示转换可获得的 Stars 数量
     * 成功后服务端更新余额，本地需重新拉取 Stars 状态
     *
     * @param msgId 礼物消息 ID（inputSavedStarGiftUser 变体）
     * @return StarGiftBoolResponse（result=true 表示转换成功）
     */
    public func convertStarGiftByMsgId(msgId: Int32): StarGiftBoolResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] convertStarGiftByMsgId msgId=${msgId}")
        let req = PaymentsConvertStarGift()
        let ref = InputSavedStarGiftUser()
        ref.msgId = msgId
        req.stargift = ref
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarGiftBool(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] convertStarGiftByMsgId exception")
            let r = StarGiftBoolResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 将收到的礼物转换为 Stars（slug 变体，对应 unique gifts）
     *
     * @param slug Unique StarGift 的 slug 字符串
     * @return StarGiftBoolResponse
     */
    public func convertStarGiftBySlug(slug: String): StarGiftBoolResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] convertStarGiftBySlug slug=${slug}")
        let req = PaymentsConvertStarGift()
        let ref = InputSavedStarGiftSlug()
        ref.slug = slug
        req.stargift = ref
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarGiftBool(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] convertStarGiftBySlug exception")
            let r = StarGiftBoolResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 将礼物添加或移除到 Profile（payments.saveStarGift）
     *
     * 对应 iOS: _internal_updateStarGiftAddedToProfile (StarGifts.swift:1431)
     * unsave=false → 添加到 Profile（显示在个人页面礼物栏）
     * unsave=true  → 从 Profile 移除（仍可在 saved gifts 列表查看）
     *
     * @param msgId  礼物消息 ID
     * @param unsave true=移除, false=添加
     * @return StarGiftBoolResponse
     */
    public func saveStarGift(msgId: Int32, unsave: Bool): StarGiftBoolResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] saveStarGift msgId=${msgId} unsave=${unsave}")
        let req = PaymentsSaveStarGift()
        req.unsave = unsave
        let ref = InputSavedStarGiftUser()
        ref.msgId = msgId
        req.stargift = ref
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarGiftBool(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] saveStarGift exception")
            let r = StarGiftBoolResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 升级礼物为 Unique Gift（payments.upgradeStarGift）
     *
     * 对应 iOS: _internal_upgradeStarGift formId=nil path (StarGifts.swift:1657)
     * 升级后礼物成为稀有的 starGiftUnique，包含独特属性
     * 响应: Updates（含 updateNewMessage with messageActionStarGiftUnique）
     *
     * @param msgId              礼物消息 ID
     * @param keepOriginalDetails true=保留原始发送人信息（需付 upgrade_stars）
     * @return StarGiftUpdatesResponse
     */
    public func upgradeStarGift(msgId: Int32, keepOriginalDetails: Bool): StarGiftUpdatesResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] upgradeStarGift msgId=${msgId} keepOriginal=${keepOriginalDetails}")
        let req = PaymentsUpgradeStarGift()
        req.keepOriginalDetails = keepOriginalDetails
        let ref = InputSavedStarGiftUser()
        ref.msgId = msgId
        req.stargift = ref
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarGiftUpdates(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] upgradeStarGift exception")
            let r = StarGiftUpdatesResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 转赠礼物给其他用户（payments.transferStarGift，prepaid 路径）
     *
     * 对应 iOS: _internal_transferStarGift prepaid=true (StarGifts.swift:1603)
     * Prepaid 模式: 直接调用 transferStarGift RPC（已经支付转赠费用时）
     * 非 prepaid 模式需先通过 inputInvoiceStarGiftTransfer 走 sendPaymentForm 路径
     * 响应: Updates（含转赠后的新消息 action）
     *
     * @param msgId      礼物消息 ID（源 savedStarGift 的 msg_id）
     * @param toUserId   目标用户 userId
     * @param toAccessHash 目标用户 access_hash
     * @return StarGiftUpdatesResponse
     */
    public func transferStarGift(msgId: Int32, toUserId: Int64, toAccessHash: Int64): StarGiftUpdatesResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] transferStarGift msgId=${msgId} toUser=${toUserId}")
        let req = PaymentsTransferStarGift()
        let ref = InputSavedStarGiftUser()
        ref.msgId = msgId
        req.stargift = ref
        let toPeer = InputPeerUser()
        toPeer.userId = toUserId
        toPeer.accessHash = toAccessHash
        req.toId = toPeer
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarGiftUpdates(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] transferStarGift exception")
            let r = StarGiftUpdatesResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    public func transferStarGiftWithStars(msgId: Int32, toUserId: Int64, toAccessHash: Int64): PaymentResultResponse {
        let peer = InputPeerUser()
        peer.userId = toUserId
        peer.accessHash = toAccessHash
        let formReq = PaymentsGetStarGiftTransferForm()
        formReq.msgId = msgId
        formReq.peer = peer
        try {
            let form = PaymentFormResponse.deserialize(this.onSourceLayer(formReq.toBytes()))
            if (!form.success) {
                let failed = PaymentResultResponse()
                failed.errorCode = form.errorCode
                failed.errorMessage = form.errorMessage
                return failed
            }
            let sendReq = PaymentsSendStarGiftTransferForm()
            sendReq.formId = form.formId
            sendReq.msgId = msgId
            sendReq.peer = peer
            return parsePaymentResult(this.onSourceLayer(sendReq.toBytes()))
        } catch (e: Exception) {
            let failed = PaymentResultResponse()
            failed.errorMessage = e.toString()
            return failed
        }
    }

    /**
     * 获取 Unique Gift 提现 URL（payments.getStarGiftWithdrawalUrl）
     *
     * 对应 iOS: getStarGiftWithdrawalUrl (TelegramEnginePayments.swift)
     * 需要 2FA SRP 密码验证；返回 Fragment 提现页面 URL
     * 响应: payments.starGiftWithdrawalUrl#84aa3a9c url:string
     *
     * @param slug      Unique Gift slug（inputSavedStarGiftSlug 变体）
     * @param srpId     SRP 会话 ID（来自 account.getPassword 响应）
     * @param srpA      SRP 参数 A
     * @param srpM1     SRP 验证值 M1
     * @return StarGiftWithdrawalUrlResponse（url 字段包含提现 URL）
     */
    public func getStarGiftWithdrawalUrl(
        slug: String,
        srpId: Int64,
        srpA: Array<Byte>,
        srpM1: Array<Byte>
    ): StarGiftWithdrawalUrlResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getStarGiftWithdrawalUrl slug=${slug}")
        let req = PaymentsGetStarGiftWithdrawalUrl()
        let ref = InputSavedStarGiftSlug()
        ref.slug = slug
        req.stargift = ref
        let pwd = InputCheckPasswordSRP()
        pwd.srpId = srpId
        pwd.srpA = srpA
        pwd.srpM1 = srpM1
        req.password = pwd
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarGiftWithdrawalUrl(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getStarGiftWithdrawalUrl exception")
            let r = StarGiftWithdrawalUrlResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 更新 Unique Gift 二次销售价格（payments.updateStarGiftPrice）
     *
     * 对应 iOS: updateStarGiftPrice (TelegramEnginePayments.swift)
     * resellStars=0  → 停止二次销售（下架）
     * resellStars>0  → 设置二次销售价格（上架）
     * 响应: Updates（服务器确认）
     *
     * @param slug         Unique Gift slug
     * @param resellStars  转售价格（Stars 数量）；0=下架
     * @return StarGiftUpdatesResponse
     */
    public func updateStarGiftPrice(slug: String, resellStars: Int64): StarGiftUpdatesResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] updateStarGiftPrice slug=${slug} stars=${resellStars}")
        let req = PaymentsUpdateStarGiftPrice()
        let ref = InputSavedStarGiftSlug()
        ref.slug = slug
        req.stargift = ref
        let amt = StarsAmount()
        amt.amount = resellStars
        amt.nanos = 0
        req.resellAmount = amt
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarGiftUpdates(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] updateStarGiftPrice exception")
            let r = StarGiftUpdatesResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 获取用户已保存的礼物列表（payments.getSavedStarGifts）
     *
     * 对应 iOS: getSavedStarGifts / ProfileGiftsContext (StarGifts.swift)
     * 分页接口，支持过滤（排除已取消保存/已保存/无限/有限/Unique）
     * 响应: payments.savedStarGifts#95f389b1（count + gifts + next_offset + chats + users）
     *
     * @param peerId       目标 peer userId（自己用 0, 以 InputPeerSelf 发）
     * @param accessHash   peer access_hash（peerId=0 时忽略）
     * @param offset       分页 offset（首次传空字符串）
     * @param limit        每页条目数
     * @param sortByValue  true=按价值排序
     * @return SavedStarGiftsResponse
     */
    public func getSavedStarGifts(
        peerId: Int64,
        accessHash: Int64,
        offset: String,
        limit: Int32,
        sortByValue: Bool
    ): SavedStarGiftsResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getSavedStarGifts peer=${peerId} offset='${offset}'")
        let req = PaymentsGetSavedStarGifts()
        req.sortByValue = sortByValue
        if (peerId == 0) {
            req.peer = InputPeerSelf()
        } else {
            let p = InputPeerUser()
            p.userId = peerId
            p.accessHash = accessHash
            req.peer = p
        }
        req.offset = offset
        req.limit = limit
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseSavedStarGifts(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getSavedStarGifts exception")
            let r = SavedStarGiftsResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 获取 Unique Gift 二次销售市场列表（payments.getResaleStarGifts）
     *
     * 对应 iOS: getResaleStarGifts (TelegramEnginePayments.swift)
     * 分页接口，按特定 gift_id 过滤，支持按价格/编号排序
     * 响应: payments.resaleStarGifts#947a12df（count + gifts + next_offset）
     *
     * @param giftId     原始 StarGift id（starGift#c62aca28.id）
     * @param offset     分页 offset（首次传空字符串）
     * @param limit      每页条目数
     * @param sortByPrice true=按价格排序；false=按编号排序
     * @return ResaleStarGiftsResponse
     */
    public func getResaleStarGifts(
        giftId: Int64,
        offset: String,
        limit: Int32,
        sortByPrice: Bool,
        sortByNum: Bool,
        starsOnly: Bool,
        attributes: ArrayList<StarGiftAttributeIdEntry>
    ): ResaleStarGiftsResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getResaleStarGifts giftId=${giftId} offset='${offset}' attrCount=${attributes.size}")
        let req = PaymentsGetResaleStarGifts()
        req.giftId = giftId
        req.offset = offset
        req.limit = limit
        req.sortByPrice = sortByPrice
        req.sortByNum = sortByNum
        req.starsOnly = starsOnly
        for (attr in attributes) {
            req.attributes.add(attr)
        }
        try {
            let responseData = this.onSourceLayer(req.toBytes())
            let result = parseResaleStarGifts(responseData)
            Hilog.info(0, "CjTelegram", "[PaymentsService] getResaleStarGifts result success=${result.success} count=${result.count} error=${result.errorMessage}")
            return result
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getResaleStarGifts exception")
            let r = ResaleStarGiftsResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 获取 StarGift 升级预览（payments.getStarGiftUpgradePreview）
     *
     * 对应 iOS: getStarGiftUpgradePreview (TelegramEnginePayments.swift)
     * 响应: payments.starGiftUpgradePreview#3dded20b
     *   sample_attributes:Vector<StarGiftAttribute>
     *   prices:Vector<StarGiftUpgradePrice>
     *   next_prices:Vector<StarGiftUpgradePrice>
     *
     * @param giftId 要升级的 StarGift id（原始 StarGift.id 字段）
     * @return StarGiftUpgradePreviewResponse
     */
    public func getStarGiftUpgradePreview(giftId: Int64): StarGiftUpgradePreviewResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getStarGiftUpgradePreview giftId=${giftId}")
        let req = PaymentsGetStarGiftUpgradePreview()
        req.giftId = giftId
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarGiftUpgradePreview(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getStarGiftUpgradePreview exception")
            let r = StarGiftUpgradePreviewResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    // ==================== P2-155c: Premium Gift Codes + Giveaways ====================

    /**
     * 校验礼品码（payments.checkGiftCode）
     *
     * 对应 iOS: _internal_checkPremiumGiftCode (GiftCodes.swift:267)
     * 响应: payments.checkedGiftCode#284a1096 (slug 的兑换信息)
     *
     * @param slug 礼品码字符串（URL 或直接 slug）
     * @return CheckedGiftCodeResponse（fromPeerId/months/date/isUsed 等）
     */
    public func checkGiftCode(slug: String): CheckedGiftCodeResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] checkGiftCode slug=${slug}")
        let req = PaymentsCheckGiftCode()
        req.slug = slug
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseCheckedGiftCode(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] checkGiftCode exception")
            let r = CheckedGiftCodeResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 兑换礼品码（payments.applyGiftCode）
     *
     * 对应 iOS: _internal_applyPremiumGiftCode (GiftCodes.swift:295)
     * 兑换后服务器更新 Premium 订阅状态。
     * 响应: Updates（四个 Updates 变体之一）
     *
     * @param slug 礼品码字符串
     * @return StarGiftUpdatesResponse（success=true 表示兑换已提交）
     */
    public func applyGiftCode(slug: String): StarGiftUpdatesResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] applyGiftCode slug=${slug}")
        let req = PaymentsApplyGiftCode()
        req.slug = slug
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarGiftUpdates(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] applyGiftCode exception")
            let r = StarGiftUpdatesResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 获取 Premium 礼品码套餐选项（payments.getPremiumGiftCodeOptions）
     *
     * 对应 iOS: _internal_premiumGiftCodeOptions (GiftCodes.swift:199)
     * 返回 Vector<PremiumGiftCodeOption>，每条包含用户数、月数、IAP 套餐信息和价格。
     * boostPeerId=0 → 不传 boost_peer（获取全局选项）
     * boostPeerId>0 → 传 InputPeerChannel 获取指定频道可用套餐
     *
     * @param boostPeerId    可选 boost 频道 channelId（0 表示全局）
     * @param boostAccessHash 频道 access_hash（boostPeerId=0 时忽略）
     * @return PremiumGiftCodeOptionsResponse（options 列表）
     */
    public func getPremiumGiftCodeOptions(boostPeerId: Int64, boostAccessHash: Int64): PremiumGiftCodeOptionsResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getPremiumGiftCodeOptions peer=${boostPeerId}")
        let req = PaymentsGetPremiumGiftCodeOptions()
        if (boostPeerId != 0i64) {
            let peer = InputPeerChannel()
            peer.channelId = boostPeerId
            peer.accessHash = boostAccessHash
            req.boostPeer = Some(peer)
        }
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parsePremiumGiftCodeOptions(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getPremiumGiftCodeOptions exception")
            let r = PremiumGiftCodeOptionsResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 查询抽奖信息（payments.getGiveawayInfo）
     *
     * 对应 iOS: _internal_getPremiumGiveawayInfo (GiftCodes.swift:109)
     * 响应: payments.giveawayInfo（进行中）或 payments.giveawayInfoResults（已结束）
     * peer 是创建抽奖的频道 / 聊天。
     *
     * @param peerId    抽奖所在频道 channelId
     * @param accessHash 频道 access_hash
     * @param msgId     包含抽奖的消息 ID
     * @return GiveawayInfoResponse（infoType="ongoing"/"results"）
     */
    public func getGiveawayInfo(peerId: Int64, accessHash: Int64, msgId: Int32): GiveawayInfoResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getGiveawayInfo peer=${peerId} msg=${msgId}")
        let req = PaymentsGetGiveawayInfo()
        let peer = InputPeerChannel()
        peer.channelId = peerId
        peer.accessHash = accessHash
        req.peer = peer
        req.msgId = msgId
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseGiveawayInfo(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getGiveawayInfo exception")
            let r = GiveawayInfoResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 启动预付费 Premium 抽奖（payments.launchPrepaidGiveaway）
     *
     * 对应 iOS: _internal_launchPrepaidGiveaway premium 路径 (GiftCodes.swift:360)
     * 已购买 prepaid giveaway 后通过此接口正式启动。
     * 响应: Updates（四个 Updates 变体之一）
     *
     * @param peerId             抽奖所在频道 channelId
     * @param accessHash         频道 access_hash
     * @param giveawayId         PrepaidGiveaway.id
     * @param onlyNewSubscribers 仅限新订阅者参与
     * @param winnersAreVisible  公示获奖者
     * @param additionalPeerIds  额外参与频道 channelIds
     * @param additionalHashes   对应 access_hash 列表（与 additionalPeerIds 一一对应）
     * @param countriesIso2      允许的国家/地区 ISO2 列表（空列表=不限制）
     * @param prizeDescription   可选奖品描述
     * @param randomId           随机数（防重复提交）
     * @param untilDate          抽奖截止时间（Unix 时间戳）
     * @param currency           货币代码
     * @param amount             金额（分为单位）
     * @return StarGiftUpdatesResponse（success=true 表示启动成功）
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
    ): StarGiftUpdatesResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] launchPrepaidGiveaway peer=${peerId} id=${giveawayId}")
        let req = PaymentsLaunchPrepaidGiveaway()
        let peer = InputPeerChannel()
        peer.channelId = peerId
        peer.accessHash = accessHash
        req.peer = peer
        req.giveawayId = giveawayId
        let purpose = InputStorePaymentPremiumGiveaway()
        purpose.onlyNewSubscribers = onlyNewSubscribers
        purpose.winnersAreVisible = winnersAreVisible
        let boostPeer2 = InputPeerChannel()
        boostPeer2.channelId = peerId
        boostPeer2.accessHash = accessHash
        purpose.boostPeer = boostPeer2
        var ai: Int64 = 0
        while (ai < Int64(additionalPeerIds.size)) {
            let ap = InputPeerChannel()
            ap.channelId = additionalPeerIds[ai]
            if (ai < Int64(additionalHashes.size)) {
                ap.accessHash = additionalHashes[ai]
            }
            purpose.additionalPeers.add(ap)
            ai = ai + 1
        }
        for (cc in countriesIso2) {
            purpose.countriesIso2.add(cc)
        }
        if (prizeDescription.size > 0) {
            purpose.prizeDescription = Some(prizeDescription)
        }
        purpose.randomId = randomId
        purpose.untilDate = untilDate
        purpose.currency = currency
        purpose.amount = amount
        req.purpose = purpose
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarGiftUpdates(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] launchPrepaidGiveaway exception")
            let r = StarGiftUpdatesResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    // ==================== P2-155d: Stars Subscriptions + Revenue ====================

    /**
     * 获取 Stars 订阅列表（payments.getStarsSubscriptions）
     *
     * 对应 iOS: _internal_requestStarsSubscriptions (Stars.swift:505)
     * 返回 payments.starsStatus#6c9ce8ed；其 subscriptions 字段含订阅条目列表。
     *
     * @param offset         分页 offset（首次传空字符串）
     * @param missingBalance 仅返回余额不足的订阅（用于提醒用户充值）
     * @return StarsSubscriptionsResponse（subscriptions + nextOffset + balance）
     */
    public func getStarsSubscriptions(offset: String, missingBalance: Bool): StarsSubscriptionsResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsSubscriptions offset='${offset}' missing=${missingBalance}")
        let req = PaymentsGetStarsSubscriptions()
        req.peer = InputPeerSelf()
        req.offset = offset
        req.missingBalance = missingBalance
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarsSubscriptions(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsSubscriptions exception")
            let r = StarsSubscriptionsResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 变更 Stars 订阅状态（payments.changeStarsSubscription）
     *
     * 对应 iOS: _internal_updateStarsSubscription (Stars.swift:1844)
     * canceled=true → 取消订阅; canceled=false → 恢复订阅。
     * 响应为 Bool (boolTrue/boolFalse)。
     *
     * @param peerId      订阅所属频道/chat 的 peer userId（0 表示当前用户）
     * @param accessHash  peer access_hash
     * @param subscriptionId 订阅 ID（来自 starsSubscription.id）
     * @param cancel      true=取消, false=恢复
     * @return TLBoolResponse（result=true 表示操作成功）
     */
    public func changeStarsSubscription(
        peerId: Int64,
        accessHash: Int64,
        subscriptionId: String,
        cancel: Bool
    ): TLBoolResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] changeStarsSubscription id=${subscriptionId} cancel=${cancel}")
        let req = PaymentsChangeStarsSubscription()
        if (peerId == 0) {
            req.peer = InputPeerSelf()
        } else {
            let p = InputPeerUser()
            p.userId = peerId
            p.accessHash = accessHash
            req.peer = p
        }
        req.subscriptionId = subscriptionId
        req.hasCanceled = true
        req.canceled = cancel
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseTLBool(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] changeStarsSubscription exception")
            let r = TLBoolResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 履行 Stars 订阅（payments.fulfillStarsSubscription）
     *
     * 对应 iOS: _internal_fulfillStarsSubscription (Stars.swift:1866)
     * 当用户余额不足导致订阅暂停时，补充充值后调用此接口手动触发履行。
     * 响应为 Bool。
     *
     * @param peerId         订阅所在频道 peer userId（0 表示当前用户）
     * @param accessHash     peer access_hash
     * @param subscriptionId 订阅 ID
     * @return TLBoolResponse（result=true 表示履行成功）
     */
    public func fulfillStarsSubscription(
        peerId: Int64,
        accessHash: Int64,
        subscriptionId: String
    ): TLBoolResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] fulfillStarsSubscription id=${subscriptionId}")
        let req = PaymentsFulfillStarsSubscription()
        if (peerId == 0) {
            req.peer = InputPeerSelf()
        } else {
            let p = InputPeerUser()
            p.userId = peerId
            p.accessHash = accessHash
            req.peer = p
        }
        req.subscriptionId = subscriptionId
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseTLBool(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] fulfillStarsSubscription exception")
            let r = TLBoolResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 获取 Stars 收益统计（payments.getStarsRevenueStats）
     *
     * 对应 iOS: 在 StatisticsUI 中使用（ChannelStatsController / RevenueWithdrawalController）
     * 返回 payments.starsRevenueStats#c92bb73b:
     *   revenue_graph:StatsGraph + status:StarsRevenueStatus + usd_rate:double
     * StarsRevenueStatus 包含 current_balance / available_balance / overall_revenue /
     *   next_withdrawal_at + withdrawal_enabled 标志。
     *
     * @param peerId     统计目标的 peer channelId（0 表示当前用户）
     * @param accessHash peer access_hash
     * @param dark       true=请求暗色主题图表
     * @return StarsRevenueStatsResponse（余额 + 收益总量 + USD汇率）
     */
    public func getStarsRevenueStats(peerId: Int64, accessHash: Int64, dark: Bool): StarsRevenueStatsResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsRevenueStats peer=${peerId} dark=${dark}")
        let req = PaymentsGetStarsRevenueStats()
        req.dark = dark
        if (peerId == 0) {
            req.peer = InputPeerSelf()
        } else {
            let p = InputPeerChannel()
            p.channelId = peerId
            p.accessHash = accessHash
            req.peer = p
        }
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarsRevenueStats(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsRevenueStats exception")
            let r = StarsRevenueStatsResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 获取 Stars 收益提现 URL（payments.getStarsRevenueWithdrawalUrl）
     *
     * 对应 iOS: RevenueWithdrawalController (StatisticsUI)
     * 需要 2FA SRP 密码验证。
     * 返回 payments.starsRevenueWithdrawalUrl#1dab80b7 url:string。
     * hasAmount=false → 提现全部可用余额；hasAmount=true → 提现指定 Stars 金额。
     *
     * @param peerId     目标频道 channelId（0 表示当前用户）
     * @param accessHash peer access_hash
     * @param hasAmount  是否指定提现金额
     * @param amount     提现金额（Stars 数，hasAmount=false 时忽略）
     * @param srpId      SRP 会话 ID（来自 account.getPassword 响应）
     * @param srpA       SRP 参数 A
     * @param srpM1      SRP 验证值 M1
     * @return StarsRevenueWithdrawalUrlResponse（url 字段含 Fragment 提现页面 URL）
     */
    public func getStarsRevenueWithdrawalUrl(
        peerId: Int64,
        accessHash: Int64,
        hasAmount: Bool,
        amount: Int64,
        srpId: Int64,
        srpA: Array<Byte>,
        srpM1: Array<Byte>
    ): StarsRevenueWithdrawalUrlResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsRevenueWithdrawalUrl peer=${peerId} hasAmount=${hasAmount}")
        let req = PaymentsGetStarsRevenueWithdrawalUrl()
        if (peerId == 0) {
            req.peer = InputPeerSelf()
        } else {
            let p = InputPeerChannel()
            p.channelId = peerId
            p.accessHash = accessHash
            req.peer = p
        }
        req.hasAmount = hasAmount
        req.amount = amount
        let pwd = InputCheckPasswordSRP()
        pwd.srpId = srpId
        pwd.srpA = srpA
        pwd.srpM1 = srpM1
        req.password = pwd
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarsRevenueWithdrawalUrl(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] getStarsRevenueWithdrawalUrl exception")
            let r = StarsRevenueWithdrawalUrlResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 启动预付费 Stars 抽奖（payments.launchPrepaidGiveaway，Stars 变体）
     *
     * 对应 iOS: _internal_launchPrepaidGiveaway stars 路径 (GiftCodes.swift:355)
     * Stars 版本抽奖需要指定 stars 数量和每位赠送数量。
     *
     * @param peerId             抽奖所在频道 channelId
     * @param accessHash         频道 access_hash
     * @param giveawayId         PrepaidGiveaway.id
     * @param stars              Stars 奖品总量
     * @param users              中奖人数
     * @param onlyNewSubscribers 仅限新订阅者参与
     * @param winnersAreVisible  公示获奖者
     * @param additionalPeerIds  额外参与频道 channelIds
     * @param additionalHashes   对应 access_hash 列表
     * @param countriesIso2      允许的国家/地区 ISO2 列表
     * @param prizeDescription   可选奖品描述
     * @param randomId           随机数
     * @param untilDate          抽奖截止时间
     * @param currency           货币代码
     * @param amount             金额
     * @return StarGiftUpdatesResponse
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
    ): StarGiftUpdatesResponse {
        Hilog.info(0, "CjTelegram", "[PaymentsService] launchPrepaidStarsGiveaway peer=${peerId} id=${giveawayId} stars=${stars}")
        let req = PaymentsLaunchPrepaidGiveaway()
        let peer = InputPeerChannel()
        peer.channelId = peerId
        peer.accessHash = accessHash
        req.peer = peer
        req.giveawayId = giveawayId
        let purpose = InputStorePaymentStarsGiveaway()
        purpose.stars = stars
        purpose.users = users
        purpose.onlyNewSubscribers = onlyNewSubscribers
        purpose.winnersAreVisible = winnersAreVisible
        let boostPeer3 = InputPeerChannel()
        boostPeer3.channelId = peerId
        boostPeer3.accessHash = accessHash
        purpose.boostPeer = boostPeer3
        var bi: Int64 = 0
        while (bi < Int64(additionalPeerIds.size)) {
            let ap2 = InputPeerChannel()
            ap2.channelId = additionalPeerIds[bi]
            if (bi < Int64(additionalHashes.size)) {
                ap2.accessHash = additionalHashes[bi]
            }
            purpose.additionalPeers.add(ap2)
            bi = bi + 1
        }
        for (cc2 in countriesIso2) {
            purpose.countriesIso2.add(cc2)
        }
        if (prizeDescription.size > 0) {
            purpose.prizeDescription = Some(prizeDescription)
        }
        purpose.randomId = randomId
        purpose.untilDate = untilDate
        purpose.currency = currency
        purpose.amount = amount
        req.purpose = purpose
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return parseStarGiftUpdates(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] launchPrepaidStarsGiveaway exception")
            let r = StarGiftUpdatesResponse()
            r.errorMessage = e.toString()
            return r
        }
    }

    /**
     * 清除已保存的支付凭据 / 收货地址（payments.clearSavedInfo，两位可分别置位——
     * diag-suite_settings_privacy-TC-0130.md RC-2：源侧是两个可分别勾选的 checkbox，
     * 按勾选结果组装 flags，不是固定两位全 1 的单按钮）。全仓唯一调用点：
     * pages/DataPrivacySettingsPage.cj。
     */
    public func clearSavedInfo(paymentInfo!: Bool, shippingInfo!: Bool): Bool {
        Hilog.info(0, "CjTelegram", "[PaymentsService] clearSavedInfo credentials=${paymentInfo} info=${shippingInfo}")
        try {
            let client = getMTProtoClient()
            let req = PaymentsClearSavedInfo()
            req.credentials = paymentInfo
            req.info = shippingInfo
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) { return false }
            let d = TLDeserializer(responseData)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errorCode = d.readInt32()
                let errorMessage = d.readString()
                Hilog.info(0, "CjTelegram", "[PaymentsService] clearSavedInfo error: ${errorCode} - ${errorMessage}")
                return false
            }
            Hilog.info(0, "CjTelegram", "[PaymentsService] clearSavedInfo: success (ctor=0x${ctor})")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PaymentsService] clearSavedInfo exception: ${e}")
            return false
        }
    }
}
