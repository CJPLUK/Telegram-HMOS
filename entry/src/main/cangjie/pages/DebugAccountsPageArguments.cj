package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.{getTelegramCoreAccountManagerService, MultiAccountEntry, getDebugSettingsService}
import ohos_app_cangjie_entry.core.services.getTelegramCore_AccountManagerService
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * DebugAccountsPageArguments — Debug ▸ Accounts 子屏（对应
 * `input/Telegram-iOS/submodules/DebugSettingsUI/Sources/DebugAccountsController.swift`）。
 *
 * 独立 `NavDestination` 路由页，对位 `DebugAccountsController.swift:103` 的 `pushController`；
 * 路由三元组见 `route_map.json` 的 `DebugAccountsPage` 条目与 `ets/pages/DebugAccountsPage.ets`
 * （`e2e/reports/diag-suite_settings_root-sysback-overpop.md`）。
 *
 * 结构/数据/交互按 `DebugAccountsController.swift` 逐项复刻（见 diag-suite_settings_root-TC-0080.md
 * §B）：账号记录卡 + 独立的 “Login to another account” 动作卡 + Production/Test/Cancel sheet。
 */
@HybridComponentEntry
@Component
public class DebugAccountsPageArguments {
    @State var accounts: ArrayList<MultiAccountEntry> = ArrayList<MultiAccountEntry>()
    @State var loaded: Bool = false
    @State var showLoginSheet: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) {
            return
        }
        this.loaded = true
        this.refresh()
    }

    /**
     * 刷新账号列表。源侧 `debugAccountsControllerEntries` 按 `record.id` 升序排序
     * （`DebugAccountsController.swift:92-94`）；目标侧多账号本地记录键是 `slot`
     * （`userId` 对应源侧 `peerId` 语义，不是记录排序键，见 diag §B2），按 `slot` 升序对齐。
     */
    private func refresh(): Unit {
        let raw = getTelegramCoreAccountManagerService().getLoggedInAccounts()
        let pending = ArrayList<MultiAccountEntry>()
        var i: Int64 = 0
        while (i < raw.size) {
            pending.add(raw[i])
            i = i + 1
        }
        this.accounts = this.sortedBySlotAscending(pending)
    }

    /**
     * 选择排序，只用 `.add()` / 下标读取（本工程已验证的 `ArrayList` 用法），
     * 不依赖下标写入语法——账号数恒 ≤3（`canAddAccount` 上限），O(n²) 无性能顾虑。
     */
    private func sortedBySlotAscending(source: ArrayList<MultiAccountEntry>): ArrayList<MultiAccountEntry> {
        let remaining = ArrayList<MultiAccountEntry>()
        var i: Int64 = 0
        while (i < source.size) {
            remaining.add(source[i])
            i = i + 1
        }
        let result = ArrayList<MultiAccountEntry>()
        while (remaining.size > 0) {
            var minIdx: Int64 = 0
            var j: Int64 = 1
            while (j < remaining.size) {
                if (remaining[j].slot < remaining[minIdx].slot) {
                    minIdx = j
                }
                j = j + 1
            }
            result.add(remaining[minIdx])
            remaining.remove(minIdx..(minIdx + 1))
        }
        return result
    }

    /**
     * 点击账号行 → 立即切换（源侧 `switchAccount`，无二次确认，`:108-111`）。
     * 当前账号行同样执行（幂等），不加 `if isActive { return }` 之类的自造短路（diag §B3）。
     */
    private func onTapAccountRow(entry: MultiAccountEntry): Unit {
        let userId = entry.userId
        let _ = getTelegramCoreAccountManagerService().switchToAccount(userId)
        this.refresh()
    }

    private func onTapLoginAnother(): Unit {
        this.showLoginSheet = true
    }

    private func dismissLoginSheet(): Unit {
        this.showLoginSheet = false
    }

    /**
     * 对应 `DebugAccountsController.swift:120-130`：该分支被 `#if DEBUG` /
     * `appBuildType == .internal` 双重包裹，App-Store release 下 else 为空。
     * 目标侧无等价构建期分区，按“忠实源侧 release 行为”取舍——仅关闭 sheet，不做任何事。
     * 这是已定取舍（详见派单三条已裁决事项之外、diag 报告 §B4 的说明），不是待办。
     */
    private func onTapProduction(): Unit {
        this.showLoginSheet = false
    }

    /**
     * 对应 `:131-134` `beginNewAuth(testingEnvironment: true)`：无构建门禁，release 也生效。
     * 目标侧等价：切 USE_TEST_DC + 走与 `SettingsPage.cj` 相同的 addAccount 三段式登录流。
     */
    private func onTapTest(): Unit {
        this.showLoginSheet = false
        getDebugSettingsService().setUseTestDc(true)
        let coreSvc = getTelegramCore_AccountManagerService()
        if (coreSvc.isAddingAccount()) {
            return
        }
        let addResult = coreSvc.addAccount()
        match (addResult) {
            case Some(slotPair) =>
                let (newSlot, origSlot) = slotPair
                let addCtxParam = "addaccount:${newSlot}:${origSlot}"
                routerPush("PhoneInputPage", addCtxParam)
            case None => ()
        }
    }

    private func accountTitle(entry: MultiAccountEntry): String {
        // 源侧行标题是账号本地记录 id 的十进制串，非手机号/用户名/显示名（diag §B3、case §7 豁免具体数值）。
        return "${entry.userId}"
    }

    func build() {
        Stack {
            Column {
                // 头部：返回 + 标题（源侧硬编码英文 "Accounts"，返回按钮取 Common_Back 语义）
                Row {
                    Text("‹")
                        .fontSize(28)
                        .fontColor(0x007AFF)
                        .onClick({ _ => routerPop() })
                    Blank().layoutWeight(1)
                    Text("Accounts")
                        .fontSize(18)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                    Blank().layoutWeight(1)
                    Row { }.width(28)
                }
                .width(100.percent)
                .height(56.0 + getSafeAreaTop())
                .padding(left: 16, right: 16, top: getSafeAreaTop())
                .backgroundColor(0xFFFFFF)
                .alignItems(VerticalAlign.Center)

                Scroll {
                    Column {
                        // 记录行卡（源侧独立 section，仅账号记录）
                        Column {
                            ForEach(this.accounts.toArray(), itemGenerator: { entry: MultiAccountEntry, idx: Int64 =>
                                Row {
                                    Column {
                                        if (entry.isActive) {
                                            DebugAccountCheckIcon()
                                        }
                                    }
                                    .width(62)
                                    .height(44)
                                    .justifyContent(FlexAlign.Center)
                                    .alignItems(HorizontalAlign.Center)

                                    Text(this.accountTitle(entry))
                                        .fontSize(17)
                                        .fontColor(0x000000)
                                        .layoutWeight(1)
                                }
                                .width(100.percent)
                                .constraintSize(minHeight: 44)
                                .alignItems(VerticalAlign.Center)
                                .onClick({ _ => this.onTapAccountRow(entry) })
                                if (idx < this.accounts.size - 1) {
                                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 62)
                                }
                            }, keyGeneratorFunc: { entry: MultiAccountEntry, _idx: Int64 =>
                                // round1 返修（命中 D-127）：`MultiAccountEntry` 未实现 `ToString`，
                                // 省略 keyGeneratorFunc 会退化为按下标生成 key——切换账号后
                                // `isActive` 在同一下标位置的内容发生变化（而非行增删），默认 key
                                // 不变会导致该行的勾选态渲染不重新对齐。改用 `entry.userId`
                                // （账号本地记录唯一且持久标识，见 `accountTitle()` 同款用法）
                                // 这个稳定身份而非位置生成 key，账号切换后对应行能正确重渲染。
                                entry.userId.toString()
                            })
                        }
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(10)
                        .margin(left: 16, right: 16, top: 20)

                        // 动作行卡（源侧独立 section：stableId = Int64.max，恒在最底，永不为空）
                        Column {
                            Text("Login to another account")
                                .fontSize(17)
                                .fontColor(0x007AFF)
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .constraintSize(minHeight: 44)
                        .padding(left: 16, right: 16)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(10)
                        .margin(left: 16, right: 16, top: 20, bottom: 32)
                        .onClick({ _ => this.onTapLoginAnother() })
                    }
                }
                .layoutWeight(1)
                .backgroundColor(0xF2F2F7)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xF2F2F7)
            .padding(bottom: getSafeAreaBottom())

            if (this.showLoginSheet) {
                DebugActionSheet(
                    message: "",
                    group1: this.loginSheetGroup1(),
                    group2: this.loginSheetGroup2(),
                    onDismiss: { => this.dismissLoginSheet() }
                )
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }

    private func loginSheetGroup1(): ArrayList<DebugSheetButton> {
        let g = ArrayList<DebugSheetButton>()
        g.add(DebugSheetButton("Production", DebugSheetButtonStyle.SheetAccent, { => this.onTapProduction() }))
        g.add(DebugSheetButton("Test", DebugSheetButtonStyle.SheetAccent, { => this.onTapTest() }))
        return g
    }

    private func loginSheetGroup2(): ArrayList<DebugSheetButton> {
        let g = ArrayList<DebugSheetButton>()
        g.add(DebugSheetButton("Cancel", DebugSheetButtonStyle.SheetBold, { => this.dismissLoginSheet() }))
        return g
    }
}

/**
 * DebugAccountCheckIcon — 当前账号行的选中勾。运行时矢量绘制，逐参数复刻源侧
 * `PresentationResourcesItemList.generateItemListCheckIcon`（`uif_misc_button_nodes`
 * source_ref `CheckNode.swift` 的渲染算法）：画布 12×10pt，整体 `translate(1,1)`，
 * 描边宽度 1.98，`lineCap`/`lineJoin` 均为 round，路径三点两段折线。
 * 严禁用 Unicode 字形替代（TC-0080 B2 判据）。Canvas 用法对齐本工程既有
 * `components/RadialStatusComponent.cj.drawCheckIcon` 的已验证写法（每行独立实例持有
 * 独立 `ctx`，与该组件在消息列表里逐行实例化的用法同构）。
 */
@Component
class DebugAccountCheckIcon {
    let ctx: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))

    func build() {
        Canvas(this.ctx)
            .width(14)
            .height(12)
            .onReady({ =>
                this.ctx.clearRect(0.0, 0.0, 14.0, 12.0)
                this.ctx.strokeStyle = 0xFF007AFF
                this.ctx.lineWidth = 1.98
                this.ctx.lineCap = "round"
                this.ctx.lineJoin = "round"
                this.ctx.beginPath()
                this.ctx.moveTo(1.215053763, 5.36080467)
                this.ctx.lineTo(4.31621263, 8.70466293)
                this.ctx.lineTo(10.89247312, 1.0)
                this.ctx.stroke()
            })
    }
}
