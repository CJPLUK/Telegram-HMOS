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
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * BlacklistPage — 双模式黑名单/封禁成员管理页（混合工程迁移版）
 *
 * P2-137 r1: 恢复联系人黑名单旧功能 + 保留频道封禁成员功能，双模式分流
 *
 * 模式判断 (parseRouteParam 后)：
 *   channelId == 0 → 联系人黑名单模式（PrivacySettings 空参入口）
 *     - 调用 getRealContactService().getBlockedUsers() 列被屏蔽联系人
 *     - Unblock 调 getRealContactService().unblockUser(userId, accessHash)
 *     - 标题：this.channelTitle（默认 "Blocked Users"）
 *   channelId > 0 → 频道封禁成员模式（GroupDetails Banned Users 入口，带 channel param）
 *     - 调用 getPeersService().getBannedChannelParticipants() 列封禁/踢出成员
 *     - Unban 调 getPeersService().editBanned(flags=0, untilDate=0)
 *     - 标题：this.channelTitle（来自路由参数 channelTitle）
 *     - 双 Tab：Restricted / Kicked
 *
 * 路由参数格式：
 *   空参 ""               → 联系人黑名单模式
 *   "channelId|hash|title" → 频道封禁模式
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（原 hideTitleBar(true)），只留内容
 *  - pageStack.pop() → routerPop()
 *  - onReady param 解析 + 首帧加载 → ensureLoaded()（.onAppear 触发）内 takePending("BlacklistPage")
 */
@HybridComponentEntry
@Component
public class BlacklistPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 频道封禁模式：封禁/踢出成员列表
    @State var bannedList: ArrayList<BannedParticipantEntry> = ArrayList<BannedParticipantEntry>()
    @State var kickedList: ArrayList<BannedParticipantEntry> = ArrayList<BannedParticipantEntry>()
    // 联系人黑名单模式：被屏蔽联系人列表
    @State var blockedUserList: ArrayList<BlockedUserEntry> = ArrayList<BlockedUserEntry>()

    @State var isLoading: Bool = false
    @State var loadError: String = ""
    @State var selectedTab: Int32 = 0
    // FIX-2: channelTitle 实际用于标题显示；联系人模式默认 "Blocked Users"
    @State var channelTitle: String = "Blocked Users"
    // FIX-1: 模式标志；true = 频道封禁模式，false = 联系人黑名单模式
    @State var isChannelMode: Bool = false

    private var channelId: Int64 = 0
    private var channelAccessHash: Int64 = 0

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("BlacklistPage")
        let param = if (raw == "{}") { "" } else { raw }
        this.parseRouteParam(param)
        if (this.isChannelMode) {
            this.loadBannedMembers()
        } else {
            this.loadBlockedUsers()
        }
    }

    private func parseRouteParam(param: String): Unit {
        if (param.size == 0) {
            // 空参 → 联系人黑名单模式
            this.isChannelMode = false
            this.channelTitle = "Blocked Users"
            return
        }
        let parts = param.split("|")
        if (parts.size >= 1) {
            try { this.channelId = Int64.parse(parts[0].trimAscii()) } catch (_: Exception) { () }
        }
        if (parts.size >= 2) {
            try { this.channelAccessHash = Int64.parse(parts[1].trimAscii()) } catch (_: Exception) { () }
        }
        if (parts.size >= 3) {
            let t = parts[2].trimAscii()
            if (t.size > 0) { this.channelTitle = t }
        }
        if (this.channelId > 0) {
            // 有效 channelId → 频道封禁模式
            this.isChannelMode = true
            // channelTitle 已在上面从 parts[2] 设置；若未提供则保持默认
            if (this.channelTitle == "Blocked Users") {
                this.channelTitle = "Banned Members"
            }
        } else {
            // channelId 解析结果为 0 → 退化为联系人黑名单模式
            this.isChannelMode = false
            this.channelTitle = "Blocked Users"
        }
    }

    // === 联系人黑名单模式 ===

    private func loadBlockedUsers(): Unit {
        launch {
            this.isLoading = true
            this.loadError = ""
        }
        spawn {
            try {
                let svc = getRealContactService()
                let result = svc.getBlockedUsers()
                Hilog.info(0, "CjTelegram", "[BlacklistPage] Contacts mode: loaded ${result.size} blocked users")
                let newList = ArrayList<BlockedUserEntry>()
                for (data in result) {
                    newList.add(BlockedUserEntry(data))
                }
                launch {
                    this.blockedUserList = newList
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[BlacklistPage] loadBlockedUsers error: ${e}")
                launch {
                    this.isLoading = false
                    this.loadError = "Failed to load blocked users"
                }
            }
        }
    }

    private func removeUnblockAt(idx: Int64): Unit {
        if (idx < 0 || idx >= this.blockedUserList.size) { return }
        let entry = this.blockedUserList[idx]
        let userId = entry.data.userId
        let accessHash = entry.data.accessHash
        let displayName = entry.data.getDisplayName()
        let snapshot = ArrayList<BlockedUserEntry>()
        for (e in this.blockedUserList) { snapshot.add(e) }

        spawn {
            try {
                let svc = getRealContactService()
                let ok = svc.unblockUser(userId, accessHash)
                if (ok) {
                    let newList = ArrayList<BlockedUserEntry>()
                    var i: Int64 = 0
                    while (i < snapshot.size) {
                        if (i != idx) { newList.add(snapshot[i]) }
                        i = i + 1
                    }
                    Hilog.info(0, "CjTelegram", "[BlacklistPage] Unblocked ${displayName}")
                    launch {
                        this.blockedUserList = newList
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[BlacklistPage] Failed to unblock ${displayName}")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[BlacklistPage] removeUnblockAt error: ${e}")
            }
        }
    }

    // === 频道封禁模式 ===

    private func loadBannedMembers(): Unit {
        if (this.channelId == 0) {
            launch { this.loadError = "No channel selected" }
            return
        }
        launch {
            this.isLoading = true
            this.loadError = ""
        }
        let cid = this.channelId
        let chash = this.channelAccessHash
        spawn {
            try {
                let svc = getPeersService()
                let bannedResult = svc.getBannedChannelParticipants(cid, chash, kicked: false)
                let kickedResult = svc.getBannedChannelParticipants(cid, chash, kicked: true)
                Hilog.info(0, "CjTelegram", "[BlacklistPage] Channel mode: banned=${bannedResult.participants.size} kicked=${kickedResult.participants.size}")
                let newBanned = ArrayList<BannedParticipantEntry>()
                for (e in bannedResult.participants) { newBanned.add(e) }
                let newKicked = ArrayList<BannedParticipantEntry>()
                for (e in kickedResult.participants) { newKicked.add(e) }
                launch {
                    this.bannedList = newBanned
                    this.kickedList = newKicked
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[BlacklistPage] loadBannedMembers error: ${e}")
                launch {
                    this.isLoading = false
                    this.loadError = "Failed to load members"
                }
            }
        }
    }

    private func removeBanAt(idx: Int64, fromKicked: Bool): Unit {
        let list = if (fromKicked) { this.kickedList } else { this.bannedList }
        if (idx < 0 || idx >= list.size) { return }
        let entry = list[idx]
        let userId = entry.userId
        let accessHash = entry.accessHash
        let displayName = entry.displayName
        let cid = this.channelId
        let chash = this.channelAccessHash
        let snapshot = ArrayList<BannedParticipantEntry>()
        for (e in list) { snapshot.add(e) }

        spawn {
            try {
                let svc = getPeersService()
                let rights = ChatBannedRights()
                rights.flags = 0
                rights.untilDate = 0
                let opResult = svc.editBanned(cid, chash, userId, accessHash, rights)
                if (opResult.success) {
                    let newList = ArrayList<BannedParticipantEntry>()
                    var i: Int64 = 0
                    while (i < snapshot.size) {
                        if (i != idx) { newList.add(snapshot[i]) }
                        i = i + 1
                    }
                    Hilog.info(0, "CjTelegram", "[BlacklistPage] Removed ban for ${displayName}")
                    launch {
                        if (fromKicked) {
                            this.kickedList = newList
                        } else {
                            this.bannedList = newList
                        }
                        getPeerInfoService().invalidateGroupFullInfo(cid)
                        notifyPeerInfoChanged()
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[BlacklistPage] Failed to remove ban for ${displayName}: ${opResult.errorCode}")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[BlacklistPage] removeBanAt error: ${e}")
            }
        }
    }

    // === 联系人黑名单 UI ===

    @Builder
    func buildBlockedUserRow(entry: BlockedUserEntry, idx: Int64) {
        Row {
            Column {
                Text(entry.data.getInitial())
                    .fontSize(18)
                    .fontColor(0xFFFFFF)
                    .fontWeight(FontWeight.Medium)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor(getAvatarColor(entry.data.userId))
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)

            Column {
                Text(if (entry.data.getDisplayName().size > 0) { entry.data.getDisplayName() } else { "Unknown" })
                    .fontSize(17)
                    .fontColor(0x000000)
                    .maxLines(1)
                Text(entry.data.getBlockedDateText())
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(top: 2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)

            Button(trSource("Unblock"))
                .fontSize(13)
                .fontColor(0xFF3B30)
                .backgroundColor(Color.Transparent)
                .borderWidth(1)
                .borderColor(0xFF3B30)
                .borderRadius(12)
                .height(26)
                .padding(left: 8, right: 8)
                .onClick({ _ =>
                    this.removeUnblockAt(idx)
                })
        }
        .width(100.percent)
        .height(64)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func buildBlockedUsersList() {
        if (this.blockedUserList.size == 0) {
            Column {
                Text("No blocked users")
                    .fontSize(16)
                    .fontColor(0x8E8E93)
            }
            .width(100.percent)
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(0xF2F2F7)
        } else {
            List {
                ForEach(this.blockedUserList, itemGenerator: { entry: BlockedUserEntry, idx: Int64 =>
                    ListItem {
                        this.buildBlockedUserRow(entry, idx)
                    }
                })
            }
            .layoutWeight(1)
            .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 72, endMargin: 0))
            .backgroundColor(0xFFFFFF)
        }
    }

    // === 频道封禁成员 UI ===

    @Builder
    func buildMemberRow(entry: BannedParticipantEntry, idx: Int64, fromKicked: Bool) {
        Row {
            Column {
                Text(entry.getInitial())
                    .fontSize(18)
                    .fontColor(0xFFFFFF)
                    .fontWeight(FontWeight.Medium)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor(getAvatarColor(entry.userId))
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)

            Column {
                Text(if (entry.displayName.size > 0) { entry.displayName } else { "Unknown" })
                    .fontSize(17)
                    .fontColor(0x000000)
                    .maxLines(1)
                Text(entry.getBanDescription())
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(top: 2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)

            Button(trSource("Unban"))
                .fontSize(13)
                .fontColor(0xFF3B30)
                .backgroundColor(Color.Transparent)
                .borderWidth(1)
                .borderColor(0xFF3B30)
                .borderRadius(12)
                .height(26)
                .padding(left: 8, right: 8)
                .onClick({ _ =>
                    this.removeBanAt(idx, fromKicked)
                })
        }
        .width(100.percent)
        .height(64)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func buildList(list: ArrayList<BannedParticipantEntry>, fromKicked: Bool) {
        if (list.size == 0) {
            Column {
                Text(if (fromKicked) { "No kicked members" } else { "No restricted members" })
                    .fontSize(16)
                    .fontColor(0x8E8E93)
            }
            .width(100.percent)
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(0xF2F2F7)
        } else {
            List {
                ForEach(list, itemGenerator: { entry: BannedParticipantEntry, idx: Int64 =>
                    ListItem {
                        this.buildMemberRow(entry, idx, fromKicked)
                    }
                })
            }
            .layoutWeight(1)
            .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 72, endMargin: 0))
            .backgroundColor(0xFFFFFF)
        }
    }

    public func build() {
        Column {
            // FIX-2: 标题使用 this.channelTitle（联系人模式="Blocked Users"，频道模式=频道名）
            Row {
                Text("\u{2190}")
                    .fontSize(20)
                    .fontColor(0x007AFF)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(this.channelTitle)
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                Blank().layoutWeight(1)
                if (this.isChannelMode) {
                    Button("+")
                        .fontSize(20)
                        .fontColor(0x007AFF)
                        .backgroundColor(Color.Transparent)
                        .width(40)
                        .height(40)
                        .onClick({ _ =>
                            Hilog.info(0, "CjTelegram", "[BlacklistPage] Add banned member tapped for channelId=${this.channelId}")
                        })
                } else {
                    Blank().width(40).height(40)
                }
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            // 双 Tab 仅频道模式显示
            if (this.isChannelMode) {
                Row {
                    Button("Restricted")
                        .fontSize(14)
                        .fontColor(if (this.selectedTab == 0) { 0xFFFFFF } else { 0x007AFF })
                        .backgroundColor(if (this.selectedTab == 0) { 0x007AFF } else { Color.Transparent })
                        .borderRadius(16)
                        .height(32)
                        .layoutWeight(1)
                        .onClick({ _ => this.selectedTab = 0 })
                    Button("Kicked")
                        .fontSize(14)
                        .fontColor(if (this.selectedTab == 1) { 0xFFFFFF } else { 0x007AFF })
                        .backgroundColor(if (this.selectedTab == 1) { 0x007AFF } else { Color.Transparent })
                        .borderRadius(16)
                        .height(32)
                        .layoutWeight(1)
                        .onClick({ _ => this.selectedTab = 1 })
                }
                .width(100.percent)
                .height(48)
                .padding(left: 16, right: 16, top: 8, bottom: 8)
                .backgroundColor(0xFFFFFF)
            }

            // 内容区：加载中 / 错误 / 列表
            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(32)
                        .height(32)
                        .color(0x007AFF)
                    Text(trSource("Loading..."))
                        .fontSize(14)
                        .fontColor(0x999999)
                        .margin(top: 8)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0xF2F2F7)
            } else if (this.loadError.size > 0) {
                Column {
                    Text(this.loadError)
                        .fontSize(15)
                        .fontColor(0xFF3B30)
                        .margin(bottom: 16)
                    Button(trSource("Retry"))
                        .fontSize(16)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(0x007AFF)
                        .width(120)
                        .height(40)
                        .borderRadius(20)
                        .onClick({ _ =>
                            if (this.isChannelMode) {
                                this.loadBannedMembers()
                            } else {
                                this.loadBlockedUsers()
                            }
                        })
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0xF2F2F7)
            } else if (this.isChannelMode) {
                // 频道封禁模式：双 Tab 内容
                if (this.selectedTab == 0) {
                    this.buildList(this.bannedList, false)
                } else {
                    this.buildList(this.kickedList, true)
                }
            } else {
                // 联系人黑名单模式：被屏蔽用户列表
                this.buildBlockedUsersList()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
