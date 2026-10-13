package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import ohos_app_cangjie_entry.core.storage.trOr
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getPrivacyEngineService,
    PrivacyEngineService,
    getUndoToastService,
    getRealContactService,
    ContactDisplayData,
    getAvatarColorForPeer,
    getRealChatListService
}
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.core.mtproto.PrivacyRulesResponse
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSectionFooter,
    ItemListDisclosureRow,
    ItemListToggleRow,
    ItemListSeparator,
    ItemListNavBarBackground,
    itemListNavBarBackgroundAlpha255,
    ITEM_LIST_NAVBAR_H,
    ITEM_LIST_ACCENT,
    ITEM_LIST_TEXT_SECONDARY,
    MessageBubble,
    TooltipBubble,
    SearchBar
}
import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.subscribe
import ohos_app_cangjie_entry.utils.{safeAnimateTo, copyText, readRawFileBytes}
import std.collection.{ArrayList, HashMap}
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
// diag-suite_settings_privacy-TC-0133-S9.md B-2：剪贴板 Toast 图标，rawfile → Lottie →
// PixelMap 通路照抄 pages/WebBrowserSettingsPage.cj:255-340（已在设备上跑通）。
// kit.ArkUI.* 已导出同名 Size，直接 import kit.ImageKit.Size 会 "ambiguous use of 'Size'"
// （WebBrowserSettingsPage.cj:23-25 同型先例已实测），改名导入。
import kit.ImageKit.Size as IKSize
import kit.ImageKit.{createPixelMap, InitializationOptions, PixelMap, PixelMapFormat, AlphaType}
import ohos_app_cangjie_entry.bindings.getTelegramLottieNative
import std.sync.Monitor

/**
 * SelectivePrivacySettingsPage — 选择性隐私详情屏。
 *
 * 对位源侧 SelectivePrivacySettingsController.swift（`selectivePrivacySettingsController`，
 * `selectivePrivacySettingsControllerEntries` :971-1209）：一条按 kind/state/isPremium 在
 * 若干位置追加/跳过整段条目的 entries 引擎，而不是"固定骨架 + 按 kind 取文案"。
 *
 * 返修历史：
 *   - diag-suite_settings_privacy-TC-0133.md：单一根因——build() 只让 kind 驱动文案，不驱动
 *     结构；本轮把 build() 改成按源侧 P1-P12 插入点顺序排列的条件区块序列（本轮落地
 *     P2/P4/P5/P6/P7/P8/P9/P10/P11；P1/P3/P12 属 giftsAutoSave/birthday，不在本轮范围）。
 *   - diag-suite_settings_privacy-TC-0131.md RC-1c/RC-2/RC-4/RC-5/RC-6/RC-7：parsed 守卫、
 *     选中态改为本地 state 唯一权威（不回读覆盖）、容器导航栏渐显契约接入、文案对齐实机、
 *     三档对勾改固定宽度前导槽、两张圆角卡补 .clip(true)。
 *   - diag-suite_settings_privacy-TC-0132.md RC-7：例外计数串形态/口径对齐、从例外名单屏
 *     返回时重新拉取服务端真值（onShown → dispatchEvent → subscribe）。
 *
 * 路由参数（本包唯一 SSOT，供 set_privacy_and_security_root 的入口读取）：
 *   routerPush("SelectivePrivacySettingsPage", "<kindParam>")，kindParam 取值：
 *   "last_seen" | "phone_number" | "profile_photo" | "forwards" | "groups" |
 *   "calls" | "voice_messages" | "bio" | "birthday" | "saved_music" | "gifts"
 *   （对位 PrivacyEngineService.KEY_* 常量，未识别时兜底 last_seen，不崩）。
 *   "messages"（IncomingMessagePrivacyScreen 对位屏，读写 GlobalPrivacySettings.
 *   nonContactChatsPrivacy 而非 getPrivacyRules）刻意不进这张表——该字段尚未在
 *   core/mtproto/TLResponses.cj/TLMethods.cj（不在本 feature target_files 内，归
 *   net_telegram_api）落地，见 F-1 边界条件与本文件底部 emitted_integration_contracts。
 *   在该字段落地前，"messages" 若被外部传入本页仍会安全兜底成 last_seen（未识别 kind
 *   的既有安全网），set_privacy_and_security_root 的 Messages 行 onClick 也不应指向本页。
 *
 * 保存语义：三档选择、手机号发现、P2P 档位 tap 后立即提交服务端；本地 state 是屏上选中态的
 * 唯一权威，不再用回读结果覆盖乐观态（RC-2，对位源侧"只改内存 state，写入即发即忘，不回读改
 * UI"）。从例外名单屏 pop 回来时经 onShown 事件重新 refresh()（TC-0132 RC-7）；根屏侧的回传
 * 通道不在本 feature 范围（TC-0131 RC-3，归 set_privacy_and_security_root）。
 *
 * diag-suite_settings_privacy-E8-batch.md F-1（TC-0128 RC-1 详情屏半）：本轮把 bio/
 * birthday/saved_music/gifts 四个新 kind 从"未识别"变成"已识别"，接入既有
 * getPrivacyRules()/setPrivacyWithUsers() 三档+例外名单基础设施；gifts 源侧还有
 * showGiftButton / 按礼物类型细分授权两块额外能力（giftsAutoSave 专属条目），本轮不实现
 * （仅落地与其余四类同构的三档+例外名单基础功能），已知限制见 <feature_id>.md。
 *
 * D-125 边界：ItemListSectionHeader.title / ItemListDisclosureRow.value / ItemListToggleRow.isOn
 * 都是 @Prop，调用点一律传裸 @State 字段，不传函数调用返回值。
 *
 * D-115 边界：三档/两档/P2P 选择行不抽参数化 @Builder，逐处内联展开；差异化取值走 D-116 允许的
 * 普通 private func（非 @Builder，可用 let）。
 */
// inputPrivacyKeyPhoneP2P#db9e70d2（登记于 services/SettingsService.cj:532 与
// services/PrivacyEngineService.cj:32 注释）。@Component 类内不允许声明 static 变量，
// 故取模块级常量；不改 services/PrivacyEngineService.cj（不在本 feature allowlist 内）。
let SELECTIVE_PRIVACY_KEY_PHONE_P2P: UInt32 = 0xdb9e70d2

// RC-E12-3：例外选人候选的页面本地承载结构——不复用 services/RealContactService.cj:182
// ContactDisplayData（不在本 feature allowlist，且它没有 chatId/成员数字段）。isChat 区分
// 候选是用户会话还是群组会话，写侧（commitPicker()）据此分流进 allow/disallowChatIds。
public class PickerCandidate {
    public var peerId: Int64 = 0
    public var isChat: Bool = false
    public var displayName: String = ""
    public var initial: String = "?"
    public var subtitle: String = ""

    public init(peerId!: Int64, isChat!: Bool, displayName!: String, initial!: String, subtitle!: String = "") {
        this.peerId = peerId
        this.isChat = isChat
        this.displayName = displayName
        this.initial = initial
        this.subtitle = subtitle
    }
}

// ======================================================================
// 剪贴板 Toast 图标（diag-suite_settings_privacy-TC-0133-S9.md B-2 / RC-4，
// Coordinator 2026-08-31 授权 resources/rawfile/anim_linkcopied.json）
// ======================================================================

/**
 * `anim_linkcopied` 帧缓存。rawfile → Lottie → PixelMap 通路照抄
 * `pages/WebBrowserSettingsPage.cj:255-340`（已在设备上跑通的既有写法：
 * `readRawFileBytes` → `getTelegramLottieNative().renderTgs` → `createPixelMap`）。
 * B-2 只需要一枚静态图标——载体新槽位 `showUndo(iconPixelMap:)`（uif_undoui A-5）是单帧
 * 展示，不像 WebBrowser 的 `.info` 提示条那样驱动 `Timer.repeat` 连续播放——因此这里只渲染
 * 一次、缓存单帧复用，不建播放定时器。
 */
private let LINK_COPIED_ICON_SIZE: Int32 = 20 * 3
private let linkCopiedIconMonitor = Monitor()
private var linkCopiedIconFrame: Option<PixelMap> = None<PixelMap>
private var linkCopiedIconLoadAttempted: Bool = false

/**
 * 首次调用触发加载；命中缓存（或已尝试过且失败）直接返回，不重复渲染。调用方需在 spawn
 * 里跑（渲染是同步阻塞调用，R-138 同理）。`anim_linkcopied.json` 用 Python 解析核实
 * `op(122)-ip(0)=122` 帧 @ `fr=60`（`Circle` 图层 `ip:0/op:122` 贯穿全程），renderTgs 的
 * maxFrames 按此值传入。
 *
 * R-140（返修第 3 轮，`diag-suite_settings_privacy-TC-0133-S9.md` round5 review 独立复现）：
 * 上一轮曾照抄 `WebBrowserSettingsPage.knockoutInfoTipFrame()` 的"渲染后按像素后处理挖空"
 * 手法，对本资产是错的——已回退，不做任何颜色替换，理由如下。
 *
 * 源侧 `UndoOverlayControllerNode.swift:341` 传 `colors: ["info1.info1.stroke": bg,
 * "info2.info2.Fill": bg]`，`AnimationUI/AnimationNode.swift:54-56` 的
 * `setValueProvider(AnimationKeypath(keypath: "\(key).Color"))` 按**字面 keypath**逐级匹配
 * 图层/组/形状树，不是按形状类型（stroke/fill）模糊匹配。用 Python 逐层解析
 * `anim_linkcopied.json` 核实：全文件图层字面名是 `Wibe`（组 `Group 1`，形状 `Stroke 1`）与
 * `Circle`（组 `Copy-link`，形状 `Fill 1`）——与 `info1.info1.stroke` / `info2.info2.Fill`
 * 在层/组/形状任一级都不匹配（对照 `anim_infotip.json` 图层树里字面确实存在 `info1`/`info2`，
 * 该资产的两个 key 才真正命中）。因此源侧这两个 colors 键对 `anim_linkcopied` 是空操作，
 * iOS 端该图标以其烘焙色（纯白 `c.k=[1,1,1,1]`）原样渲染；link 字形的"挖空"完全来自 4 条
 * path 以 `nonzero` fill-rule 缠绕产生的真透明孔洞（alpha=0），不来自任何颜色替换。
 *
 * 上一轮的错误：把资产自身唯一的可见颜色（纯白，Wibe 描边 + Circle 填充的全部不透明像素）
 * 误当成"待替换的背景匹配色"抹除，结果整个图标主体被染成与 toast 背景 (0x20,0x20,0x20)
 * 几乎同色，等价于不可见——复制了本轮本该修的那类缺陷（图标存在但不可读，同 RC-1）。
 * 正确做法：`renderTgs` 输出的原始像素直接喂给 `createPixelMap`，不做后处理；孔洞已经是
 * 资产矢量路径本身产生的真透明区域，无需、也不应再挖空一次。
 */
private func ensureLinkCopiedIconLoaded(): Bool {
    synchronized(linkCopiedIconMonitor) {
        if (linkCopiedIconFrame.isSome()) { return true }
        if (linkCopiedIconLoadAttempted) { return false }
        linkCopiedIconLoadAttempted = true
    }
    match (readRawFileBytes("anim_linkcopied.json")) {
        case None =>
            Hilog.info(0, "CjTelegram", "[SelectivePrivacySettings] missing anim_linkcopied.json")
            return false
        case Some(bytes) =>
            let rendered = getTelegramLottieNative().renderTgs(
                bytes, "selective_privacy_link_copied_icon", LINK_COPIED_ICON_SIZE, maxFrames: 122
            )
            if (!rendered.success || rendered.frames.size == 0) { return false }
            let options = InitializationOptions(
                IKSize(LINK_COPIED_ICON_SIZE, LINK_COPIED_ICON_SIZE),
                srcPixelFormat: PixelMapFormat.Bgra8888,
                pixelFormat: PixelMapFormat.Bgra8888,
                alphaType: AlphaType.Premul
            )
            // 只取最后一帧（intro 动效——环形描边收尾 + 图标变换——已完全收尾的稳定态）：
            // 载体新槽位是单帧静态展示、不驱动播放定时器，取首帧会呈现动效播放中途的
            // 未完成形态（例如环形描边仍在全宽）。
            let lastFrame = rendered.frames.get(rendered.frames.size - 1).getOrThrow()
            // R-140：不做挖空改色后处理，见上方函数级注释——源侧 colors 键对本资产是空
            // 操作，孔洞已由资产自身矢量路径产生，原样渲染即对齐源侧。
            let pixelMap = createPixelMap(lastFrame, options)
            synchronized(linkCopiedIconMonitor) {
                linkCopiedIconFrame = Some(pixelMap)
            }
            return true
    }
}

private func currentLinkCopiedIconFrame(): Option<PixelMap> {
    synchronized(linkCopiedIconMonitor) {
        return linkCopiedIconFrame
    }
}

@HybridComponentEntry
@Component
public class SelectivePrivacySettingsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var kindParam: String = "last_seen"
    @State var paramParsed: Bool = false
    @State var hasLoadedOnce: Bool = false
    @State var isLoading: Bool = true

    @State var currentValue: String = "everybody"
    @State var allowIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var disallowIds: ArrayList<Int64> = ArrayList<Int64>()
    // RC-E12-3：群组例外——chats:Vector<long> 语义的规则构造子操作的是 chat/channel id，
    // 与 allowIds/disallowIds（user id）分开两条表，不把群成员展开塞进用户表（D4.4）。
    @State var allowChatIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var disallowChatIds: ArrayList<Int64> = ArrayList<Int64>()
    // chat id → participantsCount 权重表：refresh() 从服务端 PrivacyRulesResponse.
    // peerChatUserCounts 回填已知权重；loadPickerCandidates() 从候选枚举回填新群的权重
    // （候选尚未经过一次服务端往返，只有这里能取到）。sumSelectivePeers() 唯一消费点。
    @State var chatParticipantCounts: HashMap<Int64, Int64> = HashMap<Int64, Int64>()

    @State var isPremium: Bool = false
    @State var phoneDiscoveryEverybody: Bool = true
    @State var hideReadTimeOn: Bool = false
    @State var callP2PValue: String = "everybody"
    @State var callP2PAllowIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var callP2PDisallowIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var p2pDataLoaded: Bool = false

    // D-125: 预算好的裸 @State 字段，供子组件 @Prop 调用点直接引用。
    @State var sectionHeaderText: String = "WHO CAN SEE MY LAST SEEN"
    @State var infoText: String = ""
    @State var infoLinkTarget: String = ""
    @State var disableForLabel: String = "Never Share With"
    @State var enableForLabel: String = "Always Share With"
    @State var disableForCountText: String = "Add Users"
    @State var enableForCountText: String = "Add Users"
    @State var exceptionsFooterText: String = "You can add users or entire groups as exceptions that will override the settings above."
    // F-5（diag-suite_settings_privacy-E8-batch.md RC-4）：ItemListSectionFooter.text 是
    // @Prop（D-125），调用点必须传裸 @State 字段，不能传函数调用返回值——本字段镜像
    // phoneDiscoveryFooterText()，由 refreshDerivedLabels() 统一刷新。
    @State var phoneDiscoveryFooterTextValue: String = ""
    @State var p2pDisableForCountText: String = "Add Users"
    @State var p2pEnableForCountText: String = "Add Users"

    @State var previewMessage: Message = Message()
    @State var previewTooltipText: String = "Link to your account"

    private var contentScroller: Scroller = Scroller()
    @State var navBarAlpha255: UInt32 = 0
    private var prevScrollOffsetVp: Float64 = 0.0

    private let shownEvent: String = "settings.selectivePrivacySettingsPage.shown"

    // RC-2（TC-0132）：空名单时改弹模态多选浮层，而不是 push 一个空的例外屏。
    @State var pickerMode: String = ""
    @State var pickerLoading: Bool = false
    // RC-E12-3：候选枚举改用页面本地 PickerCandidate（不复用 ContactDisplayData——
    // 不在本 feature allowlist，且它没有 chatId/成员数字段），同时容纳用户会话与群组候选。
    @State var pickerCandidates: ArrayList<PickerCandidate> = ArrayList<PickerCandidate>()
    @State var pickerQuery: String = ""
    @State var pickedIds: ArrayList<Int64> = ArrayList<Int64>()
    // RC-E12-3：picker 内被选中的群组候选，与 pickedIds（用户）分开——commitPicker() 提交时
    // 按 isChat 分流写回 allowChatIds/disallowChatIds。
    @State var pickedChatIds: ArrayList<Int64> = ArrayList<Int64>()

    private func parseRouteParamOnce(): Unit {
        if (this.paramParsed) {
            return
        }
        this.paramParsed = true
        let raw = takePending("SelectivePrivacySettingsPage")
        if (raw.size > 0 && raw != "{}") {
            let trimmed = raw.trimAscii()
            if (trimmed.size > 0) {
                this.kindParam = trimmed
            }
        }
        this.previewMessage = this.buildPreviewMessage()
        this.refreshDerivedLabels()
        // TC-0132 RC-7：从例外名单屏 pop 回本屏时，本 NavDestination 保持挂载，.onAppear 不重放；
        // 经 .ets 壳 onShown → dispatchEvent 转发给这里注册的 handler 重新拉服务端真值。
        // paramParsed 闩保证只注册一次，不随后续 onAppear 触发累积重复 handler。
        subscribe(this.shownEvent, { _payload: String => this.refresh() })
    }

    private func keyConstructor(): UInt32 {
        if (this.kindParam == "phone_number") {
            return PrivacyEngineService.KEY_PHONE_NUMBER
        }
        if (this.kindParam == "profile_photo") {
            return PrivacyEngineService.KEY_PROFILE_PHOTO
        }
        if (this.kindParam == "forwards") {
            return PrivacyEngineService.KEY_FORWARDS
        }
        if (this.kindParam == "groups") {
            return PrivacyEngineService.KEY_GROUPS
        }
        if (this.kindParam == "calls") {
            return PrivacyEngineService.KEY_CALLS
        }
        if (this.kindParam == "voice_messages") {
            return PrivacyEngineService.KEY_VOICE_MESSAGES
        }
        if (this.kindParam == "bio") {
            return PrivacyEngineService.KEY_ABOUT
        }
        if (this.kindParam == "gifts") {
            return PrivacyEngineService.KEY_STAR_GIFTS_AUTO_SAVE
        }
        if (this.kindParam == "birthday") {
            return PrivacyEngineService.KEY_BIRTHDAY
        }
        if (this.kindParam == "saved_music") {
            return PrivacyEngineService.KEY_SAVED_MUSIC
        }
        // ic_privacy_selective_kind_extension: "messages" 源侧不是 SelectivePrivacyKind 枚举
        // 成员（submodules/SettingsUI/Sources/Privacy and Security/
        // SelectivePrivacySettingsController.swift 的 kind switch 无 .messages 分支），走
        // account.getGlobalPrivacySettings/setGlobalPrivacySettings（Everybody/Contacts+Premium
        // 二选一 + 付费消息设置），不是本页的 getPrivacyRules(key) 三档协议。0 是哨兵值（非合法
        // TL constructor），refresh()/selectValue() 已按 kindParam == "messages" 短路，不会真的
        // 拿它去发 RPC；真正的 Messages 专属 UI/数据流不在本 contract 范围内（见类头注释）。
        if (this.kindParam == "messages") {
            return 0
        }
        return PrivacyEngineService.KEY_LAST_SEEN
    }

    private func computeHeaderText(): String {
        if (this.kindParam == "phone_number") {
            return "WHO CAN SEE MY PHONE NUMBER"
        }
        if (this.kindParam == "profile_photo") {
            return "WHO CAN SEE MY PROFILE PHOTO"
        }
        if (this.kindParam == "forwards") {
            return "WHO CAN ADD A LINK TO MY ACCOUNT WHEN FORWARDING MY MESSAGES"
        }
        if (this.kindParam == "groups") {
            // iOS :991 strings.Privacy_GroupsAndChannels_WhoCanAddMe.
            return trOr("Privacy.GroupsAndChannels.WhoCanAddMe", "WHO CAN ADD ME TO GROUPS AND CHANNELS")
        }
        if (this.kindParam == "calls") {
            return "WHO CAN CALL ME"
        }
        if (this.kindParam == "voice_messages") {
            return "WHO CAN SEND ME VOICE & VIDEO MESSAGES"
        }
        if (this.kindParam == "bio") {
            return "WHO CAN SEE MY BIO"
        }
        if (this.kindParam == "gifts") {
            return "WHO CAN DISPLAY GIFTS ON MY PROFILE"
        }
        if (this.kindParam == "birthday") {
            return "WHO CAN SEE MY DATE OF BIRTH"
        }
        if (this.kindParam == "saved_music") {
            return "WHO CAN SEE MY SAVED MUSIC"
        }
        if (this.kindParam == "messages") {
            return "WHO CAN SEND ME MESSAGES?"
        }
        return "WHO CAN SEE MY LAST SEEN"
    }

    // C3/E7（TC-0133 §6.5）：手机号公开链接脚注，phone_number 非 nobody 档位与 P7 手机号发现
    // 「Everybody」档位共用同一串（§6.6）。
    private func customPublicLinkFooterText(): String {
        return "Users who have your number saved in their contacts will also see it on Telegram.\n\nThis public link opens a chat with you:\nhttps://t.me/+${this.userPhoneDigits()}"
    }

    private func userPhoneDigits(): String {
        match (getAuthStorage().getUserData()) {
            case Some(u) => return u.phone
            case None => return ""
        }
    }

    private func computeInfoText(): String {
        if (this.kindParam == "phone_number") {
            if (this.currentValue == "nobody") {
                // C4：主分组脚注在 Nobody 档位整条消失（源侧 settingInfoText 在该组合下为 nil）。
                return ""
            }
            return this.customPublicLinkFooterText()
        }
        if (this.kindParam == "profile_photo") {
            return "You can restrict who can see your profile photo with granular precision."
        }
        if (this.kindParam == "forwards") {
            return "Messages you send will not link back to your account when forwarded by other users."
        }
        if (this.kindParam == "groups") {
            return "You can restrict who can add you to groups and channels with granular precision."
        }
        if (this.kindParam == "calls") {
            return "Choose exactly who can and can't call you."
        }
        if (this.kindParam == "voice_messages") {
            if (!this.isPremium) {
                return "Subscribe to Telegram Premium to restrict who can send you voice or video messages.\n\nWhat is Telegram Premium?"
            }
            return "You can restrict who can send you voice messages with granular precision."
        }
        if (this.kindParam == "bio") {
            return "You can restrict who can see your profile bio with granular precision."
        }
        if (this.kindParam == "gifts") {
            return "Choose whether gifts from specific senders need your approval before they're visible to others on your profile."
        }
        if (this.kindParam == "birthday") {
            return "You can restrict who can see your date of birth with granular precision."
        }
        if (this.kindParam == "saved_music") {
            return "You can restrict who can see your saved music with granular precision."
        }
        if (this.kindParam == "messages") {
            return "You can restrict incoming messages to only contacts and Premium users."
        }
        return "Unless you are a Premium user, you won't see Last Seen or Online statuses for people with whom you don't share yours. Approximate times will be shown instead (recently, within a week, within a month)."
    }

    private func computeInfoLink(): String {
        if (this.kindParam == "phone_number" && this.currentValue != "nobody") {
            return "https://t.me/+${this.userPhoneDigits()}"
        }
        if (this.kindParam == "voice_messages" && !this.isPremium) {
            return "premium"
        }
        return ""
    }

    // RC-E12-4：脚注可点链接的可见文案——直接从 infoLinkTarget（computeInfoLink() 的输出，
    // 由 refreshDerivedLabels() 统一刷新）派生，不重新判定 kindParam/currentValue/isPremium，
    // 与 computeInfoLink() 共用同一组判定条件。phone_number 档：infoLinkTarget 本身就是
    // 要在 infoText/phoneDiscoveryFooterTextValue 中原样出现的可点子串（customPublicLinkFooterText()
    // 与 phoneDiscoveryFooterText() 的 Everybody 分支都内嵌同一条 t.me 链接字面量）。
    // voice_messages 非 Premium 档：infoLinkTarget 是哨兵值 "premium"，映射为 computeInfoText()
    // 里出现的可点子串 "What is Telegram Premium?"。都不命中时返回空串——ItemListSectionFooter
    // 按 hasFooterLink() 走无链接分支，调用点不需要二次判断。
    private func infoLinkVisibleText(): String {
        if (this.infoLinkTarget == "premium") {
            return "What is Telegram Premium?"
        }
        return this.infoLinkTarget
    }

    // RC-E12-4：脚注链接点击——两种目标互斥（由 computeInfoLink() 保证），按 infoLinkTarget
    // 分派，不写"先试复制再试跳转"的兜底链。phone_number 档对位源侧 copyPhoneLink：写系统
    // 剪贴板 + 提示 toast；"premium" 哨兵对位源侧 openPremiumIntro：跳转 Premium 介绍页。
    //
    // diag-suite_settings_privacy-TC-0133-S9.md B-1（RC-5）：源侧 .linkCopied 的
    // displayUndo = false 且不挂任何计时视觉，之前误传 actionText: "OK" 会让载体无条件渲染出
    // 一个源侧没有的可点按钮。改用 uif_undoui 本轮新增的 showAction!/showProgress! 逐条门
    // （对位源侧 displayUndo 与"是否挂计时视觉"两个独立决策）关闭两者。durationMs: 3000 对位
    // 源侧 SelectivePrivacySettingsController.swift:1605 附近 originalRemainingSeconds = 3。
    //
    // B-2（RC-4）：源侧 :341 图标是 Lottie（`anim_linkcopied`），渲染是同步阻塞调用
    // （R-138），必须在 spawn 里跑；showUndo() 本身不是 @State 写但走 presenter 通知链，
    // 回写收敛到 spawn(UIThread)（S-001 同理）。加载失败（首次 readRawFileBytes 未命中或
    // 渲染 0 帧）时 icon 落 None，等价于 B-2 落地前的原状（无图标），不阻断 Toast 弹出。
    private func onInfoLinkTap(): Unit {
        if (this.infoLinkTarget == "premium") {
            routerPush("PremiumPage", "")
            return
        }
        if (this.infoLinkTarget.startsWith("https://t.me/")) {
            let _ = copyText(this.infoLinkTarget)
            let _ = spawn {
                let loaded = ensureLinkCopiedIconLoaded()
                let icon = if (loaded) { currentLinkCopiedIconFrame() } else { None<PixelMap> }
                spawn(UIThread) {
                    getUndoToastService().showUndo(
                        "Link copied to clipboard",
                        showAction: false,
                        showProgress: false,
                        durationMs: 3000,
                        iconPixelMap: icon,
                        onUndo: { => () },
                        onCommit: { => () }
                    )
                }
            }
        }
    }

    private func computeDisableForLabel(): String {
        if (this.kindParam == "forwards" || this.kindParam == "groups" ||
            this.kindParam == "calls" || this.kindParam == "voice_messages" ||
            this.kindParam == "gifts") {
            return "Never Allow"
        }
        return "Never Share With"
    }

    private func computeEnableForLabel(): String {
        if (this.kindParam == "forwards" || this.kindParam == "groups" ||
            this.kindParam == "calls" || this.kindParam == "voice_messages" ||
            this.kindParam == "gifts") {
            return "Always Allow"
        }
        return "Always Share With"
    }

    // G4（TC-0133 §6.9）：例外区脚注三选一，profile_photo 按档位区分，其余 kind 恒为通用串。
    private func computeExceptionsFooterText(): String {
        if (this.kindParam == "profile_photo") {
            if (this.currentValue == "everybody") {
                return "You can add users or entire groups that will not see your profile photo."
            }
            if (this.currentValue == "contacts") {
                return "You can add users or entire groups as exceptions that will override the settings above."
            }
            return "Add users or entire groups that will still see your profile photo."
        }
        return "You can add users or entire groups as exceptions that will override the settings above."
    }

    /**
     * diag-suite_settings_privacy-TC-0131.md RC-1：返回 chevron 的 Path 命令串，逐字照抄
     * 同 allowlist 内已落地先例 pages/PrivacySettingsPage.cj:254-265 backArrowCommands()
     * （对位源侧 NavigationButtonNode.swift:8-23 glassBackArrowImage，44×44 画布，
     * topRightPoint (24.6,14)，centerPoint (17,22)，第三点 (24.6,30)）。
     *
     * ArkUI Path 的 commands 坐标按 px 消费，不随 .width/.height 的 vp 单位自动换算，漏乘
     * scale 会把箭头缩到 1/density 并锚在组件框左上角（同一坑已在 PrivacySettingsPage.cj:
     * 242-252 与 DevicesPage.cj:841 记录）。
     */
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

    private func pageTitle(): String {
        if (this.kindParam == "phone_number") {
            return "Phone Number"
        }
        if (this.kindParam == "profile_photo") {
            return "Profile Photos"
        }
        if (this.kindParam == "forwards") {
            return "Forwarded Messages"
        }
        if (this.kindParam == "groups") {
            // iOS SelectivePrivacySettingsController.swift:1732 strings.Privacy_GroupsAndChannels
            // (server English pack: "Groups & Channels").
            return trOr("Privacy.GroupsAndChannels", "Groups")
        }
        if (this.kindParam == "calls") {
            return "Calls"
        }
        if (this.kindParam == "voice_messages") {
            return "Voice Messages"
        }
        if (this.kindParam == "bio") {
            return "Bio"
        }
        if (this.kindParam == "gifts") {
            return "Gifts"
        }
        if (this.kindParam == "birthday") {
            return "Date of Birth"
        }
        if (this.kindParam == "saved_music") {
            return "Saved Music"
        }
        if (this.kindParam == "messages") {
            return "Messages"
        }
        return "Last Seen & Online"
    }

    // TC-0132 RC-7：串族改用源侧 UserCount 复数族（1 user / N users），删掉零命中的 Person/People；
    // 计数口径改经 sumUserCount() 落点，不再直接读 .size（见该函数注释）。
    private func exceptionCountText(count: Int64): String {
        if (count == 0) {
            return "Add Users"
        }
        if (count == 1) {
            return "1 user"
        }
        return "${count} users"
    }

    // 纯用户列表计数（P2P 例外名单——calls 的 P2P 档位不支持群组例外，形状不变）。
    private func sumUserCount(ids: ArrayList<Int64>): Int64 {
        return ids.size
    }

    // RC-E12-3：用户+群组混合计数——用户按 1 计，群按 chatParticipantCounts 已知权重计
    // （查不到即不计，不臆造；对齐根屏 countForSelectivePeers()，PrivacySettingsPage.cj，
    // 同样"查不到就丢弃"，非兜底近似——见 TLResponses.cj PrivacyRulesResponse 字段注释）。
    private func sumSelectivePeers(userIds: ArrayList<Int64>, chatIds: ArrayList<Int64>): Int64 {
        var total: Int64 = userIds.size
        for (cid in chatIds) {
            match (this.chatParticipantCounts.get(cid)) {
                case Some(w) => total = total + w
                case None => ()
            }
        }
        return total
    }

    private func computePreviewTooltipText(): String {
        if (this.currentValue == "everybody") {
            return "Link to your account"
        }
        if (this.currentValue == "contacts") {
            return "Link if allowed by settings below"
        }
        return "Not a link to your account"
    }

    private func buildPreviewMessage(): Message {
        let m = Message()
        let name = match (getAuthStorage().getUserData()) {
            case Some(u) =>
                if (u.lastName.size > 0) {
                    "${u.firstName} ${u.lastName}"
                } else {
                    u.firstName
                }
            case None => ""
        }
        m.forwardFromName = name
        m.senderName = name
        m.content = "Reinhardt, we need to find you some new tunes."
        m.isSent = false
        m.time = "19:20"
        return m
    }

    // 集中重算所有随 kindParam / currentValue / isPremium 派生的裸 @State 展示字段。
    // 调用点：parseRouteParamOnce()（首次）、refresh() 的 UI 线程回填（服务端真值到达后）、
    // selectValue()/selectP2PValue()（本地乐观改值后立即跟随，不等回读）。
    private func refreshDerivedLabels(): Unit {
        this.sectionHeaderText = this.computeHeaderText()
        this.infoText = this.computeInfoText()
        this.infoLinkTarget = this.computeInfoLink()
        this.disableForLabel = this.computeDisableForLabel()
        this.enableForLabel = this.computeEnableForLabel()
        this.exceptionsFooterText = this.computeExceptionsFooterText()
        this.previewTooltipText = this.computePreviewTooltipText()
        this.phoneDiscoveryFooterTextValue = this.phoneDiscoveryFooterText()
    }

    // P5（TC-0133 §6.2）：voice_messages 三行走 (checked, isLocked) 二元；其余 kind 保持单值语义。
    private func rowChecked(value: String): Bool {
        if (this.kindParam == "voice_messages") {
            if (value == "everybody") {
                return this.currentValue == "everybody" || !this.isPremium
            }
            if (value == "contacts") {
                return this.currentValue == "contacts" && this.isPremium
            }
            return this.currentValue == "nobody" && this.isPremium
        }
        return this.currentValue == value
    }

    private func rowLocked(value: String): Bool {
        if (this.kindParam == "voice_messages" && !this.isPremium) {
            return value == "contacts" || value == "nobody"
        }
        return false
    }

    private func onRowTap(value: String): Unit {
        if (this.rowLocked(value)) {
            this.displayLockedInfo()
        } else {
            this.selectValue(value)
        }
    }

    // E5/E6（TC-0133 §6.3）：非 Premium 点锁定档位弹付费墙提示，形状照
    // pages/ChatFoldersPage.cj:636-644（routerPush 子屏 + 非 Premium 拦截 + 行动按钮进 Premium 屏）。
    //
    // B-3（TC-0133-R4）：上一轮把 persistent: true 当作源侧 `timeout: nil` 的对位，是误读——
    // UndoOverlayControllerNode.swift:1282/1342 `timeout ?? (isUserInteractionEnabled ? 5 : 3)`
    // 里 `timeout: nil` 只是"不覆盖默认值"，不是"常驻"；本文案（Localizable.strings:10975
    // "Subscribe to **Telegram Premium** to select this option"）不含 "](" 链接标记，
    // isUserInteractionEnabled 恒 false，源侧实际 3 秒自动消失。真正的"停表"开关是
    // isTimeoutDisabled，只由 additionalView.interaction.disableTimeout 置位，本 content
    // 无 additionalView，用不上。改为 durationMs: 3000 对位该 3 秒。showProgress: false
    // 对位源侧全文件无对应 Progress 节点（.premiumPaywall 分支不建 statusNode/timerTextNode）。
    private func displayLockedInfo(): Unit {
        getUndoToastService().showUndo(
            "Subscribe to Telegram Premium to select this option",
            actionText: "Add",
            title: "Premium Required",
            iconRes: Some(@r(app.media.set2_ic_premiumstar)),
            durationMs: 3000,
            showProgress: false,
            onUndo: { => routerPush("PremiumPage", "") },
            onCommit: { => () }
        )
    }

    private func refresh(): Unit {
        if (!this.hasLoadedOnce) {
            this.isLoading = true
        }
        let key = this.keyConstructor()
        let kp = this.kindParam
        let _ = spawn {
            let svc = getPrivacyEngineService()
            // ic_privacy_selective_kind_extension: "messages" 不是 getPrivacyRules(key) 协议
            // 的成员（keyConstructor() 对它返回哨兵 0），不发起该 RPC——PrivacyRulesResponse()
            // 默认构造的 parsed=false 让下面的 rulesParsed 分支自然跳过写值，currentValue 停在
            // 安全默认值，不产生一次拿哨兵 key 打服务端的错误请求。
            // S7-85: open from the rules the Privacy screen (or the last write) already brought
            // back, like iOS passing the current SelectivePrivacySettings into this controller;
            // only a cold entry asks account.getPrivacy.
            let rules = if (kp == "messages") { PrivacyRulesResponse() } else { svc.getPrivacyRulesCachedFirst(key) }
            let allow = ArrayList<Int64>()
            for (id in rules.allowUsers) {
                allow.add(id)
            }
            let disallow = ArrayList<Int64>()
            for (id in rules.disallowUsers) {
                disallow.add(id)
            }
            // RC-E12-3：群组例外读侧——TLResponses.cj PrivacyRulesResponse 已解析完备，
            // 这里只是消费；权重表先拷一份不可变副本，遵循本函数其余局部变量同款的
            // "spawn(UIThread) 前先落 let 副本" 纪律，不跨线程直接捕获 rules 本体。
            let allowChats = ArrayList<Int64>()
            for (id in rules.allowChats) {
                allowChats.add(id)
            }
            let disallowChats = ArrayList<Int64>()
            for (id in rules.disallowChats) {
                disallowChats.add(id)
            }
            let chatWeights = HashMap<Int64, Int64>()
            for (cid in allowChats) {
                match (rules.peerChatUserCounts.get(cid)) {
                    case Some(w) => chatWeights[cid] = w
                    case None => ()
                }
            }
            for (cid in disallowChats) {
                match (rules.peerChatUserCounts.get(cid)) {
                    case Some(w) => chatWeights[cid] = w
                    case None => ()
                }
            }
            let rulesParsed = rules.parsed
            let v = rules.primaryValue

            let premium = match (getAuthStorage().getUserData()) {
                case Some(u) => u.isPremium
                case None => false
            }

            var phoneEverybody = true
            if (kp == "phone_number") {
                let phoneRules = svc.getPrivacyRules(PrivacyEngineService.KEY_ADDED_BY_PHONE)
                if (phoneRules.parsed) {
                    phoneEverybody = phoneRules.primaryValue == "everybody"
                }
            }

            var hideReadOn = false
            if (kp == "last_seen") {
                let gp = svc.getGlobalPrivacySettings()
                hideReadOn = gp.hideReadMarks
            }

            var p2pValue = "everybody"
            let p2pAllow = ArrayList<Int64>()
            let p2pDisallow = ArrayList<Int64>()
            var p2pLoaded = false
            if (kp == "calls") {
                let p2pRules = svc.getPrivacyRules(SELECTIVE_PRIVACY_KEY_PHONE_P2P)
                if (p2pRules.parsed) {
                    p2pValue = p2pRules.primaryValue
                    for (id in p2pRules.allowUsers) {
                        p2pAllow.add(id)
                    }
                    for (id in p2pRules.disallowUsers) {
                        p2pDisallow.add(id)
                    }
                    p2pLoaded = true
                }
            }

            // spawn(UIThread) 的闭包捕获的自由变量必须是不可变绑定（"lambda capturing
            // mutable variables needs to be called directly"）；上面几个 var 在此重新
            // let 绑定一次，只把不可变副本带进闭包。
            let phoneEverybodyFinal = phoneEverybody
            let hideReadOnFinal = hideReadOn
            let p2pValueFinal = p2pValue
            let p2pLoadedFinal = p2pLoaded
            spawn(UIThread) {
                =>
                if (rulesParsed) {
                    this.currentValue = v
                    this.allowIds = allow
                    this.disallowIds = disallow
                    this.allowChatIds = allowChats
                    this.disallowChatIds = disallowChats
                    for ((cid, w) in chatWeights) {
                        this.chatParticipantCounts[cid] = w
                    }
                    this.disableForCountText = this.exceptionCountText(this.sumSelectivePeers(disallow, disallowChats))
                    this.enableForCountText = this.exceptionCountText(this.sumSelectivePeers(allow, allowChats))
                    // F-3（diag-suite_settings_privacy-E8-batch.md RC-2）：例外名单屏改了
                    // allowIds/disallowIds 后，本页经 TC-0132 RC-7 的 onShown → refresh() 拿到
                    // 服务端真值回填的同一点，把新计数回传根屏——commitPicker() 之外的第二条
                    // 变更路径（单条删除/Delete All 发生在 Peers 屏，均已回落服务端，这里读到
                    // 的就是真值）。同型：入参用本地刚回填的值，不放进 spawn/onClick。
                    notifySelectivePrivacyUpdated(kp, v, this.sumSelectivePeers(allow, allowChats), this.sumSelectivePeers(disallow, disallowChats))
                }
                this.isPremium = premium
                this.phoneDiscoveryEverybody = phoneEverybodyFinal
                this.hideReadTimeOn = hideReadOnFinal
                if (p2pLoadedFinal) {
                    this.callP2PValue = p2pValueFinal
                    this.callP2PAllowIds = p2pAllow
                    this.callP2PDisallowIds = p2pDisallow
                    this.p2pDataLoaded = true
                    this.p2pDisableForCountText = this.exceptionCountText(this.sumUserCount(p2pDisallow))
                    this.p2pEnableForCountText = this.exceptionCountText(this.sumUserCount(p2pAllow))
                }
                this.refreshDerivedLabels()
                this.isLoading = false
                this.hasLoadedOnce = true
            }
        }
    }

    // RC-2（TC-0131）：本地 state 是屏上选中态唯一权威——立即乐观置位，写入即发即忘，
    // 不再用 sendSetPrivacy 的回读结果覆盖（对位源侧「只改内存 state，UI 立刻跟随，网络写入
    // 全程不回读」）。
    private func selectValue(newValue: String): Unit {
        if (this.currentValue == newValue) {
            return
        }
        // ic_privacy_selective_kind_extension: "messages" 没有三档选择行（本页当前未渲染
        // Messages 专属结构，见类头注释），理论上不可达；防御性短路，避免万一被调用时用哨兵
        // key=0 发出一次无意义的 setPrivacyWithUsers 写请求。
        if (this.kindParam == "messages") {
            return
        }
        this.currentValue = newValue
        this.refreshDerivedLabels()
        // RC-3′（diag-suite_settings_privacy-TC-0131.md，round-2 定向重测）：改档位后同步把
        // 新值推回根屏（回传通道见 pages/PrivacySettingsPage.cj:36-42/214-216/224-252，已建成
        // 但此前从未被调用）。必须与网络写入同点（不放进 spawn/onClick/refresh），入参用本地
        // 值（不回读）；计数按 sumSelectivePeers() 口径（用户 1 计 + 群按已知权重计）。
        notifySelectivePrivacyUpdated(this.kindParam, newValue, this.sumSelectivePeers(this.allowIds, this.allowChatIds), this.sumSelectivePeers(this.disallowIds, this.disallowChatIds))
        let key = this.keyConstructor()
        let av = ArrayList<Int64>()
        for (id in this.allowIds) {
            av.add(id)
        }
        let dv = ArrayList<Int64>()
        for (id in this.disallowIds) {
            dv.add(id)
        }
        // RC-E12-3：切档位要带着已有的群组例外一起重发，否则会静默丢弃（新签名两个
        // chat 参数都有默认空表，不传时行为等价于旧调用——这里显式传是因为需要保留）。
        let acv = ArrayList<Int64>()
        for (id in this.allowChatIds) {
            acv.add(id)
        }
        let dcv = ArrayList<Int64>()
        for (id in this.disallowChatIds) {
            dcv.add(id)
        }
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let _ = svc.setPrivacyWithUsers(key, newValue, av, dv, allowChatIds: acv, disallowChatIds: dcv)
        }
    }

    // P7（TC-0133 §6.6）：手机号发现——只有两档，立即提交，不带例外名单。
    private func selectPhoneDiscovery(everybody: Bool): Unit {
        if (this.phoneDiscoveryEverybody == everybody) {
            return
        }
        this.phoneDiscoveryEverybody = everybody
        // F-5（diag-suite_settings_privacy-E8-batch.md RC-4）：手机号发现脚注跟着本地
        // 乐观值同点刷新，phoneDiscoveryFooterTextValue 的唯一其它写入点是 refreshDerivedLabels()
        // 本身，这里复用它而不是单独镜像一行，避免两处口径漂移。
        this.refreshDerivedLabels()
        let value = if (everybody) {
            "everybody"
        } else {
            "contacts"
        }
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let _ = svc.setPrivacyWithUsers(PrivacyEngineService.KEY_ADDED_BY_PHONE, value, ArrayList<Int64>(), ArrayList<Int64>())
        }
    }

    private func phoneDiscoveryFooterText(): String {
        if (this.phoneDiscoveryEverybody) {
            return this.customPublicLinkFooterText()
        }
        return "Users who add your number to their contacts will see it on Telegram only if they are your contacts."
    }

    // P9（TC-0133 §6.7）：P2P 档位，立即提交（携带当前 P2P 例外名单快照）。
    private func selectP2PValue(newValue: String): Unit {
        if (this.callP2PValue == newValue) {
            return
        }
        this.callP2PValue = newValue
        this.refreshDerivedLabels()
        let av = ArrayList<Int64>()
        for (id in this.callP2PAllowIds) {
            av.add(id)
        }
        let dv = ArrayList<Int64>()
        for (id in this.callP2PDisallowIds) {
            dv.add(id)
        }
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let _ = svc.setPrivacyWithUsers(SELECTIVE_PRIVACY_KEY_PHONE_P2P, newValue, av, dv)
        }
    }

    // P11（TC-0133 §6.8）：Hide Read Time 开关。其余五个入参必须先取当前值回填，不得传常量，
    // 否则会顺手清掉别的全局隐私位。
    private func setHideReadTime(on: Bool): Unit {
        this.hideReadTimeOn = on
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let cur = svc.getGlobalPrivacySettings()
            let _ = svc.setGlobalPrivacySettings(
                cur.archiveAndMuteNewNoncontactPeers,
                cur.keepArchivedUnmuted,
                cur.keepArchivedFolders,
                on,
                cur.newNoncontactPeersRequirePremium,
                cur.displayGiftsButton
            )
        }
    }

    private func premiumSubscribeLabel(): String {
        if (this.isPremium) {
            // F-10（diag-suite_settings_privacy-E8-batch.md RC-8）：拼写修正，本账号非
            // Premium 未被本轮任何 case 触达。
            return "Subscribed to Telegram Premium"
        }
        return "Subscribe to Telegram Premium"
    }

    // 实机串取自 Localizable.strings（Settings.Privacy.ReadTimePremiumFooter /
    // .ReadTimePremiumActiveFooter）；非 Premium 分支已由 TC-0133 诊断报告核对过实机渲染
    // （"If you subscribe..."，纠正了 bundle 内的 "It you subscribe..." 拼写）。Premium 分支
    // 本轮测试账号非 Premium，未被任何 case 触达，取 bundle 值作兜底，未来若有 Premium 账号
    // 案例复核到偏差，按该案例结论调整。
    private func readTimeFooterText(): String {
        if (this.isPremium) {
            return "Because you are a Telegram Premium subscriber, you will see the last seen and read time of all users who are sharing it with you – even if you are hiding yours."
        }
        return "If you subscribe to Telegram Premium, you will still see other users' last seen and read time even if you hid yours from them (unless they specifically restricted it)."
    }

    private func hideReadTimeSectionEnabled(): Bool {
        return this.currentValue != "everybody" || this.disallowIds.size > 0
    }

    private func openExceptions(mode: String): Unit {
        let list = if (mode == "allow") {
            this.allowIds
        } else {
            this.disallowIds
        }
        if (list.size == 0) {
            this.pickerMode = mode
            this.loadPickerCandidates()
            return
        }
        let kp = this.kindParam
        routerPush("SelectivePrivacySettingsPeersPage", "${kp}|${mode}")
    }

    private func openP2PExceptions(mode: String): Unit {
        let kp = "${this.kindParam}_p2p"
        routerPush("SelectivePrivacySettingsPeersPage", "${kp}|${mode}")
    }

    // ==================== RC-2（TC-0132）：空名单模态多选浮层 ====================

    private func containsId(list: ArrayList<Int64>, id: Int64): Bool {
        var i: Int64 = 0
        while (i < list.size) {
            if (list[i] == id) {
                return true
            }
            i = i + 1
        }
        return false
    }

    // RC-E12-3：候选源改为联系人 ∪ 会话列表（非联系人用户会话 + 群组，含 megagroup）。
    // 过滤逐条对位源侧 ContactMultiselectionControllerNode.swift:165-181 在
    // disableChannels:true/disableBots:true 下解析出的 categories=[.contacts,.nonContacts,.groups]：
    // 保留用户会话与群组，剔除频道、bot、秘密聊天、自己、已在任一侧名单中的 peer；不照抄
    // :153-164 的 onlyUsers:true 支（那是别的调用方用的）。
    private func loadPickerCandidates(): Unit {
        this.pickerLoading = true
        this.pickerCandidates = ArrayList<PickerCandidate>()
        let excludeAllowUsers = ArrayList<Int64>()
        for (id in this.allowIds) {
            excludeAllowUsers.add(id)
        }
        let excludeDisallowUsers = ArrayList<Int64>()
        for (id in this.disallowIds) {
            excludeDisallowUsers.add(id)
        }
        let excludeAllowChats = ArrayList<Int64>()
        for (id in this.allowChatIds) {
            excludeAllowChats.add(id)
        }
        let excludeDisallowChats = ArrayList<Int64>()
        for (id in this.disallowChatIds) {
            excludeDisallowChats.add(id)
        }
        let _ = spawn {
            let contactsSvc = getRealContactService()
            let contacts = contactsSvc.getContacts()
            let candidates = ArrayList<PickerCandidate>()
            let seenUserIds = ArrayList<Int64>()
            var i: Int64 = 0
            while (i < contacts.size) {
                let c = contacts[i]
                if (!c.isSelf && !c.isBot &&
                    !this.containsId(excludeAllowUsers, c.userId) && !this.containsId(excludeDisallowUsers, c.userId)) {
                    candidates.add(PickerCandidate(peerId: c.userId, isChat: false, displayName: c.getDisplayName(), initial: c.getInitial()))
                    seenUserIds.add(c.userId)
                }
                i = i + 1
            }
            let chats = getRealChatListService().getDialogsLocalFirst(limit: 200)
            let chatWeightUpdates = HashMap<Int64, Int64>()
            for (chat in chats) {
                if (chat.isSecretChat || chat.isSavedMessages) {
                    continue
                }
                if (chat.isGroup) {
                    // isGroup 同时覆盖普通群与 megagroup（后者 isChannel 也为 true）；
                    // 纯频道 isChannel=true 且 isGroup=false，不落进本分支。
                    if (this.containsId(excludeAllowChats, chat.id) || this.containsId(excludeDisallowChats, chat.id)) {
                        continue
                    }
                    let subtitle = if (chat.participantsCount == 1) {
                        "1 member"
                    } else {
                        "${chat.participantsCount} members"
                    }
                    let initial = if (chat.name.size > 0) { chat.name.toRuneArray()[0].toString() } else { "G" }
                    candidates.add(PickerCandidate(peerId: chat.id, isChat: true, displayName: chat.name, initial: initial, subtitle: subtitle))
                    chatWeightUpdates[chat.id] = chat.participantsCount
                } else if (chat.peerType == "user" && !chat.isBot && !this.containsId(seenUserIds, chat.id)) {
                    if (this.containsId(excludeAllowUsers, chat.id) || this.containsId(excludeDisallowUsers, chat.id)) {
                        continue
                    }
                    let initial = if (chat.name.size > 0) { chat.name.toRuneArray()[0].toString() } else { "U" }
                    candidates.add(PickerCandidate(peerId: chat.id, isChat: false, displayName: chat.name, initial: initial))
                    seenUserIds.add(chat.id)
                }
            }
            let result = candidates
            spawn(UIThread) {
                =>
                this.pickerCandidates = result
                for ((cid, w) in chatWeightUpdates) {
                    this.chatParticipantCounts[cid] = w
                }
                this.pickerLoading = false
            }
        }
    }

    private func filteredPickerCandidates(): ArrayList<PickerCandidate> {
        if (this.pickerQuery.size == 0) {
            return this.pickerCandidates
        }
        let q = this.pickerQuery.toAsciiLower()
        let out = ArrayList<PickerCandidate>()
        for (c in this.pickerCandidates) {
            if (c.displayName.toAsciiLower().contains(q)) {
                out.add(c)
            }
        }
        return out
    }

    private func isPicked(id: Int64, isChat: Bool): Bool {
        if (isChat) {
            return this.containsId(this.pickedChatIds, id)
        }
        return this.containsId(this.pickedIds, id)
    }

    private func togglePicked(id: Int64, isChat: Bool): Unit {
        let source = if (isChat) { this.pickedChatIds } else { this.pickedIds }
        let out = ArrayList<Int64>()
        var found = false
        for (v in source) {
            if (v == id) {
                found = true
            } else {
                out.add(v)
            }
        }
        if (!found) {
            out.add(id)
        }
        if (isChat) {
            this.pickedChatIds = out
        } else {
            this.pickedIds = out
        }
    }

    private func cancelPicker(): Unit {
        this.pickerMode = ""
        this.pickedIds = ArrayList<Int64>()
        this.pickedChatIds = ArrayList<Int64>()
        this.pickerQuery = ""
    }

    // Done：源侧空选择只 dismiss、不写任何状态、不发任何请求（对位
    // SelectivePrivacySettingsController.swift:1449-1451）；非空选择一次性并入并只提交一次。
    private func commitPicker(): Unit {
        if (this.pickedIds.size == 0 && this.pickedChatIds.size == 0) {
            this.cancelPicker()
            return
        }
        let mode = this.pickerMode
        let newAllow = ArrayList<Int64>()
        for (id in this.allowIds) {
            newAllow.add(id)
        }
        let newDisallow = ArrayList<Int64>()
        for (id in this.disallowIds) {
            newDisallow.add(id)
        }
        let newAllowChats = ArrayList<Int64>()
        for (id in this.allowChatIds) {
            newAllowChats.add(id)
        }
        let newDisallowChats = ArrayList<Int64>()
        for (id in this.disallowChatIds) {
            newDisallowChats.add(id)
        }
        if (mode == "allow") {
            for (id in this.pickedIds) {
                newAllow.add(id)
            }
            for (id in this.pickedChatIds) {
                newAllowChats.add(id)
            }
        } else {
            for (id in this.pickedIds) {
                newDisallow.add(id)
            }
            for (id in this.pickedChatIds) {
                newDisallowChats.add(id)
            }
        }
        this.allowIds = newAllow
        this.disallowIds = newDisallow
        this.allowChatIds = newAllowChats
        this.disallowChatIds = newDisallowChats
        this.disableForCountText = this.exceptionCountText(this.sumSelectivePeers(newDisallow, newDisallowChats))
        this.enableForCountText = this.exceptionCountText(this.sumSelectivePeers(newAllow, newAllowChats))
        // F-3（diag-suite_settings_privacy-E8-batch.md RC-2）：例外名单变了也要回传根屏
        // label 计数，形状与 selectValue() 的调用逐字同型——入参用刚合并好的本地值，不回读；
        // currentValue 传原值（本路径不改档位）。
        notifySelectivePrivacyUpdated(this.kindParam, this.currentValue, this.sumSelectivePeers(newAllow, newAllowChats), this.sumSelectivePeers(newDisallow, newDisallowChats))
        this.pickerMode = ""
        this.pickedIds = ArrayList<Int64>()
        this.pickedChatIds = ArrayList<Int64>()
        this.pickerQuery = ""
        let key = this.keyConstructor()
        let cv = this.currentValue
        let av = newAllow
        let dv = newDisallow
        let acv = newAllowChats
        let dcv = newDisallowChats
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let _ = svc.setPrivacyWithUsers(key, cv, av, dv, allowChatIds: acv, disallowChatIds: dcv)
        }
    }

    @Builder
    func buildPickerCandidateRow(entry: PickerCandidate) {
        Row {
            Column {
                Text(entry.initial)
                    .fontSize(18).fontColor(0xFFFFFF).fontWeight(FontWeight.Medium)
            }
            .width(40).height(40).borderRadius(20)
            .backgroundColor(getAvatarColorForPeer(entry.peerId))
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)

            Column {
                Text(entry.displayName)
                    .fontSize(17).fontColor(0x000000)
                // RC-E12-3：群组候选带成员数副标题，用户候选不渲空行占位
                // （对位 SelectivePrivacySettingsPeersController.swift peer item 语义）。
                if (entry.subtitle.size > 0) {
                    Text(entry.subtitle)
                        .fontSize(13).fontColor(0x8E8E93)
                }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1).margin(left: 12)

            Stack(alignContent: Alignment.Center) {
                if (this.isPicked(entry.peerId, entry.isChat)) {
                    Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(ITEM_LIST_ACCENT)
                }
            }
            .width(28).height(28).borderRadius(14)
            .backgroundColor(if (this.isPicked(entry.peerId, entry.isChat)) { Color.Transparent } else { 0xE5E5EA })
        }
        .width(100.percent)
        .height(if (entry.subtitle.size > 0) { 64 } else { 56 })
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _evt => this.togglePicked(entry.peerId, entry.isChat) })
    }

    @Builder
    func buildPickerOverlay() {
        Column {
            Column {}
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(0x66000000)
                .onClick({ _evt => this.cancelPicker() })

            Column {
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(16).fontColor(ITEM_LIST_ACCENT)
                        .onClick({ _evt => this.cancelPicker() })
                    Blank().layoutWeight(1)
                    Text(trSource("Add Users"))
                        .fontSize(17).fontWeight(FontWeight.Bold)
                    Blank().layoutWeight(1)
                    Text(trSource("Done"))
                        .fontSize(16).fontColor(ITEM_LIST_ACCENT)
                        .onClick({ _evt => this.commitPicker() })
                }
                .width(100.percent).height(56)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)

                SearchBar(
                    loading: false,
                    backArrow: false,
                    text: this.pickerQuery,
                    hint: trSource("Search users and groups"),
                    onChange: { s: String => this.pickerQuery = s }
                )

                if (this.pickerLoading) {
                    Column {
                        LoadingProgress().width(32).height(32)
                    }
                    .width(100.percent).layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    List {
                        ForEach(this.filteredPickerCandidates(), itemGenerator: { entry: PickerCandidate, _idx: Int64 =>
                            ListItem {
                                this.buildPickerCandidateRow(entry)
                            }
                        }, keyGeneratorFunc: { entry: PickerCandidate, _idx: Int64 =>
                            let prefix = if (entry.isChat) { "c" } else { "u" }
                            "picker_${prefix}_${entry.peerId}"
                        })
                    }
                    .layoutWeight(1)
                }
            }
            .width(100.percent)
            .layoutWeight(9)
            .backgroundColor(0xFFFFFF)
            .borderRadius(topLeft: 14, topRight: 14)
        }
        .width(100.percent)
        .height(100.percent)
        .position(x: 0, y: 0)
    }

    public func build() {
        Stack {
            Stack(alignContent: Alignment.TopStart) {
                Scroll(this.contentScroller) {
                    Column {
                        if (this.isLoading) {
                            Column {
                                LoadingProgress().width(32).height(32)
                                Text(trSource("Loading..."))
                                    .fontSize(14).fontColor(0x8E8E93).margin(top: 8)
                            }
                            .width(100.percent)
                            .padding(top: 64)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                        } else {
                            // P2（TC-0133 §6.10）：转发预览气泡，插在 settingHeader 之前。
                            if (this.kindParam == "forwards") {
                                ItemListSectionHeader(title: "SAMPLE MESSAGE")
                                Stack(alignContent: Alignment.TopStart) {
                                    Column {}
                                        .width(100.percent).height(220)
                                        .backgroundColor(0xE5DDD0)
                                    Column {
                                        MessageBubble(message: this.previewMessage, voicePlaybackEpoch: 0)
                                        Row {
                                            TooltipBubble(text: this.previewTooltipText)
                                        }
                                        .margin(left: 12, top: 4)
                                    }
                                    .width(100.percent)
                                }
                                .width(100.percent)
                                .margin(top: 8, bottom: 8)
                                .padding(left: 16, right: 16)
                            }

                            ItemListSectionHeader(title: this.sectionHeaderText)

                            Column {
                                // Everybody
                                Row {
                                    Stack(alignContent: Alignment.Center) {
                                        if (this.rowChecked("everybody")) {
                                            Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(0x007AFF)
                                        }
                                    }
                                    .width(62).height(44)
                                    Text(trSource("Everybody")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                                }
                                .width(100.percent).height(44)
                                // RC-6′（diag-suite_settings_privacy-TC-0131.md）：源侧标题/勾起点由
                                // 62pt 预留槽（左起自卡片左缘）单独决定，行内不再叠加 leftInset；
                                // right:16 保留（右侧行为与现状一致，源侧未做对称处理）。
                                .padding(right: 16)
                                .alignItems(VerticalAlign.Center)
                                .onClick({ _evt => this.onRowTap("everybody") })

                                ItemListSeparator()

                                // My Contacts
                                Row {
                                    Stack(alignContent: Alignment.Center) {
                                        if (this.rowChecked("contacts")) {
                                            Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(0x007AFF)
                                        } else if (this.rowLocked("contacts")) {
                                            Image(@r(app.media.misc_ic_premiumlock)).width(20).height(20).fillColor(ITEM_LIST_TEXT_SECONDARY)
                                        }
                                    }
                                    .width(62).height(44)
                                    Text(trSource("My Contacts")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                                }
                                .width(100.percent).height(44)
                                .padding(right: 16)
                                .alignItems(VerticalAlign.Center)
                                .onClick({ _evt => this.onRowTap("contacts") })

                                ItemListSeparator()

                                // Nobody
                                Row {
                                    Stack(alignContent: Alignment.Center) {
                                        if (this.rowChecked("nobody")) {
                                            Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(0x007AFF)
                                        } else if (this.rowLocked("nobody")) {
                                            Image(@r(app.media.misc_ic_premiumlock)).width(20).height(20).fillColor(ITEM_LIST_TEXT_SECONDARY)
                                        }
                                    }
                                    .width(62).height(44)
                                    Text(trSource("Nobody")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                                }
                                .width(100.percent).height(44)
                                .padding(right: 16)
                                .alignItems(VerticalAlign.Center)
                                .onClick({ _evt => this.onRowTap("nobody") })
                            }
                            .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16)

                            if (this.infoText.size > 0) {
                                ItemListSectionFooter(
                                    text: this.infoText,
                                    linkText: this.infoLinkVisibleText(),
                                    onLinkTap: { _: String => this.onInfoLinkTap() }
                                )
                            }

                            // P7（TC-0133 §6.6）：手机号发现，settingInfo 之后、EXCEPTIONS 之前。
                            if (this.kindParam == "phone_number") {
                                ItemListSectionHeader(title: "WHO CAN FIND ME BY MY NUMBER", topPad: 24)
                                Column {
                                    Row {
                                        Stack(alignContent: Alignment.Center) {
                                            if (this.phoneDiscoveryEverybody) {
                                                Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(0x007AFF)
                                            }
                                        }
                                        .width(62).height(44)
                                        Text(trSource("Everybody")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                                    }
                                    .width(100.percent).height(44)
                                    .padding(left: 16, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ _evt => this.selectPhoneDiscovery(true) })

                                    ItemListSeparator()

                                    Row {
                                        Stack(alignContent: Alignment.Center) {
                                            if (!this.phoneDiscoveryEverybody) {
                                                Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(0x007AFF)
                                            }
                                        }
                                        .width(62).height(44)
                                        Text(trSource("My Contacts")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                                    }
                                    .width(100.percent).height(44)
                                    .padding(left: 16, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ _evt => this.selectPhoneDiscovery(false) })
                                }
                                .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16)

                                ItemListSectionFooter(
                                    text: this.phoneDiscoveryFooterTextValue,
                                    linkText: this.infoLinkVisibleText(),
                                    onLinkTap: { _: String => this.onInfoLinkTap() }
                                )
                            }

                            // P8 / E4（TC-0133 §6.4）：例外区，voice_messages 非 Premium 整段不进渲染树。
                            if (!(this.kindParam == "voice_messages" && !this.isPremium)) {
                                ItemListSectionHeader(title: "EXCEPTIONS", topPad: 24)

                                Column {
                                    if (this.currentValue == "everybody") {
                                        ItemListDisclosureRow(
                                            title: this.disableForLabel,
                                            value: this.disableForCountText,
                                            onClick: { => this.openExceptions("disallow") }
                                        )
                                    } else if (this.currentValue == "contacts") {
                                        ItemListDisclosureRow(
                                            title: this.disableForLabel,
                                            value: this.disableForCountText,
                                            onClick: { => this.openExceptions("disallow") }
                                        )
                                        ItemListSeparator()
                                        ItemListDisclosureRow(
                                            title: this.enableForLabel,
                                            value: this.enableForCountText,
                                            onClick: { => this.openExceptions("allow") }
                                        )
                                    } else {
                                        ItemListDisclosureRow(
                                            title: this.enableForLabel,
                                            value: this.enableForCountText,
                                            onClick: { => this.openExceptions("allow") }
                                        )
                                    }
                                }
                                .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16)

                                ItemListSectionFooter(text: this.exceptionsFooterText)
                            }

                            // P9（TC-0133 §6.7）：P2P 段，例外区之后，calls 且数据取到时渲染。
                            if (this.kindParam == "calls" && this.p2pDataLoaded) {
                                ItemListSectionHeader(title: "PEER-TO-PEER", topPad: 24)

                                Column {
                                    Row {
                                        Stack(alignContent: Alignment.Center) {
                                            if (this.callP2PValue == "everybody") {
                                                Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(0x007AFF)
                                            }
                                        }
                                        .width(62).height(44)
                                        Text(trSource("Always")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                                    }
                                    .width(100.percent).height(44)
                                    .padding(left: 16, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ _evt => this.selectP2PValue("everybody") })

                                    ItemListSeparator()

                                    Row {
                                        Stack(alignContent: Alignment.Center) {
                                            if (this.callP2PValue == "contacts") {
                                                Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(0x007AFF)
                                            }
                                        }
                                        .width(62).height(44)
                                        Text(trSource("My Contacts")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                                    }
                                    .width(100.percent).height(44)
                                    .padding(left: 16, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ _evt => this.selectP2PValue("contacts") })

                                    ItemListSeparator()

                                    Row {
                                        Stack(alignContent: Alignment.Center) {
                                            if (this.callP2PValue == "nobody") {
                                                Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(0x007AFF)
                                            }
                                        }
                                        .width(62).height(44)
                                        Text(trSource("Never")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                                    }
                                    .width(100.percent).height(44)
                                    .padding(left: 16, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ _evt => this.selectP2PValue("nobody") })
                                }
                                .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16)

                                ItemListSectionFooter(text: "Disabling peer-to-peer will relay all calls through Telegram servers to avoid revealing your IP address, but may decrease audio and video quality.")

                                Column {
                                    if (this.callP2PValue == "everybody") {
                                        ItemListDisclosureRow(
                                            title: this.disableForLabel,
                                            value: this.p2pDisableForCountText,
                                            onClick: { => this.openP2PExceptions("disallow") }
                                        )
                                    } else if (this.callP2PValue == "contacts") {
                                        ItemListDisclosureRow(
                                            title: this.disableForLabel,
                                            value: this.p2pDisableForCountText,
                                            onClick: { => this.openP2PExceptions("disallow") }
                                        )
                                        ItemListSeparator()
                                        ItemListDisclosureRow(
                                            title: this.enableForLabel,
                                            value: this.p2pEnableForCountText,
                                            onClick: { => this.openP2PExceptions("allow") }
                                        )
                                    } else {
                                        ItemListDisclosureRow(
                                            title: this.enableForLabel,
                                            value: this.p2pEnableForCountText,
                                            onClick: { => this.openP2PExceptions("allow") }
                                        )
                                    }
                                }
                                .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16, top: 12)

                                ItemListSectionFooter(text: this.exceptionsFooterText)
                            }

                            // P10（TC-0133 §6.9，G1）：公开头像入口。fallback 上传链路本轮不实现
                            // （见诊断报告 §3.3 G2，需 photos.uploadProfilePhoto 补 fallback flag）。
                            if (this.kindParam == "profile_photo" && (this.currentValue != "everybody" || this.disallowIds.size > 0)) {
                                Column {
                                    ItemListDisclosureRow(
                                        title: "Set Public Photo",
                                        value: "",
                                        onClick: { => routerPush("EditProfilePage", "") }
                                    )
                                }
                                .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16, top: 12)

                                ItemListSectionFooter(text: "You can upload a public photo for users who are restricted from seeing your real profile photos.")
                            }

                            // P11（TC-0133 §6.8）：Hide Read Time。
                            if (this.kindParam == "last_seen" && this.hideReadTimeSectionEnabled()) {
                                Column {
                                    ItemListToggleRow(
                                        title: "Hide Read Time",
                                        isOn: this.hideReadTimeOn,
                                        onChange: { on: Bool => this.setHideReadTime(on) }
                                    )
                                }
                                .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16, top: 12)

                                ItemListSectionFooter(text: "Hide the time when you read messages from people who can't see your last seen. If you turn this on, their read time will also be hidden from you (unless you are a Premium user).\n\nThis setting does not affect group chats.")

                                // F-10（diag-suite_settings_privacy-E8-batch.md RC-8）：源侧是
                                // ItemListPeerActionItem（accent 文字、无右值、无 chevron），不是
                                // disclosure 行——本页/components 都没有对位原语，内联一个最小
                                // action 行，不改 ItemListDisclosureRow 本身（60+ 调用点）。
                                Column {
                                    Row {
                                        Text(this.premiumSubscribeLabel())
                                            .fontSize(17).fontColor(ITEM_LIST_ACCENT).layoutWeight(1)
                                    }
                                    .width(100.percent).height(44)
                                    .padding(left: 16, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ _evt => routerPush("PremiumPage", "") })
                                }
                                .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16, top: 12)

                                ItemListSectionFooter(text: this.readTimeFooterText())
                            }

                            Text(trSource("")).height(32)
                        }
                    }
                }
                .align(Alignment.Top)
                .padding(top: ITEM_LIST_NAVBAR_H)
                .width(100.percent).height(100.percent)
                .backgroundColor(0xF2F2F7)
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
                        // diag-suite_settings_privacy-TC-0131.md RC-1：返回控件字形换成代码
                        // 绘制的矢量折线，逐字照抄同 allowlist 内已落地先例
                        // pages/PrivacySettingsPage.cj:254-265 backArrowCommands() +
                        // :1326-1334 Path() 节点（对位源侧 NavigationButtonNode.swift:8-23
                        // glassBackArrowImage：44×44 画布，(24.6,14)→(17,22)→(24.6,30)，
                        // lineWidth=2，round cap/join）。只改本页这一站点，不动共享原语
                        // components/ItemListComponents.cj:43 的披露符「›」。
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
                        .width(44).height(44)
                        .borderRadius(22)
                        .backgroundColor(0xFFFFFF)
                        .alignContent(Alignment.Center)
                        .onClick({ _ => routerPop() })
                        Blank().layoutWeight(1)
                        // diag-suite_settings_privacy-TC-0131.md RC-2：导航栏标题字体对位源侧
                        // NavigationBarImpl.swift:15 titleFont（17 / semibold）。semibold →
                        // FontWeight.Medium 是本仓既定惯例（仓颉 FontWeight 无 Semibold），
                        // 先例 pages/WallpaperPickerPage.cj:1088 等。验收口径是这两个代码
                        // 常量本身，不是占屏宽百分比——两侧逻辑屏宽不等价（402pt/377.14vp=
                        // 1.0659），改完仍会停在约 39.8%，属逻辑单位系数、不可代码修、不判红。
                        Text(this.pageTitle())
                            .fontSize(17).fontWeight(FontWeight.Medium)
                        Blank().layoutWeight(1)
                        Row { }.width(44)
                    }
                    .width(100.percent)
                    .height(ITEM_LIST_NAVBAR_H)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                }
                .width(100.percent)
                .height(ITEM_LIST_NAVBAR_H)
            }
            .width(100.percent).height(100.percent)

            if (this.pickerMode.size > 0) {
                this.buildPickerOverlay()
            }
        }
        .width(100.percent).height(100.percent).backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({
            =>
            this.parseRouteParamOnce()
            this.refresh()
        })
    }
}
