package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.convert.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.components.SegmentedControl
import ohos_app_cangjie_entry.components.{RankInfoSheet, RankRole}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * GroupMembersPage — 群组/频道成员管理页，带分段 Tab
 *
 * Tab 分段对应 channels.getParticipants filter 变体（iOS ChannelParticipantsFilter）：
 *   Recent (index 0) → channelParticipantsRecent#de3f3c79
 *   Admins (index 1) → channelParticipantsAdmins#b4608969
 *   Bots   (index 2) → channelParticipantsBots#b0d1865b
 *   Kicked (index 3) → channelParticipantsKicked#a3b54985
 *
 * ctor 来自 iOS Api4.swift ChannelParticipantsFilter，已在 PeerInfoService.getParticipantsByFilter 验证。
 *
 * 路由参数格式（takePending 解析）：
 *   "channelId|accessHash|title"
 *
 * 成员行：avatar 首字母 + 显示名 + 角色标注 (Owner/Admin/Bot)
 * 点击成员 → 弹出操作菜单（Promote / Restrict / Remove）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（.title/.onReady 一并去掉），只留内部 Stack
 *  - onReady param 接收 → ensureLoaded()（.onAppear 触发）内 takePending("GroupMembersPage")
 */
@HybridComponentEntry
@Component
public class GroupMembersPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 当前激活 Tab（0=Recent 1=Admins 2=Bots 3=Kicked）
    @State var currentTab: Int64 = 0

    // 各 Tab 对应的成员列表（防死状态：真实从 getParticipants 拉取，切 Tab 触发加载）
    @State var recentMembers: ArrayList<MemberInfo> = ArrayList<MemberInfo>()
    // 当前 Tab 的可见列表/加载态（派生状态）。@Builder 按值传参不具响应性（ArkUI 经典坑）：
    // 原 buildMemberList(members, isLoading) 在数据回填后不会重渲染，真机恒显 "No members"。
    @State var shownMembers: ArrayList<MemberInfo> = ArrayList<MemberInfo>()
    @State var shownLoading: Bool = false
    @State var adminsMembers: ArrayList<MemberInfo> = ArrayList<MemberInfo>()
    @State var botsMembers: ArrayList<MemberInfo> = ArrayList<MemberInfo>()
    @State var kickedMembers: ArrayList<MemberInfo> = ArrayList<MemberInfo>()

    // 各 Tab 加载状态
    @State var recentLoading: Bool = false
    @State var adminsLoading: Bool = false
    @State var botsLoading: Bool = false
    @State var kickedLoading: Bool = false

    // 各 Tab 是否已加载过（避免重复请求）
    @State var recentLoaded: Bool = false
    @State var adminsLoaded: Bool = false
    @State var botsLoaded: Bool = false
    @State var kickedLoaded: Bool = false

    // 错误信息
    @State var loadError: String = ""

    // 操作菜单
    @State var showActionMenu: Bool = false
    @State var selectedUserId: Int64 = 0
    @State var selectedUserAccessHash: Int64 = 0
    @State var selectedUserName: String = ""
    @State var selectedUserIsAdmin: Bool = false

    // 操作结果提示
    @State var actionResult: String = ""
    @State var showResult: Bool = false

    // S212: 头衔说明 sheet。入口 = 点成员副标题里的头衔（本工程唯一的头衔展示点）。
    @State var showRankInfo: Bool = false
    @State var rankInfoRank: String = ""
    @State var rankInfoRole: RankRole = RankRole.RankMember
    @State var rankInfoUserName: String = ""
    @State var rankInfoCanChange: Bool = false

    // 页面标题（来自路由参数）
    @State var pageTitle: String = "Members"

    // 频道 ID 和 accessHash（来自路由参数）
    private var channelId: Int64 = 0
    private var channelAccessHash: Int64 = 0
    private var isBasicGroup: Bool = false
    private var canManage: Bool = false

    // 混合页首次渲染守卫
    @State var loaded: Bool = false

    // ==================== 首次加载（.onAppear 触发） ====================

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("GroupMembersPage")
        let param = if (raw == "{}") { "" } else { raw }
        this.parseRouteParam(param)
        // 初始加载 Recent tab
        this.loadTabMembers("recent")
    }

    // ==================== 路由参数解析 ====================

    private func parseRouteParam(param: String): Unit {
        if (param.size > 0) {
            let parts = param.split("|")
            if (parts.size >= 1) {
                try { this.channelId = Int64.parse(parts[0].trimAscii()) } catch (_: Exception) { () }
            }
            if (parts.size >= 2) {
                try { this.channelAccessHash = Int64.parse(parts[1].trimAscii()) } catch (_: Exception) { () }
            }
            if (parts.size >= 3) {
                let t = parts[2].trimAscii()
                if (t.size > 0) { this.pageTitle = t }
            }
        }
        // 后向兼容回退：若 param 为空或解析失败，退回到全局选中聊天，行为与旧版一致。
        if (this.channelId == 0) {
            this.channelId = getSelectedChatId()
            match (getRealChatListService().getCachedChat(this.channelId)) {
                case Some(chat) => this.channelAccessHash = chat.accessHash
                case None => ()
            }
        }
        match (getRealChatListService().getCachedChat(this.channelId)) {
            case Some(chat) =>
                this.isBasicGroup = !chat.isChannel
                this.canManage = chat.isCreator || chat.canEditInfo
            case None =>
                // W6 S4-25：实体不在内存缓存时按会话 peerType 判定，基础群不能发 channels.getParticipants
                if (this.channelId == getSelectedChatId() && getSelectedChatPeerType() == "chat") {
                    this.isBasicGroup = true
                }
                Hilog.info(0, "CjTelegram", "[GroupMembersPage] chat ${this.channelId} not in cache, selectedPeerType=${getSelectedChatPeerType()} -> basic=${this.isBasicGroup}")
        }
        Hilog.info(0, "CjTelegram", "[GroupMembersPage] parsed: channelId=${this.channelId} hash=${this.channelAccessHash} title=${this.pageTitle} basic=${this.isBasicGroup}")
    }

    // ==================== 数据加载（真实 API，防死状态） ====================

    /**
     * 加载指定 Tab 的成员列表，调用 PeerInfoService.getParticipantsByFilter
     *
     * filterKey 对应关系（iOS ChannelParticipantsFilter ctor 已在 PeerInfoService 验证）：
     *   "recent"  → channelParticipantsRecent#de3f3c79
     *   "admins"  → channelParticipantsAdmins#b4608969
     *   "bots"    → channelParticipantsBots#b0d1865b
     *   "kicked"  → channelParticipantsKicked#a3b54985  q:string
     */
    private func loadTabMembers(filterKey: String): Unit {
        if (this.channelId == 0) {
            Hilog.info(0, "CjTelegram", "[GroupMembersPage] No channelId, skipping load for filter=${filterKey}")
            return
        }

        // 注册 accessHash 到 PeerInfoService 缓存，使 getParticipantsByFilter 能从 channelAccessHashes 取到
        getPeerInfoService().registerChannelAccessHash(this.channelId, this.channelAccessHash)

        let cid = this.channelId
        let filter = filterKey
        // 非基础群留空：服务层仍按缓存判定，并保留 400 → 基础群兜底
        let peerTypeHint = if (this.isBasicGroup) { "chat" } else { "" }

        // 设置加载中状态（主线程）
        launch {
            if (filter == "recent") { this.recentLoading = true }
            else if (filter == "admins") { this.adminsLoading = true }
            else if (filter == "bots") { this.botsLoading = true }
            else { this.kickedLoading = true }
            this.loadError = ""
            this.refreshShown()
        }

        spawn {
            try {
                let svc = getPeerInfoService()
                let result = svc.getParticipantsByFilter(cid, filter, 0, 200, "", peerType: peerTypeHint)
                Hilog.info(0, "CjTelegram", "[GroupMembersPage] Loaded ${result.members.size} members for filter=${filter} total=${result.totalCount} peerType='${peerTypeHint}' err='${result.error}'")

                let newList = ArrayList<MemberInfo>()
                for (m in result.members) {
                    newList.add(m)
                }

                launch {
                    if (filter == "recent") {
                        this.recentMembers = newList
                        this.recentLoading = false
                        this.recentLoaded = true
                    } else if (filter == "admins") {
                        this.adminsMembers = newList
                        this.adminsLoading = false
                        this.adminsLoaded = true
                    } else if (filter == "bots") {
                        this.botsMembers = newList
                        this.botsLoading = false
                        this.botsLoaded = true
                    } else {
                        this.kickedMembers = newList
                        this.kickedLoading = false
                        this.kickedLoaded = true
                    }
                    this.refreshShown()
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupMembersPage] loadTabMembers(${filter}) error: ${e}")
                launch {
                    if (filter == "recent") { this.recentLoading = false }
                    else if (filter == "admins") { this.adminsLoading = false }
                    else if (filter == "bots") { this.botsLoading = false }
                    else { this.kickedLoading = false }
                    this.loadError = "Failed to load ${filter} members"
                    this.refreshShown()
                }
            }
        }
    }

    /**
     * 切换 Tab 时触发加载（懒加载：仅首次切入时请求）
     */
    private func refreshShown(): Unit {
        if (this.currentTab == 0) {
            this.shownMembers = this.recentMembers
            this.shownLoading = this.recentLoading
        } else if (this.currentTab == 1) {
            this.shownMembers = this.adminsMembers
            this.shownLoading = this.adminsLoading
        } else if (this.currentTab == 2) {
            this.shownMembers = this.botsMembers
            this.shownLoading = this.botsLoading
        } else {
            this.shownMembers = this.kickedMembers
            this.shownLoading = this.kickedLoading
        }
    }

    private func onTabChanged(idx: Int64): Unit {
        this.currentTab = idx
        this.refreshShown()
        if (idx == 0 && !this.recentLoaded && !this.recentLoading) {
            this.loadTabMembers("recent")
        } else if (idx == 1 && !this.adminsLoaded && !this.adminsLoading) {
            this.loadTabMembers("admins")
        } else if (idx == 2 && !this.botsLoaded && !this.botsLoading) {
            this.loadTabMembers("bots")
        } else if (idx == 3 && !this.kickedLoaded && !this.kickedLoading) {
            this.loadTabMembers("kicked")
        }
    }

    // ==================== 成员操作 ====================

    private func showActionsForMember(member: MemberInfo): Unit {
        if (!this.canManage || member.isCreator) { return }
        this.selectedUserId = member.userId
        this.selectedUserAccessHash = member.accessHash
        this.selectedUserName = member.displayName()
        this.selectedUserIsAdmin = member.isAdmin
        this.showActionMenu = true
    }

    private func unbanSelectedMember(): Unit {
        this.showActionMenu = false
        let cid = this.channelId
        let chash = this.channelAccessHash
        let uid = this.selectedUserId
        let uhash = this.selectedUserAccessHash
        let uname = this.selectedUserName
        spawn {
            let result = getPeersService().unbanChannelMember(cid, chash, uid, uhash)
            let msg = if (result.success) { "Unbanned ${uname}" } else { "Failed: ${result.errorCode}" }
            launch {
                this.actionResult = msg
                this.showResult = true
                this.kickedLoaded = false
                this.loadTabMembers("kicked")
                if (result.success) { this.notifyInfoPage(cid) }
            }
        }
    }

    private func promoteSelectedMember(): Unit {
        this.showActionMenu = false
        let cid = this.channelId
        let chash = this.channelAccessHash
        let uid = this.selectedUserId
        let uhash = this.selectedUserAccessHash
        let uname = this.selectedUserName
        spawn {
            try {
                var success = false
                var error = ""
                if (this.isBasicGroup) {
                    success = getRealMessageService().editBasicGroupAdmin(cid, uid, uhash, true)
                } else {
                    let svc = getPeersService()
                    // 基本管理员权限位: change_info(1) + post(4) + delete(8) + ban(16) + invite(32) + pin(128) = 189
                    let result = svc.editAdmin(cid, chash, uid, uhash, 189)
                    success = result.success
                    error = result.errorCode
                }
                let msg = if (success) { "Promoted ${uname} to Admin" } else { "Failed: ${error}" }
                let okFlag = success
                launch {
                    this.actionResult = msg
                    this.showResult = true
                    // 刷新 admins tab
                    this.adminsLoaded = false
                    this.loadTabMembers("admins")
                    if (okFlag) { this.notifyInfoPage(cid) }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupMembersPage] promoteSelectedMember error: ${e}")
            }
        }
    }

    private func restrictSelectedMember(): Unit {
        this.showActionMenu = false
        let cid = this.channelId
        let chash = this.channelAccessHash
        let uid = this.selectedUserId
        let uhash = this.selectedUserAccessHash
        let uname = this.selectedUserName
        spawn {
            try {
                if (this.isBasicGroup) {
                    launch {
                        this.actionResult = "Restrictions are available after upgrading to a supergroup"
                        this.showResult = true
                    }
                    return
                }
                let svc = getPeersService()
                let rights = ChatBannedRights()
                rights.flags = 6
                rights.untilDate = 0
                let ok = svc.editBanned(cid, chash, uid, uhash, rights)
                let msg = if (ok.success) { "Restricted ${uname}" } else { "Failed: ${ok.errorCode}" }
                launch {
                    this.actionResult = msg
                    this.showResult = true
                    if (ok.success) { this.notifyInfoPage(cid) }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupMembersPage] restrictSelectedMember error: ${e}")
            }
        }
    }

    private func kickSelectedMember(): Unit {
        this.showActionMenu = false
        let cid = this.channelId
        let chash = this.channelAccessHash
        let uid = this.selectedUserId
        let uhash = this.selectedUserAccessHash
        let uname = this.selectedUserName
        spawn {
            try {
                var success = false
                var error = ""
                if (this.isBasicGroup) {
                    let result = getPeersService().removeGroupMember(cid, uid, uhash)
                    success = result.success
                    error = result.errorCode
                } else {
                    let result = getPeersService().kickChannelMember(cid, chash, uid, uhash)
                    success = result.success
                    error = result.errorCode
                }
                let msg = if (success) { "Removed ${uname}" } else { "Failed: ${error}" }
                let okFlag = success
                launch {
                    this.actionResult = msg
                    this.showResult = true
                    // 刷新 recent tab
                    this.recentLoaded = false
                    this.loadTabMembers("recent")
                    if (okFlag) { this.notifyInfoPage(cid) }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupMembersPage] kickSelectedMember error: ${e}")
            }
        }
    }

    // ==================== 辅助函数 ====================

    /**
     * S212: 打开头衔说明 sheet。
     * 角色判定与 getMemberRole 同源：isCreator > isAdmin > 普通成员。
     * canChange 沿用 iOS 语义「只有管理员能指派头衔」——本页的封禁/提升动作
     * 已由 canManage 门控，这里复用同一判断。
     */
    /** 成员变动后让资料页重新拉取（缓存的 fullInfo 一并作废） */
    private func notifyInfoPage(chatId: Int64): Unit {
        getPeerInfoService().invalidateGroupFullInfo(chatId)
        notifyPeerInfoChanged()
    }

    private func openRankInfo(member: MemberInfo): Unit {
        var role = RankRole.RankMember
        if (member.isCreator) {
            role = RankRole.RankOwner
        } else if (member.isAdmin) {
            role = RankRole.RankAdmin
        }
        this.rankInfoRank = member.rank
        this.rankInfoRole = role
        this.rankInfoUserName = member.displayName()
        this.rankInfoCanChange = false
        this.showRankInfo = true
    }

    private func getMemberRole(member: MemberInfo): String {
        if (member.isCreator) { return "Owner" }
        if (member.isAdmin) {
            if (member.rank.size > 0) { return member.rank }
            return "Admin"
        }
        return ""
    }

    private func getAvatarColorForMember(userId: Int64): Int64 {
        let colors: Array<Int64> = [0xE17076, 0xFFB347, 0x6BCEBB, 0x7EC8E3, 0xA695E7, 0xFF6B6B, 0x4FC3F7]
        let idx = Int64(userId % 7)
        return colors[idx]
    }

    private func getMemberInitial(member: MemberInfo): String {
        let name = member.displayName()
        if (name.size == 0) { return "?" }
        return name[0..1]
    }

    private func getMemberSubtitle(member: MemberInfo): String {
        let role = this.getMemberRole(member)
        if (role.size > 0) { return role }
        if (member.username.size > 0) { return "@" + member.username }
        return ""
    }

    private func getMemberSubtitleColor(member: MemberInfo): Int64 {
        let role = this.getMemberRole(member)
        if (role.size > 0) { return 0x0088CC }
        return 0x999999
    }

    // ==================== build ====================

    public func build() {
        Stack {
            Column {
                // 分段切换条 — 替代手搓 tabHeaderBuilder (P2-RETRO-groups)
                Row {
                    SegmentedControl(
                        segments: if (this.isBasicGroup) { ["Recent", "Admins", "Bots"] } else { ["Recent", "Admins", "Bots", "Kicked"] },
                        selectedIndex: this.currentTab,
                        onChange: { idx: Int64 => this.onTabChanged(idx) }
                    )
                }
                .width(100.percent)
                .padding(left: 12, right: 12, top: 8, bottom: 8)
                .backgroundColor(0xF2F2F7)

                // 当前 Tab 内容区（条件渲染，替代 TabContent）
                if (this.currentTab == 0) {
                    this.buildRecentTab()
                } else if (this.currentTab == 1) {
                    this.buildAdminsTab()
                } else if (this.currentTab == 2) {
                    this.buildBotsTab()
                } else {
                    this.buildKickedTab()
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFF)
            .padding(bottom: getSafeAreaBottom())

            // 操作菜单覆盖层
            if (this.showActionMenu) {
                this.memberActionMenu()
            }

            // ==================== S212: 头衔说明 sheet ====================
            if (this.showRankInfo) {
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x66000000)
                    .onClick({ _evt => this.showRankInfo = false })

                Column {
                    RankInfoSheet(
                        rank: this.rankInfoRank,
                        role: this.rankInfoRole,
                        userName: this.rankInfoUserName,
                        chatName: "",
                        canChange: this.rankInfoCanChange,
                        onClose: { => this.showRankInfo = false },
                        onSetTag: { => this.showRankInfo = false }
                    )
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .padding(left: 20, right: 20)
            }

            // 操作结果提示
            if (this.showResult) {
                Column {
                    Text(this.actionResult)
                        .fontSize(14)
                        .fontColor(0xFFFFFF)
                        .padding(left: 20, right: 20, top: 10, bottom: 10)
                        .backgroundColor(0x333333)
                        .borderRadius(20)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.End)
                .alignItems(HorizontalAlign.Center)
                .padding(bottom: 100)
                .onClick({ _ =>
                    this.showResult = false
                })
            }
        }
        .onAppear({ => this.ensureLoaded() })
    }

    // ==================== @Builder 函数（S-013：禁止 private）====================

    // 无参 @Builder 包装（D-115：@Builder 带参在 build() 直调时宏展开失败）
    @Builder
    func buildRecentTab() {
        this.buildMemberList()
    }

    @Builder
    func buildAdminsTab() {
        this.buildMemberList()
    }

    @Builder
    func buildBotsTab() {
        this.buildMemberList()
    }

    @Builder
    func buildKickedTab() {
        this.buildMemberList()
    }

    @Builder
    func buildMemberList() {
        Column {
            if (this.shownLoading) {
                Column {
                    Text(trSource("Loading..."))
                        .fontSize(14)
                        .fontColor(0x999999)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.shownMembers.size == 0) {
                Column {
                    Text("No members")
                        .fontSize(14)
                        .fontColor(0x999999)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                List {
                    ForEach(this.shownMembers, itemGenerator: { member: MemberInfo, _: Int64 =>
                        ListItem {
                            this.memberRow(member)
                        }
                    })
                }
                .width(100.percent)
                .layoutWeight(1)
                .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xE8E8E8, startMargin: 68, endMargin: 16))
            }
        }
        .width(100.percent)
        .height(100.percent)
    }

    @Builder
    func memberRow(member: MemberInfo) {
        Row {
            // Avatar 首字母圆
            Column {
                Text(this.getMemberInitial(member))
                    .fontSize(17)
                    .fontColor(0xFFFFFF)
                    .fontWeight(FontWeight.Medium)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor(this.getAvatarColorForMember(member.userId))
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(left: 16, right: 12)

            // 名称 + 角色/用户名
            Column {
                Text(member.displayName())
                    .fontSize(16)
                    .fontColor(0x000000)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)

                if (this.getMemberSubtitle(member).size > 0) {
                    Text(this.getMemberSubtitle(member))
                        .onClick({ _evt =>
                            // S212: 副标题展示的就是头衔（getMemberRole），点它开说明 sheet；
                            // 无头衔时副标题是 @username，不触发。
                            if (this.getMemberRole(member).size > 0) {
                                this.openRankInfo(member)
                            }
                        })
                        .fontSize(13)
                        .fontColor(this.getMemberSubtitleColor(member))
                        .margin(top: 2)
                }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
        .width(100.percent)
        .height(60)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ =>
            this.showActionsForMember(member)
        })
    }

    @Builder
    func memberActionMenu() {
        Column {
            Column {
                Text(this.selectedUserName)
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                    .margin(bottom: 16)

                if (this.currentTab == 3) {
                    Row {
                        Text("Unban Member")
                            .fontSize(16)
                            .fontColor(0xFF0088CC)
                    }
                    .width(100.percent)
                    .height(48)
                    .justifyContent(FlexAlign.Center)
                    .onClick({ _ => this.unbanSelectedMember() })
                } else {
                    Row {
                        Text(if (this.selectedUserIsAdmin) { "Manage Admin Rights" } else { "Promote to Admin" })
                            .fontSize(16)
                            .fontColor(0x0088CC)
                    }
                    .width(100.percent)
                    .height(48)
                    .justifyContent(FlexAlign.Center)
                    .onClick({ _ =>
                        if (this.selectedUserIsAdmin) {
                            this.showActionMenu = false
                            routerPush("AdminManagePage")
                        } else {
                            this.promoteSelectedMember()
                        }
                    })

                    Divider()
                        .color(0xE8E8E8)
                        .height(0.5)

                    if (!this.isBasicGroup) {
                        Row {
                            Text("Restrict Member")
                                .fontSize(16)
                                .fontColor(0xFF9800)
                        }
                        .width(100.percent)
                        .height(48)
                        .justifyContent(FlexAlign.Center)
                        .onClick({ _ => this.restrictSelectedMember() })

                        Divider()
                            .color(0xE8E8E8)
                            .height(0.5)
                    }

                    Row {
                        Text("Remove from Group")
                            .fontSize(16)
                            .fontColor(0xFF3B30)
                    }
                    .width(100.percent)
                    .height(48)
                    .justifyContent(FlexAlign.Center)
                    .onClick({ _ => this.kickSelectedMember() })
                }

                Divider()
                    .color(0xE8E8E8)
                    .height(0.5)

                Row {
                    Text(trSource("Cancel"))
                        .fontSize(16)
                        .fontColor(0x0088CC)
                }
                .width(100.percent)
                .height(48)
                .justifyContent(FlexAlign.Center)
                .onClick({ _ =>
                    this.showActionMenu = false
                })
            }
            .width(85.percent)
            .padding(20)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x80000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ =>
            this.showActionMenu = false
        })
    }
}
