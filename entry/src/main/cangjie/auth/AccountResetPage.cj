package ohos_app_cangjie_entry.auth

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.router.*
import std.time.*

/**
 * 账号重置等待页面 — P2-019
 *
 * iOS 对应: AuthorizationSequenceAwaitingAccountResetController +
 *           AuthorizationSequenceAwaitingAccountResetControllerNode
 *
 * 触发场景: 用户无 2FA 密码、无恢复邮箱 → 选择删除账号 →
 *           服务器返回 2FA_CONFIRM_WAIT_<N> → 进入 7 天保护期倒计时
 *
 * UI 要素:
 *   - 标题 "Reset Account Protected"
 *   - 说明文案 (含手机号)
 *   - 倒计时标签 "Protected until" + days/hours/minutes 值
 *   - Reset Now 按钮 (倒计时 > 0 时禁用，到期才启用)
 *   - Logout 按钮 (始终可用)
 *   - LimitExceeded UI: resetPassword 返回 failedWait 时的错误 UI
 *
 * @State 无 dangling:
 *   countdownSeconds(读+写), phoneNumber(读+写), isResetting(读+写),
 *   errorMessage(读+写), limitExceeded(读+写)
 */
@HybridComponentEntry
@Component
public class AccountResetPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 倒计时剩余秒数 (0 时允许 Reset Now)
    @State var countdownSeconds: Int32 = 0

    // 账号手机号 (从 route param 解析, 显示在说明文案中)
    @State var phoneNumber: String = ""

    // 重置中
    @State var isResetting: Bool = false

    // 错误信息 (resetPassword 失败)
    @State var errorMessage: String = ""

    // LimitExceeded UI: account.resetPassword 返回 failedWait
    @State var limitExceeded: Bool = false

    // 倒计时任务是否仍在运行
    private var timerRunning: Bool = false

    // 混合迁移：首次渲染守卫
    @State var loaded: Bool = false

    // 混合迁移 auth-flow：原 EntryView @Consume isLoggedIn/tdAuthState 无 provider →
    // 改写 app 级单例 getAuthViewModel()。重置/登出后 routerReplace("SplashPage") 回登录流。

    // 混合迁移：原 onReady param 接收（"<waitSeconds>:<phone>"）+ 原 aboutToAppear（启动倒计时）
    // 合并进 ensureLoaded 守卫，经根容器 .onAppear 触发，只跑一次
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true

        // route param 格式: "<waitSeconds>:<phone>"（经 takePending 取回）
        let rawParam = takePending("AccountResetPage")
        if (rawParam.size > 0 && rawParam != "{}") {
            let parts = rawParam.split(":")
            if (parts.size >= 1) {
                var sec: Int32 = 0
                for (ch in parts[0]) {
                    let c = UInt32(ch)
                    if (c >= 48 && c <= 57) {
                        sec = sec * 10 + Int32(c - 48)
                    }
                }
                this.countdownSeconds = sec
            }
            if (parts.size >= 2) {
                this.phoneNumber = parts[1]
            }
        }
        // fallback: 从 AuthViewModel 读取
        if (this.countdownSeconds <= 0) {
            let authVM = getAuthViewModel()
            this.countdownSeconds = authVM.accountResetWaitSeconds
        }

        this.timerRunning = true
        this.startCountdown()
    }

    // 混合迁移：原 aboutToDisappear override → cleanup()，经根容器 .onDisAppear 触发
    private func cleanup(): Unit {
        this.timerRunning = false
    }

    func build() {
        Column {
                Column {
                    // 锁图标
                    Text("\u{1F512}")
                        .fontSize(60)
                        .margin(top: 60, bottom: 24)

                    // 标题 (iOS: Login_ResetAccountProtected_Title)
                    Text("Reset Account Protected")
                        .fontSize(24)
                        .fontWeight(FontWeight.Bold)
                        .textAlign(TextAlign.Center)
                        .margin(bottom: 16)

                    // 说明文案 (iOS: Login_ResetAccountProtected_Text)
                    if (this.phoneNumber.size > 0) {
                        Text("You can reset your account and delete all its data, including messages, contacts, and Telegram Passport. Your phone number ${this.phoneNumber} can be re-registered after this.")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .padding(left: 24, right: 24)
                            .margin(bottom: 24)
                    } else {
                        Text("You can reset your account and delete all its data, including messages, contacts, and Telegram Passport.")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .padding(left: 24, right: 24)
                            .margin(bottom: 24)
                    }

                    // 倒计时区域 (iOS: timerTitleNode + timerValueNode)
                    if (!this.limitExceeded) {
                        Text("Account protected until")
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                            .margin(bottom: 4)

                        Text(this.timerDisplayText())
                            .fontSize(22)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(if (this.countdownSeconds > 0) { 0xFF9500 } else { 0x34C759 })
                            .margin(bottom: 24)
                    }

                    // LimitExceeded UI: failedWait 返回时显示
                    if (this.limitExceeded) {
                        Column {
                            Text("Too many reset attempts.")
                                .fontSize(15)
                                .fontColor(0xFF3B30)
                                .textAlign(TextAlign.Center)
                                .margin(bottom: 8)
                            Text("Please wait before trying again.")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .textAlign(TextAlign.Center)
                                .margin(bottom: 16)
                        }
                    }

                    // 错误信息
                    if (this.errorMessage.size > 0) {
                        Text(this.errorMessage)
                            .fontSize(13)
                            .fontColor(0xFF3B30)
                            .textAlign(TextAlign.Center)
                            .padding(left: 24, right: 24)
                            .margin(bottom: 12)
                    }

                    // Reset Now 按钮 (iOS: resetNode, 倒计时为 0 才 enabled)
                    if (this.isResetting) {
                        Column {
                            LoadingProgress()
                                .width(32)
                                .height(32)
                                .color(0xFF3B30)
                            Text("Resetting account...")
                                .fontSize(14)
                                .fontColor(0x999999)
                                .margin(top: 8)
                        }
                        .margin(bottom: 16)
                    } else {
                        Button("Reset Account Now")
                            .width(280)
                            .height(44)
                            .margin(bottom: 12)
                            .borderRadius(22)
                            .backgroundColor(if (this.countdownSeconds <= 0 && !this.limitExceeded) { 0xFF3B30 } else { 0xCCCCCC })
                            .fontColor(0xFFFFFF)
                            .fontSize(16)
                            .enabled(this.countdownSeconds <= 0 && !this.limitExceeded)
                            .onClick({ evt =>
                                this.showResetConfirmDialog()
                            })
                    }

                    // Logout 按钮 (iOS: logoutPressed — 始终可用)
                    Button(trSource("Logout"))
                        .width(280)
                        .height(44)
                        .borderRadius(22)
                        .backgroundColor(0xE5E5EA)
                        .fontColor(0x007AFF)
                        .fontSize(16)
                        .onClick({ evt =>
                            this.doLogout()
                        })
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0xFFFFFF)
                .alignItems(HorizontalAlign.Center)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFF)
            .onAppear({ => this.ensureLoaded() })
            .onDisAppear({ => this.cleanup() })
    }

    /**
     * 倒计时 text: days d + hours h + minutes m
     * 对应 iOS timerValueString(days:hours:minutes:)
     */
    private func timerDisplayText(): String {
        if (this.countdownSeconds <= 0) {
            return "Ready to reset"
        }
        let total = this.countdownSeconds
        let secondsPerMin: Int32 = 60
        let secondsPerHour: Int32 = 3600
        let secondsPerDay: Int32 = 86400
        let days = total / secondsPerDay
        let hourRem = total - days * secondsPerDay
        let hours = hourRem / secondsPerHour
        let minRem = hourRem - hours * secondsPerHour
        var minutes = minRem / secondsPerMin
        if (days == 0 && hours == 0 && minutes == 0 && total > 0) {
            minutes = 1
        }
        var result = ""
        if (days > 0) {
            result = result + "${days}d "
        }
        if (hours > 0 || days > 0) {
            result = result + "${hours}h "
        }
        result = result + "${minutes}m"
        return result
    }

    /**
     * 启动倒计时 (spawn 每秒递减 countdownSeconds)
     * 对应 iOS SwiftSignalKit.Timer(timeout:1.0 repeat:true)
     */
    private func startCountdown(): Unit {
        let _ = spawn {
            while (this.timerRunning && this.countdownSeconds > 0) {
                sleep(Duration.second)
                let current = this.countdownSeconds
                let next = if (current > 0) { current - 1 } else { Int32(0) }
                launch {
                    this.countdownSeconds = next
                }
            }
        }
    }

    /**
     * D4 修法: Reset Account Now 二次确认 alert（destructive，无标题）
     * 对齐 iOS AuthorizationSequenceController.swift:1083-1090 —
     *   textAlertController(title: nil, text: TwoStepAuth_ResetAccountConfirmation,
     *     actions: [Cancel(genericAction), Reset(destructiveAction)])
     * 只有点击红色 Reset 才调用 doResetAccount()；Cancel 无副作用，直接关闭弹窗。
     * 与工程内已跑通的直调模式一致（auth/SignUpPage.cj showTosDialog、
     * auth/CodeInputPage.cj handleAuthError）：AccountResetPage 属登录前 auth 流，
     * 不挂载 components/DialogHost.cj（只在 MainTabPage 根挂载），故不走
     * services/DialogService.cj 的 showAlert/showConfirm 转发，直接在
     * @Component 内同步调用 getUIContext().showAlertDialog，避免 DialogService
     * 在无 presenter 场景下静默丢弃请求。
     */
    private func showResetConfirmDialog(): Unit {
        getUIContext().showAlertDialog(
            AlertDialogParamWithButtons(
                message: "You will lose all your chats and messages, along with any media and files you've shared, if you proceed with resetting your account.",
                title: "",
                primaryButton: AlertDialogButtonOptions(
                    value: "Cancel",
                    action: {=>
                        Hilog.info(0, "CjTelegram", "[AccountResetPage] Reset confirmation cancelled")
                    }
                ),
                secondaryButton: AlertDialogButtonOptions(
                    value: "Reset",
                    fontColor: DIALOG_DESTRUCTIVE_COLOR,
                    action: {=>
                        Hilog.info(0, "CjTelegram", "[AccountResetPage] Reset confirmed by user")
                        this.doResetAccount()
                    }
                )
            )
        )
    }

    /**
     * Reset Now — 调用 account.resetPassword
     * iOS: reset?() → AuthorizationSequenceController.resetAccountProtection
     * 成功: state=Unauthorized → pop 回到手机号输入
     * failedWait: limitExceeded=true
     */
    private func doResetAccount(): Unit {
        this.isResetting = true
        this.errorMessage = ""
        this.limitExceeded = false
        spawn {
            try {
                let authService = getRealAuthService()
                let resp = authService.resetPassword()
                let lastErr = authService.getLastError()
                launch {
                    this.isResetting = false
                    if (resp.kind == "ok") {
                        Hilog.info(0, "CjTelegram", "[AccountResetPage] resetPassword ok — account will be deleted")
                        getAuthViewModel().isLoggedIn = false
                        getAuthViewModel().authState = AUTH_STATE_WAIT_PHONE
                        routerReplace("SplashPage", "{}")
                    } else if (resp.kind == "requestedWait") {
                        // 服务端给出新的 until_date (罕见，刷新倒计时)
                        this.countdownSeconds = resp.untilDate
                        this.errorMessage = "Please wait ${this.timerDisplayText()} before resetting."
                        Hilog.info(0, "CjTelegram", "[AccountResetPage] resetPassword requestedWait until=${resp.untilDate}")
                    } else if (resp.kind == "failedWait") {
                        // LimitExceeded UI
                        this.limitExceeded = true
                        this.countdownSeconds = resp.retryDate
                        Hilog.info(0, "CjTelegram", "[AccountResetPage] resetPassword failedWait retry=${resp.retryDate}")
                    } else {
                        if (lastErr.size > 0) {
                            this.errorMessage = lastErr
                        } else {
                            this.errorMessage = "Reset failed. Please try again."
                        }
                        Hilog.info(0, "CjTelegram", "[AccountResetPage] resetPassword failed: ${lastErr}")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AccountResetPage] resetPassword exception: ${e}")
                launch {
                    this.isResetting = false
                    this.errorMessage = "Reset failed: ${e}"
                }
            }
        }
    }

    /**
     * Logout — 调用 RealAuthService.logout() + pop 到登录流程
     * iOS: logout?() → AuthorizationSequenceController.logout
     */
    private func doLogout(): Unit {
        spawn {
            let authService = getRealAuthService()
            authService.logout()
            Hilog.info(0, "CjTelegram", "[AccountResetPage] Logged out")
        }
        getAuthViewModel().isLoggedIn = false
        getAuthViewModel().authState = AUTH_STATE_WAIT_PHONE
        routerReplace("SplashPage", "{}")
    }
}
