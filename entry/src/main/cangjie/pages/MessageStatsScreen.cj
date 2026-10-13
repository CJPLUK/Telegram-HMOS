package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.convert.*
import ohos_app_cangjie_entry.services.{
    getTelegramCore_StatisticsService,
    getSelectedChatId,
    getSelectedChatPeerType,
    MessageStatsData,
    PublicForwardItem
}
import ohos_app_cangjie_entry.router.*

/**
 * MessageStatsScreen — 消息级统计页面（P2-366）（混合工程迁移版）
 *
 * 对应 iOS Statistics/MessageStatistics (StatisticsUI)
 *
 * 功能：
 * - viewsGraph token（interactions graph）— 来自 stats.getMessageStats 响应
 * - reactionsGraph token（reactions-by-emotion graph）— 同上
 * - Public Forwards 列表 — stats.getMessagePublicForwards
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹 + .title/.hideTitleBar，只留内容 + .onAppear
 *  - onReady param(msgId) → takePending("MessageStatsScreen") 经 ensureLoaded()
 *  - S-001: 所有 @State 写入在 launch{} 内（主线程）
 */
@HybridComponentEntry
@Component
public class MessageStatsScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoading: Bool = true
    @State var errorMsg: String = ""
    @State var msgId: Int32 = 0
    @State var msgIdTitle: String = "Message Stats"

    @State var statsData: MessageStatsData = MessageStatsData()

    @State var publicForwards: Array<PublicForwardItem> = Array<PublicForwardItem>(0, { _ => PublicForwardItem() })

    // 当前展示 Tab：0=概览 1=Public Forwards
    @State var activeTab: Int32 = 0

    @State var loaded: Bool = false

    // ── 辅助方法 ──

    private func viewsTokenAvailable(): Bool {
        return this.statsData.viewsGraphToken.size > 0
    }

    private func reactionsTokenAvailable(): Bool {
        return this.statsData.reactionsGraphToken.size > 0
    }

    private func publicForwardsCount(): Int64 {
        return this.publicForwards.size
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true

        // 原 .onReady 参数接收：msgId（经 ParamStore takePending 取代 navDestination param）
        let paramStr = takePending("MessageStatsScreen")
        Hilog.info(0, "CjTelegram", "[MessageStatsScreen] ensureLoaded param='${paramStr}'")
        if (paramStr.size > 0 && paramStr != "{}") {
            try {
                let idVal = Int64.parse(paramStr)
                let parsedId = Int32(idVal)
                launch {
                    this.msgId = parsedId
                    this.msgIdTitle = "Msg #${parsedId}"
                }
                this.startLoadForMsg(parsedId)
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[MessageStatsScreen] ensureLoaded: cannot parse param '${paramStr}'")
                launch {
                    this.isLoading = false
                    this.errorMsg = "Invalid message ID"
                }
            }
        } else {
            launch {
                this.isLoading = false
            }
        }
    }

    // ── 数据加载 ──

    private func startLoadForMsg(capturedMsgId: Int32) {
        let _ = spawn {
            try {
                let peerType = getSelectedChatPeerType()
                let peerId = getSelectedChatId()
                Hilog.info(0, "CjTelegram", "[MessageStatsScreen] loading msgId=${capturedMsgId} peerId=${peerId}")

                let svc = getTelegramCore_StatisticsService()

                let stats = svc.getMessageStats(peerType, peerId, capturedMsgId)

                let forwards = svc.getMessagePublicForwards(peerType, peerId, capturedMsgId)

                let newForwards = forwards

                launch {
                    this.statsData = stats
                    this.publicForwards = newForwards
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[MessageStatsScreen] load error: ${e}")
                launch {
                    this.errorMsg = "Failed to load message statistics"
                    this.isLoading = false
                }
            }
        }
    }

    func build() {
        Column {
            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(48)
                        .height(48)
                        .color(0xFF007AFF)
                    Text("Loading message stats...")
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
                // ── Tab Bar ──
                Row {
                    Button(trSource("Overview"))
                        .onClick({ _ =>
                            this.activeTab = 0
                        })
                        .backgroundColor(if (this.activeTab == 0) { 0xFF007AFF } else { 0xFFEEEEEE })
                        .fontColor(if (this.activeTab == 0) { 0xFFFFFFFF } else { 0xFF000000 })
                        .fontSize(13)
                        .height(34)
                        .layoutWeight(1)
                        .borderRadius(8)
                        .margin(right: 4)
                    Button("Public Forwards")
                        .onClick({ _ =>
                            this.activeTab = 1
                        })
                        .backgroundColor(if (this.activeTab == 1) { 0xFF007AFF } else { 0xFFEEEEEE })
                        .fontColor(if (this.activeTab == 1) { 0xFFFFFFFF } else { 0xFF000000 })
                        .fontSize(13)
                        .height(34)
                        .layoutWeight(1)
                        .borderRadius(8)
                        .margin(left: 4)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 8)

                Scroll() {
                    Column {
                        if (this.activeTab == 0) {
                            this.buildOverviewSection()
                            this.buildInteractionsGraphSection()
                            this.buildReactionsGraphSection()
                        } else {
                            this.buildPublicForwardsSection()
                        }
                    }
                    .width(100.percent)
                }
                .layoutWeight(1)
                .scrollBar(BarState.Auto)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }

    // ─── Overview 卡 ───
    @Builder
    func buildOverviewSection() {
        Column {
            Text("Message Overview")
                .fontSize(13)
                .fontColor(0xFF8E8E93)
                .width(100.percent)
                .margin(bottom: 12)
                .fontWeight(FontWeight.Medium)

            Text("Message ID: ${this.msgId}")
                .fontSize(14)
                .fontColor(0xFF1C1C1E)
                .width(100.percent)
                .margin(bottom: 8)

            Row {
                Column {
                    Text("—")
                        .fontSize(24)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFF1C1C1E)
                    Text(trSource("Views"))
                        .fontSize(12)
                        .fontColor(0xFF8E8E93)
                        .margin(top: 4)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)

                Column {
                    Text("—")
                        .fontSize(24)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFF34C759)
                    Text("Forwards")
                        .fontSize(12)
                        .fontColor(0xFF8E8E93)
                        .margin(top: 4)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)

                Column {
                    Text("—")
                        .fontSize(24)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFF9500)
                    Text(trSource("Reactions"))
                        .fontSize(12)
                        .fontColor(0xFF8E8E93)
                        .margin(top: 4)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
            }
            .width(100.percent)
            .padding(top: 8, bottom: 8)
        }
        .width(100.percent)
        .padding(16)
        .backgroundColor(0xFFFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16, top: 8, bottom: 8)
    }

    // ─── Interactions Graph 卡 ───
    @Builder
    func buildInteractionsGraphSection() {
        Column {
            Text("Interactions Graph")
                .fontSize(13)
                .fontColor(0xFF8E8E93)
                .width(100.percent)
                .margin(bottom: 8)
                .fontWeight(FontWeight.Medium)

            if (this.viewsTokenAvailable()) {
                Column {
                    Row {
                        Column {}
                            .width(4)
                            .height(40)
                            .backgroundColor(0xFF007AFF)
                            .borderRadius(2)
                            .margin(right: 12)
                        Column {
                            Text("Views over time")
                                .fontSize(14)
                                .fontColor(0xFF1C1C1E)
                                .fontWeight(FontWeight.Medium)
                            Text("Hourly breakdown — loaded from server")
                                .fontSize(12)
                                .fontColor(0xFF8E8E93)
                                .margin(top: 2)
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)
                    }
                    .width(100.percent)
                    .padding(top: 8, bottom: 8)
                }
                .width(100.percent)
            } else if (this.statsData.isLoaded) {
                Text("No interactions graph data")
                    .fontSize(14)
                    .fontColor(0xFF8E8E93)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .padding(top: 16, bottom: 16)
            } else {
                Text(trSource("Loading..."))
                    .fontSize(14)
                    .fontColor(0xFF8E8E93)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .padding(top: 8, bottom: 8)
            }
        }
        .width(100.percent)
        .padding(16)
        .backgroundColor(0xFFFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16, top: 8, bottom: 8)
    }

    // ─── Reactions-by-Emotion Graph 卡 ───
    @Builder
    func buildReactionsGraphSection() {
        Column {
            Text("Reactions by Emotion")
                .fontSize(13)
                .fontColor(0xFF8E8E93)
                .width(100.percent)
                .margin(bottom: 8)
                .fontWeight(FontWeight.Medium)

            if (this.reactionsTokenAvailable()) {
                Column {
                    Row {
                        Column {}
                            .width(4)
                            .height(40)
                            .backgroundColor(0xFFFF9500)
                            .borderRadius(2)
                            .margin(right: 12)
                        Column {
                            Text("Reaction breakdown")
                                .fontSize(14)
                                .fontColor(0xFF1C1C1E)
                                .fontWeight(FontWeight.Medium)
                            Text("Emoji reaction distribution from server")
                                .fontSize(12)
                                .fontColor(0xFF8E8E93)
                                .margin(top: 2)
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)
                    }
                    .width(100.percent)
                    .padding(top: 8, bottom: 8)
                }
                .width(100.percent)
            } else if (this.statsData.isLoaded) {
                Text("No reactions graph data")
                    .fontSize(14)
                    .fontColor(0xFF8E8E93)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .padding(top: 16, bottom: 16)
            } else {
                Text(trSource("Loading..."))
                    .fontSize(14)
                    .fontColor(0xFF8E8E93)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .padding(top: 8, bottom: 8)
            }
        }
        .width(100.percent)
        .padding(16)
        .backgroundColor(0xFFFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16, top: 8, bottom: 8)
    }

    // ─── Public Forwards 列表卡 ───
    @Builder
    func buildPublicForwardsSection() {
        Column {
            Text("Public Forwards")
                .fontSize(13)
                .fontColor(0xFF8E8E93)
                .width(100.percent)
                .margin(bottom: 8)
                .fontWeight(FontWeight.Medium)

            if (this.publicForwardsCount() == 0) {
                Column {
                    Text("No public forwards yet")
                        .fontSize(14)
                        .fontColor(0xFF8E8E93)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .padding(top: 24, bottom: 24)
                }
                .width(100.percent)
            } else {
                ForEach(this.publicForwards, itemGenerator: { fwd: PublicForwardItem, idx: Int64 =>
                    this.buildForwardRow(fwd, idx)
                })
            }
        }
        .width(100.percent)
        .padding(16)
        .backgroundColor(0xFFFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16, top: 8, bottom: 8)
    }

    @Builder
    func buildForwardRow(fwd: PublicForwardItem, idx: Int64) {
        Row {
            Stack(alignContent: Alignment.Center) {
                Column {}
                    .width(36)
                    .height(36)
                    .borderRadius(18)
                    .backgroundColor(0xFF007AFF)
                Text(trSource("F"))
                    .fontSize(14)
                    .fontColor(0xFFFFFFFF)
                    .fontWeight(FontWeight.Bold)
            }
            .width(36)
            .height(36)
            .margin(right: 12)

            Column {
                Text(fwd.channelTitle)
                    .fontSize(15)
                    .fontColor(0xFF1C1C1E)
                    .fontWeight(FontWeight.Medium)
                Text("Msg #${fwd.msgId}")
                    .fontSize(12)
                    .fontColor(0xFF8E8E93)
                    .margin(top: 2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Column {
                Text("${fwd.views}")
                    .fontSize(14)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF007AFF)
                Text("views")
                    .fontSize(10)
                    .fontColor(0xFF8E8E93)
                    .margin(top: 2)
            }
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .padding(top: 10, bottom: 10)
        .border(width: if (idx > 0) { 1 } else { 0 }, color: 0xFFE5E5EA)
    }
}
