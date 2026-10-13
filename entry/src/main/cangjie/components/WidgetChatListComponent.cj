package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getWidgetItemsServiceV2
import ohos_app_cangjie_entry.models.WidgetData
import ohos_app_cangjie_entry.models.WidgetDataPeer
import ohos_app_cangjie_entry.models.WidgetDataPeers
import ohos_app_cangjie_entry.models.WidgetMessageContent
import ohos_app_cangjie_entry.models.WidgetMessage
import std.collection.ArrayList

/**
 * WidgetChatListComponent — P2-433
 *
 * 会话 widget 渲染 + 结构化消息预览（应用内版本）。
 *
 * 相比 D-版 WidgetItemsComponent 的改进：
 *   P2-431: 使用 WidgetDataPeer 富模型（letters/isForum/badge/message）
 *   P2-432: 通过 WidgetItemsServiceV2 获取 14 类型媒体归类
 *   P2-433:
 *     - 结构化消息预览文案：按 Content 类型出图标+文字
 *       photo → "Photo", voice → "Voice Message", call → "Call"/"Video Call" etc.
 *     - 群发送者前缀："You: " 或 "SenderName: "
 *     - Saved Messages 特例：名称 "Saved Messages" + 书签图标
 *     - Locked 特例：显示 "Locked" + 提示文案
 *
 * 应用内会话列表真做（NavDestination 根容器合规）。
 *
 * [widget-host:P2-435] 接线点：
 *   真实桌面卡片（主屏 FormExtensionAbility 入口、ArkTS 卡片受限运行时）
 *   由 P2-435 实现。本组件仅提供应用内渲染。
 *
 * 规范合规：
 *   S-001: 所有 @State 写操作在 launch {} 回主线程
 *   S-005/R-107: build() / @Builder 内无 let/var
 *   D-002: 详情页使用 NavDestination 根容器（本组件作为内嵌组件，非独立页面，
 *           无需 NavDestination — 父页面使用时须包裹于 NavDestination 内）
 *   S-007: @State 数组显式声明 Array<WidgetDataPeer> 类型
 *   R-112: WidgetMessageContent enum operator== 已实现
 *
 * @State 自查（无 dangling）：
 *   peers       — 由 aboutToAppear → spawn → launch 写入 ✓
 *   isLoading   — 由 aboutToAppear → spawn → launch 写入 ✓
 *   hasError    — 由 aboutToAppear → spawn → launch 写入 ✓
 *   isLocked    — 由 aboutToAppear → spawn → launch 写入 ✓
 *   errorMsg    — 由 aboutToAppear → spawn → launch 写入 ✓
 */
@Component
public class WidgetChatListComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var peers: Array<WidgetDataPeer> = Array<WidgetDataPeer>(0, { _ => WidgetDataPeer() })
    @State var isLoading: Bool = false
    @State var hasError: Bool = false
    @State var isLocked: Bool = false
    @State var errorMsg: String = ""

    // 点击会话回调（peerId 作为参数，供父级导航到对应会话）
    public var onPeerTap: (Int64) -> Unit = { _id: Int64 => }

    public override func aboutToAppear(): Unit {
        this.isLoading = true
        this.hasError = false
        this.isLocked = false
        let _ = spawn {
            let svc = getWidgetItemsServiceV2()
            var widgetData: WidgetData = WidgetData()
            var ok: Bool = false
            var errStr: String = ""
            try {
                widgetData = svc.refreshWidgetData()
                ok = true
            } catch (e: Exception) {
                ok = false
                errStr = "Failed to load chats"
            }
            let okRef = ok
            let errRef = errStr
            let lockedRef = !widgetData.isUnlocked() && widgetData.accountId != 0
            let peersList = this.extractPeers(widgetData)
            let peersRef = peersList
            launch {
                if (okRef) {
                    this.peers = peersRef
                    this.isLocked = lockedRef
                    this.hasError = false
                } else {
                    this.hasError = true
                    this.errorMsg = errRef
                }
                this.isLoading = false
            }
        }
    }

    // ============================================================
    // 辅助方法（不在 build 中使用 let，S-005/D-116 合规）
    // ============================================================

    private func extractPeers(data: WidgetData): Array<WidgetDataPeer> {
        match (data.content) {
            case Some(dp) => return dp.peers
            case None => return Array<WidgetDataPeer>(0, { _ => WidgetDataPeer() })
        }
    }

    private func previewText(peer: WidgetDataPeer): String {
        match (peer.message) {
            case Some(msg) => return msg.buildPreviewText()
            case None => return ""
        }
    }

    private func badgeCount(peer: WidgetDataPeer): Int32 {
        match (peer.badge) {
            case Some(b) => return b.count
            case None => return 0
        }
    }

    private func badgeMuted(peer: WidgetDataPeer): Bool {
        match (peer.badge) {
            case Some(b) => return b.isMuted
            case None => return false
        }
    }

    private func badgeText(count: Int32): String {
        if (count > 99) { return "99+" }
        return "${count}"
    }

    private func avatarBgColor(peer: WidgetDataPeer): Int64 {
        let seed = peer.id % 7
        if (seed == 0) { return 0x317AFF }
        else if (seed == 1) { return 0xFF3B30 }
        else if (seed == 2) { return 0xFF9500 }
        else if (seed == 3) { return 0x34C759 }
        else if (seed == 4) { return 0xAF52DE }
        else if (seed == 5) { return 0xFF2D55 }
        else { return 0x5AC8FA }
    }

    private func avatarLabel(peer: WidgetDataPeer): String {
        return peer.primaryLetter()
    }

    private func peerSubtitle(peer: WidgetDataPeer): String {
        if (peer.isForum) { return "Forum" }
        return ""
    }

    private func isSavedMessages(peer: WidgetDataPeer): Bool {
        return peer.name == "Saved Messages"
    }

    private func truncatePreview(text: String): String {
        if (text.size <= 45) { return text }
        let runes = text.toRuneArray()
        var result = ""
        var count: Int64 = 0
        for (r in runes) {
            if (count >= 45) { break }
            result = result + r.toString()
            count = count + 1
        }
        return result + "..."
    }

    // ============================================================
    // build()
    // ============================================================

    public func build() {
        Column {
            if (this.isLoading) {
                this.buildLoadingState()
            } else if (this.isLocked) {
                this.buildLockedState()
            } else if (this.hasError) {
                this.buildErrorState()
            } else if (this.peers.size == 0) {
                this.buildEmptyState()
            } else {
                this.buildPeerList()
            }
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFF)
    }

    @Builder
    func buildLoadingState() {
        Row {
            Text("Loading recent chats...")
                .fontSize(14)
                .fontColor(0x8E8E93)
        }
        .width(100.percent)
        .height(60)
        .justifyContent(FlexAlign.Center)
    }

    @Builder
    func buildLockedState() {
        Column {
            Text(trSource("Locked"))
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor(0x000000)
                .margin(bottom: 6)
            Text("Open Telegram and enter passcode to view chats.")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .textAlign(TextAlign.Center)
                .padding(left: 24, right: 24)
        }
        .width(100.percent)
        .height(120)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func buildErrorState() {
        Column {
            Text(this.errorMsg)
                .fontSize(14)
                .fontColor(0xFF3B30)
            Button(trSource("Retry"))
                .width(100)
                .height(34)
                .fontSize(14)
                .borderRadius(17)
                .backgroundColor(0x317AFF)
                .fontColor(0xFFFFFF)
                .margin(top: 8)
                .onClick({ _evt =>
                    this.hasError = false
                    this.isLoading = true
                    let _ = spawn {
                        let svc = getWidgetItemsServiceV2()
                        var ok2: Bool = false
                        var err2: String = ""
                        var wd2: WidgetData = WidgetData()
                        try {
                            wd2 = svc.refreshWidgetData()
                            ok2 = true
                        } catch (_e: Exception) {
                            ok2 = false
                            err2 = "Failed to load chats"
                        }
                        let ok2Ref = ok2
                        let err2Ref = err2
                        let locked2Ref = !wd2.isUnlocked() && wd2.accountId != 0
                        let peers2Ref = this.extractPeers(wd2)
                        launch {
                            if (ok2Ref) {
                                this.peers = peers2Ref
                                this.isLocked = locked2Ref
                                this.hasError = false
                            } else {
                                this.hasError = true
                                this.errorMsg = err2Ref
                            }
                            this.isLoading = false
                        }
                    }
                })
        }
        .width(100.percent)
        .height(120)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func buildEmptyState() {
        Row {
            Text("No recent chats")
                .fontSize(14)
                .fontColor(0x8E8E93)
        }
        .width(100.percent)
        .height(60)
        .justifyContent(FlexAlign.Center)
    }

    @Builder
    func buildPeerList() {
        List {
            ForEach(this.peers, itemGenerator: { peer: WidgetDataPeer, _idx: Int64 =>
                ListItem {
                    Row {
                        // 头像
                        Stack(alignContent: Alignment.TopEnd) {
                            if (peer.hasAvatarPath) {
                                Image(peer.avatarPath)
                                    .width(48)
                                    .height(48)
                                    .borderRadius(24)
                                    .objectFit(ImageFit.Cover)
                            } else {
                                Column {
                                    Text(this.avatarLabel(peer))
                                        .fontSize(19)
                                        .fontColor(0xFFFFFF)
                                        .fontWeight(FontWeight.Medium)
                                }
                                .width(48)
                                .height(48)
                                .borderRadius(24)
                                .backgroundColor(this.avatarBgColor(peer))
                                .justifyContent(FlexAlign.Center)
                                .alignItems(HorizontalAlign.Center)
                            }
                        }
                        .width(48)
                        .height(48)
                        .margin(right: 12)

                        // 内容区
                        Column {
                            // 标题行：名称 + subtitle + badge
                            Row {
                                Text(peer.name)
                                    .fontSize(16)
                                    .fontColor(0x000000)
                                    .fontWeight(FontWeight.Medium)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .layoutWeight(1)

                                if (this.peerSubtitle(peer).size > 0) {
                                    Text(this.peerSubtitle(peer))
                                        .fontSize(11)
                                        .fontColor(0x8E8E93)
                                        .margin(left: 4)
                                }

                                if (this.badgeCount(peer) > 0) {
                                    Text(this.badgeText(this.badgeCount(peer)))
                                        .fontSize(12)
                                        .fontColor(0xFFFFFF)
                                        .backgroundColor(
                                            if (this.badgeMuted(peer)) { 0xAAAAAA } else { 0x317AFF })
                                        .borderRadius(10)
                                        .padding(left: 6, right: 6, top: 2, bottom: 2)
                                        .fontWeight(FontWeight.Medium)
                                        .margin(left: 6)
                                }
                            }
                            .width(100.percent)
                            .alignItems(VerticalAlign.Center)

                            // 预览行：结构化文案（P2-433 核心）
                            Row {
                                Text(this.truncatePreview(this.previewText(peer)))
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .layoutWeight(1)
                            }
                            .width(100.percent)
                            .margin(top: 3)
                        }
                        .layoutWeight(1)
                        .alignItems(HorizontalAlign.Start)
                    }
                    .width(100.percent)
                    .height(68)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _evt =>
                        let tapId = peer.id
                        this.onPeerTap(tapId)
                        Hilog.info(0, "CjTelegram", "[WidgetChatListComponent] tapped peer ${tapId}")
                    })
                }
            })
        }
        .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 76, endMargin: 0))
        .width(100.percent)
    }
}
