package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.core.services.getTelegramCore_AccountManagerService
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.services.{getAppLockService, getRealAuthService}
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * 对位源侧 DeleteAccountOptionsController.swift（deleteAccountOptionsController，
 * :175-471）：隐私根屏 If Away For 菜单 Delete Account Now 项推入的 Alternative
 * Options 子屏。形态基准照抄同仓已过审的孪生屏 pages/LogoutOptionsPage.cj（同源模块的
 * 另一半：LogoutOptionsController.swift 与 DeleteAccountOptionsController.swift 在源侧
 * 本就是同形孪生屏）。诊断依据
 * e2e/reports/diag-suite_settings_privacy-TC-0129-round2.md §6 M-1。
 */
@HybridComponentEntry
@Component
public class DeleteAccountOptionsScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var hasTwoStepAuth: Bool = false
    @State var hasPasscode: Bool = false
    @State var isCheckingTwoStepEntry: Bool = false
    @State var errorText: String = ""

    protected override func aboutToAppear(): Unit {
        // hasPasscode 是本地同步值（getAppLockService().hasPasscode() 不发网络请求），
        // 与 pages/PrivacySettingsPage.cj:211 同一调用、同一取值时机。
        this.hasPasscode = getAppLockService().hasPasscode()
        // hasTwoStepAuth 需要网络请求，走异步 spawn，与
        // pages/PrivacySettingsPage.cj:412-415 同一调用；异常吞掉保持 false。
        let _ = spawn {
            var hasTwoStep = false
            try {
                let authService = getRealAuthService()
                hasTwoStep = authService.getPasswordInfo().hasPassword
            } catch (_e: Exception) {}
            let hasTwoStepFinal = hasTwoStep
            launch { this.hasTwoStepAuth = hasTwoStepFinal }
        }
    }

    // 照抄 pages/LogoutOptionsPage.cj:20-31 beginAddAccount()——源侧 canAddAccounts 需要
    // activeAccountsAndPeers 那样的只读容量查询，目标 core/services/TelegramCore_AccountManagerService.cj
    // 只暴露会改状态的 addAccount()，没有只读版本，该文件不在本 feature allowlist；本行恒显，
    // 容量检查放在点击路径里，与已过审的 LogoutOptionsPage 同一口径。
    private func beginAddAccount(): Unit {
        let service = getTelegramCore_AccountManagerService()
        match (service.addAccount()) {
            case Some(pair) =>
                let (newSlot, originalSlot) = pair
                getAuthViewModel().isLoggedIn = false
                getAuthViewModel().authState = AUTH_STATE_WAIT_PHONE
                getAuthViewModel().errorMessage = ""
                routerPush("PhoneInputPage", "addaccount:${newSlot}:${originalSlot}")
            case None => this.errorText = "Maximum number of accounts reached"
        }
    }

    /**
     * 对位源侧 DeleteAccountOptionsController.swift:239-263（与
     * PrivacyAndSecurityController.swift:1276-1305 openTwoStepVerification 同一判定树）——
     * 整段照抄 pages/PrivacySettingsPage.cj:662-686，不简化成单条 routerPush。
     */
    private func openTwoStepVerification(): Unit {
        if (this.isCheckingTwoStepEntry) { return }
        this.isCheckingTwoStepEntry = true
        let _ = spawn {
            var notSetNoPendingEmail = false
            try {
                let authService = getRealAuthService()
                let info = authService.getPasswordInfo()
                notSetNoPendingEmail = !info.hasPassword && info.emailUnconfirmedPattern.size == 0
            } catch (_e: Exception) {
                notSetNoPendingEmail = false
            }
            let goToModernSplash = notSetNoPendingEmail

            spawn(UIThread) {
                =>
                this.isCheckingTwoStepEntry = false
                if (goToModernSplash) {
                    routerPush("TwoFactorAuthSplashPage")
                } else {
                    routerPush("TwoFactorAuthPage")
                }
            }
        }
    }

    public func build() {
        Column {
            Row {
                Text("×").fontSize(42).fontColor(0x000000).width(54).height(54)
                    .borderRadius(27).backgroundColor(0xF7F7F9).textAlign(TextAlign.Center)
                    .onClick({ _ => routerPop() })
                Text(trSource("Alternative Options")).fontSize(20).fontWeight(FontWeight.Bold)
                    .layoutWeight(1).textAlign(TextAlign.Center)
                Blank().width(54)
            }.width(100.percent).height(72).padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    // ══════════ CARD A — add ══════════
                    Column {
                        Row {
                            Column {
                                Image(@r(app.media.set2_ic_simcard)).width(24).height(24).fillColor(0xFFFFFF)
                            }.width(34).height(34).borderRadius(8).backgroundColor(0xB853E8)
                                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).margin(right: 14)
                            Column {
                                Text(trSource("Change Phone Number")).fontSize(18).width(100.percent)
                                Text(trSource("Move your contacts, chats and media to a new number."))
                                    .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                            }.layoutWeight(1)
                            Text("›").fontSize(30).fontColor(0xB8B8BD)
                        }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                            .onClick({ _ => routerPush("ChangePhoneIntroPage", "{\"proceed\":\"replace_top\"}") })
                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 60)
                        Row {
                            Image(@r(app.media.logout_ic_add_account)).width(34).height(34).margin(right: 14)
                            Column {
                                Text(trSource("Add Another Account")).fontSize(18).width(100.percent)
                                Text(trSource("You can use up to 3 accounts in one app at the same time."))
                                    .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                            }.layoutWeight(1)
                            Text("›").fontSize(30).fontColor(0xB8B8BD)
                        }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                            .onClick({ _ => this.beginAddAccount() })
                    }.backgroundColor(0xFFFFFF).borderRadius(18).clip(true).margin(left: 16, right: 16, top: 16)

                    // ══════════ CARD B — privacy ══════════
                    Column {
                        Row {
                            Image(@r(app.media.setroot_privacy)).width(34).height(34).margin(right: 14)
                            Column {
                                Text(trSource("Change Your Privacy Settings")).fontSize(18).width(100.percent)
                                Text(trSource("Choose who exactly can see which of your info."))
                                    .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                            }.layoutWeight(1)
                            Text("›").fontSize(30).fontColor(0xB8B8BD)
                        }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                            // 本屏唯一入口是从隐私根屏推来，pop 即等价回到该屏（源侧
                            // replaceTop(makePrivacyAndSecurityController)）；不 push 第二个
                            // PrivacySettingsPage 实例。
                            .onClick({ _ => routerPop() })
                        if (!this.hasTwoStepAuth) {
                            Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 60)
                            Row {
                                Image(@r(app.media.privacy_ic_lock)).width(34).height(34).margin(right: 14)
                                Column {
                                    Text(trSource("Enable Two-Step Verification")).fontSize(18).width(100.percent)
                                    Text(trSource("Set a password that will be required each time you log in."))
                                        .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                                }.layoutWeight(1)
                                Text("›").fontSize(30).fontColor(0xB8B8BD)
                            }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                                .onClick({ _ => this.openTwoStepVerification() })
                        }
                        if (!this.hasPasscode) {
                            Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 60)
                            Row {
                                Image(@r(app.media.logout_ic_passcode)).width(34).height(34).margin(right: 14)
                                Column {
                                    Text(trSource("Set a Passcode")).fontSize(18).width(100.percent)
                                    Text(trSource("Lock the app with a passcode so that others can't open it."))
                                        .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                                }.layoutWeight(1)
                                Text("›").fontSize(30).fontColor(0xB8B8BD)
                            }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                                .onClick({ _ => routerPush("AppLockPage", "") })
                        }
                    }.backgroundColor(0xFFFFFF).borderRadius(18).clip(true).margin(left: 16, right: 16, top: 34)

                    // ══════════ CARD C — remove ══════════
                    Column {
                        Row {
                            Image(@r(app.media.setroot_data)).width(34).height(34).margin(right: 14)
                            Column {
                                Text(trSource("Clear Cache")).fontSize(18).width(100.percent)
                                Text(trSource("Free up disk space on your device; your media will stay in the cloud."))
                                    .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                            }.layoutWeight(1)
                            Text("›").fontSize(30).fontColor(0xB8B8BD)
                        }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                            // 刻意不跟 pages/LogoutOptionsPage.cj:110 的 DataStorageSettingsPage
                            // 走：源侧两屏的 clearCache 都推 StorageUsageScreen
                            // （DeleteAccountOptionsController.swift:277-281、
                            // LogoutOptionsController.swift:184-188）。LogoutOptionsPage 那条
                            // 是它自己的既有偏差（见诊断报告 §5.5，不在本轮范围，不得照抄）。
                            .onClick({ _ => routerPush("StorageUsagePage", "") })
                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 60)
                        Row {
                            Image(@r(app.media.tab_ic_contacts)).width(34).height(34).margin(right: 14)
                            Column {
                                Text(trSource("Clear Synced Contacts")).fontSize(18).width(100.percent)
                                Text(trSource("Remove any unnecessary contacts you may have synced."))
                                    .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                            }.layoutWeight(1)
                            Text("›").fontSize(30).fontColor(0xB8B8BD)
                        }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                            .onClick({ _ => routerPush("DataPrivacySettingsPage", "") })
                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 60)
                        // 源侧 openResolvedUrl(DeleteAccount.DeleteMessagesURL)，目标无浏览器/
                        // WebView 目的地——同口径 pages/LogoutOptionsPage.cj 的 Contact Support 行。
                        Row {
                            Image(@r(app.media.set2_ic_trash)).width(34).height(34).margin(right: 14)
                            Column {
                                Text(trSource("Quickly Delete Your Chats")).fontSize(18).width(100.percent)
                                Text("Learn how to remove any info you don't need in a few taps.")
                                    .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                            }.layoutWeight(1)
                            Text("›").fontSize(30).fontColor(0xB8B8BD)
                        }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                            .onClick({ _ => })
                    }.backgroundColor(0xFFFFFF).borderRadius(18).clip(true).margin(left: 16, right: 16, top: 34)

                    // ══════════ CARD D — support ══════════
                    Column {
                        // 源侧点击先弹 AlertScreen（FAQ / OK），OK 走 supportPeerId() 跳会话；
                        // 目标无等价 alert + 会话跳转链路，同口径留空（同
                        // pages/LogoutOptionsPage.cj 的 Contact Support 行）。
                        Row {
                            Image(@r(app.media.setroot_support)).width(34).height(34).margin(right: 14)
                            Column {
                                Text(trSource("Contact Support")).fontSize(18).width(100.percent)
                                Text(trSource("Tell us about any issues; deleting account doesn't usually help."))
                                    .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                            }.layoutWeight(1)
                            Text("›").fontSize(30).fontColor(0xB8B8BD)
                        }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                            .onClick({ _ => })
                    }.backgroundColor(0xFFFFFF).borderRadius(18).clip(true).margin(left: 16, right: 16, top: 34)

                    // ══════════ CARD E — delete（destructive，无副标题、无 chevron）══════════
                    // 源侧 replaceTop(deleteAccountDataController(mode: .peers))；对位屏
                    // DeleteAccountDataController.swift 同属 set_account_identity 的
                    // owned_source_files 但尚未迁移，见
                    // diag-suite_settings_privacy-TC-0129-round2.md §6 M-1 备注。
                    Text(trSource("Delete My Account")).fontSize(18).fontColor(0xFF3B30).width(100.percent).height(52)
                        .padding(left: 16).backgroundColor(0xFFFFFF).borderRadius(18)
                        .margin(left: 16, right: 16, top: 34, bottom: 30).textAlign(TextAlign.Start)
                        .onClick({ _ => })

                    if (this.errorText.size > 0) {
                        Text(this.errorText).fontSize(14).fontColor(0xFF3B30).margin(left: 32, right: 24, bottom: 16)
                    }
                }.width(100.percent)
            }.layoutWeight(1)
        }.width(100.percent).height(100.percent).backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
    }
}
