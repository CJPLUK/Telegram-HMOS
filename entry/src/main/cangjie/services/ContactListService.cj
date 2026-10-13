package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

/**
 * 联系人列表 API 服务（ContactListUI 专用）
 *
 * 封装联系人列表相关的 TL 方法调用：
 * - contacts.getContacts — 委托 RealContactService.getContacts()
 * - contacts.search — 委托 RealContactService.searchContacts()
 * - contacts.getTopPeers — 委托 RealContactService.getTopPeers()（P2-157b 真实 RPC）
 *
 * 复用 RealContactService，不创建新的联系人服务（anti_pattern）。
 * 调用链：ContactListPage → ContactListService → RealContactService → MTProtoClient.send()
 */
private var _contactListServiceInstance: Option<ContactListService> = None

public func getContactListService(): ContactListService {
    match (_contactListServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ContactListService()
            _contactListServiceInstance = Some(inst)
            return inst
    }
}

public class ContactListService {

    /**
     * 获取联系人列表
     * 调用 contacts.getContacts (0x5dd69e12)
     * 委托 RealContactService.getContacts()
     */
    public func getContacts(): ArrayList<ContactDisplayData> {
        return getRealContactService().getContacts()
    }

    /**
     * 搜索联系人
     * 调用 contacts.search (0x11f812d8)
     * 委托 RealContactService.searchContacts()
     */
    public func searchContacts(query: String, limit!: Int32 = 20): ArrayList<ContactDisplayData> {
        return getRealContactService().searchContacts(query, limit: limit)
    }

    /**
     * 获取常用联系人（Top Peers）
     * P2-157b: 调用 contacts.getTopPeers#973478b6 真实 RPC，返回带 rating 的热度排序结果。
     * 委托 RealContactService.getTopPeers()，含 hash 增量缓存（not_modified 时用本地缓存）。
     */
    public func getTopPeers(): ArrayList<ContactDisplayData> {
        Hilog.info(0, "CjTelegram", "[ContactListService] getTopPeers: delegating to RealContactService")
        return getRealContactService().getTopPeers()
    }

    /**
     * P2-157 Gap 5: 搜索远端 peers（contacts.search#11f812d8 → contacts.found#b3134d9d）
     * 对应 iOS TelegramEngine.Contacts.searchRemotePeers()
     * 使用 MTProto contacts.search 接口，返回全网用户/联系人搜索结果
     */
    public func searchRemotePeers(query: String, limit!: Int32 = 50): ArrayList<ContactDisplayData> {
        return getRealContactService().searchRemotePeers(query, limit: limit)
    }
}
