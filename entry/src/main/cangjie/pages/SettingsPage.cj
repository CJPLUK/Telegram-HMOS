package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import std.collection.ArrayList
import std.time.DateTime
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.services.setPendingLanguagePreviewIdentifier
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation, PresentationStringsSnapshot, currentPresentationStrings}
import ohos_app_cangjie_entry.core.services.{getTelegramCore_AccountManagerService, addAccountSwitchListenerWithId, removeAccountSwitchListener, removeAllAccountSwitchListeners}
import ohos_app_cangjie_entry.components.LanguageSuggestionUIComponent
import ohos_app_cangjie_entry.components.{ItemListSeparator, ItemListDisclosureRow, ItemListButtonRow, CustomEmojiImage}
import kit.AbilityKit.Want
import ohos_app_cangjie_entry.app.{signalAccountSwitched, initAccountSwitchBridge, getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.viewmodels.getAuthViewModel
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.{parsePhoneNumber, formatPhoneNumber}
import ohos_app_cangjie_entry.utils.safeAnimateTo
import ohos_app_cangjie_entry.providers.NoticesDataProvider
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.components.SelectedPhoto
import ohos_app_cangjie_entry.interop.*

@Component
class SettingsAccountPlusIcon {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    private let plusContext: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    private func drawPlus(): Unit {
        this.plusContext.clearRect(0.0, 0.0, 32.0, 32.0)
        this.plusContext.strokeStyle = this.presentation.accentColor
        this.plusContext.lineWidth = 2.0
        this.plusContext.beginPath()
        this.plusContext.moveTo(8.0, 16.0)
        this.plusContext.lineTo(24.0, 16.0)
        this.plusContext.moveTo(16.0, 8.0)
        this.plusContext.lineTo(16.0, 24.0)
        this.plusContext.stroke()
    }

    func build() {
        Canvas(this.plusContext)
            .width(32)
            .height(32)
            .onReady({ => this.drawPlus() })
    }
}

/**
 * Settings Page — Telegram iOS Style — 混合工程迁移版（TAB CONTENT）
 *
 * 由 MainTabPage 的 Tabs 直接渲染为 SettingsPage() 子组件（非独立路由页）。
 *
 * Exact replica of Telegram-iOS Settings interface:
 * - Centered profile header (avatar, name, phone)
 * - Set Profile Photo / Set Username CTAs
 * - My Profile section
 * - Saved Messages / Recent Calls / Devices / Chat Folders
 * - Notifications / Privacy / Data / Appearance / Power Saving / Language
 * - Telegram Premium / My Stars / Telegram Business / Send a Gift
 * - Ask a Question / Telegram FAQ / Telegram Features
 *
 * 混合迁移改动（tab-content 处理，非完整 page-shell recipe）：
 *  - 不加 @HybridComponentEntry（由 MainTabPage 承载嵌入）
 *  - 删 @Consume var pageStack（混合嵌入无 @Provide 栈）
 *  - 删 @Consume var isLoggedIn（混合嵌入无 @Provide 祖先）；登出改写 app 级 SSOT
 *    getAuthViewModel().isLoggedIn = false（与 QrLoginPage/AuthViewModel LIVE 模式一致，功能未 stub）
 *  - pageStack.pushPathByName(name, param) → routerPush(name, param)
 *  - aboutToAppear 有实逻辑 → ensureLoaded()（loaded 守卫），根挂 .onAppear
 *  - aboutToDisappear 有实清理 → cleanup()，根挂 .onDisAppear
 *
 * iOS 文件参考:
 * - submodules/TelegramUI/Sources/Settings/SettingsController.swift
 * - submodules/TelegramUI/Sources/PeerInfo/PeerInfoScreen.swift
 */
@Component
public class SettingsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 返修（diag-suite_settings_appearance-TC-0401-round4.md F-3a，diag-...-TC-0400.md
    // 结论第 4 条 set_theme_settings 行）：本屏此前对呈现快照零订阅（0 处 @StorageLink /
    // currentPresentation / themeVersion），整屏颜色写死 0xFFFFFF/0x000000 字面量 ⇒ 拨动
    // Night Mode 后本屏完全不换肤。唯一先例写法见 AppearanceSettingsPage.cj:46。本文件自己
    // 画的颜色/字号（页底/卡底/主文本/次级文本/分隔线/强调色，及 scaledFontSize() 派生的
    // 字号）改吃这个字段；共享 ItemList* 原语（行标题/分隔线/chevron/分节头）画的部分不在
    // 本文件覆盖范围内（那是 uif_itemlist_items 的面，两边都改会产生双重来源）。行图标固定
    // 品牌底色（如头像圆底、搜索图标灰底）、destructive 红、toast/modal 遮罩层保持字面量不变
    // ——它们两侧本就与主题无关。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()

    // TC-0018 返修（§B3）：由 MainTabPage 按 searchActiveIndex == 3 传入 —— tab bar 搜索圆钮
    // 在 Settings tab 上激活时的对位状态，对位 PeerInfoScreen.swift:7260-7266
    // controllerNode.activateSearch()/deactivateSearch()。
    public var onSearchVisibilityChange: (Bool) -> Unit = { _visible => }
    // R-2 返修（diag-fixture-reset-searchbar-focus）：`@Watch` 侦测宿主（MainTabPage）
    // 显式下发的搜索激活态变化，对位 SearchBarNode.swift:1274
    // activate()/deactivate() 语义。
    // TC-0075 返修（diag-suite_settings_root-TC-0075.md 修法 M2a/M2d）：设置页不再自建
    // 输入框——搜索条现在是 tab bar 胶囊（认领自 MainTabPage.searchTabBuilder()），聚焦调用
    // 随之搬到 pages/MainTabPage.cj 胶囊外包 Column 的 `.onAppear`（修法 M1c）。本 `@Watch`
    // 回调只保留退出搜索态时的清理职责（`onExternalSearchVisibleChanged()`）。
    @Prop @Watch[onExternalSearchVisibleChanged] var externalSearchVisible: Bool
    // TC-0075 返修（修法 M2c）：查询文本改由宿主（MainTabPage 的 tab bar 胶囊）下发受控
    // 属性；本组件不再自持搜索文本状态（认领外置输入条语义，对位 SearchDisplayController
    // 的 `searchBarIsExternal: true`）。
    @Prop @Watch[onExternalSearchQueryChanged] var externalSearchQuery: String
    // F1 修法（diag-suite_settings_root-TC-0076.md 修法 M1-c）：宿主（MainTabPage）下发的
    // 软键盘高度（vp），对位 SettingsSearchItem.swift:551-563 `layout.insets(options: [.input])`
    // 的接收端——搜索覆盖层据此吃底部 inset，不再随整页平移被顶出屏幕。0 时行为与现状
    // 逐像素一致。
    @Prop var externalKeyboardInset: Float64
    @State var userName: String = "User"
    @State var addressName: String = ""
    @State var userPhone: String = ""
    @State var userId: Int64 = 0
    @State var avatarAccessHash: Int64 = 0
    @State var avatarText: String = "U"
    @State var avatarLocalPath: String = ""
    @State var avatarEmojiDocumentId: Int64 = 0
    @State var avatarEmojiBackgroundStart: UInt32 = 0xFF5BD1CA
    @State var avatarEmojiBackgroundEnd: UInt32 = 0xFF538EDB
    @State var profilePhotoTitle: String = "Set Profile Photo"
    @State var avatarVersion: Int64 = 0
    @State var avatarImageFailed: Bool = false
    @State var isUploadingAvatar: Bool = false
    @State var avatarExpanded: Bool = false
    @State var avatarExpandedDetailsVisible: Bool = false
    @State var avatarPhotos: ArrayList<String> = ArrayList<String>()
    // Kept only as the backing type of the legacy, unmounted sheet builder.
    // The active flow uses PhotoViewPicker and never populates this collection.
    @State var avatarPickerAssets: ArrayList<MediaPickerAsset> = ArrayList<MediaPickerAsset>()
    @State var avatarPhotoIndex: Int32 = 0
    @State var showAvatarActionSheet: Bool = false
    @State var avatarSheetShowsLibrary: Bool = false
    @State var showLogoutDialog: Bool = false
    @State var toastMessage: String = ""
    @State var showToast: Bool = false
    // M3 修法（diag-suite_settings_root-TC-0505.md）：Immediate 呈现的 loading 覆盖开关，
    // 对位源侧 OverlayStatusController(type: .loading) 展示态。见 navigateImmediate()。
    @State var searchResultLoading: Bool = false
    @State var searchResults: Array<SettingsSearchEntry> = Array<SettingsSearchEntry>()
    // TC-0075 返修（修法 M2d/M4c）：搜索覆盖层默认内容——最近搜索条目，随覆盖层每次
    // 打开时刷新（onExternalSearchVisibleChanged 激活支），对位 SettingsSearchItem.swift:
    // 519-521 的 recentListNode 默认展示。
    @State var recentSearchEntries: Array<SettingsSearchEntry> = Array<SettingsSearchEntry>()
    // TC-0076 F3 返修（diag-suite_settings_root-TC-0076-round2.md F3，D-135）：swipeAction
    // end 槽的行身份镜像——CustomBuilder 体在 ForEach 逐行构建时预求值一次，不能直接读闭包
    // 捕获的 entry（会读到"最后构建的那一行"，同 ChatListPage.cj TC-0085 round2 修法 3 的
    // 数据安全坑）。唯一写入点是 onOffsetChange（真正的逐行滑动事件回调，非 CustomBuilder），
    // 见 buildRecentSettingsSearch()。
    @State var swipeRowRecentItemId: String = ""
    @State var currentLangName: String = "English"
    @State var powerSavingOn: Bool = false
    @State var accountTTLDays: Int32 = 180
    @State var activeSessionsCount: Int32 = 0
    // Multi-account state — loaded from AccountManagerService in ensureLoaded
    @State var loggedInAccounts: Array<MultiAccountEntry> = Array<MultiAccountEntry>()
    @State var activeAccountUserId: Int64 = -1
    // Add-account flow context: tracks (newSlot, originalSlot) returned by addAccount()
    // -1 means no add-account flow in progress
    @State var addAccountNewSlot: Int32 = -1
    @State var addAccountOriginalSlot: Int32 = -1
    // A non-negative value means the user selected another account and the
    // page is waiting for AccountManagerService to finish activating its client.
    @State var pendingAccountSwitchSlot: Int32 = -1
    // TC-0511: account-row long press state. The popup visibility is slot-scoped so
    // each bindPopup remains anchored to the row that received the gesture.
    @State var accountContextMenuSlot: Int32 = -1
    @State var accountContextMenuUserId: Int64 = -1
    @State var accountContextMenuName: String = ""
    @State var logoutConfirmationSlot: Int32 = -1
    @State var logoutConfirmationUserId: Int64 = -1
    @State var logoutConfirmationName: String = ""
    @State var pendingLogoutSlot: Int32 = -1
    @State var swipeAccountSlot: Int32 = -1
    @State var swipeAccountUserId: Int64 = -1
    @State var swipeAccountName: String = ""
    @State var accountSwipeCloseVersion: Int64 = 0
    private var accountPressActive: Bool = false
    private var accountPressGeneration: Int64 = 0
    private var accountTouchStartX: Float64 = 0.0
    private var accountTouchStartY: Float64 = 0.0
    private var suppressNextAccountTap: Bool = false
    // P2-403: Language suggestion banner visibility (dismissed by user per-session)
    @State var showLangSuggestionBanner: Bool = false
    // test_failed 返修（diag-suite_settings_root-TC-0083.md 归因 F4，D 组判据）：号码提醒卡片
    // 的真正可见性门——对位源侧 PeerInfoSettingsItems.swift:88 的
    // `settings.suggestPhoneNumberConfirmation`（服务端 help.getPromoData 下发的
    // pendingSuggestions 是否含 "VALIDATE_PHONE_NUMBER"）。与 `this.userPhone.size > 0`
    // （账号是否有号码，仅作前置必要条件，见下方 ensureLoaded()）是两个独立维度。
    @State var showPhoneConfirmationCard: Bool = false
    // TC-0073 D5-B 返修（diag-suite_settings_root-TC-0073-D5.md 修法组 II，并入 TC-0505 返修
    // 上下文，与 M1-M3 是并列的独立关注点，非同一根因）：Notifications and Sounds 行右侧的
    // 通知权限 `!` 徽标状态，由 refreshNotificationsWarning() 刷新，见 :1089-1093 行接线。
    @State var notificationsWarning: Bool = false
    // S7-18: bumped by ProxyService on every proxy-list/enabled change.
    @StorageLink["proxySettingsVersion"] var proxySettingsVersion: Int64 = 0
    // TC-0073 round2 返修：D-160 挂载守卫专用 toggle，见 buildNotificationsRow() 挂载点注释。
    // 不复用 notificationsWarning 本身（该字段有自己的取值语义），只在其真正改变时翻转一次。
    @State var notificationsBadgeMountToggle: Bool = false
    // 混合迁移：一次性初始化守卫（原 aboutToAppear 实逻辑挪至此）
    @State var loaded: Bool = false

    // iOS parity (TC-SETTINGS-002): 大头像上滚折叠动画。
    // 对应 PeerInfoHeaderNode：上滚时大头像连续缩小(scale 1→0.55)、名称/号码淡出。
    // 复用 UserProfilePage 的 Scroller + onDidScroll 模式。
    private let settingsScroller: Scroller = Scroller()
    private let settingsAvatarSwiper: SwiperController = SwiperController()
    @State var scrollOffset: Float64 = 0.0
    @State var settingsWidthVp: Float64 = 377.0
    private var avatarHeaderTransitionActive: Bool = false
    // A pull that begins from the compact (scrolled) header may only restore
    // the regular header. A fresh pull that begins at the regular header can
    // expand the avatar, matching PeerInfoScreen's two-stage gesture.
    private var avatarPullStartedCollapsed: Bool = false
    // List.currentOffset() is clamped to zero while EdgeEffect.Spring consumes
    // a top overscroll. Keep the largest downward drag reported by onDidScroll
    // so the release decision can still distinguish a deliberate pull.
    @State var avatarTopPullDistance: Float64 = 0.0
    // Only a gesture that starts while the avatar is already expanded may
    // cross the second 32vp threshold and present the full-screen gallery.
    // This mirrors PeerInfoScreen.canOpenAvatarByDragging and prevents the
    // first pull (regular -> expanded) from opening two states at once.
    private var avatarGalleryPullArmed: Bool = false
    private var avatarGalleryOpening: Bool = false
    // The expanded photo pager is a horizontal-only surface.  The enclosing
    // List still observes the raw pointer stream, so remember where each List
    // gesture began and ignore its vertical deltas when the down event landed
    // on the pager.  Pull-to-expand/open is owned exclusively by the rows
    // below the photo, matching PeerInfoScreen's nested recognizers.
    private var avatarPagerTouchActive: Bool = false
    private var avatarScrollStartedInPager: Bool = false
    // CTL-SETTINGS-001: QR/Edit 按压态（"qr"/"edit"/""）
    @State var pressedNavBtn: String = ""
    // P2-318g: per-listener ID for account-switch listener (avoids removeAll clobbering ChatList's listener)
    // -1 means no listener registered
    var _accountSwitchListenerId: Int64 = -1
    var _photoCallbackRegistered: Bool = false

    // TC-0073 D5-B 返修（diag-suite_settings_root-TC-0073-D5.md 修法 II-2）：对位源侧
    // PeerInfoSettingsItems.swift:224-226 notificationsWarning 判定。三次调用全是本地同步
    // 调用（无 RPC），不包 spawn{}，同款范式见 pages/MainTabPage.cj:652-657 的取值时机。
    // 共享判定函数 shouldDisplayNotificationsPermissionWarning 已由 deviceaccess round2 落地
    // （services/DeviceAccessService.cj:89）——本方法不再手抄第二份真值表。
    /**
     * S7-18: iOS PeerInfoSettingsItems.swift:153-168 — the Proxy row exists only when proxy
     * servers are saved; its label is "Telegram" / "SOCKS5" for the active server when proxy
     * use is enabled, otherwise "Disabled". Tap opens proxy settings (PSA:51).
     */
    private func showProxyRow(version: Int64): Bool {
        let _ = version
        return getProxyService().getProxies().size > 0
    }

    private func proxyRowLabel(version: Int64): String {
        let _ = version
        let svc = getProxyService()
        if (svc.isEnabled()) {
            match (svc.getActiveProxy()) {
                case Some(p) =>
                    return match (p.proxyType) {
                        case ProxyType.MTProto => this.presentationStrings.getOr("SocksProxySetup_ProxyTelegram", "Telegram")
                        case ProxyType.SOCKS5 => this.presentationStrings.getOr("SocksProxySetup_ProxySocks5", "SOCKS5")
                    }
                case None => ()
            }
        }
        return this.presentationStrings.getOr("Settings_ProxyDisabled", "Disabled")
    }

    private func refreshNotificationsWarning(): Unit {
        let st = getDeviceAccessService().checkAccess(DeviceAccessType.Notifications)
        let ts = NoticesDataProvider().getPermissionWarningTimestamp(
            ApplicationSpecificGlobalNotice.notificationsPermissionWarning)
        let suppressed = match (ts) { case Some(t) => t > 0; case None => false }
        let newWarning = shouldDisplayNotificationsPermissionWarning(st, suppressed)
        // TC-0073 round2 返修（根因 B）：值真变化时才写字段 + 翻转 D-160 挂载守卫 toggle，
        // 避免每次探针调用都无谓重绘（同款变更守卫见 MainTabPage.cj refreshLocalTabBadges()）。
        if (newWarning != this.notificationsWarning) {
            this.notificationsWarning = newWarning
            this.notificationsBadgeMountToggle = !this.notificationsBadgeMountToggle
        }
    }

    // TC-0073 round2 返修（修法 B-6，D-125 零高度探针）：ArkTS 异步通知权限探针只把真值写进
    // DeviceAccessService 内部缓存，无订阅/推送通道；.onAppear 只在首帧调用一次
    // refreshNotificationsWarning()，探针回调之后到达的真值永远不会被重新读取。让本方法的
    // 返回值被一个零高度 Text 消费，使其在每次 build() 都被重新求值——同款范式见
    // MainTabPage.cj:refreshLocalBadgeMirrors()。内部三次调用全是本地同步调用，无 RPC，
    // 与 MainTabPage 同级开销。
    private func refreshNotificationsBadgeMirror(): String {
        this.refreshNotificationsWarning()
        return ""
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // iOS parity（TC-SETTINGS-005）：重按 Settings tab → 平滑回顶（header 随之重新展开）
        registerTabRetapHandler(3, { =>
            this.settingsScroller.scrollTo(xOffset: 0.0, yOffset: 0.0)
        })
        loadUserInfo()
        getRealAuthService().setProfileChangedCallback({ _user =>
            launch { this.loadUserInfo() }
        })
        let storage = getAuthStorage()
        this.currentLangName = getLangDisplayName(storage.getLangCode())
        this.powerSavingOn = storage.getPowerSaving()
        // test_failed 返修（diag-suite_settings_root-TC-0083.md 归因 F4）：异步预取服务端建议
        // （help.getPromoData RPC，经 providers/NoticesDataProvider.getServerProvidedSuggestions
        // 已过滤本地已 dismiss 的），据此驱动号码提醒卡片的真正可见性门
        // showPhoneConfirmationCard（对位源侧 settings.suggestPhoneNumberConfirmation）。
        // 全程在 spawn{} 里执行，不阻塞 UI 线程（S-001），写法对齐本文件既有的
        // getSettingsService()/getTelegramCoreAccountManagerService() 异步预取模式。
        let _ = spawn {
            let ndp = NoticesDataProvider()
            let suggestions = ndp.getServerProvidedSuggestions(false)
            var hasPhoneSuggestion = false
            for (s in suggestions) {
                if (s.id == "VALIDATE_PHONE_NUMBER") {
                    hasPhoneSuggestion = true
                }
            }
            let finalHasPhoneSuggestion = hasPhoneSuggestion
            launch {
                this.showPhoneConfirmationCard = finalHasPhoneSuggestion
            }
        }
        let _ = spawn {
            let svc = getSettingsService()
            let ttl = svc.getAccountTTL()
            let sessions = svc.getAuthorizations()
            let sessCount = Int32(sessions.size)
            getTelegramCore_AccountManagerService().repairDuplicateAuthorizedSlots()
            // Load multi-account state from AccountManagerService (real backend, multi-slot enumeration)
            let acctSvc = getTelegramCoreAccountManagerService()
            let accounts = acctSvc.getLoggedInAccounts()
            let activeId = acctSvc.getActiveAccountUserId()
            launch {
                this.accountTTLDays = ttl
                this.activeSessionsCount = sessCount
                this.loggedInAccounts = accounts
                this.activeAccountUserId = activeId
                Hilog.info(0, "CjTelegram", "[SettingsPage] Loaded multi-account: count=${accounts.size} activeId=${activeId}")
            }
        }
        // P2-318g: Register account-switch listener with per-ID API to avoid removeAll clobbering
        // ChatListPage's listener. Store the returned ID for precise removal in cleanup.
        // Listener is called from spawn{} inside switchAccount/completeAddAccount, so UI update needs launch{}.
        // This covers: (a) switchAccount by slot (b) completeAddAccount broadcast
        this._accountSwitchListenerId = addAccountSwitchListenerWithId({ _slot: Int32 =>
            let refreshSvc = getTelegramCoreAccountManagerService()
            let updatedAccounts = refreshSvc.getLoggedInAccounts()
            let updatedActiveId = refreshSvc.getActiveAccountUserId()
            // RealAuthService keeps the current user in memory. Refresh it from the
            // newly-active slot before rebuilding the tab root, otherwise Settings
            // and message ownership can keep showing the previous account.
            let _ = getRealAuthService().tryRestoreLogin()
            launch {
                this.loggedInAccounts = updatedAccounts
                this.activeAccountUserId = updatedActiveId
                Hilog.info(0, "CjTelegram", "[SettingsPage] Account switch listener fired: refreshed list count=${updatedAccounts.size} activeId=${updatedActiveId}")
                if (this.pendingLogoutSlot == _slot) {
                    this.finishSelectedAccountLogout(_slot)
                } else if (this.pendingAccountSwitchSlot == _slot) {
                    this.pendingAccountSwitchSlot = -1
                    // Telegram iOS returns to the Chats tab after an account row is
                    // selected. Replacing the root also recreates account-scoped tab
                    // pages instead of leaving their old in-memory view state alive.
                    signalAccountSwitched(false)
                    routerReplace("MainTabPage", "{}")
                }
            }
        })
        Hilog.info(0, "CjTelegram", "[SettingsPage] Registered account switch listener id=${this._accountSwitchListenerId}")
    }

    private func cleanup(): Unit {
        if (this.avatarExpanded) {
            this.setAvatarSystemBars(false)
        }
        getRealAuthService().clearProfileChangedCallback()
        // P2-318g: Use per-ID removal to only remove SettingsPage's own listener.
        // This preserves ChatListPage's independently-registered listener.
        if (this._accountSwitchListenerId >= 0) {
            removeAccountSwitchListener(this._accountSwitchListenerId)
            Hilog.info(0, "CjTelegram", "[SettingsPage] cleanup: removed listener id=${this._accountSwitchListenerId}")
            this._accountSwitchListenerId = -1
        }
        // ensureLoaded installs the profile/account callbacks.  A pushed gallery
        // makes this page disappear, so returning must install them again instead
        // of leaving the Settings page detached from subsequent account changes.
        this.loaded = false
    }

    /** Open the active account as PeerInfoScreen's `.myProfile` counterpart. */
    private func openMyProfile(): Unit {
        if (this.userId <= 0) { return }
        this.setAvatarSystemBars(false)
        setSelectedChat(this.userId, this.userName, "user")
        setSelectedChatUsername(this.addressName)
        routerPush("UserProfilePage", userProfileParam(this.userId, this.userName))
    }

    func loadUserInfo(): Unit {
        let authService = getRealAuthService()
        match (authService.getCurrentUser()) {
            case Some(user) =>
                this.userId = user.id
                this.avatarAccessHash = user.accessHash
                let photoService = getUserPhotoService()
                // getCurrentUser() may be restored from auth storage without photo
                // fields. Keep a richer user already loaded by the dialogs request.
                match (photoService.getCachedUser(user.id)) {
                    case Some(cachedUser) =>
                        if (!cachedUser.hasPhoto) {
                            photoService.cacheUser(user)
                        }
                    case None => photoService.cacheUser(user)
                }
                if (!this._photoCallbackRegistered) {
                    this._photoCallbackRegistered = true
                    photoService.addPhotoReadyCallback({ readyUserId: Int64, path: String =>
                        if (readyUserId == this.userId) {
                            launch {
                                this.avatarLocalPath = path
                                this.avatarImageFailed = false
                                this.avatarVersion = this.avatarVersion + 1
                                this.loggedInAccounts = getTelegramCoreAccountManagerService().getLoggedInAccounts()
                                this.loadAvatarPhotos(readyUserId, this.avatarAccessHash, path)
                            }
                        }
                    })
                }
                this.avatarLocalPath = photoService.getUserPhotoPath(user.id)
                this.loadAvatarPhotos(user.id, user.accessHash, this.avatarLocalPath)
                photoService.requestFullPhotoDownload(user.id)
                let firstName = user.firstName
                let lastName = user.lastName
                this.userName = this.buildDisplayName(firstName, lastName)
                this.userPhone = user.phone
                if (user.username.size > 0) {
                    this.addressName = user.username
                } else {
                    var firstNonEmptyUsername = ""
                    for (candidate in user.usernames) {
                        if (firstNonEmptyUsername.size == 0 && candidate.size > 0) {
                            firstNonEmptyUsername = candidate
                        }
                    }
                    this.addressName = firstNonEmptyUsername
                }
                this.profilePhotoTitle = "Change Profile Photo"
                // Build avatar initials (first letter of first + last name)
                if (firstName.size > 0) {
                    let firstRunes = firstName.toRuneArray()
                    if (lastName.size > 0) {
                        let lastRunes = lastName.toRuneArray()
                        this.avatarText = "${firstRunes[0].toString()}${lastRunes[0].toString()}"
                    } else {
                        this.avatarText = firstRunes[0].toString()
                    }
                } else {
                    this.avatarText = "U"
                }
                Hilog.info(0, "CjTelegram", "[SettingsPage] Loaded user: ${this.userName}")
            case None =>
                this.avatarLocalPath = ""
                this.avatarPhotos = ArrayList<String>()
                this.avatarPhotoIndex = 0
                this.addressName = ""
                this.avatarAccessHash = 0
                this.profilePhotoTitle = "Set Profile Photo"
                Hilog.info(0, "CjTelegram", "[SettingsPage] No current user")
        }
    }

    private func loadAvatarPhotos(uid: Int64, accessHash: Int64, fallbackPath: String): Unit {
        let seed = ArrayList<String>()
        if (fallbackPath.size > 0) { seed.add(fallbackPath) }
        this.avatarPhotos = seed
        this.avatarPhotoIndex = 0
        spawn {
            let fetched = getPeerAvatarGalleryService().fetchAvatarPhotos(uid, accessHash, limit: 20)
            let visiblePhotos = ArrayList<String>()
            if (fallbackPath.size > 0) { visiblePhotos.add(fallbackPath) }
            for (path in fetched) {
                if (path != fallbackPath) { visiblePhotos.add(path) }
            }
            launch {
                if (this.userId == uid) {
                    this.avatarPhotos = visiblePhotos
                    this.avatarPhotoIndex = 0
                    match (getPeerInfoAvatarListService().getCurrentPhotoInfo(uid)) {
                        case Some(info) =>
                            this.avatarEmojiDocumentId = info.emojiDocumentId
                            if (info.emojiBackgroundColors.size >= 2) {
                                this.avatarEmojiBackgroundStart = UInt32(Int64(info.emojiBackgroundColors[0]) & 0xFFFFFFFF)
                                this.avatarEmojiBackgroundEnd = UInt32(Int64(info.emojiBackgroundColors[1]) & 0xFFFFFFFF)
                            }
                        case None => this.avatarEmojiDocumentId = 0
                    }
                }
            }
        }
    }

    private func showToastMsg(msg: String): Unit {
        this.toastMessage = msg
        this.showToast = true
        let _ = spawn {
            sleep(Duration.second * 2)
            launch { this.showToast = false }
        }
    }

    // 返修（F-3a，对位 ChatListItem.cj:103 / ChatListItem.swift:2294-2297
    // floor(itemListBaseFontSize * n/17)）：本屏各处字号按比例从快照 listsFontSize 派生，
    // 除数固定 17（源侧基准常量，独立于 core/storage/AppTheme.cj:246 的 BASE_FONT_SIZE(=16)，
    // 二者不得混用）。不得把多档字号都直接设成同一个 listsFontSize——会丢失各档相对大小关系。
    private func scaledFontSize(numerator: Int64): Float64 {
        let scaled = Int64(Float64(this.presentation.listsFontSize) * Float64(numerator) / 17.0)
        return Float64(scaled)
    }

    private func matchesSearch(label: String): Bool {
        if (this.externalSearchQuery.size == 0) { return true }
        return label.toAsciiLower().contains(this.externalSearchQuery.toAsciiLower())
    }

    private func showSavedSection(): Bool {
        return this.matchesSearch("Saved Messages") || this.matchesSearch("Recent Calls") || this.matchesSearch("Devices") || this.matchesSearch("Chat Folders") || this.matchesSearch("Archive")
    }

    private func showSettingsSection(): Bool {
        return this.matchesSearch("Notifications") || this.matchesSearch("Privacy") || this.matchesSearch("Passport") || this.matchesSearch("Change Phone") || this.matchesSearch("Data") || this.matchesSearch("Address") || this.matchesSearch("Telegram VoIP") || this.matchesSearch("VoIP") || this.matchesSearch("Appearance") || this.matchesSearch("Power Saving") || this.matchesSearch("Language") || this.matchesSearch("Stickers") || this.matchesSearch("Sync") || this.matchesSearch("Backend") || this.matchesSearch("Log Out") || this.matchesSearch("Update") || this.matchesSearch("Permissions")
    }

    private func showPremiumSection(): Bool {
        return this.matchesSearch("Premium") || this.matchesSearch("Stars") || this.matchesSearch("Business") || this.matchesSearch("Gift")
    }

    private func handleAccountTap(acct: MultiAccountEntry): Unit {
        if (this.suppressNextAccountTap) {
            this.suppressNextAccountTap = false
            return
        }
        if (this.pendingAccountSwitchSlot >= 0 || this.pendingLogoutSlot >= 0) { return }
        let targetSlot = getTelegramCore_AccountManagerService().findAuthorizedSlotForUser(acct.userId)
        if (targetSlot < 0) {
            this.showToastMsg("Cannot switch account at this time")
            return
        }
        Hilog.info(0, "CjTelegram", "[SettingsPage] Switch to account slot=${targetSlot} userId=${acct.userId}")
        this.pendingAccountSwitchSlot = targetSlot
        let _ = spawn {
            let coreSvc = getTelegramCore_AccountManagerService()
            let ok = coreSvc.switchAccount(targetSlot)
            if (!ok) {
                launch {
                    this.pendingAccountSwitchSlot = -1
                    this.showToastMsg("Cannot switch account at this time")
                }
            }
        }
    }

    // TC-0511: mirrors the device-verified ChatThemesPage.handleCardTouch shape.
    // A held row opens its own popup after 300 ms; movement beyond 10 vp cancels it.
    private func handleAccountTouch(evt: TouchEvent, acct: MultiAccountEntry): Unit {
        match (evt.eventType) {
            case TouchType.Down =>
                if (this.pendingAccountSwitchSlot >= 0 || this.pendingLogoutSlot >= 0) { return }
                if (evt.touches.size > 0) {
                    this.accountTouchStartX = evt.touches[0].x
                    this.accountTouchStartY = evt.touches[0].y
                }
                this.accountPressActive = true
                this.accountPressGeneration = this.accountPressGeneration + 1
                let generation = this.accountPressGeneration
                let selectedSlot = acct.slot
                let selectedUserId = acct.userId
                let selectedName = this.buildDisplayName(acct.firstName, acct.lastName)
                spawn {
                    sleep(300 * Duration.millisecond)
                    launch {
                        if (this.accountPressActive && this.accountPressGeneration == generation) {
                            this.accountPressActive = false
                            this.suppressNextAccountTap = true
                            this.accountContextMenuSlot = selectedSlot
                            this.accountContextMenuUserId = selectedUserId
                            this.accountContextMenuName = selectedName
                        }
                    }
                }
            case TouchType.Move =>
                if (this.accountPressActive && evt.touches.size > 0) {
                    let dx = evt.touches[0].x - this.accountTouchStartX
                    let dy = evt.touches[0].y - this.accountTouchStartY
                    if (dx * dx + dy * dy > 100.0) {
                        this.accountPressActive = false
                        this.accountPressGeneration = this.accountPressGeneration + 1
                    }
                }
            case TouchType.Up =>
                this.accountPressActive = false
                this.accountPressGeneration = this.accountPressGeneration + 1
            case TouchType.Cancel =>
                this.accountPressActive = false
                this.accountPressGeneration = this.accountPressGeneration + 1
            case _ => ()
        }
    }

    private func closeAccountContextMenu(): Unit {
        this.accountContextMenuSlot = -1
        this.accountContextMenuUserId = -1
        this.accountContextMenuName = ""
        this.suppressNextAccountTap = false
    }

    private func requestSelectedAccountLogout(): Unit {
        if (this.accountContextMenuSlot < 0 || this.accountContextMenuUserId < 0) { return }
        this.logoutConfirmationSlot = this.accountContextMenuSlot
        this.logoutConfirmationUserId = this.accountContextMenuUserId
        this.logoutConfirmationName = this.accountContextMenuName
        this.closeAccountContextMenu()
        this.showLogoutDialog = true
    }

    private func cancelSelectedAccountLogout(): Unit {
        this.showLogoutDialog = false
        this.logoutConfirmationSlot = -1
        this.logoutConfirmationUserId = -1
        this.logoutConfirmationName = ""
    }

    private func confirmSelectedAccountLogout(): Unit {
        if (this.logoutConfirmationSlot < 0 || this.pendingAccountSwitchSlot >= 0 || this.pendingLogoutSlot >= 0) {
            return
        }
        let targetSlot = this.logoutConfirmationSlot
        let targetUserId = this.logoutConfirmationUserId
        this.showLogoutDialog = false
        this.pendingLogoutSlot = targetSlot
        Hilog.info(0, "CjTelegram", "[SettingsPage] Preparing logout slot=${targetSlot} userId=${targetUserId}")
        let _ = spawn {
            let switched = getTelegramCore_AccountManagerService().switchAccount(targetSlot)
            if (!switched) {
                launch {
                    this.pendingLogoutSlot = -1
                    this.logoutConfirmationSlot = -1
                    this.logoutConfirmationUserId = -1
                    this.logoutConfirmationName = ""
                    this.showToastMsg("Cannot log out this account at this time")
                }
            }
        }
    }

    // Called only after the account-switch listener confirms that the selected slot is active.
    private func finishSelectedAccountLogout(switchedSlot: Int32): Unit {
        if (this.pendingLogoutSlot != switchedSlot) { return }
        let _ = spawn {
            try {
                let nextSlot = getTelegramCore_AccountManagerService().logoutCurrentAccountAndSelectNext()
                launch {
                    this.pendingLogoutSlot = -1
                    this.logoutConfirmationSlot = -1
                    this.logoutConfirmationUserId = -1
                    this.logoutConfirmationName = ""
                    if (nextSlot >= 0) {
                        initAccountSwitchBridge()
                        signalAccountSwitched(true)
                        getAuthViewModel().isLoggedIn = true
                        routerReplace("MainTabPage", "{}")
                    } else {
                        getAuthViewModel().isLoggedIn = false
                        routerReplace("SplashPage", "{}")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[SettingsPage] Selected account logout failed: ${e}")
                launch {
                    this.pendingLogoutSlot = -1
                    this.showToastMsg("Could not log out. Please try again.")
                }
            }
        }
    }

    @Builder
    func accountContextMenuContent() {
        Menu {
            MenuItem(
                startIcon: "",
                content: "Log Out",
                endIcon: "",
                labelInfo: "",
                builder: None<() -> Unit>
            )
                .contentFontColor(0xFFFF3B30)
                .onClick({ _ => this.requestSelectedAccountLogout() })
        }
    }

    private func requestSwipedAccountLogout(): Unit {
        if (this.swipeAccountSlot < 0 || this.swipeAccountUserId < 0) { return }
        this.logoutConfirmationSlot = this.swipeAccountSlot
        this.logoutConfirmationUserId = this.swipeAccountUserId
        this.logoutConfirmationName = this.swipeAccountName
        this.accountSwipeCloseVersion = this.accountSwipeCloseVersion + 1
        this.showLogoutDialog = true
    }

    @Builder
    func buildAccountSwipeEndPanel() {
        Column {
            Text(trSource("Logout"))
                .fontSize(this.scaledFontSize(15))
                .fontColor(0xFFFFFFFF)
        }
        .width(80)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(0xFFFF3B30)
        .onClick({ _ => this.requestSwipedAccountLogout() })
    }

    private func accountUnreadCount(account: MultiAccountEntry): Int32 {
        return getTelegramCore_AccountManagerService().getRenderedTotalUnreadForSlot(account.slot)
    }

    // Same compactNumericCountString shape used by MainTabPage.compactCountString,
    // which mirrors TelegramPresentationData/NumericFormat.swift.
    private func accountUnreadBadgeText(count: Int32): String {
        let n = Int64(count)
        if (n >= 1000000) {
            let whole = n / 1000000
            let remainder = (n % 1000000) / 100000
            if (remainder != 0) {
                return "${whole}.${remainder}M"
            }
            return "${whole}M"
        } else if (n >= 1000) {
            let whole = n / 1000
            let remainder = (n % 1000) / 100
            if (remainder != 0) {
                return "${whole}.${remainder}K"
            }
            return "${whole}K"
        }
        return "${n}"
    }

    @Builder
    func buildAccountItems() {
        List {
            ForEach(this.loggedInAccounts, itemGenerator: { acct: MultiAccountEntry, _idx: Int64 =>
                if (!acct.isActive) {
                    ListItem {
                        Column {
                    Row {
                        if (acct.avatarPath.size > 0) {
                            Image(acct.avatarPath)
                                .id("settings_alternate_avatar_${acct.slot}_${acct.userId}")
                                .objectFit(ImageFit.Cover)
                                .width(32)
                                .height(32)
                                .borderRadius(16)
                        } else {
                            Text(acct.avatarText)
                                .fontSize(this.scaledFontSize(15))
                                .fontColor(0xFFFFFF)
                                .width(32)
                                .height(32)
                                .borderRadius(16)
                                .backgroundColor(0xFA790F)
                                .textAlign(TextAlign.Center)
                        }

                        Text(this.buildDisplayName(acct.firstName, acct.lastName))
                            .fontSize(this.scaledFontSize(17))
                            .fontColor(this.presentation.textColor)
                            .maxLines(1)
                            .margin(left: 12)
                            .layoutWeight(1)

                        if (this.accountUnreadCount(acct) > 0) {
                            Text(this.accountUnreadBadgeText(this.accountUnreadCount(acct)))
                                .fontSize(this.scaledFontSize(13))
                                .fontColor(0xFFFFFF)
                                .padding(left: 5, right: 5, top: 0, bottom: 1)
                                .backgroundColor(0xFF3B30)
                                .borderRadius(8)
                                .constraintSize(minWidth: 16)
                                .textAlign(TextAlign.Center)
                                .margin(left: 8)
                        }
                    }
                    .width(100.percent)
                    .height(52)
                    .padding(left: 16, right: 16)
                    .onClick({ _ => this.handleAccountTap(acct) })
                    .onTouch({ evt => this.handleAccountTouch(evt, acct) })
                    .bindPopup(
                        this.accountContextMenuSlot == acct.slot,
                        CustomPopupOptions(
                            builder: bind(this.accountContextMenuContent, this),
                            placement: Placement.Bottom,
                            popupColor: Color.Transparent,
                            enableArrow: false,
                            autoCancel: true,
                            radius: 14.vp,
                            onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                                if (!evt.isVisible && this.accountContextMenuSlot == acct.slot) {
                                    this.closeAccountContextMenu()
                                }
                            })
                        )
                    )
                            ItemListSeparator(leftInset: 60)
                        }
                    }
                    .swipeAction(
                        end: { => bind(this.buildAccountSwipeEndPanel, this)() },
                        onOffsetChange: { offset: Float64 =>
                            if (offset != 0.0) {
                                this.swipeAccountSlot = acct.slot
                                this.swipeAccountUserId = acct.userId
                                this.swipeAccountName = this.buildDisplayName(acct.firstName, acct.lastName)
                            }
                        }
                    )
                }
            }, keyGeneratorFunc: { acct: MultiAccountEntry, _idx: Int64 =>
                "${acct.slot}_${acct.userId}_${acct.firstName}_${acct.lastName}_${acct.avatarText}_${acct.isActive}_${this.accountUnreadCount(acct)}_${this.accountSwipeCloseVersion}_${this.avatarVersion}"
            })
        }
        .width(100.percent)
        .scrollBar(BarState.Off)
    }

    private func startAddAccount(): Unit {
        let coreSvc = getTelegramCore_AccountManagerService()
        match (startSettingsAddAccountFlow(
            isAddingAccount: { => coreSvc.isAddingAccount() },
            repairDuplicateAuthorizedSlots: { => coreSvc.repairDuplicateAuthorizedSlots() },
            addAccount: { => coreSvc.addAccount() }
        )) {
            case SettingsAddAccountOutcome.Started(newSlot, originalSlot) =>
                this.addAccountNewSlot = newSlot
                this.addAccountOriginalSlot = originalSlot
            case SettingsAddAccountOutcome.AlreadyInProgress =>
                this.showToastMsg("Account login already in progress")
            case SettingsAddAccountOutcome.LimitPresented => ()
        }
    }

    private func buildDisplayName(firstName: String, lastName: String): String {
        if (lastName.size > 0) {
            return "${firstName} ${lastName}"
        }
        return firstName
    }

    private func displayPhoneNumber(): String {
        if (this.userPhone.size == 0) { return "" }
        let parsed = parsePhoneNumber("+${this.userPhone}")
        if (parsed.countryCode.size > 0 && parsed.nationalNumber.size > 0) {
            return formatPhoneNumber(parsed.countryCode, parsed.nationalNumber)
        }
        return "+${this.userPhone}"
    }

    private func displaySettingsSubtitle(): String {
        let phone = this.displayPhoneNumber()
        if (this.addressName.size == 0) { return phone }
        if (phone.size == 0) { return "@${this.addressName}" }
        return "${phone} • @${this.addressName}"
    }

    private func presentAvatarActionSheet(): Unit {
        this.avatarSheetShowsLibrary = getPermissionsService().hasFullPhotoLibraryAccess()
        this.showAvatarActionSheet = true
        if (!this.avatarSheetShowsLibrary) {
            return
        }
        let _ = spawn {
            match (getGlobalAbilityContext()) {
                case Some(ctx) =>
                    let assets = getMediaPickerService().fetchAllAssets(ctx, limit: 30)
                    launch { this.avatarPickerAssets = assets }
                case None => ()
            }
        }
    }

    private func chooseAvatarPickerAsset(asset: MediaPickerAsset): Unit {
        this.showAvatarActionSheet = false
        let assetUri = asset.uri
        let _ = spawn {
            match (getGlobalAbilityContext()) {
                case Some(ctx) =>
                    match (getMediaPickerService().fetchAvatarEditingImage(ctx, assetUri)) {
                        case Some(pixelMap) =>
                            // Keep the editor input close to the source-side highQualityFormat image.
                            // The 1280 upload limit is applied only when the completed edit is saved.
                            let bytes = getImageCompressionService().compressPixelMapToJpeg(pixelMap, UInt8(98))
                            pixelMap.release()
                            if (!bytes.isEmpty()) {
                                let filesDir = getAppFilesDir()
                                if (filesDir.size > 0) {
                                    let editDir = filesDir + "/avatar_edits"
                                    try { FileIo.mkdir(editDir) } catch (_e: Exception) {}
                                    let stamp = DateTime.now().toUnixTimeStamp().toSeconds()
                                    let editPath = editDir + "/avatar_pick_${stamp}.jpg"
                                    try {
                                        let outFile = FileIo.open(editPath, mode: 0o1101)
                                        FileIo.write(outFile.fd, bytes)
                                        FileIo.close(outFile)
                                        launch { routerPush("MediaEditorScreen", "avatar|file://" + editPath) }
                                        return
                                    } catch (_e: Exception) {}
                                }
                            }
                        case None => ()
                    }
                case None => ()
            }
            launch { this.showToastMsg("Could not read this photo") }
        }
    }

    @Builder
    private func avatarActionSheetOverlay() {
        Column {
            Row {
                Column {
                    Text("×")
                        .fontSize(this.scaledFontSize(38))
                        .fontWeight(FontWeight.Normal)
                        .fontColor(this.presentation.textColor)
                        .textAlign(TextAlign.Center)
                }
                .width(48)
                .height(48)
                .borderRadius(24)
                .backgroundColor(this.presentation.backgroundColor)
                .justifyContent(FlexAlign.Center)
                .onClick({ _ => this.showAvatarActionSheet = false })

                Column {
                    Text("Recents ⌄")
                        .fontSize(this.scaledFontSize(18))
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.presentation.textColor)
                    Text(trSource("Set new profile photo"))
                        .fontSize(this.scaledFontSize(14))
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(top: 1)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)

                Column { }
                    .width(48)
                    .height(48)
            }
            .width(100.percent)
            .height(70)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)

            Grid {
                GridItem {
                    Column {
                        Image(@r(app.media.chatroom_ic_emoji))
                            .width(42)
                            .height(42)
                            .fillColor(0xFFFFFFFF)
                        Text(trSource("Use an Emoji"))
                            .fontSize(this.scaledFontSize(14))
                            .fontColor(0xFFFFFFFF)
                            .margin(top: 5)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .linearGradient(
                        angle: 145.0,
                        colors: [
                            (Color(UInt32(0xFF82786B)), 0.0),
                            (Color(UInt32(0xFF4F493F)), 1.0)
                        ]
                    )
                    .onClick({ _ =>
                        this.showAvatarActionSheet = false
                        routerPush("EmojiStatusPickerPage", "avatar")
                    })
                }
                .aspectRatio(1.0)

                ForEach(this.avatarPickerAssets, itemGenerator: { asset: MediaPickerAsset, _idx: Int64 =>
                    GridItem {
                        Image(asset.uri)
                            .width(100.percent)
                            .height(100.percent)
                            .objectFit(ImageFit.Cover)
                            .onClick({ _ => this.chooseAvatarPickerAsset(asset) })
                    }
                    .aspectRatio(1.0)
                })
            }
            .width(100.percent)
            .height(430)
            .columnsTemplate("1fr 1fr 1fr")
            .columnsGap(1)
            .rowsGap(1)
            .scrollBar(BarState.Off)

            if (this.avatarPickerAssets.isEmpty()) {
                Text("Choose from Photo Library")
                    .fontSize(this.scaledFontSize(17))
                    .fontColor(this.presentation.accentColor)
                    .height(48)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .onClick({ _ =>
                        this.showAvatarActionSheet = false
                        this.pickAvatarFromSystemAlbum()
                    })
            }

            if (this.canExpandAvatar()) {
                Text(trSource("Remove Photo"))
                    .fontSize(this.scaledFontSize(17))
                    .fontColor(0xFFFF3B30)
                    .height(50)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .onClick({ _ =>
                        this.showAvatarActionSheet = false
                        this.deleteCurrentAvatar()
                    })
            }
        }
        .width(100.percent)
        .height(600)
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(topLeft: 22, topRight: 22)
    }

    @Builder
    private func avatarSheetContent() {
        if (this.avatarSheetShowsLibrary) {
            this.avatarActionSheetOverlay()
        } else {
            this.avatarFallbackActionSheetOverlay()
        }
    }

    @Builder
    private func avatarFallbackActionSheetOverlay() {
        Column {
            Column {
                Text("Set New Photo")
                    .fontSize(this.scaledFontSize(20))
                    .fontColor(this.presentation.accentColor)
                    .width(100.percent).height(57).textAlign(TextAlign.Center)
                    .onClick({ _ =>
                        this.showAvatarActionSheet = false
                        this.pickAvatarFromSystemAlbum()
                    })
                Divider().color(this.presentation.dividerColor)
                Text(trSource("Set Emoji"))
                    .fontSize(this.scaledFontSize(20))
                    .fontColor(this.presentation.accentColor)
                    .width(100.percent).height(57).textAlign(TextAlign.Center)
                    .onClick({ _ =>
                        this.showAvatarActionSheet = false
                        routerPush("EmojiStatusPickerPage", "avatar")
                    })
                if (this.canExpandAvatar()) {
                    Divider().color(this.presentation.dividerColor)
                    Text(trSource("Remove Photo"))
                        .fontSize(this.scaledFontSize(20))
                        .fontColor(0xFFFF3B30)
                        .width(100.percent).height(57).textAlign(TextAlign.Center)
                        .onClick({ _ =>
                            this.showAvatarActionSheet = false
                            this.deleteCurrentAvatar()
                        })
                }
            }
            .width(100.percent)
            .backgroundColor(this.presentation.cardColor)
            .borderRadius(14)

            Text(trSource("Cancel"))
                .fontSize(this.scaledFontSize(20))
                .fontWeight(FontWeight.Medium)
                .fontColor(this.presentation.accentColor)
                .width(100.percent).height(57).textAlign(TextAlign.Center)
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(14)
                .margin(top: 8)
                .onClick({ _ => this.showAvatarActionSheet = false })
        }
        .width(100.percent)
        .padding(left: 10, right: 10, bottom: getSafeAreaBottom() + 6.0)
    }

    private func pickAvatarFromSystemAlbum(): Unit {
        callArkAsync(PICK_PHOTO_ALBUM, "{}", { result =>
            if (!editProfileJsonBool(result, "ok")) { return }
            if (editProfileJsonString(result, "status") != "picked") { return }
            let paths = editProfileJsonStringArray(result, "paths")
            if (paths.isEmpty()) { return }
            let path = paths[0]
            var fileName = "profile.jpg"
            match (path.lastIndexOf("/")) {
                case Some(index) => fileName = path[(index + 1)..path.size]
                case None => ()
            }
            launch { routerPush("MediaEditorScreen", "avatar|" + path) }
        })
    }

    private func uploadSelectedAvatar(photo: SelectedPhoto): Unit {
        this.isUploadingAvatar = true
        let uriCopy = photo.uri
        spawn {
            try {
                var realPath = uriCopy
                if (realPath.startsWith("file://")) { realPath = realPath[7..] }
                let photoData = getImageCompressionService().compressToMaxPixelSize(
                    realPath, Int32(1280), UInt8(86)
                )
                if (photoData.isEmpty()) {
                    launch {
                        this.isUploadingAvatar = false
                        this.showToastMsg("Could not read this photo")
                    }
                    return
                }
                let result = getSettingsService().uploadAndSetProfilePhoto(photoData, "profile.jpg")
                if (!result.success) {
                    launch {
                        this.isUploadingAvatar = false
                        this.showToastMsg("Could not upload photo")
                    }
                    return
                }
                let currentId = this.userId
                if (currentId > 0) {
                    let filesDir = getAppFilesDir()
                    if (filesDir.size > 0) {
                        let avatarDir = filesDir + "/avatars"
                        try { FileIo.mkdir(avatarDir) } catch (_e: Exception) {}
                        let avatarPath = avatarDir + "/avatar_${currentId}.jpg"
                        let outFile = FileIo.open(avatarPath, mode: 0o1101)
                        FileIo.write(outFile.fd, photoData)
                        FileIo.close(outFile)
                        let cachedAvatarPath = "file://" + avatarPath
                        getUserPhotoService().setUserPhotoPath(currentId, cachedAvatarPath)
                        launch { this.avatarLocalPath = cachedAvatarPath }
                    }
                }
                launch {
                    this.avatarImageFailed = false
                    this.avatarVersion = this.avatarVersion + 1
                    this.isUploadingAvatar = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[SettingsPage] avatar upload failed: ${e}")
                launch {
                    this.isUploadingAvatar = false
                    this.showToastMsg("Could not upload photo")
                }
            }
        }
    }

    private func deleteCurrentAvatar(): Unit {
        this.isUploadingAvatar = true
        spawn {
            let ok = getSettingsService().deleteOwnProfilePhoto()
            let currentId = this.userId
            if (ok && currentId > 0) { getUserPhotoService().clearUserPhoto(currentId) }
            launch {
                this.isUploadingAvatar = false
                if (ok) {
                    this.avatarLocalPath = ""
                    this.avatarImageFailed = true
                    this.avatarVersion = this.avatarVersion + 1
                    this.avatarExpanded = false
                } else {
                    this.showToastMsg("Could not remove photo")
                }
            }
        }
    }

    private func showHelpSection(): Bool {
        return this.matchesSearch("Question") || this.matchesSearch("FAQ") || this.matchesSearch("Features")
    }

    private func updateSearchResults(query: String): Unit {
        let svc = getSettingsPageService()
        let results = svc.searchSettings(query)
        if (query.size > 0 && results.size == 0) {
            // TC-0075 返修（修法 M2d 空结果不刷新）：查询非空但无匹配时保持上一批结果，
            // 对位 SettingsSearchItem.swift:450-455（不入队任何 transition）。全屏无空态节点。
            return
        }
        this.searchResults = results
    }

    // R-2 返修（diag-fixture-reset-searchbar-focus）：`@Watch[onExternalSearchVisibleChanged]`
    // 的回调方法（见 `externalSearchVisible` 声明处注释）。
    // TC-0075 返修（修法 M2c/M4c）：退出搜索态时清空结果缓存（文本归零由宿主 M1b 负责，
    // 本组件不再自持文本）；激活搜索态时刷新最近搜索列表，对位 SettingsSearchItem.swift:
    // 519-521 recentListNode 的默认展示时机。
    private func onExternalSearchVisibleChanged(): Unit {
        if (!this.externalSearchVisible) {
            this.updateSearchResults("")
        } else {
            this.recentSearchEntries = getSettingsPageService().getRecentSettingsSearchEntries()
        }
    }

    // TC-0075 返修（修法 M2c）：宿主下发查询文本变化时的回调。
    private func onExternalSearchQueryChanged(): Unit {
        this.updateSearchResults(this.externalSearchQuery)
    }

    /**
     * iOS 设置页 Saved Messages 直接打开与自己的会话（peerId == accountPeerId 的聊天页），
     * 而不是独立的消息列表页。
     */
    private func openSavedMessagesChat(): Unit {
        let selfId = getCurrentUserId()
        if (selfId == 0) { return }
        let title = savedMessagesChatTitle()
        setSelectedChat(selfId, title, "user")
        setSelectedChatDraft("")
        routerPush("ChatRoomPage", title)
    }

    private func openTelegramFeatures(): Unit {
        getOverlayStatusService().showLoading()
        let _ = spawn {
            let peerOpt = getResolveService().resolvePeerByName("TelegramTips")
            launch {
                getOverlayStatusService().dismiss()
                match (peerOpt) {
                    case Some(peer) =>
                        let displayName = if (peer.displayName.size > 0) { peer.displayName } else { "TelegramTips" }
                        let username = if (peer.username.size > 0) { peer.username } else { "TelegramTips" }
                        setSelectedChat(peer.peerId, displayName, peer.peerType)
                        setSelectedChatDraft("")
                        setSelectedChatUsername(username)
                        routerPush("ChatRoomPage", displayName)
                    case None => ()
                }
            }
        }
    }

    private func navigateToSearchResult(entry: SettingsSearchEntry): Unit {
        // TC-0075 返修（修法 M4b）：打开任一结果即写入最近搜索，对位
        // SettingsSearchItem.swift:313（sentinel 分支同样写入，源侧不区分呈现方式）。
        // M1 修法（diag-suite_settings_root-TC-0505.md）：最近搜索键改为 entry.itemId
        // （不再是 entry.routeName），对位 SettingsPageService.getRecentSettingsSearchEntries()
        // 同一批改动。
        getSettingsPageService().addRecentSettingsSearchEntry(entry.itemId)
        // 四个既有 sentinel：保留原行为不变，presentation 在索引里恒填 Push（任务分派指示），
        // 不会落到下面的四态分发。
        if (entry.routeName == "help_ask") {
            // SettingsSearchableItems opens the support peer directly.  The
            // explanatory FAQ alert belongs only to the root Settings row.
            this.openSupportChat()
            return
        }
        if (entry.routeName == "help_faq") {
            this.openFaq()
            return
        }
        if (entry.routeName == "help_features") {
            this.openTelegramFeatures()
            return
        }
        // diag-suite_settings_root-TC-0074-round3.md 修法 A-2：sentinel 拦的是
        // 「不路由到同名页」这一旧约定，现在改为路由到已交付的分享页，零 auth.* 调用。
        if (entry.routeName == "SavedMessagesPage") {
            this.openSavedMessagesChat()
            return
        }
        if (entry.routeName == "profile_qr") {
            routerPush("ChatQrCodeSharePage", "")
            return
        }
        // M3 修法（diag-suite_settings_root-TC-0505.md）：四态呈现分发，对位
        // PeerInfoScreen.swift:4973-4998 openResult 的四分支。entry.paramJson 对绝大多数
        // 条目为默认空串 "{}" 语义的 ""，routerPush(route, "") 与之前行为逐字节一致。
        match (entry.presentation) {
            case SettingsSearchPresentation.Push =>
                routerPush(entry.routeName, entry.paramJson)
            case SettingsSearchPresentation.Modal =>
                // 分发本身与 Push 一致——目的路由是否按模态呈现（竖直上滑 + 下层 dim）
                // 由导航容器根据其模态路由登记表决定（entry/src/main/ets/router/
                // CustomTransition.ets MODAL_ROUTES + entry/src/main/cangjie/router/
                // router.cj isModalRoute()），两个文件都不在 set_root_and_search
                // allowlist 内，登记工作已 emit 到 emitted_integration_contracts。
                routerPush(entry.routeName, entry.paramJson)
            case SettingsSearchPresentation.Immediate =>
                this.navigateImmediate(entry)
            case SettingsSearchPresentation.Dismiss =>
                // 源侧 present(.dismiss, nil)：只退出搜索、不打开任何屏，走与 tab bar 胶囊
                // ✕ 同一条退出通道。
                this.onSearchVisibilityChange(false)
        }
    }

    // M3 修法（diag-suite_settings_root-TC-0505.md）：Immediate 呈现——先示 loading 覆盖，
    // 解析成功再 push；失败静默停在原地、不弹错误提示（源侧 SettingsSearchableItems.swift:
    // 4262-4285 无错误屏，case C3 明确禁止加错误提示）。当前 buildSearchIndex() 的 23 条
    // 根级条目无一使用 Immediate（M4 才会引入，约 7 条，见 diag 报告 M4 小节），
    // resolveImmediateSearchTarget() 因此只有通用有效性校验、没有真实异步解析可迁移——
    // M4 交付使用 Immediate 的叶子时应按各自源侧异步逻辑（如 resolvePeerByName/
    // downloadAndApplyLocalization）替换这里的校验体；本决策记入 unresolved_api_decisions。
    private func navigateImmediate(entry: SettingsSearchEntry): Unit {
        this.searchResultLoading = true
        let resolved = this.resolveImmediateSearchTarget(entry)
        this.searchResultLoading = false
        if (resolved) {
            routerPush(entry.routeName, entry.paramJson)
        }
    }

    // 通用有效性校验：目的路由非空即视为可达。见 navigateImmediate() 注释——这是当前唯一
    // 可实现的通用形态，真实的按叶子异步解析属于 M4。
    private func resolveImmediateSearchTarget(entry: SettingsSearchEntry): Bool {
        return entry.routeName.size > 0
    }

    @Builder
    func buildSearchResults() {
        // TC-0088 返修（diag-suite_settings_root-TC-0088.md 修法 §6，D-127 既定纪律）：显式
        // keyGeneratorFunc——`SettingsSearchEntry` 未实现 `ToString`，省略此参数会让框架默认
        // 键值退化为下标，查询逐字符收缩结果数组时 itemGenerator 不重跑、行文本与 onClick
        // 捕获的 entry 冻结在首建时刻的旧条目上。不要改走给 `SettingsSearchEntry` 加
        // `ToString` 这条路（诊断已排除）。同型判例：`pages/ChatFoldersPage.cj:1194`、
        // `pages/ChatListPage.cj:1468`、`pages/DebugAccountsPageArguments.cj:193`。
        // M1 修法（diag-suite_settings_root-TC-0505.md）：键改为 itemId + paramJson——itemId
        // 对每条目唯一，已足够区分身份，不必再拼 title/subtitle 等内容段。
        ForEach(this.searchResults, itemGenerator: { entry: SettingsSearchEntry, _idx: Int64 =>
            Column {
                Row {
                    Column {
                        // 资源保真修复：真实矢量图标（Chat List/SearchIcon.imageset 转 SVG）替代 emoji 字形
                        Image(@r(app.media.set2_ic_search))
                            .width(16)
                            .height(16)
                            .fillColor(0xFFFFFF)
                    }
                    .width(29)
                    .height(29)
                    .borderRadius(7)
                    .backgroundColor(0x8E8E93)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .margin(right: 16)

                    Column {
                        Text(entry.title)
                            .fontSize(this.scaledFontSize(17))
                            .fontColor(this.presentation.textColor)
                        // M2 修法（diag-suite_settings_root-TC-0505.md）：副标题来自面包屑，
                        // 对位 SettingsSearchResultItem.swift:200
                        // `subtitle = item.breadcrumbs.joined(separator: " → ")`。根级条目
                        // （breadcrumbs 为空数组）不渲染这个 Text 节点——不是渲染空串，本轮
                        // 23 条现存条目全是根级，这里必须是「零节点」不是「空文本节点」，
                        // 否则空 Text 仍占布局高度，肉眼可见地把行拉高一截。
                        if (entry.breadcrumbs.size > 0) {
                            Text(this.joinSettingsSearchBreadcrumbs(entry.breadcrumbs))
                                .fontSize(this.scaledFontSize(13))
                                .fontColor(this.presentation.secondaryTextColor)
                                .margin(top: 2)
                        }
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Text("›")
                        .fontSize(this.scaledFontSize(20))
                        .fontColor(0xC7C7CC)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 10, bottom: 10)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ =>
                    this.navigateToSearchResult(entry)
                })
                Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 61)
            }
        }, keyGeneratorFunc: { entry: SettingsSearchEntry, _idx: Int64 =>
            entry.itemId + "_" + entry.paramJson
        })
    }

    // TC-0075 返修（修法 M2d/M4c）：最近搜索容器——对位 SettingsSearchItem.swift:415-422。
    // 为空时渲染空（无分组头/无 Clear/无占位图/无文案，覆盖层整面白，与源侧参照实拍一致）；
    // 非空时渲染分组头 + Clear + 条目行。行渲染逐字复用 buildSearchResults() 的视觉，
    // 未抽取参数化 @Builder（D-115 既定纪律：@Builder 不传自定义类参数，避免同款重构陷阱）。
    @Builder
    func buildRecentSettingsSearch() {
        if (this.recentSearchEntries.size > 0) {
            Row {
                Text(trSource("Recent"))
                    .fontSize(this.scaledFontSize(13))
                    .fontColor(this.presentation.secondaryTextColor)
                    .fontWeight(FontWeight.Medium)
                    .layoutWeight(1)
                Text(trSource("Clear"))
                    .fontSize(this.scaledFontSize(13))
                    .fontColor(this.presentation.accentColor)
                    .onClick({ _ =>
                        getSettingsPageService().clearRecentSettingsSearchEntries()
                        this.recentSearchEntries = Array<SettingsSearchEntry>()
                    })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 8)
            .alignItems(VerticalAlign.Center)

            // F3 修法（diag-suite_settings_root-TC-0076.md 修法 M3-b）：条目区改为 List +
            // ListItem + swipeAction，对位 SettingsSearchRecentItem.swift:230-236
            // setRevealOptions(right: [...Delete...])。
            // TC-0076 F3 返修（diag-suite_settings_root-TC-0076-round2.md F3）：删除面板必须
            // 经 bind(this.buildSwipeEndPanel, this)() 引用一个 @Builder 无参成员函数，不能
            // 把容器字面量直接写进 end 槽的内联 lambda——D-135（dev_pattern.md:1129）真机三轮
            // 定案：ArkUI-CJ 宏对 CustomBuilder 插槽在"内联 lambda"与"引用 @Builder 函数"两种
            // 传参形态下走不同挂载路径，只有后者的子节点渲染树被正确挂载；上一轮内联写法（本
            // 行原引 StickersSettingsPage.cj:679-706 作为先例）的援引对象选错了——那两个插槽
            // 是单叶子 Button，无容器、无子节点，本来就不触发坍缩，不能类推到这里的
            // Column{Text(...)} 容器字面量。真正对位的先例是 ChatListPage.cj:1666-1700。
            // TC-0088 同款纪律：显式 keyGeneratorFunc，理由与 buildSearchResults() 一致
            // （clearRecentSettingsSearchEntries 之后本数组整体清空重赋值，同样需要正确的
            // 差异计算才能让"清空"立刻反映到渲染上）。
            List {
                ForEach(this.recentSearchEntries, itemGenerator: { entry: SettingsSearchEntry, _idx: Int64 =>
                    ListItem {
                        Column {
                            Row {
                                Column {
                                    Image(@r(app.media.set2_ic_search))
                                        .width(16)
                                        .height(16)
                                        .fillColor(0xFFFFFF)
                                }
                                .width(29)
                                .height(29)
                                .borderRadius(7)
                                .backgroundColor(0x8E8E93)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(HorizontalAlign.Center)
                                .margin(right: 16)

                                Column {
                                    Text(entry.title)
                                        .fontSize(this.scaledFontSize(17))
                                        .fontColor(this.presentation.textColor)
                                    // M2 修法（diag-suite_settings_root-TC-0505.md）：同
                                    // buildSearchResults() 的面包屑副标题规则——根级条目
                                    // （breadcrumbs 为空）不渲染这个 Text 节点。
                                    if (entry.breadcrumbs.size > 0) {
                                        Text(this.joinSettingsSearchBreadcrumbs(entry.breadcrumbs))
                                            .fontSize(this.scaledFontSize(13))
                                            .fontColor(this.presentation.secondaryTextColor)
                                            .margin(top: 2)
                                    }
                                }
                                .alignItems(HorizontalAlign.Start)
                                .layoutWeight(1)

                                Text("›")
                                    .fontSize(this.scaledFontSize(20))
                                    .fontColor(0xC7C7CC)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 10, bottom: 10)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _ =>
                                this.navigateToSearchResult(entry)
                            })
                            Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 61)
                        }
                    }
                    .swipeAction(
                        end: { =>
                            // TC-0076 F3 返修：D-135 形态——面板渲染只经 bind(...)()，不在这个
                            // CustomBuilder 体内做任何 this.field = 赋值（同 ChatListPage.cj
                            // TC-0085 round2 修法 3 的边界：这个体在 ForEach 逐行构建时会被预
                            // 求值一次，赋值写在这里会被"最后构建的那一行"覆盖）。行身份镜像
                            // 的唯一写入点是下面的 onOffsetChange。
                            bind(this.buildSwipeEndPanel, this)()
                        },
                        onOffsetChange: { offset: Float64 =>
                            // 真正的逐行滑动开合事件回调（非 CustomBuilder，不受构建期预求值
                            // 影响），可以安全读闭包捕获的 entry。offset != 0 表示本行正在/已经
                            // 滑出；offset 归零（关闭）不写，避免用另一行的关闭事件覆盖当前正
                            // 打开行的镜像。
                            if (offset != 0.0) {
                                this.swipeRowRecentItemId = entry.itemId
                            }
                        }
                    )
                }, keyGeneratorFunc: { entry: SettingsSearchEntry, _idx: Int64 =>
                    entry.itemId + "_" + entry.paramJson
                })
            }
            .width(100.percent)
            // M2 修法（diag-suite_settings_root-TC-0505.md）：去掉 .layoutWeight(1)——这条
            // List 之前依赖外层 Column 的显式 height(100%) 来分配"剩余空间"；外层 Column
            // 现在改为按内容自适应高度（见调用侧 build() 的 Scroll 包裹处），不再有可分配的
            // 剩余空间，layoutWeight 在无界主轴容器里没有意义。滚动职责整体上收到外层
            // Scroll（"最近搜索分组与结果列表共用这一个滚动容器"），这条 List 只需按自身
            // 内容決定高度，不再自持滚动，scrollBar(Off) 因此保留（关掉这层多余的滚动条，
            // 只由外层 Scroll 显示一条）。
            .scrollBar(BarState.Off)
        }
    }

    // TC-0076 F3 返修（diag-suite_settings_root-TC-0076-round2.md F3，D-135）：swipeAction
    // end 槽引用的 @Builder 无参成员函数（D-115 合规：无参数，函数体内只读裸 this.
    // 字段）——真机 dump+截图验证过的形态，见 ChatListPage.cj:1898 buildSwipeEndPanel()
    // 同名先例。只读 this.swipeRowRecentItemId（由 onOffsetChange 写入），不读任何 ForEach
    // 闭包捕获的 entry。对位 Common.Delete，颜色取
    // theme.list.itemDisclosureActions.destructive.fillColor（本工程 destructive 用色同
    // ChatListPage.cj 删除按钮 0xFF3824 系；本行沿用 round1 已定的 0xFF3B30，未改动）。
    @Builder
    func buildSwipeEndPanel() {
        Column {
            Text(trSource("Delete"))
                .fontSize(this.scaledFontSize(14))
                .fontColor(0xFFFFFFFF)
        }
        .width(80)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(0xFF3B30)
        .onClick({ _ =>
            // M1 修法（diag-suite_settings_root-TC-0505.md）：删除键改用 itemId，与
            // addRecentSettingsSearchEntry/getRecentSettingsSearchEntries 的存取键改动一致。
            getSettingsPageService().removeRecentSettingsSearchEntry(this.swipeRowRecentItemId)
            this.recentSearchEntries = this.recentEntriesWithout(this.swipeRowRecentItemId)
        })
    }

    // F3 修法（diag-suite_settings_root-TC-0076.md 修法 M3-c）：滑动删除的本地镜像更新——
    // 必须重新赋值 @State（不能只调服务），同文件 buildRecentSettingsSearch() 的 Clear 分支
    // （:485-486）已是同款范式。M1 修法（diag-suite_settings_root-TC-0505.md）：比较键改为
    // itemId，与存储层的键改动一致。
    private func recentEntriesWithout(itemId: String): Array<SettingsSearchEntry> {
        let kept = ArrayList<SettingsSearchEntry>()
        var i: Int64 = 0
        while (i < Int64(this.recentSearchEntries.size)) {
            let e = this.recentSearchEntries[i]
            if (e.itemId != itemId) {
                kept.add(e)
            }
            i = i + 1
        }
        return kept.toArray()
    }

    // M2 修法（diag-suite_settings_root-TC-0505.md）：面包屑连接符固定 " → "，对位
    // SettingsSearchResultItem.swift:200（分隔符硬编码，不走本地化）。只在调用侧
    // breadcrumbs.size > 0 时才会被调用。
    private func joinSettingsSearchBreadcrumbs(parts: Array<String>): String {
        var s = ""
        var i: Int64 = 0
        while (i < Int64(parts.size)) {
            if (i > 0) {
                s = s + " → "
            }
            s = s + parts[i]
            i = i + 1
        }
        return s
    }

    private func getLangDisplayName(code: String): String {
        if (code == "en") { return "English" }
        if (code == "zh-hans-raw") { return "简体中文" }
        if (code == "ja-raw") { return "日本語" }
        if (code == "ko") { return "한국어" }
        if (code == "de") { return "Deutsch" }
        if (code == "ru") { return "Русский" }
        if (code == "es") { return "Español" }
        if (code == "fr") { return "Français" }
        return "English"
    }

    private func openUrl(url: String): Unit {
        let (norm, mode) = getBrowserService().resolveUrl(url)
        match (mode) {
            case BrowserMode.InApp =>
                Hilog.info(0, "CjTelegram", "[SettingsPage] openUrl InApp → BrowserScreen: ${norm}")
                routerPush("BrowserScreen", norm)
            case BrowserMode.External =>
                match (getGlobalAbilityContext()) {
                    case Some(ctx) =>
                        let want = Want(
                            action: "ohos.want.action.viewData",
                            uri: norm
                        )
                        try {
                            ctx.startAbility(want)
                            Hilog.info(0, "CjTelegram", "[SettingsPage] openUrl External: ${norm}")
                        } catch (e: Exception) {
                            this.showToastMsg("Cannot open URL")
                            Hilog.info(0, "CjTelegram", "[SettingsPage] openUrl failed: ${e}")
                        }
                    case None =>
                        this.showToastMsg("Cannot open URL")
                }
        }
    }

    /** Telegram FAQ resolves to the system browser on the source app. */
    private func openFaq(): Unit {
        this.openExternalUrl("https://telegram.org/faq#general-questions")
    }

    private func openExternalUrl(url: String): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    ctx.startAbility(Want(action: "ohos.want.action.viewData", uri: url))
                    Hilog.info(0, "CjTelegram", "[SettingsPage] open external URL: ${url}")
                } catch (e: Exception) {
                    this.showToastMsg("Cannot open URL")
                    Hilog.info(0, "CjTelegram", "[SettingsPage] external URL failed: ${e}")
                }
            case None => this.showToastMsg("Cannot open URL")
        }
    }

    /**
     * Root Settings support entry: source presents the volunteer-support
     * explanation first. FAQ opens Safari; OK resolves help.getSupport and
     * enters the returned real user conversation.
     */
    private func showSupportExplanation(): Unit {
        let faqButton = AlertDialogButtonOptions(
            value: this.presentationStrings.getOr("Settings_FAQ_Button", "FAQ"),
            action: { => this.openFaq() }
        )
        let okButton = AlertDialogButtonOptions(
            value: this.presentationStrings.getOr("Common_OK", "OK"),
            action: { => this.openSupportChat() }
        )
        getUIContext().showAlertDialog(AlertDialogParamWithButtons(
            message: this.presentationStrings.getOr(
                "Settings_FAQ_Intro",
                "Please note that Telegram Support is done by volunteers. We try to respond as quickly as possible, but it may take a while.\n\nPlease take a look at the Telegram FAQ: it has important troubleshooting tips and answers to most questions."
            ),
            primaryButton: faqButton,
            secondaryButton: okButton,
            autoCancel: true
        ))
    }

    private func openSupportChat(): Unit {
        let _ = spawn {
            let supportPeer = getSupportService().getSupportPeer()
            launch {
                match (supportPeer) {
                    case Some(peer) =>
                        setSelectedChat(peer.peerId, peer.displayName, "user")
                        setSelectedChatDraft("")
                        setSelectedChatUsername(peer.username)
                        routerPush("ChatRoomPage", peer.displayName)
                    case None => this.showToastMsg("Unable to contact support")
                }
            }
        }
    }

    // 折叠进度 0→1（0=完全展开，1=完全折叠），阈值 120px（对齐 iOS titleCollapseOffset 量级）
    private func settingsCollapse(): Float64 {
        if (this.scrollOffset <= 0.0) { return 0.0 }
        let v = this.scrollOffset / 120.0
        return if (v > 1.0) { 1.0 } else { v }
    }
    // 大头像缩放：100pt → 55pt（scale 1.0 → 0.55）
    private func avatarScaleF(): Float32 {
        return Float32(1.0 - 0.45 * this.settingsCollapse())
    }
    // During the compact-header hand-off the source avatar is gone before the
    // navigation title becomes visible. Without this fade a scaled crescent of
    // the avatar remains behind the title at the top edge.
    private func avatarCollapseOpacity(): Float64 {
        if (this.avatarExpanded) { return 1.0 }
        let collapse = this.settingsCollapse()
        if (collapse <= 0.55) { return 1.0 }
        if (collapse >= 0.75) { return 0.0 }
        return 1.0 - (collapse - 0.55) / 0.20
    }
    // 名称/号码透明度：随折叠淡出（.opacity 需 Float64）
    private func headerFade(): Float64 {
        if (this.avatarExpanded) { return 0.0 }
        let collapse = this.settingsCollapse()
        return if (collapse >= 0.40) { 0.0 } else { 1.0 - collapse / 0.40 }
    }
    // The compact navigation title starts only after the large title has
    // disappeared. This prevents both copies of the name being visible during
    // a slow drag while still leaving a short, smooth hand-off interval.
    private func pinnedTitleOpacity(): Float64 {
        if (this.avatarExpanded) { return 0.0 }
        let collapse = this.settingsCollapse()
        if (collapse <= 0.75) { return 0.0 }
        let v = (collapse - 0.75) / 0.20
        return if (v > 1.0) { 1.0 } else { v }
    }
    // CTL-SETTINGS-006: iOS titleScale = 1-0.4f（min 0.6）连续缩放（PeerInfoHeaderNode:2137）
    private func titleScaleF(): Float32 {
        return Float32(1.0 - 0.4 * this.settingsCollapse())
    }
    // CTL-SETTINGS-006: iOS subtitleScale = 1-0.2f（min 0.8）
    private func subtitleScaleF(): Float32 {
        return Float32(1.0 - 0.2 * this.settingsCollapse())
    }

    private func canExpandAvatar(): Bool {
        return this.userId > 0 &&
            (this.avatarLocalPath.size > 0 || !this.avatarPhotos.isEmpty()) &&
            !this.avatarImageFailed
    }

    private func avatarHeaderHeight(): Float64 {
        // PeerInfo settings expansion is a width-sized, uncropped photo plus
        // a separate 60pt bottom shadow/title extension. Settings content starts
        // below the system safe area, while the expanded source photo covers it;
        // subtract the inset from layout height after shifting the photo upward.
        return if (this.avatarExpanded) { this.settingsWidthVp - getSafeAreaTop() + 60.0 } else { 140.0 }
    }

    private func avatarImageWidth(): Float64 {
        return if (this.avatarExpanded) { this.settingsWidthVp } else { 100.0 }
    }

    private func avatarImageHeight(): Float64 {
        return if (this.avatarExpanded) { this.settingsWidthVp } else { 100.0 }
    }

    private func avatarCornerRadius(): Float64 {
        return if (this.avatarExpanded) { 0.0 } else { 50.0 }
    }

    private func normalTitleHeight(): Float64 {
        return if (this.avatarExpanded) { 0.0 } else { 70.0 }
    }

    private func setAvatarExpanded(expanded: Bool): Unit {
        if (expanded == this.avatarExpanded || (expanded && !this.canExpandAvatar())) { return }
        this.avatarHeaderTransitionActive = true
        this.setAvatarSystemBars(expanded)
        if (expanded) {
            safeAnimateTo(
                { => this.getUIContext() },
                AnimateParam(duration: 350, curve: Curve.Friction),
                { => this.avatarExpanded = true }
            )
            spawn {
                sleep(180 * Duration.millisecond)
                launch {
                    if (this.avatarExpanded) {
                        safeAnimateTo(
                            { => this.getUIContext() },
                            AnimateParam(duration: 170, curve: Curve.EaseOut),
                            { => this.avatarExpandedDetailsVisible = true }
                        )
                    }
                }
            }
        } else {
            safeAnimateTo(
                { => this.getUIContext() },
                AnimateParam(duration: 350, curve: Curve.Friction),
                { =>
                    this.avatarExpandedDetailsVisible = false
                    this.avatarExpanded = false
                }
            )
        }
        spawn {
            sleep(420 * Duration.millisecond)
            launch { this.avatarHeaderTransitionActive = false }
        }
    }

    private func setAvatarSystemBars(expanded: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                spawn {
                    try {
                        let win = getLastWindow(ctx)
                        win.setWindowSystemBarProperties(
                            SystemBarProperties(
                                statusBarColor: "#00000000",
                                isStatusBarLightIcon: expanded,
                                statusBarContentColor: if (expanded) { "#FFFFFFFF" } else { "#FF000000" },
                                navigationBarColor: "#00000000",
                                isNavigationBarLightIcon: false,
                                navigationBarContentColor: "#FF000000",
                                enableStatusBarAnimation: true
                            )
                        )
                    } catch (e: Exception) {
                        Hilog.warn(0, "CjTelegram", "[SettingsPage] status bar update failed: ${e}")
                    }
                }
            case None => ()
        }
    }

    private func avatarPhotoCount(): Int64 {
        return Int64(this.avatarPhotos.size)
    }

    private func currentAvatarPath(): String {
        let idx = Int64(this.avatarPhotoIndex)
        if (idx >= 0 && idx < this.avatarPhotoCount()) { return this.avatarPhotos[idx] }
        return this.avatarLocalPath
    }

    private func selectPreviousAvatar(): Unit {
        let count = this.avatarPhotoCount()
        if (count <= 1) { return }
        let idx = Int64(this.avatarPhotoIndex)
        if (idx > 0) { this.avatarPhotoIndex = Int32(idx - 1) }
    }

    private func selectNextAvatar(): Unit {
        let count = this.avatarPhotoCount()
        if (count <= 1) { return }
        let idx = Int64(this.avatarPhotoIndex)
        if (idx + 1 < count) { this.avatarPhotoIndex = Int32(idx + 1) }
    }

    private func handleAvatarPagerTouch(event: TouchEvent): Unit {
        match (event.eventType) {
            case TouchType.Down => this.avatarPagerTouchActive = true
            case TouchType.Up => this.avatarPagerTouchActive = false
            case TouchType.Cancel => this.avatarPagerTouchActive = false
            case _ => ()
        }
    }

    private func avatarOverPullScale(): Float32 {
        // The first pull is not gallery-armed: it expands the avatar, then any
        // remaining top overscroll still scales that expanded image.  A second
        // pull that starts expanded uses the same scale before opening gallery.
        if (!this.avatarExpanded) { return Float32(1.0) }
        return Float32(1.0 + this.avatarTopPullDistance / this.settingsWidthVp)
    }

    private func openAvatarGalleryFromPull(): Unit {
        if (this.avatarGalleryOpening || !this.canExpandAvatar()) { return }
        this.avatarGalleryOpening = true
        let initialIndex = this.avatarPhotoIndex
        let param = "${this.userId}|${this.avatarAccessHash}|${this.userName}|${initialIndex}"
        // Keep the scaled header alive during the overlay's fade/morph. Reset
        // only after the gallery has covered it, so the gesture never snaps
        // back to the ordinary expanded frame before the full-screen photo.
        routerPush("AvatarGalleryPage", param)
        spawn {
            sleep(220 * Duration.millisecond)
            launch {
                this.avatarExpandedDetailsVisible = false
                this.avatarExpanded = false
                this.avatarGalleryPullArmed = false
                this.avatarTopPullDistance = 0.0
            }
            sleep(230 * Duration.millisecond)
            launch { this.avatarGalleryOpening = false }
        }
    }

    private func snapSettingsHeader(): Unit {
        if (this.avatarExpanded) {
            this.avatarPullStartedCollapsed = false
            this.avatarTopPullDistance = 0.0
            return
        }
        if (this.scrollOffset < 0.0) {
            this.settingsScroller.scrollTo(xOffset: 0.0, yOffset: 0.0, animation: true)
        } else if (this.scrollOffset > 0.0 && this.scrollOffset < 120.0) {
            let target = if (this.scrollOffset < 60.0) { 0.0 } else { 120.0 }
            this.settingsScroller.scrollTo(xOffset: 0.0, yOffset: target, animation: true)
        }
        this.avatarPullStartedCollapsed = false
        this.avatarTopPullDistance = 0.0
    }

    @Builder
    private func expandedAvatarPager() {
        Stack(alignContent: Alignment.TopStart) {
            Swiper(controller: this.settingsAvatarSwiper) {
                ForEach(this.avatarPhotos, itemGenerator: { path: String, idx: Int64 =>
                    Stack {
                        if (idx == 0 && this.avatarEmojiDocumentId != 0) {
                            Column {
                                CustomEmojiImage(
                                    documentId: this.avatarEmojiDocumentId,
                                    size: if (this.avatarExpanded) { 220.0 } else { 72.0 },
                                    placeholder: "",
                                    autoplay: true
                                )
                            }
                            .width(100.percent).height(100.percent)
                            .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                            .linearGradient(angle: 180.0, colors: [
                                (Color(this.avatarEmojiBackgroundStart), 0.0),
                                (Color(this.avatarEmojiBackgroundEnd), 1.0)
                            ])
                            .onTouch({ evt => this.handleAvatarPagerTouch(evt) })
                        } else {
                            Image(path)
                                .width(100.percent)
                                .height(100.percent)
                                .objectFit(ImageFit.Cover)
                                .onTouch({ evt => this.handleAvatarPagerTouch(evt) })
                                .onError({ _ =>
                                    this.avatarImageFailed = true
                                    this.avatarExpandedDetailsVisible = false
                                    this.avatarExpanded = false
                                })
                        }

                        if (this.avatarExpanded && this.avatarPhotoCount() > 1) {
                            Row {
                                Column { }
                                    .width(50.percent)
                                    .height(100.percent)
                                    .onTouch({ evt => this.handleAvatarPagerTouch(evt) })
                                    .onClick({ _ => this.selectPreviousAvatar() })
                                Column { }
                                    .width(50.percent)
                                    .height(100.percent)
                                    .onTouch({ evt => this.handleAvatarPagerTouch(evt) })
                                    .onClick({ _ => this.selectNextAvatar() })
                            }
                            .width(100.percent)
                            .height(100.percent)
                            .onTouch({ evt => this.handleAvatarPagerTouch(evt) })
                        }
                    }
                    .width(100.percent)
                    .height(100.percent)
                })
            }
            .index(UInt32(this.avatarPhotoIndex))
            .loop(false)
            .effectMode(EdgeEffect.None)
            .indicator(false)
            .width(100.percent)
            .height(100.percent)
            .onChange({ idx: Int32 => this.avatarPhotoIndex = idx })

            if (this.avatarExpanded && this.avatarPhotoCount() > 1) {
                Row {
                    ForEach(Array<Int64>(this.avatarPhotoCount(), { i: Int64 => i }),
                        itemGenerator: { idx: Int64, _key: Int64 =>
                            Column { }
                                .layoutWeight(1)
                                .height(3)
                                .borderRadius(1.5)
                                .backgroundColor(if (idx == Int64(this.avatarPhotoIndex)) {
                                    0xFFFFFFFF
                                } else {
                                    0x80FFFFFF
                                })
                                .margin(left: 2, right: 2)
                        })
                }
                .width(100.percent)
                .padding(left: 8, right: 8, top: getSafeAreaTop() + 5.0)
            }
        }
        .width(this.avatarImageWidth())
        .height(this.avatarImageHeight())
        .borderRadius(this.avatarCornerRadius())
        .clip(true)
        .position(
            x: (this.settingsWidthVp - this.avatarImageWidth()) / 2.0,
            y: if (this.avatarExpanded) { -getSafeAreaTop() } else { 40.0 })
        .scale(
            x: if (this.avatarExpanded) { this.avatarOverPullScale() } else { this.avatarScaleF() },
            y: if (this.avatarExpanded) { this.avatarOverPullScale() } else { this.avatarScaleF() },
            z: Float32(1.0))
        .opacity(this.avatarCollapseOpacity())
        .onClick({ _ =>
            if (!this.avatarExpanded) { this.setAvatarExpanded(true) }
        })
    }

    // iOS parity: QR/Edit 固定导航按钮（overlay 常驻，不随滚动——对应 iOS navigationItem）
    // CTL-SETTINGS-001: HighlightableButtonNode 按压 alpha 0.4 瞬时 / 0.2s 释放，无缩放
    // TC-0074 返修（diag-suite_settings_root-TC-0074-round4.md §4.1/§6.3-1，本轮由 Coordinator
    // 定范围下发）：56/28 → 44/22，推翻 round1 裁定。源侧常态/编辑态共用同一个
    // PeerInfoHeaderNavigationButtonContainerNode，buttonHeight=44.0（:361）、
    // cornerRadius=height*0.5（:331-337）；round1 为了让目标侧"常态/编辑态自洽"选了
    // 56/28，代价是两态同时偏离源——`set_account_identity` 本轮已把编辑态（
    // EditProfilePage.cj）改回 44/22，这里同步常态，避免"目标两态不一致"这一源侧不存在的
    // 新偏差留存到下一次全量审查。仅改尺寸常量，不动结构：QR 图标 26x26、Edit 固定宽 80 均保留
    // （源侧编辑态改成了自适应宽，但本文件是 TC-0073 的断言落点，按分派指示保持保守）。
    @Builder
    func pinnedNavButtons() {
        Stack(alignContent: Alignment.TopStart) {
            Column { }
                .width(100.percent)
                .height(54)
                .backgroundColor(this.presentation.backgroundColor)
                .opacity(this.pinnedTitleOpacity())

            Row {
            Column {
                Image(@r(app.media.settings_ic_qr))
                    .width(26)
                    .height(26)
                    .fillColor(if (this.avatarExpanded) { 0xFFFFFFFF } else { this.presentation.textColor })
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor(if (this.avatarExpanded) { 0xC0787878 } else { this.presentation.cardColor })
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .opacity(if (this.pressedNavBtn == "qr") { 0.4 } else { 1.0 })
            // diag-session-loss-investigation R-2：此按钮曾误接 QrLoginPage（登录转移页），
            // 已登录态点击会在共享已授权连接上发起 auth.exportLoginToken，触发 401 拦截把
            // 本机凭据整体清空。diag-suite_settings_root-TC-0074-round3.md 修法 A-1：
            // 路由到已交付的本人资料分享页，零 auth.* 调用。
            .onClick({ _ => routerPush("ChatQrCodeSharePage", "") })
            .onTouch({ evt =>
                match (evt.eventType) {
                    case TouchType.Down => this.pressedNavBtn = "qr"
                    case _ =>
                        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 200, curve: Curve.EaseInOut), { =>
                            this.pressedNavBtn = ""
                        })
                }
            })

            Text(this.userName)
                .fontSize(this.scaledFontSize(17))
                .fontWeight(FontWeight.Bold)
                .fontColor(this.presentation.textColor)
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
                .height(44)
                .opacity(this.pinnedTitleOpacity())

            Text(this.presentationStrings.getOr("Common_Edit", "Edit"))
                .fontSize(this.scaledFontSize(17))
                .fontWeight(FontWeight.Medium)
                .fontColor(if (this.avatarExpanded) { 0xFFFFFFFF } else { this.presentation.textColor })
                .width(52)
                .height(44)
                .borderRadius(22)
                .backgroundColor(if (this.avatarExpanded) { 0xC0787878 } else { this.presentation.cardColor })
                .textAlign(TextAlign.Center)
                .opacity(if (this.pressedNavBtn == "edit") { 0.4 } else { 1.0 })
                .onClick({ _ => routerPush("EditProfilePage", "") })
                .onTouch({ evt =>
                    match (evt.eventType) {
                        case TouchType.Down => this.pressedNavBtn = "edit"
                        case _ =>
                            safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 200, curve: Curve.EaseInOut), { =>
                                this.pressedNavBtn = ""
                            })
                    }
                })
            }
            .width(100.percent)
            .padding(left: 16, right: 16,
                top: if (this.avatarExpanded) { getSafeAreaTop() + 10.0 } else { 10.0 })
        }
        .width(100.percent)
    }

    // TC-0073 round2 返修（diag-suite_settings_root-TC-0073-round2.md 修法 B，D-160 范式）：
    // ItemListDisclosureRow.badgeText 是普通 var（非 @Prop——把它改成无默认值 @Prop 会按 S-141
    // 级联要求全部 65 处调用点显式传参，其中 DebugSettingsPage.cj/EditProfilePage.cj/
    // AutoNightSettingsPage.cj 三个文件不在本 feature allowlist 内，越界改动会破坏它们的编译；
    // 报告已把这条列为需要 Coordinator 扩大授权的权限缺口，本轮未获得该授权，故改用不改子组件
    // 签名的等价修法）。抽成无参 @Builder，单独持有，供下方 if/else 双相同分支挂载点做
    // D-160 强制销毁重建（每次驱动值变化时 notificationsBadgeMountToggle 翻转，两分支
    // branchId 不同 ⇒ 框架销毁旧行、重新以当前 badgeText 求值构造新行，不依赖 @Prop 差分）。
    @Builder
    func buildNotificationsRow() {
        ItemListDisclosureRow(
            icon: @r(app.media.setroot_notifications),
            title: this.presentationStrings.getOr("Settings_NotificationsAndSounds", "Notifications and Sounds"),
            localizedTitleKey: "Settings_NotificationsAndSounds",
            value: "",
            badgeText: if (this.notificationsWarning) { "!" } else { "" },
            onClick: { => routerPush("NotificationSettingsPage", "") }
        )
    }

    public func build() {
        Column {
            // Main scrollable content — Stack 承载滚动内容 + pinned 折叠头
            Stack(alignContent: Alignment.TopStart) {
            // TC-0073 round2 返修（修法 B-6）：D-125 零高度探针，见
            // refreshNotificationsBadgeMirror() 上方注释；必须挂在 build() 方法体内才会
            // 每次重绘都被求值（同款范式 MainTabPage.cj:refreshLocalBadgeMirrors() 挂载点）。
            Text(this.refreshNotificationsBadgeMirror()).height(0).fontSize(0)
            // iOS parity（TC-SCROLL-004）：Scroll 无 edgeEffect API（wrapper 缺口），
            // 换 List(scroller){单 ListItem 包原内容} + Spring —— 长内容双端回弹。
            // Scroller.scrollTo/currentOffset/onDidScroll 与 List 兼容（CountrySelectionPage 先例）。
            List(scroller: this.settingsScroller) {
                ListItem {
                Column {
                    // ====================================================================
                    // P2-403: LANGUAGE SUGGESTION BANNER
                    // Shown when device locale != current app language.
                    // iOS: LanguageSuggestionController shown from TelegramApplication.
                    // ====================================================================
                    if (this.showLangSuggestionBanner) {
                        LanguageSuggestionUIComponent(
                            onDismiss: { =>
                                launch {
                                    this.showLangSuggestionBanner = false
                                }
                            },
                            onApply: { _langCode: String =>
                                launch {
                                    this.showLangSuggestionBanner = false
                                }
                            }
                        )
                    }


                    // ====================================================================
                    // PROFILE HEADER — avatar, name, phone (centered, iOS style)
                    // ====================================================================
                    Column {
                        // Source parity: the compact and expanded presentations are
                        // two layouts of the same header-owned avatar container. The
                        // header itself changes height, so all following rows move with
                        // it instead of being covered by a floating bitmap.
                        Stack(alignContent: Alignment.Bottom) {
                            if (this.canExpandAvatar()) {
                                // Keep one avatar container mounted across both
                                // states, matching PeerInfoAvatarListNode. Swapping
                                // Image/Swiper nodes here creates a visible blank
                                // frame and breaks the additive spring transition.
                                this.expandedAvatarPager()
                            } else {
                                Text(this.avatarText)
                                    .fontSize(this.scaledFontSize(40))
                                    .fontColor(0xFFFFFF)
                                    .width(100)
                                    .height(100)
                                    .borderRadius(50)
                                    .backgroundColor(0xFA790F)
                                    .textAlign(TextAlign.Center)
                                    .scale(x: this.avatarScaleF(), y: this.avatarScaleF(), z: Float32(1.0))
                                    .opacity(this.avatarCollapseOpacity())
                            }

                            // Opacity does not remove a node from hit testing in
                            // this ArkUI binding. Keep the expanded footer out of
                            // the normal tree so it cannot cover the avatar tap.
                            if (this.avatarExpanded && this.canExpandAvatar()) {
                                Stack(alignContent: Alignment.BottomStart) {
                                    // PeerInfoAvatarListNode uses a CAReplicatorLayer:
                                    // the bottom edge is reflected and stretched three
                                    // times, then covered by a variable blur. Scaling
                                    // around the image's bottom edge makes this 60vp
                                    // viewport contain only the final ~20vp instead of
                                    // copying a recognisable rectangular photo strip.
                                    Image(this.currentAvatarPath())
                                        .width(100.percent)
                                        .height(this.avatarImageHeight())
                                        .objectFit(ImageFit.Cover)
                                        .position(x: 0, y: 60.0 - this.settingsWidthVp)
                                        .scale(
                                            x: Float32(1.0),
                                            y: Float32(3.0),
                                            z: Float32(1.0),
                                            centerX: 50.percent,
                                            centerY: 100.percent)
                                        .blur(15.0)

                                    Column {
                                        Text(this.userName)
                                            .fontSize(this.scaledFontSize(20))
                                            .fontWeight(FontWeight.Medium)
                                            .fontColor(0xFFFFFFFF)
                                        if (this.userPhone.size > 0 || this.addressName.size > 0) {
                                            Text(this.displaySettingsSubtitle())
                                                .fontSize(this.scaledFontSize(15))
                                                .fontColor(0xE6FFFFFF)
                                                .margin(top: 3)
                                        }
                                    }
                                    .width(100.percent)
                                    .height(60)
                                    .padding(left: 16, right: 16, bottom: 9)
                                    .justifyContent(FlexAlign.End)
                                    .alignItems(HorizontalAlign.Start)
                                    .linearGradient(
                                        angle: 180.0,
                                        colors: [
                                            (Color(UInt32(0x20000000)), 0.0),
                                            (Color(UInt32(0xA6000000)), 1.0)
                                        ]
                                    )
                                }
                                .width(100.percent)
                                .height(60)
                                .clip(true)
                                .opacity(if (this.avatarExpandedDetailsVisible) { 1.0 } else { 0.0 })
                            }
                        }
                        .width(100.percent)
                        .height(this.avatarHeaderHeight())

                        Column {
                            Text(this.userName)
                                .fontSize(this.scaledFontSize(28))
                                .fontWeight(FontWeight.Bold)
                                .fontColor(this.presentation.textColor)
                                .margin(top: 10)
                                .scale(x: this.titleScaleF(), y: this.titleScaleF(), z: Float32(1.0))
                                .opacity(this.headerFade())

                            if (this.userPhone.size > 0 || this.addressName.size > 0) {
                                Text(this.displaySettingsSubtitle())
                                    .fontSize(this.scaledFontSize(17))
                                    .fontColor(this.presentation.secondaryTextColor)
                                    .margin(top: 3)
                                    .scale(x: this.subtitleScaleF(), y: this.subtitleScaleF(), z: Float32(1.0))
                                    .opacity(this.headerFade())
                            }
                        }
                        .width(100.percent)
                        .height(this.normalTitleHeight())
                        .alignItems(HorizontalAlign.Center)
                        .clip(true)
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                    .padding(bottom: if (this.avatarExpanded) { 12.0 } else { 20.0 })

                    // ====================================================================
                    // SET PROFILE PHOTO / SET USERNAME — Blue CTA section
                    // ====================================================================
                    Column {
                        // test_failed 返修（diag-suite_settings_root-TC-0073.md 归因 缺陷1）：
                        // TC-0024 把这两行按 mapping 规则 3（"无图标的纯蓝字操作行"）改用
                        // ItemListButtonRow 时误判了前提——源侧 PeerInfoScreenActionItem 本身
                        // 就同时支持"整行可点操作"与"可选左图标"，二者不互斥。ItemListButtonRow
                        // 现已补齐 icon 槽（components/ItemListComponents.cj），这里传回原本就
                        // 存在于工程内的成品图标。
                        ItemListButtonRow(
                            title: this.presentationStrings.getOr("Settings_ChangeProfilePhoto", "Change Profile Photo"),
                            localizedTitleKey: "Settings_ChangeProfilePhoto",
                            centered: false,
                            icon: @r(app.media.setroot_cta_avatar),
                            onClick: { => this.presentAvatarActionSheet() }
                        )
                        if (this.addressName.size == 0) {
                            ItemListSeparator(leftInset: 61)
                            ItemListButtonRow(
                                title: "Set Username",
                                centered: false,
                                icon: @r(app.media.setroot_cta_username),
                                onClick: { => routerPush("UsernameSettingsPage", "") }
                            )
                        }
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(10)
                    .clip(true)
                    .margin(left: 16, right: 16)

                    // Telegram iOS places the account list directly below the profile
                    // actions. Only alternate accounts are shown; the active account is
                    // represented by the profile header above.
                    if (this.loggedInAccounts.size > 1) {
                        Column {
                            this.buildAccountItems()
                            Row {
                                SettingsAccountPlusIcon()

                                Text(this.presentationStrings.getOr("Settings_AddAccount", "Add Account"))
                                    .fontSize(this.scaledFontSize(17))
                                    .fontColor(this.presentation.accentColor)
                                    .margin(left: 12)
                                    .layoutWeight(1)
                            }
                            .width(100.percent)
                            .height(52)
                            .padding(left: 16, right: 16)
                            .onClick({ _ => this.startAddAccount() })
                        }
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(10)
                        .clip(true)
                        .margin(left: 16, right: 16, top: 24)
                    }

                    // ====================================================================
                    // PHONE NUMBER CONFIRMATION — matches iOS Settings top reminder card
                    // ====================================================================
                    // test_failed 返修（diag-suite_settings_root-TC-0083.md 归因 F4）：真正门
                    // 是 showPhoneConfirmationCard（服务端 suggestPhoneNumberConfirmation 等价
                    // 判据），userPhone.size > 0 仅保留作为前置必要条件（无号码时格式化文案
                    // 本就无意义）。
                    if (this.userPhone.size > 0 && this.showPhoneConfirmationCard) {
                    Column {
                        Row {
                            Text("!")
                                .fontSize(this.scaledFontSize(18))
                                .fontColor(0xFFFFFF)
                                .fontWeight(FontWeight.Bold)
                                .width(24)
                                .height(24)
                                .borderRadius(12)
                                .backgroundColor(0xFF3B30)
                                .textAlign(TextAlign.Center)
                                .margin(right: 12)

                            // b6: iOS 标题 17pt bold(原 20 偏大致纵向膨胀,锚点残差 +15~22pt)
                            Text("Is ${this.displayPhoneNumber()} still your number?")
                                .fontSize(this.scaledFontSize(17))
                                .fontWeight(FontWeight.Bold)
                                .fontColor(this.presentation.textColor)
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 12, bottom: 8)
                        .alignItems(VerticalAlign.Top)

                        // b6/G-11: 正文行高 22(iOS 两行),"Learn more" 蓝色内联(iOS accent)
                        Text() {
                            Span("Keep your number up to date to ensure you can always log in to Telegram. ")
                                .fontSize(this.scaledFontSize(17))
                                .fontColor(this.presentation.textColor)
                            Span("Learn more")
                                .fontSize(this.scaledFontSize(17))
                                .fontColor(this.presentation.accentColor)
                        }
                        .lineHeight(20)
                        .width(100.percent)
                        .padding(left: 16, right: 16, bottom: 8)

                        ItemListSeparator(leftInset: 16)
                        // test_failed 返修（diag-suite_settings_root-TC-0083.md 归因 F4，D 组）：
                        // 对位源侧 PeerInfoSettingsItems.swift:95-97 Keep 行 →
                        // dismissServerProvidedSuggestion(.validatePhoneNumber)，可观察后果是
                        // 提醒卡片整块消失（源侧该行本身不弹任何提示，故删除原 toast）。
                        // 立即乐观隐藏卡片（不等 RPC 回包）——对位源侧 startStandalone() 的
                        // 即发即忘语义；dismissSuggestion() 内部已做本地 dismissed 缓存追加，
                        // 服务端调用失败也不会让卡片在下次进入设置页时复活，不需要额外的
                        // 重试/超时门控（诊断报告 A-5 边界约束）。
                        // TC-0024 返修：改用 ItemListButtonRow 换取按下高亮（mapping 规则 3）。
                        ItemListButtonRow(
                            title: "Keep ${this.displayPhoneNumber()}",
                            centered: false,
                            onClick: { =>
                                this.showPhoneConfirmationCard = false
                                let _ = spawn {
                                    let ndp = NoticesDataProvider()
                                    ndp.dismissSuggestion("VALIDATE_PHONE_NUMBER")
                                }
                            }
                        )

                        ItemListSeparator(leftInset: 16)
                        ItemListButtonRow(
                            title: "Change Number",
                            centered: false,
                            // diag-suite_settings_root-TC-0083.md round4 M-2-d.2：同一个
                            // PeerInfoScreenSettingsActions.swift:195-206 case .phoneNumber
                            // 动作，proceed 语义 = replaceTopController。
                            onClick: { => routerPush("ChangePhoneIntroPage", "{\"proceed\":\"replace_top\"}") }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(10)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24)
                    }

                    // ====================================================================
                    // MY PROFILE — Single item section
                    // ====================================================================
                    Column {
                        // TC-0024 返修：改用 ItemListDisclosureRow 换取按下高亮（mapping 规则 1）。
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_myprofile),
                            title: this.presentationStrings.getOr("Settings_MyProfile", "My Profile"),
                            localizedTitleKey: "Settings_MyProfile",
                            value: "",
                            onClick: { => this.openMyProfile() }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(10)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24)

                    // S7-18: PROXY section (iOS SettingsSection.proxy, between My Profile and shortcuts).
                    if (this.showProxyRow(this.proxySettingsVersion)) {
                        Column {
                            ItemListDisclosureRow(
                                icon: @r(app.media.setroot_proxy),
                                title: this.presentationStrings.getOr("Settings_Proxy", "Proxy"),
                                localizedTitleKey: "Settings_Proxy",
                                value: this.proxyRowLabel(this.proxySettingsVersion),
                                onClick: { => routerPush("ProxySettingsPage", "") }
                            )
                        }
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(10)
                        .clip(true)
                        .margin(left: 16, right: 16, top: 24)
                    }

                    // ====================================================================
                    // SAVED / CALLS / DEVICES / FOLDERS / ARCHIVE — Navigation section
                    // ====================================================================
                    if (this.showSavedSection()) {
                    Column {
                        // TC-0024 返修：改用 ItemListDisclosureRow 换取按下高亮（mapping 规则 1/2）。
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_saved),
                            title: this.presentationStrings.getOr("Settings_SavedMessages", "Saved Messages"),
                            localizedTitleKey: "Settings_SavedMessages",
                            value: "",
                            onClick: { =>
                                Hilog.info(0, "CjTelegram", "[SettingsPage] Saved messages tapped")
                                this.openSavedMessagesChat()
                            }
                        )
                        ItemListSeparator(leftInset: 61)
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_recentcalls),
                            title: this.presentationStrings.getOr("CallSettings_RecentCalls", "Recent Calls"),
                            localizedTitleKey: "CallSettings_RecentCalls",
                            value: "",
                            onClick: { => routerPush("CallHistoryPage", "") }
                        )
                        ItemListSeparator(leftInset: 61)
                        // iOS 原资产 Item List/Icons/Devices + colorOrange 圆角底（成品 PNG）
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_devices),
                            title: this.presentationStrings.getOr("Settings_Devices", "Devices"),
                            localizedTitleKey: "Settings_Devices",
                            value: if (this.activeSessionsCount > 0) { "${this.activeSessionsCount}" } else { "" },
                            onClick: { => routerPush("DevicesPage", "") }
                        )
                        ItemListSeparator(leftInset: 61)
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_folders),
                            title: this.presentationStrings.getOr("Settings_ChatFolders", "Chat Folders"),
                            localizedTitleKey: "Settings_ChatFolders",
                            value: "",
                            onClick: { => routerPush("ChatFoldersPage", "") }
                        )
                        // iOS parity：Archive 非 iOS 根条目，迁往 DebugSettingsPage
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(10)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24)
                    }

                    // ====================================================================
                    // NOTIFICATIONS / PRIVACY / DATA / APPEARANCE / POWER / LANGUAGE / STICKERS
                    // ====================================================================
                    if (this.showSettingsSection()) {
                    Column {
                        // TC-0024 返修：改用 ItemListDisclosureRow 换取按下高亮（mapping 规则 1/2）。
                        // TC-0073 round2 返修（diag-suite_settings_root-TC-0073-round2.md 修法 B-1'，
                        // D-160 双相同分支挂载守卫，见 buildNotificationsRow() 上方注释）：badgeText
                        // 是普通 var，已挂载实例不会随 this.notificationsWarning 变化回灌；用
                        // if/else 两个源码位置不同但内容相同的分支，靠 notificationsBadgeMountToggle
                        // 翻转触发框架销毁重建，让 badgeText 每次都以当前值重新求值。
                        if (this.notificationsBadgeMountToggle) {
                            this.buildNotificationsRow()
                        } else {
                            this.buildNotificationsRow()
                        }
                        ItemListSeparator(leftInset: 61)
                        // iOS parity：Privacy 行无 TTL 徽章（548d 为非 iOS 元素）；
                        // Passport/Address/Change Phone Number/Telegram VoIP 非 iOS 根条目，迁往 DebugSettingsPage
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_privacy),
                            title: this.presentationStrings.getOr("Settings_PrivacySettings", "Privacy and Security"),
                            localizedTitleKey: "Settings_PrivacySettings",
                            value: "",
                            onClick: { => routerPush("PrivacySettingsPage", "") }
                        )
                        ItemListSeparator(leftInset: 61)
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_data),
                            title: this.presentationStrings.getOr("Settings_ChatSettings", "Data and Storage"),
                            localizedTitleKey: "Settings_ChatSettings",
                            value: "",
                            onClick: { => routerPush("DataStorageSettingsPage", "") }
                        )
                        ItemListSeparator(leftInset: 61)
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_appearance),
                            title: this.presentationStrings.getOr("Settings_Appearance", "Appearance"),
                            localizedTitleKey: "Settings_Appearance",
                            value: "",
                            onClick: { => routerPush("AppearanceSettingsPage", "") }
                        )
                        ItemListSeparator(leftInset: 61)
                        // iOS 原资产 Item List/Icons/PowerSaving + colorOrange（成品 PNG）
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_powersaving),
                            title: this.presentationStrings.getOr("Settings_PowerSaving", "Power Saving"),
                            localizedTitleKey: "Settings_PowerSaving",
                            value: if (this.powerSavingOn) { this.presentationStrings.getOr("Settings_PowerSavingOn", "On") } else { this.presentationStrings.getOr("Settings_PowerSavingOff", "Off") },
                            localizedValueKey: if (this.powerSavingOn) { "Settings_PowerSavingOn" } else { "Settings_PowerSavingOff" },
                            onClick: { => routerPush("PowerSavingSettingsPage", "") }
                        )
                        ItemListSeparator(leftInset: 61)
                        // iOS 原资产 Item List/Icons/Language + colorPurple（成品 PNG）
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_language),
                            title: this.presentationStrings.getOr("Settings_AppLanguage", "Language"),
                            localizedTitleKey: "Settings_AppLanguage",
                            value: this.presentationStrings.getOr("Localization_LanguageName", this.currentLangName),
                            localizedValueKey: "Localization_LanguageName",
                            onClick: { => routerPush("LanguageSettingsPage", "") }
                        )
                        // iOS parity：Language Preview / Check for Updates / Permissions /
                        // Stickers and Emoji 非 iOS 根条目，迁往 DebugSettingsPage
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(10)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24)
                    }

                    // ====================================================================
                    // TELEGRAM PREMIUM / MY STARS / BUSINESS / GIFT
                    // ====================================================================
                    if (this.showPremiumSection()) {
                    Column {
                        // TC-0024 返修：改用 ItemListDisclosureRow 换取按下高亮（mapping 规则 1）。
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_premium),
                            title: this.presentationStrings.getOr("Settings_Premium", "Telegram Premium"),
                            localizedTitleKey: "Settings_Premium",
                            value: "",
                            onClick: { => routerPush("PremiumPage", "") }
                        )
                        ItemListSeparator(leftInset: 61)
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_stars),
                            title: this.presentationStrings.getOr("Gift.Store.Balance.MyStars", "My Stars"),
                            localizedTitleKey: "Gift.Store.Balance.MyStars",
                            value: "",
                            onClick: { => routerPush("StarsPage", "") }
                        )
                        ItemListSeparator(leftInset: 61)
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_business),
                            title: this.presentationStrings.getOr("Settings_Business", "Telegram Business"),
                            localizedTitleKey: "Settings_Business",
                            value: "",
                            onClick: { => routerPush("PremiumBusinessPage", "") }
                        )
                        ItemListSeparator(leftInset: 61)
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_gift),
                            title: this.presentationStrings.getOr("Settings_SendGift", "Send a Gift"),
                            localizedTitleKey: "Settings_SendGift",
                            value: "",
                            onClick: { => routerPush("PremiumGiftPage", "settings") }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(10)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24)
                    }

                    // ====================================================================
                    // HELP — Ask a Question / FAQ / Features
                    // ====================================================================
                    if (this.showHelpSection()) {
                    Column {
                        // TC-0024 返修：改用 ItemListDisclosureRow 换取按下高亮（mapping 规则 1）。
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_support),
                            title: this.presentationStrings.getOr("Settings_Support", "Ask a Question"),
                            localizedTitleKey: "Settings_Support",
                            value: "",
                            onClick: { => this.showSupportExplanation() }
                        )
                        ItemListSeparator(leftInset: 61)
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_faq),
                            title: this.presentationStrings.getOr("Settings_FAQ", "Telegram FAQ"),
                            localizedTitleKey: "Settings_FAQ",
                            value: "",
                            onClick: { => this.openFaq() }
                        )
                        ItemListSeparator(leftInset: 61)
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_features),
                            title: this.presentationStrings.getOr("Settings_Tips", "Telegram Features"),
                            localizedTitleKey: "Settings_Tips",
                            value: "",
                            onClick: { => this.openTelegramFeatures() }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(10)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24)
                    }

                    // iOS parity：Sync & Backend / Log Out / 版本行非 iOS 根条目——
                    // 已迁往 DebugSettingsPage（TC-0077 返修：debug 入口改回 Settings tab 项
                    // 10 连点，见 MainTabPage.selectPrimaryTab / tabBarItemDebugTapAction）。

                    // iOS parity：版本行非 iOS 根条目（版本信息移入 DebugSettingsPage）。
                    // 隐藏 debug 入口：Settings tab 项 10 连点（相邻 ≤ 0.4s），实现见
                    // MainTabPage.selectPrimaryTab / tabBarItemDebugTapAction。

                    // Bottom spacing — iOS parity（TC-SCROLL）：含悬浮 tab bar 底部 inset
                    //（对应 iOS intrinsicInsets.bottom=49+安全区），末行完整可见于 bar 之上
                    Row { }
                        .height(96)
                }
                .width(100.percent)
                }
            }
            .width(100.percent)
            .height(100.percent)
            .scrollBar(BarState.Off)
            // iOS parity：alwaysBounceVertical=true（PeerInfoScreen.swift:1310）
            .edgeEffect(EdgeEffect.Spring)
            .onScrollFrameBegin({ offset: Float64, _state: ScrollState =>
                // Do not let the parent List's spring translate the avatar
                // pager. The pager keeps its own horizontal Swiper gesture;
                // vertical scrolling begins only on the content below it.
                if (this.avatarPagerTouchActive || this.avatarScrollStartedInPager) {
                    OnScrollFrameBeginHandlerResult(offsetRemain: 0.0)
                } else {
                    OnScrollFrameBeginHandlerResult(offsetRemain: offset)
                }
            })
            .onScrollStart({ =>
                this.avatarScrollStartedInPager = this.avatarPagerTouchActive
                this.avatarPullStartedCollapsed = !this.avatarExpanded && this.scrollOffset > 1.0
                this.avatarGalleryPullArmed = this.avatarExpanded && !this.avatarScrollStartedInPager
                this.avatarTopPullDistance = 0.0
            })
            .onDidScroll({ delta: Float64, st: ScrollState =>
                let cur = this.settingsScroller.currentOffset()
                if (cur.isSome()) {
                    let off = cur.getOrThrow().yOffset
                    this.scrollOffset = off

                    // onDidScroll reports content-down movement as a negative
                    // per-frame delta. At the top, currentOffset remains zero;
                    // accumulate that delta instead of waiting for an
                    // unreachable negative absolute offset.
                    if (!this.avatarScrollStartedInPager && st == ScrollState.Scroll &&
                        off <= 0.5 && delta < 0.0) {
                        this.avatarTopPullDistance = this.avatarTopPullDistance - delta
                        // Match PeerInfoScreen.scrollViewDidScroll: expand while
                        // the pull gesture is still tracking at the 32pt threshold.
                        if (!this.avatarExpanded && !this.avatarPullStartedCollapsed &&
                            this.avatarTopPullDistance >= 32.0) {
                            this.setAvatarExpanded(true)
                        } else if (this.avatarExpanded && this.avatarGalleryPullArmed &&
                            this.avatarTopPullDistance >= 32.0) {
                            this.openAvatarGalleryFromPull()
                        }
                    }

                    // `ScrollState.Scroll` is also reported while the header's
                    // real-height transition relayouts this Scroll. Ignore those
                    // synthetic callbacks so tap-to-expand remains expanded.
                    if (!this.avatarHeaderTransitionActive && st == ScrollState.Scroll) {
                        if (off >= 1.0 && this.avatarExpanded) {
                            this.setAvatarExpanded(false)
                        }
                    }
                }
            })
            .onScrollStop({ =>
                if (this.avatarScrollStartedInPager) {
                    this.avatarTopPullDistance = 0.0
                    this.avatarGalleryPullArmed = false
                    this.avatarScrollStartedInPager = false
                }
                this.snapSettingsHeader()
            })

            // pinned QR/Edit 导航按钮（最上层，折叠态也可见——iOS navigationItem 行为）。
            // R-1 返修（diag-fixture-reset-searchbar-focus）：搜索激活态下用真正的 `if`
            // 门把该子树整个移除（不用 opacity/visibility——那不摘除命中测试，见本仓
            // D-145），否则它无条件平铺覆盖搜索输入框整个 x 范围，吃掉全部点击。对位
            // PeerInfoScreen.swift:4959 搜索激活时导航按钮容器淡出且不再截获触摸。
            if (!this.externalSearchVisible) {
                this.pinnedNavButtons()
            }

            // TC-0075 返修（diag-suite_settings_root-TC-0075.md 修法 M2d）：设置搜索覆盖屏，
            // 对位 PeerInfoScreen.swift:5153-5163 把 SettingsSearchContainerNode 挂进
            // headerNode.searchContainer（列表之上的不透明覆盖容器）。作为 Stack 最后一个
            // 子节点，层级最高，完全遮住列表——这正是"内容区被搜索屏覆盖"的实现物。不加任何
            // 返回/关闭控件——关闭控件唯一实现物是 tab bar 胶囊的 ✕（修法 M1c）。
            if (this.externalSearchVisible) {
                // M2 修法（diag-suite_settings_root-TC-0505.md）：外层包 Scroll——修复前这里
                // 是裸 Column(height:100%)，命中数 > 13 行时视口固定高度直接把第 14 条起
                // 静默丢出渲染树（TC-0505 附录 A 订正后的失效点 2）。最近搜索与结果列表共用
                // 这一个滚动容器（源侧是两个互斥的 ListView，目标侧本就是下方 if/else 二选
                // 一，包在同一个 Scroll 内即可），对位 SettingsSearchItem.swift:252/287
                // listNode: ListView。
                Scroll {
                    Column {
                        if (this.externalSearchQuery.size == 0) {
                            this.buildRecentSettingsSearch()
                        } else {
                            this.buildSearchResults()
                        }
                    }
                    .width(100.percent)
                    // TC-0075 round2 返修（diag-suite_settings_root-TC-0075-round2.md 修法 M）：
                    // 不透明底从这个内容驱动高度的盒子移到外层满屏 Scroll 上——最近搜索为空时
                    // buildRecentSettingsSearch() 零节点产出，这个 Column 会坍缩到 1px，底色跟着
                    // 消失，整个覆盖层不再遮挡下方设置列表。对位 SearchDisplayController
                    // (hasBackground: true) 的 backgroundNode，其 frame 等于容器 frame、与内容量
                    // 无关（PeerInfoScreen.swift:4961-5040）。颜色沿用 set_theme_settings 已迁移的
                    // this.presentation.cardColor（不回退成字面量 0xFFFFFF）。
                    // F1 修法（diag-suite_settings_root-TC-0076.md 修法 M1-c）：吃底部键盘
                    // inset，对位 SettingsSearchItem.swift:551-563 的 insets(options:
                    // [.input])——不在本项处理（M2 边界，归 TC-0076 B1 已立案的 inputHeight
                    // 通道），modifier 原样保留、位置不动。内层 Column 不再显式定高
                    // （D-162：本行 padding 现在是在给一个按内容自适应高度的盒子加底部
                    // 内边距，会把盒子撑高而不是从中扣掉，与"给键盘让出空间"的目标一致，
                    // 不是本次改动引入的新语义）。
                    .padding(bottom: this.externalKeyboardInset)
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(this.presentation.cardColor)
                .scrollBar(BarState.Auto)
            }
            }
            .layoutWeight(1)
            .backgroundColor(this.presentation.backgroundColor)

            // ====================================================================
            // TOAST overlay
            // ====================================================================
            if (this.showToast) {
                Text(this.toastMessage)
                    .fontSize(this.scaledFontSize(15))
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0xCC333333)
                    .padding(left: 20, right: 20, top: 10, bottom: 10)
                    .borderRadius(20)
                    .position(x: 0, y: 0)
                    .margin(top: 700)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
            }

            // ====================================================================
            // SEARCH RESULT LOADING overlay (M3 修法，diag-suite_settings_root-TC-0505.md)
            // Immediate 呈现的 loading 覆盖，对位源侧 OverlayStatusController(type: .loading)。
            // 见 navigateImmediate()——失败时这里只是重新变回不可见，不叠加任何错误文案
            // （case C3 明确禁止）。
            // ====================================================================
            if (this.searchResultLoading) {
                Column {
                    LoadingProgress().width(32).height(32)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0x66000000)
                .position(x: 0, y: 0)
            }

            if (this.isUploadingAvatar) {
                Column {
                    LoadingProgress().width(32).height(32)
                    Text("Uploading…")
                        .fontSize(this.scaledFontSize(15))
                        .fontColor(0xFFFFFF)
                        .margin(top: 10)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0x66000000)
                .position(x: 0, y: 0)
            }

            // ====================================================================
            // LOG OUT CONFIRMATION DIALOG (overlay)
            // ====================================================================
            if (this.showLogoutDialog) {
                Column {
                    // Semi-transparent backdrop
                    Column { }
                        .width(100.percent)
                        .layoutWeight(1)
                        .backgroundColor(0x66000000)
                        .onClick({ evt =>
                            this.cancelSelectedAccountLogout()
                        })

                    // Dialog card
                    Column {
                        Text(trSource("Log Out"))
                            .fontSize(this.scaledFontSize(17))
                            .fontWeight(FontWeight.Bold)
                            .fontColor(this.presentation.textColor)
                            .margin(top: 20, bottom: 8)

                        Text("Are you sure you want to log out ${this.logoutConfirmationName}?")
                            .fontSize(this.scaledFontSize(15))
                            .fontColor(this.presentation.secondaryTextColor)
                            .margin(bottom: 20)

                        Divider().color(this.presentation.dividerColor).strokeWidth(1)

                        Row {
                            Button(trSource("Cancel"))
                                .layoutWeight(1)
                                .height(50)
                                .fontSize(this.scaledFontSize(17))
                                .fontColor(this.presentation.accentColor)
                                .backgroundColor(Color.Transparent)
                                .onClick({ evt =>
                                    this.cancelSelectedAccountLogout()
                                })

                            Divider()
                                .vertical(true)
                                .color(this.presentation.dividerColor)
                                .strokeWidth(1)
                                .height(50)

                            Button(trSource("Log Out"))
                                .layoutWeight(1)
                                .height(50)
                                .fontSize(this.scaledFontSize(17))
                                .fontWeight(FontWeight.Bold)
                                .fontColor(0xFF3B30)
                                .backgroundColor(Color.Transparent)
                                .onClick({ evt =>
                                    this.confirmSelectedAccountLogout()
                                })
                        }
                    }
                    .width(300)
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(14)
                    .alignItems(HorizontalAlign.Center)
                    .margin(bottom: 200)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.End)
                .alignItems(HorizontalAlign.Center)
                .position(x: 0, y: 0)
            }

        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .padding(top: if (this.avatarExpanded) { 0.0 } else { getSafeAreaTop() },
            bottom: getSafeAreaBottom())
        .onAreaChange({ _: Area, newArea: Area => this.settingsWidthVp = newArea.width.value })
        .bindSheet(this.showAvatarActionSheet, this.avatarSheetContent, options: SheetOptions(
            backgroundColor: Color.Transparent,
            onDisappear: { => launch { this.showAvatarActionSheet = false } },
            height: SheetSize.FitContent,
            preferType: SheetType.Bottom,
            showClose: false,
            dragBar: false
        ))
        // TC-0073 D5-B 返修（修法 II-3）：对位源侧该行绑定在 data.globalSettings 信号上、
        // 每次进屏取最新值——refreshNotificationsWarning() 与 ensureLoaded() 的一次性守卫
        // 无关，每次 onAppear 都应重新取值。
        .onAppear({ =>
            this.ensureLoaded()
            this.loadUserInfo()
            // The restored self user may be stale (profile edited on another client). iOS keeps
            // the self peer view fresh from the server (AccountViewTracker.swift:1807 ->
            // UpdateCachedPeerData.swift:157); the result reaches loadUserInfo through the
            // profile-changed callback installed by ensureLoaded.
            spawn { let _ = getRealAuthService().refreshCurrentUserFromServer() }
            this.refreshNotificationsWarning()
            if (consumeAvatarPickerPresentation()) {
                this.presentAvatarActionSheet()
            }
        })
        .onDisAppear({ => this.cleanup() })
    }

}
