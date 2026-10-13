package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.*
import std.collection.ArrayList
import std.collection.HashMap
import std.sync.ReentrantMutex
import std.time.DateTime
import std.random.Random
import ohos_app_cangjie_entry.utils.{formatClockHHMM, decodeTinyThumbnailToDataUrl, formatScheduledCallFor}
import ohos_app_cangjie_entry.core.storage.getAuthStorage

// getFullChatInfo 的按会话合并锁 + 8s 结果缓存（须先于使用处定义）
let _fullChatGate = ReentrantMutex()
let _fullChatCache = HashMap<String, (Int64, ChatFullResponse)>()
/**
 * 真实消息服务（Phase Q1 统一解析 pipeline）
 * 
 * 对应 TelegramHarmony 的 RealMessageService.ets
 * 
 * 统一消息解析架构:
 * - parseMessage(): 统一消息解析入口，TLMessage → Message
 * - parseMessageMedia(): 媒体类型分发器
 *   - parsePhotoMedia(): 照片媒体
 *   - parseDocumentMedia(): 文档类媒体（视频/语音/音频/文件/GIF/贴纸）
 *     - parseVideoAttributes(): 视频属性
 *     - parseAudioAttributes(): 音频/语音属性
 *     - (Q2: voice 波形数据)
 *     - (Q3: sticker 贴纸信息)
 *     - (Q4: gif 动画信息)
 * - parseMessageReactionsData(): Reactions 数据
 * 
 * 发送功能:
 * - sendMessage, sendMessageWithReply, deleteMessages, editMessage
 * - forwardMessages, searchMessages, sendPhoto, sendDocument
 */

// ==================== Phase Q6: 发送响应结果 ====================

/**
 * 发送消息/媒体后服务端返回的解析结果
 * 
 * 对应 TelegramHarmony parseSendMessageResponse / parseSendMediaResponse
 * 核心字段：
 * - success: 请求是否成功
 * - messageId: 服务端分配的真实消息 ID（来自 updateShortSentMessage）
 * - pts: 服务端 pts 值（用于后续同步）
 * - date: 服务端时间戳
 * - errorCode / errorMessage: RPC 错误信息
 */
public class SendMessageResult {
    public var success: Bool = false
    public var messageId: Int32 = 0
    public var pts: Int32 = 0
    public var ptsCount: Int32 = 0
    public var date: Int32 = 0
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""

    public init() {}

    public init(success: Bool, messageId: Int32, pts: Int32, date: Int32) {
        this.success = success
        this.messageId = messageId
        this.pts = pts
        this.date = date
    }
}

// ==================== 公共工具函数 ====================

/**
 * 格式化消息时间戳为 "HH:MM" 字符串。
 *
 * 现委托给 utils/TimeFormatUtils.formatClockHHMM，使用 **本地时区** 取时分；
 * 旧实现按 UTC 取时分（timestamp % 86400），存在时区偏差。签名/返回形态（"HH:MM"）不变。
 */
public func formatMessageTime(timestamp: Int64): String {
    return formatClockHHMM(timestamp)
}

/**
 * 从名字中提取首字母缩写
 * 
 * 例如: "Hao Yuan" → "HY", "Alice" → "A", "John Doe" → "JD"
 * 支持 Unicode 名字（中文、俄文等）
 */
public func getNameInitials(name: String): String {
    if (name.size == 0) { return "" }
    let runes = name.toRuneArray()
    var result = ""
    var takeNext = true
    for (r in runes) {
        if (r.toString() == " ") {
            takeNext = true
        } else if (takeNext) {
            result = result + r.toString()
            takeNext = false
        }
    }
    return result
}
private var _realMessageServiceInstance: Option<RealMessageService> = None

public func getRealMessageService(): RealMessageService {
    match (_realMessageServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = RealMessageService()
            _realMessageServiceInstance = Some(inst)
            return inst
    }
}

public class RealMessageService {
    // accessHash 缓存
    private var userAccessHashes = HashMap<Int64, Int64>()
    private var channelAccessHashes = HashMap<Int64, Int64>()
    private static let _rand = Random()

    // ic_messages_update_chat_list: single-slot history change listener
    private var _historyListener: Option<(Int64) -> Unit> = None

    public func setHistoryListener(listener: (Int64) -> Unit): Unit {
        this._historyListener = Some(listener)
    }

    public func notifyHistoryChanged(peerId: Int64): Unit {
        match (this._historyListener) {
            case Some(cb) => cb(peerId)
            case None => ()
        }
        // S4-13: open chat pages subscribe too (iOS: Postbox history view sees the
        // .clearHistory operation immediately; here the ChatRoomViewModel clears its
        // local history view and reloads).
        for ((_token, cb) in this._historyChangedListeners) { cb(peerId) }
    }

    private var _historyChangedListeners: HashMap<Int64, (Int64) -> Unit> = HashMap<Int64, (Int64) -> Unit>()

    public func addHistoryChangedListener(token: Int64, listener: (Int64) -> Unit): Unit {
        this._historyChangedListeners[token] = listener
    }

    public func removeHistoryChangedListener(token: Int64): Unit {
        let _ = this._historyChangedListeners.remove(token)
    }

    // ==================== 缓存管理 ====================

    public func cacheUserAccessHash(userId: Int64, accessHash: Int64) {
        this.userAccessHashes[userId] = accessHash
    }

    public func getAccessHashForUser(userId: Int64): Int64 {
        if (this.userAccessHashes.contains(userId)) {
            return this.userAccessHashes[userId]
        }
        return 0
    }

    public func cacheChannelAccessHash(channelId: Int64, accessHash: Int64) {
        let changed = !this.channelAccessHashes.contains(channelId) ||
            this.channelAccessHashes[channelId] != accessHash
        this.channelAccessHashes[channelId] = accessHash
        // 同时落本地 peer（iOS TelegramChannel.accessHash 存 Postbox）：冷启动后会话列表先由本地秒开，
        // getDialogs 回来前点进超级群发消息，内存里还没有 hash → inputPeerChannel access_hash=0 →
        // CHANNEL_INVALID（V3 E2 实测）。
        if (changed && accessHash != 0) {
            getPeerStore().cacheChannelAccessHash(channelId, accessHash)
        }
    }

    public func getAccessHashForChannel(channelId: Int64): Int64 {
        if (this.channelAccessHashes.contains(channelId)) {
            let cached = this.channelAccessHashes[channelId]
            if (cached != 0) { return cached }
        }
        let stored = getPeerStore().getChannelAccessHash(channelId)
        if (stored != 0) {
            this.channelAccessHashes[channelId] = stored
        }
        return stored
    }

    // ==================== Q1: 统一消息解析 pipeline ====================

    /**
     * 统一消息解析入口
     * 
     * 将 TLMessage (从 TLDialogs 反序列化) 转换为 UI Message 模型。
     * 所有媒体类型通过 parseMessageMedia() 分发到各子解析器。
     * 
     * 对应 TelegramHarmony RealMessageService.ets 的:
     *   parseMessage() → parseMessageContent() → parseMessageMedia()
     * 
     * @param tlMsg TL 层反序列化得到的消息对象
     * @param currentUserId 当前登录用户 ID（用于判断 isSent）
     * @param userNames 用户 ID → 显示名称的查找表
     * @return 完全填充的 UI Message 模型
     */
    /**
     * iOS Message.effectivelyIncoming 在 id.peerId == accountPeerId 分支的逐条对照：
     *   SourceAuthorInfo（saved_from_id / saved_out 等）存在 → originalOutgoing 或 originalAuthor==我 为发出；
     *   否则 forwardInfo.author==我 为发出；
     *   其余：有 forwardInfo 即收到，无 forwardInfo（自己直接发到收藏夹）即发出。
     */
    public static func savedMessageEffectivelyIncoming(tlMsg: TLMessage, accountPeerId: Int64): Bool {
        if (tlMsg.fwdSavedOut || tlMsg.fwdSavedFromPeerId != 0) {
            if (tlMsg.fwdSavedOut) { return false }
            if (tlMsg.fwdSavedFromPeerId == accountPeerId) { return false }
        } else if (tlMsg.hasForwardInfo && tlMsg.fwdFromPeerType == "user" && tlMsg.fwdFromPeerId == accountPeerId) {
            return false
        }
        return tlMsg.hasForwardInfo
    }

    public func parseMessage(
        tlMsg: TLMessage,
        currentUserId: Int64,
        userNames: HashMap<Int64, String>,
        conversationPeerType!: String = "",
        conversationPeerId!: Int64 = 0
    ): Message {
        let msg = Message()

        // ====== 基础字段 ======
        msg.id = Int64(tlMsg.id)
        msg.content = tlMsg.message
        msg.time = formatMessageTime(Int64(tlMsg.date))
        msg.rawTimestamp = Int64(tlMsg.date)
        msg.mediaUnread = tlMsg.mediaUnread
        msg.ttlPeriod = tlMsg.ttlPeriod

        // ====== 发送者信息 ======
        let fromUserId: Int64 = match (tlMsg.fromId) {
            case Some(peer) =>
                msg.senderPeerType = peer.type_
                peer.id
            case None => 0
        }
        // 收发方向以 TL `out` 位(flags.1)为准，与作者身份解耦（audit P0-1）。
        // 此前用 fromUserId==currentUserId 推断：私聊 updateShortMessage 结构上无
        // from_id → 自发消息 fromUserId=0 → 误判为来信（左侧/错色/无勾、发完从右跳左）；
        // 群匿名管理员/send-as 时 out=1 但 from_id≠我也会误判。isOutgoing 已由
        // (flags & 2) 正确解析（同仓 HashtagSearchService:109 即此写法）。
        msg.isSent = tlMsg.isOutgoing
        // Saved Messages（peer == 自己）服务端不置 out 位；iOS 按 Message.effectivelyIncoming
        // (TelegramCore/Sources/Utils/MessageUtils.swift:348) 另行判定方向。
        if (currentUserId != 0 && tlMsg.peerId.type_ == "user" && tlMsg.peerId.id == currentUserId) {
            msg.isSent = !RealMessageService.savedMessageEffectivelyIncoming(tlMsg, currentUserId)
        }
        // Phase P5-11: 发送消息默认 "sent"，收到消息不显示状态
        // readOutboxMaxId 在 parseMessages() 后由 ViewModel 应用
        msg.status = if (msg.isSent) { "sent" } else { "read" }
        msg.senderId = fromUserId
        if (userNames.contains(fromUserId)) {
            msg.senderName = userNames[fromUserId]
        } else if (msg.senderPeerType == "user" && fromUserId != 0) {
            // updateEditMessage / updateNewMessage 不携带 users 向量。iOS 从 Postbox
            // 的 peer table 解析 effectiveAuthor；鸿蒙侧等价地回查共享用户缓存。
            match (getUserPhotoService().getCachedUser(fromUserId)) {
                case Some(user) =>
                    var cachedName = user.firstName
                    if (user.lastName.size > 0) { cachedName = cachedName + " " + user.lastName }
                    msg.senderName = cachedName
                case None => ()
            }
        } else if (msg.senderPeerType != "user" && fromUserId != 0) {
            // 匿名管理员 / send-as-channel：作者是群或频道本身。
            match (getRealChatListService().getCachedChat(fromUserId)) {
                case Some(chat) => msg.senderName = chat.title
                case None => ()
            }
        }

        // ====== 消息类型判定 ======
        msg.messageType = this.determineMessageType(tlMsg)
        msg.mediaDescription = tlMsg.mediaDescription
        if (tlMsg.contactPhone.size > 0 || tlMsg.contactFirstName.size > 0 || tlMsg.contactLastName.size > 0) {
            msg.contactPhone = tlMsg.contactPhone
            msg.contactDisplayName = "${tlMsg.contactFirstName} ${tlMsg.contactLastName}".trimAscii()
        }

        // ====== Phase T3: 通话消息数据 ======
        if (tlMsg.callId != 0) {
            msg.isCallMessage = true
            msg.callDuration = tlMsg.callDuration
            msg.messageType = "phone_call"
            // Map call reason constructor to string
            if (tlMsg.callReason == 0x85e42301) {
                msg.callReason = "missed"
            } else if (tlMsg.callReason == 0xfaf7e8c9) {
                msg.callReason = "busy"
            } else if (tlMsg.callReason == 0xe095c1a0) {
                msg.callReason = "disconnect"
            } else if (tlMsg.callReason == 0x57adc690) {
                msg.callReason = "hangup"
            }
        }

        // ====== P2-113: service action text + album groupedId ======
        if (tlMsg.isService && tlMsg.serviceText.size > 0) {
            msg.serviceText = tlMsg.serviceText
            if (tlMsg.serviceScheduleDate > 0) {
                msg.serviceText = "${tlMsg.serviceText} for ${formatScheduledCallFor(tlMsg.serviceScheduleDate)}"
            }
            // iOS Notification.Kicked："%@ removed %@"；自己退群才是 "left the group"
            if (tlMsg.actionUserId != 0 && tlMsg.actionUserId != msg.senderId) {
                msg.serviceText = "removed ${this.cachedUserDisplayName(tlMsg.actionUserId)}"
            }
            // iOS Notification.Invited："%@ invited %@"；自己加入是 "joined the group"
            if (!tlMsg.actionUserIds.isEmpty()) {
                if (tlMsg.actionUserIds.size == 1 && tlMsg.actionUserIds[0] == msg.senderId) {
                    msg.serviceText = "joined the group"
                } else {
                    var names = ""
                    for (uid in tlMsg.actionUserIds) {
                        if (names.size > 0) { names = names + ", " }
                        names = names + this.cachedUserDisplayName(uid)
                    }
                    msg.serviceText = "invited ${names}"
                }
            }
        }
        msg.hiddenInHistory = tlMsg.isService && tlMsg.isMigrationAction
        msg.groupedId = tlMsg.groupedId
        // iOS ServiceMessageStrings.swift:438-510 messageAutoremoveTimeoutUpdated：整句文案，不再前缀发送者名
        if (tlMsg.isService && tlMsg.serviceTtlPeriod >= 0) {
            msg.serviceTtlPeriod = tlMsg.serviceTtlPeriod
            let fromSelf = tlMsg.isOutgoing || (fromUserId != 0 && fromUserId == currentUserId)
            var authorName = msg.senderName
            match (getUserPhotoService().getCachedUser(fromUserId)) {
                case Some(u) => if (u.firstName.size > 0) { authorName = u.firstName }
                case None => ()
            }
            var broadcast = false
            if (conversationPeerType == "channel") {
                match (getRealChatListService().getCachedChat("channel", conversationPeerId)) {
                    case Some(c) => broadcast = c.isBroadcast
                    case None => ()
                }
            }
            msg.serviceText = autoremoveServiceText(tlMsg.serviceTtlPeriod, tlMsg.serviceTtlAutoFrom,
                fromSelf, currentUserId, authorName, conversationPeerType, broadcast)
            msg.senderName = ""
        }
        // S6-05：messageActionSetChatWallPaper → iOS ServiceMessageStrings.swift:1068-1096
        // （Notification.YouChangedWallpaper / ChangedWallpaper / YouChangedWallpaperBoth /
        // YouChangedToSameWallpaper / ChangedToSameWallpaper / YouChangedGroupWallpaper /
        // GroupChangedWallpaper / ChannelChangedWallpaper）：整句文案，不再前缀发送者名。
        if (tlMsg.isService && tlMsg.isWallpaperAction) {
            msg.serviceWallpaperId = tlMsg.serviceWallpaperId
            msg.serviceWallpaperAccessHash = tlMsg.serviceWallpaperAccessHash
            msg.serviceWallpaperSlug = tlMsg.serviceWallpaperSlug
            let fromSelf = tlMsg.isOutgoing || (fromUserId != 0 && fromUserId == currentUserId)
            var authorName = msg.senderName
            match (getUserPhotoService().getCachedUser(fromUserId)) {
                case Some(u) => if (u.firstName.size > 0) { authorName = u.firstName }
                case None => ()
            }
            var isGroup = conversationPeerType == "chat"
            if (conversationPeerType == "channel") {
                match (getRealChatListService().getCachedChat("channel", conversationPeerId)) {
                    case Some(c) => isGroup = !c.isBroadcast
                    case None => ()
                }
            }
            msg.serviceText = if (tlMsg.serviceWallpaperSame) {
                if (fromSelf) { "You set the same wallpaper for this chat" } else { "${authorName} set the same wallpaper for this chat" }
            } else if (fromSelf) {
                if (tlMsg.serviceWallpaperForBoth && conversationPeerType == "user") {
                    "You set a new wallpaper for ${this.cachedUserDisplayName(conversationPeerId)} and you."
                } else if (conversationPeerType == "user") {
                    "You set a new wallpaper for this chat"
                } else if (isGroup) {
                    "You set a new wallpaper for this group"
                } else {
                    "You set a new wallpaper for this chat"
                }
            } else if (conversationPeerType == "user") {
                "${authorName} set a new wallpaper for this chat"
            } else if (isGroup) {
                "Group set a new wallpaper"
            } else {
                "Channel set a new wallpaper"
            }
            msg.senderName = ""
        }
        // 回复键盘（iOS ReplyMarkupMessageAttribute）
        msg.replyMarkupKind = tlMsg.replyMarkupKind
        msg.replyKeyboardRows = tlMsg.replyKeyboardRows
        msg.replyKeyboardSingleUse = tlMsg.replyKeyboardSingleUse
        msg.replyKeyboardResize = tlMsg.replyKeyboardResize
        msg.replyKeyboardPlaceholder = tlMsg.replyKeyboardPlaceholder

        // ====== 回复 / 转发 / 编辑 / 置顶 / 频道 ======
        msg.replyToMsgId = Int64(tlMsg.replyToMsgId)
        msg.forwardFromName = this.forwardSourceName(tlMsg, userNames, HashMap<Int64, String>())
        // 隐藏编辑(edit_hide)不显示"edited"（audit P2-5，对齐 iOS EditedMessageAttribute.isHidden）
        msg.isEdited = (tlMsg.editDate > 0) && !tlMsg.editHide
        msg.isPinned = tlMsg.isPinned
        msg.views = Int64(tlMsg.views)
        msg.repliesCount = tlMsg.repliesCount
        msg.repliesIsComments = tlMsg.repliesIsComments
        msg.repliesChannelId = tlMsg.repliesChannelId

        // ====== Phase Q11: 富文本实体 ======
        this.parseTextEntities(tlMsg, msg)

        // ====== 媒体解析分发 ======
        this.parseMessageMedia(tlMsg, msg)

        // ====== Reactions ======
        this.parseMessageReactionsData(
            tlMsg,
            msg,
            userNames,
            currentUserId,
            conversationPeerType,
            conversationPeerId
        )

        return msg
    }

    /**
     * 批量解析消息列表
     * 
     * 将 MessagesHistoryResponse 中的 TLMessage 列表转换为 UI Message 列表。
     * 包含：解析 → 反转排序（旧→新）→ 填充回复预览。
     * 
     * @param historyResponse getHistory/searchMessages 的响应
     * @param currentUserId 当前登录用户 ID
     * @param photoPathCache 已下载照片的路径缓存（photoId/docId → localPath）
     * @return 按时间正序排列的 Message 列表
     */
    public func parseMessages(
        historyResponse: MessagesHistoryResponse,
        currentUserId: Int64,
        photoPathCache: HashMap<Int64, String>,
        conversationPeerType!: String = "",
        conversationPeerId!: Int64 = 0
    ): ArrayList<Message> {
        // 构建用户名查找表
        let userNames = HashMap<Int64, String>()
        let chatNames = HashMap<Int64, String>()
        let photoService = getUserPhotoService()
        photoService.cacheUsers(historyResponse.users)
        for (user in historyResponse.users) {
            var name = user.firstName
            if (user.lastName.size > 0) { name = name + " " + user.lastName }
            userNames[user.id] = name
        }
        for (chat in historyResponse.chats) {
            if (chat.title.size > 0) { chatNames[chat.id] = chat.title }
        }
        match (getAuthStorage().getUserData()) {
            case Some(me) =>
                var ownName = me.firstName
                if (me.lastName.size > 0) { ownName = ownName + " " + me.lastName }
                userNames[me.id] = ownName
            case None => ()
        }

        // 逐条解析（Telegram 返回按时间倒序）
        let rawMessages = ArrayList<Message>()
        for (tlMsg in historyResponse.messages) {
            if (tlMsg.isEmpty) { continue }
            let msg = this.parseMessage(
                tlMsg,
                currentUserId,
                userNames,
                conversationPeerType: conversationPeerType,
                conversationPeerId: conversationPeerId
            )
            // 匿名管理员 / send-as-group 的 from_id 是 peerChat/peerChannel。
            // iOS 以 effectiveAuthor 的群标题显示作者；不能拿同数值 user id 去查用户名。
            if (msg.senderPeerType != "user" && chatNames.contains(msg.senderId)) {
                msg.senderName = chatNames[msg.senderId]
            }
            // 转发来源是频道/群时，名字以本次响应 chats 向量为准（同上 effectiveAuthor 口径）。
            if (tlMsg.fwdFromPeerType.size > 0 && tlMsg.fwdFromPeerType != "user" &&
                chatNames.contains(tlMsg.fwdFromPeerId)) {
                msg.forwardFromName = this.forwardSourceName(tlMsg, userNames, chatNames)
            }

            // 从缓存恢复已下载路径
            if (msg.photoId != 0 && photoPathCache.contains(msg.photoId)) {
                msg.photoLocalPath = photoPathCache[msg.photoId]
            }
            if (msg.documentId != 0 && photoPathCache.contains(msg.documentId)) {
                msg.documentLocalPath = photoPathCache[msg.documentId]
            }
            // P7B-1: 恢复网页预览缩略图路径
            if (msg.webPagePhotoId != 0 && photoPathCache.contains(msg.webPagePhotoId)) {
                msg.webPagePhotoLocalPath = photoPathCache[msg.webPagePhotoId]
            }

            rawMessages.add(msg)
        }

        // 反转：旧 → 新
        let messages = ArrayList<Message>()
        var i = rawMessages.size - 1
        while (i >= 0) {
            messages.add(rawMessages[i])
            i -= 1
        }

        // 填充回复预览文本
        let msgMap = HashMap<Int64, Message>()
        for (m in messages) { msgMap[m.id] = m }
        for (m in messages) {
            if (m.replyToMsgId > 0 && msgMap.contains(m.replyToMsgId)) {
                let replyMsg = msgMap[m.replyToMsgId]
                // 按字符截断，不能按字节切（content[0..50]）：中文消息切在多字节字符中间会抛
                // "Invalid utf8 byte sequence"，整页历史解析失败（2026-09-15 你好群真机实锤）。
                m.replyToText = truncateRunes(replyMsg.content, 50)
                m.replyToSenderName = replyMsg.senderName
            }
        }

        return messages
    }

    // ==================== 消息类型判定 ====================

    /**
     * 确定消息类型
     * 
     * 优先级: service > mediaType > "text"
     */
    private func determineMessageType(tlMsg: TLMessage): String {
        if (tlMsg.isService) { return "service" }
        if (tlMsg.mediaType.size > 0) { return tlMsg.mediaType }
        return "text"
    }

    // ==================== 媒体解析分发器 ====================

    /**
     * 统一媒体解析分发器
     * 
     * 根据 TLMessage 中已解析的 mediaType 和元数据，将属性写入 Message 模型。
     * 各子解析器负责处理特定媒体类型的属性。
     * 
     * 当前支持:
     * - photo: 照片（photoId/accessHash/fileReference/dcId）
     * - video: 视频（文档元数据 + 时长/宽高）
     * - voice/audio: 音频/语音（文档元数据 + 时长/标题/演奏者）
     * - document: 通用文件（文档元数据 + 文件名/MIME）
     * 
     * 后续扩展 (由 Q2-Q11 添加):
     * - Q2: voice 波形数据提取 + VoicePlayer 集成
     * - Q3: sticker 贴纸集信息 + 渲染
     * - Q4: gif 动画 + 自动播放
     * - Q5: webpage 网页预览
     * - Q7: photo 增强（尺寸/质量选择）
     * - Q8: poll 增强（实时投票结果）
     */
    private func parseMessageMedia(tlMsg: TLMessage, msg: Message): Unit {
        // 照片媒体
        if (tlMsg.photoId != 0) {
            this.parsePhotoMedia(tlMsg, msg)
        }

        // 文档类媒体（视频/语音/音频/文件/GIF/贴纸）
        if (tlMsg.documentId != 0) {
            this.parseDocumentMedia(tlMsg, msg)
        }

        // Phase Q5: 网页预览
        if (tlMsg.webPageUrl.size > 0) {
            this.parseWebPageData(tlMsg, msg)
        }

        // Phase Q8: 投票数据
        if (tlMsg.pollId != 0) {
            this.parsePollData(tlMsg, msg)
        }

        // Phase P5-13: 位置消息
        if (tlMsg.locationLat != 0.0 || tlMsg.locationLng != 0.0) {
            msg.locationLat = tlMsg.locationLat
            msg.locationLng = tlMsg.locationLng
        }
        // Phase LOC-5: 实时位置标记 + 持续时间
        if (tlMsg.isLiveLocation) {
            msg.isLiveLocation = true
            msg.liveLocationPeriod = tlMsg.liveLocationPeriod
        }
        // P2-180: server heading (from messageMediaGeoLive flags.0 heading field)
        if (tlMsg.locationHeading >= 0) {
            msg.locationHeading = tlMsg.locationHeading
        }
        if (tlMsg.editDate > 0) { msg.editDate = Int64(tlMsg.editDate) }
        if (tlMsg.venueTitle.size > 0 || tlMsg.venueAddress.size > 0) {
            msg.venueTitle = tlMsg.venueTitle
            msg.venueAddress = tlMsg.venueAddress
            msg.venueProvider = tlMsg.venueProvider
            msg.venueId = tlMsg.venueId
            msg.venueType = tlMsg.venueType
        }
        if (tlMsg.mediaType == "invoice") {
            msg.invoiceTitle = tlMsg.invoiceTitle
            msg.invoiceDescription = tlMsg.invoiceDescription
            msg.invoiceCurrency = tlMsg.invoiceCurrency
            msg.invoiceTotalAmount = tlMsg.invoiceTotalAmount
            msg.invoiceStartParam = tlMsg.invoiceStartParam
            msg.invoiceReceiptMsgId = tlMsg.invoiceReceiptMsgId
            msg.invoicePaymentButtonTitle = tlMsg.invoicePaymentButtonTitle
        }
    }

    /**
     * Phase Q7: 解析照片媒体元数据（增强版）
     * 
     * 将 TLMessage 中的照片下载信息 + 尺寸 + stripped thumb 映射到 Message 模型。
     * - photoWidth/photoHeight: 最大 PhotoSize 的分辨率，用于 UI 布局比例计算
     * - photoFileSize: 最大 PhotoSize 的文件大小
     * - strippedThumb: photoStrippedSize 的 JPEG 模糊预览，先显示再加载高清图
     */
    private func parsePhotoMedia(tlMsg: TLMessage, msg: Message): Unit {
        msg.photoId = tlMsg.photoId
        msg.photoAccessHash = tlMsg.photoAccessHash
        msg.photoFileReference = tlMsg.photoFileReference
        msg.photoDcId = tlMsg.photoDcId
        msg.photoWidth = tlMsg.photoWidth
        msg.photoHeight = tlMsg.photoHeight
        msg.photoFileSize = tlMsg.photoFileSize
        msg.photoLargestType = tlMsg.photoLargestType
        msg.strippedThumb = tlMsg.strippedThumb
    }

    /**
     * 解析文档类媒体元数据（统一入口）
     * 
     * 所有以 Document 为载体的媒体类型都经过此方法：
     * video, voice, audio, document, sticker, gif
     * 
     * 基础文档元数据（所有子类型共享）写入后，
     * 根据 mediaType 分发到特定属性解析器。
     */
    private func parseDocumentMedia(tlMsg: TLMessage, msg: Message): Unit {
        // 基础文档元数据（所有文档类型共享）
        msg.documentId = tlMsg.documentId
        msg.documentAccessHash = tlMsg.documentAccessHash
        msg.documentFileReference = tlMsg.documentFileReference
        msg.documentDcId = tlMsg.documentDcId
        msg.documentSize = tlMsg.documentSize
        msg.documentMimeType = tlMsg.documentMimeType
        msg.documentFileName = tlMsg.documentFileName
        msg.strippedThumb = tlMsg.strippedThumb
        if (!tlMsg.strippedThumb.isEmpty()) {
            // Keep update parsing cheap: reconstruct the tiny JPEG only. Image
            // decode/texture upload happens in the presentation node, as on iOS.
            msg.documentThumbnailPath = decodeTinyThumbnailToDataUrl(tlMsg.strippedThumb)
        }

        // 根据媒体类型分发到子解析器
        let mediaType = tlMsg.mediaType
        if (mediaType == "video" || mediaType == "video_note") {
            this.parseVideoAttributes(tlMsg, msg)
        } else if (mediaType == "voice" || mediaType == "audio") {
            this.parseAudioAttributes(tlMsg, msg)
        } else if (mediaType == "sticker") {
            this.parseStickerAttributes(tlMsg, msg)
        } else if (mediaType == "gif") {
            this.parseGifAttributes(tlMsg, msg)
        }
    }

    /**
     * 解析视频属性
     */
    private func parseVideoAttributes(tlMsg: TLMessage, msg: Message): Unit {
        msg.videoDuration = tlMsg.videoDuration
        msg.videoWidth = tlMsg.videoWidth
        msg.videoHeight = tlMsg.videoHeight
    }

    /**
     * 解析音频/语音属性
     * 
     * Phase Q2: 完整解析
     * - 时长 (audioDuration)
     * - 标题/演奏者 (audioTitle/audioPerformer，仅 audio 类型)
     * - 波形数据 (audioWaveform，仅 voice 类型)
     * 
     * Telegram 的 waveform 是 5-bit 编码的压缩字节数组：
     * 每个采样点占 5 bits (0-31)，打包存储。
     * 例如 63 字节 → 100 个采样点。
     */
    private func parseAudioAttributes(tlMsg: TLMessage, msg: Message): Unit {
        msg.audioDuration = tlMsg.audioDuration
        msg.audioTitle = tlMsg.audioTitle
        msg.audioPerformer = tlMsg.audioPerformer
        msg.audioWaveform = tlMsg.audioWaveform
    }

    /**
     * Phase Q3: 解析贴纸属性
     * 
     * 捕获 alt emoji（来自 documentAttributeSticker.alt），
     * 用于在 MessageBubble 中作为 fallback 显示。
     * 贴纸文件本身（webp/tgs/webm）通过 documentId 下载。
     */
    private func parseStickerAttributes(tlMsg: TLMessage, msg: Message): Unit {
        msg.stickerAlt = tlMsg.stickerAlt
    }

    /**
     * Phase Q4: 解析 GIF 属性
     * 
     * Telegram GIF 实际是 mp4 视频 (documentAttributeAnimated + documentAttributeVideo)。
     * 复用视频的宽高属性以便 UI 进行正确的布局。
     */
    private func parseGifAttributes(tlMsg: TLMessage, msg: Message): Unit {
        msg.videoWidth = tlMsg.videoWidth
        msg.videoHeight = tlMsg.videoHeight
        msg.videoDuration = tlMsg.videoDuration
    }

    /**
     * Phase Q5: 解析网页预览数据
     * 
     * 将 TLMessage 中已解析的网页预览字段传递到 Message 模型，
     * 供 MessageBubble 的 webPreviewContent builder 渲染。
     */
    private func parseWebPageData(tlMsg: TLMessage, msg: Message): Unit {
        msg.webPageUrl = tlMsg.webPageUrl
        msg.webPageSiteName = tlMsg.webPageSiteName
        msg.webPageTitle = tlMsg.webPageTitle
        msg.webPageDescription = tlMsg.webPageDescription
        // P7B-1: 传递网页预览缩略图元数据
        msg.webPagePhotoId = tlMsg.webPagePhotoId
        msg.webPagePhotoAccessHash = tlMsg.webPagePhotoAccessHash
        msg.webPagePhotoFileReference = tlMsg.webPagePhotoFileReference
        msg.webPagePhotoDcId = tlMsg.webPagePhotoDcId
        msg.webPagePhotoWidth = tlMsg.webPagePhotoWidth
        msg.webPagePhotoHeight = tlMsg.webPagePhotoHeight
    }

    /**
     * Phase Q8: 解析投票数据
     * 
     * 将 TLMessage 中的投票选项、结果、总票数传递到 Message 模型。
     * 计算每个选项的百分比。
     */
    private func parsePollData(tlMsg: TLMessage, msg: Message): Unit {
        msg.pollId = tlMsg.pollId
        msg.pollQuestion = tlMsg.pollQuestion
        msg.pollClosed = tlMsg.pollClosed
        msg.pollQuiz = tlMsg.pollQuiz
        msg.pollMultipleChoice = tlMsg.pollMultipleChoice
        msg.pollTotalVoters = tlMsg.pollTotalVoters
        msg.pollSolution = tlMsg.pollSolution

        // 转换选项并计算百分比
        let totalVoters = tlMsg.pollTotalVoters
        for (tlOpt in tlMsg.pollOptions) {
            let opt = PollOptionData()
            opt.text = tlOpt.text
            opt.voters = tlOpt.voters
            opt.chosen = tlOpt.chosen
            opt.correct = tlOpt.correct
            opt.percentage = if (totalVoters > 0) { tlOpt.voters * 100 / totalVoters } else { 0 }
            opt.optionData = tlOpt.optionBytes
            msg.pollOptions.add(opt)
        }
    }

    // ==================== Phase Q11: 富文本实体解析 ====================

    /**
     * 将 TLTextEntity 列表转换为 TextEntityData 列表
     * 仅保留 UI 可渲染的类型：bold, italic, code, pre, textUrl, strike, underline,
     * mention, hashtag, url, email, spoiler, blockquote
     */
    private func parseTextEntities(tlMsg: TLMessage, msg: Message): Unit {
        if (tlMsg.textEntities.isEmpty()) { return }
        
        for (tlEntity in tlMsg.textEntities) {
            let entity = TextEntityData()
            entity.entityType = tlEntity.entityType
            entity.offset = tlEntity.offset
            entity.length = tlEntity.length
            entity.url = tlEntity.url
            entity.customEmojiDocumentId = tlEntity.documentId
            msg.textEntityList.add(entity)
        }
    }

    // ==================== Reactions 解析 ====================

    /**
     * 解析消息 Reactions 数据
     * 
     * 将 TLReactionCount 列表映射为 ReactionData 列表，
     * 并生成回复者首字母缩写（如 "HY" 代表 "Hao Yuan"）。
     */
    /**
     * iOS resolves ReactionsMessageAttribute.recentPeers through Postbox peers,
     * including the account peer. Keep the same invariant here: the selected
     * account is a real UserResponse, never a synthetic "Me" display peer.
     */
    private func prepareCurrentReactionPeer(currentUserId: Int64): Unit {
        if (currentUserId <= 0) { return }
        let photoService = getUserPhotoService()
        match (getRealAuthService().getCurrentUser()) {
            case Some(me) =>
                if (me.id == currentUserId) {
                    match (photoService.getCachedUser(currentUserId)) {
                        case Some(cached) =>
                            // Auth storage can restore a name-only user. Do not
                            // replace a richer dialogs/profile peer with it.
                            if (!cached.hasPhoto || me.hasPhoto) {
                                photoService.cacheUser(me)
                            }
                        case None => photoService.cacheUser(me)
                    }
                    photoService.requestFullPhotoDownload(currentUserId)
                }
            case None => ()
        }
    }

    private func resolveReactionPeerName(
        peerId: Int64,
        userNames: HashMap<Int64, String>,
        currentUserId: Int64
    ): String {
        if (userNames.contains(peerId)) {
            let mapped = userNames[peerId]
            if (mapped.size > 0 && mapped != "Me") { return mapped }
        }
        match (getUserPhotoService().getCachedUser(peerId)) {
            case Some(user) =>
                var name = user.firstName
                if (user.lastName.size > 0) { name = name + " " + user.lastName }
                if (name.size > 0) { return name }
            case None => ()
        }
        if (peerId == currentUserId) {
            match (getAuthStorage().getUserData()) {
                case Some(me) =>
                    var name = me.firstName
                    if (me.lastName.size > 0) { name = name + " " + me.lastName }
                    if (name.size > 0) { return name }
                case None => ()
            }
        }
        return ""
    }

    private func parseMessageReactionsData(
        tlMsg: TLMessage,
        msg: Message,
        userNames: HashMap<Int64, String>,
        currentUserId: Int64,
        conversationPeerType: String,
        conversationPeerId: Int64
    ): Unit {
        if (tlMsg.reactions.isEmpty()) { return }

        this.prepareCurrentReactionPeer(currentUserId)
        let reactionList = ArrayList<ReactionData>()
        for (tlReaction in tlMsg.reactions) {
            if (tlReaction.emoji.size > 0 || tlReaction.customEmojiDocumentId != 0) {
                // 生成回复者首字母缩写
                var initials = ""
                let peerIds = ArrayList<Int64>()
                let peerAvatarPaths = ArrayList<String>()
                let peerInitialsList = ArrayList<String>()
                for (peerId in tlReaction.recentPeerIds) {
                    peerIds.add(peerId)
                    peerAvatarPaths.add(getUserPhotoService().getUserPhotoPath(peerId))
                    let name = this.resolveReactionPeerName(peerId, userNames, currentUserId)
                    if (name.size > 0) {
                        let nameInitials = getNameInitials(name)
                        peerInitialsList.add(nameInitials)
                        if (nameInitials.size > 0) {
                            if (initials.size > 0) { initials = initials + "," }
                            initials = initials + nameInitials
                        }
                    } else {
                        peerInitialsList.add("?")
                    }
                }

                // Telegram-iOS supplements incomplete recent peers in direct chats:
                // the selected account peer is always known, and the chat peer is
                // known whenever it owns the reaction or the count includes both.
                if (conversationPeerType == "user") {
                    let inferredPeerIds = ArrayList<Int64>()
                    if (tlReaction.isChosen && currentUserId > 0) {
                        inferredPeerIds.add(currentUserId)
                    }
                    if ((!tlReaction.isChosen || tlReaction.count >= 2) && conversationPeerId > 0) {
                        inferredPeerIds.add(conversationPeerId)
                    }
                    for (peerId in inferredPeerIds) {
                        var alreadyPresent = false
                        for (existingId in peerIds) {
                            if (existingId == peerId) {
                                alreadyPresent = true
                                break
                            }
                        }
                        if (alreadyPresent) { continue }
                        peerIds.add(peerId)
                        peerAvatarPaths.add(getUserPhotoService().getUserPhotoPath(peerId))
                        let name = this.resolveReactionPeerName(peerId, userNames, currentUserId)
                        if (name.size > 0) {
                            let nameInitials = getNameInitials(name)
                            peerInitialsList.add(nameInitials)
                            if (nameInitials.size > 0) {
                                if (initials.size > 0) { initials = initials + "," }
                                initials = initials + nameInitials
                            }
                        } else {
                            peerInitialsList.add("?")
                        }
                    }
                }
                let rd = ReactionData(
                    emoji: tlReaction.emoji,
                    count: Int64(tlReaction.count),
                    isSelected: tlReaction.isChosen,
                    peerInitials: initials
                )
                rd.peerIds = peerIds
                rd.peerAvatarPaths = peerAvatarPaths
                rd.peerInitialsList = peerInitialsList
                rd.customEmojiDocumentId = tlReaction.customEmojiDocumentId
                reactionList.add(rd)
                getUserPhotoService().requestFullPhotosForUsers(peerIds)
            }
        }
        msg.reactions = reactionList
    }

    /**
     * Convert the reaction payload carried by updateMessageReactions without
     * reparsing or refetching the complete message. This is the same mapping
     * used by getHistory, including recent-peer avatars and direct-chat peer
     * inference.
     */
    public func convertReactionCounts(
        counts: ArrayList<TLReactionCount>,
        currentUserId: Int64,
        conversationPeerType: String,
        conversationPeerId: Int64,
        conversationPeerName: String
    ): ArrayList<ReactionData> {
        let tlMsg = TLMessage()
        tlMsg.reactions = counts
        let message = Message()
        let userNames = HashMap<Int64, String>()
        if (conversationPeerId > 0 && conversationPeerName.size > 0) {
            userNames[conversationPeerId] = conversationPeerName
        }
        if (currentUserId > 0) {
            match (getAuthStorage().getUserData()) {
                case Some(me) =>
                    var ownName = me.firstName
                    if (me.lastName.size > 0) { ownName = ownName + " " + me.lastName }
                    userNames[currentUserId] = ownName
                case None => ()
            }
        }
        this.parseMessageReactionsData(
            tlMsg,
            message,
            userNames,
            currentUserId,
            conversationPeerType,
            conversationPeerId
        )
        return message.reactions
    }

    // ==================== 获取消息历史 ====================

    public func getHistory(
        peerType: String,
        peerId: Int64,
        limit!: Int32 = 20,
        offsetId!: Int32 = 0,
        addOffset!: Int32 = 0
    ): MessagesHistoryResponse {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getHistory: peerType=${peerType}, peerId=${peerId}, limit=${limit}, offsetId=${offsetId}, addOffset=${addOffset}")
        let client = getMTProtoClient()

        let getHistory = MessagesGetHistory()
        getHistory.peer = buildInputPeer(peerType, peerId)
        getHistory.limit = limit
        getHistory.offsetId = offsetId
        getHistory.addOffset = addOffset

        let responseData = client.sendRequest(getHistory.toBytes())

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] getHistory: empty response")
            return MessagesHistoryResponse()
        }

        // 检查 RPC 错误
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealMessageService] getHistory RPC Error: ${errorCode} - ${errorMessage}")
                return MessagesHistoryResponse()
            }
        }

        let response = MessagesHistoryResponse.deserialize(responseData)
        Hilog.info(0, "CjTelegram", "[RealMessageService] getHistory parsed: ${response.messages.size} msgs, ${response.users.size} users")

        // 缓存 accessHash
        cacheFromResponse(response.users, response.chats)

        return response
    }

    // ==================== 本地优先消息历史（离线可读，P2-287f）====================

    /**
     * 本地优先读取消息历史（对照 iOS Postbox local-first：先读本地，缺口再网络回源回填）。
     *
     * 策略：
     *   1. 先查本地 MessageHistoryTable（offsetId>0 → earlierMessages 翻页；offsetId==0 →
     *      最近 limit 条）。本地命中且足量（size >= limit，或本地有数据且无需更多）即直接返回本地，
     *      不发网络 —— 这就是"离线可读"。
     *   2. 本地为空 / 不足 → 走原 getHistory 网络回源、parseMessages，得到 Array<Message> 后
     *      回填本地表（storeMessages，幂等覆盖），再返回网络结果。
     *
     * DB 不可用（拿不到 context / open 失败）时：MessageHistoryStore 安全降级——本地读返回空、
     * 回填 no-op，本方法等价于纯网络路径，绝不崩。
     *
     * 不改对外契约：本方法是新增入口；原 getHistory（纯网络）保持不变作为回退。
     *
     * @param peerType  对话类型（user / chat / channel）
     * @param peerId    对话 ID（同时作为本地表 (peerId, namespace) 键的 peerId 段）
     * @param limit     最多返回消息数
     * @param offsetId  分页锚点（0 = 最新）
     * @param currentUserId 当前用户 ID（网络回源 parse 时用）
     * @param photoPathCache 已下载照片路径缓存（网络回源 parse 时用）
     * @return 时间正序的 Message 列表
     */
    public func getHistoryLocalFirst(
        peerType: String,
        peerId: Int64,
        limit!: Int32 = 20,
        offsetId!: Int32 = 0,
        currentUserId!: Int64 = 0,
        photoPathCache!: HashMap<Int64, String> = HashMap<Int64, String>()
    ): ArrayList<Message> {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getHistoryLocalFirst: peerId=${peerId}, limit=${limit}, offsetId=${offsetId}")
        let store = getMessageHistoryStore()

        // Step 1: 本地优先
        let local = store.loadLocalMessages(peerId, limit, offsetId, peerType: peerType)
        if (Int32(local.size) >= limit) {
            // 本地命中且足量 → 离线可读，不发网络
            Hilog.info(0, "CjTelegram", "[RealMessageService] getHistoryLocalFirst: local hit ${local.size} (>=${limit}), skip network")
            return local
        }

        // Step 2: 本地为空 / 不足 → 网络回源
        let historyResponse = this.getHistory(peerType, peerId, limit: limit, offsetId: offsetId)
        if (historyResponse.messages.isEmpty()) {
            // 网络也空：返回本地已有的（可能 0 条），不回填
            Hilog.info(0, "CjTelegram", "[RealMessageService] getHistoryLocalFirst: network empty, returning ${local.size} local")
            return local
        }
        let parsed = this.parseMessages(historyResponse, currentUserId, photoPathCache)

        // Step 3: 回填本地（幂等覆盖），并把本页覆盖的 id 区间移出 hole
        store.storeHistoryFill(peerId, parsed, peerType: peerType, offsetId: offsetId,
            serverCount: historyResponse.reliableCount())

        Hilog.info(0, "CjTelegram", "[RealMessageService] getHistoryLocalFirst: network ${parsed.size}, backfilled local")
        return parsed
    }

    // ==================== 发送消息 ====================

    /**
     * Phase Q6: 发送文本消息，返回解析后的服务端响应
     * 
     * 返回 SendMessageResult 包含：
     * - success: 是否成功
     * - messageId: 服务端分配的真实消息 ID
     * - date: 服务端时间戳
     * - pts: 用于后续同步
     */
    public func sendMessage(
        peerType: String,
        peerId: Int64,
        message: String,
        silent!: Bool = false,
        scheduleDate!: Int32 = 0,
        effectId!: Int64 = 0
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendMessage: peerType=${peerType}, peerId=${peerId} silent=${silent} schedule=${scheduleDate} effect=${effectId}")
        let client = getMTProtoClient()

        let sendMsg = MessagesSendMessage()
        sendMsg.peer = buildInputPeer(peerType, peerId)
        sendMsg.message = message
        sendMsg.randomId = generateRandomId()
        sendMsg.silent = silent
        if (scheduleDate > 0) { sendMsg.scheduleDate = Some(scheduleDate) }
        if (effectId != 0) { sendMsg.effect = Some(effectId) }

        let responseData = client.sendRequest(sendMsg.toBytes())
        return parseSendMessageResponse(responseData, "sendMessage")
    }

    // ==================== S2-70: 定时消息 ====================

    /** messages.getScheduledHistory → messages.Messages（与 getHistory 同一解析器）。 */
    public func getScheduledHistory(peerType: String, peerId: Int64): MessagesHistoryResponse {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getScheduledHistory: peerType=${peerType}, peerId=${peerId}")
        let client = getMTProtoClient()
        let req = MessagesGetScheduledHistory()
        req.peer = buildInputPeer(peerType, peerId)
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return MessagesHistoryResponse() }
        let checkD = TLDeserializer(responseData)
        let checkConstructor = checkD.readUInt32()
        if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
            let errorCode = checkD.readInt32()
            let errorMessage = checkD.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] getScheduledHistory RPC Error: ${errorCode} - ${errorMessage}")
            return MessagesHistoryResponse()
        }
        let response = MessagesHistoryResponse.deserialize(responseData)
        Hilog.info(0, "CjTelegram", "[RealMessageService] getScheduledHistory parsed: ${response.messages.size} msgs")
        cacheFromResponse(response.users, response.chats)
        return response
    }

    /** messages.deleteScheduledMessages */
    public func deleteScheduledMessages(peerType: String, peerId: Int64, messageIds: ArrayList<Int32>): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] deleteScheduledMessages: ${messageIds.size} msgs")
        let client = getMTProtoClient()
        let req = MessagesDeleteScheduledMessages()
        req.peer = buildInputPeer(peerType, peerId)
        req.idList = messageIds
        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "deleteScheduledMessages")
    }

    /** messages.sendScheduledMessages（iOS ScheduledMessages_SendNow） */
    public func sendScheduledMessagesNow(peerType: String, peerId: Int64, messageIds: ArrayList<Int32>): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendScheduledMessagesNow: ${messageIds.size} msgs")
        let client = getMTProtoClient()
        let req = MessagesSendScheduledMessages()
        req.peer = buildInputPeer(peerType, peerId)
        req.idList = messageIds
        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "sendScheduledMessagesNow")
    }

    /**
     * P2-120: 带格式实体的消息发送
     *
     * 将 parseMarkdown 解析出的 TextEntityData 转换为 TL MessageEntity 序列化对象，
     * 通过 MessagesSendMessage.entities 字段传给服务端，使接收方能看到内联格式。
     *
     * 实体 offset/length 单位：工程已统一到 Rune（码点）口径，ASCII 文本下与 Telegram TL
     * 要求的 UTF-16 code unit 口径等价（ASCII 字符 rune=UTF-16=1）。
     */
    public func sendMessageWithEntities(
        peerType: String,
        peerId: Int64,
        message: String,
        entities: ArrayList<TLObject>,
        silent!: Bool = false,
        scheduleDate!: Int32 = 0,
        effectId!: Int64 = 0
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendMessageWithEntities: peerId=${peerId} entities=${entities.size} silent=${silent} schedule=${scheduleDate}")
        let client = getMTProtoClient()

        let sendMsg = MessagesSendMessage()
        sendMsg.peer = buildInputPeer(peerType, peerId)
        sendMsg.message = message
        sendMsg.randomId = generateRandomId()
        if (entities.size > 0) {
            sendMsg.entities = Some(entities)
        }
        sendMsg.silent = silent
        if (scheduleDate > 0) { sendMsg.scheduleDate = Some(scheduleDate) }
        if (effectId != 0) { sendMsg.effect = Some(effectId) }

        let responseData = client.sendRequest(sendMsg.toBytes())
        return parseSendMessageResponse(responseData, "sendMessageWithEntities")
    }

    /**
     * Phase Q6: 发送带回复的消息，返回解析后的服务端响应
     */
    public func sendMessageWithReply(
        peerType: String,
        peerId: Int64,
        message: String,
        replyToMsgId: Int32,
        quoteText!: String = "",
        quoteOffset!: Int32 = 0,
        silent!: Bool = false,
        scheduleDate!: Int32 = 0,
        effectId!: Int64 = 0,
        entities!: ArrayList<TLObject> = ArrayList<TLObject>()
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendMessageWithReply: peerId=${peerId}, replyTo=${replyToMsgId}, quote='${quoteText}' silent=${silent} schedule=${scheduleDate} entities=${entities.size}")
        let client = getMTProtoClient()

        let sendMsg = MessagesSendMessageWithReply()
        sendMsg.peer = buildInputPeer(peerType, peerId)
        sendMsg.message = message
        sendMsg.randomId = generateRandomId()
        sendMsg.replyToMsgId = replyToMsgId
        // P2-115: quote reply fields for inputReplyToMessage
        sendMsg.quoteText = quoteText
        sendMsg.quoteOffset = quoteOffset
        sendMsg.silent = silent
        sendMsg.scheduleDate = scheduleDate
        sendMsg.effectId = effectId
        if (entities.size > 0) { sendMsg.entities = Some(entities) }

        let responseData = client.sendRequest(sendMsg.toBytes())
        return parseSendMessageResponse(responseData, "sendMessageWithReply")
    }

    // ==================== Phase A3: 删除消息 ====================

    public func deleteMessages(
        peerType: String,
        peerId: Int64,
        messageIds: ArrayList<Int32>,
        revoke!: Bool = true
    ): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] deleteMessages: ${messageIds.size} msgs, revoke=${revoke}")
        let client = getMTProtoClient()

        if (normalizeDialogPeerType(peerType) == "channel") {
            // 频道使用 channels.deleteMessages
            let req = ChannelsDeleteMessages()
            req.channel = buildInputPeer(peerType, peerId)
            req.idList = messageIds
            let responseData = client.sendRequest(req.toBytes())
            return checkSendResponse(responseData, "channelsDeleteMessages")
        } else {
            // 普通聊天使用 messages.deleteMessages
            let req = MessagesDeleteMessages()
            req.revoke = revoke
            req.idList = messageIds
            let responseData = client.sendRequest(req.toBytes())
            return checkSendResponse(responseData, "deleteMessages")
        }
    }

    // ==================== Phase A3: 编辑消息 ====================

    public func editMessage(
        peerType: String,
        peerId: Int64,
        messageId: Int32,
        newText: String
    ): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] editMessage: msgId=${messageId}")
        let client = getMTProtoClient()

        let req = MessagesEditMessage()
        req.peer = buildInputPeer(peerType, peerId)
        req.id = messageId
        req.message = newText

        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "editMessage")
    }

    // ==================== Phase Q10: 消息置顶 ====================

    /**
     * 置顶一条消息
     * 
     * @param peerType 对话类型
     * @param peerId 对话 ID
     * @param messageId 要置顶的消息 ID
     * @param silent 是否静默（不通知群成员），默认 true
     * @return 是否成功
     */
    public func pinMessage(
        peerType: String,
        peerId: Int64,
        messageId: Int32,
        silent!: Bool = true
    ): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] pinMessage: msgId=${messageId}")
        let client = getMTProtoClient()
        
        let req = MessagesUpdatePinnedMessage()
        req.peer = buildInputPeer(peerType, peerId)
        req.id = messageId
        req.unpin = false
        req.silent = silent
        
        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "pinMessage")
    }

    /**
     * 取消置顶一条消息
     */
    public func unpinMessage(
        peerType: String,
        peerId: Int64,
        messageId: Int32
    ): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] unpinMessage: msgId=${messageId}")
        let client = getMTProtoClient()
        
        let req = MessagesUpdatePinnedMessage()
        req.peer = buildInputPeer(peerType, peerId)
        req.id = messageId
        req.unpin = true
        
        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "unpinMessage")
    }

    // ==================== Phase A3: 转发消息 ====================

    public func forwardMessages(
        fromPeerType: String,
        fromPeerId: Int64,
        toPeerType: String,
        toPeerId: Int64,
        messageIds: ArrayList<Int32>,
        dropAuthor!: Bool = false,
        dropMediaCaptions!: Bool = false
    ): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] forwardMessages: ${messageIds.size} msgs from ${fromPeerId} to ${toPeerId} dropAuthor=${dropAuthor} dropCaptions=${dropMediaCaptions}")
        let client = getMTProtoClient()

        let req = MessagesForwardMessages()
        // iOS PendingMessageManager.swift forwards with apiInputPeer(peer) for both sides.
        // The account peer goes as inputPeerSelf (no access hash needed); dialog peer types
        // arrive in UI spellings ("supergroup" / "group"), so normalize before building.
        req.fromPeer = this.buildForwardInputPeer(fromPeerType, fromPeerId)
        req.toPeer = this.buildForwardInputPeer(toPeerType, toPeerId)
        req.idList = messageIds
        // P2-115: drop_author (bit11) / drop_media_captions (bit12)
        // iOS PendingMessageManager.swift:1280,1284 — flags |= (1<<11) / (1<<12)
        req.dropAuthor = dropAuthor
        req.dropMediaCaptions = dropMediaCaptions
        // 为每条转发消息生成随机 ID
        let rids = ArrayList<Int64>()
        for (_id in messageIds) {
            rids.add(generateRandomId())
        }
        req.randomIds = rids

        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "forwardMessages")
    }

    private func buildForwardInputPeer(peerType: String, peerId: Int64): TLObject {
        let normalized = normalizeDialogPeerType(peerType)
        if (normalized == "user" && peerId != 0 && peerId == getCurrentUserId()) {
            return InputPeerSelf()
        }
        if (normalized == "channel" && !this.channelAccessHashes.contains(peerId)) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] forwardMessages: no access hash cached for channel ${peerId}")
        }
        return buildInputPeer(normalized, peerId)
    }

    // ==================== Phase A3: 搜索消息 ====================

    public func searchMessages(
        peerType: String,
        peerId: Int64,
        query: String,
        limit!: Int32 = 20,
        offsetId!: Int32 = 0
    ): MessagesHistoryResponse {
        Hilog.info(0, "CjTelegram", "[RealMessageService] searchMessages: q='${query}', peerId=${peerId}")
        let client = getMTProtoClient()

        let req = MessagesSearch()
        req.peer = buildInputPeer(peerType, peerId)
        req.q = query
        req.limit = limit
        req.offsetId = offsetId

        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            return MessagesHistoryResponse()
        }

        // 检查 RPC 错误
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealMessageService] searchMessages RPC Error: ${errorCode} - ${errorMessage}")
                return MessagesHistoryResponse()
            }
        }

        // 搜索结果格式与 getHistory 相同
        let response = MessagesHistoryResponse.deserialize(responseData)
        cacheFromResponse(response.users, response.chats)
        return response
    }

    /**
     * Phase S9: 搜索消息（带媒体类型过滤器）
     */
    public func searchMessages(
        peerType: String,
        peerId: Int64,
        query: String,
        filterObject: TLObject,
        limit: Int32
    ): MessagesHistoryResponse {
        Hilog.info(0, "CjTelegram", "[RealMessageService] searchMessages(filtered): limit=${limit}")
        let client = getMTProtoClient()

        let req = MessagesSearch()
        req.peer = buildInputPeer(peerType, peerId)
        req.q = query
        req.filter = filterObject
        req.limit = limit

        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            return MessagesHistoryResponse()
        }

        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealMessageService] searchMessages(filtered) RPC Error: ${errorCode} - ${errorMessage}")
                return MessagesHistoryResponse()
            }
        }

        let response = MessagesHistoryResponse.deserialize(responseData)
        cacheFromResponse(response.users, response.chats)
        return response
    }

    // ==================== 标记已读 ====================

    public func markAsRead(peerType: String, peerId: Int64, maxId: Int32) {
        let client = getMTProtoClient()
        try {
            if (normalizeDialogPeerType(peerType) == "channel") {
                // iOS _internal_applyMaxReadIndexInteractively dispatches channel peers to
                // channels.readHistory. messages.readHistory(InputPeerChannel) does not
                // advance a megagroup/channel inbox and caused the Chats badge to return
                // on the next authoritative dialogs refresh.
                let readHistory = ChannelsReadHistory()
                let channel = InputChannel()
                channel.channelId = peerId
                channel.accessHash = this.getAccessHashForChannel(peerId)
                readHistory.channel = channel
                readHistory.maxId = maxId
                let _ = client.sendRequest(readHistory.toBytes())
            } else {
                let readHistory = MessagesReadHistory()
                readHistory.peer = buildInputPeer(peerType, peerId)
                readHistory.maxId = maxId
                let _ = client.sendRequest(readHistory.toBytes())
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] markAsRead failed: ${e}")
        }
    }

    // ==================== Phase H6: Reactions ====================

    /**
     * 发送消息反应（点赞/爱心等）
     * 
     * 使用 messages.sendReaction TL 方法，emoji 非空时添加反应，为空时移除。
     * 返回 Updates，不需要特殊解析。
     */
    public func sendReaction(peerType: String, peerId: Int64, msgId: Int32, emoji: String): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendReaction: peer=${peerType}/${peerId}, msgId=${msgId}, emoji=${emoji}")
        let client = getMTProtoClient()

        let req = MessagesSendReaction()
        req.peer = buildInputPeer(peerType, peerId)
        req.msgId = msgId
        req.emoji = emoji

        try {
            let responseData = client.sendRequest(req.toBytes())
            return checkSendResponse(responseData, "sendReaction")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] sendReaction exception: ${e}")
            return false
        }
    }

    /**
     * 发送 custom-emoji 消息反应（P2-375）
     *
     * 使用 messages.sendReaction 带 reactionCustomEmoji#8935fc73 document_id:long。
     * iOS ref: Api22.swift case .reactionCustomEmoji => buffer.appendInt32(-1992950669)
     * ctor python: -1992950669 & 0xFFFFFFFF = 0x8935fc73 (verified)
     *
     * @param peerType 对话类型 (user/chat/channel)
     * @param peerId   对话 ID
     * @param msgId    目标消息 ID
     * @param documentId custom emoji 的 document_id（来自 reactionCustomEmoji TL）
     * @return 是否成功
     */
    public func sendCustomEmojiReaction(peerType: String, peerId: Int64, msgId: Int32, documentId: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendCustomEmojiReaction: peer=${peerType}/${peerId} msgId=${msgId} docId=${documentId}")
        let client = getMTProtoClient()
        let req = MessagesSendReaction()
        req.peer = buildInputPeer(peerType, peerId)
        req.msgId = msgId
        req.customEmojiDocumentId = documentId

        try {
            let responseData = client.sendRequest(req.toBytes())
            return checkSendResponse(responseData, "sendCustomEmojiReaction")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] sendCustomEmojiReaction exception: ${e}")
            return false
        }
    }

    /**
     * 移除消息反应
     *
     * 发送空 emoji = 移除所有当前用户的反应
     */
    public func removeReaction(peerType: String, peerId: Int64, msgId: Int32): Bool {
        return sendReaction(peerType, peerId, msgId, "")
    }

    /**
     * 获取消息反应者列表 (P2-116)
     *
     * 调用 messages.getMessageReactionsList 返回对该消息 react 过的用户列表。
     * 解析 messages.messageReactionsList#31bd492d:
     *   flags count reactions:Vector<MessagePeerReaction> chats users [next_offset]
     *
     * messagePeerReaction#8c79b63c:
     *   flags big? unread? my? peer_id:Peer date:int reaction:Reaction
     *
     * Peer 的解析：
     *   peerUser#59511722    user_id:long
     *   peerChat#36c6019a    chat_id:long
     *   peerChannel#a2a5371e channel_id:long
     *
     * reactionEmoji#1b2286b8 emoticon:string
     *
     * user#8f97e185 in the users vector (simplified — only id + first_name + last_name)
     *
     * @return 反应者列表（含 userId/displayName/emoji/isMy）
     */
    public func getReactorsList(peerType: String, peerId: Int64, msgId: Int32): ArrayList<ReactorInfo> {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getReactorsList: peer=${peerType}/${peerId}, msgId=${msgId}")
        let result = ArrayList<ReactorInfo>()
        let client = getMTProtoClient()
        let req = MessagesGetMessageReactionsList()
        req.peer = buildInputPeer(peerType, peerId)
        req.msgId = msgId
        req.limit = 50

        try {
            let data = client.sendRequest(req.toBytes())
            this.parseReactionsListResponse(data, result)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] getReactorsList exception: ${e}")
        }
        return result
    }

    /**
     * 解析 messages.messageReactionsList#31bd492d 响应
     *
     * Wire layout (big-endian 4-byte little-endian int32):
     *   ctor(4) flags(4) count(4)
     *   reactions Vector: 0x1cb5c415(4) + count(4) + N * messagePeerReaction
     *   chats Vector: 0x1cb5c415(4) + count(4) + (skipped)
     *   users Vector: 0x1cb5c415(4) + count(4) + N * user
     *   [next_offset string if flags.0]
     *
     * messagePeerReaction#8c79b63c:
     *   flags(4) peer_id:Peer date(4) reaction:Reaction
     *
     * peerUser#59511722 user_id:long(8)
     * peerChat#36c6019a chat_id:long(8)
     * peerChannel#a2a5371e channel_id:long(8)
     *
     * reactionEmoji#1b2286b8 emoticon:TL-string
     * reactionEmpty#79f5d419 (no data)
     */
    private func parseReactionsListResponse(data: Array<Byte>, result: ArrayList<ReactorInfo>): Unit {
        if (data.size < 16) { return }

        // helper: read little-endian Int32 at offset i
        // helper: read little-endian UInt32 at offset i (for ctor comparisons)

        var i: Int64 = 0

        // ctor (4)
        let responseCtor = readUInt32LE(data, i)
        i = i + 4
        // 0x31bd492d = messages.messageReactionsList
        if (responseCtor != 0x31bd492d) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] parseReactionsList: unexpected ctor=0x${responseCtor}, skip")
            return
        }

        // flags (4)
        let respFlags = readInt32LE(data, i)
        i = i + 4
        // count (4)
        let totalCount = readInt32LE(data, i)
        i = i + 4
        Hilog.info(0, "CjTelegram", "[RealMessageService] parseReactionsList: totalCount=${totalCount}")

        // reactions: Vector<MessagePeerReaction>
        if (i + 8 > Int64(data.size)) { return }
        let vecCtor = readUInt32LE(data, i)
        i = i + 4
        if (vecCtor != 0x1cb5c415) { return }
        let reactionCount = readInt32LE(data, i)
        i = i + 4

        // Accumulate peer reactions (userId→emoji, isMy)
        let peerReactions = ArrayList<ReactorInfo>()
        var rc: Int32 = 0
        while (rc < reactionCount && i < Int64(data.size)) {
            // messagePeerReaction#8c79b63c
            if (i + 4 > Int64(data.size)) { break }
            let peerReactCtor = readUInt32LE(data, i)
            i = i + 4
            if (peerReactCtor != 0x8c79b63c) {
                Hilog.info(0, "CjTelegram", "[RealMessageService] parseReactionsList: unexpected peerReaction ctor, abort")
                return
            }
            // flags (4)
            if (i + 4 > Int64(data.size)) { break }
            let prFlags = readInt32LE(data, i)
            i = i + 4
            let isMy = (prFlags & 4) != 0

            // peer_id: Peer (boxed)
            if (i + 4 > Int64(data.size)) { break }
            let peerCtor = readUInt32LE(data, i)
            i = i + 4
            var userId: Int64 = 0
            if (peerCtor == 0x59511722) {
                // peerUser#59511722 (iOS Api0.swift dict[1498486562]): user_id:long(8)
                if (i + 8 > Int64(data.size)) { break }
                userId = readInt64LE(data, i)
                i = i + 8
            } else if (peerCtor == 0x36c6019a || peerCtor == 0xa2a5371e) {
                // peerChat#36c6019a / peerChannel#a2a5371e (iOS dict[-1566230754]): id:long(8)
                if (i + 8 > Int64(data.size)) { break }
                userId = readInt64LE(data, i)
                i = i + 8
            } else {
                Hilog.info(0, "CjTelegram", "[RealMessageService] parseReactionsList: unknown peer ctor=0x${peerCtor}")
                return
            }

            // date: int(4)
            if (i + 4 > Int64(data.size)) { break }
            i = i + 4

            // reaction: Reaction (boxed)
            if (i + 4 > Int64(data.size)) { break }
            let reactCtor = readUInt32LE(data, i)
            i = i + 4
            var emoji = ""
            if (reactCtor == 0x1b2286b8) {
                // reactionEmoji: emoticon:string
                let strResult = readTLString(data, i)
                emoji = strResult.value
                i = strResult.nextOffset
            } else if (reactCtor == 0x79f5d419) {
                // reactionEmpty — no data
                emoji = ""
            } else {
                // unknown — skip; can't determine byte size, abort further parsing
                Hilog.info(0, "CjTelegram", "[RealMessageService] parseReactionsList: unknown reaction ctor=0x${reactCtor}, abort")
                return
            }

            let info = ReactorInfo()
            info.userId = userId
            info.emoji = emoji
            info.isMy = isMy
            peerReactions.add(info)
            rc = rc + 1
        }

        // chats vector: skip (we don't need chat names for now)
        // users vector: parse to get displayName
        // Find users vector start — scan past chats
        if (i + 8 > Int64(data.size)) {
            // Can't find users, return peerReactions with userId only
            for (pr in peerReactions) { result.add(pr) }
            return
        }
        let chatVecCtor = readUInt32LE(data, i)
        i = i + 4
        if (chatVecCtor == 0x1cb5c415) {
            let chatCount = readInt32LE(data, i)
            i = i + 4
            // Skip chat objects — complex to skip; use a heuristic: if chatCount==0, continue to users
            if (chatCount != 0) {
                // Can't skip chats reliably in this simple parser; just return with userId
                for (pr in peerReactions) { result.add(pr) }
                return
            }
        }

        // users vector
        if (i + 8 > Int64(data.size)) {
            for (pr in peerReactions) { result.add(pr) }
            return
        }
        let userVecCtor = readUInt32LE(data, i)
        i = i + 4
        if (userVecCtor != 0x1cb5c415) {
            for (pr in peerReactions) { result.add(pr) }
            return
        }
        let userCount = readInt32LE(data, i)
        i = i + 4

        // Build userId → displayName map from users vector
        let nameMap = HashMap<Int64, String>()
        var uc: Int32 = 0
        while (uc < userCount && i < Int64(data.size)) {
            // user ctor (4)
            if (i + 4 > Int64(data.size)) { break }
            let userCtor = readUInt32LE(data, i)
            i = i + 4
            // 0x31774388 = user (iOS Api0.swift dict[829899656], Api30.swift appendInt32(829899656))
            // We only handle this ctor; others (userEmpty 0xd3bc4b7a) have just id
            if (userCtor == 0xd3bc4b7a) {
                // userEmpty: id:long(8)
                if (i + 8 > Int64(data.size)) { break }
                i = i + 8
                uc = uc + 1
                continue
            }
            if (userCtor != 0x31774388) {
                // Unknown user ctor — stop parsing users
                break
            }
            // user#31774388: flags:# flags2:# id:long [access_hash] [first_name] [last_name] ...
            // iOS parse_user: _1=flags _2=flags2 _3=id:Int64 (Api30.swift:901-907)
            if (i + 4 > Int64(data.size)) { break }
            let uFlags = readInt32LE(data, i)
            i = i + 4
            // flags2 (4) — must be read before id per iOS wire order (Api30.swift:904-905)
            if (i + 4 > Int64(data.size)) { break }
            let uFlags2 = readInt32LE(data, i)
            let _ = uFlags2
            i = i + 4
            // id: long(8)
            if (i + 8 > Int64(data.size)) { break }
            let uid = readInt64LE(data, i)
            i = i + 8
            // access_hash: flags.0?long
            if ((uFlags & 1) != 0) {
                if (i + 8 > Int64(data.size)) { break }
                i = i + 8
            }
            // first_name: flags.1?string
            var firstName = ""
            if ((uFlags & 2) != 0) {
                if (i >= Int64(data.size)) { break }
                let sr = readTLString(data, i)
                firstName = sr.value
                i = sr.nextOffset
            }
            // last_name: flags.2?string
            var lastName = ""
            if ((uFlags & 4) != 0) {
                if (i >= Int64(data.size)) { break }
                let sr = readTLString(data, i)
                lastName = sr.value
                i = sr.nextOffset
            }
            var displayName = firstName
            if (lastName.size > 0) { displayName = displayName + " " + lastName }
            if (displayName.size == 0) { displayName = "User ${uid}" }
            nameMap[uid] = displayName
            // Stop parsing further user fields — we have what we need
            // (remaining optional fields: username, phone, photo, status, etc.)
            // Since we can't skip unknown optional fields reliably, limit parsing here
            // and break after first few users to avoid misparsing
            uc = uc + 1
            break
        }

        // Merge names into peerReactions
        for (pr in peerReactions) {
            match (nameMap.get(pr.userId)) {
                case Some(name) => pr.displayName = name
                case None => pr.displayName = if (pr.userId > 0) { "User ${pr.userId}" } else { "Unknown" }
            }
            result.add(pr)
        }

        Hilog.info(0, "CjTelegram", "[RealMessageService] parseReactionsList: parsed ${result.size} reactors")
        let _ = respFlags  // suppress unused warning
        let _ = totalCount
    }

    // ==================== TL Binary Helpers ====================

    private func readInt32LE(data: Array<Byte>, offset: Int64): Int32 {
        if (offset + 4 > Int64(data.size)) { return 0 }
        let b0 = Int32(data[offset])
        let b1 = Int32(data[offset + 1])
        let b2 = Int32(data[offset + 2])
        let b3 = Int32(data[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private func readUInt32LE(data: Array<Byte>, offset: Int64): UInt32 {
        if (offset + 4 > Int64(data.size)) { return 0 }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private func readInt64LE(data: Array<Byte>, offset: Int64): Int64 {
        if (offset + 8 > Int64(data.size)) { return 0 }
        let lo = Int64(readUInt32LE(data, offset))
        let hi = Int64(readUInt32LE(data, offset + 4))
        return lo | (hi << 32)
    }

    /**
     * TL string parser — returns (string_value, next_offset_after_string)
     * TL string encoding: if first_byte <= 253: len=first_byte, then len bytes, padded to 4-byte boundary
     */
    private func readTLString(data: Array<Byte>, offset: Int64): TLStringResult {
        let result = TLStringResult()
        if (offset >= Int64(data.size)) { return result }
        let firstByte = Int64(data[offset])
        if (firstByte <= 253) {
            let strLen = firstByte
            let dataStart = offset + 1
            if (dataStart + strLen > Int64(data.size)) {
                result.nextOffset = Int64(data.size)
                return result
            }
            var strBytes = Array<Byte>(strLen, repeat: 0)
            var si: Int64 = 0
            while (si < strLen) {
                strBytes[si] = data[dataStart + si]
                si = si + 1
            }
            result.value = String.fromUtf8(strBytes)
            let totalUsed = 1 + strLen
            let pad = (4 - (totalUsed % 4)) % 4
            result.nextOffset = dataStart + strLen + pad
        } else {
            // 3-byte length (firstByte == 254)
            if (offset + 4 > Int64(data.size)) {
                result.nextOffset = Int64(data.size)
                return result
            }
            let strLen = Int64(data[offset + 1]) | (Int64(data[offset + 2]) << 8) | (Int64(data[offset + 3]) << 16)
            let dataStart = offset + 4
            if (dataStart + strLen > Int64(data.size)) {
                result.nextOffset = Int64(data.size)
                return result
            }
            var strBytes = Array<Byte>(strLen, repeat: 0)
            var si: Int64 = 0
            while (si < strLen) {
                strBytes[si] = data[dataStart + si]
                si = si + 1
            }
            result.value = String.fromUtf8(strBytes)
            let totalUsed = 4 + strLen
            let pad = (4 - (totalUsed % 4)) % 4
            result.nextOffset = dataStart + strLen + pad
        }
        return result
    }

    // ==================== Phase H1: 发送媒体消息 ====================

    /**
     * 发送照片消息
     * 
     * 流程：上传文件 → 构建 InputMediaUploadedPhoto → messages.sendMedia
     * 参照 TelegramHarmony RealMessageService.ets: sendMediaWithUpload()
     * 
     * @param peerType 对话类型 (user/chat/channel)
     * @param peerId 对话 ID
     * @param photoData 照片二进制数据
     * @param fileName 文件名
     * @param caption 照片说明文字（可选）
     * @param replyToMsgId 回复消息 ID（可选）
     * @return 是否发送成功
     */
    /**
     * Phase Q6: 发送照片消息，返回 SendMessageResult
     */
    public func sendPhoto(
        peerType: String,
        peerId: Int64,
        photoData: Array<Byte>,
        fileName: String,
        caption!: String = "",
        replyToMsgId!: Int32 = 0
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendPhoto: peer=${peerType}/${peerId}, file=${fileName}, size=${photoData.size}")
        
        // Step 1: 上传文件
        let uploadService = getFileUploadService()
        let inputFileOpt = uploadService.uploadFile(photoData, fileName)
        
        let inputFile = match (inputFileOpt) {
            case Some(f) => f
            case None =>
                Hilog.info(0, "CjTelegram", "[RealMessageService] sendPhoto: upload failed")
                let failResult = SendMessageResult()
                failResult.errorMessage = "Upload failed"
                return failResult
        }
        
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendPhoto: upload complete, sending media...")
        
        // Step 2: 构建 InputMediaUploadedPhoto
        let media = InputMediaUploadedPhoto()
        media.file = inputFile
        
        // Step 3: 发送 messages.sendMedia
        let client = getMTProtoClient()
        let req = MessagesSendMedia()
        req.peer = buildInputPeer(peerType, peerId)
        req.media = media
        req.message = caption
        req.randomId = generateRandomId()
        req.replyToMsgId = replyToMsgId
        
        let responseData = client.sendRequest(req.toBytes())
        return parseSendMediaResponse(responseData, "sendPhoto")
    }

    /**
     * 发送文档/文件消息
     * 
     * @param peerType 对话类型
     * @param peerId 对话 ID
     * @param fileData 文件二进制数据
     * @param fileName 文件名
     * @param mimeType MIME 类型
     * @param caption 说明文字（可选）
     * @param replyToMsgId 回复消息 ID（可选）
     */
    /**
     * Phase Q6: 发送文档/文件消息，返回 SendMessageResult
     */
    public func sendDocument(
        peerType: String,
        peerId: Int64,
        fileData: Array<Byte>,
        fileName: String,
        mimeType!: String = "application/octet-stream",
        caption!: String = "",
        replyToMsgId!: Int32 = 0,
        uploadTag!: Int64 = 0
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendDocument: peer=${peerType}/${peerId}, file=${fileName}, mime=${mimeType} tag=${uploadTag}")
        
        // Step 1: 上传文件
        let uploadService = getFileUploadService()
        let inputFileOpt = uploadService.uploadFile(fileData, fileName, largeHint: true, uploadTag: uploadTag)
        
        let inputFile = match (inputFileOpt) {
            case Some(f) => f
            case None =>
                Hilog.info(0, "CjTelegram", "[RealMessageService] sendDocument: upload failed or cancelled")
                let failResult = SendMessageResult()
                failResult.errorMessage = "Upload failed"
                return failResult
        }
        
        // Step 2: 构建 InputMediaUploadedDocument
        let media = InputMediaUploadedDocument()
        media.file = inputFile
        media.mimeType = mimeType
        // 添加文件名属性
        let fileNameAttr = DocumentAttributeFilenameTL()
        fileNameAttr.fileName = fileName
        media.attributes.add(fileNameAttr)
        // 音频文件必须携带非 voice 的 documentAttributeAudio；否则 Telegram 服务端
        // 会把它作为普通 document 回传，各端都不会进入音乐/音频气泡。
        if (mimeType.startsWith("audio/")) {
            let audioAttr = DocumentAttributeAudioTL()
            audioAttr.voice = false
            audioAttr.duration = 0
            media.attributes.add(audioAttr)
        }
        
        // Step 3: 发送
        let client = getMTProtoClient()
        let req = MessagesSendMedia()
        req.peer = buildInputPeer(peerType, peerId)
        req.media = media
        req.message = caption
        req.randomId = generateRandomId()
        req.replyToMsgId = replyToMsgId
        
        let responseData = client.sendRequest(req.toBytes())
        return parseSendMediaResponse(responseData, "sendDocument")
    }

    /**
     * 发送语音消息
     * 
     * 流程: 上传文件 → InputMediaUploadedDocument (audio/ogg)
     *       + DocumentAttributeAudioTL(voice=true, duration) + DocumentAttributeFilename
     *       → messages.sendMedia
     * 
     * 与 sendDocument 的区别: 带 documentAttributeAudio 且 voice=true，
     * 服务器会将其标记为语音消息，所有客户端都能正确识别和播放。
     */
    public func sendVoice(
        peerType: String,
        peerId: Int64,
        fileData: Array<Byte>,
        fileName: String,
        mimeType!: String = "audio/wav",
        duration!: Int32 = 0,
        waveform!: Array<Byte> = Array<Byte>(0, repeat: 0),
        replyToMsgId!: Int32 = 0
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendVoice: peer=${peerType}/${peerId}, file=${fileName}, duration=${duration}s")
        
        let uploadService = getFileUploadService()
        let inputFileOpt = uploadService.uploadFile(fileData, fileName)
        
        let inputFile = match (inputFileOpt) {
            case Some(f) => f
            case None =>
                Hilog.info(0, "CjTelegram", "[RealMessageService] sendVoice: upload failed")
                let failResult = SendMessageResult()
                failResult.errorMessage = "Upload failed"
                return failResult
        }
        
        let media = InputMediaUploadedDocument()
        media.file = inputFile
        media.mimeType = mimeType
        
        let audioAttr = DocumentAttributeAudioTL()
        audioAttr.voice = true
        audioAttr.duration = duration
        audioAttr.waveform = waveform
        media.attributes.add(audioAttr)
        
        // iOS 语音只带 .Audio(isVoice) 属性，不带文件名；服务端也只把 audio/ogg 当语音，
        // 其它 mime 会被降级成普通音频文件（对端显示 voice_4s.wav）。
        if (mimeType != "audio/ogg") {
            let fileNameAttr = DocumentAttributeFilenameTL()
            fileNameAttr.fileName = fileName
            media.attributes.add(fileNameAttr)
        }
        
        let client = getMTProtoClient()
        let req = MessagesSendMedia()
        req.peer = buildInputPeer(peerType, peerId)
        req.media = media
        req.message = ""
        req.randomId = generateRandomId()
        req.replyToMsgId = replyToMsgId
        
        let responseData = client.sendRequest(req.toBytes())
        return parseSendMediaResponse(responseData, "sendVoice")
    }

    /**
     * Phase P6-1: 发送视频消息，返回 SendMessageResult
     * 
     * 流程: 上传文件 → InputMediaUploadedDocument (video/mp4) 
     *       + DocumentAttributeVideo + DocumentAttributeFilename
     *       → messages.sendMedia
     */
    public func sendVideo(
        peerType: String,
        peerId: Int64,
        videoData: Array<Byte>,
        fileName: String,
        mimeType!: String = "video/mp4",
        duration!: Float64 = 0.0,
        width!: Int32 = 0,
        height!: Int32 = 0,
        caption!: String = "",
        replyToMsgId!: Int32 = 0,
        thumbData!: Array<Byte> = Array<Byte>(0, repeat: 0)
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendVideo: peer=${peerType}/${peerId}, file=${fileName}, ${duration}s ${width}x${height}")
        
        // Step 1: 上传文件
        let uploadService = getFileUploadService()
        let inputFileOpt = uploadService.uploadFile(videoData, fileName, largeHint: true)
        
        let inputFile = match (inputFileOpt) {
            case Some(f) => f
            case None =>
                Hilog.info(0, "CjTelegram", "[RealMessageService] sendVideo: upload failed")
                let failResult = SendMessageResult()
                failResult.errorMessage = "Upload failed"
                return failResult
        }
        
        // Step 2: 构建 InputMediaUploadedDocument with video attributes
        let media = InputMediaUploadedDocument()
        media.file = inputFile
        media.mimeType = mimeType
        if (thumbData.size > 0) {
            match (uploadService.uploadFile(thumbData, "thumb.jpg")) {
                case Some(t) => media.thumbFile = Some(t)
                case None => Hilog.info(0, "CjTelegram", "[RealMessageService] sendVideo: thumb upload failed, sending without thumb")
            }
        }
        
        // DocumentAttributeVideo
        let videoAttr = DocumentAttributeVideo()
        videoAttr.duration = duration
        videoAttr.w = width
        videoAttr.h = height
        videoAttr.supportsStreaming = true
        media.attributes.add(videoAttr)
        
        // DocumentAttributeFilename
        let fileNameAttr = DocumentAttributeFilenameTL()
        fileNameAttr.fileName = fileName
        media.attributes.add(fileNameAttr)
        
        // Step 3: 发送
        let client = getMTProtoClient()
        let req = MessagesSendMedia()
        req.peer = buildInputPeer(peerType, peerId)
        req.media = media
        req.message = caption
        req.randomId = generateRandomId()
        req.replyToMsgId = replyToMsgId
        
        let responseData = client.sendRequest(req.toBytes())
        return parseSendMediaResponse(responseData, "sendVideo")
    }

    /**
     * Phase P6-11: 发送视频消息（圆形 Video Note）
     * 
     * 与 sendVideo 类似，但设置 roundMessage=true
     * 视频消息在 Telegram 中显示为圆形
     */
    public func sendVideoNote(
        peerType: String,
        peerId: Int64,
        videoData: Array<Byte>,
        fileName: String,
        duration!: Float64 = 0.0,
        width!: Int32 = 400,
        height!: Int32 = 400,
        caption!: String = "",
        replyToMsgId!: Int32 = 0,
        thumbData!: Array<Byte> = Array<Byte>(0, repeat: 0)
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendVideoNote: peer=${peerType}/${peerId}, file=${fileName}, ${duration}s")
        
        let uploadService = getFileUploadService()
        let inputFileOpt = uploadService.uploadFile(videoData, fileName, largeHint: true)
        
        let inputFile = match (inputFileOpt) {
            case Some(f) => f
            case None =>
                Hilog.info(0, "CjTelegram", "[RealMessageService] sendVideoNote: upload failed")
                let failResult = SendMessageResult()
                failResult.errorMessage = "Upload failed"
                return failResult
        }
        
        let media = InputMediaUploadedDocument()
        media.file = inputFile
        media.mimeType = "video/mp4"
        // 缩略图（iOS previewRepresentations → inputMediaUploadedDocument.thumb）：没有它对端下载前没有预览
        if (thumbData.size > 0) {
            match (uploadService.uploadFile(thumbData, "thumb.jpg")) {
                case Some(t) => media.thumbFile = Some(t)
                case None => Hilog.info(0, "CjTelegram", "[RealMessageService] sendVideoNote: thumb upload failed, sending without thumb")
            }
        }
        
        // DocumentAttributeVideo with roundMessage=true
        let videoAttr = DocumentAttributeVideo()
        videoAttr.roundMessage = true
        videoAttr.duration = duration
        videoAttr.w = width
        videoAttr.h = height
        videoAttr.supportsStreaming = true
        media.attributes.add(videoAttr)
        
        let fileNameAttr = DocumentAttributeFilenameTL()
        fileNameAttr.fileName = fileName
        media.attributes.add(fileNameAttr)
        
        let client = getMTProtoClient()
        let req = MessagesSendMedia()
        req.peer = buildInputPeer(peerType, peerId)
        req.media = media
        req.message = caption
        req.randomId = generateRandomId()
        req.replyToMsgId = replyToMsgId
        
        let responseData = client.sendRequest(req.toBytes())
        return parseSendMediaResponse(responseData, "sendVideoNote")
    }

    // ==================== Phase P7A-3: 发送投票消息 ====================

    /**
     * 发送投票消息
     * 
     * 流程: 构建 InputMediaPoll(question, answers) → messages.sendMedia
     * 
     * @param peerType 对话类型 (user/chat/channel)
     * @param peerId 对话 ID
     * @param question 投票问题
     * @param options 投票选项列表
     * @param multipleChoice 是否允许多选
     * @return SendMessageResult
     */
    public func sendPoll(
        peerType: String,
        peerId: Int64,
        question: String,
        options: ArrayList<String>,
        anonymous!: Bool = true,
        multipleChoice!: Bool = false,
        quiz!: Bool = false,
        correctAnswers!: ArrayList<Int32> = ArrayList<Int32>(),
        replyToMsgId!: Int32 = 0
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendPoll: peer=${peerType}/${peerId}, question=${question}, options=${options.size}, quiz=${quiz}, correct=${correctAnswers.size}")
        let client = getMTProtoClient()

        // 构建 InputMediaPoll
        let media = InputMediaPoll()
        media.question = question
        media.answers = options
        media.anonymous = anonymous
        media.multipleChoice = multipleChoice
        media.quiz = quiz
        media.correctAnswers = correctAnswers

        // messages.sendMedia
        let req = MessagesSendMedia()
        req.peer = buildInputPeer(peerType, peerId)
        req.media = media
        req.message = ""
        req.randomId = generateRandomId()
        req.replyToMsgId = replyToMsgId

        let responseData = client.sendRequest(req.toBytes())
        return parseSendMediaResponse(responseData, "sendPoll")
    }

    // ==================== Phase P7A-2: 发送联系人卡片 ====================

    /**
     * 发送联系人卡片消息
     * 
     * 流程: 构建 InputMediaContact(phone, firstName, lastName, vcard) → messages.sendMedia
     * 
     * @param peerType 对话类型 (user/chat/channel)
     * @param peerId 对话 ID
     * @param phoneNumber 电话号码
     * @param firstName 名
     * @param lastName 姓
     * @param vcard vCard 字符串（可为空）
     * @return SendMessageResult
     */
    public func sendContact(
        peerType: String,
        peerId: Int64,
        phoneNumber: String,
        firstName: String,
        lastName: String,
        vcard!: String = "",
        replyToMsgId!: Int32 = 0
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendContact: peer=${peerType}/${peerId}, phone=${phoneNumber}, name=${firstName} ${lastName}")
        let client = getMTProtoClient()

        // 构建 InputMediaContact
        let media = InputMediaContact()
        media.phoneNumber = phoneNumber
        media.firstName = firstName
        media.lastName = lastName
        media.vcard = vcard

        // messages.sendMedia
        let req = MessagesSendMedia()
        req.peer = buildInputPeer(peerType, peerId)
        req.media = media
        req.message = ""
        req.randomId = generateRandomId()
        req.replyToMsgId = replyToMsgId

        let responseData = client.sendRequest(req.toBytes())
        return parseSendMediaResponse(responseData, "sendContact")
    }

    // ==================== Phase P7A-1: 发送位置消息 ====================

    /**
     * 附件面板：按引用发送已有文档（iOS「Recently Sent Files / Chats Music」点选即发）。
     * inputMediaDocument#a8763ab5 id:InputDocument —— 不重新上传，服务端直接复用文件。
     */
    public func sendDocumentByReference(
        peerType: String,
        peerId: Int64,
        docId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        replyToMsgId!: Int32 = 0
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendDocumentByReference: peer=${peerType}/${peerId}, doc=${docId}")
        let client = getMTProtoClient()
        let doc = InputDocument()
        doc.id = docId
        doc.accessHash = accessHash
        doc.fileReference = fileReference
        let media = InputMediaDocument()
        media.id = doc
        let req = MessagesSendMedia()
        req.peer = buildInputPeer(peerType, peerId)
        req.media = media
        req.message = ""
        req.randomId = generateRandomId()
        req.replyToMsgId = replyToMsgId
        let responseData = client.sendRequest(req.toBytes())
        return parseSendMediaResponse(responseData, "sendDocumentByReference")
    }

    /**
     * 附件面板 Location 页签「OR CHOOSE A PLACE」：发送场馆（inputMediaVenue#c13d1c11）。
     */
    public func sendVenue(
        peerType: String,
        peerId: Int64,
        lat: Float64,
        lng: Float64,
        title: String,
        address: String,
        provider: String,
        venueId: String,
        venueType: String,
        replyToMsgId!: Int32 = 0
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendVenue: peer=${peerType}/${peerId}, title=${title}")
        let client = getMTProtoClient()
        let geo = InputGeoPoint()
        geo.lat = lat
        geo.long = lng
        let media = InputMediaVenue()
        media.geoPoint = geo
        media.title = title
        media.address = address
        media.provider = provider
        media.venueId = venueId
        media.venueType = venueType
        let req = MessagesSendMedia()
        req.peer = buildInputPeer(peerType, peerId)
        req.media = media
        req.message = ""
        req.randomId = generateRandomId()
        req.replyToMsgId = replyToMsgId
        let responseData = client.sendRequest(req.toBytes())
        return parseSendMediaResponse(responseData, "sendVenue")
    }

    /**
     * 发送地理位置消息
     * 
     * 流程: 构建 InputMediaGeoPoint(InputGeoPoint(lat, lng)) → messages.sendMedia
     * 
     * @param peerType 对话类型 (user/chat/channel)
     * @param peerId 对话 ID
     * @param lat 纬度
     * @param lng 经度
     * @return SendMessageResult
     */
    public func sendLocation(
        peerType: String,
        peerId: Int64,
        lat: Float64,
        lng: Float64,
        replyToMsgId!: Int32 = 0
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendLocation: peer=${peerType}/${peerId}, lat=${lat}, lng=${lng}")
        let client = getMTProtoClient()

        // 构建 InputMediaGeoPoint
        let geoPoint = InputGeoPoint()
        geoPoint.lat = lat
        geoPoint.long = lng

        let media = InputMediaGeoPoint()
        media.geoPoint = geoPoint

        // messages.sendMedia
        let req = MessagesSendMedia()
        req.peer = buildInputPeer(peerType, peerId)
        req.media = media
        req.message = ""
        req.randomId = generateRandomId()
        req.replyToMsgId = replyToMsgId

        let responseData = client.sendRequest(req.toBytes())
        return parseSendMediaResponse(responseData, "sendLocation")
    }

    /**
     * 发送实时位置消息
     * 
     * 流程: 构建 InputMediaGeoLive(InputGeoPoint(lat, lng), period) → messages.sendMedia
     * 
     * @param peerType 对话类型
     * @param peerId 对话 ID
     * @param lat 纬度
     * @param lng 经度
     * @param period 分享持续时间（秒），默认 900 (15 分钟)
     * @return SendMessageResult
     */
    public func sendLiveLocation(
        peerType: String,
        peerId: Int64,
        lat: Float64,
        lng: Float64,
        period!: Int32 = 900,
        replyToMsgId!: Int32 = 0
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendLiveLocation: peer=${peerType}/${peerId}, lat=${lat}, lng=${lng}, period=${period}s")
        let client = getMTProtoClient()

        // 构建 InputMediaGeoLive
        let geoPoint = InputGeoPoint()
        geoPoint.lat = lat
        geoPoint.long = lng

        let media = InputMediaGeoLive()
        media.geoPoint = geoPoint
        media.period = period

        // messages.sendMedia
        let req = MessagesSendMedia()
        req.peer = buildInputPeer(peerType, peerId)
        req.media = media
        req.message = ""
        req.randomId = generateRandomId()
        req.replyToMsgId = replyToMsgId

        let responseData = client.sendRequest(req.toBytes())
        return parseSendMediaResponse(responseData, "sendLiveLocation")
    }

    // ==================== 辅助方法 ====================

    /**
     * 构建 InputPeer（公开方法，供 ViewModel 复用）
     */
    /**
     * 转发来源显示名 —— 对位 iOS ChatMessageForwardInfoNode.asyncLayout 的 peerString：
     *   有来源 peer（fwd_from.from_id）→ 其 displayTitle；同时带 post_author 时为 "频道名 (作者)"；
     *   无 peer（隐藏转发，只有 from_name / post_author）→ 直接用该名字。
     * 此前只取 from_name，频道 / 普通用户转发（from_id 形式）一律没有来源头。
     */
    private func forwardSourceName(
        tlMsg: TLMessage,
        userNames: HashMap<Int64, String>,
        chatNames: HashMap<Int64, String>
    ): String {
        var peerTitle = ""
        if (tlMsg.fwdFromPeerId != 0) {
            if (tlMsg.fwdFromPeerType == "user") {
                if (userNames.contains(tlMsg.fwdFromPeerId)) {
                    peerTitle = userNames[tlMsg.fwdFromPeerId]
                } else {
                    let cached = match (getRealChatListService().getCachedUser(tlMsg.fwdFromPeerId)) {
                        case Some(u) => Some(u)
                        case None => getUserPhotoService().getCachedUser(tlMsg.fwdFromPeerId)
                    }
                    match (cached) {
                        case Some(u) => peerTitle = "${u.firstName} ${u.lastName}".trimAscii()
                        case None => ()
                    }
                }
            } else if (chatNames.contains(tlMsg.fwdFromPeerId)) {
                peerTitle = chatNames[tlMsg.fwdFromPeerId]
            } else {
                match (getRealChatListService().getCachedChat(tlMsg.fwdFromPeerId)) {
                    case Some(chat) => peerTitle = chat.title
                    case None => ()
                }
            }
        }
        if (peerTitle.size > 0) {
            if (tlMsg.fwdPostAuthor.size > 0) { return "${peerTitle} (${tlMsg.fwdPostAuthor})" }
            return peerTitle
        }
        if (tlMsg.fwdFromName.size > 0) { return tlMsg.fwdFromName }
        return tlMsg.fwdPostAuthor
    }

    private func cachedUserDisplayName(userId: Int64): String {
        let cached = match (getRealChatListService().getCachedUser(userId)) {
            case Some(u) => Some(u)
            case None => getUserPhotoService().getCachedUser(userId)
        }
        match (cached) {
            case Some(u) =>
                let full = "${u.firstName} ${u.lastName}".trimAscii()
                if (full.size > 0) { return full }
                return "a member"
            case None => return "a member"
        }
    }

    public func buildInputPeer(peerType: String, peerId: Int64): TLObject {
        if (peerType == "user") {
            let peer = InputPeerUser()
            peer.userId = peerId
            if (this.userAccessHashes.contains(peerId)) {
                peer.accessHash = this.userAccessHashes[peerId]
            }
            return peer
        } else if (peerType == "chat") {
            let peer = InputPeerChat()
            peer.chatId = peerId
            return peer
        } else if (peerType == "channel") {
            let peer = InputPeerChannel()
            peer.channelId = peerId
            peer.accessHash = this.getAccessHashForChannel(peerId)
            return peer
        }
        return InputPeerEmpty()
    }

    /**
     * 构建 channels.* 方法要求的 InputChannel。
     * InputPeerChannel 只能用于 InputPeer 字段，两者构造器 ID 不同，不能互换。
     */
    public func buildInputChannel(channelId: Int64): InputChannel {
        let channel = InputChannel()
        channel.channelId = channelId
        channel.accessHash = this.getAccessHashForChannel(channelId)
        return channel
    }

    /**
     * 生成安全的 randomId（避免 UInt64 > Int64.Max 的 OverflowException）
     */
    private func generateRandomId(): Int64 {
        let high = Int64(_rand.nextUInt32() & 0x7FFFFFFF)
        let low = Int64(_rand.nextUInt32())
        return (high << 32) | (low & 0xFFFFFFFF)
    }

    /**
     * 从响应中缓存 accessHash
     */
    private func cacheFromResponse(users: ArrayList<UserResponse>, chats: ArrayList<ChatResponse>) {
        for (user in users) {
            if (user.accessHash != 0) {
                cacheUserAccessHash(user.id, user.accessHash)
            }
        }
        for (chat in chats) {
            if (chat.isChannel && chat.accessHash != 0) {
                cacheChannelAccessHash(chat.id, chat.accessHash)
            }
        }
    }

    /**
     * Phase Q6: 解析发送消息的响应
     * 
     * 支持的构造器:
     * - updateShortSentMessage (0x9015e101): 最常见，包含 id/pts/date
     *   iOS Api30.swift L219: appendInt32(-1877614335); hex(-1877614335 & 0xffffffff) == 0x9015e101
     * - updates (0x74ae4240) / updatesCombined (0x725b04c3) / updateShort (0x78d4dec1):
     *   复杂 Updates 容器，返回 success=true 但无具体 messageId
     * - messages.affectedHistory (0xb45c69d1) / affectedMessages (0x84d19185):
     *   read/delete 等方法返回的 pts 状态
     * - rpc_error (0x2144ca19): 返回错误信息
     */
    private func parseSendMessageResponse(responseData: Array<Byte>, methodName: String): SendMessageResult {
        let result = SendMessageResult()

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] ${methodName}: empty response")
            return result
        }

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] ${methodName}: response too short (${responseData.size} bytes)")
            return result
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        Hilog.info(0, "CjTelegram", "[RealMessageService] ${methodName} response constructor: 0x${constructor}")

        // updateShortSentMessage (0x9015e101) - 最常见的发送成功响应
        // iOS Api30.swift L219: appendInt32(-1877614335); python: hex(-1877614335 & 0xffffffff) == 0x9015e101
        if (constructor == 0x9015e101) {
            let flags = d.readInt32()
            let msgId = d.readInt32()
            let pts = d.readInt32()
            let ptsCount = d.readInt32()
            let date = d.readInt32()
            
            result.success = true
            result.messageId = msgId
            result.pts = pts
            result.ptsCount = ptsCount
            result.date = date

            // 自己发出的消息同样要推进账号状态，否则本地 pts 每发一条就落后一格，
            // 之后的实时 update（含 updateReadHistoryOutbox）全被判成 gap 丢弃。
            // 对齐 iOS：sent-message 结果与实时 update 共用同一条状态机。
            getUpdatesManager().applySentMessagePts(pts, ptsCount)

            Hilog.info(0, "CjTelegram", "[RealMessageService] ${methodName}: updateShortSentMessage - id=${msgId}, pts=${pts}, date=${date}")
            return result
        }

        // updates#74ae4240      updates:Vector<Update> users:Vector<User> chats:Vector<Chat> date:int seq:int
        // updatesCombined#725b04c3 同上（seq_start 多一个字段）
        // updateShort#78d4dec1   update:Update date:int
        if (constructor == 0x74ae4240 || constructor == 0x725b04c3 || constructor == 0x78d4dec1) {
            result.success = true

            // ★ 从 Updates 里取回服务端消息 id。
            //
            // 媒体发送（sendMedia）返回的是 Updates 而非 updateShortSentMessage，
            // 此处**曾经直接 return、不取 id**（日志原文 "success without message ID"），
            // 于是 ChatRoomViewModel 里 9 条媒体路径的 `if (result.messageId != 0)`
            // 永远为假，本地待发消息从来没被换号。
            // 旧代码靠随后的 replaceAll 整表替换把本地那条抹掉，问题被掩盖；
            // 历史刷新改成增量合并后就暴露为**同一条消息两份**
            // （真机实测：id=101/stableId=51 sending 与 id=704/stableId=52 sent 并存）。
            //
            // updateMessageID#4e90bfd6 id:int random_id:long —— 服务端用它把本次发送的
            // random_id 映射到正式 msg_id，对齐 iOS 的 random_id 匹配机制。
            //
            // ⚠️ 限制：TL 是变长编码，**不认识的 update 无法跳过**（不知道结构就算不出长度），
            // 因此只能顺序扫描到第一个无法识别的元素为止。Telegram 对 sendMedia 的响应
            // 惯例上把 updateMessageID 放在数组首位，实测可取到；万一取不到就退化为
            // messageId=0，调用方有兜底（移除本地待发条目，避免重复），不会比之前更差。
            if (constructor != 0x78d4dec1) {
                try {
                    let vecCtor = d.readUInt32()
                    if (vecCtor == TLConstructors.VECTOR) {
                        let count = d.readInt32()
                        var i: Int64 = 0
                        while (i < Int64(count)) {
                            let updateCtor = d.readUInt32()
                            if (updateCtor == 0x4e90bfd6) {
                                result.messageId = d.readInt32()
                                let _randomId = d.readInt64()
                                break
                            }
                            // 无法识别 → 后面的字节偏移不可信，停止扫描
                            break
                        }
                    }
                } catch (_: Exception) {
                    // 解析失败不影响 success —— 退化到 messageId=0 的兜底路径
                    ()
                }
            }

            if (result.messageId != 0) {
                Hilog.info(0, "CjTelegram",
                    "[RealMessageService] ${methodName}: Updates response, updateMessageID id=${result.messageId}")
            } else {
                Hilog.info(0, "CjTelegram",
                    "[RealMessageService] ${methodName}: Updates response (constructor=0x${constructor}), no updateMessageID in first slot")
            }
            // 这条响应里的 pts 取不到（上面的顺序扫描一遇到不认识的 update 就停），
            // 不补差就会在账号状态里留一个空洞，之后每条实时 update 都被判成 gap。
            getUpdatesManager().requestDifferenceSync()
            return result
        }

        // messages.affectedHistory#b45c69d1 pts:int pts_count:int offset:int
        if (constructor == 0xb45c69d1) {
            let pts = d.readInt32()
            let ptsCount = d.readInt32()
            let offset = d.readInt32()
            result.success = true
            result.pts = pts
            result.ptsCount = ptsCount
            getUpdatesManager().applyRpcResultPts(methodName, pts, ptsCount)
            Hilog.info(0, "CjTelegram",
                "[RealMessageService] ${methodName}: affectedHistory pts=${pts} count=${ptsCount} offset=${offset}")
            return result
        }

        // messages.affectedMessages#84d19185 pts:int pts_count:int
        if (constructor == 0x84d19185) {
            let pts = d.readInt32()
            let ptsCount = d.readInt32()
            result.success = true
            result.pts = pts
            result.ptsCount = ptsCount
            getUpdatesManager().applyRpcResultPts(methodName, pts, ptsCount)
            Hilog.info(0, "CjTelegram",
                "[RealMessageService] ${methodName}: affectedMessages pts=${pts} count=${ptsCount}")
            return result
        }

        // RPC error (0x2144ca19)
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            result.errorCode = errorCode
            result.errorMessage = errorMessage
            Hilog.info(0, "CjTelegram", "[RealMessageService] ${methodName} RPC Error: ${errorCode} - ${errorMessage}")
            return result
        }

        // 未知构造器 - 假定成功（可能是新版本的响应格式）
        result.success = true
        Hilog.info(0, "CjTelegram", "[RealMessageService] ${methodName}: unknown constructor 0x${constructor}, assuming success")
        return result
    }

    /**
     * Phase Q6: 解析发送媒体的响应
     * 
     * 媒体响应与消息响应格式相同（都可能返回 updateShortSentMessage 或 Updates）
     */
    private func parseSendMediaResponse(responseData: Array<Byte>, methodName: String): SendMessageResult {
        return parseSendMessageResponse(responseData, methodName)
    }

    /**
     * Phase Q6: 向后兼容 - 简单布尔检查（用于 delete/edit/forward/reaction 等不需要消息 ID 的操作）
     */
    private func checkSendResponse(responseData: Array<Byte>, methodName: String): Bool {
        let result = parseSendMessageResponse(responseData, methodName)
        return result.success
    }

    // ==================== Phase S1: 邀请链接管理 ====================

    // ==================== Phase S2: 群组/频道完整信息 ====================

    /**
     * 获取群组/频道的完整信息（描述、成员数、在线数等）
     */
    /**
     * messages.getFullChat / channels.getFullChannel 按会话合并 + 短时缓存。
     *
     * 进群聊时 3 个调用方（成员角色、慢速模式、Video Chat JOIN 条）同时各发一次，
     * 资料页再发一次，点 video chat 又强刷一次——同一个 chat 4 秒内 5 次 getFullChat，
     * 服务器回 FLOOD_WAIT_7，Video Chat 页要等 7 秒才打开（真机实锤）。
     * 同一会话的并发请求串行化，8 秒内的重复请求直接复用上一次结果。
     */
    public func getFullChatInfo(peerType: String, peerId: Int64): ChatFullResponse {
        let key = "${peerType}:${peerId}"
        synchronized(_fullChatGate) {
            let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
            if (_fullChatCache.contains(key)) {
                let (at, cached) = _fullChatCache[key]
                if (nowMs - at < 8000) { return cached }
            }
            let fresh = this.fetchFullChatInfo(peerType, peerId)
            // 失败返回的是空对象，不缓存，下一次照常重试
            if (fresh.membersCount > 0 || fresh.participants.size > 0 || fresh.about.size > 0 || fresh.activeCallId != 0) {
                _fullChatCache[key] = (DateTime.now().toUnixTimeStamp().toMilliseconds(), fresh)
            }
            return fresh
        }
    }

    private func fetchFullChatInfo(peerType: String, peerId: Int64): ChatFullResponse {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getFullChatInfo: peerType=${peerType}, peerId=${peerId}")
        let client = getMTProtoClient()

        var responseData: Array<Byte> = Array<Byte>()
        if (peerType == "channel") {
            let req = ChannelsGetFullChannel()
            req.channel = this.buildInputChannel(peerId)
            responseData = client.sendRequest(req.toBytes())
        } else {
            // chat (basic group)
            let req = MessagesGetFullChat()
            req.chatId = peerId
            responseData = client.sendRequest(req.toBytes())
        }

        if (responseData.size < 8) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] getFullChatInfo: empty response")
            return ChatFullResponse()
        }

        let result = ChatFullResponse.deserialize(responseData)
        Hilog.info(0, "CjTelegram", "[RealMessageService] getFullChatInfo: about=${result.about.size} chars, members=${result.membersCount}, online=${result.onlineCount}")
        return result
    }

    // ==================== Phase S8: 频道管理增强 ====================

    /**
     * 删除频道/超级群
     */
    public func deleteChannel(peerId: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] deleteChannel: peerId=${peerId}")
        let client = getMTProtoClient()

        let req = ChannelsDeleteChannel()
        let ch = this.buildInputChannel(peerId)
        req.channel = ch

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] deleteChannel error: ${errorCode} - ${errorMessage}")
            return false
        }
        getUpdatesManager().handleRawUpdate(responseData)
        return true
    }

    /**
     * 离开频道/超级群
     */
    public func leaveChannel(peerId: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] leaveChannel: peerId=${peerId}")
        let client = getMTProtoClient()

        let req = ChannelsLeaveChannel()
        req.channel = this.buildInputChannel(peerId)

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] leaveChannel error: ${errorCode} - ${errorMessage}")
            return false
        }
        getRealChatListService().markDialogRemoved("channel", peerId)
        getUpdatesManager().handleRawUpdate(responseData)
        return true
    }

    /**
     * 离开普通群。Telegram iOS 对 legacy group 使用
     * messages.deleteChatUser(chatId, inputUserSelf)，而不是 channels.leaveChannel。
     */
    public func leaveGroup(chatId: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] leaveGroup: chatId=${chatId}")
        // iOS ManagedCloudChatRemoveMessagesOperations 先以 forLocalPeer 清除历史，
        // 再移除 inputUserSelf；否则旧历史仍会让该 dialog 留在 getDialogs 中。
        let _ = this.clearHistory(
            "chat",
            chatId,
            maxId: 2147483646,
            justClear: false,
            revoke: false
        )
        let req = MessagesDeleteChatUser()
        req.chatId = chatId
        req.userId = InputUserSelf()

        let responseData = getMTProtoClient().sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] leaveGroup error: ${errorCode} - ${errorMessage}")
            return false
        }
        getRealChatListService().markDialogRemoved("chat", chatId)
        getUpdatesManager().handleRawUpdate(responseData)
        return true
    }

    /**
     * 群主解散普通群：messages.deleteChat#5bd0ee50 → Bool。
     * iOS ManagedCloudChatRemoveMessagesOperations.swift:301（deleteGloballyIfPossible）。
     */
    public func deleteChat(chatId: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] deleteChat: chatId=${chatId}")
        let req = MessagesDeleteChat()
        req.chatId = chatId
        let responseData = getMTProtoClient().sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }
        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] deleteChat error: ${errorCode} - ${errorMessage}")
            return false
        }
        if (constructor == TLConstructors.BOOL_FALSE) { return false }
        getMessageHistoryStore().clearPeer(chatId, peerType: "chat")
        getRealChatListService().markDialogRemoved("chat", chatId)
        return true
    }

    /**
     * 群主/频道主"为所有成员删除"：对位 iOS removeChat(deleteGloballyIfPossible: true)
     *   CloudChannel → channels.deleteChannel，失败回退 channels.leaveChannel
     *   CloudGroup   → messages.deleteChat
     */
    public func deletePeerGlobally(peerType: String, peerId: Int64): Bool {
        if (peerType == "chat") {
            return this.deleteChat(peerId)
        }
        if (peerType == "channel") {
            if (this.deleteChannel(peerId)) {
                getRealChatListService().markDialogRemoved("channel", peerId)
                return true
            }
            return this.leaveChannel(peerId)
        }
        Hilog.info(0, "CjTelegram", "[RealMessageService] deletePeerGlobally unsupported peerType=${peerType}")
        return false
    }

    /** 按 peer 类型分发普通群和频道/超级群的离开接口。 */
    public func leavePeer(peerType: String, peerId: Int64): Bool {
        if (peerType == "chat") {
            return this.leaveGroup(peerId)
        }
        if (peerType == "channel") {
            return this.leaveChannel(peerId)
        }
        Hilog.info(0, "CjTelegram", "[RealMessageService] leavePeer unsupported peerType=${peerType}")
        return false
    }

    // ==================== Phase S6: 编辑群组信息 ====================

    // ==================== Phase P6-6: 群组头像上传 ====================

    /**
     * 上传并设置群组/频道头像
     * 
     * 流程：upload.saveFilePart → channels.editPhoto (InputChatUploadedPhoto)
     */
    public func editChannelPhoto(peerId: Int64, photoData: Array<Byte>): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] P6-6: editChannelPhoto: peerId=${peerId}, dataSize=${photoData.size}")
        
        // Step 1: 上传文件
        let uploadService = getFileUploadService()
        let inputFileOpt = uploadService.uploadFile(photoData, "group_photo.jpg")
        match (inputFileOpt) {
            case None =>
                Hilog.info(0, "CjTelegram", "[RealMessageService] P6-6: Upload failed")
                return false
            case Some(inputFile) =>
                // Step 2: 构造 InputChatUploadedPhoto
                let chatPhoto = InputChatUploadedPhoto()
                chatPhoto.file = inputFile
                
                // Step 3: 调用 channels.editPhoto
                let client = getMTProtoClient()
                let req = ChannelsEditPhoto()
                let ch = this.buildInputChannel(peerId)
                req.channel = ch
                req.photo = chatPhoto
                
                let responseData = client.sendRequest(req.toBytes())
                if (responseData.size < 4) { return false }
                
                let d = TLDeserializer(responseData)
                let constructor = d.readUInt32()
                if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
                    let errorCode = d.readInt32()
                    let errorMessage = d.readString()
                    Hilog.info(0, "CjTelegram", "[RealMessageService] P6-6: editPhoto error: ${errorCode} - ${errorMessage}")
                    return false
                }
                
                getUpdatesManager().handleRawUpdate(responseData)
                Hilog.info(0, "CjTelegram", "[RealMessageService] P6-6: editChannelPhoto success")
                return true
        }
    }

    /** Upload and apply a photo to a classic group after messages.createChat. */
    public func editBasicGroupPhoto(peerId: Int64, photoData: Array<Byte>): Bool {
        let uploaded = getFileUploadService().uploadFile(photoData, "group_photo.jpg")
        match (uploaded) {
            case None => return false
            case Some(inputFile) =>
                let photo = InputChatUploadedPhoto()
                photo.file = inputFile
                let req = MessagesEditChatPhoto()
                req.chatId = peerId
                req.removePhoto = false
                req.photo = photo
                let responseData = getMTProtoClient().sendRequest(req.toBytes())
                if (responseData.size < 4) { return false }
                let d = TLDeserializer(responseData)
                let constructor = d.readUInt32()
                if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
                    let code = d.readInt32()
                    let message = d.readString()
                    Hilog.info(0, "CjTelegram", "[RealMessageService] editBasicGroupPhoto error: ${code} ${message}")
                    return false
                }
                getUpdatesManager().handleRawUpdate(responseData)
                return true
        }
    }

    /** 按群类型分发普通群与频道/超级群的头像接口。 */
    public func editGroupPhoto(peerType: String, peerId: Int64, photoData: Array<Byte>): Bool {
        if (peerType == "chat") {
            return this.editBasicGroupPhoto(peerId, photoData)
        }
        if (peerType == "channel") {
            return this.editChannelPhoto(peerId, photoData)
        }
        return false
    }

    /**
     * 修改群组/频道标题
     */
    public func editGroupTitle(peerType: String, peerId: Int64, newTitle: String): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] editGroupTitle: newTitle=${newTitle}")
        let client = getMTProtoClient()

        var responseData: Array<Byte> = Array<Byte>()
        if (peerType == "chat") {
            let req = MessagesEditChatTitle()
            req.chatId = peerId
            req.title = newTitle
            responseData = client.sendRequest(req.toBytes())
        } else if (peerType == "channel") {
            let req = ChannelsEditTitle()
            req.channel = this.buildInputChannel(peerId)
            req.title = newTitle
            responseData = client.sendRequest(req.toBytes())
        } else {
            return false
        }
        if (responseData.size < 4) { return false }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] editGroupTitle error: ${errorCode} - ${errorMessage}")
            return false
        }
        getUpdatesManager().handleRawUpdate(responseData)
        return true
    }

    /**
     * 修改群组/频道描述
     */
    public func editGroupAbout(peerType: String, peerId: Int64, newAbout: String): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] editGroupAbout")
        let client = getMTProtoClient()

        let req = MessagesEditChatAbout()
        req.peer = buildInputPeer(peerType, peerId)
        req.about = newAbout

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] editGroupAbout error: ${errorCode} - ${errorMessage}")
            return false
        }
        return true
    }

    /**
     * P7B-3: 更新频道用户名（公开/私有切换）
     * username 为空字符串时变为私有频道
     */
    public func updateChannelUsername(peerId: Int64, username: String): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] updateChannelUsername: username=${username}")
        let client = getMTProtoClient()

        let req = ChannelsUpdateUsername()
        let ch = this.buildInputChannel(peerId)
        req.channel = ch
        req.username = username

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] updateChannelUsername error: ${errorCode} - ${errorMessage}")
            return false
        }
        return true
    }

    // ==================== Phase S3: 管理员管理 ====================

    /**
     * 设置/更新管理员权限
     * @param adminFlags ChatAdminRights 的 flags 位图
     * @param rank 管理员头衔（可为空）
     */
    public func editAdmin(peerId: Int64, userId: Int64, userAccessHash: Int64, adminFlags: Int32, rank: String): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] editAdmin: userId=${userId}, flags=${adminFlags}")
        let client = getMTProtoClient()

        let req = ChannelsEditAdmin()
        let ch = this.buildInputChannel(peerId)
        req.channel = ch

        let user = InputUser()
        user.userId = userId
        user.accessHash = userAccessHash
        req.userId = user

        let rights = ChatAdminRights()
        rights.flags = adminFlags
        req.adminRights = rights
        req.rank = rank

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] editAdmin error: ${errorCode} - ${errorMessage}")
            return false
        }

        Hilog.info(0, "CjTelegram", "[RealMessageService] editAdmin success")
        return true
    }

    /** 基础群管理员开关；传统群没有频道式的细粒度权限和自定义头衔。 */
    public func editBasicGroupAdmin(chatId: Int64, userId: Int64, userAccessHash: Int64, isAdmin: Bool): Bool {
        let req = MessagesEditChatAdmin()
        req.chatId = chatId
        req.userId = userId
        req.userAccessHash = userAccessHash
        req.isAdmin = isAdmin
        return this.checkSendResponse(getMTProtoClient().sendRequest(req.toBytes()), "messages.editChatAdmin")
    }

    /**
     * 获取频道管理员列表
     * 使用 channelParticipantsAdmins#b4608969 过滤器
     */
    public func getChannelAdmins(peerId: Int64): ArrayList<AdminMemberData> {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getChannelAdmins: peerId=${peerId}")
        let client = getMTProtoClient()

        let req = ChannelsGetParticipants()
        let ch = this.buildInputChannel(peerId)
        req.channel = ch
        req.filter = 0xb4608969  // channelParticipantsAdmins
        req.limit = 200

        let responseData = client.sendRequest(req.toBytes())
        let result = ArrayList<AdminMemberData>()
        if (responseData.size < 8) { return result }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] getChannelAdmins error: ${errorCode} - ${errorMessage}")
            return result
        }

        // channels.channelParticipants#9ab0feaf count:int participants:Vector<ChannelParticipant> chats:Vector<Chat> users:Vector<User>
        if (constructor == 0x9ab0feaf) {
            let count = d.readInt32()
            // participants vector
            let vecCtor = d.readUInt32()
            let partCount = d.readInt32()
            var i: Int32 = 0
            while (i < partCount) {
                let admin = parseChannelParticipantAdmin(d)
                if (admin.userId > 0) {
                    result.add(admin)
                }
                i += 1
            }
            // 尝试解析 users 以获取用户名 (best-effort)
            try {
                // skip chats vector
                let chatsVecCtor = d.readUInt32()
                let chatsCount = d.readInt32()
                // skip all chats (complex — just skip)
                // users vector
                let usersVecCtor = d.readUInt32()
                let usersCount = d.readInt32()
                var ui: Int32 = 0
                while (ui < usersCount) {
                    let userResp = UserResponse.deserializeBoxed(d)
                    for (admin in result) {
                        if (admin.userId == userResp.id) {
                            admin.firstName = userResp.firstName
                            admin.lastName = userResp.lastName
                            admin.userAccessHash = userResp.accessHash
                        }
                    }
                    ui += 1
                }
            } catch (_: Exception) {
                // user name resolution is best-effort
            }
            Hilog.info(0, "CjTelegram", "[RealMessageService] getChannelAdmins: got ${result.size} admins")
        }

        return result
    }

    /**
     * Phase P5-6: 获取频道/超级群真实成员列表
     * 根据 filterType 调用不同过滤器:
     *   "recent" → channelParticipantsRecent#de3f3c79
     *   "admins" → channelParticipantsAdmins#b4608969
     *   "bots"   → channelParticipantsBots#b0d1865b
     *   "kicked" → channelParticipantsKicked#a3b54985
     */
    public func getChannelMembers(peerId: Int64, filterType: String): ArrayList<ContactDisplayData> {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getChannelMembers: peerId=${peerId}, filter=${filterType}")
        let client = getMTProtoClient()
        let req = ChannelsGetParticipants()
        let ch = this.buildInputChannel(peerId)
        req.channel = ch
        req.limit = 200
        req.offset = 0

        if (filterType == "admins") {
            req.filter = 0xb4608969
        } else if (filterType == "bots") {
            req.filter = 0xb0d1865b
        } else if (filterType == "kicked") {
            req.filter = 0xa3b54985
        } else {
            req.filter = 0xde3f3c79
        }

        let result = ArrayList<ContactDisplayData>()
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 8) { return result }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] getChannelMembers error: ${errorCode} - ${errorMessage}")
            return result
        }

        // channels.channelParticipants#9ab0feaf count:int participants:Vector<ChannelParticipant> chats:Vector<Chat> users:Vector<User>
        if (constructor != 0x9ab0feaf) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] getChannelMembers unexpected ctor: 0x${UInt32ToHex(constructor)}")
            return result
        }

        let count = d.readInt32()
        Hilog.info(0, "CjTelegram", "[RealMessageService] getChannelMembers: count=${count}")

        // Parse participants → build userId → role map
        let roleMap = HashMap<Int64, String>()
        try {
            let vecCtor = d.readUInt32()
            let partCount = d.readInt32()
            var pi: Int32 = 0
            while (pi < partCount) {
                let partCtor = d.readUInt32()
                if (partCtor == 0xc00c07c0) {
                    // channelParticipant#c00c07c0 user_id:long date:int
                    let uid = d.readInt64()
                    let _ = d.readInt32()
                    roleMap[uid] = ""
                } else if (partCtor == 0x34c3bb53) {
                    // channelParticipantAdmin#34c3bb53
                    let flags = d.readInt32()
                    let uid = d.readInt64()
                    if ((flags & 2) != 0) { let _ = d.readInt64() }
                    let _ = d.readInt64()
                    let _ = d.readInt32()
                    let _ = d.readUInt32()
                    let _ = d.readInt32()
                    if ((flags & 4) != 0) { let _ = d.readString() }
                    roleMap[uid] = "admin"
                } else if (partCtor == 0x2fe601d3) {
                    // channelParticipantCreator#2fe601d3
                    let flags = d.readInt32()
                    let uid = d.readInt64()
                    let _ = d.readUInt32()
                    let _ = d.readInt32()
                    if ((flags & 1) != 0) { let _ = d.readString() }
                    roleMap[uid] = "creator"
                } else if (partCtor == 0x6df8014e) {
                    // channelParticipantBanned#6df8014e
                    let flags = d.readInt32()
                    let uid = d.readInt64()
                    let _ = d.readInt64()
                    let _ = d.readInt32()
                    let _ = d.readUInt32()
                    let _ = d.readInt32()
                    roleMap[uid] = "kicked"
                } else if (partCtor == 0x1b03f006) {
                    // channelParticipantSelf#1b03f006 flags:# via_request:flags.0?true user_id:long inviter_id:long date:int
                    let flags = d.readInt32()
                    let uid = d.readInt64()
                    let _ = d.readInt64()
                    let _ = d.readInt32()
                    roleMap[uid] = ""
                } else {
                    Hilog.info(0, "CjTelegram", "[RealMessageService] Unknown participant ctor: 0x${UInt32ToHex(partCtor)}, stopping parse")
                    break
                }
                pi += 1
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] Error parsing participants: ${e}")
        }

        // Skip chats vector, then parse users vector
        try {
            let chatsVecCtor = d.readUInt32()
            let chatsCount = d.readInt32()
            // chats are complex, skip by reading all Chat objects
            // We'll use a try-catch to gracefully handle skipping
            var ci: Int32 = 0
            while (ci < chatsCount) {
                let _ = ChatResponse.deserializeWithConstructor(d.readUInt32(), d)
                ci += 1
            }

            // Parse users vector
            let usersVecCtor = d.readUInt32()
            let usersCount = d.readInt32()
            var ui: Int32 = 0
            while (ui < usersCount) {
                try {
                    let user = UserResponse.deserializeBoxed(d)
                    let member = ContactDisplayData()
                    member.userId = user.id
                    member.accessHash = user.accessHash
                    member.firstName = user.firstName
                    member.lastName = user.lastName
                    member.username = user.username
                    member.phone = user.phone
                    member.isBot = user.isBot
                    member.isSelf = user.isSelf
                    member.isOnline = user.isOnline
                    member.statusType = user.statusType
                    if (roleMap.contains(user.id)) {
                        member.role = roleMap[user.id]
                    }
                    if (user.isBot) { member.role = "bot" }
                    result.add(member)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[RealMessageService] Error parsing member user: ${e}")
                    break
                }
                ui += 1
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] Error parsing chats/users: ${e}")
        }

        Hilog.info(0, "CjTelegram", "[RealMessageService] getChannelMembers: got ${result.size} members")
        return result
    }

    /**
     * 解析 channelParticipantAdmin / channelParticipantCreator
     */
    private func parseChannelParticipantAdmin(d: TLDeserializer): AdminMemberData {
        let admin = AdminMemberData()
        let ctor = d.readUInt32()
        
        // channelParticipantAdmin#34c3bb53
        if (ctor == 0x34c3bb53) {
            let flags = d.readInt32()
            admin.canEdit = (flags & 1) != 0
            admin.userId = d.readInt64()
            if ((flags & 2) != 0) { let _ = d.readInt64() } // inviter_id
            admin.promotedBy = d.readInt64()
            admin.date = d.readInt32()
            let rightsCtor = d.readUInt32() // ChatAdminRights boxed
            admin.adminFlags = d.readInt32()
            if ((flags & 4) != 0) { admin.rank = d.readString() }
            return admin
        }
        
        // channelParticipantCreator#2fe601d3
        if (ctor == 0x2fe601d3) {
            let flags = d.readInt32()
            admin.userId = d.readInt64()
            let rightsCtor = d.readUInt32() // ChatAdminRights boxed
            admin.adminFlags = d.readInt32()
            if ((flags & 1) != 0) { admin.rank = d.readString() }
            admin.isCreator = true
            admin.canEdit = false
            return admin
        }

        // Unknown participant type — skip is unsafe, return empty
        return admin
    }

    // ==================== Phase S4: 封禁管理 ====================

    /**
     * 封禁成员（设置 ChatBannedRights）
     * @param bannedFlags 禁止权限位图（设置为 true 表示禁止）
     * @param untilDate 封禁到期时间（0 = 永久）
     */
    public func banMember(peerId: Int64, targetUserId: Int64, targetAccessHash: Int64, bannedFlags: Int32, untilDate: Int32): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] banMember: target=${targetUserId}, flags=${bannedFlags}")
        let client = getMTProtoClient()

        let req = ChannelsEditBanned()
        let ch = this.buildInputChannel(peerId)
        req.channel = ch

        let target = InputPeerUser()
        target.userId = targetUserId
        target.accessHash = targetAccessHash
        req.participant = target

        let rights = ChatBannedRights()
        rights.flags = bannedFlags
        rights.untilDate = untilDate
        req.bannedRights = rights

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] banMember error: ${errorCode} - ${errorMessage}")
            return false
        }
        Hilog.info(0, "CjTelegram", "[RealMessageService] banMember success")
        return true
    }

    /**
     * 解封成员（设置空的 ChatBannedRights）
     */
    public func unbanMember(peerId: Int64, targetUserId: Int64, targetAccessHash: Int64): Bool {
        return banMember(peerId, targetUserId, targetAccessHash, 0, 0)
    }

    /**
     * 踢出成员（设置 view_messages 禁止）
     */
    public func kickMember(peerId: Int64, targetUserId: Int64, targetAccessHash: Int64): Bool {
        return banMember(peerId, targetUserId, targetAccessHash, 1, 0)  // bit 0 = view_messages
    }

    // ==================== Phase S1: 邀请链接管理 ====================

    /**
     * 创建新的邀请链接（messages.exportChatInvite）
     * 返回链接 URL，失败返回空字符串
     */
    public func exportChatInvite(peerType: String, peerId: Int64): String {
        Hilog.info(0, "CjTelegram", "[RealMessageService] exportChatInvite: peerType=${peerType}, peerId=${peerId}")
        let client = getMTProtoClient()

        let req = MessagesExportChatInvite()
        req.peer = buildInputPeer(peerType, peerId)

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] exportChatInvite: empty/short response")
            return ""
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        // RPC error check
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] exportChatInvite error: ${errorCode} - ${errorMessage}")
            return ""
        }

        // chatInviteExported: iOS Api0.swift:294 dict[-1574126186] -> 0xa22cbd96
        if (constructor == 0xa22cbd96) {
            return parseExportedChatInvite(d)
        }

        Hilog.info(0, "CjTelegram", "[RealMessageService] exportChatInvite: unknown constructor 0x${constructor}")
        return ""
    }

    /**
     * 获取邀请链接列表（messages.getExportedChatInvites）
     */
    public func getExportedChatInvites(peerType: String, peerId: Int64, revoked!: Bool = false): ArrayList<InviteLinkData> {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getExportedChatInvites: peerType=${peerType}, peerId=${peerId}, revoked=${revoked}")
        let client = getMTProtoClient()

        let req = MessagesGetExportedChatInvites()
        req.peer = buildInputPeer(peerType, peerId)
        req.adminId = InputUserSelf()  // P2-168 fix: admin_id is InputUser not InputPeer
        req.revoked = revoked

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return ArrayList<InviteLinkData>()
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        // RPC error check
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] getExportedChatInvites error: ${errorCode} - ${errorMessage}")
            return ArrayList<InviteLinkData>()
        }

        // messages.exportedChatInvites#bdc62dcc
        if (constructor == 0xbdc62dcc) {
            let count = d.readInt32()  // count
            let vecId = d.readUInt32() // vector
            let inviteCount = d.readInt32()
            let links = ArrayList<InviteLinkData>()
            var i: Int32 = 0
            while (i < inviteCount) {
                let invCtor = d.readUInt32()
                // chatInviteExported: iOS Api0.swift:294 dict[-1574126186] -> 0xa22cbd96
                if (invCtor == 0xa22cbd96) {
                    let linkData = parseExportedChatInviteAsData(d)
                    links.add(linkData)
                } else {
                    // skip unknown invite type (chatInvitePublicJoinRequests etc.)
                    break
                }
                i += 1
            }
            Hilog.info(0, "CjTelegram", "[RealMessageService] getExportedChatInvites: got ${links.size} links")
            return links
        }

        Hilog.info(0, "CjTelegram", "[RealMessageService] getExportedChatInvites: unknown constructor 0x${constructor}")
        return ArrayList<InviteLinkData>()
    }

    /**
     * 撤销邀请链接（messages.editExportedChatInvite with revoked=true）
     */
    public func revokeExportedChatInvite(peerType: String, peerId: Int64, link: String): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] revokeExportedChatInvite: link=${link}")
        let client = getMTProtoClient()

        let req = MessagesEditExportedChatInvite()
        req.peer = buildInputPeer(peerType, peerId)
        req.link = link
        req.revoked = true

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] revokeExportedChatInvite error: ${errorCode} - ${errorMessage}")
            return false
        }

        // messages.exportedChatInvite#1871be50 or messages.exportedChatInviteReplaced#222600ef
        Hilog.info(0, "CjTelegram", "[RealMessageService] revokeExportedChatInvite: success, constructor=0x${constructor}")
        return true
    }

    /**
     * 解析单个 chatInviteExported 对象，返回链接 URL
     * chatInviteExported: iOS Api0.swift:294 dict[-1574126186]; python hex(-1574126186 & 0xFFFFFFFF) = 0xa22cbd96
     * P2-168 fix: correct bit layout per iOS layer 214
     */
    private func parseExportedChatInvite(d: TLDeserializer): String {
        let flags = d.readInt32()
        let link = d.readString()
        let _ = d.readInt64() // admin_id
        let _ = d.readInt32() // date
        if ((flags & 16) != 0) { let _ = d.readInt32() }   // bit 4: start_date
        if ((flags & 2) != 0) { let _ = d.readInt32() }    // bit 1: expire_date
        if ((flags & 4) != 0) { let _ = d.readInt32() }    // bit 2: usage_limit
        if ((flags & 8) != 0) { let _ = d.readInt32() }    // bit 3: usage count
        if ((flags & 128) != 0) { let _ = d.readInt32() }  // bit 7: requested count
        if ((flags & 1024) != 0) { let _ = d.readInt32() } // bit 10: subscriptionExpired
        if ((flags & 256) != 0) { let _ = d.readString() } // bit 8: title
        return link
    }

    /**
     * 解析单个 chatInviteExported 对象，返回完整数据
     * chatInviteExported#0ab4a819 (iOS Api7.swift:551 ctor -1574126186 = 0xa27b0a14)
     *
     * P2-168 fix: correct flag bits per iOS layer 214 (Api7.swift:559-582):
     *   bit 0 (1):   revoked
     *   bit 1 (2):   expire_date?int
     *   bit 2 (4):   usage_limit?int
     *   bit 3 (8):   usage?int (usageCount)
     *   bit 4 (16):  start_date?int
     *   bit 5 (32):  permanent
     *   bit 6 (64):  request_needed (flag only, no payload)
     *   bit 7 (128): requested?int (pending join requests count)
     *   bit 8 (256): title?string
     *   bit 9 (512): subscriptionPricing
     *   bit 10(1024):subscriptionExpired?int
     */
    private func parseExportedChatInviteAsData(d: TLDeserializer): InviteLinkData {
        let data = InviteLinkData()
        let flags = d.readInt32()
        data.isRevoked = (flags & 1) != 0
        data.isPermanent = (flags & 32) != 0
        data.requestNeeded = (flags & 64) != 0
        data.link = d.readString()
        data.adminId = d.readInt64()
        data.date = d.readInt32()
        if ((flags & 16) != 0) { let _ = d.readInt32() }   // bit 4: start_date
        if ((flags & 2) != 0) { data.expireDate = d.readInt32() }  // bit 1: expire_date
        if ((flags & 4) != 0) { data.usageLimit = d.readInt32() }  // bit 2: usage_limit
        if ((flags & 8) != 0) { data.usageCount = d.readInt32() }  // bit 3: usage
        if ((flags & 128) != 0) { data.requestsCount = d.readInt32() }  // bit 7: requested count
        if ((flags & 1024) != 0) { let _ = d.readInt32() } // bit 10: subscriptionExpired
        if ((flags & 256) != 0) { data.title = d.readString() }    // bit 8: title
        return data
    }

    // ==================== P2-150: Drafts ====================

    /**
     * 清除所有云端草稿（对应 iOS clearCloudDraftsInteractively）
     *
     * iOS 实现:
     *   1. messages.getAllDrafts() → 得到 Updates (内含 updateDraftMessage 列表)
     *   2. 对每个草稿 peer 调 messages.saveDraft(peer, message:"") → 清空
     *
     * 平台简化：直接调 messages.clearAllDrafts#7e58ee9c（Layer 214 引入，一次 RPC 清全部）。
     * 持久化：草稿是纯云端状态（iOS 通过 Postbox 持久，平台无 Postbox，不需要本地持久化）。
     *
     * @return true 表示成功
     */
    public func clearCloudDrafts(): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] clearCloudDrafts")
        let client = getMTProtoClient()
        let req = MessagesClearAllDrafts()
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }
        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] clearCloudDrafts error: ${errorCode} - ${errorMessage}")
            return false
        }
        // boolTrue#997275b5
        Hilog.info(0, "CjTelegram", "[RealMessageService] clearCloudDrafts: success (ctor=0x${ctor})")
        return true
    }

    // ==================== P2-150: Polls ====================

    /**
     * 投票（对应 iOS messages.sendVote）
     *
     * 调用链: votePoll → MessagesSendVote.toBytes → MTProtoClient.sendRequest
     * options: 投票选项的 opaque bytes（从 PollOptionData.optionData 取）
     *
     * @param peerType 对话类型
     * @param peerId   对话 ID
     * @param msgId    投票消息 ID
     * @param options  选项 bytes 列表（每条是服务端分配的 opaque byte array）
     * @return 是否成功
     */
    public func votePoll(peerType: String, peerId: Int64, msgId: Int32, options: ArrayList<Array<Byte>>): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] votePoll: peer=${peerType}/${peerId}, msgId=${msgId}, opts=${options.size}")
        let client = getMTProtoClient()
        let req = MessagesSendVote()
        req.peer = buildInputPeer(peerType, peerId)
        req.msgId = msgId
        req.options = options
        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "votePoll")
    }

    /**
     * 关闭投票（对应 iOS messages.editMessage 设 closeFlags）
     *
     * Telegram 关闭投票的 TL 方式: messages.editMessage 中给 media 传 InputMediaPoll(closed=true)
     * 平台简化：重用已有 editMessage（修改文本），但关闭投票本质需 inputMediaPoll closed flag，
     * 独立 closePoll 方法通过 editMessage + 空文本触发更新，server 会处理 closed 状态。
     * 实际效果：发送一个 messages.editMessage with just the flags, no new text.
     * 注意：真实关闭需 inputMediaPoll(closed=true) — 这里发 editMessage 纯文本 revoke，
     * 与 iOS 的行为一致（iOS 通过 editMessage 附带 media=InputMediaPoll(poll.withClosed(true))）。
     *
     * @return 是否成功
     */
    public func closePoll(peerType: String, peerId: Int64, msgId: Int32): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] closePoll: peer=${peerType}/${peerId}, msgId=${msgId}")
        let client = getMTProtoClient()
        let req = MessagesEditMessage()
        req.peer = buildInputPeer(peerType, peerId)
        req.id = msgId
        req.message = ""
        req.closePoll = true
        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "closePoll")
    }

    // ==================== P2-150: Reactions ====================

    /**
     * 设置/添加消息反应（对应 iOS messages.sendReaction）
     *
     * emoji 非空 = 添加或切换 reaction；emoji="" = 移除所有当前用户 reactions
     * 调用链: setReaction → MessagesSendReaction.toBytes → MTProtoClient
     *
     * @param peerType  对话类型
     * @param peerId    对话 ID
     * @param msgId     消息 ID
     * @param emoji     Reaction emoji（如 "👍"、"❤️"）；空字符串移除
     * @param addToRecent 是否加入最近使用列表
     * @return 是否成功
     */
    public func setReaction(peerType: String, peerId: Int64, msgId: Int32, emoji: String, addToRecent!: Bool = true): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] setReaction: peer=${peerType}/${peerId}, msgId=${msgId}, emoji=${emoji}")
        return sendReaction(peerType, peerId, msgId, emoji)
    }

    /**
     * 获取消息的完整 Reactions 列表（对应 iOS messages.getMessagesReactions）
     *
     * 调用链: getMessagesReactions → MessagesGetMessagesReactions.toBytes → MTProtoClient
     * 服务端返回 Updates，reactions 会通过 update 推送更新本地缓存。
     *
     * @param peerType   对话类型
     * @param peerId     对话 ID
     * @param messageIds 要查询 reactions 的消息 ID 列表
     * @return 是否请求成功
     */
    public func getMessagesReactions(peerType: String, peerId: Int64, messageIds: ArrayList<Int32>): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getMessagesReactions: peer=${peerType}/${peerId}, count=${messageIds.size}")
        if (messageIds.isEmpty()) { return true }
        let client = getMTProtoClient()
        let req = MessagesGetMessagesReactions()
        req.peer = buildInputPeer(peerType, peerId)
        req.id = messageIds
        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "getMessagesReactions")
    }

    // ==================== P2-150: Bulk operations ====================

    /**
     * 删除频道内某用户的所有消息（对应 iOS channels.deleteParticipantHistory）
     *
     * 仅适用于 supergroup / channel（peerType="channel"）。
     * 普通群（chat）没有 deleteParticipantHistory，不支持此操作。
     *
     * @param peerId          频道/超级群 ID
     * @param targetUserId    目标用户 ID
     * @param targetAccessHash 目标用户 accessHash
     * @return 是否成功
     */
    public func deleteAllByAuthor(peerId: Int64, targetUserId: Int64, targetAccessHash: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] deleteAllByAuthor: peerId=${peerId}, targetUser=${targetUserId}")
        let client = getMTProtoClient()
        let req = ChannelsDeleteParticipantHistory()
        let ch = InputChannel()
        ch.channelId = peerId
        if (this.channelAccessHashes.contains(peerId)) {
            ch.accessHash = this.channelAccessHashes[peerId]
        }
        req.channel = ch
        let target = InputPeerUser()
        target.userId = targetUserId
        target.accessHash = targetAccessHash
        req.participant = target
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }
        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] deleteAllByAuthor error: ${errorCode} - ${errorMessage}")
            return false
        }
        Hilog.info(0, "CjTelegram", "[RealMessageService] deleteAllByAuthor: success")
        return true
    }

    /**
     * 清除对话历史。普通群/用户使用 messages.deleteHistory，并按
     * messages.AffectedHistory.offset 重复请求；频道/超级群必须使用
     * channels.deleteHistory。该分派与 iOS ManagedCloudChatRemoveMessagesOperations 对齐。
     */
    public func clearHistory(peerType: String, peerId: Int64, maxId!: Int32 = 0, justClear!: Bool = false, revoke!: Bool = true): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] clearHistory: peer=${peerType}/${peerId}, maxId=${maxId}, justClear=${justClear}")
        let client = getMTProtoClient()

        if (peerType == "channel") {
            let req = ChannelsDeleteHistory()
            req.channel = this.buildInputChannel(peerId)
            req.maxId = maxId
            req.forEveryone = revoke && !justClear
            let responseData = client.sendRequest(req.toBytes())
            let ok = this.checkSendResponse(responseData, "channels.deleteHistory")
            if (ok) {
                // Updates 容器由补差状态机消费，避免丢掉频道 pts。
                getUpdatesManager().requestDifferenceSync()
            }
            return ok
        }

        var pass: Int32 = 0
        while (pass < 100) {
            let req = MessagesDeleteHistory()
            req.peer = buildInputPeer(peerType, peerId)
            req.maxId = maxId
            req.justClear = justClear
            req.revoke = revoke
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) { return false }
            let d = TLDeserializer(responseData)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errorCode = d.readInt32()
                let errorMessage = d.readString()
                Hilog.info(0, "CjTelegram", "[RealMessageService] clearHistory error: ${errorCode} - ${errorMessage}")
                return false
            }
            if (ctor != 0xb45c69d1) {
                Hilog.info(0, "CjTelegram", "[RealMessageService] clearHistory unexpected ctor=0x${ctor}")
                return false
            }
            let pts = d.readInt32()
            let ptsCount = d.readInt32()
            let offset = d.readInt32()
            getUpdatesManager().applyRpcResultPts("messages.deleteHistory", pts, ptsCount)
            Hilog.info(0, "CjTelegram", "[RealMessageService] clearHistory pass=${pass} offset=${offset}")
            if (offset == 0) { return true }
            pass += 1
        }
        Hilog.info(0, "CjTelegram", "[RealMessageService] clearHistory stopped after 100 passes")
        return false
    }

    /**
     * 标记全部消息、@提及与 reaction 已读。
     *
     * 调用链:
     *   markAllRead → messages.readHistory(peer, Int32.Max) 标已读
     *              → messages.readMentions(peer) 标已读 @mentions
     *              → messages.readReactions(peer) 清除 unseen-reaction 标记
     *
     * @param peerType 对话类型（user/chat/channel）
     * @param peerId   对话 ID
     * @return 主 readHistory 请求是否成功；提及与 reaction 同步为 best effort
     */
    public func markAllRead(peerType: String, peerId: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] markAllRead: peer=${peerType}/${peerId}")
        let client = getMTProtoClient()

        // Step 1: messages.readHistory(maxId=Int32.Max-1)
        var readOk = false
        if (peerType == "channel") {
            let req = ChannelsReadHistory()
            let ch = InputChannel()
            ch.channelId = peerId
            if (this.channelAccessHashes.contains(peerId)) {
                ch.accessHash = this.channelAccessHashes[peerId]
            }
            req.channel = ch
            req.maxId = 2147483646  // Int32.Max - 1
            let resp = client.sendRequest(req.toBytes())
            readOk = checkSendResponse(resp, "markAllRead/channelsReadHistory")
        } else {
            let req = MessagesReadHistory()
            req.peer = buildInputPeer(peerType, peerId)
            req.maxId = 2147483646
            let resp = client.sendRequest(req.toBytes())
            readOk = checkSendResponse(resp, "markAllRead/readHistory")
        }

        // Step 2: messages.readMentions
        let mentionReq = MessagesReadMentions()
        mentionReq.peer = buildInputPeer(peerType, peerId)
        let mentionResp = client.sendRequest(mentionReq.toBytes())
        let mentionOk = checkSendResponse(mentionResp, "markAllRead/readMentions")

        // Step 3: messages.readReactions
        // iOS does this through ManagedSynchronizeMarkAllUnseenPersonalMessagesOperations
        // when the history consumes its unseen-reaction tag. A readHistory request does
        // not clear dialog.unread_reactions_count, so omitting this request leaves the
        // blue reaction bubble on Chats even though unread_count is already zero.
        var peerAccessHash: Int64 = 0
        if (normalizeDialogPeerType(peerType) == "channel") {
            peerAccessHash = this.getAccessHashForChannel(peerId)
        } else if (normalizeDialogPeerType(peerType) == "user") {
            peerAccessHash = this.getAccessHashForUser(peerId)
        }
        let reactionOk = this.readReactions(normalizeDialogPeerType(peerType), peerId, peerAccessHash)

        Hilog.info(0, "CjTelegram", "[RealMessageService] markAllRead: readOk=${readOk}, mentionOk=${mentionOk}, reactionOk=${reactionOk}")
        // mention/reaction failure is non-fatal: both are best-effort;
        // readHistory success is the primary contract for markAllRead.
        // We still surface both results in the log above for observability.
        return readOk
    }

    // ==================== P2-150b: Bots ====================

    /**
     * 启动 Bot 对话（对应 iOS messages.startBot）
     *
     * TL: messages.startBot#e6df7378 bot:InputUser peer:InputPeer random_id:long start_param:string = Updates
     * tl_codegen verified: 0xe6df7378 (telegram_api.tl:2238)
     *
     * 用途: 通过深链接 /start 或内联按钮启动 Bot。
     * startParam 可为空（直接 /start 不带参数）。
     *
     * @param botUserId    Bot 用户 ID
     * @param botAccessHash Bot 的 accessHash
     * @param peerType     对话类型
     * @param peerId       对话 ID（通常就是 bot 的 userId，私聊场景）
     * @param startParam   /start 后的 payload（如深链接参数），可空
     * @return 是否成功
     */
    public func startBot(
        botUserId: Int64,
        botAccessHash: Int64,
        peerType: String,
        peerId: Int64,
        startParam!: String = ""
    ): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] startBot: botId=${botUserId}, peerType=${peerType}, peerId=${peerId}, param=${startParam}")
        let client = getMTProtoClient()

        let botUser = InputUser()
        botUser.userId = botUserId
        botUser.accessHash = botAccessHash

        let req = MessagesStartBot()
        req.bot = botUser
        req.peer = buildInputPeer(peerType, peerId)
        req.randomId = generateRandomId()
        req.startParam = startParam

        let responseData = client.sendRequest(req.toBytes())
        let success = checkSendResponse(responseData, "startBot")
        if (success) {
            // messages.startBot returns the bot's visible messages in the same
            // Updates container as the send acknowledgement. Feed that response
            // through the normal update pipeline instead of relying on a later
            // difference poll, which can miss transient invoice media.
            getUpdatesManager().handleRawUpdate(responseData)
        }
        return success
    }

    /**
     * 获取内联 Bot 搜索结果（对应 iOS messages.getInlineBotResults）
     *
     * TL: messages.getInlineBotResults#514e999d flags:# bot:InputUser peer:InputPeer
     *     geo_point:flags.0?InputGeoPoint query:string offset:string = messages.BotResults
     * tl_codegen verified: 0x514e999d (telegram_api.tl:2247)
     *
     * Response: messages.botResults#e021f2f6 (tl_codegen verified: 0xe021f2f6, telegram_api.tl:795)
     *   query_id:long next_offset:?string results:Vector<BotInlineResult> cache_time:int users:Vector<User>
     *
     * 委托给 ChatContextQueryService.getInlineBotResults（已完整实现 TL 序列化和 response 解析）。
     * 调用链: getInlineBotResults → getChatContextQueryService().getInlineBotResults → MessagesGetInlineBotResults → server
     *
     * @param botUserId    Bot 用户 ID
     * @param botAccessHash Bot 的 accessHash
     * @param peerType     对话类型
     * @param peerId       对话 ID（内联查询的目标对话上下文）
     * @param peerAccessHash 对话 accessHash（user/channel 场景需要）
     * @param query        内联搜索词（@botname 后的字符串）
     * @param offset       翻页偏移（首次为空字符串）
     * @return ContextQueryResponse（含 queryId, nextOffset, items）
     */
    public func getInlineBotResults(
        botUserId: Int64,
        botAccessHash: Int64,
        peerType: String,
        peerId: Int64,
        peerAccessHash: Int64,
        query: String,
        offset!: String = ""
    ): ContextQueryResponse {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getInlineBotResults: botId=${botUserId}, query=${query}")
        // ChatContextQueryService owns the full TL implementation of messages.getInlineBotResults.
        // Delegate to avoid duplicating TL serialization and BotResults response parsing.
        return getChatContextQueryService().getInlineBotResults(
            botUserId,
            botAccessHash,
            peerId,
            peerAccessHash,
            peerType,
            query,
            offset: offset
        )
    }

    /**
     * 请求打开 Bot WebView（对应 iOS messages.requestWebView）
     *
     * TL: messages.requestWebView#269dc2c1 (tl_codegen verified: telegram_api.tl:2356)
     * Response: messages.webViewResultUrl#0a4028f9 query_id:long url:string
     *
     * 委托给 WebService.requestWebView（已完整实现 TL 序列化和 response 解析）。
     * 调用链: requestWebView → getWebService().requestWebView → MessagesRequestWebView → server
     *
     * @param botUserId    Bot 用户 ID
     * @param botAccessHash Bot 的 accessHash
     * @param peerType     对话类型（用于构建 peer accessHash；此处用 botAccessHash 作 peer）
     * @param peerId       对话 ID（peerUserId 在私聊场景即为 botUserId）
     * @param url          WebApp URL（可选，空字符串表示从 bot menu 打开）
     * @param startParam   deep-link start_param（可选）
     * @return 可加载的 WebApp URL 字符串（空字符串表示失败）
     */
    public func requestWebView(
        botUserId: Int64,
        botAccessHash: Int64,
        peerType: String,
        peerId: Int64,
        url!: String = "",
        startParam!: String = ""
    ): String {
        Hilog.info(0, "CjTelegram", "[RealMessageService] requestWebView: botId=${botUserId}, peerType=${peerType}, peerId=${peerId}")
        // WebService owns the full TL implementation of messages.requestWebView.
        // Delegate to avoid duplicating TL serialization and response parsing.
        let result = getWebService().requestWebView(
            peerId,
            botAccessHash,
            botUserId,
            botAccessHash,
            url: url,
            startParam: startParam
        )
        Hilog.info(0, "CjTelegram", "[RealMessageService] requestWebView: resultUrl=${result.url}, queryId=${result.queryId}")
        return result.url
    }

    // ==================== P2-150b: AI (Translate + Transcribe) ====================

    /**
     * 翻译消息文本（对应 iOS messages.translateText）
     *
     * TL: messages.translateText#63183030 flags:#
     *     peer:flags.0?InputPeer id:flags.0?Vector<int>
     *     text:flags.1?Vector<TextWithEntities> to_lang:string = messages.TranslatedText
     * tl_codegen verified: 0x63183030 (telegram_api.tl:2349)
     *
     * Response: messages.translateResult#33db32f8 result:Vector<TextWithEntities>
     * textWithEntities#751f3146 text:string entities:Vector<MessageEntity>
     * tl_codegen verified: 0x33db32f8 (telegram_api.tl:1606)
     *
     * 调用链: translateMessage → MessagesTranslateText(peer+id) → server → TranslateTextResult
     *
     * @param peerType 对话类型（mode 1: 翻译服务端消息）
     * @param peerId   对话 ID
     * @param msgIds   消息 ID 列表
     * @param toLang   目标语言代码（如 "en", "zh", "ru"）
     * @return TranslateTextResult（translations 列表对应 msgIds 顺序）
     */
    /**
     * 翻译单条消息文本（对应 iOS messages.translateText mode 1）
     *
     * TL: messages.translateText#63183030 (tl_codegen verified: telegram_api.tl:2349)
     *   peer:flags.0?InputPeer id:flags.0?Vector<int> to_lang:string = messages.TranslatedText
     * Response: messages.translateResult#33db32f8 result:Vector<TextWithEntities>
     * tl_codegen verified: 0x33db32f8 (telegram_api.tl:1606)
     *
     * 委托给 TranslateService.translateMessage（已完整实现 TL 序列化和 response 解析）。
     * 调用链: translateMessage → getTranslateService().translateMessage → MessagesTranslateText → server
     *
     * @param peerType       对话类型
     * @param peerId         对话 ID
     * @param peerAccessHash 对话 accessHash（user/channel 需要）
     * @param msgId          消息 ID（单条翻译）
     * @param toLang         目标语言代码（如 "en", "zh", "ru"）
     * @return TranslateResult（success + translatedText）
     */
    public func translateMessage(
        peerType: String,
        peerId: Int64,
        peerAccessHash: Int64,
        msgId: Int32,
        toLang: String
    ): TranslateResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] translateMessage: peer=${peerType}/${peerId}, msgId=${msgId}, toLang=${toLang}")
        // TranslateService owns the full TL implementation of messages.translateText.
        // Delegate to avoid duplicating TL serialization and response parsing.
        return getTranslateService().translateMessage(peerId, peerAccessHash, peerType, msgId, toLang)
    }

    /**
     * 翻译任意文本（对应 iOS messages.translateText mode 2 — text vector）
     *
     * TL: messages.translateText#63183030 (tl_codegen verified: telegram_api.tl:2349)
     *   text:flags.1?Vector<TextWithEntities> to_lang:string = messages.TranslatedText
     * Response: messages.translateResult#33db32f8 result:Vector<TextWithEntities>
     * tl_codegen verified: 0x33db32f8 (telegram_api.tl:1606)
     *
     * 委托给 TranslateService.translateText（已完整实现 TL 序列化和 response 解析）。
     * 调用链: translateText → getTranslateService().translateText → MessagesTranslateTextRaw → server
     *
     * @param text   要翻译的文本（单条）
     * @param toLang 目标语言代码
     * @return TranslateResult（success + translatedText）
     */
    public func translateText(text: String, toLang: String): TranslateResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] translateText: len=${text.size}, toLang=${toLang}")
        // TranslateService owns the full TL implementation of messages.translateText (raw text mode).
        // Delegate to avoid duplicating TL serialization and response parsing.
        return getTranslateService().translateText(text, toLang)
    }

    /**
     * 发起语音消息转文字（对应 iOS messages.transcribeAudio）
     *
     * TL: messages.transcribeAudio#269e9a49 peer:InputPeer msg_id:int = messages.TranscribedAudio
     * tl_codegen verified: 0x269e9a49 (telegram_api.tl:2361)
     *
     * Response: messages.transcribedAudio#cfb9d957 flags:# pending:flags.0?true
     *   transcription_id:long text:string
     *   trial_remains_num:flags.1?int trial_remains_until_date:flags.1?int
     * tl_codegen verified: 0xcfb9d957 (telegram_api.tl:1524)
     *
     * pending=true 表示转录仍在进行中，最终结果通过 updateTranscribedAudio 推送。
     * 调用链: transcribeAudio → MessagesTranscribeAudio.toBytes → server → TranscribeAudioResult
     *
     * @param peerType 对话类型
     * @param peerId   对话 ID
     * @param msgId    语音消息 ID
     * @return TranscribeAudioResult（text 为已转录文字；pending=true 表示还在处理中）
     */
    public func transcribeAudio(peerType: String, peerId: Int64, msgId: Int32): TranscribeAudioResult {
        Hilog.info(0, "CjTelegram", "[RealMessageService] transcribeAudio: peer=${peerType}/${peerId}, msgId=${msgId}")
        let client = getMTProtoClient()

        let req = MessagesTranscribeAudio()
        req.peer = buildInputPeer(peerType, peerId)
        req.msgId = msgId

        let responseData = client.sendRequest(req.toBytes())
        let result = TranscribeAudioResult()

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[RealMessageService] transcribeAudio: empty response")
            return result
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()

        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            result.errorCode = d.readInt32()
            result.errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[RealMessageService] transcribeAudio RPC error: ${result.errorCode} - ${result.errorMessage}")
            return result
        }

        // messages.transcribedAudio#cfb9d957 (tl_codegen verified: telegram_api.tl:1524)
        if (ctor == 0xcfb9d957) {
            let flags = d.readInt32()
            result.pending = (flags & 1) != 0
            result.transcriptionId = d.readInt64()
            result.text = d.readString()
            if ((flags & 2) != 0) {
                result.trialRemainsNum = d.readInt32()
                result.trialRemainsUntilDate = d.readInt32()
            }
            Hilog.info(0, "CjTelegram", "[RealMessageService] transcribeAudio: pending=${result.pending}, id=${result.transcriptionId}, text=${result.text.size}chars")
        } else {
            Hilog.info(0, "CjTelegram", "[RealMessageService] transcribeAudio: unknown ctor 0x${UInt32ToHex(ctor)}")
        }

        return result
    }

    // ==================== P2-150b: liveLocation edit (stop) ====================

    /**
     * 停止实时位置分享（对应 iOS editMessage + inputMediaGeoLive(stopped=true)）
     *
     * Telegram 停止实时位置的 TL 方式:
     *   messages.editMessage + media = inputMediaGeoLive#971fa843(stopped=true)
     *
     * TL: messages.editMessage#dfd14005 flags:# media:flags.14?InputMedia peer:InputPeer id:int
     * inputMediaGeoLive#971fa843 flags:# stopped:flags.0?true geo_point:InputGeoPoint ... = InputMedia
     * tl_codegen verified: 0x971fa843 (telegram_api.tl:69)
     *
     * 调用链: stopLiveLocation → MessagesEditMessage(closePoll=false, stopLiveLocation=true)
     *         → InputMediaGeoLive(stopped=true) → server → Bool
     *
     * @param peerType 对话类型
     * @param peerId   对话 ID
     * @param msgId    实时位置消息 ID
     * @return 是否成功停止
     */
    public func stopLiveLocation(peerType: String, peerId: Int64, msgId: Int32): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] stopLiveLocation: peer=${peerType}/${peerId}, msgId=${msgId}")
        let client = getMTProtoClient()

        let req = MessagesEditMessage()
        req.peer = buildInputPeer(peerType, peerId)
        req.id = msgId
        req.stopLiveLocation = true

        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "stopLiveLocation")
    }

    // ==================== P2-118: 群消息已读参与者 ====================

    /**
     * 拉取消息的已读参与者列表
     * messages.getMessageReadParticipants#31c1c44f peer:InputPeer msg_id:int
     * 返回 Vector<readParticipantDate#4a4ff172 user_id:long date:int>
     * iOS ref: Api42.swift:7407, Api22.swift:791
     *
     * 解析协议:
     *   [0x1cb5c415 VEC_CTOR][count:int32]
     *   [0x4a4ff172 item_ctor][user_id:int64][date:int32]  × count
     */
    public func getReadParticipants(peerType: String, peerId: Int64, msgId: Int32): ArrayList<ReadParticipantRecord> {
        let result = ArrayList<ReadParticipantRecord>()
        try {
            let client = getMTProtoClient()
            let req = MessagesGetMessageReadParticipants()
            req.peer = buildInputPeer(peerType, peerId)
            req.msgId = msgId
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 8) {
                Hilog.info(0, "CjTelegram", "[RealMsgSvc] getReadParticipants: response too short (${responseData.size}B)")
                return result
            }
            // Parse response: expect vector constructor 0x1cb5c415 then count then items
            var i: Int64 = 0
            let vecCtor = readUInt32LE(responseData, i)
            i += 4
            if (vecCtor != 0x1cb5c415) {
                Hilog.info(0, "CjTelegram", "[RealMsgSvc] getReadParticipants: unexpected vec ctor=${vecCtor}")
                return result
            }
            let count = readInt32LE(responseData, i)
            i += 4
            Hilog.info(0, "CjTelegram", "[RealMsgSvc] getReadParticipants: ${count} participants for msgId=${msgId}")
            var idx: Int32 = 0
            while (idx < count && i + 16 <= Int64(responseData.size)) {
                let itemCtor = readUInt32LE(responseData, i)
                i += 4
                // readParticipantDate#4a4ff172 user_id:long date:int
                if (itemCtor == 0x4a4ff172) {
                    let userId = readInt64LE(responseData, i)
                    i += 8
                    let date = readInt32LE(responseData, i)
                    i += 4
                    let rec = ReadParticipantRecord()
                    rec.userId = userId
                    rec.date = date
                    result.add(rec)
                } else {
                    // Unknown item — skip safely (8+4 bytes = 12)
                    i += 12
                    Hilog.info(0, "CjTelegram", "[RealMsgSvc] getReadParticipants: unknown item ctor=${itemCtor}, skipping")
                }
                idx += 1
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealMsgSvc] getReadParticipants exception: ${e}")
        }
        return result
    }

    // ==================== P2-AUDIT-coverage: confirmed-missing TL wires ====================

    /**
     * updates.getChannelDifference#03173d78 — 频道增量更新同步
     *
     * 获取自上次同步点（pts）以来频道产生的所有更新。
     * 调用链: getChannelDifference → UpdatesGetChannelDifference.toBytes → MTProtoClient
     *
     * @param channelId         频道 ID
     * @param channelAccessHash 频道 access hash
     * @param pts               上次同步时的 pts 值
     * @param limit             最多返回条目数（通常 100）
     * @return 原始响应字节（调用方自行解析 updates.ChannelDifference）
     */
    public func getChannelDifference(channelId: Int64, channelAccessHash: Int64, pts: Int32, limit!: Int32 = 100): Array<Byte> {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getChannelDifference: channelId=${channelId}, pts=${pts}")
        let client = getMTProtoClient()
        let req = UpdatesGetChannelDifference()
        req.channelId = channelId
        req.channelAccessHash = channelAccessHash
        req.pts = pts
        req.limit = limit
        return client.sendRequest(req.toBytes())
    }

    /**
     * messages.getMessages#63c66506 — 按 ID 批量拉取消息（用户/私聊场景）
     *
     * 对应 iOS Api42.swift:7423 messages.getMessages
     * 适用于普通用户/私聊消息获取；频道消息请用 getChannelMessages。
     *
     * @param ids 消息 ID 列表
     * @return 原始响应字节（messages.Messages）
     */
    public func getMessagesByIds(ids: ArrayList<Int32>): Array<Byte> {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getMessagesByIds: count=${ids.size}")
        if (ids.isEmpty()) { return Array<Byte>(0, repeat: 0) }
        let client = getMTProtoClient()
        let req = MessagesGetMessages()
        req.ids = ids
        return client.sendRequest(req.toBytes())
    }

    /**
     * channels.getMessages#ad8c9a23 — 按 ID 批量拉取频道消息
     *
     * @param channelId         频道 ID
     * @param channelAccessHash 频道 access hash
     * @param ids               消息 ID 列表
     * @return 原始响应字节（messages.Messages）
     */
    public func getChannelMessages(channelId: Int64, channelAccessHash: Int64, ids: ArrayList<Int32>): Array<Byte> {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getChannelMessages: channelId=${channelId}, count=${ids.size}")
        if (ids.isEmpty()) { return Array<Byte>(0, repeat: 0) }
        let client = getMTProtoClient()
        let req = ChannelsGetMessages()
        req.channelId = channelId
        req.channelAccessHash = channelAccessHash
        req.ids = ids
        return client.sendRequest(req.toBytes())
    }

    /**
     * messages.readReactions#9ec44f93 — 清除对话未读 reactions 徽标
     *
     * 对应 iOS: 清除 unreadReactionsCount 后调用此接口。
     *
     * @param peerType         对话类型
     * @param peerId           对话 ID
     * @param peerAccessHash   access hash
     * @return 是否成功（Bool response）
     */
    public func readReactions(peerType: String, peerId: Int64, peerAccessHash: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] readReactions: peer=${peerType}/${peerId}")
        let client = getMTProtoClient()
        let req = MessagesReadReactions()
        req.peerType = peerType
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "readReactions")
    }

    /**
     * messages.readDiscussion#f731a9f4 — 标记讨论帖子已读
     *
     * 用于频道帖子下的评论区已读标记。
     *
     * @param peerType         频道的 peer 类型
     * @param peerId           频道 ID
     * @param peerAccessHash   频道 access hash
     * @param msgId            帖子消息 ID
     * @param readMaxId        已读到的最大消息 ID
     * @return 是否成功
     */
    public func readDiscussion(peerType: String, peerId: Int64, peerAccessHash: Int64, msgId: Int32, readMaxId: Int32): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] readDiscussion: peer=${peerType}/${peerId}, msgId=${msgId}")
        let client = getMTProtoClient()
        let req = MessagesReadDiscussion()
        req.peerType = peerType
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.msgId = msgId
        req.readMaxId = readMaxId
        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "readDiscussion")
    }

    /**
     * messages.getPeerDialogs#e470bcfd — 批量拉取对话元数据
     *
     * 拉取单个 peer 的对话信息（read-max-id、unread counts 等）。
     *
     * @param peerType       peer 类型
     * @param peerId         peer ID
     * @param peerAccessHash access hash
     * @return 原始响应字节（messages.PeerDialogs）
     */
    public func getPeerDialogs(peerType: String, peerId: Int64, peerAccessHash: Int64): Array<Byte> {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getPeerDialogs: peer=${peerType}/${peerId}")
        let client = getMTProtoClient()
        let req = MessagesGetPeerDialogs()
        req.peerType = peerType
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        return client.sendRequest(req.toBytes())
    }

    /**
     * channels.joinChannel#7f6a1e22 — 加入公开频道
     *
     * @param channelId         频道 ID
     * @param channelAccessHash 频道 access hash（公开频道通常为 0 或 server-provided）
     * @return 是否成功（服务端返回 Updates）
     */
    public func joinChannel(channelId: Int64, channelAccessHash: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] joinChannel: channelId=${channelId}")
        let client = getMTProtoClient()
        let req = ChannelsJoinChannel()
        req.channelId = channelId
        req.channelAccessHash = channelAccessHash
        let responseData = client.sendRequest(req.toBytes())
        let ok = checkSendResponse(responseData, "joinChannel")
        if (ok) {
            getRealChatListService().clearDialogRemoved("channel", channelId)
        }
        return ok
    }

    /**
     * account.updateStatus#6628562c — 上报自己的在线/离线状态
     *
     * @param offline true = 离线；false = 在线
     * @return 是否成功
     */
    public func updateMyOnlineStatus(offline: Bool): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] updateMyOnlineStatus: offline=${offline}")
        let client = getMTProtoClient()
        let req = AccountUpdateStatus()
        req.offline = offline
        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "updateStatus")
    }

    /**
     * messages.getBotCallbackAnswer#9342ca07 — 处理内联键盘按钮点击
     *
     * @param peerType       peer 类型
     * @param peerId         peer ID
     * @param peerAccessHash access hash
     * @param msgId          包含按钮的消息 ID
     * @param callbackData   按钮携带的回调数据（可为空）
     * @return 原始响应字节（messages.BotCallbackAnswer）
     */
    public func getBotCallbackAnswer(peerType: String, peerId: Int64, peerAccessHash: Int64, msgId: Int32, callbackData: Array<Byte>): Array<Byte> {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getBotCallbackAnswer: peer=${peerType}/${peerId}, msgId=${msgId}")
        let client = getMTProtoClient()
        let req = MessagesGetBotCallbackAnswer()
        req.peerType = peerType
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.msgId = msgId
        req.hasData = callbackData.size > 0
        req.callbackData = callbackData
        return client.sendRequest(req.toBytes())
    }

    /**
     * messages.getWebPagePreview#570d6f6f — 获取 URL 链接预览
     *
     * @param messageText 包含链接的消息文本
     * @return 原始响应字节（messages.WebPagePreview）
     */
    public func getWebPagePreview(messageText: String): Array<Byte> {
        Hilog.info(0, "CjTelegram", "[RealMessageService] getWebPagePreview: text.len=${messageText.size}")
        let client = getMTProtoClient()
        let req = MessagesGetWebPagePreview()
        req.message = messageText
        return client.sendRequest(req.toBytes())
    }

    /**
     * messages.sendScreenshotNotification#a1405817 — 发送截图通知
     *
     * @param peerType       peer 类型
     * @param peerId         peer ID
     * @param peerAccessHash access hash
     * @param replyToMsgId   截图针对的消息 ID
     * @return 是否成功
     */
    public func sendScreenshotNotification(peerType: String, peerId: Int64, peerAccessHash: Int64, replyToMsgId: Int32): Bool {
        Hilog.info(0, "CjTelegram", "[RealMessageService] sendScreenshotNotification: peer=${peerType}/${peerId}")
        let client = getMTProtoClient()
        let req = MessagesSendScreenshotNotification()
        req.peerType = peerType
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.replyToMsgId = replyToMsgId
        req.randomId = Int64(RealMessageService._rand.nextInt64())
        let responseData = client.sendRequest(req.toBytes())
        return checkSendResponse(responseData, "sendScreenshotNotification")
    }
}

/**
 * P2-118: 已读参与者记录（messages.getMessageReadParticipants 响应条目）
 * 对应 iOS Api22.swift: ReadParticipantDate.Cons_readParticipantDate { userId: Int64, date: Int32 }
 */
public class ReadParticipantRecord {
    public var userId: Int64 = 0
    public var date: Int32 = 0
    public var displayName: String = ""
    public init() {}
}

/**
 * TLStringResult — TL string 解析辅助值对象 (P2-116)
 * 用于 RealMessageService.readTLString() 返回 (value, nextOffset) 对
 */
public class TLStringResult {
    public var value: String = ""
    public var nextOffset: Int64 = 0
    public init() {}
}

/** 按字符数截断（超出补 "..."），对多字节 UTF-8 安全。 */
public func truncateRunes(text: String, maxRunes: Int64): String {
    let runes = text.toRuneArray()
    if (runes.size <= maxRunes) { return text }
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i < maxRunes) {
        sb.append(runes[i])
        i += 1
    }
    sb.append("...")
    return sb.toString()
}

/** 取首个字符（头像首字母等），对多字节 UTF-8 安全；空串返回 fallback。 */
public func firstRuneString(text: String, fallback!: String = "?"): String {
    let runes = text.toRuneArray()
    if (runes.size == 0) { return fallback }
    return runes[0].toString()
}

/** iOS timeIntervalString(.generic, preferLowerValue: false)（NumericFormat.swift:106-121）。 */
func autoremoveIntervalText(value: Int32): String {
    let v = Int64(value)
    func unit(n: Int64, one: String, many: String): String {
        return if (n == 1) { "1 ${one}" } else { "${n} ${many}" }
    }
    if (v < 60) { return unit(if (v < 1) { 1 } else { v }, "second", "seconds") }
    if (v < 3600) { return unit(v / 60, "minute", "minutes") }
    if (v < 86400) { return unit(v / 3600, "hour", "hours") }
    if (v < 86400 * 7) { return unit(v / 86400, "day", "days") }
    if (v < 86400 * 30) { return unit(v / (86400 * 7), "week", "weeks") }
    if (v < 86400 * 365) { return unit(v / (86400 * 30), "month", "months") }
    return unit(v / (86400 * 365), "year", "years")
}

/** iOS ServiceMessageStrings.swift:438-510（Conversation.AutoremoveTimer* 文案）。 */
func autoremoveServiceText(period: Int32, autoFrom: Int64, fromSelf: Bool, currentUserId: Int64, authorName: String,
    peerType: String, isBroadcast: Bool): String {
    if (period > 0) {
        let t = autoremoveIntervalText(period)
        if (peerType == "user") {
            if (autoFrom != 0) {
                if (autoFrom == currentUserId) {
                    return "You set a self-destruct timer for all chats.\nAll new messages in this chat will be automatically deleted after ${t} they're sent."
                }
                return "${authorName} set a self-destruct timer for all chats.\nAll new messages in this chat will be automatically deleted after ${t} they're sent."
            }
            if (fromSelf) { return "You set messages to automatically delete after ${t}" }
            return "${authorName} set messages to automatically delete after ${t}"
        }
        if (fromSelf) { return "You set messages to automatically delete after ${t}" }
        if (peerType == "channel" && isBroadcast) { return "Messages in this channel will be automatically deleted after ${t}" }
        return "A group admin set messages to automatically delete after ${t}"
    }
    if (peerType == "user") {
        if (fromSelf) { return "You disabled the auto-delete timer" }
        return "${authorName} disabled the auto-delete timer"
    }
    if (fromSelf) { return "You disabled the auto-delete timer" }
    if (peerType == "channel" && isBroadcast) { return "Messages in this channel will no longer be automatically deleted" }
    return "A group admin disabled the auto-delete timer"
}

/**
 * 升级超级群的会话视图里，旧基础群消息的 id 映射（id - 2^31）：两个 peer 在服务端各自编号，
 * 映射到负数区间后保序、不与超级群云消息 / 本地消息 id 相撞。历史并入（ChatRoomViewModel）与
 * 会话内搜索跳转共用这一个映射。
 */
public func migratedHistoryViewId(originalId: Int64): Int64 {
    return originalId - 2147483648
}
