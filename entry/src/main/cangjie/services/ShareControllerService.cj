package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.{Want, WantValueType}
import kit.CoreFileKit.*
import std.collection.{ArrayList, HashMap}
import std.random.Random
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * 分享控制器服务（Share Controller）
 *
 * 封装转发/分享消息到多个对话的 API 调用。
 * 复用 RealMessageService、RealChatListService、RealContactService，不重复实现。
 *
 * TL 方法：messages.forwardMessages、messages.sendMessage（通过 RealMessageService）
 * iOS 参考：ShareController.swift, ShareControllerNode.swift
 */
private var _shareControllerServiceInstance: Option<ShareControllerService> = None

// 待转发参数（打开 ShareControllerPage 前设置）
private var _pendingFromPeerType: String = "user"
private var _pendingFromPeerId: Int64 = 0
private var _pendingMessageIds: ArrayList<Int32> = ArrayList<Int32>()

public func setPendingForward(fromPeerType: String, fromPeerId: Int64, messageIds: ArrayList<Int32>): Unit {
    _pendingFromPeerType = fromPeerType
    _pendingFromPeerId = fromPeerId
    _pendingMessageIds = messageIds
}

public func getPendingForward(): (String, Int64, ArrayList<Int32>) {
    return (_pendingFromPeerType, _pendingFromPeerId, _pendingMessageIds)
}

// S6-07：待分享的联系人名片（UserProfilePage more → Share Contact 打开 ShareControllerPage 前设置，
// 对位 iOS PeerInfoScreenPerformButtonAction.swift Profile_ShareContactButton →
// ShareController(subject: .media(.standalone(media: TelegramMediaContact)))）。一次性消费。
private var _pendingShareContactPhone: String = ""
private var _pendingShareContactFirstName: String = ""
private var _pendingShareContactLastName: String = ""

public func setPendingShareContact(phone: String, firstName: String, lastName: String): Unit {
    _pendingShareContactPhone = phone
    _pendingShareContactFirstName = firstName
    _pendingShareContactLastName = lastName
}

/** 取出并清空待分享联系人；phone 为空表示没有待分享联系人。 */
public func consumePendingShareContact(): (String, String, String) {
    let result = (_pendingShareContactPhone, _pendingShareContactFirstName, _pendingShareContactLastName)
    _pendingShareContactPhone = ""
    _pendingShareContactFirstName = ""
    _pendingShareContactLastName = ""
    return result
}

public func getShareControllerService(): ShareControllerService {
    match (_shareControllerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ShareControllerService()
            _shareControllerServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 分享目标（用户或对话）
 */
public class ShareTarget {
    public var peerType: String = "user"
    public var peerId: Int64 = 0
    public var name: String = ""
    public var avatarText: String = ""
    public var avatarColor: Int64 = 0x317AFF
    public var avatarLocalPath: String = ""
}

public class ShareControllerService {

    /**
     * 获取最近对话列表（用于分享选择）
     * 复用 RealChatListService.getDialogs，不创建新服务
     */
    public func getRecentChatsForShare(limit!: Int32 = 30): ArrayList<ShareTarget> {
        let chatSvc = getRealChatListService()
        let dialogs = chatSvc.getDialogs(limit: limit)
        let result = ArrayList<ShareTarget>()
        for (chat in dialogs) {
            let t = ShareTarget()
            t.peerType = chat.peerType
            t.peerId = chat.id
            t.name = chat.name
            t.avatarText = if (chat.avatarText.size > 0) { chat.avatarText } else { "?" }
            t.avatarColor = chat.avatarColor
            t.avatarLocalPath = chat.avatarLocalPath
            result.add(t)
        }
        return result
    }

    /**
     * 获取联系人列表（用于分享选择）
     * 复用 RealContactService.getContacts，不创建新服务
     */
    public func getContactsForShare(): ArrayList<ShareTarget> {
        let contactSvc = getRealContactService()
        let contacts = contactSvc.getContacts()
        let result = ArrayList<ShareTarget>()
        for (c in contacts) {
            if (c.isSelf) { continue }
            let t = ShareTarget()
            t.peerType = "user"
            t.peerId = c.userId
            t.name = c.getDisplayName()
            t.avatarText = if (c.firstName.size > 0) { c.firstName.toRuneArray()[0].toString() } else { "U" }
            t.avatarColor = 0x317AFF
            result.add(t)
        }
        return result
    }

    /**
     * 合并最近对话和联系人，去重（同一 peer 只保留一次）
     */
    public func getMergedTargetsForShare(limit!: Int32 = 30): ArrayList<ShareTarget> {
        let chats = this.getRecentChatsForShare(limit: limit)
        let contacts = this.getContactsForShare()
        let result = ArrayList<ShareTarget>()
        for (t in chats) {
            result.add(t)
        }
        for (t in contacts) {
            var found = false
            for (r in result) {
                if (r.peerType == "user" && r.peerId == t.peerId) {
                    found = true
                    break
                }
            }
            if (!found) {
                result.add(t)
            }
        }
        return result
    }

    /**
     * 转发消息到多个目标对话
     *
     * @param fromPeerType 源对话类型
     * @param fromPeerId 源对话 ID
     * @param messageIds 要转发的消息 ID 列表
     * @param targets 目标对话列表
     * @return 是否全部成功
     */
    public func forwardToPeers(
        fromPeerType: String,
        fromPeerId: Int64,
        messageIds: ArrayList<Int32>,
        targets: ArrayList<ShareTarget>
    ): Bool {
        if (targets.isEmpty() || messageIds.isEmpty()) {
            return false
        }
        let msgSvc = getRealMessageService()
        var allOk = true
        for (t in targets) {
            let ok = msgSvc.forwardMessages(
                fromPeerType,
                fromPeerId,
                t.peerType,
                t.peerId,
                messageIds
            )
            if (!ok) {
                Hilog.info(0, "CjTelegram", "[ShareControllerService] Forward to ${t.name} failed")
                allOk = false
            }
        }
        return allOk
    }

    /**
     * 通过鸿蒙系统分享面板分享邀请链接
     *
     * 对应 iOS InviteLinkViewController.shareLink → UIActivityViewController（系统 share sheet）。
     *
     * 实现路径：通过 getGlobalAbilityContext() 获取 UIAbilityContext，
     * 再用 startAbility(Want(action: "ohos.want.action.SEND", uri: link, dataType: "text/plain"))
     * 拉起系统分享面板（隐式 Want，系统分发给所有支持 SEND 操作的应用，多个时弹选择框）。
     *
     * parameters["ability.want.params.SHARE_TEXT"] 携带要分享的文本内容，供支持文本分享的应用读取。
     *
     * @param link 要分享的邀请链接 URL
     * @return true = 已成功拉起系统面板；false = 无 context 或系统调用异常
     */
    public func shareInviteLinkViaSystem(link: String): Bool {
        if (link.size == 0) {
            Hilog.info(0, "CjTelegram", "[ShareControllerService] shareInviteLinkViaSystem: empty link, skip")
            return false
        }
        match (getGlobalAbilityContext()) {
            case None =>
                Hilog.info(0, "CjTelegram", "[ShareControllerService] shareInviteLinkViaSystem: no AbilityContext")
                return false
            case Some(ctx) =>
                let params = HashMap<String, WantValueType>()
                params["ability.want.params.SHARE_TEXT"] = WantValueType.StringValue(link)
                let want = Want(
                    action: "ohos.want.action.SEND",
                    entities: ["entity.system.default"],
                    dataType: "text/plain",
                    parameters: params
                )
                try {
                    ctx.startAbility(want)
                    Hilog.info(0, "CjTelegram", "[ShareControllerService] shareInviteLinkViaSystem: startAbility SEND launched for link")
                    return true
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ShareControllerService] shareInviteLinkViaSystem: startAbility failed: ${e}")
                    return false
                }
        }
    }

    /**
     * 转发消息到多个目标对话，并在转发前向每个目标先发附加留言（P2-352）
     *
     * iOS 对应：ShareControllerNode.swift actionButtonPressed → 先发 comment 消息再转发
     *
     * @param fromPeerType 源对话类型
     * @param fromPeerId 源对话 ID
     * @param messageIds 要转发的消息 ID 列表
     * @param targets 目标对话列表
     * @param optionalMessage 附加留言（可空，若非空则先发留言再转发）
     * @return 是否全部成功
     */
    public func forwardToPeersWithComment(
        fromPeerType: String,
        fromPeerId: Int64,
        messageIds: ArrayList<Int32>,
        targets: ArrayList<ShareTarget>,
        optionalMessage: String
    ): Bool {
        if (targets.isEmpty() || messageIds.isEmpty()) {
            return false
        }
        let msgSvc = getRealMessageService()
        var allOk = true
        for (t in targets) {
            // P2-352: 先发附加留言到目标对话
            if (optionalMessage.size > 0) {
                let commentRes = msgSvc.sendMessage(t.peerType, t.peerId, optionalMessage)
                if (!commentRes.success) {
                    Hilog.info(0, "CjTelegram", "[ShareControllerService] Comment to ${t.name} failed")
                    allOk = false
                }
            }
            // 再转发消息
            let ok = msgSvc.forwardMessages(
                fromPeerType,
                fromPeerId,
                t.peerType,
                t.peerId,
                messageIds
            )
            if (!ok) {
                Hilog.info(0, "CjTelegram", "[ShareControllerService] Forward to ${t.name} failed")
                allOk = false
            }
        }
        return allOk
    }

    /**
     * 发送文本消息到多个目标对话
     *
     * @param message 消息内容
     * @param targets 目标对话列表
     * @return 是否全部成功
     */
    public func sendToPeers(
        message: String,
        targets: ArrayList<ShareTarget>
    ): Bool {
        if (targets.isEmpty() || message.isEmpty()) {
            return false
        }
        let msgSvc = getRealMessageService()
        var allOk = true
        for (t in targets) {
            let res = msgSvc.sendMessage(t.peerType, t.peerId, message)
            if (!res.success) {
                Hilog.info(0, "CjTelegram", "[ShareControllerService] Send to ${t.name} failed")
                allOk = false
            }
        }
        return allOk
    }

    // ─────────────────────────────────────────────────────────────────────────
    // P2-351: 远端搜索分享目标（contacts.search 全局 + 本地名称子串合并）
    // iOS ShareController.swift → searchContacts(query:) — 先本地再远端合并去重
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 搜索分享目标：本地名称子串 + 远端 contacts.search 全局结果合并。
     *
     * 分三类：
     *   - "chats"    : 最近对话中匹配本地名称的
     *   - "contacts" : 本地联系人中匹配的（contacts.getContacts 缓存）
     *   - "global"   : 远端 contacts.search 返回的非本地联系人
     *
     * @param query 搜索词（空串时直接调用 getMergedTargetsForShare）
     * @param limit 远端搜索限制
     * @return ShareSearchResult（三类分组）
     */
    public func searchShareTargets(query: String, limit!: Int32 = 30): ShareSearchResult {
        let result = ShareSearchResult()
        if (query.size == 0) {
            let merged = this.getMergedTargetsForShare(limit: limit)
            result.chats = merged
            return result
        }
        let q = query.toAsciiLower()

        // 本地聊天列表匹配
        let localChats = this.getRecentChatsForShare(limit: 100)
        let matchedChats = ArrayList<ShareTarget>()
        for (t in localChats) {
            if (t.name.toAsciiLower().contains(q)) {
                matchedChats.add(t)
            }
        }
        result.chats = matchedChats

        // 本地联系人匹配
        let localContacts = this.getContactsForShare()
        let matchedContacts = ArrayList<ShareTarget>()
        for (t in localContacts) {
            if (t.name.toAsciiLower().contains(q)) {
                matchedContacts.add(t)
            }
        }
        result.contacts = matchedContacts

        // 远端 contacts.search（全局）— 去掉已在本地 chats/contacts 中的
        let contactSvc = getRealContactService()
        let remoteUsers = contactSvc.searchRemotePeers(query, limit: limit)
        let globalList = ArrayList<ShareTarget>()
        for (u in remoteUsers) {
            // 去重：若已在 matchedChats 或 matchedContacts 中则跳过
            var dup = false
            for (c in matchedChats) {
                if (c.peerType == "user" && c.peerId == u.userId) {
                    dup = true
                    break
                }
            }
            if (!dup) {
                for (c in matchedContacts) {
                    if (c.peerId == u.userId) {
                        dup = true
                        break
                    }
                }
            }
            if (!dup) {
                let t = ShareTarget()
                t.peerType = "user"
                t.peerId = u.userId
                t.name = u.getDisplayName()
                t.avatarText = if (u.firstName.size > 0) { u.firstName.toRuneArray()[0].toString() } else { "U" }
                t.avatarColor = 0x34C759
                globalList.add(t)
            }
        }
        result.global = globalList

        Hilog.info(0, "CjTelegram", "[ShareControllerService] searchShareTargets: chats=${result.chats.size} contacts=${result.contacts.size} global=${result.global.size}")
        return result
    }

    // ─────────────────────────────────────────────────────────────────────────
    // P2-353: 群发增强 — groupingKey 相册分组 + silently + allowPaidStars + 逐 peer 进度
    // iOS ShareController.swift → actionButtonPressed → forwardMessages(silently:paidStars:)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 群发转发消息到多个目标，支持 silently + allowPaidStars + 逐 peer 进度回传。
     *
     * @param fromPeerType 来源对话类型
     * @param fromPeerId 来源对话 ID
     * @param messageIds 消息 ID 列表（Int32）
     * @param targets 目标对话列表
     * @param optionalMessage 附加留言（可空）
     * @param silently 静默发送（不通知对方）
     * @param allowPaidStars Paid Stars 额度（0=不付费）
     * @param onProgress 每成功发到一个 peer 的回调：(peerName, successCount, totalCount)
     * @return 全部成功时 true
     */
    public func forwardToMultiPeers(
        fromPeerType: String,
        fromPeerId: Int64,
        messageIds: ArrayList<Int32>,
        targets: ArrayList<ShareTarget>,
        optionalMessage: String,
        onProgress: (String, Int32, Int32) -> Unit,
        silently!: Bool = false,
        allowPaidStars!: Int64 = 0
    ): Bool {
        if (targets.isEmpty() || messageIds.isEmpty()) {
            return false
        }
        let msgSvc = getRealMessageService()
        var successCount: Int32 = 0
        let total = Int32(targets.size)
        var allOk = true
        for (t in targets) {
            if (optionalMessage.size > 0) {
                let commentRes = msgSvc.sendMessage(t.peerType, t.peerId, optionalMessage)
                if (!commentRes.success) {
                    Hilog.info(0, "CjTelegram", "[ShareControllerService] Comment to ${t.name} failed")
                }
            }
            // 使用增强版 forwardMessages（silently/allowPaidStars）
            let req = MessagesForwardMessages()
            req.fromPeer = buildShareInputPeer(fromPeerType, fromPeerId)
            req.toPeer = buildShareInputPeer(t.peerType, t.peerId)
            req.idList = messageIds
            let rids = ArrayList<Int64>()
            for (_id in messageIds) {
                rids.add(generateShareRandomId())
            }
            req.randomIds = rids
            if (silently) {
                req.silent = true
            }
            if (allowPaidStars > 0) {
                req.allowPaidStars = Some(allowPaidStars)
            }
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            let ok = checkShareSendResponse(responseData)
            if (ok) {
                successCount += 1
                onProgress(t.name, successCount, total)
            } else {
                Hilog.info(0, "CjTelegram", "[ShareControllerService] forwardToMultiPeers: forward to ${t.name} failed")
                allOk = false
            }
        }
        return allOk
    }

    /**
     * 群发文本消息到多个目标（带 silently + allowPaidStars + 逐 peer 进度回传）
     */
    public func sendTextToMultiPeers(
        message: String,
        targets: ArrayList<ShareTarget>,
        onProgress: (String, Int32, Int32) -> Unit,
        silently!: Bool = false,
        allowPaidStars!: Int64 = 0
    ): Bool {
        if (targets.isEmpty() || message.isEmpty()) {
            return false
        }
        let msgSvc = getRealMessageService()
        var successCount: Int32 = 0
        let total = Int32(targets.size)
        var allOk = true
        for (t in targets) {
            let res = msgSvc.sendMessage(t.peerType, t.peerId, message)
            if (res.success) {
                successCount += 1
                onProgress(t.name, successCount, total)
            } else {
                Hilog.info(0, "CjTelegram", "[ShareControllerService] sendTextToMultiPeers: send to ${t.name} failed")
                allOk = false
            }
        }
        return allOk
    }

    /**
     * S6-07：把联系人名片（messageMediaContact）发到多个目标。
     * 复用 RealMessageService.sendContact（InputMediaContact → messages.sendMedia），
     * 与附件面板「Contact」项同一条发送链路。
     */
    public func sendContactToMultiPeers(
        phone: String,
        firstName: String,
        lastName: String,
        targets: ArrayList<ShareTarget>,
        onProgress: (String, Int32, Int32) -> Unit
    ): Bool {
        if (targets.isEmpty() || phone.isEmpty()) {
            return false
        }
        let msgSvc = getRealMessageService()
        var successCount: Int32 = 0
        let total = Int32(targets.size)
        var allOk = true
        for (t in targets) {
            let res = msgSvc.sendContact(t.peerType, t.peerId, phone, firstName, lastName)
            if (res.success) {
                successCount += 1
                onProgress(t.name, successCount, total)
            } else {
                Hilog.info(0, "CjTelegram", "[ShareControllerService] sendContactToMultiPeers: send to ${t.name} failed")
                allOk = false
            }
        }
        return allOk
    }

    /**
     * P2-354/355: 发送已标准化的外部内容（文本/URL/文件/图片）到多个对话
     *
     * 对应 iOS ShareController.swift→prepareItems()→sendSharedItems() 管线。
     * 按 kind 分发：
     *   - text/url/vcard/location: sendMessage（文本正文）
     *   - image/video/audio/file:  readFile + sendDocument（文件上传）
     *
     * @param items 已标准化的内容列表（由 ExternalContentNormalizationService.normalizeItems 产出）
     * @param targets 目标对话列表
     * @param onProgress 进度回调（peerName, successCount, totalCount）
     * @param silently 静默发送（不触发通知）
     * @return true 表示全部发送成功
     */
    public func sendExternalContentToMultiPeers(
        items: ArrayList<NormalizedContentItem>,
        targets: ArrayList<ShareTarget>,
        onProgress: (String, Int32, Int32) -> Unit,
        silently!: Bool = false
    ): Bool {
        if (targets.isEmpty() || items.isEmpty()) {
            return false
        }
        let msgSvc = getRealMessageService()
        var successCount: Int32 = 0
        let total = Int32(targets.size)
        var allOk = true

        for (t in targets) {
            var peerOk = true
            for (item in items) {
                let res = this.sendOneItemToPeer(msgSvc, t, item)
                if (!res) {
                    peerOk = false
                    Hilog.info(0, "CjTelegram", "[ShareControllerService] sendExternalContent: item kind=${item.kind} to ${t.name} failed")
                }
            }
            if (peerOk) {
                successCount += 1
                onProgress(t.name, successCount, total)
            } else {
                allOk = false
            }
        }
        return allOk
    }

    /**
     * 将单个标准化内容项发送到单个对话
     *
     * 文本类 → sendMessage；文件类 → 读取字节 + sendDocument
     */
    private func sendOneItemToPeer(msgSvc: RealMessageService, target: ShareTarget, item: NormalizedContentItem): Bool {
        if (item.kind == "text" || item.kind == "url" || item.kind == "location") {
            let text = if (item.textContent.size > 0) { item.textContent } else { item.localFilePath }
            let res = msgSvc.sendMessage(target.peerType, target.peerId, text)
            return res.success
        }
        if (item.kind == "vcard") {
            let text = "Contact: " + item.textContent
            let res = msgSvc.sendMessage(target.peerType, target.peerId, text)
            return res.success
        }
        // 文件类（image/video/audio/file）: 读取字节后 sendDocument
        if (item.localFilePath.size == 0) {
            Hilog.info(0, "CjTelegram", "[ShareControllerService] sendOneItemToPeer: no filePath for kind=${item.kind}")
            return false
        }
        let fileData = this.readFileBytes(item.localFilePath)
        if (fileData.size == 0) {
            Hilog.info(0, "CjTelegram", "[ShareControllerService] sendOneItemToPeer: file empty ${item.localFilePath}")
            return false
        }
        let mimeType = guessMimeType(item.kind, item.fileName)
        let res = msgSvc.sendDocument(target.peerType, target.peerId, fileData, item.fileName, mimeType: mimeType)
        return res.success
    }

    private func readFileBytes(path: String): Array<Byte> {
        var fileSize: Int64 = 0
        try {
            let stat = FileIo.stat(path)
            fileSize = stat.size
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[ShareControllerService] readFileBytes: stat failed ${path}")
            return Array<Byte>(0, repeat: 0)
        }
        if (fileSize <= 0) {
            return Array<Byte>(0, repeat: 0)
        }
        try {
            let buf = Array<Byte>(fileSize, repeat: 0)
            let f = FileIo.open(path, mode: 0o0)
            let _ = FileIo.read(f.fd, buf)
            FileIo.close(f)
            return buf
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[ShareControllerService] readFileBytes: read failed ${path}")
            return Array<Byte>(0, repeat: 0)
        }
    }

    private func guessMimeType(kind: String, fileName: String): String {
        if (kind == "image") {
            let fnLower = fileName.toAsciiLower()
            if (fnLower.contains(".png")) { return "image/png" }
            if (fnLower.contains(".gif")) { return "image/gif" }
            if (fnLower.contains(".webp")) { return "image/webp" }
            if (fnLower.contains(".heic")) { return "image/heic" }
            return "image/jpeg"
        }
        if (kind == "video") { return "video/mp4" }
        if (kind == "audio") {
            let fnLower = fileName.toAsciiLower()
            if (fnLower.contains(".mp3")) { return "audio/mpeg" }
            if (fnLower.contains(".ogg")) { return "audio/ogg" }
            if (fnLower.contains(".m4a")) { return "audio/m4a" }
            return "audio/aac"
        }
        return "application/octet-stream"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// P2-351: 搜索结果分组模型
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 分享目标搜索结果，分三类：最近对话/联系人/全局
 * iOS ShareController.swift searchResult → .chats / .contacts / .globalPeers
 */
public class ShareSearchResult {
    public var chats: ArrayList<ShareTarget> = ArrayList<ShareTarget>()
    public var contacts: ArrayList<ShareTarget> = ArrayList<ShareTarget>()
    public var global: ArrayList<ShareTarget> = ArrayList<ShareTarget>()

    public init() {}

    public func isEmpty(): Bool {
        return this.chats.isEmpty() && this.contacts.isEmpty() && this.global.isEmpty()
    }

    public func allTargets(): ArrayList<ShareTarget> {
        let out = ArrayList<ShareTarget>()
        for (t in this.chats) { out.add(t) }
        for (t in this.contacts) { out.add(t) }
        for (t in this.global) { out.add(t) }
        return out
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 内部工具（share scope，不污染全局命名空间）
// ─────────────────────────────────────────────────────────────────────────────

private let _shareRand = Random()

private func generateShareRandomId(): Int64 {
    return _shareRand.nextInt64()
}

private func buildShareInputPeer(peerType: String, peerId: Int64): TLObject {
    // 复用 RealMessageService 的 buildInputPeer 逻辑
    // 通过 getRealMessageService().buildInputPeer 不可直接访问（private），
    // 此处自行实现轻量版（无 accessHash，足够 share 场景使用）
    if (peerType == "channel" || peerType == "supergroup") {
        let p = InputPeerChannel()
        p.channelId = peerId
        p.accessHash = getRealMessageService().getAccessHashForChannel(peerId)
        return p
    } else if (peerType == "chat" || peerType == "group") {
        let p = InputPeerChat()
        p.chatId = peerId
        return p
    } else {
        let p = InputPeerUser()
        p.userId = peerId
        p.accessHash = getRealMessageService().getAccessHashForUser(peerId)
        return p
    }
}

private func checkShareSendResponse(data: Array<Byte>): Bool {
    if (data.size == 0) {
        return false
    }
    if (data.size >= 4) {
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return false
        }
    }
    return true
}
