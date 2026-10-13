package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.sync.*
import ohos_app_cangjie_entry.services.getNotificationSoundSelectionService
import ohos_app_cangjie_entry.services.RingtoneEntry
import ohos_app_cangjie_entry.services.JsonParser
import ohos_app_cangjie_entry.services.CloudSoundBuiltinCategory
import ohos_app_cangjie_entry.services.classifyCloudSound
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.services.getUndoToastService
import ohos_app_cangjie_entry.services.getLegacyMediaPickerService
import ohos_app_cangjie_entry.utils.readRawFileBytes
import ohos_app_cangjie_entry.bindings.getTelegramLottieNative
import kit.ImageKit.Size as IKSize
import kit.ImageKit.{createPixelMap, InitializationOptions, PixelMap, PixelMapFormat, AlphaType}

/**
 * 通知铃声选择页面（Phase NSND）（混合工程迁移版）
 *
 * 对应 iOS NotificationSoundSelectionUI
 * 分区显示: 云端铃声、现代铃声、经典铃声
 * 支持: 选择铃声、上传自定义铃声、删除云端铃声
 *
 * 音频播放预览: deferred（鸿蒙 AVPlayer API 兼容性待验证）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹 + .hideTitleBar，只留内容 + .onAppear
 *  - aboutToAppear 有实逻辑（getSelectedSound/loadRingtones）→ ensureLoaded()
 *  - pop() → routerPop()
 *
 * `diag-suite_settings_notifications-TC-0446.md` F-A1b 返修：本页原先是无参页面、
 * 自持一个全局单槽（`service.getSelectedSound()`），点行即落盘并 pop——收不下调用方
 * 契约（源侧 `NotificationSoundSelection.swift:365` 带 `currentSound`/`defaultSound`/
 * `completion` 三个入参，选择与提交是两步：`:381-394 selectSound` 只改 state，
 * `:432-438 completeImpl`（Done）才真正提交）。改为：
 *  - `ensureLoaded()` 用 `takePending("NotificationSoundSelectionPage")` 取
 *    `{category, currentSoundId, currentAccessHash, defaultSoundId}` 播种初始选中态，
 *    不再读全局单槽；
 *  - `onSelectSound/onSelectDefault/onSelectNone` 只写 `@State`，不落盘、不 pop；
 *  - `Done` 才一次性提交（`commitSelection`），`Cancel` 只 pop、不写任何存储；
 *  - `defaultSoundId` 为显式 JSON null（N1 路径恒如此，源 `:870` 传 `defaultSound: nil`）
 *    时不渲染 `Default` 行（对位源 `:236-238` 的 `if let defaultSound`）。
 */
// ======================================================================
// X1/X3 Undo 提示条图标（`diag-suite_settings_notifications-TC-0449-round6.md`
// 改动 3/4）。rawfile → Lottie → PixelMap 通路照抄
// `pages/SelectivePrivacySettingsPage.cj:123-202 ensureLinkCopiedIconLoaded`
// （已在设备上跑通的既有写法：`readRawFileBytes` → `getTelegramLottieNative().renderTgs`
// → `createPixelMap`）。`UndoToastService.showUndo(iconPixelMap:)` 是单帧静态展示，
// 不驱动播放定时器，只渲染一次、缓存单帧复用。
// ======================================================================

private let NSND_TOAST_ICON_SIZE: Int32 = 20 * 3

// X1（超限提示条）复用已存在的 anim_infotip.json（源侧 `.info` 同一资产，对位一致）。
private let nsndOversizedIconMonitor = Monitor()
private var nsndOversizedIconFrame: Option<PixelMap> = None<PixelMap>
private var nsndOversizedIconLoadAttempted: Bool = false

/**
 * 首次调用触发加载；命中缓存（或已尝试过且失败）直接返回，不重复渲染。调用方需在
 * `spawn{}` 里跑（渲染是同步阻塞调用，R-138 同理）。`anim_infotip.json` 实测
 * `op(45)-ip(0)=45` 帧 @ `fr=60`，maxFrames 按此值传入（与
 * `pages/WebBrowserSettingsPage.cj:319-321` 已核实的同一资产同值）。
 */
private func ensureOversizedIconLoaded(): Bool {
    synchronized(nsndOversizedIconMonitor) {
        if (nsndOversizedIconFrame.isSome()) { return true }
        if (nsndOversizedIconLoadAttempted) { return false }
        nsndOversizedIconLoadAttempted = true
    }
    match (readRawFileBytes("anim_infotip.json")) {
        case None =>
            Hilog.info(0, "CjTelegram", "[NSND] missing anim_infotip.json")
            return false
        case Some(bytes) =>
            let rendered = getTelegramLottieNative().renderTgs(
                bytes, "nsnd_oversized_icon", NSND_TOAST_ICON_SIZE, maxFrames: 45
            )
            if (!rendered.success || rendered.frames.size == 0) { return false }
            let options = InitializationOptions(
                IKSize(NSND_TOAST_ICON_SIZE, NSND_TOAST_ICON_SIZE),
                srcPixelFormat: PixelMapFormat.Bgra8888,
                pixelFormat: PixelMapFormat.Bgra8888,
                alphaType: AlphaType.Premul
            )
            let lastFrame = rendered.frames.get(rendered.frames.size - 1).getOrThrow()
            let pixelMap = createPixelMap(lastFrame, options)
            synchronized(nsndOversizedIconMonitor) {
                nsndOversizedIconFrame = Some(pixelMap)
            }
            return true
    }
}

private func currentOversizedIconFrame(): Option<PixelMap> {
    synchronized(nsndOversizedIconMonitor) {
        return nsndOversizedIconFrame
    }
}

// 成功提示条用新拷入的 anim_notificationsound.json（改动4：从
// `input/Telegram-iOS/submodules/TelegramUI/Resources/Animations/anim_notificationsound.json`
// 原样拷入，无归属、本轮已授权新增）。
private let nsndSuccessIconMonitor = Monitor()
private var nsndSuccessIconFrame: Option<PixelMap> = None<PixelMap>
private var nsndSuccessIconLoadAttempted: Bool = false

/** `anim_notificationsound.json` 实测 `op(66)-ip(0)=66` 帧 @ `fr=60`。 */
private func ensureSuccessIconLoaded(): Bool {
    synchronized(nsndSuccessIconMonitor) {
        if (nsndSuccessIconFrame.isSome()) { return true }
        if (nsndSuccessIconLoadAttempted) { return false }
        nsndSuccessIconLoadAttempted = true
    }
    match (readRawFileBytes("anim_notificationsound.json")) {
        case None =>
            Hilog.info(0, "CjTelegram", "[NSND] missing anim_notificationsound.json")
            return false
        case Some(bytes) =>
            let rendered = getTelegramLottieNative().renderTgs(
                bytes, "nsnd_success_icon", NSND_TOAST_ICON_SIZE, maxFrames: 66
            )
            if (!rendered.success || rendered.frames.size == 0) { return false }
            let options = InitializationOptions(
                IKSize(NSND_TOAST_ICON_SIZE, NSND_TOAST_ICON_SIZE),
                srcPixelFormat: PixelMapFormat.Bgra8888,
                pixelFormat: PixelMapFormat.Bgra8888,
                alphaType: AlphaType.Premul
            )
            let lastFrame = rendered.frames.get(rendered.frames.size - 1).getOrThrow()
            let pixelMap = createPixelMap(lastFrame, options)
            synchronized(nsndSuccessIconMonitor) {
                nsndSuccessIconFrame = Some(pixelMap)
            }
            return true
    }
}

private func currentSuccessIconFrame(): Option<PixelMap> {
    synchronized(nsndSuccessIconMonitor) {
        return nsndSuccessIconFrame
    }
}

@HybridComponentEntry
@Component
public class NotificationSoundSelectionPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var cloudRingtones: ArrayList<RingtoneEntry> = ArrayList<RingtoneEntry>()
    @State var selectedId: Int64 = 0
    @State var selectedAccessHash: Int64 = 0
    @State var selectedFileRef: Array<Byte> = Array<Byte>(0, repeat: 0)
    @State var isLoading: Bool = true
    @State var isUploading: Bool = false
    @State var statusMessage: String = ""

    // 调用方契约（F-A1b）：category 决定 commitSelection 落盘到哪个分类槽；
    // hasDefaultSound/defaultSoundId 决定 ALERT TONES 段是否渲染 `Default` 行。
    @State var category: String = ""
    @State var hasDefaultSound: Bool = false
    @State var defaultSoundId: Int64 = 0

    @State var loaded: Bool = false

    // F-3（diag-suite_settings_notifications-TC-0446.md round2）：下滑交互式关闭手势的追踪态。
    // 见 onHeaderTouch() 头部注释——本仓已安装 Cangjie SDK 无 PanGesture/GestureEvent 手势
    // 识别子系统，改用底层 `.onTouch(TouchEvent)` 原始触摸事件自行复刻。
    @State var swipeStartScreenY: Float64 = 0.0
    @State var swipeTracking: Bool = false

    // `JsonObject.has(key)` 对显式 JSON `null` 值同样返回 true（JsonParser.cj 的
    // parseContent 把 null 当普通值存进 map），不能靠它区分"字段缺失"与"字段显式为
    // null"。`defaultSoundId` 的合法取值域含 0（=Default 本身），所以也不能借道
    // `getInt` 的"缺失返回 0"语义（那会把"显式 null"误判成"没传等于 0"，D-172 同类
    // 陷阱）。JsonParser.cj 不在本 feature allowlist 内，不新增 isNull 访问器，改为
    // 在本文件内直接对原始 JSON 文本做字面量匹配——调用方是本仓已有的 `setPending`
    // 手工拼串（非 `JsonObject.toJsonString()` 序列化，不会有多余转义/空白变体）。
    private func jsonFieldIsExplicitNull(raw: String, field: String): Bool {
        return raw.contains("\"" + field + "\":null") || raw.contains("\"" + field + "\": null")
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("NotificationSoundSelectionPage")
        if (raw.size > 0 && raw != "{}") {
            let obj = JsonParser.parseObject(raw)
            if (obj.has("category")) {
                this.category = obj.getString("category")
            }
            if (obj.has("currentSoundId")) {
                this.selectedId = obj.getInt("currentSoundId")
            }
            if (obj.has("currentAccessHash")) {
                this.selectedAccessHash = obj.getInt("currentAccessHash")
            }
            if (obj.has("defaultSoundId") && !this.jsonFieldIsExplicitNull(raw, "defaultSoundId")) {
                this.hasDefaultSound = true
                this.defaultSoundId = obj.getInt("defaultSoundId")
            }
        }
        this.loadRingtones()
    }

    private func loadRingtones(): Unit {
        let _ = spawn {
            let service = getNotificationSoundSelectionService()
            let (list, _hash) = service.getSavedRingtones(0)
            launch {
                this.cloudRingtones = list
                this.isLoading = false
                // diag-suite_settings_notifications-TC-0445-round3.md 处方4（F-3b）：
                // 删除此前"列表为空且未设置/无 defaultSoundId → 静默改写成 -1(None)"的
                // 兜底。源侧 NotificationSoundSelection.swift:366
                // `NotificationSoundSelectionState(selectedSound: currentSound)` 逐字
                // 采用调用方传入值，不做任何兜底；唯一的规整
                // （NotificationSoundList.swift:378-394 resolvedNotificationSound）方向是
                // `.cloud` 未命中 → 落到默认云铃声，永远不会变成 `.none`。目标侧此前的
                // 兜底方向相反（落到"无声"），且会被 onDone() 原样提交、静默把该分类铃声
                // 写成无声——按处方删除后 `selectedId` 保持调用方传入值，`None` 行不再被
                // 错误勾选，onDone() 提交的也是进屏时的原值。
                // 路由参数只带 currentSoundId/currentAccessHash，云端条目的
                // file_reference 会周期性轮换；用刚拉到的列表条目重新对齐
                // accessHash/fileRef，避免拿调用方传来的、可能已过期的引用去提交。
                if (this.selectedId > 0) {
                    for (entry in list) {
                        if (entry.id == this.selectedId) {
                            this.selectedAccessHash = entry.accessHash
                            this.selectedFileRef = entry.fileReference
                            break
                        }
                    }
                }
            }
        }
    }

    private func onSelectDefault(): Unit {
        this.selectedId = 0
        this.selectedAccessHash = 0
        this.selectedFileRef = Array<Byte>(0, repeat: 0)
    }

    private func onSelectNone(): Unit {
        this.selectedId = -1
        this.selectedAccessHash = 0
        this.selectedFileRef = Array<Byte>(0, repeat: 0)
    }

    private func onSelectSound(entry: RingtoneEntry): Unit {
        this.selectedId = entry.id
        this.selectedAccessHash = entry.accessHash
        this.selectedFileRef = entry.fileReference
    }

    private func onDone(): Unit {
        let service = getNotificationSoundSelectionService()
        service.commitSelection(this.category, this.selectedId, this.selectedAccessHash, this.selectedFileRef)
        routerPop()
    }

    private func onCancel(): Unit {
        routerPop()
    }

    /**
     * F-3（diag-suite_settings_notifications-TC-0446.md round2）：下滑交互式关闭
     * （对位源 `NotificationSoundSelection.swift:427 controller.enableInteractiveDismiss = true`）。
     * 本仓已安装的 Cangjie SDK（`~/.cangjie-sdk/6.1/cangjie/api/modules/linux_ohos_aarch64_cjnative/
     * ohos/ohos.arkui.component.common.cj.d`，14354 行全量核对）**没有**
     * PanGesture/TapGesture/LongPressGesture/GestureEvent 手势识别子系统，也没有 `.gesture(...)`
     * 修饰符——该 SDK 版本未链接手势 API（`cangjie-kb` 与 `src/reference/arkui_cangjie_wrapper`
     * 均未给出可编译验证的 PanGesture 签名，判定为环境缺口而非查询不到位，见交付报告）。
     * 改用同一文件里确认存在的底层原语 `.onTouch(TouchEvent)` / `TouchType` / `TouchObject.screenY`
     * 自行复刻等价行为（D4.4：源侧有该能力、仓颉无对应高层 API 时允许从底层自实现）：
     * `Down` 记起点 `screenY`；`Up` 时用 `changedTouches[0].screenY` 算总下滑位移，超阈值才
     * `onCancel()`（与 ✕ 路径同一语义：只 pop、不提交）。本实现不做逐帧跟手位移，未超阈值时
     * 不产生任何状态改变——天然满足"回弹"要求（没有位移就无需归位）。
     * 绑定在导航栏 Row（非 Scroll 内容区）而非整页，避免与 `Scroll`（:约 305 行起）的原生
     * 纵向滚动冲突。
     */
    private func onHeaderTouch(event: TouchEvent): Unit {
        match (event.eventType) {
            case TouchType.Down =>
                if (event.touches.size > 0) {
                    this.swipeStartScreenY = event.touches[0].screenY
                    this.swipeTracking = true
                }
            case TouchType.Up =>
                if (this.swipeTracking && event.changedTouches.size > 0) {
                    let deltaY = event.changedTouches[0].screenY - this.swipeStartScreenY
                    if (deltaY > 100.0) {
                        this.onCancel()
                    }
                }
                this.swipeTracking = false
            case TouchType.Cancel =>
                this.swipeTracking = false
            case _ => ()
        }
    }

    /**
     * F-2（diag-suite_settings_notifications-TC-0446.md round2）：按内置分类过滤 `cloudRingtones`。
     * `TELEGRAM TONES` 只显示自定义上传（对位源 `cloudSounds` 过滤条件
     * `CloudSoundBuiltinCategory(id:) == nil`）；`ALERT TONES`/`CLASSIC` 分别显示
     * `Modern`/`Classic`（对位源 `modernSounds`/`classicSounds`）。build() 内禁止 let/var
     * 声明（S-005），过滤逻辑必须放在 build() 外的普通函数里，由 build() 只调用。
     * `CloudSoundBuiltinCategory` 未 derive `Equatable`，用 `match` 而非 `==` 判等，
     * 三段各自一个函数比传参判等更不依赖未确认的运算符重载。
     */
    private func customCloudRingtones(): Array<RingtoneEntry> {
        let result = ArrayList<RingtoneEntry>()
        for (entry in this.cloudRingtones) {
            match (classifyCloudSound(entry.id)) {
                case CloudSoundBuiltinCategory.Custom => result.add(entry)
                case _ => ()
            }
        }
        return result.toArray()
    }

    private func modernCloudRingtones(): Array<RingtoneEntry> {
        let result = ArrayList<RingtoneEntry>()
        for (entry in this.cloudRingtones) {
            match (classifyCloudSound(entry.id)) {
                case CloudSoundBuiltinCategory.Modern => result.add(entry)
                case _ => ()
            }
        }
        return result.toArray()
    }

    private func classicCloudRingtones(): Array<RingtoneEntry> {
        let result = ArrayList<RingtoneEntry>()
        for (entry in this.cloudRingtones) {
            match (classifyCloudSound(entry.id)) {
                case CloudSoundBuiltinCategory.Classic => result.add(entry)
                case _ => ()
            }
        }
        return result.toArray()
    }

    /**
     * A1（`diag-suite_settings_notifications-TC-0449-round4.md` §6.1）：`Upload Sound`
     * 必须交给**系统**文档选择器，选择域是设备文档域。此前这里只翻一个页内 `@State`
     * 再自绘覆盖层包 `components/FileBrowser`（只能看应用沙箱的 `documents/`、`videos/`
     * 与 files 根），用户放在设备任意位置的 mp3 永远看不到——那是结构级差异，不是外观差异。
     * 现在改为经 `NotificationSoundSelectionService.requestMp3Document()` 走反转链路
     * （对位源 `NotificationSoundSelection.swift:500 legacyICloudFilePicker`）。
     * `components/FileBrowser` 本身无缺陷、仍被 `pages/ChatRoomPage.cj:3455` 的附件发送
     * 正当使用，本页只是不再消费它。
     */
    private func onUploadClick(): Unit {
        getNotificationSoundSelectionService().requestMp3Document({ path: String, name: String =>
            // S-001：反转回调不在 UI 线程，而 onFileSelected 会写 `isUploading`/`statusMessage`
            // 两个 @State，必须回主线程再写。同 pages/ChatRoomPage.cj:3793 的相册反转回调。
            launch { this.onFileSelected(path, name, "audio/mpeg") }
        })
    }

    /**
     * A2（同报告 §6.1 边界条件 3）：格式过滤已上移到**系统选择器层**
     * （`requestMp3Document` 传 `suffixes: [".mp3"]` → `DocumentSelectOptions.fileSuffixFilters`），
     * 与源侧 `documentTypes: ["public.mp3"]` 同一位置——非 mp3 在界面上根本不出现。
     * 因此这里不再保留选中后的 `endsWith(".mp3")` 兜底与随之而来的
     * `statusMessage` 文案：源侧在这个位置没有任何格式分支（X11），保留它就是保留一条
     * 源侧不存在的 UI 文案。
     *
     * X1（大小闸门，`diag-suite_settings_notifications-TC-0449-round6.md` 改动2）：
     * 读完文件后、`uploadRingtone` 之前先取阈值（`service.getRingtoneLimits()`）比对，
     * 命中即拦截、**不发 RPC**（源 `NotificationSoundSelection.swift:542` 同形）。
     * X2（时长闸门）本轮**不做**——目标侧没有取音频时长的能力
     * （`ets/interop/impls/AudioMetadataImpl.ets` 未建、`InteropRegistry.ets` 注册行未授权，
     * 归属 `set_account_identity`，本轮 allowlist 只有本页与本 service 两个 `.cj` 文件），
     * 已在交付报告 Hand-off 声明为已知限制，D2/D3 仍会 FAIL。
     */
    private func onFileSelected(path: String, fileName: String, mimeType: String): Unit {
        this.isUploading = true
        this.statusMessage = ""
        let _ = spawn {
            var success = false
            var oversized = false
            var maxSizeBytesHit: Int64 = 0
            try {
                let data = this.readFileBytes(path)
                if (data.size > 0) {
                    let service = getNotificationSoundSelectionService()
                    let (maxSizeBytes, _maxDurationSecs) = service.getRingtoneLimits()
                    if (data.size > maxSizeBytes) {
                        oversized = true
                        maxSizeBytesHit = maxSizeBytes
                    } else {
                        let (docId, accessHash, fileRef) = service.uploadRingtone(data, fileName)
                        if (docId != 0) {
                            let saved = service.saveRingtone(docId, accessHash, fileRef)
                            if (saved) {
                                success = true
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[NSND] Upload error: ${e}")
            }
            let ok = success
            let wasOversized = oversized
            let maxBytes = maxSizeBytesHit
            let uploadedName = fileName
            launch {
                this.isUploading = false
                if (wasOversized) {
                    this.showOversizedToast(maxBytes)
                } else if (ok) {
                    this.loadRingtones()
                    this.showUploadSuccessToast(uploadedName)
                } else {
                    this.statusMessage = "Upload failed"
                }
            }
        }
    }

    /**
     * X1 超限提示条（改动3）：`showUndo` 已存在的载体，`showAction: false`（无 UNDO
     * 按钮）、`durationMs: 5000`（5 秒自动消失）——源
     * `UndoOverlayController.swift:46 case notificationSoundAdded` 与
     * `.info(timeout: nil, customUndoText: nil)` 同形（对位源 `:542-545`）。文案用仓内已有
     * `LegacyMediaPickerService.formatFileSize`（整除不带小数，`102400 → "100 KB"`，
     * 正是 D1 要的逐字文案；不用 `ListMessageService.cj:200` 那个，它会输出 `100.0 KB`）。
     */
    private func showOversizedToast(maxSizeBytes: Int64): Unit {
        let sizeText = getLegacyMediaPickerService().formatFileSize(maxSizeBytes)
        let _ = spawn {
            let loaded = ensureOversizedIconLoaded()
            let icon = if (loaded) { currentOversizedIconFrame() } else { None<PixelMap> }
            launch {
                getUndoToastService().showUndo(
                    "File is over ${sizeText}.",
                    title: "Audio is too large",
                    iconPixelMap: icon,
                    showAction: false,
                    showProgress: false,
                    durationMs: 5000,
                    onUndo: { => () },
                    onCommit: { => () }
                )
            }
        }
    }

    /**
     * 成功提示条（改动3/5）：同一载体，同样 `showAction: false` / `durationMs: 5000`。
     * 文件名粗体渲染（C2）本轮不做——`components/UndoToast.cj` 正文尚无富文本切分能力，
     * 归 `uif_undoui`，本轮未开写权，见交付报告已知限制。
     */
    private func showUploadSuccessToast(fileName: String): Unit {
        let _ = spawn {
            let loaded = ensureSuccessIconLoaded()
            let icon = if (loaded) { currentSuccessIconFrame() } else { None<PixelMap> }
            launch {
                getUndoToastService().showUndo(
                    "The sound ${fileName} was added to your Telegram tones.",
                    title: "Sound Added",
                    iconPixelMap: icon,
                    showAction: false,
                    showProgress: false,
                    durationMs: 5000,
                    onUndo: { => () },
                    onCommit: { => () }
                )
            }
        }
    }

    private func readFileBytes(path: String): Array<Byte> {
        let result = Array<Byte>(0, repeat: 0)
        try {
            let file = FileIo.open(path, mode: 0o0)
            let stat = FileIo.stat(path)
            let data = Array<Byte>(stat.size, repeat: 0)
            let n = FileIo.read(file.fd, data)
            FileIo.close(file)
            if (n > 0) {
                return Array<Byte>(n, { i: Int64 => data[i] })
            }
        } catch (_e: Exception) {}
        return result
    }

    // F-A1d：删除是破坏性动作（从账号收藏移除云端铃声），源侧
    // `NotificationSoundSelection.swift:451-478` 二次确认（`PeerInfo_DeleteToneTitle` /
    // `PeerInfo_DeleteToneText`），目标侧此前点 Delete 即删、无确认——按仓内既有
    // `confirmDestructive` 手法（`pages/DataStorageSettingsPage.cj:627-646`）补上，
    // 必须在 .onClick 里同步调用，不能包进 spawn/launch。
    private func confirmDeleteSound(entry: RingtoneEntry): Unit {
        let title = if (entry.title.size > 0) { entry.title } else { "Sound ${entry.id}" }
        let uiCtx = getUIContext()
        let confirmBtn = AlertDialogButtonOptions(
            value: "Delete", fontColor: 0xFF3B30,
            action: {=> this.deleteSound(entry) }
        )
        let cancelBtn = AlertDialogButtonOptions(
            value: "Cancel", action: {=> ()}
        )
        uiCtx.showAlertDialog(AlertDialogParamWithOptions(
            title: "Delete Tone",
            message: "Delete \"${title}\"?",
            autoCancel: true,
            buttons: [confirmBtn, cancelBtn],
            buttonDirection: DialogButtonDirection.Vertical,
            textStyle: WordBreak.BreakWord
        ))
    }

    private func deleteSound(entry: RingtoneEntry): Unit {
        let _ = spawn {
            let service = getNotificationSoundSelectionService()
            let ok = service.deleteRingtone(entry.id, entry.accessHash, entry.fileReference)
            launch {
                if (ok) {
                    if (this.selectedId == entry.id) {
                        this.selectedId = -1
                        this.selectedAccessHash = 0
                        this.selectedFileRef = Array<Byte>(0, repeat: 0)
                    }
                    this.loadRingtones()
                }
            }
        }
    }

    public func build() {
        Column {
            Row {
                // F-A1d：导航键文字化 → 真实图标资源，对位源 `.icon(.close)`/`.icon(.done)`
                // （`NotificationSoundSelection.swift:408-414`）。复用仓内既有同形状纳入
                // allowlist 的资源（`username_nav_ic_close`/`username_nav_ic_done`，见
                // `pages/UsernameSettingsPage.cj:401,417`），不是新造字形/占位。
                Image(@r(app.media.username_nav_ic_close))
                    .width(22)
                    .height(22)
                    .fillColor(0x000000)
                    .onClick({ _ => this.onCancel() })
                Blank().layoutWeight(1)
                Text(trSource("Text Tone"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                Blank().layoutWeight(1)
                Image(@r(app.media.username_nav_ic_done))
                    .width(22)
                    .height(22)
                    .fillColor(0x317AFF)
                    .onClick({ _ => this.onDone() })
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)
            // F-3：下滑关闭手势绑定在导航栏（非 Scroll 内容区），避免与下方 Scroll
            // （:约 386 行起）的原生纵向滚动手势冲突。见 onHeaderTouch() 头部注释。
            .onTouch({ event: TouchEvent => this.onHeaderTouch(event) })

            if (this.isLoading) {
                Column {
                    LoadingProgress().width(32).height(32)
                    Text(trSource("Loading..."))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 8)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
            Scroll {
                Column {
                    // F-A1d 分节名：`CLOUD TONES` 是目标侧自造标题，源
                    // `Notifications_TelegramTones`（`Localizable.strings:7562`）实际文案是
                    // "TELEGRAM TONES"。
                    Text(trSource("TELEGRAM TONES"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, top: 16, bottom: 8)
                        .width(100.percent)

                    // F-2：只显示自定义上传（非内置）的云端铃声，内置铃声按分类分别在
                    // ALERT TONES / CLASSIC 两段渲染（见下）。
                    ForEach(this.customCloudRingtones(), itemGenerator: { entry: RingtoneEntry, idx: Int64 =>
                        Row {
                            Column {
                                Row {
                                    // TC-0446-round7 M2：源侧 `ItemListCheckboxItem(style: .left)`
                                    // 恒预留行首 62pt 勾选/图标带，标题从带后起排（对位
                                    // `ItemListCheckboxItem.swift:205,213-218,377,383-385`）。此前
                                    // 该带完全缺失，勾选图标被推到行尾。
                                    Column {
                                        if (this.selectedId == entry.id) {
                                            // F-A1d 勾选标记：`✓` 字形 → 真实矢量勾选图标
                                            // （对位源 `generateItemListCheckIcon`），复用仓内已
                                            // 转换、已在多处同类"选中态列表行"场景使用的资源
                                            // （`media_ic_check`，见
                                            // `pages/SelectivePrivacySettingsPage.cj:769` 等）。
                                            Image(@r(app.media.media_ic_check))
                                                .width(16)
                                                .height(16)
                                                .fillColor(0x317AFF)
                                        }
                                    }
                                    .width(62)
                                    .height(56)
                                    .justifyContent(FlexAlign.Center)
                                    .alignItems(HorizontalAlign.Center)

                                    Text(if (entry.title.size > 0) { entry.title } else { "Sound ${entry.id}" })
                                        .fontSize(17)
                                        .fontColor(0x000000)
                                        .layoutWeight(1)
                                }
                                .width(100.percent)
                            }
                            .layoutWeight(1)
                            .onClick({ _ => this.onSelectSound(entry) })
                            Text(trSource("Delete"))
                                .fontSize(14)
                                .fontColor(0xFF3B30)
                                .margin(left: 8)
                                .onClick({ _ => this.confirmDeleteSound(entry) })
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 0, right: 16)
                        .alignItems(VerticalAlign.Center)
                    })

                    Row {
                        // TC-0446-round7 M1+M2：本行是 C3 判红处。此前挂的是
                        // `Item List/Icons/Upload.imageset/upload.pdf`（属别处「设置页彩色圆角块
                        // 图标」族，`PresentationResourcesSettings.upload`），且被 `layoutWeight(1)`
                        // 挤到行右端。源侧实为 `PresentationResourcesItemList.uploadToneIcon`
                        // → `Settings/UploadTone.imageset/addtone_30.pdf`，恒显（`iconSize: nil`
                        // ⇒ 30×30），落在与其余 5 行同一条源侧 `ItemListCheckboxItem(style: .left)`
                        // 62pt 行首带里（对位 `ItemListCheckboxItem.swift:205,213-218,377,383-385`）。
                        // 源侧无「上传中隐藏图标」概念，故槽内图标改为恒显，`LoadingProgress` 移到
                        // 行尾单独作为被动指示（round6 裁定保留，不与图标互斥）。
                        Column {
                            Image(@r(app.media.settings_ic_upload_tone))
                                .width(30)
                                .height(30)
                                .fillColor(0x317AFF)
                        }
                        .width(62)
                        .height(56)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)

                        Text(if (this.isUploading) { "Uploading..." } else { "Upload Sound" })
                            .fontSize(17)
                            .fontColor(if (this.isUploading) { 0x8E8E93 } else { 0x317AFF })
                            .layoutWeight(1)
                        if (this.isUploading) {
                            LoadingProgress().width(20).height(20)
                        }
                    }
                    // Coordinator 裁定（round6 冻结解除，`diag-suite_settings_notifications-TC-0449-round6.md`
                    // 已核准）：不再 `.enabled(!this.isUploading)` 禁用该行。源侧
                    // `NotificationSoundSelection.swift:33-34 NotificationSoundSelectionState`
                    // 只有 `selectedSound` 一个字段，根本没有"上传中"状态；`:186`
                    // 上传项是 `ItemListCheckboxItem(... checked: false, action: {...})`，
                    // 不传 `enabled:` 参数——源侧上传期间该行保持可点。禁用是目标侧真实偏离，
                    // 按源侧改掉是忠实移植，不是放宽判据。进度指示（"Uploading..."/
                    // `LoadingProgress`）与红字 `statusMessage` 是"只增加被动指示、不削减
                    // 动作"，按裁定分流规则不判红，保留不动。
                    .width(100.percent)
                    .height(56)
                    .padding(left: 0, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ => this.onUploadClick() })

                    // F-1（diag-suite_settings_notifications-TC-0446.md round2）：脚注，对位源
                    // `.cloudInfo(Notifications_MessageSoundInfo)`（`NotificationSoundSelection.swift:233`），
                    // 文案取自 `Localizable.strings:7565`。与 `uploadSound` entry 同一分节、恒渲染
                    // （源侧位于 `if let notificationSoundList` 内，本页 `notificationSoundList`
                    // 恒非空，故不依赖 `cloudRingtones` 是否为空）。
                    Text(trSource("Press and hold a short voice note or mp3 file in any chat and select \"Save for Notifications\". It will appear here."))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, right: 16, top: 8, bottom: 8)
                        .width(100.percent)

                    Text(trSource("ALERT TONES"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, top: 24, bottom: 8)
                        .width(100.percent)

                    // F-A1b：`Default` 行只在调用方传了非 null `defaultSoundId` 时渲染
                    // （对位源 `:236-238 if let defaultSound`）。N1 分类路径恒传 null
                    // （源 `NotificationsPeerCategoryController.swift:870 defaultSound: nil`），
                    // 该路径下不应出现"回退到某个更高层默认值"的选项。
                    if (this.hasDefaultSound) {
                        Row {
                            // TC-0446-round7 M2：同一条源侧 62pt 行首带（见 Upload Sound 行注释）。
                            Column {
                                if (this.selectedId == 0) {
                                    Image(@r(app.media.media_ic_check))
                                        .width(16)
                                        .height(16)
                                        .fillColor(0x317AFF)
                                }
                            }
                            .width(62)
                            .height(56)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)

                            Text(trSource("Default"))
                                .fontSize(17)
                                .fontColor(0x000000)
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 0, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => this.onSelectDefault() })
                    }

                    Row {
                        // TC-0446-round7 M2：同一条源侧 62pt 行首带（见 Upload Sound 行注释）。
                        Column {
                            if (this.selectedId == -1) {
                                Image(@r(app.media.media_ic_check))
                                    .width(16)
                                    .height(16)
                                    .fillColor(0x317AFF)
                            }
                        }
                        .width(62)
                        .height(56)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)

                        Text(trSource("None"))
                            .fontSize(17)
                            .fontColor(0x000000)
                            .layoutWeight(1)
                    }
                    .width(100.percent)
                    .height(56)
                    .padding(left: 0, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ => this.onSelectNone() })

                    // F-2：ALERT TONES 段的现代内置铃声（对位源 `modernSounds` 循环，
                    // `NotificationSoundSelection.swift:240-243`）。不可删除
                    // （对位源 `canBeDeleted: false`），复用 :399-433 已有的行渲染形状但去掉
                    // Delete 控件。
                    ForEach(this.modernCloudRingtones(), itemGenerator: { entry: RingtoneEntry, idx: Int64 =>
                        Row {
                            // TC-0446-round7 M2：同一条源侧 62pt 行首带（见 Upload Sound 行注释）。
                            Column {
                                if (this.selectedId == entry.id) {
                                    Image(@r(app.media.media_ic_check))
                                        .width(16)
                                        .height(16)
                                        .fillColor(0x317AFF)
                                }
                            }
                            .width(62)
                            .height(56)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)

                            Text(if (entry.title.size > 0) { entry.title } else { "Sound ${entry.id}" })
                                .fontSize(17)
                                .fontColor(0x000000)
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 0, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => this.onSelectSound(entry) })
                    })

                    // F-A1d 分节名：`CLASSIC TONES` → 源 `Notifications_ClassicTones`
                    // （`Localizable.strings:789`）实际文案是 "CLASSIC"。
                    Text(trSource("CLASSIC"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, top: 24, bottom: 8)
                        .width(100.percent)

                    // F-2（diag-suite_settings_notifications-TC-0446.md round2）：CLASSIC 段的
                    // 经典内置铃声（对位源 `classicSounds` 循环，`NotificationSoundSelection.swift:245-249`）。
                    // 替换此前的静态占位文本 `Built-in classic tones (deferred)`。不可删除
                    // （对位源 `canBeDeleted: false`）。
                    ForEach(this.classicCloudRingtones(), itemGenerator: { entry: RingtoneEntry, idx: Int64 =>
                        Row {
                            // TC-0446-round7 M2：同一条源侧 62pt 行首带（见 Upload Sound 行注释）。
                            Column {
                                if (this.selectedId == entry.id) {
                                    Image(@r(app.media.media_ic_check))
                                        .width(16)
                                        .height(16)
                                        .fillColor(0x317AFF)
                                }
                            }
                            .width(62)
                            .height(56)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)

                            Text(if (entry.title.size > 0) { entry.title } else { "Sound ${entry.id}" })
                                .fontSize(17)
                                .fontColor(0x000000)
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 0, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => this.onSelectSound(entry) })
                    })

                    if (this.statusMessage.size > 0) {
                        Text(this.statusMessage)
                            .fontSize(14)
                            .fontColor(0xFF3B30)
                            .margin(left: 16, bottom: 16)
                            .width(100.percent)
                    }
                }
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16)
                // F-2 之前末尾靠 "Built-in classic tones (deferred)" 占位文本自身的
                // `.margin(bottom: 32)` 撑住卡片底部间距；占位文本被换成动态 ForEach 后
                // 不能再假设固定的"最后一个子节点"，改在容器上补一个恒定底部 padding。
                .padding(bottom: 24)
            }
            .layoutWeight(1)
            .backgroundColor(0xF2F2F7)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
