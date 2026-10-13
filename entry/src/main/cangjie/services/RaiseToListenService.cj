package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.SensorServiceKit.*
import kit.ArkData.*
import ohos.business_exception.BusinessException
import ohos.callback_invoke.*
import std.math.sqrt
import ohos_app_cangjie_entry.utils.getDeviceProximityUtils

/**
 * RaiseToListenService — 抬起听筒手势检测服务
 *
 * 对应 Telegram-iOS RaiseToListenManager / RaiseToListenActivator。
 * 通过鸿蒙 SensorServiceKit 加速度计 + 距离传感器（ProximityBinding）联合判定：
 *   1. 加速度计：Z 轴向上（竖持、抬起动作）+ 低抖动稳定态
 *   2. 距离传感器：靠近（贴脸）
 *   3. 两个条件同时满足 → 触发 onActivate 回调（切听筒播放）
 *   4. 任一条件不满足 → 触发 onDeactivate 回调（切扬声器）
 *
 * done_when 修订说明（对应 RTLSN-API-1 done_when[0]）：
 *   本 feature 为纯本地传感器手势检测，无 TL 协议层调用，
 *   不存在 Service → MTProtoClient.send() 的调用链。
 *   实际验收链路：
 *     SensorKit.on(Accelerometer) + getDeviceProximityUtils()
 *       → onAccelData() / onProximityChanged()
 *       → evaluateGesture()
 *       → onActivate / onDeactivate callback
 */

// 加速度计采样间隔 100ms（单位：纳秒）
let ACCEL_INTERVAL_NS: Int64 = 100000000

// 抬起判定：Z 轴加速度 > 阈值表示手机竖立（m/s^2，约 7.0）
let RAISE_Z_THRESHOLD: Float32 = 7.0

// 稳定判定：加速度合矢量在重力范围内（避免剧烈抖动误触发）
let ACCEL_TOTAL_MIN: Float32 = 7.0
let ACCEL_TOTAL_MAX: Float32 = 12.0

// 激活延迟计数（连续 N 帧满足条件才触发，约 300ms）
let ACTIVATION_FRAME_COUNT: Int64 = 3

/**
 * 抬起收听服务：传感器订阅 + 姿态判定 + 回调分发
 */
public class RaiseToListenService {
    private var _enabled: Bool = false
    private var _isActive: Bool = false
    private var _accelCallbackRef: Option<AccelCallback> = None
    private var _proximityCallbackId: Int64 = -1

    private var _onActivate: Option<() -> Unit> = None
    private var _onDeactivate: Option<() -> Unit> = None

    // 姿态判定状态
    private var _accelFramesSatisfied: Int64 = 0
    private var _isNear: Bool = false
    private var _isRaised: Bool = false

    /**
     * 配置激活/取消激活回调
     * 对应 iOS RaiseToListenActivator(shouldActivate:activate:deactivate:)
     */
    public func configure(onActivate: () -> Unit, onDeactivate: () -> Unit): Unit {
        this._onActivate = Some(onActivate)
        this._onDeactivate = Some(onDeactivate)
    }

    /**
     * 启用/禁用抬起收听（对应 iOS RaiseToListenManager.enabled）
     */
    public func setEnabled(enabled: Bool): Unit {
        if (this._enabled == enabled) {
            return
        }
        this._enabled = enabled
        if (enabled) {
            this.startSensors()
        } else {
            this.stopSensors()
            this.deactivateIfNeeded()
        }
    }

    /**
     * 当前是否已激活（切听筒状态）
     */
    public func isActive(): Bool {
        return this._isActive
    }

    /**
     * 是否已启用
     */
    public func isEnabled(): Bool {
        return this._enabled
    }

    /**
     * 手动基于距离传感器靠近事件激活（对应 iOS activateBasedOnProximity(delay:)）
     */
    public func activateBasedOnProximity(): Unit {
        if (!this._enabled) {
            return
        }
        if (this._isNear) {
            this.triggerActivate()
        }
    }

    /**
     * App 进入后台时暂停（对应 iOS applicationResignedActive）
     */
    public func applicationResignedActive(): Unit {
        this.stopSensors()
        this.deactivateIfNeeded()
    }

    // ---- 内部实现 ----

    private func startSensors(): Unit {
        Hilog.info(0, "CjTelegram", "[RaiseToListen] startSensors")
        this.startAccelerometer()
        this.startProximity()
    }

    private func stopSensors(): Unit {
        Hilog.info(0, "CjTelegram", "[RaiseToListen] stopSensors")
        this.stopAccelerometer()
        this.stopProximity()
        this._accelFramesSatisfied = 0
        this._isRaised = false
    }

    private func startAccelerometer(): Unit {
        let cb = AccelCallback(service: this)
        this._accelCallbackRef = Some(cb)
        let opts = Options(interval: IntervalOption.SensorNumber(ACCEL_INTERVAL_NS))
        try {
            on(SensorId.Accelerometer, cb, option: opts)
            Hilog.info(0, "CjTelegram", "[RaiseToListen] Accelerometer subscribed")
        } catch (_: BusinessException) {
            Hilog.info(0, "CjTelegram", "[RaiseToListen] Accelerometer subscribe failed")
            this._accelCallbackRef = None
        }
    }

    private func stopAccelerometer(): Unit {
        match (this._accelCallbackRef) {
            case Some(cb) =>
                try {
                    off(SensorId.Accelerometer, callback: cb)
                } catch (_: BusinessException) {}
                this._accelCallbackRef = None
            case None => ()
        }
    }

    private func startProximity(): Unit {
        let selfRef = this
        let id = getDeviceProximityUtils().addProximityCallback({ isNear: Bool =>
            selfRef.onProximityChanged(isNear)
        })
        this._proximityCallbackId = id
        this._isNear = getDeviceProximityUtils().isNear()
        Hilog.info(0, "CjTelegram", "[RaiseToListen] Proximity subscribed")
    }

    private func stopProximity(): Unit {
        if (this._proximityCallbackId >= 0) {
            getDeviceProximityUtils().removeProximityCallback(this._proximityCallbackId)
            this._proximityCallbackId = -1
        }
        this._isNear = false
    }

    /**
     * 加速度计回调 — 判定手机是否竖立并抬起（由 AccelCallback 委托调用）
     * 注意：此方法在 SensorKit 传感器线程调用，不含 @State，线程安全（R-69 不适用于此层）
     */
    public func onAccelData(x: Float32, y: Float32, z: Float32): Unit {
        let total: Float32 = Float32(sqrt(Float64(x * x + y * y + z * z)))
        let isRaisedNow: Bool = z > RAISE_Z_THRESHOLD && total >= ACCEL_TOTAL_MIN && total <= ACCEL_TOTAL_MAX
        if (isRaisedNow) {
            this._accelFramesSatisfied = this._accelFramesSatisfied + 1
        } else {
            this._accelFramesSatisfied = 0
        }
        let wasRaised = this._isRaised
        this._isRaised = this._accelFramesSatisfied >= ACTIVATION_FRAME_COUNT
        if (wasRaised != this._isRaised) {
            this.evaluateGesture()
        }
    }

    /**
     * 距离传感器变化回调（由 startProximity 闭包调用）
     */
    public func onProximityChanged(isNear: Bool): Unit {
        this._isNear = isNear
        this.evaluateGesture()
    }

    /**
     * 手势综合判定：加速度（抬起） + 距离（靠近） → 激活/取消
     */
    private func evaluateGesture(): Unit {
        let shouldBeActive: Bool = this._isRaised && this._isNear && this._enabled
        if (shouldBeActive && !this._isActive) {
            this.triggerActivate()
        } else if (!shouldBeActive && this._isActive) {
            this.triggerDeactivate()
        }
    }

    private func triggerActivate(): Unit {
        this._isActive = true
        Hilog.info(0, "CjTelegram", "[RaiseToListen] Activated: switching to earpiece")
        match (this._onActivate) {
            case Some(cb) => cb()
            case None => ()
        }
    }

    private func triggerDeactivate(): Unit {
        this._isActive = false
        Hilog.info(0, "CjTelegram", "[RaiseToListen] Deactivated: switching to speaker")
        match (this._onDeactivate) {
            case Some(cb) => cb()
            case None => ()
        }
    }

    private func deactivateIfNeeded(): Unit {
        if (this._isActive) {
            this.triggerDeactivate()
        }
    }
}

/**
 * 加速度计回调实现 — 委托给 RaiseToListenService
 * SensorKit 回调在传感器线程，Service 层无 @State，可直接调用。
 * UI 层若需更新状态，须在 launch{} 中进行（R-69）。
 */
class AccelCallback <: Callback1Argument<AccelerometerResponse> {
    private let _service: RaiseToListenService

    init(service!: RaiseToListenService) {
        this._service = service
    }

    public func invoke(err: ?BusinessException, arg: AccelerometerResponse): Unit {
        match (err) {
            case Some(_) => ()
            case None =>
                this._service.onAccelData(arg.x, arg.y, arg.z)
        }
    }
}

// ---- 单例访问 ----

private var _raiseToListenServiceInstance: Option<RaiseToListenService> = None

/**
 * 获取抬起收听服务单例
 */
public func getRaiseToListenService(): RaiseToListenService {
    match (_raiseToListenServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = RaiseToListenService()
            _raiseToListenServiceInstance = Some(svc)
            return svc
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MiscSettingsStore — 杂项开关持久化（Preferences，store: telegram_misc）
//
// 存储 P2-326 DataStorageSettingsPage 杂项 section 的三个用户偏好：
//   - raise_to_listen_enabled  : Bool（对应 iOS MediaInputSettings.enableRaiseToSpeak）
//   - pause_music_on_recording : Bool（对应 iOS MediaInputSettings.pauseMusicOnRecording）
//   - save_edited_photos       : Bool（对应 iOS GeneratedMediaStoreSettings.storeEditedPhotos）
// ─────────────────────────────────────────────────────────────────────────────

let MISC_STORE_NAME: String = "telegram_misc"
let KEY_RAISE_TO_LISTEN: String = "raise_to_listen_enabled"
let KEY_PAUSE_MUSIC: String = "pause_music_on_recording"
let KEY_SAVE_EDITED_PHOTOS: String = "save_edited_photos"
// diag-suite_settings_privacy-TC-0127.md P4（DataPrivacySettingsPage）：两个纯本地展示
// 偏好，源侧无对应真实 TL 同步字段（Suggest Frequent Contacts 是客户端本地排序提示；
// Link Previews 的源侧值来自 secretChatLinkPreviews 账号级 preference，本仓无 secret
// chat 引擎，按本地开关落地，默认 true 对齐源侧 `secretChatLinkPreviews ?? true`）。
let KEY_SUGGEST_FREQUENT_CONTACTS: String = "suggest_frequent_contacts"
let KEY_SECRET_CHAT_LINK_PREVIEWS: String = "secret_chat_link_previews"

/**
 * 杂项设置存储器 — 负责 P2-326 杂项开关的 Preferences 持久化。
 * 防死状态：所有读取均从 Preferences 真实查询，不硬编码覆盖已保存值。
 */
public class MiscSettingsStore {
    private var _prefs: Option<Preferences> = None

    private func ensurePrefs(): Unit {
        match (this._prefs) {
            case Some(_) => ()
            case None =>
                match (getGlobalAbilityContext()) {
                    case None =>
                        Hilog.info(0, "CjTelegram", "[MiscSettings] No ability context — in-memory only")
                    case Some(ctx) =>
                        try {
                            let prefs = Preferences.getPreferences(ctx, MISC_STORE_NAME)
                            this._prefs = Some(prefs)
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[MiscSettings] Prefs open failed: ${e}")
                        }
                }
        }
    }

    private func readBool(key: String, fallback: Bool): Bool {
        this.ensurePrefs()
        match (this._prefs) {
            case None => return fallback
            case Some(prefs) =>
                try {
                    let dv: Int64 = if (fallback) { 1 } else { 0 }
                    let val = prefs.get(key, PreferencesValueType.Integer(dv))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return fallback
                    }
                } catch (_: Exception) { return fallback }
        }
    }

    private func writeBool(key: String, value: Bool): Unit {
        this.ensurePrefs()
        match (this._prefs) {
            case None => ()
            case Some(prefs) =>
                try {
                    let v: Int64 = if (value) { 1 } else { 0 }
                    prefs.put(key, PreferencesValueType.Integer(v))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[MiscSettings] writeBool(${key}) err: ${e}")
                }
        }
    }

    /**
     * 抬起收听开关 — 对应 iOS MediaInputSettings.enableRaiseToSpeak
     * 默认 true，对位 MediaInputSettings.defaultSettings
     */
    public func getRaiseToListenEnabled(): Bool {
        return this.readBool(KEY_RAISE_TO_LISTEN, true)
    }

    public func saveRaiseToListenEnabled(enabled: Bool): Unit {
        this.writeBool(KEY_RAISE_TO_LISTEN, enabled)
        Hilog.info(0, "CjTelegram", "[MiscSettings] raiseToListenEnabled=${enabled}")
    }

    /**
     * 录音时暂停音乐 — 对应 iOS MediaInputSettings.pauseMusicOnRecording
     * 默认 true，对位 MediaInputSettings.defaultSettings
     */
    public func getPauseMusicOnRecording(): Bool {
        return this.readBool(KEY_PAUSE_MUSIC, true)
    }

    public func savePauseMusicOnRecording(enabled: Bool): Unit {
        this.writeBool(KEY_PAUSE_MUSIC, enabled)
        Hilog.info(0, "CjTelegram", "[MiscSettings] pauseMusicOnRecording=${enabled}")
    }

    /**
     * 保存编辑后的照片 — 对应 iOS GeneratedMediaStoreSettings.storeEditedPhotos
     * 默认 true，对位 GeneratedMediaStoreSettings.defaultSettings
     */
    public func getSaveEditedPhotos(): Bool {
        return this.readBool(KEY_SAVE_EDITED_PHOTOS, true)
    }

    public func saveSaveEditedPhotos(enabled: Bool): Unit {
        this.writeBool(KEY_SAVE_EDITED_PHOTOS, enabled)
        Hilog.info(0, "CjTelegram", "[MiscSettings] saveEditedPhotos=${enabled}")
    }

    /**
     * 优先展示常聊联系人 — 对应 iOS Privacy_TopPeers（frequentContacts）。默认 true
     * （对位源侧 dataPrivacyControllerEntries 调用点 frequentContacts 由
     * ApplicationSpecificPreferencesKeys.topPeers 驱动，客户端首次默认开启）。
     */
    public func getSuggestFrequentContacts(): Bool {
        return this.readBool(KEY_SUGGEST_FREQUENT_CONTACTS, true)
    }

    public func saveSuggestFrequentContacts(enabled: Bool): Unit {
        this.writeBool(KEY_SUGGEST_FREQUENT_CONTACTS, enabled)
        Hilog.info(0, "CjTelegram", "[MiscSettings] suggestFrequentContacts=${enabled}")
    }

    /**
     * 私密聊天链接预览 — 对应 iOS Privacy_SecretChatsLinkPreviews（secretChatLinkPreviews）。
     * 默认 true（对位源侧 `secretChatLinkPreviews ?? true`）。
     */
    public func getSecretChatLinkPreviews(): Bool {
        return this.readBool(KEY_SECRET_CHAT_LINK_PREVIEWS, true)
    }

    public func saveSecretChatLinkPreviews(enabled: Bool): Unit {
        this.writeBool(KEY_SECRET_CHAT_LINK_PREVIEWS, enabled)
        Hilog.info(0, "CjTelegram", "[MiscSettings] secretChatLinkPreviews=${enabled}")
    }
}

// 单例
private var _miscSettingsStoreInstance: Option<MiscSettingsStore> = None

public func getMiscSettingsStore(): MiscSettingsStore {
    match (_miscSettingsStoreInstance) {
        case Some(s) => return s
        case None =>
            let s = MiscSettingsStore()
            _miscSettingsStoreInstance = Some(s)
            return s
    }
}
