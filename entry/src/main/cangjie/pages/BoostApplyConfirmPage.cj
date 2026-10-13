package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.convert.*
import ohos_app_cangjie_entry.services.{
    getBoostStatsService,
    BoostsStatusData,
    BoostItem,
    ApplyBoostResult,
    MyBoostData
}
import ohos_app_cangjie_entry.router.*

/**
 * P2-302: Boost 频道确认页（替换 Boost + 确认）（混合工程迁移版）
 *
 * 对应 iOS BoostScreen / ChannelBoostScreen 的"替换 Boost"子流程。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹与其上的 .title(...)，只留内容（NavDestination 由 ArkTS 壳提供）
 *  - pageStack.pop() → routerPop()
 *  - 路由参数（"peerId|peerType"）：源经 onReady 读取；此处经 takePending("BoostApplyConfirmPage") 读取
 *  - aboutToAppear 有实逻辑（loadBoostData）→ 移入 ensureLoaded()，经根容器 .onAppear 触发
 *
 * iOS ref: ChannelBoost.swift:125, BoostStatisticsControllerNode (PremiumUI)
 */
@HybridComponentEntry
@Component
public class BoostApplyConfirmPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 路由参数 (解析自 "peerId|peerType")
    @State var peerId: Int64 = 0
    @State var peerType: String = "channel"

    // ─── 加载阶段 ───
    @State var isLoading: Bool = true
    @State var loadError: String = ""

    @State var boostStatus: BoostsStatusData = BoostsStatusData()
    @State var boostItems: Array<BoostItem> = Array<BoostItem>(0, { _ => BoostItem() })

    // ─── 替换槽选择（S-007: @State 集合用 Array<T>，整体赋值模式）───
    @State var selectedSlots: Array<Int32> = Array<Int32>(0, { _ => 0i32 })

    // ─── applyBoost 结果 ───
    @State var isApplying: Bool = false
    @State var applyError: String = ""
    @State var applyResult: ApplyBoostResult = ApplyBoostResult()
    @State var applyDone: Bool = false

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.parseRouteParam(takePending("BoostApplyConfirmPage"))
        this.loadBoostData()
    }

    private func parseRouteParam(param: String): Unit {
        if (param.size == 0) { return }
        let parts = param.split("|")
        if (parts.size >= 1) {
            try { this.peerId = Int64.parse(parts[0]) } catch (_: Exception) {}
        }
        if (parts.size >= 2 && parts[1].size > 0) {
            this.peerType = parts[1]
        }
    }

    private func loadBoostData(): Unit {
        let pid = this.peerId
        let ptype = this.peerType
        let _ = spawn {
            try {
                let svc = getBoostStatsService()
                let status = svc.getBoostsStatus(ptype, pid)
                let boosts = svc.getBoostsList(ptype, pid, false)
                let newBoosts = boosts.boosts
                launch {
                    this.boostStatus = status
                    this.boostItems = newBoosts
                    this.isLoading = false
                    if (!status.isLoaded) {
                        this.loadError = "Failed to load boost status"
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[BoostApplyConfirmPage] load error: ${e}")
                launch {
                    this.loadError = "Error loading boost data"
                    this.isLoading = false
                }
            }
        }
    }

    private func doApplyBoost(): Unit {
        let pid = this.peerId
        let ptype = this.peerType
        let slotsSnap = ArrayList<Int32>()
        let slotsArr = this.selectedSlots
        for (s in slotsArr) {
            slotsSnap.add(s)
        }
        let _ = spawn {
            launch {
                this.isApplying = true
                this.applyError = ""
            }
            try {
                let svc = getBoostStatsService()
                let result = svc.applyBoost(ptype, pid, slotsSnap)
                launch {
                    this.applyResult = result
                    this.isApplying = false
                    this.applyDone = true
                    if (!result.success) {
                        this.applyError = result.errorMessage
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[BoostApplyConfirmPage] applyBoost error: ${e}")
                launch {
                    this.isApplying = false
                    this.applyError = "Apply boost failed"
                }
            }
        }
    }

    // ─── 辅助提取方法（R-107: @Builder 内禁止 let/var）───

    private func levelText(): String {
        return "Level ${this.boostStatus.level}"
    }

    private func progressValue(): Float64 {
        return this.boostStatus.progressToNextLevel()
    }

    private func boostsNeededText(): String {
        let n = this.boostStatus.boostsNeeded()
        if (n <= 0) { return "Maximum level reached" }
        return "${n} boosts to reach Level ${this.boostStatus.level + 1}"
    }

    private func boostUrlText(): String {
        return this.boostStatus.boostUrl
    }

    private func applyButtonLabel(): String {
        if (this.isApplying) { return "Applying..." }
        if (this.selectedSlots.size > 0) { return "Replace Boost" }
        return "Apply Boost"
    }

    private func boostUserLabel(item: BoostItem): String {
        if (item.hasUserId) { return "User ${item.userId}" }
        return "Anonymous Boost"
    }

    private func slotSelectedBg(slot: Int32): Int64 {
        let arr = this.selectedSlots
        var i: Int64 = 0
        while (i < arr.size) {
            if (arr[i] == slot) { return 0xFFE8F0FE }
            i += 1
        }
        return 0xFFFFFFFF
    }

    private func slotSelectedBorder(slot: Int32): Int64 {
        let arr = this.selectedSlots
        var i: Int64 = 0
        while (i < arr.size) {
            if (arr[i] == slot) { return 0xFF007AFF }
            i += 1
        }
        return 0xFFE5E5EA
    }

    private func applyResultLabel(): String {
        if (this.applyResult.success) {
            return "Boost applied successfully! Active boosts: ${this.applyResult.boosts.size}"
        }
        return this.applyError
    }

    private func toggleBoostSlot(slot: Int32): Unit {
        let curSlots = this.selectedSlots
        var found = false
        var fi: Int64 = 0
        while (fi < curSlots.size) {
            if (curSlots[fi] == slot) {
                found = true
                break
            }
            fi += 1
        }
        let tempList = ArrayList<Int32>()
        var si: Int64 = 0
        while (si < curSlots.size) {
            if (found) {
                if (curSlots[si] != slot) { tempList.add(curSlots[si]) }
            } else {
                tempList.add(curSlots[si])
            }
            si += 1
        }
        if (!found) { tempList.add(slot) }
        this.selectedSlots = Array<Int32>(tempList.size, { ti: Int64 => tempList[ti] })
    }

    private func applyResultColor(): Int64 {
        if (this.applyResult.success) { return 0xFF34C759 }
        return 0xFFFF3B30
    }

    func build() {
        Column() {
            // ── 顶部导航栏 ──
            Row() {
                Button(trSource("Back"))
                    .onClick({ _ => routerPop() })
                    .margin(8)
                Blank()
                Text(trSource("Boost Channel"))
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
            } else if (this.loadError.size > 0) {
                Column() {
                    Text(this.loadError)
                        .fontSize(14)
                        .fontColor(0xFFFF3B30)
                        .padding(16)
                    Button(trSource("Retry"))
                        .onClick({ _ => this.loadBoostData() })
                        .margin(top: 12)
                }
                .width(100.percent)
                .flexGrow(1)
                .justifyContent(FlexAlign.Center)
            } else {
                Scroll() {
                    Column() {
                        // ── 等级卡 + 进度条 ──
                        Column() {
                            Text(this.levelText())
                                .fontSize(28)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFF1C1C1E)
                                .margin(top: 16, bottom: 8)

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
                                .margin(bottom: 8)

                            if (this.boostUrlText().size > 0) {
                                Text("Boost link: ${this.boostUrlText()}")
                                    .fontSize(12)
                                    .fontColor(0xFF007AFF)
                                    .margin(bottom: 16)
                            }
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 16, bottom: 8)

                        // ── 已有 Boost 列表（可选择替换 slot）──
                        if (this.boostItems.size > 0) {
                            Text("Your Active Boosts")
                                .fontSize(15)
                                .fontColor(0xFF8E8E93)
                                .padding(left: 16, top: 8, bottom: 4)
                                .width(100.percent)

                            Text("Select boosts to replace (optional)")
                                .fontSize(12)
                                .fontColor(0xFF8E8E93)
                                .padding(left: 16, bottom: 8)
                                .width(100.percent)

                            Column() {
                                ForEach(this.boostItems, itemGenerator: { item: BoostItem, idx: Int64 =>
                                    Row() {
                                        Column() {
                                            Text(this.boostUserLabel(item))
                                                .fontSize(15)
                                                .fontColor(0xFF1C1C1E)
                                            Text("Slot ${Int32(idx)}")
                                                .fontSize(12)
                                                .fontColor(0xFF8E8E93)
                                                .margin(top: 2)
                                        }
                                        .alignItems(HorizontalAlign.Start)
                                        .flexGrow(1)
                                    }
                                    .width(100.percent)
                                    .padding(left: 16, right: 16, top: 12, bottom: 12)
                                    .backgroundColor(this.slotSelectedBg(Int32(idx)))
                                    .border(width: 1, color: this.slotSelectedBorder(Int32(idx)))
                                    .onClick({ _ =>
                                        this.toggleBoostSlot(Int32(idx))
                                    })
                                })
                            }
                            .backgroundColor(0xFFFFFFFF)
                            .borderRadius(12)
                            .margin(left: 16, right: 16, top: 0, bottom: 8)
                        }

                        // ── Apply Boost 按钮 ──
                        Button(this.applyButtonLabel())
                            .onClick({ _ => this.doApplyBoost() })
                            .width(100.percent)
                            .height(50)
                            .margin(left: 16, right: 16, top: 8, bottom: 8)
                            .borderRadius(12)
                            .backgroundColor(0xFF007AFF)
                            .fontColor(0xFFFFFFFF)
                            .fontSize(17)

                        if (this.applyDone || this.applyError.size > 0) {
                            Text(this.applyResultLabel())
                                .fontSize(14)
                                .fontColor(this.applyResultColor())
                                .padding(left: 16, right: 16, top: 4, bottom: 16)
                                .width(100.percent)
                        }
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
