package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.models.User
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.utils.getCountryByLocaleTag
import ohos.i18n.System as I18nSystem
import ohos.business_exception.BusinessException
import std.collection.ArrayList
/**
 * 认证状态常量（顶层定义）
 */
public let AUTH_STATE_INITIALIZING: String = "initializing"
public let AUTH_STATE_WAIT_PHONE: String = "authorizationStateWaitPhoneNumber"
public let AUTH_STATE_WAIT_CODE: String = "authorizationStateWaitCode"
public let AUTH_STATE_WAIT_REGISTRATION: String = "authorizationStateWaitRegistration"
public let AUTH_STATE_WAIT_PASSWORD: String = "authorizationStateWaitPassword"
public let AUTH_STATE_WAIT_PASSWORD_RECOVERY: String = "authorizationStateWaitPasswordRecovery"
public let AUTH_STATE_AWAITING_ACCOUNT_RESET: String = "authorizationStateAwaitingAccountReset"
// R1 (TC-0015 返修): 对位 iOS SentAuthorizationCodeType.emailSetupRequired —— 登录链路要求
// 先设置邮箱才能继续，EmailLoginPage 消费此态。
public let AUTH_STATE_WAIT_EMAIL_SETUP: String = "authorizationStateWaitEmailCode"
public let AUTH_STATE_READY: String = "authorizationStateReady"
public let AUTH_STATE_CLOSING: String = "authorizationStateClosing"
public let AUTH_STATE_CLOSED: String = "authorizationStateClosed"

/**
 * 顶层单例管理函数
 */
private var _authViewModelInstance: Option<AuthViewModel> = None<AuthViewModel>

public func getAuthViewModel(): AuthViewModel {
    if (_authViewModelInstance.isNone()) {
        let vm = AuthViewModel()
        // QA #6: 单例首次创建时按设备 locale 覆盖默认国家（S-015 约束下不能塞进
        // @Observed 类的自定义 init，改在工厂函数里对 default-init 实例调用一次）。
        vm.applyLocaleDefaultCountry()
        _authViewModelInstance = Some(vm)
    }
    return _authViewModelInstance.getOrThrow()
}

/**
 * QA #6: 从设备 locale 推断默认国家（dialCode, countryName），三元组（含国旗）始终来自
 * CountryData 同一条记录，保证 flag/dialCode/name 一致（对照 AuthViewModel.countryCode
 * 字段注释：三者不一致是曾复现的缺陷组合）。
 *
 * 对齐 iOS AuthorizationSequenceController.swift:1436-1451 defaultCountryCode()：
 * 从 Locale.current 的 region 反查国家，找不到则 fallback "+1" (US)。
 *
 * 仓颉侧 ohos.i18n.System 只暴露 getAppPreferredLanguage()（无独立 getRegion API，
 * 已用 cangjie SDK ohos.i18n.cj.d 核实：System 类仅此一个静态方法），返回形如
 * "zh-Hans-CN" / "en-US" 的 BCP47 语言标签。CountryData.getCountryByLocaleTag() 已实现
 * 从该标签尾部提取 2 字母地区码再查 CountryData 表的逻辑（P2-011/P2-012），此处复用。
 *
 * getAppPreferredLanguage() 在部分设备/时机下可能抛 BusinessException（已在
 * CalendarMessageScreen.cj loadLocaleSettings() 验证过此签名及异常类型）；
 * 任何失败路径都返回 ("", "") 交给调用方决定 fallback，不在此处硬编码 UI 相关默认值。
 */
public func resolveDefaultCountryFromLocale(): (String, String) {
    var localeTag = ""
    try {
        localeTag = I18nSystem.getAppPreferredLanguage()
    } catch (_: BusinessException) {
        localeTag = ""
    }
    if (localeTag.size == 0) {
        // 无法读取设备 locale：回退 iOS 同款兜底 +1/US（AuthorizationSequenceController
        // defaultCountryCode() 的 fallback 分支）。
        return ("+1", "United States")
    }
    let (dialCode, countryName) = getCountryByLocaleTag(localeTag)
    if (dialCode.size > 0 && countryName.size > 0) {
        return (dialCode, countryName)
    }
    // locale 标签解析不出已知地区（如仅语言码且不在 getCountryByLanguageCode 映射表中）：
    // 同样回退 +1/US，保持与 iOS 一致的兜底行为。
    return ("+1", "United States")
}

/**
 * 认证 ViewModel — MTProto 集成版本
 * 
 * Phase 7: 连接 RealAuthService，使用 MTProto 进行真实认证
 */
@Observed
public class AuthViewModel {
    public static let AUTH_STATE_IDLE: Int32 = 0
    public static let AUTH_STATE_WAITING_PHONE: Int32 = 1
    public static let AUTH_STATE_WAITING_CODE: Int32 = 2
    public static let AUTH_STATE_WAITING_SIGNUP: Int32 = 3
    public static let AUTH_STATE_AUTHENTICATED: Int32 = 4
    
    @Publish public var isLoggedIn: Bool = false
    @Publish public var currentUser: Option<User> = None<User>
    @Publish public var phoneNumber: String = ""
    // QA #6: 默认国家不再硬编码，改在 init() 里按设备 locale 推断（对照 iOS
    // AuthorizationSequenceController.swift:1436-1451 defaultCountryCode() 从
    // Locale.current.regionCode 推断，找不到时 fallback "+1"/US）。此处字段初值仍先给
    // "+86"/"China mainland" 作为 init() 跑之前的占位一致三元组（countryCode/countryName/
    // 旗三者必须描述同一个国家 —— PhoneInputComponent 用 getEmojiByCode(countryCode) 反查
    // 国旗，"+1" 被 Canada/US 共用且 Canada 排在前，写 "United States" 会反查出 🇨🇦，
    // 三者不一致；"+86"/"China mainland" 是列表中唯一使用该区号的国家，天然一致），
    // init() 里会用 resolveDefaultCountry() 的结果原子性覆盖这两个字段。
    @Publish public var countryCode: String = "+86"
    // 混合迁移 auth-flow：原 EntryView @Provide countryName 迁入 app 级单例 SSOT
    // （CountrySelectionPage 写入、PhoneInputPage 读取；跨隔离嵌入页无法 @Provide/@Consume）
    @Publish public var countryName: String = "China mainland"
    @Publish public var isLoading: Bool = false
    @Publish public var errorMessage: String = ""
    @Publish public var authState: String = AUTH_STATE_INITIALIZING
    @Publish public var recoveryEmailPattern: String = ""
    @Publish public var accountResetWaitSeconds: Int32 = 0
    @Publish public var qrLoginToken: String = ""  // base64url token for QR display
    @Publish public var qrLoginExpiresAt: Int32 = 0
    @Publish public var has2FA: Bool = false
    @Publish public var tmpPasswordValidUntil: Int32 = 0
    
    // 用于导航触发
    @Publish public var shouldNavigateToCode: Bool = false
    @Publish public var shouldNavigateToSignUp: Bool = false
    @Publish public var shouldNavigateToPasswordRecovery: Bool = false
    // TC-0012/D5a 修法 A 第 1 步（diag-suite_auth_login-TC-0012.md）：AwaitingAccountReset
    // 授权状态的导航触发 flag，与上面三个 shouldNavigateTo* 同层同风格；
    // 实际路由消费见 CodeInputPage.submitCode()。
    @Publish public var shouldNavigateToAccountReset: Bool = false

    // 更改手机号流程状态 (TelegramEngine.AccountData)
    @Publish public var changePhoneStep: Int32 = 1
    @Publish public var changePhoneCodeHash: String = ""
    @Publish public var changePhoneError: String = ""
    @Publish public var changePhoneSuccess: Bool = false

    // ic_password_recovery_suggest_reset: PasswordRecoveryPage 判定恢复失败/不可用时置 true
    // （生产者），PasswordInputPage 在 .onAppear 回落读取（消费者，见该文件
    // resyncSuggestReset()），驱动已实现的 "Reset Account" 出路显示与文案分支
    // （TwoStepAuth.RecoveryFailed）。只升不降的一次性建议标记，不随其他事件复位。
    @Publish public var passwordRecoverySuggestReset: Bool = false

    // QA #6: 设备 locale 推断的默认国家不能在这里用自定义 init() 写（S-015：@Observed
    // 类禁止自定义构造函数，实测宏展开报 "macro evaluation has failed for macro call
    // 'Observed'"）。改为在顶层单例工厂 getAuthViewModel() 里，构造出 default-init 实例后
    // 立即调用 applyLocaleDefaultCountry() 这个普通实例方法覆盖 countryCode/countryName。

    /**
     * QA #6: 用设备 locale 推断的默认国家原子性覆盖 countryCode/countryName。
     * 只应在单例刚构造、用户还未做任何手动国家选择时调用一次（见 getAuthViewModel()）。
     */
    public func applyLocaleDefaultCountry(): Unit {
        let (code, name) = resolveDefaultCountryFromLocale()
        if (code.size > 0 && name.size > 0) {
            this.countryCode = code
            this.countryName = name
        }
    }

    /**
     * 初始化 MTProto 客户端（在 spawn 中调用）
     */
    public func initializeMTProto() {
        let authService = getRealAuthService()

        // 注册回调
        authService.setCallback(AuthViewModelCallback(viewModel: this))

        // 在后台初始化 MTProto 客户端
        authService.initializeClient()

        // 尝试恢复登录
        if (authService.tryRestoreLogin()) {
            this.isLoggedIn = true
            this.authState = AUTH_STATE_READY
        } else {
            // 无已存储登录，进入等待手机号状态
            this.authState = AUTH_STATE_WAIT_PHONE
        }
    }

    /**
     * 确保回调已注册
     */
    public func ensureCallbackRegistered() {
        let authService = getRealAuthService()
        // 每次确保回调指向当前 ViewModel
        authService.setCallback(AuthViewModelCallback(viewModel: this))
    }

    /**
     * 发送手机号
     */
    public func sendPhoneNumber(fullPhoneNumber: String) {
        this.isLoading = true
        this.errorMessage = ""
        this.phoneNumber = fullPhoneNumber
        
        // 确保回调已注册，这样 sendCode 完成后能通知 ViewModel
        ensureCallbackRegistered()
        
        let phoneCopy = fullPhoneNumber
        spawn {
            try {
                let authService = getRealAuthService()
                authService.sendCode(phoneCopy)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AuthViewModel] sendCode exception: ${e}")
                launch {
                    this.errorMessage = "发送验证码失败: ${e}"
                    this.isLoading = false
                }
            }
        }
    }
    
    /**
     * 验证码登录
     */
    public func verifyCode(code: String) {
        this.isLoading = true
        this.errorMessage = ""
        
        ensureCallbackRegistered()
        
        let codeCopy = code
        spawn {
            try {
                let authService = getRealAuthService()
                authService.verifyCode(codeCopy)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AuthViewModel] verifyCode exception: ${e}")
                launch {
                    this.errorMessage = "验证码验证失败: ${e}"
                    this.isLoading = false
                }
            }
        }
    }
    
    /**
     * 注册新用户
     */
    public func signUp(firstName: String, lastName: String) {
        this.isLoading = true
        this.errorMessage = ""
        
        ensureCallbackRegistered()
        
        let firstCopy = firstName
        let lastCopy = lastName
        spawn {
            try {
                let authService = getRealAuthService()
                authService.signUp(firstCopy, lastCopy)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AuthViewModel] signUp exception: ${e}")
                launch {
                    this.errorMessage = "注册失败: ${e}"
                    this.isLoading = false
                }
            }
        }
    }
    
    /**
     * 2FA 密码验证（已有 checkPassword 在 RealAuthService，通过 callback 更新状态）
     */
    public func checkPassword(password: String) {
        this.isLoading = true
        this.errorMessage = ""
        ensureCallbackRegistered()
        let pwdCopy = password
        spawn {
            try {
                let authService = getRealAuthService()
                authService.checkPassword(pwdCopy)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AuthViewModel] checkPassword exception: ${e}")
                launch {
                    this.errorMessage = "密码验证失败: ${e}"
                    this.isLoading = false
                }
            }
        }
    }
    
    /**
     * 请求 2FA 密码恢复（发送恢复码到邮箱）
     */
    public func requestPasswordRecovery() {
        this.isLoading = true
        this.errorMessage = ""
        ensureCallbackRegistered()
        spawn {
            let authService = getRealAuthService()
            let ok = authService.requestPasswordRecovery()
            launch {
                this.isLoading = false
                if (ok) {
                    this.recoveryEmailPattern = authService.getRecoveryEmailPattern()
                    this.authState = AUTH_STATE_WAIT_PASSWORD_RECOVERY
                    this.shouldNavigateToPasswordRecovery = true
                } else {
                    this.errorMessage = authService.getLastError()
                }
            }
        }
    }
    
    /**
     * 使用恢复码重置 2FA
     */
    public func recoverPassword(code: String) {
        this.isLoading = true
        this.errorMessage = ""
        ensureCallbackRegistered()
        let codeCopy = code
        spawn {
            let authService = getRealAuthService()
            let ok = authService.recoverPassword(codeCopy)
            launch {
                this.isLoading = false
                if (!ok) {
                    this.errorMessage = authService.getLastError()
                }
            }
        }
    }
    
    /**
     * 删除账号（无 2FA 密码时触发 7 天延迟）
     */
    public func deleteAccount(reason: String, withPassword: Bool, password: String) {
        this.isLoading = true
        this.errorMessage = ""
        ensureCallbackRegistered()
        let reasonCopy = reason
        let pwdCopy = password
        spawn {
            let authService = getRealAuthService()
            let (ok, waitSec) = authService.deleteAccount(reasonCopy, withPassword, pwdCopy)
            launch {
                this.isLoading = false
                if (ok) {
                    this.isLoggedIn = false
                    this.currentUser = None
                    this.authState = AUTH_STATE_WAIT_PHONE
                } else if (waitSec > 0) {
                    this.accountResetWaitSeconds = waitSec
                    this.authState = AUTH_STATE_AWAITING_ACCOUNT_RESET
                    this.shouldNavigateToAccountReset = true
                } else {
                    this.errorMessage = authService.getLastError()
                }
            }
        }
    }
    
    /**
     * 退出登录
     */
    public func logout() {
        spawn {
            let authService = getRealAuthService()
            authService.logout()
        }
        this.isLoggedIn = false
        this.currentUser = None<User>
        this.phoneNumber = ""
        this.errorMessage = ""
        this.authState = AUTH_STATE_WAIT_PHONE
    }
    
    public func handleAuthStateChange(stateType: String) {
        this.isLoading = false
        this.authState = stateType
        if (stateType == AUTH_STATE_READY) {
            this.isLoggedIn = true
        } else if (stateType == AUTH_STATE_CLOSED) {
            this.isLoggedIn = false
            this.currentUser = None<User>
        }
    }
    
    public func handleError(code: Int64, message: String) {
        this.isLoading = false
        this.errorMessage = message
    }
    
    public func clearError() {
        this.errorMessage = ""
    }
    
    public func getFullPhoneNumber(): String {
        return this.phoneNumber
    }

    // ==================== TelegramEngine.Auth — QR Login, 2FA, Recovery ====================

    /**
     * 导出 QR 登录 Token（auth.exportLoginToken）
     * 返回 token 的 base64url 编码，用于 tg://login?token=xxx 显示在 QR 码中
     */
    public func exportLoginToken(exceptIds: ArrayList<Int64>): AuthLoginTokenResponse {
        let authService = getRealAuthService()
        return authService.exportLoginToken(exceptIds)
    }

    /**
     * 导入 QR 登录 Token（auth.importLoginToken）
     * 扫码后 DC 不匹配时使用重定向 token
     */
    public func importLoginToken(token: Array<Byte>): AuthLoginTokenResponse {
        let authService = getRealAuthService()
        return authService.importLoginToken(token)
    }

    /**
     * 取消账号密码重置（account.declinePasswordReset）
     */
    public func declinePasswordReset(): Bool {
        return getRealAuthService().declinePasswordReset()
    }

    /**
     * 确认两步验证恢复邮箱（account.confirmPasswordEmail）
     */
    public func confirmPasswordEmail(code: String): Bool {
        return getRealAuthService().confirmPasswordEmail(code)
    }

    /**
     * 重新发送两步验证恢复邮箱验证码（account.resendPasswordEmail）
     */
    public func resendPasswordEmail(): Bool {
        return getRealAuthService().resendPasswordEmail()
    }

    /**
     * 获取临时支付密码（account.getTmpPassword）
     * 需已登录且通过 2FA 验证
     */
    public func getTmpPassword(password: String, period: Int32): AccountTmpPasswordResponse {
        return getRealAuthService().getTmpPassword(password, period)
    }

    /**
     * 获取 2FA 密码信息（account.getPassword）
     * 用于 UI 判断是否已启用 2FA、hint 等
     */
    public func getPasswordInfo(): AccountPasswordResponse {
        return getRealAuthService().getPasswordInfo()
    }

    // ==================== TelegramEngine.AccountData: Change Phone Flow ====================

    /**
     * 发送更改手机号验证码
     * account.sendChangePhoneCode
     * 成功时设置 changePhoneCodeHash、changePhoneStep=2
     */
    public func sendChangePhoneCode(phoneNumber: String) {
        this.changePhoneError = ""
        this.isLoading = true
        let phoneCopy = phoneNumber
        spawn {
            let authService = getRealAuthService()
            let resp = authService.changePhoneNumber(phoneCopy)
            launch {
                this.isLoading = false
                if (resp.phoneCodeHash.size > 0) {
                    this.changePhoneCodeHash = resp.phoneCodeHash
                    this.changePhoneStep = 2
                } else {
                    this.changePhoneError = authService.getLastError()
                }
            }
        }
    }

    /**
     * 确认更改手机号
     * account.changePhone
     * 成功时设置 changePhoneSuccess=true，更新 currentUser
     */
    public func confirmChangePhone(phoneNumber: String, phoneCodeHash: String, code: String) {
        this.changePhoneError = ""
        this.isLoading = true
        let phoneCopy = phoneNumber
        let hashCopy = phoneCodeHash
        let codeCopy = code
        spawn {
            let authService = getRealAuthService()
            let ok = authService.confirmChangePhone(phoneCopy, hashCopy, codeCopy)
            launch {
                this.isLoading = false
                if (ok) {
                    this.changePhoneSuccess = true
                    match (authService.getCurrentUser()) {
                        case Some(user) =>
                            let u = User()
                            u.id = user.id
                            u.username = user.username
                            u.displayName = if (user.lastName.size > 0) { "${user.firstName} ${user.lastName}" } else { user.firstName }
                            u.phoneNumber = user.phone
                            u.avatarText = if (user.firstName.size > 0) { user.firstName.toRuneArray()[0].toString() } else { "U" }
                            this.currentUser = Some(u)
                        case None => ()
                    }
                } else {
                    this.changePhoneError = authService.getLastError()
                }
            }
        }
    }

    /**
     * 重置更改手机号流程状态
     */
    public func resetChangePhoneFlow() {
        this.changePhoneStep = 1
        this.changePhoneCodeHash = ""
        this.changePhoneError = ""
        this.changePhoneSuccess = false
    }

    /**
     * 更新账号资料（account.updateProfile）
     */
    public func updateAccountInfo(firstName: String, lastName: String, about: String): Bool {
        return getRealAuthService().updateAccountInfo(firstName, lastName, about)
    }

    /**
     * 注册推送 Token（account.registerDevice）
     */
    public func registerPushToken(token: String, tokenType: Int32, appSandbox: Bool): Bool {
        return getRealAuthService().registerPushToken(token, tokenType, appSandbox)
    }

    /**
     * 注销推送 Token（account.unregisterDevice）
     */
    public func unregisterPushToken(token: String, tokenType: Int32): Bool {
        return getRealAuthService().unregisterPushToken(token, tokenType)
    }

    /**
     * 获取服务条款（help.getTermsOfServiceUpdate）
     */
    public func getTermsOfService(): HelpTermsOfServiceUpdateResponse {
        return getRealAuthService().getTermsOfService()
    }

    /**
     * 接受服务条款（help.acceptTermsOfService）
     */
    public func acceptTermsOfService(termsId: String): Bool {
        return getRealAuthService().acceptTermsOfService(termsId)
    }
}

/**
 * AuthViewModel 回调实现
 * 桥接 RealAuthService 的回调到 ViewModel 状态更新
 */
public class AuthViewModelCallback <: AuthServiceCallback {
    private var viewModel: AuthViewModel

    public init(viewModel!: AuthViewModel) {
        this.viewModel = viewModel
    }

    public func onAuthStateChanged(state: RealAuthState): Unit {
        let stateCopy = state
        let emailPat = getRealAuthService().getRecoveryEmailPattern()
        let waitSec = getRealAuthService().getAccountResetWaitSeconds()
        launch {
            match (stateCopy) {
                case RealAuthState.Unauthorized =>
                    this.viewModel.handleAuthStateChange(AUTH_STATE_WAIT_PHONE)
                case RealAuthState.WaitingCode =>
                    this.viewModel.isLoading = false
                    this.viewModel.authState = AUTH_STATE_WAIT_CODE
                    this.viewModel.shouldNavigateToCode = true
                case RealAuthState.WaitingSignUp =>
                    this.viewModel.isLoading = false
                    this.viewModel.authState = AUTH_STATE_WAIT_REGISTRATION
                    this.viewModel.shouldNavigateToSignUp = true
                case RealAuthState.WaitingPassword =>
                    this.viewModel.isLoading = false
                    this.viewModel.authState = AUTH_STATE_WAIT_PASSWORD
                case RealAuthState.WaitingPasswordRecovery =>
                    this.viewModel.isLoading = false
                    this.viewModel.recoveryEmailPattern = emailPat
                    this.viewModel.authState = AUTH_STATE_WAIT_PASSWORD_RECOVERY
                    this.viewModel.shouldNavigateToPasswordRecovery = true
                case RealAuthState.AwaitingAccountReset =>
                    this.viewModel.isLoading = false
                    this.viewModel.accountResetWaitSeconds = waitSec
                    this.viewModel.authState = AUTH_STATE_AWAITING_ACCOUNT_RESET
                    this.viewModel.shouldNavigateToAccountReset = true
                case RealAuthState.WaitingSetupEmail =>
                    // R1 (TC-0015 返修): 实际导航由 PhoneInputPage.cj 的发码回调直接
                    // routerPush("EmailLoginPage", ...) 完成（与 WaitingPassword 同款，
                    // 这里只同步 authState 供观察者读取，不重复触发导航）。
                    this.viewModel.isLoading = false
                    this.viewModel.authState = AUTH_STATE_WAIT_EMAIL_SETUP
                case RealAuthState.Authorized =>
                    this.viewModel.handleAuthStateChange(AUTH_STATE_READY)
                    // CALL-BG: 登录成功立即注册推送 token（AppStartup 的注册在未登录时
                    // 会跳过 registerDevice；不补这里则要等下次冷启动才注册）。
                    // 本回调已在 launch 主线程内，满足 ark_interop 线程要求。
                    getPushTokenService().initPushRegistration(false, ArrayList<Int64>())
            }
        }
    }

    public func onCodeSent(phoneCodeHash: String, codeType: SentCodeType): Unit {
        Hilog.info(0, "CjTelegram", "[AuthViewModel] Code sent successfully")
    }

    public func onAuthorized(user: UserResponse): Unit {
        let u = User()
        u.id = user.id
        u.username = user.username
        u.displayName = if (user.lastName.size > 0) { "${user.firstName} ${user.lastName}" } else { user.firstName }
        u.phoneNumber = user.phone
        u.avatarText = if (user.firstName.size > 0) { user.firstName.toRuneArray()[0].toString() } else { "U" }
        launch {
            this.viewModel.currentUser = Some(u)
            this.viewModel.isLoggedIn = true
            this.viewModel.isLoading = false
        }
    }

    public func onError(code: Int32, message: String): Unit {
        let c = code
        let m = message
        launch {
            this.viewModel.handleError(Int64(c), m)
        }
    }

    public func onPasswordRecoveryEmailSent(emailPattern: String): Unit {
        let pat = emailPattern
        launch {
            this.viewModel.recoveryEmailPattern = pat
        }
    }
}
