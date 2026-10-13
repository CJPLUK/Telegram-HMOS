package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.components.SelectedPeerChip
import ohos_app_cangjie_entry.components.SearchBar
import ohos_app_cangjie_entry.router.*

/**
 * 分享控制器主页面 — 转发/分享消息到多个对话（混合工程迁移版）
 *
 * P2-349..355 分享选择器/多选/搜索/留言/群发/外部内容
 *
 * 对应 iOS ShareController.swift, ShareControllerNode.swift
 * 半屏弹出面板：已选chips + 搜索栏 + 最近对话网格 + 选中打勾 + 留言框 + 底部发送按钮
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑 → ensureLoaded()+.onAppear
 */
@HybridComponentEntry
@Component
public class ShareControllerPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 基础列表
    @State var targets: ArrayList<ShareTarget> = ArrayList<ShareTarget>()
    @State var selectedTargets: ArrayList<ShareTarget> = ArrayList<ShareTarget>()
    @State var searchText: String = ""
    @State var optionalMessage: String = ""
    @State var isLoading: Bool = true
    @State var isSending: Bool = false

    // P2-351: 远端搜索状态
    @State var isSearching: Bool = false
    @State var searchResult: ShareSearchResult = ShareSearchResult()
    @State var hasSearched: Bool = false

    // P2-353: 群发选项
    @State var silently: Bool = false
    // allowPaidStars 用于群发付费星级；UI 将来可扩展（当前默认 0）
    @State var sendProgressText: String = ""

    @State var loaded: Bool = false

    // 转发参数（从 getPendingForward 读取）
    private var fromPeerType: String = "user"
    private var fromPeerId: Int64 = 0
    private var messageIds: ArrayList<Int32> = ArrayList<Int32>()

    // P2-354/355: 外部内容参数（由 ShareReceiverService / LegacyICloudFilePage 写入 pending）
    @State var externalItems: ArrayList<NormalizedContentItem> = ArrayList<NormalizedContentItem>()
    private var hasExternalContent: Bool = false

    // S6-07：联系人名片分享参数（UserProfilePage more → Share Contact 经 setPendingShareContact 写入）
    private var shareContactPhone: String = ""
    private var shareContactFirstName: String = ""
    private var shareContactLastName: String = ""
    private var hasShareContact: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true

        let (ptype, pid, mids) = getPendingForward()
        this.fromPeerType = ptype
        this.fromPeerId = pid
        this.messageIds = mids

        // S6-07：待分享联系人优先于转发/文本（与 iOS ShareController subject 一一对应，只有一种）
        let (cPhone, cFirst, cLast) = consumePendingShareContact()
        if (cPhone.size > 0) {
            this.shareContactPhone = cPhone
            this.shareContactFirstName = cFirst
            this.shareContactLastName = cLast
            this.hasShareContact = true
            this.messageIds = ArrayList<Int32>()
        }

        // P2-354/355: 消费 pending 外部内容并经过标准化管线
        let rawItems = consumePendingExternalContent()
        if (!rawItems.isEmpty()) {
            let normalized = getExternalContentNormalizationService().normalizeItems(rawItems)
            let newItems = ArrayList<NormalizedContentItem>()
            for (item in normalized) { newItems.add(item) }
            this.externalItems = newItems
            this.hasExternalContent = true
        }

        this.loadTargets()
    }

    private func loadTargets(): Unit {
        this.isLoading = true
        let _ = spawn {
            try {
                let svc = getShareControllerService()
                let list = svc.getMergedTargetsForShare(limit: 30)
                launch {
                    this.targets = list
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ShareControllerPage] Load failed")
                launch { this.isLoading = false }
            }
        }
    }

    // P2-351: 触发远端搜索
    private func doSearch(query: String): Unit {
        if (query.size == 0) {
            this.hasSearched = false
            this.searchResult = ShareSearchResult()
            return
        }
        this.isSearching = true
        this.hasSearched = true
        let q = query
        let _ = spawn {
            try {
                let svc = getShareControllerService()
                let result = svc.searchShareTargets(q)
                launch {
                    this.searchResult = result
                    this.isSearching = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ShareControllerPage] Search failed")
                launch { this.isSearching = false }
            }
        }
    }

    private func isTargetSelected(t: ShareTarget): Bool {
        for (s in this.selectedTargets) {
            if (s.peerType == t.peerType && s.peerId == t.peerId) {
                return true
            }
        }
        return false
    }

    private func toggleSelection(t: ShareTarget): Unit {
        var found = false
        let newList = ArrayList<ShareTarget>()
        for (s in this.selectedTargets) {
            if (s.peerType == t.peerType && s.peerId == t.peerId) {
                found = true
            } else {
                newList.add(s)
            }
        }
        if (!found) {
            newList.add(t)
        }
        this.selectedTargets = newList
    }

    private func removeFromSelected(peerId: Int64): Unit {
        let newList = ArrayList<ShareTarget>()
        for (s in this.selectedTargets) {
            if (s.peerId != peerId) {
                newList.add(s)
            }
        }
        this.selectedTargets = newList
    }

    private func getFilteredTargets(): ArrayList<ShareTarget> {
        if (this.searchText.size == 0) {
            return this.targets
        }
        let q = this.searchText.toAsciiLower()
        let result = ArrayList<ShareTarget>()
        for (t in this.targets) {
            if (t.name.toAsciiLower().contains(q)) {
                result.add(t)
            }
        }
        return result
    }

    private func doSend(): Unit {
        if (this.selectedTargets.isEmpty()) { return }
        // P2-354/355: 外部内容分享优先（来自系统 share sheet 或 LegacyICloudFilePage）
        if (this.hasExternalContent && !this.externalItems.isEmpty()) {
            this.doSendExternalContent()
            return
        }
        if (this.hasShareContact) {
            this.doSendContact()
            return
        }
        if (this.messageIds.isEmpty()) {
            if (this.optionalMessage.isEmpty()) { return }
            this.doSendMessage()
        } else {
            this.doForward()
        }
    }

    /**
     * P2-354/355: 发送外部内容（来自系统分享 or 文件导入）到选中的对话
     *
     * iOS 对应：ShareController.actionButtonPressed → prepareItems → sendSharedItems
     */
    private func doSendExternalContent(): Unit {
        this.isSending = true
        this.sendProgressText = "Sending..."
        let targetsCopy = ArrayList<ShareTarget>()
        for (t in this.selectedTargets) {
            targetsCopy.add(t)
        }
        let itemsCopy = ArrayList<NormalizedContentItem>()
        for (item in this.externalItems) {
            itemsCopy.add(item)
        }
        let silentlyCopy = this.silently
        let _ = spawn {
            try {
                let svc = getShareControllerService()
                let progCb: (String, Int32, Int32) -> Unit = { peerName: String, successCount: Int32, totalCount: Int32 =>
                    let pn = peerName
                    let sc = successCount
                    let tc = totalCount
                    launch {
                        this.sendProgressText = "Sent to " + pn + " (" + sc.toString() + "/" + tc.toString() + ")"
                    }
                }
                let ok = svc.sendExternalContentToMultiPeers(
                    itemsCopy,
                    targetsCopy,
                    progCb,
                    silently: silentlyCopy
                )
                launch {
                    this.isSending = false
                    if (ok) {
                        this.externalItems = ArrayList<NormalizedContentItem>()
                        this.hasExternalContent = false
                        routerPop()
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ShareControllerPage] SendExternalContent failed")
                launch { this.isSending = false }
            }
        }
    }

    /**
     * P2-353: 群发转发 — 使用 forwardToMultiPeers（支持 silently/allowPaidStars/逐 peer 进度）
     * iOS 对应 ShareControllerNode.actionButtonPressed → forwardMessages(dropAuthor:silently:paidStars:)
     */
    private func doForward(): Unit {
        this.isSending = true
        this.sendProgressText = "Sending..."
        let targetsCopy = ArrayList<ShareTarget>()
        for (t in this.selectedTargets) {
            targetsCopy.add(t)
        }
        let idsCopy = ArrayList<Int32>()
        for (id in this.messageIds) {
            idsCopy.add(id)
        }
        let ptype = this.fromPeerType
        let pid = this.fromPeerId
        let comment = this.optionalMessage
        let silentlyCopy = this.silently
        let _ = spawn {
            try {
                let svc = getShareControllerService()
                // P2-353: 使用 forwardToMultiPeers，传入 silently/onProgress
                let progCb: (String, Int32, Int32) -> Unit = { peerName: String, successCount: Int32, totalCount: Int32 =>
                    let pn = peerName
                    let sc = successCount
                    let tc = totalCount
                    launch {
                        this.sendProgressText = "Sent to " + pn + " (" + sc.toString() + "/" + tc.toString() + ")"
                    }
                }
                let ok = svc.forwardToMultiPeers(
                    ptype,
                    pid,
                    idsCopy,
                    targetsCopy,
                    comment,
                    progCb,
                    silently: silentlyCopy
                )
                launch {
                    this.isSending = false
                    if (ok) {
                        routerPop()
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ShareControllerPage] Forward failed")
                launch { this.isSending = false }
            }
        }
    }

    private func doSendMessage(): Unit {
        this.isSending = true
        let targetsCopy = ArrayList<ShareTarget>()
        for (t in this.selectedTargets) {
            targetsCopy.add(t)
        }
        let msg = this.optionalMessage
        let silentlyCopy = this.silently
        let _ = spawn {
            try {
                let svc = getShareControllerService()
                // P2-353: 使用 sendTextToMultiPeers（支持 silently/onProgress）
                let sendProgCb: (String, Int32, Int32) -> Unit = { peerName: String, successCount: Int32, totalCount: Int32 =>
                    let pn = peerName
                    let sc = successCount
                    let tc = totalCount
                    launch {
                        this.sendProgressText = pn + " (" + sc.toString() + "/" + tc.toString() + ")"
                    }
                }
                let ok = svc.sendTextToMultiPeers(
                    msg,
                    targetsCopy,
                    sendProgCb,
                    silently: silentlyCopy
                )
                launch {
                    this.isSending = false
                    if (ok) {
                        routerPop()
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ShareControllerPage] Send failed")
                launch { this.isSending = false }
            }
        }
    }

    /**
     * S6-07：发送联系人名片到选中的对话。
     * iOS 对应 PeerInfoScreenPerformButtonAction.swift Profile_ShareContactButton →
     * ShareController(subject: .media(.standalone(media: TelegramMediaContact))) → completed 后
     * 以 UserInfo_ContactForwardTooltip_{SavedMessages,Chat}_One 提示。
     */
    private func doSendContact(): Unit {
        this.isSending = true
        this.sendProgressText = "Sending..."
        let targetsCopy = ArrayList<ShareTarget>()
        for (t in this.selectedTargets) {
            targetsCopy.add(t)
        }
        let phone = this.shareContactPhone
        let first = this.shareContactFirstName
        let last = this.shareContactLastName
        let _ = spawn {
            try {
                let svc = getShareControllerService()
                let progCb: (String, Int32, Int32) -> Unit = { peerName: String, successCount: Int32, totalCount: Int32 =>
                    let pn = peerName
                    let sc = successCount
                    let tc = totalCount
                    launch {
                        this.sendProgressText = "Sent to " + pn + " (" + sc.toString() + "/" + tc.toString() + ")"
                    }
                }
                let ok = svc.sendContactToMultiPeers(phone, first, last, targetsCopy, progCb)
                launch {
                    this.isSending = false
                    if (ok) {
                        if (targetsCopy.size == 1) {
                            let t = targetsCopy[0]
                            let targetName = if (t.peerType == "user" && t.peerId == getCurrentUserId()) { "Saved Messages" } else { t.name }
                            showToast("Contact forwarded to " + targetName)
                        } else {
                            showToast("Contact forwarded to " + targetsCopy.size.toString() + " chats")
                        }
                        routerPop()
                    } else {
                        showToast("Could not send contact")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ShareControllerPage] SendContact failed: ${e}")
                launch {
                    this.isSending = false
                    showToast("Could not send contact")
                }
            }
        }
    }

    private func sendButtonLabel(): String {
        if (this.isSending) {
            if (this.sendProgressText.size > 0) { return this.sendProgressText }
            return "Sending..."
        }
        return "Send"
    }

    private func titleLabel(): String {
        if (this.messageIds.isEmpty()) { return "Share" }
        return "Forward to..."
    }

    // P2-351: 搜索结果是否为空
    private func isSearchResultEmpty(): Bool {
        return this.searchResult.chats.isEmpty() && this.searchResult.contacts.isEmpty() && this.searchResult.global.isEmpty()
    }

    public func build() {
        Column {
            // ===== 标题栏 =====
            Row {
                Text(trSource("Cancel"))
                    .fontSize(17)
                    .fontColor(0x0088CC)
                    .onClick({ _evt =>
                        routerPop()
                    })
                Blank()
                Text(this.titleLabel())
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                Blank()
                Row {}.width(50)
            }
            .width(100.percent)
            .height(48)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)

            // ===== P2-350: 已选目标 chips 横向滚动条 =====
            if (!this.selectedTargets.isEmpty()) {
                Scroll() {
                    Row {
                        ForEach(this.selectedTargets.toArray(), itemGenerator: { t: ShareTarget, _idx: Int64 =>
                            SelectedPeerChip(
                                peerId: t.peerId,
                                displayName: t.name,
                                avatarUrl: t.avatarLocalPath,
                                avatarColor: t.avatarColor,
                                onRemove: { pid: Int64 =>
                                    this.removeFromSelected(pid)
                                }
                            )
                        })
                    }
                    .padding(left: 8, right: 8)
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width(100.percent)
                .height(88)
            }

            // ===== P2-351: 搜索栏（onChange 触发远端搜索）=====
            // P2-RETRO-search-b: 手搓 TextInput+loading Row → SearchBar 原子。
            // SearchBar 是 @Component，不能直接链内置属性，外包 Column 容器。
            // loading prop 接管 isSearching 状态，原 loading Row 不再需要。
            Column {
                SearchBar(
                    backArrow: false,
                    text: this.searchText,
                    hint: "Search contacts...",
                    onChange: { value: String =>
                        this.searchText = value
                        this.doSearch(value)
                    },
                    loading: this.isSearching
                )
            }
            .width(100.percent)
            .margin(bottom: 8)

            // ===== 列表区域 =====
            if (this.isLoading && !this.hasSearched) {
                Column {
                    Text(trSource("Loading..."))
                        .fontSize(14)
                        .fontColor(0xFF666666)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
            } else if (this.hasSearched && !this.isSearching) {
                // P2-351: 搜索结果 — 三类 token 分类显示
                if (this.isSearchResultEmpty()) {
                    // 空态
                    Column {
                        Text("No results")
                            .fontSize(15)
                            .fontColor(0xFF8E8E93)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    Scroll {
                        Column {
                            // 分类：Chats
                            if (!this.searchResult.chats.isEmpty()) {
                                Text(trSource("Chats"))
                                    .fontSize(13)
                                    .fontColor(0xFF8E8E93)
                                    .padding(left: 16, right: 16, top: 8, bottom: 4)
                                    .width(100.percent)
                                Flex(wrap: FlexWrap.Wrap) {
                                    ForEach(this.searchResult.chats.toArray(), itemGenerator: { t: ShareTarget, _idx: Int64 =>
                                        SharePageGridSectionNode(
                                            target: t,
                                            isSelected: this.isTargetSelected(t),
                                            onTap: { =>
                                                this.toggleSelection(t)
                                            }
                                        )
                                    })
                                }
                                .width(100.percent)
                            }
                            // 分类：Contacts
                            if (!this.searchResult.contacts.isEmpty()) {
                                Text(trSource("Contacts"))
                                    .fontSize(13)
                                    .fontColor(0xFF8E8E93)
                                    .padding(left: 16, right: 16, top: 8, bottom: 4)
                                    .width(100.percent)
                                Flex(wrap: FlexWrap.Wrap) {
                                    ForEach(this.searchResult.contacts.toArray(), itemGenerator: { t: ShareTarget, _idx: Int64 =>
                                        SharePageGridSectionNode(
                                            target: t,
                                            isSelected: this.isTargetSelected(t),
                                            onTap: { =>
                                                this.toggleSelection(t)
                                            }
                                        )
                                    })
                                }
                                .width(100.percent)
                            }
                            // 分类：Global
                            if (!this.searchResult.global.isEmpty()) {
                                Text("Global")
                                    .fontSize(13)
                                    .fontColor(0xFF8E8E93)
                                    .padding(left: 16, right: 16, top: 8, bottom: 4)
                                    .width(100.percent)
                                Flex(wrap: FlexWrap.Wrap) {
                                    ForEach(this.searchResult.global.toArray(), itemGenerator: { t: ShareTarget, _idx: Int64 =>
                                        SharePageGridSectionNode(
                                            target: t,
                                            isSelected: this.isTargetSelected(t),
                                            onTap: { =>
                                                this.toggleSelection(t)
                                            }
                                        )
                                    })
                                }
                                .width(100.percent)
                            }
                        }
                        .width(100.percent)
                    }
                    .layoutWeight(1)
                    .width(100.percent)
                }
            } else {
                // 默认：最近+联系人合并列表
                Scroll {
                    Flex(wrap: FlexWrap.Wrap) {
                        ForEach(this.getFilteredTargets().toArray(), itemGenerator: { t: ShareTarget, _idx: Int64 =>
                            SharePageGridSectionNode(
                                target: t,
                                isSelected: this.isTargetSelected(t),
                                onTap: { =>
                                    this.toggleSelection(t)
                                }
                            )
                        })
                    }
                    .width(100.percent)
                }
                .layoutWeight(1)
                .width(100.percent)
            }

            // ===== P2-352: 附加留言框（有目标已选时显示）=====
            if (!this.selectedTargets.isEmpty()) {
                TextInput(text: this.optionalMessage, placeholder: trSource("Add a comment..."))
                    .height(40)
                    .fontSize(15)
                    .backgroundColor(0xF5F5F5)
                    .borderRadius(8)
                    .padding(left: 12, right: 12)
                    .margin(left: 16, right: 16, top: 8, bottom: 4)
                    .onChange({ value: String =>
                        this.optionalMessage = value
                    })

                // P2-353: 发送选项（silently / paid stars）
                Row {
                    // 静默发送开关
                    Text(if (this.silently) { "Mute: ON" } else { "Mute: OFF" })
                        .fontSize(13)
                        .fontColor(if (this.silently) { 0xFF317AFF } else { 0xFF8E8E93 })
                        .padding(left: 12, right: 12, top: 6, bottom: 6)
                        .backgroundColor(0xFFF2F2F7)
                        .borderRadius(8)
                        .onClick({ _evt =>
                            this.silently = !this.silently
                        })
                    Blank()
                    // 进度文本
                    if (this.isSending && this.sendProgressText.size > 0) {
                        Text(this.sendProgressText)
                            .fontSize(12)
                            .fontColor(0xFF8E8E93)
                    }
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 4, bottom: 4)
            }

            // ===== 发送按钮 =====
            Button(this.sendButtonLabel())
                .width(100.percent)
                .height(48)
                .margin(left: 16, right: 16, top: 8, bottom: 16)
                .fontSize(16)
                .fontColor(0xFFFFFFFF)
                .backgroundColor(if (this.selectedTargets.isEmpty() || this.isSending) { 0xFFCCCCCC } else { 0xFF317AFF })
                .borderRadius(24)
                .enabled(!this.selectedTargets.isEmpty() && !this.isSending)
                .onClick({ _evt =>
                    this.doSend()
                })
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFFFF)
        .onAppear({ => this.ensureLoaded() })
    }
}
