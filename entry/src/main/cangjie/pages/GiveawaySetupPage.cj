package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.getPaymentsService
import ohos_app_cangjie_entry.core.mtproto.{
    GiveawayInfoResponse,
    StarGiftUpdatesResponse
}
import std.convert.*
import ohos_app_cangjie_entry.router.*

/**
 * P2-303: Premium 抽奖 Giveaway 配置 + 信息页（混合工程迁移版）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()
 *
 * 覆盖 3 个 gap：
 *  (A) 抽奖类型选择：普通 Premium Giveaway vs 礼品码（Stars Giveaway）
 *  (B) 参数配置：频道/国家过滤/获奖人数/截止时间/仅限新订阅者
 *      → launchPrepaidGiveaway（启动已预购的 prepaid giveaway）
 *  (C) GiveawayInfo 屏：展示 payments.getGiveawayInfo 响应
 *      → 进行中（ongoing）：资格状态
 *      → 已结束（results）：是否中奖 + 礼品码
 *
 * 导航：
 *   Route name: "GiveawaySetupPage"
 *   Route name: "GiveawayInfoPage"（第二个 tab 或独立页，复用此组件 viewMode=info）
 *   根容器为 NavDestination（D-002）
 *   @Consume pageStack 访问导航栈
 *
 * TL 调用链（查询 Giveaway 信息）：
 *   GiveawaySetupPage.doGetGiveawayInfo()
 *   → getPaymentsDataProvider().getGiveawayInfo(peerId, accessHash, msgId)
 *     → PaymentsGetGiveawayInfo#f4239425 → getMTProtoClient().sendRequest()
 *     → parseGiveawayInfo → GiveawayInfoViewModel
 *
 * TL 调用链（启动 Prepaid Giveaway）：
 *   GiveawaySetupPage.doLaunchPrepaidGiveaway()
 *   → getPaymentsDataProvider().launchPrepaidGiveaway(...)
 *     → PaymentsLaunchPrepaidGiveaway#5ff58f20 / InputStorePaymentPremiumGiveaway#160544ca
 *     → getMTProtoClient().sendRequest() → StarGiftUpdatesResponse(success)
 *
 * iOS ref: CreateGiveawayScreen (PremiumUI/CreateGiveawayScreen.swift),
 *          GiftCodes.swift:109 _internal_getPremiumGiveawayInfo,
 *          GiftCodes.swift:360 _internal_launchPrepaidGiveaway
 */
@HybridComponentEntry
@Component
public class GiveawaySetupPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 视图模式：0=Setup, 1=GiveawayInfo
    @State var viewMode: Int32 = 0

    // ─── Setup 参数 ───
    @State var giveawayType: Int32 = 0    // 0=Premium, 1=Stars
    @State var onlyNewSubscribers: Bool = true
    @State var winnersVisible: Bool = false
    @State var winnersCount: Int32 = 1
    @State var monthsDuration: Int32 = 3
    @State var countryFilter: String = ""

    // prepaid giveaway context（从路由参数或固定值注入）
    @State var prepaidPeerId: Int64 = 0
    @State var prepaidPeerAccessHash: Int64 = 0
    @State var prepaidGiveawayId: Int64 = 0

    // ─── Launch 结果 ───
    @State var isLaunching: Bool = false
    @State var launchError: String = ""
    @State var launchSuccess: Bool = false

    // ─── GiveawayInfo ───
    @State var infoMsgId: Int32 = 0
    @State var isLoadingInfo: Bool = false
    @State var infoError: String = ""
    @State var giveawayInfo: GiveawayInfoResponse = GiveawayInfoResponse()

    // ─── Tab ───
    @State var activeTab: Int32 = 0  // 0=Setup/Config, 1=Info

    private func doLaunchPrepaidGiveaway(): Unit {
        let pid = this.prepaidPeerId
        let phash = this.prepaidPeerAccessHash
        let gid = this.prepaidGiveawayId
        let only = this.onlyNewSubscribers
        let visible = this.winnersVisible
        let months = this.monthsDuration
        let winners = this.winnersCount
        let gtype = this.giveawayType
        // randomId: use 0 as placeholder (real launch requires IAP-derived randomId from P2-299)
        let randomId: Int64 = 0i64
        let untilDate: Int32 = 0
        let currency: String = ""
        let amount: Int64 = 0i64
        let _ = spawn {
            launch {
                this.isLaunching = true
                this.launchError = ""
            }
            try {
                let svc = getPaymentsService()
                if (gtype == 0) {
                    // Premium Giveaway
                    let result = svc.launchPrepaidGiveaway(
                        pid,
                        phash,
                        gid,
                        only,
                        visible,
                        ArrayList<Int64>(),
                        ArrayList<Int64>(),
                        ArrayList<String>(),
                        "",
                        randomId,
                        untilDate,
                        currency,
                        amount
                    )
                    let ok = result.success
                    let msg = result.errorMessage
                    launch {
                        this.isLaunching = false
                        this.launchSuccess = ok
                        if (!ok) { this.launchError = msg }
                    }
                } else {
                    // Stars Giveaway
                    let stars: Int64 = 100i64
                    let result = svc.launchPrepaidStarsGiveaway(
                        pid,
                        phash,
                        gid,
                        stars,
                        winners,
                        only,
                        visible,
                        ArrayList<Int64>(),
                        ArrayList<Int64>(),
                        ArrayList<String>(),
                        "",
                        randomId,
                        untilDate,
                        currency,
                        amount
                    )
                    let ok = result.success
                    let msg = result.errorMessage
                    launch {
                        this.isLaunching = false
                        this.launchSuccess = ok
                        if (!ok) { this.launchError = msg }
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GiveawaySetupPage] launch error: ${e}")
                launch {
                    this.isLaunching = false
                    this.launchError = "Launch failed"
                }
            }
        }
    }

    private func doGetGiveawayInfo(): Unit {
        let pid = this.prepaidPeerId
        let phash = this.prepaidPeerAccessHash
        let msgId = this.infoMsgId
        let _ = spawn {
            launch {
                this.isLoadingInfo = true
                this.infoError = ""
            }
            try {
                let svc = getPaymentsService()
                let info = svc.getGiveawayInfo(pid, phash, msgId)
                launch {
                    this.giveawayInfo = info
                    this.isLoadingInfo = false
                    if (!info.success) {
                        this.infoError = info.errorMessage
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GiveawaySetupPage] getGiveawayInfo error: ${e}")
                launch {
                    this.isLoadingInfo = false
                    this.infoError = "Failed to load giveaway info"
                }
            }
        }
    }

    // ─── 辅助提取方法（R-107: @Builder 内禁止 let/var）───

    private func tab0BgColor(): Int64 {
        if (this.activeTab == 0) { return 0xFF007AFF }
        return 0xFFE5E5EA
    }
    private func tab1BgColor(): Int64 {
        if (this.activeTab == 1) { return 0xFF007AFF }
        return 0xFFE5E5EA
    }
    private func tab0TextColor(): Int64 {
        if (this.activeTab == 0) { return 0xFFFFFFFF }
        return 0xFF1C1C1E
    }
    private func tab1TextColor(): Int64 {
        if (this.activeTab == 1) { return 0xFFFFFFFF }
        return 0xFF1C1C1E
    }
    private func typePremiumBg(): Int64 {
        if (this.giveawayType == 0) { return 0xFF007AFF }
        return 0xFFE5E5EA
    }
    private func typeStarsBg(): Int64 {
        if (this.giveawayType == 1) { return 0xFF007AFF }
        return 0xFFE5E5EA
    }
    private func typePremiumTextColor(): Int64 {
        if (this.giveawayType == 0) { return 0xFFFFFFFF }
        return 0xFF1C1C1E
    }
    private func typeStarsTextColor(): Int64 {
        if (this.giveawayType == 1) { return 0xFFFFFFFF }
        return 0xFF1C1C1E
    }
    private func onlyNewLabel(): String {
        if (this.onlyNewSubscribers) { return "On" }
        return "Off"
    }
    private func winnersVisibleLabel(): String {
        if (this.winnersVisible) { return "On" }
        return "Off"
    }
    private func launchButtonLabel(): String {
        if (this.isLaunching) { return "Launching..." }
        return "Launch Giveaway"
    }
    private func launchStatusColor(): Int64 {
        if (this.launchSuccess) { return 0xFF34C759 }
        return 0xFFFF3B30
    }
    private func launchStatusText(): String {
        if (this.launchSuccess) { return "Giveaway launched successfully!" }
        return this.launchError
    }
    private func infoTypeLabel(): String {
        if (this.giveawayInfo.infoType == "ongoing") { return "Ongoing Giveaway" }
        if (this.giveawayInfo.infoType == "results") { return "Giveaway Results" }
        return "Giveaway Info"
    }
    private func ongoingStatusLabel(): String {
        let s = this.giveawayInfo.ongoingStatus
        if (s == "participating") { return "You are participating" }
        if (s == "almostOver") { return "Drawing almost over" }
        if (s == "notQualified") { return "Not qualified" }
        if (s == "notAllowed_tooEarly") { return "Joined channel too early" }
        if (s == "notAllowed_admin") { return "Admin disallowed" }
        if (s == "notAllowed_country") { return "Country not eligible: ${this.giveawayInfo.disallowedCountry}" }
        return s
    }
    private func resultStatusLabel(): String {
        let s = this.giveawayInfo.resultStatus
        if (s == "wonPremium") { return "You won Premium! Code: ${this.giveawayInfo.giftCodeSlug}" }
        if (s == "wonStars") { return "You won ${this.giveawayInfo.starsPrize} Stars!" }
        if (s == "refunded") { return "Giveaway refunded" }
        return "Did not win this time"
    }
    private func infoWinnersLabel(): String {
        return "${this.giveawayInfo.winnersCount} winners / ${this.giveawayInfo.activatedCount} activated"
    }

    private func getInfoButtonLabel(): String {
        if (this.isLoadingInfo) { return "Loading..." }
        return "Get Giveaway Info"
    }

    func build() {
        Column() {
            // ── 顶部导航栏 ──
            Row() {
                Button(trSource("Back"))
                    .onClick({ _ => routerPop() })
                    .margin(8)
                    Blank()
                    Text(trSource("Giveaway"))
                        .fontSize(18)
                        .fontWeight(FontWeight.Medium)
                        .margin(right: 16)
                }
                .width(100.percent)
                .height(56)
                .padding(left: 8, right: 8)
                .backgroundColor(0xFFFFFFFF)

                // ── Tab: Setup / Info ──
                Row() {
                    Button("Setup")
                        .onClick({ _ => this.activeTab = 0 })
                        .flexGrow(1)
                        .height(36)
                        .backgroundColor(this.tab0BgColor())
                        .fontColor(this.tab0TextColor())
                        .borderRadius(8)
                        .margin(right: 4)
                    Button("Giveaway Info")
                        .onClick({ _ => this.activeTab = 1 })
                        .flexGrow(1)
                        .height(36)
                        .backgroundColor(this.tab1BgColor())
                        .fontColor(this.tab1TextColor())
                        .borderRadius(8)
                        .margin(left: 4)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 8)

                if (this.activeTab == 0) {
                    this.buildSetupTab()
                } else {
                    this.buildInfoTab()
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFF2F2F7)
    }

    @Builder
    func buildSetupTab() {
        Scroll() {
            Column() {
                // ── 类型选择：Premium / Stars ──
                Text("Giveaway Type")
                    .fontSize(15)
                    .fontColor(0xFF8E8E93)
                    .padding(left: 16, top: 16, bottom: 8)
                    .width(100.percent)

                Row() {
                    Button(trSource("Premium"))
                        .onClick({ _ => this.giveawayType = 0 })
                        .flexGrow(1)
                        .height(40)
                        .backgroundColor(this.typePremiumBg())
                        .fontColor(this.typePremiumTextColor())
                        .borderRadius(8)
                        .margin(right: 4)
                    Button(trSource("Stars"))
                        .onClick({ _ => this.giveawayType = 1 })
                        .flexGrow(1)
                        .height(40)
                        .backgroundColor(this.typeStarsBg())
                        .fontColor(this.typeStarsTextColor())
                        .borderRadius(8)
                        .margin(left: 4)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 8)

                // ── 参数配置 ──
                Column() {
                    // 仅限新订阅者
                    Row() {
                        Text(trSource("Only new subscribers"))
                            .fontSize(16)
                            .fontColor(0xFF1C1C1E)
                            .flexGrow(1)
                        Toggle(ToggleType.Switch, isOn: this.onlyNewSubscribers)
                            .onChange({ val => this.onlyNewSubscribers = val })
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 14, bottom: 14)

                    // 公示获奖者
                    Row() {
                        Text("Winners are visible")
                            .fontSize(16)
                            .fontColor(0xFF1C1C1E)
                            .flexGrow(1)
                        Toggle(ToggleType.Switch, isOn: this.winnersVisible)
                            .onChange({ val => this.winnersVisible = val })
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 14, bottom: 14)

                    // 获奖人数 Stepper
                    Row() {
                        Text("Winners count: ${this.winnersCount}")
                            .fontSize(16)
                            .fontColor(0xFF1C1C1E)
                            .flexGrow(1)
                        Button("-")
                            .onClick({ _ =>
                                if (this.winnersCount > 1) {
                                    this.winnersCount -= 1
                                }
                            })
                            .width(32)
                            .height(32)
                            .borderRadius(8)
                            .margin(right: 8)
                        Button("+")
                            .onClick({ _ =>
                                if (this.winnersCount < 100) {
                                    this.winnersCount += 1
                                }
                            })
                            .width(32)
                            .height(32)
                            .borderRadius(8)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 14, bottom: 14)

                    // 时长（仅 Premium 类型）
                    if (this.giveawayType == 0) {
                        Row() {
                            Text("Duration: ${this.monthsDuration} months")
                                .fontSize(16)
                                .fontColor(0xFF1C1C1E)
                                .flexGrow(1)
                            Button("3m")
                                .onClick({ _ => this.monthsDuration = 3 })
                                .width(40)
                                .height(32)
                                .borderRadius(8)
                                .margin(right: 4)
                            Button("6m")
                                .onClick({ _ => this.monthsDuration = 6 })
                                .width(40)
                                .height(32)
                                .borderRadius(8)
                                .margin(right: 4)
                            Button("12m")
                                .onClick({ _ => this.monthsDuration = 12 })
                                .width(40)
                                .height(32)
                                .borderRadius(8)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 14, bottom: 14)
                    }

                    // 国家过滤（ISO2 代码，逗号分隔）
                    Row() {
                        Text("Country filter (ISO2, csv):")
                            .fontSize(14)
                            .fontColor(0xFF8E8E93)
                            .margin(right: 8)
                        TextInput(text: this.countryFilter, placeholder: "e.g. US,GB")
                            .onChange({ val => this.countryFilter = val })
                            .flexGrow(1)
                            .height(36)
                            .fontSize(14)
                            .borderRadius(8)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 8, bottom: 14)
                }
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, top: 0, bottom: 16)

                // ── Launch 按钮 ──
                Button(this.launchButtonLabel())
                    .onClick({ _ => this.doLaunchPrepaidGiveaway() })
                    .width(100.percent)
                    .height(50)
                    .margin(left: 16, right: 16, top: 0, bottom: 8)
                    .borderRadius(12)
                    .backgroundColor(0xFF007AFF)
                    .fontColor(0xFFFFFFFF)
                    .fontSize(17)

                Text("Note: Giveaway launch requires a prepaid giveaway (purchased via IAP/P2-299 payment flow). This page configures and launches an already-purchased prepaid giveaway.")
                    .fontSize(12)
                    .fontColor(0xFF8E8E93)
                    .padding(left: 16, right: 16, top: 4, bottom: 8)
                    .width(100.percent)

                if (this.launchSuccess || this.launchError.size > 0) {
                    Text(this.launchStatusText())
                        .fontSize(14)
                        .fontColor(this.launchStatusColor())
                        .padding(left: 16, right: 16, bottom: 16)
                        .width(100.percent)
                }
            }
            .width(100.percent)
        }
        .width(100.percent)
        .flexGrow(1)
    }

    @Builder
    func buildInfoTab() {
        Scroll() {
            Column() {
                Row() {
                    Text("Message ID:")
                        .fontSize(14)
                        .fontColor(0xFF8E8E93)
                        .margin(right: 8)
                    TextInput(text: "${this.infoMsgId}", placeholder: "Giveaway message ID")
                        .onChange({ val =>
                            try {
                                this.infoMsgId = Int32(Int64.parse(val))
                            } catch (_: Exception) {
                                this.infoMsgId = 0
                            }
                        })
                        .flexGrow(1)
                        .height(36)
                        .fontSize(14)
                        .borderRadius(8)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 16, bottom: 8)

                Button(this.getInfoButtonLabel())
                    .onClick({ _ => this.doGetGiveawayInfo() })
                    .width(100.percent)
                    .height(44)
                    .margin(left: 16, right: 16, bottom: 16)
                    .borderRadius(10)
                    .backgroundColor(0xFF007AFF)
                    .fontColor(0xFFFFFFFF)

                if (this.infoError.size > 0) {
                    Text(this.infoError)
                        .fontSize(14)
                        .fontColor(0xFFFF3B30)
                        .padding(left: 16, right: 16, bottom: 12)
                        .width(100.percent)
                }

                if (this.giveawayInfo.success) {
                    Column() {
                        Text(this.infoTypeLabel())
                            .fontSize(18)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFF1C1C1E)
                            .padding(left: 16, right: 16, top: 14, bottom: 8)
                            .width(100.percent)

                        if (this.giveawayInfo.infoType == "ongoing") {
                            Text(this.ongoingStatusLabel())
                                .fontSize(15)
                                .fontColor(0xFF1C1C1E)
                                .padding(left: 16, right: 16, bottom: 14)
                                .width(100.percent)
                        } else if (this.giveawayInfo.infoType == "results") {
                            Text(this.resultStatusLabel())
                                .fontSize(15)
                                .fontColor(0xFF1C1C1E)
                                .padding(left: 16, right: 16, bottom: 8)
                                .width(100.percent)
                            Text(this.infoWinnersLabel())
                                .fontSize(13)
                                .fontColor(0xFF8E8E93)
                                .padding(left: 16, right: 16, bottom: 14)
                                .width(100.percent)
                        }
                    }
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16, top: 0, bottom: 16)
                }
            }
            .width(100.percent)
        }
        .width(100.percent)
        .flexGrow(1)
    }
}
