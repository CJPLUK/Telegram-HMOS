package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.Chat
import std.collection.ArrayList

/**
 * 搜索结果分区头数据层
 *
 * 对应 iOS ChatListSearchItemHeader
 * 来源: input/Telegram-iOS/submodules/ChatListSearchItemHeader/Sources/ChatListSearchItemHeader.swift
 *
 * 职责:
 * - 提供分区头标题 (getTitleForType)
 * - 提供本地对话搜索结果 (getLocalDialogsForSearch) — 委托 RealChatListService，调用链完整
 *
 * 调用链: ChatListSearchItemHeaderService.getLocalDialogsForSearch
 *   → RealChatListService.getDialogs → MTProtoClient.sendRequest(messages.getDialogs)
 *
 * iOS 覆盖: getTitleForType ✓ | getLocalDialogsForSearch ✓ | LocalPeers/GlobalPeers/RecentPeers
 * Contacts/Members/Bots/Admins/Channels/Chats/Messages/Text ✓ | 本地化 DEFERRED(多语言)
 */
private var _headerServiceInstance: Option<ChatListSearchItemHeaderService> = None

public func getChatListSearchItemHeaderService(): ChatListSearchItemHeaderService {
    match (_headerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ChatListSearchItemHeaderService()
            _headerServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 分区头类型 (对应 iOS ChatListSearchItemHeaderType)
 */
public enum ChatListSearchHeaderType {
    | LocalPeers
    | GlobalPeers
    | RecentPeers
    | Contacts
    | Members
    | Bots
    | Admins
    | Channels
    | Chats
    | Messages
    | Text
}

public class ChatListSearchItemHeaderService {

    /**
     * 根据分区类型返回本地化标题
     * 对应 iOS type.title(strings:)
     */
    public func getTitleForType(headerType: ChatListSearchHeaderType): String {
        match (headerType) {
            case ChatListSearchHeaderType.LocalPeers => return "DIALOGS"
            case ChatListSearchHeaderType.GlobalPeers => return "GLOBAL"
            case ChatListSearchHeaderType.RecentPeers => return "RECENT"
            case ChatListSearchHeaderType.Contacts => return "CONTACTS"
            case ChatListSearchHeaderType.Members => return "MEMBERS"
            case ChatListSearchHeaderType.Bots => return "BOTS"
            case ChatListSearchHeaderType.Admins => return "ADMINS"
            case ChatListSearchHeaderType.Channels => return "CHANNELS"
            case ChatListSearchHeaderType.Chats => return "CHATS"
            case ChatListSearchHeaderType.Messages => return "MESSAGES"
            case ChatListSearchHeaderType.Text => return ""
        }
    }

    /**
     * 获取本地对话搜索结果（用于「本地对话」分区）
     * 委托 RealChatListService.getDialogs，调用链 Service → MTProtoClient.send() 完整
     *
     * @param query 搜索关键词，空字符串时返回全部
     * @param limit 最大数量
     */
    public func getLocalDialogsForSearch(query: String, limit: Int32): ArrayList<Chat> {
        let chatListService = getRealChatListService()
        let dialogs = chatListService.getDialogs(limit: limit, offsetDate: 0, folderId: 0)

        if (query.isEmpty()) {
            return dialogs
        }

        let q = query.toAsciiLower()
        let result = ArrayList<Chat>()
        for (chat in dialogs) {
            if (chat.name.toAsciiLower().contains(q) || chat.lastMessage.toAsciiLower().contains(q)) {
                result.add(chat)
            }
        }
        Hilog.info(0, "CjTelegram", "[ChatListSearchItemHeaderService] getLocalDialogsForSearch: query='${query}' -> ${result.size} matches")
        return result
    }
}
