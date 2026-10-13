package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.Want
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.{getCallService, isCallsTabShown, setCallsTabShown}
import ohos_app_cangjie_entry.services.{getPendingNotificationClick, clearPendingNotificationClick, setNotificationClickMessageId}
import ohos_app_cangjie_entry.services.{getResolveService, setSelectedChat, setSelectedChatUsername, setSelectedChatDraft, setSelectedChatBotStartPayload}
import ohos_app_cangjie_entry.services.{isConversationVisible, showAlert}
import ohos_app_cangjie_entry.services.{getGlobalAbilityContext, hasPendingExternalContent}
import ohos_app_cangjie_entry.services.fireTabRetap
// TC-0019 返修（diag-suite_session_shell-TC-0019.md 修法方向 FIX-2）：tab 角标取值链依赖。
import ohos_app_cangjie_entry.services.{getPermissionsService, PermissionType}
import ohos_app_cangjie_entry.services.isDeviceContactsSyncEnabled
import ohos_app_cangjie_entry.services.ApplicationSpecificGlobalNotice
import ohos_app_cangjie_entry.services.{getDeviceAccessService, DeviceAccessType, shouldDisplayNotificationsPermissionWarning}
import ohos_app_cangjie_entry.services.{getTelegramCoreAccountManagerService, MultiAccountEntry, getUserPhotoService}
import ohos_app_cangjie_entry.services.{SettingsAddAccountOutcome, startSettingsAddAccountFlow}
import ohos_app_cangjie_entry.services.getCallListSettingsService
import ohos_app_cangjie_entry.services.{getRealContactService, ContactDisplayData}
import ohos_app_cangjie_entry.services.getRealAuthService
import ohos_app_cangjie_entry.core.services.{getTelegramCore_AccountManagerService, addAccountSwitchListenerWithId, removeAccountSwitchListener}
import ohos_app_cangjie_entry.providers.NoticesDataProvider
import ohos_app_cangjie_entry.viewmodels.getChatListVM
import ohos_app_cangjie_entry.services.getChatListProjection
import ohos_app_cangjie_entry.services.triggerHaptic
import ohos_app_cangjie_entry.models.ChatFolder
import std.collection.ArrayList
import ohos_app_cangjie_entry.app.{getDeepLinkRouter, getPendingDeepLink, clearPendingDeepLink}
import ohos_app_cangjie_entry.components.SearchBar
import ohos_app_cangjie_entry.components.OverlayStatusView
import ohos_app_cangjie_entry.components.{getCallV2IconRes, getCallV2BgColor, getAvatarGradTop, getAvatarGradBottom, getAvatarColorIdxByName, getCallerInitial, getIncomingCallTypeText}
import ohos_app_cangjie_entry.components.DialogHost
import ohos_app_cangjie_entry.components.PromptDialog
import ohos_app_cangjie_entry.components.ToastHost
import ohos_app_cangjie_entry.components.GlobalOverlayHost
import ohos_app_cangjie_entry.models.CallSession
import ohos_app_cangjie_entry.models.ChatFolder
import ohos_app_cangjie_entry.core.storage.{initAppTheme, PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.services.getThemesEngineService
import ohos_app_cangjie_entry.services.getLocalizationService
import ohos_app_cangjie_entry.core.storage.initDownloadPolicy
import ohos_app_cangjie_entry.core.storage.{initI18n, PresentationStringsSnapshot, currentPresentationStrings}
import ohos_app_cangjie_entry.core.storage.{initThemeBroadcast}
import ohos_app_cangjie_entry.app.{consumeSwitchingDataTab, getAppState, getSafeAreaBottom, signalAccountSwitched}
import ohos_app_cangjie_entry.utils.safeAnimateTo
import std.time.*
import std.collection.ArrayList
import ohos.business_exception.BusinessException
import ohos.callback_invoke.Callback1Argument

/**
 * TC-0091 返修（diag-suite_settings_root-TC-0091.md 修法 B-1）：屏底带 toolbar 数据模型，
 * 对位源侧 `Display/Source/Toolbar.swift:4-30`
 * （`ToolbarAction{title,isEnabled,color}` / `Toolbar{leftAction,rightAction,middleAction}`）。
 * 被托管页（如 ChatListPage）只发布一个 `TabToolbarModel` 值，不自己画底栏（对位
 * `Display/Source/ViewController.swift:214,693-702 setToolbar(_:transition:)`）。
 * 三个槽位，不多不少。图标由宿主容器（MainTabPage）按槽位位置固定渲染——当前仅
 * ChatListPage 一个发布方，槽位语义固定为 Read/Archive/Delete，故本模型不携带图标资源，
 * 只携带文案/启用态/动作（保持类同源侧 Toolbar 三槽结构，未来若有第二个发布方需要不同
 * 图标，再扩展本模型）。
 */
public class ToolbarActionModel {
    public var title: String = ""
    public var isEnabled: Bool = true
    public var action: () -> Unit = { => }
}

public class TabToolbarModel {
    public var left: Option<ToolbarActionModel> = None
    public var middle: Option<ToolbarActionModel> = None
    public var right: Option<ToolbarActionModel> = None
}

/**
 * Tab 页内模态浮层（底部 sheet / 全屏上下文菜单）与悬浮 tab bar 的层叠通道。
 * iOS 的 sheet / action sheet / context menu 都 present 在 TabBarController 之上的窗口层
 * （ViewController.present → window.present / presentInGlobalOverlay），dim 与面板盖住 tab bar。
 * 这里的 tab bar 是 Tabs 之后的兄弟节点，页内浮层天然画在它下面（Copy/Share、Cancel 被遮）。
 * 被托管页在浮层根节点 onAppear/onDisAppear 上报，宿主据计数把 Tabs 抬到 tab bar 之上；
 * 与 fireCallsNewCallRequest 同款「模块级处理器注册 + 触发」通道。
 */
private var _tabModalOverlayDepth: Int64 = 0
private var _tabModalOverlayHandler: Option<(Bool) -> Unit> = None

public func reportTabModalOverlay(shown: Bool): Unit {
    _tabModalOverlayDepth = if (shown) { _tabModalOverlayDepth + 1 } else if (_tabModalOverlayDepth > 0) {
        _tabModalOverlayDepth - 1
    } else { 0 }
    match (_tabModalOverlayHandler) {
        case Some(handler) => handler(_tabModalOverlayDepth > 0)
        case None => ()
    }
}

private func registerTabModalOverlayHandler(handler: (Bool) -> Unit): Unit {
    _tabModalOverlayHandler = Some(handler)
    handler(_tabModalOverlayDepth > 0)
}

/**
 * 主页 Tab 框架（iOS Telegram 4-Tab 风格）— 混合工程迁移版（TAB HOST）
 * 对应 iOS TelegramRootController + TabBarControllerImpl
 *
 * iOS Tab 顺序:
 * 0: Contacts (联系人)
 * 1: Calls (通话)
 * 2: Chats (聊天) - 默认选中
 * 3: Settings (设置)
 *
 * 混合迁移改动（recipe §12 special tab-host recipe）：
 *  - @Component → @HybridComponentEntry
 *  - 删 @Provide var pageStack: NavPathStack（路由改由 route_map.json + router.*）
 *  - build() 根去掉 Navigation(this.pageStack){...} 包裹，只保留内部 Tabs 作为根组件
 *  - 删 pageMap @Builder 路由表（route_map.json 接管路由）
 *  - pageStack.pushPathByName(name, param) → routerPush(name, param)
 *  - aboutToAppear 有实逻辑 → 挪进 ensureLoaded()（loaded 守卫），根挂 .onAppear
 *  - 同包 pages 子页 import 删除（同包直接可见）
 *
 * iOS 文件参考:
 * - submodules/TelegramUI/Sources/TelegramRootController.swift
 * - submodules/TabBarUI/Sources/TabBarController.swift
 */
@HybridComponentEntry
@Component
public class MainTabPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 当前选中的 Tab 索引
    // P2-003 gap fix: iOS 默认选中 Chats(index 2)，对应 controllers.count-2
    // Tab 顺序: 0=Contacts, 1=Calls, 2=Chats(默认), 3=Settings
    @State var currentIndex: Int32 = 2
    @State var searchOverlayVisible: Bool = false
    // TC-0401 round3/round4 返修（diag-suite_settings_appearance-TC-0401-round3.md F-2 +
    // -round4.md F-C2b）：tab bar 自身此前对呈现快照零订阅，颜色全是模块内字面量，即使快照
    // 已经解算成深色也不换肤。订阅同一份唯一先例写法（pages/AppearanceSettingsPage.cj:44），
    // 供下方 toolbar / floatingTabBar / 四个 tab 构建器取色。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()

    // TC-0019 返修（diag-suite_session_shell-TC-0019.md 修法方向 FIX-2）：tab 角标层
    // ——对位源侧 `TabBarComponent.swift:1296-1330` `ItemComponent.update` 读取
    // `tabBarItem.badgeValue` 画一个 `TextBadgeComponent`。空串 = 不显示。Calls 恒为空
    // （源侧 `CallListController` 从不写 `badgeValue`），不得为它接任何取值。
    @State var badgeContacts: String = ""
    @State var badgeCalls: String = ""
    // iOS CallListSettings.showTab (default on), written by Settings → Recent Calls → Show Calls Tab
    @StorageLink["callListShowTab"] var showCallsTab: Bool = isCallsTabShown()
    @State var badgeChats: String = ""
    @State var badgeSettings: String = ""

    // TC-0511 D/E: tab-host-owned account snapshot. SettingsPage has a separate
    // account list, but the tab item remains mounted while that page is covered by
    // the add-account flow, so it must refresh independently on every root appear.
    @State var settingsAccounts: Array<MultiAccountEntry> = Array<MultiAccountEntry>()
    @State var settingsActiveUserId: Int64 = -1
    @State var settingsAvatarFailed: Bool = false
    @State var settingsAvatarVersion: Int64 = 0
    @State var contactsTabMenuVisible: Bool = false
    @State var callsTabMenuVisible: Bool = false
    @State var chatsTabMenuVisible: Bool = false
    @State var chatTabMenuFolders: ArrayList<ChatFolder> = ArrayList<ChatFolder>()
    @State var settingsAccountMenuVisible: Bool = false
    @State var tabNewCallVisible: Bool = false
    @State var tabNewCallDim: Float64 = 0.0
    @State var tabNewCallShift: Float64 = 2000.0
    @State var tabNewCallContacts: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    @State var settingsSelectedAccountSlot: Int32 = -1
    private var tabPressActive: Bool = false
    private var tabPressIndex: Int32 = -1
    private var tabPressGeneration: Int64 = 0
    private var tabTouchStartX: Float64 = 0.0
    private var tabTouchStartY: Float64 = 0.0
    private var suppressNextTabTap: Int32 = -1
    private var _settingsPhotoCallbackRegistered: Bool = false
    private var _settingsAccountSwitchListenerId: Int64 = -1
    private var pendingSettingsAccountSwitchSlot: Int32 = -1

    // TC-0091 返修（修法 B-1）：屏底带所有权收归容器。toolbarActive=true 时挂载
    // buildBottomToolbar()，false 时挂载常驻 floatingTabBar() —— mount 级互斥（不是
    // .opacity(0)）。对位源侧 `alpha = params.toolbar == nil ? 1.0 : 0.0`
    // （`TabBarContollerNode.swift:290-298`，UIKit hitTest 对 alpha<0.01 直接返回 nil）；
    // 本工程无 hitTestBehavior（D-149），mount 级互斥是唯一能同时做到"不可见 + 不参与命中
    // 测试"的写法（ArkUI `.opacity(0)` 不移除命中测试，照抄会保留 D-145/TC-0091 的 bug）。
    // 回合合流修复:聊天列表进入编辑态时,屏底带让给 ChatListPage 页内自绘的批量操作栏
    // （origin/main 的实现）。三态挂载:toolbarActive 挂我方底栏 / chatsEditing 两者都不挂 /
    // 其余挂常驻 tab bar。仍是 mount 级摘除,不用 opacity(D-149)。
    @State var chatsEditing: Bool = false
    @State var toolbarActive: Bool = false
    @State var toolbarLeftTitle: String = ""
    @State var toolbarLeftEnabled: Bool = false
    @State var toolbarMiddleTitle: String = ""
    @State var toolbarMiddleEnabled: Bool = false
    @State var toolbarRightTitle: String = ""
    @State var toolbarRightEnabled: Bool = false
    // 动作闭包不参与渲染，普通 private var（同 debugTapLast/debugTapCount 的理由）。
    private var toolbarLeftAction: () -> Unit = { => }
    private var toolbarMiddleAction: () -> Unit = { => }
    private var toolbarRightAction: () -> Unit = { => }

    // TC-0018 返修（diag-suite_session_shell-TC-0018.md §A1）：搜索归属状态 —— 对位源侧
    // currentController?.tabBarActivateSearch() 的"当前选中 tab 虚分派"（TabBarController.swift:
    // 255-265）。-1 = 无搜索激活；>=0 = 该 index 对应 tab 的搜索处于激活态。
    // 唯一写入点：activateSearchOnCurrentTab() / deactivateSearchOnCurrentTab()。
    // 边界：currentIndex 在整条搜索路径上不得被写入（对位源侧 selectedIndex 全程不变）。
    @State var searchActiveIndex: Int32 = -1
    // 浮动 tab bar 行的实测宽度（vp），用于把行的响应区收窄到胶囊与搜索钮本身。
    @State var floatingTabBarWidth: Float64 = 0.0

    // TC-0075 返修（diag-suite_settings_root-TC-0075.md 修法 M1b）：tab bar 搜索槽激活态下
    // 胶囊内的输入框文本，对位源侧胶囊内 SearchBarNode 的文本状态（TabBarComponent.swift:
    // 135-172）。裸字段引用，直接传给子组件 @Prop 即可（D-125 合规，不需要镜像字段）。
    // 唯一写入点两处：searchTabBuilder() 激活支的 onChange 回调；
    // deactivateSearchOnCurrentTab() 开头置空（对位源侧退出时销毁 searchBarNode）。
    @State var tabBarSearchQuery: String = ""

    // F1 修法（diag-suite_settings_root-TC-0076.md 修法 M1-a）：软键盘高度（vp），对位源侧
    // `ContainerViewLayout.inputHeight`。由 `ensureLoaded()` 注册的 `KeyboardHeightChange`
    // 回调（`MainTabKeyboardHeightCallback`/`onKeyboardHeightChanged()`）写入，px→vp 换算
    // 经 `getUIContext().px2vp(...)`。两个消费点：本文件 `floatingTabBar()`（tab bar 抬到
    // 键盘之上）与 `SettingsPage` 的 `externalKeyboardInset` @Prop（搜索覆盖层 bottom
    // inset）。键盘收起时回调值为 0，两个消费点均据此自然回落原状。
    @State var keyboardInset: Float64 = 0.0
    // 持有回调对象引用防止被 GC（DeviceProximityBinding.cj `_sensorCallback` 同款范式）。
    private var _keyboardHeightCallback: Option<MainTabKeyboardHeightCallback> = None
    private var _keyboardHeightCallbackActive: Bool = false

    // rework1 修复（D-125 required_fix #1）：ChatListPage/SettingsPage 的
    // `@Prop var externalSearchVisible: Bool` 调用点此前传的是 `this.searchActiveIndex == 2`/
    // `== 3` 比较表达式 —— ArkUI-CJ 宏的 @Prop 依赖追踪只认字面 `this.<field>` 裸引用，比较表达式
    // 不在依赖图内，子组件不会因 searchActiveIndex 变化而重新 build()（D-125 既有范式）。
    // 修法：为每个子组件镜像一份裸 @State 字段，在 build() 内用零高度探针驱动
    // refreshSearchVisibilityMirrors() 每次 build() 时刷新，调用点只传镜像字段本身。
    @State var chatsSearchVisibleMirror: Bool = false
    @State var settingsSearchVisibleMirror: Bool = false

    // D-125 合规：build() 内用一个"返回值被 UI 组件参数消费"的普通函数镜像派生值，
    // 绕开 build()/@Builder 方法体内不能用 let 临时变量的限制（D-116），配合下方零高度探针使用。
    private func refreshSearchVisibilityMirrors(): String {
        this.chatsSearchVisibleMirror = this.searchActiveIndex == 2
        this.settingsSearchVisibleMirror = this.searchActiveIndex == 3
        return ""
    }

    private func actualTabIndex(logicalIndex: Int32): Int32 {
        if (this.showCallsTab) { return logicalIndex }
        if (logicalIndex == 0) { return 0 }
        if (logicalIndex == 2) { return 1 }
        if (logicalIndex == 3) { return 2 }
        return -1
    }

    private func logicalTabIndex(actualIndex: Int32): Int32 {
        if (this.showCallsTab) { return actualIndex }
        if (actualIndex == 0) { return 0 }
        if (actualIndex == 1) { return 2 }
        if (actualIndex == 2) { return 3 }
        return -1
    }

    private func isLogicalTabSelected(logicalIndex: Int32): Bool {
        return this.logicalTabIndex(this.currentIndex) == logicalIndex
    }

    // 搜索态切换统一入口。TC-0075 返修（diag-suite_settings_root-TC-0075.md 修法 M1a）：
    // 不再把整条 tab bar 平移出屏底——源侧无此对应物（源侧从不隐藏 tab bar 进搜索态），
    // 同职责代码是 TabBarComponent.swift:859-864 的槽内形变，见 searchTabBuilder()/
    // floatingTabBar() 的两态实现（修法 M1c/M1d）。
    private func setSearchOverlay(visible: Bool): Unit {
        this.searchOverlayVisible = visible
    }
    // TC-TAB-001: mirrors TabBarNode's selected-icon 1.00 -> 0.87 -> 1.00 bounce.
    @State var tabBounceIndex: Int32 = -1
    @State var tabBounceScale: Float32 = Float32(1.0)

    // P2-005 master-detail 分栏状态
    // 大屏(宽度>=840物理px)显示双栏:左master(tabs)+右detail占位
    @State var isSplitMode: Bool = false

    // 来电状态 — 用于显示/隐藏来电覆盖层
    @State var showIncomingCall: Bool = false
    @State var incomingCallerName: String = ""
    @State var incomingCallerAvatarPath: String = ""
    @State var incomingCallerAvatarFailed: Bool = false
    @State var incomingCallIsVideo: Bool = false

    // 混合迁移：一次性初始化守卫（原 aboutToAppear 实逻辑挪至此）
    @State var loaded: Bool = false
    // 页内模态浮层显示中：Tabs 抬到悬浮 tab bar 之上（见 reportTabModalOverlay）。
    @State var tabModalOverlayActive: Bool = false

    // TC-0077 返修（diag-suite_settings_root-TC-0077.md 修法1）：Debug 隐藏入口 tab bar
    // 10 连点窗口计数器，对位源侧 `TabBarController.swift:131`
    // `private var debugTapCounter: (Double, Int) = (0.0, 0)`（挂在 tab bar 容器上、
    // 四个 tab 共享一份）。必须是普通 `private var`（不是 `@State`）——这两个值不参与
    // 渲染，写它们不应触发 build()（本工程同形先例：AvatarGalleryPage.cj:53-54
    // clickCount/lastClickTime）。时钟用单调时钟 MonoTime（对位 CACurrentMediaTime()，
    // 不受用户改系统时间影响），不得用墙钟 DateTime。
    private var debugTapLast: Option<MonoTime> = None      // 对位 debugTapCounter.0
    private var debugTapCount: Int64 = 0                   // 对位 debugTapCounter.1

    /**
     * 页面初始化 — 注册来电回调 + 启动状态同步
     * 参考 iOS TelegramRootController 的来电检测机制
     * 混合迁移：由根容器 .onAppear 触发，loaded 守卫只跑一次。
     */
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        registerTabModalOverlayHandler({ active: Bool => this.tabModalOverlayActive = active })
        // Restore persisted settings at startup
        initAppTheme()
        // RC-2 (diag-suite_settings_appearance-TC-0401-round3.md F-2): unconditionally
        // construct ThemesEngineService here so its presentation-extras provider registers
        // on the cold-start path that every session goes through, instead of only when a
        // user happens to open Appearance/ChatRoom/EditProfile/etc. Must run after
        // initAppTheme() (which creates the AppStorage["presentation"]/themeVersion keys) so
        // the provider's first recomputePresentation() overwrites the fallback snapshot
        // rather than racing ahead of it. Singleton getter — idempotent, safe if a later
        // screen also calls it.
        let _ = getThemesEngineService()
        initDownloadPolicy()
        initI18n()
        let _ = getLocalizationService().restoreActiveLocalization()
        // P2-009: Initialize theme broadcast mechanism (idempotent)
        initThemeBroadcast()
        this.showCallsTab = getCallListSettingsService().getShowTab()
        getCallListSettingsService().setChangedCallback({ show: Bool =>
            launch {
                let logicalIndex = this.logicalTabIndex(this.currentIndex)
                this.showCallsTab = show
                this.currentIndex = this.actualTabIndex(if (!show && logicalIndex == 1) { 2 } else { logicalIndex })
            }
        })
        this.currentIndex = this.actualTabIndex(2)
        // P2-010: Restore settings tab if an account switch just happened (iOS switchingData behavior)
        let pendingTab = consumeSwitchingDataTab()
        if (pendingTab >= 0) {
            this.currentIndex = this.actualTabIndex(pendingTab)
            Hilog.info(0, "CjTelegram", "[MainTabPage] Restored tab index=${pendingTab} after account switch")
        }
        Hilog.info(0, "CjTelegram", "[MainTabPage] ensureLoaded — initializing CallService")
        // 确保 CallService 尽早初始化，注册 updateCallback
        let callService = getCallService()

        // 注册来电回调（可能从 spawn 线程调用，需 launch 回主线程）
        callService.setIncomingCallCallback({ session: CallSession =>
            Hilog.info(0, "CjTelegram", "[MainTabPage] Incoming call callback! from=${session.peerName} video=${session.isVideo}")
            let name = session.peerName
            let avatarPath = session.peerAvatarPath
            let isVideo = session.isVideo
            launch {
                this.incomingCallerName = name
                this.incomingCallerAvatarPath = avatarPath
                this.incomingCallerAvatarFailed = false
                this.incomingCallIsVideo = isVideo
                this.showIncomingCall = true
            }
        })

        // 启动轮询 — 备用机制，防止回调线程问题
        spawn {
            while (true) {
                sleep(Duration.millisecond * 500)
                if (!getAppState().isInForeground()) { continue }
                let callOpt = getCallService().getCurrentCall()
                launch {
                    match (callOpt) {
                        case Some(c) =>
                            if (c.state == "ringing" && !this.showIncomingCall) {
                                this.incomingCallerName = c.peerName
                                this.incomingCallerAvatarPath = c.peerAvatarPath
                                this.incomingCallerAvatarFailed = false
                                this.incomingCallIsVideo = c.isVideo
                                this.showIncomingCall = true
                            } else if (c.state != "ringing" && this.showIncomingCall) {
                                this.showIncomingCall = false
                            }
                        case None =>
                            if (this.showIncomingCall) {
                                this.showIncomingCall = false
                            }
                    }
                }
            }
        }

        // P2-355: 系统分享接收导航轮询
        // MainAbility.onCreate/onNewWant 解析 SEND_DATA/SEND want → ShareReceiverService 写入 pending；
        // 本轮询每 500ms 检测，发现待处理外部内容则导航到 ShareControllerPage（一次性 guard 防重复 push）。
        spawn {
            var sharePushed = false
            while (true) {
                sleep(Duration.millisecond * 500)
                let hasShare = hasPendingExternalContent()
                if (hasShare && !sharePushed) {
                    sharePushed = true
                    launch {
                        routerPush("ShareControllerPage", "")
                    }
                } else if (!hasShare && sharePushed) {
                    sharePushed = false
                }
            }
        }

        // P2-259: 通知点击导航轮询
        // iOS 对应: AppDelegate.openChatWhenReady — 在认证就绪后打开对应聊天页
        // HarmonyOS: MainAbility.onNewWant / onCreate 解析 Want 参数后写入 pending click，
        // 本轮询线程每 500ms 检测 pending click，发现后在主线程执行导航。
        // 混合迁移：原委托 NotificationClickRouter.navigatePendingClick(pageStack) —— 该服务方法
        // 仍绑定 NavPathStack（不改 services），故此处内联复现其三分支逻辑，peer 聊天跳转改走
        // routerPush，URL 打开走 getGlobalAbilityContext + system Want（与服务 handleUrlNavigation 等价）。
        spawn {
            while (true) {
                sleep(Duration.millisecond * 500)
                match (getPendingNotificationClick()) {
                    case Some(record) =>
                        Hilog.info(0, "CjTelegram", "[MainTabPage] notif click pending detected, scheduling navigation")
                        launch {
                            clearPendingNotificationClick()
                            if (record.url.size > 0 && record.peerId == 0) {
                                // URL 打开分支（等价 NotifClickRouter.handleUrlNavigation）
                                Hilog.info(0, "CjTelegram", "[MainTabPage] notif click: URL open → ${record.url}")
                                match (getGlobalAbilityContext()) {
                                    case Some(ctx) =>
                                        try {
                                            let want = Want(action: "ohos.want.action.viewData", uri: record.url)
                                            ctx.startAbility(want)
                                        } catch (e: Exception) {
                                            Hilog.info(0, "CjTelegram", "[MainTabPage] notif click URL open failed: ${e}")
                                        }
                                    case None =>
                                        Hilog.info(0, "CjTelegram", "[MainTabPage] notif click URL open: no context, skip")
                                }
                            } else if (record.peerId > 0) {
                                let chatName = if (record.peerName.size > 0) { record.peerName } else { record.peerId.toString() }
                                Hilog.info(0, "CjTelegram", "[MainTabPage] notif click: chat → peerId=${record.peerId} chatName=${chatName} msgId=${record.messageId} peerType=${record.peerType}")
                                setSelectedChat(record.peerId, chatName, record.peerType)
                                setSelectedChatDraft("")
                                setSelectedChatUsername("")
                                if (record.messageId > 0) {
                                    setNotificationClickMessageId(record.messageId)
                                }
                                routerPush("ChatRoomPage", chatName)
                            } else {
                                Hilog.info(0, "CjTelegram", "[MainTabPage] notif click: record valid but no action, skip")
                            }
                        }
                    case None => ()
                }
            }
        }

        // P2-004: 深链导航轮询
        // iOS 对应: AppDelegate.openUrlWhenReady / openChatWhenReady(deeplink branch)
        //   application(_:open:options:) → AccountContext.openUrl → openResolved → per-peer 落地
        // HarmonyOS: MainAbility.onCreate / onNewWant 解析 Want.uri 后写入 _pendingDeepLink，
        // 本轮询线程每 500ms 检测 pending deeplink，发现后执行:
        //   1. clearPendingDeepLink (消费)
        //   2. extractUsername 提取目标 peer username
        //   3. spawn {} 中调 ResolveService.resolvePeerByName (MTProto 阻塞操作)
        //   4. launch {} 中执行 ArkUI 导航 (S-001: 状态更新在主线程)
        spawn {
            while (true) {
                sleep(Duration.millisecond * 500)
                match (getPendingDeepLink()) {
                    case Some(link) =>
                        let uri = link.rawUri
                        Hilog.info(0, "CjTelegram", "[MainTabPage] pending deeplink detected: ${uri}")
                        clearPendingDeepLink()
                        let dlRouter = getDeepLinkRouter()
                        let username = dlRouter.extractUsername(uri)
                        let botStartPayload = dlRouter.extractBotStartPayload(uri)
                        if (username.size > 0) {
                            Hilog.info(0, "CjTelegram", "[MainTabPage] deeplink resolving username: ${username}")
                            let resolveService = getResolveService()
                            let capturedUsername = username
                            let capturedBotStartPayload = botStartPayload
                            let peerOpt = resolveService.resolvePeerByName(capturedUsername)
                            launch {
                                match (peerOpt) {
                                    case Some(peer) =>
                                        Hilog.info(0, "CjTelegram", "[MainTabPage] deeplink resolved peerId=${peer.peerId} type=${peer.peerType}")
                                        // 标题用 peer 显示名（与会话列表一致），用户名只作 username 传递
                                        let chatTitle = if (peer.displayName.size > 0) { peer.displayName } else { capturedUsername }
                                        // iOS navigateToChatControllerImpl (useExisting defaults to true,
                                        // NavigateToChatController.swift:146-206): a chat controller for the
                                        // same peer that is already shown is reused, not pushed a second time.
                                        if (capturedBotStartPayload.isEmpty() && isConversationVisible(peer.peerType, peer.peerId)) {
                                            Hilog.info(0, "CjTelegram", "[MainTabPage] deeplink peer ${peer.peerId} already open, reuse")
                                            return
                                        }
                                        setSelectedChat(peer.peerId, chatTitle, peer.peerType)
                                        setSelectedChatDraft("")
                                        setSelectedChatUsername(capturedUsername)
                                        setSelectedChatBotStartPayload(capturedBotStartPayload)
                                        routerPush("ChatRoomPage", chatTitle)
                                    case None =>
                                        // iOS openResolvedUrl `.peer(nil, _)`（OpenResolvedUrl.swift:97-101）：解析不到
                                        // 只弹 Resolve_ErrorNotFound 提示，不导航、不改任何会话状态。此前这里把用户名写进
                                        // 全局 selectedChatUsername 再推 PeerInfoPage，而该页的 peerId/名称取自当前已打开的
                                        // 会话 —— 结果把正在看的频道资料页冒充成目标、链接行显示成 t.me/<该用户名>。
                                        Hilog.info(0, "CjTelegram", "[MainTabPage] deeplink resolve failed username=${capturedUsername}, show not-found alert")
                                        showAlert(
                                            title: "",
                                            message: this.presentationStrings.getOr("Resolve_ErrorNotFound", "Sorry, this user doesn't seem to exist."),
                                            confirmText: this.presentationStrings.getOr("Common_OK", "OK"),
                                            cancelText: ""
                                        )
                                }
                            }
                        } else {
                            Hilog.info(0, "CjTelegram", "[MainTabPage] deeplink: no username extracted from ${uri}")
                        }
                    case None => ()
                }
            }
        }

        // TC-0019 返修（修法 FIX-2·5）：首次加载时算一次四个 tab 角标值。
        this.refreshTabBadges()
        this.refreshSettingsAccountSnapshot()
        this.registerSettingsAccountSwitchListener()

        this.registerKeyboardHeightCallback()
    }

    private func refreshSettingsAccountSnapshot(): Unit {
        let accounts = getTelegramCoreAccountManagerService().getLoggedInAccounts()
        this.settingsAccounts = accounts
        var activeUserId: Int64 = -1
        for (account in accounts) {
            if (account.isActive) {
                activeUserId = account.userId
            }
        }
        if (this.settingsActiveUserId != activeUserId) {
            this.settingsAvatarFailed = false
        }
        this.settingsActiveUserId = activeUserId
        if (!this._settingsPhotoCallbackRegistered) {
            this._settingsPhotoCallbackRegistered = true
            getUserPhotoService().addPhotoReadyCallback({ readyUserId: Int64, _path: String =>
                launch {
                    if (readyUserId == this.settingsActiveUserId) {
                        this.settingsAvatarFailed = false
                        this.settingsAvatarVersion = this.settingsAvatarVersion + 1
                        this.refreshSettingsAccountSnapshot()
                    }
                }
            })
        }
        if (activeUserId > 0) {
            let photoService = getUserPhotoService()
            photoService.requestCurrentUserProfile(activeUserId)
            photoService.requestFullPhotoDownload(activeUserId)
        }
        if (this.settingsAccountMenuVisible && !this.hasSettingsPrimaryAccount()) {
            this.closeSettingsAccountMenu()
        }
    }

    private func hasMultipleSettingsAccounts(): Bool {
        return this.settingsAccounts.size > 1
    }

    private func hasSettingsPrimaryAccount(): Bool {
        if (this.settingsAccounts.size == 0 || this.settingsActiveUserId <= 0) {
            return false
        }
        for (account in this.settingsAccounts) {
            if (account.isActive) {
                return true
            }
        }
        return false
    }

    private func resetTabPress(): Unit {
        this.tabPressActive = false
        this.tabPressIndex = -1
        this.tabPressGeneration = this.tabPressGeneration + 1
    }

    private func settingsAccountRowName(account: MultiAccountEntry): String {
        if (account.lastName.size > 0) {
            return "${account.firstName} ${account.lastName}"
        }
        return account.firstName
    }

    private func settingsActiveAvatarText(): String {
        for (account in this.settingsAccounts) {
            if (account.userId == this.settingsActiveUserId) {
                return account.avatarText
            }
        }
        return "?"
    }

    private func settingsActiveDisplayName(): String {
        for (account in this.settingsAccounts) {
            if (account.userId == this.settingsActiveUserId) {
                if (account.lastName.size > 0) {
                    return "${account.firstName} ${account.lastName}"
                }
                return account.firstName
            }
        }
        return ""
    }

    private func settingsActiveAvatarPath(): String {
        if (this.settingsActiveUserId <= 0) { return "" }
        return getUserPhotoService().getUserPhotoPath(this.settingsActiveUserId)
    }

    private func closeSettingsAccountMenu(): Unit {
        this.settingsAccountMenuVisible = false
        this.settingsSelectedAccountSlot = -1
    }

    private func closeAllTabMenus(): Unit {
        this.contactsTabMenuVisible = false
        this.callsTabMenuVisible = false
        this.chatsTabMenuVisible = false
        this.closeSettingsAccountMenu()
    }

    private func openTabMenu(logicalIndex: Int32): Unit {
        this.closeAllTabMenus()
        if (logicalIndex == 0) {
            this.contactsTabMenuVisible = true
        } else if (logicalIndex == 1) {
            this.callsTabMenuVisible = true
        } else if (logicalIndex == 2) {
            let folders = ArrayList<ChatFolder>()
            match (getChatListVM()) {
                case Some(vm) => for (folder in vm.dialogFilters) { folders.add(folder) }
                case None => ()
            }
            this.chatTabMenuFolders = folders
            this.chatsTabMenuVisible = true
        } else if (logicalIndex == 3) {
            this.settingsSelectedAccountSlot = -1
            this.settingsAccountMenuVisible = true
        }
    }

    private func handleTabTap(logicalIndex: Int32): Unit {
        if (this.suppressNextTabTap == logicalIndex) {
            this.suppressNextTabTap = -1
            return
        }
        this.selectPrimaryTab(logicalIndex)
    }

    private func handleTabTouch(logicalIndex: Int32, evt: TouchEvent): Unit {
        match (evt.eventType) {
            case TouchType.Down =>
                if (logicalIndex == 3 && (!this.hasSettingsPrimaryAccount() || this.pendingSettingsAccountSwitchSlot >= 0)) {
                    this.resetTabPress()
                    return
                }
                if (evt.touches.size > 0) {
                    this.tabTouchStartX = evt.touches[0].x
                    this.tabTouchStartY = evt.touches[0].y
                }
                this.tabPressActive = true
                this.tabPressIndex = logicalIndex
                this.tabPressGeneration = this.tabPressGeneration + 1
                let generation = this.tabPressGeneration
                spawn {
                    sleep(300 * Duration.millisecond)
                    launch {
                        if (this.tabPressActive && this.tabPressIndex == logicalIndex &&
                            this.tabPressGeneration == generation) {
                            this.tabPressActive = false
                            this.tabPressIndex = -1
                            this.suppressNextTabTap = logicalIndex
                            this.openTabMenu(logicalIndex)
                        }
                    }
                }
            case TouchType.Move =>
                if (this.tabPressActive && evt.touches.size > 0) {
                    let dx = evt.touches[0].x - this.tabTouchStartX
                    let dy = evt.touches[0].y - this.tabTouchStartY
                    if (dx * dx + dy * dy > 100.0) {
                        this.resetTabPress()
                    }
                }
            case TouchType.Up =>
                this.resetTabPress()
            case TouchType.Cancel =>
                this.resetTabPress()
            case _ => ()
        }
    }

    private func hideCallsTab(): Unit {
        this.closeAllTabMenus()
        let logicalIndex = this.logicalTabIndex(this.currentIndex)
        let wasCallsSelected = logicalIndex == 1
        this.showCallsTab = false
        getCallListSettingsService().setShowTab(false)
        if (wasCallsSelected) {
            this.currentIndex = this.actualTabIndex(2)
        } else {
            this.currentIndex = this.actualTabIndex(logicalIndex)
        }
    }

    private func openNewCallFromTabMenu(): Unit {
        this.closeAllTabMenus()
        this.tabNewCallDim = 0.0
        this.tabNewCallShift = 2000.0
        this.tabNewCallVisible = true
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 500, curve: Curve.EaseOut), { =>
            this.tabNewCallDim = 0.25
            this.tabNewCallShift = 0.0
        })
        let _ = spawn {
            let contacts = getRealContactService().getContacts()
            let visible = ArrayList<ContactDisplayData>()
            for (contact in contacts) {
                if (!contact.isSelf && !contact.isBot) { visible.add(contact) }
            }
            launch { this.tabNewCallContacts = visible }
        }
    }

    private func closeTabNewCall(): Unit {
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 300, curve: Curve.EaseInOut), { =>
            this.tabNewCallDim = 0.0
            this.tabNewCallShift = 2000.0
        })
        let _ = spawn {
            sleep(Duration.millisecond * 310)
            launch { this.tabNewCallVisible = false }
        }
    }

    private func callFromTabMenu(contact: ContactDisplayData): Unit {
        this.closeTabNewCall()
        let _ = getCallService().requestCall(contact.userId, contact.accessHash, contact.getDisplayName(), false)
        routerPush("CallScreen", "")
    }

    private func startAddAccountFromSettingsTab(): Unit {
        this.closeSettingsAccountMenu()
        let coreSvc = getTelegramCore_AccountManagerService()
        match (startSettingsAddAccountFlow(
            isAddingAccount: { => coreSvc.isAddingAccount() },
            repairDuplicateAuthorizedSlots: { => coreSvc.repairDuplicateAuthorizedSlots() },
            addAccount: { => coreSvc.addAccount() }
        )) {
            case SettingsAddAccountOutcome.Started(newSlot, originalSlot) =>
                Hilog.info(0, "CjTelegram", "[MainTabPage] Settings tab add account started newSlot=${newSlot} originalSlot=${originalSlot}")
            case SettingsAddAccountOutcome.AlreadyInProgress =>
                Hilog.info(0, "CjTelegram", "[MainTabPage] Settings tab add account already in progress")
            case SettingsAddAccountOutcome.LimitPresented => ()
        }
    }

    private func switchAccountFromSettingsTab(account: MultiAccountEntry): Unit {
        if (account.isActive) {
            this.closeSettingsAccountMenu()
            return
        }
        if (this.pendingSettingsAccountSwitchSlot >= 0) {
            this.closeSettingsAccountMenu()
            Hilog.info(0, "CjTelegram", "[MainTabPage] Settings tab account switch ignored while slot=${this.pendingSettingsAccountSwitchSlot} is pending")
            return
        }
        let targetUserId = account.userId
        let targetSlot = getTelegramCore_AccountManagerService().findAuthorizedSlotForUser(targetUserId)
        if (targetSlot < 0) {
            this.closeSettingsAccountMenu()
            Hilog.info(0, "CjTelegram", "[MainTabPage] Settings tab account identity missing userId=${targetUserId}")
            return
        }
        this.settingsSelectedAccountSlot = targetSlot
        this.closeSettingsAccountMenu()
        this.pendingSettingsAccountSwitchSlot = targetSlot
        let _ = spawn {
            let switched = getTelegramCore_AccountManagerService().switchAccount(targetSlot)
            if (!switched) {
                launch {
                    if (this.pendingSettingsAccountSwitchSlot == targetSlot) {
                        this.pendingSettingsAccountSwitchSlot = -1
                    }
                    this.closeSettingsAccountMenu()
                    Hilog.info(0, "CjTelegram", "[MainTabPage] Settings tab account switch rejected slot=${targetSlot}")
                }
            }
        }
    }

    private func registerSettingsAccountSwitchListener(): Unit {
        if (this._settingsAccountSwitchListenerId >= 0) { return }
        this._settingsAccountSwitchListenerId = addAccountSwitchListenerWithId({ switchedSlot: Int32 =>
            launch {
                if (this.pendingSettingsAccountSwitchSlot == switchedSlot) {
                    this.pendingSettingsAccountSwitchSlot = -1
                    let _ = getRealAuthService().tryRestoreLogin()
                    signalAccountSwitched(false)
                    routerReplace("MainTabPage", "{}")
                }
            }
        })
        Hilog.info(0, "CjTelegram", "[MainTabPage] Settings tab account switch listener registered id=${this._settingsAccountSwitchListenerId}")
    }

    private func cleanupSettingsAccountSwitchListener(): Unit {
        if (this._settingsAccountSwitchListenerId >= 0) {
            removeAccountSwitchListener(this._settingsAccountSwitchListenerId)
            this._settingsAccountSwitchListenerId = -1
        }
    }

    private func cleanupMainTabBindings(): Unit {
        this.cleanupSettingsAccountSwitchListener()
        this.unregisterKeyboardHeightCallback()
    }

    private func registerKeyboardHeightCallback(): Unit {
        if (this._keyboardHeightCallbackActive) { return }
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let win = getLastWindow(ctx)
                    let cb = MainTabKeyboardHeightCallback(this)
                    this._keyboardHeightCallback = Some(cb)
                    win.on(WindowCallbackType.KeyboardHeightChange, cb)
                    this._keyboardHeightCallbackActive = true
                    Hilog.info(0, "CjTelegram", "[MainTabPage] KeyboardHeightChange listener registered")
                } catch (e: Exception) {
                    this._keyboardHeightCallback = None
                    this._keyboardHeightCallbackActive = false
                    Hilog.info(0, "CjTelegram", "[MainTabPage] KeyboardHeightChange registration failed (non-fatal): ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[MainTabPage] no context for KeyboardHeightChange registration")
        }
    }

    private func unregisterKeyboardHeightCallback(): Unit {
        if (!this._keyboardHeightCallbackActive) { return }
        this._keyboardHeightCallbackActive = false
        match ((getGlobalAbilityContext(), this._keyboardHeightCallback)) {
            case (Some(ctx), Some(cb)) =>
                try {
                    getLastWindow(ctx).off(WindowCallbackType.KeyboardHeightChange, cb)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[MainTabPage] KeyboardHeightChange removal failed (non-fatal): ${e}")
                }
            case _ => ()
        }
        this._keyboardHeightCallback = None
        this.keyboardInset = 0.0
        Hilog.info(0, "CjTelegram", "[MainTabPage] KeyboardHeightChange listener removed")
    }

    /**
     * F1 修法（diag-suite_settings_root-TC-0076.md 修法 M1-a）：KeyboardHeightChange 回调
     * 落地——参数是 px（UInt32），经 getUIContext().px2vp(...) 换算为 vp 再写 @State。回调
     * 线程不保证是 UI 线程，写状态经 launch{}（本仓既有范式，VideoPlayer.cj:onSaveDialogResult()）。
     */
    public func onKeyboardHeightChanged(pxHeight: UInt32): Unit {
        if (!this._keyboardHeightCallbackActive) { return }
        launch {
            if (!this._keyboardHeightCallbackActive) { return }
            let px: Float64 = Float64(pxHeight)
            match (this.getUIContext().px2vp(px.px)) {
                case Some(vpLength) =>
                    this.keyboardInset = vpLength.value
                case None =>
                    Hilog.info(0, "CjTelegram", "[MainTabPage] px2vp returned None for KeyboardHeightChange")
            }
        }
    }

    /**
     * 接听来电
     */
    private func handleAcceptCall(): Unit {
        Hilog.info(0, "CjTelegram", "[MainTabPage] User accepted incoming call (video=${this.incomingCallIsVideo})")
        this.showIncomingCall = false
        let isVid = this.incomingCallIsVideo
        getCallService().acceptCall()
        // 跳转到通话界面——视频来电必须进 VideoCallScreen。
        // 此前写死 CallScreen：视频帧回调无人注册，整通 559 帧全被丢弃、
        // 用户在语音界面接视频电话（16:40 真机日志实锤）。
        if (isVid) {
            routerPush("VideoCallScreen", "incoming")
        } else {
            routerPush("CallScreen", "incoming")
        }
    }

    /**
     * 拒绝来电
     */
    private func handleDeclineCall(): Unit {
        Hilog.info(0, "CjTelegram", "[MainTabPage] User declined incoming call")
        this.showIncomingCall = false
        getCallService().rejectCall()
        // 延迟清理
        spawn {
            sleep(Duration.second * 1)
            getCallService().clearCurrentCall()
        }
    }

    /**
     * TC-0018 返修（§A2）：搜索圆钮按当前选中 tab 分派，对位
     * `TabBarController.swift:255-259` `activateSearch: { self.currentController?.tabBarActivateSearch() }`。
     * 不修改 currentIndex —— 源侧 activate/deactivate 全程不写 selectedIndex。
     */
    private func activateSearchOnCurrentTab(): Unit {
        // 幂等边界：已激活则不重复 activate（对位源侧 isActive 已为 true 时按钮呈关闭态）
        if (this.searchActiveIndex >= 0) { return }
        let logicalIndex = this.logicalTabIndex(this.currentIndex)
        if (logicalIndex == 0) {
            // ContactsController.tabBarActivateSearch()。ContactListPage 是独立可路由的
            // @HybridComponentEntry 页面，externalSearchVisible 走模块级处理器通道
            // （ContactListPage.cj: fireContactsSearchActivate），非 @Prop。
            this.searchActiveIndex = 0
            this.setSearchOverlay(true)
            fireContactsSearchActivate()
        } else if (logicalIndex == 1) {
            // CallListController.tabBarActivateSearch() -> beginCallImpl()：一次性命令，
            // 不进入搜索形变态（源侧 Calls 无 tabBarDeactivateSearch 覆写）。CallHistoryPage
            // 同样是独立可路由页面，走模块级处理器通道（CallHistoryPage.cj: fireCallsNewCallRequest）。
            fireCallsNewCallRequest()
        } else if (logicalIndex == 2) {
            // ChatListController.tabBarActivateSearch()
            this.searchActiveIndex = 2
            this.setSearchOverlay(true)
        } else if (logicalIndex == 3) {
            // PeerInfoScreen.tabBarActivateSearch() -> controllerNode.activateSearch()
            this.searchActiveIndex = 3
            this.setSearchOverlay(true)
        }
    }

    /**
     * TC-0018 返修（§A4）：退出搜索只关搜索、不动 tab，对位 `TabBarComponent.swift:917-922`
     * （X 关闭）与 `:552-554`（搜索态下手势结束于 tab 区）—— 两条路径都只调
     * `component.search?.deactivate()`，不触碰选中项。
     */
    private func deactivateSearchOnCurrentTab(): Unit {
        // TC-0075 返修（修法 M1b）：退出搜索先清空胶囊文本，对位源侧退出时销毁 searchBarNode。
        this.tabBarSearchQuery = ""
        // Contacts（index 0）走模块级处理器通道，需显式通知子组件复位自身搜索态
        // （对位 ContactsController.tabBarDeactivateSearch()）；Chats/Settings 走 @Prop，
        // 会随 searchActiveIndex 变化自动重新渲染，无需额外通知。
        if (this.searchActiveIndex == 0) {
            fireContactsSearchDeactivate()
        }
        this.searchActiveIndex = -1
        this.setSearchOverlay(false)
    }

    /**
     * TC-0077 返修（修法1c）：per-tab debug 钩子分派，对位
     * `Display/Source/ViewController.swift:173` 的泛型可选钩子
     * `tabBarItemDebugTapAction: (() -> Void)?` + 唯一注册点
     * `TelegramRootController.swift:233-238`（只有 Settings controller 注册）。
     * 独立函数而非内联 if：保住"泛型计数器 + per-controller 可选钩子"两层结构，
     * 计数逻辑与"谁响应"解耦。
     */
    private func tabBarItemDebugTapAction(index: Int32): Unit {
        if (index == 3) {
            // 3 = Settings，对位 accountSettingsController 是唯一注册钩子的 controller。
            Hilog.info(0, "CjTelegram", "[MainTabPage] Debug entry triggered (settings tab 10-tap)")
            routerPush("DebugSettingsPage", "")
        }
        // index 0/1/2 未注册钩子 = no-op。
        // index 2(Chats) 对位 ChatListController.swift:736-740，源侧被 enableDebugActions
        // 门控，参照构建 is_appstore_build=true 下恒 false ⇒ 目标侧保持不注册（勿实现）。
    }

    private func selectPrimaryTab(logicalIndex: Int32): Unit {
        // TC-0018 返修（§A4）：搜索态下点 tab 区只退出搜索、不切 tab、不触发选中弹跳
        // （对位源侧退出路径全程不碰选中项）。放在既有 retap 判断之前。
        if (this.searchActiveIndex >= 0) {
            this.deactivateSearchOnCurrentTab()
            return
        }
        // TC-0077 返修（修法1b）：源侧 debug 计数器跑在 itemSelected 闭包最前面（仅次于
        // 上面的搜索早退），早于"重按当前 tab → scrollToTop"的分派——必须放在这里，放到
        // retap 早退之后连点将永远数不到 2。逐句对位 TabBarController.swift:163-179。
        let nowMono = MonoTime.now()
        // 相邻间隔 > 0.4s ⇒ 断链，连击串从头起算（对位 if debugTapCounter.0 < timestamp - 0.4）
        match (this.debugTapLast) {
            case Some(prev) => if ((nowMono - prev).toMilliseconds() > 400) {
                this.debugTapCount = 0
            }
            case None => this.debugTapCount = 0
        }
        this.debugTapLast = Some(nowMono)
        this.debugTapCount = this.debugTapCount + 1
        if (this.debugTapCount >= 10) {
            this.debugTapCount = 0                 // 只清计数，debugTapLast 保留（对位源侧只清 .1）
            this.tabBarItemDebugTapAction(logicalIndex)
        }
        let index = this.actualTabIndex(logicalIndex)
        if (index < 0) { return }
        // iOS parity（TC-TAB-002/TC-SETTINGS-005）：重按当前 tab → 该页滚动回顶，不重播选中动画
        if (this.currentIndex == index && !this.searchOverlayVisible) {
            fireTabRetap(logicalIndex)
            return
        }
        this.setSearchOverlay(false)
        this.currentIndex = index
        this.tabBounceIndex = logicalIndex
        this.tabBounceScale = Float32(1.0)
        let uiCtx = this.getUIContext()
        safeAnimateTo({ => uiCtx }, AnimateParam(duration: 100, curve: Curve.EaseInOut), { =>
            this.tabBounceScale = Float32(0.87)
        })
        let _ = spawn {
            sleep(Duration.millisecond * 100)
            launch {
                safeAnimateTo({ => uiCtx }, AnimateParam(duration: 140, curve: Curve.EaseInOut), { =>
                    this.tabBounceScale = Float32(1.0)
                })
            }
        }
    }

    private func scaleForTab(index: Int32): Float32 {
        if (this.tabBounceIndex == index) { return this.tabBounceScale }
        return Float32(1.0)
    }

    /**
     * TC-0019 返修（修法 FIX-2）：紧凑数字格式化，逐行复刻
     * `submodules/TelegramPresentationData/Sources/NumericFormat.swift:5-23`
     * （`compactNumericCountString`）。不得复用 `WidgetItemsComponent.cj:77` /
     * `WidgetChatListComponent.cj:128` 的 `99+` 规则——那是 widget 行内角标的规则，
     * 与 tab 角标不是同一个函数。小数点分隔符固定用 "."（源默认参数值）。
     */
    private func compactCountString(n: Int64): String {
        if (n >= 1000000) {
            let whole = n / 1000000
            let r = (n % 1000000) / 100000
            if (r != 0) {
                return "${whole}.${r}M"
            }
            return "${whole}M"
        } else if (n >= 1000) {
            let whole = n / 1000
            let r = (n % 1000) / 100
            if (r != 0) {
                return "${whole}.${r}K"
            }
            return "${whole}K"
        }
        return "${n}"
    }

    /**
     * TC-0019 返修 round2（修法 FIX-A3）：同步的本地部分（Chats/Contacts/Calls）。
     * 对位源侧 `UITabBarItem_addSetBadgeListener` 的"值变即刷"语义——不再只在
     * ensureLoaded()/onAppear 两次拉取，改用下方 D-125 零高度探针在**每次 build()** 都跑一次，
     * 把推模型近似为"任一重绘即最新"。每处赋值前加变更守卫（新值 != 当前字段值才写），
     * 避免 build() 内写状态导致无谓重绘。
     */
    private func refreshLocalTabBadges(): Unit {
        // Chats（对位 ChatListController.swift:439-447 badgeDisposable）：
        // 非静音未读消息总和，`n == 0 ⇒ ""`；否则紧凑格式化。ChatListPage 是纯 tab-hosted
        // 页面（全仓无 routerPush("ChatListPage",...)），getChatListVM() 单例安全（无 D-142 多实例风险）。
        let newBadgeChats: String = match (getChatListVM()) {
            case Some(vm) =>
                let n = vm.getUnreadCountForFilter(-1)
                if (n == 0) {
                    ""
                } else {
                    this.compactCountString(n)
                }
            case None => ""
        }
        if (newBadgeChats != this.badgeChats) {
            this.badgeChats = newBadgeChats
        }

        // Contacts（对位 ContactsController.swift:195-219）：
        // status != .allowed && !suppressed ? "!" : nil
        let contactsAllowed = getPermissionsService().checkPermission(PermissionType.Contacts)
        let contactsSyncEnabled = isDeviceContactsSyncEnabled()
        let contactsWarnTs = NoticesDataProvider().getPermissionWarningTimestamp(ApplicationSpecificGlobalNotice.contactsPermissionWarning)
        let contactsWarnTsPositive: Bool = match (contactsWarnTs) {
            case Some(t) => t > 0
            case None => false
        }
        let contactsSuppressed = !contactsSyncEnabled || contactsWarnTsPositive
        let newBadgeContacts = if (!contactsAllowed && !contactsSuppressed) { "!" } else { "" }
        if (newBadgeContacts != this.badgeContacts) {
            this.badgeContacts = newBadgeContacts
        }

        // Calls：不取值，恒为空（对位 CallListController 全文无 badgeValue 赋值）。
        if (this.badgeCalls != "") {
            this.badgeCalls = ""
        }
    }

    /**
     * TC-0019 返修 round2（修法 FIX-A3）：异步的 Settings/suggestions 部分，原样保留
     * ——只在 ensureLoaded()/根容器 .onAppear 触发（不得挂进 D-125 零高度探针：内部经
     * `getServerProvidedSuggestions` → `help.getPromoData` RPC，每次 build() 都跑会打一次
     * 无谓 RPC）。对位 PeerInfoScreen.swift:6719-6740 + DeviceAccess.swift:55-62：
     * notificationsWarning || phoneNumberWarning || passwordWarning ? "!" : otherAccountsBadge
     * （else 分支为空串——目标侧单账号，无跨账号未读聚合入口，已知缺口，本次不做）。
     * 按 S-001，getServerProvidedSuggestions 内部同步阻塞 RPC 必须在 spawn{} 内执行，
     * UI 写回经 launch{} 回主线程。
     */
    private func refreshSettingsBadgeAsync(): Unit {
        let notifStatus = getDeviceAccessService().checkAccess(DeviceAccessType.Notifications)
        let notifSuppressedTs = NoticesDataProvider().getPermissionWarningTimestamp(ApplicationSpecificGlobalNotice.notificationsPermissionWarning)
        let notifSuppressed = match (notifSuppressedTs) {
            case Some(t) => t > 0
            case None => false
        }
        // ic_notifications_permission_warning_query required_outcomes[1]：改调共享查询
        // services/DeviceAccessService.cj:shouldDisplayNotificationsPermissionWarning，
        // 去掉本文件此前的内联真值表复刻（deviceaccess 落地的共享函数语义与本处旧内联表
        // 逐条一致：Authorized⇒false / NotDetermined⇒!suppressed / Denied⇒true）。
        let capturedNotifWarning = shouldDisplayNotificationsPermissionWarning(notifStatus, notifSuppressed)
        let _ = spawn {
            let ndp = NoticesDataProvider()
            let sugg = ndp.getServerProvidedSuggestions(false)
            var phoneWarning = false
            var passwordWarning = false
            for (s in sugg) {
                if (s.id == "VALIDATE_PHONE_NUMBER") {
                    phoneWarning = true
                }
                if (s.id == "VALIDATE_PASSWORD") {
                    passwordWarning = true
                }
            }
            let finalWarn = capturedNotifWarning || phoneWarning || passwordWarning
            launch {
                if (finalWarn) {
                    this.badgeSettings = "!"
                } else {
                    this.badgeSettings = ""
                }
            }
        }
    }

    /**
     * TC-0019 返修 round2（修法 FIX-A3）：`refreshTabBadges()` 保留为二者的顺序调用，
     * 逻辑一行不改、只做搬运——`ensureLoaded()`（:360 附近）与根容器 `.onAppear` 的现有
     * 调用点不动。
     */
    private func refreshTabBadges(): Unit {
        this.refreshLocalTabBadges()
        this.refreshSettingsBadgeAsync()
    }

    /**
     * TC-0019 返修 round2（修法 FIX-A3）：D-125 零高度探针——本工程唯一合法的
     * "每次 build() 都跑一次普通函数"写法（受 D-116 约束不能在 build() 里写 let）。
     * 只驱动同步段 refreshLocalTabBadges()；refreshSettingsBadgeAsync()（含 RPC）
     * 绝不能挂进来，仍只在 ensureLoaded()/.onAppear 触发。
     */
    private func refreshLocalBadgeMirrors(): String {
        this.refreshLocalTabBadges()
        return ""
    }

    /**
     * TC-0019 返修 round2（diag-suite_session_shell-TC-0019.md 修法 FIX-A1，根因 A）：
     * 原先的单一 `tabBadge(text: String)` 是**参数化 @Builder**——`@Component` 宏把
     * `@Builder func` 的每个参数包装成 `ObservedProperty<T>`，仅在角标子树首次构造时
     * 以当时的值（`""`）初始化，此后 `badgeXxx` 再变也不会重新绑定（D-115）。同一构建里
     * `this.currentIndex` 驱动的 `fillColor`/`backgroundColor` 确实每帧更新，证明 builder
     * 体本身会被重新执行——断点特指"作为 @Builder 参数传入的值"这一跳，不是普遍的
     * 响应式失效。
     *
     * 修法：拆成四个**无参** @Builder，各自直读裸 `this.badgeXxx` 字段（D-115 官方修复策略：
     * "@Builder 函数不传参数，读 @State 字段"）。四份 builder 体逐字一致（唯一差异是读的
     * 字段名）——单一取值/格式化路径（refreshLocalTabBadges()/refreshSettingsBadgeAsync() +
     * compactCountString()）保持唯一，渲染侧的四份拆分是宏约束下的必要代价。
     *
     * 硬约束（诊断报告明确禁止的替代方案，均会把同一个 bug 引回来）：
     * - 不得改用 @Component + @Prop 传值（D-125 已记录该形态在本工程有独立的依赖追踪坑）。
     * - 不得为了"避免四份重复"把渲染逻辑重新参数化、或再引入任何带参 @Builder。
     * - 角标的存在与否不得依赖 this.currentIndex。
     *
     * 定位（FIX-A2，D4.4 白盒偏差）：源侧 `TabBarComponent.swift:1318-1319` 把角标
     * **右边缘**固定、向左生长（`x = floor(itemW/2)+25.0-badgeW-1.0`），原实现的
     * `Stack(alignContent: TopStart)` + `.offset(x: 46, y: 5)` 锚的是**左边缘、向右生长**，
     * 多字符角标（"99"/"1K"）会溢出 tab item。改为 `Stack(alignContent: TopEnd)` +
     * `.offset(x: -9, y: 5)`：itemW=65（`.width(65)`）⇒ 源公式 x_right = floor(65/2)+24 = 56，
     * 距右边缘 65-56=9 ⇒ `TopEnd` 对齐后角标右边缘贴 Stack 右边缘，`-9` 左移到 56，
     * 宽度增加时向左生长，与源侧一致；y=5 不变。
     */
    @Builder
    func contactsTabBadge() {
        if (!this.badgeContacts.isEmpty()) {
            Text(this.badgeContacts)
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .padding(left: 5, right: 5, top: 0, bottom: 1)
                .backgroundColor(0xFF3B30)
                .borderRadius(8)
                .constraintSize(minWidth: 16)
                .offset(x: -9, y: 5)
        }
    }

    @Builder
    func callsTabBadge() {
        if (!this.badgeCalls.isEmpty()) {
            Text(this.badgeCalls)
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .padding(left: 5, right: 5, top: 0, bottom: 1)
                .backgroundColor(0xFF3B30)
                .borderRadius(8)
                .constraintSize(minWidth: 16)
                .offset(x: -9, y: 5)
        }
    }

    @Builder
    func chatsTabBadge() {
        if (!this.badgeChats.isEmpty()) {
            Text(this.badgeChats)
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .padding(left: 5, right: 5, top: 0, bottom: 1)
                .backgroundColor(0xFF3B30)
                .borderRadius(8)
                .constraintSize(minWidth: 16)
                .offset(x: -9, y: 5)
        }
    }

    @Builder
    func settingsTabBadge() {
        if (!this.badgeSettings.isEmpty()) {
            Text(this.badgeSettings)
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .padding(left: 5, right: 5, top: 0, bottom: 1)
                .backgroundColor(0xFF3B30)
                .borderRadius(8)
                .constraintSize(minWidth: 16)
                .offset(x: -9, y: 5)
        }
    }

    /**
     * TC-0091 返修（修法 B-1）：接收被托管页发布的 toolbar 值（对位
     * `Display/Source/ViewController.swift:214 setToolbar(_:transition:)`），拆成扁平
     * @State 标量字段供 buildBottomToolbar() 渲染（普通 private func 内可以自由用
     * match/let，不受 D-116 @Builder 限制）。传给 ChatListPage 的构造参数
     * `onToolbarChange` 回调体就是 `{ model => this.applyToolbarModel(model) }`。
     */
    private func applyToolbarModel(model: Option<TabToolbarModel>): Unit {
        match (model) {
            case Some(m) =>
                this.toolbarActive = true
                match (m.left) {
                    case Some(a) =>
                        this.toolbarLeftTitle = a.title
                        this.toolbarLeftEnabled = a.isEnabled
                        this.toolbarLeftAction = a.action
                    case None =>
                        this.toolbarLeftTitle = ""
                        this.toolbarLeftEnabled = false
                        this.toolbarLeftAction = { => }
                }
                match (m.middle) {
                    case Some(a) =>
                        this.toolbarMiddleTitle = a.title
                        this.toolbarMiddleEnabled = a.isEnabled
                        this.toolbarMiddleAction = a.action
                    case None =>
                        this.toolbarMiddleTitle = ""
                        this.toolbarMiddleEnabled = false
                        this.toolbarMiddleAction = { => }
                }
                match (m.right) {
                    case Some(a) =>
                        this.toolbarRightTitle = a.title
                        this.toolbarRightEnabled = a.isEnabled
                        this.toolbarRightAction = a.action
                    case None =>
                        this.toolbarRightTitle = ""
                        this.toolbarRightEnabled = false
                        this.toolbarRightAction = { => }
                }
            case None =>
                this.toolbarActive = false
        }
    }

    /**
     * TC-0091 返修（修法 B-1）：底部 toolbar 渲染器，占据与 floatingTabBar() 同一条屏底带
     * （对位源侧 `toolbarFrame`：左右 sideInset、高度 44vp、贴 panelsBottomInset 之上）。
     * 视觉样式沿用原 ChatListPage.buildBatchActionBar() 的图标+文字+启用态配色
     * （0x317AFF 启用 / 0xC7C7CC 禁用，Delete 启用态 0xFF3B30）。本轮不做源侧
     * GlassControlPanelComponent 玻璃面板视觉复刻（已单列，视觉保真项，非本轮范围）。
     */
    @Builder
    func buildBottomToolbar() {
        Column {
            Divider()
                .color(0xE5E5EA)
                .strokeWidth(1)
            Row {
                if (!this.toolbarLeftTitle.isEmpty()) {
                    Column {
                        Image(@r(app.media.clist_ic_read))
                            .width(22)
                            .height(22)
                            .fillColor(if (this.toolbarLeftEnabled) { 0x317AFF } else { 0xC7C7CC })
                        Text(this.toolbarLeftTitle)
                            .fontSize(11)
                            .fontColor(if (this.toolbarLeftEnabled) { 0x317AFF } else { 0xC7C7CC })
                            .margin(top: 2)
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Center)
                    .padding(top: 8, bottom: 8)
                    .onClick({ _ => if (this.toolbarLeftEnabled) { this.toolbarLeftAction() } })
                }

                if (!this.toolbarMiddleTitle.isEmpty()) {
                    Column {
                        Image(@r(app.media.clist_ic_archive))
                            .width(22)
                            .height(22)
                            .fillColor(if (this.toolbarMiddleEnabled) { 0x317AFF } else { 0xC7C7CC })
                        Text(this.toolbarMiddleTitle)
                            .fontSize(11)
                            .fontColor(if (this.toolbarMiddleEnabled) { 0x317AFF } else { 0xC7C7CC })
                            .margin(top: 2)
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Center)
                    .padding(top: 8, bottom: 8)
                    .onClick({ _ => if (this.toolbarMiddleEnabled) { this.toolbarMiddleAction() } })
                }

                if (!this.toolbarRightTitle.isEmpty()) {
                    Column {
                        Image(@r(app.media.clist_ic_delete))
                            .width(22)
                            .height(22)
                            .fillColor(if (this.toolbarRightEnabled) { 0xFF3B30 } else { 0xC7C7CC })
                        Text(this.toolbarRightTitle)
                            .fontSize(11)
                            .fontColor(if (this.toolbarRightEnabled) { 0xFF3B30 } else { 0xC7C7CC })
                            .margin(top: 2)
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Center)
                    .padding(top: 8, bottom: 8)
                    .onClick({ _ => if (this.toolbarRightEnabled) { this.toolbarRightAction() } })
                }
            }
            .width(100.percent)
            // TC-0401 round4 F-C2b: 工具栏底（对位 tabBar.backgroundColor）。
            .backgroundColor(this.presentation.navBarColor)
            .justifyContent(FlexAlign.SpaceAround)
            .alignItems(VerticalAlign.Center)
        }
        .width(100.percent)
        // TC-0401 round4 F-C2b: 工具栏外壳底，同上取值。
        .backgroundColor(this.presentation.navBarColor)
    }

    @Builder
    func contactsTabMenuContent() {
        Column {
            Row {
                Image(@r(app.media.tab_context_add_user))
                    .width(24)
                    .height(24)
                    .fillColor(this.presentation.contextMenuPrimaryColor)
                    .margin(right: 14)
                Text(this.presentationStrings.getOr("Contacts_AddContact", "Add Contact"))
                    .fontSize(17)
                    .fontColor(this.presentation.contextMenuPrimaryColor)
                    .layoutWeight(1)
            }
            .width(240)
            .height(52)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _ =>
                this.closeAllTabMenus()
                routerPush("AddContactPage", "new")
            })
        }
        .backgroundColor(this.presentation.contextMenuBackgroundColor)
        .borderRadius(14)
        .clip(true)
    }

    @Builder
    func callsTabMenuContent() {
        Column {
            Row {
                Image(@r(app.media.tab_context_add_user))
                    .width(24)
                    .height(24)
                    .fillColor(this.presentation.contextMenuPrimaryColor)
                    .margin(right: 14)
                Text(this.presentationStrings.getOr("Calls_StartNewCall", "Start New Call"))
                    .fontSize(17)
                    .fontColor(this.presentation.contextMenuPrimaryColor)
                    .layoutWeight(1)
            }
            .width(240)
            .height(52)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _ =>
                this.openNewCallFromTabMenu()
            })

            Divider()
                .color(this.presentation.contextMenuSeparatorColor)
                .strokeWidth(0.5)
                .margin(left: 54)

            Row {
                Image(@r(app.media.tab_context_hide))
                    .width(24)
                    .height(24)
                    .fillColor(this.presentation.contextMenuPrimaryColor)
                    .margin(right: 14)
                Text(this.presentationStrings.getOr("Calls_HideCallsTab", "Hide Calls Tab"))
                    .fontSize(17)
                    .fontColor(this.presentation.contextMenuPrimaryColor)
                    .layoutWeight(1)
            }
            .width(240)
            .height(52)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _ => this.hideCallsTab() })
        }
        .backgroundColor(this.presentation.contextMenuBackgroundColor)
        .borderRadius(14)
        .clip(true)
    }

    private func selectChatFolderFromTabMenu(folder: ChatFolder): Unit {
        this.closeAllTabMenus()
        match (getChatListVM()) {
            case Some(vm) => vm.setActiveFilter(folder.id)
            case None => ()
        }
        this.currentIndex = this.actualTabIndex(2)
    }

    @Builder
    func chatsTabMenuContent() {
        Column {
            Row {
                Image(@r(app.media.tab_context_item_list))
                    .width(24)
                    .height(24)
                    .fillColor(this.presentation.contextMenuPrimaryColor)
                    .margin(right: 14)
                Text(if (this.chatTabMenuFolders.isEmpty()) { trSource("Add Folder") } else { trSource("Edit Folders") })
                    .fontSize(17)
                    .fontColor(this.presentation.contextMenuPrimaryColor)
                    .layoutWeight(1)
            }
            .width(240)
            .height(52)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _ =>
                this.closeAllTabMenus()
                routerPush("ChatFoldersPage", "")
            })

            if (!this.chatTabMenuFolders.isEmpty()) {
                Divider()
                    .color(this.presentation.contextMenuSeparatorColor)
                    .strokeWidth(0.5)
                    .margin(left: 54)
                ForEach(this.chatTabMenuFolders, itemGeneratorFunc: { folder: ChatFolder, _idx: Int64 =>
                    Row {
                        Image(@r(app.media.tab_context_item_list))
                            .width(24)
                            .height(24)
                            .fillColor(this.presentation.contextMenuPrimaryColor)
                            .margin(right: 14)
                        Text(folder.name)
                            .fontSize(17)
                            .fontColor(this.presentation.contextMenuPrimaryColor)
                            .layoutWeight(1)
                    }
                    .width(240)
                    .height(52)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ => this.selectChatFolderFromTabMenu(folder) })
                }, keyGeneratorFunc: { folder: ChatFolder, _idx: Int64 => "tab_folder_${folder.id}" })
            }
        }
        .backgroundColor(this.presentation.contextMenuBackgroundColor)
        .borderRadius(14)
        .clip(true)
    }

    /**
     * Contacts Tab 栏构建器
     * 资源保真修复：真实矢量图标（IconContacts.imageset/ic_tb_contacts.pdf 转 SVG）替代 emoji 字形，
     * Image(...).fillColor(...) 做选中态 tinting（蓝）/未选中态 tinting（灰）。
     */
    @Builder
    func contactsTabChrome() {
        // TC-0019 返修：外层包一层 Stack 承载角标叠加图元，Column 本体原样保留不动。
        // round2 FIX-A2：TopEnd（右边缘固定、向左生长，对位源侧 badgeFrame 公式）。
        Stack(alignContent: Alignment.TopEnd) {
            Column {
                Image(@r(app.media.tab_ic_contacts))
                    .width(24)
                    .height(24)
                    .fillColor(if (this.isLogicalTabSelected(0)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                    .margin(bottom: 2)
                Text(this.presentationStrings.getOr("Contacts_TabTitle", "Contacts"))
                    .fontSize(10)
                    .fontColor(if (this.isLogicalTabSelected(0)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                    .fontWeight(if (this.isLogicalTabSelected(0)) { FontWeight.Medium } else { FontWeight.Regular })
            }
            .width(65)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            // TC-0401 round4 F-C2b: 选中态胶囊底改快照 backgroundColor；未选中态与外壳
            // (floatingTabBar 260x56 pill / toolbar 底) 同取 navBarColor 才能与外壳无缝融合
            // ——否则会出现「暗色主题下深色胶囊浮在白色壳里」的半迁移退化，非本条自行发明。
            .backgroundColor(if (this.isLogicalTabSelected(0)) { this.presentation.backgroundColor } else { this.presentation.navBarColor })
            .borderRadius(28)
            .scale(x: this.scaleForTab(0), y: this.scaleForTab(0), z: Float32(1.0))
            .onTouch({ evt => this.handleTabTouch(0, evt) })
            .onClick({ _ => this.handleTabTap(0) })

            this.contactsTabBadge()
        }
        .clip(false)
    }

    @Builder
    func contactsTabBuilder() {
        Column { this.contactsTabChrome() }
        .bindPopup(
            this.contactsTabMenuVisible,
            CustomPopupOptions(
                builder: bind(this.contactsTabMenuContent, this),
                placement: Placement.Top,
                popupColor: Color.Transparent,
                enableArrow: false,
                autoCancel: true,
                radius: 14.vp,
                onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                    if (!evt.isVisible) {
                        this.contactsTabMenuVisible = false
                        if (this.suppressNextTabTap == 0) { this.suppressNextTabTap = -1 }
                    }
                })
            )
        )
        .clip(false)
    }

    /**
     * Calls Tab 栏构建器
     * 资源保真修复：真实矢量图标（IconCalls.imageset/ic_tb_calls.pdf 转 SVG）替代 emoji 字形。
     */
    @Builder
    func callsTabChrome() {
        // Calls 恒无角标（源侧 CallListController 从不写 badgeValue）——仍统一走 Stack + 角标 builder
        // 结构（此时 this.badgeCalls 恒为空串，callsTabBadge 内部 isEmpty 早退不产出节点），
        // 保持四个 tab 结构一致、不给 Calls 单独特判掉整层。round2 FIX-A2：TopEnd。
        Stack(alignContent: Alignment.TopEnd) {
            Column {
                Image(@r(app.media.tab_ic_calls))
                    .width(24)
                    .height(24)
                    .fillColor(if (this.isLogicalTabSelected(1)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                    .margin(bottom: 2)
                Text(this.presentationStrings.getOr("Calls_TabTitle", "Calls"))
                    .fontSize(10)
                    .fontColor(if (this.isLogicalTabSelected(1)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                    .fontWeight(if (this.isLogicalTabSelected(1)) { FontWeight.Medium } else { FontWeight.Regular })
            }
            .width(65)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            // TC-0401 round4 F-C2b: 同 contactsTabBuilder 的成对迁移理由。
            .backgroundColor(if (this.isLogicalTabSelected(1)) { this.presentation.backgroundColor } else { this.presentation.navBarColor })
            .borderRadius(28)
            .scale(x: this.scaleForTab(1), y: this.scaleForTab(1), z: Float32(1.0))
            .onTouch({ evt => this.handleTabTouch(1, evt) })
            .onClick({ _ => this.handleTabTap(1) })

            this.callsTabBadge()
        }
        .clip(false)
    }

    @Builder
    func callsTabBuilder() {
        Column { this.callsTabChrome() }
        .bindPopup(
            this.callsTabMenuVisible,
            CustomPopupOptions(
                builder: bind(this.callsTabMenuContent, this),
                placement: Placement.Top,
                popupColor: Color.Transparent,
                enableArrow: false,
                autoCancel: true,
                radius: 14.vp,
                onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                    if (!evt.isVisible) {
                        this.callsTabMenuVisible = false
                        if (this.suppressNextTabTap == 1) { this.suppressNextTabTap = -1 }
                    }
                })
            )
        )
        .clip(false)
    }

    /**
     * Chats Tab 栏构建器
     * 资源保真修复：真实矢量图标（IconChats.imageset/ic_tb_chats.pdf 转 SVG）替代 emoji 字形。
     */
    @Builder
    func chatsTabChrome() {
        // round2 FIX-A2：TopEnd（右边缘固定、向左生长）。
        Stack(alignContent: Alignment.TopEnd) {
            Column {
                Image(@r(app.media.tab_ic_chats))
                    .width(24)
                    .height(24)
                    .fillColor(if (this.isLogicalTabSelected(2)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                    .margin(bottom: 2)
                Text(this.presentationStrings.getOr("DialogList_TabTitle", "Chats"))
                    .fontSize(10)
                    .fontColor(if (this.isLogicalTabSelected(2)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                    .fontWeight(if (this.isLogicalTabSelected(2)) { FontWeight.Medium } else { FontWeight.Regular })
            }
            .width(65)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            // TC-0401 round4 F-C2b: 同 contactsTabBuilder 的成对迁移理由。
            .backgroundColor(if (this.isLogicalTabSelected(2)) { this.presentation.backgroundColor } else { this.presentation.navBarColor })
            .borderRadius(28)
            .scale(x: this.scaleForTab(2), y: this.scaleForTab(2), z: Float32(1.0))
            .onTouch({ evt => this.handleTabTouch(2, evt) })
            .onClick({ _ => this.handleTabTap(2) })

            this.chatsTabBadge()
        }
        .clip(false)
    }

    @Builder
    func chatsTabBuilder() {
        Column { this.chatsTabChrome() }
        .bindPopup(
            this.chatsTabMenuVisible,
            CustomPopupOptions(
                builder: bind(this.chatsTabMenuContent, this),
                placement: Placement.Top,
                popupColor: Color.Transparent,
                enableArrow: false,
                autoCancel: true,
                radius: 14.vp,
                onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                    if (!evt.isVisible) {
                        this.chatsTabMenuVisible = false
                        if (this.suppressNextTabTap == 2) { this.suppressNextTabTap = -1 }
                    }
                })
            )
        )
        .clip(false)
    }

    @Builder
    func settingsAccountAvatarBuilder() {
        Stack(alignContent: Alignment.Center) {
            if (this.settingsActiveAvatarPath().size > 0 && !this.settingsAvatarFailed) {
                Image(this.settingsActiveAvatarPath())
                    .id("settings_tab_avatar_${this.settingsActiveUserId}_${this.settingsAvatarVersion}")
                    .width(31)
                    .height(31)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(15.5)
                    .onError({ _ => this.settingsAvatarFailed = true })
            } else {
                Text(this.settingsActiveAvatarText())
                    .fontSize(12)
                    .fontColor(0xFFFFFF)
                    .fontWeight(FontWeight.Medium)
                    .width(31)
                    .height(31)
                    .textAlign(TextAlign.Center)
                    .borderRadius(15.5)
                    .linearGradient(
                        angle: 180.0,
                        colors: [
                            (Color(getAvatarGradTop(getAvatarColorIdxByName(this.settingsActiveDisplayName()))), 0.0),
                            (Color(getAvatarGradBottom(getAvatarColorIdxByName(this.settingsActiveDisplayName()))), 1.0)
                        ]
                    )
            }
        }
        .width(35)
        .height(35)
        .borderRadius(17.5)
        .borderWidth(if (this.isLogicalTabSelected(3)) { 2 } else { 0 })
        .borderColor(this.presentation.accentColor)
        .margin(bottom: 2)
    }

    @Builder
    func settingsAccountMenuPeerAvatar(account: MultiAccountEntry) {
        Stack(alignContent: Alignment.Center) {
            if (account.avatarPath.size > 0) {
                Image(account.avatarPath)
                    .id("settings_account_avatar_${account.slot}_${account.userId}_${this.settingsAvatarVersion}")
                    .width(28)
                    .height(28)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(14)
            } else {
                Text(account.avatarText)
                    .fontSize(12)
                    .fontColor(0xFFFFFF)
                    .fontWeight(FontWeight.Medium)
                    .width(28)
                    .height(28)
                    .textAlign(TextAlign.Center)
                    .borderRadius(14)
                    .linearGradient(
                        angle: 180.0,
                        colors: [
                            (Color(getAvatarGradTop(getAvatarColorIdxByName(this.settingsAccountRowName(account)))), 0.0),
                            (Color(getAvatarGradBottom(getAvatarColorIdxByName(this.settingsAccountRowName(account)))), 1.0)
                        ]
                    )
            }
        }
        .width(28)
        .height(28)
        .margin(right: 12)
    }

    @Builder
    func settingsAccountMenuPeerRow(account: MultiAccountEntry) {
        Row {
            this.settingsAccountMenuPeerAvatar(account)
            Text(this.settingsAccountRowName(account))
                .fontSize(17)
                .fontColor(this.presentation.contextMenuPrimaryColor)
                .layoutWeight(1)
        }
        .width(240)
        .height(48)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ =>
            if (account.isActive) {
                this.closeSettingsAccountMenu()
            } else {
                this.switchAccountFromSettingsTab(account)
            }
        })
    }

    @Builder
    func settingsAccountMenuContent() {
        Column {
            Row {
                Image(@r(app.media.itemlist_ic_plus))
                    .width(22)
                    .height(22)
                    .fillColor(this.presentation.contextMenuPrimaryColor)
                    .margin(right: 12)
                Text(trSource("Add Account"))
                    .fontSize(17)
                    .fontColor(this.presentation.contextMenuPrimaryColor)
            }
            .width(240)
            .height(48)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _ => this.startAddAccountFromSettingsTab() })

            ForEach(this.settingsAccounts, itemGenerator: { account: MultiAccountEntry, _idx: Int64 =>
                if (account.isActive) {
                    this.settingsAccountMenuPeerRow(account)
                }
            }, keyGeneratorFunc: { account: MultiAccountEntry, _idx: Int64 =>
                "current_${account.slot}_${account.userId}"
            })

            if (this.hasMultipleSettingsAccounts()) {
                Divider()
                    .color(this.presentation.contextMenuSeparatorColor)
                    .strokeWidth(8)
                ForEach(this.settingsAccounts, itemGenerator: { account: MultiAccountEntry, _idx: Int64 =>
                    if (!account.isActive) {
                        this.settingsAccountMenuPeerRow(account)
                    }
                }, keyGeneratorFunc: { account: MultiAccountEntry, _idx: Int64 =>
                    "other_${account.slot}_${account.userId}_${account.isActive}"
                })
            }
        }
        .backgroundColor(this.presentation.contextMenuBackgroundColor)
        .borderRadius(14)
        .clip(true)
    }

    /**
     * Settings 槽视觉（齿轮/头像 + 文案 + badge + 1.15 lift）。不含 bindPopup，
     * 供隐藏 Tabs.tabBar 与可见 floating chrome 共用，避免第二张顶栏 Popup。
     */
    @Builder
    func settingsTabChrome() {
        // round2 FIX-A2：TopEnd（右边缘固定、向左生长）。
        Stack(alignContent: Alignment.TopEnd) {
            Column {
                if (this.hasMultipleSettingsAccounts()) {
                    this.settingsAccountAvatarBuilder()
                } else {
                    Image(@r(app.media.tab_ic_settings))
                        .width(24)
                        .height(24)
                        .fillColor(if (this.isLogicalTabSelected(3)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                        .margin(bottom: 2)
                }
                Text(this.presentationStrings.getOr("Settings_Title", "Settings"))
                    .fontSize(10)
                    .fontColor(if (this.isLogicalTabSelected(3)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                    .fontWeight(if (this.isLogicalTabSelected(3)) { FontWeight.Medium } else { FontWeight.Regular })
            }
            .width(65)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            // TC-0401 round4 F-C2b: 同 contactsTabBuilder 的成对迁移理由。
            .backgroundColor(if (this.isLogicalTabSelected(3)) { this.presentation.backgroundColor } else { this.presentation.navBarColor })
            .borderRadius(28)
            .scale(x: this.scaleForTab(3), y: this.scaleForTab(3), z: Float32(1.0))
            .onTouch({ evt => this.handleTabTouch(3, evt) })
            .onClick({ _ => this.handleTabTap(3) })

            this.settingsTabBadge()
        }
        .clip(false)
    }

    /**
     * 可见 floating Settings：chrome + 唯一 bindPopup。只给 floatingTabBar 用。
     */
    @Builder
    func settingsTabBuilder() {
        Column {
            this.settingsTabChrome()
        }
        .bindPopup(
            this.settingsAccountMenuVisible,
            CustomPopupOptions(
                builder: bind(this.settingsAccountMenuContent, this),
                placement: Placement.Top,
                popupColor: Color.Transparent,
                enableArrow: false,
                autoCancel: true,
                radius: 14.vp,
                onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                    if (!evt.isVisible) {
                        this.closeSettingsAccountMenu()
                        if (this.suppressNextTabTap == 3) { this.suppressNextTabTap = -1 }
                    }
                })
            )
        )
        .clip(false)
    }

    private func tabItemsWidth(): Float64 {
        return if (this.showCallsTab) { 260.0 } else { 195.0 }
    }

    @Builder
    func searchTabBuilder() {
        // TC-0075 返修（diag-suite_settings_root-TC-0075.md 修法 M1c）：搜索槽两态形变，
        // 对位 TabBarComponent.swift:101-215（同一 NavigationSearchView 的 isActive 两态，
        // 不是两个控件）。
        if (this.searchActiveIndex == 0) {
            // 人工反馈 #2：Contacts 页自带导航栏内嵌搜索框（ContactListPage.cj SearchBar，
            // 带 Cancel），激活时 tab 栏不再长出第二个胶囊输入框 + ✕（原先两个框同时抢焦点，
            // 且搜索完成后胶囊不会自行收起）。tab 四项仍按搜索态让位，退出由页内 Cancel 走
            // onSearchVisibilityChange(false) → deactivateSearchOnCurrentTab()。
            Row {}
                .width(100.percent)
                .height(56)
        } else if (this.searchActiveIndex >= 0) {
            // 激活支：胶囊（认领自 SearchBar 的 inlineNavigation 形态）+ 右侧 48pt 圆形关闭钮，
            // 对位 :135-172（SearchBarNode fieldStyle .inlineNavigation）与 :179-215（关闭钮）。
            Row {
                Column {
                    SearchBar(
                        loading: false,
                        backArrow: false,
                        text: this.tabBarSearchQuery,
                        hint: trSource("Search"),
                        inlineNavigation: true,
                        inputId: "tabbar_search_input",
                        showCancel: false,
                        onChange: { value: String =>
                            this.tabBarSearchQuery = value
                        }
                    )
                }
                .layoutWeight(1)
                .margin(right: 8)
                // 对位 PeerInfoScreen.swift:5169 searchBarNode.activate()：挂载后聚焦，
                // 沿用本仓已验证的「挂载钩子里 requestFocus」范式（SettingsPage.cj 既有先例）。
                .onAppear({ =>
                    FocusControl.requestFocus("tabbar_search_input")
                })

                Column {
                    // 源侧该 ✕ 是运行时画的两条圆头交叉线（无 asset）；本工程无 Shape/Path/
                    // Canvas 用例，改用同形矢量资源 nav_ic_close 是同类替代，非字形降级
                    // （CountrySelectionPage.cj / TelegramNavBar.cj 已消费同一资源）。
                    Image(@r(app.media.nav_ic_close))
                        .width(28)
                        .height(28)
                        .fillColor(this.presentation.textColor)
                }
                .width(48)
                .height(48)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .borderRadius(24)
                .backgroundColor(this.presentation.navBarColor)
                .onClick({ _ =>
                    this.deactivateSearchOnCurrentTab()
                })
            }
            .width(100.percent)
            .height(56)
        } else {
            // 静息支：保持现状。
            Row {
                Column {
                    Image(@r(app.media.clist_ic_search))
                        .width(27)
                        .height(27)
                        .fillColor(this.presentation.textColor)
                }
                .width(56)
                .height(56)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(this.presentation.navBarColor)
                .borderRadius(28)
            }
            .width(56)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .onClick({ _ =>
                this.activateSearchOnCurrentTab()
            })
        }
    }

    @Builder
    func floatingTabBar() {
        Row {
            // TC-0075 返修（修法 M1d）：搜索激活时四项让位，只渲染占满整行的搜索槽，
            // 对位 TabBarComponent.swift:859-864（tabs 块收缩到屏外，零可见像素、零命中）。
            // 用 if 摘除而非 opacity/visibility/负 margin（D-149：opacity(0) 不摘除命中测试）。
            if (this.searchActiveIndex < 0) {
                Stack(alignContent: Alignment.End) {
                    Row {}
                        .width(this.tabItemsWidth())
                        .height(56)
                        .backgroundColor(this.presentation.navBarColor)
                        .borderRadius(28)
                    Row {
                        this.contactsTabBuilder()
                        if (this.showCallsTab) {
                            this.callsTabBuilder()
                        }
                        this.chatsTabBuilder()
                        this.settingsTabBuilder()
                    }
                    .width(this.tabItemsWidth())
                    .height(56)
                    .clip(false)
                }
                .clip(false)
            }

            this.searchTabBuilder()
        }
        .width(100.percent)
        .height(72)
        .padding(left: 16, right: 16, bottom: 8)
        // F1 修法 round2（diag-suite_settings_root-TC-0076.md 修法 M1-b，round1 被 review 判定
        // 机制大概率无效后重做，D-162）：搜索激活且键盘拉起时，tab bar 自己抬到键盘之上（对位
        // TabBarContollerNode.swift:207-210，仅搜索激活态取 inputHeight + 8.0 分支）。round1 把
        // 键盘位移量塞进这个已 `.height(72)` 定高 Row 的 `.padding(bottom:)`——
        // cj-layout-development-overview.md:37「设置了固定的 width/height 时，组件内容大小 =
        // 固定值 - padding」，padding 只会从 72 定高里往内扣，扣不出键盘那么大的位移，盒子本身
        // 位置不变（组件区域仍是原来 72 高、贴在屏底的那块）。改用 `.margin(bottom:)`：同文档
        // 38 行「组件通过 margin 设置外边距时，组件布局边界 = 组件区域 + margin」——margin 加在
        // 盒子外部、不吃盒子内部尺寸；宿主 `mainNavContent()` 的 `Column { floatingTabBar() }`
        // 无显式 height（随子节点盒 + margin 撑开），其父 `Stack(alignContent: Bottom)` 按这个
        // 撑开后的布局边界贴底对齐，margin 越大整个盒子被推得越高——真正移动的是盒子本身，不是
        // 内容在盒子里的分布。72 定高与 8 基线 padding 原样保留（round1 静息态 review 已通过，
        // 本轮 scope 只换键盘位移量的落点，不引入静息态布局变化）。参照 components/ContextMenu.cj
        // 的 `bottomInset` 用法（该卡片容器不设显式 height，直接吃 `.padding(bottom:)`——同一份
        // 文档同一条规则的另一面：没有固定尺寸时 padding 才会撑大盒子，这里改走 margin 是因为
        // 本盒子必须保留固定 72 高，两者手法不同但依据同一条文档语义）。
        // 底部安全区：本仓是沉浸式窗口（EntryAbility.applyImmersiveWindowLayout() 全局
        // setWindowLayoutFullScreen(true)），窗口内容一直铺到屏幕物理下沿，tab bar 只有 8vp
        // 基线 padding ⇒ 在有底部导航指示条的机型上紧贴屏底、与指示条重叠。位移必须走 margin
        // 而不是 padding：本盒子是 .height(72) 定高，padding 只会从 72 里往内扣、盒子不动
        // （依据同上文这段既有论证）。键盘抬升与安全区是两个独立位移，相加。
        .margin(bottom: getSafeAreaBottom() + (if (this.searchActiveIndex >= 0 && this.keyboardInset > 0.0) { this.keyboardInset } else { 0.0 }))
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Bottom)
        .responseRegion(this.floatingTabBarRegions())
        .onAreaChange({ _: Area, newArea: Area =>
            this.floatingTabBarWidth = newArea.width.value
        })
    }

    /**
     * 浮动 tab bar 的命中区只覆盖可见控件：左侧 tab 胶囊 + 右侧搜索圆钮（搜索激活时为整条
     * 搜索胶囊）。行本身是满宽 72vp 的透明容器，此前整条都吞触摸，贴在 tab bar 上方的会话行
     * （含左滑出的 Mute/Delete/Archive 按钮）点不到。iOS TabBarComponent 只有胶囊/搜索钮
     * 参与命中，其余区域透给下面的列表。
     */
    func floatingTabBarRegions(): Array<Rectangle> {
        let w = this.floatingTabBarWidth
        let top: Float64 = 72.0 - 8.0 - 56.0
        if (w <= 0.0) {
            return [Rectangle(x: 0.0, y: 0.0, width: 100.percent, height: 100.percent)]
        }
        if (this.searchActiveIndex >= 0) {
            return [Rectangle(x: 16.0, y: top, width: w - 32.0, height: 56.0)]
        }
        let pillW: Float64 = if (this.showCallsTab) { 260.0 } else { 195.0 }
        return [
            Rectangle(x: 16.0, y: top, width: pillW, height: 56.0),
            Rectangle(x: w - 16.0 - 56.0, y: top, width: 56.0, height: 56.0)
        ]
    }

    /**
     * 来电覆盖层构建器 — V2 风格（对齐 iOS 官方来电布局）
     *
     * iOS 规格源:
     * - 背景: PrivateCallScreen state0 blue-violet 渐变（等待态）
     * - 头像 136pt 圆 top≈floor(H*0.49)-39-136; 名字 28pt Regular 白 头像底+39;
     *   状态 "Telegram Audio/Video Call" 16pt 白 名字底+4
     * - 底部按钮排: CallControllerButtonsNode incoming 模式 — 72pt 大按钮,
     *   decline 红 0xd92326 / accept 绿 0x74db58, 间距 115, 距底 max(inset+32,46),
     *   label 13pt 白 按钮下+8; 图标 Call/CallDeclineButton + CallAcceptButton 官方 PDF
     * - 上下留白权重 1:1（按 iOS H=777vp 精确解出的比例）
     */
    @Builder
    func incomingCallOverlay() {
        Column {
            Blank()
                .layoutWeight(1)

            // 头像 136 渐变圆 + 首字母
            Stack(alignContent: Alignment.Center) {
                if (this.incomingCallerAvatarPath.size > 0 && !this.incomingCallerAvatarFailed) {
                    Image(this.incomingCallerAvatarPath)
                        .width(136)
                        .height(136)
                        .objectFit(ImageFit.Cover)
                        .borderRadius(68)
                        .onError({ _ => this.incomingCallerAvatarFailed = true })
                } else {
                    Text(getCallerInitial(this.incomingCallerName))
                        .fontSize(48)
                        .fontColor(0xFFFFFF)
                        .fontWeight(FontWeight.Medium)
                }
            }
            .width(136)
            .height(136)
            .borderRadius(68)
            .linearGradient(
                angle: 180.0,
                colors: [
                    (Color(getAvatarGradTop(getAvatarColorIdxByName(this.incomingCallerName))), 0.0),
                    (Color(getAvatarGradBottom(getAvatarColorIdxByName(this.incomingCallerName))), 1.0)
                ]
            )

            // 名字（头像底 +39）
            Text(this.incomingCallerName)
                .fontSize(28)
                .fontWeight(FontWeight.Regular)
                .fontColor(0xFFFFFF)
                .margin(top: 39)

            // 状态（名字底 +4）
            Text(getIncomingCallTypeText(this.incomingCallIsVideo))
                .fontSize(16)
                .fontColor(0xFFFFFF)
                .margin(top: 4)

            Blank()
                .layoutWeight(1)

            // 底部按钮排: decline / accept（72pt, 间距 115）
            Row {
                Column {
                    Stack(alignContent: Alignment.Center) {
                        Image(getCallV2IconRes("decline"))
                            .width(72)
                            .height(72)
                            .fillColor(0xFFFFFF)
                    }
                    .width(72)
                    .height(72)
                    .borderRadius(36)
                    .backgroundColor(0xD92326)
                    .onClick({ _e: ClickEvent =>
                        this.handleDeclineCall()
                    })
                    Text(trSource("Decline"))
                        .fontSize(13)
                        .fontColor(0xFFFFFF)
                        .margin(top: 8)
                }
                .alignItems(HorizontalAlign.Center)

                Blank()
                    .width(115)

                Column {
                    Stack(alignContent: Alignment.Center) {
                        Image(getCallV2IconRes("accept"))
                            .width(72)
                            .height(72)
                            .fillColor(0xFFFFFF)
                    }
                    .width(72)
                    .height(72)
                    .borderRadius(36)
                    .backgroundColor(0x74DB58)
                    .onClick({ _e: ClickEvent =>
                        this.handleAcceptCall()
                    })
                    Text(trSource("Accept"))
                        .fontSize(13)
                        .fontColor(0xFFFFFF)
                        .margin(top: 8)
                }
                .alignItems(HorizontalAlign.Center)
            }
            .justifyContent(FlexAlign.Center)

            Blank()
                .height(36)
        }
        .width(100.percent)
        .height(100.percent)
        .linearGradient(
            angle: 160.0,
            colors: [
                (Color(getCallV2BgColor(0, 0)), 0.0),
                (Color(getCallV2BgColor(0, 1)), 0.35),
                (Color(getCallV2BgColor(0, 2)), 0.70),
                (Color(getCallV2BgColor(0, 3)), 1.0)
            ]
        )
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
    }

    /**
     * P2-005: 主导航内容区 Builder（Tabs）
     * 混合迁移：去掉 Navigation(this.pageStack){...} 包裹，Tabs 直接作为内容根。
     * 复用于单栏和双栏分别的 master 侧或单栏主内容。
     */
    @Builder
    func mainNavContent() {
        Stack(alignContent: Alignment.Bottom) {
        // D-125 零高度探针：每次 build() 时刷新 chatsSearchVisibleMirror /
        // settingsSearchVisibleMirror，必须在下方 Tabs 的 TabContent 读取这两个镜像字段之前
        // 求值（Stack 子节点按源码顺序同步求值）。不可省略——它是唯一能让
        // refreshSearchVisibilityMirrors() 每次 build() 都被调用、且合法出现在 @Builder
        // 方法体内（满足 D-116"只能是 UI 组件表达式"）的写法。
        Text(this.refreshSearchVisibilityMirrors()).height(0).fontSize(0)
        // Tabs 组件 - 底部导航栏（iOS Telegram 4-Tab 布局）
        // P2-003 fix: index:2 = Chats 默认选中（对应 iOS controllers.count-2 = Chats）
        Tabs(barPosition: BarPosition.End, index: this.currentIndex) {
            // Tab 0: Contacts (联系人)
            // TC-0018 返修（§A4）：onSearchVisibilityChange 统一收敛为按 tab index 分派
            // searchActiveIndex / 退出走 deactivateSearchOnCurrentTab（不写 currentIndex）。
            // externalSearchVisible 不经构造参数传入 —— ContactListPage 是独立可路由的
            // @HybridComponentEntry 页面，改走模块级处理器通道（见 activateSearchOnCurrentTab /
            // deactivateSearchOnCurrentTab 内的 fireContactsSearchActivate/Deactivate）。
            TabContent() {
                ContactListPage(
                    onSearchVisibilityChange: { visible: Bool =>
                        if (visible) {
                            this.searchActiveIndex = 0
                            this.setSearchOverlay(true)
                        } else {
                            this.deactivateSearchOnCurrentTab()
                        }
                    },
                    // D-142：显式标记这是容器常驻实例，唯一允许 register 模块级搜索处理器的实例。
                    isTabHosted: true
                )
            }
            .tabBar(bind(this.contactsTabChrome, this))

            // Tab 1: Calls (通话) — Phase K5
            // TC-0018 返修（§B4）：一次性"新建通话"命令不经构造参数传入 —— CallHistoryPage
            // 同样是独立可路由的 @HybridComponentEntry 页面，改走模块级处理器通道
            // （activateSearchOnCurrentTab 内的 fireCallsNewCallRequest）。
            if (this.showCallsTab) {
                TabContent() {
                    // D-142：显式标记这是容器常驻实例，唯一允许 register 模块级"新建通话"处理器的实例。
                    CallHistoryPage(isTabHosted: true)
                }
                .tabBar(bind(this.callsTabChrome, this))
            }

            // Tab 2: Chats (聊天) - 默认选中
            TabContent() {
                ChatListPage(
                    onSearchVisibilityChange: { visible: Bool =>
                        if (visible) {
                            this.searchActiveIndex = 2
                            this.setSearchOverlay(true)
                        } else {
                            this.deactivateSearchOnCurrentTab()
                        }
                    },
                    externalSearchVisible: this.chatsSearchVisibleMirror,
                    // G1/G3/E5：tab 栏搜索胶囊是 Chats 搜索态唯一获焦的输入框，查询文本必须
                    // 下发给 ChatListPage（对位 SettingsPage 的 externalSearchQuery 同一通道）。
                    externalSearchQuery: this.tabBarSearchQuery,
                    externalKeyboardInset: this.keyboardInset,
                    onEditModeChange: { editing: Bool => this.chatsEditing = editing }
                    // 回合合流：批量操作栏的归属是架构级二选一——我方 TC-0091 让
                    // ChatListPage 上报 toolbar 状态、由本容器的 buildBottomToolbar()
                    // 渲染屏底带；origin/main 让 ChatListPage 在页内自绘
                    // buildBatchActionBar()（ChatListPage.cj:1649）。同一屏不可能两者并存，
                    // 按"架构冲突取对方"的裁决保留 main 的页内实现，此处仅撤掉本调用点的
                    // onToolbarChange 实参。applyToolbarModel()/buildBottomToolbar() 保留
                    // 不删——它们是容器侧通用设施，其它 tab 仍可复用。
                )
            }
            .tabBar(bind(this.chatsTabChrome, this))

            // Tab 3: Settings (设置)
            TabContent() {
                SettingsPage(
                    onSearchVisibilityChange: { visible: Bool =>
                        if (visible) {
                            this.searchActiveIndex = 3
                            this.setSearchOverlay(true)
                        } else {
                            this.deactivateSearchOnCurrentTab()
                        }
                    },
                    externalSearchVisible: this.settingsSearchVisibleMirror,
                    externalSearchQuery: this.tabBarSearchQuery,
                    externalKeyboardInset: this.keyboardInset
                )
            }
            .tabBar(bind(this.settingsTabChrome, this))
        }
        .barMode(BarMode.Fixed)
        .barWidth(100.percent)
        .barHeight(0)
        .animationDuration(300.0)
        // TC-0401 round4 F-C2b: Tabs 宿主自身底色，同一份 navBarColor。
        .backgroundColor(this.presentation.navBarColor)
        .onChange({ index: Int32 =>
            this.currentIndex = index
        })
        // 页内模态浮层（sheet / 上下文菜单）显示期间盖住下方悬浮 tab bar（iOS 在 tab bar 之上 present）。
        .zIndex(if (this.tabModalOverlayActive) { Int32(1) } else { Int32(0) })

        // TC-0091 返修（修法 B-1）：屏底带二选一挂载——mount 级互斥，不是 opacity 切换
        // （D-149：本绑定版本无 hitTestBehavior，opacity(0) 不移除命中测试）。有 toolbar
        // 时批量操作栏独占屏底带；否则常驻 tab bar 渲染。TC-0075 返修（修法 M1a）：搜索态
        // 不再整条平移出屏底——两态形变已在 floatingTabBar()/searchTabBuilder() 内完成
        // （修法 M1c/M1d），两条通道仍正交。
        if (this.toolbarActive) {
            this.buildBottomToolbar()
        } else if (!this.chatsEditing) {
            Column {
                this.floatingTabBar()
            }
            .clip(false)
            .responseRegion(this.floatingTabBarRegions())
        }
        }
        .width(100.percent)
        .height(100.percent)
    }

    /**
     * P2-005: 大屏 detail 占位面板 Builder
     * 对应 iOS UISplitViewController 右侧 detail 区域。
     * 小屏时不显示；大屏时显示"选择聊天"占位。
     */
    @Builder
    func detailPlaceholderContent() {
        Column {
            Text("Select a chat to start")
                .fontSize(18)
                .fontColor(0xFF8E8E93)
                .textAlign(TextAlign.Center)
                .margin(top: 48)
        }
        .width(100.percent)
        .height(100.percent)
        // TC-0401 round4 F-C2b: 原字面量 0xFFF2F2F7 是 8 位 ARGB 写法，快照字段
        // presentation.backgroundColor 是裸 6 位 RGB（首字节 0x00）——ResourceColor.alphaAdapt()
        // 对首字节为 0 的字面量强制补 alpha=FF（D-144/D-175 已记录的既有转换惯例），
        // 直接渲染为不透明色，与原 0xFFF2F2F7 等价，不需要也不应手写 alpha 前缀。
        .backgroundColor(this.presentation.backgroundColor)
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    private func tabNewCallOverlay() {
        if (this.tabNewCallVisible) {
            Stack(alignContent: Alignment.TopStart) {
                Column { }
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x000000)
                    .opacity(this.tabNewCallDim)
                    .onClick({ _ => this.closeTabNewCall() })
                Column {
                    Row {
                        Stack {
                            Text("✕").fontSize(15).fontColor(0x000000)
                        }
                        .width(30).height(30).borderRadius(15)
                        .backgroundColor(0xF0F0F0)
                        .alignContent(Alignment.Center)
                        .onClick({ _ => this.closeTabNewCall() })
                        Text(trSource("New Call"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                            .layoutWeight(1)
                            .textAlign(TextAlign.Center)
                        Row {}.width(30).height(30)
                    }
                    .width(100.percent).height(56)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    if (this.tabNewCallContacts.isEmpty()) {
                        Column { LoadingProgress().width(32).height(32) }
                            .width(100.percent)
                            .padding(top: 40)
                            .alignItems(HorizontalAlign.Center)
                    } else {
                        List {
                            ForEach(this.tabNewCallContacts, itemGeneratorFunc: { contact: ContactDisplayData, _idx: Int64 =>
                                ListItem {
                                    Row {
                                        if (getUserPhotoService().getUserPhotoPath(contact.userId).size > 0) {
                                            Image(getUserPhotoService().getUserPhotoPath(contact.userId))
                                                .width(40).height(40).borderRadius(20)
                                                .objectFit(ImageFit.Cover).margin(right: 12)
                                        } else {
                                            Stack {
                                                Text(contact.getAvatarInitials())
                                                    .fontSize(15).fontColor(0xFFFFFF).fontWeight(FontWeight.Medium)
                                            }
                                            .width(40).height(40).borderRadius(20)
                                            .backgroundColor(getAvatarColor(contact.userId))
                                            .alignContent(Alignment.Center).margin(right: 12)
                                        }
                                        Column {
                                            Text(contact.getDisplayName()).fontSize(17).fontColor(0x000000).maxLines(1)
                                            Text(contact.getLastSeenText())
                                                .fontSize(13)
                                                .fontColor(if (contact.isOnline) { 0x317AFF } else { 0x8E8E93 })
                                                .margin(top: 2).maxLines(1)
                                        }
                                        .layoutWeight(1).alignItems(HorizontalAlign.Start)
                                    }
                                    .width(100.percent).height(54)
                                    .padding(left: 16, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ _ => this.callFromTabMenu(contact) })
                                }
                            })
                        }
                        .width(100.percent).layoutWeight(1)
                        .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 68, endMargin: 0))
                        .edgeEffect(EdgeEffect.Spring)
                    }
                }
                .width(100.percent).height(88.percent)
                .backgroundColor(0xFFFFFF).borderRadius(10)
                .alignItems(HorizontalAlign.Start)
                .margin(top: 100.0 + this.tabNewCallShift)
            }
            .width(100.percent).height(100.percent)
        }
    }

    public func build() {
        // 使用 Stack 包裹，来电时可以在最上层覆盖来电界面
        // P2-005: onAreaChange 响应式断点 — 600vp 以上切双栏 SideBarContainer
        Stack {
            // TC-0019 返修 round2（修法 FIX-A3）：D-125 零高度探针，必须是根容器 build() 的
            // 第一个子节点——在下方 mainNavContent()/四个 tabBadge builder 读取 badgeXxx 之前
            // 求值（Stack 子节点按源码顺序同步求值）。不可省略：它是唯一能让
            // refreshLocalTabBadges() 每次 build() 都被调用、且合法出现在 build() 方法体内
            // （满足 D-116"只能是 UI 组件表达式"）的写法。只驱动同步段，Settings 的异步段
            // 不挂在这里（见 refreshSettingsBadgeAsync() 注释）。
            Text(this.refreshLocalBadgeMirrors()).height(0).fontSize(0)
            if (this.isSplitMode) {
                // P2-005 大屏双栏模式：SideBarContainer
                // 左侧 master（主导航 + Tabs）| 右侧 detail（聊天占位）
                // 对应 iOS UISplitViewController master-detail split layout
                SideBarContainer() {
                    this.mainNavContent()
                    this.detailPlaceholderContent()
                }
                .showSideBar(true)
                .sideBarWidth(320)
                .minSideBarWidth(240)
                .maxSideBarWidth(400)
                .autoHide(false)
                .showControlButton(false)
                .sideBarPosition(SideBarPosition.Start)
                .width(100.percent)
                .height(100.percent)
            } else {
                // 单栏模式（手机/小屏）：直接显示主导航
                this.mainNavContent()
            }

            this.tabNewCallOverlay()

            // Message context menus are owned by the active chat page instead
            // of the application root, so no global menu host is mounted here.

            // 统一弹窗框架宿主 — P2-405b
            DialogHost()
            PromptDialog()

            // 统一轻提示宿主 — P2-407
            ToastHost()

            // P2-008: 统一应用级 overlay 宿主 — 通用 alert/tooltip/banner 入栈渲染
            // 对应 iOS 根 UIViewController.present 统一覆盖层机制。
            // 挂在来电覆盖层之下，OverlayStatusView 之下。
            GlobalOverlayHost()

            // P2-057: 常驻通话 banner — 离开通话屏后顶部常驻，点击返回通话
            // 自门控（isActive ← isCallBannerVisible() 轮询），不可见时 build() 渲染空。
            CallActiveBanner()

            // 来电覆盖层 — 仅在收到来电且状态为 ringing 时显示
            if (this.showIncomingCall) {
                incomingCallOverlay()
            }

            // 全屏模态状态遮罩（loading/success/fail）叠加层 — P2-421
            OverlayStatusView()
        }
        // TC-0076 F1 返修（round3-dynamic 实测验证，见
        // diag-suite_settings_root-TC-0076-round3-dynamic.md §6）：ArkUI 页面级 OFFSET
        // 键盘避让只在键盘弹出瞬间按焦点组件原始几何定值一次、此后不重算，app 侧挪动
        // tab bar/胶囊无法归零该位移。搜索激活态是本页唯一自带键盘 inset 通道
        // （floatingTabBar margin + SettingsPage 覆盖层 padding）的状态，因此只在该状态
        // 退出平台避让；其余状态保留平台通道（空数组分支，经 E4 对照验证等价于不抑制）。
        // 必须挂在页面内容根 Stack 上——expandSafeArea 只把被标记子树排除在避让位移外，
        // 不关闭页面级避让本身；挂在 tab bar 宿主 Column 上时症状不变（E2 负实验实测坐实，
        // 见 diag-suite_settings_root-TC-0076-round3-dynamic-E2-negative.diff，do-not-ship）。
        .expandSafeArea(
            types: if (this.searchActiveIndex >= 0) { [SafeAreaType.Keyboard] } else { Array<SafeAreaType>() },
            edges: [SafeAreaEdge.Bottom]
        )
        .onAreaChange({ _: Area, newArea: Area =>
            // P2-005 响应式断点：宽度 > 600vp 触发大屏双栏模式
            let w = newArea.width.value
            if (w > 600.0 && !this.isSplitMode) {
                this.isSplitMode = true
                Hilog.info(0, "CjTelegram", "[MainTabPage] entering split mode w=${w}")
            } else if (w <= 600.0 && this.isSplitMode) {
                this.isSplitMode = false
                Hilog.info(0, "CjTelegram", "[MainTabPage] leaving split mode w=${w}")
            }
        })
        .onAppear({ =>
            this.ensureLoaded()
            this.registerSettingsAccountSwitchListener()
            this.registerKeyboardHeightCallback()
            this.refreshTabBadges()
            this.refreshSettingsAccountSnapshot()
        })
        .onDisAppear({ => this.cleanupMainTabBindings() })
    }
}

/**
 * F1 修法（diag-suite_settings_root-TC-0076.md 修法 M1-a）：KeyboardHeightChange 回调实现。
 * 持有页面引用同 VideoPlayerSaveDialogCallback（components/VideoPlayer.cj）/
 * DeviceProximitySensorCallback（utils/DeviceProximityBinding.cj）既有范式——回调本体只转发
 * 给页面的公开方法，不在这里直接写 @State（invoke 签名不带 UI 生命周期保证）。
 */
// public：MainTabPage 是 @Component，宏为其生成的 public init(...) 会把每个字段（含本类型
// 持有的 _keyboardHeightCallback 引用字段，非仅 @State）包进 Option<ObservedProperty<T>>
// 参数——public API 面不能引用非 public 类型（编译报 "contains 'internal' type"），故本类必须
// public（VideoPlayerSaveDialogCallback 不需要 public 是因为它只是方法内局部变量，从未落成
// @Component 的字段）。
public class MainTabKeyboardHeightCallback <: Callback1Argument<UInt32> {
    private var _page: MainTabPage

    init(page: MainTabPage) {
        this._page = page
    }

    public func invoke(err: ?BusinessException, arg: UInt32): Unit {
        match (err) {
            case Some(e) =>
                Hilog.info(0, "CjTelegram", "[MainTabPage] KeyboardHeightChange callback error: ${e.message}")
            case None =>
                this._page.onKeyboardHeightChanged(arg)
        }
    }
}
