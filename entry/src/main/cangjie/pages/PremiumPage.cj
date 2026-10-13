package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import std.collection.ArrayList
import std.sync.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom, setPendingDeepLink}
import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings, trOr, trSource}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.{getPremiumService, PremiumPromoResult}

/** Source counterpart of PremiumIntroScreen(source:). */
@HybridComponentEntry
@Component
public class PremiumPage {
    public var embedded: Bool = false
    public var onClose: () -> Unit = { => }
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()
    @State var perkItems: Array<PremiumPerkItem> = Array<PremiumPerkItem>(0, repeat: PremiumPerkItem(title: "", subtitle: "", icon: "", identifier: ""))
    @State var priceInfoList: Array<PremiumPriceInfo> = Array<PremiumPriceInfo>(0, repeat: PremiumPriceInfo())
    @State var purchaseUrls: Array<String> = Array<String>(0, repeat: "")
    @State var selectedOptionIndex: Int64 = 0
    @State var isLoading: Bool = true
    @State var loaded: Bool = false
    @State var starScale: Float32 = 0.87
    @State var starRotation: Float32 = 0.0
    @State var starShineX: Float64 = -120.0
    @State var starParticlesVisible: Bool = false
    private var starIdleTimer: Option<Timer> = None<Timer>

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.startStarAnimation()
        let _ = takePending("PremiumPage")
        this.perkItems = getPremiumPerkList()
        let _ = spawn {
            let result = getPremiumService().getPremiumPromo()
            let serverPerks = this.serverOrderedPerks(result)
            let prices = PremiumPriceCalculator.buildPriceInfoList(options: result.periodOptions)
            let urls = Array<String>(result.periodOptions.size, { i: Int64 => result.periodOptions[i].botUrl })
            launch {
                if (serverPerks.size > 0) { this.perkItems = serverPerks }
                this.priceInfoList = prices
                this.purchaseUrls = urls
                this.selectedOptionIndex = 0
                this.isLoading = false
            }
        }
    }

    private func startStarAnimation(): Unit {
        let _ = Timer.once(Duration.millisecond * 50, { =>
            launch {
                this.starScale = 1.0
                this.starRotation = 360.0
                this.starShineX = 120.0
                this.starParticlesVisible = true
            }
        })
        this.starIdleTimer = Some(Timer.repeat(Duration.second * 5, Duration.second * 5, { =>
            launch { this.playStarAppearance() }
        }))
    }

    private func playStarAppearance(): Unit {
        this.starRotation = this.starRotation + 360.0
        this.starShineX = if (this.starShineX > 0.0) { -120.0 } else { 120.0 }
        this.starParticlesVisible = !this.starParticlesVisible
    }

    @Builder
    private func starParticle(x: Int64, y: Int64, size: Int64, delay: Int32, duration: Int32, color: UInt32) {
        Text("✦")
            .fontSize(size).fontColor(color).position(x: x, y: y)
            .opacity(if (this.starParticlesVisible) { 0.95 } else { 0.12 })
            .scale(x: if (this.starParticlesVisible) { 1.15f32 } else { 0.42f32 },
                   y: if (this.starParticlesVisible) { 1.15f32 } else { 0.42f32 })
            .animation(AnimateParam(duration: duration, curve: Curve.EaseInOut,
                delay: delay, iterations: -1, playMode: PlayMode.Alternate))
    }

    public override func aboutToDisappear(): Unit {
        match (this.starIdleTimer) {
            case Some(t) => t.cancel(); this.starIdleTimer = None<Timer>
            case None => ()
        }
    }

    @Builder
    private func premiumStar() {
        Stack(alignContent: Alignment.Center) {
            this.starParticle(34, 24, 15, 0, 1250, 0xFF8D72F6)
            this.starParticle(78, 66, 8, 280, 1700, 0xFFE277DA)
            this.starParticle(112, 18, 11, 560, 1450, 0xFF6A94FF)
            this.starParticle(146, 86, 7, 120, 1900, 0xFFE277DA)
            this.starParticle(184, 34, 13, 760, 1600, 0xFF8D72F6)
            this.starParticle(224, 70, 9, 410, 1350, 0xFF6A94FF)
            this.starParticle(268, 20, 16, 650, 1800, 0xFFE277DA)
            this.starParticle(314, 58, 8, 180, 1500, 0xFF8D72F6)
            this.starParticle(352, 28, 12, 850, 1950, 0xFF6A94FF)
            this.starParticle(48, 108, 10, 520, 1550, 0xFFE277DA)
            this.starParticle(96, 126, 14, 90, 1850, 0xFF8D72F6)
            this.starParticle(286, 120, 13, 720, 1400, 0xFFE277DA)
            this.starParticle(338, 102, 9, 340, 1750, 0xFF6A94FF)
            Circle().width(92).height(92).fill(0x227B6CF6)
                .scale(x: this.starScale, y: this.starScale)
                .animation(AnimateParam(duration: 2000, curve: Curve.EaseInOut,
                    iterations: -1, playMode: PlayMode.Alternate))
            Stack(alignContent: Alignment.Center) {
                Image(@r(app.media.set2_ic_premiumstar)).width(112).height(112)
                    .fillColor(0xFF7B6CF6)
                Column { }.width(26).height(130).backgroundColor(0x55FFFFFF)
                    .rotate(angle: 22.0).translate(x: this.starShineX)
                    .animation(AnimateParam(duration: 900, curve: Curve.EaseOut,
                        delay: 1100, iterations: -1, playMode: PlayMode.Normal))
            }.width(118).height(118).clip(true)
                .rotate(angle: this.starRotation)
                .animation(AnimateParam(duration: 850, curve: Curve.Friction))
        }
        .width(100.percent).height(if (this.embedded) { 130 } else { 220 })
        .onClick({ _ => this.playStarAppearance() })
    }

    private func serverOrderedPerks(result: PremiumPromoResult): Array<PremiumPerkItem> {
        let ordered = ArrayList<PremiumPerkItem>()
        let all = getPremiumPerkList()
        for (identifier in result.videoSections) {
            for (perk in all) {
                if (perk.identifier == identifier) { ordered.add(perk); break }
            }
        }
        return Array<PremiumPerkItem>(ordered.size, { i: Int64 => ordered[i] })
    }

    private func selectedPrice(): String {
        if (this.selectedOptionIndex >= 0 && this.selectedOptionIndex < this.priceInfoList.size) {
            return this.priceInfoList[this.selectedOptionIndex].formattedTotalPrice
        }
        return ""
    }

    private func subscribeTitle(): String {
        let price = this.selectedPrice()
        return if (price.size > 0) { "Subscribe for ${price}" } else { trSource("Subscribe to Telegram Premium") }
    }

    /** Mirrors PremiumIntroScreen.State.buy()'s no-store-product branch. */
    private func subscribe(): Unit {
        if (this.selectedOptionIndex < 0 || this.selectedOptionIndex >= this.purchaseUrls.size) { return }
        let url = this.purchaseUrls[this.selectedOptionIndex]
        if (url.size > 0) { setPendingDeepLink(url) }
    }

    private func periodLabel(months: Int32): String {
        if (months == 1) { return "1 Month" }
        if (months == 12) { return "1 Year" }
        return "${months} Months"
    }

    @Builder
    private func header() {
        Column {
            this.premiumStar()
            Text(trSource("Telegram Premium"))
                .fontSize(28).fontWeight(FontWeight.Bold).fontColor(0xFF111111).margin(top: 8)
            Text(trOr("Premium.Description", "Go beyond the limits, get exclusive features and support us by subscribing to Telegram Premium."))
                .fontSize(15).fontColor(0xFF111111).textAlign(TextAlign.Center)
                .padding(left: 30, right: 30).margin(top: 10)
        }
        .width(100.percent).alignItems(HorizontalAlign.Center)
        .padding(top: if (this.embedded) { 0.0 } else { 54.0 + getSafeAreaTop() }, bottom: 21)
        .linearGradient(angle: 180.0, colors: [
            (Color(0xFFFFFFFF), 0.0),
            (Color(0xFFF8F5FF), 0.62),
            (Color(0xFFF2F2F7), 1.0)
        ])
    }

    @Builder
    private func planRow(info: PremiumPriceInfo, index: Int64) {
        Row {
            Stack(alignContent: Alignment.Center) {
                Circle().width(22).height(22)
                    .fill(if (this.selectedOptionIndex == index) { 0xFF0A84FF } else { Color.Transparent })
                    .stroke(if (this.selectedOptionIndex == index) { 0xFF0A84FF } else { 0xFFC7C7CC })
                    .strokeWidth(1.5)
                if (this.selectedOptionIndex == index) { Circle().width(8).height(8).fill(0xFFFFFFFF) }
            }.width(28).height(28).margin(right: 10)
            Column {
                Text(this.periodLabel(info.months)).fontSize(17).fontColor(0xFF111111)
                if (info.discountPercent > 0) {
                    Text("${info.formattedMonthlyPrice} per month").fontSize(13).fontColor(0xFF8E8E93).margin(top: 2)
                }
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (info.discountPercent > 0) {
                Text("-${info.discountPercent}%")
                    .fontSize(13).fontWeight(FontWeight.Medium).fontColor(0xFFFFFFFF)
                    .padding(left: 7, right: 7, top: 3, bottom: 3)
                    .borderRadius(10).backgroundColor(0xFF34C759).margin(right: 9)
            }
            Text(info.formattedTotalPrice).fontSize(17).fontColor(0xFF111111)
        }
        .width(100.percent).padding(left: 16, right: 16, top: 13, bottom: 13)
        .backgroundColor(0xFFFFFFFF).onClick({ _ => this.selectedOptionIndex = index })
    }

    @Builder
    private func perkIcon(item: PremiumPerkItem, index: Int64) {
        Stack(alignContent: Alignment.Center) {
            Column { }.width(40).height(40).borderRadius(12)
                .backgroundColor(if ((index % 6) == 0) { 0xFFEF6922 } else if ((index % 6) == 1) { 0xFFE54937 } else if ((index % 6) == 2) { 0xFFBC4395 } else if ((index % 6) == 3) { 0xFF8958FF } else if ((index % 6) == 4) { 0xFF5B79FF } else { 0xFF3DBD4A })
            if (item.identifier == "more_upload") {
                Image(@r(app.media.dataus_ic_upload)).width(23).height(23).fillColor(0xFFFFFFFF)
            } else if (item.identifier == "faster_download") {
                Image(@r(app.media.dataus_ic_download)).width(23).height(23).fillColor(0xFFFFFFFF)
            } else if (item.identifier == "translations") {
                Image(@r(app.media.chatroom_ic_translate)).width(23).height(23).fillColor(0xFFFFFFFF)
            } else if (item.identifier == "premium_stickers") {
                Image(@r(app.media.chatroom_ic_stickers)).width(23).height(23).fillColor(0xFFFFFFFF)
            } else if (item.identifier == "animated_emoji" || item.identifier == "emoji_status") {
                Image(@r(app.media.chatroom_ic_emoji)).width(23).height(23).fillColor(0xFFFFFFFF)
            } else if (item.identifier == "infinite_reactions") {
                Image(@r(app.media.setroot_ds_reactions)).width(23).height(23)
            } else if (item.identifier == "advanced_chat_management" || item.identifier == "folder_tags") {
                Image(@r(app.media.setroot_folders)).width(23).height(23)
            } else if (item.identifier == "business") {
                Image(@r(app.media.setroot_business)).width(23).height(23)
            } else {
                Image(@r(app.media.set2_ic_premiumstar)).width(22).height(22).fillColor(0xFFFFFFFF)
            }
        }.width(40).height(40)
    }

    @Builder
    private func perkRow(item: PremiumPerkItem, index: Int64) {
        Row {
            this.perkIcon(item, index)
            Column {
                Text(item.title).fontSize(17).fontColor(0xFF111111).maxLines(1)
                Text(item.subtitle).fontSize(13).fontColor(0xFF8E8E93).maxLines(2).margin(top: 2)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin(left: 12)
            Text("›").fontSize(26).fontColor(0xFFC7C7CC).margin(left: 6)
        }
        .width(100.percent).padding(left: 16, right: 13, top: 10, bottom: 10)
        .backgroundColor(0xFFFFFFFF).onClick({ _ => routerPush("PremiumDemoPage", item.identifier) })
    }

    public func build() {
        Column {
            Stack(alignContent: Alignment.TopStart) {
                Scroll {
                Column {
                    this.header()
                    if (this.priceInfoList.size > 1) {
                        Column {
                            ForEach(this.priceInfoList, itemGenerator: { info: PremiumPriceInfo, idx: Int64 =>
                                if (idx > 0) { Divider().strokeWidth(0.5).color(0xFFD7D7DA).margin(left: 54) }
                                this.planRow(info, idx)
                            })
                        }.margin(left: 16, right: 16, bottom: 18).borderRadius(26).clip(true)
                    }
                    Text(trOr("Premium.WhatsIncluded", "WHAT'S INCLUDED"))
                        .fontSize(13).fontColor(0xFF7A7A80).width(100.percent).padding(left: 32, bottom: 7)
                    if (this.isLoading && this.perkItems.size == 0) {
                        Column { LoadingProgress().width(28).height(28) }.width(100.percent).height(140)
                    } else {
                        Column {
                            ForEach(this.perkItems, itemGenerator: { item: PremiumPerkItem, idx: Int64 =>
                                if (idx > 0) { Divider().strokeWidth(0.5).color(0xFFD7D7DA).margin(left: 68) }
                                this.perkRow(item, idx)
                            })
                        }.margin(left: 16, right: 16).borderRadius(26).clip(true).backgroundColor(0xFFFFFFFF)
                    }
                    Text("Terms of Service  ·  Privacy Policy")
                        .fontSize(13).fontColor(0xFF0A84FF).width(100.percent)
                        .textAlign(TextAlign.Center).margin(top: 22, bottom: 104.0 + getSafeAreaBottom())
                }.width(100.percent)
                }.width(100.percent).height(100.percent).scrollBar(BarState.Off)

                Button { Text("×").fontSize(27).fontWeight(FontWeight.Medium).fontColor(0xFF222222) }
                    .width(44).height(44).borderRadius(22).backgroundColor(0xD9FFFFFF)
                    .margin(left: 16, top: if (this.embedded) { 8.0 } else { 8.0 + getSafeAreaTop() })
                    .onClick({ _ => if (this.embedded) { this.onClose() } else { routerPop() } })
            }.width(100.percent).layoutWeight(1)

            Column {
                Button {
                    Text(this.subscribeTitle())
                        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                }
                    .width(100.percent).height(52).borderRadius(26)
                    .linearGradient(angle: 90.0, colors: [
                        (Color(0xFF0077FF), 0.0), (Color(0xFF6B93FF), 0.4),
                        (Color(0xFF8878FF), 0.7), (Color(0xFFE46ACE), 1.0)
                    ])
                    .onClick({ _ => this.subscribe() })
            }
            .width(100.percent).padding(left: 16, right: 16, top: 10,
                bottom: if (this.embedded) { 10.0 } else { 10.0 + getSafeAreaBottom() })
            .backgroundColor(0xF2FFFFFF)
        }
        .width(100.percent).height(100.percent).backgroundColor(0xFFF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }
}
