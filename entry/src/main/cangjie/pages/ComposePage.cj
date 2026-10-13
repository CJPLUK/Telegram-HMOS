package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}
import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.components.Avatar
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * New Message（iOS ComposeController / ComposeControllerNode，TelegramUI/Sources/ComposeController.swift）。
 *
 * 会话列表右上角铅笔直接打开本页（ChatListController.composePressed，CLC:4799）：
 *   标题 Compose_NewMessage「New Message」，模态呈现；导航栏下是 Common_Search 搜索框；
 *   列表顶部三个附加项（ComposeControllerNode.swift:45-51）：
 *     New Group → 建群；NewContact_Title「New Contact」→ 新建联系人表单；New Channel → 建频道；
 *   其后是联系人列表（按名字自然排序），点联系人即进入与其的私聊（openPeer）。
 * 搜索按名字 / 用户名 / 手机号过滤本地联系人。
 */
@HybridComponentEntry
@Component
public class ComposePage {
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var loaded: Bool = false
    @State var query: String = ""
    @State var contacts: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    @State var isLoading: Bool = true

    private func localized(key: String, fallback: String): String {
        return this.presentationStrings.getOr(key, fallback)
    }

    // V5 S1-05：本页加载联系人快照时的联系人变更代数（getContactsRefreshGeneration）。
    // New Contact 保存成功后 AddContactPage 调 setContactsNeedRefresh() 再 pop 回本页；
    // 本页实例仍在导航栈里、不会重新 onAppear，须在重新可见时比对代数并重拉。
    private var loadedContactsGeneration: Int64 = -1

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let _ = takePending("ComposePage")
        this.reloadContacts()
    }

    /** 重新可见时，联系人在别处被增删过（代数变化）→ 重拉列表（iOS contactPeersView 订阅的等价物） */
    private func reloadContactsIfStale(): Unit {
        if (!this.loaded) { return }
        if (getContactsRefreshGeneration() == this.loadedContactsGeneration) { return }
        this.reloadContacts()
    }

    private func reloadContacts(): Unit {
        this.loadedContactsGeneration = getContactsRefreshGeneration()
        let _ = spawn {
            var list = ArrayList<ContactDisplayData>()
            try {
                list = getRealContactService().getContacts()
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ComposePage] load contacts failed: ${e}")
            }
            let sorted = ArrayList<ContactDisplayData>()
            for (c in list) {
                if (!c.isSelf && c.userId > 0) { sorted.add(c) }
            }
            sorted.sortBy(stable: true, comparator: { a: ContactDisplayData, b: ContactDisplayData =>
                a.getDisplayName().toAsciiLower().compare(b.getDisplayName().toAsciiLower())
            })
            let ids = ArrayList<Int64>()
            for (c in sorted) { ids.add(c.userId) }
            if (!ids.isEmpty()) { getUserPhotoService().requestFullPhotosForUsers(ids) }
            launch {
                this.contacts = sorted
                this.isLoading = false
            }
        }
    }

    private func matches(c: ContactDisplayData): Bool {
        if (this.query.isEmpty()) { return true }
        let needle = this.query.toAsciiLower()
        if (c.getDisplayName().toAsciiLower().contains(needle)) { return true }
        if (c.username.size > 0 && c.username.toAsciiLower().contains(needle)) { return true }
        if (c.phone.size > 0 && c.phone.contains(needle)) { return true }
        return false
    }

    private func filteredContacts(): ArrayList<ContactDisplayData> {
        let result = ArrayList<ContactDisplayData>()
        for (c in this.contacts) {
            if (this.matches(c)) { result.add(c) }
        }
        return result
    }

    private func openPeer(c: ContactDisplayData): Unit {
        setSelectedChat(c.userId, c.getDisplayName(), "user")
        setSelectedChatDraft("")
        setSelectedChatUsername(c.username)
        routerReplaceTop("ChatRoomPage", c.getDisplayName())
    }

    private func sectionLetter(c: ContactDisplayData): String {
        let name = c.getDisplayName()
        if (name.isEmpty()) { return "#" }
        let first = name.toRuneArray()[0].toString().toAsciiUpper()
        let r = first.toRuneArray()[0]
        if (r >= r'A' && r <= r'Z') { return first }
        return "#"
    }

    private func showsHeader(index: Int64, list: ArrayList<ContactDisplayData>): Bool {
        if (!this.query.isEmpty()) { return false }
        if (index == 0) { return true }
        return this.sectionLetter(list[index]) != this.sectionLetter(list[index - 1])
    }

    public func build() {
        Column {
            // 导航栏：关闭 / New Message
            Row {
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.nav_ic_close)).width(22).height(22).fillColor(this.presentation.textColor)
                }
                .width(44).height(44).borderRadius(22).backgroundColor(this.presentation.cardColor)
                .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(this.localized("Compose_NewMessage", "New Message"))
                    .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Row { }.width(44).height(44)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .alignItems(VerticalAlign.Center)
            .backgroundColor(this.presentation.navBarColor)

            TextInput(text: this.query, placeholder: this.localized("Common_Search", "Search"))
                .onChange({ value: String => this.query = value })
                .height(36)
                .fontSize(17)
                .backgroundColor(this.presentation.backgroundColor)
                .borderRadius(10)
                .padding(left: 12, right: 12)
                .margin(left: 16, right: 16, top: 4, bottom: 8)

            List {
                if (this.query.isEmpty()) {
                    ListItem {
                        Row {
                            Image(@r(app.media.clist_ic_newgroup)).width(24).height(24).fillColor(this.presentation.accentColor)
                                .margin(left: 8, right: 24)
                            Text(this.localized("Compose_NewGroup", "New Group"))
                                .fontSize(17).fontColor(this.presentation.accentColor)
                        }
                        .width(100.percent).height(50).padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => routerPush("CreateGroupPage", "") })
                    }
                    ListItem {
                        Row {
                            Image(@r(app.media.clist_ic_newcontact)).width(24).height(24).fillColor(this.presentation.accentColor)
                                .margin(left: 8, right: 24)
                            Text(this.localized("NewContact_Title", "New Contact"))
                                .fontSize(17).fontColor(this.presentation.accentColor)
                        }
                        .width(100.percent).height(50).padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => routerPush("AddContactPage", "new") })
                    }
                    ListItem {
                        Row {
                            Image(@r(app.media.clist_ic_newchannel)).width(24).height(24).fillColor(this.presentation.accentColor)
                                .margin(left: 8, right: 24)
                            Text(this.localized("Compose_NewChannel", "New Channel"))
                                .fontSize(17).fontColor(this.presentation.accentColor)
                        }
                        .width(100.percent).height(50).padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => routerPush("CreateChannelPage", "") })
                    }
                }
                ForEach(this.filteredContacts(), itemGeneratorFunc: { c: ContactDisplayData, idx: Int64 =>
                    ListItem {
                        Column {
                            if (this.showsHeader(idx, this.filteredContacts())) {
                                Text(this.sectionLetter(c))
                                    .fontSize(13)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(this.presentation.secondaryTextColor)
                                    .width(100.percent)
                                    .height(28)
                                    .padding(left: 16)
                                    .backgroundColor(this.presentation.backgroundColor)
                            }
                            Row {
                                Avatar(
                                    avatarUrl: getUserPhotoService().getUserPhotoPath(c.userId),
                                    displayName: c.getDisplayName(),
                                    avatarSize: 40,
                                    peerId: c.userId
                                )
                                Column {
                                    Text(c.getDisplayName())
                                        .fontSize(17).fontColor(this.presentation.textColor)
                                        .maxLines(1).textOverflow(TextOverflow.Ellipsis)
                                    Text(c.getLastSeenText())
                                        .fontSize(14)
                                        .fontColor(if (c.isOnline) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                                        .maxLines(1)
                                }
                                .layoutWeight(1)
                                .alignItems(HorizontalAlign.Start)
                                .margin(left: 12)
                            }
                            .width(100.percent).height(56).padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                        }
                        .width(100.percent)
                        .onClick({ _ => this.openPeer(c) })
                    }
                }, keyGeneratorFunc: { c: ContactDisplayData, idx: Int64 => "${c.userId}_${idx}_${this.query}" })
                ListItem { Row { }.height(24) }
            }
            .width(100.percent)
            .layoutWeight(1)
            .backgroundColor(this.presentation.cardColor)
            .divider(ListDividerOptions(strokeWidth: 1, color: this.presentation.dividerColor, startMargin: 68, endMargin: 0))
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.cardColor)
        .padding(bottom: getSafeAreaBottom())
        // V5 S1-05：从 AddContactPage（New Contact）pop 回来时页面重新可见（同 LocationPage
        // P2-181 的返回检测写法），若联系人代数变化则重拉，保存后新联系人立即出现在列表里。
        .onVisibleAreaChange([0.0, 1.0], { isVisible: Bool, ratio: Float64 =>
            if (isVisible && ratio > 0.9) { this.reloadContactsIfStale() }
        })
        .onAppear({ => this.ensureLoaded() })
    }
}
