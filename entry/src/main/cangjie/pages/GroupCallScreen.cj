package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashSet}
import std.convert.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.copyText
import ohos_app_cangjie_entry.core.storage.trSource
import ohos_app_cangjie_entry.interop.{callArkOnJSTask, subscribe, GROUP_CALL_UPDATE, EVT_GROUP_CALL_ACTION}

/**
 * GroupCallScreen — 群 Video Chat 页的数据层（对位 iOS VideoChatScreenV2Impl，
 * submodules/TelegramCallsUI/Sources/VideoChatScreen.swift）。
 *
 * UI 全部在 ArkTS（ets/pages/GroupCallScreen.ets）；本组件只做三件事：
 *   1. 解析路由参数 "callId:accessHash:title[:peerType:peerId:canManage]"
 *   2. 把 GroupCallSession 的状态序列化后 callArk(GROUP_CALL_UPDATE) 推给 ArkTS
 *   3. 接 ArkTS 的动作（join / toggleMute / leave / end / minimize / 成员菜单…）
 *
 * 通话本身由 GroupCallSession 持有——关掉本页（minimize）通话不断。
 * 注意：callId 是随机 int64，可能为负且超出 JS 安全整数，不进 JSON。
 */

/** 邀请面板里的一行（iOS ChannelMembersSearchController mode:.inviteToCall 的一个 peer）。 */
public class GroupCallInviteCandidate {
    public var userId: Int64 = 0
    public var accessHash: Int64 = 0
    public var name: String = ""
    public var isMember: Bool = false   // 已在本群：点了直接邀请；否则先问要不要拉进群
    public var invited: Bool = false
}

// 通话页是否正显示着：CallActiveBanner 据此决定要不要露出“回到通话”的顶条。
// 通话页 UI 在 ArkTS，文案走主干的 trSource（源英文 → 当前语言包），每次推状态时一并带上（~80 条，很小）。
let GROUP_CALL_UI_STRINGS: Array<String> = [
    "Abort Video Chat",
    "Abort",
    "Add Bio",
    "Add",
    "Allow to Speak",
    "Are you sure you want to end this video chat?",
    "Back",
    "Bio",
    "CONTACTS",
    "Cancel Reminder",
    "Cancel",
    "Change Name",
    "Connecting...",
    "Connection failed",
    "Copy Invite Link",
    "Disable Messages",
    "Display Me As...",
    "Do you want to abort the scheduled video chat?",
    "Edit Bio",
    "Edit Permissions",
    "Edit Title",
    "Edit a title of this video chat.",
    "Enable Messages",
    "End Video Chat",
    "End",
    "First Name",
    "GROUP MEMBERS",
    "Invite Members",
    "Last Name",
    "Late by",
    "Leave Video Chat",
    "Leave video chat",
    "Message",
    "Messages disabled",
    "Messages enabled",
    "Mute for Me",
    "Mute",
    "Muted by admin",
    "New paricipants are muted",
    "New participants can speak",
    "Remove",
    "Save",
    "Schedule Video Chat",
    "Scheduled",
    "Search",
    "Send Message",
    "Set Reminder",
    "Share Invite Link",
    "Share Screen",
    "Start Now",
    "Start Recording",
    "Start Video Chat",
    "Starts in",
    "Stop Recording",
    "Stop Screen Sharing",
    "Stop Sharing",
    "Tap if you want to speak",
    "Tap to retry",
    "Title",
    "Unmute for Me",
    "Unmute",
    "Unpin",
    "Video Chat Title",
    "Video Chat",
    "Video paused",
    "We let the speakers know",
    "You are sharing your screen",
    "You asked to speak",
    "You",
    "this is you",
    "listening",
    "speaking",
    "invited",
    "current",
    "message",
    "share",
    "video",
    "rotate",
    "speaker",
    "leave",
    "mute",
    "unmute",
    "Invite via Link",
    "Any details such as age, occupation or city.",
    "1 participant",
    "Leave",
    "Stop"
]

var _groupCallScreenVisible: Bool = false
public func isGroupCallScreenVisible(): Bool { _groupCallScreenVisible }

var _groupCallActionSubscribed: Bool = false
var _groupCallActionSink: Option<(String) -> Unit> = None

@HybridComponentEntry
@Component
public class GroupCallScreen {
    private var alive: Bool = false
    private var callId: Int64 = 0
    private var callAccessHash: Int64 = 0
    private var routeTitle: String = ""
    private var previewLoaded: Bool = false
    private var previewMembers: ArrayList<GroupCallParticipantInfo> = ArrayList<GroupCallParticipantInfo>()
    private var isRecording: Bool = false
    private var wasJoined: Bool = false
    private var inviteCandidates: ArrayList<GroupCallInviteCandidate> = ArrayList<GroupCallInviteCandidate>()
    private var inviteLoading: Bool = false
    private var toastSeq: Int64 = 0
    // iOS 的预约流程全在通话页里：new = 刚点 Video Chat 还没建（选 Start / Schedule），
    // setup = 选时间，scheduled = 已预约未开始（倒计时 + Start Now），call = 正常通话
    private var mode: String = "call"
    private var scheduleDate: Int64 = 0
    private var reminderSet: Bool = false
    private var routePeerType: String = ""
    private var routePeerId: Int64 = 0
    private var routeCanManage: Bool = false
    private var toastText: String = ""

    protected override func aboutToAppear(): Unit {
        this.ensureLoaded()
    }

    protected override func aboutToDisappear(): Unit {
        this.alive = false
        _groupCallScreenVisible = false
        _groupCallActionSink = None
        getGroupCallSession().setListener(None)
    }

    private func ensureLoaded(): Unit {
        if (this.alive) { return }
        this.alive = true
        _groupCallScreenVisible = true
        let raw = takePending("GroupCallScreen")
        let parts = (if (raw == "{}") { "" } else { raw }).split(":")
        if (parts.size >= 1) { try { this.callId = Int64.parse(parts[0]) } catch (_: Exception) {} }
        if (parts.size >= 2) { try { this.callAccessHash = Int64.parse(parts[1]) } catch (_: Exception) {} }
        if (parts.size >= 3) { this.routeTitle = parts[2] }
        var peerType = ""
        var peerId: Int64 = 0
        var canManage = false
        if (parts.size >= 6) {
            peerType = parts[3]
            try { peerId = Int64.parse(parts[4]) } catch (_: Exception) {}
            canManage = parts[5] == "1"
        }
        if (parts.size >= 7 && parts[6] == "new" && this.callId == 0) { this.mode = "new" }
        this.routePeerType = peerType
        this.routePeerId = peerId
        this.routeCanManage = canManage
        let session = getGroupCallSession()
        // 回到一通进行中的通话（从最小化条点回来）：沿用会话里的配置
        if (this.callId == 0 && session.isActive()) {
            this.callId = session.callId()
            this.callAccessHash = session.accessHash()
        }
        if (!session.isActiveFor(this.callId) && peerId != 0) {
            session.configure(peerType, peerId, canManage)
        }
        Hilog.info(0, "CjTelegram", "[GroupCallScreen] open call=${this.callId} peer=${peerType}/${peerId} canManage=${canManage}")

        if (!_groupCallActionSubscribed) {
            _groupCallActionSubscribed = true
            subscribe(EVT_GROUP_CALL_ACTION, { json: String =>
                match (_groupCallActionSink) {
                    case Some(sink) => sink(json)
                    case None => ()
                }
            })
        }
        _groupCallActionSink = Some({ json: String => this.handleAction(json) })
        session.setListener(Some({ => this.pushState() }))
        this.pushState()

        if (this.mode == "call" && this.callId != 0 && !session.isActiveFor(this.callId)) {
            // iOS：点入口即入会（PresentationCallManager.joinGroupCall），没有中间"Join"页。
            // 例外是预约通话：schedule_date 还在 → 进倒计时页，不入会。
            let cId = this.callId
            let cHash = this.callAccessHash
            let title = this.routeTitle
            let _ = spawn {
                var scheduled: Int64 = 0
                match (getCallsService().getGroupCall(cId, cHash)) {
                    case Some(info) =>
                        scheduled = Int64(info.scheduleDate)
                        this.reminderSet = info.scheduleStartSubscribed
                    case None => ()
                }
                if (scheduled > 0) {
                    Hilog.info(0, "CjTelegram", "[GroupCallScreen] call is scheduled for ${scheduled}")
                    this.mode = "scheduled"
                    this.scheduleDate = scheduled
                    this.pushState()
                } else if (this.alive) {
                    getGroupCallSession().join(cId, cHash, title)
                }
            }
        }
    }

    private func createCall(scheduleAt: Int64): Unit {
        let pid = this.routePeerId
        let pType = this.routePeerType
        if (pid == 0) { return }
        let _ = spawn {
            let isChannel = pType == "channel"
            let hash = match (getRealChatListService().getCachedChat(pType, pid)) {
                case Some(c) => c.accessHash
                case None => 0
            }
            match (getCallsService().createGroupCall(pid, hash, isChannel, "", Int32(scheduleAt))) {
                case Some(info) =>
                    this.callId = info.callId
                    this.callAccessHash = info.accessHash
                    Hilog.info(0, "CjTelegram", "[GroupCallScreen] created call=${info.callId} scheduleAt=${scheduleAt}")
                    if (scheduleAt > 0) {
                        this.mode = "scheduled"
                        this.scheduleDate = scheduleAt
                        this.pushState()
                        notifyActiveGroupCallChanged(pid, info.callId, info.accessHash, 0)
                    } else {
                        notifyActiveGroupCallChanged(pid, info.callId, info.accessHash, 1)
                        this.mode = "call"
                        this.pushState()
                        getGroupCallSession().join(info.callId, info.accessHash, this.routeTitle)
                    }
                case None =>
                    this.callToast(if (scheduleAt > 0) { "Could not schedule the video chat" } else { "Could not start video chat" })
            }
        }
    }

    // ==================== 状态推送 ====================

    private func pushState(): Unit {
        if (!this.alive) { return }
        let session = getGroupCallSession()
        let mine = session.isActiveFor(this.callId) || session.state() == "failed"
        if (this.wasJoined && session.state() == "idle") {
            // 通话被管理员结束 / 在别的设备接管：收起页面（iOS markAsCanBeRemoved → dismiss）
            this.wasJoined = false
            launch { if (this.alive) { routerPop() } }
            return
        }
        if (session.isActiveFor(this.callId)) { this.wasJoined = true }
        let obj = JsonObject()
        let st = if (mine) { session.state() } else { "idle" }
        obj.setString("state", st)
        obj.setString("error", if (mine) { session.errorText() } else { "" })
        var title = if (mine && session.title().size > 0) { session.title() } else { this.routeTitle }
        if (title.size == 0) { title = this.chatTitle() }
        obj.setString("title", title)
        obj.setBool("isMuted", session.isMuted())
        obj.setBool("canUnmute", session.canUnmute())
        obj.setBool("raisedHand", session.raisedHand())
        obj.setBool("canManage", session.canManage())
        obj.setBool("speakerOn", session.speakerOn())
        obj.setBool("isRecording", this.isRecording || session.isRecording())
        obj.setString("selfLevel", "${session.selfLevel()}")
        obj.setBool("cameraOn", session.cameraOn())
        obj.setBool("screenSharing", session.isScreenSharing())
        obj.setBool("screenConnected", session.isScreenConnected())
        obj.setBool("cameraFront", session.cameraFront())
        let arr = JsonArray()
        let photos = getUserPhotoService()
        if (mine) {
            for (m in session.snapshotMembers()) {
                let p = JsonObject()
                p.setInt("peerId", m.peerId)
                p.setString("name", if (m.name.size > 0) { m.name } else { "User" })
                p.setString("avatar", if (m.peerType == "user") { photos.getUserPhotoPath(m.peerId) } else { photos.getChatPhotoPath(m.peerId) })
                p.setBool("isSelf", m.isSelf)
                p.setBool("isMuted", m.isMuted)
                p.setBool("canSelfUnmute", m.canSelfUnmute)
                p.setBool("mutedByYou", m.mutedByYou)
                p.setBool("raiseHand", m.hasRaiseHand)
                p.setBool("isSpeaking", m.isSpeaking)
                p.setString("level", "${m.audioLevel}")
                p.setInt("volume", Int64(m.volume))
                p.setString("about", m.about)
                p.setString("videoEndpoint", if (m.isSelf) { "" } else { m.videoEndpoint })
                p.setBool("videoPaused", m.videoPaused)
                p.setString("presentationEndpoint", if (m.isSelf) { "" } else { m.presentationEndpoint })
                p.setBool("presentationPaused", m.presentationPaused)
                arr.addObject(p)
            }
        }
        obj.setArray("members", arr)
        let msgs = JsonArray()
        if (mine) {
            for (m in session.snapshotMessages()) {
                let o = JsonObject()
                o.setString("id", "${m.id}")
                o.setInt("peerId", m.peerId)
                o.setString("name", m.name)
                o.setString("avatar", photos.getUserPhotoPath(m.peerId))
                o.setString("text", m.text)
                o.setBool("isSelf", m.isSelf)
                msgs.addObject(o)
            }
        }
        obj.setArray("messages", msgs)
        let invites = JsonArray()
        for (c in this.inviteCandidates) {
            let o = JsonObject()
            o.setInt("peerId", c.userId)
            o.setString("name", c.name)
            o.setString("avatar", photos.getUserPhotoPath(c.userId))
            o.setBool("isMember", c.isMember)
            o.setBool("invited", c.invited)
            invites.addObject(o)
        }
        obj.setArray("inviteList", invites)
        obj.setBool("inviteLoading", this.inviteLoading)
        // 自己的名字拆成 first/last 给 "Change Name" 预填（iOS voiceChatUserNameController）
        match (getRealChatListService().getCachedUser(getCurrentUserId())) {
            case Some(u) =>
                obj.setString("selfFirstName", u.firstName)
                obj.setString("selfLastName", u.lastName)
            case None => ()
        }
        obj.setBool("selfIsUser", session.joinAsPeerId() == getCurrentUserId())
        let strings = JsonObject()
        for (label in GROUP_CALL_UI_STRINGS) {
            let localized = trSource(label)
            if (localized != label) { strings.setString(label, localized) }
        }
        obj.setObject("strings", strings)
        obj.setString("mode", this.mode)
        obj.setInt("scheduleDate", this.scheduleDate)
        obj.setBool("reminderSet", this.reminderSet)
        obj.setBool("routeCanManage", this.routeCanManage)
        obj.setString("toast", if (this.toastText.size > 0) { "${this.toastSeq}|${this.toastText}" } else { "" })
        obj.setBool("messagesEnabled", session.messagesAreEnabled())
        obj.setBool("canChangeMessages", session.canChangeMessagesEnabled())
        // Display Me As：iOS 只在可选身份 > 1 时给菜单（VideoChatScreenMoreMenu.swift:167）
        let displayAs = JsonArray()
        let currentAs = session.joinAsPeerId()
        for (p in session.displayAsPeers()) {
            let o = JsonObject()
            o.setInt("peerId", p.peerId)
            o.setString("name", p.name)
            o.setString("avatar", if (p.peerType == "user") { photos.getUserPhotoPath(p.peerId) } else { photos.getChatPhotoPath(p.peerId) })
            o.setBool("current", p.peerId == currentAs)
            displayAs.addObject(o)
        }
        obj.setArray("displayAs", displayAs)
        obj.setBool("joinMuted", session.joinMuted())
        obj.setBool("canChangeJoinMuted", session.canChangeJoinMuted())
        let json = obj.toJsonString()
        // 直接投递到 JS 任务：通用 callArk 在仓颉回调里会先抛一次 "Without any scope" 再回退，
        // 每次 ~150ms（带栈打印）；通话中每秒推几次状态就足以把主线程占满（真机实测 UI 整体卡死）。
        launch {
            if (this.alive) { callArkOnJSTask(GROUP_CALL_UPDATE, json, { _ => () }) }
        }
    }

    private func chatTitle(): String {
        let session = getGroupCallSession()
        let pid = session.chatPeerId()
        if (pid == 0) { return "" }
        match (getRealChatListService().getCachedChat(session.chatPeerType(), pid)) {
            case Some(c) => return c.title
            case None => return ""
        }
    }

    // ==================== ArkTS 动作 ====================

    private func handleAction(json: String): Unit {
        let obj = JsonParser.parseObject(json)
        let action = obj.getString("action")
        let session = getGroupCallSession()
        Hilog.info(0, "CjTelegram", "[GroupCallScreen] action=${action}")
        if (action == "toggleMute") {
            session.toggleMute()
        } else if (action == "toggleSpeaker") {
            session.toggleSpeaker()
        } else if (action == "minimize") {
            // iOS dismiss()：页面收起，通话继续
            routerPop()
        } else if (action == "leave") {
            session.setListener(None)
            this.wasJoined = false
            session.leave(false)
            routerPop()
        } else if (action == "end") {
            session.setListener(None)
            this.wasJoined = false
            session.leave(true)
            routerPop()
        } else if (action == "startNow") {
            this.createCall(0)
        } else if (action == "openSchedule") {
            this.mode = "setup"
            this.pushState()
        } else if (action == "schedule") {
            var at: Int64 = 0
            try { at = Int64.parse(obj.getString("text")) } catch (_: Exception) {}
            if (at > 0) { this.createCall(at) }
        } else if (action == "startScheduled") {
            // iOS PresentationGroupCall.startScheduled → phone.startScheduledGroupCall，随后正常入会
            let cId = this.callId
            let cHash = this.callAccessHash
            let _ = spawn {
                if (getCallsService().startScheduledGroupCall(cId, cHash)) {
                    this.mode = "call"
                    this.scheduleDate = 0
                    this.pushState()
                    getGroupCallSession().join(cId, cHash, this.routeTitle)
                } else {
                    this.callToast(trSource("An error occurred."))
                }
            }
        } else if (action == "editBio") {
            // iOS :119-135 —— account.updateProfile(about) → toast VoiceChat.EditBioSuccess；成员行的副标题随后由服务器更新
            let bio = obj.getString("text")
            let _ = spawn {
                if (getPeersService().updateProfileAbout(bio).success) {
                    getGroupCallSession().setSelfAboutLocal(bio)
                    this.callToast(trSource("Your bio is changed."))
                } else {
                    this.callToast(trSource("An error occurred."))
                }
            }
        } else if (action == "changeName") {
            // text = "first\nlast"（iOS :151-157，toast VoiceChat.EditNameSuccess）
            let parts = obj.getString("text").split("\n")
            let first = if (parts.size >= 1) { parts[0] } else { "" }
            let last = if (parts.size >= 2) { parts[1] } else { "" }
            if (first.size == 0) { return }
            let _ = spawn {
                if (getItemListAvatarAndNameInfoService().updateUserName(first, last)) {
                    getGroupCallSession().setSelfNameLocal(if (last.size > 0) { "${first} ${last}" } else { first })
                    this.callToast(trSource("Your name is changed."))
                } else {
                    this.callToast(trSource("An error occurred."))
                }
            }
        } else if (action == "shareScreen") {
            session.startScreenShare()
        } else if (action == "stopScreenShare") {
            session.stopScreenShare()
        } else if (action == "toggleReminder") {
            // iOS toggleScheduledSubscription：先本地翻转，失败回滚；开启时 toast VoiceChat.ReminderNotify
            let next = !this.reminderSet
            this.reminderSet = next
            this.pushState()
            let cId = this.callId
            let cHash = this.callAccessHash
            let _ = spawn {
                if (getCallsService().toggleGroupCallStartSubscription(cId, cHash, next)) {
                    if (next) { this.callToast(trSource("We will notify you when it starts.")) }
                } else {
                    this.reminderSet = !next
                    this.pushState()
                }
            }
        } else if (action == "cancelScheduled") {
            let cId = this.callId
            let cHash = this.callAccessHash
            let _ = spawn {
                let ok = getCallsService().discardGroupCall(cId, cHash)
                Hilog.info(0, "CjTelegram", "[GroupCallScreen] scheduled call discarded ok=${ok}")
                if (ok && this.routePeerId != 0) { notifyActiveGroupCallChanged(this.routePeerId, 0, 0, 0) }
                launch { if (this.alive) { routerPop() } }
            }
        } else if (action == "closeSetup") {
            routerPop()
        } else if (action == "retry") {
            session.join(this.callId, this.callAccessHash, this.routeTitle)
        } else if (action == "adminMute") {
            session.adminSetMemberMuted(obj.getInt("peerId"), true)
        } else if (action == "adminUnmute") {
            session.adminSetMemberMuted(obj.getInt("peerId"), false)
        } else if (action == "muteForMe") {
            session.setMemberMutedForMe(obj.getInt("peerId"), true)
        } else if (action == "unmuteForMe") {
            session.setMemberMutedForMe(obj.getInt("peerId"), false)
        } else if (action == "setVolume" || action == "setVolumeDone") {
            // text = 0…200（百分比）
            var pct: Int64 = 100
            try { pct = Int64.parse(obj.getString("text")) } catch (_: Exception) {}
            session.setMemberVolume(obj.getInt("peerId"), Int32(pct * 100), action == "setVolumeDone")
        } else if (action == "removeMember") {
            let pid = obj.getInt("peerId")
            var name = ""
            for (m in session.snapshotMembers()) {
                if (m.peerId == pid) { name = m.name }
            }
            let shown = name
            let _ = spawn {
                if (getGroupCallSession().removeMember(pid)) {
                    this.callToast(trSource("You removed ${shown} from this group"))
                } else {
                    this.callToast(trSource("An error occurred."))
                }
            }
        } else if (action == "sendMessageTo") {
            // iOS Conversation_ContextMenuSendMessage：收起通话页，打开和对方的私聊
            let pid = obj.getInt("peerId")
            var name = ""
            for (m in session.snapshotMembers()) {
                if (m.peerId == pid) { name = m.name }
            }
            // 与 ChatListPage.openPreviewedChat 同一套入口：先登记选中的会话，再 push
            setSelectedChat(pid, name, "user")
            setSelectedChatDraft("")
            routerPop()
            routerPush("ChatRoomPage", name)
        } else if (action == "openProfile") {
            let pid = obj.getInt("peerId")
            routerPush("PeerInfoPage", "user:${pid}:0")
        } else if (action == "shareLink") {
            this.copyInviteLink()
        } else if (action == "editTitle") {
            this.applyTitle(obj.getString("text"))
        } else if (action == "toggleRecord") {
            this.toggleRecord()
        } else if (action == "displayAs") {
            session.reconnectAs(obj.getInt("peerId"))
        } else if (action == "setJoinMuted") {
            session.setJoinMuted(obj.getString("text") == "1")
        } else if (action == "toggleMessages") {
            session.toggleMessagesEnabled()
        } else if (action == "sendMessage") {
            session.sendMessage(obj.getString("text"))
        } else if (action == "toggleCamera") {
            session.toggleCamera()
        } else if (action == "flipCamera") {
            session.flipCamera()
        } else if (action == "bindRemoteSurface") {
            // text = "<surfaceId>|<endpointId>"；surfaceId 是 uint64 的十进制串（超 JS 安全整数，走字符串）
            let parts = obj.getString("text").split("|")
            if (parts.size >= 2) {
                var sid: UInt64 = 0
                try { sid = UInt64.parse(parts[0]) } catch (_: Exception) {}
                session.bindRemoteSurface(parts[1], sid)
            }
        } else if (action == "bindLocalSurface") {
            var sid: UInt64 = 0
            try { sid = UInt64.parse(obj.getString("text")) } catch (_: Exception) {}
            session.bindLocalSurface(sid)
        } else if (action == "expandVideo") {
            session.setExpandedEndpoint(obj.getString("text"))
        } else if (action == "invite") {
            this.loadInviteCandidates()
        } else if (action == "inviteUser") {
            this.inviteUser(obj.getInt("peerId"), false)
        } else if (action == "addAndInviteUser") {
            this.inviteUser(obj.getInt("peerId"), true)
        }
    }

    // iOS VideoChatScreenInviteMembers.swift:100-116 —— 先本群成员，再联系人；去掉自己、机器人和已在通话里的人。
    private func loadInviteCandidates(): Unit {
        if (this.inviteLoading) { return }
        this.inviteLoading = true
        this.pushState()
        let _ = spawn {
            let session = getGroupCallSession()
            let result = ArrayList<GroupCallInviteCandidate>()
            let seen = HashSet<Int64>()
            for (m in session.snapshotMembers()) { seen.add(m.peerId) }
            let chatId = session.chatPeerId()
            if (chatId != 0) {
                try {
                    if (session.chatPeerType() == "channel") {
                        match (getRealChatListService().getCachedChat("channel", chatId)) {
                            case Some(c) => getPeerInfoService().registerChannelAccessHash(chatId, c.accessHash)
                            case None => ()
                        }
                    }
                    var found = getPeerInfoService().searchMembers(chatId, "", 0, 200)
                    if (found.members.size == 0 && found.error.size == 0) {
                        found = getPeerInfoService().searchMembers(chatId, "", 0, 200)
                    }
                    Hilog.info(0, "CjTelegram", "[GroupCallScreen] invite: group members=${found.members.size} err='${found.error}'")
                    for (m in found.members) {
                        if (m.userId == 0 || m.accessHash == 0 || seen.contains(m.userId)) { continue }
                        seen.add(m.userId)
                        let c = GroupCallInviteCandidate()
                        c.userId = m.userId
                        c.accessHash = m.accessHash
                        c.name = inviteDisplayName(m.firstName, m.lastName, m.username)
                        c.isMember = true
                        result.add(c)
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[GroupCallScreen] invite: group members failed: ${e}")
                }
            }
            try {
                for (u in getRealContactService().getContacts()) {
                    if (u.userId == 0 || u.isSelf || u.isBot || seen.contains(u.userId)) { continue }
                    seen.add(u.userId)
                    let c = GroupCallInviteCandidate()
                    c.userId = u.userId
                    c.accessHash = u.accessHash
                    c.name = inviteDisplayName(u.firstName, u.lastName, u.username)
                    result.add(c)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupCallScreen] invite: contacts failed: ${e}")
            }
            Hilog.info(0, "CjTelegram", "[GroupCallScreen] invite: ${result.size} candidates")
            this.inviteCandidates = result
            this.inviteLoading = false
            this.pushState()
        }
    }

    // 成员：直接 phone.inviteToGroupCall + toast（:135-139）。非成员：ArkTS 先弹 "Add" 确认，
    // 再走这里 addFirst=true —— 先拉进群再邀请（:168-250）。
    private func inviteUser(userId: Int64, addFirst: Bool): Unit {
        var target: Option<GroupCallInviteCandidate> = None
        for (c in this.inviteCandidates) {
            if (c.userId == userId) { target = Some(c) }
        }
        let cand = match (target) {
            case Some(c) => c
            case None => return
        }
        let cId = this.callId
        let cHash = this.callAccessHash
        let _ = spawn {
            let session = getGroupCallSession()
            if (addFirst) {
                let chatId = session.chatPeerId()
                let added = if (session.chatPeerType() == "channel") {
                    let hash = match (getRealChatListService().getCachedChat("channel", chatId)) {
                        case Some(c) => c.accessHash
                        case None => 0
                    }
                    getPeersService().inviteToChannel(chatId, hash, cand.userId, cand.accessHash)
                } else {
                    getPeersService().addGroupMember(chatId, cand.userId, cand.accessHash)
                }
                if (!added.success) {
                    Hilog.info(0, "CjTelegram", "[GroupCallScreen] invite: add to group failed: ${added.errorCode}")
                    showToast(if (added.errorCode.contains("PRIVACY")) {
                        "Sorry, you can't add ${cand.name} to groups because of their privacy settings."
                    } else {
                        "An error occurred."
                    })
                    return
                }
                cand.isMember = true
            }
            let ids = ArrayList<Int64>()
            ids.add(cand.userId)
            let hashes = ArrayList<Int64>()
            hashes.add(cand.accessHash)
            if (getCallsService().inviteToGroupCall(cId, cHash, ids, hashes)) {
                cand.invited = true
                this.callToast(trSource("You invited ${cand.name} to the voice chat"))
            } else {
                this.callToast(trSource("An error occurred."))
            }
        }
    }

    // 通话页是 ArkTS 覆盖层，toast 交给它在自己的 UIContext 里弹（位置要压在按钮排上方）。
    private func callToast(text: String): Unit {
        this.toastSeq = this.toastSeq + 1
        this.toastText = text
        this.pushState()
    }

    private func copyInviteLink(): Unit {
        let cId = this.callId
        let cHash = this.callAccessHash
        let _ = spawn {
            match (getCallsService().exportGroupCallInvite(cId, cHash, false)) {
                case Some(link) =>
                    let _ = copyText(link)
                    showToast(trSource("Invite link copied to clipboard."))
                case None =>
                    showToast(trSource("Could not create an invite link"))
            }
        }
    }

    private func applyTitle(text: String): Unit {
        let cId = this.callId
        let cHash = this.callAccessHash
        let _ = spawn {
            if (getCallsService().editGroupCallTitle(cId, cHash, text)) {
                getGroupCallSession().setTitleLocal(text)
            } else {
                showToast(trSource("Could not change the title"))
            }
        }
    }

    private func toggleRecord(): Unit {
        let cId = this.callId
        let cHash = this.callAccessHash
        let start = !this.isRecording
        let _ = spawn {
            if (getCallsService().toggleGroupCallRecord(cId, cHash, start, "")) {
                this.isRecording = start
                showToast(if (start) { "Video chat recording started." } else { "Video chat recording saved to Saved Messages." })
                this.pushState()
            } else {
                showToast(trSource("Could not change recording"))
            }
        }
    }

    func build() {
        // 透明占位：可见 UI 全在 ArkTS 覆盖层
        Column() {}
            .width(100.percent)
            .height(100.percent)
            .onAppear({ => this.ensureLoaded() })
    }
}

private func inviteDisplayName(first: String, last: String, username: String): String {
    if (first.size > 0 && last.size > 0) { return "${first} ${last}" }
    if (first.size > 0) { return first }
    if (last.size > 0) { return last }
    if (username.size > 0) { return username }
    return "Deleted Account"
}
