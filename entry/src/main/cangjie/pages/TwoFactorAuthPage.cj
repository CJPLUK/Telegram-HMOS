package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.components.{ItemListButtonRow, ItemListSeparator, OverlayStatusView}
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * TwoFactorAuthMode — access/manage 两态划分。
 *
 * 对位源侧 TwoStepVerificationUnlockController.swift:252-254
 * `enum TwoStepVerificationUnlockSettingsControllerMode { case access(intro:data:) / case manage(...) }`。
 * `Access`: 需先输入并校验现有密码（解锁闸），或展示未设密码时的引导行；`Manage`: 密码校验
 * 通过后展示管理动作（对位 :461 `replaceControllerImpl?(..., mode: .manage(...))` 原地换
 * 屏——本工程用同一页面内 `@State` 切换等价替代，不新建页/不 routerPush，语义同源）。
 * `Manage` 只在 `config == Set` 时可达（`checkPassword()` 成功回调唯一入口）。
 */
public enum TwoFactorAuthMode {
    | Access
    | Manage
}

/**
 * TwoFactorAccessConfig — access 侧的账号配置维度，对位源侧
 * `TwoStepVerificationAccessConfiguration`（`.notSet(pendingEmail:)` / `.set(...)`，
 * diag-suite_settings_privacy-TC-0140-round2.md §6.2）。与 `mode` 正交：`mode` 描述"是否已
 * 解锁进管理态"，`config` 描述"账号在服务端的密码/待确认邮箱状态"。
 * 由 `loadPasswordState()` 从 `getPasswordInfo()` 的 `hasPassword` / `emailUnconfirmedPattern`
 * 分类：`hasPassword==true` ⇒ `Set`；`hasPassword==false && emailUnconfirmedPattern.size>0`
 * ⇒ `NotSetPendingEmail`；否则 ⇒ `NotSet`。三态互斥、由服务端数据一次性判定，不是新增布尔。
 */
public enum TwoFactorAccessConfig {
    | NotSet
    | NotSetPendingEmail
    | Set
}

/**
 * SetupWizardKind — RC-3（TC-0142）遗留 5 态全屏模态向导的态机，对位源侧
 * `SetupTwoStepVerificationStateKind`（`SetupTwoStepVerificationControllerNode.swift:21-26`）。
 * 显式序号（见 `wizardKindOrder()`）同时用于换页方向判定
 * （diag-suite_settings_privacy-TC-0142.md §6.5，`rawValue` 更大 ⇒ 新内容右侧滑入）。
 */
public enum SetupWizardKind {
    | EnterPassword
    | ConfirmPassword
    | EnterHint
    | EnterEmail
    | ConfirmEmail
}

/**
 * SetupWizardMode — 向导的两条入口路径：`Create`（access 侧 "Set Additional Password"，
 * 对位源侧 `.createPassword`）/ `Update`（manage 侧 "Change Password"，对位源侧
 * `.updatePassword`）。`EnterEmail`/`ConfirmEmail` 两态也由 manage 侧 "Set|Change
 * Recovery E-Mail"/"Enter Code" 两行直接以 `Update` 模式跳入（跳过密码步骤，见
 * `openWizardRecoveryEmail()`/`openWizardConfirmEmailCode()`），因此 `wizardMode` 并非只
 * 表征"密码新建/更新"，还用于在 `EnterEmail` 态区分"整套 Create 流程的收尾邮箱步骤"
 * （TC-0142 §6.4，与密码/hint 一起提交）与"独立的恢复邮箱变更"（只提交邮箱本身）两种
 * 不同的提交语义——`Update` 模式下的 `EnterEmail` 恒指向后者。
 */
public enum SetupWizardMode {
    | Create
    | Update
}

/**
 * Two-Step Verification Settings Page (Phase P4-6)（混合工程迁移版）
 *
 * 使用真实 API：
 * - ensureLoaded (原 aboutToAppear): account.getPassword 获取当前 2FA 状态，分类出
 *   TwoFactorAccessConfig（NotSet / NotSetPendingEmail / Set，round2 §6.2）
 * - access 解锁闸(checkPassword): account.getPasswordSettings + 当前密码 SRP 校验
 * - 关闭密码(disablePassword): account.updatePasswordSettings + 当前密码 SRP 证明
 * - 确认待验证恢复邮箱(doConfirmRecoveryEmail): confirmPasswordEmail
 * - "Set Additional Password"/manage 三行里的向导动作(Change Password/Recovery
 *   E-Mail/Enter Code)：挂载点，向导本体归 auth_password_setup_flow(TC-0142)
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑（loadPasswordState）→ ensureLoaded() + .onAppear
 */
@HybridComponentEntry
@Component
public class TwoFactorAuthPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var config: TwoFactorAccessConfig = TwoFactorAccessConfig.NotSet
    @State var isLoading: Bool = true
    @State var isSaving: Bool = false
    @State var currentPassword: String = ""
    @State var statusMessage: String = ""
    @State var errorMessage: String = ""
    @State var serverHint: String = ""
    @State var emailUnconfirmedPattern: String = ""
    @State var resetUntilDate: Int32 = 0
    @State var confirmEmailCode: String = ""
    @State var isConfirmingEmail: Bool = false
    @State var loaded: Bool = false

    // RC-1 (TC-0140): access/manage 两态 + manage 屏所需的配置位。
    @State var mode: TwoFactorAuthMode = TwoFactorAuthMode.Access
    @State var isCheckingAccess: Bool = false
    @State var hasRecoveryEmail: Bool = false
    @State var hasSecureValues: Bool = false

    // RC-3 (TC-0142 reconstruct)：5 态向导独占全屏（打开后 host manage 不在树里）。
    // 对位源侧独立 SetupTwoStepVerificationController + .modalSheet；不再用
    // bindContentCover overlay 叠在 manage 上。
    @State var wizardVisible: Bool = false
    @State var wizardMode: SetupWizardMode = SetupWizardMode.Create
    @State var wizardState: SetupWizardKind = SetupWizardKind.EnterPassword
    @State var wizardActivity: Bool = false
    @State var wizardPassword: String = ""
    @State var wizardConfirmPassword: String = ""
    @State var wizardHint: String = ""
    @State var wizardEmail: String = ""
    @State var wizardEmailCode: String = ""
    @State var wizardErrorMessage: String = ""
    @State var wizardHadRecoveryEmail: Bool = false
    @State var wizardEmailPattern: String = ""
    // 换页方向判定（§6.5）：进入下一态前记录"来源态"的序号；-1 表示尚无来源态（首次
    // 出现），驱动 wizardContentTransition() 走淡入而非左右滑动。
    @State var wizardPrevOrder: Int64 = -1
    // 下滑 dismiss：对位源侧 .modalSheet 整层下滑关闭。SDK 无 PanGesture，复用
    // NotificationSoundSelectionPage 的 onTouch 阈值写法，挂在向导透明 nav 上。
    @State var wizardSwipeStartY: Float64 = 0.0
    @State var wizardSwipeTracking: Bool = false

    // Cached algo params from server
    private var algoG: Int32 = 0
    private var algoP: Array<Byte> = Array<Byte>(0, repeat: 0)
    private var algoSalt1: Array<Byte> = Array<Byte>(0, repeat: 0)
    private var algoSalt2: Array<Byte> = Array<Byte>(0, repeat: 0)
    private var hasExistingPassword: Bool = false
    private let accessPasswordInputId: String = "two_factor_access_password"

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadPasswordState()
    }

    private func loadPasswordState() {
        this.isLoading = true
        this.errorMessage = ""
        spawn {
            var errMsg = ""
            var hint = ""
            var hasPass = false
            var emailPattern = ""
            var g: Int32 = 0
            var p = Array<Byte>(0, repeat: 0)
            var salt1 = Array<Byte>(0, repeat: 0)
            var salt2 = Array<Byte>(0, repeat: 0)
            var hasRecovery = false
            var hasSecureVals = false
            try {
                let authService = getRealAuthService()
                let info = authService.getPasswordInfo()

                hasPass = info.hasPassword
                hint = info.hint
                emailPattern = info.emailUnconfirmedPattern
                g = info.algoG
                p = info.algoP
                salt1 = info.algoSalt1
                salt2 = info.algoSalt2
                hasRecovery = info.hasRecovery
                hasSecureVals = info.hasSecureValues

                Hilog.info(0, "CjTelegram", "[2FA-Settings] Loaded: hasPassword=${info.hasPassword}, hint='${info.hint}', emailPattern='${info.emailUnconfirmedPattern}'")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[2FA-Settings] Load error: ${e}")
                errMsg = "Failed to load 2FA status"
            }
            let finalHasPass = hasPass
            let finalG = g
            let finalP = p
            let finalSalt1 = salt1
            let finalSalt2 = salt2
            let finalHint = hint
            let finalEmailPattern = emailPattern
            let finalErrMsg = errMsg
            let finalHasRecovery = hasRecovery
            let finalHasSecureVals = hasSecureVals
            // RC-1 round2 §6.2: config 由服务端数据一次性分类，三态互斥——
            // hasPassword ⇒ Set；否则视 emailUnconfirmedPattern 是否非空分 NotSetPendingEmail/NotSet。
            let finalConfig = if (finalHasPass) {
                TwoFactorAccessConfig.Set
            } else if (finalEmailPattern.size > 0) {
                TwoFactorAccessConfig.NotSetPendingEmail
            } else {
                TwoFactorAccessConfig.NotSet
            }
            launch {
                this.hasExistingPassword = finalHasPass
                this.algoG = finalG
                this.algoP = finalP
                this.algoSalt1 = finalSalt1
                this.algoSalt2 = finalSalt2
                this.config = finalConfig
                this.serverHint = finalHint
                this.emailUnconfirmedPattern = finalEmailPattern
                this.isLoading = false
                this.errorMessage = finalErrMsg
                this.hasRecoveryEmail = finalHasRecovery
                this.hasSecureValues = finalHasSecureVals
                // RC-1: 每次(重)加载都恒回 Access——对位源侧 mode 初值恒为 .access。
                this.mode = TwoFactorAuthMode.Access
            }
        }
    }

    /**
     * RC-1 (TC-0140) access 屏解锁闸：校验现有密码，成功后进入 manage 屏。
     * 对位源侧 TwoStepVerificationUnlockController.swift:429-470 checkPassword —
     * :441 requestTwoStepVerifiationSettings(password:) 成功后 :461
     * replaceControllerImpl?(..., mode: .manage(...)) 原地换屏；本工程用同一页面内
     * this.mode = Manage 等价替代，不新建页/不 routerPush。
     *
     * 校验走已有的 SRP 通路：复用 RealAuthService.computeCurrentPasswordSRP（只读，
     * 不改该文件）+ account.getPasswordSettings#9cd4eaf9（与
     * RealAuthService.getPasswordSettings 同一 RPC，源侧同一处调用），在本页内联发起
     * 与解析——disablePassword 已在本文件内用同一内联 RPC 范式，这里不新增范式；也避免
     * 依赖 RealAuthService.getPasswordSettings 那个不重置
     * lastErrorCode/lastErrorMessage 的封装（跨调用会残留上一次错误，无法可靠区分
     * "本次成功"与"本次与上次同码失败"）。
     */
    private func checkPassword(): Unit {
        // 重入闸 + 空密码静默无响应（不报错、不转圈、不抖动）——对位源侧 :441-444。
        if (this.currentPassword.size == 0 || this.isCheckingAccess) {
            return
        }
        this.isCheckingAccess = true
        this.errorMessage = ""
        let curPass = this.currentPassword

        spawn {
            var ok = false
            var errMsg = ""
            try {
                let authService = getRealAuthService()
                let srp = authService.computeCurrentPasswordSRP(curPass)
                if (srp.srpA.size == 0) {
                    errMsg = "Session expired. Please go back and try again"
                } else {
                    let client = getMTProtoClient()
                    let req = AccountGetPasswordSettings()
                    req.password = srp
                    let responseData = client.sendRequest(req.toBytes())

                    if (responseData.size >= 4) {
                        let checkD = TLDeserializer(responseData)
                        let checkCtor = checkD.readUInt32()
                        if (checkCtor == 0x2144ca19) {
                            let errorCode = checkD.readInt32()
                            let errorMsg = checkD.readString()
                            Hilog.info(0, "CjTelegram", "[2FA-Settings] checkPassword RPC Error: ${errorCode} ${errorMsg}")
                            errMsg = errorMsg
                        } else {
                            ok = true
                            Hilog.info(0, "CjTelegram", "[2FA-Settings] checkPassword verified")
                        }
                    } else {
                        errMsg = "Unexpected server response"
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[2FA-Settings] checkPassword error: ${e}")
                errMsg = "Failed to verify password: ${e}"
            }
            let finalOk = ok
            let finalErrMsg = errMsg
            launch {
                this.isCheckingAccess = false
                if (finalOk) {
                    this.mode = TwoFactorAuthMode.Manage
                } else {
                    // 失败：单按钮 OK alert（对位源侧 textAlertController + OK），
                    // 不写 errorMessage，不清空 this.currentPassword。
                    var alertMsg = "An error occurred, please try again later."
                    if (finalErrMsg == "PASSWORD_HASH_INVALID") {
                        alertMsg = "Invalid password. Please try again."
                    }
                    if (finalErrMsg.startsWith("FLOOD_WAIT")) {
                        alertMsg = "Limit exceeded. Please try again later."
                    }
                    getUIContext().showAlertDialog(AlertDialogParamWithConfirm(
                        message: alertMsg,
                        confirm: AlertDialogButtonOptions(value: "OK", action: {=> ()})
                    ))
                }
            }
        }
    }

    private func disablePassword() {
        if (this.currentPassword.size == 0) {
            // manage 屏没有单独的"当前密码"输入框——密码已在 access 屏校验并保留在
            // this.currentPassword 里（对位源侧 case .manage(password:...) 把已验证密码
            // 带入管理态）。为空说明状态不一致，保守退回 access 屏重新校验。
            this.mode = TwoFactorAuthMode.Access
            return
        }
        this.isSaving = true
        this.errorMessage = ""
        this.statusMessage = "Verifying current password..."

        let curPass = this.currentPassword

        spawn {
            var statusMsg = ""
            var errMsg = ""
            var saving = true
            var hasPass = false
            var clearCurrent = false
            try {
                let authService = getRealAuthService()
                let client = getMTProtoClient()

                let req = AccountUpdatePasswordSettings()
                req.hasCurrentPassword = true
                req.currentPasswordSRP = authService.computeCurrentPasswordSRP(curPass)

                req.setNewPassword = true
                req.algoSalt1 = this.algoSalt1
                req.algoSalt2 = this.algoSalt2
                req.algoG = this.algoG
                req.algoP = this.algoP
                req.newPasswordHash = Array<Byte>(0, repeat: 0)
                req.hint = ""

                let responseData = client.sendRequest(req.toBytes())

                if (responseData.size >= 4) {
                    let checkD = TLDeserializer(responseData)
                    let checkCtor = checkD.readUInt32()
                    if (checkCtor == 0x2144ca19) {
                        let errorCode = checkD.readInt32()
                        let errorMsg = checkD.readString()
                        Hilog.info(0, "CjTelegram", "[2FA-Settings] Disable RPC Error: ${errorCode} ${errorMsg}")
                        saving = false
                        statusMsg = ""
                        errMsg = this.formatError(errorMsg)
                    } else {
                        saving = false
                        statusMsg = "Password disabled successfully"
                        hasPass = false
                        clearCurrent = true
                        Hilog.info(0, "CjTelegram", "[2FA-Settings] Password disabled")
                    }
                } else {
                    saving = false
                    errMsg = "Unexpected server response"
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[2FA-Settings] Disable error: ${e}")
                saving = false
                statusMsg = ""
                errMsg = "Failed to disable: ${e}"
            }
            let finalSaving = saving
            let finalStatusMsg = statusMsg
            let finalErrMsg = errMsg
            let finalHasPass = hasPass
            let finalClearCurrent = clearCurrent
            launch {
                this.isSaving = finalSaving
                this.statusMessage = finalStatusMsg
                this.errorMessage = finalErrMsg
                // R-4 (round2 §6.1): 只在成功分支（finalClearCurrent==true）写回
                // config/hasExistingPassword，对位源侧 :711-716——失败只复位 checking，
                // 不改数据；失败时屏幕必须停在 manage 屏，账号状态保持不变。
                if (finalClearCurrent) {
                    this.hasExistingPassword = finalHasPass
                    this.config = TwoFactorAccessConfig.NotSet
                    this.currentPassword = ""
                    // §6.4: 关闭成功后整屏立即关闭回上一屏（routerPop 同帧执行），
                    // 因此 config=NotSet 这次写回不会先渲染出"未设置"表单态再跳走——
                    // 与源侧 :722 该回写被注释（digest D9）效果等价：用户不可见任何中间态。
                    routerPop()
                }
            }
        }
    }

    private func formatError(rpcError: String): String {
        if (rpcError == "PASSWORD_HASH_INVALID") { return "Current password is incorrect" }
        if (rpcError == "EMAIL_UNCONFIRMED") { return "Please confirm your recovery email first" }
        if (rpcError == "SRP_ID_INVALID") { return "Session expired. Please go back and try again" }
        if (rpcError == "NEW_SALT_INVALID") { return "Server rejected the password. Please try again" }
        if (rpcError == "NEW_SETTINGS_INVALID") { return "Invalid settings. Please try again" }
        if (rpcError == "CODE_INVALID") { return "Invalid verification code" }
        if (rpcError == "EMAIL_HASH_EXPIRED") { return "Verification expired. Please request a new code" }
        if (rpcError == "PASSWORD_EMPTY") { return "Password cannot be empty" }
        if (rpcError == "RESET_REQUEST_MISSING") { return "No password reset in progress" }
        if (rpcError.startsWith("FLOOD_WAIT")) { return "Too many attempts. Please try again later" }
        return rpcError
    }

    private func doConfirmRecoveryEmail() {
        if (this.confirmEmailCode.size == 0) {
            this.errorMessage = "Enter the code from your email"
            return
        }
        this.isConfirmingEmail = true
        this.errorMessage = ""
        let code = this.confirmEmailCode
        spawn {
            let authService = getRealAuthService()
            let ok = authService.confirmPasswordEmail(code)
            let lastErr = authService.getLastError()
            let finalOk = ok
            launch {
                this.isConfirmingEmail = false
                if (finalOk) {
                    this.confirmEmailCode = ""
                    this.emailUnconfirmedPattern = ""
                    this.loadPasswordState()
                } else {
                    this.errorMessage = if (lastErr.size > 0) { this.formatError(lastErr) } else { "Invalid code" }
                }
            }
        }
    }

    private func doRequestPasswordReset() {
        spawn {
            let authService = getRealAuthService()
            let resp = authService.resetPassword()
            let kind = resp.kind
            let untilDate = resp.untilDate
            let retryDate = resp.retryDate
            launch {
                if (kind == "ok") {
                    this.hasExistingPassword = false
                    this.config = TwoFactorAccessConfig.NotSet
                    this.loadPasswordState()
                } else if (kind == "requestedWait") {
                    this.resetUntilDate = untilDate
                    this.loadPasswordState()
                } else if (kind == "failedWait") {
                    this.errorMessage = "Please wait before requesting reset again"
                }
            }
        }
    }

    private func doDeclinePasswordReset() {
        spawn {
            let authService = getRealAuthService()
            let ok = authService.declinePasswordReset()
            launch {
                if (ok) {
                    this.resetUntilDate = 0
                    this.loadPasswordState()
                }
            }
        }
    }

    public func build() {
        // TC-0142 reconstruct：向导打开时独占整页（manage 不在树里），对位源侧
        // 独立 .modalSheet controller。禁止再用 bindContentCover 叠在 host 上。
        // OverlayStatusView 挂在本页根 Stack：本页是独立 NavDestination，MainTab
        // 上的宿主叠在下面看不见；改密成功浮层必须在本页树里消费 OverlayStatusService。
        Stack {
            if (this.wizardVisible) {
                this.buildSetupWizardFullscreen()
            } else {
                this.buildTwoStepHost()
            }
            OverlayStatusView()
        }
        .width(100.percent)
        .height(100.percent)
    }

    @Builder
    func buildTwoStepHost() {
        Column {
            // Header
            Row {
                // diag round3 §6.1-a (S3/E5): 页级 header 四态共用的返回控件此前是裸字形
                // Text("←")，源侧 :966 ItemListBackButton(title: Common_Back) 声明的是带
                // "Back" 文案的返回项。改为与兄弟屏 PrivacySettingsPage.cj:427-429 逐项同形
                // 的 Text(trSource("Back"))，右侧配平占位同步从 40 改 60（同一兄弟屏 :434）。
                Text(trSource("Back"))
                    .fontSize(16)
                    .fontColor(0x317AFF)
                    .onClick({ evt => routerPop() })
                Blank().layoutWeight(1)
                Text(trSource("Two-Step Verification"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                Blank().layoutWeight(1)
                // TC-0140 c1_ui_comparison：access+已设密码时右槽是 nav trailing Next
                // （源侧 TwoStepVerificationUnlockController.swift:934-947），checking
                // 换成无文字转圈；manage / NotSet / pending-email / loading 仍宽 60 占位，
                // manage 不挂 Next。
                if (!this.isLoading && !this.isManageMode() && this.isConfigSet()) {
                    if (this.isCheckingAccess) {
                        LoadingProgress().width(20).height(20).color(0x007AFF)
                    } else {
                        Text(trSource("Next"))
                            .fontSize(17)
                            .fontColor(0x007AFF)
                            .onClick({ evt => this.checkPassword() })
                    }
                } else {
                    Row { }.width(60)
                }
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            if (this.isLoading) {
                // round2 §6.2: 无文字转圈空态，对位源侧 :951 ItemListLoadingIndicatorEmptyStateItem
                // （无文字）——目标自造的 "Loading 2FA status..." 文案已删除。
                Column {
                    LoadingProgress().width(32).height(32).color(0x007AFF)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0xF2F2F7)
            } else {
                Scroll {
                    Column {
                        // Error / Status messages
                        if (this.errorMessage.size > 0) {
                            Text(this.errorMessage)
                                .fontSize(14)
                                .fontColor(0xFF3B30)
                                .margin(left: 16, top: 16, right: 16, bottom: 8)
                                .width(100.percent)
                        }
                        if (this.statusMessage.size > 0) {
                            Text(this.statusMessage)
                                .fontSize(14)
                                .fontColor(0x007AFF)
                                .margin(left: 16, top: 16, right: 16, bottom: 8)
                                .width(100.percent)
                        }

                        if (this.isSaving) {
                            Column {
                                LoadingProgress().width(32).height(32).color(0x007AFF)
                                Text(this.statusMessage)
                                    .fontSize(14).fontColor(0x999999).margin(top: 8)
                            }
                            .width(100.percent)
                            .padding(top: 32, bottom: 32)
                            .alignItems(HorizontalAlign.Center)
                        } else if (this.isManageMode()) {
                            // RC-1 (TC-0140): access/manage 两态划分。mode 只能由 checkPassword()
                            // 成功回调置 Manage（唯一入口），因此 isManageMode() 分派点独立于
                            // config 直接放在顶层判断——对位 round2 §6.2 "isManageMode() 分派点
                            // 保留复用"。三行里"Change Password"/"Set|Change Recovery E-Mail"
                            // 通往的 5 态向导本体不在本 feature 范围内(auth_password_setup_flow /
                            // TC-0142，边界为源侧 SetupTwoStepVerificationController(...) 构造点)。
                            this.buildTwoStepManageRows()
                        } else if (this.isConfigSet()) {
                            // Access 侧按 config 三态分派，对位源侧 :195-249 switch configuration
                            // （round2 §6.2：删除 isEnabled 单布尔特判，改配置驱动）。S-136:
                            // build() 内不能直接用 match 产出 UI（"Only UI component syntax can
                            // be written in build method"），改用 if/else-if + 判别谓词函数，
                            // 与既有 isManageMode() 同一范式。
                            this.buildTwoStepAccessGate()
                        } else if (this.isConfigNotSetPendingEmail()) {
                            this.buildTwoStepNotSetPendingEmailGate()
                        } else {
                            this.buildTwoStepNotSetGate()
                        }
                    }
                }
                // diag round3 §6.1-b (S4-1): Scroll 未覆盖 SDK 默认 Alignment.Center，
                // 内容短于视口时垂直居中；源侧 ItemListController 表视图恒顶部对齐，显式
                // 覆盖为 Alignment.Top 还原（common.cj.d:13183 默认值声明）。
                .align(Alignment.Top)
                .layoutWeight(1)
                .backgroundColor(0xF2F2F7)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
        /*
        // 旧 overlay-on-manage 呈现（历史留痕）。运行时 bindContentCover 叠在
        // NavDestination 上，host manage 三行仍在树、向导 nav Cancel/Next 不出现。
        // TC-0142 reconstruct 改为 build() 内独占全屏 buildSetupWizardFullscreen()。
        .bindContentCover(
            this.wizardVisible,
            this.setupWizardCover,
            options: ContentCoverOptions(
                modalTransition: ModalTransition.Default,
                backgroundColor: 0xFFFFFF
            )
        )
        */
    }

    // R-112: enum 不自动派生 ==，用 match 判别而不是比较运算符。
    private func isManageMode(): Bool {
        match (this.mode) {
            case TwoFactorAuthMode.Manage => true
            case TwoFactorAuthMode.Access => false
        }
    }

    // round2 §6.2: config 三态判别谓词，供 build() 走 if/else-if 分派（build() 内不能
    // 直接用 match 产出 UI，见 buildTwoStepAccessGate 调用点旁的编译约束记录）。
    private func isConfigSet(): Bool {
        match (this.config) {
            case TwoFactorAccessConfig.Set => true
            case _ => false
        }
    }

    private func isConfigNotSetPendingEmail(): Bool {
        match (this.config) {
            case TwoFactorAccessConfig.NotSetPendingEmail => true
            case _ => false
        }
    }

    /**
     * RC-1 access 屏：密码输入 + 页级 header Next（本 Builder 不再画 body CTA）+
     * 脚注 Hint? / EnterPasswordHelp / Forgot password?。对位源侧 :195-249 access
     * 分支的密码输入行 + :215-234 passwordEntryInfo + :940-963 右上 Next。
     */
    @Builder
    func buildTwoStepAccessGate() {
        // diag round3 §6.1-c 附注：本文件内同一 D-165 形态（width(100%) + 水平 margin），
        // 一并按同一形状改为 padding 承载。
        Text(trSource("PASSWORD"))
            .fontSize(13).fontColor(0x8E8E93)
            .margin(top: 16, bottom: 8).padding(left: 16).width(100.percent)

        // diag round3 §6.1-d (静态残余，white-box)：access 闸密码框仍未遮蔽。报告建议的
        // `.type(InputType.Password)` 与本工程 S-128（syntax_error.md）已确认的 SDK 能力
        // 缺口冲突——当前 ArkUI-CJ SDK 绑定的 TextInput 无 `type`/InputType 成员，编译报
        // "'type' is not a member of class 'TextInput'"（S-128 已用编译 + 两条绕行方案的
        // 设备级失败反复验证，不是查漏）。改用本工程已落地的等价遮罩技法（先例
        // `pages/ProxySettingsPage.cj:1004-1022,1090-1100`）：Stack 内先绘制遮罩 Text（按
        // 已输入密码长度生成等长 "•" 串），后绘制一个内容透明、光标可见的 TextInput 接管
        // 点击/光标/输入，达到与 InputType.Password 相同的视觉遮蔽效果。
        Column {
            Stack(alignContent: Alignment.Start) {
                if (!this.currentPassword.isEmpty()) {
                    Text(this.maskedPasswordDisplay())
                        .fontSize(17)
                        .fontColor(0x000000)
                }
                TextInput(text: this.currentPassword, placeholder: trSource("Enter your password"))
                    .id(this.accessPasswordInputId)
                    .fontColor(Color.Transparent)
                    .caretColor(0x000000)
                    .backgroundColor(Color.Transparent)
                    .onChange({ value: String =>
                        this.currentPassword = value
                        this.errorMessage = ""
                    })
            }
            .width(100.percent).height(44)
        }
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFF).borderRadius(12)
        .margin(left: 16, right: 16)
        .onAppear({ => FocusControl.requestFocus(this.accessPasswordInputId) })

        Column {
            if (this.serverHint.size > 0) {
                Text("Hint: ${this.serverHint}")
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .textAlign(TextAlign.Start)
                    .width(100.percent)
            }
            Text(trSource("You have enabled Two-Step Verification, so your account is protected with an additional password."))
                .fontSize(13)
                .fontColor(0x8E8E93)
                .textAlign(TextAlign.Start)
                .width(100.percent)
            Text(trSource("Forgot password?"))
                .fontSize(14).fontColor(0x007AFF)
                .margin(top: 16)
                .onClick({ evt => this.doRequestPasswordReset() })

            if (this.resetUntilDate > 0) {
                Column {
                    Text("Password reset requested. You can cancel it now.")
                        .fontSize(13).fontColor(0x8E8E93)
                    Button("Cancel reset")
                        .fontSize(14).fontColor(0x007AFF)
                        .backgroundColor(Color.Transparent)
                        .margin(top: 8)
                        .onClick({ evt => this.doDeclinePasswordReset() })
                }
                .width(100.percent)
                .padding(16)
                .backgroundColor(0xFFF3E0)
                .borderRadius(12)
                .margin(top: 16)
            }
        }
        .padding(left: 16, right: 16, top: 24, bottom: 32)
        .width(100.percent)
    }

    /**
     * round2 §6.2 (Access, NotSet)：账号未设密码、也没有待确认的恢复邮箱残留。对位源侧
     * :210-211 `.passwordSetup(TwoStepAuth_SetPassword)` + `.passwordSetupInfo(TwoStepAuth_SetPasswordHelp)`。
     * 文案取自 Localizable.strings:1369-1370（逐字核对）。
     *
     * 行的落点是源侧 :614 `SetupTwoStepVerificationController(context:initialState:.createPassword,...)`
     * ——遗留 5 态向导本体，归 auth_password_setup_flow（TC-0142）。与 manage 屏三行同一边界
     * 原则（round2 附录 A.5.3）：本轮只建立行本身 + 点击回调挂载点，不写向导；行的存在与
     * 文案本身就是 A8/C1 判据，不是留空功能。
     */
    @Builder
    func buildTwoStepNotSetGate() {
        Column {
            ItemListButtonRow(
                title: "Set Additional Password",
                onClick: { => this.onAccessSetupPasswordTap() },
                centered: false
            )
        }
        .backgroundColor(0xFFFFFF).borderRadius(12)
        .margin(left: 16, right: 16, top: 24)

        // diag round3 §6.1-c (S4-2, D-165): width(100%) + 对称水平 margin(16/16) 在默认
        // 居中 Column 下摞出溢出盒，可见左缘塌到 0 导致两端贴边、右端末字形被裁。水平留白
        // 改用 padding（盒内计入，不产生溢出盒），纵向量继续留在 margin。
        Text(trSource("You can set a password that will be required when you log in on a new device in addition to the code you get in the SMS."))
            .fontSize(13).fontColor(0x8E8E93)
            .margin(top: 8, bottom: 32)
            .padding(left: 16, right: 16)
            .width(100.percent)
    }

    /**
     * round2 §6.2 (Access, NotSetPendingEmail)：账号未设密码，但有一个上次未完成设置遗留的
     * 待确认恢复邮箱（服务端 `account.password.email_unconfirmed_pattern` 在 hasPassword=false
     * 时同样可非空——与 manage 侧 R-2 的 pendingEmail 是同一字段的两种账号态，互斥不重叠）。
     * 对位源侧 :202-206 `.notSet(pendingEmail: some)` 分支：
     *   ① `.pendingEmailConfirmInfo` 文案 = `TwoStepAuth.SetupPendingEmail`
     *      （Localizable.strings:3856，逐字核对）；
     *   ② `.pendingEmailConfirmCode`：title 空串、placeholder = `TwoStepAuth.RecoveryCode`
     *      （strings:1417 "Code"）——源侧本行靠输入长度触发自动校验，本工程复用已有的
     *      `doConfirmRecoveryEmail()`（真实 `confirmPasswordEmail` RPC，同一账号级能力，
     *      不新增 RealAuthService 表面）改为显式按钮提交；
     *   ③ `.pendingEmailInfo` = `[TwoStepAuth.ConfirmationAbort]()` 链接，源侧点击调用
     *      :768 `openResetPendingEmail` → `account.engine.auth.updateTwoStepVerificationPassword
     *      (currentPassword: nil, updatedPassword: .none)`——该 RPC 未在 RealAuthService.cj
     *      暴露，且改该文件是 round2 §6.0 约束 3 明令禁止项；因此本行同manage三行一样只建立
     *      挂载点，不臆造本地重置逻辑。
     * 不得渲染源侧 :208 那行被注释掉的 `ConfirmationText`（恒不上屏，digest D8）。
     */
    @Builder
    func buildTwoStepNotSetPendingEmailGate() {
        // diag round3 §6.1-c 附注：同一 D-165 形态，改为 padding 承载。
        Text("Your recovery email ${this.emailUnconfirmedPattern} needs to be confirmed and is not yet active.\n\nPlease check your email and enter the confirmation code to complete Two-Step Verification setup. Be sure to check the spam folder as well.")
            .fontSize(14).fontColor(0x000000)
            .margin(top: 16, bottom: 8)
            .padding(left: 16, right: 16)
            .width(100.percent)

        Column {
            TextInput(text: this.confirmEmailCode, placeholder: trSource("Code"))
                .width(100.percent).height(44)
                .backgroundColor(Color.Transparent)
                .onChange({ value: String => this.confirmEmailCode = value })
        }
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFF).borderRadius(12)
        .margin(left: 16, right: 16, top: 8)

        Button(if (this.isConfirmingEmail) { "Confirming..." } else { "Confirm Email" })
            .width(100.percent).height(48)
            .fontSize(16).fontColor(0xFFFFFF)
            .backgroundColor(0x007AFF).borderRadius(12)
            .margin(left: 16, right: 16, top: 12)
            .enabled(!this.isConfirmingEmail && this.confirmEmailCode.size > 0)
            .onClick({ evt => this.doConfirmRecoveryEmail() })

        Column {
            ItemListButtonRow(
                title: "Abort Two-Step Verification Setup",
                onClick: { => this.onAccessAbortPendingEmailTap() },
                destructive: true,
                centered: false
            )
        }
        .backgroundColor(0xFFFFFF).borderRadius(12)
        .margin(left: 16, right: 16, top: 16, bottom: 32)
    }

    /**
     * RC-1 manage 屏三行(§6.4)：Change Password / Turn Password Off /
     * Set|Change Recovery E-Mail。前两行只在源侧 access 屏没有(:214 passwordEntry 只在
     * .access 分支 append)，manage 分支不含密码输入框/Forgot password?，对位本组一致。
     */
    @Builder
    func buildTwoStepManageRows() {
        Column {
            ItemListButtonRow(
                title: "Change Password",
                onClick: { => this.onManageChangePasswordTap() },
                centered: false
            )
            ItemListSeparator()
            ItemListButtonRow(
                // R-1 (round2 §6.1): 源侧 TwoStepAuth.RemovePassword (Localizable.strings:1377)
                // = "Turn Password Off"，此前误写成了弹窗标题 "Turn Off Two-Step Verification"。
                title: "Turn Password Off",
                onClick: { => this.onManageTurnOffTap() },
                destructive: true,
                centered: false
            )
            ItemListSeparator()
            ItemListButtonRow(
                title: if (this.hasRecoveryEmail) { "Change Recovery E-Mail" } else { "Set Recovery E-Mail" },
                onClick: { => this.onManageRecoveryEmailTap() },
                centered: false
            )
            // R-2 (round2 §6.1): 第四行二选一，对位源侧 :237-246——有 pendingEmail 时是
            // "We have sent..." 提示 + "Enter Code" 行；否则是 GenericHelp 脚注（见下）。
            if (this.emailUnconfirmedPattern.size > 0) {
                ItemListSeparator()
                ItemListButtonRow(
                    title: "Enter Code",
                    onClick: { => this.onManageEnterEmailCodeTap() },
                    centered: false
                )
            }
        }
        .backgroundColor(0xFFFFFF).borderRadius(12)
        .margin(left: 16, right: 16, top: 24)

        // diag round3 §6.1-c 附注：manage 侧脚注同一 D-165 形态，两分支一并改为 padding 承载。
        if (this.emailUnconfirmedPattern.size > 0) {
            Text(trSource("We have sent you an e-mail to confirm your address."))
                .fontSize(13).fontColor(0x8E8E93)
                .margin(top: 8, bottom: 32)
                .padding(left: 16, right: 16)
                .width(100.percent)
        } else {
            Text(trSource("You have enabled Two-Step verification.\nYou'll need the password you set up here to log in to your Telegram account."))
                .fontSize(13).fontColor(0x8E8E93)
                .margin(top: 8, bottom: 32)
                .padding(left: 16, right: 16)
                .width(100.percent)
        }
    }

    /**
     * RC-3 (TC-0142) §6.6 入口接线：源侧构造点 SetupTwoStepVerificationController
     * (mode: .updatePassword, ...) (TwoStepVerificationUnlockController.swift:647)。打开
     * 向导，初态 EnterPassword + Update——RC-1 落地后本条不再是挂载点，接回向导本体。
     */
    private func onManageChangePasswordTap(): Unit {
        this.openWizardChangePassword()
    }

    /**
     * RC-3 (TC-0142) §6.6 入口接线：源侧构造点 SetupTwoStepVerificationController
     * (mode: .addEmail, ...) (TwoStepVerificationUnlockController.swift:740)。打开向导，
     * 初态 EnterEmail + Update（跳过密码步骤——密码已在 access 屏校验，manage 屏本身没有
     * 独立密码框，见 buildTwoStepManageRows 文档）。
     */
    private func onManageRecoveryEmailTap(): Unit {
        this.openWizardRecoveryEmail()
    }

    /**
     * R-2 / RC-3 (TC-0142) §6.6 入口接线：源侧构造点 SetupTwoStepVerificationController
     * (mode: .confirmEmail, ...) (TwoStepVerificationUnlockController.swift:829)。打开
     * 向导，初态 ConfirmEmail + Update——manage 侧的 pendingEmail 确认走向导本体，不同于
     * access/NotSetPendingEmail 侧的本地 RPC 确认（见 buildTwoStepNotSetPendingEmailGate
     * 文档，二者边界互斥）。
     */
    private func onManageEnterEmailCodeTap(): Unit {
        this.openWizardConfirmEmailCode()
    }

    /**
     * round2 §6.2 (Access, NotSet) / RC-3 (TC-0142) §6.6 入口接线：源侧构造点
     * SetupTwoStepVerificationController(context:initialState:.createPassword,...)
     * (TwoStepVerificationUnlockController.swift:614)。打开向导，初态 EnterPassword +
     * Create。
     */
    private func onAccessSetupPasswordTap(): Unit {
        this.openWizardCreatePassword()
    }

    /**
     * round2 §6.2 (Access, NotSetPendingEmail) 挂载点："Abort Two-Step Verification Setup"。
     * 源侧 :768 openResetPendingEmail 调用 account.engine.auth.updateTwoStepVerificationPassword
     * (currentPassword: nil, updatedPassword: .none)——该 RPC 未在 RealAuthService.cj 暴露，
     * 且改该文件是 round2 §6.0 约束 3 明令禁止项，因此本行只建立挂载点，不臆造本地重置逻辑。
     */
    private func onAccessAbortPendingEmailTap(): Unit {
        Hilog.info(0, "CjTelegram", "[2FA-Settings] Access: Abort pending-email setup tapped (no local capability; RPC not exposed by RealAuthService)")
    }

    /**
     * Turn Off：源侧确认对话框主次故意反挂(Cancel 默认/粗体，Disable 普通)，不得"修正"
     * (§6.4)。确认后源侧既有缺陷行为——先弹成功浮层，再发网络请求——照现状复刻。
     * R-1 (round2 §6.1)：源侧 :684 该弹窗 `title: nil`，`Disable` 是普通 `.genericAction`
     * 无破坏性着色——此前目标自造了 title 与红色 `Disable`，均已删除。
     */
    private func onManageTurnOffTap(): Unit {
        if (this.isSaving) { return }
        let uiCtx = getUIContext()
        var message= "Are you sure you want to disable your password?"
        if (this.hasSecureValues) {
            message = message + "\n\nWarning! All data saved in your Telegram Passport will be lost!"
        }
        let cancelBtn = AlertDialogButtonOptions(style: DialogButtonStyle.Highlight, value: "Cancel", action: {=> ()})
        let confirmBtn = AlertDialogButtonOptions(
            value: "Disable",
            action: { =>
                showToast("Two-Step verification\nis disabled.")
                this.disablePassword()
            }
        )
        uiCtx.showAlertDialog(AlertDialogParamWithButtons(
            message: message,
            primaryButton: cancelBtn, secondaryButton: confirmBtn, autoCancel: true
        ))
    }

    /**
     * maskedPasswordDisplay — 按已输入密码的字符数生成等长遮罩串（• 字符）。
     * diag round3 §6.1-d：access 闸密码框遮蔽的承载技法，先例
     * `pages/ProxySettingsPage.cj:1090-1100`（同一 SDK 能力缺口 S-128 下的既有解法）。
     */
    private func maskedPasswordDisplay(): String {
        var result = ""
        var i: Int64 = 0
        let count = this.currentPassword.toRuneArray().size
        while (i < count) {
            result += "•"
            i += 1
        }
        return result
    }

    // ==================== RC-3 (TC-0142): 遗留 5 态向导 ====================
    // diag-suite_settings_privacy-TC-0142.md §6.1-6.6。全部落在本文件内，零扩权。

    // R-112: enum 无自动派生 ==，序号判定 + 判别谓词均走 match（普通函数体内合法，
    // S-136 只禁止 match 直接出现在 build()/@Builder 体内产出 UI）。
    private func wizardKindOrder(k: SetupWizardKind): Int64 {
        match (k) {
            case SetupWizardKind.EnterPassword => 0
            case SetupWizardKind.ConfirmPassword => 1
            case SetupWizardKind.EnterHint => 2
            case SetupWizardKind.EnterEmail => 3
            case SetupWizardKind.ConfirmEmail => 4
        }
    }

    private func wizardIsMode(mode: SetupWizardMode): Bool {
        match (this.wizardMode) {
            case SetupWizardMode.Create =>
                match (mode) { case SetupWizardMode.Create => true case _ => false }
            case SetupWizardMode.Update =>
                match (mode) { case SetupWizardMode.Update => true case _ => false }
        }
    }

    private func wizardIsState(k: SetupWizardKind): Bool {
        this.wizardKindOrder(this.wizardState) == this.wizardKindOrder(k)
    }

    // §6.4 wizardBack(): ConfirmPassword / EnterHint 可回退到 EnterPassword；其余态左键
    // 显示 Cancel（无 Back）。
    private func wizardCanGoBack(): Bool {
        this.wizardIsState(SetupWizardKind.ConfirmPassword) || this.wizardIsState(SetupWizardKind.EnterHint)
    }

    // ---- 打开向导（§6.6 入口接线，四条挂载点各自的初态） ----

    private func wizardResetFields(): Unit {
        this.wizardActivity = false
        this.wizardPassword = ""
        this.wizardConfirmPassword = ""
        this.wizardHint = ""
        this.wizardEmail = ""
        this.wizardEmailCode = ""
        this.wizardErrorMessage = ""
        this.wizardEmailPattern = ""
        this.wizardPrevOrder = -1
    }

    private func openWizardCreatePassword(): Unit {
        this.wizardResetFields()
        this.wizardMode = SetupWizardMode.Create
        this.wizardState = SetupWizardKind.EnterPassword
        this.wizardHadRecoveryEmail = false
        this.wizardVisible = true
    }

    private func openWizardChangePassword(): Unit {
        this.wizardResetFields()
        this.wizardMode = SetupWizardMode.Update
        this.wizardState = SetupWizardKind.EnterPassword
        this.wizardHadRecoveryEmail = this.hasRecoveryEmail
        this.wizardVisible = true
    }

    private func openWizardRecoveryEmail(): Unit {
        this.wizardResetFields()
        this.wizardMode = SetupWizardMode.Update
        this.wizardState = SetupWizardKind.EnterEmail
        this.wizardHadRecoveryEmail = this.hasRecoveryEmail
        this.wizardVisible = true
    }

    private func openWizardConfirmEmailCode(): Unit {
        this.wizardResetFields()
        this.wizardMode = SetupWizardMode.Update
        this.wizardState = SetupWizardKind.ConfirmEmail
        this.wizardHadRecoveryEmail = this.hasRecoveryEmail
        this.wizardEmailPattern = this.emailUnconfirmedPattern
        this.wizardVisible = true
    }

    // §6.1 边界条件：wizardVisible 置 false 时必须同时清空向导全部输入态，对位源侧
    // "模态中断不留半成品"。
    private func closeWizard(): Unit {
        this.wizardVisible = false
        this.wizardState = SetupWizardKind.EnterPassword
        this.wizardMode = SetupWizardMode.Create
        this.wizardHadRecoveryEmail = false
        this.wizardResetFields()
    }

    // ---- 态迁移（§6.4，对位 ControllerNode:486-504 activateBackAction /
    // :505-706 activateNextAction） ----

    private func wizardBack(): Unit {
        if (this.wizardActivity) { return }
        if (!this.wizardCanGoBack()) { return }
        this.wizardPrevOrder = this.wizardKindOrder(this.wizardState)
        // ConfirmPassword/EnterHint 回退恒回 EnterPassword，且把已输入密码置空串
        // （对位源侧 :486-504，回退不保留半成品密码）。
        this.wizardPassword = ""
        this.wizardConfirmPassword = ""
        this.wizardErrorMessage = ""
        this.wizardState = SetupWizardKind.EnterPassword
    }

    private func wizardNext(): Unit {
        if (this.wizardActivity) { return }
        if (this.wizardIsState(SetupWizardKind.EnterPassword)) {
            if (this.wizardPassword.size == 0) { return }
            this.wizardConfirmPassword = ""
            this.wizardErrorMessage = ""
            this.wizardPrevOrder = this.wizardKindOrder(SetupWizardKind.EnterPassword)
            this.wizardState = SetupWizardKind.ConfirmPassword
            return
        }
        if (this.wizardIsState(SetupWizardKind.ConfirmPassword)) {
            if (this.wizardConfirmPassword.size == 0) { return }
            if (this.wizardPassword == this.wizardConfirmPassword) {
                this.wizardErrorMessage = ""
                this.wizardPrevOrder = this.wizardKindOrder(SetupWizardKind.ConfirmPassword)
                this.wizardState = SetupWizardKind.EnterHint
            } else {
                // 停留原态 + 单按钮 OK alert（对位 ControllerNode:524-529），不清空输入。
                this.wizardShowMismatchAlert()
            }
            return
        }
        if (this.wizardIsState(SetupWizardKind.EnterHint)) {
            if (this.wizardIsMode(SetupWizardMode.Update)) {
                this.wizardSubmitChangePassword()
            } else {
                this.wizardErrorMessage = ""
                this.wizardPrevOrder = this.wizardKindOrder(SetupWizardKind.EnterHint)
                this.wizardState = SetupWizardKind.EnterEmail
            }
            return
        }
        if (this.wizardIsState(SetupWizardKind.EnterEmail)) {
            if (this.wizardIsMode(SetupWizardMode.Create)) {
                if (this.wizardEmail.size == 0) {
                    // Create + 空邮箱 ⇒ 先弹二次确认 alert（对位 ControllerNode:699-705），
                    // 点 Skip 才继续提交。
                    this.wizardShowSkipConfirm()
                } else {
                    this.wizardSubmitCreatePassword()
                }
            } else {
                // Update 模式的 EnterEmail 是独立的"恢复邮箱变更"（§6.6 openWizardRecoveryEmail），
                // 邮箱为空时右上按钮本就 disabled（wizardNextEnabled()），此处仅作防御性守卫。
                if (this.wizardEmail.size > 0) {
                    this.wizardSubmitRecoveryEmail()
                }
            }
            return
        }
        if (this.wizardIsState(SetupWizardKind.ConfirmEmail)) {
            if (this.wizardEmailCode.size == 0) { return }
            this.wizardSubmitEmailCode()
        }
    }

    // ---- 右上按钮文案/可用性（§6.4：EnterHint / EnterEmail(.create) 输入为空时文案变
    // Skip 且恒 enabled，不是置灰；其余态 enabled = 输入非空） ----

    private func wizardNextEnabled(): Bool {
        if (this.wizardIsState(SetupWizardKind.EnterPassword)) { return this.wizardPassword.size > 0 }
        if (this.wizardIsState(SetupWizardKind.ConfirmPassword)) { return this.wizardConfirmPassword.size > 0 }
        if (this.wizardIsState(SetupWizardKind.EnterHint)) { return true }
        if (this.wizardIsState(SetupWizardKind.EnterEmail)) {
            if (this.wizardIsMode(SetupWizardMode.Create)) { return true }
            return this.wizardEmail.size > 0
        }
        if (this.wizardIsState(SetupWizardKind.ConfirmEmail)) { return this.wizardEmailCode.size > 0 }
        return false
    }

    private func wizardNextButtonText(): String {
        if (this.wizardIsState(SetupWizardKind.EnterHint)) {
            return if (this.wizardHint.size == 0) { "Skip" } else { "Next" }
        }
        if (this.wizardIsState(SetupWizardKind.EnterEmail) && this.wizardIsMode(SetupWizardMode.Create)) {
            return if (this.wizardEmail.size == 0) { "Skip" } else { "Next" }
        }
        return "Next"
    }

    // ---- 标题/副标题/占位符（§6.2 逐态字面量表，源侧字面量逐字照抄） ----

    private func wizardTitle(): String {
        if (this.wizardIsState(SetupWizardKind.EnterPassword)) {
            return if (this.wizardIsMode(SetupWizardMode.Update)) { "Change Password" } else { "Your Password" }
        }
        if (this.wizardIsState(SetupWizardKind.ConfirmPassword)) { return "Re-enter your Password" }
        if (this.wizardIsState(SetupWizardKind.EnterHint)) { return "Add a Hint" }
        return "Recovery Email"
    }

    private func wizardSubtitle(): String {
        if (this.wizardIsState(SetupWizardKind.EnterPassword)) {
            return if (this.wizardIsMode(SetupWizardMode.Update)) {
                "Please enter a new password which will be used to protect your data."
            } else {
                "Please create a password which will be used to protect your data."
            }
        }
        if (this.wizardIsState(SetupWizardKind.ConfirmPassword)) { return "Please confirm your password." }
        if (this.wizardIsState(SetupWizardKind.EnterHint)) {
            return "You can create an optional hint for your password."
        }
        if (this.wizardIsState(SetupWizardKind.EnterEmail)) {
            return if (this.wizardHadRecoveryEmail) {
                "Please enter your new recovery email. It is the only way to recover a forgotten password."
            } else {
                "Please add your valid e-mail. It is the only way to recover a forgotten password."
            }
        }
        return "Please enter the code we've just emailed at ${this.wizardEmailPattern}."
    }

    // ---- 换页方向（§6.5：新序号更大 ⇒ 右侧滑入；反之左侧滑入；首次出现 ⇒ 淡入） ----

    private func wizardTransitionDirection(): Int64 {
        if (this.wizardPrevOrder < 0) { return 0 }
        let cur = this.wizardKindOrder(this.wizardState)
        if (cur > this.wizardPrevOrder) { return 1 }
        if (cur < this.wizardPrevOrder) { return -1 }
        return 0
    }

    private func wizardContentTransition(): TransitionEffect {
        let dir = this.wizardTransitionDirection()
        if (dir == 1) {
            return TransitionEffect.asymmetric(
                TransitionEffect.opacity(0.0).combine(TransitionEffect.translate(TranslateOptions(x: 320.0)))
                    .animation(AnimateParam(duration: 500, curve: Curve.EaseInOut)),
                TransitionEffect.opacity(0.0).combine(TransitionEffect.translate(TranslateOptions(x: -320.0)))
                    .animation(AnimateParam(duration: 500, curve: Curve.EaseInOut))
            )
        }
        if (dir == -1) {
            return TransitionEffect.asymmetric(
                TransitionEffect.opacity(0.0).combine(TransitionEffect.translate(TranslateOptions(x: -320.0)))
                    .animation(AnimateParam(duration: 500, curve: Curve.EaseInOut)),
                TransitionEffect.opacity(0.0).combine(TransitionEffect.translate(TranslateOptions(x: 320.0)))
                    .animation(AnimateParam(duration: 500, curve: Curve.EaseInOut))
            )
        }
        return TransitionEffect.opacity(0.0).animation(AnimateParam(duration: 500, curve: Curve.EaseInOut))
    }

    // ---- 遮罩（沿用本工程已落地的真值方案：TextInput 绑真值 + 透明字色，底层只读
    // Text 展示遮罩串；先例 pages/TwoFactorCreatePasswordPage.cj §密码遮蔽、本文件
    // maskedPasswordDisplay()。不使用 InputType（S-128：当前 SDK 的 TextInput 无
    // type/InputType 成员）。） ----

    private func wizardMaskOf(s: String): String {
        var result = ""
        var i: Int64 = 0
        let count = s.toRuneArray().size
        while (i < count) {
            result += "•"
            i += 1
        }
        return result
    }

    // ---- 提交（RPC，§6.4 逐条错误文案对位） ----

    private func formatWizardError(rpcError: String): String {
        if (rpcError == "EMAIL_INVALID") { return "Invalid e-mail address. Please try again." }
        if (rpcError == "EMAIL_HASH_EXPIRED") { return "This confirmation code has expired. Please try again." }
        if (rpcError.startsWith("FLOOD_WAIT")) { return "Limit exceeded. Please try again later." }
        if (rpcError == "CODE_INVALID") { return "Invalid code, please try again." }
        return "An error occurred, please try again later."
    }

    private func wizardShowMismatchAlert(): Unit {
        let uiCtx = getUIContext()
        uiCtx.showAlertDialog(AlertDialogParamWithConfirm(
            message: "Passwords don't match. Please try again.",
            confirm: AlertDialogButtonOptions(value: "OK", action: {=> ()})
        ))
    }

    private func wizardShowSkipConfirm(): Unit {
        let uiCtx = getUIContext()
        let cancelBtn = AlertDialogButtonOptions(value: "Cancel", action: {=> ()})
        let skipBtn = AlertDialogButtonOptions(
            value: "Skip",
            fontColor: 0xFF3B30,
            action: { => this.wizardSubmitCreatePassword() }
        )
        uiCtx.showAlertDialog(AlertDialogParamWithButtons(
            message: "No, seriously.\n\nIf you forget your password, you will lose access to your Telegram account. There will be no way to restore it.",
            primaryButton: cancelBtn, secondaryButton: skipBtn, autoCancel: true
        ))
    }

    // Update 模式 EnterHint→提交（"Change Password"）：hasCurrentPassword=true，复用
    // access 屏已校验并保留在 this.currentPassword 的密码（对位源侧 case
    // .manage(password:...) 把已验证密码带入管理态）。成功后同步刷新
    // this.currentPassword 为新密码，避免刷新后残留旧值。
    private func wizardSubmitChangePassword(): Unit {
        if (this.wizardActivity) { return }
        this.wizardActivity = true
        this.wizardErrorMessage = ""
        let curPass = this.currentPassword
        let newPass = this.wizardPassword
        let hint = this.wizardHint

        spawn {
            var errMsg = ""
            var success = false
            try {
                let authService = getRealAuthService()
                let info = authService.getPasswordInfo()
                let newHash = authService.computeNewPasswordHash(newPass, info.algoG, info.algoP, info.algoSalt1, info.algoSalt2)

                let client = getMTProtoClient()
                let req = AccountUpdatePasswordSettings()
                req.hasCurrentPassword = true
                req.currentPasswordSRP = authService.computeCurrentPasswordSRP(curPass)
                req.setNewPassword = true
                req.algoSalt1 = info.algoSalt1
                req.algoSalt2 = info.algoSalt2
                req.algoG = info.algoG
                req.algoP = info.algoP
                req.newPasswordHash = newHash
                req.hint = hint

                let responseData = client.sendRequest(req.toBytes())
                if (responseData.size >= 4) {
                    let checkD = TLDeserializer(responseData)
                    let checkCtor = checkD.readUInt32()
                    if (checkCtor == 0x2144ca19) {
                        let errorCode = checkD.readInt32()
                        let errorMsg = checkD.readString()
                        Hilog.info(0, "CjTelegram", "[2FA-Wizard] Change RPC Error: ${errorCode} ${errorMsg}")
                        errMsg = this.formatWizardError(errorMsg)
                    } else {
                        success = true
                        Hilog.info(0, "CjTelegram", "[2FA-Wizard] Password changed")
                    }
                } else {
                    errMsg = "Unexpected server response"
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[2FA-Wizard] Change error: ${e}")
                errMsg = "An error occurred, please try again later."
            }
            let finalSuccess = success
            let finalErrMsg = errMsg
            launch {
                this.wizardActivity = false
                if (finalSuccess) {
                    this.currentPassword = newPass
                    this.closeWizard()
                    // 改密成功回宿主对位 UnlockController.swift:656-660：
                    // dataPromise = .manage(password:) + OverlayStatus PasswordChangeSuccess。
                    // 不要走 loadPasswordState()——那条每次重载都 mode=Access，专供冷进页。
                    this.mode = TwoFactorAuthMode.Manage
                    getOverlayStatusService().showSuccess(text: "Your password\nhas been changed.")
                } else {
                    this.wizardErrorMessage = finalErrMsg
                }
            }
        }
    }

    // Create 模式 EnterEmail→提交（"Set Additional Password" 全流程收尾）：hasCurrentPassword
    // =false（账号此前无密码），一并带上 hint + 可选 email。成功且带 email 时再查一次
    // getPasswordInfo() 看是否落入待确认态（emailUnconfirmedPattern 非空）⇒ 转 ConfirmEmail；
    // 否则整屏关闭。
    private func wizardSubmitCreatePassword(): Unit {
        if (this.wizardActivity) { return }
        this.wizardActivity = true
        this.wizardErrorMessage = ""
        let newPass = this.wizardPassword
        let hint = this.wizardHint
        let email = this.wizardEmail
        let includeEmail = email.size > 0

        spawn {
            var errMsg = ""
            var success = false
            var pendingPattern = ""
            try {
                let authService = getRealAuthService()
                let info = authService.getPasswordInfo()
                let newHash = authService.computeNewPasswordHash(newPass, info.algoG, info.algoP, info.algoSalt1, info.algoSalt2)

                let client = getMTProtoClient()
                let req = AccountUpdatePasswordSettings()
                req.hasCurrentPassword = false
                req.setNewPassword = true
                req.algoSalt1 = info.algoSalt1
                req.algoSalt2 = info.algoSalt2
                req.algoG = info.algoG
                req.algoP = info.algoP
                req.newPasswordHash = newHash
                req.hint = hint
                if (includeEmail) {
                    req.setEmail = true
                    req.email = email
                }

                let responseData = client.sendRequest(req.toBytes())
                if (responseData.size >= 4) {
                    let checkD = TLDeserializer(responseData)
                    let checkCtor = checkD.readUInt32()
                    if (checkCtor == 0x2144ca19) {
                        let errorCode = checkD.readInt32()
                        let errorMsg = checkD.readString()
                        Hilog.info(0, "CjTelegram", "[2FA-Wizard] Create RPC Error: ${errorCode} ${errorMsg}")
                        errMsg = this.formatWizardError(errorMsg)
                    } else {
                        success = true
                        if (includeEmail) {
                            let refreshed = authService.getPasswordInfo()
                            pendingPattern = refreshed.emailUnconfirmedPattern
                        }
                        Hilog.info(0, "CjTelegram", "[2FA-Wizard] Password created")
                    }
                } else {
                    errMsg = "Unexpected server response"
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[2FA-Wizard] Create error: ${e}")
                errMsg = "An error occurred, please try again later."
            }
            let finalSuccess = success
            let finalErrMsg = errMsg
            let finalPending = pendingPattern
            launch {
                this.wizardActivity = false
                if (finalSuccess) {
                    if (finalPending.size > 0) {
                        this.wizardEmailPattern = finalPending
                        this.wizardPrevOrder = this.wizardKindOrder(SetupWizardKind.EnterEmail)
                        this.wizardState = SetupWizardKind.ConfirmEmail
                    } else {
                        this.closeWizard()
                    }
                    this.loadPasswordState()
                } else {
                    this.wizardErrorMessage = finalErrMsg
                }
            }
        }
    }

    // Update 模式独立 EnterEmail→提交（"Set|Change Recovery E-Mail" 单行入口）：只提交
    // 邮箱，hasCurrentPassword=true 复用 access 屏已验证密码。
    private func wizardSubmitRecoveryEmail(): Unit {
        if (this.wizardActivity) { return }
        this.wizardActivity = true
        this.wizardErrorMessage = ""
        let curPass = this.currentPassword
        let email = this.wizardEmail

        spawn {
            var errMsg = ""
            var success = false
            var pendingPattern = ""
            try {
                let authService = getRealAuthService()
                let client = getMTProtoClient()
                let req = AccountUpdatePasswordSettings()
                req.hasCurrentPassword = true
                req.currentPasswordSRP = authService.computeCurrentPasswordSRP(curPass)
                req.setEmail = true
                req.email = email

                let responseData = client.sendRequest(req.toBytes())
                if (responseData.size >= 4) {
                    let checkD = TLDeserializer(responseData)
                    let checkCtor = checkD.readUInt32()
                    if (checkCtor == 0x2144ca19) {
                        let errorCode = checkD.readInt32()
                        let errorMsg = checkD.readString()
                        Hilog.info(0, "CjTelegram", "[2FA-Wizard] Email RPC Error: ${errorCode} ${errorMsg}")
                        errMsg = this.formatWizardError(errorMsg)
                    } else {
                        success = true
                        let refreshed = authService.getPasswordInfo()
                        pendingPattern = refreshed.emailUnconfirmedPattern
                        Hilog.info(0, "CjTelegram", "[2FA-Wizard] Recovery email submitted")
                    }
                } else {
                    errMsg = "Unexpected server response"
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[2FA-Wizard] Email error: ${e}")
                errMsg = "An error occurred, please try again later."
            }
            let finalSuccess = success
            let finalErrMsg = errMsg
            let finalPending = pendingPattern
            launch {
                this.wizardActivity = false
                if (finalSuccess) {
                    if (finalPending.size > 0) {
                        this.wizardEmailPattern = finalPending
                        this.wizardPrevOrder = this.wizardKindOrder(SetupWizardKind.EnterEmail)
                        this.wizardState = SetupWizardKind.ConfirmEmail
                    } else {
                        this.closeWizard()
                    }
                    this.loadPasswordState()
                } else {
                    this.wizardErrorMessage = finalErrMsg
                }
            }
        }
    }

    // ConfirmEmail→提交：复用既有 confirmPasswordEmail RPC（与 doConfirmRecoveryEmail()
    // 同一账号级能力，向导侧用独立的 wizardEmailCode 字段，不与
    // NotSetPendingEmail 分支的 confirmEmailCode 共享状态）。
    private func wizardSubmitEmailCode(): Unit {
        if (this.wizardActivity) { return }
        this.wizardActivity = true
        this.wizardErrorMessage = ""
        let code = this.wizardEmailCode

        spawn {
            let authService = getRealAuthService()
            let ok = authService.confirmPasswordEmail(code)
            let lastErr = authService.getLastError()
            let finalOk = ok
            let finalLastErr = lastErr
            launch {
                this.wizardActivity = false
                if (finalOk) {
                    this.closeWizard()
                    this.loadPasswordState()
                } else {
                    this.wizardErrorMessage = if (finalLastErr.size > 0) {
                        this.formatWizardError(finalLastErr)
                    } else {
                        "Invalid code, please try again."
                    }
                }
            }
        }
    }

    // 源 SetupTwoStepVerificationContentNode.swift:160-161：
    // inputWidth = min(300, size.width - 37×2)，inputHeight = 44。打在 input 节点自己上。
    private func wizardFieldWidth(): Float64 {
        let density = Float64(getDefaultDisplaySync().densityPixels)
        let safeDensity = if (density <= 0.0) { 1.0 } else { density }
        let dispW = Float64(getDefaultDisplaySync().width)
        let dispH = Float64(getDefaultDisplaySync().height)
        let screenWidth = if (dispW < dispH) { dispW / safeDensity } else { dispH / safeDensity }
        let available = screenWidth - 74.0
        return if (available < 300.0) { available } else { 300.0 }
    }

    // 下滑 dismiss：挂在向导透明 nav，阈值 100vp，与 Cancel 同一 closeWizard()。
    private func onWizardNavTouch(event: TouchEvent): Unit {
        match (event.eventType) {
            case TouchType.Down =>
                if (event.touches.size > 0) {
                    this.wizardSwipeStartY = event.touches[0].screenY
                    this.wizardSwipeTracking = true
                }
            case TouchType.Up =>
                if (this.wizardSwipeTracking && event.changedTouches.size > 0) {
                    let deltaY = event.changedTouches[0].screenY - this.wizardSwipeStartY
                    if (deltaY > 100.0) {
                        this.closeWizard()
                    }
                }
                this.wizardSwipeTracking = false
            case TouchType.Cancel =>
                this.wizardSwipeTracking = false
            case _ => ()
        }
    }

    // ==================== RC-3 (TC-0142 reconstruct): 独立全屏向导 ====================
    // 打开后 host manage 不在树里。S-136：build()/@Builder 体内不能直接 match 产出 UI。

    @Builder
    func buildSetupWizardFullscreen() {
        Column {
            Row {
                if (this.wizardCanGoBack()) {
                    Text(trSource("Back"))
                        .fontSize(17).fontColor(0x007AFF)
                        .onClick({ evt => this.wizardBack() })
                } else {
                    Text(trSource("Cancel"))
                        .fontSize(17).fontColor(0x007AFF)
                        .onClick({ evt => this.closeWizard() })
                }
                Blank().layoutWeight(1)
                if (this.wizardActivity) {
                    LoadingProgress().width(20).height(20).color(0x007AFF)
                } else {
                    Text(this.wizardNextButtonText())
                        .fontSize(17)
                        .fontColor(0x007AFF)
                        .opacity(if (this.wizardNextEnabled()) { 1.0 } else { 0.4 })
                        .enabled(this.wizardNextEnabled())
                        .onClick({ evt => this.wizardNext() })
                }
            }
            .width(100.percent)
            .height(44.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .alignItems(VerticalAlign.Center)
            .backgroundColor(Color.Transparent)
            .onTouch({ event: TouchEvent => this.onWizardNavTouch(event) })

            Column {
                if (this.wizardIsState(SetupWizardKind.EnterPassword)) {
                    this.wizardEnterPasswordContent()
                } else if (this.wizardIsState(SetupWizardKind.ConfirmPassword)) {
                    this.wizardConfirmPasswordContent()
                } else if (this.wizardIsState(SetupWizardKind.EnterHint)) {
                    this.wizardEnterHintContent()
                } else if (this.wizardIsState(SetupWizardKind.EnterEmail)) {
                    this.wizardEnterEmailContent()
                } else {
                    this.wizardConfirmEmailContent()
                }

                if (this.wizardErrorMessage.size > 0) {
                    Text(this.wizardErrorMessage)
                        .fontSize(14).fontColor(0xFF3B30)
                        .textAlign(TextAlign.Center)
                        .margin(top: 16)
                        .padding(left: 32, right: 32)
                        .width(100.percent)
                }
            }
            .width(100.percent)
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1)
            .transition(this.wizardContentTransition())
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .onAppear({ => this.ensureLoaded() })
    }

    /*
    // 旧 overlay 向导（历史留痕）。setupWizardCover + bindContentCover 叠在 manage 上，
    // 运行时无 Cancel/Next，host 三行仍在树。已由 buildSetupWizardFullscreen 取代。
    @Builder
    func setupWizardCover() {
        Column {
            Row {
                if (this.wizardCanGoBack()) {
                    Text(trSource("Back"))
                        .fontSize(17).fontColor(0x007AFF)
                        .onClick({ evt => this.wizardBack() })
                } else {
                    Text(trSource("Cancel"))
                        .fontSize(17).fontColor(0x007AFF)
                        .onClick({ evt => this.closeWizard() })
                }
                Blank().layoutWeight(1)
                if (this.wizardActivity) {
                    LoadingProgress().width(20).height(20).color(0x007AFF)
                } else {
                    Text(this.wizardNextButtonText())
                        .fontSize(17)
                        .fontColor(0x007AFF)
                        .opacity(if (this.wizardNextEnabled()) { 1.0 } else { 0.4 })
                        .enabled(this.wizardNextEnabled())
                        .onClick({ evt => this.wizardNext() })
                }
            }
            .width(100.percent)
            .height(44)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    if (this.wizardIsState(SetupWizardKind.EnterPassword)) {
                        this.wizardEnterPasswordContent()
                    } else if (this.wizardIsState(SetupWizardKind.ConfirmPassword)) {
                        this.wizardConfirmPasswordContent()
                    } else if (this.wizardIsState(SetupWizardKind.EnterHint)) {
                        this.wizardEnterHintContent()
                    } else if (this.wizardIsState(SetupWizardKind.EnterEmail)) {
                        this.wizardEnterEmailContent()
                    } else {
                        this.wizardConfirmEmailContent()
                    }

                    if (this.wizardErrorMessage.size > 0) {
                        Text(this.wizardErrorMessage)
                            .fontSize(14).fontColor(0xFF3B30)
                            .textAlign(TextAlign.Center)
                            .margin(top: 16)
                            .padding(left: 32, right: 32)
                            .width(100.percent)
                    }
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Center)
                .transition(this.wizardContentTransition())
            }
            .align(Alignment.Top)
            .layoutWeight(1)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
    }
    */

    // 标题 + 副标题，5 态共用（对位 ContentNode:45-55，居中大字细体标题 + 12pt 间距
    // 12sp 居中副标题，均可多行）。
    @Builder
    func wizardHeaderText() {
        Text(this.wizardTitle())
            .fontSize(30)
            // S-140: 本 SDK FontWeight 枚举无 Light 成员（见 syntax_error.md S-140），
            // Lighter 是最接近源侧 Font.light(30) 语义的可用值。
            .fontWeight(FontWeight.Lighter)
            .fontColor(0x000000)
            .textAlign(TextAlign.Center)
            .margin(top: 56)
            .padding(left: 32, right: 32)
            .width(100.percent)

        Text(this.wizardSubtitle())
            .fontSize(12)
            .fontColor(0x000000)
            .textAlign(TextAlign.Center)
            .margin(top: 12)
            .padding(left: 32, right: 32)
            .width(100.percent)
    }

    @Builder
    func wizardEnterPasswordContent() {
        this.wizardHeaderText()
        Column {
            Stack(alignContent: Alignment.Center) {
                if (!this.wizardPassword.isEmpty()) {
                    Text(this.wizardMaskOf(this.wizardPassword))
                        .fontSize(17).fontColor(0x000000)
                }
                TextInput(text: this.wizardPassword, placeholder: trSource("Password"))
                    .fontColor(Color.Transparent)
                    .placeholderColor(0x8E8D92)
                    .caretColor(0x000000)
                    .backgroundColor(Color.Transparent)
                    .textAlign(TextAlign.Center)
                    .enabled(!this.wizardActivity)
                    .enterKeyType(EnterKeyType.Next)
                    .onSubmit({ _: EnterKeyType => this.wizardNext() })
                    .onChange({ value: String =>
                        this.wizardPassword = value
                        this.wizardErrorMessage = ""
                    })
                    .width(this.wizardFieldWidth())
                    .height(44)
                    .constraintSize(
                        minWidth: this.wizardFieldWidth(),
                        maxWidth: this.wizardFieldWidth(),
                        minHeight: 44,
                        maxHeight: 44
                    )
            }
            .width(this.wizardFieldWidth())
            .height(44)
            .clip(true)
            Divider().color(0xE5E5EA).strokeWidth(1).width(this.wizardFieldWidth())
        }
        .margin(top: 32)
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func wizardConfirmPasswordContent() {
        this.wizardHeaderText()
        Column {
            Stack(alignContent: Alignment.Center) {
                if (!this.wizardConfirmPassword.isEmpty()) {
                    Text(this.wizardMaskOf(this.wizardConfirmPassword))
                        .fontSize(17).fontColor(0x000000)
                }
                TextInput(text: this.wizardConfirmPassword, placeholder: trSource("Password"))
                    .fontColor(Color.Transparent)
                    .placeholderColor(0x8E8D92)
                    .caretColor(0x000000)
                    .backgroundColor(Color.Transparent)
                    .textAlign(TextAlign.Center)
                    .enabled(!this.wizardActivity)
                    .enterKeyType(EnterKeyType.Next)
                    .onSubmit({ _: EnterKeyType => this.wizardNext() })
                    .onChange({ value: String =>
                        this.wizardConfirmPassword = value
                        this.wizardErrorMessage = ""
                    })
                    .width(this.wizardFieldWidth())
                    .height(44)
                    .constraintSize(
                        minWidth: this.wizardFieldWidth(),
                        maxWidth: this.wizardFieldWidth(),
                        minHeight: 44,
                        maxHeight: 44
                    )
            }
            .width(this.wizardFieldWidth())
            .height(44)
            .clip(true)
            Divider().color(0xE5E5EA).strokeWidth(1).width(this.wizardFieldWidth())
        }
        .margin(top: 32)
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func wizardEnterHintContent() {
        this.wizardHeaderText()
        Column {
            Stack(alignContent: Alignment.Center) {
                TextInput(text: this.wizardHint, placeholder: trSource("Hint"))
                    .fontColor(0x000000)
                    .placeholderColor(0x8E8D92)
                    .caretColor(0x000000)
                    .backgroundColor(Color.Transparent)
                    .textAlign(TextAlign.Center)
                    .enabled(!this.wizardActivity)
                    .enterKeyType(EnterKeyType.Next)
                    .onSubmit({ _: EnterKeyType => this.wizardNext() })
                    .onChange({ value: String => this.wizardHint = value })
                    .width(this.wizardFieldWidth())
                    .height(44)
                    .constraintSize(
                        minWidth: this.wizardFieldWidth(),
                        maxWidth: this.wizardFieldWidth(),
                        minHeight: 44,
                        maxHeight: 44
                    )
            }
            .width(this.wizardFieldWidth())
            .height(44)
            .clip(true)
            Divider().color(0xE5E5EA).strokeWidth(1).width(this.wizardFieldWidth())
        }
        .margin(top: 32)
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func wizardEnterEmailContent() {
        this.wizardHeaderText()
        Column {
            Stack(alignContent: Alignment.Center) {
                TextInput(text: this.wizardEmail, placeholder: trSource("Your E-Mail"))
                    .fontColor(0x000000)
                    .placeholderColor(0x8E8D92)
                    .caretColor(0x000000)
                    .backgroundColor(Color.Transparent)
                    .textAlign(TextAlign.Center)
                    .enabled(!this.wizardActivity)
                    .enterKeyType(EnterKeyType.Next)
                    .onSubmit({ _: EnterKeyType => this.wizardNext() })
                    .onChange({ value: String =>
                        this.wizardEmail = value
                        this.wizardErrorMessage = ""
                    })
                    .width(this.wizardFieldWidth())
                    .height(44)
                    .constraintSize(
                        minWidth: this.wizardFieldWidth(),
                        maxWidth: this.wizardFieldWidth(),
                        minHeight: 44,
                        maxHeight: 44
                    )
            }
            .width(this.wizardFieldWidth())
            .height(44)
            .clip(true)
            Divider().color(0xE5E5EA).strokeWidth(1).width(this.wizardFieldWidth())
        }
        .margin(top: 32)
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func wizardConfirmEmailContent() {
        this.wizardHeaderText()
        Column {
            Stack(alignContent: Alignment.Center) {
                TextInput(text: this.wizardEmailCode, placeholder: trSource("Code"))
                    .fontColor(0x000000)
                    .placeholderColor(0x8E8D92)
                    .caretColor(0x000000)
                    .backgroundColor(Color.Transparent)
                    .textAlign(TextAlign.Center)
                    .enabled(!this.wizardActivity)
                    .enterKeyType(EnterKeyType.Next)
                    .onSubmit({ _: EnterKeyType => this.wizardNext() })
                    .onChange({ value: String =>
                        this.wizardEmailCode = value
                        this.wizardErrorMessage = ""
                    })
                    .width(this.wizardFieldWidth())
                    .height(44)
                    .constraintSize(
                        minWidth: this.wizardFieldWidth(),
                        maxWidth: this.wizardFieldWidth(),
                        minHeight: 44,
                        maxHeight: 44
                    )
            }
            .width(this.wizardFieldWidth())
            .height(44)
            .clip(true)
            Divider().color(0xE5E5EA).strokeWidth(1).width(this.wizardFieldWidth())
        }
        .margin(top: 32)
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
    }
}
