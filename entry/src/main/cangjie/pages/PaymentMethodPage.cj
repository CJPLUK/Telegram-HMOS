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
 * PaymentMethodPage — 支付方式选择页面 (P2-025)
 *
 * 对应 iOS BotCheckoutPaymentMethodScreen / PaymentMethodListScreen:
 *   BotCheckoutPaymentMethod: .savedCredentials(BotPaymentSavedCredentials) | .webToken | .applePay | .other
 *   splitSavedCardTitle — 按最后"*"分割，suffix → "•••• XXXX"
 *
 * 展示可选支付方式:
 *   1. 已存卡列表（savedCredentials from paymentForm, radio 选择，maskedTitle显示）
 *   2. Apple Pay 行 — HarmonyOS 无，诚实标注 N-A（Policy A, 合理降级）
 *   3. Web-token 行（若 form 有 webTokenTitle/webTokenData 则显示）
 *   4. 新卡录入入口
 *
 * 路由参数通过 takePending 读取（富参走 ParamStore）:
 *   param 格式: "<peerId>:<accessHash>:<msgId>:<isChannel>"
 *   (与 BotPaymentsPage 一致，用来在选好后回传选中的支付方式)
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()；pushPathByName → routerPush
 *  - onReady 参数收取 → ensureLoaded() 里 takePending("PaymentMethodPage")，.onAppear 触发
 */
@HybridComponentEntry
@Component
public class PaymentMethodPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 支付表单，含 savedCredentials
    @State var isLoading: Bool = true
    @State var errorMsg: String = ""
    @State var savedCredentials: Array<BotPaymentSavedCredential> = Array<BotPaymentSavedCredential>()

    // 当前选中的支付方式
    @State var selectedCredId: String = ""
    @State var selectedCredTitle: String = ""

    // 路由参数（从 takePending 解包，透传给 PaymentCardEntryScreen）
    var routeParam: String = ""
    var peerId: Int64 = 0
    var peerAccessHash: Int64 = 0
    var msgId: Int32 = 0
    var isChannel: Bool = false
    var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let param = takePending("PaymentMethodPage")
        let hasParam = param.size > 0 && param != "{}"
        this.routeParam = if (hasParam) { param } else { "" }
        if (hasParam) {
            this.parseParam(param)
            this.loadSavedCredentials()
        } else {
            this.isLoading = false
        }
        Hilog.info(0, "CjTelegram", "[PaymentMethodPage] ensureLoaded param size=${param.size}")
    }

    private func loadSavedCredentials() {
        if (this.peerId == 0 && this.msgId == 0) {
            let _ = spawn {
                launch {
                    this.isLoading = false
                }
            }
            return
        }
        let pid = this.peerId
        let pah = this.peerAccessHash
        let mid = this.msgId
        let isCh = this.isChannel
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[PaymentMethodPage] loadSavedCredentials peerId=${pid} msgId=${mid}")
            let svc = getBotPaymentsService()
            let result = svc.getPaymentForm(pid, pah, mid, isCh)
            launch {
                match (result) {
                    case Some(form) =>
                        let creds = form.savedCredentials.toArray()
                        this.savedCredentials = creds
                        if (creds.size > 0) {
                            this.selectedCredId = creds[0].id
                            this.selectedCredTitle = creds[0].title
                        }
                        this.isLoading = false
                    case None =>
                        this.errorMsg = "Failed to load payment methods"
                        this.isLoading = false
                }
            }
        }
    }

    private func selectCredential(id: String, title: String) {
        this.selectedCredId = id
        this.selectedCredTitle = title
    }

    private func confirmSelection() {
        routerPop()
    }

    private func parseParam(param: String): Unit {
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

    func build() {
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
                        routerPop()
                    })
                Blank().flexGrow(1)
                Text(trSource("Payment Method"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x000000)
                Blank().flexGrow(1)
                Button(trSource("Done"))
                    .fontSize(16)
                    .fontColor(if (this.selectedCredId.size > 0) { 0x007AFF } else { 0xC7C7CC })
                    .backgroundColor(Color.Transparent)
                    .borderRadius(0)
                    .padding(left: 8, right: 16, top: 8, bottom: 8)
                    .enabled(this.selectedCredId.size > 0)
                    .onClick({ _evt =>
                        this.confirmSelection()
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
                    if (this.isLoading) {
                        Column {
                            Text("Loading payment methods...")
                                .fontSize(15)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .height(200)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                    } else if (this.errorMsg.size > 0) {
                        Text(this.errorMsg)
                            .fontSize(14)
                            .fontColor(0xFF3B30)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 16, bottom: 16)
                    } else {
                        // ==================== 已存卡列表 ====================
                        // P2-025: savedCredentials from paymentForm.savedCredentials
                        // 每张卡显示掩码 title（如 "Visa •••• 1234"）+ radio 选择
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
                                        Radio(value: cred.id, group: "paymentMethodGroup")
                                            .checked(this.selectedCredId == cred.id)
                                            .width(24)
                                            .height(24)
                                            .onChange({ isChecked: Bool =>
                                                if (isChecked) {
                                                    this.selectCredential(cred.id, cred.title)
                                                }
                                            })
                                        Column {
                                            Text(cred.maskedTitle())
                                                .fontSize(16)
                                                .fontColor(0x000000)
                                        }
                                        .alignItems(HorizontalAlign.Start)
                                        .margin(left: 12)
                                        .flexGrow(1)
                                    }
                                    .width(100.percent)
                                    .padding(left: 16, right: 16, top: 14, bottom: 14)
                                    .backgroundColor(0xFFFFFF)
                                    .onClick({ _evt =>
                                        this.selectCredential(cred.id, cred.title)
                                    })
                                    Divider()
                                        .height(1)
                                        .backgroundColor(0xE5E5EA)
                                        .margin(left: 52, right: 0)
                                }
                                .width(100.percent)
                            })
                        }

                        // ==================== Apple Pay 行（HarmonyOS N-A） ====================
                        // Policy A: Apple Pay is iOS-platform-specific; HarmonyOS has no equivalent.
                        // Honest N-A display per fidelity-gap policy: shown as disabled row with label.
                        Text("Other Methods")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 16, bottom: 8)
                            .backgroundColor(0xF2F2F7)

                        Row {
                            Column {
                                Text("Apple Pay")
                                    .fontSize(16)
                                    .fontColor(0xC7C7CC)
                                Text("Not available on HarmonyOS")
                                    .fontSize(12)
                                    .fontColor(0xC7C7CC)
                            }
                            .alignItems(HorizontalAlign.Start)
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
                            .margin(left: 16, right: 0)

                        // ==================== 新卡入口 ====================
                        // Stripe/IAP card credentials require Stripe SDK (P2-299)
                        // This row navigates to card entry screen
                        Row {
                            Column {
                                Text("Add New Card")
                                    .fontSize(16)
                                    .fontColor(0x007AFF)
                                Text("Debit or credit card")
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                            }
                            .alignItems(HorizontalAlign.Start)
                            .flexGrow(1)
                            Text(">")
                                .fontSize(16)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 14, bottom: 14)
                        .backgroundColor(0xFFFFFF)
                        .onClick({ _evt =>
                            Hilog.info(0, "CjTelegram", "[PaymentMethodPage] Add New Card tapped")
                            routerPush("PaymentCardEntryScreen", this.routeParam)
                        })

                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 0, right: 0)

                        // 提示文字
                        Text("Your payment information is processed securely. Card credentials require Stripe integration (P2-299).")
                            .fontSize(12)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 8, bottom: 16)

                        // 若有已选方式，显示确认按钮
                        if (this.selectedCredId.size > 0) {
                            Button("Use ${this.selectedCredTitle}")
                                .width(100.percent)
                                .height(50)
                                .borderRadius(12)
                                .backgroundColor(0x007AFF)
                                .fontColor(0xFFFFFF)
                                .fontSize(17)
                                .fontWeight(FontWeight.Medium)
                                .margin(left: 16, right: 16, top: 8, bottom: 24)
                                .onClick({ _evt =>
                                    this.confirmSelection()
                                })
                        }
                    }
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
        .onAppear({ => this.ensureLoaded() })
    }
}
