package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.utils.getLocalAuthManager
import std.time.DateTime

/**
 * App Lock State Service (app_lock_state)
 *
 * P2-269: 自动锁定判定真接线
 *   shouldLockOnForeground() / notifyAppWentToBackground() / notifyAppCameToForeground()
 *   现在读写 AuthStorage.saveBackgroundTimestamp / getBackgroundTimestamp，
 *   实现跨重启持久化（重启后 App 仍能按超时判断是否锁定）。
 *
 * Manages app lock state: locked/unlocked, lockout timer, auto-lock timeout.
 * Works with AuthStorage for passcode verification (no duplication).
 * Tracks app background/foreground for auto-lock.
 *
 * iOS reference: AppLockState.swift
 */

private var _appLockStateServiceInstance: Option<AppLockStateService> = None

public func getAppLockStateService(): AppLockStateService {
    match (_appLockStateServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = AppLockStateService()
            _appLockStateServiceInstance = Some(inst)
            return inst
    }
}

public class AppLockStateService {
    private var _isLocked: Bool = false
    private var _lockError: String = ""
    private var _showBiometricButton: Bool = false
    // P2-269: 内存缓存后台时间戳（主要从 AuthStorage 读取，此处做本次进程内缓存）
    private var lastBackgroundTimestamp: Int64 = 0
    // P2-269: UI 通知回调 — EntryView 注册，lock() 触发时调用，令 @State isLocked=true
    private var _lockTriggeredCallback: Option<() -> Unit> = None

    /**
     * P2-269: 注册锁定通知回调（供 EntryView.aboutToAppear 注册 launch { isLocked = true }）。
     * 当 lock() 被自动锁定触发时，调用此回调令 UI @State 同步更新。
     */
    public func setLockTriggeredCallback(cb: () -> Unit): Unit {
        this._lockTriggeredCallback = Some(cb)
    }

    /**
     * Check if app is currently locked.
     */
    public func isLocked(): Bool {
        let storage = getAuthStorage()
        if (!storage.hasPasscode()) {
            return false
        }
        return this._isLocked
    }

    public func getLockError(): String {
        return this._lockError
    }

    public func getShowBiometricButton(): Bool {
        return this._showBiometricButton
    }

    /**
     * Check if passcode lockout is active (too many failed attempts).
     */
    public func isLockoutActive(): Bool {
        return getAuthStorage().isLockedOut()
    }

    /**
     * Get remaining lockout seconds.
     */
    public func getLockoutRemainingSeconds(): Int32 {
        return getAuthStorage().getLockoutRemainingSeconds()
    }

    /**
     * P2-269: Check if app should lock when coming to foreground (auto-lock timeout elapsed).
     *
     * 判定逻辑：
     *   1. 密码未设置 → false（无锁定需求）
     *   2. auto-lock minutes <= 0 → false（用户关闭自动锁定）
     *   3. 从 AuthStorage 读取持久化后台时间戳 bgTs
     *   4. bgTs == 0 → true（无记录，首次启动/重装后需锁定）
     *   5. elapsed = now - bgTs >= threshold → true
     *
     * 持久化关键：bgTs 由 notifyAppWentToBackground() 写入 AuthStorage，
     * 跨重启保留，重启后仍能正确判断自动锁定（iOS 对齐行为）。
     */
    public func shouldLockOnForeground(): Bool {
        let storage = getAuthStorage()
        if (!storage.hasPasscode()) {
            return false
        }
        let minutes = storage.getAutoLockMinutes()
        if (minutes <= 0) {
            return false
        }
        // 从持久化存储读取后台时间戳（内存缓存和持久化取较大值，避免进程内覆盖）
        let persistedTs = storage.getBackgroundTimestamp()
        let bgTs = if (this.lastBackgroundTimestamp > persistedTs) { this.lastBackgroundTimestamp } else { persistedTs }
        if (bgTs <= 0) {
            // 无记录 → 新安装或首次启动 → 按有密码即锁定
            Hilog.info(0, "CjTelegram", "[AppLockStateService] shouldLockOnForeground: no bgTs, lock=true")
            return true
        }
        let now = DateTime.now().toUnixTimeStamp().toSeconds()
        let elapsedSeconds = now - bgTs
        let thresholdSeconds = Int64(minutes) * 60
        let shouldLock = elapsedSeconds >= thresholdSeconds
        Hilog.info(0, "CjTelegram", "[AppLockStateService] shouldLockOnForeground: elapsed=${elapsedSeconds}s threshold=${thresholdSeconds}s lock=${shouldLock}")
        return shouldLock
    }

    /**
     * P2-269: Call when app goes to background.
     * Records timestamp persistently for auto-lock (跨重启 — AuthStorage Preferences flush).
     */
    public func notifyAppWentToBackground(): Unit {
        let storage = getAuthStorage()
        if (!storage.hasPasscode()) {
            return
        }
        let now = DateTime.now().toUnixTimeStamp().toSeconds()
        this.lastBackgroundTimestamp = now
        storage.saveBackgroundTimestamp(now)
        Hilog.info(0, "CjTelegram", "[AppLockStateService] App went to background, bgTs=${now}")
    }

    /**
     * P2-269: Call when app comes to foreground. Locks if auto-lock timeout elapsed.
     */
    public func notifyAppCameToForeground(): Unit {
        let storage = getAuthStorage()
        if (!storage.hasPasscode()) {
            return
        }
        if (this.shouldLockOnForeground()) {
            this.lock()
            Hilog.info(0, "CjTelegram", "[AppLockStateService] Auto-lock triggered on foreground")
        }
    }

    /**
     * P2-269: Lock the app.
     * Call when passcode is enabled and app should show lock screen.
     * Invokes _lockTriggeredCallback (registered by EntryView) to update UI @State.
     */
    public func lock(): Unit {
        let storage = getAuthStorage()
        if (!storage.hasPasscode()) {
            return
        }
        this._isLocked = true
        this._lockError = ""
        this._showBiometricButton = getLocalAuthManager().isBiometricAvailable() && storage.getBiometricEnabled()
        Hilog.info(0, "CjTelegram", "[AppLockStateService] App locked (showBiometric=${this._showBiometricButton})")
        match (this._lockTriggeredCallback) {
            case Some(cb) =>
                try {
                    cb()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AppLockStateService] lockTriggeredCallback error: ${e}")
                }
            case None => ()
        }
    }

    /**
     * Unlock the app.
     * P2-269: 解锁后清除持久化后台时间戳，防止下次启动误触发自动锁定。
     */
    public func unlock(): Unit {
        this._isLocked = false
        this._lockError = ""
        this.lastBackgroundTimestamp = 0
        getAuthStorage().clearBackgroundTimestamp()
        Hilog.info(0, "CjTelegram", "[AppLockStateService] App unlocked")
    }

    /**
     * Verify passcode and unlock if correct. Uses AuthStorage.verifyPasscode.
     * @return true if verification succeeded
     */
    public func verifyAndUnlock(code: String): Bool {
        let storage = getAuthStorage()
        if (storage.verifyPasscode(code)) {
            this.unlock()
            return true
        }
        return false
    }

    /**
     * Record failed passcode attempt (delegate to AuthStorage).
     */
    public func recordFailedAttempt(): Unit {
        getAuthStorage().recordFailedAttempt()
    }

    /**
     * Set lock error message for UI display.
     */
    public func setLockError(msg: String): Unit {
        this._lockError = msg
    }

    /**
     * Initialize lock state on app start. Call from EntryView.aboutToAppear.
     * If passcode is enabled, locks the app.
     */
    public func initializeLockState(): Unit {
        let storage = getAuthStorage()
        if (storage.hasPasscode()) {
            this.lock()
            Hilog.info(0, "CjTelegram", "[AppLockStateService] Initialized: lock screen shown")
        }
    }
}
