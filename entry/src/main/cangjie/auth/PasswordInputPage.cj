package ohos_app_cangjie_entry.auth

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.core.services.getTelegramCore_AccountManagerService
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.signalAccountSwitched
import std.convert.*

/**
 * 2FA 密码输入页面
 *
 * Phase P4-1: auth.checkPassword + SRP 6a
 * P2-318f: 多账号添加流闭环 — addAccount 上下文传递与 completeAddAccount/cancelAddAccount 调用
 *
 * 流程（首次登录 / 正常路径）：
 * 1. CodeInputPage 验证码正确但返回 SESSION_PASSWORD_NEEDED
 * 2. 用户在此页面输入 2FA 密码
 * 3. 调用 RealAuthService.checkPassword()
 * 4. SRP 6a 计算 + auth.checkPassword API
 * 5. 成功 → isLoggedIn = true → 切换到 MainTabPage
 *
 * 流程（添加账号路径，addAccountContext 非空）：
 * 5. 成功 → completeAddAccount(newSlot, origSlot) → pop 回 Settings
 * 6. 用户返回/取消 → cancelAddAccount(newSlot, origSlot) → pop
 *
 * 回归安全：addAccountContext 为空时完全不调用 complete/cancelAddAccount，原路径字节级不变。
 */
@HybridComponentEntry
@Component
public class PasswordInputPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var password: String = ""
    @State var isLoading: Bool = false
    @State var errorMessage: String = ""
    @State var passwordHint: String = ""

    // test_failed 返修（D5b, diag-suite_auth_login-TC-0012）：对齐 iOS
    // AuthorizationSequencePasswordEntryControllerNode.swift:36-39/155-157 的
    // didForgotWithNoRecovery / suggestReset —— 控制 "Reset Account" 出路是否显示。
    @State var didForgotWithNoRecovery: Bool = false
    @State var suggestReset: Bool = false

    // 混合迁移：首次渲染守卫
    @State var loaded: Bool = false

    // 混合迁移 auth-flow：原 EntryView @Consume isLoggedIn/tdAuthState 无 provider →
    // 改写 app 级单例 getAuthViewModel()，登录成功本页 routerReplace("MainTabPage")。

    // P2-318f: addAccount 上下文，从 onReady 解析路由参数
    // 格式 "addaccount:<newSlot>:<origSlot>"，正常登录时为 ""
    @State var addAccountContext: String = ""

    // P2-318f: 解析后的槽号（addAccountContext 非空时有效）
    @State var addAccountNewSlot: Int32 = -1
    @State var addAccountOriginalSlot: Int32 = -1

    // 混合迁移：首次渲染时经 takePending 解析 addAccount 上下文参数
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let rawParam = takePending("PasswordInputPage")
        if (rawParam.size > 0 && rawParam.startsWith("addaccount:")) {
            this.addAccountContext = rawParam
            let (ns, os) = this.parseAddAccountParam(rawParam)
            this.addAccountNewSlot = ns
            this.addAccountOriginalSlot = os
            Hilog.info(0, "CjTelegram", "[PasswordInputPage] addAccount context detected: newSlot=${this.addAccountNewSlot} origSlot=${this.addAccountOriginalSlot}")
        }
    }

    // ic_password_recovery_suggest_reset: PasswordRecoveryPage 恢复失败/不可用时把
    // getAuthViewModel().passwordRecoverySuggestReset 置 true（生产者，见该文件
    // submitRecoveryCode() 失败分支）。本页经 routerPush("PasswordRecoveryPage") 送走用户、
    // 用户 routerPop() 回来时同一实例仍存活，`loaded` 守卫的 ensureLoaded() 不会重跑，
    // 故用不受该守卫约束、每次 .onAppear 都执行的独立同步点（对齐本文件 D6「生命周期
    // 按需通信」范式），一旦置真只升不降（避免恢复码错误之外的普通 onAppear 把它错误清空）。
    private func resyncSuggestReset(): Unit {
        if (getAuthViewModel().passwordRecoverySuggestReset) {
            this.suggestReset = true
        }
    }

    func build() {
        Column {
                // Lock icon
                // 资源保真修复：真实矢量图标（Item List/Icons/LockBubble.imageset 转 SVG）替代 emoji 字形
                Column {
                    Image(@r(app.media.set2_ic_lockbubble))
                        .width(60)
                        .height(60)
                        .fillColor(0x007AFF)
                }
                .width(100)
                .height(100)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .margin(top: 60, bottom: 24)

                Text(trSource("Two-Step Verification"))
                    .fontSize(24)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 8)

                Text("Your account is protected with an additional password.")
                    .fontSize(14)
                    .fontColor(0x999999)
                    .textAlign(TextAlign.Center)
                    .padding(left: 40, right: 40)
                    .margin(bottom: 8)

                // Password hint
                if (this.passwordHint.size > 0) {
                    Text("Hint: ${this.passwordHint}")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(bottom: 24)
                } else {
                    Blank().height(16)
                }

                // Error message
                if (this.errorMessage.size > 0) {
                    Text(this.errorMessage)
                        .fontSize(13)
                        .fontColor(0xFF3B30)
                        .margin(bottom: 16)
                        .padding(left: 24, right: 24)
                        .width(100.percent)
                        .textAlign(TextAlign.Center)
                }

                // Password input or loading
                if (this.isLoading) {
                    Column {
                        LoadingProgress()
                            .width(32)
                            .height(32)
                            .color(0x317AFF)
                        Text("Verifying password...")
                            .fontSize(14)
                            .fontColor(0x999999)
                            .margin(top: 8)
                        Text("This may take a moment")
                            .fontSize(12)
                            .fontColor(0xBBBBBB)
                            .margin(top: 4)
                    }
                    .margin(top: 16)
                } else {
                    Column {
                        TextInput(placeholder: trSource("Password"))
                            .fontSize(16)
                            .width(280)
                            .height(44)
                            .textAlign(TextAlign.Center)
                            .onChange({ value: String =>
                                this.password = value
                                if (this.errorMessage.size > 0) {
                                    this.errorMessage = ""
                                }
                            })

                        Button(trSource("Next"))
                            .width(280)
                            .height(44)
                            .margin(top: 20)
                            .borderRadius(22)
                            .backgroundColor(if (this.password.size > 0) { 0x317AFF } else { 0xCCCCCC })
                            .fontColor(0xFFFFFF)
                            .fontSize(16)
                            .enabled(this.password.size > 0)
                            .onClick({ evt =>
                                this.submitPassword()
                            })
                    }
                }

                // Forgot password — 触发密码恢复流程
                Column {
                    Button(trSource("Forgot password?"))
                        .fontSize(14)
                        .fontColor(0x317AFF)
                        .backgroundColor(Color.Transparent)
                        .margin(top: 30)
                        .onClick({ evt =>
                            this.startPasswordRecovery()
                        })

                    // test_failed 返修（D5b）：无恢复邮箱 / 建议重置时展示 Reset Account 出路
                    // 对齐 iOS resetNode（…PasswordEntryControllerNode.swift:91-93/207-211），
                    // 标题取源 key LoginPassword.ResetAccount = "Reset Account"，destructive 红色
                    if (this.didForgotWithNoRecovery || this.suggestReset) {
                        Button(trSource("Reset Account"))
                            .fontSize(14)
                            .fontColor(0xFF3B30)
                            .backgroundColor(Color.Transparent)
                            .margin(top: 10)
                            .onClick({ evt =>
                                this.confirmAndResetAccount()
                            })
                    }
                }

                // P2-318f: 添加账号流 — 取消按钮（仅 addAccount 上下文下显示）
                if (this.addAccountContext.size > 0) {
                    Button(trSource("Cancel"))
                        .width(280)
                        .height(44)
                        .margin(top: 12)
                        .borderRadius(22)
                        .backgroundColor(0xE5E5EA)
                        .fontColor(0xFF3B30)
                        .fontSize(16)
                        .onClick({ evt =>
                            this.cancelAddAccountFlow()
                        })
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFF)
            .alignItems(HorizontalAlign.Center)
            .onAppear({ =>
                this.ensureLoaded()
                this.resyncSuggestReset()
            })
    }

    // P2-318f: 解析 "addaccount:<newSlot>:<origSlot>" 参数
    // 返回 (newSlot, origSlot)，解析失败返回 (-1, -1)
    private func parseAddAccountParam(param: String): (Int32, Int32) {
        let parts = param.split(":")
        if (parts.size >= 3) {
            let newSlotStr = parts[1]
            let origSlotStr = parts[2]
            var newSlot: Int32 = -1
            var origSlot: Int32 = -1
            try {
                newSlot = Int32(Int64.parse(newSlotStr))
                origSlot = Int32(Int64.parse(origSlotStr))
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PasswordInputPage] parseAddAccountParam failed: ${e}")
            }
            return (newSlot, origSlot)
        }
        return (-1, -1)
    }

    // P2-318f: 取消添加账号流 — 调用 cancelAddAccount 恢复原 slot 并清除废 slot
    private func cancelAddAccountFlow(): Unit {
        let newSlot = this.addAccountNewSlot
        let origSlot = this.addAccountOriginalSlot
        if (newSlot >= 0 && origSlot >= 0) {
            Hilog.info(0, "CjTelegram", "[PasswordInputPage] cancelAddAccount: newSlot=${newSlot} origSlot=${origSlot}")
            let _ = spawn {
                let svc = getTelegramCore_AccountManagerService()
                svc.cancelAddAccount(newSlot, origSlot)
                Hilog.info(0, "CjTelegram", "[PasswordInputPage] cancelAddAccount complete: restored origSlot=${origSlot}")
            }
        }
        routerPop()
    }

    // P2-318f: 完成添加账号流 — 调用 completeAddAccount 恢复原 slot 活跃状态
    private func completeAddAccountFlow(): Unit {
        let newSlot = this.addAccountNewSlot
        let origSlot = this.addAccountOriginalSlot
        if (newSlot >= 0 && origSlot >= 0) {
            Hilog.info(0, "CjTelegram", "[PasswordInputPage] completeAddAccount: newSlot=${newSlot} origSlot=${origSlot}")
            let _ = spawn {
                let svc = getTelegramCore_AccountManagerService()
                svc.completeAddAccount(newSlot, origSlot)
                // S7-16: the added account is now current (iOS setCurrentId) — rebuild the root for it.
                let _ = getRealAuthService().tryRestoreLogin()
                Hilog.info(0, "CjTelegram", "[PasswordInputPage] completeAddAccount done: newSlot=${newSlot} is now current")
                launch {
                    signalAccountSwitched(false)
                    routerReplace("MainTabPage", "{}")
                }
            }
            return
        }
        routerPop()
        routerPop()
        routerPop()
    }

    private func startPasswordRecovery() {
        this.isLoading = true
        this.errorMessage = ""
        spawn {
            let authService = getRealAuthService()
            authService.setCallback(AuthViewModelCallback(viewModel: getAuthViewModel()))
            let ok = authService.requestPasswordRecovery()
            let errMsg = authService.getLastError()
            let emailPat = authService.getRecoveryEmailPattern()
            launch {
                this.isLoading = false
                if (ok && emailPat.size > 0) {
                    routerPush("PasswordRecoveryPage")
                } else if (errMsg == "PASSWORD_RECOVERY_NA") {
                    // test_failed 返修（D5b）：源侧在此弹无标题 alert（单 OK），
                    // 对齐 AuthorizationSequenceController.swift:991-992（TwoStepAuth_RecoveryUnavailable）
                    // 点 OK 后置 didForgotWithNoRecovery=true，点亮 Reset Account 出路
                    getUIContext().showAlertDialog(
                        AlertDialogParamWithConfirm(
                            message: "Since you haven't provided a recovery e-mail when setting up your password, your remaining options are either to remember your password or to reset your account.",
                            confirm: AlertDialogButtonOptions(
                                value: "OK",
                                action: {=>
                                    this.didForgotWithNoRecovery = true
                                    Hilog.info(0, "CjTelegram", "[PasswordInputPage] recovery unavailable — reset path unlocked")
                                }
                            )
                        )
                    )
                } else if (errMsg.size > 0) {
                    this.errorMessage = errMsg
                } else {
                    this.errorMessage = "Could not send recovery code"
                }
            }
        }
    }

    // test_failed 返修（D5b）：Reset Account 二次确认
    // 对齐 AuthorizationSequenceController.swift:996-1010 —— 无标题 alert，
    // 正文按 suggestReset 取 TwoStepAuth_RecoveryFailed / TwoStepAuth_RecoveryUnavailable，
    // Cancel（默认样式）+ 红色 Reset（Login_ResetAccountProtected_Reset = "Reset"）
    private func confirmAndResetAccount(): Unit {
        let confirmMessage = if (this.suggestReset) {
            "Your remaining options are either to remember your password or to reset your account."
        } else {
            "Since you haven't provided a recovery e-mail when setting up your password, your remaining options are either to remember your password or to reset your account."
        }
        let cancelBtn = AlertDialogButtonOptions(
            value: "Cancel",
            action: {=> ()}
        )
        let resetBtn = AlertDialogButtonOptions(
            value: "Reset",
            fontColor: 0xFF3B30,
            action: {=>
                this.performAccountReset()
            }
        )
        getUIContext().showAlertDialog(
            AlertDialogParamWithButtons(
                message: confirmMessage,
                primaryButton: cancelBtn,
                secondaryButton: resetBtn,
                autoCancel: true
            )
        )
    }

    // test_failed 返修（D5b）：发起账号重置（account.deleteAccount，不带密码）
    // 对齐源侧 performAccountReset（TelegramCore/Sources/Authorization.swift:1440 →
    // account.deleteAccount(flags:0, reason:"", password:nil)）与目标
    // RealAuthService.deleteAccount(reason, withPassword, password) 语义一致。
    // 成功且带 waitSeconds（2FA_CONFIRM_WAIT_X）→ 按修法 A 第 2 步的既有参数约定
    // "<waitSeconds>:<phone>" 跳 AccountResetPage；立即成功（无 2FA）→ 回登录流。
    private func performAccountReset(): Unit {
        this.isLoading = true
        this.errorMessage = ""
        let phone = getAuthViewModel().getFullPhoneNumber()
        spawn {
            let authService = getRealAuthService()
            authService.setCallback(AuthViewModelCallback(viewModel: getAuthViewModel()))
            let (ok, waitSec) = authService.deleteAccount("", false, "")
            let lastErr = authService.getLastError()
            launch {
                this.isLoading = false
                if (waitSec > 0) {
                    Hilog.info(0, "CjTelegram", "[PasswordInputPage] account reset requested — waitSec=${waitSec}")
                    routerPush("AccountResetPage", "${waitSec}:${phone}")
                } else if (ok) {
                    Hilog.info(0, "CjTelegram", "[PasswordInputPage] account reset succeeded immediately")
                    getAuthViewModel().isLoggedIn = false
                    getAuthViewModel().authState = AUTH_STATE_WAIT_PHONE
                    routerReplace("SplashPage", "{}")
                } else {
                    this.errorMessage = if (lastErr.size > 0) {
                        lastErr
                    } else {
                        "Could not reset account. Please try again."
                    }
                    Hilog.info(0, "CjTelegram", "[PasswordInputPage] account reset failed: ${lastErr}")
                }
            }
        }
    }

    private func submitPassword() {
        if (this.password.size == 0) {
            return
        }
        this.isLoading = true
        this.errorMessage = ""

        let passwordCopy = this.password
        // P2-318f: 捕获 addAccount 上下文供 spawn 闭包使用
        let capturedAddCtx = this.addAccountContext

        spawn {
            try {
                let authService = getRealAuthService()
                authService.checkPassword(passwordCopy)

                let state = authService.getState()
                let lastErr = authService.getLastError()
                launch {
                    match (state) {
                        case RealAuthState.Authorized =>
                            this.isLoading = false
                            if (capturedAddCtx.size > 0) {
                                // P2-318f: addAccount 路径 — completeAddAccount + pop 回 Settings
                                this.completeAddAccountFlow()
                                Hilog.info(0, "CjTelegram", "[PasswordInputPage] addAccount 2FA complete — new account added (addCtx='${capturedAddCtx}')")
                            } else {
                                // 正常首次登录路径 — 混合迁移：写单例 + routerReplace 进主 tab
                                getAuthViewModel().isLoggedIn = true
                                getAuthViewModel().authState = AUTH_STATE_READY
                                routerReplace("MainTabPage", "{}")
                                Hilog.info(0, "CjTelegram", "[PasswordInputPage] 2FA verification successful")
                            }
                        case _ =>
                            this.isLoading = false
                            if (lastErr.size > 0) {
                                if (lastErr == "PASSWORD_HASH_INVALID") {
                                    this.errorMessage = "Invalid password. Please try again."
                                } else if (lastErr == "SRP_ID_INVALID") {
                                    this.errorMessage = "Session expired. Please try again."
                                } else {
                                    this.errorMessage = lastErr
                                }
                            } else {
                                this.errorMessage = "Password verification failed"
                            }
                            Hilog.info(0, "CjTelegram", "[PasswordInputPage] 2FA failed: ${lastErr}")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PasswordInputPage] checkPassword exception: ${e}")
                launch {
                    this.isLoading = false
                    this.errorMessage = "Verification failed: ${e}"
                }
            }
        }
    }
}
