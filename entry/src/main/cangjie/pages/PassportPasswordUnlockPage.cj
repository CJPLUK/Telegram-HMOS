package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * PassportPasswordUnlockPage — P2-281
 *
 * 用户输入 Telegram Passport 密码，调用 accessSecureId(password) 解锁 SecureId。
 * 成功后调用 setCachedSecureIdAccessContext(ctx) 闭合 ic_passport_secureid_unlock 契约，
 * 然后导航至密钥指纹可视化页 (PassportKeyFingerprintPage)。
 *
 * 对标 iOS: AccessSecureId.swift → _internal_accessSecureId()
 * 状态机: idle / checking / unlocked / error
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()；pushPathByName → routerPush
 *  - aboutToAppear 有实逻辑（loadHint）→ 移到 ensureLoaded()，.onAppear 触发
 */
@HybridComponentEntry
@Component
public class PassportPasswordUnlockPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // Password state machine: "idle" | "checking" | "unlocked" | "error"
    @State var unlockState: String = "idle"
    @State var passwordInput: String = ""
    @State var passwordHint: String = ""
    @State var errorMessage: String = ""
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadHint()
    }

    private func loadHint(): Unit {
        let _ = spawn {
            let authSvc = getRealAuthService()
            let info = authSvc.getPasswordInfo()
            let hint = info.hint
            launch {
                this.passwordHint = hint
            }
        }
    }

    private func onUnlock(): Unit {
        if (this.unlockState == "checking") {
            return
        }
        this.unlockState = "checking"
        this.errorMessage = ""
        let pw = this.passwordInput
        let _ = spawn {
            let svc = getSecureIdEngineService()
            let ctxOpt = svc.accessSecureId(pw)
            match (ctxOpt) {
                case Some(ctx) =>
                    // Close ic_passport_secureid_unlock: set cached context
                    setCachedSecureIdAccessContext(ctx)
                    Hilog.info(0, "CjTelegram", "[PassportPasswordUnlockPage] SecureId unlocked, context cached")
                    launch {
                        this.unlockState = "unlocked"
                        // Navigate to key fingerprint visualization (replace current page)
                        routerPop()
                        routerPush("PassportKeyFingerprintPage", "")
                    }
                case None =>
                    Hilog.info(0, "CjTelegram", "[PassportPasswordUnlockPage] accessSecureId failed")
                    launch {
                        this.unlockState = "error"
                        this.errorMessage = "Incorrect password. Please try again."
                    }
            }
        }
    }

    public func build() {
        Column {
            // Navigation bar
            Row {
                Text("← Back")
                    .fontSize(17)
                    .fontColor(0x0088CC)
                    .onClick({ evt =>
                        routerPop()
                    })
                Blank()
                Text("Passport Password")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                Blank()
                Text(trSource(""))
                    .fontSize(17)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 8, right: 8, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            Scroll() {
                Column {
                    // Lock icon
                    Text("🔐")
                        .fontSize(48)
                        .margin(top: 40, bottom: 16)

                    Text("Enter your Telegram Passport password to access your documents.")
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .textAlign(TextAlign.Center)
                        .margin(bottom: 32)

                    // Password hint (shown if available)
                    if (this.passwordHint.size > 0) {
                        Text("Hint: " + this.passwordHint)
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .fontStyle(FontStyle.Italic)
                            .margin(bottom: 16)
                    }

                    // Password input field
                    TextInput(placeholder: "Enter password")
                        .width(100.percent)
                        .height(48)
                        .fontSize(16)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .padding(left: 12, right: 12)
                        .onChange({ val =>
                            this.passwordInput = val
                        })
                        .margin(bottom: 24)

                    // Error message
                    if (this.errorMessage.size > 0) {
                        Text(this.errorMessage)
                            .fontSize(14)
                            .fontColor(0xE53935)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 16)
                    }

                    // Unlock button
                    Button(if (this.unlockState == "checking") { "Unlocking..." } else { "Unlock" })
                        .width(100.percent)
                        .height(48)
                        .fontSize(17)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(if (this.unlockState == "checking") { 0xAAAAAA } else { 0x0088CC })
                        .borderRadius(8)
                        .enabled(this.unlockState != "checking")
                        .onClick({ evt =>
                            this.onUnlock()
                        })
                        .margin(bottom: 16)

                    if (this.unlockState == "checking") {
                        Row {
                            LoadingProgress()
                                .width(24)
                                .height(24)
                            Text("Verifying password...")
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                                .margin(left: 8)
                        }
                        .margin(bottom: 16)
                    }
                }
                .width(100.percent)
                .padding(16)
                .alignItems(HorizontalAlign.Center)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
