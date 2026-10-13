package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.app.setPendingDeepLink
import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings, trOr, trSource}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.getPremiumService

public class BusinessPerkItem {
    public let id: String
    public let title: String
    public let text: String
    public init(id!: String, title!: String, text!: String) { this.id = id; this.title = title; this.text = text }
}

public func businessPerks(): Array<BusinessPerkItem> {
    return [
        BusinessPerkItem(id: "location", title: trOr("Premium.Business.Location.Title", "Location"), text: trOr("Premium.Business.Location.Text", "Display the location of your business on your account.")),
        BusinessPerkItem(id: "hours", title: trOr("Premium.Business.Hours.Title", "Opening Hours"), text: trOr("Premium.Business.Hours.Text", "Show to your customers when you are open for business.")),
        BusinessPerkItem(id: "replies", title: trOr("Premium.Business.Replies.Title", "Quick Replies"), text: trOr("Premium.Business.Replies.Text", "Set up shortcuts with rich text and media to respond to messages faster.")),
        BusinessPerkItem(id: "greetings", title: trOr("Premium.Business.Greetings.Title", "Greeting Messages"), text: trOr("Premium.Business.Greetings.Text", "Create greetings that will be automatically sent to new customers.")),
        BusinessPerkItem(id: "away", title: trOr("Premium.Business.Away.Title", "Away Messages"), text: trOr("Premium.Business.Away.Text", "Define messages that are automatically sent when you are off.")),
        BusinessPerkItem(id: "links", title: trOr("Premium.Business.Links.Title", "Links"), text: trOr("Premium.Business.Links.Text", "Create links that start a chat with you, suggesting the first message.")),
        BusinessPerkItem(id: "intro", title: trOr("Premium.Business.Intro.Title", "Intro"), text: trOr("Premium.Business.Intro.Text", "Customize the message people see before they start a chat with you.")),
        BusinessPerkItem(id: "chatbots", title: trOr("Premium.Business.Chatbots.Title", "Chatbots"), text: trOr("Premium.Business.Chatbots.Text", "Add any third party chatbots that will process customer interactions."))
    ]
}

@HybridComponentEntry
@Component
public class PremiumBusinessPage {
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()
    @State var prices: Array<PremiumPriceInfo> = Array<PremiumPriceInfo>(0, repeat: PremiumPriceInfo())
    @State var purchaseUrls: Array<String> = Array<String>(0, repeat: "")
    @State var selected: Int64 = 0
    @State var loaded: Bool = false

    private func load(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let _ = spawn {
            let result = getPremiumService().getPremiumPromo()
            let values = PremiumPriceCalculator.buildPriceInfoList(options: result.periodOptions)
            let urls = Array<String>(result.periodOptions.size, { i: Int64 => result.periodOptions[i].botUrl })
            launch {
                this.prices = values
                this.purchaseUrls = urls
            }
        }
    }

    /** Mirrors PremiumIntroScreen.State.buy(): use the selected server purchase URL in place. */
    private func subscribe(): Unit {
        if (this.selected < 0 || this.selected >= this.purchaseUrls.size) { return }
        let url = this.purchaseUrls[this.selected]
        if (url.size > 0) { setPendingDeepLink(url) }
    }

    private func periodLabel(months: Int32): String {
        if (months == 12) { return "Annual" }
        if (months == 1) { return "Monthly" }
        return "${months} Months"
    }

    private func subscribeTitle(): String {
        if (this.selected >= 0 && this.selected < this.prices.size) {
            let info = this.prices[this.selected]
            if (info.formattedTotalPrice.size > 0) {
                let unit = if (info.months == 12) { "year" } else { "month" }
                return "Subscribe for ${info.formattedTotalPrice} / ${unit}"
            }
        }
        return trSource("Subscribe to Telegram Premium")
    }

    @Builder
    private func businessCoin() {
        Stack(alignContent: Alignment.Center) {
            Image(@r(app.media.business_coin)).width(128).height(128)
        }.width(100.percent).height(158)
    }

    @Builder
    private func planRow(info: PremiumPriceInfo, index: Int64) {
        Row {
            Stack(alignContent: Alignment.Center) {
                Circle().width(22).height(22).fill(if (this.selected == index) { 0xFF0A84FF } else { Color.Transparent })
                    .stroke(if (this.selected == index) { 0xFF0A84FF } else { 0xFFC7C7CC }).strokeWidth(1.5)
                if (this.selected == index) { Circle().width(8).height(8).fill(0xFFFFFFFF) }
            }.width(28).height(28).margin(right: 10)
            Column {
                Text(this.periodLabel(info.months)).fontSize(17).fontColor(0xFF111111)
                Text("${info.months} months · ${info.formattedTotalPrice}").fontSize(13).fontColor(0xFF8E8E93).margin(top: 2)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (info.discountPercent > 0) {
                Text("-${info.discountPercent}%").fontSize(13).fontColor(0xFFFFFFFF)
                    .padding(left: 7, right: 7, top: 3, bottom: 3).borderRadius(10).backgroundColor(0xFF34C759).margin(right: 8)
            }
            Text("${info.formattedMonthlyPrice}/month").fontSize(15).fontColor(0xFF111111)
        }.width(100.percent).padding(left: 15, right: 15, top: 12, bottom: 12)
            .backgroundColor(0xFFFFFFFF).onClick({ _ => this.selected = index })
    }

    @Builder
    private func perkIcon(id: String) {
        Stack(alignContent: Alignment.Center) {
            Column { }.width(40).height(40).borderRadius(10).backgroundColor(this.perkColor(id))
            if (id == "location") { Image(@r(app.media.business_location)).width(26).height(26).fillColor(0xFFFFFFFF) }
            else if (id == "hours") { Image(@r(app.media.business_hours)).width(26).height(26).fillColor(0xFFFFFFFF) }
            else if (id == "replies") { Image(@r(app.media.business_replies)).width(26).height(26).fillColor(0xFFFFFFFF) }
            else if (id == "greetings") { Image(@r(app.media.business_greetings)).width(26).height(26).fillColor(0xFFFFFFFF) }
            else if (id == "away") { Image(@r(app.media.business_away)).width(26).height(26).fillColor(0xFFFFFFFF) }
            else if (id == "links") { Image(@r(app.media.business_links)).width(26).height(26).fillColor(0xFFFFFFFF) }
            else if (id == "intro") { Image(@r(app.media.business_intro)).width(26).height(26).fillColor(0xFFFFFFFF) }
            else { Image(@r(app.media.business_chatbots)).width(26).height(26).fillColor(0xFFFFFFFF) }
        }.width(40).height(40)
    }

    private func perkColor(id: String): Int64 {
        if (id == "location") { return 0xFFEF6922 }
        if (id == "hours") { return 0xFFE54937 }
        if (id == "replies") { return 0xFFDB374B }
        if (id == "greetings") { return 0xFFBC4395 }
        if (id == "away") { return 0xFF9B4FED }
        if (id == "links") { return 0xFF8958FF }
        if (id == "intro") { return 0xFF676BFF }
        return 0xFF0088FF
    }

    private func demoIdentifier(id: String): String {
        if (id == "location") { return "business_location" }
        if (id == "hours") { return "business_hours" }
        if (id == "replies") { return "quick_replies" }
        if (id == "greetings") { return "greeting_message" }
        if (id == "away") { return "away_message" }
        if (id == "links") { return "business_links" }
        if (id == "intro") { return "business_intro" }
        return "business_bots"
    }

    @Builder
    private func perkRow(item: BusinessPerkItem) {
        Row {
            this.perkIcon(item.id)
            Column {
                Text(item.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(0xFF111111)
                Text(item.text).fontSize(14).fontColor(0xFF6D6D72).lineHeight(19).margin(top: 2)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin(left: 14)
            Image(@r(app.media.settings_ic_text_arrow_right)).width(8).height(14).fillColor(0xFFC7C7CC).margin(left: 8)
        }.width(100.percent).padding(left: 16, right: 16, top: 12, bottom: 12).backgroundColor(0xFFFFFFFF)
            .onClick({ _ => routerPush("PremiumDemoPage", this.demoIdentifier(item.id)) })
    }

    public func build() {
        Column {
            Row {
                Button {
                    Image(@r(app.media.nav_back_arrow_legacy)).width(18).height(18).fillColor(0xFF111111)
                }.width(36).height(36).borderRadius(18).backgroundColor(0xE8FFFFFF).onClick({ _ => routerPop() })
                Blank()
            }.height(48).width(100.percent).padding(left: 12, right: 12)
            Scroll {
                Column {
                    this.businessCoin()
                    Text(trOr("Premium.Business", "Telegram Business")).fontSize(27).fontWeight(FontWeight.Bold).fontColor(0xFF111111)
                    Text("Turn your account into a business page with these additional features by subscribing to Telegram Premium.")
                        .fontSize(15).fontColor(0xFF55555A).textAlign(TextAlign.Center).lineHeight(21)
                        .padding(left: 24, right: 24).margin(top: 8, bottom: 18)
                    if (this.prices.size > 0) {
                        Column {
                            ForEach(this.prices, itemGenerator: { info: PremiumPriceInfo, idx: Int64 =>
                                if (idx > 0) { Divider().strokeWidth(0.5).color(0xFFD7D7DA).margin(left: 53) }
                                this.planRow(info, idx)
                            })
                        }.borderRadius(12).clip(true).margin(left: 16, right: 16, bottom: 16)
                    }
                    Column {
                        ForEach(businessPerks(), itemGenerator: { item: BusinessPerkItem, idx: Int64 =>
                            if (idx > 0) { Divider().strokeWidth(0.5).color(0xFFE0E0E3).margin(left: 60) }
                            this.perkRow(item)
                        })
                    }.borderRadius(12).clip(true).margin(left: 16, right: 16, bottom: 92)
                }.width(100.percent)
            }.layoutWeight(1).scrollBar(BarState.Off)
            Button(this.subscribeTitle()).width(100.percent).height(50).margin(left: 16, right: 16, top: 8, bottom: 8.0 + getSafeAreaBottom())
                .fontSize(17).fontWeight(FontWeight.Medium).fontColor(0xFFFFFFFF).borderRadius(12)
                .linearGradient(angle: 90.0, colors: [(Color(0xFF9B65EE), 0.0), (Color(0xFF5474EC), 0.55), (Color(0xFF35AEEB), 1.0)])
                .onClick({ _ => this.subscribe() })
        }.width(100.percent).height(100.percent).padding(top: getSafeAreaTop()).backgroundColor(0xFFF2F2F7).onAppear({ => this.load() })
    }
}
