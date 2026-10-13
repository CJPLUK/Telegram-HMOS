package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getTelegramCoreSettingsService,
    getTelegramCoreAccountManagerService,
    getDeviceAccessService,
    DeviceAccessType,
    DeviceAccessStatus,
    NotificationExceptionCounts
}
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSectionFooter,
    ItemListSeparator,
    ItemListToggleRow,
    ItemListDisclosureRow,
    ItemListButtonRow,
    ItemListNavBarBackground,
    itemListNavBarBackgroundAlpha255,
    ITEM_LIST_NAVBAR_H
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.subscribe
import ohos_app_cangjie_entry.viewmodels.getChatListVM
import ohos_app_cangjie_entry.utils.safeAnimateTo
import std.collection.ArrayList
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.storage.{
    PresentationSnapshot,
    currentPresentation,
    PresentationStringsSnapshot,
    currentPresentationStrings
}

/**
 * NotificationSettingsPage — 通知设置页面（混合工程迁移版）
 * (P2-335 通知音 + P2-334 逐对端例外 + P2-336 OS权限)
 *
 * 实现 iOS Telegram 通知设置对应功能（私聊/群组/频道/Stories/Reactions/
 * Contact Joined/锁屏发送者名/Badge/逐对端例外/OS 权限跳转）。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack（源仅声明未用）
 *  - build() 根去掉 NavDestination 包裹 + .hideTitleBar，只留内容 + .onAppear
 *  - aboutToAppear 有实逻辑（loadAllSettings + fetchNotificationExceptions 两拍）→ ensureLoaded()
 *
 * 整页重构（diag-suite_settings_notifications-TC-0439/0440/0441/0442-round2/0443.md，
 * 归因基线 TC-0439，单一根因：build() 此前完全不读授权状态、把源侧条件权限块/分区
 * footer 硬写成永久行）。本轮范围与已知缺口见各函数注释与 featureX.md Hand-off；
 * TC-0441-round3 F-1：In-App Sounds/Vibrate/Preview 已改读写
 * services/TelegramCoreSettingsService.cj 的本地 Preferences getter/setter（该文件由
 * feature_wiring 在本轮之前建好服务侧半边，Coordinator 已把它并入本 feature 的
 * target_files 打破跨 feature 死锁，详见交付报告）。
 * TC-0439-round3 FIX-B + TC-0441-round4 F-1..F-3：BADGE COUNTER 首行 badge 位集模型
 * 已复刻落地（services/TelegramCoreSettingsService.cj 新增 BADGE_TAG_* 常量与
 * getBadgeIncludeTags/updateBadgeIncludeTag/getBadgeIncludeChannels/
 * setBadgeIncludeChannels，消费端 services/BadgeAggregator.cj 已接线），不再是缺口。
 * 仍未落地的数据层缺口（逐对端例外服务端查询/reset 服务端调用）需要
 * core/mtproto/TLMethods.cj，该文件仍不在本 feature allowlist，按既有先例
 * （ic_nsnd_settings_service_sound_param）以披露方式处理，不新建 integration_contract。
 */
@HybridComponentEntry
@Component
public class NotificationSettingsPage {
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var strings: PresentationStringsSnapshot = currentPresentationStrings()

    private func text(key: String, fallback: String): String {
        return this.strings.getOr(key, fallback)
    }

    private func lockScreenInfoRaw(): String {
        return this.text(
            "Notifications.DisplayNamesOnLockScreenInfoWithLink",
            "Display names in notifications when the device is locked. To disable, make sure that \"Show Previews\" is also set to \"When Unlocked\" or \"Never\" in [iOS Settings]"
        )
    }

    private func lockScreenInfoText(): String {
        return this.lockScreenInfoRaw().replace("[", "").replace("]", "")
    }

    private func lockScreenInfoLink(): String {
        let raw = this.lockScreenInfoRaw()
        let start = raw.indexOf("[")
        let end = raw.indexOf("]")
        if (start.isSome() && end.isSome()) {
            let startIndex = start.getOrThrow() + 1
            let endIndex = end.getOrThrow()
            if (endIndex > startIndex) {
                return raw[startIndex..endIndex]
            }
        }
        return ""
    }

    @State var messageNotifications: Bool = true
    @State var groupNotifications: Bool = true
    @State var channelNotifications: Bool = true
    @State var inAppSounds: Bool = true
    @State var inAppVibrate: Bool = false
    @State var inAppPreview: Bool = true
    @State var storiesNotifications: Bool = true
    @State var reactionsNotifications: Bool = true
    @State var contactJoinedNotification: Bool = true
    @State var lockscreenSenderName: Bool = true
    // 默认 ON，对位 defaultSettings.totalUnreadCountIncludeTags = .all（含 .channel 位）
    @State var badgeIncludeChannels: Bool = true
    @State var badgeCountMessages: Bool = true
    @State var hasMoreThanOneAccount: Bool = false
    @State var displayFromAllAccounts: Bool = true
    @State var isLoading: Bool = true

    @State var loaded: Bool = false

    // TC-0440 A3/B1/B5/C3：五分类行副标题。空串 = 单行（ItemListDisclosureRow.subtitleText）。
    @State var privateSubtitle: String = ""
    @State var groupSubtitle: String = ""
    @State var channelSubtitle: String = ""
    @State var storiesSubtitle: String = ""
    @State var reactionsSubtitle: String = ""
    // D-184 / D-160：subtitleText 是普通 var，父 @State 变化后必须销毁重建。
    @State var categoryRowsMountToggle: Bool = false

    // diag-suite_settings_notifications-TC-0442-round2.md 条目 A：授权态三态镜像
    // （0=Authorized / 1=Denied / 2=NotDetermined）。用 Int32 而非 DeviceAccessStatus
    // 本身存字段，避免 R-112（enum 不自动派生 ==/!=）在 D-125 探针里手写比较分支。
    @State var notifStatusCode: Int32 = 2

    // diag-suite_settings_notifications-TC-0443.md 修法 1：Reset 二次确认弹层可见性。
    @State var showResetSheet: Bool = false

    // FIX-N（diag-suite_settings_notifications-TC-0439.md）：ItemList .glass 导航栏契约。
    // navBarAlpha255 必须是裸 @State（ItemListNavBarBackground.alpha255 是 @Prop / D-125）。
    private var contentScroller: Scroller = Scroller()
    @State var navBarAlpha255: UInt32 = 0
    private var prevScrollOffsetVp: Float64 = 0.0

    // S7-64 (WP-E)：ArkTS 壳 NotificationSettingsPage.ets 的 NavDestination.onShown 经
    // dispatchEvent 转发到这里（事件名逐字一致）。从分类子屏（Alert 开关）pop 回来时本页不会
    // 自动重新 build()，根屏 On/Off 行会停留在旧值 —— 收到事件就重新拉一遍全局通知设置
    // （冷进页首次 onShown 与 ensureLoaded 的首拉重复一次，幂等；onShown 与 subscribe 的
    // 先后未经真机验证，不靠"跳过首次"这种计数守卫，同 StorageUsagePage.cj 先例）。
    private let notificationsShownEvent: String = "settings.notifications.shown"
    private var subscribedShown: Bool = false

    public func aboutToAppear(): Unit {
        this.ensureLoaded()
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadAllSettings()
        if (!this.subscribedShown) {
            this.subscribedShown = true
            subscribe(this.notificationsShownEvent, { _payload: String => this.onShownAgain() })
        }
    }

    private func onShownAgain(): Unit {
        Hilog.info(0, "CjTelegram", "[NotifSettings] shown → reload summary rows")
        this.loadAllSettings()
    }

    /**
     * 从 service 拉取所有通知设置的当前值，回填到 @State。
     */
    private func loadAllSettings(): Unit {
        let _ = spawn {
            let svc = getTelegramCoreSettingsService()
            let usersData = svc.getGlobalNotifySettings("users")
            let chatsData = svc.getGlobalNotifySettings("chats")
            let broadcastsData = svc.getGlobalNotifySettings("broadcasts")
            let reactData = svc.getReactionsNotifySettings()
            let contactJoined = svc.getContactSignUpNotification()
            let lockscreen = svc.getDisplayNameOnLockscreen()
            let badgeChannels = svc.getBadgeIncludeChannels()
            let badgeMsgs = svc.getBadgeCountMessages()

            let msgEnabled = !usersData.isMuted
            let grpEnabled = !chatsData.isMuted
            let chnEnabled = !broadcastsData.isMuted
            let inAppPrev = svc.getInAppDisplayPreviews()
            let sndEnabled = svc.getInAppPlaySounds()
            let vibEnabled = svc.getInAppVibrate()
            let accounts = getTelegramCoreAccountManagerService().getLoggedInAccounts()
            let fromAll = svc.getDisplayNotificationsFromAllAccounts()
            let moreThanOne = accounts.size > 1
            let storiesEnabled = reactData.storiesNotifyFromAll
            let messagesReactOn = !reactData.messagesIsNobody
            let storiesReactOn = !reactData.storiesIsNobody
            let reactEnabled = messagesReactOn || storiesReactOn
            let reactSub = this.composeReactionsSubtitle(messagesReactOn, storiesReactOn)

            Hilog.info(0, "CjTelegram", "[NotifSettings] Loaded: msg=${msgEnabled}, grp=${grpEnabled}, chn=${chnEnabled}")
            Hilog.info(0, "CjTelegram", "[NotifSettings] Loaded: stories=${storiesEnabled}, react=${reactEnabled}, contact=${contactJoined}")

            launch {
                this.messageNotifications = msgEnabled
                this.groupNotifications = grpEnabled
                this.channelNotifications = chnEnabled
                this.inAppPreview = inAppPrev
                this.inAppSounds = sndEnabled
                this.inAppVibrate = vibEnabled
                this.storiesNotifications = storiesEnabled
                this.reactionsNotifications = reactEnabled
                this.reactionsSubtitle = reactSub
                this.contactJoinedNotification = contactJoined
                this.lockscreenSenderName = lockscreen
                this.badgeIncludeChannels = badgeChannels
                this.badgeCountMessages = badgeMsgs
                this.hasMoreThanOneAccount = moreThanOne
                this.displayFromAllAccounts = fromAll
                this.isLoading = false
                // S7-64：五分类行的 value 是 onOffLabel(...) 调用表达式（D-125 非裸字段），
                // 子组件不会随 @State 变化重 build —— 翻转挂载守卫让行立刻按新值重建，
                // 不必等下面例外计数回来再翻。
                this.categoryRowsMountToggle = !this.categoryRowsMountToggle
            }

            this.applyExceptionCounts(svc.fetchNotificationExceptions())
        }
    }

    /** 例外计数回填（S7-64 重置后也单独重读一次；只能在 spawn 内调用）。 */
    private func applyExceptionCounts(counts: NotificationExceptionCounts): Unit {
        let usersSub = this.formatExceptionCount(counts.users)
        let groupsSub = this.formatExceptionCount(counts.groups)
        let channelsSub = this.formatExceptionCount(counts.channels)
        let storiesExSub = this.formatExceptionCount(counts.stories)
        launch {
            this.privateSubtitle = usersSub
            this.groupSubtitle = groupsSub
            this.channelSubtitle = channelsSub
            this.storiesSubtitle = storiesExSub
            this.categoryRowsMountToggle = !this.categoryRowsMountToggle
        }
    }

    private func refreshExceptionCounts(): Unit {
        let _ = spawn {
            this.applyExceptionCounts(getTelegramCoreSettingsService().fetchNotificationExceptions())
        }
    }

    private func composeReactionsSubtitle(messagesOn: Bool, storiesOn: Bool): String {
        if (messagesOn && storiesOn) {
            return this.text("Notifications.Reactions.SubtitleMessages", "Messages") + ", " +
                this.text("Notifications.Reactions.SubtitleStories", "Stories")
        }
        if (messagesOn) { return this.text("Notifications.Reactions.SubtitleMessages", "Messages") }
        if (storiesOn) { return this.text("Notifications.Reactions.SubtitleStories", "Stories") }
        return ""
    }

    private func formatExceptionCount(count: Int32): String {
        if (count <= 0) { return "" }
        let pluralFallback = this.text("Notifications.CategoryExceptions", "%@ exceptions")
        if (count == 1) {
            return this.text("Notifications.CategoryExceptions_1", pluralFallback).replace("%@", "1")
        }
        return this.text("Notifications.CategoryExceptions_any", pluralFallback).replace("%@", "${count}")
    }

    private func updatePeerNotify(peerType: String, enabled: Bool): Unit {
        let capturedPreview = this.inAppPreview
        let _ = spawn {
            let svc = getTelegramCoreSettingsService()
            let muteUntil: Int32 = if (enabled) { 0 } else { 2147483647 }
            let ok = svc.updateGlobalNotifySettings(peerType, muteUntil, capturedPreview, !enabled)
            if (!ok) {
                launch { this.revertPeerToggle(peerType, !enabled) }
            }
        }
    }

    private func revertPeerToggle(peerType: String, revertTo: Bool): Unit {
        if (peerType == "users") { this.messageNotifications = revertTo }
        else if (peerType == "chats") { this.groupNotifications = revertTo }
        else if (peerType == "broadcasts") { this.channelNotifications = revertTo }
    }

    private func updateReactionsSettings(messagesFromAll: Bool, storiesFromAll: Bool): Unit {
        let _ = spawn {
            let svc = getTelegramCoreSettingsService()
            let ok = svc.setReactionsNotifySettings(messagesFromAll, storiesFromAll, true)
            if (!ok) {
                Hilog.info(0, "CjTelegram", "[NotifSettings] setReactionsNotifySettings failed; keeping optimistic UI")
            }
        }
    }

    private func updateContactJoined(enabled: Bool): Unit {
        let _ = spawn {
            let svc = getTelegramCoreSettingsService()
            let ok = svc.setContactSignUpNotification(enabled)
            if (!ok) {
                launch { this.contactJoinedNotification = !enabled }
            }
        }
    }

    // ---- 权限块（diag-suite_settings_notifications-TC-0442-round2.md 条目 A） ----

    // D-125 零高度探针：checkAccess() 只读 DeviceAccessService 内部缓存（同步、廉价），
    // 真值由 ArkTS 侧 callArkAsync("notif.enabled") 异步回填，无订阅/推送通道——
    // .onAppear 只在首帧读一次，探针回来的真值不会自动重新上屏。让本方法的返回值被一个
    // 零高度 Text 消费，使其在每次 build() 都被重新求值（先例 pages/SettingsPage.cj
    // refreshNotificationsBadgeMirror()）。值真变化时才写 @State，避免每次探针调用都
    // 无谓重绘（同款范式见 SettingsPage.cj refreshNotificationsWarning()）。
    private func refreshPermissionMirror(): String {
        let code = this.computeNotifStatusCode()
        if (code != this.notifStatusCode) {
            this.notifStatusCode = code
        }
        return ""
    }

    private func computeNotifStatusCode(): Int32 {
        match (getDeviceAccessService().checkAccess(DeviceAccessType.Notifications)) {
            case DeviceAccessStatus.Authorized => return 0
            case DeviceAccessStatus.Denied => return 1
            case DeviceAccessStatus.NotDetermined => return 2
        }
    }

    // TC-0442-round2 修法条目 A 第 5 条：按钮 onClick 走 getDeviceAccessService()
    // 的 openSystemSettings()（Denied）或 requestAccess()（NotDetermined）——与 F1
    // 返修收敛后的同一出口，不新建第三份 Want。请求结束后主动 refreshNotificationsStatus()
    // 重新探测，真值由上面的零高度探针在下一帧读回。
    private func onPermissionAction(): Unit {
        if (this.notifStatusCode == 1) {
            getDeviceAccessService().openSystemSettings()
        } else if (this.notifStatusCode == 2) {
            getDeviceAccessService().requestAccess(DeviceAccessType.Notifications, { _: Bool =>
                getDeviceAccessService().refreshNotificationsStatus()
            })
        }
    }

    // ---- Reset（diag-suite_settings_notifications-TC-0443.md） ----

    // 修法 1：原 onClick 直接执行的重置逻辑抽成私有方法，onClick 改为先弹二次确认。
    // 修法 2（范围补齐到源侧三路）中"清 per-peer 例外"与"服务端 account.resetNotifySettings"
    // 两路依赖 services/TelegramCoreSettingsService.cj / core/mtproto/TLMethods.cj（无
    // owner，不在本 feature allowlist），本轮不实现，只补齐可在本文件内完成的部分
    // （二次确认 + 现有 5 项全局默认写回）；已在 featureX.md 披露缺口。
    // S7-64：对位 iOS NotificationsAndSounds.swift resetAllNotifications —— 先 account.resetNotifySettings
    // 清服务端全部会话级设置与例外，再把全局项写回默认；成功后清本地会话静音标记并重读例外计数。
    private func performResetAllNotifications(): Unit {
        this.messageNotifications = true
        this.groupNotifications = true
        this.channelNotifications = true
        this.storiesNotifications = true
        this.reactionsNotifications = true
        this.contactJoinedNotification = true
        let _ = spawn {
            let ok = getTelegramCoreSettingsService().resetNotifySettings()
            Hilog.info(0, "CjTelegram", "[NotifSettings] resetAllNotifications server ok=${ok}")
            launch {
                if (ok) {
                    match (getChatListVM()) {
                        case Some(vm) => vm.clearAllChatMutes()
                        case None => ()
                    }
                }
                this.updatePeerNotify("users", true)
                this.updatePeerNotify("chats", true)
                this.updatePeerNotify("broadcasts", true)
                this.updateReactionsSettings(true, true)
                this.updateContactJoined(true)
                this.refreshExceptionCounts()
            }
        }
    }

    // DebugActionSheet.group1/group2 期望 ArrayList<DebugSheetButton>（先例
    // pages/DebugSettingsPage.cj:279-298/397-410 clearDbGroup1/sendLogsGroup2，同一
    // 构造范式：ArrayList<T>() + .add(...)，不用数组字面量）。
    private func resetSheetGroup1(): ArrayList<DebugSheetButton> {
        let g = ArrayList<DebugSheetButton>()
        g.add(DebugSheetButton("Reset", DebugSheetButtonStyle.SheetDestructive, { =>
            this.showResetSheet = false
            this.performResetAllNotifications()
        }))
        return g
    }

    private func resetSheetGroup2(): ArrayList<DebugSheetButton> {
        let g = ArrayList<DebugSheetButton>()
        g.add(DebugSheetButton("Cancel", DebugSheetButtonStyle.SheetBold, { =>
            this.showResetSheet = false
        }))
        return g
    }

    // ---- 辅助文本函数 ----

    // diag-suite_settings_notifications-TC-0445.md F-A1a：根屏分类行右侧改为只读
    // label（源 :565 `Notifications_On`/`Notifications_Off`），不是可写开关。
    private func onOffLabel(enabled: Bool): String {
        if (enabled) { return "On" }
        return "Off"
    }

    /**
     * Path 命令串。逐字照抄 pages/PrivacySettingsPage.cj:272-283。
     *
     * ArkUI Path 的 commands 坐标按 **px** 消费；同组件的 .width/.height/.strokeWidth
     * 是 Length，默认单位 vp。源侧 glassBackArrowImage（NavigationButtonNode.swift:8-23）
     * 把点坐标画进 DrawingContext，由框架按 deviceScale 放大，这一次乘法在 ArkUI 侧
     * 必须由调用方自己补。坐标：44×44 画布，(24.6,14)→(17,22)→(24.6,30)。
     */
    private func backArrowCommands(): String {
        let scale: Float64 = match (this.getUIContext().vp2px(1.0.vp)) {
            case Some(len) => len.value
            case None => Float64(getDefaultDisplaySync().densityPixels)
        }
        let xRight: Float64 = 24.6 * scale
        let xApex: Float64 = 17.0 * scale
        let yTop: Float64 = 14.0 * scale
        let yMid: Float64 = 22.0 * scale
        let yBottom: Float64 = 30.0 * scale
        return "M${xRight} ${yTop} L${xApex} ${yMid} L${xRight} ${yBottom}"
    }

    // D-184：subtitleText 普通 var，抽无参 @Builder + 双相同分支挂载守卫。
    @Builder
    func buildMessageNotificationRows() {
        ItemListDisclosureRow(
            icon: @r(app.media.setroot_ds_private),
            title: this.text("Notifications.PrivateChats", "Private Chats"),
            subtitleText: this.privateSubtitle,
            value: this.onOffLabel(this.messageNotifications),
            onClick: { => routerPush("NotificationsPeerCategoryPage", "{\"category\":\"users\"}") }
        )
        ItemListSeparator(leftInset: 61)
        ItemListDisclosureRow(
            icon: @r(app.media.setroot_ds_group),
            title: this.text("Notifications.GroupChats", "Group Chats"),
            subtitleText: this.groupSubtitle,
            value: this.onOffLabel(this.groupNotifications),
            onClick: { => routerPush("NotificationsPeerCategoryPage", "{\"category\":\"chats\"}") }
        )
        ItemListSeparator(leftInset: 61)
        ItemListDisclosureRow(
            icon: @r(app.media.setroot_ds_channel),
            title: this.text("Notifications.Channels", "Channels"),
            subtitleText: this.channelSubtitle,
            value: this.onOffLabel(this.channelNotifications),
            onClick: { => routerPush("NotificationsPeerCategoryPage", "{\"category\":\"broadcasts\"}") }
        )
        ItemListSeparator(leftInset: 61)
        ItemListDisclosureRow(
            icon: @r(app.media.setroot_ds_stories),
            title: this.text("Notifications.Stories", "Stories"),
            subtitleText: this.storiesSubtitle,
            value: this.onOffLabel(this.storiesNotifications),
            onClick: { => routerPush("NotificationsPeerCategoryPage", "{\"category\":\"stories\"}") }
        )
        ItemListSeparator(leftInset: 61)
        ItemListDisclosureRow(
            icon: @r(app.media.setroot_ds_reactions),
            title: this.text("Notifications.Reactions", "Reactions"),
            subtitleText: this.reactionsSubtitle,
            value: this.onOffLabel(this.reactionsNotifications),
            onClick: { => routerPush("NotificationsPeerCategoryPage", "{\"category\":\"reactions\"}") }
        )
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Stack(alignContent: Alignment.TopStart) {
                // D-125 零高度探针（见 refreshPermissionMirror() 上方注释），挂在方法体内、
                // isLoading 分支之外，使授权态探测在首屏加载期间即开始生效。
                Text(this.refreshPermissionMirror()).height(0).fontSize(0)

                if (this.isLoading) {
                    Column {
                        LoadingProgress().width(36).height(36)
                        Text(this.text("Channel.NotificationLoading", "Loading..."))
                            .fontSize(14)
                            .fontColor(this.presentation.secondaryTextColor)
                            .margin(top: 8)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .padding(top: ITEM_LIST_NAVBAR_H)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    Scroll(this.contentScroller) {
                        Column {

                            // ── SHOW NOTIFICATIONS FROM（TC-0514：N>1 才渲染，权限块之前）──
                            if (this.hasMoreThanOneAccount) {
                                ItemListSectionHeader(title: this.text("NotificationSettings.ShowNotificationsFromAccountsSection", "SHOW NOTIFICATIONS FROM"), topPad: 20)
                                Column {
                                    ItemListToggleRow(
                                        title: this.text("NotificationSettings.ShowNotificationsAllAccounts", "All Accounts"),
                                        isOn: this.displayFromAllAccounts,
                                        onChange: { isOn: Bool =>
                                            this.displayFromAllAccounts = isOn
                                            let _ = spawn { getTelegramCoreSettingsService().saveDisplayNotificationsFromAllAccounts(isOn) }
                                        }
                                    )
                                }
                                .backgroundColor(this.presentation.cardColor)
                                .borderRadius(12)
                                .margin(left: 16, right: 16)
                                if (this.displayFromAllAccounts) {
                                    ItemListSectionFooter(text: this.text("NotificationSettings.ShowNotificationsAllAccountsInfoOn", "Turn this off if you want to receive notifications only from your active account."))
                                } else {
                                    ItemListSectionFooter(text: this.text("NotificationSettings.ShowNotificationsAllAccountsInfoOff", "Turn this on if you want to receive notifications from all your accounts."))
                                }
                            }

                            // ── PERMISSION BLOCK（TC-0442-round2 条目 A，对位源 :538-561）──
                            // 三态条件渲染：Authorized 时整段不渲染（对位源 default: break）；
                            // Denied/NotDetermined 才出现，文案取
                            // Localizable.strings:3933-3938 Notifications.PermissionsTitle/
                            // PermissionsText/PermissionsAllow/PermissionsAllowInSettings。
                            // `.unreachable`（已授权但 banner 被关）态在目标侧无数据源
                            // （checkNotificationsStatus() 只三态），按源侧结构处理——不臆造
                            // 掩码判定，该态永不触发，故不写第四分支。
                            if (this.notifStatusCode != 0) {
                                Column {
                                    Column {
                                        Text(this.text("Notifications.PermissionsTitle", "Turn ON Notifications"))
                                            .fontSize(15)
                                            .fontWeight(FontWeight.Bold)
                                            .fontColor(this.presentation.textColor)
                                            .width(100.percent)
                                        Text(this.text("Notifications.PermissionsText", "Don't miss important messages from your friends and coworkers."))
                                            .fontSize(13)
                                            .fontColor(this.presentation.secondaryTextColor)
                                            .margin(top: 4)
                                            .width(100.percent)
                                    }
                                    .alignItems(HorizontalAlign.Start)
                                    .width(100.percent)
                                    .padding(left: 16, right: 16, top: 16, bottom: 4)

                                    ItemListButtonRow(
                                        title: if (this.notifStatusCode == 1) {
                                            this.text("Notifications.PermissionsAllowInSettings", "Turn ON in Settings")
                                        } else {
                                            this.text("Notifications.PermissionsAllow", "Turn Notifications ON")
                                        },
                                        destructive: false,
                                        centered: false,
                                        onClick: { => this.onPermissionAction() }
                                    )
                                }
                                .backgroundColor(this.presentation.cardColor)
                                .borderRadius(12)
                                .clip(true)
                                .margin(left: 16, right: 16, top: 20)
                            }

                            // ── MESSAGE NOTIFICATIONS ──（TC-0439 修法 1：单一分区含 5 行，
                            // Private/Group/Channel/Stories/Reactions 次序对位源
                            // NotificationsAndSoundsController.swift:529-628。旧"STORIES &
                            // REACTIONS"独立分区（源侧无对应物）随本轮合并撤销。TC-0440 修法 2
                            // 要求 Stories/Reactions 改 disclosure 行 + 跳转（而非 toggle）：
                            // 复用本 feature 已有的 NotificationsPeerCategoryPage 通用子屏
                            // （本轮已扩展支持 stories/reactions 分类，见该文件），不新建页面
                            // 文件（allowlist 不含新增页）。RC-5（Stories 应读
                            // globalNotifySettings.privateChats.storySettings.mute 三态，而非
                            // reactData.storiesNotifyFromAll 布尔）需要
                            // services/TelegramCoreSettingsService.cj 新增字段解析，无 owner，
                            // 不在 allowlist，本轮未修——已在 featureX.md 披露，右侧仍是二态
                            // On/Off 而非源侧 Top 5/On/Off 三态。
                            ItemListSectionHeader(title: this.text("Notifications.MessageNotifications", "MESSAGE NOTIFICATIONS"), topPad: 20)

                            Column {
                                if (this.categoryRowsMountToggle) {
                                    this.buildMessageNotificationRows()
                                } else {
                                    this.buildMessageNotificationRows()
                                }
                            }
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(12)
                            .clip(true)
                            .margin(left: 16, right: 16)

                            // ── IN-APP NOTIFICATIONS ──（TC-0439 修法 8：字面量取源
                            // Localizable.strings 的 In-App Sounds / In-App Preview。TC-0441
                            // round3 F-1：这三项源侧是本地记录（InAppNotificationSettings.swift，
                            // accountManager shared data，从不发服务端），目标侧此前误接在服务端
                            // 全局通知设置的 silent/show_previews 位上（Sounds 因此恒读回 true、
                            // 不持久化）。现改为读写 services/TelegramCoreSettingsService.cj 的
                            // 本地 Preferences getInAppPlaySounds/saveInAppPlaySounds、
                            // getInAppVibrate/saveInAppVibrate、
                            // getInAppDisplayPreviews/saveInAppDisplayPreviews（三键：
                            // notif_inapp_play_sounds/notif_inapp_vibrate/notif_inapp_display_previews，
                            // 默认 true/false/true，与源侧 defaultSettings 一致）。
                            ItemListSectionHeader(title: this.text("Notifications.InAppNotifications", "IN-APP NOTIFICATIONS"), topPad: 20)

                            Column {
                                ItemListToggleRow(
                                    title: this.text("Notifications.InAppNotificationsSounds", "In-App Sounds"),
                                    isOn: this.inAppSounds,
                                    onChange: { isOn: Bool =>
                                        this.inAppSounds = isOn
                                        let _ = spawn { getTelegramCoreSettingsService().saveInAppPlaySounds(isOn) }
                                    }
                                )
                                ItemListSeparator()
                                ItemListToggleRow(
                                    title: this.text("Notifications.InAppNotificationsVibrate", "In-App Vibrate"),
                                    isOn: this.inAppVibrate,
                                    onChange: { isOn: Bool =>
                                        this.inAppVibrate = isOn
                                        let _ = spawn { getTelegramCoreSettingsService().saveInAppVibrate(isOn) }
                                    }
                                )
                                ItemListSeparator()
                                ItemListToggleRow(
                                    title: this.text("Notifications.InAppNotificationsPreview", "In-App Preview"),
                                    isOn: this.inAppPreview,
                                    onChange: { isOn: Bool =>
                                        this.inAppPreview = isOn
                                        let _ = spawn { getTelegramCoreSettingsService().saveInAppDisplayPreviews(isOn) }
                                    }
                                )
                            }
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(12)
                            .margin(left: 16, right: 16)

                            // ── LOCK SCREEN ──（diag-suite_settings_notifications-
                            // TC-0439-round3.md FIX-A：源侧 :610 displayNamesOnLockscreen 前
                            // 无 header entry，本段是「卡 + footer」形态，不带分区大写标题，
                            // 紧跟 IN-APP NOTIFICATIONS 之后、BADGE COUNTER 之前（对位源侧段序
                            // :604→:610→:613）。行内 subtitle 删除，改独立 footer，footer 内
                            // "iOS Settings" 段是可点 Span，onClick 走与条目 A 同一出口
                            // openSystemSettings()）
                            Column {
                                ItemListToggleRow(
                                    title: this.text("Notifications.DisplayNamesOnLockScreen", "Names on lock-screen"),
                                    isOn: this.lockscreenSenderName,
                                    onChange: { isOn: Bool =>
                                        this.lockscreenSenderName = isOn
                                        getTelegramCoreSettingsService().saveDisplayNameOnLockscreen(isOn)
                                    }
                                )
                            }
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(12)
                            .margin(left: 16, right: 16, top: 20)

                            ItemListSectionFooter(
                                text: this.lockScreenInfoText(),
                                linkText: this.lockScreenInfoLink(),
                                onLinkTap: { _: String => getDeviceAccessService().openSystemSettings() }
                            )

                            // ── BADGE COUNTER ──（diag-suite_settings_notifications-
                            // TC-0439-round3.md FIX-B + TC-0441-round4.md F-1..F-3 定稿：首行
                            // 复刻源侧 CounterTagSettings/PeerSummaryCounterTags 位集模型，
                            // 标题改回源侧 `Include Channels`（原 `Include Muted Chats` 是与
                            // 静音过滤语义混淆的自造开关，全仓零对位物）。
                            // services/TelegramCoreSettingsService.cj 在本 feature
                            // tasks[0].target_files[10] 内——Supervisor ab2927440 已并入并打破
                            // 跨 feature 死锁，此前这里断言该文件"无 owner、不在 allowlist"的
                            // 说明已过期，随本轮改动一并删除。`Count Unread Messages` 的行内
                            // subtitle 删除，改按开关值在两条 footer 串间切换（TC-0441 修法 2
                            // 第 2 条，用既有 badgeCountMessages 状态，纯 UI，无需新服务方法）。
                            ItemListSectionHeader(title: this.text("Notifications.Badge", "BADGE COUNTER"), topPad: 20)

                            Column {
                                ItemListToggleRow(
                                    title: this.text("Notifications.Badge.IncludeChannels", "Include Channels"),
                                    isOn: this.badgeIncludeChannels,
                                    onChange: { isOn: Bool =>
                                        this.badgeIncludeChannels = isOn
                                        getTelegramCoreSettingsService().setBadgeIncludeChannels(isOn)
                                    }
                                )
                                ItemListSeparator()
                                ItemListToggleRow(
                                    title: this.text("Notifications.Badge.CountUnreadMessages", "Count Unread Messages"),
                                    isOn: this.badgeCountMessages,
                                    onChange: { isOn: Bool =>
                                        this.badgeCountMessages = isOn
                                        getTelegramCoreSettingsService().saveBadgeCountMessages(isOn)
                                    }
                                )
                            }
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(12)
                            .margin(left: 16, right: 16)

                            // diag-suite_settings_notifications-TC-0441-round2.md 修法 1：
                            // 值级 if/else 表达式包在自定义 @Component 的具名参数位置，宏对
                            // build() 的依赖追踪只识别"调用点表达式是本组件自己的裸
                            // @State/@Publish 字段引用"这一种语法形态（dev_pattern.md D-125
                            // 根因原文）；if/else 表达式整体作为调用点表达式，本身就不是裸字段
                            // 引用，落入 D-125 已界定的"非裸字段形态"（与函数调用返回值、嵌套
                            // 字段访问同一大类），因此子组件 ItemListSectionFooter 不会随
                            // badgeCountMessages 的 live 翻转重新 build()。改为组件级 if/else
                            // （两个完整调用各分居一个分支，同 D-133 对 @r() 场景验证过的模式，
                            // 这里是首次把该模式套用到自定义组件的 String @Prop 参数）：分支切换
                            // 由父组件 build() 自身负责（父组件的重新执行不受影响，只是子组件
                            // 内部依赖追踪的问题），每次翻转都会构造一个全新的
                            // ItemListSectionFooter 实例，天然不存在"旧实例未重 build()"的问题。
                            if (this.badgeCountMessages) {
                                ItemListSectionFooter(text: this.text("Notifications.Badge.CountUnreadMessages.InfoOn", "Switch off to show the number of unread chats instead of messages."))
                            } else {
                                ItemListSectionFooter(text: this.text("Notifications.Badge.CountUnreadMessages.InfoOff", "Switch on to show the number of unread messages instead of chats."))
                            }

                            // ── NEW CONTACTS ──（diag-suite_settings_notifications-
                            // TC-0439-round3.md FIX-A/FIX-C：源侧 :620 joinedNotifications 前
                            // 无 header entry，本段紧跟 BADGE COUNTER 之后、Reset 之前（对位源侧
                            // 段序 :613→:620→:623），标题取源侧 Localizable.strings:3070
                            // NotificationSettings.ContactJoined = "New Contacts"（此前写的是
                            // key 名驼峰化 "Contact Joined Telegram"，不是任何一处源文案）。
                            // 行内 subtitle 删除，改独立 footer）
                            Column {
                                ItemListToggleRow(
                                    title: this.text("NotificationSettings.ContactJoined", "New Contacts"),
                                    isOn: this.contactJoinedNotification,
                                    onChange: { isOn: Bool =>
                                        this.contactJoinedNotification = isOn
                                        this.updateContactJoined(isOn)
                                    }
                                )
                            }
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(12)
                            .margin(left: 16, right: 16, top: 20)

                            ItemListSectionFooter(text: this.text("NotificationSettings.ContactJoinedInfo", "Receive push notifications when one of your contacts becomes available on Telegram."))

                            // ── RESET ──（TC-0443 修法 1：先弹二次确认，B6：左对齐取消
                            // centered；修法 3：footer 取源 Localizable.strings:798）
                            Column {
                                ItemListButtonRow(
                                    title: this.text("Notifications.ResetAllNotifications", "Reset All Notifications"),
                                    destructive: true,
                                    centered: false,
                                    onClick: { => this.showResetSheet = true }
                                )
                            }
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(12)
                            .clip(true)
                            .margin(left: 16, right: 16, top: 20)

                            Column {
                                ItemListSectionFooter(text: this.text("Notifications.ResetAllNotificationsHelp", "Undo all custom notification settings for all your contacts and groups."))
                            }
                            .margin(bottom: 40)
                        }
                        .padding(top: ITEM_LIST_NAVBAR_H)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(this.presentation.backgroundColor)
                    .onDidScroll({ _xDelta: Float64, _yDelta: Float64, _scrollState: ScrollState =>
                        let cur = this.contentScroller.currentOffset()
                        if (cur.isSome()) {
                            let off = cur.getOrThrow().yOffset
                            let target = itemListNavBarBackgroundAlpha255(off)
                            if (this.prevScrollOffsetVp >= 30.0 && off <= 0.0) {
                                safeAnimateTo({ => this.getUIContext() },
                                    AnimateParam(duration: 200, curve: Curve.EaseInOut),
                                    { => this.navBarAlpha255 = target })
                            } else {
                                this.navBarAlpha255 = target
                            }
                            this.prevScrollOffsetVp = off
                        }
                    })
                }

                Stack(alignContent: Alignment.TopStart) {
                    ItemListNavBarBackground(alpha255: this.navBarAlpha255)
                    Row {
                        Stack {
                            Path()
                                .width(44).height(44)
                                .commands(this.backArrowCommands())
                                .fill(Color.Transparent)
                                .stroke(0x000000)
                                .strokeWidth(2)
                                .strokeLineCap(LineCapStyle.Round)
                                .strokeLineJoin(LineJoinStyle.Round)
                        }
                        .width(44).height(44)
                        .borderRadius(22)
                        .backgroundColor(this.presentation.cardColor)
                        .alignContent(Alignment.Center)
                        .onClick({ _ => routerPop() })
                        Blank().layoutWeight(1)
                        Text(this.text("Notifications.Title", "Notifications"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(this.presentation.textColor)
                        Blank().layoutWeight(1)
                        Row { }.width(44)
                    }
                    .width(100.percent)
                    .height(ITEM_LIST_NAVBAR_H)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                }
                .width(100.percent)
                .height(ITEM_LIST_NAVBAR_H)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(this.presentation.backgroundColor)
            .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
            .onAppear({ => this.ensureLoaded() })

            // TC-0443 修法 1/2：两组式底部弹层，复用仓内既有 DebugActionSheet
            // （pages/DebugPageArguments.cj，同包 ohos_app_cangjie_entry.pages，已被
            // Send*/Clear Database/Accounts Login 三个非 Debug 专属族复用），不新造/不
            // fork 拷贝。取消/遮罩关闭路径不触碰任何设置值。
            if (this.showResetSheet) {
                DebugActionSheet(
                    message: "Are you sure you want to reset all notification settings to default?",
                    group1: this.resetSheetGroup1(),
                    group2: this.resetSheetGroup2(),
                    onDismiss: { => this.showResetSheet = false }
                )
            }
        }
        .width(100.percent)
        .height(100.percent)
    }
}
