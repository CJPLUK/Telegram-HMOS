package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos.resource.__GenerateResource__
import std.collection.ArrayList
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.viewmodels.getChatListVM

/**
 * GroupDetailsPage — 群组/频道详情页（P2-132 + P2-133b 重构）（混合工程迁移版）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop(animated:true) → routerPop()
 *  - pageStack.pushPathByName(name, "") → routerPush(name)
 *  - aboutToAppear 有实逻辑 → ensureLoaded() + .onAppear
 *
 * 对应 iOS PeerInfoUI 群组和频道资料屏。
 *
 * P2-132 群信息行+管理入口:
 *   - 内联头像（workaround S-015：跨包 @Component+@State 无法命名参数构造）
 *   - 群名/群头像（点击编辑）
 *   - 群简介（about）
 *   - 成员数 / 在线数
 *   - 通知开关（toggleMuteDialog）
 *   - 成员列表入口（→ GroupMembersPage，已注册 pageMap）
 *   - 管理员入口（→ AdminManagePage，已注册 pageMap）
 *   - 封禁/黑名单入口（→ BlacklistPage，已注册 pageMap）
 *   - 邀请链接入口（→ InviteLinksPage，已注册 pageMap）
 *   - 共享媒体入口（→ SharedMediaPage，已注册 pageMap）
 *   - 退出群组/频道
 *
 * P2-133b 频道额外:
 *   - Sign Messages 开关（→ PeersService.toggleSignatures）
 *   - Restrict Saving Content 开关（→ PeersService.toggleNoForwards）
 *   - 频道头像区显示订阅数
 *
 * 架构约束:
 *   D-002: build() 根容器必须是 NavDestination()
 *   S-001: @State 写入必须在主线程 launch{}
 *   S-005: build/@Builder 内不能有 let/var
 *   S-013: @Builder 不能修饰 private func
 *   S-015: 内联头像 workaround（跨包 @Component 含 @State 无法命名参数实例化）
 */
// 混合嵌入页没有 onPageShow：子页（权限页等）改完数据后通过本回调通知编辑页刷新缓存派生状态。
private var _groupDetailsRefreshHandler: Option<() -> Unit> = None

public func notifyGroupDetailsChanged(): Unit {
    match (_groupDetailsRefreshHandler) {
        case Some(handler) => handler()
        case None => ()
    }
}

@HybridComponentEntry
@Component
public class GroupDetailsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ===== 基础信息 =====
    @State var groupName: String = ""
    @State var groupType: String = ""       // "chat" | "channel"
    @State var membersCount: Int32 = 0
    @State var onlineCount: Int32 = 0
    @State var aboutText: String = ""
    @State var isLoading: Bool = true
    @State var username: String = ""
    @State var accessHash: Int64 = 0
    @State var isCreator: Bool = false
    @State var isMegagroup: Bool = false
    // 当前账号是否管理员（chat/channel.admin_rights 存在）及其权限位（chatAdminRights.flags）
    @State var canEditInfo: Bool = false
    @State var adminRightsFlags: Int32 = 0
    @State var isLeft: Bool = false
    @State var adminsCount: Int32 = 0
    @State var kickedCount: Int32 = 0
    // 群默认权限位（chatBannedRights.flags），Permissions 行 "n/total" 标签来源
    @State var defaultBannedFlags: Int32 = 0
    // chatAdminRights 位：ban_users=flags.4 invite_users=flags.5（telegram_api.tl）
    private let adminBanUsersBit: Int32 = 1 << 4
    private let adminInviteUsersBit: Int32 = 1 << 5

    // ===== 头像上传 =====
    @State var isUploadingPhoto: Bool = false

    // ===== 通知 =====
    @State var isMuted: Bool = false

    // ===== 频道专用开关 (P2-133b) =====
    @State var signaturesEnabled: Bool = false
    @State var noForwardsEnabled: Bool = false

    // ===== 频道公开/私有 =====
    @State var isPublicChannel: Bool = false
    @State var channelUsernameInput: String = ""
    @State var showChannelType: Bool = false

    // ===== 编辑对话框 =====
    @State var showEditName: Bool = false
    @State var showEditAbout: Bool = false
    @State var editNameText: String = ""
    @State var editAboutText: String = ""

    // ===== Toast =====
    @State var toastMessage: String = ""
    @State var showToast: Bool = false

    // ===== 离开确认 =====
    @State var showLeaveConfirm: Bool = false
    // iOS 编辑屏：邀请链接计数 / 历史可见性 / 群头像
    @State var inviteLinkCount: Int64 = -1
    @State var historyHidden: Bool = false
    @State var avatarPhotoPath: String = ""

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.groupName = getSelectedChatName()
        this.groupType = getSelectedChatPeerType()
        this.username = getSelectedChatUsername()
        this.isPublicChannel = this.username.size > 0
        this.channelUsernameInput = this.username
        this.loadAccessHashFromCache()
        this.editNameText = this.groupName
        this.avatarPhotoPath = getUserPhotoService().getChatPhotoPath(getSelectedChatId())
        this.loadMuteState()
        this.loadFullInfo()
        this.loadInviteLinkCount()
        _groupDetailsRefreshHandler = Some({ => this.refreshFromCache() })
    }

    private func loadInviteLinkCount(): Unit {
        let peerType = this.groupType
        let peerId = getSelectedChatId()
        let _ = spawn {
            try {
                let links = getInviteLinksService().getExportedChatInvites(peerType, peerId)
                let n = Int64(links.size)
                launch { this.inviteLinkCount = n }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupDetailsPage] loadInviteLinkCount failed: ${e}")
            }
        }
    }

    /** Done：名称 / 简介有改动才提交，然后返回。 */
    private func saveAndClose(): Unit {
        if (this.editNameText.size > 0 && this.editNameText != this.groupName) {
            this.saveGroupName()
        }
        if (this.editAboutText != this.aboutText) {
            this.saveGroupAbout()
        }
        routerPop()
    }


    private func doToggleHistoryHidden(): Unit {
        let peerId = getSelectedChatId()
        let aHash = this.accessHash
        let next = !this.historyHidden
        let _ = spawn {
            let r = getPeersService().togglePreHistoryHidden(peerId, aHash, next)
            launch {
                if (r.success) {
                    this.historyHidden = next
                } else {
                    this.showToastMsg("Failed: ${r.errorCode}")
                }
            }
        }
    }

    /** Set Photo：系统相册选图 → 压缩为头像 JPEG → 按群类型提交。 */
    private func pickGroupPhoto(): Unit {
        callArkAsync(PICK_PHOTO_ALBUM, "{}", { result =>
            let path = groupDetailsFirstPickedPath(result)
            if (path.size == 0) { return }
            launch { this.isUploadingPhoto = true }
            let peerId = getSelectedChatId()
            let peerType = this.groupType
            let _ = spawn {
                try {
                    let realPath = if (path.startsWith("file://")) { path[7..] } else { path }
                    let photoData = getImageCompressionService().compressToMaxPixelSize(realPath, Int32(1280), UInt8(86))
                    if (photoData.isEmpty()) {
                        launch {
                            this.showToastMsg("Could not read photo")
                            this.isUploadingPhoto = false
                        }
                        return
                    }
                    let ok = getRealMessageService().editGroupPhoto(peerType, peerId, photoData)
                    launch {
                        this.isUploadingPhoto = false
                        if (ok) {
                            this.showToastMsg("Group photo updated")
                            this.avatarPhotoPath = "file://" + realPath
                        } else {
                            this.showToastMsg("Failed to update photo")
                        }
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[GroupDetailsPage] pickGroupPhoto failed: ${e}")
                    launch {
                        this.showToastMsg("Upload error")
                        this.isUploadingPhoto = false
                    }
                }
            }
        })
    }

    /** 子页回来后按缓存刷新派生状态（权限位等） */
    private func refreshFromCache(): Unit {
        match (getRealChatListService().getCachedChat(getSelectedChatId())) {
            case Some(chat) => this.defaultBannedFlags = chat.defaultBannedRightsFlags
            case None => ()
        }
    }

    private func loadAccessHashFromCache(): Unit {
        let pid = getSelectedChatId()
        let chatListSvc = getRealChatListService()
        match (chatListSvc.getCachedChat(pid)) {
            case Some(chat) =>
                this.accessHash = chat.accessHash
                this.isCreator = chat.isCreator
                this.isMegagroup = chat.isMegagroup
                this.canEditInfo = chat.canEditInfo
                this.adminRightsFlags = chat.adminRightsFlags
                this.isLeft = chat.isLeft
                this.defaultBannedFlags = chat.defaultBannedRightsFlags
                if (this.groupType == "channel") {
                    getPeerInfoService().registerChannelAccessHash(chat.id, chat.accessHash)
                    getRealMessageService().cacheChannelAccessHash(chat.id, chat.accessHash)
                }
            case None => ()
        }
    }

    /**
     * FIX-1: 从服务器加载当前对话的真实静音状态
     *
     * 调用 account.getNotifySettings via RealChatListService.getPeerMuteState,
     * 结果在 spawn+launch{} 里写回 @State isMuted，确保 Toggle 初始态正确。
     */
    private func loadMuteState(): Unit {
        let peerType = this.groupType
        let peerId = getSelectedChatId()
        let _ = spawn {
            try {
                let svc = getRealChatListService()
                let muted = svc.getPeerMuteState(peerType, peerId)
                Hilog.info(0, "CjTelegram", "[GroupDetailsPage] loadMuteState: muted=${muted}")
                launch { this.isMuted = muted }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupDetailsPage] loadMuteState failed: ${e}")
            }
        }
    }

    private func loadFullInfo(): Unit {
        let peerType = this.groupType
        let peerId = getSelectedChatId()
        let _ = spawn {
            try {
                let infoSvc = getPeerInfoService()
                // 资料页刚拉过的结果直接复用，避免连续 getFullChat 触发 FLOOD_WAIT
                let info = infoSvc.getGroupFullInfo(peerType, peerId, maxAgeMs: 60000)
                let about = info.about
                let members = info.membersCount
                let online = info.onlineCount
                let signatures = info.signaturesEnabled
                let noForwards = info.noForwardsEnabled
                let admins = info.adminsCount
                let kicked = info.kickedCount
                Hilog.info(0, "CjTelegram", "[GroupDetailsPage] fullInfo members=${members} admins=${admins} kicked=${kicked} signatures=${signatures} noforwards=${noForwards}")
                launch {
                    this.aboutText = about
                    this.editAboutText = about
                    this.membersCount = members
                    this.onlineCount = online
                    this.adminsCount = admins
                    this.kickedCount = kicked
                    this.signaturesEnabled = signatures
                    this.noForwardsEnabled = noForwards
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupDetailsPage] loadFullInfo failed: ${e}")
                launch { this.isLoading = false }
            }
        }
    }

    // ==================== 操作方法 ====================

    private func saveGroupName(): Unit {
        let newName = this.editNameText
        if (newName.size == 0) { return }
        let peerType = this.groupType
        let peerId = getSelectedChatId()
        let aHash = this.accessHash
        this.showEditName = false
        let _ = spawn {
            try {
                let svc = getPeersService()
                let ok = if (peerType == "channel") {
                    svc.editChannelTitle(peerId, aHash, newName).success
                } else {
                    svc.editChatTitle(peerId, newName).success
                }
                let msg = if (ok) { "Name updated" } else { "Failed to update name" }
                launch {
                    if (ok) {
                        this.groupName = newName
                        setSelectedChat(peerId, newName, peerType)
                        notifyPeerDisplayNameChanged(peerId, peerType, newName)
                        notifyPeerInfoChanged()
                    }
                    this.showToastMsg(msg)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupDetailsPage] saveGroupName failed: ${e}")
            }
        }
    }

    private func saveGroupAbout(): Unit {
        let newAbout = this.editAboutText
        let peerType = this.groupType
        let peerId = getSelectedChatId()
        let aHash = this.accessHash
        this.showEditAbout = false
        let _ = spawn {
            try {
                let svc = getPeersService()
                let ok = svc.editDescription(peerType, peerId, aHash, newAbout).success
                let msg = if (ok) { "Description updated" } else { "Failed to update description" }
                launch {
                    if (ok) {
                        this.aboutText = newAbout
                        getPeerInfoService().updateCachedAbout(peerId, newAbout)
                        notifyPeerInfoChanged()
                    }
                    this.showToastMsg(msg)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupDetailsPage] saveGroupAbout failed: ${e}")
            }
        }
    }

    private func saveChannelUsername(): Unit {
        let newUsername = if (this.isPublicChannel) { this.channelUsernameInput.trimAscii() } else { "" }
        let peerId = getSelectedChatId()
        let aHash = this.accessHash
        // S5 (WP-E)：与 iOS ChannelVisibilityController 一致，先本地格式校验，服务端错误按
        // AddressNames 的分类给出具体文案（此前一律 "Failed to update channel type"）。
        if (newUsername.size > 0) {
            let formatErr = channelUsernameFormatError(newUsername)
            if (formatErr.size > 0) {
                this.showToastMsg(formatErr)
                return
            }
        }
        let _ = spawn {
            try {
                let svc = getPeersService()
                let result = svc.updateChannelUsername(peerId, aHash, newUsername)
                let msg = if (result.success) {
                    if (newUsername.size > 0) { "Channel is now public" } else { "Channel is now private" }
                } else { channelUsernameServerError(result.errorCode) }
                launch {
                    if (result.success) {
                        this.username = newUsername
                        setSelectedChatUsername(newUsername)
                        this.showChannelType = false
                    }
                    this.showToastMsg(msg)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupDetailsPage] saveChannelUsername failed: ${e}")
            }
        }
    }

    /**
     * applyPeerMuteState — 把本页的静音写入回显进账号级会话列表状态（chatList + archiveChatList）。
     *
     * 归因：diag-suite_settings_notifications-TC-0451.md 根因 A（B1）。此前 doToggleMute()
     * 只翻转本页 @State，未写入任何共享会话列表状态；归档行没有第二次拉取就不会重刷，只有
     * 冷启动整表回源才补齐。本方法直接复用 ChatListViewModel 已公开的 chatList /
     * archiveChatList / publishCurrentChatList 三个 public 成员（写法同形该文件
     * toggleMuteChat :1113），不新增 ChatListViewModel 自身文件的方法 —— 该文件不在本
     * feature 的 target_files allowlist 内，只使用它已公开的既有成员。
     *
     * 两份列表都必须写：archiveChatList 不在 ChatListProjection 的投影范围内（该 projection
     * 只持 folder 0 的 _chats），本 case 的失败现象正发生在归档列表，只写 chatList 修不好。
     * 必须 publish：ChatListPage 的订阅回调是 displayList 的唯一写入点，不 publish 则下次
     * 订阅回调会用旧快照覆盖回本地修改。写绝对值而非取反，方法本身幂等。
     */
    private func applyPeerMuteState(peerId: Int64, muted: Bool): Unit {
        match (getChatListVM()) {
            case Some(vm) =>
                let newChatList = ArrayList<Chat>()
                for (c in vm.chatList) {
                    if (c.id == peerId) {
                        c.isMuted = muted
                    }
                    newChatList.add(c)
                }
                vm.chatList = newChatList

                let newArchiveList = ArrayList<Chat>()
                for (c in vm.archiveChatList) {
                    if (c.id == peerId) {
                        c.isMuted = muted
                    }
                    newArchiveList.add(c)
                }
                vm.archiveChatList = newArchiveList

                vm.publishCurrentChatList("peerMuteApplied")
            case None => ()
        }
    }

    private func doToggleMute(): Unit {
        let peerType = this.groupType
        let peerId = getSelectedChatId()
        let muted = this.isMuted
        let _ = spawn {
            try {
                let svc = getRealChatListService()
                let ok = svc.toggleMuteDialog(peerType, peerId, !muted)
                if (ok) {
                    let newMuted = !muted
                    launch {
                        this.isMuted = newMuted
                        this.applyPeerMuteState(peerId, newMuted)
                        this.showToastMsg(if (newMuted) { "Notifications are muted." } else { "Notifications are unmuted." })
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupDetailsPage] doToggleMute failed: ${e}")
            }
        }
    }

    private func doToggleSignatures(enabled: Bool): Unit {
        let channelId = getSelectedChatId()
        let aHash = this.accessHash
        let _ = spawn {
            try {
                let svc = getPeersService()
                let result = svc.toggleSignatures(channelId, aHash, enabled)
                let msg = if (result.success) {
                    if (enabled) { "Signatures enabled" } else { "Signatures disabled" }
                } else { "Failed to update signatures" }
                launch {
                    if (result.success) { this.signaturesEnabled = enabled }
                    this.showToastMsg(msg)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupDetailsPage] doToggleSignatures failed: ${e}")
            }
        }
    }

    private func doToggleNoForwards(enabled: Bool): Unit {
        let channelId = getSelectedChatId()
        let aHash = this.accessHash
        let _ = spawn {
            try {
                let svc = getPeersService()
                let result = svc.toggleNoForwards(channelId, aHash, enabled)
                let msg = if (result.success) {
                    if (enabled) { "Saving restricted" } else { "Saving allowed" }
                } else { "Failed to update content protection" }
                launch {
                    if (result.success) { this.noForwardsEnabled = enabled }
                    this.showToastMsg(msg)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupDetailsPage] doToggleNoForwards failed: ${e}")
            }
        }
    }

    
    /**
     * 编辑页 "Delete Group/Channel" 行（iOS PeerInfoScreen.openDeletePeer → deletePeerChat(globally: true)）。
     * 只有群主能看到该行，因此这里始终走"为所有成员删除"。
     */
    private func doLeave(): Unit {
        let peerId = getSelectedChatId()
        let peerType = this.groupType
        let isGroup = this.isMegagroup || peerType == "chat"
        this.showLeaveConfirm = false
        let _ = spawn {
            try {
                let msgSvc = getRealMessageService()
                let ok = msgSvc.deletePeerGlobally(peerType, peerId)
                let msg = if (ok) { if (isGroup) { "Group deleted" } else { "Channel deleted" } } else { "Failed to delete" }
                launch {
                    this.showToastMsg(msg)
                    if (ok) {
                        match (getChatListVM()) {
                            case Some(vm) => vm.removeChatFromLocal(peerId)
                            case None => ()
                        }
                        routerReplace("MainTabPage", "{}")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupDetailsPage] doLeave failed: ${e}")
            }
        }
    }

    // ==================== 辅助函数 ====================

    private func showToastMsg(msg: String): Unit {
        this.toastMessage = msg
        this.showToast = true
    }

    private func getAvatarLetter(): String {
        if (this.groupName.size > 0) {
            return this.groupName.toRuneArray()[0].toString()
        }
        return "?"
    }

    private func getMembersLabel(): String {
        if (this.membersCount > 0) {
            if (this.onlineCount > 0) {
                return "${this.membersCount} members, ${this.onlineCount} online"
            }
            return "${this.membersCount} members"
        }
        return "Members"
    }

    private func getSubscribersLabel(): String {
        if (this.membersCount > 0) {
            return "${this.membersCount} subscribers"
        }
        return "Subscribers"
    }

    private func getMembersSubtitle(): String {
        if (this.groupType == "channel" && !this.isMegagroup) { return this.getSubscribersLabel() }
        return this.getMembersLabel()
    }

    private func getAboutDisplay(): String {
        if (this.aboutText.size > 0) { return this.aboutText }
        return "No description yet."
    }

    /** iOS Group_DeleteGroup / Channel_DeleteChannel（编辑模式 peerActions，仅群主） */
    private func getLeaveLabel(): String {
        if (this.groupType == "channel" && !this.isMegagroup) { return "Delete Channel" }
        return "Delete Group"
    }

    /** iOS PeerInfo_DeleteGroupText / PeerInfo_DeleteChannelText */
    private func getDeleteDialogText(): String {
        if (this.groupType == "channel" && !this.isMegagroup) {
            return "Are you sure you want to delete ${this.groupName}? All subscribers will be removed and all messages will be lost."
        }
        return "Are you sure you want to delete ${this.groupName}? All members will be removed and all messages will be lost."
    }

    // ==================== 行显隐（对位 iOS PeerInfoProfileItems.editingItems）====================

    /** iOS canViewAdminsAndBanned = adminRights != nil || isCreator */
    private func canManage(): Bool {
        return this.isCreator || this.canEditInfo
    }

    /**
     * iOS GroupInfo_InviteLinks：
     *   supergroup → (isCreator && 无用户名) || (!isCreator && adminRights.canInviteUsers)
     *   legacyGroup → creator 且无用户名；admin 需 canInviteUsers
     */
    private func showInviteLinksRow(): Bool {
        if (this.isCreator) { return this.username.size == 0 }
        return this.canEditInfo && (this.adminRightsFlags & this.adminInviteUsersBit) != 0
    }

    /** iOS Group_Info_Members 行只在超级群编辑模式出现（普通群成员在资料页） */
    private func showMembersRow(): Bool {
        return this.groupType == "channel" && this.canManage()
    }

    /** iOS GroupInfo_Permissions_Removed：超级群 canViewAdminsAndBanned */
    private func showRemovedUsersRow(): Bool {
        return this.groupType == "channel" && this.canManage()
    }

    /** iOS GroupInfo_GroupType：群主可改（普通群固定 Private，改公开会升级为超级群） */
    private func showGroupTypeRow(): Bool {
        return this.groupType == "channel" && this.isCreator
    }

    /** iOS 编辑模式 Delete Group/Channel 行：仅超级群/频道群主（普通群解散走 More 菜单） */
    private func showDeleteRow(): Bool {
        return this.groupType == "channel" && this.isCreator && !this.isLeft
    }

    /**
     * iOS 编辑页 Permissions 行标签 "n/total"：total = allGroupPermissionList 顶层 5 项
     * （Send Messages / Send Media / Add Members / Pin Messages / Change Info），
     * n = 默认权限未禁止的项数。权限页保存成功后经 notifyGroupDetailsChanged() 刷新。
     */
    private func getPermissionsLabel(): String {
        let flags = this.defaultBannedFlags
        let bits: Array<Int32> = [1 << 25, 1 << 2, 1 << 15, 1 << 17, 1 << 10]
        var allowed = 0
        for (b in bits) {
            if ((flags & b) == 0) { allowed = allowed + 1 }
        }
        return "${allowed}/${bits.size}"
    }

    private func getAdminsSubtitle(): String {
        if (this.adminsCount > 0) { return "${this.adminsCount}" }
        return ""
    }

    private func getRemovedSubtitle(): String {
        if (this.kickedCount > 0) { return "${this.kickedCount}" }
        return ""
    }

    private func getTypeLabel(): String {
        if (this.groupType == "channel" && !this.isMegagroup) { return "Channel" }
        return "Group"
    }

    private func getChannelTypeLabel(): String {
        if (this.username.size > 0) { return "Public" }
        return "Private"
    }

    private func getMuteLabel(): String {
        if (this.isMuted) { return "Unmute" }
        return "Mute"
    }

    private func getLeaveColor(): UInt32 { return UInt32(0xFFFF3B30) }

    // ==================== build() ====================

    public func build() {
        Stack {
            Column {
                // 导航行：Cancel / Done（iOS 编辑模式）
                Row {
                    Column {
                        Text(trSource("Cancel"))
                            .fontSize(17)
                            .fontColor(0xFF007AFF)
                    }
                        .height(44)
                        .padding(left: 16, right: 16)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(22)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .onClick({ _ => routerPop() })
                    Blank().layoutWeight(1)
                    Column {
                        Text(trSource("Done"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0xFF007AFF)
                    }
                        .height(44)
                        .padding(left: 16, right: 16)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(22)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .onClick({ _ => this.saveAndClose() })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)
                .alignItems(VerticalAlign.Center)

                Scroll {
                    Column {
                        // 头像 + Set Photo
                        Column {
                            Stack(alignContent: Alignment.Center) {
                                if (this.avatarPhotoPath.size > 0) {
                                    Image(this.avatarPhotoPath)
                                        .width(100)
                                        .height(100)
                                        .borderRadius(50)
                                        .objectFit(ImageFit.Cover)
                                } else {
                                    Column {
                                        Image(@r(app.media.editprofile_ic_camera))
                                            .width(36)
                                            .height(36)
                                            .fillColor(0xFF007AFF)
                                    }
                                    .width(100)
                                    .height(100)
                                    .borderRadius(50)
                                    .backgroundColor(0xFFD6E6FB)
                                    .justifyContent(FlexAlign.Center)
                                    .alignItems(HorizontalAlign.Center)
                                }
                                if (this.isUploadingPhoto) {
                                    Column {
                                        LoadingProgress().width(28).height(28).color(0xFFFFFFFF)
                                    }
                                    .width(100)
                                    .height(100)
                                    .borderRadius(50)
                                    .backgroundColor(0x80000000)
                                    .justifyContent(FlexAlign.Center)
                                    .alignItems(HorizontalAlign.Center)
                                }
                            }
                            .width(100)
                            .height(100)
                            .onClick({ _ => this.pickGroupPhoto() })
                            Text(trSource("Set Photo"))
                                .fontSize(17)
                                .fontColor(0xFF007AFF)
                                .margin(top: 10)
                                .onClick({ _ => this.pickGroupPhoto() })
                        }
                        .width(100.percent)
                        .alignItems(HorizontalAlign.Center)
                        .margin(top: 4)

                        // 名称 / 简介（等 fullInfo 到达后再挂载输入框：TextInput 只读初值）
                        if (this.isLoading) {
                            Column {
                                Text(this.groupName)
                                    .fontSize(17)
                                    .fontColor(0xFF000000)
                                    .width(100.percent)
                                    .height(48)
                                    .padding(left: 16)
                                Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 16)
                                Text(trSource("Description"))
                                    .fontSize(17)
                                    .fontColor(0xFF8E8E93)
                                    .width(100.percent)
                                    .height(48)
                                    .padding(left: 16)
                            }
                            .width(92.percent)
                            .backgroundColor(0xFFFFFFFF)
                            .borderRadius(14)
                            .margin(top: 20)
                            .clip(true)
                        } else {
                        Column {
                            TextInput(text: this.editNameText, placeholder: if (this.groupType == "channel") { "Channel Name" } else { "Group Name" })
                                .fontSize(17)
                                .fontColor(0xFF000000)
                                .backgroundColor(0xFFFFFFFF)
                                .height(48)
                                .onChange({ value: String => this.editNameText = value })
                            Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 16)
                            TextInput(text: this.editAboutText, placeholder: trSource("Description"))
                                .fontSize(17)
                                .fontColor(0xFF000000)
                                .backgroundColor(0xFFFFFFFF)
                                .height(48)
                                .onChange({ value: String => this.editAboutText = value })
                        }
                        .width(92.percent)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(14)
                        .margin(top: 20)
                        .clip(true)
                        }

                        // 第一组：类型 / 邀请链接 / 历史 / 话题
                        Column {
                            this.editIconRow(if (this.groupType == "channel") { "Channel Type" } else { "Group Type" }, "group", 0xFF007AFF, this.showGroupTypeRow())
                            if (this.showChannelType) {
                                this.channelTypeEditor()
                            }
                            if (this.showInviteLinksRow()) {
                                Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 60)
                                this.editIconRow("Invite Links", "link", 0xFFFF9500, true)
                            }
                            if (this.groupType == "channel" && this.canManage()) {
                                Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 60)
                                this.editIconRow("Chat History", "history", 0xFF34C759, true)
                            }
                            Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 60)
                            this.editIconRow("Topics", "topics", 0xFF5AC8FA, false)
                        }
                        .width(92.percent)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(14)
                        .margin(top: 20)
                        .clip(true)
                        Text(trSource("The group chat will be divided into topics created by admins or users."))
                            .fontSize(13)
                            .fontColor(0xFF8E8E93)
                            .width(92.percent)
                            .padding(left: 16, right: 16, top: 6)

                        // 第二组：反应 / 欢迎消息 / 权限 / 管理员 / 成员 / 已移除
                        Column {
                            this.editIconRow("Reactions", "reactions", 0xFFFF2D55, false)
                            Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 60)
                            this.editIconRow("Welcome Message", "welcome", 0xFF5856D6, false)
                            if (this.canManage()) {
                                Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 60)
                                this.editIconRow("Permissions", "permissions", 0xFF8E8E93, true)
                                Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 60)
                                this.editIconRow("Administrators", "admins", 0xFF34C759, true)
                                if (this.showMembersRow()) {
                                    Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 60)
                                    this.editIconRow("Members", "members", 0xFF007AFF, true)
                                }
                                if (this.showRemovedUsersRow()) {
                                    Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 60)
                                    this.editIconRow("Removed Users", "removed", 0xFFFF9500, true)
                                }
                            }
                            if (this.groupType == "channel" && !this.isMegagroup) {
                                Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 16)
                                this.toggleRow("Sign Messages", "", this.signaturesEnabled, { v: Bool => this.doToggleSignatures(v) })
                            }
                        }
                        .width(92.percent)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(14)
                        .margin(top: 20)
                        .clip(true)

                        // Delete Group/Channel（iOS .peerActions，仅超级群/频道群主）
                        if (this.showDeleteRow()) {
                            Column {
                                Text(this.getLeaveLabel())
                                    .fontSize(17)
                                    .fontColor(0xFFFF3B30)
                                    .width(100.percent)
                                    .height(50)
                                    .padding(left: 16)
                                    .onClick({ _ => this.showLeaveConfirm = true })
                            }
                            .width(92.percent)
                            .backgroundColor(0xFFFFFFFF)
                            .borderRadius(14)
                            .margin(top: 20)
                            .clip(true)
                        }

                        Blank().height(60)
                    }
                    .width(100.percent)
                }
                .width(100.percent)
                .layoutWeight(1)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFEFEFF4)
            .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())

            if (this.showLeaveConfirm) { this.leaveConfirmDialog() }
            if (this.showToast) {
                Column {
                    Text(this.toastMessage)
                        .fontSize(14)
                        .fontColor(0xFFFFFFFF)
                        .padding(left: 20, right: 20, top: 10, bottom: 10)
                        .backgroundColor(0xCC333333)
                        .borderRadius(20)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.End)
                .alignItems(HorizontalAlign.Center)
                .padding(bottom: 100)
                .onClick({ _ => this.showToast = false })
            }
        }
        .onAppear({ => this.ensureLoaded() })
    }

    /** 行右侧值统一由状态派生（@Builder 形参按值捕获，不随 @State 更新）。 */
    private func editRowValue(title: String): String {
        if (title == "Group Type" || title == "Channel Type") { return this.getChannelTypeLabel() }
        if (title == "Invite Links") { return if (this.inviteLinkCount >= 0) { "${this.inviteLinkCount}" } else { "" } }
        if (title == "Chat History") { return if (this.historyHidden) { "Hidden" } else { "Visible" } }
        if (title == "Topics") { return "Disabled" }
        if (title == "Reactions") { return "All Reactions" }
        if (title == "Welcome Message") { return "Off" }
        if (title == "Permissions") { return this.getPermissionsLabel() }
        if (title == "Administrators") { return this.getAdminsSubtitle() }
        if (title == "Members") { return if (this.membersCount > 0) { "${this.membersCount}" } else { "" } }
        if (title == "Removed Users") { return this.getRemovedSubtitle() }
        return ""
    }

    /** 带彩色方形图标的设置行（iOS 编辑屏样式）；enabled=false 的行为灰色、点击提示不可用。 */
    @Builder
    func editIconRow(title: String, icon: String, color: UInt32, enabled: Bool) {
        Row {
            Column {
                if (icon == "group") {
                    Image(@r(app.media.contact_ic_group)).width(20).height(20).fillColor(0xFFFFFFFF)
                } else if (icon == "link") {
                    Image(@r(app.media.chatroom_ic_link)).width(20).height(20).fillColor(0xFFFFFFFF)
                } else if (icon == "history" || icon == "welcome") {
                    Image(@r(app.media.set2_ic_chatbubble)).width(20).height(20).fillColor(0xFFFFFFFF)
                } else if (icon == "topics" || icon == "members") {
                    Image(@r(app.media.misc_ic_members)).width(20).height(20).fillColor(0xFFFFFFFF)
                } else if (icon == "reactions") {
                    Image(@r(app.media.set2_ic_gift)).width(20).height(20).fillColor(0xFFFFFFFF)
                } else if (icon == "permissions") {
                    Image(@r(app.media.callui_ic_lock)).width(20).height(20).fillColor(0xFFFFFFFF)
                } else if (icon == "admins") {
                    Image(@r(app.media.set2_ic_premiumstar)).width(20).height(20).fillColor(0xFFFFFFFF)
                } else {
                    Image(@r(app.media.callui_ic_close)).width(18).height(18).fillColor(0xFFFFFFFF)
                }
            }
            .width(30)
            .height(30)
            .borderRadius(8)
            .backgroundColor(if (enabled) { color } else { 0xFFC7C7CC })
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(right: 14)
            Text(title)
                .fontSize(17)
                .fontColor(if (enabled) { 0xFF000000 } else { 0xFF8E8E93 })
                .layoutWeight(1)
            if (this.editRowValue(title).size > 0) {
                Text(this.editRowValue(title))
                    .fontSize(17)
                    .fontColor(0xFF8E8E93)
                    .margin(right: 6)
            }
            Image(@r(app.media.item_list_disclosure_arrow))
                .width(8)
                .height(14)
                .fillColor(0xFFC7C7CC)
        }
        .width(100.percent)
        .height(50)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.handleEditRowTap(title, enabled) })
    }

    /** 类型编辑（展开在 Group Type 行之下）。 */
    @Builder
    func channelTypeEditor() {
        Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 16)
        Row {
            Text(if (this.isPublicChannel) { "◉" } else { "○" })
                .fontSize(20)
                .fontColor(0xFF007AFF)
                .margin(right: 12)
            Text(if (this.groupType == "channel" && !this.isMegagroup) { "Public Channel" } else { "Public Group" })
                .fontSize(15)
                .fontColor(0xFF000000)
                .layoutWeight(1)
        }
        .width(100.percent)
        .height(44)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.isPublicChannel = true })
        Row {
            Text(if (!this.isPublicChannel) { "◉" } else { "○" })
                .fontSize(20)
                .fontColor(0xFF007AFF)
                .margin(right: 12)
            Text(if (this.groupType == "channel" && !this.isMegagroup) { "Private Channel" } else { "Private Group" })
                .fontSize(15)
                .fontColor(0xFF000000)
                .layoutWeight(1)
        }
        .width(100.percent)
        .height(44)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.isPublicChannel = false })
        if (this.isPublicChannel) {
            Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 16)
            Row {
                Text("t.me/")
                    .fontSize(15)
                    .fontColor(0xFF999999)
                TextInput(text: this.channelUsernameInput, placeholder: trSource("username"))
                    .fontSize(15)
                    .layoutWeight(1)
                    .backgroundColor(0xFFFFFFFF)
                    .onChange({ value: String => this.channelUsernameInput = value })
            }
            .width(100.percent)
            .height(44)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
        }
        Row {
            Text(trSource("Save"))
                .fontSize(16)
                .fontColor(0xFF007AFF)
                .fontWeight(FontWeight.Medium)
        }
        .width(100.percent)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .onClick({ _ => this.saveChannelUsername() })
    }

    private func handleEditRowTap(title: String, enabled: Bool): Unit {
        if (!enabled) {
            if (title == "Group Type") {
                this.showToastMsg("Only the owner can change the group type")
            } else {
                this.showToastMsg("${title}: not available yet")
            }
            return
        }
        if (title == "Group Type" || title == "Channel Type") {
            this.showChannelType = !this.showChannelType
        } else if (title == "Chat History") {
            this.doToggleHistoryHidden()
        } else {
            this.handleActionTap(title)
        }
    }

    // ==================== @Builder helpers ====================

    @Builder
    func toggleRow(title: String, subtitle: String, isOn: Bool, onChange: (Bool) -> Unit) {
        Row {
            Column {
                Text(title)
                    .fontSize(16)
                    .fontColor(0xFF000000)
                if (subtitle.size > 0) {
                    Text(subtitle)
                        .fontSize(12)
                        .fontColor(0xFF8E8E93)
                        .margin(top: 2)
                }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle(ToggleType.Switch, isOn: isOn)
                .selectedColor(0xFF007AFF)
                .onChange({ v: Bool =>
                    onChange(v)
                })
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 8, bottom: 8)
        .alignItems(VerticalAlign.Center)
        .constraintSize(minHeight: 52)
    }

    /**
     * 行副标题在 builder 内按 title 从 @State 现算：@Builder 值参在首帧固化，
     * 异步载入的成员数/权限位若当参数传入不会刷新。
     */
    private func rowSubtitle(title: String): String {
        if (title == "Members") { return "${this.membersCount}" }
        if (title == "Permissions") { return this.getPermissionsLabel() }
        if (title == "Administrators") { return this.getAdminsSubtitle() }
        if (title == "Removed Users") { return this.getRemovedSubtitle() }
        return ""
    }

    @Builder
    func actionRow(title: String) {
        Row {
            Column {
                Text(title)
                    .fontSize(16)
                    .fontColor(0xFF000000)
                if (this.rowSubtitle(title).size > 0) {
                    Text(this.rowSubtitle(title))
                        .fontSize(13)
                        .fontColor(0xFF8E8E93)
                        .margin(top: 2)
                }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(">")
                .fontSize(16)
                .fontColor(0xFFC7C7CC)
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.handleActionTap(title) })
    }

    @Builder
    func editNameDialog() {
        Column {
            Column {
                Text("Edit Group Name")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 16)
                TextInput(text: this.editNameText)
                    .width(100.percent)
                    .height(40)
                    .backgroundColor(0xFFF0F0F0)
                    .borderRadius(8)
                    .padding(left: 12, right: 12)
                    .onChange({ value: String => this.editNameText = value })
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0xFF0088CC)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.showEditName = false })
                    Text(trSource("Save"))
                        .fontSize(17)
                        .fontColor(0xFF0088CC)
                        .fontWeight(FontWeight.Bold)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.saveGroupName() })
                }
                .width(100.percent)
                .margin(top: 16)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.showEditName = false })
    }

    @Builder
    func editAboutDialog() {
        Column {
            Column {
                Text(trSource("Edit Description"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 16)
                TextArea(text: this.editAboutText)
                    .width(100.percent)
                    .height(120)
                    .backgroundColor(0xFFF0F0F0)
                    .borderRadius(8)
                    .padding(left: 12, right: 12)
                    .onChange({ value: String => this.editAboutText = value })
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0xFF0088CC)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.showEditAbout = false })
                    Text(trSource("Save"))
                        .fontSize(17)
                        .fontColor(0xFF0088CC)
                        .fontWeight(FontWeight.Bold)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.saveGroupAbout() })
                }
                .width(100.percent)
                .margin(top: 16)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.showEditAbout = false })
    }

    @Builder
    func leaveConfirmDialog() {
        Column {
            Column {
                Text(this.getLeaveLabel())
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 8)
                Text(this.getDeleteDialogText())
                    .fontSize(14)
                    .fontColor(0xFF666666)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 20)
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0xFF007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.showLeaveConfirm = false })
                    Text(trSource("Delete"))
                        .fontSize(17)
                        .fontColor(0xFFFF3B30)
                        .fontWeight(FontWeight.Bold)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.doLeave() })
                }
                .width(100.percent)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.showLeaveConfirm = false })
    }

    private func handleActionTap(title: String): Unit {
        if (title == "Members") {
            routerPush("GroupMembersPage", "${getSelectedChatId()}|${this.accessHash}|${this.groupName}")
        } else if (title == "Permissions") {
            routerPush("GroupPermissionsPage")
        } else if (title == "Administrators") {
            routerPush("AdminManagePage")
        } else if (title == "Removed Users") {
            routerPush("BlacklistPage", "${getSelectedChatId()}|${this.accessHash}|${this.groupName}")
        } else if (title == "Invite Links") {
            routerPush("InviteLinksPage")
        } else if (title == "Shared Media") {
            routerPush("SharedMediaPage")
        }
    }
}

/** 从相册选择器结果 JSON 里取第一条 "paths":["…"]。 */
private func groupDetailsFirstPickedPath(json: String): String {
    match (json.indexOf("\"paths\"")) {
        case Some(i) =>
            let rest = json[i..json.size]
            match (rest.indexOf("[\"")) {
                case Some(a) =>
                    let after = rest[(a + 2)..rest.size]
                    match (after.indexOf("\"")) {
                        case Some(b) => return after[0..b]
                        case None => return ""
                    }
                case None => return ""
            }
        case None => return ""
    }
}
