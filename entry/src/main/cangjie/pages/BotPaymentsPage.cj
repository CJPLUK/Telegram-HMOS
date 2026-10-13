package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.web.webview.WebviewController
import ohos.arkui.state_macro_manage.*
import ohos.business_exception.BusinessException
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * BotPaymentsPage — Bot 支付结账主页面 (P2-021)（混合工程迁移版）
 *
 * 对应 iOS BotCheckoutController / BotCheckoutControllerNode 的仓颉移植版本。
 * 展示 Invoice 信息（标题、描述、价格明细）并提供「Pay」操作按钮。
 * 包含内嵌子屏 Info录入(P2-022) / 运输方式选择(P2-023) / 小费编辑(P2-024)。
 *
 * 路由参数通过 onReady context 读取:
 *   param 格式: "<peerId>:<accessHash>:<msgId>:<isChannel>"
 *
 * 调用链:
 *   BotPaymentsPage.aboutToAppear
 *     → BotPaymentsService.getPaymentForm(peerId, accessHash, msgId, isChannel)
 *     → getMTProtoClient().sendRequest(PaymentsGetPaymentForm.toBytes())  [ctor 0x37148dbb]
 *
 *   BotPaymentsPage.submitInfo (P2-022)
 *     → BotPaymentsService.validateRequestedInfo(...)  [ctor 0xb6c8f12b]
 *     → returns validatedInfoId + shippingOptions
 *
 *   BotPaymentsPage.doPayment (onClick)
 *     → BotPaymentsService.sendPaymentForm(..., tip=currentTip, ...)  [ctor 0x2d03522f]
 *     → getMTProtoClient().sendRequest(PaymentsSendPaymentForm.toBytes())
 *
 * iOS Source refs:
 *   BotCheckoutControllerNode.swift — section layout (header/prices/info/shippingInfo/shippingMethod/tip/paymentMethod)
 *   BotCheckoutInfoController.swift — BotCheckoutInfoControllerFocus (address/name/phone/email)
 *   BotCheckoutShippingOptionScreen.swift — Radio list of shipping options with prices
 *   TipEditController.swift — suggested_tip_amounts preset buttons + custom input
 */

// ==================== 子屏枚举 ====================

// 子屏阶段：None=结账主屏, Info=信息录入, Shipping=运输选择, Tip=小费编辑
// P2-025: PaymentMethodSelect=支付方式选择
// P2-027: TwoFAEntry=2FA 密码输入
// P2-026: WebVerification=3DS/web 验证结账 webview
public enum CheckoutSubScreen {
    | MainCheckout
    | InfoEntry
    | ShippingSelection
    | TipEdit
    | PaymentMethodSelect
    | TwoFAEntry
    | WebVerification

    public func ordinal(): Int32 {
        match (this) {
            case MainCheckout => 0
            case InfoEntry => 1
            case ShippingSelection => 2
            case TipEdit => 3
            case PaymentMethodSelect => 4
            case TwoFAEntry => 5
            case WebVerification => 6
        }
    }

    public operator func ==(right: CheckoutSubScreen): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: CheckoutSubScreen): Bool {
        return this.ordinal() != right.ordinal()
    }
}

// ==================== 结账主页面 ====================

@HybridComponentEntry
@Component
public class BotPaymentsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 混合迁移：删除 @Consume var pageStack（NavDestination 由 ArkTS 壳提供，导航经 router.*）

    // 主屏状态
    @State var isLoading: Bool = true
    @State var errorMsg: String = ""
    @State var form: BotPaymentForm = BotPaymentForm()
    @State var isPaying: Bool = false
    @State var payResult: String = ""

    // 子屏导航状态 (P2-022/P2-023/P2-024)
    @State var currentSubScreen: CheckoutSubScreen = CheckoutSubScreen.MainCheckout

    // P2-022: 收货/联系信息录入
    @State var infoName: String = ""
    @State var infoPhone: String = ""
    @State var infoEmail: String = ""
    @State var infoStreet1: String = ""
    @State var infoStreet2: String = ""
    @State var infoCity: String = ""
    @State var infoState: String = ""
    @State var infoCountry: String = ""
    @State var infoPostCode: String = ""
    @State var saveInfo: Bool = false
    @State var infoValidating: Bool = false
    @State var infoError: String = ""

    // P2-022 验证结果
    @State var validatedInfoId: String = ""
    @State var shippingOptions: Array<BotPaymentShippingOption> = Array<BotPaymentShippingOption>()

    // P2-023: 运输方式选择
    @State var selectedShippingOptionId: String = ""
    @State var selectedShippingTitle: String = ""
    @State var selectedShippingCost: Int64 = 0

    // P2-024: 小费
    @State var currentTip: Int64 = 0
    @State var tipInputText: String = ""

    // P2-025: 支付方式选择（saved credentials）
    // selectedPaymentCredId: "" = no saved credential selected (will use new card / data cred)
    @State var selectedPaymentCredId: String = ""
    @State var selectedPaymentCredTitle: String = ""
    // savedCredentials loaded from paymentForm
    @State var savedCredentials: Array<BotPaymentSavedCredential> = Array<BotPaymentSavedCredential>()

    // P2-027: 2FA 密码输入（当 pwdProtected==true 且使用 saved credential 时需先获取 tmpPassword）
    @State var twoFAPassword: String = ""
    @State var twoFAError: String = ""
    @State var twoFAVerifying: Bool = false
    // tmpPassword token bytes，获取后用于 sendPaymentForm
    @State var tmpPasswordToken: Array<Byte> = Array<Byte>(0, repeat: 0)

    // P2-026: 3DS/web 验证结账 webview
    @State var webVerifyUrl: String = ""
    var webVerifyController: WebviewController = WebviewController()

    // 路由参数（从 onReady 解包）
    var peerId: Int64 = 0
    var peerAccessHash: Int64 = 0
    var msgId: Int32 = 0
    var isChannel: Bool = false

    @State var loaded: Bool = false

    // 混合迁移：源 aboutToAppear 仅日志（真加载在 onReady 拿到 param 后）；
    // 混合工程 onReady 已废除 → ensureLoaded() 经 takePending("BotPaymentsPage") 取参并加载表单。
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let param = takePending("BotPaymentsPage")
        if (param.size > 0) {
            this.parsePeerId(param)
            this.loadPaymentForm()
        }
    }

    private func loadPaymentForm() {
        let pid = this.peerId
        let pah = this.peerAccessHash
        let mid = this.msgId
        let isCh = this.isChannel
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[BotPaymentsPage] loadPaymentForm peerId=${pid} msgId=${mid}")
            let svc = getBotPaymentsService()
            let result = svc.getPaymentForm(pid, pah, mid, isCh)
            launch {
                match (result) {
                    case Some(f) =>
                        this.form = f
                        // Pre-fill from saved_info if present
                        if (f.savedInfoName.size > 0) { this.infoName = f.savedInfoName }
                        if (f.savedInfoPhone.size > 0) { this.infoPhone = f.savedInfoPhone }
                        if (f.savedInfoEmail.size > 0) { this.infoEmail = f.savedInfoEmail }
                        if (f.savedInfoStreet1.size > 0) {
                            this.infoStreet1 = f.savedInfoStreet1
                            this.infoStreet2 = f.savedInfoStreet2
                            this.infoCity = f.savedInfoCity
                            this.infoState = f.savedInfoState
                            this.infoCountry = f.savedInfoCountry
                            this.infoPostCode = f.savedInfoPostCode
                        }
                        // P2-025: populate saved credentials and pre-select first
                        let creds = f.savedCredentials.toArray()
                        this.savedCredentials = creds
                        if (creds.size > 0) {
                            this.selectedPaymentCredId = creds[0].id
                            this.selectedPaymentCredTitle = creds[0].maskedTitle()
                        }
                        this.isLoading = false
                    case None =>
                        this.errorMsg = "Failed to load payment form"
                        this.isLoading = false
                }
            }
        }
    }

    // P2-022: 提交收货/联系信息并验证
    private func submitInfo() {
        if (this.infoValidating) { return }
        // 字段校验
        let nameOk = !this.form.nameRequested || this.infoName.size > 0
        let phoneOk = !this.form.phoneRequested || this.infoPhone.size >= 5
        let emailOk = !this.form.emailRequested || containsChar(this.infoEmail, "@")
        let addrOk = !this.form.shippingAddressRequested || (this.infoStreet1.size > 0 && this.infoCity.size > 0 && this.infoCountry.size > 0)
        if (!nameOk) {
            this.infoError = "Name is required"
            return
        }
        if (!phoneOk) {
            this.infoError = "Valid phone number is required"
            return
        }
        if (!emailOk) {
            this.infoError = "Valid email address is required"
            return
        }
        if (!addrOk) {
            this.infoError = "Complete shipping address is required"
            return
        }
        this.infoError = ""
        this.infoValidating = true
        let pid = this.peerId
        let pah = this.peerAccessHash
        let mid = this.msgId
        let isCh = this.isChannel
        let nm = this.infoName
        let ph = this.infoPhone
        let em = this.infoEmail
        let s1 = this.infoStreet1
        let s2 = this.infoStreet2
        let cy = this.infoCity
        let st = this.infoState
        let co = this.infoCountry
        let pc = this.infoPostCode
        let sv = this.saveInfo
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[BotPaymentsPage] validateRequestedInfo save=${sv}")
            let info = BotPaymentRequestedInfo()
            info.name = nm
            info.phone = ph
            info.email = em
            info.streetLine1 = s1
            info.streetLine2 = s2
            info.city = cy
            info.state = st
            info.countryIso2 = co
            info.postCode = pc
            let svc = getBotPaymentsService()
            let res = svc.validateRequestedInfo(pid, pah, mid, isCh, info, sv)
            launch {
                this.infoValidating = false
                match (res) {
                    case Some(validated) =>
                        this.validatedInfoId = validated.id
                        let opts = validated.shippingOptions.toArray()
                        this.shippingOptions = opts
                        // Navigate: if shipping options exist → shipping screen; else → main checkout
                        if (opts.size > 0) {
                            this.currentSubScreen = CheckoutSubScreen.ShippingSelection
                        } else {
                            this.currentSubScreen = CheckoutSubScreen.MainCheckout
                        }
                    case None =>
                        this.infoError = "Validation failed. Please check your information."
                }
            }
        }
    }

    // P2-023: 选择运输方式 (called from onClick — UI thread; direct assignment is safe)
    private func selectShippingOption(optId: String, optTitle: String, optCost: Int64) {
        this.selectedShippingOptionId = optId
        this.selectedShippingTitle = optTitle
        this.selectedShippingCost = optCost
    }

    private func confirmShipping() {
        this.currentSubScreen = CheckoutSubScreen.MainCheckout
    }

    // P2-024: 设置小费 (called from onClick — UI thread)
    private func setTipPreset(amount: Int64) {
        this.currentTip = amount
        this.tipInputText = ""
    }

    private func applyCustomTip() {
        let text = this.tipInputText
        let parsed = this.parseTipAmount(text, this.form.currency)
        let maxTip = this.form.maxTipAmount
        if (parsed >= 0 && (maxTip == 0 || parsed <= maxTip)) {
            this.currentTip = parsed
            this.currentSubScreen = CheckoutSubScreen.MainCheckout
        } else if (maxTip > 0 && parsed > maxTip) {
            this.currentTip = maxTip
            this.currentSubScreen = CheckoutSubScreen.MainCheckout
        }
    }

    // 解析用户输入的小费文本 → minor units
    private func parseTipAmount(text: String, currency: String): Int64 {
        if (text.size == 0) { return 0 }
        let decimals = getCurrencyDecimals(currency)
        var result: Int64 = 0
        var afterDot: Bool = false
        var decimalCount: Int64 = 0
        let runes = text.toRuneArray()
        for (r in runes) {
            let code = UInt32(r)
            if (code >= 48 && code <= 57) {
                let digit = Int64(code - 48)
                if (afterDot) {
                    if (decimalCount < Int64(decimals)) {
                        result = result * 10 + digit
                        decimalCount = decimalCount + 1
                    }
                } else {
                    result = result * 10 + digit
                }
            } else if (r.toString() == ".") {
                afterDot = true
                // scale up by decimals
                var scale: Int64 = 1
                var k: Int64 = 0
                while (k < Int64(decimals)) {
                    scale = scale * 10
                    k = k + 1
                }
                result = result * scale
            }
        }
        // if no dot was encountered, scale by decimals
        if (!afterDot && decimals > 0) {
            var scale: Int64 = 1
            var k: Int64 = 0
            while (k < Int64(decimals)) {
                scale = scale * 10
                k = k + 1
            }
            result = result * scale
        }
        return result
    }

    // P2-027: 检查是否需要 2FA (pwdProtected + using saved credential)
    // 如果 pwdProtected 且有选中的 saved credential → 先弹 2FA 对话框
    private func initiatePayment() {
        if (this.form.pwdProtected && this.selectedPaymentCredId.size > 0 && this.tmpPasswordToken.size == 0) {
            this.twoFAPassword = ""
            this.twoFAError = ""
            this.currentSubScreen = CheckoutSubScreen.TwoFAEntry
        } else {
            this.doPayment()
        }
    }

    // P2-027: 提交 2FA 密码，获取 temp password token
    // 调用 RealAuthService.getTmpPassword(password, period) — 内部执行完整 SRP kdf
    // (computeCurrentPasswordSRP → AccountGetTmpPassword，与 TwoFactorAuthPage:142 / ChannelRevenueStatsPage:212 同路径)
    // AccountTmpPasswordResponse.tmpPassword 即 bytes token，传入 sendPaymentFormSaved
    private func submitTwoFA() {
        if (this.twoFAVerifying) { return }
        if (this.twoFAPassword.size == 0) {
            this.twoFAError = "Password is required"
            return
        }
        this.twoFAError = ""
        this.twoFAVerifying = true
        let pwd = this.twoFAPassword
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[BotPaymentsPage] submitTwoFA calling RealAuthService.getTmpPassword")
            let authSvc = getRealAuthService()
            let result = authSvc.getTmpPassword(pwd, 3600)
            launch {
                this.twoFAVerifying = false
                if (result.tmpPassword.size > 0) {
                    this.tmpPasswordToken = result.tmpPassword
                    this.currentSubScreen = CheckoutSubScreen.MainCheckout
                    this.doPayment()
                } else {
                    this.twoFAError = "Password verification failed. Please check your password."
                }
            }
        }
    }

    // P2-021 + P2-025 + P2-027: sendPaymentForm with saved credential token or data credential
    private func doPayment() {
        if (this.isPaying) { return }
        let pid = this.peerId
        let pah = this.peerAccessHash
        let mid = this.msgId
        let isCh = this.isChannel
        let fid = this.form.formId
        let tip = this.currentTip
        let infoId = this.validatedInfoId
        let shipId = this.selectedShippingOptionId
        let credId = this.selectedPaymentCredId
        let token = this.tmpPasswordToken

        this.isPaying = true
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[BotPaymentsPage] doPayment formId=${fid} tip=${tip} credId=${credId} tokenLen=${token.size}")
            let svc = getBotPaymentsService()
            let payRes: BotPaymentResult = if (credId.size > 0) {
                // P2-025 + P2-027: saved credential path.
                // iOS ref: BotCheckoutController — pwdProtected==true → getTmpPassword first (token non-empty);
                //          pwdProtected==false → sendPaymentFormSaved directly with empty token (spec-legal).
                // initiatePayment() already gates 2FA entry on form.pwdProtected, so by the time we reach here:
                //   pwdProtected==true  → token was populated in submitTwoFA via real SRP getTmpPassword
                //   pwdProtected==false → token stays empty [] which the server accepts as "no 2FA required"
                svc.sendPaymentFormSaved(fid, pid, pah, mid, isCh, credId, token, infoId, shipId, tip)
            } else {
                // Honestly deferred: card credentials require Stripe SDK (P2-299/Stripe)
                let credJson = "{\"type\":\"card\",\"id\":\"preauth_id\"}"
                svc.sendPaymentForm(fid, pid, pah, mid, isCh, credJson, infoId, shipId, tip)
            }
            let success = payRes.success
            let vurl = payRes.verificationUrl
            let errMsg = payRes.errorMessage
            launch {
                this.isPaying = false
                if (success) {
                    this.payResult = "Payment successful!"
                } else if (vurl.size > 0) {
                    // P2-026: 3DS/web 验证 — 加载验证 URL 到 webview 子屏
                    // iOS ref: BotCheckoutWebInteractionControllerNode.swift .externalVerification
                    // 先存 URL，再切换到 WebVerification 子屏
                    this.webVerifyUrl = vurl
                    this.currentSubScreen = CheckoutSubScreen.WebVerification
                } else {
                    this.payResult = "Payment failed: ${errMsg}"
                }
            }
        }
    }

    private func getTotalAmount(): Int64 {
        var total: Int64 = 0
        for (price in this.form.prices) {
            total = total + price.amount
        }
        return total + this.selectedShippingCost + this.currentTip
    }

    // Helper: sum of prices in a shipping option (R-107: must be a method, not let inside ForEach)
    private func shippingOptionTotal(opt: BotPaymentShippingOption): Int64 {
        var total: Int64 = 0
        for (price in opt.prices) {
            total = total + price.amount
        }
        return total
    }

    private func parsePeerId(param: String): Unit {
        let parts = splitByColon(param)
        if (parts.size >= 4) {
            this.peerId = parseI64(parts[0])
            this.peerAccessHash = parseI64(parts[1])
            this.msgId = Int32(parseI64(parts[2]))
            this.isChannel = parts[3] == "1"
        }
    }

    private func splitByColon(s: String): ArrayList<String> {
        let result = ArrayList<String>()
        var current = ""
        let runes = s.toRuneArray()
        for (r in runes) {
            if (r.toString() == ":") {
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
        var start = 0
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

    private func containsChar(s: String, ch: String): Bool {
        let runes = s.toRuneArray()
        let cr = ch.toRuneArray()
        if (cr.size == 0) { return true }
        for (r in runes) {
            if (r.toString() == ch) { return true }
        }
        return false
    }

    // ==================== UI 构建 ====================

    func build() {
        // 混合迁移：NavDestination 包裹与 .title/.hideTitleBar/.onReady 移除（NavDestination 由 ArkTS 壳提供，
        // hideTitleBar=false）；用全屏 Column 承载原 if/else 内容并挂 .onAppear 触发 ensureLoaded（消费路由参数）。
        Column {
            if (this.currentSubScreen == CheckoutSubScreen.InfoEntry) {
                this.buildInfoEntry()
            } else if (this.currentSubScreen == CheckoutSubScreen.ShippingSelection) {
                this.buildShippingSelection()
            } else if (this.currentSubScreen == CheckoutSubScreen.TipEdit) {
                this.buildTipEdit()
            } else if (this.currentSubScreen == CheckoutSubScreen.PaymentMethodSelect) {
                this.buildPaymentMethodSelect()
            } else if (this.currentSubScreen == CheckoutSubScreen.TwoFAEntry) {
                this.buildTwoFAEntry()
            } else if (this.currentSubScreen == CheckoutSubScreen.WebVerification) {
                this.buildWebVerification()
            } else {
                this.buildMainCheckout()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }

    // ==================== P2-026: 3DS/web 验证结账 webview ====================

    /**
     * 3DS/web 验证结账屏。
     *
     * 对应 iOS: BotCheckoutWebInteractionControllerNode.swift .externalVerification 路径
     *   - 加载 verificationUrl 到 WKWebView
     *   - navigationDelegate 拦截 host == "t.me" 或 "telegram.me" → completion(true) 成功
     *   - Cancel 按钮 → completion(false) 失败，关闭 webview 返回结账主屏
     *
     * 鸿蒙侧使用 Web 组件 + onLoadIntercept 实现相同拦截逻辑。
     * onLoadIntercept 返回 true = 拦截（阻止）该导航；false = 放行。
     */
    @Builder
    func buildWebVerification() {
        Column() {
            Row() {
                Button(trSource("Cancel"))
                    .fontSize(16)
                    .padding(left: 8, right: 8, top: 4, bottom: 4)
                    .onClick({ _ =>
                        // P2-026: 用户取消 — 对应 iOS completion(false)，返回结账主屏
                        // onClick is on UIThread, @State writes are safe directly
                        this.payResult = "3DS verification cancelled."
                        this.currentSubScreen = CheckoutSubScreen.MainCheckout
                    })
                Text("Payment Verification")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .flexGrow(1)
                    .textAlign(TextAlign.Center)
            }
            .width(100.percent)
            .padding(8)

            if (this.webVerifyUrl.size > 0) {
                Web(src: this.webVerifyUrl, controller: this.webVerifyController)
                    .width(100.percent)
                    .layoutWeight(1)
                    .domStorageAccess(true)
                    .onLoadIntercept({ evt =>
                        // P2-026: 拦截 t.me 和 telegram.me 导航 — 对应 iOS host 检查
                        // iOS ref: BotCheckoutWebInteractionControllerNode.swift
                        //   if host == "t.me" || host == "telegram.me" → completion(true)
                        let url = evt.data.getRequestUrl()
                        Hilog.info(0, "CjTelegram", "[BotPaymentsPage] onLoadIntercept url=${url}")
                        let isTgRedirect = url.contains("t.me") || url.contains("telegram.me")
                        if (isTgRedirect) {
                            // 成功支付重定向 — 通知支付流成功
                            // onLoadIntercept callback — consistent with BrowserScreen.cj direct @State write pattern
                            this.payResult = "Payment successful!"
                            this.currentSubScreen = CheckoutSubScreen.MainCheckout
                            return true  // 阻止 webview 真正跳转到 t.me
                        }
                        return false  // 放行其他导航（3DS 银行页面内跳转）
                    })
                    .onPageBegin({ evt =>
                        Hilog.info(0, "CjTelegram", "[BotPaymentsPage] webVerify onPageBegin")
                    })
                    .onPageEnd({ evt =>
                        Hilog.info(0, "CjTelegram", "[BotPaymentsPage] webVerify onPageEnd")
                    })
            } else {
                Text("Loading verification page...")
                    .fontSize(15)
                    .layoutWeight(1)
            }
        }
        .width(100.percent)
        .height(100.percent)
    }

    // ==================== P2-021: 结账主屏 ====================

    @Builder
    func buildMainCheckout() {
        Scroll() {
            Column {
                if (this.isLoading) {
                    Column {
                        Text("Loading payment form...")
                            .fontSize(16)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .height(200)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else if (this.errorMsg.size > 0) {
                    Column {
                        Text(this.errorMsg)
                            .fontSize(15)
                            .fontColor(0xFF3B30)
                            .textAlign(TextAlign.Center)
                            .padding(left: 16, right: 16, top: 16, bottom: 16)
                    }
                    .width(100.percent)
                } else {
                    // 商品标题
                    Text(this.form.title)
                        .fontSize(20)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 4)

                    // 商品描述
                    if (this.form.description.size > 0) {
                        Text(this.form.description)
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, bottom: 8)
                    }

                    Divider()
                        .height(1)
                        .backgroundColor(0xE5E5EA)
                        .margin(left: 16, right: 16, top: 4, bottom: 4)

                    // 价格明细列表
                    ForEach(this.form.prices.toArray(), itemGenerator: { price: BotPaymentPrice, _idx: Int64 =>
                        Row {
                            Text(price.label)
                                .fontSize(15)
                                .fontColor(0x000000)
                                .flexGrow(1)
                            Text(formatCurrencyAmount(price.amount, this.form.currency))
                                .fontSize(15)
                                .fontColor(0x000000)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                    })

                    // 运输费行（若已选择）
                    if (this.selectedShippingCost > 0) {
                        Row {
                            Text("Shipping: ${this.selectedShippingTitle}")
                                .fontSize(15)
                                .fontColor(0x000000)
                                .flexGrow(1)
                            Text(formatCurrencyAmount(this.selectedShippingCost, this.form.currency))
                                .fontSize(15)
                                .fontColor(0x000000)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                    }

                    // 小费行（若有）
                    if (this.currentTip > 0) {
                        Row {
                            Text(trSource("Tip"))
                                .fontSize(15)
                                .fontColor(0x000000)
                                .flexGrow(1)
                            Text(formatCurrencyAmount(this.currentTip, this.form.currency))
                                .fontSize(15)
                                .fontColor(0x000000)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                    }

                    Divider()
                        .height(1)
                        .backgroundColor(0xE5E5EA)
                        .margin(left: 16, right: 16, top: 4, bottom: 4)

                    // 总计行
                    Row {
                        Text(trSource("Total"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                            .flexGrow(1)
                        Text(formatCurrencyAmount(this.getTotalAmount(), this.form.currency))
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 12, bottom: 12)

                    Divider()
                        .height(1)
                        .backgroundColor(0xE5E5EA)
                        .margin(left: 16, right: 16)

                    // 收货/联系信息行 (P2-022)
                    if (this.form.nameRequested || this.form.phoneRequested || this.form.emailRequested || this.form.shippingAddressRequested) {
                        Row {
                            Column {
                                Text(trSource("Shipping Info"))
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                                Text(if (this.infoName.size > 0) { this.infoName + " • " + this.infoPhone } else { "Tap to enter" })
                                    .fontSize(15)
                                    .fontColor(if (this.infoName.size > 0) { 0x000000 } else { 0x8E8E93 })
                            }
                            .alignItems(HorizontalAlign.Start)
                            .flexGrow(1)
                            Text(">")
                                .fontSize(16)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 12, bottom: 12)
                        .onClick({ _evt =>
                            this.currentSubScreen = CheckoutSubScreen.InfoEntry
                        })

                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 16)
                    }

                    // 运输方式行 (P2-023)
                    if (this.shippingOptions.size > 0) {
                        Row {
                            Column {
                                Text(trSource("Shipping Method"))
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                                Text(if (this.selectedShippingTitle.size > 0) { this.selectedShippingTitle } else { "Tap to select" })
                                    .fontSize(15)
                                    .fontColor(if (this.selectedShippingTitle.size > 0) { 0x000000 } else { 0x8E8E93 })
                            }
                            .alignItems(HorizontalAlign.Start)
                            .flexGrow(1)
                            Text(">")
                                .fontSize(16)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 12, bottom: 12)
                        .onClick({ _evt =>
                            this.currentSubScreen = CheckoutSubScreen.ShippingSelection
                        })

                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 16)
                    }

                    // 小费行 (P2-024) - 若 invoice 有 suggested_tip_amounts 或 max_tip_amount
                    if (this.form.maxTipAmount > 0 || this.form.suggestedTipAmounts.size > 0) {
                        Row {
                            Column {
                                Text(trSource("Tip"))
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                                Text(if (this.currentTip > 0) { formatCurrencyAmount(this.currentTip, this.form.currency) } else { "No tip" })
                                    .fontSize(15)
                                    .fontColor(if (this.currentTip > 0) { 0x007AFF } else { 0x8E8E93 })
                            }
                            .alignItems(HorizontalAlign.Start)
                            .flexGrow(1)
                            Text(">")
                                .fontSize(16)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 12, bottom: 12)
                        .onClick({ _evt =>
                            this.currentSubScreen = CheckoutSubScreen.TipEdit
                        })

                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 16)
                    }

                    // ==================== P2-025: 支付方式行 ====================
                    Row {
                        Column {
                            Text(trSource("Payment Method"))
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                            Text(if (this.selectedPaymentCredTitle.size > 0) {
                                this.selectedPaymentCredTitle
                            } else {
                                "Add Payment Method"
                            })
                                .fontSize(15)
                                .fontColor(if (this.selectedPaymentCredTitle.size > 0) { 0x000000 } else { 0x8E8E93 })
                        }
                        .alignItems(HorizontalAlign.Start)
                        .flexGrow(1)
                        Text(">")
                            .fontSize(16)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 12, bottom: 12)
                    .onClick({ _evt =>
                        this.currentSubScreen = CheckoutSubScreen.PaymentMethodSelect
                    })

                    Divider()
                        .height(1)
                        .backgroundColor(0xE5E5EA)
                        .margin(left: 16, right: 16)

                    // 支付结果消息
                    if (this.payResult.size > 0) {
                        Text(this.payResult)
                            .fontSize(14)
                            .fontColor(if (this.payResult.contains("successful")) { 0x34C759 } else { 0xFF3B30 })
                            .textAlign(TextAlign.Center)
                            .width(100.percent)
                            .padding(left: 12, right: 12, top: 12, bottom: 12)
                    }

                    // 收据按钮（支付成功后显示）
                    if (this.payResult.contains("successful")) {
                        Button("View Receipt")
                            .width(100.percent)
                            .height(50)
                            .borderRadius(12)
                            .backgroundColor(0x34C759)
                            .fontColor(0xFFFFFF)
                            .fontSize(17)
                            .margin(left: 16, right: 16, top: 8, bottom: 4)
                            .onClick({ _evt =>
                                let paramStr = Int64(this.peerId).toString() + ":" +
                                    Int64(this.peerAccessHash).toString() + ":" +
                                    Int64(this.msgId).toString() + ":" +
                                    (if (this.isChannel) { "1" } else { "0" })
                                routerPush("BotReceiptPage", paramStr)
                            })
                    }

                    // Pay 按钮 (P2-027: calls initiatePayment which checks 2FA)
                    if (!this.payResult.contains("successful")) {
                        Button(if (this.isPaying) { "Processing..." } else { "Pay " + formatCurrencyAmount(this.getTotalAmount(), this.form.currency) })
                            .width(100.percent)
                            .height(50)
                            .borderRadius(12)
                            .backgroundColor(if (this.isPaying) { 0xAAAAAA } else { 0x007AFF })
                            .fontColor(0xFFFFFF)
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .enabled(!this.isPaying)
                            .margin(left: 16, right: 16, top: 16, bottom: 24)
                            .onClick({ _evt =>
                                this.initiatePayment()
                            })
                    }
                }
            }
            .width(100.percent)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
    }

    // ==================== P2-022: 收货/联系信息录入 ====================

    @Builder
    func buildInfoEntry() {
        Scroll() {
            Column {
                // 标题
                Row {
                    Button(trSource("Cancel"))
                        .fontSize(16)
                        .fontColor(0x007AFF)
                        .backgroundColor(Color.Transparent)
                        .borderRadius(0)
                        .padding(left: 16, right: 8, top: 8, bottom: 8)
                        .onClick({ _evt =>
                            this.infoError = ""
                            this.currentSubScreen = CheckoutSubScreen.MainCheckout
                        })
                    Blank().flexGrow(1)
                    Text(trSource("Contact Info"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .flexGrow(0)
                    Blank().flexGrow(1)
                    Button(trSource("Done"))
                        .fontSize(16)
                        .fontColor(0x007AFF)
                        .backgroundColor(Color.Transparent)
                        .borderRadius(0)
                        .padding(left: 8, right: 16, top: 8, bottom: 8)
                        .onClick({ _evt =>
                            this.submitInfo()
                        })
                }
                .width(100.percent)
                .height(50)
                .backgroundColor(0xFFFFFF)

                Divider()
                    .height(1)
                    .backgroundColor(0xE5E5EA)

                // 错误消息
                if (this.infoError.size > 0) {
                    Text(this.infoError)
                        .fontSize(14)
                        .fontColor(0xFF3B30)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .backgroundColor(0xFFF3F3)
                }

                // 姓名字段 (若需要)
                if (this.form.nameRequested) {
                    Column {
                        Text(trSource("Name"))
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 4)
                        TextInput(text: this.infoName, placeholder: "Full Name")
                            .width(100.percent)
                            .height(44)
                            .backgroundColor(0xFFFFFF)
                            .padding(left: 16, right: 16, top: 0, bottom: 0)
                            .fontSize(16)
                            .onChange({ v: String =>
                                this.infoName = v
                            })
                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 0)
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                }

                // 电话字段 (若需要)
                if (this.form.phoneRequested) {
                    Column {
                        Text(trSource("Phone"))
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 4)
                        TextInput(text: this.infoPhone, placeholder: "+1 234 567 8900")
                            .width(100.percent)
                            .height(44)
                            .backgroundColor(0xFFFFFF)
                            .padding(left: 16, right: 16, top: 0, bottom: 0)
                            .fontSize(16)
                            .onChange({ v: String =>
                                this.infoPhone = v
                            })
                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 0)
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                }

                // 邮件字段 (若需要)
                if (this.form.emailRequested) {
                    Column {
                        Text(trSource("Email"))
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 4)
                        TextInput(text: this.infoEmail, placeholder: "email@example.com")
                            .width(100.percent)
                            .height(44)
                            .backgroundColor(0xFFFFFF)
                            .padding(left: 16, right: 16, top: 0, bottom: 0)
                            .fontSize(16)
                            .onChange({ v: String =>
                                this.infoEmail = v
                            })
                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 0)
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                }

                // 地址字段 (若需要)
                if (this.form.shippingAddressRequested) {
                    Text("Shipping Address")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 16, bottom: 4)

                    Column {
                        TextInput(text: this.infoStreet1, placeholder: "Street Address Line 1")
                            .width(100.percent)
                            .height(44)
                            .backgroundColor(0xFFFFFF)
                            .padding(left: 16, right: 16, top: 0, bottom: 0)
                            .fontSize(16)
                            .onChange({ v: String =>
                                this.infoStreet1 = v
                            })
                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 0)
                        TextInput(text: this.infoStreet2, placeholder: "Street Address Line 2 (optional)")
                            .width(100.percent)
                            .height(44)
                            .backgroundColor(0xFFFFFF)
                            .padding(left: 16, right: 16, top: 0, bottom: 0)
                            .fontSize(16)
                            .onChange({ v: String =>
                                this.infoStreet2 = v
                            })
                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 0)
                        TextInput(text: this.infoCity, placeholder: trSource("City"))
                            .width(100.percent)
                            .height(44)
                            .backgroundColor(0xFFFFFF)
                            .padding(left: 16, right: 16, top: 0, bottom: 0)
                            .fontSize(16)
                            .onChange({ v: String =>
                                this.infoCity = v
                            })
                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 0)
                        Row {
                            TextInput(text: this.infoState, placeholder: "State/Province")
                                .height(44)
                                .backgroundColor(0xFFFFFF)
                                .padding(left: 16, right: 8, top: 0, bottom: 0)
                                .fontSize(16)
                                .flexGrow(1)
                                .onChange({ v: String =>
                                    this.infoState = v
                                })
                            Divider()
                                .height(44)
                                .width(1)
                                .backgroundColor(0xE5E5EA)
                            TextInput(text: this.infoPostCode, placeholder: "Post Code")
                                .height(44)
                                .backgroundColor(0xFFFFFF)
                                .padding(left: 8, right: 16, top: 0, bottom: 0)
                                .fontSize(16)
                                .width(140)
                                .onChange({ v: String =>
                                    this.infoPostCode = v
                                })
                        }
                        .width(100.percent)
                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 0)
                        TextInput(text: this.infoCountry, placeholder: "Country Code (e.g. US)")
                            .width(100.percent)
                            .height(44)
                            .backgroundColor(0xFFFFFF)
                            .padding(left: 16, right: 16, top: 0, bottom: 0)
                            .fontSize(16)
                            .onChange({ v: String =>
                                this.infoCountry = v
                            })
                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 0, right: 0)
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                }

                // Save info 开关
                Row {
                    Text(trSource("Save Info"))
                        .fontSize(16)
                        .fontColor(0x000000)
                        .flexGrow(1)
                    Toggle(ToggleType.Switch, isOn: this.saveInfo)
                        .onChange({ v: Bool =>
                            this.saveInfo = v
                        })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 12, bottom: 12)
                .backgroundColor(0xFFFFFF)
                .margin(top: 16)

                Text("Save your name, phone, email and address for faster checkout next time.")
                    .fontSize(12)
                    .fontColor(0x8E8E93)
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 4, bottom: 8)

                // Validate 按钮
                Button(if (this.infoValidating) { "Validating..." } else { "Continue" })
                    .width(100.percent)
                    .height(50)
                    .borderRadius(12)
                    .backgroundColor(if (this.infoValidating) { 0xAAAAAA } else { 0x007AFF })
                    .fontColor(0xFFFFFF)
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .enabled(!this.infoValidating)
                    .margin(left: 16, right: 16, top: 16, bottom: 24)
                    .onClick({ _evt =>
                        this.submitInfo()
                    })
            }
            .width(100.percent)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
    }

    // ==================== P2-023: 运输方式选择 ====================

    @Builder
    func buildShippingSelection() {
        Column {
            // 导航栏
            Row {
                Button(trSource("Back"))
                    .fontSize(16)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .borderRadius(0)
                    .padding(left: 16, right: 8, top: 8, bottom: 8)
                    .onClick({ _evt =>
                        this.currentSubScreen = CheckoutSubScreen.InfoEntry
                    })
                Blank().flexGrow(1)
                Text(trSource("Shipping Method"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                Blank().flexGrow(1)
                Button(trSource("Done"))
                    .fontSize(16)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .borderRadius(0)
                    .padding(left: 8, right: 16, top: 8, bottom: 8)
                    .onClick({ _evt =>
                        this.confirmShipping()
                    })
            }
            .width(100.percent)
            .height(50.0 + getSafeAreaTop())
            .padding(top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)

            Divider()
                .height(1)
                .backgroundColor(0xE5E5EA)

            Scroll() {
                Column {
                    Text("Choose a shipping method")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 16, bottom: 8)

                    // Shipping options list (Radio buttons)
                    // R-107: no let/var in ForEach closure; use this.shippingOptionTotal(opt) inline
                    ForEach(this.shippingOptions, itemGenerator: { opt: BotPaymentShippingOption, _idx: Int64 =>
                        Row {
                            Radio(value: opt.id, group: "shippingGroup")
                                .checked(this.selectedShippingOptionId == opt.id)
                                .width(24)
                                .height(24)
                                .onChange({ isChecked: Bool =>
                                    if (isChecked) {
                                        this.selectShippingOption(opt.id, opt.title, this.shippingOptionTotal(opt))
                                    }
                                })
                            Column {
                                Text(opt.title)
                                    .fontSize(16)
                                    .fontColor(0x000000)
                                Text(formatCurrencyAmount(this.shippingOptionTotal(opt), this.form.currency))
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                            }
                            .alignItems(HorizontalAlign.Start)
                            .margin(left: 12)
                            .flexGrow(1)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 12, bottom: 12)
                        .backgroundColor(0xFFFFFF)
                        .onClick({ _evt =>
                            this.selectShippingOption(opt.id, opt.title, this.shippingOptionTotal(opt))
                        })
                    })

                    // Proceed 按钮
                    Button(trSource("Proceed"))
                        .width(100.percent)
                        .height(50)
                        .borderRadius(12)
                        .backgroundColor(if (this.selectedShippingOptionId.size > 0) { 0x007AFF } else { 0xAAAAAA })
                        .fontColor(0xFFFFFF)
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .enabled(this.selectedShippingOptionId.size > 0)
                        .margin(left: 16, right: 16, top: 24, bottom: 24)
                        .onClick({ _evt =>
                            this.confirmShipping()
                        })
                }
                .width(100.percent)
            }
            .width(100.percent)
            .flexGrow(1)
            .backgroundColor(0xF2F2F7)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
    }

    // ==================== P2-025: 支付方式选择 ====================

    @Builder
    func buildPaymentMethodSelect() {
        Column {
            Row {
                Button(trSource("Cancel"))
                    .fontSize(16)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .borderRadius(0)
                    .padding(left: 16, right: 8, top: 8, bottom: 8)
                    .onClick({ _evt =>
                        this.currentSubScreen = CheckoutSubScreen.MainCheckout
                    })
                Blank().flexGrow(1)
                Text(trSource("Payment Method"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x000000)
                Blank().flexGrow(1)
                Button(trSource("Done"))
                    .fontSize(16)
                    .fontColor(if (this.selectedPaymentCredId.size > 0) { 0x007AFF } else { 0xC7C7CC })
                    .backgroundColor(Color.Transparent)
                    .borderRadius(0)
                    .padding(left: 8, right: 16, top: 8, bottom: 8)
                    .onClick({ _evt =>
                        this.currentSubScreen = CheckoutSubScreen.MainCheckout
                    })
            }
            .width(100.percent)
            .height(50.0 + getSafeAreaTop())
            .padding(top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)

            Divider()
                .height(1)
                .backgroundColor(0xE5E5EA)

            Scroll() {
                Column {
                    // 已存卡列表
                    if (this.savedCredentials.size > 0) {
                        Text("Saved Cards")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 16, bottom: 8)
                            .backgroundColor(0xF2F2F7)

                        ForEach(this.savedCredentials, itemGenerator: { cred: BotPaymentSavedCredential, _idx: Int64 =>
                            Column {
                                Row {
                                    Radio(value: cred.id, group: "checkoutPayMethodGroup")
                                        .checked(this.selectedPaymentCredId == cred.id)
                                        .width(24)
                                        .height(24)
                                        .onChange({ isChecked: Bool =>
                                            if (isChecked) {
                                                this.selectedPaymentCredId = cred.id
                                                this.selectedPaymentCredTitle = cred.maskedTitle()
                                            }
                                        })
                                    Column {
                                        Text(cred.maskedTitle())
                                            .fontSize(16)
                                            .fontColor(0x000000)
                                        if (this.form.pwdProtected) {
                                            Text("Requires password verification")
                                                .fontSize(12)
                                                .fontColor(0x8E8E93)
                                        }
                                    }
                                    .alignItems(HorizontalAlign.Start)
                                    .margin(left: 12)
                                    .flexGrow(1)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 14, bottom: 14)
                                .backgroundColor(0xFFFFFF)
                                .onClick({ _evt =>
                                    this.selectedPaymentCredId = cred.id
                                    this.selectedPaymentCredTitle = cred.maskedTitle()
                                })
                                Divider()
                                    .height(1)
                                    .backgroundColor(0xE5E5EA)
                                    .margin(left: 52, right: 0)
                            }
                            .width(100.percent)
                        })
                    }

                    // Apple Pay N-A (HarmonyOS 无对应)
                    Text("Other Methods")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 16, bottom: 8)
                        .backgroundColor(0xF2F2F7)

                    Row {
                        Text("Apple Pay")
                            .fontSize(16)
                            .fontColor(0xC7C7CC)
                            .flexGrow(1)
                        Text(trSource("N/A"))
                            .fontSize(13)
                            .fontColor(0xC7C7CC)
                            .backgroundColor(0xE5E5EA)
                            .borderRadius(4)
                            .padding(left: 6, right: 6, top: 2, bottom: 2)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 14, bottom: 14)
                    .backgroundColor(0xFFFFFF)

                    Divider()
                        .height(1)
                        .backgroundColor(0xE5E5EA)
                        .margin(left: 0, right: 0)

                    // 新卡入口
                    Row {
                        Text("Add New Card")
                            .fontSize(16)
                            .fontColor(0x007AFF)
                            .flexGrow(1)
                        Text(">")
                            .fontSize(16)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 14, bottom: 14)
                    .backgroundColor(0xFFFFFF)
                    .onClick({ _evt =>
                        let paramStr = Int64(this.peerId).toString() + ":" +
                            Int64(this.peerAccessHash).toString() + ":" +
                            Int64(this.msgId).toString() + ":" +
                            (if (this.isChannel) { "1" } else { "0" })
                        routerPush("PaymentCardEntryScreen", paramStr)
                    })

                    Divider()
                        .height(1)
                        .backgroundColor(0xE5E5EA)
                        .margin(left: 0, right: 0)

                    Text("Card credentials require Stripe SDK integration (P2-299).")
                        .fontSize(12)
                        .fontColor(0x8E8E93)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 16)
                }
                .width(100.percent)
            }
            .width(100.percent)
            .flexGrow(1)
            .backgroundColor(0xF2F2F7)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
    }

    // ==================== P2-027: 2FA 密码输入对话框 ====================

    @Builder
    func buildTwoFAEntry() {
        Column {
            Row {
                Button(trSource("Cancel"))
                    .fontSize(16)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .borderRadius(0)
                    .padding(left: 16, right: 8, top: 8, bottom: 8)
                    .onClick({ _evt =>
                        this.twoFAPassword = ""
                        this.twoFAError = ""
                        this.currentSubScreen = CheckoutSubScreen.MainCheckout
                    })
                Blank().flexGrow(1)
                Text(trSource("Enter Password"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x000000)
                Blank().flexGrow(1)
                Blank().width(70)
            }
            .width(100.percent)
            .height(50.0 + getSafeAreaTop())
            .padding(top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)

            Divider()
                .height(1)
                .backgroundColor(0xE5E5EA)

            Scroll() {
                Column {
                    Text("Password Required")
                        .fontSize(20)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 32, bottom: 8)

                    Text("Enter your 2-Step Verification password to proceed with payment using your saved card.")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .padding(left: 24, right: 24, top: 0, bottom: 24)

                    if (this.twoFAError.size > 0) {
                        Text(this.twoFAError)
                            .fontSize(14)
                            .fontColor(0xFF3B30)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 4, bottom: 8)
                            .backgroundColor(0xFFF3F3)
                    }

                    // 密码输入框 (P2-027: password mode)
                    Column {
                        Text(trSource("Password"))
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 4)
                        TextInput(text: this.twoFAPassword, placeholder: "2-Step Verification password")
                            .width(100.percent)
                            .height(44)
                            .backgroundColor(0xFFFFFF)
                            .padding(left: 16, right: 16, top: 0, bottom: 0)
                            .fontSize(16)
                            .onChange({ v: String =>
                                this.twoFAPassword = v
                            })
                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 0, right: 0)
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                    .margin(left: 16, right: 16, top: 0, bottom: 0)

                    Button(if (this.twoFAVerifying) { "Verifying..." } else { "Verify Password" })
                        .width(100.percent)
                        .height(50)
                        .borderRadius(12)
                        .backgroundColor(if (this.twoFAVerifying || this.twoFAPassword.size == 0) { 0xAAAAAA } else { 0x007AFF })
                        .fontColor(0xFFFFFF)
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .enabled(!this.twoFAVerifying && this.twoFAPassword.size > 0)
                        .margin(left: 16, right: 16, top: 24, bottom: 8)
                        .onClick({ _evt =>
                            this.submitTwoFA()
                        })

                    Text("Your password is used to obtain a temporary token for payment. It is not stored.")
                        .fontSize(12)
                        .fontColor(0x8E8E93)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .padding(left: 24, right: 24, top: 4, bottom: 32)
                }
                .width(100.percent)
            }
            .width(100.percent)
            .flexGrow(1)
            .backgroundColor(0xF2F2F7)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
    }

    // ==================== P2-024: 小费编辑 ====================

    @Builder
    func buildTipEdit() {
        Column {
            // 导航栏
            Row {
                Button(trSource("Cancel"))
                    .fontSize(16)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .borderRadius(0)
                    .padding(left: 16, right: 8, top: 8, bottom: 8)
                    .onClick({ _evt =>
                        this.currentSubScreen = CheckoutSubScreen.MainCheckout
                    })
                Blank().flexGrow(1)
                Text("Add a Tip")
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                Blank().flexGrow(1)
                Blank().width(70)
            }
            .width(100.percent)
            .height(50.0 + getSafeAreaTop())
            .padding(top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)

            Divider()
                .height(1)
                .backgroundColor(0xE5E5EA)

            Scroll() {
                Column {
                    // 当前小费显示
                    Row {
                        Text("Tip Amount")
                            .fontSize(16)
                            .fontColor(0x000000)
                            .flexGrow(1)
                        Text(if (this.currentTip > 0) { formatCurrencyAmount(this.currentTip, this.form.currency) } else { "No tip" })
                            .fontSize(16)
                            .fontColor(if (this.currentTip > 0) { 0x007AFF } else { 0x8E8E93 })
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 16, bottom: 16)
                    .backgroundColor(0xFFFFFF)

                    Divider()
                        .height(1)
                        .backgroundColor(0xE5E5EA)

                    // 预设小费按钮 (suggested_tip_amounts)
                    if (this.form.suggestedTipAmounts.size > 0) {
                        Text("Suggested Tips")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 6)

                        Row {
                            // No tip button
                            Button(trSource("None"))
                                .fontSize(14)
                                .height(36)
                                .borderRadius(18)
                                .backgroundColor(if (this.currentTip == 0) { 0x007AFF } else { 0xE5E5EA })
                                .fontColor(if (this.currentTip == 0) { 0xFFFFFF } else { 0x000000 })
                                .margin(left: 4, right: 4)
                                .onClick({ _evt =>
                                    this.setTipPreset(0)
                                })

                            ForEach(this.form.suggestedTipAmounts.toArray(), itemGenerator: { tipAmt: Int64, _idx: Int64 =>
                                Button(formatCurrencyAmount(tipAmt, this.form.currency))
                                    .fontSize(14)
                                    .height(36)
                                    .borderRadius(18)
                                    .backgroundColor(if (this.currentTip == tipAmt) { 0x007AFF } else { 0xE5E5EA })
                                    .fontColor(if (this.currentTip == tipAmt) { 0xFFFFFF } else { 0x000000 })
                                    .margin(left: 4, right: 4)
                                    .onClick({ _evt =>
                                        this.setTipPreset(tipAmt)
                                    })
                            })
                        }
                        .width(100.percent)
                        .padding(left: 12, right: 12, top: 4, bottom: 12)
                        .justifyContent(FlexAlign.Start)
                    }

                    // 自定义小费输入
                    Text("Custom Tip")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 12, bottom: 6)

                    Row {
                        Text(this.form.currency + " ")
                            .fontSize(16)
                            .fontColor(0x8E8E93)
                            .padding(left: 16, right: 4, top: 12, bottom: 12)
                        TextInput(text: this.tipInputText, placeholder: "0.00")
                            .height(44)
                            .backgroundColor(0xFFFFFF)
                            .padding(left: 4, right: 16, top: 0, bottom: 0)
                            .fontSize(16)
                            .flexGrow(1)
                            .onChange({ v: String =>
                                this.tipInputText = v
                            })
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)

                    if (this.form.maxTipAmount > 0) {
                        Text("Maximum tip: ${formatCurrencyAmount(this.form.maxTipAmount, this.form.currency)}")
                            .fontSize(12)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 4, bottom: 8)
                    }

                    Divider()
                        .height(1)
                        .backgroundColor(0xE5E5EA)

                    // 应用自定义小费按钮
                    Button("Set Custom Tip")
                        .width(100.percent)
                        .height(50)
                        .borderRadius(12)
                        .backgroundColor(if (this.tipInputText.size > 0) { 0x007AFF } else { 0xAAAAAA })
                        .fontColor(0xFFFFFF)
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .enabled(this.tipInputText.size > 0)
                        .margin(left: 16, right: 16, top: 16, bottom: 8)
                        .onClick({ _evt =>
                            this.applyCustomTip()
                        })

                    // 取消小费按钮
                    Button("Back to Checkout")
                        .width(100.percent)
                        .height(50)
                        .borderRadius(12)
                        .backgroundColor(0xF2F2F7)
                        .fontColor(0x007AFF)
                        .fontSize(17)
                        .margin(left: 16, right: 16, top: 4, bottom: 24)
                        .onClick({ _evt =>
                            this.currentSubScreen = CheckoutSubScreen.MainCheckout
                        })
                }
                .width(100.percent)
            }
            .width(100.percent)
            .flexGrow(1)
            .backgroundColor(0xF2F2F7)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
    }
}


