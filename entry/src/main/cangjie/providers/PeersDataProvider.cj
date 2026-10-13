package ohos_app_cangjie_entry.providers

import ohos_app_cangjie_entry.services.{
    getPeersService,
    PeerOperationResult,
    CreatePeerResult,
    PeerResolveResult,
    InviteLinkResult,
    InviteLinksResult,
    PeersService
}
import ohos_app_cangjie_entry.core.mtproto.ChatBannedRights
import std.collection.ArrayList

/**
 * Peers 数据接口 — 将 PeersService API 转为 UI 可用的 ViewModel 层
 *
 * 对应 TelegramEngine.Peers 的面向 UI 接口：
 * - 添加/移除群组成员
 * - 邀请/踢出/封禁频道成员
 * - 创建群组/频道
 * - 管理员权限管理
 *
 * 所有方法均为同步调用（由调用方 spawn 到后台线程），
 * 结果直接返回 ViewModel，通过 @State 更新驱动 UI 刷新。
 */
private var _peersDataProviderInstance: Option<PeersDataProvider> = None

public func getPeersDataProvider(): PeersDataProvider {
    match (_peersDataProviderInstance) {
        case Some(p) => return p
        case None =>
            let p = PeersDataProvider()
            _peersDataProviderInstance = Some(p)
            return p
    }
}

// ==================== UI ViewModel ====================

/**
 * 成员操作的 UI 友好结果
 */
public class MemberActionResult {
    public var success: Bool = false
    public var errorMessage: String = ""

    public init(success: Bool, errorMessage!: String = "") {
        this.success = success
        this.errorMessage = errorMessage
    }

    /** 将底层错误码映射为用户可读文字 */
    public static func fromServiceResult(r: PeerOperationResult): MemberActionResult {
        if (r.success) {
            return MemberActionResult(true)
        }
        let msg = if (r.errorCode == "USERS_TOO_MUCH") {
            "群组成员已达上限"
        } else if (r.errorCode == "USER_PRIVACY_RESTRICTED") {
            "该用户隐私设置不允许添加"
        } else if (r.errorCode == "USER_NOT_MUTUAL_CONTACT") {
            "需要互相是联系人"
        } else if (r.errorCode == "USER_CHANNELS_TOO_MUCH" || r.errorCode == "CHANNELS_TOO_MUCH") {
            "用户加入的群组/频道已达上限"
        } else if (r.errorCode == "USER_KICKED") {
            "该用户已被移除，无法重新添加"
        } else if (r.errorCode == "NETWORK_ERROR") {
            "网络错误，请重试"
        } else {
            "操作失败: ${r.errorCode}"
        }
        return MemberActionResult(false, errorMessage: msg)
    }
}

/**
 * 创建 Peer 的 UI 友好结果
 */
public class CreatePeerViewModel {
    public var success: Bool = false
    public var peerId: Int64 = 0
    public var accessHash: Int64 = 0
    public var peerType: String = ""  // "chat" 或 "channel"
    public var errorMessage: String = ""

    public static func fromServiceResult(r: CreatePeerResult): CreatePeerViewModel {
        let vm = CreatePeerViewModel()
        vm.success = r.success
        vm.peerId = r.peerId
        vm.accessHash = r.accessHash
        vm.peerType = r.peerType
        if (!r.success) {
            vm.errorMessage = if (r.errorCode == "USERS_TOO_FEW") {
                "Choose at least one member"
            } else if (r.errorCode == "USER_RESTRICTED") {
                // Telegram's method contract defines USER_RESTRICTED as an
                // account-wide spam restriction on creating chats/channels.
                // S1-51 (WP-E): iOS CreateGroupController.swift:893 .restricted →
                // Common.ActionNotAllowedError.
                "Sorry, you are not allowed to do this."
            } else if (r.errorCode == "INPUT_USER_INVALID") {
                "One or more selected members could not be resolved"
            } else if (r.errorCode == "USER_PRIVACY_RESTRICTED" || r.errorCode == "USER_NOT_MUTUAL_CONTACT") {
                "One or more selected members cannot be added because of their privacy settings"
            } else if (r.errorCode == "CHANNELS_ADMIN_LOCATED_TOO_MUCH") {
                "已达到创建频道上限"
            } else if (r.errorCode == "NETWORK_ERROR") {
                "网络错误，请重试"
            } else if (r.errorCode == "UNEXPECTED_RESPONSE") {
                "The server returned an unsupported response"
            } else {
                "创建失败: ${r.errorCode}"
            }
        }
        return vm
    }
}

/**
 * P2-151: Peer 解析的 UI ViewModel
 */
public class PeerResolveViewModel {
    public var success: Bool = false
    public var peerId: Int64 = 0
    public var peerType: String = ""
    public var accessHash: Int64 = 0
    public var displayName: String = ""
    public var username: String = ""
    public var errorMessage: String = ""

    public init() {}

    public static func fromServiceResult(r: PeerResolveResult): PeerResolveViewModel {
        let vm = PeerResolveViewModel()
        vm.success = r.success
        vm.peerId = r.peerId
        vm.peerType = r.peerType
        vm.accessHash = r.accessHash
        vm.displayName = r.displayName
        vm.username = r.username
        if (!r.errorCode.isEmpty()) {
            vm.errorMessage = if (r.errorCode == "USERNAME_NOT_OCCUPIED") {
                "用户名不存在"
            } else if (r.errorCode == "PHONE_NOT_OCCUPIED") {
                "该手机号未注册"
            } else if (r.errorCode == "NETWORK_ERROR") {
                "网络错误，请重试"
            } else {
                "查找失败: ${r.errorCode}"
            }
        }
        return vm
    }
}

/**
 * P2-151: 邀请链接 UI ViewModel
 */
public class InviteLinkViewModel {
    public var success: Bool = false
    public var link: String = ""
    public var revoked: Bool = false
    public var errorMessage: String = ""

    public init() {}

    public static func fromServiceResult(r: InviteLinkResult): InviteLinkViewModel {
        let vm = InviteLinkViewModel()
        vm.success = r.success
        vm.link = r.link
        vm.revoked = r.revoked
        if (!r.errorCode.isEmpty()) {
            vm.errorMessage = if (r.errorCode == "NETWORK_ERROR") {
                "网络错误，请重试"
            } else if (r.errorCode == "CHAT_ADMIN_REQUIRED") {
                "需要管理员权限"
            } else {
                "操作失败: ${r.errorCode}"
            }
        }
        return vm
    }
}

// ==================== PeersDataProvider ====================

public class PeersDataProvider {
    private let service: PeersService = getPeersService()

    // ==================== 基础群组成员管理 ====================

    /**
     * 添加成员到基础群组
     *
     * @param chatId 群组 ID (basic chat)
     * @param userId 要添加的用户 ID
     * @param userAccessHash 用户 accessHash
     */
    public func addGroupMember(chatId: Int64, userId: Int64, userAccessHash: Int64): MemberActionResult {
        let r = this.service.addGroupMember(chatId, userId, userAccessHash)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 从基础群组移除成员
     *
     * @param chatId 群组 ID
     * @param userId 要移除的用户 ID
     * @param userAccessHash 用户 accessHash
     */
    public func removeGroupMember(chatId: Int64, userId: Int64, userAccessHash: Int64): MemberActionResult {
        let r = this.service.removeGroupMember(chatId, userId, userAccessHash)
        return MemberActionResult.fromServiceResult(r)
    }

    // ==================== 频道/超级群成员管理 ====================

    /**
     * 邀请用户加入频道/超级群
     *
     * @param channelId 频道 ID
     * @param channelAccessHash 频道 accessHash
     * @param userId 要邀请的用户 ID
     * @param userAccessHash 用户 accessHash
     */
    public func inviteToChannel(
        channelId: Int64,
        channelAccessHash: Int64,
        userId: Int64,
        userAccessHash: Int64
    ): MemberActionResult {
        let r = this.service.inviteToChannel(channelId, channelAccessHash, userId, userAccessHash)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 踢出频道/超级群成员
     *
     * @param channelId 频道 ID
     * @param channelAccessHash 频道 accessHash
     * @param userId 要踢出的用户 ID
     * @param userAccessHash 用户 accessHash
     */
    public func kickChannelMember(
        channelId: Int64,
        channelAccessHash: Int64,
        userId: Int64,
        userAccessHash: Int64
    ): MemberActionResult {
        let r = this.service.kickChannelMember(channelId, channelAccessHash, userId, userAccessHash)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 解封频道成员（取消封禁）
     *
     * @param channelId 频道 ID
     * @param channelAccessHash 频道 accessHash
     * @param userId 要解封的用户 ID
     * @param userAccessHash 用户 accessHash
     */
    public func unbanChannelMember(
        channelId: Int64,
        channelAccessHash: Int64,
        userId: Int64,
        userAccessHash: Int64
    ): MemberActionResult {
        let r = this.service.unbanChannelMember(channelId, channelAccessHash, userId, userAccessHash)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 封禁频道成员（自定义权限）
     *
     * @param channelId 频道 ID
     * @param channelAccessHash 频道 accessHash
     * @param userId 要封禁的用户 ID
     * @param userAccessHash 用户 accessHash
     * @param bannedFlags 封禁权限位（参见 ChatBannedRights）
     * @param untilDate 封禁到期时间（0 = 永久）
     */
    public func banChannelMember(
        channelId: Int64,
        channelAccessHash: Int64,
        userId: Int64,
        userAccessHash: Int64,
        bannedFlags: Int32,
        untilDate!: Int32 = 0
    ): MemberActionResult {
        let rights = ChatBannedRights()
        rights.flags = bannedFlags
        rights.untilDate = untilDate
        let r = this.service.editBanned(channelId, channelAccessHash, userId, userAccessHash, rights)
        return MemberActionResult.fromServiceResult(r)
    }

    // ==================== 创建群组/频道 ====================

    /**
     * 创建基础群组
     *
     * @param title 群组名称
     * @param memberIds 初始成员列表 (userId, accessHash) 对
     */
    public func createGroup(title: String, memberIds: ArrayList<(Int64, Int64)>): CreatePeerViewModel {
        let r = this.service.createGroup(title, memberIds)
        return CreatePeerViewModel.fromServiceResult(r)
    }

    /**
     * 创建广播频道
     *
     * @param title 频道名称
     * @param about 频道简介
     */
    public func createChannel(title: String, about: String): CreatePeerViewModel {
        let r = this.service.createChannel(title, about, broadcast: true)
        return CreatePeerViewModel.fromServiceResult(r)
    }

    /**
     * 创建超级群（megagroup）
     *
     * @param title 超级群名称
     * @param about 超级群简介
     */
    public func createSupergroup(title: String, about: String): CreatePeerViewModel {
        let r = this.service.createChannel(title, about, broadcast: false)
        return CreatePeerViewModel.fromServiceResult(r)
    }

    // ==================== 管理员权限管理 ====================

    /**
     * 授予管理员权限
     *
     * @param channelId 频道 ID
     * @param channelAccessHash 频道 accessHash
     * @param userId 目标用户 ID
     * @param userAccessHash 用户 accessHash
     * @param adminFlags 权限位标志（参见 ChatAdminRights）
     * @param rank 管理员头衔（""=默认管理员）
     */
    public func promoteToAdmin(
        channelId: Int64,
        channelAccessHash: Int64,
        userId: Int64,
        userAccessHash: Int64,
        adminFlags: Int32,
        rank!: String = ""
    ): MemberActionResult {
        let r = this.service.editAdmin(
            channelId, channelAccessHash,
            userId, userAccessHash,
            adminFlags, rank: rank
        )
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 撤销管理员权限
     *
     * @param channelId 频道 ID
     * @param channelAccessHash 频道 accessHash
     * @param userId 目标用户 ID
     * @param userAccessHash 用户 accessHash
     */
    public func demoteAdmin(
        channelId: Int64,
        channelAccessHash: Int64,
        userId: Int64,
        userAccessHash: Int64
    ): MemberActionResult {
        let r = this.service.editAdmin(
            channelId, channelAccessHash,
            userId, userAccessHash,
            0  // flags=0 撤销所有管理员权限
        )
        return MemberActionResult.fromServiceResult(r)
    }

    // ==================== P2-151: Peer Resolve ====================

    /**
     * 通过用户名查找 peer
     * @param username 用户名（不含 @）
     */
    public func resolveByUsername(username: String): PeerResolveViewModel {
        let r = this.service.resolveByUsername(username)
        return PeerResolveViewModel.fromServiceResult(r)
    }

    /**
     * 通过手机号查找 peer
     * @param phone 手机号（含国家区号，如 +79161234567）
     */
    public func resolveByPhone(phone: String): PeerResolveViewModel {
        let r = this.service.resolveByPhone(phone)
        return PeerResolveViewModel.fromServiceResult(r)
    }

    /**
     * 通过 ID 直接查找（本地缓存优先）
     */
    public func resolveById(
        peerId: Int64,
        peerType: String,
        accessHash!: Int64 = 0
    ): PeerResolveViewModel {
        let r = this.service.resolveById(peerId, peerType, accessHash: accessHash)
        return PeerResolveViewModel.fromServiceResult(r)
    }

    // ==================== P2-151: Username / addressName ====================

    /**
     * 检查用户名可用性（当前账号）
     */
    public func checkUsernameAvailability(username: String): Bool {
        return this.service.checkUsernameAvailability(username)
    }

    /**
     * 更新当前账号的用户名
     * @param username 新用户名（""= 清除）
     */
    public func updateAccountUsername(username: String): MemberActionResult {
        let r = this.service.updateAccountUsername(username)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 更新频道的用户名
     */
    public func updateChannelUsername(
        channelId: Int64,
        channelAccessHash: Int64,
        username: String
    ): MemberActionResult {
        let r = this.service.updateChannelUsername(channelId, channelAccessHash, username)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 切换账号某个用户名的激活状态
     */
    public func toggleAccountUsername(username: String, active: Bool): MemberActionResult {
        let r = this.service.toggleAccountUsername(username, active)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 切换频道某个用户名的激活状态
     */
    public func toggleChannelUsername(
        channelId: Int64,
        channelAccessHash: Int64,
        username: String,
        active: Bool
    ): MemberActionResult {
        let r = this.service.toggleChannelUsername(channelId, channelAccessHash, username, active)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 重新排序账号的用户名列表
     */
    public func reorderAccountUsernames(order: ArrayList<String>): MemberActionResult {
        let r = this.service.reorderAccountUsernames(order)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 重新排序频道的用户名列表
     */
    public func reorderChannelUsernames(
        channelId: Int64,
        channelAccessHash: Int64,
        order: ArrayList<String>
    ): MemberActionResult {
        let r = this.service.reorderChannelUsernames(channelId, channelAccessHash, order)
        return MemberActionResult.fromServiceResult(r)
    }

    // ==================== P2-151: Title / Description ====================

    /**
     * 修改频道/超级群标题
     */
    public func editChannelTitle(
        channelId: Int64,
        channelAccessHash: Int64,
        title: String
    ): MemberActionResult {
        let r = this.service.editChannelTitle(channelId, channelAccessHash, title)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 修改基础群组标题
     */
    public func editChatTitle(chatId: Int64, title: String): MemberActionResult {
        let r = this.service.editChatTitle(chatId, title)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 修改群组/频道简介
     */
    public func editDescription(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        about: String
    ): MemberActionResult {
        let r = this.service.editDescription(peerType, peerId, accessHash, about)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 更新当前用户的自我介绍
     */
    public func updateProfileAbout(about: String): MemberActionResult {
        let r = this.service.updateProfileAbout(about)
        return MemberActionResult.fromServiceResult(r)
    }

    // ==================== P2-151: Mute / Notify ====================

    /**
     * 设置指定 peer 的静音状态（发送服务端 + 本地持久化）
     * @param muteUntil 0=取消, 2147483647=永久静音
     */
    public func updatePeerMuteSettings(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        muteUntil: Int32
    ): MemberActionResult {
        let r = this.service.updatePeerMuteSettings(peerType, peerId, accessHash, muteUntil)
        return MemberActionResult.fromServiceResult(r)
    }

    /**
     * 读取本地已缓存的 peer 静音状态
     * @return muteUntil（0 = 未静音）
     */
    public func getPeerMuteLocal(peerId: Int64): Int32 {
        return this.service.getPeerMuteLocal(peerId)
    }

    // ==================== P2-151: Invite Links ====================

    /**
     * 创建新邀请链接
     */
    public func createInviteLink(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        expireDate!: Int32 = 0,
        usageLimit!: Int32 = 0,
        requestNeeded!: Bool = false,
        title!: String = ""
    ): InviteLinkViewModel {
        let r = this.service.createInviteLink(
            peerType, peerId, accessHash,
            expireDate: expireDate,
            usageLimit: usageLimit,
            requestNeeded: requestNeeded,
            title: title
        )
        return InviteLinkViewModel.fromServiceResult(r)
    }

    /**
     * 撤销邀请链接
     */
    public func revokeInviteLink(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        link: String
    ): InviteLinkViewModel {
        let r = this.service.revokeInviteLink(peerType, peerId, accessHash, link)
        return InviteLinkViewModel.fromServiceResult(r)
    }

    /**
     * 编辑邀请链接
     */
    public func editInviteLink(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        link: String,
        expireDate!: Int32 = 0,
        usageLimit!: Int32 = 0,
        requestNeeded!: Bool = false,
        title!: String = ""
    ): InviteLinkViewModel {
        let r = this.service.editInviteLink(
            peerType, peerId, accessHash, link,
            expireDate: expireDate,
            usageLimit: usageLimit,
            requestNeeded: requestNeeded,
            title: title
        )
        return InviteLinkViewModel.fromServiceResult(r)
    }

    /**
     * 获取邀请链接列表
     */
    public func getInviteLinks(
        peerType: String,
        peerId: Int64,
        accessHash: Int64,
        revoked!: Bool = false,
        limit!: Int32 = 50
    ): InviteLinksResult {
        return this.service.getInviteLinks(
            peerType, peerId, accessHash,
            revoked: revoked,
            limit: limit
        )
    }
}
