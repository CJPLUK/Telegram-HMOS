package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog

/**
 * 删除对话操作项枚举
 *
 * 对应 iOS DeleteChatPeerAction（削减至 Cangjie 版本实际使用的分支）
 *   delete          — 普通用户对话删除；普通群离开
 *   deleteAndLeave  — 普通群/频道按 peerType 调用对应离开接口
 *   clearHistory    — 仅清空消息历史（revoke=true，justClear=true）
 */
public enum DeleteChatPeerActionType {
    | Delete
    | DeleteAndLeave
    | ClearHistory
}

/**
 * 删除对话操作项数据层 — DeleteChatPeerActionSheetService
 *
 * 职责：
 *   - 封装 "删除/离开/清空历史" 三种操作的调用入口
 *   - 委托 RealChatListService.deleteDialog → messages.deleteHistory /
 *     messages.deleteChatUser / channels.leaveChannel
 *
 * 调用链:
 *   DeleteChatPeerActionSheetComponent.onClickDelete()
 *     → DeleteChatPeerActionSheetService.performAction(...)
 *       → RealChatListService.deleteDialog(peerType, peerId)
 *         → MTProtoClient.send()
 */
private var _deleteChatPeerActionSheetServiceInstance: Option<DeleteChatPeerActionSheetService> = None

public func getDeleteChatPeerActionSheetService(): DeleteChatPeerActionSheetService {
    match (_deleteChatPeerActionSheetServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = DeleteChatPeerActionSheetService()
            _deleteChatPeerActionSheetServiceInstance = Some(inst)
            return inst
    }
}

public class DeleteChatPeerActionSheetService {

    /**
     * 执行删除 / 离开 / 清空历史操作
     *
     * @param peerType  "user" | "chat" | "channel"
     * @param peerId    Telegram peer ID
     * @param action    DeleteChatPeerActionType 枚举
     * @return true 表示服务器确认操作成功
     *
     * 实现细节:
     *   - DeleteAndLeave 保留真实 peerType，由底层选择普通群或频道接口
     *   - ClearHistory   调用消息服务的 clearHistory，不触发退群
     *   - Delete         直接委托 deleteDialog
     */
    public func performAction(peerType: String, peerId: Int64, action: DeleteChatPeerActionType): Bool {
        Hilog.info(0, "CjTelegram", "[DeleteChatPeerActionSheetService] performAction: peerType=${peerType} peerId=${peerId}")
        let chatListService = getRealChatListService()
        match (action) {
            case DeleteChatPeerActionType.DeleteAndLeave =>
                return chatListService.deleteDialog(peerType, peerId)
            case DeleteChatPeerActionType.ClearHistory =>
                return getRealMessageService().clearHistory(
                    peerType,
                    peerId,
                    maxId: 2147483646,
                    justClear: true,
                    revoke: false
                )
            case DeleteChatPeerActionType.Delete =>
                return chatListService.deleteDialog(peerType, peerId)
        }
    }

    /**
     * 根据 peerType 推断默认操作类型
     *
     * 规则与 iOS DeleteChatPeerActionSheetItem 保持一致:
     *   channel / megagroup → DeleteAndLeave
     *   其他               → Delete
     */
    public func defaultAction(peerType: String): DeleteChatPeerActionType {
        if (peerType == "channel") {
            return DeleteChatPeerActionType.DeleteAndLeave
        }
        return DeleteChatPeerActionType.Delete
    }

    /**
     * 根据 peerType 和 action 返回确认文案
     * 对应 iOS strings.ChatList_DeleteChatConfirmation / LeaveGroupConfirmation 等
     */
    public func confirmationText(peerName: String, peerType: String, action: DeleteChatPeerActionType): String {
        match (action) {
            case DeleteChatPeerActionType.DeleteAndLeave =>
                return "Are you sure you want to delete and leave \"${peerName}\"?"
            case DeleteChatPeerActionType.ClearHistory =>
                return "Are you sure you want to clear all messages in \"${peerName}\"?"
            case DeleteChatPeerActionType.Delete =>
                if (peerType == "chat") {
                    return "Are you sure you want to leave the group \"${peerName}\"?"
                }
                return "Are you sure you want to delete the chat with ${peerName}?"
        }
    }

    /**
     * 根据 action 返回操作按钮文案
     */
    public func actionButtonText(action: DeleteChatPeerActionType): String {
        match (action) {
            case DeleteChatPeerActionType.DeleteAndLeave => return "Delete and Leave"
            case DeleteChatPeerActionType.ClearHistory => return "Clear History"
            case DeleteChatPeerActionType.Delete => return "Delete"
        }
    }
}
