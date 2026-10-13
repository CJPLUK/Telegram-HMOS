package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import kit.AbilityKit.Want
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import std.collection.ArrayList
import std.sync.*
import std.unicode.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.components.AnimatedStickerComponent
import ohos_app_cangjie_entry.core.mtproto.{InputPeerSelf, InputPeerUser, StarGiftAttributeIdEntry, TLObject}
import ohos_app_cangjie_entry.providers.{PaymentsDataProvider, StarGiftAttributeViewModel, StarGiftViewModel, formatCurrencyAmount}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.{StickerItem, ensureStickerLocalFile, getPaymentsService, getGlobalAbilityContext, getTelegramEngineDataService, JsonParser}
import ohos_app_cangjie_entry.utils.formatTonAmountString

@HybridComponentEntry
@Component
public class GiftStorePage {
    @State var loaded: Bool = false
    @State var loading: Bool = true
    @State var loadingMore: Bool = false
    @State var giftId: Int64 = 0
    @State var giftTitle: String = "Gift"
    @State var peerId: Int64 = 0
    @State var peerAccessHash: Int64 = 0
    @State var starsBalance: Int64 = 0
    @State var tonBalance: Int64 = 0
    @State var tonLoaded: Bool = false
    @State var count: Int32 = 0
    @State var initialCount: Int32 = -1
    @State var nextOffset: String = ""
    @State var gifts: ArrayList<StarGiftViewModel> = ArrayList<StarGiftViewModel>()
    @State var giftPaths: ArrayList<String> = ArrayList<String>()
    @State var attributes: ArrayList<StarGiftAttributeViewModel> = ArrayList<StarGiftAttributeViewModel>()
    @State var sortMode: Int32 = 1
    @State var starsOnly: Bool = false
    @State var selectedModelIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var selectedBackdropIds: ArrayList<Int32> = ArrayList<Int32>()
    @State var selectedPatternIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var filterSheet: Int32 = -1
    @State var filterQuery: String = ""
    @State var selectedGift: Int64 = -1
    @State var purchasing: Bool = false
    @State var purchaseError: String = ""
    @State var purchaseConfirm: Bool = false
    @State var purchaseTon: Bool = false
    @State var acceptedPrice: Int64 = 0
    @State var hasUpdatedPrice: Bool = false
    @State var balanceSheet: Bool = false
    @State var tonTopupUrl: String = "https://fragment.com/ads/topup"
    private var attributePressGeneration: Int64 = 0
    private var attributePressActive: Bool = false
    private var suppressAttributeClick: Bool = false
    private var attributeTouchX: Float64 = 0.0
    private var attributeTouchY: Float64 = 0.0

    private func parseInt64(value: String): Int64 {
        var result: Int64 = 0
        for (rune in value.toRuneArray()) {
            let digit = Int64(UInt32(rune)) - 48
            if (digit < 0 || digit > 9) { break }
            result = result * 10 + digit
        }
        return result
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let param = takePending("GiftStorePage")
        let parts = param.split("|")
        if (parts.size > 0) { this.giftId = this.parseInt64(parts[0]) }
        if (parts.size > 1 && parts[1].size > 0) { this.giftTitle = parts[1] }
        if (parts.size > 2) { this.peerId = this.parseInt64(parts[2]) }
        if (parts.size > 3) { this.peerAccessHash = this.parseInt64(parts[3]) }
        this.reload()
        let _ = spawn {
            let provider = PaymentsDataProvider()
            let balance = provider.getStarsStatus()
            let ton = provider.getTonStatus()
            let appConfig = getTelegramEngineDataService().getAppConfig()
            let configuredTopupUrl = match (appConfig) {
                case Some(config) =>
                    let value = JsonParser.parseObject(config.configJson).getString("ton_topup_url")
                    if (value.size > 0) { value } else { "https://fragment.com/ads/topup" }
                case None => "https://fragment.com/ads/topup"
            }
            launch {
                if (balance.loaded) { this.starsBalance = balance.balanceStars }
                if (ton.loaded) { this.tonBalance = ton.balanceStars }
                this.tonLoaded = ton.loaded
                this.tonTopupUrl = configuredTopupUrl
            }
        }
    }

    private func selectedAttributes(): ArrayList<StarGiftAttributeIdEntry> {
        let result = ArrayList<StarGiftAttributeIdEntry>()
        for (documentId in this.selectedModelIds) {
            let value = StarGiftAttributeIdEntry()
            value.kind = "model"
            value.documentId = documentId
            result.add(value)
        }
        for (backdropId in this.selectedBackdropIds) {
            let value = StarGiftAttributeIdEntry()
            value.kind = "backdrop"
            value.backdropId = backdropId
            result.add(value)
        }
        for (documentId in this.selectedPatternIds) {
            let value = StarGiftAttributeIdEntry()
            value.kind = "pattern"
            value.documentId = documentId
            result.add(value)
        }
        return result
    }

    private func reload(): Unit {
        this.loading = true
        this.nextOffset = ""
        this.gifts = ArrayList<StarGiftViewModel>()
        this.giftPaths = ArrayList<String>()
        this.loadPage("")
    }

    private func loadMore(): Unit {
        if (this.loading || this.loadingMore || this.nextOffset.size == 0) { return }
        this.loadingMore = true
        this.loadPage(this.nextOffset)
    }

    private func loadPage(offset: String): Unit {
        let giftId = this.giftId
        let sortPrice = this.sortMode == 1
        let sortNumber = this.sortMode == 2
        let starsOnly = this.starsOnly
        let filters = this.selectedAttributes()
        let _ = spawn {
            let result = PaymentsDataProvider().getResaleStarGifts(giftId, offset, 36, sortPrice, sortNumber, starsOnly, filters)
            let pagePaths = ArrayList<String>()
            if (result.loaded) {
                for (gift in result.gifts) {
                    let sticker = StickerItem()
                    sticker.documentId = gift.documentId
                    sticker.accessHash = gift.documentAccessHash
                    sticker.fileReference = gift.documentFileReference
                    sticker.dcId = gift.documentDcId
                    sticker.mimeType = gift.documentMimeType
                    sticker.size = gift.documentSize
                    pagePaths.add(ensureStickerLocalFile(sticker))
                }
            }
            launch {
                if (offset.size == 0) {
                    this.gifts = result.gifts
                    this.giftPaths = pagePaths
                    this.attributes = result.attributes
                } else {
                    for (gift in result.gifts) { this.gifts.add(gift) }
                    for (path in pagePaths) { this.giftPaths.add(path) }
                }
                this.count = result.count
                if (offset.size == 0 && this.initialCount < 0) { this.initialCount = result.count }
                this.nextOffset = result.nextOffset
                this.loading = false
                this.loadingMore = false
            }
        }
    }

    private func colorValue(value: Int32, fallback: UInt32): UInt32 {
        if (value == 0) { return fallback }
        return 0xFF000000 | (UInt32(Int64(value) & 0xFFFFFFFF) & 0x00FFFFFF)
    }

    private func filterTitle(kind: Int32): String {
        if (kind == 1) {
            if (this.selectedModelIds.size == 0) { return "Model" }
            return if (this.selectedModelIds.size == 1) { "1 Model" } else { "${this.selectedModelIds.size} Models" }
        }
        if (kind == 2) {
            if (this.selectedBackdropIds.size == 0) { return "Backdrop" }
            return if (this.selectedBackdropIds.size == 1) { "1 Backdrop" } else { "${this.selectedBackdropIds.size} Backdrops" }
        }
        if (kind == 3) {
            if (this.selectedPatternIds.size == 0) { return "Symbol" }
            return if (this.selectedPatternIds.size == 1) { "1 Symbol" } else { "${this.selectedPatternIds.size} Symbols" }
        }
        if (this.sortMode == 1) { return "Price" }
        if (this.sortMode == 2) { return "Number" }
        return "Date"
    }

    @Builder
    private func filterButton(kind: Int32) {
        Row {
            if (kind == 0) { Text(if (this.sortMode == 1) { "↕" } else if (this.sortMode == 2) { "#" } else { "◷" }).fontSize(15) }
            Text(this.filterTitle(kind)).fontSize(14).fontWeight(FontWeight.Medium).margin(left: if (kind == 0) { 5 } else { 0 })
            Text("⌄").fontSize(13).fontColor(0xFF8E8E93).margin(left: 4)
        }.height(34).padding(left: 12, right: 10).backgroundColor(0xFFFFFFFF).borderRadius(17)
            .onClick({ _ => this.filterQuery = ""; this.filterSheet = kind })
    }

    @Builder
    private func giftCard(gift: StarGiftViewModel, idx: Int64) {
        Stack(alignContent: Alignment.TopEnd) {
            Column {
                if (idx < this.giftPaths.size && this.giftPaths[idx].size > 0) {
                    AnimatedStickerComponent(documentId: gift.documentId, localPath: this.giftPaths[idx], displaySize: 86.0,
                        isVideoSticker: gift.documentMimeType.contains("webm"))
                } else {
                    LoadingProgress().width(28).height(28).margin(top: 29, bottom: 29)
                }
                Row {
                    Image(@r(app.media.stars_balance)).width(17).height(17)
                    Text("${gift.resellStars}").fontSize(14).fontWeight(FontWeight.Medium).fontColor(0xFF6E4500).margin(left: 3)
                }.padding(left: 9, right: 9, top: 4, bottom: 4).backgroundColor(0xD9FFFFFF).borderRadius(13)
            }.width(100.percent).height(154).justifyContent(FlexAlign.Center)
                .linearGradient(angle: 145.0, colors: [
                    (Color(this.colorValue(gift.centerColor, 0xFFF2E9FF)), 0.0),
                    (Color(this.colorValue(gift.edgeColor, 0xFFD9E8FF)), 1.0)
                ]).borderRadius(14)
            Stack(alignContent: Alignment.Center) {
                Image(@r(app.media.gift_ribbon)).width(58).height(58)
                Text("#${gift.num}").fontSize(10).fontWeight(FontWeight.Medium).fontColor(0xFFFFFFFF)
                    .rotate(angle: 45.0).translate(x: 9, y: -9)
            }.width(58).height(58)
        }.width(100.percent).height(154).onClick({ _ =>
            this.purchaseError = ""
            this.purchaseConfirm = false
            this.hasUpdatedPrice = false
            this.selectedGift = idx
        })
    }

    private func selectSort(value: Int32): Unit {
        this.sortMode = value
        this.filterSheet = -1
        this.reload()
    }

    private func selectAttribute(attribute: StarGiftAttributeViewModel): Unit {
        if (attribute.kind == "model") {
            let updated = ArrayList<Int64>()
            for (id in this.selectedModelIds) { if (id != attribute.documentId) { updated.add(id) } }
            if (!this.selectedModelIds.contains(attribute.documentId)) { updated.add(attribute.documentId) }
            this.selectedModelIds = updated
        } else if (attribute.kind == "backdrop") {
            let updated = ArrayList<Int32>()
            for (id in this.selectedBackdropIds) { if (id != attribute.backdropId) { updated.add(id) } }
            if (!this.selectedBackdropIds.contains(attribute.backdropId)) { updated.add(attribute.backdropId) }
            this.selectedBackdropIds = updated
        } else if (attribute.kind == "pattern") {
            let updated = ArrayList<Int64>()
            for (id in this.selectedPatternIds) { if (id != attribute.documentId) { updated.add(id) } }
            if (!this.selectedPatternIds.contains(attribute.documentId)) { updated.add(attribute.documentId) }
            this.selectedPatternIds = updated
        }
        this.filterSheet = -1
        this.reload()
    }

    private func selectAttributeExclusive(attribute: StarGiftAttributeViewModel): Unit {
        if (attribute.kind == "model") {
            let updated = ArrayList<Int64>()
            updated.add(attribute.documentId)
            this.selectedModelIds = updated
        } else if (attribute.kind == "backdrop") {
            let updated = ArrayList<Int32>()
            updated.add(attribute.backdropId)
            this.selectedBackdropIds = updated
        } else if (attribute.kind == "pattern") {
            let updated = ArrayList<Int64>()
            updated.add(attribute.documentId)
            this.selectedPatternIds = updated
        }
        this.filterSheet = -1
        this.reload()
    }

    private func isAttributeSelected(attribute: StarGiftAttributeViewModel): Bool {
        if (attribute.kind == "model") { return this.selectedModelIds.size == 0 || this.selectedModelIds.contains(attribute.documentId) }
        if (attribute.kind == "backdrop") { return this.selectedBackdropIds.size == 0 || this.selectedBackdropIds.contains(attribute.backdropId) }
        if (attribute.kind == "pattern") { return this.selectedPatternIds.size == 0 || this.selectedPatternIds.contains(attribute.documentId) }
        return false
    }

    private func attributeKindCount(kind: Int32): Int64 {
        var result: Int64 = 0
        for (attribute in this.attributes) {
            if ((kind == 1 && attribute.kind == "model") || (kind == 2 && attribute.kind == "backdrop") || (kind == 3 && attribute.kind == "pattern")) {
                result = result + 1
            }
        }
        return result
    }

    private func attributeMatchesQuery(attribute: StarGiftAttributeViewModel): Bool {
        let query = this.filterQuery.trim().toAsciiLower()
        if (query.size == 0) { return true }
        let words = attribute.name.toAsciiLower().split(" ")
        for (component in query.split(" ")) {
            if (component.size == 0) { continue }
            var matched = false
            for (word in words) {
                if (word.startsWith(component)) { matched = true; break }
            }
            if (!matched) { return false }
        }
        return true
    }

    private func sortedFilterAttributes(kind: Int32): ArrayList<StarGiftAttributeViewModel> {
        let filtered = ArrayList<StarGiftAttributeViewModel>()
        for (attribute in this.attributes) {
            if ((kind == 1 && attribute.kind == "model") || (kind == 2 && attribute.kind == "backdrop") || (kind == 3 && attribute.kind == "pattern")) {
                filtered.add(attribute)
            }
        }
        let n = filtered.size
        if (n <= 1) { return filtered }
        var array = Array<StarGiftAttributeViewModel>(n, { index => filtered[index] })
        var i: Int64 = 1
        while (i < n) {
            let value = array[i]
            var j = i - 1
            while (j >= 0 && array[j].count < value.count) {
                array[j + 1] = array[j]
                j = j - 1
            }
            array[j + 1] = value
            i = i + 1
        }
        let result = ArrayList<StarGiftAttributeViewModel>()
        for (attribute in array) { result.add(attribute) }
        return result
    }

    private func openTonTopup(): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    ctx.startAbility(Want(action: "ohos.want.action.viewData", uri: this.tonTopupUrl))
                } catch (e: Exception) {
                    this.purchaseError = "Could not open Fragment."
                }
            case None => this.purchaseError = "Could not open Fragment."
        }
    }

    private func beginPurchase(ton: Bool): Bool {
        if (this.selectedGift < 0 || this.selectedGift >= this.gifts.size) { return false }
        let gift = this.gifts[this.selectedGift]
        let price = if (ton) { gift.resellTon } else { gift.resellStars }
        if (price <= 0) { return false }
        if (!ton && this.starsBalance < price) {
            this.purchaseConfirm = false
            setPending("StarsPage", "topup")
            routerPush("StarsPage", "")
            return false
        }
        if (ton && this.tonBalance < price) {
            this.purchaseConfirm = false
            this.openTonTopup()
            return false
        }
        this.purchaseTon = ton
        this.acceptedPrice = price
        this.hasUpdatedPrice = false
        return true
    }

    private func confirmPurchaseCurrency(ton: Bool): Unit {
        if (this.hasUpdatedPrice && this.purchaseTon == ton) {
            this.buySelected()
        } else if (this.beginPurchase(ton)) {
            this.buySelected()
        }
    }

    private func buySelected(): Unit {
        if (this.purchasing || this.selectedGift < 0 || this.selectedGift >= this.gifts.size) { return }
        let gift = this.gifts[this.selectedGift]
        let peer: TLObject = if (this.peerId == 0) {
            InputPeerSelf()
        } else {
            let input = InputPeerUser()
            input.userId = this.peerId
            input.accessHash = this.peerAccessHash
            input
        }
        this.purchasing = true
        this.purchaseError = ""
        let _ = spawn {
            let result = getPaymentsService().buyResaleStarGift(peer, gift.slug, this.purchaseTon, this.acceptedPrice)
            launch {
                this.purchasing = false
                if (result.success) {
                    this.purchaseConfirm = false
                    this.selectedGift = -1
                    this.reload()
                    let _ = spawn {
                        let provider = PaymentsDataProvider()
                        let stars = provider.getStarsStatus()
                        let ton = provider.getTonStatus()
                        launch {
                            if (stars.loaded) { this.starsBalance = stars.balanceStars }
                            if (ton.loaded) { this.tonBalance = ton.balanceStars }
                        }
                    }
                } else if (result.priceChanged) {
                    this.acceptedPrice = result.updatedPrice
                    this.purchaseTon = result.updatedCurrency == "TON"
                    this.hasUpdatedPrice = true
                    this.purchaseError = "The price has changed. Confirm the updated price to continue."
                } else {
                    this.purchaseError = if (result.errorMessage.size > 0) { result.errorMessage } else { "Telegram could not buy this gift." }
                }
            }
        }
    }

    @Builder
    private func filterSheetView() {
        Stack(alignContent: Alignment.Bottom) {
            Column { }.width(100.percent).height(100.percent).backgroundColor(0x55000000).onClick({ _ => this.filterSheet = -1 })
            Column {
                Row {
                    Text(if (this.filterSheet == 0) { "Sort by" } else { this.filterTitle(this.filterSheet) })
                        .fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1)
                    Button {
                        Image(@r(app.media.nav_ic_close)).width(15).height(15).fillColor(0xFF111111)
                    }.width(34).height(34).borderRadius(17).backgroundColor(0xFFE5E5EA).onClick({ _ => this.filterSheet = -1 })
                }.width(100.percent).padding(left: 20, right: 16, top: 14, bottom: 10)
                if (this.filterSheet == 0) {
                    this.sheetRow("Price", this.sortMode == 1, { => this.selectSort(1) })
                    this.sheetRow("Date", this.sortMode == 0, { => this.selectSort(0) })
                    this.sheetRow("Number", this.sortMode == 2, { => this.selectSort(2) })
                    Divider().color(0xFFD1D1D6)
                    this.sheetRow("All Listings", !this.starsOnly, { =>
                        this.starsOnly = false
                        this.filterSheet = -1
                        this.reload()
                    })
                    this.sheetRow("For Stars Only", this.starsOnly, { =>
                        this.starsOnly = true
                        this.filterSheet = -1
                        this.reload()
                    })
                } else {
                    if (this.attributeKindCount(this.filterSheet) >= 8) {
                        TextInput(text: this.filterQuery, placeholder: "Search")
                            .width(100.percent).height(42).margin(left: 14, right: 14, bottom: 8)
                            .padding(left: 12, right: 12).backgroundColor(0xFFE5E5EA).borderRadius(10)
                            .onChange({ value: String => this.filterQuery = value })
                    }
                    this.sheetRow("Select All", this.filterSheet == 1 && this.selectedModelIds.size == 0 || this.filterSheet == 2 && this.selectedBackdropIds.size == 0 || this.filterSheet == 3 && this.selectedPatternIds.size == 0, { =>
                        if (this.filterSheet == 1) { this.selectedModelIds = ArrayList<Int64>() }
                        else if (this.filterSheet == 2) { this.selectedBackdropIds = ArrayList<Int32>() }
                        else { this.selectedPatternIds = ArrayList<Int64>() }
                        this.filterSheet = -1
                        this.reload()
                    })
                    ForEach(this.sortedFilterAttributes(this.filterSheet), itemGenerator: { attribute: StarGiftAttributeViewModel, _idx: Int64 =>
                        if (this.attributeMatchesQuery(attribute)) { this.attributeSheetRow(attribute) }
                    })
                }
            }.width(100.percent).padding(bottom: 12.0 + getSafeAreaBottom()).backgroundColor(0xFFF2F2F7).borderRadius(topLeft: 24, topRight: 24)
        }.width(100.percent).height(100.percent)
    }

    @Builder
    private func sheetRow(title: String, selected: Bool, action: () -> Unit) {
        Row {
            Text(title).fontSize(17).layoutWeight(1)
            if (selected) { Text("✓").fontSize(18).fontWeight(FontWeight.Bold).fontColor(0xFF007AFF) }
        }.height(52).padding(left: 20, right: 20).backgroundColor(0xFFFFFFFF).onClick({ _ => action() })
    }

    @Builder
    private func attributeSheetRow(attribute: StarGiftAttributeViewModel) {
        Row {
            Text(if (attribute.count > 0) { "${attribute.name}  ${attribute.count}" } else { attribute.name }).fontSize(17).layoutWeight(1)
            if (this.isAttributeSelected(attribute)) { Text("✓").fontSize(18).fontWeight(FontWeight.Bold).fontColor(0xFF007AFF) }
        }.height(52).padding(left: 20, right: 20).backgroundColor(0xFFFFFFFF)
            .onClick({ _ =>
                if (this.suppressAttributeClick) { this.suppressAttributeClick = false }
                else { this.selectAttribute(attribute) }
            })
            .onTouch({ event: TouchEvent =>
                match (event.eventType) {
                    case TouchType.Down =>
                        this.attributePressActive = true
                        this.attributePressGeneration = this.attributePressGeneration + 1
                        if (event.touches.size > 0) {
                            this.attributeTouchX = event.touches[0].x
                            this.attributeTouchY = event.touches[0].y
                        }
                        let generation = this.attributePressGeneration
                        let pressedAttribute = attribute
                        let _ = spawn {
                            sleep(Duration.millisecond * 500)
                            launch {
                                if (this.attributePressActive && this.attributePressGeneration == generation) {
                                    this.attributePressActive = false
                                    this.suppressAttributeClick = true
                                    this.selectAttributeExclusive(pressedAttribute)
                                }
                            }
                        }
                    case TouchType.Move =>
                        if (this.attributePressActive && event.touches.size > 0) {
                            let dx = event.touches[0].x - this.attributeTouchX
                            let dy = event.touches[0].y - this.attributeTouchY
                            if (dx * dx + dy * dy > 100.0) {
                                this.attributePressActive = false
                                this.attributePressGeneration = this.attributePressGeneration + 1
                            }
                        }
                    case TouchType.Up =>
                        this.attributePressActive = false
                        this.attributePressGeneration = this.attributePressGeneration + 1
                    case TouchType.Cancel =>
                        this.attributePressActive = false
                        this.attributePressGeneration = this.attributePressGeneration + 1
                    case _ => ()
                }
            })
    }

    @Builder
    private func detailRow(label: String, value: String) {
        Row {
            Text(label).fontSize(16).width(118).fontColor(0xFF111111)
            Text(value).fontSize(16).layoutWeight(1).fontColor(0xFF111111)
        }.width(100.percent).height(48).padding(left: 14, right: 14, top: 8, bottom: 8)
            .border(width: 0.5, color: 0xFFD1D1D6)
    }

    private func giftPriceText(gift: StarGiftViewModel, ton: Bool): String {
        if (ton) { return "GRAM ${formatTonAmountString(gift.resellTon, ".", false, None)}" }
        return "⭐ ${gift.resellStars}"
    }

    private func confirmationPriceText(gift: StarGiftViewModel, ton: Bool): String {
        if (this.hasUpdatedPrice && this.purchaseTon == ton) {
            if (ton) { return "GRAM ${formatTonAmountString(this.acceptedPrice, ".", false, None)}" }
            return "⭐ ${this.acceptedPrice}"
        }
        return this.giftPriceText(gift, ton)
    }

    @Builder
    private func purchaseConfirmationSheet() {
        if (this.selectedGift >= 0 && this.selectedGift < this.gifts.size) {
            Stack(alignContent: Alignment.Bottom) {
                Column { }.width(100.percent).height(100.percent).backgroundColor(0x55000000)
                    .onClick({ _ => this.purchaseConfirm = false })
                Column {
                    Text("Buy this gift?").fontSize(20).fontWeight(FontWeight.Bold)
                    Text("The gift will be sent to ${if (this.peerId == 0) { "you" } else { "the selected recipient" }}.")
                        .fontSize(15).fontColor(0xFF8E8E93).textAlign(TextAlign.Center).margin(top: 8, bottom: 18)
                    if (this.gifts[this.selectedGift].resellStars > 0) {
                        Button("Buy for ${this.confirmationPriceText(this.gifts[this.selectedGift], false)}")
                            .width(100.percent).height(50).fontSize(17).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                            .backgroundColor(0xFF007AFF).borderRadius(14).onClick({ _ => this.confirmPurchaseCurrency(false) })
                    }
                    if (this.gifts[this.selectedGift].resellTon > 0) {
                        Button("Buy for ${this.confirmationPriceText(this.gifts[this.selectedGift], true)}")
                            .width(100.percent).height(50).margin(top: 10).fontSize(17).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                            .backgroundColor(0xFF007AFF).borderRadius(14).onClick({ _ => this.confirmPurchaseCurrency(true) })
                    }
                    Button("Cancel").width(100.percent).height(50).margin(top: 10).fontSize(17).fontColor(0xFF007AFF)
                        .backgroundColor(0xFFF2F2F7).borderRadius(14).onClick({ _ => this.purchaseConfirm = false })
                }.width(100.percent).padding(left: 18, right: 18, top: 20, bottom: 16.0 + getSafeAreaBottom())
                    .backgroundColor(0xFFFFFFFF).borderRadius(topLeft: 24, topRight: 24)
            }.width(100.percent).height(100.percent)
        }
    }

    @Builder
    private func balanceMenuSheet() {
        Stack(alignContent: Alignment.TopEnd) {
            Column { }.width(100.percent).height(100.percent).backgroundColor(0x22000000).onClick({ _ => this.balanceSheet = false })
            Column {
                Row {
                    Image(@r(app.media.stars_balance)).width(24).height(24)
                    Column {
                        Text("My Stars").fontSize(16)
                        Text("${this.starsBalance}").fontSize(13).fontColor(0xFF8E8E93)
                    }.alignItems(HorizontalAlign.Start).margin(left: 10).layoutWeight(1)
                }.height(58).padding(left: 14, right: 14).onClick({ _ =>
                    this.balanceSheet = false
                    setPending("StarsPage", "")
                    routerPush("StarsPage", "")
                })
                Divider().color(0xFFD1D1D6)
                Row {
                    Text("◆").fontSize(22).fontColor(0xFF0098EA).width(24).textAlign(TextAlign.Center)
                    Column {
                        Text("My GRAM").fontSize(16)
                        Text(formatTonAmountString(this.tonBalance, ".", false, None)).fontSize(13).fontColor(0xFF8E8E93)
                    }.alignItems(HorizontalAlign.Start).margin(left: 10).layoutWeight(1)
                }.height(58).padding(left: 14, right: 14).onClick({ _ =>
                    this.balanceSheet = false
                    setPending("StarsPage", "ton")
                    routerPush("StarsPage", "")
                })
            }.width(210).margin(top: getSafeAreaTop() + 48.0, right: 12).backgroundColor(0xF7FFFFFF).borderRadius(14)
        }.width(100.percent).height(100.percent)
    }

    @Builder
    private func giftDetailSheet() {
        Stack(alignContent: Alignment.Bottom) {
            Column { }.width(100.percent).height(100.percent).backgroundColor(0x66000000).onClick({ _ => this.selectedGift = -1 })
            if (this.selectedGift >= 0 && this.selectedGift < this.gifts.size) {
                Column {
                    Row {
                        Button {
                            Image(@r(app.media.nav_ic_close)).width(15).height(15).fillColor(0xFF111111)
                        }.width(34).height(34).borderRadius(17).backgroundColor(0xFFE5E5EA).onClick({ _ => this.selectedGift = -1 })
                        Text("${this.gifts[this.selectedGift].title} #${this.gifts[this.selectedGift].num}").fontSize(18).fontWeight(FontWeight.Bold).textAlign(TextAlign.Center).layoutWeight(1)
                        Column { }.width(34)
                    }.width(100.percent).padding(left: 14, right: 14, top: 12)
                    Scroll {
                        Column {
                            Column {
                                if (this.selectedGift < this.giftPaths.size && this.giftPaths[this.selectedGift].size > 0) {
                                    AnimatedStickerComponent(documentId: this.gifts[this.selectedGift].documentId, localPath: this.giftPaths[this.selectedGift], displaySize: 190.0,
                                        isVideoSticker: this.gifts[this.selectedGift].documentMimeType.contains("webm"))
                                }
                                Text("${this.gifts[this.selectedGift].title} #${this.gifts[this.selectedGift].num}").fontSize(24).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                                Text(this.gifts[this.selectedGift].modelName).fontSize(17).fontColor(0xCCFFFFFF).margin(top: 5, bottom: 18)
                            }.width(100.percent).linearGradient(angle: 145.0, colors: [
                                (Color(this.colorValue(this.gifts[this.selectedGift].centerColor, 0xFF659D75)), 0.0),
                                (Color(this.colorValue(this.gifts[this.selectedGift].edgeColor, 0xFF3B7650)), 1.0)
                            ])
                            Column {
                                this.detailRow("Owner", if (this.gifts[this.selectedGift].ownerName.size > 0) { this.gifts[this.selectedGift].ownerName } else if (this.gifts[this.selectedGift].ownerAddress.size > 0) { this.gifts[this.selectedGift].ownerAddress } else { "Anonymous" })
                                this.detailRow("Model", this.gifts[this.selectedGift].modelName)
                                this.detailRow("Symbol", this.gifts[this.selectedGift].patternName)
                                this.detailRow("Backdrop", this.gifts[this.selectedGift].backdropName)
                                this.detailRow("Availability", "${this.gifts[this.selectedGift].availabilityIssued}/${this.gifts[this.selectedGift].availabilityUniqueTotal} issued")
                                if (this.gifts[this.selectedGift].valueCurrency.size > 0) {
                                    this.detailRow("Value", "~${formatCurrencyAmount(this.gifts[this.selectedGift].valueCurrency, this.gifts[this.selectedGift].valueAmount)}")
                                }
                                if (this.purchaseError.size > 0) { Text(this.purchaseError).fontSize(13).fontColor(0xFFFF3B30).textAlign(TextAlign.Center).margin(top: 12) }
                                Button(if (this.purchasing) { "Purchasing…" } else if (this.gifts[this.selectedGift].resellStars > 0) { "Buy for ${this.giftPriceText(this.gifts[this.selectedGift], false)}" } else { "Buy for ${this.giftPriceText(this.gifts[this.selectedGift], true)}" })
                                    .width(100.percent).height(52).margin(top: 18, bottom: 12).fontSize(18).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                                    .backgroundColor(0xFF007AFF).borderRadius(26).enabled(!this.purchasing).onClick({ _ => this.purchaseConfirm = true })
                            }.padding(left: 18, right: 18, top: 16, bottom: 8)
                        }.width(100.percent)
                    }.layoutWeight(1)
                }.width(100.percent).height(88.percent).backgroundColor(0xFFFFFFFF).borderRadius(topLeft: 26, topRight: 26)
            }
            if (this.purchaseConfirm) { this.purchaseConfirmationSheet() }
        }.width(100.percent).height(100.percent)
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Column {
                Row {
                    Button {
                        Text("‹").fontSize(34).fontColor(0xFF007AFF).translate(y: -2)
                    }.width(44).height(44).backgroundColor(Color.Transparent).onClick({ _ => routerPop() })
                    Column {
                        Text(this.giftTitle).fontSize(17).fontWeight(FontWeight.Bold).maxLines(1)
                        Text(if (this.count == 0) { "no results" } else { "${this.count} for resale" }).fontSize(13).fontColor(0xFF8E8E93)
                    }.layoutWeight(1).alignItems(HorizontalAlign.Center)
                    Column {
                        Text("Balance").fontSize(12).fontColor(0xFF111111)
                        Row {
                            Image(@r(app.media.stars_balance)).width(17).height(17)
                            Text("${this.starsBalance}").fontSize(15).fontWeight(FontWeight.Medium).margin(left: 3)
                        }
                    }.height(44).padding(left: 12, right: 12).justifyContent(FlexAlign.Center).backgroundColor(0xFFFFFFFF).borderRadius(22)
                        .onClick({ _ =>
                            if (this.tonLoaded && this.tonBalance > 0) { this.balanceSheet = true }
                            else { setPending("StarsPage", ""); routerPush("StarsPage", "") }
                        })
                }.height(60).width(100.percent).padding(left: 4, right: 12)
                if (this.initialCount >= 18) {
                    Row(space: 7) {
                        this.filterButton(0)
                        this.filterButton(1)
                        this.filterButton(2)
                        this.filterButton(3)
                    }.width(100.percent).height(52).padding(left: 10, right: 10)
                }
                if (this.loading) {
                    Column { LoadingProgress().width(34).height(34) }.width(100.percent).layoutWeight(1).justifyContent(FlexAlign.Center)
                } else if (this.gifts.size == 0) {
                    Column {
                        Text("No Matching Gifts").fontSize(18).fontWeight(FontWeight.Bold)
                        if (this.selectedModelIds.size > 0 || this.selectedBackdropIds.size > 0 || this.selectedPatternIds.size > 0) {
                            Text("Clear Filters").fontSize(17).fontColor(0xFF007AFF).margin(top: 18).onClick({ _ =>
                                this.selectedModelIds = ArrayList<Int64>(); this.selectedBackdropIds = ArrayList<Int32>(); this.selectedPatternIds = ArrayList<Int64>(); this.reload()
                            })
                        }
                    }.width(100.percent).layoutWeight(1).justifyContent(FlexAlign.Center)
                } else {
                    Grid {
                        ForEach(this.gifts, itemGenerator: { gift: StarGiftViewModel, idx: Int64 => GridItem { this.giftCard(gift, idx) } })
                        if (this.loadingMore) { GridItem { LoadingProgress().width(28).height(28) } }
                    }.columnsTemplate("1fr 1fr 1fr").columnsGap(10).rowsGap(10).padding(left: 16, right: 16, bottom: 84.0 + getSafeAreaBottom())
                        .layoutWeight(1).scrollBar(BarState.Auto).onReachEnd({ => this.loadMore() })
                }
            }.width(100.percent).height(100.percent).padding(top: getSafeAreaTop()).backgroundColor(0xFFF2F2F7)
            if (this.tonLoaded && this.tonBalance == 0) {
                Row {
                    Toggle(ToggleType.Checkbox, isOn: this.starsOnly).selectedColor(0xFF007AFF).onChange({ selected: Bool => this.starsOnly = selected; this.reload() })
                    Text("Show listings for stars only").fontSize(15).fontWeight(FontWeight.Medium).margin(left: 8)
                }.height(48).padding(left: 16, right: 16).backgroundColor(0xEEFFFFFF).borderRadius(24)
                    .position(x: 72, y: 748.0 - getSafeAreaBottom())
            }
            if (this.filterSheet >= 0) { this.filterSheetView() }
            if (this.selectedGift >= 0) { this.giftDetailSheet() }
            if (this.balanceSheet) { this.balanceMenuSheet() }
        }.width(100.percent).height(100.percent).onAppear({ => this.ensureLoaded() })
    }
}
