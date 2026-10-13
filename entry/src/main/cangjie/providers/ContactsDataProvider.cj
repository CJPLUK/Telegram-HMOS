package ohos_app_cangjie_entry.providers

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getContactsService, setContactsNeedRefresh, checkAndClearContactsRefresh, ContactDisplayData, BlockedUserDisplayData}
import ohos_app_cangjie_entry.core.mtproto.InputPhoneContact
import std.collection.ArrayList
import std.collection.HashMap

/**
 * ContactsDataProvider — 将 Contacts API 数据转为 UI 可用的 ViewModel
 *
 * 对应 iOS TelegramEngine.Contacts + TelegramEngineContacts 的 UI 适配层
 * 对应 telegram_engine_contacts feature TECNT-IF-1
 *
 * 职责：
 * - 联系人导入状态（lastImportedCount, lastError 等）
 * - 联系人同步进度/刷新标记（checkAndClearSyncNeeded）
 * - 联系人变更通知机制（notifyContactChanged）
 * - 委托 ContactsService 执行 TL 调用
 */
public class ContactsDataProvider {
    private let contactsService = getContactsService()
    private var lastImportStatus: ContactsImportStatus = ContactsImportStatus()

    /**
     * 批量导入联系人，并更新导入状态
     * @param contacts 待导入的联系人列表
     * @return 成功导入的联系人列表
     */
    public func importContacts(contacts: ArrayList<InputPhoneContact>): ArrayList<ContactDisplayData> {
        this.lastImportStatus = ContactsImportStatus()
        this.lastImportStatus.lastSuccess = false
        this.lastImportStatus.lastError = ""
        try {
            let result = this.contactsService.importContacts(contacts)
            this.lastImportStatus.lastSuccess = true
            this.lastImportStatus.lastImportedCount = Int32(result.size)
            Hilog.info(0, "CjTelegram", "[ContactsDataProvider] importContacts: ${result.size} imported")
            return result
        } catch (e: Exception) {
            this.lastImportStatus.lastError = e.toString()
            Hilog.info(0, "CjTelegram", "[ContactsDataProvider] importContacts failed: ${e}")
            return ArrayList<ContactDisplayData>()
        }
    }

    /**
     * 获取上次导入的状态（供 UI 显示）
     */
    public func getImportStatus(): ContactsImportStatus {
        return this.lastImportStatus
    }

    /**
     * 检查并清除同步刷新标记
     * 包装 RealContactService.checkAndClearContactsRefresh()
     * ContactListPage 轮询调用，检测到 true 时重新加载联系人
     */
    public func checkAndClearSyncNeeded(): Bool {
        return checkAndClearContactsRefresh()
    }

    /**
     * 通知联系人已变更，触发 ContactListPage 刷新
     * 包装 setContactsNeedRefresh()
     * 添加/删除/导入联系人后调用
     */
    public func notifyContactChanged(): Unit {
        setContactsNeedRefresh()
    }

    /**
     * 获取联系人列表（委托 ContactsService）
     */
    public func getContacts(): ArrayList<ContactDisplayData> {
        return this.contactsService.getContacts()
    }

    /**
     * 删除联系人（委托 ContactsService，成功后自动 notifyContactChanged）
     */
    public func deleteContacts(userIds: ArrayList<Int64>): Bool {
        let ok = this.contactsService.deleteContacts(userIds)
        if (ok) {
            this.notifyContactChanged()
        }
        return ok
    }

    /**
     * 添加联系人（委托 ContactsService，成功后自动 notifyContactChanged）
     */
    public func addContact(userId: Int64, accessHash: Int64, firstName: String, lastName: String, phone: String): Bool {
        let ok = this.contactsService.addContact(userId, accessHash, firstName, lastName, phone)
        if (ok) {
            this.notifyContactChanged()
        }
        return ok
    }

    /**
     * 获取屏蔽用户列表（委托 ContactsService）
     * 供 BlacklistPage 等 UI 使用
     */
    public func getBlockedUsers(): ArrayList<BlockedUserDisplayData> {
        return this.contactsService.getBlockedUsers()
    }

    /**
     * 屏蔽用户（委托 ContactsService，成功后自动 notifyContactChanged）
     */
    public func blockUser(userId: Int64, accessHash: Int64): Bool {
        let ok = this.contactsService.blockUser(userId, accessHash)
        if (ok) {
            this.notifyContactChanged()
        }
        return ok
    }

    /**
     * 解除屏蔽（委托 ContactsService，成功后自动 notifyContactChanged）
     */
    public func unblockUser(userId: Int64, accessHash: Int64): Bool {
        let ok = this.contactsService.unblockUser(userId, accessHash)
        if (ok) {
            this.notifyContactChanged()
        }
        return ok
    }

    // ==================== P2-157 Gaps ====================

    /**
     * P2-157 Gap 1: 删除所有联系人（contacts.deleteContacts + contacts.resetSaved）
     * 对应 iOS TelegramEngine.Contacts.deleteAllContacts()
     */
    public func deleteAllContacts(): Bool {
        let ok = this.contactsService.deleteAllContacts()
        if (ok) {
            this.notifyContactChanged()
        }
        return ok
    }

    /**
     * P2-157 Gap 2a: 更新联系人姓名（contacts.addContact#e8f463d0 flags=0）
     * 对应 iOS TelegramEngine.Contacts.updateContactName()
     */
    public func updateContactName(userId: Int64, accessHash: Int64, firstName: String, lastName: String): Bool {
        let ok = this.contactsService.updateContactName(userId, accessHash, firstName, lastName)
        if (ok) {
            this.notifyContactChanged()
        }
        return ok
    }

    /**
     * P2-157 Gap 2b: 更新联系人备注（contacts.updateContactNote#139a8c7b）
     * 对应 iOS TelegramEngine.Contacts.updateContactNote()
     */
    public func updateContactNote(userId: Int64, accessHash: Int64, noteText: String): Bool {
        return this.contactsService.updateContactNote(userId, accessHash, noteText)
    }

    /**
     * P2-157 Gap 3: 获取设备联系人被导入的次数
     * 对应 iOS TelegramEngine.Contacts.deviceContactsImportedByCount()
     */
    public func deviceContactsImportedByCount(phones: ArrayList<String>): HashMap<String, Int32> {
        return this.contactsService.deviceContactsImportedByCount(phones)
    }

    /**
     * P2-157 Gap 4: 接受并共享联系人（contacts.acceptContact#f831a20f）
     * 对应 iOS TelegramEngine.Contacts.acceptAndShareContact()
     */
    public func acceptAndShareContact(userId: Int64, accessHash: Int64): Bool {
        let ok = this.contactsService.acceptAndShareContact(userId, accessHash)
        if (ok) {
            this.notifyContactChanged()
        }
        return ok
    }

    /**
     * P2-157 Gap 5: 搜索远端 peers（contacts.search#11f812d8）
     * 对应 iOS TelegramEngine.Contacts.searchRemotePeers()
     */
    public func searchRemotePeers(query: String, limit!: Int32 = 50): ArrayList<ContactDisplayData> {
        return this.contactsService.searchRemotePeers(query, limit: limit)
    }

    /**
     * P2-157 Gap 6: 设备联系人同步开关（本地设置）
     * 对应 iOS TelegramEngine.Contacts.updateIsContactSynchronizationEnabled()
     */
    public func updateDeviceContactsSyncEnabled(enabled: Bool): Unit {
        this.contactsService.updateDeviceContactsSyncEnabled(enabled)
        Hilog.info(0, "CjTelegram", "[ContactsDataProvider] deviceContactsSync: ${enabled}")
    }

    public func getDeviceContactsSyncEnabled(): Bool {
        return this.contactsService.getDeviceContactsSyncEnabled()
    }

    /**
     * P2-157 Gap 7: 通过本地联系人 ID 查找 Telegram peer（userId）
     * 对应 iOS TelegramEngine.Contacts.findPeerByLocalContactIdentifier()
     */
    public func findPeerByLocalContactId(localId: String): Option<Int64> {
        return this.contactsService.findContactByLocalId(localId)
    }
}

/**
 * 联系人导入状态（UI 可用的 ViewModel）
 */
public class ContactsImportStatus {
    public var lastSuccess: Bool = false
    public var lastImportedCount: Int32 = 0
    public var lastError: String = ""
}
