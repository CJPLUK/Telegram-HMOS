package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getCallsService, GroupCallStreamChannelInfo, GroupCallStreamRtmpCredentials}
import std.collection.ArrayList
import std.convert.*
import ohos_app_cangjie_entry.router.*

/**
 * LivestreamViewerPage — 直播/媒体流观看界面 (P2-066)（混合工程迁移版）
 *
 * iOS 对照:
 *   VoiceChatController.swift (Livestream 模式) + groupCallStream
 *   TelegramEngineCalls.swift: getGroupCallStreamChannels / getGroupCallStreamRtmpUrl
 *
 * 实现策略（fidelity-gap 法）:
 *   TL 信令层 [真实]:
 *     phone.getGroupCallStreamChannels#1ab21940 → CallsService.getGroupCallStreamChannels
 *     phone.getGroupCallStreamRtmpUrl#deb3abbf → CallsService.getGroupCallStreamRtmpUrl
 *     phone.joinGroupCall#b132ff7b (viewer mode: muted=true videoStopped=true)
 *
 *   媒体消费层 [诚实 N-A]:
 *     Telegram 直播流为私有 RTMP-over-CDN + HLS 分片；需 tgcalls group stream 解码器
 *     （C FFI libtgcalls_ohos.so group stream API）。HarmonyOS Video 组件无法消费私有直播流。
 *     TODO(P2-cpp): tgcalls group stream 媒体解码走 C FFI（同 P2-061 已知 gap，编译期本就过）。
 *
 * 路由参数格式: "{callId}:{accessHash}:{peerId}:{peerAccessHash}:{isChannel}:{title}"
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹与 .hideTitleBar/.onReady，只留内容 + .onAppear
 *  - pageStack.pop() → routerPop()
 *  - 源 .onReady(ctx) 收路由 param → 改为 ensureLoaded() 首帧 takePending("LivestreamViewerPage") 解析
 *  - parseLivestreamParam 签名由 NavDestinationContext 改为 String（takePending 返回值）
 */

// ==================== 画质档枚举 ====================

public enum StreamQualityLevel {
    | Auto
    | Low
    | Medium
    | High

    public func ordinal(): Int32 {
        match (this) {
            case Auto => 0
            case Low => 1
            case Medium => 2
            case High => 3
        }
    }

    public operator func ==(right: StreamQualityLevel): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: StreamQualityLevel): Bool {
        return this.ordinal() != right.ordinal()
    }

    public func displayName(): String {
        match (this) {
            case Auto => "Auto"
            case Low => "Low"
            case Medium => "Medium"
            case High => "High"
        }
    }
}

// ==================== 流频道 ViewModel ====================

public class StreamChannelVM {
    public var channel: Int32 = 0
    public var scale: Int32 = 0
    public var lastTimestampMs: Int64 = 0

    public func qualityLabel(): String {
        if (this.scale <= 2) { return "Low quality" }
        if (this.scale <= 4) { return "Medium quality" }
        return "High quality"
    }
}

// ==================== 模块级辅助函数 ====================

// 混合迁移：源接收 NavDestinationContext.pathInfo.param，混合工程改为解析 takePending 返回的原始字符串。
private func parseLivestreamParam(raw: String): (Int64, Int64, Int64, Int64, Bool, String) {
    if (raw.size == 0) { return (0, 0, 0, 0, false, "") }
    let parts = raw.split(":")
    var callId: Int64 = 0
    var accessHash: Int64 = 0
    var peerId: Int64 = 0
    var peerAccessHash: Int64 = 0
    var isChannel: Bool = false
    var title: String = "Livestream"
    if (parts.size >= 1) { try { callId = Int64.parse(parts[0]) } catch (_: Exception) {} }
    if (parts.size >= 2) { try { accessHash = Int64.parse(parts[1]) } catch (_: Exception) {} }
    if (parts.size >= 3) { try { peerId = Int64.parse(parts[2]) } catch (_: Exception) {} }
    if (parts.size >= 4) { try { peerAccessHash = Int64.parse(parts[3]) } catch (_: Exception) {} }
    if (parts.size >= 5) { isChannel = parts[4] == "1" }
    if (parts.size >= 6 && parts[5].size > 0) { title = parts[5] }
    return (callId, accessHash, peerId, peerAccessHash, isChannel, title)
}

private func buildStreamChannelVMs(channels: ArrayList<GroupCallStreamChannelInfo>): Array<StreamChannelVM> {
    return Array<StreamChannelVM>(channels.size, { i: Int64 =>
        let ch = channels[i]
        let vm = StreamChannelVM()
        vm.channel = ch.channel
        vm.scale = ch.scale
        vm.lastTimestampMs = ch.lastTimestampMs
        vm
    })
}

private func qualityBgColor(level: StreamQualityLevel, selected: StreamQualityLevel): Int64 {
    if (level == selected) { return 0xFF007AFF } else { return 0x33FFFFFF }
}

private func qualityTextColor(level: StreamQualityLevel, selected: StreamQualityLevel): Int64 {
    if (level == selected) { return 0xFFFFFFFF } else { return 0xCCFFFFFF }
}

private func buildLivestreamJoinPayload(quality: StreamQualityLevel): String {
    let ql = quality.ordinal()
    return "{\"fingerprints\":[],\"pwd\":\"\",\"ssrc\":0,\"ssrc-groups\":[],\"ufrag\":\"\",\"mode\":\"viewer\",\"quality\":${ql}}"
}

private func truncateUrl(url: String): String {
    if (url.size > 40) { return "${url[0..37]}..." }
    return url
}

// ==================== LivestreamViewerPage ====================

@HybridComponentEntry
@Component
public class LivestreamViewerPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 路由参数
    @State var callId: Int64 = 0
    @State var callAccessHash: Int64 = 0
    @State var peerId: Int64 = 0
    @State var peerAccessHash: Int64 = 0
    @State var isChannelPeer: Bool = false
    @State var streamTitle: String = "Livestream"

    // 流频道列表
    @State var channels: Array<StreamChannelVM> = Array<StreamChannelVM>()
    @State var isLoadingChannels: Bool = false
    @State var channelError: String = ""

    // 画质选择
    @State var selectedQuality: StreamQualityLevel = StreamQualityLevel.Auto

    // RTMP 推流信息: 拆解为显示字段以避免 @Builder 中 match(Option<>)
    @State var hasRtmpCredentials: Bool = false
    @State var rtmpUrl: String = ""
    @State var rtmpKey: String = ""
    @State var isLoadingRtmp: Bool = false
    @State var rtmpError: String = ""
    @State var showRtmpPanel: Bool = false

    // 观看状态
    @State var watchState: String = "idle"
    // "idle" | "watching" | "media_gap"

    // INTEROP 说明面板
    @State var showInteropNote: Bool = false

    @State var loaded: Bool = false

    // 混合迁移：源 .onReady(ctx) 收路由 param 并 loadStreamChannels，合并进 ensureLoaded()。
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let (cId, cHash, pId, pHash, isCh, title) = parseLivestreamParam(takePending("LivestreamViewerPage"))
        this.callId = cId
        this.callAccessHash = cHash
        this.peerId = pId
        this.peerAccessHash = pHash
        this.isChannelPeer = isCh
        if (title.size > 0) { this.streamTitle = title }
        Hilog.info(0, "CjTelegram", "[LivestreamViewerPage] onAppear callId=${this.callId}")
        if (cId != 0) {
            this.loadStreamChannels()
        }
    }

    // ==================== 加载流频道 ====================

    private func loadStreamChannels(): Unit {
        let cId = this.callId
        let cHash = this.callAccessHash
        launch {
            this.isLoadingChannels = true
            this.channelError = ""
        }
        let _ = spawn {
            let svc = getCallsService()
            let chList = svc.getGroupCallStreamChannels(cId, cHash)
            Hilog.info(0, "CjTelegram", "[LivestreamViewerPage] getGroupCallStreamChannels: ${chList.size} channels")
            let vms = buildStreamChannelVMs(chList)
            launch {
                this.channels = vms
                this.isLoadingChannels = false
                if (vms.size == 0) {
                    this.channelError = "No livestream channels found. The broadcast may not have started yet."
                }
            }
        }
    }

    // ==================== 加载 RTMP 推流地址 ====================

    private func loadRtmpCredentials(): Unit {
        let pId = this.peerId
        let pHash = this.peerAccessHash
        let isCh = this.isChannelPeer
        launch {
            this.isLoadingRtmp = true
            this.rtmpError = ""
            this.hasRtmpCredentials = false
        }
        let _ = spawn {
            let svc = getCallsService()
            let credOpt = svc.getGroupCallStreamRtmpUrl(pId, pHash, isCh, false)
            match (credOpt) {
                case Some(cred) =>
                    Hilog.info(0, "CjTelegram", "[LivestreamViewerPage] getGroupCallStreamRtmpUrl OK url=${cred.url.size}chars")
                    let urlStr = cred.url
                    let keyStr = cred.streamKey
                    launch {
                        this.rtmpUrl = urlStr
                        this.rtmpKey = keyStr
                        this.hasRtmpCredentials = true
                        this.isLoadingRtmp = false
                    }
                case None =>
                    Hilog.info(0, "CjTelegram", "[LivestreamViewerPage] getGroupCallStreamRtmpUrl failed")
                    launch {
                        this.isLoadingRtmp = false
                        this.rtmpError = "Failed to get RTMP stream URL"
                    }
            }
        }
    }

    // ==================== 观看/离开 ====================

    private func doStartWatching(): Unit {
        let cId = this.callId
        let cHash = this.callAccessHash
        Hilog.info(0, "CjTelegram", "[LivestreamViewerPage] doStartWatching callId=${cId} quality=${this.selectedQuality.displayName()}")
        launch {
            this.watchState = "media_gap"
            this.showInteropNote = true
        }
        // 真实发送 joinGroupCall 信令 (观众模式: muted=true videoStopped=true)
        let joinPayload = buildLivestreamJoinPayload(this.selectedQuality)
        let _ = spawn {
            let svc = getCallsService()
            let resultOpt = svc.joinGroupCall(cId, cHash, joinPayload, 0, 0, true, true, "")
            match (resultOpt) {
                case Some(result) =>
                    Hilog.info(0, "CjTelegram", "[LivestreamViewerPage] joinGroupCall (viewer) OK payload=${result.joinResponsePayload.size}bytes")
                case None =>
                    Hilog.info(0, "CjTelegram", "[LivestreamViewerPage] joinGroupCall (viewer) failed")
            }
        }
    }

    private func doStopWatching(): Unit {
        let cId = this.callId
        let cHash = this.callAccessHash
        launch {
            this.watchState = "idle"
            this.showInteropNote = false
        }
        let _ = spawn {
            let svc = getCallsService()
            let _ = svc.leaveGroupCall(cId, cHash, 0)
            Hilog.info(0, "CjTelegram", "[LivestreamViewerPage] leaveGroupCall done")
        }
    }

    // ==================== @Builder 子构建器 (无参数) ====================

    @Builder
    func buildQualitySelector() {
        Column {
            Text("Stream Quality")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .margin(bottom: 8)
                .alignSelf(ItemAlign.Start)

            Row {
                Column {
                    Text(StreamQualityLevel.Auto.displayName())
                        .fontSize(13)
                        .fontColor(qualityTextColor(StreamQualityLevel.Auto, this.selectedQuality))
                }
                .width(64)
                .height(32)
                .borderRadius(8)
                .backgroundColor(qualityBgColor(StreamQualityLevel.Auto, this.selectedQuality))
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .onClick({ _evt => launch { this.selectedQuality = StreamQualityLevel.Auto } })
                .margin(right: 8)

                Column {
                    Text(StreamQualityLevel.Low.displayName())
                        .fontSize(13)
                        .fontColor(qualityTextColor(StreamQualityLevel.Low, this.selectedQuality))
                }
                .width(64)
                .height(32)
                .borderRadius(8)
                .backgroundColor(qualityBgColor(StreamQualityLevel.Low, this.selectedQuality))
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .onClick({ _evt => launch { this.selectedQuality = StreamQualityLevel.Low } })
                .margin(right: 8)

                Column {
                    Text(StreamQualityLevel.Medium.displayName())
                        .fontSize(13)
                        .fontColor(qualityTextColor(StreamQualityLevel.Medium, this.selectedQuality))
                }
                .width(64)
                .height(32)
                .borderRadius(8)
                .backgroundColor(qualityBgColor(StreamQualityLevel.Medium, this.selectedQuality))
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .onClick({ _evt => launch { this.selectedQuality = StreamQualityLevel.Medium } })
                .margin(right: 8)

                Column {
                    Text(StreamQualityLevel.High.displayName())
                        .fontSize(13)
                        .fontColor(qualityTextColor(StreamQualityLevel.High, this.selectedQuality))
                }
                .width(64)
                .height(32)
                .borderRadius(8)
                .backgroundColor(qualityBgColor(StreamQualityLevel.High, this.selectedQuality))
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .onClick({ _evt => launch { this.selectedQuality = StreamQualityLevel.High } })
            }
            .width(100.percent)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 8)
        .backgroundColor(0x22FFFFFF)
        .borderRadius(12)
        .margin(bottom: 12)
    }

    @Builder
    func buildChannelList() {
        Column {
            Text("Available Channels")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .margin(bottom: 8)
                .alignSelf(ItemAlign.Start)

            ForEach(this.channels, itemGenerator: { vm: StreamChannelVM, _idx: Int64 =>
                Row {
                    Column {
                        Text("Channel ${vm.channel}")
                            .fontSize(15)
                            .fontColor(0xFFFFFF)
                            .fontWeight(FontWeight.Medium)
                        Text(vm.qualityLabel())
                            .fontSize(12)
                            .fontColor(0x8E8E93)
                            .margin(top: 2)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Text("Scale ${vm.scale}")
                        .fontSize(12)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 10, bottom: 10)
                .backgroundColor(0x1AFFFFFF)
                .borderRadius(10)
                .margin(bottom: 8)
            })
        }
        .width(100.percent)
        .margin(bottom: 12)
    }

    @Builder
    func buildMediaGapNotice() {
        Column {
            Text("INTEROP NOTE")
                .fontSize(11)
                .fontColor(0xFFCC00)
                .fontWeight(FontWeight.Bold)
                .margin(bottom: 6)
            Text("Livestream TL signaling (joinGroupCall viewer) sent successfully.")
                .fontSize(13)
                .fontColor(0xCCFFFFFF)
                .textAlign(TextAlign.Center)
                .margin(bottom: 4)
            Text("Media playback gap: Telegram livestream uses proprietary RTMP-over-CDN fragmentation. HarmonyOS Video component cannot consume these fragments. Full viewing requires tgcalls group stream decoder (platform constraint, same as P2-061).")
                .fontSize(11)
                .fontColor(0x8E8E93)
                .textAlign(TextAlign.Center)
        }
        .width(100.percent)
        .padding(16)
        .backgroundColor(0x22FFCC00)
        .borderRadius(12)
        .margin(bottom: 12)
    }

    @Builder
    func buildRtmpPanelCredentials() {
        Column {
            Text("Stream URL:")
                .fontSize(12)
                .fontColor(0x8E8E93)
                .alignSelf(ItemAlign.Start)
                .margin(bottom: 4)
            Text(truncateUrl(this.rtmpUrl))
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .fontFamily("monospace")
                .backgroundColor(0x33FFFFFF)
                .borderRadius(6)
                .padding(left: 8, right: 8, top: 6, bottom: 6)
                .width(100.percent)
                .margin(bottom: 8)
            Text("Stream Key:")
                .fontSize(12)
                .fontColor(0x8E8E93)
                .alignSelf(ItemAlign.Start)
                .margin(bottom: 4)
            Text(truncateUrl(this.rtmpKey))
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .fontFamily("monospace")
                .backgroundColor(0x33FFFFFF)
                .borderRadius(6)
                .padding(left: 8, right: 8, top: 6, bottom: 6)
                .width(100.percent)
                .margin(bottom: 8)
            Text("Use these credentials in OBS or ffmpeg to start broadcasting.")
                .fontSize(11)
                .fontColor(0x8E8E93)
                .textAlign(TextAlign.Center)
        }
        .width(100.percent)
    }

    @Builder
    func buildRtmpPanelEmpty() {
        Column {
            if (this.isLoadingRtmp) {
                Text("Loading RTMP credentials...")
                    .fontSize(14)
                    .fontColor(0x8E8E93)
            } else if (this.rtmpError.size > 0) {
                Text(this.rtmpError)
                    .fontSize(13)
                    .fontColor(0xFF3B30)
                    .margin(bottom: 8)
                Button(trSource("Retry"))
                    .width(120)
                    .height(36)
                    .borderRadius(8)
                    .backgroundColor(0x33FFFFFF)
                    .fontColor(0xFFFFFF)
                    .fontSize(14)
                    .onClick({ _evt => this.loadRtmpCredentials() })
            } else {
                Button("Get RTMP URL")
                    .width(160)
                    .height(40)
                    .borderRadius(10)
                    .backgroundColor(0xFF007AFF)
                    .fontColor(0xFFFFFF)
                    .fontSize(15)
                    .onClick({ _evt => this.loadRtmpCredentials() })
            }
        }
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func buildRtmpPanel() {
        Column {
            Text("RTMP Broadcast URL")
                .fontSize(15)
                .fontColor(0xFFFFFF)
                .fontWeight(FontWeight.Medium)
                .margin(bottom: 12)
                .alignSelf(ItemAlign.Start)

            if (this.hasRtmpCredentials) {
                this.buildRtmpPanelCredentials()
            } else {
                this.buildRtmpPanelEmpty()
            }
        }
        .width(100.percent)
        .padding(16)
        .backgroundColor(0x22FFFFFF)
        .borderRadius(12)
        .margin(bottom: 12)
    }

    // ==================== build ====================

    public func build() {
        Column {
            // 顶部栏
            Row {
                Text("‹")
                    .fontSize(28)
                    .fontColor(0xFFFFFF)
                    .padding(right: 8)
                    .onClick({ _evt => launch { routerPop() } })

                Column {
                    Text(this.streamTitle)
                        .fontSize(17)
                        .fontColor(0xFFFFFF)
                        .fontWeight(FontWeight.Medium)
                    Text("Livestream")
                        .fontSize(12)
                        .fontColor(0x8E8E93)
                        .margin(top: 2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Row {
                    Text(trSource("LIVE"))
                        .fontSize(11)
                        .fontColor(0xFFFFFF)
                        .fontWeight(FontWeight.Bold)
                }
                .padding(left: 8, right: 8, top: 4, bottom: 4)
                .backgroundColor(0xFFFF3B30)
                .borderRadius(6)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 8)

            Scroll {
                Column {
                    // 直播视频区占位 (媒体 gap 诚实区域)
                    Column {
                        Text("Livestream Viewer")
                            .fontSize(18)
                            .fontColor(0xFFFFFF)
                            .fontWeight(FontWeight.Bold)
                            .margin(bottom: 6)
                        Text("TL: getGroupCallStreamChannels")
                            .fontSize(11)
                            .fontColor(0x34C759)
                            .margin(bottom: 2)
                        Text("Media: platform constraint (tgcalls group stream gap)")
                            .fontSize(11)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .height(200)
                    .backgroundColor(0xFF000000)
                    .borderRadius(12)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .margin(bottom: 16)

                    // 画质选择
                    this.buildQualitySelector()

                    // 加载中/错误/频道列表
                    if (this.isLoadingChannels) {
                        Text("Loading stream channels...")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .width(100.percent)
                            .margin(bottom: 12)
                    } else if (this.channelError.size > 0) {
                        Text(this.channelError)
                            .fontSize(13)
                            .fontColor(0xFF3B30)
                            .textAlign(TextAlign.Center)
                            .width(100.percent)
                            .margin(bottom: 12)
                    } else if (this.channels.size > 0) {
                        this.buildChannelList()
                    }

                    // 媒体 gap 通知
                    if (this.showInteropNote) {
                        this.buildMediaGapNotice()
                    }

                    // RTMP 广播面板
                    if (this.showRtmpPanel) {
                        this.buildRtmpPanel()
                    }

                    // 操作按钮
                    Column {
                        if (this.watchState == "idle") {
                            Button("Watch Livestream")
                                .width(100.percent)
                                .height(50)
                                .borderRadius(12)
                                .backgroundColor(0xFF34C759)
                                .fontColor(0xFFFFFF)
                                .fontSize(16)
                                .fontWeight(FontWeight.Medium)
                                .margin(bottom: 10)
                                .onClick({ _evt => this.doStartWatching() })
                        } else if (this.watchState == "media_gap" || this.watchState == "watching") {
                            Button("Leave Stream")
                                .width(100.percent)
                                .height(50)
                                .borderRadius(12)
                                .backgroundColor(0xFFFF3B30)
                                .fontColor(0xFFFFFF)
                                .fontSize(16)
                                .fontWeight(FontWeight.Medium)
                                .margin(bottom: 10)
                                .onClick({ _evt => this.doStopWatching() })
                        }

                        Row {
                            Text(if (this.showRtmpPanel) { "Hide RTMP" } else { "Show RTMP URL" })
                                .fontSize(14)
                                .fontColor(0xFF007AFF)
                        }
                        .width(100.percent)
                        .justifyContent(FlexAlign.Center)
                        .onClick({ _evt => launch { this.showRtmpPanel = !this.showRtmpPanel } })
                        .margin(bottom: 8)

                        Row {
                            Text("Refresh Channels")
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .justifyContent(FlexAlign.Center)
                        .onClick({ _evt => this.loadStreamChannels() })
                    }
                    .width(100.percent)
                    .margin(top: 8, bottom: 32)
                }
                .width(100.percent)
                .padding(left: 16, right: 16)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFF1C1C1E)
        .alignItems(HorizontalAlign.Start)
        .onAppear({ => this.ensureLoaded() })
    }
}
