package ohos_app_cangjie_entry.app

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.HashMap
import std.sync.ReentrantMutex

/**
 * 全局应用状态管理（Phase G1）
 * 
 * 参照 TelegramHarmony AppState.ets
 * 
 * 集中管理:
 * - 当前登录用户信息
 * - 应用生命周期状态
 * - 全局配置
 * - 服务实例缓存
 */

// ==================== 单例 ====================

private var _appStateInstance: Option<AppState> = None

public func getAppState(): AppState {
    match (_appStateInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = AppState()
            _appStateInstance = Some(inst)
            return inst
    }
}

// ==================== 应用状态枚举 ====================

public enum AppLifecycleState {
    | Foreground
    | Background
    | Inactive
}

public enum AuthStatus {
    | NotAuthenticated
    | Authenticating
    | Authenticated
    | Error
}

// ==================== AppState ====================

public class AppState {
    // 当前登录用户
    public var currentUserId: Int64 = 0
    public var currentUserName: String = ""
    public var currentUserPhone: String = ""
    public var currentUsername: String = ""
    
    // 认证状态
    public var authStatus: AuthStatus = AuthStatus.NotAuthenticated
    
    // 应用生命周期
    private var lifecycleState: AppLifecycleState = AppLifecycleState.Foreground
    private let _lifecycleMutex = ReentrantMutex()
    
    // 全局配置
    public var notificationsEnabled: Bool = true
    public var darkModeEnabled: Bool = false
    public var textSizeMultiplier: Float64 = 1.0
    public var language: String = "zh-CN"
    
    // 网络状态
    public var isConnected: Bool = true
    public var isConnecting: Bool = false
    
    // 缓存统计
    public var cachedUsersCount: Int64 = 0
    public var cachedChatsCount: Int64 = 0
    
    /**
     * 初始化应用状态（从 AuthService 获取当前用户）
     */
    public func initialize() {
        let authService = getRealAuthService()
        match (authService.getCurrentUser()) {
            case Some(user) =>
                this.currentUserId = user.id
                this.currentUserName = user.firstName
                if (user.lastName.size > 0) {
                    this.currentUserName = "${user.firstName} ${user.lastName}"
                }
                this.currentUserPhone = user.phone
                this.currentUsername = user.username
                this.authStatus = AuthStatus.Authenticated
                Hilog.info(0, "CjTelegram", "[AppState] Initialized with user: ${this.currentUserName}")
            case None =>
                this.authStatus = AuthStatus.NotAuthenticated
                Hilog.info(0, "CjTelegram", "[AppState] No authenticated user")
        }
    }
    
    /**
     * 更新认证状态
     */
    public func setAuthenticated(userId: Int64, userName: String, phone: String, username: String) {
        this.currentUserId = userId
        this.currentUserName = userName
        this.currentUserPhone = phone
        this.currentUsername = username
        this.authStatus = AuthStatus.Authenticated
    }
    
    /**
     * 清除认证状态（登出）
     */
    public func clearAuthentication() {
        this.currentUserId = 0
        this.currentUserName = ""
        this.currentUserPhone = ""
        this.currentUsername = ""
        this.authStatus = AuthStatus.NotAuthenticated
    }
    
    /**
     * 更新网络状态
     */
    public func setNetworkState(connected: Bool, connecting: Bool) {
        this.isConnected = connected
        this.isConnecting = connecting
    }
    
    /**
     * P2-006 + P2-269: 进入前台
     * iOS 对应: ApplicationContext.applicationDidBecomeActive + AccountContext.networkStatePromise
     *           + AppLock.applicationDidBecomeActive（自动锁定判定）
     * 接线: lifecycleState → Foreground;
     *   1. 触发网络重连（从后台返回时 MTProto 连接可能已断）
     *   2. P2-269: AppLockStateService.notifyAppCameToForeground() → 若超时则触发锁定
     */
    public func onForeground() {
        synchronized (this._lifecycleMutex) {
            this.lifecycleState = AppLifecycleState.Foreground
        }
        setApplicationForeground(true)
        Hilog.info(0, "CjTelegram", "[AppState] App entered foreground")
        // P2-269: 自动锁定判定 — 若后台超时则触发锁定
        try {
            getAppLockStateService().notifyAppCameToForeground()
            Hilog.info(0, "CjTelegram", "[AppState] onForeground: auto-lock check done")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AppState] onForeground: auto-lock check error=${e}")
        }
        // 触发 MTProto 客户端重连（网络从后台切回前台可能已断）
        // 对应 iOS AccountContext 中 network state signal 恢复时的重连逻辑
        try {
            getTelegramCore_NetworkService().wireReachabilityReconnect()
            Hilog.info(0, "CjTelegram", "[AppState] onForeground: network reconnect triggered")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AppState] onForeground: network reconnect error=${e}")
        }
    }

    /**
     * P2-006 + P2-269: 进入后台
     * iOS 对应: ApplicationContext.applicationDidEnterBackground + 状态同步
     *           + AppLock.applicationDidEnterBackground（记录后台时间戳）
     * 接线: lifecycleState → Background;
     *   1. P2-269: AppLockStateService.notifyAppWentToBackground() → 持久化后台时间戳
     */
    public func onBackground() {
        synchronized (this._lifecycleMutex) {
            this.lifecycleState = AppLifecycleState.Background
        }
        setApplicationForeground(false)
        Hilog.info(0, "CjTelegram", "[AppState] App entered background")
        // P2-269: 持久化后台时间戳，供下次前台回来时判断自动锁定
        try {
            getAppLockStateService().notifyAppWentToBackground()
            Hilog.info(0, "CjTelegram", "[AppState] onBackground: bgTs saved")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AppState] onBackground: bgTs save error=${e}")
        }
    }

    /**
     * 获取当前生命周期状态（供 UI 层查询）
     */
    public func getLifecycleState(): AppLifecycleState {
        var state = AppLifecycleState.Inactive
        synchronized (this._lifecycleMutex) {
            state = this.lifecycleState
        }
        return state
    }

    /**
     * 当前是否处于前台
     */
    public func isInForeground(): Bool {
        return match (this.getLifecycleState()) {
            case AppLifecycleState.Foreground => true
            case _ => false
        }
    }
}
