package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * PaymentCardEntryScreen — 银行卡录入页面
 *
 * 对应 iOS PaymentCardEntryScreen（PaymentCardEntryScreen.swift）：
 * - 录入：卡号（Luhn 校验）、持卡人姓名、有效期（MM/YY）、CVV（3-4 位）
 * - 实时校验，Add 按钮仅在所有字段合法时可点击
 * - 点击 Add 后通过 PaymentMethodService.submitCardViaStripe 走 Stripe tokenize
 *   → PaymentsService.sendPaymentForm → MTProtoClient.sendRequest
 *
 * 路由参数格式（从 PaymentMethodPage 传入）：
 *   "<peerId>:<accessHash>:<msgId>:<formId>:<stripeKey>"
 *   若为空字符串则以离线校验模式运行（不实际提交）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack（原为 dead consume，未用于导航）
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - onReady 参数收取 → ensureLoaded() 里 takePending("PaymentCardEntryScreen")，.onAppear 触发
 */
@HybridComponentEntry
@Component
public class PaymentCardEntryScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 卡字段（@State 触发重绘）
    @State var cardNumber: String = ""
    @State var holderName: String = ""
    @State var expiry: String = ""
    @State var cvv: String = ""

    // 校验错误
    @State var numberError: String = ""
    @State var nameError: String = ""
    @State var expiryError: String = ""
    @State var cvvError: String = ""

    // 提交状态
    @State var isSubmitting: Bool = false
    @State var submitResult: String = ""

    // 从路由参数解析出的支付上下文
    var peerId: Int64 = 0
    var accessHash: Int64 = 0
    var msgId: Int32 = 0
    var formId: Int64 = 0
    var stripeKey: String = ""
    var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let param = takePending("PaymentCardEntryScreen")
        if (param.size > 0 && param != "{}") {
            this.parseRouteParam(param)
        }
        Hilog.info(0, "CjTelegram", "[PaymentCardEntryScreen] ensureLoaded formId=${this.formId}")
    }

    // -------------------- 校验辅助 --------------------

    private func isFormValid(): Bool {
        let svc = getPaymentMethodService()
        return svc.validateCardNumber(cardNumber) &&
            holderName.trimAscii().size > 0 &&
            svc.validateExpiry(expiry) &&
            svc.validateCvv(cvv)
    }

    private func validateFields(): Unit {
        let svc = getPaymentMethodService()
        let card = CardEntryData(
            cardNumber,
            holderName,
            expiry,
            cvv
        )
        let result = svc.validateCard(card)
        this.numberError = result.numberError
        this.nameError = result.nameError
        this.expiryError = result.expiryError
        this.cvvError = result.cvvError
    }

    // -------------------- 提交 --------------------

    private func doSubmit(): Unit {
        if (isSubmitting) { return }
        validateFields()
        if (!isFormValid()) { return }

        let pid = peerId
        let pah = accessHash
        let mid = msgId
        let fid = formId
        let skey = stripeKey
        let cardNum = cardNumber
        let holder = holderName
        let exp = expiry
        let cv = cvv

        isSubmitting = true
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[PaymentCardEntryScreen] doSubmit formId=${fid}")
            let svc = getPaymentMethodService()
            let card = CardEntryData(
                cardNum,
                holder,
                exp,
                cv
            )
            if (fid == 0 || skey.size == 0) {
                // 无支付上下文：仅校验并展示成功
                Hilog.info(0, "CjTelegram", "[PaymentCardEntryScreen] No payment context, validation only")
                launch {
                    this.isSubmitting = false
                    this.submitResult = "Card validated successfully"
                }
            } else {
                svc.submitCardViaStripe(
                    card,
                    skey,
                    fid,
                    pid,
                    pah,
                    mid,
                    { result: PaymentMethodSubmitResult =>
                        launch {
                            this.isSubmitting = false
                            if (result.success) {
                                this.submitResult = "Payment successful!"
                            } else if (result.verificationUrl.size > 0) {
                                this.submitResult = "3DS verification required"
                            } else {
                                this.submitResult = "Payment failed: " + result.errorMessage
                            }
                        }
                    }
                )
            }
        }
    }

    // -------------------- 路由参数解析 --------------------

    private func parseRouteParam(param: String): Unit {
        // Format: "<peerId>:<accessHash>:<msgId>:<formId>:<stripeKey>"
        // stripeKey may contain ':', so split on first 4 colons only
        let parts = splitByColonN(param, 5)
        if (parts.size >= 5) {
            peerId = parseI64(parts[0])
            accessHash = parseI64(parts[1])
            msgId = Int32(parseI64(parts[2]))
            formId = parseI64(parts[3])
            stripeKey = parts[4]
        } else if (parts.size >= 3) {
            peerId = parseI64(parts[0])
            accessHash = parseI64(parts[1])
            msgId = Int32(parseI64(parts[2]))
        }
    }

    private func splitByColonN(s: String, maxParts: Int64): ArrayList<String> {
        let result = ArrayList<String>()
        var current = ""
        let runes = s.toRuneArray()
        for (r in runes) {
            if (r.toString() == ":" && Int64(result.size) < maxParts - 1) {
                result.add(current)
                current = ""
            } else {
                current = current + r.toString()
            }
        }
        result.add(current)
        return result
    }

    private func parseI64(s: String): Int64 {
        var val: Int64 = 0
        var neg = false
        let runes = s.toRuneArray()
        var start: Int64 = 0
        if (runes.size > 0 && runes[0].toString() == "-") {
            neg = true
            start = 1
        }
        for (i in start..runes.size) {
            let code = UInt32(runes[i])
            if (code >= 48 && code <= 57) {
                val = val * 10 + Int64(code - 48)
            }
        }
        return if (neg) { -val } else { val }
    }

    // -------------------- UI --------------------

    func build() {
        Scroll() {
            Column {
                // 顶部说明文字
                Text("Enter your card information")
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .textAlign(TextAlign.Center)
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 16, bottom: 16)

                // ---- 卡号 ----
                Column {
                    Row {
                        Text(trSource("Number"))
                            .fontSize(17)
                            .fontColor(0x000000)
                            .width(90)
                        TextInput(placeholder: "Card Number", text: cardNumber)
                            .fontSize(17)
                            .fontColor(0x000000)
                            .placeholderColor(0xC7C7CC)
                            .backgroundColor(Color.Transparent)
                            .flexGrow(1)
                            .inputFilter("[0-9 ]", error: { _: String => })
                            .maxLength(19)
                            .onChange({ val: String =>
                                let svc = getPaymentMethodService()
                                this.cardNumber = svc.formatCardNumber(val)
                                if (this.numberError.size > 0) {
                                    this.numberError = if (svc.validateCardNumber(val)) { "" } else { "Invalid card number" }
                                }
                            })
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 12, bottom: 12)
                    if (numberError.size > 0) {
                        Text(numberError)
                            .fontSize(12)
                            .fontColor(0xFF3B30)
                            .padding(left: 106, right: 16, top: 0, bottom: 8)
                            .width(100.percent)
                    }
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, bottom: 2)

                // ---- 持卡人姓名 ----
                Column {
                    Row {
                        Text(trSource("Name"))
                            .fontSize(17)
                            .fontColor(0x000000)
                            .width(90)
                        TextInput(placeholder: "Cardholder", text: holderName)
                            .fontSize(17)
                            .fontColor(0x000000)
                            .placeholderColor(0xC7C7CC)
                            .backgroundColor(Color.Transparent)
                            .flexGrow(1)
                            .onChange({ val: String =>
                                this.holderName = val
                                if (this.nameError.size > 0) {
                                    this.nameError = if (val.trimAscii().size > 0) { "" } else { "Cardholder name required" }
                                }
                            })
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 12, bottom: 12)
                    if (nameError.size > 0) {
                        Text(nameError)
                            .fontSize(12)
                            .fontColor(0xFF3B30)
                            .padding(left: 106, right: 16, top: 0, bottom: 8)
                            .width(100.percent)
                    }
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, bottom: 2)

                // ---- 有效期 ----
                Column {
                    Row {
                        Text(trSource("Expires"))
                            .fontSize(17)
                            .fontColor(0x000000)
                            .width(90)
                        TextInput(placeholder: "MM/YY", text: expiry)
                            .fontSize(17)
                            .fontColor(0x000000)
                            .placeholderColor(0xC7C7CC)
                            .backgroundColor(Color.Transparent)
                            .flexGrow(1)
                            .inputFilter("[0-9/]", error: { _: String => })
                            .maxLength(5)
                            .onChange({ val: String =>
                                this.expiry = formatExpiryInput(val)
                                if (this.expiryError.size > 0) {
                                    let svc = getPaymentMethodService()
                                    this.expiryError = if (svc.validateExpiry(val)) { "" } else { "Invalid or expired date (MM/YY)" }
                                }
                            })
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 12, bottom: 12)
                    if (expiryError.size > 0) {
                        Text(expiryError)
                            .fontSize(12)
                            .fontColor(0xFF3B30)
                            .padding(left: 106, right: 16, top: 0, bottom: 8)
                            .width(100.percent)
                    }
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, bottom: 2)

                // ---- CVV ----
                Column {
                    Row {
                        Text("CVV")
                            .fontSize(17)
                            .fontColor(0x000000)
                            .width(90)
                        TextInput(placeholder: "123", text: cvv)
                            .fontSize(17)
                            .fontColor(0x000000)
                            .placeholderColor(0xC7C7CC)
                            .backgroundColor(Color.Transparent)
                            .flexGrow(1)
                            .inputFilter("[0-9]", error: { _: String => })
                            .maxLength(4)
                            .onChange({ val: String =>
                                this.cvv = val
                                if (this.cvvError.size > 0) {
                                    let svc = getPaymentMethodService()
                                    this.cvvError = if (svc.validateCvv(val)) { "" } else { "CVV must be 3 or 4 digits" }
                                }
                            })
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 12, bottom: 12)
                    if (cvvError.size > 0) {
                        Text(cvvError)
                            .fontSize(12)
                            .fontColor(0xFF3B30)
                            .padding(left: 106, right: 16, top: 0, bottom: 8)
                            .width(100.percent)
                    }
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, bottom: 16)

                // 条款说明
                Text("By adding a card, you agree to the Terms of Service.")
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .padding(left: 16, right: 16, top: 0, bottom: 8)
                    .width(100.percent)

                // 提交结果
                if (submitResult.size > 0) {
                    Text(submitResult)
                        .fontSize(14)
                        .fontColor(if (submitResult.contains("successful") || submitResult.contains("validated")) { 0x34C759 } else { 0xFF3B30 })
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                }

                // Add 按钮
                Button(if (isSubmitting) { "Processing..." } else { "Add" })
                    .width(100.percent)
                    .height(50)
                    .borderRadius(12)
                    .backgroundColor(if (isFormValid() && !isSubmitting) { 0x007AFF } else { 0xCCCCCC })
                    .fontColor(0xFFFFFF)
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .enabled(isFormValid() && !isSubmitting)
                    .margin(left: 16, right: 16, top: 8, bottom: 8)
                    .onClick({ _evt =>
                        this.doSubmit()
                    })
            }
            .width(100.percent)
            .backgroundColor(0xF2F2F7)
            .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
            .padding(top: 8, bottom: 32)
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }

    // -------------------- 有效期格式化辅助 --------------------

    /**
     * 在输入第 2 个数字后自动插入 '/'
     * 例: "12" → "12/" , "1234" → "12/34"
     */
    private func formatExpiryInput(val: String): String {
        let digits = stripNonDigits(val)
        if (digits.size <= 2) {
            return digits
        }
        let runes = digits.toRuneArray()
        var out = ""
        for (i in 0..runes.size) {
            if (i == 2) { out = out + "/" }
            out = out + runes[i].toString()
        }
        return out
    }

    private func stripNonDigits(s: String): String {
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
}
