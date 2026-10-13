package ohos_app_cangjie_entry.pages

/**
 * ChatFolderEditPage — 聊天文件夹编辑器（S029）+ 添加聊天选择器（S030）
 *
 * iOS 对位：ChatListFilterPresetController（名称 / 包含的聊天 / 排除的聊天 / 删除）
 *          ChatListFilterAddChatsController（聊天类型 + 会话多选，本页以全屏子视图承载）
 *
 * 路由参数（takePending("ChatFolderEditPage")）："<folderId>|<newId>"
 *   folderId >= 1 → 编辑已有文件夹（从 RealChatListService.getDialogFilters() 缓存取）
 *   folderId  < 1 → 新建，使用 newId（ChatFoldersPage.allocFolderId 预分配）
 *
 * 持久化：ChatFolderLinksService.updateDialogFilter（messages.updateDialogFilter#1ad4a04a，
 *   dialogFilter#aa472651 含布尔位/emoticon/pinned/include/exclude 向量）
 *   成功后回写文件夹缓存、刷新会话列表 tab（ChatListVM.loadFilters）并经
 *   notifyChatFolderEdited() 通知 ChatFoldersPage 重读（NavDestination 返回不重触发 onAppear）。
 *
 * 线程：网络调用一律 spawn{}，@State 回写 launch{}（S-001）。
 */

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.convert.*
import ohos_app_cangjie_entry.models.ChatFolder
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.services.getChatFolderLinksService
import ohos_app_cangjie_entry.services.getRealChatListService
import ohos_app_cangjie_entry.services.showToast
import ohos_app_cangjie_entry.viewmodels.getChatListVM
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

// 编辑完成回调：ChatFoldersPage 在 ensureLoaded 注册，编辑器保存/删除成功后触发
private var _chatFolderEditCallback: Option<() -> Unit> = None

public func registerChatFolderEditCallback(handler: () -> Unit): Unit {
    _chatFolderEditCallback = Some(handler)
}

public func notifyChatFolderEdited(): Unit {
    match (_chatFolderEditCallback) {
        case Some(h) => h()
        case None => ()
    }
}

/** 会话列表缓存中 peer 的展示名（chat 标题 / 用户姓名 / @username / #id） */
public func folderPeerDisplayName(id: Int64): String {
    let cl = getRealChatListService()
    match (cl.getCachedChat(id)) {
        case Some(c) => return c.title
        case None => ()
    }
    match (cl.getCachedUser(id)) {
        case Some(u) =>
            let n = "${u.firstName} ${u.lastName}".trimAscii()
            if (n.size > 0) { return n }
            if (u.username.size > 0) { return "@${u.username}" }
        case None => ()
    }
    return "#${id}"
}

@HybridComponentEntry
@Component
public class ChatFolderEditPage {
    @State var loaded: Bool = false
    @State var folderId: Int32 = -1
    @State var isNew: Bool = true
    @State var name: String = ""
    @State var includeContacts: Bool = false
    @State var includeNonContacts: Bool = false
    @State var includeGroups: Bool = false
    @State var includeChannels: Bool = false
    @State var includeBots: Bool = false
    @State var excludeMuted: Bool = false
    @State var excludeRead: Bool = false
    @State var excludeArchived: Bool = false
    @State var includeIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var excludeIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var pinnedIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var emoticon: String = ""
    @State var color: Int32 = 0
    @State var hasColor: Bool = false

    // 添加聊天选择器（S030）："" 关闭 / "include" / "exclude"
    @State var pickerMode: String = ""
    @State var pickerChats: ArrayList<Chat> = ArrayList<Chat>()
    @State var pickerSelected: ArrayList<Int64> = ArrayList<Int64>()

    @State var isSaving: Bool = false
    @State var showDeleteConfirm: Bool = false
    @State var errorText: String = ""

    // ==================== 加载 ====================

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("ChatFolderEditPage")
        let param = if (raw == "{}") { "" } else { raw }
        var fid: Int32 = -1
        var newId: Int32 = 0
        let parts = param.split("|")
        if (parts.size >= 1) {
            try { fid = Int32.parse(parts[0].trimAscii()) } catch (_: Exception) { () }
        }
        if (parts.size >= 2) {
            try { newId = Int32.parse(parts[1].trimAscii()) } catch (_: Exception) { () }
        }
        if (fid >= 1) {
            for (f in getRealChatListService().getDialogFilters()) {
                if (f.id == fid) {
                    this.applyFolder(f)
                    this.isNew = false
                    break
                }
            }
            if (this.isNew) {
                // 缓存里没有该 id：按新建处理但沿用 id
                this.folderId = fid
            }
        } else {
            this.folderId = if (newId >= 2) { newId } else { 2 }
            this.isNew = true
        }
        Hilog.info(0, "CjTelegram", "[ChatFolderEditPage] loaded folderId=${this.folderId} isNew=${this.isNew}")
    }

    private func applyFolder(f: ChatFolder): Unit {
        this.folderId = f.id
        this.name = f.name
        this.includeContacts = f.includeContacts
        this.includeNonContacts = f.includeNonContacts
        this.includeGroups = f.includeGroups
        this.includeChannels = f.includeChannels
        this.includeBots = f.includeBots
        this.excludeMuted = f.excludeMuted
        this.excludeRead = f.excludeRead
        this.excludeArchived = f.excludeArchived
        this.emoticon = f.emoticon
        this.color = f.color
        this.hasColor = f.hasColor
        let inc = ArrayList<Int64>()
        for (id in f.includePeers) { inc.add(id) }
        this.includeIds = inc
        let exc = ArrayList<Int64>()
        for (id in f.excludePeers) { exc.add(id) }
        this.excludeIds = exc
        let pin = ArrayList<Int64>()
        for (id in f.pinnedPeers) { pin.add(id) }
        this.pinnedIds = pin
    }

    private func buildFolder(): ChatFolder {
        let f = ChatFolder()
        f.id = this.folderId
        f.name = this.name
        f.icon = if (this.emoticon.size > 0) { this.emoticon } else { "📁" }
        f.filterType = "custom"
        f.includeContacts = this.includeContacts
        f.includeNonContacts = this.includeNonContacts
        f.includeGroups = this.includeGroups
        f.includeChannels = this.includeChannels
        f.includeBots = this.includeBots
        f.excludeMuted = this.excludeMuted
        f.excludeRead = this.excludeRead
        f.excludeArchived = this.excludeArchived
        f.emoticon = this.emoticon
        f.color = this.color
        f.hasColor = this.hasColor
        for (id in this.includeIds) { f.includePeers.add(id) }
        for (id in this.excludeIds) { f.excludePeers.add(id) }
        for (id in this.pinnedIds) { f.pinnedPeers.add(id) }
        return f
    }

    // ==================== 列表工具 ====================

    private func containsId(list: ArrayList<Int64>, id: Int64): Bool {
        for (x in list) {
            if (x == id) { return true }
        }
        return false
    }

    private func without(list: ArrayList<Int64>, id: Int64): ArrayList<Int64> {
        let r = ArrayList<Int64>()
        for (x in list) {
            if (x != id) { r.add(x) }
        }
        return r
    }

    private func hasAnyInclude(): Bool {
        return this.includeContacts || this.includeNonContacts || this.includeGroups ||
            this.includeChannels || this.includeBots || this.includeIds.size > 0
    }

    // ==================== 类型开关 ====================

    private func toggleFlag(key: String): Unit {
        if (key == "contacts") { this.includeContacts = !this.includeContacts }
        else if (key == "nonContacts") { this.includeNonContacts = !this.includeNonContacts }
        else if (key == "groups") { this.includeGroups = !this.includeGroups }
        else if (key == "channels") { this.includeChannels = !this.includeChannels }
        else if (key == "bots") { this.includeBots = !this.includeBots }
        else if (key == "muted") { this.excludeMuted = !this.excludeMuted }
        else if (key == "read") { this.excludeRead = !this.excludeRead }
        else if (key == "archived") { this.excludeArchived = !this.excludeArchived }
    }

    private func flagValue(key: String): Bool {
        if (key == "contacts") { return this.includeContacts }
        if (key == "nonContacts") { return this.includeNonContacts }
        if (key == "groups") { return this.includeGroups }
        if (key == "channels") { return this.includeChannels }
        if (key == "bots") { return this.includeBots }
        if (key == "muted") { return this.excludeMuted }
        if (key == "read") { return this.excludeRead }
        if (key == "archived") { return this.excludeArchived }
        return false
    }

    private func flagLabel(key: String): String {
        if (key == "contacts") { return "👤 联系人" }
        if (key == "nonContacts") { return "👥 非联系人" }
        if (key == "groups") { return "💬 群组" }
        if (key == "channels") { return "📢 频道" }
        if (key == "bots") { return "🤖 机器人" }
        if (key == "muted") { return "🔕 已静音" }
        if (key == "read") { return "✅ 已读" }
        if (key == "archived") { return "📦 已归档" }
        return key
    }

    private func includeKeys(): ArrayList<String> {
        let ks = ArrayList<String>()
        ks.add("contacts")
        ks.add("nonContacts")
        ks.add("groups")
        ks.add("channels")
        ks.add("bots")
        return ks
    }

    private func excludeKeys(): ArrayList<String> {
        let ks = ArrayList<String>()
        ks.add("muted")
        ks.add("read")
        ks.add("archived")
        return ks
    }

    /** 已启用的类型键（编辑器里只展示启用项，对齐 iOS 仅列出选中类别） */
    private func enabledKeys(keys: ArrayList<String>): ArrayList<String> {
        let r = ArrayList<String>()
        for (k in keys) {
            if (this.flagValue(k)) { r.add(k) }
        }
        return r
    }

    // ==================== 添加聊天选择器 ====================

    private func openPicker(mode: String): Unit {
        let sel = ArrayList<Int64>()
        let src = if (mode == "include") { this.includeIds } else { this.excludeIds }
        for (id in src) { sel.add(id) }
        this.pickerSelected = sel

        let chats = ArrayList<Chat>()
        match (getChatListVM()) {
            case Some(vm) =>
                for (c in vm.chatList) {
                    if (!this.hasChat(chats, c.id)) { chats.add(c) }
                }
                for (c in vm.archiveChatList) {
                    if (!this.hasChat(chats, c.id)) { chats.add(c) }
                }
            case None => ()
        }
        if (chats.size == 0) {
            for (c in getRealChatListService().getDialogsLocalFirst(limit: 100)) {
                if (!this.hasChat(chats, c.id)) { chats.add(c) }
            }
        }
        this.pickerChats = chats
        this.pickerMode = mode
    }

    private func hasChat(list: ArrayList<Chat>, id: Int64): Bool {
        for (c in list) {
            if (c.id == id) { return true }
        }
        return false
    }

    private func togglePickerChat(id: Int64): Unit {
        if (this.containsId(this.pickerSelected, id)) {
            this.pickerSelected = this.without(this.pickerSelected, id)
        } else {
            let r = ArrayList<Int64>()
            for (x in this.pickerSelected) { r.add(x) }
            r.add(id)
            this.pickerSelected = r
        }
    }

    private func commitPicker(): Unit {
        let chosen = ArrayList<Int64>()
        for (x in this.pickerSelected) { chosen.add(x) }
        if (this.pickerMode == "include") {
            this.includeIds = chosen
            // iOS：同一 peer 不能同时在包含与排除里
            var exc = this.excludeIds
            for (id in chosen) { exc = this.without(exc, id) }
            this.excludeIds = exc
        } else {
            this.excludeIds = chosen
            var inc = this.includeIds
            for (id in chosen) { inc = this.without(inc, id) }
            this.includeIds = inc
        }
        this.pickerMode = ""
    }

    // ==================== 保存 / 删除 ====================

    private func updateFolderCache(folder: ChatFolder): Unit {
        let cl = getRealChatListService()
        let cur = cl.getDialogFilters()
        let next = ArrayList<ChatFolder>()
        var replaced = false
        for (f in cur) {
            if (f.id == folder.id) {
                next.add(folder)
                replaced = true
            } else {
                next.add(f)
            }
        }
        if (!replaced) { next.add(folder) }
        cl.replaceDialogFiltersCache(next)
    }

    private func removeFromFolderCache(id: Int32): Unit {
        let cl = getRealChatListService()
        let next = ArrayList<ChatFolder>()
        for (f in cl.getDialogFilters()) {
            if (f.id != id) { next.add(f) }
        }
        cl.replaceDialogFiltersCache(next)
    }

    private func refreshChatListTabs(): Unit {
        match (getChatListVM()) {
            case Some(vm) => vm.loadFilters()
            case None => ()
        }
    }

    private func save(): Unit {
        if (this.isSaving) { return }
        let trimmed = this.name.trimAscii()
        if (trimmed.size == 0) {
            this.errorText = "请输入文件夹名称"
            return
        }
        if (!this.hasAnyInclude()) {
            this.errorText = "请至少添加一个聊天或聊天类型"
            return
        }
        this.errorText = ""
        this.isSaving = true
        this.name = trimmed
        let folder = this.buildFolder()
        let isNewCopy = this.isNew
        spawn {
            let ok = getChatFolderLinksService().updateDialogFilter(folder)
            Hilog.info(0, "CjTelegram", "[ChatFolderEditPage] save id=${folder.id} ok=${ok}")
            launch {
                this.isSaving = false
                if (ok) {
                    this.updateFolderCache(folder)
                    this.refreshChatListTabs()
                    showToast(if (isNewCopy) { "已创建文件夹「${folder.name}」" } else { "已保存文件夹「${folder.name}」" })
                    notifyChatFolderEdited()
                    routerPop()
                } else {
                    this.errorText = "保存失败，请重试"
                }
            }
        }
    }

    private func deleteFolder(): Unit {
        if (this.isSaving) { return }
        this.isSaving = true
        let fid = this.folderId
        spawn {
            let ok = getChatFolderLinksService().deleteDialogFilter(fid)
            Hilog.info(0, "CjTelegram", "[ChatFolderEditPage] delete id=${fid} ok=${ok}")
            launch {
                this.isSaving = false
                this.showDeleteConfirm = false
                if (ok) {
                    this.removeFromFolderCache(fid)
                    this.refreshChatListTabs()
                    showToast("已删除文件夹")
                    notifyChatFolderEdited()
                    routerPop()
                } else {
                    this.errorText = "删除失败，请重试"
                }
            }
        }
    }

    // ==================== UI 片段 ====================

    @Builder
    func sectionHeader(title: String) {
        Text(title)
            .fontSize(13)
            .fontColor(0x8E8E93)
            .width(100.percent)
            .padding(left: 32, top: 18, bottom: 6)
    }

    @Builder
    func addChatsRow(mode: String) {
        Row {
            Text("＋")
                .fontSize(20)
                .fontColor(0x317AFF)
                .margin(right: 12)
            Text("添加聊天")
                .fontSize(16)
                .fontColor(0x317AFF)
                .layoutWeight(1)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 12)
        .backgroundColor(0xFFFFFF)
        .onClick({ _ => this.openPicker(mode) })
    }

    @Builder
    func typeRow(key: String) {
        Row {
            Text(this.flagLabel(key))
                .fontSize(16)
                .fontColor(0x000000)
                .layoutWeight(1)
            Text("移除")
                .fontSize(14)
                .fontColor(0xFF3B30)
                .onClick({ _ => this.toggleFlag(key) })
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 12)
        .backgroundColor(0xFFFFFF)
    }

    @Builder
    func peerRow(id: Int64, mode: String) {
        Row {
            Text(folderPeerDisplayName(id))
                .fontSize(16)
                .fontColor(0x000000)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
            Text("移除")
                .fontSize(14)
                .fontColor(0xFF3B30)
                .onClick({ _ =>
                    if (mode == "include") {
                        this.includeIds = this.without(this.includeIds, id)
                    } else {
                        this.excludeIds = this.without(this.excludeIds, id)
                    }
                })
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 12)
        .backgroundColor(0xFFFFFF)
    }

    @Builder
    func pickerTypeRow(key: String) {
        Row {
            Text(this.flagLabel(key))
                .fontSize(16)
                .fontColor(0x000000)
                .layoutWeight(1)
            if (this.flagValue(key)) {
                Text("✓")
                    .fontSize(18)
                    .fontColor(0x317AFF)
            }
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 12)
        .backgroundColor(0xFFFFFF)
        .onClick({ _ => this.toggleFlag(key) })
    }

    @Builder
    func pickerChatRow(c: Chat) {
        Row {
            Text(c.avatarText)
                .fontSize(14)
                .fontColor(0xFFFFFF)
                .width(36)
                .height(36)
                .borderRadius(18)
                .backgroundColor(c.avatarColor)
                .textAlign(TextAlign.Center)
                .margin(right: 12)
            Text(c.name)
                .fontSize(16)
                .fontColor(0x000000)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
            if (this.containsId(this.pickerSelected, c.id)) {
                Text("✓")
                    .fontSize(18)
                    .fontColor(0x317AFF)
            }
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 8, bottom: 8)
        .backgroundColor(0xFFFFFF)
        .onClick({ _ => this.togglePickerChat(c.id) })
    }

    @Builder
    func pickerView() {
        Column {
            Row {
                Text("取消")
                    .fontSize(16)
                    .fontColor(0x317AFF)
                    .onClick({ _ => this.pickerMode = "" })
                Blank().layoutWeight(1)
                Text("添加聊天")
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                Blank().layoutWeight(1)
                Text("完成")
                    .fontSize(16)
                    .fontColor(0x317AFF)
                    .onClick({ _ => this.commitPicker() })
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            List {
                ListItem {
                    this.sectionHeader("聊天类型")
                }
                if (this.pickerMode == "include") {
                    ForEach(this.includeKeys(), itemGeneratorFunc: { key: String, _idx: Int64 =>
                        ListItem { this.pickerTypeRow(key) }
                    }, keyGeneratorFunc: { key: String, _idx: Int64 => "pt_" + key })
                } else {
                    ForEach(this.excludeKeys(), itemGeneratorFunc: { key: String, _idx: Int64 =>
                        ListItem { this.pickerTypeRow(key) }
                    }, keyGeneratorFunc: { key: String, _idx: Int64 => "pt_" + key })
                }
                ListItem {
                    this.sectionHeader("聊天")
                }
                ForEach(this.pickerChats, itemGeneratorFunc: { c: Chat, _idx: Int64 =>
                    ListItem { this.pickerChatRow(c) }
                }, keyGeneratorFunc: { c: Chat, _idx: Int64 => "pc_" + c.id.toString() })
                ListItem {
                    Row {}.width(100.percent).height(40)
                }
            }
            .width(100.percent)
            .layoutWeight(1)
            .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xE5E5EA, startMargin: 16, endMargin: 0))
        }
        .width(100.percent)
        .height(100.percent)
    }

    @Builder
    func editorView() {
        Column {
            Row {
                Text("取消")
                    .fontSize(16)
                    .fontColor(0x317AFF)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(if (this.isNew) { "新建文件夹" } else { "编辑文件夹" })
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                Blank().layoutWeight(1)
                Text(if (this.isSaving) { "保存中…" } else { "保存" })
                    .fontSize(16)
                    .fontColor(if (this.isSaving) { 0xC7C7CC } else { 0x317AFF })
                    .onClick({ _ => this.save() })
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    this.sectionHeader("文件夹名称")
                    TextInput(text: this.name, placeholder: "文件夹名称")
                        .onChange({ v: String => this.name = v })
                        .width(100.percent)
                        .height(44)
                        .fontSize(16)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(0)
                        .padding(left: 16, right: 16)

                    if (this.errorText.size > 0) {
                        Text(this.errorText)
                            .fontSize(13)
                            .fontColor(0xFF3B30)
                            .width(100.percent)
                            .padding(left: 32, top: 6)
                    }

                    this.sectionHeader("包含的聊天")
                    Column {
                        this.addChatsRow("include")
                        ForEach(this.enabledKeys(this.includeKeys()), itemGeneratorFunc: { key: String, _idx: Int64 =>
                            this.typeRow(key)
                        }, keyGeneratorFunc: { key: String, _idx: Int64 => "it_" + key })
                        ForEach(this.includeIds, itemGeneratorFunc: { id: Int64, _idx: Int64 =>
                            this.peerRow(id, "include")
                        }, keyGeneratorFunc: { id: Int64, _idx: Int64 => "ip_" + id.toString() })
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                    Text("选择要在此文件夹中显示的聊天或聊天类型。")
                        .fontSize(12)
                        .fontColor(0x8E8E93)
                        .width(100.percent)
                        .padding(left: 32, right: 32, top: 6)

                    this.sectionHeader("排除的聊天")
                    Column {
                        this.addChatsRow("exclude")
                        ForEach(this.enabledKeys(this.excludeKeys()), itemGeneratorFunc: { key: String, _idx: Int64 =>
                            this.typeRow(key)
                        }, keyGeneratorFunc: { key: String, _idx: Int64 => "et_" + key })
                        ForEach(this.excludeIds, itemGeneratorFunc: { id: Int64, _idx: Int64 =>
                            this.peerRow(id, "exclude")
                        }, keyGeneratorFunc: { id: Int64, _idx: Int64 => "ep_" + id.toString() })
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                    Text("选择不在此文件夹中显示的聊天或聊天类型。")
                        .fontSize(12)
                        .fontColor(0x8E8E93)
                        .width(100.percent)
                        .padding(left: 32, right: 32, top: 6)

                    if (!this.isNew) {
                        Blank().height(24)
                        Column {
                            Text("删除文件夹")
                                .fontSize(16)
                                .fontColor(0xFF3B30)
                                .width(100.percent)
                                .textAlign(TextAlign.Center)
                                .padding(top: 12, bottom: 12)
                                .onClick({ _ => this.showDeleteConfirm = !this.showDeleteConfirm })
                            if (this.showDeleteConfirm) {
                                Row {
                                    Text("确认删除")
                                        .fontSize(15)
                                        .fontColor(0xFFFFFF)
                                        .padding(left: 18, right: 18, top: 8, bottom: 8)
                                        .backgroundColor(0xFF3B30)
                                        .borderRadius(8)
                                        .onClick({ _ => this.deleteFolder() })
                                    Text("取消")
                                        .fontSize(15)
                                        .fontColor(0x317AFF)
                                        .margin(left: 16)
                                        .onClick({ _ => this.showDeleteConfirm = false })
                                }
                                .width(100.percent)
                                .justifyContent(FlexAlign.Center)
                                .padding(bottom: 12)
                            }
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
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
    }

    public func build() {
        Column {
            if (this.pickerMode.size > 0) {
                this.pickerView()
            } else {
                this.editorView()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
