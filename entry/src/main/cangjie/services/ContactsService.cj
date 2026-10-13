package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import std.collection.HashMap

/**
 * ContactsService — TelegramEngine 联系人引擎层
 *
 * 对应 iOS TelegramEngine.Contacts
 * 封装高级联系人管理 TL 方法，复用 RealContactService 的基础实现
 *
 * 职责：
 * - importContacts / deleteContacts / addContact / resolveUsername / block / unblock / resetSaved
 * - 不重复实现已有逻辑，委托 RealContactService 执行
 */
private var _contactsServiceInstance: Option<ContactsService> = None

public func getContactsService(): ContactsService {
    match (_contactsServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ContactsService()
            _contactsServiceInstance = Some(inst)
            return inst
    }
}

public class ContactsService {
    private let realContactService = getRealContactService()

    /**
     * 批量导入联系人（contacts.importContacts）
     * 委托 RealContactService.importContact 逐条导入
     */
    public func importContacts(contacts: ArrayList<InputPhoneContact>): ArrayList<ContactDisplayData> {
        Hilog.info(0, "CjTelegram", "[ContactsService] importContacts: ${contacts.size} contacts")
        let result = ArrayList<ContactDisplayData>()
        for (c in contacts) {
            let opt = this.realContactService.importContact(c.phone, c.firstName, c.lastName)
            match (opt) {
                case Some(contact) => result.add(contact)
                case None => ()
            }
        }
        if (result.size > 0) {
            setContactsNeedRefresh()
        }
        return result
    }

    /**
     * 删除联系人（contacts.deleteContacts）
     */
    public func deleteContacts(userIds: ArrayList<Int64>): Bool {
        Hilog.info(0, "CjTelegram", "[ContactsService] deleteContacts: ${userIds.size} users")
        let msgService = getRealMessageService()
        var allOk = true
        for (userId in userIds) {
            let accessHash = msgService.getAccessHashForUser(userId)
            let ok = this.realContactService.deleteContact(userId, accessHash)
            if (!ok) { allOk = false }
        }
        if (allOk && userIds.size > 0) {
            setContactsNeedRefresh()
        }
        return allOk
    }

    /**
     * 添加联系人（contacts.addContact）
     */
    public func addContact(userId: Int64, accessHash: Int64, firstName: String, lastName: String, phone: String): Bool {
        let ok = this.realContactService.addContact(userId, accessHash, firstName, lastName, phone)
        if (ok) {
            setContactsNeedRefresh()
        }
        return ok
    }

    /**
     * 重置已保存联系人（contacts.resetSaved）
     * 移除所有未关联 Telegram 账户的联系人
     */
    public func resetSaved(): Bool {
        Hilog.info(0, "CjTelegram", "[ContactsService] resetSaved")
        let client = getMTProtoClient()
        let req = ContactsResetSaved()
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size >= 4) {
            let d = TLDeserializer(responseData)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errorCode = d.readInt32()
                let errorMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[ContactsService] resetSaved RPC Error: %{public}s", [errorMsg])
                return false
            }
            Hilog.info(0, "CjTelegram", "[ContactsService] resetSaved success")
            setContactsNeedRefresh()
            return true
        }
        return false
    }

    /**
     * 解析用户名（contacts.resolveUsername）
     */
    public func resolveUsername(username: String): Option<ContactDisplayData> {
        return this.realContactService.resolveUsername(username)
    }

    /**
     * 屏蔽用户（contacts.block）
     */
    public func blockUser(userId: Int64, accessHash: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[ContactsService] blockUser: ${userId}")
        let client = getMTProtoClient()
        let peer = InputPeerUser()
        peer.userId = userId
        peer.accessHash = accessHash
        let req = ContactsBlock()
        req.id = peer
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size >= 4) {
            let d = TLDeserializer(responseData)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errorCode = d.readInt32()
                let errorMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[ContactsService] blockUser RPC Error: ${errorCode} - ${errorMsg}")
                return false
            }
            Hilog.info(0, "CjTelegram", "[ContactsService] blockUser success")
            return true
        }
        return false
    }

    /**
     * 解除屏蔽（contacts.unblock）
     */
    public func unblockUser(userId: Int64, accessHash: Int64): Bool {
        return this.realContactService.unblockUser(userId, accessHash)
    }

    /**
     * 获取联系人列表（委托 RealContactService）
     */
    public func getContacts(): ArrayList<ContactDisplayData> {
        return this.realContactService.getContacts()
    }

    /**
     * 获取屏蔽用户列表（委托 RealContactService）
     */
    public func getBlockedUsers(): ArrayList<BlockedUserDisplayData> {
        return this.realContactService.getBlockedUsers()
    }

    // ==================== P2-157 Gaps ====================

    /**
     * P2-157 Gap 1: 删除所有联系人（contacts.deleteContacts + contacts.resetSaved）
     * 对应 iOS _internal_deleteAllContacts = deleteContacts(all) + resetSaved()
     */
    public func deleteAllContacts(): Bool {
        Hilog.info(0, "CjTelegram", "[ContactsService] deleteAllContacts: fetching all contacts")
        let allContacts = this.realContactService.getContacts()
        let allIds = ArrayList<Int64>()
        for (c in allContacts) {
            allIds.add(c.userId)
        }
        var deleteOk = true
        if (allIds.size > 0) {
            deleteOk = this.deleteContacts(allIds)
        }
        let resetOk = this.resetSaved()
        if (deleteOk && resetOk) {
            setContactsNeedRefresh()
        }
        return deleteOk && resetOk
    }

    /**
     * P2-157 Gap 2a: 更新联系人姓名（contacts.addContact#e8f463d0 with flags=0）
     * 对应 iOS _internal_updateContactName
     */
    public func updateContactName(userId: Int64, accessHash: Int64, firstName: String, lastName: String): Bool {
        let ok = this.realContactService.updateContactName(userId, accessHash, firstName, lastName)
        if (ok) {
            setContactsNeedRefresh()
        }
        return ok
    }

    /**
     * P2-157 Gap 2b: 更新联系人备注（contacts.updateContactNote#139a8c7b）
     * 对应 iOS _internal_updateContactNote
     */
    public func updateContactNote(userId: Int64, accessHash: Int64, noteText: String): Bool {
        return this.realContactService.updateContactNote(userId, accessHash, noteText)
    }

    /**
     * P2-157 Gap 3: 获取设备联系人被导入的次数
     * 对应 iOS _internal_deviceContactsImportedByCount
     */
    public func deviceContactsImportedByCount(phones: ArrayList<String>): HashMap<String, Int32> {
        return getRealContactService().getImportedByCountForPhones(phones)
    }

    /**
     * P2-157 Gap 4: 接受并共享联系人（contacts.acceptContact#f831a20f）
     * 对应 iOS _internal_acceptAndShareContact
     */
    public func acceptAndShareContact(userId: Int64, accessHash: Int64): Bool {
        return this.realContactService.acceptAndShareContact(userId, accessHash)
    }

    /**
     * P2-157 Gap 5: 搜索远端 peers（contacts.search → contacts.found）
     * 对应 iOS _internal_searchPeers → searchRemotePeers
     */
    public func searchRemotePeers(query: String, limit!: Int32 = 50): ArrayList<ContactDisplayData> {
        return this.realContactService.searchRemotePeers(query, limit: limit)
    }

    /**
     * P2-157 Gap 6: 设备联系人同步开关
     * 对应 iOS updateIsContactSynchronizationEnabled
     */
    public func updateDeviceContactsSyncEnabled(enabled: Bool): Unit {
        this.realContactService.setDeviceSyncEnabled(enabled)
    }

    public func getDeviceContactsSyncEnabled(): Bool {
        return this.realContactService.getDeviceSyncEnabled()
    }

    /**
     * P2-157 Gap 7: 通过本地联系人 ID 查找 Telegram peer
     * 对应 iOS findPeerByLocalContactIdentifier
     */
    public func findContactByLocalId(localId: String): Option<Int64> {
        return this.realContactService.findByLocalContactId(localId)
    }
}
