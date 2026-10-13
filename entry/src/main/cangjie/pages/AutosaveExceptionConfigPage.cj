package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings, PresentationSnapshot, currentPresentation}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.ArkData.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getSaveToCameraRollService
import ohos_app_cangjie_entry.services.getGlobalAbilityContext
import ohos_app_cangjie_entry.services.{MediaAutoSaveException, encodeMediaAutoSaveExceptions, decodeMediaAutoSaveExceptions}
import ohos_app_cangjie_entry.services.getRealChatListService
import ohos_app_cangjie_entry.services.getUserPhotoService
import ohos_app_cangjie_entry.services.autodownloadDataSizeString
import ohos_app_cangjie_entry.core.mtproto.UserResponse
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSectionFooter,
    ItemListToggleRow,
    ItemListSeparator,
    ITEM_LIST_ACCENT,
    Avatar
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.dispatchEvent
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import std.collection.ArrayList
import std.convert.*
import std.time.DateTime

/**
 * AutosaveExceptionConfigPage — diag-suite_settings_data_storage-TC-0424-round7.md F-1。
 * GRANT (2026-09-01, main/supervisor，commit 3770dcd4a)：零归属新文件，两侧归属独立核过
 * （目标侧 target_files 零命中；源侧 owned_source_files 显示
 * `SaveIncomingMediaController.swift` 的 owner 就是 set_data_and_storage_root 自己）。
 *
 * 承载源侧 `saveIncomingMediaController(scope:)` 的 `.addPeer`(暂存态) / `.peer`(编辑态)
 * 两个 scope（此前误收在 `AutosaveExceptionPeerSelectionPage.cj` 内部的 `pickerPhase`
 * 假态里，导致 push/标题/首行三处结构性缺陷——round7 F-1 拆分修复）。
 *
 * 路由参数：
 *   `routerPush("AutosaveExceptionConfigPage", "<peerType>|<peerId>|new")` —— 对位
 *   `.addPeer` scope，来自选择器新选中一个候选（`AutosaveExceptionPeerSelectionPage.
 *   selectCandidate` 的「否则」分叉）。默认配置 photo=false/video=false/max=100MB，
 *   改动只暂存在内存，提交（右上对勾）才一次性写盘，随后连续两次 `routerPop()`
 *   （对位源侧 `:558-571 dismissAll`，同时移除本屏与选择器）。
 *   `routerPush("AutosaveExceptionConfigPage", "<peerType>|<peerId>")` —— 对位 `.peer`
 *   scope，从例外行直接点进编辑（`SaveIncomingMediaPage.openEditException`）。
 *   `routerReplaceTop("AutosaveExceptionConfigPage", "<peerType>|<peerId>")` —— 同样是
 *   `.peer` scope，来自选择器选中一个"已是例外"的候选（`selectCandidate` 的「若」分叉，
 *   对位源侧 `:518-530` 选中后判定 + `setViewControllers` 替换）。`.peer` scope 下每次
 *   改动（Photos/Videos 开关、滑杆）都立即读盘定位该 peerId、改字段、写回、flush
 *   （对位源侧 `:401-497` scope 分支「拨动即写」），右上对勾只做出栈（一次
 *   `routerPop()`，源侧 `:678 default: dismiss?()`），不重复写盘；`Back` 同样只出栈，
 *   不回滚（已即时落盘，没有回滚概念）。
 *
 * 持久化：与 `SaveIncomingMediaPage.cj` / `AutosaveExceptionPeerSelectionPage.cj` 共享
 * 同一个 store `telegram_autosave_media`、同一个键 `<peerType>_exceptions`，编解码复用
 * `SaveIncomingMediaPage.cj` 已声明的 `MediaAutoSaveException`/
 * `encodeMediaAutoSaveExceptions`/`decodeMediaAutoSaveExceptions`（同包 `pages` 内默认
 * internal 可见性，无需 import）。
 *
 * 模态登记（D-166，round7 F-1(4)）：`entry/src/main/ets/router/CustomTransition.ets` 的
 * `MODAL_ROUTES` 与 `entry/src/main/cangjie/router/router.cj` 的 `isModalRoute()` 均不在
 * 本 feature allowlist（owner `shell_settings_misc` 等）——已按 `emitted_integration_
 * contracts[]` 上报，Worker 不自行改这两个文件。选择器路由
 * `AutosaveExceptionPeerSelectionPage` 保持不登记（继续 push），只登记本路由为 modal。
 */

// ── 例外配置页专属滑杆锚点表（页面间不共享私有工具函数，各自独立演进——同
// SaveIncomingMediaPage.cj / 拆分前 AutosaveExceptionPeerSelectionPage.cj 既定惯例）。
private class ConfigSizeAnchor {
    public var pos: Float64
    public var bytes: Int64
    public init(pos!: Float64, bytes!: Int64) {
        this.pos = pos
        this.bytes = bytes
    }
}

private let CONFIG_SLIDER_POS_SCALE: Float64 = 1000.0

private func configSizeAnchors(): Array<ConfigSizeAnchor> {
    return [
        ConfigSizeAnchor(pos: 0.000, bytes: 512 * 1024),
        ConfigSizeAnchor(pos: 0.257, bytes: 1024 * 1024),
        ConfigSizeAnchor(pos: 0.520, bytes: 10 * 1024 * 1024),
        ConfigSizeAnchor(pos: 0.763, bytes: 100 * 1024 * 1024),
        ConfigSizeAnchor(pos: 1.000, bytes: 1536 * 1024 * 1024)
    ]
}

private func configSliderPosForSize(size: Int64): Float64 {
    let anchors = configSizeAnchors()
    var i: Int64 = 1
    while (i < anchors.size) {
        let prev = anchors[i - 1]
        let cur = anchors[i]
        if (cur.bytes > size) {
            return prev.pos + Float64(size - prev.bytes) / Float64(cur.bytes - prev.bytes) * (cur.pos - prev.pos)
        } else if (prev.bytes == size) {
            return prev.pos
        } else if (cur.bytes == size || i == anchors.size - 1) {
            return cur.pos
        }
        i += 1
    }
    return 0.0
}

private func configSizeForSliderPos(pos: Float64): Int64 {
    let anchors = configSizeAnchors()
    var i: Int64 = 1
    while (i < anchors.size) {
        let prev = anchors[i - 1]
        let cur = anchors[i]
        if (cur.pos > pos) {
            let delta = (pos - prev.pos) / (cur.pos - prev.pos) * Float64(cur.bytes - prev.bytes)
            return prev.bytes + Int64(delta)
        } else if (prev.pos == pos) {
            return prev.bytes
        } else if (cur.pos == pos || i == anchors.size - 1) {
            return cur.bytes
        }
        i += 1
    }
    return anchors[anchors.size - 1].bytes
}

// ── formatPeerStatus / formatLastSeenForPeer 逐字镜像自 services/ItemListPeerService.cj
// （该文件 internal 可见性，pages 包不可见，不在本轮 allowlist——D-195 明确认可的降级路径，
// 照抄，不改判定分支或阈值）。──
private func configFormatPeerStatus(user: UserResponse): String {
    if (user.statusType == "online") {
        return "online"
    }
    if (user.statusType == "recently") {
        return "last seen recently"
    }
    if (user.statusType == "lastWeek") {
        return "last seen within a week"
    }
    if (user.statusType == "lastMonth") {
        return "last seen within a month"
    }
    if (user.wasOnline > 0) {
        return configFormatLastSeenForPeer(user.wasOnline)
    }
    if (user.isBot) {
        return "bot"
    }
    return "last seen a long time ago"
}

private func configFormatLastSeenForPeer(wasOnline: Int32): String {
    let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let nowSec = Int64(nowMs) / 1000
    let diff = nowSec - Int64(wasOnline)

    if (diff < 60) {
        return "last seen just now"
    }
    if (diff < 3600) {
        let mins = diff / 60
        return "last seen ${mins} minutes ago"
    }
    if (diff < 86400) {
        let hours = diff / 3600
        return "last seen ${hours} hours ago"
    }
    if (diff < 172800) {
        return "last seen yesterday"
    }
    if (diff < 604800) {
        let days = diff / 86400
        return "last seen ${days} days ago"
    }
    return "last seen a long time ago"
}

@HybridComponentEntry
@Component
public class AutosaveExceptionConfigPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var peerType: String = "private"
    @State var paramParsed: Bool = false
    @State var loaded: Bool = false

    @State var selectedPeerId: Int64 = -1
    @State var selectedDisplayName: String = ""
    @State var selectedAvatarPath: String = ""
    @State var selectedStatusText: String = ""
    // true = .addPeer scope（暂存，提交才写盘，双重 pop）；false = .peer scope（拨动即写，
    // 单次 pop）。由路由参数尾缀 `|new` 决定，不靠栈深度猜（round7 F-2 边界）。
    @State var isNew: Bool = true

    @State var photoOn: Bool = false
    @State var videoOn: Bool = false
    @State var maxVideoSizeBytes: Int64 = 100 * 1024 * 1024
    @State var sliderPos: Float64 = 0.0
    @State var sizeLabel: String = ""
    @State var videoInfoLabel: String = ""

    private func parseRouteParamOnce(): Unit {
        if (this.paramParsed) { return }
        this.paramParsed = true
        let raw = takePending("AutosaveExceptionConfigPage")
        if (raw.size == 0 || raw == "{}") { return }
        let trimmed = raw.trimAscii()
        let parts = trimmed.split("|")
        if (parts.size >= 1 && parts[0].size > 0) {
            let pt = parts[0]
            if (pt == "groups" || pt == "channels") {
                this.peerType = pt
            } else {
                this.peerType = "private"
            }
        }
        if (parts.size >= 2) {
            try {
                this.selectedPeerId = Int64.parse(parts[1])
            } catch (_e: Exception) {}
        }
        this.isNew = (parts.size >= 3 && parts[2] == "new")
    }

    private func resolveDisplayName(peerId: Int64): String {
        if (this.peerType == "private") {
            match (getRealChatListService().getCachedUser(peerId)) {
                case Some(u) =>
                    var name = u.firstName
                    if (u.lastName.size > 0) { name = "${u.firstName} ${u.lastName}" }
                    if (name.size == 0) { name = "User ${peerId}" }
                    return name
                case None => return "User ${peerId}"
            }
        }
        match (getRealChatListService().getCachedChat(peerId)) {
            case Some(c) =>
                if (c.title.size > 0) { return c.title }
                return "Chat ${peerId}"
            case None => return "Chat ${peerId}"
        }
    }

    private func resolveAvatarPath(peerId: Int64): String {
        if (this.peerType == "private") {
            return getUserPhotoService().getUserPhotoPath(peerId)
        }
        return getUserPhotoService().getChatPhotoPath(peerId)
    }

    // 状态串只在 private 且能取到 UserResponse 缓存时有值（对位 :196 getCachedUser(peerId)
    // 返回 None 时状态行渲染空串，不渲染占位、不报错）；groups/channels 无「上次在线」概念。
    private func resolveStatusText(peerId: Int64): String {
        if (this.peerType != "private") { return "" }
        match (getRealChatListService().getCachedUser(peerId)) {
            case Some(u) => return configFormatPeerStatus(u)
            case None => return ""
        }
    }

    private func refreshSizeLabel(): Unit {
        this.sizeLabel = "up to ${autodownloadDataSizeString(this.maxVideoSizeBytes)}"
        // Source `Autosave.VideoInfo` is one localized string shared by every scope;
        // it is not interpolated with the selected peer category.
        this.videoInfoLabel = "All downloaded videos in private chats less than ${autodownloadDataSizeString(this.maxVideoSizeBytes)} will be saved to your Photos app."
    }

    // ── .addPeer 默认配置（不继承类别屏当前值，TC-0424 已实测确认）；.peer 从磁盘表按
    // peerId 定位现值预填，查不到（理论上不该发生）退回默认值。 ──
    private func loadInitialState(): Unit {
        this.selectedDisplayName = this.resolveDisplayName(this.selectedPeerId)
        this.selectedAvatarPath = this.resolveAvatarPath(this.selectedPeerId)
        this.selectedStatusText = this.resolveStatusText(this.selectedPeerId)
        if (this.isNew) {
            this.photoOn = false
            this.videoOn = false
            this.maxVideoSizeBytes = 100 * 1024 * 1024
        } else {
            let list = decodeMediaAutoSaveExceptions(
                getSaveToCameraRollService().getMediaSettingString(
                    "${this.peerType}_exceptions", ""))
            var i: Int64 = 0
            var found = false
            while (i < list.size) {
                if (list[i].peerId == this.selectedPeerId) {
                    this.photoOn = list[i].photo
                    this.videoOn = list[i].video
                    this.maxVideoSizeBytes = list[i].maximumVideoSize
                    found = true
                }
                i += 1
            }
            if (!found) {
                this.photoOn = false
                this.videoOn = false
                this.maxVideoSizeBytes = 100 * 1024 * 1024
            }
        }
        this.sliderPos = configSliderPosForSize(this.maxVideoSizeBytes)
        this.refreshSizeLabel()
    }

    // ── .peer scope：每次改动立即读盘 → 按 peerId 定位 → 改字段 → 写回 → flush（对位
    // 源侧 :401-497 scope 分支「拨动即写」）。定位不到该 peerId 时什么都不做（源侧
    // :407 firstIndex(where:) 找不到即 no-op，不插入新条）。 ──
    private func persistCurrent(): Unit {
        if (this.selectedPeerId < 0) { return }
        let svc = getSaveToCameraRollService()
        let current = decodeMediaAutoSaveExceptions(
            svc.getMediaSettingString("${this.peerType}_exceptions", ""))
        let out = ArrayList<MediaAutoSaveException>()
        var found = false
        var i: Int64 = 0
        while (i < current.size) {
            if (current[i].peerId == this.selectedPeerId) {
                out.add(MediaAutoSaveException(
                    peerId: this.selectedPeerId,
                    photo: this.photoOn,
                    video: this.videoOn,
                    maximumVideoSize: this.maxVideoSizeBytes
                ))
                found = true
            } else {
                out.add(current[i])
            }
            i += 1
        }
        if (found) {
            svc.setMediaSettingString(
                "${this.peerType}_exceptions", encodeMediaAutoSaveExceptions(out))
        }
    }

    private func onTogglePhoto(isOn: Bool): Unit {
        this.photoOn = isOn
        if (!this.isNew) { this.persistCurrent() }
    }

    private func onToggleVideo(isOn: Bool): Unit {
        this.videoOn = isOn
        if (!this.isNew) { this.persistCurrent() }
    }

    private func onSlide(pos: Float64): Unit {
        this.sliderPos = pos
        this.maxVideoSizeBytes = configSizeForSliderPos(pos)
        this.refreshSizeLabel()
        if (!this.isNew) { this.persistCurrent() }
    }

    // ── .addPeer 提交：先重新从磁盘读一次最新表（避免覆盖并发写入），按 peerId 去重
    // 删除旧条目，新条目插到表头（对位源侧 :544-546），编码写回。 ──
    private func persistNewEntry(): Unit {
        let svc = getSaveToCameraRollService()
        let current = decodeMediaAutoSaveExceptions(
            svc.getMediaSettingString("${this.peerType}_exceptions", ""))
        let filtered = ArrayList<MediaAutoSaveException>()
        var i: Int64 = 0
        while (i < current.size) {
            if (current[i].peerId != this.selectedPeerId) {
                filtered.add(current[i])
            }
            i += 1
        }
        let newEntry = MediaAutoSaveException(
            peerId: this.selectedPeerId,
            photo: this.photoOn,
            video: this.videoOn,
            maximumVideoSize: this.maxVideoSizeBytes
        )
        let out = ArrayList<MediaAutoSaveException>()
        out.add(newEntry)
        var j: Int64 = 0
        while (j < filtered.size) {
            out.add(filtered[j])
            j += 1
        }
        svc.setMediaSettingString(
            "${this.peerType}_exceptions", encodeMediaAutoSaveExceptions(out))
        Hilog.info(0, "CjTelegram", "[AutosaveExceptionConfig] saved new peerId=${this.selectedPeerId} photo=${this.photoOn} video=${this.videoOn} maxVideoSize=${this.maxVideoSizeBytes}")
    }

    // diag-suite_settings_data_storage-TC-0424-round8.md 缺陷 A（B5）：`.peer` 语义下
    // 从 S2 直接 routerPush 进本页（无中间标准 push 层），S2 全程未被真正隐藏过，弹出后
    // 不会收到 onShown，`SaveIncomingMediaPage.loadExceptions()` 不会被调用，导致返回列表
    // 后看不到刚编辑的新值。DIALOG 呈现方式本身不改（round7 F-1(4) 按案文要求的正确呈现），
    // 改为离开 `.peer` 作用域前主动派发一次与 `.ets` 壳 onShown 同款的事件，效果对齐源侧
    // 「每次可见都重新 diff」。事件名逐字复用 `SaveIncomingMediaPage.ets` 的
    // `SAVE_INCOMING_MEDIA_SHOWN_EVENT` 字面量 'settings.saveIncomingMedia.shown'，不新造
    // 事件名；不给 `.addPeer` 分支加同样派发——它已靠「弹出两层、途经标准 push 的选择器」
    // 天然触发 onShown。
    //
    // 桥接机制：`dispatchEvent`（`interop/interop.cj:135`）是本包内的普通 public func
    // （同时标注 `@Interop[ArkTS]` 供 ArkTS 侧 FFI 调用），`.ets` 壳里 import 自
    // `libohos_app_cangjie_entry.so` 的 dispatchEvent 与它是同一份实现——纯仓颉进程内调用
    // 与经 ArkTS 往返调用对 `EVENT_HANDLERS` fan-out 的效果完全一致。本页与
    // `SaveIncomingMediaPage.cj` 同在 `pages` 包内运行于同一进程，直接 import
    // `ohos_app_cangjie_entry.interop.dispatchEvent` 调用（同包内既有 `subscribe` 导入先例，
    // `SaveIncomingMediaPage.cj:27`）即可触发同一条 fan-out 通道，无需新增 `.ets` 侧改动。
    private func dispatchExceptionsChanged(): Unit {
        dispatchEvent("settings.saveIncomingMedia.shown", "{}")
    }

    // 右上对勾：.addPeer 一次性写盘 + dismissAll（连续两次 routerPop，移除本屏与选择器）；
    // .peer 只出栈（已拨动即写，不重复写盘）——对位源侧 :672-682/:678 两分支。
    private func submit(): Unit {
        if (this.selectedPeerId < 0) { routerPop(); return }
        if (this.isNew) {
            this.persistNewEntry()
            this.dispatchExceptionsChanged()
            routerPop()
            routerPop()
        } else {
            this.dispatchExceptionsChanged()
            routerPop()
        }
    }

    private func navTitle(): String {
        if (this.isNew) { return "Add Exception" }
        return "Exception"
    }

    @Builder
    func buildPeerHeaderCard() {
        Row {
            Avatar(
                avatarUrl: this.selectedAvatarPath,
                displayName: this.selectedDisplayName,
                avatarSize: 66,
                peerId: this.selectedPeerId
            )
            Column {
                Text(this.selectedDisplayName)
                    .fontSize(19)
                    .fontWeight(FontWeight.Bold)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                if (this.selectedStatusText.size > 0) {
                    Text(this.selectedStatusText)
                        .fontSize(15)
                        .fontColor(this.presentation.secondaryTextColor)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                        .margin(top: 2)
                }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin(left: 12)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 16, bottom: 16)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(26)
        .margin(left: 16, right: 16, top: 16)
    }

    public func build() {
        Column {
            Row {
                // Keep the actionable surface as a single Stack, matching the proven
                // modal controls in UsernameSettingsPage / ProxySettingsPage.  A nested
                // Row here exposed a clickable accessibility parent but did not dispatch
                // the tap from this DIALOG-hosted hybrid component on device.
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.nav_ic_close))
                        .width(18)
                        .height(18)
                        .fillColor(this.presentation.textColor)
                }
                    .width(44).height(44).borderRadius(22)
                    .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(this.navTitle())
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Blank().layoutWeight(1)
                Image(@r(app.media.username_nav_ic_done))
                    .width(30).height(30)
                    .fillColor(ITEM_LIST_ACCENT)
                    .onClick({ _evt => this.submit() })
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.navBarColor)
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    if (!this.isNew) {
                        this.buildPeerHeaderCard()
                    }

                    ItemListSectionHeader(title: "SAVE TO PHOTOS", topPad: 16)

                    Column {
                        ItemListToggleRow(
                            icon: @r(app.media.autosave_ic_photo),
                            title: "Photos",
                            isOn: this.photoOn,
                            onChange: { isOn: Bool => this.onTogglePhoto(isOn) }
                        )
                        ItemListSeparator(leftInset: 61)
                        ItemListToggleRow(
                            icon: @r(app.media.autosave_ic_video),
                            title: "Videos",
                            isOn: this.videoOn,
                            onChange: { isOn: Bool => this.onToggleVideo(isOn) }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .margin(left: 16, right: 16)

                    ItemListSectionFooter(
                        // Source `Autosave.TypesInfo` is also shared verbatim by
                        // `.peerType`, `.peer`, and `.addPeer` scopes.
                        text: "Automatically save all new media from private chats to your Photos app."
                    )

                    if (this.videoOn) {
                        ItemListSectionHeader(title: "MAXIMUM VIDEO SIZE", topPad: 24)

                        Column {
                            Text(this.sizeLabel)
                                .fontSize(17)
                                .fontColor(this.presentation.textColor)
                                .width(100.percent)
                                .textAlign(TextAlign.Center)
                                .padding(top: 12)

                            Slider(value: this.sliderPos * CONFIG_SLIDER_POS_SCALE, min: 0.0, max: CONFIG_SLIDER_POS_SCALE, step: 1.0, style: SliderStyle.OutSet)
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 4, bottom: 12)
                                .onChange({ value: Float64, _mode: SliderChangeMode =>
                                    this.onSlide(value / CONFIG_SLIDER_POS_SCALE)
                                })
                        }
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(26)
                        .margin(left: 16, right: 16)

                        ItemListSectionFooter(text: this.videoInfoLabel)
                    }

                    Row { }.height(32)
                }
            }
            .align(Alignment.Top)
            .layoutWeight(1)
            .backgroundColor(this.presentation.backgroundColor)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ =>
            this.parseRouteParamOnce()
            if (!this.loaded) {
                this.loaded = true
                this.loadInitialState()
            }
        })
    }
}
