package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getBoostStatsService,
    getSelectedChatId,
    getSelectedChatPeerType,
    BoostsStatusData,
    BoostItem,
    BoostsListData
}
import ohos_app_cangjie_entry.router.*

/**
 * Boost 统计页面 (P2-367)（混合工程迁移版）
 *
 * 对应 iOS BoostStatisticsControllerNode / ChannelBoostScreen。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹与其上的 .title(...)，只留内容（NavDestination 由 ArkTS 壳提供）
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑（加载 boost 数据）→ 移入 ensureLoaded()，经根容器 .onAppear 触发
 *  - 无路由参数（peerType/peerId 读全局 selected chat）
 *
 * Route name: "BoostStatsPage"
 */
@HybridComponentEntry
@Component
public class BoostStatsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoading: Bool = true
    @State var errorMsg: String = ""
    @State var activeTab: Int32 = 0   // 0 = Boosts, 1 = Gifts

    @State var boostsStatus: BoostsStatusData = BoostsStatusData()
    @State var boostItems: Array<BoostItem> = Array<BoostItem>(0, { _ => BoostItem() })
    @State var giftItems: Array<BoostItem> = Array<BoostItem>(0, { _ => BoostItem() })

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadBoostStats()
    }

    private func loadBoostStats(): Unit {
        let _ = spawn {
            try {
                let peerType = getSelectedChatPeerType()
                let peerId = getSelectedChatId()
                Hilog.info(0, "CjTelegram", "[BoostStatsPage] loading peerType=${peerType} peerId=${peerId}")

                let svc = getBoostStatsService()

                // 1. 获取 Boost 状态（等级 + 进度）
                let status = svc.getBoostsStatus(peerType, peerId)

                // 2. 获取普通 Boost 列表
                let boostsList = svc.getBoostsList(peerType, peerId, false)

                // 3. 获取 Gift Boost 列表
                let giftsList = svc.getBoostsList(peerType, peerId, true)

                // @State 更新必须在 launch{} 中（S-001：UI 线程写 @State）
                // @State Array 整体赋值（S-007 / temp-var 模式）
                let newBoosts = boostsList.boosts
                let newGifts = giftsList.boosts
                launch {
                    this.boostsStatus = status
                    this.boostItems = newBoosts
                    this.giftItems = newGifts
                    this.isLoading = false
                    if (!status.isLoaded) {
                        this.errorMsg = "Failed to load boost data"
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[BoostStatsPage] error: ${e}")
                launch {
                    this.errorMsg = "Error loading boost stats"
                    this.isLoading = false
                }
            }
        }
    }

    // ---- 辅助提取方法（R-107：@Builder 内禁止 let/var，提前计算）----

    private func levelText(): String {
        return "Level ${this.boostsStatus.level}"
    }

    private func progressValue(): Float64 {
        return this.boostsStatus.progressToNextLevel()
    }

    private func boostsNeededText(): String {
        let needed = this.boostsStatus.boostsNeeded()
        if (needed <= 0) { return "Max level reached" }
        return "${needed} more boosts to reach level ${this.boostsStatus.level + 1}"
    }

    private func progressLabelLeft(): String {
        return "${this.boostsStatus.boostsThisLevel()}"
    }

    private func progressLabelRight(): String {
        return "${this.boostsStatus.nextLevelBoosts}"
    }

    private func boostUserLabel(item: BoostItem): String {
        if (item.hasUserId) {
            return "User ${item.userId}"
        }
        return "Anonymous"
    }

    private func boostDateLabel(item: BoostItem): String {
        return "Since ${item.date}"
    }

    private func boostExpiresLabel(item: BoostItem): String {
        return "Expires ${item.expires}"
    }

    private func boostMultiplierLabel(item: BoostItem): String {
        if (item.multiplier > 1) {
            return "x${item.multiplier}"
        }
        return ""
    }

    private func currentTabItems(): Array<BoostItem> {
        if (this.activeTab == 0) {
            return this.boostItems
        }
        return this.giftItems
    }

    private func emptyTabText(): String {
        if (this.activeTab == 0) {
            return "No boosts yet"
        }
        return "No gift boosts yet"
    }

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

                Text("Boost Statistics")
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
                        // ---- Boost Level Card ----
                        Column() {
                            Text(this.levelText())
                                .fontSize(28)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFF1C1C1E)
                                .margin(top: 16, bottom: 8)

                            // 进度条：真实 boosts / nextLevelBoosts（P2-367 核心 fidelity gap）
                            // KB verified: Progress(value:, total:, progressType: ProgressType.Linear)
                            Progress(
                                value: this.progressValue(),
                                total: 1.0,
                                progressType: ProgressType.Linear
                            )
                            .width(100.percent)
                            .height(6)
                            .color(0xFF007AFF)
                            .backgroundColor(0xFFE5E5EA)
                            .margin(bottom: 8)

                            Text(this.boostsNeededText())
                                .fontSize(14)
                                .fontColor(0xFF8E8E93)
                                .margin(bottom: 4)

                            Row() {
                                Text(this.progressLabelLeft())
                                    .fontSize(12)
                                    .fontColor(0xFF8E8E93)
                                Blank()
                                Text(this.progressLabelRight())
                                    .fontSize(12)
                                    .fontColor(0xFF8E8E93)
                            }
                            .width(100.percent)
                            .margin(bottom: 16)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 0, bottom: 0)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 16, bottom: 8)

                        // ---- Boosts / Gifts Tab Switcher ----
                        Row() {
                            Button(trSource("Boosts"))
                                .onClick({ _ => this.activeTab = 0 })
                                .flexGrow(1)
                                .height(40)
                                .backgroundColor(this.tab0BgColor())
                                .fontColor(this.tab0TextColor())
                                .borderRadius(8)
                                .margin(right: 4)

                            Button(trSource("Gifts"))
                                .onClick({ _ => this.activeTab = 1 })
                                .flexGrow(1)
                                .height(40)
                                .backgroundColor(this.tab1BgColor())
                                .fontColor(this.tab1TextColor())
                                .borderRadius(8)
                                .margin(left: 4)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)

                        // ---- Boost 列表 ----
                        Column() {
                            if (this.currentTabItems().size == 0) {
                                Text(this.emptyTabText())
                                    .fontSize(14)
                                    .fontColor(0xFF8E8E93)
                                    .padding(16)
                                    .width(100.percent)
                            } else {
                                ForEach(this.currentTabItems(), itemGenerator: { item: BoostItem, _idx: Int64 =>
                                    Row() {
                                        Column() {
                                            Text(this.boostUserLabel(item))
                                                .fontSize(16)
                                                .fontColor(0xFF1C1C1E)
                                            Text(this.boostDateLabel(item))
                                                .fontSize(13)
                                                .fontColor(0xFF8E8E93)
                                        }
                                        .alignItems(HorizontalAlign.Start)
                                        .flexGrow(1)

                                        Column() {
                                            Text(this.boostExpiresLabel(item))
                                                .fontSize(12)
                                                .fontColor(0xFF8E8E93)
                                            if (this.boostMultiplierLabel(item).size > 0) {
                                                Text(this.boostMultiplierLabel(item))
                                                    .fontSize(12)
                                                    .fontColor(0xFF007AFF)
                                            }
                                        }
                                        .alignItems(HorizontalAlign.End)
                                    }
                                    .width(100.percent)
                                    .padding(left: 16, right: 16, top: 12, bottom: 12)
                                    .border(width: 1, color: 0xFFE5E5EA)
                                })
                            }
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 0, bottom: 16)
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
