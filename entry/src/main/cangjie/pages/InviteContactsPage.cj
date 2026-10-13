package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.collection.HashMap
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.bindings.*
import ohos_app_cangjie_entry.components.SolidRoundedButton
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

private func jsonEscapeInviteContacts(s: String): String {
    var result = ""
    for (ch in s.runes()) {
        if (ch == r'"') {
            result += "\\\""
        } else if (ch == r'\\') {
            result += "\\\\"
        } else if (ch == r'\n') {
            result += "\\n"
        } else if (ch == r'\r') {
            result += "\\r"
        } else if (ch == r'\t') {
            result += "\\t"
        } else {
            result += ch.toString()
        }
    }
    return result
}

/**
 * InviteContactsPage — 邀请设备联系人页面（P2-125）
 *
 * 对应 iOS ContactListUI InviteContactsController
 * + InviteContactsControllerNode（含 MFMessageComposeViewController SMS 发送）
 *
 * 功能:
 * - 通过 HarmonyOS 系统联系人选择器读取用户主动选择的联系人（普通应用免通讯录权限）
 * - 多选联系人（checkbox 行，内联选中态圆圈）
 * - Select All / Deselect All
 * - "Send SMS Invite"：对选中联系人电话号码调用 ContactsHelperUtils.sendSmsInvite（拉起系统短信 App）
 * - "Copy Link"：复制邀请链接到剪贴板（备用路径，对应 iOS requestShareTelegram）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（.hideTitleBar 一并去掉），只留内部内容
 *  - aboutToAppear 有实逻辑（loadContacts）→ ensureLoaded()（.onAppear 触发）
 *  - pop → routerPop
 */
@HybridComponentEntry
@Component
public class InviteContactsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var systemContacts: ArrayList<SystemContactData> = ArrayList<SystemContactData>()
    @State var selectedIds: ArrayList<String> = ArrayList<String>()
    @State var isLoading: Bool = false
    @State var showCopiedToast: Bool = false
    @State var smsSentToast: Bool = false
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadContacts()
    }

    func contactId(c: SystemContactData): String {
        return c.phoneNumber + "_" + c.displayName
    }

    func isSelected(c: SystemContactData): Bool {
        let id = this.contactId(c)
        for (sid in this.selectedIds) {
            if (sid == id) { return true }
        }
        return false
    }

    func toggleSelection(c: SystemContactData) {
        let id = this.contactId(c)
        let newList = ArrayList<String>()
        var found = false
        for (sid in this.selectedIds) {
            if (sid == id) {
                found = true
            } else {
                newList.add(sid)
            }
        }
        if (!found) {
            newList.add(id)
        }
        this.selectedIds = newList
    }

    func selectAll() {
        let all = ArrayList<String>()
        for (c in this.systemContacts) {
            all.add(this.contactId(c))
        }
        this.selectedIds = all
    }

    func deselectAll() {
        this.selectedIds = ArrayList<String>()
    }

    /**
     * 收集选中联系人的电话号码
     */
    func collectSelectedPhones(): ArrayList<String> {
        let phones = ArrayList<String>()
        for (c in this.systemContacts) {
            if (this.isSelected(c) && c.phoneNumber.size > 0) {
                phones.add(c.phoneNumber)
            }
        }
        return phones
    }

    /**
     * 发送 SMS 邀请（对应 iOS InviteContactsController requestShare）
     * 拉起系统短信 App，recipients = 选中联系人电话号码
     */
    func sendSmsInvite() {
        let phones = this.collectSelectedPhones()
        if (phones.isEmpty()) { return }
        let inviteText = getInviteText()
        let utils = getContactsHelperUtils()
        utils.sendSmsInvite(phones, inviteText)
        launch {
            this.smsSentToast = true
        }
        let _ = spawn {
            sleep(Duration.second * 2)
            launch {
                this.smsSentToast = false
            }
        }
    }

    // SolidRoundedButton onClick 回调（显式 Unit 返回类型，避免宏推断问题 D-123）
    private func onSmsInviteClick(): Unit {
        this.sendSmsInvite()
    }

    /**
     * iOS requestShareTelegram 使用系统分享面板分享完整 InviteText.SingleContact。
     * 系统分享不可用时才降级复制邀请正文。
     */
    func shareTelegram() {
        let inviteText = getInviteText()
        // 人工反馈 #9：原先走 Android 式隐式 Want(ohos.want.action.SEND) 的 startAbility，
        // HarmonyOS 上没有匹配的分享面板，只能静默降级成复制。改走工程既有的真系统分享桥
        // callArkAsync(SHARE_LINK) → ShareLinkImpl.ets → @kit.ShareKit systemShare.ShareController
        // （InviteMembersSheet / ImageViewer / UsernameSettingsPage 同一条链），ok=false 才降级复制。
        let argJson = "{\"text\":\"${jsonEscapeInviteContacts(inviteText)}\",\"title\":\"Telegram\"}"
        callArkAsync(SHARE_LINK, argJson, { res =>
            let ok = res.contains("\"ok\":true")
            Hilog.info(0, "CjTelegram", "[InviteContactsPage] shareTelegram systemShare ok=${ok}")
            if (!ok) {
                setClipboardText(inviteText)
                launch { this.showCopiedToast = true }
                let _ = spawn {
                    sleep(Duration.second * 2)
                    launch { this.showCopiedToast = false }
                }
            }
        })
    }

    func loadContacts() {
        // normal APL 应用不能直接枚举系统通讯录；等待用户点击系统选择器。
        this.isLoading = false
    }

    /**
     * HarmonyOS API 10+ 系统联系人多选器。
     * 不依赖 READ_CONTACTS / WRITE_CONTACTS，只返回用户明确选择的数据。
     */
    private func pickSystemContacts(): Unit {
        this.isLoading = true
        callArkAsync(PICK_CONTACTS, "{}", { resultJson =>
            let result = JsonParser.parseObject(resultJson)
            let contacts = ArrayList<SystemContactData>()
            let selected = ArrayList<String>()
            if (result.getBool("ok") && result.getString("status") == "picked") {
                let items = result.getArray("contacts").getObjects()
                for (item in items) {
                    let phone = item.getString("phoneNumber")
                    if (phone.isEmpty()) { continue }
                    let contact = SystemContactData(
                        item.getString("displayName"),
                        item.getString("firstName"),
                        item.getString("lastName"),
                        phone
                    )
                    contacts.add(contact)
                    selected.add(this.contactId(contact))
                }
            }
            launch {
                this.systemContacts = contacts
                this.selectedIds = selected
                this.isLoading = false
            }
        })
    }

    @Builder
    func buildContactRow(c: SystemContactData) {
        ListItem {
            Row {
                Row {
                    if (this.isSelected(c)) {
                        Text("V")
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                    }
                }
                .width(24)
                .height(24)
                .borderRadius(12)
                .backgroundColor(if (this.isSelected(c)) { 0x317AFF } else { 0xE0E0E0 })
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
                .margin(right: 12)

                Column {
                    Text(c.displayName)
                        .fontSize(17)
                        .fontColor(0x000000)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                    if (c.phoneNumber.size > 0) {
                        Text(c.phoneNumber)
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .margin(top: 2)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                    }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ evt =>
                this.toggleSelection(c)
            })
        }
    }

    @Builder
    func buildShareTelegramRow() {
        ListItem {
            Row {
                Image(@r(app.media.contact_ic_addmember))
                    .width(28)
                    .height(28)
                    .fillColor(0x007AFF)
                    .margin(right: 16)
                Text(trSource("Share Telegram"))
                    .fontSize(17)
                    .fontColor(0x007AFF)
                    .layoutWeight(1)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt => this.shareTelegram() })
        }
    }

    @Builder
    func buildSelectContactsRow() {
        ListItem {
            Row {
                Image(@r(app.media.contact_ic_invite))
                    .width(28)
                    .height(28)
                    .fillColor(0x007AFF)
                    .margin(right: 16)
                Text(if (this.systemContacts.isEmpty()) { "Select Contacts" } else { "Choose Other Contacts" })
                    .fontSize(17)
                    .fontColor(0x007AFF)
                    .layoutWeight(1)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt => this.pickSystemContacts() })
        }
    }

    public func build() {
        Stack {
            Column {
                Row {
                    Text("<")
                        .fontSize(17)
                        .fontColor(0x317AFF)
                        .onClick({ evt =>
                            routerPop()
                        })

                    Blank()
                        .layoutWeight(1)

                    Text(trSource("Invite Friends"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)

                    Blank()
                        .layoutWeight(1)

                    if (this.systemContacts.size > 0) {
                        Text(if (this.selectedIds.size >= this.systemContacts.size) { "Deselect All" } else { "Select All" })
                            .fontSize(17)
                            .fontColor(0x317AFF)
                            .onClick({ evt =>
                                if (this.selectedIds.size >= this.systemContacts.size) {
                                    this.deselectAll()
                                } else {
                                    this.selectAll()
                                }
                            })
                    } else {
                        Text(trSource(""))
                            .fontSize(17)
                            .width(80)
                    }
                }
                .width(100.percent)
                .height(56.0 + getSafeAreaTop())
                .padding(left: 16, right: 16, top: getSafeAreaTop())
                .backgroundColor(0xF7F7F7)
                .alignItems(VerticalAlign.Center)

                Divider()
                    .color(0xE5E5EA)
                    .strokeWidth(0.5)

                if (this.isLoading) {
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
                } else if (this.systemContacts.isEmpty()) {
                    List {
                        // iOS 中 Share Telegram 与设备联系人是否为空无关，始终保留。
                        this.buildShareTelegramRow()
                        this.buildSelectContactsRow()
                        ListItem {
                            Column {
                                Text("Choose contacts to invite")
                                    .fontSize(16)
                                    .fontColor(0x000000)
                                Text("HarmonyOS will only share the contacts you select")
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 8)
                                    .textAlign(TextAlign.Center)
                            }
                            .width(100.percent)
                            .height(220)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                        }
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                } else {
                    List {
                        // iOS InviteContactsControllerNode 的固定第一项。
                        this.buildShareTelegramRow()
                        this.buildSelectContactsRow()

                        ForEach(this.systemContacts, itemGenerator: { c: SystemContactData, _idx: Int64 =>
                            this.buildContactRow(c)
                        })
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xE5E5EA, startMargin: 52, endMargin: 0))
                }

                Column {
                    if (this.selectedIds.size > 0) {
                        Column {
                            SolidRoundedButton(
                                title: if (this.selectedIds.size == 1) { "Invite 1 Contact" } else { "Invite ${this.selectedIds.size} Contacts" },
                                onClick: this.onSmsInviteClick,
                                loading: false,
                                enabled: true
                            )
                        }
                        .width(100.percent)
                    }
                }
                .width(100.percent)
                .padding(left: 30, right: 30, top: 8, bottom: 16)
                .backgroundColor(0xFFFFFF)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFF)
            .padding(bottom: getSafeAreaBottom())

            if (this.showCopiedToast) {
                Column {
                    Text("Invite text copied to clipboard")
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

            if (this.smsSentToast) {
                Column {
                    Text("SMS app opened")
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
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }
}
