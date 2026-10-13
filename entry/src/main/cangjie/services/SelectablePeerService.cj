package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.Chat
import std.collection.ArrayList

/**
 * 可选用户节点数据层 (SelectablePeerNode)
 *
 * 封装对 peer 数据的查询，支持选择/取消选择状态管理。
 * 调用链: Service → RealContactService / RealChatListService → MTProtoClient
 *
 * 参考 iOS: Telegram-iOS/submodules/SelectablePeerNode/Sources/SelectablePeerNode.swift
 * - 提供联系人、对话列表、搜索等 peer 数据源
 * - 管理多选状态 (toggleSelection, isSelected, getSelectedPeerIds)
 */
private var _selectablePeerServiceInstance: Option<SelectablePeerService> = None

public func getSelectablePeerService(): SelectablePeerService {
    match (_selectablePeerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = SelectablePeerService()
            _selectablePeerServiceInstance = Some(inst)
            return inst
    }
}

public class SelectablePeerService {
    // 已选中的 peer ID 列表
    private var selectedPeerIds = ArrayList<Int64>()

    private func indexOfSelected(peerId: Int64): Int64 {
        var idx: Int64 = 0
        for (id in this.selectedPeerIds) {
            if (id == peerId) { return idx }
            idx = idx + 1
        }
        return -1
    }

    /**
     * 从联系人列表获取可选 peer 数据
     * 委托 RealContactService.getContacts()
     */
    public func getPeersFromContacts(): ArrayList<PeerDisplayData> {
        let contactService = getRealContactService()
        let itemListService = getItemListPeerService()
        let contacts = contactService.getContacts()
        let result = ArrayList<PeerDisplayData>()
        for (c in contacts) {
            result.add(itemListService.contactToPeerDisplay(c))
        }
        Hilog.info(0, "CjTelegram", "[SelectablePeerService] getPeersFromContacts done")
        return result
    }

    /**
     * 从对话列表获取可选 peer 数据
     * 委托 RealChatListService.getDialogs()
     */
    public func getPeersFromDialogs(limit!: Int32 = 30): ArrayList<PeerDisplayData> {
        let chatListService = getRealChatListService()
        let itemListService = getItemListPeerService()
        let dialogs = chatListService.getDialogs(limit: limit)
        let result = ArrayList<PeerDisplayData>()
        for (chat in dialogs) {
            result.add(itemListService.chatToPeerDisplay(chat))
        }
        Hilog.info(0, "CjTelegram", "[SelectablePeerService] getPeersFromDialogs done")
        return result
    }

    /**
     * 搜索 peer（联系人）
     * 委托 RealContactService.searchContacts()
     */
    public func searchPeers(query: String, limit!: Int32 = 20): ArrayList<PeerDisplayData> {
        if (query.isEmpty()) {
            return ArrayList<PeerDisplayData>()
        }
        let contactService = getRealContactService()
        let itemListService = getItemListPeerService()
        let contacts = contactService.searchContacts(query, limit: limit)
        let result = ArrayList<PeerDisplayData>()
        for (c in contacts) {
            result.add(itemListService.contactToPeerDisplay(c))
        }
        Hilog.info(0, "CjTelegram", "[SelectablePeerService] searchPeers done")
        return result
    }

    /**
     * 切换 peer 选中状态，返回切换后的选中状态
     */
    public func toggleSelection(peerId: Int64): Bool {
        let idx = this.indexOfSelected(peerId)
        if (idx >= 0) {
            this.selectedPeerIds.remove(at: idx)
            return false
        } else {
            this.selectedPeerIds.add(peerId)
            return true
        }
    }

    /**
     * 检查 peer 是否已选中
     */
    public func isSelected(peerId: Int64): Bool {
        return this.indexOfSelected(peerId) >= 0
    }

    /**
     * 获取已选中的 peer ID 列表
     */
    public func getSelectedPeerIds(): ArrayList<Int64> {
        let result = ArrayList<Int64>()
        for (id in this.selectedPeerIds) {
            result.add(id)
        }
        return result
    }

    /**
     * 清空选择
     */
    public func clearSelection(): Unit {
        this.selectedPeerIds.clear()
        Hilog.info(0, "CjTelegram", "[SelectablePeerService] clearSelection")
    }

    /**
     * 设置选中状态（批量）
     */
    public func setSelected(peerId: Int64, selected: Bool): Unit {
        let idx = this.indexOfSelected(peerId)
        if (selected && idx < 0) {
            this.selectedPeerIds.add(peerId)
        } else if (!selected && idx >= 0) {
            this.selectedPeerIds.remove(at: idx)
        }
    }
}
