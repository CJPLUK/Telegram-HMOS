package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getWidgetItemsService
import ohos_app_cangjie_entry.services.WidgetPeerItem
import std.collection.ArrayList

/**
 * WidgetItemsComponent — 桌面小组件数据条目列表组件
 *
 * 功能概述：
 *   对应 iOS WidgetItems/Sources/WidgetItems.swift 的 WidgetDataPeer 展示逻辑。
 *   iOS WidgetKit 利用 AppGroup 共享存储将最近会话写入桌面 widget；
 *   HarmonyOS 侧由 WidgetItemsService 通过 MTProto 获取对话列表（getDialogs → MTProtoClient.send()），
 *   本组件用于在应用内展示这批 widget 数据条目（预览/调试 / 可嵌入设置页）。
 *
 * 规范合规：
 *   S-64: public override func aboutToAppear(): Unit { ... }
 *   R-69: let _ = spawn { ... }，spawn 内 @State 写操作通过 launch {} 回主线程
 *   build() 中无 let（S-41），辅助逻辑提取为 private func
 *   实现完整、无占位代码
 *
 * 数据流：
 *   aboutToAppear
 *     → spawn { WidgetItemsService.refreshWidgetItems()
 *                → getRealChatListService().getDialogs()
 *                   → getMTProtoClient().sendRequest() }
 *     → launch { @State items = result }
 *
 * 使用方式（嵌入到任意 NavDestination 页面）：
 *   WidgetItemsComponent(onItemTap: { item => ... })
 */
@Component
public class WidgetItemsComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var items: ArrayList<WidgetPeerItem> = ArrayList<WidgetPeerItem>()
    @State var isLoading: Bool = false
    @State var hasError: Bool = false

    // 点击条目回调（peerId 作为参数，供父级导航到对应会话）
    public var onItemTap: (Int64) -> Unit = { _id: Int64 => }

    public override func aboutToAppear(): Unit {
        this.isLoading = true
        this.hasError = false
        let _ = spawn {
            let svc = getWidgetItemsService()
            var loaded: ArrayList<WidgetPeerItem> = ArrayList<WidgetPeerItem>()
            var ok: Bool = false
            try {
                loaded = svc.refreshWidgetItems()
                ok = true
            } catch (_e: Exception) {
                loaded = ArrayList<WidgetPeerItem>()
                ok = false
            }
            let loadedRef = loaded
            let okRef = ok
            if (okRef) {
                launch {
                    this.items = loadedRef
                    this.isLoading = false
                    this.hasError = false
                }
            } else {
                launch {
                    this.isLoading = false
                    this.hasError = true
                }
            }
        }
    }

    // ==================== 辅助方法（不在 build 中使用 let）====================

    private func unreadBadgeText(count: Int64): String {
        if (count > 99) {
            return "99+"
        }
        return "${count}"
    }

    private func avatarInitial(item: WidgetPeerItem): String {
        if (item.avatarText.size > 0) {
            let runes = item.avatarText.toRuneArray()
            if (runes.size > 0) {
                return runes[0].toString()
            }
        }
        return "?"
    }

    private func avatarBgColor(item: WidgetPeerItem): Int64 {
        let seed = item.peerId % 7
        if (seed == 0) { return 0x317AFF }
        else if (seed == 1) { return 0xFF3B30 }
        else if (seed == 2) { return 0xFF9500 }
        else if (seed == 3) { return 0x34C759 }
        else if (seed == 4) { return 0xAF52DE }
        else if (seed == 5) { return 0xFF2D55 }
        else { return 0x5AC8FA }
    }

    private func lastMessagePreview(item: WidgetPeerItem): String {
        let msg = item.lastMessage
        if (msg.size > 40) {
            let runes = msg.toRuneArray()
            var preview = ""
            var count: Int64 = 0
            for (r in runes) {
                if (count >= 40) { break }
                preview = preview + r.toString()
                count = count + 1
            }
            return preview + "..."
        }
        return msg
    }

    private func peerTypeLabel(item: WidgetPeerItem): String {
        if (item.isChannel) { return "Channel" }
        if (item.isGroup) { return "Group" }
        return ""
    }

    public func build() {
        Column {
            if (this.isLoading) {
                Row {
                    Text("Loading widget items...")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .height(48)
                .justifyContent(FlexAlign.Center)
            } else if (this.hasError) {
                Row {
                    Text("Could not load recent chats")
                        .fontSize(14)
                        .fontColor(0xFF3B30)
                }
                .width(100.percent)
                .height(48)
                .justifyContent(FlexAlign.Center)

                Button(trSource("Retry"))
                    .width(120)
                    .height(36)
                    .fontSize(14)
                    .borderRadius(18)
                    .backgroundColor(0x317AFF)
                    .fontColor(0xFFFFFF)
                    .margin(top: 8)
                    .onClick({ _evt =>
                        this.hasError = false
                        this.isLoading = true
                        let _ = spawn {
                            let svc = getWidgetItemsService()
                            var reloaded: ArrayList<WidgetPeerItem> = ArrayList<WidgetPeerItem>()
                            var reOk: Bool = false
                            try {
                                reloaded = svc.refreshWidgetItems()
                                reOk = true
                            } catch (_e2: Exception) {
                                reloaded = ArrayList<WidgetPeerItem>()
                                reOk = false
                            }
                            let reloadedRef = reloaded
                            let reOkRef = reOk
                            if (reOkRef) {
                                launch {
                                    this.items = reloadedRef
                                    this.isLoading = false
                                    this.hasError = false
                                }
                            } else {
                                launch {
                                    this.isLoading = false
                                    this.hasError = true
                                }
                            }
                        }
                    })
            } else if (this.items.size == 0) {
                Row {
                    Text("No recent chats")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .height(48)
                .justifyContent(FlexAlign.Center)
            } else {
                List {
                    ForEach(this.items, itemGenerator: { item: WidgetPeerItem, _idx: Int64 =>
                        ListItem {
                            Row {
                                // 头像区域
                                Stack {
                                    if (item.avatarLocalPath.size > 0) {
                                        Image(item.avatarLocalPath)
                                            .width(44)
                                            .height(44)
                                            .borderRadius(22)
                                            .objectFit(ImageFit.Cover)
                                    } else {
                                        Column {
                                            Text(this.avatarInitial(item))
                                                .fontSize(18)
                                                .fontColor(0xFFFFFF)
                                                .fontWeight(FontWeight.Medium)
                                        }
                                        .width(44)
                                        .height(44)
                                        .borderRadius(22)
                                        .backgroundColor(this.avatarBgColor(item))
                                        .justifyContent(FlexAlign.Center)
                                        .alignItems(HorizontalAlign.Center)
                                    }
                                }
                                .width(44)
                                .height(44)

                                // 内容区域
                                Column {
                                    Row {
                                        Text(item.name)
                                            .fontSize(15)
                                            .fontColor(0x000000)
                                            .fontWeight(FontWeight.Medium)
                                            .maxLines(1)
                                            .textOverflow(TextOverflow.Ellipsis)
                                            .layoutWeight(1)

                                        if (this.peerTypeLabel(item).size > 0) {
                                            Text(this.peerTypeLabel(item))
                                                .fontSize(11)
                                                .fontColor(0x8E8E93)
                                                .margin(left: 4)
                                        }
                                    }
                                    .width(100.percent)
                                    .alignItems(VerticalAlign.Center)

                                    Row {
                                        Text(this.lastMessagePreview(item))
                                            .fontSize(13)
                                            .fontColor(0x8E8E93)
                                            .maxLines(1)
                                            .textOverflow(TextOverflow.Ellipsis)
                                            .layoutWeight(1)

                                        if (item.unreadCount > 0 && !item.isMuted) {
                                            Text(this.unreadBadgeText(item.unreadCount))
                                                .fontSize(12)
                                                .fontColor(0xFFFFFF)
                                                .backgroundColor(0x317AFF)
                                                .borderRadius(10)
                                                .padding(left: 6, right: 6, top: 2, bottom: 2)
                                                .margin(left: 6)
                                                .fontWeight(FontWeight.Medium)
                                        } else if (item.unreadCount > 0 && item.isMuted) {
                                            Text(this.unreadBadgeText(item.unreadCount))
                                                .fontSize(12)
                                                .fontColor(0xFFFFFF)
                                                .backgroundColor(0xAAAAAA)
                                                .borderRadius(10)
                                                .padding(left: 6, right: 6, top: 2, bottom: 2)
                                                .margin(left: 6)
                                                .fontWeight(FontWeight.Medium)
                                        }
                                    }
                                    .width(100.percent)
                                    .margin(top: 3)
                                    .alignItems(VerticalAlign.Center)
                                }
                                .layoutWeight(1)
                                .padding(left: 10)
                                .alignItems(HorizontalAlign.Start)
                            }
                            .width(100.percent)
                            .height(60)
                            .padding(left: 12, right: 12)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _evt =>
                                let tapId = item.peerId
                                this.onItemTap(tapId)
                                Hilog.info(0, "CjTelegram", "[WidgetItemsComponent] tapped peer ${tapId}")
                            })
                        }
                    })
                }
                .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 68, endMargin: 0))
                .width(100.percent)
            }
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFF)
    }
}
