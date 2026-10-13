package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.sync.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.components.{SearchBar, Avatar, AvatarSpecialPeer, MessageBubble}
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.utils.formatRelativeTimestamp
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * SavedMessagesPage — 收藏消息页面 (Phase J1)（混合工程迁移版）
 *
 * 功能:
 * - 使用 messages.getHistory 获取 "Saved Messages" 对话内容
 * - 复用 MessageBubble 渲染消息
 * - 支持搜索过滤
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack（pageStack.pop() → routerPop()）
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - aboutToAppear(loadSavedMessages) → ensureLoaded() + .onAppear
 */
@HybridComponentEntry
@Component
public class SavedMessagesPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var messages: ArrayList<SavedMessageItem> = ArrayList<SavedMessageItem>()
    @State var isLoading: Bool = true
    @State var searchQuery: String = ""
    @State var isSearching: Bool = false
    @State var loaded: Bool = false
    @State var composerText: String = ""
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    /**
     * "list" (legacy route), "profile" (Saved Messages info with the Chats
     * tab, iOS PeerInfoScreen for the account peer) or "chat" (one saved
     * topic, iOS ChatController with a saved-messages replyThread location).
     */
    @State var mode: String = "list"
    @State var dialogs: ArrayList<SavedDialogEntry> = ArrayList<SavedDialogEntry>()
    @State var dialogsLoading: Bool = true
    @State var topicMessages: ArrayList<Message> = ArrayList<Message>()
    @State var topicLoading: Bool = true
    @State var topicTitle: String = ""
    private var topic: SavedDialogEntry = SavedDialogEntry()

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("SavedMessagesPage")
        if (raw == "profile") {
            this.mode = "profile"
            this.loadSavedDialogs()
            return
        }
        match (SavedDialogEntry.decode(raw)) {
            case Some(entry) =>
                this.mode = "chat"
                this.topic = entry
                this.topicTitle = entry.displayTitle()
                this.loadTopicHistory()
                return
            case None => ()
        }
        this.loadSavedMessages()
    }

    private func loadSavedDialogs(): Unit {
        spawn {
            let list = fetchSavedDialogs()
            launch {
                this.dialogs = list
                this.dialogsLoading = false
            }
        }
    }

    private func loadTopicHistory(): Unit {
        let peerType = this.topic.peerType
        let peerId = this.topic.peerId
        spawn {
            let list = fetchSavedHistory(peerType, peerId)
            launch {
                this.topicMessages = list
                this.topicLoading = false
            }
        }
    }

    /** iOS PeerInfoScreen savedMessagesChats pane item → saved topic chat. */
    private func openTopic(entry: SavedDialogEntry): Unit {
        routerPush("SavedMessagesPage", entry.encode())
    }

    /** ChatChannelSubscriberInputPanelNode.buttonPressed for .openChat/.openGroup/.openChannel. */
    private func openTopicSourceChat(): Unit {
        let entry = this.topic
        let name = entry.displayTitle()
        setSelectedChat(entry.peerId, name, entry.peerType)
        setSelectedChatDraft("")
        routerPush("ChatRoomPage", name)
    }

    func loadSavedMessages(): Unit {
        let _ = spawn {
            var parsed: ArrayList<SavedMessageItem> = ArrayList<SavedMessageItem>()
            try {
                let client = getMTProtoClient()
                let req = MessagesGetHistory()
                req.peer = InputPeerSelf()
                req.limit = 50
                let responseData = client.sendRequest(req.toBytes())
                if (responseData.size > 0) {
                    parsed = parseSavedMessages(responseData)
                    Hilog.info(0, "CjTelegram", "SavedMessages loaded")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "SavedMessages load error")
            }
            let list = parsed
            launch {
                this.messages = list
                this.isLoading = false
            }
        }
    }

    // 按搜索词过滤已保存消息（匹配正文 / 转发来源，大小写不敏感）；
    // 搜索词为空时返回全部。对齐 iOS Saved Messages 搜索过滤行为。
    private func getFilteredMessages(): Array<SavedMessageItem> {
        if (this.searchQuery.isEmpty()) {
            return this.messages.toArray()
        }
        let result = ArrayList<SavedMessageItem>()
        for (msg in this.messages) {
            if (containsIgnoreCase(msg.content, this.searchQuery) ||
                containsIgnoreCase(msg.forwardFrom, this.searchQuery)) {
                result.add(msg)
            }
        }
        return result.toArray()
    }

    @Builder
    func buildCloudStorageCard() {
        Column {
            Image(@r(app.media.saved_cloud_info))
                .width(57)
                .height(45)
                .objectFit(ImageFit.Contain)
                .fillColor(0xFFFFFF)
                .margin(bottom: 10)
            Text(trSource("Your Cloud Storage"))
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFFFFFF)
                .margin(bottom: 8)
            Text(trSource("• Forward messages here to save them"))
                .fontSize(15)
                .fontColor(0xFFFFFF)
                .width(100.percent)
                .margin(bottom: 6)
            Text(trSource("• Send media and files to store them"))
                .fontSize(15)
                .fontColor(0xFFFFFF)
                .width(100.percent)
                .margin(bottom: 6)
            Text(trSource("• Access this chat from any device"))
                .fontSize(15)
                .fontColor(0xFFFFFF)
                .width(100.percent)
                .margin(bottom: 6)
            Text(trSource("• Use search to quickly find things"))
                .fontSize(15)
                .fontColor(0xFFFFFF)
                .width(100.percent)
        }
        .width(300)
        .padding(left: 16, right: 16, top: 14, bottom: 16)
        .backgroundColor(0xB83F914A)
        .borderRadius(16)
    }

    @Builder
    func buildSavedComposer() {
        Row {
            Image(@r(app.media.chatroom_ic_attach))
                .width(22)
                .height(22)
                .fillColor(0x8E8E93)
                .margin(left: 10, right: 8)
            TextInput(text: this.composerText, placeholder: trSource("Message"))
                .layoutWeight(1)
                .height(36)
                .backgroundColor(0xB8FFFFFF)
                .borderRadius(18)
                .padding(left: 12, right: 12)
                .onChange({ value: String =>
                    this.composerText = value
                })
            Image(@r(app.media.chatroom_ic_stickers))
                .width(22)
                .height(22)
                .fillColor(0x8E8E93)
                .margin(left: 8)
            Image(@r(app.media.media_ic_mic))
                .width(22)
                .height(22)
                .fillColor(0x8E8E93)
                .margin(left: 8, right: 12)
        }
        .width(100.percent)
        .height(52)
        .backgroundColor(0xB8FFFFFF)
        .alignItems(VerticalAlign.Center)
        .padding(bottom: getSafeAreaBottom())
    }

    @Builder
    func buildNavBar(title: String) {
        Row {
            Stack(alignContent: Alignment.Center) {
                Image(@r(app.media.callui_v2_back))
                    .width(13)
                    .height(22)
                    .fillColor(this.presentation.accentColor)
            }
                .width(44)
                .height(44)
                .onClick({ _evt => routerPop() })
            Blank().layoutWeight(1)
            Text(title)
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.presentation.textColor)
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
            Blank().layoutWeight(1)
            Blank().width(44)
        }
        .width(100.percent)
        .height(54.0 + getSafeAreaTop())
        .padding(left: 8, right: 8, top: getSafeAreaTop())
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func buildDialogRow(entry: SavedDialogEntry) {
        Row(space: 12) {
            if (entry.isMyNotes()) {
                Avatar(displayName: "My Notes", avatarSize: 56, peerId: entry.peerId, specialPeer: AvatarSpecialPeer.SavedMessages)
            } else {
                Avatar(displayName: entry.displayTitle(), avatarSize: 56, peerId: entry.peerId)
            }
            Column(space: 3) {
                Row {
                    Text(entry.displayTitle())
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.presentation.textColor)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                        .layoutWeight(1)
                    if (entry.topDate > 0) {
                        Text(formatRelativeTimestamp(entry.topDate))
                            .fontSize(14)
                            .fontColor(this.presentation.secondaryTextColor)
                    }
                }
                .width(100.percent)
                Text(entry.topText)
                    .fontSize(15)
                    .fontColor(this.presentation.secondaryTextColor)
                    .maxLines(2)
                    .textOverflow(TextOverflow.Ellipsis)
                    .width(100.percent)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
        .width(100.percent)
        .height(76)
        .padding(left: 10, right: 12)
        .backgroundColor(this.presentation.cardColor)
        .onClick({ _evt => this.openTopic(entry) })
    }

    /** Saved Messages info: header + "Chats" pane (PeerInfoData.swift:1575-1577 inserts it first). */
    @Builder
    func buildProfile() {
        Column {
            this.buildNavBar("")
            Column(space: 8) {
                Avatar(displayName: "Saved Messages", avatarSize: 100, peerId: getCurrentUserId(), specialPeer: AvatarSpecialPeer.SavedMessages)
                Text(trSource("Saved Messages"))
                    .fontSize(24)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.presentation.textColor)
            }
            .width(100.percent)
            .alignItems(HorizontalAlign.Center)
            .padding(bottom: 16)

            if (savedMessagesHasPeersOtherThanSaved(this.dialogs)) {
                Row(space: 20) {
                    Column {
                        Text(trSource("Chats"))
                            .fontSize(15)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(this.presentation.accentColor)
                        Divider()
                            .strokeWidth(3)
                            .color(this.presentation.accentColor)
                            .width(40)
                            .margin(top: 6)
                    }
                    Text(trSource("Media"))
                        .fontSize(15)
                        .fontColor(this.presentation.secondaryTextColor)
                        .onClick({ _evt => routerPush("SharedMediaPage", "user:${getCurrentUserId()}") })
                }
                .width(100.percent)
                .height(44)
                .padding(left: 16, right: 16)
                .backgroundColor(this.presentation.cardColor)
                .alignItems(VerticalAlign.Center)
            }

            if (this.dialogsLoading) {
                Column {
                    LoadingProgress().width(36).height(36)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
            } else {
                List {
                    ForEach(this.dialogs.toArray(), itemGenerator: { entry: SavedDialogEntry, _idx: Int64 =>
                        ListItem {
                            this.buildDialogRow(entry)
                        }
                    }, keyGenerator: { entry: SavedDialogEntry, _idx: Int64 =>
                        "${entry.peerType}_${entry.peerId}"
                    })
                }
                .width(100.percent)
                .layoutWeight(1)
                .divider(ListDividerOptions(strokeWidth: 0.5, color: Color(this.presentation.dividerColor), startMargin: 78, endMargin: 0))
                .scrollBar(BarState.Off)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .padding(bottom: getSafeAreaBottom())
        .backgroundColor(this.presentation.backgroundColor)
    }

    /** One saved topic; bottom panel per CISP:201-221 / CSP:56-78. */
    @Builder
    func buildTopicChat() {
        Column {
            this.buildNavBar(this.topicTitle)
            Stack {
                if (this.topicLoading) {
                    Column {
                        LoadingProgress().width(36).height(36)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .justifyContent(FlexAlign.Center)
                } else {
                    List(initialIndex: if (this.topicMessages.size > 0) { Int32(this.topicMessages.size - 1) } else { Int32(0) }) {
                        ForEach(this.topicMessages.toArray(), itemGenerator: { msg: Message, _idx: Int64 =>
                            ListItem {
                                MessageBubble(
                                    message: msg,
                                    voicePlaybackEpoch: 0,
                                    isMultiSelectMode: true,
                                    withWallpaper: false,
                                    wallpaperGradientColors: Array<UInt32>()
                                )
                            }
                        }, keyGenerator: { msg: Message, _idx: Int64 =>
                            msg.id.toString()
                        })
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .scrollBar(BarState.Off)
                }
            }
            .width(100.percent)
            .layoutWeight(1)

            if (this.topic.hasOpenPanel()) {
                Row {
                    Text(this.topic.openActionTitle())
                        .fontSize(17)
                        .fontColor(this.presentation.accentColor)
                        .width(100.percent)
                        .height(100.percent)
                        .textAlign(TextAlign.Center)
                        .onClick({ _evt => this.openTopicSourceChat() })
                }
                .width(100.percent)
                .height(52)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(this.presentation.cardColor)
            } else if (this.topic.isHiddenAuthor()) {
                Row {
                    Text(trSource("Senders of these messages restricted to link their name when forwarding."))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                }
                .width(100.percent)
                .height(52)
                .padding(left: 16, right: 16)
                .backgroundColor(this.presentation.cardColor)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .padding(bottom: getSafeAreaBottom())
        .backgroundColor(this.presentation.backgroundColor)
    }

    public func build() {
        Stack {
            if (this.mode == "profile") {
                this.buildProfile()
            } else if (this.mode == "chat") {
                this.buildTopicChat()
            } else {
                this.buildLegacyList()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder
    func buildLegacyList() {
        /* HISTORICAL VIEW (pre TC-0555 reconstruct): literal "← Back" nav,
           bookmark empty "No Saved Messages" + single Forward line, no composer,
           history as media-icon + summary List. Kept as comment only. */
        Column {
            Row {
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.callui_v2_back))
                        .width(13)
                        .height(22)
                }
                    .width(44)
                    .height(44)
                    .backgroundColor(0xB8FFFFFF)
                    .borderRadius(22)
                    .onClick({ _evt => routerPop() })
                Blank().layoutWeight(1)
                Text(trSource("Saved Messages"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                    .padding(left: 18, right: 18, top: 8, bottom: 8)
                    .backgroundColor(0xB8FFFFFF)
                    .borderRadius(22)
                Blank().layoutWeight(1)
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.set2_ic_navsearch))
                        .width(25)
                        .height(25)
                }
                    .width(44)
                    .height(44)
                    .backgroundColor(0xB8FFFFFF)
                    .borderRadius(22)
                    .onClick({ _evt =>
                        this.isSearching = !this.isSearching
                        if (!this.isSearching) {
                            this.searchQuery = ""
                        }
                    })
            }
            .width(100.percent)
            .height(54.0 + getSafeAreaTop())
            .padding(left: 12, right: 12, top: getSafeAreaTop())
            .backgroundColor(Color.Transparent)
            .alignItems(VerticalAlign.Center)

            if (this.isSearching) {
                Column {
                    SearchBar(
                        loading: false,
                        backArrow: false,
                        text: this.searchQuery,
                        hint: "Search saved messages...",
                        onChange: { value: String =>
                            this.searchQuery = value
                        },
                        onCancel: { =>
                            this.searchQuery = ""
                            this.isSearching = false
                        },
                        showCancel: true
                    )
                }
                .width(100.percent)
            }

            Stack {
                Image(@r(app.media.wallpaper_pattern_dots))
                    .width(100.percent)
                    .height(100.percent)
                    .objectFit(ImageFit.Cover)
                    .opacity(0.35)
                if (this.isLoading) {
                    Column {
                        LoadingProgress()
                            .width(40)
                            .height(40)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .justifyContent(FlexAlign.Center)
                } else if (this.messages.size == 0) {
                    Column {
                        this.buildCloudStorageCard()
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    List {
                        ForEach(this.getFilteredMessages(), itemGenerator: { msg: SavedMessageItem, _idx: Int64 =>
                            ListItem {
                                Row {
                                    Blank().layoutWeight(1)
                                    Column {
                                        if (msg.forwardFrom.size > 0) {
                                            Text(msg.forwardFrom)
                                                .fontSize(12)
                                                .fontColor(0x007AFF)
                                                .margin(bottom: 4)
                                        }
                                        Text(msg.content)
                                            .fontSize(16)
                                            .fontColor(0x000000)
                                        Text(msg.timestamp)
                                            .fontSize(11)
                                            .fontColor(0x8E8E93)
                                            .margin(top: 4)
                                    }
                                    .padding(10)
                                    .backgroundColor(0xEEFFD6)
                                    .borderRadius(16)
                                    .constraintSize(maxWidth: 280)
                                }
                                .width(100.percent)
                                .padding(left: 12, right: 12, top: 4, bottom: 4)
                            }
                        })
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .scrollBar(BarState.Off)
                    .backgroundColor(Color.Transparent)
                }
            }
            .width(100.percent)
            .layoutWeight(1)
            .backgroundColor(Color.Transparent)

            this.buildSavedComposer()
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xC8E6C0)
        .linearGradient(angle: 145.0, colors: [
            (Color(0xDDE57E), 0.0),
            (Color(0x79C98B), 0.52),
            (Color(0xDDE5A4), 1.0)
        ])
    }
}

/**
 * 收藏消息项
 */
public class SavedMessageItem {
    public var messageId: Int64 = 0
    public var content: String = ""
    public var mediaIcon: String = "💬"
    public var timestamp: String = ""
    public var forwardFrom: String = ""

    public init(messageId!: Int64 = 0, content!: String = "", mediaIcon!: String = "💬",
                timestamp!: String = "", forwardFrom!: String = "") {
        this.messageId = messageId
        this.content = content
        this.mediaIcon = mediaIcon
        this.timestamp = timestamp
        this.forwardFrom = forwardFrom
    }
}

/**
 * 解析 messages.Messages 响应为 SavedMessageItem 列表
 */
func parseSavedMessages(data: Array<Byte>): ArrayList<SavedMessageItem> {
    let results = ArrayList<SavedMessageItem>()
    try {
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            return results
        }

        // 跳过 flags/count 等字段
        if (constructor == 0x3a54685e || constructor == 0xc8edce1e) {
            let _ = d.readInt32()  // flags
            let _ = d.readInt32()  // count
        }
        if (constructor == 0xc8edce1e) {
            let _ = d.readInt32()  // next_rate
            let _ = d.readInt32()  // offset_id_offset
        }

        // messages vector
        let msgVectorCtor = d.readUInt32()
        if (msgVectorCtor == 0x1cb5c415) {
            let msgCount = d.readInt32()
            var i: Int32 = 0
            while (i < msgCount && i < 50) {
                let msgCtor = d.readUInt32()
                if (msgCtor == 0x76BEC211 || msgCtor == 0x94345242) {
                    let _ = d.readInt32()
                    i += 1
                    continue
                }
                // 简化解析: 只提取 id 作为占位
                let mFlags = d.readInt32()
                let msgId = d.readInt32()
                let item = SavedMessageItem(
                    messageId: Int64(msgId),
                    content: "Saved message #${msgId}",
                    mediaIcon: "💬",
                    timestamp: "..."
                )
                results.add(item)
                i += 1
                break  // 简化: 完整解析需要更复杂的 TL 解析逻辑
            }
        }
    } catch (_e: Exception) {
        Hilog.info(0, "CjTelegram", "SavedMessages parse error")
    }
    return results
}
