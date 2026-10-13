package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.resource.__GenerateResource__
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
/** ArkTS 图库网格占位块 id（OverlayGeometry 主动重量用） */
let ATTACH_GRID_SLOT_ID = "cj_attach_grid_slot"


/**
 * AttachmentPanel — 附件 sheet（对位 iOS AttachmentController + AttachmentPanel）
 *
 * iOS 形态：点回形针弹出一张 sheet，底部是横向按钮条（AttachmentPanel.swift），
 * 按钮条上方是**当前页签的内容**，切页签只换内容、sheet 与按钮条不动：
 *   Gallery  → MediaPickerScreen 三列图库网格（首格相机）
 *   File     → AttachmentFileController：Select from Gallery / Select from Files + Recently Sent Files
 *   Location → LocationPickerController：地图 + 发送当前位置 / 实时位置 + OR CHOOSE A PLACE
 *   Poll     → 投票创建器
 *   Audio    → AttachmentFileController(audio)：Select from Files + Chats Music
 *   Contact  → ContactSelectionController：联系人列表 + 搜索
 * 按钮集合与顺序对位 ChatControllerOpenAttachmentMenu.swift:233-248（Gift/Checklist 依赖
 * Premium/待办能力，按用户指定剔除）：Gallery · File · Location · Poll(群/频道) · Audio · Contact。
 *
 * 分层：
 *   - 图库网格：读系统图库需受限权限 READ_IMAGEVIDEO（本仓 profile 装不上），改用免权限的
 *     PhotoPickerComponent，只能在 ArkTS 侧渲染；本组件留透明占位块并用 onAreaChange 报全局
 *     几何，宿主推给壳层覆盖层（与表情/贴纸网格同构）。
 *   - 投票：ComposePollScreenComponent 在 pages 包，components 不能反向依赖；同样以占位块
 *     报几何，由宿主 ChatRoomPage 在同一 Stack 里按几何叠放。
 *   - File/Audio/Contact 列表数据由本组件直接调 services 拉取；Location 页签嵌入
 *     LocationPicker(embedded)。所有「发送」动作经回调交给宿主。
 *
 * 按钮样式：30×30 模板图标 + 10pt 标题，按钮 69×49，未选中 0x959595 / 选中 accent 0x0088FF
 * （DefaultDayPresentationTheme.swift:436-439，AttachmentPanel.swift:35-39/280-331）。
 */

// iOS rootController.tabBar 主题色
let ATTACH_ICON_COLOR: Int64 = 0xFF959595
let ATTACH_TITLE_COLOR: Int64 = 0xCC000000
let ATTACH_ICON_SELECTED: Int64 = 0xFF0088FF
let ATTACH_TITLE_SELECTED: Int64 = 0xFF0088FF
let ATTACH_PANEL_BG: Int64 = 0xFFF7F7F7
let ATTACH_SHEET_BG: Int64 = 0xFFF2F2F7
let ATTACH_SEPARATOR_COLOR: Int64 = 0xFFB2B2B2
let ATTACH_SCRIM_COLOR: Int64 = 0x33000000
let ATTACH_ACCENT: Int64 = 0xFF007AFF

// iOS legacy 按钮尺寸：88×49；>5 个按钮（竖屏）收窄到 smallButtonWidth = 69
let ATTACH_BUTTON_W: Float64 = 69.0
let ATTACH_BUTTON_H: Float64 = 49.0
let ATTACH_HEADER_H: Float64 = 44.0
let ATTACH_GRABBER_H: Float64 = 20.0

func attachOptLenVp(v: ?Length): Float64 {
    match (v) {
        case Some(l) => l.value
        case None => 0.0
    }
}

func attachStatusText(c: ContactDisplayData): String {
    if (c.isOnline || c.statusType == "online") { return "online" }
    if (c.statusType == "recently") { return "last seen recently" }
    if (c.statusType == "lastWeek") { return "last seen within a week" }
    if (c.statusType == "lastMonth") { return "last seen within a month" }
    if (c.statusType == "offline" && c.wasOnline > 0) { return "last seen recently" }
    return "last seen a long time ago"
}

func attachInitials(c: ContactDisplayData): String {
    var s = ""
    if (c.firstName.size > 0) { s = s + String(c.firstName.toRuneArray()[0]) }
    if (c.lastName.size > 0) { s = s + String(c.lastName.toRuneArray()[0]) }
    if (s.size == 0 && c.username.size > 0) { s = String(c.username.toRuneArray()[0]) }
    return s.toAsciiUpper()
}

@Component
public class AttachmentPanel {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ---- 宿主参数 ----
    // iOS: 普通用户私聊禁止发投票（canSendPolls=false，仅群/频道/机器人/收藏夹可发）。
    public var canSendPolls: Bool = true
    public var bottomInset: Float64 = 0.0
    /** 内容区高度（vp），宿主按窗口高度给；sheet 总高 = 抓手 + 头 + 内容 + 按钮条 + 安全区 */
    public var contentHeightVp: Float64 = 320.0
    /** 内容占位块（gallery/poll 页签）的全局几何（px），宿主据此叠放 ArkTS 网格 / 投票组件 */
    public var onGridGeometry: (Float64, Float64, Float64, Float64) -> Unit =
        { _x: Float64, _y: Float64, _w: Float64, _h: Float64 => }
    public var onTabChanged: (String) -> Unit = { _t: String => }
    public var onClose: () -> Unit = { => }
    // File 页签
    public var onPickGalleryAsFile: () -> Unit = { => }
    public var onPickSystemFile: () -> Unit = { => }
    // Audio 页签
    public var onPickAudioFile: () -> Unit = { => }
    // File/Audio 列表项：按引用发送
    public var onSendRecent: (AttachFileItem) -> Unit = { _i: AttachFileItem => }
    // Location 页签
    public var onSendLocation: (Float64, Float64, String) -> Unit = { _a: Float64, _b: Float64, _n: String => }
    public var onSendLiveLocation: (Float64, Float64, Int64) -> Unit = { _a: Float64, _b: Float64, _d: Int64 => }
    public var onSendVenue: (VenueItemData) -> Unit = { _v: VenueItemData => }
    public var onMapGeometry: (Float64, Float64, Float64, Float64, Float64, Float64) -> Unit =
        { _x: Float64, _y: Float64, _w: Float64, _h: Float64, _lat: Float64, _lng: Float64 => }
    // Contact 页签
    public var onSendContact: (ContactDisplayData) -> Unit = { _c: ContactDisplayData => }

    // ---- 状态 ----
    @State var tab: String = "gallery"
    @State var recentFiles: ArrayList<AttachFileItem> = ArrayList<AttachFileItem>()
    @State var filesLoading: Bool = false
    @State var filesLoaded: Bool = false
    @State var music: ArrayList<AttachFileItem> = ArrayList<AttachFileItem>()
    @State var musicLoading: Bool = false
    @State var musicLoaded: Bool = false
    @State var contacts: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    @State var contactsLoading: Bool = false
    @State var contactsLoaded: Bool = false
    @State var showContactSearch: Bool = false
    @State var contactQuery: String = ""
    @State var contactResults: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()

    private func vp2pxF(v: Float64): Float64 {
        match (this.getUIContext().vp2px(v.vp)) {
            case Some(l) => l.value
            case None => v * 3.0
        }
    }

    // ==================== 页签切换与数据加载 ====================

    private func selectTab(t: String): Unit {
        if (this.tab == t) { return }
        this.tab = t
        this.onTabChanged(t)
        if (t == "file" && !this.filesLoaded) { this.loadRecentFiles() }
        if (t == "audio" && !this.musicLoaded) { this.loadMusic() }
        if (t == "contact" && !this.contactsLoaded) { this.loadContacts() }
    }

    private func loadRecentFiles(): Unit {
        this.filesLoading = true
        this.filesLoaded = true
        spawn {
            let items = getAttachmentSheetService().fetchRecentSentFiles(limit: 20)
            launch {
                this.recentFiles = items
                this.filesLoading = false
            }
        }
    }

    private func loadMusic(): Unit {
        this.musicLoading = true
        this.musicLoaded = true
        spawn {
            let items = getAttachmentSheetService().fetchChatsMusic(limit: 20)
            launch {
                this.music = items
                this.musicLoading = false
            }
        }
    }

    private func loadContacts(): Unit {
        this.contactsLoading = true
        this.contactsLoaded = true
        spawn {
            var list = ArrayList<ContactDisplayData>()
            try {
                list = getRealContactService().getContacts()
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AttachmentPanel] getContacts failed: ${e}")
            }
            let loaded = list
            launch {
                this.contacts = loaded
                this.contactsLoading = false
            }
        }
    }

    private func runContactSearch(q: String): Unit {
        let query = q.trimAscii()
        if (query.size == 0) {
            this.contactResults = ArrayList<ContactDisplayData>()
            return
        }
        // 本地先筛（即时），再补远端 contacts.search（iOS ContactListSearch 同时查本地+远端）
        let lower = query.toAsciiLower()
        let local = ArrayList<ContactDisplayData>()
        for (c in this.contacts) {
            let hay = "${c.firstName} ${c.lastName} ${c.username} ${c.phone}".toAsciiLower()
            if (hay.contains(lower)) { local.add(c) }
        }
        this.contactResults = local
        spawn {
            var remote = ArrayList<ContactDisplayData>()
            try {
                remote = getContactListService().searchContacts(query, limit: 20)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AttachmentPanel] searchContacts failed: ${e}")
            }
            let remoteList = remote
            launch {
                if (this.contactQuery.trimAscii() != query) { return }
                let merged = ArrayList<ContactDisplayData>()
                for (c in local) { merged.add(c) }
                for (r in remoteList) {
                    var dup = false
                    for (c in merged) {
                        if (c.userId == r.userId) { dup = true; break }
                    }
                    if (!dup) { merged.add(r) }
                }
                this.contactResults = merged
            }
        }
    }

    private func visibleContacts(): ArrayList<ContactDisplayData> {
        if (this.showContactSearch && this.contactQuery.trimAscii().size > 0) { return this.contactResults }
        return this.contacts
    }

    // ==================== 按钮条 ====================

    private func dispatch(key: String): Unit {
        this.selectTab(key)
    }

    private func titleFor(key: String): String {
        if (key == "gallery") { return "Gallery" }
        if (key == "file") { return "File" }
        if (key == "location") { return "Location" }
        if (key == "poll") { return "Poll" }
        if (key == "audio") { return "Audio" }
        if (key == "contact") { return "Contact" }
        return key
    }

    private func headerTitle(): String {
        if (this.tab == "gallery") { return "Recents" }
        if (this.tab == "file") { return "File" }
        if (this.tab == "location") { return "Location" }
        if (this.tab == "audio") { return "Audio" }
        if (this.tab == "contact") { return "Contacts" }
        return ""
    }

    private func iconColorFor(key: String): Int64 {
        if (key == this.tab) { return ATTACH_ICON_SELECTED }
        return ATTACH_ICON_COLOR
    }

    private func titleColorFor(key: String): Int64 {
        if (key == this.tab) { return ATTACH_TITLE_SELECTED }
        return ATTACH_TITLE_COLOR
    }

    /** 单个附件按钮：30×30 模板图标（顶部 4pt 内缩）+ 10pt 标题，按钮高 49 */
    @Builder
    func attachButton(key: String) {
        Column {
            Column {
                if (key == "gallery") {
                    Image(@r(app.media.media_ic_attach_gallery))
                        .width(30).height(30).fillColor(this.iconColorFor(key))
                } else if (key == "file") {
                    Image(@r(app.media.media_ic_attach_file))
                        .width(30).height(30).fillColor(this.iconColorFor(key))
                } else if (key == "location") {
                    Image(@r(app.media.media_ic_attach_location))
                        .width(30).height(30).fillColor(this.iconColorFor(key))
                } else if (key == "poll") {
                    Image(@r(app.media.media_ic_attach_poll))
                        .width(30).height(30).fillColor(this.iconColorFor(key))
                } else if (key == "audio") {
                    // iOS Attachment_Audio 图标是圆内播放三角（真机实拍），取同形资源
                    Image(@r(app.media.media_ic_play))
                        .width(30).height(30).fillColor(this.iconColorFor(key))
                } else {
                    // contact —— iOS 资源为 Chat/Attach Menu/Contact，本仓无该 imageset
                    // 转出的 SVG，复用语义等价的联系人图标。
                    Image(@r(app.media.tab_ic_contacts))
                        .width(30).height(30).fillColor(this.iconColorFor(key))
                }
            }
            .width(30)
            .height(30)
            .margin(top: 4)

            Text(this.titleFor(key))
                .fontSize(10)
                .fontColor(this.titleColorFor(key))
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
                .textAlign(TextAlign.Center)
                .width(100.percent)
                .margin(top: 3)
        }
        .width(ATTACH_BUTTON_W)
        .height(ATTACH_BUTTON_H)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt =>
            this.dispatch(key)
        })
    }

    // ==================== 头部 ====================

    @Builder
    func sheetHeader() {
        Stack(alignContent: Alignment.Center) {
            Text(this.headerTitle())
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFF000000)
            Row {
                Text("✕")
                    .fontSize(17)
                    .fontColor(0xFF000000)
                    .width(32)
                    .height(32)
                    .borderRadius(16)
                    .backgroundColor(0xFFE9E9EB)
                    .textAlign(TextAlign.Center)
                    .onClick({ _evt => this.onClose() })
                Blank().layoutWeight(1)
                if (this.tab == "contact") {
                    // iOS ContactSelectionController 导航栏右侧搜索键
                    Text("⌕")
                        .fontSize(20)
                        .fontColor(0xFF000000)
                        .width(32)
                        .height(32)
                        .borderRadius(16)
                        .backgroundColor(if (this.showContactSearch) { 0xFFD1D1D6 } else { 0xFFE9E9EB })
                        .textAlign(TextAlign.Center)
                        .onClick({ _evt =>
                            this.showContactSearch = !this.showContactSearch
                            if (!this.showContactSearch) {
                                this.contactQuery = ""
                                this.contactResults = ArrayList<ContactDisplayData>()
                            }
                        })
                }
            }
            .width(100.percent)
        }
        .width(100.percent)
        .height(ATTACH_HEADER_H)
        .padding(left: 12, right: 12)
    }

    // ==================== 通用行 ====================

    /** iOS AttachmentFileController 的蓝字动作行（Select from Gallery / Select from Files） */
    @Builder
    func actionRow(key: String) {
        Row {
            if (key == "gallery") {
                Image(@r(app.media.media_ic_attach_gallery))
                    .width(24).height(24).fillColor(ATTACH_ACCENT)
            } else if (key == "files") {
                Image(@r(app.media.media_ic_attach_file))
                    .width(24).height(24).fillColor(ATTACH_ACCENT)
            } else {
                Image(@r(app.media.media_ic_play))
                    .width(24).height(24).fillColor(ATTACH_ACCENT)
            }
            Text(if (key == "gallery") { "Select from Gallery" } else { "Select from Files" })
                .fontSize(17)
                .fontColor(ATTACH_ACCENT)
                .margin(left: 16)
                .layoutWeight(1)
        }
        .width(100.percent)
        .height(52)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _evt =>
            if (key == "gallery") { this.onPickGalleryAsFile() }
            else if (key == "files") { this.onPickSystemFile() }
            else { this.onPickAudioFile() }
        })
    }

    @Builder
    func fileRow(item: AttachFileItem) {
        Row {
            Column {
                if (item.isMusic) {
                    Image(@r(app.media.media_ic_play))
                        .width(22).height(22).fillColor(0xFFFFFFFF)
                } else {
                    Image(@r(app.media.media_ic_attach_file))
                        .width(22).height(22).fillColor(0xFFFFFFFF)
                }
            }
            .width(40)
            .height(40)
            .borderRadius(if (item.isMusic) { 20 } else { 8 })
            .backgroundColor(ATTACH_ACCENT)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            Column {
                Text(item.title)
                    .fontSize(16)
                    .fontColor(0xFF000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Text(item.subtitle)
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
                    .margin(top: 2)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)
        }
        .width(100.percent)
        .height(60)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _evt => this.onSendRecent(item) })
    }

    @Builder
    func sectionHeader(title: String) {
        Text(title)
            .fontSize(13)
            .fontColor(0xFF8E8E93)
            .width(100.percent)
            .padding(left: 32, top: 18, bottom: 6)
    }

    @Builder
    func emptyHint(text: String) {
        Column {
            Text(text)
                .fontSize(14)
                .fontColor(0xFF8E8E93)
                .textAlign(TextAlign.Center)
                .padding(left: 32, right: 32)
        }
        .width(100.percent)
        .padding(top: 40, bottom: 24)
        .alignItems(HorizontalAlign.Center)
    }

    // ==================== 页签内容 ====================

    /** gallery / poll：透明占位，像素由宿主叠放（ArkTS 图库网格 / 仓颉投票组件） */
    /** 主动重量图库占位块（OverlayGeometry 通道），键盘/面板整体位移后由宿主触发。 */
    private func remeasureGridSlot(): Unit {
        match (measureOverlaySlot(ATTACH_GRID_SLOT_ID)) {
            case Some(r) => this.onGridGeometry(r.x, r.y, r.w, r.h)
            case None => ()
        }
    }

    protected override func aboutToAppear(): Unit {
        registerOverlayRemeasure("attachGrid", { => this.remeasureGridSlot() })
    }

    protected override func aboutToDisappear(): Unit {
        unregisterOverlayRemeasure("attachGrid")
    }

    @Builder
    func placeholderContent(heightVp: Float64) {
        Column {}
            .width(100.percent)
            .height(heightVp)
            .id(ATTACH_GRID_SLOT_ID)
            .onAreaChange({ _: Area, newArea: Area =>
                this.onGridGeometry(
                    this.vp2pxF(attachOptLenVp(newArea.globalPosition.x)),
                    this.vp2pxF(attachOptLenVp(newArea.globalPosition.y)),
                    this.vp2pxF(newArea.width.value),
                    this.vp2pxF(newArea.height.value)
                )
            })
    }

    @Builder
    func fileContent() {
        Scroll {
            Column {
                Column {
                    this.actionRow("gallery")
                    Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 56)
                    this.actionRow("files")
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, top: 12)
                .clip(true)

                if (this.filesLoading) {
                    Column {
                        LoadingProgress().width(28).height(28).color(ATTACH_ACCENT)
                    }
                    .width(100.percent)
                    .padding(top: 32)
                    .alignItems(HorizontalAlign.Center)
                } else if (this.recentFiles.size > 0) {
                    this.sectionHeader("RECENTLY SENT FILES")
                    Column {
                        ForEach(this.recentFiles, itemGeneratorFunc: { item: AttachFileItem, _idx: Int64 =>
                            this.fileRow(item)
                        }, keyGeneratorFunc: { item: AttachFileItem, _idx: Int64 => "f_" + item.messageId.toString() })
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16)
                    .clip(true)
                } else {
                    this.emptyHint("Send and receive files of any type, up to 2 GB in size each, access them instantly on your other devices.")
                }
                Blank().height(24)
            }
            .width(100.percent)
        }
        .width(100.percent)
        .height(this.contentHeightVp)
        .scrollBar(BarState.Off)
    }

    @Builder
    func audioContent() {
        Scroll {
            Column {
                Column {
                    this.actionRow("audiofiles")
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, top: 12)
                .clip(true)

                if (this.musicLoading) {
                    Column {
                        LoadingProgress().width(28).height(28).color(ATTACH_ACCENT)
                    }
                    .width(100.percent)
                    .padding(top: 32)
                    .alignItems(HorizontalAlign.Center)
                } else if (this.music.size > 0) {
                    this.sectionHeader("CHATS MUSIC")
                    Column {
                        ForEach(this.music, itemGeneratorFunc: { item: AttachFileItem, _idx: Int64 =>
                            this.fileRow(item)
                        }, keyGeneratorFunc: { item: AttachFileItem, _idx: Int64 => "m_" + item.messageId.toString() })
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16)
                    .clip(true)
                } else {
                    this.emptyHint("Send and receive files of any type, up to 2 GB in size each, access them instantly on your other devices.")
                }
                Blank().height(24)
            }
            .width(100.percent)
        }
        .width(100.percent)
        .height(this.contentHeightVp)
        .scrollBar(BarState.Off)
    }

    @Builder
    func contactRow(c: ContactDisplayData) {
        Row {
            Text(attachInitials(c))
                .fontSize(15)
                .fontColor(0xFFFFFFFF)
                .width(40)
                .height(40)
                .borderRadius(20)
                .backgroundColor(getAvatarColorForPeer(c.userId))
                .textAlign(TextAlign.Center)
            Column {
                Text(c.getDisplayName())
                    .fontSize(16)
                    .fontColor(0xFF000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Text(attachStatusText(c))
                    .fontSize(13)
                    .fontColor(if (c.isOnline) { ATTACH_ACCENT } else { 0xFF8E8E93 })
                    .margin(top: 2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)
        }
        .width(100.percent)
        .height(60)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _evt => this.onSendContact(c) })
    }

    @Builder
    func contactContent() {
        Column {
            if (this.showContactSearch) {
                TextInput(text: this.contactQuery, placeholder: trSource("Search"))
                    .width(100.percent)
                    .height(36)
                    .fontSize(15)
                    .backgroundColor(0xFFE3E3E8)
                    .borderRadius(10)
                    .padding(left: 12, right: 12)
                    .margin(left: 16, right: 16, top: 4, bottom: 8)
                    .onChange({ v: String =>
                        this.contactQuery = v
                        this.runContactSearch(v)
                    })
            }
            if (this.contactsLoading) {
                Column {
                    LoadingProgress().width(28).height(28).color(ATTACH_ACCENT)
                }
                .width(100.percent)
                .padding(top: 32)
                .alignItems(HorizontalAlign.Center)
            } else if (this.visibleContacts().size == 0) {
                this.emptyHint(if (this.showContactSearch && this.contactQuery.size > 0) { "No results" } else { "No contacts" })
            } else {
                List {
                    ForEach(this.visibleContacts(), itemGeneratorFunc: { c: ContactDisplayData, _idx: Int64 =>
                        ListItem { this.contactRow(c) }
                    }, keyGeneratorFunc: { c: ContactDisplayData, _idx: Int64 => "c_" + c.userId.toString() })
                }
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(0xFFFFFFFF)
                .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xE5E5EA, startMargin: 68, endMargin: 0))
                .scrollBar(BarState.Off)
            }
        }
        .width(100.percent)
        .height(this.contentHeightVp)
    }

    @Builder
    func locationContent() {
        Column {
            LocationPicker(
                embedded: true,
                onSendLocation: { lat: Float64, lng: Float64, name: String =>
                    this.onSendLocation(lat, lng, name)
                },
                onSendLiveLocation: { lat: Float64, lng: Float64, dur: Int64 =>
                    this.onSendLiveLocation(lat, lng, dur)
                },
                onSendVenue: { v: VenueItemData => this.onSendVenue(v) },
                onMapGeometry: { x: Float64, y: Float64, w: Float64, h: Float64, lat: Float64, lng: Float64 =>
                    this.onMapGeometry(x, y, w, h, lat, lng)
                },
                onClose: { => this.onClose() }
            )
        }
        .width(100.percent)
        .height(this.contentHeightVp)
    }

    // ==================== 根 ====================

    public func build() {
        Column {
            // 半透明遮罩：点击空白处关闭（同 ContextMenuView 受控叠加层范式）。
            Column {}
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(ATTACH_SCRIM_COLOR)
                .onClick({ _evt =>
                    this.onClose()
                })
                .transition(
                    TransitionEffect.OPACITY
                        .animation(AnimateParam(duration: 250, curve: Curve.EaseOut))
                )

            // 底部 sheet：抓手 + 头部 + 页签内容 + separator + 按钮条
            Column {
                Row {
                    Column {}
                        .width(36)
                        .height(4)
                        .backgroundColor(0xFFD1D1D6)
                        .borderRadius(2)
                }
                .width(100.percent)
                .height(ATTACH_GRABBER_H)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)

                if (this.tab == "poll") {
                    // 投票组件自带 Cancel / New Poll / Create 头，占位块连头一起让给宿主叠放
                    this.placeholderContent(ATTACH_HEADER_H + this.contentHeightVp)
                } else {
                    this.sheetHeader()
                    if (this.tab == "gallery") {
                        this.placeholderContent(this.contentHeightVp)
                    } else if (this.tab == "file") {
                        this.fileContent()
                    } else if (this.tab == "audio") {
                        this.audioContent()
                    } else if (this.tab == "contact") {
                        this.contactContent()
                    } else {
                        this.locationContent()
                    }
                }

                Divider()
                    .color(ATTACH_SEPARATOR_COLOR)
                    .strokeWidth(0.5)

                Scroll {
                    Row {
                        this.attachButton("gallery")
                        this.attachButton("file")
                        this.attachButton("location")
                        if (this.canSendPolls) {
                            this.attachButton("poll")
                        }
                        this.attachButton("audio")
                        this.attachButton("contact")
                    }
                    .padding(left: 8, right: 8)
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width(100.percent)
                .height(ATTACH_BUTTON_H + 8.0)
                .backgroundColor(ATTACH_PANEL_BG)
            }
            .width(100.percent)
            .backgroundColor(ATTACH_SHEET_BG)
            .borderRadius(topLeft: 12, topRight: 12)
            .padding(bottom: this.bottomInset)
            .transition(
                TransitionEffect.move(TransitionEdge.Bottom)
                    .animation(AnimateParam(duration: 250, curve: Curve.EaseOut))
            )
        }
        .width(100.percent)
        .height(100.percent)
        .position(x: 0, y: 0)
    }
}
