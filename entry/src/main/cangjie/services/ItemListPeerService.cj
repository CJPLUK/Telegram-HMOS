package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.Chat
import std.collection.ArrayList
import std.time.DateTime

/**
 * 用户列表项数据层 (ItemListPeerItem)
 *
 * 封装 peer 相关的 TL 方法，供 ItemListPeerComponent 等 UI 组件使用。
 * 调用链: Service → MTProtoClient.sendRequest()
 *
 * 注意: 不重复实现聊天列表或联系人服务，使用 RealChatListService / RealContactService 已有能力。
 * 本服务提供 peer 解析、展示数据获取等 ItemListPeerItem 专用接口。
 */
private var _itemListPeerServiceInstance: Option<ItemListPeerService> = None

public func getItemListPeerService(): ItemListPeerService {
    match (_itemListPeerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ItemListPeerService()
            _itemListPeerServiceInstance = Some(inst)
            return inst
    }
}

/**
 * Peer 展示数据 — 用于 ItemListPeerComponent 渲染
 */
public class PeerDisplayData {
    public var peerId: Int64 = 0
    public var peerType: String = "user"
    public var displayName: String = ""
    public var avatarLocalPath: String = ""
    public var statusText: String = ""
    public var isOnline: Bool = false
    public var accessHash: Int64 = 0
    public var username: String = ""

    public func getInitial(): String {
        if (this.displayName.size > 0) {
            let runes = this.displayName.toRuneArray()
            if (runes.size > 0) {
                return runes[0].toString().toAsciiUpper()
            }
        }
        return "?"
    }
}

public class ItemListPeerService {

    /**
     * 通过用户名解析 peer
     * TL: contacts.resolveUsername
     * 调用链: Service → MTProtoClient.sendRequest()
     */
    public func resolvePeerByUsername(username: String): Option<PeerDisplayData> {
        if (username.isEmpty()) {
            return None
        }
        let cleanUsername = username.replace("@", "")
        if (cleanUsername.isEmpty()) {
            return None
        }

        Hilog.info(0, "CjTelegram", "[ItemListPeerService] resolvePeerByUsername: ${cleanUsername}")
        let client = getMTProtoClient()

        let req = ContactsResolveUsername()
        req.username = cleanUsername

        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[ItemListPeerService] resolvePeerByUsername: empty response")
            return None
        }

        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[ItemListPeerService] RPC Error: ${errorCode} - ${errorMessage}")
                return None
            }
        }

        let response = ContactsResolvedPeerResponse.deserialize(responseData)
        let msgService = getRealMessageService()
        let photoService = getUserPhotoService()

        let peerId = response.peer.id
        let peerType = response.peer.type_

        if (peerType == "user") {
            for (user in response.users) {
                if (user.id == peerId) {
                    if (user.accessHash != 0) {
                        msgService.cacheUserAccessHash(user.id, user.accessHash)
                    }
                    photoService.cacheUser(user)

                    let data = PeerDisplayData()
                    data.peerId = user.id
                    data.peerType = "user"
                    data.displayName = user.firstName
                    if (user.lastName.size > 0) {
                        data.displayName = data.displayName + " " + user.lastName
                    }
                    if (data.displayName.isEmpty() && user.username.size > 0) {
                        data.displayName = "@" + user.username
                    }
                    if (data.displayName.isEmpty()) {
                        data.displayName = "User ${user.id}"
                    }
                    data.accessHash = user.accessHash
                    data.username = user.username
                    data.isOnline = user.statusType == "online"
                    data.statusText = formatPeerStatus(user)
                    data.avatarLocalPath = photoService.getUserPhotoPath(user.id)
                    return Some(data)
                }
            }
        } else if (peerType == "channel" || peerType == "chat") {
            for (chat in response.chats) {
                if (chat.id == peerId) {
                    if (chat.isChannel && chat.accessHash != 0) {
                        msgService.cacheChannelAccessHash(chat.id, chat.accessHash)
                    }

                    let data = PeerDisplayData()
                    data.peerId = chat.id
                    data.peerType = peerType
                    data.displayName = chat.title
                    if (data.displayName.isEmpty()) {
                        data.displayName = "Chat ${chat.id}"
                    }
                    data.accessHash = chat.accessHash
                    data.username = chat.username
                    data.statusText = if (chat.isChannel) { "channel" } else { "group" }
                    data.avatarLocalPath = ""
                    return Some(data)
                }
            }
        }

        Hilog.info(0, "CjTelegram", "[ItemListPeerService] resolvePeerByUsername: peer not found in response")
        return None
    }

    /**
     * 从 ContactDisplayData 转换为 PeerDisplayData
     */
    public func contactToPeerDisplay(contact: ContactDisplayData): PeerDisplayData {
        let data = PeerDisplayData()
        data.peerId = contact.userId
        data.peerType = "user"
        data.displayName = contact.getDisplayName()
        data.accessHash = contact.accessHash
        data.username = contact.username
        data.isOnline = contact.isOnline
        data.statusText = contact.getLastSeenText()
        data.avatarLocalPath = getUserPhotoService().getUserPhotoPath(contact.userId)
        return data
    }

    /**
     * 从 Chat 转换为 PeerDisplayData
     */
    public func chatToPeerDisplay(chat: Chat): PeerDisplayData {
        let data = PeerDisplayData()
        data.peerId = chat.id
        data.peerType = chat.peerType
        data.displayName = chat.name
        data.avatarLocalPath = chat.avatarLocalPath
        data.username = chat.username
        data.isOnline = chat.isOnline
        data.statusText = if (chat.isGroup || chat.isChannel) { "" } else { chat.lastMessage }
        return data
    }
}

func formatPeerStatus(user: UserResponse): String {
    if (user.statusType == "online") {
        return "online"
    }
    if (user.statusType == "recently") {
        return "last seen recently"
    }
    if (user.statusType == "lastWeek") {
        return "last seen within a week"
    }
    if (user.statusType == "lastMonth") {
        return "last seen within a month"
    }
    if (user.wasOnline > 0) {
        return formatLastSeenForPeer(user.wasOnline)
    }
    if (user.isBot) {
        return "bot"
    }
    return "last seen a long time ago"
}

func formatLastSeenForPeer(wasOnline: Int32): String {
    let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let nowSec = Int64(nowMs) / 1000
    let diff = nowSec - Int64(wasOnline)

    if (diff < 60) {
        return "last seen just now"
    }
    if (diff < 3600) {
        let mins = diff / 60
        return "last seen ${mins} minutes ago"
    }
    if (diff < 86400) {
        let hours = diff / 3600
        return "last seen ${hours} hours ago"
    }
    if (diff < 172800) {
        return "last seen yesterday"
    }
    if (diff < 604800) {
        let days = diff / 86400
        return "last seen ${days} days ago"
    }
    return "last seen a long time ago"
}
