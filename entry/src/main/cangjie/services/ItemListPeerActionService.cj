package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * 用户操作列表项数据层 (ItemListPeerActionItem)
 *
 * 对应 iOS ItemListPeerActionItem — 提供列表项操作所需的 TL 封装。
 * 委托 RealChatListService / RealContactService 执行实际请求，不重复实现。
 *
 * 调用链: ItemListPeerActionService → RealChatListService/RealContactService → MTProtoClient.send()
 *
 * iOS 覆盖: deleteDialog ✓ | togglePin ✓ | toggleMute ✓ | markAsRead ✓ | blockUser ✓
 * unblockUser ✓ | archiveChat ✓ | unarchiveChat ✓ | clearHistory DEFERRED(可选)
 */
private var _peerActionServiceInstance: Option<ItemListPeerActionService> = None

public func getItemListPeerActionService(): ItemListPeerActionService {
    match (_peerActionServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ItemListPeerActionService()
            _peerActionServiceInstance = Some(inst)
            return inst
    }
}

public class ItemListPeerActionService {

    /**
     * 删除对话
     * 委托 RealChatListService.deleteDialog → messages.deleteHistory / channels.leaveChannel
     */
    public func deleteDialog(peerType: String, peerId: Int64): Bool {
        return getRealChatListService().deleteDialog(peerType, peerId)
    }

    /**
     * 置顶/取消置顶对话
     * 委托 RealChatListService.togglePinDialog → messages.toggleDialogPin
     */
    public func togglePin(peerType: String, peerId: Int64, pinned: Bool): Bool {
        return getRealChatListService().togglePinDialog(peerType, peerId, pinned)
    }

    /**
     * 静音/取消静音对话
     * 委托 RealChatListService.toggleMuteDialog → account.updateNotifySettings
     */
    public func toggleMute(peerType: String, peerId: Int64, muted: Bool): Bool {
        return getRealChatListService().toggleMuteDialog(peerType, peerId, muted)
    }

    /**
     * 标记对话已读
     * 委托 RealChatListService.markDialogAsRead → messages.readHistory / channels.readHistory
     */
    public func markAsRead(peerType: String, peerId: Int64): Bool {
        return getRealChatListService().markDialogAsRead(peerType, peerId)
    }

    /**
     * 屏蔽用户
     * 封装 contacts.block TL 方法
     */
    public func blockUser(userId: Int64, accessHash: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[ItemListPeerActionService] blockUser: ${userId}")
        let client = getMTProtoClient()
        try {
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
                    let errCode = d.readInt32()
                    let errMsg = d.readString()
                    Hilog.info(0, "CjTelegram", "[ItemListPeerActionService] blockUser RPC Error: ${errCode} - ${errMsg}")
                    return false
                }
            }
            Hilog.info(0, "CjTelegram", "[ItemListPeerActionService] blockUser success")
            return responseData.size > 0
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ItemListPeerActionService] blockUser exception: ${e}")
            return false
        }
    }

    /**
     * 解除屏蔽
     * 委托 RealContactService.unblockUser → contacts.unblock
     */
    public func unblockUser(userId: Int64, accessHash: Int64): Bool {
        return getRealContactService().unblockUser(userId, accessHash)
    }

    /**
     * 归档对话
     * 委托 RealChatListService.archiveChat → folders.editPeerFolders
     */
    public func archiveChat(peerType: String, peerId: Int64): Bool {
        return getRealChatListService().archiveChat(peerType, peerId)
    }

    /**
     * 取消归档
     * 委托 RealChatListService.unarchiveChat → folders.editPeerFolders
     */
    public func unarchiveChat(peerType: String, peerId: Int64): Bool {
        return getRealChatListService().unarchiveChat(peerType, peerId)
    }
}
