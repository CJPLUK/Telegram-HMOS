package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings, PresentationSnapshot, currentPresentation}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.ArkData.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getGlobalAbilityContext
import ohos_app_cangjie_entry.services.{getTelegramCoreAccountManagerService, MultiAccountEntry, getUserPhotoService}
import ohos_app_cangjie_entry.components.{ItemListSectionHeader, ItemListSectionFooter, ItemListToggleRow, ItemListDisclosureRow, ItemListButtonRow, ItemListSeparator, Avatar}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * diag-suite_settings_data_storage-round3-data_storage_root-batch.md §F-A 改动 2 —
 * `intentsSettingsController(context:)` 目的屏，此前不存在（`Share Sheet` 行 round1/
 * round2 两轮主动延期，本轮建屏 + 建路由 + 建行一次性同批落地，理由见诊断报告
 * §F-A.3「只加行不建屏 = 不可接受」+ §F-A.4「D4.8 豁免」）。
 * 源：`IntentsSettingsController.swift`（`account`/`chats`/`suggest`/`reset` 四分节）。
 *
 * ── 判定边界（诊断报告「修法方向 §F-A」明示，Worker 不需要自己判断）──
 * `TC-0418` 只要求行存在、形态对、能跳到该屏；到达 + 双向返回 + 滚动位置保留归
 * `TC-0421` D1；屏内元素的逐条对照不在本批次任何 case 的判定面内，按源侧四分节忠实
 * 移植即可。
 *
 * ── `account` 分节本页不渲染 ──
 * 源侧只在 `accounts.count > 1` 时才 append account 分节（多账号选择器）。本工程是
 * 单账号客户端（全仓无多账号切换 UI/AccountsService），恒不满足该条件——省略该分节
 * 与源侧同一逻辑门在单账号场景下的渲染结果逐字节一致，不是裁剪。
 *
 * ── 持久化 ──
 * `services/SettingsService.cj` 之外没有专用 IntentsSettings 服务文件被派给本 feature
 * （本页也不需要跨 feature 数据——`IntentsSettings` 本就是纯本地 UI 偏好，源侧也只存在
 * `ApplicationSpecificSharedDataKeys`，不触达网络）。持久化直接落本页自己的 Preferences
 * store `telegram_intents_settings`（`pages/AutoNightSettingsPage.cj` 已有的"页面自持久化"
 * 先例），默认值逐字段照抄 `IntentsSettings.swift.defaultSettings`：
 * `contacts=true, privateChats=false, savedMessages=true, groups=false, onlyShared=false`。
 *
 * ── `Reset All Share Suggestions` ──
 * 源侧 `resetAll()` 做两件事：`deleteAllSendMessageIntents()`（删除 iOS Siri/Share Sheet
 * 建议索引——鸿蒙无对应能力，平台差异，不是本文件缺陷）+ 隐式地让 4 个开关与
 * `initiallyReset` 标记回落默认（`IntentsSettings.defaultSettings` 会在下次读取时生效）。
 * 本页复刻可迁移的一半：把 4 个开关 + `onlyShared` 重置为 `IntentsSettings.defaultSettings`
 * 并持久化；iOS 专有的系统级建议索引清除没有对应写法，不伪造。
 */
@HybridComponentEntry
@Component
public class IntentsSettingsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var contactsOn: Bool = true
    @State var savedMessagesOn: Bool = true
    @State var privateChatsOn: Bool = false
    @State var groupsOn: Bool = false
    @State var onlyShared: Bool = false
    @State var accounts: Array<MultiAccountEntry> = Array<MultiAccountEntry>()
    @State var selectedAccountUserId: Int64 = -1
    @State var loaded: Bool = false

    private func storeName(): String { "telegram_intents_settings" }

    private func loadBool(key: String, defaultOn: Bool): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, this.storeName())
                    let defaultInt: Int64 = if (defaultOn) { 1 } else { 0 }
                    match (prefs.get(key, PreferencesValueType.Integer(defaultInt))) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return defaultOn
                    }
                } catch (_e: Exception) {
                    return defaultOn
                }
            case None => return defaultOn
        }
    }

    private func persistBool(key: String, value: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, this.storeName())
                    let n: Int64 = if (value) { 1 } else { 0 }
                    prefs.put(key, PreferencesValueType.Integer(n))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    private func loadSettings(): Unit {
        this.contactsOn = this.loadBool("intents_contacts", true)
        this.savedMessagesOn = this.loadBool("intents_saved_messages", true)
        this.privateChatsOn = this.loadBool("intents_private_chats", false)
        this.groupsOn = this.loadBool("intents_groups", false)
        this.onlyShared = this.loadBool("intents_only_shared", false)
        let accountService = getTelegramCoreAccountManagerService()
        let loadedAccounts = accountService.getLoggedInAccounts()
        let activeAccountUserId = accountService.getActiveAccountUserId()
        // Source renders activeAccountsAndPeers in AccountManager record order; it does not
        // move the currently active account to the first row.
        this.accounts = loadedAccounts
        this.selectedAccountUserId = activeAccountUserId
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, this.storeName())
                    match (prefs.get("intents_account", PreferencesValueType.Integer(this.selectedAccountUserId))) {
                        case PreferencesValueType.Integer(n) => this.selectedAccountUserId = n
                        case _ => ()
                    }
                } catch (_e: Exception) {}
            case None => ()
        }
        Hilog.info(0, "CjTelegram", "[IntentsSettings] loaded: contacts=${this.contactsOn} savedMessages=${this.savedMessagesOn} privateChats=${this.privateChatsOn} groups=${this.groupsOn} onlyShared=${this.onlyShared}")
    }

    private func accountName(account: MultiAccountEntry): String {
        let full = "${account.firstName} ${account.lastName}".trimAscii()
        if (full.size > 0) { return full }
        return account.phone
    }

    private func selectMainAccount(userId: Int64): Unit {
        this.selectedAccountUserId = userId
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, this.storeName())
                    prefs.put("intents_account", PreferencesValueType.Integer(userId))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    @Builder func accountRow(account: MultiAccountEntry): Unit {
        Row {
            Avatar(
                avatarUrl: getUserPhotoService().getUserPhotoPath(account.userId),
                displayName: this.accountName(account),
                avatarSize: 36,
                peerId: account.userId
            )
            Text(this.accountName(account))
                .fontSize(17).fontColor(this.presentation.textColor).layoutWeight(1)
                .margin(left: 14)
            Image(@r(app.media.media_ic_check))
                .width(18).height(18).fillColor(this.presentation.accentColor)
                .visibility(if (account.userId == this.selectedAccountUserId) { Visibility.Visible } else { Visibility.Hidden })
        }
        .width(100.percent).height(52).padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.selectMainAccount(account.userId) })
    }

    private func toggleContacts(isOn: Bool): Unit {
        this.contactsOn = isOn
        this.persistBool("intents_contacts", isOn)
    }

    private func toggleSavedMessages(isOn: Bool): Unit {
        this.savedMessagesOn = isOn
        this.persistBool("intents_saved_messages", isOn)
    }

    private func togglePrivateChats(isOn: Bool): Unit {
        this.privateChatsOn = isOn
        this.persistBool("intents_private_chats", isOn)
    }

    private func toggleGroups(isOn: Bool): Unit {
        this.groupsOn = isOn
        this.persistBool("intents_groups", isOn)
    }

    private func selectSuggestByAll(): Unit {
        this.onlyShared = false
        this.persistBool("intents_only_shared", false)
    }

    private func selectSuggestByShared(): Unit {
        this.onlyShared = true
        this.persistBool("intents_only_shared", true)
    }

    @Builder func suggestByRow(title: String, selected: Bool, selectShared: Bool): Unit {
        Row {
            Image(@r(app.media.media_ic_check))
                .width(18).height(18).fillColor(this.presentation.accentColor)
                .visibility(if (selected) { Visibility.Visible } else { Visibility.Hidden })
                .margin(right: 16)
            Text(title).fontSize(17).fontColor(this.presentation.textColor)
        }
        .width(100.percent).height(52).padding(left: 20, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ =>
            if (selectShared) { this.selectSuggestByShared() } else { this.selectSuggestByAll() }
        })
    }

    // 源端只清除系统维护的 Share Sheet / Siri 建议索引，不改 IntentsSettings 的筛选
    // 开关。HarmonyOS 没有对应的应用级索引删除 API，因此这里保留用户配置并仅完成
    // 本地确认动作；不能把“清建议”错误映射成“重置筛选偏好”。
    private func resetAll(): Unit {
        Hilog.info(0, "CjTelegram", "[IntentsSettings] reset share suggestions confirmed; no platform suggestion index is exposed")
    }

    private func confirmResetAll(): Unit {
        let uiCtx = getUIContext()
        let resetSheet = SheetInfo(title: "Reset", action: { => this.resetAll() })
        let cancelBtn = ActionSheetButtonOptions(value: "Cancel", action: { => () })
        uiCtx.showActionSheet(ActionSheetOptions(
            title: None,
            message: None,
            confirm: cancelBtn,
            sheets: [resetSheet],
            autoCancel: true
        ))
    }

    public func build() {
        Column {
            Row {
                Row { Image(@r(app.media.callui_v2_back)).width(10).height(18).fillColor(this.presentation.accentColor) }
                    .width(44).height(44).borderRadius(22)
                    .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
                    .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(trSource("Share Sheet"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Row { }.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.navBarColor)
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    if (this.accounts.size > 1) {
                        ItemListSectionHeader(title: "MAIN ACCOUNT", topPad: 16)
                        Column {
                            ForEach(this.accounts, itemGeneratorFunc: { account: MultiAccountEntry, idx: Int64 =>
                                if (idx > 0) { ItemListSeparator(leftInset: 58) }
                                this.accountRow(account)
                            }, keyGeneratorFunc: { account: MultiAccountEntry, _idx: Int64 =>
                                "share_account_${account.userId}"
                            })
                        }
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(26)
                        .clip(true)
                        .margin(left: 16, right: 16)
                        ItemListSectionFooter(text: "Choose an account for Siri and share suggestions.")
                    }

                    // ── SUGGESTED CHATS (source IntentsSettings.SuggestedChats) ──
                    ItemListSectionHeader(title: "SUGGESTED CHATS", topPad: if (this.accounts.size > 1) { 24 } else { 16 })

                    Column {
                        ItemListToggleRow(
                            title: "Contacts",
                            isOn: this.contactsOn,
                            onChange: { isOn: Bool => this.toggleContacts(isOn) }
                        )
                        ItemListSeparator()
                        ItemListToggleRow(
                            title: "Saved Messages",
                            isOn: this.savedMessagesOn,
                            onChange: { isOn: Bool => this.toggleSavedMessages(isOn) }
                        )
                        ItemListSeparator()
                        ItemListToggleRow(
                            title: "Private Chats",
                            isOn: this.privateChatsOn,
                            onChange: { isOn: Bool => this.togglePrivateChats(isOn) }
                        )
                        ItemListSeparator()
                        ItemListToggleRow(
                            title: "Groups",
                            isOn: this.groupsOn,
                            onChange: { isOn: Bool => this.toggleGroups(isOn) }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .margin(left: 16, right: 16)

                    ItemListSectionFooter(
                        text: "Suggestions will appear in the Share Sheet and Spotlight search results. Archived chats will not be suggested."
                    )

                    // ── SUGGEST BY (source IntentsSettings.SuggestBy) — two mutually
                    // exclusive rows (checkmark on the selected one), not a Toggle: source
                    // uses ItemListCheckboxItem radio-style selection here, not a switch. ──
                    ItemListSectionHeader(title: "SUGGEST BY", topPad: 24)

                    Column {
                        this.suggestByRow("All Sent Messages", !this.onlyShared, false)
                        ItemListSeparator()
                        this.suggestByRow("Only Shared Messages", this.onlyShared, true)
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .clip(true)
                    .margin(left: 16, right: 16)

                    // ── Reset All Share Suggestions (source IntentsSettings.ResetAll) ──
                    Column {
                        ItemListButtonRow(
                            title: "Reset All Share Suggestions",
                            destructive: true,
                            centered: false,
                            onClick: { => this.confirmResetAll() }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24, bottom: 32)
                }
            }
            // I-6：同 `pages/SaveIncomingMediaPage.cj` —— `Scroll` 的通用 `align` 默认
            // `Alignment.Center`（wrapper `common/common_component.cj:642-662`），内容短于视口时
            // 内容被垂直居中，导航栏下留空带（实测 ~297px）；源侧 `ItemListController` 的
            // `ListView` 短内容永远顶对齐。写在 `Scroll` 自身链上，不是内部 `Column` 上。
            .align(Alignment.Top)
            .layoutWeight(1)
            .backgroundColor(this.presentation.backgroundColor)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ =>
            if (!this.loaded) {
                this.loaded = true
                this.loadSettings()
            }
        })
    }
}
