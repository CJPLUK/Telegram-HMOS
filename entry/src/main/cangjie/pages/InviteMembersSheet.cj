package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.bindings.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.interop.*
import std.collection.ArrayList
import std.convert.*
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * InviteMembersSheet — 群/频道加人页，对位 iOS「Add Users」：
 * 关闭 / 标题 / 确认按钮，搜索框，Invite via Link（展开 Copy / Share / QR），
 * 按首字母分区的 Telegram 联系人多选列表。路由参数 "{peerType}:{peerId}:{accessHash}:{isChannel}:{isGroupCall}"。
 */
// ---- 轻量 JSON 读取 / 转义（仅解析 interop 回传的扁平 result 对象）----
private func jsonBoolFieldInvite(json: String, key: String): Bool {
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(i) =>
            let rest = json[(i + needle.size)..json.size]
            match (rest.indexOf("true")) {
                case Some(t) =>
                    match (rest.indexOf("false")) {
                        case Some(f) => return t < f
                        case None => return true
                    }
                case None => return false
            }
        case None => return false
    }
}

private func jsonEscapeInvite(s: String): String {
    var result = ""
    for (ch in s.runes()) {
        if (ch == r'"') {
            result += "\\\""
        } else if (ch == r'\\') {
            result += "\\\\"
        } else {
            result += ch.toString()
        }
    }
    return result
}

// ---- 解析路由参数 ----
private func parseInviteMembersParam(raw: String): (String, Int64, Int64, Bool, Bool) {
    if (raw.size == 0) {
        return ("chat", 0, 0, false, false)
    }
    let parts = raw.split(":")
    var peerType = "chat"
    var peerId: Int64 = 0
    var accessHash: Int64 = 0
    var isChannel = false
    var isGroupCall = false
    if (parts.size >= 1) { peerType = parts[0] }
    if (parts.size >= 2) {
        try { peerId = Int64.parse(parts[1]) } catch (_: Exception) {}
    }
    if (parts.size >= 3) {
        try { accessHash = Int64.parse(parts[2]) } catch (_: Exception) {}
    }
    if (parts.size >= 4) { isChannel = parts[3] == "1" || parts[3] == "true" }
    if (parts.size >= 5) { isGroupCall = parts[4] == "1" || parts[4] == "true" }
    return (peerType, peerId, accessHash, isChannel, isGroupCall)
}


/** S2-72：GLOBAL SEARCH 分区里联系人行的 letter 标记（本地分区头都是单个首字母，不会撞）。 */
private let INVITE_GLOBAL_ROW_LETTER: String = "#global"

/** 联系人列表的一行：字母分区头或联系人 */
private class InviteListRow {
    public let letter: String
    public let contact: Option<ContactDisplayData>
    public init(letter: String, contact: Option<ContactDisplayData>) {
        this.letter = letter
        this.contact = contact
    }
    public func isSection(): Bool { contact.isNone() }
    public func contactOrEmpty(): ContactDisplayData {
        match (contact) {
            case Some(c) => c
            case None => ContactDisplayData()
        }
    }
}

/** 对位 iOS「Add Users」：关闭 / 标题 / 确认，搜索框，Invite via Link，按字母分区的多选联系人列表。 */
@HybridComponentEntry
@Component
public class InviteMembersSheet {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ---- 路由参数 ----
    @State var peerType: String = "chat"
    @State var peerId: Int64 = 0
    @State var peerAccessHash: Int64 = 0
    @State var isChannel: Bool = false
    @State var isGroupCall: Bool = false

    // ---- 邀请链接 ----
    @State var inviteLink: String = ""
    @State var isLoadingLink: Bool = true
    @State var linkError: String = ""
    @State var showLinkPanel: Bool = false
    @State var showQrExpanded: Bool = false
    @State var showCopied: Bool = false

    // ---- 联系人多选 ----
    @State var contacts: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    @State var selectedUserIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var searchText: String = ""
    // S2-72 (WP-E)：GLOBAL SEARCH 分区 —— iOS「Add Users」（ContactMultiselectionController，
    // ContactListNode.swift:1521 globalSearch）在本地联系人之后列出 contacts.search 的远端结果
    // （按用户名找人，含 Bot），本地联系人里已有的跳过。
    @State var globalResults: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    private var globalSearchGeneration: Int64 = 0
    // 勾选过的远端结果：换关键词后 globalResults 会被替换，确认时仍要能加进群。
    @State var globalPicked: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    @State var isLoadingContacts: Bool = false
    @State var isAddingMembers: Bool = false
    @State var addResult: String = ""

    @State var loaded: Bool = false
    private let listScroller: Scroller = Scroller()

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("InviteMembersSheet")
        let (pt, pid, aHash, isChan, isCall) = parseInviteMembersParam(raw)
        launch {
            this.peerType = pt
            this.peerId = pid
            this.peerAccessHash = aHash
            this.isChannel = isChan
            this.isGroupCall = isCall
        }
        if (pid > 0) { this.loadInviteLink(pt, pid) }
        this.loadContacts()
    }

    // ---- 加载邀请链接：优先复用已有的主链接，没有时才创建 ----
    private func loadInviteLink(pt: String, pid: Int64): Unit {
        if (pid == 0) {
            launch { this.isLoadingLink = false }
            return
        }
        launch { this.isLoadingLink = true }
        let _ = spawn {
            let svc = getInviteLinksService()
            var link = ""
            try {
                for (l in svc.getExportedChatInvites(pt, pid)) {
                    if (l.isPermanent && !l.isRevoked) { link = l.link; break }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[InviteMembersSheet] getExportedChatInvites failed: ${e}")
            }
            let finalLink = if (link.size > 0) { link } else { svc.exportChatInvite(pt, pid) }
            launch {
                this.isLoadingLink = false
                if (finalLink.size > 0) {
                    this.inviteLink = finalLink
                    this.linkError = ""
                } else {
                    this.linkError = "Failed to generate invite link"
                }
            }
        }
    }

    // ---- 复制链接 ----
    private func copyLink(): Unit {
        let link = this.inviteLink
        if (link.size == 0) { return }
        setClipboardText(link)
        Hilog.info(0, "CjTelegram", "[InviteMembersSheet] copyLink: ${link}")
        launch { this.showCopied = true }
        let _ = spawn {
            sleep(Duration.second * 2)
            launch { this.showCopied = false }
        }
    }

    // ---- 系统分享（Phase 3 反转：真实 @kit.ShareKit systemShare）----
    // iOS: UIActivityViewController({ link }); HarmonyOS: ArkTS ShareController.show（真实系统分享面板）。
    // 反转链路: callArkAsync(SHARE_LINK, {"url":link,"title":"Invite"}) → ShareLinkImpl.ets
    //   → systemShare.ShareController.show(getContext(), ...)。
    // ArkTS 侧需 UIAbilityContext；经 getContext() 取得（同 BackgroundPrivacyImpl 模式，可用）。
    // 结果 {"ok":bool}：ok=false（无 context / API 报错）时诚实降级 setClipboardText（文件既有降级路径）。
    // TODO(P3-share): 若真机验证 getContext() 在 interop 回调里拿不到 UIAbilityContext，
    //   ShareController.show 会走 ok:false → 自动落回下方 clipboard 降级（不 stub，行为保持非空）。
    private func shareLink(): Unit {
        let link = this.inviteLink
        if (link.size == 0) { return }
        let argJson = "{\"url\":\"${jsonEscapeInvite(link)}\",\"title\":\"Invite\"}"
        callArkAsync(SHARE_LINK, argJson, { res =>
            let ok = jsonBoolFieldInvite(res, "ok")
            Hilog.info(0, "CjTelegram", "[InviteMembersSheet] shareLink ArkTS systemShare ok=${ok}")
            if (!ok) {
                // 诚实降级：系统分享不可用时复制到剪贴板并提示（行为非空）。
                setClipboardText(link)
                launch { this.showCopied = true }
                let _ = spawn {
                    sleep(Duration.second * 2)
                    launch { this.showCopied = false }
                }
            }
        })
    }

    // ---- 加载 Telegram 联系人 ----
    private func loadContacts(): Unit {
        launch {
            this.isLoadingContacts = true
            this.contacts = ArrayList<ContactDisplayData>()
            this.selectedUserIds = ArrayList<Int64>()
        }
        let _ = spawn {
            let result = ArrayList<ContactDisplayData>()
            try {
                for (c in getRealContactService().getContacts()) {
                    if (!c.isBot && !c.isSelf && c.userId > 0) { result.add(c) }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[InviteMembersSheet] getContacts failed: ${e}")
            }
            launch {
                this.contacts = result
                this.isLoadingContacts = false
            }
        }
    }

    private func contactName(c: ContactDisplayData): String {
        let full = "${c.firstName} ${c.lastName}".trimAscii()
        if (full.size > 0) { return full }
        if (c.username.size > 0) { return "@${c.username}" }
        return c.phone
    }

    private func contactMatches(c: ContactDisplayData, q: String): Bool {
        if (q.size == 0) { return true }
        let hay = "${c.firstName} ${c.lastName} ${c.username} ${c.phone}".toAsciiLower()
        return hay.contains(q)
    }

    /** 搜索过滤后按首字母分区，展平成列表行；搜索中时末尾追加 GLOBAL SEARCH 分区（S2-72）。 */
    private func listRows(): ArrayList<InviteListRow> {
        let q = this.searchText.trimAscii().toAsciiLower()
        let filtered = ArrayList<ContactDisplayData>()
        for (c in this.contacts) {
            if (this.contactMatches(c, q)) { filtered.add(c) }
        }
        let rows = ArrayList<InviteListRow>()
        for (sec in buildContactsGroupedBySection(filtered)) {
            rows.add(InviteListRow(sec.letter, None))
            for (c in sec.contacts) { rows.add(InviteListRow(sec.letter, Some(c))) }
        }
        if (q.size > 0 && this.globalResults.size > 0) {
            // iOS ChatListSearchItemHeader .globalPeers → DialogList.SearchSectionGlobal 大写
            rows.add(InviteListRow(trSource("Global Search").toAsciiUpper(), None))
            for (c in this.globalResults) { rows.add(InviteListRow(INVITE_GLOBAL_ROW_LETTER, Some(c))) }
        }
        return rows
    }

    private func isLocalContact(userId: Int64): Bool {
        for (c in this.contacts) {
            if (c.userId == userId) { return true }
        }
        return false
    }

    /**
     * S2-72：远端搜索（contacts.search），对位 iOS ContactListNode.swift:1521-1528
     * searchRemotePeers 延迟 0.2 s、旧结果在加载期间保留；本地联系人已有的跳过，Bot 保留。
     */
    private func scheduleGlobalSearch(value: String): Unit {
        this.globalSearchGeneration = this.globalSearchGeneration + 1
        let generation = this.globalSearchGeneration
        let query = value.trimAscii()
        if (query.isEmpty()) {
            this.globalResults = ArrayList<ContactDisplayData>()
            return
        }
        let _ = spawn {
            sleep(Duration.millisecond * 200)
            if (generation != this.globalSearchGeneration) { return }
            var found = ArrayList<ContactDisplayData>()
            try {
                found = getRealContactService().searchRemoteUsers(query)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[InviteMembersSheet] searchRemoteUsers failed: ${e}")
            }
            let picked = found
            launch {
                if (generation == this.globalSearchGeneration) {
                    let entries = ArrayList<ContactDisplayData>()
                    for (c in picked) {
                        if (c.userId > 0 && !c.isSelf && !this.isLocalContact(c.userId)) { entries.add(c) }
                    }
                    Hilog.info(0, "CjTelegram", "[InviteMembersSheet] global search '${query}' → ${entries.size} results")
                    this.globalResults = entries
                }
            }
        }
    }

    /** 勾选远端结果时留一份，确认加人时与本地联系人合并（S2-72）。 */
    private func rememberGlobalPick(userId: Int64): Unit {
        for (p in this.globalPicked) {
            if (p.userId == userId) { return }
        }
        for (c in this.globalResults) {
            if (c.userId == userId) {
                let newList = ArrayList<ContactDisplayData>()
                newList.add(all: this.globalPicked)
                newList.add(c)
                launch { this.globalPicked = newList }
                return
            }
        }
    }

    /** 确认时的候选池：本地联系人 + 勾选过的远端结果（按 userId 去重）。 */
    private func candidatePool(): ArrayList<ContactDisplayData> {
        let pool = ArrayList<ContactDisplayData>()
        pool.add(all: this.contacts)
        for (p in this.globalPicked) {
            if (!this.isLocalContact(p.userId)) { pool.add(p) }
        }
        return pool
    }

    private func indexLetters(): Array<String> {
        let letters = ArrayList<String>()
        for (row in this.listRows()) {
            if (row.isSection()) { letters.add(row.letter) }
        }
        return letters.toArray()
    }

    private func scrollToLetter(idx: Int64): Unit {
        let letters = this.indexLetters()
        if (idx < 0 || idx >= Int64(letters.size)) { return }
        let rows = this.listRows()
        var i: Int64 = 0
        while (i < rows.size) {
            if (rows[i].isSection() && rows[i].letter == letters[idx]) {
                try {
                    this.listScroller.scrollToIndex(Int32(i), smooth: false, align: ScrollAlign.Start)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[InviteMembersSheet] scrollToIndex failed: ${e}")
                }
                return
            }
            i = i + 1
        }
    }

    // ---- 选中状态 ----
    private func toggleContact(userId: Int64): Unit {
        let newList = ArrayList<Int64>()
        var found = false
        for (id in this.selectedUserIds) {
            if (id == userId) { found = true } else { newList.add(id) }
        }
        if (!found) {
            newList.add(userId)
            this.rememberGlobalPick(userId)
        }
        launch { this.selectedUserIds = newList }
    }

    private func isSelected(userId: Int64): Bool {
        for (id in this.selectedUserIds) {
            if (id == userId) { return true }
        }
        return false
    }

    private func showResult(msg: String): Unit {
        launch { this.addResult = msg }
        let _ = spawn {
            sleep(Duration.second * 2)
            launch { this.addResult = "" }
        }
    }

    // ---- 确认：把选中的联系人加入群 ----
    private func doAddMembers(): Unit {
        if (this.isAddingMembers || this.selectedUserIds.isEmpty()) { return }
        let pid = this.peerId
        let isChan = this.isChannel
        let aHash = this.peerAccessHash
        let ids = this.selectedUserIds
        // S2-72：候选池含勾选过的 GLOBAL SEARCH 结果（Bot 等非联系人）
        let allContacts = this.candidatePool()

        launch { this.isAddingMembers = true }
        let _ = spawn {
            let svc = getPeersService()
            let counters = ArrayList<Int32>([0])
            let errors = ArrayList<String>()
            for (c in allContacts) {
                var picked = false
                for (id in ids) { if (id == c.userId) { picked = true } }
                if (!picked) { continue }
                let result = if (isChan) {
                    svc.inviteToChannel(pid, aHash, c.userId, c.accessHash)
                } else {
                    svc.addGroupMember(pid, c.userId, c.accessHash)
                }
                if (result.success) { counters[0] = counters[0] + 1 } else { errors.add(result.errorCode) }
            }
            let successCount = counters[0]
            launch {
                this.isAddingMembers = false
                if (successCount > 0) {
                    getPeerInfoService().invalidateGroupFullInfo(pid)
                    notifyPeerInfoChanged()
                    routerPop()
                } else if (errors.size > 0) {
                    this.showResult("Failed: ${errors[errors.size - 1]}")
                } else {
                    this.showResult("No members were added")
                }
            }
        }
    }

    // ---- 圆形工具按钮（关闭 / 确认）----
    // 确认按钮的高亮态在 builder 内读状态（@Builder 参数只在首次构建时求值）
    private func confirmActive(): Bool { this.selectedUserIds.size > 0 }

    @Builder
    func circleButton(isConfirm: Bool, action: () -> Unit) {
        Stack(alignContent: Alignment.Center) {
            if (isConfirm) {
                Image(@r(app.media.callui_ic_check))
                    .width(18)
                    .height(18)
                    .fillColor(if (this.confirmActive()) { 0xFFFFFFFF } else { 0xFF000000 })
            } else {
                Image(@r(app.media.nav_ic_close))
                    .width(18)
                    .height(18)
                    .fillColor(0xFF000000)
            }
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(if (isConfirm && this.confirmActive()) { 0xFF007AFF } else { 0xFFEFEFF4 })
        .onClick({ _evt => action() })
    }

    @Builder
    func linkActionPill(label: String, action: () -> Unit) {
        Text(label)
            .fontSize(15)
            .fontColor(0xFF007AFF)
            .padding(left: 16, right: 16, top: 8, bottom: 8)
            .backgroundColor(0xFFE8F1FF)
            .borderRadius(16)
            .onClick({ _evt => action() })
    }

    /** 远端结果行的副标题：iOS 全局搜索行显示 @username（ContactListPage.globalResultSubtitle 同法）。 */
    private func rowSubtitle(c: ContactDisplayData, isGlobal: Bool): String {
        if (isGlobal && c.username.size > 0) { return "@${c.username}" }
        return c.getLastSeenText()
    }

    @Builder
    func contactRow(c: ContactDisplayData, isGlobal: Bool) {
        Column {
            Row {
                Stack(alignContent: Alignment.Center) {
                    if (this.isSelected(c.userId)) {
                        Image(@r(app.media.callui_ic_check))
                            .width(14)
                            .height(14)
                            .fillColor(0xFFFFFFFF)
                    }
                }
                .width(22)
                .height(22)
                .backgroundColor(if (this.isSelected(c.userId)) { 0xFF007AFF } else { Color.Transparent })
                .border(width: 1.5, color: if (this.isSelected(c.userId)) { 0xFF007AFF } else { 0xFFC7C7CC }, radius: 11)
                .margin(right: 12)

                Avatar(
                    avatarUrl: getUserPhotoService().getUserPhotoPath(c.userId),
                    displayName: this.contactName(c),
                    avatarSize: 40,
                    peerId: c.userId
                )

                Column {
                    Row {
                        if (c.firstName.size > 0) {
                            Text(c.firstName)
                                .fontSize(17)
                                .fontColor(0xFF000000)
                                .maxLines(1)
                                .textOverflow(TextOverflow.Ellipsis)
                        }
                        if (c.lastName.size > 0) {
                            Text(if (c.firstName.size > 0) { " ${c.lastName}" } else { c.lastName })
                                .fontSize(17)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFF000000)
                                .maxLines(1)
                                .textOverflow(TextOverflow.Ellipsis)
                        }
                        if (c.firstName.size == 0 && c.lastName.size == 0) {
                            Text(this.contactName(c))
                                .fontSize(17)
                                .fontColor(0xFF000000)
                                .maxLines(1)
                        }
                    }
                    Text(this.rowSubtitle(c, isGlobal))
                        .fontSize(14)
                        .fontColor(if (c.isOnline && !isGlobal) { 0xFF007AFF } else { 0xFF8E8E93 })
                        .maxLines(1)
                        .margin(top: 2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin(left: 12)
            }
            .width(100.percent)
            .height(60)
            .padding(left: 16, right: 40)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt => this.toggleContact(c.userId) })

            Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 102)
        }
        .width(100.percent)
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Column {
                // ---- 标题栏：关闭 / Add Users / 确认 ----
                Row {
                    this.circleButton(false, { => routerPop() })
                    Blank().layoutWeight(1)
                    Text(trSource("Add Users"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFF000000)
                    Blank().layoutWeight(1)
                    if (this.isAddingMembers) {
                        LoadingProgress().width(28).height(28).color(0xFF007AFF)
                    } else {
                        this.circleButton(true, { => this.doAddMembers() })
                    }
                }
                .width(100.percent)
                .height(56)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)

                // ---- 搜索框 ----
                TextInput(text: this.searchText, placeholder: trSource("Search for contacts or usernames"))
                    .fontSize(17)
                    .fontColor(0xFF000000)
                    .placeholderColor(0xFF8E8E93)
                    .backgroundColor(0xFFEFEFF4)
                    .height(40)
                    .borderRadius(20)
                    .width(92.percent)
                    .margin(top: 4, bottom: 8)
                    .onChange({ value: String =>
                        this.searchText = value
                        this.scheduleGlobalSearch(value)
                    })

                // ---- Invite via Link ----
                Row {
                    Image(@r(app.media.chatroom_ic_link))
                        .width(24)
                        .height(24)
                        .fillColor(0xFF007AFF)
                        .margin(right: 16)
                    Text(if (this.isChannel) { "Invite to Channel via Link" } else { "Invite to Group via Link" })
                        .fontSize(17)
                        .fontColor(0xFF007AFF)
                }
                .width(100.percent)
                .height(48)
                .padding(left: 20, right: 16)
                .alignItems(VerticalAlign.Center)
                .onClick({ _evt => launch { this.showLinkPanel = !this.showLinkPanel } })

                if (this.showLinkPanel) {
                    Column {
                        if (this.isLoadingLink) {
                            Row {
                                LoadingProgress().width(18).height(18).color(0xFF007AFF)
                                Text("Generating invite link...")
                                    .fontSize(14)
                                    .fontColor(0xFF8E8E93)
                                    .margin(left: 8)
                            }
                            .alignItems(VerticalAlign.Center)
                        } else if (this.linkError.size > 0) {
                            Text(this.linkError).fontSize(14).fontColor(0xFFFF3B30)
                        } else {
                            Text(this.inviteLink)
                                .fontSize(15)
                                .fontColor(0xFF007AFF)
                                .maxLines(1)
                                .textOverflow(TextOverflow.Ellipsis)
                                .width(100.percent)
                            Row(space: 10.0) {
                                this.linkActionPill(if (this.showCopied) { "Copied" } else { "Copy" }, { => this.copyLink() })
                                this.linkActionPill("Share", { => this.shareLink() })
                                this.linkActionPill(if (this.showQrExpanded) { "Hide QR" } else { "QR Code" }, { =>
                                    launch { this.showQrExpanded = !this.showQrExpanded }
                                })
                            }
                            .margin(top: 10)
                            if (this.showQrExpanded && this.inviteLink.size > 0) {
                                QRCode(this.inviteLink)
                                    .width(180)
                                    .height(180)
                                    .color(0xFF000000)
                                    .margin(top: 12)
                            }
                        }
                    }
                    .width(92.percent)
                    .padding(12)
                    .backgroundColor(0xFFF7F7F7)
                    .borderRadius(12)
                    .alignItems(HorizontalAlign.Start)
                    .margin(bottom: 8)
                }

                // ---- 联系人列表 ----
                if (this.isLoadingContacts) {
                    Column {
                        LoadingProgress().width(36).height(36).color(0xFF007AFF)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                } else {
                    Stack(alignContent: Alignment.End) {
                        List(scroller: this.listScroller) {
                            ForEach(this.listRows(), itemGenerator: { row: InviteListRow, _idx: Int64 =>
                                ListItem {
                                    if (row.isSection()) {
                                        Text(row.letter)
                                            .fontSize(14)
                                            .fontColor(0xFF8E8E93)
                                            .width(100.percent)
                                            .padding(left: 16, top: 10, bottom: 4)
                                    } else {
                                        this.contactRow(row.contactOrEmpty(), row.letter == INVITE_GLOBAL_ROW_LETTER)
                                    }
                                }
                            })
                            ListItem {
                                Column {}.height(getSafeAreaBottom() + 16.0)
                            }
                        }
                        .width(100.percent)
                        .height(100.percent)
                        .scrollBar(BarState.Off)

                        if (this.searchText.trimAscii().size == 0 && this.contacts.size > 0) {
                            AlphabetIndexer(arrayValue: this.indexLetters(), selected: UInt32(0))
                                .color(0xFF007AFF)
                                .onSelect({ index: Int64 => this.scrollToLetter(index) })
                        }
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                }
            }
            .width(100.percent)
            .height(100.percent)
            .padding(top: getSafeAreaTop())
            .backgroundColor(0xFFFFFFFF)
            .alignItems(HorizontalAlign.Center)

            if (this.addResult.size > 0) {
                Column {
                    Text(this.addResult)
                        .fontSize(14)
                        .fontColor(0xFFFFFFFF)
                        .padding(left: 16, right: 16, top: 10, bottom: 10)
                        .backgroundColor(0xCC000000)
                        .borderRadius(8)
                }
                .width(100.percent)
                .position(x: 0, y: getSafeAreaTop() + 70.0)
                .alignItems(HorizontalAlign.Center)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }
}
