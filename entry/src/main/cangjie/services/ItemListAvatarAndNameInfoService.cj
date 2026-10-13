package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList

/**
 * ItemListAvatarAndNameInfoService — 资料头部项数据层
 *
 * 对应 iOS ItemListAvatarAndNameItem.swift（ItemListAvatarAndNameInfoItem 数据提供侧）
 *
 * 功能:
 * - 封装 peer 头像 + 名称 + 在线/成员数状态的数据获取
 * - 编辑态：调用 MTProtoClient.sendRequest() 提交名称更新
 * - 调用链: Service.updatePeerName() → MTProtoClient.sendRequest()
 */
private var _itemListAvatarAndNameInfoServiceInstance: Option<ItemListAvatarAndNameInfoService> = None

public func getItemListAvatarAndNameInfoService(): ItemListAvatarAndNameInfoService {
    match (_itemListAvatarAndNameInfoServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ItemListAvatarAndNameInfoService()
            _itemListAvatarAndNameInfoServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 资料头部展示数据
 * 对应 iOS: ItemListAvatarAndNameInfoItem 构造参数的展示子集
 */
public class AvatarAndNameInfoData {
    public var peerId: Int64 = 0
    public var peerType: String = "user"
    public var displayName: String = ""
    public var firstName: String = ""
    public var lastName: String = ""
    public var avatarUrl: String = ""
    public var statusText: String = ""
    public var isOnline: Bool = false
    public var memberCount: Int64 = 0
    public var accessHash: Int64 = 0
    public var isBot: Bool = false
    public var isChannel: Bool = false
}

public class ItemListAvatarAndNameInfoService {

    /**
     * 从缓存中获取 peer 的头像+名称+状态数据（同步，无网络请求）
     * 用于 View 渲染前构建展示数据
     */
    public func getAvatarAndNameInfo(peerId: Int64, peerType: String): AvatarAndNameInfoData {
        let data = AvatarAndNameInfoData()
        data.peerId = peerId
        data.peerType = peerType

        let photoService = getUserPhotoService()
        let presenceService = getPeerPresenceStatusManagerService()

        if (peerType == "user" || peerType == "") {
            let cachedUser = photoService.getCachedUser(peerId)
            match (cachedUser) {
                case Some(user) =>
                    data.firstName = user.firstName
                    data.lastName = user.lastName
                    data.displayName = buildDisplayName(user.firstName, user.lastName)
                    data.avatarUrl = photoService.getUserPhotoPath(peerId)
                    data.isOnline = user.isOnline
                    data.accessHash = user.accessHash
                    data.isBot = user.isBot
                    data.statusText = presenceService.formatText(
                        user.isOnline,
                        user.wasOnline,
                        user.statusType
                    )
                case None =>
                    data.displayName = "User ${peerId}"
                    data.statusText = ""
            }
        } else if (peerType == "channel" || peerType == "chat" || peerType == "group") {
            let chatListService = getRealChatListService()
            let chatOpt = chatListService.getCachedChat(peerId)
            match (chatOpt) {
                case Some(chat) =>
                    data.displayName = chat.title
                    data.avatarUrl = ""
                    data.isChannel = chat.isChannel
                    data.accessHash = chat.accessHash
                    let cnt = Int64(chat.participantsCount)
                    if (cnt > 0) {
                        data.memberCount = cnt
                        if (chat.isChannel) {
                            data.statusText = "${cnt} subscribers"
                        } else {
                            data.statusText = "${cnt} members"
                        }
                    } else if (chat.isChannel) {
                        data.statusText = "channel"
                    } else {
                        data.statusText = "group"
                    }
                case None =>
                    data.displayName = "Chat ${peerId}"
                    data.statusText = ""
            }
        }

        return data
    }

    /**
     * 更新个人用户名称（名+姓）
     * 调用链: Service → MTProtoClient.sendRequest() → account.updateProfile
     *
     * @param firstName 新名
     * @param lastName  新姓
     * @return true 更新成功，false 失败
     */
    public func updateUserName(firstName: String, lastName: String): Bool {
        Hilog.info(0, "CjTelegram", "[ILANI] updateUserName: '${firstName}' '${lastName}'")
        let client = getMTProtoClient()

        let req = AccountUpdateProfile()
        req.firstName = Some(firstName)
        req.lastName = Some(lastName)

        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[ILANI] updateUserName: empty response")
            return false
        }

        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMsg = checkD.readString()
                Hilog.info(0, "CjTelegram", "[ILANI] updateUserName RPC Error: ${errorCode} ${errorMsg}")
                return false
            }
        }

        Hilog.info(0, "CjTelegram", "[ILANI] updateUserName: success")
        return true
    }

    /**
     * 更新群/频道标题
     * 调用链: Service → MTProtoClient.sendRequest() → channels.editTitle / messages.editChatTitle
     *
     * @param chatId      群/频道 ID
     * @param accessHash  频道 access hash（群组传 0）
     * @param isChannel   是否为频道
     * @param title       新标题
     * @return true 更新成功，false 失败
     */
    public func updateChatTitle(chatId: Int64, accessHash: Int64, isChannel: Bool, title: String): Bool {
        Hilog.info(0, "CjTelegram", "[ILANI] updateChatTitle: chatId=${chatId} title='${title}'")
        let client = getMTProtoClient()

        let responseData: Array<Byte>
        if (isChannel) {
            let req = ChannelsEditTitle()
            let peer = InputChannel()
            peer.channelId = chatId
            peer.accessHash = accessHash
            req.channel = peer
            req.title = title
            responseData = client.sendRequest(req.toBytes())
        } else {
            let req = MessagesEditChatTitle()
            req.chatId = chatId
            req.title = title
            responseData = client.sendRequest(req.toBytes())
        }

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[ILANI] updateChatTitle: empty response")
            return false
        }

        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMsg = checkD.readString()
                Hilog.info(0, "CjTelegram", "[ILANI] updateChatTitle RPC Error: ${errorCode} ${errorMsg}")
                return false
            }
        }

        Hilog.info(0, "CjTelegram", "[ILANI] updateChatTitle: success")
        return true
    }
}

/**
 * 拼接显示名称：firstName + lastName
 */
func buildDisplayName(firstName: String, lastName: String): String {
    if (firstName.size > 0 && lastName.size > 0) {
        return firstName + " " + lastName
    }
    if (firstName.size > 0) {
        return firstName
    }
    if (lastName.size > 0) {
        return lastName
    }
    return ""
}
