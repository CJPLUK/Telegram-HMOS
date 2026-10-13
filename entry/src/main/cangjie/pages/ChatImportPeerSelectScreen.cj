package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.components.SearchBar
import ohos_app_cangjie_entry.router.*

/**
 * 聊天记录导入目标会话选择页 — ChatImportPeerSelectScreen
 *
 * P2-090: 实现导入目标 peer 选择 UI。
 *
 * 用户从聊天列表（私聊 + 群组）中选择一个对话作为导入目标。
 *   - 私聊（user）：直接选择
 *   - 普通群（chat）：展示"会被升级为超级群"提示后继续
 *   - 超级群/频道（channel）：直接选择
 *
 * 选择后通过 NavPathStack 导航到 ChatImportActivityScreen，
 * 并将 peerId / peerAccessHash / peerType 写入 ChatImportActivityScreen 的 @State 字段。
 * 由于跨 NavDestination 传参需要共享状态，此处使用全局选择存储（ChatImportPeerStore）。
 *
 * iOS 参考：submodules/ChatImportUI — ChatImportActivityScreen.swift 入口路由逻辑。
 * 根容器：NavDestination（D-002）
 * 路由名：ChatImportPeerSelectScreen
 */

/**
 * 全局导入目标 peer 存储 — 跨 NavDestination 传递选择结果。
 * Worker 范围内唯一可写，由 ChatImportPeerSelectScreen 写入，
 * 由 ChatImportActivityScreen 读取后清空。
 *
 * P2-091: 增加 importFileData / importFileName / importIsZip 字段，
 * 供 ChatImportActivityScreen 在 aboutToAppear 时读取并触发 zip 解压 + 媒体上传。
 */
public class ChatImportPeerStore {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var peerType: String = "user"
    public var displayName: String = ""
    // P2-091: 主导入文件字节数据（从 LegacyDataImportPage 或导入入口写入）
    public var importFileData: Array<Byte> = Array<Byte>(0, repeat: 0)
    // P2-091: 主导入文件名（如 "telegram_export.zip" 或 "history.txt"）
    public var importFileName: String = ""
    // P2-091: 是否为 zip 包（true 时 ChatImportActivityScreen 负责 zip 解压提取媒体）
    public var importIsZip: Bool = false
}

private var _chatImportPeerStore: Option<ChatImportPeerStore> = None

public func getChatImportPeerStore(): ChatImportPeerStore {
    match (_chatImportPeerStore) {
        case Some(s) => return s
        case None =>
            let s = ChatImportPeerStore()
            _chatImportPeerStore = Some(s)
            return s
    }
}

/**
 * 导入目标候选 peer 数据
 */
public class ImportTargetPeer {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var peerType: String = "user"      // "user" | "chat" | "channel"
    public var displayName: String = ""
    public var isGroup: Bool = false
    public var needsMigration: Bool = false   // peerType=="chat" 的普通群需升级

    public init(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String,
        displayName!: String
    ) {
        this.peerId = peerId
        this.peerAccessHash = peerAccessHash
        this.peerType = peerType
        this.displayName = displayName
        this.isGroup = (peerType == "chat" || peerType == "channel")
        this.needsMigration = (peerType == "chat")
    }
}

@HybridComponentEntry
@Component
public class ChatImportPeerSelectScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false

    @State var peers: ArrayList<ImportTargetPeer> = ArrayList<ImportTargetPeer>()
    @State var searchText: String = ""
    @State var isLoading: Bool = true

    // 跳转前确认弹窗（peerType=="chat" 的普通群需提示升级）
    @State var showMigrationAlert: Bool = false
    // pendingPeer 存储为独立字段（避免 @State Option<T> 歧义）
    @State var hasPendingPeer: Bool = false
    @State var pendingPeerId: Int64 = 0
    @State var pendingPeerAccessHash: Int64 = 0
    @State var pendingPeerType: String = "user"
    @State var pendingPeerName: String = ""

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        Hilog.info(0, "CjTelegram", "[ChatImportPeerSelectScreen] ensureLoaded")
        this.loadPeers()
    }

    private func loadPeers(): Unit {
        launch {
            this.isLoading = true
        }

        let _ = spawn {
            let chatSvc = getRealChatListService()
            let chatList = chatSvc.getDialogsLocalFirst(limit: 50)
            let result = ArrayList<ImportTargetPeer>()

            for (chat in chatList) {
                let peer = ImportTargetPeer(
                    peerId: chat.id,
                    peerAccessHash: 0,
                    peerType: chat.peerType,
                    displayName: chat.name
                )
                result.add(peer)
            }

            launch {
                this.peers = result
                this.isLoading = false
            }
        }
    }

    private func matchesSearch(peer: ImportTargetPeer): Bool {
        if (this.searchText.isEmpty()) {
            return true
        }
        let lower = this.searchText.toAsciiLower()
        return peer.displayName.toAsciiLower().contains(lower)
    }

    private func selectPeer(peer: ImportTargetPeer): Unit {
        if (peer.needsMigration) {
            // 普通群需提示用户升级为超级群
            let capId = peer.peerId
            let capHash = peer.peerAccessHash
            let capType = peer.peerType
            let capName = peer.displayName
            launch {
                this.hasPendingPeer = true
                this.pendingPeerId = capId
                this.pendingPeerAccessHash = capHash
                this.pendingPeerType = capType
                this.pendingPeerName = capName
                this.showMigrationAlert = true
            }
        } else {
            this.confirmSelect(peer)
        }
    }

    private func confirmSelectPending(): Unit {
        let store = getChatImportPeerStore()
        store.peerId = this.pendingPeerId
        store.peerAccessHash = this.pendingPeerAccessHash
        store.peerType = this.pendingPeerType
        store.displayName = this.pendingPeerName

        Hilog.info(0, "CjTelegram", "[ChatImportPeerSelectScreen] confirmed pending peer ${this.pendingPeerId}")
        routerPush("ChatImportActivityScreen", "{}")
    }

    private func confirmSelect(peer: ImportTargetPeer): Unit {
        let store = getChatImportPeerStore()
        store.peerId = peer.peerId
        store.peerAccessHash = peer.peerAccessHash
        store.peerType = peer.peerType
        store.displayName = peer.displayName

        Hilog.info(0, "CjTelegram", "[ChatImportPeerSelectScreen] selected peer ${peer.peerId} type=${peer.peerType}")
        routerPush("ChatImportActivityScreen", "{}")
    }

    private func getPeerInitial(peer: ImportTargetPeer): String {
        if (peer.displayName.size > 0) {
            return firstRuneString(peer.displayName).toAsciiUpper()
        }
        return "?"
    }

    private func getPeerTypeLabel(peer: ImportTargetPeer): String {
        if (peer.peerType == "channel") {
            return "Supergroup"
        } else if (peer.peerType == "chat") {
            return "Group (will be upgraded)"
        } else {
            return "Private Chat"
        }
    }

    public func build() {
        Column() {
                Row() {
                    Text("Select Import Target")
                        .fontSize(18)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFF000000)
                        .layoutWeight(1)
                    Button(trSource("Cancel"))
                        .fontSize(14)
                        .fontColor(0xFF007AFF)
                        .backgroundColor(Color.Transparent)
                        .padding(left: 8, right: 8, top: 4, bottom: 4)
                        .onClick({ _ => routerPop() })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 12, bottom: 8)

                Divider()
                    .color(0xFFE5E5EA)
                    .width(100.percent)

                // P2-RETRO-chatlist: 手搓 TextInput → SearchBar 原子。
                // SearchBar 是 @Component，不能直接链内置属性，外包 Column 容器。
                Column {
                    SearchBar(
                        loading: false,
                        backArrow: false,
                        text: this.searchText,
                        hint: "Search chats...",
                        onChange: { val: String => this.searchText = val }
                    )
                }
                .width(100.percent)

                Divider()
                    .color(0xFFE5E5EA)
                    .width(100.percent)

                if (this.isLoading) {
                    Column() {
                        LoadingProgress()
                            .width(48)
                            .height(48)
                            .color(0xFF007AFF)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Center)
                    .justifyContent(FlexAlign.Center)
                } else {
                    List() {
                        ForEach(this.peers, itemGenerator: { peer: ImportTargetPeer, _idx: Int64 =>
                            if (this.matchesSearch(peer)) {
                                ListItem() {
                                    Row() {
                                        Column() {
                                            Text(this.getPeerInitial(peer))
                                                .fontSize(20)
                                                .fontColor(0xFFFFFFFF)
                                                .textAlign(TextAlign.Center)
                                        }
                                        .width(44)
                                        .height(44)
                                        .borderRadius(22)
                                        .backgroundColor(if (peer.isGroup) { 0xFF34C759 } else { 0xFF007AFF })
                                        .alignItems(HorizontalAlign.Center)
                                        .justifyContent(FlexAlign.Center)
                                        .margin(right: 12)

                                        Column() {
                                            Text(peer.displayName)
                                                .fontSize(16)
                                                .fontColor(0xFF1C1C1E)
                                                .maxLines(1)
                                                .textOverflow(TextOverflow.Ellipsis)
                                                .width(100.percent)
                                            Text(this.getPeerTypeLabel(peer))
                                                .fontSize(13)
                                                .fontColor(0xFF8E8E93)
                                                .margin(top: 2)
                                        }
                                        .layoutWeight(1)
                                        .alignItems(HorizontalAlign.Start)
                                    }
                                    .width(100.percent)
                                    .padding(left: 16, right: 16, top: 10, bottom: 10)
                                    .onClick({ _ => this.selectPeer(peer) })
                                }
                            }
                        })
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xFFE5E5EA, startMargin: 72, endMargin: 0))
                }

                if (this.showMigrationAlert) {
                    Stack() {
                        Column() {
                            Text("Upgrade Group")
                                .fontSize(17)
                                .fontWeight(FontWeight.Bold)
                                .fontColor(0xFF1C1C1E)
                                .margin(bottom: 8)

                            Text("This group will be upgraded to a supergroup to support history import. This action cannot be undone.")
                                .fontSize(14)
                                .fontColor(0xFF3C3C43)
                                .textAlign(TextAlign.Center)
                                .padding(left: 8, right: 8)
                                .margin(bottom: 20)

                            Row() {
                                Button(trSource("Cancel"))
                                    .layoutWeight(1)
                                    .height(44)
                                    .fontSize(16)
                                    .fontColor(0xFF007AFF)
                                    .backgroundColor(Color.Transparent)
                                    .onClick({ _ =>
                                        launch {
                                            this.showMigrationAlert = false
                                            this.hasPendingPeer = false
                                        }
                                    })
                                Button(trSource("Upgrade"))
                                    .layoutWeight(1)
                                    .height(44)
                                    .fontSize(16)
                                    .fontColor(0xFFFF3B30)
                                    .backgroundColor(Color.Transparent)
                                    .onClick({ _ =>
                                        launch {
                                            this.showMigrationAlert = false
                                        }
                                        if (this.hasPendingPeer) {
                                            this.confirmSelectPending()
                                        }
                                    })
                            }
                            .width(100.percent)
                        }
                        .width(300)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(14)
                        .padding(left: 16, right: 16, top: 20, bottom: 8)
                        .shadow(radius: 24.0, color: 0x44000000, offsetX: 0.0, offsetY: 8.0)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x66000000)
                    .position(x: 0, y: 0)
                    .alignContent(Alignment.Center)
                }
            }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFFFF)
        .onAppear({ => this.ensureLoaded() })
    }
}
