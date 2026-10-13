package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getPrivacyEngineService, getUndoToastService}
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSectionFooter,
    ItemListSeparator,
    ItemListDisclosureRow,
    ItemListNavBarBackground,
    itemListNavBarBackgroundAlpha255,
    ITEM_LIST_NAVBAR_H,
    ITEM_LIST_TEXT_SECONDARY
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.subscribe
import ohos_app_cangjie_entry.utils.safeAnimateTo
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

// inputPrivacyKeyNoPaidMessages#bdc597b4（crc32 of "inputPrivacyKeyNoPaidMessages", tl_codegen
// cross-checked against TelegramApi/Sources/Api0.swift dict[-1111124044] == 0xbdc597b4，同法核对
// KEY_ABOUT#3823cc40 与本仓已用常量吻合）。本页本地字面量常量，理由同
// SelectivePrivacySettingsPeersPage.cj 的 SELECTIVE_PRIVACY_PEERS_KEY_PHONE_P2P 先例——
// getPrivacyRules()/setPrivacyWithUsers() 是已有的通用签名（任意 keyConstructor），不需要改
// services/PrivacyEngineService.cj（不在本 feature allowlist 内）就能读写这一支例外名单。
let MESSAGES_NO_PAID_KEY: UInt32 = 0xbdc597b4

/**
 * IncomingMessagePrivacyPage — Messages 隐私屏（RC-E12-2 详情屏半）。
 *
 * 对位源侧 `IncomingMessagePrivacyScreen.swift`（`incomingMessagePrivacyScreen()`）。
 *
 * 数据源是 `GlobalPrivacySettings.nonContactChatsPrivacy`，不是 `getPrivacyRules()` 三档
 * 基础设施——不扩 `SelectivePrivacySettingsPage.kindParam`，本页独立。复用根屏
 * `PrivacySettingsPage.cj:163-164`/`:557-558` 既有的取数路径（`svc.getGlobalPrivacySettings()`
 * 的 `newNoncontactPeersRequirePremium`/`noncontactPeersPaidStars` 两个字段），不新造第二条。
 *
 * 三档 tier 由两个独立 flag 位派生（源侧 `NonContactChatsPrivacy` 枚举的镜像）：
 * `paidStars > 0` ⇒ paidMessages；否则 `requirePremium` ⇒ requirePremium；否则 everybody。
 *
 * 已知限制（如实登记，见 <feature_id>.md）：`services/PrivacyEngineService.cj:
 * setGlobalPrivacySettings()`（不在本 feature target_files 内，归 `set_privacy_and_security_root`）
 * 签名没有 `paidStars` 入参 —— Premium 用户选中 "Charge for Messages" 档位后无法真正落服务端
 * （本页只做本地预览：显示价格/例外分区，不提交）；切回前两档时，若服务端已存在真实
 * paidStars，也无法清零它（同一签名缺口）。价格段只做只读展示（没有源侧 `MessagePriceItem`
 * 滑杆的对位组件，也没有 `StarsSubscriptionConfiguration`/佣金比例的取数通道，未编造数字）。
 * 例外段（Remove Fee）不受此限——`getPrivacyRules`/`setPrivacyWithUsers` 是已有的通用签名，
 * 走 `inputPrivacyKeyNoPaidMessages` 这一支，读写都真实生效。已就此 emit
 * `emitted_integration_contracts[]` 给 `set_privacy_and_security_root`，请求补齐该签名。
 */
@HybridComponentEntry
@Component
public class IncomingMessagePrivacyPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoading: Bool = true
    @State var hasLoadedOnce: Bool = false
    @State var handlerRegistered: Bool = false

    // 服务端真值三档（"everybody" | "requirePremium" | "paidMessages"）。
    @State var committedTier: String = "everybody"
    @State var paidStars: Int64 = 0
    @State var exceptionCount: Int64 = 0
    @State var isPremium: Bool = false

    // Premium 用户点击 "Charge for Messages" 时的本地预览态（不落服务端，见已知限制）。
    // 非 Premium 用户点击该档走与 ContactsAndPremium 同款付费墙提示，不进入预览。
    @State var previewPaidMessages: Bool = false

    private var contentScroller: Scroller = Scroller()
    @State var navBarAlpha255: UInt32 = 0
    private var prevScrollOffsetVp: Float64 = 0.0

    private let shownEvent: String = "settings.incomingMessagePrivacyPage.shown"

    private func registerShownHandlerOnce(): Unit {
        if (this.handlerRegistered) {
            return
        }
        this.handlerRegistered = true
        // 对位 SelectivePrivacySettingsPage.cj 同款先例：本 NavDestination 从子屏/其它页
        // 返回时保持挂载，onShown → dispatchEvent 转发到这里重新拉服务端真值（Premium 状态
        // 与例外名单都可能在离开本页期间变化）。
        subscribe(this.shownEvent, { _payload: String => this.refresh() })
    }

    private func displayTier(): String {
        if (this.previewPaidMessages) {
            return "paidMessages"
        }
        return this.committedTier
    }

    private func refresh(): Unit {
        if (!this.hasLoadedOnce) {
            this.isLoading = true
        }
        let _ = spawn {
            let svc = getPrivacyEngineService()
            var tierVal = "everybody"
            var paidStarsVal: Int64 = 0
            try {
                let gps = svc.getGlobalPrivacySettings()
                paidStarsVal = gps.noncontactPeersPaidStars
                if (paidStarsVal > 0) {
                    tierVal = "paidMessages"
                } else if (gps.newNoncontactPeersRequirePremium) {
                    tierVal = "requirePremium"
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[IncomingMessagePrivacyPage] refresh globalPrivacy error: ${e}")
            }
            var exceptionCountVal: Int64 = 0
            try {
                let rules = svc.getPrivacyRules(MESSAGES_NO_PAID_KEY)
                exceptionCountVal = rules.allowUsers.size + rules.allowChats.size
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[IncomingMessagePrivacyPage] refresh exceptions error: ${e}")
            }
            let premium = match (getAuthStorage().getUserData()) {
                case Some(u) => u.isPremium
                case None => false
            }
            let tierFinal = tierVal
            let paidStarsFinal = paidStarsVal
            let exceptionCountFinal = exceptionCountVal
            let premiumFinal = premium
            spawn(UIThread) {
                =>
                this.committedTier = tierFinal
                this.paidStars = paidStarsFinal
                this.exceptionCount = exceptionCountFinal
                this.isPremium = premiumFinal
                this.previewPaidMessages = false
                this.isLoading = false
                this.hasLoadedOnce = true
            }
        }
    }

    // E5/E6 同款付费墙提示（对位源侧 disabledValuePressed，`.premiumPaywall` UndoOverlay），
    // 形状照 SelectivePrivacySettingsPage.cj:displayLockedInfo() 逐字复刻（同一資源/同一
    // 调用形状，两处 iconRes 一致，非巧合——都是「点了锁定档位」这一件事）。
    //
    // B-3（TC-0133-R4）：同 SelectivePrivacySettingsPage.cj 的返修——persistent: true 不是
    // 源侧 `timeout: nil` 的正确对位（IncomingMessagePrivacyScreen.swift:273 同样传
    // timeout: nil + 同一文案 Privacy_Messages_PremiumToast_Text，无 "](" ⇒ 3 秒自动消失，
    // 非常驻），改为 durationMs: 3000 + showProgress: false。
    private func displayLockedInfo(): Unit {
        getUndoToastService().showUndo(
            "Subscribe to Telegram Premium to select this option",
            actionText: "Add",
            title: "Premium Required",
            iconRes: Some(@r(app.media.set2_ic_premiumstar)),
            durationMs: 3000,
            showProgress: false,
            onUndo: { => routerPush("PremiumPage", "") },
            onCommit: { => () }
        )
    }

    // 与 SelectivePrivacySettingsPage.cj:setHideReadTime() 同款写法：先取当前完整值回填
    // 其余五个入参，只改 requirePremium 这一位，不得传常量清空别的全局隐私位。
    private func selectEverybody(): Unit {
        if (this.displayTier() == "everybody") {
            return
        }
        this.previewPaidMessages = false
        this.committedTier = "everybody"
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let cur = svc.getGlobalPrivacySettings()
            let _ = svc.setGlobalPrivacySettings(
                cur.archiveAndMuteNewNoncontactPeers,
                cur.keepArchivedUnmuted,
                cur.keepArchivedFolders,
                cur.hideReadMarks,
                false,
                cur.displayGiftsButton
            )
        }
    }

    private func selectContactsAndPremium(): Unit {
        if (!this.isPremium) {
            this.displayLockedInfo()
            return
        }
        if (this.displayTier() == "requirePremium") {
            return
        }
        this.previewPaidMessages = false
        this.committedTier = "requirePremium"
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let cur = svc.getGlobalPrivacySettings()
            let _ = svc.setGlobalPrivacySettings(
                cur.archiveAndMuteNewNoncontactPeers,
                cur.keepArchivedUnmuted,
                cur.keepArchivedFolders,
                cur.hideReadMarks,
                true,
                cur.displayGiftsButton
            )
        }
    }

    // 与前两档不同：本档无法落服务端（见文件头「已知限制」），点击只切本地预览态，
    // 让 footer/价格段/例外段按源侧结构切换渲染——不是死按钮（RC-E12-2 要修的正是
    // "行仍完全无反应"这一类问题），只是写侧缺口如实体现为"不提交"而非"假装提交"。
    private func selectChargeForMessages(): Unit {
        if (!this.isPremium) {
            this.displayLockedInfo()
            return
        }
        if (this.displayTier() == "paidMessages") {
            return
        }
        this.previewPaidMessages = true
    }

    private func onRowTap(tier: String): Unit {
        if (tier == "everybody") {
            this.selectEverybody()
        } else if (tier == "requirePremium") {
            this.selectContactsAndPremium()
        } else {
            this.selectChargeForMessages()
        }
    }

    // 源侧 footer 在 .paidMessages 档才切成 ChargeForMessagesInfo（Localizable.strings
    // Privacy.Messages.ChargeForMessagesInfo，含源串自身的 "outide" 拼写，逐字保留）；其余两档
    // 恒为 Privacy.Messages.SectionFooter + 内嵌 "What is Telegram Premium?" 链接（源侧是紧随其后
    // 的独立 .info 行，本页用 ItemListSectionFooter 的 linkText 子串机制合并成一段，视觉等价）。
    private func footerText(): String {
        if (this.displayTier() == "paidMessages") {
            return "Charge a fee for messages from people outide your contacts or those you haven't messaged first."
        }
        return "You can restrict incoming messages to only contacts and Premium users.\n\nWhat is Telegram Premium?"
    }

    private func footerLinkText(): String {
        if (this.displayTier() == "paidMessages") {
            return ""
        }
        return "What is Telegram Premium?"
    }

    private func onInfoLinkTap(): Unit {
        routerPush("PremiumPage", "")
    }

    private func priceText(): String {
        if (this.paidStars <= 0) {
            return "Not set"
        }
        if (this.paidStars == 1) {
            return "1 Star"
        }
        return "${this.paidStars} Stars"
    }

    private func exceptionValueText(): String {
        if (this.exceptionCount > 0) {
            return "${this.exceptionCount}"
        }
        return ""
    }

    private func openExceptions(): Unit {
        routerPush("SelectivePrivacySettingsPeersPage", "messages|allow")
    }

    @Builder
    func buildTierRow(title: String, checked: Bool, locked: Bool, tier: String) {
        Row {
            Stack(alignContent: Alignment.Center) {
                if (checked) {
                    Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(0x007AFF)
                } else if (locked) {
                    Image(@r(app.media.misc_ic_premiumlock)).width(20).height(20).fillColor(ITEM_LIST_TEXT_SECONDARY)
                }
            }
            .width(62).height(44)
            Text(title).fontSize(17).fontColor(0x000000).layoutWeight(1)
        }
        .width(100.percent).height(44)
        .padding(right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _evt => this.onRowTap(tier) })
    }

    public func build() {
        Stack {
            Stack(alignContent: Alignment.TopStart) {
                Scroll(this.contentScroller) {
                    Column {
                        if (this.isLoading) {
                            Column {
                                LoadingProgress().width(32).height(32)
                                Text(trSource("Loading..."))
                                    .fontSize(14).fontColor(ITEM_LIST_TEXT_SECONDARY).margin(top: 12)
                            }
                            .width(100.percent)
                            .padding(top: 80)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                        } else {
                            ItemListSectionHeader(title: "WHO CAN SEND ME MESSAGES?", topPad: 16)

                            Column {
                                this.buildTierRow("Everybody", this.displayTier() == "everybody", false, "everybody")
                                ItemListSeparator()
                                this.buildTierRow(
                                    "My Contacts and Premium Users",
                                    this.displayTier() == "requirePremium",
                                    !this.isPremium && this.displayTier() != "requirePremium",
                                    "requirePremium"
                                )
                                ItemListSeparator()
                                this.buildTierRow(
                                    "Charge for Messages",
                                    this.displayTier() == "paidMessages",
                                    !this.isPremium && this.displayTier() != "paidMessages",
                                    "paidMessages"
                                )
                            }
                            .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16)

                            ItemListSectionFooter(
                                text: this.footerText(),
                                linkText: this.footerLinkText(),
                                onLinkTap: { _: String => this.onInfoLinkTap() }
                            )

                            if (this.displayTier() == "paidMessages") {
                                ItemListSectionHeader(title: "SET YOUR PRICE PER MESSAGE", topPad: 24)

                                Row {
                                    Text("Price per message").fontSize(17).fontColor(0x000000).layoutWeight(1)
                                    Text(this.priceText()).fontSize(17).fontColor(ITEM_LIST_TEXT_SECONDARY)
                                }
                                .width(100.percent).height(44)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16)

                                if (this.isPremium) {
                                    ItemListSectionHeader(title: "EXCEPTIONS", topPad: 24)

                                    Column {
                                        ItemListDisclosureRow(
                                            title: "Remove Fee",
                                            value: this.exceptionValueText(),
                                            onClick: { => this.openExceptions() }
                                        )
                                    }
                                    .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16)

                                    ItemListSectionFooter(
                                        text: "Add users or entire groups who won't be charged for sending messages to you."
                                    )
                                }
                            }
                        }
                    }
                    .padding(top: ITEM_LIST_NAVBAR_H)
                    .width(100.percent)
                }
                .align(Alignment.Top)
                .padding(top: ITEM_LIST_NAVBAR_H)
                .width(100.percent).height(100.percent)
                .backgroundColor(0xF2F2F7)
                .onDidScroll({ _xDelta: Float64, _yDelta: Float64, _scrollState: ScrollState =>
                    let cur = this.contentScroller.currentOffset()
                    if (cur.isSome()) {
                        let off = cur.getOrThrow().yOffset
                        let target = itemListNavBarBackgroundAlpha255(off)
                        if (this.prevScrollOffsetVp >= 30.0 && off <= 0.0) {
                            safeAnimateTo({ => this.getUIContext() },
                                AnimateParam(duration: 200, curve: Curve.EaseInOut),
                                { => this.navBarAlpha255 = target })
                        } else {
                            this.navBarAlpha255 = target
                        }
                        this.prevScrollOffsetVp = off
                    }
                })

                Stack(alignContent: Alignment.TopStart) {
                    ItemListNavBarBackground(alpha255: this.navBarAlpha255)

                    Row {
                        Stack {
                            Text("‹")
                                .fontSize(28)
                                .fontColor(0x000000)
                        }
                        .width(44).height(44)
                        .borderRadius(22)
                        .backgroundColor(0xFFFFFF)
                        .alignContent(Alignment.Center)
                        .onClick({ _ => routerPop() })
                        Blank().layoutWeight(1)
                        Text(trSource("Messages"))
                            .fontSize(18).fontWeight(FontWeight.Bold)
                        Blank().layoutWeight(1)
                        Row { }.width(44)
                    }
                    .width(100.percent)
                    .height(ITEM_LIST_NAVBAR_H)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                }
                .width(100.percent)
                .height(ITEM_LIST_NAVBAR_H)
            }
            .width(100.percent).height(100.percent)
        }
        .width(100.percent).height(100.percent).backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({
            =>
            this.registerShownHandlerOnce()
            this.refresh()
        })
    }
}
