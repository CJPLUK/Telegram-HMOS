package ohos_app_cangjie_entry.models

import kit.ArkUI.*
import std.collection.ArrayList

/**
 * 消息数据模型（Phase A1 增强版）
 * 
 * 对应 TelegramHarmony 的 core/models/Message.ets
 * 
 * 纯数据类，不使用 @Observed（在后台线程创建，@Publish 会触发主线程检查异常）
 * UI 更新通过 ChatRoomViewModel 的 @Publish messages 整体替换驱动
 */
public class Message {
    // ==================== 基础字段 ====================
    public var id: Int64 = 0
    public var content: String = ""
    public var time: String = ""
    public var rawTimestamp: Int64 = 0
    public var isSent: Bool = false
    public var status: String = "sent"
    public var senderId: Int64 = 0
    public var senderName: String = ""
    // TL from_id 的 peer 命名空间。匿名管理员以群/频道身份发言时，
    // senderId 不是用户 ID，UI 需要据此使用群名和群头像语义。
    public var senderPeerType: String = "user"
    // iOS authorRank：群主显示 owner，自定义管理员头衔优先，否则显示 admin。
    public var senderRole: String = ""

    /**
     * 消息命名空间 —— 参与全序排序，缺它则同一秒内本地待发消息会排到已收消息前面。
     *
     * 对齐 iOS：
     *   - Namespaces.Message.Cloud = 0 / .Local = 1
     *     (Telegram-iOS/submodules/TelegramCore/Sources/SyncCore/SyncCore_Namespaces.swift:6-7)
     *   - MessageIndex.< 的比较优先级为 timestamp → **namespace** → id → peerId
     *     (Telegram-iOS/submodules/Postbox/Sources/Message.swift:236-250)
     *
     * 为什么必须有：本地待发消息用 ChatRoomViewModel.messageIdCounter 计数器 id（初值 100），
     * 服务端消息 id≈1100。同一秒内按 id 排序会把待发消息排到已收消息**前面**；
     * iOS 靠 namespace（Cloud=0 < Local=1）把待发压在同秒云消息之后，而不是靠 id。
     * 真机实测见 PROBE-V3 ①。
     *
     * 默认 0（Cloud）：所有从服务端解析出的消息天然正确，无需逐处赋值；
     * 只有本地构造的待发消息需在 stampLocalMessage 里置 1，发送成功后随服务端消息覆盖回 0。
     */
    public var namespace: Int32 = 0

    /**
     * 列表身份 —— **独立于 id**，由 MessageHistoryView 在首次入列时分配，此后终身不变。
     *
     * 为什么需要它：本地消息发出后 id 会从计数器号换成服务端号（实测 101→513）。
     * id 一变，ForEach 就认为「这是另一条消息」，销毁旧组件、创建新组件
     * （《ForEach 键值生成规则》：键值变化时「视为该数组元素已被替换或修改，
     * 并会基于新的键值创建一个新的组件」）——表现为刚发出的气泡在 84ms 后闪一下。
     * 实测确认：把 status 的变化排除后仍闪，故真凶是 id。
     *
     * 对齐 iOS：
     *   - Message.stableId: UInt32，与 MessageId 完全独立
     *     (Telegram-iOS/submodules/Postbox/Sources/Message.swift:689)
     *   - 分配：customStableId ?? historyMetadataTable.getNextStableMessageIndexId()
     *     (MessageHistoryTable.swift:1090)
     *   - **本地转云端时沿用旧值**：updateMessage 里 `var stableId = previousMessage.stableId`
     *     (MessageHistoryTable.swift:1831)
     *   - UI 身份取它：`UInt64(message.stableId) | (type << 40)`
     *     (ChatHistoryEntry.swift:74)
     *
     * 0 表示尚未入列（例如刚 parse 出来、还没进 MessageHistoryView）。
     */
    public var stableId: Int64 = 0

    /**
     * 供列表 key 使用的身份值：优先 stableId，未入列时退回 id。
     * 退回分支保证「尚未进入 MessageHistoryView 的消息」（搜索结果等）仍有唯一键。
     */
    public func identityKey(): Int64 {
        if (this.stableId != 0) {
            return this.stableId
        }
        return this.id
    }
    
    // ==================== A1: 消息类型 ====================
    public var messageType: String = "text"
    public var mediaDescription: String = ""
    
    // ==================== A1: 回复相关 ====================
    public var replyToMsgId: Int64 = 0
    public var replyToText: String = ""
    public var replyToSenderName: String = ""
    
    // ==================== A1: 转发相关 ====================
    public var forwardFromName: String = ""

    // ==================== S2-96: 联系人卡片 ====================
    // messageMediaContact 的号码与姓名（iOS TelegramMediaContact.phoneNumber / firstName / lastName）
    public var contactPhone: String = ""
    public var contactDisplayName: String = ""
    
    // ==================== A1: 状态标记 ====================
    public var isEdited: Bool = false
    public var isPinned: Bool = false
    
    // ==================== A1: 频道信息 ====================
    public var views: Int64 = 0
    // S5-04: messageReplies（iOS ReplyThreadMessageAttribute）：评论/回复数与讨论群
    public var repliesCount: Int32 = 0
    public var repliesIsComments: Bool = false
    public var repliesChannelId: Int64 = 0
    
    // ==================== 照片相关 ====================
    public var photoId: Int64 = 0
    public var photoAccessHash: Int64 = 0
    public var photoFileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var photoDcId: Int32 = 0
    public var photoWidth: Int32 = 0
    public var photoHeight: Int32 = 0
    public var photoFileSize: Int32 = 0
    // 最大分辨率变体 type（s/m/x/y/w）——保存/全分辨率下载选它，对齐 iOS 选最大表示
    public var photoLargestType: String = ""
    public var strippedThumb: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var photoLocalPath: String = ""
    
    // ==================== Phase H: 文档/视频/语音/文件元数据 ====================
    public var documentId: Int64 = 0
    public var documentAccessHash: Int64 = 0
    public var documentFileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var documentDcId: Int32 = 0
    public var documentSize: Int64 = 0
    public var documentMimeType: String = ""
    public var documentFileName: String = ""
    public var videoDuration: Int32 = 0
    public var videoWidth: Int32 = 0
    public var videoHeight: Int32 = 0
    public var audioDuration: Int32 = 0
    public var audioTitle: String = ""
    public var audioPerformer: String = ""
    public var audioWaveform: Array<Byte> = Array<Byte>(0, repeat: 0)
    // media_unread：语音/圆视频尚未被收听（iOS ConsumableContentMessageAttribute.consumed == false）
    public var mediaUnread: Bool = false
    // ttl_period：消息自动删除计时（秒），0 = 无（iOS minAutoremoveOrClearTimeout）
    public var ttlPeriod: Int32 = 0
    public var stickerAlt: String = ""
    public var webPageUrl: String = ""
    public var webPageSiteName: String = ""
    public var webPageTitle: String = ""
    public var webPageDescription: String = ""
    public var webPagePhotoId: Int64 = 0
    public var webPagePhotoAccessHash: Int64 = 0
    public var webPagePhotoFileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var webPagePhotoDcId: Int32 = 0
    public var webPagePhotoWidth: Int32 = 0
    public var webPagePhotoHeight: Int32 = 0
    public var webPagePhotoLocalPath: String = ""
    public var documentLocalPath: String = ""
    // Preview resource for image documents. Kept separate from documentLocalPath so
    // opening a thumbnail never masquerades as opening the original file.
    public var documentThumbnailPath: String = ""

    // ==================== Bot invoice ====================
    public var invoiceTitle: String = ""
    public var invoiceDescription: String = ""
    public var invoiceCurrency: String = ""
    public var invoiceTotalAmount: Int64 = 0
    public var invoiceStartParam: String = ""
    public var invoiceReceiptMsgId: Int32 = 0
    public var invoicePaymentButtonTitle: String = ""
    
    // ==================== Phase I6/Q11: 富文本实体 ====================
    public var textEntities: String = ""
    public var textEntityList: ArrayList<TextEntityData> = ArrayList<TextEntityData>()
    public var isFileDownloading: Bool = false
    // S7-93: photo fetch state for the bubble placeholder. 0 = automatic (loading),
    // 1 = automatic download suppressed by the auto-download settings (show the download
    // button), 2 = user-requested download in progress.
    public var photoDownloadState: Int32 = 0
    
    // ==================== Phase P5-13: 位置消息 ====================
    
    public var locationLat: Float64 = 0.0
    public var locationLng: Float64 = 0.0
    public var isLiveLocation: Bool = false
    public var liveLocationPeriod: Int32 = 0
    // P2-180: server-provided heading from messageMediaGeoLive (flags.0 heading field)
    // -1 = no heading data; 0..359 = heading in degrees
    public var locationHeading: Int32 = -1
    // 消息编辑时间（Unix 秒，0 = 未编辑）：实时位置每次坐标更新都是一次 edit，
    // iOS liveTextNode "updated … ago" 取 EditedMessageAttribute.date。
    public var editDate: Int64 = 0
    // messageMediaVenue：场馆标题/地址等（iOS TelegramMediaMap.venue）
    public var venueTitle: String = ""
    public var venueAddress: String = ""
    public var venueProvider: String = ""
    public var venueId: String = ""
    public var venueType: String = ""
    
    // ==================== Phase Q8: 投票相关 ====================
    
    public var pollId: Int64 = 0
    public var pollQuestion: String = ""
    public var pollClosed: Bool = false
    public var pollQuiz: Bool = false
    public var pollMultipleChoice: Bool = false
    public var pollTotalVoters: Int32 = 0
    public var pollSolution: String = ""
    public var pollOptions: ArrayList<PollOptionData> = ArrayList<PollOptionData>()

    // ==================== P2-113: service 消息动作文本 ====================
    // 由 parseMessageActionCapture 填充：e.g. "Alice joined the group", "Bob pinned a message"
    public var serviceText: String = ""
    // iOS ChatHistoryEntriesForView.swift:230：.channelMigratedFromGroup / .groupMigratedToChannel
    // 留在历史里（占 id、参与翻页），但不产出任何列表条目。
    public var hiddenInHistory: Bool = false

    // ==================== P2-113: album mosaic (grouped media) ====================
    // groupedId > 0 表示该消息属于一条相册消息组
    public var groupedId: Int64 = 0
    // messageActionSetMessagesTTL 的 period（-1 = 不是该服务消息；0 = 关闭）
    public var serviceTtlPeriod: Int32 = -1
    // S6-05：messageActionSetChatWallPaper 的壁纸身份（iOS ChatMessageWallpaperBubbleContentNode
    // 在文案下方画 100×100 壁纸缩略图）；serviceWallpaperThumbPath 由气泡按需下载后填入
    public var serviceWallpaperId: Int64 = 0
    public var serviceWallpaperAccessHash: Int64 = 0
    public var serviceWallpaperSlug: String = ""
    // reply_markup 的回复键盘（iOS ReplyMarkupMessageAttribute）：
    // 0 无 / 1 replyKeyboardMarkup / 2 replyKeyboardHide / 3 replyKeyboardForceReply / 4 replyInlineMarkup
    public var replyMarkupKind: Int32 = 0
    public var replyKeyboardRows: ArrayList<ArrayList<String>> = ArrayList<ArrayList<String>>()
    public var replyKeyboardSingleUse: Bool = false
    public var replyKeyboardResize: Bool = false
    public var replyKeyboardPlaceholder: String = ""

    // ==================== Phase T3: 通话消息相关 ====================

    public var isCallMessage: Bool = false
    public var callDuration: Int32 = 0
    public var callReason: String = ""  // "missed", "hangup", "busy", "disconnect", ""
    
    // ==================== Phase P6-3: 消息分组显示 ====================
    
    // 分组位置标记（由 ChatRoomViewModel.computeGroupPositions 计算）
    public var isFirstInGroup: Bool = true     // 分组中第一条（显示头像/用户名）
    public var isLastInGroup: Bool = true      // 分组中最后一条（显示时间戳）
    public var isMiddleInGroup: Bool = false   // 中间消息（隐藏头像/时间）
    public var isSingleMessage: Bool = true    // 独立消息（前后都不同 sender）
    // 与前一条消息是否跨日期（用于日期分隔线）
    public var showDateSeparator: Bool = false
    public var dateSeparatorText: String = ""
    // P2-112: 未读分隔线（"X 条未读消息"）显示在此消息上方
    // 由 computeMessageGroupPositions 在 firstUnreadId 处置位
    public var showUnreadSeparator: Bool = false
    public var unreadSeparatorText: String = ""

    // ==================== Reactions 相关 ====================
    
    public var reactions: ArrayList<ReactionData> = ArrayList<ReactionData>()
}

/**
 * Phase Q8: PollOptionData — 投票选项的展示数据
 * 
 * 包含：
 * - text: 选项文字
 * - voters: 投票人数
 * - chosen: 当前用户是否已选该选项
 * - correct: 是否为正确答案（仅 quiz 模式）
 * - percentage: 投票百分比（0-100）
 */
/**
 * Phase Q11: 富文本实体数据
 * type: bold, italic, code, pre, textUrl, strike, underline, mention, hashtag, url, email, spoiler, blockquote
 */
public class TextEntityData {
    public var entityType: String = ""
    public var offset: Int32 = 0
    public var length: Int32 = 0
    public var url: String = ""
    public var customEmojiDocumentId: Int64 = 0
    
    public init() {}
}

public class PollOptionData {
    public var text: String = ""
    public var voters: Int32 = 0
    public var chosen: Bool = false
    public var correct: Bool = false
    public var percentage: Int32 = 0
    public var optionData: Array<Byte> = Array<Byte>(0, repeat: 0)

    public init() {}
}

/**
 * ReactionData：单个 Reaction 的展示数据
 * 
 * 对应 TelegramHarmony MessageReactions.ets 的 Reaction interface
 * 
 * 包含:
 * - emoji: 反应的 emoji 表情（如 "👍", "❤️"）
 * - count: 该反应的总数量
 * - isSelected: 当前用户是否选中了该反应
 */
public class ReactionData {
    public var emoji: String = ""
    public var count: Int64 = 0
    public var isSelected: Bool = false
    // 回复者的首字母缩写（如 "HY" 代表 "Hao Yuan"），空字符串表示无数据
    public var peerInitials: String = ""
    // iOS ReactionsMessageAttribute.recentPeers 的 UI 映射，三个数组索引一一对应。
    public var peerIds: ArrayList<Int64> = ArrayList<Int64>()
    public var peerAvatarPaths: ArrayList<String> = ArrayList<String>()
    public var peerInitialsList: ArrayList<String> = ArrayList<String>()
    // P2-375: custom emoji reaction — document_id (0 = not a custom emoji)
    // Corresponds to iOS reactionCustomEmoji#8935fc73 document_id:long
    public var customEmojiDocumentId: Int64 = 0
    // P2-375: premium lock — reaction is premium-only, current user does not have premium
    // Corresponds to iOS ReactionContextNode isLocked logic (!hasPremium && item.isPremium)
    public var isPremiumLocked: Bool = false

    public func isCustomEmoji(): Bool {
        return this.customEmojiDocumentId != 0
    }

    public init() {}

    public init(emoji!: String, count!: Int64, isSelected!: Bool) {
        this.emoji = emoji
        this.count = count
        this.isSelected = isSelected
    }

    public init(emoji!: String, count!: Int64, isSelected!: Bool, peerInitials!: String) {
        this.emoji = emoji
        this.count = count
        this.isSelected = isSelected
        this.peerInitials = peerInitials
    }

    public init(emoji!: String, count!: Int64, isSelected!: Bool,
                customEmojiDocumentId!: Int64, isPremiumLocked!: Bool) {
        this.emoji = emoji
        this.count = count
        this.isSelected = isSelected
        this.customEmojiDocumentId = customEmojiDocumentId
        this.isPremiumLocked = isPremiumLocked
    }
}

/**
 * ReactorInfo — 单个反应者信息 (P2-116)
 *
 * 对应 messages.MessageReactionsList 中的 MessagePeerReaction：
 *   messagePeerReaction#8c79b63c peer_id:Peer date:int reaction:Reaction
 */
public class ReactorInfo {
    // 用户 ID（来自 Peer/User 解析）
    public var userId: Int64 = 0
    // 用户显示名（来自 users 字段解析）
    public var displayName: String = ""
    // 该用户 react 的 emoji
    public var emoji: String = ""
    // 是否是当前用户自己的 reaction
    public var isMy: Bool = false

    public init() {}
}

/**
 * MessageEntry：Message 的轻量包装，实现 ToString 接口
 * 用于 ChatRoomPage ForEach 的 key 生成
 */
public class MessageEntry <: ToString {
    public let message: Message
    public let groupedMessages: ArrayList<Message>
    // S4-12: in-chat search query to paint inside this bubble (iOS
    // ChatControllerInteraction.searchTextHighightState); empty = no search highlight.
    // Part of the render key so a search state change re-feeds the bubble.
    public var searchHighlight: String = ""

    public init(message: Message, groupedMessages!: ArrayList<Message> = ArrayList<Message>()) {
        this.message = message
        this.groupedMessages = groupedMessages
    }

    public func toString(): String {
        // Include peer avatar paths so a stripped/full profile photo becoming
        // ready invalidates the reaction row immediately.
        var reactionsKey = ""
        for (r in this.message.reactions) {
            var peerIdKey = ""
            for (peerId in r.peerIds) { peerIdKey = peerIdKey + "${peerId}," }
            var peerAvatarKey = ""
            for (path in r.peerAvatarPaths) { peerAvatarKey = peerAvatarKey + "${path}," }
            var peerInitialsKey = ""
            for (initials in r.peerInitialsList) { peerInitialsKey = peerInitialsKey + "${initials}," }
            reactionsKey = reactionsKey +
                "${r.emoji}:${r.count}:${r.isSelected}:${r.peerInitials}:${peerIdKey}:${peerAvatarKey}:${peerInitialsKey};"
        }
        var groupedMediaKey = ""
        for (m in this.groupedMessages) {
            groupedMediaKey = groupedMediaKey + "${m.identityKey()}:${m.photoLocalPath}:${m.documentLocalPath};"
        }
        // Content version. iOS bumps Message.stableVersion on every updateMessage
        // (Postbox MessageHistoryTable.swift:1834) and ChatHistoryEntry equality
        // compares it (ChatHistoryEntry.swift:150), so a message whose entities or
        // media (incl. the webpage preview) change is re-laid out even when text and
        // status stay the same. MessageBubble reads Message as a plain member, so
        // those fields must be part of this key for the bubble to repaint.
        var entitiesKey = ""
        for (e in this.message.textEntityList) {
            entitiesKey = entitiesKey + "${e.entityType}:${e.offset}:${e.length}:${e.url}:${e.customEmojiDocumentId};"
        }
        let cur = this.message
        let mediaKey = "${cur.messageType}:${cur.mediaDescription}:${cur.photoId}:${cur.documentId}:${cur.documentThumbnailPath}:" +
            "${cur.webPageUrl}:${cur.webPageSiteName}:${cur.webPageTitle}:${cur.webPageDescription}:" +
            "${cur.webPagePhotoId}:${cur.webPagePhotoLocalPath}:${cur.pollTotalVoters}:${cur.pollClosed}:${cur.photoDownloadState}"
        // Date header state belongs to the key: computeMessageGroupPositions rewrites it in place
        // whenever older history is prepended or cached rows are evicted, and a node whose key
        // did not change is never re-rendered, so its capsule would keep a stale date or stay
        // visible after the previous message moved onto the same day (R3 C3).
        let dateKey = if (this.message.showDateSeparator) { this.message.dateSeparatorText } else { "" }
        return "${this.message.identityKey()}_${dateKey}_${this.message.content}_${this.message.status}_${this.message.isEdited}_${this.message.senderName}_${this.message.senderRole}_${this.message.photoLocalPath}_${this.message.documentLocalPath}_${groupedMediaKey}_${reactionsKey}_${this.message.isFirstInGroup}_${this.message.isLastInGroup}_${this.message.showUnreadSeparator}_${this.message.editDate}_${this.message.locationLat}_${this.message.locationLng}_${this.message.replyToMsgId}:${this.message.replyToText}:${this.message.replyToSenderName}_${this.message.forwardFromName}_${entitiesKey}_${mediaKey}_${this.searchHighlight}"
    }
}
