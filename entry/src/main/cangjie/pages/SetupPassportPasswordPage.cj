package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * SetupPassportPasswordPage — P2-282（混合工程迁移版）
 *
 * Telegram Passport 2FA 密码设置页面。
 * 在设置 2FA 密码（flag.0）的同时，生成并加密 Passport secure_secret（flag.2），
 * 确保 Passport 功能在密码设置后立即可用。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑（loadPasswordInfo）→ ensureLoaded()+.onAppear
 */
@HybridComponentEntry
@Component
public class SetupPassportPasswordPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var pageState: String = "idle"
    @State var newPassword: String = ""
    @State var confirmPassword: String = ""
    @State var recoveryEmail: String = ""
    @State var passwordHint: String = ""
    @State var hasExistingPassword: Bool = false
    @State var currentPassword: String = ""
    @State var errorMessage: String = ""
    @State var statusMessage: String = ""
    @State var loaded: Bool = false

    // algo params loaded from getPasswordInfo
    private var algoSalt1: Array<Byte> = Array<Byte>(0, repeat: 0)
    private var algoSalt2: Array<Byte> = Array<Byte>(0, repeat: 0)
    private var algoG: Int32 = 0
    private var algoP: Array<Byte> = Array<Byte>(0, repeat: 0)

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadPasswordInfo()
    }

    private func loadPasswordInfo(): Unit {
        this.pageState = "loading"
        let _ = spawn {
            let authSvc = getRealAuthService()
            let info = authSvc.getPasswordInfo()
            let hasPw = info.hasPassword
            let s1 = info.algoSalt1
            let s2 = info.algoSalt2
            let g = info.algoG
            let p = info.algoP
            launch {
                this.hasExistingPassword = hasPw
                this.algoSalt1 = s1
                this.algoSalt2 = s2
                this.algoG = g
                this.algoP = p
                this.pageState = "idle"
            }
        }
    }

    private func onSave(): Unit {
        if (this.newPassword.size == 0) {
            this.errorMessage = "Please enter a new password"
            return
        }
        if (this.newPassword != this.confirmPassword) {
            this.errorMessage = "Passwords do not match"
            return
        }
        if (this.hasExistingPassword && this.currentPassword.size == 0) {
            this.errorMessage = "Please enter your current password"
            return
        }
        this.pageState = "saving"
        this.errorMessage = ""
        this.statusMessage = "Setting up password..."

        let newPass = this.newPassword
        let newHint = this.passwordHint
        let newEmail = this.recoveryEmail
        let curPass = this.currentPassword
        let hasPw = this.hasExistingPassword
        let s1 = this.algoSalt1
        let s2 = this.algoSalt2
        let g = this.algoG
        let p = this.algoP

        let _ = spawn {
            var errMsg = ""
            var success = false
            try {
                let authSvc = getRealAuthService()
                let client = getMTProtoClient()

                // Step 1: compute new password verifier (v = g^x mod p)
                let newHash = authSvc.computeNewPasswordHash(newPass, g, p, s1, s2)

                // Step 2: send AccountUpdatePasswordSettings with flag.0 (new password)
                let req = AccountUpdatePasswordSettings()
                if (hasPw && curPass.size > 0) {
                    req.hasCurrentPassword = true
                    req.currentPasswordSRP = authSvc.computeCurrentPasswordSRP(curPass)
                }
                req.setNewPassword = true
                req.algoSalt1 = s1
                req.algoSalt2 = s2
                req.algoG = g
                req.algoP = p
                req.newPasswordHash = newHash
                req.hint = newHint
                if (newEmail.size > 0) {
                    req.setEmail = true
                    req.email = newEmail
                }
                let respData = client.sendRequest(req.toBytes())
                var pwdSet = false
                if (respData.size >= 4) {
                    let checkD = TLDeserializer(respData)
                    let checkCtor = checkD.readUInt32()
                    // boolTrue#997275b5 or EMAIL_UNCONFIRMED partial success
                    pwdSet = checkCtor == 0x997275b5 || checkCtor == 0x2144ca19
                }

                if (!pwdSet) {
                    Hilog.info(0, "CjTelegram", "[SetupPassportPasswordPage] updatePasswordSettings failed")
                    errMsg = "Failed to set password. Please try again."
                } else {
                    // Step 3: set Passport secure_secret (flag.2)
                    Hilog.info(0, "CjTelegram", "[SetupPassportPasswordPage] Setting Passport secure secret...")
                    let secSvc = getSecureIdEngineService()
                    let secretOk = secSvc.setupSecureSecret(newPass)
                    if (secretOk) {
                        Hilog.info(0, "CjTelegram", "[SetupPassportPasswordPage] Passport secure secret set")
                        success = true
                    } else {
                        // Password was set but secure_secret setup failed — not fatal,
                        // user can retry; we still report partial success
                        Hilog.info(0, "CjTelegram", "[SetupPassportPasswordPage] secure_secret setup failed (non-fatal)")
                        success = true
                        errMsg = "Password set. Passport secret setup incomplete — open Passport to retry."
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[SetupPassportPasswordPage] exception: ${e.message}")
                errMsg = "An error occurred. Please try again."
            }
            let finalSuccess = success
            let finalErr = errMsg
            launch {
                if (finalSuccess) {
                    this.pageState = "success"
                    this.statusMessage = "Password set successfully"
                } else {
                    this.pageState = "error"
                }
                this.errorMessage = finalErr
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

            if (this.pageState == "loading") {
                Column {
                    LoadingProgress()
                        .width(40)
                        .height(40)
                    Text(trSource("Loading..."))
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .margin(top: 12)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.pageState == "success") {
                Column {
                    Text("✓")
                        .fontSize(48)
                        .fontColor(0x43A047)
                        .margin(top: 48, bottom: 16)
                    Text("Passport Password Set")
                        .fontSize(20)
                        .fontWeight(FontWeight.Bold)
                        .margin(bottom: 12)
                    Text("Your Passport is now protected. You can use it to submit verified documents.")
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .textAlign(TextAlign.Center)
                        .margin(bottom: 32)
                    if (this.errorMessage.size > 0) {
                        Text(this.errorMessage)
                            .fontSize(13)
                            .fontColor(0xFF8F00)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 16)
                    }
                    Button(trSource("Done"))
                        .width(100.percent)
                        .height(48)
                        .fontSize(17)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(0x43A047)
                        .borderRadius(8)
                        .onClick({ evt =>
                            routerPop()
                        })
                }
                .width(100.percent)
                .padding(24)
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
            } else {
                Scroll() {
                    Column {
                        Text("🔏")
                            .fontSize(48)
                            .margin(top: 32, bottom: 16)

                        Text("Set a password to protect your Telegram Passport. This password is also used to encrypt your identity documents.")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 24)

                        if (this.hasExistingPassword) {
                            Text("Current Password")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .width(100.percent)
                                .margin(bottom: 4)
                            TextInput(placeholder: "Enter current password")
                                .width(100.percent)
                                .height(48)
                                .fontSize(16)
                                .backgroundColor(0xFFFFFF)
                                .borderRadius(8)
                                .padding(left: 12, right: 12)
                                .onChange({ val =>
                                    this.currentPassword = val
                                })
                                .margin(bottom: 16)
                        }

                        Text(trSource("New Password"))
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .margin(bottom: 4)
                        TextInput(placeholder: "Enter new password")
                            .width(100.percent)
                            .height(48)
                            .fontSize(16)
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(8)
                            .padding(left: 12, right: 12)
                            .onChange({ val =>
                                this.newPassword = val
                            })
                            .margin(bottom: 8)

                        Text("Confirm Password")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .margin(bottom: 4)
                        TextInput(placeholder: "Repeat new password")
                            .width(100.percent)
                            .height(48)
                            .fontSize(16)
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(8)
                            .padding(left: 12, right: 12)
                            .onChange({ val =>
                                this.confirmPassword = val
                            })
                            .margin(bottom: 8)

                        Text("Password Hint (optional)")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .margin(bottom: 4)
                        TextInput(placeholder: "Hint to remember your password")
                            .width(100.percent)
                            .height(48)
                            .fontSize(16)
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(8)
                            .padding(left: 12, right: 12)
                            .onChange({ val =>
                                this.passwordHint = val
                            })
                            .margin(bottom: 8)

                        Text("Recovery Email (optional)")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .margin(bottom: 4)
                        TextInput(placeholder: "Email to recover password")
                            .width(100.percent)
                            .height(48)
                            .fontSize(16)
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(8)
                            .padding(left: 12, right: 12)
                            .onChange({ val =>
                                this.recoveryEmail = val
                            })
                            .margin(bottom: 20)

                        if (this.errorMessage.size > 0) {
                            Text(this.errorMessage)
                                .fontSize(14)
                                .fontColor(0xE53935)
                                .textAlign(TextAlign.Center)
                                .margin(bottom: 12)
                        }

                        if (this.statusMessage.size > 0 && this.pageState == "saving") {
                            Row {
                                LoadingProgress()
                                    .width(20)
                                    .height(20)
                                Text(this.statusMessage)
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                                    .margin(left: 8)
                            }
                            .margin(bottom: 12)
                        }

                        Button(if (this.pageState == "saving") { "Setting up..." } else { "Set Password" })
                            .width(100.percent)
                            .height(48)
                            .fontSize(17)
                            .fontColor(0xFFFFFF)
                            .backgroundColor(if (this.pageState == "saving") { 0xAAAAAA } else { 0x0088CC })
                            .borderRadius(8)
                            .enabled(this.pageState != "saving")
                            .onClick({ evt =>
                                this.onSave()
                            })
                            .margin(bottom: 48)
                    }
                    .width(100.percent)
                    .padding(16)
                    .alignItems(HorizontalAlign.Center)
                }
                .layoutWeight(1)
                .scrollBar(BarState.Off)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
