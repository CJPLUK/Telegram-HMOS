package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.utils.formatFullDate
import std.collection.ArrayList
import std.time.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * BotReceiptPageArguments — Bot 支付收据详情页（混合工程迁移版）
 *
 * 对应 iOS BotReceiptController / BotReceiptControllerNode 的仓颉移植版本。
 * 路由名 "BotReceiptPage"（MainTabPage.pageMap）→ 类 BotReceiptPageArguments。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（.title/.hideTitleBar 由 ArkTS 壳提供）
 *  - pageStack.pop() → routerPop()
 *  - onReady 参数解析 → takePending("BotReceiptPage") + ensureLoaded()/.onAppear
 *    参数格式: "<peerId>:<accessHash>:<msgId>:<isChannel>"
 */
@HybridComponentEntry
@Component
public class BotReceiptPageArguments {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoading: Bool = true
    @State var errorMsg: String = ""
    @State var receipt: BotPaymentReceipt = BotPaymentReceipt()
    @State var loaded: Bool = false

    var peerId: Int64 = 0
    var peerAccessHash: Int64 = 0
    var msgId: Int32 = 0
    var isChannel: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let param = takePending("BotReceiptPage")
        if (param.size > 0) {
            this.parseParam(param)
            this.loadReceipt()
        }
    }

    private func loadReceipt() {
        let pid = this.peerId
        let pah = this.peerAccessHash
        let mid = this.msgId
        let isCh = this.isChannel
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[BotReceiptPageArguments] loadReceipt peerId=${pid} msgId=${mid}")
            let svc = getBotPaymentsService()
            let result = svc.getPaymentReceipt(pid, pah, mid, isCh)
            launch {
                match (result) {
                    case Some(r) =>
                        this.receipt = r
                        this.isLoading = false
                    case None =>
                        this.errorMsg = "Failed to load receipt"
                        this.isLoading = false
                }
            }
        }
    }

    private func parseParam(param: String): Unit {
        let parts = splitStr(param, ":")
        if (parts.size >= 4) {
            this.peerId = parseInt64(parts[0])
            this.peerAccessHash = parseInt64(parts[1])
            this.msgId = Int32(parseInt64(parts[2]))
            this.isChannel = parts[3] == "1"
        }
    }

    private func splitStr(s: String, sep: String): ArrayList<String> {
        let result = ArrayList<String>()
        var current = ""
        let runes = s.toRuneArray()
        for (r in runes) {
            if (r.toString() == sep) {
                result.add(current)
                current = ""
            } else {
                current = current + r.toString()
            }
        }
        result.add(current)
        return result
    }

    private func parseInt64(s: String): Int64 {
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

    /**
     * P2-028: 可读日期格式化 — 对应 iOS BotReceiptControllerNode date label
     */
    private func formatReceiptDate(timestamp: Int32): String {
        let unixSec = Int64(timestamp)
        let dateStr = formatFullDate(unixSec)
        let dt = DateTime.fromUnixTimeStamp(Duration.second * unixSec).inLocal()
        let h = dt.hour
        let m = dt.minute
        let hStr = if (h < 10) { "0${h}" } else { h.toString() }
        let mStr = if (m < 10) { "0${m}" } else { m.toString() }
        return dateStr + " " + hStr + ":" + mStr
    }

    func build() {
        Column {
            if (this.isLoading) {
                Column {
                    Text("Loading receipt...")
                        .fontSize(16)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .height(300)
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
                Column {
                    // 头部区域: 标题 + 可读日期 (P2-028)
                    Column {
                        Text(trSource("Receipt"))
                            .fontSize(26)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0x000000)
                            .margin(bottom: 4)
                        Text(this.receipt.title)
                            .fontSize(16)
                            .fontColor(0x8E8E93)
                            .margin(bottom: 2)
                        if (this.receipt.description.size > 0) {
                            Text(this.receipt.description)
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                                .margin(bottom: 4)
                        }
                        // P2-028: 可读日期（替代旧 placeholder "Nd HH:MM"）
                        if (this.receipt.date > 0) {
                            Text(this.formatReceiptDate(this.receipt.date))
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(top: 4)
                        }
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                    .padding(top: 24, bottom: 16)

                    // 分隔
                    Divider()
                        .height(1)
                        .backgroundColor(0xE5E5EA)
                        .margin(left: 16, right: 16)

                    // 价格明细
                    List {
                        ForEach(this.receipt.prices.toArray(), itemGenerator: { price: BotPaymentPrice, _idx: Int64 =>
                            ListItem {
                                Row {
                                    Text(price.label)
                                        .fontSize(15)
                                        .fontColor(0x000000)
                                        .flexGrow(1)
                                    Text(formatCurrencyAmount(price.amount, this.receipt.currency))
                                        .fontSize(15)
                                        .fontColor(0x000000)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 10, bottom: 10)
                            }
                        })
                    }
                    .width(100.percent)
                    .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 16, endMargin: 0))

                    // P2-028: 收件人信息行（name / phone / email）
                    if (this.receipt.recipientName.size > 0 || this.receipt.recipientPhone.size > 0 ||
                        this.receipt.recipientEmail.size > 0) {
                        Column {
                            Text(trSource("Recipient"))
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 12, bottom: 4)
                            if (this.receipt.recipientName.size > 0) {
                                Row {
                                    Text(trSource("Name"))
                                        .fontSize(15)
                                        .fontColor(0x8E8E93)
                                        .width(100)
                                    Text(this.receipt.recipientName)
                                        .fontSize(15)
                                        .fontColor(0x000000)
                                        .flexGrow(1)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 6, bottom: 6)
                            }
                            if (this.receipt.recipientPhone.size > 0) {
                                Row {
                                    Text(trSource("Phone"))
                                        .fontSize(15)
                                        .fontColor(0x8E8E93)
                                        .width(100)
                                    Text(this.receipt.recipientPhone)
                                        .fontSize(15)
                                        .fontColor(0x000000)
                                        .flexGrow(1)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 6, bottom: 6)
                            }
                            if (this.receipt.recipientEmail.size > 0) {
                                Row {
                                    Text(trSource("Email"))
                                        .fontSize(15)
                                        .fontColor(0x8E8E93)
                                        .width(100)
                                    Text(this.receipt.recipientEmail)
                                        .fontSize(15)
                                        .fontColor(0x000000)
                                        .flexGrow(1)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 6, bottom: 10)
                            }
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)

                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 16)
                    }

                    // P2-028: 运输方式/地址行（shipping title + PostAddress）
                    if (this.receipt.shippingTitle.size > 0) {
                        Column {
                            Row {
                                Text("Shipping")
                                    .fontSize(15)
                                    .fontColor(0x8E8E93)
                                    .width(100)
                                Text(this.receipt.shippingTitle)
                                    .fontSize(15)
                                    .fontColor(0x000000)
                                    .flexGrow(1)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 10, bottom: 6)

                            // 运输地址（若有）
                            if (this.receipt.recipientStreet1.size > 0) {
                                Column {
                                    Text("Delivery Address")
                                        .fontSize(13)
                                        .fontColor(0x8E8E93)
                                        .width(100.percent)
                                        .padding(left: 16, right: 16, top: 4, bottom: 2)
                                    Text(this.receipt.recipientStreet1 +
                                        (if (this.receipt.recipientStreet2.size > 0) { ", " + this.receipt.recipientStreet2 } else { "" }))
                                        .fontSize(14)
                                        .fontColor(0x000000)
                                        .width(100.percent)
                                        .padding(left: 16, right: 16, top: 2, bottom: 2)
                                    Text(this.receipt.recipientCity +
                                        (if (this.receipt.recipientState.size > 0) { ", " + this.receipt.recipientState } else { "" }) +
                                        " " + this.receipt.recipientPostCode)
                                        .fontSize(14)
                                        .fontColor(0x000000)
                                        .width(100.percent)
                                        .padding(left: 16, right: 16, top: 2, bottom: 2)
                                    Text(this.receipt.recipientCountry)
                                        .fontSize(14)
                                        .fontColor(0x8E8E93)
                                        .width(100.percent)
                                        .padding(left: 16, right: 16, top: 2, bottom: 10)
                                }
                                .width(100.percent)
                            }
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)

                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 16)
                    }

                    // 小费行 (若有)
                    if (this.receipt.tipAmount > 0) {
                        Row {
                            Text(trSource("Tip"))
                                .fontSize(15)
                                .fontColor(0x000000)
                                .flexGrow(1)
                            Text(formatCurrencyAmount(this.receipt.tipAmount, this.receipt.currency))
                                .fontSize(15)
                                .fontColor(0x000000)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 10, bottom: 10)

                        Divider()
                            .height(1)
                            .backgroundColor(0xE5E5EA)
                            .margin(left: 16, right: 16)
                    }

                    // 总金额
                    Row {
                        Text(trSource("Total Paid"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                            .flexGrow(1)
                        Text(formatCurrencyAmount(this.receipt.totalAmount, this.receipt.currency))
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x007AFF)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 12, bottom: 12)

                    Divider()
                        .height(1)
                        .backgroundColor(0xE5E5EA)
                        .margin(left: 16, right: 16)

                    // 支付方式
                    if (this.receipt.credentialsTitle.size > 0) {
                        Row {
                            Text(trSource("Payment Method"))
                                .fontSize(15)
                                .fontColor(0x8E8E93)
                                .flexGrow(1)
                            Text(this.receipt.credentialsTitle)
                                .fontSize(15)
                                .fontColor(0x000000)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 10, bottom: 10)
                    }

                    // 关闭按钮
                    Button(trSource("Done"))
                        .width(100.percent)
                        .height(50)
                        .borderRadius(12)
                        .backgroundColor(0x007AFF)
                        .fontColor(0xFFFFFF)
                        .fontSize(17)
                        .margin(left: 16, right: 16, top: 24, bottom: 24)
                        .onClick({ _evt =>
                            routerPop()
                        })
                }
                .width(100.percent)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
