package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getRevenueStatsService,
    getRealAuthService,
    getGraphService,
    getSelectedChatId,
    getSelectedChatPeerType,
    TonRevenueStats,
    TonRevenueBalances,
    TonWithdrawalResult,
    TonWithdrawalErrorKind,
    ChartType,
    GraphStats
}
import ohos_app_cangjie_entry.router.*

/**
 * TON 广告收入统计页面 (P2-368)
 *
 * 对应 iOS fidelity gaps:
 *   ① TON 收入余额卡 (current / available / overall TON + USD 换算)
 *   ② 广告收入图表 (Currency 类型，调 GraphService.getGroupStats)
 *   ③ 提现按钮 + 流程 (2FA/SRP 密码验证 + cooldown 时间锁)
 *   ④ Buy Ads 入口屏 (广告主入口 / 收益说明)
 *
 * 调用链:
 *   aboutToAppear()
 *     → spawn { getRevenueStatsService().getTonRevenueStats(peerType, peerId) }
 *       → PaymentsGetStarsRevenueStats(ton=true) [0xd91ffad6 flags|=2]
 *       → parseStarsRevenueStats(responseData)
 *       → TonRevenueStats {balances, usdRate}
 *     → spawn { getGraphService().getGroupStats(peerType, peerId, chartType: Currency) }
 *       → GraphStats (Currency chart data)
 *
 *   onWithdrawTap()
 *     → showPasswordDialog()  [SRP 密码输入]
 *     → spawn { getRevenueStatsService().requestWithdrawalUrl(peerType, peerId, srpId, A, M1, 0) }
 *       → PaymentsGetStarsRevenueWithdrawalUrl(ton=true) [0x2433dc92 flags bit 0]
 *       → TonWithdrawalResult {success, url}
 *     → launch { open withdrawalUrl in BrowserService / external }
 *
 *   onBuyAdsTap()
 *     → spawn { getRevenueStatsService().getAdsAccountUrl(peerType, peerId) }
 *       → PaymentsGetStarsRevenueAdsAccountUrl [0xd1d7efc5]
 *       → url: String
 *     → launch { open url in BrowserService }
 *
 * 导航: 根容器为 NavDestination (D-002)，@Consume pageStack
 * Route name: "ChannelRevenueStatsPage"
 * 前置条件: 当前频道 ID/PeerType 由 getSelectedChatId/getSelectedChatPeerType() 提供
 */
@HybridComponentEntry
@Component
public class ChannelRevenueStatsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoading: Bool = true
    @State var errorMsg: String = ""
    @State var loaded: Bool = false

    @State var revenueStats: TonRevenueStats = TonRevenueStats()
    @State var graphStats: GraphStats = GraphStats()
    @State var graphLoaded: Bool = false

    // 提现流程状态
    @State var showWithdrawDialog: Bool = false
    @State var withdrawPassword: String = ""
    @State var isWithdrawing: Bool = false
    @State var withdrawError: String = ""
    @State var withdrawUrl: String = ""

    // Buy Ads 流程状态
    @State var adsUrl: String = ""
    @State var isLoadingAds: Bool = false
    @State var showAdsIntro: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let _ = spawn {
            try {
                let peerType = getSelectedChatPeerType()
                let peerId = getSelectedChatId()
                Hilog.info(0, "CjTelegram", "[ChannelRevenueStatsPage] loading peerType=${peerType} peerId=${peerId}")

                let revSvc = getRevenueStatsService()
                let stats = revSvc.getTonRevenueStats(peerType, peerId)

                launch {
                    this.revenueStats = stats
                    this.isLoading = false
                    if (!stats.isLoaded) {
                        this.errorMsg = "Failed to load TON revenue data"
                    }
                }

                // 广告收入图表（Currency 类型）
                let graphSvc = getGraphService()
                let gStats = graphSvc.getGroupStats(peerType, peerId, chartType: ChartType.Currency)
                launch {
                    this.graphStats = gStats
                    this.graphLoaded = true
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChannelRevenueStatsPage] error: ${e}")
                launch {
                    this.errorMsg = "Error loading TON revenue stats"
                    this.isLoading = false
                }
            }
        }
    }

    // ── 辅助提取方法（R-107: @Builder 内禁止 let/var，提前计算）──

    private func currentBalanceTon(): String {
        let nano = this.revenueStats.balances.currentBalance
        if (nano == 0) { return "0 TON" }
        return "${nano} nTON"
    }

    private func availableBalanceTon(): String {
        let nano = this.revenueStats.balances.availableBalance
        if (nano == 0) { return "0 TON" }
        return "${nano} nTON"
    }

    private func overallRevenueTon(): String {
        let nano = this.revenueStats.balances.overallRevenue
        if (nano == 0) { return "0 TON" }
        return "${nano} nTON"
    }

    private func currentBalanceUsd(): String {
        let rate = this.revenueStats.usdRate
        let nano = this.revenueStats.balances.currentBalance
        if (rate <= 0.0 || nano == 0) { return "$0.00" }
        let usd = Float64(nano) * rate * 0.000000001
        return "≈ $${usd}"
    }

    private func availableBalanceUsd(): String {
        let rate = this.revenueStats.usdRate
        let nano = this.revenueStats.balances.availableBalance
        if (rate <= 0.0 || nano == 0) { return "$0.00" }
        let usd = Float64(nano) * rate * 0.000000001
        return "≈ $${usd}"
    }

    private func usdRateText(): String {
        let rate = this.revenueStats.usdRate
        if (rate <= 0.0) { return "" }
        return "1 TON ≈ $${rate}"
    }

    private func cooldownText(): String {
        if (!this.revenueStats.balances.hasNextWithdrawalAt) { return "" }
        let ts = this.revenueStats.balances.nextWithdrawalAt
        if (ts <= 0) { return "" }
        return "Available after: ${ts}"
    }

    private func canWithdraw(): Bool {
        return this.revenueStats.balances.withdrawEnabled
            && this.revenueStats.balances.availableBalance > 0
    }

    private func withdrawBtnText(): String {
        if (!this.revenueStats.balances.withdrawEnabled) {
            return "Withdrawal Unavailable"
        }
        if (this.revenueStats.balances.hasNextWithdrawalAt && this.revenueStats.balances.nextWithdrawalAt > 0) {
            return "Cooldown Active"
        }
        return "Withdraw TON"
    }

    private func withdrawErrorText(): String {
        return this.withdrawError
    }

    private func graphSeriesCount(): Int64 {
        return Int64(this.graphStats.series.size)
    }

    // ── 提现对话框触发 ───────────────────────────────────────────────────────

    private func onWithdrawTap(): Unit {
        if (!this.canWithdraw()) { return }
        this.showWithdrawDialog = true
        this.withdrawPassword = ""
        this.withdrawError = ""
    }

    private func onWithdrawConfirm(): Unit {
        if (this.isWithdrawing) { return }
        if (this.withdrawPassword.isEmpty()) {
            this.withdrawError = "Password is required"
            return
        }
        this.isWithdrawing = true
        this.withdrawError = ""

        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        let pwd = this.withdrawPassword

        let _ = spawn {
            try {
                let revSvc = getRevenueStatsService()
                let authSvc = getRealAuthService()

                let srpResult = authSvc.computeCurrentPasswordSRP(pwd)
                if (srpResult.srpA.size == 0) {
                    launch {
                        this.isWithdrawing = false
                        this.withdrawError = "Failed to verify password. Please try again."
                    }
                    return
                }

                let withdrawResult = revSvc.requestWithdrawalUrl(
                    peerType, peerId,
                    srpResult.srpId, srpResult.srpA, srpResult.srpM1,
                    0
                )

                launch {
                    this.isWithdrawing = false
                    this.showWithdrawDialog = false
                    if (withdrawResult.success) {
                        this.withdrawUrl = withdrawResult.url
                        Hilog.info(0, "CjTelegram", "[ChannelRevenueStatsPage] withdrawal url obtained")
                    } else {
                        match (withdrawResult.errorKind) {
                            case TonWithdrawalErrorKind.PasswordMissing =>
                                this.withdrawError = "2FA password not set. Please enable two-step verification."
                            case TonWithdrawalErrorKind.PasswordInvalid =>
                                this.withdrawError = "Incorrect password. Please try again."
                            case TonWithdrawalErrorKind.TwoFARequired =>
                                this.withdrawError = "Two-step verification required. Wait and try again."
                            case TonWithdrawalErrorKind.Flood =>
                                this.withdrawError = "Too many requests. Please try again later."
                            case _ =>
                                this.withdrawError = "Withdrawal failed. Please try again."
                        }
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChannelRevenueStatsPage] withdrawConfirm error: ${e}")
                launch {
                    this.isWithdrawing = false
                    this.withdrawError = "Withdrawal request failed"
                }
            }
        }
    }

    // ── Buy Ads 触发 ─────────────────────────────────────────────────────────

    private func onBuyAdsTap(): Unit {
        if (this.isLoadingAds) { return }
        this.isLoadingAds = true
        this.showAdsIntro = false

        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()

        let _ = spawn {
            try {
                let revSvc = getRevenueStatsService()
                let url = revSvc.getAdsAccountUrl(peerType, peerId)
                launch {
                    this.isLoadingAds = false
                    if (url.size > 0) {
                        this.adsUrl = url
                        this.showAdsIntro = true
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChannelRevenueStatsPage] getAdsAccountUrl error: ${e}")
                launch {
                    this.isLoadingAds = false
                }
            }
        }
    }

    // ── build ────────────────────────────────────────────────────────────────

    func build() {
        Column() {
                // 顶部导航栏
                Row() {
                    Button(trSource("Back"))
                        .onClick({ _ =>
                            routerPop()
                        })
                        .margin(8)
                    Blank()
                    Text("Channel Revenue")
                        .fontSize(18)
                        .fontWeight(FontWeight.Medium)
                        .margin(right: 16)
                }
                .width(100.percent)
                .height(56)
                .padding(left: 8, right: 8)
                .backgroundColor(0xFFFFFFFF)

                if (this.isLoading) {
                    Column() {
                        LoadingProgress()
                            .width(40)
                            .height(40)
                    }
                    .width(100.percent)
                    .flexGrow(1)
                    .justifyContent(FlexAlign.Center)
                } else if (this.errorMsg.size > 0) {
                    Column() {
                        Text(this.errorMsg)
                            .fontSize(16)
                            .fontColor(0xFFFF3B30)
                            .padding(16)
                    }
                    .width(100.percent)
                    .flexGrow(1)
                    .justifyContent(FlexAlign.Center)
                } else {
                    Scroll() {
                        Column() {
                            // ① TON 收入余额卡 ───────────────────────────────
                            Column() {
                                Text("TON Ad Revenue")
                                    .fontSize(20)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFF1C1C1E)
                                    .margin(top: 16, bottom: 12)
                                    .width(100.percent)

                                // Current Balance
                                Row() {
                                    Text("Current Balance")
                                        .fontSize(15)
                                        .fontColor(0xFF8E8E93)
                                        .flexGrow(1)
                                    Column() {
                                        Text(this.currentBalanceTon())
                                            .fontSize(15)
                                            .fontColor(0xFF1C1C1E)
                                            .fontWeight(FontWeight.Medium)
                                        Text(this.currentBalanceUsd())
                                            .fontSize(12)
                                            .fontColor(0xFF8E8E93)
                                    }
                                    .alignItems(HorizontalAlign.End)
                                }
                                .width(100.percent)
                                .padding(top: 8, bottom: 8)

                                // Available Balance
                                Row() {
                                    Text("Available for Withdrawal")
                                        .fontSize(15)
                                        .fontColor(0xFF8E8E93)
                                        .flexGrow(1)
                                    Column() {
                                        Text(this.availableBalanceTon())
                                            .fontSize(15)
                                            .fontColor(0xFF34C759)
                                            .fontWeight(FontWeight.Medium)
                                        Text(this.availableBalanceUsd())
                                            .fontSize(12)
                                            .fontColor(0xFF8E8E93)
                                    }
                                    .alignItems(HorizontalAlign.End)
                                }
                                .width(100.percent)
                                .padding(top: 8, bottom: 8)

                                // Overall Revenue
                                Row() {
                                    Text("Total Earned")
                                        .fontSize(15)
                                        .fontColor(0xFF8E8E93)
                                        .flexGrow(1)
                                    Text(this.overallRevenueTon())
                                        .fontSize(15)
                                        .fontColor(0xFF1C1C1E)
                                        .fontWeight(FontWeight.Medium)
                                }
                                .width(100.percent)
                                .padding(top: 8, bottom: 8)

                                // USD Rate
                                if (this.usdRateText().size > 0) {
                                    Row() {
                                        Text("Rate")
                                            .fontSize(13)
                                            .fontColor(0xFF8E8E93)
                                            .flexGrow(1)
                                        Text(this.usdRateText())
                                            .fontSize(13)
                                            .fontColor(0xFF8E8E93)
                                    }
                                    .width(100.percent)
                                    .padding(top: 4, bottom: 8)
                                }

                                // Cooldown notice
                                if (this.cooldownText().size > 0) {
                                    Text(this.cooldownText())
                                        .fontSize(13)
                                        .fontColor(0xFFFF9500)
                                        .width(100.percent)
                                        .padding(top: 4, bottom: 8)
                                }
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 0, bottom: 16)
                            .backgroundColor(0xFFFFFFFF)
                            .borderRadius(12)
                            .margin(left: 16, right: 16, top: 16, bottom: 8)

                            // ③ 提现按钮 ──────────────────────────────────────
                            Column() {
                                Button(this.withdrawBtnText())
                                    .width(100.percent)
                                    .height(50)
                                    .fontSize(16)
                                    .fontColor(0xFFFFFFFF)
                                    .backgroundColor(
                                        if (this.canWithdraw()) { 0xFF007AFF } else { 0xFFAEAEB2 }
                                    )
                                    .borderRadius(12)
                                    .onClick({ _ =>
                                        this.onWithdrawTap()
                                    })

                                if (this.withdrawError.size > 0) {
                                    Text(this.withdrawError)
                                        .fontSize(13)
                                        .fontColor(0xFFFF3B30)
                                        .width(100.percent)
                                        .padding(top: 8)
                                }

                                if (this.withdrawUrl.size > 0) {
                                    Text("Withdrawal URL obtained")
                                        .fontSize(13)
                                        .fontColor(0xFF34C759)
                                        .width(100.percent)
                                        .padding(top: 8)
                                }
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 8, bottom: 8)

                            // ② 广告收入图表标题 ───────────────────────────────
                            Text("Ad Revenue Chart")
                                .fontSize(17)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFF1C1C1E)
                                .width(100.percent)
                                .padding(left: 32, right: 16, top: 16, bottom: 4)

                            // 图表摘要（调 GraphService.Currency，GraphPage 处理渲染）
                            Column() {
                                if (!this.graphLoaded) {
                                    Row() {
                                        LoadingProgress()
                                            .width(24)
                                            .height(24)
                                        Text("Loading chart...")
                                            .fontSize(14)
                                            .fontColor(0xFF8E8E93)
                                            .margin(left: 8)
                                    }
                                    .padding(16)
                                } else {
                                    Column() {
                                        Text("Series: ${this.graphSeriesCount()}")
                                            .fontSize(13)
                                            .fontColor(0xFF8E8E93)
                                            .padding(top: 4)
                                        Text("Chart Type: Currency (TON)")
                                            .fontSize(13)
                                            .fontColor(0xFF8E8E93)
                                            .padding(top: 2, bottom: 8)
                                        // Graph 渲染委托给 GraphPage (已合并的 P2-361)
                                        // 点击跳转到 GraphPage 查看完整图表
                                        Button("View Full Chart")
                                            .width(100.percent)
                                            .height(40)
                                            .fontSize(14)
                                            .fontColor(0xFF007AFF)
                                            .backgroundColor(0xFFF2F2F7)
                                            .borderRadius(8)
                                            .onClick({ _ =>
                                                routerPush("GraphPage", "{}")
                                            })
                                    }
                                    .width(100.percent)
                                    .padding(16)
                                }
                            }
                            .width(100.percent)
                            .backgroundColor(0xFFFFFFFF)
                            .borderRadius(12)
                            .margin(left: 16, right: 16, top: 0, bottom: 8)

                            // ④ Buy Ads 入口 ──────────────────────────────────
                            Column() {
                                Text(trSource("Monetization"))
                                    .fontSize(17)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFF1C1C1E)
                                    .width(100.percent)
                                    .padding(bottom: 8)

                                Text("Earn TON by placing ads in your channel. Revenue is shared 50/50 between Telegram and channel owners.")
                                    .fontSize(14)
                                    .fontColor(0xFF8E8E93)
                                    .width(100.percent)
                                    .padding(bottom: 12)

                                Button(if (this.isLoadingAds) { "Loading..." } else { "Buy Ads / Manage" })
                                    .width(100.percent)
                                    .height(44)
                                    .fontSize(15)
                                    .fontColor(0xFFFFFFFF)
                                    .backgroundColor(if (this.isLoadingAds) { 0xFFAEAEB2 } else { 0xFF34C759 })
                                    .borderRadius(10)
                                    .onClick({ _ =>
                                        this.onBuyAdsTap()
                                    })

                                if (this.showAdsIntro && this.adsUrl.size > 0) {
                                    Text("Ad account URL ready. Open in browser:")
                                        .fontSize(13)
                                        .fontColor(0xFF8E8E93)
                                        .width(100.percent)
                                        .padding(top: 8)
                                    Text(this.adsUrl)
                                        .fontSize(12)
                                        .fontColor(0xFF007AFF)
                                        .width(100.percent)
                                        .padding(top: 4)
                                }
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 16, bottom: 16)
                            .backgroundColor(0xFFFFFFFF)
                            .borderRadius(12)
                            .margin(left: 16, right: 16, top: 8, bottom: 8)

                            // 提现密码对话框（叠加层模拟）
                            if (this.showWithdrawDialog) {
                                Column() {
                                    Text("Enter 2FA Password")
                                        .fontSize(17)
                                        .fontWeight(FontWeight.Medium)
                                        .fontColor(0xFF1C1C1E)
                                        .padding(bottom: 12)

                                    Text("Your two-step verification password is required to proceed with TON withdrawal.")
                                        .fontSize(14)
                                        .fontColor(0xFF8E8E93)
                                        .width(100.percent)
                                        .padding(bottom: 12)

                                    TextInput(placeholder: trSource("Password"))
                                        .width(100.percent)
                                        .height(44)
                                        .fontSize(16)
                                        .backgroundColor(0xFFF2F2F7)
                                        .borderRadius(10)
                                        .padding(left: 12, right: 12)
                                        .onChange({ val: String =>
                                            this.withdrawPassword = val
                                        })

                                    if (this.withdrawError.size > 0) {
                                        Text(this.withdrawError)
                                            .fontSize(13)
                                            .fontColor(0xFFFF3B30)
                                            .width(100.percent)
                                            .padding(top: 8)
                                    }

                                    Row() {
                                        Button(trSource("Cancel"))
                                            .flexGrow(1)
                                            .height(44)
                                            .fontSize(15)
                                            .fontColor(0xFF007AFF)
                                            .backgroundColor(0xFFF2F2F7)
                                            .borderRadius(10)
                                            .margin(right: 8)
                                            .onClick({ _ =>
                                                this.showWithdrawDialog = false
                                                this.withdrawError = ""
                                            })

                                        Button(if (this.isWithdrawing) { "..." } else { "Withdraw" })
                                            .flexGrow(1)
                                            .height(44)
                                            .fontSize(15)
                                            .fontColor(0xFFFFFFFF)
                                            .backgroundColor(if (this.isWithdrawing) { 0xFFAEAEB2 } else { 0xFF007AFF })
                                            .borderRadius(10)
                                            .onClick({ _ =>
                                                this.onWithdrawConfirm()
                                            })
                                    }
                                    .width(100.percent)
                                    .padding(top: 16)
                                }
                                .width(100.percent)
                                .padding(24)
                                .backgroundColor(0xFFFFFFFF)
                                .borderRadius(16)
                                .margin(left: 16, right: 16, top: 8, bottom: 24)
                            }

                            Column()
                                .height(32)
                        }
                        .width(100.percent)
                    }
                    .width(100.percent)
                    .flexGrow(1)
                }
            }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }
}
