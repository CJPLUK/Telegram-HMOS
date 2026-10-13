package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import kit.ImageKit.PixelMap
import kit.CoreFileKit.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import std.time.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.getThemesEngineService
import ohos_app_cangjie_entry.router.routerPop
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.services.{
    getRealAuthService,
    getGlobalAbilityContext,
    openAnimatedStickerFileStream,
    StreamingLottiePlayer
}
import ohos_app_cangjie_entry.providers.{PaymentsDataProvider, StarGiftViewModel}
import ohos_app_cangjie_entry.core.mtproto.StarGiftAttributeIdEntry
import ohos_app_cangjie_entry.utils.readRawFileBytes
import ohos_app_cangjie_entry.components.getEmptyAnimatedEmojiPixelMap
import ohos_app_cangjie_entry.interop.subscribe
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

private let PROFILE_COLOR_STYLE_ANIM_DOC_ID: Int64 = -9002002

@HybridComponentEntry
@Component
public class ProfileColorPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var selectedSection: Int32 = 0
    @State var profileColor: Int32 = 0
    @State var nameColor: Int32 = 0
    @State var persistedProfileColor: Int32 = 0
    @State var persistedNameColor: Int32 = 0
    @State var saving: Bool = false
    @State var loaded: Bool = false
    @State var displayName: String = "PL"
    @State var avatarLetter: String = "P"
    @State var selectedGiftId: Int64 = 0
    @State var giftTabIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var giftTabTitles: ArrayList<String> = ArrayList<String>()
    @State var giftLoading: Bool = false
    @State var giftNames: ArrayList<String> = ArrayList<String>()
    @State var giftColorIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var selectedGift: Int32 = -1
    @State var giftMessage: String = ""
    @State var showNameColorPremiumDemoSheet: Bool = false
    @State var showNameColorPremiumIntroSheet: Bool = false
    @State var showUnsavedChangesAlert: Bool = false
    @State var showNameColorPremiumPaywallToast: Bool = false
    @State var styleAnimReady: Bool = false
    @State var styleAnimFrameIndex: Int64 = 0
    var styleAnimStream: Option<StreamingLottiePlayer> = None<StreamingLottiePlayer>
    private var styleAnimTimer: Option<Timer> = None<Timer>
    private var nameColorPremiumPaywallTimer: Option<Timer> = None<Timer>
    private var styleAnimLocalPath: String = ""
    private let profileColorBackEvent: String = "profileColorPage.back"

    private func colorHex(index: Int32): UInt32 {
        if (index == 0) { return 0x4897D8 }
        if (index == 1) { return 0x45B72D }
        if (index == 2) { return 0xE68A2E }
        if (index == 3) { return 0xD7615B }
        if (index == 4) { return 0x9B63DC }
        if (index == 5) { return 0x42A9C1 }
        if (index == 6) { return 0xCC5B92 }
        return 0x94A1AE
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        subscribe(this.profileColorBackEvent, { _payload: String => this.attemptLeave() })
        let service = getThemesEngineService()
        this.profileColor = service.getProfileHeaderColorIndex()
        this.nameColor = service.getProfileNameColorIndex()
        this.persistedProfileColor = this.profileColor
        this.persistedNameColor = this.nameColor
        match (getRealAuthService().getCurrentUser()) {
            case Some(user) =>
                this.displayName = (user.firstName + " " + user.lastName).trimAscii()
                if (this.displayName.size == 0) { this.displayName = "PL" }
                if (user.firstName.size > 0) { this.avatarLetter = user.firstName.toRuneArray()[0].toString() }
            case None =>
                match (getAuthStorage().getUserData()) {
                    case Some(user) =>
                        this.displayName = (user.firstName + " " + user.lastName).trimAscii()
                        if (this.displayName.size == 0) { this.displayName = "PL" }
                        if (user.firstName.size > 0) { this.avatarLetter = user.firstName.toRuneArray()[0].toString() }
                    case None => ()
                }
        }
        this.seedMyGiftsTab()
        this.extractStyleAnimation()
        this.loadGiftTabs()
    }

    public override func aboutToDisappear(): Unit {
        this.stopStyleAnimPlayback()
        this.cancelNameColorPremiumPaywallTimer()
    }

    private func seedMyGiftsTab(): Unit {
        let ids = ArrayList<Int64>()
        let titles = ArrayList<String>()
        ids.add(0)
        titles.add("My Gifts")
        this.giftTabIds = ids
        this.giftTabTitles = titles
    }

    private func catalogTypeTabQualifies(gift: StarGiftViewModel): Bool {
        if (gift.isUnique) { return false }
        if (gift.title.size == 0) { return false }
        return this.starGiftAvailabilityResale(gift) > 0
    }

    private func starGiftAvailabilityResale(gift: StarGiftViewModel): Int64 {
        return gift.resellMinStars
    }

    private func myGiftQualifiesAsStyle(gift: StarGiftViewModel): Bool {
        if (!gift.isUnique) { return false }
        if (this.selectedSection == 1) {
            return gift.collectibleColorId != 0 || gift.peerColorAvailable
        }
        return true
    }

    private func giftTabIdAt(index: Int64): Int64 {
        if (index < 0 || index >= this.giftTabIds.size) { return 0 }
        return this.giftTabIds[index]
    }

    private func firstCatalogGiftTabId(): Int64 {
        for (id in this.giftTabIds) {
            if (id != 0) { return id }
        }
        return 0
    }

    private func emptyGiftsPlaceholder(): String {
        if (this.selectedSection == 0) {
            return "You don't have any gifts you can use as styles for your profile."
        }
        return "You don't have any gifts you can use as styles for your name."
    }

    private func loadGiftTabs(): Unit {
        let _ = spawn {
            let ids = ArrayList<Int64>()
            let titles = ArrayList<String>()
            ids.add(0)
            titles.add("My Gifts")
            let provider = PaymentsDataProvider()
            let result = provider.getStarGiftsCatalog(0)
            if (result.loaded) {
                for (gift in result.gifts) {
                    if (this.catalogTypeTabQualifies(gift)) {
                        ids.add(gift.id)
                        titles.add(gift.title)
                    }
                }
            }
            launch {
                this.giftTabIds = ids
                this.giftTabTitles = titles
                this.loadGiftSection()
            }
        }
    }

    private func loadGiftSection(): Unit {
        if (this.giftLoading) { return }
        this.giftLoading = true
        this.giftMessage = ""
        let selectedId = this.selectedGiftId
        let _ = spawn {
            let names = ArrayList<String>()
            let colorIds = ArrayList<Int64>()
            var message = ""
            let provider = PaymentsDataProvider()
            if (selectedId == 0) {
                let result = provider.getSavedStarGifts(0, 0, "", 30, false)
                if (result.loaded) {
                    for (saved in result.gifts) {
                        if (this.myGiftQualifiesAsStyle(saved.gift)) {
                            let title = if (saved.gift.title.size > 0) {
                                saved.gift.title
                            } else {
                                "Gift #${saved.gift.id}"
                            }
                            names.add(title)
                            colorIds.add(saved.gift.collectibleColorId)
                        }
                    }
                    if (names.isEmpty()) { message = this.emptyGiftsPlaceholder() }
                } else {
                    message = this.emptyGiftsPlaceholder()
                }
            } else {
                let attrs = ArrayList<StarGiftAttributeIdEntry>()
                let result = provider.getResaleStarGifts(selectedId, "", 30, false, false, false, attrs)
                if (result.loaded) {
                    for (gift in result.gifts) {
                        if (!gift.isUnique) { continue }
                        names.add(if (gift.title.size > 0) { gift.title } else { "Gift #${gift.id}" })
                        colorIds.add(gift.collectibleColorId)
                    }
                }
            }
            let finalMessage = message
            launch {
                this.giftNames = names
                this.giftColorIds = colorIds
                this.selectedGift = -1
                this.giftMessage = finalMessage
                this.giftLoading = false
            }
        }
    }

    private func selectGiftTab(id: Int64): Unit {
        if (this.selectedGiftId == id) { return }
        this.selectedGiftId = id
        this.loadGiftSection()
    }

    private func browseGiftsForPurchase(): Unit {
        let firstCatalog = this.firstCatalogGiftTabId()
        if (firstCatalog != 0) {
            this.selectGiftTab(firstCatalog)
        }
    }

    private func extractStyleAnimation(): Unit {
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let filesDir = ctx.filesDir
                let animDir = filesDir + "/profile_color_style_anim"
                try { FileIo.mkdir(animDir) } catch (_e: Exception) {}
                let name = "Style.tgs"
                let targetPath = animDir + "/" + name
                match (readRawFileBytes(name)) {
                    case None =>
                        Hilog.info(0, "CjTelegram",
                            "[ProfileColorPage] extractStyleAnimation: readRawFileBytes returned None for ${name}")
                    case Some(data) =>
                        if (data.size > 0) {
                            try {
                                let file = FileIo.open(targetPath, mode: 0o1101)
                                let _ = FileIo.write(file.fd, data)
                                FileIo.close(file)
                                this.styleAnimLocalPath = "file://" + targetPath
                                this.loadStyleAnimation()
                            } catch (_e: Exception) {
                                Hilog.info(0, "CjTelegram",
                                    "[ProfileColorPage] extractStyleAnimation: write failed for ${name}")
                            }
                        }
                }
        }
    }

    private func loadStyleAnimation(): Unit {
        let path = this.styleAnimLocalPath
        if (path.size == 0) { return }
        let docId = PROFILE_COLOR_STYLE_ANIM_DOC_ID
        spawn {
            match (openAnimatedStickerFileStream(docId, path)) {
                case Some(player) =>
                    if (player.getFrameCount() > 1) { let _ = player.prepareNextFrame(1) }
                    launch {
                        this.styleAnimStream = Some(player)
                        this.styleAnimReady = true
                        this.styleAnimFrameIndex = 0
                        this.startStyleAnimPlayback()
                    }
                case None => ()
            }
        }
    }

    private func currentStyleAnimFrame(): PixelMap {
        match (this.styleAnimStream) {
            case Some(player) =>
                match (player.getCurrentFrame()) {
                    case Some(frame) => return frame
                    case None => return getEmptyAnimatedEmojiPixelMap()
                }
            case None => return getEmptyAnimatedEmojiPixelMap()
        }
    }

    private func startStyleAnimPlayback(): Unit {
        this.stopStyleAnimPlayback()
        var frameCount: Int64 = 0
        var frameInterval: Int32 = 0
        match (this.styleAnimStream) {
            case Some(player) =>
                frameCount = player.getFrameCount()
                frameInterval = player.getFrameDurationMs()
            case None => return
        }
        let count = frameCount
        var interval = frameInterval
        if (count <= 1) { return }
        if (interval < 16) { interval = 16 }
        this.styleAnimTimer = Some(Timer.repeat(
            Duration.millisecond * Int64(interval), Duration.millisecond * Int64(interval),
            { =>
                launch {
                    if (this.styleAnimFrameIndex + 1 >= count) {
                        this.styleAnimFrameIndex = count - 1
                        this.stopStyleAnimPlayback()
                    } else {
                        this.styleAnimFrameIndex = this.styleAnimFrameIndex + 1
                        match (this.styleAnimStream) {
                            case Some(player) => let _ = player.advanceTo(this.styleAnimFrameIndex)
                            case None => ()
                        }
                    }
                }
            }, style: CatchupStyle.Skip
        ))
    }

    private func stopStyleAnimPlayback(): Unit {
        match (this.styleAnimTimer) {
            case Some(timer) =>
                timer.cancel()
                this.styleAnimTimer = None<Timer>
            case None => ()
        }
    }

    private func selectedColor(): Int32 {
        return if (this.selectedSection == 0) { this.profileColor } else { this.nameColor }
    }

    private func saveColor(index: Int32): Unit {
        if (this.selectedSection == 0) { this.profileColor = index } else { this.nameColor = index }
    }

    private func hasUnsavedChanges(): Bool {
        if (this.profileColor != this.persistedProfileColor) { return true }
        if (this.nameColor != this.persistedNameColor) { return true }
        if (this.selectedGift >= 0) { return true }
        return false
    }

    private func attemptLeave(): Unit {
        if (this.saving) { return }
        if (!this.hasUnsavedChanges()) {
            routerPop()
            return
        }
        this.showUnsavedChangesAlert = true
    }

    private func cancelNameColorPremiumPaywallTimer(): Unit {
        match (this.nameColorPremiumPaywallTimer) {
            case Some(timer) =>
                timer.cancel()
                this.nameColorPremiumPaywallTimer = None<Timer>
            case None => ()
        }
    }

    private func startNameColorPremiumPaywallTimer(): Unit {
        this.cancelNameColorPremiumPaywallTimer()
        this.nameColorPremiumPaywallTimer = Some(Timer.once(Duration.millisecond * 5000, { =>
            spawn(UIThread) { =>
                this.showNameColorPremiumPaywallToast = false
                this.nameColorPremiumPaywallTimer = None<Timer>
            }
        }))
    }

    private func dismissNameColorPremiumPaywallToast(): Unit {
        this.cancelNameColorPremiumPaywallTimer()
        this.showNameColorPremiumPaywallToast = false
    }

    private func openNameColorPremiumDemoSheet(): Unit {
        this.showNameColorPremiumDemoSheet = true
    }

    private func openNameColorPremiumIntroSheet(): Unit {
        this.showNameColorPremiumDemoSheet = false
        this.showNameColorPremiumIntroSheet = true
    }

    @Builder
    func buildNameColorPremiumDemoSheet() {
        Column {
            Row {
                Blank().layoutWeight(1)
                Text("X").fontSize(20).fontColor(0x8E8E93).width(36).height(36)
                    .textAlign(TextAlign.Center)
                    .onClick({ _ => this.showNameColorPremiumDemoSheet = false })
            }.width(100.percent).padding(left: 16, right: 12, top: 8)
            Text(trSource("Name and Profile Colors"))
                .fontSize(22).fontWeight(FontWeight.Bold).fontColor(0x000000)
                .width(100.percent).padding(left: 20, right: 20, top: 4)
            Text(trSource("Choose a color and logo for your profile and replies to your messages."))
                .fontSize(16).fontColor(0x8E8E93).width(100.percent)
                .padding(left: 20, right: 20, top: 10)
            Button(trSource("About Telegram Premium"))
                .width(100.percent).height(52).borderRadius(26)
                .backgroundColor(0x0A84FF).fontColor(0xFFFFFF).fontSize(17).fontWeight(FontWeight.Medium)
                .margin(left: 20, right: 20, top: 20, bottom: 18)
                .onClick({ _ => this.openNameColorPremiumIntroSheet() })
        }.width(100.percent).backgroundColor(0xFFFFFF)
    }

    @Builder
    func buildNameColorPremiumIntroSheet() {
        Column {
            Row {
                Blank().layoutWeight(1)
                Text("X").fontSize(20).fontColor(0x8E8E93).width(36).height(36)
                    .textAlign(TextAlign.Center)
                    .onClick({ _ => this.showNameColorPremiumIntroSheet = false })
            }.width(100.percent).padding(left: 16, right: 12, top: 8)
            Text(trSource("ABOUT TELEGRAM PREMIUM"))
                .fontSize(13).fontWeight(FontWeight.Medium).fontColor(0x8E8E93)
                .width(100.percent).padding(left: 20, right: 20, top: 4)
            Text(trSource("Telegram Premium"))
                .fontSize(22).fontWeight(FontWeight.Bold).fontColor(0x000000)
                .width(100.percent).padding(left: 20, right: 20, top: 8)
            Text("Telegram Premium is a paid option that unlocks extra features, including custom name and profile colors. Contributions from Premium users help Telegram stay free for everyone.")
                .fontSize(15).fontColor(0x8E8E93).width(100.percent)
                .padding(left: 20, right: 20, top: 8)
            Column {
                Text(trSource("Annual")).fontSize(17).fontColor(0x000000).width(100.percent)
                    .padding(left: 16, right: 16, top: 14, bottom: 14)
                Divider().color(0xE5E5EA).strokeWidth(1)
                Text(trSource("Monthly")).fontSize(17).fontColor(0x000000).width(100.percent)
                    .padding(left: 16, right: 16, top: 14, bottom: 14)
            }.width(100.percent).backgroundColor(0xF2F2F7).borderRadius(12)
                .margin(left: 16, right: 16, top: 16, bottom: 20)
        }.width(100.percent).backgroundColor(0xFFFFFF)
    }

    @Builder
    func buildUnsavedChangesOverlay() {
        Stack(alignContent: Alignment.Center) {
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x33000000)
                .onClick({ _ => this.showUnsavedChangesAlert = false })
            Column {
                Text(trSource("Unsaved Changes"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .padding(top: 22, left: 30, right: 30)
                Text(trSource("You have changed the channel appearance settings. Apply changes?"))
                    .fontSize(15)
                    .fontColor(0x000000)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .padding(top: 8, left: 30, right: 30)
                Row {
                    Button(trSource("Discard"))
                        .layoutWeight(1)
                        .height(48)
                        .borderRadius(24)
                        .backgroundColor(0x1A000000)
                        .fontColor(0x000000)
                        .fontSize(17)
                        .onClick({ _ =>
                            this.showUnsavedChangesAlert = false
                            routerPop()
                        })
                    Button(trSource("Apply"))
                        .layoutWeight(1)
                        .height(48)
                        .borderRadius(24)
                        .backgroundColor(0x007AFF)
                        .fontColor(0xFFFFFF)
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .margin(left: 8)
                        .onClick({ _ =>
                            this.showUnsavedChangesAlert = false
                            this.applyStyle()
                        })
                }
                .width(100.percent)
                .height(48)
                .padding(left: 16, right: 16)
                .margin(top: 16, bottom: 21)
            }
            .width(300)
            .backgroundColor(0xFFFFFF)
            .borderRadius(35)
            .onClick({ _ => () })
        }
        .width(100.percent)
        .height(100.percent)
        .zIndex(20)
    }

    @Builder
    func buildNameColorPremiumPaywallToast() {
        Row {
            Image(@r(app.media.set2_ic_premiumstar))
                .width(20)
                .height(20)
                .fillColor(0xFFFFFF)
                .objectFit(ImageFit.Contain)
                .margin(right: 8)
            Text("Subscribe to Telegram Premium to choose a custom color for your name.")
                .fontSize(14)
                .fontColor(0xFFFFFF)
                .maxLines(2)
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
            Button(trSource("Telegram Premium"))
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x3E88F7)
                .backgroundColor(0xF0202020)
                .margin(left: 8)
                .onClick({ _ =>
                    this.openNameColorPremiumDemoSheet()
                    this.dismissNameColorPremiumPaywallToast()
                })
        }
        .width(92.percent)
        .alignItems(VerticalAlign.Center)
        .padding(left: 16, right: 16, top: 12, bottom: 12)
        .borderRadius(12)
        .backgroundColor(0xF0202020)
        .zIndex(10)
        .margin(bottom: 24)
        .onClick({ _ =>
            this.openNameColorPremiumDemoSheet()
            this.dismissNameColorPremiumPaywallToast()
        })
    }

    @Builder
    func buildNameColorPremiumPaywallOverlay() {
        Column {
            Column {}
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(0x33000000)
                .onClick({ _ => () })
            this.buildNameColorPremiumPaywallToast()
        }
        .width(100.percent)
        .height(100.percent)
        .zIndex(20)
    }

    private func applyStyle(): Unit {
        if (this.saving) { return }
        let isPremium = match (getAuthStorage().getUserData()) {
            case Some(user) => user.isPremium
            case None => false
        }
        if (!isPremium) {
            this.showNameColorPremiumPaywallToast = true
            this.startNameColorPremiumPaywallTimer()
            return
        }
        this.saving = true
        let section = this.selectedSection
        let index = this.selectedColor()
        let service = getThemesEngineService()
        var collectibleId: Int64 = 0
        if (this.selectedGiftId == 0 && this.selectedGift >= 0 && Int64(this.selectedGift) < this.giftColorIds.size) {
            collectibleId = this.giftColorIds[Int64(this.selectedGift)]
        }
        let capturedCollectibleId = collectibleId
        let _ = spawn {
            let ok = if (capturedCollectibleId != 0) {
                service.applyCollectibleNameColorToServer(capturedCollectibleId)
            } else {
                service.applyProfileColorToServer(section == 0, index)
            }
            launch {
                this.saving = false
                if (ok) {
                    if (section == 0) {
                        service.saveProfileHeaderColorIndex(index)
                        this.persistedProfileColor = index
                    } else {
                        service.saveProfileNameColorIndex(index)
                        this.persistedNameColor = index
                    }
                } else {
                    if (section == 0) {
                        this.profileColor = this.persistedProfileColor
                    } else {
                        this.nameColor = this.persistedNameColor
                    }
                }
                Hilog.info(0, "CjTelegram", "[ProfileColorPage] saved section=${section} color=${index} collectible=${capturedCollectibleId} result=${ok}")
            }
        }
    }

    public func build() {
        Stack {
        Stack(alignContent: Alignment.Bottom) {
        Column {
            Row {
                Text("‹").fontSize(36).fontColor(0x000000).width(52).height(52)
                    .borderRadius(26).backgroundColor(0xFFFFFF).textAlign(TextAlign.Center)
                    .onClick({ _ => this.attemptLeave() })
                Row {
                    Text(trSource("Profile"))
                        .fontSize(16).fontWeight(FontWeight.Medium).fontColor(0x000000)
                        .width(80).height(40).textAlign(TextAlign.Center)
                        .backgroundColor(if (this.selectedSection == 0) { 0xE4E4E8 } else { 0xFFFFFF })
                        .onClick({ _ => this.selectedSection = 0 })
                    Text(trSource("Name"))
                        .fontSize(16).fontWeight(FontWeight.Medium).fontColor(0x000000)
                        .width(80).height(40).textAlign(TextAlign.Center)
                        .backgroundColor(if (this.selectedSection == 1) { 0xE4E4E8 } else { 0xFFFFFF })
                        .onClick({ _ => this.selectedSection = 1 })
                }.borderRadius(20).clip(true).backgroundColor(0xFFFFFF)
                Blank().width(52)
            }
            .width(100.percent).height(64.0 + getSafeAreaTop()).padding(left: 12, right: 12, top: getSafeAreaTop())
            .alignItems(VerticalAlign.Center).justifyContent(FlexAlign.SpaceBetween)
            .backgroundColor(0xF2F2F7)

            Stack(alignContent: Alignment.Bottom) {
            Scroll {
                Column {
                    Column {
                    Column {
                        if (this.selectedSection == 0) {
                            Column {
                                Text(this.avatarLetter).fontSize(44).fontWeight(FontWeight.Bold).fontColor(0xFFFFFF)
                            }.width(104).height(104).borderRadius(52)
                                .linearGradient(angle: 180.0, colors: [
                                    (Color(this.colorHex(this.selectedColor())), 0.0),
                                    (Color(this.colorHex(this.selectedColor())), 1.0)
                                ])
                                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                            Text(this.displayName).fontSize(27).fontWeight(FontWeight.Bold).margin(top: 10)
                            Text(trSource("online")).fontSize(20).fontColor(0x9A9A9F).margin(top: 3)
                        } else {
                            Stack(alignContent: Alignment.BottomStart) {
                            Row {
                                Column {
                                Text(this.displayName).fontSize(16).fontColor(this.colorHex(this.selectedColor())).width(100.percent)
                                Column {
                                    Text(this.displayName).fontSize(15).fontWeight(FontWeight.Medium)
                                        .fontColor(this.colorHex(this.selectedColor())).width(100.percent)
                                    Text(trSource("Reply to your message")).fontSize(15).width(100.percent)
                                }.padding(8).backgroundColor(0xEEF7EA).borderRadius(6).margin(top: 4)
                                Text(trSource("Your name and replies to your messages will be shown in the selected color."))
                                    .fontSize(17).margin(top: 8)
                                Column {
                                    Text(trSource("Telegram")).fontSize(15).fontWeight(FontWeight.Medium)
                                        .fontColor(this.colorHex(this.selectedColor())).width(100.percent)
                                    Text(trSource("Link Preview")).fontSize(15).fontWeight(FontWeight.Bold).width(100.percent)
                                    Text("Previews of links you send will also use this color.").fontSize(15).width(100.percent)
                                }.padding(8).backgroundColor(0xEEF7EA).borderRadius(6).margin(top: 8)
                                }.width(78.percent).padding(12).backgroundColor(0xFFFFFF).borderRadius(18)
                            }.width(100.percent).justifyContent(FlexAlign.Center)
                            Row {
                                Text(this.avatarLetter).fontSize(18).fontWeight(FontWeight.Bold).fontColor(0xFFFFFF)
                            }.width(40).height(40).borderRadius(20).backgroundColor(this.colorHex(this.selectedColor()))
                                .justifyContent(FlexAlign.Center).margin(left: 8, bottom: 8)
                            }.width(100.percent).height(100.percent)
                        }
                    }.width(100.percent).height(235)
                        .padding(top: 30).alignItems(HorizontalAlign.Center)
                        .backgroundColor(if (this.selectedSection == 0) { 0xFFFFFF } else { 0xA8D693 })

                    Column {
                        Row {
                            ForEach(Array<Int64>(8, { i: Int64 => i }), itemGenerator: { index: Int64, _i: Int64 =>
                                Stack(alignContent: Alignment.Center) {
                                    Column { }.width(34).height(34).borderRadius(17)
                                        .backgroundColor(this.colorHex(Int32(index)))
                                    if (this.selectedColor() == Int32(index)) {
                                        Column { }.width(25).height(25).borderRadius(13)
                                            .border(width: 2, color: 0xFFFFFF)
                                    }
                                }.width(42).height(42).onClick({ _ => this.saveColor(Int32(index)) })
                            })
                        }.width(100.percent).justifyContent(FlexAlign.SpaceAround)
                        Row {
                            ForEach(Array<Int64>(8, { i: Int64 => i }), itemGenerator: { index: Int64, _i: Int64 =>
                                Stack {
                                    Column { }.width(34).height(34).borderRadius(17)
                                        .backgroundColor(this.colorHex(Int32(index)))
                                    Column { }.width(34).height(17)
                                        .backgroundColor(0x66FFFFFF).rotate(angle: Float32(-45.0))
                                }.width(34).height(34).borderRadius(17).clip(true).margin(left: 4, right: 4)
                                    .onClick({ _ => this.saveColor(Int32(index)) })
                            })
                        }.width(100.percent).justifyContent(FlexAlign.SpaceAround).margin(top: 4)
                        if (this.selectedSection == 1) {
                            Row {
                                ForEach(Array<Int64>(8, { i: Int64 => i }), itemGenerator: { index: Int64, _i: Int64 =>
                                    Stack(alignContent: Alignment.Center) {
                                        Column { }.width(34).height(34).borderRadius(17)
                                            .backgroundColor(this.colorHex(Int32(index)))
                                        Column { }.width(14).height(14).rotate(angle: Float32(45.0)).backgroundColor(0xFFFFFF)
                                    }.width(42).height(42).onClick({ _ => this.saveColor(Int32(index)) })
                                })
                            }.width(100.percent).justifyContent(FlexAlign.SpaceAround).margin(top: 4)
                        }
                        Row {
                            Text(if (this.selectedSection == 0) { "Add Icons To Profile" } else { "Add Icons To Replies" })
                                .fontSize(18).layoutWeight(1)
                            Text("›").fontSize(30).fontColor(0xB8B8BD)
                        }.height(56).padding(left: 16, right: 16).margin(top: 8)
                    }.width(100.percent).backgroundColor(0xFFFFFF)
                    }.width(94.percent).backgroundColor(0xFFFFFF).borderRadius(18).clip(true)
                        .margin(top: 10)

                    Text(if (this.selectedSection == 0) {
                        "You can change the color of your name and customize replies to you. Change ›"
                    } else {
                        "This color will be used for your name, the links you send, and replies to your messages."
                    }).fontSize(14).fontColor(0x77777C).padding(left: 16, right: 16, top: 10)
                        .width(100.percent)

                    Text(trSource("USE A GIFT")).fontSize(14).fontColor(0x77777C)
                        .width(100.percent).padding(left: 16, top: 24, bottom: 8)
                    Column {
                        Scroll {
                            Row {
                                ForEach(this.giftTabTitles, itemGenerator: { tabTitle: String, index: Int64 =>
                                    Text(tabTitle).fontSize(16)
                                        .fontColor(if (this.giftTabIdAt(index) == this.selectedGiftId) { 0xFFFFFF } else { 0x000000 })
                                        .padding(left: 12, right: 12, top: 7, bottom: 7)
                                        .margin(left: if (index == 0) { 0 } else { 10 })
                                        .backgroundColor(if (this.giftTabIdAt(index) == this.selectedGiftId) { 0x0A84FF } else { 0xEFEFF1 })
                                        .borderRadius(18)
                                        .onClick({ _ => this.selectGiftTab(this.giftTabIdAt(index)) })
                                })
                            }.padding(left: 16, right: 16)
                        }.width(100.percent).height(40).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
                        if (this.giftLoading) {
                            LoadingProgress().width(28).height(28).color(0x0A84FF).margin(top: 28, bottom: 28)
                        } else if (!this.giftNames.isEmpty()) {
                            Scroll {
                                Row {
                                    ForEach(this.giftNames, itemGenerator: { giftName: String, index: Int64 =>
                                        Column {
                                            Image(@r(app.media.profile_gift_preview)).width(72).height(64)
                                            Text(giftName).fontSize(12).maxLines(1).textOverflow(TextOverflow.Ellipsis)
                                                .width(92).textAlign(TextAlign.Center).margin(top: 4)
                                        }.width(100).height(96).borderRadius(12)
                                            .backgroundColor(if (this.selectedGift == Int32(index)) { 0xE5F2FF } else { 0xF2F2F7 })
                                            .border(width: if (this.selectedGift == Int32(index)) { 2 } else { 0 }, color: 0x0A84FF)
                                            .margin(left: 8, right: 4, top: 12)
                                            .onClick({ _ =>
                                                if (this.selectedGiftId == 0 && Int64(index) < this.giftColorIds.size && this.giftColorIds[index] != 0) {
                                                    this.selectedGift = Int32(index)
                                                    this.selectedSection = 1
                                                    this.giftMessage = "Style selected. Apply to save it."
                                                } else {
                                                    this.selectedGift = -1
                                                    this.giftMessage = "Add this gift to My Gifts before applying its style."
                                                }
                                            })
                                    })
                                }
                            }.width(100.percent).height(112).scrollable(ScrollDirection.Horizontal)
                        } else if (this.selectedGiftId == 0) {
                            if (this.styleAnimReady) {
                                Image(this.currentStyleAnimFrame())
                                    .id("profileColorStyleAnim_${this.styleAnimFrameIndex}")
                                    .width(100).height(100).objectFit(ImageFit.Contain).margin(top: 12)
                            }
                            Text(if (this.giftMessage.size > 0) { this.giftMessage } else { this.emptyGiftsPlaceholder() })
                                .fontSize(14).fontColor(0x8E8E93).textAlign(TextAlign.Center)
                                .margin(left: 28, right: 28, top: 4)
                            Text(trSource("Browse gifts available for purchase >")).fontSize(16).fontColor(0x0A84FF).margin(top: 10)
                                .onClick({ _ => this.browseGiftsForPurchase() })
                        }
                        if (this.giftMessage.size > 0 && !this.giftNames.isEmpty()) {
                            Text(this.giftMessage).fontSize(13).fontColor(0x8E8E93).margin(top: 6)
                        }
                    }.width(94.percent).backgroundColor(0xFFFFFF).borderRadius(18)
                        .margin(bottom: 18)
                    if (this.saving) {
                        Row {
                            LoadingProgress().width(18).height(18).color(0x317AFF)
                            Text("Saving...").fontSize(14).fontColor(0x8E8E93).margin(left: 8)
                        }.margin(top: 16)
                    }
                    Column { }.width(100.percent).height(60)
                }.width(100.percent)
            }.width(100.percent).height(100.percent).backgroundColor(0xF2F2F7)
            Button(if (this.saving) { "Applying..." } else { "Apply Style" })
                .width(100.percent).height(52).borderRadius(26)
                .backgroundColor(0x0A84FF).fontColor(0xFFFFFF).fontSize(18).fontWeight(FontWeight.Medium)
                .margin(left: 36, right: 36, bottom: 8)
                .enabled(!this.saving).onClick({ _ => this.applyStyle() })
            }.layoutWeight(1).width(100.percent)
        }
        .width(100.percent).height(100.percent).backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
        if (this.showUnsavedChangesAlert) {
            this.buildUnsavedChangesOverlay()
        }
        if (this.showNameColorPremiumPaywallToast) {
            this.buildNameColorPremiumPaywallOverlay()
        }
        }
        .width(100.percent).height(100.percent)
        .bindSheet(this.showNameColorPremiumDemoSheet, this.buildNameColorPremiumDemoSheet, options: SheetOptions(
            onDisappear: { => launch { this.showNameColorPremiumDemoSheet = false } },
            height: SheetSize.FitContent,
            preferType: SheetType.Bottom,
            showClose: false,
            dragBar: false
        ))
        }
        .width(100.percent).height(100.percent)
        .bindSheet(this.showNameColorPremiumIntroSheet, this.buildNameColorPremiumIntroSheet, options: SheetOptions(
            onDisappear: { => launch { this.showNameColorPremiumIntroSheet = false } },
            height: SheetSize.FitContent,
            preferType: SheetType.Bottom,
            showClose: false,
            dragBar: false
        ))
    }
}
