package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

/**
 * 水平用户项数据层 (HorizontalPeerItem)
 *
 * 提供水平滑动的 peer 列表数据：最近联系人、在线好友等。
 * 调用链: Service → RealContactService / RealChatListService
 *
 * 参考 iOS: Telegram-iOS/submodules/HorizontalPeerItem/Sources/HorizontalPeerItem.swift
 *
 * iOS 覆盖: getRecentPeers ✓ | getRecentPeersFromChatList ✓ | sortContacts ✓
 * presence/online indicator ✓ | avatar path ✓ | DEFERRED: 群组/频道 peer 类型
 */
private var _horizontalPeerServiceInstance: Option<HorizontalPeerService> = None

public func getHorizontalPeerService(): HorizontalPeerService {
    match (_horizontalPeerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = HorizontalPeerService()
            _horizontalPeerServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 水平 peer 项展示数据
 */
public class HorizontalPeerItem {
    public var peerId: Int64 = 0
    public var peerType: String = "user"
    public var displayName: String = ""
    public var avatarLocalPath: String = ""
    public var isOnline: Bool = false
    public var accessHash: Int64 = 0
}

public class HorizontalPeerService {

    /**
     * 获取最近联系人（按最后在线时间排序，在线优先）
     * 调用 RealContactService.getContacts() + sortContacts(ByLastSeen)
     */
    public func getRecentPeers(limit!: Int32 = 12): ArrayList<HorizontalPeerItem> {
        Hilog.info(0, "CjTelegram", "[HorizontalPeerService] getRecentPeers")
        let contactService = getRealContactService()
        let contacts = contactService.getContacts()
        let sorted = sortContacts(contacts, ContactSortMode.ByLastSeen)

        let result = ArrayList<HorizontalPeerItem>()
        let photoService = getUserPhotoService()
        var count: Int32 = 0
        for (c in sorted) {
            if (count >= limit) { break }
            if (c.isSelf) { continue }
            let item = HorizontalPeerItem()
            item.peerId = c.userId
            item.peerType = "user"
            item.displayName = c.getDisplayName()
            item.avatarLocalPath = photoService.getUserPhotoPath(c.userId)
            item.isOnline = c.isOnline
            item.accessHash = c.accessHash
            result.add(item)
            count = count + 1
        }
        Hilog.info(0, "CjTelegram", "[HorizontalPeerService] returning peers")
        return result
    }

    /**
     * 从聊天列表获取最近对话的 peer（前 N 个私聊用户）
     */
    public func getRecentPeersFromChatList(limit!: Int32 = 12): ArrayList<HorizontalPeerItem> {
        Hilog.info(0, "CjTelegram", "[HorizontalPeerService] getRecentPeersFromChatList")
        let chatListService = getRealChatListService()
        let dialogs = chatListService.getDialogs(limit: Int32(30), offsetDate: 0, folderId: 0)

        let result = ArrayList<HorizontalPeerItem>()
        var count: Int32 = 0
        for (chat in dialogs) {
            if (count >= limit) { break }
            if (chat.peerType != "user") { continue }
            let item = HorizontalPeerItem()
            item.peerId = chat.id
            item.peerType = "user"
            item.displayName = chat.name
            item.avatarLocalPath = chat.avatarLocalPath
            item.isOnline = chat.isOnline
            result.add(item)
            count = count + 1
        }
        Hilog.info(0, "CjTelegram", "[HorizontalPeerService] returning peers from chat list")
        return result
    }
}
