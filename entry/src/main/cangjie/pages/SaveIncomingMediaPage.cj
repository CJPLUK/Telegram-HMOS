package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings, PresentationSnapshot, currentPresentation}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.ArkData.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getSaveToCameraRollService
import ohos_app_cangjie_entry.services.{MediaAutoSaveException, encodeMediaAutoSaveExceptions, decodeMediaAutoSaveExceptions}
import ohos_app_cangjie_entry.services.getGlobalAbilityContext
import ohos_app_cangjie_entry.services.autodownloadDataSizeString
import ohos_app_cangjie_entry.services.getRealChatListService
import ohos_app_cangjie_entry.services.getUserPhotoService
import ohos_app_cangjie_entry.services.getAvatarColorForPeer
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSectionFooter,
    ItemListToggleRow,
    ItemListSeparator,
    ItemListDisclosureRow,
    ItemListButtonRow,
    ITEM_LIST_ACCENT,
    Avatar,
    ContextMenuItem,
    ContextMenuView
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.subscribe
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import std.collection.ArrayList
import std.convert.*

/**
 * diag-suite_settings_data_storage-round3-data_storage_root-batch.md §F-C 改动 2 —
 * `saveIncomingMediaController(context:scope:.peerType(type))` 目的屏，此前不存在
 * （TC-0423 F1 blocking，`pages/DataStorageSettingsPage.cj` 三个入口行是"会写值的假披露"）。
 * 源：`SaveIncomingMediaController.swift:269-340`（`peerType` scope 分支，
 * `peer`/`addPeer` scope 本页不适用——三个入口行只传 peer type，不传单聊 peerId）。
 *
 * ── 模型：为什么持久化落在本文件而不是 `services/SaveToCameraRollService.cj` ──
 * 诊断报告「修法方向 §F-C 改动 1」把 `photo`/`video`/`maximumVideoSize` 三字段独立化
 * 的模型还原点定位到 `SaveToCameraRollService.cj`——但该文件不在本 feature 这轮的
 * `tasks[].target_files` 内（`grep -l SaveToCameraRollService workflow_output/feature_develop/
 * features/` 命中 `SaveToCameraRollService/savetocameraroll.json`，唯一 owner 是另一个已
 * `completed` 的 feature `savetocameraroll`）。本文件改用 `pages/AutoNightSettingsPage.cj`
 * 已有先例的解法（该文件同样因为"需要的服务不在本 feature target_files 内"而直接在页面
 * 自己的 Preferences store 里读写，见其类头注释）：独立 Preferences store
 * `telegram_autosave_media`（键前缀 = peer type: `private`/`groups`/`channels`），
 * 首次读取时从旧的单 Bool（`SaveToCameraRollService.getAutosaveX()`）一次性迁移
 * （`photo = video = 旧值`, `maximumVideoSize = 100 MB` 默认，对位报告「兼容既有落盘值」
 * 那一条规则），此后 photo/video 任一变化都会把 `photo || video` 写回旧的单 Bool
 * setter（`saveAutosaveX`），保持根屏 `DataStorageSettingsPage.cj` 的 On/Off 摘要串
 * （仍读旧 store）与本页保持一致——不产生第二个互不同步的真值源。
 *
 * ── EXCEPTIONS 层（diag-suite_settings_data_storage-TC-0424-round6.md I-1 / TC-0423.md
 * FIX-B，本轮落地）──
 * 源侧 `exceptions` 分节对位一个通用会话选择器（`makePeerSelectionController`）+ 三层
 * 递归 scope（`peerType` 根屏 / `addPeer` 暂存态 / `peer` 编辑态，:370-768）。本工程没有
 * 通用选择器（`ContactListPage`/`SelectivePrivacySettingsPeersPage` 均是各自 feature 的
 * 专用屏、不在本 feature allowlist），round4 §G-2 裁定：新建一块专用选择器屏
 * `pages/AutosaveExceptionPeerSelectionPage.cj`（零授权新文件，2026-08-31 grant）——
 * 源侧 `addPeer`/`peer` 两个 scope 用同一个 controller 换 scope 呈现，本页对位实现为
 * 「选择器阶段 + 编辑阶段」两态收在同一个目的屏内（而不是两个各自独立的路由页），
 * 净效果一致（选人 → 编配置 → 保存 → 回到本页），已知实现选择差异见该文件头注释。
 * 模型：`telegram_autosave_media` store 内新增 `<peerType>_exceptions` 键（本文件内的
 * `MediaAutoSaveException`/编解码函数），持久化在同一个 store，不新建第二个。
 * 返回本页时的刷新：本 NavDestination 全程 mounted，push/pop 不会重触发 build()（同
 * TC-0420 M1 结论），故新增 `saveIncomingMediaShownEvent` + `subscribe(...)` 对位
 * `DataStorageSettingsPage.ets`/`.cj` 的既有先例（`ets/pages/SaveIncomingMediaPage.ets`
 * 配套加 `.onShown` dispatch）。
 */
// ── FIX-B-1 模型：对位源侧 MediaAutoDownloadSettings.swift:207-216 ExceptionItem
// {id: PeerId, configuration: MediaAutoSaveConfiguration}。字段/默认值逐个对位源侧
// MediaAutoSaveConfiguration 默认（photo=false, video=false, maximumVideoSize=100MB）。
// 有意不加 private/内部可见性默认即整包可见（package.md「顶层声明可见性」：其他顶层声明
// 默认 internal = 同包不导入可见）——`pages/AutosaveExceptionPeerSelectionPage.cj` 与本文件
// 同属 `ohos_app_cangjie_entry.pages` 包，直接复用这里的类型与编解码函数，不重复定义，
// 保证两个文件对同一个持久化 wire format 只有一份权威定义，不会各自漂移。
// S7-95: MediaAutoSaveException 与其编解码已移入 services/SaveToCameraRollService.cj（唯一权威
// 定义），自动保存（下载完成时的 storeDownloadedMedia 对位）需要在 services 层读同一份例外表。

private class SizeAnchor {
    public var pos: Float64
    public var bytes: Int64
    public init(pos!: Float64, bytes!: Int64) {
        this.pos = pos
        this.bytes = bytes
    }
}

// ── 滑杆定义域的整数化倍率（I-5，diag round5 §I-5）──
// 源侧 `AutodownloadSizeLimitItem.swift:162-171` 的 `TGPhotoEditorSliderView` 只设
// `minimumValue=0.0 / maximumValue=1.0 / startValue=0.0`，**不设 `positionsCount`**；
// `TGPhotoEditorSliderView.m` 的全部吸附逻辑都在 `positionsCount > 1` 之下
// （`:99` 手势开关、`:707-715` 拖停吸附、`:723` valueChanged 门），默认值 0 ⇒
// **源侧滑杆在 [0,1] 上连续，没有任何刻度位**；那张 5 项锚点表是分段线性映射的**折点**，
// 不是可停的档位——`sizeValue(for:)`（源 `:34-48`，本文件 `sizeForSliderPos`）在相邻折点
// **之间**插值，若只有 5 个可达位，那段插值就是死码。
// ArkUI 侧无法表达"连续"：`step` 省略 ⇒ wrapper `ohos/arkui/component/slider/slider.cj:117,125`
// 的 `step ?? 1.0` 取 1.0，在 min=0.0/max=1.0 上格点集合塌成 `{0.0, 1.0}`，只剩 512KB 与
// 1.5GB 两个可达值，`maxVideoSizeBytes` 的源侧默认 100MB 用户再也选不回来。
// 因此把 [0,1] 显式放大到整数域 [0, 1000] 后再喂控件：
//   · 1/1000 是能让 5 个锚点（0.000 / 0.257 / 0.520 / 0.763 / 1.000，源表全为三位小数）
//     **全部精确落在格点上**的最粗均匀格点 —— 倍率由源表的小数位数推出，不是估的；
//   · IEEE754 下 `257.0/1000.0`、`520.0/1000.0`、`763.0/1000.0` 与锚点字面量逐位相等，
//     `0/1000 = 0.0`、`1000/1000 = 1.0` 精确 ⇒ 两个端点值（512KB / 1.5GB）零回归；
//   · 轨道净宽约 1208px ⇒ 每格约 1.2px，肉眼连续，无源侧没有的台阶感。
// **`step` 在本控件上不是可省参数**：省略不等于"用 SDK 的连续分辨率"，等于选了 `step = 1.0`
// （见 `dev_pattern.md` D-199）。故此处 `step:` 与倍率成对显式写出，且不加 `.showSteps(true)`
// （源侧无刻度点，加了会造出源侧没有的视觉元素）。
private let SLIDER_POS_SCALE: Float64 = 1000.0

// Source: AutodownloadSizeLimitItem.swift:12-18 `autodownloadSizeValues` — same component
// `SaveIncomingMediaController.swift:214` reuses for the video-size row, so the same anchor
// table applies (duplicated here, not imported, because AutodownloadMediaCategoryPage.cj's
// copies are `private` top-level functions in another page file, not exported).
private func sizeAnchors(): Array<SizeAnchor> {
    return [
        SizeAnchor(pos: 0.000, bytes: 512 * 1024),
        SizeAnchor(pos: 0.257, bytes: 1024 * 1024),
        SizeAnchor(pos: 0.520, bytes: 10 * 1024 * 1024),
        SizeAnchor(pos: 0.763, bytes: 100 * 1024 * 1024),
        SizeAnchor(pos: 1.000, bytes: 1536 * 1024 * 1024)
    ]
}

private func sliderPosForSize(size: Int64): Float64 {
    let anchors = sizeAnchors()
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

private func sizeForSliderPos(pos: Float64): Int64 {
    let anchors = sizeAnchors()
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

@HybridComponentEntry
@Component
public class SaveIncomingMediaPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    // Route param: "private" | "groups" | "channels" — matches the strings
    // DataStorageSettingsPage.cj's 3 autosave rows already routerPush with.
    @State var peerType: String = "private"
    @State var paramParsed: Bool = false
    @State var loaded: Bool = false

    @State var photoOn: Bool = false
    @State var videoOn: Bool = false
    @State var maxVideoSizeBytes: Int64 = 100 * 1024 * 1024
    @State var sliderPos: Float64 = 0.0
    @State var sizeLabel: String = ""
    @State var videoInfoLabel: String = ""

    // ── FIX-B: EXCEPTIONS 层 @State ──
    @State var exceptions: ArrayList<MediaAutoSaveException> = ArrayList<MediaAutoSaveException>()
    @State var exceptionsHeaderLabel: String = "EXCEPTIONS"
    // F-6：Delete All 确认改为贴底 ActionSheet（ContextMenuView），对位源侧
    // ActionSheetController（两 group、各一个按钮，无 title、无正文行）——不再用居中
    // AlertDialog。先例 pages/SelectivePrivacySettingsPeersPage.cj 同一个 RC-6b 裁定。
    @State var showDeleteAllConfirm: Bool = false
    // F-4（diag-suite_settings_data_storage-TC-0424-round7.md）：按 peerId 标识而非下标——
    // 源侧全程按 peer id 删除（deletePeer(id)），从不按列表下标；下标形态在 ForEach 用纯身份键
    // （D-127 方向 B）时，onOffsetChange 闭包捕获的下标在同批删除后失陈，会静默 return 或删错行。
    @State var swipeRowPeerId: Int64 = -1

    // TC-0420 M1 同款先例：本 NavDestination 全程 mounted，push/pop 不重触发 build()，
    // 从 AutosaveExceptionPeerSelectionPage routerPop() 回来后必须靠 onShown 事件重新
    // loadExceptions()。事件名字面量须与 ets/pages/SaveIncomingMediaPage.ets 内
    // dispatchEvent(...) 逐字一致。
    private let saveIncomingMediaShownEvent: String = "settings.saveIncomingMedia.shown"

    private func parseRouteParamOnce(): Unit {
        if (this.paramParsed) { return }
        this.paramParsed = true
        let raw = takePending("SaveIncomingMediaPage")
        if (raw.size > 0 && raw != "{}") {
            let trimmed = raw.trimAscii()
            if (trimmed == "groups" || trimmed == "channels") {
                this.peerType = trimmed
            } else {
                this.peerType = "private"
            }
        }
    }

    // 对位 Notifications.PrivateChats/.GroupChats/.Channels —— 与根屏三行标题、以及源侧
    // SaveIncomingMediaController.swift:697/700/703 (peerType scope 的 title) 用的是
    // 同一批字符串键。
    private func titleText(): String {
        match (this.peerType) {
            case "groups" => "Group Chats"
            case "channels" => "Channels"
            case _ => "Private Chats"
        }
    }

    private func typesInfoText(): String {
        // Source uses the same `Autosave.TypesInfo` localization entry for all three
        // peer-type scopes; the category is not supplied as a format argument.
        return "Automatically save all new media from private chats to your Photos app."
    }

    private func legacyBool(): Bool {
        let svc = getSaveToCameraRollService()
        match (this.peerType) {
            case "groups" => svc.getAutosaveGroups()
            case "channels" => svc.getAutosaveChannels()
            case _ => svc.getAutosavePrivateChats()
        }
    }

    // 写回旧的单 Bool store（DataStorageSettingsPage.cj 根屏摘要串仍读它），保持两处
    // 显示一致——本页是唯一真正持久化 photo/video 分离态的地方，旧 store 只是它的
    // "combined" 派生镜像。
    private func writeLegacyBool(combined: Bool): Unit {
        let svc = getSaveToCameraRollService()
        match (this.peerType) {
            case "groups" => svc.saveAutosaveGroups(combined)
            case "channels" => svc.saveAutosaveChannels(combined)
            case _ => svc.saveAutosavePrivateChats(combined)
        }
    }

    private func loadConfiguration(): Unit {
        let svc = getSaveToCameraRollService()
        let prefix = this.peerType
        if (svc.getMediaSettingInt("${prefix}_migrated", 0) == 0) {
            // Migrate the former peer-wide switch once into Telegram's photo/video split model.
            let legacy: Int64 = if (this.legacyBool()) { 1 } else { 0 }
            svc.setMediaSettingInt("${prefix}_photo", legacy)
            svc.setMediaSettingInt("${prefix}_video", legacy)
            svc.setMediaSettingInt("${prefix}_max_video_size", 100 * 1024 * 1024)
            svc.setMediaSettingInt("${prefix}_migrated", 1)
        }
        this.photoOn = svc.getMediaSettingInt("${prefix}_photo", 0) != 0
        this.videoOn = svc.getMediaSettingInt("${prefix}_video", 0) != 0
        this.maxVideoSizeBytes = svc.getMediaSettingInt(
            "${prefix}_max_video_size", 100 * 1024 * 1024)
        this.sliderPos = sliderPosForSize(this.maxVideoSizeBytes)
        this.refreshSizeLabel()
        this.loadExceptions()
        Hilog.info(0, "CjTelegram", "[SaveIncomingMedia] loaded ${this.peerType}: photo=${this.photoOn} video=${this.videoOn} maxVideoSize=${this.maxVideoSizeBytes}")
    }

    // ── FIX-B: EXCEPTIONS 持久化（同 store `telegram_autosave_media`，键
    // `<peerType>_exceptions`；缺键即空表——例外表在旧 store 里本就不存在，不需要
    // `_migrated` 那条一次性迁移分支）──
    private func loadExceptions(): Unit {
        let raw = getSaveToCameraRollService().getMediaSettingString(
            "${this.peerType}_exceptions", "")
        this.exceptions = decodeMediaAutoSaveExceptions(raw)
        this.refreshExceptionsHeaderLabel()
    }

    private func persistExceptions(): Unit {
        getSaveToCameraRollService().setMediaSettingString(
            "${this.peerType}_exceptions", encodeMediaAutoSaveExceptions(this.exceptions))
        this.refreshExceptionsHeaderLabel()
    }

    // 对位源侧 :328-332：空表 "EXCEPTIONS"；非空取计数形式全大写
    // （Notifications.CategoryExceptions，源侧 .uppercased()）。
    private func refreshExceptionsHeaderLabel(): Unit {
        let n = this.exceptions.size
        if (n == 0) {
            this.exceptionsHeaderLabel = "EXCEPTIONS"
        } else if (n == 1) {
            this.exceptionsHeaderLabel = "1 EXCEPTION"
        } else {
            this.exceptionsHeaderLabel = "${n} EXCEPTIONS"
        }
    }

    // F-4：按 peerId 删除（对位源侧 :589-597 deletePeer(id) settings.exceptions.removeAll(where:
    // { $0.id == id })）——不再有任何下标比较，天然不受"同一挂载实例内先发生过一次删除"影响。
    private func removeExceptionByPeerId(peerId: Int64): Unit {
        if (peerId < 0) { return }
        let newList = ArrayList<MediaAutoSaveException>()
        var i: Int64 = 0
        while (i < this.exceptions.size) {
            if (this.exceptions[i].peerId != peerId) { newList.add(this.exceptions[i]) }
            i += 1
        }
        this.exceptions = newList
        this.persistExceptions()
    }

    private func deleteAllExceptions(): Unit {
        this.exceptions = ArrayList<MediaAutoSaveException>()
        this.persistExceptions()
    }

    // 对位源侧 :328-332 副标题四态之上一层——例外行本身的展示名，peerType 固定为
    // 本页当前 scope，private 走 user 缓存，groups/channels 走 chat 缓存
    // （services/RealChatListService.cj dialogToChat 同一套缓存来源）。
    private func exceptionDisplayName(peerId: Int64): String {
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

    private func exceptionAvatarPath(peerId: Int64): String {
        if (this.peerType == "private") {
            return getUserPhotoService().getUserPhotoPath(peerId)
        }
        return getUserPhotoService().getChatPhotoPath(peerId)
    }

    // 对位源侧 :331-360 四态拼串（photo/no-photo, video-up-to/no-video）。
    private func exceptionSubtitle(e: MediaAutoSaveException): String {
        let photoLabel = if (e.photo) { "Photos" } else { "No Photos" }
        let videoLabel = if (e.video) { "Videos up to ${autodownloadDataSizeString(e.maximumVideoSize)}" } else { "No Videos" }
        return "${photoLabel}, ${videoLabel}"
    }

    private func openAddException(): Unit {
        routerPush("AutosaveExceptionPeerSelectionPage", this.peerType)
    }

    // round7 F-2 边界：直接从例外行点进编辑 = .peer scope，push（不经选择器）——对位源侧
    // :577-579 openPeerMenu 就是 pushController。
    private func openEditException(peerId: Int64): Unit {
        routerPush("AutosaveExceptionConfigPage", "${this.peerType}|${peerId}")
    }

    // F-6：源侧 :597-616 ActionSheetController 两个 group，各一个 ActionSheetButtonItem，
    // 无 title、无正文行——只翻 showDeleteAllConfirm，渲染层见 build() 根 Stack 的 overlay 兄弟层。
    private func confirmDeleteAllExceptions(): Unit {
        this.showDeleteAllConfirm = true
    }

    private func persistBool(field: String, value: Bool): Unit {
        let n: Int64 = if (value) { 1 } else { 0 }
        getSaveToCameraRollService().setMediaSettingInt("${this.peerType}_${field}", n)
    }

    private func persistMaxVideoSize(bytes: Int64): Unit {
        getSaveToCameraRollService().setMediaSettingInt(
            "${this.peerType}_max_video_size", bytes)
    }

    private func togglePhoto(isOn: Bool): Unit {
        this.photoOn = isOn
        this.persistBool("photo", isOn)
        this.writeLegacyBool(this.photoOn || this.videoOn)
        Hilog.info(0, "CjTelegram", "[SaveIncomingMedia] ${this.peerType}.photo=${isOn}")
    }

    private func toggleVideo(isOn: Bool): Unit {
        this.videoOn = isOn
        this.persistBool("video", isOn)
        this.writeLegacyBool(this.photoOn || this.videoOn)
        Hilog.info(0, "CjTelegram", "[SaveIncomingMedia] ${this.peerType}.video=${isOn}")
    }

    private func onSlide(pos: Float64): Unit {
        this.sliderPos = pos
        let bytes = sizeForSliderPos(pos)
        this.maxVideoSizeBytes = bytes
        this.refreshSizeLabel()
        this.persistMaxVideoSize(bytes)
    }

    // 对位 AutoDownloadSettings.UpTo = "up to %@"（滑杆标题）+ Autosave.VideoInfo =
    // "All downloaded videos in private chats less than %@ will be saved to Cameral
    // Roll."（段尾，源串字面量固定含 "private chats"，三个 peer type 共用同一句——源侧
    // 本就没有按 scope 参数化这句文案，逐字照抄，不是本文件引入的缺陷）。两个字段在同一
    // 函数里由同一个 this.maxVideoSizeBytes 算出，对位源侧「sizeText 算一次喂两处」
    // （SaveIncomingMediaController.swift:282-293）；`videoInfoLabel` 之前是函数调用返回值
    // 传给 `ItemListSectionFooter` 的 `@Prop text`，不触发子组件重新 build（D-125），
    // 现改为裸 `@State` 由本函数直接赋值。
    private func refreshSizeLabel(): Unit {
        this.sizeLabel = "up to ${autodownloadDataSizeString(this.maxVideoSizeBytes)}"
        this.videoInfoLabel = "All downloaded videos in private chats less than ${autodownloadDataSizeString(this.maxVideoSizeBytes)} will be saved to your Photos app."
    }

    // ==================== FIX-B-2: EXCEPTIONS 行 builder ====================

    // D-135 边界：分隔线与行内容必须收进同一个 Column，swipeAction 分支下 ListItem 只保留
    // 第一个子节点（同 pages/SelectivePrivacySettingsPeersPage.cj:746-776 先例）。
    @Builder
    func buildExceptionRow(entry: MediaAutoSaveException) {
        Column {
            ItemListSeparator(leftInset: 76)
            Row {
                Avatar(
                    avatarUrl: this.exceptionAvatarPath(entry.peerId),
                    displayName: this.exceptionDisplayName(entry.peerId),
                    avatarSize: 40,
                    peerId: entry.peerId
                )
                Column {
                    Text(this.exceptionDisplayName(entry.peerId))
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                    Text(this.exceptionSubtitle(entry))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                        .margin(top: 2)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .margin(left: 12)
            }
            .width(100.percent)
            .height(60)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(this.presentation.cardColor)
            .onClick({ _ => this.openEditException(entry.peerId) })
        }
    }

    // swipeAction end 槽：行身份镜像的唯一写入点是 onOffsetChange（build() 内 ForEach
    // itemGenerator 处），本 @Builder 体内禁止任何 this.xxx = ... 赋值（D-135，同
    // SelectivePrivacySettingsPeersPage.cj:778-795 先例）。
    @Builder
    func buildExceptionSwipeEndPanel() {
        Column {
            Text(trSource("Delete"))
                .fontSize(15)
                .fontColor(0xFFFFFFFF)
        }
        .width(74)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(0xFF3B30)
        .onClick({ _ =>
            this.removeExceptionByPeerId(this.swipeRowPeerId)
        })
    }

    @Builder
    func buildAddExceptionRow() {
        Row {
            // Source: PresentationResourcesItemList.createGroupIcon(theme), backed by
            // Location/CreateGroupIcon rather than a generic plus glyph.
            Image(@r(app.media.location_ic_creategroup))
                .width(30).height(30)
                .fillColor(ITEM_LIST_ACCENT)
            Text(trSource("Add Exception"))
                .fontSize(17).fontColor(ITEM_LIST_ACCENT).layoutWeight(1).margin(left: 15)
        }
        .width(100.percent).height(48)
        .padding(right: 16)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.presentation.cardColor)
        .onClick({ _ => this.openAddException() })
    }

    public func build() {
        Stack {
        Column {
            Row {
                Row {
                    Image(@r(app.media.callui_v2_back)).width(10).height(18).fillColor(this.presentation.accentColor)
                }
                .width(44).height(44).borderRadius(22)
                .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
                .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
                .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(this.titleText())
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Row { }.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            // F-7：与页面根 Column 的 0xF2F2F7（:744）、兄弟屏
            // pages/AutosaveExceptionPeerSelectionPage.cj:521 同值——此前的 0xFFFFFF
            // 在 y=332 处切出一条白色硬边。
            .backgroundColor(this.presentation.navBarColor)
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    // ── SAVE TO CAMERA ROLL (source Autosave.TypesSection) ──
                    ItemListSectionHeader(title: "SAVE TO PHOTOS", topPad: 16)

                    Column {
                        // TC-0423.md RC-1/FIX-A-3: 真实资源迁移自 autodl_ic_photo/video.png
                        // 逐像素反解插值换色（源侧 photosLightBlue/videosBlue），不是复用
                        // 现有橙/红徽标（那是另外两个调用点 .photos/.videos 的底色）。
                        ItemListToggleRow(
                            icon: @r(app.media.autosave_ic_photo),
                            title: "Photos",
                            isOn: this.photoOn,
                            onChange: { isOn: Bool => this.togglePhoto(isOn) }
                        )
                        ItemListSeparator(leftInset: 61)
                        ItemListToggleRow(
                            icon: @r(app.media.autosave_ic_video),
                            title: "Videos",
                            isOn: this.videoOn,
                            onChange: { isOn: Bool => this.toggleVideo(isOn) }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .margin(left: 16, right: 16)

                    ItemListSectionFooter(
                        text: this.typesInfoText()
                    )

                    // ── MAXIMUM VIDEO SIZE (video only — source :282 `if configuration.video`) ──
                    // FIX-B-2 边界条件：本条与下方 EXCEPTIONS 两节是并列关系（源侧 :283
                    // `if configuration.video` 与 :297 `if case .peerType = scope` 各自独立），
                    // 不共享同一个 if/else——videoOn 为真时两组分节必须同时在屏。
                    if (this.videoOn) {
                        ItemListSectionHeader(title: "MAXIMUM VIDEO SIZE", topPad: 24)

                        Column {
                            Text(this.sizeLabel)
                                .fontSize(17)
                                .fontColor(this.presentation.textColor)
                                .width(100.percent)
                                .textAlign(TextAlign.Center)
                                .padding(top: 12)

                            // 定义域整数化：推导与倍率含义见本文件 `SLIDER_POS_SCALE`。
                            // `onSlide(pos:)` 的入参语义仍是 [0,1]，锚点表与两个映射函数
                            // （`sizeAnchors` / `sliderPosForSize` / `sizeForSliderPos`）一个字不改。
                            Slider(value: this.sliderPos * SLIDER_POS_SCALE, min: 0.0, max: SLIDER_POS_SCALE, step: 1.0, style: SliderStyle.OutSet)
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 4, bottom: 12)
                                .onChange({ value: Float64, _mode: SliderChangeMode =>
                                    this.onSlide(value / SLIDER_POS_SCALE)
                                })
                        }
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(26)
                        .margin(left: 16, right: 16)

                        ItemListSectionFooter(text: this.videoInfoLabel)
                    }

                    // ── FIX-B-2: EXCEPTIONS 两节（diag TC-0424-round6 I-1 / TC-0423.md
                    // FIX-B）——无条件渲染，不受 videoOn 门控。 ──
                    ItemListSectionHeader(title: this.exceptionsHeaderLabel, topPad: 24)

                    Column {
                        this.buildAddExceptionRow()
                        // 非滚动内层 List：仅为了拿 swipeAction（该 API 只挂在 ListItem 上，
                        // 见 pages/SelectivePrivacySettingsPeersPage.cj 同款先例），不带
                        // .layoutWeight/.height，内容按自身高度撑开——页面唯一的滚动区仍是
                        // 外层 Scroll，不构成第二个滚动容器。
                        List {
                            // F-4：keyGeneratorFunc 用「唯一 id 前缀 + 全部参与渲染的字段」
                            // （D-127 方向 B），不再是纯身份键——否则同一挂载实例内该行内容
                            // （exceptionSubtitle 读取的 photo/video/maximumVideoSize）在
                            // itemGeneratorFunc 不再执行时冻结在首次构建值。
                            ForEach(this.exceptions, itemGenerator: { entry: MediaAutoSaveException, _idx: Int64 =>
                                ListItem {
                                    this.buildExceptionRow(entry)
                                }
                                .swipeAction(
                                    end: { => bind(this.buildExceptionSwipeEndPanel, this)() },
                                    onOffsetChange: { offset: Float64 =>
                                        if (offset != 0.0) {
                                            this.swipeRowPeerId = entry.peerId
                                        }
                                    }
                                )
                            }, keyGeneratorFunc: { entry: MediaAutoSaveException, _idx: Int64 =>
                                "exception_${entry.peerId}_${entry.photo}_${entry.video}_${entry.maximumVideoSize}"
                            })
                        }
                        // 先例 pages/DevicesPage.cj:1080-1192（TC-0134/TC-0135 已 PASS）：不带
                        // .height/.layoutWeight 的内层 List 嵌在 Scroll>Column 卡片内部按内容
                        // 自身高度撑开，同一个已验证过的 List+swipeAction-in-Scroll 范式。
                        .width(100.percent)
                        .scrollBar(BarState.Off)
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .clip(true)
                    .margin(left: 16, right: 16)

                    if (this.exceptions.size > 0) {
                        Column {
                            ItemListButtonRow(
                                title: "Delete All Exceptions",
                                destructive: true,
                                centered: true,
                                onClick: { => this.confirmDeleteAllExceptions() }
                            )
                        }
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(26)
                        .clip(true)
                        .margin(left: 16, right: 16, top: 24)
                    }

                    Row { }.height(32)
                }
            }
            // I-6：`Scroll` 的通用 `align` 默认 `Alignment.Center`
            // （wrapper `common/common_component.cj:642-662` 的 `alignInner` 取 `value ?? Alignment.Center`），
            // 内容短于视口时子节点被垂直居中，导航栏下留出大片空带（实测 ~880px）；
            // 源侧 `ItemListController` 用 `ListView` 承载，短内容永远顶对齐。
            // 顶对齐必须写在 `Scroll` 自身链上（`Column.alignItems` 管的是横轴）。
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
                subscribe(this.saveIncomingMediaShownEvent, { _payload: String => this.loadExceptions() })
                this.loadConfiguration()
            }
        })

        // F-6：贴底 ActionSheet overlay，与根 Column 是同一个 Stack 的兄弟层，
        // 用显式 .zIndex 排序（D-136）。逐字先例
        // pages/SelectivePrivacySettingsPeersPage.cj:1006-1019，唯一差别：源侧本屏
        // ActionSheet 没有说明文本行（SaveIncomingMediaController.swift:599-616 只有
        // 两个 group、各一个按钮），不加 ContextMenuItem.text(...)。
        if (this.showDeleteAllConfirm) {
            // D-216：自定义 @Component 调用后不能直接链 .zIndex —— 宏展开的构造参数列表
            // 会对不上，须包一层容器。
            Stack {
                ContextMenuView(
                    items: [
                        ContextMenuItem(
                            title: "Delete All Exceptions",
                            destructive: true,
                            onClick: { => this.deleteAllExceptions() },
                            centered: true
                        ),
                        ContextMenuItem.separator(),
                        ContextMenuItem(title: "Cancel", onClick: { => }, centered: true)
                    ],
                    onDismiss: { => this.showDeleteAllConfirm = false },
                    // diag-suite_settings_data_storage-TC-0424-round8.md 缺陷 B（D3）：调用点
                    // 此前未传 bottomInset（取默认值 0.0），底部菜单卡片贴着 Stack 真实底边
                    // 渲染，`Cancel` 行命中区下半部分落进系统 Home 指示条手势区被吞掉。改用
                    // 组件已预留的逃生口（components/ContextMenu.cj:286/365）；不改组件本身，
                    // 也不改参照先例 SelectivePrivacySettingsPeersPage.cj 的外层 Stack.padding
                    // 写法——本页外层 Stack 只有本浮层这一个子节点用到安全区，主体 Column 已有
                    // 自己的 .padding(bottom: getSafeAreaBottom())（:751），动 Stack 会造成双重
                    // 内缩。
                    bottomInset: getSafeAreaBottom()
                )
            }
            .zIndex(100)
        }
        }
    }
}
