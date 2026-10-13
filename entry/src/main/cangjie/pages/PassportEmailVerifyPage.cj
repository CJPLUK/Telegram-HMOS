package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getPassportService,
    SentEmailCodeModel
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * PassportEmailVerifyPage — P2-284: Telegram Passport email address verification
 *
 * Flow:
 *   1. User enters email address -> taps "Send Code"
 *   2. Calls account.sendVerifyEmailCode -> receives code length hint
 *   3. User enters code (shown with length hint) -> taps "Confirm"
 *   4. Calls account.verifyEmail -> on success pops page
 *   5. Resend option available after code sent
 *
 * iOS reference: PassportEmailController.swift / SecureIdEmailController.swift
 * TL: AccountSendVerifyEmailCode + AccountVerifyEmail
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()
 */
@HybridComponentEntry
@Component
public class PassportEmailVerifyPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var email: String = ""
    @State var verifyCode: String = ""
    @State var isCodeSent: Bool = false
    @State var isSending: Bool = false
    @State var isConfirming: Bool = false
    @State var errorMessage: String = ""
    @State var codeLength: Int32 = 0

    private func sendCode(): Unit {
        let emailVal = this.email
        if (emailVal.size == 0) {
            this.errorMessage = "Please enter your email address"
            return
        }
        this.isSending = true
        this.errorMessage = ""
        let _ = spawn {
            let service = getPassportService()
            let sentOpt = service.sendVerifyEmailCode(emailVal)
            match (sentOpt) {
                case None =>
                    let errMsg = "Failed to send verification code"
                    launch {
                        this.isSending = false
                        this.errorMessage = errMsg
                    }
                case Some(sent) =>
                    let length = sent.length
                    launch {
                        this.isSending = false
                        this.isCodeSent = true
                        this.codeLength = length
                        this.errorMessage = ""
                    }
            }
        }
    }

    private func confirmCode(): Unit {
        let emailVal = this.email
        let code = this.verifyCode
        if (code.size == 0) {
            this.errorMessage = "Please enter the verification code"
            return
        }
        this.isConfirming = true
        this.errorMessage = ""
        let _ = spawn {
            let service = getPassportService()
            // signature: confirmVerifyEmail(email, code)
            let ok = service.confirmVerifyEmail(emailVal, code)
            launch {
                this.isConfirming = false
                if (ok) {
                    routerPop()
                } else {
                    this.errorMessage = "Invalid code — please try again"
                }
            }
        }
    }

    private func getCodeHint(): String {
        if (this.codeLength > 0) {
            return "Enter the ${this.codeLength}-digit code sent to ${this.email}"
        }
        return "Enter the code sent to ${this.email}"
    }

    private func getCodePlaceholder(): String {
        if (this.codeLength > 0) {
            return "${this.codeLength}-digit code"
        }
        return "Verification code"
    }

    @Builder
    func buildInputPhase() {
        Text("Enter your email address to verify it for Telegram Passport")
            .fontSize(14)
            .fontColor(0x8E8E93)
            .margin(top: 16, bottom: 12)

        TextInput(placeholder: "email@example.com", text: this.email)
            .fontSize(17)
            .onChange({ val =>
                this.email = val
            })
            .width(100.percent)
            .height(48)
            .padding(left: 12, right: 12)
            .backgroundColor(0xFFFFFF)
            .borderRadius(8)

        if (this.errorMessage.size > 0) {
            Text(this.errorMessage)
                .fontSize(14)
                .fontColor(0xE53935)
                .margin(top: 8)
        }

        Button(if (this.isSending) { "Sending..." } else { "Send Code" })
            .fontSize(17)
            .fontColor(0xFFFFFF)
            .backgroundColor(if (this.isSending) { 0xBBBBBB } else { 0x0088CC })
            .width(100.percent)
            .height(48)
            .borderRadius(8)
            .margin(top: 16)
            .enabled(!this.isSending)
            .onClick({ _ =>
                this.sendCode()
            })
    }

    @Builder
    func buildCodePhase() {
        Text(this.getCodeHint())
            .fontSize(14)
            .fontColor(0x8E8E93)
            .margin(top: 16, bottom: 12)

        TextInput(placeholder: this.getCodePlaceholder(), text: this.verifyCode)
            .fontSize(17)
            .onChange({ val =>
                this.verifyCode = val
            })
            .width(100.percent)
            .height(48)
            .padding(left: 12, right: 12)
            .backgroundColor(0xFFFFFF)
            .borderRadius(8)

        if (this.errorMessage.size > 0) {
            Text(this.errorMessage)
                .fontSize(14)
                .fontColor(0xE53935)
                .margin(top: 8)
        }

        Button(if (this.isConfirming) { "Confirming..." } else { "Confirm" })
            .fontSize(17)
            .fontColor(0xFFFFFF)
            .backgroundColor(if (this.isConfirming) { 0xBBBBBB } else { 0x0088CC })
            .width(100.percent)
            .height(48)
            .borderRadius(8)
            .margin(top: 16)
            .enabled(!this.isConfirming)
            .onClick({ _ =>
                this.confirmCode()
            })

        Text("Resend code")
            .fontSize(14)
            .fontColor(0x0088CC)
            .margin(top: 12)
            .onClick({ _ =>
                this.isCodeSent = false
                this.verifyCode = ""
                this.sendCode()
            })
    }

    public func build() {
        Column {
            Row {
                Text(trSource("Cancel"))
                    .fontSize(17)
                    .fontColor(0x0088CC)
                    .onClick({ _ =>
                        routerPop()
                    })
                Blank()
                Text(trSource("Email Address"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                Blank()
                Text(trSource(""))
                    .fontSize(17)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            Scroll() {
                Column {
                    if (!this.isCodeSent) {
                        this.buildInputPhase()
                    } else {
                        this.buildCodePhase()
                    }
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 32)
                .alignItems(HorizontalAlign.Start)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
    }
}
