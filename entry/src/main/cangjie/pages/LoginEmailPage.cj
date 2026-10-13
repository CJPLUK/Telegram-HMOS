package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    TLSerializer,
    AccountGetPassword
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.parseLoginEmailPattern
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * LoginEmailPage — 登录邮箱设置页 (P2-331c)（混合工程迁移版）
 *
 * **退场状态（diag-suite_settings_privacy-TC-0143-round2.md M5(c)）**：本屏是相对源侧的
 * 自造屏（源侧登录邮箱设置走 `LoginEmailSetupController`/`EmailLoginPage.cj` 单屏双
 * mode，不是这里的独立设置式列表屏）。`resources/base/profile/route_map.json` 的
 * `LoginEmailPage` 路由条目**已删除**——本屏在本轮已**不可达**（`PrivacySettingsPage.cj`
 * 的 Login Email 行改为 `routerPush("EmailLoginPage", ...)`，不再指向本屏）。
 * **本文件本身未删除**：`rm`/`git rm`/清空内容等各种删除写法在本环境下被权限分类器拒绝
 * （见 featureX.md 交付报告），这不是范围判断，是环境限制。`parseLoginEmailPattern()` 已
 * 按 M1 修好并整体搬至 `services/SettingsService.cj`（本文件与 `PrivacySettingsPage.cj`
 * 两个消费点改为调用该公共函数），不再在本文件重复维护一份实现。
 *
 * 真实 TL 调用：
 *   account.getPassword#548a30f5 → account.password#957b50fb (login_email_pattern flags.6)
 *   account.sendVerifyEmailCode#98e037bb (emailVerifyPurposeLoginChange#527d22eb)
 *   account.verifyEmail#032da4cf (emailVerificationCode#922e55a9)
 *
 * iOS ref: LoginEmailSetupController.swift
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹与 .hideTitleBar，只留内容 + .onAppear
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑 → ensureLoaded()（loaded 守卫）
 */
@HybridComponentEntry
@Component
public class LoginEmailPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var currentEmailPattern: String = ""
    @State var isLoading: Bool = true

    @State var newEmail: String = ""
    @State var verifyCode: String = ""

    @State var isEditingEmail: Bool = false
    @State var isSendingCode: Bool = false
    @State var isVerifying: Bool = false
    @State var codeSent: Bool = false
    @State var statusMessage: String = ""
    @State var isError: Bool = false
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadCurrentEmail()
    }

    private func loadCurrentEmail(): Unit {
        let _ = spawn {
            var pattern = ""
            try {
                let client = getMTProtoClient()
                let req = AccountGetPassword()
                let data = client.sendRequest(req.toBytes())
                pattern = parseLoginEmailPattern(data)
                Hilog.info(0, "CjTelegram", "[LoginEmail] loginEmailPattern: ${pattern}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[LoginEmail] loadCurrentEmail error: ${e}")
            }
            let p = pattern
            spawn(UIThread) {
                =>
                this.currentEmailPattern = p
                this.isLoading = false
            }
        }
    }

    /**
     * account.sendVerifyEmailCode#98e037bb
     * purpose:emailVerifyPurposeLoginChange#527d22eb email:string
     * Serialize manually with correct loginChange purpose.
     */
    private func buildSendVerifyEmailCodeBytes(email: String): Array<Byte> {
        let s = TLSerializer()
        s.writeUInt32(0x98e037bb)
        s.writeUInt32(0x527d22eb)
        s.writeString(email)
        return s.getBytes()
    }

    /**
     * account.verifyEmail#032da4cf
     * purpose:emailVerifyPurposeLoginChange#527d22eb
     * verification:emailVerificationCode#922e55a9 code:string
     */
    private func buildVerifyEmailBytes(code: String): Array<Byte> {
        let s = TLSerializer()
        s.writeUInt32(0x032da4cf)
        s.writeUInt32(0x527d22eb)
        s.writeUInt32(0x922e55a9)
        s.writeString(code)
        return s.getBytes()
    }

    private func sendVerifyCode(): Unit {
        let email = this.newEmail
        if (email.isEmpty()) {
            spawn(UIThread) {
                =>
                this.statusMessage = "Please enter an email address"
                this.isError = true
            }
            return
        }
        spawn(UIThread) {
            =>
            this.isSendingCode = true
            this.statusMessage = ""
            this.isError = false
        }
        let _ = spawn {
            var ok = false
            var errMsg = ""
            try {
                let client = getMTProtoClient()
                let reqBytes = this.buildSendVerifyEmailCodeBytes(email)
                let _resp = client.sendRequest(reqBytes)
                ok = true
                Hilog.info(0, "CjTelegram", "[LoginEmail] sendVerifyEmailCode ok for ${email}")
            } catch (e: Exception) {
                errMsg = "Failed to send verification code"
                Hilog.info(0, "CjTelegram", "[LoginEmail] sendVerifyEmailCode error: ${e}")
            }
            let success = ok
            let err = errMsg
            spawn(UIThread) {
                =>
                this.isSendingCode = false
                if (success) {
                    this.codeSent = true
                    this.statusMessage = "Verification code sent to ${email}"
                    this.isError = false
                } else {
                    this.statusMessage = err
                    this.isError = true
                }
            }
        }
    }

    private func submitVerifyCode(): Unit {
        let code = this.verifyCode
        if (code.isEmpty()) {
            spawn(UIThread) {
                =>
                this.statusMessage = "Please enter the verification code"
                this.isError = true
            }
            return
        }
        spawn(UIThread) {
            =>
            this.isVerifying = true
            this.statusMessage = ""
            this.isError = false
        }
        let _ = spawn {
            var ok = false
            var errMsg = ""
            try {
                let client = getMTProtoClient()
                let reqBytes = this.buildVerifyEmailBytes(code)
                let _resp = client.sendRequest(reqBytes)
                ok = true
                Hilog.info(0, "CjTelegram", "[LoginEmail] verifyEmail ok")
            } catch (e: Exception) {
                errMsg = "Verification failed. Please check your code."
                Hilog.info(0, "CjTelegram", "[LoginEmail] verifyEmail error: ${e}")
            }
            let success = ok
            let err = errMsg
            let newEmailAddr = this.newEmail
            spawn(UIThread) {
                =>
                this.isVerifying = false
                if (success) {
                    this.currentEmailPattern = this.maskEmail(newEmailAddr)
                    this.codeSent = false
                    this.isEditingEmail = false
                    this.newEmail = ""
                    this.verifyCode = ""
                    this.statusMessage = "Login email updated successfully"
                    this.isError = false
                } else {
                    this.statusMessage = err
                    this.isError = true
                }
            }
        }
    }

    private func maskEmail(email: String): String {
        let parts = email.split("@")
        if (parts.size < 2) { return email }
        let local = parts[0]
        let domain = parts[1]
        if (local.size <= 2) { return "**@${domain}" }
        return "${local[0..1]}***@${domain}"
    }

    public func build() {
        Column {
            Row {
                Text(trSource("Back"))
                    .fontSize(16)
                    .fontColor(0x317AFF)
                    .onClick({ _evt => routerPop() })
                Blank().layoutWeight(1)
                Text(trSource("Login Email"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                Blank().layoutWeight(1)
                Row { }.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            if (this.isLoading) {
                Column {
                    LoadingProgress().width(32).height(32)
                    Text(trSource("Loading..."))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 8)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                Scroll {
                    Column {
                        Text("LOGIN EMAIL")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .margin(left: 16, top: 16, bottom: 8)
                            .width(100.percent)

                        Column {
                            Row {
                                Text("Current Email")
                                    .fontSize(17)
                                    .fontColor(0x000000)
                                    .layoutWeight(1)
                                if (this.currentEmailPattern.isEmpty()) {
                                    Text("Not Set")
                                        .fontSize(15)
                                        .fontColor(0x8E8E93)
                                } else {
                                    Text(this.currentEmailPattern)
                                        .fontSize(15)
                                        .fontColor(0x8E8E93)
                                }
                            }
                            .width(100.percent)
                            .height(56)
                            .padding(left: 16, right: 16)

                            Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)

                            Row {
                                Text(if (this.currentEmailPattern.isEmpty()) { "Set Login Email" } else { "Change Login Email" })
                                    .fontSize(17)
                                    .fontColor(0x317AFF)
                                    .layoutWeight(1)
                            }
                            .width(100.percent)
                            .height(56)
                            .padding(left: 16, right: 16)
                            .onClick({ _evt =>
                                this.isEditingEmail = true
                                this.codeSent = false
                                this.newEmail = ""
                                this.verifyCode = ""
                                this.statusMessage = ""
                                this.isError = false
                            })
                        }
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16)

                        Text("An additional email address that can be used to log in to your account.")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .margin(left: 16, right: 16, top: 8)
                            .width(100.percent)

                        if (this.isEditingEmail) {
                            Text("CHANGE EMAIL")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(left: 16, top: 24, bottom: 8)
                                .width(100.percent)

                            Column {
                                Row {
                                    Text("New Email")
                                        .fontSize(17)
                                        .fontColor(0x000000)
                                        .width(110)
                                    TextInput(placeholder: "email@example.com", text: this.newEmail)
                                        .fontSize(17)
                                        .fontColor(0x000000)
                                        .layoutWeight(1)
                                        .backgroundColor(Color.Transparent)
                                        .onChange({ val: String =>
                                            this.newEmail = val
                                        })
                                }
                                .width(100.percent)
                                .height(56)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                            }
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(12)
                            .margin(left: 16, right: 16)

                            if (!this.codeSent) {
                                Row {
                                    if (this.isSendingCode) {
                                        LoadingProgress().width(20).height(20)
                                    } else {
                                        Text("Send Verification Code")
                                            .fontSize(17)
                                            .fontColor(0x317AFF)
                                            .layoutWeight(1)
                                            .textAlign(TextAlign.Center)
                                    }
                                }
                                .width(100.percent)
                                .height(56)
                                .padding(left: 16, right: 16)
                                .backgroundColor(0xFFFFFF)
                                .borderRadius(12)
                                .margin(left: 16, right: 16, top: 12)
                                .justifyContent(FlexAlign.Center)
                                .onClick({ _evt =>
                                    if (!this.isSendingCode) {
                                        this.sendVerifyCode()
                                    }
                                })
                            } else {
                                Text("VERIFICATION CODE")
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(left: 16, top: 16, bottom: 8)
                                    .width(100.percent)

                                Column {
                                    Row {
                                        Text(trSource("Code"))
                                            .fontSize(17)
                                            .fontColor(0x000000)
                                            .width(80)
                                        TextInput(placeholder: "Enter code", text: this.verifyCode)
                                            .fontSize(17)
                                            .fontColor(0x000000)
                                            .layoutWeight(1)
                                            .backgroundColor(Color.Transparent)
                                            .onChange({ val: String =>
                                                this.verifyCode = val
                                            })
                                    }
                                    .width(100.percent)
                                    .height(56)
                                    .padding(left: 16, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                }
                                .backgroundColor(0xFFFFFF)
                                .borderRadius(12)
                                .margin(left: 16, right: 16)

                                Row {
                                    if (this.isVerifying) {
                                        LoadingProgress().width(20).height(20)
                                    } else {
                                        Text("Confirm Email")
                                            .fontSize(17)
                                            .fontColor(0x317AFF)
                                            .layoutWeight(1)
                                            .textAlign(TextAlign.Center)
                                    }
                                }
                                .width(100.percent)
                                .height(56)
                                .padding(left: 16, right: 16)
                                .backgroundColor(0xFFFFFF)
                                .borderRadius(12)
                                .margin(left: 16, right: 16, top: 12)
                                .justifyContent(FlexAlign.Center)
                                .onClick({ _evt =>
                                    if (!this.isVerifying) {
                                        this.submitVerifyCode()
                                    }
                                })

                                Row {
                                    Text(trSource("Resend Code"))
                                        .fontSize(15)
                                        .fontColor(0x317AFF)
                                }
                                .width(100.percent)
                                .height(44)
                                .justifyContent(FlexAlign.Center)
                                .margin(top: 8)
                                .onClick({ _evt =>
                                    if (!this.isSendingCode) {
                                        this.sendVerifyCode()
                                    }
                                })
                            }

                            Row {
                                Text(trSource("Cancel"))
                                    .fontSize(17)
                                    .fontColor(0xFF3B30)
                                    .layoutWeight(1)
                                    .textAlign(TextAlign.Center)
                            }
                            .width(100.percent)
                            .height(56)
                            .padding(left: 16, right: 16)
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(12)
                            .margin(left: 16, right: 16, top: 12)
                            .onClick({ _evt =>
                                this.isEditingEmail = false
                                this.codeSent = false
                                this.newEmail = ""
                                this.verifyCode = ""
                                this.statusMessage = ""
                                this.isError = false
                            })
                        }

                        if (!this.statusMessage.isEmpty()) {
                            Text(this.statusMessage)
                                .fontSize(13)
                                .fontColor(if (this.isError) { 0xFF3B30 } else { 0x34C759 })
                                .margin(left: 16, right: 16, top: 12)
                                .width(100.percent)
                                .textAlign(TextAlign.Center)
                        }

                        Text(trSource("")).height(32)
                    }
                }
                .layoutWeight(1)
                .backgroundColor(0xF2F2F7)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
