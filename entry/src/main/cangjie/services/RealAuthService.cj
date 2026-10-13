package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.core.storage.*
import std.collection.ArrayList
import std.math.numeric.BigInt
/**
 * 真实认证服务
 * 
 * 对应 TelegramHarmony 的 RealServiceAdapter.ets 认证部分
 * 使用 MTProto 客户端进行真实的 Telegram 认证
 */

/**
 * 认证状态
 */
public enum RealAuthState {
    | Unauthorized
    | WaitingCode
    | WaitingSignUp
    | WaitingPassword
    | WaitingPasswordRecovery
    | AwaitingAccountReset
    // R1 (TC-0015 返修): 对位 iOS SentAuthorizationCodeType.emailSetupRequired
    // (AccountState.swift:45, MTProto auth.sentCodeTypeSetUpEmailRequired#a5491dea)。
    // 服务端要求先设置登录邮箱才会真正下发手机验证码；此前该分支被压平进 WaitingCode，
    // 导致用户被送进一个永远等不到验证码的验证码屏。
    | WaitingSetupEmail
    | Authorized
}

/**
 * 认证回调
 */
public interface AuthServiceCallback {
    func onAuthStateChanged(state: RealAuthState): Unit
    func onCodeSent(phoneCodeHash: String, codeType: SentCodeType): Unit
    func onAuthorized(user: UserResponse): Unit
    func onError(code: Int32, message: String): Unit
    func onPasswordRecoveryEmailSent(emailPattern: String): Unit
}

private var _realAuthServiceInstance: Option<RealAuthService> = None

public func getRealAuthService(): RealAuthService {
    match (_realAuthServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = RealAuthService()
            _realAuthServiceInstance = Some(inst)
            return inst
    }
}

public class RealAuthService {
    private var state: RealAuthState = RealAuthState.Unauthorized
    private var phoneCodeHash: String = ""
    private var phoneNumber: String = ""
    private var callback: Option<AuthServiceCallback> = None
    private var currentUser: Option<UserResponse> = None
    private var profileChangedCallback: Option<(UserResponse) -> Unit> = None
    private var lastErrorMessage: String = ""
    private var lastErrorCode: Int32 = 0
    private var recoveryEmailPattern: String = ""
    private var accountResetWaitSeconds: Int32 = 0
    private var codeTimeoutSeconds: Int32 = 60
    // P2-013: 最近一次 sendCode 返回的验证码投递类型
    private var sentCodeType: SentCodeType = SentCodeType.Unknown
    // P2-014: 最近一次 sentCode 的 nextType（下一个可用投递方式）
    private var sentCodeNextType: AuthCodeNextType = AuthCodeNextType.NoneNext
    // 验证码位数：来自 auth.sentCode 的 sentCodeType.length（对齐 iOS 动态 codeLength）。
    // 此前 UI 写死 5 位，中国短信是 6 位无法自动提交/输满——用服务端返回的长度。
    private var sentCodeLength: Int32 = 5

    public func setCallback(callback: AuthServiceCallback) {
        this.callback = Some(callback)
    }

    public func getState(): RealAuthState {
        return this.state
    }

    public func getCurrentUser(): Option<UserResponse> {
        return this.currentUser
    }

    public func setProfileChangedCallback(callback: (UserResponse) -> Unit): Unit {
        this.profileChangedCallback = Some(callback)
    }

    public func clearProfileChangedCallback(): Unit {
        this.profileChangedCallback = None
    }

    public func applyLocalProfile(firstName: String, lastName: String, username: String): Unit {
        match (this.currentUser) {
            case Some(user) =>
                user.firstName = firstName
                user.lastName = lastName
                user.username = username
                this.currentUser = Some(user)
                match (this.profileChangedCallback) {
                    case Some(callback) => callback(user)
                    case None => ()
                }
            case None => ()
        }
    }

    /**
     * Refresh the account's own peer from the server.
     *
     * The restored self user comes from AuthStorage and can be stale when the profile changed on
     * another client while this one was not running (e.g. username removed, then set again).
     * iOS never renders Settings from a login-time snapshot: its self peer view is refreshed from
     * the server (AccountViewTracker.swift:1807 -> UpdateCachedPeerData.swift:157, whose
     * users.getFullUser result carries the self User). users.getUsers([inputUserSelf]) returns the
     * same User object. Runs a network request: call off the UI thread.
     */
    public func refreshCurrentUserFromServer(): Bool {
        let expectedId = match (this.currentUser) {
            case Some(user) => user.id
            case None => return false
        }
        try {
            let request = UsersGetUsers()
            request.ids.add(InputUserSelf())
            let data = getMTProtoClient().sendRequest(request.toBytes())
            if (data.size < 8) {
                Hilog.info(0, "CjTelegram", "[RealAuthService] self refresh: empty response")
                return false
            }
            let d = TLDeserializer(data)
            let vectorCtor = d.readUInt32()
            if (vectorCtor != TLConstructors.VECTOR) {
                Hilog.info(0, "CjTelegram", "[RealAuthService] self refresh: unexpected response 0x${UInt32ToHex(vectorCtor)}")
                return false
            }
            if (d.readInt32() < 1) { return false }
            let user = UserResponse.deserializeBoxed(d)
            if (user.isEmpty || user.id <= 0 || (expectedId > 0 && user.id != expectedId)) {
                Hilog.info(0, "CjTelegram", "[RealAuthService] self refresh: ignored user=${user.id} expected=${expectedId}")
                return false
            }
            this.applyServerSelfUser(user)
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] self refresh failed: ${e}")
            return false
        }
    }

    /**
     * updateUserName for the account's own peer. iOS AccountStateManagementUtils.swift:1510-1519
     * applies only the usernames from this update (TelegramUser.withUpdatedUsernames).
     */
    public func applySelfUsernamesUpdate(userId: Int64, usernames: ArrayList<String>, activeUsername: String): Unit {
        match (this.currentUser) {
            case Some(user) =>
                if (user.id != userId) { return }
                user.usernames = usernames
                user.username = activeUsername
                this.currentUser = Some(user)
                this.persistSelfUser(user)
                Hilog.info(0, "CjTelegram", "[RealAuthService] self usernames updated from updateUserName: username='${activeUsername}' count=${usernames.size}")
                match (this.profileChangedCallback) {
                    case Some(callback) => callback(user)
                    case None => ()
                }
            case None => ()
        }
    }

    private func applyServerSelfUser(user: UserResponse): Unit {
        var previousUsername = ""
        match (this.currentUser) {
            case Some(old) =>
                previousUsername = old.username
                // Self phone is always visible to the owner; keep the stored one if a response
                // omitted it rather than blanking the Settings header.
                if (user.phone.size == 0) { user.phone = old.phone }
                if (user.accessHash == 0) { user.accessHash = old.accessHash }
            case None => ()
        }
        this.currentUser = Some(user)
        this.persistSelfUser(user)
        Hilog.info(0, "CjTelegram", "[RealAuthService] self user refreshed id=${user.id} username='${user.username}' previous='${previousUsername}' usernames=${user.usernames.size}")
        match (this.profileChangedCallback) {
            case Some(callback) => callback(user)
            case None => ()
        }
    }

    private func persistSelfUser(user: UserResponse): Unit {
        let storage = getAuthStorage()
        match (storage.getUserData()) {
            case Some(userData) =>
                // Only write into the slot that belongs to this account (account switch races).
                if (userData.id != user.id) { return }
                userData.firstName = user.firstName
                userData.lastName = user.lastName
                userData.username = user.username
                if (user.phone.size > 0) { userData.phone = user.phone }
                userData.isPremium = user.isPremium
                storage.saveUserData(userData)
            case None => ()
        }
    }

    public func getLastError(): String {
        return this.lastErrorMessage
    }

    public func getLastErrorCode(): Int32 {
        return this.lastErrorCode
    }

    public func getRecoveryEmailPattern(): String {
        return this.recoveryEmailPattern
    }

    public func getAccountResetWaitSeconds(): Int32 {
        return this.accountResetWaitSeconds
    }

    public func getCodeTimeoutSeconds(): Int32 {
        return this.codeTimeoutSeconds
    }

    // P2-013: 获取验证码投递类型（供 CodeInputPage 渲染专属 UI）
    public func getSentCodeType(): SentCodeType {
        return this.sentCodeType
    }

    // 验证码位数（服务端返回；未知时回退 5）。CodeInputPage 用它决定格子数/自动提交。
    public func getCodeLength(): Int64 {
        if (this.sentCodeLength >= 3 && this.sentCodeLength <= 8) {
            return Int64(this.sentCodeLength)
        }
        return 5
    }

    // P2-014: 获取下一个可用投递方式（NoneNext 表示服务器未提供 nextType）
    public func getSentCodeNextType(): AuthCodeNextType {
        return this.sentCodeNextType
    }

    /**
     * 初始化 MTProto 客户端
     * 应在 spawn 中调用
     * 
     * 重要：在初始化 MTProto client 之前，先尝试从持久化存储恢复会话。
     * 这样 client.initialize() 就不会创建新的 auth key，而是使用已恢复的。
     */
    public func initializeClient(): Unit {
        Hilog.info(0, "CjTelegram", "[RealAuthService] Initializing MTProto client...")

        // 先尝试从持久化存储恢复会话到内存
        let storage = getAuthStorage()
        var restoredDcId: Int64 = -1
        if (storage.hasStoredLogin()) {
            match (storage.getSessionData()) {
                case Some(sessionData) =>
                    Hilog.info(0, "CjTelegram", "[RealAuthService] Pre-restoring session from persistent storage for DC${sessionData.dcId}")
                    let _ = SessionManager.restoreSession(sessionData.dcId)
                    restoredDcId = sessionData.dcId
                case None => ()
            }
        }

        // 使用恢复的 DC ID 初始化（避免创建新 auth key）
        let client = getMTProtoClient()

        // 注册全局"授权失效"回调（对齐 iOS Account.swift:1316 network.loggedOut）。
        // 这是 iOS MTRequestMessageService 全局 401 拦截的等价物：本仓库此前只在启动探针里
        // 判 401，探针不再负责登出后，必须由它兜住"服务端真的吊销了授权"这一路。
        // The registry is slot-scoped, so the callback must keep the identity of
        // the client that produced the 401.  During add-account, AuthStorage routes
        // auth traffic through the pending slot while the original authorized
        // account remains alive.  Authorized-only background requests can still be
        // in flight on that new client and legitimately receive
        // AUTH_KEY_UNREGISTERED before auth.signIn completes; treating that as a
        // logout clears the pending slot and makes CodeInputPage discard the code.
        let callbackSlot = storage.getActiveSlot()
        client.setAuthorizationRequiredCallback({ => this.handleServerAuthorizationRevoked(callbackSlot) })

        if (restoredDcId > 0) {
            client.initialize(specificDcId: restoredDcId)
        } else {
            client.initialize()
        }
        Hilog.info(0, "CjTelegram", "[RealAuthService] MTProto client initialized")
    }

    /**
     * 尝试恢复登录
     * 
     * 注意：initializeClient() 已经预恢复了会话到 SessionManager，
     * 这里只需要检查持久化状态并设置登录状态。
     */
    public func tryRestoreLogin(): Bool {
        let storage = getAuthStorage()
        if (storage.hasStoredLogin()) {
            match (storage.getSessionData()) {
                case Some(sessionData) =>
                    Hilog.info(0, "CjTelegram", "[RealAuthService] Restoring login state for DC${sessionData.dcId}")
                    // 会话已在 initializeClient() 中预恢复到 SessionManager
                    // 这里确保会话在内存中（如果还没有的话）
                    let _ = SessionManager.restoreSession(sessionData.dcId)

                    // 恢复登录**不做任何网络校验** —— 严格对齐 iOS。
                    //
                    // iOS Account.swift:332 accountWithId()：从 Postbox 读到
                    // AuthorizedAccountState 就直接 return .authorized(Account(...))，
                    // 登录态是纯磁盘状态，从不以一次网络往返为前提。
                    //
                    // 此处原有一次 updates.getState 探针，其判定曾把网络故障误当授权失效
                    // 而抹除凭据（已修）；即便修正为三态后仍有两个问题：
                    //   1. 弱网/断网时白白阻塞一个 REQUEST_TIMEOUT(60s) 才放行 UI；
                    //   2. 它对"授权是否有效"其实给不出比后续真实请求更多的信息。
                    // 授权失效由服务端 401 经 MTProtoClient.authorizationRequiredCallback
                    // 全局兜底（对齐 iOS MTRequestMessageService.m:846 的每响应拦截），
                    // 无需在启动路径上额外探测。
                    this.state = RealAuthState.Authorized

                    // 恢复用户信息
                    match (storage.getUserData()) {
                        case Some(userData) =>
                            let user = UserResponse()
                            user.id = userData.id
                            user.firstName = userData.firstName
                            user.lastName = userData.lastName
                            user.username = userData.username
                            user.phone = userData.phone
                            user.isPremium = userData.isPremium
                            this.currentUser = Some(user)
                            Hilog.info(0, "CjTelegram", "[RealAuthService] User restored: ${userData.firstName}")
                        case None => ()
                    }

                    match (this.callback) {
                        case Some(cb) => cb.onAuthStateChanged(RealAuthState.Authorized)
                        case None => ()
                    }
                    return true
                case None => ()
            }
        }
        return false
    }

    /**
     * 服务端确证授权失效时的处理（由 MTProtoClient 在收到 401 rpc_error 时回调）。
     *
     * 对齐 iOS Account.swift:1316 `network.loggedOut = { ... _loggedOut.set(true) ... }`。
     * 幂等：多条 in-flight 请求可能各自收到 401，只有第一次真正执行清理。
     */
    private func handleServerAuthorizationRevoked(callbackSlot: Int32): Unit {
        let storage = getAuthStorage()
        let pendingSlot = storage.getPendingAuthSlot()
        if (pendingSlot == callbackSlot) {
            // An auth record is intentionally unauthorized until auth.signIn
            // succeeds.  A 401 from an unrelated authorized-only request on this
            // client must not destroy the in-progress login transaction.
            Hilog.info(0, "CjTelegram",
                "[RealAuthService] Ignored 401 for pending auth slot=${callbackSlot}")
            return
        }
        if (storage.getActiveSlot() != callbackSlot) {
            // The response belongs to a client that ceased being active while the
            // request was in flight (for example, the just-finished/cancelled auth
            // slot).  Never apply it to the currently displayed account.
            Hilog.info(0, "CjTelegram",
                "[RealAuthService] Ignored stale 401 for inactive slot=${callbackSlot}")
            return
        }
        var alreadyUnauthorized = false
        match (this.state) {
            case RealAuthState.Unauthorized => alreadyUnauthorized = true
            case _ => ()
        }
        if (alreadyUnauthorized) {
            // 已经是未授权态，无需重复清理（多条 in-flight 请求会各自收到 401）
            return
        }
        Hilog.info(0, "CjTelegram",
            "[RealAuthService] Server-confirmed 401 → logging out (iOS network.loggedOut semantics)")
        this.clearInvalidRestoredLogin()
    }

    /** Reinstall authorization ownership on a client created by account switch. */
    public func bindActiveAccountClient(): Unit {
        let storage = getAuthStorage()
        let callbackSlot = storage.getActiveSlot()
        getMTProtoClient().setAuthorizationRequiredCallback({ =>
            this.handleServerAuthorizationRevoked(callbackSlot)
        })
        Hilog.info(0, "CjTelegram",
            "[RealAuthService] authorization callback rebound for slot=${callbackSlot}")
    }

    private func clearInvalidRestoredLogin(): Unit {
        this.state = RealAuthState.Unauthorized
        this.currentUser = None
        this.phoneCodeHash = ""

        let storage = getAuthStorage()
        storage.clearAll()
        // ic_presentation_reset_on_logout: AuthStorage.clearAll() wipes the per-slot
        // appearance keys and telegram_themes_cache, but core/storage/AppTheme.cj's
        // in-process _currentPresentation module cache is not itself told — without this,
        // a returning session keeps rendering the previous account's presentation snapshot.
        resetPresentation()
        SessionManager.clearAllSessions()
        resetGlobalClient()

        match (this.callback) {
            case Some(cb) => cb.onAuthStateChanged(RealAuthState.Unauthorized)
            case None => ()
        }
    }

    /**
     * 发送验证码
     */
    public func sendCode(phoneNumber: String) {
        this.phoneNumber = phoneNumber
        this.lastErrorMessage = ""
        this.lastErrorCode = 0
        Hilog.info(0, "CjTelegram", "[RealAuthService] Sending code to ${phoneNumber}...")

        let client = getMTProtoClient()
        if (!client.hasAuthKey()) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] MTProto client has no auth key before sendCode; initializing fresh auth key")
            this.initializeClient()
        }
        Hilog.info(0, "CjTelegram", "[RealAuthService] MTProto client ready, hasAuthKey: ${client.hasAuthKey()}")

        // 构造 auth.sendCode 请求
        let sendCode = AuthSendCode()
        sendCode.phoneNumber = phoneNumber
        Hilog.info(0, "CjTelegram", "[RealAuthService] AuthSendCode constructorId: ${sendCode.getConstructorId()}")

        let requestData = sendCode.toBytes()
        Hilog.info(0, "CjTelegram", "[RealAuthService] Request data size: ${requestData.size}")
        let responseData = client.sendRequest(requestData)
        Hilog.info(0, "CjTelegram", "[RealAuthService] Response data size: ${responseData.size}")

        if (responseData.size == 0) {
            notifyError(500, "No response from server")
            return
        }

        // 检查是否需要 DC 迁移
        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()

            // 处理 PHONE_MIGRATE_X
            if (errorMessage.startsWith("PHONE_MIGRATE_") || errorMessage.startsWith("NETWORK_MIGRATE_")) {
                let dcIdStr = extractDCId(errorMessage)
                Hilog.info(0, "CjTelegram", "[RealAuthService] === DC Migration Required ===")
                Hilog.info(0, "CjTelegram", "[RealAuthService] Migrating to DC${dcIdStr}...")
                client.migrateToDC(dcIdStr)
                Hilog.info(0, "CjTelegram", "[RealAuthService] Migration complete, retrying sendCode...")

                // 重试 sendCode
                let retryResponse = client.sendRequest(requestData)
                Hilog.info(0, "CjTelegram", "[RealAuthService] Retry response size: ${retryResponse.size}")
                if (retryResponse.size > 0) {
                    handleSendCodeResponse(retryResponse)
                } else {
                    notifyError(Int32(errorCode), "DC migration succeeded but retry failed")
                }
                return
            }

            notifyError(Int32(errorCode), errorMessage)
            return
        }

        // 回退到响应开头重新解析
        handleSendCodeResponse(responseData)
    }

    private func handleSendCodeResponse(data: Array<Byte>) {
        let response = AuthSentCodeResponse.deserialize(data)
        this.phoneCodeHash = response.phoneCodeHash
        if (response.timeout > 0) {
            this.codeTimeoutSeconds = response.timeout
        }
        // P2-013: 保存投递类型供 CodeInputPage 读取
        this.sentCodeType = response.codeType
        // 保存验证码位数（sentCodeType.length）——中国短信 6 位，UI 据此渲染格子/自动提交
        this.sentCodeLength = response.codeLength
        // P2-014: 保存下一个投递方式（供切换验证方式按钮使用）
        this.sentCodeNextType = response.nextType

        // R1 (TC-0015 返修): SetUpEmailRequired 分流 —— 服务端还没真的发出手机验证码，
        // 必须先走邮箱设置屏。其余投递类型维持原 WaitingCode 路径不变（无净退化）。
        if (this.sentCodeType == SentCodeType.SetUpEmailRequired) {
            this.state = RealAuthState.WaitingSetupEmail
        } else {
            this.state = RealAuthState.WaitingCode
        }
        Hilog.info(0, "CjTelegram", "[RealAuthService] Code sent, hash: ${response.phoneCodeHash}, type: ${this.sentCodeType.deliveryDescription()}, nextType: ${this.sentCodeNextType.switchButtonLabel()}")

        match (this.callback) {
            case Some(cb) =>
                cb.onCodeSent(response.phoneCodeHash, response.codeType)
                cb.onAuthStateChanged(this.state)
            case None => ()
        }
    }

    /**
     * P2-014: 切换验证方式 — 调用 auth.resendCode 请求切换到 nextType 投递方式
     *
     * iOS 逻辑: resendAuthorizationCode 当 nextType != nil 时调用 auth.resendCode，
     * 服务端返回新的 auth.sentCode，其 type 即为新的投递方式。
     *
     * 区别于 sendCode（重发同方式）：resendCode 明确告知服务端切换到 nextType。
     * 返回 true 表示成功，RealAuthService.sentCodeType/nextType 已更新。
     */
    public func resendCodeToSwitch(): Bool {
        Hilog.info(0, "CjTelegram", "[RealAuthService] resendCodeToSwitch: current nextType=${this.sentCodeNextType.switchButtonLabel()}")
        if (this.sentCodeNextType == AuthCodeNextType.NoneNext) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] resendCodeToSwitch: no nextType available, abort")
            return false
        }
        if (this.phoneNumber.size == 0 || this.phoneCodeHash.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] resendCodeToSwitch: no phone/hash, abort")
            return false
        }

        let client = getMTProtoClient()
        let req = AuthResendCode()
        req.phoneNumber = this.phoneNumber
        req.phoneCodeHash = this.phoneCodeHash

        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            notifyError(500, "No response from auth.resendCode")
            return false
        }

        let checkD = TLDeserializer(data)
        let checkCtor = checkD.readUInt32()
        if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
            let errorCode = checkD.readInt32()
            let errorMessage = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] resendCodeToSwitch error: ${errorCode} ${errorMessage}")
            notifyError(Int32(errorCode), errorMessage)
            return false
        }

        handleSendCodeResponse(data)
        Hilog.info(0, "CjTelegram", "[RealAuthService] resendCodeToSwitch: switched to ${this.sentCodeType.deliveryDescription()}")
        return true
    }

    /**
     * 验证码登录
     */
    public func verifyCode(code: String) {
        Hilog.info(0, "CjTelegram", "[RealAuthService] Verifying code...")
        this.lastErrorMessage = ""
        this.lastErrorCode = 0

        let client = getMTProtoClient()

        let signIn = AuthSignIn()
        signIn.phoneNumber = this.phoneNumber
        signIn.phoneCodeHash = this.phoneCodeHash
        signIn.phoneCode = code

        let requestData = signIn.toBytes()
        let responseData = client.sendRequest(requestData)
        Hilog.info(0, "CjTelegram", "[RealAuthService] verifyCode response size: ${responseData.size}")

        if (responseData.size == 0) {
            notifyError(500, "No response from server")
            return
        }

        // 检查是否为 RPC 错误
        let checkD = TLDeserializer(responseData)
        let checkConstructor = checkD.readUInt32()
        if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
            let errorCode = checkD.readInt32()
            let errorMessage = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] verifyCode RPC Error: ${errorCode} - ${errorMessage}")

            // SESSION_PASSWORD_NEEDED: 账号开启了 2FA，需要输入密码
            if (errorMessage == "SESSION_PASSWORD_NEEDED") {
                Hilog.info(0, "CjTelegram", "[RealAuthService] 2FA password required")
                this.state = RealAuthState.WaitingPassword
                match (this.callback) {
                    case Some(cb) => cb.onAuthStateChanged(RealAuthState.WaitingPassword)
                    case None => ()
                }
                return
            }

            // USER_MIGRATE_X: 该账号的 home DC 不是当前连接的 DC（常见于非该 DC 注册号段，
            // 如 +44 英国号段 home DC 通常是 DC4/DC5，而登录码请求默认走 DC1）。
            // 必须先 migrateToDC(X)，在新 DC 上重新创建 auth key，再在新 DC 上重试
            // auth.signIn —— 这样最终持久化的 authKey 才是"已在服务端授权"的那把，
            // 避免后续 messages.getDialogs / updates.getState 收到 401 AUTH_KEY_UNREGISTERED。
            // 参照 sendCode() 中已验证可用的 PHONE_MIGRATE_/NETWORK_MIGRATE_ 处理模式（RealAuthService.cj:221）。
            if (errorMessage.startsWith("USER_MIGRATE_")) {
                let dcIdStr = extractDCId(errorMessage)
                Hilog.info(0, "CjTelegram", "[RealAuthService] === USER_MIGRATE: home DC is DC${dcIdStr} ===")
                client.migrateToDC(dcIdStr)
                Hilog.info(0, "CjTelegram", "[RealAuthService] Migration to DC${dcIdStr} complete, retrying auth.signIn...")

                let retryResponse = client.sendRequest(requestData)
                Hilog.info(0, "CjTelegram", "[RealAuthService] verifyCode retry response size: ${retryResponse.size}")
                if (retryResponse.size == 0) {
                    notifyError(Int32(errorCode), "DC migration succeeded but sign-in retry failed")
                    return
                }
                handleVerifyCodeResponse(retryResponse)
                return
            }

            notifyError(Int32(errorCode), errorMessage)
            return
        }

        handleVerifyCodeResponse(responseData)
    }

    /**
     * 解析 auth.signIn 正常响应（非 RPC_ERROR 分支），供首次请求和 USER_MIGRATE_X 重试共用。
     */
    private func handleVerifyCodeResponse(responseData: Array<Byte>) {
        let authResponse = AuthAuthorizationResponse.deserialize(responseData)

        if (authResponse.signUpRequired) {
            this.state = RealAuthState.WaitingSignUp
            match (this.callback) {
                case Some(cb) => cb.onAuthStateChanged(RealAuthState.WaitingSignUp)
                case None => ()
            }
            return
        }

        match (authResponse.user) {
            case Some(user) =>
                this.currentUser = Some(user)
                this.state = RealAuthState.Authorized
                saveAuthData(user)
                match (this.callback) {
                    case Some(cb) =>
                        cb.onAuthorized(user)
                        cb.onAuthStateChanged(RealAuthState.Authorized)
                    case None => ()
                }
                Hilog.info(0, "CjTelegram", "[RealAuthService] Authorized as ${user.firstName}")
            case None =>
                notifyError(500, "No user in authorization response")
        }
    }

    /**
     * 注册新用户
     */
    public func signUp(firstName: String, lastName: String) {
        Hilog.info(0, "CjTelegram", "[RealAuthService] Signing up...")
        this.lastErrorMessage = ""
        this.lastErrorCode = 0

        let client = getMTProtoClient()

        let signup = AuthSignUp()
        signup.phoneNumber = this.phoneNumber
        signup.phoneCodeHash = this.phoneCodeHash
        signup.firstName = firstName
        signup.lastName = lastName

        let responseData = client.sendRequest(signup.toBytes())
        Hilog.info(0, "CjTelegram", "[RealAuthService] signUp response size: ${responseData.size}")

        if (responseData.size == 0) {
            notifyError(500, "No response from server")
            return
        }

        // 检查是否为 RPC 错误
        let checkD = TLDeserializer(responseData)
        let checkConstructor = checkD.readUInt32()
        if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
            let errorCode = checkD.readInt32()
            let errorMessage = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] signUp RPC Error: ${errorCode} - ${errorMessage}")
            notifyError(Int32(errorCode), errorMessage)
            return
        }

        let authResponse = AuthAuthorizationResponse.deserialize(responseData)
        match (authResponse.user) {
            case Some(user) =>
                this.currentUser = Some(user)
                this.state = RealAuthState.Authorized
                saveAuthData(user)
                match (this.callback) {
                    case Some(cb) =>
                        cb.onAuthorized(user)
                        cb.onAuthStateChanged(RealAuthState.Authorized)
                    case None => ()
                }
            case None =>
                notifyError(500, "SignUp failed")
        }
    }

    /**
     * 退出登录
     */
    public func logout() {
        Hilog.info(0, "CjTelegram", "[RealAuthService] Logging out...")

        let client = getMTProtoClient()
        let logoutReq = AuthLogOut()
        let _ = client.sendRequest(logoutReq.toBytes())

        this.state = RealAuthState.Unauthorized
        this.currentUser = None
        this.phoneCodeHash = ""

        // 清除存储
        let storage = getAuthStorage()
        storage.clearAll()
        // ic_presentation_reset_on_logout: see clearInvalidRestoredLogin() above for why.
        resetPresentation()
        SessionManager.clearAllSessions()

        match (this.callback) {
            case Some(cb) => cb.onAuthStateChanged(RealAuthState.Unauthorized)
            case None => ()
        }
    }

    /**
     * 2FA 密码验证 (SRP 6a)
     * 
     * 流程:
     * 1. 调用 account.getPassword 获取 SRP 参数
     * 2. 使用 SRP 6a 协议计算 InputCheckPasswordSRP
     * 3. 调用 auth.checkPassword 完成登录
     */
    public func checkPassword(password: String) {
        Hilog.info(0, "CjTelegram", "[RealAuthService] checkPassword: starting 2FA verification...")
        this.lastErrorMessage = ""
        this.lastErrorCode = 0

        let client = getMTProtoClient()

        // Step 1: account.getPassword
        Hilog.info(0, "CjTelegram", "[RealAuthService] Calling account.getPassword...")
        let getPasswordReq = AccountGetPassword()
        let getPasswordData = client.sendRequest(getPasswordReq.toBytes())

        if (getPasswordData.size == 0) {
            notifyError(500, "No response from account.getPassword")
            return
        }

        // Check for RPC error
        let checkD = TLDeserializer(getPasswordData)
        let checkCtor = checkD.readUInt32()
        if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
            let errorCode = checkD.readInt32()
            let errorMessage = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] account.getPassword error: ${errorCode} ${errorMessage}")
            notifyError(Int32(errorCode), errorMessage)
            return
        }

        let passwordInfo = AccountPasswordResponse.deserialize(getPasswordData)
        if (!passwordInfo.hasPassword) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] Account does not have 2FA password")
            notifyError(400, "Account does not have 2FA enabled")
            return
        }

        if (passwordInfo.algoP.size == 0 || passwordInfo.srpB.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] Missing SRP parameters")
            notifyError(400, "Invalid SRP parameters from server")
            return
        }

        // Step 2: SRP 6a computation
        Hilog.info(0, "CjTelegram", "[RealAuthService] Computing SRP...")
        let srpResult = computeSRP(
            password,
            passwordInfo.algoG,
            passwordInfo.algoP,
            passwordInfo.algoSalt1,
            passwordInfo.algoSalt2,
            passwordInfo.srpB,
            passwordInfo.srpId
        )

        if (srpResult.srpA.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] SRP computation failed")
            notifyError(500, "SRP computation failed")
            return
        }

        // Step 3: auth.checkPassword
        Hilog.info(0, "CjTelegram", "[RealAuthService] Calling auth.checkPassword...")
        let checkPasswordReq = AuthCheckPassword()
        checkPasswordReq.password = srpResult

        let responseData = client.sendRequest(checkPasswordReq.toBytes())
        if (responseData.size == 0) {
            notifyError(500, "No response from auth.checkPassword")
            return
        }

        // Check for RPC error
        let respD = TLDeserializer(responseData)
        let respCtor = respD.readUInt32()
        if (respCtor == TLConstructors.RPC_ERROR || respCtor == 0x2144ca19) {
            let errorCode = respD.readInt32()
            let errorMessage = respD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] auth.checkPassword error: ${errorCode} ${errorMessage}")
            notifyError(Int32(errorCode), errorMessage)
            return
        }

        // Parse auth.Authorization
        let authResponse = AuthAuthorizationResponse.deserialize(responseData)
        match (authResponse.user) {
            case Some(user) =>
                this.currentUser = Some(user)
                this.state = RealAuthState.Authorized
                saveAuthData(user)
                match (this.callback) {
                    case Some(cb) =>
                        cb.onAuthorized(user)
                        cb.onAuthStateChanged(RealAuthState.Authorized)
                    case None => ()
                }
                Hilog.info(0, "CjTelegram", "[RealAuthService] 2FA auth successful: ${user.firstName}")
            case None =>
                notifyError(500, "No user in 2FA authorization response")
        }
    }

    /**
     * SRP 6a 计算
     * 
     * Telegram 使用 passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow:
     * 
     * H(data) = SHA256(data)
     * SH(data, salt) = H(salt | data | salt)
     * PH1(password, salt1, salt2) = SH(SH(password, salt1), salt2)
     * PH2(password, salt1, salt2) = SH(PBKDF2(PH1, salt1, 100000), salt2)
     * 
     * x = PH2(password, salt1, salt2)
     * v = pow(g, x) mod p
     * k = H(p | g_padded)
     * 
     * a = random 256 bytes (private key)
     * g_a = pow(g, a) mod p
     * u = H(g_a | g_b)
     * 
     * k_v = k * v mod p
     * t = (g_b - k_v) mod p
     * s_a = pow(t, a + u*x) mod p
     * k_a = H(s_a)
     * 
     * M1 = H(H(p) XOR H(g_padded) | H(salt1) | H(salt2) | g_a | g_b | k_a)
     */
    private func computeSRP(password: String, g: Int32, p: Array<Byte>, salt1: Array<Byte>, salt2: Array<Byte>, srpB: Array<Byte>, srpId: Int64): InputCheckPasswordSRP {
        let result = InputCheckPasswordSRP()
        result.srpId = srpId

        let passwordBytes = stringToUtf8(password)
        let pLen = p.size

        // SH(data, salt) = SHA256(salt | data | salt)
        // PH1 = SH(SH(password, salt1), salt2)
        let sh1 = SHA256.hash(ByteUtils.concat3(salt1, passwordBytes, salt1))
        let ph1 = SHA256.hash(ByteUtils.concat3(salt2, sh1, salt2))

        // PBKDF2-HMAC-SHA512(PH1, salt1, 100000) → 64 bytes
        Hilog.info(0, "CjTelegram", "[SRP] Starting PBKDF2 with 100000 iterations...")
        let pbkdf2Result = PBKDF2SHA512.derive(ph1, salt1, 100000, 64)
        Hilog.info(0, "CjTelegram", "[SRP] PBKDF2 complete")

        // PH2 = SH(pbkdf2Result, salt2) = SHA256(salt2 | pbkdf2Result | salt2)
        let ph2 = SHA256.hash(ByteUtils.concat3(salt2, pbkdf2Result, salt2))

        // x = PH2
        let x = ph2

        // g as padded bytes (256 bytes, big-endian)
        let gPadded = Array<Byte>(pLen, repeat: 0)
        gPadded[pLen - 1] = UInt8(g & 0xFF)
        if (g > 255) {
            gPadded[pLen - 2] = UInt8((g >> 8) & 0xFF)
        }

        // k = H(p | g_padded)
        let k = SHA256.hash(ByteUtils.concat2(p, gPadded))

        // a = random 256 bytes (private key)
        let a = ByteUtils.randomBytes(pLen)

        // g_a = pow(g, a) mod p
        let gA = BigIntMath.modPow(gPadded, a, p)

        // g_b = srpB
        let gB = srpB

        // u = H(g_a | g_b)
        let u = SHA256.hash(ByteUtils.concat2(gA, gB))

        // SRP calculation using BigInt
        let pBig = BigIntMath.bytesToBigInt(p)
        let gBBig = BigIntMath.bytesToBigInt(gB)
        let kBig = BigIntMath.bytesToBigInt(k)
        let xBig = BigIntMath.bytesToBigInt(x)
        let aBig = BigIntMath.bytesToBigInt(a)
        let uBig = BigIntMath.bytesToBigInt(u)

        // v = pow(g, x) mod p
        let vBig = BigIntMath.bytesToBigInt(gPadded).modPow(xBig, m: pBig)

        // k_v = (k * v) mod p
        let kvBig = (kBig * vBig) % pBig

        // t = (g_b - k_v) mod p ; if < 0 add p
        var tBig = gBBig - kvBig
        if (tBig < BigInt(0)) {
            tBig = tBig + pBig
        }
        tBig = tBig % pBig

        // s_a = pow(t, a + u*x) mod p
        let auxBig = aBig + uBig * xBig
        let sABig = tBig.modPow(auxBig, m: pBig)

        // k_a = H(s_a)
        let sABytes = BigIntMath.bigIntToBytes(sABig, pLen)
        let kA = SHA256.hash(sABytes)

        // M1 = H( H(p) XOR H(g_padded) | H(salt1) | H(salt2) | g_a | g_b | k_a )
        let hP = SHA256.hash(p)
        let hG = SHA256.hash(gPadded)
        let hPxorG = ByteUtils.xor(hP, hG)
        let hSalt1 = SHA256.hash(salt1)
        let hSalt2 = SHA256.hash(salt2)

        let m1Input = ArrayList<Array<Byte>>()
        m1Input.add(hPxorG)
        m1Input.add(hSalt1)
        m1Input.add(hSalt2)
        m1Input.add(gA)
        m1Input.add(gB)
        m1Input.add(kA)
        let m1Data = ByteUtils.concat(m1Input)
        let m1 = SHA256.hash(m1Data)

        result.srpA = gA
        result.srpM1 = m1

        Hilog.info(0, "CjTelegram", "[SRP] Computation complete: A=${gA.size}B, M1=${m1.size}B")
        return result
    }

    /**
     * 将字符串转为 UTF-8 字节数组
     */
    private func stringToUtf8(s: String): Array<Byte> {
        let runes = s.toRuneArray()
        let bytes = ArrayList<Byte>()
        for (r in runes) {
            let code = UInt32(r)
            if (code < 0x80) {
                bytes.add(UInt8(code))
            } else if (code < 0x800) {
                bytes.add(UInt8(0xC0 | (code >> 6)))
                bytes.add(UInt8(0x80 | (code & 0x3F)))
            } else if (code < 0x10000) {
                bytes.add(UInt8(0xE0 | (code >> 12)))
                bytes.add(UInt8(0x80 | ((code >> 6) & 0x3F)))
                bytes.add(UInt8(0x80 | (code & 0x3F)))
            } else {
                bytes.add(UInt8(0xF0 | (code >> 18)))
                bytes.add(UInt8(0x80 | ((code >> 12) & 0x3F)))
                bytes.add(UInt8(0x80 | ((code >> 6) & 0x3F)))
                bytes.add(UInt8(0x80 | (code & 0x3F)))
            }
        }
        let result = Array<Byte>(bytes.size, repeat: 0)
        for (i in 0..bytes.size) {
            result[i] = bytes[i]
        }
        return result
    }

    // ==================== Phase P4-6: 2FA 设置辅助方法 ====================

    /**
     * 获取当前 2FA 密码参数
     * 返回 AccountPasswordResponse（含 SRP 参数、hint、hasPassword 等）
     */
    public func getPasswordInfo(): AccountPasswordResponse {
        let client = getMTProtoClient()
        let req = AccountGetPassword()
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            return AccountPasswordResponse()
        }
        // Check RPC error
        if (data.size >= 4) {
            let checkD = TLDeserializer(data)
            let checkCtor = checkD.readUInt32()
            if (checkCtor == 0x2144ca19) {
                return AccountPasswordResponse()
            }
        }
        return AccountPasswordResponse.deserialize(data)
    }

    /**
     * 计算新密码的 verifier (v = g^x mod p)
     * 用于 account.updatePasswordSettings 的 new_password_hash 字段
     */
    public func computeNewPasswordHash(password: String, g: Int32, p: Array<Byte>, salt1: Array<Byte>, salt2: Array<Byte>): Array<Byte> {
        let passwordBytes = stringToUtf8(password)
        let pLen = p.size

        // SH(data, salt) = SHA256(salt | data | salt)
        // PH1 = SH(SH(password, salt1), salt2)
        let sh1 = SHA256.hash(ByteUtils.concat3(salt1, passwordBytes, salt1))
        let ph1 = SHA256.hash(ByteUtils.concat3(salt2, sh1, salt2))

        // PBKDF2-HMAC-SHA512(PH1, salt1, 100000) → 64 bytes
        Hilog.info(0, "CjTelegram", "[2FA-Settings] Computing PBKDF2 for new password...")
        let pbkdf2Result = PBKDF2SHA512.derive(ph1, salt1, 100000, 64)

        // PH2 = SH(pbkdf2Result, salt2)
        let x = SHA256.hash(ByteUtils.concat3(salt2, pbkdf2Result, salt2))

        // g_padded
        let gPadded = Array<Byte>(pLen, repeat: 0)
        gPadded[pLen - 1] = UInt8(g & 0xFF)
        if (g > 255) {
            gPadded[pLen - 2] = UInt8((g >> 8) & 0xFF)
        }

        // v = g^x mod p (the verifier)
        let v = BigIntMath.modPow(gPadded, x, p)
        Hilog.info(0, "CjTelegram", "[2FA-Settings] New password hash computed: ${v.size} bytes")
        return v
    }

    /**
     * 计算当前密码的 SRP 证明（用于修改/删除密码时验证当前密码）
     */
    public func computeCurrentPasswordSRP(password: String): InputCheckPasswordSRP {
        let info = this.getPasswordInfo()
        if (!info.hasPassword) {
            return InputCheckPasswordSRP()
        }
        return this.computeSRP(
            password,
            info.algoG,
            info.algoP,
            info.algoSalt1,
            info.algoSalt2,
            info.srpB,
            info.srpId
        )
    }

    // ==================== Auth Transfer (QR Login) ====================

    /**
     * 导出登录 Token（用于 QR 码登录）
     * auth.exportLoginToken
     * 返回 token 字节数组，空表示失败；kind="migrateTo" 时需迁移 DC
     */
    public func exportLoginToken(exceptIds: ArrayList<Int64>): AuthLoginTokenResponse {
        let client = getMTProtoClient()
        let req = AuthExportLoginToken()
        req.exceptIds = exceptIds
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return AuthLoginTokenResponse()
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return AuthLoginTokenResponse()
        }
        return AuthLoginTokenResponse.deserialize(data)
    }

    /**
     * 接受扫描的登录 Token（QR 扫码后调用 auth.importLoginToken）
     * 扫码方调用此方法，传入从 QR 解码的 token 字节
     * @return true 表示登录成功
     */
    public func acceptLoginToken(token: Array<Byte>): Bool {
        let resp = this.importLoginToken(token)
        return resp.kind == "success"
    }

    /**
     * 完成 QR 登录（轮询 exportLoginToken 收到 loginTokenSuccess 时调用）
     * 保存会话、更新状态、通知回调
     */
    public func completeQrLogin(user: UserResponse): Unit {
        this.currentUser = Some(user)
        this.state = RealAuthState.Authorized
        saveAuthData(user)
        match (this.callback) {
            case Some(cb) =>
                cb.onAuthorized(user)
                cb.onAuthStateChanged(RealAuthState.Authorized)
            case None => ()
        }
        Hilog.info(0, "CjTelegram", "[RealAuthService] QR login complete: ${user.firstName}")
    }

    /**
     * 导入登录 Token（QR 扫码后 DC 不匹配时重定向用）
     * auth.importLoginToken
     */
    public func importLoginToken(token: Array<Byte>): AuthLoginTokenResponse {
        let client = getMTProtoClient()
        let req = AuthImportLoginToken()
        req.token = token
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return AuthLoginTokenResponse()
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return AuthLoginTokenResponse()
        }
        return AuthLoginTokenResponse.deserialize(data)
    }

    // ==================== Two-Step Recovery Email (resend) ====================

    /**
     * 重新发送两步验证恢复邮箱验证码
     * account.resendPasswordEmail
     */
    public func resendPasswordEmail(): Bool {
        let client = getMTProtoClient()
        let req = AccountResendPasswordEmail()
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return false
        }
        return ctor == TLConstructors.BOOL_TRUE
    }

    // ==================== Two-Step Verification: getTmpPassword ====================

    /**
     * 获取临时支付密码
     * account.getTmpPassword — 需先通过 SRP 验证当前 2FA 密码
     * @param period 有效期秒数，60–86400
     */
    public func getTmpPassword(password: String, period: Int32): AccountTmpPasswordResponse {
        let srp = this.computeCurrentPasswordSRP(password)
        if (srp.srpA.size == 0) {
            return AccountTmpPasswordResponse()
        }
        let client = getMTProtoClient()
        let req = AccountGetTmpPassword()
        req.password = srp
        req.period = if (period >= 60 && period <= 86400) { period } else { 86400 }
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return AccountTmpPasswordResponse()
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return AccountTmpPasswordResponse()
        }
        return AccountTmpPasswordResponse.deserialize(data)
    }

    // ==================== Phase P4-PasswordSetup: Reset / Decline / Confirm Email ====================

    /**
     * account.resetPassword — 发起 2FA 密码重置（需已登录）
     * 返回: ok | requestedWait(until_date) | failedWait(retry_date)
     */
    public func resetPassword(): AccountResetPasswordResponse {
        let client = getMTProtoClient()
        let req = AccountResetPassword()
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return AccountResetPasswordResponse()
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] resetPassword RPC error: ${msg}")
            return AccountResetPasswordResponse()
        }
        let resp = AccountResetPasswordResponse.deserialize(data)
        Hilog.info(0, "CjTelegram", "[RealAuthService] resetPassword result")
        return resp
    }

    /**
     * account.declinePasswordReset — 取消待处理的 2FA 密码重置
     */
    public func declinePasswordReset(): Bool {
        let client = getMTProtoClient()
        let req = AccountDeclinePasswordReset()
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return false
        }
        return ctor == 0x997275b5
    }

    /**
     * account.confirmPasswordEmail — 用邮件验证码确认恢复邮箱
     */
    public func confirmPasswordEmail(code: String): Bool {
        let client = getMTProtoClient()
        let req = AccountConfirmPasswordEmail()
        req.code = code
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            this.lastErrorMessage = d.readString()
            this.lastErrorCode = 400
            return false
        }
        return ctor == 0x997275b5
    }

    /**
     * auth.requestPasswordRecovery — 请求恢复码（仅当用户未登录且已设置恢复邮箱时）
     * 成功时存储 email_pattern 到 recoveryEmailPattern，可通过 getRecoveryEmailPattern() 获取
     */
    public func requestPasswordRecovery(): Bool {
        let client = getMTProtoClient()
        let req = AuthRequestPasswordRecovery()
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            notifyError(Int32(errorCode), errorMessage)
            return false
        }
        let resp = AuthPasswordRecoveryResponse.deserialize(data)
        this.recoveryEmailPattern = resp.emailPattern
        this.state = RealAuthState.WaitingPasswordRecovery
        match (this.callback) {
            case Some(cb) =>
                cb.onPasswordRecoveryEmailSent(resp.emailPattern)
                cb.onAuthStateChanged(RealAuthState.WaitingPasswordRecovery)
            case None => ()
        }
        return resp.emailPattern.size > 0
    }

    /**
     * auth.recoverPassword — 用恢复码重置 2FA 密码（用户未登录时）
     */
    public func recoverPassword(code: String): Bool {
        this.lastErrorMessage = ""
        this.lastErrorCode = 0
        let client = getMTProtoClient()
        let req = AuthRecoverPassword()
        req.code = code
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            notifyError(500, "No response from auth.recoverPassword")
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            notifyError(Int32(errorCode), errorMessage)
            return false
        }
        let authResp = AuthAuthorizationResponse.deserialize(data)
        match (authResp.user) {
            case Some(user) =>
                this.currentUser = Some(user)
                this.state = RealAuthState.Authorized
                saveAuthData(user)
                match (this.callback) {
                    case Some(cb) =>
                        cb.onAuthorized(user)
                        cb.onAuthStateChanged(RealAuthState.Authorized)
                    case None => ()
                }
                return true
            case None => return false
        }
    }

    // ==================== TelegramEngine.AccountData: Change Phone, Profile, Push, ToS ====================

    /**
     * 更改手机号 - 发送验证码
     * account.sendChangePhoneCode
     * @return AuthSentCodeResponse，phoneCodeHash 用于 confirmChangePhone
     */
    public func changePhoneNumber(phoneNumber: String): AuthSentCodeResponse {
        let client = getMTProtoClient()
        let req = AccountSendChangePhoneCode()
        req.phoneNumber = phoneNumber
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return AuthSentCodeResponse()
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            this.lastErrorMessage = d.readString()
            return AuthSentCodeResponse()
        }
        return AuthSentCodeResponse.deserialize(data)
    }

    /**
     * 更改手机号 - 确认验证码
     * account.changePhone
     * @return true 成功，会更新 currentUser 和 AuthStorage
     */
    public func confirmChangePhone(phoneNumber: String, phoneCodeHash: String, code: String): Bool {
        let client = getMTProtoClient()
        let req = AccountChangePhone()
        req.phoneNumber = phoneNumber
        req.phoneCodeHash = phoneCodeHash
        req.phoneCode = code
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            this.lastErrorMessage = d.readString()
            return false
        }
        let user = UserResponse.deserializeWithConstructor(ctor, d)
        this.currentUser = Some(user)
        let storage = getAuthStorage()
        match (storage.getUserData()) {
            case Some(userData) =>
                userData.phone = phoneNumber
                storage.saveUserData(userData)
            case None => ()
        }
        return true
    }

    /**
     * 更新账号资料（姓名、bio）
     * account.updateProfile
     */
    public func updateAccountInfo(firstName: String, lastName: String, about: String): Bool {
        let client = getMTProtoClient()
        let req = AccountUpdateProfile()
        req.firstName = Some(firstName)
        req.lastName = Some(lastName)
        req.about = if (about.size > 0) { Some(about) } else { None }
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return false
        }
        return true
    }

    /**
     * 注册推送 Token（P2-255 真接线版本）
     * account.registerDevice#ec86017a
     * iOS ctor: appendInt32(-326762118) = 0xEC86017A [verified vs Api42.swift:1067]
     *
     * @param token        设备 token 字符串（hex）
     * @param tokenType    1=APNS/Harmony, 9=VoIP（VoIP defer：鸿蒙无对应能力）
     * @param appSandbox   是否沙盒环境（鸿蒙 = false）
     * @param secret       masterNotificationsKey.data（非全零；P2-255 gap fix）
     * @param noMuted      excludeMutedChats — 排除静音聊天的推送（P2-255 gap fix）
     * @param otherUids    多账号 uid 列表（P2-255 gap fix；单账号传空列表）
     */
    public func registerPushToken(
        token: String,
        tokenType: Int32,
        appSandbox: Bool,
        secret!: Array<Byte> = Array<Byte>(0, repeat: 0),
        noMuted!: Bool = false,
        otherUids!: ArrayList<Int64> = ArrayList<Int64>()
    ): Bool {
        let client = getMTProtoClient()
        let req = AccountRegisterDevice()
        req.token = token
        req.tokenType = tokenType
        req.appSandbox = appSandbox
        req.secret = secret
        req.noMuted = noMuted
        req.otherUids = otherUids
        Hilog.info(0, "CjTelegram", "[RealAuthService] registerPushToken tokenType=${tokenType} secretLen=${secret.size} noMuted=${noMuted} otherUids=${otherUids.size}")
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] registerPushToken: empty response")
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] registerPushToken: RPC_ERROR ctor=0x${ctor}")
            return false
        }
        let ok = ctor == TLConstructors.BOOL_TRUE
        Hilog.info(0, "CjTelegram", "[RealAuthService] registerPushToken result=${ok}")
        return ok
    }

    /**
     * 注销推送 Token
     * account.unregisterDevice
     */
    public func unregisterPushToken(token: String, tokenType: Int32): Bool {
        let client = getMTProtoClient()
        let req = AccountUnregisterDevice()
        req.token = token
        req.tokenType = tokenType
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return false
        }
        return ctor == TLConstructors.BOOL_TRUE
    }

    /**
     * 获取服务条款更新
     * help.getTermsOfServiceUpdate
     */
    public func getTermsOfService(): HelpTermsOfServiceUpdateResponse {
        let client = getMTProtoClient()
        let req = HelpGetTermsOfServiceUpdate()
        let data = client.sendRequest(req.toBytes())
        return HelpTermsOfServiceUpdateResponse.deserialize(data)
    }

    /**
     * 接受服务条款
     * help.acceptTermsOfService
     * @param termsId 从 getTermsOfService() 返回的 termsId（DataJSON 字符串）
     */
    public func acceptTermsOfService(termsId: String): Bool {
        let client = getMTProtoClient()
        let req = HelpAcceptTermsOfService()
        req.termsId = termsId
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return false
        }
        return ctor == TLConstructors.BOOL_TRUE
    }

    // ==================== Settings: account TTL (auto-delete) ====================

    /**
     * 获取账号自毁天数（不活跃后自动删除账号）
     * account.getAccountTTL → account.daysTTL
     * 返回 0 表示禁用
     */
    public func getAccountTTL(): Int32 {
        let client = getMTProtoClient()
        let req = AccountGetAccountTTL()
        let data = client.sendRequest(req.toBytes())
        if (data.size < 8) {
            return 0
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return 0
        }
        if (ctor == 0xb8d0afdf) {
            return d.readInt32()
        }
        return 0
    }

    /**
     * 设置账号自毁天数
     * @param days 天数，0 表示禁用
     */
    public func setAccountTTL(days: Int32): Bool {
        let client = getMTProtoClient()
        let req = AccountSetAccountTTL()
        req.days = days
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return false
        }
        return ctor == 0x997275b5
    }

    // ==================== 内部方法 ====================

    private func saveAuthData(user: UserResponse) {
        let storage = getAuthStorage()
        storage.saveAuthState(3) // Authorized

        let userData = StoredUserData()
        userData.id = user.id
        userData.firstName = user.firstName
        userData.lastName = user.lastName
        userData.username = user.username
        userData.phone = user.phone
        userData.isPremium = user.isPremium
        storage.saveUserData(userData)

        // 保存会话数据
        let client = getMTProtoClient()
        let session = client.getCurrentSession()
        // 登录成功 = 该 DC 的 auth key 已被服务端正式授权（区别于 Created：仅完成握手、
        // 服务端尚未把用户身份绑定到这把 key）。标记 Registered 后，若后续再次触发
        // migrateToDC（如账号迁移/多次 USER_MIGRATE_X），MTProtoClient.migrateToDC 才会
        // 认定旧 DC session 值得 exportAuthorization，把授权继续传递到新 DC，
        // 避免每次迁移都退化为"新 DC 裸 auth key 未注册"。
        session.setAuthKeyState(AuthKeyState.Registered)
        SessionManager.saveSession(session)
        let sessionExport = SessionManager.exportSessionData(session)
        let storedSession = StoredSessionData()
        storedSession.dcId = sessionExport.dcId
        match (sessionExport.authKey) {
            case Some(ak) => storedSession.authKey = ak
            case None => ()
        }
        match (sessionExport.authKeyId) {
            case Some(akId) => storedSession.authKeyId = akId
            case None => ()
        }
        match (sessionExport.serverSalt) {
            case Some(ss) => storedSession.serverSalt = ss
            case None => ()
        }
        storedSession.authKeyState = sessionExport.authKeyState
        storage.saveSessionData(storedSession)
    }

    /**
     * 终止指定会话（account.resetAuthorization）
     */
    public func resetAuthorization(hash: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealAuthService] resetAuthorization hash=${hash}...")
        let client = getMTProtoClient()
        let req = AccountResetAuthorization()
        req.hash = hash
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return false
        }
        return ctor == 0x997275b5
    }

    /**
     * 删除账号（account.deleteAccount）
     * @param reason 删除原因，可为空
     * @param withPassword 若 true 且账号有 2FA，需传入正确密码；若 false，将触发 7 天延迟删除
     * @return (success, waitSeconds) - 成功时 waitSeconds=0；若返回 2FA_CONFIRM_WAIT_X 则 waitSeconds>0
     */
    public func deleteAccount(reason: String, withPassword: Bool, password: String): (Bool, Int32) {
        Hilog.info(0, "CjTelegram", "[RealAuthService] deleteAccount reason=${reason} withPassword=${withPassword}...")
        this.lastErrorMessage = ""
        this.lastErrorCode = 0
        this.accountResetWaitSeconds = 0

        let client = getMTProtoClient()
        let req = AccountDeleteAccount()
        req.reason = reason
        if (withPassword && password.size > 0) {
            let srp = this.computeCurrentPasswordSRP(password)
            if (srp.srpA.size > 0) {
                req.hasPassword = true
                req.password = srp
            }
        }
        let data = client.sendRequest(req.toBytes())

        if (data.size == 0) {
            notifyError(500, "No response from account.deleteAccount")
            return (false, 0)
        }

        let checkD = TLDeserializer(data)
        let checkCtor = checkD.readUInt32()
        if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
            let errorCode = checkD.readInt32()
            let errorMessage = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] deleteAccount error: ${errorCode} ${errorMessage}")
            this.lastErrorCode = Int32(errorCode)
            this.lastErrorMessage = errorMessage
            match (this.callback) {
                case Some(cb) => cb.onError(Int32(errorCode), errorMessage)
                case None => ()
            }
            if (errorMessage.startsWith("2FA_CONFIRM_WAIT_")) {
                let parts = errorMessage.split("_")
                if (parts.size >= 4) {
                    let secStr = parts[3]
                    var sec: Int32 = 0
                    for (ch in secStr) {
                        let code = UInt32(ch)
                        if (code >= 48 && code <= 57) {
                            sec = sec * 10 + Int32(code - 48)
                        }
                    }
                    this.accountResetWaitSeconds = sec
                    this.state = RealAuthState.AwaitingAccountReset
                    match (this.callback) {
                        case Some(cb) => cb.onAuthStateChanged(RealAuthState.AwaitingAccountReset)
                        case None => ()
                    }
                    return (false, sec)
                }
            }
            return (false, 0)
        }

        if (checkCtor == 0x997275b5) {
            this.state = RealAuthState.Unauthorized
            this.currentUser = None
            this.phoneCodeHash = ""
            let storage = getAuthStorage()
            storage.clearAll()
            // ic_presentation_reset_on_logout: see clearInvalidRestoredLogin() above for why.
            resetPresentation()
            SessionManager.clearAllSessions()
            match (this.callback) {
                case Some(cb) => cb.onAuthStateChanged(RealAuthState.Unauthorized)
                case None => ()
            }
            Hilog.info(0, "CjTelegram", "[RealAuthService] Account deleted successfully")
            return (true, 0)
        }
        return (false, 0)
    }

    // ==================== Phase P2-152: 2FA / Password Layer ====================

    /**
     * Gap 1: twoStepVerificationConfiguration
     * Calls account.getPassword#548a30f5 and returns typed TwoStepVerificationConfig.
     * iOS ref: _internal_twoStepVerificationConfiguration (TelegramEngineAuth.swift:13-27)
     * TL: account.password#957b50fb (ctor verified via tl_codegen)
     */
    public func twoStepVerificationConfiguration(): TwoStepVerificationConfig {
        let client = getMTProtoClient()
        let req = AccountGetPassword()
        let data = client.sendRequest(req.toBytes())
        let config = TwoStepVerificationConfig()
        if (data.size < 4) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] twoStepConfig: empty response")
            return config
        }
        let checkD = TLDeserializer(data)
        let checkCtor = checkD.readUInt32()
        if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
            let _ = checkD.readInt32()
            let msg = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] twoStepConfig RPC error: ${msg}")
            return config
        }
        let resp = AccountPasswordResponse.deserialize(data)
        config.hasPassword = resp.hasPassword
        config.hasRecoveryEmail = resp.hasRecovery
        config.hasSecureValues = resp.hasSecureValues
        config.hint = resp.hint
        config.emailUnconfirmedPattern = resp.emailUnconfirmedPattern
        config.srpId = resp.srpId
        config.srpB = resp.srpB
        config.algoSalt1 = resp.algoSalt1
        config.algoSalt2 = resp.algoSalt2
        config.algoG = resp.algoG
        config.algoP = resp.algoP
        Hilog.info(0, "CjTelegram", "[RealAuthService] twoStepConfig: hasPassword=${config.hasPassword} hasRecovery=${config.hasRecoveryEmail}")
        return config
    }

    /**
     * Gap 2: secure-secret settings
     * Calls account.getPasswordSettings#9cd4eaf9 with current SRP proof.
     * Returns email + SecureSecretSettings for Passport.
     * iOS ref: _internal_requestTwoStepVerifiationSettings (TwoStepVerification.swift:40-88)
     * TL: account.getPasswordSettings#9cd4eaf9 (ctor verified via tl_codegen)
     *     account.passwordSettings#9a5c33e5 secureSecretSettings#1527bcac (ctor verified)
     */
    public func getPasswordSettings(password: String): AccountPasswordSettingsResponse {
        Hilog.info(0, "CjTelegram", "[RealAuthService] getPasswordSettings...")
        let srp = this.computeCurrentPasswordSRP(password)
        if (srp.srpA.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] getPasswordSettings: SRP failed (no 2FA set)")
            return AccountPasswordSettingsResponse()
        }
        let client = getMTProtoClient()
        let req = AccountGetPasswordSettings()
        req.password = srp
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            return AccountPasswordSettingsResponse()
        }
        let checkD = TLDeserializer(data)
        let checkCtor = checkD.readUInt32()
        if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
            let errorCode = checkD.readInt32()
            let errorMessage = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] getPasswordSettings error: ${errorCode} ${errorMessage}")
            this.lastErrorCode = Int32(errorCode)
            this.lastErrorMessage = errorMessage
            return AccountPasswordSettingsResponse()
        }
        return AccountPasswordSettingsResponse.deserialize(data)
    }

    /**
     * Gap 3: cachedTwoStepPasswordToken — cache 2FA token after getTmpPassword
     * iOS ref: _internal_cacheTwoStepPasswordToken / _internal_cachedTwoStepPasswordToken
     *          (TwoStepVerification.swift:340-390)
     * Persists to Preferences via AuthStorage.saveCachedTwoStepToken.
     * Valid check uses validUntil timestamp.
     */
    public func cacheTwoStepPasswordToken(tmpPassword: Array<Byte>, validUntil: Int32): Unit {
        let storage = getAuthStorage()
        storage.saveCachedTwoStepToken(tmpPassword, validUntil)
        Hilog.info(0, "CjTelegram", "[RealAuthService] 2FA token cached, validUntil=${validUntil}")
    }

    public func getCachedTwoStepPasswordToken(): Option<Array<Byte>> {
        let storage = getAuthStorage()
        return storage.getCachedTwoStepToken()
    }

    public func clearCachedTwoStepPasswordToken(): Unit {
        let storage = getAuthStorage()
        storage.clearCachedTwoStepToken()
        Hilog.info(0, "CjTelegram", "[RealAuthService] 2FA token cache cleared")
    }

    /**
     * Gap 4: invalidateLoginCodes
     * account.invalidateSignInCodes#ca8ae8ba codes:Vector<string> = Bool
     * iOS ref: _internal_invalidateLoginCodes (Authorization.swift:1427-1433)
     * TL ctor verified via tl_codegen.
     */
    public func invalidateLoginCodes(codes: ArrayList<String>): Bool {
        Hilog.info(0, "CjTelegram", "[RealAuthService] invalidateLoginCodes: ${codes.size} codes")
        let client = getMTProtoClient()
        let req = AccountInvalidateSignInCodes()
        for (code in codes) {
            req.codes.add(code)
        }
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] invalidateLoginCodes: empty response")
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] invalidateLoginCodes error: ${msg}")
            return false
        }
        let ok = (ctor == TLConstructors.BOOL_TRUE)
        Hilog.info(0, "CjTelegram", "[RealAuthService] invalidateLoginCodes result: ${ok}")
        return ok
    }

    /**
     * Gap 5a: updateTwoStepEmail — send verification code to recovery email
     * account.sendVerifyEmailCode#98e037bb purpose:emailVerifyPurposeLoginChange email:string
     * (already in TLMethods as AccountSendVerifyEmailCode with purpose=emailVerifyPurposePassport)
     * For 2FA recovery email: purpose must be emailVerifyPurposeLoginChange#527d22eb
     * iOS ref: sendLoginEmailChangeCode (Authorization.swift:773-796)
     * Returns AccountSentEmailCodeResponse (emailPattern, codeLength)
     *
     * Note: AccountSendVerifyEmailCode in TLMethods uses Passport purpose (0xec22f596).
     * For 2FA recovery email we use loginChange purpose (0x527d22eb).
     * We implement inline here to avoid modifying shared TL class.
     */
    public func sendVerifyEmailCode(email: String): AccountSentEmailCodeResponse {
        Hilog.info(0, "CjTelegram", "[RealAuthService] sendVerifyEmailCode email=${email}")
        let client = getMTProtoClient()
        let ser = TLSerializer()
        ser.writeUInt32(0x98e037bb)           // account.sendVerifyEmailCode
        ser.writeUInt32(0x527d22eb)           // emailVerifyPurposeLoginChange
        ser.writeString(email)
        let data = client.sendRequest(ser.getBytes())
        if (data.size < 4) {
            return AccountSentEmailCodeResponse()
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] sendVerifyEmailCode error: ${errorCode} ${errorMessage}")
            this.lastErrorCode = Int32(errorCode)
            this.lastErrorMessage = errorMessage
            return AccountSentEmailCodeResponse()
        }
        return AccountSentEmailCodeResponse.deserialize(data)
    }

    /**
     * Gap 5b: updateTwoStepEmail — verify the code sent to recovery email
     * account.verifyEmail#32da4cf purpose:emailVerifyPurposeLoginChange verification:emailVerificationCode
     * (already in TLMethods as AccountVerifyEmail with Passport purpose)
     * For 2FA recovery email we use loginChange purpose (0x527d22eb) inline.
     * iOS ref: verifyLoginEmailChange (Authorization.swift:856-876)
     * Returns true if email verified (emailVerified or emailVerifiedLogin)
     */
    public func verifyEmail(code: String): Bool {
        Hilog.info(0, "CjTelegram", "[RealAuthService] verifyEmail code=***")
        let client = getMTProtoClient()
        let ser = TLSerializer()
        ser.writeUInt32(0x32da4cf)            // account.verifyEmail
        ser.writeUInt32(0x527d22eb)           // emailVerifyPurposeLoginChange
        ser.writeUInt32(0x922e55a9)           // emailVerificationCode (tl_codegen: 0x922e55a9)
        ser.writeString(code)
        let data = client.sendRequest(ser.getBytes())
        if (data.size < 4) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] verifyEmail error: ${errorCode} ${errorMessage}")
            this.lastErrorCode = Int32(errorCode)
            this.lastErrorMessage = errorMessage
            return false
        }
        let resp = deserializeAccountEmailVerified(data)
        Hilog.info(0, "CjTelegram", "[RealAuthService] verifyEmail result=${resp.verified} email=${resp.email}")
        return resp.verified
    }

    // ==================== Phase P2-152b: Passkey / FIDO2 ====================
    //
    // Layer 1 (TL plumbing): fully implemented.
    //   account.getPasskeys, account.deletePasskey, account.initPasskeyRegistration,
    //   account.registerPasskey, auth.initPasskeyLogin, auth.finishPasskeyLogin
    //   all wired via TLMethods + TLResponses with ctor IDs verified from iOS TelegramApi.
    //
    // Layer 2 (ceremony): HarmonyOS SDK (Cangjie KB queried 4 rounds, all score ~0.016)
    //   exposes no native WebAuthn/FIDO2 authenticator API. Platform-limited rearchitect:
    //   initPasskeyRegistration / initPasskeyLogin return the server-issued JSON options
    //   (PublicKeyCredentialCreationOptions / PublicKeyCredentialRequestOptions) for
    //   potential future embedding in a Web component or hybrid channel.
    //   registerPasskey / finishPasskeyLogin accept pre-assembled credential bytes from
    //   the caller (whoever has platform access to create/assert the authenticator).
    //   The service layer returns a platform-limited indicator when called with empty
    //   credential bytes rather than silently failing.

    /**
     * getPasskeys — account.getPasskeys#ea1f0c52
     * Returns the list of passkeys registered on this account.
     * iOS ref: _internal_passkeysData (Account.swift:515)
     */
    public func getPasskeys(): AccountPasskeysResponse {
        Hilog.info(0, "CjTelegram", "[RealAuthService] getPasskeys...")
        let client = getMTProtoClient()
        let req = AccountGetPasskeys()
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] getPasskeys: empty response")
            return AccountPasskeysResponse()
        }
        let checkD = TLDeserializer(data)
        let checkCtor = checkD.readUInt32()
        if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
            let errorCode = checkD.readInt32()
            let errorMessage = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] getPasskeys error: ${errorCode} ${errorMessage}")
            return AccountPasskeysResponse()
        }
        return AccountPasskeysResponse.deserialize(data)
    }

    /**
     * deletePasskey — account.deletePasskey#f5b5563f id:string = Bool
     * Removes a registered passkey by its credential ID.
     * iOS ref: _internal_deletePasskey (Account.swift:572)
     */
    public func deletePasskey(id: String): Bool {
        Hilog.info(0, "CjTelegram", "[RealAuthService] deletePasskey id=${id}")
        let client = getMTProtoClient()
        let req = AccountDeletePasskey()
        req.id = id
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] deletePasskey: empty response")
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] deletePasskey error: ${msg}")
            return false
        }
        let ok = (ctor == TLConstructors.BOOL_TRUE)
        Hilog.info(0, "CjTelegram", "[RealAuthService] deletePasskey result: ${ok}")
        return ok
    }

    /**
     * initPasskeyRegistration — account.initPasskeyRegistration#429547e8
     * Requests server-issued WebAuthn PublicKeyCredentialCreationOptions JSON.
     * Caller must feed this JSON to a WebAuthn platform authenticator to obtain
     * the attestation object and clientDataJSON, then call registerPasskey().
     *
     * Platform note: HarmonyOS SDK does not expose a native WebAuthn/FIDO2
     * authenticator API (KB queried 4 rounds, no match). The JSON options are
     * returned here for use via a Web component or future platform extension.
     *
     * iOS ref: _internal_requestPasskeyRegistration (Account.swift:535)
     * Returns empty string when server call fails.
     */
    public func initPasskeyRegistration(): String {
        Hilog.info(0, "CjTelegram", "[RealAuthService] initPasskeyRegistration...")
        let client = getMTProtoClient()
        let req = AccountInitPasskeyRegistration()
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] initPasskeyRegistration: empty response")
            return ""
        }
        let checkD = TLDeserializer(data)
        let checkCtor = checkD.readUInt32()
        if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
            let _ = checkD.readInt32()
            let msg = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] initPasskeyRegistration error: ${msg}")
            return ""
        }
        let resp = PasskeyRegistrationOptionsResponse.deserialize(data)
        Hilog.info(0, "CjTelegram", "[RealAuthService] initPasskeyRegistration: got options json len=${resp.optionsJson.size}")
        return resp.optionsJson
    }

    /**
     * registerPasskey — account.registerPasskey#55b41fd6
     * Completes passkey registration by sending authenticator attestation to Telegram.
     * Parameters come from the WebAuthn ceremony performed outside this layer.
     *
     * Platform note: HarmonyOS SDK does not expose a native WebAuthn/FIDO2
     * authenticator API. This method accepts pre-assembled credential data from
     * the caller. When attestationData is empty, registration is skipped and
     * None is returned — this is the expected path on HarmonyOS until a platform
     * WebAuthn bridge is available.
     *
     * iOS ref: _internal_requestCreatePasskey (Account.swift:557)
     */
    public func registerPasskey(credentialId: String, rawId: String, clientDataJson: String, attestationData: Array<Byte>): Option<PasskeyInfo> {
        Hilog.info(0, "CjTelegram", "[RealAuthService] registerPasskey credentialId=${credentialId}")
        if (attestationData.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] registerPasskey: no attestation data (platform ceremony not available)")
            return None
        }
        let client = getMTProtoClient()
        let req = AccountRegisterPasskey()
        req.credentialId = credentialId
        req.rawId = rawId
        req.clientDataJson = clientDataJson
        req.attestationData = attestationData
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] registerPasskey: empty response")
            return None
        }
        let checkD = TLDeserializer(data)
        let checkCtor = checkD.readUInt32()
        if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
            let errorCode = checkD.readInt32()
            let errorMessage = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] registerPasskey error: ${errorCode} ${errorMessage}")
            return None
        }
        let created = PasskeyCreatedResponse.deserialize(data)
        Hilog.info(0, "CjTelegram", "[RealAuthService] registerPasskey: done")
        return created.info
    }

    /**
     * initPasskeyLogin — auth.initPasskeyLogin#518ad0b7 api_id:int api_hash:string
     * Requests server-issued WebAuthn PublicKeyCredentialRequestOptions JSON.
     * Caller must feed this JSON to a WebAuthn platform authenticator to obtain
     * the assertion (authenticatorData, signature, userHandle, clientDataJSON),
     * then call finishPasskeyLogin().
     *
     * Platform note: HarmonyOS SDK does not expose a native WebAuthn/FIDO2
     * authenticator API (KB queried 4 rounds, no match). Returns the options JSON
     * for use via a Web component or future platform extension.
     *
     * iOS ref: _internal_requestPasskeyLoginData (Account.swift:579)
     * Returns empty string when server call fails.
     */
    public func initPasskeyLogin(apiId: Int32, apiHash: String): String {
        Hilog.info(0, "CjTelegram", "[RealAuthService] initPasskeyLogin apiId=${apiId}")
        let client = getMTProtoClient()
        let req = AuthInitPasskeyLogin()
        req.apiId = apiId
        req.apiHash = apiHash
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] initPasskeyLogin: empty response")
            return ""
        }
        let checkD = TLDeserializer(data)
        let checkCtor = checkD.readUInt32()
        if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
            let _ = checkD.readInt32()
            let msg = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] initPasskeyLogin error: ${msg}")
            return ""
        }
        let resp = PasskeyLoginOptionsResponse.deserialize(data)
        Hilog.info(0, "CjTelegram", "[RealAuthService] initPasskeyLogin: got options json len=${resp.optionsJson.size}")
        return resp.optionsJson
    }

    /**
     * finishPasskeyLogin — auth.finishPasskeyLogin#9857ad07
     * Completes passkey login by sending authenticator assertion to Telegram.
     * Parameters come from the WebAuthn ceremony performed outside this layer.
     *
     * On success, updates auth state to Authorized and saves session.
     *
     * Platform note: HarmonyOS SDK does not expose a native WebAuthn/FIDO2
     * authenticator API. When authenticatorData is empty, login is skipped and
     * false is returned — this is the expected path on HarmonyOS until a platform
     * WebAuthn bridge is available. Existing phone+code and 2FA login remain
     * fully functional and are the primary login paths on this platform.
     *
     * iOS ref: auth.finishPasskeyLogin (Api42.swift:2378)
     */
    public func finishPasskeyLogin(credentialId: String, rawId: String, clientDataJson: String, authenticatorData: Array<Byte>, signature: Array<Byte>, userHandle: String): Bool {
        Hilog.info(0, "CjTelegram", "[RealAuthService] finishPasskeyLogin credentialId=${credentialId}")
        if (authenticatorData.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] finishPasskeyLogin: no authenticator data (platform ceremony not available)")
            return false
        }
        let client = getMTProtoClient()
        let req = AuthFinishPasskeyLogin()
        req.credentialId = credentialId
        req.rawId = rawId
        req.clientDataJson = clientDataJson
        req.authenticatorData = authenticatorData
        req.signature = signature
        req.userHandle = userHandle
        let data = client.sendRequest(req.toBytes())
        if (data.size < 4) {
            Hilog.info(0, "CjTelegram", "[RealAuthService] finishPasskeyLogin: empty response")
            return false
        }
        let checkD = TLDeserializer(data)
        let checkCtor = checkD.readUInt32()
        if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
            let errorCode = checkD.readInt32()
            let errorMessage = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealAuthService] finishPasskeyLogin error: ${errorCode} ${errorMessage}")
            notifyError(Int32(errorCode), errorMessage)
            return false
        }
        let authResponse = AuthAuthorizationResponse.deserialize(data)
        match (authResponse.user) {
            case Some(user) =>
                this.currentUser = Some(user)
                this.state = RealAuthState.Authorized
                saveAuthData(user)
                match (this.callback) {
                    case Some(cb) =>
                        cb.onAuthorized(user)
                        cb.onAuthStateChanged(RealAuthState.Authorized)
                    case None => ()
                }
                Hilog.info(0, "CjTelegram", "[RealAuthService] finishPasskeyLogin: authorized as ${user.firstName}")
                return true
            case None =>
                notifyError(500, "No user in passkey login response")
                return false
        }
    }

    private func notifyError(code: Int32, message: String) {
        Hilog.info(0, "CjTelegram", "[RealAuthService] Error ${code}: ${message}")
        this.lastErrorCode = code
        this.lastErrorMessage = message
        match (this.callback) {
            case Some(cb) => cb.onError(code, message)
            case None => ()
        }
    }
}

func extractDCId(errorMessage: String): Int64 {
    // 从 "PHONE_MIGRATE_2" 提取 2
    let parts = errorMessage.split("_")
    if (parts.size > 0) {
        let lastPart = parts[parts.size - 1]
        // 尝试解析数字
        var result: Int64 = 0
        for (ch in lastPart) {
            let code = UInt32(ch)
            if (code >= 48 && code <= 57) {
                result = result * 10 + Int64(code - 48)
            }
        }
        if (result > 0) {
            return result
        }
    }
    return 2 // 默认 DC2
}
