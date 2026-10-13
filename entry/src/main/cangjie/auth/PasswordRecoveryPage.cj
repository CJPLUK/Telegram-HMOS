package ohos_app_cangjie_entry.auth

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.router.*

/**
 * 2FA 密码恢复页面
 *
 * 流程：
 * 1. 从 PasswordInputPage 点击 "Forgot password?" 后，requestPasswordRecovery 已发送恢复码到邮箱
 * 2. 本页显示 email 脱敏模式（如 a***@b.com），用户输入收到的恢复码
 * 3. 调用 RealAuthService.recoverPassword(code)
 * 4. 成功 → isLoggedIn = true → 切换到 MainTabPage
 */
@HybridComponentEntry
@Component
public class PasswordRecoveryPage {
    @State var recoveryCode: String = ""
    @State var isLoading: Bool = false
    @State var errorMessage: String = ""
    @State var emailPattern: String = ""

    // 混合迁移：首次渲染守卫
    @State var loaded: Bool = false

    // 混合迁移 auth-flow：原 EntryView @Consume isLoggedIn/tdAuthState 无 provider →
    // 改写 app 级单例 getAuthViewModel()，登录成功本页 routerReplace("MainTabPage")。

    // 混合迁移：原 aboutToAppear 实逻辑（读恢复邮箱脱敏模式）→ ensureLoaded 守卫，经 .onAppear 触发
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.emailPattern = getRealAuthService().getRecoveryEmailPattern()
    }

    func build() {
        Column {
                Text("🔑")
                    .fontSize(60)
                    .margin(top: 60, bottom: 24)

                Text("Recover Password")
                    .fontSize(24)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 8)

                Text("We've sent a recovery code to your email.")
                    .fontSize(14)
                    .fontColor(0x999999)
                    .textAlign(TextAlign.Center)
                    .padding(left: 40, right: 40)
                    .margin(bottom: 8)

                if (this.emailPattern.size > 0) {
                    Text(this.emailPattern)
                        .fontSize(14)
                        .fontColor(0x317AFF)
                        .margin(bottom: 24)
                }

                if (this.errorMessage.size > 0) {
                    Text(this.errorMessage)
                        .fontSize(13)
                        .fontColor(0xFF3B30)
                        .margin(bottom: 16)
                        .padding(left: 24, right: 24)
                        .width(100.percent)
                        .textAlign(TextAlign.Center)
                }

                if (this.isLoading) {
                    Column {
                        LoadingProgress()
                            .width(32)
                            .height(32)
                            .color(0x317AFF)
                        Text("Verifying code...")
                            .fontSize(14)
                            .fontColor(0x999999)
                            .margin(top: 8)
                    }
                    .margin(top: 16)
                } else {
                    Column {
                        TextInput(placeholder: "Recovery code")
                            .fontSize(16)
                            .width(280)
                            .height(44)
                            .textAlign(TextAlign.Center)
                            .onChange({ value: String =>
                                this.recoveryCode = value
                                if (this.errorMessage.size > 0) {
                                    this.errorMessage = ""
                                }
                            })

                        Button("Recover")
                            .width(280)
                            .height(44)
                            .margin(top: 20)
                            .borderRadius(22)
                            .backgroundColor(if (this.recoveryCode.size > 0) { 0x317AFF } else { 0xCCCCCC })
                            .fontColor(0xFFFFFF)
                            .fontSize(16)
                            .enabled(this.recoveryCode.size > 0)
                            .onClick({ evt =>
                                this.submitRecoveryCode()
                            })
                    }
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFF)
            .alignItems(HorizontalAlign.Center)
            .onAppear({ => this.ensureLoaded() })
    }

    private func submitRecoveryCode() {
        if (this.recoveryCode.size == 0) { return }
        this.isLoading = true
        this.errorMessage = ""
        let codeCopy = this.recoveryCode
        spawn {
            try {
                let authService = getRealAuthService()
                authService.recoverPassword(codeCopy)
                let state = authService.getState()
                let lastErr = authService.getLastError()
                launch {
                    this.isLoading = false
                    match (state) {
                        case RealAuthState.Authorized =>
                            getAuthViewModel().isLoggedIn = true
                            getAuthViewModel().authState = AUTH_STATE_READY
                            routerReplace("MainTabPage", "{}")
                            Hilog.info(0, "CjTelegram", "[PasswordRecoveryPage] Recovery successful")
                        case _ =>
                            if (lastErr.size > 0) {
                                if (lastErr == "CODE_EMPTY") {
                                    this.errorMessage = "Please enter the recovery code"
                                } else {
                                    this.errorMessage = lastErr
                                    // ic_password_recovery_suggest_reset: 恢复码校验失败
                                    // （非"未填写"这种本地校验错误）时通知 PasswordInputPage
                                    // 点亮 Reset Account 出路，对齐源侧 recovery-failed 建议
                                    // 改走重置账号路径的语义。
                                    getAuthViewModel().passwordRecoverySuggestReset = true
                                }
                            } else {
                                this.errorMessage = "Recovery failed"
                                getAuthViewModel().passwordRecoverySuggestReset = true
                            }
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PasswordRecoveryPage] recoverPassword exception: ${e}")
                launch {
                    this.isLoading = false
                    this.errorMessage = "Recovery failed: ${e}"
                }
            }
        }
    }
}
