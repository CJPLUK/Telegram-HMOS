package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.models.WidgetData
import ohos_app_cangjie_entry.models.WidgetDataPeer
import ohos_app_cangjie_entry.models.WidgetDataPeers
import ohos_app_cangjie_entry.models.WidgetBadge
import ohos_app_cangjie_entry.models.WidgetMessage
import ohos_app_cangjie_entry.models.WidgetMessageContent
import ohos_app_cangjie_entry.models.WidgetMessageAuthor
import ohos_app_cangjie_entry.models.WidgetContentImage
import ohos_app_cangjie_entry.models.WidgetContentVideo
import ohos_app_cangjie_entry.models.WidgetContentVideoMessage
import ohos_app_cangjie_entry.models.WidgetContentVoiceMessage
import ohos_app_cangjie_entry.models.WidgetContentMusic
import ohos_app_cangjie_entry.models.WidgetContentSticker
import ohos_app_cangjie_entry.models.WidgetContentGif
import ohos_app_cangjie_entry.models.WidgetContentFile
import ohos_app_cangjie_entry.models.WidgetContentCall
import ohos_app_cangjie_entry.models.WidgetContentMapLocation
import ohos_app_cangjie_entry.models.WidgetContentPoll
import ohos_app_cangjie_entry.models.WidgetContentGame
import ohos_app_cangjie_entry.models.WidgetContentAutodeleteTimer
import std.collection.ArrayList
import std.time.DateTime

/**
 * WidgetItemsServiceV2 — P2-431/432/433
 *
 * 升级版 widget 数据服务，使用 WidgetDataModel (P2-431) 的 14 类型枚举
 * 替代 D-版 WidgetPeerItem.lastMessage:String 扁平化。
 *
 * 核心改进（相比 WidgetItemsService）：
 *   P2-431: 每个 WidgetDataPeer 携带完整结构（letters/isForum/badge/message 富类型）
 *   P2-432: message.content 通过 WidgetMediaMapper.mapMessageToWidgetContent() 真归类
 *   P2-433: buildPreviewText() 按 content 类型生成结构化预览文案
 *
 * [widget-host:P2-435] 接线点：
 *   serializeToJson() / getWidgetData() 输出供 P2-436 写入 distributedKVStore。
 *   FormExtensionAbility 卡片宿主由 P2-435 实现，本服务不涉及卡片 API。
 *
 * Saved Messages 特例：
 *   若会话 id == accountPeerId（isSavedMessages 标记），显示名 "Saved Messages"。
 * Locked 特例：
 *   WidgetData.hasUnlockedForLockId == false 时，UI 层显示 "Locked" 提示
 *   而非真实会话列表（passcode 锁屏期间，对应 iOS generalLockedTitle）。
 *
 * 调用链：
 *   refreshWidgetData()
 *     → getRealChatListService().getDialogs(limit: 8)
 *     → buildWidgetDataPeer(chat) [for each chat]
 *       → mapMessageToWidgetContent(msg)
 *     → WidgetData.serializeToJson()
 */
private var _widgetItemsServiceV2Instance: Option<WidgetItemsServiceV2> = None

public func getWidgetItemsServiceV2(): WidgetItemsServiceV2 {
    match (_widgetItemsServiceV2Instance) {
        case Some(inst) => return inst
        case None =>
            let inst = WidgetItemsServiceV2()
            _widgetItemsServiceV2Instance = Some(inst)
            return inst
    }
}

public class WidgetItemsServiceV2 {
    private var cachedWidgetData: Option<WidgetData> = None
    private var lastRefreshTimestamp: Int64 = 0
    private static let MAX_WIDGET_PEERS: Int32 = 8
    // 当前账号 peerId（用于 Saved Messages 判断和 isMe author 判断）
    // 默认 0 = 未设置
    private var accountPeerId: Int64 = 0

    /**
     * 设置当前账号 peerId（LoginService 登录后调用）
     */
    public func setAccountPeerId(peerId: Int64): Unit {
        this.accountPeerId = peerId
    }

    /**
     * 获取当前账号 peerId
     */
    public func getAccountPeerId(): Int64 {
        return this.accountPeerId
    }

    /**
     * 获取缓存的 WidgetData（不触发网络请求）
     */
    public func getCachedWidgetData(): Option<WidgetData> {
        return this.cachedWidgetData
    }

    /**
     * 获取最后刷新时间戳（毫秒）
     */
    public func getLastRefreshTimestamp(): Int64 {
        return this.lastRefreshTimestamp
    }

    /**
     * 刷新 widget 数据（全流程：网络→富类型归类→缓存）
     *
     * 调用链：
     *   refreshWidgetData()
     *     → getRealChatListService().getDialogs(limit: 8)
     *     → buildWidgetDataPeer(chat) × N
     *       → mapMessageToWidgetContent(syntheticMsg)
     *     → WidgetData(content: peers, unlockedForLockId)
     *
     * @param unlockedForLockId 若非空表示已解锁（P2-431 锁屏态字段）
     * @return 构造好的 WidgetData
     */
    public func refreshWidgetData(unlockedForLockId!: String = ""): WidgetData {
        Hilog.info(0, "CjTelegram", "[WidgetItemsServiceV2] refreshWidgetData start")
        let chatService = getRealChatListService()
        let dialogs: ArrayList<Chat> = chatService.getDialogs(limit: 8)
        Hilog.info(0, "CjTelegram", "[WidgetItemsServiceV2] got ${dialogs.size} dialogs")

        let peers = ArrayList<WidgetDataPeer>()
        var count: Int32 = 0
        for (chat in dialogs) {
            if (count >= WidgetItemsServiceV2.MAX_WIDGET_PEERS) { break }
            let peer = this.buildWidgetDataPeer(chat)
            peers.add(peer)
            count = count + 1
        }

        let peersArray = Array<WidgetDataPeer>(peers.size, { i: Int64 => peers[i] })
        let now = DateTime.now()
        let ts = Int32(now.toUnixTimeStamp().toMilliseconds() / 1000)

        let widgetDataPeers = WidgetDataPeers(
            accountPeerId: this.accountPeerId,
            peers: peersArray,
            updateTimestamp: ts)

        let hasLock = (unlockedForLockId.size > 0)
        let widgetData = WidgetData(
            accountId: this.accountPeerId,
            content: Some(widgetDataPeers),
            unlockedForLockId: unlockedForLockId,
            hasUnlockedForLockId: hasLock)

        this.cachedWidgetData = Some(widgetData)
        this.lastRefreshTimestamp = now.toUnixTimeStamp().toMilliseconds()
        Hilog.info(0, "CjTelegram", "[WidgetItemsServiceV2] cache updated: ${peers.size} peers")
        return widgetData
    }

    /**
     * 序列化当前缓存为 JSON（供 P2-436 写入共享存储）
     *
     * [widget-host:P2-435] 接线点：
     *   P2-436 将调用此方法后 put 到 distributedKVStore / Preferences。
     */
    public func serializeToJson(): String {
        match (this.cachedWidgetData) {
            case Some(d) => return d.serializeToJson()
            case None => return "{\"accountId\":0,\"content\":null,\"unlockedForLockId\":null}"
        }
    }

    // ============================================================
    // 核心构造：Chat → WidgetDataPeer (P2-431 数据模型)
    // ============================================================

    private func buildWidgetDataPeer(chat: Chat): WidgetDataPeer {
        let peer = WidgetDataPeer()
        peer.id = chat.id

        // Saved Messages 特例（iOS: id == accountPeerId → name = "Saved Messages"）
        if (chat.isSavedMessages || (this.accountPeerId != 0 && chat.id == this.accountPeerId)) {
            peer.name = "Saved Messages"
            peer.letters = Array<String>(1, repeat: "S")
        } else {
            peer.name = chat.name
            // letters[]: 从 avatarText 提取字符（iOS: WidgetDataPeer.letters 通常 1-2 字母）
            peer.letters = buildLetters(chat.avatarText)
        }

        // avatarPath
        if (chat.avatarLocalPath.size > 0) {
            peer.avatarPath = chat.avatarLocalPath
            peer.hasAvatarPath = true
        }

        // isForum（iOS: TelegramChannel.flags.isForum）
        // 仓颉侧 Chat 无直接 isForum 字段，以 isChannel && isMegagroup 近似
        peer.isForum = chat.isChannel && chat.isMegagroup

        // badge（未读数）
        if (chat.unreadCount > 0) {
            peer.badge = Some(WidgetBadge(
                count: Int32(chat.unreadCount),
                isMuted: chat.isMuted))
        }

        // message（最后一条消息，内容类型富归类）
        peer.message = Some(this.buildWidgetMessage(chat))

        return peer
    }

    /**
     * 从 Chat 构造 WidgetMessage（P2-432 媒体归类）
     *
     * Chat.lastMessageType 已包含媒体类型信号（photo/video/voice/sticker/file/...），
     * 用 mapChatToWidgetContent() 直接归类。
     */
    private func buildWidgetMessage(chat: Chat): WidgetMessage {
        let content = mapChatToWidgetContent(chat)

        // 群消息 author 归属（P2-432: isGroup/isMegagroup + lastMessageSenderName）
        var author: Option<WidgetMessageAuthor> = None
        if (chat.isGroup || chat.isMegagroup) {
            let senderName = chat.lastMessageSenderName
            if (senderName.size > 0) {
                let isMe = chat.lastMessageOutgoing || senderName == "You"
                author = Some(WidgetMessageAuthor(
                    isMe: isMe,
                    title: if (isMe) { "You" } else { senderName }))
            }
        }

        let now = DateTime.now()
        let ts = Int32(now.toUnixTimeStamp().toMilliseconds() / 1000)

        return WidgetMessage(
            author: author,
            text: chat.lastMessage,
            content: content,
            timestamp: if (chat.lastMessageTimestamp > 0) { Int32(chat.lastMessageTimestamp) } else { ts })
    }

    /**
     * 从 Chat.lastMessageType 归类 WidgetMessageContent（P2-432 媒体遍历归类简化版）
     *
     * Chat 模型目前只有 lastMessageType:String 信号，
     * 而非完整 Message 对象——使用 mapChatLastMessageTypeToContent() 直接映射。
     */
    private func mapChatToWidgetContent(chat: Chat): WidgetMessageContent {
        let mtype = chat.lastMessageType
        if (mtype == "photo") {
            return WidgetMessageContent.ContentImage(WidgetContentImage())
        }
        if (mtype == "video") {
            return WidgetMessageContent.ContentVideo(
                WidgetContentVideo())
        }
        if (mtype == "videoNote" || mtype == "round") {
            return WidgetMessageContent.ContentVideoMessage(
                WidgetContentVideoMessage(duration: 0))
        }
        if (mtype == "voice") {
            return WidgetMessageContent.ContentVoiceMessage(
                WidgetContentVoiceMessage(duration: 0))
        }
        if (mtype == "audio" || mtype == "music") {
            return WidgetMessageContent.ContentMusic(
                WidgetContentMusic(
                    artist: "", title: chat.lastMessage, duration: 0))
        }
        if (mtype == "sticker") {
            return WidgetMessageContent.ContentSticker(
                WidgetContentSticker(altText: ""))
        }
        if (mtype == "gif" || mtype == "animation") {
            return WidgetMessageContent.ContentGif(
                WidgetContentGif())
        }
        if (mtype == "file" || mtype == "document") {
            return WidgetMessageContent.ContentFile(
                WidgetContentFile(name: chat.lastMessage))
        }
        if (mtype == "call") {
            return WidgetMessageContent.ContentCall(
                WidgetContentCall(isVideo: false))
        }
        if (mtype == "videoCall") {
            return WidgetMessageContent.ContentCall(
                WidgetContentCall(isVideo: true))
        }
        if (mtype == "map" || mtype == "location") {
            return WidgetMessageContent.ContentMapLocation(
                WidgetContentMapLocation())
        }
        if (mtype == "poll") {
            return WidgetMessageContent.ContentPoll(
                WidgetContentPoll(title: chat.lastMessage))
        }
        if (mtype == "game") {
            return WidgetMessageContent.ContentGame(
                WidgetContentGame(title: chat.lastMessage))
        }
        if (mtype == "autoDeleteTimer") {
            return WidgetMessageContent.ContentAutodeleteTimer(
                WidgetContentAutodeleteTimer(value: 0, hasValue: false))
        }
        return WidgetMessageContent.ContentText
    }
}

// ============================================================
// letters[] 构造工具（iOS: WidgetDataPeer.letters = [String]）
// 从 avatarText 提取 1-2 个字母用于头像显示
// ============================================================

private func buildLetters(avatarText: String): Array<String> {
    if (avatarText.size == 0) {
        return Array<String>(0, repeat: "")
    }
    let runes = avatarText.toRuneArray()
    if (runes.size == 0) {
        return Array<String>(0, repeat: "")
    }
    if (runes.size == 1) {
        return [runes[0].toString()]
    }
    // 2 letters: 首字母 + 空格分隔的第二个词首字母
    var secondIdx: Int64 = -1
    var i: Int64 = 1
    while (i < runes.size) {
        if (runes[i] == r' ') {
            if (i + 1 < runes.size) {
                secondIdx = i + 1
            }
            break
        }
        i = i + 1
    }
    if (secondIdx >= 0) {
        return [runes[0].toString(), runes[secondIdx].toString()]
    }
    return [runes[0].toString()]
}
