package ohos_app_cangjie_entry.services

import kit.AbilityKit.*
import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import ohos.business_exception.BusinessException
import std.collection.HashMap
import ohos_app_cangjie_entry.interop.*

/**
 * DeviceAccessService — 设备能力访问管理
 *
 * 对应 iOS DeviceAccess.swift 中的 DeviceAccess 类（`DeviceAccessSubject` 含
 * camera/microphone/mediaLibrary/location/contacts/notifications/siri/cellularData）。
 * 封装相机、麦克风、相册、位置、通讯录、通知六类权限的：
 *   1. 查询（checkAccess）
 *   2. 请求（requestAccess）
 *   3. 跳转系统设置（openSystemSettings）
 *
 * 无 MTProto 依赖（N/A）。
 * 复用 PermissionsService 的 AbilityAccessCtrl 模式，不重复实现。
 */

public enum DeviceAccessType {
    | Camera
    | Microphone
    | PhotoLibrary
    | Location
    | Contacts
    | Notifications
}

// interop 契约字符串（对位 iOS DeviceAccess.swift `DeviceAccessSubject.notifications` →
// `authorizationStatus(subject:)`）。值须与 ArkTS 侧 InteropRegistry.ets 的
// `registerArkFunc(...)` 注册名逐字一致（D3 契约，见 dev_pattern LocalAuthManager 范式）。
// 本 feature（deviceaccess）allowlist 不含 interop.cj / ets/interop/*，未在 interop.cj
// 追加同名公共常量——契约以此处的字符串字面量为准，接线义务见
// emitted_integration_contracts[ic_notif_enabled_query]。
private let INTEROP_NOTIF_ENABLED: String = "notif.enabled"

// interop 契约字符串（对位 iOS DeviceAccess.swift `registerForNotifications` →
// `UNUserNotificationCenter.requestAuthorization` 系统弹窗）。HarmonyOS 侧对等能力是
// `notificationManager.requestEnableNotification(context, callback)`（真实存在，见
// @ohos.notificationManager.d.ts:694-746 "display a dialog box prompting the user to
// enable notification"；本工程 entry/src/main/ets/entryability/EntryAbility.ets:57 冷启动
// 时已在调用同一 API），不是 atManager.requestPermissionsFromUser 覆盖的 AccessToken 类
// 权限，但确有等价弹窗能力。同样受 deviceaccess allowlist 限制未在 interop.cj 追加同名
// 公共常量，接线义务见 emitted_integration_contracts[ic_notif_request_enable]。
private let INTEROP_NOTIF_REQUEST_ENABLE: String = "notif.requestEnable"

// Preferences store + key 复用既有 "telegram_contacts_settings"（core/storage/AuthStorage.cj
// clearAll() 已把该 store 整体纳入登出清理，新 key 自动继承同一生命周期，无需额外接线）。
// 记录"本应用是否已完成过一次通讯录授权请求"——contacts 的 NotDetermined 在本工程无平台 API
// 可直接查（AtManager.checkAccessToken 只回二值 Granted/Denied），故按底层事实（是否已发起过
// 一次请求）持久化复刻，而非按表现拼阈值。
private let CONTACTS_PREFS_STORE: String = "telegram_contacts_settings"
private let CONTACTS_ACCESS_REQUESTED_KEY: String = "contacts_access_requested"

public enum DeviceAccessStatus {
    | Authorized
    | Denied
    | NotDetermined
}

private var _deviceAccessServiceInstance: Option<DeviceAccessService> = None

public func getDeviceAccessService(): DeviceAccessService {
    match (_deviceAccessServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = DeviceAccessService()
            _deviceAccessServiceInstance = Some(svc)
            return svc
    }
}

/**
 * 通知权限"是否应显示红色警示徽标"的共享判据（对位 iOS DeviceAccess.swift:55-62
 * shouldDisplayNotificationsPermissionWarning）：
 *   Authorized      => false（已授权，无需提醒）
 *   NotDetermined   => !suppressed（从未询问，除非用户已主动关闭过该提醒）
 *   Denied          => true（已拒绝，持续提醒）
 * file-scope 公共函数（非类方法），供多个消费方共用同一份真值表——现有消费方
 * pages/MainTabPage.cj:651-663 refreshSettingsBadgeAsync() 内联复刻了同一段 match，
 * 待 uif_tabbarui 后续改为直接调用本函数；set_root_and_search 的
 * emitted_integration_contracts[ic_notifications_permission_warning_query] 请求的正是
 * 这个共享查询，Settings "Notifications and Sounds" 行的徽标接线由该 feature 后续消费。
 */
public func shouldDisplayNotificationsPermissionWarning(status: DeviceAccessStatus, suppressed: Bool): Bool {
    match (status) {
        case DeviceAccessStatus.Authorized => return false
        case DeviceAccessStatus.NotDetermined => return !suppressed
        case DeviceAccessStatus.Denied => return true
    }
}

public class DeviceAccessService {

    // 通知授权态缓存（对位 iOS DeviceAccess.notificationsPromise：一次探测，缓存复用，
    // 回前台可显式 refreshNotificationsStatus() 重新取值）。None = 尚未探测到有效值。
    private var _notificationsEnabled: Option<Bool> = None
    private var _notificationsProbeDispatched: Bool = false

    /**
     * 查询权限当前状态（同步，不弹窗）
     */
    public func checkAccess(accessType: DeviceAccessType): DeviceAccessStatus {
        match (accessType) {
            case DeviceAccessType.Camera => return this.checkCameraStatus()
            case DeviceAccessType.Microphone => return this.checkMicrophoneStatus()
            case DeviceAccessType.PhotoLibrary => return this.checkPhotoLibraryStatus()
            case DeviceAccessType.Location => return this.checkLocationStatus()
            case DeviceAccessType.Contacts => return this.checkContactsStatus()
            case DeviceAccessType.Notifications => return this.checkNotificationsStatus()
        }
    }

    /**
     * 请求权限（若已授权直接回调 true，否则弹系统权限弹窗）
     */
    public func requestAccess(accessType: DeviceAccessType, onResult: (Bool) -> Unit): Unit {
        match (accessType) {
            case DeviceAccessType.Camera => this.requestCameraAccess(onResult)
            case DeviceAccessType.Microphone => this.requestMicrophoneAccess(onResult)
            case DeviceAccessType.PhotoLibrary => this.requestPhotoLibraryAccess(onResult)
            case DeviceAccessType.Location => ensureLocationPermission(onResult)
            case DeviceAccessType.Contacts => getContactsHelperUtils().requestContactsPermission({ g: Bool =>
                this.recordContactsRequest()
                onResult(g)
            })
            case DeviceAccessType.Notifications => this.requestNotificationsAccess(onResult)
        }
    }

    /**
     * 跳转系统设置（权限被拒绝时引导用户手动开启）
     * 对应 iOS openSettings 回调
     */
    public func openSystemSettings(): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let params = HashMap<String, WantValueType>()
                    params["pushParams"] = WantValueType.StringValue("com.hmcangjie.telegram")
                    let want = Want(
                        bundleName: "com.huawei.hmos.settings",
                        abilityName: "com.huawei.hmos.settings.MainAbility",
                        uri: "application_info_entry",
                        parameters: params
                    )
                    ctx.startAbility(want)
                    Hilog.info(0, "CjTelegram", "[DeviceAccessService] Opened system settings")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[DeviceAccessService] openSystemSettings failed: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[DeviceAccessService] openSystemSettings: no context")
        }
    }

    // ==================== Camera ====================

    private func checkCameraStatus(): DeviceAccessStatus {
        try {
            let atManager = AbilityAccessCtrl.createAtManager()
            let bundleInfo = BundleManager.getBundleInfoForSelf(BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
            let gs = atManager.checkAccessToken(bundleInfo.appInfo.accessTokenId, "ohos.permission.CAMERA")
            if (gs == GrantStatus.PermissionGranted) {
                return DeviceAccessStatus.Authorized
            } else {
                return DeviceAccessStatus.Denied
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[DeviceAccessService] checkCamera error: ${e}")
            return DeviceAccessStatus.NotDetermined
        }
    }

    private func requestCameraAccess(onResult: (Bool) -> Unit): Unit {
        this.requestSinglePermission("ohos.permission.CAMERA", "Camera", onResult)
    }

    // ==================== Microphone ====================

    private func checkMicrophoneStatus(): DeviceAccessStatus {
        try {
            let atManager = AbilityAccessCtrl.createAtManager()
            let bundleInfo = BundleManager.getBundleInfoForSelf(BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
            let gs = atManager.checkAccessToken(bundleInfo.appInfo.accessTokenId, "ohos.permission.MICROPHONE")
            if (gs == GrantStatus.PermissionGranted) {
                return DeviceAccessStatus.Authorized
            } else {
                return DeviceAccessStatus.Denied
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[DeviceAccessService] checkMicrophone error: ${e}")
            return DeviceAccessStatus.NotDetermined
        }
    }

    private func requestMicrophoneAccess(onResult: (Bool) -> Unit): Unit {
        this.requestSinglePermission("ohos.permission.MICROPHONE", "Microphone", onResult)
    }

    // ==================== PhotoLibrary ====================
    // 权限治理返修（gallery-nopermission）：保存到相册已迁移到
    // photoAccessHelper.showAssetsCreationDialog（免 WRITE_IMAGEVIDEO 常驻权限的用户确认
    // 弹窗，见 SaveToCameraRollService.cj），因此不再需要声明/检查/申请该 AccessToken 权限
    // ——恒为 Authorized，调用方（如 DeviceAccessPage.cj）据此展示"已授权"状态。

    private func checkPhotoLibraryStatus(): DeviceAccessStatus {
        return DeviceAccessStatus.Authorized
    }

    private func requestPhotoLibraryAccess(onResult: (Bool) -> Unit): Unit {
        Hilog.info(0, "CjTelegram", "[DeviceAccessService] PhotoLibrary: no permission required (uses showAssetsCreationDialog)")
        onResult(true)
    }

    // ==================== Location ====================

    private func checkLocationStatus(): DeviceAccessStatus {
        match (checkLocationPermission()) {
            case LocationPermissionStatus.Granted => return DeviceAccessStatus.Authorized
            case LocationPermissionStatus.NotRequested => return DeviceAccessStatus.NotDetermined
            case _ => return DeviceAccessStatus.Denied
        }
    }

    // ==================== Contacts ====================
    // TC-0179 修法 1（diag-suite_contacts_peers-TC-0179.md）：恢复源侧
    // DeviceAccess.swift:156-171 的三态（.allowed/.notDetermined/.denied）。AtManager 只有
    // checkAccessToken（GrantStatus 二值 Granted/Denied）与 requestPermissionsFromUser，无任何
    // API（含 ArkTS 互操作）能在请求前区分"从未询问"与"已拒绝"（getPermissionsStatus 属系统应用
    // API，本工程 apl=normal 取不到）。故 NotDetermined 按底层事实——"本应用是否已完成过一次
    // 通讯录授权请求"——用 Preferences 持久化复刻，而非按表现拼阈值/特判表。
    //
    // D-163（round3 reject 修复）：本服务是模块级惰性单例（:65-75 `_deviceAccessServiceInstance`），
    // 生命周期跨越账号登出/登入；`CONTACTS_PREFS_STORE` 会被 `AuthStorage.clearAll()`
    // （core/storage/AuthStorage.cj:1853-1862）整体清空。round3 曾在此处加一层
    // `Option<Bool>` 读透缓存，但 clearAll() 及其调用方从未触达本单例，导致同进程内登出对
    // `checkContactsStatus()` 的回答完全不生效、跨进程重启还会把"已拒绝"误判回
    // "从未询问"。改为**不做跨调用缓存**：每次都直接读 Preferences（本地 flash 读，源侧
    // `CNContactStore.authorizationStatus` 本身也是按需查询而非缓存），天然与任何登出清理
    // 路径保持一致，无需额外的 invalidate 接线。

    private func contactsRequestRecorded(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, CONTACTS_PREFS_STORE)
                    let v = prefs.get(CONTACTS_ACCESS_REQUESTED_KEY, PreferencesValueType.Integer(0))
                    match (v) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return false
                    }
                } catch (e: Exception) {
                    // 取不到 context 或抛异常时保守取 Denied 分支（应用内 alert），而不是发起
                    // 一次用户看不见的无声请求。
                    Hilog.info(0, "CjTelegram", "[DeviceAccessService] contactsRequestRecorded read error: ${e}")
                    return true
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[DeviceAccessService] contactsRequestRecorded: no context")
                return true
        }
    }

    private func recordContactsRequest(): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, CONTACTS_PREFS_STORE)
                    prefs.put(CONTACTS_ACCESS_REQUESTED_KEY, PreferencesValueType.Integer(1))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[DeviceAccessService] recordContactsRequest write error: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[DeviceAccessService] recordContactsRequest: no context")
        }
    }

    private func checkContactsStatus(): DeviceAccessStatus {
        if (getContactsHelperUtils().checkContactsPermission()) {
            return DeviceAccessStatus.Authorized
        }
        if (this.contactsRequestRecorded()) {
            return DeviceAccessStatus.Denied
        }
        return DeviceAccessStatus.NotDetermined
    }

    // ==================== Notifications ====================
    // 对应 iOS DeviceAccess.swift `DeviceAccessSubject.notifications` →
    // `authorizationStatus(subject:.notifications)`（内部经
    // `UNUserNotificationCenter.getNotificationSettings` 查询系统通知授权态，是
    // PeerInfoScreen 设置页角标 "!" 的唯一输入）。
    //
    // HarmonyOS 无 Cangjie 层 NotificationKit 绑定——`notificationManager` 只在
    // ArkTS/JS 侧存在（`@ohos.notificationManager.d.ts`），真值必须经本工程已有的
    // interop 反转桥（interop/interop.cj `callArkAsync`，与 LocalAuthManager 的
    // `LOCALAUTH_AVAILABLE` 同一"缓存 + 懒发探测"范式，见该文件头注释）取自 ArkTS
    // `notificationManager.isNotificationEnabled()`。
    //
    // 注意：这不是 PermissionsService.checkNotificationsPermission() 那种恒
    // `return false`——interop 反转桥本工程已在多处证明可行（BADGE_SET /
    // LOCALAUTH_AVAILABLE / NOTIF_PUBLISH 等），此处走的是同一条已验证通路，不复制
    // "平台做不到"的过时前提。
    //
    // 契约（string 值即约定；本 feature allowlist 不含 interop.cj/ets，未追加同名
    // 公共常量，接线义务见 emitted_integration_contracts[ic_notif_enabled_query]）：
    //   callArkAsync("notif.enabled", "{}", cb)
    //   result: {"enabled":true|false}（ArkTS 已注册并成功查询）
    //         | {"error":"..."} 或 "no ark func: notif.enabled"（ArkTS 侧尚未接线）
    // 接线完成前保留上一次已知值（初值 None → NotDetermined），绝不写死 false/true。
    //
    // requestNotificationsAccess（下方）对应 iOS `registerForNotifications` 的系统弹窗
    // 请求路径，同样经 callArkAsync（"notif.requestEnable"）诚实转发，见该函数注释与
    // emitted_integration_contracts[ic_notif_request_enable]。

    private func checkNotificationsStatus(): DeviceAccessStatus {
        this.ensureNotificationsProbeDispatched()
        match (this._notificationsEnabled) {
            case Some(true) => return DeviceAccessStatus.Authorized
            case Some(false) => return DeviceAccessStatus.Denied
            case None => return DeviceAccessStatus.NotDetermined
        }
    }

    private func ensureNotificationsProbeDispatched(): Unit {
        if (this._notificationsProbeDispatched) {
            return
        }
        this._notificationsProbeDispatched = true
        this.refreshNotificationsStatus()
    }

    /**
     * 强制重新探测通知授权态（对位 iOS `authorizationStatus(applicationInForeground:...)`
     * 的"回前台重新取值"语义）。供外部（如 tab 角标刷新）在合适时机显式调用；
     * 首次 checkAccess(Notifications) 也会懒发一次。
     *
     * ArkTS 侧尚未注册 "notif.enabled" 时 `callArkAsync` 走 interop.cj 的
     * `case None => onResult("{\"error\":\"no ark func: ...\"}")` 分支——此处按
     * "既不匹配 enabled:true 也不匹配 enabled:false" 处理，保留上一次已知值，不覆盖
     * 为 false（不得造假返回值）。
     */
    public func refreshNotificationsStatus(): Unit {
        callArkAsync(INTEROP_NOTIF_ENABLED, "{}", { res =>
            if (res.contains("\"enabled\":true")) {
                this._notificationsEnabled = Some(true)
            } else if (res.contains("\"enabled\":false")) {
                this._notificationsEnabled = Some(false)
            } else {
                Hilog.info(0, "CjTelegram", "[DeviceAccessService] refreshNotificationsStatus: unresolved (${res}); keeping last known value")
            }
        })
    }

    /**
     * 请求通知授权弹窗（对位 iOS DeviceAccess.swift `registerForNotifications` →
     * `UNUserNotificationCenter.requestAuthorization` 系统弹窗）。
     *
     * 弹窗 API 真实存在：`notificationManager.requestEnableNotification(context, callback)`
     * ——见 @ohos.notificationManager.d.ts:694-746（"display a dialog box prompting the
     * user to enable notification for your application"），本工程
     * entry/src/main/ets/entryability/EntryAbility.ets:57 冷启动时已在调用同一 API。
     * 这不是 atManager.requestPermissionsFromUser 覆盖的 AccessToken 类权限，但确有
     * 等价弹窗能力，与"平台无弹窗 API"是两回事——不得再断言后者。
     *
     * 需 ArkTS 接线，尚未接线：走与 checkNotificationsStatus 同一条 callArkAsync 反转桥
     * 诚实转发（不编造结果），而不是硬编码返回值。契约：
     *   callArkAsync("notif.requestEnable", "{}", cb)
     *   result: {"granted":true|false}（ArkTS 已注册，转发 requestEnableNotification
     *           callback 的 err===undefined 判定）
     *         | {"error":"..."} 或 "no ark func: notif.requestEnable"（ArkTS 侧尚未接线）
     * 接线完成前，两种"未真正获得授权"的情形（ArkTS 明确拒绝 / ArkTS 尚未接线）都诚实回调
     * false——区别在于：接线完成后本函数无需任何改动即可自动透传真实弹窗结果（不像硬编码
     * false 那样需要重写才能生效）。接线义务见
     * emitted_integration_contracts[ic_notif_request_enable]。
     */
    private func requestNotificationsAccess(onResult: (Bool) -> Unit): Unit {
        callArkAsync(INTEROP_NOTIF_REQUEST_ENABLE, "{}", { res =>
            if (res.contains("\"granted\":true")) {
                onResult(true)
            } else {
                Hilog.info(0, "CjTelegram", "[DeviceAccessService] requestNotificationsAccess: not granted (${res})")
                onResult(false)
            }
        })
    }

    // ==================== 通用单权限请求 ====================

    private func requestSinglePermission(perm: String, label: String, onResult: (Bool) -> Unit): Unit {
        match (getGlobalAbilityContext()) {
            case Some(context) =>
                Hilog.info(0, "CjTelegram", "[DeviceAccessService] Requesting ${label} permission...")
                let atManager = AbilityAccessCtrl.createAtManager()
                let permissions: Array<String> = [perm]
                try {
                    atManager.requestPermissionsFromUser(
                        context,
                        permissions,
                        { errorCode: Option<BusinessException>, data: Option<PermissionRequestResult> =>
                            match (errorCode) {
                                case Some(e) =>
                                    Hilog.info(0, "CjTelegram", "[DeviceAccessService] ${label} request error: ${e.message}")
                                    onResult(false)
                                case _ =>
                                    match (data) {
                                        case Some(result) =>
                                            var granted = false
                                            for (i in 0..result.authResults.size) {
                                                if (result.authResults[i] == 0) {
                                                    granted = true
                                                }
                                            }
                                            onResult(granted)
                                        case _ =>
                                            Hilog.info(0, "CjTelegram", "[DeviceAccessService] ${label} request: no result")
                                            onResult(false)
                                    }
                            }
                        }
                    )
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[DeviceAccessService] ${label} BusinessException: ${e.message}")
                    onResult(false)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[DeviceAccessService] ${label} Exception: ${e}")
                    onResult(false)
                }
            case _ =>
                Hilog.info(0, "CjTelegram", "[DeviceAccessService] No UIAbilityContext for ${label}")
                onResult(false)
        }
    }
}
