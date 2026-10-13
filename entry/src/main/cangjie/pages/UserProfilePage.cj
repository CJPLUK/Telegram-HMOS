package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.components.{ProfileMuteIcon, CustomEmojiImage, DurationPickerSheet, ContextMenuView, ContextMenuItem, Avatar}
import ohos_app_cangjie_entry.interop.*
import ohos_app_cangjie_entry.utils.{formatClockHHMM, formatRelativeTime}
import ohos.resource.__GenerateResource__
import std.time.*
import std.collection.ArrayList
import std.convert.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.models.CallRecord
import ohos_app_cangjie_entry.viewmodels.getChatListVM

/**
 * UserProfilePage — 用户资料页（P2-131）（混合工程迁移版）
 *
 * 对应 iOS PeerInfoUI/Sources/UserInfoController.swift + PeerInfoScreen.swift 的用户资料屏。
 *
 * 功能：
 *   - 内联头像区（premium 金圈 / verified 蓝圈 / 初字兜底），同 PeerInfoPage 逻辑
 *   - 快捷按钮行：消息 / 静音 / 通话 / 视频
 *   - 用户信息行：phone / username / bio / bot 角色标注
 *   - 屏蔽/取消屏蔽操作
 *   - 头像大图查看器；点头像展开为顶部大图（iOS isAvatarExpanded，S6-01）
 *   - 通知静音开关
 *   - username 行点按分享 / 长按 Copy Username；bio 行长按 Copy Bio；他人生日行；共同群组页签
 *
 * 死状态防护：
 *   所有 @State 徽章标志（isVerified / isScam / isFake / isBot / isPremium）在
 *   ensureLoaded 中从 getRealChatListService().getCachedUser() 回填。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination() { ... }.title("Info").hideTitleBar(false) 包裹，只留内部 Stack
 *  - pageStack.pop() / pop(animated:) → routerPop()
 *  - pageStack.pushPathByName("SharedMediaPage", "") → routerPush("SharedMediaPage", "")
 *  - aboutToAppear 有实逻辑 → ensureLoaded() + .onAppear
 */
/** 打开指定用户的参数："user:{userId}:{displayName}"；其余格式回退到当前选中会话。 */
public func userProfileParam(userId: Int64, displayName: String): String {
    return "user:${userId}:${displayName}"
}

/**
 * S2-02：会话导航栏头像入口的路由参数（iOS PeerInfoScreen avatarInitiallyExpanded=true）——
 * 资料页打开即显示展开的大头像；其余入口（点标题、成员列表等）保持圆头像，点头像再展开（S6-01）。
 */
public let USER_PROFILE_EXPAND_AVATAR_PARAM: String = "expandAvatar"

private func parseUserProfileParam(raw: String): (Int64, String) {
    if (!raw.startsWith("user:")) { return (0, "") }
    let body = raw[5..]
    let sep = body.indexOf(":")
    match (sep) {
        case Some(i) =>
            let id = try { Int64.parse(body[0..i]) } catch (_: Exception) { 0 }
            return (id, body[(i + 1)..])
        case None => return (0, "")
    }
}

// 系统返回键：UserProfilePage.ets onBackPressed 同步派发 userProfilePage.backPressed。iOS 上头像展开态
// （PeerInfoHeaderNode.isAvatarExpanded）按返回先收起头像、分享面板/菜单先关闭，都不出栈；本页消费后
// 同步回调 userProfile.backHandled，ArkTS 不再 pop。
let USER_PROFILE_BACK_EVENT: String = "userProfilePage.backPressed"
let USER_PROFILE_BACK_HANDLED: String = "userProfile.backHandled"
var g_userProfileBackSubscribed: Bool = false
var g_userProfileBackHandler: Option<() -> Bool> = None
var g_userProfileBackGeneration: Int64 = 0

func registerUserProfileBackHandler(handler: () -> Bool): Int64 {
    if (!g_userProfileBackSubscribed) {
        g_userProfileBackSubscribed = true
        subscribe(USER_PROFILE_BACK_EVENT, { _p: String =>
            match (g_userProfileBackHandler) {
                case Some(h) => if (h()) { callArk(USER_PROFILE_BACK_HANDLED, "{}") }
                case None => ()
            }
        })
    }
    g_userProfileBackGeneration += 1
    g_userProfileBackHandler = Some(handler)
    return g_userProfileBackGeneration
}

func unregisterUserProfileBackHandler(generation: Int64): Unit {
    if (generation != 0 && generation == g_userProfileBackGeneration) {
        g_userProfileBackHandler = None
    }
}

// S8-21: calls handed over by the Calls tab (CallListController openInfo → PeerInfoScreen(callMessages:)).
// Taken once by the next UserProfilePage of the same peer; any other profile open discards them.
private var _pendingProfileCallPeerId: Int64 = 0
private var _pendingProfileCallRecords: ArrayList<CallRecord> = ArrayList<CallRecord>()

public func setUserProfileCallRecords(peerId: Int64, records: ArrayList<CallRecord>): Unit {
    let copy = ArrayList<CallRecord>()
    for (r in records) { copy.add(r) }
    _pendingProfileCallPeerId = peerId
    _pendingProfileCallRecords = copy
}

private func takeUserProfileCallRecords(peerId: Int64): ArrayList<CallRecord> {
    let out = ArrayList<CallRecord>()
    if (_pendingProfileCallPeerId == peerId) {
        for (r in _pendingProfileCallRecords) { out.add(r) }
    }
    _pendingProfileCallPeerId = 0
    _pendingProfileCallRecords = ArrayList<CallRecord>()
    return out
}

/** iOS PeerInfoProfileItems.swift: isBirthdayToday → label UserInfo.BirthdayToday. */
private func birthdayIsToday(bd: BirthdayData): Bool {
    let now = DateTime.now().inLocal()
    return Int64(bd.day) == Int64(now.dayOfMonth) && Int64(bd.month) == Int64(now.month.toInteger())
}

private let PROFILE_CALL_MONTHS: Array<String> = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// iOS stringForDate(timestamp:) — medium date style in UTC (DateFormat.swift:109-116), e.g. "28 Sep 2026".
private func profileCallDateString(unixSec: Int64): String {
    let dt = DateTime.fromUnixTimeStamp(Duration.second * unixSec)
    return "${dt.dayOfMonth} ${PROFILE_CALL_MONTHS[dt.month.toInteger() - 1]} ${dt.year}"
}

/** One line of the PeerInfo call list (ItemListCallListItem: time + stringForCallType). */
public class ProfileCallEntry {
    public var time: String = ""
    public var typeText: String = ""
    public var key: String = ""
}

@HybridComponentEntry
@Component
public class UserProfilePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ========== 基础信息 ==========
    @State var peerId: Int64 = 0
    @State var displayName: String = ""
    @State var username: String = ""
    @State var phone: String = ""
    @State var bio: String = ""
    @State var statusText: String = "last seen a long time ago"
    @State var avatarLetter: String = "U"
    @State var avatarPhotoPath: String = ""
    @State var avatarEmojiDocumentId: Int64 = 0
    @State var avatarEmojiBackgroundStart: UInt32 = 0xFF5BD1CA
    @State var avatarEmojiBackgroundEnd: UInt32 = 0xFF538EDB
    @State var accessHash: Int64 = 0
    @State var firstName: String = ""
    @State var lastName: String = ""

    // ========== 徽章标志（iOS flag 位，死状态防护：ensureLoaded 从缓存回填）==========
    @State var isVerified: Bool = false
    @State var isScam: Bool = false
    @State var isFake: Bool = false
    @State var isBot: Bool = false
    @State var isPremium: Bool = false
    @State var isSelf: Bool = false
    // S7-44 / S6-15: date of birth row (iOS PeerInfoProfileItems.swift:208-223 ItemBirthdate row);
    // own value from account cache, other users from userFull.birthday.
    @State var birthdayText: String = ""
    @State var isBirthdayToday: Bool = false
    // S7-48: own personal channel (iOS PeerInfoProfileItems.swift:122-139, section before info).
    @State var selfPersonalChannelId: Int64 = 0
    @State var selfPersonalChannelTitle: String = ""
    @State var isContact: Bool = false
    @State var isSupport: Bool = false
    @State var botSubscriberCount: Int32 = 0

    // ========== 用户状态 ==========
    @State var isBlocked: Bool = false
    @State var isMuted: Bool = false
    @State var isLoading: Bool = true

    // ========== UI 状态 ==========
    @State var showBlockConfirm: Bool = false
    @State var showAvatarViewer: Bool = false
    @State var toastMessage: String = ""
    @State var showToast: Bool = false
    private var toastGeneration: Int64 = 0
    @State var pageHeightVp: Float64 = 0.0
    @State var showMoreMenu: Bool = false
    // S226：Auto-Delete（iOS PeerInfo 用户 "..." 菜单 → Auto-Delete → 预设/自定义时长）
    @State var showAutoDeleteDialog: Bool = false
    @State var showAutoDeleteCustom: Bool = false
    // S6-06：Start Secret Chat 确认框（iOS UserInfo_StartSecretChatConfirmation → Cancel / Start）
    @State var showSecretChatConfirm: Bool = false
    @State var showEditContact: Bool = false
    @State var editFirstName: String = ""
    @State var editLastName: String = ""
    // S6-27 / S6-30: iOS PeerInfo edit mode for a contact（PeerInfoProfileItems.swift:1032-1110）
    // —— note（userFull.note，仅自己可见）、个人头像（personal_photo）、删除联系人
    @State var editNote: String = ""
    @State var contactNote: String = ""
    @State var hasPersonalPhoto: Bool = false
    @State var showDeleteContactConfirm: Bool = false
    @State var contactPhotoBusy: Bool = false
    @State var showContactPhotoConfirm: Bool = false
    @State var pendingContactPhotoPath: String = ""
    @State var pendingContactPhotoSuggest: Bool = false
    @State var muteAnimationSerial: Int64 = 0
    // S6-01: iOS PeerInfoHeaderNode.isAvatarExpanded — tapping the round avatar expands it into the
    // full-bleed header; back (or tapping the header back button) collapses it again.
    @State var avatarExpanded: Bool = false
    // S6-13 / S5-20 style share sheet (iOS ShareController with the t.me link)
    @State var showShareSheet: Bool = false
    @State var shareLink: String = ""
    // S6-13 / S6-14: long-press copy menus (Copy Username / Copy Bio)
    @State var showCopyMenu: Bool = false
    @State var copyMenuItems: Array<ContextMenuItem> = Array<ContextMenuItem>()
    // S6-24: Groups in common (messages.getCommonChats)
    @State var commonGroups: ArrayList<ChatResponse> = ArrayList<ChatResponse>()
    @State var commonGroupsLoaded: Bool = false
    @State var selectedProfileTab: String = ""
    // S6-20: the Add to Contacts row opens the contact form in "add" mode
    @State var editContactIsAdd: Bool = false
    // long-press tracking for info rows (same shape as PeerInfoPage member rows)
    private var rowPressGeneration: Int64 = 0
    private var rowPressActive: Bool = false
    private var rowPressX: Float64 = 0.0
    private var rowPressY: Float64 = 0.0
    private var suppressRowClick: Bool = false
    private var _backHandlerGeneration: Int64 = 0

    @State var loaded: Bool = false
    // S8-21: call list section (PeerInfoScreenCallListItem) when opened from the Calls tab
    @State var callListTitle: String = ""
    @State var callListEntries: ArrayList<ProfileCallEntry> = ArrayList<ProfileCallEntry>()
    private let profileScroller: Scroller = Scroller()
    // 展开态头部（对位 iOS PeerInfoHeaderNode）：主头像按 Cover 铺满 屏宽 × (屏宽 + 150)。
    // 优先用 photos.getUserPhotos 的原图，未取到时用 big 头像，两者同一布局，切换无跳变。
    @State var headerWidthVp: Float64 = 390.0
    @State var headerFullPhotoPath: String = ""
    private func expandedHeaderHeight(): Float64 {
        return this.headerWidthVp + 150.0
    }
    private var muteMutationVersion: Int64 = 0

    // ==================== 系统返回键 ====================

    private func handleSystemBack(): Bool {
        if (this.showAvatarViewer) {
            this.showAvatarViewer = false
            return true
        }
        if (this.showShareSheet) {
            this.showShareSheet = false
            return true
        }
        if (this.showCopyMenu) {
            this.showCopyMenu = false
            return true
        }
        if (this.showMoreMenu) {
            this.showMoreMenu = false
            return true
        }
        if (this.showSecretChatConfirm) {
            this.showSecretChatConfirm = false
            return true
        }
        if (this.showContactPhotoConfirm) {
            this.showContactPhotoConfirm = false
            this.pendingContactPhotoPath = ""
            return true
        }
        if (this.showDeleteContactConfirm) {
            this.showDeleteContactConfirm = false
            return true
        }
        if (this.showEditContact) {
            this.showEditContact = false
            return true
        }
        if (this.avatarExpanded) {
            this.avatarExpanded = false
            return true
        }
        return false
    }

    // ==================== 信息行长按（Copy Username / Copy Bio） ====================

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

    /** onClick 在长按松手后仍会触发：长按已消费则吞掉这一次点击。 */
    private func consumeSuppressedClick(): Bool {
        if (this.suppressRowClick) {
            this.suppressRowClick = false
            return true
        }
        return false
    }

    private func openCopyMenu(title: String, value: String, toast: String): Unit {
        this.copyMenuItems = [
            ContextMenuItem(title: title, onClick: { =>
                setClipboardText(value)
                this.showCopyMenu = false
                this.showToastMsg(toast)
            })
        ]
        this.showCopyMenu = true
    }

    private func openShareSheet(link: String): Unit {
        this.shareLink = link
        this.showShareSheet = true
    }

    // ==================== S6-07: Share Contact ====================

    /**
     * iOS PeerInfoScreenPerformButtonAction.swift Profile_ShareContactButton：
     * TelegramMediaContact(firstName, lastName, phoneNumber) → ShareController → 发到选中对话。
     * 目标侧复用 ShareControllerPage（setPendingShareContact → sendContactToMultiPeers →
     * RealMessageService.sendContact，与附件面板「Contact」项同一发送链路）。
     */
    private func openShareContact(): Unit {
        if (this.phone.size == 0) { return }
        var first = this.firstName
        var last = this.lastName
        if (first.size == 0 && last.size == 0) {
            first = this.displayName
            last = ""
        }
        setPendingShareContact(this.phone, first, last)
        routerPush("ShareControllerPage", "")
    }

    // ==================== S6-06: Start Secret Chat ====================

    /**
     * iOS PeerInfoScreen.swift openStartSecretChat：确认后 createSecretChat → 直接进入该秘密会话。
     * 目标侧复用 ContactListPage.startSecretChatWithContact 同一流程：
     *   TelegramCore_SecretChatsService.requestEncryption(userId, accessHash)
     *   → setSelectedChat(secretChatId, name, "secret") + setSelectedSecretPeerUserId → ChatRoomPage
     */
    private func doStartSecretChat(): Unit {
        this.showSecretChatConfirm = false
        let userId = this.peerId
        let accessHash = this.accessHash
        let name = this.displayName
        let _ = spawn {
            try {
                let hash = if (accessHash != 0) { accessHash } else { getRealMessageService().getAccessHashForUser(userId) }
                let chatId = getTelegramCore_SecretChatsService().requestEncryption(userId, hash)
                Hilog.info(0, "CjTelegram", "[UserProfilePage] startSecretChat user=${userId} secretChatId=${chatId}")
                launch {
                    // encryptedChat.id 是 TL int32，服务端会分配负值；失败返回 0
                    if (chatId != 0) {
                        setSelectedChat(Int64(chatId), name, "secret")
                        setSelectedChatDraft("")
                        setSelectedSecretPeerUserId(userId)
                        routerPush("ChatRoomPage", name)
                    } else {
                        this.showToastMsg("Could not start secret chat")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UserProfilePage] startSecretChat error: ${e}")
                launch { this.showToastMsg("Could not start secret chat") }
            }
        }
    }

    @Builder
    func secretChatConfirmDialog() {
        Column {
            Column {
                Text("Are you sure you want to start a secret chat with ${this.displayName}?")
                    .fontSize(15)
                    .fontColor(0x000000)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 20)
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0x007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.showSecretChatConfirm = false })
                    Text("Start")
                        .fontSize(17)
                        .fontColor(0x007AFF)
                        .fontWeight(FontWeight.Bold)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.doStartSecretChat() })
                }
                .width(100.percent)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.showSecretChatConfirm = false })
    }

    // ==================== S6-24: Groups in common ====================

    private func loadCommonGroups(): Unit {
        let uid = this.peerId
        let _ = spawn {
            let chats = getPeerInfoService().getCommonChats(uid)
            launch {
                if (this.peerId != uid) { return }
                this.commonGroups = chats
                this.commonGroupsLoaded = true
            }
        }
    }

    private func openCommonGroup(chat: ChatResponse): Unit {
        let peerType = if (chat.isChannel) { "channel" } else { "chat" }
        getRealChatListService().cacheChatResponse(chat)
        setSelectedChat(chat.id, chat.title, peerType)
        setSelectedChatUsername(chat.username)
        routerPush("ChatRoomPage", chat.title)
    }

    private func commonGroupSubtitle(chat: ChatResponse): String {
        if (chat.participantsCount > 0) {
            if (chat.participantsCount == 1) { return "1 member" }
            return "${chat.participantsCount} members"
        }
        return if (chat.isBroadcast) { "channel" } else { "group" }
    }

    private func openSharedMediaTab(tab: Int64): Unit {
        routerPush("SharedMediaPage", "user:${this.peerId}:${tab}")
    }

    private var _avatarCallbackRegistered: Bool = false

    private func registerAvatarReadyCallback(): Unit {
        if (this._avatarCallbackRegistered) { return }
        this._avatarCallbackRegistered = true
        let peerIdCopy = this.peerId
        getUserPhotoService().addPhotoReadyCallback({ userId: Int64, dataUrl: String =>
            if (userId == peerIdCopy && dataUrl.size > 0) {
                launch { this.avatarPhotoPath = dataUrl }
            }
        })
    }

    /** 取主头像原图：先同步命中本地缓存，未命中再异步经 photos.getUserPhotos 下载。 */
    private func loadHeaderFullPhoto(): Unit {
        let uid = this.peerId
        let ah = this.accessHash
        if (uid == 0) { return }
        match (getUserPhotoService().getCachedUser(uid)) {
            case Some(u) =>
                let cached = getPeerInfoAvatarListService().cachedPrimaryFullPhotoPath(uid, u.photoId)
                if (cached.size > 0) {
                    this.headerFullPhotoPath = cached
                    return
                }
            case None => ()
        }
        let _ = spawn {
            try {
                let path = getPeerInfoAvatarListService().fetchPrimaryFullPhotoPath(uid, ah)
                if (path.size > 0) {
                    launch { this.headerFullPhotoPath = path }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UserProfilePage] loadHeaderFullPhoto error: ${e}")
            }
        }
    }

    // ItemListCallListItem.swift:64-112 stringForCallType (1:1 phone calls).
    private func profileCallTypeText(r: CallRecord): String {
        let strings = this.sourceLocalizationPresentation
        let incoming = !r.isOutgoing
        let reason = r.discardReason
        // PhoneCallDiscardReason: disconnect#e095c1a0, missed#85e42301, busy#faf7e8c9
        if (reason == 0xe095c1a0 || ((reason == 0x85e42301 || reason == 0xfaf7e8c9) && !incoming)) {
            return if (r.isVideo) { strings.getOr("Notification_VideoCallCanceled", "Cancelled Video Call") } else { strings.getOr("Notification_CallCanceled", "Cancelled Call") }
        }
        if (reason == 0x85e42301 || reason == 0xfaf7e8c9) {
            return if (r.isVideo) { strings.getOr("Notification_VideoCallMissed", "Missed Video Call") } else { strings.getOr("Notification_CallMissed", "Missed Call") }
        }
        if (incoming) {
            return if (r.isVideo) { strings.getOr("Notification_VideoCallIncoming", "Incoming Video Call") } else { strings.getOr("Notification_CallIncoming", "Incoming Call") }
        }
        return if (r.isVideo) { strings.getOr("Notification_VideoCallOutgoing", "Outgoing Video Call") } else { strings.getOr("Notification_CallOutgoing", "Outgoing Call") }
    }

    private func loadCallListSection(records: ArrayList<CallRecord>): Unit {
        let entries = ArrayList<ProfileCallEntry>()
        if (records.size == 0) {
            this.callListEntries = entries
            return
        }
        let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
        var earliest: Int64 = -1
        var i: Int64 = 0
        for (r in records) {
            let ts = if (r.date > 0) { Int64(r.date) } else { nowSec }
            if (earliest < 0 || ts < earliest) { earliest = ts }
            let e = ProfileCallEntry()
            e.time = formatClockHHMM(ts)
            e.typeText = this.profileCallTypeText(r)
            e.key = "${i}_${r.msgId}_${ts}"
            entries.add(e)
            i = i + 1
        }
        this.callListTitle = profileCallDateString(earliest)
        this.callListEntries = entries
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // Explicit peer parameters keep member-profile navigation independent of
        // the chat currently visible underneath this page.
        let rawParam = takePending("UserProfilePage")
        let (paramId, paramName) = parseUserProfileParam(rawParam)
        if (paramId > 0) {
            this.peerId = paramId
            this.displayName = paramName
            this.username = ""
        } else {
            this.peerId = getSelectedChatId()
            this.displayName = getSelectedChatName()
            this.username = getSelectedChatUsername()
        }
        // PeerInfoScreenImpl receives isMyProfile from the route, independently of
        // the cached TelegramUser flags.  The active account id is the equivalent
        // source of truth on this side and also survives account switching.
        this.isSelf = this.peerId > 0 && this.peerId == getCurrentUserId()
        if (this.isSelf) { this.statusText = "online" }
        // S2-02：从会话导航栏头像进入 → 头像初始即展开（iOS avatarInitiallyExpanded）
        if (!this.isSelf && rawParam == USER_PROFILE_EXPAND_AVATAR_PARAM) {
            this.avatarExpanded = true
        }
        this.loadCallListSection(takeUserProfileCallRecords(this.peerId))
        if (this.isSelf) {
            this.selfPersonalChannelId = getSettingsService().getPersonalChannelId()
            this.selfPersonalChannelTitle = getSettingsService().getPersonalChannelTitle()
            match (getSettingsService().getCachedBirthday()) {
                case Some(bd) =>
                    this.birthdayText = compactBirthdayString(bd, showAge: true)
                    this.isBirthdayToday = birthdayIsToday(bd)
                case None => this.birthdayText = ""
            }
        }

        if (this.displayName.size > 0) {
            this.avatarLetter = this.displayName.toRuneArray()[0].toString()
        }

        // 死状态防护：从缓存立即回填所有字段（包含徽章标志）
        let chatListService = getRealChatListService()
        // 会话列表缓存只含有对话的用户；纯联系人落在 UserPhotoService.userCache，两处都查。
        let cachedUser: Option<UserResponse> = if (this.isSelf) {
            // My Profile is account-scoped.  A peer cache may still contain an
            // older projection for the same route, while auth owns the active
            // account identity and is updated atomically on account switches.
            getRealAuthService().getCurrentUser()
        } else {
            match (chatListService.getCachedUser(this.peerId)) {
                case Some(u) => Some(u)
                case None => getUserPhotoService().getCachedUser(this.peerId)
            }
        }
        match (cachedUser) {
            case Some(user) =>
                this.phone = user.phone
                this.accessHash = user.accessHash
                this.isPremium = user.isPremium
                this.isVerified = user.isVerified
                this.isScam = user.isScam
                this.isFake = user.isFake
                this.isBot = user.isBot
                this.isSelf = this.isSelf || user.isSelf
                this.isContact = user.isContact
                this.isSupport = user.isSupport
                // 以缓存 user 的 username 为准（全局 selected-chat username 不是所有入口都会设置）。
                if (user.username.size > 0) { this.username = user.username }
                this.botSubscriberCount = user.botSubscriberCount
                this.firstName = user.firstName
                this.lastName = user.lastName
                this.editFirstName = user.firstName
                this.editLastName = user.lastName
                this.statusText = this.profileStatusText(user)
                if (user.firstName.size > 0 || user.lastName.size > 0) {
                    let fullName = if (user.firstName.size > 0 && user.lastName.size > 0) {
                        "${user.firstName} ${user.lastName}"
                    } else {
                        if (user.firstName.size > 0) { user.firstName } else { user.lastName }
                    }
                    if (fullName.size > 0) {
                        this.displayName = fullName
                        this.avatarLetter = fullName.toRuneArray()[0].toString()
                    }
                }
                // 注册 accessHash 到 PeerInfoService
                getPeerInfoService().registerUserAccessHash(user.id, user.accessHash)
            case None =>
                Hilog.info(0, "CjTelegram", "[UserProfilePage] User not in cache: ${this.peerId}")
                this.accessHash = getPeerInfoService().getUserAccessHash(this.peerId)
        }

        // 头像路径（同步，有缓存路径则直接渲染）
        this.avatarPhotoPath = getUserPhotoService().getUserPhotoPath(this.peerId)
        this.loadAvatarMarkup()
        // 未落盘时上面拿到的是 TL 内嵌的模糊缩略图；请求 640px big 头像，下载完成后替换。
        this.registerAvatarReadyCallback()
        getUserPhotoService().requestFullPhotoDownload(this.peerId)
        this.loadHeaderFullPhoto()

        // Match iOS: render cached peer data immediately, then refresh full info.
        this.isLoading = false

        // 异步加载完整用户信息（bio / isBlocked，以及覆盖徽章标志为 true）
        this.loadUserFullInfo()
        this.loadContactNote()
        this.loadMuteState()
        if (!this.isSelf && this.peerId > 0) { this.loadCommonGroups() }
    }

    private func loadAvatarMarkup(): Unit {
        let uid = this.peerId
        let hash = this.accessHash
        spawn {
            let infos = getPeerInfoAvatarListService().fetchUserPhotoInfos(uid, hash, limit: 1)
            launch {
                if (this.peerId != uid || infos.isEmpty()) { return }
                let info = infos[0]
                this.avatarEmojiDocumentId = info.emojiDocumentId
                if (info.emojiBackgroundColors.size >= 2) {
                    this.avatarEmojiBackgroundStart = UInt32(Int64(info.emojiBackgroundColors[0]) & 0xFFFFFFFF)
                    this.avatarEmojiBackgroundEnd = UInt32(Int64(info.emojiBackgroundColors[1]) & 0xFFFFFFFF)
                }
            }
        }
    }

    // ==================== 异步加载 ====================

    /**
     * S6-27：联系人备注。userFull.note 只在 layer ≥ 222 编码里，主会话（214）的 getFullUser 永远不带，
     * 所以 PeerInfoService.getContactNote 单独走 layer-228 通道取一次；与 loadUserFullInfo 并行，不拖慢 bio 等。
     */
    private func loadContactNote(): Unit {
        if (this.isSelf || this.isBot || !this.isContact) { return }
        let uid = this.peerId
        let _ = spawn {
            var noteVal = ""
            try {
                noteVal = getPeerInfoService().getContactNote(uid)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UserProfilePage] loadContactNote error: ${e}")
            }
            let noteFinal = noteVal
            launch {
                this.contactNote = noteFinal
                if (!this.showEditContact) { this.editNote = noteFinal }
            }
        }
    }

    /**
     * 通过 PeerInfoService.getUserFullInfo 加载 bio / isBlocked / badge flags
     * S-001：@State 写入在 launch{} 内（主线程）。
     */
    private func loadUserFullInfo(): Unit {
        let uid = this.peerId
        let _ = spawn {
            try {
                let infoService = getPeerInfoService()
                let info = infoService.getUserFullInfo(uid)
                let bioVal = info.bio
                let blockedVal = info.isBlocked
                let errVal = info.error
                let verifiedVal = info.isVerified
                let scamVal = info.isScam
                let fakeVal = info.isFake
                let botVal = info.isBot
                let bdDay = info.birthdayDay
                let bdMonth = info.birthdayMonth
                let bdYear = info.birthdayYear
                let personalPhotoVal = info.hasPersonalPhoto
                launch {
                    if (errVal.size == 0) {
                        this.bio = bioVal
                        this.isBlocked = blockedVal
                        // S6-30: userFull.personal_photo → 联系人编辑页 Reset/Change 行（note 走 loadContactNote）
                        this.hasPersonalPhoto = personalPhotoVal
                        // 只追加正值；不覆盖已从缓存拿到的 true（防止网络返回旧值清零）
                        if (verifiedVal) { this.isVerified = true }
                        if (scamVal) { this.isScam = true }
                        if (fakeVal) { this.isFake = true }
                        if (botVal) { this.isBot = true }
                        // S6-15: userFull.birthday → "date of birth" row（iOS ItemBirthdate，showAge: true）
                        if (!this.isSelf && bdDay > 0 && bdMonth > 0) {
                            let bd = BirthdayData()
                            bd.day = bdDay
                            bd.month = bdMonth
                            bd.year = bdYear
                            this.birthdayText = compactBirthdayString(bd, showAge: true)
                            this.isBirthdayToday = birthdayIsToday(bd)
                        }
                    } else {
                        Hilog.info(0, "CjTelegram", "[UserProfilePage] getUserFullInfo error: ${errVal}")
                    }
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UserProfilePage] loadUserFullInfo error: ${e}")
                launch { this.isLoading = false }
            }
        }
    }

    private func loadMuteState(): Unit {
        let uid = this.peerId
        let requestVersion = this.muteMutationVersion
        let _ = spawn {
            let muted = getRealChatListService().getPeerMuteState("user", uid)
            launch {
                if (this.muteMutationVersion == requestVersion) {
                    this.isMuted = muted
                }
            }
        }
    }

    // ==================== 操作：屏蔽/取消屏蔽 ====================

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
                Hilog.info(0, "CjTelegram", "[UserProfilePage] doToggleBlock error: ${e}")
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
    /**
     * 备注改名后同步其它持有该名字的地方：当前选中会话（聊天页标题栏）和聊天列表行。
     * iOS 由 Postbox 的 peer 更新统一驱动；本工程没有统一 peer 存储，由改名入口显式广播。
     */
    private func applyPeerDisplayName(peerId: Int64, name: String): Unit {
        if (getSelectedChatId() == peerId && getSelectedChatPeerType() == "user") {
            setSelectedChat(peerId, name, "user")
        }
        notifyPeerDisplayNameChanged(peerId, "user", name)
        match (getChatListVM()) {
            case Some(vm) =>
                let newChatList = ArrayList<Chat>()
                for (c in vm.chatList) {
                    if (c.id == peerId && c.peerType == "user") { c.name = name }
                    newChatList.add(c)
                }
                vm.chatList = newChatList
                let newArchiveList = ArrayList<Chat>()
                for (c in vm.archiveChatList) {
                    if (c.id == peerId && c.peerType == "user") { c.name = name }
                    newArchiveList.add(c)
                }
                vm.archiveChatList = newArchiveList
                vm.publishCurrentChatList("peerDisplayNameApplied")
            case None => ()
        }
    }

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
        let pid = this.peerId
        let muted = this.isMuted
        this.muteMutationVersion = this.muteMutationVersion + 1
        let _ = spawn {
            try {
                let svc = getRealChatListService()
                let ok = svc.toggleMuteDialog("user", pid, !muted)
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
                Hilog.info(0, "CjTelegram", "[UserProfilePage] doToggleMute error: ${e}")
            }
        }
    }

    private func doAddContact(): Unit {
        let uid = this.peerId
        let aHash = this.accessHash
        let first = this.firstName
        let last = this.lastName
        let phoneValue = this.phone
        let _ = spawn {
            try {
                let ok = getContactsService().addContact(uid, aHash, first, last, phoneValue)
                launch {
                    if (ok) { this.isContact = true }
                    this.showToastMsg(if (ok) { "Contact added" } else { "Could not add contact" })
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UserProfilePage] addContact error: ${e}")
                launch { this.showToastMsg("Could not add contact") }
            }
        }
    }

    /**
     * iOS PeerInfoScreen.swift:1815-1870 edit-mode Done：姓名变了走 updateContactName
     * （contacts.addContact），备注变了走 updateContactNote（contacts.updateContactNote#139f63fb）；
     * 两者都没变直接退出编辑；首尾名都为空不提交。
     */
    private func doSaveContact(): Unit {
        let uid = this.peerId
        let aHash = this.accessHash
        let first = this.editFirstName
        let last = this.editLastName
        let phoneValue = this.phone
        let wasAdd = this.editContactIsAdd
        let note = this.editNote
        let nameChanged = wasAdd || first != this.firstName || last != this.lastName
        let noteChanged = !wasAdd && note != this.contactNote
        if (!nameChanged && !noteChanged) {
            this.showEditContact = false
            return
        }
        if (first.size == 0 && last.size == 0) {
            this.showToastMsg("Please enter a name")
            return
        }
        let _ = spawn {
            var ok = true
            var noteOk = true
            try {
                if (nameChanged) {
                    ok = getContactsService().addContact(uid, aHash, first, last, phoneValue)
                }
                if (ok && noteChanged) {
                    noteOk = getContactsService().updateContactNote(uid, aHash, note)
                    if (noteOk) { getPeerInfoService().rememberContactNote(uid, note) }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UserProfilePage] updateContact error: ${e}")
                ok = false
            }
            let okFinal = ok
            let noteOkFinal = noteOk
            launch {
                if (okFinal) {
                    this.firstName = first
                    this.lastName = last
                    this.isContact = true
                    this.displayName = if (first.size > 0 && last.size > 0) { "${first} ${last}" } else if (last.size > 0) { last } else { first }
                    this.avatarLetter = if (this.displayName.size > 0) { this.displayName.toRuneArray()[0].toString() } else { "U" }
                    this.applyPeerDisplayName(uid, this.displayName)
                    if (noteOkFinal) { this.contactNote = note }
                    this.showEditContact = false
                }
                if (wasAdd) {
                    this.showToastMsg(if (okFinal) { "Contact added" } else { "Could not add contact" })
                } else {
                    this.showToastMsg(if (okFinal && noteOkFinal) { "Contact updated" } else { "Could not update contact" })
                }
            }
        }
    }

    // ==================== 联系人编辑页动作（iOS PeerInfoProfileItems.swift:1032-1110） ====================

    /** iOS EnginePeer.compactDisplayTitle：Set Photo for <first name>。 */
    private func contactCompactName(): String {
        return if (this.firstName.size > 0) { this.firstName } else if (this.lastName.size > 0) { this.lastName } else { this.displayName }
    }

    /** Set Photo / Suggest Photo：相册选图后先弹 iOS 同款确认（SetCustomPhotoTitle / SuggestPhotoTitle）。 */
    private func pickContactPhoto(suggest: Bool): Unit {
        if (this.contactPhotoBusy) { return }
        callArkAsync(PICK_PHOTO_ALBUM, "{}", { result =>
            if (!editProfileJsonBool(result, "ok")) { return }
            if (editProfileJsonString(result, "status") != "picked") { return }
            let paths = editProfileJsonStringArray(result, "paths")
            if (paths.isEmpty()) { return }
            let path = paths[0]
            launch {
                this.pendingContactPhotoPath = path
                this.pendingContactPhotoSuggest = suggest
                this.showContactPhotoConfirm = true
            }
        })
    }

    /** 确认后上传：photos.uploadContactProfilePhoto（save 或 suggest），成功后本地立即换头像。 */
    private func confirmContactPhoto(): Unit {
        let uid = this.peerId
        let aHash = this.accessHash
        let path = this.pendingContactPhotoPath
        let suggest = this.pendingContactPhotoSuggest
        let name = this.contactCompactName()
        this.showContactPhotoConfirm = false
        this.pendingContactPhotoPath = ""
        if (path.size == 0) { return }
        this.contactPhotoBusy = true
        let _ = spawn {
            var uri = ""
            try {
                uri = getContactPhotoService().uploadContactPhoto(uid, aHash, path, suggest)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UserProfilePage] contact photo upload error: ${e}")
            }
            let uriFinal = uri
            let ok = uriFinal.size > 0
            launch {
                this.contactPhotoBusy = false
                if (ok && !suggest) {
                    this.hasPersonalPhoto = true
                    this.avatarEmojiDocumentId = 0
                    this.avatarPhotoPath = uriFinal
                    this.headerFullPhotoPath = uriFinal
                    this.showToastMsg("You will now always see this photo for ${name}.")
                } else if (ok) {
                    this.showToastMsg("Photo suggested to ${name}.")
                } else {
                    this.showToastMsg(if (suggest) { "Could not suggest photo" } else { "Could not set photo" })
                }
            }
        }
    }

    /** iOS UserInfo.ResetCustomPhoto：uploadContactProfilePhoto(save, 无 file) 后回到对方自己的头像。 */
    private func doResetContactPhoto(): Unit {
        if (this.contactPhotoBusy) { return }
        let uid = this.peerId
        let aHash = this.accessHash
        this.contactPhotoBusy = true
        let _ = spawn {
            var ok = false
            try {
                ok = getContactPhotoService().resetContactPhoto(uid, aHash)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UserProfilePage] reset contact photo error: ${e}")
            }
            let okFinal = ok
            let path = if (okFinal) { getUserPhotoService().getUserPhotoPath(uid) } else { "" }
            launch {
                this.contactPhotoBusy = false
                if (okFinal) {
                    this.hasPersonalPhoto = false
                    this.avatarPhotoPath = path
                    this.headerFullPhotoPath = ""
                    this.loadAvatarMarkup()
                    this.loadHeaderFullPhoto()
                    this.showToastMsg("Photo reset to original")
                } else {
                    this.showToastMsg("Could not reset photo")
                }
            }
        }
    }

    /** iOS UserInfo.DeleteContact（ActionSheet 确认后 contacts.deleteContacts）。 */
    private func doDeleteContact(): Unit {
        let uid = this.peerId
        this.showDeleteContactConfirm = false
        let _ = spawn {
            var ok = false
            try {
                let ids = ArrayList<Int64>()
                ids.add(uid)
                ok = getContactsService().deleteContacts(ids)
                if (ok) { getPeerInfoService().rememberContactNote(uid, "") }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UserProfilePage] deleteContact error: ${e}")
            }
            let okFinal = ok
            launch {
                if (okFinal) {
                    this.isContact = false
                    this.contactNote = ""
                    this.showEditContact = false
                    this.showToastMsg("Contact deleted")
                } else {
                    this.showToastMsg("Could not delete contact")
                }
            }
        }
    }

    // ==================== 操作：复制文本到剪贴板 ====================

    /**
     * 长按行时写入系统剪贴板（通过 RealChatListService.setClipboardText）
     */
    private func doCopyText(text: String, toast: String): Unit {
        setClipboardText(text)
        this.showToastMsg(toast)
    }

    // ==================== 辅助 ====================

    // ==================== S226: Auto-Delete ====================

    /** messages.setHistoryTTL（与 PeerInfoPage.doSetAutoDelete 同源；period=0 关闭） */
    private func doSetAutoDelete(period: Int32): Unit {
        let pid = this.peerId
        let aHash = this.accessHash
        this.showAutoDeleteDialog = false
        this.showAutoDeleteCustom = false
        let _ = spawn {
            try {
                let svc = getPeersService()
                let result = svc.setHistoryTTL("user", pid, aHash, period)
                let msg = if (result.success) {
                    if (period == 0) { "Auto-delete disabled" } else { "Auto-delete set" }
                } else {
                    "Failed to set auto-delete"
                }
                launch { this.showToastMsg(msg) }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[UserProfilePage] doSetAutoDelete error: ${e}")
            }
        }
    }

    @Builder
    func autoDeleteOption(label: String, period: Int32) {
        Text(label)
            .fontSize(16)
            .fontColor(0x007AFF)
            .width(100.percent)
            .height(44)
            .textAlign(TextAlign.Center)
            .onClick({ _ => this.doSetAutoDelete(period) })
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
                    this.autoDeleteOption("Off", 0)
                    Divider().color(0xE5E5EA).strokeWidth(1)
                    this.autoDeleteOption("1 Day", 86400)
                    Divider().color(0xE5E5EA).strokeWidth(1)
                    this.autoDeleteOption("1 Week", 604800)
                    Divider().color(0xE5E5EA).strokeWidth(1)
                    this.autoDeleteOption("1 Month", 2678400)
                    Divider().color(0xE5E5EA).strokeWidth(1)
                    // iOS openCustomValue → ChatTimerScreen(mode: .autoremove)
                    Text("Set a Custom Time")
                        .fontSize(16)
                        .fontColor(0x007AFF)
                        .width(100.percent)
                        .height(44)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ =>
                            this.showAutoDeleteDialog = false
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
                    .onClick({ _ => this.showAutoDeleteDialog = false })
            }
            .width(85.percent)
            .padding(16)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.showAutoDeleteDialog = false })
    }

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
                    onCancel: { => this.showAutoDeleteCustom = false }
                )
            }
            .width(100.percent)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.End)
        .onClick({ _ => this.showAutoDeleteCustom = false })
    }

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

    // 头部 accent 背景色
    private func headerAccentColor(): UInt32 {
        if (this.isPremium) { return UInt32(0xFF6B4FBB) }
        if (this.isVerified) { return UInt32(0xFF1B72C5) }
        return UInt32(0xFF317AFF)
    }

    // blockConfirm 辅助（S-005：不能在 @Builder 内用 let）
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

    private func formattedPhone(): String {
        let runes = this.phone.toRuneArray()
        if (runes.size == 12 && runes[0].toString() == "4" && runes[1].toString() == "4") {
            var result = "+"
            var index: Int64 = 0
            while (index < Int64(runes.size)) {
                if (index == 2 || index == 4 || index == 8) { result = result + " " }
                result = result + runes[index].toString()
                index = index + 1
            }
            return result
        }
        return "+${this.phone}"
    }

    private func profileStatusText(user: UserResponse): String {
        if (user.isSelf || user.id == getCurrentUserId()) { return "online" }
        if (user.isSupport) { return "support" }
        if (user.isBot) {
            if (user.botSubscriberCount > 0) {
                return "${user.botSubscriberCount} monthly users"
            }
            return "bot"
        }
        if (user.statusType == "online") { return "online" }
        if (user.statusType == "recently") { return "last seen recently" }
        if (user.statusType == "lastWeek") { return "last seen within a week" }
        if (user.statusType == "lastMonth") { return "last seen within a month" }
        if (user.wasOnline > 0) {
            let seen = DateTime.fromUnixTimeStamp(Duration.second * Int64(user.wasOnline)).inLocal()
            let now = DateTime.now().inLocal()
            if (seen.year != now.year || seen.month != now.month || seen.dayOfMonth != now.dayOfMonth) {
                return "last seen yesterday at ${formatClockHHMM(Int64(user.wasOnline))}"
            }
            let relative = formatRelativeTime(Int64(user.wasOnline))
            return "last seen ${relative}"
        }
        return "last seen a long time ago"
    }

    private func canEditPeer(): Bool {
        return this.isContact && !this.isBot && !this.isSupport && !this.isSelf
    }

    private func callsAvailable(): Bool {
        return !this.isBot && !this.isSupport && !this.isSelf
    }

    /** iOS: profiles open with the round avatar (avatarInitiallyExpanded=false); the full-bleed header only after a tap. */
    private func showsExpandedHeader(): Bool {
        return !this.isSelf && this.avatarExpanded
    }

    private func profileHeaderHeight(): Float64 {
        return this.expandedHeaderHeight()
    }

    private func birthdayLabel(): String {
        return if (this.isBirthdayToday) { trSource("birthday today") } else { trSource("date of birth") }
    }

    // ==================== build() ====================

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Scroll(this.profileScroller) {
                Column {
                    if (this.showsExpandedHeader()) {
                        this.expandedProfileHeader()
                    } else {
                        this.compactProfileHeader()
                    }

                    if (this.isLoading) {
                        Column {
                            Text(trSource("Loading..."))
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .height(60)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .backgroundColor(0xF2F2F7)
                    } else {
                        // S8-21: .calls section sits above personalChannel / peerInfo (PeerInfoProfileItems.swift
                        // Section order; ItemListCallListItem.swift:224-360 fonts 15/14/14 medium, type at +75).
                        if (this.callListEntries.size > 0) {
                            Column {
                                Text(this.callListTitle)
                                    .fontSize(15)
                                    .fontColor(0xFF000000)
                                    .maxLines(1)
                                    .margin(bottom: 10)
                                ForEach(this.callListEntries.toArray(), itemGeneratorFunc: { e: ProfileCallEntry, _i: Int64 =>
                                    Row {
                                        Text(e.time)
                                            .fontSize(14)
                                            .fontColor(0xFF000000)
                                            .width(75)
                                        Text(e.typeText)
                                            .fontSize(14)
                                            .fontWeight(FontWeight.Medium)
                                            .fontColor(0xFF000000)
                                            .maxLines(1)
                                            .layoutWeight(1)
                                    }
                                    .width(100.percent)
                                    .margin(bottom: 12)
                                }, keyGeneratorFunc: { e: ProfileCallEntry, _i: Int64 => e.key })
                            }
                            .width(92.percent)
                            .alignItems(HorizontalAlign.Start)
                            .padding(left: 16, right: 16, top: 16, bottom: 8)
                            .backgroundColor(0xFFFFFF)
                            .margin(top: 19)
                            .borderRadius(24)
                        }
                        if (this.isSelf && this.selfPersonalChannelId != 0 && this.selfPersonalChannelTitle.size > 0) {
                            Text(trSource("CHANNEL"))
                                .fontSize(13)
                                .fontColor(0xFF8E8E93)
                                .width(92.percent)
                                .padding(left: 16)
                                .margin(top: 19, bottom: 6)
                            Row {
                                Text(this.selfPersonalChannelTitle)
                                    .fontSize(17)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFF000000)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .layoutWeight(1)
                            }
                            .width(92.percent)
                            .padding(left: 16, right: 16, top: 16, bottom: 16)
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(24)
                            .onClick({ _ =>
                                setSelectedChat(this.selfPersonalChannelId, this.selfPersonalChannelTitle, "channel")
                                routerPush("ChatRoomPage", this.selfPersonalChannelTitle)
                            })
                        }
                        Column {
                            if (this.phone.size > 0) {
                                this.infoRow(this.formattedPhone(), "mobile", "+${this.phone}")
                            }
                            if (this.username.size > 0) {
                                this.usernameRow()
                            }
                            if (this.birthdayText.size > 0) {
                                this.infoRow(this.birthdayText, this.birthdayLabel(), this.birthdayText)
                            }
                            if (this.bio.size > 0) {
                                this.bioRow()
                            }
                            if (!this.isSelf && this.contactNote.size > 0) {
                                this.noteRow()
                            }
                            if (this.isBot) {
                                this.botInfoRow()
                            }
                        }
                        .width(92.percent)
                        .backgroundColor(0xFFFFFF)
                        .margin(top: 19)
                        .borderRadius(24)

                        if (!this.isSelf && ((!this.isContact && !this.isSupport) || this.isBlocked || this.isBot)) {
                            Column {
                                if (!this.isContact && !this.isBot && !this.isSupport) {
                                    this.profileActionRow("Add to Contacts", false, { =>
                                        this.editFirstName = this.firstName
                                        this.editLastName = this.lastName
                                        this.editNote = ""
                                        this.editContactIsAdd = true
                                        this.showEditContact = true
                                    })
                                }
                                if (this.isBlocked) {
                                    this.profileActionRow(if (this.isBot) { "Restart Bot" } else { "Unblock" }, false, { => this.doToggleBlock() })
                                } else if (!this.isContact && !this.isBot && !this.isSupport) {
                                    this.profileActionRow("Block User", true, { => this.showBlockConfirm = true })
                                }
                                if (this.isBot) {
                                    this.profileActionRow("Report", false, { => this.showToastMsg("Report options are unavailable") })
                                }
                            }
                            .width(92.percent)
                            .backgroundColor(0xFFFFFFFF)
                            .margin(top: 16)
                            .borderRadius(24)
                        }

                        if (!this.isSelf) {
                            this.profileTabsSection()
                        }
                    }

                    if (this.isSelf) {
                        this.selfProfilePosts()
                    } else {
                        Blank().height(60)
                    }
                }
                .width(100.percent)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xF2F2F7)
            .padding(top: if (this.showsExpandedHeader()) { 0.0 } else { getSafeAreaTop() }, bottom: getSafeAreaBottom())
            .scrollBar(BarState.Off)

            // --------- 屏蔽确认对话框 ---------
            if (this.showBlockConfirm) {
                this.blockConfirmDialog()
            }

            // --------- S6-06：Start Secret Chat 确认框 ---------
            if (this.showSecretChatConfirm) {
                this.secretChatConfirmDialog()
            }

            // --------- 全屏头像查看器 ---------
            if (this.showAvatarViewer) {
                this.avatarViewerOverlay()
            }

            if (this.showMoreMenu) {
                Column {
                    Blank().layoutWeight(1)
                    Column {
                        // iOS PeerInfoScreenPerformButtonAction.swift 用户 more 菜单顺序：
                        // Change Wallpaper → Start Secret Chat → Share Contact → (Gift) → Auto-Delete → … → Block User
                        if (!this.isBot) {
                            // S6-05：UserInfo_ChangeWallpaper → 单会话壁纸（messages.setChatWallPaper）
                            Text(trSource("Change Wallpaper"))
                                .fontSize(17)
                                .fontColor(0x007AFF)
                                .height(52)
                                .width(100.percent)
                                .textAlign(TextAlign.Center)
                                .onClick({ _ =>
                                    this.showMoreMenu = false
                                    setPendingWallpaperPeer(this.peerId, "user", this.accessHash, this.displayName)
                                    routerPush("WallpaperPickerPage", "")
                                })
                            Divider().color(0xFFE5E5EA).strokeWidth(1)
                        }
                        if (!this.isBot && !this.isSupport && !this.isSelf) {
                            // S6-06：UserInfo_StartSecretChat → 确认后 messages.requestEncryption
                            Text(trSource("Start Secret Chat"))
                                .fontSize(17)
                                .fontColor(0x007AFF)
                                .height(52)
                                .width(100.percent)
                                .textAlign(TextAlign.Center)
                                .onClick({ _ =>
                                    this.showMoreMenu = false
                                    this.showSecretChatConfirm = true
                                })
                            Divider().color(0xFFE5E5EA).strokeWidth(1)
                        }
                        if (!this.isBot && this.isContact && this.phone.size > 0) {
                            // S6-07：Profile_ShareContactButton → ShareController(messageMediaContact)
                            Text(trSource("Share Contact"))
                                .fontSize(17)
                                .fontColor(0x007AFF)
                                .height(52)
                                .width(100.percent)
                                .textAlign(TextAlign.Center)
                                .onClick({ _ =>
                                    this.showMoreMenu = false
                                    this.openShareContact()
                                })
                            Divider().color(0xFFE5E5EA).strokeWidth(1)
                        }
                        Text(trSource("Shared Media"))
                            .fontSize(17)
                            .fontColor(0x007AFF)
                            .height(52)
                            .width(100.percent)
                            .textAlign(TextAlign.Center)
                            .onClick({ _ =>
                                this.showMoreMenu = false
                                routerPush("SharedMediaPage", "user:${this.peerId}")
                            })
                        Divider().color(0xFFE5E5EA).strokeWidth(1)
                        Text("Auto-Delete")
                            .fontSize(17)
                            .fontColor(0x007AFF)
                            .height(52)
                            .width(100.percent)
                            .textAlign(TextAlign.Center)
                            .onClick({ _ =>
                                this.showMoreMenu = false
                                this.showAutoDeleteDialog = true
                            })
                        Divider().color(0xFFE5E5EA).strokeWidth(1)
                        Text(if (this.isBlocked) { "Unblock User" } else { "Block User" })
                            .fontSize(17)
                            .fontColor(0xFFFF3B30)
                            .height(52)
                            .width(100.percent)
                            .textAlign(TextAlign.Center)
                            .onClick({ _ =>
                                this.showMoreMenu = false
                                this.showBlockConfirm = true
                            })
                    }
                    .width(92.percent)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(14)
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x007AFF)
                        .width(92.percent)
                        .height(54)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(14)
                        .margin(top: 8, bottom: 16)
                        .onClick({ _ => this.showMoreMenu = false })
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x55000000)
                .alignItems(HorizontalAlign.Center)
                .onClick({ _ => this.showMoreMenu = false })
            }

            if (this.showEditContact) {
                this.editContactDialog()
                if (this.showContactPhotoConfirm) {
                    this.contactPhotoConfirmDialog()
                }
                if (this.showDeleteContactConfirm) {
                    this.deleteContactConfirmDialog()
                }
            }

            if (this.showAutoDeleteDialog) {
                this.autoDeleteDialog()
            }
            if (this.showAutoDeleteCustom) {
                this.autoDeleteCustomSheet()
            }

            // --------- 长按复制菜单（Copy Username / Copy Bio） ---------
            if (this.showCopyMenu) {
                ContextMenuView(items: this.copyMenuItems, onDismiss: { => this.showCopyMenu = false },
                    bottomInset: getSafeAreaBottom())
            }

            // --------- 分享面板（username 行 → t.me 链接） ---------
            if (this.showShareSheet) {
                this.shareSheet()
            }

            // --------- Toast ---------
            if (this.showToast) { this.toastOverlay() }
        }
        .onAreaChange({ _: Area, newArea: Area => this.pageHeightVp = newArea.height.value })
        .onAppear({ =>
            this.ensureLoaded()
            this._backHandlerGeneration = registerUserProfileBackHandler({ => this.handleSystemBack() })
        })
        .onDisAppear({ => unregisterUserProfileBackHandler(this._backHandlerGeneration) })
    }

    // ==================== @Builder: 展开态头部（iOS isAvatarExpanded） ====================

    @Builder
    func expandedProfileHeader() {
        Stack(alignContent: Alignment.BottomStart) {
            if (this.avatarEmojiDocumentId != 0) {
                Column {
                    CustomEmojiImage(documentId: this.avatarEmojiDocumentId, size: 240.0, placeholder: "", autoplay: true)
                }
                .width(100.percent).height(this.profileHeaderHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .linearGradient(angle: 180.0, colors: [
                    (Color(this.avatarEmojiBackgroundStart), 0.0),
                    (Color(this.avatarEmojiBackgroundEnd), 1.0)
                ])
                .onClick({ _ => this.showAvatarViewer = true })
            } else if (this.headerFullPhotoPath.size > 0 || this.avatarPhotoPath.size > 0) {
                Image(if (this.headerFullPhotoPath.size > 0) { this.headerFullPhotoPath } else { this.avatarPhotoPath })
                    .width(100.percent)
                    .height(this.profileHeaderHeight())
                    .objectFit(ImageFit.Cover)
                    .onClick({ _ => this.showAvatarViewer = true })
            } else {
                Column {
                    Text(this.avatarLetter)
                        .fontSize(96)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xCCFFFFFF)
                }
                .width(100.percent)
                .height(this.profileHeaderHeight())
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(this.headerAccentColor())
            }

            Column {
                Row {
                    Column {
                        Image(@r(app.media.nav_back_arrow_legacy))
                            .width(12)
                            .height(20)
                            .fillColor(0xFFFFFFFF)
                    }
                        .width(44)
                        .height(44)
                        .backgroundColor(0x663C3C43)
                        .borderRadius(22)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .onClick({ _ => this.avatarExpanded = false })
                    Blank().layoutWeight(1)
                    if (this.canEditPeer()) {
                        Column {
                            Text(trSource("Edit"))
                                .fontSize(17)
                                .fontWeight(FontWeight.Bold)
                                .fontColor(0xFFFFFFFF)
                        }
                            .height(44)
                            .padding(left: 14, right: 14)
                            .backgroundColor(0x663C3C43)
                            .borderRadius(22)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .onClick({ _ =>
                                this.editFirstName = this.firstName
                                this.editLastName = this.lastName
                                this.editNote = this.contactNote
                                this.editContactIsAdd = false
                                this.showEditContact = true
                            })
                    }
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 40)

                Blank().layoutWeight(1)

                Column {
                    Text(this.displayName)
                        .fontSize(25)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFFFFFF)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                    if (this.statusText.size > 0) {
                        Text(this.statusText)
                            .fontSize(15)
                            .fontColor(0xE6FFFFFF)
                            .margin(top: 2)
                    }
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Start)
                .padding(left: 16, right: 16)

                Row {
                    if (this.callsAvailable()) {
                        this.quickActionBtn("call", { =>
                            let _ = getCallService().requestCall(this.peerId, this.accessHash, this.displayName, false)
                            routerPush("CallScreen", "outgoing")
                        })
                        this.quickActionBtn("video", { =>
                            let _ = getCallService().requestCall(this.peerId, this.accessHash, this.displayName, true)
                            routerPush("VideoCallScreen", "outgoing")
                        })
                    }
                    this.muteQuickActionBtn({ => this.doToggleMute() })
                    this.quickActionBtn("search", { =>
                        requestChatSearchOnReturn()
                        routerPop()
                    })
                    if (this.isBot && !this.isBlocked) {
                        this.quickActionBtn("stop", { => this.doToggleBlock() })
                    }
                    if (!this.isSupport) {
                        this.quickActionBtn("more", { => this.showMoreMenu = true })
                    }
                }
                .width(100.percent)
                .padding(left: 11, right: 11, top: 12, bottom: 16)
                .justifyContent(FlexAlign.SpaceBetween)
            }
            .width(100.percent)
            .height(this.profileHeaderHeight())
        }
        .width(100.percent)
        .height(this.profileHeaderHeight())
        .onAreaChange({ _: Area, newArea: Area =>
            if (newArea.width.value > 0.0) { this.headerWidthVp = newArea.width.value }
        })
    }

    // ==================== @Builder: 分享面板（iOS ShareController: 链接 + Copy Link） ====================

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

    // ==================== @Builder: 页签条（iOS PeerInfoPaneContainerNode：Media/Files/Links/Voice/Audio/GIFs/Groups） ====================

    @Builder
    func profileTabPill(label: String, key: String, action: () -> Unit) {
        Text(label)
            .fontSize(13)
            .fontWeight(if (this.selectedProfileTab == key) { FontWeight.Medium } else { FontWeight.Normal })
            .fontColor(0xFF000000)
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(36)
            .borderRadius(18)
            .backgroundColor(if (this.selectedProfileTab == key) { 0xFFE5E5EA } else { Color.Transparent })
            .onClick({ _ => action() })
    }

    @Builder
    func profileTabsSection() {
        Column {
            Row {
                this.profileTabPill(trSource("Media"), "media", { => this.openSharedMediaTab(0) })
                this.profileTabPill(trSource("Files"), "files", { => this.openSharedMediaTab(1) })
                this.profileTabPill(trSource("Links"), "links", { => this.openSharedMediaTab(2) })
                this.profileTabPill(trSource("Voice"), "voice", { => this.openSharedMediaTab(3) })
                this.profileTabPill(trSource("Audio"), "audio", { => this.openSharedMediaTab(4) })
                this.profileTabPill(trSource("GIFs"), "gifs", { => this.openSharedMediaTab(5) })
                if (this.commonGroups.size > 0) {
                    this.profileTabPill(trSource("Groups"), "groups", { => this.selectedProfileTab = "groups" })
                }
            }
            .width(100.percent)
            .padding(4)
            .backgroundColor(0xFFFFFFFF)
            .borderRadius(22)

            if (this.selectedProfileTab == "groups") {
                Column {
                    ForEach(this.commonGroups.toArray(), itemGeneratorFunc: { chat: ChatResponse, _i: Int64 =>
                        this.commonGroupRow(chat)
                    }, keyGeneratorFunc: { chat: ChatResponse, _i: Int64 => "common_${chat.id}" })
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(14)
                .margin(top: 12)
                .clip(true)
            }
        }
        .width(92.percent)
        .margin(top: 16)
    }

    @Builder
    func commonGroupRow(chat: ChatResponse) {
        Row {
            Avatar(
                avatarUrl: getUserPhotoService().getChatPhotoPath(chat.id),
                displayName: chat.title,
                avatarSize: 40,
                peerId: chat.id
            )
            Column {
                Text(chat.title)
                    .fontSize(17)
                    .fontColor(0xFF000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Text(this.commonGroupSubtitle(chat))
                    .fontSize(14)
                    .fontColor(0xFF8E8E93)
                    .margin(top: 2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.openCommonGroup(chat) })
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

    // ==================== @Builder: 快捷按钮 ====================

    @Builder
    func quickActionBtn(label: String, action: () -> Unit) {
        Column {
            if (label == "call") {
                Image(@r(app.media.chatroom_ic_call)).width(30).height(30).fillColor(0xFFFFFFFF).margin(top: 5, bottom: 5)
            } else if (label == "video") {
                Stack {
                    Image(@r(app.media.chatroom_ic_videocall)).width(30).height(30).fillColor(0xFFFFFFFF)
                }
                .width(40)
                .height(40)
            } else if (label == "mute" || label == "unmute") {
                Stack {
                    if (label == "unmute") {
                        ProfileMuteIcon(muted: true, blue: false, autoplay: this.muteAnimationSerial > 0)
                    } else {
                        ProfileMuteIcon(muted: false, blue: false, autoplay: this.muteAnimationSerial > 0)
                    }
                }
                .width(40)
                .height(40)
            } else if (label == "search") {
                Image(@r(app.media.chatroom_ic_search)).width(30).height(30).fillColor(0xFFFFFFFF).margin(top: 5, bottom: 5)
            } else if (label == "stop") {
                Stack {
                    Text("■")
                        .fontSize(18)
                        .fontColor(0xFFFFFFFF)
                }
                .width(40)
                .height(40)
            } else {
                Row {
                    Circle().width(6).height(6).fill(0xFFFFFFFF)
                    Blank().width(2)
                    Circle().width(6).height(6).fill(0xFFFFFFFF)
                    Blank().width(2)
                    Circle().width(6).height(6).fill(0xFFFFFFFF)
                }
                .width(40)
                .height(40)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
            }
            Text(label)
                .fontSize(11)
                .fontColor(0xFFFFFFFF)
                .textAlign(TextAlign.Center)
                .maxLines(1)
                .margin(top: -3)
        }
        // 五个动作胶囊等宽铺满一行（对位 iOS）。
        .layoutWeight(1)
        .margin(left: 5, right: 5)
        .height(58)
        .borderRadius(12)
        .backgroundColor(0x33FFFFFF)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => action() })
    }

    private func quickActionWidth(): Int64 {
        if (this.isSupport) { return 160 }
        if (this.isBot) {
            return if (this.isBlocked) { 104 } else { 76 }
        }
        return 60
    }

    @Builder
    func muteQuickActionBtn(action: () -> Unit) {
        Column {
            if (this.isMuted) {
                ProfileMuteIcon(muted: true, blue: false, autoplay: this.muteAnimationSerial > 0)
            } else {
                ProfileMuteIcon(muted: false, blue: false, autoplay: this.muteAnimationSerial > 0)
            }
            if (this.isMuted) {
                Text("unmute")
                    .fontSize(11)
                    .fontColor(0xFFFFFFFF)
                    .textAlign(TextAlign.Center)
                    .margin(top: -3)
            } else {
                Text(trSource("mute"))
                    .fontSize(11)
                    .fontColor(0xFFFFFFFF)
                    .textAlign(TextAlign.Center)
                    .margin(top: -3)
            }
        }
        // 五个动作胶囊等宽铺满一行（对位 iOS）。
        .layoutWeight(1)
        .margin(left: 5, right: 5)
        .height(58)
        .borderRadius(12)
        .backgroundColor(0x33FFFFFF)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => action() })
    }

    @Builder
    func compactProfileHeader() {
        Column {
            Row {
                Column {
                    Image(@r(app.media.nav_back_arrow_legacy))
                        .width(12)
                        .height(20)
                        .fillColor(0xFF000000)
                }
                    .width(44)
                    .height(44)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(22)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                if (this.isSelf) {
                    Row {
                        Image(@r(app.media.settings_ic_qr))
                            .width(24)
                            .height(24)
                            .fillColor(0xFF000000)
                            .margin(left: 12, right: 10)
                            .onClick({ _ => routerPush("ChatQrCodeSharePage", "") })
                        Divider()
                            .vertical(true)
                            .height(24)
                            .color(0xFFE5E5EA)
                        Text(trSource("Edit"))
                            .fontSize(17)
                            .fontColor(0xFF000000)
                            .height(44)
                            .padding(left: 12, right: 14)
                            .textAlign(TextAlign.Center)
                            .onClick({ _ => routerPush("EditProfilePage", "") })
                    }
                    .height(44)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(22)
                    .alignItems(VerticalAlign.Center)
                } else if (this.canEditPeer()) {
                    Column {
                        Text(trSource("Edit"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0xFF000000)
                    }
                        .height(44)
                        .padding(left: 16, right: 16)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(22)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .onClick({ _ =>
                            this.editFirstName = this.firstName
                            this.editLastName = this.lastName
                            this.editNote = this.contactNote
                            this.editContactIsAdd = false
                            this.showEditContact = true
                        })
                }
            }
            .width(92.percent)
            .padding(top: 8)

            // 头像 + 名字 + 状态：iOS 点头像展开为顶部大图（S6-01）；本人资料保持原有查看器
            Column {
                if (this.avatarPhotoPath.size > 0) {
                    if (this.avatarEmojiDocumentId != 0) {
                        Column {
                            CustomEmojiImage(documentId: this.avatarEmojiDocumentId, size: 68.0, placeholder: "", autoplay: true)
                        }
                        .width(100).height(100).borderRadius(50).clip(true)
                        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                        .linearGradient(angle: 180.0, colors: [
                            (Color(this.avatarEmojiBackgroundStart), 0.0),
                            (Color(this.avatarEmojiBackgroundEnd), 1.0)
                        ])
                    } else {
                        Image(this.avatarPhotoPath)
                            .width(100)
                            .height(100)
                            .objectFit(ImageFit.Cover)
                            .borderRadius(50)
                    }
                } else {
                    Text(this.avatarLetter)
                        .fontSize(48)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFFFFFF)
                        .width(100)
                        .height(100)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(this.headerAccentColor())
                        .borderRadius(50)
                }

                Text(this.displayName)
                    .fontSize(25)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                    .margin(top: 12)
                if (this.statusText.size > 0) {
                    Text(this.statusText)
                        .fontSize(15)
                        .fontColor(0xFF8E8E93)
                        .margin(top: 2)
                }
            }
            .width(100.percent)
            .alignItems(HorizontalAlign.Center)
            .margin(top: 4)
            .onClick({ _ =>
                if (this.isSelf) {
                    if (this.avatarPhotoPath.size > 0) { this.showAvatarViewer = true }
                } else {
                    this.avatarExpanded = true
                }
            })

            if (!this.isSelf) {
                Row {
                    if (this.callsAvailable()) {
                        this.collapsedQuickActionBtn("call", { =>
                            let _ = getCallService().requestCall(this.peerId, this.accessHash, this.displayName, false)
                            routerPush("CallScreen", "outgoing")
                        })
                        this.collapsedQuickActionBtn("video", { =>
                            let _ = getCallService().requestCall(this.peerId, this.accessHash, this.displayName, true)
                            routerPush("VideoCallScreen", "outgoing")
                        })
                    }
                    this.collapsedMuteQuickActionBtn({ => this.doToggleMute() })
                    this.collapsedQuickActionBtn("search", { =>
                        requestChatSearchOnReturn()
                        routerPop()
                    })
                    if (!this.isSupport) {
                        this.collapsedQuickActionBtn("more", { => this.showMoreMenu = true })
                    }
                }
                .width(100.percent)
                .padding(left: 11, right: 11, top: 23)
                .justifyContent(FlexAlign.SpaceBetween)
            }
        }
        .width(100.percent)
        .backgroundColor(0xFFF2F2F7)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func collapsedQuickActionBtn(label: String, action: () -> Unit) {
        Column {
            if (label == "call") {
                Image(@r(app.media.chatroom_ic_call)).width(30).height(30).fillColor(0xFF007AFF).margin(top: 5, bottom: 5)
            } else if (label == "video") {
                Image(@r(app.media.chatroom_ic_videocall)).width(30).height(30).fillColor(0xFF007AFF)
                    .margin(top: 5, bottom: 5)
            } else if (label == "mute" || label == "unmute") {
                if (label == "unmute") {
                    ProfileMuteIcon(muted: true, blue: true, autoplay: this.muteAnimationSerial > 0)
                } else {
                    ProfileMuteIcon(muted: false, blue: true, autoplay: this.muteAnimationSerial > 0)
                }
            } else if (label == "search") {
                Image(@r(app.media.chatroom_ic_search)).width(30).height(30).fillColor(0xFF007AFF).margin(top: 5, bottom: 5)
            } else {
                Row {
                    Circle().width(5).height(5).fill(0xFF007AFF)
                    Blank().width(4)
                    Circle().width(5).height(5).fill(0xFF007AFF)
                    Blank().width(4)
                    Circle().width(5).height(5).fill(0xFF007AFF)
                }
                .width(40)
                .height(40)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
            }
            Text(label)
                .fontSize(11)
                .fontColor(0xFF007AFF)
                .textAlign(TextAlign.Center)
                .margin(top: -3)
        }
        .layoutWeight(1)
        .margin(left: 5, right: 5)
        .height(58)
        .borderRadius(16)
        .backgroundColor(0xFFFFFFFF)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => action() })
    }

    @Builder
    func collapsedMuteQuickActionBtn(action: () -> Unit) {
        Column {
            if (this.isMuted) {
                ProfileMuteIcon(muted: true, blue: true, autoplay: this.muteAnimationSerial > 0)
            } else {
                ProfileMuteIcon(muted: false, blue: true, autoplay: this.muteAnimationSerial > 0)
            }
            if (this.isMuted) {
                Text("unmute")
                    .fontSize(11)
                    .fontColor(0xFF007AFF)
                    .textAlign(TextAlign.Center)
                    .margin(top: -3)
            } else {
                Text(trSource("mute"))
                    .fontSize(11)
                    .fontColor(0xFF007AFF)
                    .textAlign(TextAlign.Center)
                    .margin(top: -3)
            }
        }
        .layoutWeight(1)
        .margin(left: 5, right: 5)
        .height(58)
        .borderRadius(16)
        .backgroundColor(0xFFFFFFFF)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => action() })
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

    // ==================== @Builder: 联系人编辑页（iOS PeerInfo edit mode） ====================

    /**
     * 对位 iOS PeerInfoScreen 联系人 edit mode（PeerInfoProfileItems.swift:1032-1110）：
     * 头像 → First/Last Name 组 → Add Notes（footer PeerInfo.AddNotesInfo）→
     * Suggest Photo for X / Set|Change Photo for X / Reset to Original Photo（footer UserInfo.CustomPhotoInfo）
     * → Delete Contact。导航栏 Cancel / Done 为 iOS 的圆角 pill 按钮。
     */
    @Builder
    func editContactDialog() {
        Column {
            Row {
                Text(trSource("Cancel"))
                    .fontSize(17)
                    .fontColor(0xFF007AFF)
                    .height(40)
                    .padding(left: 16, right: 16)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(20)
                    .onClick({ _ => this.showEditContact = false })
                Blank().layoutWeight(1)
                Text(if (this.editContactIsAdd) { "Add Contact" } else { "Edit Contact" })
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF000000)
                Blank().layoutWeight(1)
                Text(trSource("Done"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF007AFF)
                    .height(40)
                    .padding(left: 16, right: 16)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(20)
                    .onClick({ _ => this.doSaveContact() })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 8, bottom: 8)
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    if (this.avatarPhotoPath.size > 0 && this.avatarEmojiDocumentId == 0) {
                        Image(this.avatarPhotoPath)
                            .width(100)
                            .height(100)
                            .objectFit(ImageFit.Cover)
                            .borderRadius(50)
                    } else {
                        Text(this.avatarLetter)
                            .fontSize(48)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0xFFFFFFFF)
                            .width(100)
                            .height(100)
                            .textAlign(TextAlign.Center)
                            .backgroundColor(this.headerAccentColor())
                            .borderRadius(50)
                    }

                    Column {
                        TextInput(text: this.editFirstName, placeholder: trSource("First Name"))
                            .width(100.percent)
                            .height(50)
                            .fontSize(17)
                            .fontColor(0xFF000000)
                            .backgroundColor(Color.Transparent)
                            .padding(left: 16, right: 16)
                            .onChange({ value: String => this.editFirstName = value })
                        Divider().color(0xFFE5E5EA).strokeWidth(1).margin(left: 16)
                        TextInput(text: this.editLastName, placeholder: trSource("Last Name"))
                            .width(100.percent)
                            .height(50)
                            .fontSize(17)
                            .fontColor(0xFF000000)
                            .backgroundColor(Color.Transparent)
                            .padding(left: 16, right: 16)
                            .onChange({ value: String => this.editLastName = value })
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(14)
                    .margin(top: 20)

                    if (!this.editContactIsAdd) {
                        Column {
                            TextArea(text: this.editNote, placeholder: "Add Notes")
                                .width(100.percent)
                                .fontSize(17)
                                .fontColor(0xFF000000)
                                .placeholderColor(0xFFC8C8CE)
                                .backgroundColor(Color.Transparent)
                                .padding(left: 16, right: 16, top: 14, bottom: 14)
                                .onChange({ value: String => this.editNote = value })
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(14)
                        .margin(top: 36)
                        Text("Notes are only visible to you.")
                            .fontSize(13)
                            .fontColor(0xFF8E8E93)
                            .width(100.percent)
                            .textAlign(TextAlign.Start)
                            .padding(left: 16, right: 16, top: 6)

                        Column {
                            this.editContactActionRow("Suggest Photo for ${this.contactCompactName()}", "suggest", { => this.pickContactPhoto(true) })
                            Divider().color(0xFFE5E5EA).strokeWidth(1).margin(left: 60)
                            this.editContactActionRow(
                                if (this.hasPersonalPhoto) { "Change Photo for ${this.contactCompactName()}" } else { "Set Photo for ${this.contactCompactName()}" },
                                "camera", { => this.pickContactPhoto(false) })
                            if (this.hasPersonalPhoto) {
                                Divider().color(0xFFE5E5EA).strokeWidth(1).margin(left: 60)
                                this.editContactActionRow("Reset to Original Photo", "reset", { => this.doResetContactPhoto() })
                            }
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(14)
                        .margin(top: 28)
                        Text("You can replace ${this.contactCompactName()}'s photo with another photo that only you will see.")
                            .fontSize(13)
                            .fontColor(0xFF8E8E93)
                            .width(100.percent)
                            .textAlign(TextAlign.Start)
                            .padding(left: 16, right: 16, top: 6)

                        Column {
                            Text("Delete Contact")
                                .fontSize(17)
                                .fontColor(0xFFFF3B30)
                                .width(100.percent)
                                .height(52)
                                .padding(left: 16, right: 16)
                                .textAlign(TextAlign.Start)
                                .onClick({ _ => this.showDeleteContactConfirm = true })
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(14)
                        .margin(top: 28)
                    }

                    if (this.contactPhotoBusy) {
                        Text("Uploading photo...")
                            .fontSize(13)
                            .fontColor(0xFF8E8E93)
                            .margin(top: 16)
                    }
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 12, bottom: 40)
                .alignItems(HorizontalAlign.Center)
            }
            .width(100.percent)
            .layoutWeight(1)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFEFEFF4)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
    }

    /** iOS PeerInfoScreenActionItem（accent 文案 + 左侧图标）。 */
    @Builder
    func editContactActionRow(title: String, iconKey: String, action: () -> Unit) {
        Row {
            if (iconKey == "camera") {
                Image(@r(app.media.editprofile_ic_camera))
                    .width(26)
                    .height(26)
                    .fillColor(0xFF007AFF)
            } else if (iconKey == "suggest") {
                Image(@r(app.media.settings_ic_photo))
                    .width(26)
                    .height(26)
                    .fillColor(0xFF007AFF)
            } else if (this.avatarPhotoPath.size > 0) {
                Image(this.avatarPhotoPath)
                    .width(26)
                    .height(26)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(13)
            } else {
                Blank().width(26).height(26)
            }
            Text(title)
                .fontSize(17)
                .fontColor(0xFF007AFF)
                .layoutWeight(1)
                .margin(left: 18)
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
        }
        .width(100.percent)
        .height(52)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => action() })
    }

    /** iOS UserInfo.SetCustomPhotoTitle / SuggestPhotoTitle 确认弹窗（Set / Suggest）。 */
    @Builder
    func contactPhotoConfirmDialog() {
        Column {
            Column {
                Text(if (this.pendingContactPhotoSuggest) {
                    "Do you want to suggest a profile picture for ${this.contactCompactName()}?"
                } else {
                    "Do you want to set a custom profile picture for ${this.contactCompactName()}?"
                })
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 8)
                Text(if (this.pendingContactPhotoSuggest) {
                    "Do you want to suggest ${this.contactCompactName()} to set this photo for their profile?"
                } else {
                    "Do you want to set this photo for ${this.contactCompactName()}? It will replace any photo ${this.contactCompactName()} sets, but only you will see it."
                })
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
                        .onClick({ _ =>
                            this.showContactPhotoConfirm = false
                            this.pendingContactPhotoPath = ""
                        })
                    Text(if (this.pendingContactPhotoSuggest) { "Suggest" } else { "Set" })
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFF007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.confirmContactPhoto() })
                }
                .width(100.percent)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFFFF)
            .borderRadius(14)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    /** iOS UserInfo.DeleteContact ActionSheet 确认。 */
    @Builder
    func deleteContactConfirmDialog() {
        Column {
            Column {
                Text("Delete Contact")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 8)
                Text("Are you sure you want to delete ${this.displayName} from your contacts?")
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
                        .onClick({ _ => this.showDeleteContactConfirm = false })
                    Text("Delete")
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFF3B30)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.doDeleteContact() })
                }
                .width(100.percent)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFFFF)
            .borderRadius(14)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    // ==================== @Builder: 信息行（通用，长按复制）====================

    @Builder
    func infoRow(rowValue: String, rowLabel: String, rowCopyValue: String) {
        // 信息行：标签（次级灰）在上，值（强调色）在下。
        Row {
            Column {
                Text(rowLabel)
                    .fontSize(14)
                    .fontColor(0xFF8E8E93)
                Text(rowValue)
                    .fontSize(17)
                    .fontColor(0xFF007AFF)
                    .maxLines(1)
                    .margin(top: 3)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 16, bottom: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ =>
            if (rowLabel == "mobile") {
                this.doCopyText(rowCopyValue, "Phone copied to clipboard")
            } else {
                this.doCopyText(rowCopyValue, "Birthday copied to clipboard.")
            }
        })
    }

    // ==================== @Builder: username 行 ====================

    @Builder
    func usernameRow() {
        if (this.isSelf) {
            Column {
                Divider()
                    .color(0xFFE5E5EA)
                    .strokeWidth(1)
                    .margin(left: 16)
                Row {
                    Column {
                        Text(trSource("username"))
                            .fontSize(14)
                            .fontColor(0xFF111111)
                        Text("@${this.username}")
                            .fontSize(18)
                            .fontColor(0xFF007AFF)
                            .maxLines(1)
                            .margin(top: 4)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    .onClick({ _ => this.doCopyText("@${this.username}", "Username copied to clipboard") })

                    Image(@r(app.media.settings_ic_qr))
                        .width(28)
                        .height(28)
                        .fillColor(0xFF007AFF)
                        .onClick({ _ => routerPush("ChatQrCodeSharePage", "") })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 14, bottom: 14)
                .alignItems(VerticalAlign.Center)
            }
            .width(100.percent)
        } else {
            Row {
                Column {
                    Text(trSource("username"))
                        .fontSize(14)
                        .fontColor(0xFF8E8E93)
                    Text("@${this.username}")
                        .fontSize(17)
                        .fontColor(0xFF007AFF)
                        .maxLines(1)
                        .margin(top: 3)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 14, bottom: 14)
            .alignItems(VerticalAlign.Center)
            // iOS PeerInfoScreen ItemUsername: tap → ShareController(t.me 链接)；长按 → Copy Username
            .onClick({ _ =>
                if (this.consumeSuppressedClick()) { return }
                this.openShareSheet("https://t.me/${this.username}")
            })
            .onTouch({ evt =>
                match (evt.eventType) {
                    case TouchType.Down =>
                        if (evt.touches.size > 0) {
                            this.beginRowPress(evt.touches[0].x, evt.touches[0].y, { =>
                                triggerHaptic("impact", "light")
                                this.openCopyMenu("Copy Username", "@${this.username}", "Username copied to clipboard")
                            })
                        }
                    case TouchType.Move =>
                        if (evt.touches.size > 0) { this.moveRowPress(evt.touches[0].x, evt.touches[0].y) }
                    case _ => this.endRowPress()
                }
            })
        }
    }

    @Builder
    func selfProfilePosts() {
        Column {
            Text(trSource("Posts"))
                .fontSize(17)
                .fontColor(0xFF111111)
                .padding(left: 18, right: 18, top: 8, bottom: 8)
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(20)

            Row {
                Text(trSource("All Stories"))
                    .fontSize(16)
                    .fontColor(0xFF111111)
                    .padding(left: 14, right: 14, top: 8, bottom: 8)
                    .backgroundColor(0xFFE5E5EA)
                    .borderRadius(20)
                Text(trSource("+ Add Album"))
                    .fontSize(16)
                    .fontColor(0xFF111111)
                    .padding(left: 14, right: 14, top: 8, bottom: 8)
            }
            .margin(top: 18)
            .alignItems(VerticalAlign.Center)

            Image(@r(app.media.story_list_empty))
                .width(128)
                .height(128)
                .objectFit(ImageFit.Contain)
                .margin(top: 20)
            Text(trSource("No posts yet..."))
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFF111111)
                .margin(top: 12)
            Text("Publish photos and videos to\ndisplay on your profile page.")
                .fontSize(16)
                .fontColor(0xFF8E8E93)
                .textAlign(TextAlign.Center)
                .margin(top: 12)
            Text(trSource("Add a Post"))
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor(0xFFFFFFFF)
                .width(64.percent)
                .height(50)
                .textAlign(TextAlign.Center)
                .backgroundColor(0xFF007AFF)
                .borderRadius(12)
                .margin(top: 22, bottom: 40)
                .onClick({ _ => routerPush("CameraPage", "") })
        }
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
        .margin(top: 18)
    }

    // ==================== @Builder: Bio 行 ====================

    @Builder
    func bioRow() {
        // iOS ItemAbout：标签 Profile.About = "bio"；长按 → Copy Bio → MyProfile.ToastBioCopied
        Row {
            Column {
                Text(trSource("bio"))
                    .fontSize(14)
                    .fontColor(0xFF8E8E93)
                Text(this.bio)
                    .fontSize(17)
                    .fontColor(0xFF000000)
                    .maxLines(8)
                    .margin(top: 3)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 14, bottom: 14)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ =>
            if (this.consumeSuppressedClick()) { return }
        })
        .onTouch({ evt =>
            match (evt.eventType) {
                case TouchType.Down =>
                    if (evt.touches.size > 0) {
                        this.beginRowPress(evt.touches[0].x, evt.touches[0].y, { =>
                            triggerHaptic("impact", "light")
                            this.openCopyMenu("Copy Bio", this.bio, "Bio copied to clipboard.")
                        })
                    }
                case TouchType.Move =>
                    if (evt.touches.size > 0) { this.moveRowPress(evt.touches[0].x, evt.touches[0].y) }
                case _ => this.endRowPress()
            }
        })
    }

    // ==================== @Builder: 联系人备注行（S6-27 / iOS S6-16） ====================

    /**
     * iOS ItemNote（PeerInfoProfileItems.swift:298-303，PeerInfoScreenLabeledValueItem）：
     * label PeerInfo.Notes = "notes"，rightLabel PeerInfo.NotesInfo = "only visible to you"，正文多行。
     */
    @Builder
    func noteRow() {
        Row {
            Column {
                Row {
                    Text(trSource("notes"))
                        .fontSize(14)
                        .fontColor(0xFF8E8E93)
                    Blank().layoutWeight(1)
                    Text(trSource("only visible to you"))
                        .fontSize(14)
                        .fontColor(0xFF8E8E93)
                }
                .width(100.percent)
                Text(this.contactNote)
                    .fontSize(17)
                    .fontColor(0xFF000000)
                    .maxLines(100)
                    .margin(top: 3)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 14, bottom: 14)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.doCopyText(this.contactNote, "Note copied to clipboard.") })
    }

    // ==================== @Builder: Bot 信息行 ====================

    @Builder
    func botInfoRow() {
        Row {
            Column {
                Text(trSource("Bot"))
                    .fontSize(16)
                    .fontColor(0x000000)
                Text("This account is a bot")
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(top: 2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 14, bottom: 14)
        .alignItems(VerticalAlign.Center)
    }

    // ==================== @Builder: 屏蔽确认对话框 ====================

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
                    .textAlign(TextAlign.Center)
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
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.showBlockConfirm = false })
    }

    // ==================== @Builder: 全屏头像查看器 ====================

    @Builder
    func avatarViewerOverlay() {
        Column {
            Row {
                Text("X")
                    .fontSize(20)
                    .fontColor(0xFFFFFF)
                    .padding(8)
                    .onClick({ _ => this.showAvatarViewer = false })
                Text(this.displayName)
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFFFFFF)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                Text(trSource(" "))
                    .fontSize(20)
                    .width(36)
            }
            .width(100.percent)
            .padding(left: 8, right: 8, top: 48, bottom: 12)

            Column {
                if (this.avatarPhotoPath.size > 0) {
                    if (this.avatarEmojiDocumentId != 0) {
                        Column {
                            CustomEmojiImage(documentId: this.avatarEmojiDocumentId, size: 280.0, placeholder: "", autoplay: true)
                        }
                        .width(100.percent).height(100.percent)
                        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                        .linearGradient(angle: 180.0, colors: [
                            (Color(this.avatarEmojiBackgroundStart), 0.0),
                            (Color(this.avatarEmojiBackgroundEnd), 1.0)
                        ])
                    } else {
                        Image(this.avatarPhotoPath)
                            .width(100.percent)
                            .objectFit(ImageFit.Contain)
                    }
                } else {
                    Column {
                        Text(this.avatarLetter)
                            .fontSize(80)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0xFFFFFF)
                    }
                    .width(180)
                    .height(180)
                    .borderRadius(90)
                    .backgroundColor(this.headerAccentColor())
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                }
            }
            .layoutWeight(1)
            .width(100.percent)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFF000000)
        .onClick({ _ => this.showAvatarViewer = false })
    }
}
