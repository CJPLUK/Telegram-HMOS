package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.UIAbilityContext
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.core.storage.trOr
import ohos_app_cangjie_entry.core.storage.postbox.*
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.utils.{copyText, readText, formatRelativeTimestamp, formatScheduledCallFor}
import std.collection.ArrayList
import std.collection.HashSet
import std.collection.HashMap
import std.sync.Monitor
import std.time.DateTime
/**
 * 真实聊天列表服务
 * 
 * 对应 TelegramHarmony 的 RealChatListService.ets
 * 使用 MTProto 客户端获取和管理聊天列表
 */
private var _realChatListServiceInstance: Option<RealChatListService> = None

public func getRealChatListService(): RealChatListService {
    match (_realChatListServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = RealChatListService()
            _realChatListServiceInstance = Some(inst)
            return inst
    }
}

/** 区分“服务端成功返回空列表”和“请求失败后降级为空列表”。 */
public class DialogsFetchResult {
    public var chats: ArrayList<Chat> = ArrayList<Chat>()
    public var success: Bool = false
    // 下一页游标。对齐 iOS FetchChatList.parseDialogs：messages.dialogsSlice 时取本页
    // 非置顶会话 top message 的最小 MessageIndex（date, id, peer）作为下一次 getDialogs
    // 的 offset_date / offset_id / offset_peer（lowerNonPinnedIndex → ChatListHole）；
    // messages.dialogs（apiIsAtLowestBoundary）或本页无非置顶会话时无更多。
    public var hasMore: Bool = false
    public var nextOffsetDate: Int32 = 0
    public var nextOffsetId: Int32 = 0
    public var nextOffsetPeerType: String = ""
    public var nextOffsetPeerId: Int64 = 0
}

public class RealChatListService {
    // 缓存
    private var usersCache = HashMap<Int64, UserResponse>()
    private var chatsCache = HashMap<Int64, ChatResponse>()
    private var legacyChatsCache = HashMap<Int64, ChatResponse>()
    private var channelsCache = HashMap<Int64, ChatResponse>()

    // iOS Postbox 的 updatePeerChatListInclusion(.notIncluded) 等价态。
    // 退群成功后服务端的 getDialogs 可能短暂返回旧 dialog；该集合阻止它重新进入 UI。
    private var removedDialogKeys = HashSet<String>()
    private let removedDialogMonitor: Monitor = Monitor()

    private func dialogKey(peerType: String, peerId: Int64): String {
        return "${peerType}:${peerId}"
    }

    public func markDialogRemoved(peerType: String, peerId: Int64): Unit {
        let key = this.dialogKey(peerType, peerId)
        synchronized(this.removedDialogMonitor) {
            this.removedDialogKeys.add(key)
        }
        Hilog.info(0, "CjTelegram", "[RealChatListService] marked dialog removed: ${key}")
    }

    public func clearDialogRemoved(peerType: String, peerId: Int64): Unit {
        let key = this.dialogKey(peerType, peerId)
        synchronized(this.removedDialogMonitor) {
            if (this.removedDialogKeys.contains(key)) {
                let _ = this.removedDialogKeys.remove(key)
            }
        }
    }

    /** 投影层（ChatListProjection.applyCommittedMessage）据此拒绝为已移除会话重建行。 */
    public func isDialogLocallyRemoved(peerType: String, peerId: Int64): Bool {
        return this.isDialogRemoved(peerType, peerId)
    }

    private func isDialogRemoved(peerType: String, peerId: Int64): Bool {
        let key = this.dialogKey(peerType, peerId)
        return synchronized(this.removedDialogMonitor) {
            this.removedDialogKeys.contains(key)
        }
    }

    /**
     * 获取对话列表
     * @param folderId 0=主列表，1=归档
     *
     * 对齐 iOS：本地未发出（失败）消息以本地会话形式并入主列表。iOS 的列表数据源
     * 是本地 Postbox（含 pending/failed 消息），列表天然包含失败会话；仓颉列表来自
     * getDialogs 网络结果，服务端对「首条即失败、从未建会话」的 peer 无 dialog，
     * 故在数据源出口统一注入——放这里而非 VM 层，避免遗漏 restored/optimistic/
     * confirmed 等多条列表赋值路径（实测「显示一次后又消失」即某条未包装路径覆盖）。
     */
    public func getDialogs(limit!: Int32 = 20, offsetDate!: Int32 = 0, folderId!: Int32 = 0): ArrayList<Chat> {
        return this.getDialogsResult(limit: limit, offsetDate: offsetDate, folderId: folderId).chats
    }

    public func getDialogsResult(limit!: Int32 = 20, offsetDate!: Int32 = 0, folderId!: Int32 = 0,
        offsetId!: Int32 = 0, offsetPeerType!: String = "", offsetPeerId!: Int64 = 0): DialogsFetchResult {
        let result = this.getDialogsRaw(limit: limit, offsetDate: offsetDate, folderId: folderId,
            offsetId: offsetId, offsetPeerType: offsetPeerType, offsetPeerId: offsetPeerId)
        // 仅主列表(folderId=0)首页注入失败会话；归档列表与后续翻页不注入。
        if (folderId == 0 && offsetDate == 0 && offsetId == 0) {
            result.chats = injectFailedChats(result.chats)
        }
        return result
    }

    private func getDialogsRaw(limit!: Int32 = 20, offsetDate!: Int32 = 0, folderId!: Int32 = 0,
        offsetId!: Int32 = 0, offsetPeerType!: String = "", offsetPeerId!: Int64 = 0): DialogsFetchResult {
        let fetchResult = DialogsFetchResult()
        let client = getMTProtoClient()
        let isFirstPage = offsetDate == 0 && offsetId == 0

        let getDialogs = MessagesGetDialogs()
        getDialogs.limit = limit
        getDialogs.offsetDate = offsetDate
        getDialogs.offsetId = offsetId
        if (!isFirstPage && offsetPeerType.size > 0) {
            getDialogs.offsetPeer = getRealMessageService().buildInputPeer(offsetPeerType, offsetPeerId)
        }
        getDialogs.folderId = folderId

        Hilog.info(0, "CjTelegram", "[RealChatListService] Sending messages.getDialogs, limit=${limit}, folderId=${folderId}, offsetDate=${offsetDate}, offsetId=${offsetId}, offsetPeer=${offsetPeerType}/${offsetPeerId}...")
        let responseData = client.sendRequest(getDialogs.toBytes())
        Hilog.info(0, "CjTelegram", "[RealChatListService] Response size: ${responseData.size}")
        if (folderId != 0) {
            var ctorHex = "none"
            if (responseData.size >= 4) {
                let probe = TLDeserializer(responseData)
                ctorHex = "${probe.readUInt32()}"
            }
            Hilog.info(0, "CjTelegram",
                "[ArchiveTrace] svc response folder=${folderId} bytes=${responseData.size} ctor=${ctorHex}")
        }

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] Empty response, returning empty list")
            return fetchResult
        }

        // 检查是否为 RPC 错误
        let checkD = TLDeserializer(responseData)
        let checkConstructor = checkD.readUInt32()
        if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
            let errorCode = checkD.readInt32()
            let errorMessage = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealChatListService] RPC Error: ${errorCode} - ${errorMessage}")
            return fetchResult
        }

        // 正常响应，从头解析
        Hilog.info(0, "CjTelegram", "[RealChatListService] Deserializing dialogs response...")
        let response = MessagesDialogsResponse.deserialize(responseData)
        fetchResult.success = true
        let isSlice = checkConstructor == 0x71e094f3 // messages.dialogsSlice
        Hilog.info(0, "CjTelegram", "[RealChatListService] Parsed: ${response.dialogs.size} dialogs, ${response.messages.size} messages, ${response.users.size} users, ${response.chats.size} chats, slice=${isSlice}, count=${response.count}")
        if (isSlice) {
            this.fillNextPageCursor(fetchResult, response)
        }

        // 缓存用户和聊天
        let photoService = getUserPhotoService()
        for (user in response.users) {
            usersCache[user.id] = user
            // Phase L1: 缓存用户到 UserPhotoService
            photoService.cacheUser(user)
            if (user.accessHash != 0) {
                getRealMessageService().cacheUserAccessHash(user.id, user.accessHash)
                Hilog.info(0, "CjTelegram", "[RealChatListService] Cached user: id=${user.id}, name='${user.firstName} ${user.lastName}', accessHash=${user.accessHash}, hasPhoto=${user.hasPhoto}")
            } else {
                Hilog.info(0, "CjTelegram", "[RealChatListService] User without accessHash: id=${user.id}, name='${user.firstName}'")
            }
        }
        for (chat in response.chats) {
            chatsCache[chat.id] = chat
            if (chat.isChannel) { channelsCache[chat.id] = chat }
            else { legacyChatsCache[chat.id] = chat }
            photoService.cacheChat(chat)
            if (chat.isChannel && chat.accessHash != 0) {
                getRealMessageService().cacheChannelAccessHash(chat.id, chat.accessHash)
                Hilog.info(0, "CjTelegram", "[RealChatListService] Cached channel: id=${chat.id}, title='${chat.title}', accessHash=${chat.accessHash}")
            }
        }

        if (folderId != 0) {
            Hilog.info(0, "CjTelegram",
                "[ArchiveTrace] svc parsed folder=${folderId} dialogs=${response.dialogs.size} messages=${response.messages.size} chats=${response.chats.size} users=${response.users.size} count=${response.count}")
        }
        // 构建 Chat 列表
        let result = ArrayList<Chat>()
        for (dialog in response.dialogs) {
            try {
                let chat = dialogToChat(dialog, response.messages)
                match (chat) {
                    case Some(c) =>
                        result.add(c)
                        if (folderId != 0) {
                            Hilog.info(0, "CjTelegram",
                                "[ArchiveTrace] svc dialog kept ${dialog.peer.type_}/${dialog.peer.id} folderId=${dialog.folderId} name='${c.name}'")
                        }
                    case None =>
                        if (folderId != 0) {
                            Hilog.info(0, "CjTelegram",
                                "[ArchiveTrace] svc dialog dropped ${dialog.peer.type_}/${dialog.peer.id} folderId=${dialog.folderId}")
                        }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[RealChatListService] Error converting dialog: ${e}")
                // 跳过这个 dialog，继续处理其他的
            }
        }

        // Phase E: 排序——置顶优先，然后按最后消息时间降序
        let sorted = sortChatList(result)

        // PeerTable 物理键使用 PeerKey namespace，供后台新会话投影/通知离线取名。
        for (chat in sorted) {
            getPeerStore().cacheChat(chat)
        }

        // 单元 P2-288c: 仅主列表（folderId==0）回填本地 ChatListTable，
        // 让会话列表离线可读。归档（folder 1）/ 过滤夹不进单一会话主表
        // （ChatListTable 无归档分区，见 ChatListEntry.cj）。
        // storeChats 内部对 DB 不可用安全降级 no-op，绝不影响网络返回。
        // storeChats 整表替换，只能用首页快照回填；翻页结果不写，避免冲掉首页缓存。
        if (folderId == 0 && isFirstPage) {
            getChatListStore().storeChats(sorted)
        }

        Hilog.info(0, "CjTelegram", "[RealChatListService] Returning ${sorted.size} chats, hasMore=${fetchResult.hasMore}")
        fetchResult.chats = sorted
        return fetchResult
    }

    /**
     * 对齐 iOS FetchChatList.parseDialogs 的 lowerNonPinnedIndex：遍历本页非置顶 dialog，
     * 用其 top message（按 peer + id 匹配 messages 向量）的 (date, id) 取最小者，
     * 连同该 dialog 的 peer 作为下一页 offset 三元组。置顶会话不参与游标计算。
     */
    private func fillNextPageCursor(fetchResult: DialogsFetchResult, response: MessagesDialogsResponse): Unit {
        var found = false
        var minDate: Int32 = 0
        var minId: Int32 = 0
        var minPeerType = ""
        var minPeerId: Int64 = 0
        for (dialog in response.dialogs) {
            if (dialog.isPinned) { continue }
            // 不同 peer 的 message id 可能相同，优先 peer + id 精确匹配，匹配不到再退回按 id。
            var top: Option<TLMessage> = None
            var idOnly: Option<TLMessage> = None
            for (msg in response.messages) {
                if (msg.id != dialog.topMessage) { continue }
                if (msg.peerId.id == dialog.peer.id &&
                    normalizeDialogPeerType(msg.peerId.type_) == normalizeDialogPeerType(dialog.peer.type_)) {
                    top = Some(msg)
                    break
                }
                if (idOnly.isNone()) { idOnly = Some(msg) }
            }
            if (top.isNone()) { top = idOnly }
            match (top) {
                case Some(msg) =>
                    if (!found || msg.date < minDate || (msg.date == minDate && msg.id < minId)) {
                        found = true
                        minDate = msg.date
                        minId = msg.id
                        minPeerType = dialog.peer.type_
                        minPeerId = dialog.peer.id
                    }
                case None => ()
            }
        }
        if (found) {
            fetchResult.hasMore = true
            fetchResult.nextOffsetDate = minDate
            fetchResult.nextOffsetId = minId
            fetchResult.nextOffsetPeerType = minPeerType
            fetchResult.nextOffsetPeerId = minPeerId
        }
    }

    /**
     * 单元 P2-288c: 本地优先读会话列表（对照 iOS Postbox local-first：先读本地，未命中再网络回源回填）。
     *
     * 策略：
     *   1. 先查本地 ChatListTable（listChats(limit)）。本地命中且足量（size >= limit）即直接返回本地，
     *      不发网络 —— 这就是"会话列表离线可读"。
     *   2. 本地为空 / 不足 → 走原 getDialogs 网络回源；getDialogs 内部已回填本地表，
     *      返回网络权威结果（含 name / avatar / lastMessage 等完整字段）。
     *
     * 只服务主列表（folderId 固定 0）：归档 / 过滤夹不进本地会话主表，仍走纯网络 getDialogs。
     *
     * DB 不可用（拿不到 context / open 失败）时：ChatListStore 安全降级——本地读返回空、
     * 回填 no-op，本方法等价于纯网络路径，绝不崩。
     *
     * 不改对外契约：本方法是新增入口；原 getDialogs（网络，现额外回填本地）签名与既有行为保持。
     *
     * @param limit 最多返回会话数
     * @return 会话列表（本地命中时物理有序；网络回源时按 sortChatList 排序）
     */
    public func getDialogsLocalFirst(limit!: Int32 = 20): ArrayList<Chat> {
        Hilog.info(0, "CjTelegram", "[RealChatListService] getDialogsLocalFirst: limit=${limit}")
        // Step 1: 本地优先（本地表命中也要注入失败会话——纯本地路径否则漏）
        let local = getChatListStore().loadLocalChats(Int64(limit))
        if (Int64(local.size) >= Int64(limit)) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] getDialogsLocalFirst: local hit ${local.size} (>=${limit}), skip network")
            return injectFailedChats(local)
        }
        // Step 2: 本地为空 / 不足 → 网络回源（getDialogs 已含注入）
        let dialogs = this.getDialogs(limit: limit, offsetDate: 0, folderId: 0)
        if (dialogs.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] getDialogsLocalFirst: network empty, returning ${local.size} local")
            return injectFailedChats(local)
        }
        Hilog.info(0, "CjTelegram", "[RealChatListService] getDialogsLocalFirst: network ${dialogs.size}, backfilled local")
        return dialogs
    }

    /**
     * 把 FailedMessageStore 中「不在 dialogs 里」的 peer 合成本地 Chat 条目并置顶。
     * dialogs 已含该 peer 时不重复注入（正常会话里的失败消息由气泡红叹号表达）。
     */
    private func injectFailedChats(dialogs: ArrayList<Chat>): ArrayList<Chat> {
        let failedPeers = failedStorePeers()
        if (failedPeers.size == 0) { return dialogs }
        let present = HashSet<Int64>()
        for (c in dialogs) { present.add(c.id) }
        let out = ArrayList<Chat>()
        var injected = 0
        for (pid in failedPeers) {
            if (!present.contains(pid)) {
                let c = Chat()
                c.id = pid
                c.name = failedStoreName(pid)
                if (c.name.size == 0) { c.name = "Unknown" }
                c.lastMessage = failedStoreLastText(pid)
                c.peerType = "user"
                c.avatarText = if (c.name.size > 0) { c.name.toRuneArray()[0].toString() } else { "?" }
                out.add(c)
                injected = injected + 1
            }
        }
        for (c in dialogs) { out.add(c) }
        if (injected > 0) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] injected ${injected} local failed chat(s)")
        }
        return out
    }

    /**
     * 将 TLDialog 转换为 Chat 模型（Phase E 增强版）
     * 填充频道/群组字段、媒体消息类型等
     */
    private func dialogToChat(dialog: TLDialog, messages: ArrayList<TLMessage>): Option<Chat> {
        let chat = Chat()

        let peerId = dialog.peer.id
        let peerType = dialog.peer.type_
        if (this.isDialogRemoved(peerType, peerId)) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] skip locally removed dialog: ${peerType}/${peerId}")
            return None
        }
        if ((peerType == "chat" || peerType == "channel") && this.chatsCache.contains(peerId)) {
            let peer = this.chatsCache[peerId]
            if (peer.isLeft) {
                Hilog.info(0, "CjTelegram", "[RealChatListService] skip left/forbidden dialog: ${peerType}/${peerId}")
                return None
            }
            // iOS UpdatePeers CloudGroup：deactivated（已升级为超级群，migrated_to）的基础群
            // 置 notIncluded，列表只保留升级后的超级群，不会出现两行同名群。
            if (peerType == "chat" && peer.isMigrated) {
                Hilog.info(0, "CjTelegram", "[RealChatListService] skip migrated basic group dialog: ${peerId}")
                return None
            }
        }
        chat.peerType = peerType

        // 根据 peer 类型获取聊天信息
        if (peerType == "user") {
            if (usersCache.contains(peerId)) {
                let user = usersCache[peerId]
                chat.id = peerId
                chat.name = userDisplayTitle(user.firstName, user.lastName, user.phone)
                chat.isDeletedAccount = isDeletedAccountName(user.firstName, user.lastName, user.phone)
                // iOS ChatListItem：peer.id == accountPeerId → DialogList.SavedMessages + 书签头像。
                if (peerId != 0 && peerId == getCurrentUserId()) {
                    chat.isSavedMessages = true
                    chat.name = trOr("DialogList.SavedMessages", "Saved Messages")
                }
                chat.avatarText = if (user.firstName.size > 0) { user.firstName.toRuneArray()[0].toString() } else { "U" }
                chat.isGroup = false
                chat.isChannel = false
                chat.username = user.username
                // iOS parity: 认证蓝勾 + bot 标记（TL flags.17 / flags.14 / flags2.13）
                chat.isVerified = user.isVerified
                chat.isBot = user.isBot
                chat.botHasMainApp = user.botHasMainApp
                // Phase L3: 尝试加载真实头像
                let avatarPath = getUserPhotoService().getUserPhotoPath(peerId)
                Hilog.info(0, "CjTelegram", "[AVT] dialog user=${peerId} '${chat.name}': pathLen=${avatarPath.size}")
                if (avatarPath.size > 0) {
                    chat.avatarLocalPath = avatarPath
                }
            } else {
                chat.id = peerId
                chat.isGroup = false
                let photoUser = getUserPhotoService().getCachedUser(peerId)
                match (photoUser) {
                    case Some(pu) =>
                        chat.name = userDisplayTitle(pu.firstName, pu.lastName, pu.phone)
                        chat.isDeletedAccount = isDeletedAccountName(pu.firstName, pu.lastName, pu.phone)
                        if (peerId != 0 && peerId == getCurrentUserId()) {
                            chat.isSavedMessages = true
                            chat.name = trOr("DialogList.SavedMessages", "Saved Messages")
                        }
                        chat.avatarText = if (pu.firstName.size > 0) { pu.firstName.toRuneArray()[0].toString() } else { "U" }
                        chat.username = pu.username
                        Hilog.info(0, "CjTelegram", "[RealChatListService] Resolved user ${peerId} via PhotoService: '${chat.name}'")
                    case None =>
                        chat.name = "User ${peerId}"
                        chat.avatarText = "U"
                        Hilog.info(0, "CjTelegram", "[RealChatListService] User ${peerId} not in usersCache or PhotoService")
                }
            }
        } else if (peerType == "chat") {
            if (legacyChatsCache.contains(peerId)) {
                let chatInfo = legacyChatsCache[peerId]
                chat.id = peerId
                chat.name = chatInfo.title
                chat.avatarText = if (chatInfo.title.size > 0) { chatInfo.title.toRuneArray()[0].toString() } else { "G" }
                chat.isGroup = true
                chat.isChannel = false
                chat.participantsCount = Int64(chatInfo.participantsCount)
                chat.avatarLocalPath = getUserPhotoService().getChatPhotoPath(peerId)
            } else {
                chat.id = peerId
                chat.name = "Chat ${peerId}"
                chat.avatarText = "G"
                chat.isGroup = true
            }
        } else if (peerType == "channel") {
            if (channelsCache.contains(peerId)) {
                let chatInfo = channelsCache[peerId]
                chat.id = peerId
                chat.name = chatInfo.title
                chat.avatarText = if (chatInfo.title.size > 0) { chatInfo.title.toRuneArray()[0].toString() } else { "C" }
                chat.isGroup = chatInfo.isMegagroup
                chat.isChannel = true
                chat.isMegagroup = chatInfo.isMegagroup
                chat.username = chatInfo.username
                chat.isVerified = chatInfo.isVerified
                chat.participantsCount = Int64(chatInfo.participantsCount)
                chat.avatarLocalPath = getUserPhotoService().getChatPhotoPath(peerId)
            } else {
                chat.id = peerId
                chat.name = "Channel ${peerId}"
                chat.avatarText = "C"
                chat.isChannel = true
            }
        }

        // 查找最近消息（Phase E: 填充媒体类型信息 + 排序时间戳）
        // 频道/超级群的消息 id 按会话独立编号：多个新建频道的首条服务消息 id 都是 1。
        // iOS 按 MessageId(peerId, id) 取 topMessage；只比 id 会把同批响应里别的会话的
        // 那条消息（如刚建的频道 "Channel created"）当成本会话预览。
        for (msg in messages) {
            let samePeer = msg.peerId.id == 0 || (msg.peerId.id == peerId && msg.peerId.type_ == peerType)
            if (msg.id == dialog.topMessage && samePeer) {
                chat.lastMessage = dialogPreviewText(msg)
                chat.time = formatTimestamp(Int64(msg.date))
                chat.lastMessageTimestamp = Int64(msg.date)
                chat.lastMessageType = dialogPreviewType(msg)
                chat.lastMessageViews = Int64(msg.views)
                // Phase E: 判断是否为自己发出的消息
                chat.lastMessageOutgoing = msg.isOutgoing
                // iOS parity: 已读回执——outgoing 消息 id <= readOutboxMaxId 表示对方已读(双勾)，
                // 否则已发未读(单勾)。此前恒 true 导致所有会话显示双勾。
                chat.lastMessageRead = msg.isOutgoing && msg.id <= dialog.readOutboxMaxId
                // P2-106: 群组消息发送者名称（仅群/频道显示，私聊不需要）
                if (chat.isGroup || chat.isMegagroup) {
                    if (msg.isOutgoing) {
                        chat.lastMessageSenderName = "You"
                    } else {
                        match (msg.fromId) {
                            case Some(peer) =>
                                if (peer.type_ == "user" && usersCache.contains(peer.id)) {
                                    let u = usersCache[peer.id]
                                    chat.lastMessageSenderName = u.firstName
                                } else {
                                    chat.lastMessageSenderName = ""
                                }
                            case None =>
                                chat.lastMessageSenderName = ""
                        }
                    }
                }
                // 服务消息（iOS ChatListItemStrings）：整句 "You started a video chat" / "Jack invited members…"，
                // 不走 "发送者: 内容" 的两段式。
                if (msg.isService && msg.serviceText.size > 0) {
                    let who = if (msg.isOutgoing) { "You" } else { chat.lastMessageSenderName }
                    let action = if (msg.serviceScheduleDate > 0) {
                        "${msg.serviceText} for ${formatScheduledCallFor(msg.serviceScheduleDate)}"
                    } else { msg.serviceText }
                    chat.lastMessage = if (who.size > 0) { "${who} ${action}" } else { action }
                    chat.lastMessageSenderName = ""
                }
                break
            }
        }

        chat.unreadCount = Int64(dialog.unreadCount)
        // M-2b（diag-suite_chat_list-TC-0029.md）：接上此前零消费的 wire 字段——
        // core/mtproto/TLDialogs.cj:68 已正确解析 unread_mark（flags & 8），但从未回填到
        // model。对位源侧 markedUnread 一等状态位（Postbox/Sources/PeerReadState.swift:2-3）。
        chat.isMarkedUnread = dialog.isMarkedUnread
        // iOS parity: 静音状态（muteUntil > now 表示静音中）——驱动名字旁静音图标 + 未读徽章灰
        let nowSec = Int32(DateTime.now().toUnixTimeStamp().toSeconds())
        chat.isMuted = dialog.muteUntil > nowSec
        chat.isPinned = dialog.isPinned
        // Phase Q9: 草稿消息
        chat.draftText = dialog.draft
        // P2-105: 未读提及/reaction 计数（来自 TLDialog，已由 MTProto 反序列化）
        chat.mentionCount = Int64(dialog.unreadMentionsCount)
        chat.unreadReactionsCount = Int64(dialog.unreadReactionsCount)
        // Phase P5-11: 缓存 readOutboxMaxId（对方已读到的最大消息 ID）
        if (dialog.readOutboxMaxId > 0) {
            setReadOutboxMaxId(chat.peerType, peerId, dialog.readOutboxMaxId)
        }

        return Some(chat)
    }
    
    // ==================== Phase E: 聊天列表操作 ====================
    
    /**
     * 删除对话
     */
    /**
     * Phase P1-1: 删除对话 — 真实 API 调用
     *
     * 数据流:
     *   用户对话 → messages.deleteHistory(peer, maxId=0, revoke=true)
     *   普通群 → messages.deleteChatUser(chatId, inputUserSelf)
     *   频道/超级群 → channels.leaveChannel(channel)
     *
     * 返回 true 表示服务器确认删除成功
     */
    public func deleteDialog(peerType: String, peerId: Int64, deleteGlobally!: Bool = false, revokeUserHistory!: Bool = true): Bool {
        Hilog.info(0, "CjTelegram", "[RealChatListService] deleteDialog: ${peerType} ${peerId} global=${deleteGlobally}")
        let msgService = getRealMessageService()

        try {
            if (peerType == "channel" || peerType == "chat") {
                // iOS removeChat：deleteGloballyIfPossible 时群主走 deleteChannel/deleteChat，
                // 否则 leaveChannel / deleteChatUser(self)。
                if (deleteGlobally) {
                    return msgService.deletePeerGlobally(peerType, peerId)
                }
                return msgService.leavePeer(peerType, peerId)
            } else {
                // iOS InteractiveMessagesDeletionType：forLocalPeer → revoke=false，
                // forEveryone（"Delete for me and X" → Warning! → Delete All）→ revoke=true。
                // iOS ManagedCloudChatRemoveMessagesOperations.requestClearHistory 按
                // messages.affectedHistory.offset 重复请求直到 offset == 0：单次请求只删
                // 一批，长会话对方那端会残留旧消息。clearHistory 已实现该循环并回写 pts。
                let ok = msgService.clearHistory(peerType, peerId, maxId: 0, justClear: false, revoke: revokeUserHistory)
                Hilog.info(0, "CjTelegram", "[RealChatListService] deleteHistory revoke=${revokeUserHistory} ok=${ok}")
                return ok
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] deleteDialog exception: ${e}")
            return false
        }
    }
    
    /**
     * 置顶/取消置顶对话
     */
    /**
     * Phase P1-2: 置顶/取消置顶对话 — 真实 API 调用
     *
     * 数据流: messages.toggleDialogPin(flags.pinned, InputDialogPeer(InputPeer))
     * pinned=true → 置顶, pinned=false → 取消置顶
     */
    public func togglePinDialog(peerType: String, peerId: Int64, pinned: Bool): Bool {
        Hilog.info(0, "CjTelegram", "[RealChatListService] togglePinDialog: ${peerType} ${peerId} pin=${pinned}")
        let client = getMTProtoClient()
        let msgService = getRealMessageService()

        try {
            let inputPeer = msgService.buildInputPeer(peerType, peerId)
            let dialogPeer = InputDialogPeer()
            dialogPeer.peer = inputPeer

            let req = MessagesToggleDialogPin()
            req.pinned = pinned
            req.peer = dialogPeer

            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size >= 4) {
                let checkD = TLDeserializer(responseData)
                let ctor = checkD.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errCode = checkD.readInt32()
                    let errMsg = checkD.readString()
                    Hilog.info(0, "CjTelegram", "[RealChatListService] toggleDialogPin RPC Error: ${errCode} - ${errMsg}")
                    return false
                }
            }
            Hilog.info(0, "CjTelegram", "[RealChatListService] toggleDialogPin success: ${responseData.size} bytes")
            return responseData.size > 0
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] togglePinDialog exception: ${e}")
            return false
        }
    }
    
    /**
     * 静音/取消静音对话
     */
    /**
     * Phase P1-3: 静音/取消静音对话 — 真实 API 调用
     *
     * 数据流: account.updateNotifySettings(inputNotifyPeer(InputPeer), InputPeerNotifySettings)
     * muted=true → muteUntil=2147483647 (永久静音), muted=false → muteUntil=0 (取消)
     */
    public func toggleMuteDialog(peerType: String, peerId: Int64, muted: Bool): Bool {
        Hilog.info(0, "CjTelegram", "[RealChatListService] toggleMuteDialog: ${peerType} ${peerId} mute=${muted}")
        let client = getMTProtoClient()
        let msgService = getRealMessageService()

        try {
            let inputPeer = msgService.buildInputPeer(peerType, peerId)
            let req = AccountUpdatePeerNotifySettings()
            req.peer = inputPeer
            // B5：对齐 iOS ManagedPendingPeerNotificationSettings.swift:196-240 —— 静音开关只发送
            // mute_until（Int32.max / 0），不携带 show_previews / silent，避免顺带把该会话改成
            // 「隐藏预览 + 无声」。
            req.muteUntil = if (muted) { Int32(2147483647) } else { Int32(0) }
            req.includeShowPreviews = false
            req.includeSilent = false

            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) {
                Hilog.info(0, "CjTelegram", "[RealChatListService] toggleMuteDialog empty response")
                return false
            }
            let checkD = TLDeserializer(responseData)
            let ctor = checkD.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = checkD.readInt32()
                let errMsg = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealChatListService] updateNotifySettings RPC Error: ${errCode} - ${errMsg}")
                return false
            }
            // account.updateNotifySettings 返回 Bool：boolFalse 表示服务端未应用，不能当成功。
            if (ctor == 0xbc799737) {
                Hilog.info(0, "CjTelegram", "[RealChatListService] toggleMuteDialog: server returned boolFalse")
                return false
            }
            Hilog.info(0, "CjTelegram", "[RealChatListService] toggleMuteDialog success: ${responseData.size} bytes ctor=${ctor}")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] toggleMuteDialog exception: ${e}")
            return false
        }
    }
    
    /**
     * 查询单个对话的静音状态
     *
     * 数据流: account.getNotifySettings#12b3ad31 peer:InputNotifyPeer → PeerNotifySettings
     * 返回 true 表示当前已静音（muteUntil > 0 且在当前时间之后，或 == 2147483647 永久）
     */
    public func getPeerMuteState(peerType: String, peerId: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealChatListService] getPeerMuteState: ${peerType} ${peerId}")
        let client = getMTProtoClient()
        let msgService = getRealMessageService()
        try {
            let inputPeer = msgService.buildInputPeer(peerType, peerId)
            let serializer = TLSerializer()
            serializer.writeUInt32(0x12b3ad31)          // account.getNotifySettings
            serializer.writeUInt32(0xb8bc5b0c)          // inputNotifyPeer#b8bc5b0c peer:InputPeer
            serializer.writeRawBytes(inputPeer.toBytes())

            let responseData = client.sendRequest(serializer.getBytes())
            if (responseData.size < 4) { return false }
            let d = TLDeserializer(responseData)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[RealChatListService] getPeerMuteState RPC error ${errCode}: ${errMsg}")
                return false
            }
            // PeerNotifySettings#99622c0c flags:# show_previews:flags.0?Bool silent:flags.1?Bool mute_until:flags.2?int
            if (ctor != 0x99622c0c) {
                Hilog.info(0, "CjTelegram", "[RealChatListService] getPeerMuteState unexpected ctor: 0x${ctor}")
                return false
            }
            let flags = d.readInt32()
            if ((flags & 1) != 0) { let _ = d.readUInt32() }   // showPreviews (Bool)
            if ((flags & 2) != 0) { let _ = d.readUInt32() }   // silent (Bool)
            if ((flags & 4) != 0) {
                let muteUntil = d.readInt32()
                Hilog.info(0, "CjTelegram", "[RealChatListService] getPeerMuteState muteUntil=${muteUntil}")
                return muteUntil > 0
            }
            return false
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] getPeerMuteState exception: ${e}")
            return false
        }
    }

    /**
     * 归档对话（移至 folder 1）
     */
    public func archiveChat(peerType: String, peerId: Int64): Bool {
        return editPeerFolder(peerType, peerId, 1)
    }

    /**
     * 取消归档（移回 folder 0）
     */
    public func unarchiveChat(peerType: String, peerId: Int64): Bool {
        return editPeerFolder(peerType, peerId, 0)
    }

    /**
     * 将对话移至指定文件夹（0=主列表，1=归档）
     */
    private func editPeerFolder(peerType: String, peerId: Int64, folderId: Int32): Bool {
        Hilog.info(0, "CjTelegram", "[RealChatListService] editPeerFolder: ${peerType} ${peerId} -> folder ${folderId}")
        let client = getMTProtoClient()
        let msgService = getRealMessageService()
        try {
            let inputPeer = msgService.buildInputPeer(peerType, peerId)
            let fp = InputFolderPeer()
            fp.peer = inputPeer
            fp.folderId = folderId
            let req = FoldersEditPeerFolders()
            req.folderPeers.add(fp)
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size >= 4) {
                let checkD = TLDeserializer(responseData)
                let ctor = checkD.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errCode = checkD.readInt32()
                    let errMsg = checkD.readString()
                    Hilog.info(0, "CjTelegram", "[RealChatListService] editPeerFolders RPC Error: ${errCode} - ${errMsg}")
                    return false
                }
            }
            Hilog.info(0, "CjTelegram", "[RealChatListService] editPeerFolders success")
            return responseData.size > 0
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] editPeerFolder exception: ${e}")
            return false
        }
    }

    /**
     * 标记对话已读
     */
    public func markDialogAsRead(peerType: String, peerId: Int64): Bool {
        try {
            // max_id=0 does not advance Telegram's incoming read boundary.  The
            // chat-list "Mark as Read" action means read through the current
            // top message; use the same upper-bound request as markAllRead,
            // which also clears unseen mentions like iOS ViewTracker does.
            let ok = getRealMessageService().markAllRead(
                normalizeDialogPeerType(peerType), peerId)
            Hilog.info(0, "CjTelegram",
                "[RealChatListService] markDialogAsRead peer=${peerType}/${peerId} ok=${ok}")
            return ok
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] markAsRead failed: ${e}")
            return false
        }
    }

    // 对话过滤器预设缓存（内存存储，待 messages.getDialogFilters 集成后同步服务端）
    private var _dialogFiltersCache: ArrayList<ChatFolder> = ArrayList<ChatFolder>()

    /**
     * 获取对话过滤器预设列表
     */
    public func getDialogFilters(): ArrayList<ChatFolder> {
        let result = ArrayList<ChatFolder>()
        for (f in this._dialogFiltersCache) {
            result.add(f)
        }
        return result
    }

    /**
     * 从服务器响应替换过滤器缓存（由 ChatListFilterSettingsHeaderService 调用）
     */
    public func replaceDialogFiltersCache(filters: ArrayList<ChatFolder>): Unit {
        this._dialogFiltersCache = ArrayList<ChatFolder>()
        for (f in filters) {
            this._dialogFiltersCache.add(f)
        }
        Hilog.info(0, "CjTelegram", "[RealChatListService] replaceDialogFiltersCache: ${filters.size} filters")
    }

    /**
     * 添加对话过滤器
     */
    public func addDialogFilter(filter: ChatFolder): Bool {
        this._dialogFiltersCache.add(filter)
        Hilog.info(0, "CjTelegram", "[RealChatListService] addDialogFilter: ${filter.name}")
        return true
    }

    /**
     * 更新对话过滤器
     */
    public func updateDialogFilter(id: Int32, filter: ChatFolder): Bool {
        var idx: Int64 = 0
        while (idx < this._dialogFiltersCache.size) {
            if (this._dialogFiltersCache[idx].id == id) {
                this._dialogFiltersCache.remove(at: idx)
                this._dialogFiltersCache.add(filter, at: idx)
                Hilog.info(0, "CjTelegram", "[RealChatListService] updateDialogFilter: id=${id}")
                return true
            }
            idx = idx + 1
        }
        return false
    }

    /**
     * 删除对话过滤器
     */
    public func removeDialogFilter(id: Int32): Bool {
        var idx: Int64 = 0
        while (idx < this._dialogFiltersCache.size) {
            if (this._dialogFiltersCache[idx].id == id) {
                this._dialogFiltersCache.remove(at: idx)
                Hilog.info(0, "CjTelegram", "[RealChatListService] removeDialogFilter: id=${id}")
                return true
            }
            idx = idx + 1
        }
        return false
    }

    /**
     * 获取缓存的用户
     */
    public func getCachedUser(userId: Int64): Option<UserResponse> {
        if (usersCache.contains(userId)) {
            return Some(usersCache[userId])
        }
        return None
    }

    /**
     * 获取缓存的聊天
     */
    /** 把单个用户对象并入缓存（服务端返回的最新 User，如改备注后）。 */
    public func cacheUserResponse(user: UserResponse): Unit {
        usersCache[user.id] = user
        getUserPhotoService().cacheUser(user)
        if (user.accessHash != 0) {
            getRealMessageService().cacheUserAccessHash(user.id, user.accessHash)
        }
    }

    /** 把单个会话对象并入缓存（加入群/频道后立即可打开）。 */
    public func cacheChatResponse(chat: ChatResponse): Unit {
        chatsCache[chat.id] = chat
        getUserPhotoService().cacheChat(chat)
        if (chat.isChannel && chat.accessHash != 0) {
            getRealMessageService().cacheChannelAccessHash(chat.id, chat.accessHash)
        }
    }

    /**
     * 把 RPC 返回（Updates.chats / messages.Chats）里的 Chat 实体写全本地缓存：三级内存缓存
     * + PeerTable。对位 iOS stateManager.addUpdates → updatePeers 落 Postbox。新建群返回时
     * 若不落实体，随后按服务消息投影出的会话行只能取到 "Chat <id>" 占位名并被持久化到冷启动列表。
     */
    public func cacheChatEntity(chat: ChatResponse): Unit {
        if (chat.id == 0) { return }
        this.cacheChatResponse(chat)
        if (chat.isChannel) { channelsCache[chat.id] = chat } else { legacyChatsCache[chat.id] = chat }
        let model = Chat()
        model.id = chat.id
        model.name = chat.title
        model.username = chat.username
        model.avatarText = if (chat.title.size > 0) {
            chat.title.toRuneArray()[0].toString()
        } else if (chat.isChannel) { "C" } else { "G" }
        model.isChannel = chat.isChannel
        model.isMegagroup = chat.isMegagroup
        model.isGroup = !chat.isChannel || chat.isMegagroup
        model.peerType = if (chat.isChannel) { "channel" } else { "chat" }
        model.participantsCount = Int64(chat.participantsCount)
        model.avatarLocalPath = getUserPhotoService().getChatPhotoPath(chat.id)
        getPeerStore().cacheChat(model)
        Hilog.info(0, "CjTelegram", "[RealChatListService] cached chat entity ${model.peerType}/${chat.id} '${chat.title}'")
    }

    /**
     * messages.getChats#49e9528f id:Vector<long> = messages.Chats：按 id 补拉基础群实体
     * （频道需 access_hash 走 channels.getChannels，不在此处）。结果经 cacheChatEntity 落库。
     */
    public func fetchLegacyChats(ids: ArrayList<Int64>): ArrayList<ChatResponse> {
        let out = ArrayList<ChatResponse>()
        if (ids.isEmpty()) { return out }
        try {
            let req = MessagesGetChats()
            for (id in ids) { req.ids.add(id) }
            let data = getMTProtoClient().sendRequest(req.toBytes())
            if (data.size < 8) { return out }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let code = d.readInt32()
                let msg = d.readString()
                Hilog.info(0, "CjTelegram", "[RealChatListService] getChats RPC error ${code}: ${msg}")
                return out
            }
            // messages.chats#64ff9fd5 chats:Vector<Chat> / messages.chatsSlice#9cd81144 count:int chats:Vector<Chat>
            if (ctor == 0x9cd81144) {
                let _ = d.readInt32()
            } else if (ctor != 0x64ff9fd5) {
                Hilog.info(0, "CjTelegram", "[RealChatListService] getChats unexpected ctor ${ctor}")
                return out
            }
            if (d.readUInt32() != TLConstructors.VECTOR) { return out }
            let n = d.readInt32()
            var i: Int32 = 0
            while (i < n) {
                let chat = ChatResponse.deserializeBoxed(d)
                if (chat.id != 0) {
                    out.add(chat)
                    this.cacheChatEntity(chat)
                }
                i += 1
            }
            Hilog.info(0, "CjTelegram", "[RealChatListService] getChats ids=${ids.size} -> ${out.size} chats")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] getChats error: ${e}")
        }
        return out
    }

    public func getCachedChat(chatId: Int64): Option<ChatResponse> {
        if (chatsCache.contains(chatId)) {
            return Some(chatsCache[chatId])
        }
        return None
    }

    public func getCachedChat(peerType: String, chatId: Int64): Option<ChatResponse> {
        if (peerType == "channel" && channelsCache.contains(chatId)) {
            return Some(channelsCache[chatId])
        }
        if (peerType == "chat" && legacyChatsCache.contains(chatId)) {
            return Some(legacyChatsCache[chatId])
        }
        return this.getCachedChat(chatId)
    }

    /**
     * P2-104: 标记对话为未读（messages.markDialogUnread flags=1）
     * 或取消未读标记（flags=0）。
     * TL: messages.markDialogUnread#8c5006f8 flags:# unread:flags.0?true peer:InputDialogPeer
     * iOS SynchronizePeerReadState.swift:261 flags: 1 << 0
     */
    public func markDialogUnread(peerType: String, peerId: Int64, unread: Bool): Bool {
        let client = getMTProtoClient()
        let msgService = getRealMessageService()
        try {
            let inputPeer = msgService.buildInputPeer(peerType, peerId)
            let dialogPeer = InputDialogPeer()
            dialogPeer.peer = inputPeer

            let req = MessagesMarkDialogUnread()
            req.unread = unread
            req.peer = dialogPeer

            let responseData = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[RealChatListService] markDialogUnread peerType=${peerType} peerId=${peerId} unread=${unread} response=${responseData.size} bytes")
            return responseData.size > 0
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] markDialogUnread failed: ${e}")
            return false
        }
    }

    // ==================== Phase R1: 同步状态管理 ====================

    /**
     * 向服务器请求 updates.getState，获取 (pts, qts, date, seq) 四元组。
     * 将结果持久化到 AuthStorage，作为后续增量更新 (getDifference) 的基准。
     * 
     * 返回 true 表示成功获取并存储。
     */
    public func fetchAndStoreSyncState(): Bool {
        // 首次 getState 与 getDifference 同属账号状态同步：在途期间标题显示 "Updating..."
        // （iOS AccountStateManager.currentIsUpdatingValue 初值 true，首轮 pollDifference 完成
        // 才置 false）。用 finally 成对收口，任何退出路径都不能让计数泄漏成永久 "Updating..."。
        let projection = getChatListProjection()
        projection.beginUpdating()
        try {
            return this.fetchAndStoreSyncStateUnguarded()
        } finally {
            projection.endUpdating()
        }
    }

    private func fetchAndStoreSyncStateUnguarded(): Bool {
        try {
            let requestSlot = getAuthStorage().getActiveSlot()
            let client = getMTProtoClient()
            let request = UpdatesGetState()
            let responseData = client.sendRequest(request.toBytes())

            if (requestSlot != getAuthStorage().getActiveSlot()) {
                // 请求在途期间切换了账号：响应属于上一账号，不能写进当前账号的游标。
                Hilog.info(0, "CjTelegram",
                    "[SyncState] discarded: requested for slot=${requestSlot}, active slot=${getAuthStorage().getActiveSlot()}")
                return false
            }
            if (responseData.size < 20) {
                Hilog.info(0, "CjTelegram", "[SyncState] Response too small: ${responseData.size} bytes")
                return false
            }
            
            let state = UpdatesStateResponse.deserialize(responseData)
            
            if (state.pts == 0 && state.seq == 0) {
                Hilog.info(0, "CjTelegram", "[SyncState] Empty state returned, skipping store")
                return false
            }
            
            // 持久化到 AuthStorage
            let storage = getAuthStorage()
            storage.saveSyncState(state.pts, state.qts, state.date, state.seq)
            
            Hilog.info(0, "CjTelegram", "[SyncState] Stored: pts=${state.pts}, qts=${state.qts}, date=${state.date}, seq=${state.seq}, unread=${state.unreadCount}")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SyncState] fetchAndStoreSyncState failed: ${e}")
            return false
        }
    }

    /**
     * Phase R2: 获取离线期间的增量更新
     * 
     * 使用 AuthStorage 中存储的 (pts, qts, date) 调用 updates.getDifference。
     * 解析响应中的 new_messages，并更新存储的同步状态。
     * 
     * 如果返回 differenceSlice，自动循环继续拉取直到 difference 或 empty。
     * 
     * 返回所有新消息的 TLMessage 列表。
     */
    public func fetchDifference(): ArrayList<TLMessage> {
        // getDifference 在途 ⇔ 标题 "Updating..."（iOS AccountStateManager.swift:810 开始置
        // currentIsUpdatingValue = true，:784/:793 完成置 false）。VM 首屏后台补差、
        // UpdatesManager 缺口触发、设置页 Sync Now 全部经由本入口，同步结束标题即恢复；
        // 账号切换后的补差同样走这里，不再依赖页面 isLoading 的一次性快照。
        let projection = getChatListProjection()
        projection.beginUpdating()
        try {
            return this.fetchDifferenceUnguarded()
        } finally {
            projection.endUpdating()
        }
    }

    private func fetchDifferenceUnguarded(): ArrayList<TLMessage> {
        let allNewMessages = ArrayList<TLMessage>()
        let storage = getAuthStorage()

        if (!storage.hasSyncState()) {
            Hilog.info(0, "CjTelegram", "[Difference] No stored sync state, skipping getDifference")
            return allNewMessages
        }
        
        var (pts, qts, date, _seq) = storage.getSyncState()
        // date=0 会被服务器以 400 DATE_EMPTY 拒绝；而失败后每来一条 update 又会因 pts
        // 缺口再触发一次 → 请求风暴 → 全账号 FLOOD_WAIT（真机实锤：15 分钟 117 次
        // DATE_EMPTY，FLOOD_WAIT 最长 23s，Video Chat 的请求全被拖慢）。
        // 存量状态里 date 丢了就用当前时间——pts 才是消息补齐的依据，date 只需非零。
        if (date <= 0) {
            date = Int32(DateTime.now().toUnixTimeStamp().toSeconds())
            Hilog.info(0, "CjTelegram", "[Difference] stored date is 0, using now=${date}")
        }
        var loopCount = 0
        let maxLoops = 10  // 安全限制
        let requestSlot = storage.getActiveSlot()

        while (loopCount < maxLoops) {
            loopCount += 1
            try {
                let client = getMTProtoClient()
                let request = UpdatesGetDifference()
                request.pts = pts
                request.qts = qts
                request.date = date
                
                Hilog.info(0, "CjTelegram", "[Difference] Requesting getDifference #${loopCount}: pts=${pts}, qts=${qts}, date=${date}")
                
                let responseData = client.sendRequest(request.toBytes())

                if (requestSlot != storage.getActiveSlot()) {
                    // 在途期间切换了账号：本批 difference 属于上一账号，既不落库也不写游标，
                    // 也不向调用方返回消息（调用方会把它们派生进当前账号的会话列表）。
                    Hilog.info(0, "CjTelegram",
                        "[Difference] discarded: requested for slot=${requestSlot}, active slot=${storage.getActiveSlot()}")
                    return ArrayList<TLMessage>()
                }
                if (responseData.size < 4) {
                    Hilog.info(0, "CjTelegram", "[Difference] Response too small: ${responseData.size} bytes")
                    break
                }
                
                let diff = UpdatesDifferenceResponse.deserialize(responseData)
                
                if (diff.responseType == "empty") {
                    // 没有新更新
                    Hilog.info(0, "CjTelegram", "[Difference] No new updates (empty)")
                    // 更新 date 和 seq
                    if (diff.date > 0) {
                        storage.saveSyncState(pts, qts, diff.date, diff.seq)
                    }
                    break
                }
                
                if (diff.responseType == "differenceTooLong") {
                    // 离线太久，需要完全重新同步
                    Hilog.info(0, "CjTelegram", "[Difference] Too long offline, new pts=${diff.tooLongPts}")
                    storage.saveSyncState(diff.tooLongPts, qts, date, _seq)
                    break
                }
                
                if (diff.responseType == "difference" || diff.responseType == "differenceSlice") {
                    // 收集新消息
                    for (msg in diff.newMessages) {
                        allNewMessages.add(msg)
                    }

                    // 单元 P2-296: 本地为真相源——把本批 server difference 的增量
                    // （新消息 + 涉及 peer）落本地表，使重启后增量更新保留。
                    // 用 withTransaction 原子包裹（要么全成要么回滚），对齐 iOS 在一个
                    // transaction 内应用 server difference。非侵入：内部 try/catch +
                    // Store 层 DB 降级，绝不影响下面的内存收集 / 状态更新 / UI 路径。
                    this.persistDifferenceBatch(diff)

                    // other_updates 里的已读水位与实时 update 同源，交给状态机应用。
                    // 补差期间对方读了我的消息，双勾要靠这条路进来。
                    if (!diff.readStates.isEmpty()) {
                        getUpdatesManager().applyDifferenceReadStates(diff.readStates)
                    }
                    // 补差期间对端删除的消息（updateDeleteMessages）同样要从本地消息表 / 打开的会话移除。
                    if (!diff.deletedMessageIds.isEmpty()) {
                        getUpdatesManager().applyDifferenceDeletedMessages(diff.deletedMessageIds)
                    }

                    Hilog.info(0, "CjTelegram", "[Difference] Got ${diff.newMessages.size} new messages (total: ${allNewMessages.size}), reads: ${diff.readStates.size}, type: ${diff.responseType}")
                    
                    // 更新同步状态
                    if (diff.pts > 0) {
                        pts = diff.pts
                        qts = diff.qts
                        date = diff.date
                        _seq = diff.seq
                        storage.saveSyncState(pts, qts, date, _seq)
                    }
                    
                    // difference = 最终结果，differenceSlice = 还有更多
                    if (!diff.hasMore) {
                        break
                    }
                    // differenceSlice: 继续循环拉取
                    continue
                }
                
                // 未知响应类型
                Hilog.info(0, "CjTelegram", "[Difference] Unknown response type: ${diff.responseType}")
                break
                
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[Difference] fetchDifference failed: ${e}")
                break
            }
        }
        
        if (loopCount >= maxLoops) {
            Hilog.info(0, "CjTelegram", "[Difference] Reached max loop limit (${maxLoops})")
        }
        
        Hilog.info(0, "CjTelegram", "[Difference] Total new messages from getDifference: ${allNewMessages.size}")
        return allNewMessages
    }

    /**
     * 单元 P2-296: 把一批 server difference 增量原子落本地表（本地为真相源）。
     *
     * iOS 标尺：Telegram-iOS/submodules/Postbox/Sources —— server difference 的
     * new messages / peers 在**一个 transaction 内**应用进本地表，保证重启后增量保留、
     * 中途失败整体回滚不留半套数据。本方法对齐该「一个 transaction 内落库」语义。
     *
     * 落库内容（仅 diff 已可靠 parse 出的增量；difference 解析当前跳过 other_updates，
     * 故无 read 增量可落，read 持久化属平台重架构范围，不在本单元）：
     *   - 新消息（diff.newMessages）：按 tlMsg.peerId.id 分组 → 每组转 Message 后
     *     getMessageHistoryStore().storeMessages(peerId, msgs)。
     *   - 涉及 user/peer（diff.users）：getPeerStore().cacheUserResponses(...)，
     *     让离线时仍能从本地拿到发消息方的名字 / 头像文字。
     *
     * 原子性：整批落库包进 getPostboxTransaction().withTransaction { ... }——
     * 任一 Store 写抛异常即回滚整批，对齐 iOS 差异应用在一个 transaction 内。
     *
     * 非侵入（最高优先）：
     *   - 整体再包一层 try/catch；DB 不可用 / 事务 begin 失败（Store 内部已对 DB 降级
     *     no-op，但 withTransaction.begin 需要已 open 的 RdbStore，未 open 会抛
     *     PostboxDatabaseException）时只记日志、直接返回，绝不影响既有
     *     getDifference 的网络 / 内存收集 / UI 刷新路径。
     *   - 不改任何对外签名；本方法是新增 private helper。
     */
    private func persistDifferenceBatch(diff: UpdatesDifferenceResponse): Unit {
        // 本批无任何可落增量 → 直接返回，避免空事务。
        if (diff.newMessages.isEmpty() && diff.users.isEmpty()) {
            return
        }
        try {
            // 1) 预解析新消息，并保留 PeerKey namespace；仅按数值 peerId 分组会让
            // user/chat/channel 同 ID 写进同一历史。
            let currentUserId = getCurrentUserId()
            let msgService = getRealMessageService()
            let messagePeerTypes = ArrayList<String>()
            let messagePeerIds = ArrayList<Int64>()
            let parsedMessages = ArrayList<Message>()
            let emptyNames = HashMap<Int64, String>()
            for (tlMsg in diff.newMessages) {
                let peerId = tlMsg.peerId.id
                if (peerId == 0) {
                    continue
                }
                let msg = msgService.parseMessage(tlMsg, currentUserId, emptyNames)
                messagePeerTypes.add(tlMsg.peerId.type_)
                messagePeerIds.add(peerId)
                parsedMessages.add(msg)
            }

            // 2) 原子落库：消息分组 + peer 缓存全部包进一个 transaction。
            //    Store 层各自对 DB 降级 no-op；这里负责把它们绑成一个原子批次。
            let msgStore = getMessageHistoryStore()
            let peerStore = getPeerStore()
            getPostboxTransaction().withTransaction<Unit>({ =>
                var index: Int64 = 0
                while (index < parsedMessages.size) {
                    let single = ArrayList<Message>()
                    single.add(parsedMessages[index])
                    msgStore.storeMessages(
                        messagePeerIds[index], single, peerType: messagePeerTypes[index])
                    index += 1
                }
                peerStore.cacheUserResponses(diff.users)
            })
            Hilog.info(0, "CjTelegram", "[Difference] persisted batch: ${parsedMessages.size} msgs, ${diff.users.size} users")
        } catch (e: Exception) {
            // DB 未 open / 事务失败 / 任意 Store 写异常：已回滚（withTransaction 保证），
            // 这里仅记日志降级，绝不影响既有 getDifference 路径。
            Hilog.error(0, "CjTelegram", "[Difference] persistDifferenceBatch degraded (non-fatal): ${e}")
        }
    }
}

// ==================== 选中聊天状态（用于页面间传递） ====================

private var _selectedChatId: Int64 = 0
private var _selectedChatName: String = ""
private var _selectedChatPeerType: String = "user"
// Phase Q9: 选中聊天的草稿文本
private var _selectedChatDraft: String = ""
// Phase P7B-3: 选中聊天的用户名
private var _selectedChatUsername: String = ""
// iOS ChatControllerInitialBotStart(.interactive) 对应的单次 payload。
// 由内部 tg:// 深链落地前写入，ChatRoomPage 首次装载时消费。
private var _selectedChatBotStartPayload: String = ""

public func setSelectedChat(chatId: Int64, chatName: String, peerType: String) {
    var targetId = chatId
    var targetType = normalizeDialogPeerType(peerType)
    // 已升级为超级群的基础群（chat.migrated_to）已停用：iOS 的搜索结果 / 最近搜索
    // （ChatListSearchListPaneNode.swift:2187、RecentlySearchedPeerIds.swift:112）与正在看的
    // 会话（ChatControllerContentData.swift:767 upgradedToPeerId）都改开 migrationReference.peerId。
    // 这里是所有入口（会话列表、搜索、资料页、深链）共用的选中点，旧群 id 在此统一换成新超级群。
    if (targetType == "chat") {
        match (getRealChatListService().getCachedChat("chat", chatId)) {
            case Some(group) =>
                if (!group.isChannel && group.isMigrated && group.migratedToChannelId != 0) {
                    if (group.migratedToAccessHash != 0) {
                        getRealMessageService().cacheChannelAccessHash(group.migratedToChannelId, group.migratedToAccessHash)
                    }
                    Hilog.info(0, "CjTelegram",
                        "[RealChatListService] selected basic group ${chatId} was upgraded -> channel ${group.migratedToChannelId}")
                    targetId = group.migratedToChannelId
                    targetType = "channel"
                }
            case None => ()
        }
    }
    _selectedChatId = targetId
    _selectedChatName = chatName
    _selectedChatPeerType = targetType
}

/**
 * 会话列表行预览正文（不含类型图标，图标由 ChatListItem.mediaPreviewText 按 lastMessageType 加）。
 * 对齐 iOS ChatListItemStrings.chatListItemStrings：无配文时照片 "Photo"、视频 "Video"、
 * GIF "GIF"、语音 "Voice Message"、圆形视频 "Video Message"、普通文件取文件名（无名为 "File"）；
 * 有配文时显示配文。getDialogs 与实时新消息两条路径共用，避免行上类型与正文来自不同消息。
 */
public func dialogPreviewText(msg: TLMessage): String {
    // TLDialogs 在无配文的非图片媒体上把 message 回填为 mediaDescription，
    // 这里还原成真正的配文，避免拼出 "[Video 00:05] [Video 00:05]"。
    let caption = if (msg.message == msg.mediaDescription) { "" } else { msg.message }
    let mediaLabel = match (msg.mediaType) {
        case "photo" => "Photo"
        case "video" => "Video"
        case "voice" => "Voice Message"
        case "audio" => "Music"
        case "gif" => "GIF"
        case "video_note" | "round_video" => "Video Message"
        case "document" => if (msg.documentFileName.size > 0) { msg.documentFileName } else { "File" }
        case _ => ""
    }
    if (mediaLabel.size > 0) {
        return if (caption.size > 0) { caption } else { mediaLabel }
    } else if (caption.isEmpty() && msg.mediaDescription.size > 0) {
        return msg.mediaDescription
    } else if (msg.mediaDescription.size > 0 && caption.size > 0) {
        return "${msg.mediaDescription} ${caption}"
    }
    return caption
}

/** 会话列表行的消息类型（ChatListItem.mediaPreviewText 据此选图标）；服务消息与纯文本为 "text"。 */
public func dialogPreviewType(msg: TLMessage): String {
    if (msg.isService || msg.mediaType.isEmpty()) { return "text" }
    return msg.mediaType
}

/** MTProto / UI 各入口统一使用的对话命名空间。 */
/**
 * S9-23：messages.searchGlobal#4bc6589a 带范围标志的版本 —— broadcasts_only:flags.1 /
 * groups_only:flags.2 / users_only:flags.3（iOS ChatListSearchListPaneNode Messages 段
 * "From All Chats" 菜单：All / Private Chats / Group Chats / Channels）。
 */
public class MessagesSearchGlobalScoped <: TLObject {
    public var q: String = ""
    public var limit: Int32 = 30
    public var broadcastsOnly: Bool = false
    public var groupsOnly: Bool = false
    public var usersOnly: Bool = false

    public func getConstructorId(): UInt32 { return 0x4bc6589a }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.broadcastsOnly) { flags = flags | 2 }
        if (this.groupsOnly) { flags = flags | 4 }
        if (this.usersOnly) { flags = flags | 8 }
        serializer.writeInt32(flags)
        serializer.writeString(this.q)
        serializer.writeRawBytes(InputMessagesFilterEmpty().toBytes())
        serializer.writeInt32(0) // min_date
        serializer.writeInt32(0) // max_date
        serializer.writeInt32(0) // offset_rate
        serializer.writeRawBytes(InputPeerEmpty().toBytes())
        serializer.writeInt32(0) // offset_id
        serializer.writeInt32(this.limit)
    }
}

/**
 * S9-11：channels.getChannelRecommendations#25a71742 flags:# channel:flags.0?InputChannel = messages.Chats
 * 不传 channel → 全局推荐（iOS requestGlobalRecommendedChannelsIfNeeded / recommendedChannels(peerId: nil)）。
 */
public class ChannelsGetChannelRecommendations <: TLObject {
    public func getConstructorId(): UInt32 { return 0x25a71742 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)
    }
}

/**
 * messages.getChats#49e9528f id:Vector<long> = messages.Chats（iOS Api42.swift getChats：
 * 1240027791 → 0x49e9528f，随后 vector#1cb5c415）。
 */
public class MessagesGetChats <: TLObject {
    public var ids = ArrayList<Int64>()

    public func getConstructorId(): UInt32 { return 0x49e9528f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.ids.size))
        for (id in this.ids) { serializer.writeInt64(id) }
    }
}

/**
 * S9-11：全局搜索 Channels 分类的 RECOMMENDED CHANNELS。返回的 ChatResponse 已并入缓存
 * （长按 Join Channel / 点开预览时需要 access_hash）。
 */
public func fetchRecommendedChannels(): ArrayList<ChatResponse> {
    let out = ArrayList<ChatResponse>()
    try {
        let data = getMTProtoClient().sendRequest(ChannelsGetChannelRecommendations().toBytes())
        if (data.size < 8) { return out }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let code = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[RealChatListService] getChannelRecommendations RPC error ${code}: ${msg}")
            return out
        }
        // messages.chats#64ff9fd5 chats:Vector<Chat> / messages.chatsSlice#9cd81144 count:int chats:Vector<Chat>
        if (ctor == 0x9cd81144) {
            let _ = d.readInt32()
        } else if (ctor != 0x64ff9fd5) {
            Hilog.info(0, "CjTelegram", "[RealChatListService] getChannelRecommendations unexpected ctor ${ctor}")
            return out
        }
        if (d.readUInt32() != TLConstructors.VECTOR) { return out }
        let n = d.readInt32()
        var i: Int32 = 0
        while (i < n) {
            let chat = ChatResponse.deserializeBoxed(d)
            if (chat.id != 0 && chat.title.size > 0) {
                out.add(chat)
                getRealChatListService().cacheChatResponse(chat)
            }
            i += 1
        }
        Hilog.info(0, "CjTelegram", "[RealChatListService] getChannelRecommendations -> ${out.size} channels")
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[RealChatListService] getChannelRecommendations error: ${e}")
    }
    return out
}

public func normalizeDialogPeerType(peerType: String): String {
    return PeerKey.fromPeerType(peerType, 0).toPeerType()
}

public func isSameDialogPeer(leftType: String, leftId: Int64, rightType: String, rightId: Int64): Bool {
    return PeerKey.fromPeerType(leftType, leftId).equals(PeerKey.fromPeerType(rightType, rightId))
}

/**
 * Phase Q9: 设置选中聊天的草稿（导航到聊天室前调用）
 */
public func setSelectedChatDraft(draft: String) {
    _selectedChatDraft = draft
}

public func getSelectedChatId(): Int64 { return _selectedChatId }
public func getSelectedChatName(): String { return _selectedChatName }
public func getSelectedChatPeerType(): String { return _selectedChatPeerType }
public func getSelectedChatDraft(): String { return _selectedChatDraft }
public func setSelectedChatUsername(username: String) { _selectedChatUsername = username }
public func getSelectedChatUsername(): String { return _selectedChatUsername }
public func setSelectedChatBotStartPayload(payload: String) { _selectedChatBotStartPayload = payload }

// iOS NavigateToChatControllerParams(subject: .message(id:...))：打开会话并定位到指定消息
// （全局搜索结果点按 / View in Chat）。单次消费，ChatRoomPage 首次装载时取走。
private var _selectedChatFocusMessageId: Int64 = 0
public func setSelectedChatFocusMessageId(messageId: Int64) { _selectedChatFocusMessageId = messageId }
public func consumeSelectedChatFocusMessageId(): Int64 {
    let value = _selectedChatFocusMessageId
    _selectedChatFocusMessageId = 0
    return value
}

// S8-08：打开秘密聊天（peerType "secret"，selectedId = secretChatId）时的对端 userId，
// 会话页用它取头像 / 握手状态文案（iOS TelegramSecretChat.regularPeerId）。单次消费。
private var _selectedSecretPeerUserId: Int64 = 0
public func setSelectedSecretPeerUserId(userId: Int64) { _selectedSecretPeerUserId = userId }
public func consumeSelectedSecretPeerUserId(): Int64 {
    let value = _selectedSecretPeerUserId
    _selectedSecretPeerUserId = 0
    return value
}
public func consumeSelectedChatBotStartPayload(): String {
    let payload = _selectedChatBotStartPayload
    _selectedChatBotStartPayload = ""
    return payload
}

/**
 * 用户显示名 —— 对齐 iOS EnginePeer.displayTitle（LocalizedPeerData/Sources/PeerTitle.swift:31）：
 * first + last；只有其一取其一；都为空且无手机号 → User.DeletedAccount（已注销账号）；
 * 都为空但有手机号 → 空串（iOS 同样返回 ""）。
 */
public func userDisplayTitle(firstName: String, lastName: String, phone: String): String {
    if (firstName.size > 0) {
        if (lastName.size > 0) { return "${firstName} ${lastName}" }
        return firstName
    }
    if (lastName.size > 0) { return lastName }
    if (phone.size > 0) { return "" }
    return trOr("User.DeletedAccount", "Deleted Account")
}

/** 自聊天标题：iOS ChatTitleView.swift:290 strings.Conversation_SavedMessages。 */
public func savedMessagesChatTitle(): String {
    return trOr("Conversation.SavedMessages", "Saved Messages")
}

/** 与 userDisplayTitle 同一判定：名字全空且无手机号即为已注销账号（iOS 头像同时走 deletedIcon）。 */
public func isDeletedAccountName(firstName: String, lastName: String, phone: String): Bool {
    return firstName.size == 0 && lastName.size == 0 && phone.size == 0
}

// 获取当前登录用户 ID
public func getCurrentUserId(): Int64 {
    let authService = getRealAuthService()
    match (authService.getCurrentUser()) {
        case Some(user) => return user.id
        case None => return 0
    }
}

// 应用文件目录缓存（启动时由 MainAbility 设置）
private var _appFilesDir: String = ""

public func setAppFilesDir(dir: String): Unit {
    _appFilesDir = dir
    Hilog.info(0, "CjTelegram", "[setAppFilesDir] Set to: ${dir}")
}

public func getAppFilesDir(): String {
    return _appFilesDir
}

// 全局 UIAbilityContext 缓存（启动时由 MainAbility 设置）
private var _globalAbilityContext: Option<UIAbilityContext> = None

public func setGlobalAbilityContext(ctx: UIAbilityContext): Unit {
    _globalAbilityContext = Some(ctx)
}

public func getGlobalAbilityContext(): Option<UIAbilityContext> {
    return _globalAbilityContext
}

// ==================== 当前真正可见的会话 ====================
// selectedChat 只是导航参数，离开 ChatRoom 后仍会保留，不能用于抑制未读或投递消息。
private let _visibleConversationMonitor: Monitor = Monitor()
private var _visibleConversationKey: Option<PeerKey> = None
private var _visibleConversationGeneration: Int64 = 0

public func showConversation(peerType: String, peerId: Int64): Int64 {
    return synchronized(_visibleConversationMonitor) {
        _visibleConversationGeneration += 1
        _visibleConversationKey = Some(PeerKey.fromPeerType(peerType, peerId))
        _visibleConversationGeneration
    }
}

public func hideConversation(generation: Int64): Unit {
    synchronized(_visibleConversationMonitor) {
        if (generation == _visibleConversationGeneration) {
            _visibleConversationKey = None
        }
    }
}

public func isConversationVisible(peerType: String, peerId: Int64): Bool {
    return synchronized(_visibleConversationMonitor) {
        match (_visibleConversationKey) {
            case Some(key) => key.equals(PeerKey.fromPeerType(peerType, peerId))
            case None => false
        }
    }
}

// ==================== Phase P5-11: 已读回执 readOutboxMaxId 缓存 ====================

private var _readOutboxMaxIdCache: HashMap<String, Int32> = HashMap<String, Int32>()
private let _readOutboxMaxIdMonitor: Monitor = Monitor()

private func dialogPeerCacheKey(peerType: String, peerId: Int64): String {
    return "${normalizeDialogPeerType(peerType)}:${peerId}"
}

public func setReadOutboxMaxId(peerType: String, peerId: Int64, maxId: Int32): Unit {
    synchronized(_readOutboxMaxIdMonitor) {
        _readOutboxMaxIdCache[dialogPeerCacheKey(peerType, peerId)] = maxId
    }
}

public func getReadOutboxMaxId(peerType: String, peerId: Int64): Int32 {
    let key = dialogPeerCacheKey(peerType, peerId)
    return synchronized(_readOutboxMaxIdMonitor) {
        if (_readOutboxMaxIdCache.contains(key)) {
            return _readOutboxMaxIdCache[key]
        }
        return 0
    }
}

// ==================== Phase P5-3: 剪贴板（委托系统剪贴板，进程内镜像兜底） ====================

private var _clipboardText: String = ""

public func setClipboardText(text: String): Unit {
    _clipboardText = text
    let ok = copyText(text)
    if (ok) {
        Hilog.info(0, "CjTelegram", "[Clipboard] Set (system+mirror): len=${text.size}")
    } else {
        Hilog.info(0, "CjTelegram", "[Clipboard] Set (mirror only, system write failed): len=${text.size}")
    }
}

public func getClipboardText(): String {
    let sys = readText()
    if (sys.size > 0) {
        return sys
    }
    return _clipboardText
}

// ====================

/**
 * Phase E: 聊天列表排序
 * 置顶聊天优先，非置顶按最后消息时间降序
 */
// B3-1: 提升为 public —— ChatListViewModel（viewmodels 包）需复用同一套排序，
// 保证「本地应用」与「网络回源」两条路径产出的顺序完全一致。
// 仓颉顶层声明默认为 internal（仅当前包及子包可见），而 viewmodels 与 services
// 是平级包，不提升则跨包不可见（KB《顶层声明的可见性》）。
public func sortChatList(items: ArrayList<Chat>): ArrayList<Chat> {
    // 分离置顶和非置顶
    let pinned = ArrayList<Chat>()
    let normal = ArrayList<Chat>()
    for (item in items) {
        if (item.isPinned) {
            pinned.add(item)
        } else {
            normal.add(item)
        }
    }
    
    // 非置顶按时间降序排序（简单冒泡）
    let n = normal.size
    var i: Int64 = 0
    while (i < n) {
        var j: Int64 = 0
        while (j < n - 1 - i) {
            if (normal[j].lastMessageTimestamp < normal[j + 1].lastMessageTimestamp) {
                let tmp = normal[j]
                normal[j] = normal[j + 1]
                normal[j + 1] = tmp
            }
            j += 1
        }
        i += 1
    }
    
    // 合并：置顶在前
    let result = ArrayList<Chat>()
    for (p in pinned) {
        result.add(p)
    }
    for (nm in normal) {
        result.add(nm)
    }
    return result
}

/**
 * 格式化时间戳为 iOS ChatList 样式：
 *   - 今天       → HH:mm（例 "14:30"）
 *   - 昨天       → "Yesterday"
 *   - 本年内     → "M/D"（例 "6/18"）
 *   - 更早       → "M/D/YY"（例 "3/5/24"）
 *
 * DateTime API（Cangjie 6.0）:
 *   .year → Int64, .month → Month(enum), .monthValue → Int64(deprecated OK),
 *   .dayOfMonth → Int64, .hour/.minute/.second → Int64
 */
// B3-1: 提升为 public —— 本地应用需产出与回源路径一致的时间显示串。纯函数，无副作用。
// 提升理由同 sortChatList（跨平级包不可见）。
public func formatTimestamp(timestamp: Int64): String {
    return formatRelativeTimestamp(timestamp)
}
