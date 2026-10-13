package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import std.collection.ArrayList
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings, trOr, trSource}
import ohos_app_cangjie_entry.providers.{PaymentsDataProvider, StarsTransactionViewModel, StarsTopupOptionViewModel, StarsTopupOptionsViewModel, formatCurrencyAmount}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.*
import ohos_app_cangjie_entry.services.getInAppPurchaseManagerService
import ohos_app_cangjie_entry.core.mtproto.InputStorePaymentStarsTopup
import ohos_app_cangjie_entry.utils.formatTonAmountString

private func starsJsonOk(json: String): Bool {
    match (json.indexOf("\"ok\"")) { case Some(i) => return json[i..json.size].contains("true"); case None => return false }
}

private func starsJsonReceipt(json: String): String {
    let needle = "\"receipt\""
    match (json.indexOf(needle)) {
        case Some(i) =>
            let tail = json[(i + needle.size)..json.size]
            match (tail.indexOf("\"")) {
                case Some(a) =>
                    let value = tail[(a + 1)..tail.size]
                    match (value.indexOf("\"")) { case Some(b) => return value[0..b]; case None => return "" }
                case None => return ""
            }
        case None => return ""
    }
}

@HybridComponentEntry
@Component
public class StarsPage {
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false
    @State var loading: Bool = true
    @State var balance: Int64 = 0
    @State var errorText: String = ""
    @State var transactions: ArrayList<StarsTransactionViewModel> = ArrayList<StarsTransactionViewModel>()
    @State var topupOptions: ArrayList<StarsTopupOptionViewModel> = ArrayList<StarsTopupOptionViewModel>()
    @State var showTopup: Bool = false
    @State var txFilter: Int32 = 0
    @State var purchasing: Bool = false
    @State var purchaseError: String = ""
    @State var isTon: Bool = false

    private func load(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let routeParam = takePending("StarsPage")
        this.isTon = routeParam == "ton"
        let tonMode = this.isTon
        let _ = spawn {
            let provider = PaymentsDataProvider()
            let state = if (tonMode) { provider.getTonStatus() } else { provider.getStarsStatus() }
            let options = if (tonMode) { StarsTopupOptionsViewModel() } else { provider.getStarsTopupOptions() }
            launch {
                this.balance = state.balanceStars
                this.transactions = state.transactions
                this.topupOptions = options.options
                this.errorText = if (!state.loaded) { state.errorMessage } else { "" }
                this.loading = false
                if (routeParam == "topup" && !tonMode) { this.showTopup = true }
            }
        }
    }

    private func amountText(tx: StarsTransactionViewModel): String {
        let prefix = if (tx.starsAmount > 0) { "+" } else { "" }
        if (this.isTon) { return "${prefix}${formatTonAmountString(tx.starsAmount, ".", false, None)} GRAM" }
        return "${prefix}${tx.starsAmount}"
    }

    private func optionPrice(opt: StarsTopupOptionViewModel): String {
        return formatCurrencyAmount(opt.currency, opt.amount)
    }

    private func purchaseTopup(opt: StarsTopupOptionViewModel): Unit {
        if (this.purchasing || opt.storeProduct.size == 0) { return }
        let purpose = InputStorePaymentStarsTopup()
        purpose.stars = opt.stars
        purpose.currency = opt.currency
        purpose.amount = opt.amount
        this.purchasing = true
        this.purchaseError = ""
        let _ = spawn {
            let allowed = getInAppPurchaseManagerService().canPurchaseStorePurpose(purpose)
            launch {
                if (!allowed) {
                    this.purchasing = false
                    this.purchaseError = "This purchase is not available for this account."
                } else {
                    let arg = "{\"productId\":\"${opt.storeProduct}\",\"productType\":0}"
                    callArkAsync(IAP_RECEIPT, arg, { result: String =>
                        if (!starsJsonOk(result)) {
                            launch { this.purchasing = false; this.purchaseError = "Purchase was cancelled or could not be completed." }
                            return
                        }
                        let receipt = starsJsonReceipt(result)
                        let _ = spawn {
                            let sent = getInAppPurchaseManagerService().sendStoreReceipt(receipt.toArray(), purpose)
                            let state = PaymentsDataProvider().getStarsStatus()
                            launch {
                                this.purchasing = false
                                if (sent) { this.balance = state.balanceStars; this.showTopup = false }
                                else { this.purchaseError = "Telegram could not confirm this purchase." }
                            }
                        }
                    })
                }
            }
        }
    }

    @Builder
    private func hero() {
        Column {
            Stack(alignContent: Alignment.Center) {
                if (this.isTon) {
                    Text("◆").fontSize(112).fontColor(0xFF0098EA)
                } else {
                    Image(@r(app.media.premium_star_intro)).width(100.percent).height(165).objectFit(ImageFit.Contain)
                }
            }.width(100.percent).height(165)
            Text(if (this.isTon) { "GRAM" } else { trOr("Stars.Intro.Title", "Telegram Stars") }).fontSize(28).fontWeight(FontWeight.Bold).fontColor(0xFF111111)
            Text(if (this.isTon) { "Use GRAM to submit post suggestions to channels on Telegram." } else { trOr("Stars.Intro.Description", "Buy Stars to unlock content and services in mini apps on Telegram.") })
                .fontSize(15).fontColor(0xFF55555A).textAlign(TextAlign.Center).lineHeight(21)
                .padding(left: 32, right: 32).margin(top: 8, bottom: 18)
        }.width(100.percent)
    }

    @Builder
    private func balanceCard() {
        Column {
            Row {
                if (this.isTon) { Text("◆").fontSize(29).fontColor(0xFF0098EA).margin(right: 6) }
                else { Image(@r(app.media.stars_balance)).width(31).height(31).margin(right: 5) }
                Text(if (this.isTon) { formatTonAmountString(this.balance, ".", false, None) } else { "${this.balance}" }).fontSize(31).fontWeight(FontWeight.Bold).fontColor(0xFF111111)
            }.justifyContent(FlexAlign.Center).width(100.percent)
            Text(trOr("Stars.Intro.YourBalance", "your balance")).fontSize(13).fontColor(0xFF8E8E93).margin(top: 2, bottom: 13)
            if (!this.isTon) {
                Button("+  ${trOr("Stars.Intro.Buy", "Buy More Stars")}")
                    .width(100.percent).height(46).borderRadius(10).backgroundColor(0xFF007AFF).fontSize(17).fontColor(0xFFFFFFFF)
                    .onClick({ _ => this.showTopup = true })
                Row {
                    Image(@r(app.media.stars_gift)).width(23).height(23).margin(right: 9)
                    Text(trOr("Stars.Intro.GiftStars", "Gift Stars to Friends")).fontSize(17).fontColor(0xFF007AFF)
                }.height(46).width(100.percent).justifyContent(FlexAlign.Center).onClick({ _ => routerPush("PremiumGiftPage", "stars") })
            }
        }.width(100.percent).padding(left: 14, right: 14, top: 17, bottom: 4)
            .backgroundColor(0xFFFFFFFF).borderRadius(12).margin(left: 16, right: 16)
    }

    @Builder
    private func transactionRow(tx: StarsTransactionViewModel) {
        Row {
            Stack(alignContent: Alignment.Center) {
                Circle().width(40).height(40).fill(if (this.isTon) { 0xFF0098EA } else { 0xFFFFB83D })
                if (this.isTon) { Text("◆").fontSize(23).fontColor(0xFFFFFFFF) }
                else { Image(@r(app.media.stars_large)).width(24).height(24) }
            }.margin(right: 12)
            Column {
                Text(if (tx.title.size > 0) { tx.title } else if (this.isTon) { "GRAM" } else { "Telegram Stars" }).fontSize(16).fontColor(0xFF111111).maxLines(1)
                Text(tx.description).fontSize(13).fontColor(0xFF8E8E93).maxLines(1).margin(top: 2)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Text(this.amountText(tx)).fontSize(16).fontWeight(FontWeight.Medium)
                .fontColor(if (tx.starsAmount >= 0) { 0xFF34C759 } else { 0xFF111111 })
        }.width(100.percent).padding(left: 16, right: 16, top: 10, bottom: 10).backgroundColor(0xFFFFFFFF)
    }

    @Builder
    private func earnCard() {
        Column {
            Text("Earn Stars").fontSize(17).fontWeight(FontWeight.Medium).fontColor(0xFF111111).width(100.percent).margin(bottom: 11)
            Row {
                Stack(alignContent: Alignment.Center) {
                    Circle().width(42).height(42).fill(0xFF34C759)
                    Text("↗").fontSize(25).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                }.margin(right: 12)
                Text("Distribute links to mini apps and earn a share of their revenue in Stars.")
                    .fontSize(15).fontColor(0xFF111111).lineHeight(20).layoutWeight(1)
            }.width(100.percent)
        }.width(100.percent).padding(14).backgroundColor(0xFFFFFFFF).borderRadius(12)
            .margin(left: 16, right: 16, top: 22, bottom: 28)
    }

    @Builder
    private func topupSheet() {
        Stack(alignContent: Alignment.Bottom) {
            Column { }.width(100.percent).height(100.percent).backgroundColor(0x66000000).onClick({ _ => this.showTopup = false })
            Column {
                Row {
                    Button {
                        Image(@r(app.media.nav_ic_close)).width(15).height(15).fillColor(0xFF111111)
                    }.width(34).height(34).borderRadius(17).backgroundColor(0xFFE5E5EA)
                        .onClick({ _ => this.showTopup = false })
                    Blank()
                    Text("Buy Stars").fontSize(18).fontWeight(FontWeight.Bold).margin(right: 34)
                    Blank()
                }.height(52).width(100.percent).padding(left: 12, right: 12)
                if (this.topupOptions.size == 0) {
                    Text("No purchase options are available for this account.").fontSize(15).fontColor(0xFF8E8E93).padding(30)
                } else {
                    Scroll {
                        Column {
                            ForEach(this.topupOptions, itemGenerator: { opt: StarsTopupOptionViewModel, idx: Int64 =>
                                if (idx > 0) { Divider().strokeWidth(0.5).color(0xFFE0E0E3).margin(left: 58) }
                                Row {
                                    Image(@r(app.media.stars_large)).width(34).height(34).margin(right: 12)
                                    Text("${opt.stars} Stars").fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1)
                                    Text(this.optionPrice(opt)).fontSize(17).fontColor(0xFF007AFF)
                                }.height(58).width(100.percent).padding(left: 16, right: 16)
                                    .onClick({ _ => this.purchaseTopup(opt) })
                            })
                            if (this.purchaseError.size > 0) {
                                Text(this.purchaseError).fontSize(13).fontColor(0xFFFF3B30).textAlign(TextAlign.Center)
                                    .width(100.percent).padding(12)
                            }
                        }.backgroundColor(0xFFFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16, bottom: 20.0 + getSafeAreaBottom())
                    }.layoutWeight(1)
                }
            }.width(100.percent).height(72.percent).backgroundColor(0xFFF2F2F7).borderRadius(topLeft: 14, topRight: 14)
        }.width(100.percent).height(100.percent).zIndex(20)
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Column {
                Row {
                    Button {
                        Image(@r(app.media.nav_back_arrow_legacy)).width(18).height(18).fillColor(0xFF111111)
                    }.width(36).height(36).borderRadius(18).backgroundColor(0xE8FFFFFF).onClick({ _ => routerPop() })
                    Blank()
                }.height(48).width(100.percent).padding(left: 12)
                if (this.loading) {
                    Column { LoadingProgress().width(36).height(36) }.layoutWeight(1).width(100.percent).justifyContent(FlexAlign.Center)
                } else {
                    Scroll {
                        Column {
                            this.hero()
                            this.balanceCard()
                            if (this.transactions.size > 0) {
                                Text(if (this.isTon) { "GRAM Transactions" } else { "Transactions" }).fontSize(13).fontColor(0xFF8E8E93).width(100.percent).padding(left: 16).margin(top: 22, bottom: 7)
                                Column {
                                    ForEach(this.transactions, itemGenerator: { tx: StarsTransactionViewModel, idx: Int64 =>
                                        if (idx > 0) { Divider().strokeWidth(0.5).color(0xFFE0E0E3).margin(left: 68) }
                                        this.transactionRow(tx)
                                    })
                                }.borderRadius(12).clip(true).margin(left: 16, right: 16)
                            } else if (!this.isTon) { this.earnCard() }
                        }.width(100.percent)
                    }.layoutWeight(1).scrollBar(BarState.Off)
                }
            }.width(100.percent).height(100.percent).padding(top: getSafeAreaTop()).backgroundColor(0xFFF2F2F7)
            if (this.showTopup) { this.topupSheet() }
        }.width(100.percent).height(100.percent).onAppear({ => this.load() })
    }
}
