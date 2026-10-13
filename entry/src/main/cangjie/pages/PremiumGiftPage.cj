package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import std.collection.ArrayList
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.storage.{getAuthStorage, trSource}
import ohos_app_cangjie_entry.providers.{PaymentsDataProvider, PremiumGiftCodeOptionViewModel, StarGiftViewModel, SavedStarGiftViewModel}
import ohos_app_cangjie_entry.components.{AnimatedStickerComponent, CustomEmojiImage}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.interop.*
import ohos_app_cangjie_entry.core.mtproto.{TLObject, InputUser, InputUserSelf, InputPeerSelf, InputPeerUser, InputStorePaymentPremiumGiftCode}

private func giftJsonOk(json: String): Bool {
    match (json.indexOf("\"ok\"")) { case Some(i) => return json[i..json.size].contains("true"); case None => return false }
}

private func giftJsonReceipt(json: String): String {
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
public class PremiumGiftPage {
    @State var loaded: Bool = false
    @State var loading: Bool = true
    @State var contacts: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    @State var query: String = ""
    @State var selfName: String = ""
    @State var selfInitial: String = "?"
    @State var selfId: Int64 = 0
    @State var selfAvatarPath: String = ""
    @State var selfAvatarEmojiId: Int64 = 0
    @State var selfAvatarBackgroundStart: UInt32 = 0xFF5BD1CA
    @State var selfAvatarBackgroundEnd: UInt32 = 0xFF538EDB
    @State var permissionGranted: Bool = false
    @State var permissionAsked: Bool = false
    @State var showPermissionCard: Bool = true
    @State var selectedPeerId: Int64 = 0
    @State var selectedAccessHash: Int64 = 0
    @State var selectedName: String = ""
    @State var selectedInitial: String = "?"
    @State var giftOptions: ArrayList<PremiumGiftCodeOptionViewModel> = ArrayList<PremiumGiftCodeOptionViewModel>()
    @State var starsGiftOptions: ArrayList<PremiumGiftCodeOptionViewModel> = ArrayList<PremiumGiftCodeOptionViewModel>()
    @State var starsBalance: Int64 = 0
    @State var optionsLoading: Bool = false
    @State var optionsError: String = ""
    @State var selectedOption: Int64 = 0
    @State var message: String = ""
    @State var showGiftSetup: Bool = false
    @State var payWithStars: Bool = false
    @State var purchasing: Bool = false
    @State var purchaseError: String = ""
    @State var starGifts: ArrayList<StarGiftViewModel> = ArrayList<StarGiftViewModel>()
    @State var starGiftPaths: ArrayList<String> = ArrayList<String>()
    @State var allStarGifts: ArrayList<StarGiftViewModel> = ArrayList<StarGiftViewModel>()
    @State var allStarGiftPaths: ArrayList<String> = ArrayList<String>()
    @State var resaleStarGifts: ArrayList<StarGiftViewModel> = ArrayList<StarGiftViewModel>()
    @State var resaleStarGiftPaths: ArrayList<String> = ArrayList<String>()
    @State var transferStarGifts: ArrayList<SavedStarGiftViewModel> = ArrayList<SavedStarGiftViewModel>()
    @State var transferStarGiftPaths: ArrayList<String> = ArrayList<String>()
    @State var giftFilter: Int32 = 0
    @State var hasResaleGifts: Bool = false
    @State var selectedStarGift: Int64 = -1
    @State var showStarGiftSetup: Bool = false
    @State var showStarsInfo: Bool = false
    @State var hideGiftSender: Bool = false
    @State var includeGiftUpgrade: Bool = false
    private let giftPreviewFocusId: String = "gift_setup_preview_focus"

    private func load(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        match (getAuthStorage().getUserData()) {
            case Some(user) =>
                this.selfId = user.id
                this.selfAvatarPath = getUserPhotoService().getUserPhotoPath(user.id)
                getUserPhotoService().addPhotoReadyCallback({ readyId: Int64, path: String =>
                    if (readyId == this.selfId) { launch { this.selfAvatarPath = path } }
                })
                getUserPhotoService().requestFullPhotoDownload(user.id)
                match (getPeerInfoAvatarListService().getCurrentPhotoInfo(user.id)) {
                    case Some(info) =>
                        this.selfAvatarEmojiId = info.emojiDocumentId
                        if (info.emojiBackgroundColors.size >= 2) {
                            this.selfAvatarBackgroundStart = UInt32(Int64(info.emojiBackgroundColors[0]) & 0xFFFFFFFF)
                            this.selfAvatarBackgroundEnd = UInt32(Int64(info.emojiBackgroundColors[1]) & 0xFFFFFFFF)
                        }
                    case None => ()
                }
                this.selfName = (user.firstName + " " + user.lastName).trimAscii()
                if (this.selfName.size == 0) { this.selfName = "Me" }
                if (user.firstName.size > 0) { this.selfInitial = user.firstName.toRuneArray()[0].toString() }
            case None => this.selfName = "Me"
        }
        let _ = spawn {
            let granted = getPermissionsService().checkPermission(PermissionType.Contacts)
            let asked = getContactsPermissionAsked()
            let result = getRealContactService().getContacts()
            let visibleContacts = ArrayList<ContactDisplayData>()
            for (contact in result) {
                if (contact.userId != this.selfId) { visibleContacts.add(contact) }
            }
            launch {
                this.permissionGranted = granted
                this.permissionAsked = asked
                this.contacts = visibleContacts
                this.loading = false
            }
        }
    }

    private func requestContacts(): Unit {
        if (this.permissionAsked && !this.permissionGranted) { getDeviceAccessService().openSystemSettings(); return }
        getPermissionsService().requestPermission(PermissionType.Contacts, { granted: Bool =>
            setContactsPermissionAsked()
            launch {
                this.permissionGranted = granted
                this.permissionAsked = true
            }
        })
    }

    private func contactVisible(contact: ContactDisplayData): Bool {
        if (this.query.size == 0) { return true }
        return contact.getDisplayName().toAsciiLower().contains(this.query.toAsciiLower())
    }

    private func selectRecipient(id: Int64, accessHash: Int64, name: String, initial: String): Unit {
        this.selectedPeerId = id
        this.selectedAccessHash = accessHash
        this.selectedName = name
        this.selectedInitial = initial
        this.optionsLoading = true
        this.optionsError = ""
        let _ = spawn {
            let provider = PaymentsDataProvider()
            let vm = provider.getPremiumGiftCodeOptions(0, 0)
            let starsState = provider.getStarsStatus()
            let catalog = provider.getStarGiftsCatalog(0)
            let saved = provider.getSavedStarGifts(0, 0, "", 100, false)
            let catalogGifts = ArrayList<StarGiftViewModel>()
            let catalogPaths = ArrayList<String>()
            let resaleGifts = ArrayList<StarGiftViewModel>()
            let resalePaths = ArrayList<String>()
            let transferable = ArrayList<SavedStarGiftViewModel>()
            let transferablePaths = ArrayList<String>()
            var hasResale = false
            if (catalog.loaded) {
                for (gift in catalog.gifts) {
                    if (!gift.isUnique && gift.availabilityResale > 0) { hasResale = true }
                    if (!gift.isUnique) {
                        catalogGifts.add(gift)
                        catalogPaths.add("")
                        if (gift.availabilityResale > 0) { resaleGifts.add(gift); resalePaths.add("") }
                    }
                }
            }
            if (id != this.selfId && saved.loaded) {
                for (entry in saved.gifts) {
                    if (entry.gift.isUnique && !entry.isRefunded && entry.msgId != 0) {
                        transferable.add(entry)
                        transferablePaths.add("")
                    }
                }
            }
            let hasResaleValue = hasResale
            launch {
                let filtered = ArrayList<PremiumGiftCodeOptionViewModel>()
                let starsFiltered = ArrayList<PremiumGiftCodeOptionViewModel>()
                for (option in vm.options) {
                    if (id != this.selfId && option.users == 1) {
                        if (option.currency == "XTR") { starsFiltered.add(option) }
                        else { filtered.add(option) }
                    }
                }
                this.giftOptions = filtered
                this.starsGiftOptions = starsFiltered
                this.starsBalance = if (starsState.loaded) { starsState.balanceStars } else { 0 }
                this.allStarGifts = catalogGifts
                this.allStarGiftPaths = catalogPaths
                this.resaleStarGifts = resaleGifts
                this.resaleStarGiftPaths = resalePaths
                this.transferStarGifts = transferable
                this.transferStarGiftPaths = transferablePaths
                this.starGifts = catalogGifts
                this.starGiftPaths = catalogPaths
                this.hasResaleGifts = hasResaleValue
                this.giftFilter = 0
                this.selectedOption = 0
                this.payWithStars = false
                this.hideGiftSender = id == this.selfId
                this.includeGiftUpgrade = false
                this.optionsError = if (id == this.selfId || vm.loaded) { "" } else { vm.errorMessage }
                this.optionsLoading = false
            }
            for (gift in catalogGifts) {
                let sticker = StickerItem()
                sticker.documentId = gift.documentId
                sticker.accessHash = gift.documentAccessHash
                sticker.fileReference = gift.documentFileReference
                sticker.dcId = gift.documentDcId
                sticker.mimeType = gift.documentMimeType
                sticker.size = gift.documentSize
                let path = ensureStickerLocalFile(sticker)
                launch { this.updateCatalogGiftPath(id, gift.id, path) }
            }
            for (entry in transferable) {
                let sticker = StickerItem()
                sticker.documentId = entry.gift.documentId
                sticker.accessHash = entry.gift.documentAccessHash
                sticker.fileReference = entry.gift.documentFileReference
                sticker.dcId = entry.gift.documentDcId
                sticker.mimeType = entry.gift.documentMimeType
                sticker.size = entry.gift.documentSize
                let path = ensureStickerLocalFile(sticker)
                launch { this.updateTransferGiftPath(id, entry.gift.slug, path) }
            }
        }
    }

    private func updateCatalogGiftPath(recipientId: Int64, giftId: Int64, path: String): Unit {
        if (this.selectedPeerId != recipientId || path.size == 0) { return }
        let allPaths = ArrayList<String>()
        for (value in this.allStarGiftPaths) { allPaths.add(value) }
        var index: Int64 = 0
        for (gift in this.allStarGifts) {
            if (gift.id == giftId && index < allPaths.size) { allPaths[index] = path }
            index = index + 1
        }
        this.allStarGiftPaths = allPaths
        if (this.giftFilter == 0) { this.starGiftPaths = allPaths }
        let resalePaths = ArrayList<String>()
        for (value in this.resaleStarGiftPaths) { resalePaths.add(value) }
        index = 0
        for (gift in this.resaleStarGifts) {
            if (gift.id == giftId && index < resalePaths.size) { resalePaths[index] = path }
            index = index + 1
        }
        this.resaleStarGiftPaths = resalePaths
        if (this.giftFilter == 1) { this.starGiftPaths = resalePaths }
    }

    private func updateTransferGiftPath(recipientId: Int64, slug: String, path: String): Unit {
        if (this.selectedPeerId != recipientId || path.size == 0) { return }
        let paths = ArrayList<String>()
        for (value in this.transferStarGiftPaths) { paths.add(value) }
        var index: Int64 = 0
        for (entry in this.transferStarGifts) {
            if (entry.gift.slug == slug && index < paths.size) { paths[index] = path }
            index = index + 1
        }
        this.transferStarGiftPaths = paths
        if (this.giftFilter == 2) { this.starGiftPaths = paths }
    }

    private func closeRecipient(): Unit {
        this.selectedPeerId = 0
        this.selectedAccessHash = 0
        this.selectedName = ""
        this.giftOptions = ArrayList<PremiumGiftCodeOptionViewModel>()
        this.starsGiftOptions = ArrayList<PremiumGiftCodeOptionViewModel>()
        this.allStarGifts = ArrayList<StarGiftViewModel>()
        this.allStarGiftPaths = ArrayList<String>()
        this.resaleStarGifts = ArrayList<StarGiftViewModel>()
        this.resaleStarGiftPaths = ArrayList<String>()
        this.transferStarGifts = ArrayList<SavedStarGiftViewModel>()
        this.transferStarGiftPaths = ArrayList<String>()
        this.starGifts = ArrayList<StarGiftViewModel>()
        this.starGiftPaths = ArrayList<String>()
        this.giftFilter = 0
        this.hasResaleGifts = false
        this.message = ""
        this.showGiftSetup = false
        this.showStarGiftSetup = false
        this.hideGiftSender = false
        this.includeGiftUpgrade = false
    }

    private func purchaseSelectedGift(): Unit {
        if (this.purchasing || this.selectedOption < 0 || this.selectedOption >= this.giftOptions.size) { return }
        let opt = this.giftOptions[this.selectedOption]
        if (this.payWithStars) {
            let starsPrice = this.selectedStarsPrice()
            if (starsPrice <= 0) { this.purchaseError = "This gift is not available with Stars."; return }
            if (this.starsBalance < starsPrice) { routerPush("StarsPage", "topup"); return }
            let user: TLObject = if (this.selectedPeerId == this.selfId) {
                InputUserSelf()
            } else {
                let selectedUser = InputUser()
                selectedUser.userId = this.selectedPeerId
                selectedUser.accessHash = this.selectedAccessHash
                selectedUser
            }
            this.purchasing = true
            this.purchaseError = ""
            let _ = spawn {
                let result = getPaymentsService().sendPremiumGiftWithStars(user, opt.months, this.message)
                let balanceState = PaymentsDataProvider().getStarsStatus()
                launch {
                    this.purchasing = false
                    if (result.success) {
                        this.starsBalance = balanceState.balanceStars
                        routerPop()
                    } else {
                        this.purchaseError = if (result.errorMessage.size > 0) { result.errorMessage } else { "Telegram could not send this gift." }
                    }
                }
            }
            return
        }
        if (opt.storeProduct.size == 0) { this.purchaseError = "This gift is not available from the store."; return }
        let purpose = InputStorePaymentPremiumGiftCode()
        purpose.currency = opt.currency
        purpose.amount = opt.amount
        purpose.message = this.message
        if (this.selectedPeerId == this.selfId) {
            purpose.users.add(InputUserSelf())
        } else {
            let user = InputUser()
            user.userId = this.selectedPeerId
            user.accessHash = this.selectedAccessHash
            purpose.users.add(user)
        }
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
                        if (!giftJsonOk(result)) {
                            launch { this.purchasing = false; this.purchaseError = "Purchase was cancelled or could not be completed." }
                            return
                        }
                        let receipt = giftJsonReceipt(result)
                        let _ = spawn {
                            let sent = getInAppPurchaseManagerService().sendStoreReceipt(receipt.toArray(), purpose)
                            launch {
                                this.purchasing = false
                                if (sent) { routerPop() } else { this.purchaseError = "Telegram could not confirm this purchase." }
                            }
                        }
                    })
                }
            }
        }
    }

    private func optionTitle(opt: PremiumGiftCodeOptionViewModel): String {
        if (opt.months == 1) { return "1 Month Premium" }
        return "${opt.months} Months Premium"
    }

    private func buttonTitle(): String {
        if (this.payWithStars) {
            let starsPrice = this.selectedStarsPrice()
            if (starsPrice > 0) { return "Send a Gift for ⭐ ${starsPrice}" }
        }
        if (this.selectedOption >= 0 && this.selectedOption < this.giftOptions.size) {
            return "Send a Gift for ${this.giftOptions[this.selectedOption].formattedAmount}"
        }
        return "Send a Gift"
    }

    private func optionAt(index: Int64): PremiumGiftCodeOptionViewModel {
        return this.giftOptions[index]
    }

    private func selectedStarsPrice(): Int64 {
        if (this.selectedOption < 0 || this.selectedOption >= this.giftOptions.size) { return 0 }
        let months = this.giftOptions[this.selectedOption].months
        for (option in this.starsGiftOptions) {
            if (option.months == months) { return option.amount }
        }
        return 0
    }

    private func giftOptionForMonths(months: Int32): Int64 {
        var index: Int64 = 0
        for (option in this.giftOptions) {
            if (option.months == months) { return index }
            index = index + 1
        }
        return -1
    }

    private func giftDiscount(opt: PremiumGiftCodeOptionViewModel): Int64 {
        let shortIndex = this.giftOptionForMonths(3)
        if (shortIndex < 0) { return 0 }
        let short = this.giftOptions[shortIndex]
        if (short.amount <= 0 || opt.months <= 3) { return 0 }
        let regular = short.amount * Int64(opt.months) / 3
        if (regular <= opt.amount) { return 0 }
        let raw = (regular - opt.amount) * 100 / regular
        return ((raw + 2) / 5) * 5
    }

    private func purchaseSelectedStarGift(): Unit {
        if (this.purchasing || this.selectedStarGift < 0 || this.selectedStarGift >= this.starGifts.size) { return }
        if (this.giftFilter == 2) {
            if (this.selectedStarGift >= this.transferStarGifts.size) { return }
            let saved = this.transferStarGifts[this.selectedStarGift]
            if (saved.transferStars > 0 && this.starsBalance < saved.transferStars) { routerPush("StarsPage", "topup"); return }
            this.purchasing = true
            this.purchaseError = ""
            let _ = spawn {
                if (saved.transferStars > 0) {
                    let result = getPaymentsService().transferStarGiftWithStars(saved.msgId, this.selectedPeerId, this.selectedAccessHash)
                    let balanceState = PaymentsDataProvider().getStarsStatus()
                    launch {
                        this.purchasing = false
                        if (result.success) {
                            this.starsBalance = balanceState.balanceStars
                            this.showStarGiftSetup = false
                            routerPop()
                        } else {
                            this.purchaseError = if (result.errorMessage.size > 0) { result.errorMessage } else { "Telegram could not transfer this gift." }
                        }
                    }
                } else {
                    let result = PaymentsDataProvider().transferStarGift(saved.msgId, this.selectedPeerId, this.selectedAccessHash)
                    launch {
                        this.purchasing = false
                        if (result.success) {
                            this.showStarGiftSetup = false
                            routerPop()
                        } else {
                            this.purchaseError = if (result.errorMessage.size > 0) { result.errorMessage } else { "Telegram could not transfer this gift." }
                        }
                    }
                }
            }
            return
        }
        let gift = this.starGifts[this.selectedStarGift]
        if (this.starsBalance < this.selectedStarGiftPrice()) { routerPush("StarsPage", "topup"); return }
        let peer: TLObject = if (this.selectedPeerId == this.selfId) {
            InputPeerSelf()
        } else {
            let selectedPeer = InputPeerUser()
            selectedPeer.userId = this.selectedPeerId
            selectedPeer.accessHash = this.selectedAccessHash
            selectedPeer
        }
        this.purchasing = true
        this.purchaseError = ""
        let _ = spawn {
            let result = getPaymentsService().sendStarGift(peer, gift.id, this.message, this.hideGiftSender, this.includeGiftUpgrade)
            let balanceState = PaymentsDataProvider().getStarsStatus()
            launch {
                this.purchasing = false
                if (result.success) {
                    this.starsBalance = balanceState.balanceStars
                    this.showStarGiftSetup = false
                    routerPop()
                } else {
                    this.purchaseError = if (result.errorMessage.size > 0) { result.errorMessage } else { "Telegram could not send this gift." }
                }
            }
        }
    }

    private func applyGiftFilter(filter: Int32): Unit {
        this.giftFilter = filter
        if (filter == 1) {
            this.starGifts = this.resaleStarGifts
            this.starGiftPaths = this.resaleStarGiftPaths
        } else if (filter == 2) {
            let gifts = ArrayList<StarGiftViewModel>()
            for (entry in this.transferStarGifts) { gifts.add(entry.gift) }
            this.starGifts = gifts
            this.starGiftPaths = this.transferStarGiftPaths
        } else {
            this.starGifts = this.allStarGifts
            this.starGiftPaths = this.allStarGiftPaths
        }
        this.selectedStarGift = -1
        this.showStarGiftSetup = false
    }

    private func starGiftGridHeight(): Int64 {
        return ((this.starGifts.size + 2) / 3) * 164
    }

    private func starGiftPrice(gift: StarGiftViewModel): String {
        if (this.giftFilter == 2) {
            var index: Int64 = 0
            for (entry in this.transferStarGifts) {
                if (entry.gift.slug == gift.slug) { return if (entry.transferStars > 0) { "${entry.transferStars}" } else { "Free" } }
                index = index + 1
            }
        }
        if (this.giftFilter == 1 && gift.availabilityRemains == 0 && gift.resellMinStars > 0) {
            return if (gift.availabilityResale > 1) { "${gift.resellMinStars}+" } else { "${gift.resellMinStars}" }
        }
        return "${gift.stars}"
    }

    private func selectedStarGiftPrice(): Int64 {
        if (this.selectedStarGift < 0 || this.selectedStarGift >= this.starGifts.size) { return 0 }
        let gift = this.starGifts[this.selectedStarGift]
        return gift.stars + if (this.includeGiftUpgrade) { gift.upgradeStars } else { 0 }
    }

    private func starGiftRibbon(gift: StarGiftViewModel): String {
        if (this.giftFilter == 2) { return "" }
        if (gift.isAuction) { return if (gift.auctionStartDate > 0) { "soon" } else { "auction" } }
        if (gift.isSoldOut || (gift.isLimited && gift.availabilityRemains == 0)) {
            return if (gift.availabilityResale > 0) { "resale" } else { "sold out" }
        }
        if (gift.requiresPremium) { return "premium" }
        if (gift.isLimited) { return if (gift.availabilityRemains > 0) { "${gift.availabilityRemains}" } else { "limited" } }
        return ""
    }

    @Builder
    private func avatar(initial: String, size: Int64, peerId: Int64) {
        Stack(alignContent: Alignment.Center) {
            if (peerId == this.selfId && initial == this.selfInitial && this.selfAvatarEmojiId != 0) {
                Column {
                    CustomEmojiImage(documentId: this.selfAvatarEmojiId, size: Float64(size) * 0.72, placeholder: "", autoplay: true)
                }.width(size).height(size).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                    .linearGradient(angle: 180.0, colors: [(Color(this.selfAvatarBackgroundStart), 0.0), (Color(this.selfAvatarBackgroundEnd), 1.0)])
            } else if (peerId == this.selfId && initial == this.selfInitial && this.selfAvatarPath.size > 0) {
                Image(this.selfAvatarPath).width(size).height(size).objectFit(ImageFit.Cover).borderRadius(Float64(size) / 2.0)
            } else {
                Circle().width(size).height(size).fill(0xFF8E44AD)
                Text(initial).fontSize(if (size > 50) { 28 } else { 18 }).fontWeight(FontWeight.Medium).fontColor(0xFFFFFFFF)
            }
        }.width(size).height(size).borderRadius(Float64(size) / 2.0).clip(true)
    }

    @Builder
    private func permissionCard() {
        Column {
            Row {
                Text("!").width(22).height(22).borderRadius(11).backgroundColor(0xFFFF3B30).fontColor(0xFFFFFFFF)
                    .fontSize(15).fontWeight(FontWeight.Bold).textAlign(TextAlign.Center).margin(right: 10)
                Text(trSource("Access to Contacts")).fontSize(17).fontWeight(FontWeight.Bold).layoutWeight(1)
                Text("×").fontSize(24).fontColor(0xFFC7C7CC).onClick({ _ => this.showPermissionCard = false })
            }.width(100.percent)
            Text(trSource("Please allow Telegram access to your phonebook to seamlessly find all your friends."))
                .fontSize(15).fontColor(0xFF6D6D72).lineHeight(21).width(100.percent).margin(top: 9, bottom: 11)
            Divider().strokeWidth(0.5).color(0xFFE5E5EA)
            Text(if (this.permissionAsked) { "Allow in Settings" } else { "Allow Access" })
                .fontSize(17).fontColor(0xFF007AFF).width(100.percent).padding(top: 11, bottom: 2)
                .onClick({ _ => this.requestContacts() })
        }.width(100.percent).padding(left: 16, right: 16, top: 12, bottom: 9).backgroundColor(0xFFFFFFFF)
    }

    @Builder
    private func personRow(name: String, initial: String, subtitle: String, id: Int64, accessHash: Int64) {
        Row {
            this.avatar(initial, 44, id)
            Column {
                Text(name).fontSize(17).fontColor(0xFF111111).maxLines(1)
                Text(subtitle).fontSize(14).fontColor(0xFF8E8E93).margin(top: 2)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin(left: 12)
        }.width(100.percent).height(58).padding(left: 16, right: 16).backgroundColor(0xFFFFFFFF)
            .onClick({ _ => this.selectRecipient(id, accessHash, name, initial) })
    }

    @Builder
    private func recipientPicker() {
        Column {
            Stack(alignContent: Alignment.Center) {
                Text("Send a Gift").fontSize(18).fontWeight(FontWeight.Bold)
                Button {
                    Image(@r(app.media.nav_ic_close)).width(16).height(16).fillColor(0xFF111111)
                }.width(34).height(34).borderRadius(17).backgroundColor(0xFFE5E5EA)
                    .position(x: 12, y: 9).onClick({ _ => routerPop() })
            }.height(52).width(100.percent)
            TextInput(text: this.query, placeholder: "Search")
                .onChange({ value => this.query = value }).height(36).width(100.percent).margin(left: 16, right: 16, bottom: 8)
                .backgroundColor(0xFFE9E9ED).borderRadius(10).fontSize(16).padding(left: 12, right: 12)
            Scroll {
                Column {
                    if (!this.permissionGranted && this.showPermissionCard) { this.permissionCard() }
                    Row {
                        Stack(alignContent: Alignment.Center) {
                            Circle().width(44).height(44).fill(0xFF5AC8FA)
                            Image(@r(app.media.editprofile_ic_birthday)).width(25).height(25).fillColor(0xFFFFFFFF)
                        }.margin(right: 12)
                        Text("Add Your Birthday").fontSize(17).fontColor(0xFF007AFF).layoutWeight(1)
                        Text("›").fontSize(25).fontColor(0xFFC7C7CC)
                    }.width(100.percent).height(58).padding(left: 16, right: 14).backgroundColor(0xFFFFFFFF)
                        .onClick({ _ => routerPush("EditProfilePage", "birthday") })
                    Text("THIS IS YOU").fontSize(13).fontColor(0xFF8E8E93).width(100.percent).padding(left: 16, top: 18, bottom: 6)
                    this.personRow(this.selfName, this.selfInitial, "buy yourself a gift", this.selfId, 0)
                    if (this.contacts.size > 0) {
                        Text("FREQUENT CONTACTS").fontSize(13).fontColor(0xFF8E8E93).width(100.percent).padding(left: 16, top: 18, bottom: 6)
                        ForEach(this.contacts, itemGenerator: { contact: ContactDisplayData, idx: Int64 =>
                            if (this.contactVisible(contact)) {
                                if (idx > 0) { Divider().strokeWidth(0.5).color(0xFFE5E5EA).margin(left: 72) }
                                this.personRow(contact.getDisplayName(), contact.getAvatarInitials(), contact.getLastSeenText(), contact.userId, contact.accessHash)
                            }
                        })
                    }
                }.width(100.percent).height(100.percent).justifyContent(FlexAlign.Start)
            }.layoutWeight(1).scrollBar(BarState.Off)
        }.width(100.percent).height(100.percent).backgroundColor(0xFFF2F2F7)
    }

    @Builder
    private func giftArtwork(months: Int32, size: Int64) {
        if (months <= 3) { Image(@r(app.media.premium_gift_3)).width(size).height(size) }
        else if (months <= 6) { Image(@r(app.media.premium_gift_6)).width(size).height(size) }
        else { Image(@r(app.media.premium_gift_12)).width(size).height(size) }
    }

    @Builder
    private func giftOptionCard(opt: PremiumGiftCodeOptionViewModel, idx: Int64) {
        Stack(alignContent: Alignment.TopEnd) {
        Column {
            Stack(alignContent: Alignment.Center) {
                this.giftArtwork(opt.months, 60)
            }.width(88).height(88)
            Text(if (opt.months == 12) { "1 year" } else { "${opt.months} months" })
                .fontSize(17).fontWeight(FontWeight.Bold).textAlign(TextAlign.Center)
            Text("Premium").fontSize(15).textAlign(TextAlign.Center)
            Text(opt.formattedAmount).fontSize(15).fontWeight(FontWeight.Medium).fontColor(0xFF007AFF)
                .padding(left: 10, right: 10, top: 5, bottom: 5).backgroundColor(0xFFE8F4FF).borderRadius(15).margin(top: 5)
        }.width(100.percent).height(178).padding(top: 5).backgroundColor(0xFFFFFFFF).borderRadius(14)
        if (this.giftDiscount(opt) > 0) {
            Stack(alignContent: Alignment.Center) {
                Image(@r(app.media.gift_ribbon)).width(58).height(58)
                Text("-${this.giftDiscount(opt)}%").fontSize(10).fontWeight(FontWeight.Medium).fontColor(0xFFFFFFFF)
                    .rotate(angle: 45.0).translate(x: 9, y: -9)
            }.width(58).height(58)
        }
        }.width(30.percent).height(178)
            .onClick({ _ => this.selectedOption = idx; this.showGiftSetup = true })
    }

    @Builder
    private func giftFilterButton(title: String, filter: Int32) {
        if (this.giftFilter == filter) {
            Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(0xFF6D6D72)
                .padding(left: 14, right: 14, top: 7, bottom: 7)
                .backgroundColor(0xFFE1E1E6).borderRadius(16)
                .onClick({ _ => this.applyGiftFilter(filter) })
        } else {
            Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(0xFF8E8E93)
                .padding(left: 14, right: 14, top: 7, bottom: 7)
                .onClick({ _ => this.applyGiftFilter(filter) })
        }
    }

    @Builder
    private func starGiftCard(gift: StarGiftViewModel, idx: Int64) {
        Stack(alignContent: Alignment.TopEnd) {
            Column {
                if (!this.showStarGiftSetup && idx < this.starGiftPaths.size && this.starGiftPaths[idx].size > 0) {
                    AnimatedStickerComponent(documentId: gift.documentId, localPath: this.starGiftPaths[idx], displaySize: 88.0,
                        isVideoSticker: gift.documentMimeType.contains("webm"))
                } else {
                    LoadingProgress().width(30).height(30).margin(top: 29, bottom: 29)
                }
                Row {
                    Image(@r(app.media.stars_balance)).width(18).height(18)
                    Text(this.starGiftPrice(gift)).fontSize(15).fontWeight(FontWeight.Medium).fontColor(0xFFB66A00).margin(left: 3)
                }.padding(left: 10, right: 10, top: 5, bottom: 5).backgroundColor(0xFFFFF2D8).borderRadius(14)
            }.width(100.percent).height(154).justifyContent(FlexAlign.Center).backgroundColor(0xFFFFFFFF).borderRadius(14)
            if (this.starGiftRibbon(gift).size > 0) {
                Stack(alignContent: Alignment.Center) {
                    Image(if (gift.availabilityResale > 0) { @r(app.media.gift_ribbon_green) } else { @r(app.media.gift_ribbon) }).width(58).height(58)
                    Text(this.starGiftRibbon(gift)).fontSize(10).fontWeight(FontWeight.Medium).fontColor(0xFFFFFFFF)
                        .rotate(angle: 45.0).translate(x: 9, y: -9)
                }.width(58).height(58)
            }
        }.width(100.percent).height(154).onClick({ _ =>
            if (gift.lockedUntilDate > 0) {
                this.showGiftMessage("This gift is not available yet.")
            } else if (gift.perUserTotal > 0 && gift.perUserRemains == 0 && gift.availabilityResale == 0) {
                this.showGiftMessage("You have reached the purchase limit for this gift.")
            } else if (gift.requiresPremium && !this.isPremiumUser() && gift.availabilityResale == 0) {
                routerPush("PremiumPage", "")
            } else if ((gift.isSoldOut || (gift.isLimited && gift.availabilityRemains == 0)) && gift.availabilityResale > 0) {
                routerPush("GiftStorePage", "${gift.id}|${gift.title}|${this.selectedPeerId}|${this.selectedAccessHash}")
            } else if (!gift.isAuction && !(gift.isSoldOut || (gift.isLimited && gift.availabilityRemains == 0))) {
                this.includeGiftUpgrade = false
                this.selectedStarGift = idx
                this.showStarGiftSetup = true
            }
        })
    }

    private func isPremiumUser(): Bool {
        match (getAuthStorage().getUserData()) {
            case Some(user) => return user.isPremium
            case None => return false
        }
    }

    private func showGiftMessage(message: String): Unit {
        getUIContext().showAlertDialog(AlertDialogParamWithConfirm(
            message: message,
            confirm: AlertDialogButtonOptions(value: "OK", action: { => () })
        ))
    }

    @Builder
    private func giftOptionsOverview() {
        Column {
            Row {
                Button {
                    Image(@r(app.media.nav_ic_close)).width(18).height(18).fillColor(0xFF111111)
                }.width(42).height(42).borderRadius(21).backgroundColor(0xFFE5E5EA)
                    .onClick({ _ => this.closeRecipient() })
                Column { }.layoutWeight(1)
                Column {
                    Text("Balance").fontSize(13).fontColor(0xFF111111)
                    Row { Image(@r(app.media.stars_balance)).width(18).height(18); Text("${this.starsBalance}").fontSize(17).margin(left: 3) }
                }.height(44).padding(left: 12, right: 12).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                    .backgroundColor(0xFFFFFFFF).borderRadius(22)
            }.height(60).width(100.percent).padding(left: 14, right: 14)
            Scroll {
                Column {
                    if (this.optionsLoading) {
                        LoadingProgress().width(34).height(34).margin(top: 30)
                    } else {
                        if (this.selectedPeerId != this.selfId) {
                            Stack(alignContent: Alignment.Center) {
                                Image(@r(app.media.gift_particles)).width(100.percent).height(220).objectFit(ImageFit.Fill)
                                Column {
                                    this.avatar(this.selectedInitial, 82, this.selectedPeerId)
                                    Text("Gift Premium").fontSize(28).fontWeight(FontWeight.Bold).margin(top: 10)
                                }.justifyContent(FlexAlign.Center)
                            }.width(100.percent).height(188)
                            Column {
                                Text("Give ${this.selectedName} access to exclusive features").fontSize(15).fontColor(0xFF111111)
                                Row {
                                    Text("with Telegram Premium. ").fontSize(15).fontColor(0xFF111111)
                                    Text("See Features ›").fontSize(15).fontColor(0xFF007AFF)
                                        .onClick({ _ => routerPush("PremiumPage", "") })
                                }
                            }.alignItems(HorizontalAlign.Center).margin(top: 7, bottom: 20)
                            if (this.giftOptions.size > 0) {
                                Row(space: 10) {
                                    if (this.giftOptionForMonths(3) >= 0) { this.giftOptionCard(this.giftOptions[this.giftOptionForMonths(3)], this.giftOptionForMonths(3)) }
                                    if (this.giftOptionForMonths(6) >= 0) { this.giftOptionCard(this.giftOptions[this.giftOptionForMonths(6)], this.giftOptionForMonths(6)) }
                                    if (this.giftOptionForMonths(12) >= 0) { this.giftOptionCard(this.giftOptions[this.giftOptionForMonths(12)], this.giftOptionForMonths(12)) }
                                }.width(100.percent).padding(left: 16, right: 16)
                            } else if (this.optionsError.size > 0) {
                                Text(this.optionsError).fontSize(15).fontColor(0xFF8E8E93).margin(top: 24)
                            }
                        } else {
                            Stack(alignContent: Alignment.Center) {
                                Image(@r(app.media.gift_particles)).width(100.percent).height(220).objectFit(ImageFit.Fill)
                                Column {
                                    this.avatar(this.selectedInitial, 82, this.selectedPeerId)
                                    Text("Buy a Gift").fontSize(28).fontWeight(FontWeight.Bold).margin(top: 10)
                                }.justifyContent(FlexAlign.Center)
                            }.width(100.percent).height(188)
                            Text("Buy yourself a gift to add to your\nprofile or reserve for later.")
                                .fontSize(15).fontColor(0xFF111111).textAlign(TextAlign.Center).lineHeight(21).margin(top: 7)
                            Text("Limited-edition gifts upgraded to\ncollectibles can be gifted to others.")
                                .fontSize(15).fontColor(0xFF111111).textAlign(TextAlign.Center).lineHeight(21).margin(top: 18, bottom: 12)
                        }
                        if (this.starGifts.size > 0 || this.allStarGifts.size > 0) {
                            if (this.selectedPeerId != this.selfId) {
                                Text("Send a Gift").fontSize(28).fontWeight(FontWeight.Bold).margin(top: 44)
                            }
                            if (this.giftFilter == 1 && this.selectedPeerId != this.selfId) {
                                Text("Collectible gifts are unique digital\nitems you can exchange or sell.")
                                    .fontSize(15).fontColor(0xFF111111).textAlign(TextAlign.Center).lineHeight(20).margin(top: 8, bottom: 12)
                            } else if (this.giftFilter == 2) {
                                Text("Transfer one of your collectible gifts to ${this.selectedName}.")
                                    .fontSize(15).fontColor(0xFF111111).textAlign(TextAlign.Center).margin(top: 8, bottom: 12)
                            } else if (this.selectedPeerId != this.selfId) {
                                Column {
                                    Text("Give ${this.selectedName} gifts that can be kept on the profile").fontSize(15).fontColor(0xFF111111)
                                    Row {
                                        Text("or converted to Stars. ").fontSize(15).fontColor(0xFF111111)
                                        Text("What are Stars ›").fontSize(15).fontColor(0xFF007AFF).onClick({ _ => this.showStarsInfo = true })
                                    }
                                }.alignItems(HorizontalAlign.Center).margin(top: 8, bottom: 12)
                            }
                            if (this.hasResaleGifts || this.transferStarGifts.size > 0) {
                                Row(space: 6) {
                                    this.giftFilterButton(if (this.selectedPeerId == this.selfId) { "All Gifts" } else { "All" }, 0)
                                    if (this.transferStarGifts.size > 0) { this.giftFilterButton("My Gifts", 2) }
                                    if (this.hasResaleGifts) { this.giftFilterButton("Collectibles", 1) }
                                }.justifyContent(FlexAlign.Center).width(100.percent).margin(bottom: 14)
                            }
                            if (this.starGifts.size > 0) {
                                Grid {
                                    ForEach(this.starGifts, itemGenerator: { gift: StarGiftViewModel, idx: Int64 =>
                                        GridItem { this.starGiftCard(gift, idx) }
                                    })
                                }.columnsTemplate("1fr 1fr 1fr").columnsGap(10).rowsGap(10)
                                    .width(100.percent).height(this.starGiftGridHeight()).padding(left: 16, right: 16)
                            }
                        }
                    }
                }.width(100.percent).padding(top: 12, bottom: 30.0 + getSafeAreaBottom())
            }.layoutWeight(1).scrollBar(BarState.Off)
        }.width(100.percent).height(100.percent).backgroundColor(0xFFF2F2F7)
    }

    @Builder
    private func giftSetupSheet() {
        Stack(alignContent: Alignment.Bottom) {
            Column { }.width(100.percent).height(100.percent).backgroundColor(0x77000000)
                .onClick({ _ => this.showGiftSetup = false })
            Column {
                if (this.selectedOption >= 0 && this.selectedOption < this.giftOptions.size) {
                    Text("You sent a gift for ${this.optionAt(this.selectedOption).formattedAmount}")
                        .fontSize(15).fontWeight(FontWeight.Medium).fontColor(0xFFFFFFFF)
                        .padding(left: 12, right: 12, top: 5, bottom: 5).borderRadius(14).backgroundColor(0xFF5BAE39).margin(top: 26)
                    this.giftArtwork(this.optionAt(this.selectedOption).months, 156)
                    Text(this.optionTitle(this.optionAt(this.selectedOption))).fontSize(20).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                    Text("Subscription for exclusive\nTelegram features.").fontSize(16).fontColor(0xFFFFFFFF).textAlign(TextAlign.Center).lineHeight(20).margin(top: 5)
                    Button("View").height(38).padding(left: 24, right: 24).borderRadius(19).backgroundColor(0x33407838)
                        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF).margin(top: 12)
                    TextInput(text: this.message, placeholder: "Enter Message (Optional)")
                        .onChange({ value => this.message = value }).height(48).width(100.percent).margin(left: 24, right: 24, top: 20, bottom: 18)
                        .backgroundColor(0xEFFFFFFF).borderRadius(24).fontSize(16).padding(left: 18, right: 18)
                }
                Column {
                    if (this.selectedStarsPrice() > 0) {
                        Row {
                            Text("Pay with ⭐ ${this.selectedStarsPrice()}").fontSize(17).layoutWeight(1)
                            Toggle(ToggleType.Switch, isOn: this.payWithStars).selectedColor(0xFF34C759).onChange({ on: Bool => this.payWithStars = on })
                        }.height(56).padding(left: 16, right: 12).backgroundColor(0xFFFFFFFF).borderRadius(14)
                        Row {
                            Text("Your balance is ⭐ ${this.starsBalance}.").fontSize(14).fontColor(0xFF8E8E93)
                            Text(" Get More Stars ›").fontSize(14).fontColor(0xFF007AFF).onClick({ _ => routerPush("StarsPage", "topup") })
                        }.width(100.percent).padding(left: 18).margin(top: 9)
                    }
                    if (this.purchaseError.size > 0) {
                        Text(this.purchaseError).fontSize(13).fontColor(0xFFFF3B30).textAlign(TextAlign.Center).width(100.percent).margin(top: 10)
                    }
                    Button(this.buttonTitle()).width(100.percent).height(50).margin(top: 30, bottom: 10.0 + getSafeAreaBottom())
                        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF).backgroundColor(0xFF007AFF).borderRadius(25)
                        .enabled(!this.purchasing).onClick({ _ => this.purchaseSelectedGift() })
                }.width(100.percent).padding(left: 24, right: 24, top: 18).backgroundColor(0xFFF2F2F7)
            }.width(100.percent).height(78.percent)
                .linearGradient(angle: 135.0, colors: [(Color(0xFFB9D94C), 0.0), (Color(0xFF2DA770), 1.0)])
                .borderRadius(topLeft: 28, topRight: 28)
            Button {
                Image(@r(app.media.nav_ic_close)).width(18).height(18).fillColor(0xFF111111)
            }.width(44).height(44).borderRadius(22).backgroundColor(0xEEFFFFFF)
                .position(x: 22, y: 190).onClick({ _ => this.showGiftSetup = false })
        }.width(100.percent).height(100.percent)
    }

    @Builder
    private func starGiftSetupSheet() {
        Stack(alignContent: Alignment.Bottom) {
            Column { }.width(100.percent).height(100.percent).backgroundColor(0x77000000)
                .onClick({ _ => this.showStarGiftSetup = false })
            if (this.selectedStarGift >= 0 && this.selectedStarGift < this.starGifts.size && this.giftFilter == 2) {
                Column {
                    if (this.selectedStarGift < this.starGiftPaths.size && this.starGiftPaths[this.selectedStarGift].size > 0) {
                        AnimatedStickerComponent(documentId: this.starGifts[this.selectedStarGift].documentId,
                            localPath: this.starGiftPaths[this.selectedStarGift], displaySize: 190.0,
                            isVideoSticker: this.starGifts[this.selectedStarGift].documentMimeType.contains("webm"))
                    }
                    Text("Transfer Gift").fontSize(24).fontWeight(FontWeight.Bold).margin(top: 4)
                    Text("This collectible will be transferred to ${this.selectedName} and removed from your profile.")
                        .fontSize(15).fontColor(0xFF6D6D72).textAlign(TextAlign.Center).lineHeight(21)
                        .padding(left: 24, right: 24).margin(top: 8)
                    if (this.purchaseError.size > 0) {
                        Text(this.purchaseError).fontSize(13).fontColor(0xFFFF3B30).textAlign(TextAlign.Center).margin(top: 10)
                    }
                    Button(
                        if (this.transferStarGifts[this.selectedStarGift].transferStars > 0) {
                            "Transfer for ⭐ ${this.transferStarGifts[this.selectedStarGift].transferStars}"
                        } else { "Transfer" }
                    )
                        .width(100.percent).height(50).margin(left: 24, right: 24, top: 22, bottom: 10.0 + getSafeAreaBottom())
                        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF).backgroundColor(0xFF007AFF).borderRadius(25)
                        .enabled(!this.purchasing).onClick({ _ => this.purchaseSelectedStarGift() })
                }.width(100.percent).backgroundColor(0xFFFFFFFF).borderRadius(topLeft: 28, topRight: 28).padding(top: 20)
            } else if (this.selectedStarGift >= 0 && this.selectedStarGift < this.starGifts.size) {
                Column {
                    Scroll {
                        Column {
                            Stack(alignContent: Alignment.TopStart) {
                                Image(@r(app.media.wallpaper_pattern_shapes)).width(100.percent).height(305)
                                    .objectFit(ImageFit.Cover).opacity(0.08).position(x: 0, y: 0)
                                Column {
                                Stack(alignContent: Alignment.Center) {
                                    Text(if (this.selectedPeerId == this.selfId) {
                                        "You bought a gift for ${this.selectedStarGiftPrice()} Stars"
                                    } else {
                                        "You sent a gift to ${this.selectedName} for ${this.selectedStarGiftPrice()} Stars"
                                    }).fontSize(14).fontWeight(FontWeight.Medium).fontColor(0xFFFFFFFF)
                                        .padding(left: 13, right: 13, top: 5, bottom: 5).backgroundColor(0xFF5BAE39).borderRadius(15)
                                    Button {
                                        Image(@r(app.media.nav_ic_close)).width(17).height(17).fillColor(0xFF111111)
                                    }.width(44).height(44).borderRadius(22).backgroundColor(0xEEFFFFFF)
                                        .position(x: 16, y: 0).onClick({ _ => this.showStarGiftSetup = false })
                                }.width(100.percent).height(48).margin(top: 14, bottom: 6)
                                Column {
                                    if (this.selectedStarGift < this.starGiftPaths.size && this.starGiftPaths[this.selectedStarGift].size > 0) {
                                        AnimatedStickerComponent(documentId: this.starGifts[this.selectedStarGift].documentId,
                                            localPath: this.starGiftPaths[this.selectedStarGift], displaySize: 90.0,
                                            isVideoSticker: this.starGifts[this.selectedStarGift].documentMimeType.contains("webm"))
                                    }
                                    Text(if (this.selectedPeerId == this.selfId) { "Purchased Gift" } else { "Gift for ${this.selectedName}" })
                                        .fontSize(18).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF).margin(top: 4)
                                    Text(if (this.selectedPeerId == this.selfId) {
                                        "Add this gift to your profile or convert it to ${this.starGifts[this.selectedStarGift].convertStars} Stars."
                                    } else {
                                        "${this.selectedName} can keep this gift on their profile or convert it to ${this.starGifts[this.selectedStarGift].convertStars} Stars."
                                    }).fontSize(15).fontColor(0xFFFFFFFF).textAlign(TextAlign.Center).lineHeight(19)
                                        .padding(left: 18, right: 18).margin(top: 5, bottom: 8)
                                    Button("View").height(32).padding(left: 22, right: 22).borderRadius(16)
                                        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                                        .backgroundColor(0x33507838).margin(bottom: 10)
                                        .onClick({ _ => FocusControl.requestFocus(this.giftPreviewFocusId) })
                                }.width(66.percent).padding(top: 8, bottom: 10).borderRadius(28)
                                    .linearGradient(angle: 135.0, colors: [
                                        (Color(0xFF80B845), 0.0),
                                        (Color(0xFF2DA770), 1.0)
                                    ])
                                TextInput(text: this.message, placeholder: "Enter Message (Optional)")
                                    .onChange({ value => this.message = value }).height(48).width(100.percent)
                                    .margin(left: 24, right: 24, top: 16, bottom: 12).backgroundColor(0xEFFFFFFF).borderRadius(24)
                                    .fontSize(16).padding(left: 18, right: 18)
                                }.width(100.percent)
                                Text(trSource("")).width(1).height(1).opacity(0.0).focusable(true).id(this.giftPreviewFocusId)
                            }.width(100.percent).linearGradient(angle: 135.0, colors: [(Color(0xFFB9D94C), 0.0), (Color(0xFF2DA770), 1.0)])
                            if (this.starGifts[this.selectedStarGift].upgradeStars > 0) {
                                Column {
                                    Row {
                                        Text("Make Unique for ⭐ ${this.starGifts[this.selectedStarGift].upgradeStars}").fontSize(17).layoutWeight(1)
                                        Toggle(ToggleType.Switch, isOn: this.includeGiftUpgrade).selectedColor(0xFF34C759)
                                            .onChange({ on: Bool => this.includeGiftUpgrade = on })
                                    }.height(56).padding(left: 16, right: 12).backgroundColor(0xFFFFFFFF).borderRadius(14)
                                    Text("Enable this to let ${if (this.selectedPeerId == this.selfId) { "you" } else { this.selectedName }} turn the gift into a unique collectible.")
                                        .fontSize(13).fontColor(0xFF6D6D72).lineHeight(18).width(100.percent).padding(left: 16, right: 16).margin(top: 7)
                                }.width(100.percent).padding(left: 24, right: 24).margin(bottom: 16)
                            }
                            Column {
                                Row {
                                    Text("Hide My Name").fontSize(17).layoutWeight(1)
                                    Toggle(ToggleType.Switch, isOn: this.hideGiftSender).selectedColor(0xFF34C759)
                                        .onChange({ on: Bool => this.hideGiftSender = on })
                                }.height(56).padding(left: 16, right: 12).backgroundColor(0xFFFFFFFF).borderRadius(14)
                                Text(if (this.selectedPeerId == this.selfId) {
                                    "Hide my name and message from visitors to my profile."
                                } else {
                                    "Hide my name and message from visitors to ${this.selectedName}'s profile. ${this.selectedName} will still see them."
                                }).fontSize(13).fontColor(0xFF6D6D72).lineHeight(18).width(100.percent)
                                    .padding(left: 16, right: 16).margin(top: 7)
                            }.width(100.percent).padding(left: 24, right: 24)
                            if (this.purchaseError.size > 0) {
                                Text(this.purchaseError).fontSize(13).fontColor(0xFFFF3B30).textAlign(TextAlign.Center).margin(top: 10)
                            }
                        }.width(100.percent).padding(bottom: 18).backgroundColor(0xFFF2F2F7)
                    }.layoutWeight(1).scrollBar(BarState.Off)
                    Button("${if (this.selectedPeerId == this.selfId) { "Buy" } else { "Send" }} a Gift for ⭐ ${this.selectedStarGiftPrice()}")
                        .width(100.percent).height(52).margin(left: 30, right: 30, top: 8, bottom: 12.0 + getSafeAreaBottom())
                        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF).backgroundColor(0xFF007AFF).borderRadius(26)
                        .enabled(!this.purchasing).onClick({ _ => this.purchaseSelectedStarGift() })
                }.width(100.percent).height(80.percent).borderRadius(topLeft: 30, topRight: 30).backgroundColor(0xFFF2F2F7)
            }
            if (this.giftFilter == 2) {
                Button {
                    Image(@r(app.media.nav_ic_close)).width(17).height(17).fillColor(0xFF111111)
                }.width(44).height(44).borderRadius(22).backgroundColor(0xFFE5E5EA)
                    .position(x: 22, y: 510).onClick({ _ => this.showStarGiftSetup = false })
            }
        }.width(100.percent).height(100.percent)
    }

    @Builder
    private func starsInfoSheet() {
        Stack(alignContent: Alignment.Bottom) {
            Column { }.width(100.percent).height(100.percent).backgroundColor(0x66000000)
                .onClick({ _ => this.showStarsInfo = false })
            Column {
                Scroll {
                    Column {
                        Image(@r(app.media.premium_star_intro)).width(100.percent).height(190).objectFit(ImageFit.Fill)
                        Text("What are Stars?").fontSize(20).fontWeight(FontWeight.Bold).margin(top: -6)
                        Text("Telegram Stars allow users to:").fontSize(14).fontColor(0xFF8E8E93).margin(top: 8, bottom: 14)
                        Row {
                            Image(@r(app.media.stars_perk_gift)).width(30).height(30).margin(right: 14)
                            Column {
                                Text("Send Gifts to Friends").fontSize(15).fontWeight(FontWeight.Bold).width(100.percent)
                                Text("Give your friends gifts that can be kept on their profiles or converted to Stars.")
                                    .fontSize(14).fontColor(0xFF8E8E93).lineHeight(18).width(100.percent).margin(top: 3)
                            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                        }.width(100.percent).alignItems(VerticalAlign.Top).padding(left: 20, right: 20, bottom: 12)
                        Row {
                            Image(@r(app.media.stars_perk_miniapp)).width(30).height(30).margin(right: 14)
                            Column {
                                Text("Use Stars in Mini Apps").fontSize(15).fontWeight(FontWeight.Bold).width(100.percent)
                                Text() {
                                    Span("Buy additional content and services in Telegram mini apps. ").fontColor(0xFF8E8E93)
                                    Span("See Examples ›").fontColor(0xFF007AFF)
                                }.fontSize(14).lineHeight(18).width(100.percent).margin(top: 3)
                            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                        }.width(100.percent).alignItems(VerticalAlign.Top).padding(left: 20, right: 20, bottom: 12)
                        Row {
                            Image(@r(app.media.stars_perk_media)).width(30).height(30).margin(right: 14)
                            Column {
                                Text("Unlock Content in Channels").fontSize(15).fontWeight(FontWeight.Bold).width(100.percent)
                                Text("Get access to paid content and services in Telegram channels.")
                                    .fontSize(14).fontColor(0xFF8E8E93).lineHeight(18).width(100.percent).margin(top: 3)
                            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                        }.width(100.percent).alignItems(VerticalAlign.Top).padding(left: 20, right: 20, bottom: 12)
                        Row {
                            Image(@r(app.media.stars_perk_reaction)).width(30).height(30).margin(right: 14)
                            Column {
                                Text("Send Star Reactions").fontSize(15).fontWeight(FontWeight.Bold).width(100.percent)
                                Text("Support your favorite channels by sending Star reactions to their posts.")
                                    .fontSize(14).fontColor(0xFF8E8E93).lineHeight(18).width(100.percent).margin(top: 3)
                            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                        }.width(100.percent).alignItems(VerticalAlign.Top).padding(left: 20, right: 20, bottom: 14)
                    }.width(100.percent)
                }.layoutWeight(1).scrollBar(BarState.Off)
                Button("Got It").width(100.percent).height(52).margin(left: 30, right: 30, top: 8, bottom: 12.0 + getSafeAreaBottom())
                    .fontSize(17).fontWeight(FontWeight.Medium).fontColor(0xFFFFFFFF)
                    .backgroundColor(0xFF007AFF).borderRadius(26).onClick({ _ => this.showStarsInfo = false })
            }.width(100.percent).height(82.percent).backgroundColor(0xFFFFFFFF).borderRadius(topLeft: 28, topRight: 28)
        }.width(100.percent).height(100.percent)
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            if (this.loading) { Column { LoadingProgress().width(36).height(36) }.width(100.percent).height(100.percent).justifyContent(FlexAlign.Center) }
            else if (this.selectedName.size == 0) { this.recipientPicker() }
            else { this.giftOptionsOverview() }
            if (this.showGiftSetup) { this.giftSetupSheet() }
            if (this.showStarGiftSetup && this.selectedStarGift >= 0) { this.starGiftSetupSheet() }
            if (this.showStarsInfo) { this.starsInfoSheet() }
        }.width(100.percent).height(100.percent).padding(top: getSafeAreaTop()).backgroundColor(0xFFF2F2F7).onAppear({ => this.load() })
    }
}
