package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.utils.getLocalAuthManager

/**
 * App Lock Service (app_lock)
 *
 * Settings-specific operations for passcode lock: enable, disable, change passcode,
 * set auto-lock timeout, toggle biometric. Wraps AuthStorage (local storage only, no TL).
 *
 * AppLockStateService: lock state (locked/unlocked, auto-lock timer).
 * AuthStorage: passcode hash, auto-lock minutes, biometric preference.
 *
 * iOS reference: AppLock module
 */
private var _appLockServiceInstance: Option<AppLockService> = None

public func getAppLockService(): AppLockService {
    match (_appLockServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = AppLockService()
            _appLockServiceInstance = Some(inst)
            return inst
    }
}

public class AppLockService {

    /**
     * Check if passcode is enabled.
     */
    public func hasPasscode(): Bool {
        return getAuthStorage().hasPasscode()
    }

    /**
     * Get auto-lock timeout in minutes (0 = disabled).
     */
    public func getAutoLockMinutes(): Int32 {
        return getAuthStorage().getAutoLockMinutes()
    }

    /**
     * Get biometric unlock preference.
     */
    public func getBiometricEnabled(): Bool {
        return getAuthStorage().getBiometricEnabled()
    }

    /**
     * Check if biometric (fingerprint/face) is available on device.
     */
    public func isBiometricAvailable(): Bool {
        return getLocalAuthManager().isBiometricAvailable()
    }

    /**
     * Check if lockout is active (too many failed attempts).
     */
    public func isLockedOut(): Bool {
        return getAuthStorage().isLockedOut()
    }

    /**
     * Get remaining lockout seconds.
     */
    public func getLockoutRemainingSeconds(): Int32 {
        return getAuthStorage().getLockoutRemainingSeconds()
    }

    /**
     * P2-267: Get passcode type (0=digits6, 1=digits4, 2=alphanumeric).
     */
    public func getPasscodeType(): Int32 {
        return getAuthStorage().getPasscodeType()
    }

    /**
     * P2-267: Save passcode type (0=digits6, 1=digits4, 2=alphanumeric).
     */
    public func savePasscodeType(passcodeType: Int32): Unit {
        getAuthStorage().savePasscodeType(passcodeType)
    }

    /**
     * Enable passcode with type. passcodeType: 0=digits6, 1=digits4, 2=alphanumeric.
     * Caller must ensure passcode and confirmPasscode match and length >= 4 (numeric) or >= 1 (alpha).
     * Returns true on success. Unlocks app after enable.
     */
    public func enablePasscode(passcode: String, confirmPasscode: String): Bool {
        let minLen: Int64 = 4
        if (Int64(passcode.size) < minLen) {
            return false
        }
        if (passcode != confirmPasscode) {
            return false
        }
        let storage = getAuthStorage()
        storage.savePasscodeFromPlain(passcode)
        // TC-0138 R2: 首次设密码与写密码同一事务强制把 Auto-Lock 重置为 1 hour
        // （对位 PasscodeOptionsController.swift:460-470 的 withUpdatedAutolockTimeout(1*60*60)）。
        storage.saveAutoLockMinutes(60)
        getAppLockStateService().unlock()
        Hilog.info(0, "CjTelegram", "[AppLockService] Passcode enabled")
        return true
    }

    /**
     * Enable passcode with explicit type. passcodeType: 0=digits6, 1=digits4, 2=alphanumeric.
     */
    public func enablePasscodeWithType(passcode: String, confirmPasscode: String, passcodeType: Int32): Bool {
        if (passcode != confirmPasscode) {
            return false
        }
        if (passcode.size == 0) {
            return false
        }
        let storage = getAuthStorage()
        storage.savePasscodeFromPlain(passcode)
        storage.savePasscodeType(passcodeType)
        // TC-0138 R2: 同上 —— 首次设密码强制把 Auto-Lock 重置为 1 hour（见 enablePasscode() 注释）。
        // 边界：changePasscode() 不加这一行 —— 源侧改密分支没有对位的 auto-lock 写入。
        storage.saveAutoLockMinutes(60)
        getAppLockStateService().unlock()
        let typeStr = "${passcodeType}"
        Hilog.info(0, "CjTelegram", "[AppLockService] Passcode enabled type=%{public}s", [typeStr])
        return true
    }

    /**
     * Disable passcode. Verifies current passcode first.
     * Returns true on success.
     */
    public func disablePasscode(passcode: String): Bool {
        let storage = getAuthStorage()
        if (!storage.verifyPasscode(passcode)) {
            storage.recordFailedAttempt()
            return false
        }
        storage.clearPasscode()
        getAppLockStateService().unlock()
        Hilog.info(0, "CjTelegram", "[AppLockService] Passcode disabled")
        return true
    }

    /**
     * Change passcode. Writes the new passcode directly.
     *
     * TC-0139 R4: the old passcode is no longer accepted/verified here. Old-passcode
     * verification is the entry gate's job (AppLockPage uiMode=4, before this screen is
     * reachable at all) — matching iOS PasscodeOptionsController.swift:312-339, whose
     * `changePasscode` pushes `PasscodeSetupController(mode: .setup(change: true, ...))`
     * with a `complete` callback that writes the new passcode directly, no re-verification.
     * Do not add `verifyPasscode`/`recordFailedAttempt` back here — the source's `.setup`
     * mode has no failure counter, and every previously "correct" change attempt was being
     * misrecorded as a failed attempt via this call (60s lockout after 5 legitimate changes).
     * Do not add an auto-lock write here either — the source's change-passcode branch has no
     * corresponding auto-lock reset (see AppLockPage TC-0138 R2 note).
     */
    public func changePasscode(newPasscode: String): Bool {
        if (newPasscode.size == 0) {
            return false
        }
        let storage = getAuthStorage()
        storage.savePasscodeFromPlain(newPasscode)
        Hilog.info(0, "CjTelegram", "[AppLockService] Passcode changed")
        return true
    }

    /**
     * Save auto-lock timeout in minutes.
     */
    public func saveAutoLockMinutes(minutes: Int32): Unit {
        getAuthStorage().saveAutoLockMinutes(minutes)
        let minStr = "${minutes}"
        Hilog.info(0, "CjTelegram", "[AppLockService] Auto-lock set to %{public}s minutes", [minStr])
    }

    /**
     * Set biometric unlock preference.
     */
    public func setBiometricEnabled(enabled: Bool): Unit {
        getAuthStorage().saveBiometricEnabled(enabled)
        let enStr = "${enabled}"
        Hilog.info(0, "CjTelegram", "[AppLockService] Biometric unlock: %{public}s", [enStr])
    }

    /**
     * Record failed passcode attempt (delegate to AuthStorage).
     */
    public func recordFailedAttempt(): Unit {
        getAuthStorage().recordFailedAttempt()
    }
}
