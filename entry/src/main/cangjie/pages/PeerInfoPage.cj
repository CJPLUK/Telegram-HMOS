package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.utils.{secretChatKeyColorGridFromBytes, secretChatKeyEmojiFingerprint}
import ohos_app_cangjie_entry.bindings.KeyColorGrid
import ohos_app_cangjie_entry.router.*
import ohos.resource.__GenerateResource__
import std.collection.ArrayList
import std.collection.HashMap
import std.time.DateTime
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.viewmodels.getChatListVM
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}

/**
 * PeerInfoPage — 用户/群组/频道详情页 (P2-130 header/badges + P2-140 More 菜单重构)
 *
 * 对应 iOS PeerInfoScreen（PeerInfoScreen.swift）。
 *
 * 支持三种 peer 类型（由 getSelectedChatPeerType() 决定）：
 *   - "user"    → 调用 PeerInfoService.getUserFullInfo() → 显示 bio/phone/共享媒体/操作按钮
 *   - "channel" → 调用 PeerInfoService.getGroupFullInfo() → 显示 about/成员数/管理入口
 *   - "chat"    → 调用 PeerInfoService.getGroupFullInfo() → 显示 about/成员/退出
 *
 * P2-130 新增：
 *   - 折叠头：下滑时头像缩放 + 标题透明度变化（Scroller + @State scrollOffset）
 *   - 徽章渲染：verified 蓝标、scam/fake 红标、premium emoji-status 金标（名字旁）
 *   - 快捷按钮行：Message / Mute / Call(defer) / Video(defer) / More
 *   - 头部背景 accent 色（peer 的 nameColor / 渐变兜底）
 *   - 头像区使用 PeerInfoAvatarListComponent（P2-142 多图轮播 + 进度条）
 *
 * P2-140 新增：
 *   - More 菜单（ContextMenuView 受控叠加层）：
 *       Report（messages.report 服务端分级选项与备注）
 *       Share Contact（defer — AttachmentService.sendContact 需聊天上下文）
 *       Start Secret Chat（TelegramCore_SecretChatsService.requestEncryption）
 *       Clear History（MessagesService.clearHistory）
 *       Auto-Delete（PeersService.setHistoryTTL，默认关闭=0）
 *       Block/Unblock（ContactsService.blockUser/unblockUser）
 *
 * 混合迁移改动（recipe §Phase 4，pushed page 处理）：
 *   - @Component → @HybridComponentEntry @Component；NavDestination 壳由 ets/pages/PeerInfoPage.ets 提供
 *   - 删 @Consume NavPathStack
 *   - build() 根去掉 NavDestination()+.title/.hideTitleBar 包裹，只留 Stack，末尾挂 .onAppear
 *   - pushPathByName(name, "") → routerPush(name)；pop(animated:true) → routerPop()
 *   - aboutToAppear（有实逻辑：读服务/加载）→ ensureLoaded()（loaded 守卫）+ 根 .onAppear
 * 架构约束（S-013）：@Builder 不能修饰 private func，去掉 private。
 * 架构约束（S-001）：@State 写入必须在主线程（launch{}）。
 * 架构约束（S-005）：build/Builder 内不能有 let/var。
 * 架构约束（S-006）：Length 参数用 .vp/.percent，不裸整数。
 */
// 混合嵌入页没有 onPageShow：加人等子页改完数据后通过本回调让资料页重新拉取成员。
private var _peerInfoRefreshHandler: Option<() -> Unit> = None

public func notifyPeerInfoChanged(): Unit {
    match (_peerInfoRefreshHandler) {
        case Some(handler) => handler()
        case None => ()
    }
}

@HybridComponentEntry
@Component
public class PeerInfoPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ========== 基础信息 ==========
    @State var peerType: String = ""       // "user" | "channel" | "chat"
    @State var peerId: Int64 = 0
    @State var displayName: String = ""
    @State var username: String = ""
    @State var avatarLetter: String = "?"
    @State var accessHash: Int64 = 0
    @State var avatarPhotoPath: String = ""

    // ========== 徽章/状态标志 (P2-130) ==========
    @State var isVerified: Bool = false    // 蓝色 verified checkmark
    @State var isScam: Bool = false        // 红色 SCAM 标签
    @State var isFake: Bool = false        // 红色 FAKE 标签
    @State var isPremium: Bool = false     // Premium 金星 emoji-status
    @State var isBot: Bool = false         // 机器人

    // ========== 用户字段 ==========
    @State var bio: String = ""
    @State var phone: String = ""
    @State var isBlocked: Bool = false
    @State var isContact: Bool = false
    @State var isMuted: Bool = false
    // 群布局「more」浮层菜单锚点：动作按钮行底边的屏幕 y（vp）
    @State var moreMenuAnchorY: Float64 = 0.0
    // 每次切换静音 +1：>0 时 mute 图标重建并播放切换动画
    @State var muteAnimationSerial: Int64 = 0

    // ========== 群组/频道字段 ==========
    @State var about: String = ""
    @State var membersCount: Int32 = 0
    @State var onlineCount: Int32 = 0
    @State var canViewParticipants: Bool = true
    @State var isMegagroup: Bool = false
    @State var isBroadcast: Bool = false
    @State var isCreator: Bool = false
    private var startingVideoChat: Bool = false
    @State var canEditInfo: Bool = false
    @State var isLeft: Bool = false
    // S5-09: channelFull.linked_chat_id 对应的讨论群（iOS peerInfoHeaderButtons .discussion）
    @State var linkedChatId: Int64 = 0
    @State var linkedChatTitle: String = ""
    @State var linkedChatIsChannel: Bool = true
    @State var linkedChatUsername: String = ""
    // S5-20: share link 行 → 分享面板（iOS ShareController）
    @State var showShareSheet: Bool = false
    @State var shareLink: String = ""
    // S4-23 / S5-21: 描述卡长按 → Copy
    @State var showCopyMenu: Bool = false
    @State var copyMenuItems: Array<ContextMenuItem> = Array<ContextMenuItem>()
    // S4-05: Mute 按钮菜单（iOS PeerInfoScreenPerformButtonAction .mute：Mute for... / Disable Sound / Customize / Mute Forever）
    @State var showMuteMenu: Bool = false
    @State var muteMenuItems: Array<ContextMenuItem> = Array<ContextMenuItem>()
    @State var soundDisabled: Bool = false
    @State var showMuteCustom: Bool = false
    @State var showNotifyCustomize: Bool = false
    @State var showPreviewsEnabled: Bool = true
    // 描述卡长按跟踪
    private var rowPressGeneration: Int64 = 0
    private var rowPressActive: Bool = false
    private var rowPressX: Float64 = 0.0
    private var rowPressY: Float64 = 0.0
    private var suppressRowClick: Bool = false
    // 群/频道资料页（iOS PeerInfoScreen 群组形态）：成员预览列表
    @State var groupMembers: ArrayList<MemberInfo> = ArrayList<MemberInfo>()
    @State var groupMembersLoaded: Bool = false

    // 成员行长按菜单（iOS openMemberContextMenu）
    @State var showMemberMenu: Bool = false
    @State var memberMenuItems: Array<ContextMenuItem> = Array<ContextMenuItem>()
    @State var memberMenuUserId: Int64 = 0
    @State var memberMenuAccessHash: Int64 = 0
    @State var memberMenuName: String = ""
    @State var memberMenuIsAdmin: Bool = false
    @State var memberMenuFlags: Int32 = 0
    @State var memberMenuRank: String = ""
    @State var showRemoveMemberConfirm: Bool = false
    @State var showMemberTagEditor: Bool = false
    @State var memberTagInput: String = ""
    @State var pressedMemberId: Int64 = 0
    // 成员行在屏幕上的位置（onAreaChange 记录），浮层菜单锚在被按行下方
    private var memberRowTop: HashMap<Int64, Float64> = HashMap<Int64, Float64>()
    private var memberRowHeight: HashMap<Int64, Float64> = HashMap<Int64, Float64>()
    @State var memberMenuTop: Float64 = 0.0
    @State var pageHeightVp: Float64 = 0.0
    private var memberPressGeneration: Int64 = 0
    private var memberPressActive: Bool = false
    private var memberPressX: Float64 = 0.0
    private var memberPressY: Float64 = 0.0
    private var suppressMemberClick: Bool = false
    // 群默认权限位（chatBannedRights.flags）：iOS hasBannedPermission(.banChangeInfo) 依赖
    @State var defaultBannedFlags: Int32 = 0
    // iOS CachedChannelFlags.canDeleteHistory（channelFull.can_delete_channel）；普通群 = 群主
    @State var canDeleteHistory: Bool = false
    // Leave 对话框当前是"离开"还是"为所有成员删除"（iOS openLeavePeer(delete:)）
    @State var leaveIsDelete: Bool = false

    // ========== UI 状态 ==========
    @State var isLoading: Bool = true
    @State var toastMessage: String = ""
    @State var showToast: Bool = false
    private var toastGeneration: Int64 = 0
    @State var showBlockConfirm: Bool = false
    @State var showLeaveConfirm: Bool = false
    @State var showMoreMenu: Bool = false
    @State var showAutoDeleteConfirm: Bool = false
    // S226: 自定义时长选择器（对位 iOS ChatTimerScreen(mode:.autoremove)）
    @State var showAutoDeleteCustom: Bool = false
    @State var showClearHistoryConfirm: Bool = false
    @State var showPeerReport: Bool = false
    // chatBannedRights 位：change_info=flags.10 invite_users=flags.15（telegram_api.tl）
    private let bannedChangeInfoBit: Int32 = 1 << 10
    @State var reportLoading: Bool = false
    @State var reportNeedsComment: Bool = false
    @State var reportTitle: String = "Report"
    @State var reportOptions: ArrayList<String> = ArrayList<String>()
    @State var reportComment: String = ""
    private var reportOptionBytes: ArrayList<Array<Byte>> = ArrayList<Array<Byte>>()
    private var reportCommentOption: Array<Byte> = Array<Byte>(0, repeat: 0)

    // ========== 密钥可视化状态 (P2-148b) — 仅 peerType == "secret" 时使用 ==========
    @State var secretChatKeyGrid: KeyColorGrid = KeyColorGrid()
    @State var secretChatKeyEmoji: String = ""
    @State var secretChatKeyLoaded: Bool = false

    // ========== 折叠头状态 (P2-130) ==========
    // scrollOffset 累计值（vp）
    @State var scrollOffset: Float64 = 0.0
    // 头部折叠阈值（vp）：超过此值时标题完全折叠
    private let headerCollapseThreshold: Float64 = 180.0
    private let scroller: Scroller = Scroller()

    // ========== More 菜单数据 ==========
    private var moreMenuItems: Array<ContextMenuItem> = Array<ContextMenuItem>()

    // 混合嵌入下无页面生命周期：首次 .onAppear 触发一次加载
    @State var loaded: Bool = false
    // TC-0541 C6：列表卡/页底订 presentation，对位源 PeerInfoScreen.presentationData
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true

        this.peerId = getSelectedChatId()
        this.peerType = getSelectedChatPeerType()
        this.displayName = getSelectedChatName()
        this.username = getSelectedChatUsername()

        if (this.displayName.size > 0) {
            this.avatarLetter = this.displayName.toRuneArray()[0].toString()
        }

        this.injectAccessHashFromCache()
        if (this.peerType != "user") {
            _peerInfoRefreshHandler = Some({ => this.loadGroupFullInfo() })
        }
        if (this.peerType == "user") {
            this.avatarPhotoPath = getUserPhotoService().getUserPhotoPath(this.peerId)
        } else {
            this.avatarPhotoPath = getUserPhotoService().getChatPhotoPath(this.peerId)
            let ids = ArrayList<Int64>()
            ids.add(this.peerId)
            getUserPhotoService().requestFullPhotosForChats(ids)
        }
        this.buildMoreMenuItems()

        if (this.peerType == "secret") {
            this.loadSecretChatKey()
        } else if (this.peerType == "user") {
            this.loadUserFullInfo()
        } else {
            this.loadGroupFullInfo()
            this.loadMuteState()
        }
    }

    /** 打开时从服务端通知设置取当前静音态，避免按钮初始态与实际不符。 */
    private func loadMuteState(): Unit {
        let pt = this.peerType
        let pid = this.peerId
        let _ = spawn {
            let (muteUntil, soundNone) = getPeerInfoService().getPeerNotifyState(pt, pid)
            let nowSec = Int32(DateTime.now().toUnixTimeStamp().toSeconds())
            let muted = muteUntil == 2147483647 || (muteUntil > 0 && muteUntil > nowSec)
            launch {
                this.isMuted = muted
                this.soundDisabled = soundNone
            }
        }
    }

    // ==================== S4-05: Mute 按钮菜单 ====================

    /** iOS：已静音时点 Unmute 直接取消（无菜单）；未静音时弹出菜单。 */
    private func onMuteButtonTap(): Unit {
        if (this.isMuted) {
            this.doSetMuteUntil(0, "Notifications are unmuted.")
            return
        }
        this.muteMenuItems = this.buildMuteMenuItems()
        this.showMuteMenu = true
    }

    private func buildMuteMenuItems(): Array<ContextMenuItem> {
        let items = ArrayList<ContextMenuItem>()
        items.add(ContextMenuItem(title: "Mute for...", iconRes: @r(app.media.clist_ic_unmute),
            onClick: { => this.reopenMuteMenu(true) }))
        items.add(ContextMenuItem.separator())
        if (this.soundDisabled) {
            items.add(ContextMenuItem(title: "Enable Sound", onClick: { => this.doSetSound(false) }))
        } else {
            items.add(ContextMenuItem(title: "Disable Sound", onClick: { => this.doSetSound(true) }))
        }
        items.add(ContextMenuItem(title: "Customize", onClick: { =>
            this.showMuteMenu = false
            this.showNotifyCustomize = true
        }))
        items.add(ContextMenuItem(title: "Mute Forever", iconRes: @r(app.media.clist_ic_mute), destructive: true,
            onClick: { => this.doSetMuteUntil(2147483647, "Notifications are muted.") }))
        return items.toArray()
    }

    /**
     * ContextPopoverMenu 在 item.onClick() 之后会调用 onDismiss 把菜单关掉（iOS 是 pushItems/popItems 原地切换），
     * 所以换层级要等这次点击处理完再重新打开。
     */
    private func reopenMuteMenu(submenu: Bool): Unit {
        let _ = spawn {
            sleep(Duration.millisecond * 40)
            launch {
                if (submenu) {
                    this.openMuteForSubmenu()
                } else {
                    this.muteMenuItems = this.buildMuteMenuItems()
                    this.showMuteMenu = true
                }
            }
        }
    }

    /** iOS PeerInfo_MuteFor 子菜单：Back / 1 hour / 8 hours / 1 day / 7 days / Mute until... */
    private func openMuteForSubmenu(): Unit {
        let items = ArrayList<ContextMenuItem>()
        items.add(ContextMenuItem(title: "Back", onClick: { => this.reopenMuteMenu(false) }))
        items.add(ContextMenuItem.separator())
        items.add(ContextMenuItem(title: "Mute for 1 hour", onClick: { => this.doMuteFor(3600, "1 hour") }))
        items.add(ContextMenuItem(title: "Mute for 8 hours", onClick: { => this.doMuteFor(28800, "8 hours") }))
        items.add(ContextMenuItem(title: "Mute for 1 day", onClick: { => this.doMuteFor(86400, "1 day") }))
        items.add(ContextMenuItem(title: "Mute for 7 days", onClick: { => this.doMuteFor(604800, "7 days") }))
        items.add(ContextMenuItem(title: "Mute until...", onClick: { =>
            this.showMuteMenu = false
            this.showMuteCustom = true
        }))
        this.muteMenuItems = items.toArray()
        this.showMuteMenu = true
    }

    private func muteForIntervalText(seconds: Int64): String {
        if (seconds < 3600) {
            let m = seconds / 60
            return if (m == 1) { "1 minute" } else { "${m} minutes" }
        }
        if (seconds < 86400) {
            let h = seconds / 3600
            return if (h == 1) { "1 hour" } else { "${h} hours" }
        }
        let d = seconds / 86400
        return if (d == 1) { "1 day" } else { "${d} days" }
    }

    private func doMuteFor(seconds: Int64, label: String): Unit {
        let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
        var until = nowSec + seconds
        if (until > 2147483646) { until = 2147483646 }
        this.doSetMuteUntil(Int32(until), "Notifications are muted for ${label}.")
    }

    /** account.updateNotifySettings(mute_until)；成功后同步本页与会话列表静音态并提示。 */
    private func doSetMuteUntil(muteUntil: Int32, toast: String): Unit {
        let pt = this.peerType
        let pid = this.peerId
        this.showMuteMenu = false
        this.showMuteCustom = false
        let _ = spawn {
            let ok = getPeerInfoService().updatePeerNotifySettings(pt, pid, muteUntil: Some(muteUntil))
            launch {
                if (ok) {
                    let newMuted = muteUntil > 0
                    this.isMuted = newMuted
                    this.muteAnimationSerial = this.muteAnimationSerial + 1
                    this.applyPeerMuteState(pid, newMuted)
                    this.showToastMsg(toast)
                } else {
                    this.showToastMsg("Could not update notification settings")
                }
            }
        }
    }

    /** iOS updatePeerNotificationSoundInteractive(sound: .none / .default) */
    private func doSetSound(none: Bool): Unit {
        let pt = this.peerType
        let pid = this.peerId
        this.showMuteMenu = false
        let _ = spawn {
            let ok = getPeerInfoService().updatePeerNotifySettings(pt, pid, soundNone: Some(none))
            launch {
                if (ok) {
                    this.soundDisabled = none
                    this.showToastMsg(if (none) { "You will receive silent notifications." } else { "You will receive notifications with sound." })
                } else {
                    this.showToastMsg("Could not update notification settings")
                }
            }
        }
    }

    private func doSetShowPreviews(enabled: Bool): Unit {
        let pt = this.peerType
        let pid = this.peerId
        let _ = spawn {
            let ok = getPeerInfoService().updatePeerNotifySettings(pt, pid, showPreviews: Some(enabled))
            launch {
                if (ok) { this.showPreviewsEnabled = enabled } else { this.showToastMsg("Could not update notification settings") }
            }
        }
    }

    // ==================== S4-23 / S5-21 / S5-20：描述长按复制、share link 分享 ====================

    private func beginRowPress(x: Float64, y: Float64, onLongPress: () -> Unit): Unit {
        this.rowPressX = x
        this.rowPressY = y
        this.rowPressActive = true
        this.rowPressGeneration += 1
        let generation = this.rowPressGeneration
        spawn {
            sleep(Duration.millisecond * 420)
            launch {
                if (this.rowPressActive && generation == this.rowPressGeneration) {
                    this.rowPressActive = false
                    this.suppressRowClick = true
                    onLongPress()
                }
            }
        }
    }

    private func moveRowPress(x: Float64, y: Float64): Unit {
        if (!this.rowPressActive) { return }
        let dx = x - this.rowPressX
        let dy = y - this.rowPressY
        if (dx * dx + dy * dy > 100.0) {
            this.rowPressActive = false
            this.rowPressGeneration += 1
        }
    }

    private func endRowPress(): Unit {
        this.rowPressActive = false
        this.rowPressGeneration += 1
    }

    private func consumeSuppressedClick(): Bool {
        if (this.suppressRowClick) {
            this.suppressRowClick = false
            return true
        }
        return false
    }

    /** iOS PeerInfoScreen ItemAbout longTapAction → Copy → ChannelProfile.ToastAboutCopied "Copied to clipboard." */
    private func openAboutCopyMenu(): Unit {
        let text = this.about
        this.copyMenuItems = [
            ContextMenuItem(title: "Copy", onClick: { =>
                setClipboardText(text)
                this.showCopyMenu = false
                this.showToastMsg("Copied to clipboard.")
            })
        ]
        this.showCopyMenu = true
    }

    private func openShareSheet(link: String): Unit {
        this.shareLink = link
        this.showShareSheet = true
    }

    // ==================== S5-09：Discuss ====================

    private func openDiscussion(): Unit {
        if (this.linkedChatId == 0) { return }
        let peerType = if (this.linkedChatIsChannel) { "channel" } else { "chat" }
        setSelectedChat(this.linkedChatId, this.linkedChatTitle, peerType)
        setSelectedChatUsername(this.linkedChatUsername)
        routerPush("ChatRoomPage", this.linkedChatTitle)
    }

    private func openSharedMediaTab(tab: Int64): Unit {
        routerPush("SharedMediaPage", "${this.peerType}:${this.peerId}:${tab}")
    }

    private func showsDiscussButton(): Bool {
        return this.peerType == "channel" && this.isBroadcast && this.linkedChatId != 0 && this.linkedChatTitle.size > 0
    }

    /**
     * 从 RealChatListService 缓存中注入 accessHash、徽章标志、静音状态
     */
    private func injectAccessHashFromCache(): Unit {
        let chatListService = getRealChatListService()
        let infoService = getPeerInfoService()

        if (this.peerType == "user") {
            match (chatListService.getCachedUser(this.peerId)) {
                case Some(user) =>
                    infoService.registerUserAccessHash(user.id, user.accessHash)
                    this.phone = user.phone
                    this.isContact = user.isContact
                    this.accessHash = user.accessHash
                    this.isPremium = user.isPremium
                    // Badge flags from UserResponse (flags.17/24/26/14) — iOS TelegramUser.swift verified sources
                    this.isVerified = user.isVerified
                    this.isScam = user.isScam
                    this.isFake = user.isFake
                    this.isBot = user.isBot
                case None => ()
            }
        } else if (this.peerType == "channel") {
            match (chatListService.getCachedChat(this.peerId)) {
                case Some(chat) =>
                    infoService.registerChannelAccessHash(chat.id, chat.accessHash)
                    getRealMessageService().cacheChannelAccessHash(chat.id, chat.accessHash)
                    this.accessHash = chat.accessHash
                    this.isMegagroup = chat.isMegagroup
                    this.isBroadcast = chat.isBroadcast
                    this.isCreator = chat.isCreator
                    this.canEditInfo = chat.canEditInfo
                    this.isLeft = chat.isLeft
                    this.defaultBannedFlags = chat.defaultBannedRightsFlags
                    this.isVerified = chat.isVerified
                    this.isScam = chat.isScam
                    this.isFake = chat.isFake
                    this.membersCount = chat.participantsCount
                case None => ()
            }
        } else if (this.peerType == "chat") {
            match (chatListService.getCachedChat("chat", this.peerId)) {
                case Some(chat) => this.applyLegacyGroupFlags(chat)
                case None =>
                    // W6 S4-25：冷启动后基础群实体可能还没进内存缓存，isCreator/canEditInfo 全 false
                    // → "Add Members" 消失；loadGroupFullInfo 会用 messages.getChats 补拉再回填。
                    Hilog.info(0, "CjTelegram", "[PeerInfoPage] legacy group ${this.peerId} not in chat cache, flags deferred to getChats")
            }
        }
    }

    /** 基础群 Chat 实体 → 页面角色/标志（iOS TelegramGroup.role / flags / defaultBannedRights） */
    private func applyLegacyGroupFlags(chat: ChatResponse): Unit {
        this.isCreator = chat.isCreator
        this.canEditInfo = chat.canEditInfo
        this.isLeft = chat.isLeft
        this.defaultBannedFlags = chat.defaultBannedRightsFlags
        // iOS canDeletePeerGloballyAsCreator：普通群群主无条件可解散
        this.canDeleteHistory = chat.isCreator
        this.isVerified = chat.isVerified
        this.isScam = chat.isScam
        this.isFake = chat.isFake
        if (chat.participantsCount > 0) { this.membersCount = chat.participantsCount }
        Hilog.info(0, "CjTelegram",
            "[PeerInfoPage] legacy group flags chat=${chat.id} creator=${chat.isCreator} canEdit=${chat.canEditInfo} left=${chat.isLeft} members=${chat.participantsCount}")
    }

    /**
     * 构建 More 菜单数据（在 aboutToAppear 中调用，避免 build 内 let/var）
     * 调用链：
     *   Block/Unblock → ContactsService.blockUser / unblockUser
     *   Clear History  → MessagesService.clearHistory
     *   Auto-Delete    → PeersService.setHistoryTTL (period=0 关闭)
     *   Secret Chat    → TelegramCore_SecretChatsService.requestEncryption (user only)
     *   Report         → messages.report（空消息 id 表示举报 peer）
     *   Share Contact  → defer（需聊天上下文）
     */
    private func buildMoreMenuItems(): Unit {
        if (this.peerType == "user") {
            this.moreMenuItems =
            [
                ContextMenuItem(
                    title: "Report",
                    iconText: "",
                    destructive: false,
                    enabled: true,
                    onClick: { => this.startPeerReport() }
                ),
                ContextMenuItem(
                    title: "Share Contact",
                    iconText: "",
                    destructive: false,
                    enabled: true,
                    onClick: { => this.showToastMsg("Share Contact: not yet implemented") }
                ),
                ContextMenuItem(
                    title: "Start Secret Chat",
                    iconText: "",
                    destructive: false,
                    enabled: true,
                    onClick: { => this.doStartSecretChat() }
                ),
                ContextMenuItem(
                    title: "Clear History",
                    iconText: "",
                    destructive: true,
                    enabled: true,
                    onClick: { => this.showClearHistoryConfirm = true }
                ),
                ContextMenuItem(
                    title: "Auto-Delete",
                    iconText: "",
                    destructive: false,
                    enabled: true,
                    onClick: { => this.showAutoDeleteConfirm = true }
                ),
                ContextMenuItem(
                    title: if (this.isBlocked) { "Unblock User" } else { "Block User" },
                    iconText: "",
                    destructive: !this.isBlocked,
                    enabled: true,
                    onClick: { => this.showBlockConfirm = true }
                )
            ]
            return
        }
        if (this.peerType == "chat" || this.peerType == "channel") {
            this.moreMenuItems = this.buildGroupMoreMenuItems()
            return
        }
        this.moreMenuItems = [
            ContextMenuItem(
                title: "Clear History", iconText: "", destructive: true, enabled: true,
                onClick: { => this.showClearHistoryConfirm = true }
            ),
            ContextMenuItem(
                title: "Auto-Delete", iconText: "", destructive: false, enabled: true,
                onClick: { => this.showAutoDeleteConfirm = true }
            )
        ]
    }

    // ==================== 群组角色判定（对位 iOS PeerInfoScreenPerformButtonAction / PeerInfoData） ====================

    /** iOS canManage = isCreator || adminRights != nil（超级群）；普通群 creator/admin */
    private func canManageGroup(): Bool {
        return this.isCreator || this.canEditInfo
    }

    /**
     * iOS canSetupAutoremoveTimeout：
     *   legacyGroup → !group.hasBannedPermission(.banChangeInfo)（群主/管理员不受默认权限限制）
     *   channel     → channel.hasPermission(.changeInfo)
     */
    private func canSetupAutoDelete(): Bool {
        if (this.peerType == "chat") {
            return this.isCreator || this.canEditInfo || (this.defaultBannedFlags & this.bannedChangeInfoBit) == 0
        }
        return this.isCreator || this.canEditInfo
    }

    /** iOS canReport：普通群除群主外都可举报；超级群/频道仅非管理员成员可举报 */
    private func canReportPeer(): Bool {
        if (this.peerType == "chat") { return !this.isCreator }
        return !this.isCreator && !this.canEditInfo
    }

    /** iOS ClearPeerHistory.canClearForMyself：普通群总可；公开超级群和广播频道不可 */
    private func canClearForMyself(): Bool {
        if (this.peerType == "chat") { return true }
        if (this.isBroadcast) { return false }
        return this.username.size == 0
    }

    /** iOS ClearPeerHistory.canClearForEveryone：普通群群主；超级群/频道看 canDeleteHistory */
    private func canClearForEveryone(): Bool {
        if (this.peerType == "chat") { return this.isCreator }
        return this.canDeleteHistory
    }

    private func isGroupPeer(): Bool {
        return this.peerType == "chat" || (this.peerType == "channel" && !this.isBroadcast)
    }

    /**
     * iOS peerInfoHeaderButtons(isExpanded: true)：
     *   legacyGroup 永远没有 leave 头部按钮（只在 More 里）；
     *   channel 成员有 leave，但 canManage 时被剥离进 More 菜单。
     */
    private func showsLeaveHeaderButton(): Bool {
        return this.peerType == "channel" && !this.isLeft && !this.canManageGroup()
    }

    /**
     * iOS peerInfoCanEdit：
     *   channel     → isCreator || hasPermission(.changeInfo) || adminRights != nil
     *   legacyGroup → creator / admin(4 项权限之一) / 成员且默认权限未禁 change_info
     */
    private func canEditPeerInfo(): Bool {
        if (this.peerType == "channel") { return !this.isLeft && (this.isCreator || this.canEditInfo) }
        if (this.peerType == "chat") {
            if (this.isLeft) { return false }
            return this.isCreator || this.canEditInfo || (this.defaultBannedFlags & this.bannedChangeInfoBit) == 0
        }
        return false
    }

    /**
     * 群组/频道 More 菜单，逐项对位 iOS PeerInfoScreenPerformButtonAction.swift
     *   supergroup 分支 :892（Report:967 / Auto-Delete:980 / Clear:1066 / Leave:1096 / Delete:1103）
     *   legacyGroup 分支 :1114（Auto-Delete:1117 / Report:1222 / Clear:1235 / Leave:1248 / Delete:1257）
     * 未移植：Boost / Statistics / Translate（无对应能力）。
     */
    private func buildGroupMoreMenuItems(): Array<ContextMenuItem> {
        let items = ArrayList<ContextMenuItem>()
        let reportItem = ContextMenuItem(
            title: "Report", iconText: "", destructive: false, enabled: true,
            onClick: { => this.startPeerReport() }
        )
        let autoDeleteItem = ContextMenuItem(
            title: "Enable Auto-Delete", iconRes: @r(app.media.peerinfo_menu_timer),
            destructive: false, enabled: true,
            onClick: { => this.showAutoDeleteConfirm = true }
        )
        let clearItem = ContextMenuItem(
            title: "Clear Messages", iconRes: @r(app.media.peerinfo_menu_clear),
            destructive: false, enabled: true,
            onClick: { => this.showClearHistoryConfirm = true }
        )
        if (this.peerType == "channel") {
            if (this.canReportPeer()) { items.add(reportItem) }
            if (this.canSetupAutoDelete()) { items.add(autoDeleteItem) }
            if (this.canClearForMyself() || this.canClearForEveryone()) { items.add(clearItem) }
            if (!this.isLeft && !this.showsLeaveHeaderButton()) {
                if (items.size > 0) { items.add(ContextMenuItem.separator()) }
                // iOS: supergroup Leave 用 primary 色，非 destructive
                items.add(ContextMenuItem(
                    title: if (this.isBroadcast) { "Leave Channel" } else { "Leave Group" },
                    iconRes: @r(app.media.peerinfo_menu_leave), destructive: true, enabled: true,
                    onClick: { => this.openLeavePeer(false) }
                ))
                if (this.canDeleteHistory) {
                    items.add(ContextMenuItem(
                        title: if (this.isBroadcast) { "Delete Channel" } else { "Delete Group" },
                        iconRes: @r(app.media.peerinfo_menu_delete), destructive: true, enabled: true,
                        onClick: { => this.openLeavePeer(true) }
                    ))
                }
            }
        } else {
            if (this.canSetupAutoDelete()) { items.add(autoDeleteItem) }
            if (this.canReportPeer()) { items.add(reportItem) }
            items.add(clearItem)
            if (!this.isLeft) {
                items.add(ContextMenuItem.separator())
                items.add(ContextMenuItem(
                    title: "Leave Group", iconRes: @r(app.media.peerinfo_menu_leave),
                    destructive: true, enabled: true,
                    onClick: { => this.openLeavePeer(false) }
                ))
                if (this.isCreator) {
                    items.add(ContextMenuItem(
                        title: "Delete Group", iconRes: @r(app.media.peerinfo_menu_delete),
                        destructive: true, enabled: true,
                        onClick: { => this.openLeavePeer(true) }
                    ))
                }
            }
        }
        return items.toArray()
    }

    // ==================== 异步加载 ====================

    private func loadUserFullInfo(): Unit {
        let uid = this.peerId
        let _ = spawn {
            try {
                let infoService = getPeerInfoService()
                let info = infoService.getUserFullInfo(uid)
                let bioVal = info.bio
                let blockedVal = info.isBlocked
                let errVal = info.error
                // Badge flags extracted from PeerFullInfo (populated from trailing users vector
                // in parseUserFullResponse when chats vector is empty, otherwise from cache)
                let verifiedVal = info.isVerified
                let scamVal = info.isScam
                let fakeVal = info.isFake
                let botVal = info.isBot
                launch {
                    if (errVal.size == 0) {
                        this.bio = bioVal
                        this.isBlocked = blockedVal
                        // Only overwrite badge flags if PeerFullInfo has positive values;
                        // injectAccessHashFromCache may have already set them from cache.
                        if (verifiedVal) { this.isVerified = true }
                        if (scamVal) { this.isScam = true }
                        if (fakeVal) { this.isFake = true }
                        if (botVal) { this.isBot = true }
                    } else {
                        Hilog.info(0, "CjTelegram", "[PeerInfoPage] getUserFullInfo error: ${errVal}")
                    }
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PeerInfoPage] loadUserFullInfo error: ${e}")
                launch { this.isLoading = false }
            }
        }
    }

    private func loadGroupFullInfo(): Unit {
        let pt = this.peerType
        let pid = this.peerId
        let _ = spawn {
            try {
                let infoService = getPeerInfoService()
                let info = infoService.getGroupFullInfo(pt, pid, maxAgeMs: 60000)
                let aboutVal = info.about
                let membersVal = info.membersCount
                let onlineVal = info.onlineCount
                let canViewVal = info.canViewParticipants
                let canDeleteVal = info.canDeleteChannel
                // S5-09: 广播频道的讨论群（channelFull.linked_chat_id）→ 标题/access_hash
                let linkedOpt: Option<ChatResponse> = if (pt == "channel" && info.linkedChatId != 0) {
                    infoService.resolveLinkedChat(pid, info.linkedChatId)
                } else {
                    None
                }
                let (linkedIdVal, linkedTitleVal, linkedIsChannelVal, linkedUsernameVal) = match (linkedOpt) {
                    case Some(linked) => (linked.id, linked.title, linked.isChannel, linked.username)
                    case None => (Int64(0), "", true, "")
                }
                let memberList = ArrayList<MemberInfo>()
                if (pt == "chat") {
                    // W6 S4-25：基础群成员直接用 messages.getFullChat 的 participants（iOS PeerInfoScreen
                    // 读 CachedGroupData.participants），不再对基础群发 channels.getParticipants。
                    for (m in info.participants) { memberList.add(m) }
                    Hilog.info(0, "CjTelegram",
                        "[PeerInfoPage] legacy group ${pid} members from chatFull.participants: ${memberList.size} (forbidden=${info.participantsForbidden}, canView=${canViewVal})")
                    if (memberList.isEmpty() && !info.participantsForbidden && canViewVal) {
                        try {
                            let res = infoService.getParticipantsByFilter(pid, "recent", 0, 50, "", peerType: pt)
                            for (m in res.members) { memberList.add(m) }
                            Hilog.info(0, "CjTelegram", "[PeerInfoPage] legacy group ${pid} members refetched: ${memberList.size} err='${res.error}'")
                        } catch (e2: Exception) {
                            Hilog.info(0, "CjTelegram", "[PeerInfoPage] members load error: ${e2}")
                        }
                    }
                } else if (canViewVal) {
                    try {
                        let res = infoService.getParticipantsByFilter(pid, "recent", 0, 50, "", peerType: pt)
                        for (m in res.members) { memberList.add(m) }
                    } catch (e2: Exception) {
                        Hilog.info(0, "CjTelegram", "[PeerInfoPage] members load error: ${e2}")
                    }
                }
                // 基础群实体不在内存缓存时（冷启动直接进群 → 资料页），按 iOS Postbox 以服务端
                // peer 为准：messages.getChats 补拉一次，回填 creator/admin/left/默认权限。
                var legacyChatOpt: Option<ChatResponse> = None
                if (pt == "chat") {
                    match (getRealChatListService().getCachedChat("chat", pid)) {
                        case Some(_) => ()
                        case None =>
                            let ids = ArrayList<Int64>()
                            ids.add(pid)
                            let fetched = getRealChatListService().fetchLegacyChats(ids)
                            for (c in fetched) {
                                if (c.id == pid) { legacyChatOpt = Some(c) }
                            }
                            Hilog.info(0, "CjTelegram", "[PeerInfoPage] legacy group ${pid} getChats refill: found=${legacyChatOpt.isSome()}")
                    }
                }
                // 服务端 participants 里自己的条目同样给出角色（chatParticipantCreator/Admin），
                // 作为实体缺失时 Add Members / More 菜单的权限兜底。
                let selfId = getCurrentUserId()
                var selfIsCreator = false
                var selfIsAdmin = false
                for (m in memberList) {
                    if (m.userId == selfId) {
                        selfIsCreator = m.isCreator
                        selfIsAdmin = m.isAdmin
                    }
                }
                let legacyChatFinal = legacyChatOpt
                let selfCreatorFinal = selfIsCreator
                let selfAdminFinal = selfIsAdmin
                launch {
                    match (legacyChatFinal) {
                        case Some(c) => this.applyLegacyGroupFlags(c)
                        case None => ()
                    }
                    if (pt == "chat" && selfId != 0) {
                        if (selfCreatorFinal && !this.isCreator) {
                            this.isCreator = true
                            this.canDeleteHistory = true
                            Hilog.info(0, "CjTelegram", "[PeerInfoPage] legacy group ${pid}: self is creator per chatFull.participants")
                        }
                        if (selfAdminFinal && !this.canEditInfo) {
                            this.canEditInfo = true
                            Hilog.info(0, "CjTelegram", "[PeerInfoPage] legacy group ${pid}: self is admin per chatFull.participants")
                        }
                    }
                    this.groupMembers = memberList
                    this.groupMembersLoaded = true
                    this.linkedChatId = linkedIdVal
                    this.linkedChatTitle = linkedTitleVal
                    this.linkedChatIsChannel = linkedIsChannelVal
                    this.linkedChatUsername = linkedUsernameVal
                    this.about = aboutVal
                    this.displayName = getSelectedChatName()
                    if (pt == "channel") { this.canDeleteHistory = canDeleteVal }
                    // More 菜单依赖 channelFull 的 can_delete_channel，拿到后重建
                    this.buildMoreMenuItems()
                    // Legacy chatFull responses do not always carry a count. Keep the
                    // basic Chat.participantsCount instead of degrading to "group".
                    if (membersVal > 0) {
                        this.membersCount = membersVal
                    }
                    this.onlineCount = onlineVal
                    this.canViewParticipants = canViewVal
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PeerInfoPage] loadGroupFullInfo error: ${e}")
                launch { this.isLoading = false }
            }
        }
    }

    // ==================== 密钥可视化加载 (P2-148b) ====================

    /**
     * 加载秘密聊天密钥指纹并计算颜色网格 + emoji
     *
     * 数据来源：TelegramCore_SecretChatsService.getSession(chatId: Int32)
     *   → session.sessionKey (256 字节 DH 派生密钥)
     *   → SHA1(sessionKey) 前 20 字节作为 sha1Bytes
     *   → SHA256(sessionKey) 全 32 字节作为 sha256Bytes
     *   → secretChatKeyColorGridFromBytes(sha1Bytes, sha256Bytes) → 12×12 颜色网格
     *   → secretChatKeyEmojiFingerprint(sha1Bytes) → 4 个 emoji 空格连接字符串
     *
     * 注意：peerId 在密聊场景下存储的是密聊 chatId（Int64），
     * 转换为 Int32 传给 getSession。若 session 尚未就绪（PENDING/REQUESTED），
     * sessionKey 为空数组，此时使用空字节呈现占位网格（仍调用 util 真实路径）。
     *
     * S-001：@State 写入在 launch{} 内（主线程）。
     */
    private func loadSecretChatKey(): Unit {
        let chatId = Int32(this.peerId)
        let _ = spawn {
            try {
                let svc = getTelegramCore_SecretChatsService()
                let sessionOpt = svc.getSession(chatId)
                let keyBytes = match (sessionOpt) {
                    case Some(session) => session.sessionKey
                    case None => Array<Byte>(0, repeat: 0)
                }
                let sha1Bytes = SHA1.hash(keyBytes)
                let sha256Bytes = SHA256.hash(keyBytes)
                let grid = secretChatKeyColorGridFromBytes(sha1Bytes, sha256Bytes)
                let emoji = secretChatKeyEmojiFingerprint(sha1Bytes)
                launch {
                    this.secretChatKeyGrid = grid
                    this.secretChatKeyEmoji = emoji
                    this.secretChatKeyLoaded = true
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PeerInfoPage] loadSecretChatKey error: ${e}")
                launch { this.isLoading = false }
            }
        }
    }

    // ==================== 操作：屏蔽/取消屏蔽 ====================

    /**
     * 屏蔽/取消屏蔽用户
     * 调用链：doToggleBlock → ContactsService.blockUser / unblockUser
     *   → contacts.block#2e2e8734 / contacts.unblock#b550d328 → MTProtoClient.sendRequest()
     */
    private func doToggleBlock(): Unit {
        let uid = this.peerId
        let aHash = this.accessHash
        let blocked = this.isBlocked
        this.showBlockConfirm = false
        let _ = spawn {
            try {
                let svc = getContactsService()
                let ok = if (blocked) {
                    svc.unblockUser(uid, aHash)
                } else {
                    svc.blockUser(uid, aHash)
                }
                let msg = if (ok) {
                    if (blocked) { "User unblocked" } else { "User blocked" }
                } else {
                    "Operation failed"
                }
                let newBlocked = if (ok) { !blocked } else { blocked }
                launch {
                    if (ok) { this.isBlocked = newBlocked }
                    this.showToastMsg(msg)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PeerInfoPage] doToggleBlock error: ${e}")
            }
        }
    }

    // ==================== 操作：静音/取消静音 ====================

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

    /**
     * 切换静音状态
     * 调用链：doToggleMute → RealChatListService.toggleMuteDialog
     *   → account.updateNotifySettings → MTProtoClient.sendRequest()
     */
    private func doToggleMute(): Unit {
        let pt = this.peerType
        let pid = this.peerId
        let muted = this.isMuted
        let _ = spawn {
            try {
                let svc = getRealChatListService()
                let ok = svc.toggleMuteDialog(pt, pid, !muted)
                if (ok) {
                    let newMuted = !muted
                    launch {
                        this.isMuted = newMuted
                        this.muteAnimationSerial = this.muteAnimationSerial + 1
                        this.applyPeerMuteState(pid, newMuted)
                        this.showToastMsg(if (newMuted) { "Notifications are muted." } else { "Notifications are unmuted." })
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PeerInfoPage] doToggleMute error: ${e}")
            }
        }
    }

    // ==================== 操作：离开群组/频道 ====================

    /** iOS openLeavePeer(delete:)：同一确认框，delete=true 为"为所有成员删除" */
    private func openLeavePeer(delete: Bool): Unit {
        this.leaveIsDelete = delete
        this.showLeaveConfirm = true
    }

    private func doLeave(): Unit {
        let pt = this.peerType
        let pid = this.peerId
        let deleteGlobally = this.leaveIsDelete
        let groupPeer = this.isGroupPeer()
        this.showLeaveConfirm = false
        let _ = spawn {
            try {
                let msgService = getRealMessageService()
                // iOS deletePeerChat(globally:) → removePeerChat(deleteGloballyIfPossible:)
                //   → deleteChannel/deleteChat（群主）或 leaveChannel/deleteChatUser(self)
                let ok = if (deleteGlobally) {
                    msgService.deletePeerGlobally(pt, pid)
                } else {
                    msgService.leavePeer(pt, pid)
                }
                // iOS Undo_DeletedGroup / Undo_LeftGroup / Undo_DeletedChannel / Undo_LeftChannel
                let msg = if (ok) {
                    if (deleteGlobally) {
                        if (groupPeer) { "Group deleted" } else { "Channel deleted" }
                    } else {
                        if (groupPeer) { "Left group" } else { "Left channel" }
                    }
                } else {
                    if (deleteGlobally) { "Failed to delete" } else { "Failed to leave" }
                }
                launch {
                    this.showToastMsg(msg)
                    if (ok) {
                        match (getChatListVM()) {
                            case Some(vm) => vm.removeChatFromLocal(pid)
                            case None => ()
                        }
                        routerReplace("MainTabPage", "{}")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PeerInfoPage] doLeave error: ${e}")
            }
        }
    }

    // ==================== 操作：清空历史 ====================

    /**
     * 清空聊天历史（仅当前账号），与 iOS Clear History 默认动作一致。
     * 调用链：doClearHistory → MessagesService.clearHistory
     *   → messages.deleteHistory / channels.deleteHistory → MTProtoClient.sendRequest()
     */
    private func doClearHistory(revoke: Bool): Unit {
        let pt = this.peerType
        let pid = this.peerId
        this.showClearHistoryConfirm = false
        let _ = spawn {
            try {
                let svc = getMessagesService()
                // iOS requestClearHistory type: .forEveryone → revoke；.forLocalPeer → 仅本端
                let ok = svc.clearHistory(pt, pid, maxId: 2147483646, justClear: true, revoke: revoke)
                if (ok) { getMessageHistoryStore().clearPeer(pid, peerType: pt) }
                let msg = if (ok) { "History cleared" } else { "Failed to clear history" }
                launch {
                    if (ok) {
                        match (getChatListVM()) {
                            case Some(vm) => vm.applyHistoryCleared(pid)
                            case None => ()
                        }
                        getRealMessageService().notifyHistoryChanged(pid)
                    }
                    this.showToastMsg(msg)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PeerInfoPage] doClearHistory error: ${e}")
            }
        }
    }

    // ==================== 操作：举报群组/频道 ====================

    private func startPeerReport(): Unit {
        this.showPeerReport = true
        this.reportLoading = true
        this.reportNeedsComment = false
        this.reportTitle = "Report ${this.displayName}"
        this.reportOptions = ArrayList<String>()
        this.reportOptionBytes = ArrayList<Array<Byte>>()
        this.reportComment = ""
        this.requestPeerReport(Array<Byte>(0, repeat: 0), "")
    }

    private func requestPeerReport(option: Array<Byte>, message: String): Unit {
        let pt = this.peerType
        let pid = this.peerId
        spawn {
            try {
                let req = MessagesReport()
                req.peer = getRealMessageService().buildInputPeer(pt, pid)
                req.option = option
                req.message = message
                let result = ReportResultResponse.deserialize(getMTProtoClient().sendRequest(req.toBytes()))
                launch {
                    this.reportLoading = false
                    if (result.kind == "choose_option") {
                        let texts = ArrayList<String>()
                        let bytes = ArrayList<Array<Byte>>()
                        for (entry in result.chooseOptions) {
                            texts.add(entry.text)
                            bytes.add(entry.optionBytes)
                        }
                        this.reportTitle = result.chooseTitle
                        this.reportOptions = texts
                        this.reportOptionBytes = bytes
                        this.reportNeedsComment = false
                    } else if (result.kind == "add_comment") {
                        this.reportCommentOption = result.addCommentOption
                        this.reportNeedsComment = true
                    } else if (result.kind == "reported") {
                        this.showPeerReport = false
                        this.showToastMsg("Report submitted")
                    } else {
                        this.showPeerReport = false
                        this.showToastMsg("Failed to submit report")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PeerInfoPage] report peer error: ${e}")
                launch {
                    this.reportLoading = false
                    this.showPeerReport = false
                    this.showToastMsg("Failed to submit report")
                }
            }
        }
    }

    private func selectPeerReportOption(index: Int64): Unit {
        if (index < 0 || index >= this.reportOptionBytes.size) { return }
        let option = this.reportOptionBytes[index]
        this.reportLoading = true
        this.requestPeerReport(option, "")
    }

    private func submitPeerReportComment(): Unit {
        if (this.reportComment.size == 0) { return }
        this.reportLoading = true
        this.requestPeerReport(this.reportCommentOption, this.reportComment)
    }

    // ==================== 操作：自动删除设置 ====================

    /**
     * 设置自动删除为关闭（period=0）
     * 调用链：doSetAutoDelete → PeersService.setHistoryTTL
     *   → messages.setHistoryTTL → MTProtoClient.sendRequest()
     */
    private func doSetAutoDelete(period: Int32): Unit {
        let pt = this.peerType
        let pid = this.peerId
        let aHash = this.accessHash
        this.showAutoDeleteConfirm = false
        let _ = spawn {
            try {
                let svc = getPeersService()
                let result = svc.setHistoryTTL(pt, pid, aHash, period)
                let msg = if (result.success) {
                    if (period == 0) { "Auto-delete disabled" } else { "Auto-delete set" }
                } else {
                    "Failed to set auto-delete"
                }
                launch { this.showToastMsg(msg) }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PeerInfoPage] doSetAutoDelete error: ${e}")
            }
        }
    }

    // ==================== 操作：发起秘密聊天 ====================

    /**
     * 发起秘密聊天（用户专用）
     * 调用链：doStartSecretChat
     *   → TelegramCore_SecretChatsService.requestEncryption(userId, userAccessHash)
     *   → messages.getDhConfig + messages.requestEncryption → MTProtoClient.sendRequest()
     */
    private func doStartSecretChat(): Unit {
        let uid = this.peerId
        let aHash = this.accessHash
        let _ = spawn {
            try {
                let svc = getTelegramCore_SecretChatsService()
                let chatId = svc.requestEncryption(uid, aHash)
                let msg = if (chatId >= 0) { "Secret chat requested" } else { "Failed to start secret chat" }
                launch { this.showToastMsg(msg) }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PeerInfoPage] doStartSecretChat error: ${e}")
            }
        }
    }

    // ==================== 操作：发送消息 ====================

    private func doOpenChat(): Unit {
        routerPush("ChatRoomPage")
    }

    // ==================== 辅助方法 ====================

    private func showToastMsg(msg: String): Unit {
        this.toastMessage = msg
        this.showToast = true
        this.toastGeneration += 1
        let generation = this.toastGeneration
        spawn {
            sleep(Duration.second * 3)
            launch {
                if (this.toastGeneration == generation) { this.showToast = false }
            }
        }
    }

    private func isGroupLayout(): Bool {
        return this.peerType == "chat" || this.peerType == "channel"
    }

    private func memberDisplayName(m: MemberInfo): String {
        if (m.firstName.size > 0 && m.lastName.size > 0) { return "${m.firstName} ${m.lastName}" }
        if (m.firstName.size > 0) { return m.firstName }
        if (m.lastName.size > 0) { return m.lastName }
        if (m.username.size > 0) { return "@${m.username}" }
        return "User ${m.userId}"
    }

    private func memberStatusText(m: MemberInfo): String {
        match (getUserPhotoService().getCachedUser(m.userId)) {
            case Some(u) => return getPeerPresenceStatusManagerService().formatText(u.isOnline, u.wasOnline, u.statusType)
            case None => return ""
        }
    }

    private func memberIsOnline(m: MemberInfo): Bool {
        match (getUserPhotoService().getCachedUser(m.userId)) {
            case Some(u) => return u.isOnline
            case None => return false
        }
    }

    private func memberBadge(m: MemberInfo): String {
        if (m.isCreator) { return "owner" }
        if (m.isAdmin) { return if (m.rank.size > 0) { m.rank } else { "admin" } }
        return ""
    }

    private func openMember(m: MemberInfo): Unit {
        routerPush("UserProfilePage", userProfileParam(m.userId, this.memberDisplayName(m)))
    }

    // ==================== 成员长按菜单 ====================

    /** 长按成员行：Send Message + 管理动作（提升 / 头衔 / 限制 / 移除），按 iOS 权限规则显示。 */
    private func openMemberMenu(m: MemberInfo): Unit {
        let name = this.memberDisplayName(m)
        let isSelf = m.userId == getCurrentUserId()
        this.memberMenuUserId = m.userId
        this.memberMenuAccessHash = m.accessHash
        this.memberMenuName = name
        this.memberMenuIsAdmin = m.isAdmin
        this.memberMenuFlags = m.adminFlags
        this.memberMenuRank = m.rank

        let items = ArrayList<ContextMenuItem>()
        if (!isSelf) {
            items.add(ContextMenuItem(title: "Send Message", iconRes: @r(app.media.peerinfo_menu_message),
                onClick: { => this.sendMessageToMember() }))
        }
        if (this.canManageGroup() && !m.isCreator) {
            if (!isSelf && !m.isAdmin) {
                items.add(ContextMenuItem(title: "Promote to Admin", iconRes: @r(app.media.peerinfo_menu_promote),
                    onClick: { => this.promoteMember() }))
            }
            items.add(ContextMenuItem(
                title: if (m.rank.size > 0) { "Edit Member Tag" } else { "Add Member Tag" },
                iconRes: @r(app.media.peerinfo_menu_tag),
                onClick: { =>
                    this.memberTagInput = this.memberMenuRank
                    this.showMemberTagEditor = true
                }
            ))
            if (!isSelf) {
                if (this.peerType == "channel") {
                    items.add(ContextMenuItem(title: "Restrict", iconRes: @r(app.media.peerinfo_menu_restrict),
                        onClick: { => this.restrictMember() }))
                }
                items.add(ContextMenuItem.separator())
                items.add(ContextMenuItem(
                    title: "Remove from Group", iconRes: @r(app.media.peerinfo_menu_delete), destructive: true,
                    onClick: { => this.showRemoveMemberConfirm = true }
                ))
            }
        }
        if (items.isEmpty()) { return }
        // 行下方放不下时改放到行上方；被按行保持高亮直到菜单关闭
        var menuHeight = 0.0
        for (it in items) { menuHeight += if (it.isSeparator) { 8.0 } else { 46.0 } }
        let rowTop = this.memberRowTop.get(m.userId) ?? 0.0
        let rowHeight = this.memberRowHeight.get(m.userId) ?? 56.0
        var top = rowTop + rowHeight + 4.0
        if (this.pageHeightVp > 0.0 && top + menuHeight > this.pageHeightVp - 34.0) {
            top = rowTop - menuHeight - 4.0
            if (top < 0.0) { top = 0.0 }
        }
        this.memberMenuTop = top
        this.pressedMemberId = m.userId
        this.memberMenuItems = items.toArray()
        this.showMemberMenu = true
    }

    private func closeMemberMenu(): Unit {
        this.showMemberMenu = false
        this.pressedMemberId = 0
    }

    private func sendMessageToMember(): Unit {
        setSelectedChat(this.memberMenuUserId, this.memberMenuName, "user")
        routerPush("ChatRoomPage", this.memberMenuName)
    }

    private func reloadMembersAfterAction(): Unit {
        getPeerInfoService().invalidateGroupFullInfo(this.peerId)
        this.loadGroupFullInfo()
    }

    private func promoteMember(): Unit {
        let pid = this.peerId
        let ah = this.accessHash
        let uid = this.memberMenuUserId
        let uh = this.memberMenuAccessHash
        let name = this.memberMenuName
        let isChannel = this.peerType == "channel"
        let _ = spawn {
            // 基本管理员权限位: change_info(1) + post(4) + delete(8) + ban(16) + invite(32) + pin(128)
            let r = if (isChannel) {
                getPeersService().editAdmin(pid, ah, uid, uh, 189)
            } else {
                PeerOperationResult(getRealMessageService().editBasicGroupAdmin(pid, uid, uh, true))
            }
            let ok = r.success
            let msg = if (ok) { "Promoted ${name} to Admin" } else { "Failed: ${r.errorCode}" }
            launch {
                this.showToastMsg(msg)
                if (ok) { this.reloadMembersAfterAction() }
            }
        }
    }

    private func restrictMember(): Unit {
        let pid = this.peerId
        let ah = this.accessHash
        let uid = this.memberMenuUserId
        let uh = this.memberMenuAccessHash
        let name = this.memberMenuName
        let _ = spawn {
            let rights = ChatBannedRights()
            rights.flags = 6
            rights.untilDate = 0
            let r = getPeersService().editBanned(pid, ah, uid, uh, rights)
            let msg = if (r.success) { "Restricted ${name}" } else { "Failed: ${r.errorCode}" }
            launch {
                this.showToastMsg(msg)
                if (r.success) { this.reloadMembersAfterAction() }
            }
        }
    }

    private func removeMember(): Unit {
        this.showRemoveMemberConfirm = false
        let pid = this.peerId
        let ah = this.accessHash
        let uid = this.memberMenuUserId
        let uh = this.memberMenuAccessHash
        let name = this.memberMenuName
        let isChannel = this.peerType == "channel"
        let _ = spawn {
            let r = if (isChannel) {
                getPeersService().kickChannelMember(pid, ah, uid, uh)
            } else {
                getPeersService().removeGroupMember(pid, uid, uh)
            }
            let msg = if (r.success) { "Removed ${name}" } else { "Failed: ${r.errorCode}" }
            launch {
                this.showToastMsg(msg)
                if (r.success) { this.reloadMembersAfterAction() }
            }
        }
    }

    /** 保存头衔：超级群/频道走 channels.editAdmin 的 rank（非管理员以零权限管理员身份挂头衔，同 iOS）。 */
    private func saveMemberTag(): Unit {
        this.showMemberTagEditor = false
        if (this.peerType != "channel") {
            this.showToastMsg("Member tags are available after upgrading to a supergroup")
            return
        }
        let pid = this.peerId
        let ah = this.accessHash
        let uid = this.memberMenuUserId
        let uh = this.memberMenuAccessHash
        let flags = this.memberMenuFlags
        let tag = this.memberTagInput.trimAscii()
        let _ = spawn {
            let r = getPeersService().editAdmin(pid, ah, uid, uh, flags, rank: tag)
            let msg = if (r.success) { "Member tag updated" } else { "Failed: ${r.errorCode}" }
            launch {
                this.showToastMsg(msg)
                if (r.success) { this.reloadMembersAfterAction() }
            }
        }
    }

    private func doAddMembers(): Unit {
        let isChannel = this.peerType == "channel"
        routerPush("InviteMembersSheet", "${this.peerType}:${this.peerId}:${this.accessHash}:${if (isChannel) { "1" } else { "0" }}:0")
    }

    /** iOS「video chat」：无进行中的语音/视频聊天时创建并进入。 */
    private func doStartVideoChat(): Unit {
        // 请求慢的时候用户会连点：每点一次就多发一组 getFullChat + createGroupCall
        //（真机日志里出现过 4 次 CREATE_CALL_FAILED 和 3 次重复进页）。
        if (this.startingVideoChat) { return }
        this.startingVideoChat = true
        let pid = this.peerId
        let ah = this.accessHash
        let isChannel = this.peerType == "channel"
        let pType = this.peerType
        // iOS canManageCall：creator 或具 manageCalls 的管理员（PresentationGroupCall.swift:1197-1214）
        let canManage = this.isCreator || (match (getRealChatListService().getCachedChat(this.peerType, this.peerId)) {
            case Some(c) => c.isCreator || (c.adminRightsFlags & (1 << 11)) != 0
            case None => false
        })
        let _ = spawn {
            // iOS PeerInfoScreenCallActions.requestCall:17 —— 已有 activeCall 则直接加入，
            // 否则才 createGroupCall。取最新 full info（通话可能是别人刚发起的）。
            getPeerInfoService().invalidateGroupFullInfo(pid)
            let full = getPeerInfoService().getGroupFullInfo(pType, pid)
            if (full.activeCallId != 0) {
                let param = "${full.activeCallId}:${full.activeCallAccessHash}::${pType}:${pid}:${if (canManage) { "1" } else { "0" }}"
                Hilog.info(0, "CjTelegram", "[PeerInfoPage] joining active video chat ${full.activeCallId}")
                launch {
                    this.startingVideoChat = false
                    routerPush("GroupCallScreen", param)
                }
                return
            }
            if (canManage) {
                // iOS：管理员点 Video Chat 先给 Start / Schedule 的选择；选择与预约界面都在通话页里
                launch {
                    this.startingVideoChat = false
                    routerPush("GroupCallScreen", "0:0::${pType}:${pid}:1:new")
                }
                return
            }
            match (getCallsService().createGroupCall(pid, ah, isChannel, "", 0)) {
                case Some(info) =>
                    let param = "${info.callId}:${info.accessHash}::${pType}:${pid}:${if (canManage) { "1" } else { "0" }}"
                    launch {
                        this.startingVideoChat = false
                        routerPush("GroupCallScreen", param)
                    }
                case None =>
                    launch {
                        this.startingVideoChat = false
                        this.showToastMsg("Could not start video chat")
                    }
            }
        }
    }

    private func getMembersLabel(): String {
        if (this.membersCount > 0) {
            if (this.onlineCount > 1) {
                return "${this.membersCount} members, ${this.onlineCount} online"
            }
            if (this.peerType == "channel" && !this.isMegagroup) {
                return "${this.membersCount} subscribers"
            }
            return "${this.membersCount} members"
        }
        if (this.peerType == "channel" && !this.isMegagroup) { return "channel" }
        return "group"
    }

    private func getAboutText(): String {
        if (this.peerType == "user") {
            return if (this.bio.size > 0) { this.bio } else { "No bio" }
        }
        return if (this.about.size > 0) { this.about } else { "No description" }
    }

    /** iOS PeerInfo_LeaveGroupTitle / PeerInfo_LeaveChannelTitle / PeerInfo_DeleteGroupTitle / PeerInfo_DeleteChannelTitle */
    private func getLeaveLabel(): String {
        if (this.leaveIsDelete) {
            return if (this.isGroupPeer()) { "Delete Group" } else { "Delete Channel" }
        }
        return if (this.isGroupPeer()) { "Leave Group" } else { "Leave Channel" }
    }

    /** iOS PeerInfo_LeaveGroupText / PeerInfo_DeleteGroupText 等（%@ = 标题） */
    private func getLeaveDialogText(): String {
        if (this.leaveIsDelete) {
            if (this.isGroupPeer()) {
                return "Are you sure you want to delete ${this.displayName}? All members will be removed and all messages will be lost."
            }
            return "Are you sure you want to delete ${this.displayName}? All subscribers will be removed and all messages will be lost."
        }
        return "Are you sure you want to leave ${this.displayName}?"
    }

    /** iOS Common_Delete / PeerInfo_AlertLeaveAction */
    private func getLeaveActionLabel(): String {
        return if (this.leaveIsDelete) { "Delete" } else { "Leave" }
    }

    private func getTypeLabel(): String {
        if (this.peerType == "channel" || this.peerType == "chat") {
            return this.getMembersLabel()
        }
        return "User"
    }

    // 折叠进度 0.0 (展开) → 1.0 (折叠)
    private func collapseProgress(): Float64 {
        if (this.scrollOffset <= 0.0) {
            return 0.0
        }
        let progress = this.scrollOffset / this.headerCollapseThreshold
        if (progress > 1.0) {
            return 1.0
        }
        return progress
    }

    // 头像缩放比例：1.0 → 0.3 随折叠渐变
    private func avatarScale(): Float64 {
        return 1.0 - this.collapseProgress() * 0.7
    }

    // 头像区域透明度：1.0 → 0.0 随折叠渐变
    private func headerOpacity(): Float64 {
        return 1.0 - this.collapseProgress()
    }

    // 折叠后显示在 NavDestination title 栏的名称（visible 当折叠 >50%）
    private func collapsedTitleVisible(): Bool {
        return this.collapseProgress() > 0.5
    }

    // 头部 accent 背景色（使用 peer 色板颜色或蓝色兜底）
    private func headerAccentColor(): UInt32 {
        if (this.isPremium) { return UInt32(0xFF6B4FBB) }
        if (this.isVerified) { return UInt32(0xFF1B72C5) }
        return UInt32(0xFF317AFF)
    }

    // blockConfirm helper methods (no let in @Builder — S-005)
    private func getBlockTitle(): String {
        if (this.isBlocked) { return "Unblock User" }
        return "Block User"
    }
    private func getBlockMessage(): String {
        if (this.isBlocked) { return "Unblock ${this.displayName}?" }
        return "Block ${this.displayName}? They won't be able to message you."
    }
    private func getBlockConfirmLabel(): String {
        if (this.isBlocked) { return "Unblock" }
        return "Block"
    }
    private func getBlockConfirmColor(): Int64 {
        if (this.isBlocked) { return 0x007AFF }
        return 0xFF3B30
    }
    private func getMuteLabel(): String {
        if (this.isMuted) { return "Unmute" }
        return "Mute"
    }

    // ==================== 密钥网格辅助（P2-148b） ====================

    /**
     * 从 KeyColorGrid.cells[cellIdx] 取颜色值（ARGB Int64）
     * S-005：不能在 @Builder 内用 let，提取为 private func
     */
    private func keyGridCellColor(cellIdx: Int64): Int64 {
        if (this.secretChatKeyGrid.cells.size == 0) {
            return Int64(0xFFFFFFFF)
        }
        let safeIdx = if (cellIdx < this.secretChatKeyGrid.cells.size) { cellIdx } else { Int64(0) }
        let colorIdx = Int64(this.secretChatKeyGrid.cells[safeIdx]) % 4
        return this.secretChatKeyGrid.colors[colorIdx]
    }

    /**
     * 密钥网格行起始 cell 索引
     * row ∈ [0, gridSize)，返回 row * gridSize
     */
    private func keyGridRowStart(row: Int64): Int64 {
        return row * Int64(this.secretChatKeyGrid.gridSize)
    }

    /**
     * 网格尺寸（便于 @Builder 中引用，避免 let）
     */
    private func keyGridSize(): Int64 {
        return Int64(this.secretChatKeyGrid.gridSize)
    }

    /**
     * 单格宽度（vp），根据 gridSize 自适应 160vp 总宽
     * gridSize=8 → 16vp，gridSize=12 → 11vp
     */
    private func keyGridCellSize(): Float64 {
        let sz = Int64(this.secretChatKeyGrid.gridSize)
        if (sz <= 0) { return 16.0 }
        let totalWidth: Float64 = 160.0
        return totalWidth / Float64(sz)
    }

    // ==================== build() ====================

    public func build() {
        Stack {
            Scroll() {
                Column {
                    if (this.isGroupLayout()) {
                        this.buildGroupInfo()
                    } else {
                    Stack(alignContent: Alignment.BottomStart) {
                        if (this.avatarPhotoPath.size > 0) {
                            Image(this.avatarPhotoPath)
                                .width(100.percent)
                                .height(455)
                                .objectFit(ImageFit.Cover)
                        } else {
                            Column {
                                Text(this.avatarLetter)
                                    .fontSize(96)
                                    .fontWeight(FontWeight.Bold)
                                    .fontColor(0xCCFFFFFF)
                            }
                            .width(100.percent)
                            .height(455)
                            .backgroundColor(this.headerAccentColor())
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                        }

                        Column {}
                            .width(100.percent)
                            .height(220)
                            .linearGradient(
                                angle: 180.0,
                                colors: [
                                    (Color.Transparent, 0.0),
                                    (Color(UInt32(0xA6000000)), 1.0)
                                ]
                            )

                        Column {
                            Row {
                                Text("‹")
                                    .fontSize(42)
                                    .fontColor(0xFFFFFFFF)
                                    .width(44)
                                    .height(44)
                                    .textAlign(TextAlign.Center)
                                    .backgroundColor(0x663C3C43)
                                    .borderRadius(22)
                                    .onClick({ _ => routerPop() })
                                Blank().layoutWeight(1)
                                if (this.canEditPeerInfo()) {
                                    Text(trSource("Edit"))
                                        .fontSize(17)
                                        .fontColor(0xFFFFFFFF)
                                        .height(44)
                                        .padding(left: 14, right: 14)
                                        .backgroundColor(0x663C3C43)
                                        .borderRadius(22)
                                        .onClick({ _ => routerPush("GroupDetailsPage", "") })
                                }
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 40)

                            Blank().layoutWeight(1)

                            Row {
                                Text(this.displayName)
                                    .fontSize(25)
                                    .fontWeight(FontWeight.Bold)
                                    .fontColor(0xFFFFFFFF)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                if (this.isVerified) {
                                    Text("✓")
                                        .fontSize(11)
                                        .fontWeight(FontWeight.Bold)
                                        .fontColor(0xFFFFFFFF)
                                        .width(18)
                                        .height(18)
                                        .textAlign(TextAlign.Center)
                                        .backgroundColor(0xFF168ACD)
                                        .borderRadius(9)
                                        .margin(left: 5)
                                }
                                if (this.isScam) {
                                    Text("SCAM").fontSize(11).fontColor(0xFFFFFFFF).backgroundColor(0xFFFF3B30).padding(left: 4, right: 4).margin(left: 5)
                                }
                                if (this.isFake) {
                                    Text("FAKE").fontSize(11).fontColor(0xFFFFFFFF).backgroundColor(0xFFFF3B30).padding(left: 4, right: 4).margin(left: 5)
                                }
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)

                            Text(this.getTypeLabel())
                                .fontSize(15)
                                .fontColor(0xE6FFFFFF)
                                .width(100.percent)
                                .padding(left: 16, right: 16)
                                .margin(top: 2)

                            Row {
                                if (this.peerType == "user") {
                                    this.quickActionBtn("message", { => this.doOpenChat() })
                                }
                                this.quickActionBtn(if (this.isMuted) { "unmute" } else { "mute" }, { => this.doToggleMute() })
                                this.quickActionBtn("search", { =>
                                    requestChatSearchOnReturn()
                                    routerPop()
                                })
                                // iOS peerInfoHeaderButtons：普通群没有 leave 头部按钮；超级群/频道
                                // 成员有，但 canManage 时剥离进 More 菜单（PeerInfoData.swift:2680）
                                if (this.showsLeaveHeaderButton()) {
                                    this.quickActionBtn("leave", { => this.openLeavePeer(false) })
                                }
                                this.quickActionBtn("more", { => this.showMoreMenu = true })
                            }
                            .width(100.percent)
                            .padding(left: 12, right: 12, top: 16, bottom: 18)
                            .justifyContent(FlexAlign.SpaceEvenly)
                        }
                        .width(100.percent)
                        .height(455)
                    }
                    .width(100.percent)
                    .height(455)

                    if (this.isLoading) {
                        Column {
                            Text(trSource("Loading...")).fontSize(14).fontColor(this.presentation.secondaryTextColor)
                        }
                        .width(100.percent)
                        .height(60)
                        .justifyContent(FlexAlign.Center)
                    } else {
                        if (this.username.size > 0 || this.bio.size > 0 || this.about.size > 0 ||
                            (this.peerType == "user" && this.phone.size > 0)) {
                            Column {
                                if (this.peerType == "user" && this.phone.size > 0) {
                                    this.peerInfoValue("mobile", "+${this.phone}", true)
                                }
                                if (this.username.size > 0) {
                                    this.peerInfoValue("link", "https://t.me/${this.username}", true)
                                }
                                if ((this.peerType == "user" && this.bio.size > 0) || (this.peerType != "user" && this.about.size > 0)) {
                                    this.peerInfoValue("description", this.getAboutText(), false)
                                }
                            }
                            .width(100.percent)
                            .backgroundColor(this.presentation.cardColor)
                            .margin(left: 16, right: 16, top: 16)
                            .borderRadius(14)
                        }

                        if (this.peerType != "user" && this.peerType != "secret") {
                            Column {
                                // iOS Group_Info_Settings / Channel_Info_Settings（PeerInfoProfileItems.swift:801）：
                                // 超级群/频道的管理员与群主在资料页有 Settings 行进入编辑模式
                                if (this.peerType == "channel" && !this.isLeft && this.canManageGroup()) {
                                    this.profileActionRow("Settings", false, { => routerPush("GroupDetailsPage", "") })
                                }
                                if (this.canViewParticipants) {
                                    this.profileActionRow("Members", false, { => routerPush("GroupMembersPage", "") })
                                }
                                this.profileActionRow("Shared Media", false, { => routerPush("SharedMediaPage", "") })
                            }
                            .width(100.percent)
                            .backgroundColor(this.presentation.cardColor)
                            .margin(left: 16, right: 16, top: 16)
                            .borderRadius(14)
                        }
                    }

                    } // end non-group layout
                    if (this.peerType == "secret" && this.secretChatKeyLoaded) {
                        this.buildEncryptionKeySection()
                    }
                    Blank().height(320)
                }
                .width(100.percent)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(this.presentation.backgroundColor)
            .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())

            if (this.showMoreMenu) {
                if (this.isGroupLayout()) {
                    ContextPopoverMenu(items: this.moreMenuItems, onDismiss: { => this.showMoreMenu = false },
                        topOffset: this.moreMenuAnchorY + 4.0, rightInset: 16.0)
                } else {
                    // 底部安全区内缩：否则最后一项（Auto-Delete）落入系统手势区，点击被吞
                    ContextMenuView(items: this.moreMenuItems, onDismiss: { => this.showMoreMenu = false },
                        bottomInset: getSafeAreaBottom())
                }
            }
            if (this.showMemberMenu) {
                ContextPopoverMenu(items: this.memberMenuItems, onDismiss: { => this.closeMemberMenu() },
                    topOffset: this.memberMenuTop, alignStart: true, leftInset: 16.0)
            }
            // S4-05：Mute 菜单锚在动作按钮行下方（同 more 菜单）
            if (this.showMuteMenu) {
                ContextPopoverMenu(items: this.muteMenuItems, onDismiss: { => this.showMuteMenu = false },
                    topOffset: this.moreMenuAnchorY + 4.0, alignStart: true, leftInset: 16.0)
            }
            if (this.showMuteCustom) { this.muteCustomSheet() }
            if (this.showNotifyCustomize) { this.notifyCustomizeSheet() }
            if (this.showCopyMenu) {
                ContextMenuView(items: this.copyMenuItems, onDismiss: { => this.showCopyMenu = false },
                    bottomInset: getSafeAreaBottom())
            }
            if (this.showShareSheet) { this.shareSheet() }
            if (this.showRemoveMemberConfirm) { this.removeMemberConfirmDialog() }
            if (this.showMemberTagEditor) { this.memberTagDialog() }
            if (this.showBlockConfirm) { this.blockConfirmDialog() }
            if (this.showLeaveConfirm) { this.leaveConfirmDialog() }
            if (this.showClearHistoryConfirm) { this.clearHistoryConfirmDialog() }
            if (this.showAutoDeleteConfirm) { this.autoDeleteDialog() }
            if (this.showAutoDeleteCustom) { this.autoDeleteCustomSheet() }
            if (this.showPeerReport) { this.peerReportDialog() }
            if (this.showToast) { this.toastOverlay() }
        }
        .onAreaChange({ _: Area, newArea: Area => this.pageHeightVp = newArea.height.value })
        .onAppear({ => this.ensureLoaded() })
    }


    /**
     * 快捷操作按钮（Message / Mute / Call / Video / More）
     * S-005: @Builder 内不能有 let/var，所有逻辑提取为 private func
     * S-013: @Builder 不能修饰 private
     */
    // ==================== 群/频道资料页（iOS PeerInfoScreen 群组形态） ====================

    @Builder
    func buildGroupInfo() {
        // 导航行：返回 / Edit（peerInfoCanEdit）
        Row {
            Column {
                Image(@r(app.media.nav_back_arrow_legacy))
                    .width(12)
                    .height(20)
                    .fillColor(this.presentation.accentColor)
            }
                .width(44)
                .height(44)
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(22)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .onClick({ _ => routerPop() })
            Blank().layoutWeight(1)
            if (this.canEditPeerInfo()) {
                Column {
                    Text(trSource("Edit"))
                        .fontSize(17)
                        .fontColor(this.presentation.accentColor)
                }
                    .height(44)
                    .padding(left: 16, right: 16)
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(22)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .onClick({ _ => routerPush("GroupDetailsPage", "") })
            }
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 8)
        .alignItems(VerticalAlign.Center)

        // 头像 + 标题 + 成员数
        Column {
            if (this.avatarPhotoPath.size > 0) {
                Image(this.avatarPhotoPath)
                    .width(100)
                    .height(100)
                    .borderRadius(50)
                    .objectFit(ImageFit.Cover)
            } else {
                Column {
                    Text(this.avatarLetter)
                        .fontSize(44)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0xFFFFFFFF)
                }
                .width(100)
                .height(100)
                .borderRadius(50)
                .backgroundColor(this.headerAccentColor())
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
            Row {
                Text(this.displayName)
                    .fontSize(28)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                if (this.isVerified) {
                    Text("✓")
                        .fontSize(11)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFFFFFF)
                        .width(18)
                        .height(18)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(0xFF168ACD)
                        .borderRadius(9)
                        .margin(left: 5)
                }
            }
            .margin(top: 12)
            .alignItems(VerticalAlign.Center)
            Text(this.getMembersLabel())
                .fontSize(17)
                .fontColor(this.presentation.secondaryTextColor)
                .margin(top: 4)
        }
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
        .margin(top: 8)

        // 动作卡：video chat / mute / search / [leave] / more（iOS peerInfoHeaderButtons）
        Row {
            if (!this.isLeft && (this.peerType == "chat" || this.isMegagroup || this.isCreator)) {
                this.groupActionBtn("video chat", { => this.doStartVideoChat() })
            }
            this.groupActionBtn("mute", { => this.onMuteButtonTap() })
            // iOS PeerInfoData.peerInfoHeaderButtons：广播频道 mute 之后是 discussion（有关联讨论群时）
            if (this.showsDiscussButton()) {
                this.groupActionBtn("discuss", { => this.openDiscussion() })
            }
            this.groupActionBtn("search", { =>
                requestChatSearchOnReturn()
                routerPop()
            })
            if (this.showsLeaveHeaderButton()) {
                this.groupActionBtn("leave", { => this.openLeavePeer(false) })
            }
            this.groupActionBtn("more", { => this.showMoreMenu = true })
        }
        .width(100.percent)
        .padding(left: 11, right: 11, top: 20)
        .onAreaChange({ _: Area, newArea: Area =>
            match (newArea.globalPosition.y) {
                case Some(top) => this.moreMenuAnchorY = top.value + newArea.height.value
                case None => ()
            }
        })

        // 描述 / 链接卡（iOS ItemAbout 长按 → Copy；Channel_LinkItem "share link" 点按 → 分享面板）
        if (this.about.size > 0) {
            Column {
                Text(trSource("description"))
                    .fontSize(14)
                    .fontColor(this.presentation.secondaryTextColor)
                Text(this.about)
                    .fontSize(17)
                    .fontColor(this.presentation.textColor)
                    .margin(top: 4)
            }
            .width(92.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 12)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(this.presentation.cardColor)
            .margin(top: 20)
            .borderRadius(14)
            .onClick({ _ =>
                if (this.consumeSuppressedClick()) { return }
            })
            .onTouch({ evt =>
                match (evt.eventType) {
                    case TouchType.Down =>
                        if (evt.touches.size > 0) {
                            this.beginRowPress(evt.touches[0].x, evt.touches[0].y, { =>
                                triggerHaptic("impact", "light")
                                this.openAboutCopyMenu()
                            })
                        }
                    case TouchType.Move =>
                        if (evt.touches.size > 0) { this.moveRowPress(evt.touches[0].x, evt.touches[0].y) }
                    case _ => this.endRowPress()
                }
            })
        }
        if (this.username.size > 0) {
            Column {
                Text(trSource("share link"))
                    .fontSize(14)
                    .fontColor(this.presentation.secondaryTextColor)
                Text("https://t.me/${this.username}")
                    .fontSize(17)
                    .fontColor(this.presentation.accentColor)
                    .margin(top: 4)
            }
            .width(92.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 12)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(this.presentation.cardColor)
            .margin(top: 12)
            .borderRadius(14)
            .onClick({ _ => this.openShareSheet("https://t.me/${this.username}") })
        }

        // 成员卡：[Settings] + Add Members + 成员行
        if (this.canViewParticipants || (this.peerType == "channel" && this.canManageGroup())) {
            Column {
                if (this.peerType == "channel" && !this.isLeft && this.canManageGroup()) {
                    this.profileActionRow("Settings", false, { => routerPush("GroupDetailsPage", "") })
                }
                if (this.canManageGroup() && !this.isLeft) {
                    Row {
                        Image(@r(app.media.contact_ic_addmember))
                            .width(24)
                            .height(24)
                            .fillColor(this.presentation.accentColor)
                            .margin(right: 22)
                        Text(trSource("Add Members"))
                            .fontSize(17)
                            .fontColor(this.presentation.accentColor)
                    }
                    .width(100.percent)
                    .height(50)
                    .padding(left: 18, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ => this.doAddMembers() })
                }
                if (this.canViewParticipants) {
                    ForEach(this.groupMembers, itemGenerator: { m: MemberInfo, _idx: Int64 =>
                        this.groupMemberRow(m)
                    }, keyGeneratorFunc: { m: MemberInfo, _idx: Int64 => "member_${m.userId}_${m.rank}_${m.isAdmin}" })
                    if (this.membersCount > Int32(this.groupMembers.size)) {
                        Text("Show all ${this.membersCount} members")
                            .fontSize(17)
                            .fontColor(this.presentation.accentColor)
                            .width(100.percent)
                            .height(48)
                            .padding(left: 16)
                            .onClick({ _ => routerPush("GroupMembersPage", "") })
                    }
                }
            }
            .width(92.percent)
            .backgroundColor(this.presentation.cardColor)
            .margin(top: 12)
            .borderRadius(14)
            .clip(true)
        }

        // 页签条（iOS PeerInfoPaneContainerNode：Members / Media / Files / Links / Voice / Audio / GIFs）。
        // 媒体类页签打开 SharedMediaPage 的对应 tab（页面标题仍为 "Shared Media"），Members 打开成员页。
        Row {
            if (this.canViewParticipants) {
                this.groupPanePill(trSource("Members"), { => routerPush("GroupMembersPage", "") })
            }
            this.groupPanePill(trSource("Media"), { => this.openSharedMediaTab(0) })
            this.groupPanePill(trSource("Files"), { => this.openSharedMediaTab(1) })
            this.groupPanePill(trSource("Links"), { => this.openSharedMediaTab(2) })
            this.groupPanePill(trSource("Voice"), { => this.openSharedMediaTab(3) })
            this.groupPanePill(trSource("Audio"), { => this.openSharedMediaTab(4) })
            this.groupPanePill(trSource("GIFs"), { => this.openSharedMediaTab(5) })
        }
        .width(92.percent)
        .padding(4)
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(22)
        .margin(top: 20)
    }

    @Builder
    func groupPanePill(label: String, action: () -> Unit) {
        Text(label)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.presentation.textColor)
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(36)
            .borderRadius(18)
            .onClick({ _ => action() })
    }

    @Builder
    func groupActionBtn(label: String, action: () -> Unit) {
        Column {
            if (label == "video chat") {
                Image(@r(app.media.chatroom_ic_videocall)).width(30).height(30).fillColor(this.presentation.accentColor)
            } else if (label == "mute") {
                // 静音态直接读 this.isMuted（@Builder 参数只在首次构建时求值）；
                // 动画帧图是 40px，占位压到 30px 与其它图标对齐
                Stack(alignContent: Alignment.Center) {
                    if (this.isMuted) {
                        ProfileMuteIcon(muted: true, blue: true, autoplay: this.muteAnimationSerial > 0)
                    } else {
                        ProfileMuteIcon(muted: false, blue: true, autoplay: this.muteAnimationSerial > 0)
                    }
                }
                .width(30)
                .height(30)
            } else if (label == "search") {
                Image(@r(app.media.chatroom_ic_search)).width(30).height(30).fillColor(this.presentation.accentColor)
            } else if (label == "discuss") {
                Image(@r(app.media.set2_ic_chatbubble)).width(28).height(28).fillColor(this.presentation.accentColor).margin(top: 1, bottom: 1)
            } else if (label == "leave") {
                Image(@r(app.media.callui_ic_close)).width(22).height(22).fillColor(this.presentation.accentColor).margin(top: 2, bottom: 2)
            } else {
                Row {
                    Circle().width(5).height(5).fill(this.presentation.accentColor)
                    Blank().width(4)
                    Circle().width(5).height(5).fill(this.presentation.accentColor)
                    Blank().width(4)
                    Circle().width(5).height(5).fill(this.presentation.accentColor)
                }
                .height(26)
                .alignItems(VerticalAlign.Center)
            }
            Text(if (label == "mute" && this.isMuted) { "unmute" } else { label })
                .fontSize(11)
                .fontColor(this.presentation.accentColor)
                .maxLines(1)
                .margin(top: 6)
        }
        .layoutWeight(1)
        .margin(left: 5, right: 5)
        .height(62)
        .borderRadius(12)
        .backgroundColor(this.presentation.cardColor)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => action() })
    }

    @Builder
    func groupMemberRow(m: MemberInfo) {
        Row {
            Avatar(
                avatarUrl: getUserPhotoService().getUserPhotoPath(m.userId),
                displayName: this.memberDisplayName(m),
                avatarSize: 40,
                peerId: m.userId
            )
            Column {
                Text(this.memberDisplayName(m))
                    .fontSize(17)
                    .fontColor(this.presentation.textColor)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                if (this.memberStatusText(m).size > 0) {
                    Text(this.memberStatusText(m))
                        .fontSize(14)
                        .fontColor(if (this.memberIsOnline(m)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                        .margin(top: 2)
                }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)
            if (this.memberBadge(m).size > 0) {
                Text(this.memberBadge(m))
                    .fontSize(14)
                    .fontColor(0xFF8E6BD1)
                    .padding(left: 8, right: 8, top: 3, bottom: 3)
                    .backgroundColor(0x1A8E6BD1)
                    .borderRadius(8)
            }
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(if (this.pressedMemberId == m.userId) { this.presentation.itemHighlightedBackgroundColor } else { this.presentation.cardColor })
        .onClick({ _ =>
            if (this.suppressMemberClick) {
                this.suppressMemberClick = false
                return
            }
            this.openMember(m)
        })
        .onTouch({ evt =>
            match (evt.eventType) {
                case TouchType.Down =>
                    if (evt.touches.size > 0) {
                        this.memberPressX = evt.touches[0].x
                        this.memberPressY = evt.touches[0].y
                    }
                    this.pressedMemberId = m.userId
                    this.memberPressActive = true
                    this.memberPressGeneration += 1
                    let generation = this.memberPressGeneration
                    spawn {
                        sleep(Duration.millisecond * 320)
                        launch {
                            if (this.memberPressActive && generation == this.memberPressGeneration) {
                                this.memberPressActive = false
                                this.suppressMemberClick = true
                                triggerHaptic("impact", "light")
                                this.openMemberMenu(m)
                            }
                        }
                    }
                case TouchType.Move =>
                    if (this.memberPressActive && evt.touches.size > 0) {
                        let dx = evt.touches[0].x - this.memberPressX
                        let dy = evt.touches[0].y - this.memberPressY
                        if (dx * dx + dy * dy > 64.0) {
                            this.memberPressActive = false
                            this.memberPressGeneration += 1
                            this.pressedMemberId = 0
                        }
                    }
                case _ =>
                    this.memberPressActive = false
                    this.memberPressGeneration += 1
                    if (!this.showMemberMenu) { this.pressedMemberId = 0 }
            }
        })
        .onAreaChange({ _: Area, newArea: Area =>
            match (newArea.globalPosition.y) {
                case Some(top) => this.memberRowTop[m.userId] = top.value
                case None => ()
            }
            this.memberRowHeight[m.userId] = newArea.height.value
        })
    }

    // ==================== S4-05：Mute until... / Customize ====================

    /** iOS openCustomMute（自定义静音时长）→ mute_until = now + 所选时长 */
    @Builder
    func muteCustomSheet() {
        Column {
            Column {
                DurationPickerSheet(
                    title: "Mute until...",
                    onConfirm: { secs: Int32 =>
                        this.showMuteCustom = false
                        this.doMuteFor(Int64(secs), this.muteForIntervalText(Int64(secs)))
                    },
                    onCancel: { => this.showMuteCustom = false }
                )
            }
            .width(85.percent)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func notifyCustomizeRow(label: String, value: String, action: () -> Unit) {
        Row {
            Text(label)
                .fontSize(17)
                .fontColor(0xFF000000)
                .layoutWeight(1)
            Text(value)
                .fontSize(17)
                .fontColor(0xFF8E8E93)
        }
        .width(100.percent)
        .height(50)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => action() })
    }

    /** iOS notificationPeerExceptionController：Notifications / Show Previews / Sound 三组设置 */
    @Builder
    func notifyCustomizeSheet() {
        Column {
            Blank().layoutWeight(1)
            Column {
                Text(trSource("Notifications"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF000000)
                    .margin(top: 18, bottom: 12)
                Column {
                    this.notifyCustomizeRow("Notifications", if (this.isMuted) { "Muted" } else { "Enabled" }, { =>
                        if (this.isMuted) {
                            this.doSetMuteUntil(0, "Notifications are unmuted.")
                        } else {
                            this.doSetMuteUntil(2147483647, "Notifications are muted.")
                        }
                    })
                    Divider().color(0xFFE5E5EA).strokeWidth(1).margin(left: 16)
                    this.notifyCustomizeRow("Show Previews", if (this.showPreviewsEnabled) { "On" } else { "Off" }, { =>
                        this.doSetShowPreviews(!this.showPreviewsEnabled)
                    })
                    Divider().color(0xFFE5E5EA).strokeWidth(1).margin(left: 16)
                    this.notifyCustomizeRow("Sound", if (this.soundDisabled) { "None" } else { "Default" }, { =>
                        this.doSetSound(!this.soundDisabled)
                    })
                    Divider().color(0xFFE5E5EA).strokeWidth(1).margin(left: 16)
                    this.notifyCustomizeRow("Mute for...", "", { =>
                        this.showNotifyCustomize = false
                        this.openMuteForSubmenu()
                    })
                }
                .width(100.percent)
                .backgroundColor(0xFFF2F2F7)
                .borderRadius(10)
                Text(trSource("Done"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF007AFF)
                    .width(100.percent)
                    .height(50)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(0xFFF2F2F7)
                    .borderRadius(10)
                    .margin(top: 8)
                    .onClick({ _ => this.showNotifyCustomize = false })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, bottom: 16.0 + getSafeAreaBottom())
            .backgroundColor(0xFFFFFFFF)
            .borderRadius(16)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .onClick({ _ => this.showNotifyCustomize = false })
    }

    // ==================== S5-20：分享面板（iOS ShareController：链接 + Copy Link） ====================

    @Builder
    func shareSheet() {
        Column {
            Blank().layoutWeight(1)
            Column {
                Text(trSource("Share"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF000000)
                    .margin(top: 18, bottom: 12)
                Text(this.shareLink)
                    .fontSize(15)
                    .fontColor(0xFF007AFF)
                    .maxLines(2)
                    .textOverflow(TextOverflow.Ellipsis)
                    .width(100.percent)
                    .padding(left: 14, right: 14, top: 12, bottom: 12)
                    .backgroundColor(0xFFF2F2F7)
                    .borderRadius(10)
                    .margin(bottom: 12)
                Text(trSource("Copy Link"))
                    .fontSize(17)
                    .fontColor(0xFF007AFF)
                    .width(100.percent)
                    .height(50)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(0xFFF2F2F7)
                    .borderRadius(10)
                    .onClick({ _ =>
                        setClipboardText(this.shareLink)
                        this.showShareSheet = false
                        this.showToastMsg("Link copied to clipboard")
                    })
                Text(trSource("Cancel"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF007AFF)
                    .width(100.percent)
                    .height(50)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(0xFFF2F2F7)
                    .borderRadius(10)
                    .margin(top: 8)
                    .onClick({ _ => this.showShareSheet = false })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, bottom: 16.0 + getSafeAreaBottom())
            .backgroundColor(0xFFFFFFFF)
            .borderRadius(16)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .onClick({ _ => this.showShareSheet = false })
    }

    // ==================== Toast（iOS UndoOverlayController：3 秒自动消失，不挡页面点击） ====================

    /**
     * 只占底部一条的高度（Stack 内用 margin 顶到底部），其余区域的点击照常落到页面上；
     * 3 秒后自动隐藏（UndoOverlayControllerNode.swift:272 timeout ?? 3）。
     */
    @Builder
    func toastOverlay() {
        Column {
            Text(this.toastMessage)
                .fontSize(14)
                .fontColor(0xFFFFFFFF)
                .padding(left: 20, right: 20, top: 10, bottom: 10)
                .backgroundColor(0xCC333333)
                .borderRadius(20)
        }
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
        .margin(top: this.toastTopVp())
        .onClick({ _ => this.showToast = false })
    }

    private func toastTopVp(): Float64 {
        if (this.pageHeightVp <= 0.0) { return 560.0 }
        return this.pageHeightVp - 110.0
    }

    @Builder
    func removeMemberConfirmDialog() {
        Column {
            Column {
                Text("Remove from Group")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF000000)
                    .margin(bottom: 8)
                Text("Remove ${this.memberMenuName} from ${this.displayName}?")
                    .fontSize(14)
                    .fontColor(0xFF000000)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 20)
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0xFF007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.showRemoveMemberConfirm = false })
                    Text(trSource("Remove"))
                        .fontSize(17)
                        .fontColor(0xFFFF3B30)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.removeMember() })
                }
                .width(100.percent)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.showRemoveMemberConfirm = false })
    }

    @Builder
    func memberTagDialog() {
        Column {
            Column {
                Text(trSource("Member Tag"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF000000)
                    .margin(bottom: 6)
                Text("Add short tag next to ${this.memberMenuName}'s name.")
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 12)
                TextInput(text: this.memberTagInput, placeholder: trSource("Tag"))
                    .fontSize(16)
                    .fontColor(0xFF000000)
                    .backgroundColor(0xFFF2F2F7)
                    .height(40)
                    .maxLength(16)
                    .onChange({ value: String => this.memberTagInput = value })
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0xFF007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.showMemberTagEditor = false })
                    Text(trSource("Save"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFF007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.saveMemberTag() })
                }
                .width(100.percent)
                .margin(top: 16)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func quickActionBtn(label: String, action: () -> Unit) {
        Column {
            if (label == "message") {
                Image(@r(app.media.clist_ic_newmessage)).width(24).height(24).fillColor(0xFFFFFFFF)
            } else if (label == "mute" || label == "unmute") {
                if (label == "mute") {
                    Image(@r(app.media.clist_ic_unmute)).width(24).height(24).fillColor(0xFFFFFFFF)
                } else {
                    Image(@r(app.media.clist_ic_mute)).width(24).height(24).fillColor(0xFFFFFFFF)
                }
            } else if (label == "search") {
                Image(@r(app.media.chatroom_ic_search)).width(23).height(23).fillColor(0xFFFFFFFF)
            } else if (label == "leave") {
                Text("×").fontSize(30).fontColor(0xFFFFFFFF)
            } else {
                Text("•••").fontSize(18).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
            }
            Text(label)
                .fontSize(11)
                .fontColor(0xFFFFFFFF)
                .textAlign(TextAlign.Center)
                .margin(top: 4)
        }
        .width(62)
        .height(58)
        .borderRadius(16)
        .backgroundColor(0x663C3C43)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => action() })
    }

    @Builder
    func peerInfoValue(label: String, value: String, accent: Bool) {
        Column {
            Text(label)
                .fontSize(14)
                .fontColor(this.presentation.secondaryTextColor)
            Text(value)
                .fontSize(17)
                .fontColor(if (accent) { this.presentation.accentColor } else { this.presentation.textColor })
                .maxLines(8)
                .margin(top: 4)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 14, bottom: 14)
        .alignItems(HorizontalAlign.Start)
        .onClick({ _ =>
            if (accent) { setClipboardText(value) }
        })
    }

    @Builder
    func profileActionRow(title: String, destructive: Bool, action: () -> Unit) {
        Text(title)
            .fontSize(17)
            .fontColor(if (destructive) { 0xFFFF3B30 } else { 0xFF007AFF })
            .width(100.percent)
            .height(52)
            .padding(left: 16, right: 16)
            .textAlign(TextAlign.Start)
            .onClick({ _ => action() })
    }

    /**
     * 操作行（带右箭头，点击跳转子页面）
     * S-013: @Builder 不能修饰 private
     */

    /**
     * 屏蔽确认对话框
     * S-013: @Builder 不能修饰 private
     */
    @Builder
    func blockConfirmDialog() {
        Column {
            Column {
                Text(this.getBlockTitle())
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 8)
                Text(this.getBlockMessage())
                    .fontSize(14)
                    .fontColor(0x666666)
                    .margin(bottom: 20)
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0x007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.showBlockConfirm = false })
                    Text(this.getBlockConfirmLabel())
                        .fontSize(17)
                        .fontColor(this.getBlockConfirmColor())
                        .fontWeight(FontWeight.Bold)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.doToggleBlock() })
                }
                .width(100.percent)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.showBlockConfirm = false })
    }

    /**
     * 离开确认对话框
     * S-013: @Builder 不能修饰 private
     */
    @Builder
    func leaveConfirmDialog() {
        Column {
            Column {
                Text(this.getLeaveLabel())
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 8)
                Text(this.getLeaveDialogText())
                    .fontSize(14)
                    .fontColor(0x666666)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 20)
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0x007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.showLeaveConfirm = false })
                    Text(this.getLeaveActionLabel())
                        .fontSize(17)
                        .fontColor(0xFF3B30)
                        .fontWeight(FontWeight.Bold)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.doLeave() })
                }
                .width(100.percent)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.showLeaveConfirm = false })
    }

    /**
     * 清空历史确认对话框
     * S-013: @Builder 不能修饰 private
     */
    @Builder
    func clearHistoryConfirmDialog() {
        Column {
            Column {
                Text(if (this.peerType == "user") { "Clear History" } else { "Clear Messages" })
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 8)
                // iOS PeerInfo_ClearConfirmationUser / PeerInfo_ClearConfirmationGroup
                Text(if (this.peerType == "user") {
                        "Delete all messages with ${this.displayName}? This cannot be undone."
                    } else {
                        "Are you sure you want to delete all messages in ${this.displayName}?"
                    })
                    .fontSize(14)
                    .fontColor(0x666666)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 20)
                Column {
                    // iOS openClearHistory 子菜单：Conversation_DeleteMessagesForEveryone /
                    // Conversation_DeleteMessagesForMe，按 ClearPeerHistory 能力逐项显示
                    if (this.peerType != "user" && this.canClearForEveryone()) {
                        Text(trSource("Delete for everyone"))
                            .fontSize(17)
                            .fontColor(0xFF3B30)
                            .fontWeight(FontWeight.Bold)
                            .width(100.percent)
                            .height(44)
                            .textAlign(TextAlign.Center)
                            .onClick({ _ => this.doClearHistory(true) })
                    }
                    if (this.peerType == "user" || this.canClearForMyself()) {
                        Text(if (this.peerType == "user") { "Clear" } else { "Delete just for me" })
                            .fontSize(17)
                            .fontColor(0xFF3B30)
                            .width(100.percent)
                            .height(44)
                            .textAlign(TextAlign.Center)
                            .onClick({ _ => this.doClearHistory(false) })
                    }
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0x007AFF)
                        .width(100.percent)
                        .height(44)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.showClearHistoryConfirm = false })
                }
                .width(100.percent)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.showClearHistoryConfirm = false })
    }

    @Builder
    func peerReportDialog() {
        Column {
            Column {
                Text(this.reportTitle)
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 14)
                if (this.reportLoading) {
                    LoadingProgress().width(36).height(36).color(0xFF007AFF).margin(bottom: 14)
                } else if (this.reportNeedsComment) {
                    TextInput(text: this.reportComment, placeholder: "Describe the problem")
                        .width(100.percent)
                        .height(48)
                        .backgroundColor(0xFFF2F2F7)
                        .borderRadius(10)
                        .padding(left: 12, right: 12)
                        .onChange({ value: String => this.reportComment = value })
                    Button("Submit Report")
                        .width(100.percent)
                        .height(44)
                        .fontColor(0xFFFFFFFF)
                        .backgroundColor(if (this.reportComment.size > 0) { 0xFFFF3B30 } else { 0xFFB0B0B0 })
                        .enabled(this.reportComment.size > 0)
                        .margin(top: 12)
                        .onClick({ _ => this.submitPeerReportComment() })
                } else {
                    ForEach(this.reportOptions.toArray(), itemGenerator: { option: String, index: Int64 =>
                        Text(option)
                            .fontSize(16)
                            .fontColor(0xFFFF3B30)
                            .width(100.percent)
                            .height(44)
                            .textAlign(TextAlign.Center)
                            .onClick({ _ => this.selectPeerReportOption(index) })
                    })
                }
                Text(trSource("Cancel"))
                    .fontSize(16)
                    .fontColor(0xFF007AFF)
                    .width(100.percent)
                    .height(44)
                    .textAlign(TextAlign.Center)
                    .margin(top: 8)
                    .onClick({ _ => this.showPeerReport = false })
            }
            .width(84.percent)
            .padding(20)
            .backgroundColor(0xFFFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    /**
     * 自动删除设置对话框（选择关闭/1天/1周/1月）
     * S-013: @Builder 不能修饰 private
     */
    /**
     * S226: 自定义自动删除时长。对位 iOS GlobalAutoremoveScreen / PeerInfo 的
     * openCustomValue → ChatTimerScreen(mode:.autoremove)，选定后同样落
     * messages.setHistoryTTL，与四个固定档共用 doSetAutoDelete。
     */
    @Builder
    func autoDeleteCustomSheet() {
        Column {
            Column {
                DurationPickerSheet(
                    title: "Auto-Delete Messages",
                    onConfirm: { secs: Int32 =>
                        this.showAutoDeleteCustom = false
                        this.doSetAutoDelete(secs)
                    },
                    onCancel: { =>
                        this.showAutoDeleteCustom = false
                    }
                )
            }
            .width(85.percent)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func autoDeleteDialog() {
        Column {
            Column {
                Text(trSource("Auto-Delete Messages"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 16)

                Column {
                    Text(trSource("Off"))
                        .fontSize(16)
                        .fontColor(0x007AFF)
                        .width(100.percent)
                        .height(44)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.doSetAutoDelete(0) })
                    Divider().color(0xE5E5EA).strokeWidth(1)
                    Text("1 Day")
                        .fontSize(16)
                        .fontColor(0x007AFF)
                        .width(100.percent)
                        .height(44)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.doSetAutoDelete(86400) })
                    Divider().color(0xE5E5EA).strokeWidth(1)
                    Text("1 Week")
                        .fontSize(16)
                        .fontColor(0x007AFF)
                        .width(100.percent)
                        .height(44)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.doSetAutoDelete(604800) })
                    Divider().color(0xE5E5EA).strokeWidth(1)
                    Text("1 Month")
                        .fontSize(16)
                        .fontColor(0x007AFF)
                        .width(100.percent)
                        .height(44)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.doSetAutoDelete(2678400) })
                    Divider().color(0xE5E5EA).strokeWidth(1)
                    // S226: 对位源侧 openCustomValue → ChatTimerScreen(mode:.autoremove)
                    Text("Set a Custom Time")
                        .fontSize(16)
                        .fontColor(0x007AFF)
                        .width(100.percent)
                        .height(44)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ =>
                            this.showAutoDeleteConfirm = false
                            this.showAutoDeleteCustom = true
                        })
                }
                .borderRadius(10)
                .backgroundColor(0xF2F2F7)
                .margin(bottom: 8)

                Text(trSource("Cancel"))
                    .fontSize(17)
                    .fontColor(0x007AFF)
                    .fontWeight(FontWeight.Bold)
                    .width(100.percent)
                    .height(44)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(10)
                    .onClick({ _ => this.showAutoDeleteConfirm = false })
            }
            .width(85.percent)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.showAutoDeleteConfirm = false })
    }

    /**
     * Grid columnsTemplate 字符串，例如 gridSize=12 → "1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr"
     * S-005: 不能在 @Builder 内用 let，提取为 private func
     */
    private func keyGridColumnsTemplate(): String {
        let sz = Int64(this.secretChatKeyGrid.gridSize)
        if (sz <= 0) { return "1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr" }
        var tmpl: String = "1fr"
        var i: Int64 = 1
        while (i < sz) {
            tmpl = tmpl + " 1fr"
            i++
        }
        return tmpl
    }

    /**
     * Grid rowsTemplate 字符串，与 columnsTemplate 对称
     */
    private func keyGridRowsTemplate(): String {
        return this.keyGridColumnsTemplate()
    }

    /**
     * 网格总尺寸（宽=高，vp）：每格 14vp，含 1px 间距
     */
    private func keyGridTotalSize(): Float64 {
        let sz = Int64(this.secretChatKeyGrid.gridSize)
        if (sz <= 0) { return 120.0 }
        return Float64(sz) * 14.0
    }


    /**
     * 密钥可视化 Section（P2-148b）
     * 仅当 peerType == "secret" 且 secretChatKeyLoaded 时渲染。
     *
     * 布局：
     *   Section 标题 "Encryption Key"
     *   颜色网格（12×12 or 8×8 色块，总宽 ~160vp，居中）
     *   emoji 指纹行（4 个 emoji）
     *   说明文字
     *
     * S-005: @Builder 内禁止 let/var；所有计算通过 private func 访问。
     * S-013: @Builder 不能修饰 private。
     *
     * 色块渲染方式：Grid(columnsTemplate) + ForEach(cells, GridItem)
     * ForEach 的 itemGeneratorFunc 接受 (item: Int32, index: Int64)。
     */
    @Builder
    func buildEncryptionKeySection() {
        Column {
            Text(trSource("Encryption Key"))
                .fontSize(13)
                .fontColor(this.presentation.secondaryTextColor)
                .margin(bottom: 8)
                .alignSelf(ItemAlign.Start)

            Grid() {
                ForEach(
                    Array<Int64>(this.secretChatKeyGrid.cells.size, { i: Int64 => i }),
                    itemGenerator: { cellIdx: Int64, _i: Int64 =>
                        GridItem() {
                            Column {}
                                .width(100.percent)
                                .height(100.percent)
                                .backgroundColor(this.keyGridCellColor(cellIdx))
                        }
                    }
                )
            }
            .columnsTemplate(this.keyGridColumnsTemplate())
            .rowsTemplate(this.keyGridRowsTemplate())
            .width(this.keyGridTotalSize())
            .height(this.keyGridTotalSize())
            .margin(bottom: 10)

            Text(this.secretChatKeyEmoji)
                .fontSize(22)
                .margin(bottom: 8)
                .textAlign(TextAlign.Center)

            Text("Compare this key with your contact's key. If they match, the chat is encrypted end-to-end.")
                .fontSize(13)
                .fontColor(this.presentation.secondaryTextColor)
                .textAlign(TextAlign.Center)
                .maxLines(3)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 14, bottom: 14)
        .backgroundColor(this.presentation.cardColor)
        .margin(top: 8)
        .alignItems(HorizontalAlign.Center)
    }
}
