package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getTelegramCoreSettingsService,
    getNotificationSoundSelectionService,
    getSettingsService,
    RingtoneEntry,
    getNotificationMuteSettingsService,
    PeerNotifyException
}
import ohos_app_cangjie_entry.services.JsonParser
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSectionFooter,
    ItemListSeparator,
    ItemListToggleRow,
    ItemListDisclosureRow,
    ItemListButtonRow
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.subscribe
import std.collection.ArrayList
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * NotificationsPeerCategoryPage — 通知分类子屏（Alert / OPTIONS / EXCEPTIONS）
 *
 * 对位 iOS `NotificationsPeerCategoryController.swift:602+`
 * （`notificationsPeerCategoryController(context:category:mode:updatedMode:focusOnItemTag:)`）。
 * diag-suite_settings_notifications-TC-0445.md / TC-0446.md F-A1a：根屏三个分类行
 * （Private Chats/Group Chats/Channels）此前直接做成开关，点标题不产生导航——本页补回
 * 缺失的中间一级导航层，三个分类共用同一页面实例形状，仅 `category` 入参不同
 * （对位源侧同一 controller 带 `category` 参数）。
 *
 * 分区：
 *  - Alert 开关（接管根屏原来承担的"开/关该分类通知"能力，根屏改为只读 label）；
 *  - OPTIONS（Preview 开关 + Sound disclosure 行，Alert 关闭时整段隐藏，对位源侧条件段）；
 *  - EXCEPTIONS（段头 + "Add an Exception" 行；例外编辑本身归 shell_peer_management，
 *    本轮只到"打开选人页"这一步，见 emitted_integration_contracts[]）。
 *
 * `ic_nsnd_category_page_wiring`（target_architecture.json，source
 * set_notification_sound_selection）：Sound 行用
 * `NotificationSoundSelectionService.getCategorySound(category)` 取当前值渲染右侧
 * label；onClick 时 `routerPush("NotificationSoundSelectionPage", {category,
 * currentSoundId, currentAccessHash, defaultSoundId:null})`（`defaultSoundId` 在此 N1
 * 路径恒为 null，对位源 `NotificationsPeerCategoryController.swift:870
 * defaultSound: nil`）；返回时经 `.ets` 壳 `onShown` → `dispatchEvent` →
 * 本页 `subscribe(shownEvent, ...)` 刷新该行（同 `SelectivePrivacySettingsPage.cj`
 * 既有 TC-0132 RC-7 先例）。
 */
@HybridComponentEntry
@Component
public class NotificationsPeerCategoryPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // peerType 取值同既有约定："users" | "chats" | "broadcasts"（NotificationSettingsPage.cj /
    // SettingsService.updateGlobalNotifySettings 已用的同一套字符串），root 屏传入。
    // diag-suite_settings_notifications-TC-0440.md 修法 2（并入 TC-0439 修法 1 的 5 行
    // disclosure 结构）：追加 "stories" / "reactions" 两个分类，均复用本页而不新建页面文件
    // （allowlist 不含新增页）。
    //
    // D-185 + TC-0445：源侧 `stories` 与 private/group/channel 同走
    // `notificationsPeerCategoryController`。stories 首段是 NOTIFY ME ABOUT... /
    // New Stories / 条件 Important Stories，数据源是 privateChats.storySettings
    //（getGlobalNotifySettings("users") 的 storyMute + hideSender），不再走 reactions。
    //
    // `reactions` 源侧走完全独立的 `reactionNotificationSettingsController`——双三态
    // Messages/Stories 开关 + 自己的 Sound 行（ReactionNotificationSettingsController.swift:
    // 20-110），UI 结构与 peer 分类毫无重叠，正确修复需要独立页面
    // `pages/ReactionNotificationSettingsPage.cj`（不在本 feature allowlist 内——已作为
    // target_files 扩展请求写入 featureX.md Hand-off）。本轮继续把 `reactions` 路由到本页
    // （Alert 借用 messagesNotifyFromAll、无 Sound/Exceptions）**仅作为无独立页面前的临时占位
    // 呈现，不是声明它架构等价**——已在 featureX.md 已知限制/Hand-off 显式披露该差距，不再
    // 静默简化。
    @State var category: String = "users"
    @State var categoryTitle: String = "Private Chats"

    @State var alertEnabled: Bool = true
    @State var previewsEnabled: Bool = true
    @State var silent: Bool = false
    @State var muteUntil: Int32 = 0

    // stories：读 privateChats.storySettings（users 全局块），不是 reactions。
    // Mute 0=default / 1=unmuted / 2=muted；HideSender 0=default / 1=hide / 2=show。
    // 开关布尔是裸 @State，供 ItemListToggleRow.@Prop isOn（D-125）。
    @State var storyMute: Int32 = 0
    @State var hideSender: Int32 = 0
    @State var privateChatsEnabled: Bool = true
    @State var newStoriesOn: Bool = false
    @State var importantStoriesOn: Bool = true
    @State var showSenderNameOn: Bool = true

    // reactions 分类专用：账号级 reactions 通知设置的另一半布尔量（setReactionsNotifySettings
    // 需要同时提交 messagesFromAll 与 storiesFromAll，本页每次只呈现其中一个，另一个需要缓存）。
    @State var reactionsMessagesFromAll: Bool = true
    @State var reactionsStoriesFromAll: Bool = true
    // S7-56: iOS ReactionNotificationSettingsController sources (0 nobody, 1 contacts, 2 everyone)
    // and "Show Sender's Name" (hideSender != .hide ↔ show_previews).
    @State var reactionsMessagesSource: Int32 = 0
    @State var reactionsRemount: Bool = false
    @State var reactionsStoriesSource: Int32 = 0

    // F-A1c：分类铃声，来自 NotificationSoundSelectionService（set_notification_sound_selection
    // 已交付，本 feature 只读写既有公开 API，不重复实现）。
    @State var soundId: Int64 = 0
    @State var soundAccessHash: Int64 = 0
    @State var soundLabel: String = ""
    @State var cloudRingtones: ArrayList<RingtoneEntry> = ArrayList<RingtoneEntry>()
    // 回合前恢复 main 能力（S-2）：逐对端通知例外的「查看 + 删除」。服务层早已就绪
    // （NotificationMuteSettingsService.getExceptionList:180 / removeException:240），
    // 此前全仓零 UI 调用方、已成死代码，屏上只有一个 "Add an Exception" 按钮。
    // 对位 origin/main:NotificationSettingsPage.cj:110 loadExceptions / :123 removeExceptionById
    // / :510 buildExceptionRow。放在本页而非根屏——源侧 exceptions 就住在 peer category 屏。
    @State var notifyExceptions: ArrayList<PeerNotifyException> = ArrayList<PeerNotifyException>()

    @State var isLoading: Bool = true
    @State var loaded: Bool = false

    // TC-0132 RC-7 同款事件名约定：字面量须与 ets/pages/NotificationsPeerCategoryPage.ets
    // 内 dispatchEvent(...) 的字符串逐字一致（interop.cj 不在本 feature target_files 内，
    // 不新增共享常量，两侧各自持有同一字面量）。
    private let shownEvent: String = "settings.notificationsPeerCategoryPage.shown"

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("NotificationsPeerCategoryPage")
        if (raw.size > 0 && raw != "{}") {
            let obj = JsonParser.parseObject(raw)
            if (obj.has("category")) {
                this.category = obj.getString("category")
            }
        }
        this.categoryTitle = this.titleForCategory(this.category)
        this.loadAndSync()
        subscribe(this.shownEvent, { _payload: String => this.refresh() })
    }

    private func titleForCategory(cat: String): String {
        if (cat == "chats") { return "Group Chats" }
        if (cat == "broadcasts") { return "Channels" }
        if (cat == "stories") { return "Stories" }
        if (cat == "reactions") { return "Reactions" }
        return "Private Chats"
    }

    // 三个真正的 per-peer 分类：走 TelegramCoreSettingsService.getGlobalNotifySettings/
    // updateGlobalNotifySettings（服务端 InputPeerNotifySettings，有 mute/silent/sound/例外）。
    // stories 走 users 块的 storySettings（loadStoriesAndSync / updateNewStories）。
    // reactions 仍走账号级 getReactionsNotifySettings/setReactionsNotifySettings。
    private func isPeerCategory(): Bool {
        return this.category == "users" || this.category == "chats" || this.category == "broadcasts"
    }

    private func isStoriesCategory(): Bool {
        return this.category == "stories"
    }

    // D-185 返修：Sound 行 + EXCEPTIONS 段的渲染开关。peer 三分类 + stories 都有真实的
    // Sound/Exceptions（源侧同走 notificationsPeerCategoryController）；reactions 走完全独立
    // 的 controller，无这两段——故不能直接复用 isPeerCategory()。Sound 值的读写走
    // NotificationSoundSelectionService.getCategorySound/commitSelection，纯本地 Preferences、
    // 按 category 字符串做键，对 "stories" 与 "users"/"chats"/"broadcasts" 一视同仁通用，
    // 不受任何无 owner 文件阻塞。
    private func hasSoundAndExceptions(): Bool {
        return this.isPeerCategory() || this.category == "stories"
    }

    // 从 NotificationSoundSelectionPage pop 回本页时经 onShown → dispatchEvent → subscribe
    // 触发（对位源侧 `updatedMode` 回调等价物），重新拉真值刷新 Sound 行。
    private func loadNotifyExceptions(): Unit {
        let _ = spawn {
            let list = getNotificationMuteSettingsService().getExceptionList()
            spawn(UIThread) { => this.notifyExceptions = list }
        }
    }

    private func removeNotifyException(peerId: Int64): Unit {
        let _ = spawn {
            getNotificationMuteSettingsService().removeException(peerId)
            let list = getNotificationMuteSettingsService().getExceptionList()
            spawn(UIThread) { => this.notifyExceptions = list }
        }
    }

    private func notifyMuteLabel(muteUntil: Int32): String {
        if (muteUntil <= 0) { return "Unmuted" }
        if (muteUntil == 2147483647) { return "Muted" }
        return "Muted until ${muteUntil}"
    }

    @Builder
    func buildNotifyExceptionRow(exc: PeerNotifyException) {
        Row {
            Column {
                Text(exc.peerName)
                    .fontSize(17)
                    .fontColor(0x000000)
                Text(this.notifyMuteLabel(exc.muteUntil))
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(top: 2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text(trSource("Remove"))
                .fontSize(14)
                .fontColor(0xFF3B30)
                .onClick({ _ => this.removeNotifyException(exc.peerId) })
        }
        .width(100.percent)
        .height(64)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
    }

    private func refresh(): Unit {
        this.loadAndSync()
    }

    private func computeSoundLabel(): String {
        if (this.soundId == -1) { return "None" }
        if (this.soundId == 0) { return "Default" }
        for (entry in this.cloudRingtones) {
            if (entry.id == this.soundId) {
                if (entry.title.size > 0) { return entry.title }
                return "Sound ${entry.id}"
            }
        }
        // 未就绪（列表尚未加载完/未命中）时留空，不自造 "Loading..."（F-A1a 明确禁止）。
        return ""
    }

    private func loadAndSync(): Unit {
        let cat = this.category
        if (this.isStoriesCategory()) {
            let _ = spawn {
                let coreSvc = getTelegramCoreSettingsService()
                let data = coreSvc.getGlobalNotifySettings("users")
                let soundSvc = getNotificationSoundSelectionService()
                let (sId, sHash) = soundSvc.getCategorySound(cat)
                let (ringtones, _hash) = soundSvc.getSavedRingtones(0)
                let mute = data.storyMute
                let hide = data.hideSender
                let chatsOn = !data.isMuted
                let newOn = mute == 1
                let importantOn = mute != 2
                let senderOn = hide != 1
                Hilog.info(0, "CjTelegram", "[NSND] NotificationsPeerCategoryPage loaded stories storyMute=${mute} hideSender=${hide} privateChatsEnabled=${chatsOn}")
                launch {
                    this.storyMute = mute
                    this.hideSender = hide
                    this.privateChatsEnabled = chatsOn
                    this.newStoriesOn = newOn
                    this.importantStoriesOn = importantOn
                    this.showSenderNameOn = senderOn
                    this.muteUntil = data.muteUntil
                    this.previewsEnabled = data.showPreviews
                    this.silent = data.silent
                    this.soundId = sId
                    this.soundAccessHash = sHash
                    this.cloudRingtones = ringtones
                    this.soundLabel = this.computeSoundLabel()
                    this.isLoading = false
                }
            }
            return
        }
        if (!this.isPeerCategory()) {
            // reactions：Alert/Preview 走账号级 reactions 设置（无 per-peer mute/silent）。
            let _ = spawn {
                let coreSvc = getTelegramCoreSettingsService()
                let reactData = coreSvc.getReactionsNotifySettings()
                let alertVal = reactData.messagesNotifyFromAll
                let soundSvc = getNotificationSoundSelectionService()
                let (sId, sHash) = soundSvc.getCategorySound(cat)
                let (ringtones, _hash) = soundSvc.getSavedRingtones(0)
                Hilog.info(0, "CjTelegram", "[NSND] NotificationsPeerCategoryPage loaded category=${cat} alert=${alertVal}")
                launch {
                    this.alertEnabled = alertVal
                    this.previewsEnabled = reactData.showPreviews
                    this.reactionsMessagesFromAll = reactData.messagesNotifyFromAll
                    this.reactionsStoriesFromAll = reactData.storiesNotifyFromAll
                    this.reactionsMessagesSource = reactData.messagesSource()
                    this.reactionsStoriesSource = reactData.storiesSource()
                    this.soundId = sId
                    this.soundAccessHash = sHash
                    this.cloudRingtones = ringtones
                    this.soundLabel = this.computeSoundLabel()
                    this.reactionsRemount = !this.reactionsRemount
                    this.isLoading = false
                }
            }
            return
        }
        let _ = spawn {
            let coreSvc = getTelegramCoreSettingsService()
            let data = coreSvc.getGlobalNotifySettings(cat)
            let soundSvc = getNotificationSoundSelectionService()
            let (sId, sHash) = soundSvc.getCategorySound(cat)
            let (ringtones, _hash) = soundSvc.getSavedRingtones(0)

            Hilog.info(0, "CjTelegram", "[NSND] NotificationsPeerCategoryPage loaded category=${cat} alert=${!data.isMuted} soundId=${sId}")

            launch {
                this.alertEnabled = !data.isMuted
                this.previewsEnabled = data.showPreviews
                this.silent = data.silent
                this.muteUntil = data.muteUntil
                this.soundId = sId
                this.soundAccessHash = sHash
                this.cloudRingtones = ringtones
                this.soundLabel = this.computeSoundLabel()
                this.isLoading = false
            }

            // ic_nsnd_settings_service_sound_param（target_architecture.json）：把已提交的
            // 分类铃声一并透传给账号级 notify settings，对位源侧 openSound completion 回写
            // `settings.<category>.sound` 后的 `apiInputPeerNotifySettings` 上传
            // （ManagedGlobalNotificationSettings.swift:320-336）。下游两跳（
            // TelegramCoreSettingsService.cj 无 owner、TLMethods.cj 的 flags.3 序列化归
            // net_telegram_api）都不在本 feature allowlist，已分别按
            // ic_nsnd_settings_service_sound_param / ic_nsnd_tl_sound_flag 上报；这里先把
            // 本 feature 允许范围内能接的调用点接好，链路补齐后无需再改本文件。
            let _ = getSettingsService().updateGlobalNotifySettings(cat, data.muteUntil, data.showPreviews, data.silent, sId)
        }
    }

    private func writeUsersStorySettings(nextMute: Int32, nextHide: Int32, revert: () -> Unit): Unit {
        let capturedMuteUntil = this.muteUntil
        let capturedPreviews = this.previewsEnabled
        let capturedSilent = this.silent
        let _ = spawn {
            let ok = getTelegramCoreSettingsService().updateUsersStorySettings(
                capturedMuteUntil,
                capturedPreviews,
                capturedSilent,
                nextMute,
                nextHide
            )
            if (!ok) {
                launch { revert() }
            }
        }
    }

    private func updateNewStories(enabled: Bool): Unit {
        let nextMute: Int32 = if (enabled) { 1 } else { 0 }
        let capturedHide = this.hideSender
        this.storyMute = nextMute
        this.importantStoriesOn = nextMute != 2
        this.writeUsersStorySettings(nextMute, capturedHide, { =>
            this.newStoriesOn = !enabled
            this.storyMute = if (enabled) { 0 } else { 1 }
            this.importantStoriesOn = this.storyMute != 2
        })
    }

    private func updateImportantStories(enabled: Bool): Unit {
        let nextMute: Int32 = if (enabled) { 0 } else { 2 }
        let capturedHide = this.hideSender
        this.storyMute = nextMute
        this.newStoriesOn = false
        this.writeUsersStorySettings(nextMute, capturedHide, { =>
            this.importantStoriesOn = !enabled
            this.storyMute = if (enabled) { 2 } else { 0 }
        })
    }

    private func updateShowSenderName(value: Bool): Unit {
        let nextHide: Int32 = if (value) { 2 } else { 1 }
        let capturedMute = this.storyMute
        this.hideSender = nextHide
        this.writeUsersStorySettings(capturedMute, nextHide, { =>
            this.showSenderNameOn = !value
            this.hideSender = if (value) { 1 } else { 2 }
        })
    }

    private func isReactionsCategory(): Bool {
        return this.category == "reactions"
    }

    private func reactionSourceSubtitle(source: Int32): String {
        if (source == 1) { return trSource("From My Contacts") }
        if (source == 2) { return trSource("From Everyone") }
        return ""
    }

    /** Commit both sources + show-sender together; revert the UI on failure. */
    private func commitReactionSources(messages: Int32, stories: Int32, showPreviews: Bool): Unit {
        let prevMessages = this.reactionsMessagesSource
        let prevStories = this.reactionsStoriesSource
        let prevPreviews = this.previewsEnabled
        this.reactionsMessagesSource = messages
        this.reactionsStoriesSource = stories
        this.previewsEnabled = showPreviews
        let _ = spawn {
            let ok = getTelegramCoreSettingsService().setReactionsNotifySources(messages, stories, showPreviews)
            if (!ok) {
                launch {
                    this.reactionsMessagesSource = prevMessages
                    this.reactionsStoriesSource = prevStories
                    this.previewsEnabled = prevPreviews
                    this.reactionsRemount = !this.reactionsRemount
                }
            }
        }
    }

    // iOS ReactionNotificationSettingsController.swift:360-380: switch on → .contacts, off → .nobody.
    private func toggleReactionSource(isMessages: Bool, on: Bool): Unit {
        let v: Int32 = if (on) { 1 } else { 0 }
        if (isMessages) {
            this.commitReactionSources(v, this.reactionsStoriesSource, this.previewsEnabled)
        } else {
            this.commitReactionSources(this.reactionsMessagesSource, v, this.previewsEnabled)
        }
    }

    // iOS openCategory (:305-335): Everyone / My Contacts sheet for an enabled source.
    private func openReactionSourceSheet(isMessages: Bool): Unit {
        let current = if (isMessages) { this.reactionsMessagesSource } else { this.reactionsStoriesSource }
        if (current == 0) { return }
        let title = if (isMessages) {
            trSource("Notify about reactions to my messages from")
        } else {
            trSource("Notify about reactions to my stories from")
        }
        let everyone = SheetInfo(title: trSource("Everyone"), action: { =>
            if (isMessages) {
                this.commitReactionSources(2, this.reactionsStoriesSource, this.previewsEnabled)
            } else {
                this.commitReactionSources(this.reactionsMessagesSource, 2, this.previewsEnabled)
            }
        })
        let contacts = SheetInfo(title: trSource("My Contacts"), action: { =>
            if (isMessages) {
                this.commitReactionSources(1, this.reactionsStoriesSource, this.previewsEnabled)
            } else {
                this.commitReactionSources(this.reactionsMessagesSource, 1, this.previewsEnabled)
            }
        })
        let cancel = ActionSheetButtonOptions(value: trSource("Cancel"), action: { => () })
        getUIContext().showActionSheet(ActionSheetOptions(title: Some(title), message: None,
            confirm: cancel, sheets: [everyone, contacts], autoCancel: true))
    }

    @Builder
    func buildReactionSourceRow(isMessages: Bool, remount: Bool) {
        Row {
            Column {
                Text(if (isMessages) { trSource("Reactions to my Messages") } else { trSource("Reactions to my Stories") })
                    .fontSize(17)
                    .fontColor(0x000000)
                if ((if (isMessages) { this.reactionsMessagesSource } else { this.reactionsStoriesSource }) != 0) {
                    Text(this.reactionSourceSubtitle(if (isMessages) { this.reactionsMessagesSource } else { this.reactionsStoriesSource }))
                        .fontSize(14)
                        .fontColor(0x317AFF)
                        .margin(top: 2)
                }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .onClick({ _ => this.openReactionSourceSheet(isMessages) })
            if (remount) {
                Toggle(ToggleType.Switch, isOn: (if (isMessages) { this.reactionsMessagesSource } else { this.reactionsStoriesSource }) != 0)
                    .selectedColor(0x34C759)
                    .onChange({ v: Bool => this.toggleReactionSource(isMessages, v) })
            } else {
                Toggle(ToggleType.Switch, isOn: (if (isMessages) { this.reactionsMessagesSource } else { this.reactionsStoriesSource }) != 0)
                    .selectedColor(0x34C759)
                    .onChange({ v: Bool => this.toggleReactionSource(isMessages, v) })
            }
        }
        .width(100.percent)
        .constraintSize(minHeight: 52)
        .padding(left: 16, right: 16, top: 8, bottom: 8)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(0xFFFFFF)
    }

    private func updateAlert(enabled: Bool): Unit {
        let cat = this.category
        if (this.isStoriesCategory()) {
            return
        }
        if (!this.isPeerCategory()) {
            let capturedPreviews = this.previewsEnabled
            let capturedMessages = this.reactionsMessagesFromAll
            let capturedStories = this.reactionsStoriesFromAll
            let newMessages = if (cat == "reactions") { enabled } else { capturedMessages }
            let newStories = if (cat == "stories") { enabled } else { capturedStories }
            let _ = spawn {
                let ok = getTelegramCoreSettingsService().setReactionsNotifySettings(newMessages, newStories, capturedPreviews)
                if (ok) {
                    launch {
                        this.reactionsMessagesFromAll = newMessages
                        this.reactionsStoriesFromAll = newStories
                    }
                } else {
                    launch { this.alertEnabled = !enabled }
                }
            }
            return
        }
        let capturedPreviews = this.previewsEnabled
        let newMuteUntil: Int32 = if (enabled) { 0 } else { 2147483647 }
        let _ = spawn {
            let ok = getTelegramCoreSettingsService().updateGlobalNotifySettings(cat, newMuteUntil, capturedPreviews, !enabled)
            if (ok) {
                launch { this.muteUntil = newMuteUntil }
            } else {
                launch { this.alertEnabled = !enabled }
            }
        }
    }

    private func updatePreviewsSetting(value: Bool): Unit {
        let cat = this.category
        if (this.isStoriesCategory()) {
            this.updateShowSenderName(value)
            return
        }
        if (!this.isPeerCategory()) {
            let capturedMessages = this.reactionsMessagesFromAll
            let capturedStories = this.reactionsStoriesFromAll
            let _ = spawn {
                let ok = getTelegramCoreSettingsService().setReactionsNotifySettings(capturedMessages, capturedStories, value)
                if (!ok) {
                    launch { this.previewsEnabled = !value }
                }
            }
            return
        }
        let capturedMute = this.muteUntil
        let capturedSilent = this.silent
        let _ = spawn {
            let ok = getTelegramCoreSettingsService().updateGlobalNotifySettings(cat, capturedMute, value, capturedSilent)
            if (!ok) {
                launch { this.previewsEnabled = !value }
            }
        }
    }

    // ic_nsnd_category_page_wiring：Sound 行带参跳转到 NotificationSoundSelectionPage。
    // defaultSoundId 在 N1（根屏 → 分类子屏 → 铃声选择）这条路径上恒为显式 JSON null
    // （对位源 `openSound:` 传 `defaultSound: nil`），使对端不渲染 "Default (X)" 行。
    private func openSoundSelection(): Unit {
        let json = "{\"category\":\"${this.category}\",\"currentSoundId\":${this.soundId},\"currentAccessHash\":${this.soundAccessHash},\"defaultSoundId\":null}"
        routerPush("NotificationSoundSelectionPage", json)
    }

    // F-A1a EXCEPTIONS 段最小可行入口：源侧选人后的例外创建/编辑
    // （makePeerSelectionController → presentPeerSettings）不在本 feature allowlist，
    // 归 shell_peer_management（已按 emitted_integration_contracts[] 上报）。本轮只把
    // "打开选人" 这一步接上，用工程既有的、可独立路由的联系人列表页。
    private func openAddException(): Unit {
        routerPush("ContactListPage")
    }

    public func build() {
        Column {
            Row {
                Row {
                    Image(@r(app.media.callui_v2_back))
                        .width(8)
                        .height(14)
                        .fillColor(0x317AFF)
                        .margin(right: 4)
                    Text(trSource("Back"))
                        .fontSize(16)
                        .fontColor(0x317AFF)
                }
                .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(this.categoryTitle)
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                Blank().layoutWeight(1)
                Row {}.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            if (this.isLoading) {
                Column {
                    LoadingProgress().width(32).height(32)
                    Text(trSource("Loading..."))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 8)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                Scroll {
                    Column {
                        if (this.isReactionsCategory()) {
                            // S7-56: iOS ReactionNotificationSettingsController entries (:224-264).
                            ItemListSectionHeader(title: trSource("NOTIFY ME ABOUT..."), topPad: 20)
                            Column {
                                this.buildReactionSourceRow(true, this.reactionsRemount)
                                ItemListSeparator()
                                this.buildReactionSourceRow(false, this.reactionsRemount)
                            }
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(12)
                            .clip(true)
                            .margin(left: 16, right: 16)

                            if (this.reactionsMessagesSource != 0 || this.reactionsStoriesSource != 0) {
                                ItemListSectionHeader(title: "OPTIONS", topPad: 20)
                                Column {
                                    ItemListToggleRow(
                                        title: trSource("Show Sender's Name"),
                                        isOn: this.previewsEnabled,
                                        onChange: { isOn: Bool =>
                                            this.commitReactionSources(this.reactionsMessagesSource, this.reactionsStoriesSource, isOn)
                                        }
                                    )
                                    ItemListSeparator()
                                    ItemListDisclosureRow(
                                        title: trSource("Sound"),
                                        value: this.soundLabel,
                                        onClick: { => this.openSoundSelection() }
                                    )
                                }
                                .backgroundColor(0xFFFFFF)
                                .borderRadius(12)
                                .clip(true)
                                .margin(left: 16, right: 16)
                            }
                        } else if (this.isStoriesCategory()) {
                            ItemListSectionHeader(title: "NOTIFY ME ABOUT...", topPad: 20)

                            Column {
                                ItemListToggleRow(
                                    title: "New Stories",
                                    isOn: this.newStoriesOn,
                                    onChange: { isOn: Bool =>
                                        this.newStoriesOn = isOn
                                        this.updateNewStories(isOn)
                                    }
                                )
                                if (this.storyMute != 1) {
                                    ItemListSeparator()
                                    ItemListToggleRow(
                                        title: "Important Stories",
                                        isOn: this.importantStoriesOn,
                                        onChange: { isOn: Bool =>
                                            this.importantStoriesOn = isOn
                                            this.updateImportantStories(isOn)
                                        }
                                    )
                                }
                            }
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(12)
                            .clip(true)
                            .margin(left: 16, right: 16)

                            if (this.storyMute != 1) {
                                ItemListSectionFooter(text: "Always on for top 5 contacts.")
                            }

                            if (this.privateChatsEnabled || this.notifyExceptions.size > 0) {
                                ItemListSectionHeader(title: "OPTIONS", topPad: 20)

                                Column {
                                    ItemListToggleRow(
                                        title: "Show Sender's Name",
                                        isOn: this.showSenderNameOn,
                                        onChange: { isOn: Bool =>
                                            this.showSenderNameOn = isOn
                                            this.updateShowSenderName(isOn)
                                        }
                                    )
                                    if (this.hasSoundAndExceptions()) {
                                        ItemListSeparator()
                                        ItemListDisclosureRow(
                                            title: "Sound",
                                            value: this.soundLabel,
                                            onClick: { => this.openSoundSelection() }
                                        )
                                    }
                                }
                                .backgroundColor(0xFFFFFF)
                                .borderRadius(12)
                                .clip(true)
                                .margin(left: 16, right: 16)
                            }
                        } else {
                            Column {
                                ItemListToggleRow(
                                    title: "Alert",
                                    isOn: this.alertEnabled,
                                    onChange: { isOn: Bool =>
                                        this.alertEnabled = isOn
                                        this.updateAlert(isOn)
                                    }
                                )
                            }
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(12)
                            .margin(left: 16, right: 16, top: 20)

                            if (this.alertEnabled) {
                                ItemListSectionHeader(title: "OPTIONS", topPad: 20)

                                Column {
                                    ItemListToggleRow(
                                        title: "Message Preview",
                                        isOn: this.previewsEnabled,
                                        onChange: { isOn: Bool =>
                                            this.previewsEnabled = isOn
                                            this.updatePreviewsSetting(isOn)
                                        }
                                    )
                                    if (this.hasSoundAndExceptions()) {
                                        ItemListSeparator()
                                        ItemListDisclosureRow(
                                            title: "Sound",
                                            value: this.soundLabel,
                                            onClick: { => this.openSoundSelection() }
                                        )
                                    }
                                }
                                .backgroundColor(0xFFFFFF)
                                .borderRadius(12)
                                .clip(true)
                                .margin(left: 16, right: 16)
                            }
                        }

                        if (this.hasSoundAndExceptions()) {
                            ItemListSectionHeader(title: "EXCEPTIONS", topPad: 20)

                            Column {
                                ForEach(this.notifyExceptions, itemGeneratorFunc: { exc: PeerNotifyException, _: Int64 =>
                                    this.buildNotifyExceptionRow(exc)
                                    ItemListSeparator(leftInset: 16)
                                })
                                ItemListButtonRow(
                                    title: "Add an Exception",
                                    centered: false,
                                    onClick: { => this.openAddException() }
                                )
                            }
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(12)
                            .clip(true)
                            .margin(left: 16, right: 16)
                        }

                        Column {}.height(40)
                    }
                }
                .layoutWeight(1)
                .backgroundColor(0xF2F2F7)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded(); this.loadNotifyExceptions() })
    }
}
