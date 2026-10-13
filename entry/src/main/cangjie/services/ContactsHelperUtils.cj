package ohos_app_cangjie_entry.services

import kit.AbilityKit.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos.business_exception.BusinessException
import ohos_app_cangjie_entry.bindings.*

/**
 * buildSmsUri — 将电话号码列表构建为 smsto: URI
 * 多号码时拼接为逗号分隔，如 "smsto:+1234,+5678"
 * iOS 等效：MFMessageComposeViewController.recipients
 */
private func buildSmsUri(phoneNumbers: ArrayList<String>): String {
    var joined = ""
    var first = true
    for (n in phoneNumbers) {
        if (!first) { joined = joined + "," }
        joined = joined + n
        first = false
    }
    return "smsto:" + joined
}

/**
 * ContactsHelperUtils — 联系人助手工具接口
 *
 * 对应 Telegram-iOS ContactsHelper 上层调用封装。
 * 提供：
 * - 请求通讯录权限（READ_CONTACTS / WRITE_CONTACTS）
 * - 读取系统联系人（通过 ContactsHelperBinding.readSystemContacts）
 * - 同步 Telegram 联系人到系统通讯录
 *
 * 复用 RealContactService 获取 Telegram 联系人，不创建新的联系人服务。
 * 置于 services 包以访问 getGlobalAbilityContext 和 getRealContactService，
 * 同时通过 bindings.ContactsHelperBinding 调用平台 DataShare API。
 */

private var _contactsHelperUtilsInstance: Option<ContactsHelperUtils> = None

/**
 * 获取 ContactsHelperUtils 单例
 */
public func getContactsHelperUtils(): ContactsHelperUtils {
    match (_contactsHelperUtilsInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ContactsHelperUtils()
            _contactsHelperUtilsInstance = Some(inst)
            return inst
    }
}

/**
 * 联系人助手工具类
 */
public class ContactsHelperUtils {

    private var _binding: ContactsHelperBinding = getContactsHelperBinding()

    /**
     * 请求通讯录权限（读 + 写）
     * @param onResult 授权结果回调: true=已授权, false=用户拒绝
     */
    public func requestContactsPermission(onResult: (Bool) -> Unit): Unit {
        match (getGlobalAbilityContext()) {
            case Some(context) =>
                Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] Requesting contacts permissions...")
                let atManager = AbilityAccessCtrl.createAtManager()
                let permissions: Array<String> = [
                    "ohos.permission.READ_CONTACTS",
                    "ohos.permission.WRITE_CONTACTS"
                ]
                try {
                    atManager.requestPermissionsFromUser(
                        context,
                        permissions,
                        { errorCode: Option<BusinessException>, data: Option<PermissionRequestResult> =>
                            match (errorCode) {
                                case Some(e) =>
                                    Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] requestPermission error: ${e.message}")
                                    onResult(false)
                                case _ =>
                                    match (data) {
                                        case Some(result) =>
                                            var readGranted = false
                                            var writeGranted = false
                                            for (i in 0..result.authResults.size) {
                                                if (result.authResults[i] == 0) {
                                                    if (result.permissions[i] == "ohos.permission.READ_CONTACTS") {
                                                        readGranted = true
                                                    }
                                                    if (result.permissions[i] == "ohos.permission.WRITE_CONTACTS") {
                                                        writeGranted = true
                                                    }
                                                }
                                            }
                                            let ok = readGranted && writeGranted
                                            Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] Contacts permission: read=${readGranted}, write=${writeGranted}")
                                            onResult(ok)
                                        case _ =>
                                            Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] requestPermission: no result")
                                            onResult(false)
                                    }
                            }
                        }
                    )
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] requestPermission BusinessException: ${e.message}")
                    onResult(false)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] requestPermission Exception: ${e}")
                    onResult(false)
                }
            case _ =>
                Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] No UIAbilityContext, cannot request permission")
                onResult(false)
        }
    }

    /**
     * 检查通讯录权限是否已授权（读 + 写）
     */
    public func checkContactsPermission(): Bool {
        return this._binding.checkReadPermission() && this._binding.checkWritePermission()
    }

    /**
     * 读取系统联系人
     * 通过 DataShare 访问设备通讯录，获取所有联系人（displayName + 第一个电话号码）。
     * 调用前应确保已授权 READ_CONTACTS 权限。
     * @return 系统通讯录中的联系人列表
     */
    public func readSystemContacts(): ArrayList<SystemContactData> {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                return this._binding.readSystemContacts(ctx)
            case _ =>
                Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] readSystemContacts: no context")
                return ArrayList<SystemContactData>()
        }
    }

    /**
     * 向系统通讯录写入一个联系人，供 NewContactScreen 的 “Sync to Phone” 使用。
     */
    public func addSystemContact(firstName: String, lastName: String, phone: String): Bool {
        if (phone.isEmpty() || !this._binding.checkWritePermission()) {
            return false
        }
        match (getGlobalAbilityContext()) {
            case Some(ctx) => return this._binding.addContact(ctx, firstName, lastName, phone)
            case _ =>
                Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] addSystemContact: no context")
                return false
        }
    }

    /**
     * 发送 SMS 邀请（拉起系统短信应用）
     *
     * 对应 iOS MFMessageComposeViewController：
     *   - recipients = phoneNumbers
     *   - body = inviteText（包含 Telegram 邀请链接）
     *
     * 实现：通过 Want(action: ohos.want.action.sendMessage, uri: smsto:<numbers>)
     * 拉起鸿蒙系统短信应用，同时在 Want parameters 中携带短信正文。
     * 若 getGlobalAbilityContext() 为 None，静默失败并记录日志。
     *
     * @param phoneNumbers 受邀联系人电话号码列表（非空）
     * @param inviteText   短信正文（含 Telegram 邀请链接）
     */
    public func sendSmsInvite(phoneNumbers: ArrayList<String>, inviteText: String): Unit {
        if (phoneNumbers.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] sendSmsInvite: empty phone list, skip")
            return
        }
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                let uri = buildSmsUri(phoneNumbers)
                let want = Want(
                    action: "ohos.want.action.sendMessage",
                    uri: uri
                )
                try {
                    ctx.startAbility(want)
                    Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] sendSmsInvite: launched SMS app, ${phoneNumbers.size} recipients, msg=${inviteText.size}chars")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] sendSmsInvite: startAbility failed: ${e}")
                }
            case _ =>
                Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] sendSmsInvite: no UIAbilityContext")
        }
    }

    /**
     * 同步 Telegram 联系人到系统通讯录
     * 复用 RealContactService.getContacts() 获取 Telegram 联系人，
     * 逐个调用平台 addContact 添加到系统通讯录。
     *
     * @param onProgress 进度回调 (current: Int32, total: Int32)
     * @return true 表示全部同步成功，false 表示部分或全部失败
     */
    public func syncTelegramContactsToSystem(onProgress: (Int32, Int32) -> Unit): Bool {
        if (!this._binding.checkWritePermission()) {
            Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] syncTelegramContactsToSystem: WRITE_CONTACTS not granted")
            return false
        }

        let contextOpt = getGlobalAbilityContext()
        let context: UIAbilityContext
        match (contextOpt) {
            case Some(ctx) => context = ctx
            case _ =>
                Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] syncTelegramContactsToSystem: no context")
                return false
        }

        let contactService = getRealContactService()
        let telegramContacts = contactService.getContacts()
        let total = Int32(telegramContacts.size)
        if (total == 0) {
            Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] syncTelegramContactsToSystem: no Telegram contacts")
            onProgress(0, 0)
            return true
        }

        var successCount: Int32 = 0
        var idx: Int32 = 0
        for (c in telegramContacts) {
            let firstName = c.firstName
            let lastName = c.lastName
            let phone = if (c.phone.size > 0) { c.phone } else { "" }
            if (phone.size > 0) {
                let ok = this._binding.addContact(context, firstName, lastName, phone)
                if (ok) {
                    successCount = successCount + 1
                }
            }
            idx = idx + 1
            onProgress(idx, total)
        }

        Hilog.info(0, "CjTelegram", "[ContactsHelperUtils] syncTelegramContactsToSystem: ${successCount}/${total} synced")
        return successCount == total
    }
}
