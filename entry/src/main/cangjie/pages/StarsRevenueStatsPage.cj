package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getStarsRevenueService,
    getStatisticsService,
    getSelectedChatId,
    getSelectedChatPeerType,
    StarsRevenueStatsData,
    StarsRevenueStatusData,
    StarsTransactionData,
    StarsTransactionStatus
}
import ohos_app_cangjie_entry.router.*

/**
 * Stars 收入统计页面 (P2-369)（混合工程迁移版）
 *
 * 对应 iOS StarsStatisticsScreen / StarsOverviewItemNode
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑 → ensureLoaded()+.onAppear
 *
 * Route name: "StarsRevenueStatsPage"
 */
@HybridComponentEntry
@Component
public class StarsRevenueStatsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoading: Bool = true
    @State var errorMsg: String = ""

    @State var revenueStats: StarsRevenueStatsData = StarsRevenueStatsData()
    @State var transactions: Array<StarsTransactionData> = Array<StarsTransactionData>(0, { _ => StarsTransactionData() })

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadStats()
    }

    private func loadStats(): Unit {
        let _ = spawn {
            try {
                let peerType = getSelectedChatPeerType()
                let peerId = getSelectedChatId()
                Hilog.info(0, "CjTelegram", "[StarsRevenueStatsPage] loading peerType=${peerType} peerId=${peerId}")

                let revSvc = getStarsRevenueService()
                let statsSvc = getStatisticsService()

                // 1. 获取 Stars 收入统计（余额卡）
                let revData = revSvc.getStarsRevenueStats(peerType, peerId)

                // 2. 获取交易列表（含 status 字段：refund/pending/failed）
                let txList = statsSvc.getStarsTransactions(peerType, peerId)
                let maxTx = if (txList.size > 20) { 20 } else { txList.size }
                let txArray = Array<StarsTransactionData>(maxTx, { i: Int64 => txList[i] })

                // @State 更新必须在 launch{} 中（S-001）
                launch {
                    this.revenueStats = revData
                    // @State Array 整体赋值（S-007 / temp-var 模式）
                    this.transactions = txArray
                    this.isLoading = false
                    if (!revData.isLoaded) {
                        this.errorMsg = "Failed to load revenue data"
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[StarsRevenueStatsPage] error: ${e}")
                launch {
                    this.errorMsg = "Error loading Stars revenue stats"
                    this.isLoading = false
                }
            }
        }
    }

    // ---- 辅助提取方法（R-107：@Builder 内禁止 let/var，提前计算）----

    private func currentBalanceText(): String {
        return "${this.revenueStats.status.currentBalance} XTR"
    }

    private func availableBalanceText(): String {
        return "${this.revenueStats.status.availableBalance} XTR"
    }

    private func overallRevenueText(): String {
        return "${this.revenueStats.status.overallRevenue} XTR"
    }

    private func usdRateText(): String {
        return "1 XTR ≈ $${this.revenueStats.usdRate}"
    }

    private func txCount(): Int64 {
        return Int64(this.transactions.size)
    }

    // P2-369 核心：交易状态徽标文字
    // 用 match 判断枚举（Cangjie enum 不支持 == 操作符）
    private func txStatusBadge(tx: StarsTransactionData): String {
        match (tx.status) {
            case StarsTransactionStatus.Refund  => "Refund"
            case StarsTransactionStatus.Pending => "Pending"
            case StarsTransactionStatus.Failed  => "Failed"
            case _                              => ""
        }
    }

    // P2-369：状态徽标颜色
    private func txStatusBadgeColor(tx: StarsTransactionData): Int64 {
        match (tx.status) {
            case StarsTransactionStatus.Refund  => 0xFFFF3B30   // 红
            case StarsTransactionStatus.Pending => 0xFFFF9500   // 橙
            case StarsTransactionStatus.Failed  => 0xFFFF3B30   // 红
            case _                              => 0xFF8E8E93   // 灰（不显示）
        }
    }

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

                Text("Stars Revenue")
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
                }
                .width(100.percent)
                .flexGrow(1)
                .justifyContent(FlexAlign.Center)
            } else {
                Scroll() {
                    Column() {
                        // ---- Stars 余额 + 收入卡（P2-369 fidelity gap：之前只有交易列表）----
                        Column() {
                            Text("Stars Revenue")
                                .fontSize(20)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFF1C1C1E)
                                .margin(top: 16, bottom: 12)
                                .width(100.percent)

                            // Current Balance 行
                            Row() {
                                Text("Current Balance")
                                    .fontSize(15)
                                    .fontColor(0xFF8E8E93)
                                    .flexGrow(1)
                                Text(this.currentBalanceText())
                                    .fontSize(15)
                                    .fontColor(0xFF1C1C1E)
                                    .fontWeight(FontWeight.Medium)
                            }
                            .width(100.percent)
                            .padding(top: 8, bottom: 8)
                            .border(width: 1, color: 0xFFE5E5EA)

                            // Available Balance 行
                            Row() {
                                Text("Available for Withdrawal")
                                    .fontSize(15)
                                    .fontColor(0xFF8E8E93)
                                    .flexGrow(1)
                                Text(this.availableBalanceText())
                                    .fontSize(15)
                                    .fontColor(0xFF34C759)
                                    .fontWeight(FontWeight.Medium)
                            }
                            .width(100.percent)
                            .padding(top: 8, bottom: 8)
                            .border(width: 1, color: 0xFFE5E5EA)

                            // Overall Revenue 行
                            Row() {
                                Text("Overall Revenue")
                                    .fontSize(15)
                                    .fontColor(0xFF8E8E93)
                                    .flexGrow(1)
                                Text(this.overallRevenueText())
                                    .fontSize(15)
                                    .fontColor(0xFF1C1C1E)
                                    .fontWeight(FontWeight.Medium)
                            }
                            .width(100.percent)
                            .padding(top: 8, bottom: 8)
                            .border(width: 1, color: 0xFFE5E5EA)

                            // USD Rate 行
                            Row() {
                                Text("Exchange Rate")
                                    .fontSize(14)
                                    .fontColor(0xFF8E8E93)
                                    .flexGrow(1)
                                Text(this.usdRateText())
                                    .fontSize(14)
                                    .fontColor(0xFF8E8E93)
                            }
                            .width(100.percent)
                            .padding(top: 8, bottom: 16)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 0, bottom: 0)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 16, bottom: 8)

                        // ---- 交易列表标题 ----
                        Text("Transactions")
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFF1C1C1E)
                            .width(100.percent)
                            .padding(left: 32, right: 16, top: 8, bottom: 4)

                        // ---- 交易列表（含状态徽标）----
                        Column() {
                            if (this.txCount() == 0) {
                                Text("No transactions")
                                    .fontSize(14)
                                    .fontColor(0xFF8E8E93)
                                    .padding(16)
                                    .width(100.percent)
                            } else {
                                ForEach(this.transactions, itemGenerator: { tx: StarsTransactionData, _idx: Int64 =>
                                    Row() {
                                        // 收/支指示色块
                                        Column()
                                            .width(4)
                                            .height(40)
                                            .backgroundColor(
                                                if (tx.isIncoming) { 0xFF34C759 } else { 0xFFFF3B30 }
                                            )
                                            .borderRadius(2)
                                            .margin(right: 12)

                                        Column() {
                                            Text(tx.peerName)
                                                .fontSize(15)
                                                .fontColor(0xFF1C1C1E)
                                            Text("${tx.date}")
                                                .fontSize(12)
                                                .fontColor(0xFF8E8E93)
                                        }
                                        .alignItems(HorizontalAlign.Start)
                                        .flexGrow(1)

                                        Column() {
                                            // 金额文字
                                            Text(
                                                if (tx.isIncoming) { "+${tx.amount} XTR" } else { "-${tx.amount} XTR" }
                                            )
                                            .fontSize(15)
                                            .fontColor(
                                                if (tx.isIncoming) { 0xFF34C759 } else { 0xFFFF3B30 }
                                            )
                                            .fontWeight(FontWeight.Medium)

                                            // P2-369 核心：交易状态徽标（refund/pending/failed）
                                            // match 枚举（不能用 ==，Cangjie 不支持枚举 == 比较）
                                            if (this.txStatusBadge(tx).size > 0) {
                                                Text(this.txStatusBadge(tx))
                                                    .fontSize(11)
                                                    .fontColor(this.txStatusBadgeColor(tx))
                                                    .fontWeight(FontWeight.Medium)
                                                    .backgroundColor(0xFFF2F2F7)
                                                    .borderRadius(4)
                                                    .padding(left: 4, right: 4, top: 2, bottom: 2)
                                            }
                                        }
                                        .alignItems(HorizontalAlign.End)
                                    }
                                    .width(100.percent)
                                    .padding(left: 16, right: 16, top: 10, bottom: 10)
                                    .border(width: 1, color: 0xFFE5E5EA)
                                })
                            }
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 0, bottom: 24)
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
