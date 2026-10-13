package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList

/**
 * ResolveService — TelegramEngine.Resolve 解析引擎
 *
 * 对应 iOS TelegramEngine.Resolve
 * 封装 username、deep link、phone 解析的 TL 方法
 *
 * TL 方法：
 * - contacts.resolveUsername
 * - help.getDeepLinkInfo
 *
 * 复用 ContactsService.resolveUsername，扩展 getDeepLinkInfo、resolvePhoneNumber
 */
private var _resolveServiceInstance: Option<ResolveService> = None

public func getResolveService(): ResolveService {
    match (_resolveServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ResolveService()
            _resolveServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 解析结果：peer 类型 + ID + accessHash
 */
public class ResolvedPeer {
    public var peerType: String = ""
    public var peerId: Int64 = 0
    public var accessHash: Int64 = 0
    // 解析结果里 peer 的显示名（user: iOS displayTitle；chat/channel: title），供打开会话时作标题
    public var displayName: String = ""
    public var username: String = ""
}

/**
 * Deep link 解析结果
 */
public class DeepLinkInfo {
    public var message: String = ""
    public var updateApp: Bool = false
}

public class ResolveService {
    private let contactsService = getContactsService()
    private let realContactService = getRealContactService()

    /**
     * 解析用户名（contacts.resolveUsername）
     * 复用 ContactsService.resolveUsername
     */
    public func resolveUsername(username: String): Option<ContactDisplayData> {
        return this.contactsService.resolveUsername(username)
    }

    /**
     * 按名称解析 peer，返回 peer 类型 + ID + accessHash
     * 支持 user、chat、channel
     */
    public func resolvePeerByName(username: String): Option<ResolvedPeer> {
        Hilog.info(0, "CjTelegram", "[ResolveService] resolvePeerByName: ${username}")
        let client = getMTProtoClient()

        let req = ContactsResolveUsername()
        req.username = username

        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            return None
        }

        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                return None
            }
        }

        let response = ContactsResolvedPeerResponse.deserialize(responseData)
        let peer = ResolvedPeer()
        peer.peerType = response.peer.type_
        peer.peerId = response.peer.id

        // iOS _internal_resolvePeerByName writes every peer carried by
        // contacts.resolvedPeer into Postbox before returning the resolved peer.
        // Keep the same contract here: ChatRoom and avatar loading must see the
        // identity/access hash from this response, even when the peer has never
        // appeared in the local dialog list.
        let chatListService = getRealChatListService()
        for (user in response.users) {
            chatListService.cacheUserResponse(user)
        }
        for (chat in response.chats) {
            chatListService.cacheChatResponse(chat)
        }

        if (response.peer.type_ == "user") {
            for (user in response.users) {
                if (user.id == response.peer.id) {
                    peer.accessHash = user.accessHash
                    peer.displayName = userDisplayTitle(user.firstName, user.lastName, user.phone)
                    peer.username = user.username
                    let msgService = getRealMessageService()
                    if (user.accessHash != 0) {
                        msgService.cacheUserAccessHash(user.id, user.accessHash)
                    }
                    return Some(peer)
                }
            }
        } else if (response.peer.type_ == "chat" || response.peer.type_ == "channel") {
            // iOS resolvePeerByName：contacts.resolvedPeer 的 chats/users 先 updatePeers 写入 Postbox，
            // 打开会话时 getHistory 的 InputPeer（access_hash）与 Join 面板的 participationStatus
            // （channel.left）都从这份 peer 取。此前频道分支只取标题、不入缓存，经链接进入未加入的
            // 公开频道时 getHistory 拿不到 access_hash（历史为空），Join 面板也无从判断。
            let chatListSvc = getRealChatListService()
            for (chat in response.chats) {
                chatListSvc.cacheChatResponse(chat)
            }
            for (user in response.users) {
                chatListSvc.cacheUserResponse(user)
            }
            for (chat in response.chats) {
                if (chat.id == response.peer.id) {
                    peer.accessHash = chat.accessHash
                    peer.displayName = chat.title
                    peer.username = chat.username
                    return Some(peer)
                }
            }
        }

        return Some(peer)
    }

    /**
     * 解析 t.me/ 等 deep link 路径（help.getDeepLinkInfo）
     */
    public func resolveDeepLink(path: String): Option<DeepLinkInfo> {
        Hilog.info(0, "CjTelegram", "[ResolveService] resolveDeepLink: ${path}")
        let client = getMTProtoClient()

        let req = HelpGetDeepLinkInfo()
        req.path = path

        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            return None
        }

        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                return None
            }
        }

        match (DeepLinkInfoResponse.deserialize(responseData)) {
            case Some(info) =>
                let result = DeepLinkInfo()
                result.message = info.message
                result.updateApp = info.updateApp
                return Some(result)
            case None => return None
        }
    }

    /**
     * 通过手机号解析用户（contacts.importContacts）
     * 复用 RealContactService.importContact
     */
    public func resolvePhoneNumber(phone: String): Option<ContactDisplayData> {
        return this.realContactService.importContact(phone, "", "")
    }
}
