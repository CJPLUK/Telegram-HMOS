package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.core.services.getTelegramCore_AccountManagerService
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.app.{initAccountSwitchBridge, signalAccountSwitched, getSafeAreaTop, getSafeAreaBottom}

@HybridComponentEntry
@Component
public class LogoutOptionsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var showConfirmation: Bool = false
    @State var loggingOut: Bool = false
    @State var errorText: String = ""

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

    private func logoutCurrentAccount(): Unit {
        if (this.loggingOut) { return }
        this.showConfirmation = false
        this.loggingOut = true
        let _ = spawn {
            try {
                let nextSlot = getTelegramCore_AccountManagerService().logoutCurrentAccountAndSelectNext()
                launch {
                    this.loggingOut = false
                    if (nextSlot >= 0) {
                        initAccountSwitchBridge()
                        signalAccountSwitched(true)
                        getAuthViewModel().isLoggedIn = true
                        getAuthViewModel().authState = AUTH_STATE_READY
                        routerReplace("MainTabPage", "{}")
                    } else {
                        getAuthViewModel().isLoggedIn = false
                        getAuthViewModel().authState = AUTH_STATE_WAIT_PHONE
                        routerReplace("SplashPage", "{}")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[LogoutOptionsPage] logout failed: ${e}")
                launch { this.loggingOut = false; this.errorText = "Could not log out. Please try again." }
            }
        }
    }

    public func build() {
        Stack {
            Column {
                Row {
                    Text("×").fontSize(42).fontColor(0x000000).width(54).height(54)
                        .borderRadius(27).backgroundColor(0xF7F7F9).textAlign(TextAlign.Center)
                        .onClick({ _ => routerPop() })
                    Text(trSource("Log out")).fontSize(20).fontWeight(FontWeight.Bold)
                        .layoutWeight(1).textAlign(TextAlign.Center)
                    Blank().width(54)
                }.width(100.percent).height(72).padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)

                Scroll {
                    Column {
                        Text(trSource("ALTERNATIVE OPTIONS")).fontSize(14).fontColor(0x77777C)
                            .width(100.percent).margin(left: 32, top: 16, bottom: 8)
                        Column {
                            Row {
                                Image(@r(app.media.logout_ic_add_account)).width(34).height(34).margin(right: 14)
                                Column {
                                    Text(trSource("Add Another Account")).fontSize(18).width(100.percent)
                                    Text("Connect other Telegram accounts and easily switch between them.")
                                        .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                                }.layoutWeight(1)
                                Text("›").fontSize(30).fontColor(0xB8B8BD)
                            }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                                .onClick({ _ => this.beginAddAccount() })
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
                            Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 60)
                            Row {
                                Image(@r(app.media.setroot_data)).width(34).height(34).margin(right: 14)
                                Column {
                                    Text(trSource("Clear Cache")).fontSize(18).width(100.percent)
                                    Text(trSource("Free up disk space on your device; your media will stay in the cloud."))
                                        .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                                }.layoutWeight(1)
                                Text("›").fontSize(30).fontColor(0xB8B8BD)
                            }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                                // 源侧 LogoutOptionsController.swift:184-188 与
                                // DeleteAccountOptionsController.swift:277-281 的 clearCache
                                // 都推 StorageUsageScreen；此前误接 DataStorageSettingsPage 是
                                // 静态发现（diag-suite_settings_privacy-TC-0129-round2.md §5.5），
                                // 非本轮 case 触发。
                                .onClick({ _ => routerPush("StorageUsagePage", "") })
                            Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 60)
                            Row {
                                Column {
                                    Image(@r(app.media.set2_ic_simcard)).width(24).height(24).fillColor(0xFFFFFF)
                                }.width(34).height(34).borderRadius(8).backgroundColor(0xB853E8)
                                    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).margin(right: 14)
                                Column {
                                    Text(trSource("Change Phone Number")).fontSize(18).width(100.percent)
                                    Text("Move your account, chats and media to a new number.")
                                        .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                                }.layoutWeight(1)
                                Text("›").fontSize(30).fontColor(0xB8B8BD)
                            }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                                .onClick({ _ => routerPush("ChangePhoneIntroPage", "{\"proceed\":\"replace_top\"}") })
                            Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 60)
                            Row {
                                Image(@r(app.media.setroot_support)).width(34).height(34).margin(right: 14)
                                Column {
                                    Text(trSource("Contact Support")).fontSize(18).width(100.percent)
                                    Text(trSource("Tell us about any issues; logging out doesn't usually help."))
                                        .fontSize(14).fontColor(0x8E8E93).width(100.percent).margin(top: 2)
                                }.layoutWeight(1)
                                Text("›").fontSize(30).fontColor(0xB8B8BD)
                            }.height(86).padding(left: 16, right: 14).alignItems(VerticalAlign.Center)
                        }.backgroundColor(0xFFFFFF).borderRadius(18).clip(true).margin(left: 16, right: 16)

                        Text(if (this.loggingOut) { "Logging Out..." } else { "Log Out" })
                            .fontSize(18).fontColor(0xFF3B30).width(100.percent).height(52)
                            .padding(left: 16).backgroundColor(0xFFFFFF).borderRadius(18)
                            .margin(left: 16, right: 16, top: 34).textAlign(TextAlign.Start)
                            .onClick({ _ => if (!this.loggingOut) { this.showConfirmation = true } })
                        Text("Logging out deactivates all Secret Chats.").fontSize(14).fontColor(0x77777C)
                            .width(100.percent).margin(left: 32, top: 9, bottom: 30)
                        if (this.errorText.size > 0) {
                            Text(this.errorText).fontSize(14).fontColor(0xFF3B30).margin(left: 32, right: 24)
                        }
                    }.width(100.percent)
                }.layoutWeight(1)
            }.width(100.percent).height(100.percent).backgroundColor(0xF2F2F7)
            .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())

            if (this.showConfirmation) {
                Stack(alignContent: Alignment.Bottom) {
                    Column { }.width(100.percent).height(100.percent).backgroundColor(0x66000000)
                        .onClick({ _ => this.showConfirmation = false })
                    Column {
                        Text("Log Out?").fontSize(17).fontWeight(FontWeight.Bold).margin(top: 18)
                        Text("Are you sure you want to log out of this account?")
                            .fontSize(15).fontColor(0x8E8E93).textAlign(TextAlign.Center)
                            .margin(left: 20, right: 20, top: 7, bottom: 18)
                        Divider().color(0xE5E5EA).strokeWidth(1)
                        Row {
                            Text(trSource("Cancel")).fontSize(17).fontColor(0x0A84FF).layoutWeight(1)
                                .height(50).textAlign(TextAlign.Center).onClick({ _ => this.showConfirmation = false })
                            Divider().vertical(true).height(50).color(0xE5E5EA).strokeWidth(1)
                            Text(trSource("OK")).fontSize(17).fontWeight(FontWeight.Medium).fontColor(0xFF3B30)
                                .layoutWeight(1).height(50).textAlign(TextAlign.Center)
                                .onClick({ _ => this.logoutCurrentAccount() })
                        }
                    }.width(100.percent).backgroundColor(0xFFFFFF)
                        .borderRadius(topLeft: 18, topRight: 18)
                        .alignItems(HorizontalAlign.Center).padding(bottom: 18)
                }.width(100.percent).height(100.percent)
            }
        }.width(100.percent).height(100.percent)
    }
}
