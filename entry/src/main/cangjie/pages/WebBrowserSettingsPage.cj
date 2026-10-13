package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos.web.webview.WebCookieManager
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.regex.*
import std.unicode.*
// Timer 在 std.sync（SDK std.sync.cj.d:2872 class Timer / :2893 static func once(Duration, ()->Unit)）。
// Duration 是 std.core 的 struct（core_package_structs），默认可见，显式 import std.time.Duration
// 反而编译失败：`'Duration' is not accessible in package 'std.time'`（本轮实测）。
// 一次性延时的既有调用点见 components/AnimatedEmojiEffectComponent.cj:120。
import std.sync.Timer
// RC-B（diag-suite_settings_data_storage-TC-0435-round3.md F-B）：Cookies cleared 提示条图标，
// 照抄 services/ProfileMuteAnimationService.cj 已在设备上跑通的 rawfile→Lottie→PixelMap 通路
// （该服务归另一 feature，不导入，这里按同一套写法自建一份页面本地缓存）。
// CatchupStyle 用于 Timer.repeat 的补帧策略，同型先例 components/ProfileMuteIcon.cj:69。
import std.sync.Monitor
import std.sync.CatchupStyle
// kit.ArkUI.* 已在本包（pages）内多个文件里导出同名 Size 类型，直接 import kit.ImageKit.Size
// 会在包级产生 "ambiguous use of 'Size'"（本轮实测）；同型先例 pages/CropEditorScreen.cj:7
// `import kit.ImageKit.Size as IKSize`，这里照抄改名导入。
import kit.ImageKit.Size as IKSize
import kit.ImageKit.{createPixelMap, InitializationOptions, PixelMap, PixelMapFormat, AlphaType}
import ohos_app_cangjie_entry.bindings.getTelegramLottieNative
import ohos_app_cangjie_entry.utils.readRawFileBytes
import ohos_app_cangjie_entry.components.getEmptyAnimatedEmojiPixelMap
import ohos_app_cangjie_entry.services.{
    getSettingsService,
    getBrowserService,
    triggerHaptic,
    WebBrowserException,
    WebBrowserSettingsState
}
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSectionFooter,
    ItemListSeparator,
    ItemListButtonRow,
    ItemListNavBarBackground,
    itemListNavBarBackgroundAlpha255,
    ITEM_LIST_NAVBAR_H,
    ITEM_LIST_ACCENT,
    ITEM_LIST_TEXT_PRIMARY,
    ITEM_LIST_TEXT_SECONDARY,
    ITEM_LIST_BG_CARD,
    ITEM_LIST_BG_GROUPED
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.safeAnimateTo
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

// ======================================================================
// 候选浏览器表（FIX-3 / diag-suite_settings_data_storage-TC-0435.md §6.3）
// ======================================================================

/**
 * 一个 `OPEN LINKS IN` 候选项。对位源侧 `availableOpenInOptions(...)` 产出的 `OpenInOption`
 * （`identifier` + `title`）。
 */
public class WebBrowserOption {
    public var identifier: String = ""
    public var title: String = ""
    public var isTelegram: Bool = false

    public init(identifier: String, title: String, isTelegram: Bool) {
        this.identifier = identifier
        this.title = title
        this.isTelegram = isTelegram
    }
}

/**
 * 候选表。第 0 行恒为 `Telegram`（源侧 WebBrowserSettingsController.swift:333-341 的固定首行），
 * 其后是"本机能处理 http(s) 链接的外部浏览器"。
 *
 * ⚠ 平台差异（FIX-3 的 fallback，已登记进 featureX.json 的 unresolved_api_decisions[]）：
 * 源侧靠 iOS `canOpenUrl` 逐个探测已装浏览器；诊断报告给的目标侧做法是"用 bundleManager 的
 * 隐式 Want 查询取可处理 `action=ohos.want.action.viewData` + `entity.system.browsable` +
 * `uri=https://` 的应用列表"。该查询在 Cangjie 侧**没有绑定**：已安装 SDK 6.1 的
 * `ohos/ohos.bundle.bundle_manager.cj.d` 里 `BundleManager` 只有
 * `getBundleInfoForSelf` / `getProfileByAbility` / `canOpenLink` 三个静态方法，
 * `DefaultAppManager` 只有 `isDefaultApplication(appType)`（问的是"调用方自己是不是默认应用"，
 * 不能枚举、也拿不到别人的 bundleName/label/icon）；`queryAbilityInfo` 一类枚举接口在
 * `docs_cangjie/.../cj-apis-bundle_manager.md` 与 cangjie-kb 检索里同样为 0 命中。
 *
 * 因此这里落到"枚举不可得"的平台等价底：外部这一路收敛成**一行**「Default Browser」
 * （identifier = 空串 = 系统默认，沿用 `BrowserService.getDefaultBrowserId()` 早已定义的
 * "空字符串表示使用系统默认"语义，见 services/BrowserService.cj 该方法的文档注释）。
 * 这不是凭空造的 `Safari` 行（HarmonyOS 无 Safari，源侧那个硬编码字面量按 §4.3 不适用于
 * 目标侧），而是"外部浏览器"这一路在无法枚举时唯一可表达、且**真实可达**的选项——
 * 目标侧打开外链走的就是系统隐式 Want 分发，落点即系统默认浏览器。
 * 保留这一行也是 FIX-5 删除 Data and Storage 自造分节的前提：否则"切换应用内/外部浏览器"
 * 这条当前唯一可达的能力会归零，构成净退化（TC-0435-round2 增量 D-2）。
 */
public func webBrowserOptions(): Array<WebBrowserOption> {
    return [
        WebBrowserOption("", "Telegram", true),
        WebBrowserOption("system", "Default Browser", false)
    ]
}

/**
 * `Privacy and Security ▸ Open Links in` 行的右值，以及本屏选中勾的**同一个**取值口径。
 *
 * FIX-4（§6.4）+ TC-0435-round2 增量 D-1：源侧入口 label 与屏内选中态由同一份账号级
 * `AccountWebBrowserSettings` 驱动，这是结构性事实，不是可选实现细节。本函数是全仓唯一的
 * 推导入口，`pages/PrivacySettingsPage.cj` 与本屏都调它，因此不可能再出现 round2 观察到的
 * "入口读 Safari 而开关读 OFF"那种两处读数打架。
 *
 * 逐支对位源侧 PrivacyAndSecurityController.swift:1622-1636：
 *   1. openExternalBrowser == false ⇒ "Telegram"；
 *   2. openExternalBrowser == true ⇒ 取 BrowserService.getDefaultBrowserId()，为空串（未配置，
 *      即"从未选过外部浏览器"）时**替换**成 "system" 哨兵再查表（对位源侧 :1625-1627 把
 *      nil/inApp/inAppSafari 替换成 "safari" 再查表这条非对称——label 做替换，见下方
 *      isOptionChecked()/selectOption() 的对照注释：那两处**不做**这个替换，因此屏内选中态
 *      与本函数的 label 呈现在"未配置"状态下天然不同：屏内零勾、label 仍读 Default Browser），
 *      按 identifier 查得则用该候选标题；
 *   3. 查不到（本机无任何可处理 http(s) 的应用）⇒ 外部打开本就不可能达成，按 in-app 呈现，
 *      label 取 "Telegram"。**不**沿用 iOS 的硬编码字面量 "Safari"。此支现仅在候选表被改动、
 *      替换后的哨兵仍查不到候选行时才可达。
 *
 * 只读本地 Preferences 缓存，不发网络请求（调用点在 UI 线程，R-138）。
 */
public func webBrowserSelectionLabel(): String {
    if (!currentOpenExternalBrowser()) {
        return "Telegram"
    }
    var identifier = getBrowserService().getDefaultBrowserId()
    if (identifier == "") {
        identifier = "system"
    }
    for (option in webBrowserOptions()) {
        if (!option.isTelegram && option.identifier == identifier) {
            return option.title
        }
    }
    return "Telegram"
}

/**
 * 账号级 `openExternalBrowser` 的当前值（缓存读，无网络）。
 *
 * TC-0435-round2 增量 D-1 边界条件：口径只认账号级设置，**不得**改用
 * `services/BrowserService.cj` 的本地 `open_external_browser` 键——两者不同源正是 round2
 * 那条矛盾的成因。缓存尚未落盘时取 `AccountWebBrowserSettings.defaultSettings` 的默认值 false，
 * 而 `BrowserService.getOpenExternalBrowser()`（:250）在这种情况下回退读本地镜像键；
 * 二者只在"账号缓存尚未落盘"这一窗口内可能不同，缓存一落盘就同解。
 */
public func currentOpenExternalBrowser(): Bool {
    let svc = getSettingsService()
    if (!svc.hasWebBrowserSettingsCache()) {
        return false
    }
    return svc.getCachedWebBrowserSettings().openExternalBrowser
}

// ======================================================================
// Add Website 弹层的逐字符准入正则（FIX-7 / TC-0436 §6.2）
// ======================================================================
//
// 两条正则**原样照搬**源侧 WebBrowserDomainController.swift:68-69，不改写、不自造等价实现。
// 每次编辑拿到"编辑后的完整文本"，domainRegex 命中 **且** pathRegex 不命中才接受本次编辑，
// 否则整次编辑被丢弃、字段保持编辑前的值、无任何提示。
// 验收锚点（报告逐字给出）：逐字符键入 `a.com/x` 后字段应为 `a.comx`；
// `user@example.com` → `userexample.com`；`.com` → `com`。
let WEB_DOMAIN_ACCEPT_PATTERN: String = #"^(https?://)?([a-zA-Z0-9-]+\.?)*([a-zA-Z]*)?(:)?(/)?$"#
let WEB_DOMAIN_PATH_PATTERN: String = #"^(https?://)?([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,6}/"#

var _webDomainAcceptRegex: Option<Regex> = None
var _webDomainPathRegex: Option<Regex> = None

func webDomainAcceptRegex(): Option<Regex> {
    match (_webDomainAcceptRegex) {
        case Some(r) => return Some(r)
        case None => ()
    }
    try {
        let r = Regex(WEB_DOMAIN_ACCEPT_PATTERN)
        _webDomainAcceptRegex = Some(r)
        return Some(r)
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[WebBrowserSettings] accept regex compile failed: ${e}")
        return None
    }
}

func webDomainPathRegex(): Option<Regex> {
    match (_webDomainPathRegex) {
        case Some(r) => return Some(r)
        case None => ()
    }
    try {
        let r = Regex(WEB_DOMAIN_PATH_PATTERN)
        _webDomainPathRegex = Some(r)
        return Some(r)
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[WebBrowserSettings] path regex compile failed: ${e}")
        return None
    }
}

/**
 * 源侧 `shouldChangeText` 的准入判定：domainRegex 命中且 pathRegex 不命中。
 *
 * ⚠ 两侧的"命中"语义**不同**，此处等价是**推出来的**、不是天然的：
 * 仓颉 `Regex.matches(input)` 是**整串匹配**（SDK std.regex.cj.d:387
 * "Tests whether the entire input string matches this pattern"），而源侧
 * `numberOfMatches(in:range:) > 0` 是**子串搜索**。
 * - accept 正则自带 `^…$`，两种语义本就一致；
 * - path 正则只有 `^`、没有 `$`，语义**不**一致——但它只对已经通过 accept 的串起作用，
 *   而 accept 允许的串末尾最多只有一个 `/`（`(:)?(/)?$`），此时"从头匹配到某处"
 *   与"从头匹配到串尾"落在同一个位置 ⇒ 两种语义在本判定的定义域内同解。
 * 报告给的三条锚点（`a.com/x`→`a.comx`、`user@example.com`→`userexample.com`、
 * `.com`→`com`）在整串语义下逐字符推演一致。
 */
public func acceptsWebDomainEdit(updatedText: String): Bool {
    if (updatedText.size == 0) {
        return true
    }
    let accept = webDomainAcceptRegex()
    let path = webDomainPathRegex()
    match ((accept, path)) {
        case (Some(a), Some(p)) => return a.matches(updatedText) && !p.matches(updatedText)
        case _ =>
            // 正则编译失败时不把输入框锁死（宁可放行也不产出一个永远打不进字的字段）。
            return true
    }
}

// ======================================================================
// 例外行的渲染数据（预派生，供 ForEach 闭包直接消费）
// ======================================================================
/**
 * ForEach 的 itemGeneratorFunc 闭包内不允许 let/var 声明（R-107），所以每行显示所需的派生值
 * （首字母占位、删除用 url）在 applyState() 里一次性算好放进本类。
 */
// 例外行定高（源侧 WebBrowserDomainExceptionItem 是两行文本 + 29x29 favicon 的双行条目）：
// 两行文字 17sp + 15sp + 1vp 行距 ≈ 43vp，上下各 8vp 内边距 ⇒ 59vp。
let WEB_EXCEPTION_ROW_H: Float64 = 59.0

public class WebBrowserExceptionRowData {
    public var title: String = ""
    public var domain: String = ""
    public var deleteUrl: String = ""
    public var initial: String = ""
    public var rowKey: String = ""

    public init(title: String, domain: String, deleteUrl: String, initial: String, rowKey: String) {
        this.title = title
        this.domain = domain
        this.deleteUrl = deleteUrl
        this.initial = initial
        this.rowKey = rowKey
    }
}

// ======================================================================
// Cookies cleared 提示条图标（RC-B / diag-suite_settings_data_storage-TC-0435-round3.md F-B）
// ======================================================================

/**
 * `anim_infotip` 帧缓存。写法照抄 `services/ProfileMuteAnimationService.cj`（已在设备上跑通的
 * rawfile → Lottie → PixelMap 通路：`readRawFileBytes` → `getTelegramLottieNative().renderTgs`
 * → `createPixelMap`）——该服务归另一 feature，不在本 feature `target_files` 内，这里不导入它，
 * 按同一套写法在本文件内自建一份页面本地缓存（单一资源，无需 HashMap 分变体键）。
 */
private let INFO_TOAST_ICON_SIZE: Int32 = 36
private let infoToastIconMonitor = Monitor()
private var infoToastIconFrames = ArrayList<PixelMap>()
private var infoToastIconDurationMs: Int32 = 33

/**
 * 源侧 `UndoOverlayControllerNode.swift:277` 用 `colors: ["info1.info1.stroke": bg,
 * "info2.info2.Fill": bg]` 在渲染期把这两个图层实时改色成提示条底色，形成"挖空"观感。本仓
 * `bindings/TelegramLottieNative.cj` 的 rlottie 绑定只暴露整帧栅格化（无按图层名重新着色的
 * 接口，见该文件 `renderTgs`），因此改为渲染后按像素后处理：`anim_infotip.json` 里 info1/info2
 * 两层烘焙色固定为 RGB(57,67,79)（JSON 字面量 0.223529.../0.262745.../0.309803...，已用
 * Python 解析该 JSON 核实），与白色圆环/光点（`Oval`、`luc1`-`luc12`，RGB(255,255,255)）色距
 * 足够大，用色距阈值只替换这两层的烘焙色像素，不误伤白色部分。⚠ 这是近似复刻，不是像素级
 * 还原（边缘抗锯齿的过渡色可能残留极淡的原色边缘）。
 */
private func knockoutInfoTipFrame(source: Array<UInt8>): Array<UInt8> {
    let result = source.clone()
    // 目标：buildInfoToast() 的提示条底色 0xF0202020，这里只取 RGB 部分（0x20,0x20,0x20）。
    let targetR: Int64 = 0x20
    let targetG: Int64 = 0x20
    let targetB: Int64 = 0x20
    let srcR: Int64 = 57
    let srcG: Int64 = 67
    let srcB: Int64 = 79
    var index: Int64 = 0
    while (index + 3 < Int64(result.size)) {
        // BGRA 字节序，同 ProfileMuteAnimationService.tintProfileMuteFrame 的既有约定。
        let b = Int64(result[index])
        let g = Int64(result[index + 1])
        let r = Int64(result[index + 2])
        let alpha = Int64(result[index + 3])
        let dr = r - srcR
        let dg = g - srcG
        let db = b - srcB
        if (alpha > 0 && dr * dr + dg * dg + db * db < 4000) {
            result[index] = UInt8((targetB * alpha) / 255)
            result[index + 1] = UInt8((targetG * alpha) / 255)
            result[index + 2] = UInt8((targetR * alpha) / 255)
        }
        index = index + 4
    }
    return result
}

/** 首次调用触发加载；命中缓存直接返回 true。调用方需在 spawn 里跑（渲染是同步阻塞调用）。 */
private func ensureInfoToastIconLoaded(): Bool {
    synchronized(infoToastIconMonitor) {
        if (infoToastIconFrames.size > 0) { return true }
    }
    match (readRawFileBytes("anim_infotip.json")) {
        case None =>
            Hilog.info(0, "CjTelegram", "[WebBrowserSettings] missing anim_infotip.json")
            return false
        case Some(bytes) =>
            let rendered = getTelegramLottieNative().renderTgs(
                bytes, "web_browser_info_toast_icon", INFO_TOAST_ICON_SIZE, maxFrames: 45
            )
            if (!rendered.success) { return false }
            let frames = ArrayList<PixelMap>()
            let options = InitializationOptions(
                IKSize(INFO_TOAST_ICON_SIZE, INFO_TOAST_ICON_SIZE),
                srcPixelFormat: PixelMapFormat.Bgra8888,
                pixelFormat: PixelMapFormat.Bgra8888,
                alphaType: AlphaType.Premul
            )
            for (frame in rendered.frames) {
                frames.add(createPixelMap(knockoutInfoTipFrame(frame), options))
            }
            synchronized(infoToastIconMonitor) {
                infoToastIconFrames = frames
                infoToastIconDurationMs = rendered.frameDurationMs
            }
            return frames.size > 0
    }
}

private func infoToastIconFrameCount(): Int64 {
    synchronized(infoToastIconMonitor) { return Int64(infoToastIconFrames.size) }
}

private func infoToastIconFrameDurationMs(): Int32 {
    synchronized(infoToastIconMonitor) { return infoToastIconDurationMs }
}

private func infoToastIconFrame(index: Int64): Option<PixelMap> {
    synchronized(infoToastIconMonitor) {
        if (index >= 0 && index < Int64(infoToastIconFrames.size)) {
            return infoToastIconFrames.get(index)
        }
    }
    return None<PixelMap>
}

/**
 * WebBrowserSettingsPage — 对位 `submodules/SettingsUI/Sources/Data and Storage/
 * WebBrowserSettingsController.swift`（屏本体 + Clear Cookies + 域名例外）与
 * `WebBrowserDomainController.swift`（Add Website 弹层）。
 *
 * 本轮 = TC-0435 的 R2（FIX-2/FIX-3/FIX-4/FIX-5）+ TC-0436 的 R3（FIX-6/FIX-7/FIX-8）
 * 合并交付；R1（账号级数据层，services/SettingsService.cj）已在前两轮落地，本屏只消费。
 *
 * 三段（自上而下，顺序与源侧 `webBrowserSettingsControllerEntries` 的 entries 序列一致）：
 *   1. `OPEN LINKS IN` 候选行 + 勾（§6.3 FIX-3）+ 页脚；
 *   2. `Clear Cookies` + 确认 alert + `Cookies cleared.` toast（§6.2 FIX-2）；
 *   3. 域名例外分节（`OPEN IN-APP` / `DON'T OPEN IN-APP` 二选一）+ `Add Website` 弹层 +
 *      左滑删除 + `Delete All Exceptions`（TC-0436 §6.1 FIX-6 / §6.2 FIX-7）。
 *
 * 导航标题 `Web Browser`，左右导航按钮均不放（源侧 leftNavigationButton/rightNavigationButton
 * 都是 nil），只保留返回控件。进屏不加载骨架/菊花：先用缓存渲染完整列表，网络回包后就地更新。
 *
 * 已知限制（详见 featureX.md「已知限制」）：
 *   - 候选表的外部这一路收敛成单行「Default Browser」，理由见 webBrowserOptions() 的注释；
 *   - Clear Cookies 只能清 cookie，localStorage/sessionStorage 在 Cangjie SDK 6.1 无绑定，
 *     见 clearCookies() 的注释；
 *   - 例外行 favicon 恒用运行时绘制的占位方块，见 buildExceptionRows() 的注释；
 *   - `Cookies cleared.` 提示条在本文件内自绘（buildInfoToast()），源侧 `.info` 左侧那枚
 *     Lottie 图标（`anim_infotip`）已随 RC-B（diag-suite_settings_data_storage-TC-0435-
 *     round3.md F-B）落地：`resources/rawfile/anim_infotip.json` 原样迁入 + 消费侧接线，
 *     见 buildInfoToast() / ensureInfoToastIconLoaded() 的注释；两个"挖空"色层
 *     （info1.stroke / info2.Fill）用像素后处理近似复刻（本仓 rlottie 绑定无按图层重着色
 *     接口），不是像素级还原。
 */
@HybridComponentEntry
@Component
public class WebBrowserSettingsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ---- 账号级设置（缓存优先渲染，网络回包后就地更新）----
    @State var openExternalBrowser: Bool = false
    @State var defaultBrowserId: String = ""
    @State var exceptionRows: Array<WebBrowserExceptionRowData> = Array<WebBrowserExceptionRowData>()

    // ItemListSectionHeader.title / ItemListSectionFooter.text 是 @Prop，调用点必须传裸 @State
    // 字段才会随状态变化重新 build()（D-125）。
    @State var exceptionsHeaderText: String = "DON'T OPEN IN-APP"
    @State var exceptionsFooterText: String = "These websites will be always opened in your default browser."

    @State var loaded: Bool = false

    // ---- Add Website 弹层 ----
    @State var showAddDialog: Bool = false
    @State var addInputText: String = ""
    @State var addSubmitting: Bool = false
    @State var addDonePressed: Bool = false
    @State var addShakeOffset: Float64 = 0.0
    // D-160 双相同分支挂载守卫的翻转位：一次被拒的编辑不改变 addInputText（它本来就该保持
    // 编辑前的值），因此没有任何 @State 变化可以驱动 TextInput 把屏上那个已经打进去的
    // 非法字符收回去。ArkUI-CJ 的 TextInput.text 只是 init 形参之一（SDK
    // ohos/ohos.arkui.component.text_input.cj.d:92 的三参构造），该文件 :104-410 的全部
    // public func 里没有 text(...) 属性方法；TextInputController 也只有
    // caretPosition/setTextSelection/stopEditing 三个设置器、没有 setText（同文件
    // :41/:61/:70）⇒ 唯一可用的收回手段就是强制销毁重建该节点。
    @State var addInputRemountToggle: Bool = false
    var addInputId: String = "web_browser_add_website_input"

    // ---- Clear Cookies 的页内 `.info` 提示条（无 Undo 按钮，理由见 showCookiesClearedToast）----
    @State var infoToastVisible: Bool = false
    @State var infoToastText: String = ""
    var infoToastTimer: Option<Timer> = None<Timer>
    // RC-B（diag-suite_settings_data_storage-TC-0435-round3.md F-B）：`anim_infotip` 图标播放态。
    @State var infoToastIconReady: Bool = false
    @State var infoToastIconFrameIndex: Int64 = 0
    var infoToastIconTimer: Option<Timer> = None<Timer>

    // ---- 导航栏渐显 ----
    @State var navBarAlpha255: UInt32 = 0
    @State var prevScrollOffsetVp: Float64 = 0.0
    var contentScroller: Scroller = Scroller()

    // ==================== 生命周期 / 状态装载 ====================

    private func ensureLoaded(): Unit {
        if (this.loaded) {
            return
        }
        this.loaded = true
        // 缓存先渲染（同步、无网络），网络回包后就地更新——源侧同样是"先给本地值，signal 回来
        // 再刷"，进屏不显示骨架/菊花。
        this.applyState(getSettingsService().getCachedWebBrowserSettings())
        this.refreshFromNetwork()
    }

    /** R-138：网络往返只能在 spawn 里跑，回写经 spawn(UIThread) 收敛回 UI 线程（S-001）。 */
    private func refreshFromNetwork(): Unit {
        let _ = spawn {
            let fresh = getSettingsService().getWebBrowserSettings(false)
            spawn(UIThread) { => this.applyState(fresh) }
        }
    }

    private func applyState(state: WebBrowserSettingsState): Unit {
        this.openExternalBrowser = state.openExternalBrowser
        this.defaultBrowserId = getBrowserService().getDefaultBrowserId()
        // 源侧 :347-372：openExternalBrowser 为真时渲染 never 节（inAppExceptions），为假时渲染
        // always 节（externalExceptions）。任何时刻只出现一节。
        if (state.openExternalBrowser) {
            this.exceptionsHeaderText = "OPEN IN-APP"
            this.exceptionsFooterText = "These sites will still be opened in-app."
            this.exceptionRows = WebBrowserSettingsPage.buildRowData(state.inAppExceptions)
        } else {
            this.exceptionsHeaderText = "DON'T OPEN IN-APP"
            this.exceptionsFooterText = "These websites will be always opened in your default browser."
            this.exceptionRows = WebBrowserSettingsPage.buildRowData(state.externalExceptions)
        }
        // 入口行（Privacy and Security ▸ Open Links in）的右值与本屏选中勾同源，改完立刻回灌，
        // 不等下一次冷启动（形状同 pages/PrivacySettingsPage.cj 既有的
        // notifySelectivePrivacyUpdated 回传槽位）。
        notifyWebBrowserSelectionUpdated()
    }

    /** 例外行逆序（源侧 `.reversed()`，最新的在最上）+ 预派生每行的显示字段。 */
    private static func buildRowData(list: ArrayList<WebBrowserException>): Array<WebBrowserExceptionRowData> {
        let result = ArrayList<WebBrowserExceptionRowData>()
        var idx = list.size - 1
        while (idx >= 0) {
            let item = list[idx]
            // 源侧 removeExceptionImpl :531-542：`url = exception.url.isEmpty ? exception.domain : exception.url`
            var deleteUrl = item.url
            if (deleteUrl.size == 0) {
                deleteUrl = item.domain
            }
            result.add(WebBrowserExceptionRowData(
                item.title,
                item.domain,
                deleteUrl,
                WebBrowserSettingsPage.initialFor(item.title),
                "${item.domain}|${item.url}|${idx}"
            ))
            idx = idx - 1
        }
        return result.toArray()
    }

    /** 占位方块上的字母：域名标题首字母大写；标题为空白时用 `#`。 */
    private static func initialFor(title: String): String {
        let trimmed = title.trimAscii()
        if (trimmed.size == 0) {
            return "#"
        }
        return trimmed[0..1].toAsciiUpper()
    }

    // ==================== FIX-3：候选行选中 ====================

    /**
     * 点候选行的写入顺序照搬源侧 updateDefaultBrowser（WebBrowserSettingsController.swift:387-395）：
     * 先写本地 defaultWebBrowser，再调账号级 updateWebBrowserSettings；**勾只在回包成功后随状态
     * 刷新**，不乐观预置、不加 loading、不 disable 行。
     *
     * `Telegram` 行**不写** defaultWebBrowser：源侧该形参是 `String?`，Telegram 行传 `nil`，
     * 走 `else` 一支（:394）——只发远端 openExternalBrowser=false，`withUpdatedDefaultWebBrowser`
     * 根本不执行，用户此前选过的浏览器 id 被**保留**下来。TC-0435 §6.3 的修法文字写的是
     * "`Telegram` 行传空串"，逐字执行会把该 id 抹成 ""；本工程当前取不到任何外部浏览器
     * 候选（见 webBrowserOptions() 的注释）⇒ 该 id 恒为 ""、抹与不抹当下等价，但一旦枚举
     * 能力补齐就是真丢数据。故此处按源侧语义实现，不按报告字面。
     */
    private func selectOption(identifier: String, isTelegram: Bool): Unit {
        if (!isTelegram) {
            getBrowserService().setDefaultBrowserId(identifier)
        }
        let openExternal = !isTelegram
        let _ = spawn {
            let ok = getSettingsService().updateWebBrowserSettings(openExternal)
            let fresh = getSettingsService().getCachedWebBrowserSettings()
            Hilog.info(0, "CjTelegram", "[WebBrowserSettings] updateWebBrowserSettings(${openExternal}) ok=${ok}")
            spawn(UIThread) { => this.applyState(fresh) }
        }
    }

    private func isOptionChecked(identifier: String, isTelegram: Bool): Bool {
        // 源侧 :333-341：Telegram 行带勾 ⟺ openExternalBrowser == false；
        // 某浏览器行带勾 ⟺ openExternalBrowser == true 且 identifier 相符。
        // ⇒ 带勾行数恒为 0 或 1，不存在"恒有一行带勾"。
        // diag-suite_settings_data_storage-TC-0435-round5.md F-1 / P-1：`identifier` 直接来自
        // `webBrowserOptions()` 里对应行的字段（调用点见 buildTelegramOptionRow()/
        // buildExternalOptionRow()），**不做**任何"未配置 ⇒ 替换成哨兵"的操作——外部行的
        // identifier 现为 "system"，与 `defaultBrowserId` 的"未配置"值 "" 不相等，未配置时
        // 该行天然零勾。这与 webBrowserSelectionLabel() 里"先把空串替换成 system 再查表"的
        // label 口径刻意不同，是源侧非对称的逐字复刻，不是遗漏。
        if (isTelegram) {
            return !this.openExternalBrowser
        }
        return this.openExternalBrowser && identifier == this.defaultBrowserId
    }

    // ==================== FIX-2：Clear Cookies ====================

    private func confirmClearCookies(): Unit {
        let uiCtx = this.getUIContext()
        let cancelBtn = AlertDialogButtonOptions(value: "Cancel", action: { => () })
        // style: DialogButtonStyle.Highlight 对位源侧 TextAlertAction(type: .defaultAction) ->
        // AlertComponent.swift:420-425 的实心强调底+白前景+粗体主题；cancelBtn 对位 .genericAction
        // （非强调），一行不动。见 diag-suite_settings_data_storage-TC-0435-round4.md F-C1。
        let clearBtn = AlertDialogButtonOptions(
            style: DialogButtonStyle.Highlight,
            value: "Clear",
            action: { => this.clearCookies() }
        )
        // 源侧 :446-475：**无标题** alert，两按钮 Cancel(普通) / Clear(默认动作)。
        uiCtx.showAlertDialog(AlertDialogParamWithButtons(
            message: "Are you sure you want to clear cookies?",
            primaryButton: cancelBtn,
            secondaryButton: clearBtn,
            autoCancel: true
        ))
    }

    /**
     * 源侧 `WKWebsiteDataStore.default().removeData(ofTypes:[Cookies, LocalStorage,
     * SessionStorage], modifiedSince: 1970, completionHandler: {})` 之后**立即**弹提示条，
     * 不等清理结果、无 loading、无进度、无失败提示（源侧 completionHandler 是空闭包）。
     *
     * ⚠ 平台差异（已登记进 featureX.json 的 unresolved_api_decisions[]）：目标侧只能清 cookie。
     * 已安装 SDK 6.1 的 `ohos/ohos.web.webview.cj.d` 全量导出面里，与 web 数据清理相关的只有
     * `WebCookieManager.clearAllCookies(incognito!:)`(:179) 与 `clearSessionCookie()`(:188)；
     * 没有 `WebStorage` 类，`WebviewController` 也只有 `clearHistory()`(:126)，
     * localStorage / sessionStorage 在本 SDK 版本**无任何绑定**（对 `WebStorage` /
     * `deleteAllData` / `deleteOrigin` / `localStorage` 全 `.cj.d` 检索 0 命中，
     * cangjie-kb `search-knowledge-base` 亦只返回 WebCookieManager 一族）。
     */
    private func clearCookies(): Unit {
        let _ = spawn {
            try {
                WebCookieManager.clearAllCookies()
                WebCookieManager.clearSessionCookie()
                Hilog.info(0, "CjTelegram", "[WebBrowserSettings] cookies cleared")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[WebBrowserSettings] clearAllCookies failed: ${e}")
            }
        }
        // 不等清理结果、无 loading、无进度、无失败提示（源侧 completionHandler 是空闭包）。
        this.showCookiesClearedToast("Cookies cleared.")
    }

    /**
     * 页内 `.info` 提示条（源侧 WebBrowserSettingsController.swift:460-471：
     * `UndoOverlayController(content: .info(title: nil, text: WebBrowser_ClearCookies_Succeed,
     * timeout: nil, customUndoText: nil), elevatedLayout: false, position: .bottom)`）。
     *
     * **为什么不走 `getUndoToastService().showUndo(..., actionText: "")`**：
     * `.info` + `customUndoText: nil` 在源侧走的是
     * UndoOverlayControllerNode.swift:292-297 的 `displayUndo = false` —— 整条**没有任何按钮**。
     * 而 components/UndoToast.cj 的两条渲染路径（:350 buildBar 与 :413 buildContentCoverBar，
     * 本页走后者）都**无条件**渲染 `Text(this.curAction)`，且各自挂着
     * `.padding(left: 12, right: 4)` 与 `.onClick({ _ => this.handleUndo() })`，全文件没有
     * `curAction.size > 0` 一类守卫 ⇒ 传空串得到的是"零宽标签 + 仍占 16vp 内边距 + 仍可点的
     * 热区"，不是"没有按钮"。该组件归 feature `uif_undoui`，不在本 feature 的 target_files 内，
     * TC-0435 §6.6 也明令本轮不得修改它；因此改在**本文件**内自绘，用的是本页
     * buildAddWebsiteDialog() 已有的那套页内浮层机制（根 Stack 的兄弟层 + zIndex），
     * 不新增任何越权面。副作用：本页提示条不再依赖 MainTabPage:1495 那个唯一宿主，
     * 与 D-126（routerPush 压栈页看不见 MainTabPage 组合树内的浮层宿主）无关。
     *
     * 时长 5000ms 溯源：源侧 timeout 传 nil ⇒ UndoOverlayControllerNode.swift:298-302 取
     * `max(5, min(8, text.count / 14))`；文案 "Cookies cleared."
     * （Telegram/Telegram-iOS/en.lproj/Localizable.strings:12650）共 16 字符 ⇒
     * 16 / 14 = 1 ⇒ min(8, 1) = 1 ⇒ max(5, 1) = 5 秒。
     */
    private func showCookiesClearedToast(text: String): Unit {
        this.cancelInfoToastTimer()
        this.infoToastText = text
        this.infoToastVisible = true
        this.startInfoToastIconPlayback()
        this.infoToastTimer = Some(Timer.once(Duration.millisecond * 5000, { =>
            // S-001：定时器回调不在 UI 线程，@State 写必须收敛回主线程。
            spawn(UIThread) { => this.infoToastVisible = false }
        }))
    }

    /** 退场 / 重复触发时收掉未到点的定时器，避免它在组件已销毁后还去写 @State。 */
    private func cancelInfoToastTimer(): Unit {
        match (this.infoToastTimer) {
            case Some(t) =>
                t.cancel()
                this.infoToastTimer = None<Timer>
            case None => ()
        }
        this.stopInfoToastIconPlayback()
    }

    /**
     * RC-B（diag-suite_settings_data_storage-TC-0435-round3.md F-B）：加载 + 播放
     * `anim_infotip` 图标。渲染是同步阻塞调用（R-138 同理），必须在 spawn 里跑；回写经
     * spawn(UIThread) 收敛回 UI 线程（S-001）。
     */
    private func startInfoToastIconPlayback(): Unit {
        this.infoToastIconReady = false
        this.infoToastIconFrameIndex = 0
        let _ = spawn {
            let loaded = ensureInfoToastIconLoaded()
            let count = infoToastIconFrameCount()
            let durationMs = infoToastIconFrameDurationMs()
            if (loaded && count > 0) {
                spawn(UIThread) { =>
                    this.infoToastIconReady = true
                    this.infoToastIconFrameIndex = 0
                    this.runInfoToastIconTimer(count, durationMs)
                }
            }
        }
    }

    /**
     * 源侧 `anim_infotip` 是一次性播放动画（JSON `op`-`ip` = 45 帧 @ 60fps ≈ 0.75s，已用
     * Python 解析该 JSON 核实），不循环，播完停在末帧——同 `components/ProfileMuteIcon.cj:62-65`
     * 到达终点即停止 timer 的既有先例（本文件不导入该组件，只是同一播放策略）。
     */
    private func runInfoToastIconTimer(count: Int64, durationMsIn: Int32): Unit {
        if (count <= 1) { return }
        var interval = durationMsIn
        if (interval < 16) { interval = 16 }
        this.infoToastIconTimer = Some(Timer.repeat(
            Duration.millisecond * Int64(interval), Duration.millisecond * Int64(interval),
            { =>
                // S-001：定时器回调不在 UI 线程，@State 写必须收敛回主线程。
                spawn(UIThread) { =>
                    if (this.infoToastIconFrameIndex + 1 >= count) {
                        this.infoToastIconFrameIndex = count - 1
                        this.stopInfoToastIconPlayback()
                    } else {
                        this.infoToastIconFrameIndex = this.infoToastIconFrameIndex + 1
                    }
                }
            }, style: CatchupStyle.Skip
        ))
    }

    /** 退场 / 提前隐藏时收掉未播完的图标播放定时器，避免它在组件已销毁后还去写 @State。 */
    private func stopInfoToastIconPlayback(): Unit {
        match (this.infoToastIconTimer) {
            case Some(t) =>
                t.cancel()
                this.infoToastIconTimer = None<Timer>
            case None => ()
        }
    }

    /**
     * `buildInfoToast()` 只能在 build 内写 UI 组件语法（不能写 match），Option 解包挪到这里，
     * 同型先例 `components/ProfileMuteIcon.cj:44-49 currentFrame()`。`infoToastIconReady` 为真
     * 时 frameIndex 恒落在 `[0, count)`（见 startInfoToastIconPlayback / runInfoToastIconTimer），
     * None 分支只在竞态极端情况兜底，取本仓既有的空 PixelMap 占位（不引入新概念）。
     */
    private func currentInfoToastIconFrame(): PixelMap {
        match (infoToastIconFrame(this.infoToastIconFrameIndex)) {
            case Some(frame) => return frame
            case None => return getEmptyAnimatedEmojiPixelMap()
        }
    }

    // ==================== FIX-6：例外删除 ====================

    /** 左滑 Delete：**无二次确认、无 Undo toast、无成功提示**（源侧 removeExceptionImpl）。 */
    private func deleteException(url: String): Unit {
        let current = this.openExternalBrowser
        let _ = spawn {
            // 源侧 :531-542 传的是当前值的取反。
            let ok = getSettingsService().toggleWebBrowserException(Some(!current), true, url)
            let fresh = getSettingsService().getCachedWebBrowserSettings()
            Hilog.info(0, "CjTelegram", "[WebBrowserSettings] deleteException ${url} ok=${ok}")
            spawn(UIThread) { => this.applyState(fresh) }
        }
    }

    private func confirmDeleteAllExceptions(): Unit {
        let uiCtx = this.getUIContext()
        let cancelBtn = AlertDialogButtonOptions(value: "Cancel", action: { => () })
        let clearBtn = AlertDialogButtonOptions(value: "Clear", action: { => this.deleteAllExceptions() })
        // 源侧 clearExceptionsImpl :544-560：无标题 alert。
        uiCtx.showAlertDialog(AlertDialogParamWithButtons(
            message: "Are you sure you want to clear this list?",
            primaryButton: cancelBtn,
            secondaryButton: clearBtn,
            autoCancel: true
        ))
    }

    private func deleteAllExceptions(): Unit {
        let _ = spawn {
            // 接口无 list 参数，一次清掉 external 与 inApp 两个列表。
            let ok = getSettingsService().deleteWebBrowserExceptions()
            let fresh = getSettingsService().getCachedWebBrowserSettings()
            Hilog.info(0, "CjTelegram", "[WebBrowserSettings] deleteAllExceptions ok=${ok}")
            spawn(UIThread) { => this.applyState(fresh) }
        }
    }

    // ==================== FIX-7：Add Website 弹层 ====================

    private func openAddDialog(): Unit {
        // 弹层永远空白不回填（源侧 AlertInputFieldComponent 每次新建，无默认值）。
        this.addInputText = ""
        this.addSubmitting = false
        this.addDonePressed = false
        this.addShakeOffset = 0.0
        this.showAddDialog = true
    }

    private func cancelAddDialog(): Unit {
        // 直接关闭、无副作用。
        this.showAddDialog = false
        this.addSubmitting = false
        this.addInputText = ""
    }

    /**
     * 逐字符准入过滤（源侧 shouldChangeText）：整次编辑要么被接受、要么被整体丢弃，
     * 字段保持编辑前的值、**无任何提示**（抖动只属于 Done 的校验失败路径，不属于本路径）。
     */
    private func onAddInputChange(value: String): Unit {
        if (value == this.addInputText) {
            return
        }
        if (acceptsWebDomainEdit(value)) {
            this.addInputText = value
            return
        }
        // 拒收：addInputText 不动，翻转挂载守卫强制 TextInput 销毁重建，把屏上那个字符收回去
        // （D-160；重建后 .onAppear 里的 FocusControl.requestFocus 把焦点/键盘接回来）。
        this.addInputRemountToggle = !this.addInputRemountToggle
    }

    private func clearAddInput(): Unit {
        this.addInputText = ""
        this.addInputRemountToggle = !this.addInputRemountToggle
    }

    private func isAddDoneEnabled(): Bool {
        // 源侧 Done `isEnabled = 输入 trim 后非空`。
        return this.addInputText.trimAscii().size > 0
    }

    /**
     * 提交链（源侧 applyImpl :100-107）：
     *   补 scheme → 校验（能解析出 host、host 含 `.`、无 user 部分）→
     *   通过则置提交中态 + toggleWebBrowserSettingsException(openExternalBrowser: !当前值,
     *   delete: false, url:)，请求返回后关弹层；
     *   不通过则**只**抖动 + 一次错误触觉反馈，无错误文案、弹层不关、不发任何请求。
     */
    private func submitAddDialog(): Unit {
        if (this.addSubmitting) {
            return
        }
        if (!this.isAddDoneEnabled()) {
            return
        }
        let url = getBrowserService().normalizeUrl(this.addInputText.trimAscii())
        if (!WebBrowserSettingsPage.isValidWebsiteUrl(url)) {
            this.runAddShake()
            triggerHaptic("notification", "error")
            return
        }
        this.addSubmitting = true
        let current = this.openExternalBrowser
        let _ = spawn {
            // 源侧 :517-521 传的是当前值的取反。
            let applied = getSettingsService().toggleWebBrowserException(Some(!current), false, url)
            let fresh = getSettingsService().getCachedWebBrowserSettings()
            Hilog.info(0, "CjTelegram", "[WebBrowserSettings] addException ${url} applied=${applied}")
            spawn(UIThread) { => this.onAddSubmitted(applied, fresh) }
        }
    }

    /**
     * 源侧 `.start(completed: { dismissImpl?() })`——只有信号**完成**（写入落地）才关弹层。
     * 请求失败/无网时保持菊花、弹层不关、不弹错误（`Cancel` 仍可用），不加超时兜底。
     */
    private func onAddSubmitted(applied: Bool, fresh: WebBrowserSettingsState): Unit {
        if (!applied) {
            return
        }
        this.addSubmitting = false
        this.showAddDialog = false
        this.addInputText = ""
        this.applyState(fresh)
    }

    /**
     * 校验：能解析出 host、host 含 `.`、无 user 部分（源侧 explicitUrl + isValidUrl 的组合效果）。
     */
    private static func isValidWebsiteUrl(url: String): Bool {
        var rest = url
        if (rest.startsWith("https://")) {
            rest = rest[8..rest.size]
        } else if (rest.startsWith("http://")) {
            rest = rest[7..rest.size]
        } else {
            return false
        }
        var host = rest
        let slashIdx = host.indexOf("/")
        match (slashIdx) {
            case Some(idx) => host = host[0..idx]
            case None => ()
        }
        if (host.contains("@")) {
            return false
        }
        let colonIdx = host.indexOf(":")
        match (colonIdx) {
            case Some(idx) => host = host[0..idx]
            case None => ()
        }
        if (host.size == 0) {
            return false
        }
        if (!host.contains(".")) {
            return false
        }
        if (host.startsWith(".") || host.endsWith(".")) {
            return false
        }
        return true
    }

    // 抖动关键帧：0 → +3vp → -3vp → +3vp → -3vp → 0，共 0.3s，每段 0.06s、不衰减
    // （与 components/ItemListComponents.cj 的 ItemListInputRow.runShakeStep 同一套参数，
    // 对齐源侧 ShakeAnimation.swift:9-40）。
    private func runAddShakeStep(offsets: Array<Float64>, idx: Int64): Unit {
        if (idx >= offsets.size) {
            return
        }
        let nextIdx = idx + 1
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 60, curve: Curve.Linear, onFinish: { =>
            this.runAddShakeStep(offsets, nextIdx)
        }), { =>
            this.addShakeOffset = offsets[idx]
        })
    }

    private func runAddShake(): Unit {
        this.runAddShakeStep([3.0, -3.0, 3.0, -3.0, 0.0], 0)
    }

    // ==================== 导航栏 ====================

    private func backArrowCommands(): String {
        let scale: Float64 = match (this.getUIContext().vp2px(1.0.vp)) {
            case Some(len) => len.value
            case None => Float64(getDefaultDisplaySync().densityPixels)
        }
        let xRight: Float64 = 24.6 * scale
        let xApex: Float64 = 17.0 * scale
        let yTop: Float64 = 14.0 * scale
        let yMid: Float64 = 22.0 * scale
        let yBottom: Float64 = 30.0 * scale
        return "M${xRight} ${yTop} L${xApex} ${yMid} L${xRight} ${yBottom}"
    }

    // ==================== 选中勾（diag-suite_settings_data_storage-TC-0435-round5.md F-2）====================

    // 对位 generateItemListCheckIcon（PresentationResourcesItemList.swift:6-17）：
    // 12x10 画布，路径 M0.215,4.361 L3.316,7.705 L9.892,0 先 translateBy(1,1) 再乘 scale 输出。
    // scale 取法与 backArrowCommands() 同一套写法。
    private func checkIconCommands(): String {
        let scale: Float64 = match (this.getUIContext().vp2px(1.0.vp)) {
            case Some(len) => len.value
            case None => Float64(getDefaultDisplaySync().densityPixels)
        }
        let x1: Float64 = 1.215 * scale
        let y1: Float64 = 5.361 * scale
        let x2: Float64 = 4.316 * scale
        let y2: Float64 = 8.705 * scale
        let x3: Float64 = 10.892 * scale
        let y3: Float64 = 1.0 * scale
        return "M${x1} ${y1} L${x2} ${y2} L${x3} ${y3}"
    }

    // ==================== UI ====================

    @Builder
    func buildTelegramOptionRow() {
        Row {
            Image(@r(app.media.appicon_classic))
                .width(29)
                .height(29)
                .borderRadius(5)
                .clip(true)
                .margin(right: 16)
            Text(trSource("Telegram"))
                .fontSize(17)
                .fontColor(ITEM_LIST_TEXT_PRIMARY)
                .layoutWeight(1)
            if (this.isOptionChecked(webBrowserOptions()[0].identifier, true)) {
                Path()
                    .width(12)
                    .height(10)
                    .commands(this.checkIconCommands())
                    .fill(Color.Transparent)
                    .stroke(ITEM_LIST_ACCENT)
                    .strokeWidth(1.98)
                    .strokeLineCap(LineCapStyle.Round)
                    .strokeLineJoin(LineJoinStyle.Round)
            }
        }
        .width(100.percent)
        .height(44)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.selectOption(webBrowserOptions()[0].identifier, true) })
    }

    @Builder
    func buildExternalOptionRow() {
        Row {
            Image(@r(app.media.misc_ic_globe))
                .width(29)
                .height(29)
                .fillColor(ITEM_LIST_ACCENT)
                .margin(right: 16)
            Text("Default Browser")
                .fontSize(17)
                .fontColor(ITEM_LIST_TEXT_PRIMARY)
                .layoutWeight(1)
            if (this.isOptionChecked(webBrowserOptions()[1].identifier, false)) {
                Path()
                    .width(12)
                    .height(10)
                    .commands(this.checkIconCommands())
                    .fill(Color.Transparent)
                    .stroke(ITEM_LIST_ACCENT)
                    .strokeWidth(1.98)
                    .strokeLineCap(LineCapStyle.Round)
                    .strokeLineJoin(LineJoinStyle.Round)
            }
        }
        .width(100.percent)
        .height(44)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.selectOption(webBrowserOptions()[1].identifier, false) })
    }

    // 源侧 :295-302 `ItemListPeerActionItem(icon: plusIconImage, color: .accent)`。
    // 不走 ItemListButtonRow：那个共享行原语的 icon 槽固定 `Image(this.icon)` 且不链
    // `.fillColor`，加号会渲染成资源自带的黑色而不是强调色（components/ItemListComponents.cj
    // 不在本 feature 的 target_files 内，不能改它）。同款内联写法先例：
    // pages/SelectivePrivacySettingsPeersPage.cj:506-521 buildAddRow()。
    @Builder
    func buildAddWebsiteRow() {
        Row {
            Image(@r(app.media.itemlist_ic_plus))
                .width(30)
                .height(30)
                .fillColor(ITEM_LIST_ACCENT)
                .margin(left: 4)
            Text(trSource("Add Website"))
                .fontSize(17)
                .fontColor(ITEM_LIST_ACCENT)
                .layoutWeight(1)
                .margin(left: 15)
        }
        .width(100.percent)
        .height(48)
        .padding(right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.openAddDialog() })
    }

    /**
     * 例外行 + 左滑删除。
     *
     * 形态照 pages/StickersSettingsPage.cj:672-706 的既有 List/ForEach/ListItem/swipeAction
     * 写法（D-135：swipeAction 插槽内联闭包顶层只放**单个**节点，多子节点容器会坍缩成空块）。
     * 删除按钮只有红底白字 `Delete`、不放图标（源侧 `icon: .none`）。
     * 整行不可点、不加按压高亮（源侧 `selectable = false`）。
     *
     * ⚠ favicon（已登记进 featureX.json 的 unresolved_api_decisions[]）：TL 的
     * `webDomainException#933ca597` 把 favicon 带成 `flags.0?long`（一个文件引用 id，不是 URL），
     * 目标侧没有"按该 id 取 web 文件"的既有链路（本仓 core/mtproto 无 upload.getWebFile 一族，
     * 检索 0 命中），因此恒走报告给定的"取不到时"分支：运行时绘制的占位方块（底色 + 域名标题
     * 首字母大写；标题为空白时用 `#`）。这不是把图片退化成色块的资源退化——真实图源在目标侧
     * 当前不可达，报告本身规定了这条兜底。
     */
    @Builder
    func buildExceptionRows() {
        List {
            ForEach(this.exceptionRows, itemGeneratorFunc: { row: WebBrowserExceptionRowData, idx: Int64 =>
                ListItem {
                    Column {
                        Row {
                            Column {
                                Text(row.initial)
                                    .fontSize(15)
                                    .fontColor(0xFFFFFF)
                            }
                            .width(29)
                            .height(29)
                            .borderRadius(7)
                            .backgroundColor(0x8E8E93)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .margin(right: 16)

                            Column {
                                Text(row.title)
                                    .fontSize(17)
                                    .fontColor(ITEM_LIST_TEXT_PRIMARY)
                                    .width(100.percent)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                Text(row.domain)
                                    .fontSize(15)
                                    .fontColor(ITEM_LIST_ACCENT)
                                    .width(100.percent)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .margin(top: 1)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                        }
                        .width(100.percent)
                        .height(WEB_EXCEPTION_ROW_H)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .alignItems(VerticalAlign.Center)

                        // D-200：行内分隔线两端都要给 margin，左值先扣掉卡片自身承担的
                        // 容器级 leftInset（本卡 padding 16 + 图标列 29 + 间距 16 = 61）。
                        if (idx < this.exceptionRows.size - 1) {
                            Divider()
                                .color(0xE5E5EA)
                                .strokeWidth(1)
                                .margin(left: 61, right: 0)
                        }
                    }
                    .width(100.percent)
                }
                .swipeAction(
                    end: { =>
                        Button(trSource("Delete"))
                            .fontSize(15)
                            .fontColor(0xFFFFFFFF)
                            .backgroundColor(0xFFFF3B30)
                            .borderRadius(0)
                            .width(80)
                            .height(100.percent)
                            .onClick({ _ => this.deleteException(row.deleteUrl) })
                    }
                )
            }, keyGeneratorFunc: { row: WebBrowserExceptionRowData, _idx: Int64 =>
                row.rowKey
            })
        }
        .width(100.percent)
        // D-199：List 的高度不能省着不给——它嵌在外层 Scroll 的 Column 里，缺省高度下
        // 由 SDK 替你选一个固定默认（撑满可视区或塌成 0），两种都不是"按内容自适应"。
        // 逐行定高（WEB_EXCEPTION_ROW_H）+ 行间 1vp 分隔线 ⇒ 总高可精确算出。
        .height(Float64(this.exceptionRows.size) * (WEB_EXCEPTION_ROW_H + 1.0) - 1.0)
        .scrollBar(BarState.Off)
    }

    @Builder
    func buildAddInputField() {
        Row {
            TextInput(placeholder: trSource("Enter URL"), text: this.addInputText)
                .id(this.addInputId)
                .layoutWeight(1)
                .fontSize(17)
                .backgroundColor(Color.Transparent)
                .enterKeyType(EnterKeyType.Done)
                .onChange({ value: String => this.onAddInputChange(value) })
                .onSubmit({ _: EnterKeyType => this.submitAddDialog() })
            if (this.addInputText.size > 0) {
                Image(@r(app.media.itemlist_ic_input_clear))
                    .width(16)
                    .height(16)
                    .margin(left: 8)
                    .onClick({ _ => this.clearAddInput() })
            }
        }
        .width(100.percent)
        .height(40)
        .padding(left: 12, right: 12)
        .borderRadius(10)
        .backgroundColor(0xF2F2F7)
        .alignItems(VerticalAlign.Center)
        // 进入即自动聚焦并弹键盘（源侧 isInitiallyFocused: true）；D-155：requestFocus 挂在
        // 触发挂载的调用点自身外包容器的 onAppear 上，保证节点已真正插入原生树。
        .onAppear({ => FocusControl.requestFocus(this.addInputId) })
    }

    @Builder
    func buildAddDoneButton() {
        Stack {
            if (this.addSubmitting) {
                LoadingProgress()
                    .width(18)
                    .height(18)
            } else {
                Text(trSource("Done"))
                    .fontSize(17)
                    .fontColor(0xFFFFFF)
            }
        }
        .width(96)
        .height(40)
        .borderRadius(20)
        .backgroundColor(ITEM_LIST_ACCENT)
        // Done 三态（源侧）：禁用 ⇒ 胶囊背景 alpha 0.2、文字仍为白色（不是文字变灰）；
        // 按下 ⇒ alpha 0.35；提交中 ⇒ 标题文字 alpha 淡到 0、原位显示 18×18 菊花。
        .opacity(this.addDoneOpacity())
        .alignContent(Alignment.Center)
        .onClick({ _ => this.submitAddDialog() })
        .onTouch({ evt =>
            match (evt.eventType) {
                case TouchType.Down => this.addDonePressed = true
                case _ => this.addDonePressed = false
            }
        })
    }

    private func addDoneOpacity(): Float64 {
        if (this.addSubmitting) {
            return 1.0
        }
        if (!this.isAddDoneEnabled()) {
            return 0.2
        }
        if (this.addDonePressed) {
            return 0.35
        }
        return 1.0
    }

    /**
     * 正文按入口分节取值——⚠ 这组映射看起来是反的，但它是源码事实
     * （WebBrowserDomainController.swift:42 `!external ? …_Create_ExternalText : …_Create_Text`），
     * 照此实现，不要按变量名直译对调：
     *   从 `OPEN IN-APP` 分节进入（源侧 addException(false) ⇒ external == false，
     *     即目标侧 openExternalBrowser == true 那一节）⇒ "…don't want to be opened in the
     *     external browser."
     *   从 `DON'T OPEN IN-APP` 进入（external == true）⇒ "…in the in-app browser."
     */
    private func addDialogMessage(): String {
        if (this.openExternalBrowser) {
            return "Enter a domain that you don't want to be opened in the external browser."
        }
        return "Enter a domain that you don't want to be opened in the in-app browser."
    }

    @Builder
    func buildAddWebsiteDialog() {
        Stack {
            Column {
                Text(trSource("Add Website"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(ITEM_LIST_TEXT_PRIMARY)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)

                Text(this.addDialogMessage())
                    .fontSize(13)
                    .fontColor(ITEM_LIST_TEXT_SECONDARY)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .margin(top: 8)

                // D-160 双相同分支挂载守卫：两个分支调同一个 @Builder，内容故意一致，只利用
                // 它们在源码里位于 if / else 两个不同位置这一事实来换取"每次翻转都销毁重建"。
                Column {
                    if (this.addInputRemountToggle) {
                        this.buildAddInputField()
                    } else {
                        this.buildAddInputField()
                    }
                }
                .width(100.percent)
                .margin(top: 16)
                .translate(x: this.addShakeOffset)

                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(ITEM_LIST_ACCENT)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Start)
                        .onClick({ _ => this.cancelAddDialog() })
                    this.buildAddDoneButton()
                }
                .width(100.percent)
                .margin(top: 20)
                .alignItems(VerticalAlign.Center)
            }
            .width(78.percent)
            .padding(top: 20, bottom: 16, left: 20, right: 20)
            .borderRadius(14)
            .backgroundColor(ITEM_LIST_BG_CARD)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x80000000)
        .alignContent(Alignment.Center)
        // D-136：全屏兄弟层重叠时命中测试排序只能靠显式 zIndex，不能依赖声明顺序。
        .zIndex(20)
    }

    /**
     * `Cookies cleared.` 提示条本体。**只有文案、没有按钮**，对位源侧 `.info` +
     * `customUndoText: nil`（UndoOverlayControllerNode.swift:292-297 `displayUndo = false`）。
     *
     * 位置：贴底（源侧 `position: .bottom` + `elevatedLayout: false` = 不抬高），由根 Stack 的
     * `Alignment.Bottom` 对齐；根 Stack 已带 `.padding(bottom: getSafeAreaBottom())`，故这里只
     * 再留 16vp 间距。**刻意不铺满屏**：全屏兄弟层会在提示条存在的 5 秒里吃掉整页的点击与滚动
     * （本工程的 Cangjie 绑定没有 `hitTestBehavior`，见 components/UndoToast.cj:388-396 的实测
     * 记录），源侧提示条只遮住自己那一条的区域。
     *
     * 视觉参数（92% 宽 / 圆角 12 / 0xF0202020 底 / 白字）沿用本仓既有提示条
     * components/UndoToast.cj:370-377，保证与 app 内其它 toast 同形；字号 15→14 与
     * `maxLines` 取源侧 UndoOverlayControllerNode.swift:284（`Font.regular(14.0)`）与 :291
     * （`maximumNumberOfLines = 10`）。左对齐显式声明，对位源侧 `textAlignment: .natural`。
     *
     * RC-B（diag-suite_settings_data_storage-TC-0435-round3.md F-B）：图标在左、文案在右
     * （源侧 `.info` 布局），图标未就绪（首帧仍在 spawn 里加载）时不占位——不引入源侧没有的
     * loading 骨架，文案先独占整条宽度，图标就绪后自然让出空间。
     */
    @Builder
    func buildInfoToast() {
        Row {
            // D-*：@Builder 方法体内只能写 UI 组件语法，match 表达式不算——同型约束见
            // components/ProfileMuteIcon.cj:44-49 currentFrame()，把 Option 解包挪到普通函数里，
            // build() 内只保留 if 与 Image(...) 调用。
            if (this.infoToastIconReady) {
                Image(this.currentInfoToastIconFrame())
                    .id("webBrowserInfoToastIcon_${this.infoToastIconFrameIndex}")
                    .width(20)
                    .height(20)
                    .objectFit(ImageFit.Contain)
                    .margin(right: 12)
            }
            Text(this.infoToastText)
                .fontSize(14)
                .fontColor(0xFFFFFF)
                .layoutWeight(1)
                .maxLines(10)
                .textAlign(TextAlign.Start)
                .textOverflow(TextOverflow.Ellipsis)
        }
        .width(92.percent)
        .alignItems(VerticalAlign.Center)
        .padding(top: 12, bottom: 12, left: 16, right: 16)
        .borderRadius(12)
        .backgroundColor(0xF0202020)
        .margin(bottom: 16)
        // D-136：与 Add Website 弹层同为根 Stack 的兄弟层，绘制/命中顺序显式声明。
        // 提示条在弹层之上（源侧提示条 present 在 .current 上下文的最顶层）。
        .zIndex(21)
    }

    public func build() {
        // Alignment.Bottom 只作用于非满屏的兄弟层（提示条）——主内容层与 Add Website 弹层
        // 都是 100%×100%，对齐方式对它们没有可见影响。
        Stack(alignContent: Alignment.Bottom) {
            Stack(alignContent: Alignment.TopStart) {
                Scroll(this.contentScroller) {
                    Column {
                        // ══════════ 分节 1 — OPEN LINKS IN（FIX-3）══════════
                        ItemListSectionHeader(title: "OPEN LINKS IN", topPad: 16)
                        Column {
                            this.buildTelegramOptionRow()
                            ItemListSeparator(leftInset: 61)
                            this.buildExternalOptionRow()
                        }
                        .backgroundColor(ITEM_LIST_BG_CARD)
                        .borderRadius(12)
                        .clip(true)
                        .margin(left: 16, right: 16)

                        ItemListSectionFooter(text: "Open links inside Telegram instead of your default browser for more privacy.")

                        // ══════════ 分节 2 — Clear Cookies（FIX-2）══════════
                        Column {
                            ItemListButtonRow(
                                title: "Clear Cookies",
                                destructive: false,
                                centered: true,
                                onClick: { => this.confirmClearCookies() }
                            )
                        }
                        .backgroundColor(ITEM_LIST_BG_CARD)
                        .borderRadius(12)
                        .clip(true)
                        .margin(left: 16, right: 16, top: 24)

                        ItemListSectionFooter(text: "Delete all cookies in the Telegram in-app browser. This action will sign you out of most websites.")

                        // ══════════ 分节 3 — 域名例外（FIX-6）══════════
                        // 空态只有"分节头 + Add Website 行 + 页脚"：不渲染任何"无例外/暂无结果"
                        // 文案或插画，也不渲染 Delete All Exceptions（源侧列表非空才追加）。
                        ItemListSectionHeader(title: this.exceptionsHeaderText, topPad: 24)
                        Column {
                            this.buildAddWebsiteRow()
                            if (this.exceptionRows.size > 0) {
                                ItemListSeparator(leftInset: 61)
                                this.buildExceptionRows()
                            }
                        }
                        .backgroundColor(ITEM_LIST_BG_CARD)
                        .borderRadius(12)
                        .clip(true)
                        .margin(left: 16, right: 16)

                        ItemListSectionFooter(text: this.exceptionsFooterText)

                        if (this.exceptionRows.size > 0) {
                            Column {
                                ItemListButtonRow(
                                    title: "Delete All Exceptions",
                                    destructive: true,
                                    centered: true,
                                    onClick: { => this.confirmDeleteAllExceptions() }
                                )
                            }
                            .backgroundColor(ITEM_LIST_BG_CARD)
                            .borderRadius(12)
                            .clip(true)
                            .margin(left: 16, right: 16, top: 24)
                        }

                        Text(trSource("")).height(32)
                    }
                    .width(100.percent)
                    .padding(top: ITEM_LIST_NAVBAR_H)
                }
                .width(100.percent)
                .height(100.percent)
                .align(Alignment.Top)
                .backgroundColor(ITEM_LIST_BG_GROUPED)
                .onDidScroll({ _xDelta: Float64, _yDelta: Float64, _scrollState: ScrollState =>
                    let cur = this.contentScroller.currentOffset()
                    if (cur.isSome()) {
                        let off = cur.getOrThrow().yOffset
                        let target = itemListNavBarBackgroundAlpha255(off)
                        if (this.prevScrollOffsetVp >= 30.0 && off <= 0.0) {
                            safeAnimateTo({ => this.getUIContext() },
                                AnimateParam(duration: 200, curve: Curve.EaseInOut),
                                { => this.navBarAlpha255 = target })
                        } else {
                            this.navBarAlpha255 = target
                        }
                        this.prevScrollOffsetVp = off
                    }
                })

                Stack(alignContent: Alignment.TopStart) {
                    ItemListNavBarBackground(alpha255: this.navBarAlpha255)

                    Row {
                        Stack {
                            Path()
                                .width(44)
                                .height(44)
                                .commands(this.backArrowCommands())
                                .fill(Color.Transparent)
                                .stroke(0x000000)
                                .strokeWidth(2)
                                .strokeLineCap(LineCapStyle.Round)
                                .strokeLineJoin(LineJoinStyle.Round)
                        }
                        .width(44)
                        .height(44)
                        .borderRadius(22)
                        .backgroundColor(0xFFFFFF)
                        .alignContent(Alignment.Center)
                        .onClick({ _ => routerPop() })
                        Blank().layoutWeight(1)
                        Text(trSource("Web Browser"))
                            .fontSize(18)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(ITEM_LIST_TEXT_PRIMARY)
                        Blank().layoutWeight(1)
                        // 源侧 leftNavigationButton / rightNavigationButton 都是 nil：右槽只留
                        // 与左侧返回控件等宽的占位，保证标题真正居中，不放任何按钮。
                        Row {}.width(44)
                    }
                    .width(100.percent)
                    .height(ITEM_LIST_NAVBAR_H)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                }
                .width(100.percent)
                .height(ITEM_LIST_NAVBAR_H)
            }
            .width(100.percent)
            .height(100.percent)

            if (this.showAddDialog) {
                this.buildAddWebsiteDialog()
            }

            if (this.infoToastVisible) {
                this.buildInfoToast()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(ITEM_LIST_BG_GROUPED)
        // D-194：本页自绘顶部 chrome，必须成对预留 getSafeAreaTop()（这里）与 .ets 壳的
        // .expandSafeArea(...)（ets/pages/WebBrowserSettingsPage.ets），否则导航栏内容会画进
        // 系统状态栏窗口而不可点击。
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
        // 拼写是 onDisAppear（大写 A）——cangjie-kb `cj-universal-event-appear`
        // 「挂载卸载事件」逐字给出 `func onDisAppear(?() -> Unit)`；写成 `onDisappear`
        // 编译期报 "'onDisappear' is not a member of class 'Stack'"（本轮实测）。
        // 既有调用点见 pages/MediaPickerScreen.cj:309、pages/IncomingCallFullscreenPage.cj:398。
        .onDisAppear({ =>
            // 离屏时收掉未到点的提示条定时器并即时隐藏，避免回来时看到一条永不消失的提示条。
            this.cancelInfoToastTimer()
            this.infoToastVisible = false
        })
    }
}
