package ohos_app_cangjie_entry.models

import kit.ArkUI.*

/**
 * 聊天数据模型
 * 对应 iOS ChatListUI 的 Chat 数据结构
 * 
 * iOS 文件参考:
 * - submodules/ChatListUI/Sources/ChatListItem.swift
 * 
 * 纯数据类，不使用 @Observed（数据模型在后台线程创建，@Publish 会触发主线程检查异常）
 * UI 更新通过 ViewModel 层 @Publish chatList 整体替换驱动
 */
public class Chat {
    public var id: Int64 = 0
    public var name: String = ""
    public var lastMessage: String = ""
    public var time: String = ""
    public var unreadCount: Int64 = 0
    // M-2a（diag-suite_chat_list-TC-0029.md）：对位源侧 Postbox/Sources/PeerReadState.swift:2-3
    // 的 markedUnread 一等状态位——"是否未读"= unreadCount > 0 || isMarkedUnread（源侧
    // PeerReadState.isUnread）。此前该字段只在 TLDialogs.cj 解析、零消费，本轮接通。
    public var isMarkedUnread: Bool = false
    public var avatarText: String = ""
    public var avatarColor: Int64 = 0x317AFF
    public var isPinned: Bool = false
    public var isMuted: Bool = false
    public var isGroup: Bool = false
    public var peerType: String = "user"
    
    // ==================== Phase C: 频道/群组增强字段 ====================
    public var isChannel: Bool = false
    public var isMegagroup: Bool = false
    public var participantsCount: Int64 = 0
    public var username: String = ""
    public var lastMessageType: String = "text"
    public var lastMessageViews: Int64 = 0
    
    // ==================== Phase E: 聊天列表增强字段 ====================
    public var draftText: String = ""
    public var isOnline: Bool = false
    public var lastMessageOutgoing: Bool = false
    public var lastMessageRead: Bool = true
    public var lastMessageTimestamp: Int64 = 0

    // ==================== Phase L: 真实头像字段 ====================
    public var avatarLocalPath: String = ""

    // ==================== P2-100/105/106: iOS 保真度对齐字段 ====================
    // P2-105: 未读提及数（@badge）
    public var mentionCount: Int64 = 0
    // P2-105: 未读 reaction 数（reaction badge，显示💬）
    public var unreadReactionsCount: Int64 = 0
    // P2-106: 群组最后消息发送者名称（"You" 或成员 firstName）
    public var lastMessageSenderName: String = ""
    // P2-100: 是否为 Secret Chat（加密聊天，显示🔒图标）
    public var isSecretChat: Bool = false
    // P2-100: 是否为 Saved Messages（自己对自己，显示书签）
    public var isSavedMessages: Bool = false
    // 已注销账号（名字全空且无手机号，iOS PeerTitle.displayTitle → User.DeletedAccount），头像走 Deleted 特殊态
    public var isDeletedAccount: Bool = false

    // P2-304: Premium emoji status badge（premium=true 时在名称旁显示 emoji status）
    public var isPremium: Bool = false
    // emoji status unicode 表示（空字符串=无 emoji status，仅 isPremium=true 时有意义）
    public var emojiStatusEmoji: String = ""

    // iOS parity: 认证徽章（蓝勾 verified，名称右侧）与 bot 标记
    // 对应 iOS ChatListItem verified badge / peer.isVerified (flags.17)
    public var isVerified: Bool = false
    public var isBot: Bool = false
    // iOS parity: bot_has_main_app (flags2.13) — 仅此类 bot 行显示蓝色 OPEN 按钮
    public var botHasMainApp: Bool = false
    // 全局消息搜索结果行对应的消息 id（iOS ChatListSearchEntry.message 以消息为单位成行，
    // 点按 / View in Chat 需要定位到这条消息）。会话列表行恒为 0。
    public var searchMessageId: Int64 = 0

    /**
     * 创建独立的会话行快照。
     *
     * Chat 是可变数据对象。账号级 Projection 在后台接收 updates，而页面在 UI
     * 线程消费快照；只复制 ArrayList 容器仍会跨线程共享同一个 Chat 实例。
     */
    public func copy(): Chat {
        let result = Chat()
        result.id = this.id
        result.name = this.name
        result.lastMessage = this.lastMessage
        result.time = this.time
        result.unreadCount = this.unreadCount
        // 手动标未读位必须随快照复制，否则投影发布后列表行丢失未读徽章与 Read 滑动项。
        result.isMarkedUnread = this.isMarkedUnread
        result.avatarText = this.avatarText
        result.avatarColor = this.avatarColor
        result.isPinned = this.isPinned
        result.isMuted = this.isMuted
        result.isGroup = this.isGroup
        result.peerType = this.peerType
        result.isChannel = this.isChannel
        result.isMegagroup = this.isMegagroup
        result.participantsCount = this.participantsCount
        result.username = this.username
        result.lastMessageType = this.lastMessageType
        result.lastMessageViews = this.lastMessageViews
        result.draftText = this.draftText
        result.isOnline = this.isOnline
        result.lastMessageOutgoing = this.lastMessageOutgoing
        result.lastMessageRead = this.lastMessageRead
        result.lastMessageTimestamp = this.lastMessageTimestamp
        result.avatarLocalPath = this.avatarLocalPath
        result.mentionCount = this.mentionCount
        result.unreadReactionsCount = this.unreadReactionsCount
        result.lastMessageSenderName = this.lastMessageSenderName
        result.isSecretChat = this.isSecretChat
        result.isSavedMessages = this.isSavedMessages
        result.isDeletedAccount = this.isDeletedAccount
        result.isPremium = this.isPremium
        result.emojiStatusEmoji = this.emojiStatusEmoji
        result.isVerified = this.isVerified
        result.isBot = this.isBot
        result.botHasMainApp = this.botHasMainApp
        result.searchMessageId = this.searchMessageId
        return result
    }
}

/**
 * Phase S3: 管理员成员数据模型
 */
public class AdminMemberData <: ToString {
    public var userId: Int64 = 0
    public var userAccessHash: Int64 = 0
    public var firstName: String = ""
    public var lastName: String = ""
    public var rank: String = ""
    public var adminFlags: Int32 = 0
    public var isCreator: Bool = false
    public var canEdit: Bool = false
    public var promotedBy: Int64 = 0
    public var date: Int32 = 0

    public func toString(): String {
        return "${this.userId}_${this.adminFlags}_${this.rank}"
    }

    public func getDisplayName(): String {
        if (this.lastName.size > 0) {
            return "${this.firstName} ${this.lastName}"
        }
        return this.firstName
    }

    public func getRoleLabel(): String {
        if (this.isCreator) { return "Owner" }
        if (this.rank.size > 0) { return this.rank }
        return "Admin"
    }

    public func hasPermission(bit: Int32): Bool {
        return (this.adminFlags & bit) != 0
    }
}

/**
 * Phase S1: 邀请链接数据模型
 * 存储从 messages.getExportedChatInvites 返回的链接信息
 */
public class InviteLinkData <: ToString {
    public var link: String = ""
    public var adminId: Int64 = 0
    public var date: Int32 = 0
    public var expireDate: Int32 = 0
    public var usageLimit: Int32 = 0
    public var usageCount: Int32 = 0
    public var requestsCount: Int32 = 0  // P2-166/168: pending join requests count (flags.8?int)
    public var isRevoked: Bool = false
    public var isPermanent: Bool = false
    public var requestNeeded: Bool = false  // P2-166: whether link requires approval
    public var title: String = ""

    public func toString(): String {
        return "${this.link}_${this.isRevoked}_${this.usageCount}_${this.requestsCount}"
    }
}

/**
 * ChatEntry：Chat 的轻量包装，实现 ToString 接口
 * 
 * 为什么需要？
 * - Chat 是纯数据类，不实现 ToString 接口
 * - ForEach 默认 keyGenerator（来自 arkui/custom_view.cj）：
 *     case realDataStr: ToString => idx.toString() + "_" + realDataStr.toString()
 *     case _ => idx.toString()    ← 不实现 ToString 时只用 index 作 key
 * - 只用 index 作 key → 数据变化但列表长度不变时 key 相同 → 组件复用不更新
 * 
 * ChatEntry 实现 ToString，toString() 是本行的**渲染指纹**：Chat 不可观测（见上方类注释），
 * ForEach 的 key 是行内容更新的唯一通道（dev_pattern.md D-127 前置条件），因此 toString()
 * 必须覆盖 components/ChatListItem.cj 实际读取的**全部** chat.* 字段——新增任何被
 * ChatListItem 读取的字段时必须同步加入此处，否则该字段的变更在 UI 上不可见（M-1，
 * diag-suite_chat_list-TC-0029.md）。id 必须排第一以保证身份唯一性前缀。
 * 使 ForEach 在数据变化时生成不同的 key → 销毁旧组件 → 创建新组件 → UI 正确更新
 */
public class ChatEntry <: ToString {
    public let chat: Chat

    public init(chat: Chat) {
        this.chat = chat
    }

    public func toString(): String {
        let peerKey = PeerKey.fromPeerType(this.chat.peerType, this.chat.id)
        return "${peerKey}_${this.chat.name}_${this.chat.lastMessage}_${this.chat.time}_${this.chat.unreadCount}_${this.chat.isMarkedUnread}_${this.chat.avatarColor}_${this.chat.avatarLocalPath}_${this.chat.isPinned}_${this.chat.isMuted}_${this.chat.isGroup}_${this.chat.isChannel}_${this.chat.isMegagroup}_${this.chat.isOnline}_${this.chat.isBot}_${this.chat.botHasMainApp}_${this.chat.isPremium}_${this.chat.emojiStatusEmoji}_${this.chat.isVerified}_${this.chat.isSecretChat}_${this.chat.isSavedMessages}_${this.chat.draftText}_${this.chat.lastMessageType}_${this.chat.lastMessageOutgoing}_${this.chat.lastMessageRead}_${this.chat.lastMessageSenderName}_${this.chat.mentionCount}_${this.chat.unreadReactionsCount}"
    }
}
