package ohos_app_cangjie_entry.services

import kit.AbilityKit.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.business_exception.BusinessException

/**
 * PermissionsService — 统一 OS 级权限管理
 *
 * 管理相机、麦克风、通讯录、位置、通知、相册等权限的检查与申请。
 * 复用 LocationService（位置）、ContactsHelperUtils（通讯录），不重复实现。
 *
 * 权限类型与 OHOS 权限映射:
 * - Camera: ohos.permission.CAMERA
 * - Microphone: ohos.permission.MICROPHONE
 * - Contacts: READ_CONTACTS + WRITE_CONTACTS (委托 ContactsHelperUtils)
 * - Location: APPROXIMATELY_LOCATION + LOCATION (委托 LocationService)
 * - PhotoLibrary: READ_IMAGEVIDEO 只用于用户明确允许后的图库读取；保存到相册继续使用
 *   photoAccessHelper.showAssetsCreationDialog，不申请 WRITE_IMAGEVIDEO。
 * - Notifications: 通知能力由 NotificationManager 管理，本服务提供占位接口
 */

public enum PermissionType {
    | Camera
    | Microphone
    | Contacts
    | Location
    | PhotoLibrary
    | Notifications
}

public enum PermissionStatus {
    | Granted
    | Denied
    | NotRequested
    | Unreachable
    | Error
}

private var _permissionsServiceInstance: Option<PermissionsService> = None

public func getPermissionsService(): PermissionsService {
    match (_permissionsServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PermissionsService()
            _permissionsServiceInstance = Some(inst)
            return inst
    }
}

public class PermissionsService {

    /**
     * 检查指定类型权限是否已授权
     */
    public func checkPermission(permType: PermissionType): Bool {
        match (permType) {
            case PermissionType.Camera => return this.checkCameraPermission()
            case PermissionType.Microphone => return this.checkMicrophonePermission()
            case PermissionType.Contacts => return getContactsHelperUtils().checkContactsPermission()
            case PermissionType.Location => return this.isLocationGranted()
            case PermissionType.PhotoLibrary => return this.checkPhotoLibraryPermission()
            case PermissionType.Notifications => return this.checkNotificationsPermission()
        }
    }

    /**
     * 请求指定类型权限
     * @param onResult true=已授权, false=用户拒绝或出错
     */
    public func requestPermission(permType: PermissionType, onResult: (Bool) -> Unit): Unit {
        match (permType) {
            case PermissionType.Camera => this.requestCameraPermission(onResult)
            case PermissionType.Microphone => this.requestMicrophonePermission(onResult)
            case PermissionType.Contacts => getContactsHelperUtils().requestContactsPermission(onResult)
            case PermissionType.Location => ensureLocationPermission(onResult)
            case PermissionType.PhotoLibrary => this.requestPhotoLibraryPermission(onResult)
            case PermissionType.Notifications => this.requestNotificationsPermission(onResult)
        }
    }

    /**
     * 检查权限，未授权则请求（一步完成）
     */
    public func ensurePermission(permType: PermissionType, onReady: (Bool) -> Unit): Unit {
        if (this.checkPermission(permType)) {
            onReady(true)
        } else {
            this.requestPermission(permType, onReady)
        }
    }

    /**
     * 统一状态侧信道（对位 iOS `PermissionRequestStatus` 四态：requestable/denied/
     * unreachable/allowed）。返回稳定编码而非 Bool，供 UI 层区分"未请求，可弹窗申请"
     * 与"平台层不可申请"两种此前被压缩成同一个 false 的语义。
     *
     * 返回值编码（固定，不得随意改动，PermissionPage.cj 按此编码分发）：
     * 0 = Granted, 1 = Denied, 2 = NotRequested, 3 = Unreachable, 4 = Error
     */
    public func statusCode(permType: PermissionType): Int64 {
        match (permType) {
            case PermissionType.Camera => return this.boolToStatusCode(this.checkCameraPermission())
            case PermissionType.Microphone => return this.boolToStatusCode(this.checkMicrophonePermission())
            case PermissionType.Location => return this.locationStatusCode()
            case PermissionType.Contacts => return this.contactsStatusCode()
            case PermissionType.PhotoLibrary => return this.photoLibraryStatusCode()
            case PermissionType.Notifications => return this.boolToStatusCode(this.checkNotificationsPermission())
        }
    }

    public func hasFullPhotoLibraryAccess(): Bool {
        return this.photoLibraryStatusCode() == 0
    }

    private func boolToStatusCode(granted: Bool): Int64 {
        if (granted) {
            return 0
        }
        return 2
    }

    private func locationStatusCode(): Int64 {
        match (checkLocationPermission()) {
            case LocationPermissionStatus.Granted => return 0
            case LocationPermissionStatus.Denied => return 2
            case LocationPermissionStatus.NotRequested => return 2
            case LocationPermissionStatus.Error => return 4
        }
    }

    // Contacts: READ_CONTACTS / WRITE_CONTACTS 在 SDK PermissionDefinitions.json 中
    // availableLevel=system_basic；本应用 provision profile apl=normal 且
    // acls.allowed-acls 为空，module.json5 不能声明这两项（声明会导致安装期 ACL 校验
    // 失败，把整个安装链路打死）⇒ 平台层目前不可申请。
    //
    // D-141 自愈实现（不硬编码常量，走真实调用路径）：查询
    // BundleManager.getBundleInfoForSelf(GET_BUNDLE_INFO_WITH_APPLICATION |
    // GET_BUNDLE_INFO_WITH_REQUESTED_PERMISSION).reqPermissionDetails——无副作用地
    // 读取"本次构建 module.json5 实际声明的权限列表"。
    //   - 今天该列表不含 ohos.permission.READ_CONTACTS ⇒ 返回 3（Unreachable，
    //     与解除前的行为一致，无回归）。
    //   - provision profile 补入 ACL 且 module.json5 同步声明后（ACL 落地后续工作，
    //     不由本 Worker 负责），该列表自动包含 READ_CONTACTS ⇒ 自动委托给本文件
    //     已存在、已走真实 AbilityAccessCtrl.checkAccessToken 调用的
    //     checkContactsPermissionStatus()，无需再改本函数或任何调用点。
    //
    // 调查记录（two-step investigation，D-141 第 1/2 条）：
    //   (a) SDK 声明：/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/
    //       toolchains/lib/PermissionDefinitions.json:4681-4687（WRITE_CONTACTS）与
    //       :4717-4723（READ_CONTACTS），均 "availableLevel": "system_basic"。
    //   (b) provision profile：build-profile.json5:34 指向的
    //       ~/.ohos/config/default_Telegram_Cangjie_....p7b，其内嵌 JSON
    //       profile 含 "apl":"normal"、"acls":{"allowed-acls":[]}（strings 该文件核实）。
    //   (c) `grep -rn "READ_CONTACTS\|WRITE_CONTACTS" entry/src/main/ets` → 0 hits
    //       （ArkTS 侧无等价绕行用法）。
    private func contactsStatusCode(): Int64 {
        try {
            let bundleInfo = BundleManager.getBundleInfoForSelf(
                BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION | BundleFlag.GET_BUNDLE_INFO_WITH_REQUESTED_PERMISSION
            )
            var contactsDeclared = false
            for (i in 0..bundleInfo.reqPermissionDetails.size) {
                if (bundleInfo.reqPermissionDetails[i].name == "ohos.permission.READ_CONTACTS") {
                    contactsDeclared = true
                }
            }
            if (!contactsDeclared) {
                return 3
            }
            match (this.checkContactsPermissionStatus()) {
                case PermissionStatus.Granted => return 0
                case PermissionStatus.Denied => return 1
                case PermissionStatus.NotRequested => return 2
                case PermissionStatus.Unreachable => return 3
                case PermissionStatus.Error => return 4
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PermissionsService] contactsStatusCode error: ${e}")
            return 3
        }
    }

    /**
     * 检查通讯录权限状态（三态：已授权 / 已拒绝 / 未请求）
     * 用于联系人列表权限门控 UI 嵌入。
     * 区分 Denied（已被用户拒绝，引导去设置）和 NotRequested（首次，可直接请求）。
     */
    public func checkContactsPermissionStatus(): PermissionStatus {
        try {
            let atManager = AbilityAccessCtrl.createAtManager()
            let bundleInfo = BundleManager.getBundleInfoForSelf(BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
            let readStatus = atManager.checkAccessToken(bundleInfo.appInfo.accessTokenId, "ohos.permission.READ_CONTACTS")
            if (readStatus == GrantStatus.PermissionGranted) {
                return PermissionStatus.Granted
            }
            // 在 HarmonyOS 中，checkAccessToken 返回 PermissionDenied 同时覆盖"未请求"和"已拒绝"
            // 通过 getGlobalAbilityContext 是否存在来判断能否请求，无法精确区分两者；
            // 实践中返回 NotRequested 使 UI 展示"允许访问"按钮触发系统弹窗
            return PermissionStatus.NotRequested
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PermissionsService] checkContactsStatus error: ${e}")
            return PermissionStatus.Error
        }
    }

    /**
     * 请求通讨录权限（委托 ContactsHelperUtils），结果在 launch{} 外层由调用方切换 UI 线程
     */
    public func requestContactsPermission(onResult: (Bool) -> Unit): Unit {
        getContactsHelperUtils().requestContactsPermission(onResult)
    }

    // ==================== Camera ====================
    private func checkCameraPermission(): Bool {
        try {
            let atManager = AbilityAccessCtrl.createAtManager()
            let bundleInfo = BundleManager.getBundleInfoForSelf(BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
            let granted = atManager.checkAccessToken(bundleInfo.appInfo.accessTokenId, "ohos.permission.CAMERA")
            return granted == GrantStatus.PermissionGranted
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PermissionsService] checkCamera error: ${e}")
            return false
        }
    }

    private func requestCameraPermission(onResult: (Bool) -> Unit): Unit {
        this.requestSinglePermission("ohos.permission.CAMERA", "Camera", onResult)
    }

    // ==================== Microphone ====================
    private func checkMicrophonePermission(): Bool {
        try {
            let atManager = AbilityAccessCtrl.createAtManager()
            let bundleInfo = BundleManager.getBundleInfoForSelf(BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
            let granted = atManager.checkAccessToken(bundleInfo.appInfo.accessTokenId, "ohos.permission.MICROPHONE")
            return granted == GrantStatus.PermissionGranted
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PermissionsService] checkMicrophone error: ${e}")
            return false
        }
    }

    private func requestMicrophonePermission(onResult: (Bool) -> Unit): Unit {
        this.requestSinglePermission("ohos.permission.MICROPHONE", "Microphone", onResult)
    }

    // ==================== Location (委托 LocationService) ====================
    private func isLocationGranted(): Bool {
        match (checkLocationPermission()) {
            case LocationPermissionStatus.Granted => return true
            case _ => return false
        }
    }

    // ==================== PhotoLibrary ====================
    // PhotoLibrary（读取路径）：只在 module.json5 确实声明 READ_IMAGEVIDEO 时呈现
    // 可申请状态，避免未声明构建误导用户进入一个永远无法完成的授权流程。
    private func photoLibraryStatusCode(): Int64 {
        try {
            let bundleInfo = BundleManager.getBundleInfoForSelf(
                BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION | BundleFlag.GET_BUNDLE_INFO_WITH_REQUESTED_PERMISSION
            )
            var photoLibraryDeclared = false
            for (i in 0..bundleInfo.reqPermissionDetails.size) {
                if (bundleInfo.reqPermissionDetails[i].name == "ohos.permission.READ_IMAGEVIDEO") {
                    photoLibraryDeclared = true
                }
            }
            if (!photoLibraryDeclared) {
                return 3
            }
            match (this.checkPhotoLibraryPermissionStatus()) {
                case PermissionStatus.Granted => return 0
                case PermissionStatus.Denied => return 1
                case PermissionStatus.NotRequested => return 2
                case PermissionStatus.Unreachable => return 3
                case PermissionStatus.Error => return 4
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PermissionsService] photoLibraryStatusCode error: ${e}")
            return 3
        }
    }

    /**
     * 检查相册读取权限状态（三态：已授权 / 已拒绝 / 未请求），逐字对位
     * checkContactsPermissionStatus()，只把探测权限名换成 READ_IMAGEVIDEO。
     * 供 photoLibraryStatusCode() 委托，覆盖 photoAccessHelper.getAssets 等读取路径。
     */
    private func checkPhotoLibraryPermissionStatus(): PermissionStatus {
        try {
            let atManager = AbilityAccessCtrl.createAtManager()
            let bundleInfo = BundleManager.getBundleInfoForSelf(BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
            let readStatus = atManager.checkAccessToken(bundleInfo.appInfo.accessTokenId, "ohos.permission.READ_IMAGEVIDEO")
            if (readStatus == GrantStatus.PermissionGranted) {
                return PermissionStatus.Granted
            }
            // 同 checkContactsPermissionStatus()：checkAccessToken 返回 PermissionDenied
            // 同时覆盖"未请求"和"已拒绝"，无法精确区分；实践中返回 NotRequested。
            return PermissionStatus.NotRequested
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PermissionsService] checkPhotoLibraryStatus error: ${e}")
            return PermissionStatus.Error
        }
    }

    private func checkPhotoLibraryPermission(): Bool {
        match (this.checkPhotoLibraryPermissionStatus()) {
            case PermissionStatus.Granted => return true
            case _ => return false
        }
    }

    private func requestPhotoLibraryPermission(onResult: (Bool) -> Unit): Unit {
        this.requestSinglePermission("ohos.permission.READ_IMAGEVIDEO", "Photos and videos", onResult)
    }

    // ==================== Notifications ====================
    // Platform constraint (Policy A): Cangjie SDK 6.0 does not expose a Cangjie binding
    // for @ohos.notificationManager.isNotificationEnabled(). That API exists only in
    // the ArkTS/JS layer (@ohos.notificationManager.d.ts, SDK verified). Attempting to
    // call it from Cangjie would require FFI not available in this SDK version.
    //
    // Therefore: notification enabled-state CANNOT be queried from Cangjie. This function
    // returns false (unknown / cannot verify) to make the honest-default safe: callers that
    // react to false will direct the user to system settings, which is always correct.
    // requestNotificationsPermission() always jumps to system settings regardless.
    private func checkNotificationsPermission(): Bool {
        // Cannot determine actual notification enabled-state from Cangjie layer.
        // Return false so callers direct the user to system settings (safe default).
        Hilog.info(0, "CjTelegram", "[PermissionsService] checkNotificationsPermission: platform limitation — returning false (direct to settings)")
        return false
    }

    /**
     * 请求通知权限 (P2-336)
     * HarmonyOS 通知属于系统授权类型（system_grant），无法通过 requestPermissionsFromUser 弹窗申请。
     * 当用户在系统设置中关闭了通知，只能引导跳转系统设置页面。
     * 对应 iOS UNUserNotificationCenter.requestAuthorization(options:)。
     * Note: checkNotificationsPermission() cannot query real state (platform limitation),
     * so this function always opens system settings — which is the correct action.
     *
     * 返修（diag-suite_settings_notifications-TC-0442.md F1）：原实现在本函数自建
     * `Want(action: "ohos.want.action.APPLICATION_DETAILS_SETTINGS", uri: "package:ohos_app_cangjie_entry")`——
     * 这是 Android `Intent`/`Uri.fromParts("package", pkg, null)` 的寻址写法，HarmonyOS 不按此解析；
     * 且括号里的 `ohos_app_cangjie_entry` 是仓颉包名（见每个 .cj 首行 `package` 声明），不是应用
     * bundleName，即使写法对寻址对象也错。`startAbility` 因而解析不到 ability，抛
     * `BusinessException 16000019`（本例被 catch 吞掉，UI 侧此前无任何反馈）。
     * 改为委托仓内已验证正确的单一实现 `DeviceAccessService.openSystemSettings()`
     * （同文件 bundleName/abilityName 显式寻址系统设置应用），不再自建 Want 字面量——
     * `pages/PermissionPage.cj openAppSettings()` 中逐字相同的第二处拷贝同步收敛到
     * 同一出口（D4.4：结构级差异结论"目标侧不得留三处散点各写各的 Want"）。
     */
    private func requestNotificationsPermission(onResult: (Bool) -> Unit): Unit {
        // 通知权限为系统授权，无法弹窗请求——引导跳转系统应用设置页
        Hilog.info(0, "CjTelegram", "[PermissionsService] Notifications: directing user to system settings")
        getDeviceAccessService().openSystemSettings()
        // 跳转后无法同步得知用户是否开启，回调 false 让调用方等待用户回到 app
        onResult(false)
    }

    // ==================== 通用单权限请求 ====================
    private func requestSinglePermission(perm: String, label: String, onResult: (Bool) -> Unit): Unit {
        match (getGlobalAbilityContext()) {
            case Some(context) =>
                Hilog.info(0, "CjTelegram", "[PermissionsService] Requesting ${label} permission...")
                let atManager = AbilityAccessCtrl.createAtManager()
                let permissions: Array<String> = [perm]
                try {
                    atManager.requestPermissionsFromUser(
                        context,
                        permissions,
                        { errorCode: Option<BusinessException>, data: Option<PermissionRequestResult> =>
                            match (errorCode) {
                                case Some(e) =>
                                    Hilog.info(0, "CjTelegram", "[PermissionsService] ${label} request error: ${e.message}")
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
                                            Hilog.info(0, "CjTelegram", "[PermissionsService] ${label} request: no result")
                                            onResult(false)
                                    }
                            }
                        }
                    )
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[PermissionsService] ${label} BusinessException: ${e.message}")
                    onResult(false)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[PermissionsService] ${label} Exception: ${e}")
                    onResult(false)
                }
            case _ =>
                Hilog.info(0, "CjTelegram", "[PermissionsService] No UIAbilityContext for ${label}")
                onResult(false)
        }
    }
}
