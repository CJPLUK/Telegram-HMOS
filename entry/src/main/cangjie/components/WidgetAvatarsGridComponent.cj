package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
/**
 * WidgetAvatarsGridComponent — P2-434
 *
 * 头像网格 Avatars Widget（应用内 preview 版本）。
 *
 * iOS 对应：Telegram WidgetKit 中的 Avatars widget（联系人头像 2x2 网格）。
 * HarmonyOS：应用内头像网格组件；桌面卡片渲染由 ArkTS WidgetCard.ets 实现（真平台边界）。
 *
 * PLATFORM BOUNDARY NOTE:
 *   真实桌面卡片（主屏长按添加）渲染在 ArkTS 受限运行时（entry/src/main/ets/widget/WidgetCard.ets）。
 *   本组件为应用内 widget preview 及设置界面中的预览展示。
 *   点头像 deeplink 通过 onPeerTap 回调传给父级导航处理。
 *
 * 头像网格布局（iOS Avatars widget）：
 *   最多 4 个头像：2列 × 2行 (medium widget) 或 1行 × 4 (large)
 *   每个头像带未读角标（badgeCount > 0 时右上角红点）
 *   点头像 → deeplink 到对应会话
 *
 * @State 自查（无 dangling）：
 *   peers      — aboutToAppear → spawn → launch 写入 ✓
 *   isLoading  — aboutToAppear → spawn → launch 写入 ✓
 *   hasError   — aboutToAppear → spawn → launch 写入 ✓
 */

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getWidgetItemsServiceV2
import ohos_app_cangjie_entry.services.getWidgetStorageService
import ohos_app_cangjie_entry.models.WidgetData
import ohos_app_cangjie_entry.models.WidgetDataPeer

@Component
public class WidgetAvatarsGridComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 头像列表（最多 4 个）
    @State var peers: Array<WidgetDataPeer> = Array<WidgetDataPeer>(0, { _ => WidgetDataPeer() })
    @State var isLoading: Bool = false
    @State var hasError: Bool = false

    // 点头像 deeplink 回调（传 peerId，父级导航到会话）
    public var onPeerTap: (Int64) -> Unit = { _id: Int64 => }

    public override func aboutToAppear(): Unit {
        this.isLoading = true
        this.hasError = false
        let _ = spawn {
            let svc = getWidgetItemsServiceV2()
            var ok: Bool = false
            var peersResult: Array<WidgetDataPeer> = Array<WidgetDataPeer>(0, { _ => WidgetDataPeer() })
            try {
                let wd: WidgetData = svc.refreshWidgetData()
                peersResult = this.extractTopPeers(wd)
                ok = true
                // 应用内 widget 预览每次刷新都同步落盘到 distributedKVStore，
                // 让桌面卡片进程（FormExtensionAbility/ArkTS，P2-435 ic_widget_card_arkts_host
                // 外包交付）下次读取拿到最新数据；context 由 AppStartup.cj 的
                // setWidgetStorageContext() 在应用启动时注入，此处调用时已就绪。
                let _ = getWidgetStorageService().persistWidgetData()
            } catch (_e: Exception) {
                ok = false
            }
            let okRef = ok
            let peersRef = peersResult
            launch {
                if (okRef) {
                    this.peers = peersRef
                    this.hasError = false
                } else {
                    this.hasError = true
                }
                this.isLoading = false
            }
        }
    }

    // ============================================================
    // 辅助方法（不在 build 中使用 let，S-005/D-116 合规）
    // ============================================================

    private func extractTopPeers(data: WidgetData): Array<WidgetDataPeer> {
        match (data.content) {
            case None => return Array<WidgetDataPeer>(0, { _ => WidgetDataPeer() })
            case Some(dp) =>
                let maxCount: Int64 = if (dp.peers.size < 4) { dp.peers.size } else { 4 }
                return Array<WidgetDataPeer>(maxCount, { i: Int64 => dp.peers[i] })
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
        if (count > 9) { return "9+" }
        return "${count}"
    }

    private func avatarBgColor(peer: WidgetDataPeer): Int64 {
        let seed = peer.id % 6
        if (seed == 0) { return 0x317AFF }
        else if (seed == 1) { return 0xFF3B30 }
        else if (seed == 2) { return 0xFF9500 }
        else if (seed == 3) { return 0x34C759 }
        else if (seed == 4) { return 0xAF52DE }
        else { return 0xFF2D55 }
    }

    private func avatarLabel(peer: WidgetDataPeer): String {
        return peer.primaryLetter()
    }

    // ============================================================
    // build()
    // ============================================================

    public func build() {
        Column {
            if (this.isLoading) {
                this.buildLoadingView()
            } else if (this.hasError) {
                this.buildErrorView()
            } else if (this.peers.size == 0) {
                this.buildEmptyView()
            } else {
                this.buildAvatarGrid()
            }
        }
        .width(100.percent)
        .backgroundColor(0xF2F2F7)
        .borderRadius(16)
        .padding(12)
    }

    @Builder
    func buildLoadingView() {
        Row {
            Text(trSource("Loading..."))
                .fontSize(13)
                .fontColor(0x8E8E93)
        }
        .width(100.percent)
        .height(80)
        .justifyContent(FlexAlign.Center)
    }

    @Builder
    func buildErrorView() {
        Row {
            Text("Unable to load contacts")
                .fontSize(13)
                .fontColor(0x8E8E93)
        }
        .width(100.percent)
        .height(80)
        .justifyContent(FlexAlign.Center)
    }

    @Builder
    func buildEmptyView() {
        Column {
            Text("No recent contacts")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .textAlign(TextAlign.Center)
        }
        .width(100.percent)
        .height(80)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func buildAvatarGrid() {
        // 2x2 网格布局（最多 4 个头像）
        Grid {
            ForEach(this.peers, itemGenerator: { peer: WidgetDataPeer, _idx: Int64 =>
                GridItem {
                    Stack(alignContent: Alignment.TopEnd) {
                        // 头像
                        Column {
                            if (peer.hasAvatarPath) {
                                Image(peer.avatarPath)
                                    .width(56)
                                    .height(56)
                                    .borderRadius(28)
                                    .objectFit(ImageFit.Cover)
                            } else {
                                Column {
                                    Text(this.avatarLabel(peer))
                                        .fontSize(22)
                                        .fontColor(0xFFFFFF)
                                        .fontWeight(FontWeight.Medium)
                                }
                                .width(56)
                                .height(56)
                                .borderRadius(28)
                                .backgroundColor(this.avatarBgColor(peer))
                                .justifyContent(FlexAlign.Center)
                                .alignItems(HorizontalAlign.Center)
                            }
                        }

                        // 未读角标（iOS Avatars widget: badgeCount > 0 时右上角）
                        if (this.badgeCount(peer) > 0) {
                            Text(this.badgeText(this.badgeCount(peer)))
                                .fontSize(10)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(
                                    if (this.badgeMuted(peer)) { 0xAAAAAA } else { 0xFF3B30 })
                                .borderRadius(8)
                                .padding(left: 4, right: 4, top: 2, bottom: 2)
                                .fontWeight(FontWeight.Medium)
                        }
                    }
                    .width(56)
                    .height(56)
                    .onClick({ _evt =>
                        let tapId = peer.id
                        Hilog.info(0, "CjTelegram", "[WidgetAvatarsGridComponent] tapped peer ${tapId}")
                        this.onPeerTap(tapId)
                    })
                }
                .padding(4)
            })
        }
        .columnsTemplate("1fr 1fr")
        .rowsGap(8)
        .columnsGap(8)
        .width(100.percent)
        .height(140)
    }
}
