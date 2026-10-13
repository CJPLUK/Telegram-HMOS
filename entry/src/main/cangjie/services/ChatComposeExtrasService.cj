package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.*
import std.collection.ArrayList
import std.collection.HashMap

/**
 * 聊天输入区的网络能力（iOS ChatController 输入面板周边）：
 *   - 私聊 UserFull 附加字段：非联系人栏（peerSettings）/ 自动删除计时器（ttl_period）
 *   - 群 / 频道 peerSettings（messages.getPeerSettings）
 *   - 非联系人栏 Add to Contacts / 关闭（contacts.addContact / messages.hidePeerSettingsBar）
 */
public class ChatComposeExtrasService {
    public init() {}

    private static func rpcError(data: Array<Byte>): String {
        if (data.size == 0) { return "empty" }
        if (data.size < 4) { return "" }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let code = d.readInt32()
            let msg = d.readString()
            return "${code} ${msg}"
        }
        return ""
    }

    /** 私聊 peer 的 UserFull（只取输入区相关字段）。 */
    public func fetchUserExtras(userId: Int64): ChatPeerFullExtras {
        let req = UsersGetFullUser()
        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = getRealMessageService().getAccessHashForUser(userId)
        req.id = inputUser
        Hilog.info(0, "CjTelegram", "[ChatComposeExtras] getFullUser ${userId} send (accessHash set=${inputUser.accessHash != 0})")
        let data = getMTProtoClient().sendRequest(req.toBytes())
        let err = ChatComposeExtrasService.rpcError(data)
        if (err.size > 0) {
            Hilog.info(0, "CjTelegram", "[ChatComposeExtras] getFullUser ${userId} failed: ${err}")
            return ChatPeerFullExtras()
        }
        let r = parseChatPeerFullExtras(data, userId: userId)
        // iOS fetchAndUpdateCachedPeerData 用 users.userFull.users 更新 peer（含 contact 位）
        var userState = "absent"
        match (r.user) {
            case Some(u) =>
                getRealChatListService().cacheUserResponse(u)
                userState = if (u.isContact) { "contact" } else { "notContact" }
            case None => ()
        }
        Hilog.info(0, "CjTelegram",
            "[ChatComposeExtras] userFull ${userId}: bytes=${data.size} parsed=${r.parsed} settings=${r.settingsFlags} add_contact=${r.canAddContact()} block=${r.canBlock()} report=${r.canReport()} user=${userState} ttl=${r.ttlPeriod} scheduled=${r.hasScheduled} cmds=${r.botCommands.size} menu=${r.menuButtonKind}")
        return r
    }

    /** 群 / 频道的 peerSettings（iOS 对非用户 peer 走 messages.getPeerSettings）。 */
    public func fetchPeerSettingsFlags(peerType: String, peerId: Int64): Option<Int32> {
        let req = MessagesGetPeerSettings()
        req.peer = getRealMessageService().buildInputPeer(peerType, peerId)
        let data = getMTProtoClient().sendRequest(req.toBytes())
        let err = ChatComposeExtrasService.rpcError(data)
        if (err.size > 0) {
            Hilog.info(0, "CjTelegram", "[ChatComposeExtras] getPeerSettings failed: ${err}")
            return None
        }
        return parsePeerSettingsFlags(data)
    }

    public func hidePeerSettingsBar(peerType: String, peerId: Int64): Bool {
        let req = MessagesHidePeerSettingsBar()
        req.peer = getRealMessageService().buildInputPeer(peerType, peerId)
        let data = getMTProtoClient().sendRequest(req.toBytes())
        return ChatComposeExtrasService.rpcError(data).isEmpty()
    }

    /** iOS reportPeer(reason: .spam) → messages.reportSpam。 */
    public func reportSpam(peerType: String, peerId: Int64): Bool {
        let req = MessagesReportSpam()
        req.peer = getRealMessageService().buildInputPeer(peerType, peerId)
        let data = getMTProtoClient().sendRequest(req.toBytes())
        return ChatComposeExtrasService.rpcError(data).isEmpty()
    }

    /** iOS NewContactScreen 完成：contacts.addContact(add_phone_privacy_exception)。 */
    public func addPeerContact(userId: Int64, firstName: String, lastName: String, phone: String,
        sharePhone: Bool): Bool {
        let req = ContactsAddContact()
        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = getRealMessageService().getAccessHashForUser(userId)
        req.id = inputUser
        req.firstName = firstName
        req.lastName = lastName
        req.phone = phone
        req.addPhonePrivacyException = sharePhone
        let data = getMTProtoClient().sendRequest(req.toBytes())
        let err = ChatComposeExtrasService.rpcError(data)
        if (err.size > 0) {
            Hilog.info(0, "CjTelegram", "[ChatComposeExtras] addContact failed: ${err}")
            return false
        }
        return true
    }

}

private var _chatComposeExtrasService: Option<ChatComposeExtrasService> = None

public func getChatComposeExtrasService(): ChatComposeExtrasService {
    match (_chatComposeExtrasService) {
        case Some(s) => return s
        case None =>
            let s = ChatComposeExtrasService()
            _chatComposeExtrasService = Some(s)
            return s
    }
}
