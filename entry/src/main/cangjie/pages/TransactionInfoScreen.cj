package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.{
    getStatisticsService,
    getSelectedChatId,
    getSelectedChatPeerType,
    StarsTransactionData
}
import ohos_app_cangjie_entry.router.*

/**
 * 交易信息详情页 — Stars 星币交易详情
 *
 * 对应 iOS StatisticsUI/Sources/TransactionInfoScreen.swift 的仓颉移植版本。
 * 显示单笔 Stars 交易详细信息：金额、方向（入账/出账）、时间、对方信息等。
 *
 * 调用链（查询交易列表）：
 *   TransactionInfoScreen.aboutToAppear()
 *   → getStatisticsService().getMegagroupStats(peerType, peerId)
 *     OR getStatisticsService().getBroadcastStats(peerType, peerId)
 *   → getMTProtoClient().sendRequest()  (真实 TL，非 mock)
 *
 * 导航：
 *   根容器为 NavDestination（D-002 规范）。
 *   由 StatisticsPage 通过 pushPathByName("TransactionInfoScreen") 跳转进入。
 *   关闭时通过 appStack.pop() 返回。
 */
@HybridComponentEntry
@Component
public class TransactionInfoScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoading: Bool = true
    @State var errorMsg: String = ""
    @State var transactions: Array<StarsTransactionData> = Array<StarsTransactionData>(0, { _ => StarsTransactionData() })
    @State var selectedIndex: Int64 = -1
    @State var showDetail: Bool = false
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let _ = spawn {
            try {
                let pt = getSelectedChatPeerType()
                let pid = getSelectedChatId()
                Hilog.info(0, "CjTelegram", "[TransactionInfoScreen] loading Stars transactions peerId=${pid}")
                // 调用 payments.getStarsTransactions TL 接口获取真实交易列表
                let svc = getStatisticsService()
                let txList = svc.getStarsTransactions(pt, pid)
                Hilog.info(0, "CjTelegram", "[TransactionInfoScreen] loaded txCount=${txList.size}")
                // 转换为固定大小数组（最多20条），然后赋给 @State
                let maxTx = if (txList.size > 20) { 20 } else { txList.size }
                let txArray = Array<StarsTransactionData>(maxTx, { i: Int64 => txList[i] })
                launch {
                    this.transactions = txArray
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[TransactionInfoScreen] error: ${e}")
                launch {
                    this.errorMsg = "Failed to load transaction details"
                    this.isLoading = false
                }
            }
        }
    }

    // ─── 辅助方法（不在 build/Builder 内用 let）───

    private func transactionCount(): Int64 {
        return Int64(this.transactions.size)
    }

    private func transactionAmountText(idx: Int64): String {
        if (Int64(this.transactions.size) <= idx || idx < 0) { return "0 XTR" }
        let t = this.transactions[idx]
        if (t.isIncoming) {
            return "+${t.amount} XTR"
        }
        return "-${t.amount} XTR"
    }

    private func transactionAmountColor(idx: Int64): Int64 {
        if (Int64(this.transactions.size) <= idx || idx < 0) { return 0xFF1C1C1E }
        if (this.transactions[idx].isIncoming) { return 0xFF34C759 }
        return 0xFFFF3B30
    }

    private func transactionPeerName(idx: Int64): String {
        if (Int64(this.transactions.size) <= idx || idx < 0) { return "" }
        return this.transactions[idx].peerName
    }

    private func transactionDescription(idx: Int64): String {
        if (Int64(this.transactions.size) <= idx || idx < 0) { return "" }
        return this.transactions[idx].description_
    }

    private func transactionDateText(idx: Int64): String {
        if (Int64(this.transactions.size) <= idx || idx < 0) { return "" }
        // Unix timestamp → 日期字符串（简化版）
        let ts = this.transactions[idx].date
        return "${ts}"
    }

    private func selectedTransaction(): StarsTransactionData {
        let idx = this.selectedIndex
        if (idx < 0 || Int64(this.transactions.size) <= idx) {
            return StarsTransactionData()
        }
        return this.transactions[idx]
    }

    // 交易列表行可见性辅助（避免 build() 内 let/var）
    private func txRowVisible(idx: Int64): Bool {
        return idx < this.transactionCount()
    }

    // 单行事务行 Builder（避免 build() 内 let/var）
    @Builder private func buildTxRow(idx: Int64): Unit {
        Row {
            Column {
                Text(this.transactionAmountText(idx))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.transactionAmountColor(idx))
                Text(this.transactionPeerName(idx))
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
                    .margin(top: 2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(this.transactionDateText(idx))
                .fontSize(13)
                .fontColor(0xFF8E8E93)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 14, bottom: 14)
        .backgroundColor(0xFFFFFFFF)
        .border(width: 1, color: 0xFFE5E5EA)
        .onClick({ _ =>
            this.selectedIndex = idx
            this.showDetail = true
        })
    }

    func build() {
        Column {
                if (this.isLoading) {
                    Column {
                        LoadingProgress()
                            .width(48)
                            .height(48)
                            .color(0xFF007AFF)
                        Text("Loading transactions...")
                            .fontSize(14)
                            .fontColor(0xFF8E8E93)
                            .margin(top: 12)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                } else if (this.errorMsg.size > 0) {
                    Column {
                        Text(this.errorMsg)
                            .fontSize(16)
                            .fontColor(0xFFFF3B30)
                            .textAlign(TextAlign.Center)
                            .padding(24)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                } else {
                    // 交易列表或空状态
                    if (this.transactionCount() == 0) {
                        // 空状态 — 展示占位信息
                        Column {
                            Text("No transactions yet")
                                .fontSize(20)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFF1C1C1E)
                                .margin(bottom: 8)
                            Text("Stars transactions for this channel will appear here.")
                                .fontSize(14)
                                .fontColor(0xFF8E8E93)
                                .textAlign(TextAlign.Center)
                                .padding(left: 32, right: 32)
                        }
                        .width(100.percent)
                        .layoutWeight(1)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                    } else {
                        // 交易列表（最多展示20条，固定索引避免 build 内 let/var）
                        Scroll() {
                            Column {
                                if (this.txRowVisible(0)) { this.buildTxRow(0) }
                                if (this.txRowVisible(1)) { this.buildTxRow(1) }
                                if (this.txRowVisible(2)) { this.buildTxRow(2) }
                                if (this.txRowVisible(3)) { this.buildTxRow(3) }
                                if (this.txRowVisible(4)) { this.buildTxRow(4) }
                                if (this.txRowVisible(5)) { this.buildTxRow(5) }
                                if (this.txRowVisible(6)) { this.buildTxRow(6) }
                                if (this.txRowVisible(7)) { this.buildTxRow(7) }
                                if (this.txRowVisible(8)) { this.buildTxRow(8) }
                                if (this.txRowVisible(9)) { this.buildTxRow(9) }
                                if (this.txRowVisible(10)) { this.buildTxRow(10) }
                                if (this.txRowVisible(11)) { this.buildTxRow(11) }
                                if (this.txRowVisible(12)) { this.buildTxRow(12) }
                                if (this.txRowVisible(13)) { this.buildTxRow(13) }
                                if (this.txRowVisible(14)) { this.buildTxRow(14) }
                                if (this.txRowVisible(15)) { this.buildTxRow(15) }
                                if (this.txRowVisible(16)) { this.buildTxRow(16) }
                                if (this.txRowVisible(17)) { this.buildTxRow(17) }
                                if (this.txRowVisible(18)) { this.buildTxRow(18) }
                                if (this.txRowVisible(19)) { this.buildTxRow(19) }
                            }
                            .width(100.percent)
                        }
                        .layoutWeight(1)
                        .scrollBar(BarState.Auto)
                    }

                    // 交易详情面板（选中后展开）
                    if (this.showDetail) {
                        Column {
                            Row {
                                Text("Transaction Details")
                                    .fontSize(16)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFF1C1C1E)
                                    .layoutWeight(1)
                                Button(trSource("Close"))
                                    .onClick({ _ =>
                                        this.showDetail = false
                                        this.selectedIndex = -1
                                    })
                                    .backgroundColor(Color.Transparent)
                                    .fontColor(0xFF007AFF)
                                    .fontSize(15)
                                    .height(36)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 12)
                            Divider()
                                .width(100.percent)
                                .color(0xFFE5E5EA)
                            Column {
                                Text(this.transactionAmountText(this.selectedIndex))
                                    .fontSize(32)
                                    .fontWeight(FontWeight.Bold)
                                    .fontColor(this.transactionAmountColor(this.selectedIndex))
                                    .margin(top: 16, bottom: 16)
                                if (this.transactionPeerName(this.selectedIndex).size > 0) {
                                    Row {
                                        Text("Peer: ")
                                            .fontSize(14)
                                            .fontColor(0xFF8E8E93)
                                        Text(this.transactionPeerName(this.selectedIndex))
                                            .fontSize(14)
                                            .fontColor(0xFF1C1C1E)
                                    }
                                    .width(100.percent)
                                    .padding(left: 16, right: 16, top: 6, bottom: 6)
                                }
                                if (this.transactionDescription(this.selectedIndex).size > 0) {
                                    Row {
                                        Text("Description: ")
                                            .fontSize(14)
                                            .fontColor(0xFF8E8E93)
                                        Text(this.transactionDescription(this.selectedIndex))
                                            .fontSize(14)
                                            .fontColor(0xFF1C1C1E)
                                            .layoutWeight(1)
                                    }
                                    .width(100.percent)
                                    .padding(left: 16, right: 16, top: 6, bottom: 6)
                                }
                                Row {
                                    Text("Date: ")
                                        .fontSize(14)
                                        .fontColor(0xFF8E8E93)
                                    Text(this.transactionDateText(this.selectedIndex))
                                        .fontSize(14)
                                        .fontColor(0xFF1C1C1E)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 6, bottom: 6)
                            }
                            .width(100.percent)
                            .alignItems(HorizontalAlign.Center)
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(12)
                        .margin(top: 8)
                    }
                }
            }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }
}
