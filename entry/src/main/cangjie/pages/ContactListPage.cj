package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.Want
import std.collection.ArrayList
import std.collection.HashMap
import std.sync.*
import std.time.*
import std.unicode.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.components.{ContactsPeerComponent, PeersNearbyIconComponent, SelectablePeerComponent, SelectedPeerChip, SearchBar, ContextMenuView, ContextMenuItem}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.{safeAnimateTo, getCountryList, searchCountries}
import ohos_app_cangjie_entry.viewmodels.getAuthViewModel
import ohos_app_cangjie_entry.interop.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation, PresentationStringsSnapshot, currentPresentationStrings}

// P2-128: 最近/常用 peer 横向条 — 数据来自 HorizontalPeerService.getRecentPeers()
// P2-129: 选择模式 — @State selectionMode 区分单击进聊天 vs. 多选 peer

// TC-0018 返修（§B1）：由 MainTabPage 在 tab bar 搜索圆钮激活 Contacts tab 时触发，对位
// ContactsController.tabBarActivateSearch()/tabBarDeactivateSearch()。ContactListPage 同时是
// 独立可路由的 @HybridComponentEntry 页面（如 openContactMenu/群聊建群等流程直接
// routerPush("ContactListPage", ...) 零参构造），@Prop 要求父组件构造时提供初值、与该零参
// 构造路径冲突（cjpm 编译期 argc 不匹配），故不用 @Prop——改用与 ChatRoomPage.cj:24-39
// （requestChatSearchOnReturn/registerChatSearchHandler）同款的「模块级处理器注册 + host
// 触发」通道：处理器直接改写子组件自身 @State（isSearching），真实响应式，无需跨组件传值。
private var _contactsSearchActivateHandler: Option<() -> Unit> = None
private var _contactsSearchDeactivateHandler: Option<() -> Unit> = None

public func fireContactsSearchActivate(): Unit {
    match (_contactsSearchActivateHandler) {
        case Some(handler) => handler()
        case None => ()
    }
}

public func fireContactsSearchDeactivate(): Unit {
    match (_contactsSearchDeactivateHandler) {
        case Some(handler) => handler()
        case None => ()
    }
}

private func registerContactsSearchHandlers(activate: () -> Unit, deactivate: () -> Unit): Unit {
    _contactsSearchActivateHandler = Some(activate)
    _contactsSearchDeactivateHandler = Some(deactivate)
}

/**
 * 联系人列表页面（iOS Telegram 风格）
 *
 * 对应 iOS TelegramUI ContactListController
 * iOS 文件参考:
 * - submodules/TelegramUI/Sources/ContactList/ContactListController.swift
 * - submodules/TelegramUI/Sources/ContactList/ContactListNode.swift
 *
 * 功能:
 * - iOS 风格标题栏: "Sort" (左) / "Contacts" (中) / "+" (右)
 * - 搜索框
 * - "Invite Friends" 快捷入口
 * - 联系人列表: 头像 + 名字 + last seen 时间
 * - 排序切换: 按名字 / 按最后上线时间
 * - 添加联系人后自动刷新
 * - 点击联系人进入聊天
 */
@HybridComponentEntry
@Component
public class ContactListPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // The root tab host owns the floating navigation chrome. Contacts only
    // reports search activation/deactivation, matching ContactsController.
    public var onSearchVisibilityChange: (Bool) -> Unit = { _visible => }
    // rework1 修复（D-142 required_fix #2）：ContactListPage 同时是 MainTabPage TabContent
    // 常驻单例 + routerPush("ContactListPage", "") 独立压栈打开的页面（ChatListPage.cj:
    // 1144/1958「New Message」）。模块级 _contactsSearchActivateHandler/_contactsSearchDeactivateHandler
    // 只允许被"容器常驻实例"注册，独立压栈实例跳过 register，避免其在 pop 销毁后把模块级 handler
    // 永久劫持为悬挂闭包（见 dev_pattern.md D-142）。MainTabPage 直接实例化时显式传
    // isTabHosted: true；routerPush 走 ArkTS CJHybridComponent 零参桥接，无法传参，
    // 默认落到 false，天然跳过 register。
    public var isTabHosted: Bool = false
    // TC-0540 B1：Contacts 根 Tab 此前零订阅 AppStorage["presentation"]，系统深色后
    // 只有 MainTabPage chrome 变深、本页内容仍写死浅色字面量。写法对齐
    // ChatListPage / SettingsPage：每组件各自 @StorageLink，不沿组件树继承。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false
    // 原始联系人数据
    @State var contacts: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    // 显示列表（搜索过滤+排序后的结果，使用 ContactEntry 包装以实现 ToString → ForEach 正确 keying）
    @State var displayContacts: ArrayList<ContactEntry> = ArrayList<ContactEntry>()
    // 按名字排序时的分组（A-Z 索引分区）
    @State var displaySections: ArrayList<ContactSection> = ArrayList<ContactSection>()
    // 扁平化的显示项（分区头+联系人，用于 ByName 模式的单 ForEach）
    @State var displayItems: ArrayList<ContactListDisplayItem> = ArrayList<ContactListDisplayItem>()
    
    // 长按上下文预览（与 Chats 页长按会话同一形态：预览卡 + 动作面板）
    @State var showContactPreview: Bool = false
    @State var previewSourceY: Float64 = 0.0
    @State var previewSourceHeight: Float64 = 0.0
    @State var previewAvatar: String = ""
    @State var previewSubtitle: String = ""
    @State var contactPreviewItems: Array<ContextMenuItem> = Array<ContextMenuItem>()

    // 长按上下文菜单
    @State var showContextMenu: Bool = false
    @State var contextMenuUserId: Int64 = 0
    @State var contextMenuAccessHash: Int64 = 0
    @State var contextMenuDisplayName: String = ""
    
    // 搜索
    @State var searchText: String = ""
    @State var isSearching: Bool = false
    // S8-03: GLOBAL SEARCH section (iOS ContactsSearchContainerNode: searchRemotePeers results
    // listed after the local contacts, group .global, ChatListSearchItemHeader .globalPeers).
    @State var globalResults: ArrayList<ContactEntry> = ArrayList<ContactEntry>()
    private var globalSearchGeneration: Int64 = 0
    
    // 加载状态
    @State var isLoading: Bool = false
    @State var errorText: String = ""
    
    // 排序模式: 0=按名字, 1=按最后上线
    @State var sortMode: Int32 = 1
    // 排序弹窗
    @State var showSortSheet: Bool = false
    // CTL-CONTACTS-002: 菜单入/出场动画态（iOS ContextController: scale 0.01→1 spring 0.42s，出场 0.2s）
    @State var sortMenuScale: Float32 = 1.0
    @State var sortMenuAlpha: Float64 = 1.0
    // 菜单项按压高亮（iOS: 黑 alpha0.1 圆角块）：-1=无
    @State var pressedSortItem: Int32 = -1
    // CTL-SHARED-001: 导航钮按压（"sort"/"add"，iOS alpha 0.4 瞬时）
    @State var pressedNav: String = ""
    // CTL-CONTACTS-006: Invite 行按压
    @State var invitePressed: Bool = false

    // CTL-CONTACTS-003 / CTL-SHARED-004: New Contact 底部 sheet（iOS navigationPresentation=.modal:
    // 0.5s 弹性上滑 + dim 0.25 + 顶部圆角，表单 X 圆/居中标题/灰勾圆）
    @State var showNewContactSheet: Bool = false
    @State var sheetDim: Float64 = 0.0
    @State var sheetPanelShift: Float64 = 2000.0
    @State var ncFirstName: String = ""
    @State var ncLastName: String = ""
    @State var ncPhone: String = ""
    @State var ncCountryName: String = "China mainland"
    @State var ncCountryCode: String = "+86"
    @State var ncCountryFlag: String = "🇨🇳"
    @State var ncSyncToPhone: Bool = true
    @State var showNcCountryPicker: Bool = false
    @State var ncCountrySearch: String = ""
    @State var ncCountryIndices: Array<Int64> = []
    @State var ncSaving: Bool = false
    @State var ncSavePending: Int32 = 0
    @State var ncSaveAnySuccess: Bool = false
    @State var ncError: String = ""

    private func openNewContactSheet(): Unit {
        // iOS modal presentation resigns the underlying navigation search.
        // Reset the root chrome before replacing the focusable SearchBar below.
        this.isSearching = false
        this.onSearchVisibilityChange(false)
        let auth = getAuthViewModel()
        this.ncCountryName = auth.countryName
        this.ncCountryCode = auth.countryCode
        this.ncCountryFlag = this.findNcCountryFlag(auth.countryName, auth.countryCode)
        this.ncFirstName = ""
        this.ncLastName = ""
        this.ncPhone = ""
        this.ncSyncToPhone = true
        this.showNcCountryPicker = false
        this.ncCountrySearch = ""
        this.ncCountryIndices = searchCountries("")
        this.ncError = ""
        this.ncSaving = false
        this.ncSavePending = 0
        this.ncSaveAnySuccess = false
        this.sheetDim = 0.0
        this.sheetPanelShift = 2000.0
        this.showNewContactSheet = true
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 500, curve: Curve.EaseOut), { =>
            this.sheetDim = 0.25
            this.sheetPanelShift = 0.0
        })
    }

    private func closeNewContactSheet(): Unit {
        this.showNcCountryPicker = false
        // System contact UI can restore focus to the previously focused node on
        // return. Restore the root tab bar both before and after sheet teardown.
        this.isSearching = false
        this.onSearchVisibilityChange(false)
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 300, curve: Curve.EaseInOut), { =>
            this.sheetDim = 0.0
            this.sheetPanelShift = 2000.0
        })
        let _ = spawn {
            sleep(Duration.millisecond * 310)
            launch {
                this.showNewContactSheet = false
                this.onSearchVisibilityChange(false)
            }
        }
    }

    private func saveNewContact(): Unit {
        if (this.ncSaving) { return }
        let first = this.ncFirstName.trimAscii()
        let localPhone = this.ncPhone.trimAscii()
        if (first.isEmpty() || localPhone.isEmpty()) {
            this.ncError = "First name and phone number are required"
            return
        }
        if (!localPhone.startsWith("+") && this.ncCountryCode.trimAscii().isEmpty()) {
            this.ncError = "Country code is required"
            return
        }
        let phone = if (localPhone.startsWith("+")) { localPhone } else { this.ncCountryCode + localPhone }
        this.ncSaving = true
        this.ncSavePending = if (this.ncSyncToPhone) { 2 } else { 1 }
        this.ncSaveAnySuccess = false
        this.ncError = ""
        let last = this.ncLastName.trimAscii()
        let syncToPhone = this.ncSyncToPhone

        // ArkTS system UI must be invoked while the click callback still owns a
        // JS/UI scope. Starting it after the background Telegram request can
        // fail with BusinessException 34300003 ("Without any scope").
        if (syncToPhone) {
            let firstEsc = this.escapeNcJson(first)
            let lastEsc = this.escapeNcJson(last)
            let phoneEsc = this.escapeNcJson(phone)
            let args = "{\"firstName\":\"${firstEsc}\",\"lastName\":\"${lastEsc}\",\"phoneNumber\":\"${phoneEsc}\"}"
            callArkAsync(ADD_CONTACT_VIA_UI, args, { responseJson =>
                let response = JsonParser.parseObject(responseJson)
                let phoneSaved = response.getBool("ok")
                launch {
                    this.finishNewContactSave(phoneSaved)
                }
            })
        }

        let _ = spawn {
            let result = getRealContactService().importContact(phone, first, last)
            launch {
                let telegramSaved = result.isSome()
                if (telegramSaved) {
                    setContactsNeedRefresh()
                }
                this.finishNewContactSave(telegramSaved)
            }
        }
    }

    private func finishNewContactSave(success: Bool): Unit {
        this.ncSaveAnySuccess = this.ncSaveAnySuccess || success
        this.ncSavePending = this.ncSavePending - 1
        if (this.ncSavePending <= 0) {
            this.ncSaving = false
            if (this.ncSaveAnySuccess) {
                this.closeNewContactSheet()
            } else {
                this.ncError = "Could not add contact — check the number and try again."
            }
        }
    }

    private func escapeNcJson(value: String): String {
        return value.replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
    }

    private func findNcCountryFlag(name: String, code: String): String {
        let countries = getCountryList()
        for (country in countries) {
            if (country[0] == name && country[1] == code) {
                return country[2]
            }
        }
        for (country in countries) {
            if (country[1] == code) {
                return country[2]
            }
        }
        return "🌐"
    }

    private func refreshNcCountryPicker(): Unit {
        this.ncCountryIndices = searchCountries(this.ncCountrySearch)
    }

    private func updateNcCountryCode(value: String): Unit {
        let entered = value.trimAscii()
        this.ncCountryCode = if (entered.isEmpty() || entered.startsWith("+")) {
            entered
        } else {
            "+" + entered
        }
        let countries = getCountryList()
        for (country in countries) {
            if (country[1] == this.ncCountryCode) {
                this.ncCountryName = country[0]
                this.ncCountryFlag = country[2]
                return
            }
        }
    }

    private func ncCountryNameAt(index: Int64): String {
        let countries = getCountryList()
        if (index >= 0 && index < Int64(countries.size)) { return countries[index][0] }
        return ""
    }

    private func ncCountryCodeAt(index: Int64): String {
        let countries = getCountryList()
        if (index >= 0 && index < Int64(countries.size)) { return countries[index][1] }
        return ""
    }

    private func ncCountryFlagAt(index: Int64): String {
        let countries = getCountryList()
        if (index >= 0 && index < Int64(countries.size)) { return countries[index][2] }
        return ""
    }

    private func selectNcCountry(index: Int64): Unit {
        let countries = getCountryList()
        if (index >= 0 && index < Int64(countries.size)) {
            this.ncCountryName = countries[index][0]
            this.ncCountryCode = countries[index][1]
            this.ncCountryFlag = countries[index][2]
            this.ncCountrySearch = ""
            this.ncCountryIndices = searchCountries("")
            this.showNcCountryPicker = false
        }
    }

    @Builder
    private func buildNcCountryRow(index: Int64) {
        Row {
            Text(this.ncCountryFlagAt(index))
                .fontSize(24)
                .width(38)
            Text(this.ncCountryNameAt(index))
                .fontSize(17)
                .fontColor(0xFF000000)
                .layoutWeight(1)
            Text(this.ncCountryCodeAt(index))
                .fontSize(17)
                .fontColor(0xFF8E8E93)
        }
        .width(100.percent)
        .height(50)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.selectNcCountry(index) })
    }

    // iOS 真值（ContextControllerImpl.swift:573-577 / 689-728，Contacts Sort 用的是
    // ContextController 而非自绘弹层）：
    //   入场 scale 0.1→1.0 spring(duration 0.42s, damping 104, initialVelocity 0)
    //        + alpha 0→1 用 0.2s 线性（比 scale 早收，避免尾段虚影）
    //   出场 alpha 1→0 0.15s、scale 1→0.1 0.2s
    // 此前实现为 scale 0.01→1 的 420ms EaseOut + alpha 同步 420ms —— 无回弹、
    // alpha 拖尾，观感与 iOS 不符。
    private func openSortMenu(): Unit {
        this.sortMenuScale = Float32(0.1)
        this.sortMenuAlpha = 0.0
        this.showSortSheet = true
        // scale: 仓颉 ArkUI SDK 无 springMotion/ICurve 绑定（实测 undeclared），
        // 用两段 Curve 近似 damping104 的弱过冲：0.1→1.03 (300ms EaseOut) →1.0 (120ms EaseInOut)，
        // 合计 420ms 与 iOS springDuration 一致。
        safeAnimateTo({ => this.getUIContext() },
            AnimateParam(duration: 300, curve: Curve.EaseOut), { =>
            this.sortMenuScale = Float32(1.03)
        })
        let _ = spawn {
            sleep(Duration.millisecond * 300)
            launch {
                safeAnimateTo({ => this.getUIContext() },
                    AnimateParam(duration: 120, curve: Curve.EaseInOut), { =>
                    this.sortMenuScale = Float32(1.0)
                })
            }
        }
        // alpha: 200ms 线性，独立于 scale
        safeAnimateTo({ => this.getUIContext() },
            AnimateParam(duration: 200, curve: Curve.Linear), { =>
            this.sortMenuAlpha = 1.0
        })
    }

    private func closeSortMenu(): Unit {
        safeAnimateTo({ => this.getUIContext() },
            AnimateParam(duration: 150, curve: Curve.EaseInOut), { =>
            this.sortMenuAlpha = 0.0
        })
        safeAnimateTo({ => this.getUIContext() },
            AnimateParam(duration: 200, curve: Curve.EaseInOut), { =>
            this.sortMenuScale = Float32(0.1)
        })
        let _ = spawn {
            sleep(Duration.millisecond * 210)
            launch { this.showSortSheet = false }
        }
    }
    
    // 头像版本计数器：photoReadyCallback 触发时递增，驱动 UI 刷新
    @State var avatarVersion: Int64 = 0

    // 邀请链接已复制提示
    @State var showInviteCopied: Bool = false

    // P2-128: 最近/常用 peer 横向条
    @State var topPeers: ArrayList<HorizontalPeerItem> = ArrayList<HorizontalPeerItem>()
    @State var isLoadingTopPeers: Bool = false

    // P2-127: 上下文菜单删除/屏蔽反馈
    @State var showDeleteConfirm: Bool = false
    @State var deleteActionInProgress: Bool = false
    @State var contextMenuFeedback: String = ""
    @State var showContextFeedback: Bool = false

    // ContextMenuView items 数组（由 openContactMenu() 填充）
    var contactMenuItems: Array<ContextMenuItem> = Array<ContextMenuItem>()

    // P2-126: 通讯录权限门控
    // 死状态防护：contactsPermGranted 必须在 aboutToAppear 中通过 PermissionsService 真查回填
    // 不能默认 true（门控永不显示）或仅保持 false（门控永显示）
    @State var contactsPermGranted: Bool = false
    // 权限请求中（防止重复点击）
    @State var contactsPermRequesting: Bool = false
    // 人工反馈 #1：已弹过一次系统授权框（持久化镜像）。granted=false && asked=true ⇒ denied 态。
    @State var contactsPermAsked: Bool = false
    @State var showContactsPermissionNotice: Bool = true
    // TC-0178 返修：对位源侧 ContactsSettings.synchronizeContacts（ContactListNode.swift:
    // 1248-1263 syncDisabled 的取值来源）。只读回填自既有 ContactsService/RealContactService
    // 持久化开关，本次不新增设置项 UI。初值 true 与 RealContactService.cj:37 默认一致。
    @State var contactsSyncEnabled: Bool = true

    // P2-129: 选择模式（建群/加成员多选）
    // 死状态防护：selectionMode 默认 false（正常单击模式），由导航参数或外部入口驱动切换为 true；
    // selectionSelectedIds 由用户点击 SelectablePeerComponent 驱动 toggleSelectionMode() 真实填充。
    @State var selectionMode: Bool = false
    @State var selectionSelectedIds: ArrayList<Int64> = ArrayList<Int64>()
    // 选择完成后的回调（由调用方注入，如 CreateGroupPage 的 "Add Members" 流程）
    public var onSelectionDone: (ArrayList<Int64>) -> Unit = { _: ArrayList<Int64> => }

    // 人工反馈 #11：Contacts tab 选择态的删除链路（对位 ContactsController.swift:454-475 底部工具条、
    // :619-708 确认动作表 + pendingRemoval + 撤销条）。仅 isTabHosted 实例走这套；
    // routerPush 打开的选人器实例保留 P2-129 的 Cancel / Select Members / Done(N) 语义。
    @State var showContactDeleteConfirm: Bool = false
    @State var deleteConfirmItems: Array<ContextMenuItem> = Array<ContextMenuItem>()
    private var deleteConfirmIds: ArrayList<Int64> = ArrayList<Int64>()
    // 已确认删除、尚未提交服务端的 peer（行立刻从列表消失，撤销即恢复）
    @State var pendingRemovalIds: ArrayList<Int64> = ArrayList<Int64>()
    // 撤销条走工程统一的 UndoToastService（MainTabPage 顶层挂载 UndoToast()，对位 UndoOverlayController）
    private var undoGeneration: Int64 = 0

    // 同步循环控制标志
    var _syncActive: Bool = false
    // 人工反馈 #4b：联系人行的 presence 副标题不随 updateUserStatus 刷新（进过会话看到 online，
    // 回列表仍是旧的 last seen）。订阅 UpdatesManager 的用户状态通道，并在轮询里从共享缓存同步。
    private var _userStatusToken: Int64 = -1
    var _photoCallbackRegistered: Bool = false

    // iOS parity（TC-SCROLL-002）：列表视口高（vp），onAreaChange 回填，用于短内容填充计算
    @State var listVH: Float64 = 0.0
    // 短内容过滚后弹回用 scroller（iOS alwaysBounce 回弹语义）
    private let contactsListScroller: Scroller = Scroller()

    /**
     * 底部填充：使内容略超视口（Spring 恒可回弹）+ 悬浮 tab bar 不挡末条（88≈bar 带高）。
     * 行高估算：Invite 56 + 每行 54（by-name 分组头按行等价近似）。
     */
    private func contactsBottomFillerH(): Float64 {
        let n = if (this.sortMode == 1) { this.displayContacts.size } else { this.displayItems.size }
        // G-06: 行高 54→49 与 ContactsPeerComponent 同步
        let content = 56.0 + 49.0 * Float64(n)
        let want = this.listVH - content + 88.0
        if (want > 88.0) { return want }
        return 88.0
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // TC-0018 返修（§B1）：注册 tab bar 搜索激活/退出处理器，供 MainTabPage 的
        // activateSearchOnCurrentTab()/deactivateSearchOnCurrentTab() 在 Contacts tab 上触发。
        // rework1 修复（D-142）：只有容器常驻实例（isTabHosted=true）才 register，独立
        // routerPush 压栈打开的实例（isTabHosted 默认 false）跳过——避免其覆盖常驻实例的
        // 绑定后又在 pop 销毁时留下悬挂闭包。
        if (this.isTabHosted) {
            registerContactsSearchHandlers(
                { =>
                    this.isSearching = true
                    FocusControl.requestFocus("contacts_search_input")
                },
                { =>
                    this.searchText = ""
                    this.isSearching = false
                    this.applyFilterAndSort()
                    this.scheduleGlobalSearch("")
                }
            )
        }
        // S8-01：排序偏好持久化（iOS ContactsController.swift:196-222 从 contactSynchronizationSettings 读 sortOrder）
        this.sortMode = if (getContactsSortByPresence()) { 1 } else { 0 }
        this.checkAndUpdateContactsPermission()
        this.registerPhotoCallback()
        this.loadContacts()
        this.startRefreshSync()
        this.loadTopPeers()
        this.registerUserStatusUpdates()
    }

    private func registerUserStatusUpdates(): Unit {
        if (this._userStatusToken >= 0) { return }
        this._userStatusToken = getUpdatesManager().addUserStatusSubscriber({ userId: Int64, isOnline: Bool =>
            launch {
                if (this.applyPresenceForUser(userId, isOnline)) {
                    this.applyFilterAndSort()
                }
            }
        })
    }

    /**
     * 把单个用户的最新 presence 写回 this.contacts（优先取 UserPhotoService 缓存里的完整
     * isOnline/wasOnline/statusType；缓存缺失时按事件值退化）。返回是否有变化。
     */
    private func applyPresenceForUser(userId: Int64, isOnline: Bool): Bool {
        var changed = false
        for (c in this.contacts) {
            if (c.userId != userId) { continue }
            match (getUserPhotoService().getCachedUser(userId)) {
                case Some(u) =>
                    if (c.isOnline != u.isOnline || c.wasOnline != u.wasOnline || c.statusType != u.statusType) {
                        c.isOnline = u.isOnline
                        c.wasOnline = u.wasOnline
                        c.statusType = u.statusType
                        changed = true
                    }
                case None =>
                    if (c.isOnline != isOnline) {
                        c.isOnline = isOnline
                        c.statusType = if (isOnline) { "online" } else { "offline" }
                        if (!isOnline) { c.wasOnline = Int32(DateTime.now().toUnixTimeStamp().toSeconds()) }
                        changed = true
                    }
            }
            break
        }
        return changed
    }

    /**
     * 全量从共享缓存同步 presence（例如从会话页返回时，会话页的 getHistory 已刷新了缓存）。
     * 只在字段确有差异时返回 true，避免无谓重建列表。
     */
    private func syncAllPresenceFromCache(): Bool {
        var changed = false
        let photoService = getUserPhotoService()
        for (c in this.contacts) {
            // 人工反馈 R2-3：时间推进导致文案该变（just now → 1 minute ago …）也算变化
            if (c.uiPresenceText != c.getLastSeenText()) { changed = true }
            match (photoService.getCachedUser(c.userId)) {
                case Some(u) =>
                    if (c.isOnline != u.isOnline || c.wasOnline != u.wasOnline || c.statusType != u.statusType) {
                        c.isOnline = u.isOnline
                        c.wasOnline = u.wasOnline
                        c.statusType = u.statusType
                        changed = true
                    }
                case None => ()
            }
        }
        return changed
    }

    /**
     * P2-126: 通讯录权限状态检查 — 死状态防护实现
     *
     * 在后台线程查询 PermissionsService，结果通过 launch{} 回填 @State（S-001 合规）。
     * 必须真查 service 而非使用默认值，否则门控进入死状态。
     */
    func checkAndUpdateContactsPermission(): Unit {
        let _ = spawn {
            let svc = getPermissionsService()
            let granted = svc.checkPermission(PermissionType.Contacts)
            // TC-0178 返修：与 granted 同一个 spawn 内查询同步开关，同一 launch{} 块回填
            // （S-001 合规）。对位源侧 syncDisabled 取值来源 ContactsSettings.synchronizeContacts。
            let syncEnabled = getContactsService().getDeviceContactsSyncEnabled()
            let asked = getContactsPermissionAsked()
            Hilog.info(0, "CjTelegram", "[ContactListPage] contacts permission check: granted=${granted} asked=${asked}")
            launch {
                this.contactsPermGranted = granted
                this.contactsSyncEnabled = syncEnabled
                this.contactsPermAsked = asked
            }
        }
    }

    /**
     * P2-126: 请求通讯录授权（由权限引导卡片按钮触发）
     * 结果通过 launch{} 更新 @State（S-001 合规），授权后触发联系人加载。
     */
    func requestContactsPermission(): Unit {
        if (this.contactsPermRequesting || this.contactsPermGranted) { return }
        // 人工反馈 #1：已拒绝态（问过一次仍未授权）对位 iOS .denied → "Allow in Settings" 跳系统设置
        // （ContactListNode.swift:2143 applicationBindings.openSettings()），不再重复弹系统框。
        if (this.contactsPermAsked) {
            getDeviceAccessService().openSystemSettings()
            return
        }
        this.contactsPermRequesting = true
        let _ = spawn {
            let svc = getPermissionsService()
            svc.requestPermission(PermissionType.Contacts, { granted: Bool =>
                setContactsPermissionAsked()
                launch {
                    this.contactsPermRequesting = false
                    this.contactsPermGranted = granted
                    this.contactsPermAsked = true
                    if (granted) {
                        Hilog.info(0, "CjTelegram", "[ContactListPage] Contacts permission granted, loading contacts")
                        this.loadContacts()
                    } else {
                        Hilog.info(0, "CjTelegram", "[ContactListPage] Contacts permission denied by user")
                    }
                }
            })
        }
    }

    func getPermButtonLabel(): String {
        if (this.contactsPermRequesting) {
            return "Requesting..."
        }
        // 源侧 ContactListNode.swift:461-476：.denied → "Allow in Settings"，.notDetermined → "Allow Access"
        if (this.contactsPermAsked) {
            return "Allow in Settings"
        }
        return "Allow Access"
    }

    /**
     * 人工反馈 #3：通讯录权限门（对位 ContactsController.swift:749-758 与 openInvite 同一套三分支）。
     * allowed → 执行 onAllowed；notDetermined → 只弹系统授权框、本次不导航；
     * denied → alert「Please Allow Access / Telegram does not have access to your contacts」
     *          按钮 Not Now / Settings（跳系统设置）。
     */
    func guardContactsAccess(onAllowed: () -> Unit): Unit {
        if (this.contactsPermGranted) {
            onAllowed()
            return
        }
        if (!this.contactsPermAsked) {
            this.requestContactsPermission()
            return
        }
        getUIContext().showAlertDialog(
            AlertDialogParamWithButtons(
                message: "Telegram does not have access to your contacts",
                title: "Please Allow Access",
                primaryButton: AlertDialogButtonOptions(
                    value: "Not Now",
                    action: {=> }
                ),
                secondaryButton: AlertDialogButtonOptions(
                    value: "Settings",
                    action: {=>
                        getDeviceAccessService().openSystemSettings()
                    }
                )
            )
        )
    }

    // P2-129: 选择模式 — 切换选中状态
    // 防死状态：真由用户点击 SelectablePeerComponent 触发，selectionSelectedIds 真实变化
    func toggleSelectionMode(userId: Int64) {
        let newList = ArrayList<Int64>()
        var found = false
        for (id in this.selectionSelectedIds) {
            if (id == userId) {
                found = true
            } else {
                newList.add(id)
            }
        }
        if (!found) {
            newList.add(userId)
        }
        this.selectionSelectedIds = newList
        // 源侧 ContactsController.swift:352-359：取消掉最后一个勾选直接退出选择态
        if (this.isTabHosted && newList.isEmpty()) {
            this.exitSelectionMode()
            return
        }
        // 勾选变化写进行数据（进 ForEach key）并重建显示列表，否则勾选图标不刷新
        this.applyFilterAndSort()
    }

    // ==================== 人工反馈 #11：删除确认 / pendingRemoval / 撤销 ====================

    func isPendingRemoval(userId: Int64): Bool {
        for (id in this.pendingRemovalIds) {
            if (id == userId) { return true }
        }
        return false
    }

    /** 弹出 S6 确认动作表（ContactsController.swift:619-631）：破坏色标题 + Cancel。 */
    func presentDeleteConfirm(ids: ArrayList<Int64>) {
        if (ids.isEmpty()) { return }
        this.deleteConfirmIds = ids
        let title = if (ids.size == 1) { "Delete Contact" } else { "Delete ${ids.size} Contacts" }
        this.deleteConfirmItems = [
            ContextMenuItem(
                title: title,
                destructive: true,
                centered: true,
                onClick: { =>
                    this.showContactDeleteConfirm = false
                    this.beginPendingRemoval(this.deleteConfirmIds)
                }
            ),
            ContextMenuItem.separator(),
            ContextMenuItem(
                title: "Cancel",
                centered: true,
                onClick: { => this.showContactDeleteConfirm = false }
            )
        ]
        this.showContactDeleteConfirm = true
    }

    /**
     * 确认后立即：退出选择态 + 行从列表消失 + 弹撤销条（5s）；倒计时结束才真正调 deleteContacts
     * （ContactsController.swift:640-694）。撤销只把 peerIds 移出 pendingRemoval，不发任何请求。
     */
    func beginPendingRemoval(ids: ArrayList<Int64>) {
        if (ids.isEmpty()) { return }
        this.exitSelectionMode()
        let merged = ArrayList<Int64>()
        for (id in this.pendingRemovalIds) { merged.add(id) }
        for (id in ids) {
            if (!this.isPendingRemoval(id)) { merged.add(id) }
        }
        this.pendingRemovalIds = merged
        this.applyFilterAndSort()

        this.undoGeneration += 1
        let generation = this.undoGeneration
        let text = if (ids.size == 1) { "Deleted 1 Contact" } else { "Deleted ${ids.size} Contacts" }
        // showUndo 内部：若已有 toast 在显示，先按 commit 收口（对位 animateInAsReplacement）
        getUndoToastService().showUndo(
            text,
            actionText: "Undo",
            durationMs: 5000,
            onUndo: { =>
                launch {
                    if (generation == this.undoGeneration) { this.undoPendingRemoval() }
                }
            },
            onCommit: { =>
                launch {
                    if (generation == this.undoGeneration) { this.commitPendingRemoval() }
                }
            }
        )
    }

    func undoPendingRemoval() {
        this.undoGeneration += 1
        this.pendingRemovalIds = ArrayList<Int64>()
        this.applyFilterAndSort()
    }

    /** 倒计时结束：向服务端提交 contacts.deleteContacts，并把 peer 从本地列表移除。 */
    func commitPendingRemoval() {
        this.undoGeneration += 1
        let ids = this.pendingRemovalIds
        if (ids.isEmpty()) { return }
        this.pendingRemovalIds = ArrayList<Int64>()
        // 本地先移除，避免刷新循环把行带回来
        let remaining = ArrayList<ContactDisplayData>()
        let delIds = ArrayList<Int64>()
        let delHashes = ArrayList<Int64>()
        for (c in this.contacts) {
            var hit = false
            for (id in ids) {
                if (c.userId == id) {
                    hit = true
                    break
                }
            }
            if (hit) {
                delIds.add(c.userId)
                delHashes.add(c.accessHash)
            } else {
                remaining.add(c)
            }
        }
        this.contacts = remaining
        this.applyFilterAndSort()
        let _ = spawn {
            var allOk = true
            var i: Int64 = 0
            while (i < delIds.size) {
                let uid = delIds[i]
                let ahash = delHashes[i]
                i += 1
                let ok = getRealContactService().deleteContact(uid, ahash)
                Hilog.info(0, "CjTelegram", "[ContactListPage] commit deleteContact uid=${uid} ok=${ok}")
                if (!ok) { allOk = false }
            }
            if (!allOk) {
                // 服务端失败：拉一次全量把行恢复，并提示
                setContactsNeedRefresh()
                launch {
                    this.contextMenuFeedback = "Failed to delete contact"
                    this.showContextFeedback = true
                    let _ = spawn {
                        sleep(Duration.second * 2)
                        launch { this.showContextFeedback = false }
                    }
                }
            }
        }
    }

    /** 选择态底部工具条（ContactsController.swift:454-475）：只有中键 "Delete N Contacts"。 */
    @Builder
    func buildSelectionDeleteToolbar() {
        Column {
            Text(if (this.selectionSelectedIds.size == 1) { "Delete 1 Contact" } else { "Delete ${this.selectionSelectedIds.size} Contacts" })
                .fontSize(17)
                .fontColor(0xFF3B30)
                .onClick({ _evt: ClickEvent =>
                    this.presentDeleteConfirm(this.selectionSelectedIds)
                })
        }
        .width(100.percent)
        .height(49)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(0xF7F7F7)
        .border(width: 0.5, color: 0xE5E5EA)
    }

    func isSelectionSelected(userId: Int64): Bool {
        for (id in this.selectionSelectedIds) {
            if (id == userId) { return true }
        }
        return false
    }

    func exitSelectionMode() {
        this.selectionMode = false
        this.selectionSelectedIds = ArrayList<Int64>()
        this.applyFilterAndSort()
    }

    // P2-128: 加载最近/常用 peer — HorizontalPeerService.getRecentPeers()
    // 死状态防护: @State var topPeers 在 launch{} 里由 service 结果回填，非默认值
    func loadTopPeers(): Unit {
        this.isLoadingTopPeers = true
        let _ = spawn {
            let svc = getHorizontalPeerService()
            let peers = svc.getRecentPeers(limit: 12)
            launch {
                this.topPeers = peers
                this.isLoadingTopPeers = false
            }
        }
    }
    
    func registerPhotoCallback() {
        if (this._photoCallbackRegistered) { return }
        this._photoCallbackRegistered = true
        getUserPhotoService().addPhotoReadyCallback({ userId: Int64, _dataUrl: String =>
            var relevant = false
            for (c in this.contacts) {
                if (c.userId == userId) { relevant = true; break }
            }
            if (relevant) {
                launch { this.avatarVersion = this.avatarVersion + 1 }
            }
        })
    }
    
    /**
     * 从 MTProto 加载联系人列表
     */
    func loadContacts() {
        this.isLoading = true
        this.errorText = ""
        let _ = spawn {
            try {
                let service = getRealContactService()
                let contactList = service.getContacts()
                let userIds = ArrayList<Int64>()
                for (c in contactList) {
                    if (c.userId > 0) { userIds.add(c.userId) }
                }
                if (!userIds.isEmpty()) {
                    getUserPhotoService().requestFullPhotosForUsers(userIds)
                }
                launch {
                    this.contacts = contactList
                    this.applyFilterAndSort()
                    this.isLoading = false
                    Hilog.info(0, "CjTelegram", "[ContactListPage] Loaded ${contactList.size} contacts")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ContactListPage] Load failed: ${e}")
                launch {
                    this.errorText = "Failed to load contacts"
                    this.isLoading = false
                }
            }
        }
    }
    
    /**
     * 应用搜索过滤和排序
     * 结果包装为 ContactEntry（实现 ToString）以确保 ForEach 正确 keying
     */
    func applyFilterAndSort() {
        var filtered = this.contacts
        // 人工反馈 #11：把当前勾选态写进行数据，使 ForEach key 随勾选变化
        for (c in this.contacts) {
            c.uiSelected = this.selectionMode && this.isSelectionSelected(c.userId)
            c.uiPresenceText = c.getLastSeenText()
        }
        // 人工反馈 #11：已确认删除、等待撤销窗口结束的行不再显示
        if (!this.pendingRemovalIds.isEmpty()) {
            let kept = ArrayList<ContactDisplayData>()
            for (c in filtered) {
                if (!this.isPendingRemoval(c.userId)) { kept.add(c) }
            }
            filtered = kept
        }
        
        // 搜索过滤
        if (!this.searchText.isEmpty()) {
            let query = this.searchText
            let result = ArrayList<ContactDisplayData>()
            for (c in this.contacts) {
                let name = c.getDisplayName()
                if (containsIgnoreCase(name, query) || containsIgnoreCase(c.username, query) || c.phone.contains(query)) {
                    result.add(c)
                }
            }
            filtered = result
        }
        
        // 排序
        let sortedMode = if (this.sortMode == 0) { ContactSortMode.ByName } else { ContactSortMode.ByLastSeen }
        let sorted = sortContacts(filtered, sortedMode)
        
        if (this.sortMode == 0) {
            // 按名字：使用 A-Z 分组
            this.displaySections = buildContactsGroupedBySection(filtered)
            this.displayItems = flattenContactSections(this.displaySections)
            this.displayContacts = ArrayList<ContactEntry>()
        } else {
            // 按最后上线：扁平列表
            this.displaySections = ArrayList<ContactSection>()
            this.displayItems = ArrayList<ContactListDisplayItem>()
            let entries = ArrayList<ContactEntry>()
            for (c in sorted) {
                entries.add(ContactEntry(c))
            }
            this.displayContacts = entries
        }
    }

    /**
     * S8-03: remote peers for the search query — iOS ContactsSearchContainerNode.swift:357-364
     * (contacts.searchRemotePeers delayed 0.2 s, previous results kept while loading) and
     * :500-575 (users only, skipping peers already listed in the local contacts group).
     */
    private func scheduleGlobalSearch(value: String): Unit {
        this.globalSearchGeneration = this.globalSearchGeneration + 1
        let generation = this.globalSearchGeneration
        let query = value.trimAscii()
        if (query.isEmpty() || this.selectionMode) {
            this.globalResults = ArrayList<ContactEntry>()
            return
        }
        let _ = spawn {
            sleep(Duration.millisecond * 200)
            if (generation != this.globalSearchGeneration) { return }
            let found = getRealContactService().searchRemoteUsers(query)
            launch {
                if (generation == this.globalSearchGeneration) {
                    let localIds = HashMap<Int64, Bool>()
                    for (item in this.displayItems) {
                        match (item.contact) {
                            case Some(c) => localIds[c.userId] = true
                            case None => ()
                        }
                    }
                    for (e in this.displayContacts) { localIds[e.contact.userId] = true }
                    let entries = ArrayList<ContactEntry>()
                    for (c in found) {
                        if (!localIds.contains(c.userId)) { entries.add(ContactEntry(c)) }
                    }
                    this.globalResults = entries
                }
            }
        }
    }

    private func globalResultSubtitle(c: ContactDisplayData): String {
        if (c.username.size > 0) { return "@" + c.username }
        return c.getLastSeenText()
    }

    @Builder
    func buildGlobalResultRow(c: ContactDisplayData) {
        ListItem {
            Row {
                if (getContactsPeerService().getAvatarUrl(c.userId).size > 0) {
                    Image(getContactsPeerService().getAvatarUrl(c.userId))
                        .width(40).height(40).borderRadius(20).objectFit(ImageFit.Cover)
                        .margin(right: 14)
                } else {
                    Column {
                        Text(c.getAvatarInitials())
                            .fontSize(if (c.getAvatarInitials().size > 1) { 15 } else { 18 })
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFFFFFF)
                    }
                    .width(40).height(40).borderRadius(20)
                    .backgroundColor(getContactsPeerService().getAvatarColor(c.userId))
                    .justifyContent(FlexAlign.Center)
                    .margin(right: 14)
                }
                Column {
                    Text(c.getDisplayName())
                        .fontSize(17).fontColor(this.presentation.textColor).fontWeight(FontWeight.Medium)
                        .maxLines(1).textOverflow(TextOverflow.Ellipsis)
                    Text(this.globalResultSubtitle(c))
                        .fontSize(13).fontColor(this.presentation.secondaryTextColor)
                        .margin(top: 2).maxLines(1).textOverflow(TextOverflow.Ellipsis)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
            }
            .width(100.percent)
            .height(49)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(this.presentation.backgroundColor)
            .onClick({ _ =>
                setSelectedChat(c.userId, c.getDisplayName(), "user")
                routerPush("ChatRoomPage", c.getDisplayName())
            })
        }
    }

    /**
     * TC-0174 返修：右侧字母索引条内容来源。
     * 对位源侧 ContactListNode.swift:878-895 preparedContactListNodeTransition(generateIndexSections:)
     * ——按 displaySections 的现有顺序逐个取字母，不排序/不去重/不补齐/不追加 "#"/不裁剪
     * （buildContactsGroupedBySection 已完成顺序扫描去重，与渲染顺序天然一致）。
     * 不得照抄 CountrySelectionPage.cj:49-52 的静态 A-Z 26 字母数组（源侧是动态、只含
     * 实际存在的分区）。
     */
    private func indexBarSections(): Array<String> {
        let result = ArrayList<String>()
        for (sec in this.displaySections) {
            result.add(sec.letter)
        }
        return result.toArray()
    }

    /**
     * TC-0174 返修：字母索引条点击 → 列表跳位。
     * 对位源侧 ContactListNode.swift:1378-1412 indexSelected（瞬时跳位，无动画）。
     * ContactListPage 用真实 List + Scroller，直接 scrollToIndex（先例
     * ChatRoomPage.cj:1206），不照抄 CountrySelectionPage 的像素累加式跳转。
     */
    private func scrollToIndexSection(alphaIdx: Int64): Unit {
        if (alphaIdx < 0 || alphaIdx >= Int64(this.displaySections.size)) { return }
        let letter = this.displaySections[alphaIdx].letter
        var flatIdx: Int64 = -1
        var i: Int64 = 0
        while (i < Int64(this.displayItems.size)) {
            let item = this.displayItems[i]
            if (item.isSection && item.sectionLetter == letter) {
                flatIdx = i
                break
            }
            i += 1
        }
        if (flatIdx < 0) { return }
        // displayItems 下标 → List 下标的前导项偏移：权限卡片/空态项在索引条可见时
        // 恒不上树（贡献 0）；topPeers 行仅 selectionMode 下上树，Invite Friends 行
        // 仅非 selectionMode 下上树 —— 索引条只在非 selectionMode 下可见（sortMode==0
        // 分支不受 selectionMode 影响），故 leading 恒为 Invite Friends 贡献的 1。
        let leading: Int64 = if (!this.selectionMode) {
            1
        } else if (!this.topPeers.isEmpty()) {
            1
        } else {
            0
        }
        try {
            this.contactsListScroller.scrollToIndex(Int32(leading + flatIdx), smooth: false, align: ScrollAlign.Start)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ContactListPage] scrollToIndexSection failed: ${e}")
        }
    }

    /**
     * P2-126: 通讯录权限引导卡片（内联，避免跨包 @Component @State 限制 S-015）
     *
     * 对应 iOS Telegram ContactListNode permissionInfo + permissionEnable 行：
     * - 图标 + 标题 "Allow Telegram Access Your Contacts"
     * - 说明文字 "To find your friends..."
     * - "Allow Access" 按钮触发系统权限弹窗
     */
    @Builder
    func buildPermissionCard() {
        ListItem {
            Column {
                Row {
                    Text("!")
                        .fontSize(15)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFFFFFF)
                        .width(22)
                        .height(22)
                        .borderRadius(11)
                        .backgroundColor(0xFFFF3B30)
                        .textAlign(TextAlign.Center)
                        .margin(right: 10)
                    Text(trSource("Access to Contacts"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.presentation.textColor)
                        .layoutWeight(1)
                    Text("×")
                        .fontSize(24)
                        .fontColor(0xFFC7C7CC)
                        .onClick({ _ => this.showContactsPermissionNotice = false })
                }
                .width(100.percent)
                .alignItems(VerticalAlign.Center)

                Text(trSource("Please allow Telegram access to your phonebook to seamlessly find all your friends."))
                    .fontSize(15)
                    .fontColor(this.presentation.secondaryTextColor)
                    .lineHeight(22)
                    .width(100.percent)
                    .margin(top: 10, bottom: 12)

                Divider()
                    .color(0xFFE5E5EA)
                    .strokeWidth(0.5)

                Text(this.getPermButtonLabel())
                    .fontSize(17)
                    .fontColor(if (this.contactsPermRequesting) { 0xFF8E8E93 } else { 0xFF007AFF })
                    .width(100.percent)
                    .padding(top: 12, bottom: 4)
                    .enabled(!this.contactsPermRequesting)
                    .onClick({ _ => this.requestContactsPermission() })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 8)
            .backgroundColor(this.presentation.backgroundColor)
        }
    }

    /**
     * TC-0178 返修：全屏权限占位覆盖层（无参 @Builder，避免 D-115 带参 @Builder 冻结初值）。
     * 对位 ContactListNode.swift:1268 authorizationNode（PermissionContentNode）+ :2314-2315
     * 的覆盖显隐语义（覆盖在 List 之上，不替换 List；List 照常渲染，Invite Friends 仍在）。
     * 形态与位置照抄同页既有覆盖层 showContextMenu（:1350-1364 附近）。
     */
    @Builder
    func buildPermissionPlaceholder() {
        Column {
            // 插图占位：Settings/Permissions/Contacts 对应资源当前不在 resource_catalog.json
            // 中（与 TC-0172 clist_ic_add 同类缺口）。case doc A2/D1 禁止 emoji/字形/色块替代，
            // 资源迁移不在本 feature allowlist 内，故本次留空该图位，待资源迁移后补挂。

            Text(trSource("Access to Contacts"))
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.presentation.textColor)
                .margin(top: 16)

            Text(trSource("Please allow Telegram access to your phonebook to seamlessly find all your friends."))
                .fontSize(15)
                .fontColor(this.presentation.secondaryTextColor)
                .lineHeight(22)
                .textAlign(TextAlign.Center)
                .width(260)
                .margin(top: 8)

            Text(this.getPermButtonLabel())
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor(if (this.contactsPermRequesting) { 0xFF8E8E93 } else { 0xFF007AFF })
                .enabled(!this.contactsPermRequesting)
                .margin(top: 20)
                .onClick({ _ => this.requestContactsPermission() })

            // 源侧 openPrivacyPolicy（ContactListNode.swift:2150-2152）由宿主注入落点；
            // getGlobalAbilityContext 是本工程既有外链打开通道（AdInfoScreen.cj 同款用法），
            // 落点 https://telegram.org/privacy，case doc E3 只判该入口是否存在。
            Text(trSource("Privacy Policy"))
                .fontSize(15)
                .fontColor(0xFF007AFF)
                .margin(top: 12)
                .onClick({ _ => this.openContactsPrivacyPolicy() })
        }
        .width(100.percent)
        .height(100.percent)
        .position(x: 0, y: 0)
        .backgroundColor(this.presentation.backgroundColor)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding(left: 24, right: 24)
    }

    /**
     * TC-0178 返修：隐私政策外链，复用工程既有 Want 打开通道（AdInfoScreen.cj 同款）。
     */
    private func openContactsPrivacyPolicy(): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let want = Want(action: "ohos.want.action.viewData", uri: "https://telegram.org/privacy")
                    ctx.startAbility(want)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ContactListPage] openContactsPrivacyPolicy failed: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[ContactListPage] No context for openContactsPrivacyPolicy")
        }
    }

    /**
     * P2-129: 选择模式导航栏（替换正常导航栏）
     *
     * 对应 iOS ContactListController 在 selectionMode=true 时：
     * - 左: "Cancel" → 退出选择模式
     * - 中: "Select Members"
     * - 右: "Done (N)" → 回调 onSelectionDone 并退出
     */
    @Builder
    func buildSelectionHeader() {
        if (this.isTabHosted) {
            // 人工反馈 #11：Contacts tab 的选择态导航栏（ContactsControllerNode.swift:307-320）：
            // 左 "Done"（粗体，退出选择态）/ 标题 "N Selected" / 右侧无按钮（"+" 消失）。
            Row {
                Text(trSource("Done"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x317AFF)
                    .onClick({ _evt: ClickEvent =>
                        this.exitSelectionMode()
                    })
                Blank()
                    .layoutWeight(1)
                Text("${this.selectionSelectedIds.size} Selected")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                Blank()
                    .layoutWeight(1)
                Text(trSource("Done"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .opacity(0.0)
            }
            .width(100.percent)
            .height(52)
            .padding(left: 16, right: 16)
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)
        } else {
        Row {
            Text(trSource("Cancel"))
                .fontSize(17)
                .fontColor(0x317AFF)
                .onClick({ _evt: ClickEvent =>
                    this.exitSelectionMode()
                })

            Blank()
                .layoutWeight(1)

            Text("Select Members")
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)

            Blank()
                .layoutWeight(1)

            Text(if (this.selectionSelectedIds.isEmpty()) { "Done" } else { "Done (${this.selectionSelectedIds.size})" })
                .fontSize(17)
                .fontColor(if (this.selectionSelectedIds.isEmpty()) { 0xCCCCCC } else { 0x317AFF })
                .fontWeight(FontWeight.Medium)
                .onClick({ _evt: ClickEvent =>
                    if (!this.selectionSelectedIds.isEmpty()) {
                        let _ = this.onSelectionDone(this.selectionSelectedIds)
                        this.exitSelectionMode()
                    }
                })
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .backgroundColor(0xF7F7F7)
        .alignItems(VerticalAlign.Center)
        }
    }

    /**
     * P2-129: 已选成员 chips 横向条（选择模式下显示在搜索框上方）
     *
     * 与 CreateGroupPage 的 buildSelectedChipsBar 模式相同：
     * Scroll { Row { ForEach(selectedIds) } }.scrollable(Horizontal)
     */
    @Builder
    func buildSelectionChipsBar() {
        if (!this.selectionSelectedIds.isEmpty()) {
            Scroll {
                Row {
                    ForEach(this.selectionSelectedIds, itemGenerator: { uid: Int64, _idx: Int64 =>
                        Column {
                            SelectedPeerChip(
                                peerId: uid,
                                displayName: this.selChipName(uid),
                                avatarUrl: getUserPhotoService().getUserPhotoPath(uid),
                                avatarColor: Int64(getAvatarColorForPeer(uid)),
                                onRemove: { id: Int64 =>
                                    this.toggleSelectionMode(id)
                                }
                            )
                        }
                    })
                }
                .padding(left: 8, right: 8)
                .alignItems(VerticalAlign.Center)
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width(100.percent)
            .height(88)
        }
    }

    func selChipName(uid: Int64): String {
        for (c in this.contacts) {
            if (c.userId == uid) { return c.getDisplayName() }
        }
        return "User ${uid}"
    }

    /**
     * 填充 contactMenuItems 并打开 ContextMenuView。
     * 在 ContactsPeerComponent.onLongPress 回调里调用。
     */
    /** 长按联系人：从被按行弹出会话预览 + 动作面板（动作项与 openContactMenu 同一份） */
    func openContactPreview(c: ContactDisplayData, sourceY: Float64, sourceHeight: Float64): Unit {
        this.openContactMenu(c.userId, c.accessHash, c.getDisplayName())
        this.showContextMenu = false
        let wrapped = ArrayList<ContextMenuItem>()
        for (item in this.contactMenuItems) {
            if (item.isSeparator) {
                wrapped.add(ContextMenuItem.separator())
            } else {
                let action = item.onClick
                wrapped.add(ContextMenuItem(
                    title: item.title, iconRes: item.iconRes, destructive: item.destructive, enabled: item.enabled,
                    onClick: { =>
                        this.showContactPreview = false
                        action()
                    }
                ))
            }
        }
        this.contactPreviewItems = wrapped.toArray()
        this.previewAvatar = getContactsPeerService().getAvatarUrl(c.userId)
        this.previewSubtitle = c.getLastSeenText()
        this.previewSourceY = sourceY
        this.previewSourceHeight = sourceHeight
        this.showContactPreview = true
    }

    /**
     * S8-08：Start Secret Chat（iOS ContactContextMenus.swift → createSecretChat →
     * messages.getDhConfig + messages.requestEncryption，对方在线后经 updateEncryption 完成密钥协商）。
     * 本端目前只完成发起（服务端与对端会出现该秘密聊天请求）；秘密聊天会话页 / 密钥协商完成后的
     * 提示与加密消息收发尚未接线，见提交说明。
     */
    private func startSecretChatWithContact(userId: Int64, accessHash: Int64, displayName: String): Unit {
        let _ = spawn {
            try {
                let hash = if (accessHash != 0) { accessHash } else { getRealMessageService().getAccessHashForUser(userId) }
                let chatId = getTelegramCore_SecretChatsService().requestEncryption(userId, hash)
                Hilog.info(0, "CjTelegram", "[ContactListPage] startSecretChat user=${userId} secretChatId=${chatId}")
                launch {
                    // W5 S8-08：encryptedChat.id 是 TL int（int32），服务端会分配负值
                    // （真机 -1109090131）；requestEncryption 失败返回 0，只能按 != 0 判成功。
                    if (chatId != 0) {
                        // iOS ContactContextMenus.swift:172-184：createSecretChat 成功后直接
                        // navigateToChatController(.peer(secretChat))。会话键用 secretChatId，
                        // 对端 userId 另行传给会话页取头像 / 状态文案。
                        setSelectedChat(Int64(chatId), displayName, "secret")
                        setSelectedChatDraft("")
                        setSelectedSecretPeerUserId(userId)
                        routerPush("ChatRoomPage", displayName)
                    } else {
                        showToast("Could not start secret chat")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ContactListPage] startSecretChat error: ${e}")
                launch { showToast("Could not start secret chat") }
            }
        }
    }

    func openContactMenu(userId: Int64, accessHash: Int64, displayName: String) {
        // 人工反馈 #10-2：菜单项集合对齐源侧 ContactContextMenus.swift:105-250 ——
        // Send Message / Start Secret Chat / Call / Video Call / Delete Contact / ─ / Select。
        // 已删除目标侧多出的 Info 与 Block User。S8-08：补 Start Secret Chat 入口
        // （ContactList_Context_StartSecretChat → messages.requestEncryption，DH A 方）。
        this.contextMenuUserId = userId
        this.contextMenuAccessHash = accessHash
        this.contextMenuDisplayName = displayName
        this.contactMenuItems = [
            ContextMenuItem(
                title: "Send Message",
                // diag-suite_contacts_peers-TC-0175.md B1 row1 asks for a real
                // "Chat/Context Menu/Message" vector icon (contact_ic_message, not yet
                // converted into resources/). clist_ic_newmessage is the closest already
                // -catalogued glyph with the same "compose/send message" semantic used
                // elsewhere in this same package (ChatListPage's new-message action).
                iconRes: @r(app.media.clist_ic_newmessage),
                onClick: { =>
                    setSelectedChat(this.contextMenuUserId, this.contextMenuDisplayName, "user")
                    routerPush("ChatRoomPage", this.contextMenuDisplayName)
                    this.showContextMenu = false
                }
            ),
            ContextMenuItem(
                title: "Start Secret Chat",
                iconRes: @r(app.media.clist_ic_secretchat),
                onClick: { =>
                    let uid = this.contextMenuUserId
                    let hash = this.contextMenuAccessHash
                    let name = this.contextMenuDisplayName
                    this.showContextMenu = false
                    this.startSecretChatWithContact(uid, hash, name)
                }
            ),
            ContextMenuItem(
                title: "Call",
                iconRes: @r(app.media.chatroom_ic_call),
                onClick: { =>
                    setSelectedChat(this.contextMenuUserId, this.contextMenuDisplayName, "user")
                    let _ = getCallService().requestCall(this.contextMenuUserId, this.contextMenuAccessHash, this.contextMenuDisplayName, false)
                    routerPush("CallScreen", "outgoing")
                    this.showContextMenu = false
                }
            ),
            ContextMenuItem(
                title: "Video Call",
                iconRes: @r(app.media.chatroom_ic_videocall),
                onClick: { =>
                    setSelectedChat(this.contextMenuUserId, this.contextMenuDisplayName, "user")
                    let _ = getCallService().requestCall(this.contextMenuUserId, this.contextMenuAccessHash, this.contextMenuDisplayName, true)
                    routerPush("VideoCallScreen", "outgoing")
                    this.showContextMenu = false
                }
            ),
            ContextMenuItem(
                title: "Delete Contact",
                destructive: true,
                iconRes: @r(app.media.clist_ic_delete),
                onClick: { =>
                    // 源侧 ContactContextMenus.swift:234-240 → S6 确认动作表 → pendingRemoval + 撤销条
                    let uid = this.contextMenuUserId
                    this.showContextMenu = false
                    let ids = ArrayList<Int64>()
                    ids.add(uid)
                    this.presentDeleteConfirm(ids)
                }
            ),
            // diag-suite_contacts_peers-TC-0175.md B1 row6: separator + "Select" between
            // Delete Contact and the rest, mirroring source's ContactContextMenus.swift
            // grouping (destructive actions | selection entry).
            ContextMenuItem.separator(),
            ContextMenuItem(
                title: "Select",
                iconRes: @r(app.media.chatroom_ic_select),
                onClick: { =>
                    this.selectionMode = true
                    this.toggleSelectionMode(this.contextMenuUserId)
                    this.showContextMenu = false
                }
            )
        ]
        this.showContextMenu = true
    }

    /**
     * 轮询刷新循环：检测 AddContactPage 添加联系人后的刷新信号
     * 每 1 秒检查一次全局 _contactsNeedRefresh 标记
     *
     * P2-129: 联系人行渲染 — 选择模式下使用 SelectablePeerComponent，否则保持 P2-123/126 行为
     */
    @Builder
    func buildContactRow(c: ContactDisplayData) {
        ListItem {
            Column {
                if (this.selectionMode) {
                    // 选择模式：使用可多选行组件
                    SelectablePeerComponent(
                        peerId: c.userId,
                        displayName: c.getDisplayName(),
                        avatarUrl: getUserPhotoService().getUserPhotoPath(c.userId),
                        avatarColor: Int64(getAvatarColorForPeer(c.userId)),
                        isOnline: c.isOnline,
                        isSelected: this.isSelectionSelected(c.userId),
                        compact: true,
                        onToggleSelection: { id: Int64 =>
                            this.toggleSelectionMode(id)
                        }
                    )
                } else {
                    // 正常模式：保留 P2-123/126 既有行为（单击进聊天 + 长按菜单）
                    ContactsPeerComponent(
                        contact: c,
                        onClick: { =>
                            setSelectedChat(c.userId, c.getDisplayName(), "user")
                            routerPush("ChatRoomPage", c.getDisplayName())
                        },
                        onLongPressAt: { y: Float64, h: Float64 =>
                            this.openContactPreview(c, y, h)
                        }
                    )
                }
            }
        }
    }
    
    var _touchDownTime: Int64 = 0
    
    func startRefreshSync() {
        if (this._syncActive) { return }
        this._syncActive = true
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[ContactListPage] Refresh sync loop started")
            while (this._syncActive) {
                if (checkAndClearContactsRefresh()) {
                    Hilog.info(0, "CjTelegram", "[ContactListPage] Refresh signal detected, reloading contacts")
                    try {
                        let service = getRealContactService()
                        let contactList = service.getContacts()
                        launch {
                            this.contacts = contactList
                            this.applyFilterAndSort()
                            Hilog.info(0, "CjTelegram", "[ContactListPage] Refreshed contacts")
                        }
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ContactListPage] Refresh failed: ${e}")
                    }
                } else {
                    // 人工反馈 #4b：每秒从共享缓存核对一次 presence，有变化才重建列表
                    launch {
                        if (this.syncAllPresenceFromCache()) {
                            this.applyFilterAndSort()
                        }
                    }
                }
                sleep(Duration.second)
            }
        }
    }
    
    public func build() {
        Column {
            // ==================== 导航栏（P2-129: 选择模式时切换为选择模式导航栏）====================
            if (this.selectionMode) {
                this.buildSelectionHeader()
                // 已选 chips 横向条（仅选人器实例；Contacts tab 选择态源侧无 chips）
                if (!this.isTabHosted) {
                    this.buildSelectionChipsBar()
                }
            } else {
                // ==================== iOS 风格正常导航栏（P2-123 既有）====================
                Row {
                    // 左侧: Sort 按钮 — iOS-26 parity: 近黑文字（浅色胶囊已在下方）
                    Text(this.presentationStrings.getOr("Contacts_Sort", "Sort"))
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                        .height(36)
                        .padding(left: 12, right: 12)
                        .borderRadius(18)
                        .backgroundColor(this.presentation.cardColor)
                        .textAlign(TextAlign.Center)
                        .onClick({ _evt: ClickEvent =>
                            // 必须走 openSortMenu()：直接置 showSortSheet 会绕过入场动画，
                            // 且关闭动画残留的 scale=0.01/alpha=0 使第二次打开不可见（实测"按不了"）。
                            this.openSortMenu()
                        })

                    Blank()
                        .layoutWeight(1)

                    // 中间: Contacts 标题
                    Text(this.presentationStrings.getOr("Contacts_Title", "Contacts"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.presentation.textColor)

                    Blank()
                        .layoutWeight(1)

                    // 右侧: + 添加按钮（CTL-SHARED-001 按压 alpha0.4）
                    // 人工反馈 R2-4：源侧是矢量图标 Chat List/AddIcon，原 Text("+") 字形不合规
                    //（TC-0172 早已标记）；复用同仓 itemlist_ic_plus 矢量（同形 30×30 "+"）。
                    Column {
                        Image(@r(app.media.itemlist_ic_plus))
                            .width(28)
                            .height(28)
                            .fillColor(0x317AFF)
                    }
                        .width(36)
                        .height(36)
                        .borderRadius(18)
                        .backgroundColor(this.presentation.cardColor)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .opacity(if (this.pressedNav == "add") { 0.4 } else { 1.0 })
                        .onTouch({ evt =>
                            match (evt.eventType) {
                                case TouchType.Down => this.pressedNav = "add"
                                case _ => safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 200, curve: Curve.EaseInOut), { => this.pressedNav = "" })
                            }
                        })
                        .onClick({ _evt: ClickEvent =>
                            // CTL-CONTACTS-003: iOS "+" 打开 NewContactScreen 底部 sheet（非整页 push）
                            // 人工反馈 #3：先过通讯录权限门（ContactsController.swift:749-758）
                            this.guardContactsAccess({ => this.openNewContactSheet() })
                        })
                }
                .width(100.percent)
                .height(52)
                .padding(left: 16, right: 16)
                .backgroundColor(this.presentation.navBarColor)
                .alignItems(VerticalAlign.Center)
            }

            // 分隔线
            Divider()
                .color(this.presentation.dividerColor)
                .strokeWidth(0.5)

            // ==================== 搜索栏（SearchBar 原子组件） ====================
            Column {
                if (!this.showNewContactSheet) {
                    SearchBar(
                        loading: false,
                        backArrow: false,
                        text: this.searchText,
                        hint: this.presentationStrings.getOr("Common_Search", "Search"),
                        localizedHintKey: "Common.Search",
                        // TC-0018 返修（§B1/§C）：供 FocusControl 定位，对位
                        // ContactsController.swift:554 searchBarNode.activate()。
                        inputId: "contacts_search_input",
                        onChange: { value: String =>
                            this.searchText = value
                            this.applyFilterAndSort()
                            this.scheduleGlobalSearch(value)
                        },
                        onFocus: { =>
                            this.isSearching = true
                            this.onSearchVisibilityChange(true)
                        },
                        onCancel: { =>
                            this.searchText = ""
                            this.isSearching = false
                            this.applyFilterAndSort()
                            this.scheduleGlobalSearch("")
                            this.onSearchVisibilityChange(false)
                        },
                        // TC-0018 返修（§B1）：tab bar 激活（fireContactsSearchActivate 处理器）
                        // 与页内聚焦激活都写同一个 isSearching，走同一渲染分支
                        showCancel: this.isSearching
                    )
                } else {
                    // Static replacement while modal is visible. Removing the
                    // TextInput prevents HarmonyOS from restoring its focus
                    // after contact.addContactViaUI returns.
                    Column {
                        Row {
                            Image(@r(app.media.clist_ic_search))
                                .width(15)
                                .height(15)
                                .fillColor(this.presentation.secondaryTextColor)
                                .margin(right: 6)
                            Text(if (this.searchText.isEmpty()) { this.presentationStrings.getOr("Common_Search", "Search") } else { this.searchText })
                                .fontSize(17)
                                .fontColor(if (this.searchText.isEmpty()) { this.presentation.secondaryTextColor } else { this.presentation.textColor })
                        }
                        .width(100.percent)
                        .height(44)
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(22)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(VerticalAlign.Center)
                    }
                    .width(100.percent)
                    .height(60)
                    .padding(left: 16, right: 16, top: 8, bottom: 8)
                }
            }
            .width(100.percent)
            .backgroundColor(this.presentation.navBarColor)
            .padding(bottom: 6)
            
            // ==================== 联系人列表 ====================
            if (this.isLoading) {
                // 加载中
                Column {
                    LoadingProgress()
                        .width(32)
                        .height(32)
                        .color(0x317AFF)
                    Text("Loading contacts...")
                        .fontSize(14)
                        .fontColor(0x999999)
                        .margin(top: 8)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.errorText.size > 0) {
                // 错误状态
                Column {
                    Text(this.errorText)
                        .fontSize(16)
                        .fontColor(0xFF3B30)
                    Text("Tap to retry")
                        .fontSize(14)
                        .fontColor(0x317AFF)
                        .margin(top: 8)
                        .onClick({ evt =>
                            this.loadContacts()
                        })
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                // TC-0174 返修：Stack 外层叠加右侧字母索引条（对位 ContactListNode.swift:1022/
                // 1240/1289 indexNode 与 listNode 平级 addSubnode）。List 及其全部链式属性
                // 原样保留，仅把 layoutWeight 移到 Stack 上、List 自身改用 height(100.percent)。
                Stack(alignContent: Alignment.End) {
                List(scroller: this.contactsListScroller) {
                    // ==================== P2-126: 通讯录权限门控 ====================
                    // TC-0178 返修：门控方向按源侧结构改写。源侧 ContactListNode.swift:458
                    // `!peers.isEmpty && !syncDisabled` 是"列表非空才显示内联条"，此前目标侧
                    // 写反成"列表为空才显示"且只有这一条形态。现拆成两条互补分支：非空 → 内联
                    // 卡片（本条件）；为空 → 全屏占位（build() List 块之后的 buildPermissionPlaceholder）。
                    if (!this.contactsPermGranted && this.showContactsPermissionNotice && this.contactsSyncEnabled && !this.contacts.isEmpty()) {
                        this.buildPermissionCard()
                    }

                    // ==================== P2-128: 最近/常用 peer 横向条 ====================
                    if (!this.topPeers.isEmpty() && this.selectionMode) {
                        ListItem {
                            Column {
                                Text(trSource("Recent"))
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .fontWeight(FontWeight.Medium)
                                    .width(100.percent)
                                    .padding(left: 16, top: 8, bottom: 4)
                                    .textAlign(TextAlign.Start)
                                Scroll {
                                    Row {
                                        ForEach(this.topPeers, itemGenerator: { peer: HorizontalPeerItem, _idx: Int64 =>
                                            Column {
                                                // 内联头像 Stack（避免跨包 @Component @State 限制 S-015）
                                                Stack(alignContent: Alignment.BottomEnd) {
                                                    if (peer.avatarLocalPath.size > 0) {
                                                        Image(peer.avatarLocalPath)
                                                            .width(50)
                                                            .height(50)
                                                            .borderRadius(25)
                                                            .objectFit(ImageFit.Cover)
                                                    } else {
                                                        Column {
                                                            Text(topPeerInitials(peer.displayName))
                                                                .fontSize(18)
                                                                .fontColor(0xFFFFFF)
                                                                .fontWeight(FontWeight.Medium)
                                                        }
                                                        .width(50)
                                                        .height(50)
                                                        .borderRadius(25)
                                                        .backgroundColor(topPeerAvatarColor(peer.peerId))
                                                        .justifyContent(FlexAlign.Center)
                                                        .alignItems(HorizontalAlign.Center)
                                                    }
                                                    if (peer.isOnline) {
                                                        Column {}
                                                            .width(12)
                                                            .height(12)
                                                            .borderRadius(6)
                                                            .backgroundColor(0xFF4CD964)
                                                            .border(width: 2, color: 0xFFFFFFFF)
                                                    }
                                                }
                                                .width(50)
                                                .height(50)
                                                Text(topPeerShortName(peer.displayName))
                                                    .fontSize(11)
                                                    .fontColor(0x000000)
                                                    .maxLines(1)
                                                    .textOverflow(TextOverflow.Ellipsis)
                                                    .width(60)
                                                    .textAlign(TextAlign.Center)
                                                    .margin(top: 4)
                                            }
                                            .width(70)
                                            .height(80)
                                            .alignItems(HorizontalAlign.Center)
                                            .margin(right: 4)
                                            .onClick({ evt =>
                                                setSelectedChat(peer.peerId, peer.displayName, peer.peerType)
                                                routerPush("ChatRoomPage", peer.displayName)
                                            })
                                        })
                                    }
                                    .padding(left: 12, right: 12, top: 4, bottom: 8)
                                }
                                .scrollable(ScrollDirection.Horizontal)
                                .width(100.percent)
                                .height(92)
                                .scrollBar(BarState.Off)
                                Divider()
                                    .color(0xE5E5EA)
                                    .strokeWidth(0.5)
                            }
                            .width(100.percent)
                            .backgroundColor(this.presentation.backgroundColor)
                        }
                    }

                    // ==================== P2-124: 顶部动作行（选择模式下隐藏）====================
                    if (!this.selectionMode) {
                    // Invite Friends（资源保真修复：真实矢量图标 Contact List/InviteActionIcon.imageset/ic_heart.pdf
                    // 替代 "👤+" 字形——对应 iOS InviteContactsControllerNode.swift Contacts_ShareTelegram 行）
                    ListItem {
                        Row {
                            // iOS parity: 蓝色 person-add 图标（无橙色填充圆），对齐 iOS InviteAction
                            Row {
                                Image(@r(app.media.contact_ic_addmember))
                                    .width(28)
                                    .height(28)
                                    .fillColor(0x007AFF)
                            }
                            .width(40)
                            .height(40)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(VerticalAlign.Center)
                            .margin(right: 14)
                            Text(this.presentationStrings.getOr("Contacts_InviteFriends", "Invite Friends"))
                                .fontSize(17)
                                .fontColor(0x007AFF)
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(if (this.invitePressed) { this.presentation.itemHighlightedBackgroundColor } else { this.presentation.backgroundColor })
                        .onTouch({ evt =>
                            match (evt.eventType) {
                                case TouchType.Down => this.invitePressed = true
                                case _ => safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 400, curve: Curve.EaseInOut), { => this.invitePressed = false })
                            }
                        })
                        .onClick({ evt =>
                            // iOS openInvite → InviteContactsController。分享和短信邀请
                            // 都在下一页完成，主列表不直接复制链接。
                            // 人工反馈 #3：与 "+" 同一套权限门
                            this.guardContactsAccess({ => routerPush("InviteContactsPage", "") })
                        })
                    }
                    } // end if (!this.selectionMode) for action rows

                    // 联系人列表项
                    if (this.sortMode == 0 && this.displayItems.isEmpty() && !this.searchText.isEmpty() && this.globalResults.isEmpty()) {
                        ListItem {
                            Column {
                                Text("No results for '${this.searchText}'")
                                    .fontSize(15)
                                    .fontColor(0x999999)
                                    .margin(top: 40)
                            }
                            .width(100.percent)
                            .alignItems(HorizontalAlign.Center)
                        }
                    }
                    if (this.sortMode == 1 && this.displayContacts.isEmpty() && !this.searchText.isEmpty() && this.globalResults.isEmpty()) {
                        ListItem {
                            Column {
                                Text("No results for '${this.searchText}'")
                                    .fontSize(15)
                                    .fontColor(0x999999)
                                    .margin(top: 40)
                            }
                            .width(100.percent)
                            .alignItems(HorizontalAlign.Center)
                        }
                    }
                    
                    // 按名字：A-Z 分组（displayItems = section headers + contacts）
                    if (this.sortMode == 0) {
                        ForEach(this.displayItems, itemGenerator: { item: ContactListDisplayItem, _idx: Int64 =>
                            if (item.isSection) {
                                ListItem {
                                    Text(item.sectionLetter)
                                        .fontSize(13)
                                        .fontColor(0x8E8E93)
                                        .fontWeight(FontWeight.Medium)
                                        .width(100.percent)
                                        .height(28)
                                        .padding(left: 16, top: 4)
                                        .backgroundColor(0xF2F2F7)
                                }
                            } else {
                                if (item.contact.isSome()) {
                                    this.buildContactRow(item.contact.getOrThrow())
                                } else {
                                    ListItem { Blank().width(1).height(1) }
                                }
                            }
                        })
                    }
                    
                    // 按最后上线：扁平列表
                    if (this.sortMode == 1) {
                        ForEach(this.displayContacts, itemGenerator: { entry: ContactEntry, _index: Int64 =>
                            this.buildContactRow(entry.contact)
                        })
                    }

                    // S8-03: GLOBAL SEARCH (iOS ChatListSearchItemHeader .globalPeers).
                    if (!this.searchText.isEmpty() && !this.globalResults.isEmpty()) {
                        ListItem {
                            Text(this.presentationStrings.getOr("DialogList_SearchSectionGlobal", "Global Search").toAsciiUpper())
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .fontWeight(FontWeight.Medium)
                                .width(100.percent)
                                .height(28)
                                .padding(left: 16, top: 4)
                                .backgroundColor(0xF2F2F7)
                        }
                        ForEach(this.globalResults, itemGenerator: { entry: ContactEntry, _gi: Int64 =>
                            this.buildGlobalResultRow(entry.contact)
                        })
                    }

                    // iOS parity（TC-SCROLL）：底部 content inset 占位（悬浮 tab bar 不挡末条；
                    // 测量式高度使短内容也超视口 → Spring 恒可回弹）
                    ListItem {
                        Row {}.height(this.contactsBottomFillerH())
                    }
                }
                .width(100.percent)
                .height(100.percent)
                // iOS parity：alwaysBounceVertical（ListView.swift:508）
                .edgeEffect(EdgeEffect.Spring)
                .onAreaChange({ _: Area, newArea: Area =>
                    this.listVH = newArea.height.value
                })
                .onScrollStop({ =>
                    // iOS parity：内容短于视口时，过滚松手后动画弹回顶（rubber-band settle）
                    if (this.contactsBottomFillerH() > 88.5) {
                        this.contactsListScroller.scrollTo(xOffset: 0.0, yOffset: 0.0, animation: true)
                    }
                })
                .backgroundColor(this.presentation.backgroundColor)
                .divider(ListDividerOptions(strokeWidth: 0.5, color: this.presentation.dividerColor, startMargin: 70, endMargin: 0))

                // TC-0174 返修：右侧字母索引条，对位 ContactListNode.swift:1022/1240/1289
                // indexNode（CollectionIndexNode）。门控三条件缺一不可，逐条对位源侧：
                // sortMode==0 ⟺ :1427-1434 case .natural → generateSections=true；
                // searchText 为空 ⟺ 源侧搜索走独立 ContactsSearchContainerNode（不含
                // CollectionIndexNode）；displaySections 非空 ⟺ :2302
                // isUserInteractionEnabled = !indexSections.isEmpty。
                if (this.sortMode == 0 && this.searchText.trim().size == 0 && !this.displaySections.isEmpty()) {
                    AlphabetIndexer(arrayValue: this.indexBarSections(), selected: UInt32(0))
                        .color(0x317AFF)
                        .onSelect({ index: Int64 => this.scrollToIndexSection(index) })
                }
                }
                .width(100.percent)
                .layoutWeight(1)
            }

            // ==================== 人工反馈 #11：选择态底部删除工具条（ContactsController.swift:454-475） ====================
            // 在流内、列表之下；出现条件 selectedPeerIndices.count > 0。留出悬浮 tab bar 的 72vp 避让。
            if (this.isTabHosted && this.selectionMode && !this.selectionSelectedIds.isEmpty()) {
                this.buildSelectionDeleteToolbar()
                Column {}
                    .width(100.percent)
                    .height(72)
                    .backgroundColor(0xF7F7F7)
            }

            // ==================== TC-0178 返修：全屏权限占位覆盖层 ====================
            // 对位 ContactListNode.swift:1987-1990 isEmpty + :2314-2315 覆盖显隐语义。
            // 覆盖在 List 之上（List 在 if/else 分支中已照常渲染，Invite Friends 不受影响），
            // 不带 showContactsPermissionNotice/contactsSyncEnabled：源侧 isEmpty 定义与占位
            // 显隐语义里都没有这两项，不得自行加。
            if (!this.contactsPermGranted && this.contacts.isEmpty() && this.topPeers.isEmpty()) {
                this.buildPermissionPlaceholder()
            }

            if (this.showContactPreview) {
                PeerContextPreview(
                    chatId: this.contextMenuUserId,
                    chatName: this.contextMenuDisplayName,
                    peerType: "user",
                    avatarUrl: this.previewAvatar,
                    subtitle: this.previewSubtitle,
                    sourceY: this.previewSourceY,
                    sourceHeight: this.previewSourceHeight,
                    items: this.contactPreviewItems,
                    onDismiss: { => this.showContactPreview = false },
                    onOpen: { =>
                        this.showContactPreview = false
                        setSelectedChat(this.contextMenuUserId, this.contextMenuDisplayName, "user")
                        routerPush("ChatRoomPage", this.contextMenuDisplayName)
                    }
                )
            }

            // ==================== 长按上下文菜单（ContextMenuView 原子组件） ====================
            if (this.showContextMenu) {
                Column {
                    ContextMenuView(
                        items: this.contactMenuItems,
                        onDismiss: { =>
                            this.showContextMenu = false
                        },
                        // MainTabPage 悬浮 tab bar 避让（diag-suite_contacts_peers-TC-0175.md B1）。
                        bottomInset: 72.0
                    )
                }
                .width(100.percent)
                .height(100.percent)
                .position(x: 0, y: 0)
            }
            
            // ==================== 人工反馈 #11：删除确认动作表（S6） ====================
            if (this.showContactDeleteConfirm) {
                Column {
                    ContextMenuView(
                        items: this.deleteConfirmItems,
                        onDismiss: { =>
                            this.showContactDeleteConfirm = false
                        },
                        bottomInset: 72.0
                    )
                }
                .width(100.percent)
                .height(100.percent)
                .position(x: 0, y: 0)
            }

            // ==================== 排序菜单（CTL-CONTACTS-002：iOS ContextController .reference）====================
            // iOS 参数：圆角30、宽220-240、无遮罩无背景位移、入场 scale0.01→1 spring0.42、出场0.2s、
            // 勾选图标在左（32pt 槽、iconSideInset 20）、项高~44、项按压黑 a0.1 圆角块。
            if (this.showSortSheet) {
                Stack(alignContent: Alignment.TopStart) {
                    // 透明点击捕获层（iOS .reference source 无 dim）
                    Column { }
                        .width(100.percent)
                        .height(100.percent)
                        .onClick({ evt =>
                            this.closeSortMenu()
                        })

                    Column {
                        Row {
                            Row {
                                if (this.sortMode == 1) {
                                    Image(@r(app.media.callui_ic_check))
                                        .width(17)
                                        .height(17)
                                        .fillColor(this.presentation.textColor)
                                }
                            }
                            .width(32)
                            .justifyContent(FlexAlign.Center)
                            .margin(right: 8)
                            Text(trSource("by Last Seen"))
                                .fontSize(17)
                                .fontColor(this.presentation.textColor)
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(44)
                        .padding(left: 12, right: 18)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(if (this.pressedSortItem == 1) { 0x1A000000 } else { Color.Transparent })
                        .borderRadius(14)
                        .onTouch({ evt =>
                            match (evt.eventType) {
                                case TouchType.Down => this.pressedSortItem = 1
                                case _ => this.pressedSortItem = -1
                            }
                        })
                        .onClick({ evt =>
                            this.sortMode = 1
                            setContactsSortByPresence(true)
                            this.applyFilterAndSort()
                            this.closeSortMenu()
                        })

                        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 12)

                        Row {
                            Row {
                                if (this.sortMode == 0) {
                                    Image(@r(app.media.callui_ic_check))
                                        .width(17)
                                        .height(17)
                                        .fillColor(this.presentation.textColor)
                                }
                            }
                            .width(32)
                            .justifyContent(FlexAlign.Center)
                            .margin(right: 8)
                            Text(trSource("by Name"))
                                .fontSize(17)
                                .fontColor(this.presentation.textColor)
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(44)
                        .padding(left: 12, right: 18)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(if (this.pressedSortItem == 0) { 0x1A000000 } else { Color.Transparent })
                        .borderRadius(14)
                        .onTouch({ evt =>
                            match (evt.eventType) {
                                case TouchType.Down => this.pressedSortItem = 0
                                case _ => this.pressedSortItem = -1
                            }
                        })
                        .onClick({ evt =>
                            this.sortMode = 0
                            setContactsSortByPresence(false)
                            this.applyFilterAndSort()
                            this.closeSortMenu()
                        })
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .width(230)
                    .borderRadius(30)
                    .padding(top: 6, bottom: 6)
                    .shadow(radius: 30.0, color: 0x33000000, offsetX: 0.0, offsetY: 8.0)
                    .margin(left: 16, top: 58)
                    .scale(x: this.sortMenuScale, y: this.sortMenuScale, z: Float32(1.0), centerX: 0.percent, centerY: 0.percent)
                    .opacity(this.sortMenuAlpha)
                }
                .width(100.percent)
                .height(100.percent)
                .position(x: 0, y: 0)
            }

            // ==================== New Contact 底部 sheet（CTL-CONTACTS-003 / CTL-SHARED-004）====================
            // iOS: NewContactScreen 以 navigationPresentation=.modal 呈现——底部上滑 sheet、
            // dim 0.25、顶部圆角；表单头 = 左 X 圆 / 居中 "New Contact" / 右灰勾圆。
            if (this.showNewContactSheet) {
                Stack(alignContent: Alignment.TopStart) {
                    // 遮罩（0→0.25 随开合动画）
                    Column { }
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x000000)
                        .opacity(this.sheetDim)
                        .onClick({ evt => this.closeNewContactSheet() })

                    // 面板（上滑进入；margin-top 动画驱动）
                    Column {
                        // 表单头
                        Row {
                            Stack {
                                Text("✕")
                                    .fontSize(15)
                                    .fontColor(0x000000)
                            }
                            .width(44)
                            .height(44)
                            .borderRadius(22)
                            .backgroundColor(0xF0F0F0)
                            .alignContent(Alignment.Center)
                            .onClick({ evt => this.closeNewContactSheet() })

                            Text(trSource("New Contact"))
                                .fontSize(17)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0x000000)
                                .layoutWeight(1)
                                .textAlign(TextAlign.Center)

                            Stack {
                                if (this.ncSaving) {
                                    LoadingProgress().width(18).height(18).color(0x8E8E93)
                                } else {
                                    Image(@r(app.media.callui_ic_check))
                                        .width(16)
                                        .height(16)
                                        .fillColor(if (this.ncFirstName.size > 0 && this.ncPhone.size > 0) { 0x000000 } else { 0xA0A0A5 })
                                }
                            }
                            .width(44)
                            .height(44)
                            .borderRadius(22)
                            .backgroundColor(0xF0F0F0)
                            .alignContent(Alignment.Center)
                            .onClick({ evt => this.saveNewContact() })
                        }
                        .width(100.percent)
                        .height(66)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(0xFFFFFFFF)

                        Divider().color(0xFFE5E5EA).strokeWidth(0.5)

                        // iOS NewContactScreen.swift:
                        // sideInset=16, topInset=24, sectionSpacing=24。空白新建联系人
                        // initialData.peer=nil，avatarInset=0，不显示头像。
                        Column {
                            Column {
                                // Name section: iOS ListSectionComponent 两个等高文本项。
                                Column {
                                    TextInput(text: this.ncFirstName, placeholder: trSource("First Name"))
                                        .fontSize(17)
                                        .height(52)
                                        .backgroundColor(Color.Transparent)
                                        .padding(left: 16, right: 16)
                                        .onChange({ v: String => this.ncFirstName = v })
                                    Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 16, right: 16)
                                    TextInput(text: this.ncLastName, placeholder: trSource("Last Name"))
                                        .fontSize(17)
                                        .height(52)
                                        .backgroundColor(Color.Transparent)
                                        .padding(left: 16, right: 16)
                                        .onChange({ v: String => this.ncLastName = v })
                                }
                                .width(100.percent)
                                .backgroundColor(0xFFFFFFFF)
                                .borderRadius(26)

                                // PhoneInputItem section: country selector + international phone.
                                Column {
                                    Row {
                                        Text(this.ncCountryFlag)
                                            .fontSize(23)
                                            .width(34)
                                        Text(this.ncCountryName)
                                            .fontSize(17)
                                            .fontColor(0xFF000000)
                                            .layoutWeight(1)
                                        Text("›")
                                            .fontSize(24)
                                            .fontColor(0xFFC7C7CC)
                                            .margin(left: 8)
                                    }
                                    .width(100.percent)
                                    .height(52)
                                    .padding(left: 15, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ _ =>
                                        this.ncCountrySearch = ""
                                        this.ncCountryIndices = searchCountries("")
                                        this.showNcCountryPicker = true
                                    })

                                    Divider().color(0xFFE5E5EA).strokeWidth(0.5).margin(left: 16, right: 16)

                                    Row {
                                        TextInput(text: this.ncCountryCode, placeholder: "+")
                                            .fontSize(17)
                                            .fontColor(0xFF000000)
                                            .height(52)
                                            .width(72)
                                            .backgroundColor(Color.Transparent)
                                            .padding(left: 0, right: 4)
                                            .onChange({ v: String => this.updateNcCountryCode(v) })
                                        TextInput(text: this.ncPhone, placeholder: trSource("Phone Number"))
                                            .fontSize(17)
                                            .height(52)
                                            .layoutWeight(1)
                                            .backgroundColor(Color.Transparent)
                                            .padding(left: 0, right: 16)
                                            .onChange({ v: String => this.ncPhone = v })
                                    }
                                    .width(100.percent)
                                    .padding(left: 16)
                                    .alignItems(VerticalAlign.Center)
                                }
                                .width(100.percent)
                                .backgroundColor(0xFFFFFFFF)
                                .borderRadius(26)
                                .margin(top: 24)

                                // Options section.
                                Row {
                                    Text("Sync to Phone")
                                        .fontSize(17)
                                        .fontColor(0xFF000000)
                                        .layoutWeight(1)
                                    Toggle(ToggleType.Switch, isOn: this.ncSyncToPhone)
                                        .selectedColor(0xFF34C759)
                                        .onChange({ value: Bool => this.ncSyncToPhone = value })
                                }
                                .width(100.percent)
                                .height(52)
                                .padding(left: 16, right: 12)
                                .backgroundColor(0xFFFFFFFF)
                                .borderRadius(26)
                                .margin(top: 24)
                                .alignItems(VerticalAlign.Center)

                                // QR section.
                                Row {
                                    Image(@r(app.media.settings_ic_qr))
                                        .width(24)
                                        .height(24)
                                        .fillColor(0xFF007AFF)
                                        .margin(right: 12)
                                    Text(trSource("Add via QR Code"))
                                        .fontSize(17)
                                        .fontColor(0xFF007AFF)
                                        .layoutWeight(1)
                                }
                                .width(100.percent)
                                .height(52)
                                .padding(left: 16, right: 16)
                                .backgroundColor(0xFFFFFFFF)
                                .borderRadius(26)
                                .margin(top: 24)
                                .alignItems(VerticalAlign.Center)
                                .onClick({ _ => routerPush("QrScannerPage", "peer") })

                                if (this.ncError.size > 0) {
                                    Text(this.ncError)
                                        .fontSize(13)
                                        .fontColor(0xFFFF3B30)
                                        .width(100.percent)
                                        .margin(top: 10)
                                        .padding(left: 8, right: 8)
                                }
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 24, bottom: 24)
                        }
                        .width(100.percent)
                        .layoutWeight(1)
                    }
                    .width(100.percent)
                    .height(88.percent)
                    .backgroundColor(0xFFF2F2F7)
                    .borderRadius(30)
                    .alignItems(HorizontalAlign.Start)
                    .margin(top: 100.0 + this.sheetPanelShift)

                    // 国家选择仍在同一个 modal 卡片内切换，避免变成全屏 push。
                    if (this.showNcCountryPicker) {
                        Column {
                            Row {
                                Text("‹")
                                    .fontSize(32)
                                    .fontColor(0xFF007AFF)
                                    .width(38)
                                    .onClick({ _ => this.showNcCountryPicker = false })
                                Text(trSource("Country"))
                                    .fontSize(17)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFF000000)
                                    .layoutWeight(1)
                                    .textAlign(TextAlign.Center)
                                Blank().width(38)
                            }
                            .width(100.percent)
                            .height(52)
                            .padding(left: 12, right: 12)
                            .alignItems(VerticalAlign.Center)

                            TextInput(text: this.ncCountrySearch, placeholder: trSource("Search"))
                                .fontSize(16)
                                .height(38)
                                .width(100.percent)
                                .backgroundColor(0xFFE9E9ED)
                                .borderRadius(10)
                                .padding(left: 12, right: 12)
                                .margin(left: 16, right: 16, bottom: 8)
                                .onChange({ value: String =>
                                    this.ncCountrySearch = value
                                    this.refreshNcCountryPicker()
                                })

                            Divider().color(0xFFE5E5EA).strokeWidth(0.5)

                            Scroll {
                                Column {
                                    ForEach(this.ncCountryIndices, itemGenerator: { index: Int64, _position: Int64 =>
                                        this.buildNcCountryRow(index)
                                        Divider()
                                            .color(0xFFE5E5EA)
                                            .strokeWidth(0.5)
                                            .margin(left: 54)
                                    })
                                }
                                .width(100.percent)
                            }
                            .width(100.percent)
                            .layoutWeight(1)
                            .scrollable(ScrollDirection.Vertical)
                        }
                        .width(100.percent)
                        .height(88.percent)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(30)
                        .margin(top: 100.0 + this.sheetPanelShift)
                    }
                }
                .width(100.percent)
                .height(100.percent)
                .position(x: 0, y: 0)
                .onAppear({ => reportTabModalOverlay(true) })
                .onDisAppear({ => reportTabModalOverlay(false) })
            }

            // ==================== 邀请链接复制提示 ====================
            if (this.showInviteCopied) {
                Column {
                    Text(trSource("Invite link copied to clipboard"))
                        .fontSize(14)
                        .fontColor(0xFFFFFF)
                        .padding(left: 16, right: 16, top: 10, bottom: 10)
                        .backgroundColor(0x99000000)
                        .borderRadius(8)
                }
                .width(100.percent)
                .position(x: 0, y: 0)
                .margin(top: 100)
                .alignItems(HorizontalAlign.Center)
            }

            // ==================== P2-127: 操作反馈 Toast ====================
            if (this.showContextFeedback) {
                Column {
                    Text(this.contextMenuFeedback)
                        .fontSize(14)
                        .fontColor(0xFFFFFF)
                        .padding(left: 16, right: 16, top: 10, bottom: 10)
                        .backgroundColor(0x99000000)
                        .borderRadius(8)
                }
                .width(100.percent)
                .position(x: 0, y: 0)
                .margin(top: 140)
                .alignItems(HorizontalAlign.Center)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}

// ==================== P2-128: 最近 peer 横向条辅助函数 ====================

/**
 * 从显示名提取首字母（1-2 个字符），用于内联头像首字母
 */
func topPeerInitials(displayName: String): String {
    if (displayName.isEmpty()) { return "?" }
    let runes = displayName.toRuneArray()
    if (runes.size == 0) { return "?" }
    let first = runes[0].toString()
    let parts = displayName.split(" ")
    if (parts.size >= 2) {
        let secondRunes = parts[1].toRuneArray()
        if (secondRunes.size > 0) {
            return first + secondRunes[0].toString()
        }
    }
    return first
}

/**
 * 截取 peer 名字的短显示版（最多 8 个字符）
 */
func topPeerShortName(displayName: String): String {
    let runes = displayName.toRuneArray()
    if (runes.size <= 8) { return displayName }
    var result = ""
    var i: Int64 = 0
    while (i < 8) {
        result = result + runes[i].toString()
        i = i + 1
    }
    return result
}

/**
 * 根据 peerId 生成一致的头像背景色（复用项目 7 色板）
 */
func topPeerAvatarColor(peerId: Int64): Int64 {
    let palette: Array<Int64> = [
        0xFFff516a,
        0xFFffa85c,
        0xFF665fff,
        0xFF54cb68,
        0xFF4acccd,
        0xFF2a9ef1,
        0xFFd669ed
    ]
    let absId = if (peerId < 0) { -peerId } else { peerId }
    let idx = absId % 7
    return palette[idx]
}

/**
 * 根据 userId 生成一致的头像颜色（iOS Telegram 风格）
 */
func getAvatarColor(userId: Int64): UInt32 {
    let colors: Array<UInt32> = [
        0xE91E63,  // Pink
        0x9C27B0,  // Purple
        0x3F51B5,  // Indigo
        0x03A9F4,  // Light Blue
        0x009688,  // Teal
        0x4CAF50,  // Green
        0xFF9800,  // Orange
        0xFF5722   // Deep Orange
    ]
    let index = Int64(userId % 8)
    if (index < 0) {
        return colors[Int64(-index)]
    }
    return colors[index]
}

/**
 * 大小写无关的 Unicode 子串搜索
 * 
 * 参考 Telegram-iOS: localizedCaseInsensitiveContains
 * 参考 TelegramHarmony: name.toLowerCase().includes(lowerQuery)
 * 
 * 实现: 基于 Rune (Unicode 码点) 的逐字符比较
 * - ASCII 大小写 (A-Z / a-z) 不敏感
 * - 中文/其他 Unicode 字符精确匹配
 * - 注意: String.size 返回 UTF-8 字节数，不是字符数，
 *   所以必须用 toRuneArray() 做字符级比较
 */
func containsIgnoreCase(text: String, query: String): Bool {
    if (query.isEmpty()) { return true }
    
    // 使用 Rune 数组（Unicode 码点），避免 String.size 字节数与字符数不一致
    let textRunes = text.toRuneArray()
    let queryRunes = query.toRuneArray()
    
    if (queryRunes.size > textRunes.size) { return false }
    if (queryRunes.size == 0) { return true }
    
    var i: Int64 = 0
    while (i <= textRunes.size - queryRunes.size) {
        var matched = true
        var j: Int64 = 0
        while (j < queryRunes.size) {
            let a = Int64(UInt32(textRunes[i + j]))
            let b = Int64(UInt32(queryRunes[j]))
            // ASCII 大小写转换 (A=65..Z=90 → a=97..z=122)
            let aLower = if (a >= 65 && a <= 90) { a + 32 } else { a }
            let bLower = if (b >= 65 && b <= 90) { b + 32 } else { b }
            if (aLower != bLower) {
                matched = false
                break
            }
            j = j + 1
        }
        if (matched) { return true }
        i = i + 1
    }
    return false
}
